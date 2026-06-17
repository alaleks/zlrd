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

    /// Blocks until the file changes or `stop_flag` is set. Returns true if a
    /// change was observed, false on stop. The polling fallback wakes on its
    /// own interval and checks the flag.
    pub fn waitForChange(self: *Watcher, stop_flag: *StopFlag) bool {
        if (builtin.os.tag == .linux and self.inotify_fd >= 0) {
            return self.waitInotify(stop_flag);
        }
        return self.waitPolling(stop_flag);
    }

    fn waitInotify(self: *Watcher, stop_flag: *StopFlag) bool {
        // Block on inotify_fd in chunks so we can re-check stop_flag every
        // `poll_interval_ms` even if no event ever arrives.
        var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
        while (!stop_flag.load(.acquire)) {
            // poll() with a timeout lets the loop honor stop_flag.
            var pfd = [_]std.posix.pollfd{.{
                .fd = self.inotify_fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = std.posix.poll(&pfd, @intCast(self.opts.poll_interval_ms)) catch return false;
            if (ready == 0) continue;
            const n = std.posix.read(@intCast(self.inotify_fd), &buf) catch return false;
            if (n > 0) return true;
        }
        return false;
    }

    fn waitPolling(self: *Watcher, stop_flag: *StopFlag) bool {
        while (!stop_flag.load(.acquire)) {
            const size = self.statFile() catch {
                std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(self.opts.poll_interval_ms), .awake) catch {};
                continue;
            };
            if (size != self.last_size) {
                self.last_size = size;
                return true;
            }
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(self.opts.poll_interval_ms), .awake) catch return false;
        }
        return false;
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
    try testing.expect(w.waitForChange(&stop));
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
    try testing.expect(!w.waitForChange(&stop));
}
