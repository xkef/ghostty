//! This is the public API of the ghostty-renderer Zig module.
//!
//! WARNING: The API is not guaranteed to be stable.
//!
//! This library provides GPU rendering for terminal content produced
//! by libghostty-vt. It handles font loading, text shaping, glyph
//! atlas management, and GPU rendering via Metal (macOS) or OpenGL.
//!
//! The consumer provides a GPU surface (e.g. NSView on macOS)
//! and terminal render state; the library handles everything else.

const renderer = @import("renderer.zig");
const font = @import("font/main.zig");
const terminal = @import("terminal/main.zig");

pub const Renderer = renderer.Renderer;
pub const Size = renderer.Size;
pub const CellSize = renderer.CellSize;
pub const ScreenSize = renderer.ScreenSize;
pub const GridSize = renderer.GridSize;
pub const Health = renderer.Health;
pub const State = renderer.State;
pub const Options = renderer.Options;

pub const FontMetrics = font.Metrics;
pub const SharedGrid = font.SharedGrid;
pub const SharedGridSet = font.SharedGridSet;

pub const Terminal = terminal.Terminal;
pub const RenderState = terminal.RenderState;

// C API exports.
comptime {
    _ = @import("lib_renderer_c.zig");
}
