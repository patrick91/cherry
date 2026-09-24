// Cherry's narrow adapter to the pinned upstream C API. No private layouts.
#include <ghostty/vt/terminal.h>
#include <ghostty/vt/formatter.h>
#include <ghostty/vt/grid_ref.h>
#include <ghostty/vt/modes.h>
#include <ghostty/vt/sgr.h>
#include <ghostty/vt/snapshot.h>
#include <ghostty/vt/allocator.h>
#include <ghostty/vt/style.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Receives encoded bytes. Rust appends them to a Vec.
typedef void (*CherrySink)(void *userdata, const uint8_t *bytes, size_t len);

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

// Plain text of the active screen including its history (diagnostics).
int cherry_vt_plain(GhosttyTerminal term, uint8_t **out, size_t *len) {
    GhosttyFormatterTerminalOptions opts;
    memset(&opts, 0, sizeof(opts));
    opts.size = sizeof(opts);
    opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
    GhosttyTerminalModeConfig wrap = { .mode = GHOSTTY_MODE_WRAPAROUND };
    int rc = ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_MODE, &wrap);
    if (rc) return rc;
    opts.unwrap = wrap.value;
    opts.trim = true;
    opts.extra.size = sizeof(opts.extra);
    opts.extra.screen.size = sizeof(opts.extra.screen);
    GhosttyFormatter formatter = NULL;
    rc = ghostty_formatter_terminal_new(NULL, &formatter, term, opts);
    if (!rc) rc = ghostty_formatter_format_alloc(formatter, NULL, out, len);
    ghostty_formatter_free(formatter);
    return rc;
}

typedef struct {
    uint64_t total_rows;
    uint64_t history_rows;
    uint16_t cols, rows, cursor_x, cursor_y;
    bool pending_wrap, cursor_visible, alternate;
    uint8_t kitty_flags;
} CherryInfo;

int cherry_vt_info(GhosttyTerminal term, CherryInfo *out) {
    memset(out, 0, sizeof(*out));
    size_t total = 0;
    GhosttyTerminalScreen screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    GhosttyTerminalData keys[] = {
        GHOSTTY_TERMINAL_DATA_COLS, GHOSTTY_TERMINAL_DATA_ROWS,
        GHOSTTY_TERMINAL_DATA_CURSOR_X, GHOSTTY_TERMINAL_DATA_CURSOR_Y,
        GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP, GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE,
        GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS,
        GHOSTTY_TERMINAL_DATA_TOTAL_ROWS,
    };
    void *values[] = {
        &out->cols, &out->rows, &out->cursor_x, &out->cursor_y,
        &out->pending_wrap, &out->cursor_visible, &screen, &out->kitty_flags, &total,
    };
    int rc = ghostty_terminal_get_multi(term, sizeof(keys) / sizeof(keys[0]), keys, values, NULL);
    if (rc) return rc;
    out->alternate = screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
    out->total_rows = total;
    out->history_rows = total > out->rows ? total - out->rows : 0;
    return 0;
}

int cherry_vt_set_terminfo_name(GhosttyTerminal term, const uint8_t *name, size_t len) {
    GhosttyString value = { .ptr = name, .len = len };
    return ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_TERMINFO_NAME, &value);
}

int cherry_vt_mode(GhosttyTerminal term, uint16_t value, bool ansi, bool *on) {
    GhosttyTerminalModeConfig mode = { .mode = ghostty_mode_new(value, ansi) };
    int rc = ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_MODE, &mode);
    *on = mode.value;
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

// ---------------------------------------------------------------------------
// Buffered output to a CherrySink.

typedef struct {
    CherrySink sink;
    void *userdata;
    size_t total;  // bytes produced so far, including buffered bytes
    size_t len;
    uint8_t buf[8192];
} Out;

static void out_init(Out *o, CherrySink sink, void *userdata) {
    o->sink = sink; o->userdata = userdata; o->total = 0; o->len = 0;
}

static void out_flush(Out *o) {
    if (o->len) { o->sink(o->userdata, o->buf, o->len); o->len = 0; }
}

static void out_write(Out *o, const void *bytes, size_t len) {
    o->total += len;
    if (len > sizeof(o->buf) - o->len) {
        out_flush(o);
        if (len > sizeof(o->buf)) { o->sink(o->userdata, bytes, len); return; }
    }
    memcpy(o->buf + o->len, bytes, len);
    o->len += len;
}

static void out_str(Out *o, const char *s) { out_write(o, s, strlen(s)); }

static void out_fmt(Out *o, const char *fmt, ...) {
    char tmp[96];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(tmp, sizeof(tmp), fmt, ap);
    va_end(ap);
    if (n > 0) out_write(o, tmp, (size_t)n < sizeof(tmp) ? (size_t)n : sizeof(tmp) - 1);
}

static void out_utf8(Out *o, uint32_t cp) {
    uint8_t b[4];
    size_t n;
    if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) cp = 0xFFFD;
    if (cp < 0x80) {
        b[0] = (uint8_t)cp; n = 1;
    } else if (cp < 0x800) {
        b[0] = (uint8_t)(0xC0 | (cp >> 6)); b[1] = (uint8_t)(0x80 | (cp & 0x3F)); n = 2;
    } else if (cp < 0x10000) {
        b[0] = (uint8_t)(0xE0 | (cp >> 12)); b[1] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
        b[2] = (uint8_t)(0x80 | (cp & 0x3F)); n = 3;
    } else {
        b[0] = (uint8_t)(0xF0 | (cp >> 18)); b[1] = (uint8_t)(0x80 | ((cp >> 12) & 0x3F));
        b[2] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F)); b[3] = (uint8_t)(0x80 | (cp & 0x3F)); n = 4;
    }
    out_write(o, b, n);
}

// ---------------------------------------------------------------------------
// Styles.

static void style_default(GhosttyStyle *style) {
    memset(style, 0, sizeof(*style));
    style->size = sizeof(*style);
    ghostty_style_default(style);
}

static bool color_eq(const GhosttyStyleColor *a, const GhosttyStyleColor *b) {
    if (a->tag != b->tag) return false;
    switch (a->tag) {
    case GHOSTTY_STYLE_COLOR_PALETTE: return a->value.palette == b->value.palette;
    case GHOSTTY_STYLE_COLOR_RGB:
        return a->value.rgb.r == b->value.rgb.r && a->value.rgb.g == b->value.rgb.g
            && a->value.rgb.b == b->value.rgb.b;
    default: return true;
    }
}

static bool style_eq(const GhosttyStyle *a, const GhosttyStyle *b) {
    return color_eq(&a->fg_color, &b->fg_color) && color_eq(&a->bg_color, &b->bg_color)
        && color_eq(&a->underline_color, &b->underline_color)
        && a->bold == b->bold && a->italic == b->italic && a->faint == b->faint
        && a->blink == b->blink && a->inverse == b->inverse && a->invisible == b->invisible
        && a->strikethrough == b->strikethrough && a->overline == b->overline
        && a->underline == b->underline;
}

static void sgr_color(Out *o, int base, const GhosttyStyleColor *color) {
    if (color->tag == GHOSTTY_STYLE_COLOR_PALETTE) {
        out_fmt(o, ";%d;5;%u", base, (unsigned)color->value.palette);
    } else if (color->tag == GHOSTTY_STYLE_COLOR_RGB) {
        out_fmt(o, ";%d;2;%u;%u;%u", base, (unsigned)color->value.rgb.r,
                (unsigned)color->value.rgb.g, (unsigned)color->value.rgb.b);
    }
}

// A self-contained SGR: reset, then every attribute. Underline styles other
// than single use a separate colon sequence so parameters never mix separators.
static void write_sgr(Out *o, const GhosttyStyle *s) {
    out_str(o, "\x1b[0");
    if (s->bold) out_str(o, ";1");
    if (s->faint) out_str(o, ";2");
    if (s->italic) out_str(o, ";3");
    if (s->blink) out_str(o, ";5");
    if (s->inverse) out_str(o, ";7");
    if (s->invisible) out_str(o, ";8");
    if (s->strikethrough) out_str(o, ";9");
    if (s->overline) out_str(o, ";53");
    if (s->underline == GHOSTTY_SGR_UNDERLINE_SINGLE) out_str(o, ";4");
    sgr_color(o, 38, &s->fg_color);
    sgr_color(o, 48, &s->bg_color);
    sgr_color(o, 58, &s->underline_color);
    out_str(o, "m");
    if (s->underline > GHOSTTY_SGR_UNDERLINE_SINGLE) out_fmt(o, "\x1b[4:%dm", s->underline);
}

// ---------------------------------------------------------------------------
// Grid access.

typedef struct {
    GhosttyGridRef ref;
    GhosttyCell cell;
    GhosttyCellContentTag tag;
    GhosttyCellWide wide;
    uint32_t codepoint;
    uint16_t style_id;
    bool has_text, hyperlink, protect;
} CellView;

static int row_at(GhosttyTerminal term, GhosttyPointTag tag, uint32_t y, GhosttyGridRef *ref) {
    GhosttyPoint point = { .tag = tag, .value.coordinate = { .x = 0, .y = y } };
    memset(ref, 0, sizeof(*ref));
    ref->size = sizeof(*ref);
    return ghostty_terminal_grid_ref(term, point, ref);
}

static int row_flags(const GhosttyGridRef *ref, bool *wrap, bool *continuation) {
    GhosttyRow row;
    int rc = ghostty_grid_ref_row(ref, &row);
    if (!rc) rc = ghostty_row_get(row, GHOSTTY_ROW_DATA_WRAP, wrap);
    if (!rc) rc = ghostty_row_get(row, GHOSTTY_ROW_DATA_WRAP_CONTINUATION, continuation);
    return rc;
}

// Every cell of a row lives in the row's page, so a row reference can be
// moved along x without another page-list lookup.
static int cell_at(const GhosttyGridRef *row, uint16_t x, CellView *v) {
    v->ref = *row;
    v->ref.x = x;
    int rc = ghostty_grid_ref_cell(&v->ref, &v->cell);
    if (rc) return rc;
    GhosttyCellData keys[] = {
        GHOSTTY_CELL_DATA_CONTENT_TAG, GHOSTTY_CELL_DATA_WIDE, GHOSTTY_CELL_DATA_CODEPOINT,
        GHOSTTY_CELL_DATA_STYLE_ID, GHOSTTY_CELL_DATA_HAS_TEXT,
        GHOSTTY_CELL_DATA_HAS_HYPERLINK, GHOSTTY_CELL_DATA_PROTECTED,
    };
    void *values[] = {
        &v->tag, &v->wide, &v->codepoint, &v->style_id, &v->has_text, &v->hyperlink, &v->protect,
    };
    return ghostty_cell_get_multi(v->cell, sizeof(keys) / sizeof(keys[0]), keys, values, NULL);
}

static bool is_bg_cell(const CellView *v) {
    return v->tag == GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE || v->tag == GHOSTTY_CELL_CONTENT_BG_COLOR_RGB;
}

// A text-less cell erased under a background colour, as a background-only pen.
static int bg_style(const CellView *v, GhosttyStyle *style) {
    style_default(style);
    if (v->tag == GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE) {
        GhosttyColorPaletteIndex index = 0;
        int rc = ghostty_cell_get(v->cell, GHOSTTY_CELL_DATA_COLOR_PALETTE, &index);
        style->bg_color.tag = GHOSTTY_STYLE_COLOR_PALETTE;
        style->bg_color.value.palette = index;
        return rc;
    }
    GhosttyColorRgb rgb = {0};
    int rc = ghostty_cell_get(v->cell, GHOSTTY_CELL_DATA_COLOR_RGB, &rgb);
    style->bg_color.tag = GHOSTTY_STYLE_COLOR_RGB;
    style->bg_color.value.rgb = rgb;
    return rc;
}

// The cell's hyperlink URI in `stack`, or in a heap buffer the caller frees
// when *uri != stack.
static int cell_link(const CellView *v, uint8_t *stack, size_t cap, uint8_t **uri, size_t *len) {
    *uri = stack; *len = 0;
    if (!v->hyperlink) return 0;
    int rc = ghostty_grid_ref_hyperlink_uri(&v->ref, stack, cap, len);
    if (rc == GHOSTTY_OUT_OF_SPACE) {
        *uri = malloc(*len);
        if (!*uri) return GHOSTTY_OUT_OF_MEMORY;
        rc = ghostty_grid_ref_hyperlink_uri(&v->ref, *uri, *len, len);
    }
    return rc;
}

// The cell's grapheme cluster without its first `skip` codepoints.
static int write_graphemes(Out *o, const CellView *v, size_t skip) {
    if (v->tag == GHOSTTY_CELL_CONTENT_CODEPOINT) {
        if (!skip) out_utf8(o, v->codepoint);
        return 0;
    }
    uint32_t stack[32];
    uint32_t *cps = stack;
    size_t n = 0;
    int rc = ghostty_grid_ref_graphemes(&v->ref, stack, 32, &n);
    if (rc == GHOSTTY_OUT_OF_SPACE) {
        cps = malloc(n * sizeof(*cps));
        if (!cps) return GHOSTTY_OUT_OF_MEMORY;
        rc = ghostty_grid_ref_graphemes(&v->ref, cps, n, &n);
    }
    if (!rc) for (size_t i = skip; i < n; i++) out_utf8(o, cps[i]);
    if (cps != stack) free(cps);
    return rc;
}

// Ghostty keeps a wide character printed under a DEC or national character
// set as a wide cell holding a space. Printed as is, that space is narrow,
// so it is printed the same way: an ideographic space (wide) under DEC
// special graphics, which maps it to a space, then G0 designated ASCII,
// which prints like Ghostty's UTF-8 default. Combining codepoints follow.
static int write_cell_text(Out *o, const CellView *v) {
    if (v->wide != GHOSTTY_CELL_WIDE_WIDE || v->codepoint != ' ') return write_graphemes(o, v, 0);
    out_str(o, "\x1b(0\xe3\x80\x80\x1b(B");
    return write_graphemes(o, v, 1);
}

// ---------------------------------------------------------------------------
// Cell encoder. It tracks the receiving terminal's cursor column and pen so
// each cell is written at its own column with its own attributes.

typedef struct {
    Out out;
    uint16_t edge;      // printing a cell that ends here leaves a pending wrap
    uint16_t col;
    bool pending;
    bool wrapping;      // the next print soft-wraps onto column 0 of a new row
    bool protect;
    bool link_open;
    GhosttyStyle pen;
    uint8_t *link;
    size_t link_len, link_cap;
    void *style_node;   // style ids are interned per page
    uint16_t style_id;
    GhosttyStyle style;
} Enc;

static void enc_init(Enc *e, CherrySink sink, void *userdata, uint16_t edge) {
    memset(e, 0, sizeof(*e));
    out_init(&e->out, sink, userdata);
    e->edge = edge;
    style_default(&e->pen);
}

static void enc_pen(Enc *e, const GhosttyStyle *style) {
    if (style_eq(&e->pen, style)) return;
    write_sgr(&e->out, style);
    e->pen = *style;
}

static void enc_reset_pen(Enc *e) {
    GhosttyStyle plain;
    style_default(&plain);
    if (style_eq(&e->pen, &plain)) return;
    out_str(&e->out, "\x1b[0m");
    e->pen = plain;
}

static int enc_link(Enc *e, const uint8_t *uri, size_t len) {
    if (len == 0) {
        if (e->link_open) out_str(&e->out, "\x1b]8;;\x1b\\");
        e->link_open = false;
        return 0;
    }
    if (e->link_open && e->link_len == len && memcmp(e->link, uri, len) == 0) return 0;
    if (len > e->link_cap) {
        uint8_t *grown = realloc(e->link, len);
        if (!grown) return GHOSTTY_OUT_OF_MEMORY;
        e->link = grown;
        e->link_cap = len;
    }
    memcpy(e->link, uri, len);
    e->link_len = len;
    e->link_open = true;
    out_str(&e->out, "\x1b]8;;");
    out_write(&e->out, uri, len);
    out_str(&e->out, "\x1b\\");
    return 0;
}

static void enc_protect(Enc *e, bool protect) {
    if (e->protect == protect) return;
    out_str(&e->out, protect ? "\x1b[1\"q" : "\x1b[0\"q");
    e->protect = protect;
}

static void enc_move(Enc *e, uint16_t x) {
    if (e->wrapping) return;
    if (!e->pending && e->col == x) return;
    if (!e->pending && x > e->col) {
        uint16_t n = x - e->col;
        if (n == 1) out_str(&e->out, "\x1b[C");
        else out_fmt(&e->out, "\x1b[%uC", (unsigned)n);
    } else {
        out_fmt(&e->out, "\x1b[%uG", (unsigned)x + 1);
    }
    e->col = x;
    e->pending = false;
}

static int enc_text(Enc *e, const CellView *v, uint16_t x) {
    bool wrapped = e->wrapping;
    enc_move(e, x);
    GhosttyStyle style;
    if (v->style_id == 0) {
        style_default(&style);
    } else if (e->style_node == v->ref.node && e->style_id == v->style_id) {
        style = e->style;
    } else {
        style_default(&style);
        int rc = ghostty_grid_ref_style(&v->ref, &style);
        if (rc) return rc;
        e->style_node = v->ref.node;
        e->style_id = v->style_id;
        e->style = style;
    }
    enc_pen(e, &style);
    uint8_t stack[256];
    uint8_t *uri = stack;
    size_t uri_len = 0;
    int rc = cell_link(v, stack, sizeof(stack), &uri, &uri_len);
    if (!rc) rc = enc_link(e, uri, uri_len);
    if (uri != stack) free(uri);
    if (rc) return rc;
    enc_protect(e, v->protect);
    if (v->has_text) {
        rc = write_cell_text(&e->out, v);
        if (rc) return rc;
    } else {
        out_write(&e->out, " ", 1);
    }
    // The receiver wrapped: it had a pending wrap, and now it has none.
    if (wrapped) { e->wrapping = false; e->col = 0; e->pending = false; }
    e->col += v->wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : 1;
    if (e->col >= e->edge) { e->col = e->edge - 1; e->pending = true; }
    // A soft wrap that scrolls fills the new row with the pen's background.
    if (wrapped && style.bg_color.tag != GHOSTTY_STYLE_COLOR_NONE && !e->pending) {
        enc_reset_pen(e);
        out_str(&e->out, "\x1b[K");
    }
    return 0;
}

// Cells [x0, x1) of one row. Empty cells are skipped, background-only runs are
// erased with ECH under their colour (erasing never moves the cursor), and a
// wide glyph that would cross x1 is omitted.
static int enc_row(Enc *e, const GhosttyGridRef *row, uint16_t x0, uint16_t x1) {
    CellView v, next;
    uint16_t x = x0;
    while (x < x1) {
        int rc = cell_at(row, x, &v);
        if (rc) return rc;
        if (v.wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || v.wide == GHOSTTY_CELL_WIDE_SPACER_HEAD) {
            x++;
            continue;
        }
        if (is_bg_cell(&v)) {
            GhosttyStyle bg, other;
            rc = bg_style(&v, &bg);
            if (rc) return rc;
            uint16_t end = x + 1;
            while (end < x1) {
                rc = cell_at(row, end, &next);
                if (rc) return rc;
                if (!is_bg_cell(&next)) break;
                rc = bg_style(&next, &other);
                if (rc) return rc;
                if (!style_eq(&bg, &other)) break;
                end++;
            }
            enc_move(e, x);
            enc_pen(e, &bg);
            out_fmt(&e->out, "\x1b[%uX", (unsigned)(end - x));
            x = end;
            continue;
        }
        if (!v.has_text && v.style_id == 0) {
            x++;
            continue;
        }
        if (v.wide == GHOSTTY_CELL_WIDE_WIDE && x + 1 >= x1) break;
        rc = enc_text(e, &v, x);
        if (rc) return rc;
        x += v.wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : 1;
    }
    return 0;
}

static void enc_finish(Enc *e) {
    enc_reset_pen(e);
    enc_link(e, NULL, 0);
    enc_protect(e, false);
    out_flush(&e->out);
    free(e->link);
    e->link = NULL;
}

// Rows [first, first + count) of the active screen, in screen coordinates
// (history first), as a stream for a fresh terminal whose cursor is at the
// start of an empty row. Every row consumes exactly one line, so the stream
// ends on the last row it encodes and history scrolls off in order. Soft
// wraps are reproduced by letting the receiver wrap. offsets, when given,
// receives count + 1 byte offsets: where each row (including its separator)
// starts, then the total. continuations, when given, receives each row's
// soft-wrap continuation flag.
int cherry_vt_stream_rows(GhosttyTerminal term, uint64_t first, uint64_t count,
                          size_t *offsets, bool *continuations,
                          CherrySink sink, void *userdata) {
    uint16_t cols = 0;
    int rc = ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_COLS, &cols);
    if (rc) return rc;
    Enc e;
    enc_init(&e, sink, userdata, cols);
    bool previous_wrap = false, previous_head = false;
    for (uint64_t i = 0; i < count && !rc; i++) {
        GhosttyGridRef row;
        bool wrap = false, continuation = false;
        rc = row_at(term, GHOSTTY_POINT_TAG_SCREEN, (uint32_t)(first + i), &row);
        if (!rc) rc = row_flags(&row, &wrap, &continuation);
        if (rc) break;
        if (offsets) offsets[i] = e.out.total;
        if (continuations) continuations[i] = continuation;
        if (i > 0) {
            bool natural = false;
            if (previous_wrap && continuation) {
                CellView head;
                rc = cell_at(&row, 0, &head);
                if (rc) break;
                bool text = head.has_text && !is_bg_cell(&head)
                    && (head.wide == GHOSTTY_CELL_WIDE_NARROW || head.wide == GHOSTTY_CELL_WIDE_WIDE);
                // A wide glyph that did not fit left a spacer head in the
                // last column: printed there, it wraps the same way.
                bool head_wraps = previous_head && cols > 1 && head.wide == GHOSTTY_CELL_WIDE_WIDE;
                natural = text && (e.pending || head_wraps);
                if (natural && head_wraps && !e.pending) enc_move(&e, cols - 1);
            }
            if (natural) {
                e.wrapping = true;
            } else {
                // Scrolling fills the new row with the pen's background.
                if (e.pen.bg_color.tag != GHOSTTY_STYLE_COLOR_NONE) enc_reset_pen(&e);
                out_str(&e.out, "\r\n");
                e.col = 0;
                e.pending = false;
            }
        }
        rc = enc_row(&e, &row, 0, cols);
        if (rc) break;
        CellView last;
        rc = cell_at(&row, cols - 1, &last);
        previous_wrap = wrap;
        previous_head = last.wide == GHOSTTY_CELL_WIDE_SPACER_HEAD;
    }
    if (!rc && offsets) offsets[count] = e.out.total;
    enc_finish(&e);
    return rc;
}

// Active rows [0, rows) clipped to width, each painted at its absolute row
// over a cleared line. Origin mode, insert mode and character sets on the
// receiver must be at their defaults.
int cherry_vt_paint_rows(GhosttyTerminal term, uint16_t rows, uint16_t width,
                         CherrySink sink, void *userdata) {
    Enc e;
    enc_init(&e, sink, userdata, width);
    int rc = 0;
    for (uint16_t y = 0; y < rows && !rc; y++) {
        GhosttyGridRef row;
        rc = row_at(term, GHOSTTY_POINT_TAG_ACTIVE, y, &row);
        if (rc) break;
        enc_reset_pen(&e);
        out_fmt(&e.out, "\x1b[%u;1H\x1b[2K", (unsigned)y + 1);
        e.col = 0;
        e.pending = false;
        rc = enc_row(&e, &row, 0, width);
    }
    enc_finish(&e);
    return rc;
}

// Active-row cells [x0, x1) printed from x0, where the caller has already put
// the receiver's cursor. Used to reprint the glyph that holds a pending wrap.
int cherry_vt_paint_cells(GhosttyTerminal term, uint16_t y, uint16_t x0, uint16_t x1,
                          CherrySink sink, void *userdata) {
    uint16_t cols = 0;
    int rc = ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_COLS, &cols);
    if (rc) return rc;
    Enc e;
    enc_init(&e, sink, userdata, cols);
    e.col = x0;
    GhosttyGridRef row;
    rc = row_at(term, GHOSTTY_POINT_TAG_ACTIVE, y, &row);
    if (!rc) rc = enc_row(&e, &row, x0, x1);
    enc_finish(&e);
    return rc;
}

int cherry_vt_wide(GhosttyTerminal term, uint16_t x, uint16_t y, int *wide) {
    GhosttyGridRef row;
    CellView v;
    int rc = row_at(term, GHOSTTY_POINT_TAG_ACTIVE, y, &row);
    if (!rc) rc = cell_at(&row, x, &v);
    *wide = rc ? GHOSTTY_CELL_WIDE_NARROW : (int)v.wide;
    return rc;
}

// The cursor's SGR pen as a self-contained sequence.
int cherry_vt_pen(GhosttyTerminal term, CherrySink sink, void *userdata) {
    GhosttyStyle style;
    style_default(&style);
    int rc = ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_CURSOR_STYLE, &style);
    if (rc) return rc;
    Out o;
    out_init(&o, sink, userdata);
    write_sgr(&o, &style);
    out_flush(&o);
    return 0;
}

// ---------------------------------------------------------------------------
// Upstream formatter extras for state without a getter (tab stops, margins,
// modifyOtherKeys, cursor hyperlink/protection, character sets). The C API
// always formats some content, so format one cell with and without the
// extras and keep the difference. Tab stops precede the content; every other
// extra follows it.

enum {
    CHERRY_EXTRA_TABSTOPS = 0,
    CHERRY_EXTRA_MARGINS = 1,
    CHERRY_EXTRA_KEYBOARD = 2,
    CHERRY_EXTRA_PEN = 3,
    CHERRY_EXTRA_CHARSETS = 4,
    CHERRY_EXTRA_STYLE = 5,  // the pen without the hyperlink (DECSC state)
};

static int format_cell(GhosttyTerminal term, const GhosttySelection *selection,
                       const GhosttyFormatterTerminalExtra *extra, uint8_t **out, size_t *len) {
    GhosttyFormatterTerminalOptions opts;
    memset(&opts, 0, sizeof(opts));
    opts.size = sizeof(opts);
    opts.emit = GHOSTTY_FORMATTER_FORMAT_VT;
    opts.trim = true;
    opts.extra = *extra;
    opts.extra.size = sizeof(opts.extra);
    opts.extra.screen.size = sizeof(opts.extra.screen);
    opts.selection = selection;
    GhosttyFormatter formatter = NULL;
    int rc = ghostty_formatter_terminal_new(NULL, &formatter, term, opts);
    if (!rc) rc = ghostty_formatter_format_alloc(formatter, NULL, out, len);
    ghostty_formatter_free(formatter);
    return rc;
}

int cherry_vt_extras(GhosttyTerminal term, int kind, CherrySink sink, void *userdata) {
    GhosttyFormatterTerminalExtra none, want;
    memset(&none, 0, sizeof(none));
    memset(&want, 0, sizeof(want));
    switch (kind) {
    case CHERRY_EXTRA_TABSTOPS: want.tabstops = true; break;
    case CHERRY_EXTRA_MARGINS: want.scrolling_region = true; break;
    case CHERRY_EXTRA_KEYBOARD: want.keyboard = true; break;
    case CHERRY_EXTRA_PEN:
        want.screen.style = true;
        want.screen.hyperlink = true;
        want.screen.protection = true;
        break;
    case CHERRY_EXTRA_CHARSETS: want.screen.charsets = true; break;
    case CHERRY_EXTRA_STYLE:
        want.screen.style = true;
        want.screen.protection = true;
        break;
    default: return GHOSTTY_INVALID_VALUE;
    }
    GhosttySelection selection;
    memset(&selection, 0, sizeof(selection));
    selection.size = sizeof(selection);
    GhosttyPoint point = { .tag = GHOSTTY_POINT_TAG_ACTIVE, .value.coordinate = { .x = 0, .y = 0 } };
    selection.start.size = sizeof(selection.start);
    int rc = ghostty_terminal_grid_ref(term, point, &selection.start);
    if (rc) return rc;
    selection.end = selection.start;
    uint8_t *base = NULL, *full = NULL;
    size_t base_len = 0, full_len = 0;
    rc = format_cell(term, &selection, &none, &base, &base_len);
    if (!rc) rc = format_cell(term, &selection, &want, &full, &full_len);
    if (!rc) {
        bool before = kind == CHERRY_EXTRA_TABSTOPS;
        if (full_len < base_len) {
            rc = GHOSTTY_INVALID_VALUE;
        } else {
            const uint8_t *cell = before ? full + (full_len - base_len) : full;
            if (base_len && memcmp(cell, base, base_len) != 0) rc = GHOSTTY_INVALID_VALUE;
            else if (full_len > base_len) sink(userdata, before ? full : full + base_len, full_len - base_len);
        }
    }
    ghostty_free(NULL, base, base_len);
    ghostty_free(NULL, full, full_len);
    return rc;
}

// ---------------------------------------------------------------------------
// Test support: a readable, style-aware description of one screen row.
// "[attrs]" precedes cells whose attributes differ from the previous cell.
// Empty cells are "·", background-only cells "░", wide-glyph spacers at a
// soft-wrapped edge "»".

static void describe_color(Out *o, const char *name, const GhosttyStyleColor *color) {
    if (color->tag == GHOSTTY_STYLE_COLOR_PALETTE) {
        out_fmt(o, " %s=p%u", name, (unsigned)color->value.palette);
    } else if (color->tag == GHOSTTY_STYLE_COLOR_RGB) {
        out_fmt(o, " %s=#%02x%02x%02x", name, (unsigned)color->value.rgb.r,
                (unsigned)color->value.rgb.g, (unsigned)color->value.rgb.b);
    }
}

static void describe_attrs(Out *o, const CellView *v, const GhosttyStyle *style,
                           const uint8_t *uri, size_t uri_len) {
    if (is_bg_cell(v)) describe_color(o, "cell-bg", &style->bg_color);
    else describe_color(o, "bg", &style->bg_color);
    describe_color(o, "fg", &style->fg_color);
    describe_color(o, "ul", &style->underline_color);
    if (style->bold) out_str(o, " bold");
    if (style->faint) out_str(o, " faint");
    if (style->italic) out_str(o, " italic");
    if (style->blink) out_str(o, " blink");
    if (style->inverse) out_str(o, " inverse");
    if (style->invisible) out_str(o, " invisible");
    if (style->strikethrough) out_str(o, " strike");
    if (style->overline) out_str(o, " overline");
    if (style->underline) out_fmt(o, " underline=%d", style->underline);
    if (v->protect) out_str(o, " protected");
    if (uri_len) { out_str(o, " link="); out_write(o, uri, uri_len); }
}

static void discard(void *userdata, const uint8_t *bytes, size_t len) {
    (void)userdata; (void)bytes; (void)len;
}

int cherry_vt_debug_row(GhosttyTerminal term, uint32_t y, CherrySink sink, void *userdata) {
    uint16_t cols = 0;
    int rc = ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_COLS, &cols);
    if (rc) return rc;
    GhosttyGridRef row;
    rc = row_at(term, GHOSTTY_POINT_TAG_SCREEN, y, &row);
    if (rc) return rc;
    // Attribute descriptions are compared through two unflushed buffers.
    Out *previous = calloc(1, sizeof(Out)), *current = calloc(1, sizeof(Out)), *o = calloc(1, sizeof(Out));
    if (!previous || !current || !o) { free(previous); free(current); free(o); return GHOSTTY_OUT_OF_MEMORY; }
    out_init(o, sink, userdata);
    out_init(previous, discard, NULL);
    for (uint16_t x = 0; x < cols && !rc; x++) {
        CellView v;
        rc = cell_at(&row, x, &v);
        if (rc) break;
        if (v.wide == GHOSTTY_CELL_WIDE_SPACER_TAIL) continue;
        GhosttyStyle style;
        style_default(&style);
        if (is_bg_cell(&v)) rc = bg_style(&v, &style);
        else if (v.style_id) rc = ghostty_grid_ref_style(&v.ref, &style);
        if (rc) break;
        uint8_t stack[256];
        uint8_t *uri = stack;
        size_t uri_len = 0;
        rc = cell_link(&v, stack, sizeof(stack), &uri, &uri_len);
        if (rc) break;
        out_init(current, discard, NULL);
        describe_attrs(current, &v, &style, uri, uri_len);
        if (uri != stack) free(uri);
        if (current->len != previous->len || memcmp(current->buf, previous->buf, current->len) != 0) {
            out_str(o, "[");
            if (current->len > 1) out_write(o, current->buf + 1, current->len - 1);
            out_str(o, "]");
            Out *swap = previous;
            previous = current;
            current = swap;
        }
        if (is_bg_cell(&v)) out_str(o, "\xe2\x96\x91");
        else if (v.wide == GHOSTTY_CELL_WIDE_SPACER_HEAD) out_str(o, "\xc2\xbb");
        else if (v.has_text) rc = write_graphemes(o, &v, 0);
        else out_str(o, "\xc2\xb7");
    }
    out_flush(o);
    free(previous);
    free(current);
    free(o);
    return rc;
}

int cherry_vt_row_flags(GhosttyTerminal term, uint32_t y, bool *wrap, bool *continuation) {
    GhosttyGridRef row;
    int rc = row_at(term, GHOSTTY_POINT_TAG_SCREEN, y, &row);
    if (!rc) rc = row_flags(&row, wrap, continuation);
    return rc;
}
