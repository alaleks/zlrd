//! Service-level crash tracker.
//!
//! Per-service state machine that turns log-line observations into structured
//! lifecycle events: `crash`, `stop`, `restart`. A "service" is whatever the
//! user has bound to a log file path via `--service NAME=PATH`.
//!
//! Detection sources:
//!   * Built-in crash markers (Go `panic:`, Python `Traceback (most recent
//!     call last):`, Java `Exception in thread `, JSON/logfmt level
//!     `fatal` / `panic`).
//!   * User-supplied regex patterns via `--crash-marker '<regex>'`.
//!
//! Stop vs. restart is inferred from file-level signals only — silence past
//! `stop_window_ms` after a crash counts as a stop; an inode change at any
//! point counts as a restart (the service rotated/reopened its log file).
//!
//! Allocation policy: fixed-size per-tracker buffers. Stack traces are
//! captured into an inline 4 KiB buffer (max 32 lines) — anything beyond is
//! truncated. No per-line heap activity.

const std = @import("std");
const flags = @import("flags");
const regex = @import("regex");

/// Cap on retained stack trace bytes. Keeps the alert payload small enough
/// for a single HTTP POST and protects against runaway recursive panics.
pub const max_trace_bytes: usize = 4 * 1024;
pub const max_trace_lines: u8 = 32;

/// Cap on the trigger-line copy embedded in the event.
pub const max_detail_bytes: usize = 256;

/// Defaults — tuned for human-paced services. The watcher passes these to
/// `tick` so tests can override.
pub const default_trace_flush_ms: u64 = 250;
pub const default_stop_window_ms: u64 = 30_000;

pub const MarkerKind = enum {
    go_panic,
    python_traceback,
    java_exception,
    fatal_level,
    panic_level,
    custom_regex,

    pub fn label(self: MarkerKind) []const u8 {
        return switch (self) {
            .go_panic => "go_panic",
            .python_traceback => "python_traceback",
            .java_exception => "java_exception",
            .fatal_level => "fatal_level",
            .panic_level => "panic_level",
            .custom_regex => "custom_regex",
        };
    }
};

pub const EventKind = enum {
    crash,
    stop,
    restart,

    pub fn label(self: EventKind) []const u8 {
        return switch (self) {
            .crash => "service_crash",
            .stop => "service_stop",
            .restart => "service_restart",
        };
    }
};

pub const ServiceEvent = struct {
    kind: EventKind,
    service_name: []const u8,
    file_path: []const u8,
    /// Marker that triggered the crash. Empty string for `stop` and `restart`.
    marker: []const u8,
    /// PID extracted from the trigger line if discoverable; null otherwise.
    pid: ?u32,
    /// The line that triggered detection. Empty for `stop` and `restart`.
    detail: []const u8,
    /// Captured trailing lines. Empty for `stop` and `restart`.
    stack_trace: []const u8,
    /// Running tally — useful for "second crash in N minutes" downstream rules.
    crash_count: u64,
    restart_count: u64,
};

/// Stateless crash-line detector. Holds an immutable view of user-supplied
/// regex rules; the built-in markers are pure pattern checks.
pub const Detector = struct {
    customs: []const regex.Regex,

    pub fn detect(self: *const Detector, line: []const u8, level: ?flags.Level) ?MarkerKind {
        if (level) |l| {
            if (l == .Fatal) return .fatal_level;
            if (l == .Panic) return .panic_level;
        }
        // Go's runtime prints "panic: <reason>" before the stack — anchor on
        // the marker, allow leading whitespace / level prefixes by scanning
        // anywhere in the line.
        if (std.mem.indexOf(u8, line, "panic:") != null) return .go_panic;
        if (std.mem.indexOf(u8, line, "Traceback (most recent call last):") != null) return .python_traceback;
        if (std.mem.indexOf(u8, line, "Exception in thread ") != null) return .java_exception;
        for (self.customs) |*re| {
            if (re.isMatch(line)) return .custom_regex;
        }
        return null;
    }
};

/// Inline stack-trace builder. Appends lines until the continuation
/// heuristic breaks or the byte/line cap is reached.
pub const StackTraceBuilder = struct {
    buf: [max_trace_bytes]u8 = undefined,
    used: usize = 0,
    lines: u8 = 0,
    active: bool = false,
    started_at_ms: i64 = 0,

    pub fn start(self: *StackTraceBuilder, now_ms: i64) void {
        self.used = 0;
        self.lines = 0;
        self.active = true;
        self.started_at_ms = now_ms;
    }

    pub fn reset(self: *StackTraceBuilder) void {
        self.used = 0;
        self.lines = 0;
        self.active = false;
    }

    /// Tries to append `line` as a continuation of the trace. Returns true
    /// when the line was accepted (or skipped as a leading separator); false
    /// when the trace is finished (heuristic break, line cap, or byte cap).
    pub fn feed(self: *StackTraceBuilder, line: []const u8) bool {
        if (!self.active) return false;
        if (self.lines >= max_trace_lines) {
            self.active = false;
            return false;
        }

        // Go's runtime prints a blank line between `panic: <reason>` and
        // `goroutine ... [running]:` — accept one leading blank as a
        // separator so the trace below it still gets captured.
        if (line.len == 0 and self.used == 0) return true;

        if (!isTraceLine(line)) {
            self.active = false;
            return false;
        }

        // Reserve one byte for the line separator.
        const room = max_trace_bytes -| self.used;
        if (room < 2) {
            self.active = false;
            return false;
        }
        const take = @min(line.len, room - 1);
        @memcpy(self.buf[self.used .. self.used + take], line[0..take]);
        self.used += take;
        self.buf[self.used] = '\n';
        self.used += 1;
        self.lines += 1;
        return true;
    }

    pub fn slice(self: *const StackTraceBuilder) []const u8 {
        return self.buf[0..self.used];
    }
};

/// Heuristic for "this line is a continuation of a stack trace":
///   * starts with tab or two+ spaces (Java/Python/Go indent)
///   * starts with "  at " / "\tat " (Java)
///   * starts with "  File " (Python)
///   * starts with "goroutine " / "[signal " (Go)
///   * starts with "Caused by:" (Java)
///   * starts with "0x" (raw backtrace)
/// Anything else terminates the trace.
pub fn isTraceLine(line: []const u8) bool {
    if (line.len == 0) return false;
    if (line[0] == '\t') return true;
    if (line.len >= 2 and line[0] == ' ' and line[1] == ' ') return true;
    if (std.mem.startsWith(u8, line, "goroutine ")) return true;
    if (std.mem.startsWith(u8, line, "[signal ")) return true;
    if (std.mem.startsWith(u8, line, "Caused by:")) return true;
    if (std.mem.startsWith(u8, line, "0x")) return true;
    return false;
}

/// Best-effort PID extraction. Recognizes `"pid":<n>` (JSON),
/// `pid=<n>` (logfmt), and `[<n>]:` (kernel/syslog style). Returns null if
/// no clear PID is present.
pub fn extractPid(line: []const u8) ?u32 {
    if (std.mem.indexOf(u8, line, "\"pid\":")) |i| {
        return parseUintAt(line, i + 6);
    }
    if (std.mem.indexOf(u8, line, "pid=")) |i| {
        return parseUintAt(line, i + 4);
    }
    if (std.mem.indexOf(u8, line, "[")) |lb| {
        if (std.mem.indexOfScalarPos(u8, line, lb, ']')) |rb| {
            if (rb > lb + 1) {
                return std.fmt.parseInt(u32, line[lb + 1 .. rb], 10) catch null;
            }
        }
    }
    return null;
}

fn parseUintAt(s: []const u8, start: usize) ?u32 {
    var i = start;
    // Tolerate one space after key separators.
    if (i < s.len and s[i] == ' ') i += 1;
    const begin = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    if (i == begin) return null;
    return std.fmt.parseInt(u32, s[begin..i], 10) catch null;
}

pub const State = enum {
    /// Default state: receiving normal logs.
    running,
    /// Marker matched; gathering the stack trace before emitting a crash.
    crash_collecting,
    /// Crash event already emitted; waiting for stop or restart signals.
    crash_emitted,
    /// Service stopped after a crash and silence window.
    stopped,
};

/// Per-service tracker. One Tracker per `--service` binding; held inside the
/// watcher's FileState.
pub const Tracker = struct {
    name: []const u8,
    path: []const u8,
    state: State = .running,
    last_log_ms: i64 = 0,
    crash_count: u64 = 0,
    restart_count: u64 = 0,

    pending_marker: MarkerKind = .go_panic,
    pending_detail_buf: [max_detail_bytes]u8 = undefined,
    pending_detail_len: u16 = 0,
    pending_pid: ?u32 = null,

    trace: StackTraceBuilder = .{},

    pub fn init(name: []const u8, path: []const u8, now_ms: i64) Tracker {
        return .{
            .name = name,
            .path = path,
            .last_log_ms = now_ms,
        };
    }

    /// Feed a log line. Returns a `ServiceEvent` only when one is ready to
    /// dispatch — crashes are delayed slightly so the trace can be captured;
    /// see `tick` for the timeout path.
    pub fn observe(
        self: *Tracker,
        line: []const u8,
        level: ?flags.Level,
        detector: *const Detector,
        now_ms: i64,
    ) ?ServiceEvent {
        self.last_log_ms = now_ms;

        if (self.state == .crash_collecting) {
            if (self.trace.feed(line)) return null;
            // Trace ended at this line. Emit the crash, then re-evaluate the
            // current line as a possible new running-state observation
            // (overlapping crashes are rare; we keep them rare on purpose).
            return self.emitCrash();
        }

        const marker = detector.detect(line, level) orelse return null;
        return self.beginCrash(marker, line, now_ms);
    }

    /// Periodic check, intended to be invoked roughly once per second by the
    /// watcher's silence ticker. Flushes pending crash collection after
    /// `trace_flush_ms` and fires `stop` after `stop_window_ms` of silence
    /// post-crash.
    pub fn tick(
        self: *Tracker,
        now_ms: i64,
        trace_flush_ms: u64,
        stop_window_ms: u64,
    ) ?ServiceEvent {
        switch (self.state) {
            .crash_collecting => {
                const elapsed: i64 = now_ms - self.trace.started_at_ms;
                if (elapsed >= @as(i64, @intCast(trace_flush_ms))) {
                    return self.emitCrash();
                }
                return null;
            },
            .crash_emitted => {
                const silent: i64 = now_ms - self.last_log_ms;
                if (silent >= @as(i64, @intCast(stop_window_ms))) {
                    self.state = .stopped;
                    return ServiceEvent{
                        .kind = .stop,
                        .service_name = self.name,
                        .file_path = self.path,
                        .marker = "",
                        .pid = null,
                        .detail = "",
                        .stack_trace = "",
                        .crash_count = self.crash_count,
                        .restart_count = self.restart_count,
                    };
                }
                return null;
            },
            else => return null,
        }
    }

    /// Called by the watcher when the file's inode changes — the service
    /// truncated, rotated, or reopened its log. From the tracker's vantage
    /// point this is a restart signal regardless of prior state.
    pub fn observeInodeChange(self: *Tracker, now_ms: i64) ServiceEvent {
        self.last_log_ms = now_ms;
        self.restart_count += 1;
        const prev = self.state;
        _ = prev;
        self.state = .running;
        // Drop any in-flight crash collection — the restart supersedes it.
        self.trace.reset();
        return ServiceEvent{
            .kind = .restart,
            .service_name = self.name,
            .file_path = self.path,
            .marker = "",
            .pid = null,
            .detail = "",
            .stack_trace = "",
            .crash_count = self.crash_count,
            .restart_count = self.restart_count,
        };
    }

    fn beginCrash(self: *Tracker, marker: MarkerKind, line: []const u8, now_ms: i64) ?ServiceEvent {
        self.state = .crash_collecting;
        self.pending_marker = marker;
        self.copyDetail(line);
        self.pending_pid = extractPid(line);
        self.crash_count += 1;
        self.trace.start(now_ms);
        return null;
    }

    fn emitCrash(self: *Tracker) ServiceEvent {
        const ev = ServiceEvent{
            .kind = .crash,
            .service_name = self.name,
            .file_path = self.path,
            .marker = self.pending_marker.label(),
            .pid = self.pending_pid,
            .detail = self.pending_detail_buf[0..self.pending_detail_len],
            .stack_trace = self.trace.slice(),
            .crash_count = self.crash_count,
            .restart_count = self.restart_count,
        };
        self.state = .crash_emitted;
        return ev;
    }

    fn copyDetail(self: *Tracker, line: []const u8) void {
        const n = @min(line.len, self.pending_detail_buf.len);
        @memcpy(self.pending_detail_buf[0..n], line[0..n]);
        self.pending_detail_len = @intCast(n);
    }
};

const testing = std.testing;

test "Detector: detects level=fatal/panic via parsed level" {
    var det: Detector = .{ .customs = &.{} };
    try testing.expectEqual(MarkerKind.fatal_level, det.detect("any line", .Fatal).?);
    try testing.expectEqual(MarkerKind.panic_level, det.detect("any line", .Panic).?);
    try testing.expectEqual(@as(?MarkerKind, null), det.detect("hello", .Info));
}

test "Detector: built-in framework markers" {
    var det: Detector = .{ .customs = &.{} };
    try testing.expectEqual(MarkerKind.go_panic, det.detect("panic: runtime error: nil pointer", null).?);
    try testing.expectEqual(
        MarkerKind.python_traceback,
        det.detect("Traceback (most recent call last):", null).?,
    );
    try testing.expectEqual(
        MarkerKind.java_exception,
        det.detect("Exception in thread \"main\" java.lang.NullPointerException", null).?,
    );
}

test "Detector: custom regex" {
    var re = [_]regex.Regex{regex.Regex.compile("oops").?};
    var det: Detector = .{ .customs = &re };
    try testing.expectEqual(MarkerKind.custom_regex, det.detect("uh oops happened", null).?);
    try testing.expectEqual(@as(?MarkerKind, null), det.detect("nothing here", null));
}

test "isTraceLine: continuation patterns" {
    try testing.expect(isTraceLine("\tmain.go:42 +0x1a"));
    try testing.expect(isTraceLine("  at com.example.Foo.bar(Foo.java:10)"));
    try testing.expect(isTraceLine("  File \"app.py\", line 7, in <module>"));
    try testing.expect(isTraceLine("goroutine 1 [running]:"));
    try testing.expect(isTraceLine("[signal SIGSEGV: segmentation violation"));
    try testing.expect(isTraceLine("Caused by: java.io.IOException"));
    try testing.expect(isTraceLine("0xdeadbeef"));
}

test "isTraceLine: rejects new log entries" {
    try testing.expect(!isTraceLine(""));
    try testing.expect(!isTraceLine("2024-01-20T10:00:00Z [INFO] next request"));
    try testing.expect(!isTraceLine("{\"level\":\"info\",\"msg\":\"x\"}"));
    try testing.expect(!isTraceLine("[INFO] something"));
}

test "extractPid: JSON, logfmt, bracketed forms" {
    try testing.expectEqual(@as(?u32, 1234), extractPid("{\"pid\":1234,\"msg\":\"x\"}"));
    try testing.expectEqual(@as(?u32, 42), extractPid("level=error pid=42 msg=oops"));
    try testing.expectEqual(@as(?u32, 99), extractPid("nginx[99]: connection refused"));
    try testing.expectEqual(@as(?u32, null), extractPid("nothing pid-shaped here"));
}

test "StackTraceBuilder: feeds continuation lines, stops on break" {
    var b: StackTraceBuilder = .{};
    b.start(0);
    try testing.expect(b.feed("\tmain.go:1"));
    try testing.expect(b.feed("\tmain.go:2"));
    try testing.expect(!b.feed("normal log line not a trace"));
    try testing.expectEqualStrings("\tmain.go:1\n\tmain.go:2\n", b.slice());
}

test "StackTraceBuilder: tolerates leading blank between panic and trace" {
    var b: StackTraceBuilder = .{};
    b.start(0);
    try testing.expect(b.feed("")); // Go's runtime separator
    try testing.expect(b.feed("goroutine 1 [running]:"));
    try testing.expect(b.feed("\tmain.go:42"));
    try testing.expect(!b.feed("normal next entry"));
    try testing.expect(std.mem.indexOf(u8, b.slice(), "goroutine 1") != null);
    try testing.expect(std.mem.indexOf(u8, b.slice(), "main.go:42") != null);
}

test "StackTraceBuilder: blank AFTER trace started still terminates" {
    var b: StackTraceBuilder = .{};
    b.start(0);
    try testing.expect(b.feed("\tframe1"));
    try testing.expect(!b.feed(""));
}

test "StackTraceBuilder: caps at max_trace_lines" {
    var b: StackTraceBuilder = .{};
    b.start(0);
    var i: usize = 0;
    while (i < @as(usize, max_trace_lines) + 5) : (i += 1) {
        _ = b.feed("\tframe");
    }
    try testing.expect(b.lines == max_trace_lines);
}

test "Tracker: go panic with trace produces crash event on next non-trace line" {
    var det: Detector = .{ .customs = &.{} };
    var t = Tracker.init("api", "/var/log/api.log", 0);

    try testing.expectEqual(@as(?ServiceEvent, null), t.observe("info ok", .Info, &det, 100));
    try testing.expectEqual(@as(?ServiceEvent, null), t.observe("panic: nil pointer dereference", null, &det, 200));
    try testing.expect(t.state == .crash_collecting);

    try testing.expectEqual(@as(?ServiceEvent, null), t.observe("goroutine 1 [running]:", null, &det, 250));
    try testing.expectEqual(@as(?ServiceEvent, null), t.observe("\tmain.main()", null, &det, 260));

    const next = t.observe("2024-01-20T10:00:00Z next log entry", null, &det, 300);
    try testing.expect(next != null);
    try testing.expectEqual(EventKind.crash, next.?.kind);
    try testing.expectEqualStrings("go_panic", next.?.marker);
    try testing.expectEqualStrings("api", next.?.service_name);
    try testing.expect(std.mem.indexOf(u8, next.?.stack_trace, "goroutine 1") != null);
    try testing.expect(std.mem.indexOf(u8, next.?.stack_trace, "main.main") != null);
    try testing.expectEqual(@as(u64, 1), next.?.crash_count);
}

test "Tracker.tick: flushes pending crash after trace_flush_ms" {
    var det: Detector = .{ .customs = &.{} };
    var t = Tracker.init("svc", "x.log", 0);
    _ = t.observe("panic: boom", null, &det, 100);
    try testing.expect(t.state == .crash_collecting);

    try testing.expectEqual(@as(?ServiceEvent, null), t.tick(200, 250, 30_000));
    const ev = t.tick(400, 250, 30_000);
    try testing.expect(ev != null);
    try testing.expectEqual(EventKind.crash, ev.?.kind);
    try testing.expect(t.state == .crash_emitted);
}

test "Tracker.tick: emits stop after silence past stop_window" {
    var det: Detector = .{ .customs = &.{} };
    var t = Tracker.init("svc", "x.log", 0);
    _ = t.observe("panic: boom", null, &det, 100);
    _ = t.tick(400, 250, 30_000); // → crash_emitted; last_log_ms still 100
    try testing.expect(t.state == .crash_emitted);

    // Still within the 30s window (29900ms silent < 30000ms).
    try testing.expectEqual(@as(?ServiceEvent, null), t.tick(30_000, 250, 30_000));

    // 30100ms silent → fires.
    const ev = t.tick(30_100, 250, 30_000);
    try testing.expect(ev != null);
    try testing.expectEqual(EventKind.stop, ev.?.kind);
    try testing.expect(t.state == .stopped);
}

test "Tracker.observeInodeChange: emits restart and resets crash state" {
    var det: Detector = .{ .customs = &.{} };
    var t = Tracker.init("svc", "x.log", 0);
    _ = t.observe("panic: boom", null, &det, 100);

    const ev = t.observeInodeChange(500);
    try testing.expectEqual(EventKind.restart, ev.kind);
    try testing.expectEqual(@as(u64, 1), ev.restart_count);
    try testing.expect(t.state == .running);
    try testing.expect(!t.trace.active);
}
