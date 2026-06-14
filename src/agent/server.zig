//! HTTP metrics server: serves `/metrics`, `/metrics.json`, and `/healthz`.
//!
//! Auth: every protected route requires `Authorization: Bearer <token>`. The
//! comparison is constant-time so timing leaks don't reveal the token.
//! `/healthz` is unauthenticated by convention (kubelet liveness probes etc.).

const std = @import("std");

const metrics = @import("metrics.zig");

const log = std.log.scoped(.zlrd_server);

pub const Options = struct {
    listen_addr: []const u8,
    metrics_token: []const u8,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    metrics: *metrics.Metrics,
    token: []const u8,
    listener: std.Io.net.Server,
    shutdown_flag: std.atomic.Value(bool),

    pub fn listen(
        allocator: std.mem.Allocator,
        io: std.Io,
        m: *metrics.Metrics,
        opts: Options,
    ) !Server {
        const addr = try std.Io.net.IpAddress.parseLiteral(opts.listen_addr);
        const listener = try addr.listen(io, .{ .reuse_address = true });
        return .{
            .allocator = allocator,
            .io = io,
            .metrics = m,
            .token = opts.metrics_token,
            .listener = listener,
            .shutdown_flag = .init(false),
        };
    }

    pub fn deinit(self: *Server) void {
        self.listener.deinit(self.io);
        self.* = undefined;
    }

    pub fn requestShutdown(self: *Server) void {
        self.shutdown_flag.store(true, .monotonic);
    }

    /// Blocks until shutdown is requested. Accepts connections sequentially —
    /// scrape rates for a single tenant are low and one /metrics call takes
    /// microseconds, so concurrency adds complexity without a payoff here.
    pub fn run(self: *Server) void {
        while (!self.shutdown_flag.load(.monotonic)) {
            const stream = self.listener.accept(self.io) catch |err| switch (err) {
                error.SocketNotListening, error.Canceled => return,
                error.WouldBlock, error.ConnectionAborted => continue,
                else => {
                    log.warn("accept failed: {t}", .{err});
                    continue;
                },
            };
            self.serve(stream);
        }
    }

    fn serve(self: *Server, stream: std.Io.net.Stream) void {
        defer stream.close(self.io);

        var recv_buffer: [4096]u8 = undefined;
        var send_buffer: [8192]u8 = undefined;
        var conn_reader = stream.reader(self.io, &recv_buffer);
        var conn_writer = stream.writer(self.io, &send_buffer);
        var http_server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

        // One request per accepted connection is enough — keep-alive is nice
        // but adds re-entry edge cases; scrape clients can reopen cheaply.
        if (http_server.reader.state != .ready) return;
        var request = http_server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => {
                log.warn("receiveHead failed: {t}", .{err});
                return;
            },
        };

        self.routeRequest(&request);
    }

    fn routeRequest(self: *Server, request: *std.http.Server.Request) void {
        const target = request.head.target;
        const route = classifyRoute(target);

        if (route == .healthz) {
            self.respond(request, route, .ok, "text/plain", "ok\n");
            return;
        }
        if (route == .other) {
            self.respond(request, route, .not_found, "text/plain", "not found\n");
            return;
        }
        if (!self.authorized(request)) {
            self.respond(request, route, .unauthorized, "text/plain", "unauthorized\n");
            return;
        }

        var body_buf: [16 * 1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&body_buf);

        const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        switch (route) {
            .metrics => {
                metrics.renderPrometheus(self.metrics, &w, now_ms) catch {
                    self.respond(request, route, .internal_server_error, "text/plain", "render failed\n");
                    return;
                };
                self.respond(request, route, .ok, "text/plain; version=0.0.4", w.buffered());
            },
            .metrics_json => {
                metrics.renderJson(self.metrics, &w, now_ms) catch {
                    self.respond(request, route, .internal_server_error, "text/plain", "render failed\n");
                    return;
                };
                self.respond(request, route, .ok, "application/json", w.buffered());
            },
            else => unreachable,
        }
    }

    fn respond(
        self: *Server,
        request: *std.http.Server.Request,
        route: metrics.HttpRoute,
        status: std.http.Status,
        content_type: []const u8,
        body: []const u8,
    ) void {
        self.metrics.observeHttp(route, @intFromEnum(status));
        request.respond(body, .{
            .status = status,
            .extra_headers = &.{
                .{ .name = "content-type", .value = content_type },
                .{ .name = "cache-control", .value = "no-store" },
            },
        }) catch |err| {
            log.warn("respond failed: {t}", .{err});
        };
    }

    fn authorized(self: *const Server, request: *std.http.Server.Request) bool {
        var it = request.iterateHeaders();
        while (it.next()) |h| {
            if (!std.ascii.eqlIgnoreCase(h.name, "authorization")) continue;
            const prefix = "Bearer ";
            if (h.value.len <= prefix.len) return false;
            if (!std.ascii.eqlIgnoreCase(h.value[0..prefix.len], prefix)) return false;
            const presented = std.mem.trim(u8, h.value[prefix.len..], " \t");
            return ctEqual(presented, self.token);
        }
        return false;
    }
};

pub fn classifyRoute(target: []const u8) metrics.HttpRoute {
    // Strip a trailing query string when classifying.
    const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..path_end];

    if (std.mem.eql(u8, path, "/metrics")) return .metrics;
    if (std.mem.eql(u8, path, "/metrics.json")) return .metrics_json;
    if (std.mem.eql(u8, path, "/healthz")) return .healthz;
    return .other;
}

/// Constant-time byte-slice equality. Returns false on length mismatch (length
/// is not secret information). For equal-length inputs, runs in `O(len)` and
/// does not short-circuit on the first differing byte.
pub fn ctEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

const testing = std.testing;

test "classifyRoute: handles known paths and unknowns" {
    try testing.expectEqual(metrics.HttpRoute.metrics, classifyRoute("/metrics"));
    try testing.expectEqual(metrics.HttpRoute.metrics_json, classifyRoute("/metrics.json"));
    try testing.expectEqual(metrics.HttpRoute.healthz, classifyRoute("/healthz"));
    try testing.expectEqual(metrics.HttpRoute.other, classifyRoute("/"));
    try testing.expectEqual(metrics.HttpRoute.other, classifyRoute("/api/v1/x"));
}

test "classifyRoute: strips query string" {
    try testing.expectEqual(metrics.HttpRoute.metrics, classifyRoute("/metrics?fmt=text"));
}

test "ctEqual: equal strings match, unequal do not" {
    try testing.expect(ctEqual("hello", "hello"));
    try testing.expect(!ctEqual("hello", "world"));
    try testing.expect(!ctEqual("hello", "hell"));
    try testing.expect(ctEqual("", ""));
}
