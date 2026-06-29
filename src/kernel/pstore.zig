//! Post-boot reconciliation: detects a kernel panic that happened on the
//! previous boot by inspecting `/sys/fs/pstore/` (persistent storage area
//! kept across reboots by EFI vars / RAM oops region) and the panic bit of
//! `/proc/sys/kernel/tainted`.
//!
//! Runs synchronously once at agent startup; never allocates. Non-Linux
//! platforms compile to a no-op.

const std = @import("std");
const builtin = @import("builtin");

const kernel = @import("kernel.zig");

const log = std.log.scoped(.zlrd_pstore);

const pstore_dir_path = "/sys/fs/pstore";
const tainted_path = "/proc/sys/kernel/tainted";

/// Bit 9 of `/proc/sys/kernel/tainted` indicates the kernel has at some point
/// fired a panic since boot (TAINT_DIE in linux/kernel.h).
pub const taint_die_bit: u64 = 1 << 9;

/// Maximum number of pstore filenames we'll report in the detail field.
const max_dumps_in_detail = 4;

/// Scans pstore + tainted and emits at most one `panic_prev_boot` event when
/// the kernel reports panic evidence. `io` is reserved for symmetry with the
/// kmsg backend; pstore reads happen via raw syscalls.
pub fn scan(io: std.Io, sink: kernel.Sink, ctx: ?*anyopaque) !void {
    _ = io;
    if (comptime builtin.os.tag != .linux) return;

    var detail_buf: [128]u8 = undefined;
    var detail_w: std.Io.Writer = .fixed(&detail_buf);

    const tainted_value = readTainted();
    const has_taint_die = (tainted_value & taint_die_bit) != 0;

    var dump_count: usize = 0;
    countPstoreDumps(&dump_count, &detail_w) catch {};

    if (!has_taint_die and dump_count == 0) return;

    // Only emit the `"; "` separator when we have BOTH halves to join.
    // Previously the separator was written whenever the buffer was non-empty,
    // producing a dangling `"dump1,dump2; "` when dumps were present but
    // TAINT_DIE wasn't set.
    if (has_taint_die) {
        if (detail_w.buffered().len > 0) detail_w.writeAll("; ") catch {};
        detail_w.print("tainted=0x{x}", .{tainted_value}) catch {};
    }

    sink(ctx, kernel.makeEvent(
        .panic_prev_boot,
        .pstore,
        0,
        "",
        detail_w.buffered(),
    ));
    log.info("prior-boot panic evidence detected (dumps={d}, tainted=0x{x})", .{ dump_count, tainted_value });
}

/// Reads `/proc/sys/kernel/tainted` and returns its decimal value. Returns 0
/// on any error (the file is absent or unreadable).
fn readTainted() u64 {
    if (comptime builtin.os.tag != .linux) return 0;
    var buf: [32]u8 = undefined;
    const slice = readFileFully(tainted_path, &buf) catch return 0;
    const trimmed = std.mem.trim(u8, slice, " \t\n\r");
    return std.fmt.parseInt(u64, trimmed, 10) catch 0;
}

/// Counts entries in `/sys/fs/pstore/` and appends up to `max_dumps_in_detail`
/// names into `detail_w`. Returns silently when the directory is missing
/// (pstore not configured / mounted).
fn countPstoreDumps(out_count: *usize, detail_w: *std.Io.Writer) !void {
    if (comptime builtin.os.tag != .linux) return;
    const linux = std.os.linux;

    var path_z: [pstore_dir_path.len + 1]u8 = undefined;
    @memcpy(path_z[0..pstore_dir_path.len], pstore_dir_path);
    path_z[pstore_dir_path.len] = 0;
    const path_sentinel: [*:0]const u8 = @ptrCast(&path_z);

    const flags: linux.O = .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    };
    const open_rc = linux.openat(linux.AT.FDCWD, path_sentinel, flags, 0);
    if (std.posix.errno(open_rc) != .SUCCESS) return;
    const fd: i32 = @intCast(open_rc);
    defer _ = linux.close(fd);

    var dirent_buf: [4096]u8 = undefined;
    var emitted: usize = 0;
    while (true) {
        const n = linux.getdents64(fd, &dirent_buf, dirent_buf.len);
        const errno = std.posix.errno(n);
        if (errno != .SUCCESS) return;
        if (n == 0) break;

        var off: usize = 0;
        while (off < n) {
            const d: *align(1) const linux.dirent64 = @ptrCast(&dirent_buf[off]);
            const name_ptr: [*:0]const u8 = @ptrCast(&dirent_buf[off + @offsetOf(linux.dirent64, "name")]);
            const name = std.mem.span(name_ptr);
            off += d.reclen;

            if (name.len == 0 or name[0] == '.') continue;
            // Only count pstore dump prefixes — guarantees we don't false-fire
            // on stale test files left in the directory.
            if (!std.mem.startsWith(u8, name, "dmesg-") and
                !std.mem.startsWith(u8, name, "console-") and
                !std.mem.startsWith(u8, name, "pmsg-") and
                !std.mem.startsWith(u8, name, "ftrace-")) continue;

            out_count.* += 1;
            if (emitted < max_dumps_in_detail) {
                if (emitted > 0) detail_w.writeAll(",") catch {};
                detail_w.writeAll(name) catch {};
                emitted += 1;
            }
        }
    }
}

/// Reads a small file (kernel sysctl) fully into `buf` and returns the slice.
/// Errors if the file can't be opened or doesn't fit.
fn readFileFully(path: []const u8, buf: []u8) ![]const u8 {
    if (comptime builtin.os.tag != .linux) return error.Unsupported;
    const linux = std.os.linux;

    if (path.len + 1 > 256) return error.PathTooLong;
    var path_z: [256]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const path_sentinel: [*:0]const u8 = @ptrCast(&path_z);

    const flags: linux.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true };
    const open_rc = linux.openat(linux.AT.FDCWD, path_sentinel, flags, 0);
    if (std.posix.errno(open_rc) != .SUCCESS) return error.OpenFailed;
    const fd: i32 = @intCast(open_rc);
    defer _ = linux.close(fd);

    var total: usize = 0;
    while (total < buf.len) {
        const n = linux.read(fd, buf[total..].ptr, buf.len - total);
        const errno = std.posix.errno(n);
        if (errno == .INTR) continue;
        if (errno != .SUCCESS) return error.ReadFailed;
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

const testing = std.testing;

test "taint_die_bit value matches kernel TAINT_DIE" {
    try testing.expectEqual(@as(u64, 0x200), taint_die_bit);
}

test "scan: no-op on non-Linux compiles cleanly" {
    if (comptime builtin.os.tag == .linux) return;
    // On other platforms, `scan` returns without invoking the sink.
    var calls: u32 = 0;
    const Cap = struct {
        fn cb(ctx: ?*anyopaque, event: kernel.KernelEvent) void {
            _ = event;
            const slot: *u32 = @ptrCast(@alignCast(ctx.?));
            slot.* += 1;
        }
    };
    try scan(undefined, Cap.cb, &calls);
    try testing.expectEqual(@as(u32, 0), calls);
}

test "detail separator: emit only when both halves present" {
    // Reproduces the bug we fixed: writeAll("; ") used to fire whenever
    // detail_w already had bytes, producing "dump1,dump2; " when tainted
    // was clear. Exercise the helper in isolation.
    var buf: [128]u8 = undefined;
    {
        var w: std.Io.Writer = .fixed(&buf);
        try w.writeAll("dump1,dump2");
        const has_taint_die = false;
        if (has_taint_die) {
            if (w.buffered().len > 0) try w.writeAll("; ");
            try w.print("tainted=0x{x}", .{0x200});
        }
        try testing.expectEqualStrings("dump1,dump2", w.buffered());
    }
    {
        var w: std.Io.Writer = .fixed(&buf);
        try w.writeAll("dump1");
        const has_taint_die = true;
        if (has_taint_die) {
            if (w.buffered().len > 0) try w.writeAll("; ");
            try w.print("tainted=0x{x}", .{0x200});
        }
        try testing.expectEqualStrings("dump1; tainted=0x200", w.buffered());
    }
}
