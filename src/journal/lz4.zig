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
                // Bound the running sum against the space actually left in
                // `dst`, so a malformed stream with a long 0xFF run can
                // neither overflow `usize` nor spin.
                if (lit_len > dst.len - dp) return error.Truncated;
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
                if (match_len > dst.len - dp) return error.Truncated;
                if (b != 0xFF) break;
            }
        }
        if (dp + match_len > dst.len) return error.Truncated;

        const match_src = dp - offset;
        if (offset >= match_len) {
            // Source and destination ranges are disjoint — the common case
            // for real matches, and worth a vectorized copy.
            @memcpy(dst[dp..][0..match_len], dst[match_src..][0..match_len]);
        } else {
            // The match overlaps its own output: the format encodes runs
            // this way, so the copy has to propagate forward one byte at a
            // time rather than reading a stale snapshot.
            for (0..match_len) |i| dst[dp + i] = dst[match_src + i];
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

test "rejects a match reaching before the start of the output" {
    // 0 literals, match_len 4, offset 5 — but nothing has been produced yet,
    // so the match would read from before `dst`.
    const block = [_]u8{ 0x00, 0x05, 0x00 };
    var dst: [8]u8 = undefined;
    try testing.expectError(error.InvalidOffset, decompressBlock(&block, &dst));
}

test "extended match length (nibble 15 plus continuation bytes)" {
    // Literals "ABCD", then a match with the match nibble saturated:
    // match_len = (15 + 4) + 1 = 20, offset 4 → a 4-byte repeating run.
    // Layout is token, literals, 2-byte offset, THEN the match-length
    // continuation — getting that order wrong silently shifts the stream.
    const block = [_]u8{ 0x4F, 'A', 'B', 'C', 'D', 0x04, 0x00, 0x01, 0x00 };
    var dst: [24]u8 = undefined;
    const n = try decompressBlock(&block, &dst);
    try testing.expectEqual(@as(usize, 24), n);
    try testing.expectEqualStrings("ABCD" ** 6, &dst);
}

test "overlapping match with offset 1 expands to a run" {
    // 1 literal 'Z', match_len 7, offset 1 → each copied byte must see the
    // byte written one step earlier, not a pre-match snapshot.
    const block = [_]u8{ 0x13, 'Z', 0x01, 0x00, 0x00 };
    var dst: [8]u8 = undefined;
    const n = try decompressBlock(&block, &dst);
    try testing.expectEqual(@as(usize, 8), n);
    try testing.expectEqualStrings("ZZZZZZZZ", &dst);
}

test "disjoint match copies without overlap" {
    // 20 literals, then match_len 4 at offset 20: source and destination
    // ranges don't touch, which takes the bulk-copy path.
    const lits = "0123456789abcdefghij";
    var block = std.ArrayList(u8).empty;
    defer block.deinit(testing.allocator);
    try block.append(testing.allocator, 0xF0); // 15+ literals, match nibble 0
    try block.append(testing.allocator, lits.len - 15);
    try block.appendSlice(testing.allocator, lits);
    try block.appendSlice(testing.allocator, &.{ 0x14, 0x00 }); // offset 20
    try block.append(testing.allocator, 0x00); // final literals-only token

    var dst: [24]u8 = undefined;
    const n = try decompressBlock(block.items, &dst);
    try testing.expectEqual(@as(usize, 24), n);
    try testing.expectEqualStrings(lits ++ "0123", &dst);
}

test "literal run longer than one continuation byte round-trips" {
    // 300 bytes forces encodeAllLiterals to emit 0xFF + remainder, and the
    // decoder to sum across two continuation bytes.
    var payload: [300]u8 = undefined;
    for (&payload, 0..) |*c, i| c.* = @intCast('a' + (i % 26));

    const block = try encodeAllLiterals(testing.allocator, &payload);
    defer testing.allocator.free(block);

    var dst: [300]u8 = undefined;
    const n = try decompressBlock(block, &dst);
    try testing.expectEqual(@as(usize, 300), n);
    try testing.expectEqualSlices(u8, &payload, &dst);
}

test "rejects a block that decodes to fewer bytes than declared" {
    const block = try encodeAllLiterals(testing.allocator, "abcd");
    defer testing.allocator.free(block);

    var wrapped = std.ArrayList(u8).empty;
    defer wrapped.deinit(testing.allocator);
    var size_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &size_bytes, 10, .little); // claims 10, yields 4
    try wrapped.appendSlice(testing.allocator, &size_bytes);
    try wrapped.appendSlice(testing.allocator, block);

    try testing.expectError(error.SizeMismatch, decompressSystemd(testing.allocator, wrapped.items));
}

test "rejects a payload too short to hold the size prefix" {
    try testing.expectError(error.InvalidSize, decompressSystemd(testing.allocator, "short"));
    try testing.expectError(error.InvalidSize, decompressSystemd(testing.allocator, ""));
}

test "rejects a literal run that would overrun the output buffer" {
    // Token claims 15+ literals and the continuation says 300, but the
    // caller only sized `dst` for 16.
    const block = [_]u8{ 0xF0, 0xFF, 0x2A } ++ [_]u8{'x'} ** 16;
    var dst: [16]u8 = undefined;
    try testing.expectError(error.Truncated, decompressBlock(&block, &dst));
}

test "rejects a match that would overrun the output buffer" {
    // 2 literals then match_len 15+4+255+... past the end of `dst`.
    const block = [_]u8{ 0x2F, 'A', 'B', 0x02, 0x00, 0xFF, 0xFF };
    var dst: [8]u8 = undefined;
    try testing.expectError(error.Truncated, decompressBlock(&block, &dst));
}
