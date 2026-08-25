//! Detection and pretty-printing of JSON embedded *inside* a log message.
//!
//! Two shapes show up in practice and both are handled:
//!
//!   1. Raw, in a plain-text line —
//!      `12:00:01 INFO api: upstream replied {"id":5,"items":[1,2]}`
//!   2. Escaped, as a string value of a JSON log line —
//!      `{"level":"info","msg":"replied","body":"{\"id\":5}"}`
//!
//! ## Why this doesn't slow the reader down
//!
//! The work is ordered so that a line without embedded JSON pays almost
//! nothing:
//!
//!   - Nothing here runs during *filtering*. A line that gets filtered out is
//!     never inspected, so the cost scales with printed lines, not file size.
//!   - The gate is a single SIMD scan for `{`. Lines without one stop there.
//!   - Validation is one linear pass with no allocation and no recursion; it
//!     aborts at the first byte that can't belong to JSON, so the usual false
//!     positive (a Go map, a brace in prose) costs a handful of bytes.
//!   - Un-escaping and printing write into caller-owned scratch and the
//!     output buffer. There is no parse tree and no allocator involved at any
//!     point.
//!
//! The net effect on a line that *does* carry JSON is roughly two extra
//! passes over the JSON region — which we were already going to write out
//! byte for byte anyway.

const std = @import("std");
const simd = @import("simd");
const theme = @import("theme.zig");

/// Bounds that keep a malformed or hostile line from turning into unbounded
/// work. All are deliberately generous for real logs and tight enough that a
/// pathological line can't stall the reader.
pub const Limits = struct {
    /// Nesting cap. Also bounds `writeBlock`'s recursion depth.
    max_depth: u8 = 24,
    /// Largest region we will expand. Beyond this the line is printed as-is.
    max_bytes: usize = 64 * 1024,
    /// Below this a `{…}` isn't worth a multi-line block.
    min_bytes: usize = 12,
};

/// A JSON region located inside a line.
pub const Span = struct {
    start: usize,
    end: usize,

    pub inline fn slice(self: Span, line: []const u8) []const u8 {
        return line[self.start..self.end];
    }
};

// ─── Validation ───────────────────────────────────────────────────────────

/// Returns the byte length of the complete JSON object or array starting at
/// `src[0]`, or null if `src` doesn't open one, it never closes, it exceeds
/// the limits, or it holds a byte that cannot occur in JSON.
///
/// Iterative, so nesting costs a bit in a fixed-size depth counter rather
/// than stack frames.
pub fn validate(src: []const u8, limits: Limits) ?usize {
    if (src.len < 2) return null;
    if (src[0] != '{' and src[0] != '[') return null;

    const scan_len = @min(src.len, limits.max_bytes);
    var depth: u8 = 0;
    var i: usize = 0;
    var in_string = false;
    // A structural `:` is what separates a real object from `{}` or a
    // brace-wrapped fragment of prose.
    var pairs: usize = 0;

    while (i < scan_len) : (i += 1) {
        const c = src[i];
        if (in_string) {
            if (c == '\\') {
                i += 1; // skip the escaped byte
                continue;
            }
            if (c == '"') in_string = false;
            // Raw control bytes are illegal inside a JSON string; seeing one
            // means this was never JSON.
            if (c < 0x20) return null;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{', '[' => {
                if (depth == limits.max_depth) return null;
                depth += 1;
            },
            '}', ']' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) {
                    const len = i + 1;
                    if (len < limits.min_bytes or pairs == 0) return null;
                    return len;
                }
            },
            ':' => pairs += 1,
            ',', ' ', '\t', '\r', '\n' => {},
            '-', '+', '.', '0'...'9' => {},
            'a'...'z', 'A'...'Z' => {}, // true / false / null (and slop)
            else => return null,
        }
    }
    return null; // never closed within the budget
}

/// Locates an embedded JSON object in `line` at or after `from`.
///
/// Only `{`-rooted objects are considered. `[` is deliberately excluded: log
/// lines are full of bracketed prefixes (`[INFO]`, `[2026-08-25]`) and
/// treating those as candidates would turn the cheap gate into a scan of
/// every line.
pub fn find(line: []const u8, from: usize, limits: Limits) ?Span {
    var pos = from;
    while (pos < line.len) {
        const open = simd.findByte(line, pos, '{') orelse return null;
        if (validate(line[open..], limits)) |len| {
            return .{ .start = open, .end = open + len };
        }
        pos = open + 1;
    }
    return null;
}

// ─── Un-escaping ──────────────────────────────────────────────────────────

/// Decodes one level of JSON string escaping from `src` into `dst`.
///
/// Returns the decoded bytes, or null when `dst` is too small or `src` holds
/// an escape we don't decode — in which case the caller prints the value
/// as-is rather than guessing.
///
/// `\uXXXX` is decoded for the Basic Multilingual Plane, including surrogate
/// pairs, since real logs carry non-ASCII messages.
pub fn unescape(dst: []u8, src: []const u8) ?[]const u8 {
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
        var cp: u21 = std.fmt.parseInt(u16, src[i .. i + 4], 16) catch return null;
        i += 4;
        if (cp >= 0xD800 and cp <= 0xDBFF) {
            // High surrogate — pair it with the low one that must follow.
            if (i + 6 > src.len or src[i] != '\\' or src[i + 1] != 'u') return null;
            const lo = std.fmt.parseInt(u16, src[i + 2 .. i + 6], 16) catch return null;
            if (lo < 0xDC00 or lo > 0xDFFF) return null;
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
            i += 6;
        } else if (cp >= 0xDC00 and cp <= 0xDFFF) {
            return null; // lone low surrogate
        }
        const n = std.unicode.utf8CodepointSequenceLength(cp) catch return null;
        if (out + n > dst.len) return null;
        _ = std.unicode.utf8Encode(cp, dst[out..]) catch return null;
        out += n;
    }
    return dst[0..out];
}

/// True if `value` (the raw bytes of a JSON string value, still escaped)
/// looks like it wraps a nested JSON object. Cheap pre-check before paying
/// for `unescape`.
pub fn looksLikeNestedObject(value: []const u8, limits: Limits) bool {
    if (value.len < limits.min_bytes) return false;
    return value[0] == '{' and value[value.len - 1] == '}';
}

// ─── Pretty printing ──────────────────────────────────────────────────────

/// A container is kept on one line when it holds no nested container and the
/// *rendered* result still fits inside this many columns, counting the gutter
/// and the indent already spent on that line. Without inlining, every
/// `[1, 2, 3]` would cost five lines; without the column budget, a nested
/// object would inline itself into a line that wraps.
const inline_max_cols: usize = 92;

/// Hard ceiling on how far `fitsInline` will scan, so the check stays O(1)
/// with respect to document size regardless of the column budget.
const inline_scan_limit: usize = inline_max_cols;

/// Number of spaces per nesting level.
const indent_width: usize = 2;

/// Writes `src` — which must already have passed `validate` — as an indented,
/// coloured block. Each physical line is prefixed with a dim gutter so the
/// block reads as an attachment to the log line above it rather than as more
/// log lines.
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
    w.newline(0);
    _ = w.value(src, 0, 0, 0);

    out.write("\n");
    out.write(p.dim);
    out.write("  ");
    out.write(th.glyphs.bottom);
    out.write(th.glyphs.rule);
    out.write(p.reset);
    out.write("\n");
}

/// Walks a validated JSON value and emits it. Generic over the sink so tests
/// can render into an `ArrayList` without standing up the real output buffer.
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

        /// Columns a fresh output line has already consumed before any
        /// content: the two-space margin, the gutter bar, and the space
        /// after it.
        const gutter_cols: usize = 4;

        /// Emits the value starting at `src[i]`; returns the index just past
        /// it. `depth` drives indentation and `col` carries how much of the
        /// current output line is already spent, so a container can tell
        /// whether inlining it would overflow the terminal.
        fn value(self: *Self, src: []const u8, i_in: usize, depth: usize, col: usize) usize {
            var i = skipWs(src, i_in);
            if (i >= src.len) return i;
            return switch (src[i]) {
                '{' => self.container(src, i, depth, col, '}'),
                '[' => self.container(src, i, depth, col, ']'),
                '"' => blk: {
                    const end = stringEnd(src, i) orelse break :blk src.len;
                    self.out.write(self.th.palette.json_string);
                    self.out.write(src[i..end]);
                    self.out.write(self.th.palette.reset);
                    break :blk end;
                },
                else => blk: {
                    const start = i;
                    while (i < src.len and !isStructural(src[i])) : (i += 1) {}
                    const tok = std.mem.trimEnd(u8, src[start..i], " \t\r\n");
                    const color = if (isWordLiteral(tok))
                        self.th.palette.json_bool_null
                    else
                        self.th.palette.json_number;
                    self.out.write(color);
                    self.out.write(tok);
                    self.out.write(self.th.palette.reset);
                    break :blk i;
                },
            };
        }

        fn container(self: *Self, src: []const u8, open_at: usize, depth: usize, col: usize, close: u8) usize {
            const is_object = close == '}';
            // Past the depth cap, or short enough to read on one line: keep it
            // on one line, so we neither recurse without bound nor explode a
            // two-element array across five lines. The outermost container is
            // always expanded — collapsing it would defeat the whole block.
            const flat = depth + 1 >= self.limits.max_depth or
                (depth > 0 and fitsInline(src, open_at, col));

            self.punct(src[open_at .. open_at + 1]);
            var i = skipWs(src, open_at + 1);
            var first = true;

            while (i < src.len and src[i] != close) {
                if (!first) {
                    self.punct(",");
                    if (flat) self.out.write(" ");
                }
                if (!flat) self.newline(depth + 1);
                first = false;

                // Columns spent on this output line before the value starts.
                var value_col = gutter_cols + (depth + 1) * indent_width;
                if (is_object) {
                    if (i >= src.len or src[i] != '"') break;
                    const key_end = stringEnd(src, i) orelse break;
                    self.out.write(self.th.palette.json_key);
                    self.out.write(src[i..key_end]);
                    self.out.write(self.th.palette.reset);
                    value_col += (key_end - i) + 2; // key plus `: `
                    i = skipWs(src, key_end);
                    if (i < src.len and src[i] == ':') {
                        self.punct(":");
                        self.out.write(" ");
                        i += 1;
                    }
                }

                i = self.value(src, i, depth + 1, value_col);
                i = skipWs(src, i);
                if (i < src.len and src[i] == ',') i = skipWs(src, i + 1);
            }

            if (!flat and !first) self.newline(depth);
            if (i < src.len and src[i] == close) {
                self.punct(src[i .. i + 1]);
                return i + 1;
            }
            return i;
        }
    };
}

/// True when the container starting at `src[i]` should stay on one line:
/// it holds no nested container, and rendering it after `used_cols` columns
/// of gutter, indent and key still lands within `inline_max_cols`.
///
/// Rendering adds one space after every structural `:` and `,`, so those are
/// counted as we go rather than measured on the source alone.
///
/// The scan stops after `inline_scan_limit` bytes, which makes this a
/// constant-cost check no matter how large the document is.
fn fitsInline(src: []const u8, i: usize, used_cols: usize) bool {
    if (used_cols >= inline_max_cols) return false;
    const budget = inline_max_cols - used_cols;

    var depth: usize = 0;
    var seps: usize = 0;
    var j = i;
    var in_string = false;
    const stop = @min(src.len, i + inline_scan_limit);
    while (j < stop) : (j += 1) {
        const c = src[j];
        if (in_string) {
            if (c == '\\') {
                j += 1;
            } else if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            ':', ',' => seps += 1,
            '{', '[' => {
                depth += 1;
                if (depth > 1) return false; // nested container
            },
            '}', ']' => {
                depth -= 1;
                if (depth == 0) return (j + 1 - i) + seps <= budget;
            },
            else => {},
        }
    }
    return false;
}

inline fn skipWs(src: []const u8, from: usize) usize {
    var i = from;
    while (i < src.len and (src[i] == ' ' or src[i] == '\t' or src[i] == '\r' or src[i] == '\n')) : (i += 1) {}
    return i;
}

inline fn isStructural(c: u8) bool {
    return c == ',' or c == '}' or c == ']' or c == ':';
}

fn isWordLiteral(tok: []const u8) bool {
    return std.mem.eql(u8, tok, "true") or
        std.mem.eql(u8, tok, "false") or
        std.mem.eql(u8, tok, "null");
}

/// Index just past the closing quote of the string starting at `src[i] == '"'`.
fn stringEnd(src: []const u8, i: usize) ?usize {
    var j = i + 1;
    while (j < src.len) : (j += 1) {
        if (src[j] == '\\') {
            j += 1;
            continue;
        }
        if (src[j] == '"') return j + 1;
    }
    return null;
}

// ─── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Minimal sink matching the interface `writeBlock` expects.
const TestSink = struct {
    buf: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestSink) void {
        self.buf.deinit(testing.allocator);
    }
    pub fn write(self: *TestSink, s: []const u8) void {
        self.buf.appendSlice(testing.allocator, s) catch unreachable;
    }
    fn items(self: *const TestSink) []const u8 {
        return self.buf.items;
    }
};

fn render(src: []const u8) !std.ArrayList(u8) {
    var sink = TestSink{};
    const th = theme.Theme.plain;
    writeBlock(&sink, &th, src, .{});
    return sink.buf;
}

fn renderOwned(src: []const u8) ![]u8 {
    var buf = try render(src);
    return buf.toOwnedSlice(testing.allocator);
}

test "validate accepts a well-formed object" {
    const src = "{\"id\":5,\"ok\":true}xx";
    const len = validate(src, .{}).?;
    try testing.expectEqualStrings("{\"id\":5,\"ok\":true}", src[0..len]);
}

test "validate rejects things that only look like JSON" {
    // No key/value separator: a brace-wrapped fragment, not an object.
    try testing.expect(validate("{abcdefghijklmno}", .{}) == null);
    // Too short to be worth expanding.
    try testing.expect(validate("{\"a\":1}", .{}) == null);
    // Never closes.
    try testing.expect(validate("{\"id\":5,\"name\":\"unterminated", .{}) == null);
    // Doesn't open a container.
    try testing.expect(validate("\"id\":5}", .{}) == null);
    try testing.expect(validate("", .{}) == null);
    // Raw control byte inside a string.
    try testing.expect(validate("{\"a\":\"x\x01yyyyyyyyyy\"}", .{}) == null);
    // Closes more than it opens.
    try testing.expect(validate("{\"a\":1}}}}}}}}}}}", .{}) == null);
}

test "validate honours the depth and size caps" {
    const deep = "{\"a\":" ++ ("[" ** 40) ++ ("]" ** 40) ++ "}";
    try testing.expect(validate(deep, .{ .max_depth = 8 }) == null);
    const big = "{\"key\":\"" ++ ("x" ** 500) ++ "\"}";
    try testing.expect(validate(big, .{ .max_bytes = 64 }) == null);
    try testing.expect(validate(big, .{}) != null);
}

test "validate stops at the matching brace, not the last one" {
    const src = "{\"a\":{\"b\":1}} trailing {\"c\":2}";
    const len = validate(src, .{}).?;
    try testing.expectEqualStrings("{\"a\":{\"b\":1}}", src[0..len]);
}

test "find locates JSON embedded in a plain-text line" {
    const line = "12:00:01 INFO api: upstream replied {\"id\":5,\"ok\":true} in 3ms";
    const span = find(line, 0, .{}).?;
    try testing.expectEqualStrings("{\"id\":5,\"ok\":true}", span.slice(line));
}

test "find skips a false brace and keeps looking" {
    const line = "map[a:1] {not json} then {\"real\":true,\"n\":2}";
    const span = find(line, 0, .{}).?;
    try testing.expectEqualStrings("{\"real\":true,\"n\":2}", span.slice(line));
}

test "find returns null when there is no JSON" {
    try testing.expect(find("plain log line with no braces", 0, .{}) == null);
    try testing.expect(find("has { but never closes", 0, .{}) == null);
}

test "find respects the starting offset" {
    const line = "{\"skipped\":1,\"x\":2} tail {\"wanted\":true,\"y\":3}";
    const span = find(line, 20, .{}).?;
    try testing.expectEqualStrings("{\"wanted\":true,\"y\":3}", span.slice(line));
}

test "unescape decodes the simple escapes" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "{\"id\":5}",
        unescape(&buf, "{\\\"id\\\":5}").?,
    );
    try testing.expectEqualStrings("a\nb\tc\\d\"e", unescape(&buf, "a\\nb\\tc\\\\d\\\"e").?);
}

test "unescape decodes \\u escapes including surrogate pairs" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("привет", unescape(&buf, "\\u043f\\u0440\\u0438\\u0432\\u0435\\u0442").?);
    // U+1F600 as a surrogate pair.
    try testing.expectEqualStrings("😀", unescape(&buf, "\\ud83d\\ude00").?);
}

test "unescape refuses rather than guessing" {
    var buf: [4]u8 = undefined;
    // Doesn't fit.
    try testing.expect(unescape(&buf, "aaaaaaaaaa") == null);
    // Unknown escape.
    var big: [64]u8 = undefined;
    try testing.expect(unescape(&big, "\\q") == null);
    // Truncated \u.
    try testing.expect(unescape(&big, "\\u12") == null);
    // Lone high surrogate.
    try testing.expect(unescape(&big, "\\ud83d") == null);
    // Lone low surrogate.
    try testing.expect(unescape(&big, "\\udc00") == null);
    // Trailing backslash.
    try testing.expect(unescape(&big, "abc\\") == null);
}

test "looksLikeNestedObject gates on shape and length" {
    try testing.expect(looksLikeNestedObject("{\\\"id\\\":5,\\\"ok\\\":true}", .{}));
    // Real but shorter than min_bytes: not worth a block.
    try testing.expect(!looksLikeNestedObject("{\\\"a\\\":1}", .{}));
    try testing.expect(!looksLikeNestedObject("plain message", .{}));
    try testing.expect(!looksLikeNestedObject("{}", .{}));
    try testing.expect(!looksLikeNestedObject("{\"a\":1", .{}));
}

test "writeBlock expands an object across lines with a gutter" {
    const got = try renderOwned("{\"id\":5,\"name\":\"widget\",\"ok\":true}");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\  +-
        \\  | {
        \\  |   "id": 5,
        \\  |   "name": "widget",
        \\  |   "ok": true
        \\  | }
        \\  +-
        \\
    , got);
}

test "writeBlock keeps short containers on one line" {
    const got = try renderOwned("{\"items\":[1,2,3],\"tag\":\"x\"}");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\  +-
        \\  | {
        \\  |   "items": [1, 2, 3],
        \\  |   "tag": "x"
        \\  | }
        \\  +-
        \\
    , got);
}

test "writeBlock keeps a short nested object inline" {
    const got = try renderOwned("{\"req\":{\"method\":\"GET\",\"path\":\"/v1\"},\"ms\":12}");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\  +-
        \\  | {
        \\  |   "req": {"method": "GET", "path": "/v1"},
        \\  |   "ms": 12
        \\  | }
        \\  +-
        \\
    , got);
}

test "writeBlock expands a nested object once it outgrows the column budget" {
    const got = try renderOwned(
        "{\"req\":{\"method\":\"GET\",\"path\":\"/v1/items/search\",\"referer\":\"https://example.com/a\"},\"ms\":12}",
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\  +-
        \\  | {
        \\  |   "req": {
        \\  |     "method": "GET",
        \\  |     "path": "/v1/items/search",
        \\  |     "referer": "https://example.com/a"
        \\  |   },
        \\  |   "ms": 12
        \\  | }
        \\  +-
        \\
    , got);
}

test "no rendered line exceeds the column budget by much" {
    // The inline rule budgets *rendered* columns, not source bytes: the
    // spaces added after `:` and `,` and the indent already spent on the line
    // all count. Getting that wrong is invisible in a unit test that only
    // checks content, but wraps in a real terminal.
    const src = "{\"a\":{\"k1\":\"vvvvvvvvvv\",\"k2\":\"wwwwwwwwww\",\"k3\":\"xxxxxxxxxx\"}," ++
        "\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]}";
    const got = try renderOwned(src);
    defer testing.allocator.free(got);
    var it = std.mem.splitScalar(u8, got, '\n');
    while (it.next()) |ln| {
        try testing.expect(ln.len <= inline_max_cols + 4);
    }
}

test "writeBlock expands an array of objects" {
    const got = try renderOwned("{\"rows\":[{\"a\":1,\"bb\":2},{\"a\":3,\"bb\":4}]}");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\  +-
        \\  | {
        \\  |   "rows": [
        \\  |     {"a": 1, "bb": 2},
        \\  |     {"a": 3, "bb": 4}
        \\  |   ]
        \\  | }
        \\  +-
        \\
    , got);
}

test "writeBlock handles an escaped-string value verbatim" {
    // Quotes inside a string value must not be read as structure.
    const got = try renderOwned("{\"msg\":\"he said \\\"hi\\\" loudly\",\"n\":1}");
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "\"he said \\\"hi\\\" loudly\"") != null);
}

test "writeBlock colours keys, strings, numbers and literals distinctly" {
    var sink = TestSink{};
    defer sink.deinit();
    const th = theme.Theme.forMode(.truecolor, theme.Glyphs.unicode);
    writeBlock(&sink, &th, "{\"k\":\"s\",\"n\":42,\"b\":null}", .{});
    const p = th.palette;
    const got = sink.items();
    try testing.expect(std.mem.indexOf(u8, got, p.json_key) != null);
    try testing.expect(std.mem.indexOf(u8, got, p.json_string) != null);
    try testing.expect(std.mem.indexOf(u8, got, p.json_number) != null);
    try testing.expect(std.mem.indexOf(u8, got, p.json_bool_null) != null);
    try testing.expect(std.mem.indexOf(u8, got, "│") != null);
}

test "writeBlock emits nothing coloured under the plain theme" {
    const got = try renderOwned("{\"id\":5,\"name\":\"x\"}");
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "\x1b[") == null);
}

test "writeBlock flattens past the depth cap instead of recursing" {
    const src = "{\"a\":{\"b\":{\"c\":{\"d\":{\"e\":{\"f\":1}}}}}}";
    var sink = TestSink{};
    defer sink.deinit();
    const th = theme.Theme.plain;
    writeBlock(&sink, &th, src, .{ .max_depth = 3 });
    // Must terminate and still contain the innermost data.
    try testing.expect(std.mem.indexOf(u8, sink.items(), "\"f\"") != null);
}

test "round trip: validate then expand every field survives" {
    const src = "{\"level\":\"info\",\"count\":17,\"ratio\":-0.5,\"ok\":false,\"tags\":[\"a\",\"b\"]}";
    try testing.expect(validate(src, .{}) != null);
    const got = try renderOwned(src);
    defer testing.allocator.free(got);
    for ([_][]const u8{ "\"level\"", "\"info\"", "\"count\"", "17", "-0.5", "false", "\"tags\"", "\"a\"", "\"b\"" }) |needle| {
        try testing.expect(std.mem.indexOf(u8, got, needle) != null);
    }
}

test "writeBlock terminates on every prefix of a valid document" {
    // Truncated input reaches the writer only through a bug, but it must not
    // hang or read out of bounds if it does.
    const full = "{\"a\":[1,{\"b\":\"c\"},true],\"d\":{\"e\":null}}";
    var i: usize = 1;
    while (i <= full.len) : (i += 1) {
        var sink = TestSink{};
        defer sink.deinit();
        const th = theme.Theme.plain;
        writeBlock(&sink, &th, full[0..i], .{});
    }
}
