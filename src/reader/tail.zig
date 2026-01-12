const std = @import("std");
const flags = @import("../flags/flags.zig");
const formats = @import("formats.zig");

pub fn follow(
    allocator: std.mem.Allocator,
    args: flags.Args,
) !void {
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    while (true) {
        for (args.files) |path| {
            try readAndFilter(allocator, path, args, &seen);
        }
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }
}

fn readAndFilter(
    allocator: std.mem.Allocator,
    path: []const u8,
    args: flags.Args,
    seen: *std.AutoHashMap(u64, void),
) !void {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var buf: [8192]u8 = undefined;
    var carry = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer carry.deinit(allocator);

    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;

        var slice = buf[0..n];

        if (carry.items.len != 0) {
            try carry.appendSlice(allocator, slice);
            slice = carry.items;
        }

        var it = std.mem.splitScalar(u8, slice, '\n');
        while (it.next()) |line| {
            if (it.peek() == null and slice[slice.len - 1] != '\n') {
                carry.clearRetainingCapacity();
                try carry.appendSlice(allocator, line);
                break;
            }

            const h = std.hash.Wyhash.hash(0, line);
            if (!seen.contains(h)) {
                try seen.put(h, {});
                formats.handleLine(line, args);
            }
        }
    }
}
