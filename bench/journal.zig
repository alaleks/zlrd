//! Throughput benchmark for the native journal reader.
//!
//! Builds a synthetic `.journal` shaped like a real one — a stable set of
//! deduplicated fields per unit plus a few unique fields per entry, and an
//! entry-array chain that grows the way journald's does — then iterates it
//! under the configurations the agent actually uses.
//!
//! Run with `zig build bench`.

const std = @import("std");
const jr = @import("journal");
const fmt = jr.format;

const n_entries: usize = 200_000;
const n_units: usize = 8;
const stable_per_unit: usize = 22;

const stable_keys = [stable_per_unit][]const u8{
    "_SYSTEMD_UNIT",   "_HOSTNAME",         "_TRANSPORT",     "_UID",
    "_GID",            "_COMM",             "_EXE",           "_CMDLINE",
    "_CAP_EFFECTIVE",  "_SELINUX_CONTEXT",  "_AUDIT_SESSION", "_AUDIT_LOGINUID",
    "_SYSTEMD_CGROUP", "_SYSTEMD_SLICE",    "_BOOT_ID",       "_MACHINE_ID",
    "SYSLOG_FACILITY", "SYSLOG_IDENTIFIER", "PRIORITY",       "_SYSTEMD_INVOCATION_ID",
    "_STREAM_ID",      "_LINE_BREAK",
};

const Builder = struct {
    b: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator,

    fn pad(self: *Builder) !void {
        while (self.b.items.len % 8 != 0) try self.b.append(self.a, 0);
    }
    fn header(self: *Builder) !void {
        var h: fmt.Header = std.mem.zeroes(fmt.Header);
        h.signature = fmt.signature_magic;
        h.header_size = @sizeOf(fmt.Header);
        try self.b.appendSlice(self.a, std.mem.asBytes(&h));
    }
    /// `n_refs` mirrors the reference count journald keeps on a data object;
    /// the reader's cache admission reads it.
    fn data(self: *Builder, payload: []const u8, n_refs: u64) !u64 {
        try self.pad();
        const off = self.b.items.len;
        var dh: fmt.DataHead = std.mem.zeroes(fmt.DataHead);
        dh.object.type = @intFromEnum(fmt.ObjectType.data);
        dh.object.size = @sizeOf(fmt.DataHead) + payload.len;
        dh.n_entries = n_refs;
        try self.b.appendSlice(self.a, std.mem.asBytes(&dh));
        try self.b.appendSlice(self.a, payload);
        return @intCast(off);
    }
    fn entry(self: *Builder, seq: u64, items: []const u64) !u64 {
        try self.pad();
        const off = self.b.items.len;
        var eh: fmt.EntryHead = std.mem.zeroes(fmt.EntryHead);
        eh.object.type = @intFromEnum(fmt.ObjectType.entry);
        eh.object.size = @sizeOf(fmt.EntryHead) + @sizeOf(fmt.EntryItem) * items.len;
        eh.seqnum = seq;
        eh.realtime = 1_700_000_000_000_000 + seq * 1000;
        try self.b.appendSlice(self.a, std.mem.asBytes(&eh));
        for (items) |d| {
            const it: fmt.EntryItem = .{ .object_offset = d, .hash = 0 };
            try self.b.appendSlice(self.a, std.mem.asBytes(&it));
        }
        return @intCast(off);
    }
    fn array(self: *Builder, entries: []const u64, cap: usize) !u64 {
        try self.pad();
        const off = self.b.items.len;
        var ah: fmt.EntryArrayHead = std.mem.zeroes(fmt.EntryArrayHead);
        ah.object.type = @intFromEnum(fmt.ObjectType.entry_array);
        ah.object.size = @sizeOf(fmt.EntryArrayHead) + 8 * cap;
        try self.b.appendSlice(self.a, std.mem.asBytes(&ah));
        for (entries) |e| try self.b.appendSlice(self.a, &@as([8]u8, @bitCast(e)));
        for (entries.len..cap) |_| try self.b.appendSlice(self.a, &[_]u8{0} ** 8);
        return @intCast(off);
    }
};

fn buildFixture(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !usize {
    var bd = Builder{ .a = gpa };
    defer bd.b.deinit(gpa);
    try bd.header();

    var stable: [n_units][stable_per_unit]u64 = undefined;
    var kb: [96]u8 = undefined;
    for (0..n_units) |u| {
        for (0..stable_per_unit) |k| {
            const p = try std.fmt.bufPrint(&kb, "{s}=svc{d}-value-{d}", .{ stable_keys[k], u, k });
            stable[u][k] = try bd.data(p, n_entries / n_units);
        }
    }

    const entry_offsets = try gpa.alloc(u64, n_entries);
    defer gpa.free(entry_offsets);
    var mb: [256]u8 = undefined;
    for (0..n_entries) |i| {
        var items: [stable_per_unit + 3]u64 = undefined;
        @memcpy(items[0..stable_per_unit], &stable[i % n_units]);
        items[stable_per_unit] = try bd.data(try std.fmt.bufPrint(&mb, "MESSAGE=request {d} handled for tenant {d} in {d}ms", .{ i, i % 977, i % 250 }), 1);
        items[stable_per_unit + 1] = try bd.data(try std.fmt.bufPrint(&mb, "_PID={d}", .{1000 + i % 64}), 1);
        items[stable_per_unit + 2] = try bd.data(try std.fmt.bufPrint(&mb, "_SOURCE_REALTIME_TIMESTAMP={d}", .{1_700_000_000_000_000 + i * 997}), 1);
        entry_offsets[i] = try bd.entry(i + 1, &items);
    }

    // journald grows each entry array until it caps out; mirror that so the
    // chain-walking cost is representative.
    var heads: std.ArrayList(u64) = .empty;
    defer heads.deinit(gpa);
    var pos: usize = 0;
    var cap: usize = 4;
    while (pos < n_entries) {
        const take = @min(cap, n_entries - pos);
        try heads.append(gpa, try bd.array(entry_offsets[pos..][0..take], cap));
        pos += take;
        if (cap < 8192) cap *= 2;
    }
    for (0..heads.items.len - 1) |i| {
        const h: *fmt.EntryArrayHead = @ptrCast(@alignCast(bd.b.items[@intCast(heads.items[i])..].ptr));
        h.next_entry_array_offset = heads.items[i + 1];
    }
    const hp: *fmt.Header = @ptrCast(@alignCast(bd.b.items.ptr));
    hp.entry_array_offset = heads.items[0];
    hp.n_entries = n_entries;

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bd.b.items });
    return bd.b.items.len;
}

fn now() f64 {
    return @as(f64, @floatFromInt(std.Io.Timestamp.now(std.Options.debug_io, .awake).nanoseconds)) / 1e9;
}

/// Wraps an allocator to count how many times the reader reaches for memory.
const Counting = struct {
    child: std.mem.Allocator,
    allocs: usize = 0,
    bytes: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        self.bytes += len;
        return self.child.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, b: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(b, a, n, ra);
    }
    fn remap(ctx: *anyopaque, b: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        return self.child.rawRemap(b, a, n, ra);
    }
    fn free(ctx: *anyopaque, b: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.rawFree(b, a, ra);
    }
};

const Config = struct {
    label: []const u8,
    cache: bool,
    reuse_arena: bool,
    /// Mirrors what the agent asks for: five fields out of the twenty-five
    /// a journald entry carries.
    filter: bool = false,
};

const agent_fields = [_][]const u8{
    "MESSAGE", "_SYSTEMD_UNIT", "SYSLOG_IDENTIFIER", "PRIORITY", "_PID",
};

fn run(gpa: std.mem.Allocator, io: std.Io, path: []const u8, cfg: Config) !void {
    var best_ms: f64 = std.math.floatMax(f64);
    var best_allocs: usize = 0;
    var best_bytes: usize = 0;
    var count: usize = 0;

    for (0..3) |_| {
        var r = try jr.Reader.open(io, std.Io.Dir.cwd(), path);
        defer r.deinit();
        var it = r.iterator();
        if (cfg.cache) try it.enableCache(gpa);
        defer if (cfg.cache) it.disableCache(gpa);
        if (cfg.filter) it.setFieldFilter(&agent_fields);

        var counting = Counting{ .child = gpa };
        var scratch = std.heap.ArenaAllocator.init(counting.allocator());
        defer scratch.deinit();
        const alloc = if (cfg.reuse_arena) scratch.allocator() else counting.allocator();

        const t0 = now();
        var n: usize = 0;
        var sink: usize = 0;
        while (true) {
            if (cfg.reuse_arena) _ = scratch.reset(.retain_capacity);
            const e = try it.next(alloc) orelse break;
            var entry = e;
            defer entry.deinit();
            // What the agent does with each entry.
            if (entry.get("MESSAGE")) |m| sink += m.len;
            _ = entry.get("_SYSTEMD_UNIT");
            _ = entry.get("PRIORITY");
            n += 1;
        }
        std.mem.doNotOptimizeAway(&sink);
        const ms = (now() - t0) * 1000;
        if (ms < best_ms) {
            best_ms = ms;
            best_allocs = counting.allocs;
            best_bytes = counting.bytes;
        }
        count = n;
    }

    const per_s = @as(f64, @floatFromInt(count)) / (best_ms / 1000);
    std.debug.print("{s:<30} {d:7.0} ms  {d:9.0} entries/s  {d:5.2} allocs/entry  {d:6.1} MB\n", .{
        cfg.label,                                                             best_ms,                                         per_s,
        @as(f64, @floatFromInt(best_allocs)) / @as(f64, @floatFromInt(count)), @as(f64, @floatFromInt(best_bytes)) / 1048576.0,
    });
}

pub fn main() !void {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const gpa = da.allocator();
    const io = std.Options.debug_io;

    const path = "zlrd-bench.journal.tmp";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const size = try buildFixture(gpa, io, path);
    std.debug.print("\njournal fixture: {d} entries x {d} fields, {d:.1} MB\n\n", .{
        n_entries, stable_per_unit + 3, @as(f64, @floatFromInt(size)) / 1048576.0,
    });

    try run(gpa, io, path, .{ .label = "no cache, fresh arena", .cache = false, .reuse_arena = false });
    try run(gpa, io, path, .{ .label = "cache, fresh arena", .cache = true, .reuse_arena = false });
    try run(gpa, io, path, .{ .label = "cache + reused arena", .cache = true, .reuse_arena = true });
    try run(gpa, io, path, .{ .label = "  + field filter (agent)", .cache = true, .reuse_arena = true, .filter = true });
    std.debug.print("\n", .{});
}
