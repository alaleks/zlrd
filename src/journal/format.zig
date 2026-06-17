//! Binary layout of the systemd journal file format. Mirrors
//! `systemd/src/libsystemd/sd-journal/journal-def.h` from upstream systemd —
//! field offsets, object types, flag bits.
//!
//! All multi-byte fields are little-endian on disk. Since the agent runs on
//! the same machine as the journal, we read them as native — the format
//! itself documents that journal files are not portable across machines.

const std = @import("std");
const builtin = @import("builtin");

/// Header signature — the first 8 bytes of every .journal file. Stands for
/// "Logging Pulsar Knowledge Storehouse Hieroglyphic Records Headquarters",
/// the funny acronym used by upstream systemd.
pub const signature_magic: [8]u8 = .{ 'L', 'P', 'K', 'S', 'H', 'H', 'R', 'H' };

/// `Header.incompatible_flags` bits. Readers must reject files with any
/// flag they don't understand.
pub const incompat = struct {
    pub const compressed_xz: u32 = 1 << 0;
    pub const compressed_lz4: u32 = 1 << 1;
    pub const keyed_hash: u32 = 1 << 2;
    pub const compressed_zstd: u32 = 1 << 3;
    pub const compact: u32 = 1 << 4;

    /// Mask of flags this reader knows how to handle. Files with any flag
    /// outside this mask are rejected. Compression flags are accepted only
    /// when the corresponding decoder is wired in (currently LZ4).
    pub const supported: u32 = compressed_lz4 | keyed_hash | compact;
};

/// `ObjectHeader.flags` low-3 bits encode the compression scheme of the
/// payload (mutually exclusive). The same constants appear in `incompat`
/// for the file-wide flag.
pub const obj_compressed_xz: u8 = 1 << 0;
pub const obj_compressed_lz4: u8 = 1 << 1;
pub const obj_compressed_zstd: u8 = 1 << 2;
pub const obj_compression_mask: u8 = obj_compressed_xz | obj_compressed_lz4 | obj_compressed_zstd;

pub const ObjectType = enum(u8) {
    unused = 0,
    data = 1,
    field = 2,
    entry = 3,
    data_hash_table = 4,
    field_hash_table = 5,
    entry_array = 6,
    tag = 7,
    _,
};

/// Every object in the arena starts with this 16-byte header. `size` is the
/// total size of the object (header + payload), in bytes.
pub const ObjectHeader = extern struct {
    type: u8,
    flags: u8,
    reserved: [6]u8,
    size: u64,
};

comptime {
    std.debug.assert(@sizeOf(ObjectHeader) == 16);
}

/// 240-byte journal file header. Newer systemd versions extend this with
/// additional fields (n_data, n_fields, etc.) — `header_size` records the
/// on-disk size so we can tolerate larger headers without re-parsing them.
pub const Header = extern struct {
    signature: [8]u8,
    compatible_flags: u32,
    incompatible_flags: u32,
    state: u8,
    reserved: [7]u8,
    file_id: [16]u8,
    machine_id: [16]u8,
    tail_entry_boot_id: [16]u8,
    seqnum_id: [16]u8,
    header_size: u64,
    arena_size: u64,
    data_hash_table_offset: u64,
    data_hash_table_size: u64,
    field_hash_table_offset: u64,
    field_hash_table_size: u64,
    tail_object_offset: u64,
    n_objects: u64,
    n_entries: u64,
    tail_entry_seqnum: u64,
    head_entry_seqnum: u64,
    entry_array_offset: u64,
    head_entry_realtime: u64,
    tail_entry_realtime: u64,
    tail_entry_monotonic: u64,
    n_data: u64,
    n_fields: u64,
    n_tags: u64,
    n_entry_arrays: u64,
};

comptime {
    std.debug.assert(@sizeOf(Header) == 240);
}

/// Common entry-object prefix (everything before the variable-length items
/// array). 16 + 48 = 64 bytes.
pub const EntryHead = extern struct {
    object: ObjectHeader,
    seqnum: u64,
    realtime: u64,
    monotonic: u64,
    boot_id: [16]u8,
    xor_hash: u64,
};

comptime {
    std.debug.assert(@sizeOf(EntryHead) == 64);
}

/// Regular (non-compact) entry item: { object_offset, hash }. 16 bytes.
pub const EntryItem = extern struct {
    object_offset: u64,
    hash: u64,
};

comptime {
    std.debug.assert(@sizeOf(EntryItem) == 16);
}

/// Compact entry item: just the data-object offset. 4 bytes. Used when the
/// file has the COMPACT incompat flag.
pub const CompactEntryItem = extern struct {
    object_offset: u32,
};

comptime {
    std.debug.assert(@sizeOf(CompactEntryItem) == 4);
}

/// Common data-object prefix. Payload starts at offset 64 (non-compact) or
/// 72 (compact — two extra u32 fields).
pub const DataHead = extern struct {
    object: ObjectHeader,
    hash: u64,
    next_hash_offset: u64,
    next_field_offset: u64,
    entry_offset: u64,
    entry_array_offset: u64,
    n_entries: u64,
};

comptime {
    std.debug.assert(@sizeOf(DataHead) == 64);
}

/// Two extra u32 fields present only when the file has COMPACT.
pub const DataCompactExtra = extern struct {
    tail_entry_array_offset: u32,
    tail_entry_array_n_entries: u32,
};

comptime {
    std.debug.assert(@sizeOf(DataCompactExtra) == 8);
}

/// EntryArray object header. Followed by inline items[] of u64 (non-compact)
/// or u32 (compact) entry-object offsets.
pub const EntryArrayHead = extern struct {
    object: ObjectHeader,
    next_entry_array_offset: u64,
};

comptime {
    std.debug.assert(@sizeOf(EntryArrayHead) == 24);
}

pub fn dataPayloadStart(compact: bool) usize {
    return if (compact) 64 + @sizeOf(DataCompactExtra) else 64;
}

pub fn entryItemSize(compact: bool) usize {
    return if (compact) @sizeOf(CompactEntryItem) else @sizeOf(EntryItem);
}

pub fn entryArrayItemSize(compact: bool) usize {
    return if (compact) @sizeOf(u32) else @sizeOf(u64);
}

const testing = std.testing;

test "ObjectHeader is 16 bytes (matches systemd)" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(ObjectHeader));
}

test "Header layout matches systemd's 240-byte base" {
    try testing.expectEqual(@as(usize, 240), @sizeOf(Header));
    // Spot-check a few field offsets to catch any layout drift across compilers.
    try testing.expectEqual(@as(usize, 0), @offsetOf(Header, "signature"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(Header, "compatible_flags"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(Header, "incompatible_flags"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(Header, "state"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(Header, "file_id"));
    try testing.expectEqual(@as(usize, 88), @offsetOf(Header, "header_size"));
    try testing.expectEqual(@as(usize, 176), @offsetOf(Header, "entry_array_offset"));
    try testing.expectEqual(@as(usize, 208), @offsetOf(Header, "n_data"));
}

test "dataPayloadStart: 64 non-compact, 72 compact" {
    try testing.expectEqual(@as(usize, 64), dataPayloadStart(false));
    try testing.expectEqual(@as(usize, 72), dataPayloadStart(true));
}

test "entryItemSize: 16 non-compact, 4 compact" {
    try testing.expectEqual(@as(usize, 16), entryItemSize(false));
    try testing.expectEqual(@as(usize, 4), entryItemSize(true));
}

test "incompat.supported gates accepted flags" {
    // LZ4 + keyed_hash + compact are wired in.
    try testing.expect((incompat.supported & incompat.compressed_lz4) != 0);
    try testing.expect((incompat.supported & incompat.keyed_hash) != 0);
    try testing.expect((incompat.supported & incompat.compact) != 0);
    // XZ + ZSTD are not — these would force the reader to bail.
    try testing.expect((incompat.supported & incompat.compressed_xz) == 0);
    try testing.expect((incompat.supported & incompat.compressed_zstd) == 0);
}

test "endianness check: format is documented as machine-native" {
    // The journal format is explicitly NOT portable across machines. Verify
    // we're running little-endian (where every modern systemd target sits).
    try testing.expectEqual(builtin.cpu.arch.endian(), .little);
}
