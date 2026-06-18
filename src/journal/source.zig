//! Discovery helpers for native journal sources. Locates the active
//! `system.journal` file under `/var/log/journal/<machine-id>/` (persistent)
//! or `/run/log/journal/<machine-id>/` (volatile), and matches `_SYSTEMD_UNIT`
//! values against user-supplied glob patterns.
//!
//! Linux-only. On other platforms the discovery functions return null and
//! the caller is expected to fall back to whatever it had before.

const std = @import("std");
const builtin = @import("builtin");

const fmt = @import("format.zig");
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

/// Returns an owned path to the active `system.journal` file. Walks both
/// the persistent (`/var/log/journal`) and volatile (`/run/log/journal`)
/// roots and picks the one whose header's `tail_entry_realtime` is freshest
/// — matches the behavior of systemd's own writer when both directories
/// are populated (e.g. transient → persistent migration). Falls back to the
/// systemd-default persistent-over-volatile preference if neither file is
/// readable. Caller frees with `allocator`.
pub fn findActiveJournalPath(allocator: std.mem.Allocator, io: std.Io) DiscoveryError![]u8 {
    if (comptime builtin.os.tag != .linux) return error.NotLinux;

    var mid_buf: [40]u8 = undefined;
    const mid = try readMachineId(io, &mid_buf);

    var best_path: ?[]u8 = null;
    errdefer if (best_path) |p| allocator.free(p);
    var best_realtime: u64 = 0;

    for ([_][]const u8{ persistent_root, volatile_root }) |root| {
        const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{
            root, mid, system_journal_basename,
        });
        var keep = false;
        defer if (!keep) allocator.free(candidate);

        const rt = journalTailRealtime(io, candidate) catch continue;
        // Either no contender yet, or this file's tail is newer.
        if (best_path == null or rt > best_realtime) {
            if (best_path) |old| allocator.free(old);
            best_path = candidate;
            best_realtime = rt;
            keep = true;
        }
    }

    return best_path orelse error.JournalDirNotFound;
}

/// Reads just enough of a journal file's header to extract the writer's
/// `tail_entry_realtime` (the wall-clock microseconds of the most recent
/// entry). Cheaper than opening a full `Reader` since we don't validate
/// the rest of the file.
fn journalTailRealtime(io: std.Io, path: []const u8) !u64 {
    const f = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return error.OpenFailed;
    defer f.close(io);

    var hdr_bytes: [@sizeOf(fmt.Header)]u8 = undefined;
    const n = f.readPositional(io, &.{&hdr_bytes}, 0) catch return error.ReadFailed;
    if (n != hdr_bytes.len) return error.ReadFailed;

    const hdr = std.mem.bytesAsValue(fmt.Header, &hdr_bytes).*;
    if (!std.mem.eql(u8, &hdr.signature, &fmt.signature_magic)) return error.BadMagic;
    return hdr.tail_entry_realtime;
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


/// True if `unit` matches the user-supplied `pattern`. The pattern syntax
/// is the same shell-style glob that `journalctl -u` accepts, restricted
/// to the `*` wildcard (no `?`, no character classes).
///
/// Implemented as an iterative two-pointer match with backtracking. The
/// previous recursive implementation was O(2^n) for patterns like
/// `*a*a*a*a*` against `aaaa...`; this one is O(n*m).
pub fn matchesUnitGlob(pattern: []const u8, unit: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var star_text: usize = 0;

    while (t < unit.len) {
        if (p < pattern.len and pattern[p] == '*') {
            // Collapse runs of `**` and remember where to backtrack to.
            while (p < pattern.len and pattern[p] == '*') p += 1;
            star = p;
            star_text = t;
            if (p == pattern.len) return true;
            continue;
        }
        if (p < pattern.len and pattern[p] == unit[t]) {
            p += 1;
            t += 1;
            continue;
        }
        if (star) |sp| {
            // Back off: the `*` we last saw must swallow one more byte of `unit`.
            p = sp;
            star_text += 1;
            t = star_text;
            continue;
        }
        return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
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
