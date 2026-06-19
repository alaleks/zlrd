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
const kernel = @import("kernel");
const service = @import("service.zig");

/// Hooks set by the watcher / main loop so this file does not have to depend
/// on `webhook.zig` (which pulls in std.http). Set after construction.
pub const WebhookSender = *const fn (ctx: ?*anyopaque, url: []const u8, payload: []const u8) void;

/// Sidecar sink: three thunks that mirror the three dispatch entry points.
/// Set after construction via `setSidecarSink`. Implementations live in
/// `sidecar.zig` — they enqueue OTLP log records for async delivery.
pub const SidecarSink = struct {
    record_fired: *const fn (ctx: ?*anyopaque, fired: rules.Fired, now_ms: i64) void,
    record_kernel: *const fn (ctx: ?*anyopaque, ev: kernel.KernelEvent, now_ms: i64) void,
    record_service: *const fn (ctx: ?*anyopaque, ev: service.ServiceEvent, now_ms: i64) void,
    ctx: ?*anyopaque,
};

/// Thunk that adapts `Dispatcher.dispatchKernel` to the `kernel.Sink`
/// signature. `ctx` must be a `*Dispatcher`. Reads wall-clock ms internally
/// so callers don't have to thread `std.Io` through.
pub fn kernelSinkThunk(ctx: ?*anyopaque, event: kernel.KernelEvent) void {
    const d: *Dispatcher = @ptrCast(@alignCast(ctx orelse return));
    const now_ms = std.Io.Timestamp.now(d.io, .real).toMilliseconds();
    d.dispatchKernel(event, now_ms);
}

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
    sidecar_sink: ?SidecarSink,

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
            .sidecar_sink = null,
        };
    }

    pub fn setWebhookSender(self: *Dispatcher, sender: WebhookSender, ctx: ?*anyopaque) void {
        self.webhook_sender = sender;
        self.webhook_ctx = ctx;
    }

    pub fn setSidecarSink(self: *Dispatcher, sink: SidecarSink) void {
        self.sidecar_sink = sink;
    }

    pub fn deinit(self: *Dispatcher) void {
        if (self.file) |f| f.close(self.io);
        self.file = null;
    }

    pub fn shouldExit(self: *const Dispatcher) bool {
        return self.exit_flag.load(.monotonic);
    }

    /// Fan out a service-lifecycle event to the same sinks. Uses the
    /// service payload schema (`formatServiceEventJson`), which is distinct
    /// from rule alerts (no threshold/window, has stack_trace).
    pub fn dispatchService(self: *Dispatcher, event: service.ServiceEvent, now_ms: i64) void {
        const rule_kind: metrics.RuleKind = switch (event.kind) {
            .crash => .service_crash,
            .stop => .service_stop,
            .restart => .service_restart,
        };
        self.metrics.observeAlert(rule_kind);

        // Stack traces can run up to ~4 KiB; budget the payload accordingly.
        var buf: [8192]u8 = undefined;
        const payload = formatServiceEventJson(&buf, event, now_ms) catch return;

        // `.crash` is the only durability-critical kind here — `stop` and
        // `restart` are housekeeping that don't justify a per-record fsync.
        const sync_to_disk = event.kind == .crash;

        if (self.sinks.stderr) self.writeStderr(payload);
        if (self.file != null) self.writeFile(payload, sync_to_disk);
        if (self.webhook_sender) |send| {
            for (self.sinks.webhooks) |url| send(self.webhook_ctx, url, payload);
        }
        if (self.sidecar_sink) |sink| sink.record_service(sink.ctx, event, now_ms);
        if (self.alert_exit) self.exit_flag.store(true, .monotonic);
    }

    /// Fan out a kernel-level event to the same sinks. Distinct from
    /// `dispatch` because kernel events have their own payload schema
    /// (rendered by `kernel.formatEventJson`).
    pub fn dispatchKernel(self: *Dispatcher, event: kernel.KernelEvent, now_ms: i64) void {
        const rule_kind: metrics.RuleKind = switch (event.kind) {
            .oom => .kernel_oom,
            .segfault => .kernel_segfault,
            .panic_prev_boot => .kernel_panic,
        };
        self.metrics.observeAlert(rule_kind);

        var buf: [512]u8 = undefined;
        const payload = kernel.formatEventJson(&buf, event, now_ms) catch return;

        if (self.sinks.stderr) self.writeStderr(payload);
        // Every kernel event is durability-critical — the next instant may
        // be a panic that takes the box down.
        if (self.file != null) self.writeFile(payload, true);
        if (self.webhook_sender) |send| {
            for (self.sinks.webhooks) |url| send(self.webhook_ctx, url, payload);
        }
        if (self.sidecar_sink) |sink| sink.record_kernel(sink.ctx, event, now_ms);
        if (self.alert_exit) self.exit_flag.store(true, .monotonic);
    }

    /// Fan out a single fired rule to all enabled sinks. Each sink is
    /// best-effort: a failing webhook does not prevent the file/stderr write.
    pub fn dispatch(self: *Dispatcher, fired: rules.Fired, now_ms: i64) void {
        self.metrics.observeAlert(fired.kind);

        // Render once into a stack buffer, reuse for all sinks. 2 KiB covers
        // the per-line cap we already enforce upstream.
        var buf: [2048]u8 = undefined;
        const payload = formatAlert(&buf, fired, now_ms) catch return;

        // Rule alerts (error_rate, regex, first_seen, silence) don't earn
        // an fsync — they're statistical, not crash forensics. Skipping
        // the sync keeps the watcher thread unblocked under bursty match
        // rates on slow filesystems (NFS, etc.).
        if (self.sinks.stderr) self.writeStderr(payload);
        if (self.file != null) self.writeFile(payload, false);
        if (self.webhook_sender) |send| {
            for (self.sinks.webhooks) |url| {
                send(self.webhook_ctx, url, payload);
            }
        }
        if (self.sidecar_sink) |sink| sink.record_fired(sink.ctx, fired, now_ms);
        if (self.alert_exit) self.exit_flag.store(true, .monotonic);
    }

    fn writeStderr(self: *Dispatcher, payload: []const u8) void {
        const stderr = std.Io.File.stderr();
        stderr.writeStreamingAll(self.io, payload) catch return;
        stderr.writeStreamingAll(self.io, "\n") catch return;
    }

    fn writeFile(self: *Dispatcher, payload: []const u8, sync_to_disk: bool) void {
        const f = self.file orelse return;

        // Combine payload + newline into a single buffer so the write is one
        // syscall. The previous version did payload-then-newline; a transient
        // error between the two left a 1-byte gap that broke downstream
        // JSONL readers. 16 KiB is comfortably larger than every render
        // buffer the dispatchers use (8 KiB max for service events).
        var combined: [16 * 1024]u8 = undefined;
        if (payload.len + 1 > combined.len) return;
        @memcpy(combined[0..payload.len], payload);
        combined[payload.len] = '\n';
        const record = combined[0 .. payload.len + 1];

        self.file_mutex.lockUncancelable(self.io);
        defer self.file_mutex.unlock(self.io);
        f.writePositionalAll(self.io, record, self.file_offset) catch return;
        self.file_offset += record.len;
        // Only fsync when the caller asked — crash + kernel events. Rule
        // alerts skip the sync to keep the dispatcher thread unblocked on
        // slow filesystems (NFS measured ~50 ms per fsync).
        if (sync_to_disk) f.sync(self.io) catch {};
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

/// Renders a `ServiceEvent` as a single-line JSON document.
pub fn formatServiceEventJson(buf: []u8, event: service.ServiceEvent, now_ms: i64) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeByte('{');
    try w.print("\"ts_ms\":{d}", .{now_ms});
    try w.print(",\"kind\":\"{s}\"", .{event.kind.label()});
    try w.writeAll(",\"service\":");
    try writeJsonString(&w, event.service_name);
    try w.writeAll(",\"file\":");
    try writeJsonString(&w, event.file_path);
    if (event.marker.len > 0) {
        try w.writeAll(",\"marker\":");
        try writeJsonString(&w, event.marker);
    }
    if (event.pid) |p| try w.print(",\"pid\":{d}", .{p});
    try w.print(",\"crash_count\":{d}", .{event.crash_count});
    try w.print(",\"restart_count\":{d}", .{event.restart_count});
    if (event.detail.len > 0) {
        try w.writeAll(",\"detail\":");
        try writeJsonString(&w, event.detail);
    }
    if (event.stack_trace.len > 0) {
        try w.writeAll(",\"stack_trace\":");
        try writeJsonString(&w, event.stack_trace);
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
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            // ASCII printable excluding `"` (0x22) and `\\` (0x5c) which
            // are handled above as explicit escape arms.
            0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try w.writeByte(c),
            // Remaining controls + DEL + high bytes. Log payloads may
            // contain UTF-8 or stray control bytes; emit them as `\uXX` so
            // the JSON is always parseable downstream.
            else => try w.print("\\u{x:0>4}", .{c}),
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

test "formatServiceEventJson: crash with marker, pid, detail, stack_trace" {
    var buf: [2048]u8 = undefined;
    const ev: service.ServiceEvent = .{
        .kind = .crash,
        .service_name = "api",
        .file_path = "/var/log/api.log",
        .marker = "go_panic",
        .pid = 1234,
        .detail = "panic: nil pointer",
        .stack_trace = "\tmain.go:1\n\tmain.go:2\n",
        .crash_count = 1,
        .restart_count = 0,
    };
    const out = try formatServiceEventJson(&buf, ev, 1_700_000_000_000);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("service_crash", obj.get("kind").?.string);
    try testing.expectEqualStrings("api", obj.get("service").?.string);
    try testing.expectEqualStrings("go_panic", obj.get("marker").?.string);
    try testing.expectEqual(@as(i64, 1234), obj.get("pid").?.integer);
    try testing.expectEqualStrings("panic: nil pointer", obj.get("detail").?.string);
    try testing.expect(std.mem.indexOf(u8, obj.get("stack_trace").?.string, "main.go:1") != null);
}

test "formatServiceEventJson: stop event omits empty fields" {
    var buf: [512]u8 = undefined;
    const ev: service.ServiceEvent = .{
        .kind = .stop,
        .service_name = "x",
        .file_path = "/x.log",
        .marker = "",
        .pid = null,
        .detail = "",
        .stack_trace = "",
        .crash_count = 1,
        .restart_count = 0,
    };
    const out = try formatServiceEventJson(&buf, ev, 0);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("service_stop", obj.get("kind").?.string);
    try testing.expect(!obj.contains("marker"));
    try testing.expect(!obj.contains("pid"));
    try testing.expect(!obj.contains("detail"));
    try testing.expect(!obj.contains("stack_trace"));
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
