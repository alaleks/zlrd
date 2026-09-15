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

/// Which background the palette is tuned for.
///
/// This exists because one fixed colour cannot serve both. For 4.5:1 on
/// white a colour needs relative luminance <= 0.183; for 4.5:1 on One Dark
/// it needs >= 0.227. The ranges do not overlap, and the best any single
/// value does on both at once is 3.74:1 — legible, but flat on both. So the
/// foreground colours come in two sets and the background decides.
pub const Background = enum { dark, light };

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
    /// Whether non-ASCII output renders here at all. Callers outside the
    /// JSON block — the banner, error markers — key their own symbol choices
    /// off this rather than duplicating the detection.
    unicode_ok: bool,

    pub const unicode: Glyphs = .{ .bar = "│", .top = "╭", .bottom = "╰", .rule = "─", .unicode_ok = true };
    pub const ascii: Glyphs = .{ .bar = "|", .top = "+", .bottom = "+", .rule = "-", .unicode_ok = false };
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
    /// `json_key` / `json_string` with the opening quote already attached,
    /// and the closing quote with the reset attached. A JSON line is mostly
    /// quoted tokens, and these three are always written adjacently — one
    /// append each beats two.
    json_key_open: []const u8,
    json_string_open: []const u8,
    quote_close: []const u8,
    json_number: []const u8,
    json_bool_null: []const u8,
    /// Braces, brackets, commas, colons.
    json_punct: []const u8,

    /// Search hit. A background/foreground pair rather than a bright
    /// foreground, so it stands out regardless of the terminal's theme.
    ///
    /// Teal, and deliberately not in any level badge's hue. It used to be
    /// orange, which sat between the Warn and Error badges and read as "this
    /// line is bad" rather than "this is what you searched for" — and in the
    /// 16-colour palette it was byte-for-byte the same escape as Warn.
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

    pub fn forMode(mode: Mode, glyphs: Glyphs, background: Background) Theme {
        return .{
            .mode = mode,
            .palette = switch (mode) {
                .truecolor => switch (background) {
                    .dark => &truecolor_dark_palette,
                    .light => &truecolor_light_palette,
                },
                .ansi256 => switch (background) {
                    .dark => &ansi256_dark_palette,
                    .light => &ansi256_light_palette,
                },
                // The 16 ANSI slots are remapped by the terminal's own theme,
                // so they already track the background without our help.
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

/// The non-badge foreground colours of one palette, named so the contrast
/// tests at the bottom of this file can assert on the values themselves
/// rather than on the escape sequences built from them.
const Chroma = struct {
    muted: u24,
    key: u24,
    string: u24,
    number: u24,
    bool_null: u24,
};

/// Tuned for a dark terminal background: every colour clears 6:1 against
/// One Dark (#282c34) and 5.7:1 against Nord (#2e3440), the lightest dark
/// theme in common use. Unusable on white by design — that is what the
/// light set below is for.
const dark_chroma: Chroma = .{
    .muted = 0xb5b5b5,
    .key = 0x8fb5ff,
    .string = 0x00cbba,
    .number = 0xd99dfc,
    .bool_null = 0x00d207,
};

/// Tuned for a white or near-white background: every colour clears 7:1
/// against #ffffff and 6.6:1 against Solarized Light (#fdf6e3).
const light_chroma: Chroma = .{
    .muted = 0x565656,
    .key = 0x0047d7,
    .string = 0x00635a,
    .number = 0x8505ce,
    .bool_null = 0x006503,
};

/// The xterm-256 cube is coarse where these colours live, so each index is
/// the closest one that still clears 4.5:1 against the background the set is
/// for. Two hand-picks: the nearest index to the light `string` came out
/// blue enough (hue 202°) to be mistaken for `key` (207°), so it is pinned
/// to a true teal at 180°, and Info's green would otherwise land on a teal.
const Indices = struct {
    muted: u8,
    key: u8,
    string: u8,
    number: u8,
    bool_null: u8,
};

const dark_indices: Indices = .{ .muted = 249, .key = 111, .string = 43, .number = 183, .bool_null = 40 };
const light_indices: Indices = .{ .muted = 240, .key = 19, .string = 23, .number = 57, .bool_null = 22 };

/// Badge backgrounds carry white text at 5.9:1–7.4:1, so they read on any
/// terminal theme — they bring their own background, which is exactly why
/// they are shared between the light and dark palettes untouched.
const level_badges = [7][]const u8{
    badge(0x595f66, 0xffffff), // Trace
    badge(0x0d5bbd, 0xffffff), // Debug
    badge(0x11713c, 0xffffff), // Info
    badge(0x8a5300, 0xffffff), // Warn
    badge(0xc02626, 0xffffff), // Error
    badge(0x9c1382, 0xffffff), // Fatal
    badge(0x9c1382, 0xffffff), // Panic
};

const ansi256_level_badges = [7][]const u8{
    esc ++ "48;5;59m" ++ esc ++ "38;5;231m",
    esc ++ "48;5;25m" ++ esc ++ "38;5;231m",
    esc ++ "48;5;22m" ++ esc ++ "38;5;231m",
    esc ++ "48;5;94m" ++ esc ++ "38;5;231m",
    esc ++ "48;5;124m" ++ esc ++ "38;5;231m",
    esc ++ "48;5;90m" ++ esc ++ "38;5;231m",
    esc ++ "48;5;90m" ++ esc ++ "38;5;231m",
};

fn idx(comptime i: u8) []const u8 {
    return std.fmt.comptimePrint(esc ++ "38;5;{d}m", .{i});
}

/// `text` is the terminal's *default* foreground in both palettes, not a
/// fixed colour: whatever the user chose is legible on their own background
/// by construction, which no value we pick can guarantee.
fn truecolorPalette(comptime c: Chroma) Palette {
    return .{
        .reset = esc ++ "0m",
        .dim = esc ++ "2m",
        .muted = fg(c.muted),
        .text = esc ++ "39m",
        .json_key = fg(c.key),
        .json_string = fg(c.string),
        .json_key_open = fg(c.key) ++ "\"",
        .json_string_open = fg(c.string) ++ "\"",
        .quote_close = "\"" ++ esc ++ "0m",
        .json_number = fg(c.number),
        .json_bool_null = fg(c.bool_null),
        .json_punct = esc ++ "2m",
        .match_on = badge(0x146b73, 0xffffff),
        .level = level_badges,
    };
}

fn ansi256Palette(comptime c: Indices) Palette {
    return .{
        .reset = esc ++ "0m",
        .dim = esc ++ "2m",
        .muted = idx(c.muted),
        .text = esc ++ "39m",
        .json_key = idx(c.key),
        .json_string = idx(c.string),
        .json_key_open = idx(c.key) ++ "\"",
        .json_string_open = idx(c.string) ++ "\"",
        .quote_close = "\"" ++ esc ++ "0m",
        .json_number = idx(c.number),
        .json_bool_null = idx(c.bool_null),
        .json_punct = esc ++ "2m",
        .match_on = esc ++ "48;5;23m" ++ esc ++ "38;5;231m",
        .level = ansi256_level_badges,
    };
}

const truecolor_dark_palette: Palette = truecolorPalette(dark_chroma);
const truecolor_light_palette: Palette = truecolorPalette(light_chroma);
const ansi256_dark_palette: Palette = ansi256Palette(dark_indices);
const ansi256_light_palette: Palette = ansi256Palette(light_indices);

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
    .json_key_open = esc ++ "34m" ++ "\"",
    .json_string_open = esc ++ "36m" ++ "\"",
    .quote_close = "\"" ++ esc ++ "0m",
    .json_number = esc ++ "35m",
    .json_bool_null = esc ++ "32m",
    .json_punct = esc ++ "2m",
    .match_on = esc ++ "46m" ++ esc ++ "30m",
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
    .json_key_open = "\"",
    .json_string_open = "\"",
    .quote_close = "\"",
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
    /// `COLORFGBG` is "fg;bg" with the background as an ANSI palette index.
    /// Only some terminals set it — konsole and the rxvt family do, iTerm2,
    /// Alacritty, kitty and Terminal.app do not — so it can confirm a light
    /// background but never rule one out.
    colorfgbg: ?[]const u8 = null,
    /// `ZLRD_THEME`, the environment form of `--theme`.
    zlrd_theme: ?[]const u8 = null,
};

/// Resolves capabilities from the environment. Pure — `Env` is gathered by
/// `fromMap` and the console is prepared separately by `prepareConsole`.
pub fn resolve(env: Env, choice: ColorChoice, theme_choice: flags.ThemeChoice) Theme {
    const want_color = switch (choice) {
        .never => false,
        // NO_COLOR is a user's explicit opt-out and outranks TTY detection,
        // but `--color=always` outranks NO_COLOR: it is more explicit still.
        .auto => !env.no_color and env.is_tty and !isDumb(env.term),
        .always => true,
    };
    if (!want_color) return .plain;
    return Theme.forMode(detectMode(env), detectGlyphs(env), detectBackground(env, theme_choice));
}

/// Resolves which background the palette should target.
///
/// `--theme` wins, then `ZLRD_THEME`, then `COLORFGBG`. When nothing says
/// otherwise the answer is `dark`: most terminals are, and unlike the old
/// single compromised palette a wrong guess here is one flag away from being
/// right rather than permanently flat on both backgrounds.
fn detectBackground(env: Env, choice: flags.ThemeChoice) Background {
    switch (choice) {
        .dark => return .dark,
        .light => return .light,
        .auto => {},
    }

    if (env.zlrd_theme) |t| {
        if (std.mem.eql(u8, t, "light")) return .light;
        if (std.mem.eql(u8, t, "dark")) return .dark;
    }

    if (env.colorfgbg) |v| {
        // The background is the field after the last ';'. Indices 7 and 15
        // are the two white entries; everything else is treated as dark.
        // A trailing "default" (some rxvt builds) parses as neither, and
        // falls through to the dark default below.
        var it = std.mem.splitBackwardsScalar(u8, v, ';');
        if (it.next()) |bg| {
            const n = std.fmt.parseInt(u8, bg, 10) catch return .dark;
            if (n == 7 or n == 15) return .light;
            return .dark;
        }
    }

    return .dark;
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
        .colorfgbg = map.get("COLORFGBG"),
        .zlrd_theme = map.get("ZLRD_THEME"),
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
    const t = resolve(.{ .no_color = true, .is_tty = true, .colorterm = "truecolor" }, .auto, .auto);
    try testing.expectEqual(Mode.none, t.mode);
    try testing.expect(!t.colored);
    try testing.expectEqualStrings("", t.palette.reset);
}

test "an empty NO_COLOR value does not disable colour" {
    // The convention keys off presence of a *non-empty* value.
    var map_env: Env = .{ .is_tty = true, .colorterm = "truecolor" };
    map_env.no_color = false;
    try testing.expectEqual(Mode.truecolor, resolve(map_env, .auto, .auto).mode);
}

test "piped output gets no colour" {
    const t = resolve(.{ .is_tty = false, .colorterm = "truecolor" }, .auto, .auto);
    try testing.expectEqual(Mode.none, t.mode);
}

test "--color=always overrides both NO_COLOR and a non-TTY" {
    const t = resolve(.{ .no_color = true, .is_tty = false, .colorterm = "truecolor" }, .always, .auto);
    try testing.expectEqual(Mode.truecolor, t.mode);
}

test "--color=never overrides a colour-capable TTY" {
    const t = resolve(.{ .is_tty = true, .colorterm = "truecolor" }, .never, .auto);
    try testing.expectEqual(Mode.none, t.mode);
}

test "TERM=dumb gets no colour" {
    try testing.expectEqual(Mode.none, resolve(.{ .is_tty = true, .term = "dumb" }, .auto, .auto).mode);
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
        const got = resolve(c.env, .auto, .auto).mode;
        try testing.expectEqual(c.want, got);
    }
}

test "COLORTERM outranks a modest TERM" {
    const t = resolve(.{ .is_tty = true, .term = "xterm", .colorterm = "truecolor" }, .auto, .auto);
    try testing.expectEqual(Mode.truecolor, t.mode);
}

test "box glyphs require evidence of UTF-8" {
    try testing.expectEqualStrings("│", resolve(.{ .is_tty = true, .lang = "en_US.UTF-8" }, .auto, .auto).glyphs.bar);
    try testing.expectEqualStrings("│", resolve(.{ .is_tty = true, .wt_session = true }, .auto, .auto).glyphs.bar);
    if (comptime builtin.os.tag != .macos) {
        try testing.expectEqualStrings("|", resolve(.{ .is_tty = true, .lang = "C" }, .auto, .auto).glyphs.bar);
        try testing.expectEqualStrings("|", resolve(.{ .is_tty = true }, .auto, .auto).glyphs.bar);
    }
}

test "every palette defines every slot" {
    // A missing entry would silently emit unstyled text in one mode only.
    for ([_]Mode{ .truecolor, .ansi256, .ansi16 }) |m| {
        const p = Theme.forMode(m, Glyphs.ascii, .dark).palette;
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
    const t = Theme.forMode(.truecolor, Glyphs.ascii, .dark);
    inline for (@typeInfo(flags.Level).@"enum".fields) |f| {
        const lvl: flags.Level = @enumFromInt(f.value);
        try testing.expect(t.levelStyle(lvl).len > 0);
    }
}

test "truecolor badges pair a background with a foreground" {
    // One write per badge is only safe if both halves really are in there.
    const t = Theme.forMode(.truecolor, Glyphs.ascii, .dark);
    const s = t.levelStyle(.Error);
    try testing.expect(std.mem.indexOf(u8, s, "48;2;") != null);
    try testing.expect(std.mem.indexOf(u8, s, "38;2;") != null);
}

test "primary text uses the terminal default foreground" {
    // The whole point: never pin the main text to a colour, because the
    // terminal's own default is the only value guaranteed to be legible on
    // the user's own background.
    for ([_]Mode{ .truecolor, .ansi256, .ansi16 }) |m| {
        try testing.expectEqualStrings("\x1b[39m", Theme.forMode(m, Glyphs.ascii, .dark).palette.text);
    }
}

// ─── Contrast ─────────────────────────────────────────────────────────────

fn srgbToLinear(c: u8) f64 {
    const x = @as(f64, @floatFromInt(c)) / 255.0;
    return if (x <= 0.03928) x / 12.92 else std.math.pow(f64, (x + 0.055) / 1.055, 2.4);
}

/// WCAG relative luminance.
fn relLuminance(hex: u24) f64 {
    const r = srgbToLinear(@intCast((hex >> 16) & 0xff));
    const g = srgbToLinear(@intCast((hex >> 8) & 0xff));
    const b = srgbToLinear(@intCast(hex & 0xff));
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/// WCAG contrast ratio, 1.0 (identical) to 21.0 (black on white).
fn contrastRatio(a: u24, b: u24) f64 {
    const la = relLuminance(a);
    const lb = relLuminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

test "background resolution prefers the flag, then env, then COLORFGBG" {
    const tty: Env = .{ .is_tty = true, .colorterm = "truecolor" };

    // The flag outranks everything, in both directions.
    var e = tty;
    e.zlrd_theme = "dark";
    e.colorfgbg = "0;15";
    try testing.expectEqual(Background.light, detectBackground(e, .light));
    try testing.expectEqual(Background.dark, detectBackground(e, .dark));

    // ZLRD_THEME outranks COLORFGBG.
    try testing.expectEqual(Background.dark, detectBackground(e, .auto));

    // COLORFGBG alone: 7 and 15 are the white entries, everything else dark.
    var c = tty;
    c.colorfgbg = "0;15";
    try testing.expectEqual(Background.light, detectBackground(c, .auto));
    c.colorfgbg = "15;7";
    try testing.expectEqual(Background.light, detectBackground(c, .auto));
    c.colorfgbg = "15;0";
    try testing.expectEqual(Background.dark, detectBackground(c, .auto));
    // rxvt writes a trailing "default" on some builds; it must not crash or
    // be mistaken for an index.
    c.colorfgbg = "15;default;0";
    try testing.expectEqual(Background.dark, detectBackground(c, .auto));
    c.colorfgbg = "";
    try testing.expectEqual(Background.dark, detectBackground(c, .auto));

    // Nothing to go on at all: dark, because most terminals are, and a wrong
    // guess is one flag away from right.
    try testing.expectEqual(Background.dark, detectBackground(tty, .auto));
}

test "the two palettes really are different tables" {
    const d = Theme.forMode(.truecolor, Glyphs.ascii, .dark);
    const l = Theme.forMode(.truecolor, Glyphs.ascii, .light);
    try testing.expect(!std.mem.eql(u8, d.palette.json_key, l.palette.json_key));
    // Level badges are shared on purpose: they carry their own background,
    // so they need no per-background variant.
    for (d.palette.level, l.palette.level) |a, b| try testing.expectEqualStrings(a, b);
    try testing.expectEqualStrings(d.palette.match_on, l.palette.match_on);
}

test "each palette clears 4.5:1 on the backgrounds it is for" {
    // The palettes' whole claim is numeric, so assert it numerically: a
    // colour picked by eye can look right in one terminal and quietly fail
    // in another. Splitting light from dark is what buys the full 4.5:1 —
    // the single shared palette this replaced topped out at 3.74:1, because
    // no one luminance clears 4.5:1 against both white and a dark theme.
    const dark_bgs = [_]struct { name: []const u8, hex: u24 }{
        .{ .name = "vscode dark", .hex = 0x1e1e1e },
        .{ .name = "one dark", .hex = 0x282c34 },
        // The lightest dark theme in common use, so it binds the constraint.
        .{ .name = "nord", .hex = 0x2e3440 },
        .{ .name = "black", .hex = 0x000000 },
    };
    const light_bgs = [_]struct { name: []const u8, hex: u24 }{
        .{ .name = "white", .hex = 0xffffff },
        .{ .name = "solarized light", .hex = 0xfdf6e3 },
    };

    inline for (.{
        .{ "dark", dark_chroma, dark_bgs[0..] },
        .{ "light", light_chroma, light_bgs[0..] },
    }) |set| {
        const which = set[0];
        const c = set[1];
        const colors = [_]struct { name: []const u8, hex: u24 }{
            .{ .name = "muted", .hex = c.muted },
            .{ .name = "json_key", .hex = c.key },
            .{ .name = "json_string", .hex = c.string },
            .{ .name = "json_number", .hex = c.number },
            .{ .name = "json_bool_null", .hex = c.bool_null },
        };
        for (colors) |col| {
            for (set[2]) |bg| {
                const ratio = contrastRatio(col.hex, bg.hex);
                if (ratio < 4.5) {
                    std.debug.print("{s} palette: {s} (#{x:0>6}) on {s}: {d:.2}:1\n", .{ which, col.name, col.hex, bg.name, ratio });
                    return error.InsufficientContrast;
                }
            }
        }
    }
}

test "level badges keep white legible on their own background" {
    // Badges carry their own background, so unlike the foreground colours
    // above they are free to clear the full 4.5:1 — and must, since the
    // level is the one token a reader scans for.
    const badge_bgs = [_]u24{ 0x595f66, 0x0d5bbd, 0x11713c, 0x8a5300, 0xc02626, 0x9c1382 };
    for (badge_bgs) |bg| {
        try std.testing.expect(contrastRatio(0xffffff, bg) >= 4.5);
    }
}

/// Hue angle in degrees, 0–360.
fn hueDegrees(hex: u24) f64 {
    const r = @as(f64, @floatFromInt((hex >> 16) & 0xff)) / 255.0;
    const g = @as(f64, @floatFromInt((hex >> 8) & 0xff)) / 255.0;
    const b = @as(f64, @floatFromInt(hex & 0xff)) / 255.0;
    const mx = @max(r, @max(g, b));
    const mn = @min(r, @min(g, b));
    const d = mx - mn;
    if (d == 0) return 0;
    const h = if (mx == r)
        60.0 * @mod((g - b) / d, 6.0)
    else if (mx == g)
        60.0 * (((b - r) / d) + 2.0)
    else
        60.0 * (((r - g) / d) + 4.0);
    return if (h < 0) h + 360.0 else h;
}

test "foreground colours stay distinguishable within a palette" {
    // Inside one palette every colour sits at the same luminance by design,
    // so hue is the only thing telling them apart — two that converge become
    // one colour on screen while still passing the contrast test above.
    //
    // Measured on hue rather than RGB distance: at the luminance the dark
    // palette needs, blue has to desaturate towards white to get there, and
    // an RGB metric reads that wash-out as "too similar" for a pair a reader
    // separates without effort. Compared per palette, never across — the two
    // sets never appear together.
    inline for (.{ dark_chroma, light_chroma }) |c| {
        const colors = [_]u24{ c.key, c.string, c.number, c.bool_null };
        for (colors, 0..) |a, i| {
            for (colors[i + 1 ..]) |b| {
                const raw = @abs(hueDegrees(a) - hueDegrees(b));
                const gap = @min(raw, 360.0 - raw);
                if (gap < 40.0) {
                    std.debug.print("#{x:0>6} and #{x:0>6} are {d:.1} deg apart\n", .{ a, b, gap });
                    return error.HuesTooClose;
                }
            }
        }
    }
}
