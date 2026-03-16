//! SIMD-accelerated utility functions for log parsing and string searching.
//! Provides vectorized operations for finding bytes, extracting fields,
//! and validating formats commonly used in log processing.
const std = @import("std");

/// Default vector size for SIMD operations (16 bytes = 128 bits).
pub const VecSize = 16;

// ============================================================================
// Internal helpers
// ============================================================================

/// Converts a boolean SIMD mask to a packed u16 bitmask for use with @ctz.
/// Bit N is set iff lane N of `mask` is true.
inline fn chunkMask(mask: @Vector(VecSize, bool)) u16 {
    var result: u16 = 0;
    // Pack 16 single-bit values into a u16.
    // @intFromBool guarantees 0/1 without an intermediate vector.
    // Zig has no _mm_movemask_epi8 intrinsic yet, so we do it manually.
    inline for (0..VecSize) |j| {
        result |= @as(u16, @intFromBool(mask[j])) << @intCast(j);
    }
    return result;
}

// ============================================================================
// Public API
// ============================================================================

/// Returns the index of the first occurrence of `needle` in `buf[start..]`,
/// or null if not found. Uses SIMD for windows >= VecSize bytes.
pub inline fn findByte(
    buf: []const u8,
    start: usize,
    needle: u8,
) ?usize {
    if (start >= buf.len) return null;

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

    while (i < buf.len) : (i += 1) {
        if (buf[i] == needle) return i;
    }
    return null;
}

/// Returns the index of the first byte equal to `a` or `b` in `buf[start..]`,
/// or null if not found.
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

/// Returns the index of the first byte equal to `a`, `b`, or `c` in `buf[start..]`,
/// or null if not found.
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
/// Returns a slice within `line` (no allocation), or null if the key is absent,
/// the value is not quoted, or the value exceeds `max_len` bytes.
/// Escaped quotes (`\"`) inside the value are handled correctly.
pub fn extractJsonField(
    line: []const u8,
    comptime key: []const u8,
    max_len: usize,
) ?[]const u8 {
    var i: usize = 0;

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

    // Scan for closing quote within the max_len window, honouring `\"` escapes.
    const window_end = @min(start + max_len, line.len);
    while (i < window_end) : (i += 1) {
        if (line[i] == '\\') {
            i += 1;
            continue;
        }
        if (line[i] == '"') break;
    }

    if (i >= window_end or line[i] != '"') return null;

    return line[start..i];
}

/// Returns true if `s` starts with an ISO-8601 date (`YYYY-MM-DD`).
/// Validates format only; calendar correctness is not checked.
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
/// or null if the line does not start with a non-empty `[…]`.
pub fn findBracketedLevel(line: []const u8) ?struct { start: usize, end: usize } {
    if (line.len < 3 or line[0] != '[') return null;
    const end = findByte(line, 1, ']') orelse return null;
    if (end <= 1) return null;
    return .{ .start = 1, .end = end };
}

/// Returns true if `line[pos..]` starts with `key`.
inline fn matchKeyAt(line: []const u8, pos: usize, comptime key: []const u8) bool {
    return pos + key.len <= line.len and
        std.mem.eql(u8, line[pos .. pos + key.len], key);
}

/// Returns true if `c` is a logfmt field separator (space or tab).
inline fn isLogfmtSep(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Finds a logfmt level field (`level=`, `severity=`, or `lvl=`) and returns
/// the byte range of its value (up to the next whitespace or EOL), or null.
/// Requires a word boundary before the key to avoid partial matches such as `mylevel=`.
pub fn findLogfmtLevel(line: []const u8) ?struct { start: usize, end: usize } {
    const keys = .{
        .{ "level", 5 },
        .{ "severity", 8 },
        .{ "lvl", 3 },
    };

    var i: usize = 0;

    while (true) {
        const eq = findByte(line, i, '=') orelse return null;

        inline for (keys) |kv| {
            const klen = kv[1];
            if (eq >= klen) {
                const key_start = eq - klen;
                if (matchKeyAt(line, key_start, kv[0]) and
                    (key_start == 0 or isLogfmtSep(line[key_start - 1])))
                {
                    const s = eq + 1;
                    var e = s;
                    while (e < line.len and !isLogfmtSep(line[e])) : (e += 1) {}
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

test "findByte: buffer exactly VecSize bytes" {
    var buf: [VecSize]u8 = undefined;
    @memset(&buf, 'a');
    buf[VecSize - 1] = 'x';
    try testing.expectEqual(@as(?usize, VecSize - 1), findByte(&buf, 0, 'x'));
    try testing.expectEqual(@as(?usize, null), findByte(&buf, 0, 'z'));
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

test "findEither: buffer exactly VecSize bytes" {
    var buf: [VecSize]u8 = undefined;
    @memset(&buf, 'a');
    buf[VecSize - 1] = 'x';
    try testing.expectEqual(@as(?usize, VecSize - 1), findEither(&buf, 0, 'x', 'y'));
    try testing.expectEqual(@as(?usize, null), findEither(&buf, 0, 'z', 'w'));
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

test "findAny3: buffer exactly VecSize bytes" {
    var buf: [VecSize]u8 = undefined;
    @memset(&buf, 'a');
    buf[VecSize - 1] = 'z';
    try testing.expectEqual(@as(?usize, VecSize - 1), findAny3(&buf, 0, 'x', 'y', 'z'));
    try testing.expectEqual(@as(?usize, null), findAny3(&buf, 0, 'p', 'q', 'r'));
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

test "extractJsonField: value exceeds max_len returns null" {
    const r = extractJsonField("{\"msg\":\"very long message here\"}", "msg", 4);
    try testing.expect(r == null);
}

test "extractJsonField: value exactly at max_len" {
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

test "extractJsonField: escaped quote inside value" {
    const r = extractJsonField("{\"msg\":\"hello \\\"world\\\"\"}", "msg", 20);
    try testing.expectEqualStrings("hello \\\"world\\\"", r.?);
}

test "extractJsonField: window_end does not bleed into next field quote" {
    const ok = extractJsonField("{\"k\":\"ab\",\"x\":\"y\"}", "k", 2);
    try testing.expectEqualStrings("ab", ok.?);
    const too_long = extractJsonField("{\"k\":\"ab\",\"x\":\"y\"}", "k", 1);
    try testing.expect(too_long == null);
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

test "findLogfmtLevel: word boundary — mylevel= must not match" {
    try testing.expect(findLogfmtLevel("mylevel=warn msg=test") == null);
}

test "findLogfmtLevel: word boundary — loglevel= must not match" {
    try testing.expect(findLogfmtLevel("loglevel=warn msg=test") == null);
}

test "findLogfmtLevel: tab separator before level=" {
    const line = "time=2024-01-15\tlevel=error\tmsg=test";
    const r = findLogfmtLevel(line).?;
    try testing.expectEqualStrings("error", line[r.start..r.end]);
}

test "findLogfmtLevel: tab separator before lvl=" {
    const line = "time=2024-01-15\tlvl=warn";
    const r = findLogfmtLevel(line).?;
    try testing.expectEqualStrings("warn", line[r.start..r.end]);
}

test "findLogfmtLevel: word boundary — xylvl= must not match" {
    try testing.expect(findLogfmtLevel("xylvl=warn msg=test") == null);
}
