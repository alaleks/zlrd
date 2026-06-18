//! Thin shim re-exporting the formatting/filtering surface from `reader.zig`.
//!
//! Background: `formats.zig` and `reader.zig` used to be ~3000 lines of
//! near-identical duplicates. The canonical implementation now lives in
//! `reader.zig`; this file remains only as a stable import path for
//! `tail.zig` (and any external code that still expects it).
//!
//! Prefer importing `reader.zig` directly for new code.

const reader = @import("reader.zig");

pub const FilterState = reader.FilterState;
pub const LineInfo = reader.LineInfo;
pub const buildAggregateKey = reader.buildAggregateKey;
pub const buildAggregateKeyForLine = reader.buildAggregateKeyForLine;
