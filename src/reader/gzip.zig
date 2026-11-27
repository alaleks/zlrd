//! Streaming gzip decompressor for line-oriented log reading.
//! Wraps `std.compress.flate.Decompress` and feeds decompressed lines into
//! the same filter/print pipeline as regular files.

const std = @import("std");
const flags = @import("flags");
const simd = @import("simd");

const debug_io = std.Options.debug_io;

/// Upper bound for a single logical line kept in memory while waiting for `\n`.
/// Protects against corrupted input or unexpectedly huge records.
pub const MaxLineLen = 4 * 1024 * 1024;

/// Callback used to build aggregation keys without importing reader/formats
/// code here. Returns a borrowed slice — either into `line` or into
/// `scratch`. Do not free the return value.
pub const AggregateKeyBuilder = *const fn (
    allocator: std.mem.Allocator,
    scratch: *std.ArrayList(u8),
    mode: flags.AggregateMode,
    line: []const u8,
) anyerror![]const u8;

/// Per-key state kept by `BatchAggregator`. Mirrors `reader.AggregateEntry`
/// but is kept local so gzip.zig stays leaf (no import cycle with reader).
const Entry = struct {
    count: usize,
    sample_line: []const u8,
};

/// Upper bound for distinct aggregation keys retained across one gzip scan.
/// Matches `reader.max_aggregate_keys` so `-a` cannot OOM on high-cardinality archives.
pub const max_aggregate_keys: usize = 100_000;

/// Errors specific to gzip line streaming.
pub const GzipReadError = error{
    LineTooLong,
    MissingAggregateKeyBuilder,
    MissingAggregator,
    WrongGzipChecksum,
    WrongGzipSize,
    TruncatedStream,
};

/// One aggregated output entry kept for the current gzip read.
const BatchAggregator = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    entries: std.StringHashMapUnmanaged(Entry),
    order: std.ArrayList([]const u8),
    /// Reused per-line scratch space for building non-.exact keys.
    key_scratch: std.ArrayList(u8),

    fn init(allocator: std.mem.Allocator) !BatchAggregator {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .entries = .{},
            .order = try std.ArrayList([]const u8).initCapacity(allocator, 32),
            .key_scratch = .empty,
        };
    }

    fn deinit(self: *BatchAggregator) void {
        self.entries.deinit(self.allocator);
        self.order.deinit(self.allocator);
        self.key_scratch.deinit(self.allocator);
        self.arena.deinit();
    }

    fn add(self: *BatchAggregator, key: []const u8, sample_line: []const u8) !void {
        if (self.entries.getPtr(key)) |entry| {
            entry.count += 1;
            return;
        }
        if (self.entries.count() >= max_aggregate_keys) return;

        // Reserve capacity before spending arena bytes so an OOM in the
        // hash-map put can't leak the key/line dupes.
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        try self.order.ensureUnusedCapacity(self.allocator, 1);

        const owned_line = try self.arena.allocator().dupe(u8, sample_line);
        const owned_key = if (key.ptr == sample_line.ptr and key.len == sample_line.len)
            owned_line
        else
            try self.arena.allocator().dupe(u8, key);

        self.entries.putAssumeCapacityNoClobber(owned_key, .{
            .count = 1,
            .sample_line = owned_line,
        });
        self.order.appendAssumeCapacity(owned_key);
    }

    fn printAll(self: *BatchAggregator, filter_state: anytype) void {
        for (self.order.items) |key| {
            if (outBroken(filter_state)) break;
            const entry = self.entries.get(key).?;

            if (entry.count > 1 and !outputJsonEnabled(filter_state)) {
                writeCountPrefix(filter_state, entry.count);
            }

            filter_state.printIfMatch(entry.sample_line);
        }
    }
};

fn outBroken(filter_state: anytype) bool {
    const Child = @typeInfo(@TypeOf(filter_state)).pointer.child;
    if (comptime @hasField(Child, "out")) {
        if (filter_state.out) |o| return o.broken;
    }
    return false;
}

fn writeCountPrefix(filter_state: anytype, count: usize) void {
    const Child = @typeInfo(@TypeOf(filter_state)).pointer.child;
    if (comptime @hasField(Child, "out")) {
        if (filter_state.out) |o| {
            o.write(o.theme.palette.dim);
            o.print("[x{d}] ", .{count});
            o.write(o.theme.palette.reset);
        }
    }
}

fn recordLevel(filter_state: anytype, checked: anytype) void {
    const Child = @typeInfo(@TypeOf(filter_state)).pointer.child;
    const CheckedT = @TypeOf(checked);
    if (comptime @hasField(Child, "counter") and @typeInfo(CheckedT) == .@"struct" and @hasField(CheckedT, "info")) {
        if (filter_state.counter) |counter| {
            if (checked.info.level) |lvl| counter.add(lvl);
        }
    }
}

fn outputJsonEnabled(filter_state: anytype) bool {
    const T = @TypeOf(filter_state);
    if (@typeInfo(T) == .pointer) {
        const Child = @typeInfo(T).pointer.child;
        if (@hasField(Child, "output_json")) return filter_state.output_json;
    } else if (@hasField(T, "output_json")) {
        return filter_state.output_json;
    }
    return false;
}

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
    const file = try std.Io.Dir.cwd().openFile(debug_io, path, .{});
    defer file.close(debug_io);

    var file_buf: [4096]u8 = undefined;
    var file_reader = file.reader(debug_io, &file_buf);

    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;

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

    // Loop over RFC 1952 concatenated gzip members until true underlying EOF.
    while (true) {
        var decompress: std.compress.flate.Decompress = .init(
            &file_reader.interface,
            .gzip,
            &decompress_buf,
        );
        const decompress_reader = &decompress.reader;
        var hasher = std.compress.flate.Container.Hasher.init(.gzip);

        while (true) {
            if (outBroken(filter_state)) return;
            const n = decompress_reader.readSliceShort(chunk) catch |err| switch (err) {
                error.ReadFailed => {
                    if (decompress.err) |derr| {
                        if (derr == error.EndOfStream) return GzipReadError.TruncatedStream;
                        return derr;
                    }
                    if (file_reader.err) |ferr| return ferr;
                    return GzipReadError.TruncatedStream;
                },
            };
            if (n == 0) break;
            hasher.update(chunk[0..n]);

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

        if (decompress.err) |err| return err;
        if (decompress.state != .end) return GzipReadError.TruncatedStream;
        if (hasher.gzip.crc.final() != decompress.container_metadata.gzip.crc) {
            return GzipReadError.WrongGzipChecksum;
        }
        if (hasher.gzip.count != decompress.container_metadata.gzip.count) {
            return GzipReadError.WrongGzipSize;
        }

        // Check whether another concatenated gzip member follows.
        _ = file_reader.interface.peekByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
    }

    if (outBroken(filter_state)) return;

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
    chunk_in: []const u8,
    args: flags.Args,
    filter_state: anytype,
    aggregator: ?*BatchAggregator,
    key_builder: ?AggregateKeyBuilder,
) !void {
    if (chunk_in.len == 0) return;
    var chunk = chunk_in;

    // A line left over from the previous chunk is finished by this chunk's
    // first newline, and only that much is copied onto it. Appending the
    // whole chunk, as this used to, copied nearly every decompressed byte a
    // second time: the last line of a chunk almost never ends on its edge.
    if (carry.items.len > 0) {
        const nl = simd.findByte(chunk, 0, '\n') orelse {
            try carry.appendSlice(allocator, chunk);
            try ensureCarryWithinLimit(carry.items.len);
            return;
        };
        try carry.appendSlice(allocator, chunk[0..nl]);
        try ensureCarryWithinLimit(carry.items.len);
        beginChunk(filter_state, carry.items);
        try processLine(allocator, carry.items, args, filter_state, aggregator, key_builder);
        carry.clearRetainingCapacity();
        chunk = chunk[nl + 1 ..];
    }

    beginChunk(filter_state, chunk);
    var start: usize = 0;
    while (simd.findByte(chunk, start, '\n')) |nl| {
        try processLine(allocator, chunk[start..nl], args, filter_state, aggregator, key_builder);
        start = nl + 1;
    }
    if (start < chunk.len) {
        try carry.appendSlice(allocator, chunk[start..]);
        try ensureCarryWithinLimit(carry.items.len);
    }
}

/// Lets the filter hoist its per-chunk checks (the literal-ANSI scan) out of
/// the per-line path, as the plain-file reader does. The test sink has no
/// such hook.
fn beginChunk(filter_state: anytype, bytes: []const u8) void {
    if (@hasDecl(@TypeOf(filter_state.*), "beginChunk")) filter_state.beginChunk(bytes);
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
        const Child = @typeInfo(@TypeOf(filter_state)).pointer.child;
        if (comptime @hasDecl(Child, "printChecked")) {
            if (filter_state.checkLine(line)) |ck| {
                recordLevel(filter_state, ck);
                filter_state.printChecked(ck.line, ck.info);
            }
        } else {
            filter_state.printIfMatch(line);
        }
        return;
    }

    _ = allocator;
    if (filter_state.checkLine(line)) |result| {
        recordLevel(filter_state, result);
        const builder = key_builder orelse return GzipReadError.MissingAggregateKeyBuilder;
        const agg = aggregator orelse return GzipReadError.MissingAggregator;

        // The real reader.FilterState returns `CheckedLine { line, info }` so
        // aggregation keys and stored samples see the ANSI-stripped bytes.
        // The unit-test sink below returns a scalar sentinel — fall back to
        // the raw line for it (its callers never inspect the strip).
        const T = @TypeOf(result);
        const effective_line = if (comptime @typeInfo(T) == .@"struct" and @hasField(T, "line")) result.line else line;
        const key = try builder(agg.allocator, &agg.key_scratch, args.aggregate_mode, effective_line);
        try agg.add(key, effective_line);
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
    scratch: *std.ArrayList(u8),
    mode: flags.AggregateMode,
    line: []const u8,
) ![]const u8 {
    return switch (mode) {
        .exact => line,
        .normalized => blk: {
            scratch.clearRetainingCapacity();
            try scratch.appendSlice(allocator, "normalized");
            break :blk scratch.items;
        },
        .level_message => blk: {
            scratch.clearRetainingCapacity();
            try scratch.appendSlice(allocator, "level-message");
            break :blk scratch.items;
        },
        .json_message => blk: {
            scratch.clearRetainingCapacity();
            try scratch.appendSlice(allocator, "json-message");
            break :blk scratch.items;
        },
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
    try testing.expectEqual(@as(usize, 2), agg.entries.get("same").?.count);
    try testing.expectEqual(@as(usize, 1), agg.entries.get("other").?.count);
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
    try testing.expectEqual(@as(usize, 2), agg.entries.get("normalized").?.count);
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
    try testing.expectEqual(@as(usize, 1), agg.entries.get("tail-line").?.count);
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

test "flushFinalCarry: non-aggregate mode prints line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var carry = try std.ArrayList(u8).initCapacity(allocator, 16);
    defer carry.deinit(allocator);
    try carry.appendSlice(allocator, "unterminated");

    var sink = try CollectingFilterState.init(testing.allocator);
    defer sink.deinit();

    try flushFinalCarry(
        allocator,
        &carry,
        makeArgs(false, .exact),
        &sink,
        null,
        null,
    );

    try testing.expectEqual(@as(usize, 1), sink.printed_lines.items.len);
    try testing.expectEqualStrings("unterminated", sink.printed_lines.items[0]);
}

test "flushFinalCarry: empty carry is no-op" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var carry: std.ArrayList(u8) = .empty;
    defer carry.deinit(allocator);

    var sink = try CollectingFilterState.init(testing.allocator);
    defer sink.deinit();

    try flushFinalCarry(
        allocator,
        &carry,
        makeArgs(false, .exact),
        &sink,
        null,
        null,
    );

    try testing.expectEqual(@as(usize, 0), sink.printed_lines.items.len);
}

test "processChunk: filter that rejects lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var carry = try std.ArrayList(u8).initCapacity(arena.allocator(), 16);
    defer carry.deinit(arena.allocator());

    var sink = try CollectingFilterState.init(testing.allocator);
    defer sink.deinit();
    sink.should_match = false;

    try processChunk(
        arena.allocator(),
        &carry,
        "line1\nline2\n",
        makeArgs(false, .exact),
        &sink,
        null,
        null,
    );

    try testing.expectEqual(@as(usize, 0), sink.printed_lines.items.len);
    try testing.expectEqual(@as(usize, 0), carry.items.len);
}

test "processChunk: filter rejection with carry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var carry = try std.ArrayList(u8).initCapacity(allocator, 16);
    defer carry.deinit(allocator);

    var sink = try CollectingFilterState.init(testing.allocator);
    defer sink.deinit();
    sink.should_match = false;

    // Rejected lines still consume the carry correctly
    try processChunk(
        allocator,
        &carry,
        "line1\nline2",
        makeArgs(false, .exact),
        &sink,
        null,
        null,
    );

    try testing.expectEqual(@as(usize, 0), sink.printed_lines.items.len);
    try testing.expectEqualStrings("line2", carry.items);
}

test "processLine: aggregate mode with key builder" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sink = try CollectingFilterState.init(testing.allocator);
    defer sink.deinit();

    var agg = try BatchAggregator.init(allocator);
    defer agg.deinit();

    try processLine(
        allocator,
        "hello",
        makeArgs(true, .exact),
        &sink,
        &agg,
        testKeyBuilder,
    );

    try testing.expectEqual(@as(usize, 1), agg.order.items.len);
    try testing.expectEqualStrings("hello", agg.entries.get("hello").?.sample_line);
}

test "processLine: aggregate requires aggregator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sink = try CollectingFilterState.init(testing.allocator);
    defer sink.deinit();

    try testing.expectError(
        GzipReadError.MissingAggregator,
        processLine(
            allocator,
            "x",
            makeArgs(true, .exact),
            &sink,
            null,
            testKeyBuilder,
        ),
    );
}

test "processLine: non-aggregate prints line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var sink = try CollectingFilterState.init(testing.allocator);
    defer sink.deinit();

    try processLine(
        allocator,
        "hello world",
        makeArgs(false, .exact),
        &sink,
        null,
        null,
    );

    try testing.expectEqual(@as(usize, 1), sink.printed_lines.items.len);
    try testing.expectEqualStrings("hello world", sink.printed_lines.items[0]);
}

test "processChunk: carry near MaxLineLen is accepted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var carry = try std.ArrayList(u8).initCapacity(allocator, MaxLineLen);
    defer carry.deinit(allocator);

    var sink = try CollectingFilterState.init(testing.allocator);
    defer sink.deinit();

    // Fill carry near the limit, then add a tiny chunk.
    // Use a smaller representative size to keep the test fast.
    const fill_size = 64 * 1024;
    const big = try allocator.alloc(u8, fill_size);
    defer allocator.free(big);
    @memset(big, 'x');
    try carry.appendSlice(allocator, big);

    try processChunk(
        allocator,
        &carry,
        "y",
        makeArgs(false, .exact),
        &sink,
        null,
        null,
    );

    try testing.expectEqual(@as(usize, fill_size + 1), carry.items.len);
}

test "processChunk: slow path carry compaction after partial consumption" {
    // When carry has data and a chunk with newlines is appended,
    // consumed lines are removed and remainder is compacted to the front.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var carry = try std.ArrayList(u8).initCapacity(allocator, 64);
    defer carry.deinit(allocator);
    try carry.appendSlice(allocator, "old");

    var sink = try CollectingFilterState.init(testing.allocator);
    defer sink.deinit();

    try processChunk(
        allocator,
        &carry,
        "line\nnew-tail",
        makeArgs(false, .exact),
        &sink,
        null,
        null,
    );

    try testing.expectEqual(@as(usize, 1), sink.printed_lines.items.len);
    try testing.expectEqualStrings("oldline", sink.printed_lines.items[0]);
    try testing.expectEqualStrings("new-tail", carry.items);
}

test "BatchAggregator.printAll delegates to filter_state" {
    // Use unique keys to avoid stdout output from the count > 1 prefix.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var agg = try BatchAggregator.init(allocator);
    defer agg.deinit();

    try agg.add("key-a", "line-a");
    try agg.add("key-b", "line-b");

    var sink = try CollectingFilterState.init(testing.allocator);
    defer sink.deinit();

    agg.printAll(&sink);

    try testing.expectEqual(@as(usize, 2), sink.printed_lines.items.len);
    try testing.expectEqualStrings("line-a", sink.printed_lines.items[0]);
    try testing.expectEqualStrings("line-b", sink.printed_lines.items[1]);
}

test "BatchAggregator deinit after no additions is safe" {
    var agg = try BatchAggregator.init(testing.allocator);
    agg.deinit();
}

test "processChunk: a line split across chunks is joined, the rest stays in place" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var carry: std.ArrayList(u8) = .empty;
    var sink = try CollectingFilterState.init(testing.allocator);
    defer sink.deinit();

    try processChunk(allocator, &carry, "first\npar", makeArgs(false, .exact), &sink, null, null);
    try processChunk(allocator, &carry, "tial\nnext\nrem", makeArgs(false, .exact), &sink, null, null);
    try processChunk(allocator, &carry, "ain", makeArgs(false, .exact), &sink, null, null);
    try flushFinalCarry(allocator, &carry, makeArgs(false, .exact), &sink, null, null);

    try testing.expectEqual(@as(usize, 4), sink.printed_lines.items.len);
    try testing.expectEqualStrings("first", sink.printed_lines.items[0]);
    try testing.expectEqualStrings("partial", sink.printed_lines.items[1]);
    try testing.expectEqualStrings("next", sink.printed_lines.items[2]);
    try testing.expectEqualStrings("remain", sink.printed_lines.items[3]);
}

/// Encodes `payload` (<= 65535 bytes) as a valid single-member RFC 1952 gzip
/// stream using a stored DEFLATE block.
fn appendStoredGzipMember(allocator: std.mem.Allocator, out: *std.ArrayList(u8), payload: []const u8) !void {
    try out.appendSlice(allocator, &.{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff });
    const len16: u16 = @intCast(payload.len);
    const nlen16: u16 = ~len16;
    try out.append(allocator, 0x01); // BFINAL=1, BTYPE=00 (stored)
    var le: [2]u8 = undefined;
    std.mem.writeInt(u16, &le, len16, .little);
    try out.appendSlice(allocator, &le);
    std.mem.writeInt(u16, &le, nlen16, .little);
    try out.appendSlice(allocator, &le);
    try out.appendSlice(allocator, payload);

    var crc = std.hash.Crc32.init();
    crc.update(payload);
    var trailer: [8]u8 = undefined;
    std.mem.writeInt(u32, trailer[0..4], crc.final(), .little);
    std.mem.writeInt(u32, trailer[4..8], @truncate(payload.len), .little);
    try out.appendSlice(allocator, &trailer);
}

test "readGzip reads concatenated multi-member gzip files completely" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var gz: std.ArrayList(u8) = .empty;
    defer gz.deinit(testing.allocator);
    try appendStoredGzipMember(testing.allocator, &gz, "member1-line1\nmember1-part");
    try appendStoredGzipMember(testing.allocator, &gz, "-joined\nmember2-line2\n");

    try tmp.dir.writeFile(debug_io, .{ .sub_path = "multi.log.gz", .data = gz.items });
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/multi.log.gz", .{tmp.sub_path});

    var sink = try CollectingFilterState.init(testing.allocator);
    defer sink.deinit();

    try readGzip(testing.allocator, path, makeArgs(false, .exact), &sink, null);
    try testing.expectEqual(@as(usize, 3), sink.printed_lines.items.len);
    try testing.expectEqualStrings("member1-line1", sink.printed_lines.items[0]);
    try testing.expectEqualStrings("member1-part-joined", sink.printed_lines.items[1]);
    try testing.expectEqualStrings("member2-line2", sink.printed_lines.items[2]);
}

test "readGzip rejects corrupted CRC32, wrong ISIZE, and truncated streams" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var gz: std.ArrayList(u8) = .empty;
    defer gz.deinit(testing.allocator);
    try appendStoredGzipMember(testing.allocator, &gz, "hello world\n");

    var path_buf: [128]u8 = undefined;

    // Flip a bit in CRC32 (last 8..-4 bytes).
    var bad_crc = try testing.allocator.dupe(u8, gz.items);
    defer testing.allocator.free(bad_crc);
    bad_crc[bad_crc.len - 8] ^= 0x01;
    try tmp.dir.writeFile(debug_io, .{ .sub_path = "bad_crc.gz", .data = bad_crc });
    const p1 = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/bad_crc.gz", .{tmp.sub_path});
    var s1 = try CollectingFilterState.init(testing.allocator);
    defer s1.deinit();
    try testing.expectError(GzipReadError.WrongGzipChecksum, readGzip(testing.allocator, p1, makeArgs(false, .exact), &s1, null));

    // Flip a bit in ISIZE (last 4 bytes).
    var bad_sz = try testing.allocator.dupe(u8, gz.items);
    defer testing.allocator.free(bad_sz);
    bad_sz[bad_sz.len - 1] ^= 0x01;
    try tmp.dir.writeFile(debug_io, .{ .sub_path = "bad_sz.gz", .data = bad_sz });
    const p2 = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/bad_sz.gz", .{tmp.sub_path});
    var s2 = try CollectingFilterState.init(testing.allocator);
    defer s2.deinit();
    try testing.expectError(GzipReadError.WrongGzipSize, readGzip(testing.allocator, p2, makeArgs(false, .exact), &s2, null));

    // Truncate before the footer finishes.
    try tmp.dir.writeFile(debug_io, .{ .sub_path = "trunc.gz", .data = gz.items[0 .. gz.items.len - 4] });
    const p3 = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/trunc.gz", .{tmp.sub_path});
    var s3 = try CollectingFilterState.init(testing.allocator);
    defer s3.deinit();
    try testing.expectError(GzipReadError.TruncatedStream, readGzip(testing.allocator, p3, makeArgs(false, .exact), &s3, null));
}
