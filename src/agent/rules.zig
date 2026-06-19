//! Alert rule evaluation: sliding-window rate, regex match-rate, first-seen
//! error signature, and silence detection.
//!
//! All state lives behind `RuleSet.mutex` because both the watcher (writer)
//! and the silence ticker (writer + reader) can poke it.

const std = @import("std");
const flags = @import("flags");
const regex = @import("regex");

const config = @import("config.zig");
const metrics = @import("metrics.zig");
const signature = @import("signature.zig");

const buckets_per_window = 8;

/// Fixed-size sliding-window counter.
///
/// The window is split into `buckets_per_window` equal-sized buckets. Each
/// bucket records (epoch_id, count). On insert we map `now_ms` to a slot via
/// `(now_ms / bucket_size_ms) % N`; if the slot's stored epoch is stale, it's
/// recycled. On read, we sum buckets whose epoch is within `[now - window, now]`.
const WindowedCounter = struct {
    buckets: [buckets_per_window]Bucket = [_]Bucket{.{ .epoch = 0, .count = 0 }} ** buckets_per_window,
    window_ms: u64,
    bucket_size_ms: u64,
    threshold: u32,
    /// `null` until the rule has fired at least once. Latched per-epoch so
    /// the same burst doesn't repeatedly alert.
    last_fire_epoch: ?u64 = null,

    const Bucket = struct { epoch: u64, count: u32 };

    fn init(spec: config.ThresholdSpec) WindowedCounter {
        // Round up so the actual covered span is >= window_ms.
        const bucket = (spec.window_ms + buckets_per_window - 1) / buckets_per_window;
        return .{
            .window_ms = spec.window_ms,
            .bucket_size_ms = if (bucket == 0) 1 else bucket,
            .threshold = spec.count,
        };
    }

    fn increment(self: *WindowedCounter, now_ms: i64) void {
        const epoch = epochOf(now_ms, self.bucket_size_ms);
        const slot = epoch % buckets_per_window;
        if (self.buckets[slot].epoch != epoch) {
            self.buckets[slot] = .{ .epoch = epoch, .count = 0 };
        }
        self.buckets[slot].count += 1;
    }

    fn sumWithin(self: *const WindowedCounter, now_ms: i64) u64 {
        const cur_epoch = epochOf(now_ms, self.bucket_size_ms);
        const min_epoch: u64 = if (cur_epoch >= buckets_per_window - 1)
            cur_epoch - (buckets_per_window - 1)
        else
            0;
        var total: u64 = 0;
        for (self.buckets) |b| {
            if (b.epoch >= min_epoch and b.epoch <= cur_epoch) total += b.count;
        }
        return total;
    }

    /// Returns true if the threshold was crossed AND the rule has not fired
    /// for the current "bucket epoch" yet. Without the latch the rule would
    /// fire on every observation after the threshold is hit; this caps it to
    /// one alert per bucket.
    fn shouldFire(self: *WindowedCounter, now_ms: i64) bool {
        const total = self.sumWithin(now_ms);
        if (total < self.threshold) return false;
        const cur_epoch = epochOf(now_ms, self.bucket_size_ms);
        if (self.last_fire_epoch) |prev| {
            if (prev == cur_epoch) return false;
        }
        self.last_fire_epoch = cur_epoch;
        return true;
    }
};

fn epochOf(now_ms: i64, bucket_size_ms: u64) u64 {
    if (now_ms <= 0) return 0;
    return @as(u64, @intCast(now_ms)) / bucket_size_ms;
}

const RegexState = struct {
    pattern: []const u8,
    re: regex.Regex,
    window: WindowedCounter,
};

/// `Fired` is the result of `RuleSet.observe`. It borrows slices from its
/// inputs — caller must consume or copy before they go out of scope.
pub const Fired = struct {
    kind: metrics.RuleKind,
    rule_id: []const u8,
    line: []const u8,
    file_path: []const u8,
    threshold_count: u32,
    threshold_window_ms: u64,
    /// Observed count in the window when the rule fired. For first-seen this
    /// is always 1; for silence it's 0.
    observed_count: u64,
};

pub const RuleSet = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex,
    error_rate: ?WindowedCounter,
    regexes: []RegexState,
    seen_enabled: bool,
    seen: std.AutoHashMapUnmanaged(u64, void),
    silence_window_ms: ?u64,

    /// Constructs a RuleSet from a parsed AgentConfig. Owns the `regexes`
    /// slice and `seen` map; takes a borrowed slice of regex specs.
    pub fn init(allocator: std.mem.Allocator, cfg: config.AgentConfig) !RuleSet {
        const regexes = try allocator.alloc(RegexState, cfg.regex_rules.len);
        errdefer allocator.free(regexes);

        var built: usize = 0;
        errdefer {
            for (regexes[0..built]) |*rs| rs.re.deinit();
        }
        for (cfg.regex_rules, 0..) |rule, i| {
            const re = regex.Regex.compile(rule.pattern) orelse return error.InvalidRegexPattern;
            regexes[i] = .{
                .pattern = rule.pattern,
                .re = re,
                .window = WindowedCounter.init(rule.threshold),
            };
            built += 1;
        }

        return .{
            .allocator = allocator,
            .mutex = .init,
            .error_rate = if (cfg.error_rate) |t| WindowedCounter.init(t) else null,
            .regexes = regexes,
            .seen_enabled = cfg.first_seen,
            .seen = .empty,
            .silence_window_ms = cfg.silence_window_ms,
        };
    }

    pub fn deinit(self: *RuleSet) void {
        for (self.regexes) |*rs| rs.re.deinit();
        self.allocator.free(self.regexes);
        self.seen.deinit(self.allocator);
        self.* = undefined;
    }

    /// Returns true if any rules need silence checking.
    pub fn hasSilenceRule(self: *const RuleSet) bool {
        return self.silence_window_ms != null;
    }

    /// Observe a single line. `level` is the detected level (may be null).
    /// Writes any fired alerts to `out` and returns the number written.
    /// At most 1 (error-rate) + N (regex rules) + 1 (first-seen) alerts can
    /// fire per call, so the caller can size `out` accordingly.
    pub fn observe(
        self: *RuleSet,
        io: std.Io,
        line: []const u8,
        level: ?flags.Level,
        file_path: []const u8,
        now_ms: i64,
        out: []Fired,
    ) error{OutOfMemory}!usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var n: usize = 0;

        if (self.error_rate) |*w| {
            if (level != null and signature.isErrorLevel(level.?)) {
                w.increment(now_ms);
                if (n < out.len and w.shouldFire(now_ms)) {
                    out[n] = .{
                        .kind = .error_rate,
                        .rule_id = "error_rate",
                        .line = line,
                        .file_path = file_path,
                        .threshold_count = w.threshold,
                        .threshold_window_ms = w.window_ms,
                        .observed_count = w.sumWithin(now_ms),
                    };
                    n += 1;
                }
            }
        }

        for (self.regexes) |*rs| {
            if (n >= out.len) break;
            if (!rs.re.isMatch(line)) continue;
            rs.window.increment(now_ms);
            if (rs.window.shouldFire(now_ms)) {
                out[n] = .{
                    .kind = .regex,
                    .rule_id = rs.pattern,
                    .line = line,
                    .file_path = file_path,
                    .threshold_count = rs.window.threshold,
                    .threshold_window_ms = rs.window.window_ms,
                    .observed_count = rs.window.sumWithin(now_ms),
                };
                n += 1;
            }
        }

        if (self.seen_enabled and level != null and signature.isErrorLevel(level.?) and n < out.len) {
            const sig = signature.errorSignature(line);
            const gop = try self.seen.getOrPut(self.allocator, sig);
            if (!gop.found_existing) {
                out[n] = .{
                    .kind = .first_seen,
                    .rule_id = "first_seen",
                    .line = line,
                    .file_path = file_path,
                    .threshold_count = 1,
                    .threshold_window_ms = 0,
                    .observed_count = 1,
                };
                n += 1;
            }
        }

        return n;
    }

    /// Called periodically by the watcher. If no line has been observed for a
    /// given file in the silence window, fires once per window period.
    ///
    /// `latch` is per-file state owned by the caller (typically a field on
    /// the watcher's `FileState`). Each file needs its own latch so one
    /// file's silence alert doesn't suppress alerts for every other silent
    /// file in the same window.
    pub fn checkSilence(
        self: *RuleSet,
        io: std.Io,
        file_path: []const u8,
        last_line_ms: i64,
        now_ms: i64,
        latch: *?u64,
        out: []Fired,
    ) usize {
        const window = self.silence_window_ms orelse return 0;
        if (out.len == 0) return 0;

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (now_ms - last_line_ms < @as(i64, @intCast(window))) return 0;

        const epoch = epochOf(now_ms, window);
        if (latch.*) |prev| {
            if (prev == epoch) return 0;
        }
        latch.* = epoch;

        out[0] = .{
            .kind = .silence,
            .rule_id = "silence",
            .line = "",
            .file_path = file_path,
            .threshold_count = 0,
            .threshold_window_ms = window,
            .observed_count = 0,
        };
        return 1;
    }
};

const testing = std.testing;

test "WindowedCounter: below threshold does not fire" {
    var w = WindowedCounter.init(.{ .count = 5, .window_ms = 1_000 });
    var i: usize = 0;
    while (i < 4) : (i += 1) w.increment(1_000);
    try testing.expectEqual(false, w.shouldFire(1_000));
}

test "WindowedCounter: threshold crossed fires once per epoch" {
    var w = WindowedCounter.init(.{ .count = 3, .window_ms = 1_000 });
    var i: usize = 0;
    while (i < 3) : (i += 1) w.increment(1_000);
    try testing.expectEqual(true, w.shouldFire(1_000));
    // Same epoch -> latched, no re-fire.
    w.increment(1_000);
    try testing.expectEqual(false, w.shouldFire(1_000));
}

test "WindowedCounter: events outside window do not count" {
    var w = WindowedCounter.init(.{ .count = 3, .window_ms = 1_000 });
    // 3 events at t=0
    var i: usize = 0;
    while (i < 3) : (i += 1) w.increment(0);
    // Far-future query: those events have aged out (well beyond N buckets).
    try testing.expectEqual(false, w.shouldFire(60_000));
}

test "WindowedCounter: re-fires after the latch epoch advances" {
    var w = WindowedCounter.init(.{ .count = 2, .window_ms = 8_000 });
    // bucket_size_ms = 1000 (8000 / 8). All events land in the t=0 bucket.
    w.increment(0);
    w.increment(0);
    try testing.expect(w.shouldFire(0));
    try testing.expect(!w.shouldFire(0));
    // Two more events one bucket later — within the window, but in a new
    // epoch, so the latch reopens.
    w.increment(1_000);
    w.increment(1_000);
    try testing.expect(w.shouldFire(1_000));
}

test "RuleSet: error_rate fires on threshold of error/fatal/panic" {
    const allocator = testing.allocator;

    var args = flags.Args{};
    args.metrics_token = "t";
    args.alert_error_rate = "3/1s";

    var cfg = try config.AgentConfig.fromArgs(allocator, args);
    defer cfg.deinit(allocator);

    var rs = try RuleSet.init(allocator, cfg);
    defer rs.deinit();

    const io = std.Options.debug_io;
    var out: [4]Fired = undefined;

    try testing.expectEqual(@as(usize, 0), try rs.observe(io, "x", .Error, "a.log", 100, &out));
    try testing.expectEqual(@as(usize, 0), try rs.observe(io, "x", .Error, "a.log", 100, &out));
    const n = try rs.observe(io, "x", .Error, "a.log", 100, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(metrics.RuleKind.error_rate, out[0].kind);
}

test "RuleSet: non-error level does not count toward error_rate" {
    const allocator = testing.allocator;
    var args = flags.Args{};
    args.metrics_token = "t";
    args.alert_error_rate = "2/1s";

    var cfg = try config.AgentConfig.fromArgs(allocator, args);
    defer cfg.deinit(allocator);

    var rs = try RuleSet.init(allocator, cfg);
    defer rs.deinit();

    const io = std.Options.debug_io;
    var out: [4]Fired = undefined;
    _ = try rs.observe(io, "x", .Info, "a.log", 100, &out);
    _ = try rs.observe(io, "x", .Warn, "a.log", 100, &out);
    const n = try rs.observe(io, "x", .Debug, "a.log", 100, &out);
    try testing.expectEqual(@as(usize, 0), n);
}

test "RuleSet: regex fires after threshold matches" {
    const allocator = testing.allocator;

    const regexes = [_][]const u8{"panic:2/1s"};
    var args = flags.Args{};
    args.metrics_token = "t";
    args.alert_regexes = &regexes;

    var cfg = try config.AgentConfig.fromArgs(allocator, args);
    defer cfg.deinit(allocator);

    var rs = try RuleSet.init(allocator, cfg);
    defer rs.deinit();

    const io = std.Options.debug_io;
    var out: [4]Fired = undefined;
    _ = try rs.observe(io, "all ok", .Info, "a.log", 100, &out);
    _ = try rs.observe(io, "PANIC at the disco", .Info, "a.log", 100, &out);
    const n = try rs.observe(io, "panic stations", .Info, "a.log", 100, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(metrics.RuleKind.regex, out[0].kind);
    try testing.expectEqualStrings("panic", out[0].rule_id);
}

test "RuleSet: first_seen fires only on novel signatures" {
    const allocator = testing.allocator;

    var args = flags.Args{};
    args.metrics_token = "t";
    args.alert_first_seen = true;

    var cfg = try config.AgentConfig.fromArgs(allocator, args);
    defer cfg.deinit(allocator);

    var rs = try RuleSet.init(allocator, cfg);
    defer rs.deinit();

    const io = std.Options.debug_io;
    var out: [4]Fired = undefined;
    var n = try rs.observe(io, "connection refused 10.0.0.1", .Error, "a.log", 100, &out);
    try testing.expectEqual(@as(usize, 1), n);

    // Different IDs, same signature — must NOT fire.
    n = try rs.observe(io, "connection refused 10.0.0.99", .Error, "a.log", 200, &out);
    try testing.expectEqual(@as(usize, 0), n);

    // Truly new signature -> fires.
    n = try rs.observe(io, "permission denied", .Error, "a.log", 300, &out);
    try testing.expectEqual(@as(usize, 1), n);
}

test "RuleSet: checkSilence fires after window elapses, latches per epoch" {
    const allocator = testing.allocator;

    var args = flags.Args{};
    args.metrics_token = "t";
    args.alert_silence = "1s";

    var cfg = try config.AgentConfig.fromArgs(allocator, args);
    defer cfg.deinit(allocator);

    var rs = try RuleSet.init(allocator, cfg);
    defer rs.deinit();

    const io = std.Options.debug_io;
    var out: [4]Fired = undefined;
    var latch: ?u64 = null;

    // last_line at t=0, now=500ms -> within window, no fire.
    try testing.expectEqual(@as(usize, 0), rs.checkSilence(io, "a.log", 0, 500, &latch, &out));

    // last_line at t=0, now=2000ms -> >= 1s, fires once.
    try testing.expectEqual(@as(usize, 1), rs.checkSilence(io, "a.log", 0, 2_000, &latch, &out));
    try testing.expectEqual(metrics.RuleKind.silence, out[0].kind);

    // Same epoch -> latched, no fire.
    try testing.expectEqual(@as(usize, 0), rs.checkSilence(io, "a.log", 0, 2_500, &latch, &out));
}

test "RuleSet.checkSilence: per-file latch lets other files fire in the same epoch" {
    const allocator = testing.allocator;

    var args = flags.Args{};
    args.metrics_token = "t";
    args.alert_silence = "1s";

    var cfg = try config.AgentConfig.fromArgs(allocator, args);
    defer cfg.deinit(allocator);

    var rs = try RuleSet.init(allocator, cfg);
    defer rs.deinit();

    const io = std.Options.debug_io;
    var out: [4]Fired = undefined;
    var latch_a: ?u64 = null;
    var latch_b: ?u64 = null;

    // Both files silent past the window; both must fire even though they
    // hit the same epoch. The previous implementation used a single shared
    // latch on the RuleSet so the second file was silently suppressed.
    try testing.expectEqual(@as(usize, 1), rs.checkSilence(io, "a.log", 0, 2_000, &latch_a, &out));
    try testing.expectEqual(@as(usize, 1), rs.checkSilence(io, "b.log", 0, 2_000, &latch_b, &out));
}
