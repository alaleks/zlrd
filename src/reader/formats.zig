const std = @import("std");
const flags = @import("../flags/flags.zig");

const Color = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";

    pub const red = "\x1b[31m";
    pub const yellow = "\x1b[33m";
    pub const green = "\x1b[32m";
    pub const blue = "\x1b[34m";
    pub const gray = "\x1b[90m";
    pub const cyan = "\x1b[36m";
};

const DateRange = struct {
    from: ?[]const u8,
    to: ?[]const u8,
};

fn parseDateRange(s: []const u8) DateRange {
    if (std.mem.indexOf(u8, s, "..")) |pos| {
        const left = s[0..pos];
        const right = s[pos + 2 ..];

        return .{
            .from = if (left.len > 0) left else null,
            .to = if (right.len > 0) right else null,
        };
    }

    // одиночная дата
    return .{
        .from = s,
        .to = s,
    };
}

fn matchDateRange(line: []const u8, range: DateRange) bool {
    const date = extractDate(line) orelse return false;

    if (range.from) |from| {
        if (std.mem.lessThan(u8, date, from))
            return false;
    }

    if (range.to) |to| {
        if (std.mem.lessThan(u8, to, date))
            return false;
    }

    return true;
}

fn extractDate(line: []const u8) ?[]const u8 {
    // JSON
    if (line.len > 0 and line[0] == '{') {
        return extractJsonDate(line);
    }

    // Plain text: YYYY-MM-DD ...
    if (line.len >= 10) {
        return line[0..10];
    }

    return null;
}

fn levelColor(lvl: flags.Level) []const u8 {
    return switch (lvl) {
        .Error, .Fatal, .Panic => Color.red,
        .Warn => Color.yellow,
        .Info => Color.green,
        .Debug => Color.blue,
        .Trace => Color.gray,
    };
}

pub fn readStreaming(
    allocator: std.mem.Allocator,
    path: []const u8,
    args: flags.Args,
) !void {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var buf: [8192]u8 = undefined;

    var carry = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer carry.deinit(allocator);

    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;

        var slice = buf[0..n];

        if (carry.items.len != 0) {
            try carry.appendSlice(allocator, slice);
            slice = carry.items;
            carry.clearRetainingCapacity();
        }

        var it = std.mem.splitScalar(u8, slice, '\n');
        while (it.next()) |line| {
            if (it.peek() == null and slice[slice.len - 1] != '\n') {
                try carry.appendSlice(allocator, line);
                break;
            }
            handleLine(line, args);
        }
    }

    if (carry.items.len != 0) {
        handleLine(carry.items, args);
    }
}

pub fn handleLine(line: []const u8, args: flags.Args) void {
    const lvl = extractLevel(line);

    // фильтр по дате
    if (!args.tail_mode) {
        if (args.date) |date_arg| {
            const range = parseDateRange(date_arg);
            if (!matchDateRange(line, range))
                return;
        }
    }

    // фильтр по уровню
    if (args.levels != 0) {
        const l = lvl orelse return;
        const shift: u3 = @intCast(@intFromEnum(l));
        if ((args.levels & (@as(flags.LevelMask, 1) << shift)) == 0)
            return;
    }

    // фильтр по search
    if (args.search) |expr| {
        if (!matchSearch(line, expr))
            return;
    }

    // JSON → bold cyan keys + colored level value
    if (line.len > 0 and line[0] == '{') {
        printJsonStyled(line, lvl);
        return;
    }

    // plain text
    if (lvl) |l| {
        const color = levelColor(l);
        std.debug.print("{s}{s}{s}\n", .{ color, line, Color.reset });
    } else {
        std.debug.print("{s}\n", .{line});
    }
}

fn matchSearch(line: []const u8, expr: []const u8) bool {
    // OR: a|b|c
    if (std.mem.indexOfScalar(u8, expr, '|') != null) {
        var it = std.mem.splitScalar(u8, expr, '|');
        while (it.next()) |part| {
            if (part.len == 0) continue;
            if (containsIgnoreCase(line, part))
                return true;
        }
        return false;
    }

    // AND: a&b&c
    if (std.mem.indexOfScalar(u8, expr, '&') != null) {
        var it = std.mem.splitScalar(u8, expr, '&');
        while (it.next()) |part| {
            if (part.len == 0) continue;
            if (!containsIgnoreCase(line, part))
                return false;
        }
        return true;
    }

    // simple search
    return containsIgnoreCase(line, expr);
}

fn matchLevel(line: []const u8, mask: flags.LevelMask) bool {
    if (mask == 0) return true;

    // JSON logs
    if (line.len > 0 and line[0] == '{') {
        return matchJsonLevel(line, mask);
    }

    // Plain text logs: [Error]
    return matchBracketLevel(line, mask);
}

fn parseLevelInsensitive(s: []const u8) ?flags.Level {
    inline for (std.meta.fields(flags.Level)) |f| {
        if (std.ascii.eqlIgnoreCase(s, f.name)) {
            return @enumFromInt(f.value);
        }
    }
    return null;
}

fn matchJsonLevel(line: []const u8, mask: flags.LevelMask) bool {
    const key = "\"level\"";
    const key_pos = std.mem.indexOf(u8, line, key) orelse
        return false;

    var i = key_pos + key.len;

    // пропускаем пробелы и :
    while (i < line.len and (line[i] == ' ' or line[i] == ':')) : (i += 1) {}

    if (i >= line.len or line[i] != '"')
        return false;
    i += 1;

    const start = i;
    while (i < line.len and line[i] != '"') : (i += 1) {}
    if (i >= line.len)
        return false;

    const level_str = line[start..i];
    const lvl = parseLevelInsensitive(level_str) orelse
        return false;

    const shift: u3 = @intCast(@intFromEnum(lvl));
    return (mask & (@as(flags.LevelMask, 1) << shift)) != 0;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(
            haystack[i .. i + needle.len],
            needle,
        )) {
            return true;
        }
    }
    return false;
}

fn matchBracketLevel(line: []const u8, mask: flags.LevelMask) bool {
    if (line.len < 3 or line[0] != '[')
        return false;

    const end = std.mem.indexOfScalar(u8, line, ']') orelse
        return false;

    const lvl = parseLevelInsensitive(line[1..end]) orelse
        return false;

    const shift: u3 = @intCast(@intFromEnum(lvl));
    return (mask & (@as(flags.LevelMask, 1) << shift)) != 0;
}

fn extractLevel(line: []const u8) ?flags.Level {
    // JSON
    if (line.len > 0 and line[0] == '{') {
        return extractJsonLevel(line);
    }

    // Plain text: [Error]
    if (line.len > 0 and line[0] == '[') {
        const end = std.mem.indexOfScalar(u8, line, ']') orelse return null;
        return parseLevelInsensitive(line[1..end]);
    }

    return null;
}

fn extractJsonLevel(line: []const u8) ?flags.Level {
    const key = "\"level\"";
    const pos = std.mem.indexOf(u8, line, key) orelse return null;

    var i = pos + key.len;
    while (i < line.len and (line[i] == ' ' or line[i] == ':')) : (i += 1) {}

    if (i >= line.len or line[i] != '"') return null;
    i += 1;

    const start = i;
    while (i < line.len and line[i] != '"') : (i += 1) {}
    if (i >= line.len) return null;

    return parseLevelInsensitive(line[start..i]);
}

fn printJsonStyled(line: []const u8, lvl: ?flags.Level) void {
    var i: usize = 0;
    var in_string = false;
    var string_start: usize = 0;

    // диапазон значения level, если есть
    var level_range: ?struct { start: usize, end: usize } = null;

    if (lvl != null) {
        const key = "\"level\"";
        if (std.mem.indexOf(u8, line, key)) |pos| {
            var j = pos + key.len;
            while (j < line.len and (line[j] == ' ' or line[j] == ':')) : (j += 1) {}
            if (j < line.len and line[j] == '"') {
                j += 1;
                const start = j;
                while (j < line.len and line[j] != '"') : (j += 1) {}
                if (j < line.len) {
                    level_range = .{ .start = start, .end = j };
                }
            }
        }
    }

    while (i < line.len) : (i += 1) {
        const c = line[i];

        // начало / конец JSON-строки
        if (c == '"' and (i == 0 or line[i - 1] != '\\')) {
            if (!in_string) {
                in_string = true;
                string_start = i + 1;
            } else {
                in_string = false;
                const str = line[string_start..i];

                // это ключ? (после строки идёт :)
                var k = i + 1;
                while (k < line.len and line[k] == ' ') : (k += 1) {}
                const is_key = k < line.len and line[k] == ':';

                // это значение level?
                if (level_range) |r| {
                    if (string_start == r.start and i == r.end) {
                        const color = levelColor(lvl.?);
                        std.debug.print(
                            "{s}\"{s}\"{s}",
                            .{ color, str, Color.reset },
                        );
                        continue;
                    }
                }

                if (is_key) {
                    std.debug.print(
                        "{s}{s}\"{s}\"{s}",
                        .{ Color.bold, Color.cyan, str, Color.reset },
                    );
                } else {
                    std.debug.print("\"{s}\"", .{str});
                }
            }
            continue;
        }

        if (in_string) continue;

        std.debug.print("{c}", .{c});
    }

    std.debug.print("\n", .{});
}

fn extractJsonDate(line: []const u8) ?[]const u8 {
    const key = "\"time\"";
    const pos = std.mem.indexOf(u8, line, key) orelse return null;

    var i = pos + key.len;
    while (i < line.len and (line[i] == ' ' or line[i] == ':')) : (i += 1) {}

    if (i >= line.len or line[i] != '"') return null;
    i += 1;

    // ожидаем YYYY-MM-DD...
    if (i + 10 > line.len) return null;

    return line[i .. i + 10];
}

fn matchDate(line: []const u8, wanted: []const u8) bool {
    // JSON
    if (line.len > 0 and line[0] == '{') {
        const d = extractJsonDate(line) orelse return false;
        return std.mem.eql(u8, d, wanted);
    }

    // Plain text: YYYY-MM-DD ...
    if (line.len >= 10) {
        return std.mem.eql(u8, line[0..10], wanted);
    }

    return false;
}
