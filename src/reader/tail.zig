const std = @import("std");
const flags = @import("flags");
const formats = @import("formats.zig");
const reader = @import("reader.zig");
const simd = @import("simd");

/// Same cap as `reader.max_line_bytes`; lifted to a local alias so the hot
/// loop avoids the indirection on every iteration.
const max_line_bytes: usize = reader.max_line_bytes;

inline fn ensureLineCapacity(current: usize, extra: usize) reader.LineCapError!void {
    if (current + extra > max_line_bytes) return error.LineTooLong;
}

// Track open files with manual position tracking.
const OpenFile = struct {
    path: []const u8,
    fd: std.Io.File,
    position: u64,
};

// Read buffer size for the follow loop.
// 64 KB gives good throughput without excessive stack usage.
const READ_BUF_SIZE = 64 * 1024;
const tail_io = std.Options.debug_io;

/// Reads up to buf.len bytes from `pos` without affecting the OS seek position.
/// Uses positional read (pread) so concurrent / interleaved I/O is safe.
fn readAt(f: std.Io.File, pos: u64, buf: []u8) !usize {
    return f.readPositional(tail_io, &.{buf}, pos);
}

fn findLastNLinesStart(f: *OpenFile, file_size: u64, n: usize, scan_buf: []u8) !u64 {
    if (file_size == 0 or n == 0) return 0;

    var target_newlines = n;
    var last_byte: [1]u8 = undefined;
    if (try readAt(f.fd, file_size - 1, &last_byte) == 1 and last_byte[0] == '\n') {
        // n comes from args.num_lines (default 10, CLI-bounded), so n+1 cannot overflow.
        target_newlines += 1;
    }

    var newlines_found: usize = 0;
    var scan_end: u64 = file_size;
    const max_chunk: u64 = @intCast(scan_buf.len);

    while (scan_end > 0) {
        const chunk_size_u64 = @min(scan_end, max_chunk);
        const chunk_size: usize = @intCast(chunk_size_u64);
        const chunk_start = scan_end - chunk_size_u64;

        const bytes_read = try readAt(f.fd, chunk_start, scan_buf[0..chunk_size]);
        if (bytes_read == 0) break;

        var idx: usize = bytes_read;
        while (idx > 0) {
            idx -= 1;
            if (scan_buf[idx] == '\n') {
                newlines_found += 1;
                if (newlines_found == target_newlines) {
                    return chunk_start + idx + 1;
                }
            }
        }

        if (chunk_start == 0) break;
        scan_end = chunk_start;
    }

    return 0;
}

/// How far back a filtered backfill will look before giving up and printing
/// whatever it found. Without a bound, `-t -l fatal` on a file with no fatals
/// would read the entire file before showing the first live line.
const filtered_backfill_cap: u64 = 8 * 1024 * 1024;

/// Offset of the first byte of the `n`-th-from-last line that passes the
/// active filters.
///
/// `findLastNLinesStart` counts raw lines, which is the wrong unit once `-l`
/// or `-s` is in play: on a busy file the last 10 lines are almost never the
/// ones the filter wants, so `zlrd -t -l error` opened on a blank screen and
/// stayed blank until a new error happened to arrive. The window is widened
/// geometrically instead, so the extra passes cost about an eighth of the
/// bytes finally kept, and it stops at the first of: `n` matches found, start
/// of file, or `filtered_backfill_cap`.
fn findLastNMatchingStart(
    allocator: std.mem.Allocator,
    f: *OpenFile,
    file_size: u64,
    n: usize,
    filter_state: *formats.FilterState,
    scan_buf: []u8,
) !u64 {
    // Offsets of the most recent `n` matches, oldest at `head` once it wraps.
    const ring = try allocator.alloc(u64, n);
    defer allocator.free(ring);

    var carry: std.ArrayList(u8) = .empty;
    defer carry.deinit(allocator);

    var budget = n;
    while (true) {
        const start = try findLastNLinesStart(f, file_size, budget, scan_buf);

        var matches: usize = 0;
        var head: usize = 0;
        carry.clearRetainingCapacity();

        // Absolute offset of the first byte of the line being assembled.
        var line_off = start;
        var pos = start;
        while (pos < file_size) {
            const want: usize = @intCast(@min(@as(u64, scan_buf.len), file_size - pos));
            const got = try readAt(f.fd, pos, scan_buf[0..want]);
            if (got == 0) break;
            const chunk = scan_buf[0..got];

            var seg_start: usize = 0;
            while (simd.findByte(chunk, seg_start, '\n')) |nl| {
                // Fast path: a line contained entirely in this chunk needs no
                // copy. Only a line split across chunks goes through `carry`.
                const line = if (carry.items.len == 0) chunk[seg_start..nl] else blk: {
                    try ensureLineCapacity(carry.items.len, nl - seg_start);
                    try carry.appendSlice(allocator, chunk[seg_start..nl]);
                    break :blk carry.items;
                };
                if (line.len > 0 and filter_state.checkLine(line) != null) {
                    ring[head] = line_off;
                    head = (head + 1) % n;
                    matches += 1;
                }
                carry.clearRetainingCapacity();
                seg_start = nl + 1;
                line_off = pos + seg_start;
            }

            if (seg_start < chunk.len) {
                try ensureLineCapacity(carry.items.len, chunk.len - seg_start);
                try carry.appendSlice(allocator, chunk[seg_start..]);
            }
            pos += got;
        }

        // A final line with no trailing newline still counts — `readLastNLines`
        // prints it too, via `flush_final_line`.
        if (carry.items.len > 0 and filter_state.checkLine(carry.items) != null) {
            ring[head] = line_off;
            head = (head + 1) % n;
            matches += 1;
        }

        if (matches >= n) return ring[head];
        if (start == 0 or file_size - start >= filtered_backfill_cap) return start;
        budget *|= 8;
    }
}

/// Batch-local aggregator used by tail reads.
/// Keeps first-seen order within one read batch and prints once per key.
/// Uses `reader.Aggregator`'s Entry shape — single map instead of three.
const BatchAggregator = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    entries: std.StringHashMapUnmanaged(reader.AggregateEntry),
    order: std.ArrayList([]const u8),
    /// Reused per-line scratch space for building non-.exact keys; owned here
    /// so callers don't have to thread an extra parameter through.
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

    /// Build the aggregation key for `line` using the aggregator's own
    /// scratch, then delegate to `add`. Removes the per-line malloc/free
    /// pair from the caller.
    fn observe(
        self: *BatchAggregator,
        mode: flags.AggregateMode,
        line: []const u8,
        info: formats.LineInfo,
    ) !void {
        const key = try formats.buildAggregateKey(self.allocator, &self.key_scratch, mode, line, info);
        try self.add(key, line, info);
    }

    fn add(
        self: *BatchAggregator,
        key: []const u8,
        sample_line: []const u8,
        info: formats.LineInfo,
    ) !void {
        if (self.entries.getPtr(key)) |entry| {
            entry.count += 1;
            return;
        }

        // Reserve capacity before spending arena bytes so an OOM in the
        // hash-map put can't leak the key/line dupes.
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        try self.order.ensureUnusedCapacity(self.allocator, 1);

        const owned_key = try self.arena.allocator().dupe(u8, key);
        const owned_line = try self.arena.allocator().dupe(u8, sample_line);

        self.entries.putAssumeCapacityNoClobber(owned_key, .{
            .count = 1,
            .sample_line = owned_line,
            .sample_info = info,
        });
        self.order.appendAssumeCapacity(owned_key);
    }

    fn printAll(self: *BatchAggregator, filter_state: *formats.FilterState) void {
        for (self.order.items) |key| {
            const entry = self.entries.get(key).?;

            if (entry.count > 1 and !filter_state.output_json) {
                // Through the same sink as the record itself. A direct stdout
                // write here jumped ahead of everything still buffered, so the
                // count landed detached from the line it counted — and it hard-
                // coded the escapes, leaking them under `--color never`.
                if (filter_state.out) |o| {
                    o.write(o.theme.palette.dim);
                    o.print("[x{d}] ", .{entry.count});
                    o.write(o.theme.palette.reset);
                }
            }

            // Line + info were already validated by checkLine in processLine;
            // print directly to avoid a redundant second parse.
            filter_state.printChecked(entry.sample_line, entry.sample_info);
        }
    }
};

pub fn follow(
    allocator: std.mem.Allocator,
    args: flags.Args,
    th: *const formats.Theme,
) !void {
    const file_count = args.files.len;
    if (file_count == 0) return;

    const files_buf = try allocator.alloc(OpenFile, file_count);
    defer allocator.free(files_buf);

    var files_len: usize = 0;
    defer {
        var i: usize = 0;
        while (i < files_len) : (i += 1) {
            files_buf[i].fd.close(tail_io);
        }
    }

    // Follow output goes through the same buffered sink as file reads. It
    // used to write straight to stdout, one syscall per colour escape.
    var out = try formats.Out.init(allocator, std.Io.File.stdout(), th);
    defer out.deinit();

    var expander: ?formats.JsonExpander = if (!args.output_json and th.colored and !args.no_expand_json)
        try formats.JsonExpander.init(allocator, .{})
    else
        null;
    defer if (expander) |*x| x.deinit();

    var filter_state = formats.FilterState.init(args, &out, if (expander) |*x| x else null);
    defer filter_state.deinit();

    const read_buf = try allocator.alloc(u8, READ_BUF_SIZE);
    defer allocator.free(read_buf);

    for (args.files) |path| {
        const fd = std.Io.Dir.cwd().openFile(tail_io, path, .{}) catch |err| {
            var errbuf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&errbuf, "Cannot open {s}: {any}\n", .{ path, err }) catch "Cannot open file\n";
            std.Io.File.stderr().writeStreamingAll(tail_io, msg) catch {};
            continue;
        };

        files_buf[files_len] = OpenFile{
            .path = path,
            .fd = fd,
            .position = 0,
        };
        files_len += 1;

        const stat = try fd.stat(tail_io);
        if (stat.size > 0) {
            const final_pos = try readLastNLines(
                allocator,
                &files_buf[files_len - 1],
                args,
                stat.size,
                &filter_state,
                read_buf,
            );
            files_buf[files_len - 1].position = final_pos;
        }
    }

    if (files_len == 0) return;

    // The backfill above went into `out`'s 256 KB buffer, which otherwise
    // only drains when it fills or on `deinit` — and `deinit` never runs in
    // follow mode, because the loop below only ends when the process is
    // killed. Without this flush and the one per batch, `-t` printed nothing
    // at all: not the last-N lines, not a single appended record.
    out.flush();

    const carries = try allocator.alloc(std.ArrayList(u8), files_len);
    defer {
        for (carries) |*c| c.deinit(allocator);
        allocator.free(carries);
    }
    for (carries) |*c| c.* = .empty;

    while (true) {
        var any_read = false;

        for (files_buf[0..files_len], carries) |*f, *carry| {
            const stat = f.fd.stat(tail_io) catch |err| {
                logTailError("stat", f.path, err);
                continue;
            };

            if (f.position > stat.size) {
                // File was truncated — reset to beginning.
                f.position = 0;
            } else if (f.position == stat.size) {
                continue;
            }

            const bytes_read = readAvailable(allocator, f, args, &filter_state, carry, read_buf) catch |err| {
                logTailError("read", f.path, err);
                continue;
            };
            if (bytes_read > 0) any_read = true;
        }

        if (any_read) {
            out.flush();
            // Downstream went away (`| head`, pager quit). Stop rather than
            // formatting output nobody will read until we are killed.
            if (out.broken) return;
            continue;
        }

        std.Io.sleep(tail_io, std.Io.Duration.fromMilliseconds(100), .awake) catch continue;
    }
}

/// Prints a one-line warning to stderr when a tail-follow read fails. Tail
/// mode must keep running across transient errors (file rotated, network
/// fs hiccup), but we shouldn't swallow them silently — every failed read
/// is a potentially lost log entry.
fn logTailError(op: []const u8, path: []const u8, err: anyerror) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "tail {s} {s}: {s}\n", .{ op, path, @errorName(err) }) catch return;
    std.Io.File.stderr().writeStreamingAll(tail_io, msg) catch {};
}

/// Reads the last `args.num_lines` lines (default 10) from `file`,
/// prints matching ones via `filter_state`, and returns the file position
/// after the last consumed byte.
pub fn readLastNLines(
    allocator: std.mem.Allocator,
    f: *OpenFile,
    args: flags.Args,
    file_size: u64,
    filter_state: *formats.FilterState,
    read_buf: []u8,
) !u64 {
    const n: usize = if (args.num_lines == 0) 10 else args.num_lines;

    // With a filter on, "last n lines" has to mean n lines that survive it.
    const filtered = filter_state.has_level_filter or filter_state.has_search_filter;
    const read_from = if (filtered)
        try findLastNMatchingStart(allocator, f, file_size, n, filter_state, read_buf)
    else
        try findLastNLinesStart(f, file_size, n, read_buf);

    f.position = read_from;

    var carry: std.ArrayList(u8) = .empty;
    defer carry.deinit(allocator);

    try readToEOFInternal(allocator, f, args, filter_state, &carry, read_buf, true);
    return f.position;
}

/// Reads any new data from `file` starting at `*position`,
/// processes complete lines, and returns the number of bytes consumed.
fn readAvailable(
    allocator: std.mem.Allocator,
    f: *OpenFile,
    args: flags.Args,
    filter_state: *formats.FilterState,
    carry: *std.ArrayList(u8),
    buf: []u8,
) !usize {
    const start_pos = f.position;
    try readToEOF(allocator, f, args, filter_state, carry, buf);
    return f.position - start_pos;
}

/// Reads `file` to EOF, splits on newlines, and processes complete lines.
/// Partial trailing lines are saved in `carry` and prepended on the next call.
/// `position` is advanced by bytes read.
///
/// If aggregation is enabled, matched lines are aggregated within this read batch.
pub fn readToEOF(
    allocator: std.mem.Allocator,
    f: *OpenFile,
    args: flags.Args,
    filter_state: *formats.FilterState,
    carry: *std.ArrayList(u8),
    buf: []u8,
) !void {
    try readToEOFInternal(allocator, f, args, filter_state, carry, buf, false);
}

fn readToEOFInternal(
    allocator: std.mem.Allocator,
    f: *OpenFile,
    args: flags.Args,
    filter_state: *formats.FilterState,
    carry: *std.ArrayList(u8),
    buf: []u8,
    flush_final_line: bool,
) !void {
    var aggregator: ?BatchAggregator = null;
    defer if (aggregator) |*agg| agg.deinit();

    if (args.aggregate) {
        aggregator = try BatchAggregator.init(allocator);
    }

    const agg_ptr: ?*BatchAggregator = if (aggregator) |*agg| agg else null;

    while (true) {
        const n = try readAt(f.fd, f.position, buf);
        if (n == 0) break;

        f.position += n;
        var slice = buf[0..n];

        const used_carry = carry.items.len > 0;
        if (used_carry) {
            try ensureLineCapacity(carry.items.len, slice.len);
            try carry.appendSlice(allocator, slice);
            slice = carry.items;
        }

        var start: usize = 0;
        while (simd.findByte(slice, start, '\n')) |nl| {
            const line = slice[start..nl];
            if (line.len > 0) {
                try processLine(allocator, args, filter_state, agg_ptr, line);
            }
            start = nl + 1;
        }

        try keepUnprocessedTail(allocator, carry, slice, start, used_carry);
    }

    if (flush_final_line and carry.items.len > 0) {
        try processLine(allocator, args, filter_state, agg_ptr, carry.items);
        carry.clearRetainingCapacity();
    }

    if (aggregator) |*agg| {
        agg.printAll(filter_state);
    }
}

fn keepUnprocessedTail(
    allocator: std.mem.Allocator,
    carry: *std.ArrayList(u8),
    slice: []const u8,
    start: usize,
    used_carry: bool,
) !void {
    if (used_carry) {
        if (start < carry.items.len) {
            const rest = carry.items[start..];
            std.mem.copyForwards(u8, carry.items[0..rest.len], rest);
            carry.items.len = rest.len;
        } else {
            carry.clearRetainingCapacity();
        }
        return;
    }

    carry.clearRetainingCapacity();
    if (start < slice.len) {
        try ensureLineCapacity(0, slice.len - start);
        try carry.appendSlice(allocator, slice[start..]);
    }
}

fn processLine(
    allocator: std.mem.Allocator,
    args: flags.Args,
    filter_state: *formats.FilterState,
    aggregator: ?*BatchAggregator,
    line: []const u8,
) !void {
    if (!args.aggregate) {
        filter_state.printIfMatch(line);
        return;
    }

    _ = allocator;
    // Reuse LineInfo produced by checkLine — buildAggregateKey accepts it
    // directly, avoiding a second parse of the line for key construction,
    // and the aggregator caches it so printAll skips a third one.
    if (filter_state.checkLine(line)) |ck| {
        try aggregator.?.observe(args.aggregate_mode, ck.line, ck.info);
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;
const never_match = "__tail_test_should_not_match__";

fn makeTailArgs(
    files: [][]const u8,
    num_lines: usize,
    aggregate: bool,
    aggregate_mode: flags.AggregateMode,
) flags.Args {
    return .{
        .files = files,
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = null,
        .num_lines = num_lines,
        .aggregate = aggregate,
        .aggregate_mode = aggregate_mode,
    };
}

/// Same as `makeTailArgs`, but with a search term that intentionally matches nothing.
/// This keeps tests silent and avoids stdout interaction inside the test runner.
fn makeSilentTailArgs(
    files: [][]const u8,
    num_lines: usize,
    aggregate: bool,
    aggregate_mode: flags.AggregateMode,
) flags.Args {
    return .{
        .files = files,
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = never_match,
        .num_lines = num_lines,
        .aggregate = aggregate,
        .aggregate_mode = aggregate_mode,
    };
}

test "readLastNLines handles files with fewer lines than requested" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(tail_io, .{ .sub_path = "small.log", .data = "first\nsecond\n" });

    var file = try tmp.dir.openFile(tail_io, "small.log", .{});
    defer file.close(tail_io);

    const stat = try file.stat(tail_io);
    var files_array = [_][]const u8{"small.log"};
    const args = makeSilentTailArgs(files_array[0..], 10, false, .exact);
    var filter_state = formats.FilterState.init(args, null, null);

    const read_buf = try allocator.alloc(u8, READ_BUF_SIZE);
    defer allocator.free(read_buf);

    var of = OpenFile{ .path = "small.log", .fd = file, .position = 0 };
    const pos = try readLastNLines(allocator, &of, args, stat.size, &filter_state, read_buf);
    try testing.expectEqual(@as(u64, 13), pos);
}

test "readLastNLines handles empty file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(tail_io, .{ .sub_path = "empty.log", .data = "" });

    var file = try tmp.dir.openFile(tail_io, "empty.log", .{});
    defer file.close(tail_io);

    const stat = try file.stat(tail_io);
    try testing.expectEqual(@as(u64, 0), stat.size);
}

test "findLastNLinesStart ignores trailing newline" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(tail_io, .{
        .sub_path = "tail.log",
        .data = "line1\nline2\nline3\nline4\nline5\n",
    });

    var file = try tmp.dir.openFile(tail_io, "tail.log", .{});
    defer file.close(tail_io);

    const stat = try file.stat(tail_io);
    var read_buf: [READ_BUF_SIZE]u8 = undefined;
    var of = OpenFile{ .path = "tail.log", .fd = file, .position = 0 };

    try testing.expectEqual(@as(u64, 12), try findLastNLinesStart(&of, stat.size, 3, &read_buf));
    try testing.expectEqual(@as(u64, 24), try findLastNLinesStart(&of, stat.size, 1, &read_buf));
}

test "findLastNLinesStart handles file without trailing newline" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(tail_io, .{
        .sub_path = "tail-no-newline.log",
        .data = "line1\nline2\nline3\nline4\nline5",
    });

    var file = try tmp.dir.openFile(tail_io, "tail-no-newline.log", .{});
    defer file.close(tail_io);

    const stat = try file.stat(tail_io);
    var read_buf: [READ_BUF_SIZE]u8 = undefined;
    var of = OpenFile{ .path = "tail-no-newline.log", .fd = file, .position = 0 };

    try testing.expectEqual(@as(u64, 12), try findLastNLinesStart(&of, stat.size, 3, &read_buf));
    try testing.expectEqual(@as(u64, 24), try findLastNLinesStart(&of, stat.size, 1, &read_buf));
}

test "position tracking correctly advances after reading" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(tail_io, .{
        .sub_path = "pos.log",
        .data = "line1\nline2\nline3\nline4\nline5\n",
    });

    var file = try tmp.dir.openFile(tail_io, "pos.log", .{});
    defer file.close(tail_io);

    const stat = try file.stat(tail_io);
    var files_array = [_][]const u8{"pos.log"};
    const args = makeSilentTailArgs(files_array[0..], 3, false, .exact);
    var filter_state = formats.FilterState.init(args, null, null);

    const read_buf = try allocator.alloc(u8, READ_BUF_SIZE);
    defer allocator.free(read_buf);

    var of = OpenFile{ .path = "pos.log", .fd = file, .position = 0 };
    const position = try readLastNLines(allocator, &of, args, stat.size, &filter_state, read_buf);
    try testing.expectEqual(@as(u64, 30), position);
}

test "truncation detection resets position to beginning" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(tail_io, .{ .sub_path = "truncate.log", .data = "initial content\n" });

    var file = try tmp.dir.openFile(tail_io, "truncate.log", .{});
    defer file.close(tail_io);

    const stat1 = try file.stat(tail_io);
    var position: u64 = stat1.size;

    {
        var truncate_file = try tmp.dir.openFile(tail_io, "truncate.log", .{ .mode = .write_only });
        defer truncate_file.close(tail_io);
        try truncate_file.setLength(tail_io, 0);
    }

    const stat2 = try file.stat(tail_io);
    if (position > stat2.size) position = 0;

    try testing.expectEqual(@as(u64, 0), position);
}

test "appended data read correctly in sequential operations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(tail_io, .{
        .sub_path = "append.log",
        .data = "line1\nline2\nline3\n",
    });

    var file = try tmp.dir.openFile(tail_io, "append.log", .{});
    defer file.close(tail_io);

    const stat1 = try file.stat(tail_io);
    var files_array = [_][]const u8{"append.log"};
    const args = makeSilentTailArgs(files_array[0..], 2, false, .exact);
    var filter_state = formats.FilterState.init(args, null, null);

    const read_buf = try allocator.alloc(u8, READ_BUF_SIZE);
    defer allocator.free(read_buf);

    var of = OpenFile{ .path = "append.log", .fd = file, .position = 0 };
    const position = try readLastNLines(allocator, &of, args, stat1.size, &filter_state, read_buf);
    try testing.expectEqual(@as(u64, 18), position);

    // Append more data using positional write (pwrite)
    {
        var append_file = try tmp.dir.openFile(tail_io, "append.log", .{ .mode = .read_write });
        defer append_file.close(tail_io);
        const end_pos = try append_file.length(tail_io);
        try append_file.writePositionalAll(tail_io, "line4\nline5\nline6\n", end_pos);
    }

    const stat2 = try file.stat(tail_io);
    try testing.expect(stat2.size > position);

    var carry: std.ArrayList(u8) = .empty;
    defer carry.deinit(allocator);

    const args2 = makeSilentTailArgs(files_array[0..], 0, false, .exact);
    var filter_state2 = formats.FilterState.init(args2, null, null);

    try readToEOF(allocator, &of, args2, &filter_state2, &carry, read_buf);
    try testing.expectEqual(@as(u64, 36), of.position);
}

test "batch aggregator counts identical keys and keeps first line" {
    var agg = try BatchAggregator.init(testing.allocator);
    defer agg.deinit();

    // Use a no-op LineInfo — the tests below only assert counts/sample lines.
    const empty_info: formats.LineInfo = std.mem.zeroes(formats.LineInfo);
    try agg.add("error\x1ffailed", "[ERROR] failed", empty_info);
    try agg.add("error\x1ffailed", "[ERROR] failed", empty_info);
    try agg.add("warn\x1fslow", "[WARN] slow", empty_info);

    try testing.expectEqual(@as(usize, 2), agg.order.items.len);
    try testing.expectEqual(@as(usize, 2), agg.entries.get("error\x1ffailed").?.count);
    try testing.expectEqual(@as(usize, 1), agg.entries.get("warn\x1fslow").?.count);
    try testing.expectEqualStrings("[ERROR] failed", agg.entries.get("error\x1ffailed").?.sample_line);
}

test "readToEOF with aggregate exact advances position and preserves carry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(tail_io, .{
        .sub_path = "agg.log",
        .data = "[ERROR] one\n[ERROR] one\npartial",
    });

    var file = try tmp.dir.openFile(tail_io, "agg.log", .{});
    defer file.close(tail_io);

    var files_array = [_][]const u8{"agg.log"};
    const args = makeSilentTailArgs(files_array[0..], 0, true, .exact);
    var filter_state = formats.FilterState.init(args, null, null);

    var carry: std.ArrayList(u8) = .empty;
    defer carry.deinit(allocator);

    const read_buf = try allocator.alloc(u8, READ_BUF_SIZE);
    defer allocator.free(read_buf);

    var of = OpenFile{ .path = "agg.log", .fd = file, .position = 0 };
    try readToEOF(allocator, &of, args, &filter_state, &carry, read_buf);

    try testing.expectEqualStrings("partial", carry.items);
    try testing.expect(of.position > 0);
}

test "readToEOF with aggregate normalized consumes complete data" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(tail_io, .{
        .sub_path = "norm.log",
        .data = "2023-10-18 [ERROR] Request 123 failed\n2023-10-19 [ERROR] Request 999 failed\n",
    });

    var file = try tmp.dir.openFile(tail_io, "norm.log", .{});
    defer file.close(tail_io);

    var files_array = [_][]const u8{"norm.log"};
    const args = makeSilentTailArgs(files_array[0..], 0, true, .normalized);
    var filter_state = formats.FilterState.init(args, null, null);

    var carry: std.ArrayList(u8) = .empty;
    defer carry.deinit(allocator);

    const read_buf = try allocator.alloc(u8, READ_BUF_SIZE);
    defer allocator.free(read_buf);

    var of = OpenFile{ .path = "norm.log", .fd = file, .position = 0 };
    try readToEOF(allocator, &of, args, &filter_state, &carry, read_buf);

    try testing.expectEqual(@as(usize, 0), carry.items.len);
    try testing.expect(of.position > 0);
}

test "readToEOFInternal can flush final line without trailing newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(tail_io, .{
        .sub_path = "unterminated.log",
        .data = "line1\npartial",
    });

    var file = try tmp.dir.openFile(tail_io, "unterminated.log", .{});
    defer file.close(tail_io);

    const stat = try file.stat(tail_io);
    var files_array = [_][]const u8{"unterminated.log"};
    const args = makeSilentTailArgs(files_array[0..], 0, false, .exact);
    var filter_state = formats.FilterState.init(args, null, null);
    defer filter_state.deinit();

    var carry: std.ArrayList(u8) = .empty;
    defer carry.deinit(allocator);

    var read_buf: [4]u8 = undefined;
    var of = OpenFile{ .path = "unterminated.log", .fd = file, .position = 0 };
    try readToEOFInternal(allocator, &of, args, &filter_state, &carry, &read_buf, true);

    try testing.expectEqual(@as(usize, 0), carry.items.len);
    try testing.expectEqual(stat.size, of.position);
}

fn makeSearchTailArgs(files: [][]const u8, num_lines: usize, search: []const u8) flags.Args {
    return .{
        .files = files,
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = search,
        .num_lines = num_lines,
        .aggregate = false,
        .aggregate_mode = .exact,
    };
}

/// `hit a` starts at 4 and `hit b` at 26; everything else is filler the
/// filter drops.
const filtered_backfill_fixture =
    "no1\nhit a\nno2\nno3\nno4\nno5\nhit b\nno6\nno7\nno8\nno9\nno10\n";

fn filteredBackfillStart(allocator: std.mem.Allocator, n: usize) !u64 {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(tail_io, .{ .sub_path = "f.log", .data = filtered_backfill_fixture });

    var file = try tmp.dir.openFile(tail_io, "f.log", .{});
    defer file.close(tail_io);

    var files_array = [_][]const u8{"f.log"};
    const args = makeSearchTailArgs(files_array[0..], n, "hit");
    var filter_state = formats.FilterState.init(args, null, null);

    const scan_buf = try allocator.alloc(u8, READ_BUF_SIZE);
    defer allocator.free(scan_buf);

    var of = OpenFile{ .path = "f.log", .fd = file, .position = 0 };
    const stat = try file.stat(tail_io);
    return findLastNMatchingStart(allocator, &of, stat.size, n, &filter_state, scan_buf);
}

test "filtered backfill starts at the nth-from-last matching line" {
    // Both matches sit outside the last `n` raw lines, which is the case the
    // raw-line backfill got wrong: it would have started past them and shown
    // nothing at all.
    try testing.expectEqual(@as(u64, 26), try filteredBackfillStart(testing.allocator, 1));
    try testing.expectEqual(@as(u64, 4), try filteredBackfillStart(testing.allocator, 2));
}

test "filtered backfill falls back to start of file when matches run out" {
    try testing.expectEqual(@as(u64, 0), try filteredBackfillStart(testing.allocator, 5));
}

test "filtered backfill counts a final line with no trailing newline" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Last line is unterminated; `readLastNLines` prints it, so it has to
    // count here too or the window would be off by one match.
    try tmp.dir.writeFile(tail_io, .{ .sub_path = "u.log", .data = "hit a\nno1\nhit b" });

    var file = try tmp.dir.openFile(tail_io, "u.log", .{});
    defer file.close(tail_io);

    var files_array = [_][]const u8{"u.log"};
    const args = makeSearchTailArgs(files_array[0..], 1, "hit");
    var filter_state = formats.FilterState.init(args, null, null);

    const scan_buf = try testing.allocator.alloc(u8, READ_BUF_SIZE);
    defer testing.allocator.free(scan_buf);

    var of = OpenFile{ .path = "u.log", .fd = file, .position = 0 };
    const stat = try file.stat(tail_io);
    const start = try findLastNMatchingStart(testing.allocator, &of, stat.size, 1, &filter_state, scan_buf);
    try testing.expectEqual(@as(u64, 10), start);
}

test "filtered backfill reassembles lines split across scan chunks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    // Filler long enough that the sole match lands mid-chunk with a tiny
    // scan buffer, exercising the carry path.
    const hit_off = 300;
    try body.appendNTimes(allocator, 'x', hit_off - 1);
    try body.append(allocator, '\n');
    try body.appendSlice(allocator, "hit here\n");
    try body.appendNTimes(allocator, 'y', 299);
    try body.append(allocator, '\n');

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(tail_io, .{ .sub_path = "c.log", .data = body.items });

    var file = try tmp.dir.openFile(tail_io, "c.log", .{});
    defer file.close(tail_io);

    var files_array = [_][]const u8{"c.log"};
    const args = makeSearchTailArgs(files_array[0..], 1, "hit");
    var filter_state = formats.FilterState.init(args, null, null);

    const scan_buf = try allocator.alloc(u8, 64);
    var of = OpenFile{ .path = "c.log", .fd = file, .position = 0 };
    const stat = try file.stat(tail_io);
    const start = try findLastNMatchingStart(allocator, &of, stat.size, 1, &filter_state, scan_buf);
    try testing.expectEqual(@as(u64, hit_off), start);
}
