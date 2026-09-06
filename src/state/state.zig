//! Agent state that outlives the process.
//!
//! Everything the agent knows used to live in RAM and die with it: the
//! first-seen signature set was empty again after a restart, so the next
//! occurrence of an error the agent had already reported alerted a second
//! time; and the per-service crash and restart counters went back to zero, so
//! the numbers in an alert described the current process rather than the
//! service. The only durable record was the JSONL alert file, which answers
//! "what was emitted" and not "what is the state of my services".
//!
//! This module is the small file that closes that gap. It holds three things:
//!
//!   * per-service counters and the most recent crash, with its trace;
//!   * a bounded ring of recent events, newest last;
//!   * the first-seen signature set, so a restart does not re-alert history.
//!
//! It is deliberately a plain JSON document rather than a database. It is
//! read once at startup, written a few times a day on a healthy host, and it
//! has to be something an operator can `cat` at three in the morning.
//!
//! ## Durability
//!
//! Writes go through `File.Atomic` — an unnamed file renamed over the target
//! — so a crash mid-write leaves the previous state intact rather than a
//! truncated document. Crashes are written through immediately; everything
//! else is coalesced by the background saver, because a busy rule can fire
//! far more often than a state file deserves to be rewritten.

const std = @import("std");

/// Bumped when the on-disk shape changes incompatibly. A file from a future
/// version is ignored rather than half-read.
pub const version: u32 = 1;

/// Recent events retained. Enough to cover a bad night without turning the
/// file into a log of its own — that is what `--alert-file` is for.
pub const max_events: usize = 64;

/// Distinct services tracked. A single agent watching more than this many is
/// past the shape this project is aimed at.
pub const max_services: usize = 64;

/// First-seen signatures persisted. `rules.max_seen_signatures` allows far
/// more in memory; carrying all of them across a restart would turn a state
/// file meant to be read by a human into a megabyte of hashes, so the newest
/// ones are kept and the rest are allowed to alert once more.
pub const max_signatures: usize = 4_096;

/// Per-field caps. A stack trace is the reason this file is worth having and
/// the reason it could grow without bound.
pub const max_detail_bytes: usize = 512;
pub const max_trace_bytes: usize = 4 * 1024;

/// Refusal threshold when loading. Anything larger is not a state file we
/// wrote.
pub const max_file_bytes: usize = 4 * 1024 * 1024;

const log = std.log.scoped(.zlrd_state);

/// How often the background saver looks for unsaved changes.
const save_interval_ms: u64 = 2_000;

pub const Counts = struct {
    crash: u64 = 0,
    restart: u64 = 0,
    stop: u64 = 0,
};

pub const ServiceStat = struct {
    name: []u8,
    counts: Counts = .{},
    last_crash_ms: i64 = 0,
    last_marker: []u8 = &.{},
    last_detail: []u8 = &.{},
    last_trace: []u8 = &.{},

    fn deinit(self: *ServiceStat, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.last_marker);
        allocator.free(self.last_detail);
        allocator.free(self.last_trace);
    }
};

pub const Event = struct {
    ts_ms: i64,
    kind: []u8,
    subject: []u8,
    source: []u8,
    detail: []u8,

    fn deinit(self: *Event, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.subject);
        allocator.free(self.source);
        allocator.free(self.detail);
    }
};

/// One thing that happened, in the vocabulary the dispatcher already speaks.
/// Slices are borrowed; the store copies what it decides to keep.
pub const Record = struct {
    ts_ms: i64,
    /// Payload kind: `service_crash`, `kernel_oom`, `error_rate`, …
    kind: []const u8,
    /// Service name for lifecycle events, rule id otherwise.
    subject: []const u8,
    /// File path or unit the event came from.
    source: []const u8 = "",
    detail: []const u8 = "",
    marker: []const u8 = "",
    trace: []const u8 = "",
    /// Running totals from the service tracker, which owns them for the life
    /// of the process. The store adopts rather than increments: the tracker
    /// was seeded from the store at startup, so it already counts history.
    counts: ?Counts = null,
    /// True when the record must reach the disk before this call returns.
    /// Set for crashes — the next moment may be the one that takes the box
    /// down, and a crash the operator cannot see in the morning is the exact
    /// failure this file exists to prevent.
    durable: bool = false,
};

/// Where the state file lives when `--state` was not given. Filled from the
/// process environment by the caller so this module needs no access to it.
pub const Env = struct {
    zlrd_state: ?[]const u8 = null,
    xdg_state_home: ?[]const u8 = null,
    home: ?[]const u8 = null,
    local_app_data: ?[]const u8 = null,
};

/// Resolves the default state path. `ZLRD_STATE` wins outright — it is how a
/// systemd unit with `StateDirectory=zlrd` points the agent at
/// `/var/lib/zlrd`. Otherwise the platform's own convention applies, and if
/// even that is unavailable the file lands in the working directory rather
/// than the feature silently turning itself off.
pub fn defaultPath(allocator: std.mem.Allocator, env: Env) ![]u8 {
    if (env.zlrd_state) |p| {
        if (p.len > 0) return allocator.dupe(u8, p);
    }
    if (@import("builtin").os.tag == .windows) {
        if (env.local_app_data) |base| {
            if (base.len > 0) return std.fmt.allocPrint(allocator, "{s}\\zlrd\\state.json", .{base});
        }
    }
    if (env.xdg_state_home) |base| {
        if (base.len > 0) return std.fmt.allocPrint(allocator, "{s}/zlrd/state.json", .{base});
    }
    if (env.home) |base| {
        if (base.len > 0) return std.fmt.allocPrint(allocator, "{s}/.local/state/zlrd/state.json", .{base});
    }
    return allocator.dupe(u8, "zlrd-state.json");
}

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []u8,

    /// Guards every field below it. The dispatcher calls in from the watcher
    /// thread, one thread per journal source, and the kernel monitor; the
    /// saver thread reads the same state to serialise it.
    mutex: std.Io.Mutex,
    services: std.ArrayList(ServiceStat),
    events: std.ArrayList(Event),
    signatures: std.ArrayList(u64),
    /// Set by every mutation, cleared by a successful save.
    dirty: bool,
    /// Logged once. A state directory that cannot be written is worth saying
    /// out loud, but not once every two seconds for the life of the daemon.
    save_failed: bool,

    shutdown: std.atomic.Value(bool),
    thread: ?std.Thread,

    /// Opens the store at `path`, loading whatever is already there.
    ///
    /// A file that cannot be read or parsed is reported and then ignored: the
    /// agent's job is to watch logs, and refusing to start because its own
    /// bookkeeping got corrupted would turn a cosmetic problem into an
    /// outage. The next save replaces it.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Store {
        var self: Store = .{
            .allocator = allocator,
            .io = io,
            .path = try allocator.dupe(u8, path),
            .mutex = .init,
            .services = .empty,
            .events = .empty,
            .signatures = .empty,
            .dirty = false,
            .save_failed = false,
            .shutdown = .init(false),
            .thread = null,
        };
        errdefer allocator.free(self.path);

        self.load() catch |err| switch (err) {
            error.FileNotFound => {},
            else => log.warn("state {s}: {t}; starting from empty", .{ path, err }),
        };
        return self;
    }

    pub fn deinit(self: *Store) void {
        self.stop();
        for (self.services.items) |*s| s.deinit(self.allocator);
        self.services.deinit(self.allocator);
        for (self.events.items) |*e| e.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.signatures.deinit(self.allocator);
        self.allocator.free(self.path);
        self.* = undefined;
    }

    /// Starts the background saver.
    pub fn start(self: *Store) !void {
        self.thread = try std.Thread.spawn(.{}, saveLoop, .{self});
    }

    /// Signals shutdown, joins the saver, and flushes anything still pending.
    /// Idempotent.
    pub fn stop(self: *Store) void {
        self.shutdown.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.flush();
    }

    fn saveLoop(self: *Store) void {
        while (!self.shutdown.load(.acquire)) {
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(save_interval_ms), .awake) catch break;
            self.flush();
        }
    }

    /// Writes if anything changed since the last successful save.
    pub fn flush(self: *Store) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.dirty) return;
        self.saveLocked();
    }

    // ─── Recording ────────────────────────────────────────────────────────

    /// Files one event. Never fails: a state file is a convenience, and an
    /// allocation failure here must not take down the watcher that produced
    /// the event.
    pub fn record(self: *Store, r: Record) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (r.counts) |c| self.updateService(r, c);
        self.pushEvent(r);
        self.dirty = true;

        if (r.durable) self.saveLocked();
    }

    /// Remembers a first-seen signature so the same error does not announce
    /// itself as new after every restart.
    pub fn recordSignature(self: *Store, sig: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.signatures.items.len >= max_signatures) {
            // Drop the oldest. Alerting once more on an error last seen
            // thousands of signatures ago is a far smaller cost than letting
            // this array grow for the life of the daemon.
            _ = self.signatures.orderedRemove(0);
        }
        self.signatures.append(self.allocator, sig) catch return;
        self.dirty = true;
    }

    /// The persisted signature set, for seeding the rule engine at startup.
    /// Borrowed — valid until the next `recordSignature`.
    pub fn signatureSlice(self: *Store) []const u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.signatures.items;
    }

    /// Counters carried over from previous runs, for seeding a tracker.
    pub fn counts(self: *Store, name: []const u8) Counts {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.services.items) |s| {
            if (std.mem.eql(u8, s.name, name)) return s.counts;
        }
        return .{};
    }

    fn updateService(self: *Store, r: Record, c: Counts) void {
        const slot = self.serviceSlot(r.subject) orelse return;
        // Crashes and restarts are adopted, not incremented: the tracker owns
        // them for the life of the process and was seeded from this file at
        // startup, so its numbers already span every run. Stops are the
        // exception — nothing upstream counts them — so they accumulate here.
        slot.counts.crash = c.crash;
        slot.counts.restart = c.restart;
        if (std.mem.eql(u8, r.kind, "service_stop")) slot.counts.stop += 1;
        if (std.mem.eql(u8, r.kind, "service_crash")) {
            slot.last_crash_ms = r.ts_ms;
            replace(self.allocator, &slot.last_marker, r.marker, max_detail_bytes);
            replace(self.allocator, &slot.last_detail, r.detail, max_detail_bytes);
            replace(self.allocator, &slot.last_trace, r.trace, max_trace_bytes);
        }
    }

    fn serviceSlot(self: *Store, name: []const u8) ?*ServiceStat {
        for (self.services.items) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        if (self.services.items.len >= max_services) return null;
        const owned = self.allocator.dupe(u8, name) catch return null;
        self.services.append(self.allocator, .{ .name = owned }) catch {
            self.allocator.free(owned);
            return null;
        };
        return &self.services.items[self.services.items.len - 1];
    }

    fn pushEvent(self: *Store, r: Record) void {
        var ev: Event = .{
            .ts_ms = r.ts_ms,
            .kind = self.allocator.dupe(u8, r.kind) catch return,
            .subject = &.{},
            .source = &.{},
            .detail = &.{},
        };
        ev.subject = self.allocator.dupe(u8, r.subject) catch {
            self.allocator.free(ev.kind);
            return;
        };
        ev.source = self.allocator.dupe(u8, r.source) catch {
            self.allocator.free(ev.kind);
            self.allocator.free(ev.subject);
            return;
        };
        ev.detail = self.allocator.dupe(u8, clamp(r.detail, max_detail_bytes)) catch {
            self.allocator.free(ev.kind);
            self.allocator.free(ev.subject);
            self.allocator.free(ev.source);
            return;
        };

        self.events.append(self.allocator, ev) catch {
            ev.deinit(self.allocator);
            return;
        };
        while (self.events.items.len > max_events) {
            var oldest = self.events.orderedRemove(0);
            oldest.deinit(self.allocator);
        }
    }

    // ─── Reading, for `zlrd status` ───────────────────────────────────────

    /// A borrowed, point-in-time view. Only safe while nothing is writing —
    /// which is the case for `zlrd status`, where the store is opened,
    /// rendered, and closed with no saver thread running.
    pub const Snapshot = struct {
        path: []const u8,
        services: []const ServiceStat,
        events: []const Event,
        signatures: usize,
    };

    pub fn snapshot(self: *const Store) Snapshot {
        return .{
            .path = self.path,
            .services = self.services.items,
            .events = self.events.items,
            .signatures = self.signatures.items.len,
        };
    }

    // ─── Persistence ──────────────────────────────────────────────────────

    fn saveLocked(self: *Store) void {
        self.write() catch |err| {
            if (!self.save_failed) {
                self.save_failed = true;
                log.warn("state {s}: cannot save: {t}", .{ self.path, err });
            }
            return;
        };
        self.save_failed = false;
        self.dirty = false;
    }

    fn write(self: *Store) !void {
        // An unnamed file renamed into place: a reader either sees the whole
        // previous document or the whole new one, never the middle of a
        // write. `make_path` covers the first run, where ~/.local/state/zlrd
        // does not exist yet.
        var af = try std.Io.Dir.cwd().createFileAtomic(self.io, self.path, .{
            .make_path = true,
            .replace = true,
        });
        defer af.deinit(self.io);

        var buf: [16 * 1024]u8 = undefined;
        var fw = af.file.writer(self.io, &buf);
        try self.writeJson(&fw.interface);
        try fw.interface.flush();

        try af.replace(self.io);
    }

    fn writeJson(self: *Store, w: *std.Io.Writer) !void {
        try w.print("{{\"version\":{d}", .{version});
        try w.print(",\"updated_ms\":{d}", .{std.Io.Timestamp.now(self.io, .real).toMilliseconds()});

        try w.writeAll(",\"services\":[");
        for (self.services.items, 0..) |s, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"name\":");
            try writeJsonString(w, s.name);
            try w.print(",\"crashes\":{d},\"restarts\":{d},\"stops\":{d},\"last_crash_ms\":{d}", .{
                s.counts.crash,
                s.counts.restart,
                s.counts.stop,
                s.last_crash_ms,
            });
            try w.writeAll(",\"last_marker\":");
            try writeJsonString(w, s.last_marker);
            try w.writeAll(",\"last_detail\":");
            try writeJsonString(w, s.last_detail);
            try w.writeAll(",\"last_trace\":");
            try writeJsonString(w, s.last_trace);
            try w.writeByte('}');
        }

        try w.writeAll("],\"events\":[");
        for (self.events.items, 0..) |e, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{{\"ts_ms\":{d},\"kind\":", .{e.ts_ms});
            try writeJsonString(w, e.kind);
            try w.writeAll(",\"subject\":");
            try writeJsonString(w, e.subject);
            try w.writeAll(",\"source\":");
            try writeJsonString(w, e.source);
            try w.writeAll(",\"detail\":");
            try writeJsonString(w, e.detail);
            try w.writeByte('}');
        }

        // Hex rather than JSON numbers: a signature is a full 64-bit hash,
        // and every tool an operator might pipe this through — jq included —
        // routes numbers through a double and silently rounds the ones past
        // 2^53.
        try w.writeAll("],\"signatures\":[");
        for (self.signatures.items, 0..) |sig, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("\"{x:0>16}\"", .{sig});
        }
        try w.writeAll("]}\n");
    }

    fn load(self: *Store) !void {
        const text = try std.Io.Dir.cwd().readFileAlloc(
            self.io,
            self.path,
            self.allocator,
            .limited(max_file_bytes),
        );
        defer self.allocator.free(text);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, text, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidState;
        const root = parsed.value.object;

        const file_version = switch (root.get("version") orelse return error.InvalidState) {
            .integer => |v| v,
            else => return error.InvalidState,
        };
        if (file_version != version) {
            log.warn("state {s}: version {d} is not {d}; starting from empty", .{
                self.path, file_version, version,
            });
            return;
        }

        if (root.get("services")) |v| {
            if (v == .array) for (v.array.items) |item| self.loadService(item);
        }
        if (root.get("events")) |v| {
            if (v == .array) for (v.array.items) |item| self.loadEvent(item);
        }
        if (root.get("signatures")) |v| {
            if (v == .array) for (v.array.items) |item| {
                if (item != .string) continue;
                const sig = std.fmt.parseInt(u64, item.string, 16) catch continue;
                if (self.signatures.items.len >= max_signatures) break;
                self.signatures.append(self.allocator, sig) catch break;
            };
        }
    }

    /// Field-by-field and tolerant on purpose: a state file half-written by
    /// an older build should give up the records it can still be read for
    /// rather than all of them.
    fn loadService(self: *Store, item: std.json.Value) void {
        if (item != .object) return;
        const obj = item.object;
        const name = str(obj.get("name")) orelse return;
        if (name.len == 0) return;
        const slot = self.serviceSlot(name) orelse return;
        slot.counts = .{
            .crash = num(obj.get("crashes")),
            .restart = num(obj.get("restarts")),
            .stop = num(obj.get("stops")),
        };
        slot.last_crash_ms = @intCast(num(obj.get("last_crash_ms")));
        replace(self.allocator, &slot.last_marker, str(obj.get("last_marker")) orelse "", max_detail_bytes);
        replace(self.allocator, &slot.last_detail, str(obj.get("last_detail")) orelse "", max_detail_bytes);
        replace(self.allocator, &slot.last_trace, str(obj.get("last_trace")) orelse "", max_trace_bytes);
    }

    fn loadEvent(self: *Store, item: std.json.Value) void {
        if (item != .object) return;
        const obj = item.object;
        self.pushEvent(.{
            .ts_ms = @intCast(num(obj.get("ts_ms"))),
            .kind = str(obj.get("kind")) orelse return,
            .subject = str(obj.get("subject")) orelse "",
            .source = str(obj.get("source")) orelse "",
            .detail = str(obj.get("detail")) orelse "",
        });
    }
};

fn str(v: ?std.json.Value) ?[]const u8 {
    const value = v orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn num(v: ?std.json.Value) u64 {
    const value = v orelse return 0;
    return switch (value) {
        .integer => |i| if (i > 0) @intCast(i) else 0,
        else => 0,
    };
}

fn clamp(s: []const u8, cap: usize) []const u8 {
    return if (s.len > cap) s[0..cap] else s;
}

/// Swaps an owned string for a copy of `s`, capped. Leaves the old value in
/// place when the copy cannot be made — a stale marker beats a dangling one.
fn replace(allocator: std.mem.Allocator, dst: *[]u8, s: []const u8, cap: usize) void {
    const owned = allocator.dupe(u8, clamp(s, cap)) catch return;
    allocator.free(dst.*);
    dst.* = owned;
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            // High-bit bytes are UTF-8 continuation bytes and must go through
            // untouched; escaping them as `\u00XX` would decode as that code
            // point and mangle the character.
            0x20...0x21, 0x23...0x5b, 0x5d...0x7e, 0x80...0xff => try w.writeByte(c),
            else => try w.print("\\u{x:0>4}", .{c}),
        }
    }
    try w.writeByte('"');
}

// ─── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Each test gets its own file: this module is compiled into several test
/// binaries and `zig build test` runs them concurrently from one working
/// directory, so a fixed name would have runs overwriting each other's state
/// and deleting it out from under one another.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    buf: [160]u8 = undefined,

    fn init() Fixture {
        return .{ .tmp = testing.tmpDir(.{}) };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    /// Built on demand from the caller's own storage. Returning the slice
    /// from `init` instead would have it point into a `Fixture` that the
    /// return-by-value copy left behind.
    fn path(self: *Fixture, comptime name: []const u8) []const u8 {
        return std.fmt.bufPrint(&self.buf, ".zig-cache/tmp/{s}/" ++ name, .{self.tmp.sub_path}) catch unreachable;
    }
};

test "state survives a restart: counters, last crash and signatures" {
    const allocator = testing.allocator;
    const io = std.Options.debug_io;
    var fx = Fixture.init();
    defer fx.deinit();

    {
        var s = try Store.open(allocator, io, fx.path("state.json"));
        defer s.deinit();
        s.record(.{
            .ts_ms = 1_700_000_000_000,
            .kind = "service_crash",
            .subject = "api",
            .source = "/var/log/api.log",
            .detail = "panic: nil pointer",
            .marker = "go_panic",
            .trace = "goroutine 1 [running]:\nmain.go:42",
            .counts = .{ .crash = 3, .restart = 1 },
        });
        s.recordSignature(0xdeadbeefcafef00d);
        s.flush();
    }

    var s = try Store.open(allocator, io, fx.path("state.json"));
    defer s.deinit();

    // The counters the next run's tracker starts from.
    const c = s.counts("api");
    try testing.expectEqual(@as(u64, 3), c.crash);
    try testing.expectEqual(@as(u64, 1), c.restart);

    const snap = s.snapshot();
    try testing.expectEqual(@as(usize, 1), snap.services.len);
    try testing.expectEqualStrings("go_panic", snap.services[0].last_marker);
    try testing.expectEqualStrings("panic: nil pointer", snap.services[0].last_detail);
    try testing.expect(std.mem.indexOf(u8, snap.services[0].last_trace, "main.go:42") != null);
    try testing.expectEqual(@as(i64, 1_700_000_000_000), snap.services[0].last_crash_ms);

    try testing.expectEqual(@as(usize, 1), snap.events.len);
    try testing.expectEqualStrings("service_crash", snap.events[0].kind);

    // A signature past 2^53 has to come back bit-for-bit, which is the whole
    // reason they are written as hex instead of JSON numbers.
    try testing.expectEqual(@as(usize, 1), s.signatureSlice().len);
    try testing.expectEqual(@as(u64, 0xdeadbeefcafef00d), s.signatureSlice()[0]);
}

test "the event ring keeps the newest and drops the oldest" {
    const allocator = testing.allocator;
    const io = std.Options.debug_io;
    var fx = Fixture.init();
    defer fx.deinit();

    var s = try Store.open(allocator, io, fx.path("state.json"));
    defer s.deinit();

    var buf: [32]u8 = undefined;
    for (0..max_events * 3) |i| {
        s.record(.{
            .ts_ms = @intCast(i),
            .kind = "error_rate",
            .subject = "rule",
            .detail = try std.fmt.bufPrint(&buf, "line {d}", .{i}),
        });
    }

    const snap = s.snapshot();
    try testing.expectEqual(max_events, snap.events.len);
    try testing.expectEqual(@as(i64, max_events * 3 - 1), snap.events[snap.events.len - 1].ts_ms);
    try testing.expectEqual(@as(i64, max_events * 2), snap.events[0].ts_ms);
}

test "the signature set is bounded and keeps the newest" {
    const allocator = testing.allocator;
    const io = std.Options.debug_io;
    var fx = Fixture.init();
    defer fx.deinit();

    var s = try Store.open(allocator, io, fx.path("state.json"));
    defer s.deinit();

    for (0..max_signatures + 100) |i| s.recordSignature(@intCast(i));
    const sigs = s.signatureSlice();
    try testing.expectEqual(max_signatures, sigs.len);
    try testing.expectEqual(@as(u64, 100), sigs[0]);
    try testing.expectEqual(@as(u64, max_signatures + 99), sigs[sigs.len - 1]);
}

test "a corrupt state file is reported, not fatal" {
    const allocator = testing.allocator;
    const io = std.Options.debug_io;
    var fx = Fixture.init();
    defer fx.deinit();

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = fx.path("state.json"), .data = "{not json at all" });

    // The agent's job is to watch logs. Refusing to start because its own
    // bookkeeping got truncated would turn a cosmetic problem into an outage.
    var s = try Store.open(allocator, io, fx.path("state.json"));
    defer s.deinit();
    try testing.expectEqual(@as(usize, 0), s.snapshot().services.len);

    // And the next save must replace it with something readable.
    s.record(.{ .ts_ms = 1, .kind = "service_stop", .subject = "api", .counts = .{} });
    s.flush();

    var again = try Store.open(allocator, io, fx.path("state.json"));
    defer again.deinit();
    try testing.expectEqual(@as(usize, 1), again.snapshot().events.len);
}

test "a state file from another version is ignored rather than half-read" {
    const allocator = testing.allocator;
    const io = std.Options.debug_io;
    var fx = Fixture.init();
    defer fx.deinit();

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = fx.path("state.json"),
        .data =
        \\{"version":999,"services":[{"name":"api","crashes":7}],"events":[],"signatures":[]}
        ,
    });

    var s = try Store.open(allocator, io, fx.path("state.json"));
    defer s.deinit();
    try testing.expectEqual(@as(u64, 0), s.counts("api").crash);
}

test "a missing file is the normal first run, not an error" {
    const allocator = testing.allocator;
    const io = std.Options.debug_io;
    var fx = Fixture.init();
    defer fx.deinit();

    // Two directory levels that do not exist yet — the same shape as
    // ~/.local/state/zlrd on a machine that has never run the agent.
    const nested = fx.path("a/b/state.json");

    var s = try Store.open(allocator, io, nested);
    defer s.deinit();
    s.record(.{ .ts_ms = 1, .kind = "first_seen", .subject = "first_seen", .source = "app.log" });
    s.flush();

    var again = try Store.open(allocator, io, nested);
    defer again.deinit();
    try testing.expectEqual(@as(usize, 1), again.snapshot().events.len);
}

test "overlong detail and traces are capped on the way in" {
    const allocator = testing.allocator;
    const io = std.Options.debug_io;
    var fx = Fixture.init();
    defer fx.deinit();

    var huge: [64 * 1024]u8 = undefined;
    @memset(&huge, 'x');

    var s = try Store.open(allocator, io, fx.path("state.json"));
    defer s.deinit();
    s.record(.{
        .ts_ms = 1,
        .kind = "service_crash",
        .subject = "api",
        .detail = &huge,
        .trace = &huge,
        .counts = .{ .crash = 1 },
    });

    const snap = s.snapshot();
    try testing.expectEqual(max_detail_bytes, snap.services[0].last_detail.len);
    try testing.expectEqual(max_trace_bytes, snap.services[0].last_trace.len);
    try testing.expectEqual(max_detail_bytes, snap.events[0].detail.len);
}

test "a crash is on disk before record returns" {
    const allocator = testing.allocator;
    const io = std.Options.debug_io;
    var fx = Fixture.init();
    defer fx.deinit();

    var s = try Store.open(allocator, io, fx.path("state.json"));
    defer s.deinit();
    // No flush, no saver thread: `durable` is the only thing that can have
    // put this on disk, and a crash is exactly the event whose next moment
    // may be the one that takes the box down.
    s.record(.{
        .ts_ms = 1,
        .kind = "service_crash",
        .subject = "api",
        .detail = "boom",
        .counts = .{ .crash = 1 },
        .durable = true,
    });

    var reopened = try Store.open(allocator, io, fx.path("state.json"));
    defer reopened.deinit();
    try testing.expectEqual(@as(u64, 1), reopened.counts("api").crash);
}

test "unicode and quotes round-trip through the state file" {
    const allocator = testing.allocator;
    const io = std.Options.debug_io;
    var fx = Fixture.init();
    defer fx.deinit();

    const detail = "panic: не найден \"ключ\" / 你好\tend";
    {
        var s = try Store.open(allocator, io, fx.path("state.json"));
        defer s.deinit();
        s.record(.{ .ts_ms = 1, .kind = "service_crash", .subject = "api", .detail = detail, .counts = .{ .crash = 1 } });
        s.flush();
    }
    var s = try Store.open(allocator, io, fx.path("state.json"));
    defer s.deinit();
    try testing.expectEqualStrings(detail, s.snapshot().services[0].last_detail);
}

test "defaultPath prefers ZLRD_STATE, then the platform convention" {
    const allocator = testing.allocator;

    const explicit = try defaultPath(allocator, .{ .zlrd_state = "/var/lib/zlrd/state.json", .home = "/home/x" });
    defer allocator.free(explicit);
    try testing.expectEqualStrings("/var/lib/zlrd/state.json", explicit);

    const xdg = try defaultPath(allocator, .{ .xdg_state_home = "/home/x/.state", .home = "/home/x" });
    defer allocator.free(xdg);
    try testing.expectEqualStrings("/home/x/.state/zlrd/state.json", xdg);

    const home = try defaultPath(allocator, .{ .home = "/home/x" });
    defer allocator.free(home);
    try testing.expectEqualStrings("/home/x/.local/state/zlrd/state.json", home);

    // Nothing in the environment at all — a bare container, or a daemon
    // started with a scrubbed environment. Landing in the working directory
    // keeps the feature working instead of silently disabling it.
    const nothing = try defaultPath(allocator, .{});
    defer allocator.free(nothing);
    try testing.expectEqualStrings("zlrd-state.json", nothing);
}

test "an empty environment variable does not win over the next fallback" {
    const allocator = testing.allocator;
    // `ZLRD_STATE=` in a systemd EnvironmentFile is set-but-empty, which is
    // how the operator spells "I did not configure this".
    const p = try defaultPath(allocator, .{ .zlrd_state = "", .home = "/home/x" });
    defer allocator.free(p);
    try testing.expectEqualStrings("/home/x/.local/state/zlrd/state.json", p);
}

test "stops accumulate across runs while crashes are adopted from the tracker" {
    const allocator = testing.allocator;
    const io = std.Options.debug_io;
    var fx = Fixture.init();
    defer fx.deinit();

    {
        var s = try Store.open(allocator, io, fx.path("state.json"));
        defer s.deinit();
        s.record(.{ .ts_ms = 1, .kind = "service_stop", .subject = "api", .counts = .{ .crash = 2 } });
        s.record(.{ .ts_ms = 2, .kind = "service_stop", .subject = "api", .counts = .{ .crash = 2 } });
        s.flush();
    }

    var s = try Store.open(allocator, io, fx.path("state.json"));
    defer s.deinit();
    try testing.expectEqual(@as(u64, 2), s.counts("api").stop);

    // A fresh run whose tracker was seeded with 2 crashes reports 3 after
    // the next one; the store takes that number rather than adding to it,
    // which is what keeps a restart from doubling the tally.
    s.record(.{ .ts_ms = 3, .kind = "service_crash", .subject = "api", .counts = .{ .crash = 3 } });
    try testing.expectEqual(@as(u64, 3), s.counts("api").crash);
    try testing.expectEqual(@as(u64, 2), s.counts("api").stop);
}
