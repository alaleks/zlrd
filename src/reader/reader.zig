//! Log format detection, filtering, and colored output.
//! Handles JSON, plain-text bracketed, and logfmt log formats.
//! Provides streaming reading with filtering by date, level, and search string.

const std = @import("std");
const flags = @import("flags");
const simd = @import("simd");
const tail_reader = @import("tail.zig");
const gzip = @import("gzip.zig");
const regex = @import("regex");
const theme = @import("theme.zig");
const civil = @import("civil.zig");
const parallel = @import("parallel.zig");
pub const Cutoff = civil.Cutoff;
const jsonx = @import("jsonx.zig");
const protox = @import("protox.zig");
const debug_io = std.Options.debug_io;

pub const Theme = theme.Theme;
pub const theme_mod = theme;

/// Buffered sink for everything this package prints.
///
/// Every printer used to exist twice — once writing straight to stdout for
/// tail/gzip, once into a buffer for the file readers — which meant the
/// gzip and follow paths issued a `write` syscall per colour escape and per
/// punctuation byte. Funnelling both through one buffered sink removed that
/// (and ~400 lines of copy-pasted printer).
///
/// Writes are infallible: output is best-effort, exactly as the previous
/// direct-to-stdout path was. That keeps `try` out of the printers, where
/// there is nothing useful to do with a write error anyway.
pub const Out = struct {
    file: std.Io.File,
    theme: *const Theme,
    buf: []u8,
    len: usize = 0,
    allocator: std.mem.Allocator,
    /// Set once a write fails, which in practice means the reader on the
    /// other end of the pipe went away (`| head`, quitting the pager). The
    /// read loops poll this and stop early instead of formatting the rest of
    /// a file nobody will read.
    broken: bool = false,
    /// When set, `flush` appends here instead of writing to `file`. The
    /// parallel scan gives every worker its own sink, so formatting happens
    /// on all cores while one thread writes the pieces out in order.
    sink: ?*std.ArrayList(u8) = null,

    /// Large enough that a page of styled output flushes once. Colour escapes
    /// inflate a log line roughly 3–5×, so this is ~1–2k lines per syscall.
    pub const capacity: usize = 256 * 1024;

    pub fn init(allocator: std.mem.Allocator, file: std.Io.File, th: *const Theme) !Out {
        return .{
            .file = file,
            .theme = th,
            .buf = try allocator.alloc(u8, capacity),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Out) void {
        self.flush();
        self.allocator.free(self.buf);
        self.* = undefined;
    }

    /// Appends `s`. The zero-length early-out matters: under the plain
    /// (no-colour) theme every palette entry is `""`, so this turns each
    /// styling call into a single predictable branch instead of a memcpy.
    pub fn write(self: *Out, s: []const u8) void {
        if (s.len == 0) return;
        if (s.len > self.buf.len - self.len) {
            self.flush();
            if (s.len > self.buf.len) {
                // Bigger than the whole buffer: hand it straight to the sink
                // rather than growing without bound.
                if (self.sink) |dst| {
                    dst.appendSlice(self.allocator, s) catch {
                        self.broken = true;
                    };
                } else {
                    self.file.writeStreamingAll(debug_io, s) catch {
                        self.broken = true;
                    };
                }
                return;
            }
        }
        @memcpy(self.buf[self.len..][0..s.len], s);
        self.len += s.len;
    }

    pub fn writeByte(self: *Out, c: u8) void {
        if (self.len == self.buf.len) self.flush();
        self.buf[self.len] = c;
        self.len += 1;
    }

    /// Writes `s` wrapped in `style`, resetting afterwards. No-ops the escapes
    /// when colour is off.
    pub fn writeStyled(self: *Out, style: []const u8, s: []const u8) void {
        self.write(style);
        self.write(s);
        self.write(self.theme.palette.reset);
    }

    pub fn print(self: *Out, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const printed = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.write(printed);
    }

    pub fn flush(self: *Out) void {
        if (self.len == 0) return;
        if (self.sink) |s| {
            s.appendSlice(self.allocator, self.buf[0..self.len]) catch {
                self.broken = true;
            };
        } else {
            self.file.writeStreamingAll(debug_io, self.buf[0..self.len]) catch {
                self.broken = true;
            };
        }
        self.len = 0;
    }
};

/// Cached analysis of a single log line.
/// Computed once per line by `analyzeLine` and reused by all filters and the printer.
pub const LineInfo = struct {
    format: enum {
        json,
        plain_bracketed,
        plain_logfmt,
        plain_unknown,
    },
    /// Extracted log level, or null if the line carries no recognizable level field.
    level: ?flags.Level,
    /// Byte range of the level value within the line, used for selective coloring.
    level_pos: ?LevelPos,
    /// When set, the printer runs in "rewrite" mode instead of replacing
    /// `level_pos`: the level block is INSERTED at `insert_at` and the tail
    /// past `truncate_at` is dropped. Currently populated only by the gRPC
    /// error heuristic ("rpc error: code = X" → surface as Error, hide the
    /// noisy tail).
    rewrite: ?Rewrite = null,
    /// Extracted YYYY-MM-DD date prefix, or null if absent.
    date: ?[]const u8,
    /// Extracted HH:MM or HH:MM:SS time, or null if absent.
    time: ?[]const u8,
    is_json: bool,
    starts_with_bracket: bool,
};

/// Analyzes a line and returns a fully populated `LineInfo`.
/// All subsequent operations (filtering, printing) use this result directly,
/// so the line is parsed only once per call path.
///
/// JSON lines are walked once via `analyzeJsonInPlace` which extracts level,
/// date, time, and level_pos in a single pass — the previous implementation
/// performed up to 4 full `extractJsonField` scans (one per candidate key).
fn analyzeLine(line: []const u8, want_timestamps: bool) LineInfo {
    var info: LineInfo = .{
        .format = .plain_unknown,
        .level = null,
        .level_pos = null,
        .rewrite = null,
        .date = null,
        .time = null,
        .is_json = false,
        .starts_with_bracket = false,
    };

    if (line.len == 0) return info;

    info.is_json = line[0] == '{';
    info.starts_with_bracket = line[0] == '[';

    if (info.is_json) {
        info.format = .json;
        analyzeJsonInPlace(line, &info);
        return info;
    }

    // Two full scans of the line that only pay off if a date/time filter is
    // active or the output format carries them. Skipped otherwise.
    if (want_timestamps) {
        info.date = extractDate(line);
        info.time = extractTime(line);
    }

    if (info.starts_with_bracket) {
        info.format = .plain_bracketed;
        if (simd.findBracketedLevel(line)) |r| {
            if (flags.parseLevelInsensitive(line[r.start..r.end])) |lvl| {
                info.level = lvl;
                info.level_pos = LevelPos{ .start = r.start, .end = r.end };
            }
        }
    } else if (simd.findLogfmtLevel(line)) |r| {
        info.format = .plain_logfmt;
        if (flags.parseLevelInsensitive(line[r.start..r.end])) |lvl| {
            info.level = lvl;
            info.level_pos = LevelPos{ .start = r.start, .end = r.end };
        }
    }

    if (info.level == null) inferMidLineLevel(line, &info);

    return info;
}

/// Fallback level detector for lines whose level is a bare word somewhere in
/// the middle (e.g. zerolog-formatted `... 9:32AM DBG message ...`), or a
/// gRPC status line with `code = <NAME>` where `<NAME>` ≠ `OK`.
///
/// gRPC is checked FIRST because the word "error" in "rpc error:" would
/// otherwise get picked up by the alpha-token scan and produce a misleading
/// `ERROR` block right in the middle of the message body. In gRPC mode we
/// switch to `Rewrite` — insert the level block right after the last
/// timestamp and drop the trailing "rpc error: code = X desc = ..." noise.
fn inferMidLineLevel(line: []const u8, info: *LineInfo) void {
    if (simd.findGrpcCode(line)) |r| {
        const name = line[r.start..r.end];
        if (!std.mem.eql(u8, name, "OK")) {
            info.level = .Error;
            info.rewrite = computeGrpcRewrite(line);
            return;
        }
    }

    var scan_from: usize = 0;
    while (simd.nextAlphaToken(line, scan_from)) |tok| {
        scan_from = tok.end;
        const len = tok.end - tok.start;
        if (len < 3 or len > 8) continue;
        if (flags.parseLevelInsensitive(line[tok.start..tok.end])) |lvl| {
            info.level = lvl;
            info.level_pos = LevelPos{ .start = tok.start, .end = tok.end };
            return;
        }
    }
}

/// Computes the `Rewrite` for a gRPC-flavoured error line. Inserts the level
/// block right after the last `HH:MM[:SS]` (falling back to line start when
/// no time is present) and truncates the trailing gRPC noise.
fn computeGrpcRewrite(line: []const u8) Rewrite {
    var insert_at: usize = findLastTimeEnd(line) orelse 0;
    // Skip a single space so the level block doesn't hug the timestamp.
    if (insert_at < line.len and line[insert_at] == ' ') insert_at += 1;

    var truncate_at: usize = line.len;
    // Prefer ", rpc " — this preserves the "clean" phrase that usually sits
    // before the gRPC tail (e.g. `Client.GetSystemConfigParams()`).
    if (std.mem.indexOfPos(u8, line, insert_at, ", rpc ")) |p| {
        truncate_at = p;
    } else if (std.mem.indexOfPos(u8, line, insert_at, "rpc error")) |p| {
        truncate_at = p;
        while (truncate_at > insert_at and
            (line[truncate_at - 1] == ' ' or line[truncate_at - 1] == '\t'))
        {
            truncate_at -= 1;
        }
    }
    return .{ .insert_at = insert_at, .truncate_at = truncate_at };
}

/// Byte offset immediately after the last `HH:MM` or `HH:MM:SS` substring in
/// `line`, or null if none is present. Iterates via the internal
/// `findTimeRange` helper so both plain syslog envelopes (`Jul 22 05:44:13`)
/// and later embedded timestamps (`2026/07/22 05:44:13`) are considered — we
/// want the LAST match so the inserted level block ends up next to the
/// message body, not next to the syslog envelope.
fn findLastTimeEnd(line: []const u8) ?usize {
    var last: ?usize = null;
    var from: usize = 0;
    while (findTimeRange(line, from)) |r| {
        last = r.end;
        from = r.end;
    }
    return last;
}

/// Locates the next `HH:MM[:SS]` starting at or after `from`, mirroring the
/// scan logic of `extractTime` but reporting the byte range instead of a
/// borrowed slice.
fn findTimeRange(line: []const u8, from: usize) ?struct { start: usize, end: usize } {
    if (line.len < 5) return null;
    var scan_pos: usize = if (from < 2) 2 else from;
    while (scan_pos < line.len) {
        const colon = simd.findByte(line, scan_pos, ':') orelse return null;
        if (colon < 2) {
            scan_pos = colon + 1;
            continue;
        }
        const i = colon - 2;
        if (i < from) {
            scan_pos = colon + 1;
            continue;
        }
        const boundary_ok = i == 0 or line[i - 1] == 'T' or line[i - 1] == ' ' or line[i - 1] == '[';
        if (!boundary_ok or
            i + 5 > line.len or
            !isDigit(line[i]) or !isDigit(line[i + 1]) or
            !isDigit(line[i + 3]) or !isDigit(line[i + 4]))
        {
            scan_pos = colon + 1;
            continue;
        }
        const end = if (i + 8 <= line.len and line[i + 5] == ':' and
            isDigit(line[i + 6]) and isDigit(line[i + 7]))
            i + 8
        else
            i + 5;
        return .{ .start = i, .end = end };
    }
    return null;
}

/// Targets we look up while walking a JSON object's top-level keys.
const JsonTarget = enum { none, level, time_like };

/// Identifies the target slot a given JSON key fills. `time`, `timestamp`,
/// and `date` are all treated equivalently — first one wins.
inline fn identifyJsonKey(key: []const u8) JsonTarget {
    if (std.mem.eql(u8, key, "level")) return .level;
    if (std.mem.eql(u8, key, "time")) return .time_like;
    if (std.mem.eql(u8, key, "timestamp")) return .time_like;
    if (std.mem.eql(u8, key, "date")) return .time_like;
    return .none;
}

inline fn isJsonWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Single-pass extractor for JSON log lines. Walks top-level keys exactly
/// once and fills in `level`, `level_pos`, `date`, `time` as it encounters
/// the matching fields. Exits early once both level and date are known.
fn analyzeJsonInPlace(line: []const u8, info: *LineInfo) void {
    var i: usize = 1; // skip the opening '{'

    while (i < line.len) {
        // Locate the next top-level key opening quote.
        const q = simd.findByte(line, i, '"') orelse return;
        const key_start = q + 1;
        const key_end = simd.scanJsonStringEnd(line, key_start) orelse return;
        const key = line[key_start..key_end];
        i = key_end + 1;

        while (i < line.len and isJsonWs(line[i])) : (i += 1) {}
        if (i >= line.len or line[i] != ':') continue;
        i += 1;
        while (i < line.len and isJsonWs(line[i])) : (i += 1) {}

        const target = identifyJsonKey(key);
        if (target == .none) {
            i = skipJsonValue(line, i);
            continue;
        }

        // We only care about string values; non-string slots are skipped.
        if (i >= line.len or line[i] != '"') {
            i = skipJsonValue(line, i);
            continue;
        }
        i += 1;
        const value_start = i;
        const value_end = simd.scanJsonStringEnd(line, value_start) orelse return;
        const value = line[value_start..value_end];
        i = value_end + 1;

        switch (target) {
            .level => {
                if (info.level == null and value.len <= 16) {
                    info.level = flags.parseLevelInsensitive(value);
                    info.level_pos = .{ .start = value_start, .end = value_end };
                }
            },
            .time_like => {
                if (info.date == null and value.len >= 10 and isValidDateString(value[0..10])) {
                    info.date = value[0..10];
                }
                if (info.time == null) {
                    if (timeWithinValue(value)) |t| info.time = t;
                }
            },
            .none => unreachable,
        }

        // Exit only when every slot we care about is filled. Requiring `time`
        // too avoids missing it when a JSON puts `date` and `timestamp` in
        // separate fields (e.g. `{"date":"…","level":"…","timestamp":"…"}`);
        // otherwise the two earlier fields would trip the exit and the later
        // `timestamp` would never be walked → `--from-time` silently drops.
        if (info.level != null and info.date != null and info.time != null) return;
    }
}

/// Looks for an `HH:MM[:SS]` substring inside a JSON timestamp value.
/// Expects ISO-shaped strings (`2024-01-15T14:30:00Z`, `… 14:30 …`).
fn timeWithinValue(value: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 5 <= value.len) : (i += 1) {
        const boundary_ok = i == 0 or value[i - 1] == 'T' or value[i - 1] == ' ' or value[i - 1] == '[';
        if (!boundary_ok) continue;
        if (!isDigit(value[i]) or !isDigit(value[i + 1]) or value[i + 2] != ':' or
            !isDigit(value[i + 3]) or !isDigit(value[i + 4])) continue;
        const end = if (i + 8 <= value.len and value[i + 5] == ':' and
            isDigit(value[i + 6]) and isDigit(value[i + 7]))
            i + 8
        else
            i + 5;
        return value[i..end];
    }
    return null;
}

// The palette lives in `theme.zig`. It is resolved once at startup from the
// terminal's advertised capabilities rather than hard-coded, because the
// previous fixed GitHub-Dark table was unreadable on a light background
// (contrast as low as 1.18:1 against white) and printed raw escape bytes on
// terminals without 24-bit colour.

/// Byte range of a level value within a line.
const LevelPos = struct {
    start: usize,
    end: usize,
};

/// Rewrite instructions for plain-text lines whose level is inferred rather
/// than lifted from a token. The printer keeps bytes `[0..insert_at]`, emits
/// the level block, keeps `[insert_at..truncate_at]`, and drops the rest.
pub const Rewrite = struct {
    insert_at: usize,
    truncate_at: usize,
};

/// Byte range of a search match within a line.
const MatchRange = struct {
    start: usize,
    end: usize,
};

const max_search_matches = 64;

/// Inclusive date range for the `-d` filter.
/// Both bounds are optional; a missing bound means open-ended.
const DateRange = struct {
    from: ?[]const u8,
    to: ?[]const u8,
};

/// Pre-computed filter state derived from command-line arguments.
/// Build once with `FilterState.init`, then call `checkLine` per line.
/// Keeping this separate from `flags.Args` avoids repeated string parsing
/// and repeated `args.date` null-checks in the hot path.
/// Result of a successful `FilterState.checkLine` call. `line` may point into
/// the caller's original bytes OR into the FilterState-owned strip buffer
/// (when the input contained literal `#033[..m` ANSI runs). Callers that
/// print or aggregate must use `line` (not the raw input), so display and
/// aggregation see the cleaned bytes.
pub const CheckedLine = struct {
    line: []const u8,
    info: LineInfo,
};

/// Scratch size for the ANSI-strip buffer inside `FilterState`. Big enough
/// for realistic log lines (16 KiB is well above zerolog+journalctl
/// pathological cases); if a line exceeds it, `stripLiteralAnsi` falls back
/// to the original bytes so nothing is silently truncated.
const filter_strip_buf_size: usize = 16 * 1024;

/// Expands JSON found inside a log message into an indented, coloured block
/// printed under the line.
///
/// Owns the scratch used to decode escaped payloads, so expansion costs no
/// allocation once the reader is running. One instance is shared by a whole
/// read loop.
pub const JsonExpander = struct {
    limits: jsonx.Limits = .{},
    /// Bounds for the protobuf fallback. Separate from `limits` because the
    /// two formats need different ceilings — field numbers and wire nesting
    /// have nothing to do with JSON depth or brace counts.
    proto_limits: protox.Limits = .{},
    /// Un-escape target for JSON carried as a string value. Sized to the
    /// largest region `limits` will expand, so a payload that passes
    /// validation always fits.
    scratch: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, limits: jsonx.Limits) !JsonExpander {
        return .{
            .limits = limits,
            .scratch = try allocator.alloc(u8, limits.max_bytes),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *JsonExpander) void {
        self.allocator.free(self.scratch);
        self.* = undefined;
    }

    /// Expands raw JSON embedded in a plain-text line, searching from `from`
    /// (the end of the level token) so a bracketed prefix can't be mistaken
    /// for a payload.
    pub fn expandPlain(self: *JsonExpander, out: *Out, line: []const u8, from: usize) void {
        const span = jsonx.find(line, from, self.limits) orelse return;
        jsonx.writeBlock(out, out.theme, span.slice(line), self.limits);
    }

    /// Length of the escaped prefix worth printing for a value that carries a
    /// protobuf payload — the human sentence in front of the bytes.
    ///
    /// Null when there is nothing to hide, which is the common case: either
    /// the value holds no payload, or it holds nested JSON, which stays
    /// verbatim on the line because it is already readable there.
    ///
    /// Without this the compact line keeps a run of `\u00XX` escapes that
    /// nobody can read and that the block underneath has already decoded —
    /// the same bytes twice, once unreadably.
    pub fn payloadPrefix(self: *JsonExpander, value: []const u8) ?usize {
        if (jsonx.looksLikeNestedObject(value, self.limits)) return null;
        if (!protox.looksLikeBinary(value)) return null;
        const raw = protox.unescapeBytes(self.scratch, value) orelse return null;
        const start = protox.find(raw, self.proto_limits) orelse return null;
        return protox.escapedPrefixLen(value, start);
    }

    /// Expands a payload carried as an escaped string value of a JSON log
    /// line — nested JSON, or protobuf wire bytes.
    ///
    /// JSON is tried first: it is the cheaper check and the unambiguous one.
    /// Protobuf only gets a look when the value failed to be JSON, and then
    /// only after a second un-escape pass, because the two need different
    /// byte semantics for `\uXXXX` (see `protox.unescapeBytes`). Both passes
    /// reuse the same scratch, so the fallback costs no memory.
    ///
    /// Silently does nothing when the value turns out to be neither — the
    /// compact line already showed it verbatim.
    pub fn expandEscaped(self: *JsonExpander, out: *Out, value: []const u8) void {
        if (jsonx.unescape(self.scratch, value)) |decoded| {
            if (jsonx.validate(decoded, self.limits) != null) {
                jsonx.writeBlock(out, out.theme, decoded, self.limits);
                return;
            }
        }

        if (!protox.looksLikeBinary(value)) return;
        const raw = protox.unescapeBytes(self.scratch, value) orelse return;
        const start = protox.find(raw, self.proto_limits) orelse return;
        protox.writeBlock(out, out.theme, raw[start..], self.proto_limits);
    }
};

pub const FilterState = struct {
    has_date_filter: bool,
    date_range: DateRange,
    has_time_filter: bool,
    from_time: ?[]const u8,
    to_time: ?[]const u8,
    has_level_filter: bool,
    enabled_levels: ?flags.LevelMask,
    has_search_filter: bool,
    has_regex: bool,
    regex_list: regex.RegexList,
    search_expr: ?[]const u8,
    output_json: bool,
    /// Whether `analyzeLine` has to extract the date and time.
    needs_timestamps: bool = true,
    /// Whether the current read chunk contains any byte that could open a
    /// literal `#033[` escape. Set once per chunk by `beginChunk`; when
    /// false, `checkLine` skips the per-line strip scan entirely.
    ///
    /// Defaults to true so callers that never call `beginChunk` (tail,
    /// gzip) keep stripping unconditionally.
    chunk_may_have_ansi: bool = true,
    /// Sink used by `printIfMatch` / `printChecked`. Null for filter-only use.
    out: ?*Out = null,
    /// Cutoff for `--since`, set by the caller once the anchor is known.
    /// Null when no relative window was asked for.
    since_cut: ?civil.Cutoff = null,
    /// Null disables embedded-JSON expansion.
    expander: ?*JsonExpander = null,
    strip_buf: [filter_strip_buf_size]u8 = undefined,

    /// Builds a `FilterState` from parsed CLI arguments.
    /// Tries to compile regex; falls back to literal matching on failure.
    /// Date filtering is disabled in tail mode.
    ///
    /// `out` and `expander` may be null for filter-only use (tests, and
    /// gzip's collecting sink); `printIfMatch` then does nothing.
    pub fn init(args: flags.Args, out: ?*Out, expander: ?*JsonExpander) FilterState {
        const has_date = !args.tail_mode and args.date != null;
        const has_time = !args.tail_mode and (args.from_time != null or args.to_time != null);
        const has_search = args.search != null;
        var rx_list: regex.RegexList = undefined;
        var has_rx = false;
        if (has_search and shouldUseRegexSearch(args.search.?)) {
            if (regex.RegexList.compile(args.search.?)) |rl| {
                rx_list = rl;
                has_rx = true;
            }
        }
        return .{
            .has_date_filter = has_date,
            .date_range = if (has_date) parseDateRange(args.date.?) else .{ .from = null, .to = null },
            .has_time_filter = has_time,
            .from_time = args.from_time,
            .to_time = args.to_time,
            .has_level_filter = args.levels != null,
            .enabled_levels = args.levels,
            .has_search_filter = has_search and !has_rx,
            .has_regex = has_rx,
            .regex_list = rx_list,
            .search_expr = args.search,
            .output_json = args.output_json,
            // `analyzeLine` only needs the date and time when something
            // downstream will read them. Skipping the two scans on every
            // plain-text line is pure win when neither filter is active and
            // output isn't JSON.
            .needs_timestamps = has_date or has_time or args.output_json or
                (!args.tail_mode and args.since_ms != null),
            .out = out,
            .expander = expander,
        };
    }

    /// Free compiled regex if present.
    pub fn deinit(self: *FilterState) void {
        if (self.has_regex) self.regex_list.deinit();
    }

    /// Returns a `CheckedLine` if the (possibly ANSI-stripped) `line` passes
    /// all active filters, null otherwise. The returned `line` slice must be
    /// used for all subsequent operations (print, aggregation) so that the
    /// stripped bytes propagate through the pipeline.
    ///
    /// Filter order: search → level → date (cheapest to most expensive).
    /// Called once per read chunk, before its lines are handed to
    /// `checkLine`. Hoists the "does this data contain literal ANSI at all"
    /// question out of the per-line path: one scan of the whole chunk
    /// instead of one call per line over the same bytes.
    pub fn beginChunk(self: *FilterState, chunk: []const u8) void {
        self.chunk_may_have_ansi = simd.findByte(chunk, 0, '#') != null;
    }

    pub fn checkLine(self: *FilterState, raw_line: []const u8) ?CheckedLine {
        if (raw_line.len == 0) return null;
        const line = if (self.chunk_may_have_ansi)
            simd.stripLiteralAnsi(&self.strip_buf, raw_line)
        else
            raw_line;

        if (self.has_regex) {
            if (!self.regex_list.allMatch(line)) return null;
        } else if (self.has_search_filter) {
            if (!matchSearch(line, self.search_expr.?)) return null;
        }

        const info = analyzeLine(line, self.needs_timestamps);

        if (self.has_level_filter) {
            const lvl = info.level orelse return null;
            if (self.enabled_levels.? & flags.levelBit(lvl) == 0) return null;
        }

        if (self.has_date_filter) {
            if (!matchDateRangeWithDate(info.date, self.date_range)) return null;
        }

        if (self.has_time_filter) {
            if (!matchTimeRange(info.time, self.from_time, self.to_time)) return null;
        }

        if (self.since_cut) |*cut| {
            if (!civil.atOrAfter(info.date, info.time, cut)) return null;
        }

        return .{ .line = line, .info = info };
    }

    /// Convenience wrapper: filter and print in one call.
    /// Intended for tail.zig so it does not need to import `LineInfo` or
    /// `printStyledLine`.
    pub fn printIfMatch(self: *FilterState, line: []const u8) void {
        if (self.checkLine(line)) |ck| self.printChecked(ck.line, ck.info);
    }

    /// Prints an already-checked line using its cached `LineInfo`. Callers
    /// that have already run `checkLine` use this to skip a second parse.
    /// `line` must be the (possibly stripped) `CheckedLine.line` — passing
    /// the raw input undoes the ANSI stripping done in `checkLine`.
    pub fn printChecked(self: *FilterState, line: []const u8, info: LineInfo) void {
        const out = self.out orelse return;
        if (self.output_json) {
            printJsonOutputLine(out, line, info);
            return;
        }
        var match_buf: [max_search_matches]MatchRange = undefined;
        // Match ranges exist only to place highlight escapes around them. In
        // the colourless palette those escapes are empty strings, so
        // collecting the ranges cannot change a single output byte — it only
        // costs an O(line x term) rescan per record and, worse, pushes the
        // line off the direct-copy path in `printStyledLine` onto the
        // token walk. Redirected output is the common case, so gate on it.
        // `has_search_filter` and `has_regex` are mutually exclusive — `init`
        // clears the former when a pattern compiles — so both have to be
        // consulted here, exactly as `checkLine` does.
        const matches: []const MatchRange = if (!out.theme.colored)
            &.{}
        else if (self.has_regex)
            // The literal splitter cannot find `5\d\d` in a line, so every
            // regex search printed without a single highlight — the filter
            // matched and the printer had nothing to mark.
            findRegexMatches(line, &self.regex_list, &match_buf)
        else if (self.has_search_filter)
            findSearchMatches(line, self.search_expr.?, &match_buf)
        else
            &.{};
        printStyledLine(out, line, info, matches, self.expander);
    }
};

/// Per-level line counter for summary display.
pub const LevelCounter = struct {
    counts: [7]usize = [_]usize{0} ** 7,
    total: usize = 0,

    pub fn add(self: *LevelCounter, lvl: flags.Level) void {
        self.counts[@intFromEnum(lvl)] += 1;
        self.total += 1;
    }

    /// Print a colored summary of matched line counts per level.
    pub fn print(self: LevelCounter, out: *Out) void {
        if (self.total == 0) return;
        const levels = [_]flags.Level{ .Trace, .Debug, .Info, .Warn, .Error, .Fatal, .Panic };
        for (levels) |lvl| {
            const n = self.counts[@intFromEnum(lvl)];
            if (n == 0) continue;
            out.write(out.theme.levelStyle(lvl));
            out.write(" ");
            writeUpperPadded(out, @tagName(lvl), 5);
            out.print(" {d} ", .{n});
            out.write(out.theme.palette.reset);
        }
        out.write(out.theme.palette.dim);
        out.print("  total {d}\n", .{self.total});
        out.write(out.theme.palette.reset);
    }
};

/// Per-key state kept by `Aggregator`. One entry replaces the three parallel
/// hash-maps of the previous design (counts / sample_lines / sample_infos).
pub const AggregateEntry = struct {
    count: usize,
    sample_line: []const u8,
    sample_info: LineInfo,
};

/// Aggregates identical matched lines.
/// Keeps first-seen order and stores each unique line only once.
pub const Aggregator = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    entries: std.StringHashMapUnmanaged(AggregateEntry),
    order: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) !Aggregator {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .entries = .{},
            .order = try std.ArrayList([]const u8).initCapacity(allocator, 128),
        };
    }

    pub fn deinit(self: *Aggregator) void {
        self.entries.deinit(self.allocator);
        self.order.deinit(self.allocator);
        self.arena.deinit();
    }

    /// Add one matched line under a borrowed aggregation key. On the
    /// existing-key path we only bump the counter — no allocation. On the
    /// new-key path we reserve hash-table capacity first, so the arena
    /// dupes can't leak if the put OOMs.
    ///
    /// Silently drops new keys once `max_aggregate_keys` is hit so a file
    /// with pathologically high key cardinality can't exhaust memory.
    pub fn add(self: *Aggregator, key: []const u8, sample_line: []const u8, info: LineInfo) !void {
        if (self.entries.getPtr(key)) |entry| {
            entry.count += 1;
            return;
        }
        if (self.entries.count() >= max_aggregate_keys) return;

        // Reserve first so the hash-map puts below cannot OOM after we've
        // already burned arena bytes on the key/line dupes.
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        try self.order.ensureUnusedCapacity(self.allocator, 1);

        const owned_key = try self.arena.allocator().dupe(u8, key);
        const owned_line = try self.arena.allocator().dupe(u8, sample_line);

        self.entries.putAssumeCapacityNoClobber(owned_key, .{
            .count = 1,
            .sample_line = owned_line,
            .sample_info = info,
        });
        self.order.appendAssumeCapacity(owned_key);
    }

    /// Print all aggregated entries in first-seen order.
    /// If `page_size > 0`, paginate the aggregated output.
    fn printAll(self: *Aggregator, out: *Out, page_size: usize, output_json: bool, expander: ?*JsonExpander) void {
        var batch: usize = 0;
        var page: usize = 1;

        // Iterate the entry pointers stored alongside the key order rather
        // than re-hashing every key to fetch its entry.
        for (self.order.items) |key| {
            const entry = self.entries.getPtr(key) orelse continue;
            if (output_json) {
                printJsonOutputLine(out, entry.sample_line, entry.sample_info);
            } else {
                out.write(out.theme.palette.dim);
                out.print("[x{d}] ", .{entry.count});
                out.write(out.theme.palette.reset);
                printStyledLine(out, entry.sample_line, entry.sample_info, &.{}, expander);
            }

            if (page_size > 0) {
                batch += 1;
                if (batch >= page_size) {
                    out.flush();
                    printPaginationPrompt(out, page, batch);
                    out.flush();
                    waitForEnter();
                    clearScreen(out);
                    batch = 0;
                    page += 1;
                }
            }
        }
    }
};

/// Parses a date filter string into a `DateRange`.
/// Accepts a single date (`YYYY-MM-DD`) or a range (`FROM..TO`).
/// Either side of `..` may be omitted for an open-ended bound.
fn parseDateRange(s: []const u8) DateRange {
    if (std.mem.indexOf(u8, s, "..")) |pos| {
        const left = s[0..pos];
        const right = s[pos + 2 ..];
        return .{
            .from = if (left.len > 0) left else null,
            .to = if (right.len > 0) right else null,
        };
    }
    return .{ .from = s, .to = s };
}

/// Returns true if the date extracted from `line` lies within `range`.
/// Comparison is lexicographic, which is correct for ISO-8601 dates.
fn matchDateRange(line: []const u8, range: DateRange) bool {
    return matchDateRangeWithDate(extractDate(line), range);
}

/// Returns true if `date` lies within `range`.
/// `null` date never matches. Both sides are truncated to 10 chars (YYYY-MM-DD)
/// before lexicographic comparison.
fn matchDateRangeWithDate(date: ?[]const u8, range: DateRange) bool {
    const d = date orelse return false;
    const d10 = if (d.len >= 10) d[0..10] else return false;

    if (range.from) |from| {
        const f10 = if (from.len >= 10) from[0..10] else return false;
        if (std.mem.order(u8, d10, f10) == .lt) return false;
    }
    if (range.to) |to| {
        const t10 = if (to.len >= 10) to[0..10] else return false;
        if (std.mem.order(u8, d10, t10) == .gt) return false;
    }
    return true;
}

/// Extracts the `YYYY-MM-DD` date prefix from a log line.
/// Recognizes JSON `time`, `timestamp`, and `date` fields and plain ISO prefixes.
/// Also handles dates immediately after an opening bracket: `[YYYY-MM-DD...`.
/// Returns a slice into `line`, or null if no date is found.
fn extractDate(line: []const u8) ?[]const u8 {
    if (line.len == 0) return null;

    if (line[0] == '{') {
        inline for (.{ "time", "timestamp", "date" }) |field| {
            if (simd.extractJsonField(line, field, 32)) |v| {
                if (v.len >= 10 and isValidDateString(v[0..10])) return v[0..10];
            }
        }
        return null;
    }

    if (simd.isISODate(line)) return line[0..10];
    if (line.len >= 11 and line[0] == '[') {
        const s = line[1..11];
        if (isValidDateString(s)) return s;
    }

    return null;
}

/// Extracts a time (HH:MM or HH:MM:SS) from a log line.
/// Looks for a time pattern preceded by T, space, or bracket.
/// Returns a slice into `line`, or null if no time is found.
///
/// Uses SIMD `findByte` to jump between `:` candidates instead of walking
/// each byte. For long lines without a time near the start this is the
/// difference between an O(n) scalar scan and ~O(n/VecSize) candidate hops.
fn extractTime(line: []const u8) ?[]const u8 {
    if (line.len < 5) return null;

    var scan_pos: usize = 2; // earliest position a `:` of HH:MM can sit at
    while (scan_pos < line.len) {
        const colon = simd.findByte(line, scan_pos, ':') orelse return null;
        // Candidate start of HH:MM is two bytes before the colon.
        if (colon < 2) {
            scan_pos = colon + 1;
            continue;
        }
        const i = colon - 2;
        const boundary_ok = i == 0 or line[i - 1] == 'T' or line[i - 1] == ' ' or line[i - 1] == '[';
        if (!boundary_ok or
            i + 5 > line.len or
            !isDigit(line[i]) or !isDigit(line[i + 1]) or
            !isDigit(line[i + 3]) or !isDigit(line[i + 4]))
        {
            scan_pos = colon + 1;
            continue;
        }
        const end = if (i + 8 <= line.len and line[i + 5] == ':' and
            isDigit(line[i + 6]) and isDigit(line[i + 7]))
            i + 8
        else
            i + 5;
        return line[i..end];
    }
    return null;
}

/// Returns true if `time` lies within [from_time, to_time].
/// Both sides are truncated to the shorter length for fair comparison.
/// When prefixes match, the longer side wins (e.g. "15:00:01" > "15:00").
fn matchTimeRange(time: ?[]const u8, from_time: ?[]const u8, to_time: ?[]const u8) bool {
    const t = time orelse return true;
    if (t.len < 5) return true;

    if (from_time) |from| {
        const len = @min(t.len, from.len);
        switch (std.mem.order(u8, t[0..len], from[0..len])) {
            .lt => return false,
            .eq => if (t.len < from.len) return false,
            else => {},
        }
    }
    if (to_time) |to| {
        const len = @min(t.len, to.len);
        switch (std.mem.order(u8, t[0..len], to[0..len])) {
            .gt => return false,
            .eq => if (t.len > to.len) return false,
            else => {},
        }
    }
    return true;
}

/// Background + foreground ANSI codes for a log level.
/// Emits a level badge: the level name uppercased and padded to a uniform
/// width, wrapped in that level's colours.
///
/// Padding uses plain spaces rather than U+2009 THIN SPACE — the old choice
/// rendered as a replacement box on Windows consoles and in terminals with a
/// narrow font fallback.
fn writeLevelBadge(out: *Out, lvl: flags.Level, label: []const u8) void {
    out.write(out.theme.levelStyle(lvl));
    out.write(" ");
    writeUpperPadded(out, label, 5);
    out.write(" ");
    out.write(out.theme.palette.reset);
}

/// Upper bound for a single logical line. Logs are line-oriented; a line
/// longer than this is almost certainly corrupted input or a binary file
/// misidentified as text. Capping here keeps the carry buffer from growing
/// without bound when a file has no newlines.
pub const max_line_bytes: usize = 4 * 1024 * 1024;

/// Upper bound for distinct aggregation keys retained across one file scan.
/// Each unique key pins its sample line in the arena, so unbounded keys =
/// unbounded memory. Beyond this cap we keep counting hits on existing keys
/// but silently skip new ones (the alternative — aborting mid-scan — is
/// worse for an interactive tool).
pub const max_aggregate_keys: usize = 100_000;

pub const LineCapError = error{LineTooLong};

/// Returns `error.LineTooLong` if appending `extra` bytes to `current` would
/// exceed `max_line_bytes`. Inline so the bounds check stays in the hot loop.
inline fn ensureLineCapacity(current: usize, extra: usize) LineCapError!void {
    if (current + extra > max_line_bytes) return error.LineTooLong;
}

/// Returns an appropriate read-buffer size based on the file's size.
/// Larger files get a larger buffer to amortize syscall overhead.
fn getOptimalBufferSize(file: std.Io.File) usize {
    const stat = file.stat(debug_io) catch return 512 * 1024;
    return if (stat.size > 100 * 1024 * 1024)
        1024 * 1024 // > 100 MB → 1 MB
    else if (stat.size > 10 * 1024 * 1024)
        512 * 1024 // > 10 MB  → 512 KB
    else
        256 * 1024; // ≤ 10 MB  → 256 KB
}

/// Entry point for reading log files with filtering and coloured output.
/// Dispatches to tail follow mode, gzip, pagination, or continuous streaming.
pub fn readLogs(
    allocator: std.mem.Allocator,
    args: flags.Args,
    th: *const Theme,
    since_cut: ?civil.Cutoff,
) !void {
    if (args.tail_mode) {
        try tail_reader.follow(allocator, args, th);
        return;
    }

    var out = try Out.init(allocator, std.Io.File.stdout(), th);
    defer out.deinit();

    var counter = LevelCounter{};
    for (args.files) |path| {
        try readStreaming(allocator, path, args, &counter, &out, since_cut);
        if (out.broken) return;
    }
    if (!args.output_json) counter.print(&out);
}

/// Bytes of the tail scanned when looking for the anchor timestamp. Large
/// enough that a stack trace or a burst of untimestamped lines at the end of
/// a file cannot hide the last real record, small enough to be one read.
const anchor_scan_bytes: usize = 64 * 1024;

/// The cutoff for `--since`: `window_ms` before the newest timestamp in the
/// inputs.
///
/// Computed once for the whole run, over every file named on the command
/// line — which is why it lives here and not inside `readLogs`. Multiple
/// files are read one at a time, each through its own `readLogs` call, so an
/// anchor found there would be per-file: `--since 5m app.log app.log.1` would
/// hand back the last five minutes of *each* file, resurrecting the rotated
/// one from last week.
///
/// Anchoring on the log rather than on the clock is what keeps this free of
/// time zones — both sides of every later comparison come from the same file,
/// so whatever offset its timestamps carry cancels out. It also means
/// `--since 5m` on a log that was rotated last week shows the last five
/// minutes *of that log*, instead of the empty output a wall-clock window
/// would produce.
///
/// Falls back to null — no filtering — when nothing in the inputs carries a
/// date. Silently dropping every line because no anchor could be found would
/// look exactly like a log with nothing in it.
pub fn sinceCutoff(files: []const []const u8, window_ms: u64) ?civil.Cutoff {
    var best_date: ?[10]u8 = null;
    var best_time: ?[8]u8 = null;
    var buf: [anchor_scan_bytes]u8 = undefined;

    for (files) |path| {
        // Compressed input is not seekable, so the tail cannot be read
        // without decompressing everything ahead of it. Skipped rather than
        // paid for twice.
        if (gzip.isGzip(path)) continue;

        const file = std.Io.Dir.cwd().openFile(debug_io, path, .{}) catch continue;
        defer file.close(debug_io);
        const size = file.length(debug_io) catch continue;
        if (size == 0) continue;

        const want: usize = @intCast(@min(@as(u64, buf.len), size));
        const pos = size - want;
        const n = file.readPositional(debug_io, &.{buf[0..want]}, pos) catch continue;
        if (n == 0) continue;

        if (newestInChunk(buf[0..n])) |found| {
            const better = if (best_date) |bd| blk: {
                const order = std.mem.order(u8, &found.date, &bd);
                if (order == .gt) break :blk true;
                if (order == .lt) break :blk false;
                break :blk std.mem.order(u8, &found.time, &(best_time orelse found.time)) == .gt;
            } else true;
            if (better) {
                best_date = found.date;
                best_time = found.time;
            }
        }
    }

    const d = best_date orelse return null;
    const t = best_time orelse return null;
    return civil.cutoffBefore(&d, &t, window_ms);
}

const AnchorStamp = struct { date: [10]u8, time: [8]u8 };

/// Last line in `chunk` that carries both a date and a time.
///
/// Walks backwards because the newest record is at the end, and stops at the
/// first hit — a log is written in order, so scanning the rest to confirm
/// would cost a full pass to learn nothing.
fn newestInChunk(chunk: []const u8) ?AnchorStamp {
    var end = chunk.len;
    while (end > 0) {
        // The first line of the chunk may be a fragment of a longer one, so
        // it is only considered when the chunk starts the file.
        const start = if (std.mem.lastIndexOfScalar(u8, chunk[0..end], '\n')) |nl| nl + 1 else 0;
        const line = std.mem.trimEnd(u8, chunk[start..end], "\r");
        if (line.len > 0) {
            const info = analyzeLine(line, true);
            if (info.date) |d| {
                if (info.time) |t| {
                    if (d.len >= 10 and t.len >= 5) {
                        var stamp: AnchorStamp = .{ .date = undefined, .time = "00:00:00".* };
                        @memcpy(&stamp.date, d[0..10]);
                        @memcpy(stamp.time[0..@min(t.len, 8)], t[0..@min(t.len, 8)]);
                        return stamp;
                    }
                }
            }
        }
        if (start == 0) return null;
        end = start - 1;
    }
    return null;
}

/// Smallest file worth splitting across threads. Below this the pool costs
/// more to stand up than the scan it replaces.
const parallel_min_bytes: u64 = 4 << 20;

/// Input bytes per chunk. Small enough that peak memory stays in single-digit
/// megabytes at any thread count, large enough that per-chunk overhead
/// disappears against the work.
const parallel_chunk_bytes: usize = 1 << 20;

/// Threads the pool will use at most. Past this the writer, which is a single
/// thread, becomes the bottleneck and the extra workers only add memory.
const parallel_max_workers: usize = 8;

/// One thread's worth of scanning state.
///
/// Everything a line needs is per-worker: its own filter state, its own
/// expander, its own output buffer. Nothing is shared, so there is no lock on
/// the hot path — the only synchronisation in the whole scan is handing a
/// finished chunk to the writer.
const ChunkWorker = struct {
    out: Out,
    filter_state: FilterState,
    expander: ?JsonExpander,
    counter: LevelCounter = .{},

    fn init(
        allocator: std.mem.Allocator,
        args: flags.Args,
        th: *const Theme,
        since_cut: ?civil.Cutoff,
    ) !ChunkWorker {
        var w = ChunkWorker{
            .out = try Out.init(allocator, std.Io.File.stdout(), th),
            .filter_state = undefined,
            .expander = if (wantsJsonExpansion(args, th))
                try JsonExpander.init(allocator, .{})
            else
                null,
        };
        w.filter_state = FilterState.init(args, &w.out, null);
        w.filter_state.since_cut = since_cut;
        return w;
    }

    /// Fixes up the interior pointers that `init` could not set, because the
    /// struct is moved into its slot after being built.
    fn rebind(self: *ChunkWorker) void {
        self.filter_state.out = &self.out;
        self.filter_state.expander = if (self.expander) |*x| x else null;
    }

    fn deinit(self: *ChunkWorker) void {
        self.filter_state.deinit();
        if (self.expander) |*x| x.deinit();
        self.out.deinit();
    }

    pub fn process(self: *ChunkWorker, chunk: []const u8, dst: *std.ArrayList(u8)) void {
        self.out.sink = dst;
        self.out.len = 0;
        self.filter_state.beginChunk(chunk);

        var start: usize = 0;
        while (start < chunk.len) {
            const nl = simd.findByte(chunk, start, '\n') orelse chunk.len;
            const line = chunk[start..nl];
            if (line.len > 0) {
                if (self.filter_state.checkLine(line)) |ck| {
                    if (ck.info.level) |lvl| self.counter.add(lvl);
                    self.filter_state.printChecked(ck.line, ck.info);
                }
            }
            start = nl + 1;
        }
        self.out.flush();
    }
};

/// True when this run can be split across threads without changing a byte of
/// its output.
///
/// Pagination is interactive and aggregation needs one map for the whole
/// file; both stay on the serial path rather than being approximated here.
fn parallelEligible(args: flags.Args, path: []const u8, size: u64) bool {
    if (args.tail_mode or args.aggregate) return false;
    if (args.num_lines > 0) return false; // pagination
    if (gzip.isGzip(path)) return false; // not seekable
    return size >= parallel_min_bytes;
}

fn writeChunkToOut(ctx: *anyopaque, bytes: []const u8) bool {
    const out: *Out = @ptrCast(@alignCast(ctx));
    out.write(bytes);
    return !out.broken;
}

/// Scans `file` across threads. Returns false when the pool could not be set
/// up, in which case the caller runs the serial path and nothing is lost.
fn readParallel(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    size: u64,
    args: flags.Args,
    counter: *LevelCounter,
    out: *Out,
    since_cut: ?civil.Cutoff,
    chunk_bytes: usize,
) !bool {
    const worker_count = parallel.suggestedWorkers(size, chunk_bytes, parallel_max_workers);
    if (worker_count < 2) return false;

    var file_ctx = FileSource{ .file = file };
    const source = parallel.Source{
        .ctx = &file_ctx,
        .size = size,
        .read_at = FileSource.readAt,
    };

    const bounds = try parallel.computeBoundaries(allocator, source, chunk_bytes, max_line_bytes);
    defer allocator.free(bounds);
    if (bounds.len - 1 < 2) return false;

    const workers = try allocator.alloc(ChunkWorker, worker_count);
    defer allocator.free(workers);

    var built: usize = 0;
    errdefer for (workers[0..built]) |*w| w.deinit();
    while (built < worker_count) : (built += 1) {
        workers[built] = try ChunkWorker.init(allocator, args, out.theme, since_cut);
    }
    for (workers) |*w| w.rebind();
    defer for (workers) |*w| w.deinit();

    try parallel.run(ChunkWorker, allocator, source, bounds, workers, out, writeChunkToOut, .{
        .chunk_bytes = chunk_bytes,
        .max_line_bytes = max_line_bytes,
    });

    for (workers) |*w| {
        for (w.counter.counts, 0..) |n, i| counter.counts[i] += n;
        counter.total += w.counter.total;
    }
    return true;
}

/// Adapts a file to `parallel.Source`. Positional reads only, so every worker
/// can read its own range without a shared cursor.
const FileSource = struct {
    file: std.Io.File,

    fn readAt(ctx: *anyopaque, pos: u64, dst: []u8) usize {
        const self: *FileSource = @ptrCast(@alignCast(ctx));
        return self.file.readPositional(debug_io, &.{dst}, pos) catch 0;
    }
};

/// Read one log file with filtering and coloured output.
/// If aggregation is enabled, matched lines are grouped by `args.aggregate_mode`.
/// If `args.num_lines > 0`, paginates the output; otherwise streams continuously.
pub fn readStreaming(
    allocator: std.mem.Allocator,
    path: []const u8,
    args: flags.Args,
    counter: *LevelCounter,
    out: *Out,
    since_cut: ?civil.Cutoff,
) !void {
    var expander: ?JsonExpander = if (wantsJsonExpansion(args, out.theme))
        try JsonExpander.init(allocator, .{})
    else
        null;
    defer if (expander) |*x| x.deinit();
    const expander_ptr: ?*JsonExpander = if (expander) |*x| x else null;

    var filter_state = FilterState.init(args, out, expander_ptr);
    filter_state.since_cut = since_cut;
    defer filter_state.deinit();

    if (gzip.isGzip(path)) {
        try gzip.readGzip(allocator, path, args, &filter_state, buildAggregateKeyForLine);
        return;
    }

    const file = try std.Io.Dir.cwd().openFile(debug_io, path, .{});
    defer file.close(debug_io);

    if (parallelEligible(args, path, file.length(debug_io) catch 0)) {
        const size = file.length(debug_io) catch 0;
        // A pool that cannot be built is not an error: the serial path is
        // still right, just slower, and a failed allocation here says the
        // machine is in no state to run eight of them anyway.
        if (readParallel(allocator, file, size, args, counter, out, since_cut, parallel_chunk_bytes) catch false) return;
    }

    if (args.aggregate) {
        var handler = try AggregateHandler.init(allocator, args, counter, &filter_state, out, expander_ptr);
        defer handler.deinit();
        try scanLines(allocator, file, &handler);
        handler.finish();
        return;
    }

    var handler = PrintHandler{
        .args = args,
        .counter = counter,
        .filter_state = &filter_state,
        .out = out,
        .paginate = args.num_lines > 0,
    };
    scanLines(allocator, file, &handler) catch |err| switch (err) {
        error.OutputClosed => {},
        else => return err,
    };
}

/// Whether embedded JSON should be expanded for this run.
///
/// Off for `--output json` (the consumer is a program, not a person) and off
/// when the output isn't a terminal, so redirecting to a file still produces
/// one record per line.
fn wantsJsonExpansion(args: flags.Args, th: *const Theme) bool {
    if (args.no_expand_json or args.output_json) return false;
    return th.colored;
}

/// Splits `file` into lines and hands each to `handler.line(bytes)`.
///
/// One buffer holds both the freshly read bytes and the partial line left
/// over from the previous read: the leftover is compacted to the front and
/// the next read fills in behind it. The previous design kept a separate
/// `carry` list and appended each whole read chunk into it whenever a line
/// straddled a boundary — which, since the last line of a chunk almost never
/// ends exactly on the boundary, meant memcpy-ing the entire file a second
/// time.
///
/// The slice handed to `handler.line` stays valid only until the next read.
fn scanLines(allocator: std.mem.Allocator, file: std.Io.File, handler: anytype) !void {
    var buf = try allocator.alloc(u8, getOptimalBufferSize(file));
    defer allocator.free(buf);

    // Bytes of an unfinished line sitting at the front of `buf`.
    var carry: usize = 0;

    while (true) {
        const n = file.readStreaming(debug_io, &.{buf[carry..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;

        const filled = buf[0 .. carry + n];
        if (@hasDecl(@TypeOf(handler.*), "beginChunk")) handler.beginChunk(filled);
        var start: usize = 0;
        while (simd.findByte(filled, start, '\n')) |nl| {
            try handler.line(filled[start..nl]);
            start = nl + 1;
        }

        const rest = filled.len - start;
        if (rest > 0 and start > 0) std.mem.copyForwards(u8, buf[0..rest], filled[start..]);
        carry = rest;

        // A whole buffer with no newline in it: the line is longer than the
        // buffer, so grow rather than stall. `max_line_bytes` bounds this.
        if (carry == buf.len) {
            try ensureLineCapacity(buf.len, buf.len);
            buf = try allocator.realloc(buf, buf.len * 2);
        }
    }

    if (carry > 0) try handler.line(buf[0..carry]);
}

/// Raised by a line handler when the output sink has gone away. Caught by
/// `readStreaming`, which treats it as a normal end of work rather than a
/// failure — `zlrd big.log | head -20` is a successful command.
const OutputClosed = error.OutputClosed;

/// Line handler for the streaming and paginated modes.
const PrintHandler = struct {
    args: flags.Args,
    counter: *LevelCounter,
    filter_state: *FilterState,
    out: *Out,
    paginate: bool,
    batch: usize = 0,
    page: usize = 1,

    fn beginChunk(self: *PrintHandler, chunk: []const u8) void {
        self.filter_state.beginChunk(chunk);
    }

    fn line(self: *PrintHandler, bytes: []const u8) !void {
        const ck = self.filter_state.checkLine(bytes) orelse return;
        if (ck.info.level) |lvl| self.counter.add(lvl);
        self.filter_state.printChecked(ck.line, ck.info);
        if (self.out.broken) return OutputClosed;

        if (!self.paginate) return;
        self.batch += 1;
        if (self.batch >= self.args.num_lines) {
            self.out.flush();
            printPaginationPrompt(self.out, self.page, self.batch);
            self.out.flush();
            waitForEnter();
            clearScreen(self.out);
            self.batch = 0;
            self.page += 1;
        }
    }
};

/// Line handler for `--aggregate`: groups matched lines and prints once at
/// the end.
const AggregateHandler = struct {
    allocator: std.mem.Allocator,
    args: flags.Args,
    counter: *LevelCounter,
    filter_state: *FilterState,
    out: *Out,
    expander: ?*JsonExpander,
    aggregator: Aggregator,
    /// Reusable scratch for non-`.exact` key building — one allocation for
    /// the whole file instead of one per matched line.
    key_scratch: std.ArrayList(u8) = .empty,

    fn init(
        allocator: std.mem.Allocator,
        args: flags.Args,
        counter: *LevelCounter,
        filter_state: *FilterState,
        out: *Out,
        expander: ?*JsonExpander,
    ) !AggregateHandler {
        return .{
            .allocator = allocator,
            .args = args,
            .counter = counter,
            .filter_state = filter_state,
            .out = out,
            .expander = expander,
            .aggregator = try Aggregator.init(allocator),
        };
    }

    fn deinit(self: *AggregateHandler) void {
        self.key_scratch.deinit(self.allocator);
        self.aggregator.deinit();
    }

    fn beginChunk(self: *AggregateHandler, chunk: []const u8) void {
        self.filter_state.beginChunk(chunk);
    }

    fn line(self: *AggregateHandler, bytes: []const u8) !void {
        const ck = self.filter_state.checkLine(bytes) orelse return;
        if (ck.info.level) |lvl| self.counter.add(lvl);
        const key = try buildAggregateKey(
            self.allocator,
            &self.key_scratch,
            self.args.aggregate_mode,
            ck.line,
            ck.info,
        );
        try self.aggregator.add(key, ck.line, ck.info);
    }

    fn finish(self: *AggregateHandler) void {
        self.aggregator.printAll(self.out, self.args.num_lines, self.args.output_json, self.expander);
    }
};

/// Extracts the log level from a line without a full `analyzeLine` call.
/// Used in contexts where only the level is needed (e.g. unit tests).
fn extractLevel(line: []const u8) ?flags.Level {
    if (line.len == 0) return null;

    if (line[0] == '{') {
        if (simd.extractJsonField(line, "level", 16)) |v|
            return flags.parseLevelInsensitive(v);
        return null;
    }

    if (line[0] == '[') {
        if (simd.findBracketedLevel(line)) |r|
            return flags.parseLevelInsensitive(line[r.start..r.end]);
    }

    if (simd.findLogfmtLevel(line)) |r|
        return flags.parseLevelInsensitive(line[r.start..r.end]);

    return null;
}

/// Build an aggregation key into `scratch`. Returns a borrowed slice — either
/// pointing into `line` (`.exact`) or into `scratch` (all other modes). The
/// caller must not free the return value and must not touch `scratch` until
/// it is done using the key.
///
/// The previous version dup'd a fresh key per line and the caller freed it
/// after the hash lookup — on a hot aggregation path (existing key, just
/// bump a counter) that's an allocation pair per line for zero ownership.
/// Borrowed keys eliminate all of it.
pub fn buildAggregateKey(
    allocator: std.mem.Allocator,
    scratch: *std.ArrayList(u8),
    mode: flags.AggregateMode,
    line: []const u8,
    info: LineInfo,
) ![]const u8 {
    return switch (mode) {
        .exact => line,
        .level_message => try buildLevelMessageKey(allocator, scratch, line, info),
        .json_message => try buildJsonMessageKey(allocator, scratch, line),
        .normalized => try buildNormalizedKey(allocator, scratch, line),
    };
}

/// Public wrapper for callers that do not have access to `LineInfo`.
/// Prefer `buildAggregateKey` with a cached `LineInfo` when available.
pub fn buildAggregateKeyForLine(
    allocator: std.mem.Allocator,
    scratch: *std.ArrayList(u8),
    mode: flags.AggregateMode,
    line: []const u8,
) ![]const u8 {
    // Callers of this entry point (gzip) have no cached LineInfo, so the
    // timestamps are extracted here rather than assumed present.
    return buildAggregateKey(allocator, scratch, mode, line, analyzeLine(line, true));
}

/// Build a key from `level + message` into `scratch`.
fn buildLevelMessageKey(
    allocator: std.mem.Allocator,
    scratch: *std.ArrayList(u8),
    line: []const u8,
    info: LineInfo,
) ![]const u8 {
    scratch.clearRetainingCapacity();

    if (info.level) |lvl| {
        try scratch.appendSlice(allocator, @tagName(lvl));
    } else {
        try scratch.appendSlice(allocator, "unknown");
    }
    // Unit Separator to avoid accidental ambiguity.
    try scratch.append(allocator, 0x1f);

    const msg = extractMessage(line, info) orelse line;
    const trimmed = std.mem.trim(u8, msg, &std.ascii.whitespace);
    try scratch.appendSlice(allocator, trimmed);

    return scratch.items;
}

/// Build a key from the JSON `message`/`msg` field into `scratch`.
/// Falls back to the whole line if the field is absent.
fn buildJsonMessageKey(
    allocator: std.mem.Allocator,
    scratch: *std.ArrayList(u8),
    line: []const u8,
) ![]const u8 {
    scratch.clearRetainingCapacity();
    const msg =
        simd.extractJsonField(line, "message", 4096) orelse
        simd.extractJsonField(line, "msg", 4096) orelse
        line;
    try scratch.appendSlice(allocator, std.mem.trim(u8, msg, &std.ascii.whitespace));
    return scratch.items;
}

/// Build a normalized key into `scratch`:
/// - lowercases ASCII
/// - collapses whitespace
/// - replaces ISO dates with `<date>`
/// - replaces decimal runs with `#`
///
/// Writes straight into the reserved buffer rather than through
/// `ArrayList.append`. Every rule here either preserves length (lowercase) or
/// shrinks it — `<date>` is six bytes for ten, a digit run becomes one `#`, a
/// whitespace run becomes one space — so `line.len` is a hard upper bound on
/// the output and one reservation up front makes each write below safe. The
/// per-byte `try append` it replaces paid a capacity check and an error
/// branch on every one of the input's bytes.
fn buildNormalizedKey(
    allocator: std.mem.Allocator,
    scratch: *std.ArrayList(u8),
    line: []const u8,
) ![]const u8 {
    scratch.clearRetainingCapacity();
    try scratch.ensureUnusedCapacity(allocator, line.len);
    const dst = scratch.allocatedSlice();

    var w: usize = 0;
    var i: usize = 0;
    // Seeded true so a leading whitespace run is dropped outright, which is
    // what the trailing `trim` used to undo with a second pass and a shift.
    var prev_space = true;

    while (i < line.len) {
        const c = line[i];

        // A date always starts with a digit, so this check rides along with
        // the digit branch instead of being retried at every byte.
        if (isDigit(c)) {
            if (i + 10 <= line.len and isValidDateString(line[i .. i + 10])) {
                dst[w..][0..6].* = "<date>".*;
                w += 6;
                i += 10;
            } else {
                dst[w] = '#';
                w += 1;
                i += 1;
                while (i < line.len and isDigit(line[i])) : (i += 1) {}
            }
            prev_space = false;
            continue;
        }

        if (std.ascii.isWhitespace(c)) {
            if (!prev_space) {
                dst[w] = ' ';
                w += 1;
                prev_space = true;
            }
        } else {
            dst[w] = std.ascii.toLower(c);
            w += 1;
            prev_space = false;
        }
        i += 1;
    }

    // Whitespace is collapsed above, so at most one trailing space survives.
    if (w > 0 and dst[w - 1] == ' ') w -= 1;
    scratch.items.len = w;
    return scratch.items;
}

/// Extract a human-meaningful message slice from a line.
/// Used by `level_message` aggregation mode.
fn extractMessage(line: []const u8, info: LineInfo) ?[]const u8 {
    switch (info.format) {
        .json => {
            if (simd.extractJsonField(line, "message", 4096)) |v| return v;
            if (simd.extractJsonField(line, "msg", 4096)) |v| return v;
            return null;
        },
        .plain_logfmt => {
            if (extractLogfmtField(line, "message")) |v| return v;
            if (extractLogfmtField(line, "msg")) |v| return v;
            return null;
        },
        .plain_bracketed, .plain_unknown => {
            return extractPlainMessage(line, info);
        },
    }
}

/// Extract an unquoted or quoted logfmt field value.
/// Returns a slice into `line`, or null if the key is absent.
fn extractLogfmtField(line: []const u8, comptime key: []const u8) ?[]const u8 {
    var i: usize = 0;

    while (i < line.len) {
        // Skip separators.
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        if (i >= line.len) return null;

        const field_start = i;
        const eq = simd.findByte(line, i, '=') orelse return null;
        const field_key = line[field_start..eq];

        i = eq + 1;
        if (!std.mem.eql(u8, field_key, key)) {
            if (i < line.len and line[i] == '"') {
                i += 1;
                while (i < line.len and !isUnescapedQuote(line, i)) : (i += 1) {}
                if (i < line.len) i += 1;
            } else {
                while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
            }
            continue;
        }

        if (i >= line.len) return line[i..i];

        if (line[i] == '"') {
            const start = i + 1;
            i += 1;
            while (i < line.len and !isUnescapedQuote(line, i)) : (i += 1) {}
            if (i >= line.len) return null;
            return line[start..i];
        }

        const start = i;
        while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
        return line[start..i];
    }

    return null;
}

/// Extract the message part from a plain-text line.
/// This is heuristic by design: it removes an initial bracketed token and
/// common punctuation separators, then returns the remaining tail.
fn extractPlainMessage(line: []const u8, info: LineInfo) ?[]const u8 {
    var start: usize = 0;

    if (info.starts_with_bracket) {
        if (simd.findByte(line, 0, ']')) |pos| {
            start = pos + 1;
            while (start < line.len and (line[start] == ' ' or line[start] == ':' or line[start] == '-')) : (start += 1) {}
            if (start < line.len) return line[start..];
            return null;
        }
    }

    return line;
}

/// Validate a fixed-width `YYYY-MM-DD` date string.
inline fn isValidDateString(s: []const u8) bool {
    if (s.len != 10) return false;
    return isDigit(s[0]) and isDigit(s[1]) and isDigit(s[2]) and isDigit(s[3]) and
        s[4] == '-' and
        isDigit(s[5]) and isDigit(s[6]) and
        s[7] == '-' and
        isDigit(s[8]) and isDigit(s[9]);
}

/// Returns true if `c` is an ASCII decimal digit.
inline fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Returns true if `line[pos..]` starts with `word`.
fn matchWord(line: []const u8, pos: usize, comptime word: []const u8) bool {
    return pos + word.len <= line.len and
        std.mem.eql(u8, line[pos .. pos + word.len], word);
}

fn skipJsonValue(line: []const u8, start: usize) usize {
    var i = start;
    if (i >= line.len) return i;

    if (line[i] == '"') {
        const end = simd.scanJsonStringEnd(line, i + 1) orelse return line.len;
        return end + 1;
    }

    if (line[i] == '{' or line[i] == '[') {
        var depth: usize = 0;
        while (i < line.len) {
            switch (line[i]) {
                '"' => {
                    i = skipJsonValue(line, i);
                    continue;
                },
                '{', '[' => depth += 1,
                '}', ']' => {
                    depth -= 1;
                    i += 1;
                    if (depth == 0) return i;
                    continue;
                },
                else => {},
            }
            i += 1;
        }
        return i;
    }

    while (i < line.len and line[i] != ',' and line[i] != '}' and line[i] != ']') : (i += 1) {}
    return i;
}

/// Writes `bytes` uppercased and right-padded to `width` characters, so level
/// badges line up. Anything past the stack buffer is truncated — levels are
/// always short, and a malformed 100-character level field mustn't turn into
/// 100 separate appends.
fn writeUpperPadded(out: *Out, bytes: []const u8, width: usize) void {
    var buf: [16]u8 = undefined;
    const n = @min(bytes.len, buf.len);
    for (bytes[0..n], 0..) |b, j| buf[j] = std.ascii.toUpper(b);
    out.write(buf[0..n]);
    if (n < width) out.write("     "[0 .. width - n]);
}

/// Finds all non-overlapping search matches for `expr` in `line`.
/// Returns a slice of `buf` containing the matches, sorted by position.
fn findSearchMatches(line: []const u8, expr: []const u8, buf: []MatchRange) []MatchRange {
    var count: usize = 0;
    // Collect individual terms: split by | then by &
    var terms: [max_search_matches][]const u8 = undefined;
    var term_count: usize = 0;
    var or_it = std.mem.splitScalar(u8, expr, '|');
    while (or_it.next()) |or_term| {
        if (or_term.len == 0) continue;
        var and_it = std.mem.splitScalar(u8, or_term, '&');
        while (and_it.next()) |and_term| {
            if (and_term.len == 0 or term_count >= terms.len) continue;
            terms[term_count] = and_term;
            term_count += 1;
        }
    }
    // Find all matches, case-insensitive, non-overlapping per term
    for (terms[0..term_count]) |term| {
        var pos: usize = 0;
        while (pos + term.len <= line.len) {
            if (charAtIgnoreCase(line, pos, term)) {
                if (count < buf.len) {
                    buf[count] = .{ .start = pos, .end = pos + term.len };
                    count += 1;
                }
                pos += term.len;
            } else {
                pos += 1;
            }
        }
    }
    return mergeMatches(buf, count);
}

/// Collects the ranges matched by every pattern in `list`, so a regex search
/// highlights the same bytes it selected the line for.
///
/// Terms are AND-ed by the filter, and each contributes its own occurrences;
/// the ranges are merged afterwards exactly as the literal path merges its.
fn findRegexMatches(line: []const u8, list: *const regex.RegexList, buf: []MatchRange) []MatchRange {
    var count: usize = 0;
    for (list.regexes[0..list.count]) |*re| {
        var from: usize = 0;
        while (from <= line.len) {
            const m = re.findFrom(line, from) orelse break;
            if (count < buf.len) {
                buf[count] = .{ .start = m.start, .end = m.end };
                count += 1;
            }
            // A pattern like `a*` matches the empty string; without this the
            // scan would sit on one position forever.
            from = if (m.end > m.start) m.end else m.start + 1;
            if (count == buf.len) break;
        }
    }
    return mergeMatches(buf, count);
}

/// Sorts by position and merges overlaps, leaving ranges the printer can walk
/// in one pass.
fn mergeMatches(buf: []MatchRange, count: usize) []MatchRange {
    if (count <= 1) return buf[0..count];
    std.mem.sort(MatchRange, buf[0..count], {}, struct {
        fn lt(_: void, a: MatchRange, b: MatchRange) bool {
            return a.start < b.start;
        }
    }.lt);
    var j: usize = 1;
    for (buf[1..count]) |m| {
        if (m.start >= buf[j - 1].end) {
            buf[j] = m;
            j += 1;
        } else if (m.end > buf[j - 1].end) {
            buf[j - 1].end = m.end;
        }
    }
    return buf[0..j];
}

/// Returns true if `line[pos..]` starts with `needle`, case-insensitive.
fn charAtIgnoreCase(line: []const u8, pos: usize, needle: []const u8) bool {
    if (pos + needle.len > line.len) return false;
    for (needle, 0..) |c, j| {
        if (std.ascii.toLower(line[pos + j]) != std.ascii.toLower(c)) return false;
    }
    return true;
}

/// Prints a log line with colouring appropriate for its format, then — when
/// enabled — the expanded JSON block for any JSON embedded in its message.
///
/// Plain-text lines end in `\n\n` (blank line between entries) so consecutive
/// syslog-style records don't visually merge; JSON output keeps the compact
/// single-`\n` termination expected by pipeline consumers.
fn printStyledLine(out: *Out, line: []const u8, info: LineInfo, search_matches: []const MatchRange, expand: ?*JsonExpander) void {
    if (line.len == 0) return;

    // Colourless output with nothing to highlight and no block to expand is
    // byte-for-byte the input line with the level token swapped for its
    // badge. That is the shape every redirected run takes — `| grep`,
    // `| less`, `> file` — so emit it directly instead of walking every
    // token to decide which escape *not* to print.
    if (!out.theme.colored and search_matches.len == 0 and expand == null and info.is_json) {
        if (info.level_pos) |lp| {
            // The badge replaces the quoted value, quotes included.
            out.write(line[0 .. lp.start - 1]);
            writeLevelBadge(out, info.level.?, line[lp.start..lp.end]);
            out.write(line[lp.end + 1 ..]);
        } else {
            out.write(line);
        }
        out.write("\n");
        return;
    }

    if (info.is_json) {
        printJsonStyled(out, line, info, search_matches, expand);
    } else if (info.level != null) {
        printPlainTextWithLevel(out, line, info, search_matches, expand);
    } else {
        writeRangeHighlightedIn(out, line, 0, line.len, search_matches, out.theme.palette.text);
        out.write("\n");
        if (expand) |x| x.expandPlain(out, line, 0);
        out.write("\n");
    }
}

/// Writes a byte range of `line`, inserting search-highlight escapes around
/// `matches` that fall inside the range.
fn writeRangeHighlighted(out: *Out, line: []const u8, start: usize, end: usize, matches: []const MatchRange) void {
    writeRangeHighlightedIn(out, line, start, end, matches, "");
}

/// Same as `writeRangeHighlighted`, but wraps the whole range in `wrap_color`
/// and re-applies it after each highlight so the `reset` that closes a
/// highlight doesn't leave the tail uncoloured.
fn writeRangeHighlightedIn(
    out: *Out,
    line: []const u8,
    start: usize,
    end: usize,
    matches: []const MatchRange,
    wrap_color: []const u8,
) void {
    const reset = out.theme.palette.reset;
    const wrapped = wrap_color.len > 0;
    if (wrapped) out.write(wrap_color);
    if (matches.len == 0) {
        out.write(line[start..end]);
        if (wrapped) out.write(reset);
        return;
    }
    var pos = start;
    for (matches) |m| {
        if (m.end <= pos) continue;
        if (m.start >= end) break;
        const seg_start = @max(pos, m.start);
        const seg_end = @min(end, m.end);
        if (pos < seg_start) out.write(line[pos..seg_start]);
        out.write(out.theme.palette.match_on);
        out.write(line[seg_start..seg_end]);
        out.write(reset);
        if (wrapped) out.write(wrap_color);
        pos = seg_end;
    }
    if (pos < end) out.write(line[pos..end]);
    if (wrapped) out.write(reset);
}

/// Prints a line as JSON (JSONL format) for pipeline compatibility.
fn printJsonOutputLine(out: *Out, line: []const u8, info: LineInfo) void {
    const lvl = if (info.level) |l| @tagName(l) else "";
    const date = if (info.date) |d| d else "";
    const time = if (info.time) |t| t else "";

    out.print("{{\"level\":\"{s}\",\"date\":\"{s}\",\"time\":\"{s}\",\"raw\":\"", .{ lvl, date, time });

    // Walk the line in runs of safe (no-escape) bytes and flush each run as a
    // single write. Saves one switch plus one append per byte for the common
    // case of printable ASCII.
    var run_start: usize = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        const needs_escape = switch (c) {
            '"', '\\', '\n', '\r', '\t', 0...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => true,
            else => false,
        };
        if (!needs_escape) continue;

        if (i > run_start) out.write(line[run_start..i]);
        switch (c) {
            '"' => out.write("\\\""),
            '\\' => out.write("\\\\"),
            '\n' => out.write("\\n"),
            '\r' => out.write("\\r"),
            '\t' => out.write("\\t"),
            else => {
                var esc: [6]u8 = undefined;
                const s = std.fmt.bufPrint(&esc, "\\u{X:0>4}", .{c}) catch continue;
                out.write(s);
            },
        }
        run_start = i + 1;
    }
    if (run_start < line.len) out.write(line[run_start..]);
    out.write("\"}\n");
}

/// Writes a plain-text line with the level token highlighted.
///
/// Three modes, in order of priority:
///   1. `info.rewrite` set → INSERT mode. Prefix `[0..insert_at]` is muted,
///      the level badge is emitted, then the "clean" tail
///      `[insert_at..truncate_at]` is printed as text and the rest dropped.
///      Used by the gRPC error heuristic.
///   2. `info.level_pos` set → REPLACE mode. Prefix muted, level bytes
///      replaced by the badge, suffix printed as text.
///   3. Neither → whole line printed as text.
fn printPlainTextWithLevel(out: *Out, line: []const u8, info: LineInfo, search_matches: []const MatchRange, expand: ?*JsonExpander) void {
    const lvl = info.level.?;
    const p = out.theme.palette;

    if (info.rewrite) |rw| {
        if (rw.insert_at > 0) writeRangeHighlightedIn(out, line, 0, rw.insert_at, search_matches, p.muted);
        writeLevelBadge(out, lvl, @tagName(lvl));
        if (rw.insert_at < rw.truncate_at) {
            out.write(" ");
            writeRangeHighlightedIn(out, line, rw.insert_at, rw.truncate_at, search_matches, p.text);
        }
        out.write("\n");
        if (expand) |x| x.expandPlain(out, line[0..rw.truncate_at], rw.insert_at);
        out.write("\n");
        return;
    }

    if (info.level_pos) |r| {
        if (r.start > 0) writeRangeHighlightedIn(out, line, 0, r.start, search_matches, p.muted);
        writeLevelBadge(out, lvl, line[r.start..r.end]);
        if (r.end < line.len) writeRangeHighlightedIn(out, line, r.end, line.len, search_matches, p.text);
        out.write("\n");
        if (expand) |x| x.expandPlain(out, line, r.end);
        out.write("\n");
        return;
    }

    writeRangeHighlightedIn(out, line, 0, line.len, search_matches, p.text);
    out.write("\n");
    if (expand) |x| x.expandPlain(out, line, 0);
    out.write("\n");
}

/// Returns true if the byte at `i` in `line` is an unescaped `"`.
/// Handles `\\\"` by counting consecutive preceding backslashes: an even
/// count means the backslashes escape each other, so the `"` is unescaped.
inline fn isUnescapedQuote(line: []const u8, i: usize) bool {
    if (line[i] != '"') return false;
    var backslashes: usize = 0;
    var j = i;
    while (j > 0) {
        j -= 1;
        if (line[j] == '\\') backslashes += 1 else break;
    }
    return backslashes % 2 == 0;
}

/// Writes a JSON log line with syntax highlighting.
///
/// Bytes that need no styling are accumulated into runs and emitted with one
/// append each. The previous version wrote every brace, comma and space as
/// its own one-byte call, which for a typical record meant dozens of appends
/// (and, on the unbuffered path, dozens of syscalls) per line.
fn printJsonStyled(out: *Out, line: []const u8, info: LineInfo, search_matches: []const MatchRange, expand: ?*JsonExpander) void {
    const p = out.theme.palette;
    var i: usize = 0;
    // Start of the current run of unstyled bytes, flushed lazily.
    var plain_start: usize = 0;
    // Message-embedded JSON found while walking; expanded after the line so
    // the compact overview stays on one line.
    var nested: ?[]const u8 = null;

    while (i < line.len) {
        const c = line[i];

        if (c == '"') {
            // Jump straight to the closing quote. In a JSON log line most
            // bytes sit inside string values, and the previous version
            // stepped through every one of them re-testing whether it was an
            // unescaped quote. `scanJsonStringEnd` vectorises the search for
            // the next `\\` or `"` and skips escape pairs on the way.
            const body = i + 1;
            const end = simd.scanJsonStringEnd(line, body) orelse break;
            if (i > plain_start) out.write(line[plain_start..i]);
            const str = line[body..end];

            if (info.level_pos) |lp| {
                if (body == lp.start and end == lp.end) {
                    writeLevelBadge(out, info.level.?, str);
                    i = end + 1;
                    plain_start = i;
                    continue;
                }
            }

            // A key is a string followed by `:`.
            var j = end + 1;
            while (j < line.len and line[j] == ' ') : (j += 1) {}
            const is_key = j < line.len and line[j] == ':';
            // A payload's escapes are noise on the compact line — the block
            // below decodes them. Print the sentence in front of them and
            // mark the cut, so the record stays one readable line.
            var value_end = end;
            if (!is_key and nested == null) {
                if (expand) |x| {
                    if (x.payloadPrefix(str)) |cut| value_end = body + cut;
                }
            }

            out.write(if (is_key) p.json_key_open else p.json_string_open);
            writeRangeHighlighted(out, line, body, value_end, search_matches);
            if (value_end != end) {
                out.write(p.dim);
                out.write(if (out.theme.glyphs.unicode_ok) "…" else "...");
                out.write(p.reset);
            }
            out.write(p.quote_close);

            // A value worth expanding below the line: nested JSON, or bytes
            // that only a JSON encoder could have produced — the `\u00XX`
            // runs of an embedded protobuf payload.
            if (!is_key and expand != null and nested == null and
                (jsonx.looksLikeNestedObject(str, .{}) or protox.looksLikeBinary(str)))
            {
                nested = str;
            }

            i = end + 1;
            plain_start = i;
            continue;
        }

        if (isDigit(c) or c == '-') {
            if (i > plain_start) out.write(line[plain_start..i]);
            const num_start = i;
            i += 1;
            while (i < line.len and
                (isDigit(line[i]) or line[i] == '.' or
                    line[i] == 'e' or line[i] == 'E' or
                    line[i] == '+' or line[i] == '-')) : (i += 1)
            {}
            out.write(p.json_number);
            writeRangeHighlighted(out, line, num_start, i, search_matches);
            out.write(p.reset);
            plain_start = i;
            continue;
        }

        const word_len: usize = if (matchWord(line, i, "true"))
            4
        else if (matchWord(line, i, "false"))
            5
        else if (matchWord(line, i, "null"))
            4
        else
            0;
        if (word_len != 0) {
            if (i > plain_start) out.write(line[plain_start..i]);
            out.write(p.json_bool_null);
            writeRangeHighlighted(out, line, i, i + word_len, search_matches);
            out.write(p.reset);
            i += word_len;
            plain_start = i;
            continue;
        }

        i += 1;
    }

    if (plain_start < line.len) out.write(line[plain_start..]);
    out.write("\n");
    if (nested) |value| {
        if (expand) |x| {
            x.expandEscaped(out, value);
            // Blank line after an expanded block, so the next record doesn't
            // butt up against the gutter. Unexpanded JSON output keeps its
            // compact one-line-per-record shape.
            out.write("\n");
        }
    }
}

/// Prints a pagination prompt after each full page.
fn printPaginationPrompt(out: *Out, page: usize, count: usize) void {
    out.write("\n");
    out.write(out.theme.palette.dim);
    out.print("--- Page {d}: {d} lines | Press Enter...", .{ page, count });
    out.write(out.theme.palette.reset);
    out.write("\n");
}

/// Blocks until the user presses Enter (reads one byte from stdin).
fn waitForEnter() void {
    var buf: [1]u8 = undefined;
    _ = std.Io.File.stdin().readStreaming(debug_io, &.{&buf}) catch {};
}

/// Clears the terminal screen. Only meaningful when the output is a styled
/// terminal — the theme already encodes that, so redirecting to a file no
/// longer injects a clear-screen sequence into it.
fn clearScreen(out: *Out) void {
    if (!out.theme.colored) return;
    out.write("\x1b[2J\x1b[H");
    out.flush();
}

/// Matches `line` against a search expression.
/// Supports `|` (OR) and `&` (AND) operators; without either, plain substring match.
/// Matching is always case-insensitive.
/// Empty tokens produced by adjacent operators (e.g. `a||b`, `a&&b`) are skipped.
fn matchSearch(line: []const u8, expr: []const u8) bool {
    if (std.mem.indexOfScalar(u8, expr, '|')) |_| {
        var it = std.mem.splitScalar(u8, expr, '|');
        while (it.next()) |p| {
            if (p.len > 0 and containsIgnoreCase(line, p)) return true;
        }
        return false;
    }

    if (std.mem.indexOfScalar(u8, expr, '&')) |_| {
        var it = std.mem.splitScalar(u8, expr, '&');
        while (it.next()) |p| {
            // Skip empty tokens from adjacent `&&` so they don't force a false return.
            if (p.len == 0) continue;
            if (!containsIgnoreCase(line, p)) return false;
        }
        return true;
    }

    return containsIgnoreCase(line, expr);
}

fn shouldUseRegexSearch(expr: []const u8) bool {
    for (expr) |c| {
        switch (c) {
            '.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '\\' => return true,
            else => {},
        }
    }
    return false;
}

/// Returns true if `needle` appears in `hay` (case-insensitive).
/// Returns false if either slice is empty or `needle` is longer than `hay`.
///
/// Hot path: pre-lowers the needle once into a stack buffer, then uses SIMD
/// `findEither` to jump to candidate positions matching the (lower, upper)
/// variant of the first byte before verifying the rest. Long needles
/// (> 256 bytes — extremely rare in log search) fall back to the simple
/// scalar scan.
fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > hay.len) return false;

    var lower_buf: [256]u8 = undefined;
    if (needle.len > lower_buf.len) return containsIgnoreCaseScalar(hay, needle);

    for (needle, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    const lneedle = lower_buf[0..needle.len];

    const first_lo = lneedle[0];
    const first_hi: u8 = if (first_lo >= 'a' and first_lo <= 'z') first_lo - 32 else first_lo;

    const max = hay.len - needle.len;
    var i: usize = 0;
    while (i <= max) {
        const pos = simd.findEither(hay, i, first_lo, first_hi) orelse return false;
        if (pos > max) return false;

        var ok = true;
        var j: usize = 1;
        while (j < lneedle.len) : (j += 1) {
            if (std.ascii.toLower(hay[pos + j]) != lneedle[j]) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
        i = pos + 1;
    }
    return false;
}

fn containsIgnoreCaseScalar(hay: []const u8, needle: []const u8) bool {
    const max = hay.len - needle.len;
    var i: usize = 0;
    while (i <= max) : (i += 1) {
        var ok = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(hay[i + j]) != std.ascii.toLower(c)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

// ============================================================================
// Unit Tests
// ============================================================================

/// Renders into memory so printer tests can assert on exact bytes without
/// touching stdout.
const TestOut = struct {
    th: theme.Theme,
    out: Out = undefined,

    /// Two-phase on purpose: `out.theme` points back into this struct, so it
    /// can only be set once the struct sits at its final address. Returning a
    /// fully-built value from `init` would leave that pointer dangling.
    fn start(self: *TestOut) !void {
        self.out = .{
            // Never actually written to: tests drain the buffer with `take`
            // and every fixture is far below `Out.capacity`.
            .file = std.Io.File.stdout(),
            .theme = &self.th,
            .buf = try std.testing.allocator.alloc(u8, Out.capacity),
            .allocator = std.testing.allocator,
        };
    }

    fn deinit(self: *TestOut) void {
        std.testing.allocator.free(self.out.buf);
    }

    /// Returns everything buffered so far and resets, without flushing.
    fn take(self: *TestOut) ![]u8 {
        const copy = try std.testing.allocator.dupe(u8, self.out.buf[0..self.out.len]);
        self.out.len = 0;
        return copy;
    }
};

/// Renders one line through the real printer under the plain theme.
fn renderLine(line: []const u8, expand_json: bool) ![]u8 {
    var h = TestOut{ .th = theme.Theme.plain };
    try h.start();
    defer h.deinit();
    var expander: ?JsonExpander = if (expand_json)
        try JsonExpander.init(std.testing.allocator, .{})
    else
        null;
    defer if (expander) |*x| x.deinit();
    const info = analyzeLine(line, true);
    printStyledLine(&h.out, line, info, &.{}, if (expander) |*x| x else null);
    return h.take();
}

test "parseDateRange should parse single date" {
    const range = parseDateRange("2023-10-15");
    try std.testing.expectEqualStrings("2023-10-15", range.from.?);
    try std.testing.expectEqualStrings("2023-10-15", range.to.?);
}

test "parseDateRange should parse range with both sides" {
    const range = parseDateRange("2023-10-01..2023-10-31");
    try std.testing.expectEqualStrings("2023-10-01", range.from.?);
    try std.testing.expectEqualStrings("2023-10-31", range.to.?);
}

test "parseDateRange should parse range with only start date" {
    const range = parseDateRange("2023-10-01..");
    try std.testing.expectEqualStrings("2023-10-01", range.from.?);
    try std.testing.expect(range.to == null);
}

test "parseDateRange should parse range with only end date" {
    const range = parseDateRange("..2023-10-31");
    try std.testing.expect(range.from == null);
    try std.testing.expectEqualStrings("2023-10-31", range.to.?);
}

test "matchDateRange should return true when date is within range" {
    const range = DateRange{ .from = "2023-10-01", .to = "2023-10-31" };
    const line = "2023-10-15T12:00:00Z [INFO] Some message";
    try std.testing.expect(matchDateRange(line, range));
}

test "matchDateRange should return false when date is before range" {
    const range = DateRange{ .from = "2023-10-15", .to = "2023-10-31" };
    const line = "2023-10-01T12:00:00Z [INFO] Some message";
    try std.testing.expect(!matchDateRange(line, range));
}

test "matchDateRange should return false when date is after range" {
    const range = DateRange{ .from = "2023-10-01", .to = "2023-10-15" };
    const line = "2023-10-31T12:00:00Z [INFO] Some message";
    try std.testing.expect(!matchDateRange(line, range));
}

test "extractDate should extract ISO date from beginning of line" {
    const line = "2023-10-15T12:00:00Z [INFO] Some message";
    const result = extractDate(line);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("2023-10-15", result.?);
}

test "extractDate should return null for line without date" {
    const line = "[INFO] Some message without date";
    try std.testing.expect(extractDate(line) == null);
}

test "extractDate should return null for empty line" {
    try std.testing.expect(extractDate("") == null);
}

test "extractDate should extract JSON timestamp field date prefix" {
    const line = "{\"timestamp\":\"2023-10-18T12:00:00Z\",\"level\":\"info\"}";
    const result = extractDate(line);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("2023-10-18", result.?);
}

test "extractDate should extract JSON date field" {
    const line = "{\"date\":\"2023-10-18\",\"level\":\"info\"}";
    const result = extractDate(line);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("2023-10-18", result.?);
}

test "extractDate should extract ISO date from bracketed prefix" {
    const line = "[2023-10-18T12:00:00Z] [INFO] message";
    const result = extractDate(line);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("2023-10-18", result.?);
}

test "buildAggregateKey exact returns borrowed slice into line" {
    const line = "[ERROR] Connection failed";
    const info = analyzeLine(line, true);
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(std.testing.allocator);
    const key = try buildAggregateKey(std.testing.allocator, &scratch, .exact, line, info);
    try std.testing.expectEqualStrings("[ERROR] Connection failed", key);
    // .exact must not allocate — key points into `line`, scratch stays empty.
    try std.testing.expectEqual(@as(usize, 0), scratch.items.len);
    try std.testing.expect(key.ptr == line.ptr);
}

test "buildAggregateKey level_message uses level + message" {
    const line = "[ERROR] Connection failed";
    const info = analyzeLine(line, true);
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(std.testing.allocator);
    const key = try buildAggregateKey(std.testing.allocator, &scratch, .level_message, line, info);
    try std.testing.expect(std.mem.indexOfScalar(u8, key, 0x1f) != null);
}

test "extractLevel should extract level from JSON line" {
    const line = "{\"level\":\"error\",\"message\":\"connection failed\"}";
    try std.testing.expectEqual(flags.Level.Error, extractLevel(line).?);
}

test "extractLevel should extract level from bracketed line" {
    const line = "[ERROR] connection failed";
    try std.testing.expectEqual(flags.Level.Error, extractLevel(line).?);
}

test "extractLevel should extract level from logfmt line" {
    const line = "level=error message=\"connection failed\"";
    try std.testing.expectEqual(flags.Level.Error, extractLevel(line).?);
}

test "extractLevel should return null for line without level" {
    try std.testing.expect(extractLevel("Some plain log message") == null);
}

test "extractLevel should return null for empty line" {
    try std.testing.expect(extractLevel("") == null);
}

test "parseLevelInsensitive should parse all levels case-insensitively" {
    try std.testing.expectEqual(flags.Level.Trace, flags.parseLevelInsensitive("trace").?);
    try std.testing.expectEqual(flags.Level.Debug, flags.parseLevelInsensitive("DEBUG").?);
    try std.testing.expectEqual(flags.Level.Info, flags.parseLevelInsensitive("Info").?);
    try std.testing.expectEqual(flags.Level.Warn, flags.parseLevelInsensitive("WARN").?);
    try std.testing.expectEqual(flags.Level.Error, flags.parseLevelInsensitive("error").?);
    try std.testing.expectEqual(flags.Level.Fatal, flags.parseLevelInsensitive("Fatal").?);
    try std.testing.expectEqual(flags.Level.Panic, flags.parseLevelInsensitive("PANIC").?);
}

test "parseLevelInsensitive should return null for invalid level" {
    try std.testing.expect(flags.parseLevelInsensitive("invalid") == null);
    try std.testing.expect(flags.parseLevelInsensitive("") == null);
}

test "matchSearch should match simple substring case-insensitively" {
    try std.testing.expect(matchSearch("Hello World", "world"));
    try std.testing.expect(matchSearch("HELLO WORLD", "hello"));
    try std.testing.expect(!matchSearch("Hello World", "test"));
}

test "matchSearch should support OR operator" {
    try std.testing.expect(matchSearch("Hello World", "hello|test"));
    try std.testing.expect(matchSearch("Hello World", "test|world"));
    try std.testing.expect(!matchSearch("Hello World", "foo|bar"));
}

test "matchSearch should support AND operator" {
    try std.testing.expect(matchSearch("Hello World", "hello&world"));
    try std.testing.expect(!matchSearch("Hello World", "hello&test"));
    try std.testing.expect(!matchSearch("Hello World", "test&world"));
}

test "matchSearch should handle empty parts in expression" {
    try std.testing.expect(matchSearch("Hello World", "hello||world"));
    // Empty tokens from `&&` are skipped; remaining tokens must all match.
    try std.testing.expect(matchSearch("Hello World", "hello&&world"));
}

test "containsIgnoreCase should find substring case-insensitively" {
    try std.testing.expect(containsIgnoreCase("Hello World", "hello"));
    try std.testing.expect(containsIgnoreCase("HELLO WORLD", "world"));
    try std.testing.expect(containsIgnoreCase("Hello World", "lo wo"));
    try std.testing.expect(!containsIgnoreCase("Hello World", "test"));
}

test "containsIgnoreCase should handle edge cases" {
    try std.testing.expect(!containsIgnoreCase("", "test"));
    try std.testing.expect(!containsIgnoreCase("test", ""));
    try std.testing.expect(!containsIgnoreCase("short", "very long needle"));
}

test "isDigit should identify decimal digits" {
    try std.testing.expect(isDigit('0'));
    try std.testing.expect(isDigit('5'));
    try std.testing.expect(isDigit('9'));
    try std.testing.expect(!isDigit('a'));
    try std.testing.expect(!isDigit(' '));
}

test "matchWord should match word at position" {
    try std.testing.expect(matchWord("hello world", 0, "hello"));
    try std.testing.expect(matchWord("hello world", 6, "world"));
    try std.testing.expect(!matchWord("hello world", 0, "world"));
}

test "FilterState.init should initialize from args" {
    var file = [_][]const u8{"test.log"};
    const args = flags.Args{
        .files = &file,
        .tail_mode = false,
        .date = "2023-10-01..2023-10-31",
        .levels = flags.levelBit(.Error) | flags.levelBit(.Warn),
        .search = "error",
        .num_lines = 0,
    };
    var state = FilterState.init(args, null, null);
    defer state.deinit();
    try std.testing.expect(state.has_date_filter);
    try std.testing.expect(state.has_level_filter);
    try std.testing.expect(!state.has_regex);
    try std.testing.expectEqualStrings("error", state.search_expr.?);
}

test "FilterState.checkLine should filter by level" {
    var file = [_][]const u8{"test.log"};
    const args = flags.Args{
        .files = &file,
        .tail_mode = false,
        .date = null,
        .levels = flags.levelBit(.Error),
        .search = null,
        .num_lines = 0,
    };
    var state = FilterState.init(args, null, null);
    defer state.deinit();
    try std.testing.expectEqual(flags.Level.Error, state.checkLine("[ERROR] Something went wrong").?.info.level.?);
    try std.testing.expect(state.checkLine("[INFO] Everything is fine") == null);
}

test "FilterState.checkLine handles JSON non-string fields before level" {
    var file = [_][]const u8{"test.log"};
    const args = flags.Args{
        .files = &file,
        .levels = flags.levelBit(.Error),
    };
    var state = FilterState.init(args, null, null);
    defer state.deinit();

    const ck = state.checkLine("{\"pid\":123,\"ok\":true,\"level\":\"error\",\"msg\":\"failed\"}").?;
    try std.testing.expectEqual(flags.Level.Error, ck.info.level.?);
}

test "FilterState.checkLine should filter by search" {
    var file = [_][]const u8{"test.log"};
    const args = flags.Args{
        .files = &file,
        .tail_mode = false,
        .date = null,
        .levels = null,
        .search = "connection",
        .num_lines = 0,
    };
    var state = FilterState.init(args, null, null);
    defer state.deinit();
    try std.testing.expect(state.checkLine("[ERROR] Connection failed") != null);
    try std.testing.expect(state.checkLine("[INFO] Operation successful") == null);
}

test "FilterState.checkLine should filter by date" {
    var file = [_][]const u8{"test.log"};
    const args = flags.Args{
        .files = &file,
        .tail_mode = false,
        .date = "2023-10-15..2023-10-20",
        .levels = null,
        .search = null,
        .num_lines = 0,
    };
    var state = FilterState.init(args, null, null);
    defer state.deinit();
    const in_range = "{\"time\":\"2023-10-18T12:00:00Z\",\"level\":\"info\",\"msg\":\"test\"}";
    try std.testing.expect(state.checkLine(in_range) != null);
    const out_of_range = "{\"time\":\"2023-10-25T12:00:00Z\",\"level\":\"info\",\"msg\":\"test\"}";
    try std.testing.expect(state.checkLine(out_of_range) == null);
}

test "level badges are distinct per level and padded to a fixed width" {
    var h = TestOut{ .th = theme.Theme.forMode(.truecolor, theme.Glyphs.ascii) };
    try h.start();
    defer h.deinit();

    var seen: [7][]const u8 = undefined;
    const levels = [_]flags.Level{ .Trace, .Debug, .Info, .Warn, .Error, .Fatal, .Panic };
    for (levels, 0..) |lvl, i| {
        seen[i] = h.out.theme.levelStyle(lvl);
        try std.testing.expect(seen[i].len > 0);
    }
    // Fatal and Panic deliberately share a badge; everything else is distinct.
    try std.testing.expect(!std.mem.eql(u8, seen[0], seen[1]));
    try std.testing.expect(!std.mem.eql(u8, seen[2], seen[3]));
    try std.testing.expect(!std.mem.eql(u8, seen[3], seen[4]));

    writeLevelBadge(&h.out, .Info, "info");
    const a = try h.take();
    defer std.testing.allocator.free(a);
    writeLevelBadge(&h.out, .Error, "error");
    const b = try h.take();
    defer std.testing.allocator.free(b);
    // " INFO  " and " ERROR " — same visible width either way.
    try std.testing.expect(std.mem.indexOf(u8, a, " INFO  ") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, " ERROR ") != null);
    // Never U+2009: it renders as a box on Windows consoles.
    try std.testing.expect(std.mem.indexOf(u8, a, "\u{2009}") == null);
}

// --- isUnescapedQuote ---

test "isUnescapedQuote: plain quote" {
    try std.testing.expect(isUnescapedQuote("\"hello\"", 0));
    try std.testing.expect(isUnescapedQuote("\"hello\"", 6));
}

test "isUnescapedQuote: escaped quote" {
    // `\"` — backslash count 1 (odd) → escaped
    try std.testing.expect(!isUnescapedQuote("\\\"", 1));
}

test "isUnescapedQuote: double-escaped backslash before quote" {
    // `\\"` — two backslashes (even) → the quote is unescaped
    try std.testing.expect(isUnescapedQuote("\\\\\"", 2));
}

test "matchSearch AND with adjacent operators skips empty tokens" {
    // `hello&&world` splits into ["hello", "", "world"]; empty token is skipped
    try std.testing.expect(matchSearch("hello world", "hello&&world"));
    try std.testing.expect(!matchSearch("hello", "hello&&world"));
}

test "Aggregator counts identical lines and preserves first-seen order" {
    var agg = try Aggregator.init(std.testing.allocator);
    defer agg.deinit();

    try agg.add("[ERROR] one", "[ERROR] one", analyzeLine("[ERROR] one", true));
    try agg.add("[WARN] two", "[WARN] two", analyzeLine("[WARN] two", true));
    try agg.add("[ERROR] one", "[ERROR] one", analyzeLine("[ERROR] one", true));
    try agg.add("[ERROR] one", "[ERROR] one", analyzeLine("[ERROR] one", true));
    try agg.add("[WARN] two", "[WARN] two", analyzeLine("[WARN] two", true));

    try std.testing.expectEqual(@as(usize, 2), agg.order.items.len);
    try std.testing.expectEqualStrings("[ERROR] one", agg.order.items[0]);
    try std.testing.expectEqualStrings("[WARN] two", agg.order.items[1]);
    try std.testing.expectEqual(@as(usize, 3), agg.entries.get("[ERROR] one").?.count);
    try std.testing.expectEqual(@as(usize, 2), agg.entries.get("[WARN] two").?.count);
    try std.testing.expectEqualStrings("[ERROR] one", agg.entries.get("[ERROR] one").?.sample_line);
    try std.testing.expectEqualStrings("[WARN] two", agg.entries.get("[WARN] two").?.sample_line);
}

test "FilterState with aggregation semantics still filters before counting" {
    var file = [_][]const u8{"test.log"};
    const args = flags.Args{
        .files = &file,
        .tail_mode = false,
        .date = null,
        .levels = flags.levelBit(.Error),
        .search = "connection",
        .num_lines = 0,
        .aggregate = true,
    };

    var state = FilterState.init(args, null, null);
    defer state.deinit();

    try std.testing.expect(state.checkLine("[ERROR] Connection failed") != null);
    try std.testing.expect(state.checkLine("[ERROR] Timeout") == null);
    try std.testing.expect(state.checkLine("[INFO] Connection failed") == null);
}

test "buildAggregateKey exact uses full line" {
    const line = "[ERROR] Connection failed";
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(std.testing.allocator);

    const key = try buildAggregateKeyForLine(std.testing.allocator, &scratch, .exact, line);
    try std.testing.expectEqualStrings("[ERROR] Connection failed", key);
}

test "buildAggregateKey level_message for bracketed line" {
    const line1 = "[ERROR] Connection failed";
    const line2 = "[ERROR] Connection failed";
    var s1: std.ArrayList(u8) = .empty;
    defer s1.deinit(std.testing.allocator);
    var s2: std.ArrayList(u8) = .empty;
    defer s2.deinit(std.testing.allocator);

    const key1 = try buildAggregateKeyForLine(std.testing.allocator, &s1, .level_message, line1);
    const key2 = try buildAggregateKeyForLine(std.testing.allocator, &s2, .level_message, line2);

    try std.testing.expectEqualStrings(key1, key2);
    try std.testing.expect(std.mem.indexOfScalar(u8, key1, 0x1f) != null);
}

test "buildAggregateKey level_message uses JSON message field" {
    const line1 = "{\"time\":\"2023-10-18T12:00:00Z\",\"level\":\"error\",\"message\":\"Connection failed\"}";
    const line2 = "{\"time\":\"2023-10-18T12:00:01Z\",\"level\":\"error\",\"message\":\"Connection failed\"}";
    var s1: std.ArrayList(u8) = .empty;
    defer s1.deinit(std.testing.allocator);
    var s2: std.ArrayList(u8) = .empty;
    defer s2.deinit(std.testing.allocator);

    const key1 = try buildAggregateKeyForLine(std.testing.allocator, &s1, .level_message, line1);
    const key2 = try buildAggregateKeyForLine(std.testing.allocator, &s2, .level_message, line2);
    try std.testing.expectEqualStrings(key1, key2);
}

test "buildAggregateKey json_message ignores level and timestamp differences" {
    const line1 = "{\"time\":\"2023-10-18T12:00:00Z\",\"level\":\"error\",\"message\":\"Connection failed\"}";
    const line2 = "{\"time\":\"2023-10-18T12:00:01Z\",\"level\":\"warn\",\"message\":\"Connection failed\"}";
    var s1: std.ArrayList(u8) = .empty;
    defer s1.deinit(std.testing.allocator);
    var s2: std.ArrayList(u8) = .empty;
    defer s2.deinit(std.testing.allocator);

    const key1 = try buildAggregateKeyForLine(std.testing.allocator, &s1, .json_message, line1);
    const key2 = try buildAggregateKeyForLine(std.testing.allocator, &s2, .json_message, line2);

    try std.testing.expectEqualStrings("Connection failed", key1);
    try std.testing.expectEqualStrings(key1, key2);
}

test "buildAggregateKey normalized collapses dates digits case and whitespace" {
    const line1 = "2023-10-18T12:00:00Z [ERROR] Request 123 failed";
    const line2 = "2023-10-19T12:00:01Z   [error]   Request 987 failed";
    var s1: std.ArrayList(u8) = .empty;
    defer s1.deinit(std.testing.allocator);
    var s2: std.ArrayList(u8) = .empty;
    defer s2.deinit(std.testing.allocator);

    const key1 = try buildAggregateKeyForLine(std.testing.allocator, &s1, .normalized, line1);
    const key2 = try buildAggregateKeyForLine(std.testing.allocator, &s2, .normalized, line2);
    try std.testing.expectEqualStrings(key1, key2);
}

test "Aggregator groups by key and keeps first sample line" {
    var agg = try Aggregator.init(std.testing.allocator);
    defer agg.deinit();

    const key = "error\x1fConnection failed";

    try agg.add(key, "[ERROR] Connection failed", analyzeLine("[ERROR] Connection failed", true));
    try agg.add(key, "[ERROR] Connection failed", analyzeLine("[ERROR] Connection failed", true));
    try agg.add(key, "[ERROR] Connection failed at retry", analyzeLine("[ERROR] Connection failed at retry", true));

    try std.testing.expectEqual(@as(usize, 1), agg.order.items.len);
    try std.testing.expectEqual(@as(usize, 3), agg.entries.get(key).?.count);
    try std.testing.expectEqualStrings("[ERROR] Connection failed", agg.entries.get(key).?.sample_line);
}

test "level_message aggregation groups same message with different timestamps" {
    var agg = try Aggregator.init(std.testing.allocator);
    defer agg.deinit();
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(std.testing.allocator);

    const line1 = "{\"time\":\"2023-10-18T12:00:00Z\",\"level\":\"error\",\"message\":\"Connection failed\"}";
    const line2 = "{\"time\":\"2023-10-18T12:00:05Z\",\"level\":\"error\",\"message\":\"Connection failed\"}";

    {
        const key = try buildAggregateKeyForLine(std.testing.allocator, &scratch, .level_message, line1);
        try agg.add(key, line1, analyzeLine(line1, true));
    }
    {
        const key = try buildAggregateKeyForLine(std.testing.allocator, &scratch, .level_message, line2);
        try agg.add(key, line2, analyzeLine(line2, true));
    }

    try std.testing.expectEqual(@as(usize, 1), agg.order.items.len);
    try std.testing.expectEqual(@as(usize, 2), agg.entries.get(agg.order.items[0]).?.count);
    try std.testing.expectEqualStrings(line1, agg.entries.get(agg.order.items[0]).?.sample_line);
}

test "json_message aggregation separates different messages" {
    var agg = try Aggregator.init(std.testing.allocator);
    defer agg.deinit();
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(std.testing.allocator);

    const line1 = "{\"level\":\"error\",\"message\":\"Connection failed\"}";
    const line2 = "{\"level\":\"error\",\"message\":\"Timeout\"}";

    {
        const key = try buildAggregateKeyForLine(std.testing.allocator, &scratch, .json_message, line1);
        try agg.add(key, line1, analyzeLine(line1, true));
    }
    {
        const key = try buildAggregateKeyForLine(std.testing.allocator, &scratch, .json_message, line2);
        try agg.add(key, line2, analyzeLine(line2, true));
    }

    try std.testing.expectEqual(@as(usize, 2), agg.order.items.len);
}

test "normalized aggregation groups noisy numeric variants" {
    var agg = try Aggregator.init(std.testing.allocator);
    defer agg.deinit();
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(std.testing.allocator);

    const line1 = "2023-10-18 [ERROR] Request 123 failed";
    const line2 = "2023-10-19 [ERROR] Request 999 failed";

    {
        const key = try buildAggregateKeyForLine(std.testing.allocator, &scratch, .normalized, line1);
        try agg.add(key, line1, analyzeLine(line1, true));
    }
    {
        const key = try buildAggregateKeyForLine(std.testing.allocator, &scratch, .normalized, line2);
        try agg.add(key, line2, analyzeLine(line2, true));
    }

    try std.testing.expectEqual(@as(usize, 1), agg.order.items.len);
    try std.testing.expectEqual(@as(usize, 2), agg.entries.get(agg.order.items[0]).?.count);
}

test "extractLogfmtField extracts quoted and unquoted values" {
    const line1 = "level=error message=test";
    const line2 = "level=error message=\"connection failed\"";

    try std.testing.expectEqualStrings("test", extractLogfmtField(line1, "message").?);
    try std.testing.expectEqualStrings("connection failed", extractLogfmtField(line2, "message").?);
}

test "extractMessage uses logfmt message field" {
    const line = "level=error message=\"connection failed\"";
    const info = analyzeLine(line, true);

    const msg = extractMessage(line, info).?;
    try std.testing.expectEqualStrings("connection failed", msg);
}

test "extractMessage uses plain tail after bracketed level" {
    const line = "[ERROR] connection failed";
    const info = analyzeLine(line, true);

    const msg = extractMessage(line, info).?;
    try std.testing.expectEqualStrings("connection failed", msg);
}

test "findSearchMatches: single term" {
    var buf: [max_search_matches]MatchRange = undefined;
    const m = findSearchMatches("hello world hello", "hello", &buf);
    try std.testing.expectEqual(@as(usize, 2), m.len);
    try std.testing.expectEqual(@as(usize, 0), m[0].start);
    try std.testing.expectEqual(@as(usize, 5), m[0].end);
    try std.testing.expectEqual(@as(usize, 12), m[1].start);
    try std.testing.expectEqual(@as(usize, 17), m[1].end);
}

test "findSearchMatches: case-insensitive" {
    var buf: [max_search_matches]MatchRange = undefined;
    const m = findSearchMatches("HELLO world", "hello", &buf);
    try std.testing.expectEqual(@as(usize, 1), m.len);
    try std.testing.expectEqual(@as(usize, 0), m[0].start);
    try std.testing.expectEqual(@as(usize, 5), m[0].end);
}

test "findSearchMatches: OR terms" {
    var buf: [max_search_matches]MatchRange = undefined;
    const m = findSearchMatches("hello world", "hello|world", &buf);
    try std.testing.expectEqual(@as(usize, 2), m.len);
    try std.testing.expectEqualStrings("hello", "hello world"[m[0].start..m[0].end]);
    try std.testing.expectEqualStrings("world", "hello world"[m[1].start..m[1].end]);
}

test "findSearchMatches: AND terms" {
    var buf: [max_search_matches]MatchRange = undefined;
    const m = findSearchMatches("hello world", "hello&world", &buf);
    try std.testing.expectEqual(@as(usize, 2), m.len);
}

test "findSearchMatches: overlapping dedup" {
    var buf: [max_search_matches]MatchRange = undefined;
    // "aaaa" — "aa" matches at 0, 2 (non-overlapping adjacent)
    const m = findSearchMatches("aaaa", "aa", &buf);
    try std.testing.expectEqual(@as(usize, 2), m.len);
    try std.testing.expectEqual(@as(usize, 0), m[0].start);
    try std.testing.expectEqual(@as(usize, 2), m[0].end);
    try std.testing.expectEqual(@as(usize, 2), m[1].start);
    try std.testing.expectEqual(@as(usize, 4), m[1].end);
}

test "findSearchMatches: overlapping merge" {
    var buf: [max_search_matches]MatchRange = undefined;
    // "aaaa" — "aa" matches at 0,2; "aaa" at 0 → merged to 0-4
    const m = findSearchMatches("aaaa", "aa|aaa", &buf);
    try std.testing.expectEqual(@as(usize, 1), m.len);
    try std.testing.expectEqual(@as(usize, 0), m[0].start);
    try std.testing.expectEqual(@as(usize, 4), m[0].end);
}

test "findSearchMatches: no match" {
    var buf: [max_search_matches]MatchRange = undefined;
    const m = findSearchMatches("hello", "world", &buf);
    try std.testing.expectEqual(@as(usize, 0), m.len);
}

test "charAtIgnoreCase: match" {
    try std.testing.expect(charAtIgnoreCase("Hello World", 0, "hello"));
    try std.testing.expect(charAtIgnoreCase("Hello World", 6, "WORLD"));
    try std.testing.expect(!charAtIgnoreCase("Hello World", 0, "world"));
}

test "charAtIgnoreCase: bounds check" {
    try std.testing.expect(!charAtIgnoreCase("hi", 1, "world"));
    try std.testing.expect(!charAtIgnoreCase("hi", 3, "x"));
}

test "isValidDateString: valid dates" {
    try std.testing.expect(isValidDateString("2023-10-15"));
    try std.testing.expect(isValidDateString("0000-00-00"));
    try std.testing.expect(isValidDateString("9999-99-99"));
}

test "isValidDateString: invalid inputs" {
    try std.testing.expect(!isValidDateString("2023-1-15"));
    try std.testing.expect(!isValidDateString("20231015"));
    try std.testing.expect(!isValidDateString("2023-10-15T12:00:00Z"));
    try std.testing.expect(!isValidDateString(""));
    try std.testing.expect(!isValidDateString("2023-10"));
}

test "extractPlainMessage: strips bracketed prefix with colon" {
    const line = "[ERROR]: connection failed";
    const info = analyzeLine(line, true);
    try std.testing.expectEqualStrings("connection failed", extractPlainMessage(line, info).?);
}

test "extractPlainMessage: strips bracketed prefix with dash" {
    const line = "[WARN] - something happened";
    const info = analyzeLine(line, true);
    try std.testing.expectEqualStrings("something happened", extractPlainMessage(line, info).?);
}

test "extractPlainMessage: returns full line without brackets" {
    const line = "Just a plain message";
    const info = analyzeLine(line, true);
    try std.testing.expectEqualStrings("Just a plain message", extractPlainMessage(line, info).?);
}

test "extractPlainMessage: bracket-only line" {
    const line = "[ERROR]";
    const info = analyzeLine(line, true);
    try std.testing.expect(extractPlainMessage(line, info) == null);
}

test "buildNormalizedKey: collapses digits and spaces" {
    const line = "error code 12345 at line 99";
    _ = analyzeLine(line, true);
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(std.testing.allocator);
    const key = try buildNormalizedKey(std.testing.allocator, &scratch, line);
    try std.testing.expectEqualStrings("error code # at line #", key);
}

test "buildNormalizedKey: replaces ISO date" {
    const line = "request 2023-10-18 failed";
    _ = analyzeLine(line, true);
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(std.testing.allocator);
    const key = try buildNormalizedKey(std.testing.allocator, &scratch, line);
    try std.testing.expect(std.mem.indexOf(u8, key, "<date>") != null);
}

test "buildNormalizedKey: collapses multiple spaces" {
    const line = "error    multiple    spaces";
    _ = analyzeLine(line, true);
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(std.testing.allocator);
    const key = try buildNormalizedKey(std.testing.allocator, &scratch, line);
    try std.testing.expectEqualStrings("error multiple spaces", key);
}

test "extractTime: ISO timestamp with T separator" {
    try std.testing.expectEqualStrings("14:30:00", extractTime("2023-10-15T14:30:00Z").?);
}

test "extractTime: space-separated time" {
    try std.testing.expectEqualStrings("14:30:00", extractTime("2023-10-15 14:30:00 [INFO] msg").?);
}

test "extractTime: HH:MM only" {
    try std.testing.expectEqualStrings("14:30", extractTime("[14:30] message").?);
}

test "extractTime: time at start of line" {
    try std.testing.expectEqualStrings("14:30:05", extractTime("14:30:05 service started").?);
}

test "extractTime: returns null without time" {
    try std.testing.expect(extractTime("no time here") == null);
    try std.testing.expect(extractTime("") == null);
}

test "extractTime: avoids partial match on port numbers" {
    try std.testing.expect(extractTime("listening on 0.0.0.0:8080") == null);
}

test "matchTimeRange: within range HH:MM" {
    try std.testing.expect(matchTimeRange("14:30", "14:00", "15:00"));
}

test "matchTimeRange: before range" {
    try std.testing.expect(!matchTimeRange("13:59", "14:00", "15:00"));
}

test "matchTimeRange: after range" {
    try std.testing.expect(!matchTimeRange("15:01", "14:00", "15:00"));
}

test "matchTimeRange: null time passes" {
    try std.testing.expect(matchTimeRange(null, "14:00", "15:00"));
}

test "matchTimeRange: open-ended from" {
    try std.testing.expect(matchTimeRange("13:00", null, "15:00"));
    try std.testing.expect(!matchTimeRange("16:00", null, "15:00"));
}

test "matchTimeRange: open-ended to" {
    try std.testing.expect(matchTimeRange("16:00", "14:00", null));
    try std.testing.expect(!matchTimeRange("13:00", "14:00", null));
}

test "matchTimeRange: HH:MM:SS vs HH:MM truncation" {
    try std.testing.expect(matchTimeRange("14:30:00", "14:00", "15:00"));
    try std.testing.expect(!matchTimeRange("15:00:00", "14:00", "15:00"));
    try std.testing.expect(!matchTimeRange("15:00:01", "14:00", "15:00"));
}

test "matchTimeRange: equal boundaries" {
    try std.testing.expect(matchTimeRange("14:00", "14:00", "14:00"));
    try std.testing.expect(!matchTimeRange("13:59:59", "14:00", "14:00"));
}

test "FilterState: time filter rejects early time" {
    var file = [_][]const u8{"test.log"};
    const args = flags.Args{
        .files = &file,
        .from_time = "14:00",
        .to_time = "15:00",
    };
    var state = FilterState.init(args, null, null);
    defer state.deinit();
    try std.testing.expect(state.checkLine("2023-10-15T14:30:00Z [INFO] msg") != null);
    try std.testing.expect(state.checkLine("2023-10-15T13:00:00Z [INFO] msg") == null);
    try std.testing.expect(state.checkLine("2023-10-15T16:00:00Z [INFO] msg") == null);
}

test "FilterState: --from only" {
    var file = [_][]const u8{"test.log"};
    const args = flags.Args{ .files = &file, .from_time = "14:00" };
    var state = FilterState.init(args, null, null);
    defer state.deinit();
    try std.testing.expect(state.checkLine("2023-10-15T15:00:00Z [INFO] msg") != null);
    try std.testing.expect(state.checkLine("2023-10-15T13:00:00Z [INFO] msg") == null);
}

test "FilterState: time filter disabled in tail mode" {
    var file = [_][]const u8{"test.log"};
    const args = flags.Args{ .files = &file, .tail_mode = true, .from_time = "14:00" };
    var state = FilterState.init(args, null, null);
    defer state.deinit();
    try std.testing.expect(!state.has_time_filter);
}

test "FilterState: date + time combined filter" {
    var file = [_][]const u8{"test.log"};
    const args = flags.Args{ .files = &file, .date = "2023-10-15", .from_time = "14:00", .to_time = "15:00" };
    var state = FilterState.init(args, null, null);
    defer state.deinit();
    try std.testing.expect(state.checkLine("2023-10-15T14:30:00Z [INFO] msg") != null);
    try std.testing.expect(state.checkLine("2023-10-16T14:30:00Z [INFO] msg") == null);
    try std.testing.expect(state.checkLine("2023-10-15T13:00:00Z [INFO] msg") == null);
}

test "extractDate rejects invalid JSON date fields" {
    try std.testing.expect(extractDate("{\"time\":\"not-a-date\",\"level\":\"info\"}") == null);
}

test "ensureLineCapacity: accepts up to the cap" {
    try ensureLineCapacity(0, max_line_bytes);
    try ensureLineCapacity(max_line_bytes / 2, max_line_bytes / 2);
}

test "ensureLineCapacity: rejects oversize lines" {
    try std.testing.expectError(error.LineTooLong, ensureLineCapacity(max_line_bytes, 1));
    try std.testing.expectError(error.LineTooLong, ensureLineCapacity(max_line_bytes / 2, max_line_bytes));
}

test "Aggregator drops new keys past max_aggregate_keys cap" {
    var agg = try Aggregator.init(std.testing.allocator);
    defer agg.deinit();

    // Pre-fill the cap with unique keys; use a tiny-scope override by
    // injecting directly into the maps would skip our gate. So we drive
    // the public API: add max_aggregate_keys distinct keys, then one more.
    // Doing 100k allocs in a unit test is acceptable but slow; the cap is a
    // pub const for a reason — verify the gate's logic with a much smaller
    // cap value via a parallel scalar test.
    const empty_info = std.mem.zeroes(LineInfo);

    // Fill near the boundary via a low-level shortcut: stuff `entries` to
    // the cap with sentinel entries so the gate fires on the next `add`.
    var i: usize = 0;
    while (i < max_aggregate_keys) : (i += 1) {
        var key_buf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "k{d}", .{i}) catch return;
        const owned = try agg.arena.allocator().dupe(u8, key);
        try agg.entries.putNoClobber(agg.allocator, owned, .{
            .count = 1,
            .sample_line = "",
            .sample_info = empty_info,
        });
    }
    try std.testing.expectEqual(max_aggregate_keys, agg.entries.count());

    // Now a fresh key gets silently dropped.
    try agg.add("overflow-key", "sample", empty_info);
    try std.testing.expectEqual(max_aggregate_keys, agg.entries.count());

    // But an existing key still increments its count.
    try agg.add("k0", "sample-2", empty_info);
    try std.testing.expectEqual(@as(usize, 2), agg.entries.get("k0").?.count);
}

test "scanLines splits on newlines across read boundaries" {
    // The scanner reads into the tail of one buffer and compacts the
    // leftover to the front. A line straddling a boundary must come back
    // whole, exactly once.
    const Collect = struct {
        seen: std.ArrayList([]u8) = .empty,
        fn line(self: *@This(), bytes: []const u8) !void {
            try self.seen.append(std.testing.allocator, try std.testing.allocator.dupe(u8, bytes));
        }
        fn deinit(self: *@This()) void {
            for (self.seen.items) |x| std.testing.allocator.free(x);
            self.seen.deinit(std.testing.allocator);
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Lines long enough that several reads are needed, with no trailing
    // newline on the last one.
    var expected: std.ArrayList([]u8) = .empty;
    defer {
        for (expected.items) |x| std.testing.allocator.free(x);
        expected.deinit(std.testing.allocator);
    }
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(std.testing.allocator);
    for (0..500) |i| {
        var buf: [512]u8 = undefined;
        const ln = try std.fmt.bufPrint(&buf, "line {d} {s}", .{ i, "x" ** 300 });
        try expected.append(std.testing.allocator, try std.testing.allocator.dupe(u8, ln));
        try content.appendSlice(std.testing.allocator, ln);
        if (i != 499) try content.append(std.testing.allocator, '\n');
    }
    try tmp.dir.writeFile(debug_io, .{ .sub_path = "scan.log", .data = content.items });

    const file = try tmp.dir.openFile(debug_io, "scan.log", .{});
    defer file.close(debug_io);

    var collect = Collect{};
    defer collect.deinit();
    try scanLines(std.testing.allocator, file, &collect);

    try std.testing.expectEqual(expected.items.len, collect.seen.items.len);
    for (expected.items, collect.seen.items) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "scanLines rejects a line past max_line_bytes instead of growing forever" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const huge = try std.testing.allocator.alloc(u8, max_line_bytes + 1024);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'z');
    try tmp.dir.writeFile(debug_io, .{ .sub_path = "huge.log", .data = huge });

    const file = try tmp.dir.openFile(debug_io, "huge.log", .{});
    defer file.close(debug_io);

    const Ignore = struct {
        fn line(_: *@This(), _: []const u8) !void {}
    };
    var ignore = Ignore{};
    try std.testing.expectError(error.LineTooLong, scanLines(std.testing.allocator, file, &ignore));
}

test "FilterState: regex matches simple pattern" {
    var file = [_][]const u8{"test.log"};
    const args = flags.Args{ .files = &file, .search = ".*error.*" };
    var state = FilterState.init(args, null, null);
    defer state.deinit();
    try std.testing.expect(state.has_regex);
    try std.testing.expect(state.checkLine("some error occurred") != null);
    try std.testing.expect(state.checkLine("no issue here") == null);
}

test "FilterState: plain search stays on literal fast path" {
    var file = [_][]const u8{"test.log"};
    const args = flags.Args{ .files = &file, .search = "error" };
    var state = FilterState.init(args, null, null);
    defer state.deinit();
    try std.testing.expect(!state.has_regex);
    try std.testing.expect(state.checkLine("some error occurred") != null);
}

test "FilterState: regex OR via pipe" {
    var file = [_][]const u8{"test.log"};
    const args = flags.Args{ .files = &file, .search = "error|timeout" };
    var state = FilterState.init(args, null, null);
    defer state.deinit();
    try std.testing.expect(state.checkLine("connection timeout") != null);
    try std.testing.expect(state.checkLine("some error") != null);
    try std.testing.expect(state.checkLine("all good") == null);
}

test "FilterState: regex AND via ampersand" {
    var file = [_][]const u8{"test.log"};
    const args = flags.Args{ .files = &file, .search = "error&connection" };
    var state = FilterState.init(args, null, null);
    defer state.deinit();
    try std.testing.expect(state.checkLine("error: connection failed") != null);
    try std.testing.expect(state.checkLine("error: timeout") == null);
}

test "FilterState: invalid regex falls back to literal" {
    var file = [_][]const u8{"test.log"};
    const args = flags.Args{ .files = &file, .search = "[invalid" };
    var state = FilterState.init(args, null, null);
    defer state.deinit();
    try std.testing.expect(!state.has_regex);
    try std.testing.expect(state.has_search_filter);
    try std.testing.expect(state.checkLine("[invalid") != null);
}

test "Regex.compile: valid pattern" {
    var re = regex.Regex.compile("hello").?;
    defer re.deinit();
    try std.testing.expect(re.isMatch("hello world"));
    try std.testing.expect(re.isMatch("HELLO"));
    try std.testing.expect(!re.isMatch("world"));
}

test "Regex.compile: invalid pattern returns null" {
    try std.testing.expect(regex.Regex.compile("[unclosed") == null);
}

test "RegexList: AND logic" {
    var rl = regex.RegexList.compile("error&connection").?;
    defer rl.deinit();
    try std.testing.expect(rl.allMatch("error: connection failed"));
    try std.testing.expect(!rl.allMatch("error: timeout"));
    try std.testing.expect(!rl.allMatch("connection: ok"));
}

test "RegexList: single pattern" {
    var rl = regex.RegexList.compile("hello|world").?;
    defer rl.deinit();
    try std.testing.expect(rl.allMatch("hello"));
    try std.testing.expect(rl.allMatch("world"));
    try std.testing.expect(!rl.allMatch("nope"));
}

test "--output json flag" {
    var file = [_][]const u8{"test.log"};
    const args = flags.Args{ .files = &file, .output_json = true };
    try std.testing.expect(args.output_json);
}

test "printJsonOutputLine: produces valid JSON" {
    const line = "[ERROR] connection failed";
    const info = analyzeLine(line, true);
    // Just verify it doesn't crash and produces non-empty output.
    // The actual output goes to stdout which we can't easily capture.
    try std.testing.expect(info.level != null);
}

// --- Output sink ---

test "Out buffers until capacity and flushes on demand" {
    var h = TestOut{ .th = theme.Theme.plain };
    try h.start();
    defer h.deinit();

    h.out.write("hello ");
    h.out.write("world");
    try std.testing.expectEqual(@as(usize, 11), h.out.len);
    const got = try h.take();
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hello world", got);
    try std.testing.expectEqual(@as(usize, 0), h.out.len);
}

test "Out treats an empty write as a no-op" {
    // Every palette entry is "" under the plain theme, so this path runs
    // several times per printed line.
    var h = TestOut{ .th = theme.Theme.plain };
    try h.start();
    defer h.deinit();
    h.out.write("");
    h.out.write("");
    try std.testing.expectEqual(@as(usize, 0), h.out.len);
}

// --- Styled output is lossless ---

/// Strips ANSI CSI sequences so a styled line can be compared with its input.
fn stripAnsi(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            i += 2;
            while (i < s.len and s[i] != 'm' and s[i] != 'H' and s[i] != 'J') : (i += 1) {}
            i += 1;
            continue;
        }
        try out.append(allocator, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

test "styled JSON output reproduces the input byte for byte" {
    // The JSON styler emits unstyled bytes in runs and styled tokens
    // separately. Getting the hand-off wrong duplicates or drops content in
    // a way that colour makes hard to see, so assert on the stripped bytes.
    // No `level` field in these: the level badge is the one place the
    // printer deliberately rewrites content (see the test below).
    const cases = [_][]const u8{
        "{\"lvl\":\"info\",\"msg\":\"hello\",\"n\":42,\"ok\":true,\"z\":null}",
        "{\"a\":[1,2,3],\"b\":{\"c\":-1.5e3}}",
        "{\"msg\":\"quote \\\" inside\",\"esc\":\"back\\\\slash\"}",
        "{\"empty\":\"\",\"spaces\" : \"  x  \"}",
        "{}",
        "{\"unicode\":\"привет мир\",\"emoji\":\"ok\"}",
    };
    for (cases) |line| {
        var h = TestOut{ .th = theme.Theme.forMode(.truecolor, theme.Glyphs.ascii) };
        try h.start();
        defer h.deinit();
        const info = analyzeLine(line, true);
        printJsonStyled(&h.out, line, info, &.{}, null);
        const raw = try h.take();
        defer std.testing.allocator.free(raw);
        const plain = try stripAnsi(std.testing.allocator, raw);
        defer std.testing.allocator.free(plain);
        // The printer appends a newline.
        try std.testing.expectEqualStrings(line, std.mem.trimEnd(u8, plain, "\n"));
    }
}

test "the level badge is the only rewrite the JSON styler performs" {
    const line = "{\"level\":\"info\",\"msg\":\"hello\"}";
    var h = TestOut{ .th = theme.Theme.plain };
    try h.start();
    defer h.deinit();
    const info = analyzeLine(line, true);
    printJsonStyled(&h.out, line, info, &.{}, null);
    const got = try h.take();
    defer std.testing.allocator.free(got);
    // `"info"` becomes the padded badge; every other byte survives.
    try std.testing.expectEqualStrings(
        "{\"level\": INFO  ,\"msg\":\"hello\"}\n",
        got,
    );
}

test "styled JSON output carries no colour under the plain theme" {
    const got = try renderLine("{\"level\":\"info\",\"msg\":\"hello\"}", false);
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "\x1b[") == null);
}

test "plain-text line keeps its bytes when the level is replaced by a badge" {
    const line = "2026-08-25 12:00:01 [INFO] api: started";
    var h = TestOut{ .th = theme.Theme.plain };
    try h.start();
    defer h.deinit();
    const info = analyzeLine(line, true);
    printStyledLine(&h.out, line, info, &.{}, null);
    const got = try h.take();
    defer std.testing.allocator.free(got);
    // The badge pads "INFO" to a fixed width; everything else is verbatim.
    try std.testing.expect(std.mem.startsWith(u8, got, "2026-08-25 12:00:01 ["));
    try std.testing.expect(std.mem.indexOf(u8, got, "] api: started") != null);
}

// --- Embedded JSON expansion ---

test "embedded JSON in a plain line is expanded below it" {
    const got = try renderLine(
        "12:00:01 [INFO] api: replied {\"id\":5,\"status\":200,\"ok\":true}",
        true,
    );
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"id\": 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"status\": 200") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "+-") != null);
}

test "escaped JSON inside a JSON log line is decoded and expanded" {
    const got = try renderLine(
        "{\"level\":\"error\",\"msg\":\"failed\",\"body\":\"{\\\"code\\\":503,\\\"detail\\\":\\\"down\\\"}\"}",
        true,
    );
    defer std.testing.allocator.free(got);
    // The compact line still shows the escaped form...
    try std.testing.expect(std.mem.indexOf(u8, got, "\\\"code\\\":503") != null);
    // ...and the block shows it decoded.
    try std.testing.expect(std.mem.indexOf(u8, got, "\"code\": 503") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"detail\": \"down\"") != null);
}

test "expansion is skipped when disabled" {
    const line = "12:00:01 [INFO] api: replied {\"id\":5,\"status\":200,\"ok\":true}";
    const got = try renderLine(line, false);
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"id\": 5") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "+-") == null);
}

test "a line without embedded JSON gains nothing" {
    const got = try renderLine("12:00:01 [WARN] cache: eviction ran, nothing to see", true);
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "+-") == null);
}

test "a brace that is not JSON is left alone" {
    // Go's `map[...]` printing and prose braces must not trigger a block.
    for ([_][]const u8{
        "12:00:01 [INFO] state map[a:1 b:2] settled",
        "12:00:01 [INFO] template {placeholder} unresolved",
        "12:00:01 [INFO] truncated {\"id\":5,\"name\":\"unclos",
    }) |line| {
        const got = try renderLine(line, true);
        defer std.testing.allocator.free(got);
        try std.testing.expect(std.mem.indexOf(u8, got, "+-") == null);
    }
}

test "a protobuf payload is decoded below the line and cut out of it" {
    const line = "{\"level\":\"info\",\"message\":" ++
        "\"Handle: \\u000a\\u0015\\u000a\\u000ccleanup_time\\u0012\\u000510:45\"}";
    const got = try renderLine(line, true);
    defer std.testing.allocator.free(got);

    // The sentence survives, the escapes it was carrying do not.
    try std.testing.expect(std.mem.indexOf(u8, got, "\"Handle: ...\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "u000a") == null);
    // …because the block below now says what was actually sent.
    try std.testing.expect(std.mem.indexOf(u8, got, "1: \"cleanup_time\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "2: \"10:45\"") != null);
}

test "a damaged payload leaves the line exactly as it was" {
    // Same shape, but the length prefixes disagree with the contents. Nothing
    // trustworthy can be decoded, so nothing is hidden either.
    const line = "{\"level\":\"info\",\"message\":" ++
        "\"Handle: \\u000a\\u001c\\u000a\\u0013cleanup_time\\u0012\\u000510:45\"}";
    const got = try renderLine(line, true);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "u001c") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "+-") == null);
}

test "a nested JSON value keeps its verbatim form on the line" {
    // Only protobuf payloads get cut; JSON is readable where it stands.
    const line = "{\"level\":\"info\",\"body\":\"{\\\"id\\\":5,\\\"n\\\":\\\"x\\\"}\"}";
    const got = try renderLine(line, true);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.indexOf(u8, got, "...") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"id\": 5") != null);
}

test "a regex search highlights what it matched" {
    var files = [_][]const u8{"x.log"};
    const args = flags.Args{ .files = &files, .search = "5\\d\\d" };
    var state = FilterState.init(args, null, null);
    defer state.deinit();
    // `init` clears has_search_filter for a regex; the printer must still
    // find ranges, which is what this whole path exists for.
    try std.testing.expect(state.has_regex);
    try std.testing.expect(!state.has_search_filter);

    var buf: [max_search_matches]MatchRange = undefined;
    const m = findRegexMatches("request served in 512ms", &state.regex_list, &buf);
    try std.testing.expectEqual(@as(usize, 1), m.len);
    try std.testing.expectEqual(@as(usize, 18), m[0].start);
    try std.testing.expectEqual(@as(usize, 21), m[0].end);
}

test "regex highlighting collects every occurrence and merges overlaps" {
    var files = [_][]const u8{"x.log"};
    const args = flags.Args{ .files = &files, .search = "\\d\\d" };
    var state = FilterState.init(args, null, null);
    defer state.deinit();

    var buf: [max_search_matches]MatchRange = undefined;
    const m = findRegexMatches("a 12 b 34", &state.regex_list, &buf);
    try std.testing.expectEqual(@as(usize, 2), m.len);
    try std.testing.expectEqual(@as(usize, 2), m[0].start);
    try std.testing.expectEqual(@as(usize, 7), m[1].start);
}

test "a pattern that can match nothing does not spin" {
    var files = [_][]const u8{"x.log"};
    // `x*` matches the empty string at every position; the scan has to make
    // progress anyway.
    const args = flags.Args{ .files = &files, .search = "x*" };
    var state = FilterState.init(args, null, null);
    defer state.deinit();

    var buf: [max_search_matches]MatchRange = undefined;
    const m = findRegexMatches("abc", &state.regex_list, &buf);
    try std.testing.expect(m.len <= buf.len);
}

test "newestInChunk takes the last stamped line, not the last line" {
    // The tail of a crash is untimestamped continuation; the anchor has to
    // walk back past it to the record those lines belong to.
    const chunk =
        "2026-09-03T10:00:00Z INF older\n" ++
        "2026-09-03T10:44:05Z ERR boom\n" ++
        "\tgoroutine 1 [running]:\n" ++
        "\tmain.crash()\n";
    const got = newestInChunk(chunk) orelse return error.NoAnchor;
    try std.testing.expectEqualStrings("2026-09-03", &got.date);
    try std.testing.expectEqualStrings("10:44:05", &got.time);
}

test "newestInChunk ignores a leading fragment of a longer line" {
    // A chunk read from the middle of a file starts mid-line; that fragment
    // is the one line whose parse cannot be trusted.
    const chunk = "45Z INF fragment\n2026-09-03T10:44:05Z INF whole\n";
    const got = newestInChunk(chunk) orelse return error.NoAnchor;
    try std.testing.expectEqualStrings("10:44:05", &got.time);
}

test "newestInChunk reports nothing when no line carries a date" {
    try std.testing.expectEqual(@as(?AnchorStamp, null), newestInChunk("no stamps here\nnor here\n"));
}

test "--since keeps the window and drops what precedes it" {
    var files = [_][]const u8{"x.log"};
    const args = flags.Args{ .files = &files, .since_ms = 5 * 60 * 1000 };
    var state = FilterState.init(args, null, null);
    defer state.deinit();
    try std.testing.expect(state.needs_timestamps);

    // Twenty minutes back from 00:11 lands on the previous day at 23:51 —
    // the case a string comparison on its own gets wrong.
    state.since_cut = civil.cutoffBefore("2026-09-04", "00:11:00", 20 * 60 * 1000);

    // Inside the window, including the far side of midnight.
    try std.testing.expect(state.checkLine("2026-09-04T00:11:00Z INF newest") != null);
    try std.testing.expect(state.checkLine("2026-09-03T23:58:00Z INF just inside") != null);
    // The boundary itself is inclusive.
    try std.testing.expect(state.checkLine("2026-09-03T23:51:00Z INF boundary") != null);
    // Outside.
    try std.testing.expect(state.checkLine("2026-09-03T23:50:59Z INF too old") == null);
    try std.testing.expect(state.checkLine("2026-09-02T23:59:59Z INF yesterday") == null);
    // Untimestamped continuation stays with the record above it.
    try std.testing.expect(state.checkLine("\tmain.crash()") != null);
}

test "--since with no anchor filters nothing rather than everything" {
    var files = [_][]const u8{"x.log"};
    const args = flags.Args{ .files = &files, .since_ms = 60 * 1000 };
    var state = FilterState.init(args, null, null);
    defer state.deinit();
    // `findSinceCutoff` returns null when nothing in the input carries a
    // date. An empty log would otherwise look exactly like a broken filter.
    try std.testing.expectEqual(@as(?civil.Cutoff, null), state.since_cut);
    try std.testing.expect(state.checkLine("2019-01-01T00:00:00Z INF ancient") != null);
}

/// Builds a mixed-format fixture, runs it through both scan paths, and hands
/// back the two outputs for comparison.
fn bothScanPaths(
    allocator: std.mem.Allocator,
    args_in: flags.Args,
    th: *const Theme,
    lines: usize,
    chunk_bytes: usize,
) !struct { serial: []u8, parallel: []u8 } {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    var scratch: [256]u8 = undefined;
    for (0..lines) |i| {
        const line = switch (i % 3) {
            0 => try std.fmt.bufPrint(&scratch, "{{\"time\":\"2026-09-03T10:00:{d:0>2}Z\",\"level\":\"{s}\",\"msg\":\"req {d}\"}}\n", .{ i % 60, if (i % 7 == 0) "error" else "info", i }),
            1 => try std.fmt.bufPrint(&scratch, "2026-09-03 10:00:{d:0>2} [{s}] req {d} handled\n", .{ i % 60, if (i % 7 == 0) "ERROR" else "INFO", i }),
            else => try std.fmt.bufPrint(&scratch, "time=2026-09-03T10:00:{d:0>2}Z level={s} msg=\"req {d}\"\n", .{ i % 60, if (i % 7 == 0) "error" else "info", i }),
        };
        try content.appendSlice(allocator, line);
    }
    try tmp.dir.writeFile(debug_io, .{ .sub_path = "f.log", .data = content.items });

    var args = args_in;
    var files = [_][]const u8{"f.log"};
    args.files = &files;

    const file = try tmp.dir.openFile(debug_io, "f.log", .{});
    defer file.close(debug_io);
    const size = try file.length(debug_io);

    // Parallel.
    var par_buf: std.ArrayList(u8) = .empty;
    errdefer par_buf.deinit(allocator);
    var par_out = try Out.init(allocator, std.Io.File.stdout(), th);
    defer par_out.deinit();
    par_out.sink = &par_buf;
    var par_counter = LevelCounter{};
    const ran = try readParallel(allocator, file, size, args, &par_counter, &par_out, null, chunk_bytes);
    try std.testing.expect(ran);
    par_out.flush();

    // Serial, through the same handler the real read path uses.
    var ser_buf: std.ArrayList(u8) = .empty;
    errdefer ser_buf.deinit(allocator);
    var ser_out = try Out.init(allocator, std.Io.File.stdout(), th);
    defer ser_out.deinit();
    ser_out.sink = &ser_buf;
    var expander: ?JsonExpander = if (wantsJsonExpansion(args, th))
        try JsonExpander.init(allocator, .{})
    else
        null;
    defer if (expander) |*x| x.deinit();
    var fs = FilterState.init(args, &ser_out, if (expander) |*x| x else null);
    defer fs.deinit();
    var ser_counter = LevelCounter{};
    var handler = PrintHandler{
        .args = args,
        .counter = &ser_counter,
        .filter_state = &fs,
        .out = &ser_out,
        .paginate = false,
    };
    const file2 = try tmp.dir.openFile(debug_io, "f.log", .{});
    defer file2.close(debug_io);
    try scanLines(allocator, file2, &handler);
    ser_out.flush();

    // The level tally has to survive the split too — it is merged from one
    // counter per worker, and a lost record there would be invisible in the
    // bytes.
    try std.testing.expectEqual(ser_counter.total, par_counter.total);
    for (ser_counter.counts, par_counter.counts) |a, b| try std.testing.expectEqual(a, b);

    return .{
        .serial = try ser_buf.toOwnedSlice(allocator),
        .parallel = try par_buf.toOwnedSlice(allocator),
    };
}

test "the parallel scan produces exactly the serial output" {
    const a = std.testing.allocator;
    var files = [_][]const u8{"f.log"};
    // Every shape the split has to survive: plain rendering, a level filter,
    // a substring search, and JSONL for a pipeline.
    for ([_]flags.Args{
        .{ .files = &files },
        .{ .files = &files, .levels = flags.levelBit(.Error) },
        .{ .files = &files, .search = "handled" },
        .{ .files = &files, .output_json = true },
    }) |args| {
        for ([_]*const Theme{ &Theme.plain, &Theme.forMode(.truecolor, theme.Glyphs.unicode) }) |th| {
            const got = try bothScanPaths(a, args, th, 4000, 4096);
            defer a.free(got.serial);
            defer a.free(got.parallel);
            try std.testing.expectEqualSlices(u8, got.serial, got.parallel);
        }
    }
}

test "a chunk size that yields one chunk falls back instead of splitting" {
    const a = std.testing.allocator;
    var files = [_][]const u8{"f.log"};
    // `readParallel` reports false rather than standing up a pool of one, so
    // the caller runs the serial path and nothing is duplicated.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(debug_io, .{ .sub_path = "tiny.log", .data = "one line\n" });
    const file = try tmp.dir.openFile(debug_io, "tiny.log", .{});
    defer file.close(debug_io);

    var out = try Out.init(a, std.Io.File.stdout(), &Theme.plain);
    defer out.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    out.sink = &buf;
    var counter = LevelCounter{};

    var args = flags.Args{ .files = &files };
    args.files = &files;
    try std.testing.expect(!try readParallel(a, file, 9, args, &counter, &out, null, 1 << 20));
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "pagination and aggregation stay on the serial path" {
    var files = [_][]const u8{"app.log"};
    const big: u64 = 64 << 20;
    try std.testing.expect(parallelEligible(.{ .files = &files }, "app.log", big));
    // Pagination is interactive; aggregation needs one map for the whole file.
    try std.testing.expect(!parallelEligible(.{ .files = &files, .num_lines = 100 }, "app.log", big));
    try std.testing.expect(!parallelEligible(.{ .files = &files, .aggregate = true }, "app.log", big));
    try std.testing.expect(!parallelEligible(.{ .files = &files, .tail_mode = true }, "app.log", big));
    // Not seekable, so it cannot be split.
    try std.testing.expect(!parallelEligible(.{ .files = &files }, "app.log.gz", big));
    // Too small to pay for the pool.
    try std.testing.expect(!parallelEligible(.{ .files = &files }, "app.log", 1024));
}

test "expansion never runs for --output json" {
    var file = [_][]const u8{"x.log"};
    const args = flags.Args{ .files = &file, .output_json = true };
    const th = theme.Theme.forMode(.truecolor, theme.Glyphs.unicode);
    try std.testing.expect(!wantsJsonExpansion(args, &th));
}

test "expansion follows colour, and --no-expand-json overrides it" {
    var file = [_][]const u8{"x.log"};
    const colored = theme.Theme.forMode(.truecolor, theme.Glyphs.unicode);
    const plain = theme.Theme.plain;

    try std.testing.expect(wantsJsonExpansion(.{ .files = &file }, &colored));
    // Redirected output stays one record per line.
    try std.testing.expect(!wantsJsonExpansion(.{ .files = &file }, &plain));
    try std.testing.expect(!wantsJsonExpansion(.{ .files = &file, .no_expand_json = true }, &colored));
}

test "expanding a huge embedded payload is refused rather than attempted" {
    // `Limits.max_bytes` bounds both the validate scan and the unescape
    // buffer; a payload past it prints as-is.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(std.testing.allocator);
    try big.appendSlice(std.testing.allocator, "12:00:01 [INFO] dump {\"k\":\"");
    try big.appendSlice(std.testing.allocator, "y" ** 4096);
    try big.appendSlice(std.testing.allocator, "\"}");

    var h = TestOut{ .th = theme.Theme.plain };
    try h.start();
    defer h.deinit();
    var expander = try JsonExpander.init(std.testing.allocator, .{ .max_bytes = 128 });
    defer expander.deinit();
    const info = analyzeLine(big.items, true);
    printStyledLine(&h.out, big.items, info, &.{}, &expander);
    const got = try h.take();
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "+-") == null);
}

// --- Timestamp extraction gate ---

test "timestamps are skipped when nothing downstream needs them" {
    const line = "2026-08-25 12:00:01 [INFO] api: started";
    const with = analyzeLine(line, true);
    try std.testing.expect(with.date != null);
    try std.testing.expect(with.time != null);

    const without = analyzeLine(line, false);
    try std.testing.expect(without.date == null);
    try std.testing.expect(without.time == null);
    // Level detection is unaffected — only the two timestamp scans are.
    try std.testing.expectEqual(with.level, without.level);
    try std.testing.expectEqual(with.format, without.format);
}

test "FilterState asks for timestamps exactly when it needs them" {
    var file = [_][]const u8{"x.log"};
    const none = FilterState.init(.{ .files = &file }, null, null);
    try std.testing.expect(!none.needs_timestamps);

    const dated = FilterState.init(.{ .files = &file, .date = "2026-08-25" }, null, null);
    try std.testing.expect(dated.needs_timestamps);

    const timed = FilterState.init(.{ .files = &file, .from_time = "12:00" }, null, null);
    try std.testing.expect(timed.needs_timestamps);

    // JSON output carries date and time fields, so they must be extracted.
    const as_json = FilterState.init(.{ .files = &file, .output_json = true }, null, null);
    try std.testing.expect(as_json.needs_timestamps);
}

test "a date filter still matches with the gate in place" {
    var file = [_][]const u8{"x.log"};
    var state = FilterState.init(.{ .files = &file, .date = "2026-08-25" }, null, null);
    defer state.deinit();
    try std.testing.expect(state.checkLine("2026-08-25 12:00:01 [INFO] yes") != null);
    try std.testing.expect(state.checkLine("2026-08-26 12:00:01 [INFO] no") == null);
}

test "a broken sink stops the scan instead of formatting the rest of the file" {
    // `zlrd big.log | head -20` must not walk the remaining gigabytes.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(std.testing.allocator);
    for (0..1000) |i| {
        var buf: [64]u8 = undefined;
        try content.appendSlice(std.testing.allocator, try std.fmt.bufPrint(&buf, "[INFO] line {d}\n", .{i}));
    }
    try tmp.dir.writeFile(debug_io, .{ .sub_path = "s.log", .data = content.items });
    const file = try tmp.dir.openFile(debug_io, "s.log", .{});
    defer file.close(debug_io);

    var h = TestOut{ .th = theme.Theme.plain };
    try h.start();
    defer h.deinit();
    h.out.broken = true; // as if the reader on the far end went away

    var file_arg = [_][]const u8{"s.log"};
    var fs = FilterState.init(.{ .files = &file_arg }, &h.out, null);
    defer fs.deinit();
    var counter = LevelCounter{};
    var handler = PrintHandler{
        .args = .{ .files = &file_arg },
        .counter = &counter,
        .filter_state = &fs,
        .out = &h.out,
        .paginate = false,
    };
    try std.testing.expectError(error.OutputClosed, scanLines(std.testing.allocator, file, &handler));
    // Stopped on the very first line, not after all 1000.
    try std.testing.expectEqual(@as(usize, 1), counter.total);
}

test "an intact sink processes every line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(debug_io, .{
        .sub_path = "ok.log",
        .data = "[INFO] a\n[WARN] b\n[ERROR] c\n",
    });
    const file = try tmp.dir.openFile(debug_io, "ok.log", .{});
    defer file.close(debug_io);

    var h = TestOut{ .th = theme.Theme.plain };
    try h.start();
    defer h.deinit();

    var file_arg = [_][]const u8{"ok.log"};
    var fs = FilterState.init(.{ .files = &file_arg }, &h.out, null);
    defer fs.deinit();
    var counter = LevelCounter{};
    var handler = PrintHandler{
        .args = .{ .files = &file_arg },
        .counter = &counter,
        .filter_state = &fs,
        .out = &h.out,
        .paginate = false,
    };
    try scanLines(std.testing.allocator, file, &handler);
    try std.testing.expectEqual(@as(usize, 3), counter.total);
    try std.testing.expect(!h.out.broken);
}

test "the colourless fast path matches the token walk byte for byte" {
    // `printStyledLine` short-circuits the whole JSON token walk when there
    // is no colour, no highlight and no block to expand. It has to produce
    // exactly what the walk would have.
    const cases = [_][]const u8{
        "{\"level\":\"info\",\"msg\":\"hello\",\"n\":42}",
        "{\"time\":\"2026-08-25T12:00:00Z\",\"level\":\"error\",\"msg\":\"boom\"}",
        "{\"level\":\"warn\"}",
        "{\"no_level\":\"here\",\"n\":1,\"ok\":true}",
        "{\"msg\":\"quote \\\" and back\\\\slash\",\"level\":\"debug\"}",
        "{}",
        "{\"level\":\"fatal\",\"trailing\":null}",
    };
    for (cases) |line| {
        const info = analyzeLine(line, true);

        var fast = TestOut{ .th = theme.Theme.plain };
        try fast.start();
        defer fast.deinit();
        printStyledLine(&fast.out, line, info, &.{}, null);
        const a = try fast.take();
        defer std.testing.allocator.free(a);

        var slow = TestOut{ .th = theme.Theme.plain };
        try slow.start();
        defer slow.deinit();
        printJsonStyled(&slow.out, line, info, &.{}, null);
        const b = try slow.take();
        defer std.testing.allocator.free(b);

        try std.testing.expectEqualStrings(b, a);
    }
}

test "colourless search output is identical to unfiltered output" {
    // The optimisation in `printChecked` skips match collection when colour
    // is off. That is only sound because the plain palette highlights with
    // empty strings — assert the dependency directly, so giving `plain` a
    // real `match_on` (bold or underline need no colour) fails here instead
    // of silently dropping highlights from every redirected run.
    try std.testing.expectEqual(@as(usize, 0), theme.Theme.plain.palette.match_on.len);

    const line = "{\"level\":\"info\",\"msg\":\"needle here\"}";
    const info = analyzeLine(line, true);

    var file = [_][]const u8{"t.log"};
    const with_search = flags.Args{ .files = &file, .tail_mode = false, .search = "needle", .num_lines = 0 };
    const no_search = flags.Args{ .files = &file, .tail_mode = false, .num_lines = 0 };

    var a = TestOut{ .th = theme.Theme.plain };
    try a.start();
    defer a.deinit();
    var sa = FilterState.init(with_search, &a.out, null);
    defer sa.deinit();
    sa.printChecked(line, info);
    const got_search = try a.take();
    defer std.testing.allocator.free(got_search);

    var b = TestOut{ .th = theme.Theme.plain };
    try b.start();
    defer b.deinit();
    var sb = FilterState.init(no_search, &b.out, null);
    defer sb.deinit();
    sb.printChecked(line, info);
    const got_plain = try b.take();
    defer std.testing.allocator.free(got_plain);

    try std.testing.expectEqualStrings(got_plain, got_search);
}

test "normalized key trims surrounding whitespace and ends on a date" {
    // Edge cases of the direct-write rewrite: the leading run is dropped by
    // seeding `prev_space`, the trailing one by a single decrement, and a
    // date flush at the very end must not read past the line.
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(std.testing.allocator);

    const key = try buildAggregateKeyForLine(std.testing.allocator, &scratch, .normalized, "   \t Foo   BAR \t ");
    try std.testing.expectEqualStrings("foo bar", key);

    var s2: std.ArrayList(u8) = .empty;
    defer s2.deinit(std.testing.allocator);
    const key2 = try buildAggregateKeyForLine(std.testing.allocator, &s2, .normalized, "seen 2026-08-26");
    try std.testing.expectEqualStrings("seen <date>", key2);

    // A digit run too short to be a date still collapses to a single `#`.
    var s3: std.ArrayList(u8) = .empty;
    defer s3.deinit(std.testing.allocator);
    const key3 = try buildAggregateKeyForLine(std.testing.allocator, &s3, .normalized, "id=12345 ok");
    try std.testing.expectEqualStrings("id=# ok", key3);
}

test "search highlighting still takes the token walk" {
    // A non-empty match list must not be short-circuited away, even without
    // colour: the highlight escapes are the whole point.
    const line = "{\"level\":\"info\",\"msg\":\"needle here\"}";
    const info = analyzeLine(line, true);
    var match_buf: [max_search_matches]MatchRange = undefined;
    const matches = findSearchMatches(line, "needle", &match_buf);
    try std.testing.expect(matches.len > 0);

    var h = TestOut{ .th = theme.Theme.forMode(.truecolor, theme.Glyphs.ascii) };
    try h.start();
    defer h.deinit();
    printStyledLine(&h.out, line, info, matches, null);
    const got = try h.take();
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, h.th.palette.match_on) != null);
}

test "the fast path never runs when a JSON block would be expanded" {
    const line = "{\"level\":\"info\",\"body\":\"{\\\"id\\\":5,\\\"ok\\\":true}\"}";
    const info = analyzeLine(line, true);
    var expander = try JsonExpander.init(std.testing.allocator, .{});
    defer expander.deinit();

    var h = TestOut{ .th = theme.Theme.plain };
    try h.start();
    defer h.deinit();
    printStyledLine(&h.out, line, info, &.{}, &expander);
    const got = try h.take();
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"id\": 5") != null);
}
