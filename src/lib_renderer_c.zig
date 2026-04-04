//! C API for libghostty-renderer.
//!
//! Platform-independent interface for Ghostty's GPU renderer and
//! terminal emulation. Two API levels:
//!   Level 1: bind a surface, library draws everything.
//!   Level 2: library builds cell buffers + atlas, consumer draws.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const builtin = @import("builtin");
const objc = @import("objc");

const rendererpkg = @import("renderer.zig");
const font = @import("font/main.zig");
const terminal = @import("terminal/main.zig");
const configpkg = @import("config.zig");
const link = @import("renderer/link.zig");

const Renderer = rendererpkg.Renderer;

const log = std.log.scoped(.lib_renderer_c);

// ================================================================
// C config struct (matches renderer.h)
// ================================================================

const CConfig = extern struct {
    width_px: u32 = 0,
    height_px: u32 = 0,
    content_scale: f64 = 0,

    font_size: f32 = 0,
    font_family: ?[*:0]const u8 = null,
    font_family_bold: ?[*:0]const u8 = null,
    font_family_italic: ?[*:0]const u8 = null,
    font_family_bold_italic: ?[*:0]const u8 = null,
    font_features: ?[*:0]const u8 = null,
    font_thicken: bool = false,
    font_thicken_strength: u8 = 0,

    background: extern struct { r: u8 = 0, g: u8 = 0, b: u8 = 0 } = .{},
    foreground: extern struct { r: u8 = 0, g: u8 = 0, b: u8 = 0 } = .{},
    cursor_color: extern struct { r: u8 = 0, g: u8 = 0, b: u8 = 0, has: bool = false } = .{},
    cursor_text: extern struct { r: u8 = 0, g: u8 = 0, b: u8 = 0, has: bool = false } = .{},
    selection_background: extern struct { r: u8 = 0, g: u8 = 0, b: u8 = 0, has: bool = false } = .{},
    selection_foreground: extern struct { r: u8 = 0, g: u8 = 0, b: u8 = 0, has: bool = false } = .{},
    bold_color: extern struct { r: u8 = 0, g: u8 = 0, b: u8 = 0, has: bool = false } = .{},

    search_match_bg: extern struct { r: u8 = 0, g: u8 = 0, b: u8 = 0 } = .{},
    search_match_fg: extern struct { r: u8 = 0, g: u8 = 0, b: u8 = 0 } = .{},
    search_selected_bg: extern struct { r: u8 = 0, g: u8 = 0, b: u8 = 0 } = .{},
    search_selected_fg: extern struct { r: u8 = 0, g: u8 = 0, b: u8 = 0 } = .{},

    background_opacity: f32 = 0,
    cursor_opacity: f32 = 0,
    faint_opacity: f32 = 0,

    min_contrast: f32 = 0,
    colorspace: c_int = 0,
    alpha_blending: c_int = 0,
    padding_color: c_int = 0,

    scroll_to_bottom_on_output: bool = false,
};

// ================================================================
// Renderer state
// ================================================================

const RendererState = struct {
    alloc: Allocator,
    renderer: Renderer,
    render_state: rendererpkg.State,
    terminal_set: bool = false,
    font_grid_set: font.SharedGridSet,
    font_grid: *font.SharedGrid,
    font_grid_key: font.SharedGridSet.Key,
    config: configpkg.Config,
    mutex: std.Thread.Mutex = .{},

    // Level 2 staging
    text_cells_staging: []Renderer.API.shaders.CellText = &.{},
    atlas_grayscale_gen: usize = 0,
    atlas_color_gen: usize = 0,
};

// ================================================================
// Renderer lifecycle
// ================================================================

export fn ghostty_renderer_new(
    c_config: ?*const CConfig,
    native_handle: ?*anyopaque,
) ?*RendererState {
    return createRenderer(c_config orelse &.{}, native_handle) catch |err| {
        log.err("failed to create renderer: {}", .{err});
        return null;
    };
}

fn createRenderer(cc: *const CConfig, native_handle: ?*anyopaque) !*RendererState {
    const alloc = std.heap.c_allocator;

    // Load Ghostty config for defaults (font discovery, etc).
    // We don't read config files -- just get programmatic defaults.
    // TODO: replace Config.load with a minimal default-only init
    // once we can build DerivedConfig without the full Config.
    var config = try configpkg.Config.load(alloc);
    errdefer config.deinit();

    // Apply C config overrides. Only override when the consumer
    // explicitly set a value (non-zero). Zero means "use ghostty default."
    if (cc.font_size > 0) config.@"font-size" = cc.font_size;
    if (cc.background_opacity > 0) config.@"background-opacity" = cc.background_opacity;
    if (cc.min_contrast > 0) config.@"minimum-contrast" = cc.min_contrast;
    config.@"font-thicken" = cc.font_thicken;
    // Note: color overrides (background, foreground, etc.) are NOT applied
    // from the C config when zero-initialized, because zero (black) is
    // indistinguishable from "not set." Use set_background() at runtime
    // or load a theme file to change colors.

    // Font grid
    var font_grid_set = try font.SharedGridSet.init(alloc);
    errdefer font_grid_set.deinit();

    const scale = if (cc.content_scale > 0) cc.content_scale else 1.0;
    const pt_size: f32 = if (cc.font_size > 0) cc.font_size else @floatCast(config.@"font-size");
    const dpi: u16 = @intFromFloat(@round(72.0 * scale));

    var font_config = try font.SharedGridSet.DerivedConfig.init(alloc, &config);
    defer font_config.deinit();

    const font_grid_key, const font_grid = try font_grid_set.ref(
        &font_config,
        .{ .points = pt_size, .xdpi = dpi, .ydpi = dpi },
    );

    // Renderer size
    const cell_size = font_grid.cellSize();
    const size: rendererpkg.Size = .{
        .screen = .{
            .width = if (cc.width_px > 0) cc.width_px else 800,
            .height = if (cc.height_px > 0) cc.height_px else 600,
        },
        .cell = cell_size,
        .padding = .{},
    };

    // Derive renderer config from the (possibly overridden) ghostty config.
    const renderer_config = try Renderer.DerivedConfig.init(alloc, &config);

    // Build view_info if a native handle was provided (Level 1).
    const view_info: ?rendererpkg.Options.ViewInfo = if (native_handle) |handle|
        .{
            .view = .{ .value = @ptrCast(@alignCast(handle)) },
            .scale_factor = scale,
        }
    else
        null;

    var renderer_impl = try Renderer.init(alloc, .{
        .config = renderer_config,
        .font_grid = font_grid,
        .size = size,
        .view_info = view_info,
    });
    errdefer renderer_impl.deinit();

    const state = try alloc.create(RendererState);
    errdefer alloc.destroy(state);

    state.* = .{
        .alloc = alloc,
        .renderer = renderer_impl,
        .render_state = undefined,
        .font_grid_set = font_grid_set,
        .font_grid = font_grid,
        .font_grid_key = font_grid_key,
        .config = config,
    };
    return state;
}

export fn ghostty_renderer_free(state: *RendererState) void {
    if (state.text_cells_staging.len > 0) {
        state.alloc.free(state.text_cells_staging);
    }
    state.renderer.deinit();
    state.font_grid_set.deref(state.font_grid_key);
    state.font_grid_set.deinit();
    state.config.deinit();
    state.alloc.destroy(state);
}


export fn ghostty_renderer_set_terminal(
    state: *RendererState,
    wrapper: *TerminalWrapper,
) void {
    // Apply the renderer's configured colors to the terminal so that
    // terminal_state.update() picks them up for the bg/fg uniforms.
    const bg = state.renderer.config.background;
    const fg = state.renderer.config.foreground;
    wrapper.t.colors.background = .init(.{ .r = bg.r, .g = bg.g, .b = bg.b });
    wrapper.t.colors.foreground = .init(.{ .r = fg.r, .g = fg.g, .b = fg.b });

    state.render_state = .{
        .mutex = &state.mutex,
        .terminal = wrapper.t,
    };
    state.terminal_set = true;
}

export fn ghostty_renderer_resize(
    state: *RendererState,
    width: u32,
    height: u32,
    scale: f64,
) void {
    _ = scale;
    state.renderer.size.screen = .{
        .width = width,
        .height = height,
    };
}

// ================================================================
// Level 1: library draws
// ================================================================

export fn ghostty_renderer_update_frame(state: *RendererState) void {
    if (!state.terminal_set) return;
    state.renderer.updateFrame(&state.render_state, true) catch |err| {
        log.warn("updateFrame error: {}", .{err});
    };

    // Compute grid_padding for Level 2 consumers. The generic renderer
    // normally does this in setScreenSize (called by the apprt), but
    // Level 2 consumers never call that — they own the surface. We
    // recompute here because rebuildCells (inside updateFrame) may
    // have changed the grid dimensions.
    const pad = state.renderer.size.screen.blankPadding(
        state.renderer.size.padding,
        state.renderer.cells.size,
        .{
            .width = state.renderer.grid_metrics.cell_width,
            .height = state.renderer.grid_metrics.cell_height,
        },
    ).add(state.renderer.size.padding);

    // Level 2 convention: [left, top, right, bottom].
    state.renderer.uniforms.grid_padding = .{
        @floatFromInt(pad.left),
        @floatFromInt(pad.top),
        @floatFromInt(pad.right),
        @floatFromInt(pad.bottom),
    };
}

export fn ghostty_renderer_draw_frame(state: *RendererState) void {
    state.renderer.drawFrame(true) catch |err| {
        log.warn("drawFrame error: {}", .{err});
    };
}

// ================================================================
// Level 2: consumer draws
// ================================================================

export fn ghostty_renderer_get_bg_cells(
    state: *RendererState,
    count: *u32,
) [*]const [4]u8 {
    const cells = state.renderer.cells.bg_cells;
    count.* = @intCast(cells.len);
    return cells.ptr;
}

export fn ghostty_renderer_get_text_cells(
    state: *RendererState,
    count: *u32,
) ?[*]const Renderer.API.shaders.CellText {
    const fg = &state.renderer.cells.fg_rows;
    var total: u32 = 0;
    for (fg.lists) |list| {
        total += @intCast(list.items.len);
    }

    if (total == 0) {
        count.* = 0;
        return null;
    }

    // Grow staging buffer if needed.
    if (state.text_cells_staging.len < total) {
        if (state.text_cells_staging.len > 0) {
            state.alloc.free(state.text_cells_staging);
        }
        state.text_cells_staging = state.alloc.alloc(
            Renderer.API.shaders.CellText,
            @intCast(total),
        ) catch {
            count.* = 0;
            return null;
        };
    }

    var offset: usize = 0;
    for (fg.lists) |list| {
        @memcpy(state.text_cells_staging[offset..][0..list.items.len], list.items);
        offset += list.items.len;
    }

    count.* = total;
    return state.text_cells_staging.ptr;
}

const FrameData = extern struct {
    cell_width: f32,
    cell_height: f32,
    grid_cols: u16,
    grid_rows: u16,
    grid_padding: [4]f32,
    bg_color: [4]u8,
    min_contrast: f32,
    cursor_pos: [2]u16,
    cursor_color: [4]u8,
    cursor_wide: bool,
};

export fn ghostty_renderer_get_frame_data(
    state: *RendererState,
    out: *FrameData,
) void {
    const u = state.renderer.uniforms;
    out.* = .{
        .cell_width = u.cell_size[0],
        .cell_height = u.cell_size[1],
        .grid_cols = u.grid_size[0],
        .grid_rows = u.grid_size[1],
        .grid_padding = u.grid_padding,
        .bg_color = u.bg_color,
        .min_contrast = u.min_contrast,
        .cursor_pos = u.cursor_pos,
        .cursor_color = u.cursor_color,
        .cursor_wide = u.bools.cursor_wide,
    };
}

export fn ghostty_renderer_get_atlas_grayscale(
    state: *RendererState,
    size: *u32,
    modified: *bool,
) [*]const u8 {
    const grid = state.font_grid;
    grid.lock.lockShared();
    defer grid.lock.unlockShared();

    const atlas = &grid.atlas_grayscale;
    const current = atlas.modified.load(.monotonic);
    modified.* = (current != state.atlas_grayscale_gen);
    state.atlas_grayscale_gen = current;
    size.* = atlas.size;
    return atlas.data.ptr;
}

export fn ghostty_renderer_get_atlas_color(
    state: *RendererState,
    size: *u32,
    modified: *bool,
) [*]const u8 {
    const grid = state.font_grid;
    grid.lock.lockShared();
    defer grid.lock.unlockShared();

    const atlas = &grid.atlas_color;
    const current = atlas.modified.load(.monotonic);
    modified.* = (current != state.atlas_color_gen);
    state.atlas_color_gen = current;
    size.* = atlas.size;
    return atlas.data.ptr;
}

// ================================================================
// Theme loading
// ================================================================

export fn ghostty_renderer_load_theme(
    state: *RendererState,
    name: [*:0]const u8,
) bool {
    _ = state;
    _ = name;
    // TODO: resolve theme name from ghostty theme dirs,
    // parse the file, update colors + palette on the renderer.
    log.warn("load_theme not yet implemented", .{});
    return false;
}

export fn ghostty_renderer_load_theme_file(
    state: *RendererState,
    path: [*:0]const u8,
) bool {
    _ = state;
    _ = path;
    // TODO: parse theme file, update colors + palette.
    log.warn("load_theme_file not yet implemented", .{});
    return false;
}

// ================================================================
// Runtime config updates
// ================================================================

export fn ghostty_renderer_set_font_size(state: *RendererState, points: f32) void {
    _ = state;
    _ = points;
    log.warn("set_font_size not yet implemented", .{});
}

export fn ghostty_renderer_set_background(state: *RendererState, r: u8, g: u8, b: u8) void {
    // Must set on the config (persistent across changeConfig calls),
    // the uniforms (immediate), AND the terminal's color (so
    // terminal_state.update picks it up on the next frame).
    state.renderer.config.background = .{ .r = r, .g = g, .b = b };
    state.renderer.uniforms.bg_color = .{ r, g, b, state.renderer.uniforms.bg_color[3] };
    if (state.terminal_set) {
        state.render_state.terminal.colors.background =
            .init(.{ .r = r, .g = g, .b = b });
    }
}

export fn ghostty_renderer_set_foreground(state: *RendererState, r: u8, g: u8, b: u8) void {
    _ = state;
    _ = r;
    _ = g;
    _ = b;
    log.warn("set_foreground not yet implemented", .{});
}

export fn ghostty_renderer_set_background_opacity(state: *RendererState, opacity: f32) void {
    state.renderer.uniforms.bg_color[3] = @intFromFloat(@round(@max(0, @min(1, opacity)) * 255.0));
}

export fn ghostty_renderer_set_min_contrast(state: *RendererState, contrast: f32) void {
    state.renderer.uniforms.min_contrast = contrast;
}

// ================================================================
// Terminal
// ================================================================

const stream_terminal = @import("terminal/stream_terminal.zig");
const Stream = stream_terminal.Stream;
const Handler = stream_terminal.Handler;
const size_report = terminal.size_report;
const device_attributes = @import("terminal/device_attributes.zig");

const TerminalWrapper = struct {
    t: *terminal.Terminal,
    stream: Stream,
    response_buf: std.ArrayListUnmanaged(u8),
    response_alloc: Allocator,

    fn writePty(handler: *Handler, data: [:0]const u8) void {
        const stream_ptr: *Stream = @fieldParentPtr("handler", handler);
        const wrapper: *TerminalWrapper = @fieldParentPtr("stream", stream_ptr);
        wrapper.response_buf.appendSlice(wrapper.response_alloc, data) catch {};
    }

    fn reportDeviceAttributes(_: *Handler) device_attributes.Attributes {
        return .{};
    }

    fn reportSize(handler: *Handler) ?size_report.Size {
        const t = handler.terminal;
        return .{
            .columns = t.cols,
            .rows = t.rows,
            .cell_width = 0,
            .cell_height = 0,
        };
    }
};

export fn ghostty_terminal_new(
    cols: u16,
    rows: u16,
    max_scrollback: u32,
) ?*TerminalWrapper {
    const alloc = std.heap.c_allocator;

    const t = alloc.create(terminal.Terminal) catch return null;
    t.* = terminal.Terminal.init(alloc, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback = max_scrollback,
    }) catch {
        alloc.destroy(t);
        return null;
    };

    const wrapper = alloc.create(TerminalWrapper) catch {
        t.deinit(alloc);
        alloc.destroy(t);
        return null;
    };
    wrapper.* = .{
        .t = t,
        .stream = t.vtStream(),
        .response_buf = .empty,
        .response_alloc = alloc,
    };

    wrapper.stream.handler.effects.write_pty = &TerminalWrapper.writePty;
    wrapper.stream.handler.effects.size = &TerminalWrapper.reportSize;
    wrapper.stream.handler.effects.device_attributes = &TerminalWrapper.reportDeviceAttributes;

    return wrapper;
}

export fn ghostty_terminal_free(wrapper: *TerminalWrapper) void {
    const alloc = std.heap.c_allocator;
    wrapper.response_buf.deinit(wrapper.response_alloc);
    wrapper.t.deinit(alloc);
    alloc.destroy(wrapper.t);
    alloc.destroy(wrapper);
}

export fn ghostty_terminal_vt_write(
    wrapper: *TerminalWrapper,
    data: [*]const u8,
    len: usize,
) void {
    wrapper.stream.nextSlice(data[0..len]);
}

export fn ghostty_terminal_resize(
    wrapper: *TerminalWrapper,
    cols: u16,
    rows: u16,
) void {
    wrapper.t.resize(wrapper.response_alloc, cols, rows) catch |err| {
        log.warn("terminal resize error: {}", .{err});
    };
}

export fn ghostty_terminal_drain_responses(
    wrapper: *TerminalWrapper,
    out_len: *usize,
) [*]const u8 {
    const items = wrapper.response_buf.items;
    out_len.* = items.len;
    return if (items.len > 0) items.ptr else @as([*]const u8, "");
}

export fn ghostty_terminal_clear_responses(wrapper: *TerminalWrapper) void {
    wrapper.response_buf.clearRetainingCapacity();
}

export fn ghostty_terminal_get_size(
    wrapper: *TerminalWrapper,
    cols: *u16,
    rows: *u16,
) void {
    cols.* = wrapper.t.cols;
    rows.* = wrapper.t.rows;
}

export fn ghostty_terminal_get_cursor(
    wrapper: *TerminalWrapper,
    col: *u16,
    row: *u16,
    visible: *bool,
) void {
    col.* = wrapper.t.screens.active.cursor.x;
    row.* = wrapper.t.screens.active.cursor.y;
    visible.* = wrapper.t.modes.get(.cursor_visible);
}

export fn ghostty_terminal_scroll(
    wrapper: *TerminalWrapper,
    action: c_int,
    delta: i32,
) void {
    const sv: terminal.Terminal.ScrollViewport = switch (action) {
        0 => .{ .delta = delta },
        1 => .top,
        2 => .bottom,
        3 => .{ .delta = -@as(isize, wrapper.t.rows) },
        4 => .{ .delta = @as(isize, wrapper.t.rows) },
        else => return,
    };
    wrapper.t.scrollViewport(sv);
}

export fn ghostty_terminal_get_scrollback_rows(
    _: *TerminalWrapper,
) usize {
    // TODO: expose a proper scrollback row count.
    return 0;
}

export fn ghostty_free(ptr: ?*anyopaque) void {
    _ = ptr;
    // Currently unused. Will be needed when we return allocated strings.
}
