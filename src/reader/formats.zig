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

/// Range of log levels within a line for coloring.
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

/// Parse date range from string with ".." separator.
/// Supports single dates, open ranges, and full ranges.
fn parseDateRange(s: []const u8) DateRange {
    if (std.mem.indexOf(u8, s, "..")) |pos| {
        const left = s[0..pos];
        const right = s[pos + 2 ..];

        return .{
            .from = if (left.len > 0) left else null,
            .to = if (right.len > 0) right else null,
        };
    }

    // Single date: treat as both from and to
    return .{
        .from = s,
        .to = s,
    };
}

/// Check if log line date falls within specified range using lexicographic comparison.
fn matchDateRange(line: []const u8, range: DateRange) bool {
    const date = extractDate(line) orelse return false;

    if (range.from) |from| {
        if (std.mem.order(u8, date, from) == .lt)
            return false;
    }

    if (range.to) |to| {
        if (std.mem.order(u8, date, to) == .gt)
            return false;
    }

    return true;
}

/// Extract date from log line, supporting JSON and plain text formats.
fn extractDate(line: []const u8) ?[]const u8 {
    if (line.len == 0) return null;

    // JSON format: {"time":"2024-01-15T10:30:45Z",...}
    if (line[0] == '{') {
        return extractJsonDate(line);
    }

    // Plain text format: YYYY-MM-DD at start
    if (line.len >= 10 and std.ascii.isDigit(line[0])) {
        // Quick validation for date pattern
        if (line[4] == '-' and line[7] == '-') {
            return line[0..10];
        }
    }

    return null;
}

/// Extract date from JSON "time" field (ISO 8601 format).
fn extractJsonDate(line: []const u8) ?[]const u8 {
    const key = "\"time\"";
    const pos = std.mem.indexOf(u8, line, key) orelse return null;

    var i = pos + key.len;

    // Skip whitespace and colon
    while (i < line.len and (line[i] == ' ' or line[i] == ':')) : (i += 1) {}
    if (i >= line.len or line[i] != '"') return null;
    i += 1; // Skip opening quote

    // Extract YYYY-MM-DD (first 10 chars of ISO date)
    if (i + 10 > line.len) return null;

    // Validate format quickly
    if (line[i + 4] == '-' and line[i + 7] == '-') {
        return line[i .. i + 10];
    }

    return null;
}

/// Get ANSI color for log level.
fn levelColor(lvl: flags.Level) []const u8 {
    return switch (lvl) {
        .Error, .Fatal, .Panic => Color.red,
        .Warn => Color.yellow,
        .Info => Color.green,
        .Debug => Color.blue,
        .Trace => Color.gray,
    };
}

/// Read and process large files efficiently with minimal allocations.
/// Uses a larger buffer for better I/O performance and optimized line processing.
pub fn readStreaming(
    allocator: std.mem.Allocator,
    path: []const u8,
    args: flags.Args,
) !void {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // 64KB buffer for better I/O performance with large files
    var buf: [65536]u8 = undefined;

    // Create arena allocator for temporary allocations
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Carry buffer for incomplete lines (256 bytes initial, grows as needed)
    var carry = std.ArrayList(u8){};
    defer carry.deinit(arena);
    try carry.ensureTotalCapacity(arena, 256);

    // Pre-compute filters to avoid repeated checks
    const has_date_filter = !args.tail_mode and args.date != null;
    const date_range = if (has_date_filter) parseDateRange(args.date.?) else undefined;

    // Variables for paging functionality
    var total_lines: usize = 0;
    var shown_lines: usize = 0;
    const num_lines = if (args.num_lines > 0) args.num_lines else std.math.maxInt(usize);
    var current_batch_count: usize = 0;
    var first_batch = true;

    // First pass: count total lines (for accurate pagination info)
    // We need to know total number of filtered lines
    var count_file = try std.fs.cwd().openFile(path, .{});
    defer count_file.close();

    var count_buf: [65536]u8 = undefined;
    var count_carry = std.ArrayList(u8){};
    defer count_carry.deinit(arena);
    try count_carry.ensureTotalCapacity(arena, 256);

    // Count total filtered lines
    while (true) {
        const bytes_read = try count_file.read(&count_buf);
        if (bytes_read == 0) break;

        var slice = count_buf[0..bytes_read];

        if (count_carry.items.len > 0) {
            try count_carry.appendSlice(arena, slice);
            slice = count_carry.items;
        }

        var line_start: usize = 0;
        var line_end: usize = 0;

        while (line_end < slice.len) {
            if (slice[line_end] == '\n') {
                const line = slice[line_start..line_end];
                if (line.len > 0) {
                    // Check if this line would pass filters
                    if (checkLinePassesFilters(line, args, has_date_filter, date_range)) {
                        total_lines += 1;
                    }
                }
                line_start = line_end + 1;
            }
            line_end += 1;
        }

        if (line_start < slice.len) {
            const partial_line = slice[line_start..];
            count_carry.clearRetainingCapacity();
            try count_carry.appendSlice(arena, partial_line);
        } else {
            count_carry.clearRetainingCapacity();
        }
    }

    // Reset file position for actual reading
    try file.seekTo(0);

    // Reset carry buffer
    carry.clearRetainingCapacity();
    try carry.ensureTotalCapacity(arena, 256);

    // Now read and display with pagination
    while (true) {
        const bytes_read = try file.read(&buf);
        if (bytes_read == 0) break;

        var slice = buf[0..bytes_read];

        // Prepend any carried-over partial line
        if (carry.items.len > 0) {
            try carry.appendSlice(arena, slice);
            slice = carry.items;
        }

        // Process complete lines in this chunk
        var line_start: usize = 0;
        var line_end: usize = 0;

        while (line_end < slice.len) {
            if (slice[line_end] == '\n') {
                // Found complete line
                const line = slice[line_start..line_end];
                if (line.len > 0) {
                    if (handleLineWithPrecomputed(line, args, has_date_filter, date_range)) {
                        shown_lines += 1;
                        current_batch_count += 1;

                        // Check if we need to wait for user input
                        if (args.num_lines > 0 and current_batch_count >= num_lines) {
                            const left = if (total_lines > shown_lines)
                                total_lines - shown_lines
                            else
                                0;

                            if (left == 0) {
                                showPaginationInfo(shown_lines, total_lines, true);
                                return;
                            }

                            showPaginationInfo(shown_lines, total_lines, false);
                            waitForEnter();
                            clearScreen();

                            current_batch_count = 0;
                            first_batch = false;
                        }
                    }
                }
                line_start = line_end + 1;
            }
            line_end += 1;
        }

        // Handle remaining partial line
        if (line_start < slice.len) {
            const partial_line = slice[line_start..];
            carry.clearRetainingCapacity();
            try carry.appendSlice(arena, partial_line);
        } else {
            // All data was processed, clear carry
            carry.clearRetainingCapacity();
        }
    }

    // Process any final partial line
    if (carry.items.len > 0) {
        if (handleLineWithPrecomputed(carry.items, args, has_date_filter, date_range)) {
            shown_lines += 1;
            current_batch_count += 1;
        }
    }

    // Show final pagination info if in paging mode
    if (args.num_lines > 0 and shown_lines < total_lines) {
        showPaginationInfo(shown_lines, total_lines, true);
    }
}

/// Check if line passes filters without printing
fn checkLinePassesFilters(
    line: []const u8,
    args: flags.Args,
    has_date_filter: bool,
    date_range: DateRange,
) bool {
    if (line.len == 0) return false;

    const lvl = extractLevel(line);

    // Apply date filter if present
    if (has_date_filter) {
        if (!matchDateRange(line, date_range)) return false;
    }

    // Apply level filter
    if (args.levels != null) {
        const l = lvl orelse return false;
        if (!args.isLevelEnabled(l)) return false;
    }

    // Apply search filter
    if (args.search) |expr| {
        if (!matchSearch(line, expr)) return false;
    }

    return true;
}

/// Show pagination information
fn showPaginationInfo(shown: usize, total: usize, is_final: bool) void {
    const remaining = if (total > shown) total - shown else 0;

    if (is_final) {
        std.debug.print("\n{s}=== Total records: {d} ==={s}\n", .{ Color.dim, total, Color.reset });
    } else {
        std.debug.print("\n{s}--- Shown: {d} of {d} (left: {d}) --- Press Enter to continue...{s}\n", .{ Color.dim, shown, total, remaining, Color.reset });
    }
}

/// Wait for Enter key press
fn waitForEnter() void {
    const stdin = std.fs.File.stdin();
    var buffer: [1]u8 = undefined;

    const bytes_read = stdin.read(&buffer) catch {
        std.debug.print("\n", .{});
        return;
    };

    if (bytes_read == 0) {
        std.debug.print("\n", .{});
        return;
    }

    if (buffer[0] != '\n' and buffer[0] != '\r') {
        while (true) {
            const next_bytes = stdin.read(&buffer) catch break;
            if (next_bytes == 0 or buffer[0] == '\n' or buffer[0] == '\r') {
                break;
            }
        }
    }

    std.debug.print("\n", .{});
}

/// Optimized version of handleLine with pre-computed filter state.
/// Returns true if line was printed, false if filtered out.
fn handleLineWithPrecomputed(
    line: []const u8,
    args: flags.Args,
    has_date_filter: bool,
    date_range: DateRange,
) bool {
    if (line.len == 0) return false;

    const lvl = extractLevel(line);

    // Apply date filter if present
    if (has_date_filter) {
        if (!matchDateRange(line, date_range)) return false;
    }

    // Apply level filter
    if (args.levels != null) {
        const l = lvl orelse return false;
        if (!args.isLevelEnabled(l)) return false;
    }

    // Apply search filter
    if (args.search) |expr| {
        if (!matchSearch(line, expr)) return false;
    }

    // Output with appropriate formatting
    printStyledLine(line, lvl);
    return true;
}

/// Main line processing with all filters applied.
pub fn handleLine(line: []const u8, args: flags.Args) void {
    if (line.len == 0) return;

    const lvl = extractLevel(line);

    // Date filter (skip in tail mode)
    if (!args.tail_mode) {
        if (args.date) |date_arg| {
            const range = parseDateRange(date_arg);
            if (!matchDateRange(line, range)) return;
        }
    }

    // Level filter
    if (args.levels != null) {
        const l = lvl orelse return;
        if (!args.isLevelEnabled(l)) return;
    }

    // Search filter
    if (args.search) |expr| {
        if (!matchSearch(line, expr)) return;
    }

    printStyledLine(line, lvl);
}

/// Print line with appropriate styling based on format and level.
fn printStyledLine(line: []const u8, lvl: ?flags.Level) void {
    if (line[0] == '{') {
        printJsonStyled(line, lvl);
    } else if (lvl != null) {
        printPlainTextWithLevel(line);
    } else {
        std.debug.print("{s}\n", .{line});
    }
}

/// Print plain text log line with level coloring.
fn printPlainTextWithLevel(line: []const u8) void {
    const range = extractLevelRange(line);

    if (range) |r| {
        const color = levelColor(r.level);

        // Print before level
        if (r.start > 0) {
            std.debug.print("{s}", .{line[0..r.start]});
        }

        // Print level with color
        std.debug.print(
            "{s}{s}{s}{s}",
            .{
                Color.bold,
                color,
                line[r.start..r.end],
                Color.reset,
            },
        );

        // Print after level
        if (r.end < line.len) {
            std.debug.print("{s}\n", .{line[r.end..]});
        } else {
            std.debug.print("\n", .{});
        }
    } else {
        std.debug.print("{s}\n", .{line});
    }
}

/// Match search expression against line with OR/AND support.
fn matchSearch(line: []const u8, expr: []const u8) bool {
    // OR expression
    if (std.mem.indexOfScalar(u8, expr, '|')) |_| {
        var it = std.mem.splitScalar(u8, expr, '|');
        while (it.next()) |part| {
            if (part.len == 0) continue;
            if (containsIgnoreCase(line, part))
                return true;
        }
        return false;
    }

    // AND expression
    if (std.mem.indexOfScalar(u8, expr, '&')) |_| {
        var it = std.mem.splitScalar(u8, expr, '&');
        while (it.next()) |part| {
            if (part.len == 0) continue;
            if (!containsIgnoreCase(line, part))
                return false;
        }
        return true;
    }

    // Simple substring
    return containsIgnoreCase(line, expr);
}

/// Optimized case-insensitive substring search.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    // Pre-compute lowercase needle for small needles
    if (needle.len <= 256) {
        var needle_lower: [256]u8 = undefined;
        for (needle, 0..) |c, i| {
            needle_lower[i] = std.ascii.toLower(c);
        }
        const needle_slice = needle_lower[0..needle.len];

        // Slide window with early exit on mismatch
        var i: usize = 0;
        const max_i = haystack.len - needle.len;
        while (i <= max_i) : (i += 1) {
            var j: usize = 0;
            while (j < needle.len) : (j += 1) {
                if (std.ascii.toLower(haystack[i + j]) != needle_slice[j]) {
                    break;
                }
            }
            if (j == needle.len) return true;
        }
        return false;
    }

    // Fallback for very long needles
    var i: usize = 0;
    const max_i = haystack.len - needle.len;
    while (i <= max_i) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) {
            return true;
        }
    }
    return false;
}

/// Parse log level from string (case-insensitive).
fn parseLevelInsensitive(s: []const u8) ?flags.Level {
    inline for (std.meta.fields(flags.Level)) |f| {
        if (std.ascii.eqlIgnoreCase(s, f.name)) {
            return @enumFromInt(f.value);
        }
    }
    return null;
}

/// Extract log level from line (JSON, plain text, or logfmt).
fn extractLevel(line: []const u8) ?flags.Level {
    if (line.len == 0) return null;

    // JSON format
    if (line[0] == '{') {
        return extractJsonLevel(line);
    }

    // Plain text format: [LEVEL]
    if (line[0] == '[') {
        if (std.mem.indexOfScalar(u8, line, ']')) |end| {
            return parseLevelInsensitive(line[1..end]);
        }
    }

    // Logfmt format: level=value
    if (std.mem.indexOf(u8, line, "level=")) |pos| {
        return extractLogfmtField(line, pos + 6);
    }

    // Alternative logfmt fields
    if (std.mem.indexOf(u8, line, "lvl=")) |pos| {
        return extractLogfmtField(line, pos + 4);
    }

    if (std.mem.indexOf(u8, line, "severity=")) |pos| {
        return extractLogfmtField(line, pos + 9);
    }

    return null;
}

/// Extract log level from JSON "level" field.
fn extractJsonLevel(line: []const u8) ?flags.Level {
    const key = "\"level\"";
    const pos = std.mem.indexOf(u8, line, key) orelse return null;

    var i = pos + key.len;
    while (i < line.len and (line[i] == ' ' or line[i] == ':')) : (i += 1) {}
    if (i >= line.len or line[i] != '"') return null;
    i += 1; // Skip opening quote

    const start = i;
    while (i < line.len and line[i] != '"') : (i += 1) {}
    if (i >= line.len) return null;

    return parseLevelInsensitive(line[start..i]);
}

/// Extract logfmt field value starting at position.
fn extractLogfmtField(line: []const u8, start_pos: usize) ?flags.Level {
    var i = start_pos;
    const start = i;

    // Find end of value (space or end of line)
    while (i < line.len and line[i] != ' ') : (i += 1) {}

    if (i > start) {
        return parseLevelInsensitive(line[start..i]);
    }

    return null;
}

/// Extract level range for coloring in plain text logs.
fn extractLevelRange(line: []const u8) ?LevelRange {
    if (line.len == 0) return null;
    if (line[0] == '{') return null; // JSON handled elsewhere

    // [LEVEL] format
    if (line[0] == '[') {
        if (std.mem.indexOfScalar(u8, line, ']')) |end| {
            const lvl = parseLevelInsensitive(line[1..end]) orelse return null;
            return .{
                .start = 1,
                .end = end,
                .level = lvl,
            };
        }
    }

    // Check for logfmt level fields
    const fields = [_][]const u8{ "level=", "lvl=", "severity=" };

    inline for (fields) |field| {
        if (std.mem.indexOf(u8, line, field)) |pos| {
            var i = pos + field.len;
            const start = i;

            while (i < line.len and line[i] != ' ') : (i += 1) {}

            const lvl = parseLevelInsensitive(line[start..i]) orelse return null;
            return .{
                .start = start,
                .end = i,
                .level = lvl,
            };
        }
    }

    return null;
}

/// Print JSON log line with syntax highlighting and level coloring.
fn printJsonStyled(line: []const u8, lvl: ?flags.Level) void {
    // Pre-find level value position if available
    var level_range: ?struct { start: usize, end: usize } = null;
    if (lvl != null) {
        const key = "\"level\"";
        if (std.mem.indexOf(u8, line, key)) |pos| {
            var i = pos + key.len;
            while (i < line.len and (line[i] == ' ' or line[i] == ':')) : (i += 1) {}
            if (i < line.len and line[i] == '"') {
                i += 1;
                const start = i;
                while (i < line.len and line[i] != '"') : (i += 1) {}
                if (i < line.len) {
                    level_range = .{ .start = start, .end = i };
                }
            }
        }
    }

    var i: usize = 0;
    var in_string = false;
    var string_start: usize = 0;

    while (i < line.len) : (i += 1) {
        const c = line[i];

        // Handle string boundaries
        if (c == '"' and (i == 0 or line[i - 1] != '\\')) {
            if (!in_string) {
                in_string = true;
                string_start = i + 1;
            } else {
                in_string = false;
                const str = line[string_start..i];

                // Check if this is the level value
                if (level_range) |r| {
                    if (string_start == r.start and i == r.end) {
                        const color = levelColor(lvl.?);
                        std.debug.print(
                            "{s}{s}\"{s}\"{s}",
                            .{ Color.bold, color, str, Color.reset },
                        );
                        continue;
                    }
                }

                // Check if this is a key (look ahead for colon)
                var j = i + 1;
                while (j < line.len and line[j] == ' ') : (j += 1) {}
                const is_key = j < line.len and line[j] == ':';

                // Style keys with dim color
                if (is_key) {
                    std.debug.print(
                        "{s}\"{s}\"{s}",
                        .{ Color.key, str, Color.reset },
                    );
                } else {
                    std.debug.print("\"{s}\"", .{str});
                }
            }
            continue;
        }

        // Skip characters inside strings
        if (in_string) continue;

        // Print structural characters
        std.debug.print("{c}", .{c});
    }

    std.debug.print("\n", .{});
}

/// Clear the screen using ANSI escape codes.
fn clearScreen() void {
    const stdout = std.fs.File.stdout();

    if (stdout.isTty()) {
        std.debug.print("\x1b[2J\x1b[H", .{});
    }
}
