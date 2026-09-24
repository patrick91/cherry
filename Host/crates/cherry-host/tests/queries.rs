//! Queries the host does not answer go to exactly one attached client, whose
//! terminal replies: of the clients whose terminal answers queries, the one
//! that most recently sent input, or else the most recently attached one.
//! They travel apart from the output, in order with it, and are never
//! repeated by a snapshot or a resync.
mod support;

use cherry_protocol::*;
use std::{
    fs,
    os::{fd::AsRawFd, unix::net::UnixStream},
    path::Path,
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};
use support::*;

const CURSOR_QUERY: &[u8] = b"\x1b[?6n";

/// What a client received, in order.
#[derive(Debug, PartialEq)]
enum Event {
    /// Output, with its offset.
    Output(u64, Vec<u8>),
    Query(Vec<u8>),
    Attached(AttachReason),
    Ok,
    Pong,
}

/// An attached client standing in for a terminal: it applies what arrives
/// and answers every query with its own reply, as its terminal would.
struct Term {
    writer: UnixStream,
    reader: Option<UnixStream>,
    messages: Option<mpsc::Receiver<ServerMessage>>,
    screen: Screen,
    events: Vec<Event>,
    reply: &'static [u8],
}

impl Term {
    /// Attach; reading starts with `read`.
    fn attach(host: &Host, id: &str, reply: &'static [u8]) -> Self {
        Self::attach_with(host, id, reply, true)
    }

    /// Attach as a client whose terminal answers queries, or not; either
    /// way it replies to any query it is sent.
    fn attach_with(host: &Host, id: &str, reply: &'static [u8], answers: bool) -> Self {
        let (socket, _, offset, snapshot) = host.attach_with(id, 80, 24, false, answers);
        socket.set_read_timeout(None).unwrap();
        Self {
            writer: socket.try_clone().unwrap(),
            reader: Some(socket),
            messages: None,
            screen: Screen::new(80, 24, offset, &snapshot),
            events: Vec::new(),
            reply,
        }
    }

    /// Read what the host sends from now on, on a thread of its own.
    fn read(&mut self) {
        let Some(mut reader) = self.reader.take() else {
            return;
        };
        let (tx, rx) = mpsc::channel();
        thread::spawn(move || {
            while let Ok(Some(message)) = read_frame::<_, ServerMessage>(&mut reader) {
                if tx.send(message).is_err() {
                    break;
                }
            }
        });
        self.messages = Some(rx);
    }

    /// Apply what has arrived, answering queries.
    fn pump(&mut self) {
        let Some(messages) = &self.messages else {
            return;
        };
        while let Ok(message) = messages.try_recv() {
            let event = match &message {
                ServerMessage::Output { offset, data } => Event::Output(*offset, data.clone()),
                ServerMessage::Query { data } => {
                    input(&mut self.writer, self.reply);
                    Event::Query(data.clone())
                }
                ServerMessage::Attached { reason, .. } => Event::Attached(*reason),
                ServerMessage::Ok => Event::Ok,
                ServerMessage::Pong => Event::Pong,
                other => panic!("unexpected {other:?}"),
            };
            if !matches!(event, Event::Ok | Event::Pong) {
                self.screen.apply(&message);
            }
            self.events.push(event);
        }
    }

    fn shows(&self, needle: &str) -> bool {
        self.screen.text().contains(needle)
    }

    fn queries(&self) -> Vec<&[u8]> {
        self.events
            .iter()
            .filter_map(|event| match event {
                Event::Query(data) => Some(&data[..]),
                _ => None,
            })
            .collect()
    }

    /// All output received, back to back.
    fn output(&self) -> Vec<u8> {
        self.events
            .iter()
            .filter_map(|event| match event {
                Event::Output(_, data) => Some(data.clone()),
                _ => None,
            })
            .flatten()
            .collect()
    }

    /// The stream offset right after `marker` in the output received.
    fn offset_after(&self, marker: &[u8]) -> Option<u64> {
        self.events.iter().find_map(|event| match event {
            Event::Output(offset, data) => data
                .windows(marker.len())
                .position(|window| window == marker)
                .map(|at| offset + (at + marker.len()) as u64),
            _ => None,
        })
    }

    /// The output received before its `n`th query.
    fn output_before_query(&self, n: usize) -> Vec<u8> {
        let mut seen = 0;
        let mut output = Vec::new();
        for event in &self.events {
            match event {
                Event::Output(_, data) => output.extend(data),
                Event::Query(_) if seen == n => return output,
                Event::Query(_) => seen += 1,
                _ => {}
            }
        }
        panic!("no query {n}");
    }

    /// Send `request` and apply what arrives until its `reply`: everything
    /// the host queued for this client before it.
    fn request(&mut self, request: &ClientMessage, reply: Event) {
        send(&mut self.writer, request);
        let deadline = Instant::now() + Duration::from_secs(10);
        while !self.events.contains(&reply) {
            assert!(Instant::now() < deadline, "no {reply:?}");
            self.pump();
            thread::sleep(Duration::from_millis(5));
        }
    }
}

/// Pump every client until each shows `needle`.
fn wait_all(terms: &mut [&mut Term], needle: &str) {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        for term in terms.iter_mut() {
            term.pump();
        }
        if terms.iter().all(|term| term.shows(needle)) {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "timed out waiting for {needle:?}: {:?}",
            terms
                .iter()
                .map(|term| term
                    .screen
                    .text()
                    .trim_end()
                    .lines()
                    .last()
                    .map(str::to_owned))
                .collect::<Vec<_>>()
        );
        thread::sleep(Duration::from_millis(5));
    }
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

fn touch(dir: &Path, name: &str) {
    fs::write(dir.join(name), b"").unwrap();
}

#[test]
fn the_client_that_typed_last_answers_each_query_alone() {
    const FIRST: &[u8] = b"\x1b[?11;1R";
    const SECOND: &[u8] = b"\x1b[?22;1R";
    let host = Host::new();
    // Each round asks for the cursor and reads one reply; a second reply
    // would be read as the next round's go byte, or land in `extra`.
    let session = host.create(shell_in(
        host.dir(),
        r#"stty raw -echo
printf 'READY\r\n'
while [ ! -e "$CHERRY_TEST_DIR/go0" ]; do sleep 0.02; done
for round in 0 1 2 3; do
  [ "$round" = 0 ] || dd bs=1 count=1 >/dev/null 2>&1
  printf 'ASK%s\033[?6n' "$round"
  dd bs=1 count=8 2>/dev/null > "$CHERRY_TEST_DIR/reply$round"
  printf '\r\nROUND%s\r\n' "$round"
done
while [ ! -e "$CHERRY_TEST_DIR/go4" ]; do sleep 0.02; done
printf 'ASK4\033[?6n\033]52;c;?\007'
stty min 0 time 5
dd bs=1 count=64 2>/dev/null > "$CHERRY_TEST_DIR/extra"
touch "$CHERRY_TEST_DIR/finished"
printf '\r\nROUND4\r\n'
exec sleep 60"#,
    ));
    let mut first = Term::attach(&host, &session.id, FIRST);
    let mut second = Term::attach(&host, &session.id, SECOND);
    first.read();
    second.read();
    wait_all(&mut [&mut first, &mut second], "READY");

    // Nobody has typed: the most recently attached client answers. Then the
    // one that typed last does, each time.
    let rounds: [(Option<bool>, bool); 4] = [
        (None, false),
        (Some(true), true),
        (Some(false), false),
        (Some(true), true),
    ];
    for (round, (typist, first_answers)) in rounds.into_iter().enumerate() {
        let asked = (first.queries().len(), second.queries().len());
        match typist {
            None => touch(host.dir(), "go0"),
            Some(true) => input(&mut first.writer, b"g"),
            Some(false) => input(&mut second.writer, b"g"),
        }
        let marker = format!("ROUND{round}");
        // Each client's messages arrive in order, so a query sent to the
        // client that must not answer would arrive before this output.
        wait_all(&mut [&mut first, &mut second], &marker);
        let expected = if first_answers {
            (asked.0 + 1, asked.1)
        } else {
            (asked.0, asked.1 + 1)
        };
        assert_eq!(
            (first.queries().len(), second.queries().len()),
            expected,
            "round {round}"
        );
        let responder = if first_answers { &first } else { &second };
        assert_eq!(responder.queries().last(), Some(&CURSOR_QUERY));
        // In its place in the output.
        assert!(responder
            .output_before_query(responder.queries().len() - 1)
            .ends_with(format!("ASK{round}").as_bytes()));
        let reply = fs::read(host.dir().join(format!("reply{round}"))).unwrap();
        assert_eq!(reply, responder.reply, "round {round}");
    }

    // With nobody attached, a query is dropped, and the session goes on.
    first.request(&ClientMessage::Detach, Event::Ok);
    second.request(&ClientMessage::Detach, Event::Ok);
    host.wait(&session.id, |s| !s.attached);
    touch(host.dir(), "go4");
    wait_until_for("the unanswered round", Duration::from_secs(30), || {
        host.dir().join("finished").exists()
    });
    assert_eq!(fs::read(host.dir().join("extra")).unwrap(), b"");
    let mut third = Term::attach(&host, &session.id, FIRST);
    third.read();
    wait_all(&mut [&mut third], "ROUND4");
    third.request(&ClientMessage::Ping, Event::Pong);
    assert!(third.queries().is_empty());
    assert_eq!(host.session(&session.id).state, SessionState::Running);

    // No query reached the output every client gets, and both clients got
    // all of it, contiguously (`Screen` checks every offset).
    for term in [&first, &second, &third] {
        let output = term.output();
        assert!(!contains(&output, CURSOR_QUERY));
        assert!(!contains(&output, b"\x1b]52;c;?"));
    }
    assert_eq!(first.screen.offset, second.screen.offset);
}

#[test]
fn a_client_without_a_terminal_is_never_asked() {
    const FIRST: &[u8] = b"\x1b[?11;1R";
    const SECOND: &[u8] = b"\x1b[?22;1R";
    const SCRIPT: &[u8] = b"\x1b[?33;1R";
    let host = Host::new();
    let session = host.create(shell_in(
        host.dir(),
        r#"stty raw -echo
printf 'READY\r\n'
while [ ! -e "$CHERRY_TEST_DIR/go0" ]; do sleep 0.02; done
for round in 0 1 2; do
  [ "$round" = 0 ] || dd bs=1 count=1 >/dev/null 2>&1
  printf 'ASK%s\033[?6n' "$round"
  dd bs=1 count=8 2>/dev/null > "$CHERRY_TEST_DIR/reply$round"
  printf '\r\nROUND%s\r\n' "$round"
done
while [ ! -e "$CHERRY_TEST_DIR/go3" ]; do sleep 0.02; done
printf 'ASK3\033[?6n'
stty min 0 time 5
dd bs=1 count=64 2>/dev/null > "$CHERRY_TEST_DIR/extra"
touch "$CHERRY_TEST_DIR/finished"
printf '\r\nROUND3\r\n'
exec sleep 60"#,
    ));
    let mut first = Term::attach(&host, &session.id, FIRST);
    let mut second = Term::attach(&host, &session.id, SECOND);
    // Attached last: a client whose input is a script, not the terminal its
    // output reaches.
    let mut script = Term::attach_with(&host, &session.id, SCRIPT, false);
    for term in [&mut first, &mut second, &mut script] {
        term.read();
    }
    wait_all(&mut [&mut first, &mut second, &mut script], "READY");
    // Nobody has typed: the most recently attached client that answers
    // does. Then the one of those that typed last, whoever typed since.
    // Who typed (the first client or the script), whose reply the program
    // reads, and how many queries each terminal client received so far.
    let rounds = [
        (None, SECOND, (0, 1)),
        (Some(true), FIRST, (1, 1)),
        (Some(false), FIRST, (2, 1)),
    ];
    for (round, (typist, reply, asked)) in rounds.into_iter().enumerate() {
        match typist {
            None => touch(host.dir(), "go0"),
            Some(true) => input(&mut first.writer, b"g"),
            Some(false) => input(&mut script.writer, b"g"),
        }
        // A query sent to another client would arrive before this output.
        wait_all(
            &mut [&mut first, &mut second, &mut script],
            &format!("ROUND{round}"),
        );
        assert_eq!(
            (first.queries().len(), second.queries().len()),
            asked,
            "round {round}"
        );
        assert!(script.queries().is_empty(), "round {round}");
        let received = fs::read(host.dir().join(format!("reply{round}"))).unwrap();
        assert_eq!(received, reply, "round {round}");
    }

    // Left with only the script attached, a query is dropped.
    first.request(&ClientMessage::Detach, Event::Ok);
    second.request(&ClientMessage::Detach, Event::Ok);
    touch(host.dir(), "go3");
    wait_until_for("the unanswered round", Duration::from_secs(30), || {
        host.dir().join("finished").exists()
    });
    assert_eq!(fs::read(host.dir().join("extra")).unwrap(), b"");
    wait_all(&mut [&mut script], "ROUND3");
    assert!(script.queries().is_empty());
    assert!(!contains(&script.output(), CURSOR_QUERY));
}

/// Bytes waiting in a socket's receive buffer.
fn queued(socket: &UnixStream) -> usize {
    let mut n: libc::c_int = 0;
    assert_eq!(
        unsafe { libc::ioctl(socket.as_raw_fd(), libc::FIONREAD, &mut n) },
        0
    );
    n as usize
}

#[test]
fn a_query_queued_for_a_responder_that_falls_behind_follows_its_resync_once() {
    const REPLY: &[u8] = b"\x1b[?33;1R";
    let host = Host::new();
    // Output until told to stop, a query, then output until told to stop
    // again, and the reply.
    let session = host.create(shell_in(
        host.dir(),
        r#"stty -echo; IFS= read -r go; stty raw
flood() {
  while [ ! -e "$CHERRY_TEST_DIR/$1" ]; do
    dd if=/dev/zero bs=65536 count=4 2>/dev/null | tr '\0' x
  done
}
flood before
printf '\r\nASK-QUERY\033[?6n'
flood after
dd bs=1 count=8 2>/dev/null > "$CHERRY_TEST_DIR/reply"
printf '\r\nREPLIED\r\n'
stty min 0 time 5
dd bs=1 count=64 2>/dev/null > "$CHERRY_TEST_DIR/extra"
printf 'DONE\r\n'
exec sleep 60"#,
    ));
    let mut watcher = Term::attach(&host, &session.id, b"\x1b[?44;1R");
    let mut responder = Term::attach(&host, &session.id, REPLY);
    watcher.read();
    // The responder typed last and then stops reading. Output frames are at
    // least 4/3 of what they carry, and the responder's socket holds what
    // reached it, so the host holds at least the difference for it,
    // whatever the socket buffer sizes, less the frame it is writing.
    input(&mut responder.writer, b"go\n");
    let start = watcher.screen.offset;
    let wait_for = |watcher: &mut Term, what: &str, done: &dyn Fn(&Term) -> bool| {
        let deadline = Instant::now() + Duration::from_secs(60);
        while !done(watcher) {
            assert!(Instant::now() < deadline, "timed out waiting for {what}");
            thread::sleep(Duration::from_millis(5));
            watcher.pump();
        }
    };
    const FRAME: u64 = 512 * 1024;
    let held = |sent: u64, socket: usize| (sent * 4 / 3).saturating_sub(socket as u64 + FRAME);
    let socket = responder.reader.as_ref().unwrap().try_clone().unwrap();
    // So the query is queued behind output the responder has not received.
    wait_for(&mut watcher, "output held for the responder", &|watcher| {
        held(watcher.screen.offset - start, queued(&socket)) > 512 * 1024
    });
    touch(host.dir(), "before");
    wait_for(&mut watcher, "the query", &|watcher| {
        watcher.offset_after(b"ASK-QUERY").is_some()
    });
    let asked = watcher.offset_after(b"ASK-QUERY").unwrap();
    // More output behind the query than a client may have queued: the
    // responder falls behind, and the output before the query is dropped.
    wait_for(&mut watcher, "the responder falling behind", &|watcher| {
        held(watcher.screen.offset - asked, 0) > (4 * 1024 + 512) * 1024
    });
    touch(host.dir(), "after");
    responder.read();
    wait_all(&mut [&mut watcher, &mut responder], "DONE");

    assert_eq!(responder.queries(), [CURSOR_QUERY]);
    assert!(watcher.queries().is_empty());
    assert_eq!(fs::read(host.dir().join("reply")).unwrap(), REPLY);
    assert_eq!(fs::read(host.dir().join("extra")).unwrap(), b"");
    // It came after a resync snapshot, which showed the screen it asks
    // about, and was not repeated.
    let query = responder
        .events
        .iter()
        .position(|event| matches!(event, Event::Query(_)))
        .unwrap();
    assert!(
        responder.events[..query].contains(&Event::Attached(AttachReason::Resync)),
        "the query arrived before the resync"
    );
    assert!(!contains(&responder.output(), CURSOR_QUERY));
    assert!(!contains(&watcher.output(), CURSOR_QUERY));
    assert_eq!(responder.screen.offset, watcher.screen.offset);
}
