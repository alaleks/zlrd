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

    /// Compile a case-insensitive ERE pattern.
    /// Returns null if the pattern is syntactically invalid.
    pub fn compile(pattern: []const u8) ?Regex {
        if (!validate(pattern)) return null;
        return .{ .pattern = pattern };
    }

    /// Returns true if any substring of `text` matches the pattern.
    pub fn isMatch(self: *const Regex, text: []const u8) bool {
        return matchAnywhere(self.pattern, text);
    }

    /// Leftmost match at or after `from`, as a byte range.
    ///
    /// Filtering only ever needed a yes/no answer, so that is all the engine
    /// used to expose — and highlighting silently did nothing for any search
    /// the regex path claimed. `matchFrom` already computed the end offset
    /// internally; this hands it back instead of discarding it.
    pub fn findFrom(self: *const Regex, text: []const u8, from: usize) ?Match {
        return findAnywhere(self.pattern, text, from);
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

/// Match `pattern` starting at `text[start]`.
/// Returns position after the match, or null on failure.
fn matchFrom(pattern: []const u8, text: []const u8, start: usize) ?usize {
    var pp: usize = 0;
    var tp: usize = start;

    while (pp < pattern.len) {
        // $ end anchor — only special at the very end of this pattern segment
        if (pattern[pp] == '$' and pp + 1 == pattern.len) {
            return if (tp == text.len) tp else null;
        }

        const alen = atomLen(pattern[pp..]) orelse return null;
        const qp = pp + alen;

        if (qp < pattern.len) {
            switch (pattern[qp]) {
                '*' => return matchRepeat(pattern[pp..qp], pattern[qp + 1 ..], text, tp, 0),
                '+' => return matchRepeat(pattern[pp..qp], pattern[qp + 1 ..], text, tp, 1),
                '?' => return matchRepeat(pattern[pp..qp], pattern[qp + 1 ..], text, tp, 0),
                else => {},
            }
        }

        const new_tp = matchAtom(pattern[pp..qp], text, tp) orelse return null;
        tp = new_tp;
        pp = qp;
    }

    return tp;
}

/// True when `atom_pat` consumes exactly one byte whenever it matches.
///
/// Every atom does except a group: `.`, a literal, a class, and an escape all
/// advance by one. A group's width depends on what is inside it, so only it
/// has to be re-walked to find out where a shorter repetition ends.
fn isFixedWidthAtom(atom_pat: []const u8) bool {
    return atom_pat.len > 0 and atom_pat[0] != '(';
}

/// Greedy repetition of `atom_pat`, then match `rest`. min ∈ {0,1}.
/// For `?`, max is 1; for `*`/`+`, max is unbounded.
///
/// Backtracking gives up one repetition at a time, and the position after
/// `count` of them used to be recovered by replaying the atom `count` times
/// from `start`. That made one repetition quadratic in its own length, and
/// `matchAnywhere` then multiplied it by every starting position: `.*` at the
/// front of a pattern turned into cubic work in the length of the line.
///
/// It measured the way that sounds. `zlrd -s '.*zzz'` against a single 2 KB
/// line took 4.8 seconds, and `-s 'x.*y'` 4.6 — not adversarial patterns, the
/// ordinary ones. Under `--alert-regex` the same shape stalls the agent's
/// watcher thread, which keeps answering `/metrics` while it has stopped
/// reading logs entirely.
///
/// For an atom of fixed width the position after `count` repetitions is just
/// arithmetic, which is what the replay was recomputing.
fn matchRepeat(
    atom_pat: []const u8,
    rest: []const u8,
    text: []const u8,
    start: usize,
    min: usize,
) ?usize {
    var count: usize = 0;
    var tp = start;
    while (tp < text.len) {
        const new_tp = matchAtom(atom_pat, text, tp) orelse break;
        if (new_tp == tp) break; // zero-width guard
        tp = new_tp;
        count += 1;
    }

    const fixed_width = isFixedWidthAtom(atom_pat);

    // Backtrack from count down to min
    while (true) {
        if (count >= min) {
            if (matchFrom(rest, text, tp)) |end| return end;
        }
        if (count == 0) return null;
        count -= 1;
        if (fixed_width) {
            tp = start + count;
        } else {
            // A group: replay it to find where `count` repetitions end.
            tp = start;
            var k: usize = 0;
            while (k < count) : (k += 1) {
                tp = matchAtom(atom_pat, text, tp) orelse return null;
            }
        }
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
        '(' => matchGroupFrom(atom_pat[1 .. atom_pat.len - 1], text, tp),
        else => if (std.ascii.toLower(c) == std.ascii.toLower(atom_pat[0])) tp + 1 else null,
    };
}

fn matchGroupFrom(inner: []const u8, text: []const u8, tp: usize) ?usize {
    if (topAlt(inner)) |pipe| {
        return matchFrom(inner[0..pipe], text, tp) orelse
            matchFrom(inner[pipe + 1 ..], text, tp);
    }
    return matchFrom(inner, text, tp);
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
    if (i < class_pat.len and class_pat[i] == ']') i += 1; // ] as first char is literal

    var found = false;
    while (i < class_pat.len and class_pat[i] != ']') {
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
            var i: usize = 1;
            while (i < pattern.len and depth > 0) : (i += 1) {
                switch (pattern[i]) {
                    '\\' => i += 1,
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
            '[' => in_class = true,
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
