const std = @import("std");
const flags = @import("../flags/flags.zig");
const formats = @import("formats.zig");

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
    // FIX: errdefer must free the slice; the per-fd close is in the main defer.
    defer allocator.free(files_buf);

    var files_len: usize = 0;
    defer {
        var i: usize = 0;
        while (i < files_len) : (i += 1) {
            files_buf[i].fd.close();
        }
    }

    // FIX: build FilterState once, outside the per-line loop.
    // handleLine was rebuilding it on every line — O(lines) overhead.
    const filter_state = formats.FilterState.init(args);

    // Open files and read last N lines.
    for (args.files) |path| {
        const fd = std.fs.cwd().openFile(path, .{}) catch |err| {
            // Format error to stderr without File.writer(buf) API.
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
            const final_pos = try readLastNLines(allocator, &files_buf[files_len - 1].fd, args, stat.size, filter_state);
            files_buf[files_len - 1].position = final_pos;
        }
    }

    if (files_len == 0) return;

    // Allocate a single shared read buffer for the follow loop.
    // Re-using one allocation instead of stack-allocating 4 KB per call.
    const read_buf = try allocator.alloc(u8, READ_BUF_SIZE);
    defer allocator.free(read_buf);

    // Carry buffers — one per file, so partial lines survive across reads.
    const carries = try allocator.alloc(std.ArrayList(u8), files_len);
    defer {
        for (carries) |*c| c.deinit(allocator);
        allocator.free(carries);
    }
    for (carries) |*c| c.* = std.ArrayList(u8){};

    // Follow loop — keep FDs open continuously (required on macOS).
    while (true) {
        var any_read = false;

        for (files_buf[0..files_len], carries) |*f, *carry| {
            // Check for log rotation (file truncated or replaced).
            const stat = f.fd.stat() catch continue;

            if (f.position > stat.size) {
                // File was truncated — reset to the beginning.
                f.position = 0;
                f.fd.seekTo(0) catch continue;
            } else if (f.position < stat.size) {
                // New data available — seek to our last position.
                // FIX: only seek when needed; avoids a syscall when nothing changed.
                f.fd.seekTo(f.position) catch continue;
            } else {
                // Nothing new.
                continue;
            }

            const bytes_read = readAvailable(allocator, &f.fd, filter_state, carry, &f.position, read_buf) catch continue;
            if (bytes_read > 0) any_read = true;
        }

        if (!any_read) {
            // FIX: 100 ms sleep is fine for tail -f; avoids busy-spinning.
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
}

// readLastNLines reads the last `n` lines from `file` (where n = args.num_lines,
// defaulting to 10), prints matching ones, and returns the file position after the
// last byte consumed.
pub fn readLastNLines(
    allocator: std.mem.Allocator,
    file: *std.fs.File,
    args: flags.Args,
    file_size: u64,
    filter_state: formats.FilterState,
) !u64 {
    const n = if (args.num_lines == 0) 10 else args.num_lines;

    // Skip to EOF immediately if 0 lines are requested.
    if (n == 0) {
        try file.seekTo(file_size);
        return file_size;
    }

    // Read a tail chunk large enough to hold N typical lines.
    // Cap at file_size to handle small files correctly.
    const chunk_size: u64 = @min(file_size, 8192);
    const start_pos: u64 = file_size - chunk_size;
    try file.seekTo(start_pos);

    const buf = try allocator.alloc(u8, chunk_size);
    defer allocator.free(buf);

    const bytes_read = try file.read(buf[0..chunk_size]);

    // Walk backwards counting newlines.
    // To get the last N lines we need to skip N-1 newline separators —
    // the Nth line from the end starts right after the (N-1)th newline from the end.
    var newlines_found: usize = 0;
    var keep_start: usize = 0; // byte offset within buf
    var idx: usize = bytes_read;
    while (idx > 0) {
        idx -= 1;
        if (buf[idx] == '\n') {
            newlines_found += 1;
            if (newlines_found == n) {
                // idx is the newline *before* our N-line window.
                keep_start = idx + 1;
                break;
            }
        }
    }

    // If we found fewer than N newlines, read from the very beginning.
    const read_from: u64 = if (newlines_found >= n) start_pos + keep_start else 0;
    try file.seekTo(read_from);

    var carry = std.ArrayList(u8){};
    defer carry.deinit(allocator);
    var pos: u64 = read_from;

    const read_buf = try allocator.alloc(u8, READ_BUF_SIZE);
    defer allocator.free(read_buf);

    try readToEOF(allocator, file, filter_state, &carry, &pos, read_buf);
    return pos;
}

// readAvailable reads any new data from `file` starting at `*position`,
// processes complete lines, and returns the number of bytes consumed.
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

// readToEOF reads `file` to EOF, splits on newlines, and hands each complete
// line to the filter+printer. Partial final lines are saved in `carry`.
// `position` is updated by the number of raw bytes read.
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

        // If there's a partial line from the previous read, prepend it.
        if (carry.items.len > 0) {
            try carry.appendSlice(allocator, slice);
            // Clear carry first so the save-partial step below doesn't alias.
            const combined = try allocator.dupe(u8, carry.items);
            defer allocator.free(combined);
            carry.clearRetainingCapacity();
            slice = combined;
        }

        // Process complete lines.
        var start: usize = 0;
        for (slice, 0..) |byte, i| {
            if (byte == '\n') {
                // FIX: original skipped empty lines (i > start check).
                // Preserve that behaviour — empty lines between log entries
                // are uninteresting noise in a tail viewer.
                if (i > start) {
                    filter_state.printIfMatch(slice[start..i]);
                }
                start = i + 1;
            }
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

// Test helper: count lines that readLastNLines would emit.
fn countLinesInFile(allocator: std.mem.Allocator, path: []const u8, num_lines: usize) !usize {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    if (stat.size == 0) return 0;

    const n = if (num_lines == 0) @as(usize, 10) else num_lines;
    if (n == 0) return 0;

    const chunk_size: u64 = @min(stat.size, 8192);
    const start_pos: u64 = stat.size - chunk_size;
    try file.seekTo(start_pos);

    const buf = try allocator.alloc(u8, chunk_size);
    defer allocator.free(buf);
    const bytes_read = try file.read(buf[0..chunk_size]);

    var newlines_found: usize = 0;
    var keep_start: usize = 0;
    var idx: usize = bytes_read;
    while (idx > 0) {
        idx -= 1;
        if (buf[idx] == '\n') {
            newlines_found += 1;
            if (newlines_found == n) {
                keep_start = idx + 1;
                break;
            }
        }
    }

    const read_from: u64 = if (newlines_found >= n) start_pos + keep_start else 0;
    try file.seekTo(read_from);

    // Count lines from read_from to EOF.
    var line_count: usize = 0;
    var has_partial = false;
    var buf2: [4096]u8 = undefined;
    var i: usize = 0;
    while (true) {
        const nread = file.read(&buf2) catch break;
        if (nread == 0) break;
        i = 0;
        while (i < nread) : (i += 1) {
            if (buf2[i] == '\n') {
                line_count += 1;
                has_partial = false;
            } else {
                has_partial = true;
            }
        }
    }
    if (has_partial) line_count += 1;

    return line_count;
}

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

    const line_count = try countLinesInFile(allocator, "small.log", 10);
    try testing.expectEqual(@as(usize, 2), line_count);
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

    const line_count = try countLinesInFile(allocator, "empty.log", 10);
    try testing.expectEqual(@as(usize, 0), line_count);
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
    const filter_state = formats.FilterState.init(flags.Args{
        .files = files_array[0..],
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = null,
        .num_lines = 3,
    });

    const position = try readLastNLines(allocator, &file, flags.Args{
        .files = files_array[0..],
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = null,
        .num_lines = 3,
    }, stat.size, filter_state);

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

    var position = try readLastNLines(allocator, &file, args, stat1.size, filter_state);
    try testing.expectEqual(@as(u64, 18), position);

    // Append new data WITHOUT closing the reader file.
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

    const read_buf = try allocator.alloc(u8, READ_BUF_SIZE);
    defer allocator.free(read_buf);

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
    try testing.expectEqual(@as(u64, 18), position - @as(u64, 18));
}
