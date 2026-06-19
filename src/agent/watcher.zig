//! Multi-file follow loop for agent mode.
//!
//! Stays minimal on purpose: positional reads, partial-line carry, and a
//! short sleep when nothing new arrived. Truncation (size shrank below the
//! tracked position) is handled by resetting to the start of the file and
//! bumping `file_rotation_total`.

const std = @import("std");
const flags = @import("flags");
const regex = @import("regex");

const alert = @import("alert.zig");
const config = @import("config.zig");
const metrics = @import("metrics.zig");
const rules = @import("rules.zig");
const service = @import("service.zig");
const signature = @import("signature.zig");

const log = std.log.scoped(.zlrd_watcher);

const read_buf_size = 64 * 1024;
const poll_interval_ms = 100;
const silence_check_interval_ms = 1_000;
/// Cap on a single line. Anything longer is truncated; the truncated portion
/// is dropped (and the next byte after the cap starts a new line).
///
/// Sized at 8 KiB so realistic structured log lines (multi-KB JSON, java
/// stack frames) fit without truncation. The previous 1.5 KiB cap was too
/// aggressive — it broke first-seen signature computation and crash-marker
/// detection for any line where the marker sat past the cap. The signature
/// buffer in `signature.zig` is sized to match.
const max_line_bytes = 8 * 1024;

const FileState = struct {
    path: []const u8,
    fd: std.Io.File,
    position: u64,
    carry: std.ArrayList(u8),
    last_line_ms: i64,
    /// Inode of the file currently open under this path. Compared against a
    /// path-level stat each iteration to detect rotation / restart.
    inode: u64,
    /// Per-file lifecycle tracker. Non-null only when the file's path is
    /// bound to a `--service NAME=PATH` mapping.
    tracker: ?service.Tracker,
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
                f.fd.close(io);
                f.carry.deinit(allocator);
            }
        }

        const now = nowMs(io);
        for (paths, 0..) |path, i| {
            const fd = try std.Io.Dir.cwd().openFile(io, path, .{});
            errdefer fd.close(io);
            const stat = try fd.stat(io);
            const tracker_opt: ?service.Tracker = if (cfg.serviceForPath(path)) |svc_name|
                service.Tracker.init(svc_name, path, now)
            else
                null;
            files[i] = .{
                .path = path,
                .fd = fd,
                .position = stat.size,
                .carry = .empty,
                .last_line_ms = now,
                .inode = stat.inode,
                .tracker = tracker_opt,
            };
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
            f.fd.close(self.io);
            f.carry.deinit(self.allocator);
        }
        self.allocator.free(self.files);
        self.allocator.free(self.read_buf);
        self.allocator.free(self.crash_regexes);
        self.* = undefined;
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

    /// Reads at most one `read_buf_size` chunk per call so the outer loop
    /// in `run()` round-robins fairly across all watched files. The previous
    /// implementation drained one file to EOF before moving on — a busy file
    /// could starve all the others. The outer loop sets `any_read=true`
    /// whenever any file produced bytes, so fast files still get back-to-back
    /// iterations and aren't throttled by the no-data sleep.
    fn drainFile(self: *Watcher, f: *FileState) !usize {
        // Path-level stat catches the "logrotate / restart created a new
        // file at this path" case — the open fd still points at the old
        // (possibly unlinked) inode, so its fstat() would never notice.
        if (std.Io.Dir.cwd().statFile(self.io, f.path, .{})) |path_stat| {
            if (path_stat.inode != f.inode) {
                try self.handleRotation(f, path_stat.inode);
            }
        } else |_| {
            // Path temporarily missing during a swap — keep using the
            // existing fd until the path resolves again.
        }

        const stat = try f.fd.stat(self.io);

        // Truncation: file shrank under us (in-place truncate, not rotation).
        if (stat.size < f.position) {
            self.metrics.observeRotation();
            f.position = 0;
            f.carry.clearRetainingCapacity();
        }
        if (stat.size == f.position) return 0;

        const n = try f.fd.readPositional(self.io, &.{self.read_buf}, f.position);
        if (n == 0) return 0;
        f.position += n;
        try self.processChunk(f, self.read_buf[0..n]);
        return n;
    }

    fn handleRotation(self: *Watcher, f: *FileState, new_inode: u64) !void {
        f.fd.close(self.io);
        f.fd = try std.Io.Dir.cwd().openFile(self.io, f.path, .{});
        f.inode = new_inode;
        f.position = 0;
        f.carry.clearRetainingCapacity();
        self.metrics.observeRotation();

        if (f.tracker) |*t| {
            const now_ms = nowMs(self.io);
            const ev = t.observeInodeChange(now_ms);
            self.dispatcher.dispatchService(ev, now_ms);
        }
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
            if (t.observe(line, level, &self.detector, now_ms)) |ev| {
                self.dispatcher.dispatchService(ev, now_ms);
            }
        }
    }

    fn runSilenceChecks(self: *Watcher, now_ms: i64) void {
        var fired: [1]rules.Fired = undefined;
        for (self.files) |*f| {
            const n = self.rules.checkSilence(self.io, f.path, f.last_line_ms, now_ms, &fired);
            for (fired[0..n]) |entry| self.dispatcher.dispatch(entry, now_ms);
        }
    }
};

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
