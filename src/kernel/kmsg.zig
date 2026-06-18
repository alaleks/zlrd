//! `/dev/kmsg` backend: reads structured kernel ring buffer records and
//! matches OOM-kill and segfault patterns. Linux-only — on other platforms
//! `run` returns immediately.
//!
//! Allocation policy: a single 8 KiB stack buffer per read; pattern matchers
//! never allocate. Detection latency is bounded by the poll timeout
//! (`poll_timeout_ms`).
//!
//! Kmsg record format (see Documentation/ABI/testing/dev-kmsg):
//!   `<level>,<seq>,<timestamp_us>,<flag>;<message>\n[ key=value ...]`
//! Only the message after `;` is parsed; continuation kv-lines are ignored.

const std = @import("std");
const builtin = @import("builtin");

const kernel = @import("kernel.zig");

const log = std.log.scoped(.zlrd_kmsg);

/// `/dev/kmsg` returns one record per read. LOG_LINE_MAX is 1024 by default
/// but distro kernels often raise it; a max-length record plus KV postfix
/// can approach 16 KiB. Sizing the buffer to that means a single read
/// pulls the whole record even on the worst-case kernel build.
const read_buf_size = 16 * 1024;
const poll_timeout_ms: i32 = 500;
const kmsg_path = "/dev/kmsg";

pub fn run(
    io: std.Io,
    sink: kernel.Sink,
    ctx: ?*anyopaque,
    stop: *std.atomic.Value(bool),
) !void {
    _ = io;
    if (comptime builtin.os.tag != .linux) return;

    const linux = std.os.linux;

    const flags: linux.O = .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .CLOEXEC = true,
    };
    const open_rc = linux.openat(linux.AT.FDCWD, kmsg_path, flags, 0);
    switch (std.posix.errno(open_rc)) {
        .SUCCESS => {},
        .ACCES, .PERM => {
            log.warn("cannot open {s}: permission denied; kernel events disabled (run with CAP_SYSLOG or add user to 'adm' group)", .{kmsg_path});
            return;
        },
        .NOENT => {
            log.info("{s} not present; kernel events disabled", .{kmsg_path});
            return;
        },
        else => |e| {
            log.warn("openat({s}) failed: {s}", .{ kmsg_path, @tagName(e) });
            return;
        },
    }
    const fd: i32 = @intCast(open_rc);
    defer _ = linux.close(fd);

    // Seek to end so we don't replay historical messages on startup.
    _ = linux.lseek(fd, 0, std.posix.SEEK.END);

    var pollfd = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    var buf: [read_buf_size]u8 = undefined;

    while (!stop.load(.monotonic)) {
        const pn = linux.poll(&pollfd, 1, poll_timeout_ms);
        switch (std.posix.errno(pn)) {
            .SUCCESS => {},
            .INTR => continue,
            else => |e| {
                log.warn("poll failed: {s}", .{@tagName(e)});
                return;
            },
        }
        if (pn == 0) continue;

        while (true) {
            const n = linux.read(fd, &buf, buf.len);
            const errno = std.posix.errno(n);
            switch (errno) {
                .SUCCESS => {},
                .AGAIN => break,
                .PIPE => {
                    // We fell behind the ring buffer. Skip ahead.
                    log.debug("kmsg reader fell behind; resyncing", .{});
                    continue;
                },
                .INTR => continue,
                else => {
                    log.warn("read failed: {s}", .{@tagName(errno)});
                    return;
                },
            }
            if (n == 0) break;
            handleRecord(buf[0..n], sink, ctx);
        }
    }
}

/// Handles one kmsg record. Extracts the message after `;` and feeds it to
/// the pattern matchers.
fn handleRecord(record: []const u8, sink: kernel.Sink, ctx: ?*anyopaque) void {
    const message = extractMessage(record) orelse return;
    if (parseOomKilled(message)) |info| {
        sink(ctx, kernel.makeEvent(.oom, .kmsg, info.pid, info.comm, message));
        return;
    }
    if (parseSegfault(message)) |info| {
        sink(ctx, kernel.makeEvent(.segfault, .kmsg, info.pid, info.comm, message));
        return;
    }
    if (parseGeneralProtection(message)) {
        sink(ctx, kernel.makeEvent(.segfault, .kmsg, 0, "", message));
        return;
    }
}

/// Returns the message body of a kmsg record (the bytes between the first
/// `;` and the first `\n`). Returns null if the record is malformed.
pub fn extractMessage(record: []const u8) ?[]const u8 {
    const semi = std.mem.indexOfScalar(u8, record, ';') orelse return null;
    const start = semi + 1;
    if (start >= record.len) return null;
    const tail = record[start..];
    const newline_idx = std.mem.indexOfScalar(u8, tail, '\n') orelse tail.len;
    return tail[0..newline_idx];
}

pub const OomInfo = struct {
    pid: u32,
    comm: []const u8,
};

/// Matches the canonical OOM-killer line:
///   "Killed process <pid> (<comm>)..."
/// Returns null on no match. The `comm` slice borrows from the input.
pub fn parseOomKilled(msg: []const u8) ?OomInfo {
    const prefix = "Killed process ";
    if (!std.mem.startsWith(u8, msg, prefix)) return null;
    var rest = msg[prefix.len..];
    const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const pid = std.fmt.parseInt(u32, rest[0..space], 10) catch return null;
    rest = rest[space + 1 ..];
    if (rest.len == 0 or rest[0] != '(') return null;
    const close_paren = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
    return .{ .pid = pid, .comm = rest[1..close_paren] };
}

pub const SegInfo = struct {
    pid: u32,
    comm: []const u8,
};

/// Matches the `print-fatal-signals` segfault line:
///   "<comm>[<pid>]: segfault at <addr> ip ..."
/// Returns null on no match.
pub fn parseSegfault(msg: []const u8) ?SegInfo {
    const bracket = std.mem.indexOfScalar(u8, msg, '[') orelse return null;
    if (bracket == 0) return null;
    const close = std.mem.indexOfScalarPos(u8, msg, bracket + 1, ']') orelse return null;
    const tail = msg[close + 1 ..];
    if (!std.mem.startsWith(u8, tail, ": segfault at ")) return null;
    const pid = std.fmt.parseInt(u32, msg[bracket + 1 .. close], 10) catch return null;
    return .{ .pid = pid, .comm = msg[0..bracket] };
}

/// Matches the kernel-mode protection-fault line:
///   "general protection fault[, ...]"
/// These don't carry a pid in a stable position; we surface them anyway since
/// they almost always indicate a real crash.
pub fn parseGeneralProtection(msg: []const u8) bool {
    return std.mem.startsWith(u8, msg, "general protection fault");
}

const testing = std.testing;

test "extractMessage: returns text after first semicolon, before newline" {
    try testing.expectEqualStrings(
        "hello world",
        extractMessage("6,200,15000,-;hello world\n SUBSYSTEM=foo\n").?,
    );
    try testing.expectEqualStrings(
        "no kv",
        extractMessage("3,1,1,-;no kv").?,
    );
    try testing.expectEqual(@as(?[]const u8, null), extractMessage("no semicolon here"));
}

test "parseOomKilled: classic format" {
    const out = parseOomKilled("Killed process 1234 (nginx), UID 33, total-vm:...").?;
    try testing.expectEqual(@as(u32, 1234), out.pid);
    try testing.expectEqualStrings("nginx", out.comm);
}

test "parseOomKilled: comm with spaces and brackets" {
    const out = parseOomKilled("Killed process 99 (my proc), UID 0").?;
    try testing.expectEqual(@as(u32, 99), out.pid);
    try testing.expectEqualStrings("my proc", out.comm);
}

test "parseOomKilled: rejects non-matching lines" {
    try testing.expectEqual(@as(?OomInfo, null), parseOomKilled("oom-kill:constraint=..."));
    try testing.expectEqual(@as(?OomInfo, null), parseOomKilled("Killed process not_a_number (x)"));
    try testing.expectEqual(@as(?OomInfo, null), parseOomKilled("hello world"));
}

test "parseSegfault: standard print-fatal-signals format" {
    const out = parseSegfault("myapp[4242]: segfault at 0 ip 0000aabb sp ... error 4 in libc.so").?;
    try testing.expectEqual(@as(u32, 4242), out.pid);
    try testing.expectEqualStrings("myapp", out.comm);
}

test "parseSegfault: rejects unrelated bracketed input" {
    try testing.expectEqual(@as(?SegInfo, null), parseSegfault("[ERROR] something"));
    try testing.expectEqual(@as(?SegInfo, null), parseSegfault("nothing here"));
    try testing.expectEqual(@as(?SegInfo, null), parseSegfault("name[abc]: segfault at 0"));
}

test "parseGeneralProtection: matches prefix only" {
    try testing.expect(parseGeneralProtection("general protection fault, probably for non-canonical address 0xdead"));
    try testing.expect(!parseGeneralProtection("Killed process 1 (x)"));
}

test "handleRecord: dispatches OOM event to sink" {
    var captured: ?kernel.KernelEvent = null;
    const Cap = struct {
        fn cb(ctx: ?*anyopaque, event: kernel.KernelEvent) void {
            const slot: *?kernel.KernelEvent = @ptrCast(@alignCast(ctx.?));
            slot.* = event;
        }
    };
    handleRecord("4,17,100,-;Killed process 99 (proc1), UID 0\n", Cap.cb, &captured);
    try testing.expect(captured != null);
    try testing.expectEqual(kernel.KernelEvent.Kind.oom, captured.?.kind);
    try testing.expectEqual(@as(u32, 99), captured.?.pid);
    try testing.expectEqualStrings("proc1", captured.?.commSlice());
}

test "handleRecord: ignores unrelated lines" {
    var calls: u32 = 0;
    const Cap = struct {
        fn cb(ctx: ?*anyopaque, event: kernel.KernelEvent) void {
            _ = event;
            const slot: *u32 = @ptrCast(@alignCast(ctx.?));
            slot.* += 1;
        }
    };
    handleRecord("6,1,1,-;random kernel chatter\n", Cap.cb, &calls);
    try testing.expectEqual(@as(u32, 0), calls);
}
