const std = @import("std");
const flags = @import("flags/flags.zig");
const reader = @import("reader/reader.zig");
const build_options = @import("build_options");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) std.log.err("memory leak detected", .{});
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

    // No files given — discover *.log in the current directory.
    //
    // Ownership note: discovered_files owns the heap strings.
    // args.files may point to the same slice — before freeing discovered_files
    // we reset args.files to &.{} so that the subsequent args.deinit defer
    // (which runs after this one in LIFO order) does not double-free.
    var discovered_files: [][]const u8 = &.{};
    defer {
        if (discovered_files.len > 0) {
            args.files = &.{}; // prevent args.deinit from freeing this
            for (discovered_files) |p| allocator.free(p);
            allocator.free(discovered_files);
        }
    }

    if (args.files.len == 0) {
        discovered_files = findLogFiles(allocator) catch {
            std.fs.File.stderr().writeAll("zlrd: could not read current directory\n") catch {};
            std.process.exit(1);
        };
        if (discovered_files.len == 0) {
            std.fs.File.stderr().writeAll("zlrd: no *.log files found in current directory\n") catch {};
            std.process.exit(1);
        }
        args.files = discovered_files;
    } else {
        // Files were explicitly provided — verify each one exists and is readable.
        var all_ok = true;
        for (args.files) |path| {
            std.fs.cwd().access(path, .{}) catch |err| {
                var buf: [512]u8 = undefined;
                const msg = switch (err) {
                    error.FileNotFound => std.fmt.bufPrint(&buf, "zlrd: {s}: no such file\n", .{path}) catch "zlrd: no such file\n",
                    error.AccessDenied => std.fmt.bufPrint(&buf, "zlrd: {s}: permission denied\n", .{path}) catch "zlrd: permission denied\n",
                    else => std.fmt.bufPrint(&buf, "zlrd: {s}: {s}\n", .{ path, @errorName(err) }) catch "zlrd: error\n",
                };
                std.fs.File.stderr().writeAll(msg) catch {};
                all_ok = false;
            };
        }
        if (!all_ok) std.process.exit(1);
    }

    processFiles(allocator, args) catch |err| {
        printError(err);
        std.process.exit(1);
    };
}

/// Return sorted list of *.log files in the current directory.
/// Caller owns the returned slice and each string within it.
fn findLogFiles(allocator: std.mem.Allocator) ![][]const u8 {
    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer dir.close();

    // In Zig 0.15.2, ArrayList.init(gpa) does not exist — use empty init
    // and pass the allocator explicitly to every method.
    var list = std.ArrayList([]const u8){};
    errdefer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".log")) continue;
        try list.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    return list.toOwnedSlice(allocator);
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
