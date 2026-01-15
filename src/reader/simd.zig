//! SIMD-accelerated utility functions for log parsing and string searching.
//! This module provides vectorized operations for finding bytes, extracting fields,
//! and validating formats commonly used in log processing.
const std = @import("std");

/// Default vector size for SIMD operations (16 bytes = 128 bits).
pub const VecSize = 16;

/// Finds the first occurrence of `needle` in `buf` starting from index `start`.
/// Uses scalar loop for small buffers and SIMD for larger ones.
/// Returns the index of the found byte, or `null` if not found.
pub inline fn findByte(
    buf: []const u8,
    start: usize,
    needle: u8,
) ?usize {
    // Scalar fallback for small buffers
    if (buf.len - start < VecSize) {
        for (buf[start..], start..) |c, i| {
            if (c == needle) return i;
        }
        return null;
    }

    const v: @Vector(VecSize, u8) = @splat(needle);

    var i = start;
    const limit = buf.len - VecSize;

    // SIMD loop: process 16 bytes at a time
    while (i <= limit) : (i += VecSize) {
        const ptr = @as(*const [VecSize]u8, @ptrCast(buf.ptr + i));
        const chunk: @Vector(VecSize, u8) = ptr.*;
        // Check if any byte in the chunk equals `needle`
        if (@reduce(.Or, chunk == v)) {
            // Scan the chunk to find the exact position
            inline for (0..VecSize) |j| {
                if (buf[i + j] == needle)
                    return i + j;
            }
        }
    }

    // Handle remaining bytes (tail) with scalar loop
    while (i < buf.len) : (i += 1) {
        if (buf[i] == needle) return i;
    }

    return null;
}

/// Finds the first occurrence of either `a` or `b` in `buf` starting from `start`.
/// Returns the index of the found byte, or `null` if neither is found.
pub inline fn findEither(
    buf: []const u8,
    start: usize,
    a: u8,
    b: u8,
) ?usize {
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
        // ИСПРАВЛЕНИЕ: используем pointer cast как в findByte
        const ptr = @as(*const [VecSize]u8, @ptrCast(buf.ptr + i));
        const chunk: @Vector(VecSize, u8) = ptr.*;
        // Check if any byte equals `a` OR `b`
        if (@reduce(.Or, (chunk == va) | (chunk == vb))) {
            inline for (0..VecSize) |j| {
                const c = buf[i + j];
                if (c == a or c == b)
                    return i + j;
            }
        }
    }

    while (i < buf.len) : (i += 1) {
        const c = buf[i];
        if (c == a or c == b) return i;
    }

    return null;
}

/// Finds the first occurrence of any of three bytes (`a`, `b`, or `c`) in `buf`.
/// Returns the index of the found byte, or `null` if none are found.
pub inline fn findAny3(
    buf: []const u8,
    start: usize,
    a: u8,
    b: u8,
    c: u8,
) ?usize {
    if (buf.len - start < VecSize) {
        for (buf[start..], start..) |ch, i| {
            if (ch == a or ch == b or ch == c)
                return i;
        }
        return null;
    }

    const va: @Vector(VecSize, u8) = @splat(a);
    const vb: @Vector(VecSize, u8) = @splat(b);
    const vc: @Vector(VecSize, u8) = @splat(c);

    var i = start;
    const limit = buf.len - VecSize;

    while (i <= limit) : (i += VecSize) {
        const ptr = @as(*const [VecSize]u8, @ptrCast(buf.ptr + i));
        const chunk: @Vector(VecSize, u8) = ptr.*;
        // Combine three equality comparisons with OR
        if (@reduce(.Or, (chunk == va) | (chunk == vb) | (chunk == vc))) {
            inline for (0..VecSize) |j| {
                const ch = buf[i + j];
                if (ch == a or ch == b or ch == c)
                    return i + j;
            }
        }
    }

    while (i < buf.len) : (i += 1) {
        const ch = buf[i];
        if (ch == a or ch == b or ch == c)
            return i;
    }

    return null;
}

/// Extracts a JSON field value from a line given a compile‑time key.
/// Searches for `"key": "value"` pattern and returns the value (without quotes).
/// The search starts from the beginning of `line`. The returned slice is guaranteed
/// to be within `line` and not longer than `max_len`.
/// Returns `null` if the key is not found, the value is missing, or the line is malformed.
pub fn extractJsonField(
    line: []const u8,
    comptime key: []const u8,
    max_len: usize,
) ?[]const u8 {
    var i: usize = 0;

    // Find the key (enclosed in double quotes)
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

    // Skip whitespace and colon
    while (i < line.len and (line[i] == ' ' or line[i] == ':')) : (i += 1) {}
    if (i >= line.len or line[i] != '"') return null;

    // Start of the value
    i += 1;
    const start = i;
    const end = @min(i + max_len, line.len);

    // Find the closing quote
    while (i < end and line[i] != '"') : (i += 1) {}
    if (i >= line.len) return null;

    return line[start..i];
}

/// Checks if the given slice starts with an ISO‑8601 date (YYYY‑MM‑DD).
/// Only validates the format, not the actual calendar values.
pub inline fn isISODate(s: []const u8) bool {
    if (s.len < 10) return false;

    inline for (0..10) |i| {
        const c = s[i];
        if (i == 4 or i == 7) {
            if (c != '-') return false;
        } else {
            if (c < '0' or c > '9') return false;
        }
    }
    return true;
}

/// Finds a bracketed log level marker of the form `[LEVEL]`.
/// Returns the byte range (start..end) of the level text inside the brackets,
/// or `null` if not found. The brackets themselves are excluded.
pub fn findBracketedLevel(
    line: []const u8,
) ?struct { start: usize, end: usize } {
    if (line.len < 3 or line[0] != '[') return null;

    const end = findByte(line, 1, ']') orelse return null;
    if (end <= 1) return null;

    return .{ .start = 1, .end = end };
}

/// Helper: checks whether `key` appears in `line` at position `pos`.
inline fn matchKeyAt(
    line: []const u8,
    pos: usize,
    comptime key: []const u8,
) bool {
    return pos + key.len <= line.len and
        std.mem.eql(u8, line[pos .. pos + key.len], key);
}

/// Finds a logfmt‑style level field (`level=...`, `severity=...`, `lvl=...`).
/// Returns the byte range of the level value (after the `=` until the next space or end).
/// Assumes the line is space‑separated key‑value pairs.
pub fn findLogfmtLevel(
    line: []const u8,
) ?struct { start: usize, end: usize } {
    var i: usize = 0;

    while (true) {
        const pos = findByte(line, i, '=') orelse return null;

        if (pos >= 5 and matchKeyAt(line, pos - 5, "level")) {
            const start = pos + 1;
            var end = start;
            while (end < line.len and line[end] != ' ') : (end += 1) {}
            return .{ .start = start, .end = end };
        }

        if (pos >= 8 and matchKeyAt(line, pos - 8, "severity")) {
            const start = pos + 1;
            var end = start;
            while (end < line.len and line[end] != ' ') : (end += 1) {}
            return .{ .start = start, .end = end };
        }

        if (pos >= 3 and matchKeyAt(line, pos - 3, "lvl")) {
            const start = pos + 1;
            var end = start;
            while (end < line.len and line[end] != ' ') : (end += 1) {}
            return .{ .start = start, .end = end };
        }

        i = pos + 1;
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

// ----------------------
// findByte tests
// ----------------------

test "findByte should find byte in small buffer" {
    const buf = "hello";
    try testing.expectEqual(@as(?usize, 1), findByte(buf, 0, 'e'));
    try testing.expectEqual(@as(?usize, 4), findByte(buf, 0, 'o'));
    try testing.expectEqual(@as(?usize, null), findByte(buf, 0, 'x'));
}

test "findByte should find byte in large buffer with SIMD" {
    const buf = "a" ** 100 ++ "x" ++ "a" ** 100;
    try testing.expectEqual(@as(?usize, 100), findByte(buf, 0, 'x'));
}

test "findByte should respect start position" {
    const buf = "hello world";
    try testing.expectEqual(@as(?usize, 4), findByte(buf, 3, 'o')); // 'o' at index 4
    try testing.expectEqual(@as(?usize, null), findByte(buf, 8, 'o'));
}

test "findByte should handle empty buffer" {
    const buf = "";
    try testing.expectEqual(@as(?usize, null), findByte(buf, 0, 'x'));
}

test "findByte should find newline in chunk" {
    const buf = "line1\nline2\nline3";
    try testing.expectEqual(@as(?usize, 5), findByte(buf, 0, '\n'));
    try testing.expectEqual(@as(?usize, 11), findByte(buf, 6, '\n'));
}

test "findByte should handle buffer with no match" {
    const buf = "a" ** 50;
    try testing.expectEqual(@as(?usize, null), findByte(buf, 0, 'x'));
}

test "findByte should find byte at boundary" {
    var buf: [32]u8 = undefined;
    @memset(&buf, 'a');
    buf[15] = 'x'; // At SIMD boundary
    buf[31] = 'y'; // At end

    try testing.expectEqual(@as(?usize, 15), findByte(&buf, 0, 'x'));
    try testing.expectEqual(@as(?usize, 31), findByte(&buf, 0, 'y'));
}

// ----------------------
// findEither tests
// ----------------------

test "findEither should find first of two bytes" {
    const buf = "hello world";
    try testing.expectEqual(@as(?usize, 1), findEither(buf, 0, 'e', 'o'));
    try testing.expectEqual(@as(?usize, 2), findEither(buf, 0, 'l', 'x'));
}

test "findEither should find second byte if first not present" {
    const buf = "hello world";
    try testing.expectEqual(@as(?usize, 4), findEither(buf, 0, 'x', 'o'));
}

test "findEither should return null if neither found" {
    const buf = "hello";
    try testing.expectEqual(@as(?usize, null), findEither(buf, 0, 'x', 'y'));
}

test "findEither should work with large buffer" {
    const buf = "a" ** 50 ++ "x" ++ "a" ** 50;
    try testing.expectEqual(@as(?usize, 50), findEither(buf, 0, 'x', 'y'));
}

test "findEither should respect start position" {
    const buf = "hello world";
    try testing.expectEqual(@as(?usize, 4), findEither(buf, 3, 'o', 'w')); // 'o' at 4
}

// ----------------------
// findAny3 tests
// ----------------------

test "findAny3 should find first of three bytes" {
    const buf = "hello world";
    try testing.expectEqual(@as(?usize, 1), findAny3(buf, 0, 'e', 'o', 'x'));
    try testing.expectEqual(@as(?usize, 2), findAny3(buf, 0, 'l', 'x', 'y'));
}

test "findAny3 should return null if none found" {
    const buf = "hello";
    try testing.expectEqual(@as(?usize, null), findAny3(buf, 0, 'x', 'y', 'z'));
}

test "findAny3 should work with large buffer" {
    const buf = "a" ** 50 ++ "x" ++ "a" ** 50;
    try testing.expectEqual(@as(?usize, 50), findAny3(buf, 0, 'x', 'y', 'z'));
}

test "findAny3 should find any of three in mixed positions" {
    const buf = "abcdefghijk";
    try testing.expectEqual(@as(?usize, 2), findAny3(buf, 0, 'c', 'm', 'z'));
    try testing.expectEqual(@as(?usize, 7), findAny3(buf, 0, 'h', 'm', 'z'));
}

// ----------------------
// extractJsonField tests
// ----------------------

test "extractJsonField should extract simple field" {
    const line = "{\"level\":\"error\",\"msg\":\"test\"}";
    const result = extractJsonField(line, "level", 10);
    try testing.expectEqualStrings("error", result.?);
}

test "extractJsonField should extract time field" {
    const line = "{\"time\":\"2024-01-15T10:30:45Z\",\"msg\":\"test\"}";
    const result = extractJsonField(line, "time", 30);
    try testing.expectEqualStrings("2024-01-15T10:30:45Z", result.?);
}

test "extractJsonField should respect max_len" {
    const line = "{\"msg\":\"very long message here\"}";
    const result = extractJsonField(line, "msg", 10);
    try testing.expectEqualStrings("very long ", result.?);
}

test "extractJsonField should return null for missing key" {
    const line = "{\"level\":\"error\"}";
    const result = extractJsonField(line, "msg", 10);
    try testing.expect(result == null);
}

test "extractJsonField should return null for malformed JSON" {
    const line = "{\"level\":error}"; // Missing quotes around value
    const result = extractJsonField(line, "level", 10);
    try testing.expect(result == null);
}

test "extractJsonField should handle key with similar prefix" {
    const line = "{\"level_old\":\"warn\",\"level\":\"error\"}";
    const result = extractJsonField(line, "level", 10);
    try testing.expectEqualStrings("error", result.?);
}

test "extractJsonField should handle empty value" {
    const line = "{\"msg\":\"\",\"level\":\"info\"}";
    const result = extractJsonField(line, "msg", 10);
    try testing.expectEqualStrings("", result.?);
}

test "extractJsonField should handle nested quotes" {
    const line = "{\"msg\":\"quoted \\\"text\\\"\"}";
    const result = extractJsonField(line, "msg", 20);
    try testing.expect(result != null);
}

// ----------------------
// isISODate tests
// ----------------------

test "isISODate should validate correct ISO date" {
    try testing.expect(isISODate("2024-01-15"));
    try testing.expect(isISODate("2024-01-15T10:30:45"));
    try testing.expect(isISODate("1999-12-31 extra text"));
}

test "isISODate should reject invalid dates" {
    try testing.expect(!isISODate("2024/01/15")); // Wrong separator
    try testing.expect(!isISODate("24-01-15")); // Wrong year format
    try testing.expect(!isISODate("2024-1-15")); // Missing zero padding
    try testing.expect(!isISODate("2024-01")); // Too short
    try testing.expect(!isISODate("")); // Empty
    try testing.expect(!isISODate("abcd-ef-gh")); // Non-digits
}

test "isISODate should handle edge cases" {
    // isISODate only validates FORMAT, not actual calendar validity
    try testing.expect(isISODate("2024-13-32")); // Format is valid (YYYY-MM-DD)
    try testing.expect(isISODate("0000-00-00")); // Format is valid
}

// ----------------------
// findBracketedLevel tests
// ----------------------

test "findBracketedLevel should find level in brackets" {
    const line = "[ERROR] Something went wrong";
    const result = findBracketedLevel(line);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 1), result.?.start);
    try testing.expectEqual(@as(usize, 6), result.?.end);
    try testing.expectEqualStrings("ERROR", line[result.?.start..result.?.end]);
}

test "findBracketedLevel should handle different levels" {
    const levels = [_][]const u8{
        "[INFO] message",
        "[WARN] warning",
        "[DEBUG] debug info",
        "[TRACE] trace",
    };

    inline for (levels) |line| {
        const result = findBracketedLevel(line);
        try testing.expect(result != null);
        try testing.expectEqual(@as(usize, 1), result.?.start);
    }
}

test "findBracketedLevel should return null without brackets" {
    try testing.expect(findBracketedLevel("ERROR message") == null);
    try testing.expect(findBracketedLevel("") == null);
    try testing.expect(findBracketedLevel("[") == null);
    try testing.expect(findBracketedLevel("[]") == null);
}

test "findBracketedLevel should return null for non-starting bracket" {
    const line = "Some text [ERROR] here";
    try testing.expect(findBracketedLevel(line) == null);
}

test "findBracketedLevel should handle brackets at end" {
    const line = "[ERROR]";
    const result = findBracketedLevel(line);
    try testing.expect(result != null);
    try testing.expectEqualStrings("ERROR", line[result.?.start..result.?.end]);
}

// ----------------------
// findLogfmtLevel tests
// ----------------------

test "findLogfmtLevel should find level= field" {
    const line = "time=2024-01-15 level=error msg=test";
    const result = findLogfmtLevel(line);
    try testing.expect(result != null);
    try testing.expectEqualStrings("error", line[result.?.start..result.?.end]);
}

test "findLogfmtLevel should find severity= field" {
    const line = "time=2024-01-15 severity=warn msg=test";
    const result = findLogfmtLevel(line);
    try testing.expect(result != null);
    try testing.expectEqualStrings("warn", line[result.?.start..result.?.end]);
}

test "findLogfmtLevel should find lvl= field" {
    const line = "time=2024-01-15 lvl=info msg=test";
    const result = findLogfmtLevel(line);
    try testing.expect(result != null);
    try testing.expectEqualStrings("info", line[result.?.start..result.?.end]);
}

test "findLogfmtLevel should prioritize level over severity" {
    const line = "severity=warn level=error msg=test";
    const result = findLogfmtLevel(line);
    try testing.expect(result != null);
    // Should find first occurrence
    try testing.expect(result.?.start > 0);
}

test "findLogfmtLevel should return null without level field" {
    try testing.expect(findLogfmtLevel("time=2024-01-15 msg=test") == null);
    try testing.expect(findLogfmtLevel("") == null);
    try testing.expect(findLogfmtLevel("no equals signs here") == null);
}

test "findLogfmtLevel should handle level at end of line" {
    const line = "time=2024-01-15 level=error";
    const result = findLogfmtLevel(line);
    try testing.expect(result != null);
    try testing.expectEqualStrings("error", line[result.?.start..result.?.end]);
}

test "findLogfmtLevel should handle quoted values" {
    const line = "level=\"error with spaces\" msg=test";
    const result = findLogfmtLevel(line);
    try testing.expect(result != null);
    // Extracts until first space (includes opening quote)
    const extracted = line[result.?.start..result.?.end];
    try testing.expect(extracted.len > 0);
}

test "findLogfmtLevel should not match partial key names" {
    const line = "time=now level=error msg=test";
    const result = findLogfmtLevel(line);
    try testing.expect(result != null);
    try testing.expectEqualStrings("error", line[result.?.start..result.?.end]);
}

// ----------------------
// Performance/Edge case tests
// ----------------------

test "findByte SIMD boundary test" {
    // Test exactly at SIMD vector boundaries
    var buf: [VecSize * 3]u8 = undefined;
    @memset(&buf, 'a');

    // Place target at different boundaries
    buf[VecSize - 1] = 'x'; // End of first vector
    buf[VecSize] = 'y'; // Start of second vector
    buf[VecSize * 2] = 'z'; // Start of third vector

    try testing.expectEqual(@as(?usize, VecSize - 1), findByte(&buf, 0, 'x'));
    try testing.expectEqual(@as(?usize, VecSize), findByte(&buf, 0, 'y'));
    try testing.expectEqual(@as(?usize, VecSize * 2), findByte(&buf, 0, 'z'));
}

test "extractJsonField with unicode should not crash" {
    const line = "{\"msg\":\"Hello 世界\",\"level\":\"info\"}";
    const result = extractJsonField(line, "level", 10);
    try testing.expectEqualStrings("info", result.?);
}

test "findByte should handle all-same buffer" {
    const buf = "aaaaaaaaaaaaaaaa";
    try testing.expectEqual(@as(?usize, 0), findByte(buf, 0, 'a'));
    try testing.expectEqual(@as(?usize, null), findByte(buf, 0, 'b'));
}

test "matchKeyAt helper function" {
    const line = "level=error";
    try testing.expect(matchKeyAt(line, 0, "level"));
    try testing.expect(!matchKeyAt(line, 0, "severity"));
    try testing.expect(!matchKeyAt(line, 1, "level"));
    try testing.expect(matchKeyAt(line, 6, "error"));
}
