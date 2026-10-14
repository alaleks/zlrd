//! Atomic counters + Prometheus / JSON exposition for agent mode.
//!
//! All counters are monotonically increasing `u64`s held in
//! `std.atomic.Value`s, so updates from the watcher thread and reads from the
//! HTTP server thread don't need a mutex.

const std = @import("std");
const flags = @import("flags");

pub const RuleKind = enum {
    error_rate,
    regex,
    first_seen,
    silence,
    kernel_oom,
    kernel_segfault,
    kernel_panic,
    service_crash,
    service_stop,
    service_restart,

    pub fn label(self: RuleKind) []const u8 {
        return switch (self) {
            .error_rate => "error_rate",
            .regex => "regex",
            .first_seen => "first_seen",
            .silence => "silence",
            .kernel_oom => "kernel_oom",
            .kernel_segfault => "kernel_segfault",
            .kernel_panic => "kernel_panic",
            .service_crash => "service_crash",
            .service_stop => "service_stop",
            .service_restart => "service_restart",
        };
    }
};

pub const HttpRoute = enum {
    metrics,
    metrics_json,
    healthz,
    other,

    pub fn label(self: HttpRoute) []const u8 {
        return switch (self) {
            .metrics => "/metrics",
            .metrics_json => "/metrics.json",
            .healthz => "/healthz",
            .other => "other",
        };
    }
};

/// `zlrd_kernel_events_total{kind}`. Mirrors `kernel.KernelEvent.Kind`
/// without importing it, like `RuleKind` does.
pub const KernelKind = enum {
    oom,
    segfault,
    panic,
};

pub const ServiceEventKind = enum { crash, restart };

/// Services with their own `{service}` series. Matches `state.max_services`.
pub const max_services: usize = 64;

/// Per-service counters behind `zlrd_service_crashes_total` and
/// `zlrd_service_restarts_total`. Process-local, like every `_total` here:
/// they start at zero on each run and `rate()` takes care of the reset —
/// the lifetime numbers are in the state file.
pub const ServiceCounters = struct {
    name: []const u8,
    crashes: std.atomic.Value(u64) = .init(0),
    restarts: std.atomic.Value(u64) = .init(0),
};

/// The exposition uses these in the labels and rendering loops.
pub const level_labels = [_][]const u8{
    "trace", "debug", "info", "warn", "error", "fatal", "panic", "unknown",
};

const level_count = level_labels.len;
const rule_count = @typeInfo(RuleKind).@"enum".field_names.len;
const kernel_kind_count = @typeInfo(KernelKind).@"enum".field_names.len;
const route_count = @typeInfo(HttpRoute).@"enum".field_names.len;
/// HTTP status codes we surface explicitly. Any other status is bucketed into
/// the corresponding hundred (200/400/500). Keeps cardinality bounded.
pub const http_status_codes = [_]u16{ 200, 400, 401, 404, 500 };
const status_count = http_status_codes.len;

/// Process-wide metrics. Safe to share across threads — all fields are atomic.
pub const Metrics = struct {
    started_at_ms: i64,
    files_watched: std.atomic.Value(u64),
    lines_total: [level_count]std.atomic.Value(u64),
    bytes_total: std.atomic.Value(u64),
    alerts_fired_total: [rule_count]std.atomic.Value(u64),
    http_requests_total: [route_count][status_count]std.atomic.Value(u64),
    file_rotation_total: std.atomic.Value(u64),
    kernel_events_total: [kernel_kind_count]std.atomic.Value(u64),
    /// Registered before any thread starts and never changed after, so the
    /// readers need no lock: only the counters inside move.
    services: [max_services]ServiceCounters = undefined,
    service_count: usize = 0,
    /// `zlrd_build_info{version}`. Set by `agent.run`.
    version: []const u8 = "dev",

    pub fn init(now_ms: i64) Metrics {
        var m: Metrics = .{
            .started_at_ms = now_ms,
            .files_watched = .init(0),
            .lines_total = undefined,
            .bytes_total = .init(0),
            .alerts_fired_total = undefined,
            .http_requests_total = undefined,
            .file_rotation_total = .init(0),
            .kernel_events_total = undefined,
        };
        for (&m.kernel_events_total) |*c| c.* = .init(0);
        for (&m.lines_total) |*c| c.* = .init(0);
        for (&m.alerts_fired_total) |*c| c.* = .init(0);
        for (&m.http_requests_total) |*row| {
            for (row) |*c| c.* = .init(0);
        }
        return m;
    }

    pub fn setFilesWatched(self: *Metrics, n: u64) void {
        self.files_watched.store(n, .monotonic);
    }

    /// Records a line with optional detected level. `bytes` is the on-disk
    /// length of the line (no newline) — used to bump bytes_total.
    pub fn observeLine(self: *Metrics, level: ?flags.Level, bytes: u64) void {
        const idx = levelIndex(level);
        _ = self.lines_total[idx].fetchAdd(1, .monotonic);
        _ = self.bytes_total.fetchAdd(bytes, .monotonic);
    }

    pub fn observeAlert(self: *Metrics, kind: RuleKind) void {
        _ = self.alerts_fired_total[@backingInt(kind)].fetchAdd(1, .monotonic);
    }

    pub fn observeHttp(self: *Metrics, route: HttpRoute, status: u16) void {
        const route_idx = @backingInt(route);
        const code_idx = statusIndex(status);
        _ = self.http_requests_total[route_idx][code_idx].fetchAdd(1, .monotonic);
    }

    pub fn observeRotation(self: *Metrics) void {
        _ = self.file_rotation_total.fetchAdd(1, .monotonic);
    }

    /// Gives `name` its own series, at zero, so a service that has never
    /// crashed still shows up. Startup only — see `services`. `name` must
    /// outlive the metrics; duplicates and names past `max_services` are
    /// ignored.
    pub fn registerService(self: *Metrics, name: []const u8) void {
        if (self.findService(name) != null or self.service_count == max_services) return;
        self.services[self.service_count] = .{ .name = name };
        self.service_count += 1;
    }

    /// Counts a crash or restart. An unregistered name is dropped: every
    /// service the agent can see comes from `--service` or `--journal-unit`,
    /// and both are registered at startup.
    pub fn observeService(self: *Metrics, name: []const u8, kind: ServiceEventKind) void {
        const s = self.findService(name) orelse return;
        const c = switch (kind) {
            .crash => &s.crashes,
            .restart => &s.restarts,
        };
        _ = c.fetchAdd(1, .monotonic);
    }

    pub fn observeKernel(self: *Metrics, kind: KernelKind) void {
        _ = self.kernel_events_total[@backingInt(kind)].fetchAdd(1, .monotonic);
    }

    fn findService(self: *Metrics, name: []const u8) ?*ServiceCounters {
        for (self.services[0..self.service_count]) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    fn uptimeSeconds(self: *const Metrics, now_ms: i64) u64 {
        if (now_ms <= self.started_at_ms) return 0;
        return @intCast(@divTrunc(now_ms - self.started_at_ms, 1000));
    }
};

/// Maps an optional Level into the lines_total array slot.
fn levelIndex(level: ?flags.Level) usize {
    if (level) |l| return @backingInt(l);
    return level_count - 1; // "unknown" is the last slot
}

fn statusIndex(status: u16) usize {
    for (http_status_codes, 0..) |code, i| if (code == status) return i;
    // Bucket unknown codes into the closest "main" code we track.
    if (status < 300) return indexOfCode(200);
    if (status < 500) return indexOfCode(400);
    return indexOfCode(500);
}

fn indexOfCode(code: u16) usize {
    for (http_status_codes, 0..) |c, i| if (c == code) return i;
    unreachable;
}

/// Renders the Prometheus text exposition format (v0.0.4) into `writer`.
pub fn renderPrometheus(m: *const Metrics, writer: *std.Io.Writer, now_ms: i64) std.Io.Writer.Error!void {
    try writer.print("# HELP zlrd_up Whether the zlrd agent is up.\n", .{});
    try writer.print("# TYPE zlrd_up gauge\n", .{});
    try writer.print("zlrd_up 1\n", .{});

    try writer.print("# HELP zlrd_uptime_seconds Seconds since the agent started.\n", .{});
    try writer.print("# TYPE zlrd_uptime_seconds gauge\n", .{});
    try writer.print("zlrd_uptime_seconds {d}\n", .{m.uptimeSeconds(now_ms)});

    try writer.print("# HELP zlrd_files_watched Number of files the watcher is following.\n", .{});
    try writer.print("# TYPE zlrd_files_watched gauge\n", .{});
    try writer.print("zlrd_files_watched {d}\n", .{m.files_watched.load(.monotonic)});

    try writer.print("# HELP zlrd_lines_total Total log lines observed, by level.\n", .{});
    try writer.print("# TYPE zlrd_lines_total counter\n", .{});
    for (level_labels, 0..) |name, i| {
        try writer.print("zlrd_lines_total{{level=\"{s}\"}} {d}\n", .{ name, m.lines_total[i].load(.monotonic) });
    }

    try writer.print("# HELP zlrd_bytes_total Total bytes of log content observed.\n", .{});
    try writer.print("# TYPE zlrd_bytes_total counter\n", .{});
    try writer.print("zlrd_bytes_total {d}\n", .{m.bytes_total.load(.monotonic)});

    try writer.print("# HELP zlrd_alerts_fired_total Alerts fired, by rule kind.\n", .{});
    try writer.print("# TYPE zlrd_alerts_fired_total counter\n", .{});
    inline for (@typeInfo(RuleKind).@"enum".field_values) |value| {
        const kind: RuleKind = @fromBackingInt(@intCast(value));
        try writer.print("zlrd_alerts_fired_total{{rule=\"{s}\"}} {d}\n", .{
            kind.label(),
            m.alerts_fired_total[value].load(.monotonic),
        });
    }

    try writer.print("# HELP zlrd_http_requests_total HTTP requests served by the metrics endpoint.\n", .{});
    try writer.print("# TYPE zlrd_http_requests_total counter\n", .{});
    inline for (@typeInfo(HttpRoute).@"enum".field_values) |value| {
        const route: HttpRoute = @fromBackingInt(@intCast(value));
        for (http_status_codes, 0..) |code, ci| {
            try writer.print("zlrd_http_requests_total{{route=\"{s}\",code=\"{d}\"}} {d}\n", .{
                route.label(),
                code,
                m.http_requests_total[value][ci].load(.monotonic),
            });
        }
    }

    try writer.print("# HELP zlrd_file_rotation_total File truncations / rotations detected.\n", .{});
    try writer.print("# TYPE zlrd_file_rotation_total counter\n", .{});
    try writer.print("zlrd_file_rotation_total {d}\n", .{m.file_rotation_total.load(.monotonic)});

    try writer.writeAll("# HELP zlrd_service_crashes_total Crashes detected per service since the agent started.\n");
    try writer.writeAll("# TYPE zlrd_service_crashes_total counter\n");
    for (m.services[0..m.service_count]) |*s| {
        try writer.writeAll("zlrd_service_crashes_total{service=\"");
        try writeLabelValue(writer, s.name);
        try writer.print("\"}} {d}\n", .{s.crashes.load(.monotonic)});
    }

    try writer.writeAll("# HELP zlrd_service_restarts_total Restarts detected per service since the agent started.\n");
    try writer.writeAll("# TYPE zlrd_service_restarts_total counter\n");
    for (m.services[0..m.service_count]) |*s| {
        try writer.writeAll("zlrd_service_restarts_total{service=\"");
        try writeLabelValue(writer, s.name);
        try writer.print("\"}} {d}\n", .{s.restarts.load(.monotonic)});
    }

    try writer.writeAll("# HELP zlrd_kernel_events_total Kernel events seen, by kind.\n");
    try writer.writeAll("# TYPE zlrd_kernel_events_total counter\n");
    inline for (@typeInfo(KernelKind).@"enum".field_names, 0..) |name, i| {
        try writer.print("zlrd_kernel_events_total{{kind=\"{s}\"}} {d}\n", .{ name, m.kernel_events_total[i].load(.monotonic) });
    }

    try writer.writeAll("# HELP zlrd_build_info The running zlrd version.\n");
    try writer.writeAll("# TYPE zlrd_build_info gauge\n");
    try writer.writeAll("zlrd_build_info{version=\"");
    try writeLabelValue(writer, m.version);
    try writer.writeAll("\"} 1\n");
}

/// Prometheus label value escaping: backslash, double quote and newline.
fn writeLabelValue(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        '\n' => try w.writeAll("\\n"),
        else => try w.writeByte(c),
    };
}

/// Minimal JSON string body escaping for the names in `renderJson`.
fn writeJsonString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        0...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// Renders a JSON snapshot of all counters. Schema is documented in README.
pub fn renderJson(m: *const Metrics, writer: *std.Io.Writer, now_ms: i64) std.Io.Writer.Error!void {
    try writer.writeAll("{");
    try writer.print("\"uptime_seconds\":{d}", .{m.uptimeSeconds(now_ms)});
    try writer.print(",\"files_watched\":{d}", .{m.files_watched.load(.monotonic)});

    try writer.writeAll(",\"lines_total\":{");
    for (level_labels, 0..) |name, i| {
        if (i != 0) try writer.writeByte(',');
        try writer.print("\"{s}\":{d}", .{ name, m.lines_total[i].load(.monotonic) });
    }
    try writer.writeAll("}");

    try writer.print(",\"bytes_total\":{d}", .{m.bytes_total.load(.monotonic)});

    try writer.writeAll(",\"alerts_fired_total\":{");
    inline for (@typeInfo(RuleKind).@"enum".field_values, 0..) |value, i| {
        const kind: RuleKind = @fromBackingInt(@intCast(value));
        if (i != 0) try writer.writeByte(',');
        try writer.print("\"{s}\":{d}", .{ kind.label(), m.alerts_fired_total[value].load(.monotonic) });
    }
    try writer.writeAll("}");

    try writer.writeAll(",\"http_requests_total\":[");
    var first = true;
    inline for (@typeInfo(HttpRoute).@"enum".field_values) |value| {
        const route: HttpRoute = @fromBackingInt(@intCast(value));
        for (http_status_codes, 0..) |code, ci| {
            const v = m.http_requests_total[value][ci].load(.monotonic);
            if (v == 0) continue;
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print("{{\"route\":\"{s}\",\"code\":{d},\"count\":{d}}}", .{ route.label(), code, v });
        }
    }
    try writer.writeAll("]");

    try writer.print(",\"file_rotation_total\":{d}", .{m.file_rotation_total.load(.monotonic)});

    try writer.writeAll(",\"services\":{");
    for (m.services[0..m.service_count], 0..) |*s, i| {
        if (i != 0) try writer.writeByte(',');
        try writeJsonString(writer, s.name);
        try writer.print(":{{\"crashes\":{d},\"restarts\":{d}}}", .{ s.crashes.load(.monotonic), s.restarts.load(.monotonic) });
    }
    try writer.writeAll("}");

    try writer.writeAll(",\"kernel_events_total\":{");
    inline for (@typeInfo(KernelKind).@"enum".field_names, 0..) |name, i| {
        if (i != 0) try writer.writeByte(',');
        try writer.print("\"{s}\":{d}", .{ name, m.kernel_events_total[i].load(.monotonic) });
    }
    try writer.writeAll("}");

    try writer.writeAll(",\"version\":");
    try writeJsonString(writer, m.version);
    try writer.writeAll("}");
}

const testing = std.testing;

test "observeLine: known level increments matching bucket, unknown lands in 'unknown'" {
    var m = Metrics.init(0);
    m.observeLine(.Error, 42);
    m.observeLine(.Info, 10);
    m.observeLine(null, 5);
    m.observeLine(null, 0);
    try testing.expectEqual(@as(u64, 1), m.lines_total[@backingInt(flags.Level.Error)].load(.monotonic));
    try testing.expectEqual(@as(u64, 1), m.lines_total[@backingInt(flags.Level.Info)].load(.monotonic));
    try testing.expectEqual(@as(u64, 2), m.lines_total[level_count - 1].load(.monotonic));
    try testing.expectEqual(@as(u64, 57), m.bytes_total.load(.monotonic));
}

test "observeAlert: increments matching rule bucket" {
    var m = Metrics.init(0);
    m.observeAlert(.regex);
    m.observeAlert(.regex);
    m.observeAlert(.first_seen);
    try testing.expectEqual(@as(u64, 2), m.alerts_fired_total[@backingInt(RuleKind.regex)].load(.monotonic));
    try testing.expectEqual(@as(u64, 1), m.alerts_fired_total[@backingInt(RuleKind.first_seen)].load(.monotonic));
}

test "observeHttp: known and unknown codes" {
    var m = Metrics.init(0);
    m.observeHttp(.metrics, 200);
    m.observeHttp(.metrics, 401);
    m.observeHttp(.metrics, 503); // unknown -> bucketed into 500
    try testing.expectEqual(@as(u64, 1), m.http_requests_total[@backingInt(HttpRoute.metrics)][indexOfCode(200)].load(.monotonic));
    try testing.expectEqual(@as(u64, 1), m.http_requests_total[@backingInt(HttpRoute.metrics)][indexOfCode(401)].load(.monotonic));
    try testing.expectEqual(@as(u64, 1), m.http_requests_total[@backingInt(HttpRoute.metrics)][indexOfCode(500)].load(.monotonic));
}

test "renderPrometheus: contains expected metric lines" {
    var m = Metrics.init(0);
    m.setFilesWatched(3);
    m.observeLine(.Error, 100);
    m.observeAlert(.error_rate);

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try renderPrometheus(&m, &w, 1_500);

    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "zlrd_up 1\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zlrd_uptime_seconds 1\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zlrd_files_watched 3\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zlrd_lines_total{level=\"error\"} 1\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zlrd_lines_total{level=\"info\"} 0\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zlrd_alerts_fired_total{rule=\"error_rate\"} 1\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "# TYPE zlrd_lines_total counter\n") != null);
}

test "renderJson: valid JSON with expected keys" {
    var m = Metrics.init(0);
    m.observeHttp(.metrics_json, 200);

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try renderJson(&m, &w, 0);

    const out = w.buffered();
    // Parses cleanly.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(obj.contains("uptime_seconds"));
    try testing.expect(obj.contains("lines_total"));
    try testing.expect(obj.contains("alerts_fired_total"));
    try testing.expect(obj.contains("http_requests_total"));

    const http = obj.get("http_requests_total").?.array;
    try testing.expectEqual(@as(usize, 1), http.items.len);
    try testing.expectEqualStrings("/metrics.json", http.items[0].object.get("route").?.string);
    try testing.expectEqual(@as(i64, 200), http.items[0].object.get("code").?.integer);
    try testing.expectEqual(@as(i64, 1), http.items[0].object.get("count").?.integer);
}

test "service, kernel and build-info series" {
    var m = Metrics.init(0);
    m.version = "1.2.3";
    m.registerService("api");
    m.registerService("api"); // duplicate: one series
    m.registerService("odd\"name");
    m.observeService("api", .crash);
    m.observeService("api", .crash);
    m.observeService("api", .restart);
    m.observeService("ghost", .crash); // not registered: dropped
    m.observeKernel(.oom);

    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try renderPrometheus(&m, &w, 0);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "zlrd_service_crashes_total{service=\"api\"} 2\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zlrd_service_restarts_total{service=\"api\"} 1\n") != null);
    // A service that never crashed still has its series, at zero.
    try testing.expect(std.mem.indexOf(u8, out, "zlrd_service_crashes_total{service=\"odd\\\"name\"} 0\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ghost") == null);
    try testing.expect(std.mem.indexOf(u8, out, "zlrd_kernel_events_total{kind=\"oom\"} 1\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zlrd_kernel_events_total{kind=\"panic\"} 0\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "zlrd_build_info{version=\"1.2.3\"} 1\n") != null);

    var jbuf: [8192]u8 = undefined;
    var jw: std.Io.Writer = .fixed(&jbuf);
    try renderJson(&m, &jw, 0);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, jw.buffered(), .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 2), obj.get("services").?.object.get("api").?.object.get("crashes").?.integer);
    try testing.expect(obj.get("services").?.object.contains("odd\"name"));
    try testing.expectEqual(@as(i64, 1), obj.get("kernel_events_total").?.object.get("oom").?.integer);
    try testing.expectEqualStrings("1.2.3", obj.get("version").?.string);
}

test "registerService stops at max_services" {
    var m = Metrics.init(0);
    var names: [max_services + 1][8]u8 = undefined;
    for (&names, 0..) |*n, i| m.registerService(try std.fmt.bufPrint(n, "s{d}", .{i}));
    try testing.expectEqual(max_services, m.service_count);
}
