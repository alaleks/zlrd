//! Native LZ4 block-format decompressor for journal data objects.
//!
//! systemd compresses individual data payloads with the LZ4 block format —
//! NOT the LZ4 frame format. The on-disk payload of a compressed data object
//! is laid out as:
//!
//!     [ 8 bytes  : little-endian u64, uncompressed size ]
//!     [ N bytes  : LZ4 block stream                     ]
//!
//! Reference: `src/basic/compress.c` in upstream systemd, function
//! `compress_blob_lz4` (writer) / `decompress_blob_lz4` (reader).
//!
//! The block format itself is a sequence of "sequences"; each sequence is:
//!
//!     [ token byte:       high nibble = literal length (0..15)
//!                         low  nibble = match  length (0..15) ]
//!     [ extra literal len bytes — only if literal nibble == 15 ]
//!     [ literal bytes ]
//!     [ 2-byte LE match offset ]    (omitted on the very last sequence)
//!     [ extra match len bytes — only if match nibble == 15 ]
//!
//! Each "extra length" run reads bytes until one < 255 is seen, summing them
//! all into the length. Match length is `(nibble + 4) + extras`. The first 4
//! bytes of every match are mandatory because the format's encoding floor is
//! 4-byte matches.

const std = @import("std");

pub const Error = error{
    /// The 8-byte size prefix is missing or impossibly large.
    InvalidSize,
    /// The LZ4 stream tried to read past its bounds.
    Truncated,
    /// A match referenced a position before the start of the output buffer.
    InvalidOffset,
    /// The decoded size didn't match the declared size.
    SizeMismatch,
} || std.mem.Allocator.Error;

/// Hard upper bound on a single decompressed data payload. Real journal
/// entries are well under this (a few KB typically); the cap is just to
/// reject malformed inputs that claim absurd sizes.
pub const max_decompressed_size: usize = 16 * 1024 * 1024;

/// Decompresses a systemd-wrapped LZ4 payload (size-prefixed block). The
/// returned slice is owned by `allocator`.
pub fn decompressSystemd(allocator: std.mem.Allocator, src: []const u8) Error![]u8 {
    if (src.len < 8) return error.InvalidSize;
    const declared = std.mem.readInt(u64, src[0..8], .little);
    if (declared > max_decompressed_size) return error.InvalidSize;
    const out = try allocator.alloc(u8, @intCast(declared));
    errdefer allocator.free(out);
    const written = try decompressBlock(src[8..], out);
    if (written != out.len) return error.SizeMismatch;
    return out;
}

/// Decompresses a bare LZ4 block into the caller-provided buffer. Returns the
/// number of bytes written. The buffer must be sized to the (known) original
/// length.
pub fn decompressBlock(src: []const u8, dst: []u8) Error!usize {
    var sp: usize = 0;
    var dp: usize = 0;

    while (true) {
        if (sp >= src.len) return error.Truncated;
        const token = src[sp];
        sp += 1;

        // ── literal run ──────────────────────────────────────────────────
        var lit_len: usize = token >> 4;
        if (lit_len == 15) {
            while (true) {
                if (sp >= src.len) return error.Truncated;
                const b = src[sp];
                sp += 1;
                lit_len += b;
                // Bound the running sum so a malformed stream with many 0xFF
                // bytes can't overflow `usize` on 32-bit builds.
                if (lit_len > dst.len - dp + 1) return error.Truncated;
                if (b != 0xFF) break;
            }
        }
        if (sp + lit_len > src.len) return error.Truncated;
        if (dp + lit_len > dst.len) return error.Truncated;
        @memcpy(dst[dp..][0..lit_len], src[sp..][0..lit_len]);
        sp += lit_len;
        dp += lit_len;

        // The final sequence has only literals — when we've consumed all of
        // the source, we're done.
        if (sp == src.len) break;

        // ── match copy ───────────────────────────────────────────────────
        if (sp + 2 > src.len) return error.Truncated;
        const offset: usize = @as(usize, src[sp]) | (@as(usize, src[sp + 1]) << 8);
        sp += 2;
        if (offset == 0 or offset > dp) return error.InvalidOffset;

        var match_len: usize = (token & 0x0F) + 4;
        if ((token & 0x0F) == 15) {
            while (true) {
                if (sp >= src.len) return error.Truncated;
                const b = src[sp];
                sp += 1;
                match_len += b;
                if (match_len > dst.len - dp + 1) return error.Truncated;
                if (b != 0xFF) break;
            }
        }
        if (dp + match_len > dst.len) return error.Truncated;

        // Byte-by-byte copy because matches with offset < match_len overlap
        // their own output and must propagate forward (RLE-style).
        const match_src = dp - offset;
        var i: usize = 0;
        while (i < match_len) : (i += 1) {
            dst[dp + i] = dst[match_src + i];
        }
        dp += match_len;
    }

    return dp;
}

// ─── Test helpers (exported for the journal reader's own tests) ─────────

/// Encodes `input` as a single all-literal LZ4 block. Useful for crafting
/// known-good fixtures in tests without depending on a real encoder.
/// Exported so `reader.zig`'s SyntheticBuilder can reuse it.
pub fn encodeAllLiterals(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var lit_len = input.len;
    // Token: high nibble carries literal length; if >= 15, the extra bytes
    // follow.
    const token_hi: u8 = if (lit_len < 15) @intCast(lit_len) else 15;
    try out.append(allocator, token_hi << 4);
    if (lit_len >= 15) {
        lit_len -= 15;
        while (lit_len >= 255) {
            try out.append(allocator, 0xFF);
            lit_len -= 255;
        }
        try out.append(allocator, @intCast(lit_len));
    }
    try out.appendSlice(allocator, input);
    return out.toOwnedSlice(allocator);
}

// ─── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "all-literal block round-trips" {
    const payload = "MESSAGE=hello world from lz4";
    const block = try encodeAllLiterals(testing.allocator, payload);
    defer testing.allocator.free(block);

    var dst: [64]u8 = undefined;
    const n = try decompressBlock(block, dst[0..payload.len]);
    try testing.expectEqual(payload.len, n);
    try testing.expectEqualStrings(payload, dst[0..payload.len]);
}

test "match copy reproduces a repeated run" {
    // Hand-craft: literal "AB" + match (offset 2, len 4) → "ABABAB",
    // followed by a final empty-literals sequence to terminate the block.
    // Token1: literals=2, match nibble=0 (match_len = 0 + 4 = 4) → 0x20.
    // Token2: literals=0 → 0x00. (Last sequence is literals-only.)
    const block = [_]u8{ 0x20, 'A', 'B', 0x02, 0x00, 0x00 };
    var dst: [6]u8 = undefined;
    const n = try decompressBlock(&block, &dst);
    try testing.expectEqual(@as(usize, 6), n);
    try testing.expectEqualStrings("ABABAB", &dst);
}

test "decompressSystemd validates the size prefix and round-trips" {
    const payload = "TEMPERATURE=42";
    const block = try encodeAllLiterals(testing.allocator, payload);
    defer testing.allocator.free(block);

    var wrapped = std.ArrayList(u8).empty;
    defer wrapped.deinit(testing.allocator);
    var size_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &size_bytes, payload.len, .little);
    try wrapped.appendSlice(testing.allocator, &size_bytes);
    try wrapped.appendSlice(testing.allocator, block);

    const out = try decompressSystemd(testing.allocator, wrapped.items);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(payload, out);
}

test "rejects an impossibly large declared size" {
    var src: [16]u8 = .{0} ** 16;
    std.mem.writeInt(u64, src[0..8], std.math.maxInt(u64), .little);
    try testing.expectError(error.InvalidSize, decompressSystemd(testing.allocator, &src));
}

test "rejects a truncated literal run" {
    // Token claims 5 literal bytes but only 3 follow.
    const block = [_]u8{ 0x50, 'a', 'b', 'c' };
    var dst: [5]u8 = undefined;
    try testing.expectError(error.Truncated, decompressBlock(&block, &dst));
}

test "rejects a match with zero offset" {
    // Token: 0 literals, match nibble = 1 (match_len = 5). Offset = 0.
    const block = [_]u8{ 0x01, 0x00, 0x00 };
    var dst: [5]u8 = undefined;
    try testing.expectError(error.InvalidOffset, decompressBlock(&block, &dst));
}
