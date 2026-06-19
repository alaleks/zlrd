//! Webhook sender: POSTs alert JSON payloads to one or more configured URLs.
//! Uses `std.http.Client` so both `http://` and `https://` work via the
//! standard library — no third-party deps.
//!
//! Concurrency model: producers (watcher thread, journal threads, kernel
//! monitor threads) call `send` from any thread. `send` clones the URL and
//! payload, pushes onto a bounded queue, and returns immediately. A single
//! worker thread drains the queue and performs the actual HTTP POSTs.
//!
//! This makes the producer side non-blocking (a wedged collector cannot
//! stall log processing) and keeps `std.http.Client` confined to one
//! thread (avoids races on the shared connection pool).
//!
//! Delivery is still best-effort: HTTP failures are logged via `std.log`
//! and the queue moves on. Backpressure: when the queue is full new events
//! are dropped and `dropped_total` increments.

const std = @import("std");

const config = @import("config.zig");

const log = std.log.scoped(.zlrd_webhook);

/// Bounded queue cap. Sized so a brief burst (1–2 seconds of high-rate
/// alerts) fits without dropping, but a wedged collector can't grow it
/// without bound.
pub const max_pending: usize = 256;

/// Polling cadence when the queue is empty. The worker also responds to
/// shutdown promptly because it checks the flag on every iteration.
const idle_sleep_ms: u32 = 50;

pub const Sender = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: std.http.Client,
    extra_headers: []std.http.Header,

    mutex: std.Io.Mutex = .init,
    /// Backing storage for the queue. Items are produced at the tail and
    /// consumed at `head`; we never shift the array. When the head catches
    /// the tail we reset both to 0 and `clearRetainingCapacity` the
    /// ArrayList so it doesn't grow without bound. This makes `takeOne`
    /// amortized O(1) — the previous `orderedRemove(0)` was O(n) and on
    /// burst-drain became O(n²) under the mutex.
    queue: std.ArrayList(QueuedPost),
    head: usize = 0,

    shutdown: std.atomic.Value(bool) = .init(false),
    /// Number of webhook events dropped since startup (queue full or
    /// allocation failure). Exposed for diagnostics.
    dropped_total: std.atomic.Value(u64) = .init(0),

    thread: ?std.Thread = null,

    const QueuedPost = struct {
        url: []u8,
        payload: []u8,

        fn deinit(self: *QueuedPost, allocator: std.mem.Allocator) void {
            allocator.free(self.url);
            allocator.free(self.payload);
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        headers: []const config.HeaderSpec,
    ) !Sender {
        const extra = try allocator.alloc(std.http.Header, headers.len);
        for (headers, 0..) |h, i| {
            extra[i] = .{ .name = h.name, .value = h.value };
        }
        return .{
            .allocator = allocator,
            .io = io,
            .client = .{ .allocator = allocator, .io = io },
            .extra_headers = extra,
            .queue = .empty,
        };
    }

    pub fn deinit(self: *Sender) void {
        self.stop();
        // Anything still queued at shutdown is dropped — the worker had
        // its chance during the drain phase of `stop`. Only items at
        // index `head..len` are live; the head-skipped slots have
        // already been consumed and freed.
        for (self.queue.items[self.head..]) |*q| q.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        self.client.deinit();
        self.allocator.free(self.extra_headers);
        self.* = undefined;
    }

    pub fn start(self: *Sender) !void {
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    /// Signals shutdown and joins the worker. Idempotent.
    pub fn stop(self: *Sender) void {
        self.shutdown.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// Enqueues a webhook POST. Returns immediately — the actual HTTP call
    /// happens on the worker thread. Drops the event if the queue is full
    /// or allocation fails; `dropped_total` is incremented in either case.
    pub fn send(self: *Sender, url: []const u8, payload: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const pending = self.queue.items.len - self.head;
        if (pending >= max_pending) {
            _ = self.dropped_total.fetchAdd(1, .monotonic);
            return;
        }

        const url_copy = self.allocator.dupe(u8, url) catch {
            _ = self.dropped_total.fetchAdd(1, .monotonic);
            return;
        };
        errdefer self.allocator.free(url_copy);

        const payload_copy = self.allocator.dupe(u8, payload) catch {
            _ = self.dropped_total.fetchAdd(1, .monotonic);
            return;
        };
        errdefer self.allocator.free(payload_copy);

        self.queue.append(self.allocator, .{
            .url = url_copy,
            .payload = payload_copy,
        }) catch {
            _ = self.dropped_total.fetchAdd(1, .monotonic);
        };
    }

    fn runLoop(self: *Sender) void {
        while (!self.shutdown.load(.acquire)) {
            const work = self.takeOne() orelse {
                std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(idle_sleep_ms), .awake) catch break;
                continue;
            };
            self.postOne(work.url, work.payload);
            self.allocator.free(work.url);
            self.allocator.free(work.payload);
        }

        // Drain whatever remained at shutdown. Best-effort — we still want
        // alerts that producers enqueued moments before stop to land.
        while (self.takeOne()) |work| {
            self.postOne(work.url, work.payload);
            self.allocator.free(work.url);
            self.allocator.free(work.payload);
        }
    }

    /// Pops the oldest queued item in amortized O(1). We advance `head`
    /// instead of shifting the array; once everything in the current
    /// batch has been drained the ArrayList is cleared so it doesn't
    /// keep growing across bursts.
    fn takeOne(self: *Sender) ?QueuedPost {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.head >= self.queue.items.len) return null;
        const item = self.queue.items[self.head];
        self.head += 1;
        if (self.head == self.queue.items.len) {
            self.head = 0;
            self.queue.clearRetainingCapacity();
        }
        return item;
    }

    fn postOne(self: *Sender, url: []const u8, payload: []const u8) void {
        const result = self.client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = self.extra_headers,
        }) catch |err| {
            log.warn("webhook POST {s} failed: {t}", .{ url, err });
            return;
        };

        const code = @intFromEnum(result.status);
        if (code >= 400) {
            log.warn("webhook POST {s} returned {d}", .{ url, code });
        }
    }
};

/// Thunk that adapts `Sender.send` to `alert.WebhookSender`'s `*anyopaque`
/// signature. `ctx` must be a `*Sender`.
pub fn sendThunk(ctx: ?*anyopaque, url: []const u8, payload: []const u8) void {
    const sender: *Sender = @ptrCast(@alignCast(ctx orelse return));
    sender.send(url, payload);
}

// ─── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Sender: drops events past max_pending" {
    const io = std.Options.debug_io;
    var sender = try Sender.init(testing.allocator, io, &.{});
    defer sender.deinit();
    // Don't start the worker — we just want to verify the bounded enqueue.

    var i: usize = 0;
    while (i < max_pending) : (i += 1) {
        sender.send("https://example.test/hook", "{}");
    }
    try testing.expectEqual(max_pending, sender.queue.items.len - sender.head);
    try testing.expectEqual(@as(u64, 0), sender.dropped_total.load(.monotonic));

    sender.send("https://example.test/hook", "{}");
    try testing.expectEqual(max_pending, sender.queue.items.len - sender.head);
    try testing.expectEqual(@as(u64, 1), sender.dropped_total.load(.monotonic));
}

test "Sender: takeOne returns items FIFO and resets when drained" {
    const io = std.Options.debug_io;
    var sender = try Sender.init(testing.allocator, io, &.{});
    defer sender.deinit();

    sender.send("https://x/1", "{\"i\":1}");
    sender.send("https://x/2", "{\"i\":2}");
    sender.send("https://x/3", "{\"i\":3}");

    var first = sender.takeOne().?;
    try testing.expectEqualStrings("https://x/1", first.url);
    first.deinit(sender.allocator);

    var second = sender.takeOne().?;
    try testing.expectEqualStrings("https://x/2", second.url);
    second.deinit(sender.allocator);

    var third = sender.takeOne().?;
    try testing.expectEqualStrings("https://x/3", third.url);
    third.deinit(sender.allocator);

    // Fully drained — head must have been reset to 0 and storage cleared.
    try testing.expectEqual(@as(usize, 0), sender.head);
    try testing.expectEqual(@as(usize, 0), sender.queue.items.len);
    try testing.expect(sender.takeOne() == null);
}

test "Sender: stop is idempotent and safe before start" {
    const io = std.Options.debug_io;
    var sender = try Sender.init(testing.allocator, io, &.{});
    defer sender.deinit();
    sender.stop();
    sender.stop(); // second call is a no-op
}
