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
inline fn levelBit(l: Level) LevelMask {
    const shift: u3 = @intCast(@intFromEnum(l));
    return @as(LevelMask, 1) << shift;
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

    /// Date filter (`YYYY-MM-DD` or range).
    date: ?[]const u8 = null,

    /// Enable tail mode (`-t`).
    tail_mode: bool = false,

    /// Show help and exit.
    help: bool = false,

    /// Number of lines to display (`-n`).
    num_lines: usize = 0,

    /// Free allocated memory.
    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        allocator.free(self.files);
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
        \\  -l, --level <levels>     Levels: Trace,Debug,Info,Warn,Error,Fatal,Panic
        \\                           Multiple: -l Error,Warn -l Fatal
        \\  -d, --date <date>        Date filter (YYYY-MM-DD)
        \\  -t, --tail               Tail mode
        \\  -n, --num-lines <num>    Number of lines to display
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

    // Collect file paths incrementally with reasonable initial capacity
    var files = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    errdefer files.deinit(allocator);

    var args = Args{
        .files = &.{},
    };

    while (it.next()) |arg| {
        // Early exit for help
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            args.help = true;
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

        // Positional argument → file path
        try files.append(allocator, arg);
    }

    // Finalize files slice
    args.files = try files.toOwnedSlice(allocator);
    errdefer allocator.free(args.files);

    // At least one file is required unless help is requested
    if (!args.help and args.files.len == 0)
        return ParseError.MissingFile;

    return args;
}

/// Long flags (--flag, --flag=value)
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
    flags: []const u8,
    it: anytype,
    allocator: std.mem.Allocator,
) ParseError!void {
    var i: usize = 0;
    while (i < flags.len) : (i += 1) {
        switch (flags[i]) {
            'h' => {
                args.help = true;
                return;
            },
            't' => args.tail_mode = true,

            'f' => {
                const f = valueOrNext(flags, &i, it) orelse return ParseError.MissingFile;
                try files.append(allocator, f);
                return;
            },

            's' => {
                args.search = valueOrNext(flags, &i, it) orelse return ParseError.MissingSearch;
                return;
            },

            'l' => {
                const v = valueOrNext(flags, &i, it) orelse return ParseError.MissingLevel;
                try addLevels(&args.levels, v);
                return;
            },

            'd' => {
                args.date = valueOrNext(flags, &i, it) orelse return ParseError.MissingDate;
                return;
            },

            'n' => {
                const v = valueOrNext(flags, &i, it) orelse return ParseError.MissingNumLines;
                args.num_lines = std.fmt.parseUnsigned(u32, v, 10) catch return ParseError.InvalidNumLines;
                return;
            },

            else => return ParseError.UnknownArgument,
        }
    }
}

/// Returns an inline value from grouped flags (`-fvalue`)
/// or consumes the next argv element.
inline fn valueOrNext(
    flags: []const u8,
    index: *usize,
    it: anytype,
) ?[]const u8 {
    if (index.* + 1 < flags.len) {
        const v = flags[index.* + 1 ..];
        index.* = flags.len;
        return v;
    }
    return it.next();
}

/// Parse comma-separated log levels and update the bitmask.
fn addLevels(mask: *?LevelMask, value: []const u8) ParseError!void {
    // Initialize mask to 0 if not set
    const current = mask.* orelse 0;
    var new_mask = current;

    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        const lvl = std.meta.stringToEnum(Level, trimmed) orelse return ParseError.InvalidLevel;
        new_mask |= levelBit(lvl);
    }

    mask.* = new_mask;
}

/// Tests
const testing = std.testing;

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

    const argv = [_][]const u8{
        "zlrd", "-f", "log.txt",
    };

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
        "zlrd", "-f", "a.log", "b.log", "-f", "c.log", "-n", "10",
    };

    var it = FakeIter{ .argv = &argv };
    var args = try parseArgsFromIter(arena.allocator(), &it);
    defer args.deinit(arena.allocator());

    try testing.expectEqual(@as(usize, 3), args.files.len);
    try testing.expectEqualStrings("a.log", args.files[0]);
    try testing.expectEqualStrings("b.log", args.files[1]);
    try testing.expectEqualStrings("c.log", args.files[2]);
    try testing.expectEqual(@as(u32, 10), args.num_lines);
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
        "zlrd", "-tl", "Error", "log.txt",
    };

    var it = FakeIter{ .argv = &argv };
    var args = try parseArgsFromIter(arena.allocator(), &it);
    defer args.deinit(arena.allocator());

    try testing.expect(args.tail_mode);
    const m = args.levels.?;
    try testing.expect((m & levelBit(.Error)) != 0);
    try testing.expectEqual(@as(usize, 1), args.files.len);
}

test "help flag stops parsing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const argv = [_][]const u8{
        "zlrd", "-h",
    };

    var it = FakeIter{ .argv = &argv };
    var args = try parseArgsFromIter(arena.allocator(), &it);
    defer args.deinit(arena.allocator());

    try testing.expect(args.help);
}

test "memory cleanup on error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const argv = [_][]const u8{
        "zlrd", "-l",
    };

    var it = FakeIter{ .argv = &argv };
    const result = parseArgsFromIter(arena.allocator(), &it);

    try testing.expectError(ParseError.MissingLevel, result);
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

    // Test null (all enabled)
    args.levels = null;
    try testing.expect(args.isLevelEnabled(.Trace));
    try testing.expect(args.isLevelEnabled(.Error));
}
