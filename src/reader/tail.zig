const std = @import("std");
const flags = @import("../flags/flags.zig");
const formats = @import("formats.zig");

/// Follows files and outputs new, unique lines as they appear (like `tail -f`).
/// Uses a hash set to track previously seen lines and avoid duplicates.
pub fn follow(
    allocator: std.mem.Allocator,
    args: flags.Args,
) !void {
    // Track seen lines using a hash set for deduplication
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    // Main follow loop - runs indefinitely
    while (true) {
        for (args.files) |path| {
            try readAndFilter(allocator, path, args, &seen);
        }
        // Sleep to avoid busy-waiting (500ms interval)
        std.time.sleep(std.time.ns_per_ms * 500);
    }
}

/// Reads a file, splits into lines, and outputs only unique new lines.
/// Maintains partial line carry-over between reads to handle line fragmentation.
fn readAndFilter(
    allocator: std.mem.Allocator,
    path: []const u8,
    args: flags.Args,
    seen: *std.AutoHashMap(u64, void),
) !void {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // Buffer for reading file chunks
    var buf: [8192]u8 = undefined;

    // Buffer for carrying over partial lines between reads
    var carry = std.ArrayList(u8).init(allocator);
    defer carry.deinit();

    while (true) {
        const bytes_read = try file.read(&buf);
        if (bytes_read == 0) break; // EOF reached

        var slice = buf[0..bytes_read];

        // If we have a partial line from previous read, prepend it
        if (carry.items.len > 0) {
            try carry.appendSlice(slice);
            slice = carry.items;
        }

        // Split by newlines and process complete lines
        var line_iter = std.mem.splitScalar(u8, slice, '\n');

        while (line_iter.next()) |line| {
            // Check if this is a partial line at the end of buffer
            if (line_iter.peek() == null and slice[slice.len - 1] != '\n') {
                // Save partial line for next read
                carry.clearRetainingCapacity();
                try carry.appendSlice(line);
                break;
            }

            // Hash line for deduplication
            const hash = std.hash.Wyhash.hash(0, line);

            // Only process if we haven't seen this line before
            if (!seen.contains(hash)) {
                try seen.put(hash, {});
                try formats.handleLine(line, args);
            }
        }

        // If we processed all data, clear carry for next iteration
        if (carry.items.ptr != slice.ptr) {
            carry.clearRetainingCapacity();
        }
    }
}
