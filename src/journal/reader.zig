//! Forward iterator over a single `.journal` file. Walks the entry-array
//! chain starting at `Header.entry_array_offset`, follows each entry's
//! `items[]` to the referenced data objects, and reconstructs the original
//! `KEY=value` field list.
//!
//! Supports non-compact and COMPACT files, uncompressed and LZ4-compressed
//! data objects, and live tailing via `Iterator.refresh`.
//!
//! Two properties of the on-disk format shape the iterator's design:
//!
//!   - Entry arrays are *pre-allocated*. `object.size` gives the slot
//!     capacity, not the number of entries; the writer fills slots in order
//!     and leaves the tail zeroed. A zero slot therefore means "nothing here
//!     yet", not "sparse hole" — the iterator parks on it and retries after
//!     a `refresh` instead of skipping past it.
//!   - Objects are strictly append-only, so every chain pointer moves
//!     forward in the file. A pointer that doesn't is a cycle.

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
/// Upper bound on the number of entry-array hops the iterator will take in
/// its lifetime. Backstop behind the monotonic-offset check in
/// `moveToNextArray`, which catches every cycle a well-formed-looking file
/// can express.
pub const max_entry_arrays: usize = 1_000_000;

/// Bytes read in the first `pread` of an entry object. Sized to cover the
/// 64-byte head plus 28 non-compact items in a single syscall, which is
/// above the field count of a typical journald entry (~20).
const entry_probe_bytes: usize = 512;
/// Bytes pulled per `pread` when walking an entry-array's items. Arrays are
/// read strictly in order, so fetching one 8-byte offset at a time costs a
/// syscall per entry; a window amortises that over 64 entries (128 in
/// COMPACT files).
const array_window_bytes: usize = 512;

/// Bytes read in the first `pread` of a data object. Covers the 64/72-byte
/// head plus the payload of every field except long `MESSAGE` values.
const data_probe_bytes: usize = 512;

/// Size of the file-read window. journald allocates the data objects a new
/// entry introduces contiguously, immediately before the entry object
/// itself, so a read covering one of them usually covers the rest.
///
/// Measured on a 200k-entry fixture (agent field filter, reused arena):
///
///     4 KiB  56 ms   3.6M entries/s
///     8 KiB  44 ms   4.5M
///    16 KiB  39 ms   5.2M
///    32 KiB  35 ms   5.7M
///    64 KiB  34 ms   5.8M
///
/// 16 KiB sits at the knee. Past it the gain is a few percent while every
/// live-tail wake-up pays the larger read to deliver one entry, and the
/// buffer is inline in `Reader`, which callers keep on the stack.
const read_window_bytes: usize = 16 * 1024;

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
    /// A chain pointer did not move forward in the file, or the iterator
    /// took more than `max_entry_arrays` hops. Both mean a malformed file.
    ChainLoop,
} || std.mem.Allocator.Error || error{
    /// Underlying I/O failed. We collapse the std.Io.File errors into a
    /// single variant so the public API stays small.
    IoError,
};

pub const Field = struct {
    /// Borrowed slice into the entry's arena. Valid until `Entry.deinit`.
    key: []const u8,
    /// Borrowed slice into the entry's arena. Valid until `Entry.deinit`.
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
    /// Bytes most recently pulled from the file, serving the speculative
    /// object reads. Objects are immutable once written, so a covered read
    /// can be answered from here without a syscall. Dropped on `refresh`,
    /// which is the point at which the file is allowed to have changed.
    window: [read_window_bytes]u8 = undefined,
    window_pos: u64 = 0,
    window_len: usize = 0,

    /// Opens a journal file in read-only mode. Validates the header magic
    /// and the set of declared incompat flags.
    pub fn open(io: std.Io, dir: std.Io.Dir, path: []const u8) Error!Reader {
        const f = dir.openFile(io, path, .{ .mode = .read_only }) catch return error.IoError;
        errdefer f.close(io);

        const size = f.length(io) catch return error.IoError;
        if (size < @sizeOf(fmt.Header)) return error.InvalidHeaderSize;

        var header_bytes: [@sizeOf(fmt.Header)]u8 = undefined;
        const n = f.readPositionalAll(io, &header_bytes, 0) catch return error.IoError;
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
            .initial_chain_head = self.header.entry_array_offset,
            .compact = compact,
            .array_item_sz = fmt.entryArrayItemSize(compact),
            .entry_item_sz = fmt.entryItemSize(compact),
        };
    }

    /// Re-reads the volatile portion of the file header — just the fields
    /// that change as new entries are appended (tail pointers, entry counts,
    /// chain head). The static fields (signature, machine_id, flags, file
    /// id) never change after open so we don't pay for re-reading them:
    /// 104 bytes from `tail_object_offset` (offset 136) to the end of the
    /// base header, versus 240 for the whole thing.
    pub fn refresh(self: *Reader) Error!void {
        self.file_size = self.file.length(self.io) catch return error.IoError;
        // The file is allowed to have changed underneath us; nothing read
        // before this point may be reused.
        self.window_len = 0;

        const refresh_start: u64 = @offsetOf(fmt.Header, "tail_object_offset");
        const refresh_len = @sizeOf(fmt.Header) - refresh_start;
        var buf: [refresh_len]u8 = undefined;
        const n = self.file.readPositionalAll(self.io, &buf, refresh_start) catch return error.IoError;
        if (n != buf.len) return error.IoError;

        @memcpy(std.mem.asBytes(&self.header)[refresh_start..], &buf);
    }

    /// Reads exactly `dst.len` bytes at `pos`. Errors if the read is short
    /// (truncated file) or runs past `file_size`. The bounds check is done
    /// via subtraction (`file_size - pos`) rather than addition — a crafted
    /// file with `pos` near `u64` max would wrap `pos + dst.len` and slip
    /// past a naïve check, letting the caller read at attacker-controlled
    /// offsets.
    fn readAt(self: *Reader, pos: u64, dst: []u8) Error!void {
        if (pos > self.file_size or dst.len > self.file_size - pos) return error.InvalidOffset;
        const n = self.file.readPositionalAll(self.io, dst, pos) catch return error.IoError;
        if (n != dst.len) return error.IoError;
    }

    /// Reads up to `dst.len` bytes at `pos`, stopping at EOF. Used for the
    /// speculative first read of an object, whose size isn't known until its
    /// header has been parsed — a short tail here is normal, not an error.
    fn readAtClamped(self: *Reader, pos: u64, dst: []u8) Error![]u8 {
        if (pos > self.file_size) return error.InvalidOffset;
        const want = @min(dst.len, self.file_size - pos);
        if (want == 0) return dst[0..0];

        // Already covered by the window? Copy out rather than aliasing it:
        // callers hold the result across further reads, and those may refill
        // the window underneath them.
        if (pos >= self.window_pos and
            pos - self.window_pos + want <= self.window_len)
        {
            const from: usize = @intCast(pos - self.window_pos);
            @memcpy(dst[0..want], self.window[from..][0..want]);
            return dst[0..want];
        }

        // A read wider than the window could never be served from it.
        if (want > self.window.len) {
            const n = self.file.readPositionalAll(self.io, dst[0..want], pos) catch return error.IoError;
            return dst[0..n];
        }

        const fill: usize = @intCast(@min(@as(u64, self.window.len), self.file_size - pos));
        const n = self.file.readPositionalAll(self.io, self.window[0..fill], pos) catch return error.IoError;
        self.window_pos = pos;
        self.window_len = n;
        const give = @min(want, n);
        @memcpy(dst[0..give], self.window[0..give]);
        return dst[0..give];
    }

    /// Like `readAtClamped`, but hands back a view into the window when the
    /// bytes are already there instead of copying them out.
    ///
    /// The view is invalidated by the next read on this reader, so it suits
    /// a caller that consumes the bytes before reading again — which the
    /// data-object path does. `readEntry` cannot use it: it holds its probe
    /// across the field reads that follow.
    ///
    /// Worth the extra contract because the copy it avoids is the full probe
    /// width (512 bytes) for an object whose useful part is usually ~100.
    fn peekAt(self: *Reader, pos: u64, dst: []u8) Error![]const u8 {
        if (pos > self.file_size) return error.InvalidOffset;
        const want = @min(dst.len, self.file_size - pos);
        if (want == 0) return dst[0..0];

        if (pos >= self.window_pos and
            pos - self.window_pos + want <= self.window_len)
        {
            const from: usize = @intCast(pos - self.window_pos);
            return self.window[from..][0..want];
        }
        return self.readAtClamped(pos, dst);
    }

    /// Rejects an object header whose declared `size` would place the object
    /// past the end of the file. Catches corruption early — before we derive
    /// item counts or payload lengths from it — and keeps every subsequent
    /// `offset + size`-style computation inside `u64`.
    fn checkObjectFits(self: *const Reader, offset: u64, size: u64) Error!void {
        if (offset > self.file_size or size > self.file_size - offset) return error.InvalidObjectSize;
    }
};

pub const Iterator = struct {
    reader: *Reader,
    /// Entry-array the cursor sits in. Zero only when the file has no
    /// entry-array chain at all.
    array_offset: u64,
    /// Index of the next item to read inside `array_offset`.
    ///
    /// When `next` returns null the iterator *parks* here rather than
    /// abandoning the position: entry arrays are pre-allocated and filled in
    /// place, so this slot is exactly where the writer will put the next
    /// entry. `refresh` invalidates the cached header and `next` retries
    /// this same index.
    array_index: u64 = 0,
    /// Slot capacity of `array_offset`, derived from its object size. Only
    /// meaningful while `array_loaded` is true.
    array_capacity: u64 = 0,
    /// `next_entry_array_offset` of `array_offset`. Only meaningful while
    /// `array_loaded` is true.
    next_array_offset: u64 = 0,
    /// False when `array_offset`'s header still needs to be read — either
    /// because we just moved there, or because `refresh` invalidated it.
    array_loaded: bool = false,
    /// Snapshot of `Header.entry_array_offset` at iterator creation. Used
    /// by `refresh` to detect a fresh chain head (a file that had no entries
    /// when we opened it, or one the writer re-headed).
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
    /// When set, `next` keeps only these field keys. See `setFieldFilter`.
    field_filter: ?[]const []const u8 = null,
    /// Chain hops taken so far. Only bumps when we actually move to a
    /// different array, so a long-lived tail that re-reads its parked array
    /// on every wake-up never approaches the cap.
    arrays_visited: usize = 0,
    /// Sequentially-filled window over the current array's items.
    /// `item_window_count == 0` means nothing is cached.
    item_window: [array_window_bytes]u8 = undefined,
    item_window_array: u64 = 0,
    item_window_first: u64 = 0,
    item_window_count: u64 = 0,

    /// Advances to the next entry. Returns null when the writer hasn't
    /// produced one yet; call `refresh` and try again to keep tailing.
    /// Caller owns the returned `Entry` and must call `deinit`.
    ///
    /// ## Pass an arena
    ///
    /// Each entry carries its own `ArenaAllocator`, so `allocator` sees one
    /// allocation and one free per entry — roughly 1.4 KB of field bytes for
    /// a typical journald record. Handing this a general-purpose allocator
    /// makes that malloc/free pair the single most expensive thing about
    /// iterating: measured at 512 ms for 200 000 entries, against 91 ms when
    /// the caller supplies an arena it resets between entries (2.2 M
    /// entries/s, zero allocations in steady state):
    ///
    /// ```
    /// var scratch = std.heap.ArenaAllocator.init(gpa);
    /// defer scratch.deinit();
    /// while (true) {
    ///     _ = scratch.reset(.retain_capacity);
    ///     var entry = try it.next(scratch.allocator()) orelse break;
    ///     defer entry.deinit();
    ///     // …use entry; its bytes die at the next reset…
    /// }
    /// ```
    ///
    /// The reset invalidates the previous entry, which is exactly the
    /// lifetime `deinit` already implies.
    pub fn next(self: *Iterator, allocator: std.mem.Allocator) Error!?Entry {
        while (true) {
            if (self.array_offset == 0) return null;
            if (!self.array_loaded) try self.loadArray();

            if (self.array_index >= self.array_capacity) {
                // Array full and consumed. Move on if the writer has linked
                // a successor, otherwise park at the end: a successor may
                // appear before the next `refresh`.
                if (self.next_array_offset == 0) return null;
                try self.moveToNextArray();
                continue;
            }

            const item_offset = try self.readArrayItem(self.array_index);
            if (item_offset == 0) {
                // Unfilled slot. In the last array of the chain this is the
                // live write position — park on it so a later `refresh` +
                // `next` picks the entry up once the writer lands it.
                if (self.next_array_offset == 0) return null;
                // A hole in a mid-chain array can't happen in a well-formed
                // file (arrays are sealed before a successor is linked), so
                // treat the rest of this array as untrustworthy and skip to
                // the successor rather than reading past the hole.
                try self.moveToNextArray();
                continue;
            }

            self.array_index += 1;
            return try self.readEntry(allocator, item_offset);
        }
    }

    /// Picks up whatever the writer has appended since the last call: slots
    /// filled inside the parked array, a newly linked successor array, or a
    /// brand-new chain head. Safe to call after `next` has returned null —
    /// that is exactly when a tail loop should call it.
    pub fn refresh(self: *Iterator) Error!void {
        try self.reader.refresh();

        // Did the writer install a fresh chain head? That happens when the
        // file had no entries at all when we opened it, and after an
        // in-place re-head. Either way our cached offsets mean nothing.
        const fresh_head = self.reader.header.entry_array_offset;
        if (fresh_head != 0 and fresh_head != self.initial_chain_head) {
            self.initial_chain_head = fresh_head;
            self.array_offset = fresh_head;
            self.array_index = 0;
            self.array_capacity = 0;
            self.next_array_offset = 0;
            self.array_loaded = false;
            self.invalidateItemWindow();
            // Object offsets may now mean something different.
            if (self.cache) |c| c.reset();
            return;
        }

        // Otherwise just drop the cached array header and item window. `next`
        // re-reads them and retries `array_index`, which is still the correct
        // resume point — and the window must go because the writer fills
        // slots in place.
        self.array_loaded = false;
        self.invalidateItemWindow();
    }

    /// Reads the header of the array at `array_offset` into the cursor.
    fn loadArray(self: *Iterator) Error!void {
        var head_buf: [@sizeOf(fmt.EntryArrayHead)]u8 = undefined;
        try self.reader.readAt(self.array_offset, &head_buf);
        const head = std.mem.bytesAsValue(fmt.EntryArrayHead, &head_buf).*;

        if (head.object.type != @intFromEnum(fmt.ObjectType.entry_array)) return error.InvalidObjectType;
        if (head.object.size < @sizeOf(fmt.EntryArrayHead)) return error.InvalidObjectSize;
        try self.reader.checkObjectFits(self.array_offset, head.object.size);

        self.array_capacity = (head.object.size - @sizeOf(fmt.EntryArrayHead)) / self.array_item_sz;
        self.next_array_offset = head.next_entry_array_offset;
        self.array_loaded = true;
    }

    /// Follows `next_entry_array_offset`. Callers must have checked that it
    /// is non-zero.
    fn moveToNextArray(self: *Iterator) Error!void {
        const next_off = self.next_array_offset;
        // Journal files are append-only: an array can only ever link to an
        // array allocated after it, so chain offsets increase strictly. A
        // pointer that doesn't move forward is a cycle (`A.next = A` being
        // the cheapest one to craft) or corruption — following it would spin.
        if (next_off <= self.array_offset) return error.ChainLoop;
        if (self.arrays_visited >= max_entry_arrays) return error.ChainLoop;
        self.arrays_visited += 1;

        self.array_offset = next_off;
        self.array_index = 0;
        self.array_capacity = 0;
        self.next_array_offset = 0;
        self.array_loaded = false;
        self.invalidateItemWindow();
    }

    /// Returns the entry-object offset of the i-th item in the current array,
    /// refilling the read window when `index` falls outside it.
    fn readArrayItem(self: *Iterator, index: u64) Error!u64 {
        if (self.item_window_count == 0 or
            self.item_window_array != self.array_offset or
            index < self.item_window_first or
            index - self.item_window_first >= self.item_window_count)
        {
            try self.fillItemWindow(index);
        }
        const at: usize = @intCast((index - self.item_window_first) * self.array_item_sz);
        const raw = self.item_window[at..];
        return if (self.compact)
            std.mem.readInt(u32, raw[0..4], .little)
        else
            std.mem.readInt(u64, raw[0..8], .little);
    }

    /// Reads as many items as fit, starting at `index`.
    fn fillItemWindow(self: *Iterator, index: u64) Error!void {
        const per_window = array_window_bytes / self.array_item_sz;
        const count = @min(@as(u64, per_window), self.array_capacity - index);
        std.debug.assert(count > 0);
        const pos = self.array_offset + @sizeOf(fmt.EntryArrayHead) + index * self.array_item_sz;
        const len: usize = @intCast(count * self.array_item_sz);
        try self.reader.readAt(pos, self.item_window[0..len]);
        self.item_window_array = self.array_offset;
        self.item_window_first = index;
        self.item_window_count = count;
    }

    /// Drops the item window. Called whenever the slots behind it may have
    /// changed under us — the writer fills entry-array slots in place, so a
    /// stale window would hide exactly the entries a tail is waiting for.
    fn invalidateItemWindow(self: *Iterator) void {
        self.item_window_count = 0;
    }

    /// Positions the iterator after the last entry currently in the file,
    /// without resolving any of them. Used by tail consumers that only want
    /// newly-appended entries: reading entries one by one just to discard
    /// them turns a multi-second startup on a large journal into a
    /// tens-of-milliseconds bookkeeping pass.
    ///
    /// Parks on the first unfilled slot of the last array, which is where
    /// the writer will land the next entry.
    pub fn seekToEnd(self: *Iterator) Error!void {
        while (self.array_offset != 0) {
            if (!self.array_loaded) try self.loadArray();
            if (self.next_array_offset == 0) break;
            try self.moveToNextArray();
        }
        if (self.array_offset == 0) return;

        // Slots are filled in order, so the boundary between non-zero and
        // zero items can be bisected instead of scanned: log2(capacity)
        // reads instead of one per slot.
        var lo: u64 = 0;
        var hi: u64 = self.array_capacity;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (try self.readArrayItem(mid) != 0) lo = mid + 1 else hi = mid;
        }
        self.array_index = lo;
    }

    /// Restricts the fields `next` resolves to `keys`; everything else is
    /// left out of the entry.
    ///
    /// Worth setting whenever the consumer reads a fixed handful of fields:
    /// a journald entry carries ~25, and the agent looks at five of them.
    /// Resolving the other twenty costs an arena bump and a payload copy
    /// each — together the largest single item in the read profile.
    ///
    /// With the data cache enabled this compounds: data objects are
    /// deduplicated, so an object's key never changes, and once an offset
    /// has been rejected the object is never read again either.
    ///
    /// `keys` is borrowed and must outlive the iterator. `Entry.get` returns
    /// null for anything not in the filter, so pass every key the consumer
    /// will ask for.
    pub fn setFieldFilter(self: *Iterator, keys: []const []const u8) void {
        self.field_filter = keys;
    }

    inline fn wantsKey(self: *const Iterator, key: []const u8) bool {
        const filter = self.field_filter orelse return true;
        for (filter) |k| {
            if (std.mem.eql(u8, k, key)) return true;
        }
        return false;
    }

    /// Opts the iterator into a DATA-object cache. Cuts repeat reads of
    /// high-cardinality fields (`_SYSTEMD_UNIT`, `SYSLOG_IDENTIFIER`,
    /// `_HOSTNAME`, …) which are referenced by every entry of a service.
    pub fn enableCache(self: *Iterator, allocator: std.mem.Allocator) Error!void {
        if (self.cache != null) return;
        const c = try allocator.create(DataCache);
        c.* = .{};
        c.reset();
        self.cache = c;
    }

    /// Releases the cache allocated by `enableCache`. Safe to call when no
    /// cache is attached. Entries already handed out are unaffected — their
    /// field bytes live in the entry's own arena, never in the cache.
    pub fn disableCache(self: *Iterator, allocator: std.mem.Allocator) void {
        if (self.cache) |c| {
            allocator.destroy(c);
            self.cache = null;
        }
    }

    /// Reads an entry object at `offset` and resolves all its data items into
    /// field key/value pairs.
    ///
    /// Two `pread`s cover a typical entry: one speculative read that captures
    /// the head plus the whole item array, and (only for unusually wide
    /// entries) one for the item bytes that didn't fit.
    fn readEntry(self: *Iterator, allocator: std.mem.Allocator, offset: u64) Error!Entry {
        var probe: [entry_probe_bytes]u8 = undefined;
        const got = try self.reader.readAtClamped(offset, &probe);
        if (got.len < @sizeOf(fmt.EntryHead)) return error.InvalidObjectSize;
        const head = std.mem.bytesAsValue(fmt.EntryHead, got[0..@sizeOf(fmt.EntryHead)]).*;

        if (head.object.type != @intFromEnum(fmt.ObjectType.entry)) return error.InvalidObjectType;
        if (head.object.size < @sizeOf(fmt.EntryHead)) return error.InvalidObjectSize;
        try self.reader.checkObjectFits(offset, head.object.size);

        const compact = self.compact;
        const item_sz = self.entry_item_sz;
        const n_items = (head.object.size - @sizeOf(fmt.EntryHead)) / item_sz;
        if (n_items > max_entry_fields) return error.EntryTooLarge;

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const fields = try a.alloc(Field, n_items);

        const items_len = n_items * item_sz;
        const probed_items = got[@sizeOf(fmt.EntryHead)..];
        const items: []const u8 = if (probed_items.len >= items_len)
            probed_items[0..items_len]
        else blk: {
            const buf = try a.alloc(u8, items_len);
            @memcpy(buf[0..probed_items.len], probed_items);
            try self.reader.readAt(
                offset + @sizeOf(fmt.EntryHead) + probed_items.len,
                buf[probed_items.len..],
            );
            break :blk buf;
        };

        var kept: usize = 0;
        for (0..n_items) |i| {
            const raw_item = items[i * item_sz ..][0..item_sz];
            // Both layouts start with the data-object offset; the non-compact
            // `EntryItem`'s trailing hash is of no use to us.
            const data_offset: u64 = if (compact)
                std.mem.readInt(u32, raw_item[0..4], .little)
            else
                std.mem.readInt(u64, raw_item[0..8], .little);
            if (try self.readDataField(a, data_offset, compact)) |f| {
                fields[kept] = f;
                kept += 1;
            }
        }

        return .{
            .seqnum = head.seqnum,
            .realtime_us = head.realtime,
            .monotonic_us = head.monotonic,
            .boot_id = head.boot_id,
            .fields = fields[0..kept],
            .arena = arena,
        };
    }

    /// Reads a DATA object at `offset` and splits its payload on the first
    /// `=` byte into key + value. Decompresses LZ4-flagged payloads
    /// transparently; XZ and ZSTD are still rejected.
    ///
    /// The returned `Field` always borrows from `arena` — never from the
    /// cache, whose storage is recycled — so it stays valid for the whole
    /// life of the entry.
    /// Returns null when the field is filtered out — see `setFieldFilter`.
    fn readDataField(self: *Iterator, arena: std.mem.Allocator, offset: u64, compact: bool) Error!?Field {
        if (self.cache) |c| {
            switch (c.lookup(offset)) {
                // Already known to be a field the caller does not want: no
                // read, no decompress, no copy.
                .skip => return null,
                .hit => |cached| return try splitField(try arena.dupe(u8, cached)),
                .miss => {},
            }
        }

        var probe: [data_probe_bytes]u8 = undefined;
        const got = try self.reader.peekAt(offset, &probe);
        if (got.len < @sizeOf(fmt.DataHead)) return error.InvalidObjectSize;
        const head = std.mem.bytesAsValue(fmt.DataHead, got[0..@sizeOf(fmt.DataHead)]).*;

        if (head.object.type != @intFromEnum(fmt.ObjectType.data)) return error.InvalidObjectType;
        const compression = head.object.flags & fmt.obj_compression_mask;

        const payload_start = fmt.dataPayloadStart(compact);
        if (head.object.size < payload_start) return error.InvalidObjectSize;
        try self.reader.checkObjectFits(offset, head.object.size);
        const payload_len = head.object.size - payload_start;
        if (payload_len == 0) return error.InvalidField;
        if (payload_len > max_data_payload_bytes) return error.PayloadTooLarge;

        // Bytes of the payload the speculative read already captured.
        const probed = if (got.len > payload_start) got[payload_start..] else got[got.len..];

        const shared = head.n_entries > 1;

        // Decide the filter from the probe alone where possible. A field key
        // sits at the front of the payload, so the ~440 bytes the probe
        // already holds almost always contain it — and a payload wider than
        // the probe would otherwise be pulled into the arena in full before
        // anything looked at its name. Compressed payloads have to be
        // decoded first, so they take the slower path below.
        if (self.field_filter != null and compression == 0) {
            if (std.mem.indexOfScalar(u8, probed, '=')) |eq| {
                if (eq > 0 and !self.wantsKey(probed[0..eq])) {
                    if (shared) {
                        if (self.cache) |c| c.putSkip(offset);
                    }
                    return null;
                }
            }
        }

        var raw: []const u8 = undefined;
        var raw_in_arena = false;
        if (probed.len >= payload_len) {
            raw = probed[0..payload_len];
        } else {
            const buf = try arena.alloc(u8, @intCast(payload_len));
            @memcpy(buf[0..probed.len], probed);
            try self.reader.readAt(offset + payload_start + probed.len, buf[probed.len..]);
            raw = buf;
            raw_in_arena = true;
        }

        // Decode without taking ownership yet. `view` may point into the
        // reader's window or the stack probe — both die before the entry
        // does — but a field the filter rejects should not cost a copy, so
        // the key is inspected first and the bytes are claimed after.
        var view: []const u8 = undefined;
        var view_in_arena = raw_in_arena;
        switch (compression) {
            0 => view = raw,
            fmt.obj_compressed_lz4 => {
                view = lz4.decompressSystemd(arena, raw) catch return error.UnsupportedCompression;
                view_in_arena = true;
            },
            else => return error.UnsupportedCompression,
        }

        // Only cache payloads the file says are shared.
        //
        // A journal mixes a small stable working set — the deduplicated
        // fields of each unit, referenced by every one of its entries — with
        // payloads referenced exactly once (`MESSAGE`, `_PID`, source
        // timestamps). Caching the second kind fills the byte arena and
        // forces a reset that also drops the working set: measured at one
        // full reset every 69 entries, holding the hit rate to 78%.
        //
        // `DataHead.n_entries` is the exact reference count and we have
        // already read it, so there is nothing to guess at. A value of 1 in
        // a live file may grow later; the next miss re-reads the header and
        // admits it then.
        const probe_field = try splitField(view);
        if (!self.wantsKey(probe_field.key)) {
            // Remember the verdict for objects worth a slot, so the same
            // field on every later entry costs nothing at all.
            if (shared) {
                if (self.cache) |c| c.putSkip(offset);
            }
            return null;
        }

        if (self.cache) |c| {
            if (shared) c.put(offset, view);
        }

        // Wanted: the entry has to own these bytes.
        const payload = if (view_in_arena) view else try arena.dupe(u8, view);
        return try splitField(payload);
    }
};

/// Splits a `KEY=value` payload into a `Field`. Shared by the cache-hit
/// and cache-miss paths to keep the split logic in one place.
inline fn splitField(payload: []const u8) Error!Field {
    const eq = std.mem.indexOfScalar(u8, payload, '=') orelse return error.InvalidField;
    if (eq == 0) return error.InvalidField;
    return .{ .key = payload[0..eq], .value = payload[eq + 1 ..] };
}

/// Maps DATA-object file offsets to their decoded payloads.
///
/// An open-addressed table over a fixed byte arena — no allocator traffic
/// after construction, and no per-entry bookkeeping. Values are copied out
/// on every hit, so the storage here is free to be recycled underneath live
/// entries.
///
/// When either the table or the arena fills up the whole cache is dropped
/// and re-warmed rather than evicted slot by slot: the working set is the
/// dedup fields of the units being tailed, which re-populate within a single
/// entry, and a bulk reset keeps `put` branch-free in the common case.
pub const DataCache = struct {
    pub const log2_slots = 9;
    pub const slot_count: usize = 1 << log2_slots;
    pub const arena_bytes: usize = 64 * 1024;
    /// Payloads above this never enter the cache. Long `MESSAGE` values are
    /// unique per entry, so caching them would only churn the arena.
    pub const max_value_bytes: usize = 1024;
    /// Table load factor at which we reset, kept below 1 so probe runs stay
    /// short.
    const max_live = slot_count * 3 / 4;

    const Slot = struct {
        /// 0 = empty. Journal object offsets are never 0 (the header sits
        /// there), so no separate tombstone is needed.
        offset: u64 = 0,
        start: u32 = 0,
        len: u32 = 0,
        /// The caller's field filter rejected this object's key. Data objects
        /// are deduplicated, so a key never changes: once rejected, the
        /// object never has to be read again. Costs a slot but no arena
        /// bytes — the payload is not kept.
        skip: bool = false,
    };

    /// Outcome of a cache lookup.
    pub const Lookup = union(enum) {
        /// Not seen before; the caller has to read the object.
        miss,
        /// Seen, and its key is not one the caller asked for.
        skip,
        /// Seen and wanted — payload follows.
        hit: []const u8,
    };

    slots: [slot_count]Slot = @splat(.{}),
    bytes: [arena_bytes]u8 = undefined,
    used: u32 = 0,
    live: u32 = 0,

    /// Fibonacci hashing — object offsets are 8-aligned and densely packed,
    /// so the low bits alone would collide badly.
    fn slotFor(offset: u64) usize {
        return @intCast((offset *% 0x9E3779B97F4A7C15) >> (64 - log2_slots));
    }

    pub fn lookup(self: *const DataCache, offset: u64) Lookup {
        if (offset == 0) return .miss;
        var i = slotFor(offset);
        for (0..slot_count) |_| {
            const s = &self.slots[i];
            if (s.offset == 0) return .miss;
            if (s.offset == offset) {
                if (s.skip) return .skip;
                return .{ .hit = self.bytes[s.start..][0..s.len] };
            }
            i = (i + 1) & (slot_count - 1);
        }
        return .miss;
    }

    /// Convenience for callers that only care about a stored payload.
    pub fn get(self: *const DataCache, offset: u64) ?[]const u8 {
        return switch (self.lookup(offset)) {
            .hit => |p| p,
            else => null,
        };
    }

    /// Records that `offset` holds a field the caller filtered out. Only
    /// worth remembering for objects several entries reference — a
    /// single-use object would fill the table for one saved read, the same
    /// trade-off `put` makes.
    pub fn putSkip(self: *DataCache, offset: u64) void {
        if (offset == 0) return;
        if (self.live >= max_live) self.reset();
        var i = slotFor(offset);
        while (true) {
            const s = &self.slots[i];
            if (s.offset == 0) break;
            if (s.offset == offset) return;
            i = (i + 1) & (slot_count - 1);
        }
        self.slots[i] = .{ .offset = offset, .skip = true };
        self.live += 1;
    }

    pub fn put(self: *DataCache, offset: u64, payload: []const u8) void {
        if (offset == 0 or payload.len > max_value_bytes) return;
        if (self.live >= max_live or @as(usize, self.used) + payload.len > arena_bytes) {
            self.reset();
        }

        var i = slotFor(offset);
        while (true) {
            const s = &self.slots[i];
            if (s.offset == 0) break;
            if (s.offset == offset) return; // already cached
            i = (i + 1) & (slot_count - 1);
        }

        const start = self.used;
        @memcpy(self.bytes[start..][0..payload.len], payload);
        self.used = start + @as(u32, @intCast(payload.len));
        self.slots[i] = .{ .offset = offset, .start = start, .len = @intCast(payload.len) };
        self.live += 1;
    }

    /// Drops every cached payload. Called when the arena fills and whenever
    /// the iterator's notion of what an offset means may have changed.
    pub fn reset(self: *DataCache) void {
        @memset(&self.slots, .{});
        self.used = 0;
        self.live = 0;
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

    /// Writes a DATA object with raw `KEY=value` payload. Returns its file
    /// offset. Claims two referencing entries so the payload is eligible for
    /// the data cache; use `writeDataShared` to control that explicitly.
    fn writeData(self: *SyntheticBuilder, payload: []const u8) !u64 {
        return self.writeDataRaw(payload, 0, 2);
    }

    /// Writes a DATA object declaring `n_entries` referencing entries — the
    /// count journald maintains, and what the cache's admission test reads.
    fn writeDataShared(self: *SyntheticBuilder, payload: []const u8, n_entries: u64) !u64 {
        return self.writeDataRaw(payload, 0, n_entries);
    }

    /// Writes a DATA object with an explicit ObjectHeader.flags value, used by
    /// tests that want to simulate compressed payloads.
    fn writeDataRaw(self: *SyntheticBuilder, payload: []const u8, obj_flags: u8, n_entries: u64) !u64 {
        try self.padTo8();
        const off = self.bytes.items.len;
        const extra_size: usize = if (self.compact) @sizeOf(fmt.DataCompactExtra) else 0;
        var dh: fmt.DataHead = std.mem.zeroes(fmt.DataHead);
        dh.object.type = @intFromEnum(fmt.ObjectType.data);
        dh.object.flags = obj_flags;
        dh.object.size = @sizeOf(fmt.DataHead) + extra_size + payload.len;
        dh.n_entries = n_entries;
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
        return self.writeDataRaw(wrapped.items, fmt.obj_compressed_lz4, 2);
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

    /// Writes an EntryArray holding `entry_offsets`, sized for exactly that
    /// many slots.
    fn writeEntryArray(self: *SyntheticBuilder, entry_offsets: []const u64) !u64 {
        return self.writeEntryArrayCap(entry_offsets, entry_offsets.len);
    }

    /// Writes an EntryArray with `capacity` slots of which only the first
    /// `entry_offsets.len` are filled — the shape systemd actually writes,
    /// since it pre-allocates arrays and fills them in place afterwards.
    /// Returns the file offset of the array.
    fn writeEntryArrayCap(self: *SyntheticBuilder, entry_offsets: []const u64, capacity: usize) !u64 {
        std.debug.assert(entry_offsets.len <= capacity);
        try self.padTo8();
        const off = self.bytes.items.len;
        const item_sz: usize = if (self.compact) @sizeOf(u32) else @sizeOf(u64);
        var ah: fmt.EntryArrayHead = std.mem.zeroes(fmt.EntryArrayHead);
        ah.object.type = @intFromEnum(fmt.ObjectType.entry_array);
        ah.object.size = @sizeOf(fmt.EntryArrayHead) + item_sz * capacity;
        try self.bytes.appendSlice(self.allocator, std.mem.asBytes(&ah));
        for (entry_offsets) |e| try self.appendArrayItem(e);
        for (entry_offsets.len..capacity) |_| try self.appendArrayItem(0);
        return @intCast(off);
    }

    fn appendArrayItem(self: *SyntheticBuilder, value: u64) !void {
        if (self.compact) {
            const buf: [4]u8 = @bitCast(@as(u32, @intCast(value)));
            try self.bytes.appendSlice(self.allocator, &buf);
        } else {
            const buf: [8]u8 = @bitCast(value);
            try self.bytes.appendSlice(self.allocator, &buf);
        }
    }

    /// Overwrites slot `index` of the array at `array_offset` in place —
    /// exactly what journald does when it links a new entry into an
    /// already-allocated array, without changing the file's size.
    fn fillArraySlot(self: *SyntheticBuilder, array_offset: u64, index: usize, entry_offset: u64) void {
        const item_sz: usize = if (self.compact) 4 else 8;
        const pos = @as(usize, @intCast(array_offset)) + @sizeOf(fmt.EntryArrayHead) + index * item_sz;
        if (self.compact) {
            std.mem.writeInt(u32, self.bytes.items[pos..][0..4], @intCast(entry_offset), .little);
        } else {
            std.mem.writeInt(u64, self.bytes.items[pos..][0..8], entry_offset, .little);
        }
    }

    fn linkArrays(self: *SyntheticBuilder, from: u64, to: u64) void {
        const head: *fmt.EntryArrayHead = @ptrCast(@alignCast(self.bytes.items[@intCast(from)..].ptr));
        head.next_entry_array_offset = to;
    }

    fn patchHeaderEntryArray(self: *SyntheticBuilder, array_offset: u64) void {
        const h_ptr: *fmt.Header = @ptrCast(@alignCast(self.bytes.items[self.header_offset..].ptr));
        h_ptr.entry_array_offset = array_offset;
    }

    fn write(self: *SyntheticBuilder, dir: std.Io.Dir, name: []const u8) !void {
        try dir.writeFile(debug_io, .{ .sub_path = name, .data = self.bytes.items });
    }
};

/// Drains the iterator into a list of seqnums, freeing each entry.
fn drainSeqnums(it: *Iterator, out: *std.ArrayList(u64)) !void {
    while (try it.next(testing.allocator)) |entry| {
        var e = entry;
        defer e.deinit();
        try out.append(testing.allocator, e.seqnum);
    }
}

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

test "Reader.open rejects a file shorter than the base header" {
    const tio = debug_io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(tio, .{ .sub_path = "short.journal", .data = "LPKSHHRH" });
    try testing.expectError(error.InvalidHeaderSize, Reader.open(tio, tmp.dir, "short.journal"));
}

test "Reader.open rejects header_size below the 240-byte base" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);
    const h: *fmt.Header = @ptrCast(@alignCast(b.bytes.items.ptr));
    h.header_size = 128;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "tiny.journal");
    try testing.expectError(error.InvalidHeaderSize, Reader.open(tio, tmp.dir, "tiny.journal"));
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
    try b.write(tmp.dir, "ok.journal");

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
    try b.write(tmp.dir, "xz.journal");
    try testing.expectError(error.UnsupportedIncompatFlag, Reader.open(tio, tmp.dir, "xz.journal"));
}

test "Iterator stops at the first unfilled slot of a pre-allocated array" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);
    const d = try b.writeData("MESSAGE=only");
    const e1 = try b.writeEntry(7, 7_000, &.{d});
    const e2 = try b.writeEntry(8, 8_000, &.{d});
    // Capacity 8, two slots filled — the shape journald leaves on disk.
    const arr = try b.writeEntryArrayCap(&.{ e1, e2 }, 8);
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "prealloc.journal");

    var r = try Reader.open(tio, tmp.dir, "prealloc.journal");
    defer r.deinit();

    var it = r.iterator();
    var seq = std.ArrayList(u64).empty;
    defer seq.deinit(testing.allocator);
    try drainSeqnums(&it, &seq);
    try testing.expectEqualSlices(u64, &.{ 7, 8 }, seq.items);
    // Parked on the first empty slot, ready for the writer to fill it.
    try testing.expectEqual(@as(u64, 2), it.array_index);
    try testing.expectEqual(arr, it.array_offset);
}

test "Iterator treats a leading zero slot as an empty array" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);
    const d = try b.writeData("MESSAGE=unreachable");
    const e = try b.writeEntry(7, 7_000, &.{d});
    // Slot 0 empty, slot 1 filled. A well-formed writer never produces this;
    // slots are filled in order, so slot 0 being zero means "no entries yet"
    // and the entry behind slot 1 is not yet linked.
    const arr = try b.writeEntryArrayCap(&.{}, 2);
    b.fillArraySlot(arr, 1, e);
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "hole.journal");

    var r = try Reader.open(tio, tmp.dir, "hole.journal");
    defer r.deinit();

    var it = r.iterator();
    try testing.expect((try it.next(testing.allocator)) == null);
    try testing.expectEqual(@as(u64, 0), it.array_index);
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
    try b.write(tmp.dir, "compact.journal");

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
    try b.write(tmp.dir, "lz4.journal");

    var r = try Reader.open(tio, tmp.dir, "lz4.journal");
    defer r.deinit();

    var it = r.iterator();
    var got = (try it.next(testing.allocator)) orelse return error.Missing;
    defer got.deinit();
    try testing.expectEqualStrings("6", got.get("PRIORITY").?);
    try testing.expectEqualStrings("lz4-compressed payload, hello", got.get("MESSAGE").?);
    try testing.expect((try it.next(testing.allocator)) == null);
}

test "COMPACT and LZ4 combine (u32 items plus compressed payloads)" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(fmt.incompat.compact | fmt.incompat.compressed_lz4);

    // COMPACT shifts the data payload to offset 72; the LZ4 path has to
    // respect that or it decodes the two extra header words as a block.
    const d_unit = try b.writeDataLz4("_SYSTEMD_UNIT=both.service");
    const d_msg = try b.writeData("MESSAGE=plain alongside compressed");
    const e = try b.writeEntry(5, 5_000, &.{ d_unit, d_msg });
    const arr = try b.writeEntryArrayCap(&.{e}, 4);
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "both.journal");

    var r = try Reader.open(tio, tmp.dir, "both.journal");
    defer r.deinit();

    var it = r.iterator();
    var got = (try it.next(testing.allocator)) orelse return error.Missing;
    defer got.deinit();
    try testing.expectEqualStrings("both.service", got.get("_SYSTEMD_UNIT").?);
    try testing.expectEqualStrings("plain alongside compressed", got.get("MESSAGE").?);
}

test "payloads larger than the speculative probe read are reassembled" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    // Deliberately past `data_probe_bytes` so the two-read path runs, and
    // with distinctive content at both ends so a splice error is visible.
    var big: [4096]u8 = undefined;
    @memcpy(big[0..8], "MESSAGE=");
    for (big[8..], 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));
    const d = try b.writeData(&big);

    // An entry wide enough that its item array outruns `entry_probe_bytes`.
    var items: [64]u64 = undefined;
    @memset(&items, d);
    const e = try b.writeEntry(1, 1, &items);
    const arr = try b.writeEntryArray(&.{e});
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "big.journal");

    var r = try Reader.open(tio, tmp.dir, "big.journal");
    defer r.deinit();

    var it = r.iterator();
    var got = (try it.next(testing.allocator)) orelse return error.Missing;
    defer got.deinit();
    try testing.expectEqual(@as(usize, 64), got.fields.len);
    try testing.expectEqualStrings(big[8..], got.get("MESSAGE").?);
    // Every item pointed at the same data object; all must agree.
    for (got.fields) |f| try testing.expectEqualStrings(big[8..], f.value);
}

test "Iterator.seekToEnd parks on the first unfilled slot" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    const d = try b.writeData("MESSAGE=cold");
    const e1 = try b.writeEntry(1, 1, &.{d});
    const e2 = try b.writeEntry(2, 2, &.{d});
    const arr = try b.writeEntryArrayCap(&.{ e1, e2 }, 16);
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "seek.journal");

    var r = try Reader.open(tio, tmp.dir, "seek.journal");
    defer r.deinit();

    var it = r.iterator();
    try it.seekToEnd();
    // No entries should surface from before the seek point.
    try testing.expect((try it.next(testing.allocator)) == null);
    // Parked right after the last filled slot — not at the array's capacity.
    try testing.expectEqual(arr, it.array_offset);
    try testing.expectEqual(@as(u64, 2), it.array_index);
}

test "seekToEnd on an entirely unfilled array parks at slot 0" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);
    const arr = try b.writeEntryArrayCap(&.{}, 8);
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "empty.journal");

    var r = try Reader.open(tio, tmp.dir, "empty.journal");
    defer r.deinit();

    var it = r.iterator();
    try it.seekToEnd();
    try testing.expectEqual(@as(u64, 0), it.array_index);
    try testing.expect((try it.next(testing.allocator)) == null);
}

test "refresh picks up an entry written into a pre-allocated slot" {
    // The core tail scenario: journald links a new entry by writing its
    // offset into an already-allocated array slot. The file does not grow,
    // no new array appears, and the array's object size is unchanged — the
    // only observable difference is the slot itself.
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    const d_old = try b.writeData("MESSAGE=old");
    const d_new = try b.writeData("MESSAGE=new");
    const e1 = try b.writeEntry(1, 1, &.{d_old});
    const e2 = try b.writeEntry(2, 2, &.{d_new});
    const arr = try b.writeEntryArrayCap(&.{e1}, 8);
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "tail.journal");

    var r = try Reader.open(tio, tmp.dir, "tail.journal");
    defer r.deinit();

    var it = r.iterator();
    try it.seekToEnd();
    try testing.expect((try it.next(testing.allocator)) == null);

    // Writer fills slot 1 in place.
    b.fillArraySlot(arr, 1, e2);
    try b.write(tmp.dir, "tail.journal");

    try it.refresh();
    var got = (try it.next(testing.allocator)) orelse return error.NewEntryLost;
    defer got.deinit();
    try testing.expectEqual(@as(u64, 2), got.seqnum);
    try testing.expectEqualStrings("new", got.get("MESSAGE").?);
    // And nothing more until the writer produces something.
    try testing.expect((try it.next(testing.allocator)) == null);
}

test "refresh does not re-emit entries already consumed" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    const d = try b.writeData("MESSAGE=x");
    const e1 = try b.writeEntry(1, 1, &.{d});
    const e2 = try b.writeEntry(2, 2, &.{d});
    const arr = try b.writeEntryArrayCap(&.{ e1, e2 }, 8);
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "dedup.journal");

    var r = try Reader.open(tio, tmp.dir, "dedup.journal");
    defer r.deinit();

    var it = r.iterator();
    var seq = std.ArrayList(u64).empty;
    defer seq.deinit(testing.allocator);
    try drainSeqnums(&it, &seq);
    try testing.expectEqualSlices(u64, &.{ 1, 2 }, seq.items);

    // Several refresh/drain rounds with no writer activity must stay quiet.
    for (0..3) |_| {
        try it.refresh();
        try drainSeqnums(&it, &seq);
    }
    try testing.expectEqualSlices(u64, &.{ 1, 2 }, seq.items);
}

test "refresh follows a newly linked successor array" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    const d = try b.writeData("MESSAGE=x");
    const e1 = try b.writeEntry(1, 1, &.{d});
    const e2 = try b.writeEntry(2, 2, &.{d});
    const arr1 = try b.writeEntryArray(&.{e1}); // full, capacity 1
    const arr2 = try b.writeEntryArrayCap(&.{e2}, 4);
    b.patchHeaderEntryArray(arr1);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "link.journal");

    var r = try Reader.open(tio, tmp.dir, "link.journal");
    defer r.deinit();

    var it = r.iterator();
    var seq = std.ArrayList(u64).empty;
    defer seq.deinit(testing.allocator);
    // arr2 exists on disk but nothing points at it yet.
    try drainSeqnums(&it, &seq);
    try testing.expectEqualSlices(u64, &.{1}, seq.items);

    b.linkArrays(arr1, arr2);
    try b.write(tmp.dir, "link.journal");

    try it.refresh();
    try drainSeqnums(&it, &seq);
    try testing.expectEqualSlices(u64, &.{ 1, 2 }, seq.items);
}

test "refresh adopts a chain head that appears after open" {
    // A journal file created but not yet written to has
    // entry_array_offset == 0. The tail must notice when the writer
    // installs the first array.
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);
    const d = try b.writeData("MESSAGE=first ever");
    const e = try b.writeEntry(1, 1, &.{d});
    const arr = try b.writeEntryArrayCap(&.{e}, 4);
    // Header still points nowhere.

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "fresh.journal");

    var r = try Reader.open(tio, tmp.dir, "fresh.journal");
    defer r.deinit();

    var it = r.iterator();
    try it.seekToEnd();
    try testing.expect((try it.next(testing.allocator)) == null);

    b.patchHeaderEntryArray(arr);
    try b.write(tmp.dir, "fresh.journal");

    try it.refresh();
    var got = (try it.next(testing.allocator)) orelse return error.Missing;
    defer got.deinit();
    try testing.expectEqualStrings("first ever", got.get("MESSAGE").?);
}

test "long-lived tail does not exhaust the chain-hop budget" {
    // `refresh` re-reads the parked array's header every wake-up. If that
    // counted as a chain hop, a busy agent would hit `max_entry_arrays` and
    // fail after a few days of uptime.
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);
    const d = try b.writeData("MESSAGE=x");
    const e = try b.writeEntry(1, 1, &.{d});
    const arr = try b.writeEntryArrayCap(&.{e}, 4);
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "idle.journal");

    var r = try Reader.open(tio, tmp.dir, "idle.journal");
    defer r.deinit();

    var it = r.iterator();
    var first = (try it.next(testing.allocator)) orelse return error.Missing;
    first.deinit();

    for (0..1000) |_| {
        try it.refresh();
        try testing.expect((try it.next(testing.allocator)) == null);
    }
    try testing.expectEqual(@as(usize, 0), it.arrays_visited);
}

test "DataCache stores, retrieves and resets" {
    var cache: DataCache = .{};
    cache.reset();

    try testing.expect(cache.get(0) == null);
    try testing.expect(cache.get(64) == null);

    cache.put(64, "MESSAGE=cached-hit");
    try testing.expectEqualStrings("MESSAGE=cached-hit", cache.get(64).?);

    cache.put(128, "PRIORITY=3");
    try testing.expectEqualStrings("MESSAGE=cached-hit", cache.get(64).?);
    try testing.expectEqualStrings("PRIORITY=3", cache.get(128).?);

    // Re-putting a live offset must not duplicate it or grow the arena.
    const used_before = cache.used;
    cache.put(64, "MESSAGE=cached-hit");
    try testing.expectEqual(used_before, cache.used);

    cache.reset();
    try testing.expect(cache.get(64) == null);
    try testing.expectEqual(@as(u32, 0), cache.used);
}

test "DataCache survives more distinct offsets than it can hold" {
    var cache: DataCache = .{};
    cache.reset();

    // Overrun both the slot table and the byte arena several times over.
    var value: [256]u8 = undefined;
    @memset(&value, 'v');
    var i: u64 = 8;
    while (i < 8 * 4000) : (i += 8) {
        cache.put(i, &value);
        // Whatever survives eviction must be intact, never truncated garbage.
        if (cache.get(i)) |v| try testing.expectEqualSlices(u8, &value, v);
    }
    // The most recent insert is always present.
    try testing.expect(cache.get(i - 8) != null);
    cache.put(0, "ignored");
    try testing.expect(cache.get(0) == null);
    // Oversized payloads are refused outright.
    var huge: [DataCache.max_value_bytes + 1]u8 = undefined;
    @memset(&huge, 'x');
    cache.put(1_000_000, &huge);
    try testing.expect(cache.get(1_000_000) == null);
}

test "cached fields are owned by the entry, not the cache" {
    // Regression: `readDataField` used to hand back a slice into the cache's
    // own storage on a hit. The very next miss in the same entry recycled
    // that storage, silently rewriting fields the caller already held.
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    // Shape of a real journald entry: a long tail of stable dedup fields
    // shared by every entry (cache hits) plus a couple of unique ones
    // (misses, whose inserts churn the cache underneath the hits).
    const shared_n = 24;
    var key_bufs: [64][48]u8 = undefined;
    var items1: [shared_n + 2]u64 = undefined;
    var items2: [shared_n + 2]u64 = undefined;
    for (0..shared_n) |i| {
        const off = try b.writeData(try std.fmt.bufPrint(&key_bufs[i], "S{d:0>2}=stable-{d:0>2}", .{ i, i }));
        items1[i] = off;
        items2[i] = off;
    }
    for (shared_n..shared_n + 2) |i| {
        items1[i] = try b.writeData(try std.fmt.bufPrint(&key_bufs[i], "U{d:0>2}=e1-{d:0>2}", .{ i, i }));
        items2[i] = try b.writeData(try std.fmt.bufPrint(&key_bufs[i + 16], "U{d:0>2}=e2-{d:0>2}", .{ i, i }));
    }
    const e1 = try b.writeEntry(1, 1, &items1);
    const e2 = try b.writeEntry(2, 2, &items2);
    const arr = try b.writeEntryArray(&.{ e1, e2 });
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "alias.journal");

    var r = try Reader.open(tio, tmp.dir, "alias.journal");
    defer r.deinit();

    var it = r.iterator();
    try it.enableCache(testing.allocator);
    defer it.disableCache(testing.allocator);

    var first = (try it.next(testing.allocator)) orelse return error.Missing;
    first.deinit(); // warms the cache

    var second = (try it.next(testing.allocator)) orelse return error.Missing;
    defer second.deinit();

    // Force the cache to recycle everything while `second` is still alive.
    it.cache.?.reset();
    for (0..DataCache.slot_count) |k| it.cache.?.put(@intCast(8 * (k + 1)), "junk=junk");

    for (second.fields, 0..) |f, i| {
        var expect: [48]u8 = undefined;
        const want = try std.fmt.bufPrint(&expect, "{s}{d:0>2}", .{ if (i < shared_n) "S" else "U", i });
        try testing.expectEqualStrings(want, f.key);
    }
    try testing.expectEqualStrings("stable-00", second.get("S00").?);
    try testing.expectEqualStrings("e2-24", second.get("U24").?);
}

test "cache-enabled iteration matches uncached iteration byte for byte" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    var key_bufs: [40][48]u8 = undefined;
    const d_unit = try b.writeData("_SYSTEMD_UNIT=api.service");
    const d_host = try b.writeData("_HOSTNAME=box");
    var entries: [12]u64 = undefined;
    for (&entries, 0..) |*e, i| {
        const uniq = try b.writeData(try std.fmt.bufPrint(&key_bufs[i], "MESSAGE=line {d}", .{i}));
        e.* = try b.writeEntry(@intCast(i + 1), @intCast(i + 1), &.{ d_unit, d_host, uniq });
    }
    const arr = try b.writeEntryArray(&entries);
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "parity.journal");

    var r = try Reader.open(tio, tmp.dir, "parity.journal");
    defer r.deinit();

    var plain = std.ArrayList(u8).empty;
    defer plain.deinit(testing.allocator);
    var cached = std.ArrayList(u8).empty;
    defer cached.deinit(testing.allocator);

    for ([_]bool{ false, true }) |use_cache| {
        var it = r.iterator();
        if (use_cache) try it.enableCache(testing.allocator);
        defer if (use_cache) it.disableCache(testing.allocator);
        const sink = if (use_cache) &cached else &plain;
        while (try it.next(testing.allocator)) |entry| {
            var e = entry;
            defer e.deinit();
            for (e.fields) |f| {
                try sink.appendSlice(testing.allocator, f.key);
                try sink.append(testing.allocator, '=');
                try sink.appendSlice(testing.allocator, f.value);
                try sink.append(testing.allocator, '\n');
            }
        }
    }
    try testing.expectEqualStrings(plain.items, cached.items);
}

test "enableCache is idempotent and disableCache tolerates no cache" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);
    const arr = try b.writeEntryArrayCap(&.{}, 2);
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "cachectl.journal");

    var r = try Reader.open(tio, tmp.dir, "cachectl.journal");
    defer r.deinit();

    var it = r.iterator();
    it.disableCache(testing.allocator); // no-op, must not crash
    try it.enableCache(testing.allocator);
    const first = it.cache.?;
    try it.enableCache(testing.allocator); // second call must not leak
    try testing.expectEqual(first, it.cache.?);
    it.disableCache(testing.allocator);
    try testing.expect(it.cache == null);
    it.disableCache(testing.allocator);
}

test "refresh clears the data cache when the chain head changes" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);
    const d = try b.writeData("MESSAGE=x");
    const e = try b.writeEntry(1, 1, &.{d});
    const arr = try b.writeEntryArrayCap(&.{e}, 4);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "rehead.journal");

    var r = try Reader.open(tio, tmp.dir, "rehead.journal");
    defer r.deinit();

    var it = r.iterator();
    try it.enableCache(testing.allocator);
    defer it.disableCache(testing.allocator);
    it.cache.?.put(4096, "STALE=value");
    try testing.expect(it.cache.?.get(4096) != null);

    b.patchHeaderEntryArray(arr);
    try b.write(tmp.dir, "rehead.journal");
    try it.refresh();

    try testing.expect(it.cache.?.get(4096) == null);
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
    try b.write(tmp.dir, "bad.journal");

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

    const arr1 = try b.writeEntryArray(&.{e1});
    const arr2 = try b.writeEntryArrayCap(&.{ e2, e3 }, 4);
    b.linkArrays(arr1, arr2);
    b.patchHeaderEntryArray(arr1);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "chain.journal");

    var r = try Reader.open(tio, tmp.dir, "chain.journal");
    defer r.deinit();

    var it = r.iterator();
    var seq = std.ArrayList(u64).empty;
    defer seq.deinit(testing.allocator);
    try drainSeqnums(&it, &seq);
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, seq.items);
    try testing.expectEqual(@as(usize, 1), it.arrays_visited);
}

test "Iterator rejects a self-referencing entry-array cycle" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    // An empty array pointing at itself. The offsets-only-move-forward rule
    // catches this on the first hop instead of after a million reads.
    const arr = try b.writeEntryArray(&.{});
    b.linkArrays(arr, arr);
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "loop.journal");

    var r = try Reader.open(tio, tmp.dir, "loop.journal");
    defer r.deinit();

    var it = r.iterator();
    try testing.expectError(error.ChainLoop, it.next(testing.allocator));

    var it2 = r.iterator();
    try testing.expectError(error.ChainLoop, it2.seekToEnd());
}

test "Iterator rejects a chain pointer that moves backwards" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    const d = try b.writeData("MESSAGE=a");
    const e1 = try b.writeEntry(1, 1, &.{d});
    const arr1 = try b.writeEntryArray(&.{e1});
    const arr2 = try b.writeEntryArray(&.{e1});
    // arr2 points back at arr1 — a two-array cycle.
    b.linkArrays(arr1, arr2);
    b.linkArrays(arr2, arr1);
    b.patchHeaderEntryArray(arr1);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "backwards.journal");

    var r = try Reader.open(tio, tmp.dir, "backwards.journal");
    defer r.deinit();

    var it = r.iterator();
    var seq = std.ArrayList(u64).empty;
    defer seq.deinit(testing.allocator);
    try testing.expectError(error.ChainLoop, drainSeqnums(&it, &seq));
}

test "Iterator rejects an entry-array item pointing at the wrong object type" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    const d = try b.writeData("MESSAGE=not an entry");
    // The array item references the DATA object directly.
    const arr = try b.writeEntryArray(&.{d});
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "wrongtype.journal");

    var r = try Reader.open(tio, tmp.dir, "wrongtype.journal");
    defer r.deinit();

    var it = r.iterator();
    try testing.expectError(error.InvalidObjectType, it.next(testing.allocator));
}

test "Iterator rejects an entry item pointing at a non-DATA object" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    const d = try b.writeData("MESSAGE=ok");
    const e1 = try b.writeEntry(1, 1, &.{d});
    // Entry 2's item points at entry 1 instead of a DATA object.
    const e2 = try b.writeEntry(2, 2, &.{e1});
    const arr = try b.writeEntryArray(&.{e2});
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "baddata.journal");

    var r = try Reader.open(tio, tmp.dir, "baddata.journal");
    defer r.deinit();

    var it = r.iterator();
    try testing.expectError(error.InvalidObjectType, it.next(testing.allocator));
}

test "Iterator rejects an object claiming to extend past EOF" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    const d = try b.writeData("MESSAGE=ok");
    const e = try b.writeEntry(1, 1, &.{d});
    const arr = try b.writeEntryArray(&.{e});
    b.patchHeaderEntryArray(arr);

    // Inflate the DATA object's declared size well past the file.
    const dh: *fmt.DataHead = @ptrCast(@alignCast(b.bytes.items[@intCast(d)..].ptr));
    dh.object.size = 1 << 40;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "past-eof.journal");

    var r = try Reader.open(tio, tmp.dir, "past-eof.journal");
    defer r.deinit();

    var it = r.iterator();
    try testing.expectError(error.InvalidObjectSize, it.next(testing.allocator));
}

test "Iterator rejects an entry with more items than max_entry_fields" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    const d = try b.writeData("MESSAGE=ok");
    const e = try b.writeEntry(1, 1, &.{d});
    const arr = try b.writeEntryArray(&.{e});
    b.patchHeaderEntryArray(arr);

    // Claim an item count above the cap while staying inside the file, so
    // the size check passes and the field-count check is what fires.
    const eh: *fmt.EntryHead = @ptrCast(@alignCast(b.bytes.items[@intCast(e)..].ptr));
    eh.object.size = @sizeOf(fmt.EntryHead) + @sizeOf(fmt.EntryItem) * (max_entry_fields + 1);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Pad the file so the oversized entry object still fits inside it.
    const pad = try testing.allocator.alloc(u8, @sizeOf(fmt.EntryItem) * (max_entry_fields + 1));
    defer testing.allocator.free(pad);
    @memset(pad, 0);
    try b.bytes.appendSlice(testing.allocator, pad);
    try b.write(tmp.dir, "wide.journal");

    var r = try Reader.open(tio, tmp.dir, "wide.journal");
    defer r.deinit();

    var it = r.iterator();
    try testing.expectError(error.EntryTooLarge, it.next(testing.allocator));
}

test "Iterator rejects a data payload without a key separator" {
    const tio = debug_io;
    for ([_][]const u8{ "no-separator-here", "=leading-equals" }) |payload| {
        var b = SyntheticBuilder.init(testing.allocator);
        defer b.deinit();
        try b.writeHeader(0);
        const d = try b.writeData(payload);
        const e = try b.writeEntry(1, 1, &.{d});
        const arr = try b.writeEntryArray(&.{e});
        b.patchHeaderEntryArray(arr);

        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try b.write(tmp.dir, "nofield.journal");

        var r = try Reader.open(tio, tmp.dir, "nofield.journal");
        defer r.deinit();

        var it = r.iterator();
        try testing.expectError(error.InvalidField, it.next(testing.allocator));
    }
}

test "Iterator rejects an empty data payload" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);
    const d = try b.writeData("");
    const e = try b.writeEntry(1, 1, &.{d});
    const arr = try b.writeEntryArray(&.{e});
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "emptydata.journal");

    var r = try Reader.open(tio, tmp.dir, "emptydata.journal");
    defer r.deinit();

    var it = r.iterator();
    try testing.expectError(error.InvalidField, it.next(testing.allocator));
}

test "Iterator rejects a zstd-compressed data object" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    // The file-wide flag is one we accept; the per-object flag is not.
    try b.writeHeader(fmt.incompat.compressed_lz4);
    const d = try b.writeDataRaw("MESSAGE=zstd", fmt.obj_compressed_zstd, 2);
    const e = try b.writeEntry(1, 1, &.{d});
    const arr = try b.writeEntryArray(&.{e});
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "zstd.journal");

    var r = try Reader.open(tio, tmp.dir, "zstd.journal");
    defer r.deinit();

    var it = r.iterator();
    try testing.expectError(error.UnsupportedCompression, it.next(testing.allocator));
}

test "Iterator handles an entry with no items" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);
    const e = try b.writeEntry(11, 11_000, &.{});
    const arr = try b.writeEntryArray(&.{e});
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "noitems.journal");

    var r = try Reader.open(tio, tmp.dir, "noitems.journal");
    defer r.deinit();

    var it = r.iterator();
    var got = (try it.next(testing.allocator)) orelse return error.Missing;
    defer got.deinit();
    try testing.expectEqual(@as(u64, 11), got.seqnum);
    try testing.expectEqual(@as(usize, 0), got.fields.len);
    try testing.expect(got.get("MESSAGE") == null);
}

test "Reader.readAt bounds check resists integer overflow" {
    const tio = debug_io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);
    try b.write(tmp.dir, "overflow.journal");

    var r = try Reader.open(tio, tmp.dir, "overflow.journal");
    defer r.deinit();

    // A crafted `pos` near u64 max would wrap `pos + dst.len` past `file_size`
    // and slip through a naïve additive check. The subtractive check must
    // reject it.
    var buf: [16]u8 = undefined;
    try testing.expectError(error.InvalidOffset, r.readAt(std.math.maxInt(u64) - 4, &buf));
    try testing.expectError(error.InvalidOffset, r.readAt(std.math.maxInt(u64), &buf));
    try testing.expectError(error.InvalidOffset, r.readAtClamped(std.math.maxInt(u64), &buf));
    // Clamped reads stop at EOF rather than erroring.
    const tail_bytes = try r.readAtClamped(r.file_size - 4, &buf);
    try testing.expectEqual(@as(usize, 4), tail_bytes.len);
    const at_eof = try r.readAtClamped(r.file_size, &buf);
    try testing.expectEqual(@as(usize, 0), at_eof.len);
}

test "Reader.refresh picks up header changes and the new file size" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);
    const d = try b.writeData("MESSAGE=x");
    const e = try b.writeEntry(1, 1, &.{d});
    const arr = try b.writeEntryArrayCap(&.{e}, 4);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "hdr.journal");

    var r = try Reader.open(tio, tmp.dir, "hdr.journal");
    defer r.deinit();
    const size_before = r.file_size;
    try testing.expectEqual(@as(u64, 0), r.header.entry_array_offset);

    b.patchHeaderEntryArray(arr);
    const h: *fmt.Header = @ptrCast(@alignCast(b.bytes.items.ptr));
    h.n_entries = 7;
    h.tail_entry_seqnum = 42;
    // Static fields must survive the partial re-read untouched.
    try b.bytes.appendSlice(testing.allocator, &[_]u8{0} ** 64);
    try b.write(tmp.dir, "hdr.journal");

    try r.refresh();
    try testing.expectEqual(arr, r.header.entry_array_offset);
    try testing.expectEqual(@as(u64, 7), r.header.n_entries);
    try testing.expectEqual(@as(u64, 42), r.header.tail_entry_seqnum);
    try testing.expectEqual(size_before + 64, r.file_size);
    try testing.expectEqualSlices(u8, &fmt.signature_magic, &r.header.signature);
    try testing.expectEqual(@as(u64, @sizeOf(fmt.Header)), r.header.header_size);
}

test "only shared data objects enter the cache" {
    // journald mixes a stable working set with payloads referenced by one
    // entry. Admitting the latter fills the byte arena and forces a reset
    // that drops the working set, so the reference count in the object
    // header decides.
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    const shared = try b.writeDataShared("_SYSTEMD_UNIT=api.service", 1000);
    const once = try b.writeDataShared("MESSAGE=seen exactly once here", 1);
    const e = try b.writeEntry(1, 1, &.{ shared, once });
    const arr = try b.writeEntryArray(&.{e});
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "admit.journal");

    var r = try Reader.open(tio, tmp.dir, "admit.journal");
    defer r.deinit();
    var it = r.iterator();
    try it.enableCache(testing.allocator);
    defer it.disableCache(testing.allocator);

    var got = (try it.next(testing.allocator)) orelse return error.Missing;
    defer got.deinit();
    // Both fields resolve correctly...
    try testing.expectEqualStrings("api.service", got.get("_SYSTEMD_UNIT").?);
    try testing.expectEqualStrings("seen exactly once here", got.get("MESSAGE").?);
    // ...but only the shared one is worth arena space.
    try testing.expect(it.cache.?.get(shared) != null);
    try testing.expect(it.cache.?.get(once) == null);
}

test "a single-use payload cannot evict the working set" {
    // The failure this guards against: a long run of unique payloads filling
    // the cache arena and resetting it, throwing away the shared fields that
    // every entry needs.
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    const shared = try b.writeDataShared("_SYSTEMD_UNIT=api.service", 4096);
    var key_buf: [128]u8 = undefined;
    var entries: [400]u64 = undefined;
    for (&entries, 0..) |*slot, i| {
        // Each message is unique and long enough that 400 of them would
        // overrun the cache arena several times over.
        const msg = try std.fmt.bufPrint(&key_buf, "MESSAGE=unique payload number {d} {s}", .{ i, "p" ** 64 });
        const d = try b.writeDataShared(msg, 1);
        slot.* = try b.writeEntry(@intCast(i + 1), 1, &.{ shared, d });
    }
    const arr = try b.writeEntryArray(&entries);
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "evict.journal");

    var r = try Reader.open(tio, tmp.dir, "evict.journal");
    defer r.deinit();
    var it = r.iterator();
    try it.enableCache(testing.allocator);
    defer it.disableCache(testing.allocator);

    var n: usize = 0;
    while (try it.next(testing.allocator)) |entry| {
        var e = entry;
        defer e.deinit();
        try testing.expectEqualStrings("api.service", e.get("_SYSTEMD_UNIT").?);
        n += 1;
    }
    try testing.expectEqual(@as(usize, entries.len), n);
    // Still resident after 400 unique payloads went past it.
    try testing.expect(it.cache.?.get(shared) != null);
}

test "the item window walks an array wider than one window" {
    // `array_window_bytes` holds 64 non-compact items; an array past that
    // must refill transparently and in order.
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    const d = try b.writeData("MESSAGE=x");
    var entries: [300]u64 = undefined;
    for (&entries, 0..) |*slot, i| slot.* = try b.writeEntry(@intCast(i + 1), 1, &.{d});
    const arr = try b.writeEntryArrayCap(&entries, 320);
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "wide.journal");

    var r = try Reader.open(tio, tmp.dir, "wide.journal");
    defer r.deinit();
    var it = r.iterator();

    var seq: u64 = 0;
    while (try it.next(testing.allocator)) |entry| {
        var e = entry;
        defer e.deinit();
        seq += 1;
        try testing.expectEqual(seq, e.seqnum);
    }
    try testing.expectEqual(@as(u64, entries.len), seq);
    // Parked on the first unfilled slot, not at capacity.
    try testing.expectEqual(@as(u64, 300), it.array_index);
}

test "refresh drops both read windows so a tail sees new bytes" {
    // The item window and the file window both cache bytes that a writer can
    // fill in behind us. `refresh` is the point at which the file is allowed
    // to have changed, so both must be dropped there — otherwise a tail
    // serves stale zeros forever.
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    const d1 = try b.writeData("MESSAGE=first");
    const d2 = try b.writeData("MESSAGE=second");
    const e1 = try b.writeEntry(1, 1, &.{d1});
    const e2 = try b.writeEntry(2, 2, &.{d2});
    const arr = try b.writeEntryArrayCap(&.{e1}, 8);
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "win.journal");

    var r = try Reader.open(tio, tmp.dir, "win.journal");
    defer r.deinit();
    var it = r.iterator();

    var first = (try it.next(testing.allocator)) orelse return error.Missing;
    first.deinit();
    // Parked: the window now holds a zero for slot 1.
    try testing.expect((try it.next(testing.allocator)) == null);

    b.fillArraySlot(arr, 1, e2);
    try b.write(tmp.dir, "win.journal");

    try it.refresh();
    var second = (try it.next(testing.allocator)) orelse return error.StaleWindow;
    defer second.deinit();
    try testing.expectEqual(@as(u64, 2), second.seqnum);
    try testing.expectEqualStrings("second", second.get("MESSAGE").?);
}

test "an arena reset between entries is a supported iteration pattern" {
    // The documented way to iterate without per-entry allocator traffic.
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    const unit = try b.writeDataShared("_SYSTEMD_UNIT=api.service", 64);
    var key_buf: [64]u8 = undefined;
    var entries: [64]u64 = undefined;
    for (&entries, 0..) |*slot, i| {
        const msg = try std.fmt.bufPrint(&key_buf, "MESSAGE=line {d}", .{i});
        const d = try b.writeDataShared(msg, 1);
        slot.* = try b.writeEntry(@intCast(i + 1), 1, &.{ unit, d });
    }
    const arr = try b.writeEntryArray(&entries);
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "arena.journal");

    var r = try Reader.open(tio, tmp.dir, "arena.journal");
    defer r.deinit();
    var it = r.iterator();
    try it.enableCache(testing.allocator);
    defer it.disableCache(testing.allocator);

    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    var expect_buf: [64]u8 = undefined;
    var n: usize = 0;
    while (true) {
        _ = scratch.reset(.retain_capacity);
        const entry = try it.next(scratch.allocator()) orelse break;
        var e = entry;
        defer e.deinit();
        const want = try std.fmt.bufPrint(&expect_buf, "line {d}", .{n});
        try testing.expectEqualStrings(want, e.get("MESSAGE").?);
        try testing.expectEqualStrings("api.service", e.get("_SYSTEMD_UNIT").?);
        n += 1;
    }
    try testing.expectEqual(@as(usize, entries.len), n);
}

test "field filter keeps only the requested keys" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    const d_msg = try b.writeDataShared("MESSAGE=hello", 100);
    const d_unit = try b.writeDataShared("_SYSTEMD_UNIT=api.service", 100);
    const d_pid = try b.writeDataShared("_PID=42", 100);
    const d_noise = try b.writeDataShared("_SELINUX_CONTEXT=unconfined_u:x", 100);
    const e = try b.writeEntry(1, 1, &.{ d_noise, d_msg, d_unit, d_noise, d_pid });
    const arr = try b.writeEntryArray(&.{e});
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "filter.journal");

    var r = try Reader.open(tio, tmp.dir, "filter.journal");
    defer r.deinit();
    var it = r.iterator();
    try it.enableCache(testing.allocator);
    defer it.disableCache(testing.allocator);
    it.setFieldFilter(&.{ "MESSAGE", "_PID" });

    var got = (try it.next(testing.allocator)) orelse return error.Missing;
    defer got.deinit();

    try testing.expectEqual(@as(usize, 2), got.fields.len);
    try testing.expectEqualStrings("hello", got.get("MESSAGE").?);
    try testing.expectEqualStrings("42", got.get("_PID").?);
    // Filtered-out keys are simply absent.
    try testing.expect(got.get("_SYSTEMD_UNIT") == null);
    try testing.expect(got.get("_SELINUX_CONTEXT") == null);
}

test "field filter records a skip verdict so the object is read once" {
    // Data objects are deduplicated, so a rejected offset never has to be
    // read again — that is where most of the saving comes from.
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    const d_msg = try b.writeDataShared("MESSAGE=x", 8);
    const d_noise = try b.writeDataShared("_CMDLINE=/usr/bin/svc --flag", 8);
    var entries: [8]u64 = undefined;
    for (&entries, 0..) |*slot, i| {
        slot.* = try b.writeEntry(@intCast(i + 1), 1, &.{ d_noise, d_msg });
    }
    const arr = try b.writeEntryArray(&entries);
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "skip.journal");

    var r = try Reader.open(tio, tmp.dir, "skip.journal");
    defer r.deinit();
    var it = r.iterator();
    try it.enableCache(testing.allocator);
    defer it.disableCache(testing.allocator);
    it.setFieldFilter(&.{"MESSAGE"});

    var n: usize = 0;
    while (try it.next(testing.allocator)) |entry| {
        var e = entry;
        defer e.deinit();
        try testing.expectEqual(@as(usize, 1), e.fields.len);
        n += 1;
    }
    try testing.expectEqual(@as(usize, entries.len), n);

    // The rejected offset is remembered; the wanted one is cached with its
    // payload.
    try testing.expectEqual(DataCache.Lookup.skip, it.cache.?.lookup(d_noise));
    try testing.expect(it.cache.?.get(d_msg) != null);
}

test "no filter still yields every field" {
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);
    const a1 = try b.writeData("A=1");
    const a2 = try b.writeData("B=2");
    const a3 = try b.writeData("C=3");
    const e = try b.writeEntry(1, 1, &.{ a1, a2, a3 });
    const arr = try b.writeEntryArray(&.{e});
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "nofilter.journal");

    var r = try Reader.open(tio, tmp.dir, "nofilter.journal");
    defer r.deinit();
    var it = r.iterator();
    var got = (try it.next(testing.allocator)) orelse return error.Missing;
    defer got.deinit();
    try testing.expectEqual(@as(usize, 3), got.fields.len);
}

test "field filter works without the data cache" {
    // Without a cache there is nowhere to record the verdict, so every
    // object is still read — but the copy into the entry is still skipped.
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);
    const d_msg = try b.writeData("MESSAGE=kept");
    const d_other = try b.writeData("_COMM=dropped");
    const e = try b.writeEntry(1, 1, &.{ d_other, d_msg });
    const arr = try b.writeEntryArray(&.{e});
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "nocache.journal");

    var r = try Reader.open(tio, tmp.dir, "nocache.journal");
    defer r.deinit();
    var it = r.iterator();
    it.setFieldFilter(&.{"MESSAGE"});

    var got = (try it.next(testing.allocator)) orelse return error.Missing;
    defer got.deinit();
    try testing.expectEqual(@as(usize, 1), got.fields.len);
    try testing.expectEqualStrings("kept", got.get("MESSAGE").?);
}

test "window-borrowed payloads survive interleaved large and small fields" {
    // `readDataField` reads its object through `peekAt`, which hands back a
    // slice of the reader's window instead of copying it out. That is only
    // sound because nothing re-reads the file before the bytes are claimed —
    // a field wide enough to need a second read must copy what it already
    // has *first*. Mixing widths inside one entry is what exercises it.
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    var wide: [3000]u8 = undefined;
    @memcpy(wide[0..5], "WIDE=");
    for (wide[5..], 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));

    const d_small1 = try b.writeDataShared("A=first", 4);
    const d_wide = try b.writeDataShared(&wide, 4);
    const d_small2 = try b.writeDataShared("B=second", 4);
    var far: [2500]u8 = undefined;
    @memcpy(far[0..5], "FAR2=");
    for (far[5..], 0..) |*c, i| c.* = 'A' + @as(u8, @intCast(i % 26));
    const d_far = try b.writeDataShared(&far, 4);

    var entries: [4]u64 = undefined;
    for (&entries, 0..) |*slot, i| {
        slot.* = try b.writeEntry(@intCast(i + 1), 1, &.{ d_small1, d_wide, d_small2, d_far });
    }
    const arr = try b.writeEntryArray(&entries);
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "window.journal");

    var r = try Reader.open(tio, tmp.dir, "window.journal");
    defer r.deinit();
    var it = r.iterator();
    try it.enableCache(testing.allocator);
    defer it.disableCache(testing.allocator);

    var n: usize = 0;
    while (try it.next(testing.allocator)) |entry| {
        var e = entry;
        defer e.deinit();
        try testing.expectEqualStrings("first", e.get("A").?);
        try testing.expectEqualStrings("second", e.get("B").?);
        try testing.expectEqualStrings(wide[5..], e.get("WIDE").?);
        try testing.expectEqualStrings(far[5..], e.get("FAR2").?);
        n += 1;
    }
    try testing.expectEqual(@as(usize, entries.len), n);
}

/// Totals the bytes an allocator is asked for, so a test can compare the
/// memory two code paths demand rather than inspecting arena internals.
const ByteCounter = struct {
    child: std.mem.Allocator,
    bytes: usize = 0,

    fn allocator(self: *ByteCounter) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = cAlloc,
            .resize = cResize,
            .remap = cRemap,
            .free = cFree,
        } };
    }
    fn cAlloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *ByteCounter = @ptrCast(@alignCast(ctx));
        self.bytes += len;
        return self.child.rawAlloc(len, a, ra);
    }
    fn cResize(ctx: *anyopaque, b: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *ByteCounter = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(b, a, n, ra);
    }
    fn cRemap(ctx: *anyopaque, b: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *ByteCounter = @ptrCast(@alignCast(ctx));
        self.bytes += n;
        return self.child.rawRemap(b, a, n, ra);
    }
    fn cFree(ctx: *anyopaque, b: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *ByteCounter = @ptrCast(@alignCast(ctx));
        self.child.rawFree(b, a, ra);
    }
};

test "a filtered-out field is rejected before it is copied" {
    // The key is read off the borrowed bytes and the payload is claimed only
    // if the filter wants it. A bulky rejected field must therefore not show
    // up in the memory the entries demand.
    const tio = debug_io;
    var b = SyntheticBuilder.init(testing.allocator);
    defer b.deinit();
    try b.writeHeader(0);

    // Wider than `data_probe_bytes`, so without an early verdict the whole
    // thing is pulled into the entry arena before anything reads its name.
    var bulky: [64 * 1024]u8 = undefined;
    @memcpy(bulky[0..7], "_BULKY=");
    @memset(bulky[7..], 'z');

    const d_msg = try b.writeDataShared("MESSAGE=kept", 8);
    var entries: [8]u64 = undefined;
    for (&entries, 0..) |*slot, i| {
        // Unique, so no skip verdict can be cached: the object is re-read on
        // every entry and has to be rejected cheaply each time.
        const d_bulk = try b.writeDataShared(&bulky, 1);
        slot.* = try b.writeEntry(@intCast(i + 1), 1, &.{ d_bulk, d_msg });
    }
    const arr = try b.writeEntryArray(&entries);
    b.patchHeaderEntryArray(arr);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try b.write(tmp.dir, "cheapskip.journal");

    var used: [2]usize = undefined;
    for ([_]bool{ false, true }, 0..) |filtered, idx| {
        var r = try Reader.open(tio, tmp.dir, "cheapskip.journal");
        defer r.deinit();
        var it = r.iterator();
        try it.enableCache(testing.allocator);
        defer it.disableCache(testing.allocator);
        if (filtered) it.setFieldFilter(&.{"MESSAGE"});

        var counter = ByteCounter{ .child = testing.allocator };
        var n: usize = 0;
        while (try it.next(counter.allocator())) |entry| {
            var e = entry;
            defer e.deinit();
            try testing.expectEqualStrings("kept", e.get("MESSAGE").?);
            try testing.expectEqual(@as(usize, if (filtered) 1 else 2), e.fields.len);
            n += 1;
        }
        try testing.expectEqual(@as(usize, entries.len), n);
        used[idx] = counter.bytes;
    }

    // Eight entries each carrying a 64 KB field the filter drops: without an
    // early verdict those bytes land in every entry's arena.
    try testing.expect(used[1] * 2 < used[0]);
}
