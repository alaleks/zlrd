//! Sidecar orchestrator: converts agent alerts/events into OTLP log records,
//! buffers them in a bounded queue, and periodically flushes them (plus a
//! metrics snapshot) to a remote OTLP/HTTP collector.
//!
//! Architecture:
//!   - Producers (watcher, journal, kernel-monitor threads) call
//!     `recordFired` / `recordService` / `recordKernel`. Each call clones the
//!     necessary strings into an arena, then pushes a `QueuedLog` onto the
//!     active queue under a short mutex.
//!   - The flush thread wakes on a timer (`flush_interval_ms`), swaps the
//!     active queue + arena with a fresh pair, then encodes the swapped-out
//!     batch into an OTLP `ExportLogsServiceRequest` and POSTs via the
//!     transport. Metrics are snapshotted at the same cadence and sent to
//!     `/v1/metrics`.
//!   - If the queue is full when a producer arrives, the event is dropped and
//!     `dropped_events` is incremented. The drop counter is itself exposed as
//!     a metric (`zlrd_sidecar_dropped_total`).
//!
//! Lifecycle: `init` → `start` (spawns flush thread) → `stop` (joins) →
//! `deinit`.

const std = @import("std");
const flags = @import("flags");
const sidecar = @import("sidecar");
const otlp = sidecar.otlp;
const transport = sidecar.transport;
const kernel = @import("kernel");

const rules = @import("rules.zig");
const service = @import("service.zig");
const metrics_mod = @import("metrics.zig");
const config_mod = @import("config.zig");

const log = std.log.scoped(.zlrd_sidecar);

pub const default_flush_interval_ms: u64 = 5_000;
pub const default_max_queue: usize = 1024;

/// Snapshot of an alert or event, with all string fields cloned into the
/// arena so the original data can be freed/overwritten by the producer.
const QueuedLog = struct {
    time_unix_nano: u64,
    severity: otlp.Severity,
    severity_text: []const u8,
    body: []const u8,
    /// Owned attribute slice (lives in arena alongside body).
    attrs: []otlp.Attr,
};

pub const Options = struct {
    /// OTLP/HTTP base URL — must be https://.
    base_url: []const u8,
    /// Extra HTTP headers (auth tokens, tenant IDs).
    headers: []const std.http.Header,
    /// Background flush cadence. Default 5s.
    flush_interval_ms: u64 = default_flush_interval_ms,
    /// Max events buffered between flushes. Default 1024.
    max_queue: usize = default_max_queue,
    /// Resource attributes attached to every batch (e.g. `host.name`,
    /// `service.instance.id`). The encoder always adds `service.name=zlrd`.
    resource_attrs: []const otlp.Attr = &.{},
    /// Metrics reference — snapshotted on every flush.
    metrics: *const metrics_mod.Metrics,
};

pub const Sidecar = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    transport: transport.Transport,
    flush_interval_ms: u64,
    max_queue: usize,
    metrics: *const metrics_mod.Metrics,

    /// Resource attrs always sent with each batch (owns the slice copy so the
    /// caller's storage can be transient).
    resource_attrs: []otlp.Attr,

    mutex: std.Io.Mutex = .init,
    /// Active producer-facing buffer + arena. Swapped under `mutex` at flush.
    active: Buffer,

    /// Set by `stop` — the flush thread observes it on each tick.
    shutdown: std.atomic.Value(bool) = .init(false),
    /// Number of events dropped because the queue was full since startup.
    dropped: std.atomic.Value(u64) = .init(0),
    /// Number of events successfully posted since startup.
    sent: std.atomic.Value(u64) = .init(0),
    /// Number of failed POSTs since startup (after retries exhausted).
    failed: std.atomic.Value(u64) = .init(0),

    thread: ?std.Thread = null,

    const Buffer = struct {
        arena: std.heap.ArenaAllocator,
        queue: std.ArrayList(QueuedLog),

        fn init(parent: std.mem.Allocator) Buffer {
            return .{
                .arena = std.heap.ArenaAllocator.init(parent),
                .queue = .empty,
            };
        }

        fn deinit(self: *Buffer, parent: std.mem.Allocator) void {
            self.queue.deinit(parent);
            self.arena.deinit();
        }
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, opts: Options) !Sidecar {
        var tr = try transport.Transport.init(allocator, io, .{
            .base_url = opts.base_url,
            .headers = opts.headers,
        });
        errdefer tr.deinit();

        const attrs_copy = try allocator.alloc(otlp.Attr, opts.resource_attrs.len);
        @memcpy(attrs_copy, opts.resource_attrs);

        return .{
            .allocator = allocator,
            .io = io,
            .transport = tr,
            .flush_interval_ms = opts.flush_interval_ms,
            .max_queue = opts.max_queue,
            .metrics = opts.metrics,
            .resource_attrs = attrs_copy,
            .active = Buffer.init(allocator),
        };
    }

    pub fn deinit(self: *Sidecar) void {
        self.active.deinit(self.allocator);
        self.allocator.free(self.resource_attrs);
        self.transport.deinit();
        self.* = undefined;
    }

    pub fn start(self: *Sidecar) !void {
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    /// Signals shutdown and joins the flush thread. Calls a final flush so
    /// in-flight events are not lost.
    pub fn stop(self: *Sidecar) void {
        self.shutdown.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.flushOnce();
    }

    // ─── Producer API ────────────────────────────────────────────────────

    /// Snapshot a fired rule into the queue. Safe to call from any thread.
    pub fn recordFired(self: *Sidecar, fired: rules.Fired, now_ms: i64) void {
        const severity: otlp.Severity = switch (fired.kind) {
            .silence => .warn,
            .first_seen => .info,
            else => .@"error",
        };

        var body_buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "alert {s}/{s} fired ({d}/{d} in {d}ms)", .{
            fired.kind.label(),
            fired.rule_id,
            fired.observed_count,
            fired.threshold_count,
            fired.threshold_window_ms,
        }) catch fired.rule_id;

        self.pushClone(
            timeNsFromMs(now_ms),
            severity,
            severityText(severity),
            body,
            &.{
                .{ .key = "alert.kind", .value = .{ .string = fired.kind.label() } },
                .{ .key = "alert.rule_id", .value = .{ .string = fired.rule_id } },
                .{ .key = "log.file.path", .value = .{ .string = fired.file_path } },
                .{ .key = "alert.threshold_count", .value = .{ .int = @intCast(fired.threshold_count) } },
                .{ .key = "alert.threshold_window_ms", .value = .{ .int = @intCast(fired.threshold_window_ms) } },
                .{ .key = "alert.observed_count", .value = .{ .int = @intCast(fired.observed_count) } },
                .{ .key = "log.line", .value = .{ .string = fired.line } },
            },
        );
    }

    pub fn recordService(self: *Sidecar, ev: service.ServiceEvent, now_ms: i64) void {
        const severity: otlp.Severity = switch (ev.kind) {
            .crash => .@"error",
            else => .info,
        };
        const body = if (ev.detail.len > 0) ev.detail else ev.kind.label();

        var attrs_buf: [10]otlp.Attr = undefined;
        var n: usize = 0;
        attrs_buf[n] = .{ .key = "event.kind", .value = .{ .string = ev.kind.label() } };
        n += 1;
        attrs_buf[n] = .{ .key = "service.name", .value = .{ .string = ev.service_name } };
        n += 1;
        attrs_buf[n] = .{ .key = "log.file.path", .value = .{ .string = ev.file_path } };
        n += 1;
        if (ev.marker.len > 0) {
            attrs_buf[n] = .{ .key = "crash.marker", .value = .{ .string = ev.marker } };
            n += 1;
        }
        if (ev.pid) |p| {
            attrs_buf[n] = .{ .key = "process.pid", .value = .{ .int = @intCast(p) } };
            n += 1;
        }
        if (ev.stack_trace.len > 0) {
            attrs_buf[n] = .{ .key = "exception.stacktrace", .value = .{ .string = ev.stack_trace } };
            n += 1;
        }
        attrs_buf[n] = .{ .key = "service.crash_count", .value = .{ .int = @intCast(ev.crash_count) } };
        n += 1;
        attrs_buf[n] = .{ .key = "service.restart_count", .value = .{ .int = @intCast(ev.restart_count) } };
        n += 1;

        self.pushClone(timeNsFromMs(now_ms), severity, severityText(severity), body, attrs_buf[0..n]);
    }

    pub fn recordKernel(self: *Sidecar, ev: kernel.KernelEvent, now_ms: i64) void {
        const severity: otlp.Severity = switch (ev.kind) {
            .panic_prev_boot => .fatal,
            else => .@"error",
        };
        const body = ev.detailSlice();

        var attrs_buf: [6]otlp.Attr = undefined;
        var n: usize = 0;
        attrs_buf[n] = .{ .key = "event.kind", .value = .{ .string = ev.kind.label() } };
        n += 1;
        attrs_buf[n] = .{ .key = "kernel.source", .value = .{ .string = ev.source.label() } };
        n += 1;
        if (ev.pid != 0) {
            attrs_buf[n] = .{ .key = "process.pid", .value = .{ .int = @intCast(ev.pid) } };
            n += 1;
        }
        const comm = ev.commSlice();
        if (comm.len > 0) {
            attrs_buf[n] = .{ .key = "process.executable.name", .value = .{ .string = comm } };
            n += 1;
        }

        self.pushClone(timeNsFromMs(now_ms), severity, severityText(severity), body, attrs_buf[0..n]);
    }

    // ─── Internals ───────────────────────────────────────────────────────

    fn pushClone(
        self: *Sidecar,
        time_ns: u64,
        severity: otlp.Severity,
        severity_text: []const u8,
        body: []const u8,
        attrs_in: []const otlp.Attr,
    ) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.active.queue.items.len >= self.max_queue) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        }

        const arena_alloc = self.active.arena.allocator();
        const body_copy = arena_alloc.dupe(u8, body) catch {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        };

        const attrs_copy = arena_alloc.alloc(otlp.Attr, attrs_in.len) catch {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        };
        for (attrs_in, 0..) |a, i| {
            const key_copy = arena_alloc.dupe(u8, a.key) catch {
                _ = self.dropped.fetchAdd(1, .monotonic);
                return;
            };
            const value_copy: otlp.Value = switch (a.value) {
                .string => |s| .{ .string = arena_alloc.dupe(u8, s) catch {
                    _ = self.dropped.fetchAdd(1, .monotonic);
                    return;
                } },
                .int => |n| .{ .int = n },
                .bool => |b| .{ .bool = b },
            };
            attrs_copy[i] = .{ .key = key_copy, .value = value_copy };
        }

        self.active.queue.append(self.allocator, .{
            .time_unix_nano = time_ns,
            .severity = severity,
            .severity_text = severity_text,
            .body = body_copy,
            .attrs = attrs_copy,
        }) catch {
            _ = self.dropped.fetchAdd(1, .monotonic);
        };
    }

    fn runLoop(self: *Sidecar) void {
        while (!self.shutdown.load(.acquire)) {
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(@intCast(self.flush_interval_ms)), .awake) catch break;
            self.flushOnce();
        }
    }

    fn flushOnce(self: *Sidecar) void {
        // Swap the producer buffer under the lock so producers can't see a
        // partially-drained queue.
        var stale = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const old = self.active;
            self.active = Buffer.init(self.allocator);
            break :blk old;
        };
        defer stale.deinit(self.allocator);

        if (stale.queue.items.len > 0) {
            self.sendLogs(stale.queue.items);
        }
        self.sendMetrics();
    }

    fn sendLogs(self: *Sidecar, items: []const QueuedLog) void {
        // Map QueuedLog → otlp.LogRecord. Slices are already in the stale arena.
        const records = self.allocator.alloc(otlp.LogRecord, items.len) catch {
            _ = self.failed.fetchAdd(1, .monotonic);
            return;
        };
        defer self.allocator.free(records);
        for (items, 0..) |q, i| {
            records[i] = .{
                .time_unix_nano = q.time_unix_nano,
                .severity = q.severity,
                .severity_text = q.severity_text,
                .body = q.body,
                .attrs = q.attrs,
            };
        }

        const payload = otlp.encodeLogsRequest(self.allocator, self.resource_attrs, records) catch {
            _ = self.failed.fetchAdd(1, .monotonic);
            return;
        };
        defer self.allocator.free(payload);

        if (self.transport.send(.logs, payload)) {
            _ = self.sent.fetchAdd(@intCast(items.len), .monotonic);
        } else {
            _ = self.failed.fetchAdd(1, .monotonic);
        }
    }

    fn sendMetrics(self: *Sidecar) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var points = std.ArrayList(otlp.MetricPoint).empty;
        const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        const now_ns = timeNsFromMs(now_ms);
        const start_ns = timeNsFromMs(self.metrics.started_at_ms);

        addCounters(a, &points, self.metrics, now_ns, start_ns) catch {
            _ = self.failed.fetchAdd(1, .monotonic);
            return;
        };
        addSidecarSelfMetrics(a, &points, self, now_ns, start_ns) catch {
            _ = self.failed.fetchAdd(1, .monotonic);
            return;
        };

        const payload = otlp.encodeMetricsRequest(self.allocator, self.resource_attrs, points.items) catch {
            _ = self.failed.fetchAdd(1, .monotonic);
            return;
        };
        defer self.allocator.free(payload);

        if (!self.transport.send(.metrics, payload)) {
            _ = self.failed.fetchAdd(1, .monotonic);
        }
    }
};

fn timeNsFromMs(ms: i64) u64 {
    if (ms <= 0) return 0;
    return @as(u64, @intCast(ms)) *% 1_000_000;
}

fn severityText(s: otlp.Severity) []const u8 {
    return switch (s) {
        .info => "INFO",
        .warn => "WARN",
        .@"error" => "ERROR",
        .fatal => "FATAL",
    };
}

fn addCounters(
    a: std.mem.Allocator,
    points: *std.ArrayList(otlp.MetricPoint),
    m: *const metrics_mod.Metrics,
    now_ns: u64,
    start_ns: u64,
) !void {
    // Per-level line counters → Sum/CUMULATIVE with `level` attribute.
    for (metrics_mod.level_labels, 0..) |level_label, i| {
        const attrs = try a.alloc(otlp.Attr, 1);
        attrs[0] = .{ .key = "level", .value = .{ .string = level_label } };
        try points.append(a, .{
            .name = "zlrd_lines_total",
            .description = "Total log lines observed, by level.",
            .is_monotonic = true,
            .time_unix_nano = now_ns,
            .start_time_unix_nano = start_ns,
            .value = @intCast(m.lines_total[i].load(.monotonic)),
            .attrs = attrs,
        });
    }

    // Per-rule alert counters.
    const rule_fields = @typeInfo(metrics_mod.RuleKind).@"enum".fields;
    inline for (rule_fields) |f| {
        const kind: metrics_mod.RuleKind = @enumFromInt(f.value);
        const attrs = try a.alloc(otlp.Attr, 1);
        attrs[0] = .{ .key = "rule", .value = .{ .string = kind.label() } };
        try points.append(a, .{
            .name = "zlrd_alerts_fired_total",
            .description = "Alerts fired, by rule kind.",
            .is_monotonic = true,
            .time_unix_nano = now_ns,
            .start_time_unix_nano = start_ns,
            .value = @intCast(m.alerts_fired_total[f.value].load(.monotonic)),
            .attrs = attrs,
        });
    }

    try points.append(a, .{
        .name = "zlrd_bytes_total",
        .description = "Total bytes of log content observed.",
        .is_monotonic = true,
        .time_unix_nano = now_ns,
        .start_time_unix_nano = start_ns,
        .value = @intCast(m.bytes_total.load(.monotonic)),
        .attrs = &.{},
    });
    try points.append(a, .{
        .name = "zlrd_file_rotation_total",
        .description = "File truncations / rotations detected.",
        .is_monotonic = true,
        .time_unix_nano = now_ns,
        .start_time_unix_nano = start_ns,
        .value = @intCast(m.file_rotation_total.load(.monotonic)),
        .attrs = &.{},
    });
    try points.append(a, .{
        .name = "zlrd_files_watched",
        .description = "Number of files the watcher is following.",
        .is_monotonic = false,
        .time_unix_nano = now_ns,
        .start_time_unix_nano = start_ns,
        .value = @intCast(m.files_watched.load(.monotonic)),
        .attrs = &.{},
    });

    const uptime_seconds: u64 = if (now_ns > start_ns) (now_ns - start_ns) / 1_000_000_000 else 0;
    try points.append(a, .{
        .name = "zlrd_uptime_seconds",
        .description = "Seconds since the agent started.",
        .is_monotonic = false,
        .time_unix_nano = now_ns,
        .start_time_unix_nano = start_ns,
        .value = @intCast(uptime_seconds),
        .attrs = &.{},
    });
}

fn addSidecarSelfMetrics(
    a: std.mem.Allocator,
    points: *std.ArrayList(otlp.MetricPoint),
    s: *const Sidecar,
    now_ns: u64,
    start_ns: u64,
) !void {
    try points.append(a, .{
        .name = "zlrd_sidecar_sent_total",
        .description = "Log records successfully POSTed to the collector.",
        .is_monotonic = true,
        .time_unix_nano = now_ns,
        .start_time_unix_nano = start_ns,
        .value = @intCast(s.sent.load(.monotonic)),
        .attrs = &.{},
    });
    try points.append(a, .{
        .name = "zlrd_sidecar_dropped_total",
        .description = "Events dropped because the queue was full.",
        .is_monotonic = true,
        .time_unix_nano = now_ns,
        .start_time_unix_nano = start_ns,
        .value = @intCast(s.dropped.load(.monotonic)),
        .attrs = &.{},
    });
    try points.append(a, .{
        .name = "zlrd_sidecar_failed_total",
        .description = "Failed POSTs after exhausting retries.",
        .is_monotonic = true,
        .time_unix_nano = now_ns,
        .start_time_unix_nano = start_ns,
        .value = @intCast(s.failed.load(.monotonic)),
        .attrs = &.{},
    });
}

// ─── Sink thunks ──────────────────────────────────────────────────────────

pub fn recordFiredThunk(ctx: ?*anyopaque, fired: rules.Fired, now_ms: i64) void {
    const s: *Sidecar = @ptrCast(@alignCast(ctx orelse return));
    s.recordFired(fired, now_ms);
}

pub fn recordServiceThunk(ctx: ?*anyopaque, ev: service.ServiceEvent, now_ms: i64) void {
    const s: *Sidecar = @ptrCast(@alignCast(ctx orelse return));
    s.recordService(ev, now_ms);
}

pub fn recordKernelThunk(ctx: ?*anyopaque, ev: kernel.KernelEvent, now_ms: i64) void {
    const s: *Sidecar = @ptrCast(@alignCast(ctx orelse return));
    s.recordKernel(ev, now_ms);
}

// ─── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "timeNsFromMs: zero stays zero, positive scales by 1e6" {
    try testing.expectEqual(@as(u64, 0), timeNsFromMs(0));
    try testing.expectEqual(@as(u64, 0), timeNsFromMs(-1));
    try testing.expectEqual(@as(u64, 1_000_000), timeNsFromMs(1));
    try testing.expectEqual(@as(u64, 1_700_000_000_000_000_000), timeNsFromMs(1_700_000_000_000));
}

test "severityText: covers all variants" {
    try testing.expectEqualStrings("INFO", severityText(.info));
    try testing.expectEqualStrings("WARN", severityText(.warn));
    try testing.expectEqualStrings("ERROR", severityText(.@"error"));
    try testing.expectEqualStrings("FATAL", severityText(.fatal));
}

test "addCounters: emits one metric per level and per rule kind" {
    var m = metrics_mod.Metrics.init(1_000);
    m.observeLine(.Error, 10);
    m.observeAlert(.regex);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var points = std.ArrayList(otlp.MetricPoint).empty;

    try addCounters(arena.allocator(), &points, &m, 2_000_000_000, 1_000_000_000);

    const rule_count = @typeInfo(metrics_mod.RuleKind).@"enum".fields.len;
    const expected_min = metrics_mod.level_labels.len + rule_count + 4; // 4 scalars
    try testing.expect(points.items.len == expected_min);

    // Check that at least one of the points has the expected rule attribute.
    var found_regex_rule = false;
    for (points.items) |p| {
        if (!std.mem.eql(u8, p.name, "zlrd_alerts_fired_total")) continue;
        for (p.attrs) |a| {
            if (std.mem.eql(u8, a.key, "rule")) {
                if (std.mem.eql(u8, a.value.string, "regex")) found_regex_rule = true;
            }
        }
    }
    try testing.expect(found_regex_rule);
}
