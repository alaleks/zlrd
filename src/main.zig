const std = @import("std");
const flags = @import("flags/flags.zig");
const reader = @import("reader/reader.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const args = flags.parseArgs(arena.allocator()) catch |err| {
        std.debug.print("zlrd: {s}\n\n", .{@errorName(err)});
        flags.printHelp();
        return;
    };

    if (args.help) {
        flags.printHelp();
        return;
    }

    reader.readLogs(arena.allocator(), args) catch |err| {
        printError(err);
        std.process.exit(1);
    };
}

fn printError(err: anyerror) void {
    switch (err) {
        error.FileNotFound => {
            std.debug.print("zlrd: file not found\n", .{});
        },
        error.AccessDenied => {
            std.debug.print("zlrd: permission denied\n", .{});
        },
        else => {
            std.debug.print("zlrd: {s}\n", .{@errorName(err)});
        },
    }
}
