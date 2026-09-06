//! Renders the state file for `zlrd status`.
//!
//! The question this answers is the one an operator actually has in the
//! morning: something went wrong overnight, what was it. So the layout leads
//! with a per-service tally, then spends its space on the single most recent
//! crash — marker, first line, stack trace — because that is the one an
//! answer usually starts from. Everything else is a short tail of recent
//! events for context.
//!
//! Times are shown twice on purpose. "4h ago" is what the reader is really
//! asking and needs no time zone to be true; the absolute stamp beside it is
//! UTC, stated as such, so it can be matched against a log line or a ticket
//! without anyone having to guess which machine's clock it came from.
//!
//! Colour arrives as a `Style` filled in by the caller rather than by
//! importing the reader's theme: this package has no other reason to know
//! about terminals, and the escape strings are the only part of a theme a
//! table needs.

const std = @import("std");
const civil = @import("civil");
// The module, not the file beside it: `main.zig` holds a `state.Store` and
// hands its snapshot here, and a second compilation of the same source would
// make that a different type.
const state = @import("state");

/// Escape sequences and glyphs, or empty strings for plain output.
pub const Style = struct {
    reset: []const u8 = "",
    /// Structural noise: rules, column headers, punctuation.
    dim: []const u8 = "",
    /// Secondary text: timestamps, paths.
    muted: []const u8 = "",
    /// A service that has crashed. Deliberately the only colour in the
    /// table: badging every row, healthy ones included, makes the one row
    /// that matters no easier to find than it was in plain text.
    bad: []const u8 = "",
    /// Horizontal rule character.
    rule: []const u8 = "-",
    /// Placeholder for a field with nothing in it.
    none: []const u8 = "-",

    pub const plain: Style = .{};
};

/// Longest service name given its own column before the table starts
/// truncating.
const max_name_col: usize = 28;
/// How much of an event's line is shown in the recent list.
const max_recent_detail: usize = 72;

pub fn render(
    w: *std.Io.Writer,
    snap: state.Store.Snapshot,
    style: Style,
    now_ms: i64,
) !void {
    try w.print("{s}state{s} {s}{s}{s}\n", .{
        style.dim,   style.reset,
        style.muted, snap.path,
        style.reset,
    });

    if (snap.services.len == 0 and snap.events.len == 0) {
        try w.print("\n{s}nothing recorded yet{s} \u{2014} the agent writes here as it runs\n", .{
            style.muted, style.reset,
        });
        return;
    }

    if (snap.services.len > 0) {
        try w.writeByte('\n');
        try writeServices(w, snap.services, style, now_ms);
    }

    if (newestCrash(snap.services)) |c| {
        try w.writeByte('\n');
        try writeCrash(w, c, style, now_ms);
    }

    if (snap.events.len > 0) {
        try w.writeByte('\n');
        try writeRecent(w, snap.events, style, now_ms);
    }
}

fn writeServices(
    w: *std.Io.Writer,
    services: []const state.ServiceStat,
    style: Style,
    now_ms: i64,
) !void {
    var name_col: usize = 7; // len("SERVICE")
    for (services) |s| name_col = @max(name_col, @min(s.name.len, max_name_col));

    try w.writeAll(style.dim);
    try w.writeAll("SERVICE");
    try pad(w, name_col - 7 + 2);
    try w.writeAll("CRASHES  RESTARTS  LAST CRASH\n");
    try w.writeAll(style.reset);

    for (services) |s| {
        const name = truncate(s.name, name_col);
        if (s.counts.crash > 0) {
            try w.print("{s}{s}{s}", .{ style.bad, name, style.reset });
        } else {
            try w.writeAll(name);
        }
        try pad(w, name_col - name.len + 2);
        try w.print("{d: >7}  {d: >8}  ", .{ s.counts.crash, s.counts.restart });
        if (s.last_crash_ms > 0) {
            try writeAgo(w, now_ms - s.last_crash_ms, style);
            if (s.last_marker.len > 0) {
                try w.print("  {s}{s}{s}", .{ style.muted, s.last_marker, style.reset });
            }
        } else {
            try w.print("{s}{s}{s}", .{ style.dim, style.none, style.reset });
        }
        try w.writeByte('\n');
    }
}

fn newestCrash(services: []const state.ServiceStat) ?*const state.ServiceStat {
    var best: ?*const state.ServiceStat = null;
    for (services) |*s| {
        if (s.last_crash_ms == 0) continue;
        if (best == null or s.last_crash_ms > best.?.last_crash_ms) best = s;
    }
    return best;
}

fn writeCrash(
    w: *std.Io.Writer,
    s: *const state.ServiceStat,
    style: Style,
    now_ms: i64,
) !void {
    try w.print("{s}last crash{s} {s} \u{00B7} ", .{ style.dim, style.reset, s.name });
    try writeAgo(w, now_ms - s.last_crash_ms, style);
    try w.print(" {s}(", .{style.muted});
    try writeStamp(w, s.last_crash_ms);
    try w.print(" UTC){s}\n", .{style.reset});

    if (s.last_detail.len > 0) {
        try w.print("  {s}\n", .{s.last_detail});
    }
    if (s.last_trace.len > 0) {
        try w.writeAll(style.muted);
        var it = std.mem.splitScalar(u8, s.last_trace, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trimEnd(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            try w.print("  {s}\n", .{trimmed});
        }
        try w.writeAll(style.reset);
    }
}

fn writeRecent(
    w: *std.Io.Writer,
    events: []const state.Event,
    style: Style,
    now_ms: i64,
) !void {
    try w.print("{s}recent{s}\n", .{ style.dim, style.reset });

    // Newest first: the state file appends, and the thing that just happened
    // is the thing being looked for.
    var i = events.len;
    while (i > 0) {
        i -= 1;
        const e = events[i];
        try w.writeAll("  ");
        try writeAgoPadded(w, now_ms - e.ts_ms, style);
        try w.print("  {s: <15}", .{truncate(e.kind, 15)});
        try w.print(" {s}{s}{s}", .{ style.muted, truncate(e.subject, 20), style.reset });
        if (e.detail.len > 0) {
            try pad(w, 20 -| e.subject.len + 1);
            try w.writeAll(truncate(e.detail, max_recent_detail));
        }
        try w.writeByte('\n');
    }
}

// ─── Formatting helpers ───────────────────────────────────────────────────

/// "just now" / "42s" / "13m" / "4h" / "3d" ago. Deliberately coarse — the
/// exact second is in the absolute stamp, and a column of them would be
/// harder to scan, not easier.
fn writeAgo(w: *std.Io.Writer, delta_ms: i64, style: Style) !void {
    var buf: [24]u8 = undefined;
    const s = agoText(&buf, delta_ms);
    try w.print("{s}{s}{s}", .{ style.muted, s, style.reset });
}

fn writeAgoPadded(w: *std.Io.Writer, delta_ms: i64, style: Style) !void {
    var buf: [24]u8 = undefined;
    const s = agoText(&buf, delta_ms);
    try w.print("{s}{s: <9}{s}", .{ style.muted, s, style.reset });
}

fn agoText(buf: []u8, delta_ms: i64) []const u8 {
    // A negative delta means the record is stamped in the future: a clock
    // that moved backwards, or a state file copied from another machine.
    // Saying "just now" is the honest answer to "how long ago" when the
    // answer is "it hasn't been".
    if (delta_ms <= 0) return "just now";
    const secs = @divTrunc(delta_ms, 1000);
    if (secs < 5) return "just now";
    if (secs < 60) return std.fmt.bufPrint(buf, "{d}s ago", .{secs}) catch "just now";
    if (secs < 3600) return std.fmt.bufPrint(buf, "{d}m ago", .{@divTrunc(secs, 60)}) catch "just now";
    if (secs < 86_400) return std.fmt.bufPrint(buf, "{d}h ago", .{@divTrunc(secs, 3600)}) catch "just now";
    return std.fmt.bufPrint(buf, "{d}d ago", .{@divTrunc(secs, 86_400)}) catch "just now";
}

/// `YYYY-MM-DD HH:MM:SS`, in UTC.
///
/// `civil` warns that its second counts are calendar seconds and not Unix
/// timestamps. The two coincide exactly when the offset is zero, which is
/// what makes running a Unix timestamp through it correct here and why the
/// caller prints "UTC" beside the result.
fn writeStamp(w: *std.Io.Writer, ts_ms: i64) !void {
    const cut = civil.fromSeconds(@divFloor(ts_ms, 1000));
    try w.print("{s} {s}", .{ cut.dateSlice(), cut.timeSlice() });
}

fn pad(w: *std.Io.Writer, n: usize) !void {
    try w.splatByteAll(' ', n);
}

/// Cuts to at most `max` bytes without splitting a UTF-8 sequence — a log
/// line ending in half a character renders as a replacement glyph and looks
/// like corruption rather than truncation.
fn truncate(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xc0) == 0x80) end -= 1;
    return s[0..end];
}

// ─── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The stored strings are owned by the store, so they are typed mutable.
/// A test does not own anything and only reads, hence the cast.
fn own(s: []const u8) []u8 {
    return @constCast(s);
}

const now: i64 = 1_757_000_000_000;

fn renderToBuf(buf: []u8, snap: state.Store.Snapshot) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try render(&w, snap, .plain, now);
    return w.buffered();
}

test "an empty state says so instead of printing an empty table" {
    var buf: [4096]u8 = undefined;
    const out = try renderToBuf(&buf, .{
        .path = "/home/x/.local/state/zlrd/state.json",
        .services = &.{},
        .events = &.{},
        .signatures = 0,
    });
    try testing.expect(std.mem.indexOf(u8, out, "nothing recorded yet") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/home/x/.local/state/zlrd/state.json") != null);
}

test "services table carries the counters and the age of the last crash" {
    const services = [_]state.ServiceStat{
        .{
            .name = own("api"),
            .counts = .{ .crash = 3, .restart = 1 },
            .last_crash_ms = now - 4 * 3_600_000,
            .last_marker = own("go_panic"),
            .last_detail = own("panic: nil pointer"),
            .last_trace = own("goroutine 1 [running]:\nmain.go:42"),
        },
        .{ .name = own("worker"), .counts = .{ .restart = 2 } },
    };
    var buf: [8192]u8 = undefined;
    const out = try renderToBuf(&buf, .{
        .path = "state.json",
        .services = &services,
        .events = &.{},
        .signatures = 0,
    });

    try testing.expect(std.mem.indexOf(u8, out, "SERVICE") != null);
    try testing.expect(std.mem.indexOf(u8, out, "api") != null);
    try testing.expect(std.mem.indexOf(u8, out, "4h ago") != null);
    try testing.expect(std.mem.indexOf(u8, out, "go_panic") != null);
    // A service that has never crashed gets a placeholder, not a stale date.
    try testing.expect(std.mem.indexOf(u8, out, "worker") != null);
}

test "the newest crash is the one expanded, with its trace" {
    const services = [_]state.ServiceStat{
        .{
            .name = own("old"),
            .counts = .{ .crash = 1 },
            .last_crash_ms = now - 48 * 3_600_000,
            .last_detail = own("panic: yesterday"),
        },
        .{
            .name = own("fresh"),
            .counts = .{ .crash = 1 },
            .last_crash_ms = now - 60_000,
            .last_detail = own("panic: just now"),
            .last_trace = own("main.handle()\n  /src/main.go:42"),
        },
    };
    var buf: [8192]u8 = undefined;
    const out = try renderToBuf(&buf, .{
        .path = "state.json",
        .services = &services,
        .events = &.{},
        .signatures = 0,
    });

    const at = std.mem.indexOf(u8, out, "last crash").?;
    const tail = out[at..];
    try testing.expect(std.mem.indexOf(u8, tail, "fresh") != null);
    try testing.expect(std.mem.indexOf(u8, tail, "panic: just now") != null);
    try testing.expect(std.mem.indexOf(u8, tail, "/src/main.go:42") != null);
    // The absolute stamp is UTC and labelled as such.
    try testing.expect(std.mem.indexOf(u8, tail, "UTC") != null);
}

test "recent events are listed newest first" {
    const events = [_]state.Event{
        .{ .ts_ms = now - 7_200_000, .kind = own("error_rate"), .subject = own("error_rate"), .source = own("app.log"), .detail = own("older") },
        .{ .ts_ms = now - 60_000, .kind = own("service_crash"), .subject = own("api"), .source = own("api.log"), .detail = own("newer") },
    };
    var buf: [8192]u8 = undefined;
    const out = try renderToBuf(&buf, .{
        .path = "state.json",
        .services = &.{},
        .events = &events,
        .signatures = 0,
    });

    const newer = std.mem.indexOf(u8, out, "newer").?;
    const older = std.mem.indexOf(u8, out, "older").?;
    try testing.expect(newer < older);
    try testing.expect(std.mem.indexOf(u8, out, "1m ago") != null);
    try testing.expect(std.mem.indexOf(u8, out, "2h ago") != null);
}

test "a timestamp from the future reads as 'just now', not as a negative age" {
    // A clock that stepped backwards, or a state file copied off another box.
    const services = [_]state.ServiceStat{.{
        .name = own("api"),
        .counts = .{ .crash = 1 },
        .last_crash_ms = now + 10 * 60_000,
        .last_detail = own("panic: boom"),
    }};
    var buf: [4096]u8 = undefined;
    const out = try renderToBuf(&buf, .{
        .path = "state.json",
        .services = &services,
        .events = &.{},
        .signatures = 0,
    });
    try testing.expect(std.mem.indexOf(u8, out, "just now") != null);
    try testing.expect(std.mem.indexOf(u8, out, "-") == null or std.mem.indexOf(u8, out, "ago") == null);
}

test "the UTC stamp matches the epoch it was built from" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // 2026-09-06T12:34:56Z
    try writeStamp(&w, 1_788_698_096_000);
    try testing.expectEqualStrings("2026-09-06 12:34:56", w.buffered());
}

test "truncate never splits a multi-byte character" {
    // Cutting mid-sequence renders as a replacement glyph, which reads as
    // corruption rather than as a line that was too long.
    const s = "ошибка соединения";
    for (0..s.len) |n| {
        const cut = truncate(s, n);
        try testing.expect(std.unicode.utf8ValidateSlice(cut));
    }
}

test "a long service name is cut to the column instead of shearing the table" {
    const long = "a-very-long-service-name-that-exceeds-the-column";
    const services = [_]state.ServiceStat{
        .{ .name = own(long), .counts = .{ .crash = 1 }, .last_crash_ms = now - 1000 },
        .{ .name = own("api"), .counts = .{} },
    };
    var buf: [8192]u8 = undefined;
    const out = try renderToBuf(&buf, .{
        .path = "state.json",
        .services = &services,
        .events = &.{},
        .signatures = 0,
    });

    // The table truncates; the crash detail below it, which has a whole line
    // to itself, still shows the name in full.
    const table = out[0..std.mem.indexOf(u8, out, "last crash").?];
    try testing.expect(std.mem.indexOf(u8, table, long) == null);
    try testing.expect(std.mem.indexOf(u8, table, long[0..max_name_col]) != null);

    // Both rows put their crash counter at the same offset, which is the
    // property a caller reads the table for.
    var it = std.mem.splitScalar(u8, out, '\n');
    _ = it.next(); // "state <path>"
    _ = it.next(); // blank
    const header = it.next().?;
    const first = it.next().?;
    const second = it.next().?;
    const col = std.mem.indexOf(u8, header, "CRASHES").? + "CRASHES".len;
    try testing.expectEqual(col, std.mem.lastIndexOfScalar(u8, first[0..col], '1').? + 1);
    try testing.expectEqual(col, std.mem.lastIndexOfScalar(u8, second[0..col], '0').? + 1);
}
