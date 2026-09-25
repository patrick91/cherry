//! A holder on its own, driven over its link the way a daemon drives it.
mod support;

use serde_json::json;
use std::{
    fs,
    os::unix::{
        fs::PermissionsExt,
        io::AsRawFd,
        net::{UnixListener, UnixStream},
        process::CommandExt,
    },
    path::Path,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};
use support::*;
use uuid::Uuid;

/// A holder a test started. Dropped while it still runs (a failed
/// assertion, say), it is killed together with its session's program: a
/// holder whose session runs never exits by itself, and the programs here
/// wait for input or for a file for as long as they run.
struct Held {
    child: Child,
}

impl Held {
    fn id(&self) -> u32 {
        self.child.id()
    }

    fn wait(&mut self, timeout: Duration) -> std::process::ExitStatus {
        wait_child(&mut self.child, timeout)
    }
}

impl Drop for Held {
    fn drop(&mut self) {
        if matches!(self.child.try_wait(), Ok(Some(_))) {
            return;
        }
        // The session's leader is the holder's child, and leads a process
        // group of its own: found before the holder goes, which would leave
        // it to init.
        for leader in children(self.child.id() as i32) {
            unsafe {
                libc::kill(-leader, libc::SIGKILL);
                libc::kill(leader, libc::SIGKILL);
            }
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Start `cherry-host hold` with its link on descriptor 3 and hand it a
/// session running `script`, as the daemon does (without the double fork,
/// so the test can wait for it).
fn hold(sandbox: &Sandbox, state: &Path, id: &str, script: &str) -> (Held, UnixStream) {
    hold_command(sandbox, state, id, &["/bin/sh", "-c", script])
}

fn hold_command(sandbox: &Sandbox, state: &Path, id: &str, command: &[&str]) -> (Held, UnixStream) {
    let (mut ours, theirs) = UnixStream::pair().unwrap();
    let fd = theirs.as_raw_fd();
    let mut process = sandbox.command("hold");
    process.stdin(Stdio::null()).stdout(Stdio::null());
    unsafe {
        process.pre_exec(move || {
            if fd == 3 {
                libc::fcntl(3, libc::F_SETFD, 0);
            } else if libc::dup2(fd, 3) == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let child = Held {
        child: process.spawn().unwrap(),
    };
    drop(theirs);
    ours.set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let mut data = b"/tmp\0".to_vec();
    for (key, value) in [
        ("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
        ("HOME", sandbox.home.to_str().unwrap()),
        ("TERM", "xterm-256color"),
    ] {
        data.extend_from_slice(format!("{key}={value}\0").as_bytes());
    }
    link::send(
        &mut ours,
        link::LAUNCH,
        link::VERSION,
        json!({
            "id": id,
            "name": "held",
            "command": command,
            "cols": 80,
            "rows": 24,
            "created_at": 1,
            "state_dir": state,
            "kill_grace_ms": 100,
        }),
        &data,
    );
    (child, ours)
}

/// The holder's next connection to the socket.
fn accept(listener: &UnixListener) -> UnixStream {
    listener.set_nonblocking(true).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        match listener.accept() {
            Ok((stream, _)) => {
                stream.set_nonblocking(false).unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(10)))
                    .unwrap();
                return stream;
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                assert!(Instant::now() < deadline, "the holder never dialed");
                thread::sleep(Duration::from_millis(10));
            }
            Err(error) => panic!("{error}"),
        }
    }
}

/// The daemon goes away. Shut down, not only closed: a process that
/// another test is starting may hold a copy of the descriptor for a while,
/// and the holder would not see the link end before it lets go.
fn hang_up(daemon: UnixStream) {
    let _ = daemon.shutdown(std::net::Shutdown::Both);
}

/// Frames until one of `kind` whose meta satisfies `matches`.
fn until_matching(
    link: &mut UnixStream,
    kind: u8,
    matches: impl Fn(&link::Frame) -> bool,
) -> link::Frame {
    loop {
        let frame = link::until(link, kind, |frame| assert_eq!(frame.version, link::VERSION));
        if matches(&frame) {
            return frame;
        }
    }
}

#[test]
fn a_holder_keeps_its_session_between_daemons_and_exits_once_removed() {
    let sandbox = Sandbox::new();
    let state = sandbox.path().join("state");
    fs::create_dir(&state).unwrap();
    fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();
    let id = Uuid::new_v4().to_string();
    let (go, held) = (sandbox.path().join("go"), sandbox.path().join("held"));
    // Between its two lines, once told to go, the program reports things
    // and then asks for a status report, which the holder answers: by then
    // it has taken in the reports.
    let (mut holder, mut daemon) = hold(
        &sandbox,
        &state,
        &id,
        &format!(
            r#"stty -echo
printf '\033]2;First title\007'
IFS= read -r line
while [ ! -e '{go}' ]; do sleep 0.02; done
printf '\007\033]9;Hello there\007\033]0;%s\007\033]99;;Kitty says\033\\' "$line"
stty raw -echo
printf '\033[5n'
dd bs=1 count=4 >/dev/null 2>&1
stty -raw -echo
: > '{held}'
IFS= read -r line
printf 'SCREEN:%s\r\n' "$line"
exec sleep 60"#,
            go = go.display(),
            held = held.display(),
        ),
    );
    let hello = link::next(&mut daemon);
    assert_eq!(
        (hello.kind, hello.version),
        (link::HOLDER_HELLO, link::VERSION)
    );
    assert_eq!(hello.meta["id"], id.as_str());
    assert_eq!(hello.meta["holder_pid"], holder.id());
    assert_eq!(hello.meta["offset"], 0);
    assert_eq!(hello.meta["session"]["running"], true);
    assert_eq!(hello.meta["session"]["name"], "held");
    let pid = hello.meta["session"]["pid"].as_u64().unwrap() as i32;
    // Its manifest tells a starting daemon to expect it.
    let manifest = state.join("sessions").join(format!("{id}.json"));
    let written: serde_json::Value = serde_json::from_slice(&fs::read(&manifest).unwrap()).unwrap();
    assert_eq!(written["holder_pid"], holder.id());
    assert_eq!(written["link_version"], link::VERSION);
    assert_eq!(
        fs::metadata(&manifest).unwrap().permissions().mode() & 0o777,
        0o600
    );
    // What the program reports arrives as it changes.
    until_matching(&mut daemon, link::INFO, |frame| {
        frame.meta["title"] == "First title"
    });
    // Input is written and acknowledged.
    link::send(
        &mut daemon,
        link::INPUT,
        link::VERSION,
        json!({"lease": 7}),
        b"Second\n",
    );
    let ack = link::until(&mut daemon, link::INPUT_ACK, |_| {});
    assert_eq!(
        (ack.meta["lease"].clone(), ack.meta["bytes"].clone()),
        (json!(7), json!(7))
    );
    // The daemon goes away. The session carries on, and what the program
    // reports meanwhile waits for the next daemon.
    hang_up(daemon);
    fs::write(&go, b"").unwrap();
    wait_until("the status report", || held.exists());
    assert!(is_live(pid));
    let listener = UnixListener::bind(&sandbox.socket).unwrap();
    let mut daemon = accept(&listener);
    let hello = link::next(&mut daemon);
    assert_eq!(hello.kind, link::HOLDER_HELLO);
    assert_eq!(hello.meta["session"]["title"], "Second");
    assert!(hello.meta["offset"].as_u64().unwrap() > 0);
    let events: Vec<_> = hello.meta["events"].as_array().unwrap().clone();
    assert_eq!(
        events,
        [
            json!({"kind": "bell"}),
            json!({"kind": "notification", "title": "", "body": "Hello there"}),
            json!({"kind": "notification", "title": "Kitty says", "body": ""}),
        ]
    );
    // The screen as text.
    link::send(
        &mut daemon,
        link::INPUT,
        link::VERSION,
        json!({"lease": 1}),
        b"Third\n",
    );
    until_matching(&mut daemon, link::OUTPUT, |frame| {
        String::from_utf8_lossy(&frame.data).contains("SCREEN:Third")
    });
    link::send(
        &mut daemon,
        link::SCREEN,
        link::VERSION,
        json!({"req": 1, "scrollback": false}),
        b"",
    );
    let screen = link::until(&mut daemon, link::SCREEN_REPLY, |_| {});
    assert_eq!(screen.meta["req"], 1);
    assert_eq!(String::from_utf8_lossy(&screen.data).trim(), "SCREEN:Third");
    assert_eq!(
        (
            screen.meta["cursor_row"].clone(),
            screen.meta["cursor_col"].clone()
        ),
        (json!(1), json!(0))
    );
    assert_eq!(screen.meta["alternate_screen"], false);
    // A resize is reported back.
    link::send(
        &mut daemon,
        link::RESIZE,
        link::VERSION,
        json!({"cols": 100, "rows": 30}),
        b"",
    );
    until_matching(&mut daemon, link::INFO, |frame| {
        frame.meta["cols"] == 100 && frame.meta["rows"] == 30
    });
    // A kill ends the program; the exit follows its last output.
    link::send(&mut daemon, link::KILL, link::VERSION, json!({}), b"");
    let mut offset = 0;
    let exited = link::until(&mut daemon, link::EXITED, |frame| {
        if frame.kind == link::OUTPUT {
            offset = frame.meta["offset"].as_u64().unwrap() + frame.data.len() as u64;
        }
    });
    assert_eq!(
        (
            exited.meta["exit_code"].clone(),
            exited.meta["signal"].clone()
        ),
        (json!(128 + libc::SIGHUP), json!(libc::SIGHUP))
    );
    assert!(!is_live(pid));
    // Its screen stays for snapshots, at the offset of the output so far.
    link::send(
        &mut daemon,
        link::SNAPSHOT,
        link::VERSION,
        json!({"req": 2, "kind": "limited", "max": 1_000_000, "later": true}),
        b"",
    );
    let snapshot = link::until(&mut daemon, link::SNAPSHOT_REPLY, |_| {});
    assert_eq!(snapshot.meta["req"], 2);
    assert_eq!(snapshot.meta["cols"], 100);
    if offset > 0 {
        assert_eq!(snapshot.meta["offset"], offset);
    }
    assert!(String::from_utf8_lossy(&snapshot.data).contains("SCREEN:Third"));
    // Frames it does not know are ignored; once removed it exits, and its
    // manifest goes with it.
    link::send(&mut daemon, 222, 9, json!({"new": "thing"}), b"?");
    link::send(&mut daemon, link::REMOVE, link::VERSION, json!({}), b"");
    assert!(holder.wait(Duration::from_secs(5)).success());
    assert!(!manifest.exists());
}

#[test]
fn a_holder_that_cannot_start_its_session_says_why_and_exits() {
    let sandbox = Sandbox::new();
    let state = sandbox.path().join("state");
    fs::create_dir(&state).unwrap();
    fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();
    let id = Uuid::new_v4().to_string();
    let (mut holder, mut daemon) = hold_command(&sandbox, &state, &id, &["/does/not/exist"]);
    let failed = link::next(&mut daemon);
    assert_eq!(failed.kind, link::FAILED);
    let message = failed.meta["message"].as_str().unwrap();
    assert!(message.contains("/does/not/exist"), "{message}");
    assert!(!holder.wait(Duration::from_secs(5)).success());
    assert!(!state.join("sessions").join(format!("{id}.json")).exists());
}

#[test]
fn a_holder_refused_for_good_waits_for_another_host_and_exits_once_its_session_has() {
    let sandbox = Sandbox::new();
    let state = sandbox.path().join("state");
    fs::create_dir(&state).unwrap();
    fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();
    let id = Uuid::new_v4().to_string();
    // Not beside the socket: an entry there would have the holder dial
    // again.
    let go = state.join("go");
    let (mut holder, mut daemon) = hold(
        &sandbox,
        &state,
        &id,
        &format!(
            "while [ ! -e '{}' ]; do sleep 0.02; done; exit 7",
            go.display()
        ),
    );
    assert_eq!(link::next(&mut daemon).kind, link::HOLDER_HELLO);
    let manifest = state.join("sessions").join(format!("{id}.json"));
    assert!(manifest.exists());
    hang_up(daemon);
    let listener = UnixListener::bind(&sandbox.socket).unwrap();
    let mut daemon = accept(&listener);
    assert_eq!(link::next(&mut daemon).kind, link::HOLDER_HELLO);
    // A daemon that will never serve it (from a later version, say).
    link::send(
        &mut daemon,
        link::REFUSED,
        link::VERSION + 1,
        json!({"reason": "too old", "retry": false, "later": 1}),
        b"",
    );
    hang_up(daemon);
    // It dials no more, where backoff would have dialed several times...
    thread::sleep(Duration::from_secs(1));
    assert!(matches!(
        listener.accept(),
        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock
    ));
    // ...until the socket's directory changes, as when another host binds
    // the socket.
    fs::write(sandbox.path().join("changed"), b"").unwrap();
    let mut daemon = accept(&listener);
    let hello = link::next(&mut daemon);
    assert_eq!(hello.kind, link::HOLDER_HELLO);
    assert_eq!(hello.meta["session"]["running"], true);
    link::send(
        &mut daemon,
        link::REFUSED,
        link::VERSION,
        json!({"reason": "still too old", "retry": false}),
        b"",
    );
    // Refused, its session exits: nobody could show it, so the holder
    // exits too, and forgets its manifest.
    fs::write(&go, b"").unwrap();
    assert!(holder.wait(Duration::from_secs(5)).success());
    assert!(!manifest.exists());
}

#[test]
fn a_holder_tells_the_next_daemon_how_its_session_ended_meanwhile() {
    let sandbox = Sandbox::new();
    let state = sandbox.path().join("state");
    fs::create_dir(&state).unwrap();
    fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();
    let id = Uuid::new_v4().to_string();
    let go = sandbox.path().join("go");
    let (mut holder, mut daemon) = hold(
        &sandbox,
        &state,
        &id,
        &format!(
            "while [ ! -e '{}' ]; do sleep 0.02; done; printf '\\007'; exit 7",
            go.display()
        ),
    );
    let hello = link::next(&mut daemon);
    assert_eq!(hello.kind, link::HOLDER_HELLO);
    let pid = hello.meta["session"]["pid"].as_u64().unwrap() as u32;
    hang_up(daemon);
    fs::write(&go, b"").unwrap();
    wait_until("the exit", || is_gone(pid));
    let listener = UnixListener::bind(&sandbox.socket).unwrap();
    let mut daemon = accept(&listener);
    let hello = link::next(&mut daemon);
    assert_eq!(hello.kind, link::HOLDER_HELLO);
    assert_eq!(hello.meta["session"]["running"], false);
    assert_eq!(hello.meta["session"]["exit_code"], 7);
    assert_eq!(
        hello.meta["events"],
        json!([{"kind": "bell"}, {"kind": "exited", "exit_code": 7, "signal": null}])
    );
    link::send(&mut daemon, link::REMOVE, link::VERSION, json!({}), b"");
    assert!(holder.wait(Duration::from_secs(5)).success());
}

#[test]
fn a_holder_keeps_what_happened_meanwhile_until_a_daemon_takes_it() {
    let sandbox = Sandbox::new();
    let state = sandbox.path().join("state");
    fs::create_dir(&state).unwrap();
    fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();
    let id = Uuid::new_v4().to_string();
    let go = state.join("go");
    let (mut holder, mut daemon) = hold(
        &sandbox,
        &state,
        &id,
        &format!(
            "while [ ! -e '{}' ]; do sleep 0.02; done; printf '\\007'; exit 7",
            go.display()
        ),
    );
    let hello = link::next(&mut daemon);
    assert_eq!(hello.kind, link::HOLDER_HELLO);
    let pid = hello.meta["session"]["pid"].as_u64().unwrap() as u32;
    hang_up(daemon);
    fs::write(&go, b"").unwrap();
    wait_until("the exit", || is_gone(pid));
    let held = json!([{"kind": "bell"}, {"kind": "exited", "exit_code": 7, "signal": null}]);
    let listener = UnixListener::bind(&sandbox.socket).unwrap();
    // A daemon that turns it away (a stopping one, say) did not take them.
    let mut daemon = accept(&listener);
    let hello = link::next(&mut daemon);
    assert_eq!(hello.kind, link::HOLDER_HELLO);
    assert_eq!(hello.meta["events"], held);
    link::send(
        &mut daemon,
        link::REFUSED,
        link::VERSION,
        json!({"reason": "stopping", "retry": true}),
        b"",
    );
    hang_up(daemon);
    // One that serves it (it sends anything else) did.
    let mut daemon = accept(&listener);
    let hello = link::next(&mut daemon);
    assert_eq!(hello.kind, link::HOLDER_HELLO);
    assert_eq!(hello.meta["events"], held);
    link::send(
        &mut daemon,
        link::RESIZE,
        link::VERSION,
        json!({"cols": 100, "rows": 30}),
        b"",
    );
    hang_up(daemon);
    let mut daemon = accept(&listener);
    let hello = link::next(&mut daemon);
    assert_eq!(hello.kind, link::HOLDER_HELLO);
    assert_eq!(hello.meta["events"], json!([]));
    link::send(&mut daemon, link::REMOVE, link::VERSION, json!({}), b"");
    assert!(holder.wait(Duration::from_secs(5)).success());
}

#[test]
fn a_holder_reports_its_terminal_state_when_it_changes_and_limits_its_screen() {
    let sandbox = Sandbox::new();
    let state = sandbox.path().join("state");
    fs::create_dir(&state).unwrap();
    fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();
    let id = Uuid::new_v4().to_string();
    let (enter, leave) = (state.join("enter"), state.join("leave"));
    let (mut holder, mut daemon) = hold(
        &sandbox,
        &state,
        &id,
        &format!(
            r#"stty -echo
printf '\033[1mstyled\033[0m \033]2;Styled\007\n'
while [ ! -e '{enter}' ]; do sleep 0.02; done
printf 'one\ntwo\n\033[?1049h\033[>3u\033[?1hFULL SCREEN'
while [ ! -e '{leave}' ]; do sleep 0.02; done
printf '\033[<u\033[?1049l\033[?1lPRIMARY'
exec sleep 60"#,
            enter = enter.display(),
            leave = leave.display(),
        ),
    );
    let hello = link::next(&mut daemon);
    assert_eq!(hello.kind, link::HOLDER_HELLO);
    assert_eq!(hello.meta["session"]["alternate_screen"], false);
    assert_eq!(hello.meta["session"]["kitty_keyboard_flags"], 0);
    assert_eq!(hello.meta["session"]["application_cursor_keys"], false);
    const STATE: [&str; 3] = [
        "alternate_screen",
        "kitty_keyboard_flags",
        "application_cursor_keys",
    ];
    // What reports the terminal state, until `done` holds for it.
    let reports = |daemon: &mut UnixStream, done: &dyn Fn(&serde_json::Value) -> bool| {
        let mut infos = Vec::new();
        loop {
            let frame = link::until(daemon, link::INFO, |_| {});
            let meta = frame.meta.clone();
            let finished = done(&meta);
            if STATE.iter().any(|key| meta.get(key).is_some()) {
                infos.push(meta);
            }
            if finished {
                return infos;
            }
        }
    };
    // What `infos` reported of `key`, in order.
    let reported = |infos: &[serde_json::Value], key: &str| {
        infos
            .iter()
            .filter_map(|meta| meta.get(key).cloned())
            .collect::<Vec<_>>()
    };
    // Styled output and a title change none of it.
    let quiet = reports(&mut daemon, &|meta| meta["title"] == "Styled");
    assert_eq!(quiet, Vec::<serde_json::Value>::new());
    fs::write(&enter, b"").unwrap();
    // DECCKM is set last, so its report comes with or after the others.
    let entered = reports(&mut daemon, &|meta| meta["application_cursor_keys"] == true);
    // Once each, however the output was read.
    for (key, value) in STATE.iter().zip([json!(true), json!(3), json!(true)]) {
        assert_eq!(reported(&entered, key), [value], "{key}: {entered:?}");
    }
    // The screen, limited to its last line, with its history: the
    // alternate screen has none.
    link::send(
        &mut daemon,
        link::SCREEN,
        link::VERSION,
        json!({"req": 1, "scrollback": true, "max_lines": 1}),
        b"",
    );
    let screen = link::until(&mut daemon, link::SCREEN_REPLY, |_| {});
    assert_eq!(String::from_utf8_lossy(&screen.data), "FULL SCREEN");
    assert_eq!(
        (
            screen.meta["cursor_row"].clone(),
            screen.meta["cursor_col"].clone(),
            screen.meta["alternate_screen"].clone()
        ),
        (json!(0), json!(11), json!(true))
    );
    // Unlimited, the cursor's row is the screen's.
    link::send(
        &mut daemon,
        link::SCREEN,
        link::VERSION,
        json!({"req": 2, "scrollback": false}),
        b"",
    );
    let screen = link::until(&mut daemon, link::SCREEN_REPLY, |_| {});
    assert_eq!(String::from_utf8_lossy(&screen.data), "\n\n\nFULL SCREEN");
    assert_eq!(screen.meta["cursor_row"], 3);
    // The next daemon hears it with the hello.
    hang_up(daemon);
    let listener = UnixListener::bind(&sandbox.socket).unwrap();
    let mut daemon = accept(&listener);
    let hello = link::next(&mut daemon);
    assert_eq!(hello.kind, link::HOLDER_HELLO);
    assert_eq!(
        STATE.map(|key| hello.meta["session"][key].clone()),
        [json!(true), json!(3), json!(true)]
    );
    fs::write(&leave, b"").unwrap();
    let left = reports(&mut daemon, &|meta| {
        meta["application_cursor_keys"] == false
    });
    for (key, value) in STATE.iter().zip([json!(false), json!(0), json!(false)]) {
        assert_eq!(reported(&left, key), [value], "{key}: {left:?}");
    }
    link::send(&mut daemon, link::KILL, link::VERSION, json!({}), b"");
    link::until(&mut daemon, link::EXITED, |_| {});
    link::send(&mut daemon, link::REMOVE, link::VERSION, json!({}), b"");
    assert!(holder.wait(Duration::from_secs(5)).success());
}

/// Until `pid`'s state, as `ps` shows it, starts with `state` (`T`: stopped).
fn wait_for_state(pid: i32, state: char) {
    wait_until(&format!("{pid} in state {state}"), || {
        let output = Command::new("/bin/ps")
            .args(["-p", &pid.to_string(), "-o", "stat="])
            .output()
            .unwrap();
        String::from_utf8_lossy(&output.stdout)
            .trim()
            .starts_with(state)
    });
}

/// The next frame of `kind`; the session must not exit meanwhile.
fn until_running(link: &mut UnixStream, kind: u8) -> link::Frame {
    link::until(link, kind, |frame| {
        assert_ne!(frame.kind, link::EXITED, "taken for exited: {frame:?}");
    })
}

#[test]
fn a_stopped_program_is_neither_taken_for_exited_nor_beyond_a_kill() {
    let sandbox = Sandbox::new();
    let state = sandbox.path().join("state");
    fs::create_dir(&state).unwrap();
    fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();
    let id = Uuid::new_v4().to_string();
    // It ignores the hangup and the termination request (and so does the
    // program it becomes), so a kill takes the whole escalation.
    let (mut holder, mut daemon) = hold(
        &sandbox,
        &state,
        &id,
        r#"trap '' HUP TERM
stty -echo
IFS= read -r line
printf 'GOT:%s\r\n' "$line"
exec sleep 600"#,
    );
    let hello = link::next(&mut daemon);
    assert_eq!(hello.kind, link::HOLDER_HELLO);
    let pid = hello.meta["session"]["pid"].as_u64().unwrap() as i32;
    // Stopped (a debugger, `kill -STOP`, a job control stop)...
    unsafe { libc::kill(pid, libc::SIGSTOP) };
    wait_for_state(pid, 'T');
    // ...it keeps running, and the holder keeps serving the session: a
    // resize, the screen, input, each of which wakes it.
    link::send(
        &mut daemon,
        link::RESIZE,
        link::VERSION,
        json!({"cols": 100, "rows": 30}),
        b"",
    );
    until_running(&mut daemon, link::INFO);
    link::send(
        &mut daemon,
        link::SCREEN,
        link::VERSION,
        json!({"req": 1, "scrollback": false}),
        b"",
    );
    assert_eq!(
        until_running(&mut daemon, link::SCREEN_REPLY).meta["req"],
        1
    );
    link::send(
        &mut daemon,
        link::INPUT,
        link::VERSION,
        json!({"lease": 1}),
        b"typed while stopped\n",
    );
    assert_eq!(
        until_running(&mut daemon, link::INPUT_ACK).meta["bytes"],
        20
    );
    // Continued, it reads what was typed meanwhile.
    unsafe { libc::kill(pid, libc::SIGCONT) };
    loop {
        let output = until_running(&mut daemon, link::OUTPUT);
        if String::from_utf8_lossy(&output.data).contains("GOT:typed while stopped") {
            break;
        }
    }
    link::send(
        &mut daemon,
        link::SCREEN,
        link::VERSION,
        json!({"req": 2, "scrollback": false}),
        b"",
    );
    let screen = until_running(&mut daemon, link::SCREEN_REPLY);
    assert!(String::from_utf8_lossy(&screen.data).contains("GOT:typed while stopped"));
    // Stopped again, a kill still ends it: SIGHUP and SIGTERM, which it
    // ignores, then SIGKILL.
    wait_until("the program it becomes", || {
        command_of(pid).is_some_and(|name| name.contains("sleep"))
    });
    unsafe { libc::kill(pid, libc::SIGSTOP) };
    wait_for_state(pid, 'T');
    link::send(&mut daemon, link::KILL, link::VERSION, json!({}), b"");
    let exited = link::until(&mut daemon, link::EXITED, |_| {});
    assert_eq!(
        (
            exited.meta["exit_code"].clone(),
            exited.meta["signal"].clone()
        ),
        (json!(128 + libc::SIGKILL), json!(libc::SIGKILL))
    );
    assert!(is_gone(pid as u32) || !is_live(pid));
    link::send(&mut daemon, link::REMOVE, link::VERSION, json!({}), b"");
    assert!(holder.wait(Duration::from_secs(5)).success());
}

/// The command `ps` shows for `pid`, if it runs.
fn command_of(pid: i32) -> Option<String> {
    let output = Command::new("/bin/ps")
        .args(["-p", &pid.to_string(), "-o", "command="])
        .output()
        .unwrap();
    let command = String::from_utf8_lossy(&output.stdout).trim().to_string();
    (!command.is_empty()).then_some(command)
}

/// A holder of a fresh session running `script`, its hello taken.
fn held_session(sandbox: &Sandbox, script: &str) -> (Held, UnixStream) {
    let state = sandbox.path().join("state");
    fs::create_dir_all(&state).unwrap();
    fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();
    let (holder, mut daemon) = hold(sandbox, &state, &Uuid::new_v4().to_string(), script);
    assert_eq!(link::next(&mut daemon).kind, link::HOLDER_HELLO);
    (holder, daemon)
}

#[test]
fn output_goes_out_between_the_requests_that_take_work() {
    // Output first, and out before the holder serves a request that takes
    // work (the screen as text, a snapshot): one of those per pass, so a
    // burst of them never holds the program's output back.
    let sandbox = Sandbox::new();
    let (_holder, mut daemon) = held_session(&sandbox, "exec yes FLOOD");
    link::until(&mut daemon, link::OUTPUT, |_| {});
    let mut burst = Vec::new();
    for req in 1..=6 {
        burst.extend(link::encode(
            link::SCREEN,
            link::VERSION,
            &json!({"req": req, "scrollback": true}),
            b"",
        ));
    }
    std::io::Write::write_all(&mut daemon, &burst).unwrap();
    let mut replies = 0;
    let mut between = 0;
    while replies < 6 {
        let frame = link::next(&mut daemon);
        match frame.kind {
            link::SCREEN_REPLY => {
                replies += 1;
                assert_eq!(frame.meta["req"], replies);
            }
            link::OUTPUT if replies > 0 => between += 1,
            _ => {}
        }
    }
    assert!(between > 0, "the replies went out back to back");
}

#[test]
fn a_resized_snapshot_holds_the_screens_unless_the_program_repaints_them() {
    let sandbox = Sandbox::new();
    let request = |daemon: &mut UnixStream, req: u64| {
        link::send(
            daemon,
            link::SNAPSHOT,
            link::VERSION,
            json!({"req": req, "kind": "resized"}),
            b"",
        );
        until_matching(daemon, link::SNAPSHOT_REPLY, |frame| {
            frame.meta["req"] == req
        })
    };
    // On the primary screen: the screens, as a refresh gives them.
    let (_shell, mut daemon) = held_session(&sandbox, "printf 'PROMPT$ '; exec sleep 60");
    until_matching(&mut daemon, link::OUTPUT, |frame| {
        String::from_utf8_lossy(&frame.data).contains("PROMPT")
    });
    let reply = request(&mut daemon, 1);
    assert_eq!(reply.meta["kind"], "refresh");
    assert!(String::from_utf8_lossy(&reply.data).contains("PROMPT$"));
    // On the alternate screen: nothing but where the size took effect, and
    // only right after a resize.
    let (_editor, mut daemon) =
        held_session(&sandbox, "printf '\\033[?1049hEDITOR'; exec sleep 60");
    until_matching(&mut daemon, link::INFO, |frame| {
        frame.meta["alternate_screen"] == true
    });
    let resize = |daemon: &mut UnixStream, cols: u16, rows: u16| {
        link::send(
            daemon,
            link::RESIZE,
            link::VERSION,
            json!({"cols": cols, "rows": rows}),
            b"",
        );
    };
    assert_eq!(request(&mut daemon, 2).meta["kind"], "refresh");
    resize(&mut daemon, 90, 30);
    let reply = request(&mut daemon, 3);
    assert_eq!(reply.meta["kind"], "size");
    assert_eq!(
        (reply.meta["cols"].clone(), reply.meta["rows"].clone()),
        (json!(90), json!(30))
    );
    assert!(reply.data.is_empty());
    assert!(reply.meta["offset"].as_u64().unwrap() > 0);
    // A resize that changes nothing: the program repaints nothing.
    resize(&mut daemon, 90, 30);
    assert_eq!(request(&mut daemon, 4).meta["kind"], "refresh");

    // A program that repaints on its own once resized: after its repaint,
    // the screens, which a copy that took the repaint at its old size
    // would lack.
    let (_repainting, mut daemon) = held_session(
        &sandbox,
        "trap 'printf \"\\033[HSIZE:%s\" \"$(stty size)\"' WINCH; printf '\\033[?1049hEDITOR'; while :; do sleep 1 & wait $!; done",
    );
    until_matching(&mut daemon, link::INFO, |frame| {
        frame.meta["alternate_screen"] == true
    });
    resize(&mut daemon, 100, 40);
    until_matching(&mut daemon, link::OUTPUT, |frame| {
        String::from_utf8_lossy(&frame.data).contains("SIZE:40 100")
    });
    let reply = request(&mut daemon, 5);
    assert_eq!(reply.meta["kind"], "refresh");
    assert!(String::from_utf8_lossy(&reply.data).contains("SIZE:40 100"));
    // Asked for in the same pass as the resize, before the repaint is read:
    // where the size took effect. That takes no work, so the pass goes on
    // (as it would not after a snapshot) and answers the next one alike.
    let mut burst = link::encode(
        link::RESIZE,
        link::VERSION,
        &json!({"cols": 110, "rows": 45}),
        b"",
    );
    for req in [6, 7] {
        burst.extend(link::encode(
            link::SNAPSHOT,
            link::VERSION,
            &json!({"req": req, "kind": "resized"}),
            b"",
        ));
    }
    std::io::Write::write_all(&mut daemon, &burst).unwrap();
    let first = until_matching(&mut daemon, link::SNAPSHOT_REPLY, |frame| {
        frame.meta["req"] == 6
    });
    let second = link::next(&mut daemon);
    assert_eq!(second.kind, link::SNAPSHOT_REPLY, "{second:?}");
    for reply in [&first, &second] {
        assert_eq!(reply.meta["kind"], "size", "{reply:?}");
        assert_eq!(reply.meta["cols"], 110);
    }
    assert_eq!(first.meta["offset"], second.meta["offset"]);
}
