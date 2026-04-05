/**
 * libghostty-renderer
 *
 * Terminal emulation + GPU-ready cell buffer generation.
 * Platform-independent C API.
 *
 * Level 1: bind a native surface, library draws everything.
 * Level 2: library builds cell buffers + glyph atlas,
 *          consumer owns the GPU pipeline.
 */

#ifndef GHOSTTY_RENDERER_H
#define GHOSTTY_RENDERER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ================================================================
 * Handles
 * ================================================================ */

typedef struct GhosttyRendererImpl *GhosttyRenderer;
typedef struct GhosttyTerminalImpl *GhosttyTerminal;

/* ================================================================
 * Basic types
 * ================================================================ */

typedef struct { uint8_t r, g, b; } GhosttyColor;
typedef struct { GhosttyColor color; bool has; } GhosttyOptColor;

/* ================================================================
 * Enums
 * ================================================================ */

typedef enum {
    GHOSTTY_COLORSPACE_SRGB = 0,
    GHOSTTY_COLORSPACE_DISPLAY_P3 = 1,
} GhosttyColorspace;

typedef enum {
    GHOSTTY_BLENDING_NATIVE = 0,
    GHOSTTY_BLENDING_LINEAR = 1,
    GHOSTTY_BLENDING_LINEAR_CORRECTED = 2,
} GhosttyBlending;

typedef enum {
    GHOSTTY_PADDING_COLOR_BACKGROUND = 0,
    GHOSTTY_PADDING_COLOR_EXTEND = 1,
    GHOSTTY_PADDING_COLOR_EXTEND_ALWAYS = 2,
} GhosttyPaddingColor;

/* ================================================================
 * Renderer configuration
 *
 * Zero-init produces usable defaults.
 * All strings are copied during new(); caller may free after.
 * ================================================================ */

typedef struct {
    /* Surface */
    uint32_t width_px;                 /* 0 -> 800 */
    uint32_t height_px;                /* 0 -> 600 */
    double   content_scale;            /* 0 -> 1.0 */

    /* Font */
    float       font_size;             /* 0 -> 13.0 */
    const char *font_family;           /* NULL -> system default */
    const char *font_family_bold;      /* NULL -> derive from regular */
    const char *font_family_italic;    /* NULL -> derive from regular */
    const char *font_family_bold_italic;
    const char *font_features;         /* comma-separated: "ss01,liga" */
    bool        font_thicken;
    uint8_t     font_thicken_strength; /* 0 -> 127 */

    /* Colors */
    GhosttyColor    background;
    GhosttyColor    foreground;
    GhosttyOptColor cursor_color;
    GhosttyOptColor cursor_text;
    GhosttyOptColor selection_background;
    GhosttyOptColor selection_foreground;
    GhosttyOptColor bold_color;

    /* Search colors */
    GhosttyColor search_match_bg;
    GhosttyColor search_match_fg;
    GhosttyColor search_selected_bg;
    GhosttyColor search_selected_fg;

    /* Opacity */
    float background_opacity;          /* 0 -> 1.0 */
    float cursor_opacity;              /* 0 -> 1.0 */
    float faint_opacity;               /* 0 -> 0.5 */

    /* Rendering */
    float               min_contrast;  /* 0 -> 1.0 */
    GhosttyColorspace   colorspace;
    GhosttyBlending     alpha_blending;
    GhosttyPaddingColor padding_color;

    /* Behavior */
    bool scroll_to_bottom_on_output;
} GhosttyRendererConfig;

/* ================================================================
 * Renderer lifecycle
 * ================================================================ */

/** Create a renderer.
 *  native_handle: platform-specific window handle (macOS: NSView*).
 *                 May be NULL for headless / Level 2 only use. */
GhosttyRenderer ghostty_renderer_new(const GhosttyRendererConfig *config,
                                     void *native_handle);
void ghostty_renderer_free(GhosttyRenderer r);

void ghostty_renderer_set_terminal(GhosttyRenderer r, GhosttyTerminal t);
void ghostty_renderer_resize(GhosttyRenderer r,
                             uint32_t width_px, uint32_t height_px,
                             double content_scale);

/* ================================================================
 * Theme
 * ================================================================ */

bool ghostty_renderer_load_theme(GhosttyRenderer r, const char *name);
bool ghostty_renderer_load_theme_file(GhosttyRenderer r, const char *path);

/* ================================================================
 * Runtime config updates
 * ================================================================ */

void ghostty_renderer_set_font_size(GhosttyRenderer r, float points);
void ghostty_renderer_set_background(GhosttyRenderer r,
                                     uint8_t red, uint8_t green, uint8_t blue);
void ghostty_renderer_set_foreground(GhosttyRenderer r,
                                     uint8_t red, uint8_t green, uint8_t blue);
void ghostty_renderer_set_background_opacity(GhosttyRenderer r, float o);
void ghostty_renderer_set_min_contrast(GhosttyRenderer r, float c);
void ghostty_renderer_set_palette(GhosttyRenderer r,
                                  const GhosttyColor palette[256]);

/* ================================================================
 * Level 1: library draws
 * ================================================================ */

void ghostty_renderer_update_frame(GhosttyRenderer r);
void ghostty_renderer_draw_frame(GhosttyRenderer r);

/* ================================================================
 * Level 2: consumer draws
 *
 * Call update_frame() first. Pointers valid until next update_frame().
 * ================================================================ */

typedef uint8_t GhosttyRendererCellBg[4];

typedef struct {
    uint32_t glyph_pos[2];
    uint32_t glyph_size[2];
    int16_t  bearings[2];
    uint16_t grid_pos[2];
    uint8_t  color[4];
    uint8_t  atlas;
    uint8_t  flags;
} GhosttyRendererCellText;

typedef struct {
    float    cell_width, cell_height;
    uint16_t grid_cols, grid_rows;
    float    grid_padding[4];
    uint8_t  bg_color[4];
    float    min_contrast;
    uint16_t cursor_pos[2];
    uint8_t  cursor_color[4];
    bool     cursor_wide;
} GhosttyRendererFrameData;

const GhosttyRendererCellBg *ghostty_renderer_get_bg_cells(
    GhosttyRenderer r, uint32_t *count);
const GhosttyRendererCellText *ghostty_renderer_get_text_cells(
    GhosttyRenderer r, uint32_t *count);
void ghostty_renderer_get_frame_data(
    GhosttyRenderer r, GhosttyRendererFrameData *out);
const uint8_t *ghostty_renderer_get_atlas_grayscale(
    GhosttyRenderer r, uint32_t *size, bool *modified);
const uint8_t *ghostty_renderer_get_atlas_color(
    GhosttyRenderer r, uint32_t *size, bool *modified);

/* ================================================================
 * Terminal lifecycle & I/O
 * ================================================================ */

GhosttyTerminal ghostty_terminal_new(uint16_t cols, uint16_t rows,
                                     uint32_t max_scrollback);
void ghostty_terminal_free(GhosttyTerminal t);
void ghostty_terminal_vt_write(GhosttyTerminal t,
                               const uint8_t *data, size_t len);
void ghostty_terminal_resize(GhosttyTerminal t,
                             uint16_t cols, uint16_t rows);
const uint8_t *ghostty_terminal_drain_responses(
    GhosttyTerminal t, size_t *out_len);
void ghostty_terminal_clear_responses(GhosttyTerminal t);

/* ================================================================
 * Terminal state queries
 * ================================================================ */

void ghostty_terminal_get_size(GhosttyTerminal t,
                               uint16_t *cols, uint16_t *rows);
void ghostty_terminal_get_cursor(GhosttyTerminal t,
                                 uint16_t *col, uint16_t *row,
                                 bool *visible);
const char *ghostty_terminal_get_title(GhosttyTerminal t, size_t *len);

/* ================================================================
 * Terminal scrolling
 * ================================================================ */

typedef enum {
    GHOSTTY_SCROLL_LINES = 0,
    GHOSTTY_SCROLL_TOP = 1,
    GHOSTTY_SCROLL_BOTTOM = 2,
    GHOSTTY_SCROLL_PAGE_UP = 3,
    GHOSTTY_SCROLL_PAGE_DOWN = 4,
} GhosttyScrollAction;

void ghostty_terminal_scroll(GhosttyTerminal t,
                             GhosttyScrollAction action,
                             int32_t delta);
size_t ghostty_terminal_get_scrollback_rows(GhosttyTerminal t);

/* ================================================================
 * Memory
 * ================================================================ */

void ghostty_free(void *ptr);

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_RENDERER_H */
