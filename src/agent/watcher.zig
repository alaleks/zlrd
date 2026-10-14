//! Multi-file follow loop for agent mode.
//!
//! Stays minimal on purpose: positional reads, partial-line carry, and a
//! short sleep when nothing new arrived.
//!
//! Rotation is followed by path. A new inode at the path — `mv` + create,
//! delete + recreate, `mv` then gzip — means the old file is read to its end
//! first, then the new one from its start. In-place truncation
//! (`copytruncate`) is caught by size or, when the file has already grown
//! back past the old offset, by its first bytes changing. A path that does
//! not exist yet is opened when it appears. Every one of these bumps
//! `file_rotation_total`.

const std = @import("std");
const flags = @import("flags");
const regex = @import("regex");

const alert = @import("alert.zig");
const config = @import("config.zig");
const metrics = @import("metrics.zig");
const rules = @import("rules.zig");
const service = @import("service.zig");
const signature = @import("signature.zig");
const state = @import("state");

const log = std.log.scoped(.zlrd_watcher);

const read_buf_size = 64 * 1024;
const poll_interval_ms = 100;
const silence_check_interval_ms = 1_000;

/// Soft cap on bytes consumed from a single file per outer iteration. The
/// previous "one chunk per iteration" rule was too aggressive — a multi-MB
/// backlog turned into thousands of extra stat() syscalls because the
/// rotation-detection stat was done per chunk. The new policy: drain up to
/// `max_bytes_per_pass` bytes (≈ 64 chunks) from a file in one go, then
/// yield so other files get a turn. Fairness is preserved (one busy file
/// can't starve others indefinitely) and syscall overhead drops by ~64×.
const max_bytes_per_pass: usize = 4 * 1024 * 1024;
/// Cap on a single line. Anything longer is truncated; the truncated portion
/// is dropped (and the next byte after the cap starts a new line).
///
/// Sized at 8 KiB so realistic structured log lines (multi-KB JSON, java
/// stack frames) fit without truncation. The previous 1.5 KiB cap was too
/// aggressive — it broke first-seen signature computation and crash-marker
/// detection for any line where the marker sat past the cap. The signature
/// buffer in `signature.zig` is sized to match.
const max_line_bytes = 8 * 1024;

/// Bytes kept from the start of a file to recognise it after an in-place
/// truncate. A log line's timestamp sits in its first bytes, so a rewritten
/// file almost never starts the same way.
const head_bytes = 64;

const FileState = struct {
    path: []const u8,
    /// Null until the path exists.
    fd: ?std.Io.File,
    position: u64,
    carry: std.ArrayList(u8),
    last_line_ms: i64,
    /// Inode of the file currently open under this path. Compared against a
    /// path-level stat each iteration to detect rotation / restart. Typed as
    /// `std.Io.File.INode` so Windows (signed file id) compiles too.
    /// Meaningless while `fd` is null.
    inode: std.Io.File.INode,
    head: [head_bytes]u8 = undefined,
    head_len: u8 = 0,
    /// Per-file lifecycle tracker. Non-null only when the file's path is
    /// bound to a `--service NAME=PATH` mapping.
    tracker: ?service.Tracker,
    /// Per-file latch for the silence rule. Owned here (rather than on the
    /// `RuleSet`) so one file's silence alert doesn't suppress the alert
    /// for every other silent file in the same window.
    silence_latch_epoch: ?u64 = null,
};

pub const Watcher = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    files: []FileState,
    metrics: *metrics.Metrics,
    rules: *rules.RuleSet,
    dispatcher: *alert.Dispatcher,
    read_buf: []u8,
    stop_flag: std.atomic.Value(bool),
    crash_regexes: []regex.Regex,
    detector: service.Detector,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        m: *metrics.Metrics,
        rs: *rules.RuleSet,
        dispatcher: *alert.Dispatcher,
        cfg: *const config.AgentConfig,
        paths: []const []const u8,
    ) !Watcher {
        const files = try allocator.alloc(FileState, paths.len);
        errdefer allocator.free(files);

        var opened: usize = 0;
        errdefer {
            for (files[0..opened]) |*f| {
                if (f.fd) |fd| fd.close(io);
                f.carry.deinit(allocator);
            }
        }

        const now = nowMs(io);
        for (paths, 0..) |path, i| {
            const tracker_opt: ?service.Tracker = if (cfg.serviceForPath(path)) |svc_name|
                service.Tracker.init(svc_name, path, now)
            else
                null;
            files[i] = .{
                .path = path,
                .fd = null,
                .position = 0,
                .carry = .empty,
                .last_line_ms = now,
                .inode = undefined,
                .tracker = tracker_opt,
            };
            // A file that is already there is followed from its end; one
            // that is not yet is picked up, from its start, once it appears.
            if (std.Io.Dir.cwd().openFile(io, path, .{})) |fd| {
                errdefer fd.close(io);
                const stat = try fd.stat(io);
                files[i].fd = fd;
                files[i].inode = stat.inode;
                files[i].position = stat.size;
                // Read from the end, so the head has to be fetched now.
                try readHead(io, &files[i], fd);
            } else |err| switch (err) {
                error.FileNotFound => log.info("{s} does not exist yet; waiting for it", .{path}),
                else => return err,
            }
            opened += 1;
        }

        const buf = try allocator.alloc(u8, read_buf_size);
        errdefer allocator.free(buf);

        // Compile user-supplied crash markers once. Pure-Zig regex engine
        // borrows the pattern slice; cfg outlives the watcher.
        //
        // Track `built` so a mid-loop compile failure cleans up the regexes
        // we already allocated — otherwise an InvalidCrashMarker after the
        // first successful pattern leaked all the compiled regex internals.
        const regexes = try allocator.alloc(regex.Regex, cfg.crash_markers.len);
        var built: usize = 0;
        errdefer {
            for (regexes[0..built]) |*r| r.deinit();
            allocator.free(regexes);
        }
        for (cfg.crash_markers, 0..) |pattern, i| {
            regexes[i] = regex.Regex.compile(pattern) orelse return error.InvalidCrashMarker;
            built += 1;
        }

        m.setFilesWatched(files.len);

        return .{
            .allocator = allocator,
            .io = io,
            .files = files,
            .metrics = m,
            .rules = rs,
            .dispatcher = dispatcher,
            .read_buf = buf,
            .stop_flag = .init(false),
            .crash_regexes = regexes,
            .detector = .{ .customs = regexes },
        };
    }

    pub fn deinit(self: *Watcher) void {
        for (self.files) |*f| {
            if (f.fd) |fd| fd.close(self.io);
            f.carry.deinit(self.allocator);
        }
        self.allocator.free(self.files);
        self.allocator.free(self.read_buf);
        self.allocator.free(self.crash_regexes);
        self.* = undefined;
    }

    /// Adopts each tracked service's counters from the state file, so the
    /// totals an alert reports span every run rather than this one.
    ///
    /// Called before `run`, while no other thread is touching the trackers.
    pub fn seedTrackers(self: *Watcher, store: *state.Store) void {
        for (self.files) |*f| {
            if (f.tracker) |*t| {
                const c = store.counts(t.name);
                t.seed(c.crash, c.restart);
            }
        }
    }

    pub fn requestStop(self: *Watcher) void {
        self.stop_flag.store(true, .monotonic);
    }

    /// Blocks until `requestStop` is called or the dispatcher's exit flag is
    /// set (via `--alert-exit`).
    pub fn run(self: *Watcher) !void {
        var last_silence_check_ms: i64 = nowMs(self.io);

        while (!self.stop_flag.load(.monotonic) and !self.dispatcher.shouldExit()) {
            var any_read = false;

            for (self.files) |*f| {
                const bytes = self.drainFile(f) catch |err| {
                    log.warn("read {s}: {t}", .{ f.path, err });
                    continue;
                };
                if (bytes > 0) any_read = true;
            }

            const now_ms = nowMs(self.io);
            if (self.rules.hasSilenceRule() and (now_ms - last_silence_check_ms) >= silence_check_interval_ms) {
                self.runSilenceChecks(now_ms);
                last_silence_check_ms = now_ms;
            }

            // Tick service trackers every loop iteration — the cost is just a
            // pair of timestamp comparisons; flushing pending crashes within
            // ~250 ms of the marker is what makes the alert latency feel
            // tight to operators.
            self.runServiceTicks(now_ms);

            if (!any_read) {
                std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(poll_interval_ms), .awake) catch break;
            }
        }
    }

    fn runServiceTicks(self: *Watcher, now_ms: i64) void {
        for (self.files) |*f| {
            if (f.tracker) |*t| {
                if (t.tick(now_ms, service.default_trace_flush_ms, service.default_stop_window_ms)) |ev| {
                    self.dispatcher.dispatchService(ev, now_ms);
                }
            }
        }
    }

    /// Drains up to `max_bytes_per_pass` bytes from one file, then yields so
    /// the outer loop can give other files a turn. The two stat() syscalls
    /// (rotation + size) happen once per pass, not once per chunk — the
    /// previous "one chunk per call" version cost an extra 30k+ syscalls
    /// when starting up against a large backlog.
    fn drainFile(self: *Watcher, f: *FileState) !usize {
        var consumed: usize = 0;
        // Path-level stat catches the "logrotate / restart created a new
        // file at this path" case — the open fd still points at the old
        // (possibly unlinked) inode, so its fstat() would never notice.
        if (std.Io.Dir.cwd().statFile(self.io, f.path, .{})) |path_stat| {
            if (f.fd == null) {
                try self.openAppeared(f, path_stat.inode);
            } else if (path_stat.inode != f.inode) {
                consumed += try self.handleRotation(f, path_stat.inode);
            }
        } else |_| {
            // Missing: not created yet, or mid-swap. Keep reading the open
            // fd, if any, until the path resolves again.
        }
        const fd = f.fd orelse return consumed;

        const stat = try fd.stat(self.io);
        // In-place truncation. Usually the file is simply shorter than our
        // offset; but a busy writer can refill it past that offset between
        // two polls, and then only its first bytes give it away.
        if (stat.size < f.position or try self.headChanged(f, fd)) {
            self.metrics.observeRotation();
            f.position = 0;
            f.head_len = 0;
            f.carry.clearRetainingCapacity();
        }
        if (stat.size == f.position) return consumed;
        return consumed + try self.readFrom(f, fd, max_bytes_per_pass);
    }

    /// Reads and processes up to `limit` bytes from `f.position`.
    fn readFrom(self: *Watcher, f: *FileState, fd: std.Io.File, limit: usize) !usize {
        var consumed: usize = 0;
        while (consumed < limit) {
            const n = try fd.readPositional(self.io, &.{self.read_buf}, f.position);
            if (n == 0) break;
            if (f.position < head_bytes and f.head_len < head_bytes) {
                const take = @min(head_bytes - f.head_len, n);
                if (f.position == f.head_len) {
                    @memcpy(f.head[f.head_len..][0..take], self.read_buf[0..take]);
                    f.head_len += @intCast(take);
                }
            }
            consumed += n;
            f.position += n;
            try self.processChunk(f, self.read_buf[0..n]);
            // Short read → caught up with EOF for now, stop and let other
            // files get a turn.
            if (n < self.read_buf.len) break;
        }
        return consumed;
    }

    /// True when the file no longer starts with the bytes it started with
    /// when they were read.
    fn headChanged(self: *Watcher, f: *const FileState, fd: std.Io.File) !bool {
        if (f.head_len == 0) return false;
        var buf: [head_bytes]u8 = undefined;
        const n = try fd.readPositional(self.io, &.{buf[0..f.head_len]}, 0);
        return n < f.head_len or !std.mem.eql(u8, buf[0..n], f.head[0..f.head_len]);
    }

    fn openAppeared(self: *Watcher, f: *FileState, inode: std.Io.File.INode) !void {
        f.fd = try std.Io.Dir.cwd().openFile(self.io, f.path, .{});
        f.inode = inode;
        f.position = 0;
        f.head_len = 0;
        self.metrics.observeRotation();
        log.info("{s} appeared; following it", .{f.path});
    }

    /// Switches to the new file at the path, after reading the old one to
    /// its end. The writer may have appended right up to the rename, and the
    /// old inode stays readable through our fd even once it is unlinked or
    /// compressed away — closing it first is how those last lines were lost.
    fn handleRotation(self: *Watcher, f: *FileState, new_inode: std.Io.File.INode) !usize {
        const old = f.fd.?;
        const drained = self.readFrom(f, old, std.math.maxInt(usize)) catch 0;
        // The old file is finished, so an unterminated last line is whole.
        if (f.carry.items.len > 0) {
            try self.handleLine(f, f.carry.items);
            f.carry.clearRetainingCapacity();
        }
        old.close(self.io);
        f.fd = null;
        f.fd = try std.Io.Dir.cwd().openFile(self.io, f.path, .{});
        f.inode = new_inode;
        f.position = 0;
        f.head_len = 0;
        self.metrics.observeRotation();

        if (f.tracker) |*t| {
            const now_ms = nowMs(self.io);
            const ev = t.observeInodeChange(now_ms);
            self.dispatcher.dispatchService(ev, now_ms);
        }
        return drained;
    }

    fn processChunk(self: *Watcher, f: *FileState, chunk: []const u8) !void {
        var i: usize = 0;
        while (i < chunk.len) {
            const newline = std.mem.indexOfScalarPos(u8, chunk, i, '\n') orelse {
                // No newline in this chunk's remainder — extend carry and stop.
                try appendBounded(&f.carry, self.allocator, chunk[i..]);
                return;
            };
            const segment = chunk[i..newline];
            if (f.carry.items.len == 0) {
                try self.handleLine(f, segment);
            } else {
                try appendBounded(&f.carry, self.allocator, segment);
                try self.handleLine(f, f.carry.items);
                f.carry.clearRetainingCapacity();
            }
            i = newline + 1;
        }
    }

    fn handleLine(self: *Watcher, f: *FileState, line_in: []const u8) !void {
        const line = if (line_in.len > max_line_bytes) line_in[0..max_line_bytes] else line_in;
        const level = signature.extractLevel(line);
        self.metrics.observeLine(level, line.len);

        const now_ms = nowMs(self.io);
        f.last_line_ms = now_ms;

        var fired: [8]rules.Fired = undefined;
        const n = try self.rules.observe(self.io, line, level, f.path, now_ms, &fired);
        for (fired[0..n]) |entry| self.dispatcher.dispatch(entry, now_ms);

        if (f.tracker) |*t| {
            while (t.observe(line, level, &self.detector, now_ms)) |ev| {
                self.dispatcher.dispatchService(ev, now_ms);
                if (!t.refeed) break;
            }
        }
    }

    fn runSilenceChecks(self: *Watcher, now_ms: i64) void {
        var fired: [1]rules.Fired = undefined;
        for (self.files) |*f| {
            const n = self.rules.checkSilence(
                self.io,
                f.path,
                f.last_line_ms,
                now_ms,
                &f.silence_latch_epoch,
                &fired,
            );
            for (fired[0..n]) |entry| self.dispatcher.dispatch(entry, now_ms);
        }
    }
};

/// Records the first `head_bytes` of the file (fewer if it is shorter).
fn readHead(io: std.Io, f: *FileState, fd: std.Io.File) !void {
    const n = try fd.readPositional(io, &.{f.head[0..]}, 0);
    f.head_len = @intCast(@min(n, f.position));
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

/// Appends `extra` to `carry`, capping at `max_line_bytes` total. Bytes beyond
/// the cap are discarded so a runaway line can't blow up the watcher's RSS.
fn appendBounded(
    carry: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    extra: []const u8,
) !void {
    if (carry.items.len >= max_line_bytes) return;
    const room = max_line_bytes - carry.items.len;
    const slice = if (extra.len > room) extra[0..room] else extra;
    try carry.appendSlice(allocator, slice);
}

// ─── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A watcher over one file in a temp dir, with nothing configured to fire.
const Fixture = struct {
    tmp: testing.TmpDir,
    path_buf: [160]u8 = undefined,
    path: []const u8 = "",
    m: metrics.Metrics,
    cfg: config.AgentConfig,
    rs: rules.RuleSet,
    d: alert.Dispatcher,
    w: Watcher = undefined,
    paths: [1][]const u8 = undefined,

    fn init(self: *Fixture, initial: ?[]const u8) !void {
        const io = std.Options.debug_io;
        self.tmp = testing.tmpDir(.{});
        self.path = try std.fmt.bufPrint(&self.path_buf, ".zig-cache/tmp/{s}/app.log", .{self.tmp.sub_path});
        if (initial) |data| try self.write(data, .{});
        self.m = metrics.Metrics.init(0);
        self.cfg = try config.AgentConfig.fromArgs(testing.allocator, .{});
        self.rs = try rules.RuleSet.init(testing.allocator, self.cfg);
        self.d = try alert.Dispatcher.init(io, self.cfg.sinks, &self.m, false);
        self.paths = .{self.path};
        self.w = try Watcher.init(testing.allocator, io, &self.m, &self.rs, &self.d, &self.cfg, &self.paths);
    }

    fn deinit(self: *Fixture) void {
        self.w.deinit();
        self.d.deinit();
        self.rs.deinit();
        self.cfg.deinit(testing.allocator);
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, data: []const u8, opts: struct { append: bool = false }) !void {
        const io = std.Options.debug_io;
        const f = try std.Io.Dir.cwd().createFile(io, self.path, .{ .truncate = !opts.append, .read = true });
        defer f.close(io);
        try f.writePositionalAll(io, data, if (opts.append) try f.length(io) else 0);
    }

    fn rename(self: *Fixture, suffix: []const u8) !void {
        var buf: [176]u8 = undefined;
        const to = try std.fmt.bufPrint(&buf, "{s}{s}", .{ self.path, suffix });
        try std.Io.Dir.cwd().rename(self.path, std.Io.Dir.cwd(), to, std.Options.debug_io);
    }

    fn drain(self: *Fixture) !void {
        _ = try self.w.drainFile(&self.w.files[0]);
    }

    fn lines(self: *Fixture) u64 {
        var n: u64 = 0;
        for (&self.m.lines_total) |*c| n += c.load(.monotonic);
        return n;
    }
};

test "mv rotation: the old file is read to its end before the new one" {
    var fx: Fixture = undefined;
    try fx.init("old history\n");
    defer fx.deinit();

    // Written after the last poll, right before logrotate's rename.
    try fx.write("a\nb\nunterminated", .{ .append = true });
    try fx.rename(".1");
    try fx.write("c\nd\n", .{});
    try fx.drain();
    // a, b, the old file's unfinished last line, c, d.
    try testing.expectEqual(@as(u64, 5), fx.lines());
}

test "delete and recreate: the unlinked file is still drained" {
    var fx: Fixture = undefined;
    try fx.init("");
    defer fx.deinit();

    try fx.write("a\nb\n", .{ .append = true });
    try std.Io.Dir.cwd().deleteFile(std.Options.debug_io, fx.path);
    try fx.write("c\n", .{});
    try fx.drain();
    try testing.expectEqual(@as(u64, 3), fx.lines());
}

test "copytruncate refilled past the old offset is still seen as a restart" {
    var fx: Fixture = undefined;
    try fx.init("2026-10-14 10:00:00 first\n");
    defer fx.deinit();
    try fx.drain();

    // Truncated and rewritten by the time of the next poll, already longer
    // than before, so the size alone says nothing happened.
    try fx.write("2026-10-14 11:00:00 new one\n2026-10-14 11:00:01 new two\n", .{});
    try fx.drain();
    try testing.expectEqual(@as(u64, 2), fx.lines());
}

test "a file that does not exist at start is followed from its start once it does" {
    var fx: Fixture = undefined;
    try fx.init(null);
    defer fx.deinit();

    try fx.drain();
    try testing.expectEqual(@as(u64, 0), fx.lines());
    try fx.write("a\nb\nc\n", .{});
    try fx.drain();
    try testing.expectEqual(@as(u64, 3), fx.lines());
}
