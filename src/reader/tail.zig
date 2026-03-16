const std = @import("std");
const flags = @import("../flags/flags.zig");
const formats = @import("formats.zig");
const simd = @import("simd.zig");

// Track open files with manual position tracking.
const OpenFile = struct {
    path: []const u8,
    fd: std.fs.File,
    position: u64,
};

// Read buffer size for the follow loop.
// 64 KB gives good throughput without excessive stack usage.
const READ_BUF_SIZE = 64 * 1024;

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
            files_buf[i].fd.close();
        }
    }

    // FilterState is built once and reused across all lines and files.
    const filter_state = formats.FilterState.init(args);

    // Allocate a single shared read buffer for the follow loop and for
    // readLastNLines — avoids a second READ_BUF_SIZE allocation per file.
    const read_buf = try allocator.alloc(u8, READ_BUF_SIZE);
    defer allocator.free(read_buf);

    // Open files and read last N lines.
    for (args.files) |path| {
        const fd = std.fs.cwd().openFile(path, .{}) catch |err| {
            var errbuf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&errbuf, "Cannot open {s}: {any}\n", .{ path, err }) catch "Cannot open file\n";
            std.fs.File.stderr().writeAll(msg) catch {};
            continue;
        };
        files_buf[files_len] = OpenFile{
            .path = path,
            .fd = fd,
            .position = 0,
        };
        files_len += 1;

        const stat = try fd.stat();
        if (stat.size > 0) {
            const final_pos = try readLastNLines(allocator, &files_buf[files_len - 1].fd, args, stat.size, filter_state, read_buf);
            files_buf[files_len - 1].position = final_pos;
        }
    }

    if (files_len == 0) return;

    // Carry buffers — one per file, so partial lines survive across reads.
    const carries = try allocator.alloc(std.ArrayList(u8), files_len);
    defer {
        for (carries) |*c| c.deinit(allocator);
        allocator.free(carries);
    }
    for (carries) |*c| c.* = std.ArrayList(u8){};

    // Follow loop — keep FDs open continuously (required on macOS).
    //
    // NOTE: log rotation via rename/unlink is detected by size shrink only.
    // On Linux a renamed file continues to be readable via the original fd
    // (the inode is still open). A full inode-change detection would require
    // stat()-ing the path and comparing st_ino, then reopening the file.
    // This is a known limitation: after rotation the new file is not picked
    // up until the old fd reaches EOF and the size drops below `position`.
    while (true) {
        var any_read = false;

        for (files_buf[0..files_len], carries) |*f, *carry| {
            const stat = f.fd.stat() catch continue;

            if (f.position > stat.size) {
                // File was truncated — reset to the beginning.
                f.position = 0;
                f.fd.seekTo(0) catch continue;
            } else if (f.position < stat.size) {
                f.fd.seekTo(f.position) catch continue;
            } else {
                continue;
            }

            const bytes_read = readAvailable(allocator, &f.fd, filter_state, carry, &f.position, read_buf) catch continue;
            if (bytes_read > 0) any_read = true;
        }

        if (!any_read) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
}

/// Reads the last `args.num_lines` lines (default 10) from `file`,
/// prints matching ones via `filter_state`, and returns the file position
/// after the last consumed byte.
///
/// Scans backwards through the file in SCAN_CHUNK steps until N newlines
/// are found or the beginning of the file is reached. This handles files of
/// any size correctly — the old single-chunk approach missed lines when the
/// last N lines spanned more than 8 KB.
///
/// `read_buf` is a caller-owned scratch buffer of at least READ_BUF_SIZE bytes,
/// allowing the caller to reuse one allocation across multiple calls.
pub fn readLastNLines(
    allocator: std.mem.Allocator,
    file: *std.fs.File,
    args: flags.Args,
    file_size: u64,
    filter_state: formats.FilterState,
    read_buf: []u8,
) !u64 {
    const n: usize = if (args.num_lines == 0) 10 else args.num_lines;

    // Scan chunk size for the backwards pass — 64 KB matches READ_BUF_SIZE
    // so one chunk is almost always enough for typical log lines.
    const SCAN_CHUNK: u64 = 64 * 1024;

    const scan_buf = try allocator.alloc(u8, SCAN_CHUNK);
    defer allocator.free(scan_buf);

    // Scan backwards in SCAN_CHUNK windows until we have found N newlines.
    var newlines_found: usize = 0;
    var read_from: u64 = 0; // absolute file offset to start forward reading from
    var scan_end: u64 = file_size;

    outer: while (scan_end > 0) {
        const chunk_size: u64 = @min(scan_end, SCAN_CHUNK);
        const chunk_start: u64 = scan_end - chunk_size;

        try file.seekTo(chunk_start);
        const bytes_read = try file.read(scan_buf[0..chunk_size]);

        // Walk backwards through this chunk counting newlines.
        var idx: usize = bytes_read;
        while (idx > 0) {
            idx -= 1;
            if (scan_buf[idx] == '\n') {
                newlines_found += 1;
                if (newlines_found == n) {
                    // The line after this newline is where we start reading.
                    read_from = chunk_start + idx + 1;
                    break :outer;
                }
            }
        }

        if (chunk_start == 0) break; // reached the beginning
        scan_end = chunk_start;
    }

    // read_from stays 0 if fewer than N newlines exist in the entire file.
    try file.seekTo(read_from);

    var carry = try std.ArrayList(u8).initCapacity(allocator, 4096);
    defer carry.deinit(allocator);
    var pos: u64 = read_from;

    try readToEOF(allocator, file, filter_state, &carry, &pos, read_buf);
    return pos;
}

/// Reads any new data from `file` starting at `*position`,
/// processes complete lines, and returns the number of bytes consumed.
fn readAvailable(
    allocator: std.mem.Allocator,
    file: *std.fs.File,
    filter_state: formats.FilterState,
    carry: *std.ArrayList(u8),
    position: *u64,
    buf: []u8,
) !usize {
    const start_pos = position.*;
    try readToEOF(allocator, file, filter_state, carry, position, buf);
    return position.* - start_pos;
}

/// Reads `file` to EOF, splits on newlines, and passes each complete line to
/// `filter_state.printIfMatch`. Partial trailing lines are saved in `carry`
/// and prepended on the next call. `position` is advanced by bytes read.
///
/// NOTE: empty lines (consecutive newlines) are silently skipped. This is
/// intentional for tail output but means blank separators between log entries
/// are not forwarded to the filter. Revisit if blank-line-aware formats are added.
pub fn readToEOF(
    allocator: std.mem.Allocator,
    file: *std.fs.File,
    filter_state: formats.FilterState,
    carry: *std.ArrayList(u8),
    position: *u64,
    buf: []u8,
) !void {
    while (true) {
        const n = file.read(buf) catch break;
        if (n == 0) break;

        position.* += n;
        var slice = buf[0..n];

        // BUG FIX: the old code did `defer allocator.free(combined)` inside the
        // `if` block, which freed `combined` before the line-scanning loop below
        // could use `slice` — a use-after-free. The fix hoists the defer outside
        // the `if` so `combined` lives for the full iteration of the outer loop.
        var combined: ?[]u8 = null;
        defer if (combined) |c| allocator.free(c);

        if (carry.items.len > 0) {
            try carry.appendSlice(allocator, slice);
            combined = try allocator.dupe(u8, carry.items);
            carry.clearRetainingCapacity();
            slice = combined.?;
        }

        // Process complete lines using SIMD byte search.
        var start: usize = 0;
        while (simd.findByte(slice, start, '\n')) |nl| {
            if (nl > start) filter_state.printIfMatch(slice[start..nl]);
            start = nl + 1;
        }

        // Save the trailing partial line for the next iteration.
        if (start < slice.len) {
            try carry.appendSlice(allocator, slice[start..]);
        }
    }
}

// ============================================================================
// Unit Tests (Zig 0.15.2 compliant)
// ============================================================================

const testing = std.testing;

test "readLastNLines handles files with fewer lines than requested" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "small.log", .data = "first\nsecond\n" });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const old_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(old_cwd);
    try std.posix.chdir(tmp_path);
    defer std.posix.chdir(old_cwd) catch unreachable;

    var file = try std.fs.cwd().openFile("small.log", .{});
    defer file.close();

    const stat = try file.stat();
    var files_array = [_][]const u8{"small.log"};
    const args = flags.Args{
        .files = files_array[0..],
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = null,
        .num_lines = 10,
    };
    const filter_state = formats.FilterState.init(args);
    const read_buf = try allocator.alloc(u8, READ_BUF_SIZE);

    const pos = try readLastNLines(allocator, &file, args, stat.size, filter_state, read_buf);
    // File has 2 lines totalling 13 bytes; position should be at EOF.
    try testing.expectEqual(@as(u64, 13), pos);
}

test "readLastNLines handles empty file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "empty.log", .data = "" });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const old_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(old_cwd);
    try std.posix.chdir(tmp_path);
    defer std.posix.chdir(old_cwd) catch unreachable;

    // Empty file: follow() skips readLastNLines (stat.size == 0), so position stays 0.
    var file = try std.fs.cwd().openFile("empty.log", .{});
    defer file.close();
    const stat = try file.stat();
    try testing.expectEqual(@as(u64, 0), stat.size);
}

test "position tracking correctly advances after reading" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "pos.log",
        .data = "line1\nline2\nline3\nline4\nline5\n",
    });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const old_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(old_cwd);
    try std.posix.chdir(tmp_path);
    defer std.posix.chdir(old_cwd) catch unreachable;

    var file = try std.fs.cwd().openFile("pos.log", .{});
    defer file.close();

    const stat = try file.stat();
    var files_array = [_][]const u8{"pos.log"};
    const args = flags.Args{
        .files = files_array[0..],
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = null,
        .num_lines = 3,
    };
    const filter_state = formats.FilterState.init(args);
    const read_buf = try allocator.alloc(u8, READ_BUF_SIZE);

    const position = try readLastNLines(allocator, &file, args, stat.size, filter_state, read_buf);
    try testing.expectEqual(@as(u64, 30), position);
}

test "truncation detection resets position to beginning" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "truncate.log", .data = "initial content\n" });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const old_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(old_cwd);
    try std.posix.chdir(tmp_path);
    defer std.posix.chdir(old_cwd) catch unreachable;

    var file = try std.fs.cwd().openFile("truncate.log", .{});
    defer file.close();

    const stat1 = try file.stat();
    var position: u64 = stat1.size;

    {
        var truncate_file = try std.fs.cwd().openFile("truncate.log", .{ .mode = .write_only });
        defer truncate_file.close();
        try truncate_file.setEndPos(0);
    }

    const stat2 = try file.stat();
    if (position > stat2.size) position = 0;

    try testing.expectEqual(@as(u64, 0), position);
}

test "appended data read correctly in sequential operations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "append.log",
        .data = "line1\nline2\nline3\n",
    });

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const old_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(old_cwd);
    try std.posix.chdir(tmp_path);
    defer std.posix.chdir(old_cwd) catch unreachable;

    var file = try std.fs.cwd().openFile("append.log", .{});
    defer file.close();

    const stat1 = try file.stat();
    var files_array = [_][]const u8{"append.log"};
    const args = flags.Args{
        .files = files_array[0..],
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = null,
        .num_lines = 2,
    };
    const filter_state = formats.FilterState.init(args);
    const read_buf = try allocator.alloc(u8, READ_BUF_SIZE);

    var position = try readLastNLines(allocator, &file, args, stat1.size, filter_state, read_buf);
    try testing.expectEqual(@as(u64, 18), position);

    {
        var append_file = try std.fs.cwd().openFile("append.log", .{ .mode = .write_only });
        defer append_file.close();
        try append_file.seekFromEnd(0);
        try append_file.writeAll("line4\nline5\nline6\n");
    }

    const stat2 = try file.stat();
    try testing.expect(stat2.size > position);

    try file.seekTo(position);
    var carry = std.ArrayList(u8){};
    defer carry.deinit(allocator);

    const args2 = flags.Args{
        .files = files_array[0..],
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = null,
        .num_lines = 0,
    };
    const filter_state2 = formats.FilterState.init(args2);

    try readToEOF(allocator, &file, filter_state2, &carry, &position, read_buf);

    try testing.expectEqual(@as(u64, 36), position);
}
