/**
 * libghostty-renderer
 *
 * GPU-ready cell buffer generation from a terminal + font system.
 * The consumer provides a GhosttyTerminal from libghostty-vt and gets
 * back cell arrays + glyph atlas textures for their own GPU pipeline.
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

typedef struct GhosttyFontGridImpl *GhosttyFontGrid;
typedef struct GhosttyRendererImpl *GhosttyRenderer;

/* GhosttyTerminal from libghostty-vt (opaque, passed through) */
typedef void *GhosttyTerminal;

/* ================================================================
 * Basic types
 * ================================================================ */

typedef struct { uint8_t r, g, b; } GhosttyRendererRGB;
typedef struct { GhosttyRendererRGB color; bool has; } GhosttyRendererOptRGB;

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
 * Font grid config (zero-init for defaults)
 * ================================================================ */

typedef struct {
    float       font_size;             /* 0 -> 13.0 */
    const char *font_family;           /* NULL -> system default */
    const char *font_family_bold;
    const char *font_family_italic;
    const char *font_family_bold_italic;
    const char *font_features;         /* comma-separated */
    bool        font_thicken;
    double      content_scale;         /* 0 -> 1.0 */
} GhosttyFontGridConfig;

typedef struct {
    float cell_width, cell_height, cell_baseline;
    float underline_position, underline_thickness;
    float strikethrough_position, strikethrough_thickness;
} GhosttyFontMetrics;

/* ================================================================
 * Font grid API
 * ================================================================ */

GhosttyFontGrid ghostty_font_grid_new(const GhosttyFontGridConfig *config);
void ghostty_font_grid_free(GhosttyFontGrid grid);
void ghostty_font_grid_get_metrics(GhosttyFontGrid grid, GhosttyFontMetrics *out);
const uint8_t *ghostty_font_grid_atlas_grayscale(GhosttyFontGrid grid,
                                                  uint32_t *size, bool *modified);
const uint8_t *ghostty_font_grid_atlas_color(GhosttyFontGrid grid,
                                              uint32_t *size, bool *modified);
void ghostty_font_grid_set_size(GhosttyFontGrid grid, float points);

/* ================================================================
 * Renderer config (zero-init for defaults)
 * ================================================================ */

typedef struct {
    uint32_t width_px;                 /* 0 -> 800 */
    uint32_t height_px;                /* 0 -> 600 */
    double   content_scale;            /* 0 -> 1.0 */
    void    *native_view;              /* NSView* on macOS, NULL for headless */

    GhosttyRendererRGB    background;
    GhosttyRendererRGB    foreground;
    GhosttyRendererOptRGB cursor_color;
    GhosttyRendererOptRGB cursor_text;
    GhosttyRendererOptRGB selection_background;
    GhosttyRendererOptRGB selection_foreground;
    GhosttyRendererOptRGB bold_color;

    GhosttyRendererRGB search_match_bg, search_match_fg;
    GhosttyRendererRGB search_selected_bg, search_selected_fg;

    float background_opacity, cursor_opacity, faint_opacity;
    float               min_contrast;
    GhosttyColorspace   colorspace;
    GhosttyBlending     alpha_blending;
    GhosttyPaddingColor padding_color;
} GhosttyRendererConfig;

/* ================================================================
 * Renderer API
 * ================================================================ */

GhosttyRenderer ghostty_renderer_new(GhosttyFontGrid grid,
                                     const GhosttyRendererConfig *config);
void ghostty_renderer_free(GhosttyRenderer r);
void ghostty_renderer_set_terminal(GhosttyRenderer r, GhosttyTerminal t);
void ghostty_renderer_resize(GhosttyRenderer r, uint32_t width_px, uint32_t height_px);
void ghostty_renderer_update_frame(GhosttyRenderer r, bool cursor_blink_visible);

/* Cell buffer output (pointers valid until next update_frame) */

typedef uint8_t GhosttyRendererCellBg[4];

typedef struct {
    uint32_t glyph_pos[2];
    uint32_t glyph_size[2];
    int16_t  bearings[2];
    uint16_t grid_pos[2];
    uint8_t  color[4];
    uint8_t  atlas;
    uint8_t  flags;
    uint8_t  _pad[2];
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

const GhosttyRendererCellBg *ghostty_renderer_bg_cells(GhosttyRenderer r, uint32_t *count);
const GhosttyRendererCellText *ghostty_renderer_text_cells(GhosttyRenderer r, uint32_t *count);
void ghostty_renderer_frame_data(GhosttyRenderer r, GhosttyRendererFrameData *out);

/* Theme & runtime config */

bool ghostty_renderer_load_theme(GhosttyRenderer r, const char *name);
bool ghostty_renderer_load_theme_file(GhosttyRenderer r, const char *path);
void ghostty_renderer_set_background(GhosttyRenderer r, uint8_t r_, uint8_t g, uint8_t b);
void ghostty_renderer_set_foreground(GhosttyRenderer r, uint8_t r_, uint8_t g, uint8_t b);
void ghostty_renderer_set_background_opacity(GhosttyRenderer r, float opacity);
void ghostty_renderer_set_min_contrast(GhosttyRenderer r, float contrast);
void ghostty_renderer_set_palette(GhosttyRenderer r, const GhosttyRendererRGB palette[256]);

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_RENDERER_H */
