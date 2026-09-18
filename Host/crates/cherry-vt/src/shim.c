// Cherry's narrow adapter to the pinned upstream C API. No private layouts.
#include <ghostty/vt/terminal.h>
#include <ghostty/vt/formatter.h>
#include <ghostty/vt/snapshot.h>
#include <ghostty/vt/allocator.h>
#include <string.h>

static bool terminal_size(GhosttyTerminal term, void *userdata, GhosttySizeReportSize *out) {
    (void)userdata;
    out->cell_width = 8; out->cell_height = 16;
    return !ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_COLS, &out->columns)
        && !ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_ROWS, &out->rows);
}

static bool terminal_color_scheme(GhosttyTerminal term, void *userdata, GhosttyColorScheme *out) {
    (void)term; (void)userdata;
    *out = GHOSTTY_COLOR_SCHEME_DARK;
    return true;
}

int cherry_vt_new(GhosttyTerminal *out, uint16_t cols, uint16_t rows,
                  size_t scrollback, void *userdata, GhosttyTerminalWritePtyFn reply) {
    int rc = ghostty_terminal_new(NULL, out, cols, rows);
    if (rc) return rc;
    // Retain unfinished UTF-8 / control sequences so snapshot + subsequent
    // output remains valid even when a PTY read splits an escape sequence.
    size_t continuation_limit = 1024 * 1024;
    GhosttyColorRgb foreground = { .r=229, .g=229, .b=229 };
    GhosttyColorRgb background = { .r=0, .g=0, .b=0 };
    rc = ghostty_terminal_set(*out, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback);
    if (!rc) rc = ghostty_terminal_set(*out, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &continuation_limit);
    if (!rc) rc = ghostty_terminal_set(*out, GHOSTTY_TERMINAL_OPT_USERDATA, userdata);
    if (!rc) rc = ghostty_terminal_set(*out, GHOSTTY_TERMINAL_OPT_WRITE_PTY, (void *)reply);
    if (!rc) rc = ghostty_terminal_set(*out, GHOSTTY_TERMINAL_OPT_SIZE, (void *)terminal_size);
    if (!rc) rc = ghostty_terminal_set(*out, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, (void *)terminal_color_scheme);
    if (!rc) rc = ghostty_terminal_set(*out, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground);
    if (!rc) rc = ghostty_terminal_set(*out, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background);
    if (!rc) rc = ghostty_terminal_set(*out, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &foreground);
    if (rc) { ghostty_terminal_free(*out); *out = NULL; }
    return rc;
}

int cherry_vt_format(GhosttyTerminal term, bool plain, uint8_t **out, size_t *len) {
    GhosttyFormatterTerminalOptions opts = {0};
    opts.size = sizeof(opts);
    opts.emit = plain ? GHOSTTY_FORMATTER_FORMAT_PLAIN : GHOSTTY_FORMATTER_FORMAT_VT;
    GhosttyTerminalModeConfig wrap = { .mode = GHOSTTY_MODE_WRAPAROUND };
    int rc = ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_MODE, &wrap);
    if (rc) return rc;
    opts.unwrap = wrap.value;
    opts.trim = true;
    opts.extra.size = sizeof(opts.extra);
    opts.extra.modes = !plain;
    opts.extra.scrolling_region = !plain;
    opts.extra.tabstops = !plain;
    opts.extra.keyboard = !plain;
    opts.extra.screen.size = sizeof(opts.extra.screen);
    opts.extra.screen.cursor = !plain;
    opts.extra.screen.style = !plain;
    opts.extra.screen.hyperlink = !plain;
    opts.extra.screen.protection = !plain;
    opts.extra.screen.kitty_keyboard = !plain;
    opts.extra.screen.charsets = !plain;
    GhosttyFormatter formatter = NULL;
    rc = ghostty_formatter_terminal_new(NULL, &formatter, term, opts);
    if (rc) return rc;
    rc = ghostty_formatter_format_alloc(formatter, NULL, out, len);
    ghostty_formatter_free(formatter);
    return rc;
}

// A single active-screen row, clipped to the physical viewport. Formatting
// rows independently prevents soft wraps from reflowing on a wider device.
int cherry_vt_viewport_row(GhosttyTerminal term, uint16_t row, uint16_t width,
                          bool extras, uint8_t **out, size_t *len) {
    uint16_t cols;
    int rc = ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_COLS, &cols);
    if (rc) return rc;
    if (width > cols) width = cols;
    GhosttySelection selection = { .size=sizeof(selection) };
    GhosttyPoint point = { .tag=GHOSTTY_POINT_TAG_ACTIVE,
        .value.coordinate={.x=0, .y=row} };
    rc = ghostty_terminal_grid_ref(term, point, &selection.start);
    if (rc) return rc;
    point.value.coordinate.x = width - 1;
    rc = ghostty_terminal_grid_ref(term, point, &selection.end);
    if (rc) return rc;
    // A wide glyph whose second cell is outside the viewport must not wrap.
    GhosttyCell cell;
    GhosttyCellWide wide;
    rc = ghostty_grid_ref_cell(&selection.end, &cell);
    if (!rc) rc = ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide);
    if (rc) return rc;
    if (wide == GHOSTTY_CELL_WIDE_WIDE && width < cols) {
        if (width == 1) { *out=NULL; *len=0; return 0; }
        point.value.coordinate.x--;
        rc = ghostty_terminal_grid_ref(term, point, &selection.end);
        if (rc) return rc;
    }
    GhosttyFormatterTerminalOptions opts = {0};
    opts.size = sizeof(opts);
    opts.emit = GHOSTTY_FORMATTER_FORMAT_VT;
    opts.unwrap = false;
    opts.trim = true;
    opts.selection = &selection;
    opts.extra.size = sizeof(opts.extra);
    opts.extra.modes = extras;
    opts.extra.keyboard = extras;
    opts.extra.screen.size = sizeof(opts.extra.screen);
    opts.extra.screen.style = extras;
    opts.extra.screen.hyperlink = extras;
    opts.extra.screen.protection = extras;
    opts.extra.screen.kitty_keyboard = extras;
    opts.extra.screen.charsets = extras;
    GhosttyFormatter formatter = NULL;
    rc = ghostty_formatter_terminal_new(NULL, &formatter, term, opts);
    if (!rc) rc = ghostty_formatter_format_alloc(formatter, NULL, out, len);
    ghostty_formatter_free(formatter);
    return rc;
}

int cherry_vt_alternate(GhosttyTerminal term, bool *alternate) {
    GhosttyTerminalScreen screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    int rc = ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
    *alternate = screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
    return rc;
}

int cherry_vt_cursor(GhosttyTerminal term, uint16_t *x, uint16_t *y, bool *origin) {
    int rc = ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_CURSOR_X, x);
    if (!rc) rc = ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_CURSOR_Y, y);
    GhosttyTerminalModeConfig mode = { .mode = GHOSTTY_MODE_ORIGIN };
    if (!rc) rc = ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_MODE, &mode);
    *origin = mode.value;
    return rc;
}

int cherry_vt_clone(GhosttyTerminal term, GhosttyTerminal *out) {
    uint8_t *bytes = NULL;
    size_t len = 0;
    int rc = ghostty_snapshot_encode_alloc(term, NULL, &bytes, &len);
    if (rc) return rc;
    GhosttySnapshotDecoder decoder = NULL;
    rc = ghostty_snapshot_decoder_new_buf(NULL, &decoder, bytes, len);
    if (!rc) rc = ghostty_snapshot_decoder_decode(decoder, out);
    ghostty_snapshot_decoder_free(decoder);
    ghostty_free(NULL, bytes, len);
    return rc;
}

// CUP clears pending-wrap. Reprinting the final glyph restores it, and the
// formatter's style-only extras put the active pen back without moving cursor.
int cherry_vt_pending_tail(GhosttyTerminal term, uint8_t **out, size_t *len, uint16_t *rewind) {
    *out = NULL; *len = 0; *rewind = 0;
    bool pending = false;
    int rc = ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP, &pending);
    if (rc || !pending) return rc;
    uint16_t x, y;
    rc = ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x);
    if (!rc) rc = ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y);
    if (rc) return rc;
    GhosttyPoint point = { .tag = GHOSTTY_POINT_TAG_ACTIVE, .value.coordinate = {.x=x, .y=y} };
    GhosttySelection selection = { .size=sizeof(selection) };
    rc = ghostty_terminal_grid_ref(term, point, &selection.end);
    if (rc) return rc;
    selection.start = selection.end;
    GhosttyCell cell;
    GhosttyCellWide wide;
    rc = ghostty_grid_ref_cell(&selection.end, &cell);
    if (!rc) rc = ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide);
    if (rc) return rc;
    if (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL && x > 0) {
        *rewind = 1;
        point.value.coordinate.x--;
        rc = ghostty_terminal_grid_ref(term, point, &selection.start);
        if (rc) return rc;
    }
    GhosttyFormatterTerminalOptions opts = {0};
    opts.size = sizeof(opts);
    opts.emit = GHOSTTY_FORMATTER_FORMAT_VT;
    opts.selection = &selection;
    opts.extra.size = sizeof(opts.extra);
    opts.extra.screen.size = sizeof(opts.extra.screen);
    opts.extra.screen.style = true;
    opts.extra.screen.hyperlink = true;
    opts.extra.screen.protection = true;
    GhosttyFormatter formatter = NULL;
    rc = ghostty_formatter_terminal_new(NULL, &formatter, term, opts);
    if (!rc) rc = ghostty_formatter_format_alloc(formatter, NULL, out, len);
    ghostty_formatter_free(formatter);
    return rc;
}
