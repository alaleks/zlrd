const std = @import("std");
const flags = @import("flags");
const formats = @import("formats.zig");
const simd = @import("simd.zig");

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

/// Batch-local aggregator used by tail reads.
/// Keeps first-seen order within one read batch and prints once per key.
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

    fn printAll(self: *BatchAggregator) void {
        for (self.order.items) |key| {
            const count = self.counts.get(key).?;
            const line = self.sample_lines.get(key).?;

            if (count > 1) {
                var buf: [128]u8 = undefined;
                const prefix = std.fmt.bufPrint(&buf, "\x1b[2m[x{d}] \x1b[0m", .{count}) catch "[x?] ";
                std.Io.File.stdout().writeStreamingAll(tail_io, prefix) catch {};
            }

            formats.handleLine(line, .{
                .files = &.{},
                .search = null,
                .levels = null,
                .date = null,
                .tail_mode = false,
                .help = false,
                .version = false,
                .num_lines = 0,
                .aggregate = false,
                .aggregate_mode = .exact,
            });
        }
    }
};

pub fn follow(
    allocator: std.mem.Allocator,
    args: flags.Args,
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

    const filter_state = formats.FilterState.init(args);

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
                filter_state,
                read_buf,
            );
            files_buf[files_len - 1].position = final_pos;
        }
    }

    if (files_len == 0) return;

    const carries = try allocator.alloc(std.ArrayList(u8), files_len);
    defer {
        for (carries) |*c| c.deinit(allocator);
        allocator.free(carries);
    }
    for (carries) |*c| c.* = .empty;

    while (true) {
        var any_read = false;

        for (files_buf[0..files_len], carries) |*f, *carry| {
            const stat = f.fd.stat(tail_io) catch continue;

            if (f.position > stat.size) {
                // File was truncated — reset to beginning.
                f.position = 0;
            } else if (f.position == stat.size) {
                continue;
            }

            const bytes_read = readAvailable(allocator, f, args, filter_state, carry, read_buf) catch continue;
            if (bytes_read > 0) any_read = true;
        }

        if (!any_read) {
            std.Io.sleep(tail_io, std.Io.Duration.fromMilliseconds(100), .awake) catch continue;
        }
    }
}

/// Reads the last `args.num_lines` lines (default 10) from `file`,
/// prints matching ones via `filter_state`, and returns the file position
/// after the last consumed byte.
pub fn readLastNLines(
    allocator: std.mem.Allocator,
    f: *OpenFile,
    args: flags.Args,
    file_size: u64,
    filter_state: formats.FilterState,
    read_buf: []u8,
) !u64 {
    const n: usize = if (args.num_lines == 0) 10 else args.num_lines;

    const read_from = try findLastNLinesStart(f, file_size, n, read_buf);

    f.position = read_from;

    var carry: std.ArrayList(u8) = .empty;
    defer carry.deinit(allocator);

    try readToEOF(allocator, f, args, filter_state, &carry, read_buf);
    return f.position;
}

/// Reads any new data from `file` starting at `*position`,
/// processes complete lines, and returns the number of bytes consumed.
fn readAvailable(
    allocator: std.mem.Allocator,
    f: *OpenFile,
    args: flags.Args,
    filter_state: formats.FilterState,
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
    filter_state: formats.FilterState,
    carry: *std.ArrayList(u8),
    buf: []u8,
) !void {
    var aggregator: ?BatchAggregator = null;
    defer if (aggregator) |*agg| agg.deinit();

    if (args.aggregate) {
        aggregator = try BatchAggregator.init(allocator);
    }

    const agg_ptr: ?*BatchAggregator = if (aggregator) |*agg| agg else null;

    while (true) {
        const n = readAt(f.fd, f.position, buf) catch break;
        if (n == 0) break;

        f.position += n;
        var slice = buf[0..n];

        if (carry.items.len > 0) {
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

        carry.clearRetainingCapacity();
        if (start < slice.len) {
            try carry.appendSlice(allocator, slice[start..]);
        }
    }

    if (aggregator) |*agg| {
        agg.printAll();
    }
}

fn processLine(
    allocator: std.mem.Allocator,
    args: flags.Args,
    filter_state: formats.FilterState,
    aggregator: ?*BatchAggregator,
    line: []const u8,
) !void {
    if (!args.aggregate) {
        filter_state.printIfMatch(line);
        return;
    }

    if (filter_state.checkLine(line) != null) {
        const key = try formats.buildAggregateKeyForLine(allocator, args.aggregate_mode, line);
        defer allocator.free(key);

        try aggregator.?.add(key, line);
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
    const filter_state = formats.FilterState.init(args);

    const read_buf = try allocator.alloc(u8, READ_BUF_SIZE);
    defer allocator.free(read_buf);

    var of = OpenFile{ .path = "small.log", .fd = file, .position = 0 };
    const pos = try readLastNLines(allocator, &of, args, stat.size, filter_state, read_buf);
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
    const filter_state = formats.FilterState.init(args);

    const read_buf = try allocator.alloc(u8, READ_BUF_SIZE);
    defer allocator.free(read_buf);

    var of = OpenFile{ .path = "pos.log", .fd = file, .position = 0 };
    const position = try readLastNLines(allocator, &of, args, stat.size, filter_state, read_buf);
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
    const filter_state = formats.FilterState.init(args);

    const read_buf = try allocator.alloc(u8, READ_BUF_SIZE);
    defer allocator.free(read_buf);

    var of = OpenFile{ .path = "append.log", .fd = file, .position = 0 };
    const position = try readLastNLines(allocator, &of, args, stat1.size, filter_state, read_buf);
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
    const filter_state2 = formats.FilterState.init(args2);

    try readToEOF(allocator, &of, args2, filter_state2, &carry, read_buf);
    try testing.expectEqual(@as(u64, 36), of.position);
}

test "batch aggregator counts identical keys and keeps first line" {
    var agg = try BatchAggregator.init(testing.allocator);
    defer agg.deinit();

    try agg.add("error\x1ffailed", "[ERROR] failed");
    try agg.add("error\x1ffailed", "[ERROR] failed");
    try agg.add("warn\x1fslow", "[WARN] slow");

    try testing.expectEqual(@as(usize, 2), agg.order.items.len);
    try testing.expectEqual(@as(usize, 2), agg.counts.get("error\x1ffailed").?);
    try testing.expectEqual(@as(usize, 1), agg.counts.get("warn\x1fslow").?);
    try testing.expectEqualStrings("[ERROR] failed", agg.sample_lines.get("error\x1ffailed").?);
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
    const filter_state = formats.FilterState.init(args);

    var carry: std.ArrayList(u8) = .empty;
    defer carry.deinit(allocator);

    const read_buf = try allocator.alloc(u8, READ_BUF_SIZE);
    defer allocator.free(read_buf);

    var of = OpenFile{ .path = "agg.log", .fd = file, .position = 0 };
    try readToEOF(allocator, &of, args, filter_state, &carry, read_buf);

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
    const filter_state = formats.FilterState.init(args);

    var carry: std.ArrayList(u8) = .empty;
    defer carry.deinit(allocator);

    const read_buf = try allocator.alloc(u8, READ_BUF_SIZE);
    defer allocator.free(read_buf);

    var of = OpenFile{ .path = "norm.log", .fd = file, .position = 0 };
    try readToEOF(allocator, &of, args, filter_state, &carry, read_buf);

    try testing.expectEqual(@as(usize, 0), carry.items.len);
    try testing.expect(of.position > 0);
}
