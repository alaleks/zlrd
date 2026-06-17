//! OTLP/HTTP encoders for logs and metrics. Builds Export*ServiceRequest
//! protobuf payloads using the wire-format helpers in `protobuf.zig`.
//!
//! The encoder accepts neutral input types (`LogRecord`, `MetricPoint`) so
//! agent + kernel modules don't have to know about OTLP. Translation from
//! agent event types lives in `sidecar.zig`.
//!
//! Schema reference: opentelemetry-proto v1.0
//!   - logs:    opentelemetry/proto/logs/v1/logs.proto
//!   - metrics: opentelemetry/proto/metrics/v1/metrics.proto
//!   - common:  opentelemetry/proto/common/v1/common.proto

const std = @import("std");
const pb = @import("protobuf.zig");

pub const scope_name = "zlrd";

/// OTLP SeverityNumber enum values used by the agent. The full spec defines
/// 0–24; we only need INFO, WARN, ERROR, FATAL.
pub const Severity = enum(u32) {
    info = 9,
    warn = 13,
    @"error" = 17,
    fatal = 21,
};

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    bool: bool,
};

pub const Attr = struct {
    key: []const u8,
    value: Value,
};

/// A neutral log event. Slices are borrowed — they must remain valid until
/// `encodeLogsRequest` returns.
pub const LogRecord = struct {
    time_unix_nano: u64,
    severity: Severity,
    severity_text: []const u8,
    body: []const u8,
    attrs: []const Attr,
};

/// One datapoint of a single metric. `is_monotonic = true` selects Sum (with
/// CUMULATIVE temporality); `false` selects Gauge. Counters use Sum, the
/// process snapshot gauges (`uptime_seconds`, `files_watched`) use Gauge.
pub const MetricPoint = struct {
    name: []const u8,
    description: []const u8 = "",
    unit: []const u8 = "",
    is_monotonic: bool,
    time_unix_nano: u64,
    start_time_unix_nano: u64,
    value: i64,
    attrs: []const Attr,
};

// ─── KeyValue + AnyValue ──────────────────────────────────────────────────

fn encodeAnyValue(enc: *pb.Encoder, value: Value) !void {
    switch (value) {
        .string => |s| try enc.writeStringField(1, s),
        .bool => |b| try enc.writeVarintField(2, if (b) 1 else 0),
        .int => |i| try enc.writeVarintField(3, @as(u64, @bitCast(i))),
    }
}

fn encodeKeyValue(enc: *pb.Encoder, field_number: u32, attr: Attr) !void {
    const kv = try enc.beginMessage(field_number);
    try enc.writeStringField(1, attr.key);
    {
        const av = try enc.beginMessage(2);
        try encodeAnyValue(enc, attr.value);
        enc.endMessage(av);
    }
    enc.endMessage(kv);
}

// ─── LogRecord ────────────────────────────────────────────────────────────

fn encodeLogRecord(enc: *pb.Encoder, record: LogRecord) !void {
    const lr = try enc.beginMessage(2); // ScopeLogs.log_records = 2

    try enc.writeFixed64Field(1, record.time_unix_nano);
    try enc.writeVarintField(2, @intFromEnum(record.severity));
    if (record.severity_text.len > 0) try enc.writeStringField(3, record.severity_text);

    // body is an AnyValue (string variant).
    {
        const body = try enc.beginMessage(5);
        try enc.writeStringField(1, record.body);
        enc.endMessage(body);
    }

    for (record.attrs) |attr| try encodeKeyValue(enc, 6, attr);
    try enc.writeFixed64Field(11, record.time_unix_nano); // observed_time

    enc.endMessage(lr);
}

/// Encodes an `ExportLogsServiceRequest` carrying a single ResourceLogs +
/// ScopeLogs. Caller owns the returned slice.
pub fn encodeLogsRequest(
    allocator: std.mem.Allocator,
    resource_attrs: []const Attr,
    records: []const LogRecord,
) ![]u8 {
    var enc = pb.Encoder.init(allocator);
    errdefer enc.deinit();

    // ExportLogsServiceRequest.resource_logs = 1
    const rl = try enc.beginMessage(1);

    // ResourceLogs.resource = 1
    {
        const res = try enc.beginMessage(1);
        for (resource_attrs) |attr| try encodeKeyValue(&enc, 1, attr);
        enc.endMessage(res);
    }

    // ResourceLogs.scope_logs = 2
    {
        const sl = try enc.beginMessage(2);

        // ScopeLogs.scope = 1 (InstrumentationScope)
        {
            const scope = try enc.beginMessage(1);
            try enc.writeStringField(1, scope_name);
            enc.endMessage(scope);
        }

        for (records) |record| try encodeLogRecord(&enc, record);
        enc.endMessage(sl);
    }

    enc.endMessage(rl);
    return enc.toOwnedSlice();
}

// ─── Metrics ──────────────────────────────────────────────────────────────

fn encodeNumberDataPoint(enc: *pb.Encoder, point: MetricPoint) !void {
    // Sum.data_points = 1 / Gauge.data_points = 1
    const dp = try enc.beginMessage(1);
    for (point.attrs) |attr| try encodeKeyValue(enc, 7, attr);
    try enc.writeFixed64Field(2, point.start_time_unix_nano);
    try enc.writeFixed64Field(3, point.time_unix_nano);
    // NumberDataPoint.as_int = 6 (sfixed64 — fixed 8 LE, signed bit-cast)
    try enc.writeFixed64Field(6, @as(u64, @bitCast(point.value)));
    enc.endMessage(dp);
}

fn encodeMetric(enc: *pb.Encoder, point: MetricPoint) !void {
    // ScopeMetrics.metrics = 2
    const m = try enc.beginMessage(2);
    try enc.writeStringField(1, point.name);
    if (point.description.len > 0) try enc.writeStringField(2, point.description);
    if (point.unit.len > 0) try enc.writeStringField(3, point.unit);

    if (point.is_monotonic) {
        // Metric.sum = 7
        const sum = try enc.beginMessage(7);
        try encodeNumberDataPoint(enc, point);
        try enc.writeVarintField(2, 2); // aggregation_temporality = CUMULATIVE
        try enc.writeVarintField(3, 1); // is_monotonic = true
        enc.endMessage(sum);
    } else {
        // Metric.gauge = 5
        const gauge = try enc.beginMessage(5);
        try encodeNumberDataPoint(enc, point);
        enc.endMessage(gauge);
    }
    enc.endMessage(m);
}

/// Encodes an `ExportMetricsServiceRequest` carrying a single ResourceMetrics
/// + ScopeMetrics. Caller owns the returned slice.
pub fn encodeMetricsRequest(
    allocator: std.mem.Allocator,
    resource_attrs: []const Attr,
    points: []const MetricPoint,
) ![]u8 {
    var enc = pb.Encoder.init(allocator);
    errdefer enc.deinit();

    // ExportMetricsServiceRequest.resource_metrics = 1
    const rm = try enc.beginMessage(1);

    // ResourceMetrics.resource = 1
    {
        const res = try enc.beginMessage(1);
        for (resource_attrs) |attr| try encodeKeyValue(&enc, 1, attr);
        enc.endMessage(res);
    }

    // ResourceMetrics.scope_metrics = 2
    {
        const sm = try enc.beginMessage(2);
        {
            const scope = try enc.beginMessage(1);
            try enc.writeStringField(1, scope_name);
            enc.endMessage(scope);
        }
        for (points) |p| try encodeMetric(&enc, p);
        enc.endMessage(sm);
    }

    enc.endMessage(rm);
    return enc.toOwnedSlice();
}

// ─── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Walks `payload` looking for a length-delimited field at `field_number` at
/// the top level. Returns the value bytes. Test helper only.
fn findLenField(payload: []const u8, field_number: u32) ?[]const u8 {
    var i: usize = 0;
    while (i < payload.len) {
        var tag: u64 = 0;
        var shift: u6 = 0;
        while (i < payload.len) {
            const byte = payload[i];
            i += 1;
            tag |= @as(u64, byte & 0x7f) << shift;
            if (byte & 0x80 == 0) break;
            shift += 7;
        }
        const fn_seen: u32 = @intCast(tag >> 3);
        const wire: u3 = @intCast(tag & 0x7);

        if (wire == 0) { // varint
            while (i < payload.len) : (i += 1) if (payload[i] & 0x80 == 0) break;
            i += 1;
        } else if (wire == 1) { // i64
            i += 8;
        } else if (wire == 2) { // LEN
            var len: u64 = 0;
            shift = 0;
            while (i < payload.len) {
                const byte = payload[i];
                i += 1;
                len |= @as(u64, byte & 0x7f) << shift;
                if (byte & 0x80 == 0) break;
                shift += 7;
            }
            if (fn_seen == field_number) return payload[i .. i + len];
            i += @intCast(len);
        } else if (wire == 5) { // i32
            i += 4;
        } else return null;
    }
    return null;
}

test "encodeLogsRequest: structure is decodable and contains body" {
    const attrs: [1]Attr = .{.{ .key = "service.name", .value = .{ .string = "zlrd" } }};
    const log_attrs: [1]Attr = .{.{ .key = "rule", .value = .{ .string = "error_rate" } }};
    const records: [1]LogRecord = .{.{
        .time_unix_nano = 1_700_000_000_000_000_000,
        .severity = .@"error",
        .severity_text = "ERROR",
        .body = "alert fired",
        .attrs = &log_attrs,
    }};

    const bytes = try encodeLogsRequest(testing.allocator, &attrs, &records);
    defer testing.allocator.free(bytes);

    // Top-level field 1 = ResourceLogs.
    const rl = findLenField(bytes, 1) orelse return error.MissingResourceLogs;

    // ResourceLogs field 1 = Resource (has service.name).
    const resource = findLenField(rl, 1) orelse return error.MissingResource;
    try testing.expect(std.mem.indexOf(u8, resource, "service.name") != null);

    // ResourceLogs field 2 = ScopeLogs.
    const sl = findLenField(rl, 2) orelse return error.MissingScopeLogs;

    // ScopeLogs field 2 = LogRecord, must contain "alert fired" body string.
    const lr = findLenField(sl, 2) orelse return error.MissingLogRecord;
    try testing.expect(std.mem.indexOf(u8, lr, "alert fired") != null);
    try testing.expect(std.mem.indexOf(u8, lr, "ERROR") != null);
}

test "encodeLogsRequest: empty inputs produce valid empty envelope" {
    const bytes = try encodeLogsRequest(testing.allocator, &.{}, &.{});
    defer testing.allocator.free(bytes);
    try testing.expect(bytes.len > 0);
    // Must contain top-level ResourceLogs (which contains scope = "zlrd").
    const rl = findLenField(bytes, 1) orelse return error.MissingResourceLogs;
    const sl = findLenField(rl, 2) orelse return error.MissingScopeLogs;
    const scope = findLenField(sl, 1) orelse return error.MissingScope;
    try testing.expect(std.mem.indexOf(u8, scope, "zlrd") != null);
}

test "encodeMetricsRequest: monotonic counter produces Sum field" {
    const res_attrs: [1]Attr = .{.{ .key = "service.name", .value = .{ .string = "zlrd" } }};
    const m_attrs: [1]Attr = .{.{ .key = "level", .value = .{ .string = "error" } }};
    const points: [1]MetricPoint = .{.{
        .name = "zlrd_lines_total",
        .is_monotonic = true,
        .time_unix_nano = 2_000_000_000,
        .start_time_unix_nano = 1_000_000_000,
        .value = 42,
        .attrs = &m_attrs,
    }};

    const bytes = try encodeMetricsRequest(testing.allocator, &res_attrs, &points);
    defer testing.allocator.free(bytes);

    const rm = findLenField(bytes, 1) orelse return error.MissingResourceMetrics;
    const sm = findLenField(rm, 2) orelse return error.MissingScopeMetrics;
    const metric = findLenField(sm, 2) orelse return error.MissingMetric;
    try testing.expect(std.mem.indexOf(u8, metric, "zlrd_lines_total") != null);

    // Metric field 7 = Sum (set since is_monotonic).
    const sum = findLenField(metric, 7) orelse return error.MissingSum;
    // Sum field 1 = NumberDataPoint.
    const dp = findLenField(sum, 1) orelse return error.MissingDataPoint;
    try testing.expect(std.mem.indexOf(u8, dp, "level") != null);
}

test "encodeMetricsRequest: gauge variant skips Sum" {
    const points: [1]MetricPoint = .{.{
        .name = "zlrd_uptime_seconds",
        .is_monotonic = false,
        .time_unix_nano = 100,
        .start_time_unix_nano = 100,
        .value = 7,
        .attrs = &.{},
    }};
    const bytes = try encodeMetricsRequest(testing.allocator, &.{}, &points);
    defer testing.allocator.free(bytes);

    const rm = findLenField(bytes, 1) orelse return error.MissingResourceMetrics;
    const sm = findLenField(rm, 2) orelse return error.MissingScopeMetrics;
    const metric = findLenField(sm, 2) orelse return error.MissingMetric;
    // Metric.gauge = 5 should be present; Metric.sum = 7 should not.
    try testing.expect(findLenField(metric, 5) != null);
    try testing.expect(findLenField(metric, 7) == null);
}
