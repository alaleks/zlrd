//! Webhook sender: POSTs alert JSON payloads to one or more configured URLs.
//! Uses `std.http.Client` so both `http://` and `https://` work via the
//! standard library — no third-party deps.
//!
//! Delivery is best-effort: HTTP failures are logged via `std.log` and the
//! watcher loop continues. The shared `Client` is reused across calls so the
//! connection pool can keep keep-alive connections warm.

const std = @import("std");

const config = @import("config.zig");

const log = std.log.scoped(.zlrd_webhook);

pub const Sender = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: std.http.Client,
    headers: []const config.HeaderSpec,
    extra_headers: []std.http.Header,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        headers: []const config.HeaderSpec,
    ) !Sender {
        // Pre-build the std.http.Header array once — same shape every call.
        const extra = try allocator.alloc(std.http.Header, headers.len);
        for (headers, 0..) |h, i| {
            extra[i] = .{ .name = h.name, .value = h.value };
        }
        // Always attach a content-type for the JSON payload.
        // (Caller may override via --webhook-header.)
        return .{
            .allocator = allocator,
            .io = io,
            .client = .{ .allocator = allocator, .io = io },
            .headers = headers,
            .extra_headers = extra,
        };
    }

    pub fn deinit(self: *Sender) void {
        self.client.deinit();
        self.allocator.free(self.extra_headers);
        self.* = undefined;
    }

    /// Posts `payload` to `url`. Returns void: any error is logged. Designed
    /// to plug into `alert.Dispatcher.setWebhookSender` via `sendThunk`.
    pub fn send(self: *Sender, url: []const u8, payload: []const u8) void {
        const result = self.client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = self.extra_headers,
        }) catch |err| {
            log.warn("webhook POST {s} failed: {t}", .{ url, err });
            return;
        };

        const code = @intFromEnum(result.status);
        if (code >= 400) {
            log.warn("webhook POST {s} returned {d}", .{ url, code });
        }
    }
};

/// Thunk that adapts `Sender.send` to `alert.WebhookSender`'s `*anyopaque`
/// signature. `ctx` must be a `*Sender`.
pub fn sendThunk(ctx: ?*anyopaque, url: []const u8, payload: []const u8) void {
    const sender: *Sender = @ptrCast(@alignCast(ctx orelse return));
    sender.send(url, payload);
}
