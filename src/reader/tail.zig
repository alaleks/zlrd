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
