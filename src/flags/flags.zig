const std = @import("std");

pub const Level = enum(u8) {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
    Fatal,
    Panic,
};

pub const AggregateMode = enum {
    exact,
    level_message,
    json_message,
    normalized,
};

pub const LevelMask = u8;

pub fn allLevelsMask() LevelMask {
    var mask: LevelMask = 0;
    inline for (@typeInfo(Level).@"enum".fields) |f| {
        mask |= levelBit(@enumFromInt(f.value));
    }
    return mask;
}

pub inline fn levelBit(lvl: Level) LevelMask {
    return @as(LevelMask, 1) << @intCast(@intFromEnum(lvl));
}

pub fn parseLevelInsensitive(s: []const u8) ?Level {
    inline for (@typeInfo(Level).@"enum".fields) |f| {
        if (eqlIgnoreCaseFast(s, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

pub fn parseAggregateMode(s: []const u8) ?AggregateMode {
    inline for (@typeInfo(AggregateMode).@"enum".fields) |f| {
        if (eqlDashInsensitive(s, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

/// Returns true if `a` and `b` are equal when dashes and underscores are treated
/// as equivalent. Used for parsing enum values from CLI flags.
fn eqlDashInsensitive(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const na = if (ca == '-') '_' else ca;
        const nb = if (cb == '-') '_' else cb;
        if (std.ascii.toLower(na) != std.ascii.toLower(nb)) return false;
    }
    return true;
}

fn eqlIgnoreCaseFast(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (toLowerFast(ca) != toLowerFast(cb)) return false;
    }
    return true;
}

inline fn toLowerFast(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

pub const Args = struct {
    files: []const []const u8 = &.{},
    search: ?[]const u8 = null,
    levels: ?LevelMask = null,
    date: ?[]const u8 = null,
    from_time: ?[]const u8 = null,
    to_time: ?[]const u8 = null,
    tail_mode: bool = false,
    help: bool = false,
    version: bool = false,
    num_lines: usize = 0,
    aggregate: bool = false,
    aggregate_mode: AggregateMode = .exact,
    output_json: bool = false,

    // Agent mode flags. See src/agent/ for the implementation.
    agent_mode: bool = false,
    listen: ?[]const u8 = null,
    metrics_token: ?[]const u8 = null,
    alert_error_rate: ?[]const u8 = null,
    alert_regexes: []const []const u8 = &.{},
    alert_first_seen: bool = false,
    alert_silence: ?[]const u8 = null,
    alert_stderr: bool = false,
    alert_file: ?[]const u8 = null,
    alert_webhooks: []const []const u8 = &.{},
    webhook_headers: []const []const u8 = &.{},
    alert_exit_on_alert: bool = false,
    kernel_probes: bool = false,

    pub fn deinit(self: Args, allocator: std.mem.Allocator) void {
        for (self.files) |f| allocator.free(f);
        allocator.free(self.files);
        if (self.search) |s| allocator.free(s);
        if (self.date) |d| allocator.free(d);
        if (self.from_time) |t| allocator.free(t);
        if (self.to_time) |t| allocator.free(t);

        if (self.listen) |s| allocator.free(s);
        if (self.metrics_token) |s| allocator.free(s);
        if (self.alert_error_rate) |s| allocator.free(s);
        if (self.alert_silence) |s| allocator.free(s);
        if (self.alert_file) |s| allocator.free(s);
        for (self.alert_regexes) |s| allocator.free(s);
        allocator.free(self.alert_regexes);
        for (self.alert_webhooks) |s| allocator.free(s);
        allocator.free(self.alert_webhooks);
        for (self.webhook_headers) |s| allocator.free(s);
        allocator.free(self.webhook_headers);
    }

    pub fn isLevelEnabled(self: Args, lvl: Level) bool {
        return self.levels == null or (self.levels.? & levelBit(lvl)) != 0;
    }
};

pub const ParseError = error{
    InvalidArgument,
    InvalidNumLines,
    MissingFile,
    InvalidLevel,
    InvalidAggregateMode,
    InvalidOutputMode,
    MissingSearch,
    MissingLevel,
    MissingDate,
    MissingNumLines,
    MissingAggregateMode,
    MissingFromTime,
    MissingToTime,
    MissingOutput,
    MissingListen,
    MissingMetricsToken,
    MissingAlertErrorRate,
    MissingAlertRegex,
    MissingAlertSilence,
    MissingAlertFile,
    MissingAlertWebhook,
    MissingWebhookHeader,
    UnknownArgument,
    OutOfMemory,
};

pub fn parseArgs(allocator: std.mem.Allocator, process_args: std.process.Args) ParseError!Args {
    var it = try std.process.Args.iterateAllocator(process_args, allocator);
    defer it.deinit();

    return parseArgsFromIter(allocator, &it);
}

pub fn printHelp() void {
    // ANSI — consistent with the rest of the codebase (GitHub Dark palette)
    const b = "\x1b[1m"; // bold  (section headers)
    const sh = "\x1b[38;2;227;179;65m"; // amber (short flags   -x)
    const lo = "\x1b[38;2;88;166;255m"; // blue  (long flags --flag)
    const ar = "\x1b[38;2;139;148;158m"; // muted (<args>, hints)
    const gr = "\x1b[38;2;63;185;80m"; // green (examples)
    const r = "\x1b[0m";

    // Description column starts at display position 35.
    // Layout per row:  2 + 4 + <long flag padded to 19> + <arg padded to 10> = 35
    const text =
        "\n" ++
        b ++ "Usage" ++ r ++ "\n" ++
        "  zlrd " ++ ar ++ "[options]" ++ r ++ " " ++ ar ++ "<file...>" ++ r ++ "\n\n" ++
        b ++ "Options" ++ r ++ "\n" ++
        "  " ++ sh ++ "-f" ++ r ++ ", " ++ lo ++ "--file" ++ r ++
        "             " ++ ar ++ "<path>   " ++ r ++ "  Add log file (repeatable)\n" ++
        "  " ++ sh ++ "-s" ++ r ++ ", " ++ lo ++ "--search" ++ r ++
        "           " ++ ar ++ "<text>   " ++ r ++ "  Search string  " ++
        ar ++ "·  | = OR   & = AND" ++ r ++ "\n" ++
        "  " ++ sh ++ "-l" ++ r ++ ", " ++ lo ++ "--level" ++ r ++
        "            " ++ ar ++ "<levels> " ++ r ++ "  Filter by level (comma-separated, repeatable)\n" ++
        "                                     " ++
        ar ++ "trace · debug · info · warn · error · fatal · panic" ++ r ++ "\n" ++
        "  " ++ sh ++ "-d" ++ r ++ ", " ++ lo ++ "--date" ++ r ++
        "             " ++ ar ++ "<date>   " ++ r ++ "  Date: YYYY-MM-DD  or  YYYY-MM-DD..YYYY-MM-DD\n" ++
        "      " ++ lo ++ "--from" ++ r ++
        "             " ++ ar ++ "<time>   " ++ r ++ "  Time range start (HH:MM or HH:MM:SS)\n" ++
        "      " ++ lo ++ "--to" ++ r ++
        "               " ++ ar ++ "<time>   " ++ r ++ "  Time range end   (HH:MM or HH:MM:SS)\n" ++
        "      " ++ lo ++ "--output" ++ r ++
        "           " ++ ar ++ "<mode>   " ++ r ++ "  Output format: " ++
        ar ++ "json" ++ r ++ "  " ++ ar ++ "(pipe to jq)" ++ r ++ "\n" ++
        "  " ++ sh ++ "-t" ++ r ++ ", " ++ lo ++ "--tail" ++ r ++
        "                          Follow file in real time\n" ++
        "  " ++ sh ++ "-n" ++ r ++ ", " ++ lo ++ "--num-lines" ++ r ++
        "        " ++ ar ++ "<num>    " ++ r ++ "  Paginate: show N lines per page\n" ++
        "  " ++ sh ++ "-a" ++ r ++ ", " ++ lo ++ "--aggregate" ++ r ++
        "                     Group identical matched lines\n" ++
        "  " ++ sh ++ "-m" ++ r ++ ", " ++ lo ++ "--aggregate-mode" ++ r ++
        "   " ++ ar ++ "<mode>   " ++ r ++ "  " ++
        ar ++ "exact · level-message · json-message · normalized" ++ r ++ "\n" ++
        "  " ++ sh ++ "-v" ++ r ++ ", " ++ lo ++ "--version" ++ r ++
        "                     Print version and exit\n" ++
        "  " ++ sh ++ "-h" ++ r ++ ", " ++ lo ++ "--help" ++ r ++
        "                          Show this help\n" ++
        "\n" ++
        b ++ "Agent mode" ++ r ++ "\n" ++
        "      " ++ lo ++ "--agent" ++ r ++
        "                         Run as a background watcher with /metrics + alerting\n" ++
        "      " ++ lo ++ "--listen" ++ r ++
        "           " ++ ar ++ "<addr>   " ++ r ++ "  HTTP bind address  " ++ ar ++ "(default 127.0.0.1:9100)" ++ r ++ "\n" ++
        "      " ++ lo ++ "--metrics-token" ++ r ++
        "    " ++ ar ++ "<token>  " ++ r ++ "  Bearer token required on /metrics  " ++ ar ++ "(mandatory)" ++ r ++ "\n" ++
        "      " ++ lo ++ "--alert-error-rate" ++ r ++
        " " ++ ar ++ "<N/Ws>   " ++ r ++ "  Alert if >N error/fatal/panic lines in window  " ++ ar ++ "e.g. 10/60s" ++ r ++ "\n" ++
        "      " ++ lo ++ "--alert-regex" ++ r ++
        "      " ++ ar ++ "<spec>   " ++ r ++ "  Alert if regex matches N times in W seconds  " ++ ar ++ "P:N/Ws  (repeatable)" ++ r ++ "\n" ++
        "      " ++ lo ++ "--alert-first-seen" ++ r ++
        "                Alert on first-seen normalized error signature\n" ++
        "      " ++ lo ++ "--alert-silence" ++ r ++
        "    " ++ ar ++ "<Ws>     " ++ r ++ "  Alert if no lines arrived in window  " ++ ar ++ "e.g. 60s" ++ r ++ "\n" ++
        "      " ++ lo ++ "--alert-stderr" ++ r ++
        "                    Sink: structured JSON alerts to stderr\n" ++
        "      " ++ lo ++ "--alert-file" ++ r ++
        "       " ++ ar ++ "<path>   " ++ r ++ "  Sink: append JSONL alerts to file\n" ++
        "      " ++ lo ++ "--alert-webhook" ++ r ++
        "    " ++ ar ++ "<url>    " ++ r ++ "  Sink: POST JSON alert to URL  " ++ ar ++ "(repeatable)" ++ r ++ "\n" ++
        "      " ++ lo ++ "--webhook-header" ++ r ++
        "   " ++ ar ++ "<K: V>   " ++ r ++ "  Extra header for webhooks  " ++ ar ++ "(repeatable)" ++ r ++ "\n" ++
        "      " ++ lo ++ "--alert-exit" ++ r ++
        "                      Exit non-zero on first alert\n" ++
        "      " ++ lo ++ "--kernel-probes" ++ r ++
        "                   Watch kernel for OOM / segfault / panic (Linux)\n" ++
        "\n" ++
        b ++ "Examples" ++ r ++ "\n" ++
        "  " ++ gr ++ "zlrd app.log" ++ r ++ "\n" ++
        "  " ++ gr ++ "zlrd -l error,warn app.log" ++ r ++ "\n" ++
        "  " ++ gr ++ "zlrd -s \"connection|timeout\" app.log" ++ r ++ "\n" ++
        "  " ++ gr ++ "zlrd -d 2024-01-20 --from 09:00 --to 09:30 app.log" ++ r ++ "\n" ++
        "  " ++ gr ++ "zlrd -t -l error app.log" ++ r ++ "\n" ++
        "  " ++ gr ++ "zlrd -a -m normalized app.log" ++ r ++ "\n" ++
        "  " ++ gr ++ "zlrd --output json app.log | jq ." ++ r ++ "\n" ++
        "\n";

    std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, text) catch {};
}

pub const Options = struct {
    short: u8,
    long: []const u8,
};

pub const OptionFile = Options{ .short = 'f', .long = "file" };
pub const OptionSearch = Options{ .short = 's', .long = "search" };
pub const OptionLevel = Options{ .short = 'l', .long = "level" };
pub const OptionDate = Options{ .short = 'd', .long = "date" };
pub const OptionTail = Options{ .short = 't', .long = "tail" };
pub const OptionNumLines = Options{ .short = 'n', .long = "num-lines" };
pub const OptionVersion = Options{ .short = 'v', .long = "version" };
pub const OptionHelp = Options{ .short = 'h', .long = "help" };
pub const OptionAggregate = Options{ .short = 'a', .long = "aggregate" };
pub const OptionAggregateMode = Options{ .short = 'm', .long = "aggregate-mode" };
pub const OptionFromTime = Options{ .short = 0, .long = "from" };
pub const OptionToTime = Options{ .short = 0, .long = "to" };
pub const OptionOutput = Options{ .short = 0, .long = "output" };

/// Mutable buffers for repeatable string-list flags (--file, agent-mode repeatables).
/// Held outside Args during parsing; converted to owned slices on success.
const ParseBuffers = struct {
    files: std.ArrayList([]const u8),
    alert_regexes: std.ArrayList([]const u8),
    alert_webhooks: std.ArrayList([]const u8),
    webhook_headers: std.ArrayList([]const u8),

    fn init(allocator: std.mem.Allocator) !ParseBuffers {
        return .{
            .files = try std.ArrayList([]const u8).initCapacity(allocator, 4),
            .alert_regexes = .empty,
            .alert_webhooks = .empty,
            .webhook_headers = .empty,
        };
    }

    fn deinit(self: *ParseBuffers, allocator: std.mem.Allocator) void {
        freeStringList(allocator, &self.files);
        freeStringList(allocator, &self.alert_regexes);
        freeStringList(allocator, &self.alert_webhooks);
        freeStringList(allocator, &self.webhook_headers);
    }

    fn transferInto(self: *ParseBuffers, allocator: std.mem.Allocator, parsed: *Args) !void {
        parsed.files = try self.files.toOwnedSlice(allocator);
        parsed.alert_regexes = try self.alert_regexes.toOwnedSlice(allocator);
        parsed.alert_webhooks = try self.alert_webhooks.toOwnedSlice(allocator);
        parsed.webhook_headers = try self.webhook_headers.toOwnedSlice(allocator);
    }
};

fn parseArgsFromIter(
    allocator: std.mem.Allocator,
    it: anytype,
) ParseError!Args {
    _ = it.next();

    var bufs = try ParseBuffers.init(allocator);
    errdefer bufs.deinit(allocator);

    var parsed = Args{
        .files = &.{},
    };
    errdefer parsed.deinit(allocator);

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            parsed.help = true;
            try bufs.transferInto(allocator, &parsed);
            return parsed;
        }

        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            parsed.version = true;
            try bufs.transferInto(allocator, &parsed);
            return parsed;
        }

        if (std.mem.startsWith(u8, arg, "--")) {
            try parseLongFlag(&parsed, &bufs, arg, it, allocator);
            continue;
        }

        if (arg.len > 1 and arg[0] == '-') {
            try parseShortFlags(&parsed, &bufs.files, arg[1..], it, allocator);
            if (parsed.help or parsed.version) {
                try bufs.transferInto(allocator, &parsed);
                return parsed;
            }
            continue;
        }

        try appendFile(allocator, &bufs.files, arg);
    }

    try bufs.transferInto(allocator, &parsed);
    return parsed;
}

fn freeStringList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |f| allocator.free(f);
    list.deinit(allocator);
}

fn appendFile(
    allocator: std.mem.Allocator,
    files: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const owned = try allocator.dupe(u8, path);
    errdefer allocator.free(owned);
    try files.append(allocator, owned);
}

fn appendString(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try list.append(allocator, owned);
}

fn replaceOwnedString(
    allocator: std.mem.Allocator,
    slot: *?[]const u8,
    value: []const u8,
) !void {
    const owned = try allocator.dupe(u8, value);
    if (slot.*) |old| allocator.free(old);
    slot.* = owned;
}

fn parseLongFlag(
    parsed: *Args,
    bufs: *ParseBuffers,
    arg: []const u8,
    it: anytype,
    allocator: std.mem.Allocator,
) ParseError!void {
    const flag = if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| blk: {
        const val = arg[eq_pos + 1 ..];
        const f = arg[2..eq_pos];
        if (applyValuedLongFlag(parsed, bufs, f, val, allocator)) |applied| {
            if (applied) return;
        } else |err| return err;
        break :blk f;
    } else arg[2..];

    if (std.mem.eql(u8, flag, "tail")) {
        parsed.tail_mode = true;
        return;
    }
    if (std.mem.eql(u8, flag, "aggregate")) {
        parsed.aggregate = true;
        return;
    }
    if (std.mem.eql(u8, flag, "agent")) {
        parsed.agent_mode = true;
        return;
    }
    if (std.mem.eql(u8, flag, "alert-first-seen")) {
        parsed.alert_first_seen = true;
        return;
    }
    if (std.mem.eql(u8, flag, "alert-stderr")) {
        parsed.alert_stderr = true;
        return;
    }
    if (std.mem.eql(u8, flag, "alert-exit")) {
        parsed.alert_exit_on_alert = true;
        return;
    }
    if (std.mem.eql(u8, flag, "kernel-probes")) {
        parsed.kernel_probes = true;
        return;
    }
    if (std.mem.eql(u8, flag, "output")) {
        const val = valueOrNext(it, flag) orelse return error.MissingOutput;
        try parseOutputMode(parsed, val);
        return;
    }
    if (isValuedLongFlag(flag)) {
        const val = valueOrNext(it, flag) orelse return missingValueError(flag);
        const applied = try applyValuedLongFlag(parsed, bufs, flag, val, allocator);
        if (!applied) return error.UnknownArgument;
        return;
    }

    return error.UnknownArgument;
}

fn isValuedLongFlag(flag: []const u8) bool {
    const names = [_][]const u8{
        "file",          "search",         "level",            "date",
        "num-lines",     "aggregate-mode", "from",             "to",
        "listen",        "metrics-token",  "alert-error-rate", "alert-regex",
        "alert-silence", "alert-file",     "alert-webhook",    "webhook-header",
    };
    for (names) |n| {
        if (std.mem.eql(u8, flag, n)) return true;
    }
    return false;
}

/// Applies a `<flag>=<val>` style assignment, or the second-arg form once the
/// caller has resolved the value via `valueOrNext`. Returns true if the flag
/// was a known valued flag and was applied; false if the name is unknown
/// (caller may surface as `error.UnknownArgument`).
fn applyValuedLongFlag(
    parsed: *Args,
    bufs: *ParseBuffers,
    flag: []const u8,
    val: []const u8,
    allocator: std.mem.Allocator,
) ParseError!bool {
    if (std.mem.eql(u8, flag, "file")) {
        try appendFile(allocator, &bufs.files, val);
        return true;
    }
    if (std.mem.eql(u8, flag, "search")) {
        try replaceOwnedString(allocator, &parsed.search, val);
        return true;
    }
    if (std.mem.eql(u8, flag, "level")) {
        try addLevels(parsed, val);
        return true;
    }
    if (std.mem.eql(u8, flag, "date")) {
        try replaceOwnedString(allocator, &parsed.date, val);
        return true;
    }
    if (std.mem.eql(u8, flag, "num-lines")) {
        parsed.num_lines = parseNumLines(val) catch return error.InvalidNumLines;
        return true;
    }
    if (std.mem.eql(u8, flag, "aggregate-mode")) {
        parsed.aggregate_mode = parseAggregateMode(val) orelse return error.InvalidAggregateMode;
        return true;
    }
    if (std.mem.eql(u8, flag, "from")) {
        try replaceOwnedString(allocator, &parsed.from_time, val);
        return true;
    }
    if (std.mem.eql(u8, flag, "to")) {
        try replaceOwnedString(allocator, &parsed.to_time, val);
        return true;
    }
    if (std.mem.eql(u8, flag, "output")) {
        try parseOutputMode(parsed, val);
        return true;
    }
    if (std.mem.eql(u8, flag, "listen")) {
        try replaceOwnedString(allocator, &parsed.listen, val);
        return true;
    }
    if (std.mem.eql(u8, flag, "metrics-token")) {
        try replaceOwnedString(allocator, &parsed.metrics_token, val);
        return true;
    }
    if (std.mem.eql(u8, flag, "alert-error-rate")) {
        try replaceOwnedString(allocator, &parsed.alert_error_rate, val);
        return true;
    }
    if (std.mem.eql(u8, flag, "alert-silence")) {
        try replaceOwnedString(allocator, &parsed.alert_silence, val);
        return true;
    }
    if (std.mem.eql(u8, flag, "alert-file")) {
        try replaceOwnedString(allocator, &parsed.alert_file, val);
        return true;
    }
    if (std.mem.eql(u8, flag, "alert-regex")) {
        try appendString(allocator, &bufs.alert_regexes, val);
        return true;
    }
    if (std.mem.eql(u8, flag, "alert-webhook")) {
        try appendString(allocator, &bufs.alert_webhooks, val);
        return true;
    }
    if (std.mem.eql(u8, flag, "webhook-header")) {
        try appendString(allocator, &bufs.webhook_headers, val);
        return true;
    }
    return false;
}

fn missingValueError(flag: []const u8) ParseError {
    if (std.mem.eql(u8, flag, "file")) return error.MissingFile;
    if (std.mem.eql(u8, flag, "search")) return error.MissingSearch;
    if (std.mem.eql(u8, flag, "level")) return error.MissingLevel;
    if (std.mem.eql(u8, flag, "date")) return error.MissingDate;
    if (std.mem.eql(u8, flag, "num-lines")) return error.MissingNumLines;
    if (std.mem.eql(u8, flag, "aggregate-mode")) return error.MissingAggregateMode;
    if (std.mem.eql(u8, flag, "from")) return error.MissingFromTime;
    if (std.mem.eql(u8, flag, "to")) return error.MissingToTime;
    if (std.mem.eql(u8, flag, "output")) return error.MissingOutput;
    if (std.mem.eql(u8, flag, "listen")) return error.MissingListen;
    if (std.mem.eql(u8, flag, "metrics-token")) return error.MissingMetricsToken;
    if (std.mem.eql(u8, flag, "alert-error-rate")) return error.MissingAlertErrorRate;
    if (std.mem.eql(u8, flag, "alert-regex")) return error.MissingAlertRegex;
    if (std.mem.eql(u8, flag, "alert-silence")) return error.MissingAlertSilence;
    if (std.mem.eql(u8, flag, "alert-file")) return error.MissingAlertFile;
    if (std.mem.eql(u8, flag, "alert-webhook")) return error.MissingAlertWebhook;
    if (std.mem.eql(u8, flag, "webhook-header")) return error.MissingWebhookHeader;
    return error.InvalidArgument;
}

fn parseOutputMode(parsed: *Args, value: []const u8) ParseError!void {
    if (!std.mem.eql(u8, value, "json")) return error.InvalidOutputMode;
    parsed.output_json = true;
}

fn parseShortFlags(
    parsed: *Args,
    files: *std.ArrayList([]const u8),
    flags_str: []const u8,
    it: anytype,
    allocator: std.mem.Allocator,
) ParseError!void {
    var i: usize = 0;
    while (i < flags_str.len) : (i += 1) {
        switch (flags_str[i]) {
            'f' => {
                const rest = flags_str[i + 1 ..];
                if (rest.len > 0) {
                    try appendFile(allocator, files, rest);
                    return;
                }
                const val = valueOrNext(it, "file") orelse return error.MissingFile;
                try appendFile(allocator, files, val);
                return;
            },
            's' => {
                const rest = flags_str[i + 1 ..];
                if (rest.len > 0) {
                    try replaceOwnedString(allocator, &parsed.search, rest);
                    return;
                }
                const val = valueOrNext(it, "search") orelse return error.MissingSearch;
                try replaceOwnedString(allocator, &parsed.search, val);
                return;
            },
            'l' => {
                const rest = flags_str[i + 1 ..];
                if (rest.len > 0) {
                    try addLevels(parsed, rest);
                    return;
                }
                const val = valueOrNext(it, "level") orelse return error.MissingLevel;
                try addLevels(parsed, val);
                return;
            },
            'd' => {
                const rest = flags_str[i + 1 ..];
                if (rest.len > 0) {
                    try replaceOwnedString(allocator, &parsed.date, rest);
                    return;
                }
                const val = valueOrNext(it, "date") orelse return error.MissingDate;
                try replaceOwnedString(allocator, &parsed.date, val);
                return;
            },
            't' => parsed.tail_mode = true,
            'n' => {
                const rest = flags_str[i + 1 ..];
                if (rest.len > 0) {
                    parsed.num_lines = parseNumLines(rest) catch return error.InvalidNumLines;
                    return;
                }
                const val = valueOrNext(it, "num-lines") orelse return error.MissingNumLines;
                parsed.num_lines = parseNumLines(val) catch return error.InvalidNumLines;
                return;
            },
            'a' => parsed.aggregate = true,
            'm' => {
                const rest = flags_str[i + 1 ..];
                if (rest.len > 0) {
                    parsed.aggregate_mode = parseAggregateMode(rest) orelse return error.InvalidAggregateMode;
                    return;
                }
                const val = valueOrNext(it, "aggregate-mode") orelse return error.MissingAggregateMode;
                parsed.aggregate_mode = parseAggregateMode(val) orelse return error.InvalidAggregateMode;
                return;
            },
            'h' => {
                parsed.help = true;
                return;
            },
            'v' => {
                parsed.version = true;
                return;
            },
            else => return error.UnknownArgument,
        }
    }
}

inline fn valueOrNext(it: anytype, _: []const u8) ?[]const u8 {
    return it.next();
}

fn parseNumLines(s: []const u8) !usize {
    const n = try std.fmt.parseInt(usize, s, 10);
    if (n == 0) return error.InvalidNumLines;
    return n;
}

fn addLevels(parsed: *Args, s: []const u8) !void {
    var it = std.mem.splitScalar(u8, s, ',');
    var saw_level = false;
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        const lvl = parseLevelInsensitive(trimmed) orelse return error.InvalidLevel;
        saw_level = true;
        if (parsed.levels == null) parsed.levels = 0;
        parsed.levels.? |= levelBit(lvl);
    }
    if (!saw_level) return error.InvalidLevel;
}

const testing = std.testing;

const FakeIter = struct {
    argv: []const []const u8,
    index: usize = 0,

    pub fn next(self: *FakeIter) ?[]const u8 {
        if (self.index >= self.argv.len) return null;
        defer self.index += 1;
        return self.argv[self.index];
    }
};

test "single file via -f" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-f", "app.log" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expectEqualStrings("app.log", parsed.files[0]);
    try testing.expect(!parsed.tail_mode);
}

test "multiple files mixed positional and -f" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "a.log", "-f", "b.log", "c.log" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expectEqual(@as(usize, 3), parsed.files.len);
}

test "multiple long flags" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "--search", "err", "--level", "error", "app.log" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expectEqualStrings("err", parsed.search.?);
    try testing.expect(parsed.levels.? & levelBit(.Error) != 0);
    try testing.expectEqual(@as(usize, 1), parsed.files.len);
}

test "mixed flags" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-t", "--search", "err", "app.log" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expect(parsed.tail_mode);
    try testing.expectEqualStrings("err", parsed.search.?);
    try testing.expectEqual(@as(usize, 1), parsed.files.len);
}

test "mixed flags with grouping" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-t", "-lerror", "app.log" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expect(parsed.tail_mode);
    try testing.expect(parsed.levels.? & levelBit(.Error) != 0);
    try testing.expectEqual(@as(usize, 1), parsed.files.len);
}

test "levels bitmask" {
    const mask = levelBit(.Error) | levelBit(.Warn) | levelBit(.Info);
    try testing.expect(mask & levelBit(.Error) != 0);
    try testing.expect(mask & levelBit(.Debug) == 0);
}

test "gnu short flags grouping" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-taserror", "app.log" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expect(parsed.tail_mode);
    try testing.expect(parsed.aggregate);
    try testing.expectEqualStrings("error", parsed.search.?);
    try testing.expectEqual(@as(usize, 1), parsed.files.len);
}

test "short option with inline value works" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-serror", "app.log" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expectEqualStrings("error", parsed.search.?);
    try testing.expectEqual(@as(usize, 1), parsed.files.len);
}

test "aggregate short flag does not stop grouped parsing" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-talerror", "app.log" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expect(parsed.tail_mode);
    try testing.expect(parsed.aggregate);
    try testing.expect(parsed.levels.? & levelBit(.Error) != 0);
    try testing.expectEqual(@as(usize, 1), parsed.files.len);
}

test "aggregate mode via long flag" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "--aggregate-mode", "normalized", "app.log" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expectEqual(AggregateMode.normalized, parsed.aggregate_mode);
}

test "aggregate mode via long flag with equals" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "--aggregate-mode=json-message", "app.log" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expectEqual(AggregateMode.json_message, parsed.aggregate_mode);
}

test "aggregate mode via short flag" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-m", "level-message", "app.log" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expectEqual(AggregateMode.level_message, parsed.aggregate_mode);
}

test "aggregate mode via short flag inline" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-mexact", "app.log" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expectEqual(AggregateMode.exact, parsed.aggregate_mode);
}

test "aggregate mode in grouped short flags" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-amnormalized", "app.log" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expect(parsed.aggregate);
    try testing.expectEqual(AggregateMode.normalized, parsed.aggregate_mode);
}

test "invalid aggregate mode returns error" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-m", "invalid", "app.log" } };
    var it = fake;
    try testing.expectError(error.InvalidAggregateMode, parseArgsFromIter(allocator, &it));
}

test "missing aggregate mode returns error" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-m" } };
    var it = fake;
    try testing.expectError(error.MissingAggregateMode, parseArgsFromIter(allocator, &it));
}

test "help flag stops parsing" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "--help", "app.log" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expect(parsed.help);
    try testing.expect(!parsed.tail_mode);
}

test "memory cleanup on error" {
    const fake = FakeIter{ .argv = &.{ "zlrd", "-f", "a.log", "-f", "b.log", "--bad-flag" } };
    var it = fake;
    try testing.expectError(error.UnknownArgument, parseArgsFromIter(testing.allocator, &it));
}

test "empty file list is allowed" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{"zlrd"} };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), parsed.files.len);
}

test "levels with whitespace" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-l", "error, warn , info" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    const mask = parsed.levels.?;
    try testing.expect(mask & levelBit(.Error) != 0);
    try testing.expect(mask & levelBit(.Warn) != 0);
    try testing.expect(mask & levelBit(.Info) != 0);
}

test "isLevelEnabled helper" {
    const parsed = Args{ .levels = levelBit(.Error) | levelBit(.Warn) };
    try testing.expect(parsed.isLevelEnabled(.Error));
    try testing.expect(!parsed.isLevelEnabled(.Info));
    const parsed2 = Args{};
    try testing.expect(parsed2.isLevelEnabled(.Info));
}

test "parseLevelInsensitive handles lowercase" {
    try testing.expectEqual(Level.Error, parseLevelInsensitive("error").?);
    try testing.expectEqual(Level.Warn, parseLevelInsensitive("warn").?);
    try testing.expectEqual(Level.Info, parseLevelInsensitive("info").?);
    try testing.expectEqual(Level.Debug, parseLevelInsensitive("debug").?);
    try testing.expectEqual(Level.Trace, parseLevelInsensitive("trace").?);
}

test "parseLevelInsensitive handles uppercase" {
    try testing.expectEqual(Level.Error, parseLevelInsensitive("ERROR").?);
    try testing.expectEqual(Level.Fatal, parseLevelInsensitive("FATAL").?);
}

test "parseLevelInsensitive handles mixed case" {
    try testing.expectEqual(Level.Error, parseLevelInsensitive("Error").?);
    try testing.expectEqual(Level.Panic, parseLevelInsensitive("PaNiC").?);
}

test "parseLevelInsensitive returns null for unknown" {
    try testing.expect(parseLevelInsensitive("critical") == null);
    try testing.expect(parseLevelInsensitive("") == null);
}

test "parseAggregateMode parses known values" {
    try testing.expectEqual(AggregateMode.exact, parseAggregateMode("exact").?);
    try testing.expectEqual(AggregateMode.level_message, parseAggregateMode("level-message").?);
    try testing.expectEqual(AggregateMode.json_message, parseAggregateMode("json-message").?);
    try testing.expectEqual(AggregateMode.normalized, parseAggregateMode("normalized").?);
}

test "parseAggregateMode returns null for unknown values" {
    try testing.expect(parseAggregateMode("invalid") == null);
    try testing.expect(parseAggregateMode("") == null);
}

test "addLevels is case-insensitive" {
    var parsed = Args{};
    try addLevels(&parsed, "ERROR,warn,Info");
    const mask = parsed.levels.?;
    try testing.expect(mask & levelBit(.Error) != 0);
    try testing.expect(mask & levelBit(.Warn) != 0);
    try testing.expect(mask & levelBit(.Info) != 0);
    try testing.expect(mask & levelBit(.Debug) == 0);
}

test "addLevels returns InvalidLevel for unknown string" {
    var parsed = Args{};
    try testing.expectError(error.InvalidLevel, addLevels(&parsed, "badlevel"));
}

test "level flag case-insensitive via CLI" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-l", "ERROR" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expect(parsed.levels.? & levelBit(.Error) != 0);

    const fake2 = FakeIter{ .argv = &.{ "zlrd", "--level", "error,warn" } };
    var it2 = fake2;
    const parsed2 = try parseArgsFromIter(allocator, &it2);
    defer parsed2.deinit(allocator);
    const mask2 = parsed2.levels.?;
    try testing.expect(mask2 & levelBit(.Error) != 0);
    try testing.expect(mask2 & levelBit(.Warn) != 0);

    const fake3 = FakeIter{ .argv = &.{ "zlrd", "-lerror" } };
    var it3 = fake3;
    const parsed3 = try parseArgsFromIter(allocator, &it3);
    defer parsed3.deinit(allocator);
    try testing.expect(parsed3.levels.? & levelBit(.Error) != 0);
}

test "eqlIgnoreCaseFast: correctness" {
    try testing.expect(eqlIgnoreCaseFast("hello", "HELLO"));
    try testing.expect(eqlIgnoreCaseFast("Hello", "hello"));
    try testing.expect(!eqlIgnoreCaseFast("hello", "world"));
    try testing.expect(!eqlIgnoreCaseFast("hello", "helloo"));
}

test "toLowerFast: ASCII conversion" {
    try testing.expectEqual(@as(u8, 'a'), toLowerFast('A'));
    try testing.expectEqual(@as(u8, 'z'), toLowerFast('Z'));
    try testing.expectEqual(@as(u8, 'a'), toLowerFast('a'));
    try testing.expectEqual(@as(u8, '1'), toLowerFast('1'));
}

test "version flag returns early" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "--version", "app.log" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expect(parsed.version);
}

test "version flag via -v" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-v" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expect(parsed.version);
}

test "version flag in grouped short flags stops parsing" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-tv", "app.log" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expect(parsed.tail_mode);
    try testing.expect(parsed.version);
    try testing.expectEqual(@as(usize, 0), parsed.files.len);
}

test "date filter via -d" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-d", "2023-10-01..2023-10-31", "app.log" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expectEqualStrings("2023-10-01..2023-10-31", parsed.date.?);
}

test "date filter via inline -d" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-d2023-10-15", "app.log" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expectEqualStrings("2023-10-15", parsed.date.?);
}

test "date filter via --date equals" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "--date=2023-10-01" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expectEqualStrings("2023-10-01", parsed.date.?);
}

test "num lines via -n" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-n", "50", "app.log" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expectEqual(@as(usize, 50), parsed.num_lines);
}

test "num lines via inline -n" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-n100", "app.log" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expectEqual(@as(usize, 100), parsed.num_lines);
}

test "num lines via --num-lines equals" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "--num-lines=25", "app.log" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expectEqual(@as(usize, 25), parsed.num_lines);
}

test "num lines zero returns error" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-n", "0" } };
    var it = fake;
    try testing.expectError(error.InvalidNumLines, parseArgsFromIter(allocator, &it));
}

test "num lines missing value" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-n" } };
    var it = fake;
    try testing.expectError(error.MissingNumLines, parseArgsFromIter(allocator, &it));
}

test "search via --search equals" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "--search=error" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expectEqualStrings("error", parsed.search.?);
}

test "level via --level equals" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "--level=error,warn" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    const mask = parsed.levels.?;
    try testing.expect(mask & levelBit(.Error) != 0);
    try testing.expect(mask & levelBit(.Warn) != 0);
}

test "file via --file equals" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "--file=app.log", "--file=err.log" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), parsed.files.len);
}

test "unknown short flag returns error" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-x" } };
    var it = fake;
    try testing.expectError(error.UnknownArgument, parseArgsFromIter(allocator, &it));
}

test "unknown long flag returns error" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "--unknown-flag" } };
    var it = fake;
    try testing.expectError(error.UnknownArgument, parseArgsFromIter(allocator, &it));
}

test "allLevelsMask covers all levels" {
    const mask = allLevelsMask();
    try testing.expect(mask & levelBit(.Trace) != 0);
    try testing.expect(mask & levelBit(.Debug) != 0);
    try testing.expect(mask & levelBit(.Info) != 0);
    try testing.expect(mask & levelBit(.Warn) != 0);
    try testing.expect(mask & levelBit(.Error) != 0);
    try testing.expect(mask & levelBit(.Fatal) != 0);
    try testing.expect(mask & levelBit(.Panic) != 0);
}

test "levelBit values are sequential" {
    try testing.expectEqual(@as(LevelMask, 1), levelBit(.Trace));
    try testing.expectEqual(@as(LevelMask, 2), levelBit(.Debug));
    try testing.expectEqual(@as(LevelMask, 4), levelBit(.Info));
    try testing.expectEqual(@as(LevelMask, 8), levelBit(.Warn));
    try testing.expectEqual(@as(LevelMask, 16), levelBit(.Error));
    try testing.expectEqual(@as(LevelMask, 32), levelBit(.Fatal));
    try testing.expectEqual(@as(LevelMask, 64), levelBit(.Panic));
}

test "eqlDashInsensitive treats dash and underscore as equal" {
    try testing.expect(eqlDashInsensitive("level-message", "level_message"));
    try testing.expect(eqlDashInsensitive("level_message", "level-message"));
    try testing.expect(eqlDashInsensitive("json-message", "json_message"));
    try testing.expect(!eqlDashInsensitive("level-message", "level_msg"));
    try testing.expect(!eqlDashInsensitive("", "x"));
}

test "eqlDashInsensitive is case-insensitive" {
    try testing.expect(eqlDashInsensitive("LEVEL-MESSAGE", "level_message"));
    try testing.expect(eqlDashInsensitive("Exact", "exact"));
}

test "eqlIgnoreCaseFast handles equal strings" {
    try testing.expect(eqlIgnoreCaseFast("", ""));
    try testing.expect(eqlIgnoreCaseFast("a", "A"));
    try testing.expect(!eqlIgnoreCaseFast("a", "b"));
    try testing.expect(!eqlIgnoreCaseFast("", "x"));
}

test "toLowerFast boundary values" {
    try testing.expectEqual(@as(u8, 'a'), toLowerFast('A'));
    try testing.expectEqual(@as(u8, 'z'), toLowerFast('Z'));
    try testing.expectEqual(@as(u8, '@'), toLowerFast('@'));
    try testing.expectEqual(@as(u8, '['), toLowerFast('['));
    try testing.expectEqual(@as(u8, '`'), toLowerFast('`'));
}

test "parseNumLines valid values" {
    try testing.expectEqual(@as(usize, 1), try parseNumLines("1"));
    try testing.expectEqual(@as(usize, 99999), try parseNumLines("99999"));
}

test "parseAggregateMode accepts underscore form" {
    try testing.expectEqual(AggregateMode.level_message, parseAggregateMode("level_message").?);
    try testing.expectEqual(AggregateMode.json_message, parseAggregateMode("json_message").?);
}

test "missing file value returns error" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-f" } };
    var it = fake;
    try testing.expectError(error.MissingFile, parseArgsFromIter(allocator, &it));
}

test "missing search value returns error" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-s" } };
    var it = fake;
    try testing.expectError(error.MissingSearch, parseArgsFromIter(allocator, &it));
}

test "missing date value returns error" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-d" } };
    var it = fake;
    try testing.expectError(error.MissingDate, parseArgsFromIter(allocator, &it));
}

test "missing level value returns error" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "-l" } };
    var it = fake;
    try testing.expectError(error.MissingLevel, parseArgsFromIter(allocator, &it));
}

test "missing aggregate mode via long flag returns specific error" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "--aggregate-mode" } };
    var it = fake;
    try testing.expectError(error.MissingAggregateMode, parseArgsFromIter(allocator, &it));
}

test "output json via long flag and equals" {
    const allocator = testing.allocator;

    const fake = FakeIter{ .argv = &.{ "zlrd", "--output", "json" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expect(parsed.output_json);

    const fake2 = FakeIter{ .argv = &.{ "zlrd", "--output=json" } };
    var it2 = fake2;
    const parsed2 = try parseArgsFromIter(allocator, &it2);
    defer parsed2.deinit(allocator);
    try testing.expect(parsed2.output_json);
}

test "output rejects missing and unknown modes" {
    const allocator = testing.allocator;

    const missing = FakeIter{ .argv = &.{ "zlrd", "--output" } };
    var it_missing = missing;
    try testing.expectError(error.MissingOutput, parseArgsFromIter(allocator, &it_missing));

    const invalid = FakeIter{ .argv = &.{ "zlrd", "--output", "yaml" } };
    var it_invalid = invalid;
    try testing.expectError(error.InvalidOutputMode, parseArgsFromIter(allocator, &it_invalid));

    const invalid_equals = FakeIter{ .argv = &.{ "zlrd", "--output=yaml" } };
    var it_invalid_equals = invalid_equals;
    try testing.expectError(error.InvalidOutputMode, parseArgsFromIter(allocator, &it_invalid_equals));
}

test "empty level list is invalid" {
    const allocator = testing.allocator;

    const fake = FakeIter{ .argv = &.{ "zlrd", "--level=, , " } };
    var it = fake;
    try testing.expectError(error.InvalidLevel, parseArgsFromIter(allocator, &it));
}

test "allLevelsMask has no unused bits" {
    try testing.expectEqual(@as(LevelMask, 0x7F), allLevelsMask());
}

test "agent: flag toggles agent_mode" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "--agent", "app.log" } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expect(parsed.agent_mode);
    try testing.expectEqual(@as(usize, 1), parsed.files.len);
}

test "agent: listen + metrics-token parsed and owned" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{
        "zlrd",
        "--agent",
        "--listen",
        "0.0.0.0:9100",
        "--metrics-token=secret123",
        "app.log",
    } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expectEqualStrings("0.0.0.0:9100", parsed.listen.?);
    try testing.expectEqualStrings("secret123", parsed.metrics_token.?);
}

test "agent: missing metrics-token value surfaces specific error" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{ "zlrd", "--metrics-token" } };
    var it = fake;
    try testing.expectError(error.MissingMetricsToken, parseArgsFromIter(allocator, &it));
}

test "agent: repeatable alert-regex collects all values" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{
        "zlrd",
        "--alert-regex=panic:5/30s",
        "--alert-regex",
        "OOMKilled:1/60s",
        "app.log",
    } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), parsed.alert_regexes.len);
    try testing.expectEqualStrings("panic:5/30s", parsed.alert_regexes[0]);
    try testing.expectEqualStrings("OOMKilled:1/60s", parsed.alert_regexes[1]);
}

test "agent: webhook + headers collected" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{
        "zlrd",
        "--alert-webhook",
        "https://example.com/hook",
        "--webhook-header",
        "Authorization: Bearer xyz",
        "--webhook-header=X-Source: zlrd",
        "app.log",
    } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), parsed.alert_webhooks.len);
    try testing.expectEqual(@as(usize, 2), parsed.webhook_headers.len);
    try testing.expectEqualStrings("Authorization: Bearer xyz", parsed.webhook_headers[0]);
}

test "agent: bool flags parse" {
    const allocator = testing.allocator;
    const fake = FakeIter{ .argv = &.{
        "zlrd",
        "--alert-first-seen",
        "--alert-stderr",
        "--alert-exit",
        "app.log",
    } };
    var it = fake;
    const parsed = try parseArgsFromIter(allocator, &it);
    defer parsed.deinit(allocator);
    try testing.expect(parsed.alert_first_seen);
    try testing.expect(parsed.alert_stderr);
    try testing.expect(parsed.alert_exit_on_alert);
}
