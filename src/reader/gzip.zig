//! Streaming gzip decompressor for log reading.
//! Wraps std.compress.flate.Decompress with a line-oriented read loop
//! compatible with the rest of the reader pipeline.

const std = @import("std");
const simd = @import("simd.zig");

/// Returns true if `path` has a `.gz` extension.
pub fn isGzip(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".gz");
}

/// Decompresses a gzip log file and feeds each line through `filter_state`.
/// Drop-in replacement for `readContinuous` for .gz files.
///
/// Pagination (`-n`) is not supported — gzip streams are not randomly seekable,
/// so the file is always read in full.
pub fn readGzip(
    allocator: std.mem.Allocator,
    path: []const u8,
    filter_state: anytype,
) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // In Zig 0.15.2, file.reader() requires an explicit scratch buffer and
    // returns fs.File.Reader, not *std.Io.Reader. Decompress.init requires
    // *std.Io.Reader, so we pass &file_reader.interface.
    var file_buf: [4096]u8 = undefined;
    var file_reader = file.reader(&file_buf);

    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(
        &file_reader.interface,
        .gzip,
        &decompress_buf,
    );
    const decompress_reader = &decompress.reader;

    // Carry buffer for incomplete lines that span chunk boundaries.
    var carry = try std.ArrayList(u8).initCapacity(allocator, 4096);
    defer carry.deinit(allocator);

    const chunk_size = 64 * 1024;
    const chunk = try allocator.alloc(u8, chunk_size);
    defer allocator.free(chunk);

    while (true) {
        // readSliceShort returns error{ReadFailed} only — no EndOfStream.
        // EOF is indicated by n == 0.
        const n = try decompress_reader.readSliceShort(chunk);
        if (n == 0) break;

        var slice = chunk[0..n];

        var combined: ?[]u8 = null;
        defer if (combined) |c| allocator.free(c);

        if (carry.items.len > 0) {
            try carry.appendSlice(allocator, slice);
            combined = try allocator.dupe(u8, carry.items);
            carry.clearRetainingCapacity();
            slice = combined.?;
        }

        var start: usize = 0;
        while (simd.findByte(slice, start, '\n')) |nl| {
            if (nl > start) filter_state.printIfMatch(slice[start..nl]);
            start = nl + 1;
        }

        if (start < slice.len) {
            try carry.appendSlice(allocator, slice[start..]);
        }
    }

    // Flush final line with no trailing newline.
    if (carry.items.len > 0) {
        filter_state.printIfMatch(carry.items);
    }
}
