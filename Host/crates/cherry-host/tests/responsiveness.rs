//! What keeps an attached window responsive: a client that starts again
//! replaces its own stale attachment, the threads that carry an attachment's
//! traffic run at interactive priority while it lasts, and a window that
//! alone sets the shared grid resizes it at once, painted once by a
//! full-screen program.
mod support;

use cherry_protocol::*;
use std::{os::unix::net::UnixStream, time::Duration};
use support::*;

/// Attach as the client `client`, at `cols` by `rows`.
fn attach_as(
    host: &Host,
    id: &str,
    cols: u16,
    rows: u16,
    client: Option<&str>,
) -> (UnixStream, SessionInfo, u64, Vec<u8>) {
    let mut socket = host.connect();
    send(
        &mut socket,
        &ClientMessage::Attach {
            id: id.into(),
            cols,
            rows,
            takeover: false,
            answers_queries: true,
            client_id: client.map(str::to_owned),
        },
    );
    match receive(&mut socket) {
        ServerMessage::Attached {
            reason: AttachReason::Attach,
            session,
            offset,
            snapshot,
        } => (socket, session, offset, snapshot),
        other => panic!("attach failed: {other:?}"),
    }
}

/// Read until the host ends the connection; the messages that came first.
fn until_closed(socket: &mut UnixStream) -> Vec<ServerMessage> {
    // Fails once the host shut the connection down, as it may have.
    let _ = socket.set_read_timeout(Some(Duration::from_secs(10)));
    let mut messages = Vec::new();
    loop {
        match read_frame::<_, ServerMessage>(socket) {
            Ok(Some(message)) => messages.push(message),
            Ok(None) => return messages,
            Err(error) if error.kind() == std::io::ErrorKind::ConnectionReset => return messages,
            Err(error) => panic!("the connection was not closed: {error}"),
        }
    }
}

#[test]
fn a_client_that_attaches_again_replaces_its_stale_attachment() {
    let host = Host::new();
    let session = host.create(shell("stty -echo; printf 'READY\\n'; exec sleep 60"));
    // A tab's adapter, which then goes away without the host noticing
    // (its connection stays open), and another client.
    let (mut stale, _, _, _) = attach_as(&host, &session.id, 60, 20, Some("tab-1"));
    let (mut other, _, _, _) = attach_as(&host, &session.id, 100, 30, None);
    assert_eq!(host.session(&session.id).clients, 2);
    let grid = host.session(&session.id);
    assert_eq!(
        (grid.cols, grid.rows),
        (60, 20),
        "the stale one sets the grid"
    );

    // The tab's adapter starts again, larger: the stale attachment is
    // dropped as if its connection had ended, and the grid no longer
    // waits for it.
    let (mut fresh, info, _, _) = attach_as(&host, &session.id, 90, 28, Some("tab-1"));
    assert_eq!((info.cols, info.rows), (90, 28));
    // It alone is told, last, that it was replaced (not taken over), so a
    // copy of the client that still ran would end rather than connect
    // again and replace the new one in turn.
    let told = until_closed(&mut stale);
    assert!(
        !told.iter().any(|message| matches!(
            message,
            ServerMessage::Error { code, .. } if code == error_code::TAKEN_OVER
        )),
        "a replaced attachment is not taken over: {told:?}"
    );
    assert!(
        matches!(
            told.last(),
            Some(ServerMessage::Error { code, .. }) if code == error_code::REPLACED
        ),
        "{told:?}"
    );
    let now = host.wait(&session.id, |info| info.clients == 2);
    assert_eq!((now.cols, now.rows), (90, 28));
    // The other client was told nothing but the new grid.
    other
        .set_read_timeout(Some(Duration::from_millis(500)))
        .unwrap();
    while let Ok(Some(message)) = read_frame::<_, ServerMessage>(&mut other) {
        assert!(
            matches!(
                message,
                ServerMessage::Attached {
                    reason: AttachReason::Resize,
                    ..
                } | ServerMessage::Resized { .. }
                    | ServerMessage::Output { .. }
                    | ServerMessage::Pong
            ),
            "{message:?}"
        );
    }
    // Another client ID, or none, replaces nothing.
    let (_third, _, _, _) = attach_as(&host, &session.id, 120, 40, Some("tab-2"));
    let (_fourth, _, _, _) = attach_as(&host, &session.id, 120, 40, None);
    assert_eq!(host.wait(&session.id, |info| info.clients == 4).clients, 4);
    // The replacement itself stays attached: its input is taken and its
    // heartbeat answered.
    input(&mut fresh, b"x");
    send(&mut fresh, &ClientMessage::Ping);
    fresh
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    loop {
        match receive(&mut fresh) {
            ServerMessage::Pong => break,
            ServerMessage::Error { code, message } => panic!("{code}: {message}"),
            _ => {}
        }
    }

    // A client ID is at most MAX_CLIENT_ID_BYTES.
    let mut socket = host.connect();
    send(
        &mut socket,
        &ClientMessage::Attach {
            id: session.id.clone(),
            cols: 80,
            rows: 24,
            takeover: false,
            answers_queries: true,
            client_id: Some("x".repeat(MAX_CLIENT_ID_BYTES + 1)),
        },
    );
    match receive(&mut socket) {
        ServerMessage::Error { code, message } => {
            assert_eq!(code, error_code::REQUEST_FAILED);
            assert!(message.contains("client ID"), "{message}");
        }
        other => panic!("{other:?}"),
    }
}

/// The scheduling priorities of `pid`'s threads.
#[cfg(target_os = "macos")]
fn thread_priorities(pid: u32) -> Vec<i32> {
    /// From `sys/proc_info.h`.
    const PROC_PIDLISTTHREADS: libc::c_int = 6;
    let pid = pid as libc::c_int;
    let mut handles = vec![0u64; 256];
    let size = unsafe {
        libc::proc_pidinfo(
            pid,
            PROC_PIDLISTTHREADS,
            0,
            handles.as_mut_ptr().cast(),
            (handles.len() * std::mem::size_of::<u64>()) as libc::c_int,
        )
    };
    assert!(size > 0, "listing the threads of {pid}");
    handles.truncate(size as usize / std::mem::size_of::<u64>());
    handles
        .into_iter()
        .filter_map(|handle| {
            let mut info: libc::proc_threadinfo = unsafe { std::mem::zeroed() };
            let size = std::mem::size_of::<libc::proc_threadinfo>() as libc::c_int;
            (unsafe {
                libc::proc_pidinfo(
                    pid,
                    libc::PROC_PIDTHREADINFO,
                    handle,
                    (&mut info as *mut libc::proc_threadinfo).cast(),
                    size,
                )
            } == size)
                .then_some(info.pth_priority)
        })
        .collect()
}

/// How many of `pid`'s threads run above the default priority, once that
/// holds `expected`.
#[cfg(target_os = "macos")]
fn wait_raised(pid: u32, expected: impl Fn(usize) -> bool) -> usize {
    use std::time::Instant;
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let raised = thread_priorities(pid)
            .into_iter()
            .filter(|&priority| priority > 31)
            .count();
        if expected(raised) {
            return raised;
        }
        assert!(
            Instant::now() < deadline,
            "{raised} threads of {pid} raised"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[cfg(target_os = "macos")]
#[test]
fn an_attachment_is_served_at_interactive_priority_while_it_lasts() {
    let host = Host::new();
    let session = host.create(shell(
        "stty -echo; while IFS= read -r line; do printf 'ECHO:%s\\n' \"$line\"; done",
    ));
    let holder = holder_of(&host.sandbox, &session.id) as u32;
    let daemon = host.child.id();
    // Nothing attached: every thread at the default priority.
    wait_raised(holder, |raised| raised == 0);
    wait_raised(daemon, |raised| raised == 0);
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    input(&mut socket, b"hello\n");
    screen.wait_text(&mut socket, "ECHO:hello");
    // The holder's thread, and the daemon's session worker and connection
    // reader (its writer too, once it has something to write).
    wait_raised(holder, |raised| raised == 1);
    wait_raised(daemon, |raised| raised >= 2);
    send(&mut socket, &ClientMessage::Detach);
    loop {
        if matches!(receive(&mut socket), ServerMessage::Ok) {
            break;
        }
    }
    drop(socket);
    // Detached: back to the default, and the program never ran above it.
    wait_raised(holder, |raised| raised == 0);
    wait_raised(daemon, |raised| raised == 0);
    let program = session.pid.unwrap();
    assert!(
        thread_priorities(program)
            .into_iter()
            .all(|priority| priority <= 31),
        "the session's program runs at the default priority"
    );
}

/// A session that shows the alternate screen, as a full-screen program
/// does, and says when it has.
fn full_screen_program(host: &Host) -> SessionInfo {
    host.create(shell(
        "stty -echo; printf '\\033[?1049h\\033[HFULLSCREEN'; exec sleep 60",
    ))
}

#[test]
fn a_lone_window_resizes_the_grid_at_once_and_a_full_screen_program_repaints_it() {
    let host = Host::new();
    let session = full_screen_program(&host);
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    screen.wait_text(&mut socket, "FULLSCREEN");
    host.wait(&session.id, |info| info.alternate_screen);
    // Two steps of a drag, sent back to back: the only window changes the
    // grid for each, with no replacement snapshot, since the program
    // repaints its screen itself.
    for (cols, rows) in [(90, 30), (91, 31)] {
        send(&mut socket, &ClientMessage::Resize { cols, rows });
    }
    screen.wait_size(&mut socket, 91, 31);
    assert_eq!(screen.resized, [(90, 30), (91, 31)]);
    assert_eq!(screen.attached, []);
    let info = host.session(&session.id);
    assert_eq!((info.cols, info.rows), (91, 31));
    // The copy still shows the program's screen.
    assert!(screen.text().contains("FULLSCREEN"), "{}", screen.text());

    // On the primary screen the window gets the screens without history,
    // at once too.
    let session = host.create(shell("stty -echo; printf 'SHELL$ '; exec sleep 60"));
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    screen.wait_text(&mut socket, "SHELL$");
    send(&mut socket, &ClientMessage::Resize { cols: 70, rows: 20 });
    screen.wait_size(&mut socket, 70, 20);
    assert_eq!(screen.attached, [AttachReason::Resize]);
    assert_eq!(screen.resized, []);
    assert!(screen.text().contains("SHELL$"), "{}", screen.text());
}

#[test]
fn a_window_that_waits_for_other_windows_still_gets_its_new_grid() {
    // A smaller window elsewhere holds the grid: this window's resize
    // changes nothing but its own view, and the other window's resize
    // brings both the new grid.
    let host = Host::new();
    let session = full_screen_program(&host);
    let (mut small, _, offset, snapshot) = host.attach(&session.id, 60, 20);
    let mut small_screen = Screen::new(60, 20, offset, &snapshot);
    small_screen.wait_text(&mut small, "FULLSCREEN");
    host.wait(&session.id, |info| info.alternate_screen);
    let (mut large, info, offset, snapshot) = host.attach(&session.id, 100, 40);
    assert_eq!((info.cols, info.rows), (60, 20));
    let mut large_screen = Screen::new(60, 20, offset, &snapshot);
    send(&mut small, &ClientMessage::Resize { cols: 70, rows: 24 });
    small_screen.wait_size(&mut small, 70, 24);
    large_screen.wait_size(&mut large, 70, 24);
    // Neither needed its history back: both follow with the program's own
    // repaint.
    assert_eq!(small_screen.resized, [(70, 24)]);
    assert_eq!(large_screen.resized, [(70, 24)]);
    assert_eq!(host.session(&session.id).cols, 70);
}

/// A full-screen program with history behind it (so a snapshot with
/// history takes a while), which repaints its screen for every new size.
/// The first thing it writes, at once, is a mark in the last column of the
/// first row, which wraps onto the second only at the width the terminal
/// has then; then the size, numbered rows filled nearly to the width, and
/// `DONE` last. Output made for one width and fed to a copy of another
/// shows.
fn repainting_program(host: &Host) -> SessionInfo {
    host.create(shell(
        r#"stty -echo
i=0
while [ $i -lt 12000 ]; do echo "history line $i ........................................................................"; i=$((i+1)); done
repaint() {
  printf '\033[1;999H<>'
  set -- $(stty size)
  printf '\033[1;1H%-15s' "SIZE $2x$1"
  dots=$(printf "%$(($2 - 6))s" "" | tr ' ' '.')
  i=2
  while [ $i -le "$1" ]; do printf '\033[%d;3H%d%s\033[K' "$i" "$i" "$dots"; i=$((i+1)); done
  printf '\033[1;16HDONE'
}
trap repaint WINCH
printf '\033[?1049h\033[2J\033[HREADY'
while :; do sleep 1 & wait $!; done"#,
    ))
}

/// The host's screen, as text.
fn host_screen(host: &Host, id: &str) -> String {
    match host.call(ClientMessage::Screen {
        id: id.into(),
        scrollback: false,
        max_lines: None,
    }) {
        ServerMessage::ScreenText { text, .. } => text,
        other => panic!("{other:?}"),
    }
}

/// Follow `socket` until the host shows the whole repaint for `size` and
/// the copy shows what the host does, at that size.
fn wait_for_the_repaint(
    host: &Host,
    id: &str,
    socket: &mut UnixStream,
    screen: &mut Screen,
    size: (u16, u16),
) {
    let needle = format!("{:<15}DONE", format!("SIZE {}x{}", size.0, size.1));
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    let expected = loop {
        let text = host_screen(host, id);
        if text.starts_with(&needle) {
            break text;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "the program never repainted for {size:?}:\n{text}"
        );
        std::thread::sleep(Duration::from_millis(20));
    };
    socket
        .set_read_timeout(Some(Duration::from_millis(100)))
        .unwrap();
    loop {
        let copy = screen.terminal.active_text().unwrap();
        if (screen.cols, screen.rows) == size && copy == expected {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "the copy ({}x{}) differs from the host's screen ({size:?}):\n{copy}\n--- host:\n{expected}",
            screen.cols,
            screen.rows,
        );
        match read_frame::<_, ServerMessage>(socket) {
            Ok(Some(message)) => screen.apply(&message),
            Ok(None) => panic!("the connection closed"),
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Err(error) => panic!("{error}"),
        }
    }
    socket
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
}

#[test]
fn a_window_that_follows_a_new_grid_gets_it_before_the_programs_repaint() {
    // Two windows, and the smaller grows: the grid takes the other's size.
    // That one, which showed a viewport, gets a snapshot with history; the
    // growing one keeps its copy, which must take the new size before the
    // program's repaint for it, whatever the snapshot costs.
    let host = Host::new();
    let session = repainting_program(&host);
    let id = session.id.clone();
    let (mut a, _, offset, snapshot) = host.attach(&id, 100, 30);
    let mut a_screen = Screen::new(100, 30, offset, &snapshot);
    host.wait(&id, |info| info.alternate_screen);
    let (mut b, info, offset, snapshot) = host.attach(&id, 80, 24);
    let mut b_screen = Screen::new(info.cols, info.rows, offset, &snapshot);
    wait_for_the_repaint(&host, &id, &mut b, &mut b_screen, (80, 24));
    wait_for_the_repaint(&host, &id, &mut a, &mut a_screen, (80, 24));
    for round in 0..3 {
        send(
            &mut b,
            &ClientMessage::Resize {
                cols: 120,
                rows: 40,
            },
        );
        wait_for_the_repaint(&host, &id, &mut b, &mut b_screen, (100, 30));
        wait_for_the_repaint(&host, &id, &mut a, &mut a_screen, (100, 30));
        if round < 2 {
            send(&mut b, &ClientMessage::Resize { cols: 80, rows: 24 });
            wait_for_the_repaint(&host, &id, &mut b, &mut b_screen, (80, 24));
            wait_for_the_repaint(&host, &id, &mut a, &mut a_screen, (80, 24));
        }
    }
    // The copies that kept following the stream were not sent snapshots
    // for it (the holder answers right after the resize, before the
    // repaint is read), save by a rare chance.
    assert!(!b_screen.resized.is_empty() && !a_screen.resized.is_empty());
}

#[test]
fn a_window_whose_grid_a_new_window_shrinks_gets_it_before_the_programs_repaint() {
    // A smaller window attaches: the grid shrinks at once, and the window
    // already attached must take the new size before the program's
    // repaint for it, however long the new window's snapshot takes.
    let host = Host::new();
    let session = repainting_program(&host);
    let id = session.id.clone();
    let (mut a, _, offset, snapshot) = host.attach(&id, 100, 30);
    let mut a_screen = Screen::new(100, 30, offset, &snapshot);
    host.wait(&id, |info| info.alternate_screen);
    for (cols, rows) in [(80, 24), (70, 20), (60, 16)] {
        let (mut b, info, offset, snapshot) = host.attach(&id, cols, rows);
        assert_eq!((info.cols, info.rows), (cols, rows));
        let mut b_screen = Screen::new(info.cols, info.rows, offset, &snapshot);
        wait_for_the_repaint(&host, &id, &mut b, &mut b_screen, (cols, rows));
        wait_for_the_repaint(&host, &id, &mut a, &mut a_screen, (cols, rows));
        // B goes; A's own size comes back with its own repaint.
        send(&mut b, &ClientMessage::Detach);
        while !matches!(receive(&mut b), ServerMessage::Ok) {}
        drop(b);
        wait_for_the_repaint(&host, &id, &mut a, &mut a_screen, (100, 30));
    }
    // As a window that follows the stream, A was not sent snapshots for
    // the smaller grids, save by a rare chance.
    assert!(!a_screen.resized.is_empty());
}
