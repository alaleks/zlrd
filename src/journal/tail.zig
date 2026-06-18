//! Live-tail watcher around a `journal.Reader`. Blocks until the underlying
//! `.journal` file changes (via inotify on Linux), then asks the iterator to
//! refresh and surfaces newly-appended entries.
//!
//! Platform fallback: where inotify is unavailable (macOS, BSDs), we poll the
//! file's mtime/size on a fixed interval. Polling is good enough for tests
//! and dev work; production deployments are Linux.
//!
//! Scope: a single `.journal` file. The agent layer will wrap multiple
//! watchers when the active file is rotated (rename of `system.journal` to
//! `system@…~.journal`); detecting rotation across files is the agent's job,
//! not this module's.

const std = @import("std");
const builtin = @import("builtin");

const reader_mod = @import("reader.zig");

const log = std.log.scoped(.zlrd_journal_tail);

/// Tail loop bounded by the caller via `stop_flag`. The flag is checked
/// between waits so the caller can request shutdown without racing the
/// blocking syscall.
pub const StopFlag = std.atomic.Value(bool);

/// What caused `waitForChange` to wake up. Callers behave differently for
/// modify (drain new entries) vs rotated/deleted (reopen the file from
/// the directory).
pub const WakeReason = enum {
    /// `stop_flag` was set or the underlying syscall reported an error.
    stop,
    /// The file was modified (data appended).
    modified,
    /// The file was renamed away from its watched path. Real systemd
    /// rotation moves `system.journal` aside to `system@<id>.journal`.
    rotated,
    /// The watched path was unlinked. Practically the same as `rotated`
    /// for our purposes — we need to re-discover the active file.
    deleted,
};

pub const Options = struct {
    /// Where the .journal file lives on disk. Required for the inotify watch
    /// (and for the poll fallback's `statFile`).
    dir: std.Io.Dir,
    /// Path of the file relative to `dir`.
    path: []const u8,
    /// Polling interval when inotify is unavailable. Ignored on Linux unless
    /// inotify_init fails.
    poll_interval_ms: u32 = 500,
};

pub const Watcher = struct {
    io: std.Io,
    reader: *reader_mod.Reader,
    opts: Options,
    /// Inotify file descriptor on Linux, -1 otherwise (poll fallback).
    inotify_fd: i32 = -1,
    /// Mirror of the file's last observed size — used by the poll fallback
    /// to detect appends.
    last_size: u64 = 0,

    pub fn init(io: std.Io, r: *reader_mod.Reader, opts: Options) Watcher {
        var w: Watcher = .{
            .io = io,
            .reader = r,
            .opts = opts,
            .last_size = r.file_size,
        };
        if (builtin.os.tag == .linux) {
            w.inotify_fd = setupInotify(opts) catch -1;
            if (w.inotify_fd < 0) {
                log.warn("inotify unavailable, falling back to polling", .{});
            }
        }
        return w;
    }

    pub fn deinit(self: *Watcher) void {
        if (self.inotify_fd >= 0) {
            _ = std.os.linux.close(@intCast(self.inotify_fd));
            self.inotify_fd = -1;
        }
    }

    /// Blocks until the file changes or `stop_flag` is set. Returns the
    /// reason for waking: `.modified` for normal appends, `.rotated`/
    /// `.deleted` when the file moved or disappeared (caller should reopen),
    /// `.stop` when shut down.
    pub fn waitForChange(self: *Watcher, stop_flag: *StopFlag) WakeReason {
        if (builtin.os.tag == .linux and self.inotify_fd >= 0) {
            return self.waitInotify(stop_flag);
        }
        return self.waitPolling(stop_flag);
    }

    fn waitInotify(self: *Watcher, stop_flag: *StopFlag) WakeReason {
        const linux = std.os.linux;
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (!stop_flag.load(.acquire)) {
            // poll() with a timeout lets the loop honor stop_flag.
            var pfd = [_]std.posix.pollfd{.{
                .fd = self.inotify_fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = std.posix.poll(&pfd, @intCast(self.opts.poll_interval_ms)) catch return .stop;
            if (ready == 0) continue;
            // POLLHUP/POLLERR mean the fd is unusable — exit instead of
            // spinning on a dead descriptor.
            if ((pfd[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) return .stop;
            if ((pfd[0].revents & std.posix.POLL.IN) == 0) continue;

            const n = std.posix.read(@intCast(self.inotify_fd), &buf) catch return .stop;
            if (n == 0) continue;

            // Walk the event packet. Any DELETE/MOVE wins over a plain
            // MODIFY — rotation needs the caller's full attention.
            var reason: WakeReason = .modified;
            var off: usize = 0;
            const hdr_sz = @sizeOf(linux.inotify_event);
            while (off + hdr_sz <= n) {
                const ev_ptr: *const linux.inotify_event = @ptrCast(@alignCast(&buf[off]));
                const mask = ev_ptr.mask;
                if ((mask & linux.IN.MOVE_SELF) != 0) reason = .rotated;
                if ((mask & linux.IN.DELETE_SELF) != 0) reason = .deleted;
                off += hdr_sz + ev_ptr.len;
            }
            return reason;
        }
        return .stop;
    }

    fn waitPolling(self: *Watcher, stop_flag: *StopFlag) WakeReason {
        while (!stop_flag.load(.acquire)) {
            const size = self.statFile() catch {
                // Path went away — treat as deletion so the agent can
                // reopen against the freshly-rotated file.
                return .deleted;
            };
            if (size < self.last_size) {
                // File truncated — practically equivalent to a fresh file.
                self.last_size = size;
                return .rotated;
            }
            if (size != self.last_size) {
                self.last_size = size;
                return .modified;
            }
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(self.opts.poll_interval_ms), .awake) catch return .stop;
        }
        return .stop;
    }

    fn statFile(self: *Watcher) !u64 {
        const f = try self.opts.dir.openFile(self.io, self.opts.path, .{ .mode = .read_only });
        defer f.close(self.io);
        return f.length(self.io);
    }
};

fn setupInotify(opts: Options) !i32 {
    if (comptime builtin.os.tag != .linux) return error.Unsupported;
    const linux = std.os.linux;
    const init_rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
    if (std.posix.errno(init_rc) != .SUCCESS) return error.InotifyInitFailed;
    const ifd: i32 = @intCast(init_rc);
    errdefer _ = linux.close(ifd);

    // inotify_add_watch needs a NUL-terminated path. We need an absolute or
    // cwd-resolvable path; std.Io.Dir doesn't yet expose its fd portably, so
    // the caller passes a real path string.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (opts.path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..opts.path.len], opts.path);
    path_buf[opts.path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(path_buf[0..opts.path.len :0].ptr);

    const wd_rc = linux.inotify_add_watch(
        ifd,
        path_z,
        linux.IN.MODIFY | linux.IN.MOVE_SELF | linux.IN.DELETE_SELF,
    );
    if (std.posix.errno(wd_rc) != .SUCCESS) return error.InotifyWatchFailed;
    return ifd;
}

// ─── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;
const debug_io = std.Options.debug_io;

test "polling watcher detects file growth" {
    const tio = debug_io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(tio, .{ .sub_path = "tail.dat", .data = "abc" });

    // Stand up a dummy Reader-shaped placeholder — Watcher only reads
    // `file_size` and uses `Options.dir`/`path` for the stat, so we can use
    // a sentinel reader pointer for this fallback-path test.
    var dummy_reader: reader_mod.Reader = undefined;
    dummy_reader.file_size = 3;

    var w = Watcher{
        .io = tio,
        .reader = &dummy_reader,
        .opts = .{ .dir = tmp.dir, .path = "tail.dat", .poll_interval_ms = 20 },
        .inotify_fd = -1, // force the polling fallback
        .last_size = 3,
    };
    defer w.deinit();

    // Spawn a thread that appends to the file after a short delay.
    const Appender = struct {
        fn run(dir: std.Io.Dir, io: std.Io) void {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(40), .awake) catch return;
            dir.writeFile(io, .{ .sub_path = "tail.dat", .data = "abcdef" }) catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, Appender.run, .{ tmp.dir, tio });
    defer t.join();

    var stop = StopFlag.init(false);
    try testing.expectEqual(WakeReason.modified, w.waitForChange(&stop));
    try testing.expectEqual(@as(u64, 6), w.last_size);
}

test "stop flag wakes the polling watcher" {
    const tio = debug_io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(tio, .{ .sub_path = "idle.dat", .data = "xx" });

    var dummy_reader: reader_mod.Reader = undefined;
    dummy_reader.file_size = 2;

    var w = Watcher{
        .io = tio,
        .reader = &dummy_reader,
        .opts = .{ .dir = tmp.dir, .path = "idle.dat", .poll_interval_ms = 20 },
        .inotify_fd = -1,
        .last_size = 2,
    };
    defer w.deinit();

    var stop = StopFlag.init(false);
    const Stopper = struct {
        fn run(flag: *StopFlag, io: std.Io) void {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(40), .awake) catch return;
            flag.store(true, .release);
        }
    };
    const t = try std.Thread.spawn(.{}, Stopper.run, .{ &stop, tio });
    defer t.join();

    // File isn't growing — only the stop flag can wake us.
    try testing.expectEqual(WakeReason.stop, w.waitForChange(&stop));
}
