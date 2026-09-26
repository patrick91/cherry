//! Replacement snapshots when the shared grid changes size: small frames
//! whatever the history, screens that replay exactly, and the live-only
//! output that queued output being replaced still delivers.
mod support;

use cherry_protocol::*;
use cherry_vt::{Inspection, Terminal};
use std::{
    fs,
    os::unix::net::UnixStream,
    path::Path,
    thread,
    time::{Duration, Instant},
};
use support::*;

/// A snapshot starts with a reset; the screens-only replacement does not.
fn is_full(snapshot: &[u8]) -> bool {
    snapshot.starts_with(b"\x18\x1bc")
}

/// A renderer that shows the session's stream directly, like a window of
/// the grid's size: output is written as is; a full snapshot starts it over
/// (it begins with a reset), and a screens-only replacement is written over
/// what the window holds after the window took the new size.
struct Window {
    terminal: Terminal,
    offset: u64,
}

impl Window {
    fn new(cols: u16, rows: u16, offset: u64, snapshot: &[u8]) -> Self {
        let mut terminal = Terminal::new(cols, rows, 64 * 1024 * 1024).unwrap();
        terminal.feed(snapshot);
        Self { terminal, offset }
    }

    /// Apply output until an `Attached` arrives; returns it.
    fn until_attached(&mut self, socket: &mut UnixStream) -> (SessionInfo, u64, Vec<u8>) {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            assert!(Instant::now() < deadline, "no replacement snapshot");
            match receive(socket) {
                ServerMessage::Output { offset, data } => {
                    assert_eq!(offset, self.offset, "output out of sequence");
                    self.offset += data.len() as u64;
                    self.terminal.feed(&data);
                }
                ServerMessage::Attached {
                    session,
                    offset,
                    snapshot,
                    reason,
                    ..
                } => {
                    assert_eq!(reason, AttachReason::Resize);
                    return (session, offset, snapshot);
                }
                other => panic!("unexpected message {other:?}"),
            }
        }
    }

    /// Apply output until the screen shows `needle`.
    fn wait_text(&mut self, socket: &mut UnixStream, needle: &str) {
        let deadline = Instant::now() + Duration::from_secs(30);
        while !self.terminal.screen_text().unwrap().contains(needle) {
            assert!(Instant::now() < deadline, "timed out waiting for {needle}");
            match receive(socket) {
                ServerMessage::Output { offset, data } => {
                    assert_eq!(offset, self.offset, "output out of sequence");
                    self.offset += data.len() as u64;
                    self.terminal.feed(&data);
                }
                other => panic!("unexpected message {other:?}"),
            }
        }
    }

    fn replace(&mut self, session: &SessionInfo, offset: u64, snapshot: &[u8]) {
        if is_full(snapshot) {
            *self = Self::new(session.cols, session.rows, offset, snapshot);
        } else {
            self.terminal.resize(session.cols, session.rows).unwrap();
            self.terminal.feed(snapshot);
            self.offset = offset;
        }
    }

    /// Resize the window, as its user does, and apply what arrives until
    /// the replacement for the grid of that size: the screens only, which
    /// leave the history the window holds alone. Returns the sizes the grid
    /// had in between.
    fn resize_directly(
        &mut self,
        socket: &mut UnixStream,
        cols: u16,
        rows: u16,
    ) -> Vec<(u16, u16)> {
        send(socket, &ClientMessage::Resize { cols, rows });
        self.terminal.resize(cols, rows).unwrap();
        let history = self.terminal.inspect().unwrap().history;
        let mut between = Vec::new();
        loop {
            let (session, offset, refresh) = self.until_attached(socket);
            assert!(
                !is_full(&refresh) && refresh.len() < 16 * 1024,
                "{}",
                refresh.len()
            );
            if (session.cols, session.rows) == (cols, rows) {
                self.replace(&session, offset, &refresh);
                break;
            }
            between.push((session.cols, session.rows));
        }
        assert_eq!(self.terminal.inspect().unwrap().history, history);
        between
    }
}

/// Screens, cursor, modes and state, without history. The screens-only
/// replacement designates ASCII where Ghostty keeps its UTF-8 default (both
/// print alike).
fn screens(terminal: &Terminal) -> Inspection {
    let mut inspection = terminal.inspect().unwrap();
    inspection.history.clear();
    for slot in ["␛(B", "␛)B", "␛*B", "␛+B"] {
        inspection.state = inspection.state.replace(slot, "");
    }
    inspection
}

/// A replay of the full snapshot against the reference: everything, with
/// the history they share. Output arrives in other pieces on the host, which
/// can make its scrollback limit prune at another row.
#[track_caller]
fn assert_same(copy: &Terminal, reference: &Terminal) {
    let (copy, reference) = (copy.inspect().unwrap(), reference.inspect().unwrap());
    let shared = copy.history.len().min(reference.history.len());
    assert!(shared > 500, "{shared}");
    assert!(copy.history.len().abs_diff(reference.history.len()) < 20);
    assert_eq!(
        copy.history[copy.history.len() - shared..],
        reference.history[reference.history.len() - shared..]
    );
    let without_history = |mut inspection: Inspection| {
        inspection.history.clear();
        inspection
    };
    assert_eq!(without_history(copy), without_history(reference));
}

/// Styled history far larger than a screen (the host keeps 1 MiB of it),
/// then a cleared screen with a prompt, a hyperlink, modes and a cursor.
fn session_output() -> Vec<u8> {
    let mut bytes = Vec::new();
    for line in 0..6000u32 {
        bytes.extend(
            format!(
                "\x1b[38;2;{};{};{}mline {line:05} \x1b[48;5;{}m{}\x1b[0m\r\n",
                line % 256,
                (line * 7) % 256,
                (line * 13) % 256,
                line % 200,
                "x".repeat(40 + (line % 20) as usize)
            )
            .into_bytes(),
        );
    }
    bytes.extend_from_slice(b"\x1b[H\x1b[2J\x1b[1;32m$ \x1b[0mcat notes \x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\\r\n\x1b[44mREADY_MARK\x1b[0m\x1b[?2004h\x1b[?1h\x1b[3;5H");
    bytes
}

/// A session that writes `path` unchanged once it reads a line.
fn cat_session(host: &Host, path: &Path) -> SessionInfo {
    host.create(shell(&format!(
        "stty -echo; IFS= read -r go; stty raw; cat '{}'; exec sleep 60",
        path.display()
    )))
}

#[test]
fn resizes_send_screens_without_history_and_full_snapshots_where_needed() {
    let host = Host::new();
    let path = host.dir().join("output");
    let bytes = session_output();
    fs::write(&path, &bytes).unwrap();
    let session = cat_session(&host, &path);

    // The host's terminal, reproduced: the session started at 80x24.
    let mut reference = Terminal::new(80, 24, 1024 * 1024).unwrap();
    let (mut first, info, offset, snapshot) = host.attach(&session.id, 100, 30);
    assert_eq!((info.cols, info.rows), (100, 30));
    reference.resize(100, 30).unwrap();
    let mut first_window = Window::new(100, 30, offset, &snapshot);
    input(&mut first, b"go\n");
    first_window.wait_text(&mut first, "READY_MARK");
    reference.feed(&bytes);
    assert_eq!(screens(&first_window.terminal), screens(&reference));
    let retained = reference.inspect().unwrap().history.len();
    assert!(retained > 500, "{retained}");

    // A smaller client: the first window turns into a viewport and gets the
    // screens without history, a small frame; the new client, a full
    // snapshot with the history.
    let (mut second, info, offset, full) = host.attach(&session.id, 80, 24);
    assert_eq!((info.cols, info.rows), (80, 24));
    reference.resize(80, 24).unwrap();
    assert!(is_full(&full));
    let mut second_window = Window::new(80, 24, offset, &full);
    assert_same(&second_window.terminal, &reference);
    let (session_info, offset, refresh) = first_window.until_attached(&mut first);
    assert!(!is_full(&refresh));
    // Small however much history the session keeps.
    assert!(refresh.len() < 16 * 1024, "{}", refresh.len());
    assert!(
        refresh.len() * 10 < full.len(),
        "{} {}",
        refresh.len(),
        full.len()
    );
    // Over the content the window holds, and over a fresh copy (which a
    // viewport renderer rebuilds from it), the replacement shows the
    // session's screens.
    let mut copy = Terminal::new(80, 24, 1024 * 1024).unwrap();
    copy.feed(&refresh);
    assert_eq!(screens(&copy), screens(&reference));
    first_window.terminal.resize(80, 24).unwrap();
    let history = first_window.terminal.inspect().unwrap().history;
    first_window.replace(&session_info, offset, &refresh);
    assert_eq!(screens(&first_window.terminal), screens(&reference));
    assert_eq!(first_window.terminal.inspect().unwrap().history, history);

    // The smaller client grows: the grid follows it to 90x28. Its window
    // showed the stream, whose history it keeps, so it gets the screens
    // only, like the other.
    reference.resize(90, 28).unwrap();
    second_window.resize_directly(&mut second, 90, 28);
    assert_eq!(screens(&second_window.terminal), screens(&reference));
    let (session_info, offset, refresh) = first_window.until_attached(&mut first);
    assert!(
        !is_full(&refresh) && refresh.len() < 16 * 1024,
        "{}",
        refresh.len()
    );
    first_window.replace(&session_info, offset, &refresh);
    assert_eq!(screens(&first_window.terminal), screens(&reference));

    // Beyond the first window: the grid takes its size, and it is the one
    // that gets the full snapshot.
    send(
        &mut second,
        &ClientMessage::Resize {
            cols: 120,
            rows: 40,
        },
    );
    let (session_info, offset, snapshot) = first_window.until_attached(&mut first);
    assert_eq!((session_info.cols, session_info.rows), (100, 30));
    reference.resize(100, 30).unwrap();
    assert!(
        is_full(&snapshot) && snapshot.len() > 64 * 1024,
        "{}",
        snapshot.len()
    );
    first_window.replace(&session_info, offset, &snapshot);
    assert_same(&first_window.terminal, &reference);
    let (_, offset, refresh) = second_window.until_attached(&mut second);
    assert!(
        !is_full(&refresh) && refresh.len() < 16 * 1024,
        "{}",
        refresh.len()
    );
    let mut copy = Terminal::new(100, 30, 1024 * 1024).unwrap();
    copy.feed(&refresh);
    assert_eq!(screens(&copy), screens(&reference));
    second_window.offset = offset;

    // The larger client shrinks to exactly the grid another client holds:
    // no grid change, but its window now matches the grid and gets the
    // full snapshot.
    send(
        &mut second,
        &ClientMessage::Resize {
            cols: 100,
            rows: 30,
        },
    );
    let (session_info, _, snapshot) = second_window.until_attached(&mut second);
    assert_eq!((session_info.cols, session_info.rows), (100, 30));
    assert!(
        is_full(&snapshot) && snapshot.len() > 64 * 1024,
        "{}",
        snapshot.len()
    );
    let mut copy = Terminal::new(100, 30, 64 * 1024 * 1024).unwrap();
    copy.feed(&snapshot);
    assert_same(&copy, &reference);
}

#[test]
fn a_lone_clients_own_resizes_send_only_the_screens() {
    let host = Host::new();
    let path = host.dir().join("output");
    let bytes = session_output();
    fs::write(&path, &bytes).unwrap();
    let session = cat_session(&host, &path);
    let mut reference = Terminal::new(80, 24, 1024 * 1024).unwrap();
    let (mut socket, info, offset, snapshot) = host.attach(&session.id, 100, 30);
    assert_eq!((info.cols, info.rows), (100, 30));
    reference.resize(100, 30).unwrap();
    let mut window = Window::new(100, 30, offset, &snapshot);
    input(&mut socket, b"go\n");
    window.wait_text(&mut socket, "READY_MARK");
    reference.feed(&bytes);
    assert!(reference.inspect().unwrap().history.len() > 500);

    // A window drag that settles at each size: the window shows the
    // stream throughout, and each size brings the screens only, over what
    // the window holds, with its history left alone.
    for (cols, rows) in [(95, 29), (90, 28), (85, 27), (80, 26)] {
        reference.resize(cols, rows).unwrap();
        assert!(window.resize_directly(&mut socket, cols, rows).is_empty());
        assert_eq!(screens(&window.terminal), screens(&reference));
    }
    // A size the window leaves again before the grid follows: the window
    // is repainted at the grid's size, still without history.
    send(&mut socket, &ClientMessage::Resize { cols: 70, rows: 20 });
    window.terminal.resize(70, 20).unwrap();
    for (cols, rows) in window.resize_directly(&mut socket, 80, 26) {
        // Only on a machine too busy to read both within the settle time.
        reference.resize(cols, rows).unwrap();
    }
    reference.resize(80, 26).unwrap();
    assert_eq!(screens(&window.terminal), screens(&reference));
    // The window keeps the history it followed.
    let (history, retained) = (
        window.terminal.inspect().unwrap().history,
        reference.inspect().unwrap().history,
    );
    assert!(history.len() > 500);
    assert_eq!(
        history[history.len() - 100..],
        retained[retained.len() - 100..]
    );
}

/// Read a client that fell behind: every message in order (offsets checked
/// by `Screen`) until a replacement snapshot shows `until` and nothing more
/// arrives. Returns the data of each output message, marked when it
/// directly follows a replacement snapshot.
fn catch_up(screen: &mut Screen, socket: &mut UnixStream, until: &str) -> Vec<(bool, Vec<u8>)> {
    let mut output = Vec::new();
    let mut after_snapshot = false;
    let mut apply = |screen: &mut Screen, message: ServerMessage| {
        screen.apply(&message);
        let attached = matches!(message, ServerMessage::Attached { .. });
        if let ServerMessage::Output { data, .. } = message {
            output.push((after_snapshot, data));
        }
        after_snapshot = attached;
    };
    socket
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(60);
    while screen.attached.is_empty() || !screen.text().contains(until) {
        assert!(Instant::now() < deadline, "timed out:\n{}", screen.text());
        apply(screen, receive(socket));
    }
    // The session is idle now: what follows the replacement arrives at once.
    socket
        .set_read_timeout(Some(Duration::from_millis(500)))
        .unwrap();
    while let Ok(Some(message)) = read_frame::<_, ServerMessage>(socket) {
        apply(screen, message);
    }
    output
}

/// How often `needle` occurs in the output, and in output that directly
/// follows a replacement snapshot.
fn occurrences(output: &[(bool, Vec<u8>)], needle: &[u8]) -> (usize, usize) {
    let count = |data: &[u8]| {
        data.windows(needle.len())
            .filter(|window| *window == needle)
            .count()
    };
    output.iter().fold((0, 0), |(all, carried), (after, data)| {
        let n = count(data);
        (all + n, carried + if *after { n } else { 0 })
    })
}

/// Active rows, without the continuation mark of the first one (a screens-
/// only replacement has no history for it to continue).
fn active(screen: &Screen) -> Vec<String> {
    let mut rows = screen.terminal.inspect().unwrap().active;
    rows[0] = rows[0].trim_start_matches('↪').to_owned();
    rows
}

#[test]
fn a_resize_leaves_a_client_that_keeps_up_all_of_its_queued_output() {
    let host = Host::new();
    // About 1 MiB of output: more than a socket holds, well under a
    // client's output budget. Then what no snapshot carries: a clipboard
    // write, a title and a kitty image sent in two chunks, around a query,
    // which goes to the client that typed, apart from the output.
    let session = host.create(shell(
        "stty -echo; IFS= read -r go; stty raw; dd if=/dev/zero bs=65536 count=16 2>/dev/null | tr '\\0' x; printf '\\033]52;c;Q0xJUA==\\007\\033[?6n\\033]2;TITLE\\007\\033_Ga=T,f=24,s=1,v=1,m=1;AAAA\\033\\\\\\033_Gm=0;AAAA\\033\\\\\\r\\nFLOOD_DONE\\r\\n'; exec sleep 60",
    ));
    let (mut slow, _, start, snapshot) = host.attach(&session.id, 80, 24);
    let mut slow_screen = Screen::new(80, 24, start, &snapshot);
    let (mut fast, _, offset, snapshot) = host.attach(&session.id, 90, 30);
    let mut fast_screen = Screen::new(80, 24, offset, &snapshot);
    input(&mut fast, b"go\n");
    // The slow client does not read while the output arrives.
    fast_screen.wait_text(&mut fast, "FLOOD_DONE");
    // Replacements for sizes the grid moved on from are superseded while
    // queued (unless the socket took them), and the output stays.
    for (cols, rows) in [(70, 20), (60, 18), (50, 16)] {
        send(&mut fast, &ClientMessage::Resize { cols, rows });
        fast_screen.wait_size(&mut fast, cols, rows);
    }

    let output = catch_up(&mut slow_screen, &mut slow, "FLOOD_DONE");
    assert!(
        (1..=3).contains(&slow_screen.attached.len())
            && slow_screen
                .attached
                .iter()
                .all(|reason| *reason == AttachReason::Resize),
        "{:?}",
        slow_screen.attached
    );
    assert_eq!((slow_screen.cols, slow_screen.rows), (50, 16));
    // Every byte arrived, in order, before the replacement.
    let delivered: usize = output.iter().map(|(_, data)| data.len()).sum();
    assert_eq!(start + delivered as u64, slow_screen.offset);
    assert!(output.iter().all(|(after, _)| !after));
    let tokens = b"\x1b]52;c;Q0xJUA==\x07\x1b]2;TITLE\x07\x1b_Ga=T,f=24,s=1,v=1,m=1,q=2;AAAA\x1b\\\x1b_Gm=0,q=2;AAAA\x1b\\";
    let all: Vec<u8> = output.iter().flat_map(|(_, data)| data.clone()).collect();
    assert_eq!(occurrences(&[(false, all.clone())], tokens), (1, 0));
    assert!(slow_screen.queries.is_empty());
    let query_at = fast_screen.queries[0].0;
    assert_eq!(
        fast_screen
            .queries
            .iter()
            .map(|(_, data)| &data[..])
            .collect::<Vec<_>>(),
        [b"\x1b[?6n"]
    );
    // Where it stood in the output: right after the clipboard write.
    let clipboard = all
        .windows(tokens.len())
        .position(|window| window == tokens)
        .unwrap();
    assert_eq!(
        query_at,
        start + (clipboard + b"\x1b]52;c;Q0xJUA==\x07".len()) as u64
    );
    assert_eq!(slow_screen.offset, fast_screen.offset);
    assert_eq!(active(&slow_screen), active(&fast_screen));
}

#[test]
fn a_resync_delivers_the_clipboard_writes_of_output_the_client_missed() {
    let host = Host::new();
    // About 12 MiB: more than a client may have waiting for it (its socket,
    // which Linux lets hold up to 3 MiB, and its 4 MiB output budget). A
    // clipboard write and a title follow the first MiB, and another title
    // comes last.
    let session = host.create(shell(
        "stty -echo; IFS= read -r go; stty raw; dd if=/dev/zero bs=65536 count=16 2>/dev/null | tr '\\0' x; printf '\\033]2;FIRST\\007\\033]52;c;Q0xJUA==\\007'; dd if=/dev/zero bs=65536 count=176 2>/dev/null | tr '\\0' y; printf '\\033]2;SECOND\\007\\r\\nFLOOD_DONE\\r\\n'; exec sleep 60",
    ));
    let (mut slow, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut slow_screen = Screen::new(80, 24, offset, &snapshot);
    let (mut fast, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut fast_screen = Screen::new(80, 24, offset, &snapshot);
    input(&mut fast, b"go\n");
    fast_screen.wait_text(&mut fast, "FLOOD_DONE");

    let output = catch_up(&mut slow_screen, &mut slow, "FLOOD_DONE");
    assert!(
        slow_screen.attached.contains(&AttachReason::Resync),
        "{:?}",
        slow_screen.attached
    );
    // The clipboard write arrives once: after a resync snapshot when it
    // went with output that was dropped (all that the socket did not hold
    // when the client fell behind, so with ordinary socket buffers), or
    // with the output. The last title is the session's.
    assert_eq!(occurrences(&output, b"\x1b]52;c;Q0xJUA==\x07").0, 1);
    let all: Vec<u8> = output.iter().flat_map(|(_, data)| data.clone()).collect();
    let last_title = all
        .windows(4)
        .rposition(|window| window == b"\x1b]2;")
        .unwrap();
    assert!(all[last_title..].starts_with(b"\x1b]2;SECOND\x07"));
    // The fast client stopped reading once the marker showed, which may be
    // before the last bytes of the stream arrived.
    drain(&mut fast_screen, &mut fast);
    assert_eq!(slow_screen.offset, fast_screen.offset);
    assert_eq!(active(&slow_screen), active(&fast_screen));
}

/// Many lines where every cell has its own true colour: a large snapshot.
const STYLED_HISTORY: &str = r#"awk 'BEGIN { for (i = 0; i < 6000; i++) { line = ""; for (j = 0; j < 78; j++) line = line sprintf("\033[38;2;%d;%d;%dm%c", (i * 7 + j) % 256, (j * 13) % 256, (i + j * 3) % 256, 65 + (i + j) % 26); print line "\033[0m" } }'"#;

/// A holder that answers late, as one busy with a large history or a flood
/// does: stopped until dropped (or `resume`).
struct Stopped(i32);

impl Stopped {
    fn new(holder: i32) -> Self {
        unsafe { libc::kill(holder, libc::SIGSTOP) };
        Self(holder)
    }

    fn resume(self) {}
}

impl Drop for Stopped {
    fn drop(&mut self) {
        unsafe { libc::kill(self.0, libc::SIGCONT) };
    }
}

/// Take what the client has queued, until nothing arrives for a moment.
fn drain(screen: &mut Screen, socket: &mut UnixStream) {
    socket
        .set_read_timeout(Some(Duration::from_millis(500)))
        .unwrap();
    loop {
        match read_frame::<_, ServerMessage>(socket) {
            Ok(Some(message)) => screen.apply(&message),
            Ok(None) => panic!("the connection closed"),
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                break
            }
            Err(error) => panic!("{error}"),
        }
    }
    socket
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
}

#[test]
fn an_attach_answered_after_the_grid_changed_is_brought_to_the_new_grid() {
    let host = Host::new();
    let session = host.create(shell(
        "stty -echo; printf 'READY\\n'; while IFS= read -r line; do printf 'LINE:%s\\n' \"$line\"; done",
    ));
    let (mut first, _, offset, snapshot) = host.attach(&session.id, 100, 30);
    let mut first_screen = Screen::new(100, 30, offset, &snapshot);
    first_screen.wait_text(&mut first, "READY");
    let holder = Stopped::new(holder_of(&host.sandbox, &session.id));
    // A larger window attaches: the grid stays, and its snapshot is asked
    // for...
    let mut second = host.connect();
    send(
        &mut second,
        &ClientMessage::Attach {
            id: session.id.clone(),
            cols: 120,
            rows: 40,
            takeover: false,
            answers_queries: true,
            client_id: None,
        },
    );
    thread::sleep(Duration::from_millis(300));
    // ...before the other window makes the grid smaller.
    send(&mut first, &ClientMessage::Resize { cols: 90, rows: 25 });
    host.wait(&session.id, |info| (info.cols, info.rows) == (90, 25));
    holder.resume();
    // The snapshot shows the grid it was taken at; the new grid follows.
    let mut second_screen = match receive(&mut second) {
        ServerMessage::Attached {
            reason: AttachReason::Attach,
            session: attached,
            offset,
            snapshot,
            ..
        } => {
            assert_eq!((attached.cols, attached.rows), (100, 30));
            Screen::new(100, 30, offset, &snapshot)
        }
        other => panic!("expected the attach's snapshot, not {other:?}"),
    };
    second_screen.wait_size(&mut second, 90, 25);
    assert_eq!(second_screen.attached, [AttachReason::Resize]);
    first_screen.wait_size(&mut first, 90, 25);
    input(&mut first, b"after\n");
    second_screen.wait_text(&mut second, "LINE:after");
    first_screen.wait_text(&mut first, "LINE:after");
    assert_eq!(second_screen.offset, first_screen.offset);
    assert_eq!(second_screen.text(), first_screen.text());
}

#[test]
fn a_resync_answered_after_the_grid_changed_is_brought_to_the_new_grid() {
    let host = Host::new();
    // Far more styled output than a client may have queued: a client that
    // does not read falls behind, and stays behind, since the large resync
    // snapshot queued for it keeps it from catching up.
    let session = host.create(shell(&format!(
        "stty -echo; IFS= read -r start; {STYLED_HISTORY}; printf 'FLOOD_%s\\n' DONE; while IFS= read -r line; do printf 'LINE:%s\\n' \"$line\"; done"
    )));
    let (mut lagging, _, offset, snapshot) = host.attach(&session.id, 100, 30);
    let mut lagging_screen = Screen::new(100, 30, offset, &snapshot);
    let (mut active, _, offset, snapshot) = host.attach(&session.id, 100, 30);
    let mut screen = Screen::new(100, 30, offset, &snapshot);
    input(&mut active, b"start\n");
    active
        .set_read_timeout(Some(Duration::from_secs(30)))
        .unwrap();
    // The lagging socket is not read during the flood.
    screen.wait_text(&mut active, "FLOOD_DONE");
    let holder = Stopped::new(holder_of(&host.sandbox, &session.id));
    // The lagging client takes what was queued for it; its resync is asked
    // for then...
    drain(&mut lagging_screen, &mut lagging);
    thread::sleep(Duration::from_millis(300));
    // ...and the grid changes before the holder answers.
    send(&mut active, &ClientMessage::Resize { cols: 90, rows: 25 });
    host.wait(&session.id, |info| (info.cols, info.rows) == (90, 25));
    holder.resume();
    lagging_screen.wait_size(&mut lagging, 90, 25);
    let reasons = &lagging_screen.attached;
    let resync = reasons
        .iter()
        .rposition(|reason| *reason == AttachReason::Resync)
        .unwrap_or_else(|| panic!("no resync: {reasons:?}"));
    assert_eq!(reasons[resync + 1..], [AttachReason::Resize], "{reasons:?}");
    screen.wait_size(&mut active, 90, 25);
    input(&mut active, b"after\n");
    lagging_screen.wait_text(&mut lagging, "LINE:after");
    screen.wait_text(&mut active, "LINE:after");
    assert_eq!(lagging_screen.offset, screen.offset);
    assert_eq!(lagging_screen.text(), screen.text());
}

#[test]
fn a_refresh_is_answered_with_the_screens_of_the_grid() {
    let host = Host::new();
    let session = host.create(shell(
        "stty -echo; printf '\\033[?2004hREADY\\r\\n'; IFS= read -r line; printf 'GOT:%s\\r\\n' \"$line\"; exec sleep 60",
    ));
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut window = Window::new(80, 24, offset, &snapshot);
    window.wait_text(&mut socket, "READY");
    // A client that keeps no copy of the screen asks for one: the screens
    // of the grid at the stream's offset, which the window shows already.
    send(&mut socket, &ClientMessage::Refresh);
    let (grid, at, refresh) = window.until_attached(&mut socket);
    assert_eq!((grid.cols, grid.rows), (80, 24));
    assert_eq!(at, window.offset, "the replacement is placed in the stream");
    assert!(!is_full(&refresh) && refresh.len() < 16 * 1024);
    let mut copy = Terminal::new(80, 24, 0).unwrap();
    copy.feed(&refresh);
    assert!(copy.screen_text().unwrap().contains("READY"));
    assert!(copy
        .modes()
        .unwrap()
        .windows(8)
        .any(|m| m == b"\x1b[?2004h"));
    // Output goes on after it.
    input(&mut socket, b"after\n");
    window.replace(&grid, at, &refresh);
    window.wait_text(&mut socket, "GOT:after");
    // A Refresh without an attachment is refused.
    let mut control = host.connect();
    send(&mut control, &ClientMessage::Refresh);
    assert!(matches!(
        receive(&mut control),
        ServerMessage::Error { code, .. } if code == error_code::REQUEST_FAILED
    ));
}
