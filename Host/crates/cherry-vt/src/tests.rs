use super::*;

fn term(cols: u16, rows: u16) -> Terminal {
    Terminal::new(cols, rows, 1024 * 1024).unwrap()
}

/// A fresh terminal of the source's size with the snapshot replayed. Its
/// scrollback is large enough that replay never prunes history.
fn replay(source: &Terminal, snapshot: &[u8]) -> Terminal {
    let mut copy = Terminal::new(source.cols, source.rows, 64 * 1024 * 1024).unwrap();
    copy.feed(snapshot);
    copy
}

fn restored(source: &Terminal) -> Terminal {
    replay(source, &source.snapshot().unwrap())
}

#[track_caller]
fn assert_same(original: &Terminal, copy: &Terminal) {
    assert_eq!(original.inspect().unwrap(), copy.inspect().unwrap());
}

fn feed_both(original: &mut Terminal, copy: &mut Terminal, bytes: &[u8]) {
    original.feed(bytes);
    copy.feed(bytes);
}

fn numbered(lines: usize) -> Vec<u8> {
    (0..lines)
        .flat_map(|line| format!("output line {line}\r\n").into_bytes())
        .collect()
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

/// Parameters of every `CSI ? … h/l` sequence in bytes.
fn private_modes(bytes: &[u8]) -> Vec<String> {
    let mut modes = Vec::new();
    for (start, window) in bytes.windows(3).enumerate() {
        if window == b"\x1b[?" {
            let body = &bytes[start + 3..];
            let end = body
                .iter()
                .position(|b| !b.is_ascii_digit() && *b != b';')
                .unwrap_or(body.len());
            if matches!(body.get(end), Some(b'h' | b'l')) {
                modes.push(String::from_utf8_lossy(&body[..end]).into_owned());
            }
        }
    }
    modes
}

#[test]
fn clear_screen_with_history_keeps_every_row_in_place() {
    let mut original = term(40, 10);
    original.feed(&numbered(40));
    original.feed(b"$ \x1b[H\x1b[2J$ ");
    let mut copy = restored(&original);
    assert_same(&original, &copy);
    let active = copy.inspect().unwrap().active;
    assert_eq!(active[0], "$ ");
    assert!(active[1..].iter().all(String::is_empty), "{active:?}");
    feed_both(&mut original, &mut copy, b"echo hi\r\nhi\r\n$ ");
    assert_same(&original, &copy);
}

#[test]
fn erase_below_with_history_keeps_every_row_in_place() {
    let mut original = term(40, 10);
    original.feed(&numbered(40));
    original.feed(b"\x1b[5;1H\x1b[J$ ");
    let mut copy = restored(&original);
    assert_same(&original, &copy);
    feed_both(&mut original, &mut copy, b"typed");
    assert_same(&original, &copy);
}

#[test]
fn partial_screen_interface_keeps_its_rows_and_cursor() {
    // fzf --height reserves rows below the prompt, draws there and parks the
    // cursor on its query line.
    let mut original = term(40, 12);
    original.feed(&numbered(30));
    original.feed(b"$ fzf --height 40%\r\n\r\n\r\n\r\n\r\n\x1b[4A> query\x1b[K\r\n  3/3\x1b[K\r\n\x1b[7m> item1\x1b[0m\x1b[K\r\n  item2\x1b[K\x1b[3A\x1b[8G");
    let mut copy = restored(&original);
    assert_same(&original, &copy);
    feed_both(&mut original, &mut copy, b"x\x1b[J\r\n$ ");
    assert_same(&original, &copy);
}

#[test]
fn primary_screen_with_trailing_blank_rows_survives_under_alternate_screen() {
    let mut original = term(40, 10);
    original.feed(&numbered(25));
    original.feed(b"$ \x1b[H\x1b[2J$ \x1b[1mnvim\x1b[0m\r\n");
    original
        .feed(b"\x1b[?1049h\x1b[?1h\x1b[?2004h\x1b[H\x1b[2J\x1b[38;2;100;150;200mEditor\x1b[5;3H");
    let mut copy = restored(&original);
    assert_same(&original, &copy);
    assert!(copy.inspect().unwrap().alternate);
    feed_both(
        &mut original,
        &mut copy,
        b"\x1b[?1049l\x1b[?1l\x1b[?2004l$ after",
    );
    assert_same(&original, &copy);
    let active = copy.inspect().unwrap().active;
    assert_eq!(active[0], "$ [bold]nvim");
    assert_eq!(active[1], "$ after");
}

#[test]
fn legacy_alternate_screen_modes_round_trip() {
    for entry in [47u16, 1047] {
        let mut original = term(20, 5);
        original.feed(&numbered(8));
        original.feed(format!("$ top\x1b[?{entry}h\x1b[2;2Halt").as_bytes());
        let mut copy = restored(&original);
        assert_same(&original, &copy);
        feed_both(
            &mut original,
            &mut copy,
            format!("\x1b[?{entry}lback").as_bytes(),
        );
        assert_same(&original, &copy);
    }
}

#[test]
fn cursor_mid_screen_keeps_position_and_pen() {
    let mut original = term(30, 8);
    original.feed(&numbered(12));
    original.feed(b"\x1b[3;5H\x1b[1;31m");
    let mut copy = restored(&original);
    assert_same(&original, &copy);
    feed_both(&mut original, &mut copy, b"X\x1b[B\x1b[4mY");
    assert_same(&original, &copy);
    assert!(copy.inspect().unwrap().active[2].contains("[fg=p1 bold]X"));
}

#[test]
fn snapshot_after_resize_keeps_every_row_in_place() {
    for (cols, rows) in [(40, 14), (30, 10), (50, 10), (20, 5)] {
        let mut original = term(40, 10);
        original.feed(&numbered(40));
        original.feed(b"$ \x1b[H\x1b[2J$ a much longer command line that wraps");
        original.resize(cols, rows).unwrap();
        let mut copy = restored(&original);
        assert_same(&original, &copy);
        feed_both(&mut original, &mut copy, b"\r\nnext\r\n$ ");
        assert_same(&original, &copy);
    }
}

#[test]
fn background_only_rows_and_cells_survive_snapshot() {
    let mut original = term(20, 6);
    original.feed(b"\x1b[44m\x1b[2J\x1b[Hheader\x1b[3;1Hbody\x1b[0m");
    let copy = restored(&original);
    assert_same(&original, &copy);
    let active = copy.inspect().unwrap().active;
    assert!(active[1].starts_with("[cell-bg=p4]░"), "{active:?}");
    assert!(active[5].starts_with("[cell-bg=p4]░"), "{active:?}");

    // Neovim with truecolor clears empty buffer lines under its RGB Normal
    // background; such rows also scroll into history.
    let mut original = term(20, 6);
    original.feed(b"\x1b[48;2;30;30;46m\x1b[2J\x1b[H\x1b[38;2;200;200;200mfn main() {\x1b[3;1H}\x1b[K\x1b[0m\x1b[6;1H");
    original.feed(b"\x1b[41m\x1b[K\x1b[0m\r\n\x1b[42m   \x1b[0m\r\n");
    original.feed(&numbered(8));
    let copy = restored(&original);
    assert_same(&original, &copy);
    let inspection = copy.inspect().unwrap();
    assert!(inspection.history[1].starts_with("[cell-bg=#1e1e2e]░"));
    assert!(inspection
        .history
        .iter()
        .any(|row| row.starts_with("[cell-bg=p1]░")));
}

#[test]
fn background_only_rows_survive_viewport_frames() {
    let mut source = term(20, 6);
    source.feed(
        b"\x1b[44m\x1b[2J\x1b[Hheader\x1b[3;1Hbody\x1b[0m\x1b[5;3H\x1b[48;2;1;2;3m\x1b[4X\x1b[0m",
    );
    let mut display = term(30, 8);
    display.feed(b"stale\x1b[8;1HOLD BOTTOM\x1b[1;25Hright");
    display.feed(&source.modes().unwrap());
    display.feed(&source.viewport(30, 8).unwrap());
    let (source, display) = (source.inspect().unwrap(), display.inspect().unwrap());
    assert_eq!(display.active[..6], source.active[..]);
    assert!(display.active[6..].iter().all(String::is_empty));
    assert_eq!(display.cursor, source.cursor);
}

#[test]
fn viewport_is_content_only_and_repeatable() {
    let mut source = term(8, 4);
    source.feed(b"abc\x1b[?1004h\x1b[?2033h\x1b[?2031h\x1b[?2048h\x1b[?1h\x1b[?2004h\x1b[>1u\x1b[>4;2m\x1b[?6h\x1b[4h\x1b[2;3r\x1b(0\x0eqq\x1b[?25l");
    let frame = source.viewport(16, 8).unwrap();
    assert!(!contains(&frame, b"\x1bc"), "{frame:?}");
    for mode in private_modes(&frame) {
        assert!(
            matches!(mode.as_str(), "25" | "2026"),
            "{mode} in {frame:?}"
        );
    }
    for control in [
        b"\x1b[=".as_slice(),
        b"\x1b[>",
        b"\x1b[<",
        b"\x1b(",
        b"\x0e",
        b"r\x1b",
    ] {
        assert!(!contains(&frame, control), "{control:?} in {frame:?}");
    }
    let mut display = term(16, 8);
    display.feed(&source.modes().unwrap());
    assert!(
        display.feed(&frame).is_empty(),
        "a frame must not make the renderer reply"
    );
    let first = display.inspect().unwrap();
    assert!(display.feed(&frame).is_empty());
    assert_eq!(first, display.inspect().unwrap());
    // The DEC special graphics glyphs are painted as the canonical cells.
    assert_eq!(first.active[..4], source.inspect().unwrap().active[..]);
    assert!(first.modes.contains(&"?25l".to_owned()));
}

#[test]
fn viewport_preserves_soft_wrap_positions_on_larger_screen() {
    let mut source = term(8, 4);
    source.feed(b"abcdefghijklmnopQ\x1b[2;3H\x1b[?1h\x1b[>1u");
    let mut display = term(16, 8);
    display.feed(b"stale content\x1b[8;1HOLD BOTTOM");
    display.feed(&source.modes().unwrap());
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
    display.feed(&source.modes().unwrap());
    display.feed(&source.viewport(16, 6).unwrap());
    assert!(display.inspect().unwrap().alternate);
    assert!(display.screen_text().unwrap().starts_with("editor"));
    assert!(!display.screen_text().unwrap().contains("old"));
    source.feed(b"\x1b[?1049l\r\nresumed");
    display.feed(&source.modes().unwrap());
    display.feed(&source.viewport(16, 6).unwrap());
    let text = display.screen_text().unwrap();
    assert!(!display.inspect().unwrap().alternate);
    assert!(text.contains("primary"));
    assert!(text.contains("resumed"));
    assert!(!text.contains("editor"));
}

#[test]
fn modes_round_trip_onto_a_dirty_renderer() {
    let mut source = term(20, 5);
    source.feed(b"\x1b[?1h\x1b[?5h\x1b[?7l\x1b[?12h\x1b[?1002h\x1b[?1006h\x1b[?1004h\x1b[?2004h\x1b[?2027l\x1b[?2031h\x1b[?66h\x1b[20h\x1b[?1007l\x1b[?2048h\x1b[4h\x1b[?6h\x1b[?69h\x1b[?25l\x1b[>4;2m\x1b[?1049h\x1b[>1u\x1b[>5u");
    let modes = source.modes().unwrap();
    assert!(!contains(&modes, b"2048"), "{modes:?}");
    assert!(!private_modes(&modes)
        .iter()
        .any(|mode| mode == "25" || mode == "2026"));
    let mut renderer = term(30, 8);
    renderer.feed(
        b"\x1b[?1003h\x1b[?1015h\x1b[?45h\x1b[?1004h\x1b(0\x0e\x1b[3;5r\x1b[?6h\x1b[4h\x1b[>3u",
    );
    renderer.feed(&modes);
    let (source, renderer) = (source.inspect().unwrap(), renderer.inspect().unwrap());
    let managed = |modes: &[String]| {
        modes
            .iter()
            .filter(|mode| !matches!(mode.as_str(), "?25l" | "4h" | "?6h" | "?69h"))
            .cloned()
            .collect::<Vec<_>>()
    };
    assert_eq!(managed(&renderer.modes), managed(&source.modes));
    assert!(renderer.alternate);
    assert_eq!(renderer.kitty_flags, 5);
    assert!(renderer.state.contains("␛[>4;2m"), "{}", renderer.state);
    assert!(!renderer.state.contains("␛(0") && !renderer.state.contains('\x0e'));
    assert!(!renderer.state.contains(";5r"), "{}", renderer.state);

    // Back on the primary screen with default modes.
    let mut plain = term(20, 5);
    let mut renderer = term(30, 8);
    renderer.feed(&modes);
    plain.feed(b"\x1b[?25l");
    renderer.feed(&plain.modes().unwrap());
    let renderer = renderer.inspect().unwrap();
    assert!(!renderer.alternate);
    // Modes whose default comes from the user's terminal keep the value the
    // session last had away from libghostty's default.
    assert_eq!(renderer.modes, ["?1007l", "?2027l"]);
    assert_eq!(renderer.kitty_flags, 0);
    assert!(!renderer.state.contains("␛[>4;2m"));
}

#[test]
fn modes_and_a_frame_form_one_synchronized_update() {
    let mut source = term(8, 3);
    source.feed(b"primary\x1b[?1049h\x1b[?2004h\x1b[2;2H\x1b[31meditor");
    let mut update = b"\x1b[?2026h".to_vec();
    update.extend(source.modes().unwrap());
    update.extend(source.viewport(16, 6).unwrap());
    assert!(update.ends_with(b"\x1b[?2026l"), "{update:?}");
    let mut display = term(16, 6);
    display.feed(b"old\x1b[?1049h\x1b[?1004h");
    display.feed(&update);
    let (source, display) = (source.inspect().unwrap(), display.inspect().unwrap());
    assert!(display.alternate);
    assert_eq!(display.modes, source.modes);
    assert_eq!(display.active[..3], source.active[..]);
    assert_eq!(display.cursor, source.cursor);
    assert!(display.state.contains("␛[0m␛[38;5;1m"), "{}", display.state);
}

/// What a viewport client writes after a batch of output: `modes()` in a
/// synchronized update when it changed since `sent`, then a frame.
fn viewport_update(source: &Terminal, sent: &mut Vec<u8>, size: (u16, u16)) -> Vec<u8> {
    let modes = source.modes().unwrap();
    let mut update = Vec::new();
    if modes != *sent {
        update.extend_from_slice(b"\x1b[?2026h");
        update.extend_from_slice(&modes);
        *sent = modes;
    }
    update.extend(source.viewport(size.0, size.1).unwrap());
    update
}

#[test]
fn viewport_rendering_from_the_alternate_screen_keeps_the_window_cursor() {
    // Viewport rendering starts with the session on the alternate screen:
    // the window's primary screen is the user's shell, and leaving the
    // alternate screen (as a detach does) returns to its prompt line.
    let mut source = term(20, 5);
    source.feed(b"$ nvim\r\n\x1b[?1049h\x1b[H\x1b[2Jeditor\x1b[3;4H");
    let mut window = term(30, 8);
    window.feed(b"one\r\nuser$ cherry attach\r\n");
    let mut sent = Vec::new();
    window.feed(&viewport_update(&source, &mut sent, (30, 8)));
    assert!(window.inspect().unwrap().alternate);
    // Changed modes are sent again while both are on the alternate screen.
    source.feed(b"\x1b[?1000h\x1b[?2004h more");
    let update = viewport_update(&source, &mut sent, (30, 8));
    assert!(contains(&update, b"\x1b[?1000h"), "{update:?}");
    window.feed(&update);
    window.feed(b"\x1b[?1049l");
    let shown = window.inspect().unwrap();
    assert_eq!(shown.cursor, (0, 2), "{shown:?}");
    assert_eq!(shown.active[..3], ["one", "user$ cherry attach", ""]);
}

#[test]
fn viewport_rendering_keeps_the_window_cursor_over_a_stale_1049_cursor() {
    // tmux keeps the cursor 1049 saves apart from DECSC, and ?1049l restores
    // it even on the primary screen, so the one an earlier program left is
    // still there. Ghostty keeps one slot for both; the stale 1049 cursor
    // stays in it, and dropping DECSC from the updates models tmux. Leaving
    // with ?1049l returns to the prompt whichever mode the session entered
    // the alternate screen with.
    let entries: [&[u8]; 3] = [b"\x1b[?1049h", b"\x1b[?1047h", b"\x1b[?47h"];
    for (entry, tmux) in entries.into_iter().flat_map(|e| [(e, false), (e, true)]) {
        let seen = |bytes: Vec<u8>| -> Vec<u8> {
            if !tmux {
                return bytes;
            }
            let mut kept = Vec::with_capacity(bytes.len());
            let mut rest = bytes.as_slice();
            while let Some((&byte, tail)) = rest.split_first() {
                if tail.first() == Some(&b'7') && byte == 0x1b {
                    rest = &tail[1..];
                } else {
                    kept.push(byte);
                    rest = tail;
                }
            }
            kept
        };
        let case = format!("{} tmux={tmux}", String::from_utf8_lossy(entry));
        let mut source = term(20, 5);
        source.feed(b"$ nvim\r\n");
        source.feed(entry);
        source.feed(b"\x1b[H\x1b[2Jeditor\x1b[3;4H");
        let mut window = term(30, 8);
        window.feed(b"\x1b[5;10H\x1b[?1049h\x1b[?1049l\x1b[H\x1b[2J");
        window.feed(b"one\r\nuser$ cherry attach\r\n");
        let mut sent = Vec::new();
        window.feed(&seen(viewport_update(&source, &mut sent, (30, 8))));
        source.feed(b"\x1b[?2004h more");
        let update = viewport_update(&source, &mut sent, (30, 8));
        assert!(contains(&update, b"\x1b[?2004h"), "{case}");
        window.feed(&seen(update));
        window.feed(b"\x1b[?1049l");
        let shown = window.inspect().unwrap();
        assert_eq!(shown.cursor, (0, 2), "{case} {shown:?}");
        assert_eq!(shown.active[..3], ["one", "user$ cherry attach", ""]);

        // Frames of the primary screen in between: the cursor they left.
        let mut source = term(20, 5);
        source.feed(entry);
        let mut window = term(30, 8);
        window.feed(b"\x1b[5;10H\x1b[?1049h\x1b[?1049l\x1b[H\x1b[2J$ cherry attach\r\n");
        let mut sent = Vec::new();
        window.feed(&seen(viewport_update(&source, &mut sent, (30, 8))));
        source.feed(b"\x1b[?1049l\x1b[?1047l\x1b[?47l\x1b[H\x1b[2Jone\r\n$ ");
        window.feed(&seen(viewport_update(&source, &mut sent, (30, 8))));
        source.feed(entry);
        window.feed(&seen(viewport_update(&source, &mut sent, (30, 8))));
        window.feed(b"\x1b[?1049l");
        let shown = window.inspect().unwrap();
        assert_eq!(shown.cursor, (2, 1), "{case} {shown:?}");
        assert_eq!(shown.active[..2], ["one", "$ "]);
    }
}

#[test]
fn leaving_the_alternate_screen_restores_the_primary_cursor_frames_painted() {
    // Frames painted the primary screen before the program entered the
    // alternate screen: leaving it shows that screen with its cursor.
    let mut source = term(20, 5);
    source.feed(b"one\r\ntwo\r\n\x1b[31m$ \x1b[0mnvim\r\n");
    let mut window = term(30, 8);
    window.feed(b"stale\x1b[5;9H");
    let mut sent = Vec::new();
    window.feed(&viewport_update(&source, &mut sent, (30, 8)));
    source.feed(b"\x1b[?1049h\x1b[?1h\x1b[H\x1b[2Jeditor\x1b[4;2H");
    window.feed(&viewport_update(&source, &mut sent, (30, 8)));
    source.feed(b"\x1b[?1004h");
    window.feed(&viewport_update(&source, &mut sent, (30, 8)));
    feed_both(&mut source, &mut window, b"\x1b[?1049l");
    let (source, shown) = (source.inspect().unwrap(), window.inspect().unwrap());
    assert_eq!(shown.cursor, source.cursor);
    assert_eq!(shown.active[..5], source.active[..]);
}

#[test]
fn terminfo_name_answers_xtgettcap_tn() {
    let mut t = term(20, 4);
    let query = b"\x1bP+q544e\x1b\\";
    assert!(t.feed(query).is_empty(), "no name is reported by default");
    t.set_terminfo_name("xterm-256color").unwrap();
    assert_eq!(
        t.feed(query),
        b"\x1bP1+r544E=787465726D2D323536636F6C6F72\x1b\\"
    );
    assert!(t.set_terminfo_name(&"x".repeat(129)).is_err());
    t.set_terminfo_name("").unwrap();
    assert!(t.feed(query).is_empty());
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
    let mut copy = restored(&original);
    assert_same(&original, &copy);
    assert_eq!(original.feed(b"\x1b[6n"), copy.feed(b"\x1b[6n"));
    for query in [b"\x1b[?1$p".as_slice(), b"\x1b[?1002$p", b"\x1b[?2004$p"] {
        assert_eq!(original.feed(query), copy.feed(query));
    }
    feed_both(&mut original, &mut copy, b"\x1b[?1049lAfter quit");
    assert_same(&original, &copy);
    assert_eq!(
        copy.inspect().unwrap().active[0],
        "shell prompt> After quit"
    );
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
        let mut copy = restored(&original);
        feed_both(&mut original, &mut copy, suffix);
        assert_same(&original, &copy);
    }
}

#[test]
fn resized_unicode_and_scrollback_survive_snapshot() {
    let mut original = term(20, 4);
    for _ in 0..10 {
        original.feed("one 界 🍒\r\n".as_bytes());
    }
    original.resize(40, 8).unwrap();
    let copy = restored(&original);
    assert_same(&original, &copy);
}

#[test]
fn soft_wraps_wide_cells_and_graphemes_survive_in_history() {
    for grapheme_mode in [false, true] {
        let mut original = term(10, 6);
        if grapheme_mode {
            original.feed(b"\x1b[?2027h");
        }
        original.feed("0123456789abcdefghij界界界界界\r\n".as_bytes());
        original.feed("123456789界tail\r\n".as_bytes());
        original.feed("e\u{301} 👍🏽 🇯🇵 👨\u{200d}👩\u{200d}👧\r\n".as_bytes());
        original.feed(b"\x1b[31mred wrapping line\x1b[0m\r\n");
        original.feed(&numbered(8));
        original.feed(b"tail \x1b[44mwrapped under a background");
        let mut copy = restored(&original);
        assert_same(&original, &copy);
        let history = copy.inspect().unwrap().history;
        assert!(history.iter().any(|row| row.ends_with('⏎')), "{history:?}");
        assert!(history.iter().any(|row| row.contains('»')), "{history:?}");
        feed_both(&mut original, &mut copy, b"\x1b[0m more text\r\n");
        assert_same(&original, &copy);
    }
}

#[test]
fn styles_hyperlinks_and_protection_survive_snapshot() {
    let mut original = term(40, 6);
    original.feed(b"\x1b[1;2;3;5;7;9;53mA\x1b[0m \x1b[4:3m\x1b[58;2;255;0;0mB\x1b[0m \x1b[38;5;196;48;5;21mC\x1b[0m \x1b[8mD\x1b[0m \x1b[4:2mE\x1b[0m \x1b[4mF\x1b[0m\r\n");
    original.feed(b"see \x1b]8;;file:///tmp/x.rs\x1b\\x.rs\x1b]8;;\x1b\\ done \x1b]8;id=a;https://example.com\x1b\\open\x1b]8;;\x1b\\\r\n");
    original.feed(b"\x1b[1\"qP\x1b[0\"qU\r\n");
    original.feed(b"\x1b]8;;https://example.com/open\x1b\\\x1b[1\"q\x1b[32m");
    let mut copy = restored(&original);
    assert_same(&original, &copy);
    let active = copy.inspect().unwrap().active;
    assert!(
        active[1].contains("[link=file:///tmp/x.rs]x.rs"),
        "{active:?}"
    );
    assert!(active[2].contains("[protected]P"), "{active:?}");
    // The open hyperlink, protection and pen continue on the copy.
    feed_both(&mut original, &mut copy, b"next");
    assert_same(&original, &copy);
    assert!(
        copy.inspect().unwrap().active[3].contains("protected link=https://example.com/open]next")
    );

    // Links in retained history survive too.
    original.feed(&numbered(8));
    let copy = restored(&original);
    assert_same(&original, &copy);
    assert!(copy
        .inspect()
        .unwrap()
        .history
        .iter()
        .any(|row| row.contains("link=file:///tmp/x.rs")));
}

#[test]
fn hyperlinks_survive_viewport_frames() {
    let mut source = term(30, 3);
    source.feed(b"see \x1b]8;;file:///tmp/x.rs\x1b\\x.rs\x1b]8;;\x1b\\ done");
    let mut display = term(40, 5);
    display.feed(&source.modes().unwrap());
    display.feed(&source.viewport(40, 5).unwrap());
    assert_eq!(
        display.inspect().unwrap().active[0],
        source.inspect().unwrap().active[0]
    );
}

#[test]
fn kitty_keyboard_stack_survives_snapshot() {
    let mut original = term(20, 4);
    original.feed(b"\x1b[>1u\x1b[>3u");
    let mut copy = restored(&original);
    assert_same(&original, &copy);
    for expected in [1, 0, 0] {
        feed_both(&mut original, &mut copy, b"\x1b[<u");
        assert_eq!(original.inspect().unwrap().kitty_flags, expected);
        assert_same(&original, &copy);
    }

    // Each screen has its own stack.
    let mut original = term(20, 4);
    original.feed(b"\x1b[>1u\x1b[>9u\x1b[?1049h\x1b[>5u\x1b[>7u");
    let mut copy = restored(&original);
    assert_same(&original, &copy);
    feed_both(&mut original, &mut copy, b"\x1b[<u");
    assert_same(&original, &copy);
    feed_both(&mut original, &mut copy, b"\x1b[?1049l");
    assert_eq!(copy.inspect().unwrap().kitty_flags, 9);
    for _ in 0..3 {
        assert_same(&original, &copy);
        feed_both(&mut original, &mut copy, b"\x1b[<u");
    }
}

#[test]
fn kitty_keyboard_entries_below_a_zero_entry_survive_snapshot() {
    // A program that pushed "disabled" over its parent's flags, on either
    // screen, with an unfinished sequence in the parser; and flags a program
    // left on the alternate screen, which the next one entering it inherits.
    for (setup, pops) in [
        (b"\x1b[>1u\x1b[>0u".as_slice(), 2),
        (b"\x1b[>3u\x1b[>0u\x1b[>0u\x1b[?1049h\x1b[>5u\x1b[>0u", 4),
        (
            b"\x1b[>1u\x1b[>0u\x1b[?1049h\x1b[>0u\x1b[?1049l\x1b[38;2;",
            3,
        ),
        (
            b"\x1b[?1049h\x1b[>1u\x1b[>5u\x1b[?1049l\x1b]8;;https://x\x1b\\",
            2,
        ),
    ] {
        let mut original = term(20, 4);
        original.feed(setup);
        let mut copy = restored(&original);
        assert_same(&original, &copy);
        feed_both(&mut original, &mut copy, b"m\x1b[?1049l");
        for _ in 0..pops {
            feed_both(&mut original, &mut copy, b"\x1b[<u");
            assert_same(&original, &copy);
        }
        feed_both(&mut original, &mut copy, b"\x1b[?1049h");
        for _ in 0..pops {
            feed_both(&mut original, &mut copy, b"\x1b[<u");
            assert_same(&original, &copy);
        }
    }
}

#[test]
fn pending_wrap_glyph_is_reprinted_before_character_sets() {
    for (prefix, suffix) in [
        (b"abcdefghiq\x1b(0".as_slice(), b"qx".as_slice()),
        (b"\x1b(0abcdefghik".as_slice(), b"q".as_slice()),
        (b"\x1b)0\x0eabcdefghik".as_slice(), b"q\x0fq".as_slice()),
    ] {
        let mut original = term(10, 3);
        original.feed(prefix);
        let mut copy = restored(&original);
        assert_same(&original, &copy);
        feed_both(&mut original, &mut copy, suffix);
        assert_same(&original, &copy);
    }
}

#[test]
fn primary_character_sets_do_not_leak_into_the_alternate_screen() {
    let mut original = term(20, 4);
    original.feed(b"\x1b(0qq\x1b[?1049h\x1b(Bplain text");
    let mut copy = restored(&original);
    assert_eq!(
        copy.inspect().unwrap().active,
        original.inspect().unwrap().active
    );
    feed_both(&mut original, &mut copy, b"\x1b[?1049lqq");
    assert_same(&original, &copy);
}

#[test]
fn origin_mode_restores_cursor_without_a_stray_glyph() {
    let mut original = term(10, 8);
    original
        .feed(b"r1\r\nr2\r\nr3\r\nr4\r\nr5\r\nr6\r\nr7\r\nr8\x1b[3;8r\x1b[?6h\x1b[3;1H0123456789");
    let mut copy = restored(&original);
    assert_same(&original, &copy);
    assert_eq!(copy.inspect().unwrap().active[6], "r7");
    assert_eq!(original.feed(b"\x1b[6n"), copy.feed(b"\x1b[6n"));
    feed_both(&mut original, &mut copy, b"X\x1b[1;1HY");
    assert_same(&original, &copy);
}

#[test]
fn origin_mode_cursor_is_restored_after_margins() {
    let mut original = term(40, 10);
    original.feed(b"\x1b[3;8r\x1b[?6h\x1b[2;4Htext");
    let mut copy = restored(&original);
    assert_same(&original, &copy);
    assert_eq!(original.feed(b"\x1b[6n"), copy.feed(b"\x1b[6n"));
}

#[test]
fn saved_cursors_survive_snapshot() {
    // Each case saves a cursor (DECSC, or 1049 entering the alternate
    // screen), then changes the live one; `leave` returns to the primary
    // screen where one is active. Restoring must match on both terminals,
    // before and after leaving, and printing afterwards must too.
    let cases: &[(&[u8], &[u8])] = &[
        // Position and pen.
        (b"\x1b[3;5H\x1b[1;31m\x1b7\x1b[0m\x1b[5;1H", b""),
        // Pending wrap at the edge, protection, DEC graphics in G0 and G1
        // with G1 shifted in, and an open hyperlink (not saved).
        (
            b"\x1b[2;1H01234567890123456789\x1b[1\"q\x1b(0\x1b)0\x0e\x1b7\x1b[0\"q\x1b(B\x1b)B\x0f\x1b]8;;https://x\x1b\\\x1b[H",
            b"",
        ),
        // A wide glyph at the edge, with a pending wrap.
        ("\x1b[3;1H012345678901234567界\x1b7\x1b[H".as_bytes(), b""),
        // Origin mode inside margins.
        (b"\x1b[2;4r\x1b[?6h\x1b[2;3H\x1b7\x1b[?6l\x1b[r\x1b[5;1H", b""),
        // 1048 saves like DECSC.
        (b"\x1b[4;2H\x1b[7m\x1b[?1048h\x1b[0m\x1b[H", b""),
        // The alternate screen's own saved cursor, and the primary cursor
        // 1049 saved with origin mode on.
        (
            b"\x1b[2;4r\x1b[?6h\x1b[2;3H\x1b[4m\x1b[?1049h\x1b[?6l\x1b[r\x1b[4;6H\x1b[3m\x1b7\x1b[0m\x1b[H",
            b"\x1b[?1049l",
        ),
        // Saved cursors on both screens under 47, with the alternate
        // screen's cursor pending a wrap and DEC graphics in G0.
        (
            b"\x1b[3;7H\x1b[4m\x1b7\x1b[0m\x1b[?47h\x1b[2;1H01234567890123456789\x1b(0\x1b7\x1b(B\x1b[H",
            b"\x1b[?47l",
        ),
        // The same under 1047.
        (
            b"\x1b[4;4H\x1b[9m\x1b7\x1b[0m\x1b[?1047h\x1b[2;2H\x1b[2m\x1b7\x1b[0m\x1b[H",
            b"\x1b[?1047l",
        ),
    ];
    for &(setup, leave) in cases {
        let mut original = term(20, 5);
        original.feed(setup);
        let mut copy = restored(&original);
        assert_same(&original, &copy);
        for step in [
            b"\x1b8".as_slice(),
            b"qX",
            leave,
            b"\x1b8",
            b"qY\x1b[?1049h\x1b8Z",
        ] {
            feed_both(&mut original, &mut copy, step);
            assert_same(&original, &copy);
        }
    }
    // Nothing is set up for a terminal that never saved a cursor.
    let fresh = term(20, 5).snapshot().unwrap();
    assert!(!contains(&fresh, b"\x1b7"), "{fresh:?}");
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
        let mut copy = restored(&original);
        assert_same(&original, &copy);
        feed_both(&mut original, &mut copy, b"NEXT");
        assert_same(&original, &copy);
        assert_eq!(original.snapshot().unwrap(), copy.snapshot().unwrap());
    }
    // Autowrap disabled after the edge was reached keeps the pending wrap.
    let mut original = term(10, 4);
    original.feed(b"0123456789\x1b[?7l");
    let copy = restored(&original);
    assert_same(&original, &copy);
}

#[test]
fn synchronized_update_in_progress_is_restored() {
    let mut original = term(20, 4);
    original.feed(b"\x1b[?2026hpartial");
    let copy = restored(&original);
    assert_same(&original, &copy);
}

#[test]
fn reports_the_host_answers_are_left_to_the_host() {
    // In-band size (2048) and visibility (2033) reports: enabling either
    // makes a terminal report at once, and a renderer that enabled them
    // would answer next to the host.
    for mode in [b"2048".as_slice(), b"2033"] {
        let mut original = term(20, 4);
        assert!(!original.feed(&[b"\x1b[?", mode, b"h"].concat()).is_empty());
        let snapshot = original.snapshot().unwrap();
        assert!(!contains(&snapshot, mode), "{snapshot:?}");
        let modes = original.modes().unwrap();
        assert!(!contains(&modes, mode), "{modes:?}");
        let mut renderer = term(20, 4);
        assert!(renderer.feed(&snapshot).is_empty());
        assert!(renderer.feed(&modes).is_empty());
    }
}

fn styled_history(terminal: &mut Terminal, lines: usize) {
    for line in 0..lines {
        let mut bytes = Vec::new();
        for col in 0..60u32 {
            let _ = write!(
                bytes,
                "\x1b[38;2;{};{};{}m\x1b[48;2;{};{};{}m{}",
                (line as u32 * 7 + col) % 256,
                col * 4 % 256,
                line % 256,
                col,
                line % 200,
                (col * 3) % 256,
                char::from(b'a' + (col % 26) as u8)
            );
        }
        bytes.extend_from_slice(b"\x1b[0m\r\n");
        terminal.feed(&bytes);
    }
}

#[test]
fn snapshot_limited_drops_the_oldest_history_first() {
    let mut original = Terminal::new(80, 24, 16 * 1024 * 1024).unwrap();
    styled_history(&mut original, 400);
    original.feed(b"\x1b[H\x1b[2Jtop row\x1b[10;5H\x1b[44m\x1b[Kmiddle\x1b[0m\x1b[12;3H");
    let full = original.snapshot().unwrap();
    assert_eq!(original.snapshot_limited(full.len()).unwrap(), full);
    let limit = full.len() / 3;
    let limited = original.snapshot_limited(limit).unwrap();
    assert!(limited.len() <= limit, "{} > {limit}", limited.len());
    let copy = replay(&original, &limited);
    let (source, copy) = (original.inspect().unwrap(), copy.inspect().unwrap());
    assert_eq!(copy.active, source.active);
    assert_eq!(copy.cursor, source.cursor);
    assert_eq!(copy.modes, source.modes);
    assert_eq!(copy.state, source.state);
    assert!(!copy.history.is_empty() && copy.history.len() < source.history.len());
    assert_eq!(
        copy.history[..],
        source.history[source.history.len() - copy.history.len()..]
    );
    let error = original.snapshot_limited(128).unwrap_err().to_string();
    assert!(error.contains("active screen"), "{error}");
}

#[test]
fn snapshot_limited_drops_whole_wrapped_lines() {
    let mut original = Terminal::new(20, 5, 16 * 1024 * 1024).unwrap();
    for line in 0..40 {
        original.feed(
            format!(
                "\x1b[3{}mline {line:02} exceeding twenty columns\x1b[0m\r\n",
                line % 8
            )
            .as_bytes(),
        );
    }
    original.feed(b"$ ls");
    let full = original.snapshot().unwrap();
    let source = original.inspect().unwrap();
    // Every retained history row keeps its position and wrap marks, and the
    // first one starts a line, whatever the limit.
    for limit in (full.len() / 3..full.len()).step_by(97) {
        let limited = original.snapshot_limited(limit).unwrap();
        assert!(limited.len() <= limit, "{} > {limit}", limited.len());
        let copy = replay(&original, &limited).inspect().unwrap();
        assert_eq!(copy.active, source.active);
        assert_eq!(copy.cursor, source.cursor);
        assert!(copy.history.len() < source.history.len());
        assert_eq!(
            copy.history[..],
            source.history[source.history.len() - copy.history.len()..],
            "limit {limit}"
        );
        assert!(copy.history[0].contains("line"), "{:?}", copy.history[0]);
    }

    // A logical line far longer than a screen is dropped whole too.
    let mut original = Terminal::new(20, 5, 16 * 1024 * 1024).unwrap();
    original.feed(b"$ cat blob\r\n");
    original.feed(&[b'x'; 20 * 30]);
    original.feed(b"\r\n");
    original.feed(&numbered(10));
    original.feed(b"$ ");
    let full = original.snapshot().unwrap();
    let limited = original.snapshot_limited(full.len() - 100).unwrap();
    let (source, copy) = (
        original.inspect().unwrap(),
        replay(&original, &limited).inspect().unwrap(),
    );
    assert_eq!(copy.history[0], "output line 0");
    assert_eq!(
        copy.history[..],
        source.history[source.history.len() - copy.history.len()..]
    );
    assert_eq!(copy.active, source.active);

    // When the cut line continues into the active screen, all history is
    // dropped; the active screen is kept, and only its first row loses the
    // continuation mark of the line whose start was dropped.
    let mut original = Terminal::new(20, 5, 16 * 1024 * 1024).unwrap();
    original.feed(b"$ cat blob\r\n");
    original.feed(&[b'x'; 20 * 30]);
    original.feed(b"\r\n$ ");
    let full = original.snapshot().unwrap();
    let limited = original.snapshot_limited(full.len() - 100).unwrap();
    let (source, copy) = (
        original.inspect().unwrap(),
        replay(&original, &limited).inspect().unwrap(),
    );
    assert!(copy.history.is_empty(), "{:?}", copy.history);
    let mut expected = source.active.clone();
    assert!(expected[0].starts_with('↪'), "{expected:?}");
    expected[0] = expected[0].trim_start_matches('↪').to_owned();
    assert_eq!(copy.active, expected);
    assert_eq!(copy.cursor, source.cursor);
}

#[test]
fn snapshot_limited_keeps_both_screens_under_an_alternate_screen() {
    let mut original = Terminal::new(80, 24, 16 * 1024 * 1024).unwrap();
    styled_history(&mut original, 300);
    original.feed(b"$ \x1b[H\x1b[2J$ vim\r\n\x1b[?1049h\x1b[H\x1b[44m\x1b[2Jeditor\x1b[0m");
    let full = original.snapshot().unwrap();
    let limit = full.len() / 2;
    let limited = original.snapshot_limited(limit).unwrap();
    assert!(limited.len() <= limit);
    let mut copy = replay(&original, &limited);
    assert_eq!(
        copy.inspect().unwrap().active,
        original.inspect().unwrap().active
    );
    feed_both(&mut original, &mut copy, b"\x1b[?1049l");
    let (source, copy) = (original.inspect().unwrap(), copy.inspect().unwrap());
    assert_eq!(copy.active, source.active);
    assert_eq!(copy.cursor, source.cursor);
    assert!(!copy.history.is_empty() && copy.history.len() < source.history.len());
    assert_eq!(
        copy.history[..],
        source.history[source.history.len() - copy.history.len()..]
    );
}

#[test]
fn rows_after_a_replayed_soft_wrap_keep_their_background_and_position() {
    // A background-coloured line that wraps on a cleared screen with
    // history: the continuation row's empty cells stay uncoloured.
    let mut original = term(5, 3);
    original.feed(b"a\r\nb\r\nc\r\nd\r\ne\r\n\x1b[H\x1b[J\x1b[41mabcdefg\x1b[0m\r\n");
    let copy = restored(&original);
    assert_same(&original, &copy);
    assert_eq!(copy.inspect().unwrap().active[1], "↪[bg=p1]fg");

    // A continuation row holding only a wide-glyph spacer head is followed
    // by another continuation: every row keeps its own line.
    let mut original = term(20, 5);
    original.feed(
        "$ cat data.tsv\r\n01234567890123456789y\t\t\t中文 row\r\nnext line\r\n$ ".as_bytes(),
    );
    let mut copy = restored(&original);
    assert_same(&original, &copy);
    feed_both(&mut original, &mut copy, b"ls\r\n");
    assert_same(&original, &copy);

    // Random wrapped content with styles, wide glyphs and tabs, in history
    // and on screen.
    let mut seed = 0x2545_f491_u32;
    let mut next = move || {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        seed
    };
    for _ in 0..40 {
        let mut original = term(12, 4);
        for _ in 0..30 {
            let bytes: &[u8] = match next() % 9 {
                0 => b"\x1b[41m",
                1 => b"\x1b[0m",
                2 => "界".as_bytes(),
                3 => b"\t",
                4 => b"\r\n",
                5 => b"abcdefghijk",
                6 => b"\x1b[44mxy",
                7 => b"\x1b[K",
                _ => b"z",
            };
            original.feed(bytes);
        }
        let mut copy = restored(&original);
        assert_same(&original, &copy);
        feed_both(&mut original, &mut copy, b"\x1b[0m end\r\n");
        assert_same(&original, &copy);
    }
}

#[test]
fn pending_wrap_at_a_right_margin_survives_snapshot() {
    let mut original = term(20, 5);
    original.feed(b"\x1b[?69h\x1b[3;12s\x1b[2;3H0123456789");
    let state = original.inspect().unwrap();
    assert_eq!((state.cursor, state.pending_wrap), ((11, 1), true));
    let mut copy = restored(&original);
    assert_same(&original, &copy);
    feed_both(&mut original, &mut copy, b"X");
    assert_same(&original, &copy);
}

/// `Inspection` of a copy made by designating ASCII where Ghostty keeps its
/// UTF-8 default (they print alike), with that difference removed.
fn without_ascii_designations(mut inspection: Inspection) -> Inspection {
    for slot in ["␛(B", "␛)B", "␛*B", "␛+B"] {
        inspection.state = inspection.state.replace(slot, "");
    }
    inspection
}

#[test]
fn wide_cells_holding_a_narrow_space_keep_the_row_in_place() {
    // A wide character printed under DEC special graphics is kept as a wide
    // cell holding a space; the cells after it stay at their columns, in a
    // snapshot, a pending-wrap reprint and a viewport frame.
    for setup in [
        "\x1b(0中qqq\x1b(B abc",
        "\x1b(0012345678中qq\x1b(Btail",
        "\x1b(0abcdefghi中\x1b(B",
        "\x1b(0abcdefgh中\x1b(B",
    ] {
        let mut original = term(10, 3);
        original.feed(setup.as_bytes());
        let mut copy = restored(&original);
        let (source, copied) = (original.inspect().unwrap(), copy.inspect().unwrap());
        assert_eq!(
            without_ascii_designations(copied),
            without_ascii_designations(source.clone()),
            "{setup:?}"
        );
        feed_both(&mut original, &mut copy, b"\x1b[1;3HX\x1b[3;1HY");
        assert_eq!(
            copy.inspect().unwrap().active,
            original.inspect().unwrap().active,
            "{setup:?}"
        );
        let mut display = term(14, 5);
        display.feed(&original.modes().unwrap());
        display.feed(&original.viewport(14, 5).unwrap());
        let shown = display.inspect().unwrap();
        let source = original.inspect().unwrap();
        for (row, (shown, source)) in shown.active.iter().zip(&source.active).enumerate() {
            let source = source.trim_start_matches('↪').trim_end_matches(['⏎', '»']);
            assert_eq!(shown, source, "{setup:?} row {row}");
        }
    }
}

#[test]
fn modes_leave_the_users_terminal_defaults_alone() {
    // A session that never touched DECARM, alternate scroll, the Meta and
    // Alt key modes or grapheme clustering sends none of them.
    let user_defaults = ["8", "1007", "1035", "1036", "1039", "2027"];
    let modes = term(20, 5).modes().unwrap();
    for mode in private_modes(&modes) {
        assert!(
            !user_defaults.contains(&mode.as_str()),
            "?{mode} in {modes:?}"
        );
    }
    // Ones the session changed are sent.
    let mut source = term(20, 5);
    source.feed(b"\x1b[?8h\x1b[?1007l\x1b[?1036l\x1b[?2027l");
    let modes = source.modes().unwrap();
    for sent in ["\x1b[?8h", "\x1b[?1007l", "\x1b[?1036l", "\x1b[?2027l"] {
        assert!(contains(&modes, sent.as_bytes()), "{sent:?} in {modes:?}");
    }
    assert!(!contains(&modes, b"?1035"), "{modes:?}");
    let mut renderer = term(30, 8);
    renderer.feed(&modes);
    assert_eq!(
        renderer.inspect().unwrap().modes,
        source.inspect().unwrap().modes
    );
}

/// The screens, cursor, modes and state of `copy` after `refresh()`, compared
/// with `original` without history (a refresh leaves the receiver's alone)
/// and ASCII designations (see `without_ascii_designations`).
#[track_caller]
fn assert_same_screens(original: &Terminal, copy: &Terminal) {
    let screens = |terminal: &Terminal| {
        let mut inspection = without_ascii_designations(terminal.inspect().unwrap());
        inspection.history.clear();
        inspection
    };
    assert_eq!(screens(copy), screens(original));
}

/// Situations a refresh must reproduce, each with bytes to feed afterwards.
fn refresh_cases() -> Vec<(&'static str, Vec<u8>, &'static [u8])> {
    vec![
        (
            "styled prompt after clear",
            [numbered(40), b"$ \x1b[H\x1b[2J\x1b[1;32m$ \x1b[0mls".to_vec()].concat(),
            b"\r\nout\r\n$ ",
        ),
        (
            "background rows and hyperlinks",
            b"\x1b[44m\x1b[2J\x1b[Hheader\x1b[3;1Hbody\x1b[0m\x1b[5;1Hsee \x1b]8;;file:///x\x1b\\x\x1b]8;;\x1b\\ \x1b]8;;https://y\x1b\\".to_vec(),
            b"open\x1b]8;;\x1b\\",
        ),
        (
            "soft wraps and wide cells",
            "0123456789abcdefghij界界界界界\r\n123456789界tail\r\n\x1b[31mred wrapping line\x1b[0m".as_bytes().to_vec(),
            b" more\r\n",
        ),
        (
            "pending wrap with a pen",
            b"\x1b[3;1H\x1b[31m0123456789012345678901234567890123456789\x1b[32m".to_vec(),
            b"NEXT",
        ),
        (
            "origin mode inside margins with a saved cursor",
            b"r1\r\nr2\r\nr3\r\n\x1b[2;4H\x1b[4m\x1b7\x1b[0m\x1b[3;8r\x1b[?6h\x1b[2;5Hin".to_vec(),
            b"X\x1b8Y\x1b[1;1HZ",
        ),
        (
            "modes, tab stops, keyboard and synchronized output",
            b"\x1b[?1h\x1b=\x1b[?1002h\x1b[?1006h\x1b[?2004h\x1b[?25l\x1b[4h\x1b[?7l\x1b[>4;2m\x1b[3g\x1b[5G\x1bH\x1b[H\x1b[>1u\x1b[>5u\x1b[?2026htext".to_vec(),
            b"\tX\x1b[<u",
        ),
        (
            "character sets and protection",
            b"\x1b)0\x0eqqq\x1b[1\"qP".to_vec(),
            b"q\x0fq\x1b[0\"q",
        ),
        (
            "1049 alternate screen over a shell",
            [numbered(30), b"$ \x1b[H\x1b[2J$ vim\r\n\x1b[1;4r\x1b[?6h\x1b[2;2H\x1b[?1049h\x1b[?6l\x1b[r\x1b[?1h\x1b[H\x1b[2J\x1b[38;2;1;2;3mEditor\x1b[3;5H\x1b[>3u".to_vec()].concat(),
            b"\x1b[?1049lback\x1b[<u",
        ),
        (
            "47 alternate screen with saved cursors",
            b"\x1b[3;7H\x1b[4m\x1b7\x1b[0m$ top\x1b[?47h\x1b[2;1H01234567890123456789\x1b(0\x1b7\x1b(B\x1b[H".to_vec(),
            b"\x1b8q\x1b[?47l\x1b8Y",
        ),
        (
            "1047 alternate screen",
            b"one\r\ntwo\x1b[?1047h\x1b[2;2Halt\x1b[>1u".to_vec(),
            b"\x1b[?1047lX\x1b[<u",
        ),
        (
            "inactive alternate screen keyboard stack",
            b"\x1b[?1049h\x1b[>1u\x1b[>5u\x1b[?1049lprimary\x1b[>2u".to_vec(),
            b"\x1b[?1049h\x1b[<u\x1b[<u",
        ),
        (
            "wide cells holding a space",
            b"\x1b(0\xe4\xb8\xadqqq\x1b(B abc".to_vec(),
            b"\x1b[1;3HX",
        ),
    ]
}

#[test]
fn refresh_brings_a_fresh_renderer_to_the_current_screens() {
    for (name, setup, after) in refresh_cases() {
        let mut original = term(40, 8);
        original.feed(&setup);
        let refresh = original.refresh().unwrap();
        let mut copy = term(40, 8);
        copy.feed(&refresh);
        assert_same_screens(&original, &copy);
        assert!(copy.inspect().unwrap().history.is_empty(), "{name}");
        feed_both(&mut original, &mut copy, after);
        assert_same_screens(&original, &copy);
    }
}

#[test]
fn refresh_repaints_a_renderer_that_followed_the_session_in_place() {
    // A renderer that followed the session until some point, then missed
    // output that changed every kind of state: the refresh repaints it
    // without touching its history.
    for (name, setup, after) in refresh_cases() {
        let mut original = term(40, 8);
        original.feed(&numbered(50));
        original.feed(b"\x1b[?1049h\x1b[?1000h\x1b(0\x1b[5;7r\x1b[?6h\x1b[4h\x1b[>7u\x1b[45mstale\x1b[?1049l\x1b[?47h\x1b[1\"q\x1bVprot\x1bW\x1b]8;;https://stale\x1b\\\x1b[3;3r\x1b7");
        let mut copy = restored(&original);
        // The copy's primary history, read on its way back to the alternate
        // screen.
        copy.feed(b"\x1b[?47l");
        let history = copy.inspect().unwrap().history;
        assert_eq!(history.len(), 43);
        copy.feed(b"\x1b[?47h");
        original.feed(b"\x1b[?47l\x1b[?1049h\x1b[?1049l\x1bc");
        original.feed(&setup);
        let refresh = original.refresh().unwrap();
        for forbidden in [b"\x1bc".as_slice(), b"\x1b[3J", b"\x1b[2J"] {
            assert!(!contains(&refresh, forbidden), "{name}: {forbidden:?}");
        }
        copy.feed(&refresh);
        let copied = copy.inspect().unwrap();
        if !copied.alternate {
            assert_eq!(copied.history, history, "{name}");
        }
        assert_same_screens(&original, &copy);
        feed_both(&mut original, &mut copy, after);
        assert_same_screens(&original, &copy);
    }
}

#[test]
fn refresh_follows_a_resize_and_keeps_the_receivers_history() {
    // Both sides resized alike; the refresh fixes whatever the session
    // changed meanwhile. The history is the receiver's own.
    let mut original = Terminal::new(80, 24, 16 * 1024 * 1024).unwrap();
    styled_history(&mut original, 400);
    original.feed(b"$ \x1b[H\x1b[2J$ vim\r\n\x1b[?1049h\x1b[H\x1b[44m\x1b[2Jeditor\x1b[0m");
    let mut copy = replay(&original, &original.snapshot().unwrap());
    for (cols, rows) in [(60, 20), (100, 30)] {
        original.resize(cols, rows).unwrap();
        copy.resize(cols, rows).unwrap();
        original.feed(format!("\x1b[H\x1b[2J{cols}x{rows}\x1b[5;5H").as_bytes());
        let refresh = original.refresh().unwrap();
        // A small fraction of the full snapshot, which carries the history.
        let snapshot = original.snapshot().unwrap();
        assert!(
            refresh.len() * 20 < snapshot.len(),
            "{} vs {}",
            refresh.len(),
            snapshot.len()
        );
        let history = copy.inspect().unwrap().history;
        copy.feed(&refresh);
        assert_eq!(copy.inspect().unwrap().history, history);
        assert_same_screens(&original, &copy);
        feed_both(&mut original, &mut copy, b"\x1b[?1049l$ ");
        let (source, copied) = (original.inspect().unwrap(), copy.inspect().unwrap());
        assert_eq!(copied.active, source.active);
        assert_eq!(copied.cursor, source.cursor);
        feed_both(&mut original, &mut copy, b"\x1b[?1049h\x1b[H\x1b[2Jeditor");
    }
}

#[test]
fn refresh_leaves_host_reports_and_user_defaults_alone() {
    let mut original = term(20, 4);
    original.feed(b"\x1b[?2048h\x1b[?2033h\x1b[?1007l");
    let refresh = original.refresh().unwrap();
    for mode in private_modes(&refresh) {
        assert!(
            !matches!(
                mode.as_str(),
                "2048" | "2033" | "8" | "1035" | "1036" | "1039" | "2027"
            ),
            "?{mode} in {refresh:?}"
        );
    }
    assert!(contains(&refresh, b"\x1b[?1007l"));
    let mut renderer = term(20, 4);
    assert!(renderer.feed(&refresh).is_empty());
}

// Documented limits (README "Limits"), pinned so that restoring one of them
// also updates the README.

#[test]
fn hyperlink_ids_are_not_restored() {
    // Two links with one URI but different ids become one link.
    let mut original = term(20, 3);
    original.feed(b"\x1b]8;id=a;https://x\x1b\\ab\x1b]8;id=b;https://x\x1b\\cd\x1b]8;;\x1b\\");
    let snapshot = original.snapshot().unwrap();
    assert!(!contains(&snapshot, b"id="), "{snapshot:?}");
    assert!(
        contains(&snapshot, b"\x1b]8;;https://x\x1b\\abcd"),
        "{snapshot:?}"
    );
    assert_same(&original, &replay(&original, &snapshot));
}

#[test]
fn cursor_shape_is_not_restored_but_its_blink_is() {
    let mut original = term(20, 3);
    original.feed(b"\x1b[5 q");
    let snapshot = original.snapshot().unwrap();
    assert!(!contains(&snapshot, b" q"), "{snapshot:?}");
    assert!(contains(&snapshot, b"\x1b[?12h"), "{snapshot:?}");
}

#[test]
fn some_saved_cursor_state_is_not_restored() {
    // A pending wrap saved at a right margin inside the screen comes back
    // as the position alone.
    let mut original = term(20, 5);
    original.feed(b"\x1b[?69h\x1b[1;10s\x1b[2;1H0123456789\x1b7\x1b[s\x1b[?69l\x1b[H");
    let mut copy = restored(&original);
    assert_same(&original, &copy);
    feed_both(&mut original, &mut copy, b"\x1b8");
    let (original, copy) = (original.inspect().unwrap(), copy.inspect().unwrap());
    assert_eq!((original.cursor, copy.cursor), ((9, 1), (9, 1)));
    assert_eq!((original.pending_wrap, copy.pending_wrap), (true, false));

    // The same for the primary cursor 1049 saved.
    let mut original = term(20, 5);
    original.feed(b"\x1b[?69h\x1b[1;10s\x1b[2;1H0123456789\x1b[?1049h\x1b[s\x1b[?69l");
    let mut copy = restored(&original);
    assert_same(&original, &copy);
    feed_both(&mut original, &mut copy, b"\x1b[?1049l");
    let (original, copy) = (original.inspect().unwrap(), copy.inspect().unwrap());
    assert_eq!((original.cursor, copy.cursor), ((9, 1), (9, 1)));
    assert_eq!((original.pending_wrap, copy.pending_wrap), (true, false));

    // A slot the saved cursor designates comes back designated ASCII where
    // the live cursor has Ghostty's UTF-8 default; both print alike.
    let mut original = term(20, 5);
    original.feed(b"\x1b(0\x1b7\x1b[?47h\x1b8\x1b[?47l");
    let mut copy = restored(&original);
    let (source, copied) = (original.inspect().unwrap(), copy.inspect().unwrap());
    assert_eq!(copied.state, format!("{}␛(B", source.state));
    feed_both(&mut original, &mut copy, b"q\x1b8\x1b[2Cq");
    assert_eq!(
        copy.inspect().unwrap().active,
        original.inspect().unwrap().active
    );
    assert_eq!(copy.inspect().unwrap().active[0], "q·─");

    // The saved cursor of an inactive alternate screen is not kept.
    let mut original = term(20, 5);
    original.feed(b"\x1b[?47h\x1b[3;3H\x1b7\x1b[?47l\x1b[H");
    let mut copy = restored(&original);
    assert_same(&original, &copy);
    feed_both(&mut original, &mut copy, b"\x1b[?47h\x1b8");
    let (original, copy) = (original.inspect().unwrap(), copy.inspect().unwrap());
    assert_eq!((original.cursor, copy.cursor), ((2, 2), (0, 0)));
}

#[test]
fn a_pending_wrap_away_from_the_edge_keeps_only_its_position() {
    // Ghostty keeps a pending wrap when the terminal widens under it; no
    // edge holds it on the replay, so only the position comes back.
    let mut original = term(12, 3);
    original.feed(b"abcdefghijkl");
    original.resize(15, 3).unwrap();
    let copy = restored(&original).inspect().unwrap();
    let source = original.inspect().unwrap();
    assert_eq!((source.cursor, source.pending_wrap), ((11, 0), true));
    assert_eq!((copy.cursor, copy.pending_wrap), ((11, 0), false));
    assert_eq!(copy.active, source.active);
}

#[test]
fn oldest_history_row_is_replayed_as_a_line_start() {
    // Scrollback pruning left the tail of a long line at the top of history.
    let mut original = Terminal::new(20, 5, 64 * 1024).unwrap();
    original.feed(b"$ cat blob\r\n");
    original.feed(&vec![b'x'; 20 * 20_000]);
    original.feed(b"\r\n$ ");
    let source = original.inspect().unwrap();
    assert!(
        source.history[0].starts_with('↪'),
        "{:?}",
        source.history[0]
    );
    let copy = restored(&original).inspect().unwrap();
    let mut expected = source.clone();
    expected.history[0] = expected.history[0].trim_start_matches('↪').to_owned();
    assert_eq!(copy, expected);
}

fn notification(title: &str, body: &str) -> VtEvent {
    VtEvent::Notification {
        title: title.into(),
        body: body.into(),
    }
}

/// Output that makes a program's terminal report one of each event.
const EVENTFUL: &[u8] = b"\x1b]2;building\x07\
    \x1b]7;file://studio/Users/me/My%20Code\x1b\\\
    ready\x07\
    \x1b]9;tests passed\x07\
    \x1b]777;notify;Build;finished in 3s\x1b\\\
    \x1b]9;4;1;42\x07\
    \x1b]9;4;3\x07";

fn eventful() -> Vec<VtEvent> {
    vec![
        VtEvent::Title("building".into()),
        VtEvent::Pwd("file://studio/Users/me/My%20Code".into()),
        VtEvent::Bell,
        notification("", "tests passed"),
        notification("Build", "finished in 3s"),
        VtEvent::Progress {
            state: ProgressState::Set,
            value: Some(42),
        },
        VtEvent::Progress {
            state: ProgressState::Indeterminate,
            value: None,
        },
    ]
}

#[test]
fn titles_directories_bells_notifications_and_progress_are_events() {
    let mut terminal = term(40, 5);
    assert!(terminal.take_events().is_empty());
    // Events never make the terminal reply.
    assert!(terminal.feed(EVENTFUL).is_empty());
    let mut expected = eventful();
    // The second progress report replaced the first: nothing came between.
    expected.remove(5);
    assert_eq!(terminal.take_events(), expected);
    assert!(terminal.take_events().is_empty());
    assert_eq!(terminal.inspect().unwrap().active[0], "ready");
    // Replies still flow beside them.
    assert_eq!(terminal.feed(b"\x07\x1b[5n"), b"\x1b[0n");
    assert_eq!(terminal.take_events(), [VtEvent::Bell]);
}

#[test]
fn events_split_across_reads_are_reported_once_complete() {
    let mut whole = term(40, 5);
    whole.feed(EVENTFUL);
    let expected = whole.take_events();
    let mut collapsed = eventful();
    collapsed.remove(5);
    assert_eq!(expected, collapsed);
    for size in [1, 2, 3, 7] {
        let mut terminal = term(40, 5);
        let mut events = Vec::new();
        for chunk in EVENTFUL.chunks(size) {
            assert!(terminal.feed(chunk).is_empty(), "{size}: {chunk:?}");
            events.extend(terminal.take_events());
        }
        // Taken between reads, both progress reports are seen.
        assert_eq!(events, eventful(), "{size}");
    }
    // Nothing is reported for a sequence that has not ended.
    let mut terminal = term(40, 5);
    terminal.feed(b"\x1b]2;half");
    assert!(terminal.take_events().is_empty());
    terminal.feed(b" done");
    assert!(terminal.take_events().is_empty());
    assert_eq!(terminal.title(), None);
    terminal.feed(b"\x1b\\");
    assert_eq!(terminal.take_events(), [VtEvent::Title("half done".into())]);
}

#[test]
fn title_and_working_directory_follow_the_program() {
    let mut terminal = term(40, 5);
    assert_eq!((terminal.title(), terminal.pwd()), (None, None));
    terminal.feed(b"\x1b]0;vim \xe2\x80\x94 main.rs\x07");
    assert_eq!(terminal.title().as_deref(), Some("vim \u{2014} main.rs"));
    terminal.feed(b"\x1b]7;file://studio/tmp\x07");
    assert_eq!(terminal.pwd().as_deref(), Some("file://studio/tmp"));
    terminal.feed(b"\x1b]1337;CurrentDir=/Users/me\x07");
    assert_eq!(terminal.pwd().as_deref(), Some("/Users/me"));
    terminal.feed(b"\x1b]9;9;/opt/work\x07");
    assert_eq!(terminal.pwd().as_deref(), Some("/opt/work"));
    assert_eq!(
        terminal.take_events(),
        [
            VtEvent::Title("vim \u{2014} main.rs".into()),
            VtEvent::Pwd("/opt/work".into()),
        ]
    );
    // The icon name is not the title, and a title that is not UTF-8 is
    // ignored.
    terminal.feed(b"\x1b]1;icon\x07\x1b]2;bad \xff\x07");
    assert_eq!(terminal.title().as_deref(), Some("vim \u{2014} main.rs"));
    assert!(terminal.take_events().is_empty());
    // Clearing them.
    terminal.feed(b"\x1b]2;\x07\x1b]7;\x07");
    assert_eq!((terminal.title(), terminal.pwd()), (None, None));
    assert_eq!(
        terminal.take_events(),
        [VtEvent::Title(String::new()), VtEvent::Pwd(String::new())]
    );
    // A value set again unchanged is not reported again.
    terminal.feed(b"\x1b]2;prompt\x07\x1b]7;file://studio/tmp\x07");
    terminal.take_events();
    terminal.feed(b"\x1b]2;prompt\x07\x1b]7;file://studio/tmp\x07\x1b]2;prompt\x07");
    assert!(terminal.take_events().is_empty());
    // Titles are cut to 1024 bytes.
    terminal.feed(format!("\x1b]2;{}\x07", "t".repeat(1500)).as_bytes());
    assert_eq!(terminal.title().unwrap().len(), 1024);
    assert!(matches!(&terminal.take_events()[..], [VtEvent::Title(title)] if title.len() == 1024));
    // A reset clears both without a callback; that is reported too, after
    // the progress report a reset makes.
    terminal.feed(b"\x1b]7;file://studio/tmp\x07");
    terminal.take_events();
    terminal.feed(b"\x1bc");
    assert_eq!((terminal.title(), terminal.pwd()), (None, None));
    assert_eq!(
        terminal.take_events(),
        [
            VtEvent::Progress {
                state: ProgressState::Remove,
                value: None
            },
            VtEvent::Title(String::new()),
            VtEvent::Pwd(String::new()),
        ]
    );
    terminal.feed(b"\x1b]2;tt\x07");
    assert_eq!(terminal.take_events(), [VtEvent::Title("tt".into())]);
}

#[test]
fn progress_reports_carry_their_state_and_percentage() {
    let mut terminal = term(40, 5);
    let mut report = |sequence: &[u8]| {
        terminal.feed(sequence);
        terminal.take_events()
    };
    for (sequence, state, value) in [
        (&b"\x1b]9;4;1;50\x07"[..], ProgressState::Set, Some(50)),
        (b"\x1b]9;4;1\x07", ProgressState::Set, Some(0)),
        (b"\x1b]9;4;1;250\x07", ProgressState::Set, Some(100)),
        (b"\x1b]9;4;2;75\x1b\\", ProgressState::Error, Some(75)),
        (b"\x1b]9;4;2\x07", ProgressState::Error, None),
        (b"\x1b]9;4;3\x07", ProgressState::Indeterminate, None),
        (b"\x1b]9;4;4;10\x07", ProgressState::Pause, Some(10)),
        (b"\x1b]9;4;0\x07", ProgressState::Remove, None),
    ] {
        assert_eq!(
            report(sequence),
            [VtEvent::Progress { state, value }],
            "{sequence:?}"
        );
    }
    // Upstream takes an unknown state for a plain OSC 9 notification.
    assert_eq!(report(b"\x1b]9;4;9;1\x07"), [notification("", "4;9;1")]);
}

#[test]
fn bursts_collapse_and_pending_events_are_bounded() {
    let mut terminal = term(40, 5);
    terminal.feed(&[0x07; 10_000]);
    terminal.feed(b"\x1b]2;a\x07\x1b]2;b\x07\x1b]2;c\x07");
    assert_eq!(
        terminal.take_events(),
        [VtEvent::Bell, VtEvent::Title("c".into())]
    );
    // Notifications are each kept, up to the bound; the oldest go first.
    let count = MAX_PENDING_EVENTS + 44;
    for n in 0..count {
        terminal.feed(format!("\x1b]9;note {n}\x07").as_bytes());
    }
    let events = terminal.take_events();
    assert_eq!(events.len(), MAX_PENDING_EVENTS);
    assert_eq!(events[0], notification("", "note 44"));
    assert_eq!(
        events.last(),
        Some(&notification("", &format!("note {}", count - 1)))
    );
    // So is their text.
    let body = "x".repeat(2000);
    for _ in 0..MAX_PENDING_EVENTS {
        terminal.feed(format!("\x1b]777;notify;t;{body}\x07").as_bytes());
    }
    let events = terminal.take_events();
    assert_eq!(events.len(), MAX_PENDING_EVENT_BYTES / 2001);
    // A terminal whose events nobody takes stays bounded (besides the
    // state kept apart, below).
    for _ in 0..4 {
        terminal.feed(&EVENTFUL.repeat(500));
    }
    assert!(terminal.take_events().len() <= MAX_PENDING_EVENTS + 3);
}

#[test]
fn the_bound_never_loses_the_current_title_directory_or_progress() {
    let flood = |terminal: &mut Terminal, from: usize| {
        for n in from..from + MAX_PENDING_EVENTS + 44 {
            terminal.feed(format!("\x1b]9;note {n}\x07").as_bytes());
        }
    };
    let mut terminal = term(40, 5);
    terminal.feed(b"\x1b]2;keep\x07\x1b]9;4;1;30\x07\x1b]7;file://studio/tmp\x07");
    flood(&mut terminal, 0);
    let events = terminal.take_events();
    // Kept apart in order, ahead of what the bound left.
    assert_eq!(
        events[..4],
        [
            VtEvent::Title("keep".into()),
            VtEvent::Progress {
                state: ProgressState::Set,
                value: Some(30)
            },
            VtEvent::Pwd("file://studio/tmp".into()),
            notification("", "note 44"),
        ]
    );
    assert_eq!(events.len(), MAX_PENDING_EVENTS + 3);
    // Taken, they are known: set again unchanged, they are not reported.
    terminal.feed(b"\x1b]2;keep\x07\x1b]7;file://studio/tmp\x07");
    assert!(terminal.take_events().is_empty());
    // Only the latest of a kind is kept, and one still waiting in its
    // place supersedes nothing kept apart before it.
    terminal.feed(b"\x1b]2;one\x07");
    flood(&mut terminal, 0);
    terminal.feed(b"\x1b]2;two\x07");
    flood(&mut terminal, 1000);
    terminal.feed(b"\x1b]2;three\x07");
    let events = terminal.take_events();
    let titles: Vec<_> = events
        .iter()
        .filter(|event| matches!(event, VtEvent::Title(_)))
        .collect();
    assert_eq!(
        titles,
        [
            &VtEvent::Title("two".into()),
            &VtEvent::Title("three".into())
        ]
    );
    assert_eq!(events[0], VtEvent::Title("two".into()));
    assert_eq!(events.last(), Some(&VtEvent::Title("three".into())));
    // A reset after a flood reports the cleared values; nothing stale.
    terminal.feed(b"\x1b]2;four\x07");
    flood(&mut terminal, 0);
    terminal.feed(b"\x1bc");
    let events = terminal.take_events();
    assert_eq!(events[0], VtEvent::Title("four".into()));
    assert_eq!(
        events[events.len() - 3..],
        [
            VtEvent::Progress {
                state: ProgressState::Remove,
                value: None
            },
            VtEvent::Title(String::new()),
            VtEvent::Pwd(String::new()),
        ]
    );
}

#[test]
fn snapshots_resizes_and_inspection_report_no_events() {
    let mut terminal = term(40, 5);
    terminal.feed(EVENTFUL);
    terminal.feed(b"\x1b[?1049h\x1b]2;vim\x07\x07");
    terminal.take_events();
    let snapshot = terminal.snapshot().unwrap();
    terminal.refresh().unwrap();
    terminal.snapshot_limited(1024 * 1024).unwrap();
    terminal.viewport(20, 3).unwrap();
    terminal.modes().unwrap();
    terminal.inspect().unwrap();
    terminal.screen_text().unwrap();
    assert!(terminal.resize(30, 4).unwrap().is_empty());
    assert!(terminal.take_events().is_empty());
    assert_eq!(terminal.title().as_deref(), Some("vim"));
    // A snapshot carries neither title nor working directory: its replay
    // reports only what its reset does.
    let mut copy = replay(&terminal, &snapshot);
    assert_eq!(
        copy.take_events(),
        [VtEvent::Progress {
            state: ProgressState::Remove,
            value: None
        }]
    );
    assert_eq!((copy.title(), copy.pwd()), (None, None));
}

#[test]
fn kitty_notifications_are_left_to_osc99() {
    // libghostty-vt drops OSC 99.
    let sequence = b"\x1b]99;;Hello world\x1b\\";
    let mut terminal = term(40, 5);
    assert!(terminal.feed(sequence).is_empty());
    assert!(terminal.take_events().is_empty());
    assert_eq!(parse_osc99(sequence), Some(notification("Hello world", "")));
    assert_eq!(
        parse_osc99(b"\x1b]99;i=1:p=body;done; really\x07"),
        Some(notification("", "done; really"))
    );
    assert_eq!(
        parse_osc99(b"\x1b]99;e=1;SGVsbG8g4pyT\x07"),
        Some(notification("Hello \u{2713}", ""))
    );
    for sequence in [
        &b"\x1b]99;p=?;\x1b\\"[..],
        b"\x1b]99;i=1:p=close;\x1b\\",
        b"\x1b]99;i=1:p=icon;abc\x1b\\",
        b"\x1b]99;i=1:d=0;chunk\x1b\\",
        b"\x1b]99;;\x1b\\",
        b"\x1b]99;e=1;not base64!\x07",
        b"\x1b]99;no payload\x07",
        b"\x1b]99;;unterminated",
        b"\x1b]9;not kitty\x07",
        b"99;;bare\x07",
    ] {
        assert_eq!(parse_osc99(sequence), None, "{sequence:?}");
    }
}

#[test]
fn osc99_assembles_notifications_sent_in_chunks() {
    let mut osc99 = Osc99::default();
    let mut feed = |sequence: &str| osc99.feed(sequence.as_bytes());
    assert_eq!(feed("\x1b]99;i=1:d=0;Hello \x1b\\"), None);
    // Another notification is assembled meanwhile.
    assert_eq!(feed("\x1b]99;i=two:d=0:p=body;second body\x1b\\"), None);
    assert_eq!(feed("\x1b]99;i=1:d=0;world\x1b\\"), None);
    assert_eq!(
        feed("\x1b]99;i=1:p=body:u=2;This is cool\x1b\\"),
        Some(notification("Hello world", "This is cool"))
    );
    // Base64 chunks join as bytes, so a character may span them.
    assert_eq!(feed("\x1b]99;i=two:d=0:e=1:p=body;4g==\x1b\\"), None);
    assert_eq!(
        feed("\x1b]99;i=two:e=1:p=body;nJM\x1b\\"),
        Some(notification("", "second body\u{2713}"))
    );
    // A finished notification is forgotten.
    assert_eq!(
        feed("\x1b]99;i=1;again\x07"),
        Some(notification("again", ""))
    );
    // Without an identifier, chunks join too.
    assert_eq!(feed("\x1b]99;d=0;one \x07"), None);
    assert_eq!(feed("\x1b]99;;two\x07"), Some(notification("one two", "")));
    // A chunk whose payload is not reported (an icon, buttons, a type this
    // does not know) may end the notification.
    assert_eq!(feed("\x1b]99;i=1:d=0;Title\x1b\\"), None);
    assert_eq!(feed("\x1b]99;i=1:d=0:p=body;Body\x1b\\"), None);
    assert_eq!(
        feed("\x1b]99;i=1:p=icon:e=1;aWNvbg==\x1b\\"),
        Some(notification("Title", "Body"))
    );
    // So the next one with that identifier starts afresh.
    assert_eq!(feed("\x1b]99;i=1;New\x07"), Some(notification("New", "")));
    assert_eq!(feed("\x1b]99;i=2:d=0;T2\x07"), None);
    // Its payload is never decoded, so it cannot be malformed.
    assert_eq!(feed("\x1b]99;i=2:d=0:p=icon:e=1;not base64!\x07"), None);
    assert_eq!(
        feed("\x1b]99;i=2:p=later;what\x07"),
        Some(notification("T2", ""))
    );
    assert_eq!(feed("\x1b]99;i=3:d=0;T3\x07"), None);
    assert_eq!(
        feed("\x1b]99;i=3:p=buttons;Yes\u{2028}No\x07"),
        Some(notification("T3", ""))
    );
    // Requests about notifications leave one being assembled alone.
    assert_eq!(feed("\x1b]99;i=4:d=0;T4\x07"), None);
    for request in ["?", "close", "alive"] {
        assert_eq!(feed(&format!("\x1b]99;i=4:p={request};\x07")), None);
    }
    assert_eq!(
        feed("\x1b]99;i=4:p=body;B4\x07"),
        Some(notification("T4", "B4"))
    );
    // Bounded: forgotten oldest first, and cut at 64 KiB.
    for n in 0..20 {
        assert_eq!(feed(&format!("\x1b]99;i=n{n}:d=0;{n}\x07")), None);
    }
    assert_eq!(feed("\x1b]99;i=n0;!\x07"), Some(notification("!", "")));
    assert_eq!(feed("\x1b]99;i=n19;!\x07"), Some(notification("19!", "")));
    let chunk = "y".repeat(2048);
    for _ in 0..40 {
        feed(&format!("\x1b]99;i=big:d=0;{chunk}\x07"));
    }
    match feed("\x1b]99;i=big:p=body;end\x07") {
        Some(VtEvent::Notification { title, body }) => {
            assert_eq!((title.len(), body.as_str()), (64 * 1024, ""));
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn modes_read_as_the_terminal_holds_them() {
    let mut terminal = term(20, 5);
    assert!(!terminal.mode(1, false).unwrap());
    assert!(
        terminal.mode(7, false).unwrap(),
        "autowrap is on by default"
    );
    terminal.feed(b"\x1b[?1h\x1b[4h");
    assert!(terminal.mode(1, false).unwrap());
    assert!(terminal.mode(4, true).unwrap());
    assert!(!terminal.mode(4, false).unwrap(), "?4 is not ANSI 4");
    // Terminal-wide: switching screens keeps it.
    terminal.feed(b"\x1b[?1049h");
    assert!(terminal.mode(1, false).unwrap());
    terminal.feed(b"\x1b[?1049l");
    assert!(terminal.mode(1, false).unwrap());
    // Split across reads, it applies once it ends.
    terminal.feed(b"\x1b[?");
    assert!(terminal.mode(1, false).unwrap());
    terminal.feed(b"1l");
    assert!(!terminal.mode(1, false).unwrap());
    // A reset clears it.
    terminal.feed(b"\x1b[?1h\x1bc");
    assert!(!terminal.mode(1, false).unwrap());
    // It agrees with what snapshots carry.
    terminal.feed(b"\x1b[?1h");
    assert!(terminal
        .inspect()
        .unwrap()
        .modes
        .contains(&"?1h".to_string()));
    assert!(restored(&terminal).mode(1, false).unwrap());
}

#[test]
fn grapheme_clustering_is_on_by_default_and_a_reset_keeps_it() {
    let mut terminal = term(20, 5);
    assert!(terminal.mode(2027, false).unwrap());
    terminal.feed(b"\x1b[?2027l");
    assert!(!terminal.mode(2027, false).unwrap());
    // RIS restores this terminal's default, as Ghostty's does.
    terminal.feed(b"\x1bc");
    assert!(terminal.mode(2027, false).unwrap());
    // A session's own choice travels with its snapshot either way.
    terminal.feed(b"\x1b[?2027l");
    assert!(!restored(&terminal).mode(2027, false).unwrap());
    terminal.feed(b"\x1b[?2027h");
    assert!(restored(&terminal).mode(2027, false).unwrap());
}

#[test]
fn emoji_rows_restore_aligned_into_a_terminal_with_grapheme_clustering_on() {
    // What the app's terminal (Ghostty, grapheme clustering on) makes of
    // these rows: a ZWJ family, a flag, a skin tone and a combining accent
    // are one cluster each, two cells wide (the accent one), so the marker
    // after each lands where the tab's own terminal puts it.
    let rows: [(&str, u16); 4] = [
        ("👨\u{200d}👩\u{200d}👧|", 2),
        ("🇯🇵|", 2),
        ("👍🏽|", 2),
        ("e\u{301}|", 1),
    ];
    for (row, marker) in rows {
        let mut original = term(20, 4);
        original.feed(row.as_bytes());
        assert_eq!(
            original.cursor().unwrap().x,
            marker + 1,
            "{row:?} as the host's terminal lays it out"
        );
        // Replayed into a renderer with grapheme clustering on (a snapshot
        // on reattach), every cell lines up, and so does what follows.
        let mut copy = restored(&original);
        assert_eq!(copy.cursor().unwrap().x, marker + 1, "{row:?}");
        assert_same(&original, &copy);
        feed_both(&mut original, &mut copy, "after 🍒\r\n".as_bytes());
        assert_same(&original, &copy);
    }
    // Several such rows in the history, restored in one snapshot.
    let mut original = term(12, 3);
    for _ in 0..6 {
        original.feed("👨\u{200d}👩\u{200d}👧 🇯🇵 👍🏽 é|\r\n".as_bytes());
    }
    let copy = restored(&original);
    assert_same(&original, &copy);
    assert!(copy.mode(2027, false).unwrap());
}

#[test]
fn colour_queries_report_the_colours_the_terminal_was_given() {
    let mut terminal = term(20, 5);
    // The defaults: light grey on black, dark.
    let replies = terminal.feed(b"\x1b]10;?\x07\x1b]11;?\x07\x1b]12;?\x07\x1b[?996n");
    let replies = String::from_utf8(replies).unwrap();
    assert!(
        replies.contains("\x1b]10;rgb:e5e5/e5e5/e5e5"),
        "{replies:?}"
    );
    assert!(
        replies.contains("\x1b]11;rgb:0000/0000/0000"),
        "{replies:?}"
    );
    assert!(
        replies.contains("\x1b]12;rgb:e5e5/e5e5/e5e5"),
        "{replies:?}"
    );
    assert!(replies.contains("\x1b[?997;1n"), "{replies:?}");

    terminal
        .set_colors(Colors {
            foreground: [0x1f, 0x23, 0x28],
            background: [0xff, 0xfe, 0xfd],
            cursor: [0x12, 0x34, 0x56],
            light: true,
        })
        .unwrap();
    let replies = terminal.feed(b"\x1b]10;?\x07\x1b]11;?\x07\x1b]12;?\x07\x1b[?996n");
    let replies = String::from_utf8(replies).unwrap();
    assert!(
        replies.contains("\x1b]10;rgb:1f1f/2323/2828"),
        "{replies:?}"
    );
    assert!(
        replies.contains("\x1b]11;rgb:ffff/fefe/fdfd"),
        "{replies:?}"
    );
    assert!(
        replies.contains("\x1b]12;rgb:1212/3434/5656"),
        "{replies:?}"
    );
    assert!(replies.contains("\x1b[?997;2n"), "{replies:?}");
    // A reset keeps them: they are the terminal's defaults.
    let replies = terminal.feed(b"\x1bc\x1b]11;?\x07\x1b[?996n");
    let replies = String::from_utf8(replies).unwrap();
    assert!(
        replies.contains("\x1b]11;rgb:ffff/fefe/fdfd"),
        "{replies:?}"
    );
    assert!(replies.contains("\x1b[?997;2n"), "{replies:?}");
}

#[test]
fn clearing_history_keeps_the_screen_and_an_unfinished_sequence() {
    let mut terminal = term(20, 3);
    terminal.feed(&numbered(10));
    terminal.feed(b"$ \x1b[3");
    assert!(!terminal.inspect().unwrap().history.is_empty());
    let screen = terminal.inspect().unwrap().active;
    assert!(terminal.clear_history().unwrap());
    let cleared = terminal.inspect().unwrap();
    assert!(cleared.history.is_empty(), "{:?}", cleared.history);
    assert_eq!(cleared.active, screen);
    assert!(!terminal.screen_text().unwrap().contains("output line 0"));
    // The SGR the output had begun still applies once it ends.
    terminal.feed(b"1mred");
    let row = terminal.inspect().unwrap().active[2].clone();
    assert!(row.contains("red") && !row.contains("1mred"), "{row:?}");
    let mut plain = term(20, 3);
    plain.feed(b"\r\n\r\n$ \x1b[31mred");
    assert_eq!(row, plain.inspect().unwrap().active[2]);
    // A snapshot carries no history now.
    assert!(restored(&terminal).inspect().unwrap().history.is_empty());
    // New output scrolls into a history of its own.
    terminal.feed(&numbered(5));
    assert!(!terminal.inspect().unwrap().history.is_empty());

    // A UTF-8 character split across the clear (`─` is E2 94 80) is not
    // broken: the history goes once the output completes it.
    let mut terminal = term(20, 3);
    terminal.feed(&numbered(10));
    terminal.feed(b"$ a\xe2\x94");
    assert!(!terminal.clear_history().unwrap());
    terminal.feed(b"\x80b");
    let cleared = terminal.inspect().unwrap();
    assert!(cleared.history.is_empty(), "{:?}", cleared.history);
    let mut plain = term(20, 3);
    plain.feed(&numbered(10));
    plain.feed("$ a─b".as_bytes());
    assert_eq!(cleared.active, plain.inspect().unwrap().active);
    assert_eq!(terminal.cursor().unwrap().x, plain.cursor().unwrap().x);
    assert!(!terminal.screen_text().unwrap().contains('\u{fffd}'));
}
