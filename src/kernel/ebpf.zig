//! eBPF backend: tracepoint-based kernel-event probes for the most accurate
//! signal we can get from userspace. Currently implements `oom:mark_victim`;
//! `signal:signal_generate` (segfault filter) is structured-in as a TODO and
//! will land in a follow-up iteration since both share the same loader.
//!
//! Gated behind `-Dwith-ebpf=true`. Requires:
//!   - Linux ≥ 5.8 (BPF ringbuf)
//!   - `CAP_BPF` + `CAP_PERFMON` (or root)
//!   - tracefs mounted at `/sys/kernel/tracing` (the common default)
//!
//! Allocation policy: one fixed-size mmap region for the ringbuf data pages;
//! no per-event allocation. Events read via zero-copy reads off the mmap'd
//! data area into a stack-only `KernelEvent` value.
//!
//! Runtime testing note: this backend is compile-verified against Zig
//! 0.16's `std.os.linux.BPF` helpers, but loading + attach require a real
//! Linux kernel and were not exercised from this build host. Failures during
//! setup degrade gracefully — the kmsg backend stays active.

const std = @import("std");
const builtin = @import("builtin");

const kernel = @import("kernel.zig");

const log = std.log.scoped(.zlrd_ebpf);

const tracefs_root = "/sys/kernel/tracing";

/// Size of the ringbuf data area. Must be a power of two and a multiple of
/// the system page size. 256 KiB is enough headroom for OOM events
/// (each is 4 bytes after the 8-byte header).
const ringbuf_size: usize = 256 * 1024;

pub fn run(
    io: std.Io,
    sink: kernel.Sink,
    ctx: ?*anyopaque,
    stop: *std.atomic.Value(bool),
) !void {
    _ = io;
    if (comptime !kernel.with_ebpf or builtin.os.tag != .linux) return;
    return runLinux(sink, ctx, stop);
}

/// Reasonable upper bound on number of CPUs we attach to. 1024 covers any
/// machine zlrd realistically runs on; the array sits in the function frame
/// (4 KiB) so we avoid an allocator dependency for startup.
const max_cpus: usize = 1024;

fn runLinux(sink: kernel.Sink, ctx: ?*anyopaque, stop: *std.atomic.Value(bool)) !void {
    if (comptime builtin.os.tag != .linux) return;

    const linux = std.os.linux;
    const BPF = linux.BPF;

    // 1. Create a ringbuf map for event delivery.
    const map_fd = BPF.map_create(.ringbuf, 0, 0, @intCast(ringbuf_size)) catch |err| {
        log.warn("ringbuf map_create failed: {t} (kernel ≥5.8 + CAP_BPF required)", .{err});
        return;
    };
    defer _ = linux.close(map_fd);

    // 2. Load the OOM tracepoint program.
    const oom_prog_fd = loadOomProgram(map_fd) catch |err| {
        log.warn("OOM program load failed: {t}", .{err});
        return;
    };
    defer _ = linux.close(oom_prog_fd);

    // 3. Resolve the tracepoint id and attach via perf_event_open.
    const tp_id = readTracepointId("oom", "mark_victim") catch |err| {
        log.warn("tracepoint id read failed: {t}", .{err});
        return;
    };

    // Tracepoint perf events are per-CPU: pid=-1 requires cpu>=0, and an fd
    // attached to cpu N only catches the tracepoint when it fires on cpu N.
    // We open one perf event per online CPU, attach the BPF program to each,
    // and close them all on exit. Without this we'd miss OOM events that fire
    // on every CPU but the first one.
    const nr_cpus = std.Thread.getCpuCount() catch 1;
    const cpus = @min(nr_cpus, max_cpus);
    var perf_fds: [max_cpus]i32 = undefined;
    var attached: usize = 0;
    defer {
        var i: usize = 0;
        while (i < attached) : (i += 1) _ = linux.close(perf_fds[i]);
    }

    for (0..cpus) |cpu| {
        const fd = openTracepoint(tp_id, @intCast(cpu)) catch continue;
        setBpfAndEnable(fd, oom_prog_fd) catch {
            _ = linux.close(fd);
            continue;
        };
        perf_fds[attached] = fd;
        attached += 1;
    }
    if (attached == 0) {
        log.warn("ebpf: failed to attach OOM tracepoint on any CPU", .{});
        return;
    }

    // 4. mmap the ringbuf consumer page + data area, run the consumer loop.
    var consumer = RingbufConsumer.init(map_fd) catch |err| {
        log.warn("ringbuf mmap failed: {t}", .{err});
        return;
    };
    defer consumer.deinit();

    log.info("ebpf backend up; OOM tracepoint attached on {d} CPU(s)", .{attached});

    var pollfd = [_]std.posix.pollfd{.{
        .fd = map_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    while (!stop.load(.monotonic)) {
        const pn = linux.poll(&pollfd, 1, 500);
        switch (std.posix.errno(pn)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return,
        }
        if (pn == 0) continue;
        consumer.drain(sink, ctx);
    }
}

/// Builds the BPF program that runs on `oom:mark_victim`. Reads the victim
/// pid from the tracepoint context (offset 8 in the standard layout) and
/// writes a 4-byte record to the ringbuf.
///
/// Licensed as GPL: `bpf_ringbuf_output` is marked `gpl_only` in upstream
/// kernels, so loading with `MIT` (or any non-GPL string) fails immediately
/// with `EACCES` at `BPF_PROG_LOAD`. Tracepoint programs are GPL-only too.
fn loadOomProgram(ringbuf_map_fd: i32) !i32 {
    if (comptime builtin.os.tag != .linux) return error.Unsupported;
    const linux = std.os.linux;
    const BPF = linux.BPF;
    const Insn = BPF.Insn;

    const insns = [_]Insn{
        // r2 = *(u32 *)(r1 + 8)            ; pid from ctx
        Insn.ldx(.word, .r2, .r1, 8),
        // *(u32 *)(r10 - 4) = r2           ; stash pid on stack
        Insn.stx(.word, .r10, -4, .r2),
        // r1 = map_fd (ld_imm64 in two slots)
        Insn.ld_map_fd1(.r1, ringbuf_map_fd),
        Insn.ld_map_fd2(ringbuf_map_fd),
        // r2 = r10
        Insn.mov(.r2, .r10),
        // r2 += -4                         ; r2 points at the stashed pid
        Insn.add(.r2, -4),
        // r3 = 4                           ; record size in bytes
        Insn.mov(.r3, 4),
        // r4 = 0                           ; flags
        Insn.mov(.r4, 0),
        // call bpf_ringbuf_output(map, data, size, flags)
        Insn.call(.ringbuf_output),
        // r0 = 0                           ; tracepoint progs must return 0
        Insn.mov(.r0, 0),
        Insn.exit(),
    };

    return BPF.prog_load(.tracepoint, &insns, null, "GPL", 0, 0);
}

/// Resolves the kernel-assigned numeric id for a tracepoint by reading
/// `/sys/kernel/tracing/events/<category>/<name>/id`.
fn readTracepointId(category: []const u8, name: []const u8) !u64 {
    if (comptime builtin.os.tag != .linux) return error.Unsupported;
    const linux = std.os.linux;

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/events/{s}/{s}/id\x00", .{
        tracefs_root,
        category,
        name,
    });
    const path_sentinel: [*:0]const u8 = @ptrCast(path.ptr);

    const flags: linux.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true };
    const fd_rc = linux.openat(linux.AT.FDCWD, path_sentinel, flags, 0);
    if (std.posix.errno(fd_rc) != .SUCCESS) return error.TracepointMissing;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);

    var num_buf: [32]u8 = undefined;
    const n = linux.read(fd, &num_buf, num_buf.len);
    if (std.posix.errno(n) != .SUCCESS) return error.ReadFailed;
    const trimmed = std.mem.trim(u8, num_buf[0..n], " \t\n\r");
    return std.fmt.parseInt(u64, trimmed, 10) catch return error.InvalidId;
}

/// Opens a perf event for the given tracepoint id on a specific CPU.
/// pid=-1 + cpu>=0 → all tasks on that CPU. One fd per online CPU is
/// required because tracepoint perf events are per-CPU instruments.
fn openTracepoint(tracepoint_id: u64, cpu: i32) !i32 {
    if (comptime builtin.os.tag != .linux) return error.Unsupported;
    const linux = std.os.linux;

    var attr = std.mem.zeroes(linux.perf_event_attr);
    attr.type = .TRACEPOINT;
    attr.size = @sizeOf(linux.perf_event_attr);
    attr.config = tracepoint_id;
    attr.sample_period_or_freq = 1;
    attr.flags.disabled = true;
    attr.wakeup = .{ .events = 1 };

    const rc = linux.perf_event_open(&attr, -1, cpu, -1, 0);
    if (std.posix.errno(rc) != .SUCCESS) return error.PerfEventOpen;
    return @intCast(rc);
}

const PERF_EVENT_IOC_ENABLE: u32 = 0x2400;
const PERF_EVENT_IOC_SET_BPF: u32 = 0x40042408;

fn setBpfAndEnable(perf_fd: i32, prog_fd: i32) !void {
    if (comptime builtin.os.tag != .linux) return error.Unsupported;
    const linux = std.os.linux;

    const set_rc = linux.ioctl(perf_fd, PERF_EVENT_IOC_SET_BPF, @as(usize, @intCast(prog_fd)));
    if (std.posix.errno(set_rc) != .SUCCESS) return error.IoctlSetBpf;

    const en_rc = linux.ioctl(perf_fd, PERF_EVENT_IOC_ENABLE, 0);
    if (std.posix.errno(en_rc) != .SUCCESS) return error.IoctlEnable;
}

/// Consumer of a BPF ringbuf map. Holds the two mmap'd regions and the
/// current consumer position. Reads are zero-copy.
const RingbufConsumer = struct {
    consumer_page: []align(std.heap.page_size_min) u8,
    producer_pages: []align(std.heap.page_size_min) u8,
    data: []u8,

    fn init(map_fd: i32) !RingbufConsumer {
        if (comptime builtin.os.tag != .linux) return error.Unsupported;
        const linux = std.os.linux;
        const page = std.heap.pageSize();

        const consumer_addr = linux.mmap(
            null,
            page,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            map_fd,
            0,
        );
        if (std.posix.errno(consumer_addr) != .SUCCESS) return error.MmapConsumer;
        const consumer_ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(consumer_addr);
        errdefer _ = linux.munmap(consumer_ptr, page);

        // Producer page + data area (data is mapped twice contiguously to
        // simplify wrap-around handling).
        const producer_len = page + 2 * ringbuf_size;
        const producer_addr = linux.mmap(
            null,
            producer_len,
            .{ .READ = true },
            .{ .TYPE = .SHARED },
            map_fd,
            @intCast(page),
        );
        if (std.posix.errno(producer_addr) != .SUCCESS) return error.MmapProducer;
        const producer_ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(producer_addr);

        const data_ptr = producer_ptr + page;
        return .{
            .consumer_page = consumer_ptr[0..page],
            .producer_pages = producer_ptr[0..producer_len],
            .data = data_ptr[0..ringbuf_size],
        };
    }

    fn deinit(self: *RingbufConsumer) void {
        if (comptime builtin.os.tag != .linux) return;
        const linux = std.os.linux;
        _ = linux.munmap(@ptrCast(self.consumer_page.ptr), self.consumer_page.len);
        _ = linux.munmap(@ptrCast(self.producer_pages.ptr), self.producer_pages.len);
        self.* = undefined;
    }

    fn consumerPos(self: *RingbufConsumer) *std.atomic.Value(u64) {
        return @ptrCast(@alignCast(self.consumer_page.ptr));
    }

    fn producerPos(self: *RingbufConsumer) *std.atomic.Value(u64) {
        return @ptrCast(@alignCast(self.producer_pages.ptr));
    }

    /// Drains all currently-available records via the pure `drainBuffer`
    /// helper. The split makes the record-walking logic testable without
    /// having to mmap a real BPF ringbuf.
    fn drain(self: *RingbufConsumer, sink: kernel.Sink, ctx: ?*anyopaque) void {
        const consumer = self.consumerPos();
        const producer = self.producerPos();
        var cpos = consumer.load(.acquire);
        const ppos = producer.load(.acquire);
        const start = cpos;
        cpos = drainBuffer(self.data, cpos, ppos, sink, ctx);
        // Publish the new consumer position once at the end — on bursts this
        // collapses N atomic stores into one.
        if (cpos != start) consumer.store(cpos, .release);
    }
};

/// Walks BPF-ringbuf records in `data` from `cpos` toward `ppos`, calling
/// `sink` for each committed record. Honors the BUSY bit (stops there;
/// producer still writing) and the DISCARD bit (skips payload but still
/// advances past the record). Returns the new consumer position.
///
/// Without DISCARD handling, the previous implementation would wedge on
/// the first discarded record forever because `len_raw & 0x7FFFFFFF` left
/// bit 30 set, producing a ~1 GiB length that always failed the bounds
/// check.
fn drainBuffer(data: []const u8, cpos_in: u64, ppos: u64, sink: kernel.Sink, ctx: ?*anyopaque) u64 {
    const busy_bit: u32 = 0x80000000;
    const discard_bit: u32 = 0x40000000;
    const len_mask: u32 = 0x3FFFFFFF;
    const mask: u64 = data.len - 1;

    var cpos = cpos_in;
    while (cpos < ppos) {
        const off: usize = @intCast(cpos & mask);
        if (off + 8 > data.len) break;
        const hdr_ptr: *const [8]u8 = @ptrCast(&data[off]);
        const len_raw: u32 = std.mem.readInt(u32, hdr_ptr[0..4], .little);
        if ((len_raw & busy_bit) != 0) break;

        const discarded = (len_raw & discard_bit) != 0;
        const data_len: usize = @intCast(len_raw & len_mask);
        const data_off = off + 8;
        if (data_off + data_len > data.len) break;

        if (!discarded and data_len >= 4) {
            const pid_ptr: *const [4]u8 = @ptrCast(&data[data_off]);
            const pid: u32 = std.mem.readInt(u32, pid_ptr, .little);
            sink(ctx, kernel.makeEvent(.oom, .ebpf, pid, "", ""));
        }

        // Records are 8-byte aligned. Advance past header + padded payload.
        const padded = (data_len + 7) & ~@as(usize, 7);
        cpos += 8 + padded;
    }
    return cpos;
}

// ─── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Writes a synthetic BPF-ringbuf record header into `buf[off..]`.
/// `len` is the payload length; `discard` sets bit 30; `busy` sets bit 31.
fn writeRingbufRecord(buf: []u8, off: usize, payload: []const u8, discard: bool, busy: bool) usize {
    var len_raw: u32 = @intCast(payload.len);
    if (discard) len_raw |= 0x40000000;
    if (busy) len_raw |= 0x80000000;
    std.mem.writeInt(u32, buf[off..][0..4], len_raw, .little);
    std.mem.writeInt(u32, buf[off + 4 ..][0..4], 0, .little);
    @memcpy(buf[off + 8 ..][0..payload.len], payload);
    const padded = (payload.len + 7) & ~@as(usize, 7);
    return 8 + padded;
}

test "drainBuffer: emits committed records and advances cpos correctly" {
    var data: [256]u8 = undefined;
    @memset(&data, 0);

    var pid1_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &pid1_bytes, 1234, .little);
    var pid2_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &pid2_bytes, 5678, .little);

    const r1 = writeRingbufRecord(&data, 0, &pid1_bytes, false, false);
    const r2 = writeRingbufRecord(&data, r1, &pid2_bytes, false, false);

    const Cap = struct {
        var seen: [4]u32 = .{ 0, 0, 0, 0 };
        var n: usize = 0;
        fn cb(_: ?*anyopaque, ev: kernel.KernelEvent) void {
            seen[n] = ev.pid;
            n += 1;
        }
    };
    Cap.n = 0;
    const new_cpos = drainBuffer(&data, 0, r1 + r2, Cap.cb, null);
    try testing.expectEqual(@as(usize, 2), Cap.n);
    try testing.expectEqual(@as(u32, 1234), Cap.seen[0]);
    try testing.expectEqual(@as(u32, 5678), Cap.seen[1]);
    try testing.expectEqual(@as(u64, r1 + r2), new_cpos);
}

test "drainBuffer: DISCARDed record is skipped but advances cpos" {
    var data: [256]u8 = undefined;
    @memset(&data, 0);

    var pid_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &pid_bytes, 9999, .little);

    // First record is discarded (should be skipped); second is a normal
    // record whose pid must surface — proving cpos advanced past the
    // discarded one rather than wedging on it.
    const r1 = writeRingbufRecord(&data, 0, &pid_bytes, true, false);
    const r2 = writeRingbufRecord(&data, r1, &pid_bytes, false, false);

    const Cap = struct {
        var seen: [4]u32 = .{ 0, 0, 0, 0 };
        var n: usize = 0;
        fn cb(_: ?*anyopaque, ev: kernel.KernelEvent) void {
            seen[n] = ev.pid;
            n += 1;
        }
    };
    Cap.n = 0;
    const new_cpos = drainBuffer(&data, 0, r1 + r2, Cap.cb, null);
    try testing.expectEqual(@as(usize, 1), Cap.n);
    try testing.expectEqual(@as(u32, 9999), Cap.seen[0]);
    try testing.expectEqual(@as(u64, r1 + r2), new_cpos);
}

test "drainBuffer: stops at a BUSY record without advancing past it" {
    var data: [256]u8 = undefined;
    @memset(&data, 0);

    var pid_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &pid_bytes, 1, .little);

    // Producer is mid-write on this record — consumer must stop and resume
    // on a later drain (when BUSY clears).
    _ = writeRingbufRecord(&data, 0, &pid_bytes, false, true);

    const Cap = struct {
        var n: usize = 0;
        fn cb(_: ?*anyopaque, _: kernel.KernelEvent) void {
            n += 1;
        }
    };
    Cap.n = 0;
    const new_cpos = drainBuffer(&data, 0, 128, Cap.cb, null);
    try testing.expectEqual(@as(usize, 0), Cap.n);
    try testing.expectEqual(@as(u64, 0), new_cpos);
}
