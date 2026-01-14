const std = @import("std");
const flags = @import("../flags/flags.zig");

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
};

/// Cached level position in a log line for efficient coloring.
const LevelRange = struct {
    start: usize,
    end: usize,
    level: flags.Level,
};

/// Date range for filtering logs with optional boundaries.
const DateRange = struct {
    from: ?[]const u8,
    to: ?[]const u8,
};

/// Pre-parsed filter state to avoid repeated string operations.
const FilterState = struct {
    has_date_filter: bool,
    date_range: DateRange,
    has_level_filter: bool,
    has_search_filter: bool,
    search_expr: ?[]const u8,

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

    /// Fast path: check if line passes all filters.
    /// Returns null if filtered out, level if passes.
    fn checkLine(self: FilterState, line: []const u8, args: flags.Args) ?flags.Level {
        if (line.len == 0) return null;

        const lvl = extractLevel(line);

        // Date filter
        if (self.has_date_filter) {
            if (!matchDateRange(line, self.date_range)) return null;
        }

        // Level filter
        if (self.has_level_filter) {
            const l = lvl orelse return null;
            if (!args.isLevelEnabled(l)) return null;
        }

        // Search filter
        if (self.has_search_filter) {
            if (!matchSearch(line, self.search_expr.?)) return null;
        }

        return lvl;
    }
};

/// Statistics for processed logs.
const Stats = struct {
    lines_read: usize = 0,
    lines_matched: usize = 0,
    bytes_read: usize = 0,
};

/// Parse date range from string with ".." separator.
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

/// Check if log line date falls within specified range.
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

/// Extract date from log line (JSON or plain text).
fn extractDate(line: []const u8) ?[]const u8 {
    if (line.len == 0) return null;

    if (line[0] == '{') {
        return extractJsonField(line, "\"time\"", 10);
    }

    // Plain text: YYYY-MM-DD at start
    if (line.len >= 10 and line[4] == '-' and line[7] == '-') {
        return line[0..10];
    }

    return null;
}

/// Generic JSON field extractor with max length.
fn extractJsonField(line: []const u8, key: []const u8, max_len: usize) ?[]const u8 {
    const pos = std.mem.indexOf(u8, line, key) orelse return null;
    var i = pos + key.len;

    // Skip whitespace and colon
    while (i < line.len and (line[i] == ' ' or line[i] == ':')) : (i += 1) {}
    if (i >= line.len or line[i] != '"') return null;
    i += 1;

    const start = i;
    const end = @min(i + max_len, line.len);

    // Find closing quote within limit
    while (i < end and line[i] != '"') : (i += 1) {}
    if (i >= line.len) return null;

    return line[start..i];
}

/// Get ANSI color for log level.
inline fn levelColor(lvl: flags.Level) []const u8 {
    return switch (lvl) {
        .Error, .Fatal, .Panic => Color.red,
        .Warn => Color.yellow,
        .Info => Color.green,
        .Debug => Color.blue,
        .Trace => Color.gray,
    };
}

/// Main entry point for reading log files.
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

/// Read entire file without pagination (optimized hot path).
fn readContinuous(
    allocator: std.mem.Allocator,
    path: []const u8,
    args: flags.Args,
) !void {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // Large buffer for fewer syscalls (128KB)
    const buffer_size = 128 * 1024;
    const buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(buffer);

    // Carry buffer for incomplete lines
    var carry = std.ArrayList(u8){};
    defer carry.deinit(allocator);
    try carry.ensureTotalCapacity(allocator, 256);

    // Pre-compute filter state once
    const filter_state = FilterState.init(args);

    var stats = Stats{};

    while (true) {
        const bytes_read = try file.read(buffer);
        if (bytes_read == 0) break;

        stats.bytes_read += bytes_read;
        var slice = buffer[0..bytes_read];

        // Prepend carried-over data
        if (carry.items.len > 0) {
            try carry.appendSlice(allocator, slice);
            slice = carry.items;
        }

        // Process lines with optimized scanning
        try processLines(allocator, slice, &carry, filter_state, args, &stats);
    }

    // Process final partial line
    if (carry.items.len > 0) {
        if (filter_state.checkLine(carry.items, args)) |lvl| {
            printStyledLine(carry.items, lvl);
            stats.lines_matched += 1;
        }
    }
}

/// Process lines from a buffer slice.
fn processLines(
    allocator: std.mem.Allocator,
    slice: []const u8,
    carry: *std.ArrayList(u8),
    filter_state: FilterState,
    args: flags.Args,
    stats: *Stats,
) !void {
    var start: usize = 0;
    var i: usize = 0;

    while (i < slice.len) : (i += 1) {
        if (slice[i] == '\n') {
            const line = slice[start..i];
            stats.lines_read += 1;

            if (line.len > 0) {
                if (filter_state.checkLine(line, args)) |lvl| {
                    printStyledLine(line, lvl);
                    stats.lines_matched += 1;
                }
            }
            start = i + 1;
        }
    }

    // Save partial line
    if (start < slice.len) {
        const partial = slice[start..];
        carry.clearRetainingCapacity();
        try carry.appendSlice(allocator, partial);
    } else {
        carry.clearRetainingCapacity();
    }
}

/// Read file with pagination support.
fn readWithPagination(
    allocator: std.mem.Allocator,
    path: []const u8,
    args: flags.Args,
) !void {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const buffer_size = 128 * 1024;
    const buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(buffer);

    var carry = std.ArrayList(u8){};
    defer carry.deinit(allocator);
    try carry.ensureTotalCapacity(allocator, 256);

    const filter_state = FilterState.init(args);

    var shown_lines: usize = 0;
    var batch_count: usize = 0;
    var batch_num: usize = 1;
    const page_size = args.num_lines;

    while (true) {
        const bytes_read = try file.read(buffer);
        if (bytes_read == 0) break;

        var slice = buffer[0..bytes_read];

        if (carry.items.len > 0) {
            try carry.appendSlice(allocator, slice);
            slice = carry.items;
        }

        var start: usize = 0;
        var i: usize = 0;

        while (i < slice.len) : (i += 1) {
            if (slice[i] == '\n') {
                const line = slice[start..i];

                if (line.len > 0) {
                    if (filter_state.checkLine(line, args)) |lvl| {
                        printStyledLine(line, lvl);
                        shown_lines += 1;
                        batch_count += 1;

                        if (batch_count >= page_size) {
                            printPaginationPrompt(batch_num, batch_count);
                            waitForEnter();
                            clearScreen();
                            batch_count = 0;
                            batch_num += 1;
                        }
                    }
                }
                start = i + 1;
            }
        }

        if (start < slice.len) {
            const partial = slice[start..];
            carry.clearRetainingCapacity();
            try carry.appendSlice(allocator, partial);
        } else {
            carry.clearRetainingCapacity();
        }
    }

    // Final partial line
    if (carry.items.len > 0) {
        if (filter_state.checkLine(carry.items, args)) |lvl| {
            printStyledLine(carry.items, lvl);
            shown_lines += 1;
        }
    }

    if (shown_lines > 0) {
        std.debug.print(
            "\n{s}=== Total: {d} lines ==={s}\n",
            .{ Color.dim, shown_lines, Color.reset },
        );
    }
}

/// Print pagination prompt.
inline fn printPaginationPrompt(batch: usize, count: usize) void {
    std.debug.print(
        "\n{s}--- Batch {d}: {d} lines | Press Enter to continue...{s}\n",
        .{ Color.dim, batch, count, Color.reset },
    );
}

/// Wait for Enter key with timeout support.
fn waitForEnter() void {
    const stdin = std.fs.File.stdin();
    var buf: [1]u8 = undefined;
    _ = stdin.read(&buf) catch return;
}

/// Clear screen using ANSI escape codes.
fn clearScreen() void {
    const stdout = std.fs.File.stdout();
    if (stdout.isTty()) {
        std.debug.print("\x1b[2J\x1b[H", .{});
    }
}

/// Print line with appropriate styling.
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

/// Print plain text log with colored level.
fn printPlainTextWithLevel(line: []const u8, level: flags.Level) void {
    const range = findLevelInLine(line);
    const color = levelColor(level);

    if (range) |r| {
        // Print: before + colored_level + after
        if (r.start > 0) {
            std.debug.print("{s}", .{line[0..r.start]});
        }
        std.debug.print(
            "{s}{s}{s}{s}",
            .{ Color.bold, color, line[r.start..r.end], Color.reset },
        );
        if (r.end < line.len) {
            std.debug.print("{s}", .{line[r.end..]});
        }
        std.debug.print("\n", .{});
    } else {
        // Fallback: color entire line
        std.debug.print("{s}{s}{s}\n", .{ color, line, Color.reset });
    }
}

/// Find level text position in line for coloring.
fn findLevelInLine(line: []const u8) ?struct { start: usize, end: usize } {
    if (line.len == 0) return null;

    // [LEVEL] format
    if (line[0] == '[') {
        const end = std.mem.indexOfScalar(u8, line, ']') orelse return null;
        return .{ .start = 1, .end = end };
    }

    // logfmt: level=VALUE
    const patterns = [_][]const u8{ "level=", "lvl=", "severity=" };
    inline for (patterns) |pattern| {
        if (std.mem.indexOf(u8, line, pattern)) |pos| {
            const start = pos + pattern.len;
            var end = start;
            while (end < line.len and line[end] != ' ') : (end += 1) {}
            return .{ .start = start, .end = end };
        }
    }

    return null;
}

/// Match search expression with OR/AND support.
fn matchSearch(line: []const u8, expr: []const u8) bool {
    // OR: a|b|c
    if (std.mem.indexOfScalar(u8, expr, '|')) |_| {
        var it = std.mem.splitScalar(u8, expr, '|');
        while (it.next()) |part| {
            if (part.len > 0 and containsIgnoreCase(line, part))
                return true;
        }
        return false;
    }

    // AND: a&b&c
    if (std.mem.indexOfScalar(u8, expr, '&')) |_| {
        var it = std.mem.splitScalar(u8, expr, '&');
        while (it.next()) |part| {
            if (part.len > 0 and !containsIgnoreCase(line, part))
                return false;
        }
        return true;
    }

    return containsIgnoreCase(line, expr);
}

/// Optimized case-insensitive substring search.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    // Fast path: use Boyer-Moore-Horspool for long needles
    if (needle.len > 8) {
        return containsIgnoreCaseBMH(haystack, needle);
    }

    // Inline path for short needles
    const max_i = haystack.len - needle.len;
    var i: usize = 0;
    while (i <= max_i) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

/// Boyer-Moore-Horspool for long search strings.
fn containsIgnoreCaseBMH(haystack: []const u8, needle: []const u8) bool {
    // Build skip table
    var skip: [256]usize = undefined;
    @memset(&skip, needle.len);

    for (needle[0 .. needle.len - 1], 0..) |c, i| {
        const lower = std.ascii.toLower(c);
        const upper = std.ascii.toUpper(c);
        skip[lower] = needle.len - 1 - i;
        skip[upper] = needle.len - 1 - i;
    }

    var i: usize = 0;
    while (i <= haystack.len - needle.len) {
        var j: usize = needle.len - 1;

        while (j > 0 and std.ascii.toLower(haystack[i + j]) == std.ascii.toLower(needle[j])) {
            j -= 1;
        }

        if (std.ascii.toLower(haystack[i]) == std.ascii.toLower(needle[0])) {
            return true;
        }

        i += skip[haystack[i + needle.len - 1]];
    }

    return false;
}

/// Parse log level from string (case-insensitive).
inline fn parseLevelInsensitive(s: []const u8) ?flags.Level {
    inline for (std.meta.fields(flags.Level)) |f| {
        if (std.ascii.eqlIgnoreCase(s, f.name)) {
            return @enumFromInt(f.value);
        }
    }
    return null;
}

/// Extract log level from line (optimized with early exits).
fn extractLevel(line: []const u8) ?flags.Level {
    if (line.len == 0) return null;

    // JSON format (most common in production)
    if (line[0] == '{') {
        return extractJsonLevel(line);
    }

    // [LEVEL] format (second most common)
    if (line[0] == '[') {
        const end = std.mem.indexOfScalar(u8, line, ']') orelse return null;
        return parseLevelInsensitive(line[1..end]);
    }

    // logfmt format (check common fields)
    if (std.mem.indexOf(u8, line, "level=")) |pos| {
        return extractLogfmtLevel(line, pos + 6);
    }
    if (std.mem.indexOf(u8, line, "lvl=")) |pos| {
        return extractLogfmtLevel(line, pos + 4);
    }

    return null;
}

/// Extract level from JSON "level" field.
fn extractJsonLevel(line: []const u8) ?flags.Level {
    const value = extractJsonField(line, "\"level\"", 16) orelse return null;
    return parseLevelInsensitive(value);
}

/// Extract level from logfmt field.
fn extractLogfmtLevel(line: []const u8, start: usize) ?flags.Level {
    var end = start;
    while (end < line.len and line[end] != ' ') : (end += 1) {}
    if (end > start) {
        return parseLevelInsensitive(line[start..end]);
    }
    return null;
}

/// Print JSON with syntax highlighting.
fn printJsonStyled(line: []const u8, lvl: ?flags.Level) void {
    // Find level value position once
    var level_pos: ?struct { start: usize, end: usize } = null;
    if (lvl != null) {
        if (std.mem.indexOf(u8, line, "\"level\"")) |pos| {
            var i = pos + 7; // len("\"level\"")
            while (i < line.len and (line[i] == ' ' or line[i] == ':')) : (i += 1) {}
            if (i < line.len and line[i] == '"') {
                i += 1;
                const start = i;
                while (i < line.len and line[i] != '"') : (i += 1) {}
                if (i < line.len) {
                    level_pos = .{ .start = start, .end = i };
                }
            }
        }
    }

    var i: usize = 0;
    var in_string = false;
    var str_start: usize = 0;

    while (i < line.len) : (i += 1) {
        const c = line[i];

        if (c == '"' and (i == 0 or line[i - 1] != '\\')) {
            if (!in_string) {
                in_string = true;
                str_start = i + 1;
            } else {
                in_string = false;
                const str = line[str_start..i];

                // Check if level value
                if (level_pos) |lp| {
                    if (str_start == lp.start and i == lp.end) {
                        const color = levelColor(lvl.?);
                        std.debug.print("{s}{s}\"{s}\"{s}", .{
                            Color.bold, color, str, Color.reset,
                        });
                        continue;
                    }
                }

                // Check if key
                var j = i + 1;
                while (j < line.len and line[j] == ' ') : (j += 1) {}

                if (j < line.len and line[j] == ':') {
                    std.debug.print("{s}\"{s}\"{s}", .{ Color.key, str, Color.reset });
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

/// Backward compatibility wrapper.
pub fn handleLine(line: []const u8, args: flags.Args) void {
    const filter_state = FilterState.init(args);
    if (filter_state.checkLine(line, args)) |lvl| {
        printStyledLine(line, lvl);
    }
}
