//! Ordered parallel scan over line-aligned chunks.
//!
//! `grep`, `less` and `awk` are single-threaded, so a machine with eight
//! cores spends seven of them idle while one walks the file. This splits the
//! input at line boundaries, hands the pieces to a pool, and writes the
//! results back **in the original order** — the output is byte-for-byte what
//! the serial path produces, which is the only version of this worth having.
//!
//! Nothing here knows what a log line is. It takes a `Worker` type with a
//! `process` method and moves bytes around it, which keeps the threading in
//! one testable place instead of tangled through the reader.
//!
//! ## How the order is kept without a queue
//!
//! Worker `w` owns chunks `w`, `w+W`, `w+2W`, … so the writer always knows
//! which worker owes it chunk `i`: worker `i % W`. There is no work queue, no
//! stealing and no completed-chunk map — just one buffer per worker and a
//! condition variable.
//!
//! That also bounds memory, which a queue would not. A worker that finishes
//! early blocks until the writer has taken its buffer, so at most `W` chunks
//! are ever in flight. Peak cost is `workers × chunk_bytes × (1 + output
//! ratio)`, and nothing grows with the size of the file.
//!
//! ## Why boundaries are computed up front
//!
//! Splitting at `i * chunk_bytes` would cut lines in half. Each split is
//! therefore pushed forward to just past the next newline, once, in the
//! calling thread. Doing it inside the workers would have every one of them
//! re-derive the same answer, and — worse — a worker cannot know where its
//! chunk *starts* without finding the boundary before it.

const std = @import("std");

/// The synchronisation primitives in `std.Io` all take an `Io`. This is the
/// same one the rest of the reader uses.
const io = std.Options.debug_io;

/// A byte source the scan can read at arbitrary offsets. Backed by a file in
/// production and by a slice in the tests, so none of the logic below needs a
/// filesystem to exercise.
pub const Source = struct {
    ctx: *anyopaque,
    size: u64,
    read_at: *const fn (ctx: *anyopaque, pos: u64, dst: []u8) usize,

    pub fn readAt(self: Source, pos: u64, dst: []u8) usize {
        if (pos >= self.size) return 0;
        const want: usize = @intCast(@min(@as(u64, dst.len), self.size - pos));
        return self.read_at(self.ctx, pos, dst[0..want]);
    }

    pub fn fromSlice(data: *const []const u8) Source {
        return .{
            .ctx = @ptrCast(@constCast(data)),
            .size = data.len,
            .read_at = struct {
                fn f(ctx: *anyopaque, pos: u64, dst: []u8) usize {
                    const d: *const []const u8 = @ptrCast(@alignCast(ctx));
                    const from: usize = @intCast(pos);
                    const n = @min(dst.len, d.len - from);
                    @memcpy(dst[0..n], d.*[from..][0..n]);
                    return n;
                }
            }.f,
        };
    }
};

/// Bytes probed at a time when pushing a split forward to a line boundary.
const probe_bytes: usize = 64 * 1024;

/// Splits `[0, source.size)` into ranges that each end just past a newline.
///
/// Returns `n + 1` offsets describing `n` chunks: chunk `i` is
/// `[bounds[i], bounds[i+1])`. Always at least `{0, size}`, so the caller
/// never has to special-case a file with no newline in it.
///
/// A split that cannot find a newline within `max_line_bytes` is dropped
/// rather than forced. Forcing it would cut a line, and a line that long is
/// already at the reader's own cap — one oversized record is not worth
/// producing a chunk that renders it wrong.
pub fn computeBoundaries(
    allocator: std.mem.Allocator,
    source: Source,
    chunk_bytes: usize,
    max_line_bytes: usize,
) ![]u64 {
    var bounds: std.ArrayList(u64) = .empty;
    errdefer bounds.deinit(allocator);
    try bounds.append(allocator, 0);

    if (source.size == 0 or chunk_bytes == 0) {
        try bounds.append(allocator, source.size);
        return bounds.toOwnedSlice(allocator);
    }

    var probe: [probe_bytes]u8 = undefined;
    var split: u64 = chunk_bytes;
    while (split < source.size) : (split += chunk_bytes) {
        if (lineStartAtOrAfter(source, split, max_line_bytes, &probe)) |b| {
            // Zero-length chunks help nobody, and a boundary that lands on
            // the end of the file is the end of the file.
            if (b > bounds.items[bounds.items.len - 1] and b < source.size) {
                try bounds.append(allocator, b);
            }
        }
    }

    try bounds.append(allocator, source.size);
    return bounds.toOwnedSlice(allocator);
}

/// Offset just past the first newline at or after `pos`, or null when there
/// is none within `limit` bytes.
fn lineStartAtOrAfter(source: Source, pos: u64, limit: usize, probe: []u8) ?u64 {
    var at = pos;
    var scanned: usize = 0;
    while (scanned < limit and at < source.size) {
        const n = source.readAt(at, probe);
        if (n == 0) return null;
        if (std.mem.indexOfScalar(u8, probe[0..n], '\n')) |nl| return at + nl + 1;
        at += n;
        scanned += n;
    }
    return null;
}

/// Sink for finished chunks. Returns false to stop the scan — the reader on
/// the other end of the pipe went away, and formatting the rest of a file
/// nobody will read is wasted work.
pub const WriteFn = *const fn (ctx: *anyopaque, bytes: []const u8) bool;

pub const Options = struct {
    /// Target input bytes per chunk before line alignment.
    chunk_bytes: usize = 1 << 20,
    /// Cap used when pushing a split to a line boundary.
    max_line_bytes: usize = 4 << 20,
};

/// Runs `workers.len` threads over the chunks of `source`, writing the
/// results in order through `write`.
///
/// `Worker` must provide:
///
///     fn process(self: *Worker, chunk: []const u8, out: *std.ArrayList(u8)) void
///
/// Each worker is called only from its own thread, so it may hold whatever
/// per-thread scratch it likes — buffers, filter state, an expander — without
/// synchronisation.
pub fn run(
    comptime Worker: type,
    allocator: std.mem.Allocator,
    source: Source,
    bounds: []const u64,
    workers: []Worker,
    write_ctx: *anyopaque,
    write: WriteFn,
    opts: Options,
) !void {
    const chunk_count = bounds.len - 1;
    const worker_count = @min(workers.len, @max(chunk_count, 1));
    if (chunk_count == 0) return;

    var shared = Shared{
        .source = source,
        .bounds = bounds,
        .chunk_count = chunk_count,
        .worker_count = worker_count,
    };

    const slots = try allocator.alloc(Slot, worker_count);
    defer {
        for (slots) |*s| {
            s.in.deinit(allocator);
            s.out.deinit(allocator);
        }
        allocator.free(slots);
    }
    for (slots) |*s| s.* = .{};

    // Every buffer is reserved before a thread starts. An allocation failure
    // here is recoverable — the caller falls back to the serial path — while
    // one inside a worker would have to be reported across a thread boundary
    // for no gain.
    const reserve = opts.chunk_bytes + opts.chunk_bytes / 4;
    for (slots) |*s| {
        try s.in.ensureTotalCapacity(allocator, reserve);
        try s.out.ensureTotalCapacity(allocator, reserve);
    }

    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);

    var started: usize = 0;
    errdefer {
        // Unblock and reap whatever did start, so a failed spawn cannot leave
        // threads parked on the condition variable.
        shared.mutex.lockUncancelable(io);
        shared.stopped = true;
        shared.cond.broadcast(io);
        shared.mutex.unlock(io);
        for (threads[0..started]) |t| t.join();
    }

    while (started < worker_count) : (started += 1) {
        threads[started] = try std.Thread.spawn(.{}, workerMain, .{
            Worker,            allocator, &shared, &slots[started],
            &workers[started], started,
        });
    }

    // The writer is this thread: chunk `i` is owed by worker `i % W`, and it
    // is parked until we take the buffer, so the bytes stay put while we
    // write them without holding the lock.
    var i: usize = 0;
    while (i < chunk_count) : (i += 1) {
        const slot = &slots[i % worker_count];

        shared.mutex.lockUncancelable(io);
        while (!slot.ready and !shared.stopped) shared.cond.waitUncancelable(io, &shared.mutex);
        const stopped = shared.stopped;
        shared.mutex.unlock(io);
        if (stopped and !slot.ready) break;

        const keep_going = write(write_ctx, slot.out.items);

        shared.mutex.lockUncancelable(io);
        slot.ready = false;
        if (!keep_going) shared.stopped = true;
        shared.cond.broadcast(io);
        shared.mutex.unlock(io);
        if (!keep_going) break;
    }

    shared.mutex.lockUncancelable(io);
    shared.stopped = true;
    shared.cond.broadcast(io);
    shared.mutex.unlock(io);

    for (threads[0..started]) |t| t.join();
}

const Slot = struct {
    in: std.ArrayList(u8) = .empty,
    out: std.ArrayList(u8) = .empty,
    /// Set by the worker when `out` holds a finished chunk, cleared by the
    /// writer once it has been written.
    ready: bool = false,
};

const Shared = struct {
    source: Source,
    bounds: []const u64,
    chunk_count: usize,
    worker_count: usize,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    stopped: bool = false,
};

fn workerMain(
    comptime Worker: type,
    allocator: std.mem.Allocator,
    shared: *Shared,
    slot: *Slot,
    worker: *Worker,
    index: usize,
) void {
    var i = index;
    while (i < shared.chunk_count) : (i += shared.worker_count) {
        {
            shared.mutex.lockUncancelable(io);
            defer shared.mutex.unlock(io);
            if (shared.stopped) return;
        }

        const start = shared.bounds[i];
        const end = shared.bounds[i + 1];
        const len: usize = @intCast(end - start);

        slot.in.clearRetainingCapacity();
        slot.in.ensureTotalCapacity(allocator, len) catch return;
        slot.in.items.len = len;

        var got: usize = 0;
        while (got < len) {
            const n = shared.source.readAt(start + got, slot.in.items[got..]);
            if (n == 0) break;
            got += n;
        }
        slot.in.items.len = got;

        slot.out.clearRetainingCapacity();
        worker.process(slot.in.items, &slot.out);

        shared.mutex.lockUncancelable(io);
        slot.ready = true;
        shared.cond.broadcast(io);
        // Hold here until the writer has taken the buffer. This is what caps
        // memory at one chunk per worker instead of letting a fast thread run
        // the whole file into RAM.
        while (slot.ready and !shared.stopped) shared.cond.waitUncancelable(io, &shared.mutex);
        const stopped = shared.stopped;
        shared.mutex.unlock(io);
        if (stopped) return;
    }
}

/// Threads worth using for `size` bytes, or 1 when the work is too small to
/// pay for the pool.
pub fn suggestedWorkers(size: u64, chunk_bytes: usize, cap: usize) usize {
    if (chunk_bytes == 0) return 1;
    const chunks = size / chunk_bytes;
    if (chunks < 2) return 1;
    const cpus = std.Thread.getCpuCount() catch return 1;
    return @max(1, @min(@min(cpus, cap), @as(usize, @intCast(chunks))));
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

fn fillLines(buf: *std.ArrayList(u8), count: usize, label: []const u8) !void {
    var scratch: [64]u8 = undefined;
    for (0..count) |i| {
        const line = try std.fmt.bufPrint(&scratch, "{s} {d}\n", .{ label, i });
        try buf.appendSlice(testing.allocator, line);
    }
}

fn sliceSource(data: *const []const u8) Source {
    return Source.fromSlice(data);
}

test "boundaries always describe the whole input" {
    const data: []const u8 = "a\nb\nc\n";
    const b = try computeBoundaries(testing.allocator, sliceSource(&data), 2, 1024);
    defer testing.allocator.free(b);
    try testing.expectEqual(@as(u64, 0), b[0]);
    try testing.expectEqual(@as(u64, data.len), b[b.len - 1]);
}

test "every boundary lands just past a newline" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try fillLines(&buf, 500, "line");
    const data: []const u8 = buf.items;

    const b = try computeBoundaries(testing.allocator, sliceSource(&data), 128, 1024);
    defer testing.allocator.free(b);
    try testing.expect(b.len > 2);

    for (b[1 .. b.len - 1]) |off| {
        try testing.expectEqual(@as(u8, '\n'), data[@intCast(off - 1)]);
    }
    // Strictly increasing, so no chunk is empty and none overlaps.
    for (b[1..], 0..) |off, i| try testing.expect(off > b[i]);
}

test "chunks reassemble into the original bytes" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try fillLines(&buf, 300, "record");
    const data: []const u8 = buf.items;

    const b = try computeBoundaries(testing.allocator, sliceSource(&data), 100, 1024);
    defer testing.allocator.free(b);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (b[1..], 0..) |end, i| {
        try joined.appendSlice(testing.allocator, data[@intCast(b[i])..@intCast(end)]);
    }
    try testing.expectEqualSlices(u8, data, joined.items);
}

test "a file with no newline stays a single chunk" {
    const data: []const u8 = "one very long line with no terminator";
    const b = try computeBoundaries(testing.allocator, sliceSource(&data), 8, 1024);
    defer testing.allocator.free(b);
    try testing.expectEqual(@as(usize, 2), b.len);
    try testing.expectEqual(@as(u64, data.len), b[1]);
}

test "a line longer than the cap is not cut in half" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendNTimes(testing.allocator, 'x', 4096);
    try buf.append(testing.allocator, '\n');
    try buf.appendSlice(testing.allocator, "short\n");
    const data: []const u8 = buf.items;

    // Splits every 512 bytes, but no newline is reachable within 64 bytes of
    // them, so those splits are dropped instead of slicing the long line.
    const b = try computeBoundaries(testing.allocator, sliceSource(&data), 512, 64);
    defer testing.allocator.free(b);
    for (b[1 .. b.len - 1]) |off| {
        try testing.expectEqual(@as(u8, '\n'), data[@intCast(off - 1)]);
    }
}

test "an empty input yields one empty chunk" {
    const data: []const u8 = "";
    const b = try computeBoundaries(testing.allocator, sliceSource(&data), 16, 1024);
    defer testing.allocator.free(b);
    try testing.expectEqual(@as(usize, 2), b.len);
    try testing.expectEqual(@as(u64, 0), b[1]);
}

/// Uppercases every line, so the output order is verifiable by eye and any
/// chunk written out of turn shows up immediately.
const UpperWorker = struct {
    allocator: std.mem.Allocator,
    calls: usize = 0,

    fn process(self: *UpperWorker, chunk: []const u8, out: *std.ArrayList(u8)) void {
        self.calls += 1;
        var it = std.mem.splitScalar(u8, chunk, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            for (line) |c| out.append(self.allocator, std.ascii.toUpper(c)) catch return;
            out.append(self.allocator, '\n') catch return;
        }
    }
};

const Collector = struct {
    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    stop_after: ?usize = null,
    writes: usize = 0,

    fn write(ctx: *anyopaque, bytes: []const u8) bool {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        self.writes += 1;
        self.buf.appendSlice(self.allocator, bytes) catch return false;
        if (self.stop_after) |n| return self.writes < n;
        return true;
    }
};

fn runUpper(allocator: std.mem.Allocator, data: []const u8, workers_n: usize, chunk_bytes: usize) ![]u8 {
    const src = Source.fromSlice(&data);
    const bounds = try computeBoundaries(allocator, src, chunk_bytes, 1024);
    defer allocator.free(bounds);

    const workers = try allocator.alloc(UpperWorker, workers_n);
    defer allocator.free(workers);
    for (workers) |*w| w.* = .{ .allocator = allocator };

    var sink = Collector{ .allocator = allocator };
    errdefer sink.buf.deinit(allocator);

    try run(UpperWorker, allocator, src, bounds, workers, &sink, Collector.write, .{
        .chunk_bytes = chunk_bytes,
        .max_line_bytes = 1024,
    });
    return sink.buf.toOwnedSlice(allocator);
}

test "parallel output is identical to serial output" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try fillLines(&buf, 2000, "record payload here");
    const data: []const u8 = buf.items;

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    for (data) |c| try expected.append(testing.allocator, std.ascii.toUpper(c));

    // Same input, same answer, whatever the thread count — which is the only
    // property that makes this worth having.
    for ([_]usize{ 1, 2, 3, 8 }) |n| {
        const got = try runUpper(testing.allocator, data, n, 256);
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u8, expected.items, got);
    }
}

test "one worker and one chunk still work" {
    const data: []const u8 = "only\n";
    const got = try runUpper(testing.allocator, data, 4, 1 << 20);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("ONLY\n", got);
}

test "more workers than chunks leaves the extra threads idle, not stuck" {
    const data: []const u8 = "a\nb\n";
    const got = try runUpper(testing.allocator, data, 16, 1 << 20);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("A\nB\n", got);
}

test "a sink that stops early unblocks every worker" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try fillLines(&buf, 5000, "line");
    const data: []const u8 = buf.items;

    const src = Source.fromSlice(&data);
    const bounds = try computeBoundaries(testing.allocator, src, 128, 1024);
    defer testing.allocator.free(bounds);
    try testing.expect(bounds.len > 10);

    const workers = try testing.allocator.alloc(UpperWorker, 4);
    defer testing.allocator.free(workers);
    for (workers) |*w| w.* = .{ .allocator = testing.allocator };

    // Emulates `| head`: the writer refuses after the second chunk. Every
    // worker parked on the condition variable has to come back and exit, or
    // the join below never returns.
    var sink = Collector{ .allocator = testing.allocator, .stop_after = 2 };
    defer sink.buf.deinit(testing.allocator);

    try run(UpperWorker, testing.allocator, src, bounds, workers, &sink, Collector.write, .{});
    try testing.expectEqual(@as(usize, 2), sink.writes);
}

test "suggestedWorkers declines to spin up a pool for small input" {
    try testing.expectEqual(@as(usize, 1), suggestedWorkers(1024, 1 << 20, 8));
    try testing.expectEqual(@as(usize, 1), suggestedWorkers(0, 1 << 20, 8));
    // Capped by the caller's ceiling even on a large file.
    try testing.expect(suggestedWorkers(1 << 30, 1 << 20, 2) <= 2);
}
