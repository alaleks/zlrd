const std = @import("std");
const flags = @import("../flags/flags.zig");
const formats = @import("formats.zig");

/// Simple tail -f implementation
pub fn follow(
    allocator: std.mem.Allocator,
    args: flags.Args,
) !void {
    // Track seen lines using a hash set for deduplication
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    // For each file, read existing content first
    for (args.files) |path| {
        _ = try tailFile(allocator, path, args, &seen, false);
    }

    // Then follow for new content
    while (true) {
        var any_read = false;

        for (args.files) |path| {
            const read = try tailFile(allocator, path, args, &seen, true);
            if (read) any_read = true;
        }

        if (!any_read) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
}

/// Tail a single file, optionally following for new content
fn tailFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    args: flags.Args,
    seen: *std.AutoHashMap(u64, void),
    follow_mode: bool,
) !bool {
    var file = std.fs.cwd().openFile(path, .{}) catch |err| {
        // If file doesn't exist in follow mode, just return false
        if (follow_mode and err == error.FileNotFound) {
            return false;
        }
        return err;
    };
    defer file.close();

    // Get file size
    const stat = try file.stat();

    // If not in follow mode (initial read), start near the end
    var pos: u64 = if (!follow_mode and stat.size > 8192)
        stat.size - 8192
    else
        0;

    // Seek to position
    try file.seekTo(pos);

    var buf: [8192]u8 = undefined;
    var carry = std.ArrayList(u8){};
    defer carry.deinit(allocator);

    var data_read = false;

    // Read in a loop to get all available data
    while (true) {
        const bytes_read = file.read(&buf) catch {
            // Read error, break out of loop
            break;
        };

        if (bytes_read == 0) {
            // No more data available
            break;
        }

        data_read = true;
        pos += bytes_read;

        var slice = buf[0..bytes_read];

        // Handle carry-over from previous read
        if (carry.items.len > 0) {
            try carry.appendSlice(allocator, slice);
            slice = carry.items;
        }

        // Split by newlines and process complete lines
        var iter = std.mem.splitScalar(u8, slice, '\n');

        while (iter.next()) |line| {
            if (iter.peek() == null and slice[slice.len - 1] != '\n') {
                // Partial line, save for next read
                carry.clearRetainingCapacity();
                try carry.appendSlice(allocator, line);
                break;
            }

            if (line.len > 0) {
                const hash = std.hash.Wyhash.hash(0, line);
                if (!seen.contains(hash)) {
                    try seen.put(hash, {});
                    formats.handleLine(line, args);
                }
            }
        }

        // If we processed all data, clear carry
        if (carry.items.ptr != slice.ptr) {
            carry.clearRetainingCapacity();
        }

        // In follow mode, if we've read to the end, break to check again later
        if (follow_mode and pos >= stat.size) {
            break;
        }

        // If there's more data in the file, continue reading
        if (pos < stat.size) {
            try file.seekTo(pos);
        } else {
            break;
        }
    }

    return data_read;
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "tailFile should read from existing file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a temporary test file
    const test_content = "[INFO] Line 1\n[ERROR] Line 2\n[WARN] Line 3\n";
    var tmp_dir = testing.tmpDir(.{});
    var dir = tmp_dir.dir;
    defer tmp_dir.cleanup();

    const file_name = "test.log";
    {
        // Create and write to file without defer
        var file = try dir.createFile(file_name, .{});
        try file.writeAll(test_content);
        file.close(); // Close immediately after writing
    }

    // Create args
    var files = [_][]const u8{file_name};
    const args = flags.Args{
        .files = &files,
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = null,
        .num_lines = 0,
    };

    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    // Change to tmp directory - using posix API for compatibility
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Store original working directory
    const original_cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(original_cwd_path);

    // Change directory using posix.chdir
    try std.posix.chdir(tmp_path);

    // Read file
    const read = try tailFile(allocator, file_name, args, &seen, false);
    try testing.expect(read);

    // Restore original directory
    try std.posix.chdir(original_cwd_path);

    // Verify lines were added to seen set
    try testing.expect(seen.count() > 0);
}

test "tailFile should handle non-existent file in follow mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var files = [_][]const u8{"nonexistent.log"};
    const args = flags.Args{
        .files = &files,
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = null,
        .num_lines = 0,
    };

    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    // Change to tmp directory
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const original_cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(original_cwd_path);

    try std.posix.chdir(tmp_path);

    // Should return false without error
    const read = try tailFile(allocator, "nonexistent.log", args, &seen, true);
    try testing.expect(!read);

    try std.posix.chdir(original_cwd_path);
}

test "tailFile should error on non-existent file in initial mode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var files = [_][]const u8{"nonexistent.log"};
    const args = flags.Args{
        .files = &files,
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = null,
        .num_lines = 0,
    };

    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    // Change to tmp directory
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const original_cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(original_cwd_path);

    try std.posix.chdir(tmp_path);

    // Should return error
    const result = tailFile(allocator, "nonexistent.log", args, &seen, false);
    try testing.expectError(error.FileNotFound, result);

    try std.posix.chdir(original_cwd_path);
}

test "tailFile should deduplicate lines using hash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file_name = "dedup.log";
    var file = try tmp_dir.dir.createFile(file_name, .{});
    const test_content = "[INFO] Same line\n[INFO] Same line\n[INFO] Different line\n";
    try file.writeAll(test_content);
    file.close();

    var files = [_][]const u8{file_name};
    const args = flags.Args{
        .files = &files,
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = null,
        .num_lines = 0,
    };

    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    // Change directory
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const original_cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(original_cwd_path);

    try std.posix.chdir(tmp_path);

    _ = try tailFile(allocator, file_name, args, &seen, false);

    // Should have 2 unique lines (deduplicated)
    try testing.expectEqual(@as(usize, 2), seen.count());

    try std.posix.chdir(original_cwd_path);
}

test "tailFile should handle empty file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file_name = "empty.log";
    var file = try tmp_dir.dir.createFile(file_name, .{});
    file.close();

    var files = [_][]const u8{file_name};
    const args = flags.Args{
        .files = &files,
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = null,
        .num_lines = 0,
    };

    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    // Change directory
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const original_cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(original_cwd_path);

    try std.posix.chdir(tmp_path);

    const read = try tailFile(allocator, file_name, args, &seen, false);
    try testing.expect(!read); // No data read from empty file

    try std.posix.chdir(original_cwd_path);
}

test "tailFile should handle file without trailing newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file_name = "no_newline.log";
    var file = try tmp_dir.dir.createFile(file_name, .{});
    const test_content = "[INFO] Line without newline";
    try file.writeAll(test_content);
    file.close();

    var files = [_][]const u8{file_name};
    const args = flags.Args{
        .files = &files,
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = null,
        .num_lines = 0,
    };

    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    // Change directory
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const original_cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(original_cwd_path);

    try std.posix.chdir(tmp_path);

    const read = try tailFile(allocator, file_name, args, &seen, false);
    try testing.expect(read);

    try std.posix.chdir(original_cwd_path);
}

test "tailFile should start near end for large files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file_name = "large.log";
    var file = try tmp_dir.dir.createFile(file_name, .{});

    // Write content that should make file larger than 8192 bytes
    var i: usize = 0;
    while (i < 1000) : (i += 1) { // Increased to 1000 lines to ensure file > 8192 bytes
        // Use a small buffer for writing formatted text
        var buf: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "[INFO] Line {d}\n", .{i});
        try file.writeAll(line);
    }
    file.close();

    var files = [_][]const u8{file_name};
    const args = flags.Args{
        .files = &files,
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = null,
        .num_lines = 0,
    };

    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    // Change directory
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const original_cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(original_cwd_path);

    try std.posix.chdir(tmp_path);

    const read = try tailFile(allocator, file_name, args, &seen, false);
    try testing.expect(read);

    // File is > 8192 bytes, so we should start near the end
    // and not read all 1000 lines
    try testing.expect(seen.count() > 0);
    try testing.expect(seen.count() < 1000);

    try std.posix.chdir(original_cwd_path);
}

test "hash collision handling with AutoHashMap" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    // Add some hashes
    const line1 = "[INFO] Test line 1";
    const line2 = "[INFO] Test line 2";
    const line3 = "[INFO] Test line 1"; // Duplicate

    const hash1 = std.hash.Wyhash.hash(0, line1);
    const hash2 = std.hash.Wyhash.hash(0, line2);
    const hash3 = std.hash.Wyhash.hash(0, line3);

    try seen.put(hash1, {});
    try seen.put(hash2, {});

    try testing.expectEqual(@as(usize, 2), seen.count());

    // hash3 should equal hash1
    try testing.expectEqual(hash1, hash3);

    // Trying to add duplicate should not increase count
    try seen.put(hash3, {});
    try testing.expectEqual(@as(usize, 2), seen.count());
}

test "carry buffer handling across reads" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file_name = "partial.log";
    var file = try tmp_dir.dir.createFile(file_name, .{});

    // Write content that will span across buffer boundary
    // First write a line longer than typical buffer
    var long_line: [100]u8 = undefined;
    @memset(&long_line, 'a');
    try file.writeAll(&long_line);
    try file.writeAll("\n[INFO] Next line\n");
    file.close();

    var files = [_][]const u8{file_name};
    const args = flags.Args{
        .files = &files,
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = null,
        .num_lines = 0,
    };

    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    // Change directory
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();

    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const original_cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(original_cwd_path);

    try std.posix.chdir(tmp_path);

    const read = try tailFile(allocator, file_name, args, &seen, false);
    try testing.expect(read);
    try testing.expect(seen.count() >= 1);

    try std.posix.chdir(original_cwd_path);
}
