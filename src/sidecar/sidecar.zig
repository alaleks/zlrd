//! Sidecar mode (OTLP/HTTP) protocol layer. Pure wire format + transport,
//! no agent dependencies — the agent's bridge lives in `src/agent/exporter.zig`
//! and imports this module via `@import("sidecar")`.

pub const protobuf = @import("protobuf.zig");
pub const otlp = @import("otlp.zig");
pub const transport = @import("transport.zig");
