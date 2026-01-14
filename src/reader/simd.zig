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
        const chunk: @Vector(VecSize, u8) = buf[i .. i + VecSize].*;
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
