//! OTLP/HTTP transport: POSTs a protobuf payload to an OTLP endpoint with
//! retry + exponential backoff. Built on `std.http.Client` so TLS is handled
//! by the standard library — no third-party deps.
//!
//! Policy:
//!   - URL must be https:// (TLS mandatory)
//!   - Caller supplies a base URL like `https://collector.example.com:4318`;
//!     `Transport.send` appends `/v1/logs` or `/v1/metrics`.
//!   - Retry on connection errors, 408, 429, and 5xx
//!   - Give up on other 4xx (caller misconfiguration)
//!   - Backoff: 100ms, 200ms, 400ms, 800ms (capped at 5s)

const std = @import("std");

const log = std.log.scoped(.zlrd_sidecar);

pub const Signal = enum {
    logs,
    metrics,

    pub fn path(self: Signal) []const u8 {
        return switch (self) {
            .logs => "/v1/logs",
            .metrics => "/v1/metrics",
        };
    }
};

pub const Error = error{
    InvalidUrl,
    TlsRequired,
} || std.mem.Allocator.Error;

pub const Transport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: std.http.Client,
    base_url: []const u8,
    extra_headers: []std.http.Header,
    max_retries: u8,

    pub const Options = struct {
        /// Base URL like `https://collector.example.com:4318`. The `/v1/*`
        /// path is appended per signal.
        base_url: []const u8,
        /// Extra headers (auth tokens, tenant IDs). Borrowed slice — caller
        /// keeps ownership of the underlying memory.
        headers: []const std.http.Header,
        max_retries: u8 = 3,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, opts: Options) Error!Transport {
        if (!std.mem.startsWith(u8, opts.base_url, "https://")) return error.TlsRequired;
        // Strip trailing slash so endpoint = base + "/v1/logs" stays clean.
        var trimmed = opts.base_url;
        while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
        if (trimmed.len < "https://x".len) return error.InvalidUrl;

        const headers_copy = try allocator.alloc(std.http.Header, opts.headers.len);
        @memcpy(headers_copy, opts.headers);

        return .{
            .allocator = allocator,
            .io = io,
            .client = .{ .allocator = allocator, .io = io },
            .base_url = trimmed,
            .extra_headers = headers_copy,
            .max_retries = opts.max_retries,
        };
    }

    pub fn deinit(self: *Transport) void {
        self.client.deinit();
        self.allocator.free(self.extra_headers);
        self.* = undefined;
    }

    /// Posts `payload` to `<base_url><signal.path()>` with retries on
    /// transient failures. Returns `true` if the server returned 2xx,
    /// `false` if all retries were exhausted or the server returned a
    /// non-retryable error.
    pub fn send(self: *Transport, signal: Signal, payload: []const u8) bool {
        var url_buf: [1024]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}{s}", .{ self.base_url, signal.path() }) catch {
            log.warn("sidecar: URL too long for {s}", .{signal.path()});
            return false;
        };

        var attempt: u8 = 0;
        while (attempt <= self.max_retries) : (attempt += 1) {
            if (attempt > 0) {
                const ms = backoffMs(attempt);
                std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
            }

            const result = self.client.fetch(.{
                .location = .{ .url = url },
                .method = .POST,
                .payload = payload,
                .headers = .{ .content_type = .{ .override = "application/x-protobuf" } },
                .extra_headers = self.extra_headers,
            }) catch |err| {
                if (attempt == self.max_retries) {
                    log.warn("sidecar POST {s} failed after {d} retries: {t}", .{ url, attempt, err });
                    return false;
                }
                continue;
            };

            const code = @intFromEnum(result.status);
            if (code >= 200 and code < 300) return true;
            if (!retryable(code) or attempt == self.max_retries) {
                log.warn("sidecar POST {s} returned {d}", .{ url, code });
                return false;
            }
        }
        return false;
    }
};

fn retryable(code: u16) bool {
    if (code == 408 or code == 429) return true;
    return code >= 500 and code < 600;
}

/// Exponential backoff with a 5s cap: 100ms, 200ms, 400ms, 800ms, 1600ms, …
fn backoffMs(attempt: u8) u64 {
    const base: u64 = 100;
    const shift: u6 = @min(attempt - 1, 6);
    const ms = base * (@as(u64, 1) << shift);
    return @min(ms, 5_000);
}

// ─── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Signal: paths" {
    try testing.expectEqualStrings("/v1/logs", Signal.logs.path());
    try testing.expectEqualStrings("/v1/metrics", Signal.metrics.path());
}

test "retryable: 5xx and 429 are retryable, other 4xx are not" {
    try testing.expect(retryable(500));
    try testing.expect(retryable(503));
    try testing.expect(retryable(599));
    try testing.expect(retryable(408));
    try testing.expect(retryable(429));
    try testing.expect(!retryable(400));
    try testing.expect(!retryable(401));
    try testing.expect(!retryable(404));
    try testing.expect(!retryable(200));
    try testing.expect(!retryable(301));
}

test "backoffMs: doubles until cap" {
    try testing.expectEqual(@as(u64, 100), backoffMs(1));
    try testing.expectEqual(@as(u64, 200), backoffMs(2));
    try testing.expectEqual(@as(u64, 400), backoffMs(3));
    try testing.expectEqual(@as(u64, 800), backoffMs(4));
    try testing.expectEqual(@as(u64, 1600), backoffMs(5));
    try testing.expectEqual(@as(u64, 3200), backoffMs(6));
    try testing.expectEqual(@as(u64, 5_000), backoffMs(7));
    try testing.expectEqual(@as(u64, 5_000), backoffMs(20));
}
