const std = @import("std");
const flags = @import("../flags/flags.zig");
const formats = @import("formats.zig");
const tail = @import("tail.zig");

/// Reads log files based on command line arguments and mode selection.
/// In tail mode (-f), follows files continuously for new entries.
/// In normal mode, reads and processes each file once.
pub fn readLogs(
    allocator: std.mem.Allocator,
    args: flags.Args,
) !void {
    // Tail mode: follow files continuously for new entries
    if (args.tail_mode) {
        try tail.follow(allocator, args);
        return;
    }

    // Normal mode: read and process each file once
    for (args.files) |path| {
        try formats.readStreaming(allocator, path, args);
    }
}
