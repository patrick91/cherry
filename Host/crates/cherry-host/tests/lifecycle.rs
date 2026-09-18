//! Regressions for owning a process session independently of its attachments.
use cherry_protocol::*;
use std::{
    collections::BTreeMap,
    fs,
    io::Write,
    net::Shutdown,
    os::unix::{fs::PermissionsExt, net::UnixStream},
    path::PathBuf,
    process::{Child, Command, Stdio},
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    },
    thread,
    time::{Duration, Instant},
};
use tempfile::TempDir;
use uuid::Uuid;

struct Host {
    dir: TempDir,
    socket: PathBuf,
    child: Child,
}

impl Host {
    fn new() -> Self {
        let dir = tempfile::Builder::new()
            .prefix("ch-life-")
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
        let mut host = Self { dir, socket, child };
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
        let env = BTreeMap::from([(
            "CHERRY_TEST_DIR".into(),
            self.dir.path().to_string_lossy().into(),
        )]);
        match self.call(ClientMessage::Create {
            request_id: Uuid::new_v4().to_string(),
            name: "lifecycle".into(),
            cwd: "/tmp".into(),
            command,
            env,
            cols: 80,
            rows: 24,
        }) {
            ServerMessage::Created { session } => session,
            other => panic!("create failed: {other:?}"),
        }
    }

    fn sessions(&self) -> Vec<SessionInfo> {
        match self.call(ClientMessage::List) {
            ServerMessage::Sessions { sessions, .. } => sessions,
            other => panic!("list failed: {other:?}"),
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

    fn attach(&self, id: &str) -> UnixStream {
        let mut socket = self.connect();
        write_frame(
            &mut socket,
            &ClientMessage::Attach {
                id: id.into(),
                cols: 80,
                rows: 24,
                takeover: false,
            },
        )
        .unwrap();
        assert!(matches!(
            receive(&mut socket),
            ServerMessage::Attached { .. }
        ));
        socket
    }

    fn kill(&self, id: &str) {
        assert!(matches!(
            self.call(ClientMessage::Kill { id: id.into() }),
            ServerMessage::Ok
        ));
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        // Also clean up if an assertion fails: dropping the daemon alone does not
        // promise to terminate processes whose PTYs it owns.
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

fn wait_until(description: &str, predicate: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !predicate() {
        assert!(
            Instant::now() < deadline,
            "timed out waiting for {description}"
        );
        thread::sleep(Duration::from_millis(15));
    }
}

fn shell(script: &str) -> Vec<String> {
    vec!["/bin/sh".into(), "-c".into(), script.into()]
}

// The sleep ignores SIGHUP and lives in a different process group from the
// foreground shell. Killing only the foreground pgrp cannot pass these tests.
fn background_session(host: &Host) -> (SessionInfo, BackgroundJob) {
    let session = host.create(vec![
        "/bin/bash".into(),
        "-m".into(),
        "-c".into(),
        r#"set -m
/bin/bash -c 'trap "" HUP; printf "%s" "$$" > "$CHERRY_TEST_DIR/background.pid"; exec /bin/sleep 60' &
while [ ! -s "$CHERRY_TEST_DIR/background.pid" ]; do sleep 0.01; done
printf ready > "$CHERRY_TEST_DIR/ready"
while [ ! -e "$CHERRY_TEST_DIR/exit" ]; do sleep 0.01; done
exit 23"#.into(),
    ]);
    wait_until("background job", || host.dir.path().join("ready").exists());
    let pid = fs::read_to_string(host.dir.path().join("background.pid"))
        .unwrap()
        .parse::<i32>()
        .unwrap();
    let job = BackgroundJob {
        pid,
        leader: session.pid.unwrap() as i32,
        group: unsafe { libc::getpgid(pid) },
    };
    assert_eq!(unsafe { libc::getsid(pid) }, job.leader);
    assert!(job.group > 0);
    assert_ne!(job.group, job.leader);
    (session, job)
}

struct BackgroundJob {
    pid: i32,
    leader: i32,
    group: i32,
}

impl BackgroundJob {
    fn is_live(&self) -> bool {
        // An orphaned zombie awaits the system reaper but cannot execute. ps is
        // portable between macOS and Linux, unlike inspecting /proc directly.
        let output = Command::new("/bin/ps")
            .args(["-p", &self.pid.to_string(), "-o", "stat="])
            .output()
            .unwrap();
        let status = String::from_utf8_lossy(&output.stdout);
        !status.trim().is_empty() && !status.trim().starts_with('Z')
    }
}

impl Drop for BackgroundJob {
    fn drop(&mut self) {
        // Restrict cleanup to the exact owned session and background group.
        if unsafe { libc::getsid(self.pid) } == self.leader
            && unsafe { libc::getpgid(self.pid) } == self.group
        {
            unsafe {
                libc::kill(-self.group, libc::SIGKILL);
            }
        }
    }
}

#[test]
fn explicit_kill_terminates_background_job_control_groups() {
    let host = Host::new();
    let (session, job) = background_session(&host);
    assert!(job.is_live());
    host.kill(&session.id);
    host.wait(&session.id, |s| s.state == SessionState::Exited);
    wait_until("background job termination", || !job.is_live());
}

#[test]
fn natural_shell_exit_cleans_up_background_jobs_and_preserves_exit_code() {
    let host = Host::new();
    let (session, job) = background_session(&host);
    assert!(job.is_live());
    fs::write(host.dir.path().join("exit"), []).unwrap();
    let exited = host.wait(&session.id, |s| s.state == SessionState::Exited);
    assert_eq!(exited.exit_code, Some(23));
    wait_until("background job termination after shell exit", || {
        !job.is_live()
    });
}

#[test]
fn explicit_detach_acknowledges_before_eof_and_allows_reattach() {
    let host = Host::new();
    let session = host.create(shell("exec /bin/sleep 60"));
    // Exercise the connection writer and session worker racing each other. A
    // cancellation must release the lease without discarding the queued reply.
    for attempt in 0..32 {
        let mut socket = host.attach(&session.id);
        write_frame(&mut socket, &ClientMessage::Detach).unwrap();
        let reply = read_frame::<_, ServerMessage>(&mut socket).unwrap();
        assert!(
            matches!(reply, Some(ServerMessage::Ok)),
            "detach {attempt} lost its acknowledgement: {reply:?}"
        );
        assert!(
            read_frame::<_, ServerMessage>(&mut socket)
                .unwrap()
                .is_none(),
            "detach must close after acknowledging"
        );
        let detached = host.wait(&session.id, |s| !s.attached);
        assert_eq!(detached.pid, session.pid);
        assert_eq!(detached.state, SessionState::Running);
    }
    let final_attachment = host.attach(&session.id);
    host.kill(&session.id);
    host.wait(&session.id, |s| s.state == SessionState::Exited);
    drop(final_attachment);
}

fn input_frame() -> Vec<u8> {
    let mut bytes = Vec::new();
    write_frame(
        &mut bytes,
        &ClientMessage::Input {
            data: vec![b'x'; MAX_INPUT_BYTES],
        },
    )
    .unwrap();
    bytes
}

#[test]
fn blocked_pty_input_and_disconnect_do_not_prevent_reattach_or_kill() {
    let host = Host::new();
    let session = host.create(shell(
        r#"stty raw -echo; printf ready > "$CHERRY_TEST_DIR/ready"; exec /bin/sleep 60"#,
    ));
    wait_until("non-reading PTY child", || {
        host.dir.path().join("ready").exists()
    });
    let unaffected = host.create(shell("exec /bin/sleep 60"));
    let mut socket = host.attach(&session.id);
    socket
        .set_write_timeout(Some(Duration::from_millis(500)))
        .unwrap();
    let frame = input_frame();
    // More than the bounded pending-input budget, against a child that never
    // reads stdin. Either backpressure or the host's deliberate disconnect is OK.
    let mut sent = 0;
    for _ in 0..128 {
        if socket.write_all(&frame).is_err() {
            break;
        }
        sent += 1;
    }
    assert!(sent > 0, "no input reached the attachment");
    let _ = socket.shutdown(Shutdown::Both);
    drop(socket);
    let detached = host.wait(&session.id, |s| !s.attached);
    assert_eq!(detached.pid, session.pid);
    assert_eq!(detached.state, SessionState::Running);

    let mut reattached = host.attach(&session.id);
    reattached
        .set_write_timeout(Some(Duration::from_millis(500)))
        .unwrap();
    let abort = reattached.try_clone().unwrap();
    let sent = Arc::new(AtomicUsize::new(0));
    let writer_sent = sent.clone();
    let writer = thread::spawn(move || {
        for _ in 0..128 {
            if reattached.write_all(&frame).is_err() {
                break;
            }
            writer_sent.fetch_add(1, Ordering::SeqCst);
        }
    });
    wait_until("reattached input writer", || {
        sent.load(Ordering::SeqCst) > 0 || writer.is_finished()
    });
    let start = Instant::now();
    host.kill(&session.id);
    let exited = host.wait(&session.id, |s| s.state == SessionState::Exited);
    assert_eq!(exited.pid, session.pid);
    assert!(
        start.elapsed() < Duration::from_secs(3),
        "termination stalled behind input"
    );
    let _ = abort.shutdown(Shutdown::Both);
    writer.join().unwrap();
    let other = host
        .sessions()
        .into_iter()
        .find(|s| s.id == unaffected.id)
        .unwrap();
    assert_eq!(other.state, SessionState::Running);
}

fn cpu_seconds(pid: u32) -> f64 {
    let output = Command::new("/bin/ps")
        .args(["-p", &pid.to_string(), "-o", "time="])
        .output()
        .unwrap();
    assert!(output.status.success());
    String::from_utf8_lossy(&output.stdout)
        .trim()
        .split(':')
        .fold(0.0, |seconds, part| {
            seconds * 60.0 + part.parse::<f64>().unwrap()
        })
}

#[test]
fn closed_terminal_fds_do_not_spin_while_the_child_is_still_running() {
    let host = Host::new();
    let session = host.create(shell(
        r#"exec 0</dev/null 1>/dev/null 2>/dev/null
printf ready > "$CHERRY_TEST_DIR/ready"
sleep 2
exit 19"#,
    ));
    wait_until("closed terminal descriptors", || {
        host.dir.path().join("ready").exists()
    });
    let initial = host
        .sessions()
        .into_iter()
        .find(|s| s.id == session.id)
        .unwrap();
    assert_eq!(initial.state, SessionState::Running);
    let before = cpu_seconds(host.child.id());
    thread::sleep(Duration::from_millis(1500));
    let consumed = cpu_seconds(host.child.id()) - before;
    assert!(
        consumed < 0.75,
        "host consumed {consumed:.2}s CPU after terminal EOF"
    );
    let exited = host.wait(&session.id, |s| s.state == SessionState::Exited);
    assert_eq!(exited.exit_code, Some(19));
}
