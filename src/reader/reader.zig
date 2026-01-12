const std = @import("std");
const flags = @import("../flags/flags.zig");
const formats = @import("formats.zig");
const tail = @import("tail.zig");

pub fn readLogs(
    allocator: std.mem.Allocator,
    args: flags.Args,
) !void {
    if (args.tail_mode) {
        try tail.follow(allocator, args);
        return;
    }

    for (args.files) |path| {
        try formats.readStreaming(allocator, path, args);
    }
}
