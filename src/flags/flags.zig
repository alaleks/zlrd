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
    return 0xFF;
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

    pub fn deinit(self: Args, allocator: std.mem.Allocator) void {
        for (self.files) |f| allocator.free(f);
        allocator.free(self.files);
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
    MissingSearch,
    MissingLevel,
    MissingDate,
    MissingNumLines,
    MissingAggregateMode,
    MissingFromTime,
    MissingToTime,
    UnknownArgument,
    OutOfMemory,
};

pub fn parseArgs(allocator: std.mem.Allocator, process_args: std.process.Args) ParseError!Args {
    var it = try std.process.Args.iterateAllocator(process_args, allocator);
    defer it.deinit();

    return parseArgsFromIter(allocator, &it);
}

pub fn printHelp() void {
    std.debug.print(
        \\Usage:
        \\  zlrd [options] <file...>
        \\
        \\Options:
        \\  -{c}, --{s:<16} <path>   Add log file (can be repeated)
        \\  -{c}, --{s:<16} <text>   Search string
        \\  -{c}, --{s:<16} <levels> Levels: trace,debug,info,warn,error,fatal,panic
        \\                           Case-insensitive. Multiple: -l error,warn -l fatal
        \\  -{c}, --{s:<16} <date>   Date filter (YYYY-MM-DD or YYYY-MM-DD..YYYY-MM-DD)
        \\  -{c}, --{s:<16}          Tail mode
        \\  -{c}, --{s:<16} <num>    Number of lines to display
        \\  -{c}, --{s:<16}          Print version and exit
        \\  -{c}, --{s:<16}          Show help
        \\  -{c}, --{s:<16}          Aggregate matched log rows
        \\  -{c}, --{s:<16} <mode>   Aggregate mode: exact | level-message | json-message | normalized
        \\      --from <time>        Time range start (HH:MM or HH:MM:SS)
        \\      --to <time>          Time range end (HH:MM or HH:MM:SS)
        \\      --output json        Output as JSONL (pipe to jq)
        \\
    , .{
        OptionFile.short,          OptionFile.long,
        OptionSearch.short,        OptionSearch.long,
        OptionLevel.short,         OptionLevel.long,
        OptionDate.short,          OptionDate.long,
        OptionTail.short,          OptionTail.long,
        OptionNumLines.short,      OptionNumLines.long,
        OptionVersion.short,       OptionVersion.long,
        OptionHelp.short,          OptionHelp.long,
        OptionAggregate.short,     OptionAggregate.long,
        OptionAggregateMode.short, OptionAggregateMode.long,
    });
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

fn parseArgsFromIter(
    allocator: std.mem.Allocator,
    it: anytype,
) ParseError!Args {
    _ = it.next();

    var files = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    errdefer freeFileList(allocator, &files);

    var parsed = Args{
        .files = &.{},
    };

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            parsed.help = true;
            parsed.files = try files.toOwnedSlice(allocator);
            return parsed;
        }

        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            parsed.version = true;
            parsed.files = try files.toOwnedSlice(allocator);
            return parsed;
        }

        if (std.mem.startsWith(u8, arg, "--")) {
            try parseLongFlag(&parsed, &files, arg, it, allocator);
            continue;
        }

        if (arg.len > 1 and arg[0] == '-') {
            try parseShortFlags(&parsed, &files, arg[1..], it, allocator);
            continue;
        }

        try appendFile(allocator, &files, arg);
    }

    parsed.files = try files.toOwnedSlice(allocator);
    return parsed;
}

fn freeFileList(allocator: std.mem.Allocator, files: *std.ArrayList([]const u8)) void {
    for (files.items) |f| allocator.free(f);
    files.deinit(allocator);
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

fn parseLongFlag(
    parsed: *Args,
    files: *std.ArrayList([]const u8),
    arg: []const u8,
    it: anytype,
    allocator: std.mem.Allocator,
) ParseError!void {
    const flag = if (std.mem.indexOfScalar(u8, arg, '=')) |eq_pos| blk: {
        const val = arg[eq_pos + 1 ..];
        const f = arg[2..eq_pos];
        if (std.mem.eql(u8, f, "file")) {
            try appendFile(allocator, files, val);
            return;
        }
        if (std.mem.eql(u8, f, "search")) {
            parsed.search = val;
            return;
        }
        if (std.mem.eql(u8, f, "level")) {
            try addLevels(parsed, val);
            return;
        }
        if (std.mem.eql(u8, f, "date")) {
            parsed.date = val;
            return;
        }
        if (std.mem.eql(u8, f, "num-lines")) {
            parsed.num_lines = parseNumLines(val) catch return error.InvalidNumLines;
            return;
        }
        if (std.mem.eql(u8, f, "aggregate-mode")) {
            parsed.aggregate_mode = parseAggregateMode(val) orelse return error.InvalidAggregateMode;
            return;
        }
        if (std.mem.eql(u8, f, "from")) {
            parsed.from_time = val;
            return;
        }
        if (std.mem.eql(u8, f, "to")) {
            parsed.to_time = val;
            return;
        }
        if (std.mem.eql(u8, f, "output")) {
            if (std.mem.eql(u8, val, "json")) parsed.output_json = true;
            return;
        }
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
    if (std.mem.eql(u8, flag, "output")) {
        const val = valueOrNext(it, flag) orelse return;
        if (std.mem.eql(u8, val, "json")) parsed.output_json = true;
        return;
    }
    if (std.mem.eql(u8, flag, "file") or
        std.mem.eql(u8, flag, "search") or
        std.mem.eql(u8, flag, "level") or
        std.mem.eql(u8, flag, "date") or
        std.mem.eql(u8, flag, "num-lines") or
        std.mem.eql(u8, flag, "aggregate-mode") or
        std.mem.eql(u8, flag, "from") or
        std.mem.eql(u8, flag, "to"))
    {
        const val = valueOrNext(it, flag) orelse return switch (flag[0]) {
            'f' => error.MissingFile,
            's' => error.MissingSearch,
            'l' => error.MissingLevel,
            'd' => error.MissingDate,
            'n' => error.MissingNumLines,
            'm' => error.MissingAggregateMode,
            else => if (std.mem.eql(u8, flag, "from")) error.MissingFromTime else error.MissingToTime,
        };
        if (std.mem.eql(u8, flag, "file")) {
            try appendFile(allocator, files, val);
        } else if (std.mem.eql(u8, flag, "search")) {
            parsed.search = val;
        } else if (std.mem.eql(u8, flag, "level")) {
            try addLevels(parsed, val);
        } else if (std.mem.eql(u8, flag, "date")) {
            parsed.date = val;
        } else if (std.mem.eql(u8, flag, "num-lines")) {
            parsed.num_lines = parseNumLines(val) catch return error.InvalidNumLines;
        } else if (std.mem.eql(u8, flag, "aggregate-mode")) {
            parsed.aggregate_mode = parseAggregateMode(val) orelse return error.InvalidAggregateMode;
        } else if (std.mem.eql(u8, flag, "from")) {
            parsed.from_time = val;
        } else if (std.mem.eql(u8, flag, "to")) {
            parsed.to_time = val;
        }
        return;
    }

    return error.UnknownArgument;
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
                    parsed.search = rest;
                    return;
                }
                parsed.search = valueOrNext(it, "search") orelse return error.MissingSearch;
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
                    parsed.date = rest;
                    return;
                }
                parsed.date = valueOrNext(it, "date") orelse return error.MissingDate;
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
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        const lvl = parseLevelInsensitive(trimmed) orelse return error.InvalidLevel;
        if (parsed.levels == null) parsed.levels = 0;
        parsed.levels.? |= levelBit(lvl);
    }
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
