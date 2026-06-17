//! Native systemd-journal parser. Re-exports the protocol layer so the
//! agent can import a single `journal` module rather than reaching into
//! individual files.

pub const format = @import("format.zig");
pub const lz4 = @import("lz4.zig");
pub const reader = @import("reader.zig");
pub const tail = @import("tail.zig");
pub const source = @import("source.zig");

pub const Reader = reader.Reader;
pub const Iterator = reader.Iterator;
pub const Entry = reader.Entry;
pub const Field = reader.Field;
pub const Watcher = tail.Watcher;
pub const StopFlag = tail.StopFlag;
