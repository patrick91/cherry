//! What a session's terminal shows, read without changing it: the screen as
//! text (`Screen`), and the terminal state clients follow in `SessionInfo`
//! (the alternate screen, the kitty keyboard flags and application cursor
//! keys).
use anyhow::{bail, Result};
use cherry_protocol::MAX_SCREEN_TEXT_BYTES;
use cherry_vt::Terminal;

/// A screen as text (see `cherry_protocol::ServerMessage::ScreenText`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScreenText {
    pub text: String,
    pub cursor_row: u16,
    pub cursor_col: u16,
    pub alternate_screen: bool,
}

/// The terminal state clients follow in `SessionInfo`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TerminalState {
    /// Whether the alternate screen shows.
    pub alternate_screen: bool,
    /// The active screen's kitty keyboard flags.
    pub kitty_keyboard_flags: u32,
    /// DECCKM (mode `?1`): in legacy key encoding (no kitty keyboard
    /// flags), cursor keys send `ESC O x` rather than `ESC [ x`.
    pub application_cursor_keys: bool,
}

/// What `terminal` has of the state clients follow; None if it cannot be
/// read.
///
/// cherry-vt has no accessor for the alternate screen and the kitty
/// keyboard flags, but `Terminal::modes` sets both up in a fixed shape: it
/// returns to the primary screen with
/// `ESC[?1049h ESC[?1049l ESC[?1047l ESC[?47l`, sets the mode that entered
/// the alternate screen right after that when it is active, and ends by
/// popping every kitty keyboard entry (`ESC[<8u`) and, when the flags are
/// not 0, setting them (`ESC[=<flags>;1u`). DECCKM is read as a mode. It is
/// cheap (a few microseconds), and read only after output that holds an
/// escape sequence, since nothing else changes any of them (DECCKM changes
/// with `CSI ? 1 h` / `l` and resets). A test pins the shape against
/// `Terminal::inspect`.
pub fn terminal_state(terminal: &Terminal) -> Option<TerminalState> {
    let (alternate_screen, kitty_keyboard_flags) = parse_terminal_state(&terminal.modes().ok()?)?;
    Some(TerminalState {
        alternate_screen,
        kitty_keyboard_flags,
        application_cursor_keys: terminal.mode(1, false).ok()?,
    })
}

fn parse_terminal_state(modes: &[u8]) -> Option<(bool, u32)> {
    const PRIMARY: &[u8] = b"\x1b[?1049h\x1b[?1049l\x1b[?1047l\x1b[?47l";
    const ALTERNATE: [&[u8]; 3] = [b"\x1b[?1049h", b"\x1b[?1047h", b"\x1b[?47h"];
    const POP: &[u8] = b"\x1b[<8u";
    let rest = modes.strip_prefix(PRIMARY)?;
    let alternate = ALTERNATE.iter().any(|entry| rest.starts_with(entry));
    let popped = rest.windows(POP.len()).rposition(|window| window == POP)? + POP.len();
    let flags = match &rest[popped..] {
        [] => 0,
        set => {
            let digits = set.strip_prefix(b"\x1b[=")?.strip_suffix(b";1u")?;
            std::str::from_utf8(digits).ok()?.parse().ok()?
        }
    };
    Some((alternate, flags))
}

/// How many lines `text` has: one more than its line ends (an empty text
/// is one empty line).
pub fn line_count(text: &str) -> usize {
    text.bytes().filter(|&byte| byte == b'\n').count() + 1
}

/// Keep the last `max` bytes of `text`, whole lines. Returns how many
/// lines it dropped.
pub fn keep_last(text: &mut String, max: usize) -> usize {
    if text.len() <= max {
        return 0;
    }
    let mut cut = text.len() - max;
    while !text.is_char_boundary(cut) {
        cut += 1;
    }
    if text.as_bytes()[cut - 1] != b'\n' {
        if let Some(newline) = text[cut..].find('\n') {
            cut += newline + 1;
        }
    }
    let dropped = text[..cut].bytes().filter(|&byte| byte == b'\n').count();
    text.drain(..cut);
    dropped
}

/// Keep the last `lines` lines of `text` (none: empty). Returns how many
/// lines it dropped.
pub fn keep_last_lines(text: &mut String, lines: usize) -> usize {
    let count = line_count(text);
    if lines == 0 {
        text.clear();
        return count;
    }
    if count <= lines {
        return 0;
    }
    let dropped = count - lines;
    let cut = text
        .match_indices('\n')
        .nth(dropped - 1)
        .map_or(text.len(), |(at, _)| at + 1);
    text.drain(..cut);
    dropped
}

/// How much history a session's terminal keeps (libghostty's page memory).
pub const SCROLLBACK_BYTES: usize = 1024 * 1024;

/// `terminal`'s screen as text: its history first when `scrollback`, only
/// the last `max_lines` lines when that is set, and at most
/// `MAX_SCREEN_TEXT_BYTES` (the oldest lines dropped). `terminal` is
/// `cols` by `rows` and keeps at most `SCROLLBACK_BYTES` of history. The
/// cursor is on the active screen; with `max_lines` its row is the line of
/// the text that holds it instead.
pub fn read(
    terminal: &Terminal,
    cols: u16,
    rows: u16,
    scrollback: bool,
    max_lines: Option<u32>,
) -> Result<ScreenText> {
    // A copy of the screens alone: its text is the screen's, and it shows
    // where the cursor is.
    let mut screens = Terminal::new(cols, rows, 64 * 1024)?;
    screens.feed(&terminal.refresh()?);
    let inspection = screens.inspect()?;
    let (cursor_col, cursor_row) = inspection.cursor;
    let alternate_screen = inspection.alternate;
    let visible = screens.screen_text()?;
    let Some(max_lines) = max_lines else {
        let mut text = if scrollback {
            terminal.screen_text()?
        } else {
            visible
        };
        keep_last(&mut text, MAX_SCREEN_TEXT_BYTES);
        return Ok(ScreenText {
            text,
            cursor_row,
            cursor_col,
            alternate_screen,
        });
    };
    let max_lines = usize::try_from(max_lines).unwrap_or(usize::MAX);
    if max_lines == 0 {
        return Ok(ScreenText {
            text: String::new(),
            cursor_row: 0,
            cursor_col,
            alternate_screen,
        });
    }
    // The alternate screen has no history.
    let history = scrollback && !alternate_screen;
    // The text, and the line of it that holds the cursor (at or after its
    // line count when blank rows after the text hold it).
    let (mut text, line) = if history && visible.is_empty() {
        // A blank screen adds no lines to the text with history, which
        // ends at the last line of history that is not blank, so the
        // cursor is found in a copy of the whole terminal. (Rare, and
        // bounded by the history a session keeps.)
        let mut copy = Terminal::new(cols, rows, 4 * SCROLLBACK_BYTES)?;
        copy.feed(&terminal.snapshot()?);
        let text = copy.screen_text()?;
        let line = cursor_line(&mut copy, &text, cursor_col, cursor_row)?;
        (text, line)
    } else {
        let line = cursor_line(&mut screens, &visible, cursor_col, cursor_row)?;
        let visible_lines = line_count(&visible);
        // The last lines of the text with history are the screen's, all
        // but its first line, which may continue a line of history: with
        // fewer lines asked for than the screen has, its text is enough.
        if history && max_lines >= visible_lines {
            // Counted from the end, the cursor's line is the same in the
            // screen's text and in the text with history: the lines below
            // it are the screen's either way, trimmed alike, since the
            // screen is not blank.
            let text = terminal.screen_text()?;
            let line = (line_count(&text) + line).saturating_sub(visible_lines);
            (text, line)
        } else {
            (visible, line)
        }
    };
    let dropped =
        keep_last_lines(&mut text, max_lines) + keep_last(&mut text, MAX_SCREEN_TEXT_BYTES);
    Ok(ScreenText {
        text,
        cursor_row: u16::try_from(line.saturating_sub(dropped)).unwrap_or(u16::MAX),
        cursor_col,
        alternate_screen,
    })
}

/// The line of `text`, the screen text of `copy`, that holds the cursor at
/// (`x`, `y`) on the active screen: `copy` gets a mark in the cursor's cell
/// (so it changes), and the mark shows where that cell lands in the text,
/// whatever soft wraps, trimmed blanks or wide characters come before it.
/// Everything before the cursor's cell reads the same with the mark, so
/// the texts differ first at the mark or at blanks that come before it
/// (trimmed away without it, or the other half of a wide character it
/// replaced): the mark is the first one from there.
fn cursor_line(copy: &mut Terminal, text: &str, x: u16, y: u16) -> Result<usize> {
    // Private-use characters, one cell wide, that no character set maps:
    // the second in case the cell holds the first.
    for mark in ['\u{e000}', '\u{e001}'] {
        // Written in place, whatever the program set up: no insert mode,
        // no origin mode or margins to position against, and the cursor
        // placement clears a pending wrap, so the mark never wraps or
        // scrolls. CAN ends anything unfinished.
        let write = format!(
            "\x18\x1b[4l\x1b[?69l\x1b[?6l\x1b[r\x1b[{};{}H{mark}",
            u32::from(y) + 1,
            u32::from(x) + 1
        );
        copy.feed(write.as_bytes());
        let marked = copy.screen_text()?;
        let mut same = text
            .bytes()
            .zip(marked.bytes())
            .take_while(|(a, b)| a == b)
            .count();
        if same == text.len() && same == marked.len() {
            continue;
        }
        while !marked.is_char_boundary(same) {
            same -= 1;
        }
        if let Some(at) = marked[same..].find(mark) {
            return Ok(line_count(&marked[..same + at]) - 1);
        }
    }
    bail!("the cursor's cell could not be found in the screen text")
}

/// Limit a screen text that a holder older than link version 3 sent in full
/// (it knows nothing of `max_lines`) to its last `max_lines` lines. Its
/// `cursor_row` is the cursor's row on the screen: the line holding it is
/// estimated as if each screen row were one line and, with the history
/// (`history`), as if the screen's last row ended the text. Returns the
/// cursor's row counted from the first line kept.
pub fn limit_whole(
    text: &mut String,
    cursor_row: u16,
    rows: u16,
    history: bool,
    max_lines: u32,
) -> u16 {
    let lines = line_count(text) as i64;
    let cursor = if history {
        (lines - i64::from(rows) + i64::from(cursor_row)).max(0)
    } else {
        i64::from(cursor_row)
    };
    let dropped = keep_last_lines(text, usize::try_from(max_lines).unwrap_or(usize::MAX));
    let dropped = dropped + keep_last(text, MAX_SCREEN_TEXT_BYTES);
    (cursor - dropped as i64).clamp(0, i64::from(u16::MAX)) as u16
}

#[cfg(test)]
mod tests {
    use super::*;

    fn terminal(cols: u16, rows: u16, output: &[u8]) -> Terminal {
        let mut terminal = Terminal::new(cols, rows, 1024 * 1024).unwrap();
        terminal.feed(output);
        terminal
    }

    #[test]
    fn the_terminal_state_matches_what_the_terminal_holds() {
        for output in [
            &b""[..],
            b"\x1b[?1049h",
            b"\x1b[?1047h",
            b"\x1b[?47h",
            b"\x1b[?1049h\x1b[?1049l",
            b"\x1b[>1u",
            b"\x1b[>31u",
            b"\x1b[>5u\x1b[>7u\x1b[<u",
            b"\x1b[>5u\x1b[<u",
            b"\x1b[=9;1u",
            b"\x1b[=9;1u\x1b[=2;2u",
            b"\x1b[=15;1u\x1b[=4;3u",
            // Each screen has its own flags.
            b"\x1b[>3u\x1b[?1049h",
            b"\x1b[>3u\x1b[?1049h\x1b[>12u",
            b"\x1b[>3u\x1b[?1049h\x1b[>12u\x1b[?1049l",
            b"\x1b[?1049h\x1b[>1u\x1b[?1049l\x1b[?1049h",
            // A reset leaves both.
            b"\x1b[?1049h\x1b[>1u\x1bc",
            b"\x1b[?6h\x1b[?69h\x1b[2;3s\x1b[?1047h\x1b[>8u",
            // Application cursor keys, whichever screen shows.
            b"\x1b[?1h",
            b"\x1b[?1h\x1b[?1l",
            b"\x1b[?1h\x1b[?1049h\x1b[>5u",
            b"\x1b[?1049h\x1b[?1h\x1b[?1049l",
            b"\x1b[?1h\x1b[?1000h\x1b[?1l",
            // Resets.
            b"\x1b[?1h\x1bc",
            b"\x1b[?1h\x1b[!p",
        ] {
            let terminal = terminal(20, 5, output);
            let inspection = terminal.inspect().unwrap();
            assert_eq!(
                terminal_state(&terminal),
                Some(TerminalState {
                    alternate_screen: inspection.alternate,
                    kitty_keyboard_flags: u32::from(inspection.kitty_flags),
                    application_cursor_keys: inspection.modes.iter().any(|mode| mode == "?1h"),
                }),
                "{:?}",
                String::from_utf8_lossy(output)
            );
        }
        assert_eq!(
            terminal_state(&terminal(20, 5, b"\x1b[>5u")),
            Some(TerminalState {
                kitty_keyboard_flags: 5,
                ..TerminalState::default()
            })
        );
        assert_eq!(
            terminal_state(&terminal(20, 5, b"\x1b[?1049h")),
            Some(TerminalState {
                alternate_screen: true,
                ..TerminalState::default()
            })
        );
        assert_eq!(
            terminal_state(&terminal(20, 5, b"\x1b[?1049h\x1b[?1h")),
            Some(TerminalState {
                alternate_screen: true,
                application_cursor_keys: true,
                ..TerminalState::default()
            })
        );
        assert_eq!(
            terminal_state(&terminal(20, 5, b"\x1b[?1h\x1b[?1l")),
            Some(TerminalState::default())
        );
        // Any other shape is not guessed at.
        assert_eq!(parse_terminal_state(b"\x1b[?1049h"), None);
        assert_eq!(
            parse_terminal_state(b"\x1b[?1049h\x1b[?1049l\x1b[?1047l\x1b[?47l\x1b[<8u\x1b[=x;1u"),
            None
        );
    }

    #[test]
    fn lines_are_kept_from_the_end() {
        let mut text = "one\ntwo\nthree".to_string();
        assert_eq!(keep_last_lines(&mut text, 5), 0);
        assert_eq!(text, "one\ntwo\nthree");
        assert_eq!(keep_last_lines(&mut text, 2), 1);
        assert_eq!(text, "two\nthree");
        assert_eq!(keep_last_lines(&mut text, 0), 2);
        assert_eq!(text, "");
        let mut text = "a\n\n".to_string();
        assert_eq!(keep_last_lines(&mut text, 1), 2);
        assert_eq!(text, "");
        assert_eq!(
            (line_count(""), line_count("\n"), line_count("a\nb")),
            (1, 2, 2)
        );
    }

    #[test]
    fn screen_text_keeps_the_last_whole_lines() {
        let mut text = "first\nsecond\nthird".to_string();
        assert_eq!(keep_last(&mut text, 12), 1);
        assert_eq!(text, "second\nthird");
        let mut text = "first\nsecond\nthird".to_string();
        assert_eq!(keep_last(&mut text, 11), 2);
        assert_eq!(text, "third");
        let mut text = "ééé".to_string();
        assert_eq!(keep_last(&mut text, 3), 0);
        assert_eq!(text, "é");
    }

    /// `read` of `output` on a `cols` by `rows` terminal.
    fn read_after(
        cols: u16,
        rows: u16,
        output: &[u8],
        scrollback: bool,
        max_lines: Option<u32>,
    ) -> ScreenText {
        read(
            &terminal(cols, rows, output),
            cols,
            rows,
            scrollback,
            max_lines,
        )
        .unwrap()
    }

    /// The line the cursor is on, per `ScreenText`'s rule.
    fn cursor_text(screen: &ScreenText) -> Option<&str> {
        screen.text.split('\n').nth(usize::from(screen.cursor_row))
    }

    #[test]
    fn without_a_limit_the_cursor_is_on_the_screen() {
        let screen = read_after(10, 4, b"a\r\nb\r\nc\r\nd\r\ne\r\nf", true, None);
        assert_eq!(screen.text, "a\nb\nc\nd\ne\nf");
        assert_eq!((screen.cursor_row, screen.cursor_col), (3, 1));
        let screen = read_after(10, 4, b"a\r\nb\r\nc\r\nd\r\ne\r\nf", false, None);
        assert_eq!(screen.text, "c\nd\ne\nf");
        assert_eq!((screen.cursor_row, screen.cursor_col), (3, 1));
    }

    #[test]
    fn a_limit_keeps_the_last_lines_and_counts_the_cursor_from_them() {
        let history = b"line 1\r\nline 2\r\nline 3\r\nline 4\r\nline 5\r\nline 6\r\n$ ";
        for (scrollback, max_lines, text, row) in [
            (true, 3, "line 5\nline 6\n$", 2),
            (true, 1, "$", 0),
            (true, 6, "line 2\nline 3\nline 4\nline 5\nline 6\n$", 5),
            (
                true,
                100,
                "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\n$",
                6,
            ),
            (false, 2, "line 6\n$", 1),
            (false, 100, "line 4\nline 5\nline 6\n$", 3),
        ] {
            let screen = read_after(20, 4, history, scrollback, Some(max_lines));
            assert_eq!(
                (screen.text.as_str(), screen.cursor_row, screen.cursor_col),
                (text, row, 2),
                "{scrollback} {max_lines}"
            );
            assert_eq!(cursor_text(&screen), Some("$"));
        }
        let screen = read_after(20, 4, history, true, Some(0));
        assert_eq!((screen.text.as_str(), screen.cursor_row), ("", 0));
    }

    #[test]
    fn soft_wrapped_rows_are_one_line_for_the_cursor_too() {
        // 25 characters on 10 columns: three rows, one line. The prompt
        // after it wraps as well.
        let output = b"first\r\nabcdefghijklmnopqrstuvwxy\r\n> 0123456789abc";
        for scrollback in [false, true] {
            let screen = read_after(10, 6, output, scrollback, Some(10));
            assert_eq!(
                screen.text,
                "first\nabcdefghijklmnopqrstuvwxy\n> 0123456789abc"
            );
            assert_eq!(cursor_text(&screen), Some("> 0123456789abc"));
            assert_eq!((screen.cursor_row, screen.cursor_col), (2, 5));
        }
        // The cursor on the first row of a line that wraps below it.
        let screen = read_after(
            10,
            6,
            b"x\r\nabcdefghijklmnopqrst\x1b[2;4H",
            false,
            Some(10),
        );
        assert_eq!(screen.text, "x\nabcdefghijklmnopqrst");
        assert_eq!((screen.cursor_row, screen.cursor_col), (1, 3));
        // Without autowrap nothing is joined.
        let screen = read_after(
            10,
            6,
            b"\x1b[?7labcdefghijklmn\r\nsecond\x1b[?7h",
            false,
            Some(10),
        );
        assert_eq!(
            (screen.text.as_str(), screen.cursor_row),
            ("abcdefghin\nsecond", 1)
        );
    }

    #[test]
    fn a_cursor_below_the_text_or_above_the_lines_kept() {
        // Below: the rows after the text are blank.
        let screen = read_after(20, 8, b"top\r\nnext\x1b[6;3H", false, Some(10));
        assert_eq!((screen.text.as_str(), screen.cursor_row), ("top\nnext", 5));
        assert_eq!(cursor_text(&screen), None);
        let screen = read_after(20, 8, b"top\r\nnext\x1b[6;3H", false, Some(1));
        assert_eq!((screen.text.as_str(), screen.cursor_row), ("next", 4));
        // An empty screen: its one line is empty.
        let screen = read_after(20, 8, b"", true, Some(3));
        assert_eq!((screen.text.as_str(), screen.cursor_row), ("", 0));
        // Above: more lines below it than were asked for.
        let screen = read_after(20, 8, b"a\r\nb\r\nc\r\nd\x1b[1;1H", false, Some(2));
        assert_eq!((screen.text.as_str(), screen.cursor_row), ("c\nd", 0));
        // Leading blank rows are lines.
        let screen = read_after(20, 8, b"\x1b[3;1Hthird\x1b[3;2H", false, Some(8));
        assert_eq!((screen.text.as_str(), screen.cursor_row), ("\n\nthird", 2));
    }

    #[test]
    fn a_blank_screen_under_history_holds_the_cursor_below_it() {
        // Six lines on four rows leave two in the history; the screen is
        // then cleared. The text is the history alone, and the cursor's row
        // counts on from it.
        let cleared = b"h1\r\nh2\r\nh3\r\nh4\r\nh5\r\nh6\x1b[2J";
        for (at, max_lines, text, row, screen_row) in [
            ("1;1", 10, "h1\nh2", 2, 0),
            ("3;1", 10, "h1\nh2", 4, 2),
            ("3;1", 1, "h2", 3, 2),
            ("4;7", 2, "h1\nh2", 5, 3),
        ] {
            let output = [&cleared[..], format!("\x1b[{at}H").as_bytes()].concat();
            let screen = read_after(10, 4, &output, true, Some(max_lines));
            assert_eq!(
                (screen.text.as_str(), screen.cursor_row),
                (text, row),
                "{at} {max_lines}"
            );
            assert_eq!(cursor_text(&screen), None);
            // Without the history the text is empty: the row is the
            // screen's.
            let screen = read_after(10, 4, &output, false, Some(max_lines));
            assert_eq!((screen.text.as_str(), screen.cursor_row), ("", screen_row));
        }
        // Blank lines at the end of the history are not in the text, and
        // still lie between it and the cursor: the history is "h1" and
        // four blank lines, or "h1", "h2" and two.
        for (output, text, row) in [
            (
                &b"h1\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n\x1b[2J\x1b[H"[..],
                "h1",
                5,
            ),
            (
                b"h1\r\nh2\r\nh3\r\nh4\r\nh5\r\nh6\x1b[2J\x1b[H\r\n\r\n\r\n\r\n\r\n\x1b[3;1H",
                "h1\nh2",
                6,
            ),
            // A history line that wraps is one line.
            (
                b"abcdefghijklmnop\r\nh2\r\nh3\r\nh4\r\nh5\x1b[2J\x1b[2;1H",
                "abcdefghijklmnop",
                2,
            ),
        ] {
            let screen = read_after(10, 4, output, true, Some(100));
            assert_eq!((screen.text.as_str(), screen.cursor_row), (text, row));
        }
        // The alternate screen has no history to count.
        let screen = read_after(
            10,
            4,
            b"h1\r\nh2\r\nh3\r\nh4\r\nh5\x1b[?1049h\x1b[2;1H",
            true,
            Some(10),
        );
        assert_eq!((screen.text.as_str(), screen.cursor_row), ("", 1));
    }

    #[test]
    fn the_mark_finds_the_cursor_whatever_the_program_set_up() {
        // Trailing blanks before the cursor, which the text trims.
        let screen = read_after(20, 4, b"one\r\ntwo   ", false, Some(4));
        assert_eq!(
            (screen.text.as_str(), screen.cursor_row, screen.cursor_col),
            ("one\ntwo", 1, 6)
        );
        // A pending wrap at the last column: the next character would wrap
        // and scroll, the mark does not.
        let screen = read_after(5, 3, b"a\r\nb\r\nabcde", false, Some(5));
        assert_eq!(
            (screen.text.as_str(), screen.cursor_row),
            ("a\nb\nabcde", 2)
        );
        // Origin mode inside margins, insert mode, left and right margins.
        let screen = read_after(
            20,
            6,
            b"r1\r\nr2\r\nr3\r\nr4\x1b[4h\x1b[?69h\x1b[5;15s\x1b[2;5r\x1b[?6h\x1b[2;2Hx",
            false,
            Some(6),
        );
        let row = screen.text.split('\n').position(|line| line.contains('x'));
        assert_eq!(row, Some(usize::from(screen.cursor_row)), "{screen:?}");
        // Wide characters, before and under the cursor, and a cell that
        // holds the first mark already.
        for output in [
            "界界界\r\n界界".as_bytes(),
            "界界界\r\n界界\x1b[2;2H".as_bytes(),
            "a\r\n\u{e000}b\x1b[2;1H".as_bytes(),
            "a\r\nb\u{e000}\u{e001}\x1b[2;2H".as_bytes(),
        ] {
            let screen = read_after(20, 4, output, false, Some(4));
            assert_eq!(screen.cursor_row, 1, "{screen:?}");
        }
        // DEC special graphics and a shifted character set.
        let screen = read_after(20, 4, b"\x1b(0lqk\r\nx\x0e", false, Some(4));
        assert_eq!(screen.cursor_row, 1, "{screen:?}");
    }

    #[test]
    fn the_alternate_screen_has_no_history() {
        let output = b"under 1\r\nunder 2\r\nunder 3\r\nunder 4\r\n\x1b[?1049h\x1b[HFULL\x1b[3;5H";
        for scrollback in [false, true] {
            let screen = read_after(20, 3, output, scrollback, Some(10));
            assert_eq!(
                (screen.text.as_str(), screen.cursor_row, screen.cursor_col),
                ("FULL", 2, 4)
            );
            assert!(screen.alternate_screen);
        }
    }

    #[test]
    fn whole_texts_of_older_holders_are_limited_by_estimate() {
        let mut text = "h1\nh2\nh3\ns1\ns2\ns3".to_string();
        // The cursor on the last screen row, with history.
        assert_eq!(limit_whole(&mut text, 2, 3, true, 2), 1);
        assert_eq!(text, "s2\ns3");
        let mut text = "s1\ns2\ns3".to_string();
        assert_eq!(limit_whole(&mut text, 0, 3, false, 2), 0);
        assert_eq!(text, "s2\ns3");
        let mut text = "s1\ns2\ns3".to_string();
        assert_eq!(limit_whole(&mut text, 2, 3, false, 5), 2);
        assert_eq!(text, "s1\ns2\ns3");
    }
}
