const std = @import("std");

/// Log severity levels.
/// Numeric values are used to build a compact bitmask.
pub const Level = enum(u8) {
    Trace = 0,
    Debug = 1,
    Info = 2,
    Warn = 3,
    Error = 4,
    Fatal = 5,
    Panic = 6,
};

/// Bitmask of enabled log levels.
/// Each bit corresponds to a `Level` enum value.
pub const LevelMask = u8;

/// Returns a bitmask with all levels enabled.
pub fn allLevelsMask() LevelMask {
    return (1 << 7) - 1; // 0b01111111
}

/// Describes a CLI option in short and long form.
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

/// Returns a bitmask with a single bit set for the given level.
pub inline fn levelBit(l: Level) LevelMask {
    const shift: u3 = @intCast(@intFromEnum(l));
    return @as(LevelMask, 1) << shift;
}

/// Parse a level string case-insensitively.
/// Accepts any casing: "error", "ERROR", "Error", "eRRoR", etc.
/// Returns `null` if the string does not match any known level.
pub fn parseLevelInsensitive(s: []const u8) ?Level {
    if (s.len == 0 or s.len > 7) return null;

    inline for (std.meta.fields(Level)) |field| {
        if (eqlIgnoreCaseFast(s, field.name)) {
            return @enumFromInt(field.value);
        }
    }

    return null;
}

/// Fast ASCII-only case-insensitive compare.
///
/// `b` is comptime-known so short level names are compared with an unrolled loop.
inline fn eqlIgnoreCaseFast(a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;

    if (comptime b.len <= 8) {
        comptime var i: usize = 0;
        inline while (i < b.len) : (i += 1) {
            if (toLowerFast(a[i]) != toLowerFast(b[i])) {
                return false;
            }
        }
        return true;
    }

    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (toLowerFast(a[i]) != toLowerFast(b[i])) {
            return false;
        }
    }
    return true;
}

/// Lowercase a single ASCII byte.
/// Non-uppercase ASCII bytes are returned unchanged.
inline fn toLowerFast(c: u8) u8 {
    const is_upper = (c >= 'A') and (c <= 'Z');
    return c + @as(u8, if (is_upper) 32 else 0);
}

/// Result of command-line parsing.
/// All fields are validated and ready for use by the reader.
pub const Args = struct {
    /// List of log file paths.
    ///
    /// Can be empty if the user did not pass any files.
    /// The caller may then apply its own fallback behavior.
    files: [][]const u8,

    /// Search expression (`-s` / `--search`).
    /// Supports simple AND/OR expressions.
    search: ?[]const u8 = null,

    /// Enabled log levels bitmask.
    /// `null` means "all levels enabled".
    levels: ?LevelMask = null,

    /// Date filter (`YYYY-MM-DD` or range `YYYY-MM-DD..YYYY-MM-DD`).
    date: ?[]const u8 = null,

    /// Enable tail mode (`-t` / `--tail`).
    tail_mode: bool = false,

    /// Show help and exit.
    help: bool = false,

    /// Print version and exit (`-v` / `--version`).
    version: bool = false,

    /// Number of lines to display (`-n` / `--num-lines`).
    num_lines: usize = 0,

    /// Aggregate log rows (`-a` / `--aggregate`).
    aggregate: bool = false,

    /// Free allocated memory owned by this struct.
    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        if (self.files.len > 0) allocator.free(self.files);
        self.* = undefined;
    }

    /// Check whether a level is enabled.
    pub fn isLevelEnabled(self: Args, level: Level) bool {
        const mask = self.levels orelse return true;
        return (mask & levelBit(level)) != 0;
    }
};

/// Errors that may occur during argument parsing.
pub const ParseError = error{
    /// Allocator failure.
    OutOfMemory,

    /// Required value is missing.
    MissingFile,
    MissingSearch,
    MissingLevel,
    MissingDate,
    MissingNumLines,

    /// Invalid value provided.
    InvalidLevel,
    InvalidNumLines,

    /// Unknown or unsupported flag.
    UnknownArgument,
};

/// Parse command-line arguments from the real process argv.
///
/// On Windows this uses `ArgIterator.initWithAllocator`,
/// which is required for cross-platform support.
pub fn parseArgs(allocator: std.mem.Allocator) ParseError!Args {
    var it = try std.process.ArgIterator.initWithAllocator(allocator);
    defer it.deinit();

    return parseArgsFromIter(allocator, &it);
}

/// Print usage information to stderr.
pub fn printHelp() void {
    std.debug.print(
        \\Usage:
        \\  zlrd [options] <file...>
        \\
        \\Options:
        \\  -{c}, --{s} <path>        Add log file (can be repeated)
        \\  -{c}, --{s} <text>      Search string
        \\  -{c}, --{s} <levels>     Levels: trace,debug,info,warn,error,fatal,panic
        \\                           Case-insensitive. Multiple: -l error,warn -l fatal
        \\  -{c}, --{s} <date>        Date filter (YYYY-MM-DD)
        \\  -{c}, --{s}               Tail mode
        \\  -{c}, --{s} <num>    Number of lines to display
        \\  -{c}, --{s}            Print version and exit
        \\  -{c}, --{s}               Show help
        \\  -{c}, --{s}          Aggregate log rows
        \\
    , .{
        OptionFile.short,      OptionFile.long,
        OptionSearch.short,    OptionSearch.long,
        OptionLevel.short,     OptionLevel.long,
        OptionDate.short,      OptionDate.long,
        OptionTail.short,      OptionTail.long,
        OptionNumLines.short,  OptionNumLines.long,
        OptionVersion.short,   OptionVersion.long,
        OptionHelp.short,      OptionHelp.long,
        OptionAggregate.short, OptionAggregate.long,
    });
}

/// Core argument parser that operates on a generic iterator.
///
/// This is separated from `parseArgs` to make unit testing easy
/// without depending on the real process argv.
fn parseArgsFromIter(
    allocator: std.mem.Allocator,
    it: anytype,
) ParseError!Args {
    // Skip argv[0] (program name).
    _ = it.next();

    // Collect file paths incrementally with a reasonable initial capacity.
    var files = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    errdefer files.deinit(allocator);

    var args = Args{
        .files = &.{},
    };

    while (it.next()) |arg| {
        // Early exit for help.
        if (std.mem.eql(u8, arg, "-" ++ [_]u8{OptionHelp.short}) or
            std.mem.eql(u8, arg, "--" ++ OptionHelp.long))
        {
            args.help = true;
            args.files = try files.toOwnedSlice(allocator);
            return args;
        }

        // Early exit for version.
        if (std.mem.eql(u8, arg, "-" ++ [_]u8{OptionVersion.short}) or
            std.mem.eql(u8, arg, "--" ++ OptionVersion.long))
        {
            args.version = true;
            args.files = try files.toOwnedSlice(allocator);
            return args;
        }

        // Long flags: --flag or --flag=value
        if (std.mem.startsWith(u8, arg, "--")) {
            try parseLongFlag(&args, &files, arg, it, allocator);
            continue;
        }

        // Short flags: -a, -abc, -fvalue
        if (arg.len > 1 and arg[0] == '-') {
            try parseShortFlags(&args, &files, arg[1..], it, allocator);
            continue;
        }

        // Positional argument → file path.
        try files.append(allocator, arg);
    }

    // Finalize files slice.
    // Empty file list is valid. The caller may choose a fallback strategy.
    args.files = try files.toOwnedSlice(allocator);
    errdefer allocator.free(args.files);

    return args;
}

/// Long flags (`--flag`, `--flag=value`).
fn parseLongFlag(
    args: *Args,
    files: *std.ArrayList([]const u8),
    arg: []const u8,
    it: anytype,
    allocator: std.mem.Allocator,
) ParseError!void {
    const body = arg[2..];
    const eq = std.mem.indexOfScalar(u8, body, '=');

    const name = if (eq) |i| body[0..i] else body;
    const value = if (eq) |i| body[i + 1 ..] else null;

    if (std.mem.eql(u8, name, OptionHelp.long)) {
        args.help = true;
        return;
    }

    if (std.mem.eql(u8, name, OptionVersion.long)) {
        args.version = true;
        return;
    }

    if (std.mem.eql(u8, name, OptionTail.long)) {
        args.tail_mode = true;
        return;
    }

    if (std.mem.eql(u8, name, OptionFile.long)) {
        const f = value orelse it.next() orelse return ParseError.MissingFile;
        try files.append(allocator, f);
        return;
    }

    if (std.mem.eql(u8, name, OptionSearch.long)) {
        args.search = value orelse it.next() orelse return ParseError.MissingSearch;
        return;
    }

    if (std.mem.eql(u8, name, OptionLevel.long)) {
        const v = value orelse it.next() orelse return ParseError.MissingLevel;
        try addLevels(&args.levels, v);
        return;
    }

    if (std.mem.eql(u8, name, OptionDate.long)) {
        args.date = value orelse it.next() orelse return ParseError.MissingDate;
        return;
    }

    if (std.mem.eql(u8, name, OptionNumLines.long)) {
        const v = value orelse it.next() orelse return ParseError.MissingNumLines;
        args.num_lines = std.fmt.parseUnsigned(usize, v, 10) catch return ParseError.InvalidNumLines;
        return;
    }

    if (std.mem.eql(u8, name, OptionAggregate.long)) {
        args.aggregate = true;
        return;
    }

    return ParseError.UnknownArgument;
}

/// Parse grouped short flags (GNU-style).
///
/// Examples:
///   `-tl Error`
///   `-fpath`
///   `-n10`
fn parseShortFlags(
    args: *Args,
    files: *std.ArrayList([]const u8),
    group: []const u8,
    it: anytype,
    allocator: std.mem.Allocator,
) ParseError!void {
    var i: usize = 0;
    while (i < group.len) : (i += 1) {
        switch (group[i]) {
            OptionHelp.short => {
                args.help = true;
                return;
            },
            OptionVersion.short => {
                args.version = true;
                return;
            },
            OptionTail.short => args.tail_mode = true,

            OptionFile.short => {
                const v = valueOrNext(group, &i, it) orelse return ParseError.MissingFile;
                try files.append(allocator, v);
                return;
            },

            OptionSearch.short => {
                const v = valueOrNext(group, &i, it) orelse return ParseError.MissingSearch;
                args.search = v;
                return;
            },

            OptionLevel.short => {
                const v = valueOrNext(group, &i, it) orelse return ParseError.MissingLevel;
                try addLevels(&args.levels, v);
                return;
            },

            OptionDate.short => {
                const v = valueOrNext(group, &i, it) orelse return ParseError.MissingDate;
                args.date = v;
                return;
            },

            OptionNumLines.short => {
                const v = valueOrNext(group, &i, it) orelse return ParseError.MissingNumLines;
                args.num_lines = std.fmt.parseUnsigned(usize, v, 10) catch return ParseError.InvalidNumLines;
                return;
            },

            OptionAggregate.short => {
                args.aggregate = true;
            },

            else => return ParseError.UnknownArgument,
        }
    }
}

/// Returns an inline value from grouped flags (`-fvalue`, `-n10`)
/// or consumes the next argv element.
///
/// Inline value is allowed only when this flag is the last one in the group.
inline fn valueOrNext(
    group: []const u8,
    index: *usize,
    it: anytype,
) ?[]const u8 {
    if (index.* + 1 < group.len) {
        const inline_value = group[index.* + 1 ..];
        index.* = group.len;
        return inline_value;
    }

    return it.next();
}

/// Parse comma-separated log levels and update the bitmask.
///
/// Uses `parseLevelInsensitive`, so any casing is accepted.
fn addLevels(mask: *?LevelMask, value: []const u8) ParseError!void {
    const current = mask.* orelse 0;
    var new_mask = current;

    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        const lvl = parseLevelInsensitive(trimmed) orelse return ParseError.InvalidLevel;
        new_mask |= levelBit(lvl);
    }

    mask.* = new_mask;
}

// ============================================================================
// Unit Tests
// ============================================================================
const testing = std.testing;

/// Minimal argv iterator used by unit tests.
const FakeIter = struct {
    argv: []const []const u8,
    index: usize = 0,

    pub fn next(self: *FakeIter) ?[]const u8 {
        if (self.index >= self.argv.len) return null;
        const v = self.argv[self.index];
        self.index += 1;
        return v;
    }
};

test "single file via -f" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const argv = [_][]const u8{ "zlrd", "-f", "log.txt" };
    var it = FakeIter{ .argv = &argv };
    var args = try parseArgsFromIter(arena.allocator(), &it);
    defer args.deinit(arena.allocator());

    try testing.expectEqual(@as(usize, 1), args.files.len);
    try testing.expectEqualStrings("log.txt", args.files[0]);
}

test "multiple files mixed positional and -f" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const argv = [_][]const u8{
        "zlrd", "-f", "a.log", "b.log", "-f", "c.log",
        "-n",   "10", "-s",    "test",  "-d", "2025-01-01..2025-12-31",
        "-t",
    };
    var it = FakeIter{ .argv = &argv };
    var args = try parseArgsFromIter(arena.allocator(), &it);
    defer args.deinit(arena.allocator());

    try testing.expectEqual(@as(usize, 3), args.files.len);
    try testing.expectEqualStrings("a.log", args.files[0]);
    try testing.expectEqualStrings("b.log", args.files[1]);
    try testing.expectEqualStrings("c.log", args.files[2]);
    try testing.expectEqual(@as(usize, 10), args.num_lines);
    try testing.expectEqualStrings("test", args.search.?);
    try testing.expectEqualStrings("2025-01-01..2025-12-31", args.date.?);
    try testing.expectEqual(true, args.tail_mode);
}

test "multiple long flags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const argv = [_][]const u8{
        "zlrd",          "--file=a.log",      "--num-lines=10",
        "--search=test", "--date=2025-01-01", "--tail",
    };
    var it = FakeIter{ .argv = &argv };
    var args = try parseArgsFromIter(arena.allocator(), &it);
    defer args.deinit(arena.allocator());

    try testing.expectEqual(@as(usize, 1), args.files.len);
    try testing.expectEqualStrings("a.log", args.files[0]);
    try testing.expectEqual(@as(usize, 10), args.num_lines);
    try testing.expectEqualStrings("test", args.search.?);
    try testing.expectEqualStrings("2025-01-01", args.date.?);
    try testing.expectEqual(true, args.tail_mode);
}

test "mixed flags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const argv = [_][]const u8{ "zlrd", "-f", "a.log", "--level=Fatal" };
    var it = FakeIter{ .argv = &argv };
    var args = try parseArgsFromIter(arena.allocator(), &it);
    defer args.deinit(arena.allocator());

    try testing.expectEqual(@as(usize, 1), args.files.len);
    try testing.expect((args.levels.? & levelBit(.Fatal)) != 0);
}

test "mixed flags with grouping" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const argv = [_][]const u8{
        "zlrd",   "-f", "a.log", "-l",   "Error",
        "-n",     "10", "-s",    "test", "--date=2025-01-01",
        "--tail",
    };
    var it = FakeIter{ .argv = &argv };
    var args = try parseArgsFromIter(arena.allocator(), &it);
    defer args.deinit(arena.allocator());

    try testing.expectEqual(@as(usize, 1), args.files.len);
    try testing.expectEqual(@as(usize, 10), args.num_lines);
    try testing.expectEqualStrings("test", args.search.?);
    try testing.expectEqualStrings("2025-01-01", args.date.?);
    try testing.expectEqual(true, args.tail_mode);
}

test "levels bitmask" {
    var mask: ?LevelMask = null;
    try addLevels(&mask, "Error,Warn");

    const m = mask.?;
    try testing.expect((m & levelBit(.Error)) != 0);
    try testing.expect((m & levelBit(.Warn)) != 0);
    try testing.expect((m & levelBit(.Info)) == 0);
}

test "gnu short flags grouping" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const argv = [_][]const u8{
        "zlrd", "-tl", "Error", "-n", "10", "-s", "test", "log.txt",
    };
    var it = FakeIter{ .argv = &argv };
    var args = try parseArgsFromIter(arena.allocator(), &it);
    defer args.deinit(arena.allocator());

    try testing.expect(args.tail_mode);
    try testing.expect((args.levels.? & levelBit(.Error)) != 0);
    try testing.expectEqual(@as(usize, 1), args.files.len);
    try testing.expectEqual(@as(usize, 10), args.num_lines);
    try testing.expectEqualStrings("test", args.search.?);
}

test "short option with inline value works" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const argv = [_][]const u8{
        "zlrd", "-fa.log", "-n10", "-serror", "-lWarn",
    };
    var it = FakeIter{ .argv = &argv };
    var args = try parseArgsFromIter(arena.allocator(), &it);
    defer args.deinit(arena.allocator());

    try testing.expectEqual(@as(usize, 1), args.files.len);
    try testing.expectEqualStrings("a.log", args.files[0]);
    try testing.expectEqual(@as(usize, 10), args.num_lines);
    try testing.expectEqualStrings("error", args.search.?);
    try testing.expect((args.levels.? & levelBit(.Warn)) != 0);
}

test "aggregate short flag does not stop grouped parsing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const argv = [_][]const u8{
        "zlrd", "-at", "log.txt",
    };
    var it = FakeIter{ .argv = &argv };
    var args = try parseArgsFromIter(arena.allocator(), &it);
    defer args.deinit(arena.allocator());

    try testing.expect(args.aggregate);
    try testing.expect(args.tail_mode);
    try testing.expectEqual(@as(usize, 1), args.files.len);
    try testing.expectEqualStrings("log.txt", args.files[0]);
}

test "help flag stops parsing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const argv = [_][]const u8{ "zlrd", "-h" };
    var it = FakeIter{ .argv = &argv };
    var args = try parseArgsFromIter(arena.allocator(), &it);
    defer args.deinit(arena.allocator());

    try testing.expect(args.help);
}

test "memory cleanup on error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const argv = [_][]const u8{ "zlrd", "-f", "a.log", "-l" };
    var it = FakeIter{ .argv = &argv };
    const result = parseArgsFromIter(arena.allocator(), &it);

    try testing.expectError(ParseError.MissingLevel, result);
}

test "empty file list is allowed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const argv = [_][]const u8{"zlrd"};
    var it = FakeIter{ .argv = &argv };
    var args = try parseArgsFromIter(arena.allocator(), &it);
    defer args.deinit(arena.allocator());

    try testing.expectEqual(@as(usize, 0), args.files.len);
    try testing.expect(args.search == null);
    try testing.expect(args.levels == null);
}

test "levels with whitespace" {
    var mask: ?LevelMask = null;
    try addLevels(&mask, " Error , Warn ");

    const m = mask.?;
    try testing.expect((m & levelBit(.Error)) != 0);
    try testing.expect((m & levelBit(.Warn)) != 0);
}

test "isLevelEnabled helper" {
    var args = Args{
        .files = &.{},
        .levels = levelBit(.Error) | levelBit(.Fatal),
    };

    try testing.expect(args.isLevelEnabled(.Error));
    try testing.expect(args.isLevelEnabled(.Fatal));
    try testing.expect(!args.isLevelEnabled(.Info));

    // `null` means all levels are enabled.
    args.levels = null;
    try testing.expect(args.isLevelEnabled(.Trace));
    try testing.expect(args.isLevelEnabled(.Error));
}

test "parseLevelInsensitive handles lowercase" {
    try testing.expectEqual(Level.Trace, parseLevelInsensitive("trace").?);
    try testing.expectEqual(Level.Debug, parseLevelInsensitive("debug").?);
    try testing.expectEqual(Level.Info, parseLevelInsensitive("info").?);
    try testing.expectEqual(Level.Warn, parseLevelInsensitive("warn").?);
    try testing.expectEqual(Level.Error, parseLevelInsensitive("error").?);
    try testing.expectEqual(Level.Fatal, parseLevelInsensitive("fatal").?);
    try testing.expectEqual(Level.Panic, parseLevelInsensitive("panic").?);
}

test "parseLevelInsensitive handles uppercase" {
    try testing.expectEqual(Level.Error, parseLevelInsensitive("ERROR").?);
    try testing.expectEqual(Level.Warn, parseLevelInsensitive("WARN").?);
    try testing.expectEqual(Level.Info, parseLevelInsensitive("INFO").?);
}

test "parseLevelInsensitive handles mixed case" {
    try testing.expectEqual(Level.Error, parseLevelInsensitive("eRRoR").?);
    try testing.expectEqual(Level.Debug, parseLevelInsensitive("DeBuG").?);
    try testing.expectEqual(Level.Fatal, parseLevelInsensitive("fAtAl").?);
}

test "parseLevelInsensitive returns null for unknown" {
    try testing.expect(parseLevelInsensitive("") == null);
    try testing.expect(parseLevelInsensitive("invalid") == null);
    try testing.expect(parseLevelInsensitive("err") == null);
}

test "addLevels is case-insensitive" {
    var mask1: ?LevelMask = null;
    try addLevels(&mask1, "error,warn");
    try testing.expect((mask1.? & levelBit(.Error)) != 0);
    try testing.expect((mask1.? & levelBit(.Warn)) != 0);

    var mask2: ?LevelMask = null;
    try addLevels(&mask2, "ERROR,WARN");
    try testing.expect((mask2.? & levelBit(.Error)) != 0);
    try testing.expect((mask2.? & levelBit(.Warn)) != 0);

    var mask3: ?LevelMask = null;
    try addLevels(&mask3, "eRrOr,wArN,fAtAl");
    try testing.expect((mask3.? & levelBit(.Error)) != 0);
    try testing.expect((mask3.? & levelBit(.Warn)) != 0);
    try testing.expect((mask3.? & levelBit(.Fatal)) != 0);
    try testing.expect((mask3.? & levelBit(.Info)) == 0);
}

test "addLevels returns InvalidLevel for unknown string" {
    var mask: ?LevelMask = null;
    try testing.expectError(ParseError.InvalidLevel, addLevels(&mask, "notlevel"));
    try testing.expectError(ParseError.InvalidLevel, addLevels(&mask, "Error,badlevel"));
}

test "level flag case-insensitive via CLI" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    {
        const argv = [_][]const u8{ "zlrd", "-f", "a.log", "-l", "error" };
        var it = FakeIter{ .argv = &argv };
        var args = try parseArgsFromIter(arena.allocator(), &it);
        defer args.deinit(arena.allocator());
        try testing.expect((args.levels.? & levelBit(.Error)) != 0);
    }

    {
        const argv = [_][]const u8{ "zlrd", "-f", "a.log", "--level=ERROR" };
        var it = FakeIter{ .argv = &argv };
        var args = try parseArgsFromIter(arena.allocator(), &it);
        defer args.deinit(arena.allocator());
        try testing.expect((args.levels.? & levelBit(.Error)) != 0);
    }

    {
        const argv = [_][]const u8{ "zlrd", "-f", "a.log", "--level=eRrOr,wArN" };
        var it = FakeIter{ .argv = &argv };
        var args = try parseArgsFromIter(arena.allocator(), &it);
        defer args.deinit(arena.allocator());
        try testing.expect((args.levels.? & levelBit(.Error)) != 0);
        try testing.expect((args.levels.? & levelBit(.Warn)) != 0);
        try testing.expect((args.levels.? & levelBit(.Info)) == 0);
    }
}

test "eqlIgnoreCaseFast: correctness" {
    try testing.expect(eqlIgnoreCaseFast("error", "ERROR"));
    try testing.expect(eqlIgnoreCaseFast("Error", "eRRoR"));
    try testing.expect(eqlIgnoreCaseFast("WaRn", "warn"));
    try testing.expect(!eqlIgnoreCaseFast("error", "warn"));
    try testing.expect(!eqlIgnoreCaseFast("error", "erro"));
}

test "toLowerFast: ASCII conversion" {
    try testing.expectEqual(@as(u8, 'a'), toLowerFast('A'));
    try testing.expectEqual(@as(u8, 'z'), toLowerFast('Z'));
    try testing.expectEqual(@as(u8, 'a'), toLowerFast('a'));
    try testing.expectEqual(@as(u8, 'z'), toLowerFast('z'));
    try testing.expectEqual(@as(u8, '0'), toLowerFast('0'));
}
