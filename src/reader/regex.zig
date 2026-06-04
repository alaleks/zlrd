//! POSIX regex wrapper for pattern matching.
//! Provides compiled regex caching and case-insensitive match support.

const c = @cImport(@cInclude("regex.h"));

pub const Regex = struct {
    preg: c.regex_t,
    compiled: bool = false,

    /// Compile a case-insensitive regex pattern.
    /// Returns null if compilation fails (pattern is invalid).
    pub fn compile(pattern: []const u8) ?Regex {
        // POSIX regcomp requires null-terminated strings.
        var buf: [256]u8 = undefined;
        if (pattern.len >= buf.len) return null;
        @memcpy(buf[0..pattern.len], pattern);
        buf[pattern.len] = 0;
        var self = Regex{ .preg = undefined };
        const rc = c.regcomp(&self.preg, &buf, c.REG_EXTENDED | c.REG_ICASE | c.REG_NOSUB);
        if (rc != 0) return null;
        self.compiled = true;
        return self;
    }

    /// Returns true if the haystack matches the compiled regex.
    pub fn isMatch(self: *const Regex, haystack: []const u8) bool {
        if (!self.compiled) return false;
        // POSIX regexec requires null-terminated strings.
        var buf: [4096]u8 = undefined;
        if (haystack.len >= buf.len) return false;
        @memcpy(buf[0..haystack.len], haystack);
        buf[haystack.len] = 0;
        return c.regexec(&self.preg, &buf, 0, null, 0) == 0;
    }

    /// Free the compiled regex.
    pub fn deinit(self: *Regex) void {
        if (self.compiled) c.regfree(&self.preg);
        self.compiled = false;
    }
};

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
                if (self.count >= max_regex_terms) return null;
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

const std = @import("std");
