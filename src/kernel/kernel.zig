//! Kernel-level event monitoring for the agent: OOM kills, segfaults, and
//! prior-boot panic reconciliation. The package exposes a single `Monitor`
//! type with a uniform interface; backends are platform-conditional.
//!
//! Backends, in order of accuracy:
//!   - `ebpf`   — gated behind `-Dwith-ebpf=true`. Tracepoint-based, exact.
//!                Requires Linux ≥5.8 + CAP_BPF + CAP_PERFMON.
//!   - `kmsg`   — Linux baseline. Reads /dev/kmsg and matches kernel messages.
//!                Detects OOM-kills universally and segfaults when
//!                `kernel.print-fatal-signals=1` is enabled.
//!   - `pstore` — Linux baseline. One-shot at startup: detects prior-boot
//!                kernel panic via /sys/fs/pstore + /proc/sys/kernel/tainted.
//!
//! On macOS, Windows, and other non-Linux platforms the monitor compiles to
//! a no-op so the agent stays portable.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const log = std.log.scoped(.zlrd_kernel);

pub const is_supported = builtin.os.tag == .linux;
pub const with_ebpf = is_supported and build_options.with_ebpf;

pub const comm_max = 16; // matches TASK_COMM_LEN in the Linux kernel

/// A single kernel-level event. Fixed-size: no heap pointers, safe to copy.
pub const KernelEvent = struct {
    kind: Kind,
    /// Process ID associated with the event, when applicable.
    pid: u32,
    /// Process command name. Truncated/padded to `comm_max` bytes; `comm_len`
    /// gives the actual length.
    comm: [comm_max]u8,
    comm_len: u8,
    /// Free-form detail string (kept ≤ 128 bytes so we don't blow up payloads).
    /// For OOM: the kernel message snippet. For segfault: the address. For
    /// panic_prev_boot: the pstore dump name.
    detail: [128]u8,
    detail_len: u8,
    /// Backend that produced this event — used for diagnostics & metrics.
    source: Source,

    pub const Kind = enum {
        oom,
        segfault,
        panic_prev_boot,

        pub fn label(self: Kind) []const u8 {
            return switch (self) {
                .oom => "kernel_oom",
                .segfault => "kernel_segfault",
                .panic_prev_boot => "kernel_panic",
            };
        }
    };

    pub const Source = enum {
        kmsg,
        pstore,
        ebpf,

        pub fn label(self: Source) []const u8 {
            return switch (self) {
                .kmsg => "kmsg",
                .pstore => "pstore",
                .ebpf => "ebpf",
            };
        }
    };

    pub fn commSlice(self: *const KernelEvent) []const u8 {
        return self.comm[0..self.comm_len];
    }

    pub fn detailSlice(self: *const KernelEvent) []const u8 {
        return self.detail[0..self.detail_len];
    }
};

/// Constructs a KernelEvent with stack-only data — never allocates.
pub fn makeEvent(kind: KernelEvent.Kind, source: KernelEvent.Source, pid: u32, comm: []const u8, detail: []const u8) KernelEvent {
    var ev: KernelEvent = .{
        .kind = kind,
        .pid = pid,
        .comm = std.mem.zeroes([comm_max]u8),
        .comm_len = 0,
        .detail = std.mem.zeroes([128]u8),
        .detail_len = 0,
        .source = source,
    };
    const comm_n = @min(comm.len, comm_max);
    @memcpy(ev.comm[0..comm_n], comm[0..comm_n]);
    ev.comm_len = @intCast(comm_n);
    const detail_n = @min(detail.len, ev.detail.len);
    @memcpy(ev.detail[0..detail_n], detail[0..detail_n]);
    ev.detail_len = @intCast(detail_n);
    return ev;
}

/// Sink callback fired by backends for each detected event. `ctx` is whatever
/// the caller passed to `Monitor.init`. The callback is invoked from the
/// monitor's own thread — implementations must be thread-safe.
pub const Sink = *const fn (ctx: ?*anyopaque, event: KernelEvent) void;

/// Background kernel-event monitor. Owns one OS thread per active backend.
pub const Monitor = struct {
    /// One thread slot per concurrently-running background backend. Today:
    /// kmsg (always) + eBPF (gated by `with_ebpf`). Pstore is synchronous
    /// at startup and doesn't need a slot.
    pub const max_threads = 2;

    io: std.Io,
    sink: Sink,
    ctx: ?*anyopaque,
    stop_flag: std.atomic.Value(bool),
    threads: [max_threads]?std.Thread,
    threads_len: usize,

    pub fn init(io: std.Io, sink: Sink, ctx: ?*anyopaque) Monitor {
        return .{
            .io = io,
            .sink = sink,
            .ctx = ctx,
            .stop_flag = .init(false),
            .threads = [_]?std.Thread{null} ** max_threads,
            .threads_len = 0,
        };
    }

    pub fn start(self: *Monitor) !void {
        if (comptime !is_supported) {
            log.info("kernel probes: unsupported on this platform, monitor is a no-op", .{});
            return;
        }
        try linuxStart(self);
    }

    pub fn stop(self: *Monitor) void {
        self.stop_flag.store(true, .monotonic);
    }

    pub fn join(self: *Monitor) void {
        for (self.threads[0..self.threads_len]) |t| {
            if (t) |th| th.join();
        }
        self.threads_len = 0;
    }
};

fn linuxStart(self: *Monitor) !void {
    if (comptime !is_supported) return;
    const pstore = @import("pstore.zig");

    // Pstore is a one-shot reconciliation — run synchronously on the calling
    // thread before any background backends fire so the panic event (if any)
    // is delivered first.
    pstore.scan(self.io, self.sink, self.ctx) catch |err| {
        log.warn("pstore scan failed: {t}", .{err});
    };

    // kmsg backend lives in its own thread so the watcher loop is unaffected.
    // A kmsg-spawn failure used to short-circuit the function and silently
    // disable eBPF too — fall through instead so each backend stands on its
    // own.
    if (std.Thread.spawn(.{}, kmsgThread, .{ self, &self.stop_flag })) |th| {
        self.threads[self.threads_len] = th;
        self.threads_len += 1;
    } else |err| {
        log.warn("failed to spawn kmsg thread: {t}", .{err});
    }

    if (comptime with_ebpf) {
        if (std.Thread.spawn(.{}, ebpfThread, .{ self, &self.stop_flag })) |th| {
            self.threads[self.threads_len] = th;
            self.threads_len += 1;
        } else |err| {
            log.warn("failed to spawn ebpf thread: {t}", .{err});
        }
    }
}

fn kmsgThread(self: *Monitor, stop: *std.atomic.Value(bool)) void {
    if (comptime !is_supported) return;
    const kmsg = @import("kmsg.zig");
    kmsg.run(self.io, self.sink, self.ctx, stop) catch |err| {
        log.warn("kmsg backend exited: {t}", .{err});
    };
}

fn ebpfThread(self: *Monitor, stop: *std.atomic.Value(bool)) void {
    if (comptime !with_ebpf) return;
    const ebpf = @import("ebpf.zig");
    ebpf.run(self.io, self.sink, self.ctx, stop) catch |err| {
        log.warn("ebpf backend exited: {t}", .{err});
    };
}

/// Renders a KernelEvent as a single-line JSON document into `buf`. Used by
/// the alert dispatcher to embed kernel events into the standard alert
/// payload schema.
pub fn formatEventJson(buf: []u8, event: KernelEvent, now_ms: i64) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeByte('{');
    try w.print("\"ts_ms\":{d}", .{now_ms});
    try w.print(",\"kind\":\"{s}\"", .{event.kind.label()});
    try w.print(",\"source\":\"{s}\"", .{event.source.label()});
    try w.print(",\"pid\":{d}", .{event.pid});
    if (event.comm_len > 0) {
        try w.writeAll(",\"comm\":");
        try writeJsonString(&w, event.commSlice());
    }
    if (event.detail_len > 0) {
        try w.writeAll(",\"detail\":");
        try writeJsonString(&w, event.detailSlice());
    }
    try w.writeByte('}');
    return w.buffered();
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            // ASCII printable, excluding `"` (0x22) and `\\` (0x5c) which
            // are handled above as explicit escape arms.
            0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try w.writeByte(c),
            // Everything else: remaining controls, DEL, and high bytes.
            // Kernel `task->comm` / kmsg messages are nominally ASCII, but
            // corrupted input or module names with odd encodings can leak
            // high bytes. Emit them as `\uXX` so the output stays valid
            // JSON regardless.
            else => try w.print("\\u{x:0>4}", .{c}),
        }
    }
    try w.writeByte('"');
}

const testing = std.testing;

test "makeEvent: truncates comm and detail to fixed buffers" {
    const ev = makeEvent(.oom, .kmsg, 1234, "abcdefghijklmnopqrstuvwxyz", "x" ** 200);
    try testing.expectEqual(@as(u8, 16), ev.comm_len);
    try testing.expectEqualStrings("abcdefghijklmnop", ev.commSlice());
    try testing.expectEqual(@as(u8, 128), ev.detail_len);
}

test "formatEventJson: renders parseable JSON with expected fields" {
    var buf: [512]u8 = undefined;
    const ev = makeEvent(.oom, .kmsg, 42, "myproc", "Killed by OOM");
    const out = try formatEventJson(&buf, ev, 1_700_000_000_000);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("kernel_oom", obj.get("kind").?.string);
    try testing.expectEqualStrings("kmsg", obj.get("source").?.string);
    try testing.expectEqual(@as(i64, 42), obj.get("pid").?.integer);
    try testing.expectEqualStrings("myproc", obj.get("comm").?.string);
    try testing.expectEqualStrings("Killed by OOM", obj.get("detail").?.string);
}

test "formatEventJson: empty comm/detail are omitted" {
    var buf: [256]u8 = undefined;
    const ev = makeEvent(.panic_prev_boot, .pstore, 0, "", "");
    const out = try formatEventJson(&buf, ev, 0);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    try testing.expect(!parsed.value.object.contains("comm"));
    try testing.expect(!parsed.value.object.contains("detail"));
}

test "Kind.label: stable wire names" {
    try testing.expectEqualStrings("kernel_oom", KernelEvent.Kind.oom.label());
    try testing.expectEqualStrings("kernel_segfault", KernelEvent.Kind.segfault.label());
    try testing.expectEqualStrings("kernel_panic", KernelEvent.Kind.panic_prev_boot.label());
}

test "writeJsonString: escapes \\b and \\f shortforms" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeJsonString(&w, "\x08\x0c");
    try testing.expectEqualStrings("\"\\b\\f\"", w.buffered());
}

test "writeJsonString: escapes DEL and high bytes as \\uXX" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeJsonString(&w, "\x7f\xc3\xa9");
    try testing.expectEqualStrings("\"\\u007f\\u00c3\\u00a9\"", w.buffered());
}

test "writeJsonString: preserves printable ASCII including '!' and '~'" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeJsonString(&w, "hello !~");
    try testing.expectEqualStrings("\"hello !~\"", w.buffered());
}
