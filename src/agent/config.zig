//! Agent-mode configuration: lifts parsed CLI flags into a typed config and
//! parses the small DSLs used by `--alert-error-rate`, `--alert-regex`,
//! `--alert-silence`, and `--webhook-header`.

const std = @import("std");
const flags = @import("flags");

pub const default_listen = "127.0.0.1:9100";

/// `N/Ws` threshold: at most `count` events per `window_ms` milliseconds before
/// the rule fires.
pub const ThresholdSpec = struct {
    count: u32,
    window_ms: u64,
};

pub const RegexRule = struct {
    pattern: []const u8,
    threshold: ThresholdSpec,
};

pub const HeaderSpec = struct {
    name: []const u8,
    value: []const u8,
};

pub const ParseError = error{
    InvalidThresholdSpec,
    InvalidDuration,
    InvalidRegexSpec,
    InvalidHeaderSpec,
    MissingMetricsToken,
};

pub const SinkConfig = struct {
    stderr: bool,
    file_path: ?[]const u8,
    webhooks: []const []const u8,
    webhook_headers: []HeaderSpec,

    pub fn hasAny(self: SinkConfig) bool {
        return self.stderr or self.file_path != null or self.webhooks.len > 0;
    }
};

pub const AgentConfig = struct {
    listen_addr: []const u8,
    metrics_token: []const u8,
    error_rate: ?ThresholdSpec,
    regex_rules: []RegexRule,
    first_seen: bool,
    silence_window_ms: ?u64,
    sinks: SinkConfig,
    alert_exit: bool,

    pub fn deinit(self: *AgentConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.regex_rules);
        allocator.free(self.sinks.webhook_headers);
        self.* = undefined;
    }

    /// Build an AgentConfig from CLI flags. Allocates only the parsed
    /// `regex_rules` and `sinks.webhook_headers` slices — all string slices
    /// remain borrowed from `args` and stay valid for the lifetime of `args`.
    pub fn fromArgs(allocator: std.mem.Allocator, args: flags.Args) (ParseError || error{OutOfMemory})!AgentConfig {
        const token = args.metrics_token orelse return error.MissingMetricsToken;
        if (token.len == 0) return error.MissingMetricsToken;

        const error_rate: ?ThresholdSpec = if (args.alert_error_rate) |s|
            try parseThresholdSpec(s)
        else
            null;

        const silence_ms: ?u64 = if (args.alert_silence) |s|
            try parseDuration(s)
        else
            null;

        const regex_rules = try allocator.alloc(RegexRule, args.alert_regexes.len);
        errdefer allocator.free(regex_rules);
        for (args.alert_regexes, 0..) |spec, i| {
            regex_rules[i] = try parseRegexRuleSpec(spec);
        }

        const headers = try allocator.alloc(HeaderSpec, args.webhook_headers.len);
        errdefer allocator.free(headers);
        for (args.webhook_headers, 0..) |spec, i| {
            headers[i] = try parseHeaderSpec(spec);
        }

        // Default sink: if the user enabled agent mode but specified no sink at all,
        // emit alerts to stderr so the process is never silently producing them.
        const any_sink = args.alert_stderr or args.alert_file != null or args.alert_webhooks.len > 0;
        const stderr_enabled = args.alert_stderr or !any_sink;

        return .{
            .listen_addr = args.listen orelse default_listen,
            .metrics_token = token,
            .error_rate = error_rate,
            .regex_rules = regex_rules,
            .first_seen = args.alert_first_seen,
            .silence_window_ms = silence_ms,
            .sinks = .{
                .stderr = stderr_enabled,
                .file_path = args.alert_file,
                .webhooks = args.alert_webhooks,
                .webhook_headers = headers,
            },
            .alert_exit = args.alert_exit_on_alert,
        };
    }
};

/// Parses an `N/Ws` threshold spec into its components. `W` accepts the same
/// duration suffixes as `parseDuration` (`ms`, `s`, `m`, `h`).
pub fn parseThresholdSpec(s: []const u8) ParseError!ThresholdSpec {
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse return error.InvalidThresholdSpec;
    if (slash == 0 or slash == s.len - 1) return error.InvalidThresholdSpec;

    const count = std.fmt.parseInt(u32, s[0..slash], 10) catch return error.InvalidThresholdSpec;
    if (count == 0) return error.InvalidThresholdSpec;

    const window_ms = try parseDuration(s[slash + 1 ..]);
    if (window_ms == 0) return error.InvalidThresholdSpec;

    return .{ .count = count, .window_ms = window_ms };
}

/// Parses durations with unit suffix: `ms`, `s`, `m`, `h`. Returns milliseconds.
pub fn parseDuration(s: []const u8) ParseError!u64 {
    if (s.len == 0) return error.InvalidDuration;

    var digit_end: usize = 0;
    while (digit_end < s.len and s[digit_end] >= '0' and s[digit_end] <= '9') : (digit_end += 1) {}
    if (digit_end == 0) return error.InvalidDuration;

    const num = std.fmt.parseInt(u64, s[0..digit_end], 10) catch return error.InvalidDuration;
    const unit = s[digit_end..];

    if (std.mem.eql(u8, unit, "ms")) return num;
    if (std.mem.eql(u8, unit, "s")) return std.math.mul(u64, num, 1_000) catch return error.InvalidDuration;
    if (std.mem.eql(u8, unit, "m")) return std.math.mul(u64, num, 60_000) catch return error.InvalidDuration;
    if (std.mem.eql(u8, unit, "h")) return std.math.mul(u64, num, 3_600_000) catch return error.InvalidDuration;
    return error.InvalidDuration;
}

/// Splits `pattern:N/Ws` into a RegexRule. The `:` is the LAST one in the
/// string so patterns may themselves contain `:`.
pub fn parseRegexRuleSpec(s: []const u8) ParseError!RegexRule {
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return error.InvalidRegexSpec;
    if (colon == 0) return error.InvalidRegexSpec;

    const pattern = s[0..colon];
    const threshold = parseThresholdSpec(s[colon + 1 ..]) catch return error.InvalidRegexSpec;
    return .{ .pattern = pattern, .threshold = threshold };
}

/// Splits `Name: Value` into HeaderSpec. Leading whitespace in the value is
/// trimmed; the name is taken verbatim.
pub fn parseHeaderSpec(s: []const u8) ParseError!HeaderSpec {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return error.InvalidHeaderSpec;
    if (colon == 0 or colon == s.len - 1) return error.InvalidHeaderSpec;
    const name = s[0..colon];
    const value = std.mem.trimStart(u8, s[colon + 1 ..], " \t");
    if (value.len == 0) return error.InvalidHeaderSpec;
    return .{ .name = name, .value = value };
}

const testing = std.testing;

test "parseDuration accepts ms/s/m/h" {
    try testing.expectEqual(@as(u64, 250), try parseDuration("250ms"));
    try testing.expectEqual(@as(u64, 60_000), try parseDuration("60s"));
    try testing.expectEqual(@as(u64, 120_000), try parseDuration("2m"));
    try testing.expectEqual(@as(u64, 3_600_000), try parseDuration("1h"));
}

test "parseDuration rejects empty, bare digits, unknown unit" {
    try testing.expectError(error.InvalidDuration, parseDuration(""));
    try testing.expectError(error.InvalidDuration, parseDuration("60"));
    try testing.expectError(error.InvalidDuration, parseDuration("60xy"));
    try testing.expectError(error.InvalidDuration, parseDuration("ms"));
}

test "parseThresholdSpec valid cases" {
    const t = try parseThresholdSpec("10/60s");
    try testing.expectEqual(@as(u32, 10), t.count);
    try testing.expectEqual(@as(u64, 60_000), t.window_ms);

    const t2 = try parseThresholdSpec("1/500ms");
    try testing.expectEqual(@as(u32, 1), t2.count);
    try testing.expectEqual(@as(u64, 500), t2.window_ms);
}

test "parseThresholdSpec rejects malformed input" {
    try testing.expectError(error.InvalidThresholdSpec, parseThresholdSpec(""));
    try testing.expectError(error.InvalidThresholdSpec, parseThresholdSpec("10"));
    try testing.expectError(error.InvalidThresholdSpec, parseThresholdSpec("/60s"));
    try testing.expectError(error.InvalidThresholdSpec, parseThresholdSpec("10/"));
    try testing.expectError(error.InvalidThresholdSpec, parseThresholdSpec("0/60s"));
    try testing.expectError(error.InvalidDuration, parseThresholdSpec("10/60"));
}

test "parseRegexRuleSpec splits on last colon" {
    const r = try parseRegexRuleSpec("panic:5/30s");
    try testing.expectEqualStrings("panic", r.pattern);
    try testing.expectEqual(@as(u32, 5), r.threshold.count);
    try testing.expectEqual(@as(u64, 30_000), r.threshold.window_ms);

    // patterns with colons survive
    const r2 = try parseRegexRuleSpec("level:error:3/60s");
    try testing.expectEqualStrings("level:error", r2.pattern);
    try testing.expectEqual(@as(u32, 3), r2.threshold.count);
}

test "parseRegexRuleSpec rejects malformed input" {
    try testing.expectError(error.InvalidRegexSpec, parseRegexRuleSpec("panic"));
    try testing.expectError(error.InvalidRegexSpec, parseRegexRuleSpec(":5/30s"));
}

test "parseHeaderSpec trims leading whitespace in value" {
    const h = try parseHeaderSpec("Authorization: Bearer xyz");
    try testing.expectEqualStrings("Authorization", h.name);
    try testing.expectEqualStrings("Bearer xyz", h.value);

    const h2 = try parseHeaderSpec("X-Source:zlrd");
    try testing.expectEqualStrings("X-Source", h2.name);
    try testing.expectEqualStrings("zlrd", h2.value);
}

test "parseHeaderSpec rejects malformed input" {
    try testing.expectError(error.InvalidHeaderSpec, parseHeaderSpec("Authorization"));
    try testing.expectError(error.InvalidHeaderSpec, parseHeaderSpec(":value"));
    try testing.expectError(error.InvalidHeaderSpec, parseHeaderSpec("Name:"));
    try testing.expectError(error.InvalidHeaderSpec, parseHeaderSpec("Name:  "));
}

test "AgentConfig.fromArgs: missing token surfaces specific error" {
    const allocator = testing.allocator;
    var args = flags.Args{};
    args.agent_mode = true;
    try testing.expectError(error.MissingMetricsToken, AgentConfig.fromArgs(allocator, args));
}

test "AgentConfig.fromArgs: defaults listen, defaults stderr sink when no sink given" {
    const allocator = testing.allocator;
    var args = flags.Args{};
    args.agent_mode = true;
    args.metrics_token = "t";
    var cfg = try AgentConfig.fromArgs(allocator, args);
    defer cfg.deinit(allocator);
    try testing.expectEqualStrings(default_listen, cfg.listen_addr);
    try testing.expect(cfg.sinks.stderr);
    try testing.expect(cfg.sinks.file_path == null);
    try testing.expectEqual(@as(usize, 0), cfg.sinks.webhooks.len);
    try testing.expectEqual(@as(usize, 0), cfg.regex_rules.len);
}

test "AgentConfig.fromArgs: explicit sink suppresses default stderr" {
    const allocator = testing.allocator;
    var args = flags.Args{};
    args.agent_mode = true;
    args.metrics_token = "t";
    args.alert_file = "/tmp/alerts.jsonl";
    var cfg = try AgentConfig.fromArgs(allocator, args);
    defer cfg.deinit(allocator);
    try testing.expect(!cfg.sinks.stderr);
    try testing.expectEqualStrings("/tmp/alerts.jsonl", cfg.sinks.file_path.?);
}
