const std = @import("std");
const flags = @import("flags/flags.zig");
const reader = @import("reader/reader.zig");

pub fn main() !void {
    // Use GPA as the backing allocator for better performance with small allocations.
    // page_allocator would be inefficient here as it allocates minimum 4KB per call.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("memory leak detected", .{});
        }
    }
    const allocator = gpa.allocator();

    // Parse command-line arguments.
    // The Args struct owns its memory and must be freed.
    var args = flags.parseArgs(allocator) catch |err| {
        printError(err);
        flags.printHelp();
        std.process.exit(1);
    };
    defer args.deinit(allocator);

    if (args.help) {
        flags.printHelp();
        return;
    }

    // Validate that at least one file was provided.
    // This check is redundant if parseArgs already enforces it,
    // but provides a clearer error message.
    if (args.files.len == 0) {
        std.debug.print("zlrd: no input files\n\n", .{});
        flags.printHelp();
        std.process.exit(1);
    }

    // Process files with optimal memory management strategy.
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
    // Tail mode requires persistent memory across the program lifetime,
    // so we use a single arena regardless of file count.
    if (args.tail_mode) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        try reader.readLogs(arena.allocator(), args);
        return;
    }

    // For a single file, avoid the overhead of creating multiple arenas.
    if (args.files.len == 1) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        try reader.readLogs(arena.allocator(), args);
        return;
    }

    // For multiple files, process each in its own arena to release memory
    // after each file is processed. This prevents memory accumulation.
    for (args.files) |file_path| {
        try processFileWithArena(allocator, file_path, args);
    }
}

/// Process a single file in an isolated arena allocator.
///
/// Memory allocated during file processing is automatically freed when
/// the arena is deinitialized, preventing memory accumulation across files.
fn processFileWithArena(
    base_allocator: std.mem.Allocator,
    file_path: []const u8,
    args: flags.Args,
) !void {
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();

    // Create a modified args struct with only the current file.
    // This allows reusing the readLogs function while processing one file at a time.
    var single_file = [_][]const u8{file_path};
    var single_file_args = args;
    single_file_args.files = single_file[0..];

    try reader.readLogs(arena.allocator(), single_file_args);
}

/// Print user-friendly error messages to stderr.
///
/// Maps common errors to human-readable messages and falls back
/// to the error name for unknown errors.
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

    std.debug.print("zlrd: {s}\n", .{msg});
}

// Future optimization ideas (commented out for now):
//
// 1. Buffered writer for stdout:
//    In Zig 0.15.2, bufferedWriter moved to std.io.BufferedWriter
//    Usage: var bw = std.io.BufferedWriter(4096, @TypeOf(stdout)){.unbuffered_writer = stdout};
//    This reduces system calls when writing many lines.
//
// 2. Parallel file processing for independent files:
//    Use std.Thread.Pool to process multiple files concurrently.
//    This would significantly speed up processing of many small files.
//
// 2. Memory-mapped files for large logs (>10MB):
//    Use std.os.mmap instead of reading entire file into memory.
//    This reduces memory usage and can be faster for large files.
//
// 3. Statistics tracking:
//    Add optional --stats flag to report:
//    - Files processed
//    - Lines read/matched
//    - Bytes processed
//    - Throughput (MB/s)
//
// 4. Signal handling for tail mode:
//    Catch SIGINT (Ctrl+C) for graceful shutdown and cleanup.
//    Use std.os.sigaction with atomic flag for thread-safe exit.
//
// Example skeleton for parallel processing:
//
// fn processFilesParallel(
//     allocator: std.mem.Allocator,
//     args: flags.Args,
//     writer: anytype,
// ) !void {
//     var pool: std.Thread.Pool = undefined;
//     try pool.init(.{ .allocator = allocator });
//     defer pool.deinit();
//
//     var wait_group = std.Thread.WaitGroup{};
//
//     for (args.files) |file_path| {
//         wait_group.start();
//         try pool.spawn(processFileConcurrent, .{
//             allocator,
//             file_path,
//             args,
//             writer,
//             &wait_group,
//         });
//     }
//
//     pool.waitAndWork(&wait_group);
// }
