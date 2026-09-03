//! Container layer of a Windows Event Log file: header, chunks, records.
//!
//! This layer stops at the record boundary. It hands back the BinXml stream
//! of each record and the chunk it came from — the chunk matters, because a
//! record's names and templates live in that chunk's caches and nowhere else.
//! Turning that stream into text is `binxml.zig`'s job.
//!
//! ## Why a chunk at a time
//!
//! Chunks are a fixed 64 KiB and self-contained, so the whole reader needs
//! exactly one buffer that the caller owns, reused for every chunk. Nothing
//! here allocates. A 4 GiB event log costs the same 64 KiB as an empty one.
//!
//! ## Reading a log that is being written
//!
//! `.evtx` is a circular buffer belonging to a running service. Two things
//! follow, and both are handled rather than treated as corruption:
//!
//!   * The dirty flag is set for the whole life of a running system. It says
//!     "not closed cleanly", which is the normal state, so it is reported and
//!     never used to reject a file.
//!   * The last chunk's records checksum covers only what was committed. A
//!     chunk being appended to right now fails it routinely. Verification is
//!     therefore something a caller asks for per chunk, not a gate this layer
//!     applies on its own.

const std = @import("std");
const fmt = @import("format.zig");

pub const Error = error{
    NotEvtx,
    UnsupportedVersion,
    BadFileHeader,
    BadChunkHeader,
    ChunkOutOfRange,
    ShortRead,
    IoError,
};

/// What a chunk's checksums say about it.
pub const Integrity = struct {
    /// The header and both caches match `header_checksum`.
    header_ok: bool,
    /// The records region matches `records_checksum`. False is expected for
    /// the chunk currently being appended to.
    records_ok: bool,

    pub fn intact(self: Integrity) bool {
        return self.header_ok and self.records_ok;
    }
};

/// One event record, still in wire form.
pub const Record = struct {
    /// Monotonic identifier assigned by the log service.
    id: u64,
    /// When the record was written, in Unix milliseconds.
    written_ms: i64,
    /// The record's BinXml stream: everything between the header and the
    /// trailing size copy.
    binxml: []const u8,
    /// Chunk-relative offset of the record, for diagnostics.
    offset: usize,
};

/// A parsed chunk, borrowing the caller's buffer.
pub const Chunk = struct {
    /// The whole 64 KiB, so records can resolve chunk-relative offsets.
    bytes: []const u8,
    header: fmt.ChunkHeader,

    /// Parses `bytes` as a chunk. Does not verify checksums — see `verify`.
    pub fn parse(bytes: []const u8) Error!Chunk {
        if (bytes.len < fmt.chunk_size) return Error.ShortRead;
        const header = std.mem.bytesToValue(fmt.ChunkHeader, bytes[0..fmt.ChunkHeader.size]);
        if (!std.mem.eql(u8, &header.magic, &fmt.chunk_magic)) return Error.BadChunkHeader;

        // `free_space_offset` bounds every record walk, so it has to be
        // inside the chunk and past the header before anything reads it.
        if (header.free_space_offset < fmt.chunk_records_offset or
            header.free_space_offset > fmt.chunk_size) return Error.BadChunkHeader;

        return .{ .bytes = bytes[0..fmt.chunk_size], .header = header };
    }

    pub fn verify(self: Chunk) Integrity {
        const head = fmt.crc32Split(
            self.bytes[0..120],
            self.bytes[128..fmt.chunk_records_offset],
        );
        const body = fmt.crc32(
            self.bytes[fmt.chunk_records_offset..self.header.free_space_offset],
        );
        return .{
            .header_ok = head == self.header.header_checksum,
            .records_ok = body == self.header.records_checksum,
        };
    }

    pub fn records(self: *const Chunk) RecordIterator {
        return .{ .chunk = self, .pos = fmt.chunk_records_offset };
    }
};

/// Walks the records of one chunk in write order.
///
/// Stops at the first thing that does not look like a record rather than
/// trying to resynchronise. In a circular log the bytes past the last commit
/// are whatever the previous generation left there, and hunting for a
/// plausible signature in them invents records that were never written.
pub const RecordIterator = struct {
    chunk: *const Chunk,
    pos: usize,

    pub fn next(self: *RecordIterator) ?Record {
        const limit = self.chunk.header.free_space_offset;
        if (self.pos + fmt.min_record_size > limit) return null;

        const head = std.mem.bytesToValue(
            fmt.RecordHeader,
            self.chunk.bytes[self.pos..][0..fmt.record_header_size],
        );
        if (head.magic != fmt.record_magic) return null;

        const size: usize = head.size;
        if (size < fmt.min_record_size or size > fmt.max_record_size) return null;
        if (self.pos + size > limit) return null;

        // The trailing copy of the size is the format's own consistency
        // check. A mismatch means the record was never finished, so the walk
        // ends here instead of stepping into whatever follows.
        const trailer = std.mem.readInt(
            u32,
            self.chunk.bytes[self.pos + size - fmt.record_trailer_size ..][0..4],
            .little,
        );
        if (trailer != head.size) return null;

        const body_start = self.pos + fmt.record_header_size;
        const body_end = self.pos + size - fmt.record_trailer_size;
        const rec = Record{
            .id = head.record_id,
            .written_ms = fmt.filetimeToUnixMs(head.written_time),
            .binxml = self.chunk.bytes[body_start..body_end],
            .offset = self.pos,
        };
        self.pos += size;
        return rec;
    }
};

/// Parses the 128-byte file header out of the leading block.
pub fn parseFileHeader(block: []const u8) Error!fmt.FileHeader {
    if (block.len < fmt.FileHeader.size) return Error.ShortRead;
    const header = std.mem.bytesToValue(fmt.FileHeader, block[0..fmt.FileHeader.size]);
    if (!std.mem.eql(u8, &header.magic, &fmt.file_magic)) return Error.NotEvtx;
    // 3.x is what every Windows since Vista writes. Refusing anything else is
    // better than silently misreading a layout we have not seen.
    if (header.major_version != 3) return Error.UnsupportedVersion;
    if (header.header_size != fmt.FileHeader.size) return Error.BadFileHeader;
    if (header.checksum != fmt.crc32(block[0..120])) return Error.BadFileHeader;
    return header;
}

/// File-backed reader. Owns nothing: the 64 KiB chunk buffer is the caller's,
/// reused for every chunk.
pub const Reader = struct {
    io: std.Io,
    file: std.Io.File,
    file_size: u64,
    header: fmt.FileHeader,
    chunk_buf: []u8,

    /// `chunk_buf` must be at least `fmt.chunk_size` bytes.
    pub fn open(
        io: std.Io,
        dir: std.Io.Dir,
        path: []const u8,
        chunk_buf: []u8,
    ) (Error || std.Io.File.OpenError)!Reader {
        std.debug.assert(chunk_buf.len >= fmt.chunk_size);
        const file = try dir.openFile(io, path, .{});
        errdefer file.close(io);

        const size = file.length(io) catch return Error.IoError;
        var block: [fmt.FileHeader.size]u8 = undefined;
        const n = file.readPositional(io, &.{&block}, 0) catch return Error.IoError;
        if (n < block.len) return Error.ShortRead;

        return .{
            .io = io,
            .file = file,
            .file_size = size,
            .header = try parseFileHeader(&block),
            .chunk_buf = chunk_buf,
        };
    }

    pub fn close(self: *Reader) void {
        self.file.close(self.io);
        self.* = undefined;
    }

    /// True when the file was not closed cleanly — the normal state of a log
    /// on a running machine, not a reason to stop.
    pub fn isDirty(self: *const Reader) bool {
        return self.header.flags & 1 != 0;
    }

    /// Chunks actually present in the file, which can be fewer than the
    /// header claims if the file was truncated in transit.
    pub fn chunkCount(self: *const Reader) usize {
        if (self.file_size <= fmt.header_block_size) return 0;
        const usable = self.file_size - fmt.header_block_size;
        const present: usize = @intCast(usable / fmt.chunk_size);
        return @min(present, self.header.chunk_count);
    }

    /// Reads chunk `index` into the caller's buffer and parses it.
    pub fn chunk(self: *Reader, index: usize) Error!Chunk {
        if (index >= self.chunkCount()) return Error.ChunkOutOfRange;
        const pos = fmt.header_block_size + index * fmt.chunk_size;
        const dst = self.chunk_buf[0..fmt.chunk_size];
        const n = self.file.readPositional(self.io, &.{dst}, pos) catch return Error.IoError;
        if (n < dst.len) return Error.ShortRead;
        return Chunk.parse(dst);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;
const test_io = std.Options.debug_io;

/// Builds a syntactically valid `.evtx` in memory.
///
/// The reader is written against the specification, but the specification is
/// not a test — so the fixtures are built here from the same field offsets the
/// reader reads, and the checksums are computed the way the format defines
/// them rather than copied from the reader. A file this builder produces is
/// one a real parser should accept; that is the strongest claim available
/// without a genuine log to read.
const Builder = struct {
    bytes: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    chunks: u16 = 0,
    next_id: u64 = 1,

    fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Builder) void {
        self.bytes.deinit(self.allocator);
    }

    /// Appends one chunk holding `payloads`, one record each.
    fn addChunk(self: *Builder, payloads: []const []const u8) !void {
        var chunk = [_]u8{0} ** fmt.chunk_size;
        @memcpy(chunk[0..8], &fmt.chunk_magic);

        var pos: usize = fmt.chunk_records_offset;
        const first_id = self.next_id;
        var last_offset: usize = pos;
        for (payloads) |payload| {
            const size = fmt.record_header_size + payload.len + fmt.record_trailer_size;
            last_offset = pos;
            std.mem.writeInt(u32, chunk[pos..][0..4], fmt.record_magic, .little);
            std.mem.writeInt(u32, chunk[pos + 4 ..][0..4], @intCast(size), .little);
            std.mem.writeInt(u64, chunk[pos + 8 ..][0..8], self.next_id, .little);
            // 2026-01-01T00:00:00Z as a FILETIME, plus a second per record.
            const ft: u64 = (11_644_473_600 + 1_767_225_600 + self.next_id) * 10_000_000;
            std.mem.writeInt(u64, chunk[pos + 16 ..][0..8], ft, .little);
            @memcpy(chunk[pos + fmt.record_header_size ..][0..payload.len], payload);
            std.mem.writeInt(u32, chunk[pos + size - 4 ..][0..4], @intCast(size), .little);
            pos += size;
            self.next_id += 1;
        }

        std.mem.writeInt(u64, chunk[8..][0..8], first_id, .little);
        std.mem.writeInt(u64, chunk[16..][0..8], self.next_id - 1, .little);
        std.mem.writeInt(u64, chunk[24..][0..8], first_id, .little);
        std.mem.writeInt(u64, chunk[32..][0..8], self.next_id - 1, .little);
        std.mem.writeInt(u32, chunk[40..][0..4], 128, .little);
        std.mem.writeInt(u32, chunk[44..][0..4], @intCast(last_offset), .little);
        std.mem.writeInt(u32, chunk[48..][0..4], @intCast(pos), .little);
        std.mem.writeInt(u32, chunk[52..][0..4], fmt.crc32(chunk[fmt.chunk_records_offset..pos]), .little);
        const head_crc = fmt.crc32Split(chunk[0..120], chunk[128..fmt.chunk_records_offset]);
        std.mem.writeInt(u32, chunk[124..][0..4], head_crc, .little);

        try self.bytes.appendSlice(self.allocator, &chunk);
        self.chunks += 1;
    }

    /// Finishes the file by prepending the header block.
    fn finish(self: *Builder) ![]const u8 {
        var block = [_]u8{0} ** fmt.header_block_size;
        @memcpy(block[0..8], &fmt.file_magic);
        std.mem.writeInt(u64, block[8..][0..8], 0, .little);
        std.mem.writeInt(u64, block[16..][0..8], self.chunks -| 1, .little);
        std.mem.writeInt(u64, block[24..][0..8], self.next_id, .little);
        std.mem.writeInt(u32, block[32..][0..4], fmt.FileHeader.size, .little);
        std.mem.writeInt(u16, block[36..][0..2], 1, .little);
        std.mem.writeInt(u16, block[38..][0..2], 3, .little);
        std.mem.writeInt(u16, block[40..][0..2], fmt.header_block_size, .little);
        std.mem.writeInt(u16, block[42..][0..2], self.chunks, .little);
        std.mem.writeInt(u32, block[120..][0..4], 1, .little); // dirty, as a live log is
        std.mem.writeInt(u32, block[124..][0..4], fmt.crc32(block[0..120]), .little);

        try self.bytes.insertSlice(self.allocator, 0, &block);
        return self.bytes.items;
    }
};

fn buildFile(b: *Builder) ![]const u8 {
    return b.finish();
}

test "file header round-trips through the builder" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.addChunk(&.{"payload"});
    const bytes = try buildFile(&b);

    const h = try parseFileHeader(bytes);
    try testing.expectEqual(@as(u16, 3), h.major_version);
    try testing.expectEqual(@as(u16, 1), h.chunk_count);
    try testing.expectEqual(@as(u32, 1), h.flags & 1);
}

test "a file that is not evtx is rejected by magic, not by luck" {
    var block = [_]u8{0} ** fmt.header_block_size;
    @memcpy(block[0..8], "NotElf\x00\x00");
    try testing.expectError(Error.NotEvtx, parseFileHeader(&block));
}

test "a corrupted file header fails its checksum" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.addChunk(&.{"payload"});
    const bytes = try buildFile(&b);
    const mutable = @constCast(bytes);

    mutable[24] ^= 0xff; // next_record_id, covered by the checksum
    try testing.expectError(Error.BadFileHeader, parseFileHeader(mutable));
}

test "an unsupported major version is refused rather than guessed at" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.addChunk(&.{"payload"});
    const bytes = try buildFile(&b);
    const mutable = @constCast(bytes);

    std.mem.writeInt(u16, mutable[38..][0..2], 4, .little);
    std.mem.writeInt(u32, mutable[124..][0..4], fmt.crc32(mutable[0..120]), .little);
    try testing.expectError(Error.UnsupportedVersion, parseFileHeader(mutable));
}

test "records iterate in write order with ids and timestamps" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.addChunk(&.{ "first", "second", "third" });
    const bytes = try buildFile(&b);

    const chunk = try Chunk.parse(bytes[fmt.header_block_size..]);
    try testing.expect(chunk.verify().intact());

    var it = chunk.records();
    var seen: usize = 0;
    var last_ms: i64 = 0;
    for ([_][]const u8{ "first", "second", "third" }) |want| {
        const rec = it.next() orelse return error.MissingRecord;
        try testing.expectEqualSlices(u8, want, rec.binxml);
        try testing.expectEqual(@as(u64, seen + 1), rec.id);
        try testing.expect(rec.written_ms > last_ms);
        last_ms = rec.written_ms;
        seen += 1;
    }
    try testing.expectEqual(@as(?Record, null), it.next());
}

test "the walk stops at free space instead of reading old generations" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.addChunk(&.{"only"});
    const bytes = try buildFile(&b);
    const mutable = @constCast(bytes);

    // Plant a complete, plausible record past free_space_offset — the shape
    // a circular log leaves behind when it wraps.
    const chunk_at = fmt.header_block_size;
    const stale = chunk_at + 4096;
    std.mem.writeInt(u32, mutable[stale..][0..4], fmt.record_magic, .little);
    std.mem.writeInt(u32, mutable[stale + 4 ..][0..4], 32, .little);
    std.mem.writeInt(u32, mutable[stale + 28 ..][0..4], 32, .little);

    const chunk = try Chunk.parse(mutable[chunk_at..]);
    var it = chunk.records();
    _ = it.next() orelse return error.MissingRecord;
    try testing.expectEqual(@as(?Record, null), it.next());
}

test "a record whose trailing size disagrees ends the walk" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.addChunk(&.{ "first", "second" });
    const bytes = try buildFile(&b);
    const mutable = @constCast(bytes);

    // Corrupt the first record's trailer. It was never finished, so nothing
    // after it can be trusted to start where we think it does.
    const first = fmt.header_block_size + fmt.chunk_records_offset;
    const size = std.mem.readInt(u32, mutable[first + 4 ..][0..4], .little);
    std.mem.writeInt(u32, mutable[first + size - 4 ..][0..4], size + 1, .little);

    const chunk = try Chunk.parse(mutable[fmt.header_block_size..]);
    var it = chunk.records();
    try testing.expectEqual(@as(?Record, null), it.next());
}

test "a chunk with an out-of-range free space offset is refused" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.addChunk(&.{"x"});
    const bytes = try buildFile(&b);
    const mutable = @constCast(bytes);

    std.mem.writeInt(u32, mutable[fmt.header_block_size + 48 ..][0..4], fmt.chunk_size + 1, .little);
    try testing.expectError(Error.BadChunkHeader, Chunk.parse(mutable[fmt.header_block_size..]));

    std.mem.writeInt(u32, mutable[fmt.header_block_size + 48 ..][0..4], 8, .little);
    try testing.expectError(Error.BadChunkHeader, Chunk.parse(mutable[fmt.header_block_size..]));
}

test "a half-written chunk keeps its header but fails its records checksum" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.addChunk(&.{ "first", "second" });
    const bytes = try buildFile(&b);
    const mutable = @constCast(bytes);

    // Touch a record byte without updating the records checksum — what the
    // service leaves behind mid-append.
    mutable[fmt.header_block_size + fmt.chunk_records_offset + fmt.record_header_size] ^= 0xff;

    const chunk = try Chunk.parse(mutable[fmt.header_block_size..]);
    const integrity = chunk.verify();
    try testing.expect(integrity.header_ok);
    try testing.expect(!integrity.records_ok);
    // And the records are still walkable, which is the point.
    var it = chunk.records();
    _ = it.next() orelse return error.MissingRecord;
}

test "reading through the file reader yields every chunk" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.addChunk(&.{ "a", "b" });
    try b.addChunk(&.{"c"});
    const bytes = try buildFile(&b);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(test_io, .{ .sub_path = "test.evtx", .data = bytes });

    const buf = try testing.allocator.alloc(u8, fmt.chunk_size);
    defer testing.allocator.free(buf);

    var r = try Reader.open(test_io, tmp.dir, "test.evtx", buf);
    defer r.close();

    try testing.expect(r.isDirty());
    try testing.expectEqual(@as(usize, 2), r.chunkCount());

    var total: usize = 0;
    for (0..r.chunkCount()) |i| {
        const chunk = try r.chunk(i);
        try testing.expect(chunk.verify().intact());
        var it = chunk.records();
        while (it.next()) |_| total += 1;
    }
    try testing.expectEqual(@as(usize, 3), total);
    try testing.expectError(Error.ChunkOutOfRange, r.chunk(2));
}

test "a truncated file reports only the chunks that are present" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    try b.addChunk(&.{"a"});
    try b.addChunk(&.{"b"});
    const bytes = try buildFile(&b);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Header claims two chunks; only one and a half are on disk.
    const cut = fmt.header_block_size + fmt.chunk_size + 1024;
    try tmp.dir.writeFile(test_io, .{ .sub_path = "cut.evtx", .data = bytes[0..cut] });

    const buf = try testing.allocator.alloc(u8, fmt.chunk_size);
    defer testing.allocator.free(buf);

    var r = try Reader.open(test_io, tmp.dir, "cut.evtx", buf);
    defer r.close();

    try testing.expectEqual(@as(u16, 2), r.header.chunk_count);
    try testing.expectEqual(@as(usize, 1), r.chunkCount());
}
