//! Alert dispatcher: turns a fired rule into a structured JSON payload and
//! fans it out to the configured sinks (stderr, file, webhooks). On exit-mode,
//! it sets a flag that the main loop polls.
//!
//! Webhook delivery is delegated to `webhook.zig`; this module never blocks
//! the watcher loop on outbound network I/O for longer than the per-call HTTP
//! timeout.

const std = @import("std");

const config = @import("config.zig");
const metrics = @import("metrics.zig");
const rules = @import("rules.zig");

/// Hooks set by the watcher / main loop so this file does not have to depend
/// on `webhook.zig` (which pulls in std.http). Set after construction.
pub const WebhookSender = *const fn (ctx: ?*anyopaque, url: []const u8, payload: []const u8) void;

pub const Dispatcher = struct {
    io: std.Io,
    sinks: config.SinkConfig,
    file: ?std.Io.File,
    file_offset: u64,
    file_mutex: std.Io.Mutex,
    metrics: *metrics.Metrics,
    exit_flag: std.atomic.Value(bool),
    alert_exit: bool,
    webhook_sender: ?WebhookSender,
    webhook_ctx: ?*anyopaque,

    pub fn init(
        io: std.Io,
        sinks: config.SinkConfig,
        m: *metrics.Metrics,
        alert_exit: bool,
    ) !Dispatcher {
        var file: ?std.Io.File = null;
        var offset: u64 = 0;
        if (sinks.file_path) |path| {
            file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
            offset = try file.?.length(io);
        }
        return .{
            .io = io,
            .sinks = sinks,
            .file = file,
            .file_offset = offset,
            .file_mutex = .init,
            .metrics = m,
            .exit_flag = .init(false),
            .alert_exit = alert_exit,
            .webhook_sender = null,
            .webhook_ctx = null,
        };
    }

    pub fn setWebhookSender(self: *Dispatcher, sender: WebhookSender, ctx: ?*anyopaque) void {
        self.webhook_sender = sender;
        self.webhook_ctx = ctx;
    }

    pub fn deinit(self: *Dispatcher) void {
        if (self.file) |f| f.close(self.io);
        self.file = null;
    }

    pub fn shouldExit(self: *const Dispatcher) bool {
        return self.exit_flag.load(.monotonic);
    }

    /// Fan out a single fired rule to all enabled sinks. Each sink is
    /// best-effort: a failing webhook does not prevent the file/stderr write.
    pub fn dispatch(self: *Dispatcher, fired: rules.Fired, now_ms: i64) void {
        self.metrics.observeAlert(fired.kind);

        // Render once into a stack buffer, reuse for all sinks. 2 KiB covers
        // the per-line cap we already enforce upstream.
        var buf: [2048]u8 = undefined;
        const payload = formatAlert(&buf, fired, now_ms) catch return;

        if (self.sinks.stderr) self.writeStderr(payload);
        if (self.file != null) self.writeFile(payload);
        if (self.webhook_sender) |send| {
            for (self.sinks.webhooks) |url| {
                send(self.webhook_ctx, url, payload);
            }
        }
        if (self.alert_exit) self.exit_flag.store(true, .monotonic);
    }

    fn writeStderr(self: *Dispatcher, payload: []const u8) void {
        const stderr = std.Io.File.stderr();
        stderr.writeStreamingAll(self.io, payload) catch return;
        stderr.writeStreamingAll(self.io, "\n") catch return;
    }

    fn writeFile(self: *Dispatcher, payload: []const u8) void {
        const f = self.file orelse return;
        self.file_mutex.lockUncancelable(self.io);
        defer self.file_mutex.unlock(self.io);
        f.writePositionalAll(self.io, payload, self.file_offset) catch return;
        self.file_offset += payload.len;
        f.writePositionalAll(self.io, "\n", self.file_offset) catch return;
        self.file_offset += 1;
    }
};

/// Renders `fired` as a single-line JSON payload into `buf`. Returns the
/// populated slice. Never includes a trailing newline — callers add it where
/// appropriate.
pub fn formatAlert(buf: []u8, fired: rules.Fired, now_ms: i64) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);

    try w.writeByte('{');
    try w.print("\"ts_ms\":{d}", .{now_ms});
    try w.print(",\"kind\":\"{s}\"", .{fired.kind.label()});
    try w.writeAll(",\"rule_id\":");
    try writeJsonString(&w, fired.rule_id);
    try w.writeAll(",\"file\":");
    try writeJsonString(&w, fired.file_path);
    try w.print(",\"threshold\":{{\"count\":{d},\"window_ms\":{d}}}", .{
        fired.threshold_count,
        fired.threshold_window_ms,
    });
    try w.print(",\"observed_count\":{d}", .{fired.observed_count});
    if (fired.line.len > 0) {
        try w.writeAll(",\"line\":");
        try writeJsonString(&w, fired.line);
    }
    try w.writeByte('}');

    return w.buffered();
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

const testing = std.testing;

test "formatAlert: emits valid JSON with expected keys" {
    var buf: [1024]u8 = undefined;
    const fired: rules.Fired = .{
        .kind = .regex,
        .rule_id = "panic",
        .line = "panic at line 1",
        .file_path = "app.log",
        .threshold_count = 5,
        .threshold_window_ms = 60_000,
        .observed_count = 7,
    };
    const out = try formatAlert(&buf, fired, 1_700_000_000_000);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqualStrings("regex", obj.get("kind").?.string);
    try testing.expectEqualStrings("panic", obj.get("rule_id").?.string);
    try testing.expectEqualStrings("app.log", obj.get("file").?.string);
    try testing.expectEqualStrings("panic at line 1", obj.get("line").?.string);
    try testing.expectEqual(@as(i64, 1_700_000_000_000), obj.get("ts_ms").?.integer);
    try testing.expectEqual(@as(i64, 7), obj.get("observed_count").?.integer);

    const threshold = obj.get("threshold").?.object;
    try testing.expectEqual(@as(i64, 5), threshold.get("count").?.integer);
    try testing.expectEqual(@as(i64, 60_000), threshold.get("window_ms").?.integer);
}

test "formatAlert: silence alert omits empty line field" {
    var buf: [1024]u8 = undefined;
    const fired: rules.Fired = .{
        .kind = .silence,
        .rule_id = "silence",
        .line = "",
        .file_path = "a.log",
        .threshold_count = 0,
        .threshold_window_ms = 60_000,
        .observed_count = 0,
    };
    const out = try formatAlert(&buf, fired, 1_000);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();

    try testing.expect(!parsed.value.object.contains("line"));
}

test "formatAlert: escapes quotes, backslashes, and control bytes in line" {
    var buf: [1024]u8 = undefined;
    const fired: rules.Fired = .{
        .kind = .regex,
        .rule_id = "p",
        .line = "weird: \"q\" \\ \n \t end",
        .file_path = "a.log",
        .threshold_count = 1,
        .threshold_window_ms = 1_000,
        .observed_count = 1,
    };
    const out = try formatAlert(&buf, fired, 0);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();

    // The parser does the reverse-escape — round-tripping is the strongest
    // check that the encoder was correct.
    try testing.expectEqualStrings("weird: \"q\" \\ \n \t end", parsed.value.object.get("line").?.string);
}
