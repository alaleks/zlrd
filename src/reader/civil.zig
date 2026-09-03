//! Calendar arithmetic for the `--since` filter.
//!
//! The reader compares timestamps as strings — `YYYY-MM-DD` against
//! `YYYY-MM-DD`, `HH:MM:SS` against `HH:MM:SS` — which works because both are
//! zero-padded and therefore order lexicographically. A relative window
//! breaks that: "five minutes before 00:02:00 on the 4th" is on the 3rd, and
//! no amount of string comparison gets you there. So a cutoff is computed
//! here, once, and handed back as the same pair of strings everything else
//! already knows how to compare.
//!
//! ## No time zones, on purpose
//!
//! Nothing here converts between zones, and that is what makes it correct.
//! Both sides of every comparison come from the same place — the log — so
//! whatever offset its timestamps are written in cancels out. Anchoring on
//! the system clock instead would need the machine's zone, the log's zone,
//! and the assumption that they agree; this needs none of the three, and
//! keeps working when the clock of the machine reading the file has nothing
//! to do with the machine that wrote it.
//!
//! The conversion below therefore treats a date and time as a plain count of
//! seconds on a proleptic Gregorian calendar. It is not a Unix timestamp and
//! must not be used as one.

const std = @import("std");

/// A cutoff, in the shape the string comparisons expect.
pub const Cutoff = struct {
    date: [10]u8,
    time: [8]u8,

    pub fn dateSlice(self: *const Cutoff) []const u8 {
        return &self.date;
    }

    pub fn timeSlice(self: *const Cutoff) []const u8 {
        return &self.time;
    }
};

/// Days from 1970-01-01 to `y-m-d`, by Howard Hinnant's `days_from_civil`.
///
/// Chosen over a table because it is branch-free apart from one comparison,
/// handles every year without a leap-year special case, and is exact for any
/// date a log can carry.
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = y_in - @intFromBool(m <= 2);
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400; // [0, 399]
    const doy = @divTrunc(153 * (m + (if (m > 2) @as(i64, -3) else 9)) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Inverse of `daysFromCivil`.
fn civilFromDays(z_in: i64) struct { y: i64, m: i64, d: i64 } {
    const z = z_in + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = mp + (if (mp < 10) @as(i64, 3) else -9);
    return .{ .y = y + @intFromBool(m <= 2), .m = m, .d = d };
}

fn twoDigits(s: []const u8) ?i64 {
    if (s.len < 2 or !std.ascii.isDigit(s[0]) or !std.ascii.isDigit(s[1])) return null;
    return @as(i64, s[0] - '0') * 10 + @as(i64, s[1] - '0');
}

/// Converts a `YYYY-MM-DD` date and an `HH:MM[:SS]` time into a second count
/// on the shared calendar. Returns null when either is malformed.
///
/// `time` may be null — a date with no time is taken as its midnight, which
/// keeps a log whose lines carry only a date usable with `--since`.
pub fn toSeconds(date: []const u8, time: ?[]const u8) ?i64 {
    if (date.len < 10 or date[4] != '-' or date[7] != '-') return null;
    var year: i64 = 0;
    for (date[0..4]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        year = year * 10 + (c - '0');
    }
    const month = twoDigits(date[5..]) orelse return null;
    const day = twoDigits(date[8..]) orelse return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;

    var secs = daysFromCivil(year, month, day) * 86_400;
    if (time) |t| {
        if (t.len < 5 or t[2] != ':') return null;
        const hh = twoDigits(t[0..]) orelse return null;
        const mm = twoDigits(t[3..]) orelse return null;
        if (hh > 23 or mm > 59) return null;
        secs += hh * 3600 + mm * 60;
        if (t.len >= 8 and t[5] == ':') {
            const ss = twoDigits(t[6..]) orelse return null;
            if (ss > 60) return null; // 60 is a leap second, not an error
            secs += ss;
        }
    }
    return secs;
}

/// Formats a second count back into the pair of strings the filters compare.
pub fn fromSeconds(secs: i64) Cutoff {
    const days = @divFloor(secs, 86_400);
    const rem = secs - days * 86_400;
    const c = civilFromDays(days);

    var out: Cutoff = .{ .date = undefined, .time = undefined };
    // Years outside four digits cannot be compared against a log's own
    // `YYYY-MM-DD` anyway, so they clamp rather than corrupt the layout.
    const y: u64 = @intCast(std.math.clamp(c.y, 0, 9999));
    _ = std.fmt.bufPrint(&out.date, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        y,
        @as(u64, @intCast(c.m)),
        @as(u64, @intCast(c.d)),
    }) catch unreachable;
    _ = std.fmt.bufPrint(&out.time, "{d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u64, @intCast(@divTrunc(rem, 3600))),
        @as(u64, @intCast(@divTrunc(@mod(rem, 3600), 60))),
        @as(u64, @intCast(@mod(rem, 60))),
    }) catch unreachable;
    return out;
}

/// The cutoff `window_ms` before the anchor, or null when the anchor cannot
/// be read as a date.
pub fn cutoffBefore(anchor_date: []const u8, anchor_time: ?[]const u8, window_ms: u64) ?Cutoff {
    const secs = toSeconds(anchor_date, anchor_time) orelse return null;
    const window_s: i64 = @intCast(window_ms / 1000);
    return fromSeconds(secs - window_s);
}

/// True when a line's `(date, time)` is at or after `cut`.
///
/// A line with no date cannot be placed on the timeline at all. It is kept:
/// dropping continuation lines, stack frames and banners — none of which
/// carry a timestamp — would tear apart exactly the records `--since` was
/// opened to look at.
pub fn atOrAfter(date: ?[]const u8, time: ?[]const u8, cut: *const Cutoff) bool {
    const d = date orelse return true;
    if (d.len < 10) return true;

    switch (std.mem.order(u8, d[0..10], &cut.date)) {
        .lt => return false,
        .gt => return true,
        .eq => {},
    }

    // Same day: the time decides. A line with a date but no time sits at the
    // start of its day, which is at or after a cutoff that falls on it only
    // when the cutoff is midnight.
    const t = time orelse return std.mem.eql(u8, &cut.time, "00:00:00");
    const len = @min(t.len, cut.time.len);
    return std.mem.order(u8, t[0..len], cut.time[0..len]) != .lt;
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

test "civil round-trips across leap years and centuries" {
    for ([_][3]i64{
        .{ 1970, 1, 1 },
        .{ 2000, 2, 29 }, // divisible by 400 — a leap year
        .{ 1900, 3, 1 }, // divisible by 100 — not one
        .{ 2024, 2, 29 },
        .{ 2026, 9, 3 },
        .{ 2099, 12, 31 },
    }) |ymd| {
        const days = daysFromCivil(ymd[0], ymd[1], ymd[2]);
        const back = civilFromDays(days);
        try testing.expectEqual(ymd[0], back.y);
        try testing.expectEqual(ymd[1], back.m);
        try testing.expectEqual(ymd[2], back.d);
    }
}

test "the epoch is day zero" {
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, 0), toSeconds("1970-01-01", "00:00:00").?);
}

test "toSeconds accepts both time widths and a bare date" {
    const base = toSeconds("2026-09-03", null).?;
    try testing.expectEqual(base + 10 * 3600 + 44 * 60, toSeconds("2026-09-03", "10:44").?);
    try testing.expectEqual(base + 10 * 3600 + 44 * 60 + 5, toSeconds("2026-09-03", "10:44:05").?);
}

test "toSeconds rejects malformed input instead of guessing" {
    try testing.expectEqual(@as(?i64, null), toSeconds("2026/09/03", "10:44:05"));
    try testing.expectEqual(@as(?i64, null), toSeconds("2026-09-03", "10-44-05"));
    try testing.expectEqual(@as(?i64, null), toSeconds("2026-13-03", null));
    try testing.expectEqual(@as(?i64, null), toSeconds("2026-09-03", "25:00:00"));
    try testing.expectEqual(@as(?i64, null), toSeconds("short", null));
}

test "a window crossing midnight lands on the previous day" {
    // This is the case string comparison alone cannot express, and the whole
    // reason this module exists.
    const cut = cutoffBefore("2026-09-04", "00:02:00", 5 * 60 * 1000).?;
    try testing.expectEqualStrings("2026-09-03", &cut.date);
    try testing.expectEqualStrings("23:57:00", &cut.time);
}

test "a window crossing a month, a year and a leap day" {
    const m = cutoffBefore("2026-09-01", "00:00:30", 60 * 1000).?;
    try testing.expectEqualStrings("2026-08-31", &m.date);

    const y = cutoffBefore("2026-01-01", "00:00:30", 60 * 1000).?;
    try testing.expectEqualStrings("2025-12-31", &y.date);

    const leap = cutoffBefore("2024-03-01", "00:00:30", 60 * 1000).?;
    try testing.expectEqualStrings("2024-02-29", &leap.date);
}

test "atOrAfter orders by date first, then by time" {
    const cut = cutoffBefore("2026-09-03", "10:44:05", 5 * 60 * 1000).?; // 10:39:05

    try testing.expect(atOrAfter("2026-09-03", "10:44:05", &cut));
    try testing.expect(atOrAfter("2026-09-03", "10:39:05", &cut)); // the boundary is inclusive
    try testing.expect(!atOrAfter("2026-09-03", "10:39:04", &cut));
    try testing.expect(!atOrAfter("2026-09-02", "23:59:59", &cut));
    try testing.expect(atOrAfter("2026-09-04", "00:00:00", &cut));
}

test "atOrAfter compares only the width both sides share" {
    const cut = cutoffBefore("2026-09-03", "10:44:00", 5 * 60 * 1000).?; // 10:39:00
    // `HH:MM` from the log against `HH:MM:SS` from the cutoff.
    try testing.expect(atOrAfter("2026-09-03", "10:40", &cut));
    try testing.expect(!atOrAfter("2026-09-03", "10:38", &cut));
}

test "a line without a timestamp is kept" {
    const cut = cutoffBefore("2026-09-03", "10:44:05", 60 * 1000).?;
    // Stack frames and continuation lines carry no date; dropping them would
    // shred the very records the filter was opened to read.
    try testing.expect(atOrAfter(null, null, &cut));
    try testing.expect(atOrAfter("bad", null, &cut));
}
