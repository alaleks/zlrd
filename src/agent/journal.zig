//! systemd-journal source for agent mode.
//!
//! Each `--journal-unit NAME=PATTERN` spawns one `journalctl -fu <PATTERN>
//! --output=json --no-pager --since now` subprocess and consumes its stdout
//! line-by-line. Each line is one JSON-encoded journal entry; we extract a
//! handful of fields (MESSAGE, PRIORITY, _SYSTEMD_UNIT, _PID,
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
    return false;
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
    stop_flag: std.atomic.Value(bool),
    child: ?std.process.Child = null,

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

    pub fn deinit(self: *JournalSource) void {
        var it = self.trackers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
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

        // Enable the DATA-object cache for live tailing — hot fields like
        // `_SYSTEMD_UNIT` are referenced by every entry of a service and
        // would otherwise hit the disk (+LZ4) once per entry.
        try it.enableCache(self.allocator);
        defer it.disableCache(self.allocator);

        var watcher = native.Watcher.init(self.io, &r, .{
            .dir = std.Io.Dir.cwd(),
            .path = path,
        });
        defer watcher.deinit();

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
            while (try it.next(self.allocator)) |entry| {
                var e = entry;
                defer e.deinit();
                self.handleNativeEntry(&e);
            }
        }
        return false;
    }

    fn handleNativeEntry(self: *JournalSource, e: *const native.Entry) void {
        const message = e.get("MESSAGE") orelse return;
        if (message.len == 0) return;

        const unit = e.get("_SYSTEMD_UNIT") orelse self.pattern;
        if (!native.source.matchesUnitGlob(self.pattern, unit)) return;
        const syslog_id = e.get("SYSLOG_IDENTIFIER") orelse "";
        const priority = e.get("PRIORITY") orelse "";
        const level = priorityToLevel(priority);
        const pid_str = e.get("_PID");
        const pid: ?u32 = if (pid_str) |s| std.fmt.parseInt(u32, s, 10) catch null else null;
        const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();

        if (std.mem.eql(u8, syslog_id, "systemd")) {
            switch (classifySystemdMessage(message)) {
                .lifecycle, .other => return,
                .crash_signal => {
                    self.emitSystemdCrash(unit, pid, message, now_ms);
                    return;
                },
            }
        }

        const tracker = self.trackerFor(unit, now_ms) orelse return;
        if (tracker.observe(message, level, self.detector, now_ms)) |ev| {
            self.dispatcher.dispatchService(ev, now_ms);
        }
        if (tracker.tick(now_ms, service.default_trace_flush_ms, service.default_stop_window_ms)) |ev| {
            self.dispatcher.dispatchService(ev, now_ms);
        }
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
                if (carry.items.len + (chunk.len - i) <= max_line_bytes) {
                    try carry.appendSlice(self.allocator, chunk[i..]);
                }
                return;
            };
            const segment = chunk[i..nl];
            if (carry.items.len == 0) {
                if (segment.len <= max_line_bytes) self.handleEntry(segment);
            } else {
                if (carry.items.len + segment.len <= max_line_bytes) {
                    try carry.appendSlice(self.allocator, segment);
                    self.handleEntry(carry.items);
                }
                carry.clearRetainingCapacity();
            }
            i = nl + 1;
        }
    }

    fn handleEntry(self: *JournalSource, json_line: []const u8) void {
        const raw_message = findJsonStringField(json_line, "MESSAGE") orelse return;
        if (raw_message.len == 0) return;

        var msg_buf: [unescape_buf_size]u8 = undefined;
        const message = unescapeJsonString(&msg_buf, raw_message);

        const unit_raw = findJsonStringField(json_line, "_SYSTEMD_UNIT");
        var unit_buf: [256]u8 = undefined;
        const unit = if (unit_raw) |u|
            unescapeJsonString(&unit_buf, u)
        else
            self.pattern;

        const syslog_id_raw = findJsonStringField(json_line, "SYSLOG_IDENTIFIER");
        var sid_buf: [64]u8 = undefined;
        const syslog_id = if (syslog_id_raw) |s| unescapeJsonString(&sid_buf, s) else "";

        const priority = findJsonStringField(json_line, "PRIORITY") orelse "";
        const level = priorityToLevel(priority);
        const pid = pidFromEntry(json_line);
        const now_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();

        if (std.mem.eql(u8, syslog_id, "systemd")) {
            switch (classifySystemdMessage(message)) {
                .lifecycle => return,
                .crash_signal => {
                    self.emitSystemdCrash(unit, pid, message, now_ms);
                    return;
                },
                .other => return,
            }
        }

        // Application log entry — route to the per-unit tracker.
        const tracker = self.trackerFor(unit, now_ms) orelse return;
        if (tracker.observe(message, level, self.detector, now_ms)) |ev| {
            self.dispatcher.dispatchService(ev, now_ms);
        }
        // Tick frequently so the trace-collection window can flush even when
        // entries arrive sparsely.
        if (tracker.tick(now_ms, service.default_trace_flush_ms, service.default_stop_window_ms)) |ev| {
            self.dispatcher.dispatchService(ev, now_ms);
        }
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
        const key = self.allocator.dupe(u8, unit) catch return null;
        errdefer self.allocator.free(key);
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

    /// systemd told us a unit died abnormally. Surface it directly — there
    /// is no application-side stack trace to wait for. If a tracker already
    /// fired a crash for this unit very recently, suppress this echo.
    fn emitSystemdCrash(self: *JournalSource, unit: []const u8, pid: ?u32, message: []const u8, now_ms: i64) void {
        if (self.trackers.get(unit)) |t| {
            if (t.state == .crash_collecting or t.state == .crash_emitted) {
                // The app already produced a crash event for this unit;
                // systemd's notice is the same event from a different vantage.
                return;
            }
        }
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ journal_pseudo_path_prefix, unit }) catch unit;
        const ev: service.ServiceEvent = .{
            .kind = .crash,
            .service_name = self.name,
            .file_path = path,
            .marker = service.MarkerKind.systemd_signal.label(),
            .pid = pid,
            .detail = message,
            .stack_trace = "",
            .crash_count = 1,
            .restart_count = 0,
        };
        self.dispatcher.dispatchService(ev, now_ms);
    }
};

/// Extracts the `_PID` field and parses it. Returns null if the field is
/// missing or non-numeric.
fn pidFromEntry(json_line: []const u8) ?u32 {
    const raw = findJsonStringField(json_line, "_PID") orelse return null;
    return std.fmt.parseInt(u32, raw, 10) catch null;
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

test "pidFromEntry: parses numeric _PID" {
    const json = "{\"_PID\":\"1234\"}";
    try testing.expectEqual(@as(?u32, 1234), pidFromEntry(json));
    try testing.expectEqual(@as(?u32, null), pidFromEntry("{}"));
}
