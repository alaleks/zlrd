//! Streaming gzip decompressor for line-oriented log reading.
//! Wraps `std.compress.flate.Decompress` and feeds decompressed lines into
//! the same filter/print pipeline as regular files.

const std = @import("std");
const flags = @import("flags");
const simd = @import("simd.zig");

/// Upper bound for a single logical line kept in memory while waiting for `\n`.
/// Protects against corrupted input or unexpectedly huge records.
pub const MaxLineLen = 4 * 1024 * 1024;

/// Callback used to build aggregation keys without importing reader/formats code here.
pub const AggregateKeyBuilder = *const fn (
    allocator: std.mem.Allocator,
    mode: flags.AggregateMode,
    line: []const u8,
) anyerror![]u8;

/// Errors specific to gzip line streaming.
pub const GzipReadError = error{
    LineTooLong,
    MissingAggregateKeyBuilder,
    MissingAggregator,
};

/// One aggregated output entry kept for the current gzip read.
const BatchAggregator = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    counts: std.StringHashMapUnmanaged(usize),
    sample_lines: std.StringHashMapUnmanaged([]const u8),
    order: std.ArrayList([]const u8),

    fn init(allocator: std.mem.Allocator) !BatchAggregator {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .counts = .{},
            .sample_lines = .{},
            .order = try std.ArrayList([]const u8).initCapacity(allocator, 32),
        };
    }

    fn deinit(self: *BatchAggregator) void {
        self.counts.deinit(self.allocator);
        self.sample_lines.deinit(self.allocator);
        self.order.deinit(self.allocator);
        self.arena.deinit();
    }

    fn add(self: *BatchAggregator, key: []const u8, sample_line: []const u8) !void {
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

    fn printAll(self: *BatchAggregator, filter_state: anytype) void {
        for (self.order.items) |key| {
            const count = self.counts.get(key).?;
            const line = self.sample_lines.get(key).?;

            if (count > 1) {
                var buf: [128]u8 = undefined;
                const prefix = std.fmt.bufPrint(&buf, "\x1b[2m[x{d}] \x1b[0m", .{count}) catch "[x?] ";
                std.fs.File.stdout().writeAll(prefix) catch {};
            }

            filter_state.printIfMatch(line);
        }
    }
};

/// Returns true if `path` has a `.gz` extension.
pub fn isGzip(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".gz");
}

/// Streaming gzip reader for line-oriented log processing.
///
/// `filter_state` must provide:
/// - `pub fn printIfMatch(self: *@This(), line: []const u8) void`
/// - `pub fn checkLine(self: *@This(), line: []const u8) ?T`
///
/// Pagination is not supported at this layer. Gzip streams are not randomly
/// seekable, so the file is always processed sequentially.
///
/// If `args.aggregate` is true, `key_builder` must be provided.
pub fn readGzip(
    allocator: std.mem.Allocator,
    path: []const u8,
    args: flags.Args,
    filter_state: anytype,
    key_builder: ?AggregateKeyBuilder,
) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var file_buf: [4096]u8 = undefined;
    var file_reader = file.reader(&file_buf);

    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(
        &file_reader.interface,
        .gzip,
        &decompress_buf,
    );
    const decompress_reader = &decompress.reader;

    var carry = try std.ArrayList(u8).initCapacity(allocator, 4096);
    defer carry.deinit(allocator);

    var aggregator: ?BatchAggregator = null;
    defer if (aggregator) |*agg| agg.deinit();

    if (args.aggregate) {
        if (key_builder == null) return GzipReadError.MissingAggregateKeyBuilder;
        aggregator = try BatchAggregator.init(allocator);
    }

    const agg_ptr: ?*BatchAggregator = if (aggregator) |*agg| agg else null;

    const chunk_size = 64 * 1024;
    const chunk = try allocator.alloc(u8, chunk_size);
    defer allocator.free(chunk);

    while (true) {
        const n = try decompress_reader.readSliceShort(chunk);
        if (n == 0) break;

        try processChunk(
            allocator,
            &carry,
            chunk[0..n],
            args,
            filter_state,
            agg_ptr,
            key_builder,
        );
    }

    try flushFinalCarry(
        allocator,
        &carry,
        args,
        filter_state,
        agg_ptr,
        key_builder,
    );

    if (aggregator) |*agg| {
        agg.printAll(filter_state);
    }
}

/// Processes one decompressed chunk and emits complete lines to `filter_state`
/// or accumulates them into `aggregator` when aggregation is enabled.
fn processChunk(
    allocator: std.mem.Allocator,
    carry: *std.ArrayList(u8),
    chunk: []const u8,
    args: flags.Args,
    filter_state: anytype,
    aggregator: ?*BatchAggregator,
    key_builder: ?AggregateKeyBuilder,
) !void {
    if (chunk.len == 0) return;

    // Fast path: no carry from the previous chunk.
    if (carry.items.len == 0) {
        var start: usize = 0;

        while (simd.findByte(chunk, start, '\n')) |nl| {
            try processLine(
                allocator,
                chunk[start..nl],
                args,
                filter_state,
                aggregator,
                key_builder,
            );
            start = nl + 1;
        }

        if (start < chunk.len) {
            try carry.appendSlice(allocator, chunk[start..]);
            try ensureCarryWithinLimit(carry.items.len);
        }

        return;
    }

    // Slow path: append the new chunk to the carry buffer and scan in-place.
    try carry.appendSlice(allocator, chunk);
    try ensureCarryWithinLimit(carry.items.len);

    var start: usize = 0;

    while (simd.findByte(carry.items, start, '\n')) |nl| {
        try processLine(
            allocator,
            carry.items[start..nl],
            args,
            filter_state,
            aggregator,
            key_builder,
        );
        start = nl + 1;
    }

    if (start == 0) return;

    if (start < carry.items.len) {
        const rest = carry.items[start..];
        std.mem.copyForwards(u8, carry.items[0..rest.len], rest);
        carry.items.len = rest.len;
    } else {
        carry.clearRetainingCapacity();
    }
}

/// Flushes the final unterminated line left in `carry`.
fn flushFinalCarry(
    allocator: std.mem.Allocator,
    carry: *std.ArrayList(u8),
    args: flags.Args,
    filter_state: anytype,
    aggregator: ?*BatchAggregator,
    key_builder: ?AggregateKeyBuilder,
) !void {
    if (carry.items.len == 0) return;

    try processLine(
        allocator,
        carry.items,
        args,
        filter_state,
        aggregator,
        key_builder,
    );
}

/// Processes one logical line either directly or through the batch aggregator.
fn processLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    args: flags.Args,
    filter_state: anytype,
    aggregator: ?*BatchAggregator,
    key_builder: ?AggregateKeyBuilder,
) !void {
    if (!args.aggregate) {
        filter_state.printIfMatch(line);
        return;
    }

    if (filter_state.checkLine(line) != null) {
        const builder = key_builder orelse return GzipReadError.MissingAggregateKeyBuilder;
        const agg = aggregator orelse return GzipReadError.MissingAggregator;

        const key = try builder(allocator, args.aggregate_mode, line);
        defer allocator.free(key);

        try agg.add(key, line);
    }
}

/// Fails if the carry buffer exceeds the configured maximum line length.
inline fn ensureCarryWithinLimit(len: usize) GzipReadError!void {
    if (len > MaxLineLen) return GzipReadError.LineTooLong;
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

/// Test sink that records all printed lines and matches every line by default.
const CollectingFilterState = struct {
    allocator: std.mem.Allocator,
    printed_lines: std.ArrayList([]const u8),
    should_match: bool = true,

    fn init(allocator: std.mem.Allocator) !CollectingFilterState {
        return .{
            .allocator = allocator,
            .printed_lines = try std.ArrayList([]const u8).initCapacity(allocator, 8),
        };
    }

    fn deinit(self: *CollectingFilterState) void {
        for (self.printed_lines.items) |line| {
            self.allocator.free(line);
        }
        self.printed_lines.deinit(self.allocator);
    }

    pub fn printIfMatch(self: *CollectingFilterState, line: []const u8) void {
        if (!self.should_match) return;
        const owned = self.allocator.dupe(u8, line) catch @panic("OutOfMemory");
        self.printed_lines.append(self.allocator, owned) catch @panic("OutOfMemory");
    }

    pub fn checkLine(self: *CollectingFilterState, line: []const u8) ?u8 {
        _ = line;
        if (self.should_match) return 1;
        return null;
    }
};

fn makeArgs(
    aggregate: bool,
    mode: flags.AggregateMode,
) flags.Args {
    return .{
        .files = &.{},
        .search = null,
        .levels = null,
        .date = null,
        .tail_mode = false,
        .help = false,
        .version = false,
        .num_lines = 0,
        .aggregate = aggregate,
        .aggregate_mode = mode,
    };
}

fn testKeyBuilder(
    allocator: std.mem.Allocator,
    mode: flags.AggregateMode,
    line: []const u8,
) ![]u8 {
    return switch (mode) {
        .exact => allocator.dupe(u8, line),
        .normalized => allocator.dupe(u8, "normalized"),
        .level_message => allocator.dupe(u8, "level-message"),
        .json_message => allocator.dupe(u8, "json-message"),
    };
}

test "isGzip: detects .gz extension" {
    try testing.expect(isGzip("app.log.gz"));
    try testing.expect(isGzip("/var/log/app.gz"));
    try testing.expect(!isGzip("app.log"));
    try testing.expect(!isGzip("gz"));
    try testing.expect(!isGzip(""));
}

test "processChunk: emits complete lines without carry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var carry = try std.ArrayList(u8).initCapacity(arena.allocator(), 16);
    defer carry.deinit(arena.allocator());

    var sink = try CollectingFilterState.init(testing.allocator);
    defer sink.deinit();

    try processChunk(
        arena.allocator(),
        &carry,
        "one\ntwo\nthree\n",
        makeArgs(false, .exact),
        &sink,
        null,
        null,
    );

    try testing.expectEqual(@as(usize, 3), sink.printed_lines.items.len);
    try testing.expectEqualStrings("one", sink.printed_lines.items[0]);
    try testing.expectEqualStrings("two", sink.printed_lines.items[1]);
    try testing.expectEqualStrings("three", sink.printed_lines.items[2]);
    try testing.expectEqual(@as(usize, 0), carry.items.len);
}

test "processChunk: stores incomplete trailing line in carry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var carry = try std.ArrayList(u8).initCapacity(arena.allocator(), 16);
    defer carry.deinit(arena.allocator());

    var sink = try CollectingFilterState.init(testing.allocator);
    defer sink.deinit();

    try processChunk(
        arena.allocator(),
        &carry,
        "one\ntwo\nthree",
        makeArgs(false, .exact),
        &sink,
        null,
        null,
    );

    try testing.expectEqual(@as(usize, 2), sink.printed_lines.items.len);
    try testing.expectEqualStrings("one", sink.printed_lines.items[0]);
    try testing.expectEqualStrings("two", sink.printed_lines.items[1]);
    try testing.expectEqualStrings("three", carry.items);
}

test "processChunk: joins carry with next chunk without extra logical line breaks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var carry = try std.ArrayList(u8).initCapacity(arena.allocator(), 16);
    defer carry.deinit(arena.allocator());

    var sink = try CollectingFilterState.init(testing.allocator);
    defer sink.deinit();

    try processChunk(
        arena.allocator(),
        &carry,
        "hello ",
        makeArgs(false, .exact),
        &sink,
        null,
        null,
    );
    try testing.expectEqual(@as(usize, 0), sink.printed_lines.items.len);
    try testing.expectEqualStrings("hello ", carry.items);

    try processChunk(
        arena.allocator(),
        &carry,
        "world\nnext\npar",
        makeArgs(false, .exact),
        &sink,
        null,
        null,
    );

    try testing.expectEqual(@as(usize, 2), sink.printed_lines.items.len);
    try testing.expectEqualStrings("hello world", sink.printed_lines.items[0]);
    try testing.expectEqualStrings("next", sink.printed_lines.items[1]);
    try testing.expectEqualStrings("par", carry.items);
}

test "processChunk: supports empty lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var carry = try std.ArrayList(u8).initCapacity(arena.allocator(), 16);
    defer carry.deinit(arena.allocator());

    var sink = try CollectingFilterState.init(testing.allocator);
    defer sink.deinit();

    try processChunk(
        arena.allocator(),
        &carry,
        "\n\nx\n",
        makeArgs(false, .exact),
        &sink,
        null,
        null,
    );

    try testing.expectEqual(@as(usize, 3), sink.printed_lines.items.len);
    try testing.expectEqualStrings("", sink.printed_lines.items[0]);
    try testing.expectEqualStrings("", sink.printed_lines.items[1]);
    try testing.expectEqualStrings("x", sink.printed_lines.items[2]);
}

test "processChunk: handles multiple chunks with repeated carry compaction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var carry = try std.ArrayList(u8).initCapacity(arena.allocator(), 16);
    defer carry.deinit(arena.allocator());

    var sink = try CollectingFilterState.init(testing.allocator);
    defer sink.deinit();

    try processChunk(
        arena.allocator(),
        &carry,
        "aa",
        makeArgs(false, .exact),
        &sink,
        null,
        null,
    );
    try processChunk(
        arena.allocator(),
        &carry,
        "bb\ncc",
        makeArgs(false, .exact),
        &sink,
        null,
        null,
    );
    try processChunk(
        arena.allocator(),
        &carry,
        "dd\nee\n",
        makeArgs(false, .exact),
        &sink,
        null,
        null,
    );

    try testing.expectEqual(@as(usize, 3), sink.printed_lines.items.len);
    try testing.expectEqualStrings("aabb", sink.printed_lines.items[0]);
    try testing.expectEqualStrings("ccdd", sink.printed_lines.items[1]);
    try testing.expectEqualStrings("ee", sink.printed_lines.items[2]);
    try testing.expectEqual(@as(usize, 0), carry.items.len);
}

test "processChunk: empty chunk is ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var carry = try std.ArrayList(u8).initCapacity(arena.allocator(), 16);
    defer carry.deinit(arena.allocator());

    var sink = try CollectingFilterState.init(testing.allocator);
    defer sink.deinit();

    try processChunk(
        arena.allocator(),
        &carry,
        "",
        makeArgs(false, .exact),
        &sink,
        null,
        null,
    );

    try testing.expectEqual(@as(usize, 0), sink.printed_lines.items.len);
    try testing.expectEqual(@as(usize, 0), carry.items.len);
}

test "ensureCarryWithinLimit: accepts values at or below limit" {
    try ensureCarryWithinLimit(0);
    try ensureCarryWithinLimit(1);
    try ensureCarryWithinLimit(MaxLineLen);
}

test "ensureCarryWithinLimit: rejects values above limit" {
    try testing.expectError(GzipReadError.LineTooLong, ensureCarryWithinLimit(MaxLineLen + 1));
}

test "processChunk: aggregate exact groups identical lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var carry = try std.ArrayList(u8).initCapacity(allocator, 16);
    defer carry.deinit(allocator);

    var sink = try CollectingFilterState.init(testing.allocator);
    defer sink.deinit();

    var agg = try BatchAggregator.init(allocator);
    defer agg.deinit();

    const agg_ptr: ?*BatchAggregator = &agg;

    try processChunk(
        allocator,
        &carry,
        "same\nsame\nother\n",
        makeArgs(true, .exact),
        &sink,
        agg_ptr,
        testKeyBuilder,
    );

    try testing.expectEqual(@as(usize, 2), agg.order.items.len);
    try testing.expectEqual(@as(usize, 2), agg.counts.get("same").?);
    try testing.expectEqual(@as(usize, 1), agg.counts.get("other").?);
    try testing.expectEqual(@as(usize, 0), sink.printed_lines.items.len);
}

test "processChunk: aggregate normalized uses aggregate mode for keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var carry = try std.ArrayList(u8).initCapacity(allocator, 16);
    defer carry.deinit(allocator);

    var sink = try CollectingFilterState.init(testing.allocator);
    defer sink.deinit();

    var agg = try BatchAggregator.init(allocator);
    defer agg.deinit();

    const agg_ptr: ?*BatchAggregator = &agg;

    try processChunk(
        allocator,
        &carry,
        "first\nsecond\n",
        makeArgs(true, .normalized),
        &sink,
        agg_ptr,
        testKeyBuilder,
    );

    try testing.expectEqual(@as(usize, 1), agg.order.items.len);
    try testing.expectEqual(@as(usize, 2), agg.counts.get("normalized").?);
}

test "flushFinalCarry: aggregate final unterminated line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var carry = try std.ArrayList(u8).initCapacity(allocator, 16);
    defer carry.deinit(allocator);
    try carry.appendSlice(allocator, "tail-line");

    var sink = try CollectingFilterState.init(testing.allocator);
    defer sink.deinit();

    var agg = try BatchAggregator.init(allocator);
    defer agg.deinit();

    try flushFinalCarry(
        allocator,
        &carry,
        makeArgs(true, .exact),
        &sink,
        &agg,
        testKeyBuilder,
    );

    try testing.expectEqual(@as(usize, 1), agg.order.items.len);
    try testing.expectEqual(@as(usize, 1), agg.counts.get("tail-line").?);
}

test "processLine: aggregate requires key builder" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sink = try CollectingFilterState.init(testing.allocator);
    defer sink.deinit();

    var agg = try BatchAggregator.init(allocator);
    defer agg.deinit();

    try testing.expectError(
        GzipReadError.MissingAggregateKeyBuilder,
        processLine(
            allocator,
            "x",
            makeArgs(true, .exact),
            &sink,
            &agg,
            null,
        ),
    );
}
