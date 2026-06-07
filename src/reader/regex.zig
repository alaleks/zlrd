//! POSIX regex wrapper for pattern matching.
//! Provides compiled regex caching and case-insensitive match support.

const std = @import("std");
const c = @cImport(@cInclude("regex.h"));

pub const Regex = struct {
    preg: c.regex_t,
    compiled: bool = false,

    /// Compile a case-insensitive regex pattern.
    /// Returns null if compilation fails (pattern is invalid).
    pub fn compile(pattern: []const u8) ?Regex {
        // POSIX regcomp requires null-terminated strings.
        const buf = allocNullTerminated(pattern) orelse return null;
        defer std.heap.c_allocator.free(buf);

        var self = Regex{ .preg = undefined };
        const rc = c.regcomp(&self.preg, buf.ptr, c.REG_EXTENDED | c.REG_ICASE | c.REG_NOSUB);
        if (rc != 0) return null;
        self.compiled = true;
        return self;
    }

    /// Returns true if the haystack matches the compiled regex.
    pub fn isMatch(self: *const Regex, haystack: []const u8) bool {
        if (!self.compiled) return false;
        // POSIX regexec requires null-terminated strings.
        var stack_buf: [4096]u8 = undefined;
        if (haystack.len < stack_buf.len) {
            @memcpy(stack_buf[0..haystack.len], haystack);
            stack_buf[haystack.len] = 0;
            return c.regexec(&self.preg, &stack_buf, 0, null, 0) == 0;
        }

        const buf = allocNullTerminated(haystack) orelse return false;
        defer std.heap.c_allocator.free(buf);
        return c.regexec(&self.preg, buf.ptr, 0, null, 0) == 0;
    }

    /// Free the compiled regex.
    pub fn deinit(self: *Regex) void {
        if (self.compiled) c.regfree(&self.preg);
        self.compiled = false;
    }
};

fn allocNullTerminated(bytes: []const u8) ?[]u8 {
    const buf = std.heap.c_allocator.alloc(u8, bytes.len + 1) catch return null;
    @memcpy(buf[0..bytes.len], bytes);
    buf[bytes.len] = 0;
    return buf;
}

const max_regex_terms = 8;

/// Compiled regex list for AND-separated patterns.
pub const RegexList = struct {
    regexes: [max_regex_terms]Regex = undefined,
    count: usize = 0,

    /// Try to compile `expr` as a set of regex patterns.
    /// If the expression contains `&`, each part is compiled separately (AND logic).
    /// If any part fails to compile, the entire list is considered invalid.
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

    /// Returns true if all compiled regexes match the haystack.
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

const testing = std.testing;

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

test "RegexList.compile cleans up when term limit is exceeded" {
    try testing.expect(RegexList.compile("a&b&c&d&e&f&g&h&i") == null);
}
