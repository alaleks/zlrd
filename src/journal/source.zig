//! Discovery helpers for native journal sources. Locates the active
//! `system.journal` file under `/var/log/journal/<machine-id>/` (persistent)
//! or `/run/log/journal/<machine-id>/` (volatile), and matches `_SYSTEMD_UNIT`
//! values against user-supplied glob patterns.
//!
//! Linux-only. On other platforms the discovery functions return null and
//! the caller is expected to fall back to whatever it had before.

const std = @import("std");
const builtin = @import("builtin");

const reader_mod = @import("reader.zig");
const tail_mod = @import("tail.zig");

const log = std.log.scoped(.zlrd_journal_source);

const machine_id_path = "/etc/machine-id";
const persistent_root = "/var/log/journal";
const volatile_root = "/run/log/journal";
const system_journal_basename = "system.journal";

pub const DiscoveryError = error{
    NotLinux,
    MachineIdMissing,
    MachineIdInvalid,
    JournalDirNotFound,
} || std.mem.Allocator.Error;

/// Returns an owned path to the active `system.journal` file. Prefers the
/// persistent location over the volatile one — matches systemd's own
/// preference order. Caller frees with `allocator`.
pub fn findActiveJournalPath(allocator: std.mem.Allocator, io: std.Io) DiscoveryError![]u8 {
    if (comptime builtin.os.tag != .linux) return error.NotLinux;

    var mid_buf: [40]u8 = undefined;
    const mid = try readMachineId(io, &mid_buf);

    for ([_][]const u8{ persistent_root, volatile_root }) |root| {
        const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{
            root, mid, system_journal_basename,
        });
        errdefer allocator.free(candidate);
        if (pathExists(io, candidate)) return candidate;
        allocator.free(candidate);
    }
    return error.JournalDirNotFound;
}

fn readMachineId(io: std.Io, buf: []u8) DiscoveryError![]const u8 {
    const f = std.Io.Dir.cwd().openFile(io, machine_id_path, .{ .mode = .read_only }) catch
        return error.MachineIdMissing;
    defer f.close(io);
    const n = f.readStreaming(io, &.{buf}) catch return error.MachineIdInvalid;
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (trimmed.len < 8 or trimmed.len > 32) return error.MachineIdInvalid;
    // The trimmed slice may not point at the start of `buf` (no leading WS in
    // /etc/machine-id, but be safe).
    @memcpy(buf[0..trimmed.len], trimmed);
    return buf[0..trimmed.len];
}

fn pathExists(io: std.Io, path: []const u8) bool {
    const f = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return false;
    f.close(io);
    return true;
}

/// True if `unit` matches the user-supplied `pattern`. The pattern syntax is
/// the same shell-style glob that `journalctl -u` accepts, restricted to the
/// `*` wildcard (no `?`, no character classes) — sufficient for everything
/// agent mode realistically encounters.
pub fn matchesUnitGlob(pattern: []const u8, unit: []const u8) bool {
    return globMatch(pattern, 0, unit, 0);
}

fn globMatch(pat: []const u8, pi: usize, txt: []const u8, ti: usize) bool {
    var p = pi;
    var t = ti;
    while (p < pat.len) {
        switch (pat[p]) {
            '*' => {
                // Skip consecutive stars.
                while (p < pat.len and pat[p] == '*') p += 1;
                if (p == pat.len) return true; // trailing `*` matches the rest
                while (t <= txt.len) : (t += 1) {
                    if (globMatch(pat, p, txt, t)) return true;
                }
                return false;
            },
            else => {
                if (t >= txt.len or pat[p] != txt[t]) return false;
                p += 1;
                t += 1;
            },
        }
    }
    return t == txt.len;
}

// ─── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "matchesUnitGlob: exact match" {
    try testing.expect(matchesUnitGlob("nginx.service", "nginx.service"));
    try testing.expect(!matchesUnitGlob("nginx.service", "nginx.socket"));
    try testing.expect(!matchesUnitGlob("nginx.service", "nginx.servic"));
}

test "matchesUnitGlob: trailing wildcard" {
    try testing.expect(matchesUnitGlob("nginx*", "nginx.service"));
    try testing.expect(matchesUnitGlob("nginx*", "nginx"));
    try testing.expect(!matchesUnitGlob("nginx*", "apache.service"));
}

test "matchesUnitGlob: leading wildcard" {
    try testing.expect(matchesUnitGlob("*.service", "nginx.service"));
    try testing.expect(matchesUnitGlob("*.service", "a.service"));
    try testing.expect(!matchesUnitGlob("*.service", "nginx.socket"));
}

test "matchesUnitGlob: middle wildcard" {
    try testing.expect(matchesUnitGlob("web-*-prod.service", "web-api-prod.service"));
    try testing.expect(matchesUnitGlob("web-*-prod.service", "web--prod.service"));
    try testing.expect(!matchesUnitGlob("web-*-prod.service", "web-api-dev.service"));
}

test "matchesUnitGlob: multiple wildcards collapse" {
    try testing.expect(matchesUnitGlob("***.service", "x.service"));
    try testing.expect(matchesUnitGlob("*", "anything.at.all"));
    try testing.expect(matchesUnitGlob("**", ""));
}

test "discovery returns NotLinux on macOS/BSD" {
    if (comptime builtin.os.tag == .linux) return;
    const tio = std.Options.debug_io;
    try testing.expectError(error.NotLinux, findActiveJournalPath(testing.allocator, tio));
}
