use cherry_protocol::*;
use cherry_vt::Terminal;
use std::{
    collections::BTreeMap,
    fs,
    os::unix::{fs::PermissionsExt, net::UnixStream},
    path::PathBuf,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};
use tempfile::TempDir;
use uuid::Uuid;

struct Host {
    _dir: TempDir,
    socket: PathBuf,
    child: Child,
}
impl Host {
    fn new() -> Self {
        let dir = tempfile::Builder::new()
            .prefix("ch-mux-")
            .tempdir_in("/tmp")
            .unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let socket = dir.path().join("host.sock");
        let child = Command::new(env!("CARGO_BIN_EXE_cherry-host"))
            .args(["serve", "--socket"])
            .arg(&socket)
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let mut host = Self {
            _dir: dir,
            socket,
            child,
        };
        // bind creates the socket pathname before listen accepts connections.
        // Readiness requires a real protocol handshake, not file existence.
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(status) = host.child.try_wait().unwrap() {
                panic!("host exited during startup: {status}");
            }
            match UnixStream::connect(&host.socket) {
                Ok(mut socket) => {
                    socket
                        .set_read_timeout(Some(Duration::from_secs(5)))
                        .unwrap();
                    socket
                        .set_write_timeout(Some(Duration::from_secs(5)))
                        .unwrap();
                    write_frame(
                        &mut socket,
                        &ClientMessage::Hello {
                            version: PROTOCOL_VERSION,
                        },
                    )
                    .unwrap();
                    assert!(matches!(
                        receive(&mut socket),
                        ServerMessage::Welcome {
                            version: PROTOCOL_VERSION,
                            ..
                        }
                    ));
                    break;
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
                    ) =>
                {
                    assert!(
                        Instant::now() < deadline,
                        "host did not become ready: {error}"
                    );
                    thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("host readiness connection failed: {error}"),
            }
        }
        host
    }
    fn connect(&self) -> UnixStream {
        let mut socket = UnixStream::connect(&self.socket).unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        socket
            .set_write_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        write_frame(
            &mut socket,
            &ClientMessage::Hello {
                version: PROTOCOL_VERSION,
            },
        )
        .unwrap();
        assert!(matches!(
            receive(&mut socket),
            ServerMessage::Welcome {
                version: PROTOCOL_VERSION,
                ..
            }
        ));
        socket
    }
    fn call(&self, request: ClientMessage) -> ServerMessage {
        let mut socket = self.connect();
        write_frame(&mut socket, &request).unwrap();
        receive(&mut socket)
    }
    fn create(&self, command: Vec<String>) -> SessionInfo {
        match self.call(create_request(Uuid::new_v4().to_string(), command)) {
            ServerMessage::Created { session } => session,
            other => panic!("create failed: {other:?}"),
        }
    }
    fn sessions(&self) -> Vec<SessionInfo> {
        match self.call(ClientMessage::List) {
            ServerMessage::Sessions { sessions, .. } => sessions,
            other => panic!("list failed {other:?}"),
        }
    }
    fn wait(&self, id: &str, predicate: impl Fn(&SessionInfo) -> bool) -> SessionInfo {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let info = self.sessions().into_iter().find(|s| s.id == id).unwrap();
            if predicate(&info) {
                return info;
            }
            assert!(
                Instant::now() < deadline,
                "session condition not met: {info:?}"
            );
            thread::sleep(Duration::from_millis(15));
        }
    }
    fn attach(&self, id: &str, cols: u16, rows: u16) -> (UnixStream, SessionInfo, u64, Vec<u8>) {
        self.attach_with_takeover(id, cols, rows, false)
    }
    fn attach_with_takeover(
        &self,
        id: &str,
        cols: u16,
        rows: u16,
        takeover: bool,
    ) -> (UnixStream, SessionInfo, u64, Vec<u8>) {
        let mut socket = self.connect();
        write_frame(
            &mut socket,
            &ClientMessage::Attach {
                id: id.into(),
                cols,
                rows,
                takeover,
            },
        )
        .unwrap();
        match receive(&mut socket) {
            ServerMessage::Attached {
                session,
                offset,
                snapshot,
            } => (socket, session, offset, snapshot),
            other => panic!("attach failed {other:?}"),
        }
    }
}
impl Drop for Host {
    fn drop(&mut self) {
        if let Ok(mut socket) = UnixStream::connect(&self.socket) {
            let _ = socket.set_read_timeout(Some(Duration::from_millis(500)));
            let _ = socket.set_write_timeout(Some(Duration::from_millis(500)));
            let _ = write_frame(
                &mut socket,
                &ClientMessage::Hello {
                    version: PROTOCOL_VERSION,
                },
            );
            if read_frame::<_, ServerMessage>(&mut socket).is_ok() {
                let _ = write_frame(&mut socket, &ClientMessage::List);
                if let Ok(Some(ServerMessage::Sessions { sessions, .. })) = read_frame(&mut socket)
                {
                    for session in sessions {
                        let _ = write_frame(&mut socket, &ClientMessage::Kill { id: session.id });
                        let _ = read_frame::<_, ServerMessage>(&mut socket);
                    }
                }
            }
        }
        thread::sleep(Duration::from_millis(150));
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
fn receive(socket: &mut UnixStream) -> ServerMessage {
    read_frame(socket)
        .unwrap()
        .expect("unexpected connection EOF")
}
fn create_request(request_id: String, command: Vec<String>) -> ClientMessage {
    ClientMessage::Create {
        request_id,
        name: "test".into(),
        cwd: "/tmp".into(),
        command,
        env: BTreeMap::new(),
        cols: 80,
        rows: 24,
    }
}
fn shell(script: &str) -> Vec<String> {
    vec!["/bin/sh".into(), "-c".into(), script.into()]
}

#[test]
fn disconnect_preserves_process_and_reattach_restores_screen_and_input() {
    let host = Host::new();
    let session = host.create(vec!["/bin/sh".into()]);
    let (mut first, _, _, _) = host.attach(&session.id, 80, 24);
    write_frame(
        &mut first,
        &ClientMessage::Input {
            data: b"printf 'CHERRY_PERSISTED\\n'\r".to_vec(),
        },
    )
    .unwrap();
    let mut output = Vec::new();
    while !String::from_utf8_lossy(&output).contains("CHERRY_PERSISTED\r\n") {
        if let ServerMessage::Output { data, .. } = receive(&mut first) {
            output.extend(data);
        }
    }
    drop(first);
    let detached = host.wait(&session.id, |s| !s.attached);
    assert_eq!(detached.pid, session.pid);
    assert_eq!(detached.state, SessionState::Running);
    let (mut second, resumed, mut offset, snapshot) = host.attach(&session.id, 100, 30);
    assert_eq!(resumed.pid, session.pid);
    assert_eq!((resumed.cols, resumed.rows), (100, 30));
    let mut renderer = Terminal::new(100, 30, 2000).unwrap();
    renderer.feed(&snapshot);
    assert!(renderer.screen_text().unwrap().contains("CHERRY_PERSISTED"));
    write_frame(
        &mut second,
        &ClientMessage::Input {
            data: b"printf 'AFTER_RECONNECT\\n'; exit 7\r".to_vec(),
        },
    )
    .unwrap();
    loop {
        match receive(&mut second) {
            ServerMessage::Output {
                offset: actual,
                data,
            } => {
                assert_eq!(actual, offset);
                offset += data.len() as u64;
                renderer.feed(&data);
            }
            ServerMessage::Exit { exit_code, .. } => {
                assert_eq!(exit_code, 7);
                break;
            }
            other => panic!("unexpected {other:?}"),
        }
    }
    assert!(renderer.screen_text().unwrap().contains("AFTER_RECONNECT"));
    assert_eq!(
        host.wait(&session.id, |s| s.state == SessionState::Exited)
            .exit_code,
        Some(7)
    );
}

#[test]
fn create_retry_is_idempotent_and_second_controller_shares_session() {
    let host = Host::new();
    let request = create_request(Uuid::new_v4().to_string(), shell("sleep 60"));
    let a = match host.call(request.clone()) {
        ServerMessage::Created { session } => session,
        _ => panic!(),
    };
    let b = match host.call(request) {
        ServerMessage::Created { session } => session,
        _ => panic!(),
    };
    assert_eq!(a.id, b.id);
    assert_eq!(a.pid, b.pid);
    assert_eq!(host.sessions().len(), 1);
    let (_first, _, _, _) = host.attach(&a.id, 80, 24);
    let (_second, shared, _, _) = host.attach(&a.id, 80, 24);
    assert_eq!(shared.pid, a.pid);
    assert!(matches!(
        host.call(ClientMessage::Shutdown),
        ServerMessage::Error { .. }
    ));
    assert!(matches!(
        host.call(ClientMessage::Kill { id: a.id.clone() }),
        ServerMessage::Ok
    ));
    host.wait(&a.id, |s| s.state == SessionState::Exited);
}

#[test]
fn takeover_moves_live_session_without_restarting_or_accepting_stale_input() {
    let host = Host::new();
    let session = host.create(shell(
        "stty -echo; printf 'ORIGINAL_SCREEN\\n'; while IFS= read -r line; do printf 'INPUT:%s\\n' \"$line\"; stty size; done",
    ));
    let (mut first, _, _, snapshot) = host.attach(&session.id, 80, 24);
    let mut original = Terminal::new(80, 24, 2000).unwrap();
    original.feed(&snapshot);
    while !original.screen_text().unwrap().contains("ORIGINAL_SCREEN") {
        if let ServerMessage::Output { data, .. } = receive(&mut first) {
            original.feed(&data);
        }
    }

    let (mut second, resumed, mut offset, snapshot) =
        host.attach_with_takeover(&session.id, 100, 30, true);
    assert_eq!(resumed.id, session.id);
    assert_eq!(resumed.pid, session.pid);
    assert_eq!(resumed.state, SessionState::Running);
    assert_eq!((resumed.cols, resumed.rows), (100, 30));
    let mut renderer = Terminal::new(100, 30, 2000).unwrap();
    renderer.feed(&snapshot);
    assert!(renderer.screen_text().unwrap().contains("ORIGINAL_SCREEN"));

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

    write_frame(&mut second, &ClientMessage::Resize { cols: 90, rows: 28 }).unwrap();
    write_frame(
        &mut second,
        &ClientMessage::Input {
            data: b"NEW_CONTROLLER\n".to_vec(),
        },
    )
    .unwrap();
    loop {
        match receive(&mut second) {
            ServerMessage::Output {
                offset: actual,
                data,
            } => {
                assert_eq!(actual, offset);
                offset += data.len() as u64;
                renderer.feed(&data);
                let text = renderer.screen_text().unwrap();
                assert!(!text.contains("STALE_INPUT"), "{text}");
                if text.contains("INPUT:NEW_CONTROLLER") && text.contains("28 90") {
                    break;
                }
            }
            ServerMessage::Attached {
                session,
                offset: actual,
                snapshot,
            } => {
                offset = actual;
                renderer = Terminal::new(session.cols, session.rows, 2000).unwrap();
                renderer.feed(&snapshot);
            }
            other => panic!("unexpected new controller reply: {other:?}"),
        }
    }
    let current = host.wait(&session.id, |s| s.cols == 90 && s.rows == 28);
    assert_eq!(current.pid, session.pid);
    assert!(current.attached);
    let (_third, shared, _, _) = host.attach(&session.id, 90, 28);
    assert_eq!(shared.pid, session.pid);
}

struct Screen {
    terminal: Terminal,
    offset: u64,
    cols: u16,
    rows: u16,
}

impl Screen {
    fn new(cols: u16, rows: u16, offset: u64, snapshot: &[u8]) -> Self {
        let mut terminal = Terminal::new(cols, rows, 2000).unwrap();
        terminal.feed(snapshot);
        Self {
            terminal,
            offset,
            cols,
            rows,
        }
    }

    fn receive(&mut self, socket: &mut UnixStream) {
        match receive(socket) {
            ServerMessage::Output { offset, data } => {
                assert_eq!(
                    offset, self.offset,
                    "live output must resume at snapshot's exact boundary"
                );
                self.offset += data.len() as u64;
                self.terminal.feed(&data);
            }
            ServerMessage::Attached {
                session,
                offset,
                snapshot,
            } => {
                *self = Self::new(session.cols, session.rows, offset, &snapshot);
            }
            other => panic!("unexpected screen message: {other:?}"),
        }
    }

    fn wait_text(&mut self, socket: &mut UnixStream, needle: &str) {
        while !self.terminal.screen_text().unwrap().contains(needle) {
            self.receive(socket);
        }
    }

    fn wait_size(&mut self, socket: &mut UnixStream, cols: u16, rows: u16) {
        while (self.cols, self.rows) != (cols, rows) {
            self.receive(socket);
        }
    }
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
    assert_eq!(screen1.offset, screen2.offset);
    assert_eq!(
        screen1.terminal.screen_text().unwrap(),
        screen2.terminal.screen_text().unwrap()
    );

    write_frame(
        &mut first,
        &ClientMessage::Input {
            data: b"FROM_FIRST\n".to_vec(),
        },
    )
    .unwrap();
    screen1.wait_text(&mut first, "24 80");
    screen2.wait_text(&mut second, "24 80");
    assert!(screen1
        .terminal
        .screen_text()
        .unwrap()
        .contains("INPUT:FROM_FIRST"));
    assert_eq!(
        screen1.terminal.screen_text().unwrap(),
        screen2.terminal.screen_text().unwrap()
    );
    write_frame(
        &mut second,
        &ClientMessage::Input {
            data: b"FROM_SECOND\n".to_vec(),
        },
    )
    .unwrap();
    screen1.wait_text(&mut first, "INPUT:FROM_SECOND");
    screen2.wait_text(&mut second, "INPUT:FROM_SECOND");

    // Each requested size is retained. Growing the smaller client grows the
    // shared PTY only as far as the other client's dimensions.
    write_frame(
        &mut second,
        &ClientMessage::Resize {
            cols: 120,
            rows: 40,
        },
    )
    .unwrap();
    screen1.wait_size(&mut first, 100, 30);
    screen2.wait_size(&mut second, 100, 30);
    assert_eq!(screen1.offset, screen2.offset);
    assert_eq!(
        screen1.terminal.screen_text().unwrap(),
        screen2.terminal.screen_text().unwrap()
    );

    write_frame(&mut first, &ClientMessage::Detach).unwrap();
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
    write_frame(
        &mut second,
        &ClientMessage::Input {
            data: b"STILL_RUNNING\n".to_vec(),
        },
    )
    .unwrap();
    screen2.wait_text(&mut second, "INPUT:STILL_RUNNING");
    screen2.wait_text(&mut second, "40 120");
    assert!(screen2
        .terminal
        .screen_text()
        .unwrap()
        .contains("INPUT:STILL_RUNNING"));
    let info = host.wait(&session.id, |s| s.cols == 120 && s.rows == 40);
    assert_eq!(info.pid, session.pid);
    assert!(info.attached);
    drop(second);
    let info = host.wait(&session.id, |s| !s.attached);
    assert_eq!(info.state, SessionState::Running);
}

#[test]
fn stalled_attachment_does_not_block_other_clients_or_the_pty() {
    let host = Host::new();
    let session = host.create(shell(
        "stty -echo; IFS= read -r start; chunk=$(printf '%8192s' ' ' | tr ' ' X); i=0; while [ $i -lt 256 ]; do printf '%s' \"$chunk\"; i=$((i+1)); sleep 0.005; done; printf '\\r\\nFLOOD_COMPLETE\\r\\n'; IFS= read -r line; printf 'LIVE:%s\\r\\n' \"$line\"; sleep 60",
    ));
    let (mut stalled, _, _, _) = host.attach(&session.id, 80, 24);
    let (mut active, _, offset, snapshot) = host.attach(&session.id, 100, 30);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    write_frame(
        &mut active,
        &ClientMessage::Input {
            data: b"start\n".to_vec(),
        },
    )
    .unwrap();
    // The stalled socket is intentionally never drained during the flood.
    screen.wait_text(&mut active, "FLOOD_COMPLETE");
    screen.wait_size(&mut active, 100, 30);
    write_frame(
        &mut active,
        &ClientMessage::Input {
            data: b"AFTER_SLOW_PEER\n".to_vec(),
        },
    )
    .unwrap();
    screen.wait_text(&mut active, "LIVE:AFTER_SLOW_PEER");
    assert_eq!(host.wait(&session.id, |s| s.cols == 100).pid, session.pid);
    // Shutdown may truncate a frame already being written to the slow socket.
    // Either EOF or a truncated-frame error demonstrates bounded disconnect.
    loop {
        match read_frame::<_, ServerMessage>(&mut stalled) {
            Ok(Some(ServerMessage::Output { .. })) => {}
            Ok(None) | Err(_) => break,
            other => panic!("unexpected stalled socket message: {other:?}"),
        }
    }
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

#[test]
fn reattach_inside_alternate_screen_restores_underlying_primary_buffer() {
    let host = Host::new();
    let session=host.create(shell(r"stty raw -echo; printf 'PRIMARY_SCREEN\033[?1049h\033[2J\033[HALTERNATE_SCREEN'; dd bs=1 count=1 >/dev/null 2>&1; printf '\033[?1049l'; sleep 2"));
    // Wait for the application to enter its alternate screen, not merely for spawn.
    let deadline = Instant::now() + Duration::from_secs(5);
    let (mut socket, mut renderer) = loop {
        let (socket, _, _, snapshot) = host.attach(&session.id, 80, 24);
        let mut renderer = Terminal::new(80, 24, 2000).unwrap();
        renderer.feed(&snapshot);
        if renderer.screen_text().unwrap().contains("ALTERNATE_SCREEN") {
            break (socket, renderer);
        }
        drop(socket);
        host.wait(&session.id, |s| !s.attached);
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(15));
    };
    write_frame(
        &mut socket,
        &ClientMessage::Input {
            data: b"x".to_vec(),
        },
    )
    .unwrap();
    loop {
        if let ServerMessage::Output { data, .. } = receive(&mut socket) {
            renderer.feed(&data);
            if renderer.screen_text().unwrap().contains("PRIMARY_SCREEN") {
                break;
            }
        }
    }
}

#[test]
fn invalid_protocol_and_launch_do_not_create_sessions() {
    let host = Host::new();
    let mut socket = UnixStream::connect(&host.socket).unwrap();
    write_frame(&mut socket, &ClientMessage::Hello { version: 999 }).unwrap();
    assert!(
        matches!(receive(&mut socket),ServerMessage::Error {code,..} if code=="version_mismatch")
    );
    let bad = ClientMessage::Create {
        request_id: Uuid::new_v4().to_string(),
        name: "bad".into(),
        cwd: "/does/not/exist".into(),
        command: vec![],
        env: BTreeMap::new(),
        cols: 80,
        rows: 24,
    };
    assert!(matches!(host.call(bad), ServerMessage::Error { .. }));
    assert!(host.sessions().is_empty());
}

#[test]
fn stdio_gateway_flushes_binary_frames_without_newlines() {
    let host = Host::new();
    let mut gateway = Command::new(env!("CARGO_BIN_EXE_cherry-host"))
        .args(["gateway", "--socket"])
        .arg(&host.socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    let mut input = gateway.stdin.take().unwrap();
    let mut output = gateway.stdout.take().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    let reader = thread::spawn(move || {
        let result = read_frame::<_, ServerMessage>(&mut output);
        let _ = tx.send(result);
    });
    write_frame(
        &mut input,
        &ClientMessage::Hello {
            version: PROTOCOL_VERSION,
        },
    )
    .unwrap();
    let result = rx.recv_timeout(Duration::from_secs(3));
    drop(input);
    let _ = gateway.kill();
    let _ = gateway.wait();
    reader.join().unwrap();
    assert!(matches!(
        result,
        Ok(Ok(Some(ServerMessage::Welcome { .. })))
    ));
}
