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

test "tailFile reads existing file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "test.log",
        .data = "line1\nline2\n",
    });

    const old_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(old_cwd);

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    try std.posix.chdir(tmp_path);
    defer std.posix.chdir(old_cwd) catch unreachable;

    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    var files = [_][]const u8{"test.log"};
    const args = flags.Args{
        .files = files[0..],
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = null,
        .num_lines = 0,
    };

    const read = try tailFile(
        allocator,
        "test.log",
        args,
        &seen,
        false,
    );

    try testing.expect(read);
    try testing.expectEqual(@as(usize, 2), seen.count());
}

test "tailFile follow mode reads appended data" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "follow.log",
        .data = "line1\n",
    });

    const old_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(old_cwd);

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    try std.posix.chdir(tmp_path);
    defer std.posix.chdir(old_cwd) catch unreachable;

    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    var files = [_][]const u8{"follow.log"};
    const args = flags.Args{
        .files = files[0..],
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = null,
        .num_lines = 0,
    };

    _ = try tailFile(
        allocator,
        "follow.log",
        args,
        &seen,
        false,
    );

    try testing.expectEqual(@as(usize, 1), seen.count());

    {
        var file = try std.fs.cwd().openFile(
            "follow.log",
            .{ .mode = .write_only },
        );
        defer file.close();
        try file.seekFromEnd(0);
        try file.writeAll("line2\n");
    }

    const read = try tailFile(
        allocator,
        "follow.log",
        args,
        &seen,
        true,
    );

    try testing.expect(read);
    try testing.expectEqual(@as(usize, 2), seen.count());
}

test "tailFile follow mode ignores missing file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const old_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(old_cwd);

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    try std.posix.chdir(tmp_path);
    defer std.posix.chdir(old_cwd) catch unreachable;

    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    var files = [_][]const u8{"missing.log"};
    const args = flags.Args{
        .files = files[0..],
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = null,
        .num_lines = 0,
    };

    const read = try tailFile(
        allocator,
        "missing.log",
        args,
        &seen,
        true,
    );

    try testing.expect(!read);
    try testing.expectEqual(@as(usize, 0), seen.count());
}

test "tailFile handles empty file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "empty.log",
        .data = "",
    });

    const old_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(old_cwd);

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    try std.posix.chdir(tmp_path);
    defer std.posix.chdir(old_cwd) catch unreachable;

    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    var files = [_][]const u8{"empty.log"};
    const args = flags.Args{
        .files = files[0..],
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = null,
        .num_lines = 0,
    };

    const read = try tailFile(
        allocator,
        "empty.log",
        args,
        &seen,
        false,
    );

    try testing.expect(!read);
    try testing.expectEqual(@as(usize, 0), seen.count());
}

test "tailFile deduplicates identical lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "dup.log",
        .data = "same\nsame\nother\n",
    });

    const old_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(old_cwd);

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    try std.posix.chdir(tmp_path);
    defer std.posix.chdir(old_cwd) catch unreachable;

    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    var files = [_][]const u8{"dup.log"};
    const args = flags.Args{
        .files = files[0..],
        .tail_mode = true,
        .date = null,
        .levels = null,
        .search = null,
        .num_lines = 0,
    };

    _ = try tailFile(
        allocator,
        "dup.log",
        args,
        &seen,
        false,
    );

    try testing.expectEqual(@as(usize, 2), seen.count());
}
