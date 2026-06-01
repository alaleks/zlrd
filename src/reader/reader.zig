//! Log format detection, filtering, and colored output.
//! Handles JSON, plain-text bracketed, and logfmt log formats.
//! Provides streaming reading with filtering by date, level, and search string.

const std = @import("std");
const flags = @import("flags");
const simd = @import("simd.zig");
const tail_reader = @import("tail.zig");
const formats = @import("formats.zig");
const gzip = @import("gzip.zig");
const debug_io = std.Options.debug_io;

/// Write bytes to stdout. Swallows errors — log output is best-effort.
fn writeOut(bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(debug_io, bytes) catch {};
}

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
/// Theme: GitHub Dark palette on terminal background #0d1117.
const Color = struct {
    pub const reset = "\x1b[0m";
    pub const dim = "\x1b[2m";

    /// Main text: #e6edf3
    pub const text = "\x1b[38;2;230;237;243m";
    /// Dim/muted text: #8b949e
    pub const muted = "\x1b[38;2;139;148;158m";

    /// JSON key: #58a6ff
    pub const json_key = "\x1b[38;2;88;166;255m";
    /// JSON string value: #a5d6ff
    pub const json_string = "\x1b[38;2;165;214;255m";
    /// JSON number: #79c0ff
    pub const json_number = "\x1b[38;2;121;192;255m";
    /// JSON true/false/null: #56d364
    pub const json_bool_null = "\x1b[38;2;86;211;100m";

    /// Search highlight fg: #ffd700
    pub const search_fg = "\x1b[38;2;255;215;0m";
    /// Search underline: dotted
    pub const search_underline = "\x1b[4:3m";
};

/// Byte range of a level value within a line.
const LevelPos = struct {
    start: usize,
    end: usize,
};

/// Byte range of a search match within a line.
const MatchRange = struct {
    start: usize,
    end: usize,
};

const max_search_matches = 64;

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
            if (self.enabled_levels.? & flags.levelBit(lvl) == 0) return null;
        }

        if (self.has_date_filter) {
            if (!matchDateRangeWithDate(info.date, self.date_range)) return null;
        }

        return info;
    }

    /// Convenience wrapper: filter and print in one call.
    /// Intended for tail.zig so it does not need to import `LineInfo` or `printStyledLine`.
    pub fn printIfMatch(self: FilterState, line: []const u8) void {
        if (self.checkLine(line)) |info| {
            var match_buf: [max_search_matches]MatchRange = undefined;
            const matches: []const MatchRange = if (self.has_search_filter)
                findSearchMatches(line, self.search_expr.?, &match_buf)
            else
                &.{};
            printStyledLine(line, info, matches);
        }
    }
};

/// Per-session read statistics (non-interactive mode only).
const Stats = struct {
    lines_read: usize = 0,
    lines_matched: usize = 0,
    bytes_read: usize = 0,
};

/// One aggregated log line with its occurrence count.
const AggregateEntry = struct {
    key: []const u8,
    sample_line: []const u8,
    count: usize,
};

/// Aggregates identical matched lines.
/// Keeps first-seen order and stores each unique line only once.
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
            try printStyledLineBuffered(output, line, analyzeLine(line), &.{});

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

/// Write-buffered wrapper around a `std.Io.File`.
/// Accumulates output in a heap-allocated `ArrayList` and flushes automatically
/// when the buffer reaches `max_size` or on `deinit`.
///
/// Zig 0.15.2 note: `File.writer(buf)` requires an explicit `[]u8` scratch buffer
/// and `ArrayList.writer()` requires the allocator at the call site. Both are
/// avoided here by caching the allocator and using `appendSlice` directly.
const OutputBuffer = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    file: std.Io.File,
    max_size: usize,

    fn init(allocator: std.mem.Allocator, file: std.Io.File) !OutputBuffer {
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
        var buf: [256]u8 = undefined;
        const printed = try std.fmt.bufPrint(&buf, fmt, args);
        try self.buffer.appendSlice(self.allocator, printed);
        if (self.buffer.items.len >= self.max_size) try self.flush();
    }

    /// Appends a raw byte slice to the internal buffer, flushing if full.
    fn write(self: *OutputBuffer, s: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, s);
        if (self.buffer.items.len >= self.max_size) try self.flush();
    }

    fn flush(self: *OutputBuffer) !void {
        if (self.buffer.items.len > 0) {
            try self.file.writeStreamingAll(debug_io, self.buffer.items);
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
/// Comparison is lexicographic, which is correct for ISO-8601 dates.
fn matchDateRange(line: []const u8, range: DateRange) bool {
    return matchDateRangeWithDate(extractDate(line), range);
}

/// Returns true if `date` lies within `range`.
/// `null` date never matches a range that has at least one bound.
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

/// Extracts the `YYYY-MM-DD` date prefix from a log line.
/// Recognizes JSON `time`, `timestamp`, and `date` fields and plain ISO prefixes.
/// Also handles dates immediately after an opening bracket: `[YYYY-MM-DD...`.
/// Returns a slice into `line`, or null if no date is found.
fn extractDate(line: []const u8) ?[]const u8 {
    if (line.len == 0) return null;

    if (line[0] == '{') {
        inline for (.{ "time", "timestamp", "date" }) |field| {
            if (simd.extractJsonField(line, field, 32)) |v| {
                if (v.len >= 10) return v[0..10];
            }
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

/// Background + foreground ANSI codes for a log level.
const LevelStyle = struct {
    bg: []const u8,
    fg: []const u8,
};

/// Maps a log level to its background and foreground ANSI codes.
inline fn levelStyle(lvl: flags.Level) LevelStyle {
    return switch (lvl) {
        .Trace => .{ .bg = "\x1b[48;2;48;54;61m", .fg = "\x1b[38;2;139;148;158m" },
        .Debug => .{ .bg = "\x1b[48;2;26;58;92m", .fg = "\x1b[38;2;88;166;255m" },
        .Info => .{ .bg = "\x1b[48;2;26;61;43m", .fg = "\x1b[38;2;63;185;80m" },
        .Warn => .{ .bg = "\x1b[48;2;61;46;0m", .fg = "\x1b[38;2;227;179;65m" },
        .Error => .{ .bg = "\x1b[48;2;61;26;26m", .fg = "\x1b[38;2;248;81;73m" },
        .Fatal, .Panic => .{ .bg = "\x1b[48;2;248;81;73m", .fg = "\x1b[38;2;255;255;255m" },
    };
}

/// Returns an appropriate read-buffer size based on the file's size.
/// Larger files get a larger buffer to amortize syscall overhead.
fn getOptimalBufferSize(file: std.Io.File) usize {
    const stat = file.stat(debug_io) catch return 512 * 1024;
    return if (stat.size > 100 * 1024 * 1024)
        1024 * 1024 // > 100 MB → 1 MB
    else if (stat.size > 10 * 1024 * 1024)
        512 * 1024 // > 10 MB  → 512 KB
    else
        256 * 1024; // ≤ 10 MB  → 256 KB
}

/// Entry point for reading a log file with filtering and colored output.
/// Dispatches to pagination or continuous streaming based on `args.num_lines`.
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
        try gzip.readGzip(allocator, path, args, filter_state, null);
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

/// Read the whole file, aggregate identical matched lines, and print them once.
///
/// Aggregation is applied after all active filters.
/// Output keeps the order of the first occurrence of each unique line.
fn readAggregated(
    allocator: std.mem.Allocator,
    path: []const u8,
    args: flags.Args,
) !void {
    const file = try std.Io.Dir.cwd().openFile(debug_io, path, .{});
    defer file.close(debug_io);

    const buffer_size = getOptimalBufferSize(file);
    const buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(buffer);

    var carry = try std.ArrayList(u8).initCapacity(allocator, 64 * 1024);
    defer carry.deinit(allocator);

    const filter_state = FilterState.init(args);

    var aggregator = try Aggregator.init(allocator);
    defer aggregator.deinit();

    var output = try OutputBuffer.init(allocator, std.Io.File.stdout());
    defer output.deinit();

    while (true) {
        const n = file.readStreaming(debug_io, &.{buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
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

            // Reuse LineInfo from checkLine to avoid re-parsing in buildAggregateKey.
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

    // Process final line if present (no trailing newline).
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
    const file = try std.Io.Dir.cwd().openFile(debug_io, path, .{});
    defer file.close(debug_io);

    const buffer_size = getOptimalBufferSize(file);
    const buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(buffer);

    // Accumulates bytes from the end of one read that did not form a complete line.
    var carry = try std.ArrayList(u8).initCapacity(allocator, 64 * 1024);
    defer carry.deinit(allocator);

    const filter_state = FilterState.init(args);

    var output = try OutputBuffer.init(allocator, std.Io.File.stdout());
    defer output.deinit();

    var stats = Stats{};

    while (true) {
        const n = file.readStreaming(debug_io, &.{buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
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
                var match_buf: [max_search_matches]MatchRange = undefined;
                const matches: []const MatchRange = if (filter_state.has_search_filter)
                    findSearchMatches(line, filter_state.search_expr.?, &match_buf)
                else
                    &.{};
                try printStyledLineBuffered(&output, line, info, matches);
                stats.lines_matched += 1;
            }

            start = nl + 1;
        }

        // Save the incomplete trailing bytes for the next read iteration.
        carry.clearRetainingCapacity();
        if (start < slice.len) {
            try carry.appendSlice(allocator, slice[start..]);
        }
    }

    // Flush any final line that had no trailing newline.
    if (carry.items.len > 0) {
        if (filter_state.checkLine(carry.items)) |info| {
            var match_buf: [max_search_matches]MatchRange = undefined;
            const matches: []const MatchRange = if (filter_state.has_search_filter)
                findSearchMatches(carry.items, filter_state.search_expr.?, &match_buf)
            else
                &.{};
            try printStyledLineBuffered(&output, carry.items, info, matches);
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
    const file = try std.Io.Dir.cwd().openFile(debug_io, path, .{});
    defer file.close(debug_io);

    const buffer_size = getOptimalBufferSize(file);
    const buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(buffer);

    var carry = try std.ArrayList(u8).initCapacity(allocator, 64 * 1024);
    defer carry.deinit(allocator);

    const filter_state = FilterState.init(args);

    var output = try OutputBuffer.init(allocator, std.Io.File.stdout());
    defer output.deinit();

    var batch: usize = 0;
    var page: usize = 1;

    while (true) {
        const n = file.readStreaming(debug_io, &.{buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
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
                var match_buf: [max_search_matches]MatchRange = undefined;
                const matches: []const MatchRange = if (filter_state.has_search_filter)
                    findSearchMatches(line, filter_state.search_expr.?, &match_buf)
                else
                    &.{};
                try printStyledLineBuffered(&output, line, info, matches);
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
/// Accepts a pre-computed `LineInfo` to avoid re-parsing the line.
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
/// Prefer `buildAggregateKey` with a cached `LineInfo` when available.
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

    // Unit Separator to avoid accidental ambiguity.
    try buf.append(allocator, 0x1f);

    const msg = extractMessage(line, info) orelse line;
    const trimmed = std.mem.trim(u8, msg, &std.ascii.whitespace);
    try buf.appendSlice(allocator, trimmed);

    return buf.toOwnedSlice(allocator);
}

/// Build a key from the JSON `message`/`msg` field only.
/// Falls back to the whole line if the field is absent.
fn buildJsonMessageKey(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
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
        // Skip separators.
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

/// Validate a fixed-width `YYYY-MM-DD` date string.
inline fn isValidDateString(s: []const u8) bool {
    if (s.len != 10) return false;
    return isDigit(s[0]) and isDigit(s[1]) and isDigit(s[2]) and isDigit(s[3]) and
        s[4] == '-' and
        isDigit(s[5]) and isDigit(s[6]) and
        s[7] == '-' and
        isDigit(s[8]) and isDigit(s[9]);
}

/// Returns true if `c` is an ASCII decimal digit.
inline fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Returns true if `line[pos..]` starts with `word`.
fn matchWord(line: []const u8, pos: usize, comptime word: []const u8) bool {
    return pos + word.len <= line.len and
        std.mem.eql(u8, line[pos .. pos + word.len], word);
}

/// Locates the `"level"` value inside a JSON log line and returns its byte range.
/// Used by the printer to colorize only the level token, not the surrounding JSON.
/// Continues searching after `"level"` tokens that are not followed by `: "`.
fn extractJsonLevelPos(line: []const u8) ?LevelPos {
    var search_pos: usize = 0;

    while (true) {
        const q = simd.findByte(line, search_pos, '"') orelse return null;

        if (q + 7 <= line.len and
            std.mem.eql(u8, line[q + 1 .. q + 6], "level") and
            line[q + 6] == '"')
        {
            var i = q + 7;
            while (i < line.len and (line[i] == ' ' or line[i] == ':')) : (i += 1) {}
            if (i < line.len and line[i] == '"') {
                const start = i + 1;
                const end = simd.findByte(line, start, '"') orelse return null;
                return LevelPos{ .start = start, .end = end };
            }
        }

        search_pos = q + 1;
    }
}

/// Writes bytes to stdout in uppercase.
fn writeUpper(bytes: []const u8) void {
    for (bytes) |b| {
        var buf: [1]u8 = undefined;
        buf[0] = std.ascii.toUpper(b);
        writeOut(&buf);
    }
}

/// Writes bytes to an OutputBuffer in uppercase.
fn writeUpperBuffered(output: *OutputBuffer, bytes: []const u8) !void {
    for (bytes) |b| {
        var buf: [1]u8 = undefined;
        buf[0] = std.ascii.toUpper(b);
        try output.write(&buf);
    }
}

/// Finds all non-overlapping search matches for `expr` in `line`.
/// Returns a slice of `buf` containing the matches, sorted by position.
fn findSearchMatches(line: []const u8, expr: []const u8, buf: []MatchRange) []MatchRange {
    var count: usize = 0;
    // Collect individual terms: split by | then by &
    var terms: [max_search_matches][]const u8 = undefined;
    var term_count: usize = 0;
    var or_it = std.mem.splitScalar(u8, expr, '|');
    while (or_it.next()) |or_term| {
        if (or_term.len == 0) continue;
        var and_it = std.mem.splitScalar(u8, or_term, '&');
        while (and_it.next()) |and_term| {
            if (and_term.len == 0 or term_count >= terms.len) continue;
            terms[term_count] = and_term;
            term_count += 1;
        }
    }
    // Find all matches, case-insensitive, non-overlapping per term
    for (terms[0..term_count]) |term| {
        var pos: usize = 0;
        while (pos + term.len <= line.len) {
            if (charAtIgnoreCase(line, pos, term)) {
                if (count < buf.len) {
                    buf[count] = .{ .start = pos, .end = pos + term.len };
                    count += 1;
                }
                pos += term.len;
            } else {
                pos += 1;
            }
        }
    }
    // Sort and deduplicate overlapping ranges
    if (count > 1) {
        std.mem.sort(MatchRange, buf[0..count], {}, struct {
            fn lt(_: void, a: MatchRange, b: MatchRange) bool {
                return a.start < b.start;
            }
        }.lt);
        var j: usize = 1;
        for (buf[1..count]) |m| {
            if (m.start >= buf[j - 1].end) {
                buf[j] = m;
                j += 1;
            } else if (m.end > buf[j - 1].end) {
                buf[j - 1].end = m.end;
            }
        }
        return buf[0..j];
    }
    return buf[0..count];
}

/// Returns true if `line[pos..]` starts with `needle`, case-insensitive.
fn charAtIgnoreCase(line: []const u8, pos: usize, needle: []const u8) bool {
    if (pos + needle.len > line.len) return false;
    for (needle, 0..) |c, j| {
        if (std.ascii.toLower(line[pos + j]) != std.ascii.toLower(c)) return false;
    }
    return true;
}

/// Prints a log line to stdout with ANSI coloring appropriate for its format.
/// Falls back to plain writeAll for lines with no recognized level.
fn printStyledLine(line: []const u8, info: LineInfo, search_matches: []const MatchRange) void {
    if (line.len == 0) return;

    if (info.is_json) {
        printJsonStyled(line, info, search_matches);
    } else if (info.level != null) {
        printPlainTextWithLevel(line, info, search_matches);
    } else {
        writeRangeHighlighted(line, 0, line.len, search_matches);
        writeOut("\n");
    }
}

/// Buffered version of `printStyledLine`, used in read loops to reduce syscalls.
fn printStyledLineBuffered(output: *OutputBuffer, line: []const u8, info: LineInfo, search_matches: []const MatchRange) !void {
    if (line.len == 0) return;

    if (info.is_json) {
        try printJsonStyledBuffered(output, line, info, search_matches);
    } else if (info.level != null) {
        try printPlainTextWithLevelBuffered(output, line, info, search_matches);
    } else {
        try writeRangeHighlightedBuffered(output, line, 0, line.len, search_matches);
        try output.write("\n");
    }
}

/// Writes a byte range of `line` to stdout, inserting search highlight
/// ANSI codes around `matches` that fall within the range.
fn writeRangeHighlighted(line: []const u8, start: usize, end: usize, matches: []const MatchRange) void {
    if (matches.len == 0) return writeOut(line[start..end]);
    var pos = start;
    for (matches) |m| {
        if (m.end <= pos) continue;
        if (m.start >= end) break;
        const seg_start = @max(pos, m.start);
        const seg_end = @min(end, m.end);
        if (pos < seg_start) writeOut(line[pos..seg_start]);
        writeOut(Color.search_fg);
        writeOut(Color.search_underline);
        writeOut(line[seg_start..seg_end]);
        writeOut(Color.reset);
        pos = seg_end;
    }
    if (pos < end) writeOut(line[pos..end]);
}

/// Buffered version of `writeRangeHighlighted`.
fn writeRangeHighlightedBuffered(output: *OutputBuffer, line: []const u8, start: usize, end: usize, matches: []const MatchRange) !void {
    if (matches.len == 0) return output.write(line[start..end]);
    var pos = start;
    for (matches) |m| {
        if (m.end <= pos) continue;
        if (m.start >= end) break;
        const seg_start = @max(pos, m.start);
        const seg_end = @min(end, m.end);
        if (pos < seg_start) try output.write(line[pos..seg_start]);
        try output.write(Color.search_fg);
        try output.write(Color.search_underline);
        try output.write(line[seg_start..seg_end]);
        try output.write(Color.reset);
        pos = seg_end;
    }
    if (pos < end) try output.write(line[pos..end]);
}

/// Writes a plain-text line to stdout, coloring the level token at `info.level_pos`
/// with a background + foreground color pair. Renders the level value in uppercase.
fn printPlainTextWithLevel(line: []const u8, info: LineInfo, search_matches: []const MatchRange) void {
    const style = levelStyle(info.level.?);

    if (info.level_pos) |r| {
        if (r.start > 0) writeRangeHighlighted(line, 0, r.start, search_matches);
        writeOut(style.bg);
        writeOut(style.fg);
        writeUpper(line[r.start..r.end]);
        writeOut(Color.reset);
        if (r.end < line.len) writeRangeHighlighted(line, r.end, line.len, search_matches);
        writeOut("\n");
        return;
    }

    writeRangeHighlighted(line, 0, line.len, search_matches);
    writeOut("\n");
}

/// Buffered version of `printPlainTextWithLevel`.
fn printPlainTextWithLevelBuffered(output: *OutputBuffer, line: []const u8, info: LineInfo, search_matches: []const MatchRange) !void {
    const style = levelStyle(info.level.?);

    if (info.level_pos) |r| {
        if (r.start > 0) try writeRangeHighlightedBuffered(output, line, 0, r.start, search_matches);
        try output.write(style.bg);
        try output.write(style.fg);
        try writeUpperBuffered(output, line[r.start..r.end]);
        try output.write(Color.reset);
        if (r.end < line.len) try writeRangeHighlightedBuffered(output, line, r.end, line.len, search_matches);
        try output.write("\n");
        return;
    }

    try writeRangeHighlightedBuffered(output, line, 0, line.len, search_matches);
    try output.write("\n");
}

/// Returns true if the byte at `i` in `line` is an unescaped `"`.
/// Handles `\\\"` sequences by counting consecutive preceding backslashes:
/// an even count means the backslashes are themselves escaped, so the `"` is unescaped.
inline fn isUnescapedQuote(line: []const u8, i: usize) bool {
    if (line[i] != '"') return false;
    var backslashes: usize = 0;
    var j = i;
    while (j > 0) {
        j -= 1;
        if (line[j] == '\\') backslashes += 1 else break;
    }
    return backslashes % 2 == 0;
}

/// Writes a JSON log line to stdout with syntax highlighting.
/// Keys use `Color.json_key`, strings `Color.json_string`, numbers
/// `Color.json_number`, booleans and nulls `Color.json_bool_null`.
/// The `"level"` value gets a background + foreground color from `levelStyle`.
fn printJsonStyled(line: []const u8, info: LineInfo, search_matches: []const MatchRange) void {
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
                        const style = levelStyle(info.level.?);
                        writeOut(style.bg);
                        writeOut(style.fg);
                        writeOut("\"");
                        writeUpper(str);
                        writeOut("\"");
                        writeOut(Color.reset);
                        i += 1;
                        continue;
                    }
                }

                // Detect whether this string is a JSON key (followed by ':').
                var j = i + 1;
                while (j < line.len and line[j] == ' ') : (j += 1) {}
                if (j < line.len and line[j] == ':') {
                    writeOut(Color.json_key);
                    writeOut("\"");
                    writeRangeHighlighted(line, str_start, i, search_matches);
                    writeOut("\"");
                    writeOut(Color.reset);
                } else {
                    writeOut(Color.json_string);
                    writeOut("\"");
                    writeRangeHighlighted(line, str_start, i, search_matches);
                    writeOut("\"");
                    writeOut(Color.reset);
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
            writeOut(Color.json_number);
            writeRangeHighlighted(line, start, i, search_matches);
            writeOut(Color.reset);
            continue;
        }

        if (matchWord(line, i, "true")) {
            writeOut(Color.json_bool_null);
            writeRangeHighlighted(line, i, i + 4, search_matches);
            writeOut(Color.reset);
            i += 4;
            continue;
        }
        if (matchWord(line, i, "false")) {
            writeOut(Color.json_bool_null);
            writeRangeHighlighted(line, i, i + 5, search_matches);
            writeOut(Color.reset);
            i += 5;
            continue;
        }
        if (matchWord(line, i, "null")) {
            writeOut(Color.json_bool_null);
            writeRangeHighlighted(line, i, i + 4, search_matches);
            writeOut(Color.reset);
            i += 4;
            continue;
        }

        switch (c) {
            '{', '}' => {
                scratch[0] = c;
                writeOut(Color.dim);
                writeOut(scratch[0..1]);
                writeOut(Color.reset);
            },
            ':' => {
                writeOut(Color.muted);
                writeOut(":");
                writeOut(Color.reset);
            },
            else => {
                scratch[0] = c;
                writeOut(scratch[0..1]);
            },
        }
        i += 1;
    }

    writeOut("\n");
}

/// Buffered version of `printJsonStyled`, used in read loops to reduce syscalls.
fn printJsonStyledBuffered(output: *OutputBuffer, line: []const u8, info: LineInfo, search_matches: []const MatchRange) !void {
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
                        const style = levelStyle(info.level.?);
                        try output.write(style.bg);
                        try output.write(style.fg);
                        try output.write("\"");
                        try writeUpperBuffered(output, str);
                        try output.write("\"");
                        try output.write(Color.reset);
                        i += 1;
                        continue;
                    }
                }

                var j = i + 1;
                while (j < line.len and line[j] == ' ') : (j += 1) {}
                if (j < line.len and line[j] == ':') {
                    try output.write(Color.json_key);
                    try output.write("\"");
                    try writeRangeHighlightedBuffered(output, line, str_start, i, search_matches);
                    try output.write("\"");
                    try output.write(Color.reset);
                } else {
                    try output.write(Color.json_string);
                    try output.write("\"");
                    try writeRangeHighlightedBuffered(output, line, str_start, i, search_matches);
                    try output.write("\"");
                    try output.write(Color.reset);
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
            try output.write(Color.json_number);
            try writeRangeHighlightedBuffered(output, line, start, i, search_matches);
            try output.write(Color.reset);
            continue;
        }

        if (matchWord(line, i, "true")) {
            try output.write(Color.json_bool_null);
            try writeRangeHighlightedBuffered(output, line, i, i + 4, search_matches);
            try output.write(Color.reset);
            i += 4;
            continue;
        }
        if (matchWord(line, i, "false")) {
            try output.write(Color.json_bool_null);
            try writeRangeHighlightedBuffered(output, line, i, i + 5, search_matches);
            try output.write(Color.reset);
            i += 5;
            continue;
        }
        if (matchWord(line, i, "null")) {
            try output.write(Color.json_bool_null);
            try writeRangeHighlightedBuffered(output, line, i, i + 4, search_matches);
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
                try output.write(Color.muted);
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
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "\n{s}--- Page {d}: {d} lines | Press Enter...{s}\n", .{
        Color.dim, page, count, Color.reset,
    }) catch return;
    writeOut(s);
}

/// Blocks until the user presses Enter (reads one byte from stdin).
fn waitForEnter() void {
    var buf: [1]u8 = undefined;
    _ = std.Io.File.stdin().readStreaming(debug_io, &.{&buf}) catch {};
}

/// Clears the terminal screen if stdout is a TTY.
fn clearScreen() void {
    const stdout = std.Io.File.stdout();
    if (stdout.isTty(debug_io) catch false) writeOut("\x1b[2J\x1b[H");
}

/// Matches `line` against a search expression.
/// Supports `|` (OR) and `&` (AND) operators; without either, plain substring match.
/// Matching is always case-insensitive.
/// Empty tokens produced by adjacent operators (e.g. `a||b`, `a&&b`) are skipped.
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
            // Skip empty tokens from adjacent `&&` so they don't force a false return.
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
/// In loops, build `FilterState` once with `FilterState.init` and call `checkLine` directly.
pub fn handleLine(line: []const u8, args: flags.Args) void {
    const filter_state = FilterState.init(args);
    if (filter_state.checkLine(line)) |info| {
        var match_buf: [max_search_matches]MatchRange = undefined;
        const matches: []const MatchRange = if (filter_state.has_search_filter)
            findSearchMatches(line, filter_state.search_expr.?, &match_buf)
        else
            &.{};
        printStyledLine(line, info, matches);
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

test "extractDate should extract JSON timestamp field date prefix" {
    const line = "{\"timestamp\":\"2023-10-18T12:00:00Z\",\"level\":\"info\"}";
    const result = extractDate(line);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("2023-10-18", result.?);
}

test "extractDate should extract JSON date field" {
    const line = "{\"date\":\"2023-10-18\",\"level\":\"info\"}";
    const result = extractDate(line);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("2023-10-18", result.?);
}

test "extractDate should extract ISO date from bracketed prefix" {
    const line = "[2023-10-18T12:00:00Z] [INFO] message";
    const result = extractDate(line);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("2023-10-18", result.?);
}

test "buildAggregateKey exact duplicates the full line" {
    const line = "[ERROR] Connection failed";
    const info = analyzeLine(line);
    const key = try buildAggregateKey(std.testing.allocator, .exact, line, info);
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("[ERROR] Connection failed", key);
}

test "buildAggregateKey level_message uses level + message" {
    const line = "[ERROR] Connection failed";
    const info = analyzeLine(line);
    const key = try buildAggregateKey(std.testing.allocator, .level_message, line, info);
    defer std.testing.allocator.free(key);
    try std.testing.expect(std.mem.indexOfScalar(u8, key, 0x1f) != null);
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
    // Empty tokens from `&&` are skipped; remaining tokens must all match.
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

test "levelStyle should return correct bg+fg codes" {
    try std.testing.expectEqualStrings("\x1b[48;2;61;26;26m", levelStyle(.Error).bg);
    try std.testing.expectEqualStrings("\x1b[48;2;248;81;73m", levelStyle(.Fatal).bg);
    try std.testing.expectEqualStrings("\x1b[48;2;248;81;73m", levelStyle(.Panic).bg);
    try std.testing.expectEqualStrings("\x1b[48;2;61;46;0m", levelStyle(.Warn).bg);
    try std.testing.expectEqualStrings("\x1b[48;2;26;61;43m", levelStyle(.Info).bg);
    try std.testing.expectEqualStrings("\x1b[48;2;26;58;92m", levelStyle(.Debug).bg);
    try std.testing.expectEqualStrings("\x1b[48;2;48;54;61m", levelStyle(.Trace).bg);
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

// --- isUnescapedQuote ---

test "isUnescapedQuote: plain quote" {
    try std.testing.expect(isUnescapedQuote("\"hello\"", 0));
    try std.testing.expect(isUnescapedQuote("\"hello\"", 6));
}

test "isUnescapedQuote: escaped quote" {
    // `\"` — backslash count 1 (odd) → escaped
    try std.testing.expect(!isUnescapedQuote("\\\"", 1));
}

test "isUnescapedQuote: double-escaped backslash before quote" {
    // `\\"` — two backslashes (even) → the quote is unescaped
    try std.testing.expect(isUnescapedQuote("\\\\\"", 2));
}

test "matchSearch AND with adjacent operators skips empty tokens" {
    // `hello&&world` splits into ["hello", "", "world"]; empty token is skipped
    try std.testing.expect(matchSearch("hello world", "hello&&world"));
    try std.testing.expect(!matchSearch("hello", "hello&&world"));
}

test "Aggregator counts identical lines and preserves first-seen order" {
    var agg = try Aggregator.init(std.testing.allocator);
    defer agg.deinit();

    try agg.add("[ERROR] one", "[ERROR] one");
    try agg.add("[WARN] two", "[WARN] two");
    try agg.add("[ERROR] one", "[ERROR] one");
    try agg.add("[ERROR] one", "[ERROR] one");
    try agg.add("[WARN] two", "[WARN] two");

    try std.testing.expectEqual(@as(usize, 2), agg.order.items.len);
    try std.testing.expectEqualStrings("[ERROR] one", agg.order.items[0]);
    try std.testing.expectEqualStrings("[WARN] two", agg.order.items[1]);
    try std.testing.expectEqual(@as(usize, 3), agg.counts.get("[ERROR] one").?);
    try std.testing.expectEqual(@as(usize, 2), agg.counts.get("[WARN] two").?);
    try std.testing.expectEqualStrings("[ERROR] one", agg.sample_lines.get("[ERROR] one").?);
    try std.testing.expectEqualStrings("[WARN] two", agg.sample_lines.get("[WARN] two").?);
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
    };

    const state = FilterState.init(args);

    try std.testing.expect(state.checkLine("[ERROR] Connection failed") != null);
    try std.testing.expect(state.checkLine("[ERROR] Timeout") == null);
    try std.testing.expect(state.checkLine("[INFO] Connection failed") == null);
}

test "buildAggregateKey exact uses full line" {
    const line = "[ERROR] Connection failed";

    const key = try formats.buildAggregateKeyForLine(std.testing.allocator, .exact, line);
    defer std.testing.allocator.free(key);

    try std.testing.expectEqualStrings("[ERROR] Connection failed", key);
}

test "buildAggregateKey level_message for bracketed line" {
    const line1 = "[ERROR] Connection failed";
    const line2 = "[ERROR] Connection failed";

    const key1 = try formats.buildAggregateKeyForLine(std.testing.allocator, .level_message, line1);
    defer std.testing.allocator.free(key1);

    const key2 = try formats.buildAggregateKeyForLine(std.testing.allocator, .level_message, line2);
    defer std.testing.allocator.free(key2);

    try std.testing.expectEqualStrings(key1, key2);
    try std.testing.expect(std.mem.indexOfScalar(u8, key1, 0x1f) != null);
}

test "buildAggregateKey level_message uses JSON message field" {
    const line1 = "{\"time\":\"2023-10-18T12:00:00Z\",\"level\":\"error\",\"message\":\"Connection failed\"}";
    const line2 = "{\"time\":\"2023-10-18T12:00:01Z\",\"level\":\"error\",\"message\":\"Connection failed\"}";

    const key1 = try formats.buildAggregateKeyForLine(std.testing.allocator, .level_message, line1);
    defer std.testing.allocator.free(key1);

    const key2 = try formats.buildAggregateKeyForLine(std.testing.allocator, .level_message, line2);
    defer std.testing.allocator.free(key2);

    try std.testing.expectEqualStrings(key1, key2);
}

test "buildAggregateKey json_message ignores level and timestamp differences" {
    const line1 = "{\"time\":\"2023-10-18T12:00:00Z\",\"level\":\"error\",\"message\":\"Connection failed\"}";
    const line2 = "{\"time\":\"2023-10-18T12:00:01Z\",\"level\":\"warn\",\"message\":\"Connection failed\"}";

    const key1 = try formats.buildAggregateKeyForLine(std.testing.allocator, .json_message, line1);
    defer std.testing.allocator.free(key1);

    const key2 = try formats.buildAggregateKeyForLine(std.testing.allocator, .json_message, line2);
    defer std.testing.allocator.free(key2);

    try std.testing.expectEqualStrings("Connection failed", key1);
    try std.testing.expectEqualStrings(key1, key2);
}

test "buildAggregateKey normalized collapses dates digits case and whitespace" {
    const line1 = "2023-10-18T12:00:00Z [ERROR] Request 123 failed";
    const line2 = "2023-10-19T12:00:01Z   [error]   Request 987 failed";

    const key1 = try formats.buildAggregateKeyForLine(std.testing.allocator, .normalized, line1);
    defer std.testing.allocator.free(key1);

    const key2 = try formats.buildAggregateKeyForLine(std.testing.allocator, .normalized, line2);
    defer std.testing.allocator.free(key2);

    try std.testing.expectEqualStrings(key1, key2);
}

test "Aggregator groups by key and keeps first sample line" {
    var agg = try Aggregator.init(std.testing.allocator);
    defer agg.deinit();

    const key = "error\x1fConnection failed";

    try agg.add(key, "[ERROR] Connection failed");
    try agg.add(key, "[ERROR] Connection failed");
    try agg.add(key, "[ERROR] Connection failed at retry");

    try std.testing.expectEqual(@as(usize, 1), agg.order.items.len);
    try std.testing.expectEqual(@as(usize, 3), agg.counts.get(key).?);
    try std.testing.expectEqualStrings("[ERROR] Connection failed", agg.sample_lines.get(key).?);
}

test "level_message aggregation groups same message with different timestamps" {
    var agg = try Aggregator.init(std.testing.allocator);
    defer agg.deinit();

    const line1 = "{\"time\":\"2023-10-18T12:00:00Z\",\"level\":\"error\",\"message\":\"Connection failed\"}";
    const line2 = "{\"time\":\"2023-10-18T12:00:05Z\",\"level\":\"error\",\"message\":\"Connection failed\"}";

    {
        const key = try formats.buildAggregateKeyForLine(std.testing.allocator, .level_message, line1);
        defer std.testing.allocator.free(key);
        try agg.add(key, line1);
    }
    {
        const key = try formats.buildAggregateKeyForLine(std.testing.allocator, .level_message, line2);
        defer std.testing.allocator.free(key);
        try agg.add(key, line2);
    }

    try std.testing.expectEqual(@as(usize, 1), agg.order.items.len);
    try std.testing.expectEqual(@as(usize, 2), agg.counts.get(agg.order.items[0]).?);
    try std.testing.expectEqualStrings(line1, agg.sample_lines.get(agg.order.items[0]).?);
}

test "json_message aggregation separates different messages" {
    var agg = try Aggregator.init(std.testing.allocator);
    defer agg.deinit();

    const line1 = "{\"level\":\"error\",\"message\":\"Connection failed\"}";
    const line2 = "{\"level\":\"error\",\"message\":\"Timeout\"}";

    {
        const key = try formats.buildAggregateKeyForLine(std.testing.allocator, .json_message, line1);
        defer std.testing.allocator.free(key);
        try agg.add(key, line1);
    }
    {
        const key = try formats.buildAggregateKeyForLine(std.testing.allocator, .json_message, line2);
        defer std.testing.allocator.free(key);
        try agg.add(key, line2);
    }

    try std.testing.expectEqual(@as(usize, 2), agg.order.items.len);
}

test "normalized aggregation groups noisy numeric variants" {
    var agg = try Aggregator.init(std.testing.allocator);
    defer agg.deinit();

    const line1 = "2023-10-18 [ERROR] Request 123 failed";
    const line2 = "2023-10-19 [ERROR] Request 999 failed";

    {
        const key = try formats.buildAggregateKeyForLine(std.testing.allocator, .normalized, line1);
        defer std.testing.allocator.free(key);
        try agg.add(key, line1);
    }
    {
        const key = try formats.buildAggregateKeyForLine(std.testing.allocator, .normalized, line2);
        defer std.testing.allocator.free(key);
        try agg.add(key, line2);
    }

    try std.testing.expectEqual(@as(usize, 1), agg.order.items.len);
    try std.testing.expectEqual(@as(usize, 2), agg.counts.get(agg.order.items[0]).?);
}

test "extractLogfmtField extracts quoted and unquoted values" {
    const line1 = "level=error message=test";
    const line2 = "level=error message=\"connection failed\"";

    try std.testing.expectEqualStrings("test", extractLogfmtField(line1, "message").?);
    try std.testing.expectEqualStrings("connection failed", extractLogfmtField(line2, "message").?);
}

test "extractMessage uses logfmt message field" {
    const line = "level=error message=\"connection failed\"";
    const info = analyzeLine(line);

    const msg = extractMessage(line, info).?;
    try std.testing.expectEqualStrings("connection failed", msg);
}

test "extractMessage uses plain tail after bracketed level" {
    const line = "[ERROR] connection failed";
    const info = analyzeLine(line);

    const msg = extractMessage(line, info).?;
    try std.testing.expectEqualStrings("connection failed", msg);
}
