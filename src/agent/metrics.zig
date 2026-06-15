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

    pub fn label(self: RuleKind) []const u8 {
        return switch (self) {
            .error_rate => "error_rate",
            .regex => "regex",
            .first_seen => "first_seen",
            .silence => "silence",
            .kernel_oom => "kernel_oom",
            .kernel_segfault => "kernel_segfault",
            .kernel_panic => "kernel_panic",
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

/// The exposition uses these in the labels and rendering loops.
pub const level_labels = [_][]const u8{
    "trace", "debug", "info", "warn", "error", "fatal", "panic", "unknown",
};

const level_count = level_labels.len;
const rule_count = @typeInfo(RuleKind).@"enum".fields.len;
const route_count = @typeInfo(HttpRoute).@"enum".fields.len;
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

    pub fn init(now_ms: i64) Metrics {
        var m: Metrics = .{
            .started_at_ms = now_ms,
            .files_watched = .init(0),
            .lines_total = undefined,
            .bytes_total = .init(0),
            .alerts_fired_total = undefined,
            .http_requests_total = undefined,
            .file_rotation_total = .init(0),
        };
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
        _ = self.alerts_fired_total[@intFromEnum(kind)].fetchAdd(1, .monotonic);
    }

    pub fn observeHttp(self: *Metrics, route: HttpRoute, status: u16) void {
        const route_idx = @intFromEnum(route);
        const code_idx = statusIndex(status);
        _ = self.http_requests_total[route_idx][code_idx].fetchAdd(1, .monotonic);
    }

    pub fn observeRotation(self: *Metrics) void {
        _ = self.file_rotation_total.fetchAdd(1, .monotonic);
    }

    fn uptimeSeconds(self: *const Metrics, now_ms: i64) u64 {
        if (now_ms <= self.started_at_ms) return 0;
        return @intCast(@divTrunc(now_ms - self.started_at_ms, 1000));
    }
};

/// Maps an optional Level into the lines_total array slot.
fn levelIndex(level: ?flags.Level) usize {
    if (level) |l| return @intFromEnum(l);
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
    inline for (@typeInfo(RuleKind).@"enum".fields) |f| {
        const kind: RuleKind = @enumFromInt(f.value);
        try writer.print("zlrd_alerts_fired_total{{rule=\"{s}\"}} {d}\n", .{
            kind.label(),
            m.alerts_fired_total[f.value].load(.monotonic),
        });
    }

    try writer.print("# HELP zlrd_http_requests_total HTTP requests served by the metrics endpoint.\n", .{});
    try writer.print("# TYPE zlrd_http_requests_total counter\n", .{});
    inline for (@typeInfo(HttpRoute).@"enum".fields) |rf| {
        const route: HttpRoute = @enumFromInt(rf.value);
        for (http_status_codes, 0..) |code, ci| {
            try writer.print("zlrd_http_requests_total{{route=\"{s}\",code=\"{d}\"}} {d}\n", .{
                route.label(),
                code,
                m.http_requests_total[rf.value][ci].load(.monotonic),
            });
        }
    }

    try writer.print("# HELP zlrd_file_rotation_total File truncations / rotations detected.\n", .{});
    try writer.print("# TYPE zlrd_file_rotation_total counter\n", .{});
    try writer.print("zlrd_file_rotation_total {d}\n", .{m.file_rotation_total.load(.monotonic)});
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
    inline for (@typeInfo(RuleKind).@"enum".fields, 0..) |f, i| {
        const kind: RuleKind = @enumFromInt(f.value);
        if (i != 0) try writer.writeByte(',');
        try writer.print("\"{s}\":{d}", .{ kind.label(), m.alerts_fired_total[f.value].load(.monotonic) });
    }
    try writer.writeAll("}");

    try writer.writeAll(",\"http_requests_total\":[");
    var first = true;
    inline for (@typeInfo(HttpRoute).@"enum".fields) |rf| {
        const route: HttpRoute = @enumFromInt(rf.value);
        for (http_status_codes, 0..) |code, ci| {
            const v = m.http_requests_total[rf.value][ci].load(.monotonic);
            if (v == 0) continue;
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print("{{\"route\":\"{s}\",\"code\":{d},\"count\":{d}}}", .{ route.label(), code, v });
        }
    }
    try writer.writeAll("]");

    try writer.print(",\"file_rotation_total\":{d}", .{m.file_rotation_total.load(.monotonic)});
    try writer.writeAll("}");
}

const testing = std.testing;

test "observeLine: known level increments matching bucket, unknown lands in 'unknown'" {
    var m = Metrics.init(0);
    m.observeLine(.Error, 42);
    m.observeLine(.Info, 10);
    m.observeLine(null, 5);
    m.observeLine(null, 0);
    try testing.expectEqual(@as(u64, 1), m.lines_total[@intFromEnum(flags.Level.Error)].load(.monotonic));
    try testing.expectEqual(@as(u64, 1), m.lines_total[@intFromEnum(flags.Level.Info)].load(.monotonic));
    try testing.expectEqual(@as(u64, 2), m.lines_total[level_count - 1].load(.monotonic));
    try testing.expectEqual(@as(u64, 57), m.bytes_total.load(.monotonic));
}

test "observeAlert: increments matching rule bucket" {
    var m = Metrics.init(0);
    m.observeAlert(.regex);
    m.observeAlert(.regex);
    m.observeAlert(.first_seen);
    try testing.expectEqual(@as(u64, 2), m.alerts_fired_total[@intFromEnum(RuleKind.regex)].load(.monotonic));
    try testing.expectEqual(@as(u64, 1), m.alerts_fired_total[@intFromEnum(RuleKind.first_seen)].load(.monotonic));
}

test "observeHttp: known and unknown codes" {
    var m = Metrics.init(0);
    m.observeHttp(.metrics, 200);
    m.observeHttp(.metrics, 401);
    m.observeHttp(.metrics, 503); // unknown -> bucketed into 500
    try testing.expectEqual(@as(u64, 1), m.http_requests_total[@intFromEnum(HttpRoute.metrics)][indexOfCode(200)].load(.monotonic));
    try testing.expectEqual(@as(u64, 1), m.http_requests_total[@intFromEnum(HttpRoute.metrics)][indexOfCode(401)].load(.monotonic));
    try testing.expectEqual(@as(u64, 1), m.http_requests_total[@intFromEnum(HttpRoute.metrics)][indexOfCode(500)].load(.monotonic));
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
