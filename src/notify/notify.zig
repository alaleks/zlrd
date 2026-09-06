//! Native alert bodies for Telegram, Slack and Discord.
//!
//! The webhook sinks POST `alert.zig`'s JSON payload verbatim, which is the
//! right thing for a collector and the wrong thing for a chat app: all three
//! services reject a body they don't recognise, so reaching them used to
//! require standing up a templating proxy in front. For the operator this
//! project is aimed at — one box, no Alertmanager, no Prometheus — that proxy
//! is a whole extra moving part to run and monitor, in exchange for a line of
//! text in a channel.
//!
//! So the three shapes live here instead. A `Target` records which one a URL
//! wants; `render` turns a neutral `Alert` view into that channel's request
//! body. Nothing in here allocates and nothing does I/O — `webhook.zig` still
//! owns delivery, and it cannot tell a templated body from a raw one.
//!
//! ## Staying inside the message limits
//!
//! Every channel caps a message, and a crash alert carries a stack trace that
//! can be several KiB on its own. Rather than trim the trace to a guessed
//! character count and hope the escaping doesn't push it over, the writers
//! here charge each byte against a budget *after* escaping. The budget is the
//! channel's cap with headroom, so the encoded body is bounded by
//! construction and a trace is cut at the last byte that fits rather than
//! costing the whole alert.

const std = @import("std");

pub const Kind = enum {
    /// The raw `alert.zig` payload — a collector, Alertmanager, a bespoke
    /// receiver. Never rendered here.
    raw,
    slack,
    discord,
    telegram,
};

/// One configured destination.
pub const Target = struct {
    kind: Kind,
    /// The URL to POST to. For Telegram this is built by `parseTelegram`
    /// (the operator supplies a bot token, not a URL); for everything else
    /// it is borrowed from argv verbatim.
    url: []const u8,
    /// Telegram only: the chat the message is addressed to. Empty otherwise.
    chat_id: []const u8 = "",
    /// True when `url` was allocated by `parseTelegram` and the config owns
    /// it. The other kinds borrow from argv and must not be freed.
    url_owned: bool = false,

    pub fn deinit(self: *const Target, allocator: std.mem.Allocator) void {
        if (self.url_owned) allocator.free(self.url);
    }
};

pub const ParseError = error{InvalidTelegramTarget};

/// Longest Telegram send URL we will build. A bot token is
/// `<9-10 digit id>:<35 char secret>`; 192 leaves room for the format to
/// change without this becoming the thing that breaks.
pub const max_telegram_url = 192;

/// Parses `--alert-telegram=<bot-token>:<chat-id>` and builds the sendMessage
/// URL for it.
///
/// The split is on the LAST colon because a bot token contains one of its own
/// (`123456789:AAH...`), the same rule `--alert-regex` uses for patterns that
/// contain a colon. What makes that unambiguous is the shape of a chat id: it
/// is either all digits — negative for groups and supergroups — or an
/// `@channelusername`. Anything else is a token the operator pasted without
/// its chat id, and saying so beats POSTing to a URL that will 404 forever.
pub fn parseTelegram(allocator: std.mem.Allocator, spec: []const u8) (ParseError || error{OutOfMemory})!Target {
    const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse return error.InvalidTelegramTarget;
    const token = spec[0..colon];
    const chat = spec[colon + 1 ..];
    if (chat.len == 0) return error.InvalidTelegramTarget;
    if (!validChatId(chat)) return error.InvalidTelegramTarget;
    // The token must still carry its own colon after the chat id was split
    // off, otherwise what we have is a bare token and no chat.
    if (std.mem.indexOfScalar(u8, token, ':') == null) return error.InvalidTelegramTarget;

    var buf: [max_telegram_url]u8 = undefined;
    const url = std.fmt.bufPrint(
        &buf,
        "https://api.telegram.org/bot{s}/sendMessage",
        .{token},
    ) catch return error.InvalidTelegramTarget;

    return .{
        .kind = .telegram,
        .url = try allocator.dupe(u8, url),
        .chat_id = chat,
        .url_owned = true,
    };
}

fn validChatId(chat: []const u8) bool {
    if (chat[0] == '@') return chat.len > 1;
    const digits = if (chat[0] == '-') chat[1..] else chat;
    if (digits.len == 0) return false;
    for (digits) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// True when `url` is one of the well-known chat endpoints. Used to warn an
/// operator who passed a Slack or Discord URL to `--alert-webhook`, where it
/// would receive the raw payload and be rejected with a 400 that only shows
/// up in the agent's own log.
pub fn looksTemplated(url: []const u8) ?Kind {
    if (std.mem.indexOf(u8, url, "hooks.slack.com/") != null) return .slack;
    if (std.mem.indexOf(u8, url, "discord.com/api/webhooks/") != null) return .discord;
    if (std.mem.indexOf(u8, url, "discordapp.com/api/webhooks/") != null) return .discord;
    if (std.mem.indexOf(u8, url, "api.telegram.org/bot") != null) return .telegram;
    return null;
}

// ─── The neutral view ─────────────────────────────────────────────────────

pub const Severity = enum { critical, warning, notice };

/// What happened, in the vocabulary the three dispatch paths share. Mirrors
/// `metrics.RuleKind` without depending on it — this package is standalone so
/// it can be tested and reasoned about without the agent around it.
pub const Event = enum {
    service_crash,
    service_stop,
    service_restart,
    kernel_oom,
    kernel_segfault,
    kernel_panic,
    error_rate,
    regex,
    first_seen,
    silence,

    pub fn severity(self: Event) Severity {
        return switch (self) {
            .service_crash, .kernel_oom, .kernel_segfault, .kernel_panic => .critical,
            .service_stop, .error_rate, .regex, .silence => .warning,
            .service_restart, .first_seen => .notice,
        };
    }

    /// Leading glyph. Carries the severity at a glance in a channel that has
    /// no room for a colour bar (Telegram) and reinforces it in the two that
    /// do.
    pub fn emoji(self: Event) []const u8 {
        return switch (self) {
            .service_crash => "\u{1F534}", // red circle
            .service_stop => "\u{23F9}\u{FE0F}", // stop button
            .service_restart => "\u{1F504}", // arrows
            .kernel_oom, .kernel_segfault, .kernel_panic => "\u{1F4A5}", // collision
            .error_rate => "\u{1F7E0}", // orange circle
            .regex => "\u{1F50E}", // magnifier
            .first_seen => "\u{1F195}", // NEW
            .silence => "\u{1F507}", // muted speaker
        };
    }

    /// Accent colour, taken from the reader's level palette in
    /// `src/reader/theme.zig` so an alert in a chat app is the same colour as
    /// the line that produced it in the terminal.
    pub fn color(self: Event) u32 {
        return switch (self) {
            .service_crash, .kernel_oom, .kernel_segfault, .kernel_panic => 0xc02626, // Error
            .error_rate, .regex, .service_stop, .silence => 0x8a5300, // Warn
            .first_seen => 0x0d5bbd, // Debug
            .service_restart => 0x11713c, // Info
        };
    }
};

/// A fired alert, flattened to what a human needs to read in a chat message.
/// Every slice is borrowed from the caller's event and must outlive `render`.
pub const Alert = struct {
    event: Event,
    /// Service name for lifecycle events, the killed process for kernel
    /// events, the rule id otherwise.
    subject: []const u8,
    /// Where it came from: a file path or a systemd unit.
    source: []const u8,
    /// Which detector matched (`go_panic`, `rust_panic`, …). May be empty.
    marker: []const u8 = "",
    /// The line that fired the rule, or the crash's first line.
    detail: []const u8 = "",
    /// Stack trace, if one was collected. May be empty.
    trace: []const u8 = "",
    pid: ?u32 = null,
    /// Observed / threshold / window, for the rate-shaped rules.
    observed: ?u64 = null,
    threshold: ?u32 = null,
    window_ms: ?u64 = null,
    crash_count: ?u64 = null,
    restart_count: ?u64 = null,

    /// One-line summary: what happened, to what. Falls back to the bare verb
    /// if `buf` cannot hold the subject, so a pathological service name
    /// degrades the title instead of dropping the alert.
    pub fn headline(self: Alert, buf: []u8) []const u8 {
        return switch (self.event) {
            .service_crash => bufPrintOr(buf, "{s} crashed", .{self.subject}, "service crashed"),
            .service_stop => bufPrintOr(buf, "{s} went silent", .{self.subject}, "service went silent"),
            .service_restart => bufPrintOr(buf, "{s} restarted", .{self.subject}, "service restarted"),
            .kernel_oom => bufPrintOr(buf, "OOM killer took {s}", .{self.subject}, "OOM killer fired"),
            .kernel_segfault => bufPrintOr(buf, "{s} segfaulted", .{self.subject}, "process segfaulted"),
            .kernel_panic => "kernel panicked on the previous boot",
            .error_rate => bufPrintOr(buf, "error rate on {s}", .{self.source}, "error rate exceeded"),
            .regex => bufPrintOr(buf, "rule '{s}' fired", .{self.subject}, "alert rule fired"),
            .first_seen => bufPrintOr(buf, "new error on {s}", .{self.source}, "new error signature"),
            .silence => bufPrintOr(buf, "{s} went quiet", .{self.source}, "log went quiet"),
        };
    }
};

fn bufPrintOr(buf: []u8, comptime fmt: []const u8, args: anytype, fallback: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch fallback;
}

// ─── Rendering ────────────────────────────────────────────────────────────

/// Output budget for the log-derived part of a message, in bytes *after*
/// escaping. Each is under the channel's own cap with room to spare, and
/// because the count is of encoded bytes — never fewer than the characters
/// they decode to — staying under it is sufficient, not just likely.
///
///   Telegram  4096 characters per message
///   Slack     3000 characters per mrkdwn section
///   Discord   4096 per embed description, 2000 per message
const budget = struct {
    const telegram: usize = 3_400;
    const slack: usize = 2_700;
    const discord: usize = 1_700;
};

/// Every rendered body fits here: the largest budget plus the fixed chrome
/// around it, rounded up.
pub const max_body_bytes: usize = 8 * 1024;

pub const RenderError = error{NotTemplated} || std.Io.Writer.Error;

/// Renders `a` into `target`'s request body. `buf` should be
/// `max_body_bytes`; the returned slice points into it.
pub fn render(buf: []u8, target: Target, a: Alert) RenderError![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    switch (target.kind) {
        .raw => return error.NotTemplated,
        .telegram => try renderTelegram(&w, target.chat_id, a),
        .slack => try renderSlack(&w, a),
        .discord => try renderDiscord(&w, a),
    }
    return w.buffered();
}

fn renderTelegram(w: *std.Io.Writer, chat_id: []const u8, a: Alert) RenderError!void {
    var head_buf: [192]u8 = undefined;
    const head = a.headline(&head_buf);

    try w.writeAll("{\"chat_id\":");
    try jsonString(w, chat_id);
    try w.writeAll(",\"parse_mode\":\"HTML\",\"disable_web_page_preview\":true,\"text\":\"");

    var b: Body = .{ .w = w, .kind = .telegram, .left = budget.telegram };
    try b.markup(a.event.emoji());
    try b.markup(" <b>");
    try b.text(head);
    try b.markup("</b>");
    try writeMeta(&b, a);
    try writeDetail(&b, a);
    if (trimTrace(a.trace)) |trace| {
        try b.newline();
        try b.markup("<pre>");
        try b.text(trace);
        try b.markup("</pre>");
    }
    try writeCounts(&b, a);

    try w.writeAll("\"}");
}

fn renderSlack(w: *std.Io.Writer, a: Alert) RenderError!void {
    var head_buf: [192]u8 = undefined;
    const head = a.headline(&head_buf);

    // `text` is the notification fallback — what a phone shows before the
    // block is rendered — so it stays short and carries no markup.
    try w.writeAll("{\"text\":\"");
    {
        var fb: Body = .{ .w = w, .kind = .slack, .left = 256 };
        try fb.markup(a.event.emoji());
        try fb.markup(" ");
        try fb.text(head);
    }
    try w.writeAll("\",\"blocks\":[{\"type\":\"section\",\"text\":{\"type\":\"mrkdwn\",\"text\":\"");

    var b: Body = .{ .w = w, .kind = .slack, .left = budget.slack };
    try b.markup(a.event.emoji());
    try b.markup(" *");
    try b.text(head);
    try b.markup("*");
    try writeMeta(&b, a);
    try writeDetail(&b, a);
    if (trimTrace(a.trace)) |trace| {
        try b.newline();
        try b.markup("```\\n");
        try b.fenced(trace);
        try b.markup("\\n```");
    }
    try writeCounts(&b, a);

    try w.writeAll("\"}}]}");
}

fn renderDiscord(w: *std.Io.Writer, a: Alert) RenderError!void {
    var head_buf: [192]u8 = undefined;
    const head = a.headline(&head_buf);

    try w.writeAll("{\"embeds\":[{\"title\":\"");
    {
        var tb: Body = .{ .w = w, .kind = .discord, .left = 200 };
        try tb.markup(a.event.emoji());
        try tb.markup(" ");
        // The title is plain text to Discord — no markdown is parsed there,
        // so it must not carry the backslashes `Body` would add for the
        // description.
        try tb.plain(head);
    }
    try w.print("\",\"color\":{d},\"description\":\"", .{a.event.color()});

    var b: Body = .{ .w = w, .kind = .discord, .left = budget.discord };
    try writeMeta(&b, a);
    try writeDetail(&b, a);
    if (trimTrace(a.trace)) |trace| {
        try b.newline();
        try b.markup("```\\n");
        try b.fenced(trace);
        try b.markup("\\n```");
    }
    try writeCounts(&b, a);

    try w.writeAll("\"}]}");
}

/// The context line: which detector, which file, which process. Written only
/// when at least one of the three is present, so an event that carries none
/// of them doesn't open with a blank line.
fn writeMeta(b: *Body, a: Alert) RenderError!void {
    if (a.marker.len == 0 and a.source.len == 0 and a.pid == null) return;
    try b.newline();

    var wrote = false;
    if (a.marker.len > 0) {
        try b.text(a.marker);
        wrote = true;
    }
    if (a.source.len > 0) {
        if (wrote) try b.markup(sep);
        try b.text(a.source);
        wrote = true;
    }
    if (a.pid) |p| {
        if (wrote) try b.markup(sep);
        try b.number("pid {d}", p);
    }
}

/// Middle dot with spaces, the same separator the reader uses between fields.
const sep = " \u{00B7} ";

/// The trace with its surrounding blank lines removed, or null if there is
/// nothing left. A collected trace usually ends in a newline, which inside a
/// code fence renders as an empty line before the closing marker.
fn trimTrace(trace: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, trace, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

fn writeDetail(b: *Body, a: Alert) RenderError!void {
    if (a.detail.len == 0) return;
    try b.newline();
    try b.text(a.detail);
}

/// The trailing tally. Only what the event actually carries — a rate rule has
/// no crash count and a crash has no window.
fn writeCounts(b: *Body, a: Alert) RenderError!void {
    var wrote = false;
    if (a.observed) |n| {
        try b.newline();
        try b.number("{d}", n);
        if (a.threshold) |t| {
            try b.markup("/");
            try b.number("{d}", t);
        }
        if (a.window_ms) |ms| {
            try b.markup(" in ");
            try b.duration(ms);
        }
        wrote = true;
    }
    // Zeroes are left out: "restarts: 0" is not a fact anyone reads an alert
    // for, and it costs a line in a message that is already tight.
    if (a.crash_count) |c| if (c > 0) {
        if (wrote) try b.markup(sep) else try b.newline();
        try b.number("crashes: {d}", c);
        wrote = true;
    };
    if (a.restart_count) |r| if (r > 0) {
        if (wrote) try b.markup(sep) else try b.newline();
        try b.number("restarts: {d}", r);
    };
}

/// Writes into a JSON string that is already open, applying the channel's own
/// escaping on the way, and stops once the budget is spent.
///
/// The two layers have to happen together: Telegram wants `<` as `&lt;` and
/// JSON wants `"` as `\"`, and doing them in separate passes needs a scratch
/// buffer between them for no gain. Charging the budget here — against bytes
/// that have already been escaped — is what makes the finished body's size
/// something the code knows rather than estimates.
const Body = struct {
    w: *std.Io.Writer,
    kind: Kind,
    /// Remaining output bytes for caller-supplied text. Markup this file
    /// authors is not charged: it is fixed, small, and dropping half of a
    /// `</pre>` would corrupt the message.
    left: usize,
    truncated: bool = false,
    /// Whether anything has reached the message yet. A Discord embed's
    /// description starts with the metadata line — there is no headline above
    /// it, that lives in the title — so the separator before it has nothing
    /// to separate and would open the message with a blank line.
    started: bool = false,
    /// Backing store for the multi-byte encodings below. The longest is a
    /// markdown-escaped control byte: two bytes of backslash plus `\u00XX`.
    scratch: [8]u8 = undefined,

    /// Markup this file authors. Written verbatim — it is already valid for
    /// both the channel and JSON.
    fn markup(self: *Body, s: []const u8) RenderError!void {
        if (s.len > 0) self.started = true;
        try self.w.writeAll(s);
    }

    /// Line break between sections, suppressed at the very start.
    fn newline(self: *Body) RenderError!void {
        if (!self.started) return;
        try self.w.writeAll("\\n");
    }

    /// A number we formatted ourselves. Bounded by construction, so unlike
    /// `text` it needs no escaping — but it is still charged so a long tally
    /// cannot push a nearly-full message over.
    fn number(self: *Body, comptime fmt: []const u8, value: anytype) RenderError!void {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, .{value}) catch return;
        if (s.len > self.left) return;
        self.left -= s.len;
        self.started = true;
        try self.w.writeAll(s);
    }

    fn duration(self: *Body, ms: u64) RenderError!void {
        if (ms >= 3_600_000 and ms % 3_600_000 == 0) return self.number("{d}h", ms / 3_600_000);
        if (ms >= 60_000 and ms % 60_000 == 0) return self.number("{d}m", ms / 60_000);
        if (ms >= 1_000 and ms % 1_000 == 0) return self.number("{d}s", ms / 1_000);
        return self.number("{d}ms", ms);
    }

    /// Log-derived text, escaped for the channel and then for JSON.
    fn text(self: *Body, s: []const u8) RenderError!void {
        return self.write(s, .free);
    }

    /// Log-derived text going inside a triple-backtick fence.
    ///
    /// A fence cannot be escaped from within — there is no syntax for it — so
    /// a backtick in the payload would end the block early and let the rest
    /// of the trace be reinterpreted as markup. Backticks do not occur in
    /// stack traces, and losing one to an apostrophe costs nothing next to
    /// the alternative.
    fn fenced(self: *Body, s: []const u8) RenderError!void {
        return self.write(s, .fenced);
    }

    /// Log-derived text in a field the channel does not parse as markup at
    /// all, such as a Discord embed title.
    fn plain(self: *Body, s: []const u8) RenderError!void {
        return self.write(s, .literal);
    }

    const Context = enum { free, fenced, literal };

    fn write(self: *Body, s: []const u8, ctx: Context) RenderError!void {
        for (s) |c| {
            const byte = if (ctx == .fenced and c == '`') '\'' else c;
            const piece = self.encode(byte, ctx);
            if (piece.len > self.left) {
                // Out of room. Say so in the message — a trace that just
                // stops looks like a trace that was that short — then stop,
                // because every later byte fails the same test.
                //
                // The ellipsis is not charged against the budget: by the time
                // it is written the budget is by definition nearly spent, and
                // subtracting it up front would mean every message that fits
                // comfortably still paid for a marker it never shows. Three
                // bytes fit inside the headroom `budget` leaves under the
                // channel's real cap.
                if (!self.truncated) {
                    self.truncated = true;
                    self.left = 0;
                    try self.w.writeAll("...");
                }
                return;
            }
            self.left -= piece.len;
            self.started = true;
            try self.w.writeAll(piece);
        }
    }

    /// One input byte as the bytes that will appear in the request body.
    /// Returns a slice into either a constant or `scratch`, which is why the
    /// caller writes it before asking for the next one.
    fn encode(self: *Body, c: u8, ctx: Context) []const u8 {
        // Telegram parses the message as HTML; Slack requires exactly these
        // three escaped in mrkdwn, inside code blocks included. Entities are
        // pure ASCII, so the JSON layer below has nothing left to do to them.
        if (self.kind == .telegram or self.kind == .slack) {
            switch (c) {
                '&' => return "&amp;",
                '<' => return "&lt;",
                '>' => return "&gt;",
                else => {},
            }
        }

        var n: usize = 0;
        // Discord renders markdown in an embed description. Inside a fence it
        // is inert and in a title it is never parsed, so only free text needs
        // neutralising — with a backslash that is itself a JSON escape, hence
        // two bytes here for one in the delivered message.
        if (self.kind == .discord and ctx == .free and discordMeta(c)) {
            self.scratch[0] = '\\';
            self.scratch[1] = '\\';
            n = 2;
        }

        // JSON, which every channel shares.
        switch (c) {
            '"' => {
                self.scratch[n] = '\\';
                self.scratch[n + 1] = '"';
                return self.scratch[0 .. n + 2];
            },
            '\\' => {
                self.scratch[n] = '\\';
                self.scratch[n + 1] = '\\';
                return self.scratch[0 .. n + 2];
            },
            '\n', '\r', '\t' => {
                self.scratch[n] = '\\';
                self.scratch[n + 1] = switch (c) {
                    '\n' => 'n',
                    '\r' => 'r',
                    else => 't',
                };
                return self.scratch[0 .. n + 2];
            },
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {
                self.scratch[n] = '\\';
                self.scratch[n + 1] = 'u';
                self.scratch[n + 2] = '0';
                self.scratch[n + 3] = '0';
                self.scratch[n + 4] = hex(c >> 4);
                self.scratch[n + 5] = hex(c & 0xf);
                return self.scratch[0 .. n + 6];
            },
            else => {
                // Everything else, high-bit bytes included: raw. Escaping a
                // UTF-8 continuation byte as `\u00XX` would decode it as that
                // code point and mangle the character it belongs to.
                self.scratch[n] = c;
                return self.scratch[0 .. n + 1];
            },
        }
    }
};

/// Characters Discord reads as markup in free text. `-` and `#` are markup
/// only at the start of a line and escaping every one of them would fill a
/// timestamp with backslashes, so they are left alone — the cost of being
/// wrong is a log line rendered as a list item.
fn discordMeta(c: u8) bool {
    return switch (c) {
        '*', '_', '~', '|', '`', '\\' => true,
        else => false,
    };
}

fn hex(nibble: u8) u8 {
    return if (nibble < 10) '0' + nibble else 'a' + (nibble - 10);
}

fn jsonString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0x00...0x1f, 0x7f => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

// ─── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

const sample: Alert = .{
    .event = .service_crash,
    .subject = "api",
    .source = "/var/log/api.log",
    .marker = "go_panic",
    .detail = "panic: runtime error: invalid memory address",
    .trace = "goroutine 1 [running]:\nmain.handle(0x0)\n\t/src/main.go:42 +0x1f",
    .pid = 1234,
    .crash_count = 3,
    .restart_count = 1,
};

/// Parses a rendered body and returns the message text a human would see,
/// with JSON's escaping already undone. Every assertion below goes through
/// this rather than searching the raw bytes: what matters is what arrives at
/// the other end, not how it was spelled on the wire.
fn messageText(allocator: std.mem.Allocator, kind: Kind, body: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const text = switch (kind) {
        .telegram => obj.get("text").?.string,
        .slack => obj.get("blocks").?.array.items[0].object.get("text").?.object.get("text").?.string,
        .discord => obj.get("embeds").?.array.items[0].object.get("description").?.string,
        .raw => unreachable,
    };
    return allocator.dupe(u8, text);
}

test "parseTelegram: splits on the last colon and builds the send URL" {
    const allocator = testing.allocator;
    var t = try parseTelegram(allocator, "123456789:AAHkq_ExampleTokenValue-01:-1001234567890");
    defer t.deinit(allocator);

    try testing.expectEqual(Kind.telegram, t.kind);
    try testing.expectEqualStrings(
        "https://api.telegram.org/bot123456789:AAHkq_ExampleTokenValue-01/sendMessage",
        t.url,
    );
    try testing.expectEqualStrings("-1001234567890", t.chat_id);
}

test "parseTelegram: accepts an @channel and a positive chat id" {
    const allocator = testing.allocator;
    var a = try parseTelegram(allocator, "1:AAH:@my_alerts");
    defer a.deinit(allocator);
    try testing.expectEqualStrings("@my_alerts", a.chat_id);

    var b = try parseTelegram(allocator, "1:AAH:441122");
    defer b.deinit(allocator);
    try testing.expectEqualStrings("441122", b.chat_id);
}

test "parseTelegram: rejects a token with no chat id" {
    const allocator = testing.allocator;
    // The commonest mistake: pasting just the bot token. Without the chat-id
    // shape check this would silently become chat_id="AAHsecret" and POST
    // into the void for the life of the process.
    try testing.expectError(error.InvalidTelegramTarget, parseTelegram(allocator, "123456789:AAHsecret"));
    try testing.expectError(error.InvalidTelegramTarget, parseTelegram(allocator, "nocolonatall"));
    try testing.expectError(error.InvalidTelegramTarget, parseTelegram(allocator, "123:AAH:"));
    try testing.expectError(error.InvalidTelegramTarget, parseTelegram(allocator, "123:AAH:@"));
}

test "telegram: body is valid JSON carrying the chat id and an HTML message" {
    const allocator = testing.allocator;
    var buf: [max_body_bytes]u8 = undefined;
    const body = try render(&buf, .{ .kind = .telegram, .url = "u", .chat_id = "-100777" }, sample);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("-100777", obj.get("chat_id").?.string);
    try testing.expectEqualStrings("HTML", obj.get("parse_mode").?.string);

    const text = obj.get("text").?.string;
    try testing.expect(std.mem.indexOf(u8, text, "<b>api crashed</b>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "go_panic") != null);
    try testing.expect(std.mem.indexOf(u8, text, "pid 1234") != null);
    try testing.expect(std.mem.indexOf(u8, text, "<pre>goroutine 1 [running]:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "crashes: 3") != null);
    try testing.expect(std.mem.indexOf(u8, text, "restarts: 1") != null);
}

test "slack: body is a mrkdwn section with a plain-text fallback" {
    const allocator = testing.allocator;
    var buf: [max_body_bytes]u8 = undefined;
    const body = try render(&buf, .{ .kind = .slack, .url = "u" }, sample);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    // The fallback must not carry markup — it is shown raw in notifications.
    try testing.expect(std.mem.indexOf(u8, obj.get("text").?.string, "*") == null);

    const section = obj.get("blocks").?.array.items[0].object;
    try testing.expectEqualStrings("section", section.get("type").?.string);
    const text = section.get("text").?.object.get("text").?.string;
    try testing.expect(std.mem.indexOf(u8, text, "*api crashed*") != null);
    try testing.expect(std.mem.indexOf(u8, text, "```") != null);
}

test "discord: body is an embed coloured from the level palette" {
    const allocator = testing.allocator;
    var buf: [max_body_bytes]u8 = undefined;
    const body = try render(&buf, .{ .kind = .discord, .url = "u" }, sample);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const embed = parsed.value.object.get("embeds").?.array.items[0].object;
    try testing.expect(std.mem.indexOf(u8, embed.get("title").?.string, "api crashed") != null);
    try testing.expectEqual(@as(i64, 0xc02626), embed.get("color").?.integer);
    // `_` is markup to Discord, so the marker arrives escaped — which is
    // exactly what the reader is meant to see rendered back as `go_panic`.
    try testing.expect(std.mem.indexOf(u8, embed.get("description").?.string, "go\\_panic") != null);
}

test "every channel escapes markup that arrived in the log line" {
    const allocator = testing.allocator;
    // A line that is hostile to all three at once: HTML for Telegram, angle
    // brackets for Slack, and markdown for Discord.
    const hostile: Alert = .{
        .event = .regex,
        .subject = "rule",
        .source = "app.log",
        .detail = "<script>alert(1)</script> a*b_c & d|e",
    };

    for ([_]Kind{ .telegram, .slack, .discord }) |kind| {
        var buf: [max_body_bytes]u8 = undefined;
        const body = try render(&buf, .{ .kind = kind, .url = "u" }, hostile);
        const text = try messageText(allocator, kind, body);
        defer allocator.free(text);

        switch (kind) {
            .telegram, .slack => {
                // The tag must arrive as text, not as a tag. `<b>` from our
                // own markup is still there, so look for the payload's.
                try testing.expect(std.mem.indexOf(u8, text, "<script>") == null);
                try testing.expect(std.mem.indexOf(u8, text, "&lt;script&gt;") != null);
                try testing.expect(std.mem.indexOf(u8, text, "&amp; d") != null);
            },
            .discord => {
                try testing.expect(std.mem.indexOf(u8, text, "a\\*b\\_c") != null);
                try testing.expect(std.mem.indexOf(u8, text, "d\\|e") != null);
            },
            .raw => unreachable,
        }
    }
}

test "a backslash in the payload survives Discord's escaping" {
    const allocator = testing.allocator;
    const a: Alert = .{
        .event = .regex,
        .subject = "r",
        .source = "app.log",
        .detail = "open C:\\Users\\svc\\app.log failed",
    };
    var buf: [max_body_bytes]u8 = undefined;
    const body = try render(&buf, .{ .kind = .discord, .url = "u" }, a);
    const text = try messageText(allocator, .discord, body);
    defer allocator.free(text);

    // Each backslash must reach Discord as an escaped backslash. Emitting it
    // bare would make it escape the next character instead, eating the `U`
    // and the `s` and leaving the operator with a path that never existed.
    try testing.expect(std.mem.indexOf(u8, text, "C:\\\\Users\\\\svc\\\\app.log") != null);
}

test "a trace longer than the budget is cut, not dropped" {
    const allocator = testing.allocator;
    var long: [64 * 1024]u8 = undefined;
    for (&long, 0..) |*c, i| c.* = if (i % 64 == 63) '\n' else 'x';

    const a: Alert = .{
        .event = .service_crash,
        .subject = "api",
        .source = "api.log",
        .marker = "go_panic",
        .detail = "panic: boom",
        .trace = &long,
    };

    for ([_]Kind{ .telegram, .slack, .discord }) |kind| {
        var buf: [max_body_bytes]u8 = undefined;
        const body = try render(&buf, .{ .kind = kind, .url = "u" }, a);
        const text = try messageText(allocator, kind, body);
        defer allocator.free(text);

        // The headline and the crash detail are what the operator actually
        // needs; the trace is what has to give. (Discord carries the headline
        // in the embed's title, which has a budget of its own.)
        if (kind != .discord) try testing.expect(std.mem.indexOf(u8, text, "api crashed") != null);
        try testing.expect(std.mem.indexOf(u8, text, "panic: boom") != null);
        try testing.expect(std.mem.indexOf(u8, text, "...") != null);

        // And the whole message stays inside the channel's cap, which is the
        // property the byte budget exists to guarantee.
        const cap: usize = switch (kind) {
            .telegram => 4096,
            .slack => 3000,
            .discord => 2000,
            .raw => unreachable,
        };
        try testing.expect(text.len < cap);
    }
}

test "a backtick cannot break out of a fenced trace" {
    const allocator = testing.allocator;
    const a: Alert = .{
        .event = .service_crash,
        .subject = "api",
        .source = "api.log",
        .trace = "at eval(`rm -rf`)\n```\nescaped?",
    };
    for ([_]Kind{ .slack, .discord }) |kind| {
        var buf: [max_body_bytes]u8 = undefined;
        const body = try render(&buf, .{ .kind = kind, .url = "u" }, a);
        const text = try messageText(allocator, kind, body);
        defer allocator.free(text);

        // Exactly two fences: the one we opened and the one we closed.
        var fences: usize = 0;
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, text, i, "```")) |at| : (i = at + 3) fences += 1;
        try testing.expectEqual(@as(usize, 2), fences);
    }
}

test "multi-byte UTF-8 passes through untouched" {
    const allocator = testing.allocator;
    const a: Alert = .{
        .event = .first_seen,
        .subject = "first_seen",
        .source = "app.log",
        .detail = "ошибка соединения / 接続失敗 / 🚀",
    };
    for ([_]Kind{ .telegram, .slack, .discord }) |kind| {
        var buf: [max_body_bytes]u8 = undefined;
        const body = try render(&buf, .{ .kind = kind, .url = "u" }, a);
        const text = try messageText(allocator, kind, body);
        defer allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "ошибка соединения / 接続失敗 / 🚀") != null);
    }
}

test "rate rules render their threshold and window" {
    const allocator = testing.allocator;
    const a: Alert = .{
        .event = .error_rate,
        .subject = "error_rate",
        .source = "app.log",
        .detail = "ERROR upstream timed out",
        .observed = 27,
        .threshold = 10,
        .window_ms = 60_000,
    };
    var buf: [max_body_bytes]u8 = undefined;
    const body = try render(&buf, .{ .kind = .slack, .url = "u" }, a);
    const text = try messageText(allocator, .slack, body);
    defer allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "27/10 in 1m") != null);
}

test "an event with no metadata renders without a leading blank line" {
    const allocator = testing.allocator;
    const a: Alert = .{ .event = .kernel_panic, .subject = "", .source = "" };
    var buf: [max_body_bytes]u8 = undefined;
    const body = try render(&buf, .{ .kind = .telegram, .url = "u", .chat_id = "1" }, a);
    const text = try messageText(allocator, .telegram, body);
    defer allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\n\n") == null);
    try testing.expect(std.mem.endsWith(u8, text, "</b>"));
}

test "render refuses a raw target rather than inventing a shape for it" {
    var buf: [max_body_bytes]u8 = undefined;
    try testing.expectError(error.NotTemplated, render(&buf, .{ .kind = .raw, .url = "u" }, sample));
}

test "looksTemplated spots the well-known chat endpoints" {
    try testing.expectEqual(Kind.slack, looksTemplated("https://hooks.slack.com/services/T/B/x").?);
    try testing.expectEqual(Kind.discord, looksTemplated("https://discord.com/api/webhooks/1/x").?);
    try testing.expectEqual(Kind.telegram, looksTemplated("https://api.telegram.org/bot1:x/sendMessage").?);
    try testing.expect(looksTemplated("https://alerts.internal/ingest") == null);
}

test "a Discord description does not open with a blank line" {
    const allocator = testing.allocator;
    var buf: [max_body_bytes]u8 = undefined;
    const body = try render(&buf, .{ .kind = .discord, .url = "u" }, sample);
    const text = try messageText(allocator, .discord, body);
    defer allocator.free(text);
    // The headline lives in the embed's title, so the description starts at
    // the metadata line with nothing above it to separate from.
    try testing.expect(text.len > 0 and text[0] != '\n');
}

test "counters that are zero are left out" {
    const allocator = testing.allocator;
    const a: Alert = .{
        .event = .service_crash,
        .subject = "api",
        .source = "api.log",
        .detail = "panic: boom",
        .crash_count = 1,
        .restart_count = 0,
    };
    var buf: [max_body_bytes]u8 = undefined;
    const body = try render(&buf, .{ .kind = .slack, .url = "u" }, a);
    const text = try messageText(allocator, .slack, body);
    defer allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "crashes: 1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "restarts") == null);
}

test "a trace's trailing newline does not become a blank line in the fence" {
    const allocator = testing.allocator;
    const a: Alert = .{
        .event = .service_crash,
        .subject = "api",
        .source = "api.log",
        .trace = "\nmain.go:42\n\n",
    };
    for ([_]Kind{ .slack, .discord }) |kind| {
        var buf: [max_body_bytes]u8 = undefined;
        const body = try render(&buf, .{ .kind = kind, .url = "u" }, a);
        const text = try messageText(allocator, kind, body);
        defer allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "```\nmain.go:42\n```") != null);
    }
}

test "a trace of nothing but whitespace is not rendered at all" {
    const allocator = testing.allocator;
    const a: Alert = .{ .event = .service_crash, .subject = "api", .source = "api.log", .trace = "\n  \n" };
    var buf: [max_body_bytes]u8 = undefined;
    const body = try render(&buf, .{ .kind = .telegram, .url = "u", .chat_id = "1" }, a);
    const text = try messageText(allocator, .telegram, body);
    defer allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "<pre>") == null);
}
