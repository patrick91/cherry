//! Sessions live in holder processes: they outlive the daemon, a new daemon
//! adopts them, and a holder that crashes takes only its own session along.
mod support;

use cherry_protocol::*;
use cherry_vt::Terminal;
use serde_json::json;
use std::{
    fs,
    os::unix::net::UnixStream,
    thread,
    time::{Duration, Instant},
};
use support::*;
use uuid::Uuid;

/// Read until the host closes the connection.
fn until_closed(socket: &mut UnixStream) {
    let _ = socket.set_read_timeout(Some(Duration::from_secs(5)));
    while let Ok(Some(_)) = read_frame::<_, ServerMessage>(socket) {}
}

fn echo(host: &Host) -> SessionInfo {
    host.create(shell(
        "stty -echo; printf 'READY\\n'; while IFS= read -r line; do printf 'ECHO:%s\\n' \"$line\"; done",
    ))
}

/// Attach and check that the session answers `line`.
fn echoes(host: &Host, id: &str, line: &str) {
    let (mut socket, _, offset, snapshot) = host.attach(id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    input(&mut socket, format!("{line}\n").as_bytes());
    screen.wait_text(&mut socket, &format!("ECHO:{line}"));
}

#[test]
fn a_killed_daemon_leaves_its_sessions_running_with_their_exact_screens() {
    let mut host = Host::new();
    let dir = host.dir().to_path_buf();
    // Output is flowing when the daemon dies: a counter redrawn in place,
    // which keeps the history short. The rest comes while no daemon runs,
    // up to a status query that the holder answers: then it has taken in
    // everything before it.
    let session = host.create(shell_in(
        &dir,
        r#"printf 'START\n'
i=0
while [ ! -e "$CHERRY_TEST_DIR/crashed" ]; do printf '\033[2;1Hcount %07d' $i; i=$((i+1)); done
printf '\n'
j=0
while [ $j -lt 150 ]; do printf 'down %04d\n' $j; j=$((j+1)); done
printf 'END\n'
stty raw -echo
printf '\033[5n'
dd bs=1 count=4 >/dev/null 2>&1
printf '%d' $i > "$CHERRY_TEST_DIR/count.tmp"
mv "$CHERRY_TEST_DIR/count.tmp" "$CHERRY_TEST_DIR/count"
exec sleep 60"#,
    ));
    let other = echo(&host);
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    screen.wait_text(&mut socket, "count");
    host.crash();
    fs::write(dir.join("crashed"), b"").unwrap();
    until_closed(&mut socket);
    let count = dir.join("count");
    wait_until("the program to finish while no daemon runs", || {
        count.exists()
    });
    let count: u64 = fs::read_to_string(&count).unwrap().parse().unwrap();
    host.respawn();
    let sessions = host.adopted();
    for (id, pid) in [(&session.id, session.pid), (&other.id, other.pid)] {
        let adopted = sessions.iter().find(|s| &s.id == id).expect("adopted");
        assert_eq!(adopted.state, SessionState::Running);
        assert_eq!(adopted.pid, pid);
        assert_eq!(adopted.name, "test");
    }
    // Reattached, its snapshot shows exactly what the program wrote, the
    // output while no daemon ran included, and live output would follow
    // at its end.
    let mut transcript = b"START\r\n".to_vec();
    for i in 0..count {
        transcript.extend_from_slice(format!("\x1b[2;1Hcount {i:07}").as_bytes());
    }
    transcript.extend_from_slice(b"\r\n");
    for j in 0..150 {
        transcript.extend_from_slice(format!("down {j:04}\r\n").as_bytes());
    }
    transcript.extend_from_slice(b"END\r\n");
    let (_socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    assert_eq!(offset, transcript.len() as u64);
    let reattached = Screen::new(80, 24, offset, &snapshot);
    let mut reference = Terminal::new(80, 24, 1024 * 1024).unwrap();
    reference.feed(&transcript);
    let (actual, expected) = (
        reattached.terminal.inspect().unwrap(),
        reference.inspect().unwrap(),
    );
    assert!(expected.history.len() > 100, "{expected:?}");
    assert_eq!(actual, expected);
    echoes(&host, &other.id, "STILL_HERE");
    assert_eq!(host.sessions().len(), 2);
}

#[test]
fn a_crashed_holder_ends_only_its_own_session() {
    let mut host = Host::new();
    let doomed = host.create(shell("exec sleep 60"));
    let survivor = echo(&host);
    let (mut watcher, _, offset, snapshot) = host.attach(&doomed.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    let holder = holder_of(&host.sandbox, &doomed.id);
    // As a failed safety check in the terminal parser would end it.
    unsafe {
        libc::kill(holder, libc::SIGKILL);
    }
    // Its session is over: the attached client hears so, and the program
    // got the hangup.
    assert_eq!(screen.wait_exit(&mut watcher), (1, None));
    let lost = host.wait(&doomed.id, |s| s.state == SessionState::Exited);
    assert_eq!(lost.exit_code, Some(1));
    wait_until(
        "the program to end",
        || !is_live(doomed.pid.unwrap() as i32),
    );
    // The daemon and every other session carry on.
    assert!(host.child.try_wait().unwrap().is_none());
    assert_eq!(host.session(&survivor.id).state, SessionState::Running);
    echoes(&host, &survivor.id, "UNAFFECTED");
    // Reattaching shows the end; removing it forgets its manifest.
    let (mut socket, _, offset, snapshot) = host.attach(&doomed.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    assert_eq!(screen.wait_exit(&mut socket), (1, None));
    assert!(matches!(
        host.call(ClientMessage::Remove {
            id: doomed.id.clone()
        }),
        ServerMessage::Ok
    ));
    assert!(!holders(&host.sandbox)
        .iter()
        .any(|(id, _)| *id == doomed.id));
    assert_eq!(host.sessions().len(), 1);
}

#[test]
fn holders_register_again_with_the_next_daemon() {
    let mut host = Host::new();
    let running = echo(&host);
    let finished = host.create(shell("printf 'LAST_%s\\n' WORDS; exit 5"));
    host.wait(&finished.id, |s| s.state == SessionState::Exited);
    let finished_holder = holder_of(&host.sandbox, &finished.id);
    let waiting = host.create(shell_in(
        host.dir(),
        r#"while [ ! -e "$CHERRY_TEST_DIR/go" ]; do sleep 0.05; done; exit 6"#,
    ));
    host.crash();
    // This one ends while no daemon runs.
    fs::write(host.dir().join("go"), b"").unwrap();
    // Long enough for the holders to back off to their longest delay.
    thread::sleep(Duration::from_millis(2500));
    host.respawn();
    // The new daemon's first list waits a moment at most for the holders
    // it expects, which dial as soon as its socket appears (a loaded
    // machine may take longer to let them all in).
    let started = Instant::now();
    host.sessions();
    assert!(
        started.elapsed() < Duration::from_millis(1500),
        "{:?}",
        started.elapsed()
    );
    let sessions = host.adopted();
    let find = |id: &str| sessions.iter().find(|s| s.id == id).cloned().unwrap();
    assert_eq!(find(&running.id).state, SessionState::Running);
    assert_eq!(find(&running.id).pid, running.pid);
    let exited = find(&finished.id);
    assert_eq!(
        (exited.state, exited.exit_code, exited.exit_signal),
        (SessionState::Exited, Some(5), None)
    );
    let ended = find(&waiting.id);
    assert_eq!(
        (ended.state, ended.exit_code, ended.pid),
        (SessionState::Exited, Some(6), waiting.pid)
    );
    // An exited session still shows its last screen.
    let (mut socket, _, offset, snapshot) = host.attach(&finished.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    assert_eq!(screen.wait_exit(&mut socket), (5, None));
    assert!(screen.text().contains("LAST_WORDS"), "{}", screen.text());
    echoes(&host, &running.id, "AGAIN");
    // Once removed, its holder is done.
    assert!(matches!(
        host.call(ClientMessage::Remove {
            id: finished.id.clone()
        }),
        ServerMessage::Ok
    ));
    wait_until("the holder to exit", || !is_holder(finished_holder));
    assert!(!holders(&host.sandbox)
        .iter()
        .any(|(id, _)| *id == finished.id));
}

/// Sends SIGCONT to a stopped process when dropped, however a test ends.
struct Continue(i32);

impl Drop for Continue {
    fn drop(&mut self) {
        unsafe {
            libc::kill(self.0, libc::SIGCONT);
        }
    }
}

#[test]
fn a_retried_create_finds_its_session_after_a_daemon_restart() {
    // A restarted daemon learns what a holder launched, and for which
    // request, only once that holder registers again. A retried Create that
    // reaches it first must wait for the holder and find its session rather
    // than launch another. The holder is held back (stopped) until the
    // retry is waiting, and the wait is long here, so that the holder's
    // return decides, not the time.
    let mut host = Host::with_env(&[("CHERRY_HOST_HOLDER_WAIT_MS", "20000")]);
    let request = create_request(Uuid::new_v4().to_string(), shell("exec sleep 60"));
    let first = match host.call(request.clone()) {
        ServerMessage::Created { session } => session,
        other => panic!("{other:?}"),
    };
    let holder = holder_of(&host.sandbox, &first.id);
    let _continue = Continue(holder);
    assert_eq!(unsafe { libc::kill(holder, libc::SIGSTOP) }, 0);
    host.crash();
    host.respawn();
    // The retry is the new daemon's first request.
    let mut socket = host.connect();
    socket
        .set_read_timeout(Some(Duration::from_secs(30)))
        .unwrap();
    write_frame(&mut socket, &request).unwrap();
    let (sender, reply) = std::sync::mpsc::channel();
    thread::spawn(move || {
        let _ = sender.send(read_frame::<_, ServerMessage>(&mut socket));
    });
    assert!(
        reply.recv_timeout(Duration::from_millis(500)).is_err(),
        "the retry was answered before the holder registered"
    );
    assert_eq!(unsafe { libc::kill(holder, libc::SIGCONT) }, 0);
    match reply.recv_timeout(Duration::from_secs(15)).unwrap() {
        Ok(Some(ServerMessage::Created { session })) => assert_eq!(session.id, first.id),
        other => panic!("{other:?}"),
    }
    assert_eq!(host.sessions().len(), 1);
}

#[test]
fn sessions_report_their_title_working_directory_and_foreground_process() {
    let host = Host::new();
    let session = host.create(shell(
        "printf '\\033]2;Building things\\007\\033]7;file://host/tmp/place\\007'; exec sleep 60",
    ));
    let info = host.wait(&session.id, |s| {
        s.title.is_some()
            && s.pwd.is_some()
            && s.foreground.as_ref().is_some_and(|f| f.name == "sleep")
    });
    assert_eq!(info.title.as_deref(), Some("Building things"));
    assert_eq!(info.pwd.as_deref(), Some("file://host/tmp/place"));
    // The program itself is in the foreground: not busy.
    assert_eq!(info.foreground.unwrap().pid, session.pid.unwrap());
    // A job of its own in the foreground: busy.
    let busy = host.create(vec![
        "/bin/bash".into(),
        "-c".into(),
        "set -m; sleep 60; exit 0".into(),
    ]);
    let info = host.wait(&busy.id, |s| {
        s.foreground
            .as_ref()
            .is_some_and(|f| f.name == "sleep" && Some(f.pid) != s.pid)
    });
    assert_eq!(info.state, SessionState::Running);
    // After the exit the title stays, and nothing is in the foreground.
    host.kill(&session.id);
    let info = host.wait(&session.id, |s| s.state == SessionState::Exited);
    assert_eq!(info.foreground, None);
    assert_eq!(info.title.as_deref(), Some("Building things"));
}

/// A holder written out by hand, registering the way a holder of another
/// version would.
struct FakeHolder {
    link: UnixStream,
    id: String,
    /// The kinds the daemon sent.
    received: Vec<u8>,
    /// What the daemon said of attached clients (`Attended`), in order;
    /// `next` passes over those frames.
    attended: Vec<bool>,
    /// How far the daemon let the program's output be read (`Pace`), in
    /// order; `next` passes over those frames too.
    paces: Vec<Option<u64>>,
}

impl FakeHolder {
    fn register(host: &Host, version: u16, hello: serde_json::Value) -> Self {
        let mut link = UnixStream::connect(&host.socket).unwrap();
        link.set_read_timeout(Some(Duration::from_secs(10)))
            .unwrap();
        let id = hello["id"].as_str().unwrap().to_string();
        link::send(&mut link, link::HOLDER_HELLO, version, hello, b"");
        Self {
            link,
            id,
            received: Vec::new(),
            attended: Vec::new(),
            paces: Vec::new(),
        }
    }

    fn next(&mut self) -> link::Frame {
        loop {
            let frame = link::next(&mut self.link);
            // Every frame carries the sender's link version.
            assert_eq!(frame.version, link::VERSION, "{frame:?}");
            self.received.push(frame.kind);
            if frame.kind == link::ATTENDED {
                self.attended
                    .push(frame.meta["attached"].as_bool().expect("attached"));
                continue;
            }
            if frame.kind == link::PACE {
                self.paces.push(frame.meta["limit"].as_u64());
                continue;
            }
            return frame;
        }
    }

    fn expect(&mut self, kind: u8) -> link::Frame {
        let frame = self.next();
        assert_eq!(frame.kind, kind, "{frame:?}");
        frame
    }

    fn send(&mut self, kind: u8, version: u16, meta: serde_json::Value, data: &[u8]) {
        link::send(&mut self.link, kind, version, meta, data);
    }
}

fn hello(id: &str, extra: serde_json::Value) -> serde_json::Value {
    let mut hello = json!({
        "id": id,
        "holder_pid": std::process::id(),
        "session": {
            "name": "fake",
            "cwd": "/tmp",
            "command": ["fake"],
            "cols": 80,
            "rows": 24,
            "running": true,
            "pid": 4242,
        },
        "offset": 5,
    });
    for (key, value) in extra.as_object().unwrap() {
        hello[key] = value.clone();
    }
    hello
}

#[test]
fn the_link_serves_holders_of_older_versions_and_ignores_what_it_does_not_know() {
    let host = Host::new();
    // Link version 1: the base set of messages, no metadata.
    let mut old = FakeHolder::register(
        &host,
        1,
        hello(
            &Uuid::new_v4().to_string(),
            json!({"future": {"nested": true}, "events": [{"kind": "sparkle"}, {"kind": "bell"}]}),
        ),
    );
    wait_until("the old holder's session", || {
        host.sessions().iter().any(|s| s.id == old.id)
    });
    let info = host.session(&old.id);
    assert_eq!(
        (
            info.name.as_str(),
            info.cols,
            info.rows,
            info.pid,
            info.state
        ),
        ("fake", 80, 24, Some(4242), SessionState::Running)
    );
    assert_eq!(info.title, None);
    assert_eq!(
        (
            info.alternate_screen,
            info.kitty_keyboard_flags,
            info.application_cursor_keys,
            info.bracketed_paste,
            info.request_id.clone()
        ),
        (false, 0, false, None, None)
    );
    let old_id = old.id.clone();
    thread::scope(|scope| {
        let client = scope.spawn(|| {
            let (mut socket, _, offset, snapshot) = host.attach(&old_id, 80, 24);
            assert_eq!((offset, snapshot.as_slice()), (5, &b"SNAP"[..]));
            match receive(&mut socket) {
                ServerMessage::Output { offset, data } => {
                    assert_eq!((offset, data.as_slice()), (5, &b"LIVE"[..]))
                }
                other => panic!("{other:?}"),
            }
            input(&mut socket, b"typed");
            send(&mut socket, &ClientMessage::Detach);
            loop {
                if matches!(receive(&mut socket), ServerMessage::Ok) {
                    break;
                }
            }
        });
        let request = old.expect(link::SNAPSHOT);
        assert_eq!(request.meta["kind"], "limited");
        // Frames of kinds it does not know, and fields it does not know,
        // change nothing.
        old.send(200, 1, json!({"whatever": 1}), b"ignored");
        old.send(
            link::SNAPSHOT_REPLY,
            1,
            json!({"req": request.meta["req"], "kind": "limited", "offset": 5, "cols": 80, "rows": 24, "later": [1, 2]}),
            b"SNAP",
        );
        old.send(link::OUTPUT, 1, json!({"offset": 5, "later": "x"}), b"LIVE");
        let input = old.expect(link::INPUT);
        assert_eq!(input.data, b"typed");
        let lease = input.meta["lease"].clone();
        assert!(lease.is_u64(), "{:?}", input.meta);
        old.send(link::INPUT_ACK, 1, json!({"lease": lease, "bytes": 5}), b"");
        let detach = old.expect(link::DETACH);
        assert_eq!(detach.meta["lease"], lease);
        old.send(
            link::DETACH_DONE,
            1,
            json!({"req": detach.meta["req"]}),
            b"",
        );
        client.join().unwrap();
    });
    // What version 1 cannot do: read its screen, clear its history, or
    // keep a new name for the next daemon (this one keeps it).
    match host.call(ClientMessage::Screen {
        id: old.id.clone(),
        scrollback: false,
        max_lines: None,
    }) {
        ServerMessage::Error { code, .. } => assert_eq!(code, error_code::UNSUPPORTED_OPERATION),
        other => panic!("{other:?}"),
    }
    match host.call(ClientMessage::ClearHistory { id: old.id.clone() }) {
        ServerMessage::Error { code, .. } => assert_eq!(code, error_code::UNSUPPORTED_OPERATION),
        other => panic!("{other:?}"),
    }
    assert_eq!(
        host.call(ClientMessage::Update {
            id: old.id.clone(),
            name: Some("renamed".into()),
            tags: None,
        }),
        ServerMessage::Ok
    );
    assert_eq!(host.session(&old.id).name, "renamed");
    host.kill(&old.id);
    old.expect(link::KILL);
    old.send(
        link::EXITED,
        1,
        json!({"exit_code": 3, "signal": null}),
        b"",
    );
    let exited = host.wait(&old.id, |s| s.state == SessionState::Exited);
    assert_eq!(exited.exit_code, Some(3));
    assert!(matches!(
        host.call(ClientMessage::Remove { id: old.id.clone() }),
        ServerMessage::Ok
    ));
    old.expect(link::REMOVE);
    assert!(link::read(&mut old.link).unwrap().is_none());
    // Only what version 1 knows was sent to it.
    assert!(
        old.received
            .iter()
            .all(|kind| (link::LAUNCH..=link::REMOVE).contains(kind)),
        "{:?}",
        old.received
    );

    // A newer holder: kinds and fields this daemon does not know are
    // ignored, and what it knows is applied.
    let newer = link::VERSION + 1;
    let request_id = Uuid::new_v4().to_string();
    let mut new = FakeHolder::register(
        &host,
        newer,
        hello(
            &Uuid::new_v4().to_string(),
            json!({"session": {
                "name": "newer",
                "cwd": "/tmp",
                "command": ["fake"],
                "cols": 100,
                "rows": 30,
                "running": true,
                "pid": 4343,
                "mood": "cheerful",
                "alternate_screen": true,
                "kitty_keyboard_flags": 7,
                "application_cursor_keys": true,
                "bracketed_paste": true,
            }, "receipt": {"request_id": request_id, "fingerprint": "f", "extra": 1}}),
        ),
    );
    new.send(250, newer, json!({}), b"");
    new.send(
        link::INFO,
        newer,
        json!({"title": "From a newer holder", "sparkle": {"level": 11}}),
        b"",
    );
    new.send(link::EVENT, newer, json!({"kind": "confetti"}), b"");
    wait_until("the newer holder's session", || {
        host.sessions().iter().any(|s| s.id == new.id)
    });
    let info = host.wait(&new.id, |s| s.title.is_some());
    assert_eq!(info.title.as_deref(), Some("From a newer holder"));
    assert_eq!(
        (info.name.as_str(), info.cols, info.rows),
        ("newer", 100, 30)
    );
    assert_eq!(
        (
            info.alternate_screen,
            info.kitty_keyboard_flags,
            info.application_cursor_keys,
            info.bracketed_paste,
            info.request_id.as_deref()
        ),
        (true, 7, true, Some(true), Some(request_id.as_str()))
    );
    new.send(
        link::INFO,
        newer,
        json!({"alternate_screen": false, "kitty_keyboard_flags": 1}),
        b"",
    );
    // Absent fields are unchanged.
    let changed = host.wait(&new.id, |s| {
        !s.alternate_screen && s.kitty_keyboard_flags == 1
    });
    assert!(changed.application_cursor_keys);
    new.send(
        link::INFO,
        newer,
        json!({"application_cursor_keys": false}),
        b"",
    );
    host.wait(&new.id, |s| !s.application_cursor_keys);
    new.send(link::INFO, newer, json!({"bracketed_paste": false}), b"");
    let changed = host.wait(&new.id, |s| s.bracketed_paste == Some(false));
    assert!(!changed.application_cursor_keys);
    // It is asked to clear its history, and the client hears how that went.
    let new_id = new.id.clone();
    thread::scope(|scope| {
        let cleared = scope.spawn(|| host.call(ClientMessage::ClearHistory { id: new_id.clone() }));
        let request = new.expect(link::CLEAR_HISTORY);
        new.send(
            link::HISTORY_CLEARED,
            newer,
            json!({"req": request.meta["req"], "outcome": "cleared"}),
            b"",
        );
        assert_eq!(cleared.join().unwrap(), ServerMessage::Ok);
        let kept = scope.spawn(|| host.call(ClientMessage::ClearHistory { id: new_id.clone() }));
        let request = new.expect(link::CLEAR_HISTORY);
        new.send(
            link::HISTORY_CLEARED,
            newer,
            json!({"req": request.meta["req"], "outcome": "alternate_screen"}),
            b"",
        );
        match kept.join().unwrap() {
            ServerMessage::Error { code, message } => {
                assert_eq!(code, error_code::REQUEST_FAILED);
                assert!(message.contains("alternate screen"), "{message}");
            }
            other => panic!("{other:?}"),
        }
    });
    host.kill(&new.id);
    new.expect(link::KILL);
    drop(new);
    // A holder that goes away without an exit is lost.
    let lost = host.wait(&info.id, |s| s.state == SessionState::Exited);
    assert_eq!(lost.exit_code, Some(1));

    // A holder older than any this daemon adopts is told so, for good.
    let mut ancient = FakeHolder::register(&host, 0, hello(&Uuid::new_v4().to_string(), json!({})));
    let refused = ancient.expect(link::REFUSED);
    assert_eq!(refused.meta["retry"], false);
    assert!(refused.meta["reason"].as_str().unwrap().contains("version"));
    assert!(link::read(&mut ancient.link).unwrap().is_none());
    assert!(!host.sessions().iter().any(|s| s.id == ancient.id));
}

/// Attach to a fake holder's session and detach, serving the holder's part.
fn attach_and_detach(host: &Host, holder: &mut FakeHolder) {
    let id = holder.id.clone();
    thread::scope(|scope| {
        let client = scope.spawn(|| {
            let (mut socket, _, _, snapshot) = host.attach(&id, 80, 24);
            assert_eq!(snapshot, b"SNAP");
            send(&mut socket, &ClientMessage::Detach);
            while !matches!(receive(&mut socket), ServerMessage::Ok) {}
        });
        let request = holder.expect(link::SNAPSHOT);
        holder.send(
            link::SNAPSHOT_REPLY,
            link::VERSION,
            json!({"req": request.meta["req"], "kind": "limited", "offset": 5, "cols": 80, "rows": 24}),
            b"SNAP",
        );
        let detach = holder.expect(link::DETACH);
        holder.send(
            link::DETACH_DONE,
            link::VERSION,
            json!({"req": detach.meta["req"]}),
            b"",
        );
        client.join().unwrap();
    });
}

#[test]
fn a_holder_is_told_while_a_client_is_attached() {
    let host = Host::new();
    let mut holder = FakeHolder::register(
        &host,
        link::VERSION,
        hello(&Uuid::new_v4().to_string(), json!({})),
    );
    wait_until("the session", || {
        host.sessions().iter().any(|s| s.id == holder.id)
    });
    // Once the client is attached, and before its detach is passed on.
    attach_and_detach(&host, &mut holder);
    assert_eq!(holder.attended, [true, false]);
    // A holder of link version 4 does not know the frame, and is not sent
    // it.
    let mut older = FakeHolder::register(&host, 4, hello(&Uuid::new_v4().to_string(), json!({})));
    wait_until("the older session", || {
        host.sessions().iter().any(|s| s.id == older.id)
    });
    attach_and_detach(&host, &mut older);
    assert!(older.attended.is_empty(), "{:?}", older.received);
}

#[test]
fn callers_share_a_screen_request_their_holder_has_not_answered() {
    let host = Host::new();
    let mut holder = FakeHolder::register(
        &host,
        link::VERSION,
        hello(&Uuid::new_v4().to_string(), json!({})),
    );
    wait_until("the session", || {
        host.sessions().iter().any(|s| s.id == holder.id)
    });
    let id = holder.id.clone();
    let screen = |scrollback| {
        host.call(ClientMessage::Screen {
            id: id.clone(),
            scrollback,
            max_lines: None,
        })
    };
    let text = |text: &str| ServerMessage::ScreenText {
        id: id.clone(),
        text: text.into(),
        cursor_row: 1,
        cursor_col: 2,
        alternate_screen: false,
    };
    thread::scope(|scope| {
        let first = scope.spawn(|| screen(false));
        let request = holder.expect(link::SCREEN);
        assert_eq!(request.meta["scrollback"], false);
        // Callers that come while it is pending wait for its answer, as
        // many as may: the holder (a stopped one, say) is not sent more.
        let others: Vec<_> = (0..64).map(|_| scope.spawn(|| screen(false))).collect();
        wait_until_for(
            "a caller to be turned away",
            Duration::from_secs(20),
            || others.iter().any(|other| other.is_finished()),
        );
        // One with the history is a request of its own.
        let history = scope.spawn(|| screen(true));
        let with_history = holder.expect(link::SCREEN);
        assert_eq!(with_history.meta["scrollback"], true);
        holder.send(
            link::SCREEN_REPLY,
            link::VERSION,
            json!({"req": request.meta["req"], "cursor_row": 1, "cursor_col": 2, "alternate_screen": false}),
            b"shared",
        );
        holder.send(
            link::SCREEN_REPLY,
            link::VERSION,
            json!({"req": with_history.meta["req"], "cursor_row": 1, "cursor_col": 2, "alternate_screen": false}),
            b"history\nshared",
        );
        assert_eq!(first.join().unwrap(), text("shared"));
        assert_eq!(history.join().unwrap(), text("history\nshared"));
        let mut answers: Vec<_> = others
            .into_iter()
            .map(|other| other.join().unwrap())
            .collect();
        let turned_away = answers
            .iter()
            .position(|answer| matches!(answer, ServerMessage::Error { .. }))
            .expect("one caller too many");
        assert_eq!(
            answers.remove(turned_away),
            ServerMessage::error(
                error_code::REQUEST_FAILED,
                "the session's holder is not answering"
            )
        );
        assert!(answers.iter().all(|answer| *answer == text("shared")));
    });
    // Answered, the next caller asks anew.
    thread::scope(|scope| {
        let next = scope.spawn(|| screen(false));
        let request = holder.expect(link::SCREEN);
        holder.send(
            link::SCREEN_REPLY,
            link::VERSION,
            json!({"req": request.meta["req"], "cursor_row": 1, "cursor_col": 2, "alternate_screen": false}),
            b"later",
        );
        assert_eq!(next.join().unwrap(), text("later"));
    });
}

#[test]
fn a_holder_that_does_not_answer_is_asked_for_a_few_screens_at_most() {
    let host = Host::new();
    let mut holder = FakeHolder::register(
        &host,
        link::VERSION,
        hello(&Uuid::new_v4().to_string(), json!({})),
    );
    wait_until("the session", || {
        host.sessions().iter().any(|s| s.id == holder.id)
    });
    let id = holder.id.clone();
    let id = id.as_str();
    let not_answering = ServerMessage::error(
        error_code::REQUEST_FAILED,
        "the session's holder is not answering",
    );
    let answer = |lines: u32| ServerMessage::ScreenText {
        id: id.into(),
        text: format!("{lines} lines"),
        cursor_row: 1,
        cursor_col: 1,
        alternate_screen: false,
    };
    let host = &host;
    thread::scope(|scope| {
        // Callers of eight kinds (each its own `max_lines`) each get a
        // request of their own while the holder does not answer.
        let callers: Vec<_> = (1..=8u32)
            .map(|lines| {
                scope.spawn(move || (lines, screen_of(host, id, lines % 2 == 0, Some(lines))))
            })
            .collect();
        let requests: Vec<_> = (0..8).map(|_| holder.expect(link::SCREEN)).collect();
        let mut asked: Vec<_> = requests
            .iter()
            .map(|request| request.meta["max_lines"].as_u64().unwrap())
            .collect();
        asked.sort_unstable();
        assert_eq!(asked, (1..=8).collect::<Vec<_>>());
        // With as many pending, a caller of another kind is turned away at
        // once, and the holder is not asked.
        assert_eq!(screen_of(host, id, false, Some(9)), not_answering);
        assert_eq!(screen_of(host, id, true, None), not_answering);
        for request in &requests {
            let lines = request.meta["max_lines"].as_u64().unwrap();
            holder.send(
                link::SCREEN_REPLY,
                link::VERSION,
                screen_reply(request, 1, false),
                format!("{lines} lines").as_bytes(),
            );
        }
        for caller in callers {
            let (lines, screen) = caller.join().unwrap();
            assert_eq!(screen, answer(lines));
        }
    });
    // Answered, it is asked again: the next request is the next caller's,
    // not one turned away.
    thread::scope(|scope| {
        let next = scope.spawn(|| screen_of(host, id, false, Some(10)));
        let request = holder.expect(link::SCREEN);
        assert_eq!(request.meta["max_lines"], 10);
        holder.send(
            link::SCREEN_REPLY,
            link::VERSION,
            screen_reply(&request, 1, false),
            b"10 lines",
        );
        assert_eq!(next.join().unwrap(), answer(10));
    });
}

/// A `Screen` of session `id`.
fn screen_of(host: &Host, id: &str, scrollback: bool, max_lines: Option<u32>) -> ServerMessage {
    host.call(ClientMessage::Screen {
        id: id.into(),
        scrollback,
        max_lines,
    })
}

/// The meta of a holder's answer to the screen request `request`.
fn screen_reply(request: &link::Frame, cursor_row: u16, alternate: bool) -> serde_json::Value {
    json!({
        "req": request.meta["req"],
        "cursor_row": cursor_row,
        "cursor_col": 1,
        "alternate_screen": alternate,
    })
}

#[test]
fn screens_are_limited_by_holders_that_can_and_for_those_that_cannot() {
    let host = Host::new();
    let session = json!({"session": {
        "name": "fake",
        "cwd": "/tmp",
        "command": ["fake"],
        "cols": 80,
        "rows": 3,
        "running": true,
        "pid": 4242,
    }});
    // Link version 2: screen text, but no `max_lines`.
    let older_version = 2;
    let mut older = FakeHolder::register(
        &host,
        older_version,
        hello(&Uuid::new_v4().to_string(), session.clone()),
    );
    let mut current = FakeHolder::register(
        &host,
        link::VERSION,
        hello(&Uuid::new_v4().to_string(), session),
    );
    let (older_id, current_id) = (older.id.clone(), current.id.clone());
    wait_until("both sessions", || {
        let sessions = host.sessions();
        [&older_id, &current_id]
            .iter()
            .all(|id| sessions.iter().any(|s| &&s.id == id))
    });
    let text =
        |id: &str, text: &str, cursor_row: u16, alternate_screen: bool| ServerMessage::ScreenText {
            id: id.into(),
            text: text.into(),
            cursor_row,
            cursor_col: 1,
            alternate_screen,
        };
    thread::scope(|scope| {
        // A holder of link version 2 is asked for the whole text, and the
        // daemon keeps its last lines. With the history, the screen (three
        // rows) is taken to end the text.
        let asked = scope.spawn(|| screen_of(&host, &older_id, true, Some(2)));
        let request = older.expect(link::SCREEN);
        assert_eq!(request.meta.get("max_lines"), None, "{:?}", request.meta);
        older.send(
            link::SCREEN_REPLY,
            older_version,
            screen_reply(&request, 2, false),
            b"h1\nh2\ns1\ns2\ns3",
        );
        assert_eq!(asked.join().unwrap(), text(&older_id, "s2\ns3", 1, false));
        // Without it, the cursor's row on the screen is its line.
        let asked = scope.spawn(|| screen_of(&host, &older_id, false, Some(2)));
        let request = older.expect(link::SCREEN);
        older.send(
            link::SCREEN_REPLY,
            older_version,
            screen_reply(&request, 0, true),
            b"s1\ns2\ns3",
        );
        assert_eq!(asked.join().unwrap(), text(&older_id, "s2\ns3", 0, true));
        // A holder of this version limits the text itself, and its answer
        // is passed on. Requests for different limits are different
        // requests.
        let two = scope.spawn(|| screen_of(&host, &current_id, true, Some(2)));
        let first = current.expect(link::SCREEN);
        let three = scope.spawn(|| screen_of(&host, &current_id, true, Some(3)));
        let second = current.expect(link::SCREEN);
        let unlimited = scope.spawn(|| screen_of(&host, &current_id, true, None));
        let third = current.expect(link::SCREEN);
        let mut limits: Vec<_> = [&first, &second, &third]
            .iter()
            .map(|request| request.meta.get("max_lines").cloned())
            .collect();
        limits.sort_by_key(|limit| limit.as_ref().map(|value| value.as_u64()));
        assert_eq!(limits, [None, Some(json!(2)), Some(json!(3))]);
        for request in [&first, &second, &third] {
            let (body, row): (&[u8], u16) = match request.meta.get("max_lines") {
                Some(limit) if limit == 2 => (b"s2\ns3", 1),
                Some(_) => (b"s1\ns2\ns3", 2),
                None => (b"h1\ns1\ns2\ns3", 2),
            };
            current.send(
                link::SCREEN_REPLY,
                link::VERSION,
                screen_reply(request, row, false),
                body,
            );
        }
        assert_eq!(two.join().unwrap(), text(&current_id, "s2\ns3", 1, false));
        assert_eq!(
            three.join().unwrap(),
            text(&current_id, "s1\ns2\ns3", 2, false)
        );
        assert_eq!(
            unlimited.join().unwrap(),
            text(&current_id, "h1\ns1\ns2\ns3", 2, false)
        );
    });
}

#[test]
fn terminal_state_and_create_request_ids_follow_sessions_to_the_next_daemon() {
    let mut host = Host::new();
    let dir = host.dir().to_path_buf();
    let request_id = Uuid::new_v4().to_string();
    let full = match host.call(create_request(
        request_id.clone(),
        shell("printf 'under\\n\\033[?1049h\\033[>3u\\033[?1hFULL'; exec sleep 60"),
    )) {
        ServerMessage::Created { session } => session,
        other => panic!("{other:?}"),
    };
    assert_eq!(full.request_id.as_deref(), Some(request_id.as_str()));
    host.wait(&full.id, |s| {
        s.alternate_screen && s.kitty_keyboard_flags == 3 && s.application_cursor_keys
    });
    // This one changes them while no daemon runs.
    let later = host.create(shell_in(
        &dir,
        r#"printf 'PRIMARY\n'
while [ ! -e "$CHERRY_TEST_DIR/go" ]; do sleep 0.02; done
printf '\033[?1047h\033[=9;1u\033[?1hLATER'
: > "$CHERRY_TEST_DIR/done"
exec sleep 60"#,
    ));
    assert_eq!(
        (
            later.alternate_screen,
            later.kitty_keyboard_flags,
            later.application_cursor_keys
        ),
        (false, 0, false)
    );
    host.crash();
    fs::write(dir.join("go"), b"").unwrap();
    wait_until("the change while no daemon runs", || {
        dir.join("done").exists()
    });
    host.respawn();
    wait_until("both sessions to be adopted", || {
        let sessions = host.sessions();
        [&full.id, &later.id]
            .iter()
            .all(|id| sessions.iter().any(|s| &&s.id == id))
    });
    let adopted = host.session(&full.id);
    assert_eq!(
        (
            adopted.alternate_screen,
            adopted.kitty_keyboard_flags,
            adopted.application_cursor_keys,
            adopted.request_id.as_deref()
        ),
        (true, 3, true, Some(request_id.as_str()))
    );
    let changed = host.wait(&later.id, |s| {
        s.alternate_screen && s.kitty_keyboard_flags == 9 && s.application_cursor_keys
    });
    assert_eq!(changed.request_id, later.request_id);
    assert!(changed.request_id.is_some());
    // The retried Create still finds its session.
    match host.call(create_request(
        request_id.clone(),
        shell("printf 'under\\n\\033[?1049h\\033[>3u\\033[?1hFULL'; exec sleep 60"),
    )) {
        ServerMessage::Created { session } => {
            assert_eq!(session.id, full.id);
            assert_eq!(session.request_id.as_deref(), Some(request_id.as_str()));
        }
        other => panic!("{other:?}"),
    }
    // Limited screens work as before.
    for (id, text) in [(&full.id, "FULL"), (&later.id, "LATER")] {
        match screen_of(&host, id, true, Some(1)) {
            ServerMessage::ScreenText {
                text: screen,
                cursor_row,
                cursor_col,
                alternate_screen,
                ..
            } => assert_eq!(
                (screen.as_str(), cursor_row, cursor_col, alternate_screen),
                (text, 0, text.len() as u16, true)
            ),
            other => panic!("{other:?}"),
        }
    }
}

/// The sessions a daemon lists, and how many holders it still waits for.
fn listing(host: &Host) -> (Vec<SessionInfo>, u32) {
    match host.call(ClientMessage::List) {
        ServerMessage::Sessions {
            sessions,
            pending_holders,
            ..
        } => (sessions, pending_holders),
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_list_counts_the_holders_a_new_daemon_still_waits_for() {
    let mut host = Host::new();
    let registered = echo(&host);
    let stopped = host.create(shell("exec sleep 60"));
    let doomed = host.create(shell("exec sleep 60"));
    assert_eq!(listing(&host).1, 0);
    let stopped_holder = holder_of(&host.sandbox, &stopped.id);
    let doomed_holder = holder_of(&host.sandbox, &doomed.id);
    host.crash();
    // Two holders cannot register with the next daemon for now.
    for holder in [stopped_holder, doomed_holder] {
        unsafe {
            libc::kill(holder, libc::SIGSTOP);
        }
    }
    host.respawn();
    // (The first list waits a second for them; a busy machine may take
    // longer to let the running holder in.)
    wait_until("the running holder to register", || {
        listing(&host).0.iter().any(|s| s.id == registered.id)
    });
    let (sessions, pending) = listing(&host);
    assert_eq!(pending, 2);
    let listed: Vec<&str> = sessions.iter().map(|s| s.id.as_str()).collect();
    assert_eq!(listed, [registered.id.as_str()]);
    // One that is gone is not waited for: its session is over.
    unsafe {
        libc::kill(doomed_holder, libc::SIGKILL);
    }
    wait_until("the holder to be gone", || !is_live(doomed_holder));
    let (sessions, pending) = listing(&host);
    assert_eq!((sessions.len(), pending), (1, 1));
    // The other registers once it runs again, and nothing is pending.
    unsafe {
        libc::kill(stopped_holder, libc::SIGCONT);
    }
    wait_until("the stopped holder to register", || {
        let (sessions, pending) = listing(&host);
        pending == 0 && sessions.iter().any(|s| s.id == stopped.id)
    });
    assert_eq!(host.session(&stopped.id).pid, stopped.pid);
    echoes(&host, &registered.id, "STILL_HERE");
}

#[test]
fn a_second_holder_for_a_session_already_served_is_turned_away() {
    let host = Host::new();
    let session = echo(&host);
    let mut impostor = FakeHolder::register(&host, link::VERSION, hello(&session.id, json!({})));
    // For now: the connected holder may be gone a moment later.
    assert_eq!(impostor.expect(link::REFUSED).meta["retry"], true);
    assert!(link::read(&mut impostor.link).unwrap().is_none());
    let info = host.session(&session.id);
    assert_eq!(info.pid, session.pid);
    echoes(&host, &session.id, "GENUINE");
}

#[test]
fn replacing_the_daemon_hands_its_sessions_to_the_next_one() {
    let mut host = Host::new();
    let session = echo(&host);
    let finished = host.create(shell("exit 4"));
    host.wait(&finished.id, |s| s.state == SessionState::Exited);
    let (mut attached, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    screen.wait_text(&mut attached, "READY");
    // As an upgraded client does.
    let mut newer = UnixStream::connect(&host.socket).unwrap();
    newer
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    write_frame(
        &mut newer,
        &ClientMessage::Hello {
            version: PROTOCOL_VERSION + 1,
        },
    )
    .unwrap();
    assert!(matches!(receive(&mut newer), ServerMessage::Welcome { .. }));
    write_frame(&mut newer, &ClientMessage::Replace).unwrap();
    assert!(matches!(receive(&mut newer), ServerMessage::Ok));
    // The client starts the next daemon at once.
    host.respawn();
    until_closed(&mut attached);
    assert!(host.wait_retired().iter().all(|status| status.success()));
    let sessions = host.adopted();
    assert_eq!(sessions.len(), 2, "{sessions:?}");
    // The attached client reattaches where it was.
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    assert!(screen.text().contains("READY"));
    input(&mut socket, b"REATTACHED\n");
    screen.wait_text(&mut socket, "ECHO:REATTACHED");
    assert_eq!(host.session(&finished.id).exit_code, Some(4));
    fs::metadata(&host.socket).unwrap();
}

#[test]
fn a_restart_hands_running_sessions_to_the_next_daemon_of_the_same_version() {
    let mut host = Host::new();
    let session = echo(&host);
    let finished = host.create(shell("exit 5"));
    host.wait(&finished.id, |s| s.state == SessionState::Exited);
    // Shutdown refuses while a session runs; Restart does not.
    match host.call(ClientMessage::Shutdown) {
        ServerMessage::Error { .. } => {}
        other => panic!("{other:?}"),
    }
    assert_eq!(host.call(ClientMessage::Restart), ServerMessage::Ok);
    // The client starts the next daemon at once.
    host.respawn();
    assert!(host.wait_retired().iter().all(|status| status.success()));
    let sessions = host.adopted();
    assert_eq!(sessions.len(), 2, "{sessions:?}");
    let adopted = sessions.iter().find(|s| s.id == session.id).unwrap();
    assert_eq!(
        (adopted.state, adopted.pid),
        (SessionState::Running, session.pid)
    );
    assert_eq!(host.session(&finished.id).exit_code, Some(5));
    echoes(&host, &session.id, "RESTARTED");
}

#[test]
fn shutting_down_ends_exited_sessions_and_their_holders() {
    let mut host = Host::new();
    let finished = host.create(shell("exit 3"));
    host.wait(&finished.id, |s| s.state == SessionState::Exited);
    let finished_holder = holder_of(&host.sandbox, &finished.id);
    // One whose holder is gone, and one still running.
    let lost = host.create(shell("exec sleep 60"));
    unsafe {
        libc::kill(holder_of(&host.sandbox, &lost.id), libc::SIGKILL);
    }
    host.wait(&lost.id, |s| s.state == SessionState::Exited);
    let running = host.create(shell("exec sleep 60"));
    let running_holder = holder_of(&host.sandbox, &running.id);
    assert!(matches!(
        host.call(ClientMessage::Shutdown),
        ServerMessage::Error { .. }
    ));
    host.kill(&running.id);
    host.wait(&running.id, |s| s.state == SessionState::Exited);
    assert!(matches!(
        host.call(ClientMessage::Shutdown),
        ServerMessage::Ok
    ));
    assert!(wait_child(&mut host.child, Duration::from_secs(5)).success());
    // Nothing is left for a next host: no holder, no manifest.
    wait_until("the holders to exit", || {
        !is_holder(finished_holder) && !is_holder(running_holder)
    });
    wait_until("the manifests to go", || holders(&host.sandbox).is_empty());
    host.respawn();
    assert_eq!(host.sessions(), []);
}

#[test]
fn a_manifest_naming_a_process_that_is_not_its_holder_is_dropped() {
    let mut host = Host::new();
    let sessions = host.sandbox.state_dir().join("sessions");
    host.crash();
    // The PID is taken, by a process that started at another time: the
    // holder is gone (a reboot, a reused PID).
    let mut other = std::process::Command::new("/bin/sleep")
        .arg("60")
        .spawn()
        .unwrap();
    let _stray = Stray::new(other.id() as i32);
    let id = Uuid::new_v4().to_string();
    fs::create_dir_all(&sessions).unwrap();
    let manifest = sessions.join(format!("{id}.json"));
    fs::write(
        &manifest,
        json!({
            "id": id,
            "holder_pid": other.id(),
            "created_at": 1,
            "link_version": link::VERSION,
            "holder_started": "not this process",
        })
        .to_string(),
    )
    .unwrap();
    host.respawn();
    assert!(!manifest.exists());
    assert_eq!(host.sessions(), []);
    other.kill().unwrap();
    other.wait().unwrap();
}

#[test]
fn sessions_start_after_the_installed_executable_moves_or_is_replaced() {
    let mut sandbox = Sandbox::new();
    let bin = sandbox.path().join("bin");
    fs::create_dir(&bin).unwrap();
    fs::copy(BIN, bin.join("cherry-host")).unwrap();
    sandbox.bin = bin.join("cherry-host");
    let host = Host::launch(sandbox, &[], None);
    let first = echo(&host);
    // Moved, as an app bundle can be.
    let moved = host.dir().join("moved");
    fs::rename(&bin, &moved).unwrap();
    let executable = moved.join("cherry-host");
    let second = echo(&host);
    echoes(&host, &second.id, "MOVED");
    // Replaced by another file, as upgrades install one.
    let fresh = moved.join("cherry-host.new");
    fs::copy(BIN, &fresh).unwrap();
    fs::rename(&fresh, &executable).unwrap();
    let third = echo(&host);
    echoes(&host, &third.id, "REPLACED");
    #[cfg(target_os = "linux")]
    {
        // Holders run the daemon's own build, not the file installed over
        // it, even once no file is left.
        let image =
            fs::read_link(format!("/proc/{}/exe", holder_of(&host.sandbox, &third.id))).unwrap();
        assert!(image.to_string_lossy().ends_with(" (deleted)"), "{image:?}");
        fs::remove_file(&executable).unwrap();
        let fourth = echo(&host);
        echoes(&host, &fourth.id, "REMOVED");
    }
    #[cfg(target_os = "macos")]
    {
        // Nothing is left to start, which the client hears.
        fs::remove_file(&executable).unwrap();
        match host.call(create_request(Uuid::new_v4().to_string(), shell("exit 0"))) {
            ServerMessage::Error { message, .. } => {
                assert!(message.contains("was removed"), "{message}")
            }
            other => panic!("{other:?}"),
        }
    }
    echoes(&host, &first.id, "FIRST");
}

fn touch(path: &std::path::Path) {
    fs::write(path, b"").unwrap();
}

#[test]
fn what_programs_report_while_no_daemon_runs_reaches_the_next_daemons_subscribers() {
    let mut host = Host::new();
    let dir = host.dir().to_path_buf();
    let (go, reported) = (dir.join("go"), dir.join("reported"));
    // Once told to go, the program reports things and then asks for a
    // status report, which its holder answers: by then it has taken them
    // in.
    let reporter = host.create(shell(&format!(
        r#"while [ ! -e '{go}' ]; do sleep 0.02; done
stty raw -echo
printf '\007\033]9;While away\007\033]9;4;1;30\007\033[5n'
dd bs=1 count=4 >/dev/null 2>&1
: > '{reported}'
exec sleep 60"#,
        go = go.display(),
        reported = reported.display(),
    )));
    let leaver = host.create(shell(&format!(
        "while [ ! -e '{}' ]; do sleep 0.02; done; exit 5",
        go.display()
    )));
    host.crash();
    touch(&go);
    wait_until("the reports", || reported.exists());
    wait_until("the exit", || is_gone(leaver.pid.unwrap()));
    host.respawn();
    // Subscribed after its holders registered again: what they kept waited
    // for a subscriber.
    let mut socket = subscribe(&host);
    let mut heard = Vec::new();
    while heard.len() < 3 {
        match next_event(&mut socket) {
            SessionEvent::Added { .. } | SessionEvent::Changed { .. } => {}
            SessionEvent::Exited { id, exit_code, .. } => {
                assert_eq!((id, exit_code), (leaver.id.clone(), 5))
            }
            event => heard.push(event),
        }
    }
    let id = reporter.id.clone();
    assert_eq!(
        heard,
        [
            SessionEvent::Bell { id: id.clone() },
            SessionEvent::Notification {
                id: id.clone(),
                title: String::new(),
                body: "While away".into()
            },
            SessionEvent::Progress {
                id,
                state: ProgressState::Set,
                value: Some(30)
            },
        ]
    );
    // The session that ended meanwhile is listed as it ended.
    let ended = host.wait(&leaver.id, |s| s.state == SessionState::Exited);
    assert_eq!((ended.exit_code, ended.exit_signal), (Some(5), None));
    // Delivered once: a later subscriber hears none of it.
    let mut later = subscribe(&host);
    write_frame(&mut later, &ClientMessage::Ping).unwrap();
    loop {
        match receive(&mut later) {
            ServerMessage::Pong => break,
            ServerMessage::Event {
                event: SessionEvent::Changed { .. },
            } => {}
            other => panic!("{other:?}"),
        }
    }
}

#[test]
fn what_a_holder_kept_follows_its_session_to_subscribers() {
    let host = Host::new();
    let mut socket = subscribe(&host);
    let id = Uuid::new_v4().to_string();
    let _ended = FakeHolder::register(
        &host,
        link::VERSION,
        hello(
            &id,
            json!({
                "session": {
                    "name": "kept",
                    "cwd": "/tmp",
                    "command": ["fake"],
                    "cols": 80,
                    "rows": 24,
                    "running": false,
                    "pid": 4242,
                    "exit_code": 9,
                    "title": "Finished",
                },
                "events": [
                    {"kind": "notification", "title": "Build", "body": "done"},
                    {"kind": "sparkle"},
                    {"kind": "bell"},
                    {"kind": "progress", "state": "remove"},
                    {"kind": "exited", "exit_code": 9, "signal": null},
                ],
            }),
        ),
    );
    match next_event(&mut socket) {
        SessionEvent::Added { session } => {
            assert_eq!(session.id, id);
            assert_eq!(
                (session.state, session.exit_code, session.title.as_deref()),
                (SessionState::Exited, Some(9), Some("Finished"))
            );
        }
        other => panic!("{other:?}"),
    }
    for expected in [
        SessionEvent::Notification {
            id: id.clone(),
            title: "Build".into(),
            body: "done".into(),
        },
        SessionEvent::Bell { id: id.clone() },
        SessionEvent::Progress {
            id: id.clone(),
            state: ProgressState::Remove,
            value: None,
        },
        SessionEvent::Exited {
            id: id.clone(),
            exit_code: 9,
            signal: None,
        },
    ] {
        assert_eq!(next_event(&mut socket), expected);
    }
    // An exit its hello does not show is not believed.
    let running = Uuid::new_v4().to_string();
    let _running = FakeHolder::register(
        &host,
        link::VERSION,
        hello(
            &running,
            json!({"events": [{"kind": "exited", "exit_code": 1}, {"kind": "bell"}]}),
        ),
    );
    assert!(matches!(
        next_event(&mut socket),
        SessionEvent::Added { session } if session.id == running && session.state == SessionState::Running
    ));
    assert_eq!(next_event(&mut socket), SessionEvent::Bell { id: running });
}

#[test]
fn a_subscriber_that_falls_behind_is_told_to_resync_and_stays_connected() {
    let host = Host::new();
    // It reads nothing for now.
    let mut lagging = subscribe(&host);
    let mut holder = FakeHolder::register(
        &host,
        link::VERSION,
        hello(&Uuid::new_v4().to_string(), json!({})),
    );
    // Far more than the host queues for a subscriber and any socket holds.
    let body = "x".repeat(256 * 1024);
    let sent = 128;
    for n in 0..sent {
        holder.send(
            link::EVENT,
            link::VERSION,
            json!({"kind": "notification", "title": n.to_string(), "body": body}),
            b"",
        );
    }
    holder.send(
        link::EVENT,
        link::VERSION,
        json!({"kind": "notification", "title": "last"}),
        b"",
    );
    let (mut heard, mut resyncs) = (0, 0);
    loop {
        match next_event(&mut lagging) {
            SessionEvent::Added { .. } | SessionEvent::Changed { .. } => {}
            SessionEvent::Notification { title, .. } if title == "last" => break,
            SessionEvent::Notification { body: text, .. } => {
                assert_eq!(text.len(), body.len());
                heard += 1;
            }
            SessionEvent::Resync => resyncs += 1,
            other => panic!("{other:?}"),
        }
    }
    assert!(resyncs >= 1, "{heard} heard");
    assert!(heard < sent, "{heard} heard");
    // It was never dropped.
    write_frame(&mut lagging, &ClientMessage::Ping).unwrap();
    assert_eq!(receive(&mut lagging), ServerMessage::Pong);
    assert_eq!(host.sessions().len(), 1);
}

#[test]
fn a_refresh_that_meets_a_resize_the_program_repaints_for_still_gets_the_screens() {
    let host = Host::new();
    let mut holder = FakeHolder::register(
        &host,
        link::VERSION,
        hello(&Uuid::new_v4().to_string(), json!({})),
    );
    wait_until("the session", || {
        host.sessions().iter().any(|s| s.id == holder.id)
    });
    let id = holder.id.clone();
    let snapshot_reply = |holder: &mut FakeHolder,
                          request: &link::Frame,
                          kind: &str,
                          size: (u16, u16),
                          bytes: &[u8]| {
        holder.send(
            link::SNAPSHOT_REPLY,
            link::VERSION,
            json!({"req": request.meta["req"], "kind": kind, "offset": 5, "cols": size.0, "rows": size.1}),
            bytes,
        );
    };
    thread::scope(|scope| {
        // A window of the grid's size, and a larger one.
        let first = scope.spawn(|| host.attach(&id, 80, 24).0);
        let request = holder.expect(link::SNAPSHOT);
        snapshot_reply(&mut holder, &request, "limited", (80, 24), b"SNAP");
        let mut small = first.join().unwrap();
        let second = scope.spawn(|| host.attach(&id, 100, 30).0);
        let request = holder.expect(link::SNAPSHOT);
        snapshot_reply(&mut holder, &request, "limited", (80, 24), b"SNAP");
        let mut large = second.join().unwrap();
        // The small window shrinks the grid; the holder is asked where the
        // new size took effect, which it may answer without the screens
        // (the program on the alternate screen repaints).
        send(&mut small, &ClientMessage::Resize { cols: 70, rows: 20 });
        let resize = holder.expect(link::RESIZE);
        assert_eq!(
            (resize.meta["cols"].as_u64(), resize.meta["rows"].as_u64()),
            (Some(70), Some(20))
        );
        let resized = holder.expect(link::SNAPSHOT);
        assert_eq!(resized.meta["kind"], "resized");
        // Meanwhile the large window asks for the screens (it has no copy
        // to paint its viewport from); its input after it shows the host
        // took the request.
        send(&mut large, &ClientMessage::Refresh);
        input(&mut large, b"x");
        let typed = holder.expect(link::INPUT);
        assert_eq!(typed.data, b"x");
        // The answer carries no screens: the large window still gets them.
        snapshot_reply(&mut holder, &resized, "size", (70, 20), b"");
        let refresh = holder.expect(link::SNAPSHOT);
        assert_eq!(refresh.meta["kind"], "refresh");
        snapshot_reply(&mut holder, &refresh, "refresh", (70, 20), b"SCREENS");
        large
            .set_read_timeout(Some(Duration::from_secs(10)))
            .unwrap();
        let mut seen = Vec::new();
        loop {
            match receive(&mut large) {
                ServerMessage::Resized { cols, rows, .. } => {
                    seen.push(format!("resized {cols}x{rows}"))
                }
                ServerMessage::Attached {
                    reason, snapshot, ..
                } => {
                    assert_eq!(reason, AttachReason::Resize);
                    assert_eq!(snapshot, b"SCREENS");
                    seen.push("screens".into());
                    break;
                }
                _ => {}
            }
        }
        assert_eq!(seen, ["resized 70x20", "screens"]);
    });
}
