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
//! ## Delivery
//!
//! A POST that fails with a transport error, a 5xx, 408 or 429 is retried
//! with exponential backoff (`backoffMs`), held in a worker-only retry list
//! so one dead endpoint does not hold up the others. After `max_attempts` it
//! is parked in the spool — a small file next to the state file — and the
//! spool is replayed once every `spool_replay_ms`, one attempt per item per
//! round, for as long as it takes. Anything still in memory at shutdown is
//! parked too, and the next run picks it up. Other 4xx are the receiver
//! refusing the request; repeating it would not change the answer, so those
//! are logged and dropped.
//!
//! Without a spool (`--no-state`) retries still happen, but an alert that
//! exhausts them is dropped. Every drop increments `dropped_total`.
//!
//! ## Signing
//!
//! With `--webhook-secret`, every request carries
//! `X-Zlrd-Signature: sha256=<hex HMAC-SHA256 of the body>`, the scheme
//! GitHub uses, so a receiver can verify the body came from an agent that
//! holds the key. The payload's `ts_ms` lets it reject replays.

const std = @import("std");
const builtin = @import("builtin");

const config = @import("config.zig");

const log = std.log.scoped(.zlrd_webhook);

/// Bounded queue cap. Sized so a brief burst (1–2 seconds of high-rate
/// alerts) fits without dropping, but a wedged collector can't grow it
/// without bound. Also caps the retry list.
pub const max_pending: usize = 256;

/// Polling cadence when the queue is empty. The worker also responds to
/// shutdown promptly because it checks the flag on every iteration.
const idle_sleep_ms: u32 = 50;

/// Attempts in memory before an alert is parked in the spool: 1+2+4+8+16 s
/// of backoff between them, so about half a minute of outage is absorbed
/// without touching the disk.
pub const max_attempts: u8 = 6;
const base_backoff_ms: u64 = 1_000;
const max_backoff_ms: u64 = 60_000;

/// How often parked alerts are tried again.
pub const spool_replay_ms: i64 = 60_000;

/// Spool size cap. A chat message is a few KiB, so this holds hundreds of
/// alerts — a long outage — without the file becoming a log of its own.
pub const max_spool_bytes: u64 = 1 << 20;

pub const signature_header = "X-Zlrd-Signature";
const signature_prefix = "sha256=";
pub const signature_len = signature_prefix.len + std.crypto.auth.hmac.sha2.HmacSha256.mac_length * 2;

/// `sha256=<hex HMAC-SHA256(secret, body)>`.
pub fn sign(out: *[signature_len]u8, secret: []const u8, body: []const u8) []const u8 {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, body, secret);
    out[0..signature_prefix.len].* = signature_prefix.*;
    out[signature_prefix.len..].* = std.fmt.bytesToHex(mac, .lower);
    return out;
}

pub const Outcome = enum { delivered, retry, rejected };

/// What an HTTP status means for the alert that got it.
pub fn classify(status: u16) Outcome {
    if (status < 300) return .delivered;
    if (status == 408 or status == 429 or status >= 500) return .retry;
    return .rejected;
}

/// Wait before attempt `attempt + 1`: 1 s, doubling, capped at a minute.
pub fn backoffMs(attempt: u8) u64 {
    const shift: u6 = @intCast(@min(attempt -| 1, 16));
    return @min(base_backoff_ms << shift, max_backoff_ms);
}

pub const Options = struct {
    /// `--webhook-secret`. Null sends requests unsigned.
    secret: ?[]const u8 = null,
    /// Where undeliverable alerts wait. Null keeps retries in memory only.
    spool_path: ?[]const u8 = null,
};

pub const Sender = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: std.http.Client,
    /// The `--webhook-header` pairs, plus one trailing slot for the
    /// signature when a secret is set. Only the worker touches it.
    extra_headers: []std.http.Header,
    secret: ?[]const u8,

    mutex: std.Io.Mutex = .init,
    /// Backing storage for the queue. Items are produced at the tail and
    /// consumed at `head`; we never shift the array. When the head catches
    /// the tail we reset both to 0 and `clearRetainingCapacity` the
    /// ArrayList so it doesn't grow without bound. This makes `takeOne`
    /// amortized O(1) — the previous `orderedRemove(0)` was O(n) and on
    /// burst-drain became O(n²) under the mutex.
    queue: std.ArrayList(QueuedPost),
    head: usize = 0,

    /// Posts waiting for their next attempt. Worker-only, so unlocked.
    retry: std.ArrayList(QueuedPost) = .empty,
    spool: ?Spool = null,
    next_replay_ms: i64 = 0,
    /// The actual POST. A field so the tests can script outcomes without a
    /// network.
    post: *const fn (*Sender, []const u8, []const u8) Outcome = httpPost,

    shutdown: std.atomic.Value(bool) = .init(false),
    /// Number of webhook events dropped since startup (queue full,
    /// allocation failure, rejected or out of retries with no room in the
    /// spool). Exposed for diagnostics.
    dropped_total: std.atomic.Value(u64) = .init(0),

    thread: ?std.Thread = null,

    const QueuedPost = struct {
        url: []u8,
        payload: []u8,
        attempts: u8 = 0,
        due_ms: i64 = 0,

        fn deinit(self: *const QueuedPost, allocator: std.mem.Allocator) void {
            allocator.free(self.url);
            allocator.free(self.payload);
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        headers: []const config.HeaderSpec,
        opts: Options,
    ) !Sender {
        const extra = try allocator.alloc(std.http.Header, headers.len + @intFromBool(opts.secret != null));
        for (headers, 0..) |h, i| {
            extra[i] = .{ .name = h.name, .value = h.value };
        }
        var spool: ?Spool = null;
        if (opts.spool_path) |path| {
            spool = Spool.open(io, path, max_spool_bytes) catch |err| blk: {
                log.warn("webhook spool {s}: {t}; failed alerts will not survive a restart", .{ path, err });
                break :blk null;
            };
        }
        return .{
            .allocator = allocator,
            .io = io,
            .client = .{ .allocator = allocator, .io = io },
            .extra_headers = extra,
            .secret = opts.secret,
            .queue = .empty,
            .spool = spool,
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
        for (self.retry.items) |*q| q.deinit(self.allocator);
        self.retry.deinit(self.allocator);
        if (self.spool) |*s| s.close();
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
            if (self.step(nowMs(self.io))) continue;
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(idle_sleep_ms), .awake) catch break;
        }

        // Drain whatever remained at shutdown: one attempt each for the
        // fresh posts, so alerts enqueued moments before stop still land,
        // and the spool for everything that does not.
        const now = nowMs(self.io);
        while (self.takeOne()) |item| {
            var last = item;
            last.attempts = max_attempts - 1;
            self.attempt(last, now);
        }
        for (self.retry.items) |item| self.park(item);
        self.retry.clearRetainingCapacity();
    }

    /// One unit of work: replay the spool when it is due, then attempt the
    /// first retry that is due, else the oldest fresh post. Returns false
    /// when there was nothing to do.
    pub fn step(self: *Sender, now: i64) bool {
        if (self.spool != null and now >= self.next_replay_ms) {
            self.next_replay_ms = now + spool_replay_ms;
            self.replaySpool(now);
        }
        const item = self.takeDue(now) orelse self.takeOne() orelse return false;
        self.attempt(item, now);
        return true;
    }

    fn takeDue(self: *Sender, now: i64) ?QueuedPost {
        for (self.retry.items, 0..) |item, i| {
            if (item.due_ms <= now) return self.retry.orderedRemove(i);
        }
        return null;
    }

    /// Takes ownership of `item`.
    fn attempt(self: *Sender, item: QueuedPost, now: i64) void {
        switch (self.post(self, item.url, item.payload)) {
            .delivered => item.deinit(self.allocator),
            .rejected => {
                _ = self.dropped_total.fetchAdd(1, .monotonic);
                item.deinit(self.allocator);
            },
            .retry => {
                var next = item;
                next.attempts +|= 1;
                if (next.attempts >= max_attempts or self.retry.items.len >= max_pending) return self.park(next);
                next.due_ms = now + @as(i64, @intCast(backoffMs(next.attempts)));
                self.retry.append(self.allocator, next) catch self.park(next);
            },
        }
    }

    /// Moves a post that ran out of attempts to the spool, or drops it.
    /// Takes ownership of `item`.
    fn park(self: *Sender, item: QueuedPost) void {
        defer item.deinit(self.allocator);
        if (self.spool) |*s| if (s.append(item.url, item.payload)) return;
        _ = self.dropped_total.fetchAdd(1, .monotonic);
        log.warn("webhook {s}: dropped after {d} attempts", .{ item.url, item.attempts });
    }

    /// Moves parked posts back into the retry list, one attempt left each —
    /// they already used their in-memory retries, and the next round is
    /// only `spool_replay_ms` away. What does not fit goes back in the file.
    fn replaySpool(self: *Sender, now: i64) void {
        const s = &(self.spool orelse return);
        // shortcut: the file is emptied before the posts are re-parked, so a
        // crash in between loses them. Rewrite to a temp file and rename if
        // that window ever matters.
        const content = s.takeAll(self.allocator) catch |err| {
            log.warn("webhook spool: {t}", .{err});
            return;
        } orelse return;
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const rec = parseSpoolLine(line) orelse continue;
            if (self.retry.items.len >= max_pending) {
                _ = s.append(rec.url, rec.payload);
                continue;
            }
            const url = self.allocator.dupe(u8, rec.url) catch {
                _ = s.append(rec.url, rec.payload);
                continue;
            };
            const payload = self.allocator.dupe(u8, rec.payload) catch {
                self.allocator.free(url);
                _ = s.append(rec.url, rec.payload);
                continue;
            };
            const item: QueuedPost = .{ .url = url, .payload = payload, .attempts = max_attempts - 1, .due_ms = now };
            self.retry.append(self.allocator, item) catch self.park(item);
        }
    }

    /// Pops the oldest queued item in amortized O(1). We advance `head`
    /// instead of shifting the array on every pop.
    ///
    /// Reclaiming only when the queue hits exactly empty is not enough:
    /// `max_pending` bounds the *live window* (`items.len - head`), not the
    /// array behind it. Under sustained load — producers enqueueing at least
    /// as fast as the single worker can POST — `head` never catches the tail,
    /// so both indices climb together and the backing store grows without
    /// bound while `pending` looks healthy. Compacting once `head` passes
    /// `max_pending` caps the array at twice that, and each item is moved at
    /// most once per `max_pending` pops.
    fn takeOne(self: *Sender) ?QueuedPost {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.head >= self.queue.items.len) return null;
        const item = self.queue.items[self.head];
        self.head += 1;
        if (self.head == self.queue.items.len) {
            self.head = 0;
            self.queue.clearRetainingCapacity();
        } else if (self.head >= max_pending) {
            const live = self.queue.items[self.head..];
            std.mem.copyForwards(QueuedPost, self.queue.items[0..live.len], live);
            self.queue.items.len = live.len;
            self.head = 0;
        }
        return item;
    }

    fn httpPost(self: *Sender, url: []const u8, payload: []const u8) Outcome {
        var sig_buf: [signature_len]u8 = undefined;
        if (self.secret) |key| {
            self.extra_headers[self.extra_headers.len - 1] = .{
                .name = signature_header,
                .value = sign(&sig_buf, key, payload),
            };
        }
        const result = self.client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = self.extra_headers,
        }) catch |err| {
            log.warn("webhook POST {s} failed: {t}", .{ url, err });
            return .retry;
        };

        const code = @backingInt(result.status);
        const outcome = classify(code);
        if (outcome != .delivered) log.warn("webhook POST {s} returned {d}", .{ url, code });
        return outcome;
    }
};

fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

/// Undelivered posts on disk, one per line: `<url>\t<body>\n`. Both are
/// single-line by construction — every body is JSON with its newlines
/// escaped — so the file needs no framing beyond that.
///
/// Created 0600: a Telegram URL carries the bot token.
pub const Spool = struct {
    io: std.Io,
    file: std.Io.File,
    size: u64,
    max_bytes: u64,

    pub fn open(io: std.Io, path: []const u8, max_bytes: u64) !Spool {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{
            .truncate = false,
            .read = true,
            .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600),
        });
        errdefer file.close(io);
        return .{ .io = io, .file = file, .size = try file.length(io), .max_bytes = max_bytes };
    }

    pub fn close(self: *Spool) void {
        self.file.close(self.io);
    }

    /// False when the line does not fit under `max_bytes`, cannot be framed,
    /// or the write failed.
    pub fn append(self: *Spool, url: []const u8, payload: []const u8) bool {
        if (std.mem.indexOfAny(u8, url, "\t\n") != null or std.mem.indexOfScalar(u8, payload, '\n') != null) return false;
        const len = url.len + payload.len + 2;
        if (self.size + len > self.max_bytes) return false;
        const parts = [_][]const u8{ url, "\t", payload, "\n" };
        var off = self.size;
        for (parts) |p| {
            self.file.writePositionalAll(self.io, p, off) catch return false;
            off += p.len;
        }
        self.size = off;
        self.file.sync(self.io) catch {};
        return true;
    }

    /// The whole file, which is then emptied. Null when there is nothing in it.
    pub fn takeAll(self: *Spool, allocator: std.mem.Allocator) !?[]u8 {
        if (self.size == 0) return null;
        const buf = try allocator.alloc(u8, @intCast(self.size));
        errdefer allocator.free(buf);
        const n = try self.file.readPositionalAll(self.io, buf, 0);
        try self.file.setLength(self.io, 0);
        self.size = 0;
        return buf[0..n];
    }
};

const SpoolRecord = struct { url: []const u8, payload: []const u8 };

fn parseSpoolLine(line: []const u8) ?SpoolRecord {
    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return null;
    if (tab == 0 or tab + 1 == line.len) return null;
    return .{ .url = line[0..tab], .payload = line[tab + 1 ..] };
}

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
    var sender = try Sender.init(testing.allocator, io, &.{}, .{});
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
    var sender = try Sender.init(testing.allocator, io, &.{}, .{});
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
    var sender = try Sender.init(testing.allocator, io, &.{}, .{});
    defer sender.deinit();
    sender.stop();
    sender.stop(); // second call is a no-op
}

test "queue: the backing array stays bounded under sustained load" {
    // `max_pending` caps the live window, not the array. Draining one item
    // for every item enqueued keeps the queue permanently non-empty, so the
    // "clear when it hits empty" path never runs — and without compaction
    // both `head` and `items.len` climb forever.
    const allocator = testing.allocator;
    var sender = try Sender.init(allocator, std.Options.debug_io, &.{}, .{});
    defer sender.deinit();

    // Prime a live window, then hold it steady for many rounds.
    for (0..max_pending) |_| sender.send("https://example.invalid/hook", "{}");
    try testing.expectEqual(max_pending, sender.queue.items.len - sender.head);

    for (0..max_pending * 20) |_| {
        var item = sender.takeOne().?;
        item.deinit(allocator);
        sender.send("https://example.invalid/hook", "{}");
        // The live window never moves...
        try testing.expectEqual(max_pending, sender.queue.items.len - sender.head);
        // ...and neither does the array behind it.
        try testing.expect(sender.queue.items.len <= max_pending * 2);
    }
}

test "queue: compaction preserves order" {
    const allocator = testing.allocator;
    var sender = try Sender.init(allocator, std.Options.debug_io, &.{}, .{});
    defer sender.deinit();

    var buf: [32]u8 = undefined;
    for (0..max_pending) |i| {
        sender.send("https://example.invalid/hook", try std.fmt.bufPrint(&buf, "{d}", .{i}));
    }
    // Drive past the compaction threshold, checking FIFO order throughout.
    for (0..max_pending * 3) |i| {
        var item = sender.takeOne().?;
        defer item.deinit(allocator);
        const want = try std.fmt.bufPrint(&buf, "{d}", .{i});
        try testing.expectEqualStrings(want, item.payload);
        sender.send("https://example.invalid/hook", try std.fmt.bufPrint(&buf, "{d}", .{i + max_pending}));
    }
}

test "sign: HMAC-SHA256 matches RFC 4231 test case 2" {
    var out: [signature_len]u8 = undefined;
    try testing.expectEqualStrings(
        "sha256=5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
        sign(&out, "Jefe", "what do ya want for nothing?"),
    );
}

test "classify and backoff" {
    try testing.expectEqual(Outcome.delivered, classify(204));
    try testing.expectEqual(Outcome.retry, classify(500));
    try testing.expectEqual(Outcome.retry, classify(503));
    try testing.expectEqual(Outcome.retry, classify(429));
    try testing.expectEqual(Outcome.retry, classify(408));
    try testing.expectEqual(Outcome.rejected, classify(400));
    try testing.expectEqual(Outcome.rejected, classify(404));

    try testing.expectEqual(@as(u64, 1_000), backoffMs(1));
    try testing.expectEqual(@as(u64, 2_000), backoffMs(2));
    try testing.expectEqual(@as(u64, 16_000), backoffMs(5));
    try testing.expectEqual(max_backoff_ms, backoffMs(7));
    try testing.expectEqual(max_backoff_ms, backoffMs(255));
}

/// Scripted `post`: returns `script[i]` on call `i`, then `fallback`.
const Fake = struct {
    var calls: usize = 0;
    var script: []const Outcome = &.{};
    var fallback: Outcome = .retry;

    fn reset(s: []const Outcome, f: Outcome) void {
        calls = 0;
        script = s;
        fallback = f;
    }

    fn post(_: *Sender, _: []const u8, _: []const u8) Outcome {
        defer calls += 1;
        return if (calls < script.len) script[calls] else fallback;
    }
};

test "a failed POST is retried with backoff until it lands" {
    var sender = try Sender.init(testing.allocator, std.Options.debug_io, &.{}, .{});
    defer sender.deinit();
    sender.post = Fake.post;
    Fake.reset(&.{ .retry, .retry }, .delivered);

    sender.send("https://x/h", "{}");
    try testing.expect(sender.step(0)); // fails, due at 1 s
    try testing.expect(!sender.step(999)); // not due yet
    try testing.expect(sender.step(1_000)); // fails, due 2 s later
    try testing.expect(!sender.step(2_999));
    try testing.expect(sender.step(3_000)); // delivered
    try testing.expectEqual(@as(usize, 3), Fake.calls);
    try testing.expectEqual(@as(usize, 0), sender.retry.items.len);
    try testing.expectEqual(@as(u64, 0), sender.dropped_total.load(.monotonic));
}

test "a rejected POST is not retried" {
    var sender = try Sender.init(testing.allocator, std.Options.debug_io, &.{}, .{});
    defer sender.deinit();
    sender.post = Fake.post;
    Fake.reset(&.{}, .rejected);

    sender.send("https://x/h", "{}");
    try testing.expect(sender.step(0));
    try testing.expect(!sender.step(120_000));
    try testing.expectEqual(@as(usize, 1), Fake.calls);
    try testing.expectEqual(@as(u64, 1), sender.dropped_total.load(.monotonic));
}

test "without a spool, a post out of attempts is dropped" {
    var sender = try Sender.init(testing.allocator, std.Options.debug_io, &.{}, .{});
    defer sender.deinit();
    sender.post = Fake.post;
    Fake.reset(&.{}, .retry);

    sender.send("https://x/h", "{}");
    var now: i64 = 0;
    while (sender.step(now) or sender.retry.items.len > 0) now += max_backoff_ms;
    try testing.expectEqual(@as(usize, max_attempts), Fake.calls);
    try testing.expectEqual(@as(u64, 1), sender.dropped_total.load(.monotonic));
}

fn tmpSpoolPath(buf: []u8, tmp: *const testing.TmpDir) ![]const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}/webhooks.spool", .{tmp.sub_path});
}

test "an outage longer than the retries is parked on disk and survives a restart" {
    const allocator = testing.allocator;
    const io = std.Options.debug_io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try tmpSpoolPath(&path_buf, &tmp);

    {
        var sender = try Sender.init(allocator, io, &.{}, .{ .spool_path = path });
        defer sender.deinit();
        sender.post = Fake.post;
        Fake.reset(&.{}, .retry);

        sender.send("https://x/h", "{\"n\":1}");
        // Steps a minute apart: every retry is due, and the replay that
        // runs alongside finds the spool empty until the very end.
        var now: i64 = 0;
        while (Fake.calls < max_attempts) : (now += max_backoff_ms) _ = sender.step(now);
        try testing.expectEqual(@as(usize, 0), sender.retry.items.len);
        try testing.expectEqual(@as(u64, 0), sender.dropped_total.load(.monotonic));
    }

    const on_disk = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096));
    defer allocator.free(on_disk);
    try testing.expectEqualStrings("https://x/h\t{\"n\":1}\n", on_disk);

    // The next run replays it straight away and the endpoint is back.
    var sender = try Sender.init(allocator, io, &.{}, .{ .spool_path = path });
    defer sender.deinit();
    sender.post = Fake.post;
    Fake.reset(&.{}, .delivered);
    try testing.expect(sender.step(0));
    try testing.expectEqual(@as(usize, 1), Fake.calls);
    try testing.expectEqual(@as(u64, 0), sender.spool.?.size);
}

test "a parked post gets one attempt per replay round" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try tmpSpoolPath(&path_buf, &tmp);

    var sender = try Sender.init(allocator, std.Options.debug_io, &.{}, .{ .spool_path = path });
    defer sender.deinit();
    sender.post = Fake.post;
    Fake.reset(&.{}, .retry);
    try testing.expect(sender.spool.?.append("https://x/h", "{}"));

    try testing.expect(sender.step(0)); // replay + one failed attempt, parked again
    try testing.expectEqual(@as(usize, 1), Fake.calls);
    try testing.expect(sender.spool.?.size > 0);
    try testing.expect(!sender.step(spool_replay_ms - 1));
    try testing.expect(sender.step(spool_replay_ms));
    try testing.expectEqual(@as(usize, 2), Fake.calls);
}

test "spool: bounded, and refuses what it cannot frame" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    var s = try Spool.open(std.Options.debug_io, try tmpSpoolPath(&path_buf, &tmp), 32);
    defer s.close();

    try testing.expect(s.append("https://a", "{\"x\":1}")); // 18 bytes
    try testing.expect(!s.append("https://a", "{\"x\":1}")); // would pass 32
    try testing.expect(!s.append("https://a", "{\n}"));
    try testing.expect(!s.append("https://a\tb", "{}"));

    const all = (try s.takeAll(testing.allocator)).?;
    defer testing.allocator.free(all);
    const rec = parseSpoolLine(std.mem.trimEnd(u8, all, "\n")).?;
    try testing.expectEqualStrings("https://a", rec.url);
    try testing.expectEqualStrings("{\"x\":1}", rec.payload);
    try testing.expect(try s.takeAll(testing.allocator) == null);
    try testing.expect(parseSpoolLine("no-tab") == null);
    try testing.expect(parseSpoolLine("\t{}") == null);
}
