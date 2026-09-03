//! Detection and pretty-printing of protobuf wire-format payloads carried
//! *inside* a log message.
//!
//! Services that log a request body get this shape a lot:
//!
//!   {"level":"info","message":"Handle: \\n\\u001c\\n\\u0013cleanup_time\\u0012\\u000510:45"}
//!
//! The message is human text followed by raw protobuf bytes, escaped by the
//! JSON encoder. Printed verbatim it is unreadable — you cannot tell what was
//! sent. Decoded it is three lines and obvious:
//!
//!   1 {
//!     1: "cleanup_time"
//!     2: "10:45"
//!   }
//!
//! There is no schema here and there cannot be one: the log carries bytes,
//! not a descriptor. So this renders the same thing `protoc --decode_raw`
//! does — field numbers instead of names, value shapes inferred from the wire
//! type. That is enough to answer "what was sent", which is the question
//! being asked when you squint at a line like the one above.
//!
//! ## Why this doesn't slow the reader down
//!
//! Same ordering as `jsonx`, for the same reason: a line without a payload
//! must pay almost nothing.
//!
//!   - Nothing here runs during filtering, so cost scales with printed lines.
//!   - The gate is a substring scan for `\u00` on the still-escaped value.
//!     A JSON string may only carry control bytes as `\u00XX`, so a value
//!     without that sequence cannot hold binary and stops here.
//!   - `find` is a bounded number of linear scans that abort at the first
//!     byte that cannot open a field.
//!   - Decoding writes into caller-owned scratch and the output buffer. No
//!     parse tree, no allocator, no unbounded recursion.
//!
//! ## What survives the round trip
//!
//! Bytes ≥ 0x80 do not, in general. Go's `encoding/json` replaces invalid
//! UTF-8 with U+FFFD before the value ever reaches the log, so those payloads
//! arrive already destroyed and no decoder can recover them. What *is*
//! recoverable is the common case where every byte escaped as `\u00XX` —
//! which `unescapeBytes` maps back to one byte each, unlike `jsonx.unescape`
//! which would UTF-8 encode 0x96 into two bytes and break the parse. When a
//! payload doesn't survive, `find` simply returns null and the line keeps the
//! verbatim rendering it had before.

const std = @import("std");
const theme = @import("theme.zig");

/// Bounds that keep a malformed or hostile payload from turning into
/// unbounded work. Generous for real messages, tight enough that random
/// bytes can't stall the reader.
pub const Limits = struct {
    /// Nesting cap. Also bounds `writeBlock`'s recursion depth.
    max_depth: u8 = 12,
    /// Field numbers above this are treated as noise rather than data.
    /// Real schemas stay far below it; the wire format allows up to 2^29-1,
    /// and accepting that range makes random bytes parse far too often.
    max_field_number: u64 = 2048,
    /// Fields per message. Bounds the work a single payload can cause.
    max_fields: usize = 1024,
    /// Below this a payload isn't worth a block — and is too short to
    /// distinguish from coincidence.
    min_bytes: usize = 4,
    /// Bytes of a non-textual, non-message `LEN` value shown before eliding.
    max_hex_bytes: usize = 32,
};

/// Longest varint the wire format allows.
const max_varint_len: usize = 10;

/// How far back from the first binary byte `find` will look for the opening
/// tag. A tag plus its length is at most a few bytes, so this covers the case
/// where both happen to be printable (field 4 `LEN` is `"`, for instance) and
/// the first binary byte therefore sits inside the payload rather than at its
/// start.
const back_window: usize = 10;

/// Number of spaces per nesting level.
const indent_width: usize = 2;

// ─── Escaped-value handling ───────────────────────────────────────────────

/// True if `value` (the raw bytes of a JSON string value, still escaped) can
/// possibly carry binary. Cheap pre-check before paying for `unescapeBytes`.
///
/// JSON forbids literal control bytes inside a string, so a payload always
/// arrives as `\u00XX`. No such sequence, no payload.
pub fn looksLikeBinary(value: []const u8) bool {
    if (value.len < 6) return false;
    return std.mem.indexOf(u8, value, "\\u00") != null;
}

/// Un-escapes a JSON string value into `dst`, mapping every `\uXXXX` below
/// 0x100 to a single byte.
///
/// This is the one thing `jsonx.unescape` deliberately does differently: it
/// produces text, so it UTF-8 encodes the codepoint and 0x96 becomes two
/// bytes. Here the bytes *are* the message, and re-encoding them would shift
/// every following field and turn a valid payload into garbage.
///
/// Returns null when `src` is malformed or wouldn't fit — the caller then
/// leaves the line as it was.
pub fn unescapeBytes(dst: []u8, src: []const u8) ?[]const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c != '\\') {
            if (out >= dst.len) return null;
            dst[out] = c;
            out += 1;
            i += 1;
            continue;
        }
        i += 1;
        if (i >= src.len) return null;
        const e = src[i];
        i += 1;
        const simple: ?u8 = switch (e) {
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'b' => 0x08,
            'f' => 0x0C,
            else => null,
        };
        if (simple) |s| {
            if (out >= dst.len) return null;
            dst[out] = s;
            out += 1;
            continue;
        }
        if (e != 'u') return null;
        if (i + 4 > src.len) return null;
        const cp = std.fmt.parseInt(u16, src[i .. i + 4], 16) catch return null;
        i += 4;
        if (cp < 0x100) {
            if (out >= dst.len) return null;
            dst[out] = @intCast(cp);
            out += 1;
            continue;
        }
        // Above 0x100 it is genuinely text, not a byte. Encode it as UTF-8;
        // it will fail the wire-format scan if it sits inside a payload, and
        // read correctly if it sits in the prose prefix.
        const n = std.unicode.utf8CodepointSequenceLength(cp) catch return null;
        if (out + n > dst.len) return null;
        _ = std.unicode.utf8Encode(cp, dst[out..]) catch return null;
        out += n;
    }
    return dst[0..out];
}

// ─── Detection ────────────────────────────────────────────────────────────

const Varint = struct { value: u64, len: usize };

fn readVarint(src: []const u8, at: usize) ?Varint {
    var v: u64 = 0;
    var shift: u7 = 0;
    var n: usize = 0;
    while (n < max_varint_len and at + n < src.len) : (n += 1) {
        const b = src[at + n];
        v |= @as(u64, b & 0x7f) << @intCast(shift);
        if (b & 0x80 == 0) return .{ .value = v, .len = n + 1 };
        shift += 7;
        if (shift >= 64) return null;
    }
    return null;
}

/// A byte that cannot occur in human-readable text. Tab, newline and carriage
/// return are excluded on purpose: prose contains them, and a payload that
/// held nothing else would be indistinguishable from a multi-line message.
inline fn isBinaryByte(c: u8) bool {
    return switch (c) {
        0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => true,
        else => false,
    };
}

fn firstBinaryByte(src: []const u8) ?usize {
    for (src, 0..) |c, i| {
        if (isBinaryByte(c)) return i;
    }
    return null;
}

/// True if every byte of `src` is a sequence of well-formed fields that ends
/// exactly at `src.len`.
///
/// Ending exactly is what makes this usable as a detector. Random bytes
/// almost always run past the end or hit a length that overruns the buffer;
/// requiring the parse to land on the final byte rejects them.
pub fn validate(src: []const u8, limits: Limits) bool {
    if (src.len == 0) return false;
    var i: usize = 0;
    var fields: usize = 0;
    while (i < src.len) {
        const tag = readVarint(src, i) orelse return false;
        i += tag.len;
        const field_no = tag.value >> 3;
        if (field_no == 0 or field_no > limits.max_field_number) return false;

        switch (tag.value & 7) {
            0 => {
                const v = readVarint(src, i) orelse return false;
                i += v.len;
            },
            1 => {
                if (src.len - i < 8) return false;
                i += 8;
            },
            5 => {
                if (src.len - i < 4) return false;
                i += 4;
            },
            2 => {
                const len = readVarint(src, i) orelse return false;
                i += len.len;
                if (len.value > src.len - i) return false;
                i += @intCast(len.value);
            },
            // Wire types 3 and 4 are the deprecated group markers. No current
            // encoder emits them, so in practice they only ever show up in
            // random bytes — rejecting them costs nothing and buys accuracy.
            else => return false,
        }

        fields += 1;
        if (fields > limits.max_fields) return false;
    }
    return fields > 0;
}

/// True if `src` opens with a tag a real message plausibly starts with.
///
/// Only wire types 0 and 2 qualify. A logged payload's first field is a
/// varint or something length-delimited essentially always, whereas a bare
/// `fixed32`/`fixed64` opener is exactly what a stray letter decodes to —
/// `a` is field 12 fixed64, `e` is field 12 fixed32. Without this, a damaged
/// payload anchors on its own prose and prints a confident, invented
/// structure, which is worse than printing nothing.
fn opensPlausibly(src: []const u8, limits: Limits) bool {
    const tag = readVarint(src, 0) orelse return false;
    const field_no = tag.value >> 3;
    if (field_no == 0 or field_no > limits.max_field_number) return false;
    return switch (tag.value & 7) {
        0, 2 => true,
        else => false,
    };
}

/// Bytes a human sentence ends with before an appended payload. Anything
/// else means the offset lands mid-word, which is prose rather than a tag.
inline fn isSeparator(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', ':', '=', ',', '|', '>' => true,
        else => false,
    };
}

/// Length of the escaped prefix of `src` that decodes to exactly
/// `decoded_len` bytes, or null if no boundary lines up.
///
/// The printer works in escaped coordinates (it writes bytes of the original
/// line) while `find` reports an offset into the decoded payload, so one of
/// the two has to be translated. Re-walking the escape rules is cheaper than
/// having `unescapeBytes` record a position per output byte, and it needs
/// only the lengths, never the values.
pub fn escapedPrefixLen(src: []const u8, decoded_len: usize) ?usize {
    var out: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        if (out == decoded_len) return i;
        if (src[i] != '\\') {
            i += 1;
            out += 1;
            continue;
        }
        if (i + 1 >= src.len) return null;
        if (src[i + 1] != 'u') {
            i += 2;
            out += 1;
            continue;
        }
        if (i + 6 > src.len) return null;
        const cp = std.fmt.parseInt(u16, src[i + 2 .. i + 6], 16) catch return null;
        i += 6;
        out += if (cp < 0x100) 1 else (std.unicode.utf8CodepointSequenceLength(cp) catch return null);
    }
    return if (out == decoded_len) i else null;
}

/// Offset of the protobuf payload inside `src`, or null if there isn't one.
///
/// Handles the common `"Handle: " ++ payload` shape by looking for the tag
/// near the first binary byte, not only at offset 0.
pub fn find(src: []const u8, limits: Limits) ?usize {
    if (src.len < limits.min_bytes) return null;

    // A payload made entirely of printable bytes is not distinguishable from
    // prose that happens to parse, and treating it as protobuf would mangle
    // ordinary messages. Requiring at least one binary byte is what keeps
    // this from firing on normal logs.
    const ctl = firstBinaryByte(src) orelse return null;
    const lo = ctl -| back_window;

    // Preferred anchor: the earliest offset that parses *and* sits right after
    // a separator. A payload is appended to a human sentence — "Handle: " —
    // so its first byte follows a space or a colon, never the middle of a
    // word. That single constraint rules out the prose offsets, which lets us
    // scan forwards and keep the OUTERMOST message: anchoring later would
    // silently drop a level of nesting and print the inner fields as if they
    // were top-level.
    var i = lo;
    while (i <= ctl) : (i += 1) {
        if (i != 0 and !isSeparator(src[i - 1])) continue;
        const rest = src[i..];
        if (rest.len >= limits.min_bytes and
            opensPlausibly(rest, limits) and validate(rest, limits)) return i;
    }

    // Fallback for payloads that follow no separator: take the latest offset
    // that parses. Direction matters here — prose parses as fields far more
    // often than intuition suggests ("andle: …" is a valid field 12 fixed64),
    // so scanning forwards without the separator rule would anchor inside the
    // text. The latest match keeps the most text as text.
    var start = ctl;
    while (true) : (start -= 1) {
        const rest = src[start..];
        if (rest.len >= limits.min_bytes and
            opensPlausibly(rest, limits) and validate(rest, limits)) return start;
        if (start == lo) break;
    }

    // Only now consider a payload that fills the whole value: reaching here
    // means no tag sits near the first binary byte, which happens when the
    // payload opens with printable bytes of its own.
    if (lo != 0 and opensPlausibly(src, limits) and validate(src, limits)) return 0;
    return null;
}

// ─── Pretty printing ──────────────────────────────────────────────────────

/// True if `src` reads as text rather than as bytes. Text wins over a nested
/// message when both parse, because a string field holding `"cleanup_time"`
/// is what the reader wants to see — not the two-field message those same
/// bytes coincidentally decode to.
fn isTextual(src: []const u8) bool {
    if (src.len == 0) return false;
    for (src) |c| {
        if (isBinaryByte(c)) return false;
    }
    return std.unicode.utf8ValidateSlice(src);
}

/// Writes `src` — which must already have passed `validate` — as an indented,
/// coloured block, using the same gutter as an expanded JSON block so the two
/// read as the same kind of attachment to the line above.
///
/// `out` is any value with `pub fn write(self: *@This(), []const u8) void`.
pub fn writeBlock(out: anytype, th: *const theme.Theme, src: []const u8, limits: Limits) void {
    const p = th.palette;

    out.write(p.dim);
    out.write("  ");
    out.write(th.glyphs.top);
    out.write(th.glyphs.rule);
    out.write(p.reset);

    var w: Writer(@TypeOf(out.*)) = .{ .out = out, .th = th, .limits = limits };
    w.message(src, 0);

    out.write("\n");
    out.write(p.dim);
    out.write("  ");
    out.write(th.glyphs.bottom);
    out.write(th.glyphs.rule);
    out.write(p.reset);
    out.write("\n");
}

/// Walks a validated payload and emits it. Generic over the sink so tests can
/// render into an `ArrayList` without standing up the real output buffer.
fn Writer(comptime Out: type) type {
    return struct {
        out: *Out,
        th: *const theme.Theme,
        limits: Limits,

        const Self = @This();

        fn newline(self: *Self, depth: usize) void {
            const p = self.th.palette;
            self.out.write("\n");
            self.out.write(p.dim);
            self.out.write("  ");
            self.out.write(self.th.glyphs.bar);
            self.out.write(p.reset);
            self.out.write(" ");
            var n = depth * indent_width;
            while (n >= 8) : (n -= 8) self.out.write("        ");
            while (n > 0) : (n -= 1) self.out.write(" ");
        }

        fn punct(self: *Self, s: []const u8) void {
            self.out.write(self.th.palette.json_punct);
            self.out.write(s);
            self.out.write(self.th.palette.reset);
        }

        fn styled(self: *Self, color: []const u8, s: []const u8) void {
            self.out.write(color);
            self.out.write(s);
            self.out.write(self.th.palette.reset);
        }

        fn number(self: *Self, comptime fmt: []const u8, args: anytype) void {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
            self.styled(self.th.palette.json_number, s);
        }

        /// Emits every field of `src`, one per line.
        fn message(self: *Self, src: []const u8, depth: usize) void {
            var i: usize = 0;
            while (i < src.len) {
                const tag = readVarint(src, i) orelse return;
                i += tag.len;
                const field_no = tag.value >> 3;
                const wire = tag.value & 7;

                self.newline(depth);
                self.number("{d}", .{field_no});

                switch (wire) {
                    0 => {
                        const v = readVarint(src, i) orelse return;
                        i += v.len;
                        self.punct(": ");
                        self.number("{d}", .{v.value});
                    },
                    1 => {
                        if (src.len - i < 8) return;
                        const v = std.mem.readInt(u64, src[i..][0..8], .little);
                        i += 8;
                        self.punct(": ");
                        self.number("{d}", .{v});
                    },
                    5 => {
                        if (src.len - i < 4) return;
                        const v = std.mem.readInt(u32, src[i..][0..4], .little);
                        i += 4;
                        self.punct(": ");
                        self.number("{d}", .{v});
                    },
                    2 => {
                        const len = readVarint(src, i) orelse return;
                        i += len.len;
                        if (len.value > src.len - i) return;
                        const body = src[i..][0..@intCast(len.value)];
                        i += body.len;
                        self.lenValue(body, depth);
                    },
                    else => return,
                }
            }
        }

        /// Renders a length-delimited value as a string, a nested message, or
        /// a hex dump — in that order of preference. See `isTextual` for why
        /// text outranks a message that also happens to parse.
        fn lenValue(self: *Self, body: []const u8, depth: usize) void {
            if (isTextual(body)) {
                self.punct(": ");
                self.out.write(self.th.palette.json_string_open);
                self.out.write(body);
                self.out.write(self.th.palette.quote_close);
                return;
            }

            if (depth + 1 < self.limits.max_depth and validate(body, self.limits)) {
                self.punct(" {");
                self.message(body, depth + 1);
                self.newline(depth);
                self.punct("}");
                return;
            }

            self.punct(": ");
            self.hex(body);
        }

        /// Last resort: bytes that are neither text nor a message. Shown as
        /// hex so the record still says *something* about what was sent,
        /// capped so one blob can't flood the terminal.
        fn hex(self: *Self, body: []const u8) void {
            const shown = @min(body.len, self.limits.max_hex_bytes);
            self.out.write(self.th.palette.json_number);
            var buf: [2]u8 = undefined;
            for (body[0..shown], 0..) |b, n| {
                if (n > 0) self.out.write(" ");
                const s = std.fmt.bufPrint(&buf, "{x:0>2}", .{b}) catch continue;
                self.out.write(s);
            }
            self.out.write(self.th.palette.reset);
            if (shown < body.len) {
                var tail: [40]u8 = undefined;
                const s = std.fmt.bufPrint(&tail, " … {d} bytes", .{body.len}) catch return;
                self.styled(self.th.palette.dim, s);
            }
        }
    };
}

// ============================================================================
// Unit Tests
// ============================================================================

const testing = std.testing;

/// Minimal sink mirroring `Out.write`, so the printer can be tested without
/// the reader's buffered output.
const TestSink = struct {
    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    fn deinit(self: *TestSink) void {
        self.buf.deinit(self.allocator);
    }

    pub fn write(self: *TestSink, s: []const u8) void {
        self.buf.appendSlice(self.allocator, s) catch {};
    }
};

/// The payload from the report that started this: a `Handle: ` prefix
/// followed by a message holding one nested message with two string fields.
const sample = "Handle: \x0a\x1b\x0a\x12cleanup_time_field\x12\x0510:45";

test "find locates a payload behind a text prefix" {
    const start = find(sample, .{}) orelse return error.NotFound;
    try testing.expectEqual(@as(usize, 8), start);
    try testing.expect(validate(sample[start..], .{}));
}

/// The same payload as `sample`, but with the length prefixes left at the
/// values they had before a copy-paste dropped bytes out of the middle. A
/// real log can arrive damaged the same way.
const damaged = "Handle: \x0a\x1c\x0a\x13cleanup_time\x12\x0510:45";

test "find declines a damaged payload instead of inventing structure" {
    // Some offset inside the prose does parse to the end here — "andle: …"
    // is a valid field 12 fixed64 followed by two fields that happen to line
    // up. Anchoring there printed a confident, wrong decode, so the opening
    // wire type has to be plausible as well.
    try testing.expectEqual(@as(?usize, null), find(damaged, .{}));
}

test "opensPlausibly rejects a fixed-width opening field" {
    // 'a' — field 12, wire type 1 (fixed64): the exact false anchor above.
    try testing.expect(!opensPlausibly("andle: \x0a\x1c", .{}));
    // field 1, LEN and field 1, varint both open real messages.
    try testing.expect(opensPlausibly("\x0a\x02ab", .{}));
    try testing.expect(opensPlausibly("\x08\x01", .{}));
}

/// A payload whose inner message is itself a valid anchor. Without the
/// separator rule the scan settles on the inner one and the outer level is
/// silently lost.
const wrapped = "HandleSystemConfigUpdate: \x0a$\x0a\x1cpoller_cleanup_records_count\x12\x04true";

test "find keeps the outermost message when the inner one also parses" {
    // 26 is the byte after "…Update: "; 28 is the inner message, which parses
    // just as cleanly and would drop a level of nesting.
    try testing.expectEqual(@as(?usize, 26), find(wrapped, .{}));
}

test "writeBlock keeps the wrapper of a nested payload" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();

    const start = find(wrapped, .{}) orelse return error.NotFound;
    writeBlock(&sink, &theme.Theme.plain, wrapped[start..], .{});

    const expected =
        "  +-\n" ++
        "  | 1 {\n" ++
        "  |   1: \"poller_cleanup_records_count\"\n" ++
        "  |   2: \"true\"\n" ++
        "  | }\n" ++
        "  +-\n";
    try testing.expectEqualStrings(expected, sink.buf.items);
}

test "escapedPrefixLen maps a decoded offset back onto the escaped bytes" {
    // "Handle: " is eight decoded bytes and eight escaped ones.
    try testing.expectEqual(@as(?usize, 8), escapedPrefixLen("Handle: \\u000a\\u0015", 8));
    // Escapes ahead of the boundary make the two coordinates diverge:
    // `\n` is two escaped bytes for one decoded byte.
    try testing.expectEqual(@as(?usize, 3), escapedPrefixLen("a\\nb", 2));
    // A boundary that lands mid-escape has no answer.
    try testing.expectEqual(@as(?usize, null), escapedPrefixLen("\\u0041", 2));
}

test "validate rejects plain prose" {
    try testing.expect(!validate("connection refused to upstream", .{}));
    try testing.expect(!validate("", .{}));
}

test "find ignores text that carries no binary byte" {
    // Parses as fields by coincidence or not, it has no binary byte, so it
    // must never be treated as a payload.
    try testing.expectEqual(@as(?usize, null), find("Handle: cleanup_time", .{}));
    try testing.expectEqual(@as(?usize, null), find("a\nb\tc\r\n", .{}));
}

test "validate rejects a truncated length-delimited field" {
    // field 1, LEN, claims 9 bytes but only 3 follow.
    try testing.expect(!validate("\x0a\x09abc", .{}));
}

test "validate rejects group wire types" {
    // field 1, wire type 3 (start group).
    try testing.expect(!validate("\x0b\x01\x02\x03", .{}));
}

test "validate rejects an out-of-range field number" {
    // field 4096, LEN, empty — above the default max_field_number.
    try testing.expect(!validate("\x82\x80\x02\x00", .{}));
    try testing.expect(validate("\x82\x80\x02\x00", .{ .max_field_number = 8192 }));
}

test "unescapeBytes maps \\u00XX to single bytes" {
    var buf: [64]u8 = undefined;
    const got = unescapeBytes(&buf, "\\n\\u001c\\u0096x") orelse return error.Failed;
    try testing.expectEqualSlices(u8, "\n\x1c\x96x", got);
}

test "unescapeBytes reports overflow instead of truncating" {
    var buf: [2]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), unescapeBytes(&buf, "abcdef"));
}

test "looksLikeBinary gates on the escape sequence" {
    try testing.expect(looksLikeBinary("Handle: \\n\\u001c\\n\\u0013x"));
    try testing.expect(!looksLikeBinary("plain message with \\n and \\t"));
    try testing.expect(!looksLikeBinary("short"));
}

test "writeBlock renders nested fields as decode_raw does" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();

    const start = find(sample, .{}) orelse return error.NotFound;
    writeBlock(&sink, &theme.Theme.plain, sample[start..], .{});

    const expected =
        "  +-\n" ++
        "  | 1 {\n" ++
        "  |   1: \"cleanup_time_field\"\n" ++
        "  |   2: \"10:45\"\n" ++
        "  | }\n" ++
        "  +-\n";
    try testing.expectEqualStrings(expected, sink.buf.items);
}

test "writeBlock renders scalar wire types" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();

    // field 1 varint 300, field 2 fixed32 = 1, field 3 fixed64 = 2.
    const src = "\x08\xac\x02" ++ "\x15\x01\x00\x00\x00" ++ "\x19\x02\x00\x00\x00\x00\x00\x00\x00";
    try testing.expect(validate(src, .{}));
    writeBlock(&sink, &theme.Theme.plain, src, .{});

    const expected =
        "  +-\n" ++
        "  | 1: 300\n" ++
        "  | 2: 1\n" ++
        "  | 3: 2\n" ++
        "  +-\n";
    try testing.expectEqualStrings(expected, sink.buf.items);
}

test "writeBlock falls back to hex for undecodable bytes" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();

    // field 1, LEN 3, bytes that are neither text nor a valid message.
    const src = "\x0a\x03\xff\xfe\xfd";
    try testing.expect(validate(src, .{}));
    writeBlock(&sink, &theme.Theme.plain, src, .{});

    try testing.expectEqualStrings("  +-\n  | 1: ff fe fd\n  +-\n", sink.buf.items);
}

test "hex dump is capped and reports the full length" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();

    const body = [_]u8{0xff} ** 8;
    const src = "\x0a\x08" ++ body;
    writeBlock(&sink, &theme.Theme.plain, src, .{ .max_hex_bytes = 2 });

    try testing.expectEqualStrings("  +-\n  | 1: ff ff … 8 bytes\n  +-\n", sink.buf.items);
}

test "depth cap stops recursion" {
    var sink = TestSink{ .allocator = testing.allocator };
    defer sink.deinit();

    // Two levels of nesting, rendered with a cap of 1 so the inner message
    // must degrade to hex rather than recurse.
    const src = "\x0a\x04\x0a\x02\x00\x01";
    try testing.expect(validate(src, .{}));
    writeBlock(&sink, &theme.Theme.plain, src, .{ .max_depth = 1 });

    try testing.expectEqualStrings("  +-\n  | 1: 0a 02 00 01\n  +-\n", sink.buf.items);
}
