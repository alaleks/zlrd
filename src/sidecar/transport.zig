//! OTLP/HTTP transport: POSTs a protobuf payload to an OTLP endpoint with
//! retry + exponential backoff. Built on `std.http.Client` so TLS is handled
//! by the standard library — no third-party deps.
//!
//! Policy:
//!   - URL must be https:// (TLS mandatory)
//!   - Caller supplies a base URL like `https://collector.example.com:4318`;
//!     `Transport.send` appends `/v1/logs` or `/v1/metrics`.
//!   - Payload is gzipped on the wire (Content-Encoding: gzip).
//!   - Retry on connection errors, 408, 429, and 5xx
//!   - Give up on other 4xx (caller misconfiguration)
//!   - Backoff: 100ms, 200ms, 400ms, 800ms (capped at 5s)
//!
//! Caveat — std.http.Client 0.16 has no per-request timeout. A wedged TLS
//! handshake or stalled collector can block `fetch` indefinitely; callers
//! should use `Sidecar`'s shutdown watchdog to recover.

const std = @import("std");

const log = std.log.scoped(.zlrd_sidecar);

pub const Signal = enum {
    logs,
    metrics,

    pub fn path(self: Signal) []const u8 {
        return switch (self) {
            .logs => "/v1/logs",
            .metrics => "/v1/metrics",
        };
    }
};

/// Outcome of a `Transport.send` call. The enum splits the previous bool
/// return so callers can distinguish transient infrastructure errors (worth
/// alerting on but expected) from configuration mistakes (need an operator).
pub const SendResult = enum {
    success,
    retryable_exhausted,
    non_retryable,
    encoding_failed,
};

pub const Error = error{
    InvalidUrl,
    TlsRequired,
    UrlTooLong,
} || std.mem.Allocator.Error;

/// Hard upper bound for the rendered endpoint URL. Generous for any real
/// collector hostname + signal path.
const max_url_bytes: usize = 4096;

/// Default cap on the compressed payload size posted in one HTTP request.
/// Most OTLP collectors honor `max_recv_msg_size = 4 MiB` (the protobuf
/// default for gRPC). Sidecar splits batches to stay below this.
pub const default_max_payload_bytes: usize = 4 * 1024 * 1024;

pub const Transport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: std.http.Client,
    /// Owned URL — we copy the caller's base because `Transport` outlives
    /// most callers' string storage. The previous version held a borrowed
    /// slice and worked only because `agent.run` happened to keep the
    /// config alive for the full sidecar lifetime.
    base_url: []u8,
    /// Owned headers — same lifetime reasoning as `base_url`.
    extra_headers: []std.http.Header,
    max_retries: u8,
    max_payload_bytes: usize,
    /// Reused 64 KiB window for the gzip compressor so each `send` doesn't
    /// allocate it from scratch. Single-threaded use — the flush thread
    /// is the only caller.
    gzip_window: []u8,

    pub const Options = struct {
        /// Base URL like `https://collector.example.com:4318`. The `/v1/*`
        /// path is appended per signal.
        base_url: []const u8,
        /// Extra headers (auth tokens, tenant IDs). Borrowed slice — caller
        /// keeps ownership of the underlying memory.
        headers: []const std.http.Header,
        max_retries: u8 = 3,
        max_payload_bytes: usize = default_max_payload_bytes,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, opts: Options) Error!Transport {
        if (!std.mem.startsWith(u8, opts.base_url, "https://")) return error.TlsRequired;
        // Strip trailing slash so endpoint = base + "/v1/logs" stays clean.
        var trimmed = opts.base_url;
        while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
        if (trimmed.len < "https://x".len) return error.InvalidUrl;
        if (trimmed.len + max_signal_path_len > max_url_bytes) return error.UrlTooLong;

        const base_copy = try allocator.dupe(u8, trimmed);
        errdefer allocator.free(base_copy);

        const headers_copy = try allocator.alloc(std.http.Header, opts.headers.len);
        errdefer allocator.free(headers_copy);
        @memcpy(headers_copy, opts.headers);

        const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
        errdefer allocator.free(window);

        return .{
            .allocator = allocator,
            .io = io,
            .client = .{ .allocator = allocator, .io = io },
            .base_url = base_copy,
            .extra_headers = headers_copy,
            .max_retries = opts.max_retries,
            .max_payload_bytes = opts.max_payload_bytes,
            .gzip_window = window,
        };
    }

    pub fn deinit(self: *Transport) void {
        self.client.deinit();
        self.allocator.free(self.base_url);
        self.allocator.free(self.extra_headers);
        self.allocator.free(self.gzip_window);
        self.* = undefined;
    }

    /// Posts `payload` to `<base_url><signal.path()>` with retries on
    /// transient failures. Payload is gzipped on the wire; the helpful
    /// `Content-Encoding: gzip` header tells the collector to decompress.
    pub fn send(self: *Transport, signal: Signal, payload: []const u8) SendResult {
        var url_buf: [max_url_bytes]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}{s}", .{ self.base_url, signal.path() }) catch {
            log.warn("sidecar: URL too long for {s}", .{signal.path()});
            return .encoding_failed;
        };

        const compressed = self.gzipCompress(payload) catch |err| {
            log.warn("sidecar: gzip failed for {s}: {t}", .{ url, err });
            return .encoding_failed;
        };
        defer self.allocator.free(compressed);

        // Collectors enforce per-request size limits; refuse to send a
        // batch that's certainly going to be rejected.
        if (compressed.len > self.max_payload_bytes) {
            log.warn("sidecar: compressed payload {d} bytes exceeds cap {d}", .{
                compressed.len, self.max_payload_bytes,
            });
            return .non_retryable;
        }

        // `Content-Encoding: gzip` isn't a typed slot on
        // `http.Client.Request.Headers` in std 0.16 — pass it through the
        // free-form `extra_headers` list alongside any caller-supplied auth
        // headers. Built once per send and freed at the end.
        const ce_header: std.http.Header = .{ .name = "Content-Encoding", .value = "gzip" };
        const headers_with_gzip = self.allocator.alloc(std.http.Header, self.extra_headers.len + 1) catch {
            log.warn("sidecar: out of memory building headers", .{});
            return .encoding_failed;
        };
        defer self.allocator.free(headers_with_gzip);
        @memcpy(headers_with_gzip[0..self.extra_headers.len], self.extra_headers);
        headers_with_gzip[self.extra_headers.len] = ce_header;

        var attempt: u8 = 0;
        while (attempt <= self.max_retries) : (attempt += 1) {
            if (attempt > 0) {
                const ms = backoffMs(attempt);
                std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
            }

            const result = self.client.fetch(.{
                .location = .{ .url = url },
                .method = .POST,
                .payload = compressed,
                .headers = .{
                    .content_type = .{ .override = "application/x-protobuf" },
                },
                .extra_headers = headers_with_gzip,
            }) catch |err| {
                if (attempt == self.max_retries) {
                    log.warn("sidecar POST {s} failed after {d} retries: {t}", .{ url, attempt, err });
                    return .retryable_exhausted;
                }
                continue;
            };

            const code = @intFromEnum(result.status);
            if (code >= 200 and code < 300) return .success;
            if (!retryable(code)) {
                log.warn("sidecar POST {s} returned {d} (non-retryable)", .{ url, code });
                return .non_retryable;
            }
            if (attempt == self.max_retries) {
                log.warn("sidecar POST {s} returned {d} after {d} retries", .{ url, code, attempt });
                return .retryable_exhausted;
            }
        }
        return .retryable_exhausted;
    }

    fn gzipCompress(self: *Transport, src: []const u8) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();
        var compress = try std.compress.flate.Compress.init(
            &aw.writer,
            self.gzip_window,
            .gzip,
            .level_6,
        );
        try compress.writer.writeAll(src);
        try compress.finish();
        return aw.toOwnedSlice();
    }
};

/// Longest `Signal.path()` value. Used at init to bound the URL length.
const max_signal_path_len: usize = "/v1/metrics".len;

fn retryable(code: u16) bool {
    if (code == 408 or code == 429) return true;
    return code >= 500 and code < 600;
}

/// Exponential backoff with a 5s cap: 100ms, 200ms, 400ms, 800ms, 1600ms, …
fn backoffMs(attempt: u8) u64 {
    const base: u64 = 100;
    const shift: u6 = @min(attempt - 1, 6);
    const ms = base * (@as(u64, 1) << shift);
    return @min(ms, 5_000);
}

// ─── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Signal: paths" {
    try testing.expectEqualStrings("/v1/logs", Signal.logs.path());
    try testing.expectEqualStrings("/v1/metrics", Signal.metrics.path());
}

test "retryable: 5xx and 429 are retryable, other 4xx are not" {
    try testing.expect(retryable(500));
    try testing.expect(retryable(503));
    try testing.expect(retryable(599));
    try testing.expect(retryable(408));
    try testing.expect(retryable(429));
    try testing.expect(!retryable(400));
    try testing.expect(!retryable(401));
    try testing.expect(!retryable(404));
    try testing.expect(!retryable(200));
    try testing.expect(!retryable(301));
}

test "backoffMs: doubles until cap" {
    try testing.expectEqual(@as(u64, 100), backoffMs(1));
    try testing.expectEqual(@as(u64, 200), backoffMs(2));
    try testing.expectEqual(@as(u64, 400), backoffMs(3));
    try testing.expectEqual(@as(u64, 800), backoffMs(4));
    try testing.expectEqual(@as(u64, 1600), backoffMs(5));
    try testing.expectEqual(@as(u64, 3200), backoffMs(6));
    try testing.expectEqual(@as(u64, 5_000), backoffMs(7));
    try testing.expectEqual(@as(u64, 5_000), backoffMs(20));
}

test "Transport.init: rejects non-https base URL" {
    const opts: Transport.Options = .{
        .base_url = "http://collector.example.com:4318",
        .headers = &.{},
    };
    try testing.expectError(error.TlsRequired, Transport.init(testing.allocator, std.Options.debug_io, opts));
}

test "Transport.init: clones base_url and survives caller-side free" {
    const stack_url = "https://collector.example.com:4318/";
    const heap_url = try testing.allocator.dupe(u8, stack_url);
    var tr = try Transport.init(testing.allocator, std.Options.debug_io, .{
        .base_url = heap_url,
        .headers = &.{},
    });
    // Free the caller's storage — `Transport` must hold its own copy.
    testing.allocator.free(heap_url);
    // Trailing slash should have been stripped.
    try testing.expectEqualStrings("https://collector.example.com:4318", tr.base_url);
    tr.deinit();
}
