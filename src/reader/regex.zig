//! Pure-Zig ERE regex engine (case-insensitive, no libc).
//! Supports: . * + ? | ^ $ [...] (...) \d \w \s and their inverses.
//! Reports whether a pattern matches, and where — `findFrom` returns the
//! byte range of the leftmost match so the printer can highlight it. There is
//! still no sub-group capture; the range covers the whole match.

const std = @import("std");

/// Byte range of a whole-pattern match within the searched text.
pub const Match = struct { start: usize, end: usize };

pub const Regex = struct {
    pattern: []const u8,
    /// A literal every match must contain, lowercased, or empty. Checked
    /// with one substring search before the interpreter runs, which is
    /// what lets a line without it — nearly every line, for a search —
    /// cost a scan instead of an attempt at every byte.
    required: [max_required]u8 = undefined,
    required_len: u8 = 0,
    /// Bytes a match can start with, or null when that set says nothing
    /// (anchored, `.`-led, or able to match empty). Positions holding any
    /// other byte are skipped without entering the interpreter.
    first: ?std.StaticBitSet(256) = null,

    const max_required = 32;

    /// Compile a case-insensitive ERE pattern.
    /// Returns null if the pattern is syntactically invalid.
    pub fn compile(pattern: []const u8) ?Regex {
        if (!validate(pattern)) return null;
        var re: Regex = .{ .pattern = pattern };
        re.required_len = @intCast(requiredLiteral(pattern, &re.required).len);
        var set: std.StaticBitSet(256) = .empty;
        if (firstBytes(pattern, &set)) re.first = set;
        return re;
    }

    /// Returns true if any substring of `text` matches the pattern.
    pub fn isMatch(self: *const Regex, text: []const u8) bool {
        if (self.required_len > 0 and
            !containsLower(text, self.required[0..self.required_len])) return false;
        const set = self.first orelse return matchAnywhere(self.pattern, text);
        for (text, 0..) |c, i| {
            if (set.isSet(c) and matchAt(self.pattern, text, i) != null) return true;
        }
        return false;
    }

    /// Leftmost match at or after `from`, as a byte range.
    ///
    /// Filtering only ever needed a yes/no answer, so that is all the engine
    /// used to expose — and highlighting silently did nothing for any search
    /// the regex path claimed. `matchFrom` already computed the end offset
    /// internally; this hands it back instead of discarding it.
    pub fn findFrom(self: *const Regex, text: []const u8, from: usize) ?Match {
        const set = self.first orelse return findAnywhere(self.pattern, text, from);
        if (from >= text.len) return null;
        for (text[from..], from..) |c, i| {
            if (!set.isSet(c)) continue;
            // findAnywhere looks at every later start too, so its answer is
            // final either way.
            return findAnywhere(self.pattern, text, i);
        }
        return null;
    }

    pub fn deinit(self: *Regex) void {
        _ = self;
    }
};

const max_regex_terms = 8;

pub const RegexList = struct {
    regexes: [max_regex_terms]Regex = undefined,
    count: usize = 0,

    /// Compile `expr` as AND-separated patterns (split on `&`).
    /// Returns null if any part is invalid or there are too many terms.
    pub fn compile(expr: []const u8) ?RegexList {
        var self = RegexList{};
        if (std.mem.indexOfScalar(u8, expr, '&')) |_| {
            var it = std.mem.splitScalar(u8, expr, '&');
            while (it.next()) |part| {
                if (part.len == 0) continue;
                if (self.count >= max_regex_terms) {
                    self.deinit();
                    return null;
                }
                self.regexes[self.count] = Regex.compile(part) orelse {
                    self.deinit();
                    return null;
                };
                self.count += 1;
            }
        } else {
            self.regexes[0] = Regex.compile(expr) orelse return null;
            self.count = 1;
        }
        return self;
    }

    pub fn allMatch(self: *const RegexList, haystack: []const u8) bool {
        for (self.regexes[0..self.count]) |*re| {
            if (!re.isMatch(haystack)) return false;
        }
        return true;
    }

    pub fn deinit(self: *RegexList) void {
        for (self.regexes[0..self.count]) |*re| re.deinit();
        self.count = 0;
    }
};

// ── matching engine ──────────────────────────────────────────────────────────

fn matchAnywhere(pattern: []const u8, text: []const u8) bool {
    if (topAlt(pattern)) |pipe| {
        return matchAnywhere(pattern[0..pipe], text) or
            matchAnywhere(pattern[pipe + 1 ..], text);
    }
    if (pattern.len > 0 and pattern[0] == '^') {
        return matchFrom(pattern[1..], text, 0) != null;
    }
    // A leading `.*` or `.+` already reaches every position the rest of the
    // pattern could start at — its backtrack walks the whole line — so the
    // outer loop below would repeat that entire search once per starting
    // offset. Doing it once instead is what separates linear from quadratic
    // on the commonest prefix there is.
    if (leadingDotStar(pattern)) return matchFrom(pattern, text, 0) != null;

    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (matchFrom(pattern, text, i) != null) return true;
    }
    return false;
}

/// Case-insensitive substring test against an already-lowercased needle.
/// A vector compare finds candidates for the first byte in both cases,
/// sixteen bytes at a time; only those are verified.
fn containsLower(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    const V = @Vector(16, u8);
    const lo: V = @splat(needle[0]);
    const up: V = @splat(std.ascii.toUpper(needle[0]));
    const last = hay.len - needle.len;
    var i: usize = 0;
    while (i + 16 <= last + 1) : (i += 16) {
        const chunk: V = hay[i..][0..16].*;
        var bits: u16 = @bitCast((chunk == lo) | (chunk == up));
        while (bits != 0) : (bits &= bits - 1) {
            if (eqlLower(hay[i + @ctz(bits) ..][0..needle.len], needle)) return true;
        }
    }
    while (i <= last) : (i += 1) {
        if (eqlLower(hay[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn eqlLower(a: []const u8, lower: []const u8) bool {
    for (a, lower) |x, y| if (std.ascii.toLower(x) != y) return false;
    return true;
}

/// `pattern` at exactly `start`, any top-level branch. Only used once
/// `firstBytes` has vouched that no branch is anchored.
fn matchAt(pattern: []const u8, text: []const u8, start: usize) ?usize {
    if (topAlt(pattern)) |pipe| {
        return matchAt(pattern[0..pipe], text, start) orelse matchAt(pattern[pipe + 1 ..], text, start);
    }
    return matchFrom(pattern, text, start);
}

/// The longest run of literal bytes every match of `pattern` contains,
/// lowercased into `buf`. Empty when there is a top-level `|` — no single
/// literal is required then — or no literal at all.
fn requiredLiteral(pattern: []const u8, buf: []u8) []const u8 {
    if (topAlt(pattern) != null) return buf[0..0];
    var cur: [Regex.max_required]u8 = undefined;
    var cur_len: usize = 0;
    var best_len: usize = 0;
    var pp: usize = 0;
    while (pp < pattern.len) {
        const alen = atomLen(pattern[pp..]) orelse break;
        const atom = pattern[pp .. pp + alen];
        const q: u8 = if (pp + alen < pattern.len) pattern[pp + alen] else 0;
        pp += alen + @intFromBool(q == '*' or q == '+' or q == '?');

        const lit = literalByte(atom);
        if (lit != null and q != '*' and q != '?' and cur_len < @min(buf.len, cur.len)) {
            cur[cur_len] = std.ascii.toLower(lit.?);
            cur_len += 1;
        } else cur_len = 0;
        if (cur_len > best_len) {
            @memcpy(buf[0..cur_len], cur[0..cur_len]);
            best_len = cur_len;
        }
        // `x+` may be followed by more `x`s, so a run cannot continue past
        // it — but it does contribute its one guaranteed byte.
        if (q == '+') cur_len = 0;
    }
    return buf[0..best_len];
}

/// The byte `atom` stands for when it is a plain literal, else null.
fn literalByte(atom: []const u8) ?u8 {
    return switch (atom[0]) {
        '.', '[', '(', '^', '$' => null,
        '\\' => switch (atom[1]) {
            'd', 'D', 'w', 'W', 's', 'S', 'n', 'r', 't' => null,
            else => atom[1],
        },
        else => atom[0],
    };
}

/// Adds to `set` every byte a match of `pattern` can begin with. False when
/// the answer is useless or unknowable: an anchor, a leading `.`, or a
/// branch that can match the empty string.
fn firstBytes(pattern: []const u8, set: *std.StaticBitSet(256)) bool {
    if (topAlt(pattern)) |pipe| {
        return firstBytes(pattern[0..pipe], set) and firstBytes(pattern[pipe + 1 ..], set);
    }
    const alen = atomLen(pattern) orelse return false;
    if (alen < pattern.len and (pattern[alen] == '*' or pattern[alen] == '?')) return false;
    const atom = pattern[0..alen];
    switch (atom[0]) {
        '.', '^' => return false,
        '(' => return firstBytes(atom[1 .. atom.len - 1], set),
        else => {
            for (0..256) |c| {
                const byte = [1]u8{@intCast(c)};
                if (matchAtom(atom, &byte, 0) != null) set.set(c);
            }
            return true;
        },
    }
}

/// True when `pattern` opens with `.*` or `.+`.
///
/// `.?` does not qualify: it reaches at most one position past its start, so
/// a single attempt would miss matches further along.
fn leadingDotStar(pattern: []const u8) bool {
    return pattern.len >= 2 and pattern[0] == '.' and
        (pattern[1] == '*' or pattern[1] == '+');
}

/// Leftmost match of `pattern` in `text` at or after `from`.
///
/// Alternation is resolved by position first and length second, which is what
/// a reader expects to see highlighted: the earliest thing that matched, and
/// when two branches start together, the one that covers more of the line.
fn findAnywhere(pattern: []const u8, text: []const u8, from: usize) ?Match {
    if (topAlt(pattern)) |pipe| {
        const a = findAnywhere(pattern[0..pipe], text, from);
        const b = findAnywhere(pattern[pipe + 1 ..], text, from);
        const x = a orelse return b;
        const y = b orelse return x;
        if (y.start < x.start) return y;
        if (y.start == x.start and y.end > x.end) return y;
        return x;
    }
    if (pattern.len > 0 and pattern[0] == '^') {
        if (from > 0) return null;
        const end = matchFrom(pattern[1..], text, 0) orelse return null;
        return .{ .start = 0, .end = end };
    }
    // Same shortcut as `matchAnywhere`. The leftmost match of a pattern that
    // opens with `.*` or `.+` starts exactly where the search does, because
    // the repetition absorbs whatever precedes the rest of the pattern.
    if (leadingDotStar(pattern)) {
        const end = matchFrom(pattern, text, from) orelse return null;
        return .{ .start = from, .end = end };
    }

    var i: usize = from;
    while (i <= text.len) : (i += 1) {
        if (matchFrom(pattern, text, i)) |end| return .{ .start = i, .end = end };
    }
    return null;
}

/// Continuation chain for backtracking across group boundaries without heap
/// allocation. Each frame lives on the call stack and describes what must
/// match after the current group/branch succeeds.
const Cont = union(enum) {
    seq: struct {
        pat: []const u8,
        next: ?*const Cont,
    },
    rep_group: struct {
        inner: []const u8,
        min: usize,
        max: usize,
        count: usize,
        start_tp: usize,
        rest: []const u8,
        next: ?*const Cont,
    },
};

/// Upper bound on backtracking steps inside quantified/nested groups so
/// pathological patterns like `(a+)+b` cannot stall the process.
const max_group_steps: usize = 100_000;

/// Match `pattern` starting at `text[start]`.
/// Returns position after the match, or null on failure.
fn matchFrom(pattern: []const u8, text: []const u8, start: usize) ?usize {
    var steps: usize = 0;
    return matchFromCont(pattern, null, text, start, &steps);
}

fn evalCont(cont: ?*const Cont, text: []const u8, tp: usize, steps: *usize) ?usize {
    const c = cont orelse return tp;
    return switch (c.*) {
        .seq => |s| matchFromCont(s.pat, s.next, text, tp, steps),
        .rep_group => |rg| {
            const next_count = rg.count + 1;
            // Zero-width guard: a repetition that consumed 0 bytes cannot
            // repeat again, so finish directly with `rest`.
            if (tp == rg.start_tp) {
                if (next_count >= rg.min) {
                    return matchFromCont(rg.rest, rg.next, text, tp, steps);
                }
                return null;
            }
            return matchRepeatGroup(rg.inner, rg.min, rg.max, next_count, rg.rest, rg.next, text, tp, steps);
        },
    };
}

fn matchBranches(inner: []const u8, cont: ?*const Cont, text: []const u8, tp: usize, steps: *usize) ?usize {
    var branches = inner;
    while (true) {
        const pipe = topAlt(branches);
        const branch = branches[0 .. pipe orelse branches.len];
        if (matchFromCont(branch, cont, text, tp, steps)) |end| return end;
        branches = branches[(pipe orelse return null) + 1 ..];
    }
}

fn matchRepeatGroup(
    inner: []const u8,
    min: usize,
    max: usize,
    count: usize,
    rest: []const u8,
    cont: ?*const Cont,
    text: []const u8,
    tp: usize,
    steps: *usize,
) ?usize {
    if (steps.* >= max_group_steps) return null;
    steps.* += 1;

    if (count < max) {
        const next_cont: Cont = .{
            .rep_group = .{
                .inner = inner,
                .min = min,
                .max = max,
                .count = count,
                .start_tp = tp,
                .rest = rest,
                .next = cont,
            },
        };
        if (matchBranches(inner, &next_cont, text, tp, steps)) |end| return end;
    }

    if (count >= min) {
        return matchFromCont(rest, cont, text, tp, steps);
    }
    return null;
}

fn matchFromCont(pattern: []const u8, cont: ?*const Cont, text: []const u8, start: usize, steps: *usize) ?usize {
    var pp: usize = 0;
    var tp: usize = start;

    while (pp < pattern.len) {
        // ^ start anchor (works inside groups such as `(^err|warn)` as well as at pattern[0])
        if (pattern[pp] == '^') {
            if (tp != 0) return null;
            pp += 1;
            continue;
        }
        // $ end anchor — only special at the very end of this pattern segment
        if (pattern[pp] == '$' and pp + 1 == pattern.len) {
            return if (tp == text.len) evalCont(cont, text, tp, steps) else null;
        }

        const alen = atomLen(pattern[pp..]) orelse return null;
        const qp = pp + alen;

        if (qp < pattern.len) {
            switch (pattern[qp]) {
                '*' => {
                    if (pattern[pp] == '(') {
                        return matchRepeatGroup(pattern[pp + 1 .. qp - 1], 0, std.math.maxInt(usize), 0, pattern[qp + 1 ..], cont, text, tp, steps);
                    }
                    return matchRepeat(pattern[pp..qp], pattern[qp + 1 ..], cont, text, tp, 0, std.math.maxInt(usize), steps);
                },
                '+' => {
                    if (pattern[pp] == '(') {
                        return matchRepeatGroup(pattern[pp + 1 .. qp - 1], 1, std.math.maxInt(usize), 0, pattern[qp + 1 ..], cont, text, tp, steps);
                    }
                    return matchRepeat(pattern[pp..qp], pattern[qp + 1 ..], cont, text, tp, 1, std.math.maxInt(usize), steps);
                },
                '?' => {
                    if (pattern[pp] == '(') {
                        return matchRepeatGroup(pattern[pp + 1 .. qp - 1], 0, 1, 0, pattern[qp + 1 ..], cont, text, tp, steps);
                    }
                    return matchRepeat(pattern[pp..qp], pattern[qp + 1 ..], cont, text, tp, 0, 1, steps);
                },
                else => {},
            }
        }

        // Delegate every group — with or without `|` — through the continuation
        // chain so internal quantifiers (`(.*)error`, `(\w+)ms`) and branches
        // (`(err|error):`) backtrack against `pattern[qp..]`.
        if (pattern[pp] == '(') {
            const next_cont: Cont = .{
                .seq = .{
                    .pat = pattern[qp..],
                    .next = cont,
                },
            };
            return matchBranches(pattern[pp + 1 .. qp - 1], &next_cont, text, tp, steps);
        }

        const new_tp = matchAtom(pattern[pp..qp], text, tp) orelse return null;
        tp = new_tp;
        pp = qp;
    }

    return evalCont(cont, text, tp, steps);
}

/// Greedy repetition of a fixed-width `atom_pat` (not a group), at least `min`
/// and at most `max` times, then match `rest` + `cont`.
///
/// Backtracking gives up one repetition at a time in O(1) arithmetic because
/// every fixed-width atom consumes exactly one byte per match, keeping
/// `.*zzz` linear rather than quadratic.
fn matchRepeat(
    atom_pat: []const u8,
    rest: []const u8,
    cont: ?*const Cont,
    text: []const u8,
    start: usize,
    min: usize,
    max: usize,
    steps: *usize,
) ?usize {
    var count: usize = 0;
    var tp = start;
    while (tp < text.len and count < max) {
        const new_tp = matchAtom(atom_pat, text, tp) orelse break;
        if (new_tp == tp) break; // zero-width guard
        tp = new_tp;
        count += 1;
    }

    // Backtrack from count down to min
    while (true) {
        if (count >= min) {
            if (matchFromCont(rest, cont, text, tp, steps)) |end| return end;
        }
        if (count == 0) return null;
        count -= 1;
        tp = start + count;
    }
}

fn matchAtom(atom_pat: []const u8, text: []const u8, tp: usize) ?usize {
    if (atom_pat.len == 0) return tp;
    if (tp >= text.len) return null;
    const c = text[tp];
    return switch (atom_pat[0]) {
        '.' => tp + 1,
        '\\' => if (atom_pat.len >= 2 and matchEscape(atom_pat[1], c)) tp + 1 else null,
        '[' => if (matchClass(atom_pat, c)) tp + 1 else null,
        else => if (std.ascii.toLower(c) == std.ascii.toLower(atom_pat[0])) tp + 1 else null,
    };
}

fn matchEscape(esc: u8, c: u8) bool {
    return switch (esc) {
        'd' => c >= '0' and c <= '9',
        'D' => !(c >= '0' and c <= '9'),
        'w' => std.ascii.isAlphanumeric(c) or c == '_',
        'W' => !(std.ascii.isAlphanumeric(c) or c == '_'),
        's' => std.ascii.isWhitespace(c),
        'S' => !std.ascii.isWhitespace(c),
        'n' => c == '\n',
        'r' => c == '\r',
        't' => c == '\t',
        else => std.ascii.toLower(esc) == std.ascii.toLower(c),
    };
}

fn matchClass(class_pat: []const u8, c: u8) bool {
    var i: usize = 1;
    const negate = i < class_pat.len and class_pat[i] == '^';
    if (negate) i += 1;

    var found = false;
    // A `]` immediately after `[` or `[^` is a literal member of the class, not
    // the closing bracket.
    var first = true;
    while (i < class_pat.len and (first or class_pat[i] != ']')) {
        first = false;
        if (class_pat[i] == '\\' and i + 1 < class_pat.len) {
            if (matchEscape(class_pat[i + 1], c)) found = true;
            i += 2;
        } else if (i + 2 < class_pat.len and class_pat[i + 1] == '-' and class_pat[i + 2] != ']') {
            const lo = std.ascii.toLower(class_pat[i]);
            const hi = std.ascii.toLower(class_pat[i + 2]);
            if (std.ascii.toLower(c) >= lo and std.ascii.toLower(c) <= hi) found = true;
            i += 3;
        } else {
            if (std.ascii.toLower(class_pat[i]) == std.ascii.toLower(c)) found = true;
            i += 1;
        }
    }
    return if (negate) !found else found;
}

// ── pattern utilities ────────────────────────────────────────────────────────

/// Length of the first atom in `pattern` (bytes in the pattern, not in text).
fn atomLen(pattern: []const u8) ?usize {
    if (pattern.len == 0) return null;
    return switch (pattern[0]) {
        '\\' => if (pattern.len >= 2) @as(usize, 2) else null,
        '[' => blk: {
            var i: usize = 1;
            if (i < pattern.len and pattern[i] == '^') i += 1;
            if (i < pattern.len and pattern[i] == ']') i += 1;
            while (i < pattern.len and pattern[i] != ']') : (i += 1) {
                if (pattern[i] == '\\') i += 1;
            }
            break :blk if (i < pattern.len) i + 1 else null;
        },
        '(' => blk: {
            var depth: usize = 1;
            var in_class = false;
            var i: usize = 1;
            while (i < pattern.len and depth > 0) : (i += 1) {
                if (in_class) {
                    if (pattern[i] == '\\') {
                        i += 1;
                        continue;
                    }
                    if (pattern[i] == ']') in_class = false;
                    continue;
                }
                switch (pattern[i]) {
                    '\\' => i += 1,
                    '[' => {
                        in_class = true;
                        if (i + 1 < pattern.len and pattern[i + 1] == '^') i += 1;
                        if (i + 1 < pattern.len and pattern[i + 1] == ']') i += 1;
                    },
                    '(' => depth += 1,
                    ')' => depth -= 1,
                    else => {},
                }
            }
            break :blk if (depth == 0) i else null;
        },
        '.', '^' => @as(usize, 1),
        '$', '*', '+', '?', '|', ')' => null,
        else => @as(usize, 1),
    };
}

/// Position of the first top-level `|` (not inside `[...]` or `(...)`), or null.
fn topAlt(pattern: []const u8) ?usize {
    var depth: usize = 0;
    var in_class = false;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (in_class) {
            if (pattern[i] == '\\') {
                i += 1;
                continue;
            }
            if (pattern[i] == ']') in_class = false;
            continue;
        }
        switch (pattern[i]) {
            '\\' => i += 1,
            '[' => {
                in_class = true;
                if (i + 1 < pattern.len and pattern[i + 1] == '^') i += 1;
                if (i + 1 < pattern.len and pattern[i + 1] == ']') i += 1;
            },
            '(' => depth += 1,
            ')' => {
                if (depth > 0) depth -= 1;
            },
            '|' => if (depth == 0) return i,
            else => {},
        }
    }
    return null;
}

/// Returns false for unclosed `[`, `(`, trailing `\`, or quantifier with no preceding atom.
fn validate(pattern: []const u8) bool {
    var i: usize = 0;
    var depth: usize = 0;
    var last_was_atom = false;

    while (i < pattern.len) : (i += 1) {
        switch (pattern[i]) {
            '\\' => {
                i += 1;
                if (i >= pattern.len) return false;
                last_was_atom = true;
            },
            '[' => {
                i += 1;
                if (i < pattern.len and pattern[i] == '^') i += 1;
                if (i < pattern.len and pattern[i] == ']') i += 1;
                var closed = false;
                while (i < pattern.len) : (i += 1) {
                    if (pattern[i] == '\\') {
                        i += 1;
                        continue;
                    }
                    if (pattern[i] == ']') {
                        closed = true;
                        break;
                    }
                }
                if (!closed) return false;
                last_was_atom = true;
            },
            '(' => {
                depth += 1;
                last_was_atom = false;
            },
            ')' => {
                if (depth == 0) return false;
                depth -= 1;
                last_was_atom = true;
            },
            '*', '+', '?' => {
                if (!last_was_atom) return false;
                last_was_atom = false;
            },
            '|' => last_was_atom = false,
            else => last_was_atom = true,
        }
    }
    return depth == 0;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Regex.compile: valid pattern" {
    var re = Regex.compile("hello").?;
    defer re.deinit();
    try testing.expect(re.isMatch("hello world"));
    try testing.expect(re.isMatch("HELLO"));
    try testing.expect(!re.isMatch("world"));
}

test "Regex.compile: invalid pattern returns null" {
    try testing.expect(Regex.compile("[unclosed") == null);
}

test "Regex: dot-star pattern" {
    var re = Regex.compile(".*error.*").?;
    defer re.deinit();
    try testing.expect(re.isMatch("some error occurred"));
    try testing.expect(!re.isMatch("no issue here"));
}

test "Regex: anchored start" {
    var re = Regex.compile("^error").?;
    defer re.deinit();
    try testing.expect(re.isMatch("error here"));
    try testing.expect(!re.isMatch("some error here"));
}

test "Regex: anchored end" {
    var re = Regex.compile("error$").?;
    defer re.deinit();
    try testing.expect(re.isMatch("some error"));
    try testing.expect(!re.isMatch("error here"));
}

test "Regex: alternation via pipe" {
    var re = Regex.compile("error|timeout").?;
    defer re.deinit();
    try testing.expect(re.isMatch("connection timeout"));
    try testing.expect(re.isMatch("some error"));
    try testing.expect(!re.isMatch("all good"));
}

test "Regex: character class" {
    var re = Regex.compile("[0-9]+").?;
    defer re.deinit();
    try testing.expect(re.isMatch("code 404"));
    try testing.expect(!re.isMatch("no digits here"));
}

test "Regex: escape classes" {
    var re_d = Regex.compile("\\d+").?;
    defer re_d.deinit();
    try testing.expect(re_d.isMatch("error 42"));
    try testing.expect(!re_d.isMatch("no digits"));
}

test "Regex.isMatch supports long haystacks" {
    var re = Regex.compile("needle").?;
    defer re.deinit();

    const haystack = try testing.allocator.alloc(u8, 8192);
    defer testing.allocator.free(haystack);
    @memset(haystack, 'a');
    @memcpy(haystack[7000..7006], "needle");

    try testing.expect(re.isMatch(haystack));
}

test "Regex.compile supports long patterns" {
    const pattern = try testing.allocator.alloc(u8, 300);
    defer testing.allocator.free(pattern);
    @memset(pattern, 'a');

    var re = Regex.compile(pattern).?;
    defer re.deinit();

    const haystack = try testing.allocator.alloc(u8, 512);
    defer testing.allocator.free(haystack);
    @memset(haystack, 'a');

    try testing.expect(re.isMatch(haystack));
}

test "RegexList: AND logic" {
    var rl = RegexList.compile("error&connection").?;
    defer rl.deinit();
    try testing.expect(rl.allMatch("error: connection failed"));
    try testing.expect(!rl.allMatch("error: timeout"));
    try testing.expect(!rl.allMatch("connection: ok"));
}

test "RegexList: single pattern with alternation" {
    var rl = RegexList.compile("hello|world").?;
    defer rl.deinit();
    try testing.expect(rl.allMatch("hello"));
    try testing.expect(rl.allMatch("world"));
    try testing.expect(!rl.allMatch("nope"));
}

test "RegexList.compile cleans up when term limit is exceeded" {
    try testing.expect(RegexList.compile("a&b&c&d&e&f&g&h&i") == null);
}

test "a repetition backtracks in linear time, not quadratic" {
    // `.*` followed by something that never matches is the worst case for a
    // backtracking engine, and the shape most people actually type. Replaying
    // the atom from the start on every backtrack step made this cubic in the
    // length of the line: 4.8 seconds for one 2 KB line, measured.
    var text: [4096]u8 = undefined;
    @memset(&text, 'x');

    for ([_][]const u8{ ".*zzz", ".+zzz", "x.*y", "x.+y", "[a-z]*zzz" }) |pattern| {
        var re = Regex.compile(pattern).?;
        defer re.deinit();
        try testing.expect(!re.isMatch(&text));
    }
}

test "a leading .* still finds every match the slow path would" {
    // The single-start shortcut is only sound because the repetition's own
    // backtrack already visits every position; these are the cases that
    // would expose it if it did not.
    const cases = [_]struct { pattern: []const u8, text: []const u8, want: bool }{
        .{ .pattern = ".*abc", .text = "xxxabc", .want = true },
        .{ .pattern = ".*abc", .text = "abc", .want = true },
        .{ .pattern = ".*abc", .text = "xxxab", .want = false },
        .{ .pattern = ".+abc", .text = "xabc", .want = true },
        // `.+` must consume at least one byte, so a match at offset 0 alone
        // is not enough.
        .{ .pattern = ".+abc", .text = "abc", .want = false },
        .{ .pattern = ".*", .text = "", .want = true },
        .{ .pattern = ".*x", .text = "", .want = false },
        .{ .pattern = ".*b.*d", .text = "abcd", .want = true },
        .{ .pattern = "q|.*abc", .text = "zzabc", .want = true },
    };
    for (cases) |c| {
        var re = Regex.compile(c.pattern).?;
        defer re.deinit();
        try testing.expectEqual(c.want, re.isMatch(c.text));
    }
}

test "findFrom reports the same span with the shortcut as without" {
    var re = Regex.compile(".*abc").?;
    defer re.deinit();
    const m = re.findFrom("xxabcyy", 0).?;
    // `.*` is greedy but backtracks to the leftmost overall match, which
    // starts where the search did and ends after `abc`.
    try testing.expectEqual(@as(usize, 0), m.start);
    try testing.expectEqual(@as(usize, 5), m.end);

    try testing.expect(re.findFrom("nope", 0) == null);

    var plus = Regex.compile(".+abc").?;
    defer plus.deinit();
    const p = plus.findFrom("xabc", 0).?;
    try testing.expectEqual(@as(usize, 0), p.start);
    try testing.expectEqual(@as(usize, 4), p.end);
}

test "a group repetition still replays correctly when it backtracks" {
    // A group is the one atom whose width varies, so it keeps the replay
    // path — these check that path did not rot when the fixed-width one was
    // split out of it.
    var re = Regex.compile("(ab)*abc").?;
    defer re.deinit();
    try testing.expect(re.isMatch("ababc"));
    try testing.expect(re.isMatch("abc"));
    try testing.expect(!re.isMatch("ababab"));

    var alt = Regex.compile("(a|bb)+c").?;
    defer alt.deinit();
    try testing.expect(alt.isMatch("abbac"));
    try testing.expect(!alt.isMatch("abba"));
}

test "? matches at most once" {
    const re = Regex.compile("ab?c").?;
    try std.testing.expect(re.isMatch("ac"));
    try std.testing.expect(re.isMatch("abc"));
    try std.testing.expect(!re.isMatch("abbc"));
}

test "a group's alternatives are each tried against the rest of the pattern" {
    const re = Regex.compile("(err|error): ").?;
    try std.testing.expect(re.isMatch("error: disk full"));
    try std.testing.expect(re.isMatch("err: disk full"));
    try std.testing.expect(!re.isMatch("errors happen"));
    const m = re.findFrom("x error: y", 0).?;
    try std.testing.expectEqual(@as(usize, 2), m.start);
    try std.testing.expectEqual(@as(usize, 9), m.end);
}

test "requiredLiteral: the longest run every match must contain" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("refused", requiredLiteral("conn.*REFUSED", &buf));
    try std.testing.expectEqualStrings("status\":5", requiredLiteral("status\":5\\d\\d", &buf));
    try std.testing.expectEqualStrings("", requiredLiteral("a|b", &buf));
    try std.testing.expectEqualStrings("app.log", requiredLiteral("app\\.log", &buf));
    // An optional atom breaks a run; `x+` contributes one byte and ends it.
    try std.testing.expectEqualStrings("meo", requiredLiteral("ti?meo+ut", &buf));
}

test "firstBytes: only when every branch starts with a known byte" {
    var set: std.StaticBitSet(256) = .empty;
    try std.testing.expect(firstBytes("(timeout|refused)", &set));
    try std.testing.expect(set.isSet('t') and set.isSet('T') and set.isSet('r') and !set.isSet('x'));
    set = .empty;
    try std.testing.expect(firstBytes("\\d+ms", &set));
    try std.testing.expect(set.isSet('7') and !set.isSet('m'));
    try std.testing.expect(!firstBytes("^x", &set));
    try std.testing.expect(!firstBytes(".*x", &set));
    try std.testing.expect(!firstBytes("a?b", &set));
    try std.testing.expect(!firstBytes("a|", &set));
}

test "prefilters never change the answer" {
    const pats = [_][]const u8{ "(timeout|refused)", "status\":5\\d\\d", "job 12.*ms$", "^2026", "x?y", "[a-c]+z", "(a|ab)c", "o+k", "app\\.log" };
    const texts = [_][]const u8{ "", "connection refused", "TIMEOUT!", "status\":503", "status\":200", "job 1234 in 5ms", "2026-10-14", "y", "bbz", "abc", "ok", "ooook", "nothing here", "/var/app.log" };
    for (pats) |p| {
        const re = Regex.compile(p).?;
        for (texts) |t| {
            try std.testing.expectEqual(matchAnywhere(p, t), re.isMatch(t));
            const want = findAnywhere(p, t, 0);
            const got = re.findFrom(t, 0);
            try std.testing.expectEqual(want == null, got == null);
            if (want) |w| try std.testing.expectEqual(w.start, got.?.start);
        }
    }
}

test "containsLower: both cases, both paths, edges" {
    try std.testing.expect(containsLower("xxxxxxxxxxxxxxxxxxxxCONNECTION refused", "connection"));
    try std.testing.expect(containsLower("Refused", "refused"));
    try std.testing.expect(containsLower("aaaaaaaaaaaaaaaab", "ab"));
    try std.testing.expect(!containsLower("aaaaaaaaaaaaaaaaaaaaaaaa", "ab"));
    try std.testing.expect(!containsLower("ab", "abc"));
}

test "a group with three or more alternatives matches every branch" {
    // The second branch used to be handed on as `b|c`, which the sequence
    // matcher cannot read, so only the first alternative ever matched.
    const re = Regex.compile("(timeout|refused|job 1234)").?;
    try std.testing.expect(re.isMatch("connection timeout"));
    try std.testing.expect(re.isMatch("connection refused"));
    try std.testing.expect(re.isMatch("processed job 1234 in 5ms"));
    try std.testing.expect(!re.isMatch("processed job 999"));
    try std.testing.expect(Regex.compile("x(a|b|c)y").?.isMatch("xcy"));
}

test "quantified groups with 3+ alternatives match every branch" {
    const re = Regex.compile("(info|warn|error)+").?;
    try std.testing.expect(re.isMatch("info"));
    try std.testing.expect(re.isMatch("warn"));
    try std.testing.expect(re.isMatch("error"));
    try std.testing.expect(re.isMatch("warnerror"));
    try std.testing.expect(!re.isMatch("debug"));

    const opt = Regex.compile("^(a|b|c)?$").?;
    try std.testing.expect(opt.isMatch(""));
    try std.testing.expect(opt.isMatch("a"));
    try std.testing.expect(opt.isMatch("b"));
    try std.testing.expect(opt.isMatch("c"));
    try std.testing.expect(!opt.isMatch("d"));
}

test "groups with internal quantifiers or alternations backtrack for trailing pattern" {
    try std.testing.expect(Regex.compile("(.*)error").?.isMatch("some error"));
    try std.testing.expect(Regex.compile("(\\w+)ms").?.isMatch("500ms"));
    try std.testing.expect(Regex.compile("([a-z]+)c").?.isMatch("abc"));
    try std.testing.expect(Regex.compile("(err|error)?:").?.isMatch("error:"));
    try std.testing.expect(Regex.compile("(a|ab)+c").?.isMatch("abc"));
    try std.testing.expect(!Regex.compile("(a|ab)+c").?.isMatch("abd"));
}

test "nullable groups at end of text, bracket classes inside groups, leading ], and grouped ^" {
    // Nullable groups at end of input and `+`-quantified nullable groups
    try std.testing.expect(Regex.compile("foo(a*)").?.isMatch("foo"));
    try std.testing.expect(Regex.compile("foo(a?)").?.isMatch("foo"));
    try std.testing.expect(Regex.compile("^(a*)$").?.isMatch(""));
    try std.testing.expect(Regex.compile("error($)").?.isMatch("error"));
    try std.testing.expect(Regex.compile("(a*)+").?.isMatch("b"));
    try std.testing.expect(Regex.compile("(a*)+").?.isMatch(""));

    // Parentheses inside character classes within groups
    try std.testing.expect(Regex.compile("([)])").?.isMatch(")"));
    try std.testing.expect(Regex.compile("([a-z)]+)").?.isMatch("a)"));
    try std.testing.expect(Regex.compile("([(]a)").?.isMatch("(a"));

    // Literal leading `]` in character classes and with `|`
    try std.testing.expect(Regex.compile("[]a]").?.isMatch("]"));
    try std.testing.expect(Regex.compile("[]]").?.isMatch("]"));
    try std.testing.expect(!Regex.compile("[^]a]").?.isMatch("]"));
    try std.testing.expect(Regex.compile("[^]a]").?.isMatch("b"));
    try std.testing.expect(Regex.compile("[]|]").?.isMatch("|"));
    try std.testing.expect(Regex.compile("[^]|]").?.isMatch("a"));

    // `^` anchor inside groups
    try std.testing.expect(Regex.compile("(^error)").?.isMatch("error"));
    try std.testing.expect(!Regex.compile("(^error)").?.isMatch("^error"));
    try std.testing.expect(Regex.compile("(^err|warn)").?.isMatch("err"));
    try std.testing.expect(!Regex.compile("(^err|warn)").?.isMatch("x err"));
}
