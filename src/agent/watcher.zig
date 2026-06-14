//! Multi-file follow loop for agent mode.
//!
//! Stays minimal on purpose: positional reads, partial-line carry, and a
//! short sleep when nothing new arrived. Truncation (size shrank below the
//! tracked position) is handled by resetting to the start of the file and
//! bumping `file_rotation_total`.

const std = @import("std");
const flags = @import("flags");

const alert = @import("alert.zig");
const metrics = @import("metrics.zig");
const rules = @import("rules.zig");
const signature = @import("signature.zig");

const log = std.log.scoped(.zlrd_watcher);

const read_buf_size = 64 * 1024;
const poll_interval_ms = 100;
const silence_check_interval_ms = 1_000;
/// Cap on a single line. Anything longer is truncated; the truncated portion
/// is dropped (and the next byte after the cap starts a new line). Matches the
/// JSON payload buffer we use for alerts.
const max_line_bytes = 1_536;

const FileState = struct {
    path: []const u8,
    fd: std.Io.File,
    position: u64,
    carry: std.ArrayList(u8),
    last_line_ms: i64,
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

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        m: *metrics.Metrics,
        rs: *rules.RuleSet,
        dispatcher: *alert.Dispatcher,
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
            files[i] = .{
                .path = path,
                .fd = fd,
                .position = stat.size,
                .carry = .empty,
                .last_line_ms = now,
            };
            opened += 1;
        }

        const buf = try allocator.alloc(u8, read_buf_size);
        errdefer allocator.free(buf);

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
        };
    }

    pub fn deinit(self: *Watcher) void {
        for (self.files) |*f| {
            f.fd.close(self.io);
            f.carry.deinit(self.allocator);
        }
        self.allocator.free(self.files);
        self.allocator.free(self.read_buf);
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

            if (!any_read) {
                std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(poll_interval_ms), .awake) catch break;
            }
        }
    }

    fn drainFile(self: *Watcher, f: *FileState) !usize {
        const stat = try f.fd.stat(self.io);

        // Truncation / rotation: file shrank under us.
        if (stat.size < f.position) {
            self.metrics.observeRotation();
            f.position = 0;
            f.carry.clearRetainingCapacity();
        }
        if (stat.size == f.position) return 0;

        var consumed: usize = 0;
        while (true) {
            const n = try f.fd.readPositional(self.io, &.{self.read_buf}, f.position);
            if (n == 0) break;
            consumed += n;
            f.position += n;
            try self.processChunk(f, self.read_buf[0..n]);
            if (n < self.read_buf.len) break;
        }
        return consumed;
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
