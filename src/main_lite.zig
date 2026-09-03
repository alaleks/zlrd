//! Reader-only entry point (`zlrd-lite`). Same argument parser as the full
//! `zlrd`, but does not link agent / journal / kernel / sidecar code.
//! If the user passes `--agent`, we print a clear error pointing to the full
//! binary rather than silently ignoring the flag.

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
    _ = opts.preopens;
    const allocator = opts.gpa;
    const io = opts.io;

    // Resolve terminal capabilities before anything is written. stdout and
    // stderr get separate answers on purpose: `zlrd-lite app.log | less`
    // leaves stderr on the terminal, and an error message there should still
    // be legible.
    const stdout = std.Io.File.stdout();
    const stderr_file = std.Io.File.stderr();
    const vt_ok = reader.theme_mod.prepareConsole(stdout.handle);
    const out_env = reader.theme_mod.fromMap(opts.environ_map, vt_ok and (stdout.isTty(io) catch false));
    const err_env = reader.theme_mod.fromMap(opts.environ_map, vt_ok and (stderr_file.isTty(io) catch false));

    var parsed_args = flags.parseArgs(allocator, opts.minimal.args) catch |err| {
        // `--color` is unavailable when parsing is what failed, so this one
        // path falls back to plain auto-detection.
        const early = reader.theme_mod.resolve(err_env, .auto);
        fatal(io, &early, parseErrorMessage(err), "run zlrd-lite --help for usage");
        std.process.exit(1);
    };
    defer parsed_args.deinit(allocator);

    const choice: reader.theme_mod.ColorChoice = switch (parsed_args.color) {
        .auto => .auto,
        .always => .always,
        .never => .never,
    };
    const th = reader.theme_mod.resolve(out_env, choice);
    const err_th = reader.theme_mod.resolve(err_env, choice);

    if (parsed_args.version) {
        printVersion(io, &th);
        return;
    }

    if (parsed_args.help) {
        flags.printHelpLite(th.colored);
        return;
    }

    // zlrd-lite is the reader-only build. Fail fast if the user asked for
    // features that only exist in the full binary.
    if (isAgentModeRequested(parsed_args)) {
        fatal(
            io,
            &err_th,
            "agent mode is not available in zlrd-lite",
            "install the full binary: brew install alaleks/tap/zlrd  (or apt install zlrd)",
        );
        std.process.exit(1);
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
            fatal(io, &err_th, "could not read current directory", "check read permissions: ls -la .");
            std.process.exit(1);
        };
        if (discovered_files.len == 0) {
            fatal(io, &err_th, "no *.log or *.log.gz files found in current directory", "specify a file: zlrd-lite app.log");
            std.process.exit(1);
        }
        parsed_args.files = discovered_files;
    } else {
        var all_ok = true;
        for (parsed_args.files) |path| {
            if (parsed_args.tail_mode and gzip.isGzip(path)) {
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "{s}: tail mode is not supported for .gz files", .{path}) catch
                    "tail mode is not supported for .gz files";
                fatal(io, &err_th, msg, "decompress first: gunzip file.log.gz");
                all_ok = false;
                continue;
            }

            std.Io.Dir.cwd().access(io, path, .{}) catch |err| {
                var buf: [512]u8 = undefined;
                const msg = switch (err) {
                    error.FileNotFound => std.fmt.bufPrint(&buf, "{s}: no such file", .{path}) catch "no such file",
                    error.AccessDenied => std.fmt.bufPrint(&buf, "{s}: permission denied", .{path}) catch "permission denied",
                    else => std.fmt.bufPrint(&buf, "{s}: {s}", .{ path, @errorName(err) }) catch "unexpected error",
                };
                const hint: ?[]const u8 = switch (err) {
                    error.AccessDenied => "check permissions or try with sudo",
                    else => null,
                };
                fatal(io, &err_th, msg, hint);
                all_ok = false;
            };
        }
        if (!all_ok) std.process.exit(1);
    }

    if (!parsed_args.output_json and !parsed_args.tail_mode and th.colored) printBanner(io, &th);
    processFiles(allocator, parsed_args, &th) catch |err| {
        fatal(io, &err_th, runtimeErrorMessage(err), null);
        std.process.exit(1);
    };
}

/// Returns true if any agent-only flag was set. `agent_mode` alone catches the
/// common case; we also check the auxiliary flags so `--metrics-token foo`
/// without `--agent` fails loudly instead of being silently discarded.
fn isAgentModeRequested(args: flags.Args) bool {
    if (args.agent_mode) return true;
    if (args.metrics_token != null) return true;
    if (args.listen != null) return true;
    if (args.alert_error_rate != null) return true;
    if (args.alert_regexes.len > 0) return true;
    if (args.alert_first_seen) return true;
    if (args.alert_silence != null) return true;
    if (args.alert_stderr) return true;
    if (args.alert_file != null) return true;
    if (args.alert_webhooks.len > 0) return true;
    if (args.webhook_headers.len > 0) return true;
    if (args.alert_exit_on_alert) return true;
    if (args.kernel_probes) return true;
    if (args.services.len > 0) return true;
    if (args.crash_markers.len > 0) return true;
    if (args.journal_units.len > 0) return true;
    if (args.sidecar_url != null) return true;
    if (args.sidecar_headers.len > 0) return true;
    return false;
}

/// Styled fatal error. `hint` is an optional follow-up line in muted colour.
///
/// Takes the stderr theme rather than hard-coding escapes: error output is
/// the most likely thing to be redirected into a file, a CI log or a bug
/// report, and it used to emit 24-bit colour there regardless of `NO_COLOR`
/// or whether stderr was even a terminal.
fn fatal(io: std.Io, th: *const reader.Theme, msg: []const u8, hint: ?[]const u8) void {
    const e = std.Io.File.stderr();
    const p = th.palette;
    const cross = if (th.glyphs.unicode_ok) "\u{2717}" else "x";
    const arrow = if (th.glyphs.unicode_ok) "\u{2192}" else "->";

    e.writeStreamingAll(io, "\n") catch {};
    if (th.colored) e.writeStreamingAll(io, "\x1b[1m") catch {};
    e.writeStreamingAll(io, p.level[@intFromEnum(flags.Level.Error)]) catch {};
    e.writeStreamingAll(io, cross) catch {};
    e.writeStreamingAll(io, p.reset) catch {};
    e.writeStreamingAll(io, "  ") catch {};
    e.writeStreamingAll(io, msg) catch {};
    e.writeStreamingAll(io, "\n") catch {};
    if (hint) |h| {
        e.writeStreamingAll(io, p.muted) catch {};
        e.writeStreamingAll(io, "   ") catch {};
        e.writeStreamingAll(io, arrow) catch {};
        e.writeStreamingAll(io, " ") catch {};
        e.writeStreamingAll(io, h) catch {};
        e.writeStreamingAll(io, p.reset) catch {};
        e.writeStreamingAll(io, "\n") catch {};
    }
    e.writeStreamingAll(io, "\n") catch {};
}

/// `--version`. Same palette treatment as the banner, so `zlrd --version`
/// piped into a file no longer carries escape bytes.
fn printVersion(io: std.Io, th: *const reader.Theme) void {
    const w = std.Io.File.stdout();
    const p = th.palette;
    var buf: [256]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "{s}{s}z{s}l{s}r{s}d{s}{s}", .{
        p.dim,      p.json_key, p.json_bool_null, p.muted,
        p.json_key, p.reset,    "-lite",
    }) catch return;
    w.writeStreamingAll(io, name) catch {};
    w.writeStreamingAll(io, " " ++ build_options.version ++ "\n\n") catch {};
    if (th.colored) w.writeStreamingAll(io, "\x1b[4m") catch {};
    w.writeStreamingAll(io, "https://github.com/alaleks/zlrd") catch {};
    w.writeStreamingAll(io, p.reset) catch {};
    w.writeStreamingAll(io, "\n\n") catch {};
    w.writeStreamingAll(io, p.dim) catch {};
    const star = if (th.glyphs.unicode_ok) "\u{2b50} Star if you like it \u{b7} PRs welcome!" else "Star if you like it - PRs welcome!";
    w.writeStreamingAll(io, star) catch {};
    w.writeStreamingAll(io, p.reset) catch {};
    w.writeStreamingAll(io, "\n") catch {};
}

fn printBanner(io: std.Io, th: *const reader.Theme) void {
    const w = std.Io.File.stdout();
    const p = th.palette;
    const dim = p.dim;
    const rst = p.reset;
    const ul = if (th.colored) "\x1b[4m" else "";
    const ver = build_options.version;

    // Drawn from the resolved palette so the banner degrades with the
    // terminal instead of assuming 24-bit colour.
    var name_buf: [256]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}{s}z{s}l{s}r{s}d{s}{s}-lite", .{
        p.dim,      p.json_key, p.json_bool_null, p.muted,
        p.json_key, p.reset,    p.dim,
    }) catch return;

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
    th: *const reader.Theme,
) !void {
    if (parsed_args.tail_mode) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        try reader.readLogs(arena.allocator(), parsed_args, th, null);
        return;
    }

    // The `--since` anchor is found here, over the whole file list, because
    // the loop below hands `readLogs` one file at a time. Computed down there
    // it would be per-file, and a rotated log would show its own last five
    // minutes as if they were recent.
    const since_cut = if (parsed_args.since_ms) |window|
        reader.sinceCutoff(parsed_args.files, window)
    else
        null;

    if (parsed_args.files.len == 1) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        try reader.readLogs(arena.allocator(), parsed_args, th, since_cut);
        return;
    }

    for (parsed_args.files) |file_path| {
        try processFileWithArena(allocator, file_path, parsed_args, th, since_cut);
    }
}

fn processFileWithArena(
    base_allocator: std.mem.Allocator,
    file_path: []const u8,
    parsed_args: flags.Args,
    th: *const reader.Theme,
    since_cut: ?reader.Cutoff,
) !void {
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();

    var single_file = [_][]const u8{file_path};
    var single_file_args = parsed_args;
    single_file_args.files = single_file[0..];

    try reader.readLogs(arena.allocator(), single_file_args, th, since_cut);
}

fn parseErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownArgument => "unknown argument",
        error.InvalidArgument => "invalid argument",
        error.InvalidNumLines => "invalid value for --num-lines (must be a positive integer)",
        error.InvalidLevel => "invalid log level (valid: trace debug info warn error fatal panic)",
        error.InvalidAggregateMode => "invalid aggregate mode (valid: exact level-message json-message normalized)",
        error.InvalidOutputMode => "invalid output mode (valid: json)",
        error.InvalidColorChoice => "invalid --color value (valid: auto, always, never)",
        error.MissingColor => "--color requires a value (auto, always, never)",
        error.MissingFile => "missing value for --file",
        error.MissingSearch => "missing value for --search",
        error.MissingLevel => "missing value for --level",
        error.MissingDate => "missing value for --date",
        error.MissingNumLines => "missing value for --num-lines",
        error.MissingAggregateMode => "missing value for --aggregate-mode",
        error.MissingFromTime => "missing value for --from",
        error.MissingToTime => "missing value for --to",
        error.MissingSince => "missing value for --since",
        error.InvalidSince => "invalid --since window (expected 5m, 90s, 2h, 7d)",
        error.MissingOutput => "missing value for --output",
        else => @errorName(err),
    };
}

fn runtimeErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "file not found",
        error.AccessDenied => "permission denied",
        error.IsDir => "path is a directory, not a file",
        error.NotOpenForReading => "file is not open for reading",
        error.OutOfMemory => "out of memory",
        error.LineTooLong => "log line exceeds 4 MiB limit (likely a binary file or corrupted input)",
        else => @errorName(err),
    };
}
