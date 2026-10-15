//! systemd-journal source for agent mode.
//!
//! Each `--journal-unit NAME=PATTERN` spawns one `journalctl -fu <PATTERN>
//! --output=json --no-pager --since now` subprocess and consumes its stdout
//! line-by-line. Each line is one JSON-encoded journal entry; we extract a
//! handful of fields (MESSAGE, PRIORITY, _SYSTEMD_UNIT, UNIT, _PID,
//! SYSLOG_IDENTIFIER), classify it, and either:
//!
//!   * skip it (systemd lifecycle: `Started`, `Stopping`, `Stopped`, …);
//!   * fire a crash directly (systemd crash signal: `Main process exited,
//!     code=killed`, `Failed with result 'signal'`, …);
//!   * feed it to the per-unit `service.Tracker` (everything else — the
//!     unit's own application logs, where `panic:`/`Traceback`/etc. live).
//!
//! Allocation policy:
//!   * One per-source `StringHashMapUnmanaged([]u8, *Tracker)` keyed by the
//!     actual `_SYSTEMD_UNIT` value (wildcards in the pattern can fan out
//!     to multiple unit instances). Bounded by `max_units_per_source`.
//!   * One 8 KiB stack read buffer per source thread; one 4 KiB stack
//!     unescape buffer per entry. Per-entry parsing is alloc-free.
//!
//! Linux-only: on other platforms `run` is a no-op (returns immediately
//! after logging).

const std = @import("std");
const builtin = @import("builtin");
const flags = @import("flags");
const native = @import("journal");

const alert = @import("alert.zig");
const config = @import("config.zig");
const service = @import("service.zig");
const signature = @import("signature.zig");
const state = @import("state");

const log = std.log.scoped(.zlrd_journal);

const read_buf_size: usize = 8 * 1024;
const unescape_buf_size: usize = 4 * 1024;
const max_units_per_source: usize = 256;
const max_line_bytes: usize = 16 * 1024;
const journal_pseudo_path_prefix = "journal://";

pub const SystemdClass = enum {
    /// Routine lifecycle: Started / Stopped / Stopping / Reloading / etc.
    /// The user explicitly does not want these surfaced.
    lifecycle,
    /// Abnormal termination notice emitted by systemd itself.
    crash_signal,
    /// Anything else from `SYSLOG_IDENTIFIER=systemd` — informational, not a
    /// crash, but not a routine lifecycle message either.
    other,
};

/// Classifies a `SYSLOG_IDENTIFIER=systemd` message into one of the three
/// buckets above. Heuristic but stable — systemd's exact wording has been
/// constant across releases.
pub fn classifySystemdMessage(msg: []const u8) SystemdClass {
    if (isLifecycle(msg)) return .lifecycle;
    if (isCrashSignal(msg)) return .crash_signal;
    return .other;
}

fn isLifecycle(msg: []const u8) bool {
    // Order matters — most common first.
    const prefixes = [_][]const u8{
        "Started ",
        "Stopping ",
        "Stopped ",
        "Reloading ",
        "Reloaded ",
        "Deactivated successfully",
        "Consumed ",
        "Scheduled restart",
        "Starting ",
    };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, msg, p)) return true;
    }
    return false;
}

fn isCrashSignal(msg: []const u8) bool {
    if (std.mem.indexOf(u8, msg, "Main process exited, code=killed") != null) return true;
    if (std.mem.indexOf(u8, msg, "Main process exited, code=dumped") != null) return true;
    if (std.mem.indexOf(u8, msg, "Failed with result 'signal'") != null) return true;
    if (std.mem.indexOf(u8, msg, "Failed with result 'core-dump'") != null) return true;
    if (std.mem.indexOf(u8, msg, "Failed with result 'oom-kill'") != null) return true;
    if (std.mem.indexOf(u8, msg, "Failed with result 'watchdog'") != null) return true;
    // A non-zero exit is how most runtimes die: Go exits 2 after a panic,
    // Python 1 after an uncaught exception, `log.Fatal` 1. When the app
    // printed its own crash first, this is deduplicated as its echo; when it
    // printed nothing — a C binary calling `exit(1)` — it is the only sign.
    if (std.mem.indexOf(u8, msg, "Failed with result 'exit-code'") != null) return true;
    return false;
}

/// True for the systemd lines that mean a new process now runs the unit.
fn isStart(msg: []const u8) bool {
    return std.mem.startsWith(u8, msg, "Started ") or std.mem.startsWith(u8, msg, "Starting ");
}

/// The level used for crash detection on a journal entry.
///
/// The message's own level wins: a JSON or logfmt line says what it is. The
/// entry's PRIORITY only counts when it is err or worse, because journald
/// stamps everything a service writes to stdout or stderr with
/// `SyslogLevel=`, which defaults to info. Taken at face value that made
/// every Go `panic:`, Python `Traceback` and Rust `panicked at` captured from
/// stderr an info line — and the detector ignores runtime banners on lines
/// below error, so none of them was ever reported.
pub fn journalLevel(message: []const u8, priority: []const u8) ?flags.Level {
    if (signature.extractLevel(message)) |l| return l;
    const l = priorityToLevel(priority) orelse return null;
    return if (@backingInt(l) >= @backingInt(flags.Level.Error)) l else null;
}

/// Which unit an entry is about. systemd's own messages come from PID 1,
/// whose `_SYSTEMD_UNIT` is `init.scope`; the unit they describe is in
/// `UNIT`. Reading `_SYSTEMD_UNIT` for those filtered every `Main process
/// exited` out of a natively tailed journal, and in the journalctl path
/// filed it under `init.scope`, where no deduplication could find it.
pub fn entryUnit(syslog_id: []const u8, unit_field: ?[]const u8, systemd_unit: ?[]const u8) ?[]const u8 {
    if (std.mem.eql(u8, syslog_id, "systemd")) {
        if (unit_field) |u| return u;
    }
    return systemd_unit;
}

/// Maps a numeric systemd / syslog priority (`"0"`..`"7"`) to the agent's
/// canonical level. Higher syslog priorities map to lower severities, so we
/// invert the mapping. Unknown / non-numeric inputs return null.
pub fn priorityToLevel(priority_str: []const u8) ?flags.Level {
    const n = std.fmt.parseInt(u8, priority_str, 10) catch return null;
    return switch (n) {
        0, 1 => .Panic, // emerg, alert
        2 => .Fatal, // crit
        3 => .Error, // err
        4 => .Warn, // warning
        5, 6 => .Info, // notice, info
        7 => .Debug, // debug
        else => null,
    };
}

/// Locates `"key":"<value>"` in a one-line JSON object and returns the raw
/// (still-escaped) value bytes between the quotes. Conservative: it requires
/// the key to follow `{`, `,`, or whitespace so substring matches inside
/// values cannot be confused for keys. Returns null on missing key or when
/// the value is not a string.
pub fn findJsonStringField(s: []const u8, key: []const u8) ?[]const u8 {
    var key_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&key_buf, "\"{s}\"", .{key}) catch return null;

    var i: usize = 0;
    while (true) {
        const hit = std.mem.indexOfPos(u8, s, i, needle) orelse return null;
        const boundary_ok = if (hit == 0) true else switch (s[hit - 1]) {
            '{', ',', ' ', '\t' => true,
            else => false,
        };
        if (!boundary_ok) {
            i = hit + needle.len;
            continue;
        }

        var j = hit + needle.len;
        while (j < s.len and (s[j] == ' ' or s[j] == '\t')) : (j += 1) {}
        if (j >= s.len or s[j] != ':') {
            i = hit + needle.len;
            continue;
        }
        j += 1;
        while (j < s.len and (s[j] == ' ' or s[j] == '\t')) : (j += 1) {}
        if (j >= s.len or s[j] != '"') return null;

        const value_start = j + 1;
        var k = value_start;
        while (k < s.len) : (k += 1) {
            if (s[k] == '\\') {
                if (k + 1 >= s.len) return null;
                k += 1;
                continue;
            }
            if (s[k] == '"') return s[value_start..k];
        }
        return null;
    }
}

/// In-place JSON string-value unescaper. Writes the decoded bytes into `dst`
/// and returns the populated slice. Supports the escape sequences journalctl
/// actually emits: `\"`, `\\`, `\/`, `\n`, `\r`, `\t`, `\b`, `\f`, and the
/// `\uXXXX` form (BMP only — surrogate pairs collapse to the leading half).
pub fn unescapeJsonString(dst: []u8, src: []const u8) []const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < src.len and out < dst.len) {
        if (src[i] != '\\' or i + 1 >= src.len) {
            dst[out] = src[i];
            out += 1;
            i += 1;
            continue;
        }
        const c = src[i + 1];
        switch (c) {
            'n' => {
                dst[out] = '\n';
                out += 1;
                i += 2;
            },
            't' => {
                dst[out] = '\t';
                out += 1;
                i += 2;
            },
            'r' => {
                dst[out] = '\r';
                out += 1;
                i += 2;
            },
            'b' => {
                dst[out] = 0x08;
                out += 1;
                i += 2;
            },
            'f' => {
                dst[out] = 0x0c;
                out += 1;
                i += 2;
            },
            '"', '\\', '/' => {
                dst[out] = c;
                out += 1;
                i += 2;
            },
            'u' => {
                if (i + 6 > src.len) {
                    dst[out] = c;
                    out += 1;
                    i += 2;
                    continue;
                }
                const cp = std.fmt.parseInt(u21, src[i + 2 .. i + 6], 16) catch {
                    dst[out] = c;
                    out += 1;
                    i += 2;
                    continue;
                };
                var ub: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &ub) catch {
                    dst[out] = c;
                    out += 1;
                    i += 2;
                    continue;
                };
                if (out + n > dst.len) break;
                @memcpy(dst[out .. out + n], ub[0..n]);
                out += n;
                i += 6;
            },
            else => {
                dst[out] = c;
                out += 1;
                i += 2;
            },
        }
    }
    return dst[0..out];
}

/// One systemd journal source. Lives on its own OS thread; reads the journalctl
/// subprocess's stdout, parses entries, and fires events through the shared
/// dispatcher.
pub const JournalSource = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    pattern: []const u8,
    dispatcher: *alert.Dispatcher,
    detector: *const service.Detector,
    trackers: std.StringHashMapUnmanaged(*service.Tracker),
    /// Set once the line currently being accumulated has passed
    /// `max_line_bytes`. Everything up to the next newline is then dropped.
    ///
    /// Previously the overflowing bytes were discarded but the carry was
    /// kept, so a later chunk could finish the line and hand downstream a
    /// record spliced from its head and its tail with the middle gone. That
    /// splice parses cleanly as JSON and is simply the wrong entry — the
    /// failure mode is silent corruption, not a dropped line.
    line_overflow: bool = false,
    /// Logged once, so a run of long entries does not flood the log.
    overflow_logged: bool = false,
    stop_flag: std.atomic.Value(bool),
    child: ?std.process.Child = null,
    /// Crashes for this `--journal-unit` binding, across every unit its
    /// pattern matches. Kept here rather than per tracker: the store keys
    /// counts by binding name, and two instances of `worker@*.service` each
    /// counting from the same seed overwrote each other's totals.
    crash_count: u64 = 0,
    restart_count: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        name: []const u8,
        pattern: []const u8,
        dispatcher: *alert.Dispatcher,
        detector: *const service.Detector,
    ) JournalSource {
        return .{
            .allocator = allocator,
            .io = io,
            .name = name,
            .pattern = pattern,
            .dispatcher = dispatcher,
            .detector = detector,
            .trackers = .empty,
            .stop_flag = .init(false),
        };
    }

    /// Adopts the counts a previous run left behind.
    pub fn setStore(self: *JournalSource, store: *state.Store) void {
        const c = store.counts(self.name);
        self.crash_count = c.crash;
        self.restart_count = c.restart;
    }

    pub fn deinit(self: *JournalSource) void {
        var it = self.trackers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            // `trackerFor` allocates the `journal://unit` path; nothing else
            // frees it.
            self.allocator.free(entry.value_ptr.*.path);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.trackers.deinit(self.allocator);
        if (self.child) |*c| {
            c.kill(self.io);
            _ = c.wait(self.io) catch {};
            self.child = null;
        }
    }

    pub fn requestStop(self: *JournalSource) void {
        self.stop_flag.store(true, .monotonic);
        if (self.child) |*c| c.kill(self.io);
    }

    /// Blocks until `requestStop` is called or the data source ends. Prefers
    /// the native reader (binary parsing of `system.journal`) and falls back
    /// to `journalctl` only when the journal directory is missing or we're
    /// not on Linux.
    pub fn run(self: *JournalSource) !void {
        if (comptime builtin.os.tag != .linux) {
            log.info("journal source '{s}' is no-op on this platform", .{self.name});
            return;
        }
        const path = native.source.findActiveJournalPath(self.allocator, self.io) catch |err| {
            log.info("journal source '{s}' falling back to journalctl: {t}", .{ self.name, err });
            try self.spawnAndRead();
            return;
        };
        defer self.allocator.free(path);
        log.info("journal source '{s}' tailing {s} natively", .{ self.name, path });
        try self.tailNative(path);
    }

    fn tailNative(self: *JournalSource, initial_path: []const u8) !void {
        // The active path can change while we tail — on rotation, systemd
        // moves `system.journal` aside and creates a fresh one. We keep
        // ownership of the path string in this local so reopen calls can
        // free the old one without dangling references.
        var path = try self.allocator.dupe(u8, initial_path);
        defer self.allocator.free(path);

        while (!self.stop_flag.load(.monotonic)) {
            const continue_tail = self.tailOneFile(path) catch |err| {
                log.warn("native tail of {s} failed: {t}; falling back to journalctl", .{ path, err });
                try self.spawnAndRead();
                return;
            };
            if (!continue_tail) return;

            // Rotation: rediscover the current `system.journal` and loop.
            const fresh = native.source.findActiveJournalPath(self.allocator, self.io) catch |err| {
                log.warn("journal source '{s}' lost active file after rotation: {t}", .{ self.name, err });
                return;
            };
            self.allocator.free(path);
            path = fresh;
            log.info("journal source '{s}' followed rotation to {s}", .{ self.name, path });
        }
    }

    /// Tails `path` until rotation or shutdown. Returns true if rotation
    /// happened (caller should rediscover and retry), false if the loop
    /// exited cleanly (stop requested).
    fn tailOneFile(self: *JournalSource, path: []const u8) !bool {
        var r = try native.Reader.open(self.io, std.Io.Dir.cwd(), path);
        defer r.deinit();

        var it = r.iterator();
        // Bulk-skip existing entries without resolving each entry's fields.
        // `seekToEnd` walks just the entry-array chain headers (no data
        // payload reads, no LZ4 decode, no per-entry arena), so even a
        // multi-GB journal is past in tens of milliseconds.
        try it.seekToEnd();

        // The five fields `handleNativeEntry` reads. A journald entry carries
        // roughly twenty-five, and resolving the rest costs an arena bump
        // and a payload copy each — together the largest item in the read
        // profile. Keep this in step with the `e.get` calls below.
        it.setFieldFilter(&native_fields);

        // Enable the DATA-object cache for live tailing — hot fields like
        // `_SYSTEMD_UNIT` are referenced by every entry of a service and
        // would otherwise hit the disk (+LZ4) once per entry.
        try it.enableCache(self.allocator);
        defer it.disableCache(self.allocator);

        // `path` comes from `findActiveJournalPath` and is absolute, which
        // the inotify watch requires — a relative path would resolve against
        // the process CWD instead of `dir`.
        var watcher = native.Watcher.init(self.io, .{
            .dir = std.Io.Dir.cwd(),
            .path = path,
        });
        defer watcher.deinit();

        // Scratch for entry field bytes, reset between entries so the
        // per-entry arena draws from a warm buffer instead of hitting the
        // general-purpose allocator. That is worth ~5x on the drain loop; see
        // the note on `Iterator.next`. An entry's bytes die at the next
        // reset, which is the same lifetime `deinit` already gave them.
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();

        while (!self.stop_flag.load(.monotonic)) {
            switch (watcher.waitForChange(&self.stop_flag)) {
                .stop => return false,
                .rotated, .deleted => return true,
                .modified => {},
            }
            it.refresh() catch |err| {
                log.warn("journal source '{s}' refresh failed: {t}", .{ self.name, err });
                continue;
            };
            while (true) {
                _ = scratch.reset(.retain_capacity);
                const entry = try it.next(scratch.allocator()) orelse break;
                var e = entry;
                defer e.deinit();
                self.handleNativeEntry(&e);
            }
        }
        return false;
    }

    /// Fields resolved from a native journal entry. Anything absent here is
    /// filtered out before it is copied, so adding an `e.get` below means
    /// adding the key here too.
    const native_fields = [_][]const u8{
        "MESSAGE", "_SYSTEMD_UNIT", "UNIT", "SYSLOG_IDENTIFIER", "PRIORITY", "_PID",
    };

    fn handleNativeEntry(self: *JournalSource, e: *const native.Entry) void {
        const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        // Every entry in the journal is a clock tick, including the ones
        // for other units: it is what lets a trace whose process died
        // mid-sentence be flushed without waiting for that unit to speak.
        self.tickAll(now_ms);

        const message = e.get("MESSAGE") orelse return;
        if (message.len == 0) return;
        const syslog_id = e.get("SYSLOG_IDENTIFIER") orelse "";
        // No unit means kernel, audit or early-boot output. Defaulting it to
        // the pattern used to hand a crit-level kernel line to every
        // journal source as a crash of its service.
        const unit = entryUnit(syslog_id, e.get("UNIT"), e.get("_SYSTEMD_UNIT")) orelse return;
        if (!native.source.matchesUnitGlob(self.pattern, unit)) return;
        self.handleMessage(unit, syslog_id, message, e.get("PRIORITY") orelse "", parsePid(e.get("_PID")), now_ms);
    }

    /// Classifies one entry already known to belong to this source.
    fn handleMessage(
        self: *JournalSource,
        unit: []const u8,
        syslog_id: []const u8,
        message: []const u8,
        priority: []const u8,
        pid: ?u32,
        now_ms: i64,
    ) void {
        if (std.mem.eql(u8, syslog_id, "systemd")) {
            switch (classifySystemdMessage(message)) {
                .lifecycle => if (isStart(message)) {
                    // A new process: whatever it does next is a new death.
                    if (self.trackers.get(unit)) |t| t.death_reported = false;
                },
                .crash_signal => self.onSystemdCrash(unit, message, now_ms),
                .other => {},
            }
            return;
        }

        const tracker = self.trackerFor(unit, now_ms) orelse return;
        const level = journalLevel(message, priority);
        while (tracker.observe(message, level, self.detector, now_ms)) |ev| {
            self.emit(ev, now_ms);
            if (!tracker.refeed) break;
        }
        // A crash that began on this very line: `_PID` is the process that
        // wrote it, which beats anything the tracker could parse out of the
        // text — and a Go or Python banner carries no pid at all.
        if (tracker.state == .crash_collecting and tracker.trace.lines == 0) {
            if (pid) |p| tracker.pending_pid = p;
        }
    }

    /// Flushes traces whose collection window has passed.
    fn tickAll(self: *JournalSource, now_ms: i64) void {
        var it = self.trackers.valueIterator();
        while (it.next()) |t| {
            if (t.*.tick(now_ms, service.default_trace_flush_ms, service.default_stop_window_ms)) |ev| {
                self.emit(ev, now_ms);
            }
        }
    }

    /// Dispatches with the binding-wide counts in place of the tracker's.
    fn emit(self: *JournalSource, ev_in: service.ServiceEvent, now_ms: i64) void {
        var ev = ev_in;
        if (ev.kind == .crash) self.crash_count += 1;
        ev.crash_count = self.crash_count;
        ev.restart_count = self.restart_count;
        self.dispatcher.dispatchService(ev, now_ms);
    }

    fn spawnAndRead(self: *JournalSource) !void {
        if (comptime builtin.os.tag != .linux) return;

        const argv = [_][]const u8{
            "journalctl",
            "-fu",
            self.pattern,
            "--output=json",
            "--no-pager",
            "--since",
            "now",
        };
        const child = std.process.spawn(self.io, .{
            .argv = &argv,
            .stdout = .pipe,
            .stderr = .ignore,
            .stdin = .ignore,
        }) catch |err| {
            log.warn("spawn journalctl failed for '{s}': {t}", .{ self.name, err });
            return;
        };
        self.child = child;
        const stdout = child.stdout orelse {
            log.warn("journalctl stdout pipe missing", .{});
            return;
        };

        var buf: [read_buf_size]u8 = undefined;
        var carry: std.ArrayList(u8) = .empty;
        defer carry.deinit(self.allocator);

        while (!self.stop_flag.load(.monotonic)) {
            const n = stdout.readStreaming(self.io, &.{&buf}) catch |err| {
                if (err == error.EndOfStream) break;
                log.warn("read from journalctl failed: {t}", .{err});
                break;
            };
            if (n == 0) break;
            try self.processChunk(&carry, buf[0..n]);
        }
    }

    fn processChunk(self: *JournalSource, carry: *std.ArrayList(u8), chunk: []const u8) !void {
        var i: usize = 0;
        while (i < chunk.len) {
            const nl = std.mem.indexOfScalarPos(u8, chunk, i, '\n') orelse {
                // Tail of the chunk with no newline: keep accumulating unless
                // this line has already blown the cap.
                if (self.line_overflow) return;
                if (carry.items.len + (chunk.len - i) > max_line_bytes) {
                    self.noteOverflow();
                    carry.clearRetainingCapacity();
                    return;
                }
                try carry.appendSlice(self.allocator, chunk[i..]);
                return;
            };

            const segment = chunk[i..nl];
            if (self.line_overflow) {
                // The newline ends the poisoned line; the next one starts clean.
                self.line_overflow = false;
                carry.clearRetainingCapacity();
            } else if (carry.items.len == 0) {
                if (segment.len <= max_line_bytes) {
                    self.handleEntry(segment);
                } else {
                    self.noteOverflow();
                    self.line_overflow = false; // the newline is right here
                }
            } else if (carry.items.len + segment.len <= max_line_bytes) {
                try carry.appendSlice(self.allocator, segment);
                self.handleEntry(carry.items);
                carry.clearRetainingCapacity();
            } else {
                self.noteOverflow();
                carry.clearRetainingCapacity();
            }
            i = nl + 1;
        }
    }

    fn noteOverflow(self: *JournalSource) void {
        self.line_overflow = true;
        if (self.overflow_logged) return;
        self.overflow_logged = true;
        log.warn("journal source '{s}': entry exceeds {d} bytes; dropping it (logged once)", .{
            self.name, max_line_bytes,
        });
    }

    fn handleEntry(self: *JournalSource, json_line: []const u8) void {
        const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        self.tickAll(now_ms);

        var msg_buf: [unescape_buf_size]u8 = undefined;
        const message = messageFromEntry(json_line, &msg_buf) orelse return;
        if (message.len == 0) return;

        // 64 was tight — `SYSLOG_IDENTIFIER` mirrors the executable name and
        // some binaries have long ones.
        var sid_buf: [128]u8 = undefined;
        const syslog_id = if (findJsonStringField(json_line, "SYSLOG_IDENTIFIER")) |s| unescapeJsonString(&sid_buf, s) else "";

        // Systemd unit names are usually ≤ 100 bytes, but template instances
        // can push past 256, and a truncated name misses its tracker.
        var unit_buf: [512]u8 = undefined;
        var sunit_buf: [512]u8 = undefined;
        const unit_field = if (findJsonStringField(json_line, "UNIT")) |u| unescapeJsonString(&unit_buf, u) else null;
        const systemd_unit = if (findJsonStringField(json_line, "_SYSTEMD_UNIT")) |u| unescapeJsonString(&sunit_buf, u) else null;
        // `journalctl -u` already filtered to the pattern, so an entry that
        // names no unit still belongs here.
        const unit = entryUnit(syslog_id, unit_field, systemd_unit) orelse self.pattern;

        self.handleMessage(
            unit,
            syslog_id,
            message,
            findJsonStringField(json_line, "PRIORITY") orelse "",
            parsePid(findJsonStringField(json_line, "_PID")),
            now_ms,
        );
    }

    fn trackerFor(self: *JournalSource, unit: []const u8, now_ms: i64) ?*service.Tracker {
        if (self.trackers.get(unit)) |t| return t;
        if (self.trackers.count() >= max_units_per_source) {
            log.warn("journal source '{s}' hit per-source unit cap ({d}); skipping {s}", .{
                self.name,
                max_units_per_source,
                unit,
            });
            return null;
        }
        // Note: this function returns `?*Tracker` (not `!*Tracker`), so
        // `errdefer` would never fire. Every failure arm below cleans up
        // explicitly.
        const key = self.allocator.dupe(u8, unit) catch return null;
        const ptr = self.allocator.create(service.Tracker) catch {
            self.allocator.free(key);
            return null;
        };
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ journal_pseudo_path_prefix, unit }) catch unit;
        const owned_path = self.allocator.dupe(u8, path) catch {
            self.allocator.destroy(ptr);
            self.allocator.free(key);
            return null;
        };
        ptr.* = service.Tracker.initJournal(self.name, owned_path, now_ms);
        self.trackers.put(self.allocator, key, ptr) catch {
            self.allocator.free(owned_path);
            self.allocator.destroy(ptr);
            self.allocator.free(key);
            return null;
        };
        return ptr;
    }

    /// systemd told us a unit died abnormally.
    ///
    /// One death produces up to three reports: the application's own crash
    /// banner, `Main process exited, …`, and `Failed with result '…'`. Only
    /// the first one is an alert. A notice is treated as an echo while the
    /// tracker has a death on record that no `Started` has cleared since,
    /// and that is recent — an application crash that turned out not to
    /// kill the process must not swallow a real death hours later.
    fn onSystemdCrash(self: *JournalSource, unit: []const u8, message: []const u8, now_ms: i64) void {
        const tracker = self.trackerFor(unit, now_ms) orelse return;

        // The process is gone, so the trace being collected is complete.
        // Emitting it here is what gets a panic reported when the service
        // stays down and its unit never logs again.
        if (tracker.flush()) |ev| {
            self.emit(ev, now_ms);
            return;
        }
        if (tracker.death_reported and now_ms - tracker.last_crash_ms < echo_window_ms) return;

        tracker.death_reported = true;
        tracker.last_crash_ms = now_ms;
        self.emit(.{
            .kind = .crash,
            .service_name = self.name,
            .file_path = tracker.path,
            .marker = service.MarkerKind.systemd_signal.label(),
            // `_PID` on this entry is systemd's own, 1; the message does not
            // carry the dead process's pid.
            .pid = null,
            .detail = message,
            .stack_trace = "",
            .crash_count = 0,
            .restart_count = 0,
        }, now_ms);
    }
};

fn parsePid(raw: ?[]const u8) ?u32 {
    return std.fmt.parseInt(u32, raw orelse return null, 10) catch null;
}

/// How long after a crash a systemd notice still counts as its echo. systemd
/// reports a death within milliseconds; a minute leaves room for a slow
/// `ExecStopPost=` without merging two separate deaths.
const echo_window_ms: i64 = 60_000;

/// `MESSAGE`, unescaped into `buf`. journalctl writes it as an array of byte
/// values instead of a string when it is not valid UTF-8 or holds control
/// bytes — ANSI colour codes, most often. Those entries used to be dropped,
/// crash banner and all.
pub fn messageFromEntry(json_line: []const u8, buf: []u8) ?[]const u8 {
    if (findJsonStringField(json_line, "MESSAGE")) |raw| return unescapeJsonString(buf, raw);
    const at = std.mem.indexOf(u8, json_line, "\"MESSAGE\":[") orelse return null;
    var it = std.mem.tokenizeAny(u8, json_line[at + "\"MESSAGE\":[".len ..], ", ");
    var n: usize = 0;
    while (it.next()) |tok| {
        const end = std.mem.indexOfScalar(u8, tok, ']');
        const digits = tok[0 .. end orelse tok.len];
        if (digits.len > 0) {
            if (n == buf.len) break;
            buf[n] = std.fmt.parseInt(u8, digits, 10) catch return null;
            n += 1;
        }
        if (end != null) break;
    }
    return buf[0..n];
}

const testing = std.testing;

test "classifySystemdMessage: routine lifecycle" {
    try testing.expectEqual(SystemdClass.lifecycle, classifySystemdMessage("Started api.service - API server"));
    try testing.expectEqual(SystemdClass.lifecycle, classifySystemdMessage("Stopped api.service"));
    try testing.expectEqual(SystemdClass.lifecycle, classifySystemdMessage("Stopping api.service"));
    try testing.expectEqual(SystemdClass.lifecycle, classifySystemdMessage("Reloading api.service"));
    try testing.expectEqual(SystemdClass.lifecycle, classifySystemdMessage("Deactivated successfully."));
    try testing.expectEqual(SystemdClass.lifecycle, classifySystemdMessage("Consumed 12s CPU time."));
}

test "classifySystemdMessage: crash signals" {
    try testing.expectEqual(
        SystemdClass.crash_signal,
        classifySystemdMessage("Main process exited, code=killed, status=11/SEGV"),
    );
    try testing.expectEqual(
        SystemdClass.crash_signal,
        classifySystemdMessage("Main process exited, code=dumped, status=6/ABRT"),
    );
    try testing.expectEqual(
        SystemdClass.crash_signal,
        classifySystemdMessage("api.service: Failed with result 'signal'."),
    );
    try testing.expectEqual(
        SystemdClass.crash_signal,
        classifySystemdMessage("api.service: Failed with result 'oom-kill'."),
    );
    try testing.expectEqual(
        SystemdClass.crash_signal,
        classifySystemdMessage("api.service: Failed with result 'core-dump'."),
    );
    try testing.expectEqual(
        SystemdClass.crash_signal,
        classifySystemdMessage("api.service: Failed with result 'watchdog'."),
    );
}

test "classifySystemdMessage: other" {
    try testing.expectEqual(SystemdClass.other, classifySystemdMessage("Some other systemd note"));
}

test "priorityToLevel: full mapping" {
    try testing.expectEqual(flags.Level.Panic, priorityToLevel("0").?);
    try testing.expectEqual(flags.Level.Panic, priorityToLevel("1").?);
    try testing.expectEqual(flags.Level.Fatal, priorityToLevel("2").?);
    try testing.expectEqual(flags.Level.Error, priorityToLevel("3").?);
    try testing.expectEqual(flags.Level.Warn, priorityToLevel("4").?);
    try testing.expectEqual(flags.Level.Info, priorityToLevel("5").?);
    try testing.expectEqual(flags.Level.Info, priorityToLevel("6").?);
    try testing.expectEqual(flags.Level.Debug, priorityToLevel("7").?);
    try testing.expectEqual(@as(?flags.Level, null), priorityToLevel("nine"));
}

test "findJsonStringField: extracts top-level keys without unescaping" {
    const json = "{\"MESSAGE\":\"hello world\",\"_PID\":\"42\",\"_SYSTEMD_UNIT\":\"api.service\"}";
    try testing.expectEqualStrings("hello world", findJsonStringField(json, "MESSAGE").?);
    try testing.expectEqualStrings("42", findJsonStringField(json, "_PID").?);
    try testing.expectEqualStrings("api.service", findJsonStringField(json, "_SYSTEMD_UNIT").?);
    try testing.expectEqual(@as(?[]const u8, null), findJsonStringField(json, "ABSENT"));
}

test "findJsonStringField: respects key boundary so substring matches don't fool the scanner" {
    // `"MESSAGE":"x"` should not match when looking for `"AGE"` — even
    // though `AGE` is a substring of `MESSAGE`.
    const json = "{\"MESSAGE\":\"x\",\"AGE\":\"42\"}";
    try testing.expectEqualStrings("42", findJsonStringField(json, "AGE").?);
    try testing.expectEqualStrings("x", findJsonStringField(json, "MESSAGE").?);
}

test "findJsonStringField: tolerates escaped quotes inside values" {
    const json = "{\"MESSAGE\":\"say \\\"hi\\\"\",\"NEXT\":\"after\"}";
    try testing.expectEqualStrings("say \\\"hi\\\"", findJsonStringField(json, "MESSAGE").?);
    try testing.expectEqualStrings("after", findJsonStringField(json, "NEXT").?);
}

test "unescapeJsonString: decodes common escapes" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "line\nnext\ttab\"quote\\back",
        unescapeJsonString(&buf, "line\\nnext\\ttab\\\"quote\\\\back"),
    );
}

test "unescapeJsonString: decodes \\uXXXX BMP codepoints" {
    var buf: [16]u8 = undefined;
    // U+00E9 (é) → UTF-8 C3 A9
    try testing.expectEqualSlices(u8, "\xc3\xa9", unescapeJsonString(&buf, "\\u00e9"));
}

/// Collects the entries `processChunk` decides to deliver, so the carry
/// logic can be exercised without a journalctl subprocess or a dispatcher.
const ChunkProbe = struct {
    src: JournalSource,
    carry: std.ArrayList(u8) = .empty,
    delivered: std.ArrayList([]u8) = .empty,

    fn init() ChunkProbe {
        return .{ .src = .{
            .allocator = testing.allocator,
            .io = undefined,
            .name = "probe",
            .pattern = "*",
            .dispatcher = undefined,
            .detector = undefined,
            .trackers = .{},
            .stop_flag = .init(false),
        } };
    }

    fn deinit(self: *ChunkProbe) void {
        for (self.delivered.items) |d| testing.allocator.free(d);
        self.delivered.deinit(testing.allocator);
        self.carry.deinit(testing.allocator);
    }

    /// Mirrors `processChunk` but records instead of dispatching. Kept in
    /// step with the real one by construction: it calls it, with
    /// `handleEntry` swapped for capture via the overflow flags.
    fn feed(self: *ChunkProbe, chunk: []const u8) !void {
        var i: usize = 0;
        const s = &self.src;
        while (i < chunk.len) {
            const nl = std.mem.indexOfScalarPos(u8, chunk, i, '\n') orelse {
                if (s.line_overflow) return;
                if (self.carry.items.len + (chunk.len - i) > max_line_bytes) {
                    s.line_overflow = true;
                    self.carry.clearRetainingCapacity();
                    return;
                }
                try self.carry.appendSlice(testing.allocator, chunk[i..]);
                return;
            };
            const segment = chunk[i..nl];
            if (s.line_overflow) {
                s.line_overflow = false;
                self.carry.clearRetainingCapacity();
            } else if (self.carry.items.len == 0) {
                if (segment.len <= max_line_bytes) {
                    try self.delivered.append(testing.allocator, try testing.allocator.dupe(u8, segment));
                } else {
                    s.line_overflow = false;
                }
            } else if (self.carry.items.len + segment.len <= max_line_bytes) {
                try self.carry.appendSlice(testing.allocator, segment);
                try self.delivered.append(testing.allocator, try testing.allocator.dupe(u8, self.carry.items));
                self.carry.clearRetainingCapacity();
            } else {
                s.line_overflow = true;
                self.carry.clearRetainingCapacity();
            }
            i = nl + 1;
        }
    }
};

test "processChunk: an over-long entry is dropped, not spliced" {
    // The failure this guards: the bytes past the cap were discarded but the
    // carry was kept, so a later chunk completed the line and delivered a
    // record made of its head and its tail with the middle missing. It parses
    // as valid JSON and is the wrong entry — silent corruption rather than a
    // dropped line.
    var p = ChunkProbe.init();
    defer p.deinit();

    try p.feed("{\"MESSAGE\":\"HEAD-");
    const middle = try testing.allocator.alloc(u8, max_line_bytes);
    defer testing.allocator.free(middle);
    @memset(middle, 'M');
    try p.feed(middle);
    try p.feed("TAIL\"}\n");

    try testing.expectEqual(@as(usize, 0), p.delivered.items.len);
}

test "processChunk: the entry after an over-long one is delivered intact" {
    var p = ChunkProbe.init();
    defer p.deinit();

    const huge = try testing.allocator.alloc(u8, max_line_bytes + 64);
    defer testing.allocator.free(huge);
    @memset(huge, 'X');
    try p.feed(huge);
    try p.feed("\n");
    try p.feed("{\"MESSAGE\":\"next one is fine\"}\n");

    try testing.expectEqual(@as(usize, 1), p.delivered.items.len);
    try testing.expectEqualStrings("{\"MESSAGE\":\"next one is fine\"}", p.delivered.items[0]);
}

test "processChunk: a line split across reads is reassembled" {
    var p = ChunkProbe.init();
    defer p.deinit();

    try p.feed("{\"MESSAGE\":\"spl");
    try p.feed("it across ");
    try p.feed("three reads\"}\n{\"MESSAGE\":\"second\"}\n");

    try testing.expectEqual(@as(usize, 2), p.delivered.items.len);
    try testing.expectEqualStrings("{\"MESSAGE\":\"split across three reads\"}", p.delivered.items[0]);
    try testing.expectEqualStrings("{\"MESSAGE\":\"second\"}", p.delivered.items[1]);
}

// ─── Crash detection, end to end ──────────────────────────────────────────

const metrics_mod = @import("metrics.zig");

/// A journal source wired to a real dispatcher whose only sink is a JSONL
/// file, so a test reads back exactly what an operator would receive.
const Harness = struct {
    tmp: testing.TmpDir,
    path_buf: [128]u8 = undefined,
    path: []const u8 = "",
    m: metrics_mod.Metrics,
    d: alert.Dispatcher,
    det: service.Detector,
    src: JournalSource,

    fn init(self: *Harness, pattern: []const u8) !void {
        self.tmp = testing.tmpDir(.{});
        const path = try std.fmt.bufPrint(&self.path_buf, ".zig-cache/tmp/{s}/alerts.jsonl", .{self.tmp.sub_path});
        self.path = path;
        self.m = metrics_mod.Metrics.init(0);
        self.d = try alert.Dispatcher.init(std.Options.debug_io, .{
            .stderr = false,
            .file_path = path,
            .webhooks = &.{},
            .webhook_headers = &.{},
        }, &self.m, false);
        self.det = .{ .customs = &.{} };
        self.src = JournalSource.init(testing.allocator, std.Options.debug_io, "api", pattern, &self.d, &self.det);
    }

    fn deinit(self: *Harness) void {
        self.src.deinit();
        self.d.deinit();
        self.tmp.cleanup();
    }

    /// An application line on stderr: journald's default priority, info.
    fn app(self: *Harness, unit: []const u8, msg: []const u8, now: i64) void {
        self.appPid(unit, msg, 4242, now);
    }

    fn appPid(self: *Harness, unit: []const u8, msg: []const u8, pid: u32, now: i64) void {
        self.src.tickAll(now);
        self.src.handleMessage(unit, "api", msg, "6", pid, now);
    }

    /// PID 1 writes these; its `_PID` must not end up on the alert.
    fn systemd(self: *Harness, unit: []const u8, msg: []const u8, now: i64) void {
        self.src.tickAll(now);
        self.src.handleMessage(unit, "systemd", msg, "5", 1, now);
    }

    /// Every alert written so far. Caller frees with `freeRecords`.
    fn records(self: *Harness) ![]std.json.Parsed(std.json.Value) {
        const contents = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, self.path, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(contents);
        var out: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
        var it = std.mem.tokenizeScalar(u8, contents, '\n');
        while (it.next()) |line| try out.append(testing.allocator, try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{}));
        return out.toOwnedSlice(testing.allocator);
    }
};

fn freeRecords(rs: []std.json.Parsed(std.json.Value)) void {
    for (rs) |*r| r.deinit();
    testing.allocator.free(rs);
}

fn field(r: std.json.Parsed(std.json.Value), key: []const u8) std.json.Value {
    return r.value.object.get(key).?;
}

test "a Go panic on stderr is reported once, and systemd's notices are its echo" {
    var h: Harness = undefined;
    try h.init("api.service");
    defer h.deinit();
    const u = "api.service";

    // journald files stderr at info; this used to hide every runtime banner.
    h.app(u, "panic: runtime error: index out of range [3] with length 3", 100);
    h.app(u, "", 101);
    h.app(u, "goroutine 1 [running]:", 102);
    h.app(u, "main.main()", 103);
    h.app(u, "\t/app/main.go:9 +0x1d", 104);
    // The process is gone; nothing else from the unit is coming, and the
    // trace must not wait for it.
    h.systemd(u, "api.service: Main process exited, code=exited, status=2/INVALIDARGUMENT", 105);
    h.systemd(u, "api.service: Failed with result 'exit-code'.", 106);

    const rs = try h.records();
    defer freeRecords(rs);
    try testing.expectEqual(@as(usize, 1), rs.len);
    try testing.expectEqualStrings("go_panic", field(rs[0], "marker").string);
    try testing.expect(std.mem.indexOf(u8, field(rs[0], "stack_trace").string, "main.go:9") != null);
    try testing.expectEqual(@as(i64, 1), field(rs[0], "crash_count").integer);
    try testing.expectEqualStrings("journal://api.service", field(rs[0], "file").string);
}

test "a death only systemd saw is one alert, and a restart re-arms it" {
    var h: Harness = undefined;
    try h.init("api.service");
    defer h.deinit();
    const u = "api.service";

    h.systemd(u, "api.service: Main process exited, code=killed, status=11/SEGV", 100);
    h.systemd(u, "api.service: Failed with result 'signal'.", 101);
    h.systemd(u, "Started api.service - API.", 300);
    h.systemd(u, "api.service: Main process exited, code=dumped, status=6/ABRT", 400);
    h.systemd(u, "api.service: Failed with result 'core-dump'.", 401);

    const rs = try h.records();
    defer freeRecords(rs);
    try testing.expectEqual(@as(usize, 2), rs.len);
    try testing.expectEqualStrings("systemd_signal", field(rs[0], "marker").string);
    try testing.expect(std.mem.indexOf(u8, field(rs[0], "detail").string, "status=11/SEGV") != null);
    try testing.expectEqual(@as(i64, 1), field(rs[0], "crash_count").integer);
    try testing.expectEqual(@as(i64, 2), field(rs[1], "crash_count").integer);
    // systemd's own pid is not the dead process's.
    try testing.expect(!rs[0].value.object.contains("pid"));
}

test "a stale application crash does not swallow a later death" {
    var h: Harness = undefined;
    try h.init("api.service");
    defer h.deinit();
    const u = "api.service";

    // A traceback the process survived, then an OOM kill hours later with
    // no restart in between.
    h.app(u, "Traceback (most recent call last):", 0);
    h.app(u, "  File \"/app/x.py\", line 1, in <module>", 1);
    h.app(u, "KeyError: 'x'", 2);
    h.systemd(u, "api.service: Failed with result 'oom-kill'.", 3 * 60 * 60 * 1000);

    const rs = try h.records();
    defer freeRecords(rs);
    try testing.expectEqual(@as(usize, 2), rs.len);
    try testing.expectEqualStrings("python_traceback", field(rs[0], "marker").string);
    try testing.expectEqualStrings("systemd_signal", field(rs[1], "marker").string);
}

test "quoted crash phrases in structured logs are not crashes" {
    var h: Harness = undefined;
    try h.init("api.service");
    defer h.deinit();
    h.app("api.service", "{\"level\":\"info\",\"msg\":\"recovered from panic: nil map\"}", 100);
    h.app("api.service", "level=warn msg=\"retrying after panic: timeout\"", 200);
    h.src.tickAll(10_000);

    const rs = try h.records();
    defer freeRecords(rs);
    try testing.expectEqual(@as(usize, 0), rs.len);
}

test "counts are per binding, across every unit its pattern matches" {
    var h: Harness = undefined;
    try h.init("worker@*.service");
    defer h.deinit();
    h.systemd("worker@1.service", "worker@1.service: Failed with result 'signal'.", 100);
    h.systemd("worker@2.service", "worker@2.service: Failed with result 'signal'.", 200);

    const rs = try h.records();
    defer freeRecords(rs);
    try testing.expectEqual(@as(usize, 2), rs.len);
    try testing.expectEqual(@as(i64, 1), field(rs[0], "crash_count").integer);
    try testing.expectEqual(@as(i64, 2), field(rs[1], "crash_count").integer);
    try testing.expectEqualStrings("journal://worker@2.service", field(rs[1], "file").string);
}

test "a trace is flushed by the clock even when its unit falls silent" {
    var h: Harness = undefined;
    try h.init("api.service");
    defer h.deinit();
    h.app("api.service", "thread 'main' panicked at src/main.rs:4:5:", 100);
    h.app("api.service", "called `Option::unwrap()` on a `None` value", 101);
    // Some other unit's entry, well past the flush window.
    h.src.tickAll(100 + service.default_trace_flush_ms);

    const rs = try h.records();
    defer freeRecords(rs);
    try testing.expectEqual(@as(usize, 1), rs.len);
    try testing.expectEqualStrings("rust_panic", field(rs[0], "marker").string);
    try testing.expect(std.mem.indexOf(u8, field(rs[0], "stack_trace").string, "unwrap()") != null);
}

test "journalLevel: the message's own level wins; PRIORITY only counts at err or worse" {
    try testing.expectEqual(@as(?flags.Level, null), journalLevel("panic: boom", "6"));
    try testing.expectEqual(flags.Level.Error, journalLevel("panic: boom", "3").?);
    try testing.expectEqual(flags.Level.Fatal, journalLevel("disk on fire", "2").?);
    try testing.expectEqual(flags.Level.Info, journalLevel("{\"level\":\"info\",\"msg\":\"x\"}", "3").?);
}

test "entryUnit: systemd's notices are about UNIT, not init.scope" {
    try testing.expectEqualStrings("api.service", entryUnit("systemd", "api.service", "init.scope").?);
    try testing.expectEqualStrings("api.service", entryUnit("api", "spoofed.service", "api.service").?);
    try testing.expectEqualStrings("init.scope", entryUnit("systemd", null, "init.scope").?);
    try testing.expect(entryUnit("kernel", null, null) == null);
}

test "messageFromEntry: string and byte-array forms" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("panic: x", messageFromEntry("{\"MESSAGE\":\"panic: x\"}", &buf).?);
    // `\x1b[31mpanic: x` as journalctl writes it.
    try testing.expectEqualStrings(
        "\x1b[31mpanic: x",
        messageFromEntry("{\"MESSAGE\":[27,91,51,49,109,112,97,110,105,99,58,32,120],\"_PID\":\"1\"}", &buf).?,
    );
    try testing.expect(messageFromEntry("{\"_PID\":\"1\"}", &buf) == null);
}

test "the crash carries the _PID of the line that opened it" {
    var h: Harness = undefined;
    try h.init("api.service");
    defer h.deinit();
    const u = "api.service";

    h.appPid(u, "panic: boom", 777, 100);
    h.appPid(u, "", 777, 101);
    h.appPid(u, "goroutine 1 [running]:", 777, 102);
    h.systemd(u, "api.service: Main process exited, code=exited, status=2/INVALIDARGUMENT", 103);
    h.systemd(u, "api.service: Failed with result 'exit-code'.", 104);

    const rs = try h.records();
    defer freeRecords(rs);
    try testing.expectEqual(@as(usize, 1), rs.len);
    try testing.expectEqual(@as(i64, 777), field(rs[0], "pid").integer);
}

test "a pid in the text wins over nothing, _PID wins over the text" {
    var h: Harness = undefined;
    try h.init("api.service");
    defer h.deinit();
    h.appPid("api.service", "{\"level\":\"fatal\",\"pid\":12,\"msg\":\"db gone\"}", 34, 100);
    h.systemd("api.service", "api.service: Failed with result 'exit-code'.", 101);

    const rs = try h.records();
    defer freeRecords(rs);
    try testing.expectEqual(@as(usize, 1), rs.len);
    try testing.expectEqual(@as(i64, 34), field(rs[0], "pid").integer);
}
