//! Discovery helpers for native journal sources. Locates the active
//! `system.journal` file under `/var/log/journal/<machine-id>/` (persistent)
//! or `/run/log/journal/<machine-id>/` (volatile), and matches `_SYSTEMD_UNIT`
//! values against user-supplied glob patterns.
//!
//! Linux-only. On other platforms the discovery functions return
//! `error.NotLinux` and the caller is expected to fall back to whatever it
//! had before.

const std = @import("std");
const builtin = @import("builtin");

const fmt = @import("format.zig");

const log = std.log.scoped(.zlrd_journal_source);

const machine_id_path = "/etc/machine-id";
const persistent_root = "/var/log/journal";
const volatile_root = "/run/log/journal";
const system_journal_basename = "system.journal";

/// Length of a systemd machine ID: 32 lowercase hex digits (`man machine-id`).
const machine_id_len = 32;

pub const DiscoveryError = error{
    NotLinux,
    MachineIdMissing,
    MachineIdInvalid,
    JournalDirNotFound,
} || std.mem.Allocator.Error;

/// Returns an owned path to the active `system.journal` file. Walks both
/// the persistent (`/var/log/journal`) and volatile (`/run/log/journal`)
/// roots and picks the one whose header's `tail_entry_realtime` is freshest
/// — matching systemd's own behavior when both directories are populated
/// (e.g. a transient → persistent migration). Returns
/// `error.JournalDirNotFound` when neither candidate can be read as a
/// journal file. Caller frees with `allocator`.
pub fn findActiveJournalPath(allocator: std.mem.Allocator, io: std.Io) DiscoveryError![]u8 {
    if (comptime builtin.os.tag != .linux) return error.NotLinux;

    var mid_buf: [machine_id_len + 8]u8 = undefined;
    const mid = try readMachineId(io, &mid_buf);
    return findFreshestJournal(allocator, io, .cwd(), &.{ persistent_root, volatile_root }, mid);
}

/// The root-scanning half of `findActiveJournalPath`, split out so it can be
/// driven against a temporary directory in tests instead of the real
/// filesystem layout. `roots` are tried in order and act as the tiebreaker
/// when tail timestamps are equal.
fn findFreshestJournal(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    roots: []const []const u8,
    machine_id: []const u8,
) DiscoveryError![]u8 {
    var best_path: ?[]u8 = null;
    errdefer if (best_path) |p| allocator.free(p);
    var best_realtime: u64 = 0;

    for (roots) |root| {
        const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{
            root, machine_id, system_journal_basename,
        });
        var keep = false;
        defer if (!keep) allocator.free(candidate);

        const rt = journalTailRealtime(io, dir, candidate) catch continue;
        // Either no contender yet, or this file's tail is strictly newer —
        // a tie leaves the earlier root (persistent) in place.
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
fn journalTailRealtime(io: std.Io, dir: std.Io.Dir, path: []const u8) !u64 {
    const f = dir.openFile(io, path, .{ .mode = .read_only }) catch return error.OpenFailed;
    defer f.close(io);

    var hdr_bytes: [@sizeOf(fmt.Header)]u8 = undefined;
    const n = f.readPositionalAll(io, &hdr_bytes, 0) catch return error.ReadFailed;
    if (n != hdr_bytes.len) return error.ReadFailed;

    const hdr = std.mem.bytesAsValue(fmt.Header, &hdr_bytes).*;
    if (!std.mem.eql(u8, &hdr.signature, &fmt.signature_magic)) return error.BadMagic;
    return hdr.tail_entry_realtime;
}

fn readMachineId(io: std.Io, buf: []u8) DiscoveryError![]const u8 {
    const f = std.Io.Dir.cwd().openFile(io, machine_id_path, .{ .mode = .read_only }) catch
        return error.MachineIdMissing;
    defer f.close(io);
    const n = f.readPositionalAll(io, buf, 0) catch return error.MachineIdInvalid;
    return validateMachineId(buf[0..n]) orelse error.MachineIdInvalid;
}

/// Validates the contents of `/etc/machine-id` and returns the ID itself,
/// or null if the file doesn't hold one.
///
/// The ID is interpolated into a filesystem path, so shape-checking it is a
/// containment measure as much as a correctness one: a file holding `../..`
/// must not be able to steer discovery out of the journal tree. `man
/// machine-id` specifies exactly 32 lowercase hex digits plus a newline, and
/// the journal directory is named after that string verbatim, so anything
/// else could not match a real journal directory anyway.
pub fn validateMachineId(raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len != machine_id_len) return null;
    for (trimmed) |c| {
        if (!std.ascii.isHex(c)) return null;
        if (std.ascii.isUpper(c)) return null;
    }
    return trimmed;
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
const debug_io = std.Options.debug_io;

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

test "matchesUnitGlob: empty pattern and empty unit" {
    try testing.expect(matchesUnitGlob("", ""));
    try testing.expect(!matchesUnitGlob("", "nginx.service"));
    try testing.expect(!matchesUnitGlob("nginx.service", ""));
    try testing.expect(matchesUnitGlob("*", ""));
}

test "matchesUnitGlob: backtracks when a wildcard overshoots" {
    // The greedy first attempt consumes both leading 'a's; the match only
    // succeeds after backing the wildcard off by one.
    try testing.expect(matchesUnitGlob("*ab", "aab"));
    try testing.expect(matchesUnitGlob("*aab", "aaab"));
    try testing.expect(!matchesUnitGlob("*ab", "aba"));
    try testing.expect(matchesUnitGlob("a*b*c", "axxbyyc"));
    try testing.expect(!matchesUnitGlob("a*b*c", "axxbyy"));
}

test "matchesUnitGlob: pathological pattern stays linear" {
    // The recursive implementation this replaced went exponential here.
    const unit = "a" ** 40;
    try testing.expect(!matchesUnitGlob("*a*a*a*a*a*b", unit));
    try testing.expect(matchesUnitGlob("*a*a*a*a*a*a", unit));
}

test "matchesUnitGlob: '?' is a literal, not a wildcard" {
    try testing.expect(matchesUnitGlob("a?c", "a?c"));
    try testing.expect(!matchesUnitGlob("a?c", "abc"));
}

test "matchesUnitGlob: matching is case sensitive" {
    try testing.expect(!matchesUnitGlob("NGINX.service", "nginx.service"));
}

test "validateMachineId accepts a well-formed id" {
    const id = "0123456789abcdef0123456789abcdef";
    try testing.expectEqualStrings(id, validateMachineId(id).?);
    try testing.expectEqualStrings(id, validateMachineId(id ++ "\n").?);
    try testing.expectEqualStrings(id, validateMachineId(" " ++ id ++ " \r\n").?);
}

test "validateMachineId rejects anything that is not 32 lowercase hex digits" {
    try testing.expect(validateMachineId("") == null);
    try testing.expect(validateMachineId("\n") == null);
    // Too short / too long.
    try testing.expect(validateMachineId("0123456789abcdef") == null);
    try testing.expect(validateMachineId("0123456789abcdef0123456789abcdef0") == null);
    // Non-hex, including path separators that would escape the journal tree.
    try testing.expect(validateMachineId("0123456789abcdef0123456789abcdeg") == null);
    try testing.expect(validateMachineId("../../../etc/passwd\x00aaaaaaaaaaa") == null);
    try testing.expect(validateMachineId("..0123456789abcdef0123456789ab/x") == null);
    // Uppercase: systemd writes lowercase, and the directory name must match.
    try testing.expect(validateMachineId("0123456789ABCDEF0123456789abcdef") == null);
}

/// Writes a minimal journal file whose header carries `tail_entry_realtime`.
fn writeStubJournal(dir: std.Io.Dir, path: []const u8, tail_realtime: u64, magic_ok: bool) !void {
    var h: fmt.Header = std.mem.zeroes(fmt.Header);
    if (magic_ok) h.signature = fmt.signature_magic;
    h.header_size = @sizeOf(fmt.Header);
    h.tail_entry_realtime = tail_realtime;
    try dir.writeFile(debug_io, .{ .sub_path = path, .data = std.mem.asBytes(&h) });
}

const stub_mid = "0123456789abcdef0123456789abcdef";

fn stubRoots(dir: std.Io.Dir) !void {
    try dir.createDirPath(debug_io, "persistent/" ++ stub_mid);
    try dir.createDirPath(debug_io, "volatile/" ++ stub_mid);
}

test "findFreshestJournal prefers the freshest tail timestamp" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try stubRoots(tmp.dir);

    // Volatile is newer, so it wins despite persistent being listed first.
    try writeStubJournal(tmp.dir, "persistent/" ++ stub_mid ++ "/system.journal", 1_000, true);
    try writeStubJournal(tmp.dir, "volatile/" ++ stub_mid ++ "/system.journal", 9_000, true);

    const got = try findFreshestJournal(
        testing.allocator,
        debug_io,
        tmp.dir,
        &.{ "persistent", "volatile" },
        stub_mid,
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("volatile/" ++ stub_mid ++ "/system.journal", got);
}

test "findFreshestJournal keeps the earlier root on a tie" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try stubRoots(tmp.dir);

    // Equal timestamps (e.g. two freshly created files) must fall back to
    // systemd's persistent-over-volatile preference.
    try writeStubJournal(tmp.dir, "persistent/" ++ stub_mid ++ "/system.journal", 5_000, true);
    try writeStubJournal(tmp.dir, "volatile/" ++ stub_mid ++ "/system.journal", 5_000, true);

    const got = try findFreshestJournal(
        testing.allocator,
        debug_io,
        tmp.dir,
        &.{ "persistent", "volatile" },
        stub_mid,
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("persistent/" ++ stub_mid ++ "/system.journal", got);
}

test "findFreshestJournal skips unreadable and non-journal candidates" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try stubRoots(tmp.dir);

    // Persistent exists but isn't a journal; volatile is the only real one.
    try writeStubJournal(tmp.dir, "persistent/" ++ stub_mid ++ "/system.journal", 9_999, false);
    try writeStubJournal(tmp.dir, "volatile/" ++ stub_mid ++ "/system.journal", 1, true);

    const got = try findFreshestJournal(
        testing.allocator,
        debug_io,
        tmp.dir,
        &.{ "persistent", "volatile", "does-not-exist" },
        stub_mid,
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("volatile/" ++ stub_mid ++ "/system.journal", got);
}

test "findFreshestJournal reports JournalDirNotFound when nothing is readable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.expectError(error.JournalDirNotFound, findFreshestJournal(
        testing.allocator,
        debug_io,
        tmp.dir,
        &.{ "persistent", "volatile" },
        stub_mid,
    ));
}

test "findFreshestJournal rejects a file truncated below the header" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try stubRoots(tmp.dir);
    try tmp.dir.writeFile(debug_io, .{
        .sub_path = "persistent/" ++ stub_mid ++ "/system.journal",
        .data = "LPKSHHRH",
    });

    try testing.expectError(error.JournalDirNotFound, findFreshestJournal(
        testing.allocator,
        debug_io,
        tmp.dir,
        &.{"persistent"},
        stub_mid,
    ));
}

test "discovery returns NotLinux on macOS/BSD" {
    if (comptime builtin.os.tag == .linux) return error.SkipZigTest;
    try testing.expectError(error.NotLinux, findActiveJournalPath(testing.allocator, debug_io));
}
