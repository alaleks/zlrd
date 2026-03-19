//! Log format detection, filtering, and colored output.
//! This module handles multiple log formats (JSON, plain text with bracketed levels,
//! logfmt) and provides streaming reading with filtering by date, level, and search.

const std = @import("std");
const flags = @import("../flags/flags.zig");
const simd = @import("simd.zig");

/// Cached analysis of a log line.
const LineInfo = struct {
    /// Format type of the line.
    format: enum {
        json,
        plain_bracketed,
        plain_logfmt,
        plain_unknown,
    },
    /// Extracted log level, if any.
    level: ?flags.Level,
    /// Position of the level value within the line for coloring.
    level_pos: ?LevelPos,
    /// Extracted date prefix (YYYY-MM-DD), if any.
    date: ?[]const u8,
    /// Whether the line starts with '{' (JSON).
    is_json: bool,
    /// Whether the line starts with '[' (bracketed level).
    starts_with_bracket: bool,
};

/// Analyze a line once and cache the results.
fn analyzeLine(line: []const u8) LineInfo {
    var info: LineInfo = .{
        .format = .plain_unknown,
        .level = null,
        .level_pos = null,
        .date = null,
        .is_json = false,
        .starts_with_bracket = false,
    };

    if (line.len == 0) return info;

    info.is_json = line[0] == '{';
    info.starts_with_bracket = line[0] == '[';

    // Extract date prefix once; reused by the date filter.
    info.date = extractDate(line);

    // Determine format and extract level.
    if (info.is_json) {
        info.format = .json;
        if (simd.extractJsonField(line, "level", 16)) |v| {
            info.level = flags.parseLevelInsensitive(v);
            if (extractJsonLevelPos(line)) |pos| {
                info.level_pos = pos;
            }
        }
    } else if (info.starts_with_bracket) {
        info.format = .plain_bracketed;
        if (simd.findBracketedLevel(line)) |r| {
            info.level = flags.parseLevelInsensitive(line[r.start..r.end]);
            info.level_pos = LevelPos{ .start = r.start, .end = r.end };
        }
    } else if (simd.findLogfmtLevel(line)) |r| {
        info.format = .plain_logfmt;
        info.level = flags.parseLevelInsensitive(line[r.start..r.end]);
        info.level_pos = LevelPos{ .start = r.start, .end = r.end };
    }

    return info;
}

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

/// Position of a level value within a line.
const LevelPos = struct {
    start: usize,
    end: usize,
};

/// Inclusive date range for filtering.
const DateRange = struct {
    from: ?[]const u8,
    to: ?[]const u8,
};

/// Accumulated filter state derived from command-line arguments.
/// Built once per file/session; `checkLine` uses only this struct.
/// Public so that tail.zig can build it once and reuse it across lines.
pub const FilterState = struct {
    has_date_filter: bool,
    date_range: DateRange,
    has_level_filter: bool,
    /// Cached bitmask — avoids touching `args` on every line.
    enabled_levels: ?flags.LevelMask,
    has_search_filter: bool,
    search_expr: ?[]const u8,

    /// Build filter state from parsed command-line arguments.
    pub fn init(args: flags.Args) FilterState {
        const has_date = args.date != null;
        return .{
            .has_date_filter = has_date,
            .date_range = if (has_date) parseDateRange(args.date.?) else .{ .from = null, .to = null },
            .has_level_filter = args.levels != null,
            .enabled_levels = args.levels,
            .has_search_filter = args.search != null,
            .search_expr = args.search,
        };
    }

    /// Check whether a line passes all active filters.
    /// Returns cached line analysis if the line matches, `null` otherwise.
    pub fn checkLine(self: FilterState, line: []const u8) ?LineInfo {
        if (line.len == 0) return null;

        // Analyze once; results are reused by all filters and by the printer.
        const info = analyzeLine(line);

        // Search filter — checked first (cheap string scan, no alloc).
        if (self.has_search_filter) {
            if (!matchSearch(line, self.search_expr.?)) return null;
        }

        // Level filter.
        if (self.has_level_filter) {
            const lvl = info.level orelse return null;
            if (self.enabled_levels.? & flags.levelBit(lvl) == 0) return null;
        }

        // Date filter — checked last (most expensive: involves field extraction).
        if (self.has_date_filter) {
            if (!matchDateRangeWithDate(info.date, self.date_range)) return null;
        }

        return info;
    }

    /// Filter and print a single line.
    /// Used by tail.zig so it doesn't need to import LineInfo or printStyledLine.
    pub fn printIfMatch(self: FilterState, line: []const u8) void {
        if (self.checkLine(line)) |info| {
            printStyledLine(line, info);
        }
    }
};

/// Reading statistics for non-interactive mode.
const Stats = struct {
    lines_read: usize = 0,
    lines_matched: usize = 0,
    bytes_read: usize = 0,
};

/// Buffered writer for output to reduce syscalls.
///
/// Zig 0.15.2 quirks worked around here:
///   - File.writer(buf)      requires an explicit []u8 buffer — skipped entirely.
///   - ArrayList.writer(gpa) requires the allocator at call time — cached in struct.
///   - ArrayList.deinit(gpa) same — uses cached allocator.
const OutputBuffer = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    file: std.fs.File,
    max_size: usize,

    fn init(allocator: std.mem.Allocator, file: std.fs.File) !OutputBuffer {
        return .{
            .allocator = allocator,
            .buffer = try std.ArrayList(u8).initCapacity(allocator, 64 * 1024),
            .file = file,
            .max_size = 64 * 1024,
        };
    }

    fn deinit(self: *OutputBuffer) void {
        self.flush() catch {};
        self.buffer.deinit(self.allocator);
    }

    /// Append formatted text to the internal buffer.
    fn print(self: *OutputBuffer, comptime fmt: []const u8, args: anytype) !void {
        try self.buffer.writer(self.allocator).print(fmt, args);
        if (self.buffer.items.len >= self.max_size) try self.flush();
    }

    /// Append a raw byte slice without formatting overhead.
    fn write(self: *OutputBuffer, s: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, s);
        if (self.buffer.items.len >= self.max_size) try self.flush();
    }

    fn flush(self: *OutputBuffer) !void {
        if (self.buffer.items.len > 0) {
            try self.file.writeAll(self.buffer.items);
            self.buffer.clearRetainingCapacity();
        }
    }
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
/// The comparison is lexicographic, which works for ISO-8601 dates.
fn matchDateRange(line: []const u8, range: DateRange) bool {
    return matchDateRangeWithDate(extractDate(line), range);
}

/// Test whether a pre-extracted date lies within `range`.
fn matchDateRangeWithDate(date: ?[]const u8, range: DateRange) bool {
    const d = date orelse return false;

    if (range.from) |from| {
        if (std.mem.order(u8, d, from) == .lt) return false;
    }
    if (range.to) |to| {
        if (std.mem.order(u8, d, to) == .gt) return false;
    }

    return true;
}

/// Extract a date prefix from a log line.
/// Recognizes JSON lines (field `"time"`) and ISO-8601 prefixes.
/// Returns the first 10 characters (YYYY-MM-DD) or `null`.
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

/// Determine appropriate buffer size based on file size.
/// FIX: returns `usize` directly — no error union needed; catch handles stat failure.
fn getOptimalBufferSize(file: std.fs.File) usize {
    const stat = file.stat() catch return 512 * 1024;
    return if (stat.size > 100 * 1024 * 1024)
        1024 * 1024 // > 100 MB → 1 MB read buffer
    else if (stat.size > 10 * 1024 * 1024)
        512 * 1024 // > 10 MB  → 512 KB
    else
        256 * 1024; // ≤ 10 MB  → 256 KB
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
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // FIX: getOptimalBufferSize no longer returns an error union.
    const buffer_size = getOptimalBufferSize(file);
    const buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(buffer);

    // Carry buffer for incomplete lines between reads.
    var carry = try std.ArrayList(u8).initCapacity(allocator, 64 * 1024);
    defer carry.deinit(allocator);

    // FIX: FilterState built once; checkLine no longer takes `args`.
    const filter_state = FilterState.init(args);

    // FIX: output goes to stdout (std.debug.print writes to stderr).
    var output = try OutputBuffer.init(allocator, std.fs.File.stdout());
    defer output.deinit();

    var stats = Stats{};

    while (true) {
        const n = try file.read(buffer);
        if (n == 0) break;

        stats.bytes_read += n;
        var slice = buffer[0..n];

        // Prepend carry-over from the previous read.
        if (carry.items.len > 0) {
            try carry.appendSlice(allocator, slice);
            slice = carry.items;
        }

        var start: usize = 0;

        // Process all complete lines in this chunk.
        while (true) {
            const nl = simd.findByte(slice, start, '\n') orelse break;
            const line = slice[start..nl];
            stats.lines_read += 1;

            if (filter_state.checkLine(line)) |info| {
                try printStyledLineBuffered(&output, line, info);
                stats.lines_matched += 1;
            }

            start = nl + 1;
        }

        // Save the incomplete trailing line for the next iteration.
        carry.clearRetainingCapacity();
        if (start < slice.len) {
            try carry.appendSlice(allocator, slice[start..]);
        }
    }

    // Process final line if present (no trailing newline).
    if (carry.items.len > 0) {
        if (filter_state.checkLine(carry.items)) |info| {
            try printStyledLineBuffered(&output, carry.items, info);
        }
    }
}

/// Read with pagination: show `args.num_lines` at a time, wait for Enter.
fn readWithPagination(
    allocator: std.mem.Allocator,
    path: []const u8,
    args: flags.Args,
) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const buffer_size = getOptimalBufferSize(file);
    const buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(buffer);

    var carry = try std.ArrayList(u8).initCapacity(allocator, 64 * 1024);
    defer carry.deinit(allocator);

    const filter_state = FilterState.init(args);

    var output = try OutputBuffer.init(allocator, std.fs.File.stdout());
    defer output.deinit();

    // FIX: `shown` was declared `var` but never mutated — removed entirely.
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

        while (true) {
            const nl = simd.findByte(slice, start, '\n') orelse break;
            const line = slice[start..nl];

            if (filter_state.checkLine(line)) |info| {
                try printStyledLineBuffered(&output, line, info);
                batch += 1;

                if (batch >= args.num_lines) {
                    try output.flush();
                    printPaginationPrompt(page, batch);
                    waitForEnter();
                    clearScreen();
                    batch = 0;
                    page += 1;
                }
            }

            start = nl + 1;
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
            return flags.parseLevelInsensitive(v);
        return null;
    }

    if (line[0] == '[') {
        if (simd.findBracketedLevel(line)) |r|
            return flags.parseLevelInsensitive(line[r.start..r.end]);
    }

    if (simd.findLogfmtLevel(line)) |r| {
        return flags.parseLevelInsensitive(line[r.start..r.end]);
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
fn extractJsonLevelPos(line: []const u8) ?LevelPos {
    var i: usize = 0;

    while (true) {
        const q = simd.findByte(line, i, '"') orelse return null;

        // FIX: was `q + 7 < line.len` (off-by-one — excludes last byte).
        // Must be `<=` so that line[q+6] is always a valid index.
        if (q + 7 <= line.len and
            std.mem.eql(u8, line[q + 1 .. q + 6], "level") and
            line[q + 6] == '"')
        {
            i = q + 7;
            break;
        }

        i = q + 1;
    }

    // Skip whitespace and colon between key and value.
    while (i < line.len and (line[i] == ' ' or line[i] == ':')) : (i += 1) {}
    if (i >= line.len or line[i] != '"') return null;

    const start = i + 1;
    const end = simd.findByte(line, start, '"') orelse return null;

    return LevelPos{ .start = start, .end = end };
}

/// Print a line with appropriate styling based on its format and extracted level.
fn printStyledLine(line: []const u8, info: LineInfo) void {
    if (line.len == 0) return;

    if (info.is_json) {
        printJsonStyled(line, info);
    } else if (info.level) |_| {
        printPlainTextWithLevel(line, info);
    } else {
        // In Zig 0.15.2, File.writer(buf) needs an explicit buffer.
        // Use writeAll directly for simple unbuffered output.
        const stdout = std.fs.File.stdout();
        stdout.writeAll(line) catch {};
        stdout.writeAll("\n") catch {};
    }
}

/// Buffered version of printStyledLine — used in hot loops.
fn printStyledLineBuffered(output: *OutputBuffer, line: []const u8, info: LineInfo) !void {
    if (line.len == 0) return;

    if (info.is_json) {
        try printJsonStyledBuffered(output, line, info);
    } else if (info.level) |_| {
        try printPlainTextWithLevelBuffered(output, line, info);
    } else {
        try output.write(line);
        try output.write("\n");
    }
}

/// Print a plain-text line with a colored level.
/// If the level appears inside brackets, only the bracketed part is colored.
/// Uses writeAll directly — File.writer(buf) in Zig 0.15.2 needs an explicit buffer.
fn printPlainTextWithLevel(line: []const u8, info: LineInfo) void {
    const stdout = std.fs.File.stdout();
    const color = levelColor(info.level.?);

    if (info.level_pos) |r| {
        if (r.start > 0) stdout.writeAll(line[0..r.start]) catch {};
        stdout.writeAll(Color.bold) catch {};
        stdout.writeAll(color) catch {};
        stdout.writeAll(line[r.start..r.end]) catch {};
        stdout.writeAll(Color.reset) catch {};
        if (r.end < line.len) stdout.writeAll(line[r.end..]) catch {};
        stdout.writeAll("\n") catch {};
        return;
    }

    stdout.writeAll(line) catch {};
    stdout.writeAll("\n") catch {};
}

/// Buffered version of printPlainTextWithLevel.
fn printPlainTextWithLevelBuffered(output: *OutputBuffer, line: []const u8, info: LineInfo) !void {
    const color = levelColor(info.level.?);

    if (info.level_pos) |r| {
        if (r.start > 0) try output.write(line[0..r.start]);
        try output.write(Color.bold);
        try output.write(color);
        try output.write(line[r.start..r.end]);
        try output.write(Color.reset);
        if (r.end < line.len) try output.write(line[r.end..]);
        try output.write("\n");
        return;
    }

    try output.write(line);
    try output.write("\n");
}

/// Print a JSON line with syntax-highlighted keys, strings, numbers, and booleans.
/// The `"level"` value is additionally colored according to its severity.
/// Uses writeAll directly — File.writer(buf) in Zig 0.15.2 needs an explicit buffer.
fn printJsonStyled(line: []const u8, info: LineInfo) void {
    const stdout = std.fs.File.stdout();
    var i: usize = 0;
    var in_string = false;
    var str_start: usize = 0;

    // Scratch buffer for small formatted segments (numbers, etc.).
    var scratch: [64]u8 = undefined;

    while (i < line.len) {
        const c = line[i];

        if (c == '"' and (i == 0 or line[i - 1] != '\\')) {
            if (!in_string) {
                in_string = true;
                str_start = i + 1;
            } else {
                in_string = false;
                const str = line[str_start..i];

                if (info.level_pos) |lp| {
                    if (str_start == lp.start and i == lp.end) {
                        stdout.writeAll(Color.bold) catch {};
                        stdout.writeAll(levelColor(info.level.?)) catch {};
                        stdout.writeAll("\"") catch {};
                        stdout.writeAll(str) catch {};
                        stdout.writeAll("\"") catch {};
                        stdout.writeAll(Color.reset) catch {};
                        i += 1;
                        continue;
                    }
                }

                var j = i + 1;
                while (j < line.len and line[j] == ' ') : (j += 1) {}
                if (j < line.len and line[j] == ':') {
                    stdout.writeAll(Color.key) catch {};
                    stdout.writeAll("\"") catch {};
                    stdout.writeAll(str) catch {};
                    stdout.writeAll("\"") catch {};
                    stdout.writeAll(Color.reset) catch {};
                } else {
                    stdout.writeAll("\"") catch {};
                    stdout.writeAll(str) catch {};
                    stdout.writeAll("\"") catch {};
                }
            }
            i += 1;
            continue;
        }

        if (in_string) {
            i += 1;
            continue;
        }

        if (isDigit(c) or c == '-') {
            const start = i;
            i += 1;
            while (i < line.len and
                (isDigit(line[i]) or line[i] == '.' or
                    line[i] == 'e' or line[i] == 'E' or
                    line[i] == '+' or line[i] == '-')) : (i += 1)
            {}
            stdout.writeAll(Color.number) catch {};
            stdout.writeAll(line[start..i]) catch {};
            stdout.writeAll(Color.reset) catch {};
            continue;
        }

        if (matchWord(line, i, "true")) {
            stdout.writeAll(Color.boolean) catch {};
            stdout.writeAll("true") catch {};
            stdout.writeAll(Color.reset) catch {};
            i += 4;
            continue;
        }
        if (matchWord(line, i, "false")) {
            stdout.writeAll(Color.boolean) catch {};
            stdout.writeAll("false") catch {};
            stdout.writeAll(Color.reset) catch {};
            i += 5;
            continue;
        }
        if (matchWord(line, i, "null")) {
            stdout.writeAll(Color.nullv) catch {};
            stdout.writeAll("null") catch {};
            stdout.writeAll(Color.reset) catch {};
            i += 4;
            continue;
        }

        switch (c) {
            '{', '}' => {
                stdout.writeAll(Color.dim) catch {};
                // Single byte — write via scratch to avoid format overhead.
                scratch[0] = c;
                stdout.writeAll(scratch[0..1]) catch {};
                stdout.writeAll(Color.reset) catch {};
            },
            ':' => {
                stdout.writeAll(Color.gray) catch {};
                stdout.writeAll(":") catch {};
                stdout.writeAll(Color.reset) catch {};
            },
            else => {
                scratch[0] = c;
                stdout.writeAll(scratch[0..1]) catch {};
            },
        }
        i += 1;
    }

    stdout.writeAll("\n") catch {};
}

/// Buffered version of printJsonStyled — used in hot loops.
/// Uses output.write() (appendSlice) everywhere to avoid ArrayList.writer(gpa) overhead.
fn printJsonStyledBuffered(output: *OutputBuffer, line: []const u8, info: LineInfo) !void {
    var i: usize = 0;
    var in_string = false;
    var str_start: usize = 0;
    var scratch: [1]u8 = undefined;

    while (i < line.len) {
        const c = line[i];

        if (c == '"' and (i == 0 or line[i - 1] != '\\')) {
            if (!in_string) {
                in_string = true;
                str_start = i + 1;
            } else {
                in_string = false;
                const str = line[str_start..i];

                if (info.level_pos) |lp| {
                    if (str_start == lp.start and i == lp.end) {
                        try output.write(Color.bold);
                        try output.write(levelColor(info.level.?));
                        try output.write("\"");
                        try output.write(str);
                        try output.write("\"");
                        try output.write(Color.reset);
                        i += 1;
                        continue;
                    }
                }

                var j = i + 1;
                while (j < line.len and line[j] == ' ') : (j += 1) {}
                if (j < line.len and line[j] == ':') {
                    try output.write(Color.key);
                    try output.write("\"");
                    try output.write(str);
                    try output.write("\"");
                    try output.write(Color.reset);
                } else {
                    try output.write("\"");
                    try output.write(str);
                    try output.write("\"");
                }
            }
            i += 1;
            continue;
        }

        if (in_string) {
            i += 1;
            continue;
        }

        if (isDigit(c) or c == '-') {
            const start = i;
            i += 1;
            while (i < line.len and
                (isDigit(line[i]) or line[i] == '.' or
                    line[i] == 'e' or line[i] == 'E' or
                    line[i] == '+' or line[i] == '-')) : (i += 1)
            {}
            try output.write(Color.number);
            try output.write(line[start..i]);
            try output.write(Color.reset);
            continue;
        }

        if (matchWord(line, i, "true")) {
            try output.write(Color.boolean);
            try output.write("true");
            try output.write(Color.reset);
            i += 4;
            continue;
        }
        if (matchWord(line, i, "false")) {
            try output.write(Color.boolean);
            try output.write("false");
            try output.write(Color.reset);
            i += 5;
            continue;
        }
        if (matchWord(line, i, "null")) {
            try output.write(Color.nullv);
            try output.write("null");
            try output.write(Color.reset);
            i += 4;
            continue;
        }

        switch (c) {
            '{', '}' => {
                scratch[0] = c;
                try output.write(Color.dim);
                try output.write(scratch[0..1]);
                try output.write(Color.reset);
            },
            ':' => {
                try output.write(Color.gray);
                try output.write(":");
                try output.write(Color.reset);
            },
            else => {
                scratch[0] = c;
                try output.write(scratch[0..1]);
            },
        }
        i += 1;
    }

    try output.write("\n");
}

/// Print a pagination prompt after each batch.
inline fn printPaginationPrompt(page: usize, count: usize) void {
    const stdout = std.fs.File.stdout();
    // Use a stack buffer to format the prompt — avoids File.writer(buf) API.
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\n{s}--- Page {d}: {d} lines | Press Enter...{s}\n", .{
        Color.dim, page, count, Color.reset,
    }) catch return;
    stdout.writeAll(s) catch {};
}

/// Wait for the user to press Enter.
fn waitForEnter() void {
    var buf: [1]u8 = undefined;
    _ = std.fs.File.stdin().read(&buf) catch {};
}

/// Clear the terminal screen if stdout is a TTY.
fn clearScreen() void {
    const stdout = std.fs.File.stdout();
    if (stdout.isTty()) stdout.writeAll("\x1b[2J\x1b[H") catch {};
}

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

/// Case-insensitive substring search.
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

/// Backward-compatible wrapper used by tail.zig.
/// Note: builds FilterState on every call.
/// Callers in a tight loop should construct FilterState once and call checkLine directly.
pub fn handleLine(line: []const u8, args: flags.Args) void {
    const filter_state = FilterState.init(args);
    if (filter_state.checkLine(line)) |info| {
        printStyledLine(line, info);
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

test "parseDateRange should parse single date" {
    const range = parseDateRange("2023-10-15");
    try std.testing.expectEqualStrings("2023-10-15", range.from.?);
    try std.testing.expectEqualStrings("2023-10-15", range.to.?);
}

test "parseDateRange should parse range with both sides" {
    const range = parseDateRange("2023-10-01..2023-10-31");
    try std.testing.expectEqualStrings("2023-10-01", range.from.?);
    try std.testing.expectEqualStrings("2023-10-31", range.to.?);
}

test "parseDateRange should parse range with only start date" {
    const range = parseDateRange("2023-10-01..");
    try std.testing.expectEqualStrings("2023-10-01", range.from.?);
    try std.testing.expect(range.to == null);
}

test "parseDateRange should parse range with only end date" {
    const range = parseDateRange("..2023-10-31");
    try std.testing.expect(range.from == null);
    try std.testing.expectEqualStrings("2023-10-31", range.to.?);
}

test "matchDateRange should return true when date is within range" {
    const range = DateRange{ .from = "2023-10-01", .to = "2023-10-31" };
    const line = "2023-10-15T12:00:00Z [INFO] Some message";
    try std.testing.expect(matchDateRange(line, range));
}

test "matchDateRange should return false when date is before range" {
    const range = DateRange{ .from = "2023-10-15", .to = "2023-10-31" };
    const line = "2023-10-01T12:00:00Z [INFO] Some message";
    try std.testing.expect(!matchDateRange(line, range));
}

test "matchDateRange should return false when date is after range" {
    const range = DateRange{ .from = "2023-10-01", .to = "2023-10-15" };
    const line = "2023-10-31T12:00:00Z [INFO] Some message";
    try std.testing.expect(!matchDateRange(line, range));
}

test "extractDate should extract ISO date from beginning of line" {
    const line = "2023-10-15T12:00:00Z [INFO] Some message";
    const result = extractDate(line);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("2023-10-15", result.?);
}

test "extractDate should return null for line without date" {
    const line = "[INFO] Some message without date";
    try std.testing.expect(extractDate(line) == null);
}

test "extractDate should return null for empty line" {
    try std.testing.expect(extractDate("") == null);
}

test "extractLevel should extract level from JSON line" {
    const line = "{\"level\":\"error\",\"message\":\"connection failed\"}";
    try std.testing.expectEqual(flags.Level.Error, extractLevel(line).?);
}

test "extractLevel should extract level from bracketed line" {
    const line = "[ERROR] connection failed";
    try std.testing.expectEqual(flags.Level.Error, extractLevel(line).?);
}

test "extractLevel should extract level from logfmt line" {
    const line = "level=error message=\"connection failed\"";
    try std.testing.expectEqual(flags.Level.Error, extractLevel(line).?);
}

test "extractLevel should return null for line without level" {
    try std.testing.expect(extractLevel("Some plain log message") == null);
}

test "extractLevel should return null for empty line" {
    try std.testing.expect(extractLevel("") == null);
}

test "parseLevelInsensitive should parse all levels case-insensitively" {
    try std.testing.expectEqual(flags.Level.Trace, flags.parseLevelInsensitive("trace").?);
    try std.testing.expectEqual(flags.Level.Debug, flags.parseLevelInsensitive("DEBUG").?);
    try std.testing.expectEqual(flags.Level.Info, flags.parseLevelInsensitive("Info").?);
    try std.testing.expectEqual(flags.Level.Warn, flags.parseLevelInsensitive("WARN").?);
    try std.testing.expectEqual(flags.Level.Error, flags.parseLevelInsensitive("error").?);
    try std.testing.expectEqual(flags.Level.Fatal, flags.parseLevelInsensitive("Fatal").?);
    try std.testing.expectEqual(flags.Level.Panic, flags.parseLevelInsensitive("PANIC").?);
}

test "parseLevelInsensitive should return null for invalid level" {
    try std.testing.expect(flags.parseLevelInsensitive("invalid") == null);
    try std.testing.expect(flags.parseLevelInsensitive("") == null);
}

test "matchSearch should match simple substring case-insensitively" {
    try std.testing.expect(matchSearch("Hello World", "world"));
    try std.testing.expect(matchSearch("HELLO WORLD", "hello"));
    try std.testing.expect(!matchSearch("Hello World", "test"));
}

test "matchSearch should support OR operator" {
    try std.testing.expect(matchSearch("Hello World", "hello|test"));
    try std.testing.expect(matchSearch("Hello World", "test|world"));
    try std.testing.expect(!matchSearch("Hello World", "foo|bar"));
}

test "matchSearch should support AND operator" {
    try std.testing.expect(matchSearch("Hello World", "hello&world"));
    try std.testing.expect(!matchSearch("Hello World", "hello&test"));
    try std.testing.expect(!matchSearch("Hello World", "test&world"));
}

test "matchSearch should handle empty parts in expression" {
    try std.testing.expect(matchSearch("Hello World", "hello||world"));
    try std.testing.expect(matchSearch("Hello World", "hello&&world"));
}

test "containsIgnoreCase should find substring case-insensitively" {
    try std.testing.expect(containsIgnoreCase("Hello World", "hello"));
    try std.testing.expect(containsIgnoreCase("HELLO WORLD", "world"));
    try std.testing.expect(containsIgnoreCase("Hello World", "lo wo"));
    try std.testing.expect(!containsIgnoreCase("Hello World", "test"));
}

test "containsIgnoreCase should handle edge cases" {
    try std.testing.expect(!containsIgnoreCase("", "test"));
    try std.testing.expect(!containsIgnoreCase("test", ""));
    try std.testing.expect(!containsIgnoreCase("short", "very long needle"));
}

test "isDigit should identify decimal digits" {
    try std.testing.expect(isDigit('0'));
    try std.testing.expect(isDigit('5'));
    try std.testing.expect(isDigit('9'));
    try std.testing.expect(!isDigit('a'));
    try std.testing.expect(!isDigit(' '));
}

test "matchWord should match word at position" {
    try std.testing.expect(matchWord("hello world", 0, "hello"));
    try std.testing.expect(matchWord("hello world", 6, "world"));
    try std.testing.expect(!matchWord("hello world", 0, "world"));
}

test "FilterState.init should initialize from args" {
    var file = [_][]const u8{"test.log"};
    const args = flags.Args{
        .files = &file,
        .tail_mode = false,
        .date = "2023-10-01..2023-10-31",
        .levels = flags.levelBit(.Error) | flags.levelBit(.Warn),
        .search = "error",
        .num_lines = 0,
    };
    const state = FilterState.init(args);
    try std.testing.expect(state.has_date_filter);
    try std.testing.expect(state.has_level_filter);
    try std.testing.expect(state.has_search_filter);
    try std.testing.expectEqualStrings("error", state.search_expr.?);
}

test "FilterState.checkLine should filter by level" {
    var file = [_][]const u8{"test.log"};
    const args = flags.Args{
        .files = &file,
        .tail_mode = false,
        .date = null,
        .levels = flags.levelBit(.Error),
        .search = null,
        .num_lines = 0,
    };
    const state = FilterState.init(args);
    try std.testing.expectEqual(flags.Level.Error, state.checkLine("[ERROR] Something went wrong").?.level.?);
    try std.testing.expect(state.checkLine("[INFO] Everything is fine") == null);
}

test "FilterState.checkLine should filter by search" {
    var file = [_][]const u8{"test.log"};
    const args = flags.Args{
        .files = &file,
        .tail_mode = false,
        .date = null,
        .levels = null,
        .search = "connection",
        .num_lines = 0,
    };
    const state = FilterState.init(args);
    try std.testing.expect(state.checkLine("[ERROR] Connection failed") != null);
    try std.testing.expect(state.checkLine("[INFO] Operation successful") == null);
}

test "FilterState.checkLine should filter by date" {
    var file = [_][]const u8{"test.log"};
    const args = flags.Args{
        .files = &file,
        .tail_mode = false,
        .date = "2023-10-15..2023-10-20",
        .levels = null,
        .search = null,
        .num_lines = 0,
    };
    const state = FilterState.init(args);
    const in_range = "{\"time\":\"2023-10-18T12:00:00Z\",\"level\":\"info\",\"msg\":\"test\"}";
    try std.testing.expect(state.checkLine(in_range) != null);
    const out_of_range = "{\"time\":\"2023-10-25T12:00:00Z\",\"level\":\"info\",\"msg\":\"test\"}";
    try std.testing.expect(state.checkLine(out_of_range) == null);
}

test "levelColor should return correct ANSI codes" {
    try std.testing.expectEqualStrings(Color.red, levelColor(.Error));
    try std.testing.expectEqualStrings(Color.red, levelColor(.Fatal));
    try std.testing.expectEqualStrings(Color.red, levelColor(.Panic));
    try std.testing.expectEqualStrings(Color.yellow, levelColor(.Warn));
    try std.testing.expectEqualStrings(Color.green, levelColor(.Info));
    try std.testing.expectEqualStrings(Color.blue, levelColor(.Debug));
    try std.testing.expectEqualStrings(Color.gray, levelColor(.Trace));
}

test "handleLine should not crash on various inputs" {
    var file = [_][]const u8{"test.log"};
    const args = flags.Args{
        .files = &file,
        .tail_mode = false,
        .date = null,
        .levels = flags.levelBit(.Error),
        .search = null,
        .num_lines = 0,
    };
    const state = FilterState.init(args);
    _ = state.checkLine("[ERROR] Test");
    _ = state.checkLine("");
}
