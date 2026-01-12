const std = @import("std");

/// =======================
/// Levels
/// =======================
pub const Level = enum(u8) {
    Trace = 0,
    Debug = 1,
    Info = 2,
    Warn = 3,
    Error = 4,
    Fatal = 5,
    Panic = 6,
};

pub const LevelMask = u8;

/// =======================
/// Args
/// =======================
pub const Args = struct {
    files: [][]const u8,
    search: ?[]const u8 = null,
    levels: LevelMask = 0, // 0 = all
    date: ?[]const u8 = null,
    tail_mode: bool = false,
    help: bool = false,
};

/// =======================
/// Errors
/// =======================
pub const ParseError = error{
    OutOfMemory,

    MissingFile,
    MissingSearch,
    MissingLevel,
    MissingDate,

    InvalidLevel,
    UnknownArgument,
};

pub fn printHelp() void {
    std.debug.print(
        \\Usage:
        \\  zlrd [options] <file...>
        \\
        \\Options:
        \\  -f, --file <path>        Add log file (can be repeated)
        \\  -s, --search <text>      Search string
        \\  -l, --level <levels>    Levels: Trace,Debug,Info,Warn,Error,Fatal,Panic
        \\                          Multiple: -l Error,Warn -l Fatal
        \\  -d, --date <date>        Date filter (YYYY-MM-DD)
        \\  -t, --tail               Tail mode
        \\  -h, --help               Show help
        \\
    , .{});
}

inline fn levelBit(l: Level) LevelMask {
    const shift: u3 = @intCast(@intFromEnum(l));
    return @as(LevelMask, 1) << shift;
}

/// =======================
/// Public API (used by main)
/// =======================
pub fn parseArgs(allocator: std.mem.Allocator) ParseError!Args {
    var it = std.process.ArgIterator.init();
    defer it.deinit();

    return parseArgsFromIter(allocator, &it);
}

/// =======================
/// Core parser (TESTABLE)
/// =======================
fn parseArgsFromIter(
    allocator: std.mem.Allocator,
    it: anytype, // must have next() ?[]const u8
) ParseError!Args {
    _ = it.next(); // argv[0]

    var files = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    errdefer files.deinit(allocator);

    var args = Args{
        .files = &.{},
    };

    while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--")) {
            try parseLongFlag(&args, &files, arg, it, allocator);
            continue;
        }

        if (arg.len > 1 and arg[0] == '-') {
            try parseShortFlags(&args, &files, arg[1..], it, allocator);
            continue;
        }

        // positional file
        try files.append(allocator, arg);
    }

    args.files = try files.toOwnedSlice(allocator);

    if (!args.help and args.files.len == 0)
        return ParseError.MissingFile;

    return args;
}

/// =======================
/// Long flags
/// =======================
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

    return ParseError.UnknownArgument;
}

/// =======================
/// Short flags (-abc)
/// =======================
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

            else => return ParseError.UnknownArgument,
        }
    }
}

/// =======================
/// Helpers
/// =======================
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

fn addLevels(mask: *LevelMask, value: []const u8) ParseError!void {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        const lvl = std.meta.stringToEnum(Level, part) orelse return ParseError.InvalidLevel;
        mask.* |= levelBit(lvl);
    }
}

/// =======================
/// Tests
/// =======================
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
    const args = try parseArgsFromIter(arena.allocator(), &it);

    try testing.expectEqual(@as(usize, 1), args.files.len);
    try testing.expectEqualStrings("log.txt", args.files[0]);
}

test "multiple files mixed positional and -f" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const argv = [_][]const u8{
        "zlrd", "-f", "a.log", "b.log", "-f", "c.log",
    };

    var it = FakeIter{ .argv = &argv };
    const args = try parseArgsFromIter(arena.allocator(), &it);

    try testing.expectEqual(@as(usize, 3), args.files.len);
    try testing.expectEqualStrings("a.log", args.files[0]);
    try testing.expectEqualStrings("b.log", args.files[1]);
    try testing.expectEqualStrings("c.log", args.files[2]);
}

test "levels bitmask" {
    var mask: LevelMask = 0;
    try addLevels(&mask, "Error,Warn");

    try testing.expect((mask & levelBit(.Error)) != 0);
    try testing.expect((mask & levelBit(.Warn)) != 0);
    try testing.expect((mask & levelBit(.Info)) == 0);
}

test "gnu short flags grouping" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const argv = [_][]const u8{
        "zlrd", "-tl", "Error", "log.txt",
    };

    var it = FakeIter{ .argv = &argv };
    const args = try parseArgsFromIter(arena.allocator(), &it);

    try testing.expect(args.tail_mode);
    try testing.expect((args.levels & levelBit(.Error)) != 0);
    try testing.expectEqual(@as(usize, 1), args.files.len);
}
