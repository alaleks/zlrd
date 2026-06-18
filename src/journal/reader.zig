//! Forward iterator over a single `.journal` file. Walks the entry-array
//! chain starting at `Header.entry_array_offset`, follows each entry's
//! `items[]` to the referenced data objects, and reconstructs the original
//! `KEY=value` field list.
//!
//! Scope of this phase:
//!   - Non-compact files (no COMPACT incompat flag)
//!   - Uncompressed data objects (no XZ / LZ4 / ZSTD)
//!   - Single file, read-only
//!
//! Subsequent phases add COMPACT support, LZ4 decompression, and an
//! inotify-driven live tail across rotated `.journal` files.

const std = @import("std");

const fmt = @import("format.zig");
const lz4 = @import("lz4.zig");

const log = std.log.scoped(.zlrd_journal);
const debug_io = std.Options.debug_io;

/// Defensive caps on values pulled from on-disk object headers. A corrupted
/// or maliciously crafted journal can claim absurd sizes; without these we
/// would happily try to allocate gigabytes or recurse millions of times.
pub const max_entry_fields: usize = 4096;
pub const max_data_payload_bytes: usize = 16 * 1024 * 1024;

pub const Error = error{
    InvalidMagic,
    InvalidHeaderSize,
    UnsupportedIncompatFlag,
    InvalidOffset,
    InvalidObjectType,
    InvalidObjectSize,
    UnsupportedCompression,
    InvalidField,
    EntryTooLarge,
    PayloadTooLarge,
} || std.mem.Allocator.Error || error{
    /// Underlying I/O failed. We collapse the std.Io.File errors into a
    /// single variant so the public API stays small.
    IoError,
};

pub const Field = struct {
    /// Borrowed slice into the entry's backing buffer.
    key: []const u8,
    /// Borrowed slice into the entry's backing buffer.
    value: []const u8,
};

pub const Entry = struct {
    seqnum: u64,
    realtime_us: u64,
    monotonic_us: u64,
    boot_id: [16]u8,
    /// Owned slice — release via `deinit`.
    fields: []Field,
    /// Owned arena holding all field bytes; freed together with `fields`.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Entry) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Returns the value of `key`, or null. O(n) linear scan; sufficient for
    /// typical journal entries (≤ a few dozen fields).
    pub fn get(self: *const Entry, key: []const u8) ?[]const u8 {
        for (self.fields) |f| {
            if (std.mem.eql(u8, f.key, key)) return f.value;
        }
        return null;
    }
};

pub const Reader = struct {
    io: std.Io,
    file: std.Io.File,
    /// Owned copy of the file's 240-byte base header.
    header: fmt.Header,
    file_size: u64,

    /// Opens a journal file in read-only mode. Validates the header magic
    /// and the set of declared incompat flags.
    pub fn open(io: std.Io, dir: std.Io.Dir, path: []const u8) Error!Reader {
        const f = dir.openFile(io, path, .{ .mode = .read_only }) catch return error.IoError;
        errdefer f.close(io);

        const size = f.length(io) catch return error.IoError;
        if (size < @sizeOf(fmt.Header)) return error.InvalidHeaderSize;

        var header_bytes: [@sizeOf(fmt.Header)]u8 = undefined;
        const n = f.readPositional(io, &.{&header_bytes}, 0) catch return error.IoError;
        if (n != header_bytes.len) return error.InvalidHeaderSize;
        const header = std.mem.bytesAsValue(fmt.Header, &header_bytes).*;

        if (!std.mem.eql(u8, &header.signature, &fmt.signature_magic)) return error.InvalidMagic;
        if (header.header_size < @sizeOf(fmt.Header)) return error.InvalidHeaderSize;

        const unsupported = header.incompatible_flags & ~fmt.incompat.supported;
        if (unsupported != 0) {
            log.warn("journal {s}: unsupported incompat flags 0x{x}", .{ path, unsupported });
            return error.UnsupportedIncompatFlag;
        }

        if (header.entry_array_offset != 0 and header.entry_array_offset >= size) {
            return error.InvalidOffset;
        }

        return .{
            .io = io,
            .file = f,
            .header = header,
            .file_size = size,
        };
    }

    pub fn deinit(self: *Reader) void {
        self.file.close(self.io);
        self.* = undefined;
    }

    pub fn isCompact(self: *const Reader) bool {
        return (self.header.incompatible_flags & fmt.incompat.compact) != 0;
    }

    pub fn iterator(self: *Reader) Iterator {
        const compact = self.isCompact();
        return .{
            .reader = self,
            .array_offset = self.header.entry_array_offset,
            .array_index = 0,
            .array_capacity = 0,
            .initial_chain_head = self.header.entry_array_offset,
            .compact = compact,
            .array_item_sz = fmt.entryArrayItemSize(compact),
            .entry_item_sz = fmt.entryItemSize(compact),
        };
    }

    /// Re-reads the volatile portion of the file header — just the fields
    /// that change as new entries are appended (tail pointers, entry counts,
    /// chain head). The static fields (signature, machine_id, flags, file
    /// id) never change after open so we don't pay for re-reading them.
    /// 80 bytes vs 240 bytes — meaningful at high inotify-wake rates.
    pub fn refresh(self: *Reader) Error!void {
        self.file_size = self.file.length(self.io) catch return error.IoError;

        // Read the contiguous slab covering `tail_object_offset` (offset 152)
        // through `n_entry_arrays` (offset 232). That's everything the
        // iterator's `refresh` cares about.
        const refresh_start: u64 = @offsetOf(fmt.Header, "tail_object_offset");
        const refresh_end: u64 = @sizeOf(fmt.Header);
        const refresh_len = refresh_end - refresh_start;
        var buf: [refresh_len]u8 = undefined;
        const n = self.file.readPositional(self.io, &.{&buf}, refresh_start) catch return error.IoError;
        if (n != buf.len) return error.IoError;

        const dst = @as([*]u8, @ptrCast(&self.header)) + refresh_start;
        @memcpy(dst[0..refresh_len], &buf);
    }

    /// Reads `len` bytes at `pos` into `dst`. Errors if the read is short
    /// (truncated file) or runs past `file_size`.
    fn readAt(self: *Reader, pos: u64, dst: []u8) Error!void {
        if (pos + dst.len > self.file_size) return error.InvalidOffset;
        const n = self.file.readPositional(self.io, &.{dst}, pos) catch return error.IoError;
        if (n != dst.len) return error.IoError;
    }
};

pub const Iterator = struct {
    reader: *Reader,
    array_offset: u64,
    array_index: u64,
    array_capacity: u64,
    /// Cached `next_entry_array_offset` of the current array — read once in
    /// `advanceArray` and consumed when we exhaust the array's items.
    next_array_offset: u64 = 0,
    /// Offset of the last array we successfully read from. Preserved when
    /// the iterator returns null so `refresh()` can pick up appended items
    /// (extended array capacity) or a freshly-linked next array.
    last_array_offset: u64 = 0,
    /// Last index returned from `last_array_offset`. Together with the
    /// offset above, this lets a tail consumer resume exactly where it left
    /// off after a `refresh()`.
    last_array_index: u64 = 0,
    /// Snapshot of `Header.entry_array_offset` at iterator creation. Used
    /// by `refresh` to detect a fresh chain head (rotation/snapshot).
    initial_chain_head: u64 = 0,
    /// Hoisted out of the hot loops: encoded once at iterator creation so
    /// `readEntry`/`readArrayItem`/etc. don't re-check the incompat flag
    /// or call out to `entryItemSize` on every iteration.
    compact: bool = false,
    array_item_sz: usize = 8,
    entry_item_sz: usize = 16,
    /// Optional DATA-object cache. Systemd journals deduplicate field
    /// objects via a hash table — the SAME `_SYSTEMD_UNIT=foo.service`
    /// DATA payload is referenced by every entry of that unit. Without a
    /// cache we re-read (and re-LZ4-decode) it once per entry.
    cache: ?*DataCache = null,

    /// Advances to the next entry. Returns null at EOF. Caller owns the
    /// returned `Entry` and must call `deinit`.
    pub fn next(self: *Iterator, allocator: std.mem.Allocator) Error!?Entry {
        while (true) {
            if (self.array_offset == 0) return null;
            if (self.array_index >= self.array_capacity) {
                try self.advanceArray();
                if (self.array_offset == 0) return null;
                continue;
            }

            self.last_array_offset = self.array_offset;
            self.last_array_index = self.array_index;
            const item_offset = try self.readArrayItem(self.array_index);
            self.array_index += 1;
            if (item_offset == 0) continue;
            return try self.readEntry(allocator, item_offset);
        }
    }

    /// Re-reads the most recent array's header so the iterator can see new
    /// items appended to it, or a newly-linked next array. Safe to call
    /// after `next()` has returned null.
    ///
    /// Also detects when `Header.entry_array_offset` switches to a brand-new
    /// chain head (snapshot/compaction in upstream systemd writers) — in
    /// that case we resume from the new head instead of staying stuck on
    /// the old one.
    pub fn refresh(self: *Iterator) Error!void {
        try self.reader.refresh();

        // Did the writer install a fresh chain head? If so, jump there.
        const fresh_head = self.reader.header.entry_array_offset;
        if (fresh_head != 0 and fresh_head != self.initial_chain_head) {
            self.initial_chain_head = fresh_head;
            self.array_offset = fresh_head;
            self.array_index = 0;
            self.array_capacity = 0;
            self.next_array_offset = 0;
            self.last_array_offset = 0;
            self.last_array_index = 0;
            return;
        }

        const probe = if (self.array_offset != 0) self.array_offset else self.last_array_offset;
        if (probe == 0) {
            // The file never had an entry-array; fall back to the header.
            self.array_offset = fresh_head;
            self.array_index = 0;
            self.array_capacity = 0;
            return;
        }

        var head_buf: [@sizeOf(fmt.EntryArrayHead)]u8 = undefined;
        try self.reader.readAt(probe, &head_buf);
        const head = std.mem.bytesAsValue(fmt.EntryArrayHead, &head_buf).*;
        if (head.object.type != @intFromEnum(fmt.ObjectType.entry_array)) return error.InvalidObjectType;
        if (head.object.size < @sizeOf(fmt.EntryArrayHead)) return error.InvalidObjectSize;

        const new_capacity = (head.object.size - @sizeOf(fmt.EntryArrayHead)) / self.array_item_sz;

        // If we're mid-array, just extend the capacity and pick up new items.
        // Otherwise (we'd exhausted the chain), re-arm to the next-linked
        // array if one has appeared.
        if (self.array_offset != 0) {
            self.array_capacity = new_capacity;
            self.next_array_offset = head.next_entry_array_offset;
        } else if (new_capacity > self.last_array_index + 1) {
            self.array_offset = probe;
            self.array_index = self.last_array_index + 1;
            self.array_capacity = new_capacity;
            self.next_array_offset = head.next_entry_array_offset;
        } else if (head.next_entry_array_offset != 0) {
            self.array_offset = head.next_entry_array_offset;
            self.array_index = 0;
            self.array_capacity = 0;
            self.next_array_offset = 0;
        }
    }

    /// Loads the current entry-array's metadata: capacity (item count) and
    /// `next_entry_array_offset`. Advances `array_offset` to next array when
    /// the current is exhausted.
    fn advanceArray(self: *Iterator) Error!void {
        var head_buf: [@sizeOf(fmt.EntryArrayHead)]u8 = undefined;
        try self.reader.readAt(self.array_offset, &head_buf);
        const head = std.mem.bytesAsValue(fmt.EntryArrayHead, &head_buf).*;

        if (head.object.type != @intFromEnum(fmt.ObjectType.entry_array)) return error.InvalidObjectType;
        if (head.object.size < @sizeOf(fmt.EntryArrayHead)) return error.InvalidObjectSize;

        const capacity = (head.object.size - @sizeOf(fmt.EntryArrayHead)) / self.array_item_sz;

        // EntryArray often pre-allocates trailing slots; only the populated
        // prefix has non-zero offsets. We still iterate the full capacity —
        // each `next` call skips zero entries.
        self.array_capacity = capacity;
        self.array_index = 0;

        if (capacity == 0) {
            self.array_offset = head.next_entry_array_offset;
        } else {
            // Cache the next-array pointer on the iterator so we can advance
            // once we've exhausted this array's items.
            self.next_array_offset = head.next_entry_array_offset;
        }
    }

    /// Returns the entry-object offset of the i-th item in the current array.
    fn readArrayItem(self: *Iterator, index: u64) Error!u64 {
        const item_pos = self.array_offset + @sizeOf(fmt.EntryArrayHead) + index * self.array_item_sz;
        if (self.compact) {
            var buf: [4]u8 = undefined;
            try self.reader.readAt(item_pos, &buf);
            // When the array is exhausted, fall through to the next-array
            // pointer on the next outer-loop iteration.
            if (index + 1 == self.array_capacity) self.array_offset = self.next_array_offset;
            return std.mem.readInt(u32, &buf, .little);
        } else {
            var buf: [8]u8 = undefined;
            try self.reader.readAt(item_pos, &buf);
            if (index + 1 == self.array_capacity) self.array_offset = self.next_array_offset;
            return std.mem.readInt(u64, &buf, .little);
        }
    }

    /// Walks the entry-array chain WITHOUT resolving any entries. Used by
    /// callers (typically tail-follow) that want to skip the file's existing
    /// content and only emit newly-appended entries. Reading entries one by
    /// one just to discard them turns a multi-second startup on a large
    /// journal into a tens-of-milliseconds bookkeeping pass.
    pub fn seekToEnd(self: *Iterator) Error!void {
        while (self.array_offset != 0) {
            var head_buf: [@sizeOf(fmt.EntryArrayHead)]u8 = undefined;
            try self.reader.readAt(self.array_offset, &head_buf);
            const head = std.mem.bytesAsValue(fmt.EntryArrayHead, &head_buf).*;
            if (head.object.type != @intFromEnum(fmt.ObjectType.entry_array)) return error.InvalidObjectType;
            if (head.object.size < @sizeOf(fmt.EntryArrayHead)) return error.InvalidObjectSize;

            const capacity = (head.object.size - @sizeOf(fmt.EntryArrayHead)) / self.array_item_sz;

            // Pretend we just consumed the last item of this array.
            self.last_array_offset = self.array_offset;
            self.last_array_index = if (capacity == 0) 0 else capacity - 1;
            self.next_array_offset = head.next_entry_array_offset;

            self.array_offset = head.next_entry_array_offset;
            self.array_index = 0;
            self.array_capacity = 0;
        }
    }

    /// Opts the iterator into a small DATA-object cache. Cuts repeat reads
    /// of high-cardinality fields (`_SYSTEMD_UNIT`, `SYSLOG_IDENTIFIER`,
    /// `_HOSTNAME`, …) which are referenced by every entry of a service.
    pub fn enableCache(self: *Iterator, allocator: std.mem.Allocator) Error!void {
        if (self.cache != null) return;
        const c = try allocator.create(DataCache);
        c.* = .{};
        self.cache = c;
    }

    /// Releases the cache allocated by `enableCache`. Safe to call when no
    /// cache is attached.
    pub fn disableCache(self: *Iterator, allocator: std.mem.Allocator) void {
        if (self.cache) |c| {
            allocator.destroy(c);
            self.cache = null;
        }
    }

    /// Reads an entry object at `offset` and resolves all its data items into
    /// field key/value pairs.
    fn readEntry(self: *Iterator, allocator: std.mem.Allocator, offset: u64) Error!Entry {
        var head_buf: [@sizeOf(fmt.EntryHead)]u8 = undefined;
        try self.reader.readAt(offset, &head_buf);
        const head = std.mem.bytesAsValue(fmt.EntryHead, &head_buf).*;

        if (head.object.type != @intFromEnum(fmt.ObjectType.entry)) return error.InvalidObjectType;
        if (head.object.size < @sizeOf(fmt.EntryHead)) return error.InvalidObjectSize;

        const compact = self.compact;
        const item_sz = self.entry_item_sz;
        const items_bytes = head.object.size - @sizeOf(fmt.EntryHead);
        const n_items = items_bytes / item_sz;
        if (n_items > max_entry_fields) return error.EntryTooLarge;

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const fields = try a.alloc(Field, n_items);

        var i: usize = 0;
        while (i < n_items) : (i += 1) {
            const item_pos = offset + @sizeOf(fmt.EntryHead) + i * item_sz;
            const data_offset = try self.readEntryItem(item_pos, compact);
            fields[i] = try self.readDataField(a, data_offset, compact);
        }

        return .{
            .seqnum = head.seqnum,
            .realtime_us = head.realtime,
            .monotonic_us = head.monotonic,
            .boot_id = head.boot_id,
            .fields = fields,
            .arena = arena,
        };
    }

    fn readEntryItem(self: *Iterator, pos: u64, compact: bool) Error!u64 {
        if (compact) {
            var buf: [4]u8 = undefined;
            try self.reader.readAt(pos, &buf);
            return std.mem.readInt(u32, &buf, .little);
        }
        var buf: [@sizeOf(fmt.EntryItem)]u8 = undefined;
        try self.reader.readAt(pos, &buf);
        const item = std.mem.bytesAsValue(fmt.EntryItem, &buf).*;
        return item.object_offset;
    }

    /// Reads a DATA object at `offset` and splits its payload on the first
    /// `=` byte into key + value. Decompresses LZ4-flagged payloads
    /// transparently; XZ and ZSTD are still rejected. Looks up `offset` in
    /// the optional cache first and writes back on miss.
    fn readDataField(self: *Iterator, arena: std.mem.Allocator, offset: u64, compact: bool) Error!Field {
        if (self.cache) |c| {
            if (c.get(offset)) |cached| return splitField(cached);
        }

        var head_buf: [@sizeOf(fmt.DataHead)]u8 = undefined;
        try self.reader.readAt(offset, &head_buf);
        const head = std.mem.bytesAsValue(fmt.DataHead, &head_buf).*;

        if (head.object.type != @intFromEnum(fmt.ObjectType.data)) return error.InvalidObjectType;
        const compression = head.object.flags & fmt.obj_compression_mask;

        const payload_start = fmt.dataPayloadStart(compact);
        if (head.object.size < payload_start) return error.InvalidObjectSize;
        const payload_len = head.object.size - payload_start;
        if (payload_len == 0) return error.InvalidField;
        if (payload_len > max_data_payload_bytes) return error.PayloadTooLarge;

        const raw = try arena.alloc(u8, payload_len);
        try self.reader.readAt(offset + payload_start, raw);

        const payload: []const u8 = switch (compression) {
            0 => raw,
            fmt.obj_compressed_lz4 => lz4.decompressSystemd(arena, raw) catch return error.UnsupportedCompression,
            else => return error.UnsupportedCompression,
        };

        if (self.cache) |c| c.put(offset, payload);
        return splitField(payload);
    }
};

/// Splits a `KEY=value` payload into a `Field`. Shared by the cache-hit
/// and cache-miss paths to keep the split logic in one place.
inline fn splitField(payload: []const u8) Error!Field {
    const eq = std.mem.indexOfScalar(u8, payload, '=') orelse return error.InvalidField;
    if (eq == 0) return error.InvalidField;
    return .{ .key = payload[0..eq], .value = payload[eq + 1 ..] };
}

/// Bounded fixed-size cache mapping DATA-object file offsets to their
/// decoded payloads. Sized to capture the working set of high-cardinality
/// dedup fields without paying for a real hashmap: each slot is 4 KiB so
/// the total footprint is `cache_slots * 4 KiB` = 64 KiB.
pub const DataCache = struct {
    pub const slot_count = 16;
    pub const slot_bytes = 4 * 1024;

    const Slot = struct {
        offset: u64 = 0, // 0 = empty
        len: u16 = 0,
        buf: [slot_bytes]u8 = undefined,
    };

    slots: [slot_count]Slot = [_]Slot{.{}} ** slot_count,
    /// Round-robin replacement index. Simple FIFO, no real LRU — the
    /// access pattern (repeated high-cardinality fields hit the same
    /// slots) makes this nearly equivalent in practice.
    next_evict: u8 = 0,

    pub fn get(self: *const DataCache, offset: u64) ?[]const u8 {
        if (offset == 0) return null;
        for (&self.slots) |*slot| {
            if (slot.offset == offset) return slot.buf[0..slot.len];
        }
        return null;
    }

    pub fn put(self: *DataCache, offset: u64, payload: []const u8) void {
        if (offset == 0 or payload.len > slot_bytes) return;
        const idx = self.next_evict;
        self.next_evict = (self.next_evict + 1) % slot_count;
        self.slots[idx].offset = offset;
        self.slots[idx].len = @intCast(payload.len);
        @memcpy(self.slots[idx].buf[0..payload.len], payload);
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Builds a synthetic journal file in-memory. Used by tests so we don't need
/// a real /var/log/journal/*.journal fixture.
const SyntheticBuilder = struct {
    bytes: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    /// When true, the builder emits the COMPACT data/entry/entry-array
    /// variants. Mirrors the same bit on the file header.
    compact: bool = false,
    /// Recorded so callers can patch the offsets into the header after the
    /// fact (we don't yet know the file layout when emitting the header).
    header_offset: usize = 0,

    fn init(allocator: std.mem.Allocator) SyntheticBuilder {
        return .{ .bytes = .empty, .allocator = allocator };
    }
    fn deinit(self: *SyntheticBuilder) void {
        self.bytes.deinit(self.allocator);
    }

    fn padTo8(self: *SyntheticBuilder) !void {
        while (self.bytes.items.len % 8 != 0) try self.bytes.append(self.allocator, 0);
    }

    fn writeHeader(self: *SyntheticBuilder, incompat_flags: u32) !void {
        self.compact = (incompat_flags & fmt.incompat.compact) != 0;
        self.header_offset = self.bytes.items.len;
        var h: fmt.Header = std.mem.zeroes(fmt.Header);
        h.signature = fmt.signature_magic;
        h.incompatible_flags = incompat_flags;
        h.header_size = @sizeOf(fmt.Header);
        try self.bytes.appendSlice(self.allocator, std.mem.asBytes(&h));
    }

    /// Writes a DATA object with raw `KEY=value` payload. Returns its file offset.
    fn writeData(self: *SyntheticBuilder, payload: []const u8) !u64 {
        return self.writeDataRaw(payload, 0);
    }

    /// Writes a DATA object with an explicit ObjectHeader.flags value, used by
    /// tests that want to simulate compressed payloads.
    fn writeDataRaw(self: *SyntheticBuilder, payload: []const u8, obj_flags: u8) !u64 {
        try self.padTo8();
        const off = self.bytes.items.len;
        const extra_size: usize = if (self.compact) @sizeOf(fmt.DataCompactExtra) else 0;
        var dh: fmt.DataHead = std.mem.zeroes(fmt.DataHead);
        dh.object.type = @intFromEnum(fmt.ObjectType.data);
        dh.object.flags = obj_flags;
        dh.object.size = @sizeOf(fmt.DataHead) + extra_size + payload.len;
        try self.bytes.appendSlice(self.allocator, std.mem.asBytes(&dh));
        if (self.compact) {
            const extra: fmt.DataCompactExtra = .{
                .tail_entry_array_offset = 0,
                .tail_entry_array_n_entries = 0,
            };
            try self.bytes.appendSlice(self.allocator, std.mem.asBytes(&extra));
        }
        try self.bytes.appendSlice(self.allocator, payload);
        return @intCast(off);
    }

    /// Writes an LZ4-compressed DATA object. `plain` is the desired post-
    /// decompression payload; the builder wraps it in systemd's
    /// 8-byte-size-prefixed all-literal block.
    fn writeDataLz4(self: *SyntheticBuilder, plain: []const u8) !u64 {
        const block = try lz4.encodeAllLiterals(self.allocator, plain);
        defer self.allocator.free(block);
        var wrapped = std.ArrayList(u8).empty;
        defer wrapped.deinit(self.allocator);
        var size_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &size_bytes, plain.len, .little);
        try wrapped.appendSlice(self.allocator, &size_bytes);
        try wrapped.appendSlice(self.allocator, block);
        return self.writeDataRaw(wrapped.items, fmt.obj_compressed_lz4);
    }

    /// Writes an ENTRY object referencing the given data offsets. Returns the
    /// file offset of the entry object. In COMPACT mode each item is u32; in
    /// non-compact mode each item is `EntryItem { object_offset: u64, hash: u64 }`.
    fn writeEntry(self: *SyntheticBuilder, seqnum: u64, realtime: u64, data_offsets: []const u64) !u64 {
        try self.padTo8();
        const off = self.bytes.items.len;
        const item_sz: usize = if (self.compact) @sizeOf(fmt.CompactEntryItem) else @sizeOf(fmt.EntryItem);
        var eh: fmt.EntryHead = std.mem.zeroes(fmt.EntryHead);
        eh.object.type = @intFromEnum(fmt.ObjectType.entry);
        eh.object.size = @sizeOf(fmt.EntryHead) + item_sz * data_offsets.len;
        eh.seqnum = seqnum;
        eh.realtime = realtime;
        eh.monotonic = realtime;
        try self.bytes.appendSlice(self.allocator, std.mem.asBytes(&eh));
        for (data_offsets) |d| {
            if (self.compact) {
                const item: fmt.CompactEntryItem = .{ .object_offset = @intCast(d) };
                try self.bytes.appendSlice(self.allocator, std.mem.asBytes(&item));
            } else {
                const item: fmt.EntryItem = .{ .object_offset = d, .hash = 0 };
                try self.bytes.appendSlice(self.allocator, std.mem.asBytes(&item));
            }
        }
        return @intCast(off);
    }

    /// Writes an EntryArray object holding the given entry offsets. Returns
    /// the file offset of the array. Items are u32 in COMPACT mode, u64 otherwise.
    fn writeEntryArray(self: *SyntheticBuilder, entry_offsets: []const u64) !u64 {
        try self.padTo8();
        const off = self.bytes.items.len;
        const item_sz: usize = if (self.compact) @sizeOf(u32) else @sizeOf(u64);
        var ah: fmt.EntryArrayHead = std.mem.zeroes(fmt.EntryArrayHead);
        ah.object.type = @intFromEnum(fmt.ObjectType.entry_array);
        ah.object.size = @sizeOf(fmt.EntryArrayHead) + item_sz * entry_offsets.len;
        try self.bytes.appendSlice(self.allocator, std.mem.asBytes(&ah));
        for (entry_offsets) |e| {
            if (self.compact) {
                const buf: [4]u8 = @bitCast(@as(u32, @intCast(e)));
                try self.bytes.appendSlice(self.allocator, &buf);
            } else {
                const buf: [8]u8 = @bitCast(e);
                try self.bytes.appendSlice(self.allocator, &buf);
            }
        }
        return @intCast(off);
    }

    fn patchHeaderEntryArray(self: *SyntheticBuilder, array_offset: u64) void {
        const h_ptr: *fmt.Header = @alignCast(@ptrCast(self.bytes.items[self.header_offset..].ptr));
        h_ptr.entry_array_offset = array_offset;
    }
};

test "Reader.open rejects files without the magic header" {
    const tio = debug_io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(tio, .{
        .sub_path = "bogus.journal",
        .data = &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 } ** 32,
    });
    try testing.expectError(error.InvalidMagic, Reader.open(tio, tmp.dir, "bogus.journal"));
}

test "Reader iterates entries in a synthetic single-array journal" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();

    try b.writeHeader(0); // no incompat flags = non-compact, uncompressed

    // Two data records that both entries share.
    const d_msg1 = try b.writeData("MESSAGE=hello");
    const d_unit = try b.writeData("_SYSTEMD_UNIT=demo.service");
    // One more record only present on entry 2.
    const d_msg2 = try b.writeData("MESSAGE=world");

    const e1 = try b.writeEntry(1, 1_000_000, &.{ d_msg1, d_unit });
    const e2 = try b.writeEntry(2, 2_000_000, &.{ d_msg2, d_unit });
    const arr = try b.writeEntryArray(&.{ e1, e2 });
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(tio, .{ .sub_path = "ok.journal", .data = b.bytes.items });

    var r = try Reader.open(tio, tmp.dir, "ok.journal");
    defer r.deinit();

    var it = r.iterator();
    var first = (try it.next(testing.allocator)) orelse return error.MissingFirst;
    defer first.deinit();
    try testing.expectEqual(@as(u64, 1), first.seqnum);
    try testing.expectEqual(@as(u64, 1_000_000), first.realtime_us);
    try testing.expectEqualStrings("hello", first.get("MESSAGE").?);
    try testing.expectEqualStrings("demo.service", first.get("_SYSTEMD_UNIT").?);

    var second = (try it.next(testing.allocator)) orelse return error.MissingSecond;
    defer second.deinit();
    try testing.expectEqual(@as(u64, 2), second.seqnum);
    try testing.expectEqualStrings("world", second.get("MESSAGE").?);

    try testing.expect((try it.next(testing.allocator)) == null);
}

test "Reader.open rejects unsupported incompat flag (xz)" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(fmt.incompat.compressed_xz);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(tio, .{ .sub_path = "xz.journal", .data = b.bytes.items });
    try testing.expectError(error.UnsupportedIncompatFlag, Reader.open(tio, tmp.dir, "xz.journal"));
}

test "Iterator skips zero-offset items in EntryArray" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);
    const d = try b.writeData("MESSAGE=only");
    const e = try b.writeEntry(7, 7_000, &.{d});
    // EntryArray with a leading zero (sparse slot) — iterator should skip it.
    const arr = try b.writeEntryArray(&.{ 0, e });
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(tio, .{ .sub_path = "sparse.journal", .data = b.bytes.items });

    var r = try Reader.open(tio, tmp.dir, "sparse.journal");
    defer r.deinit();

    var it = r.iterator();
    var only = (try it.next(testing.allocator)) orelse return error.Missing;
    defer only.deinit();
    try testing.expectEqual(@as(u64, 7), only.seqnum);
    try testing.expect((try it.next(testing.allocator)) == null);
}

test "Reader iterates COMPACT-flagged journal with u32 items" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(fmt.incompat.compact);

    const d_msg = try b.writeData("MESSAGE=compact");
    const d_pri = try b.writeData("PRIORITY=3");
    const e = try b.writeEntry(42, 42_000_000, &.{ d_msg, d_pri });
    const arr = try b.writeEntryArray(&.{e});
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(tio, .{ .sub_path = "compact.journal", .data = b.bytes.items });

    var r = try Reader.open(tio, tmp.dir, "compact.journal");
    defer r.deinit();
    try testing.expect(r.isCompact());

    var it = r.iterator();
    var only = (try it.next(testing.allocator)) orelse return error.Missing;
    defer only.deinit();
    try testing.expectEqual(@as(u64, 42), only.seqnum);
    try testing.expectEqualStrings("compact", only.get("MESSAGE").?);
    try testing.expectEqualStrings("3", only.get("PRIORITY").?);
    try testing.expect((try it.next(testing.allocator)) == null);
}

test "Reader decompresses LZ4-flagged data payloads" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(fmt.incompat.compressed_lz4);

    // The plaintext is what readDataField will expose after decompression.
    const d_plain = try b.writeData("PRIORITY=6");
    const d_lz4 = try b.writeDataLz4("MESSAGE=lz4-compressed payload, hello");
    const e = try b.writeEntry(99, 99_999, &.{ d_plain, d_lz4 });
    const arr = try b.writeEntryArray(&.{e});
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(tio, .{ .sub_path = "lz4.journal", .data = b.bytes.items });

    var r = try Reader.open(tio, tmp.dir, "lz4.journal");
    defer r.deinit();

    var it = r.iterator();
    var got = (try it.next(testing.allocator)) orelse return error.Missing;
    defer got.deinit();
    try testing.expectEqualStrings("6", got.get("PRIORITY").?);
    try testing.expectEqualStrings("lz4-compressed payload, hello", got.get("MESSAGE").?);
    try testing.expect((try it.next(testing.allocator)) == null);
}

test "Iterator.seekToEnd jumps past existing entries without reading them" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    const d = try b.writeData("MESSAGE=cold");
    const e1 = try b.writeEntry(1, 1, &.{d});
    const e2 = try b.writeEntry(2, 2, &.{d});
    const arr = try b.writeEntryArray(&.{ e1, e2 });
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(tio, .{ .sub_path = "seek.journal", .data = b.bytes.items });

    var r = try Reader.open(tio, tmp.dir, "seek.journal");
    defer r.deinit();

    var it = r.iterator();
    try it.seekToEnd();
    // No entries should surface from before the seek point.
    try testing.expect((try it.next(testing.allocator)) == null);
    // And we should still remember the last array we walked, so a future
    // refresh+next can resume from new appends.
    try testing.expectEqual(arr, it.last_array_offset);
    try testing.expectEqual(@as(u64, 1), it.last_array_index);
}

test "DataCache returns cached payloads for repeat offsets" {
    var cache: DataCache = .{};
    try testing.expect(cache.get(0) == null);
    try testing.expect(cache.get(64) == null);

    cache.put(64, "MESSAGE=cached-hit");
    const hit = cache.get(64).?;
    try testing.expectEqualStrings("MESSAGE=cached-hit", hit);

    // Different offsets hit different slots.
    cache.put(128, "PRIORITY=3");
    try testing.expectEqualStrings("MESSAGE=cached-hit", cache.get(64).?);
    try testing.expectEqualStrings("PRIORITY=3", cache.get(128).?);

    // Round-robin replacement: fill enough new entries to cycle back to
    // slot 0 (which holds offset 64). After `slot_count` more inserts the
    // oldest entry must have been evicted.
    var k: usize = 0;
    while (k < DataCache.slot_count) : (k += 1) {
        cache.put(@intCast(200 + 8 * k), "x=y");
    }
    try testing.expect(cache.get(64) == null);
}

test "readDataField uses cache on a hit" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    // Two entries share the same DATA object — the second one must
    // be served from cache when the cache is enabled.
    const d_unit = try b.writeData("_SYSTEMD_UNIT=api.service");
    const d_msg1 = try b.writeData("MESSAGE=one");
    const d_msg2 = try b.writeData("MESSAGE=two");
    const e1 = try b.writeEntry(1, 1, &.{ d_unit, d_msg1 });
    const e2 = try b.writeEntry(2, 2, &.{ d_unit, d_msg2 });
    const arr = try b.writeEntryArray(&.{ e1, e2 });
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(tio, .{ .sub_path = "cache.journal", .data = b.bytes.items });

    var r = try Reader.open(tio, tmp.dir, "cache.journal");
    defer r.deinit();

    var it = r.iterator();
    try it.enableCache(testing.allocator);
    defer it.disableCache(testing.allocator);

    var first = (try it.next(testing.allocator)) orelse return error.Missing;
    defer first.deinit();
    try testing.expectEqualStrings("api.service", first.get("_SYSTEMD_UNIT").?);

    // After the first iteration the cache must hold the shared unit's payload.
    try testing.expect(it.cache.?.get(d_unit) != null);

    var second = (try it.next(testing.allocator)) orelse return error.Missing;
    defer second.deinit();
    try testing.expectEqualStrings("api.service", second.get("_SYSTEMD_UNIT").?);
}

test "Reader.open rejects out-of-range entry_array_offset" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    // Point the header at an offset past EOF.
    const fake_offset: u64 = @intCast(b.bytes.items.len + 1024);
    b.patchHeaderEntryArray(fake_offset);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(tio, .{ .sub_path = "bad.journal", .data = b.bytes.items });

    try testing.expectError(error.InvalidOffset, Reader.open(tio, tmp.dir, "bad.journal"));
}

test "Iterator follows next_entry_array_offset chain" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    const d_a = try b.writeData("MESSAGE=a");
    const d_b = try b.writeData("MESSAGE=b");
    const d_c = try b.writeData("MESSAGE=c");
    const e1 = try b.writeEntry(1, 1, &.{d_a});
    const e2 = try b.writeEntry(2, 2, &.{d_b});
    const e3 = try b.writeEntry(3, 3, &.{d_c});

    // Write the second array first so we have its offset to chain from the
    // first. (Both arrays must be reachable through the chain.)
    const arr2 = try b.writeEntryArray(&.{ e2, e3 });
    const arr1 = try b.writeEntryArray(&.{e1});
    // Patch arr1's next_entry_array_offset → arr2.
    const arr1_head: *fmt.EntryArrayHead = @alignCast(@ptrCast(b.bytes.items[arr1..].ptr));
    arr1_head.next_entry_array_offset = arr2;

    b.patchHeaderEntryArray(arr1);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(tio, .{ .sub_path = "chain.journal", .data = b.bytes.items });

    var r = try Reader.open(tio, tmp.dir, "chain.journal");
    defer r.deinit();

    var it = r.iterator();
    var got_seq: [3]u64 = undefined;
    var i: usize = 0;
    while (try it.next(testing.allocator)) |entry| {
        var e = entry;
        defer e.deinit();
        try testing.expect(i < got_seq.len);
        got_seq[i] = e.seqnum;
        i += 1;
    }
    try testing.expectEqual(@as(usize, 3), i);
    try testing.expectEqual([_]u64{ 1, 2, 3 }, got_seq);
}
