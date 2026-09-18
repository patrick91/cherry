//! Headless Ghostty terminal state. The host owns query replies; a frontend
//! must filter answered queries from its display stream to avoid duplicate input.
use anyhow::{bail, ensure, Result};
use std::{ffi::c_void, marker::PhantomData, ptr::NonNull};

type Handle = *mut c_void;
unsafe extern "C" {
    fn cherry_vt_new(
        out: *mut Handle,
        cols: u16,
        rows: u16,
        scrollback: usize,
        userdata: *mut c_void,
        reply: extern "C" fn(Handle, *mut c_void, *const u8, usize),
    ) -> i32;
    fn cherry_vt_format(term: Handle, plain: bool, out: *mut *mut u8, len: *mut usize) -> i32;
    fn cherry_vt_viewport_row(
        term: Handle,
        row: u16,
        width: u16,
        extras: bool,
        out: *mut *mut u8,
        len: *mut usize,
    ) -> i32;
    fn cherry_vt_alternate(term: Handle, alternate: *mut bool) -> i32;
    fn cherry_vt_cursor(term: Handle, x: *mut u16, y: *mut u16, origin: *mut bool) -> i32;
    fn cherry_vt_clone(term: Handle, out: *mut Handle) -> i32;
    fn cherry_vt_pending_tail(
        term: Handle,
        out: *mut *mut u8,
        len: *mut usize,
        rewind: *mut u16,
    ) -> i32;
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
        unsafe {
            ghostty_terminal_vt_write(self.handle.as_ptr(), bytes.as_ptr(), bytes.len());
        }
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

    /// Paint the canonical active grid at the upper left of a physical terminal
    /// with another size. Each row has an absolute position, so soft wraps never
    /// reflow. This is a bounded view, not a replay of retained scrollback; live
    /// output must continue to be parsed by this Terminal, then painted again.
    pub fn viewport(&self, physical_cols: u16, physical_rows: u16) -> Result<Vec<u8>> {
        ensure!(
            physical_cols > 0 && physical_rows > 0,
            "viewport dimensions must be positive"
        );
        let rows = self.rows.min(physical_rows);
        let cols = self.cols.min(physical_cols);
        let mut out = b"\x18\x1bc\x1b[?2026h".to_vec();
        let mut alternate = false;
        check(
            unsafe { cherry_vt_alternate(self.handle.as_ptr(), &mut alternate) },
            "screen",
        )?;
        if alternate {
            out.extend_from_slice(b"\x1b[?1049h");
        }
        // The physical renderer only paints frames. Workload origin, character
        // sets and insertion modes belong to the canonical terminal instead.
        out.extend_from_slice(b"\x1b[?6l\x1b[4l\x1b(B\x1b)B\x0f\x1b[2J");
        for row in 0..rows {
            out.extend_from_slice(
                format!(
                    "\x1b[?6l\x1b[4l\x1b(B\x1b)B\x0f\x1b[0m\x1b]8;;\x1b\\\x1b[{};1H",
                    row + 1
                )
                .as_bytes(),
            );
            let line = allocated(|ptr, len| unsafe {
                cherry_vt_viewport_row(self.handle.as_ptr(), row, cols, row == 0, ptr, len)
            })?;
            out.extend(line);
        }
        let (mut x, mut y, mut origin) = (0, 0, false);
        check(
            unsafe { cherry_vt_cursor(self.handle.as_ptr(), &mut x, &mut y, &mut origin) },
            "cursor",
        )?;
        // This renderer never interprets workload output directly. Its margins
        // and origin can remain physical while keyboard modes mirror the host.
        out.extend_from_slice(
            format!(
                "\x1b[?6l\x1b[{};{}H",
                y.min(rows - 1) + 1,
                x.min(cols - 1) + 1
            )
            .as_bytes(),
        );
        if x >= cols || y >= rows {
            out.extend_from_slice(b"\x1b[?25l");
        }
        out.extend_from_slice(b"\x1b[?2026l");
        // The PTY host owns resize reporting. A renderer enabling this mode
        // would otherwise send a duplicate report back through keyboard input.
        for control in [
            b"\x1b[?2048h".as_slice(),
            b"\x1b[?3h",
            b"\x1b[?3l",
            b"\x1b[?40h",
        ] {
            while let Some(start) = out
                .windows(control.len())
                .position(|bytes| bytes == control)
            {
                out.drain(start..start + control.len());
            }
        }
        Ok(out)
    }

    /// VT bytes for a fresh renderer of the same dimensions. Preserves the
    /// primary screen under an active alternate screen (e.g. Neovim). Graphics,
    /// saved cursors other than the normal 1049 transition, cursor shape and the
    /// inactive alternate buffer are not yet transported. No raw-tail fallback.
    pub fn snapshot(&self) -> Result<Vec<u8>> {
        let continuation = allocated(|ptr, len| unsafe {
            ghostty_terminal_continuation_alloc(self.handle.as_ptr(), std::ptr::null(), ptr, len)
        })?;
        let mut alternate = false;
        check(
            unsafe { cherry_vt_alternate(self.handle.as_ptr(), &mut alternate) },
            "screen",
        )?;
        let mut result = b"\x18\x1bc".to_vec();
        if alternate {
            let mut cloned = std::ptr::null_mut();
            check(
                unsafe { cherry_vt_clone(self.handle.as_ptr(), &mut cloned) },
                "clone",
            )?;
            let cloned = OwnedHandle(NonNull::new(cloned).expect("successful clone"));
            let leave = b"\x18\x1b[?1049l";
            unsafe {
                ghostty_terminal_vt_write(cloned.0.as_ptr(), leave.as_ptr(), leave.len());
            }
            result.extend(format_vt(cloned.0.as_ptr())?);
            result.extend_from_slice(b"\x1b[?1049h");
        }
        result.extend(format_vt(self.handle.as_ptr())?);
        result.extend(continuation);
        Ok(result)
    }

    /// Active buffer text including its retained history, for diagnostics/tests.
    pub fn screen_text(&self) -> Result<String> {
        let bytes = allocated(|ptr, len| unsafe {
            cherry_vt_format(self.handle.as_ptr(), true, ptr, len)
        })?;
        Ok(String::from_utf8_lossy(&bytes).into_owned())
    }
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

fn format_vt(handle: Handle) -> Result<Vec<u8>> {
    let mut out = allocated(|ptr, len| unsafe { cherry_vt_format(handle, false, ptr, len) })?;
    // Formatter extras may move the cursor while setting margins/tab stops.
    // Restore it last, accounting for CUP's origin-relative coordinates.
    let (mut x, mut y, mut origin) = (0, 0, false);
    check(
        unsafe { cherry_vt_cursor(handle, &mut x, &mut y, &mut origin) },
        "cursor",
    )?;
    let (mut col, mut row) = (u32::from(x) + 1, u32::from(y) + 1);
    if origin {
        row = row.saturating_sub(margin(&out, b'r') - 1).max(1);
        col = col.saturating_sub(margin(&out, b's') - 1).max(1);
    }
    out.extend_from_slice(format!("\x1b[{row};{col}H").as_bytes());
    let mut rewind = 0;
    let tail =
        allocated(|ptr, len| unsafe { cherry_vt_pending_tail(handle, ptr, len, &mut rewind) })?;
    if rewind > 0 {
        out.extend_from_slice(format!("\x1b[{rewind}D").as_bytes());
    }
    out.extend(tail);
    Ok(out)
}

fn margin(bytes: &[u8], final_byte: u8) -> u32 {
    let mut last = 1;
    for chunk in bytes.split(|&b| b == 0x1b) {
        if let Some(body) = chunk.strip_prefix(b"[") {
            let end = body
                .iter()
                .position(|b| !b.is_ascii_digit() && *b != b';')
                .unwrap_or(body.len());
            if body.get(end) == Some(&final_byte) {
                if let Ok(value) = std::str::from_utf8(
                    body[..end].split(|&b| b == b';').next().unwrap_or_default(),
                )
                .unwrap_or("")
                .parse::<u32>()
                {
                    last = value.max(1);
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
mod tests {
    use super::*;
    fn term(cols: u16, rows: u16) -> Terminal {
        Terminal::new(cols, rows, 1024 * 1024).unwrap()
    }
    fn restored(source: &Terminal, cols: u16, rows: u16) -> Terminal {
        let mut result = term(cols, rows);
        result.feed(&source.snapshot().unwrap());
        result
    }
    #[test]
    fn viewport_preserves_soft_wrap_positions_on_larger_screen() {
        let mut source = term(8, 4);
        source.feed(b"abcdefghijklmnopQ\x1b[2;3H\x1b[?1h\x1b[>1u");
        let mut display = term(16, 8);
        display.feed(b"stale content\x1b[8;1HOLD BOTTOM");
        display.feed(&source.viewport(16, 8).unwrap());
        let lines = display.screen_text().unwrap();
        assert_eq!(
            lines.lines().take(3).collect::<Vec<_>>(),
            ["abcdefgh", "ijklmnop", "Q"]
        );
        assert!(!lines.contains("stale"));
        assert!(!lines.contains("BOTTOM"));
        assert_eq!(display.feed(b"\x1b[6n"), b"\x1b[2;3R");
        assert_eq!(display.feed(b"\x1b[?1$p"), source.feed(b"\x1b[?1$p"));
        assert_eq!(display.feed(b"\x1b[?u"), source.feed(b"\x1b[?u"));
    }

    #[test]
    fn viewport_crops_resizing_screen_without_wrapping_wide_cells() {
        let mut source = term(8, 4);
        source.feed("abcdef🍒\r\nNEXTLINE\r\nBOTTOM".as_bytes());
        let mut display = term(7, 2);
        display.feed(&source.viewport(7, 2).unwrap());
        assert_eq!(
            display.screen_text().unwrap().lines().collect::<Vec<_>>(),
            ["abcdef", "NEXTLIN"]
        );
        assert_eq!(display.feed(b"\x1b[?25$p"), b"\x1b[?25;2$y");
    }

    #[test]
    fn viewport_paints_only_active_screen_and_updates_from_canonical_state() {
        let mut source = term(8, 3);
        source.feed(b"old1\r\nold2\r\nold3\r\nprimary\x1b[?1049h\x1b[2J\x1b[Heditor");
        let mut display = term(16, 6);
        display.feed(&source.viewport(16, 6).unwrap());
        assert!(
            display.screen_text().unwrap().starts_with("editor"),
            "screen={:?}, frame={:?}",
            display.screen_text(),
            String::from_utf8_lossy(&source.viewport(16, 6).unwrap())
        );
        assert!(!display.screen_text().unwrap().contains("old"));
        source.feed(b"\x1b[?1049l\r\nresumed");
        display.feed(&source.viewport(16, 6).unwrap());
        let text = display.screen_text().unwrap();
        assert!(text.contains("primary"));
        assert!(text.contains("resumed"));
        assert!(!text.contains("editor"));
    }
    #[test]
    fn responds_to_queries_when_detached() {
        let mut t = term(80, 24);
        assert_eq!(t.feed(b"hello\x1b[6n"), b"\x1b[1;6R");
        assert!(!t.feed(b"\x1b[c").is_empty());
        assert_eq!(t.feed(b"\x1b[5n"), b"\x1b[0n");
    }
    #[test]
    fn snapshot_preserves_neovim_style_alternate_and_primary_screen() {
        let mut original = term(80, 24);
        original.feed(b"shell prompt> \x1b[?1049h\x1b[?1h\x1b[?1002h\x1b[?1006h\x1b[?2004h\x1b[2J\x1b[H\x1b[38;2;100;150;200mHello from Neovim\x1b[9;4H");
        let mut copy = restored(&original, 80, 24);
        assert_eq!(original.screen_text().unwrap(), copy.screen_text().unwrap());
        assert_eq!(original.feed(b"\x1b[6n"), copy.feed(b"\x1b[6n"));
        for query in [b"\x1b[?1$p".as_slice(), b"\x1b[?1002$p", b"\x1b[?2004$p"] {
            assert_eq!(original.feed(query), copy.feed(query));
        }
        original.feed(b"\x1b[?1049lAfter quit");
        copy.feed(b"\x1b[?1049lAfter quit");
        assert_eq!(original.screen_text().unwrap(), copy.screen_text().unwrap());
        assert!(copy
            .screen_text()
            .unwrap()
            .contains("shell prompt> After quit"));
    }
    #[test]
    fn reconnect_across_partial_escape_and_utf8() {
        for (prefix, suffix) in [
            (b"abc\x1b[38;2;".as_slice(), b"1;2;3mDEF".as_slice()),
            (b"hello \xf0\x9f".as_slice(), b"\x8d\x92!".as_slice()),
            (
                b"\x1b[?1049h\x1b[2Jabc\x1b[".as_slice(),
                b"7;9Hnext".as_slice(),
            ),
        ] {
            let mut original = term(80, 24);
            original.feed(prefix);
            let mut copy = restored(&original, 80, 24);
            original.feed(suffix);
            copy.feed(suffix);
            assert_eq!(original.screen_text().unwrap(), copy.screen_text().unwrap());
        }
    }
    #[test]
    fn resized_unicode_and_scrollback_survive_snapshot() {
        let mut original = term(20, 4);
        for _ in 0..10 {
            original.feed("one 界 🍒\r\n".as_bytes());
        }
        original.resize(40, 8).unwrap();
        let copy = restored(&original, 40, 8);
        assert_eq!(original.screen_text().unwrap(), copy.screen_text().unwrap());
    }
    #[test]
    fn origin_mode_cursor_is_restored_after_margins() {
        let mut original = term(40, 10);
        original.feed(b"\x1b[3;8r\x1b[?6h\x1b[2;4Htext");
        let mut copy = restored(&original, 40, 10);
        assert_eq!(original.feed(b"\x1b[6n"), copy.feed(b"\x1b[6n"));
    }
    #[test]
    fn rejects_empty_grid() {
        assert!(Terminal::new(0, 24, 100).is_err());
        assert!(term(80, 24).resize(80, 0).is_err());
    }
    #[test]
    fn pending_wrap_survives_reconnect_with_styles_and_wide_cells() {
        for line in ["0123456789", "01234567界", "012345678 "] {
            let mut original = term(10, 4);
            original.feed(b"\x1b[31m");
            original.feed(line.as_bytes());
            original.feed(b"\x1b[32m");
            let mut copy = restored(&original, 10, 4);
            original.feed(b"NEXT");
            copy.feed(b"NEXT");
            assert_eq!(original.screen_text().unwrap(), copy.screen_text().unwrap());
            assert_eq!(original.snapshot().unwrap(), copy.snapshot().unwrap());
        }
    }
}
