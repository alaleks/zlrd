//! Log format detection, filtering, and colored output.
//! This module handles multiple log formats (JSON, plain text with bracketed levels,
//! logfmt) and provides streaming reading with filtering by date, level, and search.
const std = @import("std");
const flags = @import("../flags/flags.zig");
const simd = @import("simd.zig");

/// ANSI color codes for terminal output.
const Color = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";

    pub const red = "\x1b[31m";
    pub const yellow = "\x1b[33m";
    pub const green = "\x1b[32m";
    pub const blue = "\x1b[34m";
    pub const gray = "\x1b[90m";
    pub const key = "\x1b[38;5;66m";

    pub const number = "\x1b[38;5;214m";
    pub const boolean = "\x1b[38;5;135m";
    pub const nullv = "\x1b[38;5;244m";
};

/// Inclusive date range for filtering.
const DateRange = struct {
    from: ?[]const u8,
    to: ?[]const u8,
};

/// Accumulated filter state derived from command-line arguments.
const FilterState = struct {
    has_date_filter: bool,
    date_range: DateRange,
    has_level_filter: bool,
    has_search_filter: bool,
    search_expr: ?[]const u8,

    /// Build filter state from parsed command-line arguments.
    fn init(args: flags.Args) FilterState {
        const has_date = !args.tail_mode and args.date != null;
        return .{
            .has_date_filter = has_date,
            .date_range = if (has_date) parseDateRange(args.date.?) else undefined,
            .has_level_filter = args.levels != null,
            .has_search_filter = args.search != null,
            .search_expr = args.search,
        };
    }

    /// Check whether a line passes all active filters.
    /// Returns the extracted level if the line matches, `null` otherwise.
    fn checkLine(self: FilterState, line: []const u8, args: flags.Args) ?flags.Level {
        if (line.len == 0) return null;

        const lvl = extractLevel(line);

        if (self.has_date_filter) {
            if (!matchDateRange(line, self.date_range)) return null;
        }

        if (self.has_level_filter) {
            const l = lvl orelse return null;
            if (!args.isLevelEnabled(l)) return null;
        }

        if (self.has_search_filter) {
            if (!matchSearch(line, self.search_expr.?)) return null;
        }

        return lvl;
    }
};

/// Reading statistics for non‑interactive mode.
const Stats = struct {
    lines_read: usize = 0,
    lines_matched: usize = 0,
    bytes_read: usize = 0,
};

/// Parse a date range string of the form `FROM..TO` or a single date.
/// If `..` is present, the left and right sides become `from` and `to`.
/// A missing side is stored as `null`. If no `..` is found, the whole string
/// is used for both `from` and `to` (exact match).
fn parseDateRange(s: []const u8) DateRange {
    if (std.mem.indexOf(u8, s, "..")) |pos| {
        const left = s[0..pos];
        const right = s[pos + 2 ..];
        return .{
            .from = if (left.len > 0) left else null,
            .to = if (right.len > 0) right else null,
        };
    }
    return .{ .from = s, .to = s };
}

/// Test whether the date extracted from `line` lies within `range`.
/// The comparison is lexicographic, which works for ISO‑8601 dates.
fn matchDateRange(line: []const u8, range: DateRange) bool {
    const date = extractDate(line) orelse return false;

    if (range.from) |from| {
        if (std.mem.order(u8, date, from) == .lt) return false;
    }
    if (range.to) |to| {
        if (std.mem.order(u8, date, to) == .gt) return false;
    }

    return true;
}

/// Extract a date prefix from a log line.
/// Recognizes JSON lines (field `"time"`) and ISO‑8601 prefixes.
/// Returns the first 10 characters (YYYY‑MM‑DD) or `null`.
fn extractDate(line: []const u8) ?[]const u8 {
    if (line.len == 0) return null;

    if (line[0] == '{') {
        return simd.extractJsonField(line, "time", 10);
    }

    if (simd.isISODate(line)) {
        return line[0..10];
    }

    return null;
}

/// Map a log level to its corresponding terminal color.
inline fn levelColor(lvl: flags.Level) []const u8 {
    return switch (lvl) {
        .Error, .Fatal, .Panic => Color.red,
        .Warn => Color.yellow,
        .Info => Color.green,
        .Debug => Color.blue,
        .Trace => Color.gray,
    };
}

/// Read a log file with filtering and colored output.
/// If `args.num_lines > 0`, paginates the output; otherwise streams continuously.
pub fn readStreaming(
    allocator: std.mem.Allocator,
    path: []const u8,
    args: flags.Args,
) !void {
    if (args.num_lines > 0) {
        try readWithPagination(allocator, path, args);
    } else {
        try readContinuous(allocator, path, args);
    }
}

/// Read and filter lines continuously, printing matches as they appear.
fn readContinuous(
    allocator: std.mem.Allocator,
    path: []const u8,
    args: flags.Args,
) !void {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const buffer = try allocator.alloc(u8, 128 * 1024);
    defer allocator.free(buffer);

    var carry = std.ArrayList(u8){};
    defer carry.deinit(allocator);

    const filter_state = FilterState.init(args);
    var stats = Stats{};

    while (true) {
        const n = try file.read(buffer);
        if (n == 0) break;

        stats.bytes_read += n;
        var slice = buffer[0..n];

        if (carry.items.len > 0) {
            try carry.appendSlice(allocator, slice);
            slice = carry.items;
        }

        var start: usize = 0;
        var pos = start;

        while (true) {
            const nl = simd.findByte(slice, pos, '\n') orelse break;
            const line = slice[start..nl];
            stats.lines_read += 1;

            if (filter_state.checkLine(line, args)) |lvl| {
                printStyledLine(line, lvl);
                stats.lines_matched += 1;
            }

            start = nl + 1;
            pos = start;
        }

        carry.clearRetainingCapacity();
        if (start < slice.len) {
            try carry.appendSlice(allocator, slice[start..]);
        }
    }

    if (carry.items.len > 0) {
        if (filter_state.checkLine(carry.items, args)) |lvl| {
            printStyledLine(carry.items, lvl);
        }
    }
}

/// Read with pagination: show `args.num_lines` at a time, wait for Enter.
fn readWithPagination(
    allocator: std.mem.Allocator,
    path: []const u8,
    args: flags.Args,
) !void {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const buffer = try allocator.alloc(u8, 128 * 1024);
    defer allocator.free(buffer);

    var carry = std.ArrayList(u8){};
    defer carry.deinit(allocator);

    const filter_state = FilterState.init(args);

    var shown: usize = 0;
    var batch: usize = 0;
    var page: usize = 1;

    while (true) {
        const n = try file.read(buffer);
        if (n == 0) break;

        var slice = buffer[0..n];
        if (carry.items.len > 0) {
            try carry.appendSlice(allocator, slice);
            slice = carry.items;
        }

        var start: usize = 0;
        var pos = start;

        while (true) {
            const nl = simd.findByte(slice, pos, '\n') orelse break;
            const line = slice[start..nl];

            if (filter_state.checkLine(line, args)) |lvl| {
                printStyledLine(line, lvl);
                shown += 1;
                batch += 1;

                if (batch >= args.num_lines) {
                    printPaginationPrompt(page, batch);
                    waitForEnter();
                    clearScreen();
                    batch = 0;
                    page += 1;
                }
            }

            start = nl + 1;
            pos = start;
        }

        carry.clearRetainingCapacity();
        if (start < slice.len) {
            try carry.appendSlice(allocator, slice[start..]);
        }
    }
}

/// Extract the log level from a line, regardless of format.
/// Recognizes JSON (`"level": "..."`), bracketed (`[LEVEL]`), and logfmt
/// (`level=...`, `severity=...`, `lvl=...`).
/// Returns `null` if no level field is found.
fn extractLevel(line: []const u8) ?flags.Level {
    if (line.len == 0) return null;

    if (line[0] == '{') {
        if (simd.extractJsonField(line, "level", 16)) |v|
            return parseLevelInsensitive(v);
        return null;
    }

    if (line[0] == '[') {
        if (simd.findBracketedLevel(line)) |r|
            return parseLevelInsensitive(line[r.start..r.end]);
    }

    if (simd.findLogfmtLevel(line)) |r| {
        return parseLevelInsensitive(line[r.start..r.end]);
    }

    return null;
}

/// Check whether a byte is a decimal digit.
inline fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Check if `word` appears at position `pos` in `line`.
fn matchWord(line: []const u8, pos: usize, comptime word: []const u8) bool {
    return pos + word.len <= line.len and
        std.mem.eql(u8, line[pos .. pos + word.len], word);
}

/// Locate the JSON `"level"` value and return its byte range (without quotes).
/// Used for coloring the level value inside a JSON line.
fn extractJsonLevelPos(line: []const u8) ?struct { start: usize, end: usize } {
    var i: usize = 0;

    while (true) {
        const q = simd.findByte(line, i, '"') orelse return null;

        if (q + 7 < line.len and
            std.mem.eql(u8, line[q + 1 .. q + 6], "level") and
            line[q + 6] == '"')
        {
            i = q + 7;
            break;
        }

        i = q + 1;
    }

    // skip whitespace + colon
    while (i < line.len and (line[i] == ' ' or line[i] == ':')) : (i += 1) {}
    if (i >= line.len or line[i] != '"') return null;

    const start = i + 1;
    const end = simd.findByte(line, start, '"') orelse return null;

    return .{ .start = start, .end = end };
}

/// Parse a level string case‑insensitively.
inline fn parseLevelInsensitive(s: []const u8) ?flags.Level {
    inline for (std.meta.fields(flags.Level)) |f| {
        if (std.ascii.eqlIgnoreCase(s, f.name))
            return @enumFromInt(f.value);
    }
    return null;
}

/// Print a line with appropriate styling based on its format and extracted level.
fn printStyledLine(line: []const u8, lvl: ?flags.Level) void {
    if (line.len == 0) return;

    if (line[0] == '{') {
        printJsonStyled(line, lvl);
    } else if (lvl) |l| {
        printPlainTextWithLevel(line, l);
    } else {
        std.debug.print("{s}\n", .{line});
    }
}

/// Print a plain‑text line with a colored level.
/// If the level appears inside brackets, only the bracketed part is colored.
fn printPlainTextWithLevel(line: []const u8, level: flags.Level) void {
    const color = levelColor(level);

    // [LEVEL] format
    if (simd.findBracketedLevel(line)) |r| {
        // before [
        if (r.start > 0) {
            std.debug.print("{s}", .{line[0..r.start]});
        }

        // LEVEL
        std.debug.print(
            "{s}{s}{s}{s}",
            .{
                Color.bold,
                color,
                line[r.start..r.end],
                Color.reset,
            },
        );

        // after ]
        if (r.end < line.len) {
            std.debug.print("{s}", .{line[r.end..]});
        }

        std.debug.print("\n", .{});
        return;
    }

    // logfmt: level= / severity= / lvl=
    if (simd.findLogfmtLevel(line)) |r| {
        // before value
        if (r.start > 0) {
            std.debug.print("{s}", .{line[0..r.start]});
        }

        // value
        std.debug.print(
            "{s}{s}{s}{s}",
            .{
                Color.bold,
                color,
                line[r.start..r.end],
                Color.reset,
            },
        );

        // after value
        if (r.end < line.len) {
            std.debug.print("{s}", .{line[r.end..]});
        }

        std.debug.print("\n", .{});
        return;
    }

    // fallback: no level detected → print as-is
    std.debug.print("{s}\n", .{line});
}

/// Print a JSON line with syntax‑highlighted keys, strings, numbers, and booleans.
/// The `"level"` value is additionally colored according to its severity.
fn printJsonStyled(line: []const u8, lvl: ?flags.Level) void {
    const level_pos = if (lvl != null) extractJsonLevelPos(line) else null;

    var i: usize = 0;
    var in_string = false;
    var str_start: usize = 0;

    while (i < line.len) {
        const c = line[i];

        // ---------- strings ----------
        if (c == '"' and (i == 0 or line[i - 1] != '\\')) {
            if (!in_string) {
                in_string = true;
                str_start = i + 1;
            } else {
                in_string = false;
                const str = line[str_start..i];

                // level value
                if (level_pos) |lp| {
                    if (str_start == lp.start and i == lp.end) {
                        std.debug.print(
                            "{s}{s}\"{s}\"{s}",
                            .{ Color.bold, levelColor(lvl.?), str, Color.reset },
                        );
                        i += 1;
                        continue;
                    }
                }

                // key
                var j = i + 1;
                while (j < line.len and line[j] == ' ') : (j += 1) {}
                if (j < line.len and line[j] == ':') {
                    std.debug.print("{s}\"{s}\"{s}", .{
                        Color.key, str, Color.reset,
                    });
                } else {
                    std.debug.print("\"{s}\"", .{str});
                }
            }
            i += 1;
            continue;
        }

        if (in_string) {
            i += 1;
            continue;
        }

        // ---------- literals ----------
        if (isDigit(c) or c == '-') {
            const start = i;
            i += 1;
            while (i < line.len and
                (isDigit(line[i]) or line[i] == '.' or
                    line[i] == 'e' or line[i] == 'E' or
                    line[i] == '+' or line[i] == '-'))
            {
                i += 1;
            }

            std.debug.print("{s}{s}{s}", .{
                Color.number,
                line[start..i],
                Color.reset,
            });
            continue;
        }

        if (matchWord(line, i, "true")) {
            std.debug.print("{s}true{s}", .{ Color.boolean, Color.reset });
            i += 4;
            continue;
        }
        if (matchWord(line, i, "false")) {
            std.debug.print("{s}false{s}", .{ Color.boolean, Color.reset });
            i += 5;
            continue;
        }
        if (matchWord(line, i, "null")) {
            std.debug.print("{s}null{s}", .{ Color.nullv, Color.reset });
            i += 4;
            continue;
        }

        // ---------- structure ----------
        switch (c) {
            '{', '}' => std.debug.print("{s}{c}{s}", .{
                Color.dim, c, Color.reset,
            }),
            ':' => std.debug.print("{s}:{s}", .{
                Color.gray, Color.reset,
            }),
            else => std.debug.print("{c}", .{c}),
        }

        i += 1;
    }

    std.debug.print("\n", .{});
}

/// Print a pagination prompt after each batch.
inline fn printPaginationPrompt(batch: usize, count: usize) void {
    std.debug.print(
        "\n{s}--- Batch {d}: {d} lines | Press Enter...{s}\n",
        .{ Color.dim, batch, count, Color.reset },
    );
}

/// Wait for the user to press Enter.
fn waitForEnter() void {
    var buf: [1]u8 = undefined;
    _ = std.fs.File.stdin().read(&buf) catch {};
}

/// Clear the terminal screen if stdout is a TTY.
fn clearScreen() void {
    if (std.fs.File.stdout().isTty())
        std.debug.print("\x1b[2J\x1b[H", .{});
}

/// ============================================================
/// Search
/// ============================================================
/// Match a line against a search expression.
/// Supports `|` (OR) and `&` (AND) operators. If neither is present,
/// the expression is treated as a simple substring.
fn matchSearch(line: []const u8, expr: []const u8) bool {
    if (std.mem.indexOfScalar(u8, expr, '|')) |_| {
        var it = std.mem.splitScalar(u8, expr, '|');
        while (it.next()) |p| {
            if (p.len > 0 and containsIgnoreCase(line, p)) return true;
        }
        return false;
    }

    if (std.mem.indexOfScalar(u8, expr, '&')) |_| {
        var it = std.mem.splitScalar(u8, expr, '&');
        while (it.next()) |p| {
            if (p.len > 0 and !containsIgnoreCase(line, p)) return false;
        }
        return true;
    }

    return containsIgnoreCase(line, expr);
}

/// Case‑insensitive substring search.
fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > hay.len) return false;

    const max = hay.len - needle.len;
    var i: usize = 0;
    while (i <= max) : (i += 1) {
        var ok = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(hay[i + j]) != std.ascii.toLower(c)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

/// Backward-compatible wrapper (used by tail.zig)
/// Filter and print a single line according to the given arguments.
pub fn handleLine(line: []const u8, args: flags.Args) void {
    const filter_state = FilterState.init(args);
    if (filter_state.checkLine(line, args)) |lvl| {
        printStyledLine(line, lvl);
    }
}
