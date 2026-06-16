//! Agent mode entry point: orchestrates config, metrics, rules, dispatcher,
//! HTTP server, and the watcher loop.
//!
//! The HTTP server runs in its own OS thread; the watcher runs in the calling
//! thread (so it can return cleanly when stop conditions are met).

const std = @import("std");
const flags = @import("flags");
const kernel = @import("kernel");

pub const config = @import("config.zig");
pub const metrics = @import("metrics.zig");
pub const signature = @import("signature.zig");
pub const rules = @import("rules.zig");
pub const alert = @import("alert.zig");
pub const server = @import("server.zig");
pub const watcher = @import("watcher.zig");
pub const webhook = @import("webhook.zig");
pub const journal = @import("journal.zig");
pub const service = @import("service.zig");

const log = std.log.scoped(.zlrd_agent);

pub const RunError = error{
    NoFiles,
    InvalidListenAddress,
} || config.ParseError || error{
    OutOfMemory,
    InvalidRegexPattern,
};

/// Runs agent mode until `--alert-exit` fires or the process receives a stop
/// signal. The return value is non-zero iff the agent should exit with a
/// non-zero status (i.e. an alert fired in `--alert-exit` mode).
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: flags.Args,
) !u8 {
    if (args.files.len == 0 and args.journal_units.len == 0) return error.NoFiles;

    var cfg = try config.AgentConfig.fromArgs(allocator, args);
    defer cfg.deinit(allocator);

    var m = metrics.Metrics.init(nowMs(io));

    var rs = try rules.RuleSet.init(allocator, cfg);
    defer rs.deinit();

    var dispatcher = try alert.Dispatcher.init(io, cfg.sinks, &m, cfg.alert_exit);
    defer dispatcher.deinit();

    var sender_storage: ?webhook.Sender = null;
    defer if (sender_storage) |*s| s.deinit();
    if (cfg.sinks.webhooks.len > 0) {
        sender_storage = try webhook.Sender.init(allocator, io, cfg.sinks.webhook_headers);
        dispatcher.setWebhookSender(webhook.sendThunk, &sender_storage.?);
    }

    var srv = try server.Server.listen(allocator, io, &m, .{
        .listen_addr = cfg.listen_addr,
        .metrics_token = cfg.metrics_token,
    });
    defer srv.deinit();

    log.info("listening on {s}", .{cfg.listen_addr});
    log.info("watching {d} file(s); error_rate={s} regex={d} first_seen={s} silence={s}", .{
        args.files.len,
        if (args.alert_error_rate) |s| s else "off",
        cfg.regex_rules.len,
        if (cfg.first_seen) "on" else "off",
        if (args.alert_silence) |s| s else "off",
    });

    var w = try watcher.Watcher.init(allocator, io, &m, &rs, &dispatcher, &cfg, args.files);
    defer w.deinit();

    const server_thread = try std.Thread.spawn(.{}, runServer, .{&srv});

    var km: ?kernel.Monitor = if (args.kernel_probes)
        kernel.Monitor.init(io, alert.kernelSinkThunk, &dispatcher)
    else
        null;
    if (km) |*m_ref| {
        m_ref.start() catch |err| {
            log.warn("kernel probes failed to start: {t}", .{err});
        };
    }
    defer if (km) |*m_ref| {
        m_ref.stop();
        m_ref.join();
    };

    // Journal sources: one subprocess + thread per `--journal-unit` binding.
    // The watcher's own crash regexes are shared via Watcher.detector.
    var journals = std.ArrayList(*journal.JournalSource).empty;
    defer journals.deinit(allocator);
    var journal_threads = std.ArrayList(std.Thread).empty;
    defer journal_threads.deinit(allocator);
    defer {
        for (journals.items) |js| {
            js.requestStop();
        }
        for (journal_threads.items) |t| t.join();
        for (journals.items) |js| {
            js.deinit();
            allocator.destroy(js);
        }
    }
    for (cfg.journal_units) |spec| {
        const js = try allocator.create(journal.JournalSource);
        js.* = journal.JournalSource.init(
            allocator,
            io,
            spec.name,
            spec.pattern,
            &dispatcher,
            &w.detector,
        );
        try journals.append(allocator, js);
        const th = std.Thread.spawn(.{}, runJournal, .{js}) catch |err| {
            log.warn("failed to spawn journal thread for '{s}': {t}", .{ spec.name, err });
            continue;
        };
        try journal_threads.append(allocator, th);
        log.info("journal source '{s}' tracking unit pattern '{s}'", .{ spec.name, spec.pattern });
    }

    w.run() catch |err| {
        log.warn("watcher exited: {t}", .{err});
    };

    srv.requestShutdown();
    // The listener.accept() call is blocking; opening a no-op local connection
    // is the simplest way to wake it so the thread can observe shutdown_flag.
    nudgeListener(io, cfg.listen_addr);
    server_thread.join();

    return if (dispatcher.shouldExit()) 1 else 0;
}

fn runServer(srv: *server.Server) void {
    srv.run();
}

fn runJournal(src: *journal.JournalSource) void {
    src.run() catch |err| {
        std.log.scoped(.zlrd_agent).warn("journal source '{s}' exited: {t}", .{ src.name, err });
    };
}

/// Wall-clock milliseconds since epoch. Wraps the std.Io clock API so callers
/// stay backend-agnostic.
pub fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

/// Wakes the listener by opening a local connection and immediately closing.
/// Best-effort: if the connection can't be made (port closed, race), the
/// listener will eventually be killed when the process exits.
fn nudgeListener(io: std.Io, addr_str: []const u8) void {
    const addr = std.Io.net.IpAddress.parseLiteral(addr_str) catch return;
    const stream = addr.connect(io, .{ .mode = .stream }) catch return;
    stream.close(io);
}
