//! Protocol behaviour of attached clients: snapshots, output, input, sizes.
mod support;

use cherry_protocol::*;
use cherry_vt::Terminal;
use std::{
    collections::BTreeMap,
    fs,
    io::Write,
    os::unix::net::UnixStream,
    thread,
    time::{Duration, Instant},
};
use support::*;
use uuid::Uuid;

#[test]
fn disconnect_preserves_process_and_reattach_restores_screen_and_input() {
    let host = Host::new();
    let session = host.create(vec!["/bin/sh".into()]);
    let (mut first, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    // The command line echoes `CHERRY_%s`; only its output joins the words.
    input(&mut first, b"printf 'CHERRY_%s\\n' PERSISTED\r");
    screen.wait_text(&mut first, "CHERRY_PERSISTED");
    drop(first);
    let detached = host.wait(&session.id, |s| !s.attached);
    assert_eq!(detached.pid, session.pid);
    assert_eq!(detached.state, SessionState::Running);
    let (mut second, resumed, offset, snapshot) = host.attach(&session.id, 100, 30);
    assert_eq!(resumed.pid, session.pid);
    assert_eq!((resumed.cols, resumed.rows), (100, 30));
    let mut screen = Screen::new(100, 30, offset, &snapshot);
    assert!(screen.text().contains("CHERRY_PERSISTED"));
    input(&mut second, b"printf 'AFTER_%s\\n' RECONNECT; exit 7\r");
    assert_eq!(screen.wait_exit(&mut second), (7, None));
    assert!(screen.text().contains("AFTER_RECONNECT"));
    let exited = host.wait(&session.id, |s| s.state == SessionState::Exited);
    assert_eq!(exited.exit_code, Some(7));
    assert_eq!(exited.exit_signal, None);
}

#[test]
fn create_retries_are_idempotent_whatever_the_terminal_size() {
    let host = Host::new();
    let request_id = Uuid::new_v4().to_string();
    let request = |cols, rows, command: &str| ClientMessage::Create {
        request_id: request_id.clone(),
        name: "retry".into(),
        cwd: "/tmp".into(),
        command: shell(command),
        env: BTreeMap::new(),
        cols,
        rows,
    };
    let a = match host.call(request(80, 24, "sleep 60")) {
        ServerMessage::Created { session } => session,
        other => panic!("{other:?}"),
    };
    // Retried from a resized terminal: still the same launch.
    let b = match host.call(request(132, 40, "sleep 60")) {
        ServerMessage::Created { session } => session,
        other => panic!("{other:?}"),
    };
    assert_eq!(a.id, b.id);
    assert_eq!(a.pid, b.pid);
    assert_eq!(host.sessions().len(), 1);
    // Reusing the request for something else is refused.
    match host.call(request(80, 24, "sleep 61")) {
        ServerMessage::Error { code, message } => {
            assert_eq!(code, "request_failed");
            assert!(message.contains("different launch"), "{message}");
        }
        other => panic!("{other:?}"),
    }
    let (_first, _, _, _) = host.attach(&a.id, 80, 24);
    let (_second, shared, _, _) = host.attach(&a.id, 80, 24);
    assert_eq!(shared.pid, a.pid);
    assert!(matches!(
        host.call(ClientMessage::Shutdown),
        ServerMessage::Error { .. }
    ));
    host.kill(&a.id);
    host.wait(&a.id, |s| s.state == SessionState::Exited);
    // Removing the session forgets its receipt.
    assert!(matches!(
        host.call(ClientMessage::Remove { id: a.id.clone() }),
        ServerMessage::Ok
    ));
    let c = match host.call(request(80, 24, "sleep 60")) {
        ServerMessage::Created { session } => session,
        other => panic!("{other:?}"),
    };
    assert_ne!(c.id, a.id);
    host.kill(&c.id);
}

#[test]
fn takeover_moves_live_session_without_restarting_or_accepting_stale_input() {
    let host = Host::new();
    let session = host.create(shell(
        "stty -echo; printf 'ORIGINAL_SCREEN\\n'; while IFS= read -r line; do printf 'INPUT:%s\\n' \"$line\"; stty size; done",
    ));
    let (mut first, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut original = Screen::new(80, 24, offset, &snapshot);
    original.wait_text(&mut first, "ORIGINAL_SCREEN");

    let (mut second, resumed, offset, snapshot) =
        host.attach_with_takeover(&session.id, 100, 30, true);
    assert_eq!(resumed.id, session.id);
    assert_eq!(resumed.pid, session.pid);
    assert_eq!(resumed.state, SessionState::Running);
    assert_eq!((resumed.cols, resumed.rows), (100, 30));
    let mut screen = Screen::new(100, 30, offset, &snapshot);
    assert!(screen.text().contains("ORIGINAL_SCREEN"));

    // The old peer receives a useful terminal diagnostic and EOF. An input or
    // detach racing its cleanup can neither reach the PTY nor revoke the new
    // controller. Socket closure can reject these writes before protocol read.
    let _ = write_frame(
        &mut first,
        &ClientMessage::Input {
            data: b"STALE_INPUT\n".to_vec(),
        },
    );
    let _ = write_frame(&mut first, &ClientMessage::Detach);
    loop {
        match receive(&mut first) {
            ServerMessage::Error { code, message } => {
                assert_eq!(code, "taken_over");
                assert!(message.contains("still running"));
                break;
            }
            ServerMessage::Output { .. } => {}
            other => panic!("unexpected old controller reply: {other:?}"),
        }
    }
    assert!(read_frame::<_, ServerMessage>(&mut first)
        .unwrap()
        .is_none());
    drop(first);
    assert!(host.wait(&session.id, |s| s.attached).attached);

    send(&mut second, &ClientMessage::Resize { cols: 90, rows: 28 });
    screen.wait_size(&mut second, 90, 28);
    input(&mut second, b"NEW_CONTROLLER\n");
    screen.wait_text(&mut second, "INPUT:NEW_CONTROLLER");
    screen.wait_text(&mut second, "28 90");
    assert!(!screen.text().contains("STALE_INPUT"));
    let current = host.wait(&session.id, |s| s.cols == 90 && s.rows == 28);
    assert_eq!(current.pid, session.pid);
    assert!(current.attached);
    let (_third, shared, _, _) = host.attach(&session.id, 90, 28);
    assert_eq!(shared.pid, session.pid);
}

#[test]
fn shared_attachments_both_type_and_resize_to_smallest_client_until_detach() {
    let host = Host::new();
    let session = host.create(shell(
        "stty -echo; printf 'READY\\n'; while IFS= read -r line; do printf 'INPUT:%s\\n' \"$line\"; stty size; done",
    ));
    let (mut first, _, offset, snapshot) = host.attach(&session.id, 100, 30);
    let mut screen1 = Screen::new(100, 30, offset, &snapshot);
    screen1.wait_text(&mut first, "READY");
    let (mut second, info, offset, snapshot) = host.attach(&session.id, 80, 24);
    assert_eq!(info.pid, session.pid);
    assert_eq!((info.cols, info.rows), (80, 24));
    let mut screen2 = Screen::new(80, 24, offset, &snapshot);
    screen1.wait_size(&mut first, 80, 24);
    assert_eq!(screen1.attached, vec![AttachReason::Resize]);
    assert_eq!(screen1.offset, screen2.offset);
    assert_eq!(screen1.text(), screen2.text());

    input(&mut first, b"FROM_FIRST\n");
    screen1.wait_text(&mut first, "24 80");
    screen2.wait_text(&mut second, "24 80");
    assert!(screen1.text().contains("INPUT:FROM_FIRST"));
    assert_eq!(screen1.text(), screen2.text());
    input(&mut second, b"FROM_SECOND\n");
    screen1.wait_text(&mut first, "INPUT:FROM_SECOND");
    screen2.wait_text(&mut second, "INPUT:FROM_SECOND");

    // Each requested size is retained. Growing the smaller client grows the
    // shared PTY only as far as the other client's dimensions.
    send(
        &mut second,
        &ClientMessage::Resize {
            cols: 120,
            rows: 40,
        },
    );
    screen1.wait_size(&mut first, 100, 30);
    screen2.wait_size(&mut second, 100, 30);
    assert_eq!(screen1.offset, screen2.offset);
    assert_eq!(screen1.text(), screen2.text());

    send(&mut first, &ClientMessage::Detach);
    loop {
        if matches!(receive(&mut first), ServerMessage::Ok) {
            break;
        }
    }
    assert!(read_frame::<_, ServerMessage>(&mut first)
        .unwrap()
        .is_none());
    drop(first);
    screen2.wait_size(&mut second, 120, 40);
    input(&mut second, b"STILL_RUNNING\n");
    screen2.wait_text(&mut second, "INPUT:STILL_RUNNING");
    screen2.wait_text(&mut second, "40 120");
    let info = host.wait(&session.id, |s| s.cols == 120 && s.rows == 40);
    assert_eq!(info.pid, session.pid);
    assert!(info.attached);
    drop(second);
    let info = host.wait(&session.id, |s| !s.attached);
    assert_eq!(info.state, SessionState::Running);
}

#[test]
fn rapid_resizes_are_coalesced_into_one_snapshot() {
    let host = Host::new();
    let session = host.create(shell("exec sleep 60"));
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 100, 30);
    let mut screen = Screen::new(100, 30, offset, &snapshot);
    // Like a window drag: one step every 10 ms.
    for step in 0..20u16 {
        send(
            &mut socket,
            &ClientMessage::Resize {
                cols: 80 + step,
                rows: 20 + step,
            },
        );
        thread::sleep(Duration::from_millis(10));
    }
    screen.wait_size(&mut socket, 99, 39);
    // Nothing else follows once the size has settled.
    socket
        .set_read_timeout(Some(Duration::from_millis(400)))
        .unwrap();
    while let Ok(Some(message)) = read_frame::<_, ServerMessage>(&mut socket) {
        screen.apply(&message);
    }
    assert!(
        screen.attached.len() <= 2,
        "{} snapshots for one drag",
        screen.attached.len()
    );
    assert_eq!((screen.cols, screen.rows), (99, 39));
    let info = host.session(&session.id);
    assert_eq!((info.cols, info.rows), (99, 39));
}

#[test]
fn a_lagging_client_is_resynchronized_instead_of_disconnected() {
    let host = Host::new();
    // About 6 MiB without pauses: far more than one client may have queued.
    let session = host.create(shell(
        "stty -echo; IFS= read -r start; dd if=/dev/zero bs=65536 count=96 2>/dev/null | tr '\\0' x; printf '\\r\\nFLOOD_%s\\r\\n' COMPLETE; IFS= read -r line; printf 'LIVE:%s\\r\\n' \"$line\"; exec sleep 60",
    ));
    let (mut stalled, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut stalled_screen = Screen::new(80, 24, offset, &snapshot);
    let (mut active, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    input(&mut active, b"start\n");
    // The stalled socket is intentionally not read during the flood.
    screen.wait_text(&mut active, "FLOOD_COMPLETE");
    assert!(host.session(&session.id).attached);
    input(&mut active, b"AFTER_SLOW_PEER\n");
    screen.wait_text(&mut active, "LIVE:AFTER_SLOW_PEER");

    // The slow client catches up through a fresh snapshot and continues at
    // its offset, with every later byte in order.
    stalled
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    stalled_screen.wait_text(&mut stalled, "LIVE:AFTER_SLOW_PEER");
    assert!(
        stalled_screen.attached.contains(&AttachReason::Resync),
        "{:?}",
        stalled_screen.attached
    );
    assert_eq!(stalled_screen.offset, screen.offset);
    assert_eq!(stalled_screen.text(), screen.text());
    input(&mut stalled, b"FROM_SLOW_PEER\n");
    let info = host.session(&session.id);
    assert_eq!(info.pid, session.pid);
    assert!(info.attached);
}

/// Many lines where every cell has its own true colour: a large snapshot.
const STYLED_HISTORY: &str = r#"awk 'BEGIN { for (i = 0; i < 6000; i++) { line = ""; for (j = 0; j < 78; j++) line = line sprintf("\033[38;2;%d;%d;%dm%c", (i * 7 + j) % 256, (j * 13) % 256, (i + j * 3) % 256, 65 + (i + j) % 26); print line "\033[0m" } }'"#;

#[test]
fn a_client_lagging_when_its_session_exits_still_gets_the_final_screen() {
    let host = Host::new();
    // Far more styled output than a client may have queued, then the last
    // lines a user needs to see (a build's error, say) and an exit.
    let session = host.create(shell(&format!(
        "stty -echo; IFS= read -r start; {STYLED_HISTORY}; printf 'FINAL_%s\\n' MARKER; exit 3"
    )));
    let (mut stalled, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut stalled_screen = Screen::new(80, 24, offset, &snapshot);
    let (mut active, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    input(&mut active, b"start\n");
    active
        .set_read_timeout(Some(Duration::from_secs(30)))
        .unwrap();
    assert_eq!(screen.wait_exit(&mut active), (3, None));
    assert!(screen.text().contains("FINAL_MARKER"), "{}", screen.text());
    // Only now does the stalled client read what the host kept for it.
    stalled
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    assert_eq!(stalled_screen.wait_exit(&mut stalled), (3, None));
    assert!(
        stalled_screen.attached.contains(&AttachReason::Resync),
        "{:?}",
        stalled_screen.attached
    );
    assert!(
        stalled_screen.text().contains("FINAL_MARKER"),
        "the lagging client exited on a stale screen:\n{}",
        stalled_screen.text()
    );
    assert_eq!(stalled_screen.offset, screen.offset);
    assert_eq!(stalled_screen.text(), screen.text());
}

#[test]
fn a_flooding_session_does_not_delay_another_session() {
    let host = Host::new();
    let flood = host.create(shell("exec yes CHERRY_FLOOD"));
    // Its only client never reads.
    let (_stalled, _, _, _) = host.attach(&flood.id, 80, 24);
    let echo = host.create(shell(
        "stty -echo; while IFS= read -r line; do printf 'ECHO:%s\\n' \"$line\"; done",
    ));
    let (mut socket, _, offset, snapshot) = host.attach(&echo.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    thread::sleep(Duration::from_millis(200));
    for round in 0..5 {
        let started = Instant::now();
        input(&mut socket, format!("ping{round}\n").as_bytes());
        screen.wait_text(&mut socket, &format!("ECHO:ping{round}"));
        let elapsed = started.elapsed();
        assert!(
            elapsed < Duration::from_millis(1500),
            "echo took {elapsed:?} while another session flooded"
        );
    }
    assert_eq!(host.session(&flood.id).state, SessionState::Running);
}

#[test]
fn detached_terminal_queries_receive_replies() {
    let host = Host::new();
    let session=host.create(shell(r"stty raw -echo; printf '\033[6n'; dd bs=1 count=6 2>/dev/null | od -An -tx1; printf QUERY_COMPLETE"));
    host.wait(&session.id, |s| s.state == SessionState::Exited);
    let (_socket, _, _, snapshot) = host.attach(&session.id, 80, 24);
    let mut renderer = Terminal::new(80, 24, 2000).unwrap();
    renderer.feed(&snapshot);
    let text = renderer.screen_text().unwrap();
    assert!(text.contains("QUERY_COMPLETE"), "{text}");
    assert!(
        text.split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .contains("1b 5b 31 3b 31 52"),
        "{text}"
    );
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

#[test]
fn attached_queries_have_exactly_one_responder() {
    let host = Host::new();
    let session = host.create(shell_in(
        host.dir(),
        r#"stty raw -echo
printf 'READY\r\n'
dd bs=1 count=1 >/dev/null 2>&1
printf '\033[6n\033]52;c;?\007\033[?6n\033[>4n'
dd bs=1 count=6 2>/dev/null | od -An -tx1 > "$CHERRY_TEST_DIR/reply"
stty min 0 time 5
dd bs=1 count=64 2>/dev/null | od -An -tx1 > "$CHERRY_TEST_DIR/extra"
printf 'DONE\r\n'
exec sleep 60"#,
    ));
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    screen.wait_text(&mut socket, "READY");
    input(&mut socket, b"g");
    let mut output = Vec::new();
    let mut queries = Vec::new();
    while !contains(&output, b"DONE") {
        match receive(&mut socket) {
            ServerMessage::Output { data, .. } => output.extend(data),
            ServerMessage::Query { data } => queries.push((output.len(), data)),
            _ => {}
        }
    }
    // The host answered the cursor report, so the renderer never saw it; the
    // queries the host does not answer went to this client, apart from the
    // output and where they stood in it. A setting stays in the output.
    assert!(!contains(&output, b"\x1b[6n"));
    assert!(!contains(&output, b"\x1b]52;c;?\x07"));
    assert!(!contains(&output, b"\x1b[?6n"));
    assert!(contains(&output, b"\x1b[>4n"));
    let before_query = output.len() - b"\x1b[>4nDONE\r\n".len();
    assert_eq!(
        queries,
        [(before_query, b"\x1b]52;c;?\x07\x1b[?6n".to_vec())],
        "{:?}",
        String::from_utf8_lossy(&output)
    );
    let reply = fs::read_to_string(host.dir().join("reply")).unwrap();
    assert_eq!(
        reply.split_whitespace().collect::<Vec<_>>().join(" "),
        "1b 5b 32 3b 31 52"
    );
    let extra = fs::read_to_string(host.dir().join("extra")).unwrap();
    assert!(extra.trim().is_empty(), "second reply: {extra}");
}

#[test]
fn large_clipboard_writes_reach_attached_clients() {
    let host = Host::new();
    let session = host.create(shell(
        "stty raw -echo; IFS= read -r start; printf '\\033]52;c;'; head -c 3000000 /dev/zero | tr '\\0' A; printf '\\007CLIP_DONE\\r\\n'; exec sleep 60",
    ));
    let (mut socket, _, _, _) = host.attach(&session.id, 80, 24);
    input(&mut socket, b"go\n");
    let mut output = Vec::new();
    while !contains(&output, b"CLIP_DONE") {
        if let ServerMessage::Output { data, .. } = receive(&mut socket) {
            output.extend(data);
        }
    }
    let expected = [&b"\x1b]52;c;"[..], &vec![b'A'; 3_000_000], b"\x07"].concat();
    assert!(
        contains(&output, &expected),
        "clipboard write was not forwarded intact"
    );
}

#[test]
fn reattach_inside_alternate_screen_restores_underlying_primary_buffer() {
    let host = Host::new();
    let session=host.create(shell(r"stty raw -echo; printf 'PRIMARY_SCREEN\033[?1049h\033[2J\033[HALTERNATE_SCREEN'; dd bs=1 count=1 >/dev/null 2>&1; printf '\033[?1049l'; sleep 2"));
    // Wait for the application to enter its alternate screen, not merely for spawn.
    let deadline = Instant::now() + Duration::from_secs(5);
    let (mut socket, mut screen) = loop {
        let (socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
        let screen = Screen::new(80, 24, offset, &snapshot);
        if screen.text().contains("ALTERNATE_SCREEN") {
            break (socket, screen);
        }
        drop(socket);
        host.wait(&session.id, |s| !s.attached);
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(15));
    };
    input(&mut socket, b"x");
    screen.wait_text(&mut socket, "PRIMARY_SCREEN");
}

#[test]
fn reattaching_a_full_screen_app_at_other_sizes_restores_the_primary_screen() {
    let host = Host::new();
    let primary = "PRIMARY_TOP\r\nline 1\r\nline 2\r\nPRIMARY_BOTTOM";
    let alternate = "\x1b[?1049h\x1b[2J\x1b[HALTERNATE_APP\x1b[5;3Hbody";
    let session = host.create(shell(&format!(
        "stty raw -echo; printf '{}'; printf '{}'; dd bs=1 count=1 >/dev/null 2>&1; printf '\\033[?1049lEXITED_APP'; exec sleep 60",
        primary,
        alternate.replace('\x1b', "\\033"),
    )));
    let mut reference = Terminal::new(80, 24, 1024 * 1024).unwrap();
    reference.feed(primary.as_bytes());
    reference.feed(alternate.as_bytes());
    // Attach at the original size until the app is on its alternate screen.
    loop {
        let (socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
        let screen = Screen::new(80, 24, offset, &snapshot);
        drop(socket);
        host.wait(&session.id, |s| !s.attached);
        if screen.text().contains("body") {
            break;
        }
        thread::sleep(Duration::from_millis(15));
    }
    // Larger, then smaller than the grid the app started on.
    for (cols, rows) in [(110, 35), (60, 15)] {
        let (socket, info, offset, snapshot) = host.attach(&session.id, cols, rows);
        assert_eq!((info.cols, info.rows), (cols, rows));
        reference.resize(cols, rows).unwrap();
        let screen = Screen::new(cols, rows, offset, &snapshot);
        assert_eq!(
            screen.terminal.inspect().unwrap().active,
            reference.inspect().unwrap().active,
            "snapshot at {cols}x{rows}"
        );
        drop(socket);
        host.wait(&session.id, |s| !s.attached);
    }
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 60, 15);
    let mut screen = Screen::new(60, 15, offset, &snapshot);
    input(&mut socket, b"q");
    screen.wait_text(&mut socket, "EXITED_APP");
    reference.feed(b"\x1b[?1049lEXITED_APP");
    let (actual, expected) = (
        screen.terminal.inspect().unwrap(),
        reference.inspect().unwrap(),
    );
    assert_eq!(actual.active, expected.active);
    assert_eq!(actual.cursor, expected.cursor);
    assert!(screen.text().contains("PRIMARY_BOTTOM"));
}

/// A real full-screen program through the host: startup queries, a reattach
/// at a new size, and the primary screen after it quits.
#[test]
#[ignore = "needs nvim on PATH"]
fn neovim_survives_reattach_at_a_new_size() {
    if std::process::Command::new("nvim")
        .arg("--version")
        .output()
        .is_err()
    {
        eprintln!("skipped: nvim not found");
        return;
    }
    let host = Host::new();
    let session = host.create(shell(
        "printf 'BEFORE_%s\\n' NVIM; nvim --clean -n; printf 'AFTER_%s\\n' NVIM; exec sleep 60",
    ));
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    screen.wait_text(&mut socket, "~");
    // Neovim negotiates the kitty keyboard protocol with the host, so a bare
    // ESC byte is not Escape; stay in normal mode.
    input(&mut socket, b":call setline(1, 'hello from nvim')\r");
    screen.wait_text(&mut socket, "hello from nvim");
    drop(socket);
    host.wait(&session.id, |s| !s.attached);
    let (mut socket, info, offset, snapshot) = host.attach(&session.id, 110, 35);
    assert_eq!((info.cols, info.rows), (110, 35));
    let mut screen = Screen::new(110, 35, offset, &snapshot);
    assert!(
        screen.text().contains("hello from nvim"),
        "{}",
        screen.text()
    );
    // Neovim redraws for the new size.
    input(&mut socket, b":echo 'SIZE_'.&columns\r");
    screen.wait_text(&mut socket, "SIZE_110");
    input(&mut socket, b":qa!\r");
    screen.wait_text(&mut socket, "AFTER_NVIM");
    assert!(screen.text().contains("BEFORE_NVIM"), "{}", screen.text());
    assert!(!screen.text().contains("hello from nvim"));
}

#[test]
fn invalid_protocol_and_launch_do_not_create_sessions() {
    let host = Host::new();
    let mut socket = UnixStream::connect(&host.socket).unwrap();
    write_frame(&mut socket, &ClientMessage::Hello { version: 999 }).unwrap();
    assert!(
        matches!(receive(&mut socket),ServerMessage::Error {code,..} if code=="version_mismatch")
    );
    let launch = |cwd: &str, env: BTreeMap<String, String>| ClientMessage::Create {
        request_id: Uuid::new_v4().to_string(),
        name: "bad".into(),
        cwd: cwd.into(),
        command: vec![],
        env,
        cols: 80,
        rows: 24,
    };
    let error = |message: ServerMessage| match message {
        ServerMessage::Error { message, .. } => message,
        other => panic!("{other:?}"),
    };
    assert!(error(host.call(launch("/does/not/exist", BTreeMap::new()))).contains("does not exist"));
    assert!(error(host.call(launch(".", BTreeMap::new())))
        .contains("must be absolute or start with ~/"));
    assert!(error(host.call(launch(
        "/tmp",
        BTreeMap::from([("CHERRY_PROCESS_ID".into(), "1".into())])
    )))
    .contains("only LANG, LC_* and TZ"));
    assert!(error(host.call(ClientMessage::Create {
        request_id: Uuid::new_v4().to_string(),
        name: "bad".into(),
        cwd: "/tmp".into(),
        command: vec!["/does/not/exist".into()],
        env: BTreeMap::new(),
        cols: 80,
        rows: 24,
    }))
    .contains("/does/not/exist"));
    assert!(host.sessions().is_empty());
}

#[test]
fn working_directories_are_expanded_on_the_host() {
    let host = Host::new();
    let home = host.sandbox.home.canonicalize().unwrap();
    fs::create_dir(home.join("project")).unwrap();
    for (cwd, expected) in [
        ("~", home.clone()),
        ("", home.clone()),
        ("~/project", home.join("project")),
        ("/tmp", fs::canonicalize("/tmp").unwrap()),
    ] {
        let created = match host.call(ClientMessage::Create {
            request_id: Uuid::new_v4().to_string(),
            name: "cwd".into(),
            cwd: cwd.into(),
            command: shell("pwd -P; exec sleep 60"),
            env: BTreeMap::new(),
            cols: 80,
            rows: 24,
        }) {
            ServerMessage::Created { session } => session,
            other => panic!("{cwd}: {other:?}"),
        };
        assert_eq!(created.cwd, expected.to_string_lossy(), "{cwd}");
        let (mut socket, _, offset, snapshot) = host.attach(&created.id, 80, 24);
        let mut screen = Screen::new(80, 24, offset, &snapshot);
        screen.wait_text(&mut socket, &expected.to_string_lossy());
        host.kill(&created.id);
    }
}

#[test]
fn large_styled_history_still_attaches_within_one_frame() {
    let host = Host::new();
    let session = host.create(shell(&format!(
        "{STYLED_HISTORY}; printf 'HISTORY_%s\\n' DONE; exec sleep 60"
    )));
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    screen.wait_text(&mut socket, "HISTORY_DONE");
    drop(socket);
    host.wait(&session.id, |s| !s.attached);
    let (_socket, _, _, snapshot) = host.attach(&session.id, 80, 24);
    assert!(snapshot.len() <= MAX_SNAPSHOT_BYTES, "{}", snapshot.len());
    let screen = Screen::new(80, 24, 0, &snapshot);
    assert!(screen.text().contains("HISTORY_DONE"));
    assert!(!screen.terminal.inspect().unwrap().history.is_empty());
}

#[test]
fn attaching_during_live_output_reproduces_the_final_screen() {
    let host = Host::new();
    let session = host.create(shell(
        "i=0; while [ $i -lt 4000 ]; do printf 'row %05d\\n' $i; i=$((i+1)); [ $((i % 200)) -eq 0 ] && sleep 0.03; done; printf 'END\\n'; exec sleep 60",
    ));
    // Attach while the loop is still printing.
    let (mut probe, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut first = Screen::new(80, 24, offset, &snapshot);
    first.wait_text(&mut probe, "row 00");
    let mut attachments = Vec::new();
    for _ in 0..3 {
        let (socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
        attachments.push((socket, Screen::new(80, 24, offset, &snapshot)));
        thread::sleep(Duration::from_millis(20));
    }
    let mut transcript = String::new();
    for i in 0..4000 {
        transcript.push_str(&format!("row {i:05}\r\n"));
    }
    transcript.push_str("END\r\n");
    let mut reference = Terminal::new(80, 24, 1024 * 1024).unwrap();
    reference.feed(transcript.as_bytes());
    let expected = reference.inspect().unwrap();
    for (mut socket, mut screen) in attachments {
        while !screen.text().contains("END") {
            screen.receive(&mut socket);
        }
        let actual = screen.terminal.inspect().unwrap();
        assert_eq!(actual.active, expected.active);
        assert_eq!(actual.cursor, expected.cursor);
    }
}

/// Attach once the snapshot satisfies `ready`, re-attaching until it does.
fn attach_when(host: &Host, id: &str, ready: impl Fn(&str) -> bool) -> (UnixStream, Screen) {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let (socket, _, offset, snapshot) = host.attach(id, 80, 24);
        let screen = Screen::new(80, 24, offset, &snapshot);
        if ready(&screen.text()) {
            return (socket, screen);
        }
        drop(socket);
        assert!(Instant::now() < deadline, "{}", screen.text());
        thread::sleep(Duration::from_millis(15));
    }
}

#[test]
fn sequences_split_across_reads_survive_attach() {
    let host = Host::new();
    // A true-colour SGR and a UTF-8 character, each cut in two: the program
    // waits for the test between the halves.
    let session = host.create(shell_in(
        host.dir(),
        r#"stty raw -echo
printf 'A\033[38;2;255;0'
while [ ! -e "$CHERRY_TEST_DIR/second" ]; do sleep 0.01; done
printf ';0mRED\342\202'
while [ ! -e "$CHERRY_TEST_DIR/third" ]; do sleep 0.01; done
printf '\254END\r\n'
exec sleep 60"#,
    ));
    // Attached while the host holds half an SGR sequence...
    let first = attach_when(&host, &session.id, |text| text.contains('A'));
    assert!(!first.1.text().contains("RED"), "{}", first.1.text());
    fs::write(host.dir().join("second"), []).unwrap();
    // ...and while it holds half a UTF-8 character.
    let second = attach_when(&host, &session.id, |text| text.contains("ARED"));
    assert!(!second.1.text().contains('€'), "{}", second.1.text());
    fs::write(host.dir().join("third"), []).unwrap();
    let mut reference = Terminal::new(80, 24, 1024).unwrap();
    reference.feed(b"A\x1b[38;2;255;0;0mRED\xe2\x82\xacEND\r\n");
    let expected = reference.inspect().unwrap();
    for (mut socket, mut screen) in [first, second] {
        screen.wait_text(&mut socket, "END");
        assert!(screen.text().contains("ARED€END"), "{}", screen.text());
        assert_eq!(screen.terminal.inspect().unwrap().active, expected.active);
    }
}

#[test]
fn silent_attachments_are_evicted_and_the_grid_regrows() {
    let host = Host::with_env(&[("CHERRY_HOST_HEARTBEAT_TIMEOUT_MS", "600")]);
    let session = host.create(shell("exec sleep 60"));
    let (mut active, _, offset, snapshot) = host.attach(&session.id, 100, 30);
    let mut screen = Screen::new(100, 30, offset, &snapshot);
    let (mut silent, info, _, _) = host.attach(&session.id, 60, 20);
    assert_eq!((info.cols, info.rows), (60, 20));
    active
        .set_read_timeout(Some(Duration::from_millis(100)))
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut sizes = Vec::new();
    // The active client keeps sending heartbeats; the other goes quiet.
    while (screen.cols, screen.rows) != (100, 30) || sizes.is_empty() {
        assert!(Instant::now() < deadline, "grid never regrew: {sizes:?}");
        send(&mut active, &ClientMessage::Ping);
        while let Ok(Some(message)) = read_frame::<_, ServerMessage>(&mut active) {
            screen.apply(&message);
            if let ServerMessage::Attached { session, .. } = &message {
                sizes.push((session.cols, session.rows));
            }
        }
    }
    assert_eq!(sizes, vec![(60, 20), (100, 30)]);
    // The evicted client's connection was closed. (macOS refuses socket
    // options once the peer has closed, so this may fail.)
    let _ = silent.set_read_timeout(Some(Duration::from_secs(5)));
    loop {
        match read_frame::<_, ServerMessage>(&mut silent) {
            Ok(Some(_)) => {}
            Ok(None) => break,
            Err(error) => panic!("expected the host to close the connection: {error}"),
        }
    }
    let info = host.session(&session.id);
    assert!(info.attached);
    assert_eq!((info.cols, info.rows), (100, 30));
}

/// Read with a short timeout while pinging, until `done` holds.
fn ping_until(
    socket: &mut UnixStream,
    screen: &mut Screen,
    what: &str,
    done: impl Fn(&Screen) -> bool,
) {
    socket
        .set_read_timeout(Some(Duration::from_millis(100)))
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !done(screen) {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        send(socket, &ClientMessage::Ping);
        while let Ok(Some(message)) = read_frame::<_, ServerMessage>(socket) {
            screen.apply(&message);
        }
    }
}

#[test]
fn a_paste_held_for_a_program_that_stopped_reading_never_ends_the_attachment() {
    let host = Host::with_env(&[("CHERRY_HOST_HEARTBEAT_TIMEOUT_MS", "600")]);
    const SIZE: usize = 2 * 1024 * 1024;
    // Taken before the program starts, so its sleep ends more than 3 s
    // from now, whatever the speed of this machine.
    let started = Instant::now();
    // Busy for five heartbeat timeouts before it reads anything, as behind
    // a hung plugin or a stalled network read.
    let session = host.create(shell_in(
        host.dir(),
        &format!(
            r#"stty raw -echo; printf 'READY\r\n'; sleep 3; head -c {SIZE} > "$CHERRY_TEST_DIR/paste"; printf 'PASTED\r\n'; exec sleep 60"#
        ),
    ));
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    screen.wait_text(&mut socket, "READY");
    let payload: Vec<u8> = (0..SIZE).map(|i| b'a' + (i % 26) as u8).collect();
    let mut writer = socket.try_clone().unwrap();
    writer
        .set_write_timeout(Some(Duration::from_secs(20)))
        .unwrap();
    let chunks = payload.clone();
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let stopped = stop.clone();
    // Like a real client: the paste, then heartbeats, which wait behind it.
    let sender = thread::spawn(move || {
        for chunk in chunks.chunks(MAX_INPUT_BYTES) {
            write_frame(
                &mut writer,
                &ClientMessage::Input {
                    data: chunk.to_vec(),
                },
            )
            .unwrap();
        }
        while !stopped.load(std::sync::atomic::Ordering::SeqCst) {
            write_frame(&mut writer, &ClientMessage::Ping).unwrap();
            thread::sleep(Duration::from_millis(100));
        }
    });
    socket
        .set_read_timeout(Some(Duration::from_secs(20)))
        .unwrap();
    // Meanwhile the host keeps telling the client it is alive: its writes
    // are blocked, and silence would make it give up on the connection.
    let mut pongs_while_stuck = 0;
    while !screen.text().contains("PASTED") {
        match read_frame::<_, ServerMessage>(&mut socket) {
            Ok(Some(ServerMessage::Pong)) => {
                if started.elapsed() < Duration::from_millis(2500) {
                    pongs_while_stuck += 1;
                }
            }
            Ok(Some(message)) => screen.apply(&message),
            Ok(None) => panic!("the host closed the connection"),
            Err(error) => panic!("{error}"),
        }
    }
    assert!(started.elapsed() > Duration::from_secs(3));
    assert!(pongs_while_stuck >= 3, "{pongs_while_stuck} Pongs");
    stop.store(true, std::sync::atomic::Ordering::SeqCst);
    sender.join().unwrap();
    assert_eq!(fs::read(host.dir().join("paste")).unwrap(), payload);
    assert!(host.session(&session.id).attached);
}

#[test]
fn a_client_that_hangs_up_while_its_input_is_held_is_evicted_at_once() {
    // Far longer than this test: only the hangup can end the attachment.
    let host = Host::with_env(&[("CHERRY_HOST_HEARTBEAT_TIMEOUT_MS", "60000")]);
    let session = host.create(shell_in(
        host.dir(),
        r#"stty raw -echo; printf ready > "$CHERRY_TEST_DIR/ready"; exec sleep 60"#,
    ));
    wait_until("program", || host.dir().join("ready").exists());
    // A client pastes far more than the program reads (nothing), then
    // hangs up while its writes are blocked.
    let (paster, _, _, _) = host.attach(&session.id, 60, 20);
    let mut writer = paster.try_clone().unwrap();
    writer
        .set_write_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let sent = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counted = sent.clone();
    let pasting = thread::spawn(move || {
        let mut frame = Vec::new();
        write_frame(
            &mut frame,
            &ClientMessage::Input {
                data: vec![b'x'; MAX_INPUT_BYTES],
            },
        )
        .unwrap();
        for _ in 0..40 {
            if writer.write_all(&frame).is_err() {
                break;
            }
            counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        }
    });
    let (mut active, info, offset, snapshot) = host.attach(&session.id, 100, 30);
    assert_eq!((info.cols, info.rows), (60, 20));
    let mut screen = Screen::new(60, 20, offset, &snapshot);
    // The host holds the paste: the paster's writes stop being accepted.
    wait_until("the paste to be held", || {
        let before = sent.load(std::sync::atomic::Ordering::SeqCst);
        thread::sleep(Duration::from_millis(300));
        before > 16 && sent.load(std::sync::atomic::Ordering::SeqCst) == before
    });
    assert!(host.session(&session.id).attached);
    // Its process ends: the blocked write fails and the connection closes.
    let _ = paster.shutdown(std::net::Shutdown::Both);
    pasting.join().unwrap();
    drop(paster);
    ping_until(&mut active, &mut screen, "the grid to regrow", |screen| {
        (screen.cols, screen.rows) == (100, 30)
    });
    let info = host.session(&session.id);
    assert!(info.attached);
    assert_eq!((info.cols, info.rows), (100, 30));
}

#[test]
fn another_clients_stuck_paste_does_not_stall_this_client() {
    // Longer than this test: the paster is never evicted meanwhile.
    let host = Host::with_env(&[("CHERRY_HOST_HEARTBEAT_TIMEOUT_MS", "20000")]);
    let session = host.create(shell_in(
        host.dir(),
        r#"stty raw -echo; printf ready > "$CHERRY_TEST_DIR/ready"; exec sleep 60"#,
    ));
    wait_until("program", || host.dir().join("ready").exists());
    let (paster, _, _, _) = host.attach(&session.id, 80, 24);
    let mut writer = paster.try_clone().unwrap();
    writer
        .set_write_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let pasting = thread::spawn(move || {
        let mut frame = Vec::new();
        write_frame(
            &mut frame,
            &ClientMessage::Input {
                data: vec![b'x'; MAX_INPUT_BYTES],
            },
        )
        .unwrap();
        for _ in 0..40 {
            if writer.write_all(&frame).is_err() {
                break;
            }
        }
    });
    // Let the paste fill the session's input budget.
    thread::sleep(Duration::from_millis(300));
    let (mut other, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    // Its resizes and heartbeats are still read and answered.
    let started = Instant::now();
    send(&mut other, &ClientMessage::Resize { cols: 80, rows: 20 });
    ping_until(&mut other, &mut screen, "the resize", |screen| {
        (screen.cols, screen.rows) == (80, 20)
    });
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "resize took {:?}",
        started.elapsed()
    );
    assert!(host.session(&session.id).attached);
    drop(paster);
    host.kill(&session.id);
    pasting.join().unwrap();
}

#[test]
fn a_paste_into_a_slow_reader_is_not_mistaken_for_silence() {
    let host = Host::with_env(&[("CHERRY_HOST_HEARTBEAT_TIMEOUT_MS", "300")]);
    const CHUNK: usize = 64 * 1024;
    const CHUNKS: usize = 20;
    const SIZE: usize = CHUNK * CHUNKS;
    // A chunk at a time with a pause after each (one byte per read, so the
    // chunks are exact): the backlog drains for at least CHUNKS pauses,
    // however fast the machine, while the program keeps making progress.
    let session = host.create(shell_in(
        host.dir(),
        &format!(
            r#"stty raw -echo; printf 'READY\r\n'; i=0; while [ $i -lt {CHUNKS} ]; do dd bs=1 count={CHUNK} 2>/dev/null; sleep 0.1; i=$((i + 1)); done > "$CHERRY_TEST_DIR/paste"; printf 'PASTED\r\n'; exec sleep 60"#
        ),
    ));
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    screen.wait_text(&mut socket, "READY");
    let payload: Vec<u8> = (0..SIZE).map(|i| b'a' + (i % 26) as u8).collect();
    let mut writer = socket.try_clone().unwrap();
    writer
        .set_write_timeout(Some(Duration::from_secs(20)))
        .unwrap();
    let chunks = payload.clone();
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let stopped = stop.clone();
    let started = Instant::now();
    // Like a real client: the paste, then heartbeats (which cannot overtake
    // the paste).
    let sender = thread::spawn(move || {
        for chunk in chunks.chunks(MAX_INPUT_BYTES) {
            write_frame(
                &mut writer,
                &ClientMessage::Input {
                    data: chunk.to_vec(),
                },
            )
            .unwrap();
        }
        while !stopped.load(std::sync::atomic::Ordering::SeqCst) {
            write_frame(&mut writer, &ClientMessage::Ping).unwrap();
            thread::sleep(Duration::from_millis(100));
        }
    });
    socket
        .set_read_timeout(Some(Duration::from_secs(30)))
        .unwrap();
    screen.wait_text(&mut socket, "PASTED");
    // Every pause follows input sent after `started`.
    assert!(started.elapsed() >= Duration::from_millis(100) * CHUNKS as u32);
    stop.store(true, std::sync::atomic::Ordering::SeqCst);
    sender.join().unwrap();
    assert_eq!(fs::read(host.dir().join("paste")).unwrap(), payload);
    assert!(host.session(&session.id).attached);
}

#[test]
fn a_client_whose_input_is_held_hears_whether_the_program_consumes_it() {
    // A client whose paste the host holds back sees its writes blocked, and
    // cannot tell a slow program from a stuck one. The host tells it with a
    // Pong about once a second while the program works through the input.
    for reads in [true, false] {
        // The host's own heartbeats while input is held come every third of
        // this, after the test.
        let host = Host::with_env(&[("CHERRY_HOST_HEARTBEAT_TIMEOUT_MS", "20000")]);
        let program = if reads {
            // Far slower than the paste arrives, with pauses between reads.
            r#"while :; do dd bs=1 count=16384 2>/dev/null; sleep 0.05; done > /dev/null"#
        } else {
            "exec sleep 60"
        };
        let session = host.create(shell_in(
            host.dir(),
            &format!(r#"stty raw -echo; printf 'READY\r\n'; {program}"#),
        ));
        let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
        let mut screen = Screen::new(80, 24, offset, &snapshot);
        screen.wait_text(&mut socket, "READY");
        let mut writer = socket.try_clone().unwrap();
        writer
            .set_write_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        // Twice what the host holds for a session, and never a Ping.
        let sender = thread::spawn(move || {
            for _ in 0..32 {
                let data = vec![b'x'; MAX_INPUT_BYTES];
                if write_frame(&mut writer, &ClientMessage::Input { data }).is_err() {
                    break;
                }
            }
        });
        socket
            .set_read_timeout(Some(Duration::from_millis(200)))
            .unwrap();
        let started = Instant::now();
        let mut pongs = 0;
        while started.elapsed() < Duration::from_secs(3) {
            match read_frame::<_, ServerMessage>(&mut socket) {
                Ok(Some(ServerMessage::Pong)) => pongs += 1,
                Ok(Some(message)) => screen.apply(&message),
                Ok(None) => panic!("the host closed the connection"),
                Err(_) => {}
            }
        }
        if reads {
            assert!(pongs >= 2, "{pongs} Pongs");
        } else {
            assert_eq!(pongs, 0);
        }
        assert!(host.session(&session.id).attached);
        host.kill(&session.id);
        drop(socket);
        sender.join().unwrap();
    }
}

#[test]
fn detach_delivers_input_sent_before_it() {
    let host = Host::new();
    let session = host.create(vec!["/bin/sh".into()]);
    for round in 0..10 {
        let marker = host.dir().join(format!("marker-{round}"));
        let (mut socket, _, _, _) = host.attach(&session.id, 80, 24);
        // One write: the input and the detach arrive together.
        let mut bytes = Vec::new();
        write_frame(
            &mut bytes,
            &ClientMessage::Input {
                data: format!("echo marker > '{}'\r", marker.display()).into_bytes(),
            },
        )
        .unwrap();
        write_frame(&mut bytes, &ClientMessage::Detach).unwrap();
        socket.write_all(&bytes).unwrap();
        loop {
            match receive(&mut socket) {
                ServerMessage::Ok => break,
                ServerMessage::Output { .. } => {}
                other => panic!("{other:?}"),
            }
        }
        wait_until(&format!("marker {round}"), || marker.exists());
        host.wait(&session.id, |s| !s.attached);
    }
}

#[test]
fn large_pastes_are_delivered_without_disconnecting() {
    let host = Host::new();
    const SIZE: usize = 5 * 1024 * 1024;
    let session = host.create(shell_in(
        host.dir(),
        &format!(
            "stty raw -echo; printf 'READY\\r\\n'; head -c {SIZE} > \"$CHERRY_TEST_DIR/paste\"; printf 'PASTED\\r\\n'; exec sleep 60"
        ),
    ));
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    screen.wait_text(&mut socket, "READY");
    let payload: Vec<u8> = (0..SIZE).map(|i| b'a' + (i % 26) as u8).collect();
    let mut writer = socket.try_clone().unwrap();
    writer
        .set_write_timeout(Some(Duration::from_secs(30)))
        .unwrap();
    let chunks = payload.clone();
    let sender = thread::spawn(move || {
        for chunk in chunks.chunks(MAX_INPUT_BYTES) {
            write_frame(
                &mut writer,
                &ClientMessage::Input {
                    data: chunk.to_vec(),
                },
            )
            .unwrap();
        }
    });
    socket
        .set_read_timeout(Some(Duration::from_secs(30)))
        .unwrap();
    // Replies and output keep flowing while the paste drains.
    screen.wait_text(&mut socket, "PASTED");
    sender.join().unwrap();
    assert_eq!(fs::read(host.dir().join("paste")).unwrap(), payload);
    assert!(host.session(&session.id).attached);
    send(&mut socket, &ClientMessage::Ping);
    loop {
        match screen.receive(&mut socket) {
            ServerMessage::Pong => break,
            ServerMessage::Output { .. } => {}
            other => panic!("{other:?}"),
        }
    }
}

#[test]
fn stdio_gateway_flushes_binary_frames_without_newlines() {
    let host = Host::new();
    let mut gateway = host
        .sandbox
        .command("gateway")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .spawn()
        .unwrap();
    let mut stdin = gateway.stdin.take().unwrap();
    let mut stdout = gateway.stdout.take().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    let reader = thread::spawn(move || {
        use std::io::Read;
        let mut preamble = [0u8; 17];
        let result = stdout
            .read_exact(&mut preamble)
            .map(|_| preamble.to_vec())
            .and_then(|preamble| Ok((preamble, read_frame::<_, ServerMessage>(&mut stdout)?)));
        let _ = tx.send(result);
    });
    write_frame(&mut stdin, &ClientMessage::hello()).unwrap();
    let result = rx.recv_timeout(Duration::from_secs(3));
    drop(stdin);
    let _ = gateway.kill();
    let _ = gateway.wait();
    reader.join().unwrap();
    let (preamble, welcome) = result.unwrap().unwrap();
    assert_eq!(preamble, b"CHERRY-GATEWAY 3\n");
    assert!(matches!(welcome, Some(ServerMessage::Welcome { .. })));
}

#[test]
fn bursts_of_small_frames_are_all_handled_promptly() {
    let host = Host::new();
    let session = host.create(shell_in(
        host.dir(),
        r#"stty raw -echo; printf 'READY\r\n'; head -c 500 > "$CHERRY_TEST_DIR/bytes"; printf 'GOT\r\n'; exec sleep 60"#,
    ));
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    screen.wait_text(&mut socket, "READY");
    // Far more frames than the session's command queue holds, in one write.
    let mut burst = Vec::new();
    for i in 0..500 {
        write_frame(
            &mut burst,
            &ClientMessage::Input {
                data: vec![b'a' + (i % 26) as u8],
            },
        )
        .unwrap();
    }
    socket.write_all(&burst).unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    screen.wait_text(&mut socket, "GOT");
    let expected: Vec<u8> = (0..500).map(|i| b'a' + (i % 26) as u8).collect();
    assert_eq!(fs::read(host.dir().join("bytes")).unwrap(), expected);
}
