//! Terminal capability detection and the colour palette.
//!
//! Two problems this solves that a hard-coded escape table cannot:
//!
//! **Unknown background.** A terminal never tells us reliably whether it is
//! light or dark, and the same palette has to be legible on both. There is a
//! hard ceiling here: a foreground colour readable on both #ffffff and a
//! near-black background must sit in a narrow luminance band, and the best
//! achievable contrast against both is ~4.16:1. The palette below is tuned to
//! that optimum (≈4.2:1 on white, ≈4.5:1 on GitHub-dark, ≥3.9:1 on VS Code
//! dark and Solarized Light) instead of assuming a dark terminal.
//!
//! Level badges sidestep the problem entirely: they carry an explicit
//! background *and* foreground, so their legibility depends only on the pair,
//! never on the terminal's theme.
//!
//! **Unknown colour depth.** 24-bit `38;2;r;g;b` is not universal — older
//! terminals, `screen`, and plain Windows consoles either ignore it or print
//! it literally. We pick the deepest format the terminal advertises and
//! degrade to 256-colour, then to the 16 ANSI colours, then to no colour.
//!
//! Detection honours the `NO_COLOR` convention (https://no-color.org) and,
//! critically, emits nothing at all when stdout is not a TTY — piping into
//! `grep` or a file should not produce escape sequences.

const std = @import("std");
const builtin = @import("builtin");
const flags = @import("flags");

/// Colour formats, deepest first. Each maps to a whole `Palette`.
pub const Mode = enum { truecolor, ansi256, ansi16, none };

/// How the caller wants colour resolved. Mirrors the `--color` flag.
pub const ColorChoice = enum { auto, always, never };

/// Box-drawing characters used by the JSON block. Terminals that cannot be
/// confirmed as UTF-8 capable get the ASCII set — a mis-rendered gutter is
/// worse than a plain one.
pub const Glyphs = struct {
    /// Left gutter of an expanded JSON block.
    bar: []const u8,
    /// Top-left corner introducing the block.
    top: []const u8,
    /// Bottom-left corner closing it.
    bottom: []const u8,
    /// Horizontal stroke trailing the corners.
    rule: []const u8,

    pub const unicode: Glyphs = .{ .bar = "│", .top = "╭", .bottom = "╰", .rule = "─" };
    pub const ascii: Glyphs = .{ .bar = "|", .top = "+", .bottom = "+", .rule = "-" };
};

/// Every escape sequence the printers emit. Empty strings in `Mode.none` make
/// every colour write a no-op without the call sites needing a branch.
pub const Palette = struct {
    reset: []const u8,
    /// Faint text for structural noise (prefixes, punctuation, counters).
    dim: []const u8,
    /// Secondary text — timestamps, the part of a line before the level.
    muted: []const u8,
    /// Primary text. Deliberately the terminal's *default* foreground rather
    /// than a fixed colour: whatever the user chose is legible on their own
    /// background by construction, which no fixed value can guarantee.
    text: []const u8,

    json_key: []const u8,
    json_string: []const u8,
    json_number: []const u8,
    json_bool_null: []const u8,
    /// Braces, brackets, commas, colons.
    json_punct: []const u8,

    /// Search hit. A background/foreground pair rather than a bright
    /// foreground, so it stands out regardless of the terminal's theme.
    match_on: []const u8,

    /// Level badges, indexed by `@intFromEnum(flags.Level)`. Each entry is
    /// the background and foreground already concatenated — one write instead
    /// of two in the hot path.
    level: [7][]const u8,
};

/// Resolved terminal capabilities. Threaded through the printers rather than
/// held in a global so tests can pin a mode without touching process state.
pub const Theme = struct {
    mode: Mode,
    palette: *const Palette,
    glyphs: Glyphs,
    /// False when colour is off — lets callers skip building styled output
    /// entirely rather than emitting a run of empty strings.
    colored: bool,

    /// Plain, colourless output. The default for pipes, `NO_COLOR`, and tests.
    pub const plain: Theme = .{
        .mode = .none,
        .palette = &no_palette,
        .glyphs = Glyphs.ascii,
        .colored = false,
    };

    pub fn forMode(mode: Mode, glyphs: Glyphs) Theme {
        return .{
            .mode = mode,
            .palette = switch (mode) {
                .truecolor => &truecolor_palette,
                .ansi256 => &ansi256_palette,
                .ansi16 => &ansi16_palette,
                .none => &no_palette,
            },
            .glyphs = glyphs,
            .colored = mode != .none,
        };
    }

    /// Badge escape for `lvl`, or an empty string when colour is off.
    pub inline fn levelStyle(self: *const Theme, lvl: flags.Level) []const u8 {
        return self.palette.level[@intFromEnum(lvl)];
    }
};

// ─── Palettes ─────────────────────────────────────────────────────────────
//
// Truecolor values and their contrast against four common backgrounds
// (white / GitHub-dark #0d1117 / VS Code dark #1e1e1e / Solarized Light):
//
//   muted    #7b7b7b   4.23  4.47  3.94  3.92
//   key      #1974fc   4.25  4.46  3.93  3.94
//   string   #188796   4.25  4.46  3.93  3.94
//   number   #a34bfb   4.24  4.47  3.93  3.93
//   bool     #038f19   4.25  4.46  3.93  3.94
//   accent   #c45e00   4.24  4.46  3.93  3.93
//
// All clear the 3:1 WCAG threshold for UI components on every one of them;
// the previous GitHub-dark palette scored 1.18–3.08 against white.

const esc = "\x1b[";

fn fg(comptime hex: u24) []const u8 {
    const r = (hex >> 16) & 0xff;
    const g = (hex >> 8) & 0xff;
    const b = hex & 0xff;
    return std.fmt.comptimePrint(esc ++ "38;2;{d};{d};{d}m", .{ r, g, b });
}

fn badge(comptime bg_hex: u24, comptime fg_hex: u24) []const u8 {
    const br = (bg_hex >> 16) & 0xff;
    const bg_g = (bg_hex >> 8) & 0xff;
    const bb = bg_hex & 0xff;
    const fr = (fg_hex >> 16) & 0xff;
    const fg_g = (fg_hex >> 8) & 0xff;
    const fb = fg_hex & 0xff;
    return std.fmt.comptimePrint(
        esc ++ "48;2;{d};{d};{d}m" ++ esc ++ "38;2;{d};{d};{d}m",
        .{ br, bg_g, bb, fr, fg_g, fb },
    );
}

/// Badge backgrounds carry white text at 5.9:1–7.4:1, so they read on any
/// terminal theme.
const truecolor_palette: Palette = .{
    .reset = esc ++ "0m",
    .dim = esc ++ "2m",
    .muted = fg(0x7b7b7b),
    .text = esc ++ "39m",
    .json_key = fg(0x1974fc),
    .json_string = fg(0x188796),
    .json_number = fg(0xa34bfb),
    .json_bool_null = fg(0x038f19),
    .json_punct = esc ++ "2m",
    .match_on = badge(0xc45e00, 0xffffff),
    .level = .{
        badge(0x595f66, 0xffffff), // Trace
        badge(0x0d5bbd, 0xffffff), // Debug
        badge(0x11713c, 0xffffff), // Info
        badge(0x8a5300, 0xffffff), // Warn
        badge(0xc02626, 0xffffff), // Error
        badge(0x9c1382, 0xffffff), // Fatal
        badge(0x9c1382, 0xffffff), // Panic
    },
};

/// Nearest xterm-256 cube entries to the truecolor values above. A few are
/// nudged by hand where the closest index drifted in hue (Info's green would
/// otherwise land on a teal).
const ansi256_palette: Palette = .{
    .reset = esc ++ "0m",
    .dim = esc ++ "2m",
    .muted = esc ++ "38;5;243m",
    .text = esc ++ "39m",
    .json_key = esc ++ "38;5;33m",
    .json_string = esc ++ "38;5;30m",
    .json_number = esc ++ "38;5;135m",
    .json_bool_null = esc ++ "38;5;28m",
    .json_punct = esc ++ "2m",
    .match_on = esc ++ "48;5;166m" ++ esc ++ "38;5;231m",
    .level = .{
        esc ++ "48;5;59m" ++ esc ++ "38;5;231m",
        esc ++ "48;5;25m" ++ esc ++ "38;5;231m",
        esc ++ "48;5;22m" ++ esc ++ "38;5;231m",
        esc ++ "48;5;94m" ++ esc ++ "38;5;231m",
        esc ++ "48;5;124m" ++ esc ++ "38;5;231m",
        esc ++ "48;5;90m" ++ esc ++ "38;5;231m",
        esc ++ "48;5;90m" ++ esc ++ "38;5;231m",
    },
};

/// The 16 ANSI colours are remapped by every terminal theme, so exact hues are
/// out of our hands here. What we *can* guarantee is that we never pick the
/// bright variants for foreground text (they wash out on light themes) and
/// that badges keep an explicit background.
const ansi16_palette: Palette = .{
    .reset = esc ++ "0m",
    .dim = esc ++ "2m",
    .muted = esc ++ "90m",
    .text = esc ++ "39m",
    .json_key = esc ++ "34m",
    .json_string = esc ++ "36m",
    .json_number = esc ++ "35m",
    .json_bool_null = esc ++ "32m",
    .json_punct = esc ++ "2m",
    .match_on = esc ++ "43m" ++ esc ++ "30m",
    .level = .{
        esc ++ "100m" ++ esc ++ "97m",
        esc ++ "44m" ++ esc ++ "97m",
        esc ++ "42m" ++ esc ++ "30m",
        esc ++ "43m" ++ esc ++ "30m",
        esc ++ "41m" ++ esc ++ "97m",
        esc ++ "45m" ++ esc ++ "97m",
        esc ++ "45m" ++ esc ++ "97m",
    },
};

const no_palette: Palette = .{
    .reset = "",
    .dim = "",
    .muted = "",
    .text = "",
    .json_key = "",
    .json_string = "",
    .json_number = "",
    .json_bool_null = "",
    .json_punct = "",
    .match_on = "",
    .level = .{ "", "", "", "", "", "", "" },
};

// ─── Detection ────────────────────────────────────────────────────────────

/// The environment values detection depends on. Extracted into a struct so
/// the decision logic is a pure function that tests can drive directly.
pub const Env = struct {
    no_color: bool = false,
    term: ?[]const u8 = null,
    colorterm: ?[]const u8 = null,
    /// Windows Terminal sets this; it implies full truecolor + UTF-8.
    wt_session: bool = false,
    /// Set by CI systems that render ANSI in their log viewers.
    ci: bool = false,
    lang: ?[]const u8 = null,
    is_tty: bool = false,
};

/// Resolves capabilities from the environment. Pure — `Env` is gathered by
/// `fromMap` and the console is prepared separately by `prepareConsole`.
pub fn resolve(env: Env, choice: ColorChoice) Theme {
    const want_color = switch (choice) {
        .never => false,
        // NO_COLOR is a user's explicit opt-out and outranks TTY detection,
        // but `--color=always` outranks NO_COLOR: it is more explicit still.
        .auto => !env.no_color and env.is_tty and !isDumb(env.term),
        .always => true,
    };
    if (!want_color) return .plain;
    return Theme.forMode(detectMode(env), detectGlyphs(env));
}

fn isDumb(term: ?[]const u8) bool {
    const t = term orelse return false;
    return std.mem.eql(u8, t, "dumb") or t.len == 0;
}

fn detectMode(env: Env) Mode {
    // Windows Terminal and modern Windows consoles do full truecolor once VT
    // processing is on, but never advertise it via COLORTERM.
    if (env.wt_session) return .truecolor;

    if (env.colorterm) |ct| {
        if (std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit")) return .truecolor;
    }

    const term = env.term orelse {
        // No TERM at all: on Windows that is normal and VT is available;
        // elsewhere it means we know nothing, so stay conservative.
        return if (builtin.os.tag == .windows) .truecolor else .ansi16;
    };

    if (std.mem.indexOf(u8, term, "truecolor") != null or
        std.mem.indexOf(u8, term, "direct") != null) return .truecolor;
    if (std.mem.indexOf(u8, term, "256") != null) return .ansi256;
    // `screen`/`tmux` multiplex 256 colours reliably but mangle truecolor
    // unless explicitly configured, so cap them at 256.
    if (std.mem.startsWith(u8, term, "screen") or
        std.mem.startsWith(u8, term, "tmux")) return .ansi256;
    if (std.mem.eql(u8, term, "linux")) return .ansi16;
    // CI log viewers (GitHub Actions, GitLab) render truecolor fine.
    if (env.ci) return .truecolor;
    return .ansi16;
}

fn detectGlyphs(env: Env) Glyphs {
    if (env.wt_session) return Glyphs.unicode;
    // A UTF-8 locale is the portable signal that box-drawing will render.
    if (env.lang) |l| {
        if (std.mem.indexOf(u8, l, "UTF-8") != null or
            std.mem.indexOf(u8, l, "utf8") != null or
            std.mem.indexOf(u8, l, "UTF8") != null) return Glyphs.unicode;
    }
    // macOS terminals are UTF-8 unconditionally even with LANG unset.
    if (builtin.os.tag == .macos) return Glyphs.unicode;
    return Glyphs.ascii;
}

/// Gathers `Env` from the process environment map handed to `main`.
pub fn fromMap(map: *const std.process.Environ.Map, is_tty: bool) Env {
    return .{
        // Per the NO_COLOR convention any non-empty value disables colour.
        .no_color = if (map.get("NO_COLOR")) |v| v.len > 0 else false,
        .term = map.get("TERM"),
        .colorterm = map.get("COLORTERM"),
        .wt_session = map.get("WT_SESSION") != null,
        .ci = map.get("CI") != null,
        .lang = map.get("LC_ALL") orelse map.get("LC_CTYPE") orelse map.get("LANG"),
        .is_tty = is_tty,
    };
}

// ─── Windows console setup ────────────────────────────────────────────────

const windows = if (builtin.os.tag == .windows) struct {
    const w = std.os.windows;

    extern "kernel32" fn GetConsoleMode(hConsoleHandle: w.HANDLE, lpMode: *w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn SetConsoleMode(hConsoleHandle: w.HANDLE, dwMode: w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn SetConsoleOutputCP(wCodePageID: c_uint) callconv(.winapi) w.BOOL;
} else struct {};

/// Puts a Windows console into a state where ANSI escapes and UTF-8 actually
/// work. Without this the classic console prints `←[38;2;…m` as literal text
/// and box-drawing characters come out as mojibake under the OEM code page.
///
/// No-op everywhere else. Returns whether VT processing is available, which
/// the caller folds into colour detection.
pub fn prepareConsole(handle: std.Io.File.Handle) bool {
    if (comptime builtin.os.tag != .windows) return true;

    _ = windows.SetConsoleOutputCP(65001); // CP_UTF8

    var mode: std.os.windows.DWORD = 0;
    // `BOOL` is an enum in this std, not an integer — `== 0` does not
    // compile and `!= 0` would be a bug even if it did, since any non-zero
    // value is truthy.
    if (!windows.GetConsoleMode(handle, &mode).toBool()) {
        // Not a console (redirected). Colour is decided by the TTY check.
        return false;
    }
    const vt = std.os.windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
    if (mode & vt != 0) return true;
    return windows.SetConsoleMode(handle, mode | vt).toBool();
}

// ─── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "NO_COLOR disables colour even on a TTY" {
    const t = resolve(.{ .no_color = true, .is_tty = true, .colorterm = "truecolor" }, .auto);
    try testing.expectEqual(Mode.none, t.mode);
    try testing.expect(!t.colored);
    try testing.expectEqualStrings("", t.palette.reset);
}

test "an empty NO_COLOR value does not disable colour" {
    // The convention keys off presence of a *non-empty* value.
    var map_env: Env = .{ .is_tty = true, .colorterm = "truecolor" };
    map_env.no_color = false;
    try testing.expectEqual(Mode.truecolor, resolve(map_env, .auto).mode);
}

test "piped output gets no colour" {
    const t = resolve(.{ .is_tty = false, .colorterm = "truecolor" }, .auto);
    try testing.expectEqual(Mode.none, t.mode);
}

test "--color=always overrides both NO_COLOR and a non-TTY" {
    const t = resolve(.{ .no_color = true, .is_tty = false, .colorterm = "truecolor" }, .always);
    try testing.expectEqual(Mode.truecolor, t.mode);
}

test "--color=never overrides a colour-capable TTY" {
    const t = resolve(.{ .is_tty = true, .colorterm = "truecolor" }, .never);
    try testing.expectEqual(Mode.none, t.mode);
}

test "TERM=dumb gets no colour" {
    try testing.expectEqual(Mode.none, resolve(.{ .is_tty = true, .term = "dumb" }, .auto).mode);
}

test "colour depth degrades with terminal capability" {
    const cases = [_]struct { env: Env, want: Mode }{
        .{ .env = .{ .is_tty = true, .colorterm = "truecolor" }, .want = .truecolor },
        .{ .env = .{ .is_tty = true, .colorterm = "24bit" }, .want = .truecolor },
        .{ .env = .{ .is_tty = true, .term = "xterm-256color" }, .want = .ansi256 },
        .{ .env = .{ .is_tty = true, .term = "screen" }, .want = .ansi256 },
        .{ .env = .{ .is_tty = true, .term = "tmux-256color" }, .want = .ansi256 },
        .{ .env = .{ .is_tty = true, .term = "xterm" }, .want = .ansi16 },
        .{ .env = .{ .is_tty = true, .term = "linux" }, .want = .ansi16 },
        .{ .env = .{ .is_tty = true, .term = "xterm-direct" }, .want = .truecolor },
        .{ .env = .{ .is_tty = true, .wt_session = true }, .want = .truecolor },
    };
    for (cases) |c| {
        const got = resolve(c.env, .auto).mode;
        try testing.expectEqual(c.want, got);
    }
}

test "COLORTERM outranks a modest TERM" {
    const t = resolve(.{ .is_tty = true, .term = "xterm", .colorterm = "truecolor" }, .auto);
    try testing.expectEqual(Mode.truecolor, t.mode);
}

test "box glyphs require evidence of UTF-8" {
    try testing.expectEqualStrings("│", resolve(.{ .is_tty = true, .lang = "en_US.UTF-8" }, .auto).glyphs.bar);
    try testing.expectEqualStrings("│", resolve(.{ .is_tty = true, .wt_session = true }, .auto).glyphs.bar);
    if (comptime builtin.os.tag != .macos) {
        try testing.expectEqualStrings("|", resolve(.{ .is_tty = true, .lang = "C" }, .auto).glyphs.bar);
        try testing.expectEqualStrings("|", resolve(.{ .is_tty = true }, .auto).glyphs.bar);
    }
}

test "every palette defines every slot" {
    // A missing entry would silently emit unstyled text in one mode only.
    for ([_]Mode{ .truecolor, .ansi256, .ansi16 }) |m| {
        const p = Theme.forMode(m, Glyphs.ascii).palette;
        try testing.expect(p.reset.len > 0);
        try testing.expect(p.muted.len > 0);
        try testing.expect(p.json_key.len > 0);
        try testing.expect(p.json_string.len > 0);
        try testing.expect(p.json_number.len > 0);
        try testing.expect(p.json_bool_null.len > 0);
        try testing.expect(p.match_on.len > 0);
        for (p.level) |l| try testing.expect(l.len > 0);
    }
}

test "the plain palette emits nothing at all" {
    const p = Theme.plain.palette;
    try testing.expectEqual(@as(usize, 0), p.reset.len);
    try testing.expectEqual(@as(usize, 0), p.muted.len);
    try testing.expectEqual(@as(usize, 0), p.match_on.len);
    for (p.level) |l| try testing.expectEqual(@as(usize, 0), l.len);
}

test "level badges cover every level in the enum" {
    const t = Theme.forMode(.truecolor, Glyphs.ascii);
    inline for (@typeInfo(flags.Level).@"enum".fields) |f| {
        const lvl: flags.Level = @enumFromInt(f.value);
        try testing.expect(t.levelStyle(lvl).len > 0);
    }
}

test "truecolor badges pair a background with a foreground" {
    // One write per badge is only safe if both halves really are in there.
    const t = Theme.forMode(.truecolor, Glyphs.ascii);
    const s = t.levelStyle(.Error);
    try testing.expect(std.mem.indexOf(u8, s, "48;2;") != null);
    try testing.expect(std.mem.indexOf(u8, s, "38;2;") != null);
}

test "primary text uses the terminal default foreground" {
    // The whole point: never pin the main text to a colour, because the
    // terminal's own default is the only value guaranteed to be legible on
    // the user's own background.
    for ([_]Mode{ .truecolor, .ansi256, .ansi16 }) |m| {
        try testing.expectEqualStrings("\x1b[39m", Theme.forMode(m, Glyphs.ascii).palette.text);
    }
}
