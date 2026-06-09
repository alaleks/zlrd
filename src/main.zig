const std = @import("std");
const flags = @import("flags");
const reader = @import("reader/reader.zig");
const gzip = @import("reader/gzip.zig");
const build_options = @import("build_options");

pub fn main(opts: struct {
    minimal: struct {
        args: std.process.Args,
        environ: std.process.Environ,
    },
    arena: *std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    preopens: std.process.Preopens,
}) !void {
    _ = opts.arena;
    _ = opts.environ_map;
    _ = opts.preopens;
    const allocator = opts.gpa;
    const io = opts.io;

    var parsed_args = flags.parseArgs(allocator, opts.minimal.args) catch |err| {
        printError(io, err);
        flags.printHelp();
        std.process.exit(1);
    };
    defer parsed_args.deinit(allocator);

    if (parsed_args.version) {
        const ver_name = "\x1b[2m\x1b[38;2;88;166;255mz\x1b[38;2;63;185;80ml\x1b[38;2;227;179;65mr\x1b[38;2;248;81;73md\x1b[0m";
        std.Io.File.stdout().writeStreamingAll(io, ver_name ++ " " ++ build_options.version ++ "\n\n") catch {};
        std.Io.File.stdout().writeStreamingAll(io, "\x1b[4mhttps://github.com/alaleks/zlrd\x1b[0m\n\n") catch {};
        std.Io.File.stdout().writeStreamingAll(io, "\x1b[2m⭐ Star if you like it · PRs welcome!\x1b[0m\n") catch {};
        return;
    }

    if (parsed_args.help) {
        flags.printHelp();
        return;
    }

    var discovered_files: [][]const u8 = &.{};
    defer {
        if (discovered_files.len > 0) {
            parsed_args.files = &.{};
            for (discovered_files) |p| allocator.free(p);
            allocator.free(discovered_files);
        }
    }

    if (parsed_args.files.len == 0) {
        discovered_files = findLogFiles(allocator, io) catch {
            writeStderr(io, "zlrd: could not read current directory\n");
            std.process.exit(1);
        };
        if (discovered_files.len == 0) {
            writeStderr(io, "zlrd: no *.log or *.log.gz files found in current directory\n");
            std.process.exit(1);
        }
        parsed_args.files = discovered_files;
    } else {
        var all_ok = true;
        for (parsed_args.files) |path| {
            if (parsed_args.tail_mode and gzip.isGzip(path)) {
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "zlrd: {s}: tail mode is not supported for .gz files\n", .{path}) catch
                    "zlrd: tail mode is not supported for .gz files\n";
                writeStderr(io, msg);
                all_ok = false;
                continue;
            }

            std.Io.Dir.cwd().access(io, path, .{}) catch |err| {
                var buf: [512]u8 = undefined;
                const msg = switch (err) {
                    error.FileNotFound => std.fmt.bufPrint(&buf, "zlrd: {s}: no such file\n", .{path}) catch "zlrd: no such file\n",
                    error.AccessDenied => std.fmt.bufPrint(&buf, "zlrd: {s}: permission denied\n", .{path}) catch "zlrd: permission denied\n",
                    else => std.fmt.bufPrint(&buf, "zlrd: {s}: {s}\n", .{ path, @errorName(err) }) catch "zlrd: error\n",
                };
                writeStderr(io, msg);
                all_ok = false;
            };
        }
        if (!all_ok) std.process.exit(1);
    }

    if (!parsed_args.output_json and !parsed_args.tail_mode) {
        if (std.Io.File.stdout().isTty(io) catch false) printBanner(io);
    }
    processFiles(allocator, parsed_args) catch |err| {
        printError(io, err);
        std.process.exit(1);
    };
}

fn writeStderr(io: std.Io, msg: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

fn printBanner(io: std.Io) void {
    const w = std.Io.File.stdout();
    const dim = "\x1b[2m";
    const rst = "\x1b[0m";
    const ul = "\x1b[4m";
    const ver = build_options.version;

    // z=DEBUG(blue) l=INFO(green) r=WARN(yellow) d=ERROR(red)
    const name = "\x1b[2m\x1b[38;2;88;166;255mz\x1b[38;2;63;185;80ml\x1b[38;2;227;179;65mr\x1b[38;2;248;81;73md\x1b[0m\x1b[2m";

    var buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&buf, "{s} {s}\n", .{ name, ver }) catch return;
    w.writeStreamingAll(io, header) catch {};
    w.writeStreamingAll(io, rst) catch {};
    w.writeStreamingAll(io, "\n") catch {};
    w.writeStreamingAll(io, ul) catch {};
    w.writeStreamingAll(io, "https://github.com/alaleks/zlrd") catch {};
    w.writeStreamingAll(io, rst) catch {};
    w.writeStreamingAll(io, "\n\n") catch {};
    w.writeStreamingAll(io, dim) catch {};
    w.writeStreamingAll(io, "⭐ Star if you like it · PRs welcome!") catch {};
    w.writeStreamingAll(io, rst) catch {};
    w.writeStreamingAll(io, "\n") catch {};
}

fn findLogFiles(allocator: std.mem.Allocator, io: std.Io) ![][]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);

    var list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    errdefer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".log") and
            !std.mem.endsWith(u8, entry.name, ".log.gz")) continue;

        try list.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    return list.toOwnedSlice(allocator);
}

fn processFiles(
    allocator: std.mem.Allocator,
    parsed_args: flags.Args,
) !void {
    if (parsed_args.tail_mode) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        try reader.readLogs(arena.allocator(), parsed_args);
        return;
    }

    if (parsed_args.files.len == 1) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        try reader.readLogs(arena.allocator(), parsed_args);
        return;
    }

    for (parsed_args.files) |file_path| {
        try processFileWithArena(allocator, file_path, parsed_args);
    }
}

fn processFileWithArena(
    base_allocator: std.mem.Allocator,
    file_path: []const u8,
    parsed_args: flags.Args,
) !void {
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();

    var single_file = [_][]const u8{file_path};
    var single_file_args = parsed_args;
    single_file_args.files = single_file[0..];

    try reader.readLogs(arena.allocator(), single_file_args);
}

fn printError(io: std.Io, err: anyerror) void {
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
        error.InvalidAggregateMode => "invalid aggregate mode",
        error.InvalidOutputMode => "invalid output mode",
        error.UnknownArgument => "unknown argument",
        error.MissingSearch => "missing search value",
        error.MissingLevel => "missing level value",
        error.MissingDate => "missing date value",
        error.MissingNumLines => "missing number of lines",
        error.MissingAggregateMode => "missing aggregate mode",
        error.MissingFromTime => "missing from time value",
        error.MissingToTime => "missing to time value",
        error.MissingOutput => "missing output mode",
        else => @errorName(err),
    };

    std.Io.File.stderr().writeStreamingAll(io, "zlrd: ") catch {};
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
    std.Io.File.stderr().writeStreamingAll(io, "\n") catch {};
}
