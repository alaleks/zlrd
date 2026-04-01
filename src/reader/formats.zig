//! Log format detection, filtering, and colored output.
//! Handles JSON, plain-text bracketed, and logfmt log formats.
//! Provides streaming reading with filtering by date, level, and search string.

const std = @import("std");
const flags = @import("flags");
const simd = @import("simd.zig");
const tail_reader = @import("tail.zig");
const gzip = @import("gzip.zig");

/// Cached analysis of a single log line.
/// Computed once per line by `analyzeLine` and reused by all filters and the printer.
const LineInfo = struct {
    format: enum {
        json,
        plain_bracketed,
        plain_logfmt,
        plain_unknown,
    },
    /// Extracted log level, or null if the line carries no recognizable level field.
    level: ?flags.Level,
    /// Byte range of the level value within the line, used for selective coloring.
    level_pos: ?LevelPos,
    /// Extracted YYYY-MM-DD date prefix, or null if absent.
    date: ?[]const u8,
    is_json: bool,
    starts_with_bracket: bool,
};

/// Analyzes a line and returns a fully populated `LineInfo`.
/// All subsequent operations (filtering, printing) use this result directly,
/// so the line is parsed only once per call path.
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
    info.date = extractDate(line);

    if (info.is_json) {
        info.format = .json;
        if (simd.extractJsonField(line, "level", 16)) |v| {
            info.level = flags.parseLevelInsensitive(v);
            if (extractJsonLevelPos(line)) |pos| info.level_pos = pos;
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

/// ANSI escape codes for terminal coloring.
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

/// Byte range of a level value within a line.
const LevelPos = struct {
    start: usize,
    end: usize,
};

/// Inclusive date range for the `-d` filter.
/// Both bounds are optional; a missing bound means open-ended.
const DateRange = struct {
    from: ?[]const u8,
    to: ?[]const u8,
};

/// Pre-computed filter state derived from command-line arguments.
/// Build once with `FilterState.init`, then call `checkLine` per line.
/// Keeping this separate from `flags.Args` avoids repeated string parsing
/// and repeated `args.date` null-checks in the hot path.
pub const FilterState = struct {
    has_date_filter: bool,
    date_range: DateRange,
    has_level_filter: bool,
    enabled_levels: ?flags.LevelMask,
    has_search_filter: bool,
    search_expr: ?[]const u8,

    /// Builds a `FilterState` from parsed CLI arguments.
    /// Date filtering is disabled in tail mode because tail follows live output
    /// where date-based skipping would drop all newly written lines.
    pub fn init(args: flags.Args) FilterState {
        const has_date = !args.tail_mode and args.date != null;
        return .{
            .has_date_filter = has_date,
            .date_range = if (has_date) parseDateRange(args.date.?) else .{ .from = null, .to = null },
            .has_level_filter = args.levels != null,
            .enabled_levels = args.levels,
            .has_search_filter = args.search != null,
            .search_expr = args.search,
        };
    }

    /// Returns the cached `LineInfo` if `line` passes all active filters, null otherwise.
    /// Filter order: search → level → date (cheapest to most expensive).
    pub fn checkLine(self: FilterState, line: []const u8) ?LineInfo {
        if (line.len == 0) return null;

        const info = analyzeLine(line);

        if (self.has_search_filter) {
            if (!matchSearch(line, self.search_expr.?)) return null;
        }

        if (self.has_level_filter) {
            const lvl = info.level orelse return null;
            if ((self.enabled_levels.? & flags.levelBit(lvl)) == 0) return null;
        }

        if (self.has_date_filter) {
            if (!matchDateRangeWithDate(info.date, self.date_range)) return null;
        }

        return info;
    }

    /// Convenience wrapper: filter and print in one call.
    /// Intended for tail.zig so it does not need to import `LineInfo` or `printStyledLine`.
    pub fn printIfMatch(self: FilterState, line: []const u8) void {
        if (self.checkLine(line)) |info| printStyledLine(line, info);
    }
};

/// Per-session read statistics (non-interactive mode only).
const Stats = struct {
    lines_read: usize = 0,
    lines_matched: usize = 0,
    bytes_read: usize = 0,
};

/// One aggregated output entry.
const AggregateEntry = struct {
    key: []const u8,
    sample_line: []const u8,
    count: usize,
};

/// Aggregates matched lines by a caller-provided key.
/// Keeps first-seen order and stores one sample line per key.
const Aggregator = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    counts: std.StringHashMapUnmanaged(usize),
    sample_lines: std.StringHashMapUnmanaged([]const u8),
    order: std.ArrayList([]const u8),

    fn init(allocator: std.mem.Allocator) !Aggregator {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .counts = .{},
            .sample_lines = .{},
            .order = try std.ArrayList([]const u8).initCapacity(allocator, 128),
        };
    }

    fn deinit(self: *Aggregator) void {
        self.counts.deinit(self.allocator);
        self.sample_lines.deinit(self.allocator);
        self.order.deinit(self.allocator);
        self.arena.deinit();
    }

    /// Add one matched line under a precomputed aggregation key.
    /// The first line seen for a key is kept as the sample line for display.
    fn add(self: *Aggregator, key: []const u8, sample_line: []const u8) !void {
        const gop = try self.counts.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            gop.value_ptr.* += 1;
            return;
        }

        const owned_key = try self.arena.allocator().dupe(u8, key);
        const owned_line = try self.arena.allocator().dupe(u8, sample_line);

        gop.key_ptr.* = owned_key;
        gop.value_ptr.* = 1;

        try self.sample_lines.put(self.allocator, owned_key, owned_line);
        try self.order.append(self.allocator, owned_key);
    }

    /// Print all aggregated entries in first-seen order.
    /// If `page_size > 0`, paginate the aggregated output.
    fn printAll(self: *Aggregator, output: *OutputBuffer, page_size: usize) !void {
        var batch: usize = 0;
        var page: usize = 1;

        for (self.order.items) |key| {
            const count = self.counts.get(key).?;
            const line = self.sample_lines.get(key).?;
            try printAggregatePrefix(output, count);
            try printStyledLineBuffered(output, line, analyzeLine(line));

            if (page_size > 0) {
                batch += 1;
                if (batch >= page_size) {
                    try output.flush();
                    printPaginationPrompt(page, batch);
                    waitForEnter();
                    clearScreen();
                    batch = 0;
                    page += 1;
                }
            }
        }
    }
};

/// Print `[xN] ` prefix before an aggregated line.
fn printAggregatePrefix(output: *OutputBuffer, count: usize) !void {
    try output.write(Color.dim);
    try output.print("[x{d}] ", .{count});
    try output.write(Color.reset);
}

/// Write-buffered wrapper around a `std.fs.File`.
/// Accumulates output in a heap-allocated `ArrayList` and flushes automatically
/// when the buffer reaches `max_size` or on `deinit`.
///
/// Zig 0.15.2 note: `File.writer(buf)` requires an explicit `[]u8` scratch buffer
/// and `ArrayList.writer()` requires the allocator at the call site. Both are
/// avoided here by caching the allocator and using `appendSlice` directly.
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

    /// Formats and appends text to the internal buffer, flushing if full.
    fn print(self: *OutputBuffer, comptime fmt: []const u8, args: anytype) !void {
        try self.buffer.writer(self.allocator).print(fmt, args);
        if (self.buffer.items.len >= self.max_size) try self.flush();
    }

    /// Appends a raw byte slice to the internal buffer, flushing if full.
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

/// Parses a date filter string into a `DateRange`.
/// Accepts a single date (`YYYY-MM-DD`) or a range (`FROM..TO`).
/// Either side of `..` may be omitted for an open-ended bound.
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

/// Returns true if the date extracted from `line` lies within `range`.
fn matchDateRange(line: []const u8, range: DateRange) bool {
    return matchDateRangeWithDate(extractDate(line), range);
}

/// Returns true if `date` lies within `range`.
/// `null` date never matches.
fn matchDateRangeWithDate(date: ?[]const u8, range: DateRange) bool {
    const d = date orelse return false;
    const d10 = if (d.len >= 10) d[0..10] else return false;

    if (range.from) |from| {
        const f10 = if (from.len >= 10) from[0..10] else return false;
        if (std.mem.order(u8, d10, f10) == .lt) return false;
    }
    if (range.to) |to| {
        const t10 = if (to.len >= 10) to[0..10] else return false;
        if (std.mem.order(u8, d10, t10) == .gt) return false;
    }
    return true;
}

/// Extracts the `YYYY-MM-DD` date prefix from a log line.
/// Recognizes JSON `time`, `timestamp`, and `date` fields and plain ISO prefixes.
/// Returns a slice into `line`, or null if no date is found.
fn extractDate(line: []const u8) ?[]const u8 {
    if (line.len == 0) return null;

    if (line[0] == '{') {
        if (simd.extractJsonField(line, "time", 32)) |v| {
            if (v.len >= 10) return v[0..10];
        }
        if (simd.extractJsonField(line, "timestamp", 32)) |v| {
            if (v.len >= 10) return v[0..10];
        }
        if (simd.extractJsonField(line, "date", 32)) |v| {
            if (v.len >= 10) return v[0..10];
        }
        return null;
    }

    if (simd.isISODate(line)) return line[0..10];
    if (line.len >= 11 and line[0] == '[') {
        const s = line[1..11];
        if (isValidDateString(s)) return s;
    }

    return null;
}

/// Maps a log level to its ANSI color code.
inline fn levelColor(lvl: flags.Level) []const u8 {
    return switch (lvl) {
        .Error, .Fatal, .Panic => Color.red,
        .Warn => Color.yellow,
        .Info => Color.green,
        .Debug => Color.blue,
        .Trace => Color.gray,
    };
}

/// Returns an appropriate read-buffer size based on the file's size.
/// Larger files get a larger buffer to amortize syscall overhead.
fn getOptimalBufferSize(file: std.fs.File) usize {
    const stat = file.stat() catch return 512 * 1024;
    return if (stat.size > 100 * 1024 * 1024)
        1024 * 1024
    else if (stat.size > 10 * 1024 * 1024)
        512 * 1024
    else
        256 * 1024;
}

/// Public entry point called by main.zig.
/// Dispatches to tail follow mode, gzip, pagination, or continuous streaming.
pub fn readLogs(allocator: std.mem.Allocator, args: flags.Args) !void {
    if (args.tail_mode) {
        try tail_reader.follow(allocator, args);
        return;
    }

    for (args.files) |path| {
        try readStreaming(allocator, path, args);
    }
}

/// Read a log file with filtering and colored output.
/// If aggregation is enabled, matched lines are grouped by `args.aggregate_mode`.
/// If `args.num_lines > 0`, paginates the output; otherwise streams continuously.
pub fn readStreaming(
    allocator: std.mem.Allocator,
    path: []const u8,
    args: flags.Args,
) !void {
    if (gzip.isGzip(path)) {
        const filter_state = FilterState.init(args);
        try gzip.readGzip(allocator, path, filter_state);
        return;
    }

    if (args.aggregate) {
        try readAggregated(allocator, path, args);
        return;
    }

    if (args.num_lines > 0) {
        try readWithPagination(allocator, path, args);
    } else {
        try readContinuous(allocator, path, args);
    }
}

/// Read the whole file, aggregate matched lines, and print them once.
/// Aggregation is applied after all active filters.
/// Output keeps the order of first occurrence per key.
fn readAggregated(
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

    var aggregator = try Aggregator.init(allocator);
    defer aggregator.deinit();

    var output = try OutputBuffer.init(allocator, std.fs.File.stdout());
    defer output.deinit();

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
                const key = try buildAggregateKey(allocator, args.aggregate_mode, line, info);
                defer allocator.free(key);
                try aggregator.add(key, line);
            }

            start = nl + 1;
        }

        carry.clearRetainingCapacity();
        if (start < slice.len) {
            try carry.appendSlice(allocator, slice[start..]);
        }
    }

    if (carry.items.len > 0) {
        if (filter_state.checkLine(carry.items)) |info| {
            const key = try buildAggregateKey(allocator, args.aggregate_mode, carry.items, info);
            defer allocator.free(key);
            try aggregator.add(key, carry.items);
        }
    }

    try aggregator.printAll(&output, args.num_lines);
}

/// Streams a log file continuously, printing each matching line as it is read.
fn readContinuous(
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

        carry.clearRetainingCapacity();
        if (start < slice.len) {
            try carry.appendSlice(allocator, slice[start..]);
        }
    }

    if (carry.items.len > 0) {
        if (filter_state.checkLine(carry.items)) |info| {
            try printStyledLineBuffered(&output, carry.items, info);
        }
    }
}

/// Reads a log file in pages of `args.num_lines` matching lines,
/// pausing between pages and waiting for the user to press Enter.
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

    if (carry.items.len > 0) {
        if (filter_state.checkLine(carry.items)) |info| {
            try printStyledLineBuffered(&output, carry.items, info);
        }
    }
}

/// Extracts the log level from a line without a full `analyzeLine` call.
/// Used in contexts where only the level is needed (e.g. unit tests).
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

    if (simd.findLogfmtLevel(line)) |r|
        return flags.parseLevelInsensitive(line[r.start..r.end]);

    return null;
}

/// Build an aggregation key for a matched line according to `mode`.
/// The returned slice is allocator-owned and must be freed by the caller.
pub fn buildAggregateKey(
    allocator: std.mem.Allocator,
    mode: flags.AggregateMode,
    line: []const u8,
    info: LineInfo,
) ![]u8 {
    return switch (mode) {
        .exact => allocator.dupe(u8, line),
        .level_message => buildLevelMessageKey(allocator, line, info),
        .json_message => buildJsonMessageKey(allocator, line),
        .normalized => buildNormalizedKey(allocator, line, info),
    };
}

/// Public wrapper for callers that do not have access to `LineInfo`.
pub fn buildAggregateKeyForLine(
    allocator: std.mem.Allocator,
    mode: flags.AggregateMode,
    line: []const u8,
) ![]u8 {
    return buildAggregateKey(allocator, mode, line, analyzeLine(line));
}

/// Build a key from `level + message`.
/// The level is normalized via enum tag name; message extraction depends on format.
fn buildLevelMessageKey(
    allocator: std.mem.Allocator,
    line: []const u8,
    info: LineInfo,
) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 128);
    errdefer buf.deinit(allocator);

    if (info.level) |lvl| {
        try buf.appendSlice(allocator, @tagName(lvl));
    } else {
        try buf.appendSlice(allocator, "unknown");
    }

    try buf.append(allocator, 0x1f);

    const msg = extractMessage(line, info) orelse line;
    const trimmed = std.mem.trim(u8, msg, &std.ascii.whitespace);
    try buf.appendSlice(allocator, trimmed);

    return buf.toOwnedSlice(allocator);
}

/// Build a key from the JSON `message`/`msg` field only.
/// Falls back to the whole line if the field is absent.
fn buildJsonMessageKey(
    allocator: std.mem.Allocator,
    line: []const u8,
) ![]u8 {
    const msg =
        simd.extractJsonField(line, "message", 4096) orelse
        simd.extractJsonField(line, "msg", 4096) orelse
        line;

    return allocator.dupe(u8, std.mem.trim(u8, msg, &std.ascii.whitespace));
}

/// Build a normalized key that removes common high-cardinality noise:
/// - lowercases ASCII
/// - collapses whitespace
/// - replaces ISO dates with `<date>`
/// - replaces decimal runs with `#`
fn buildNormalizedKey(
    allocator: std.mem.Allocator,
    line: []const u8,
    info: LineInfo,
) ![]u8 {
    _ = info;

    var buf = try std.ArrayList(u8).initCapacity(allocator, line.len);
    defer buf.deinit(allocator);

    var i: usize = 0;
    var prev_space = false;

    while (i < line.len) {
        if (i + 10 <= line.len and isValidDateString(line[i .. i + 10])) {
            try buf.appendSlice(allocator, "<date>");
            i += 10;
            prev_space = false;
            continue;
        }

        if (isDigit(line[i])) {
            try buf.append(allocator, '#');
            i += 1;
            while (i < line.len and isDigit(line[i])) : (i += 1) {}
            prev_space = false;
            continue;
        }

        const c = std.ascii.toLower(line[i]);
        if (std.ascii.isWhitespace(c)) {
            if (!prev_space) {
                try buf.append(allocator, ' ');
                prev_space = true;
            }
        } else {
            try buf.append(allocator, c);
            prev_space = false;
        }

        i += 1;
    }

    const trimmed = std.mem.trim(u8, buf.items, " ");
    return allocator.dupe(u8, trimmed);
}

/// Extract a human-meaningful message slice from a line.
/// Used by `level_message` aggregation mode.
fn extractMessage(line: []const u8, info: LineInfo) ?[]const u8 {
    switch (info.format) {
        .json => {
            if (simd.extractJsonField(line, "message", 4096)) |v| return v;
            if (simd.extractJsonField(line, "msg", 4096)) |v| return v;
            return null;
        },
        .plain_logfmt => {
            if (extractLogfmtField(line, "message")) |v| return v;
            if (extractLogfmtField(line, "msg")) |v| return v;
            return null;
        },
        .plain_bracketed, .plain_unknown => {
            return extractPlainMessage(line, info);
        },
    }
}

/// Extract an unquoted or quoted logfmt field value.
/// Returns a slice into `line`, or null if the key is absent.
fn extractLogfmtField(line: []const u8, comptime key: []const u8) ?[]const u8 {
    var i: usize = 0;

    while (i < line.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        if (i >= line.len) return null;

        const field_start = i;
        const eq = simd.findByte(line, i, '=') orelse return null;
        const field_key = line[field_start..eq];

        i = eq + 1;
        if (!std.mem.eql(u8, field_key, key)) {
            if (i < line.len and line[i] == '"') {
                i += 1;
                while (i < line.len and !isUnescapedQuote(line, i)) : (i += 1) {}
                if (i < line.len) i += 1;
            } else {
                while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
            }
            continue;
        }

        if (i >= line.len) return line[i..i];

        if (line[i] == '"') {
            const start = i + 1;
            i += 1;
            while (i < line.len and !isUnescapedQuote(line, i)) : (i += 1) {}
            if (i >= line.len) return null;
            return line[start..i];
        }

        const start = i;
        while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
        return line[start..i];
    }

    return null;
}

/// Extract the message part from a plain-text line.
/// This is heuristic by design: it removes an initial bracketed token and
/// common punctuation separators, then returns the remaining tail.
fn extractPlainMessage(line: []const u8, info: LineInfo) ?[]const u8 {
    var start: usize = 0;

    if (info.starts_with_bracket) {
        if (simd.findByte(line, 0, ']')) |pos| {
            start = pos + 1;
            while (start < line.len and (line[start] == ' ' or line[start] == ':' or line[start] == '-')) : (start += 1) {}
            if (start < line.len) return line[start..];
            return null;
        }
    }

    return line;
}

/// Returns true if `c` is an ASCII decimal digit.
inline fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Validate a fixed-width `YYYY-MM-DD` date string.
inline fn isValidDateString(s: []const u8) bool {
    if (s.len != 10) return false;
    return isDigit(s[0]) and isDigit(s[1]) and isDigit(s[2]) and isDigit(s[3]) and
        s[4] == '-' and
        isDigit(s[5]) and isDigit(s[6]) and
        s[7] == '-' and
        isDigit(s[8]) and isDigit(s[9]);
}

/// Returns true if `line[pos..]` starts with `word`.
fn matchWord(line: []const u8, pos: usize, comptime word: []const u8) bool {
    return pos + word.len <= line.len and
        std.mem.eql(u8, line[pos .. pos + word.len], word);
}

/// Locates the `"level"` value inside a JSON log line and returns its byte range.
/// Used by the printer to colorize only the level token, not the surrounding JSON.
fn extractJsonLevelPos(line: []const u8) ?LevelPos {
    var i: usize = 0;

    while (true) {
        const q = simd.findByte(line, i, '"') orelse return null;

        if (q + 7 <= line.len and
            std.mem.eql(u8, line[q + 1 .. q + 6], "level") and
            line[q + 6] == '"')
        {
            i = q + 7;
            break;
        }

        i = q + 1;
    }

    while (i < line.len and (line[i] == ' ' or line[i] == ':')) : (i += 1) {}
    if (i >= line.len or line[i] != '"') return null;

    const start = i + 1;
    const end = simd.findByte(line, start, '"') orelse return null;

    return LevelPos{ .start = start, .end = end };
}

/// Prints a log line to stdout with ANSI coloring appropriate for its format.
/// Falls back to plain writeAll for lines with no recognized level.
fn printStyledLine(line: []const u8, info: LineInfo) void {
    if (line.len == 0) return;

    if (info.is_json) {
        printJsonStyled(line, info);
    } else if (info.level != null) {
        printPlainTextWithLevel(line, info);
    } else {
        const stdout = std.fs.File.stdout();
        stdout.writeAll(line) catch {};
        stdout.writeAll("\n") catch {};
    }
}

/// Buffered version of `printStyledLine`, used in read loops to reduce syscalls.
fn printStyledLineBuffered(output: *OutputBuffer, line: []const u8, info: LineInfo) !void {
    if (line.len == 0) return;

    if (info.is_json) {
        try printJsonStyledBuffered(output, line, info);
    } else if (info.level != null) {
        try printPlainTextWithLevelBuffered(output, line, info);
    } else {
        try output.write(line);
        try output.write("\n");
    }
}

/// Writes a plain-text line to stdout, coloring the level token at `info.level_pos`.
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

/// Buffered version of `printPlainTextWithLevel`.
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

/// Returns true if the byte at `i` in `line` is an unescaped `"`.
inline fn isUnescapedQuote(line: []const u8, i: usize) bool {
    if (line[i] != '"') return false;
    var backslashes: usize = 0;
    var j = i;
    while (j > 0) {
        j -= 1;
        if (line[j] == '\\') backslashes += 1 else break;
    }
    return (backslashes % 2) == 0;
}

/// Writes a JSON log line to stdout with syntax highlighting.
fn printJsonStyled(line: []const u8, info: LineInfo) void {
    const stdout = std.fs.File.stdout();
    var i: usize = 0;
    var in_string = false;
    var str_start: usize = 0;
    var scratch: [1]u8 = undefined;

    while (i < line.len) {
        const c = line[i];

        if (isUnescapedQuote(line, i)) {
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
                scratch[0] = c;
                stdout.writeAll(Color.dim) catch {};
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

/// Buffered version of `printJsonStyled`, used in read loops to reduce syscalls.
fn printJsonStyledBuffered(output: *OutputBuffer, line: []const u8, info: LineInfo) !void {
    var i: usize = 0;
    var in_string = false;
    var str_start: usize = 0;
    var scratch: [1]u8 = undefined;

    while (i < line.len) {
        const c = line[i];

        if (isUnescapedQuote(line, i)) {
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

/// Prints a pagination prompt to stdout after each full page.
inline fn printPaginationPrompt(page: usize, count: usize) void {
    const stdout = std.fs.File.stdout();
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\n{s}--- Page {d}: {d} lines | Press Enter...{s}\n", .{
        Color.dim, page, count, Color.reset,
    }) catch return;
    stdout.writeAll(s) catch {};
}

/// Blocks until the user presses Enter (reads one byte from stdin).
fn waitForEnter() void {
    var buf: [1]u8 = undefined;
    _ = std.fs.File.stdin().read(&buf) catch {};
}

/// Clears the terminal screen if stdout is a TTY.
fn clearScreen() void {
    const stdout = std.fs.File.stdout();
    if (stdout.isTty()) stdout.writeAll("\x1b[2J\x1b[H") catch {};
}

/// Matches `line` against a search expression.
/// Supports `|` (OR) and `&` (AND) operators; without either, plain substring match.
/// Matching is always case-insensitive.
/// Empty tokens produced by adjacent operators are skipped.
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
            if (p.len == 0) continue;
            if (!containsIgnoreCase(line, p)) return false;
        }
        return true;
    }

    return containsIgnoreCase(line, expr);
}

/// Returns true if `needle` appears in `hay` (case-insensitive).
/// Returns false if either slice is empty or `needle` is longer than `hay`.
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

/// Backward-compatible wrapper for tail.zig.
/// Constructs a `FilterState` on every call — do not use in tight loops.
pub fn handleLine(line: []const u8, args: flags.Args) void {
    const filter_state = FilterState.init(args);
    if (filter_state.checkLine(line)) |info| printStyledLine(line, info);
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "parseDateRange should parse single date" {
    const range = parseDateRange("2023-10-15");
    try testing.expectEqualStrings("2023-10-15", range.from.?);
    try testing.expectEqualStrings("2023-10-15", range.to.?);
}

test "parseDateRange should parse range with both sides" {
    const range = parseDateRange("2023-10-01..2023-10-31");
    try testing.expectEqualStrings("2023-10-01", range.from.?);
    try testing.expectEqualStrings("2023-10-31", range.to.?);
}

test "parseDateRange should parse range with only start date" {
    const range = parseDateRange("2023-10-01..");
    try testing.expectEqualStrings("2023-10-01", range.from.?);
    try testing.expect(range.to == null);
}

test "parseDateRange should parse range with only end date" {
    const range = parseDateRange("..2023-10-31");
    try testing.expect(range.from == null);
    try testing.expectEqualStrings("2023-10-31", range.to.?);
}

test "matchDateRange should return true when date is within range" {
    const range = DateRange{ .from = "2023-10-01", .to = "2023-10-31" };
    const line = "2023-10-15T12:00:00Z [INFO] Some message";
    try testing.expect(matchDateRange(line, range));
}

test "matchDateRange should return false when date is before range" {
    const range = DateRange{ .from = "2023-10-15", .to = "2023-10-31" };
    const line = "2023-10-01T12:00:00Z [INFO] Some message";
    try testing.expect(!matchDateRange(line, range));
}

test "matchDateRange should return false when date is after range" {
    const range = DateRange{ .from = "2023-10-01", .to = "2023-10-15" };
    const line = "2023-10-31T12:00:00Z [INFO] Some message";
    try testing.expect(!matchDateRange(line, range));
}

test "extractDate should extract ISO date from beginning of line" {
    const line = "2023-10-15T12:00:00Z [INFO] Some message";
    const result = extractDate(line);
    try testing.expect(result != null);
    try testing.expectEqualStrings("2023-10-15", result.?);
}

test "extractDate should extract JSON time field date prefix" {
    const line = "{\"time\":\"2023-10-18T12:00:00Z\",\"level\":\"info\"}";
    const result = extractDate(line);
    try testing.expect(result != null);
    try testing.expectEqualStrings("2023-10-18", result.?);
}

test "extractDate should extract JSON timestamp field date prefix" {
    const line = "{\"timestamp\":\"2023-10-18T12:00:00Z\",\"level\":\"info\"}";
    const result = extractDate(line);
    try testing.expect(result != null);
    try testing.expectEqualStrings("2023-10-18", result.?);
}

test "extractDate should extract JSON date field" {
    const line = "{\"date\":\"2023-10-18\",\"level\":\"info\"}";
    const result = extractDate(line);
    try testing.expect(result != null);
    try testing.expectEqualStrings("2023-10-18", result.?);
}

test "extractDate should return null for line without date" {
    const line = "[INFO] Some message without date";
    try testing.expect(extractDate(line) == null);
}

test "extractDate should return null for empty line" {
    try testing.expect(extractDate("") == null);
}

test "extractLevel should extract level from JSON line" {
    const line = "{\"level\":\"error\",\"message\":\"connection failed\"}";
    try testing.expectEqual(flags.Level.Error, extractLevel(line).?);
}

test "extractLevel should extract level from bracketed line" {
    const line = "[ERROR] connection failed";
    try testing.expectEqual(flags.Level.Error, extractLevel(line).?);
}

test "extractLevel should extract level from logfmt line" {
    const line = "level=error message=\"connection failed\"";
    try testing.expectEqual(flags.Level.Error, extractLevel(line).?);
}

test "extractLevel should return null for line without level" {
    try testing.expect(extractLevel("Some plain log message") == null);
}

test "extractLevel should return null for empty line" {
    try testing.expect(extractLevel("") == null);
}

test "matchSearch should match simple substring case-insensitively" {
    try testing.expect(matchSearch("Hello World", "world"));
    try testing.expect(matchSearch("HELLO WORLD", "hello"));
    try testing.expect(!matchSearch("Hello World", "test"));
}

test "matchSearch should support OR operator" {
    try testing.expect(matchSearch("Hello World", "hello|test"));
    try testing.expect(matchSearch("Hello World", "test|world"));
    try testing.expect(!matchSearch("Hello World", "foo|bar"));
}

test "matchSearch should support AND operator" {
    try testing.expect(matchSearch("Hello World", "hello&world"));
    try testing.expect(!matchSearch("Hello World", "hello&test"));
    try testing.expect(!matchSearch("Hello World", "test&world"));
}

test "matchSearch should handle empty parts in expression" {
    try testing.expect(matchSearch("Hello World", "hello||world"));
    try testing.expect(matchSearch("Hello World", "hello&&world"));
}

test "containsIgnoreCase should find substring case-insensitively" {
    try testing.expect(containsIgnoreCase("Hello World", "hello"));
    try testing.expect(containsIgnoreCase("HELLO WORLD", "world"));
    try testing.expect(containsIgnoreCase("Hello World", "lo wo"));
    try testing.expect(!containsIgnoreCase("Hello World", "test"));
}

test "containsIgnoreCase should handle edge cases" {
    try testing.expect(!containsIgnoreCase("", "test"));
    try testing.expect(!containsIgnoreCase("test", ""));
    try testing.expect(!containsIgnoreCase("short", "very long needle"));
}

test "isDigit should identify decimal digits" {
    try testing.expect(isDigit('0'));
    try testing.expect(isDigit('5'));
    try testing.expect(isDigit('9'));
    try testing.expect(!isDigit('a'));
    try testing.expect(!isDigit(' '));
}

test "matchWord should match word at position" {
    try testing.expect(matchWord("hello world", 0, "hello"));
    try testing.expect(matchWord("hello world", 6, "world"));
    try testing.expect(!matchWord("hello world", 0, "world"));
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
        .aggregate = false,
        .aggregate_mode = .exact,
    };
    const state = FilterState.init(args);
    try testing.expect(state.has_date_filter);
    try testing.expect(state.has_level_filter);
    try testing.expect(state.has_search_filter);
    try testing.expectEqualStrings("error", state.search_expr.?);
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
        .aggregate = false,
        .aggregate_mode = .exact,
    };
    const state = FilterState.init(args);
    try testing.expectEqual(flags.Level.Error, state.checkLine("[ERROR] Something went wrong").?.level.?);
    try testing.expect(state.checkLine("[INFO] Everything is fine") == null);
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
        .aggregate = false,
        .aggregate_mode = .exact,
    };
    const state = FilterState.init(args);
    try testing.expect(state.checkLine("[ERROR] Connection failed") != null);
    try testing.expect(state.checkLine("[INFO] Operation successful") == null);
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
        .aggregate = false,
        .aggregate_mode = .exact,
    };
    const state = FilterState.init(args);
    const in_range = "{\"time\":\"2023-10-18T12:00:00Z\",\"level\":\"info\",\"msg\":\"test\"}";
    try testing.expect(state.checkLine(in_range) != null);
    const out_of_range = "{\"time\":\"2023-10-25T12:00:00Z\",\"level\":\"info\",\"msg\":\"test\"}";
    try testing.expect(state.checkLine(out_of_range) == null);
}

test "levelColor should return correct ANSI codes" {
    try testing.expectEqualStrings(Color.red, levelColor(.Error));
    try testing.expectEqualStrings(Color.red, levelColor(.Fatal));
    try testing.expectEqualStrings(Color.red, levelColor(.Panic));
    try testing.expectEqualStrings(Color.yellow, levelColor(.Warn));
    try testing.expectEqualStrings(Color.green, levelColor(.Info));
    try testing.expectEqualStrings(Color.blue, levelColor(.Debug));
    try testing.expectEqualStrings(Color.gray, levelColor(.Trace));
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
        .aggregate = false,
        .aggregate_mode = .exact,
    };
    const state = FilterState.init(args);
    _ = state.checkLine("[ERROR] Test");
    _ = state.checkLine("");
}

test "isUnescapedQuote: plain quote" {
    try testing.expect(isUnescapedQuote("\"hello\"", 0));
    try testing.expect(isUnescapedQuote("\"hello\"", 6));
}

test "isUnescapedQuote: escaped quote" {
    try testing.expect(!isUnescapedQuote("\\\"", 1));
}

test "isUnescapedQuote: double-escaped backslash before quote" {
    try testing.expect(isUnescapedQuote("\\\\\"", 2));
}

test "matchSearch AND with adjacent operators skips empty tokens" {
    try testing.expect(matchSearch("hello world", "hello&&world"));
    try testing.expect(!matchSearch("hello", "hello&&world"));
}

test "Aggregator counts identical lines and preserves first-seen order" {
    var agg = try Aggregator.init(testing.allocator);
    defer agg.deinit();

    try agg.add("[ERROR] one", "[ERROR] one");
    try agg.add("[WARN] two", "[WARN] two");
    try agg.add("[ERROR] one", "[ERROR] one");
    try agg.add("[ERROR] one", "[ERROR] one");
    try agg.add("[WARN] two", "[WARN] two");

    try testing.expectEqual(@as(usize, 2), agg.order.items.len);
    try testing.expectEqualStrings("[ERROR] one", agg.order.items[0]);
    try testing.expectEqualStrings("[WARN] two", agg.order.items[1]);
    try testing.expectEqual(@as(usize, 3), agg.counts.get("[ERROR] one").?);
    try testing.expectEqual(@as(usize, 2), agg.counts.get("[WARN] two").?);
    try testing.expectEqualStrings("[ERROR] one", agg.sample_lines.get("[ERROR] one").?);
    try testing.expectEqualStrings("[WARN] two", agg.sample_lines.get("[WARN] two").?);
}

test "FilterState with aggregation semantics still filters before counting" {
    var file = [_][]const u8{"test.log"};
    const args = flags.Args{
        .files = &file,
        .tail_mode = false,
        .date = null,
        .levels = flags.levelBit(.Error),
        .search = "connection",
        .num_lines = 0,
        .aggregate = true,
        .aggregate_mode = .exact,
    };

    const state = FilterState.init(args);

    try testing.expect(state.checkLine("[ERROR] Connection failed") != null);
    try testing.expect(state.checkLine("[ERROR] Timeout") == null);
    try testing.expect(state.checkLine("[INFO] Connection failed") == null);
}

test "buildAggregateKey exact uses full line" {
    const line = "[ERROR] Connection failed";
    const info = analyzeLine(line);

    const key = try buildAggregateKey(testing.allocator, .exact, line, info);
    defer testing.allocator.free(key);

    try testing.expectEqualStrings("[ERROR] Connection failed", key);
}

test "buildAggregateKey level_message for bracketed line" {
    const line1 = "[ERROR] Connection failed";
    const line2 = "[ERROR] Connection failed";

    const key1 = try buildAggregateKey(testing.allocator, .level_message, line1, analyzeLine(line1));
    defer testing.allocator.free(key1);

    const key2 = try buildAggregateKey(testing.allocator, .level_message, line2, analyzeLine(line2));
    defer testing.allocator.free(key2);

    try testing.expectEqualStrings(key1, key2);
    try testing.expect(std.mem.indexOfScalar(u8, key1, 0x1f) != null);
}

test "buildAggregateKey level_message uses JSON message field" {
    const line1 = "{\"time\":\"2023-10-18T12:00:00Z\",\"level\":\"error\",\"message\":\"Connection failed\"}";
    const line2 = "{\"time\":\"2023-10-18T12:00:01Z\",\"level\":\"error\",\"message\":\"Connection failed\"}";

    const key1 = try buildAggregateKey(testing.allocator, .level_message, line1, analyzeLine(line1));
    defer testing.allocator.free(key1);

    const key2 = try buildAggregateKey(testing.allocator, .level_message, line2, analyzeLine(line2));
    defer testing.allocator.free(key2);

    try testing.expectEqualStrings(key1, key2);
}

test "buildAggregateKey json_message ignores level and timestamp differences" {
    const line1 = "{\"time\":\"2023-10-18T12:00:00Z\",\"level\":\"error\",\"message\":\"Connection failed\"}";
    const line2 = "{\"time\":\"2023-10-18T12:00:01Z\",\"level\":\"warn\",\"message\":\"Connection failed\"}";

    const key1 = try buildAggregateKey(testing.allocator, .json_message, line1, analyzeLine(line1));
    defer testing.allocator.free(key1);

    const key2 = try buildAggregateKey(testing.allocator, .json_message, line2, analyzeLine(line2));
    defer testing.allocator.free(key2);

    try testing.expectEqualStrings("Connection failed", key1);
    try testing.expectEqualStrings(key1, key2);
}

test "buildAggregateKey normalized collapses dates digits case and whitespace" {
    const line1 = "2023-10-18T12:00:00Z [ERROR] Request 123 failed";
    const line2 = "2023-10-19T12:00:01Z   [error]   Request 987 failed";

    const key1 = try buildAggregateKey(testing.allocator, .normalized, line1, analyzeLine(line1));
    defer testing.allocator.free(key1);

    const key2 = try buildAggregateKey(testing.allocator, .normalized, line2, analyzeLine(line2));
    defer testing.allocator.free(key2);

    try testing.expectEqualStrings(key1, key2);
}

test "Aggregator groups by key and keeps first sample line" {
    var agg = try Aggregator.init(testing.allocator);
    defer agg.deinit();

    const key = "error\x1fConnection failed";

    try agg.add(key, "[ERROR] Connection failed");
    try agg.add(key, "[ERROR] Connection failed");
    try agg.add(key, "[ERROR] Connection failed at retry");

    try testing.expectEqual(@as(usize, 1), agg.order.items.len);
    try testing.expectEqual(@as(usize, 3), agg.counts.get(key).?);
    try testing.expectEqualStrings("[ERROR] Connection failed", agg.sample_lines.get(key).?);
}

test "level_message aggregation groups same message with different timestamps" {
    var agg = try Aggregator.init(testing.allocator);
    defer agg.deinit();

    const line1 = "{\"time\":\"2023-10-18T12:00:00Z\",\"level\":\"error\",\"message\":\"Connection failed\"}";
    const line2 = "{\"time\":\"2023-10-18T12:00:05Z\",\"level\":\"error\",\"message\":\"Connection failed\"}";

    {
        const key = try buildAggregateKey(testing.allocator, .level_message, line1, analyzeLine(line1));
        defer testing.allocator.free(key);
        try agg.add(key, line1);
    }
    {
        const key = try buildAggregateKey(testing.allocator, .level_message, line2, analyzeLine(line2));
        defer testing.allocator.free(key);
        try agg.add(key, line2);
    }

    try testing.expectEqual(@as(usize, 1), agg.order.items.len);
    try testing.expectEqual(@as(usize, 2), agg.counts.get(agg.order.items[0]).?);
    try testing.expectEqualStrings(line1, agg.sample_lines.get(agg.order.items[0]).?);
}

test "json_message aggregation separates different messages" {
    var agg = try Aggregator.init(testing.allocator);
    defer agg.deinit();

    const line1 = "{\"level\":\"error\",\"message\":\"Connection failed\"}";
    const line2 = "{\"level\":\"error\",\"message\":\"Timeout\"}";

    {
        const key = try buildAggregateKey(testing.allocator, .json_message, line1, analyzeLine(line1));
        defer testing.allocator.free(key);
        try agg.add(key, line1);
    }
    {
        const key = try buildAggregateKey(testing.allocator, .json_message, line2, analyzeLine(line2));
        defer testing.allocator.free(key);
        try agg.add(key, line2);
    }

    try testing.expectEqual(@as(usize, 2), agg.order.items.len);
}

test "normalized aggregation groups noisy numeric variants" {
    var agg = try Aggregator.init(testing.allocator);
    defer agg.deinit();

    const line1 = "2023-10-18 [ERROR] Request 123 failed";
    const line2 = "2023-10-19 [ERROR] Request 999 failed";

    {
        const key = try buildAggregateKey(testing.allocator, .normalized, line1, analyzeLine(line1));
        defer testing.allocator.free(key);
        try agg.add(key, line1);
    }
    {
        const key = try buildAggregateKey(testing.allocator, .normalized, line2, analyzeLine(line2));
        defer testing.allocator.free(key);
        try agg.add(key, line2);
    }

    try testing.expectEqual(@as(usize, 1), agg.order.items.len);
    try testing.expectEqual(@as(usize, 2), agg.counts.get(agg.order.items[0]).?);
}

test "extractLogfmtField extracts quoted and unquoted values" {
    const line1 = "level=error message=test";
    const line2 = "level=error message=\"connection failed\"";

    try testing.expectEqualStrings("test", extractLogfmtField(line1, "message").?);
    try testing.expectEqualStrings("connection failed", extractLogfmtField(line2, "message").?);
}

test "extractMessage uses logfmt message field" {
    const line = "level=error message=\"connection failed\"";
    const info = analyzeLine(line);

    const msg = extractMessage(line, info).?;
    try testing.expectEqualStrings("connection failed", msg);
}

test "extractMessage uses plain tail after bracketed level" {
    const line = "[ERROR] connection failed";
    const info = analyzeLine(line);

    const msg = extractMessage(line, info).?;
    try testing.expectEqualStrings("connection failed", msg);
}
