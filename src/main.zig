const std = @import("std");
const flags = @import("flags");
const agent = @import("agent");
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
    // stderr get separate answers on purpose: `zlrd app.log | less` leaves
    // stderr on the terminal, and an error message there should still be
    // legible.
    const stdout = std.Io.File.stdout();
    const stderr_file = std.Io.File.stderr();
    const vt_ok = reader.theme_mod.prepareConsole(stdout.handle);
    const out_env = reader.theme_mod.fromMap(opts.environ_map, vt_ok and (stdout.isTty(io) catch false));
    const err_env = reader.theme_mod.fromMap(opts.environ_map, vt_ok and (stderr_file.isTty(io) catch false));

    var parsed_args = flags.parseArgs(allocator, opts.minimal.args) catch |err| {
        // `--color` is unavailable when parsing is what failed, so this one
        // path falls back to plain auto-detection.
        const early = reader.theme_mod.resolve(err_env, .auto);
        fatal(io, &early, parseErrorMessage(err), "run zlrd --help for usage");
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
        flags.printHelp(th.colored);
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

    // Agent mode with --journal-unit but no positional files is valid:
    // journal sources don't need a file on disk. Skip auto-discovery in
    // that case so we don't fail-fast on a cwd without log files.
    const agent_journal_only = parsed_args.agent_mode and
        parsed_args.files.len == 0 and
        parsed_args.journal_units.len > 0;

    if (parsed_args.files.len == 0 and !agent_journal_only) {
        discovered_files = findLogFiles(allocator, io) catch {
            fatal(io, &err_th, "could not read current directory", "check read permissions: ls -la .");
            std.process.exit(1);
        };
        if (discovered_files.len == 0) {
            fatal(io, &err_th, "no *.log or *.log.gz files found in current directory", "specify a file: zlrd app.log");
            std.process.exit(1);
        }
        parsed_args.files = discovered_files;
    } else if (parsed_args.files.len > 0) {
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

    if (parsed_args.agent_mode) {
        const exit_code = agent.run(allocator, io, parsed_args) catch |err| {
            fatal(io, &err_th, agentErrorMessage(err), agentErrorHint(err));
            std.process.exit(1);
        };
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    if (!parsed_args.output_json and !parsed_args.tail_mode and th.colored) printBanner(io, &th);
    processFiles(allocator, parsed_args, &th) catch |err| {
        fatal(io, &err_th, runtimeErrorMessage(err), null);
        std.process.exit(1);
    };
}

/// Styled fatal error. `hint` is optional follow-up line shown in muted colour.
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
        p.json_key, p.reset,    "",
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

    // z=DEBUG l=INFO r=WARN d=ERROR, drawn from the resolved palette so the
    // banner degrades with the terminal instead of assuming 24-bit colour.
    var name_buf: [256]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}{s}z{s}l{s}r{s}d{s}{s}", .{
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
        error.MissingListen => "missing value for --listen",
        error.MissingMetricsToken => "missing value for --metrics-token",
        error.MissingAlertErrorRate => "missing value for --alert-error-rate",
        error.MissingAlertRegex => "missing value for --alert-regex",
        error.MissingAlertSilence => "missing value for --alert-silence",
        error.MissingAlertFile => "missing value for --alert-file",
        error.MissingAlertWebhook => "missing value for --alert-webhook",
        error.MissingWebhookHeader => "missing value for --webhook-header",
        error.MissingSidecarUrl => "missing value for --sidecar",
        error.MissingSidecarHeader => "missing value for --sidecar-header",
        error.MissingSidecarFlushInterval => "missing value for --sidecar-flush-interval",
        error.MissingSidecarBatchSize => "missing value for --sidecar-batch-size",
        else => @errorName(err),
    };
}

fn agentErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.NoFiles => "agent mode requires at least one file",
        error.MissingMetricsToken => "agent mode requires --metrics-token <secret>",
        error.InvalidListenAddress, error.InvalidAddress, error.InvalidPort => "invalid --listen address",
        error.InvalidThresholdSpec => "invalid threshold spec (expected N/Ws, e.g. 10/60s)",
        error.InvalidDuration => "invalid duration (expected Nms, Ns, Nm, or Nh)",
        error.InvalidRegexSpec => "invalid --alert-regex spec (expected <pattern>:N/Ws)",
        error.InvalidRegexPattern => "invalid regex pattern in --alert-regex",
        error.InvalidHeaderSpec => "invalid --webhook-header spec (expected 'Name: Value')",
        error.InvalidServiceSpec => "invalid --service spec (expected NAME=PATH)",
        error.InvalidJournalSpec => "invalid --journal-unit spec (expected NAME=UNIT_PATTERN)",
        error.InvalidBatchSize => "invalid --sidecar-batch-size (expected positive integer)",
        error.InvalidSidecarUrl => "invalid --sidecar URL (must start with https://)",
        error.InvalidUrl => "invalid URL",
        error.TlsRequired => "sidecar requires an https:// URL",
        else => runtimeErrorMessage(err),
    };
}

fn agentErrorHint(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.NoFiles => "pass at least one file: zlrd --agent --metrics-token secret app.log",
        error.MissingMetricsToken => "generate one and export it: --metrics-token=$(openssl rand -hex 16)",
        error.InvalidThresholdSpec => "example: --alert-error-rate 10/60s",
        error.InvalidDuration => "example: --alert-silence 60s  (suffixes: ms, s, m, h)",
        error.InvalidRegexSpec => "example: --alert-regex 'panic:5/30s'",
        error.InvalidServiceSpec => "example: --service api=/var/log/api.log",
        error.InvalidJournalSpec => "example: --journal-unit api='nginx.service'",
        error.InvalidHeaderSpec => "example: --webhook-header 'Authorization: Bearer xyz'",
        error.InvalidBatchSize => "example: --sidecar-batch-size 1024",
        error.InvalidSidecarUrl, error.TlsRequired => "example: --sidecar https://collector.example.com:4318",
        else => null,
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
