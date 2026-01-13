const std = @import("std");
const flags = @import("../flags/flags.zig");

/// ANSI color codes for terminal output.
const Color = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";

    pub const red = "\x1b[31m";
    pub const yellow = "\x1b[33m";
    pub const green = "\x1b[32m";
    pub const blue = "\x1b[34m";
    pub const gray = "\x1b[90m";
    pub const dim = "\x1b[38;5;67m";
};

/// LevelRange is a range of log levels.
const LevelRange = struct {
    start: usize,
    end: usize,
    level: flags.Level,
};

/// Represents a date range for filtering logs.
/// Both bounds are optional to support open-ended ranges like "2024-01-01.." or "..2024-12-31".
const DateRange = struct {
    from: ?[]const u8,
    to: ?[]const u8,
};

/// Parse a date range string in the format "YYYY-MM-DD..YYYY-MM-DD".
/// Supports:
/// - Single date: "2024-01-15" (same as "2024-01-15..2024-01-15")
/// - Open start: "..2024-12-31"
/// - Open end: "2024-01-01.."
/// - Full range: "2024-01-01..2024-12-31"
fn parseDateRange(s: []const u8) DateRange {
    if (std.mem.indexOf(u8, s, "..")) |pos| {
        const left = s[0..pos];
        const right = s[pos + 2 ..];

        return .{
            .from = if (left.len > 0) left else null,
            .to = if (right.len > 0) right else null,
        };
    }

    // Single date means both from and to are the same.
    return .{
        .from = s,
        .to = s,
    };
}

/// Check if a log line's date falls within the specified range.
/// Uses lexicographic comparison which works for ISO 8601 dates (YYYY-MM-DD).
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

/// Extract date from a log line.
/// Supports both JSON logs (with "time" field) and plain text logs (YYYY-MM-DD prefix).
fn extractDate(line: []const u8) ?[]const u8 {
    if (line.len == 0) return null;

    // JSON format: {"time":"2024-01-15T10:30:45Z",...}
    if (line[0] == '{') {
        return extractJsonDate(line);
    }

    // Plain text format: 2024-01-15 10:30:45 [INFO] ...
    if (line.len >= 10) {
        return line[0..10];
    }

    return null;
}

/// Extract date from JSON "time" field.
/// Expects ISO 8601 format: "2024-01-15T10:30:45Z"
fn extractJsonDate(line: []const u8) ?[]const u8 {
    const key = "\"time\"";
    const pos = std.mem.indexOf(u8, line, key) orelse return null;

    var i = pos + key.len;

    // Skip whitespace and colon
    while (i < line.len and (line[i] == ' ' or line[i] == ':')) : (i += 1) {}

    if (i >= line.len or line[i] != '"') return null;
    i += 1;

    // Extract YYYY-MM-DD (first 10 characters of ISO 8601 date)
    if (i + 10 > line.len) return null;

    return line[i .. i + 10];
}

/// Get ANSI color code for a log level.
fn levelColor(lvl: flags.Level) []const u8 {
    return switch (lvl) {
        .Error, .Fatal, .Panic => Color.red,
        .Warn => Color.yellow,
        .Info => Color.green,
        .Debug => Color.blue,
        .Trace => Color.gray,
    };
}

/// Read and process a log file in streaming mode with fixed buffer.
/// This approach minimizes memory allocation by reusing a stack buffer.
pub fn readStreaming(
    allocator: std.mem.Allocator,
    path: []const u8,
    args: flags.Args,
) !void {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // 8KB buffer for reading chunks
    var buf: [8192]u8 = undefined;

    // Carry buffer for incomplete lines at chunk boundaries
    var carry = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer carry.deinit(allocator);

    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;

        var slice = buf[0..n];

        // If we have leftover data from previous chunk, prepend it
        if (carry.items.len != 0) {
            try carry.appendSlice(allocator, slice);
            slice = carry.items;
        }

        var it = std.mem.splitScalar(u8, slice, '\n');
        while (it.next()) |line| {
            // Last fragment without newline? Save for next iteration
            if (it.peek() == null and slice[slice.len - 1] != '\n') {
                // Clear and reuse carry buffer
                if (slice.ptr != carry.items.ptr) {
                    carry.clearRetainingCapacity();
                    try carry.appendSlice(allocator, line);
                }
                break;
            }
            handleLine(line, args);
        }

        // Clear carry if we consumed it
        if (slice.ptr == carry.items.ptr) {
            carry.clearRetainingCapacity();
        }
    }

    // Process any remaining data
    if (carry.items.len != 0) {
        handleLine(carry.items, args);
    }
}

/// Process and print a single log line with filtering and styling.
/// Applies filters in order: date, level, search expression.
pub fn handleLine(line: []const u8, args: flags.Args) void {
    // Skip empty lines early
    if (line.len == 0) return;

    const lvl = extractLevel(line);

    // Date filter (skip in tail mode to avoid unnecessary parsing)
    if (!args.tail_mode) {
        if (args.date) |date_arg| {
            const range = parseDateRange(date_arg);
            if (!matchDateRange(line, range))
                return;
        }
    }

    // Level filter
    if (args.levels != null) {
        const l = lvl orelse return;
        if (!args.isLevelEnabled(l))
            return;
    }

    // Search expression filter
    if (args.search) |expr| {
        if (!matchSearch(line, expr))
            return;
    }

    // Print with appropriate formatting
    if (line[0] == '{') {
        // JSON logs get special styling
        printJsonStyled(line, lvl);
    } else if (lvl != null) {
        // Plain text with level gets colored
        const range = extractLevelRange(line);

        if (range) |r| {
            const color = levelColor(r.level);

            // before level
            std.debug.print("{s}", .{line[0..r.start]});

            // level itself (bold + color)
            std.debug.print(
                "{s}{s}{s}{s}",
                .{
                    Color.bold,
                    color,
                    line[r.start..r.end],
                    Color.reset,
                },
            );

            // after level
            std.debug.print("{s}\n", .{line[r.end..]});
        }
    } else {
        // Plain text without level
        std.debug.print("{s}\n", .{line});
    }
}

/// Match search expression against a line.
/// Supports:
/// - Simple search: "error"
/// - OR expression: "error|warning|critical"
/// - AND expression: "user&login&failed"
fn matchSearch(line: []const u8, expr: []const u8) bool {
    // OR expression: match any term
    if (std.mem.indexOfScalar(u8, expr, '|')) |_| {
        var it = std.mem.splitScalar(u8, expr, '|');
        while (it.next()) |part| {
            if (part.len == 0) continue;
            if (containsIgnoreCase(line, part))
                return true;
        }
        return false;
    }

    // AND expression: match all terms
    if (std.mem.indexOfScalar(u8, expr, '&')) |_| {
        var it = std.mem.splitScalar(u8, expr, '&');
        while (it.next()) |part| {
            if (part.len == 0) continue;
            if (!containsIgnoreCase(line, part))
                return false;
        }
        return true;
    }

    // Simple substring search
    return containsIgnoreCase(line, expr);
}

/// Case-insensitive substring search.
/// Optimized with early bailout for impossible matches.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    // Optimize: convert needle to lowercase once
    var needle_lower: [256]u8 = undefined;
    if (needle.len > 256) {
        // Fallback to O(n*m) for very long needles
        return containsIgnoreCaseSlow(haystack, needle);
    }

    for (needle, 0..) |c, i| {
        needle_lower[i] = std.ascii.toLower(c);
    }
    const needle_slice = needle_lower[0..needle.len];

    // Slide window and compare
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matches = true;
        for (needle_slice, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != nc) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }

    return false;
}

/// Fallback for very long search strings.
fn containsIgnoreCaseSlow(haystack: []const u8, needle: []const u8) bool {
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

/// Parse log level from string, case-insensitive.
fn parseLevelInsensitive(s: []const u8) ?flags.Level {
    inline for (std.meta.fields(flags.Level)) |f| {
        if (std.ascii.eqlIgnoreCase(s, f.name)) {
            return @enumFromInt(f.value);
        }
    }
    return null;
}

/// Extract log level from a line.
/// Supports both JSON logs and plain text logs with [Level] format.
fn extractLevel(line: []const u8) ?flags.Level {
    if (line.len == 0) return null;

    // JSON format: {"level":"error",...}
    if (line[0] == '{') {
        return extractJsonLevel(line);
    }

    // Plain text format: [ERROR] or [Error]
    if (line[0] == '[') {
        const end = std.mem.indexOfScalar(u8, line, ']') orelse return null;
        return parseLevelInsensitive(line[1..end]);
    }

    // Logfmt format: level=error
    if (std.mem.indexOf(u8, line, "level=") != null) {
        return extractLogfmtLevel(line);
    }

    return null;
}

/// Extract log level from JSON "level" field.
fn extractJsonLevel(line: []const u8) ?flags.Level {
    const key = "\"level\"";
    const pos = std.mem.indexOf(u8, line, key) orelse return null;

    var i = pos + key.len;

    // Skip whitespace and colon
    while (i < line.len and (line[i] == ' ' or line[i] == ':')) : (i += 1) {}

    if (i >= line.len or line[i] != '"') return null;
    i += 1;

    const start = i;
    while (i < line.len and line[i] != '"') : (i += 1) {}
    if (i >= line.len) return null;

    return parseLevelInsensitive(line[start..i]);
}

/// Extract log level from logfmt "level" field.
fn extractLogfmtLevel(line: []const u8) ?flags.Level {
    const keys = [_][]const u8{
        "level=",
        "lvl=",
        "severity=",
    };

    inline for (keys) |key| {
        if (std.mem.indexOf(u8, line, key)) |pos| {
            var i = pos + key.len;
            if (i >= line.len) return null;

            const start = i;

            // value ends at space or end of line
            while (i < line.len and line[i] != ' ') : (i += 1) {}

            return parseLevelInsensitive(line[start..i]);
        }
    }

    return null;
}

/// Extract log level range from logfmt "level" field.
fn extractLevelRange(line: []const u8) ?LevelRange {
    if (line.len == 0) return null;

    // JSON handled elsewhere
    if (line[0] == '{') return null;

    // [WARN]
    if (line[0] == '[') {
        const end = std.mem.indexOfScalar(u8, line, ']') orelse return null;
        const lvl = parseLevelInsensitive(line[1..end]) orelse return null;
        return .{
            .start = 1,
            .end = end,
            .level = lvl,
        };
    }

    // logfmt: level=warn | lvl=warn | severity=warn
    const keys = [_][]const u8{ "level=", "lvl=", "severity=" };

    inline for (keys) |key| {
        if (std.mem.indexOf(u8, line, key)) |pos| {
            var i = pos + key.len;
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

/// Print JSON log line with syntax highlighting.
/// Keys are dimmed, level values are colored based on severity.
fn printJsonStyled(line: []const u8, lvl: ?flags.Level) void {
    var i: usize = 0;
    var in_string = false;
    var string_start: usize = 0;

    // Cache level value position to avoid re-parsing
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

        // Toggle string state on unescaped quotes
        if (c == '"' and (i == 0 or line[i - 1] != '\\')) {
            if (!in_string) {
                in_string = true;
                string_start = i + 1;
            } else {
                in_string = false;
                const str = line[string_start..i];

                // Determine if this is a key (followed by colon)
                var k = i + 1;
                while (k < line.len and line[k] == ' ') : (k += 1) {}
                const is_key = k < line.len and line[k] == ':';

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

                // Style keys differently from values
                if (is_key) {
                    std.debug.print(
                        "{s}\"{s}\"{s}",
                        .{ Color.dim, str, Color.reset },
                    );
                } else {
                    std.debug.print("\"{s}\"", .{str});
                }
            }
            continue;
        }

        // Skip characters inside strings (already printed)
        if (in_string) continue;

        // Print structural characters as-is
        std.debug.print("{c}", .{c});
    }

    std.debug.print("\n", .{});
}
