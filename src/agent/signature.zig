//! Level extraction + normalized error-signature hashing for first-seen alerting.
//!
//! Level extraction reuses the simd-accelerated key scanners that the reader
//! package already uses to detect levels in JSON, bracketed plain text, and
//! logfmt input.

const std = @import("std");
const flags = @import("flags");
const simd = @import("simd");

/// Extracts the log level from a line in any of the three supported formats.
/// Returns null when no recognizable level field is present.
pub fn extractLevel(line: []const u8) ?flags.Level {
    if (line.len == 0) return null;

    if (line[0] == '{') {
        if (simd.extractJsonField(line, "level", 16)) |v| {
            return flags.parseLevelInsensitive(v);
        }
        return null;
    }
    if (line[0] == '[') {
        if (simd.findBracketedLevel(line)) |r| {
            return flags.parseLevelInsensitive(line[r.start..r.end]);
        }
        return null;
    }
    if (simd.findLogfmtLevel(line)) |r| {
        return flags.parseLevelInsensitive(line[r.start..r.end]);
    }
    return null;
}

/// Returns true if the level should be treated as an error condition for
/// rate-rule purposes: any of error, fatal, panic.
pub fn isErrorLevel(level: flags.Level) bool {
    return switch (level) {
        .Error, .Fatal, .Panic => true,
        else => false,
    };
}

/// Computes a stable normalized signature for an error line so two structurally
/// identical messages with different IDs/timestamps map to the same hash.
///
/// Normalization is intentionally light:
///   - ASCII letters are lowercased.
///   - Runs of digits collapse to a single `#`.
///   - Hex runs of length >= 8 (UUIDs, request IDs) collapse to `<id>`.
///   - Other bytes are passed through verbatim.
///
/// Returns the SipHash64 digest of the normalized buffer.
pub fn errorSignature(line: []const u8) u64 {
    var buf: [4096]u8 = undefined;
    const n = normalizeInto(&buf, line);
    return std.hash.Wyhash.hash(0, buf[0..n]);
}

/// Writes the normalized form of `line` into `dest` and returns the number of
/// bytes written. The output is truncated if `dest` is too small.
pub fn normalizeInto(dest: []u8, line: []const u8) usize {
    var i: usize = 0;
    var out: usize = 0;
    while (i < line.len and out < dest.len) {
        const c = line[i];

        if (isAsciiDigit(c)) {
            // Collapse a run of digits to a single '#'.
            while (i < line.len and isAsciiDigit(line[i])) : (i += 1) {}
            if (out < dest.len) {
                dest[out] = '#';
                out += 1;
            }
            continue;
        }

        if (isHexDigit(c)) {
            // Check for a hex run of length >= 8 (UUIDs, request IDs, hashes).
            var j = i;
            while (j < line.len and isHexDigit(line[j])) : (j += 1) {}
            if (j - i >= 8) {
                const tag = "<id>";
                for (tag) |b| {
                    if (out >= dest.len) break;
                    dest[out] = b;
                    out += 1;
                }
                i = j;
                continue;
            }
        }

        dest[out] = std.ascii.toLower(c);
        out += 1;
        i += 1;
    }
    return out;
}

inline fn isAsciiDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

inline fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

const testing = std.testing;

test "extractLevel: json" {
    const line = "{\"time\":\"2024-01-20T12:00:00Z\",\"level\":\"error\",\"msg\":\"x\"}";
    try testing.expectEqual(flags.Level.Error, extractLevel(line).?);
}

test "extractLevel: bracketed" {
    // Same shape the reader package recognizes: bracketed level must lead the line.
    const line = "[ERROR] something broke";
    try testing.expectEqual(flags.Level.Error, extractLevel(line).?);
}

test "extractLevel: logfmt" {
    const line = "time=2024-01-20T12:00:00Z level=warn msg=\"slow\"";
    try testing.expectEqual(flags.Level.Warn, extractLevel(line).?);
}

test "extractLevel: missing returns null" {
    try testing.expect(extractLevel("hello world") == null);
    try testing.expect(extractLevel("") == null);
}

test "isErrorLevel: only error/fatal/panic" {
    try testing.expect(isErrorLevel(.Error));
    try testing.expect(isErrorLevel(.Fatal));
    try testing.expect(isErrorLevel(.Panic));
    try testing.expect(!isErrorLevel(.Warn));
    try testing.expect(!isErrorLevel(.Info));
    try testing.expect(!isErrorLevel(.Trace));
}

test "normalizeInto: collapses digit runs" {
    var buf: [128]u8 = undefined;
    const n = normalizeInto(&buf, "user 42 failed in 1234ms");
    try testing.expectEqualStrings("user # failed in #ms", buf[0..n]);
}

test "normalizeInto: collapses hex runs of length >= 8" {
    var buf: [128]u8 = undefined;
    const n = normalizeInto(&buf, "req=abcdef0123 user=42");
    // "abcdef0123" is 10 hex chars -> <id>; "42" is digits -> #
    try testing.expectEqualStrings("req=<id> user=#", buf[0..n]);
}

test "normalizeInto: short hex passes through (case-lowered)" {
    var buf: [128]u8 = undefined;
    const n = normalizeInto(&buf, "code=AbC");
    // 3 hex chars is < 8, so they pass through, lowercased.
    try testing.expectEqualStrings("code=abc", buf[0..n]);
}

test "errorSignature: identical structure yields identical hash" {
    const a = errorSignature("connection refused to 10.0.0.1:5432 in 1500ms");
    const b = errorSignature("connection refused to 10.0.0.2:5433 in 2200ms");
    try testing.expectEqual(a, b);
}

test "errorSignature: distinct messages yield distinct hashes" {
    const a = errorSignature("connection refused");
    const b = errorSignature("permission denied");
    try testing.expect(a != b);
}
