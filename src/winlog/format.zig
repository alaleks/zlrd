//! On-disk layout of a Windows Event Log (`.evtx`) file.
//!
//! The file is a container, not a stream: a 4 KiB header followed by a series
//! of fixed 64 KiB chunks, each holding its own record range, its own string
//! and template caches, and its own checksums. A chunk is self-contained by
//! design — the log is a circular buffer that the service overwrites chunk by
//! chunk, so nothing inside one may point outside it.
//!
//! That property is the reason this reader can be strict. Every offset a
//! record carries is chunk-relative, so a bounds check is `< 65536` rather
//! than a comparison against a file size that may have changed underneath us.
//!
//! Layout, all little-endian:
//!
//!     0            file header (128 bytes used of a 4096-byte block)
//!     4096         chunk 0        ┐
//!     4096+65536   chunk 1        ├ `chunk_count` of them
//!     …                           ┘
//!
//!     chunk + 0    chunk header (512 bytes, including both caches)
//!     chunk + 512  event records, packed, until `free_space_offset`
//!
//! Field names follow the ones used in Microsoft's `[MS-EVEN6]` and in
//! libevtx, so the two can be read side by side.

const std = @import("std");

/// Every chunk is exactly this big, header included. Not a hint — the format
/// pads to it, and chunk N always starts at `header_block_size + N * this`.
pub const chunk_size: usize = 64 * 1024;

/// Bytes reserved for the file header. Only the first 128 carry anything.
pub const header_block_size: usize = 4096;

/// Where a chunk's records begin, relative to the chunk.
pub const chunk_records_offset: usize = 512;

pub const file_magic: [8]u8 = "ElfFile\x00".*;
pub const chunk_magic: [8]u8 = "ElfChnk\x00".*;

/// Record signature: the bytes `2a 2a 00 00`, read as a little-endian u32.
pub const record_magic: u32 = 0x0000_2a2a;

/// A record carries a 24-byte header and repeats its own size in the last
/// four bytes, so the minimum meaningful record is header + trailer.
pub const record_header_size: usize = 24;
pub const record_trailer_size: usize = 4;
pub const min_record_size: usize = record_header_size + record_trailer_size;

/// Cap on a single record. The format allows up to the chunk size; anything
/// claiming more than that is corruption, and this keeps the check in one
/// place instead of at every call site.
pub const max_record_size: usize = chunk_size - chunk_records_offset;

/// Entries in a chunk's two caches. Both are chunk-local: a record refers to
/// a string or a template by its offset inside the same chunk.
pub const string_table_len: usize = 64;
pub const template_table_len: usize = 32;

/// File header. `checksum` covers the first 120 bytes, i.e. everything up to
/// but excluding itself.
pub const FileHeader = extern struct {
    magic: [8]u8,
    /// Chunk numbers of the oldest and newest chunk still in use. The log is
    /// circular, so `first` is not necessarily 0 and may exceed `last`.
    first_chunk: u64,
    last_chunk: u64,
    /// Identifier the next record written will get.
    next_record_id: u64,
    header_size: u32,
    minor_version: u16,
    major_version: u16,
    header_block_size: u16,
    chunk_count: u16,
    unused: [76]u8,
    /// Bit 0: the file was not closed cleanly. Bit 1: the log is full.
    /// A dirty file is still readable — it is the normal state of a log
    /// belonging to a running system.
    flags: u32,
    checksum: u32,

    pub const size: usize = 128;

    comptime {
        std.debug.assert(@sizeOf(FileHeader) == size);
    }
};

/// Chunk header, including both caches.
///
/// Two checksums, covering different things: `header_checksum` protects the
/// header and the caches, `records_checksum` protects the records region. A
/// chunk being written right now fails the second one routinely, which is why
/// verification is a caller's choice rather than a hard gate.
pub const ChunkHeader = extern struct {
    magic: [8]u8,
    first_record_number: u64,
    last_record_number: u64,
    first_record_id: u64,
    last_record_id: u64,
    header_size: u32,
    /// Chunk-relative offset of the last record written.
    last_record_offset: u32,
    /// Chunk-relative offset just past the last record. Everything from here
    /// to the end of the chunk is unwritten space.
    free_space_offset: u32,
    /// CRC32 over the records region, `[512, free_space_offset)`.
    records_checksum: u32,
    unused: [64]u8,
    flags: u32,
    /// CRC32 over `[0, 120)` followed by `[128, 512)` — the header without
    /// this field, plus both caches.
    header_checksum: u32,
    /// Chunk-relative offsets of cached name strings, 0 when the slot is
    /// empty. Records address names through this table instead of repeating
    /// them.
    string_table: [string_table_len]u32,
    /// Chunk-relative offsets of cached BinXml templates, 0 when empty.
    template_table: [template_table_len]u32,

    pub const size: usize = 512;

    comptime {
        std.debug.assert(@sizeOf(ChunkHeader) == size);
    }
};

/// Event record header. The BinXml stream follows it and runs to
/// `size - 4`, where the size is repeated.
pub const RecordHeader = extern struct {
    magic: u32,
    /// Total record length, header and trailer included.
    size: u32,
    record_id: u64,
    /// Windows FILETIME: 100-nanosecond ticks since 1601-01-01 UTC.
    written_time: u64,

    comptime {
        std.debug.assert(@sizeOf(RecordHeader) == record_header_size);
    }
};

/// Seconds between the FILETIME epoch (1601-01-01) and the Unix epoch.
const filetime_epoch_offset_s: i64 = 11_644_473_600;

/// Converts a FILETIME to Unix milliseconds.
///
/// Saturates instead of wrapping: a corrupt timestamp should produce a wrong
/// date, not a panic in a reader that has no business crashing on bad input.
pub fn filetimeToUnixMs(ft: u64) i64 {
    const ticks_ms: i64 = @intCast(@min(ft / 10_000, std.math.maxInt(i64)));
    return ticks_ms - filetime_epoch_offset_s * 1000;
}

/// CRC32 as the format uses it — the ordinary IEEE/zlib polynomial.
pub fn crc32(bytes: []const u8) u32 {
    return std.hash.crc.Crc32.hash(bytes);
}

/// CRC32 over two regions, for `ChunkHeader.header_checksum`, which skips
/// the checksum field itself.
pub fn crc32Split(a: []const u8, b: []const u8) u32 {
    var h = std.hash.crc.Crc32.init();
    h.update(a);
    h.update(b);
    return h.final();
}

const testing = std.testing;

test "structure sizes match the on-disk layout" {
    try testing.expectEqual(@as(usize, 128), @sizeOf(FileHeader));
    try testing.expectEqual(@as(usize, 512), @sizeOf(ChunkHeader));
    try testing.expectEqual(@as(usize, 24), @sizeOf(RecordHeader));
}

test "field offsets match the specification" {
    try testing.expectEqual(@as(usize, 8), @offsetOf(FileHeader, "first_chunk"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(FileHeader, "next_record_id"));
    try testing.expectEqual(@as(usize, 120), @offsetOf(FileHeader, "flags"));
    try testing.expectEqual(@as(usize, 124), @offsetOf(FileHeader, "checksum"));

    try testing.expectEqual(@as(usize, 40), @offsetOf(ChunkHeader, "header_size"));
    try testing.expectEqual(@as(usize, 48), @offsetOf(ChunkHeader, "free_space_offset"));
    try testing.expectEqual(@as(usize, 52), @offsetOf(ChunkHeader, "records_checksum"));
    try testing.expectEqual(@as(usize, 120), @offsetOf(ChunkHeader, "flags"));
    try testing.expectEqual(@as(usize, 124), @offsetOf(ChunkHeader, "header_checksum"));
    try testing.expectEqual(@as(usize, 128), @offsetOf(ChunkHeader, "string_table"));
    try testing.expectEqual(@as(usize, 384), @offsetOf(ChunkHeader, "template_table"));

    try testing.expectEqual(@as(usize, 8), @offsetOf(RecordHeader, "record_id"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(RecordHeader, "written_time"));
}

test "filetime converts to unix milliseconds" {
    // 1970-01-01T00:00:00Z expressed as a FILETIME.
    try testing.expectEqual(@as(i64, 0), filetimeToUnixMs(11_644_473_600 * 10_000_000));
    // One second later.
    try testing.expectEqual(@as(i64, 1000), filetimeToUnixMs((11_644_473_600 + 1) * 10_000_000));
    // Dates before the Unix epoch stay negative rather than wrapping.
    try testing.expect(filetimeToUnixMs(0) < 0);
    // An absurd value saturates instead of trapping.
    _ = filetimeToUnixMs(std.math.maxInt(u64));
}

test "crc32 matches the known IEEE vector" {
    try testing.expectEqual(@as(u32, 0xCBF43926), crc32("123456789"));
    // Splitting the input must not change the result.
    try testing.expectEqual(crc32("123456789"), crc32Split("1234", "56789"));
}
