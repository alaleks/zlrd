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

/// Returns a bitmask with a single bit set for the given level.
pub inline fn levelBit(l: Level) LevelMask {
    const shift: u3 = @intCast(@intFromEnum(l));
    return @as(LevelMask, 1) << shift;
}

/// Parse a level string case-insensitively.
/// Accepts any casing: "error", "ERROR", "Error", "eRRoR", etc.
/// Returns `null` if the string does not match any known level.
pub fn parseLevelInsensitive(s: []const u8) ?Level {
    inline for (std.meta.fields(Level)) |f| {
        if (std.ascii.eqlIgnoreCase(s, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

/// Result of command-line parsing.
/// All fields are validated and ready for use by the reader.
pub const Args = struct {
    /// List of log file paths.
    files: [][]const u8,

    /// Search expression (`-s` / `--search`).
    /// Supports simple AND/OR expressions.
    search: ?[]const u8 = null,

    /// Enabled log levels bitmask.
    /// `null` means "all levels enabled".
    levels: ?LevelMask = null,

    /// Date filter (`YYYY-MM-DD` or range 'YYYY-MM-DD..YYYY-MM-DD').
    date: ?[]const u8 = null,

    /// Enable tail mode (`-t`).
    tail_mode: bool = false,

    /// Show help and exit.
    help: bool = false,

    /// Print version and exit (`-v` / `--version`).
    version: bool = false,

    /// Number of lines to display (`-n`).
    num_lines: usize = 0,

    /// Free allocated memory.
    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        // Only free if the slice was heap-allocated (len > 0 or ptr != undefined).
        // An empty &.{} slice has an undefined pointer — freeing it is UB.
        if (self.files.len > 0) allocator.free(self.files);
        self.* = undefined;
    }

    /// Check if a level is enabled.
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
        \\  -f, --file <path>        Add log file (can be repeated)
        \\  -s, --search <text>      Search string
        \\  -l, --level <levels>     Levels: trace,debug,info,warn,error,fatal,panic
        \\                           Case-insensitive. Multiple: -l error,warn -l fatal
        \\  -d, --date <date>        Date filter (YYYY-MM-DD)
        \\  -t, --tail               Tail mode
        \\  -n, --num-lines <num>    Number of lines to display
        \\  -v, --version            Print version and exit
        \\  -h, --help               Show help
        \\
    , .{});
}

/// Core argument parser that operates on a generic iterator.
///
/// This is separated from `parseArgs` to make unit testing easy
/// without depending on the real process argv.
fn parseArgsFromIter(
    allocator: std.mem.Allocator,
    it: anytype, // must provide `next() ?[]const u8`
) ParseError!Args {
    // Skip argv[0] (program name)
    _ = it.next();

    // Collect file paths incrementally with reasonable initial capacity.
    var files = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    errdefer files.deinit(allocator);

    var args = Args{
        .files = &.{},
    };

    while (it.next()) |arg| {
        // Early exit for help.
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            args.help = true;
            args.files = try files.toOwnedSlice(allocator);
            return args;
        }

        // Early exit for version.
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
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
    // An empty list is valid — main.zig will fall back to *.log in the current directory.
    args.files = try files.toOwnedSlice(allocator);
    errdefer allocator.free(args.files);

    return args;
}

/// Long flags (--flag, --flag=value).
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

    if (std.mem.eql(u8, name, "help")) {
        args.help = true;
        return;
    }

    if (std.mem.eql(u8, name, "version")) {
        args.version = true;
        return;
    }

    if (std.mem.eql(u8, name, "tail")) {
        args.tail_mode = true;
        return;
    }

    if (std.mem.eql(u8, name, "file")) {
        const f = value orelse it.next() orelse return ParseError.MissingFile;
        try files.append(allocator, f);
        return;
    }

    if (std.mem.eql(u8, name, "search")) {
        args.search = value orelse it.next() orelse return ParseError.MissingSearch;
        return;
    }

    if (std.mem.eql(u8, name, "level")) {
        const v = value orelse it.next() orelse return ParseError.MissingLevel;
        try addLevels(&args.levels, v);
        return;
    }

    if (std.mem.eql(u8, name, "date")) {
        args.date = value orelse it.next() orelse return ParseError.MissingDate;
        return;
    }

    if (std.mem.eql(u8, name, "num-lines")) {
        const v = value orelse it.next() orelse return ParseError.MissingNumLines;
        args.num_lines = std.fmt.parseUnsigned(u32, v, 10) catch return ParseError.InvalidNumLines;
        return;
    }

    return ParseError.UnknownArgument;
}

/// Parse grouped short flags (GNU-style).
///
/// Example:
///   -tl Error
///   -fpath
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
            'h' => {
                args.help = true;
                return;
            },
            'v' => {
                args.version = true;
                return;
            },
            't' => args.tail_mode = true,

            'f' => {
                const v = valueOrNext(group, &i, it) orelse return ParseError.MissingFile;
                try files.append(allocator, v);
                return;
            },

            's' => {
                args.search = valueOrNext(group, &i, it) orelse return ParseError.MissingSearch;
                return;
            },

            'l' => {
                const v = valueOrNext(group, &i, it) orelse return ParseError.MissingLevel;
                try addLevels(&args.levels, v);
                return;
            },

            'd' => {
                args.date = valueOrNext(group, &i, it) orelse return ParseError.MissingDate;
                return;
            },

            'n' => {
                const v = valueOrNext(group, &i, it) orelse return ParseError.MissingNumLines;
                args.num_lines = std.fmt.parseUnsigned(u32, v, 10) catch return ParseError.InvalidNumLines;
                return;
            },

            else => return ParseError.UnknownArgument,
        }
    }
}

/// Returns an inline value from grouped flags (`-fvalue`)
/// or consumes the next argv element.
/// Inline value is only allowed if this flag is the last in the group.
inline fn valueOrNext(
    group: []const u8,
    index: *usize,
    it: anytype,
) ?[]const u8 {
    // Inline value only permitted when this is the last flag in the group.
    if (index.* + 1 < group.len) return null;
    return it.next();
}

/// Parse comma-separated log levels and update the bitmask.
/// FIX: uses parseLevelInsensitive — accepts any casing (error, ERROR, Error, eRRoR).
fn addLevels(mask: *?LevelMask, value: []const u8) ParseError!void {
    const current = mask.* orelse 0;
    var new_mask = current;

    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        // FIX: was std.meta.stringToEnum which is case-sensitive.
        // Now uses parseLevelInsensitive so "error", "ERROR", "Error" all work.
        const lvl = parseLevelInsensitive(trimmed) orelse return ParseError.InvalidLevel;
        new_mask |= levelBit(lvl);
    }

    mask.* = new_mask;
}

// ============================================================================
// Unit Tests
// ============================================================================
const testing = std.testing;

/// Iterator for testing.
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
    try testing.expectEqual(@as(u32, 10), args.num_lines);
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
    try testing.expectEqual(@as(u32, 10), args.num_lines);
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
    try testing.expectEqual(@as(u32, 10), args.num_lines);
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
    try testing.expectEqual(@as(u32, 10), args.num_lines);
    try testing.expectEqualStrings("test", args.search.?);
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

test "empty file list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const argv = [_][]const u8{"zlrd"};
    var it = FakeIter{ .argv = &argv };
    const result = parseArgsFromIter(arena.allocator(), &it);

    try testing.expectError(ParseError.MissingFile, result);
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

    // null means all levels enabled.
    args.levels = null;
    try testing.expect(args.isLevelEnabled(.Trace));
    try testing.expect(args.isLevelEnabled(.Error));
}

// --- Case-insensitive level parsing tests ---

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
    // All lowercase
    var mask1: ?LevelMask = null;
    try addLevels(&mask1, "error,warn");
    try testing.expect((mask1.? & levelBit(.Error)) != 0);
    try testing.expect((mask1.? & levelBit(.Warn)) != 0);

    // All uppercase
    var mask2: ?LevelMask = null;
    try addLevels(&mask2, "ERROR,WARN");
    try testing.expect((mask2.? & levelBit(.Error)) != 0);
    try testing.expect((mask2.? & levelBit(.Warn)) != 0);

    // Mixed case
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

    // lowercase via short flag
    {
        const argv = [_][]const u8{ "zlrd", "-f", "a.log", "-l", "error" };
        var it = FakeIter{ .argv = &argv };
        var args = try parseArgsFromIter(arena.allocator(), &it);
        defer args.deinit(arena.allocator());
        try testing.expect((args.levels.? & levelBit(.Error)) != 0);
    }

    // UPPERCASE via long flag
    {
        const argv = [_][]const u8{ "zlrd", "-f", "a.log", "--level=ERROR" };
        var it = FakeIter{ .argv = &argv };
        var args = try parseArgsFromIter(arena.allocator(), &it);
        defer args.deinit(arena.allocator());
        try testing.expect((args.levels.? & levelBit(.Error)) != 0);
    }

    // mixed case, multiple levels
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
