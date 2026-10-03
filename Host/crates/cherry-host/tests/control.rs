//! The control plane of protocol 4: events for subscribers, input and screen
//! text without attaching, renaming and retagging, and what a `Create` may
//! ask of the session's environment.
mod support;

use cherry_protocol::*;
use std::{
    collections::{BTreeMap, HashMap},
    fs,
    os::unix::net::UnixStream,
    path::Path,
    thread,
    time::{Duration, Instant},
};
use support::*;
use uuid::Uuid;

/// How long any wait for events may take.
const EVENT_WAIT: Duration = Duration::from_secs(20);

/// A connection subscribed to events, and its request IDs.
struct Control {
    socket: UnixStream,
    next_req: u64,
    /// Events that came while waiting for a reply.
    events: Vec<SessionEvent>,
}

impl Control {
    fn subscribe(host: &Host) -> Self {
        let mut control = Self {
            socket: host.connect(),
            next_req: 1,
            events: Vec::new(),
        };
        // The Ok comes before any event.
        write_frame(
            &mut control.socket,
            &Request::new(Some(99), ClientMessage::Subscribe),
        )
        .unwrap();
        let Response { req, message } = read_frame(&mut control.socket).unwrap().unwrap();
        assert_eq!((req, message), (Some(99), ServerMessage::Ok));
        control
    }

    /// Send a request and wait for its reply, keeping the events that come
    /// meanwhile.
    fn call(&mut self, message: ClientMessage) -> ServerMessage {
        let req = self.next_req;
        self.next_req += 1;
        write_frame(&mut self.socket, &Request::new(Some(req), message)).unwrap();
        loop {
            let Response {
                req: echoed,
                message,
            } = read_frame(&mut self.socket)
                .unwrap()
                .expect("the host closed the connection");
            match message {
                ServerMessage::Event { event } => {
                    assert_eq!(echoed, None);
                    self.events.push(event);
                }
                message => {
                    assert_eq!(echoed, Some(req), "{message:?}");
                    return message;
                }
            }
        }
    }

    /// Whether an event that satisfies `done` was kept meanwhile or comes
    /// within `wait`; the events stay kept.
    fn heard_within(&mut self, wait: Duration, done: impl Fn(&SessionEvent) -> bool) -> bool {
        if self.events.iter().any(&done) {
            return true;
        }
        let deadline = Instant::now() + wait;
        let heard = loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break false;
            }
            self.socket.set_read_timeout(Some(left)).unwrap();
            match read_frame::<_, Response>(&mut self.socket) {
                Ok(Some(Response {
                    req: None,
                    message: ServerMessage::Event { event },
                })) => {
                    let found = done(&event);
                    self.events.push(event);
                    if found {
                        break true;
                    }
                }
                Ok(Some(other)) => panic!("expected an event, not {other:?}"),
                Ok(None) => panic!("the host closed the connection"),
                Err(_) => break false,
            }
        };
        self.socket
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        heard
    }

    /// Events (first those kept meanwhile) until one satisfies `done`;
    /// returns all of them.
    fn events_until(
        &mut self,
        what: &str,
        done: impl Fn(&SessionEvent) -> bool,
    ) -> Vec<SessionEvent> {
        let deadline = Instant::now() + EVENT_WAIT;
        let mut events = std::mem::take(&mut self.events);
        if events.iter().any(&done) {
            return events;
        }
        loop {
            assert!(
                Instant::now() < deadline,
                "timed out waiting for {what}: {events:#?}"
            );
            match read_frame::<_, Response>(&mut self.socket) {
                Ok(Some(Response {
                    req: None,
                    message: ServerMessage::Event { event },
                })) => {
                    let found = done(&event);
                    events.push(event);
                    if found {
                        return events;
                    }
                }
                Ok(Some(other)) => panic!("expected an event, not {other:?}"),
                Ok(None) => panic!("the host closed the connection waiting for {what}"),
                // Nothing for a while: a heartbeat, and keep waiting.
                Err(_) => {
                    write_frame(&mut self.socket, &ClientMessage::Ping).unwrap();
                    loop {
                        match read_frame::<_, Response>(&mut self.socket)
                            .unwrap()
                            .unwrap()
                        {
                            Response {
                                message: ServerMessage::Pong,
                                ..
                            } => break,
                            Response {
                                message: ServerMessage::Event { event },
                                ..
                            } => {
                                let found = done(&event);
                                events.push(event);
                                if found {
                                    return events;
                                }
                            }
                            other => panic!("{other:?}"),
                        }
                    }
                }
            }
        }
    }
}

fn error(message: ServerMessage) -> (String, String) {
    match message {
        ServerMessage::Error { code, message } => (code, message),
        other => panic!("expected an error, not {other:?}"),
    }
}

fn create(
    host: &Host,
    cwd: &str,
    command: Vec<String>,
    env: BTreeMap<String, String>,
) -> ServerMessage {
    host.call(ClientMessage::Create {
        request_id: Uuid::new_v4().to_string(),
        name: "control".into(),
        cwd: cwd.into(),
        command,
        env,
        cols: 80,
        rows: 24,
        owner: None,
        tags: BTreeMap::new(),
        colors: None,
        cell_width: None,
        cell_height: None,
    })
}

fn created(message: ServerMessage) -> SessionInfo {
    match message {
        ServerMessage::Created { session } => session,
        other => panic!("create failed: {other:?}"),
    }
}

/// Of `id`'s events, those that are not `changed`.
fn reports(events: &[SessionEvent], id: &str) -> Vec<SessionEvent> {
    events
        .iter()
        .filter(|event| event_id(event) == Some(id))
        .filter(|event| !matches!(event, SessionEvent::Changed { .. }))
        .cloned()
        .collect()
}

fn event_id(event: &SessionEvent) -> Option<&str> {
    match event {
        SessionEvent::Added { session } | SessionEvent::Changed { session } => Some(&session.id),
        SessionEvent::Removed { id }
        | SessionEvent::Bell { id }
        | SessionEvent::Notification { id, .. }
        | SessionEvent::Progress { id, .. }
        | SessionEvent::Exited { id, .. } => Some(id),
        SessionEvent::Resync => None,
    }
}

/// The latest state `changed` events reported for `id`.
fn changes<'a>(events: &'a [SessionEvent], id: &'a str) -> impl Iterator<Item = &'a SessionInfo> {
    events.iter().filter_map(move |event| match event {
        SessionEvent::Changed { session } if session.id == id => Some(session),
        _ => None,
    })
}

fn touch(path: &Path) {
    fs::write(path, b"").unwrap();
}

#[test]
fn subscribers_hear_of_sessions_and_everything_their_programs_report() {
    let host = Host::new();
    let mut control = Control::subscribe(&host);
    let dir = host.dir();
    let (go, done) = (dir.join("go"), dir.join("done"));
    let session = host.create(shell(&format!(
        r#"while [ ! -e '{go}' ]; do sleep 0.02; done
printf '\033]2;Reporting\007\033]7;file://host/tmp/reports\007'
printf '\007\033]9;Plain\007\033]777;notify;Titled;With a body\007'
printf '\033]99;i=1:d=0;Kitty\033\\\033]99;i=1:p=body;says hi\033\\'
printf '\033]9;4;1;42\007'
while [ ! -e '{done}' ]; do sleep 0.02; done
exit 3"#,
        go = go.display(),
        done = done.display(),
    )));
    let id = session.id.clone();
    let added = control.events_until(
        "the new session",
        |event| matches!(event, SessionEvent::Added { session } if session.id == id),
    );
    assert!(
        reports(&added, &id).len() == 1,
        "the session is added before anything else of it: {added:#?}"
    );
    // Clients coming and going change the session.
    let (socket, ..) = host.attach(&id, 80, 24);
    control.events_until("an attached client", |event| {
        matches!(event, SessionEvent::Changed { session } if session.id == id && session.clients == 1 && session.attached)
    });
    drop(socket);
    control.events_until("no attached client", |event| {
        matches!(event, SessionEvent::Changed { session } if session.id == id && session.clients == 0 && !session.attached)
    });
    // What the program reports.
    touch(&go);
    let events = control.events_until(
        "the progress report",
        |event| matches!(event, SessionEvent::Progress { id: of, .. } if *of == id),
    );
    assert_eq!(
        reports(&events, &id),
        [
            SessionEvent::Bell { id: id.clone() },
            SessionEvent::Notification {
                id: id.clone(),
                title: String::new(),
                body: "Plain".into()
            },
            SessionEvent::Notification {
                id: id.clone(),
                title: "Titled".into(),
                body: "With a body".into()
            },
            SessionEvent::Notification {
                id: id.clone(),
                title: "Kitty".into(),
                body: "says hi".into()
            },
            SessionEvent::Progress {
                id: id.clone(),
                state: ProgressState::Set,
                value: Some(42)
            },
        ]
    );
    // What it reports as state, as a change (which may have come first).
    let reported = |event: &SessionEvent| {
        matches!(event, SessionEvent::Changed { session } if session.id == id
            && session.title.as_deref() == Some("Reporting")
            && session.pwd.as_deref() == Some("file://host/tmp/reports"))
    };
    if !events.iter().any(reported) {
        control.events_until("the title and directory", reported);
    }
    // The exit, and the session's end.
    touch(&done);
    let events = control.events_until(
        "the exit",
        |event| matches!(event, SessionEvent::Exited { id: of, .. } if *of == id),
    );
    assert_eq!(
        reports(&events, &id),
        [SessionEvent::Exited {
            id: id.clone(),
            exit_code: 3,
            signal: None,
            ended_by: None,
            holder_log: None,
        }]
    );
    // The change that says so follows the exit, never passes it.
    assert!(
        changes(&events, &id).all(|session| session.state == SessionState::Running),
        "{events:#?}"
    );
    let events = control.events_until("the exited state", |event| {
        matches!(event, SessionEvent::Changed { session } if session.id == id && session.state == SessionState::Exited)
    });
    let exited = changes(&events, &id).last().unwrap();
    assert_eq!(
        (exited.exit_code, exited.foreground.clone()),
        (Some(3), None)
    );
    assert!(matches!(
        control.call(ClientMessage::Remove { id: id.clone() }),
        ServerMessage::Ok
    ));
    let events = control.events_until(
        "the removal",
        |event| matches!(event, SessionEvent::Removed { id: of } if *of == id),
    );
    assert_eq!(
        reports(&events, &id),
        [SessionEvent::Removed { id: id.clone() }]
    );
}

#[test]
fn a_subscriber_hears_the_foreground_process_change() {
    let host = Host::new();
    let mut control = Control::subscribe(&host);
    let job = host.dir().join("job");
    // A job of its own (job control) in the foreground, which says which
    // process group it is and then becomes `sleep`.
    let session = host.create(vec![
        "/bin/bash".into(),
        "-c".into(),
        format!(
            r#"set -m; sh -c 'echo $$ > "$1"; exec sleep 60' sh '{}'; exit 0"#,
            job.display()
        ),
    ]);
    let job_pid = || {
        let written = fs::read_to_string(&job).ok()?;
        written.strip_suffix('\n')?.parse::<u32>().ok()
    };
    wait_until("the job to start", || job_pid().is_some());
    let foreground = ForegroundProcess {
        pid: job_pid().unwrap(),
        name: "sleep".into(),
    };
    // The host looks at the foreground only shortly after output or input,
    // so the job may have become `sleep` after its last look: type until it
    // looks again. (It may have been `sleep` by the time it was added.)
    let deadline = Instant::now() + EVENT_WAIT;
    let seen = |event: &SessionEvent| {
        matches!(event, SessionEvent::Added { session: s } | SessionEvent::Changed { session: s }
            if s.id == session.id && s.foreground.as_ref() == Some(&foreground))
    };
    while !control.heard_within(Duration::from_millis(1500), seen) {
        assert!(
            Instant::now() < deadline,
            "timed out waiting for sleep in the foreground: {:#?}",
            control.events
        );
        assert_eq!(
            control.call(ClientMessage::SendInput {
                id: session.id.clone(),
                data: b"\n".to_vec(),
            }),
            ServerMessage::Ok
        );
    }
    // A job of its own: busy.
    assert_ne!(Some(foreground.pid), session.pid);
    assert_eq!(host.session(&session.id).foreground, Some(foreground));
    host.kill(&session.id);
}

#[test]
fn send_input_types_into_a_session_nobody_is_attached_to() {
    let host = Host::new();
    let mut control = Control::subscribe(&host);
    let session = host.create(shell(
        "stty -echo; printf 'READY\\n'; while IFS= read -r line; do printf 'GOT:%s\\n' \"$line\"; done",
    ));
    let id = session.id.clone();
    for line in ["first", "second"] {
        assert_eq!(
            control.call(ClientMessage::SendInput {
                id: id.clone(),
                data: format!("{line}\n").into_bytes(),
            }),
            ServerMessage::Ok
        );
    }
    wait_until("the input to be read", || {
        match control_screen(&host, &id, false) {
            ServerMessage::ScreenText { text, .. } => text.contains("GOT:second"),
            other => panic!("{other:?}"),
        }
    });
    // An attached client sees it too.
    let (mut socket, _, offset, snapshot) = host.attach(&id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    assert_eq!(
        control.call(ClientMessage::SendInput {
            id: id.clone(),
            data: b"third\n".to_vec(),
        }),
        ServerMessage::Ok
    );
    screen.wait_text(&mut socket, "GOT:third");
    // What it cannot do.
    let (code, _) = error(control.call(ClientMessage::SendInput {
        id: Uuid::new_v4().to_string(),
        data: b"x".to_vec(),
    }));
    assert_eq!(code, error_code::UNKNOWN_SESSION);
    let (code, message) = error(control.call(ClientMessage::SendInput {
        id: id.clone(),
        data: vec![b'x'; MAX_INPUT_BYTES + 1],
    }));
    assert_eq!(code, error_code::REQUEST_FAILED);
    assert!(message.contains("exceeds"), "{message}");
    host.kill(&id);
    host.wait(&id, |s| s.state == SessionState::Exited);
    let (code, _) = error(control.call(ClientMessage::SendInput {
        id: id.clone(),
        data: b"late\n".to_vec(),
    }));
    assert_eq!(code, error_code::NOT_RUNNING);
    assert_eq!(control.call(ClientMessage::Ping), ServerMessage::Pong);
}

#[test]
fn send_input_to_a_program_that_stops_reading_is_refused_in_time() {
    let host = Host::with_env(&[("CHERRY_HOST_INPUT_WAIT_MS", "200")]);
    let session = host.create(shell("stty raw -echo; printf 'READY'; exec sleep 600"));
    let (mut attached, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    Screen::new(80, 24, offset, &snapshot).wait_text(&mut attached, "READY");
    drop(attached);
    let mut control = Control::subscribe(&host);
    let chunk = vec![b'x'; MAX_INPUT_BYTES];
    // The terminal takes some, the host holds a bounded amount more, and
    // then the program has to read.
    let mut accepted = 0;
    let refusal = loop {
        assert!(accepted < 1024, "the host kept taking input");
        match control.call(ClientMessage::SendInput {
            id: session.id.clone(),
            data: chunk.clone(),
        }) {
            ServerMessage::Ok => accepted += 1,
            other => break error(other),
        }
    };
    assert_eq!(refusal.0, error_code::REQUEST_FAILED);
    assert!(refusal.1.contains("not reading"), "{}", refusal.1);
    assert!(accepted >= 16, "{accepted}");
    // The connection carries on.
    assert_eq!(control.call(ClientMessage::Ping), ServerMessage::Pong);
    host.kill(&session.id);
    host.wait(&session.id, |s| s.state == SessionState::Exited);
    let (code, _) = error(control.call(ClientMessage::SendInput {
        id: session.id.clone(),
        data: b"x".to_vec(),
    }));
    assert_eq!(code, error_code::NOT_RUNNING);
}

fn control_screen(host: &Host, id: &str, scrollback: bool) -> ServerMessage {
    host.call(ClientMessage::Screen {
        id: id.into(),
        scrollback,
        max_lines: None,
    })
}

/// The screen once `ready` holds for its text.
fn screen_when(
    host: &Host,
    id: &str,
    scrollback: bool,
    ready: impl Fn(&str) -> bool,
) -> (String, u16, u16, bool) {
    let deadline = Instant::now() + EVENT_WAIT;
    loop {
        match control_screen(host, id, scrollback) {
            ServerMessage::ScreenText {
                id: of,
                text,
                cursor_row,
                cursor_col,
                alternate_screen,
            } => {
                assert_eq!(of, id);
                if ready(&text) {
                    return (text, cursor_row, cursor_col, alternate_screen);
                }
                assert!(Instant::now() < deadline, "screen never ready:\n{text}");
            }
            other => panic!("{other:?}"),
        }
        thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn the_screen_reads_as_text_with_or_without_its_history() {
    let host = Host::new();
    let session = host.create(shell(
        "stty -echo; i=1; while [ $i -le 60 ]; do printf 'line %d\\n' $i; i=$((i+1)); done; printf 'prompt> '; exec sleep 60",
    ));
    let (text, row, col, alternate) =
        screen_when(&host, &session.id, false, |text| text.contains("prompt>"));
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 24, "{text}");
    assert_eq!((lines[0], lines[23]), ("line 38", "prompt>"));
    assert_eq!((row, col, alternate), (23, 8, false));
    let (history, row, col, _) =
        screen_when(&host, &session.id, true, |text| text.contains("prompt>"));
    let lines: Vec<&str> = history.lines().collect();
    assert_eq!(lines.len(), 61, "{history}");
    assert_eq!(
        (lines[0], lines[59], lines[60]),
        ("line 1", "line 60", "prompt>")
    );
    // The cursor is on the screen, whatever history comes before it.
    assert_eq!((row, col), (23, 8));

    // A full-screen program's screen, over the primary one.
    let full = host.create(shell(
        "stty -echo; printf 'UNDERNEATH\\n'; printf '\\033[?1049h\\033[HFULL SCREEN\\033[3;5H'; exec sleep 60",
    ));
    for scrollback in [false, true] {
        let (text, row, col, alternate) = screen_when(&host, &full.id, scrollback, |text| {
            text.contains("FULL SCREEN")
        });
        assert!(!text.contains("UNDERNEATH"), "{text}");
        assert_eq!((row, col, alternate), (2, 4, true));
    }
    // An exited session's last screen stays readable until it is removed.
    host.kill(&session.id);
    host.wait(&session.id, |s| s.state == SessionState::Exited);
    let (text, ..) = screen_when(&host, &session.id, false, |_| true);
    assert!(text.contains("line 60\nprompt>"), "{text}");
    assert!(matches!(
        host.call(ClientMessage::Remove {
            id: session.id.clone()
        }),
        ServerMessage::Ok
    ));
    let (code, _) = error(control_screen(&host, &session.id, false));
    assert_eq!(code, error_code::UNKNOWN_SESSION);
    host.kill(&full.id);
}

/// A `Screen` limited to `max_lines`.
fn limited_screen(
    host: &Host,
    id: &str,
    scrollback: bool,
    max_lines: u32,
) -> (String, u16, u16, bool) {
    match host.call(ClientMessage::Screen {
        id: id.into(),
        scrollback,
        max_lines: Some(max_lines),
    }) {
        ServerMessage::ScreenText {
            id: of,
            text,
            cursor_row,
            cursor_col,
            alternate_screen,
        } => {
            assert_eq!(of, id);
            (text, cursor_row, cursor_col, alternate_screen)
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_limited_screen_is_its_last_lines_with_the_cursor_among_them() {
    let host = Host::new();
    // 60 lines, then a prompt that wraps onto a second row.
    let session = host.create(shell(
        "stty -echo; i=1; while [ $i -le 60 ]; do printf 'line %d\\n' $i; i=$((i+1)); done; printf 'prompt> %090d' 0; exec sleep 60",
    ));
    let prompt = format!("prompt> {}", "0".repeat(90));
    let (text, row, col, _) = screen_when(&host, &session.id, false, |text| {
        text.ends_with(&"0".repeat(90))
    });
    // Unlimited, the cursor is on the screen's last row, the prompt's
    // second.
    assert_eq!(text.lines().count(), 23, "{text}");
    assert_eq!((row, col), (23, 18));
    for (scrollback, max_lines, first, lines, row) in [
        (true, 3, "line 59", 3, 2),
        (true, 1, prompt.as_str(), 1, 0),
        (true, 1000, "line 1", 61, 60),
        (false, 1000, "line 39", 23, 22),
        (false, 5, "line 57", 5, 4),
    ] {
        let (text, cursor_row, cursor_col, alternate) =
            limited_screen(&host, &session.id, scrollback, max_lines);
        let all: Vec<&str> = text.split('\n').collect();
        assert_eq!(
            (all[0], all.len(), cursor_row, cursor_col, alternate),
            (first, lines, row, 18, false),
            "{scrollback} {max_lines}:\n{text}"
        );
        // The cursor's line is the prompt.
        assert_eq!(all[usize::from(cursor_row)], prompt);
    }
    // None at all.
    let (text, row, ..) = limited_screen(&host, &session.id, true, 0);
    assert_eq!((text.as_str(), row), ("", 0));
    // Blank rows below the text: the cursor is below its last line. (The
    // title says the cursor has moved.)
    let cleared = host.create(shell(
        "printf 'top\\n\\033[5;3H\\033]2;moved\\007'; exec sleep 60",
    ));
    host.wait(&cleared.id, |s| s.title.as_deref() == Some("moved"));
    let (text, row, col, _) = screen_when(&host, &cleared.id, false, |_| true);
    assert_eq!((text.as_str(), row, col), ("top", 4, 2));
    let (text_limited, row, col, _) = limited_screen(&host, &cleared.id, true, 10);
    assert_eq!((text_limited.as_str(), row, col), (text.as_str(), 4, 2));
    // A blank screen under history: 40 lines on 24 rows leave 17 in the
    // history, then the screen is cleared. The text is the history, and
    // the cursor is on the row after it.
    let blank = host.create(shell(
        "i=1; while [ $i -le 40 ]; do printf 'h%d\\n' $i; i=$((i+1)); done; printf '\\033[2J\\033[H\\033]2;blank\\007'; exec sleep 60",
    ));
    host.wait(&blank.id, |s| s.title.as_deref() == Some("blank"));
    for (scrollback, max_lines, first, lines, row) in [
        (true, 100, "h1", 17, 17),
        (true, 5, "h13", 5, 5),
        (false, 10, "", 1, 0),
    ] {
        let (text, cursor_row, cursor_col, _) =
            limited_screen(&host, &blank.id, scrollback, max_lines);
        let all: Vec<&str> = text.split('\n').collect();
        assert_eq!(
            (all[0], all.len(), cursor_row, cursor_col),
            (first, lines, row, 0),
            "{scrollback} {max_lines}:\n{text}"
        );
    }
    host.kill(&session.id);
    host.kill(&cleared.id);
    host.kill(&blank.id);
}

#[test]
fn subscribers_hear_the_alternate_screen_and_keyboard_flags_change() {
    let host = Host::new();
    let mut control = Control::subscribe(&host);
    let dir = host.dir();
    let (enter, keys, leave) = (dir.join("enter"), dir.join("keys"), dir.join("leave"));
    let session = host.create(shell(&format!(
        r#"stty -echo
printf '\033[1mstyled\033[0m\n'
while [ ! -e '{enter}' ]; do sleep 0.02; done
printf '\033[?1049h\033[>1u\033[>5uFULL'
while [ ! -e '{keys}' ]; do sleep 0.02; done
printf '\033[?1h'
while [ ! -e '{leave}' ]; do sleep 0.02; done
printf '\033[<2u\033[?1049l\033[?1l'
exec sleep 60"#,
        enter = enter.display(),
        keys = keys.display(),
        leave = leave.display(),
    )));
    let id = session.id.clone();
    let state = |session: &SessionInfo| {
        (
            session.alternate_screen,
            session.kitty_keyboard_flags,
            session.application_cursor_keys,
        )
    };
    assert_eq!(state(&session), (false, 0, false));
    control.events_until(
        "the new session",
        |event| matches!(event, SessionEvent::Added { session } if session.id == id),
    );
    touch(&enter);
    control.events_until("the full-screen program", |event| {
        matches!(event, SessionEvent::Changed { session } if session.id == id
            && state(session) == (true, 5, false))
    });
    assert_eq!(state(&host.session(&id)), (true, 5, false));
    // Application cursor keys alone are a change too.
    touch(&keys);
    control.events_until("application cursor keys", |event| {
        matches!(event, SessionEvent::Changed { session } if session.id == id
            && state(session) == (true, 5, true))
    });
    assert_eq!(state(&host.session(&id)), (true, 5, true));
    // Attached clients are told too, and the screen agrees.
    let (_attached, attached, ..) = host.attach(&id, 80, 24);
    assert_eq!(state(&attached), (true, 5, true));
    let (text, _, _, alternate) = screen_when(&host, &id, true, |text| text == "\nFULL");
    assert!(alternate, "{text}");
    touch(&leave);
    control.events_until("the primary screen again", |event| {
        matches!(event, SessionEvent::Changed { session } if session.id == id
            && state(session) == (false, 0, false))
    });
    host.kill(&id);
}

#[test]
fn a_request_the_host_cannot_decode_is_answered_and_the_connection_carries_on() {
    use std::io::Write;
    let host = Host::new();
    let mut control = Control::subscribe(&host);
    let raw = |control: &mut Control, body: &str| {
        let mut frame = (body.len() as u32).to_be_bytes().to_vec();
        frame.extend_from_slice(body.as_bytes());
        control.socket.write_all(&frame).unwrap();
        let Response { req, message } = loop {
            let response: Response = read_frame(&mut control.socket).unwrap().unwrap();
            if !matches!(response.message, ServerMessage::Event { .. }) {
                break response;
            }
        };
        (req, message)
    };
    // A newer client's request.
    let (req, message) = raw(&mut control, r#"{"op":"teleport","req":41,"id":"s"}"#);
    assert_eq!(req, Some(41));
    assert_eq!(error(message).0, error_code::UNSUPPORTED_OPERATION);
    // A known request with a field it cannot take (a colour that is not
    // ASCII hex).
    let (req, message) = raw(
        &mut control,
        r##"{"op":"create","req":42,"request_id":"6f1a2b3c-4d5e-4f60-8172-8394a5b6c7d8","name":"n","cwd":"/tmp","command":["sh"],"cols":80,"rows":24,"colors":{"foreground":"#１２３４５６","background":"#000000","dark":true}}"##,
    );
    assert_eq!(req, Some(42));
    assert_eq!(error(message).0, error_code::REQUEST_FAILED);
    // The same connection still serves.
    assert!(matches!(
        control.call(ClientMessage::List),
        ServerMessage::Sessions { .. }
    ));
}

#[test]
fn subscribers_hear_bracketed_paste_turn_on_and_off() {
    let host = Host::new();
    let mut control = Control::subscribe(&host);
    let dir = host.dir();
    let (on, off) = (dir.join("on"), dir.join("off"));
    let session = host.create(shell(&format!(
        r#"stty -echo
while [ ! -e '{on}' ]; do sleep 0.02; done
printf '\033[?2004h'
while [ ! -e '{off}' ]; do sleep 0.02; done
printf '\033[?2004l'
exec sleep 60"#,
        on = on.display(),
        off = off.display(),
    )));
    let id = session.id.clone();
    // Known, and off, from the start.
    assert_eq!(session.bracketed_paste, Some(false));
    touch(&on);
    control.events_until("bracketed paste on", |event| {
        matches!(event, SessionEvent::Changed { session } if session.id == id
            && session.bracketed_paste == Some(true))
    });
    assert_eq!(host.session(&id).bracketed_paste, Some(true));
    // Attached clients are told too.
    let (_attached, attached, ..) = host.attach(&id, 80, 24);
    assert_eq!(attached.bracketed_paste, Some(true));
    touch(&off);
    control.events_until("bracketed paste off", |event| {
        matches!(event, SessionEvent::Changed { session } if session.id == id
            && session.bracketed_paste == Some(false))
    });
    host.kill(&id);
}

#[test]
fn clearing_history_leaves_the_screen_and_no_history_for_reads_and_reattaches() {
    let host = Host::new();
    let dir = host.dir();
    let more = dir.join("more");
    let session = host.create(shell(&format!(
        r#"stty -echo
i=1; while [ $i -le 60 ]; do printf 'line %d\n' $i; i=$((i+1)); done
printf 'prompt> '
while [ ! -e '{more}' ]; do sleep 0.02; done
printf '\nafter 1\nafter 2\n'
exec sleep 60"#,
        more = more.display(),
    )));
    let id = session.id.clone();
    let (history, ..) = screen_when(&host, &id, true, |text| text.contains("prompt>"));
    assert!(history.starts_with("line 1\n"), "{history}");
    assert_eq!(
        host.call(ClientMessage::ClearHistory { id: id.clone() }),
        ServerMessage::Ok
    );
    // The screen stays; the history above it is gone.
    let (text, row, col, _) = screen_when(&host, &id, true, |text| !text.contains("line 1\n"));
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 24, "{text}");
    assert_eq!(
        (lines[0], lines[23], row, col),
        ("line 38", "prompt>", 23, 8)
    );
    // A client that attaches now is sent no history either.
    let (_socket, _, offset, snapshot) = host.attach(&id, 80, 24);
    let screen = Screen::new(80, 24, offset, &snapshot);
    let shown = screen.terminal.inspect().unwrap();
    assert!(shown.history.is_empty(), "{:?}", shown.history);
    assert!(screen.text().contains("line 38"));
    // Later output scrolls into a history of its own.
    touch(&more);
    let (text, ..) = screen_when(&host, &id, true, |text| text.contains("after 2"));
    assert!(text.starts_with("line 38\n"), "{text}");
    // An unknown session is refused.
    let (code, _) = error(host.call(ClientMessage::ClearHistory {
        id: "no-such-session".into(),
    }));
    assert_eq!(code, error_code::UNKNOWN_SESSION);
    host.kill(&id);

    // On the alternate screen nothing is cleared, and the client hears so.
    let full = host.create(shell(
        "stty -echo; i=1; while [ $i -le 60 ]; do printf 'under %d\\n' $i; i=$((i+1)); done; printf '\\033[?1049hFULL'; exec sleep 60",
    ));
    screen_when(&host, &full.id, false, |text| text.contains("FULL"));
    let (code, message) = error(host.call(ClientMessage::ClearHistory {
        id: full.id.clone(),
    }));
    assert_eq!(code, error_code::REQUEST_FAILED);
    assert!(message.contains("alternate screen"), "{message}");
    host.kill(&full.id);
}

#[test]
fn the_terminal_reports_the_colours_and_appearance_the_create_named() {
    let host = Host::new();
    let dir = host.dir().to_path_buf();
    // The program asks its terminal (the holder answers these itself)
    // and keeps the answers, and its terminal's settings.
    let script = |name: &str| {
        let out = dir.join(name);
        format!(
            r#"stty -echo -icanon min 0 time 20
stty -a > '{out}.stty'
printf '\033]10;?\007\033]11;?\007\033]12;?\007\033[?996n'
dd bs=256 count=1 of='{out}.tmp' 2>/dev/null
mv '{out}.tmp' '{out}'
exec sleep 60"#,
            out = out.display(),
        )
    };
    let colored = |name: &str, colors: Option<TerminalColors>| {
        created(host.call(ClientMessage::Create {
            request_id: Uuid::new_v4().to_string(),
            name: name.into(),
            cwd: "/tmp".into(),
            command: shell(&script(name)),
            env: BTreeMap::new(),
            cols: 80,
            rows: 24,
            owner: None,
            tags: BTreeMap::new(),
            colors,
            cell_width: None,
            cell_height: None,
        }))
    };
    let light = colored(
        "light",
        Some(TerminalColors {
            foreground: Rgb([0x1f, 0x23, 0x28]),
            background: Rgb([0xff, 0xfe, 0xfd]),
            cursor: None,
            dark: false,
        }),
    );
    let plain = colored("plain", None);
    let answers = |name: &str| {
        let path = dir.join(name);
        wait_until(&format!("{name}'s answers"), || path.exists());
        fs::read_to_string(&path).unwrap()
    };
    // As named: light, the cursor in the foreground's colour.
    let reply = answers("light");
    for expected in [
        "\x1b]10;rgb:1f1f/2323/2828",
        "\x1b]11;rgb:ffff/fefe/fdfd",
        "\x1b]12;rgb:1f1f/2323/2828",
        "\x1b[?997;2n",
    ] {
        assert!(reply.contains(expected), "{expected:?} in {reply:?}");
    }
    // Without colours: light grey on black, dark.
    let reply = answers("plain");
    for expected in [
        "\x1b]10;rgb:e5e5/e5e5/e5e5",
        "\x1b]11;rgb:0000/0000/0000",
        "\x1b[?997;1n",
    ] {
        assert!(reply.contains(expected), "{expected:?} in {reply:?}");
    }
    // The terminal erases whole UTF-8 characters (IUTF8).
    for name in ["light", "plain"] {
        let stty = fs::read_to_string(dir.join(format!("{name}.stty"))).unwrap();
        assert!(
            stty.split_whitespace().any(|flag| flag == "iutf8"),
            "{name}: {stty}"
        );
    }
    host.kill(&light.id);
    host.kill(&plain.id);
}

#[test]
fn sessions_are_renamed_and_retagged_and_keep_it_across_daemons() {
    let mut host = Host::new();
    let tags = BTreeMap::from([("tab".to_string(), "t1".to_string())]);
    let session = created(host.call(ClientMessage::Create {
        request_id: Uuid::new_v4().to_string(),
        name: "before".into(),
        cwd: "/tmp".into(),
        command: shell("exec sleep 60"),
        env: BTreeMap::new(),
        cols: 80,
        rows: 24,
        owner: Some("tester".into()),
        tags: tags.clone(),
        colors: None,
        cell_width: None,
        cell_height: None,
    }));
    let id = session.id.clone();
    let mut control = Control::subscribe(&host);
    assert_eq!(
        control.call(ClientMessage::Update {
            id: id.clone(),
            name: Some("after".into()),
            tags: None,
        }),
        ServerMessage::Ok
    );
    // Applied by the time it is acknowledged, and heard by subscribers.
    let listed = host.session(&id);
    assert_eq!((listed.name.as_str(), &listed.tags), ("after", &tags));
    control.events_until("the rename", |event| {
        matches!(event, SessionEvent::Changed { session } if session.id == id && session.name == "after")
    });
    let retagged = BTreeMap::from([
        ("kind".to_string(), "agent".to_string()),
        ("agent".to_string(), "claude".to_string()),
    ]);
    assert_eq!(
        control.call(ClientMessage::Update {
            id: id.clone(),
            name: None,
            tags: Some(retagged.clone()),
        }),
        ServerMessage::Ok
    );
    let events = control.events_until("the new tags", |event| {
        matches!(event, SessionEvent::Changed { session } if session.id == id && session.tags.contains_key("kind"))
    });
    let changed = changes(&events, &id).last().unwrap();
    assert_eq!((changed.name.as_str(), &changed.tags), ("after", &retagged));
    assert_eq!(changed.owner.as_deref(), Some("tester"));
    // Nothing to change is fine too.
    assert_eq!(
        control.call(ClientMessage::Update {
            id: id.clone(),
            name: None,
            tags: None,
        }),
        ServerMessage::Ok
    );
    // What is refused.
    let (code, _) = error(control.call(ClientMessage::Update {
        id: Uuid::new_v4().to_string(),
        name: Some("x".into()),
        tags: None,
    }));
    assert_eq!(code, error_code::UNKNOWN_SESSION);
    let (code, message) = error(control.call(ClientMessage::Update {
        id: id.clone(),
        name: Some("n".repeat(257)),
        tags: None,
    }));
    assert_eq!(code, error_code::REQUEST_FAILED);
    assert!(message.contains("name"), "{message}");
    let too_many: BTreeMap<String, String> = (0..=MAX_TAGS)
        .map(|n| (n.to_string(), String::new()))
        .collect();
    let (code, message) = error(control.call(ClientMessage::Update {
        id: id.clone(),
        name: None,
        tags: Some(too_many),
    }));
    assert_eq!(code, error_code::REQUEST_FAILED);
    assert!(message.contains("tags"), "{message}");
    drop(control);
    // The holder keeps them for the next daemon.
    host.crash();
    host.respawn();
    let adopted = host
        .adopted()
        .into_iter()
        .find(|session| session.id == id)
        .unwrap();
    assert_eq!(
        (
            adopted.name.as_str(),
            &adopted.tags,
            adopted.owner.as_deref()
        ),
        ("after", &retagged, Some("tester"))
    );
    assert_eq!(adopted.created_at, session.created_at);
    host.kill(&id);
}

/// The environment a session's program gets: `env`'s, run as the program
/// itself (a shell would drop names it cannot use), read off its screen.
fn session_env(
    host: &Host,
    cwd: &str,
    env: BTreeMap<String, String>,
) -> (SessionInfo, HashMap<String, String>) {
    let session = created(create(host, cwd, vec!["/usr/bin/env".into()], env));
    host.wait(&session.id, |s| s.state == SessionState::Exited);
    let text = match host.call(ClientMessage::Screen {
        id: session.id.clone(),
        scrollback: true,
        max_lines: None,
    }) {
        ServerMessage::ScreenText { text, .. } => text,
        other => panic!("{other:?}"),
    };
    let env = text
        .lines()
        .filter_map(|line| {
            let (key, value) = line.split_once('=')?;
            Some((key.to_string(), value.to_string()))
        })
        .collect();
    (session, env)
}

#[test]
fn a_create_sets_any_variable_and_the_hosts_defaults_only_fill_in() {
    let host = Host::new();
    let chosen = BTreeMap::from([
        ("TERM".to_string(), "xterm-ghostty".to_string()),
        ("TERM_PROGRAM".into(), "ghostty".into()),
        ("SSH_AUTH_SOCK".into(), "/tmp/agent-of-the-client".into()),
        ("CHERRY_PROCESS_ID".into(), "p-1".into()),
        ("SPACED_VALUE".into(), "a b=c".into()),
        ("lower.case-name".into(), "odd but valid".into()),
        // What only the host knows, it sets.
        ("CHERRY_SESSION_ID".into(), "forged".into()),
    ]);
    let (session, env) = session_env(&host, "/tmp", chosen.clone());
    for (key, value) in &chosen {
        if key != "CHERRY_SESSION_ID" {
            assert_eq!(env.get(key), Some(value), "{key}");
        }
    }
    assert_eq!(env.get("CHERRY_SESSION_ID"), Some(&session.id));
    // Defaults fill in what the client leaves out.
    let (_, defaults) = session_env(&host, "/tmp", BTreeMap::new());
    assert_eq!(
        defaults.get("TERM").map(String::as_str),
        Some("xterm-256color")
    );
    assert_eq!(
        defaults.get("TERM_PROGRAM").map(String::as_str),
        Some("Cherry")
    );
    assert_eq!(
        defaults.get("SSH_AUTH_SOCK").map(Path::new),
        Some(host.dir().join(AGENT_LINK_NAME).as_path())
    );
    assert!(!defaults.contains_key("CHERRY_PROCESS_ID"));
    // Names no program can be given are refused, and start nothing.
    for (key, value) in [("", "x"), ("A=B", "x"), ("NUL\0", "x"), ("VALUE", "a\0b")] {
        let (code, message) = error(create(
            &host,
            "/tmp",
            shell("exit 0"),
            BTreeMap::from([(key.to_string(), value.to_string())]),
        ));
        assert_eq!(code, error_code::REQUEST_FAILED);
        assert!(
            message.contains("invalid environment variable"),
            "{message}"
        );
    }
    assert_eq!(host.sessions().len(), 2);
}

#[test]
fn pwd_is_the_directory_as_the_client_named_it() {
    let host = Host::new();
    let real = host.dir().join("real");
    fs::create_dir(&real).unwrap();
    let link = host.dir().join("link");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    let real = real.canonicalize().unwrap();
    let link = link.to_str().unwrap().to_string();
    let forged = BTreeMap::from([("PWD".to_string(), "/somewhere/else".to_string())]);
    // Through a symbolic link: the session starts in the directory itself,
    // and PWD keeps the path it was asked for, tidied.
    for named in [link.clone(), format!("{link}/"), format!("{link}/./")] {
        let (session, env) = session_env(&host, &named, forged.clone());
        assert_eq!(env.get("PWD"), Some(&link), "{named}");
        assert_eq!(Path::new(&session.cwd), real, "{named}");
    }
    // A path through `..` is not kept.
    let (_, env) = session_env(&host, &format!("{link}/../link"), BTreeMap::new());
    assert_eq!(env.get("PWD").map(Path::new), Some(real.as_path()));
    // HOME, as named.
    let (_, env) = session_env(&host, "~", BTreeMap::new());
    assert_eq!(
        env.get("PWD").map(Path::new),
        Some(host.sandbox.home.as_path())
    );
}

#[test]
fn subscribed_connections_outlive_the_idle_limit_but_not_their_heartbeat() {
    let host = Host::with_env(&[
        ("CHERRY_HOST_IDLE_TIMEOUT_MS", "300"),
        ("CHERRY_HOST_HEARTBEAT_TIMEOUT_MS", "2000"),
    ]);
    let closed = |socket: &mut UnixStream| {
        // Refused by macOS once the host has shut the socket down.
        let _ = socket.set_read_timeout(Some(Duration::from_secs(10)));
        loop {
            match read_frame::<_, ServerMessage>(socket) {
                Ok(None) | Err(_) => return,
                Ok(Some(ServerMessage::Event { .. })) => {}
                Ok(Some(other)) => panic!("{other:?}"),
            }
        }
    };
    let mut idle = host.connect();
    let mut control = Control::subscribe(&host);
    thread::sleep(Duration::from_millis(1000));
    let started = Instant::now();
    closed(&mut idle);
    assert!(started.elapsed() < Duration::from_secs(1));
    // Past the idle limit, a heartbeat keeps it.
    assert_eq!(control.call(ClientMessage::Ping), ServerMessage::Pong);
    thread::sleep(Duration::from_millis(1000));
    assert_eq!(control.call(ClientMessage::Ping), ServerMessage::Pong);
    // Without one, it goes.
    let silent = Instant::now();
    closed(&mut control.socket);
    let elapsed = silent.elapsed();
    assert!(elapsed >= Duration::from_millis(1500), "{elapsed:?}");
}
