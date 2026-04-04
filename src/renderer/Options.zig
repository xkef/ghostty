//! The options that are used to configure a renderer.

const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const renderer = @import("../renderer.zig");

/// The derived configuration for this renderer implementation.
config: renderer.Renderer.DerivedConfig,

/// The font grid that should be used along with the key for deref-ing.
font_grid: *font.SharedGrid,

/// The size of everything.
size: renderer.Size,

/// The mailbox for sending the surface messages. This is only valid
/// once the thread has started and should not be used outside of the thread.
/// When null, surface notifications (scrollbar, health) are silently dropped.
surface_mailbox: ?apprt.surface.Mailbox = null,

/// The apprt surface. When null, the renderer is in standalone mode
/// and the graphics API must be initialized with explicit platform handles
/// via `view_info`.
rt_surface: ?*apprt.Surface = null,

/// The renderer thread. When null, the consumer manages the render loop.
thread: ?*renderer.Thread = null,

/// Explicit platform view info for standalone (non-apprt) use.
/// When set, this is used instead of extracting view info from rt_surface.
view_info: ?ViewInfo = null,

pub const ViewInfo = struct {
    /// The NSView (macOS) or UIView (iOS) to render into.
    view: @import("objc").Object,

    /// The content scale factor (e.g. 2.0 for Retina).
    scale_factor: f64,
};
