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
///
/// Compiles to a single `vpmovmskb`-equivalent instruction on x86_64 (SSE2) and
/// `umaxv`/`shrn` sequences on aarch64 — far cheaper than a 16-step inline OR.
inline fn chunkMask(mask: @Vector(VecSize, bool)) u16 {
    const bits: @Vector(VecSize, u1) = @intFromBool(mask);
    return @bitCast(bits);
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

/// Walks a JSON string body starting at `body_start` (the byte right after the
/// opening `"`) and returns the index of the closing quote, or null if the
/// string is unterminated.
///
/// Uses SIMD to jump over runs of plain characters between escape sequences,
/// which is the dominant case for log messages.
pub fn scanJsonStringEnd(line: []const u8, body_start: usize) ?usize {
    var i = body_start;
    while (i < line.len) {
        const pos = findEither(line, i, '\\', '"') orelse return null;
        if (line[pos] == '"') return pos;
        // Backslash: skip it and the escaped byte (handles \", \\ and others).
        i = pos + 2;
    }
    return null;
}

/// Extracts the string value of a JSON field matching `"key": "value"`.
/// Returns a slice within `line` (no allocation), or null if the key is absent,
/// the value is not a quoted JSON string, or the value exceeds `max_len` bytes.
///
/// Escaped bytes inside JSON strings are skipped correctly while scanning.
pub fn extractJsonField(
    line: []const u8,
    key: []const u8,
    max_len: usize,
) ?[]const u8 {
    if (line.len < key.len + 4) return null;

    var i: usize = 0;
    while (i < line.len) {
        const q = findByte(line, i, '"') orelse return null;
        i = q + 1;

        const key_start = i;
        const key_end = scanJsonStringEnd(line, i) orelse return null;

        const found_key = line[key_start..key_end];
        i = key_end + 1;

        // Skip whitespace after key.
        while (i < line.len and (line[i] == ' ' or line[i] == '\t' or line[i] == '\n' or line[i] == '\r')) : (i += 1) {}

        if (i >= line.len or line[i] != ':') {
            continue;
        }
        i += 1;

        // Skip whitespace before value.
        while (i < line.len and (line[i] == ' ' or line[i] == '\t' or line[i] == '\n' or line[i] == '\r')) : (i += 1) {}

        const is_target_key = std.mem.eql(u8, found_key, key);

        if (!is_target_key) {
            i = skipJsonValue(line, i);
            continue;
        }

        if (i >= line.len or line[i] != '"') return null;
        i += 1;

        const value_start = i;
        const value_end = scanJsonStringEnd(line, i) orelse return null;
        const value = line[value_start..value_end];
        if (value.len > max_len) return null;

        return value;
    }

    return null;
}

fn skipJsonValue(line: []const u8, start: usize) usize {
    var i = start;
    if (i >= line.len) return i;

    if (line[i] == '"') {
        const end = scanJsonStringEnd(line, i + 1) orelse return line.len;
        return end + 1;
    }

    if (line[i] == '{' or line[i] == '[') {
        var depth: usize = 0;
        while (i < line.len) {
            switch (line[i]) {
                '"' => {
                    i = skipJsonValue(line, i);
                    continue;
                },
                '{', '[' => depth += 1,
                '}', ']' => {
                    depth -= 1;
                    i += 1;
                    if (depth == 0) return i;
                    continue;
                },
                else => {},
            }
            i += 1;
        }
        return i;
    }

    while (i < line.len and line[i] != ',' and line[i] != '}' and line[i] != ']') : (i += 1) {}
    return i;
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

/// Returns the byte range inside the leading `[...]` marker,
/// or null if the line does not start with a non-empty bracketed token.
///
/// The caller is responsible for validating that the token is an actual log level.
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

/// Finds an unquoted logfmt level field (`level=`, `severity=`, or `lvl=`) and returns
/// the byte range of its value up to the next whitespace or EOL, or null.
///
/// Requires a field boundary before the key to avoid partial matches such as `mylevel=`.
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

/// Strips journalctl-encoded ANSI escape sequences of the form `#033[…m`
/// (SGR parameters made of digits, `;`, `:`) from `src` into `dst`, returning
/// the populated slice. If `src` contains no such sequence, `src` is returned
/// unchanged — the caller pays nothing on the hot path where the log source
/// is not zerolog+journalctl.
///
/// Only well-formed SGR sequences are stripped: `#033[` followed by
/// digits/`;`/`:` and terminated by `m`. Malformed matches are left in place
/// so unrelated `#033[…` runs in real message bodies aren't swallowed.
pub fn stripLiteralAnsi(dst: []u8, src: []const u8) []const u8 {
    var esc = findLiteralAnsi(src, 0) orelse return src;
    // Stripping only removes bytes, so `dst` must be large enough to hold the
    // worst-case (no-strip) output. If not, return `src` unchanged instead of
    // silently truncating and desynchronising level_pos / search_matches.
    if (dst.len < src.len) return src;

    var out: usize = 0;
    var i: usize = 0;
    while (true) {
        // Bulk-copy everything up to the escape rather than one byte at a
        // time — the vast majority of a line is ordinary text.
        const run = esc - i;
        @memcpy(dst[out..][0..run], src[i..esc]);
        out += run;

        var j = esc + literal_ansi_prefix.len;
        var terminated = false;
        while (j < src.len) : (j += 1) {
            const c = src[j];
            if (c == 'm') {
                terminated = true;
                break;
            }
            if (!((c >= '0' and c <= '9') or c == ';' or c == ':')) break;
        }

        if (terminated) {
            i = j + 1;
        } else {
            // Malformed: keep the byte and resume just past it, so unrelated
            // `#033[…` runs in real message bodies aren't swallowed.
            dst[out] = src[esc];
            out += 1;
            i = esc + 1;
        }
        esc = findLiteralAnsi(src, i) orelse break;
    }
    const tail = src.len - i;
    @memcpy(dst[out..][0..tail], src[i..]);
    return dst[0 .. out + tail];
}

const literal_ansi_prefix = "#033[";

/// Index of the next `#033[` in `src` at or after `from`, or null.
///
/// Gated on a vectorised single-byte scan for `#`. The obvious
/// `std.mem.indexOf(u8, src, "#033[")` costs the same as a scalar pass over
/// every line, and since `stripLiteralAnsi` runs on every line of every file,
/// that one call measured at ~73% of the whole filtering path — 603 ms of a
/// 743 ms scan over 479 MB. The gate brings it to 59 ms.
fn findLiteralAnsi(src: []const u8, from: usize) ?usize {
    var i = from;
    while (findByte(src, i, '#')) |hit| {
        if (hit + literal_ansi_prefix.len <= src.len and
            std.mem.eql(u8, src[hit..][0..literal_ansi_prefix.len], literal_ansi_prefix))
        {
            return hit;
        }
        i = hit + 1;
    }
    return null;
}

inline fn isAsciiAlpha(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

/// Returns the byte range of the next contiguous ASCII-alpha token in
/// `line[from..]`, or null if none. Used to enumerate candidate level tokens
/// for `findFreeStandingLevel`.
pub fn nextAlphaToken(line: []const u8, from: usize) ?struct { start: usize, end: usize } {
    var i = from;
    while (i < line.len and !isAsciiAlpha(line[i])) : (i += 1) {}
    if (i >= line.len) return null;
    const s = i;
    while (i < line.len and isAsciiAlpha(line[i])) : (i += 1) {}
    return .{ .start = s, .end = i };
}

/// Locates a gRPC status marker of the form `code = <NAME>` inside `line` and
/// returns the byte range of `<NAME>` when it is non-empty. Whitespace around
/// the `=` is tolerated. Boundary before `code` must be start-of-line or a
/// non-alnum byte so we don't match tokens like `error_code`.
///
/// The caller decides how to interpret the name; `OK` means success.
pub fn findGrpcCode(line: []const u8) ?struct { start: usize, end: usize } {
    const needle = "code";
    var i: usize = 0;
    // Gated on a vectorised scan for `c` rather than
    // `std.mem.indexOfPos(line, i, "code")`. This runs on every line whose
    // level wasn't found by the bracketed or logfmt paths — which is every
    // syslog-style line with a timestamp prefix — so a scalar substring
    // search here costs a full extra pass over most of the file.
    while (findByte(line, i, 'c')) |hit| {
        if (hit + needle.len > line.len or
            !std.mem.eql(u8, line[hit..][0..needle.len], needle))
        {
            i = hit + 1;
            continue;
        }
        const boundary_ok = if (hit == 0) true else blk: {
            const c = line[hit - 1];
            break :blk !isAsciiAlpha(c) and !(c >= '0' and c <= '9') and c != '_';
        };
        if (!boundary_ok) {
            i = hit + needle.len;
            continue;
        }
        var j = hit + needle.len;
        while (j < line.len and (line[j] == ' ' or line[j] == '\t')) : (j += 1) {}
        if (j >= line.len or line[j] != '=') {
            i = hit + needle.len;
            continue;
        }
        j += 1;
        while (j < line.len and (line[j] == ' ' or line[j] == '\t')) : (j += 1) {}
        const s = j;
        while (j < line.len and (isAsciiAlpha(line[j]) or (line[j] >= '0' and line[j] <= '9') or line[j] == '_')) : (j += 1) {}
        if (j == s) {
            i = hit + needle.len;
            continue;
        }
        return .{ .start = s, .end = j };
    }
    return null;
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

test "extractJsonField: key-like text inside another string must not match" {
    const line =
        "{\"msg\":\"text with \\\"level\\\":\\\"warn\\\" inside\",\"level\":\"error\"}";
    const r = extractJsonField(line, "level", 10);
    try testing.expectEqualStrings("error", r.?);
}

test "extractJsonField: escaped backslash before quote" {
    const line = "{\"msg\":\"path \\\\ server\"}";
    const r = extractJsonField(line, "msg", 32);
    try testing.expectEqualStrings("path \\\\ server", r.?);
}

test "extractJsonField: whitespace around colon" {
    const line = "{ \"level\" : \"error\" }";
    const r = extractJsonField(line, "level", 10);
    try testing.expectEqualStrings("error", r.?);
}

// ── stripLiteralAnsi ─────────────────────────────────────────────────────────

test "stripLiteralAnsi: no escapes → src returned unchanged" {
    var buf: [64]u8 = undefined;
    const src = "plain text with no escapes";
    const out = stripLiteralAnsi(&buf, src);
    try testing.expectEqual(src.ptr, out.ptr);
}

test "stripLiteralAnsi: removes single SGR sequence" {
    var buf: [128]u8 = undefined;
    const out = stripLiteralAnsi(&buf, "hello #033[31mworld#033[0m!");
    try testing.expectEqualStrings("hello world!", out);
}

test "stripLiteralAnsi: removes multi-parameter SGR" {
    var buf: [128]u8 = undefined;
    const out = stripLiteralAnsi(&buf, "#033[38;2;255;0;0mred#033[0m");
    try testing.expectEqualStrings("red", out);
}

test "stripLiteralAnsi: real zerolog+journalctl line" {
    var buf: [256]u8 = undefined;
    const line = "core[785424]: #033[90m9:32AM#033[0m #033[32mINF#033[0m #033[1mBuildTopology: 5.8s#033[0m #033[36merror_code=#033[0mUnknown";
    const out = stripLiteralAnsi(&buf, line);
    try testing.expectEqualStrings(
        "core[785424]: 9:32AM INF BuildTopology: 5.8s error_code=Unknown",
        out,
    );
}

test "stripLiteralAnsi: malformed (no `m` terminator) left untouched" {
    var buf: [64]u8 = undefined;
    // First is valid (gets stripped), second is a random `#033[` in text.
    const out = stripLiteralAnsi(&buf, "#033[0mkeep #033[abcxyz still here");
    try testing.expectEqualStrings("keep #033[abcxyz still here", out);
}

// ── nextAlphaToken ───────────────────────────────────────────────────────────

test "nextAlphaToken: walks tokens skipping punctuation and digits" {
    const line = "9:32AM DBG msg";
    const t1 = nextAlphaToken(line, 0).?;
    try testing.expectEqualStrings("AM", line[t1.start..t1.end]);
    const t2 = nextAlphaToken(line, t1.end).?;
    try testing.expectEqualStrings("DBG", line[t2.start..t2.end]);
    const t3 = nextAlphaToken(line, t2.end).?;
    try testing.expectEqualStrings("msg", line[t3.start..t3.end]);
    try testing.expect(nextAlphaToken(line, t3.end) == null);
}

// ── findGrpcCode ─────────────────────────────────────────────────────────────

test "findGrpcCode: extracts name after code=" {
    const line = "rpc error: code = Unavailable desc = connection error";
    const r = findGrpcCode(line).?;
    try testing.expectEqualStrings("Unavailable", line[r.start..r.end]);
}

test "findGrpcCode: OK is returned literally — caller decides" {
    const line = "code = OK";
    const r = findGrpcCode(line).?;
    try testing.expectEqualStrings("OK", line[r.start..r.end]);
}

test "findGrpcCode: does not match error_code=" {
    // `error_code=` has `_` immediately before `code`, so the boundary check
    // rejects it and the scan continues; there is no second `code =` here.
    try testing.expect(findGrpcCode("error_code=Unknown") == null);
}

test "findGrpcCode: does not match without =" {
    try testing.expect(findGrpcCode("this code is fine") == null);
}

test "extractJsonField: non-string value is ignored" {
    try testing.expect(extractJsonField("{\"level\":123}", "level", 10) == null);
}

test "extractJsonField: skips unrelated non-string values before target" {
    const line = "{\"pid\":123,\"ok\":true,\"level\":\"error\"}";
    const r = extractJsonField(line, "level", 10);
    try testing.expectEqualStrings("error", r.?);
}

test "extractJsonField: skips nested unrelated objects before target" {
    const line = "{\"ctx\":{\"level\":\"debug\"},\"level\":\"error\"}";
    const r = extractJsonField(line, "level", 10);
    try testing.expectEqualStrings("error", r.?);
}

// ── chunkMask ────────────────────────────────────────────────────────────────

test "chunkMask: single bit" {
    var mask: @Vector(VecSize, bool) = @splat(false);
    mask[0] = true;
    try testing.expectEqual(@as(u16, 1), chunkMask(mask));
    mask = @splat(false);
    mask[15] = true;
    try testing.expectEqual(@as(u16, 0x8000), chunkMask(mask));
}

test "chunkMask: all bits set" {
    const mask: @Vector(VecSize, bool) = @splat(true);
    try testing.expectEqual(@as(u16, 0xFFFF), chunkMask(mask));
}

test "chunkMask: no bits set" {
    const mask: @Vector(VecSize, bool) = @splat(false);
    try testing.expectEqual(@as(u16, 0), chunkMask(mask));
}

test "chunkMask: alternating bits" {
    var mask: @Vector(VecSize, bool) = @splat(false);
    mask[0] = true;
    mask[2] = true;
    mask[4] = true;
    mask[15] = true;
    const result = chunkMask(mask);
    try testing.expect(result & 1 != 0);
    try testing.expect(result & 4 != 0);
    try testing.expect(result & 16 != 0);
    try testing.expect(result & 0x8000 != 0);
    try testing.expect(result & 2 == 0);
}

// ── findByte edge cases ──────────────────────────────────────────────────────

test "findByte: needle in last byte with start offset" {
    var buf: [VecSize + 5]u8 = undefined;
    @memset(&buf, 'a');
    buf[buf.len - 1] = 'x';
    try testing.expectEqual(@as(?usize, buf.len - 1), findByte(&buf, VecSize - 1, 'x'));
}

test "findByte: start near end, scalar path" {
    const buf = "abcdefghijklmnop";
    try testing.expectEqual(@as(?usize, null), findByte(buf, 15, 'x'));
    try testing.expectEqual(@as(?usize, 15), findByte(buf, 14, 'p'));
}

test "findByte: needle at position 0 with non-zero start" {
    try testing.expectEqual(@as(?usize, 6), findByte("hello world", 6, 'w'));
}

test "findByte: every byte matches" {
    const buf = "xxxxxxxxxxxxxxxxxxxxxx";
    try testing.expectEqual(@as(?usize, 0), findByte(buf, 0, 'x'));
    try testing.expectEqual(@as(?usize, 5), findByte(buf, 5, 'x'));
}

// ── extractJsonField edge cases ──────────────────────────────────────────────

test "extractJsonField: basic key extraction" {
    const line = "{\"key\":\"val\"}";
    const r = extractJsonField(line, "key", 10);
    try testing.expectEqualStrings("val", r.?);
}

test "extractJsonField: backslash at end of buffer is safe" {
    const line = "{\"key\": \\";
    const r = extractJsonField(line, "key", 10);
    try testing.expect(r == null);
}

test "extractJsonField: escaped backslash in key" {
    const line = "{\"k\\\\y\":\"value\"}";
    const r = extractJsonField(line, "k\\\\y", 10);
    try testing.expectEqualStrings("value", r.?);
}

test "extractJsonField: unicode escape in value" {
    const line = "{\"msg\":\"hello \\\\u0041 world\"}";
    const r = extractJsonField(line, "msg", 30);
    try testing.expect(r != null);
}

test "extractJsonField: tab around colon" {
    const line = "{\"level\":\t\"error\"}";
    const r = extractJsonField(line, "level", 10);
    try testing.expectEqualStrings("error", r.?);
}

test "extractJsonField: key starting after escaped quote in previous field" {
    const line = "{\"msg\":\"he\\\"llo\",\"level\":\"info\"}";
    const r = extractJsonField(line, "level", 10);
    try testing.expectEqualStrings("info", r.?);
}

test "extractJsonField: not a JSON object (no opening brace)" {
    try testing.expect(extractJsonField("level: error", "level", 10) == null);
}

test "extractJsonField: truncated JSON" {
    try testing.expect(extractJsonField("{\"lev", "level", 10) == null);
    try testing.expect(extractJsonField("{\"level\"", "level", 10) == null);
    try testing.expect(extractJsonField("{\"level\":", "level", 10) == null);
}

// ── findLogfmtLevel edge cases ───────────────────────────────────────────────

test "findLogfmtLevel: multiple equals signs, level is first" {
    const line = "level=error extra=stuff=more";
    const r = findLogfmtLevel(line).?;
    try testing.expectEqualStrings("error", line[r.start..r.end]);
}

test "findLogfmtLevel: severity= at position 0" {
    const line = "severity=warn time=...";
    const r = findLogfmtLevel(line).?;
    try testing.expectEqualStrings("warn", line[r.start..r.end]);
}

test "findLogfmtLevel: equals inside value does not confuse" {
    const line = "msg=url=http://x level=error";
    const r = findLogfmtLevel(line).?;
    try testing.expectEqualStrings("error", line[r.start..r.end]);
}

test "findLogfmtLevel: key appears as suffix of another key" {
    try testing.expect(findLogfmtLevel("notlevel=warn") == null);
}

// ── isISODate edge cases ─────────────────────────────────────────────────────

test "isISODate: exactly 10 bytes" {
    try testing.expect(isISODate("2024-12-31"));
}

test "isISODate: rejects non-ASCII digits" {
    try testing.expect(!isISODate("2024-12-3١"));
}

test "isISODate: rejects hyphen at wrong positions" {
    try testing.expect(!isISODate("202412-31"));
    try testing.expect(!isISODate("2024-1231"));
}

// ── findBracketedLevel edge cases ────────────────────────────────────────────

test "findBracketedLevel: nested brackets" {
    const r = findBracketedLevel("[[nested]] msg");
    try testing.expect(r != null);
    try testing.expectEqual(@as(usize, 1), r.?.start);
    try testing.expectEqual(@as(usize, 8), r.?.end);
}

test "findBracketedLevel: single char inside brackets" {
    const r = findBracketedLevel("[X] something").?;
    try testing.expectEqual(@as(usize, 1), r.start);
    try testing.expectEqual(@as(usize, 2), r.end);
}

test "stripLiteralAnsi: leaves a line without escapes untouched" {
    var dst: [256]u8 = undefined;
    const src = "2026-08-25 12:00:00 [INFO] nothing to strip here #not-an-escape";
    const got = stripLiteralAnsi(&dst, src);
    try std.testing.expectEqualStrings(src, got);
    // Returned as-is, not copied.
    try std.testing.expectEqual(src.ptr, got.ptr);
}

test "stripLiteralAnsi: removes well-formed sequences and keeps the rest" {
    var dst: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "hello world",
        stripLiteralAnsi(&dst, "#033[32mhello#033[0m world"),
    );
    try std.testing.expectEqualStrings(
        "abc",
        stripLiteralAnsi(&dst, "#033[1;38;2;255;0;0ma#033[0mb#033[4:3mc"),
    );
}

test "stripLiteralAnsi: leaves malformed runs in place" {
    var dst: [256]u8 = undefined;
    // No terminating `m`.
    try std.testing.expectEqualStrings("x #033[32 y", stripLiteralAnsi(&dst, "x #033[32 y"));
    // `#` that isn't the start of a sequence.
    try std.testing.expectEqualStrings("cost #033 usd", stripLiteralAnsi(&dst, "cost #033 usd"));
    try std.testing.expectEqualStrings("## #0 #03", stripLiteralAnsi(&dst, "## #0 #03"));
}

test "stripLiteralAnsi: a sequence at either end" {
    var dst: [256]u8 = undefined;
    try std.testing.expectEqualStrings("tail", stripLiteralAnsi(&dst, "#033[31mtail"));
    try std.testing.expectEqualStrings("head", stripLiteralAnsi(&dst, "head#033[0m"));
    try std.testing.expectEqualStrings("", stripLiteralAnsi(&dst, "#033[0m"));
}

test "stripLiteralAnsi: refuses to truncate when dst is too small" {
    var dst: [4]u8 = undefined;
    const src = "#033[32mhello world this will not fit";
    // Falls back to the original bytes rather than desynchronising offsets.
    try std.testing.expectEqualStrings(src, stripLiteralAnsi(&dst, src));
}

test "stripLiteralAnsi: many sequences in one line" {
    var dst: [512]u8 = undefined;
    var src: [512]u8 = undefined;
    var w: usize = 0;
    for (0..20) |i| {
        const part = "#033[3Xm";
        @memcpy(src[w..][0..part.len], part);
        src[w + 6] = '0' + @as(u8, @intCast(i % 10)); // the `X` placeholder
        w += part.len;
        src[w] = 'a' + @as(u8, @intCast(i % 26));
        w += 1;
    }
    const got = stripLiteralAnsi(&dst, src[0..w]);
    try std.testing.expectEqual(@as(usize, 20), got.len);
}
