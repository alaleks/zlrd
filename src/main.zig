const std = @import("std");
const flags = @import("flags/flags.zig");
const reader = @import("reader/reader.zig");
const build_options = @import("build_options");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("memory leak detected", .{});
        }
    }
    const allocator = gpa.allocator();

    var args = flags.parseArgs(allocator) catch |err| {
        printError(err);
        flags.printHelp();
        std.process.exit(1);
    };
    defer args.deinit(allocator);

    if (args.version) {
        std.fs.File.stdout().writeAll("zlrd " ++ build_options.version ++ "\n") catch {};
        return;
    }

    if (args.help) {
        flags.printHelp();
        return;
    }

    if (args.files.len == 0) {
        std.fs.File.stderr().writeAll("zlrd: no input files\n\n") catch {};
        flags.printHelp();
        std.process.exit(1);
    }

    processFiles(allocator, args) catch |err| {
        printError(err);
        std.process.exit(1);
    };
}

/// Process log files with memory-efficient strategy based on mode and file count.
///
/// Strategy selection:
/// - Single file or tail mode: Use one arena for the entire operation
/// - Multiple files (no tail): Use separate arena per file to keep memory usage bounded
///
/// This approach ensures memory usage is O(largest_file) rather than O(sum_of_all_files).
fn processFiles(
    allocator: std.mem.Allocator,
    args: flags.Args,
) !void {
    if (args.tail_mode) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        try reader.readLogs(arena.allocator(), args);
        return;
    }

    if (args.files.len == 1) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        try reader.readLogs(arena.allocator(), args);
        return;
    }

    for (args.files) |file_path| {
        try processFileWithArena(allocator, file_path, args);
    }
}

/// Process a single file in an isolated arena allocator.
fn processFileWithArena(
    base_allocator: std.mem.Allocator,
    file_path: []const u8,
    args: flags.Args,
) !void {
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();

    var single_file = [_][]const u8{file_path};
    var single_file_args = args;
    single_file_args.files = single_file[0..];

    try reader.readLogs(arena.allocator(), single_file_args);
}

/// Print user-friendly error messages to stderr.
fn printError(err: anyerror) void {
    const msg = switch (err) {
        error.FileNotFound => "file not found",
        error.AccessDenied => "access denied",
        error.IsDir => "is a directory",
        error.NotOpenForReading => "not open for reading",
        error.OutOfMemory => "out of memory",
        error.InvalidArgument => "invalid argument",
        error.InvalidNumLines => "invalid number of lines",
        error.MissingFile => "no input files specified",
        error.InvalidLevel => "invalid log level",
        error.UnknownArgument => "unknown argument",
        error.MissingSearch => "missing search value",
        error.MissingLevel => "missing level value",
        error.MissingDate => "missing date value",
        error.MissingNumLines => "missing number of lines",
        else => @errorName(err),
    };
    std.fs.File.stderr().writeAll("zlrd: ") catch {};
    std.fs.File.stderr().writeAll(msg) catch {};
    std.fs.File.stderr().writeAll("\n") catch {};
}
