//! Live-tail watcher around a `.journal` file. Blocks until the file changes
//! (via inotify on Linux), then the caller asks its iterator to refresh and
//! drains newly-appended entries.
//!
//! Platform fallback: where inotify is unavailable (macOS, BSDs, or a failed
//! `inotify_init`), we poll the path's metadata on a fixed interval.
//!
//! Both paths have to cope with a quirk of how journald writes: entries are
//! appended into a *pre-allocated* arena via `mmap`, so a new entry usually
//! changes neither the file's size nor its object layout. journald works
//! around the fact that mmap writes don't raise `IN_MODIFY` by `ftruncate`-ing
//! the file to its own current size after each batch. That gives inotify its
//! event — and it means a poll fallback watching only `st_size` would never
//! see anything. We compare mtime as well.
//!
//! Scope: a single `.journal` file. The agent layer will wrap multiple
//! watchers when the active file is rotated (rename of `system.journal` to
//! `system@…~.journal`); detecting rotation across files is the agent's job,
//! not this module's.

const std = @import("std");
const builtin = @import("builtin");

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
    /// The watched path no longer refers to the file we opened: renamed
    /// away, replaced by a fresh file, or truncated. Real systemd rotation
    /// moves `system.journal` aside to `system@<id>.journal` and creates a
    /// new one in its place.
    rotated,
    /// The watched path was unlinked. Practically the same as `rotated`
    /// for our purposes — we need to re-discover the active file.
    deleted,
};

pub const Options = struct {
    /// Where the .journal file lives on disk.
    dir: std.Io.Dir,
    /// Path of the file relative to `dir`. Must be absolute for the inotify
    /// path to be usable — see `setupInotify`.
    path: []const u8,
    /// Polling interval when inotify is unavailable, and the timeout on the
    /// inotify `poll()` that keeps `stop_flag` responsive.
    poll_interval_ms: u32 = 500,
};

pub const Watcher = struct {
    io: std.Io,
    opts: Options,
    /// Inotify file descriptor on Linux, -1 otherwise (poll fallback).
    inotify_fd: i32 = -1,
    /// Last observed metadata of the watched path. `mtime` is what actually
    /// moves when journald appends; `size` catches truncation and `inode`
    /// catches the path being replaced by a different file.
    last_size: u64 = 0,
    last_mtime: std.Io.Timestamp = .zero,
    last_inode: ?std.Io.File.INode = null,

    pub fn init(io: std.Io, opts: Options) Watcher {
        var w: Watcher = .{ .io = io, .opts = opts };
        // Seed the poll baseline even on the inotify path: if inotify dies
        // later we fall back mid-flight and want a sane starting point.
        if (opts.dir.statFile(io, opts.path, .{})) |st| {
            w.last_size = st.size;
            w.last_mtime = st.mtime;
            w.last_inode = st.inode;
        } else |err| {
            log.warn("cannot stat {s} at watcher start: {t}", .{ opts.path, err });
        }
        if (builtin.os.tag == .linux) {
            w.inotify_fd = setupInotify(opts) catch |err| blk: {
                log.warn("inotify unavailable for {s} ({t}), falling back to polling", .{ opts.path, err });
                break :blk -1;
            };
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
                // The watch is gone (file deleted, or the fs unmounted).
                // Staying here would just spin on poll timeouts forever.
                if ((mask & (linux.IN.IGNORED | linux.IN.UNMOUNT)) != 0) reason = .deleted;
                // The kernel dropped events we never saw. We don't know what
                // was missed, so report the recoverable one and let the
                // caller re-read from its parked position.
                if ((mask & linux.IN.Q_OVERFLOW) != 0 and reason == .modified) {
                    log.warn("inotify queue overflow watching {s}", .{self.opts.path});
                }
                off += hdr_sz + ev_ptr.len;
            }
            return reason;
        }
        return .stop;
    }

    fn waitPolling(self: *Watcher, stop_flag: *StopFlag) WakeReason {
        while (!stop_flag.load(.acquire)) {
            if (self.opts.dir.statFile(self.io, self.opts.path, .{})) |st| {
                // The path now resolves to a different file — journald
                // rotated `system.journal` aside and made a new one.
                if (self.last_inode) |prev| {
                    if (st.inode != prev) {
                        self.observe(st);
                        return .rotated;
                    }
                }
                // Truncation: practically equivalent to a fresh file.
                if (st.size < self.last_size) {
                    self.observe(st);
                    return .rotated;
                }
                // Size alone is not enough: journald appends into a
                // pre-allocated arena and then `ftruncate`s to the same
                // length, so mtime is usually the only thing that moves.
                if (st.size != self.last_size or st.mtime.nanoseconds != self.last_mtime.nanoseconds) {
                    self.observe(st);
                    return .modified;
                }
            } else |_| {
                // Path went away — treat as deletion so the agent can
                // reopen against the freshly-rotated file.
                return .deleted;
            }
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(self.opts.poll_interval_ms), .awake) catch return .stop;
        }
        return .stop;
    }

    fn observe(self: *Watcher, st: std.Io.File.Stat) void {
        self.last_size = st.size;
        self.last_mtime = st.mtime;
        self.last_inode = st.inode;
    }
};

fn setupInotify(opts: Options) !i32 {
    if (comptime builtin.os.tag != .linux) return error.Unsupported;
    // `inotify_add_watch` resolves its path against the process CWD, not
    // against `opts.dir`. Watching a same-named file in the wrong directory
    // would be silently wrong — worse than falling back to polling — so
    // require the caller to hand us an unambiguous path.
    if (!std.fs.path.isAbsolute(opts.path)) return error.PathNotAbsolute;

    const linux = std.os.linux;
    const init_rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
    if (std.posix.errno(init_rc) != .SUCCESS) return error.InotifyInitFailed;
    const ifd: i32 = @intCast(init_rc);
    errdefer _ = linux.close(ifd);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (opts.path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..opts.path.len], opts.path);
    path_buf[opts.path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(path_buf[0..opts.path.len :0].ptr);

    const wd_rc = linux.inotify_add_watch(
        ifd,
        path_z,
        linux.IN.MODIFY | linux.IN.MOVE_SELF | linux.IN.DELETE_SELF | linux.IN.ATTRIB,
    );
    if (std.posix.errno(wd_rc) != .SUCCESS) return error.InotifyWatchFailed;
    return ifd;
}

// ─── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;
const debug_io = std.Options.debug_io;

/// Sets `stop_flag` after `ms` unless cancelled first. Used two ways: as a
/// watchdog so a watcher that never wakes fails the test as `.stop` instead
/// of hanging CI, and as the deliberate trigger in the stop-flag test.
///
/// The wait is chopped into short naps so `cancel` returns promptly once the
/// test is done — sleeping out the full watchdog interval would add its
/// timeout to the runtime of every passing test.
const Deadline = struct {
    done: StopFlag = StopFlag.init(false),
    thread: std.Thread = undefined,

    const tick_ms = 20;

    fn arm(self: *Deadline, flag: *StopFlag, io: std.Io, ms: i64) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{ self, flag, io, ms });
    }

    fn run(self: *Deadline, flag: *StopFlag, io: std.Io, ms: i64) void {
        var waited: i64 = 0;
        while (waited < ms) : (waited += tick_ms) {
            if (self.done.load(.acquire)) return;
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(tick_ms), .awake) catch return;
        }
        flag.store(true, .release);
    }

    fn cancel(self: *Deadline) void {
        self.done.store(true, .release);
        self.thread.join();
    }
};

fn pollWatcher(tmp_dir: std.Io.Dir, path: []const u8) Watcher {
    var w = Watcher.init(debug_io, .{ .dir = tmp_dir, .path = path, .poll_interval_ms = 10 });
    w.inotify_fd = -1; // force the polling fallback even on Linux
    return w;
}

/// Writes `data` at `offset` without truncating, the way journald mutates a
/// journal file. `Dir.writeFile` would open with O_TRUNC, and a poll landing
/// inside that window would legitimately observe a shrunken file and report
/// `.rotated` — a race in the test, not in the watcher.
fn writeInPlace(dir: std.Io.Dir, path: []const u8, offset: u64, data: []const u8) !void {
    const f = try dir.openFile(debug_io, path, .{ .mode = .read_write });
    defer f.close(debug_io);
    try f.writePositionalAll(debug_io, data, offset);
}

test "polling watcher detects file growth" {
    const tio = debug_io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(tio, .{ .sub_path = "tail.dat", .data = "abc" });

    var w = pollWatcher(tmp.dir, "tail.dat");
    defer w.deinit();
    try testing.expectEqual(@as(u64, 3), w.last_size);

    const Appender = struct {
        fn run(dir: std.Io.Dir, io: std.Io) void {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(30), .awake) catch return;
            writeInPlace(dir, "tail.dat", 3, "def") catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, Appender.run, .{ tmp.dir, tio });
    defer t.join();

    var stop = StopFlag.init(false);
    var guard: Deadline = .{};
    try guard.arm(&stop, tio, 5_000);
    defer guard.cancel();

    try testing.expectEqual(WakeReason.modified, w.waitForChange(&stop));
    try testing.expectEqual(@as(u64, 6), w.last_size);
}

test "polling watcher detects a same-size rewrite" {
    // The journald case: content changes, byte count does not. A watcher
    // comparing only `st_size` sleeps through this forever.
    const tio = debug_io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(tio, .{ .sub_path = "same.dat", .data = "aaaa" });

    var w = pollWatcher(tmp.dir, "same.dat");
    defer w.deinit();

    const Rewriter = struct {
        fn run(dir: std.Io.Dir, io: std.Io) void {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(30), .awake) catch return;
            // Same length, different bytes — only mtime moves.
            writeInPlace(dir, "same.dat", 0, "bbbb") catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, Rewriter.run, .{ tmp.dir, tio });
    defer t.join();

    var stop = StopFlag.init(false);
    var guard: Deadline = .{};
    try guard.arm(&stop, tio, 5_000);
    defer guard.cancel();

    try testing.expectEqual(WakeReason.modified, w.waitForChange(&stop));
    try testing.expectEqual(@as(u64, 4), w.last_size);
}

test "polling watcher reports truncation as rotation" {
    const tio = debug_io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(tio, .{ .sub_path = "trunc.dat", .data = "abcdefgh" });

    var w = pollWatcher(tmp.dir, "trunc.dat");
    defer w.deinit();

    const Shrinker = struct {
        fn run(dir: std.Io.Dir, io: std.Io) void {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(30), .awake) catch return;
            dir.writeFile(io, .{ .sub_path = "trunc.dat", .data = "ab" }) catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, Shrinker.run, .{ tmp.dir, tio });
    defer t.join();

    var stop = StopFlag.init(false);
    var guard: Deadline = .{};
    try guard.arm(&stop, tio, 5_000);
    defer guard.cancel();

    try testing.expectEqual(WakeReason.rotated, w.waitForChange(&stop));
}

test "polling watcher reports a replaced file as rotation" {
    // journald rotation: the path keeps its name but points at a new inode.
    const tio = debug_io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(tio, .{ .sub_path = "rot.dat", .data = "old" });

    var w = pollWatcher(tmp.dir, "rot.dat");
    defer w.deinit();
    try testing.expect(w.last_inode != null);

    const Rotator = struct {
        fn run(dir: std.Io.Dir, io: std.Io) void {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(30), .awake) catch return;
            dir.writeFile(io, .{ .sub_path = "fresh.dat", .data = "brand new file" }) catch return;
            dir.rename("fresh.dat", dir, "rot.dat", io) catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, Rotator.run, .{ tmp.dir, tio });
    defer t.join();

    var stop = StopFlag.init(false);
    var guard: Deadline = .{};
    try guard.arm(&stop, tio, 5_000);
    defer guard.cancel();

    try testing.expectEqual(WakeReason.rotated, w.waitForChange(&stop));
}

test "polling watcher reports an unlinked path as deleted" {
    const tio = debug_io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(tio, .{ .sub_path = "gone.dat", .data = "here" });

    var w = pollWatcher(tmp.dir, "gone.dat");
    defer w.deinit();

    const Remover = struct {
        fn run(dir: std.Io.Dir, io: std.Io) void {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(30), .awake) catch return;
            dir.deleteFile(io, "gone.dat") catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, Remover.run, .{ tmp.dir, tio });
    defer t.join();

    var stop = StopFlag.init(false);
    var guard: Deadline = .{};
    try guard.arm(&stop, tio, 5_000);
    defer guard.cancel();

    try testing.expectEqual(WakeReason.deleted, w.waitForChange(&stop));
}

test "stop flag wakes the polling watcher" {
    const tio = debug_io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(tio, .{ .sub_path = "idle.dat", .data = "xx" });

    var w = pollWatcher(tmp.dir, "idle.dat");
    defer w.deinit();

    var stop = StopFlag.init(false);
    var trigger: Deadline = .{};
    try trigger.arm(&stop, tio, 40);
    defer trigger.cancel();

    // File isn't changing — only the stop flag can wake us.
    try testing.expectEqual(WakeReason.stop, w.waitForChange(&stop));
}

test "a watcher on a missing path reports deleted immediately" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var w = pollWatcher(tmp.dir, "never-existed.dat");
    defer w.deinit();
    try testing.expect(w.last_inode == null);

    var stop = StopFlag.init(false);
    try testing.expectEqual(WakeReason.deleted, w.waitForChange(&stop));
}

test "setupInotify refuses a relative path" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Relative paths resolve against the CWD rather than `dir`, which would
    // silently watch the wrong file.
    try testing.expectError(error.PathNotAbsolute, setupInotify(.{
        .dir = tmp.dir,
        .path = "relative.journal",
    }));
}

test "Watcher.init falls back to polling for a relative path" {
    // Not just an inotify-layer detail: the constructed watcher must still
    // be functional, via the poll path, rather than half-initialized.
    const tio = debug_io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(tio, .{ .sub_path = "rel.dat", .data = "one" });

    var w = Watcher.init(tio, .{ .dir = tmp.dir, .path = "rel.dat", .poll_interval_ms = 10 });
    defer w.deinit();
    try testing.expectEqual(@as(i32, -1), w.inotify_fd);
    try testing.expectEqual(@as(u64, 3), w.last_size);
}
