//! Headless Ghostty terminal state. The host owns query replies; a frontend
//! must filter answered queries from its display stream to avoid duplicate input.
use anyhow::{bail, ensure, Result};
use std::{ffi::c_void, io::Write, marker::PhantomData, ptr::NonNull};

type Handle = *mut c_void;
type Sink = extern "C" fn(*mut c_void, *const u8, usize);

#[repr(C)]
#[derive(Default)]
struct Info {
    total_rows: u64,
    history_rows: u64,
    cols: u16,
    rows: u16,
    cursor_x: u16,
    cursor_y: u16,
    pending_wrap: bool,
    cursor_visible: bool,
    alternate: bool,
    kitty_flags: u8,
}

unsafe extern "C" {
    fn cherry_vt_new(
        out: *mut Handle,
        cols: u16,
        rows: u16,
        scrollback: usize,
        userdata: *mut c_void,
        reply: extern "C" fn(Handle, *mut c_void, *const u8, usize),
    ) -> i32;
    fn cherry_vt_plain(term: Handle, out: *mut *mut u8, len: *mut usize) -> i32;
    fn cherry_vt_info(term: Handle, out: *mut Info) -> i32;
    fn cherry_vt_set_terminfo_name(term: Handle, name: *const u8, len: usize) -> i32;
    fn cherry_vt_mode(term: Handle, value: u16, ansi: bool, on: *mut bool) -> i32;
    fn cherry_vt_clone(term: Handle, out: *mut Handle) -> i32;
    fn cherry_vt_stream_rows(
        term: Handle,
        first: u64,
        count: u64,
        offsets: *mut usize,
        continuations: *mut bool,
        sink: Sink,
        userdata: *mut c_void,
    ) -> i32;
    fn cherry_vt_paint_rows(
        term: Handle,
        rows: u16,
        width: u16,
        sink: Sink,
        userdata: *mut c_void,
    ) -> i32;
    fn cherry_vt_paint_cells(
        term: Handle,
        y: u16,
        x0: u16,
        x1: u16,
        sink: Sink,
        userdata: *mut c_void,
    ) -> i32;
    fn cherry_vt_wide(term: Handle, x: u16, y: u16, wide: *mut i32) -> i32;
    fn cherry_vt_pen(term: Handle, sink: Sink, userdata: *mut c_void) -> i32;
    fn cherry_vt_extras(term: Handle, kind: i32, sink: Sink, userdata: *mut c_void) -> i32;
    fn cherry_vt_debug_row(term: Handle, y: u32, sink: Sink, userdata: *mut c_void) -> i32;
    fn cherry_vt_row_flags(term: Handle, y: u32, wrap: *mut bool, continuation: *mut bool) -> i32;
    fn ghostty_terminal_free(term: Handle);
    fn ghostty_terminal_vt_write(term: Handle, bytes: *const u8, len: usize);
    fn ghostty_terminal_resize(
        term: Handle,
        cols: u16,
        rows: u16,
        cell_width: u32,
        cell_height: u32,
    ) -> i32;
    fn ghostty_terminal_continuation_alloc(
        term: Handle,
        allocator: *const c_void,
        bytes: *mut *mut u8,
        len: *mut usize,
    ) -> i32;
    fn ghostty_free(allocator: *const c_void, bytes: *mut c_void, len: usize);
}

// Upstream formatter extras, see cherry_vt_extras in shim.c.
const EXTRA_TABSTOPS: i32 = 0;
const EXTRA_MARGINS: i32 = 1;
const EXTRA_KEYBOARD: i32 = 2;
const EXTRA_PEN: i32 = 3;
const EXTRA_CHARSETS: i32 = 4;
const EXTRA_STYLE: i32 = 5;
const WIDE_SPACER_TAIL: i32 = 2;

/// Modes carried by snapshots and `modes()`: (value, ANSI, libghostty default).
/// Not listed: DECCOLM (3) would resize the receiver, 1048 is an action,
/// 47/1047/1049 switch screens and are handled on their own, and in-band
/// size reports (2048) and visibility reports (2033) are answered by the
/// host itself; a renderer with them enabled would report a second time.
const MODES: &[(u16, bool, bool)] = &[
    (2, true, false),
    (4, true, false),
    (12, true, true),
    (20, true, false),
    (1, false, false),
    (4, false, false),
    (5, false, false),
    (6, false, false),
    (7, false, true),
    (8, false, false),
    (9, false, false),
    (12, false, false),
    (25, false, true),
    (40, false, false),
    (45, false, false),
    (66, false, false),
    (67, false, false),
    (69, false, false),
    (1000, false, false),
    (1002, false, false),
    (1003, false, false),
    (1004, false, false),
    (1005, false, false),
    (1006, false, false),
    (1007, false, true),
    (1015, false, false),
    (1016, false, false),
    (1035, false, true),
    (1036, false, true),
    (1039, false, false),
    (1045, false, false),
    (2004, false, false),
    (2026, false, false),
    (2027, false, false),
    (2031, false, false),
    (5522, false, false),
];
const ALTERNATE_SCREEN_MODES: [u16; 3] = [1049, 1047, 47];

/// Cursor visibility and synchronized output belong to viewport frames.
fn frame_mode(value: u16, ansi: bool) -> bool {
    !ansi && matches!(value, 25 | 2026)
}

/// Modes whose default comes from the user's terminal settings, not from the
/// VT standard: DECARM (8, which libghostty defaults to off and does not
/// implement), alternate scroll (1007), the Meta and Alt key modes (1035,
/// 1036, 1039) and grapheme clustering (2027). They are never reset to
/// libghostty's default; they are sent only while the session has them away
/// from it, as the session's own output would.
fn user_default_mode(value: u16, ansi: bool) -> bool {
    !ansi && matches!(value, 8 | 1007 | 1035 | 1036 | 1039 | 2027)
}

/// What `refresh()` resets before painting, on whichever screen the
/// receiver is: back to the primary screen, then the pen, hyperlink,
/// protection, character sets and top/bottom margins. Modes follow, then
/// modifyOtherKeys. The repaint is one synchronized update.
const REFRESH_RESET: &[u8] = concat!(
    "\x18\x1b[?2026h",
    "\x1b[?1049l\x1b[?1047l\x1b[?47l",
    "\x1b[0m\x1b]8;;\x1b\\\x1b[0\"q",
    "\x1b(B\x1b)B\x1b*B\x1b+B\x0f\x1b}\x1b[r",
)
.as_bytes();

/// Insert, origin and left/right margin modes change where frames paint.
fn painting_mode(value: u16, ansi: bool) -> bool {
    matches!((value, ansi), (4, true) | (6, false) | (69, false))
}

fn check(code: i32, operation: &str) -> Result<()> {
    if code != 0 {
        bail!("libghostty-vt {operation} failed ({code})");
    }
    Ok(())
}

extern "C" fn reply(_term: Handle, userdata: *mut c_void, bytes: *const u8, len: usize) {
    // Ghostty invokes this synchronously during a mutating call. The Box's
    // allocation never moves; its lifetime exceeds the terminal's.
    if len != 0 {
        unsafe {
            (&mut *userdata.cast::<Vec<u8>>())
                .extend_from_slice(std::slice::from_raw_parts(bytes, len));
        }
    }
}

extern "C" fn append(userdata: *mut c_void, bytes: *const u8, len: usize) {
    // The shim calls this synchronously with the Vec passed to `emit`.
    if len != 0 {
        unsafe {
            (&mut *userdata.cast::<Vec<u8>>())
                .extend_from_slice(std::slice::from_raw_parts(bytes, len));
        }
    }
}

fn emit(
    out: &mut Vec<u8>,
    operation: &str,
    encode: impl FnOnce(Sink, *mut c_void) -> i32,
) -> Result<()> {
    check(encode(append, (out as *mut Vec<u8>).cast()), operation)
}

/// Owns one terminal. Mutations and callbacks are synchronous. Moving ownership
/// between threads is safe, but concurrent access to the C handle is not.
pub struct Terminal {
    handle: NonNull<c_void>,
    cols: u16,
    rows: u16,
    // C retains the Vec object's address as callback userdata; its backing
    // allocation alone would not keep that address stable when Terminal moves.
    #[allow(clippy::box_collection)]
    replies: Box<Vec<u8>>,
    _not_sync: PhantomData<std::cell::Cell<()>>,
}
unsafe impl Send for Terminal {}

/// Test support: a style-aware description of the active screen. Rows are
/// in screen order with attribute runs in brackets; `↪` marks a soft-wrap
/// continuation and `⏎` a soft-wrapped row.
#[doc(hidden)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Inspection {
    pub alternate: bool,
    pub history: Vec<String>,
    pub active: Vec<String>,
    pub cursor: (u16, u16),
    pub pending_wrap: bool,
    pub modes: Vec<String>,
    /// Tab stops, margins, keyboard mode, pen and character sets as VT.
    pub state: String,
    pub kitty_flags: u8,
}

impl Terminal {
    pub fn new(cols: u16, rows: u16, scrollback: usize) -> Result<Self> {
        ensure!(cols > 0 && rows > 0, "terminal dimensions must be positive");
        let mut replies = Box::new(Vec::new());
        let mut handle = std::ptr::null_mut();
        check(
            unsafe {
                cherry_vt_new(
                    &mut handle,
                    cols,
                    rows,
                    scrollback,
                    (&mut *replies as *mut Vec<u8>).cast(),
                    reply,
                )
            },
            "create",
        )?;
        Ok(Self {
            handle: NonNull::new(handle).expect("successful terminal creation"),
            cols,
            rows,
            replies,
            _not_sync: PhantomData,
        })
    }

    pub fn feed(&mut self, bytes: &[u8]) -> Vec<u8> {
        write(self.handle.as_ptr(), bytes);
        std::mem::take(&mut *self.replies)
    }

    pub fn resize(&mut self, cols: u16, rows: u16) -> Result<Vec<u8>> {
        ensure!(cols > 0 && rows > 0, "terminal dimensions must be positive");
        check(
            unsafe { ghostty_terminal_resize(self.handle.as_ptr(), cols, rows, 8, 16) },
            "resize",
        )?;
        self.cols = cols;
        self.rows = rows;
        Ok(std::mem::take(&mut *self.replies))
    }

    /// The terminfo entry name the program runs under (its TERM), reported
    /// for an XTGETTCAP `TN` query. Without one (the default, or after an
    /// empty name) `TN` goes unanswered. At most 128 bytes.
    pub fn set_terminfo_name(&mut self, name: &str) -> Result<()> {
        check(
            unsafe { cherry_vt_set_terminfo_name(self.handle.as_ptr(), name.as_ptr(), name.len()) },
            "terminfo name",
        )
    }

    /// Repaint the canonical active grid at the upper left of a physical
    /// terminal of another size. Content only: every row is painted at an
    /// absolute position over a cleared line, then the cursor position,
    /// visibility and pen are restored. It sends no reset and no modes, so it
    /// is safe to send after every batch of output; send `modes()` first so
    /// origin, insert mode and character sets are at their defaults. The
    /// frame is bracketed by synchronized output (2026). This is a bounded
    /// view, not a replay of retained scrollback.
    pub fn viewport(&self, physical_cols: u16, physical_rows: u16) -> Result<Vec<u8>> {
        ensure!(
            physical_cols > 0 && physical_rows > 0,
            "viewport dimensions must be positive"
        );
        let handle = self.handle.as_ptr();
        let rows = self.rows.min(physical_rows);
        let cols = self.cols.min(physical_cols);
        let state = info(handle)?;
        // Start from a known pen with no open hyperlink.
        let mut out = b"\x1b[?2026h\x1b[0m\x1b]8;;\x1b\\".to_vec();
        emit(&mut out, "viewport", |sink, userdata| unsafe {
            cherry_vt_paint_rows(handle, rows, cols, sink, userdata)
        })?;
        if physical_rows > rows {
            let _ = write!(out, "\x1b[{};1H\x1b[J", rows + 1);
        }
        let (x, y) = (state.cursor_x, state.cursor_y);
        let _ = write!(out, "\x1b[{};{}H", y.min(rows - 1) + 1, x.min(cols - 1) + 1);
        let visible = state.cursor_visible && x < cols && y < rows;
        out.extend_from_slice(if visible { b"\x1b[?25h" } else { b"\x1b[?25l" });
        emit(&mut out, "pen", |sink, userdata| unsafe {
            cherry_vt_pen(handle, sink, userdata)
        })?;
        out.extend_from_slice(b"\x1b[?2026l");
        Ok(out)
    }

    /// Bytes that make a physical terminal's modes match this terminal for
    /// viewport rendering. Every managed mode is first reset to its default,
    /// then the non-default values are set, so the result does not depend on
    /// the receiver's prior modes. Managed: the alternate screen, input and
    /// display modes, modifyOtherKeys and the current kitty keyboard flags.
    /// Insert, origin and left/right margin modes, margins and character sets
    /// are forced to their defaults because frames paint at absolute
    /// positions. Cursor visibility and synchronized output are left to
    /// `viewport()`, and the reports the host answers (in-band size 2048,
    /// visibility 2033) to the host. Modes whose default comes from the
    /// user's terminal settings (DECARM 8, alternate scroll 1007, Meta and
    /// Alt keys 1035, 1036 and 1039, grapheme clustering 2027) are not reset:
    /// they are set only while the session has them away from libghostty's
    /// default, so a session that never touches them leaves the user's
    /// settings alone. One the session sets back to that default keeps the
    /// value last sent.
    ///
    /// The receiver's primary screen keeps its cursor: the screen switches
    /// come before any reset that homes the cursor, so the cursor that 1049
    /// saves (and restores when the receiver leaves the alternate screen with
    /// `?1049l`, for example on detach) is the one the primary screen showed,
    /// not the home position. Leave with `?1049l` whichever mode the session
    /// entered the alternate screen with: leaving 47 or 1047 keeps the
    /// alternate screen's cursor. Other resets have side effects (switching
    /// screens clears the alternate screen, enabling 1004/2031 makes the
    /// receiver report), so send this only when its output changes and paint
    /// a viewport frame after it, as one synchronized update:
    /// `ESC[?2026h` + `modes()` + `viewport()`, whose closing `ESC[?2026l`
    /// ends it before the receiver shows the screen switch.
    pub fn modes(&self) -> Result<Vec<u8>> {
        let handle = self.handle.as_ptr();
        let state = info(handle)?;
        // Return to the primary screen without moving its cursor, whichever
        // screen the receiver is on. ?1049l restores the cursor 1049 saved
        // even when the receiver is already on the primary screen, and tmux
        // keeps that cursor apart from DECSC, so it can be stale (left by an
        // earlier program). ?1049h first saves the current one, so on the
        // primary screen the pair is a no-op. On the alternate screen
        // ?1049h saves that screen's own cursor (xterm, Ghostty) or does
        // nothing (tmux), and ?1049l returns to the primary cursor saved
        // when the receiver last left the primary screen: by this pair, or
        // by a 1049 entry below.
        let mut out = b"\x1b[?1049h\x1b[?1049l\x1b[?1047l\x1b[?47l".to_vec();
        if state.alternate {
            push_mode(&mut out, alternate_mode(handle)?, false, true);
        }
        for &(value, ansi, default) in MODES {
            if !frame_mode(value, ansi) && !user_default_mode(value, ansi) {
                push_mode(&mut out, value, ansi, default);
            }
        }
        out.extend_from_slice(b"\x1b[r\x1b(B\x1b)B\x1b*B\x1b+B\x0f\x1b[>4m");
        for &(value, ansi, default) in MODES {
            if frame_mode(value, ansi) || painting_mode(value, ansi) {
                continue;
            }
            let on = mode(handle, value, ansi)?;
            if on != default {
                push_mode(&mut out, value, ansi, on);
            }
        }
        out.extend(extras(handle, EXTRA_KEYBOARD)?);
        // Kitty keyboard flags are per screen, so they follow the switch.
        out.extend_from_slice(b"\x1b[<8u");
        if state.kitty_flags != 0 {
            let _ = write!(out, "\x1b[={};1u", state.kitty_flags);
        }
        Ok(out)
    }

    /// VT bytes for a fresh renderer of the same dimensions, beginning with a
    /// reset. Replaying them reproduces every active row at its row with its
    /// styles (including background-only cells and hyperlinks), retained
    /// history in order with soft wraps, the primary screen under an active
    /// alternate screen, modes, tab stops, margins, the cursor (position,
    /// pending wrap, visibility, pen, character sets), each screen's saved
    /// cursor, the kitty keyboard stack and unfinished UTF-8/control
    /// continuations. See the README for what is not carried.
    pub fn snapshot(&self) -> Result<Vec<u8>> {
        self.encode(Replay::Snapshot {
            skip: 0,
            layout: None,
        })
    }

    /// VT bytes that bring a terminal of the same dimensions which already
    /// holds this terminal's history (a renderer that followed its output,
    /// or a fresh one) to this terminal's current screens, cursor and modes,
    /// without a reset and without history: no RIS and no ED 2 or 3, so the
    /// receiver's scrollback is left alone. The screen switch, pen,
    /// hyperlink, protection, character sets, margins, modes (except those
    /// whose default comes from the user's terminal, see `modes()`),
    /// modifyOtherKeys, tab stops, the repainted screens' saved cursors and
    /// the kitty keyboard stacks are put back to their defaults explicitly.
    /// Then each screen's active area is erased line by line and repainted
    /// in place, the primary screen first when an alternate screen is
    /// active, and the rest of the state follows as in `snapshot()`. It is
    /// one synchronized update (2026), which it leaves as the session has
    /// it.
    pub fn refresh(&self) -> Result<Vec<u8>> {
        self.encode(Replay::Refresh)
    }

    /// `snapshot()` limited to `max_bytes`: the oldest history is dropped,
    /// in whole logical lines, until the result fits. When the cut falls
    /// inside a soft-wrapped line, the rest of that line is dropped too, so
    /// the kept history starts with the start of a line; when that line
    /// continues into the active screen, all history is dropped. The active
    /// screen, and the primary screen under an alternate screen, are never
    /// dropped; if they alone exceed the limit this fails.
    pub fn snapshot_limited(&self, max_bytes: usize) -> Result<Vec<u8>> {
        let mut layout = Layout::default();
        let full = self.encode(Replay::Snapshot {
            skip: 0,
            layout: Some(&mut layout),
        })?;
        if full.len() <= max_bytes {
            return Ok(full);
        }
        // offsets[i] is where history row i starts; offsets[history] is the
        // first active row.
        let Layout {
            offsets,
            continuations,
        } = layout;
        let rows = usize::from(self.rows);
        let history = offsets.len().saturating_sub(rows + 1);
        let excess = full.len() - max_bytes;
        // The first history row at or after `skip` that starts a line.
        let line_start = |skip: usize| {
            (skip.min(history)..history)
                .find(|&row| !continuations[row])
                .unwrap_or(history)
        };
        let mut skip = offsets[..=history]
            .partition_point(|offset| offset - offsets[0] < excess)
            .max(1);
        let mut step = 1;
        loop {
            let dropped = line_start(skip);
            let candidate = self.encode(Replay::Snapshot {
                skip: dropped as u64,
                layout: None,
            })?;
            if candidate.len() <= max_bytes {
                return Ok(candidate);
            }
            ensure!(
                dropped < history,
                "the active screen needs a {}-byte snapshot; the limit is {max_bytes} bytes",
                candidate.len()
            );
            skip = dropped + step;
            step *= 2;
        }
    }

    /// Active buffer text including its retained history, for diagnostics/tests.
    pub fn screen_text(&self) -> Result<String> {
        let bytes =
            allocated(|ptr, len| unsafe { cherry_vt_plain(self.handle.as_ptr(), ptr, len) })?;
        Ok(String::from_utf8_lossy(&bytes).into_owned())
    }

    #[doc(hidden)]
    pub fn inspect(&self) -> Result<Inspection> {
        let handle = self.handle.as_ptr();
        let state = info(handle)?;
        let mut rows = Vec::new();
        for y in 0..u32::try_from(state.total_rows)? {
            let mut bytes = Vec::new();
            emit(&mut bytes, "row", |sink, userdata| unsafe {
                cherry_vt_debug_row(handle, y, sink, userdata)
            })?;
            let (mut wrap, mut continuation) = (false, false);
            check(
                unsafe { cherry_vt_row_flags(handle, y, &mut wrap, &mut continuation) },
                "row",
            )?;
            let mut text = String::from_utf8_lossy(&bytes).into_owned();
            loop {
                let trimmed = text.trim_end_matches('·');
                let trimmed = trimmed.strip_suffix("[]").unwrap_or(trimmed).len();
                if trimmed == text.len() {
                    break;
                }
                text.truncate(trimmed);
            }
            if continuation {
                text.insert(0, '↪');
            }
            if wrap {
                text.push('⏎');
            }
            rows.push(text);
        }
        let active = rows.split_off(usize::try_from(state.history_rows)?);
        let mut modes = Vec::new();
        let screens = ALTERNATE_SCREEN_MODES.map(|value| (value, false, false));
        for &(value, ansi, default) in MODES.iter().chain(&screens) {
            let on = mode(handle, value, ansi)?;
            if on != default {
                modes.push(format!(
                    "{}{value}{}",
                    if ansi { "" } else { "?" },
                    if on { 'h' } else { 'l' }
                ));
            }
        }
        let mut extra = Vec::new();
        for kind in [
            EXTRA_TABSTOPS,
            EXTRA_MARGINS,
            EXTRA_KEYBOARD,
            EXTRA_PEN,
            EXTRA_CHARSETS,
        ] {
            extra.extend(extras(handle, kind)?);
        }
        Ok(Inspection {
            alternate: state.alternate,
            history: rows,
            active,
            cursor: (state.cursor_x, state.cursor_y),
            pending_wrap: state.pending_wrap,
            modes,
            state: String::from_utf8_lossy(&extra).replace('\x1b', "␛"),
            kitty_flags: state.kitty_flags,
        })
    }

    fn encode(&self, replay: Replay<'_>) -> Result<Vec<u8>> {
        let handle = self.handle.as_ptr();
        let continuation = allocated(|ptr, len| unsafe {
            ghostty_terminal_continuation_alloc(handle, std::ptr::null(), ptr, len)
        })?;
        let (refresh, skip, layout) = match replay {
            Replay::Snapshot { skip, layout } => (false, skip, layout),
            Replay::Refresh => (true, 0, None),
        };
        let mut out = if refresh {
            let mut out = REFRESH_RESET.to_vec();
            for &(value, ansi, default) in MODES {
                if !user_default_mode(value, ansi) && (value, ansi) != (2026, false) {
                    push_mode(&mut out, value, ansi, default);
                }
            }
            out.extend_from_slice(b"\x1b[>4m");
            out
        } else {
            b"\x18\x1bc".to_vec()
        };
        // Grapheme clustering decides cell widths while content is replayed.
        if mode(handle, 2027, false)? {
            out.extend_from_slice(b"\x1b[?2027h");
        }
        // Kitty keyboard stacks can only be read by popping them, so they
        // are read from a copy, which also provides the primary screen under
        // an alternate screen. CAN ends any unfinished sequence on the copy.
        // Screens keep their stacks while inactive.
        let copy = clone_terminal(handle)?;
        let probe = copy.0.as_ptr();
        write(probe, b"\x18");
        if info(handle)?.alternate {
            let entry = alternate_mode(handle)?;
            write(probe, format!("\x1b[?{entry}l").as_bytes());
            let primary_stack = kitty_stack(probe)?;
            // Leaving 1049 restored the primary cursor it saved, which the
            // receiver's ?1049h saves again; origin mode, which the primary
            // screen is otherwise replayed without, is set for that save
            // (margins are still full, so the cursor stays absolute).
            // Leaving 47 or 1047 copied the alternate screen's cursor over the
            // primary one instead, so the primary screen's own saved cursor is
            // restored on the copy and set up after its content.
            let origin = entry == 1049 && mode(probe, 6, false)?;
            let after_content = if entry != 1049 {
                saved_cursor(probe, probe, refresh)?
            } else if origin {
                b"\x1b[?6h".to_vec()
            } else {
                Vec::new()
            };
            let screen = encode_screen(
                probe,
                Rows::from(refresh, skip, layout),
                false,
                &after_content,
                &primary_stack,
                &mut out,
            )?;
            push_mode(&mut out, entry, false, true);
            if origin {
                push_mode(&mut out, 6, false, false);
            }
            // The alternate screen inherits the primary's character sets,
            // pen and protection; its content is replayed without them.
            out.extend(neutral_charsets(&screen.charsets));
            if screen.protected {
                out.extend_from_slice(b"\x1b[0\"q");
            }
            out.extend_from_slice(b"\x1b[0m\x1b[H");
            write(probe, b"\x1b[?47h");
            let saved = saved_cursor(probe, handle, refresh)?;
            let stack = kitty_stack(probe)?;
            encode_screen(
                handle,
                Rows::from(refresh, 0, None),
                true,
                &saved,
                &stack,
                &mut out,
            )?;
        } else {
            let mut after_content = saved_cursor(probe, handle, refresh)?;
            let stack = kitty_stack(probe)?;
            // An inactive alternate screen's stack is set up on the way. Mode
            // 47 switches without saving the cursor or erasing.
            write(probe, b"\x1b[?47h");
            let inactive = kitty_stack(probe)?;
            if refresh || !inactive.is_empty() {
                after_content.extend_from_slice(b"\x1b[?47h");
                if refresh {
                    after_content.extend_from_slice(KITTY_CLEAR);
                }
                after_content.extend(inactive);
                after_content.extend_from_slice(b"\x1b[?47l");
            }
            encode_screen(
                handle,
                Rows::from(refresh, skip, layout),
                true,
                &after_content,
                &stack,
                &mut out,
            )?;
        }
        out.extend(continuation);
        Ok(out)
    }
}

/// What `Terminal::encode` produces.
enum Replay<'a> {
    /// For a fresh terminal: a reset, then retained history from `skip` and
    /// the active screen as one stream.
    Snapshot {
        skip: u64,
        layout: Option<&'a mut Layout>,
    },
    /// For a terminal of the same size that holds this terminal's history:
    /// state reset explicitly and each screen's active area repainted.
    Refresh,
}

/// Where each row of an encoded screen starts in the snapshot (one entry
/// per row plus the end), and whether it continues a soft-wrapped line.
#[derive(Default)]
struct Layout {
    offsets: Vec<usize>,
    continuations: Vec<bool>,
}

/// The rows of one screen to encode.
enum Rows<'a> {
    /// Streamed from screen row `skip` (history first) for a fresh receiver.
    Stream {
        skip: u64,
        layout: Option<&'a mut Layout>,
    },
    /// The active area, erased and repainted in place.
    Repaint,
}

impl<'a> Rows<'a> {
    fn from(refresh: bool, skip: u64, layout: Option<&'a mut Layout>) -> Self {
        if refresh {
            Rows::Repaint
        } else {
            Rows::Stream { skip, layout }
        }
    }
}

/// Clears a screen's kitty keyboard stack: popping all of its entries.
const KITTY_CLEAR: &[u8] = b"\x1b[<8u";

struct ScreenState {
    charsets: Vec<u8>,
    protected: bool,
}

/// One screen: its rows, then `after_content`, then its cursor.
/// Terminal-wide state (tab stops, modes, margins, keyboard mode) is
/// written only for the `last` screen so an earlier primary screen is
/// replayed under default modes. Content is always replayed under defaults;
/// the pending-wrap glyph is reprinted before character sets are restored
/// and before autowrap may be disabled. `kitty` is the screen's keyboard
/// stack from `kitty_stack`.
fn encode_screen(
    term: Handle,
    rows: Rows<'_>,
    last: bool,
    after_content: &[u8],
    kitty: &[u8],
    out: &mut Vec<u8>,
) -> Result<ScreenState> {
    let state = info(term)?;
    let refresh = matches!(rows, Rows::Repaint);
    let stream = |out: &mut Vec<u8>, first: u64, count: u64, layout: Option<&mut Layout>| {
        let start = out.len();
        match layout {
            Some(layout) => {
                let rows = usize::try_from(count)?;
                let mut offsets = vec![0usize; rows + 1];
                let mut continuations = vec![false; rows];
                emit(out, "content", |sink, userdata| unsafe {
                    cherry_vt_stream_rows(
                        term,
                        first,
                        count,
                        offsets.as_mut_ptr(),
                        continuations.as_mut_ptr(),
                        sink,
                        userdata,
                    )
                })?;
                layout.offsets = offsets.into_iter().map(|offset| start + offset).collect();
                layout.continuations = continuations;
                Ok(())
            }
            None => emit(out, "content", |sink, userdata| unsafe {
                cherry_vt_stream_rows(
                    term,
                    first,
                    count,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    sink,
                    userdata,
                )
            }),
        }
    };
    match rows {
        Rows::Stream { skip, layout } => {
            stream(out, skip, state.total_rows.saturating_sub(skip), layout)?;
        }
        Rows::Repaint => {
            // Erasing whole lines leaves the receiver's history alone; ED 2
            // may scroll the screen into it first. Selecting DEC protection
            // makes the erase ignore ISO (SPA/EPA) protection, which is
            // kept per screen. The rows are then streamed from the top,
            // which scrolls nothing.
            out.extend_from_slice(b"\x1b[1\"q\x1b[0\"q");
            for row in 1..=state.rows {
                let _ = write!(out, "\x1b[{row};1H\x1b[2K");
            }
            out.extend_from_slice(b"\x1b[H");
            stream(out, state.history_rows, u64::from(state.rows), None)?;
        }
    }
    out.extend_from_slice(after_content);
    let mut margins = Vec::new();
    let (mut origin, mut wraparound, mut synchronized) = (false, true, false);
    let mut right = state.cols;
    if last {
        out.extend(extras(term, EXTRA_TABSTOPS)?);
        for &(value, ansi, default) in MODES {
            let on = mode(term, value, ansi)?;
            if on == default || (value, ansi) == (2027, false) {
                continue;
            }
            match (value, ansi) {
                (7, false) => wraparound = on,
                (2026, false) => synchronized = on,
                _ => push_mode(out, value, ansi, on),
            }
        }
        margins = extras(term, EXTRA_MARGINS)?;
        out.extend_from_slice(&margins);
        out.extend(extras(term, EXTRA_KEYBOARD)?);
        origin = mode(term, 6, false)?;
        if mode(term, 69, false)? {
            right = margins_of(&margins, b's').map_or(state.cols, |(_, right)| {
                u16::try_from(right).unwrap_or(state.cols)
            });
        }
    }
    // Margins and origin mode are set, so CUP is origin-relative. An
    // earlier screen is replayed with full margins.
    let offset = if origin {
        (margin(&margins, b'r') - 1, margin(&margins, b's') - 1)
    } else {
        (0, 0)
    };
    // The glyph holding a pending wrap is reprinted only at a wrap edge:
    // the screen edge or, with left/right margins, the right margin.
    // Ghostty keeps a pending wrap when a resize moves the edge away from
    // the cursor; only its position can be restored there.
    let x = state.cursor_x + 1;
    let pending_wrap = state.pending_wrap && (x == state.cols || x == right);
    place_cursor(term, &state, offset, pending_wrap, out)?;
    if !wraparound {
        push_mode(out, 7, false, false);
    }
    let pen = extras(term, EXTRA_PEN)?;
    out.extend_from_slice(&pen);
    let charsets = extras(term, EXTRA_CHARSETS)?;
    out.extend_from_slice(&charsets);
    if refresh {
        out.extend_from_slice(KITTY_CLEAR);
    }
    out.extend_from_slice(kitty);
    if synchronized {
        push_mode(out, 2026, false, true);
    } else if refresh && last {
        push_mode(out, 2026, false, false);
    }
    Ok(ScreenState {
        charsets,
        protected: pen.windows(5).any(|bytes| bytes == b"\x1b[1\"q"),
    })
}

/// CUP to the cursor in `state`, less the origin-mode `offset` (rows,
/// columns), then, for `pending_wrap`, the glyph that holds it reprinted from
/// `cells` (which shows the same screen) because CUP cleared it.
fn place_cursor(
    cells: Handle,
    state: &Info,
    offset: (u32, u32),
    pending_wrap: bool,
    out: &mut Vec<u8>,
) -> Result<()> {
    let (x, y) = (state.cursor_x, state.cursor_y);
    let mut glyph = x;
    if pending_wrap && x > 0 {
        let mut wide = 0;
        check(unsafe { cherry_vt_wide(cells, x, y, &mut wide) }, "cursor")?;
        if wide == WIDE_SPACER_TAIL {
            glyph = x - 1;
        }
    }
    let row = (u32::from(y) + 1).saturating_sub(offset.0).max(1);
    let col = (u32::from(glyph) + 1).saturating_sub(offset.1).max(1);
    let _ = write!(out, "\x1b[{row};{col}H");
    if pending_wrap {
        emit(out, "pending wrap", |sink, userdata| unsafe {
            cherry_vt_paint_cells(cells, y, glyph, x + 1, sink, userdata)
        })?;
    }
    Ok(())
}

/// The saved cursor (DECSC) of the screen `probe` shows, restored on
/// `probe` (which it changes), as bytes for a receiver that has just
/// replayed that screen's content under default modes and full margins:
/// origin mode, the position (with a pending wrap at the screen edge
/// reprinted from `cells`, which shows the same screen), pen, protection
/// and character sets are set up, DECSC saves them, and they are put back
/// to defaults. When the saved cursor is the default that restoring on a
/// screen without one gives, it is empty, or for an `explicit` receiver
/// (one that may hold a saved cursor already) that default saved at home.
fn saved_cursor(probe: Handle, cells: Handle, explicit: bool) -> Result<Vec<u8>> {
    write(probe, b"\x1b8");
    let state = info(probe)?;
    let origin = mode(probe, 6, false)?;
    let pen = extras(probe, EXTRA_STYLE)?;
    let charsets = extras(probe, EXTRA_CHARSETS)?;
    // A pending wrap at a right margin inside the screen needs that
    // margin, which the receiver does not have yet.
    let pending_wrap = state.pending_wrap && state.cursor_x + 1 == state.cols;
    if (state.cursor_x, state.cursor_y) == (0, 0)
        && !pending_wrap
        && !origin
        && pen == b"\x1b[0m"
        && charsets.is_empty()
    {
        return Ok(if explicit {
            b"\x1b[H\x1b7".to_vec()
        } else {
            Vec::new()
        });
    }
    let mut out = Vec::new();
    if origin {
        push_mode(&mut out, 6, false, true);
    }
    place_cursor(cells, &state, (0, 0), pending_wrap, &mut out)?;
    out.extend_from_slice(&pen);
    out.extend_from_slice(&charsets);
    out.extend_from_slice(b"\x1b7");
    if origin {
        push_mode(&mut out, 6, false, false);
    }
    out.extend_from_slice(b"\x1b[0m");
    if pen.windows(5).any(|bytes| bytes == b"\x1b[1\"q") {
        out.extend_from_slice(b"\x1b[0\"q");
    }
    out.extend(neutral_charsets(&charsets));
    Ok(out)
}

/// The active screen's kitty keyboard stack as a set of the deepest non-zero
/// entry followed by pushes, so later pops on the receiver return the same
/// flags; empty when every entry is 0. Ghostty keeps eight entries and
/// exposes only the current one, so this pops all of them off `probe`.
fn kitty_stack(probe: Handle) -> Result<Vec<u8>> {
    let mut entries = [0u8; 8];
    for entry in &mut entries {
        *entry = info(probe)?.kitty_flags;
        write(probe, b"\x1b[<u");
    }
    let mut out = Vec::new();
    if let Some(deepest) = entries.iter().rposition(|&flags| flags != 0) {
        let _ = write!(out, "\x1b[={};1u", entries[deepest]);
        for flags in entries[..deepest].iter().rev() {
            let _ = write!(out, "\x1b[>{flags}u");
        }
    }
    Ok(out)
}

/// Designate ASCII into every slot the given character-set restore changed
/// and invoke G0 into GL and G2 into GR again. Ghostty has no designation
/// back to its UTF-8 default, but ASCII prints identically.
fn neutral_charsets(charsets: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    let (mut left, mut right) = (false, false);
    let mut i = 0;
    while i < charsets.len() {
        match (charsets[i], charsets.get(i + 1)) {
            (0x1b, Some(&slot @ (b'(' | b')' | b'*' | b'+'))) => {
                out.extend_from_slice(&[0x1b, slot, b'B']);
                i += 3;
            }
            (0x1b, Some(b'n' | b'o')) => {
                left = true;
                i += 2;
            }
            (0x1b, Some(b'~' | b'|')) => {
                right = true;
                i += 2;
            }
            (0x0e, _) => {
                left = true;
                i += 1;
            }
            _ => i += 1,
        }
    }
    if left {
        out.push(0x0f);
    }
    if right {
        out.extend_from_slice(b"\x1b}");
    }
    out
}

fn push_mode(out: &mut Vec<u8>, value: u16, ansi: bool, on: bool) {
    let _ = write!(
        out,
        "\x1b[{}{value}{}",
        if ansi { "" } else { "?" },
        if on { 'h' } else { 'l' }
    );
}

fn write(term: Handle, bytes: &[u8]) {
    unsafe {
        ghostty_terminal_vt_write(term, bytes.as_ptr(), bytes.len());
    }
}

fn info(term: Handle) -> Result<Info> {
    let mut info = Info::default();
    check(unsafe { cherry_vt_info(term, &mut info) }, "state")?;
    Ok(info)
}

fn mode(term: Handle, value: u16, ansi: bool) -> Result<bool> {
    let mut on = false;
    check(
        unsafe { cherry_vt_mode(term, value, ansi, &mut on) },
        "mode",
    )?;
    Ok(on)
}

/// The mode that entered the alternate screen, so leaving and re-entering it
/// keeps that mode's cursor semantics.
fn alternate_mode(term: Handle) -> Result<u16> {
    for value in ALTERNATE_SCREEN_MODES {
        if mode(term, value, false)? {
            return Ok(value);
        }
    }
    Ok(1049)
}

fn extras(term: Handle, kind: i32) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    emit(&mut out, "state export", |sink, userdata| unsafe {
        cherry_vt_extras(term, kind, sink, userdata)
    })?;
    Ok(out)
}

fn clone_terminal(term: Handle) -> Result<OwnedHandle> {
    let mut cloned = std::ptr::null_mut();
    check(unsafe { cherry_vt_clone(term, &mut cloned) }, "clone")?;
    Ok(OwnedHandle(NonNull::new(cloned).expect("successful clone")))
}

fn allocated(f: impl FnOnce(*mut *mut u8, *mut usize) -> i32) -> Result<Vec<u8>> {
    let mut bytes = std::ptr::null_mut();
    let mut len = 0;
    let code = f(&mut bytes, &mut len);
    let out = if code == 0 && len > 0 {
        unsafe { std::slice::from_raw_parts(bytes, len).to_vec() }
    } else {
        Vec::new()
    };
    unsafe {
        ghostty_free(std::ptr::null(), bytes.cast(), len);
    }
    check(code, "export")?;
    Ok(out)
}

/// First parameter of the last `CSI Pn ; Pn <final_byte>` in bytes, or 1.
fn margin(bytes: &[u8], final_byte: u8) -> u32 {
    margins_of(bytes, final_byte).map_or(1, |(first, _)| first)
}

/// Both parameters of the last `CSI Pn ; Pn <final_byte>` in bytes (at
/// least 1 each), as the upstream formatter writes margins.
fn margins_of(bytes: &[u8], final_byte: u8) -> Option<(u32, u32)> {
    let mut last = None;
    for chunk in bytes.split(|&b| b == 0x1b) {
        if let Some(body) = chunk.strip_prefix(b"[") {
            let end = body
                .iter()
                .position(|b| !b.is_ascii_digit() && *b != b';')
                .unwrap_or(body.len());
            if body.get(end) == Some(&final_byte) {
                let mut params = body[..end].split(|&b| b == b';').map(|param| {
                    std::str::from_utf8(param)
                        .ok()
                        .and_then(|param| param.parse::<u32>().ok())
                        .unwrap_or(1)
                        .max(1)
                });
                if let (Some(first), Some(second)) = (params.next(), params.next()) {
                    last = Some((first, second));
                }
            }
        }
    }
    last
}

struct OwnedHandle(NonNull<c_void>);
impl Drop for OwnedHandle {
    fn drop(&mut self) {
        unsafe {
            ghostty_terminal_free(self.0.as_ptr());
        }
    }
}
impl Drop for Terminal {
    fn drop(&mut self) {
        unsafe {
            ghostty_terminal_free(self.handle.as_ptr());
        }
    }
}

#[cfg(test)]
mod tests;
