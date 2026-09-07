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
const signature = @import("signature.zig");

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
    /// Go's runtime *throw* path — `fatal error:`, `runtime: out of memory`,
    /// the `[signal SIG…]` banner. Distinct from a panic: deferred functions
    /// do not run and the process is already gone, so it is strictly worse
    /// news than `go_panic` and worth telling apart downstream.
    go_fatal,
    python_traceback,
    java_exception,
    /// Rust's `thread '…' panicked at …`. The reason is printed on the line
    /// *after* the banner, which is why the trace builder is allowed one
    /// free-form line for this marker.
    rust_panic,
    /// The C/C++/glibc abort family — an uncaught exception reaching
    /// `terminate`, a smashed stack, a double free, or a signal the shell
    /// reported with a core dump. Different runtimes, same meaning: the
    /// process died where it stood.
    native_abort,
    fatal_level,
    panic_level,
    custom_regex,
    systemd_signal,

    pub fn label(self: MarkerKind) []const u8 {
        return switch (self) {
            .go_panic => "go_panic",
            .go_fatal => "go_fatal",
            .python_traceback => "python_traceback",
            .java_exception => "java_exception",
            .rust_panic => "rust_panic",
            .native_abort => "native_abort",
            .fatal_level => "fatal_level",
            .panic_level => "panic_level",
            .custom_regex => "custom_regex",
            .systemd_signal => "systemd_signal",
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
            // A line carrying its own level below Error came out of a
            // logger, so any runtime phrase in it is quoted text rather than
            // a crash. `{"level":"info","msg":"recovered from panic: …"}`
            // used to register as a Go panic.
            //
            // User-supplied patterns are deliberately still honoured: the
            // operator asked for those explicitly.
            if (@intFromEnum(l) < @intFromEnum(flags.Level.Error)) return self.matchCustom(line);
        }
        if (runtimeMarker(line)) |m| return m;
        if (bannerAt(line, "Traceback (most recent call last):")) return .python_traceback;
        if (bannerAt(line, "Exception in thread ")) return .java_exception;
        return self.matchCustom(line);
    }

    fn matchCustom(self: *const Detector, line: []const u8) ?MarkerKind {
        for (self.customs) |*re| {
            if (re.isMatch(line)) return .custom_regex;
        }
        return null;
    }
};

/// Go runtime crash banners.
///
/// `fatal error:` and friends were missing outright, which is the whole
/// unrecoverable family — concurrent map writes, deadlock, stack overflow,
/// out of memory. They are not panics: no deferred function runs and the
/// process is already unwinding in the runtime.
fn runtimeMarker(line: []const u8) ?MarkerKind {
    if (bannerAt(line, "panic: ")) return .go_panic;
    if (bannerAt(line, "fatal error: ")) return .go_fatal;
    if (bannerAt(line, "runtime: out of memory")) return .go_fatal;
    // Printed on the line after `panic:` for a SIGSEGV/SIGBUS. Reached on its
    // own only when the panic line was lost; while a crash is already being
    // collected the tracker feeds this into the trace instead.
    if (bannerAt(line, "[signal SIG")) return .go_fatal;
    if (rustPanic(line)) return .rust_panic;
    if (nativeAbort(line)) return .native_abort;
    return null;
}

/// Rust's panic banner. Both spellings carry `' panicked at `: the current
/// one puts the location on the banner and the reason on the next line,
/// the pre-1.72 one quoted the reason inline.
fn rustPanic(line: []const u8) bool {
    if (!bannerAt(line, "thread '")) return false;
    return std.mem.indexOf(u8, line, "' panicked at ") != null;
}

/// Abort banners from the C/C++ runtimes and from the shell that reaped the
/// process. Each one is a fixed phrase no application prints by accident;
/// the bare signal names are deliberately not here, because "segmentation
/// fault" shows up in prose and only the `(core dumped)` suffix makes it a
/// report of something that actually happened.
fn nativeAbort(line: []const u8) bool {
    const banners = [_][]const u8{
        "terminate called ",
        "*** stack smashing detected ***",
        "double free or corruption",
        "free(): invalid pointer",
        "malloc(): corrupted top size",
        "Segmentation fault (core dumped)",
        "Aborted (core dumped)",
    };
    for (banners) |b| {
        if (bannerAt(line, b)) return true;
    }
    return false;
}

/// True when `banner` starts the line, or starts the message portion of a
/// captured line whose envelope ends in `:`, `]` or `|`.
///
/// The Go runtime writes its banner straight to stderr with no logger
/// prefix, so in raw output it sits at column 0; a capture layer may put
/// `unit[123]: ` or `2026-08-26T10:00:00Z |` in front of it. What can never
/// precede it is an English word or a quote — and matching those is how
/// `GET /api/panic:status`, `"panic:0 restarts:0"` and `no panic: all good`
/// all used to be reported as crashes.
fn bannerAt(line: []const u8, banner: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, line, i, banner)) |hit| {
        if (hit == 0) return true;
        // Walk back over the separating whitespace.
        var j = hit;
        while (j > 0 and (line[j - 1] == ' ' or line[j - 1] == '\t')) j -= 1;
        if (j == 0) return true; // only indentation before it
        // The delimiter counts whether or not a space follows it. Requiring
        // one missed every capture layer that writes `…Z|panic: boom` or
        // `unit[7]:panic: boom` without padding, and gained nothing: the
        // false positives this guards against — `/api/panic: x`, `"panic: 0`
        // — are rejected by the delimiter set itself, not by the spacing.
        const last = line[j - 1];
        if (last == ':' or last == ']' or last == '|') return true;
        i = hit + 1;
    }
    return false;
}

/// Inline stack-trace builder. Appends lines until the continuation
/// heuristic breaks or the byte/line cap is reached.
pub const StackTraceBuilder = struct {
    buf: [max_trace_bytes]u8 = undefined,
    used: usize = 0,
    lines: u8 = 0,
    active: bool = false,
    started_at_ms: i64 = 0,
    /// Accept one arbitrary line as the first entry of the trace. Rust puts
    /// the panic reason on the line after the banner, flush-left, so the
    /// continuation heuristic would end the trace before capturing the one
    /// line that says what actually went wrong.
    free_first: bool = false,
    /// Apply Go's own trace grammar on top of the generic indentation
    /// heuristic. Set from the marker when the detector already knows it is a
    /// Go panic, and latched on the way past `[signal ...]` or `goroutine N`
    /// so a crash found by a custom `--crash-marker` gets it too.
    ///
    /// The generic heuristic is indentation-based, and a Go trace is the one
    /// that does not indent: `goroutine 1 [running]:` is followed by
    /// alternating flush-left symbols and tab-indented file positions, with
    /// blank lines between goroutine blocks. Reading it as "indented means
    /// continuation" captures every other line at best, so Go gets rules
    /// of its own — scoped to a trace already in progress, where an ordinary
    /// log line cannot appear.
    go_mode: bool = false,

    pub fn start(self: *StackTraceBuilder, now_ms: i64) void {
        self.used = 0;
        self.lines = 0;
        self.active = true;
        self.started_at_ms = now_ms;
        self.free_first = false;
        self.go_mode = false;
    }

    pub fn reset(self: *StackTraceBuilder) void {
        self.used = 0;
        self.lines = 0;
        self.active = false;
        self.free_first = false;
        self.go_mode = false;
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

        // Anything that names the Go runtime puts the builder into Go mode
        // for the rest of this trace, including a crash first spotted by a
        // custom marker.
        if (opensGoTrace(line)) self.go_mode = true;

        // A blank line separates `panic:` from the goroutine dump and one
        // goroutine block from the next. In Go it is punctuation, so it is
        // stepped over rather than appended or treated as the end.
        //
        // Outside Go mode a blank still ends the trace: the indentation
        // heuristic has no way to tell a separator from the gap before an
        // unrelated indented block, and Java and Python do not put blanks in
        // the middle of a trace anyway.
        if (line.len == 0) {
            if (self.go_mode or self.used == 0) return true;
            self.active = false;
            return false;
        }

        const accepted = isTraceLine(line) or
            (self.go_mode and isGoFrame(line)) or
            (self.free_first and self.used == 0);
        if (!accepted) {
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
    // Rust prints these flush-left under a panic.
    if (std.mem.startsWith(u8, line, "note: ")) return true;
    if (std.mem.startsWith(u8, line, "stack backtrace:")) return true;
    return false;
}

/// True for the two lines that identify a dump as Go's. Either one is enough
/// to switch on the grammar below, and both are specific enough that an
/// ordinary log line does not trip them.
pub fn opensGoTrace(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "goroutine ") or
        std.mem.startsWith(u8, line, "[signal ");
}

/// True for a flush-left Go stack frame.
///
/// Go writes a frame as a symbol immediately followed by its arguments and
/// nothing else — `main.main()`, `main.(*Server).handle(0x0, {0x14000112000,
/// 0x1f})`, `github.com/x/y.(*Pool).Get(0x14000a2000)`. The shape that
/// separates those from a log line is narrow: the text before the first `(`
/// is a dotted path with no whitespace in it, and the line ends on the
/// closing paren.
///
/// `2026-09-06 10:44:05 INFO handled request (took 3ms)` ends in `)` too, but
/// everything before its `(` is prose full of spaces, so it is not a frame —
/// and this is only ever consulted once a Go trace is already open.
pub fn isGoFrame(line: []const u8) bool {
    // Go 1.21+ attributes a goroutine to whatever started it. Flush-left,
    // and not a call, so it needs saying separately.
    if (std.mem.startsWith(u8, line, "created by ")) return true;

    if (line.len < 3 or line[line.len - 1] != ')') return false;
    const open = std.mem.indexOfScalar(u8, line, '(') orelse return false;
    const symbol = line[0..open];
    if (symbol.len == 0) return false;

    var dotted = false;
    for (symbol) |c| {
        if (c == ' ' or c == '\t') return false;
        if (c == '.') dotted = true;
    }
    return dotted;
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

/// Source backing the tracker. The mode controls which lifecycle events the
/// tracker emits — file-backed services surface stop/restart, while journal
/// sources only surface crash signals (systemd already manages lifecycle and
/// the user wants those treated as noise).
pub const Mode = enum {
    file,
    journal,
};

/// Per-service tracker. One Tracker per `--service` binding; held inside the
/// watcher's FileState.
pub const Tracker = struct {
    name: []const u8,
    path: []const u8,
    mode: Mode = .file,
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
            .mode = .file,
            .last_log_ms = now_ms,
        };
    }

    /// Constructs a tracker for a journal-backed source. Lifecycle signals
    /// (stop, restart) are not emitted in this mode — those are systemd's
    /// concern and we deliberately leave them as noise.
    pub fn initJournal(name: []const u8, path: []const u8, now_ms: i64) Tracker {
        return .{
            .name = name,
            .path = path,
            .mode = .journal,
            .last_log_ms = now_ms,
        };
    }

    /// Adopts the counters a previous run left behind.
    ///
    /// Without this the numbers in an alert describe the current process
    /// rather than the service: an operator reading "crashes: 1" after a
    /// third crash overnight has been told something false, and the agent
    /// restarting — which is exactly what happens when the box it watches
    /// reboots — is what resets them.
    pub fn seed(self: *Tracker, crash_count: u64, restart_count: u64) void {
        self.crash_count = crash_count;
        self.restart_count = restart_count;
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
                // Journal-mode trackers never emit stop — systemd already
                // tracks unit liveness; surfacing it again is just noise.
                if (self.mode == .journal) return null;
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
        self.trace.free_first = marker == .rust_panic;
        self.trace.go_mode = marker == .go_panic;
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

test "bannerAt accepts an envelope delimiter with no trailing space" {
    // Capture layers that pad their delimiter were already handled; these
    // are the same envelopes written tight, which used to be missed.
    try testing.expect(bannerAt("2026-08-26T10:00:00Z|panic: boom", "panic: "));
    try testing.expect(bannerAt("unit[7]:panic: boom", "panic: "));
    try testing.expect(bannerAt("unit[7]: panic: boom", "panic: "));

    // The delimiter set is still what rejects prose, so these stay negative.
    try testing.expect(!bannerAt("GET /api/panic: status", "panic: "));
    try testing.expect(!bannerAt("no panic: all good", "panic: "));
    try testing.expect(!bannerAt("\"panic: 0 restarts: 0\"", "panic: "));
}

test "detect recognises Rust panics in both spellings" {
    const d = Detector{ .customs = &.{} };
    // Current form: location on the banner, reason on the next line.
    try testing.expectEqual(MarkerKind.rust_panic, d.detect("thread 'main' panicked at src/main.rs:4:5:", null).?);
    // Pre-1.72 form: reason quoted inline.
    try testing.expectEqual(
        MarkerKind.rust_panic,
        d.detect("thread 'tokio-worker-1' panicked at 'index out of bounds', src/lib.rs:9:1", null).?,
    );
    // Behind a capture envelope.
    try testing.expectEqual(
        MarkerKind.rust_panic,
        d.detect("api[912]: thread 'main' panicked at src/main.rs:4:5:", null).?,
    );
    // Prose about panicking is not a panic.
    try testing.expectEqual(@as(?MarkerKind, null), d.detect("worker thread 'main' panicked earlier, recovered", null));
}

test "detect recognises the native abort family" {
    const d = Detector{ .customs = &.{} };
    for ([_][]const u8{
        "terminate called after throwing an instance of 'std::runtime_error'",
        "*** stack smashing detected ***: terminated",
        "double free or corruption (out)",
        "Segmentation fault (core dumped)",
        "Aborted (core dumped)",
    }) |line| {
        try testing.expectEqual(MarkerKind.native_abort, d.detect(line, null).?);
    }

    // A bare signal name in prose is not a report that anything died.
    try testing.expectEqual(@as(?MarkerKind, null), d.detect("guarding against Segmentation fault in the parser", null));
}

test "a Rust panic captures the reason printed under it" {
    var b = StackTraceBuilder{};
    b.start(0);
    b.free_first = true;

    try testing.expect(b.feed("index out of bounds: the len is 3 but the index is 7"));
    try testing.expect(b.feed("note: run with `RUST_BACKTRACE=1` to display a backtrace"));
    try testing.expect(b.feed("stack backtrace:"));
    try testing.expect(b.feed("   0: rust_begin_unwind"));
    // Back to the ordinary heuristic once the trace is under way.
    try testing.expect(!b.feed("2026-08-26 10:00:01 INF next request"));

    try testing.expect(std.mem.indexOf(u8, b.slice(), "index out of bounds") != null);
    try testing.expect(std.mem.indexOf(u8, b.slice(), "rust_begin_unwind") != null);
}

test "the free-form allowance applies to the first line only" {
    var b = StackTraceBuilder{};
    b.start(0);
    b.free_first = true;

    try testing.expect(b.feed("the reason"));
    // Second unindented line is an ordinary log line again.
    try testing.expect(!b.feed("unrelated log line"));
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

test "Tracker (journal mode): tick never emits stop after crash" {
    var det: Detector = .{ .customs = &.{} };
    var t = Tracker.initJournal("api", "myapp.service", 0);
    _ = t.observe("panic: boom", null, &det, 100);
    _ = t.tick(400, 250, 30_000); // flush crash collection
    try testing.expect(t.state == .crash_emitted);

    // Even far past the silence window, journal mode stays silent on stop.
    try testing.expectEqual(@as(?ServiceEvent, null), t.tick(120_000, 250, 30_000));
    try testing.expect(t.state == .crash_emitted);
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

// ─── Go crash-banner accuracy ─────────────────────────────────────────────
//
// Measured against this corpus before the rewrite: precision 69%, recall
// 55%. The whole `fatal error:` family was missing, and `panic:` matched
// anywhere in the line, so log messages *quoting* a panic registered as
// crashes.

const GoCase = struct {
    line: []const u8,
    crash: bool,
    marker: ?MarkerKind = null,
};

const go_corpus = [_]GoCase{
    // Runtime panic banner.
    .{ .line = "panic: runtime error: index out of range [5] with length 3", .crash = true, .marker = .go_panic },
    .{ .line = "panic: runtime error: invalid memory address or nil pointer dereference", .crash = true, .marker = .go_panic },
    .{ .line = "panic: assignment to entry in nil map", .crash = true, .marker = .go_panic },
    .{ .line = "panic: close of closed channel", .crash = true, .marker = .go_panic },
    .{ .line = "panic: interface conversion: interface {} is string, not int", .crash = true, .marker = .go_panic },
    .{ .line = "panic: send on closed channel [recovered]", .crash = true, .marker = .go_panic },
    .{ .line = "panic: test timed out after 10m0s", .crash = true, .marker = .go_panic },

    // Runtime throw: unrecoverable, no deferred functions run.
    .{ .line = "fatal error: concurrent map writes", .crash = true, .marker = .go_fatal },
    .{ .line = "fatal error: all goroutines are asleep - deadlock!", .crash = true, .marker = .go_fatal },
    .{ .line = "fatal error: out of memory", .crash = true, .marker = .go_fatal },
    .{ .line = "fatal error: stack overflow", .crash = true, .marker = .go_fatal },
    .{ .line = "fatal error: unexpected signal during runtime execution", .crash = true, .marker = .go_fatal },
    .{ .line = "runtime: out of memory: cannot allocate 8192-byte block", .crash = true, .marker = .go_fatal },
    .{ .line = "[signal SIGSEGV: segmentation violation code=0x1 addr=0x0 pc=0x45a1c2]", .crash = true, .marker = .go_fatal },

    // Captured through a log envelope rather than raw stderr.
    .{ .line = "Aug 26 10:00:00 host api[1234]: panic: runtime error: nil map", .crash = true, .marker = .go_panic },
    .{ .line = "2026-08-26T10:00:00Z | fatal error: concurrent map read and map write", .crash = true, .marker = .go_fatal },
    .{ .line = "  panic: leading indentation", .crash = true, .marker = .go_panic },

    // Go loggers carrying the level themselves.
    .{ .line = "{\"level\":\"fatal\",\"msg\":\"cannot bind port\"}", .crash = true, .marker = .fatal_level },
    .{ .line = "{\"level\":\"panic\",\"msg\":\"invariant broken\"}", .crash = true, .marker = .panic_level },
    .{ .line = "{\"level\":\"dpanic\",\"msg\":\"dev invariant\"}", .crash = true, .marker = .panic_level },
    .{ .line = "level=fatal msg=\"migrations failed\"", .crash = true, .marker = .fatal_level },
    .{ .line = "time=2026-08-26T10:00:00Z level=panic msg=\"bad state\"", .crash = true, .marker = .panic_level },
    .{ .line = "2026-08-26 10:00:00 FTL shutting down", .crash = true, .marker = .fatal_level },

    // Quoting a crash is not crashing.
    .{ .line = "{\"level\":\"info\",\"msg\":\"recovered from panic: retrying request\"}", .crash = false },
    .{ .line = "level=debug msg=\"panic: handler installed\"", .crash = false },
    .{ .line = "2026-08-26 10:00:00 INF no panic: all good", .crash = false },
    .{ .line = "{\"level\":\"warn\",\"msg\":\"panic:0 restarts:0\"}", .crash = false },
    .{ .line = "{\"level\":\"info\",\"msg\":\"fatal error: none seen this hour\"}", .crash = false },
    .{ .line = "{\"level\":\"error\",\"msg\":\"upstream 503\"}", .crash = false },

    // The words in ordinary text, paths and metric names.
    .{ .line = "GET /api/panic:status 200 4ms", .crash = false },
    .{ .line = "POST /v1/fatal error: ignored", .crash = false },
    .{ .line = "2026-08-26 10:00:00 user hit the panic button in the UI", .crash = false },
    .{ .line = "2026-08-26 10:00:00 shipping fatal error handling to prod", .crash = false },
    .{ .line = "deploy: rolled back after fatal error: see incident 42", .crash = false },
    .{ .line = "{\"msg\":\"panic budget remaining: 3\"}", .crash = false },
    .{ .line = "chan_panic_total 0", .crash = false },

    // Stack frames on their own carry no verdict.
    .{ .line = "goroutine 1 [running]:", .crash = false },
    .{ .line = "main.main()", .crash = false },
};

test "Detector: Go crash corpus has no false positives or negatives" {
    const det: Detector = .{ .customs = &.{} };
    var wrong: usize = 0;
    for (go_corpus) |c| {
        const got = det.detect(c.line, signature.extractLevel(c.line));
        if ((got != null) != c.crash) {
            wrong += 1;
            std.debug.print("misjudged: {s}\n  expected crash={}, got {?}\n", .{ c.line, c.crash, got });
        }
    }
    try testing.expectEqual(@as(usize, 0), wrong);
}

test "Detector: Go crash corpus attributes the right marker" {
    const det: Detector = .{ .customs = &.{} };
    for (go_corpus) |c| {
        const want = c.marker orelse continue;
        const got = det.detect(c.line, signature.extractLevel(c.line));
        try testing.expectEqual(want, got.?);
    }
}

test "Detector: a runtime banner needs a line or envelope boundary before it" {
    const det: Detector = .{ .customs = &.{} };
    // Boundaries the Go runtime or a capture layer can produce.
    for ([_][]const u8{
        "panic: x",
        "\tpanic: x",
        "svc[9]: panic: x",
        "2026-08-26T00:00:00Z | panic: x",
    }) |line| {
        try testing.expectEqual(MarkerKind.go_panic, det.detect(line, null).?);
    }
    // Anything else means the phrase is embedded in text.
    for ([_][]const u8{
        "recovered from panic: x",
        "\"panic: x\"",
        "/api/panic: x",
        "nopanic: x",
    }) |line| {
        try testing.expect(det.detect(line, null) == null);
    }
}

test "Detector: user regexes still fire on a low-severity line" {
    // The level gate suppresses *built-in* markers on an info line; a
    // pattern the operator asked for explicitly must still match.
    const re = regex.Regex.compile("shard-[0-9]+ lost").?;
    var customs = [_]regex.Regex{re};
    var det: Detector = .{ .customs = &customs };
    defer customs[0].deinit();

    try testing.expectEqual(
        MarkerKind.custom_regex,
        det.detect("{\"level\":\"info\",\"msg\":\"shard-7 lost\"}", .Info).?,
    );
}

test "isGoFrame: accepts real frames, rejects prose that happens to end in )" {
    // The shapes Go actually emits.
    try testing.expect(isGoFrame("main.main()"));
    try testing.expect(isGoFrame("main.(*Server).handle(0x0, {0x14000112000, 0x1f})"));
    try testing.expect(isGoFrame("runtime.gopanic(0x14000064000)"));
    try testing.expect(isGoFrame("github.com/x/y.(*Pool).Get(0x14000a2000, 0x1)"));
    try testing.expect(isGoFrame("created by main.startWorker in goroutine 1"));

    // A log line ending in a parenthesis is the case this has to survive:
    // everything before the `(` is prose, and prose has spaces in it.
    try testing.expect(!isGoFrame("2026-09-06 10:44:05 INFO handled request (took 3ms)"));
    try testing.expect(!isGoFrame("done (ok)"));
    // No dot, so not a qualified symbol.
    try testing.expect(!isGoFrame("main()"));
    // Not a call at all.
    try testing.expect(!isGoFrame("exit status 2"));
    try testing.expect(!isGoFrame("{\"level\":\"info\",\"message\":\"done\"}"));
    try testing.expect(!isGoFrame(""));
}

test "StackTraceBuilder: a Go dump survives its blank lines and flush-left frames" {
    var b: StackTraceBuilder = .{};
    b.start(0);
    b.go_mode = true;

    // Exactly what the runtime prints for a nil-pointer dereference.
    try testing.expect(b.feed("[signal SIGSEGV: segmentation violation code=0x1 addr=0x0 pc=0x10a2f]"));
    try testing.expect(b.feed(""));
    try testing.expect(b.feed("goroutine 1 [running]:"));
    try testing.expect(b.feed("main.(*Server).handle(0x0, {0x14000112000, 0x1f})"));
    try testing.expect(b.feed("\t/src/api/server.go:142 +0x24"));
    try testing.expect(b.feed("main.main()"));
    try testing.expect(b.feed("\t/src/api/main.go:31 +0x88"));
    // A second goroutine block, separated by a blank.
    try testing.expect(b.feed(""));
    try testing.expect(b.feed("goroutine 18 [select]:"));
    try testing.expect(b.feed("created by main.startWorker in goroutine 1"));
    // And an ordinary log line still ends it.
    try testing.expect(!b.feed("{\"level\":\"info\",\"message\":\"restarted\"}"));

    const trace = b.slice();
    try testing.expect(std.mem.indexOf(u8, trace, "goroutine 1 [running]:") != null);
    try testing.expect(std.mem.indexOf(u8, trace, "main.(*Server).handle") != null);
    try testing.expect(std.mem.indexOf(u8, trace, "/src/api/server.go:142") != null);
    try testing.expect(std.mem.indexOf(u8, trace, "goroutine 18 [select]:") != null);
    try testing.expect(std.mem.indexOf(u8, trace, "created by main.startWorker") != null);
    // Separators are stepped over, not stored.
    try testing.expect(std.mem.indexOf(u8, trace, "\n\n") == null);
}

test "StackTraceBuilder: [signal ...] switches on Go mode by itself" {
    // A crash found through a custom `--crash-marker` never tells the builder
    // which runtime it is looking at, so the dump has to say so.
    var b: StackTraceBuilder = .{};
    b.start(0);
    try testing.expect(!b.go_mode);
    try testing.expect(b.feed("[signal SIGSEGV: segmentation violation code=0x1 addr=0x0]"));
    try testing.expect(b.go_mode);
    try testing.expect(b.feed(""));
    try testing.expect(b.feed("goroutine 1 [running]:"));
    try testing.expect(std.mem.indexOf(u8, b.slice(), "goroutine 1") != null);
}

test "StackTraceBuilder: Go's grammar stays inside a Go trace" {
    // The same flush-left shape under a Java trace must not extend it — the
    // frame rule is only safe because a trace is already open and known to
    // be Go's.
    var b: StackTraceBuilder = .{};
    b.start(0);
    try testing.expect(b.feed("\tat com.example.Service.handle(Service.java:42)"));
    try testing.expect(!b.feed("com.example.Other.call(0x1)"));
}

test "Tracker: a Go panic keeps its frames end to end" {
    const detector = Detector{ .customs = &.{} };
    var t = Tracker.init("api", "/var/log/api.log", 0);

    try testing.expect(t.observe("panic: runtime error: invalid memory address or nil pointer dereference", null, &detector, 100) == null);
    try testing.expect(t.observe("[signal SIGSEGV: segmentation violation code=0x1 addr=0x0 pc=0x10a2f]", null, &detector, 101) == null);
    try testing.expect(t.observe("", null, &detector, 102) == null);
    try testing.expect(t.observe("goroutine 1 [running]:", null, &detector, 103) == null);
    try testing.expect(t.observe("main.(*Server).handle(0x0, {0x14000112000, 0x1f})", null, &detector, 104) == null);
    try testing.expect(t.observe("\t/src/api/server.go:142 +0x24", null, &detector, 105) == null);
    try testing.expect(t.observe("main.main()", null, &detector, 106) == null);
    try testing.expect(t.observe("\t/src/api/main.go:31 +0x88", null, &detector, 107) == null);

    const ev = t.observe("{\"level\":\"info\",\"message\":\"back up\"}", .Info, &detector, 200).?;
    try testing.expectEqual(EventKind.crash, ev.kind);
    try testing.expectEqualStrings("go_panic", ev.marker);
    try testing.expect(std.mem.indexOf(u8, ev.detail, "nil pointer dereference") != null);

    // Every frame, not just the signal line the old heuristic stopped at.
    for ([_][]const u8{
        "goroutine 1 [running]:",
        "main.(*Server).handle",
        "/src/api/server.go:142",
        "main.main()",
        "/src/api/main.go:31",
    }) |want| {
        try testing.expect(std.mem.indexOf(u8, ev.stack_trace, want) != null);
    }
}
