//! C API for libghostty-renderer.
//!
//! GPU-ready cell buffer generation from a terminal + font system.
//! Platform-independent. The consumer provides a GhosttyTerminal handle
//! from libghostty-vt and gets back cell arrays + glyph atlas textures
//! for their own GPU pipeline.
//!
//! Two opaque handles:
//!   GhosttyFontGrid  — shared font system (atlas, shaper, metrics)
//!   GhosttyRenderer  — per-terminal cell buffer generator

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const objc = @import("objc");

const rendererpkg = @import("renderer.zig");
const font = @import("font/main.zig");
const terminal = @import("terminal/main.zig");
const configpkg = @import("config.zig");
const internal_os = @import("os/main.zig");
const global = @import("global.zig");

const Renderer = rendererpkg.Renderer;
const TerminalWrapper = @import("terminal/c/terminal.zig").TerminalWrapper;

const log = std.log.scoped(.lib_renderer_c);

// ================================================================
// C config structs
// ================================================================

const FontGridConfig = extern struct {
    font_size: f32 = 0,
    font_family: ?[*:0]const u8 = null,
    font_family_bold: ?[*:0]const u8 = null,
    font_family_italic: ?[*:0]const u8 = null,
    font_family_bold_italic: ?[*:0]const u8 = null,
    font_features: ?[*:0]const u8 = null,
    font_thicken: bool = false,
    content_scale: f64 = 0,
};

const RendererConfig = extern struct {
    width_px: u32 = 0,
    height_px: u32 = 0,
    content_scale: f64 = 0,
    native_view: ?*anyopaque = null,

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
    colorspace: i32 = 0,
    alpha_blending: i32 = 0,
    padding_color: i32 = 0,
};

const FontMetrics = extern struct {
    cell_width: f32,
    cell_height: f32,
    cell_baseline: f32,
    underline_position: f32,
    underline_thickness: f32,
    strikethrough_position: f32,
    strikethrough_thickness: f32,
};

// ================================================================
// Internal state
// ================================================================

const FontGridState = struct {
    alloc: Allocator,
    font_grid_set: font.SharedGridSet,
    font_grid: *font.SharedGrid,
    font_grid_key: font.SharedGridSet.Key,
    config: configpkg.Config,
    atlas_grayscale_gen: usize = 0,
    atlas_color_gen: usize = 0,
};

const RendererState = struct {
    alloc: Allocator,
    renderer: Renderer,
    render_state: rendererpkg.State,
    font_grid_state: *FontGridState,
    terminal_set: bool = false,
    mutex: std.Thread.Mutex = .{},
    text_cells_staging: []Renderer.API.shaders.CellText = &.{},
};

// ================================================================
// Font grid
// ================================================================

export fn ghostty_font_grid_new(c_config: ?*const FontGridConfig) ?*FontGridState {
    return createFontGrid(c_config orelse &.{}) catch |err| {
        log.err("failed to create font grid: {}", .{err});
        return null;
    };
}

fn createFontGrid(cc: *const FontGridConfig) !*FontGridState {
    const alloc = std.heap.c_allocator;

    if (global.state.resources_dir.app() == null) {
        global.state.resources_dir = internal_os.resourcesDir(alloc) catch .{};
    }

    var config = try configpkg.Config.load(alloc);
    errdefer config.deinit();

    if (cc.font_family) |ff| {
        config.@"font-family" = .{};
        try config.@"font-family".list.append(alloc, std.mem.span(ff));
    }
    if (cc.font_family_bold) |ff| {
        config.@"font-family-bold" = .{};
        try config.@"font-family-bold".list.append(alloc, std.mem.span(ff));
    }
    if (cc.font_family_italic) |ff| {
        config.@"font-family-italic" = .{};
        try config.@"font-family-italic".list.append(alloc, std.mem.span(ff));
    }
    if (cc.font_family_bold_italic) |ff| {
        config.@"font-family-bold-italic" = .{};
        try config.@"font-family-bold-italic".list.append(alloc, std.mem.span(ff));
    }
    if (cc.font_features) |ff| {
        config.@"font-feature" = .{};
        try config.@"font-feature".list.append(alloc, std.mem.span(ff));
    }
    if (cc.font_size > 0) config.@"font-size" = cc.font_size;
    config.@"font-thicken" = cc.font_thicken;

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

    const state = try alloc.create(FontGridState);
    errdefer alloc.destroy(state);
    state.* = .{
        .alloc = alloc,
        .font_grid_set = font_grid_set,
        .font_grid = font_grid,
        .font_grid_key = font_grid_key,
        .config = config,
    };
    return state;
}

export fn ghostty_font_grid_free(state: *FontGridState) void {
    state.font_grid_set.deref(state.font_grid_key);
    state.font_grid_set.deinit();
    state.config.deinit();
    state.alloc.destroy(state);
}

export fn ghostty_font_grid_get_metrics(state: *FontGridState, out: *FontMetrics) void {
    const m = state.font_grid.cellSize();
    const metrics = state.font_grid.metrics;
    out.* = .{
        .cell_width = @floatFromInt(m.width),
        .cell_height = @floatFromInt(m.height),
        .cell_baseline = @floatFromInt(metrics.cell_baseline),
        .underline_position = @floatFromInt(metrics.underline_position),
        .underline_thickness = @floatFromInt(metrics.underline_thickness),
        .strikethrough_position = @floatFromInt(metrics.strikethrough_position),
        .strikethrough_thickness = @floatFromInt(metrics.strikethrough_thickness),
    };
}

export fn ghostty_font_grid_atlas_grayscale(
    state: *FontGridState,
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

export fn ghostty_font_grid_atlas_color(
    state: *FontGridState,
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

export fn ghostty_font_grid_set_size(state: *FontGridState, points: f32) void {
    _ = state;
    _ = points;
    log.warn("font_grid_set_size not yet implemented", .{});
}

// ================================================================
// Renderer
// ================================================================

export fn ghostty_renderer_new(
    grid_state: *FontGridState,
    c_config: ?*const RendererConfig,
) ?*RendererState {
    return createRenderer(grid_state, c_config orelse &.{}) catch |err| {
        log.err("failed to create renderer: {}", .{err});
        return null;
    };
}

fn createRenderer(grid_state: *FontGridState, cc: *const RendererConfig) !*RendererState {
    const alloc = std.heap.c_allocator;

    var config = grid_state.config;
    if (cc.background_opacity > 0) config.@"background-opacity" = cc.background_opacity;
    if (cc.min_contrast > 0) config.@"minimum-contrast" = cc.min_contrast;

    const font_grid = grid_state.font_grid;
    const cell_size = font_grid.cellSize();
    const size: rendererpkg.Size = .{
        .screen = .{
            .width = if (cc.width_px > 0) cc.width_px else 800,
            .height = if (cc.height_px > 0) cc.height_px else 600,
        },
        .cell = cell_size,
        .padding = .{},
    };

    const renderer_config = try Renderer.DerivedConfig.init(alloc, &config);

    const scale = if (cc.content_scale > 0) cc.content_scale else 1.0;
    const view_info: ?rendererpkg.Options.ViewInfo = if (cc.native_view) |handle|
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
        .font_grid_state = grid_state,
    };
    return state;
}

export fn ghostty_renderer_free(state: *RendererState) void {
    if (state.text_cells_staging.len > 0) {
        state.alloc.free(state.text_cells_staging);
    }
    state.renderer.deinit();
    state.alloc.destroy(state);
}

export fn ghostty_renderer_set_terminal(state: *RendererState, wrapper: *TerminalWrapper) void {
    const t = wrapper.terminal;

    const bg = state.renderer.config.background;
    const fg = state.renderer.config.foreground;
    t.colors.background = .init(.{ .r = bg.r, .g = bg.g, .b = bg.b });
    t.colors.foreground = .init(.{ .r = fg.r, .g = fg.g, .b = fg.b });

    state.render_state = .{
        .mutex = &state.mutex,
        .terminal = t,
    };
    state.terminal_set = true;
}

export fn ghostty_renderer_resize(state: *RendererState, width: u32, height: u32) void {
    state.renderer.size.screen = .{ .width = width, .height = height };
}

export fn ghostty_renderer_update_frame(state: *RendererState, cursor_blink_visible: bool) void {
    if (!state.terminal_set) return;
    state.renderer.updateFrame(&state.render_state, cursor_blink_visible) catch |err| {
        log.warn("updateFrame error: {}", .{err});
    };

    const pad = state.renderer.size.screen.blankPadding(
        state.renderer.size.padding,
        state.renderer.cells.size,
        .{
            .width = state.renderer.grid_metrics.cell_width,
            .height = state.renderer.grid_metrics.cell_height,
        },
    ).add(state.renderer.size.padding);

    state.renderer.uniforms.grid_padding = .{
        @floatFromInt(pad.left),
        @floatFromInt(pad.top),
        @floatFromInt(pad.right),
        @floatFromInt(pad.bottom),
    };
}

// ================================================================
// Cell buffer output
// ================================================================

export fn ghostty_renderer_bg_cells(state: *RendererState, count: *u32) [*]const [4]u8 {
    const cells = state.renderer.cells.bg_cells;
    count.* = @intCast(cells.len);
    return cells.ptr;
}

export fn ghostty_renderer_text_cells(
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

export fn ghostty_renderer_frame_data(state: *RendererState, out: *FrameData) void {
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

// ================================================================
// Theme
// ================================================================

export fn ghostty_renderer_load_theme(state: *RendererState, name: [*:0]const u8) bool {
    const name_slice = std.mem.span(name);
    if (name_slice.len == 0) return false;

    // Try to find the theme file in the resources directory.
    const resources_dir = std.process.getEnvVarOwned(
        std.heap.c_allocator,
        "GHOSTTY_RESOURCES_DIR",
    ) catch return false;
    defer std.heap.c_allocator.free(resources_dir);

    const theme_path = std.fs.path.join(std.heap.c_allocator, &.{
        resources_dir,
        "themes",
        name_slice,
    }) catch return false;
    defer std.heap.c_allocator.free(theme_path);

    const file = std.fs.cwd().openFile(theme_path, .{}) catch |err| {
        log.warn("failed to open theme '{s}': {}", .{ name_slice, err });
        return false;
    };
    defer file.close();

    return loadThemeFromFile(state, file);
}

export fn ghostty_renderer_load_theme_file(state: *RendererState, path: [*:0]const u8) bool {
    const path_slice = std.mem.span(path);
    if (path_slice.len == 0) return false;

    const file = std.fs.cwd().openFile(path_slice, .{}) catch |err| {
        log.warn("failed to open theme file '{s}': {}", .{ path_slice, err });
        return false;
    };
    defer file.close();

    return loadThemeFromFile(state, file);
}

fn parseHexColor(s: []const u8) ?terminal.color.RGB {
    const hex = if (s.len > 0 and s[0] == '#') s[1..] else s;
    if (hex.len != 6) return null;
    return .{
        .r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null,
        .g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null,
        .b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null,
    };
}

fn loadThemeFromFile(state: *RendererState, file: std.fs.File) bool {
    const contents = file.readToEndAlloc(std.heap.c_allocator, 1024 * 64) catch return false;
    defer std.heap.c_allocator.free(contents);

    var any_applied = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue;

        const eq_idx = std.mem.indexOf(u8, line, "=") orelse continue;
        const key = std.mem.trim(u8, line[0..eq_idx], &std.ascii.whitespace);
        const value = std.mem.trim(u8, line[eq_idx + 1 ..], &std.ascii.whitespace);

        if (std.mem.eql(u8, key, "palette")) {
            // Format: N=#RRGGBB
            const palette_eq = std.mem.indexOf(u8, value, "=") orelse continue;
            const idx_str = std.mem.trim(u8, value[0..palette_eq], &std.ascii.whitespace);
            const color_str = std.mem.trim(u8, value[palette_eq + 1 ..], &std.ascii.whitespace);
            const idx = std.fmt.parseInt(u8, idx_str, 10) catch continue;
            const rgb = parseHexColor(color_str) orelse continue;
            if (state.terminal_set) {
                state.render_state.terminal.colors.palette.set(idx, rgb);
            }
            any_applied = true;
        } else if (std.mem.eql(u8, key, "background")) {
            const rgb = parseHexColor(value) orelse continue;
            ghostty_renderer_set_background(state, rgb.r, rgb.g, rgb.b);
            any_applied = true;
        } else if (std.mem.eql(u8, key, "foreground")) {
            const rgb = parseHexColor(value) orelse continue;
            ghostty_renderer_set_foreground(state, rgb.r, rgb.g, rgb.b);
            any_applied = true;
        }
    }

    return any_applied;
}

// ================================================================
// Runtime config
// ================================================================

export fn ghostty_renderer_set_background(state: *RendererState, r: u8, g: u8, b: u8) void {
    state.renderer.config.background = .{ .r = r, .g = g, .b = b };
    state.renderer.uniforms.bg_color = .{ r, g, b, state.renderer.uniforms.bg_color[3] };
    if (state.terminal_set) {
        state.render_state.terminal.colors.background = .init(.{ .r = r, .g = g, .b = b });
    }
}

export fn ghostty_renderer_set_foreground(state: *RendererState, r: u8, g: u8, b: u8) void {
    state.renderer.config.foreground = .{ .r = r, .g = g, .b = b };
    if (state.terminal_set) {
        state.render_state.terminal.colors.foreground = .init(.{ .r = r, .g = g, .b = b });
    }
}

export fn ghostty_renderer_set_background_opacity(state: *RendererState, opacity: f32) void {
    state.renderer.uniforms.bg_color[3] = @intFromFloat(@round(@max(0, @min(1, opacity)) * 255.0));
}

export fn ghostty_renderer_set_min_contrast(state: *RendererState, contrast: f32) void {
    state.renderer.uniforms.min_contrast = contrast;
}

export fn ghostty_renderer_set_palette(
    state: *RendererState,
    palette: [*]const extern struct { r: u8, g: u8, b: u8 },
) void {
    if (!state.terminal_set) return;
    const t = state.render_state.terminal;
    for (0..256) |i| {
        t.colors.palette.set(@intCast(i), .{
            .r = palette[i].r,
            .g = palette[i].g,
            .b = palette[i].b,
        });
    }
}
