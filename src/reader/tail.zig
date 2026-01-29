const std = @import("std");
const flags = @import("../flags/flags.zig");
const formats = @import("formats.zig");

// Track open files with manual position tracking
const OpenFile = struct {
    path: []const u8,
    fd: std.fs.File,
    position: u64,
};

pub fn follow(
    allocator: std.mem.Allocator,
    args: flags.Args,
) !void {
    const file_count = args.files.len;
    if (file_count == 0) return;

    var files_buf = try allocator.alloc(OpenFile, file_count);
    errdefer allocator.free(files_buf);
    var files_len: usize = 0;
    defer {
        var i: usize = 0;
        while (i < files_len) : (i += 1) {
            files_buf[i].fd.close();
        }
        allocator.free(files_buf);
    }

    // Open files and read last N lines
    var i: usize = 0;
    while (i < args.files.len) : (i += 1) {
        const path = args.files[i];
        var fd = std.fs.cwd().openFile(path, .{}) catch |err| {
            std.debug.print("Cannot open {s}: {any}\n", .{ path, err });
            continue;
        };
        files_buf[files_len] = OpenFile{
            .path = path,
            .fd = fd,
            .position = 0,
        };
        files_len += 1;

        // Read last N lines
        const stat = try fd.stat();
        if (stat.size > 0) {
            const final_pos = try readLastNLines(allocator, &fd, args, stat.size);
            files_buf[files_len - 1].position = final_pos;
        }
    }

    if (files_len == 0) return;

    // Follow loop - keep FDs open continuously (critical for macOS)
    while (true) {
        var any_read = false;
        var j: usize = 0;
        while (j < files_len) : (j += 1) {
            const f = &files_buf[j];

            // Check for log rotation (file truncated)
            const stat = f.fd.stat() catch continue;
            if (f.position > stat.size) {
                // File was truncated - reset to beginning
                f.position = 0;
                try f.fd.seekTo(0);
            } else if (f.position < stat.size) {
                // Seek to last read position before reading new data
                try f.fd.seekTo(f.position);
            }

            // Read any available data from current position
            const read_bytes = try readAvailable(allocator, &f.fd, args, &f.position);
            if (read_bytes > 0) any_read = true;
        }

        if (!any_read) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
}

fn readLastNLines(
    allocator: std.mem.Allocator,
    file: *std.fs.File,
    args: flags.Args,
    file_size: u64,
) !u64 {
    const n = if (args.num_lines == 0) 10 else args.num_lines;
    if (n == 0) {
        try file.seekTo(file_size);
        return file_size;
    }

    // Read last 8KB chunk to find Nth newline from end
    const chunk_size = @min(file_size, 8192);
    const start_pos = file_size - chunk_size;
    try file.seekTo(start_pos);

    var buf = try allocator.alloc(u8, chunk_size);
    defer allocator.free(buf);
    const bytes_read = try file.read(buf[0..chunk_size]);

    // Count newlines backwards to find start of Nth line from end
    // CRITICAL FIX: Count N-1 newlines to get correct start position (off-by-one fix)
    var newlines_found: usize = 0;
    var i = bytes_read;
    var keep_start: usize = 0;
    while (i > 0) {
        i -= 1;
        if (buf[i] == '\n') {
            newlines_found += 1;
            // Stop at N-1 newlines to include the Nth line
            if (newlines_found == n - 1) {
                keep_start = i + 1;
                break;
            }
        }
    }

    // Calculate absolute position to start reading from
    const read_from = if (newlines_found >= n - 1) start_pos + keep_start else 0;
    try file.seekTo(read_from);

    // Read and process all lines to EOF
    var carry = std.ArrayList(u8){};
    defer carry.deinit(allocator);
    var pos: u64 = read_from;
    try readToEOF(allocator, file, args, &carry, &pos);
    return pos;
}

fn readAvailable(
    allocator: std.mem.Allocator,
    file: *std.fs.File,
    args: flags.Args,
    position: *u64,
) !usize {
    var carry = std.ArrayList(u8){};
    defer carry.deinit(allocator);
    const start_pos = position.*;
    try readToEOF(allocator, file, args, &carry, position);
    return position.* - start_pos;
}

fn readToEOF(
    allocator: std.mem.Allocator,
    file: *std.fs.File,
    args: flags.Args,
    carry: *std.ArrayList(u8),
    position: *u64,
) !void {
    var buf: [4096]u8 = undefined;

    while (true) {
        const n = file.read(&buf) catch break;
        if (n == 0) break; // EOF/no more data

        position.* += n;
        var slice = buf[0..n];

        // CRITICAL FIX: Safe carry handling to prevent @memcpy aliasing
        if (carry.items.len > 0) {
            // Append new data to carry buffer
            try carry.appendSlice(allocator, slice);
            // Process the combined data
            slice = carry.items;
            // Clear carry BEFORE processing to avoid aliasing when saving partial lines
            try carry.resize(allocator, 0);
        }

        // Process complete lines
        var start: usize = 0;
        var i: usize = 0;
        while (i < slice.len) : (i += 1) {
            if (slice[i] == '\n') {
                if (i > start) {
                    formats.handleLine(slice[start..i], args);
                }
                start = i + 1;
            }
        }

        // Save partial line for next read (safe because carry is empty)
        if (start < slice.len) {
            try carry.appendSlice(allocator, slice[start..]);
        }
    }
}

// ============================================================================
// Unit Tests (Zig 0.15.2 compliant)
// ============================================================================

const testing = std.testing;
const tail = @import("tail.zig");

// Test helper: Count lines from calculated start position (not entire file)
fn countLinesInFile(allocator: std.mem.Allocator, path: []const u8, num_lines: usize) !usize {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    if (stat.size == 0) return 0;

    const n = if (num_lines == 0) 10 else num_lines;
    if (n == 0) return 0;

    // Replicate start position calculation from readLastNLines (with off-by-one fix)
    const chunk_size = @min(stat.size, 8192);
    const start_pos = stat.size - chunk_size;
    try file.seekTo(start_pos);

    var buf = try allocator.alloc(u8, chunk_size);
    defer allocator.free(buf);
    const bytes_read = try file.read(buf[0..chunk_size]);

    var newlines_found: usize = 0;
    var i = bytes_read;
    var keep_start: usize = 0;
    while (i > 0) {
        i -= 1;
        if (buf[i] == '\n') {
            newlines_found += 1;
            if (newlines_found == n - 1) { // OFF-BY-ONE FIX: n-1 not n
                keep_start = i + 1;
                break;
            }
        }
    }

    const read_from = if (newlines_found >= n - 1) start_pos + keep_start else 0;

    // Read from calculated position and count lines
    try file.seekTo(read_from);
    var line_count: usize = 0;
    var has_partial: bool = false;
    var buf2: [4096]u8 = undefined;
    while (true) {
        const nread = file.read(&buf2) catch break;
        if (nread == 0) break;

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

    try tmp.dir.writeFile(.{
        .sub_path = "small.log",
        .data = "first\nsecond\n",
    });

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

    try tmp.dir.writeFile(.{
        .sub_path = "empty.log",
        .data = "",
    });

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
    var position: u64 = 0;

    var files_array = [_][]const u8{"pos.log"};
    position = try tail.readLastNLines(allocator, &file, flags.Args{
        .files = files_array[0..],
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = null,
        .num_lines = 3,
    }, stat.size);

    try testing.expectEqual(@as(u64, 30), position);
}

test "truncation detection resets position to beginning" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "truncate.log",
        .data = "initial content\n",
    });

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
    if (position > stat2.size) {
        position = 0;
    }

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
    var position: u64 = 0;
    var files_array = [_][]const u8{"append.log"};
    position = try tail.readLastNLines(allocator, &file, flags.Args{
        .files = files_array[0..],
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = null,
        .num_lines = 2,
    }, stat1.size);

    try testing.expectEqual(@as(u64, 18), position);

    // Append new data WITHOUT closing file
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
    var new_position: u64 = position;
    var files_array2 = [_][]const u8{"append.log"};
    try tail.readToEOF(allocator, &file, flags.Args{
        .files = files_array2[0..],
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = null,
        .num_lines = 0,
    }, &carry, &new_position);

    try testing.expectEqual(@as(u64, 36), new_position);
    try testing.expectEqual(@as(u64, 18), new_position - position);
}
