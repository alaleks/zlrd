//! Minimal protobuf wire-format encoder. Just enough to emit OTLP/HTTP log
//! and metric payloads — no descriptors, no reflection, no decoding.
//!
//! All helpers write into a caller-provided buffer and return the number of
//! bytes written. They return `error.NoSpaceLeft` when the buffer is too
//! small — the caller is expected to provide a buffer sized for the worst
//! case, or use a two-pass encoder for nested messages where the length is
//! computed first.
//!
//! Wire format reference:
//!   tag       = (field_number << 3) | wire_type   (varint)
//!   VARINT    = uint64 / int64 / bool / enum (sint via zigzag)
//!   I64       = fixed64 / sfixed64 / double      (8 bytes LE)
//!   LEN       = string / bytes / embedded message / packed (length-delimited)
//!   I32       = fixed32 / sfixed32 / float       (4 bytes LE)

const std = @import("std");

pub const WireType = enum(u3) {
    varint = 0,
    i64 = 1,
    len = 2,
    i32 = 5,
};

pub const Error = error{NoSpaceLeft};

/// Maximum bytes needed to encode any 64-bit varint.
pub const max_varint_len: usize = 10;

/// Encodes a varint into `buf`. Returns bytes written.
pub fn encodeVarint(buf: []u8, value: u64) Error!usize {
    var n = value;
    var i: usize = 0;
    while (n >= 0x80) {
        if (i >= buf.len) return error.NoSpaceLeft;
        buf[i] = @intCast((n & 0x7f) | 0x80);
        n >>= 7;
        i += 1;
    }
    if (i >= buf.len) return error.NoSpaceLeft;
    buf[i] = @intCast(n & 0x7f);
    return i + 1;
}

/// Returns the number of bytes a varint of `value` will occupy. Used by the
/// two-pass encoder for nested messages.
pub fn varintSize(value: u64) usize {
    var n = value;
    var len: usize = 1;
    while (n >= 0x80) : (n >>= 7) len += 1;
    return len;
}

/// Encodes a field tag `(field_number << 3) | wire_type` into `buf`.
pub fn encodeTag(buf: []u8, field_number: u32, wire: WireType) Error!usize {
    const tag = (@as(u64, field_number) << 3) | @intFromEnum(wire);
    return encodeVarint(buf, tag);
}

/// Encodes a single varint field (uint64 / int64 / bool / enum).
pub fn encodeVarintField(buf: []u8, field_number: u32, value: u64) Error!usize {
    var n = try encodeTag(buf, field_number, .varint);
    n += try encodeVarint(buf[n..], value);
    return n;
}

/// Encodes a fixed64 field — 8 bytes little-endian following the tag.
pub fn encodeFixed64Field(buf: []u8, field_number: u32, value: u64) Error!usize {
    const n = try encodeTag(buf, field_number, .i64);
    if (n + 8 > buf.len) return error.NoSpaceLeft;
    std.mem.writeInt(u64, buf[n..][0..8], value, .little);
    return n + 8;
}

/// Encodes a fixed32 field — 4 bytes little-endian following the tag.
pub fn encodeFixed32Field(buf: []u8, field_number: u32, value: u32) Error!usize {
    const n = try encodeTag(buf, field_number, .i32);
    if (n + 4 > buf.len) return error.NoSpaceLeft;
    std.mem.writeInt(u32, buf[n..][0..4], value, .little);
    return n + 4;
}

/// Encodes a length-delimited field carrying raw bytes (string / bytes / pre-
/// encoded message body).
pub fn encodeLenField(buf: []u8, field_number: u32, value: []const u8) Error!usize {
    var n = try encodeTag(buf, field_number, .len);
    n += try encodeVarint(buf[n..], @intCast(value.len));
    if (n + value.len > buf.len) return error.NoSpaceLeft;
    @memcpy(buf[n .. n + value.len], value);
    return n + value.len;
}

/// Encodes a length-delimited field whose body is produced by `encode_fn`
/// into the same buffer. Two-pass: first dry-run to learn the length, then
/// emit tag+length+body. `ctx` is forwarded to `encode_fn` so it can carry
/// the source values to serialize.
pub fn encodeMessageField(
    buf: []u8,
    field_number: u32,
    ctx: anytype,
    encode_fn: fn (buf: []u8, ctx: @TypeOf(ctx)) Error!usize,
) Error!usize {
    var tag_buf: [max_varint_len]u8 = undefined;
    const tag_len = try encodeTag(&tag_buf, field_number, .len);

    // Pass 1: encode the body into a scratch position past the tag/length
    // estimate, then back-fill the actual length.
    const scratch_start: usize = tag_len + max_varint_len;
    if (scratch_start > buf.len) return error.NoSpaceLeft;
    const body_len = try encode_fn(buf[scratch_start..], ctx);

    const length_size = varintSize(body_len);
    const final_start = tag_len + length_size;

    // Shift the body forward to its final position if our length estimate
    // was larger than the actual length varint.
    if (final_start != scratch_start) {
        std.mem.copyForwards(u8, buf[final_start .. final_start + body_len], buf[scratch_start .. scratch_start + body_len]);
    }

    @memcpy(buf[0..tag_len], tag_buf[0..tag_len]);
    _ = try encodeVarint(buf[tag_len..], @intCast(body_len));

    return final_start + body_len;
}

/// Encodes `value` into a fixed 5-byte varint slot, padding with continuation
/// bytes where needed. Used by `Encoder.endMessage` to back-fill an
/// unknown-at-the-time length without shifting bytes. Protobuf decoders accept
/// non-minimally-encoded varints.
///
/// Caps at 2^35 - 1; a single OTLP request never approaches this.
pub fn encodeVarintFixed5(buf: *[5]u8, value: u64) void {
    std.debug.assert(value <= (@as(u64, 1) << 35) - 1);
    buf[0] = @intCast((value & 0x7f) | 0x80);
    buf[1] = @intCast(((value >> 7) & 0x7f) | 0x80);
    buf[2] = @intCast(((value >> 14) & 0x7f) | 0x80);
    buf[3] = @intCast(((value >> 21) & 0x7f) | 0x80);
    buf[4] = @intCast((value >> 28) & 0x7f);
}

/// Growable protobuf encoder backed by an ArrayList. Designed for OTLP-style
/// payloads where nested message lengths aren't known until the body is
/// emitted. `beginMessage` reserves a 5-byte slot for the length; `endMessage`
/// back-fills it as a minimally-encoded varint and shifts the body backward
/// to drop any unused reserve bytes.
///
/// Caller owns the underlying buffer via the supplied allocator; call
/// `deinit` (or `toOwnedSlice`) to release.
pub const Encoder = struct {
    /// Initial buffer reserved up-front so OTLP-sized payloads avoid the
    /// repeated grow-by-doubling cost of the first few KiB of writes.
    pub const default_initial_capacity: usize = 4096;

    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    pub const Pending = struct {
        reserve_pos: usize,
        body_start: usize,
    };

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return initCapacity(allocator, default_initial_capacity) catch
            .{ .allocator = allocator };
    }

    /// Same as `init` but caller picks the initial capacity. Allocation
    /// failure here is non-fatal: we fall back to lazy growth.
    pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !Encoder {
        var buf: std.ArrayList(u8) = .empty;
        try buf.ensureTotalCapacity(allocator, capacity);
        return .{ .buf = buf, .allocator = allocator };
    }

    pub fn deinit(self: *Encoder) void {
        self.buf.deinit(self.allocator);
    }

    pub fn bytes(self: *const Encoder) []const u8 {
        return self.buf.items;
    }

    pub fn toOwnedSlice(self: *Encoder) ![]u8 {
        return self.buf.toOwnedSlice(self.allocator);
    }

    pub fn reset(self: *Encoder) void {
        self.buf.clearRetainingCapacity();
    }

    fn writeVarintImpl(self: *Encoder, value: u64) !void {
        var n = value;
        while (n >= 0x80) : (n >>= 7) {
            try self.buf.append(self.allocator, @as(u8, @intCast((n & 0x7f) | 0x80)));
        }
        try self.buf.append(self.allocator, @as(u8, @intCast(n & 0x7f)));
    }

    pub fn writeTag(self: *Encoder, field_number: u32, wire: WireType) !void {
        const tag = (@as(u64, field_number) << 3) | @intFromEnum(wire);
        try self.writeVarintImpl(tag);
    }

    pub fn writeVarintField(self: *Encoder, field_number: u32, value: u64) !void {
        try self.writeTag(field_number, .varint);
        try self.writeVarintImpl(value);
    }

    pub fn writeFixed64Field(self: *Encoder, field_number: u32, value: u64) !void {
        try self.writeTag(field_number, .i64);
        var le: [8]u8 = undefined;
        std.mem.writeInt(u64, &le, value, .little);
        try self.buf.appendSlice(self.allocator, &le);
    }

    pub fn writeFixed32Field(self: *Encoder, field_number: u32, value: u32) !void {
        try self.writeTag(field_number, .i32);
        var le: [4]u8 = undefined;
        std.mem.writeInt(u32, &le, value, .little);
        try self.buf.appendSlice(self.allocator, &le);
    }

    pub fn writeStringField(self: *Encoder, field_number: u32, value: []const u8) !void {
        try self.writeTag(field_number, .len);
        try self.writeVarintImpl(value.len);
        try self.buf.appendSlice(self.allocator, value);
    }

    /// Begins a length-delimited (LEN) field at `field_number`. The returned
    /// `Pending` must be passed to `endMessage` once the body is emitted.
    pub fn beginMessage(self: *Encoder, field_number: u32) !Pending {
        try self.writeTag(field_number, .len);
        const reserve_pos = self.buf.items.len;
        try self.buf.appendNTimes(self.allocator, 0, 5);
        return .{ .reserve_pos = reserve_pos, .body_start = self.buf.items.len };
    }

    /// Back-fills the reserved length slot with the minimally-encoded varint
    /// for `body_len` and shifts the body backward to drop the unused
    /// reserve bytes. The previous fixed-width approach wasted 4 bytes per
    /// nested message; for OTLP payloads with deep nesting (~6 levels) that
    /// added up to tens of KiB of pure padding per batch — and gzip-on-the-
    /// wire (Content-Encoding: gzip) compresses the resulting compact bytes
    /// noticeably better.
    pub fn endMessage(self: *Encoder, pending: Pending) void {
        const body_len = self.buf.items.len - pending.body_start;
        const len_size = varintSize(body_len);
        const slack = 5 - len_size;

        if (slack != 0) {
            const dst_start = pending.reserve_pos + len_size;
            const src_start = pending.body_start;
            // src_start > dst_start (slack > 0) — safe to copyForwards.
            std.mem.copyForwards(
                u8,
                self.buf.items[dst_start .. dst_start + body_len],
                self.buf.items[src_start .. src_start + body_len],
            );
            self.buf.items.len -= slack;
        }
        // Write the minimal varint into the now-correctly-sized slot.
        _ = encodeVarint(
            self.buf.items[pending.reserve_pos..][0..len_size],
            body_len,
        ) catch unreachable;
    }
};

const testing = std.testing;

test "encodeVarint: single-byte values" {
    var buf: [10]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), try encodeVarint(&buf, 0));
    try testing.expectEqual(@as(u8, 0), buf[0]);
    try testing.expectEqual(@as(usize, 1), try encodeVarint(&buf, 127));
    try testing.expectEqual(@as(u8, 127), buf[0]);
}

test "encodeVarint: multi-byte values match protobuf spec" {
    var buf: [10]u8 = undefined;
    // 150 → 0x96 0x01 per protobuf docs
    try testing.expectEqual(@as(usize, 2), try encodeVarint(&buf, 150));
    try testing.expectEqual(@as(u8, 0x96), buf[0]);
    try testing.expectEqual(@as(u8, 0x01), buf[1]);

    // 300 → 0xAC 0x02
    try testing.expectEqual(@as(usize, 2), try encodeVarint(&buf, 300));
    try testing.expectEqual(@as(u8, 0xAC), buf[0]);
    try testing.expectEqual(@as(u8, 0x02), buf[1]);
}

test "varintSize: matches encoded length" {
    var buf: [10]u8 = undefined;
    inline for ([_]u64{ 0, 1, 127, 128, 16383, 16384, 0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF }) |v| {
        const expected = try encodeVarint(&buf, v);
        try testing.expectEqual(expected, varintSize(v));
    }
}

test "encodeTag: field 1 varint = 0x08" {
    var buf: [2]u8 = undefined;
    const n = try encodeTag(&buf, 1, .varint);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u8, 0x08), buf[0]);
}

test "encodeTag: field 2 LEN = 0x12" {
    var buf: [2]u8 = undefined;
    const n = try encodeTag(&buf, 2, .len);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u8, 0x12), buf[0]);
}

test "encodeVarintField: full encoding of int32 = 150" {
    var buf: [4]u8 = undefined;
    // field=1, type=VARINT, value=150 → 08 96 01
    const n = try encodeVarintField(&buf, 1, 150);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x96, 0x01 }, buf[0..n]);
}

test "encodeLenField: string 'hi' as field 2" {
    var buf: [8]u8 = undefined;
    // field=2, type=LEN, length=2, "hi"
    const n = try encodeLenField(&buf, 2, "hi");
    try testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x02, 'h', 'i' }, buf[0..n]);
}

test "encodeFixed64Field: little-endian 1" {
    var buf: [16]u8 = undefined;
    const n = try encodeFixed64Field(&buf, 1, 1);
    // field=1, type=I64 → tag=0x09; then 8 bytes LE
    try testing.expectEqual(@as(usize, 9), n);
    try testing.expectEqual(@as(u8, 0x09), buf[0]);
    try testing.expectEqual(@as(u8, 1), buf[1]);
    try testing.expectEqual(@as(u8, 0), buf[8]);
}

test "encodeFixed32Field: little-endian byte order" {
    var buf: [8]u8 = undefined;
    const n = try encodeFixed32Field(&buf, 1, 0x01020304);
    // field=1, type=I32 → tag=0x0D
    try testing.expectEqualSlices(u8, &[_]u8{ 0x0D, 0x04, 0x03, 0x02, 0x01 }, buf[0..n]);
}

test "encodeMessageField: nested message with string field" {
    // Outer field=1 LEN, body = string field=2 LEN "x"
    var inner_buf: [16]u8 = undefined;
    const inner_n = try encodeLenField(&inner_buf, 2, "x");

    var outer_buf: [32]u8 = undefined;
    const Ctx = struct { body: []const u8 };
    const ctx: Ctx = .{ .body = inner_buf[0..inner_n] };
    const outer_n = try encodeMessageField(&outer_buf, 1, ctx, struct {
        fn enc(b: []u8, c: Ctx) Error!usize {
            if (c.body.len > b.len) return error.NoSpaceLeft;
            @memcpy(b[0..c.body.len], c.body);
            return c.body.len;
        }
    }.enc);

    // Expected: field=1 LEN, tag=0x0A; length=inner_n; then inner body.
    try testing.expectEqual(@as(u8, 0x0A), outer_buf[0]);
    try testing.expectEqual(@as(u8, @intCast(inner_n)), outer_buf[1]);
    try testing.expectEqualSlices(u8, inner_buf[0..inner_n], outer_buf[2..outer_n]);
}

test "encodeVarint: NoSpaceLeft when buf too small" {
    var buf: [1]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, encodeVarint(&buf, 128));
}

test "encodeVarintFixed5: pads short values correctly" {
    var buf: [5]u8 = undefined;
    encodeVarintFixed5(&buf, 1);
    // Continuation bits set on bytes 0-3; final byte is the value.
    try testing.expectEqual(@as(u8, 0x81), buf[0]);
    try testing.expectEqual(@as(u8, 0x80), buf[1]);
    try testing.expectEqual(@as(u8, 0x80), buf[2]);
    try testing.expectEqual(@as(u8, 0x80), buf[3]);
    try testing.expectEqual(@as(u8, 0x00), buf[4]);
}

test "encodeVarintFixed5: round-trips through encodeVarint reader" {
    // The fixed5 form decodes to the same value as a minimal varint.
    inline for ([_]u64{ 0, 1, 127, 128, 150, 300, 65535, 1 << 20, 1 << 30 }) |v| {
        var enc: [5]u8 = undefined;
        encodeVarintFixed5(&enc, v);
        // Manual minimal decode of the 5-byte form.
        var out: u64 = 0;
        inline for (0..5) |i| {
            out |= @as(u64, enc[i] & 0x7f) << (7 * i);
        }
        try testing.expectEqual(v, out);
    }
}

test "Encoder: simple string field round-trips" {
    var enc = Encoder.init(testing.allocator);
    defer enc.deinit();
    try enc.writeStringField(2, "hi");
    try testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x02, 'h', 'i' }, enc.bytes());
}

test "Encoder: nested message via beginMessage / endMessage" {
    var enc = Encoder.init(testing.allocator);
    defer enc.deinit();

    // Outer field 1 LEN containing a single inner field 2 LEN "x".
    const pending = try enc.beginMessage(1);
    try enc.writeStringField(2, "x");
    enc.endMessage(pending);

    // tag(1,LEN)=0x0A, then minimal 1-byte length=3, then inner 0x12 0x01 'x'.
    // (Previous version always padded to 5 bytes; the adaptive endMessage
    // shifts the body backward and emits a minimal varint.)
    try testing.expectEqualSlices(u8, &[_]u8{ 0x0A, 0x03, 0x12, 0x01, 'x' }, enc.bytes());
}

test "Encoder: nested message with body crossing the 128-byte varint boundary" {
    var enc = Encoder.init(testing.allocator);
    defer enc.deinit();

    // Inner string field 2 with 200 bytes — length needs 2 varint bytes.
    var big: [200]u8 = undefined;
    @memset(&big, 'a');

    const pending = try enc.beginMessage(1);
    try enc.writeStringField(2, &big);
    enc.endMessage(pending);

    const b = enc.bytes();
    // tag = 0x0A, length varint = 0xCC 0x01 (200 + 3 bytes of inner header
    // = 203 → 0xCB 0x01... let's just sanity-check shape rather than exact).
    try testing.expectEqual(@as(u8, 0x0A), b[0]);
    // Two-byte length varint: high bit set on first, clear on second.
    try testing.expect((b[1] & 0x80) != 0);
    try testing.expect((b[2] & 0x80) == 0);
}

test "Encoder: writeVarintField / writeFixed64Field" {
    var enc = Encoder.init(testing.allocator);
    defer enc.deinit();

    try enc.writeVarintField(1, 150);
    try enc.writeFixed64Field(2, 0);

    const b = enc.bytes();
    // 08 96 01 — varint field 1 = 150
    try testing.expectEqual(@as(u8, 0x08), b[0]);
    try testing.expectEqual(@as(u8, 0x96), b[1]);
    try testing.expectEqual(@as(u8, 0x01), b[2]);
    // 11 — tag for field 2 fixed64 (i64=1) = (2<<3)|1 = 0x11
    try testing.expectEqual(@as(u8, 0x11), b[3]);
    // 8 zero bytes
    for (b[4..12]) |byte| try testing.expectEqual(@as(u8, 0), byte);
}
