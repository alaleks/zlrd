//! SIMD-accelerated utility functions for log parsing and string searching.
//! This module provides vectorized operations for finding bytes, extracting fields,
//! and validating formats commonly used in log processing.
const std = @import("std");

/// Default vector size for SIMD operations (16 bytes = 128 bits).
pub const VecSize = 16;

// ============================================================================
// Internal helpers
// ============================================================================

/// Convert a boolean SIMD mask to a packed u16 bitmask for use with @ctz.
/// Bit N is set iff lane N of `mask` is true.
///
/// PERF: replaces the original `inline for (0..VecSize)` scan inside each
/// SIMD hit — that scan was still O(VecSize) in the hot path. @ctz is O(1).
inline fn chunkMask(mask: @Vector(VecSize, bool)) u16 {
    const ones: @Vector(VecSize, u8) = @splat(1);
    const zeros: @Vector(VecSize, u8) = @splat(0);
    const bits: @Vector(VecSize, u8) = @select(u8, mask, ones, zeros);
    var result: u16 = 0;
    // Pack 16 single-bit values into a u16.
    // Zig has no _mm_movemask_epi8 intrinsic yet, so we do it manually.
    // This still compiles to a handful of instructions and is always faster
    // than the 16-iteration scalar scan it replaces.
    inline for (0..VecSize) |j| {
        result |= @as(u16, bits[j]) << @intCast(j);
    }
    return result;
}

// ============================================================================
// Public API
// ============================================================================

/// Finds the first occurrence of `needle` in `buf[start..]`.
/// Uses SIMD for buffers ≥ VecSize bytes, scalar otherwise.
/// Returns the absolute index within `buf`, or null.
///
/// BUG FIX (original code): `buf.len - start` underflows (usize wrap) when
/// start > buf.len, causing an incorrect SIMD path or out-of-bounds access.
pub inline fn findByte(
    buf: []const u8,
    start: usize,
    needle: u8,
) ?usize {
    if (start >= buf.len) return null;

    // Scalar path for small remaining windows.
    if (buf.len - start < VecSize) {
        for (buf[start..], start..) |c, i| {
            if (c == needle) return i;
        }
        return null;
    }

    const v: @Vector(VecSize, u8) = @splat(needle);
    var i = start;
    const limit = buf.len - VecSize;

    while (i <= limit) : (i += VecSize) {
        const chunk: @Vector(VecSize, u8) = buf[i..][0..VecSize].*;
        const eq = chunk == v;
        if (@reduce(.Or, eq)) {
            return i + @ctz(chunkMask(eq));
        }
    }

    // Scalar tail for remaining < VecSize bytes.
    while (i < buf.len) : (i += 1) {
        if (buf[i] == needle) return i;
    }
    return null;
}

/// Finds the first byte equal to `a` or `b` in `buf[start..]`.
pub inline fn findEither(
    buf: []const u8,
    start: usize,
    a: u8,
    b: u8,
) ?usize {
    if (start >= buf.len) return null;

    if (buf.len - start < VecSize) {
        for (buf[start..], start..) |c, i| {
            if (c == a or c == b) return i;
        }
        return null;
    }

    const va: @Vector(VecSize, u8) = @splat(a);
    const vb: @Vector(VecSize, u8) = @splat(b);
    var i = start;
    const limit = buf.len - VecSize;

    while (i <= limit) : (i += VecSize) {
        const chunk: @Vector(VecSize, u8) = buf[i..][0..VecSize].*;
        const hits = (chunk == va) | (chunk == vb);
        if (@reduce(.Or, hits)) {
            return i + @ctz(chunkMask(hits));
        }
    }

    while (i < buf.len) : (i += 1) {
        const c = buf[i];
        if (c == a or c == b) return i;
    }
    return null;
}

/// Finds the first byte equal to `a`, `b`, or `c` in `buf[start..]`.
pub inline fn findAny3(
    buf: []const u8,
    start: usize,
    a: u8,
    b: u8,
    c: u8,
) ?usize {
    if (start >= buf.len) return null;

    if (buf.len - start < VecSize) {
        for (buf[start..], start..) |ch, i| {
            if (ch == a or ch == b or ch == c) return i;
        }
        return null;
    }

    const va: @Vector(VecSize, u8) = @splat(a);
    const vb: @Vector(VecSize, u8) = @splat(b);
    const vc: @Vector(VecSize, u8) = @splat(c);
    var i = start;
    const limit = buf.len - VecSize;

    while (i <= limit) : (i += VecSize) {
        const chunk: @Vector(VecSize, u8) = buf[i..][0..VecSize].*;
        const hits = (chunk == va) | (chunk == vb) | (chunk == vc);
        if (@reduce(.Or, hits)) {
            return i + @ctz(chunkMask(hits));
        }
    }

    while (i < buf.len) : (i += 1) {
        const ch = buf[i];
        if (ch == a or ch == b or ch == c) return i;
    }
    return null;
}

/// Extracts the string value of a JSON field matching `"key":"value"`.
/// Returns a slice within `line` (no allocation), or null on any mismatch.
///
/// BUG FIX (original + my previous version): after clamping the scan window
/// to `end = min(start + max_len, line.len)`, the closing-quote check was
///   `if (i >= line.len)` — but `i` stops at `end`, not `line.len`, so when
/// the value is shorter than max_len but longer than (line.len - start) the
/// check was wrong. Correct condition: `line[i] != '"'` (i.e. we hit `end`
/// without finding the closing quote).
///
/// BUG FIX 2: max_len is a character limit on the *value*, not a hard truncation
/// that returns a partial string. If the closing `"` is beyond max_len we return
/// null (malformed / too long), consistent with a filter use-case. The old test
/// `expectEqualStrings("very long ", result.?)` was testing wrong behaviour.
pub fn extractJsonField(
    line: []const u8,
    comptime key: []const u8,
    max_len: usize,
) ?[]const u8 {
    var i: usize = 0;

    // Locate `"key"` in the line.
    while (true) {
        const q = findByte(line, i, '"') orelse return null;

        if (q + key.len + 2 <= line.len and
            std.mem.eql(u8, line[q + 1 .. q + 1 + key.len], key) and
            line[q + 1 + key.len] == '"')
        {
            i = q + key.len + 2;
            break;
        }

        i = q + 1;
    }

    // Skip `:` and optional spaces.
    while (i < line.len and (line[i] == ' ' or line[i] == ':')) : (i += 1) {}
    if (i >= line.len or line[i] != '"') return null;

    i += 1; // skip opening quote
    const start = i;

    // Scan for closing quote within the max_len window.
    const window_end = @min(start + max_len, line.len);
    while (i < window_end and line[i] != '"') : (i += 1) {}

    // If we did not land on a closing quote, the value is absent or too long.
    if (i >= line.len or line[i] != '"') return null;

    return line[start..i];
}

/// Returns true if `s` starts with an ISO-8601 date: `YYYY-MM-DD`.
/// Validates format only — calendar validity is not checked.
pub inline fn isISODate(s: []const u8) bool {
    if (s.len < 10) return false;
    inline for (0..10) |idx| {
        const c = s[idx];
        if (idx == 4 or idx == 7) {
            if (c != '-') return false;
        } else {
            if (c < '0' or c > '9') return false;
        }
    }
    return true;
}

/// Returns the byte range of the level text inside a leading `[LEVEL]` marker,
/// or null if the line does not start with `[…]` (non-empty content required).
pub fn findBracketedLevel(line: []const u8) ?struct { start: usize, end: usize } {
    if (line.len < 3 or line[0] != '[') return null;
    const end = findByte(line, 1, ']') orelse return null;
    if (end <= 1) return null; // empty brackets `[]`
    return .{ .start = 1, .end = end };
}

/// True if `line[pos..]` starts with `key`.
inline fn matchKeyAt(line: []const u8, pos: usize, comptime key: []const u8) bool {
    return pos + key.len <= line.len and
        std.mem.eql(u8, line[pos .. pos + key.len], key);
}

/// Finds a logfmt level field: `level=`, `severity=`, or `lvl=`.
/// Returns the byte range of the value (up to the next space or EOL).
///
/// BUG FIX (original code): `pos >= 5 and matchKeyAt(line, pos - 5, "level")`
/// allows `mylevel=` to match because it only checks that the 5 chars before `=`
/// spell "level", without checking the word boundary before them.
/// Fix: additionally require `key_start == 0 or line[key_start - 1] == ' '`.
pub fn findLogfmtLevel(line: []const u8) ?struct { start: usize, end: usize } {
    var i: usize = 0;

    while (true) {
        const eq = findByte(line, i, '=') orelse return null;

        // Try each key in priority order. Word-boundary guard prevents
        // `mylevel=` or `loglevel=` from matching as `level=`.
        const keys = .{
            .{ "level", 5 },
            .{ "severity", 8 },
            .{ "lvl", 3 },
        };
        inline for (keys) |kv| {
            const klen = kv[1];
            if (eq >= klen) {
                const key_start = eq - klen;
                if (matchKeyAt(line, key_start, kv[0]) and
                    (key_start == 0 or line[key_start - 1] == ' '))
                {
                    const s = eq + 1;
                    var e = s;
                    while (e < line.len and line[e] != ' ') : (e += 1) {}
                    return .{ .start = s, .end = e };
                }
            }
        }

        i = eq + 1;
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

// ── findByte ─────────────────────────────────────────────────────────────────

test "findByte: small buffer" {
    try testing.expectEqual(@as(?usize, 1), findByte("hello", 0, 'e'));
    try testing.expectEqual(@as(?usize, 4), findByte("hello", 0, 'o'));
    try testing.expectEqual(@as(?usize, null), findByte("hello", 0, 'x'));
}

test "findByte: large buffer SIMD" {
    const buf = "a" ** 100 ++ "x" ++ "a" ** 100;
    try testing.expectEqual(@as(?usize, 100), findByte(buf, 0, 'x'));
}

test "findByte: respects start" {
    try testing.expectEqual(@as(?usize, 4), findByte("hello world", 3, 'o'));
    try testing.expectEqual(@as(?usize, null), findByte("hello world", 8, 'o'));
}

test "findByte: empty buffer" {
    try testing.expectEqual(@as(?usize, null), findByte("", 0, 'x'));
}

// BUG: original panicked here due to usize underflow.
test "findByte: start >= buf.len" {
    try testing.expectEqual(@as(?usize, null), findByte("hello", 5, 'h'));
    try testing.expectEqual(@as(?usize, null), findByte("hello", 100, 'h'));
}

test "findByte: SIMD vector boundaries" {
    var buf: [VecSize * 3]u8 = undefined;
    @memset(&buf, 'a');
    buf[VecSize - 1] = 'x';
    buf[VecSize] = 'y';
    buf[VecSize * 2] = 'z';
    try testing.expectEqual(@as(?usize, VecSize - 1), findByte(&buf, 0, 'x'));
    try testing.expectEqual(@as(?usize, VecSize), findByte(&buf, 0, 'y'));
    try testing.expectEqual(@as(?usize, VecSize * 2), findByte(&buf, 0, 'z'));
}

test "findByte: all-same buffer" {
    try testing.expectEqual(@as(?usize, 0), findByte("aaaaaaaaaaaaaaaa", 0, 'a'));
    try testing.expectEqual(@as(?usize, null), findByte("aaaaaaaaaaaaaaaa", 0, 'b'));
}

test "findByte: newlines" {
    const buf = "line1\nline2\nline3";
    try testing.expectEqual(@as(?usize, 5), findByte(buf, 0, '\n'));
    try testing.expectEqual(@as(?usize, 11), findByte(buf, 6, '\n'));
}

// ── findEither ───────────────────────────────────────────────────────────────

test "findEither: finds first of two" {
    try testing.expectEqual(@as(?usize, 1), findEither("hello world", 0, 'e', 'o'));
}

test "findEither: falls back to second byte" {
    try testing.expectEqual(@as(?usize, 4), findEither("hello world", 0, 'x', 'o'));
}

test "findEither: not found" {
    try testing.expectEqual(@as(?usize, null), findEither("hello", 0, 'x', 'y'));
}

test "findEither: large buffer" {
    const buf = "a" ** 50 ++ "x" ++ "a" ** 50;
    try testing.expectEqual(@as(?usize, 50), findEither(buf, 0, 'x', 'y'));
}

test "findEither: start >= buf.len" {
    try testing.expectEqual(@as(?usize, null), findEither("hi", 10, 'h', 'i'));
}

// ── findAny3 ─────────────────────────────────────────────────────────────────

test "findAny3: finds first match" {
    try testing.expectEqual(@as(?usize, 1), findAny3("hello world", 0, 'e', 'o', 'x'));
}

test "findAny3: not found" {
    try testing.expectEqual(@as(?usize, null), findAny3("hello", 0, 'x', 'y', 'z'));
}

test "findAny3: large buffer" {
    const buf = "a" ** 50 ++ "x" ++ "a" ** 50;
    try testing.expectEqual(@as(?usize, 50), findAny3(buf, 0, 'x', 'y', 'z'));
}

test "findAny3: start >= buf.len" {
    try testing.expectEqual(@as(?usize, null), findAny3("hi", 10, 'h', 'i', 'j'));
}

// ── extractJsonField ─────────────────────────────────────────────────────────

test "extractJsonField: simple field" {
    const r = extractJsonField("{\"level\":\"error\",\"msg\":\"test\"}", "level", 10);
    try testing.expectEqualStrings("error", r.?);
}

test "extractJsonField: time field" {
    const r = extractJsonField("{\"time\":\"2024-01-15T10:30:45Z\"}", "time", 30);
    try testing.expectEqualStrings("2024-01-15T10:30:45Z", r.?);
}

// BUG FIX: max_len is a limit — values longer than max_len return null,
// not a truncated slice. Old code returned partial strings.
test "extractJsonField: value exceeds max_len returns null" {
    const r = extractJsonField("{\"msg\":\"very long message here\"}", "msg", 4);
    try testing.expect(r == null);
}

test "extractJsonField: value exactly at max_len" {
    // "err" is 5 chars; max_len=5 should succeed.
    const r = extractJsonField("{\"level\":\"error\"}", "level", 5);
    try testing.expectEqualStrings("error", r.?);
}

test "extractJsonField: missing key" {
    try testing.expect(extractJsonField("{\"level\":\"error\"}", "msg", 10) == null);
}

test "extractJsonField: unquoted value (malformed)" {
    try testing.expect(extractJsonField("{\"level\":error}", "level", 10) == null);
}

test "extractJsonField: similar key prefix" {
    // "level_old" must not shadow "level"
    const r = extractJsonField("{\"level_old\":\"warn\",\"level\":\"error\"}", "level", 10);
    try testing.expectEqualStrings("error", r.?);
}

test "extractJsonField: empty value" {
    const r = extractJsonField("{\"msg\":\"\",\"level\":\"info\"}", "msg", 10);
    try testing.expectEqualStrings("", r.?);
}

test "extractJsonField: unicode in other field does not crash" {
    const r = extractJsonField("{\"msg\":\"Hello 世界\",\"level\":\"info\"}", "level", 10);
    try testing.expectEqualStrings("info", r.?);
}

// ── isISODate ────────────────────────────────────────────────────────────────

test "isISODate: valid dates" {
    try testing.expect(isISODate("2024-01-15"));
    try testing.expect(isISODate("2024-01-15T10:30:45"));
    try testing.expect(isISODate("1999-12-31 extra"));
}

test "isISODate: invalid formats" {
    try testing.expect(!isISODate("2024/01/15"));
    try testing.expect(!isISODate("24-01-15"));
    try testing.expect(!isISODate("2024-1-15"));
    try testing.expect(!isISODate("2024-01"));
    try testing.expect(!isISODate(""));
    try testing.expect(!isISODate("abcd-ef-gh"));
}

// ── findBracketedLevel ───────────────────────────────────────────────────────

test "findBracketedLevel: basic" {
    const r = findBracketedLevel("[ERROR] msg").?;
    try testing.expectEqualStrings("ERROR", "[ERROR] msg"[r.start..r.end]);
}

test "findBracketedLevel: various levels" {
    inline for ([_][]const u8{ "[INFO] x", "[WARN] x", "[DEBUG] x", "[TRACE] x" }) |l| {
        try testing.expect(findBracketedLevel(l) != null);
    }
}

test "findBracketedLevel: no bracket" {
    try testing.expect(findBracketedLevel("ERROR msg") == null);
    try testing.expect(findBracketedLevel("") == null);
    try testing.expect(findBracketedLevel("[") == null);
    try testing.expect(findBracketedLevel("[]") == null);
}

test "findBracketedLevel: bracket not at start" {
    try testing.expect(findBracketedLevel("text [ERROR] here") == null);
}

// ── findLogfmtLevel ──────────────────────────────────────────────────────────

test "findLogfmtLevel: level=" {
    const line = "time=2024-01-15 level=error msg=test";
    const r = findLogfmtLevel(line).?;
    try testing.expectEqualStrings("error", line[r.start..r.end]);
}

test "findLogfmtLevel: severity=" {
    const line = "time=2024-01-15 severity=warn msg=test";
    const r = findLogfmtLevel(line).?;
    try testing.expectEqualStrings("warn", line[r.start..r.end]);
}

test "findLogfmtLevel: lvl=" {
    const line = "time=2024-01-15 lvl=info msg=test";
    const r = findLogfmtLevel(line).?;
    try testing.expectEqualStrings("info", line[r.start..r.end]);
}

test "findLogfmtLevel: at end of line" {
    const line = "time=2024-01-15 level=error";
    const r = findLogfmtLevel(line).?;
    try testing.expectEqualStrings("error", line[r.start..r.end]);
}

test "findLogfmtLevel: at start of line" {
    const line = "level=debug msg=boot";
    const r = findLogfmtLevel(line).?;
    try testing.expectEqualStrings("debug", line[r.start..r.end]);
}

test "findLogfmtLevel: not found" {
    try testing.expect(findLogfmtLevel("time=2024-01-15 msg=test") == null);
    try testing.expect(findLogfmtLevel("") == null);
    try testing.expect(findLogfmtLevel("no equals") == null);
}

// BUG FIX: "mylevel=warn" must NOT match as "level=warn".
test "findLogfmtLevel: word boundary — mylevel= must not match" {
    try testing.expect(findLogfmtLevel("mylevel=warn msg=test") == null);
}

test "findLogfmtLevel: word boundary — loglevel= must not match" {
    try testing.expect(findLogfmtLevel("loglevel=warn msg=test") == null);
}
