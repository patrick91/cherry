//! Run after `cargo build -p cherry-host` with:
//! `cargo test -p cherry-cli --test real_host -- --ignored`.
use std::{
    fs::File,
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{fs::PermissionsExt, net::UnixStream},
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

fn host_binary() -> PathBuf {
    std::env::var_os("CHERRY_TEST_HOST")
        .map(PathBuf::from)
        .unwrap_or_else(|| Path::new(env!("CARGO_BIN_EXE_cherry")).with_file_name("cherry-host"))
}

/// A private directory, as the host requires for its socket.
fn private_directory() -> tempfile::TempDir {
    let directory = tempfile::tempdir().unwrap();
    std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    directory
}

struct Host {
    _directory: tempfile::TempDir,
    socket: PathBuf,
    child: Child,
    host_id: Option<String>,
}

impl Host {
    fn start() -> Self {
        let directory = private_directory();
        let socket = directory.path().join("host.sock");
        // The daemon keeps its state under HOME; never the real one.
        let home = directory.path().join("home");
        std::fs::create_dir(&home).unwrap();
        let child = Command::new(host_binary())
            .arg("serve")
            .arg("--socket")
            .arg(&socket)
            .env("HOME", &home)
            .env_remove("XDG_STATE_HOME")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let mut host = Self {
            _directory: directory,
            socket,
            child,
            host_id: None,
        };
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if UnixStream::connect(&host.socket).is_ok() {
                break;
            }
            assert!(
                host.child.try_wait().unwrap().is_none(),
                "host exited during startup"
            );
            assert!(Instant::now() < deadline, "host did not become ready");
            thread::sleep(Duration::from_millis(10));
        }
        host.host_id = Some(
            host.json(&["list", "--json"])["host_id"]
                .as_str()
                .unwrap()
                .to_owned(),
        );
        host
    }

    fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cherry"));
        command.arg("--socket").arg(&self.socket);
        // This test's daemon is the only one: never auto-start another.
        command.env("CHERRY_HOST_PATH", "/nonexistent/cherry-host");
        command.env_remove("CHERRY_SESSION_ID");
        // The test terminals do not answer the query written when leaving a
        // session that asked them something.
        command.env("CHERRY_CLI_REPORT_WAIT_MS", "200");
        if let Some(id) = &self.host_id {
            command.arg("--expected-host-id").arg(id);
        }
        command
    }

    fn json(&self, args: &[&str]) -> serde_json::Value {
        let output = self.command().args(args).output().unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout).unwrap()
    }

    fn wait_for_detached_running(&self, id: &str, pid: &serde_json::Value) {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let listing = self.json(&["list", "--json"]);
            let session = listing["sessions"]
                .as_array()
                .unwrap()
                .iter()
                .find(|session| session["id"] == id)
                .unwrap();
            assert_eq!(session["state"], "running");
            assert_eq!(
                &session["pid"], pid,
                "reconnect spawned a different process"
            );
            if session["attached"] == false {
                return;
            }
            assert!(Instant::now() < deadline, "host did not release attachment");
            thread::sleep(Duration::from_millis(20));
        }
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        // Best effort cleanup also runs if an assertion fails mid-attachment.
        // A daemon that already died has nothing left to clean up.
        if !matches!(self.child.try_wait(), Ok(None)) {
            return;
        }
        if let Ok(output) = self.command().args(["list", "--json"]).output() {
            if let Ok(listing) = serde_json::from_slice::<serde_json::Value>(&output.stdout) {
                if let Some(sessions) = listing["sessions"].as_array() {
                    for session in sessions {
                        if let Some(id) = session["id"].as_str() {
                            let _ = self
                                .command()
                                .args(["kill", id])
                                .stdout(Stdio::null())
                                .stderr(Stdio::null())
                                .status();
                        }
                    }
                }
            }
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

struct Attached {
    master: File,
    _slave: File,
    child: Child,
    received: Vec<u8>,
}

impl Attached {
    fn new(host: &Host, id: &str, cols: u16, rows: u16) -> Self {
        Self::with_takeover(host, id, cols, rows, false)
    }

    fn with_takeover(host: &Host, id: &str, cols: u16, rows: u16, takeover: bool) -> Self {
        let (mut master, mut slave) = (-1, -1);
        let mut size = libc::winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        assert_eq!(
            unsafe {
                libc::openpty(
                    &mut master,
                    &mut slave,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::addr_of_mut!(size),
                )
            },
            0
        );
        let master = unsafe { File::from_raw_fd(master) };
        let slave = unsafe { File::from_raw_fd(slave) };
        let flags = unsafe { libc::fcntl(master.as_raw_fd(), libc::F_GETFL) };
        assert_eq!(
            unsafe { libc::fcntl(master.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) },
            0
        );
        let mut command = host.command();
        command.args(["attach", id]);
        if takeover {
            command.arg("--takeover");
        }
        let child = command
            .stdin(slave.try_clone().unwrap())
            .stdout(slave.try_clone().unwrap())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        Self {
            master,
            _slave: slave,
            child,
            received: Vec::new(),
        }
    }

    fn expect(&mut self, needle: &[u8]) {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if self
                .received
                .windows(needle.len())
                .any(|bytes| bytes == needle)
            {
                return;
            }
            let mut bytes = [0u8; 16384];
            match self.master.read(&mut bytes) {
                Ok(n) => self.received.extend_from_slice(&bytes[..n]),
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(error) => panic!("PTY read failed: {error}"),
            }
            assert!(
                Instant::now() < deadline,
                "missing {:?} in {:?}",
                String::from_utf8_lossy(needle),
                String::from_utf8_lossy(&self.received)
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    /// How many cursor report requests the terminal received.
    fn cursor_queries(&self) -> usize {
        self.received
            .windows(5)
            .filter(|bytes| *bytes == b"\x1b[?6n")
            .count()
    }

    fn shows(&self, needle: &[u8]) -> bool {
        self.received
            .windows(needle.len())
            .any(|bytes| bytes == needle)
    }

    /// Read what the client wrote, and answer each new cursor report request
    /// with `reply`, as a terminal does.
    fn answer(&mut self, answered: &mut usize, reply: &[u8]) {
        let mut bytes = [0u8; 16384];
        match self.master.read(&mut bytes) {
            Ok(n) => self.received.extend_from_slice(&bytes[..n]),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(error) => panic!("PTY read failed: {error}"),
        }
        while *answered < self.cursor_queries() {
            self.master.write_all(reply).unwrap();
            *answered += 1;
        }
    }

    fn wait(&mut self) -> std::process::ExitStatus {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            // Keep acting like a terminal renderer while waiting for detach;
            // otherwise pending shared-screen repaints can fill the PTY.
            let mut bytes = [0u8; 16384];
            for _ in 0..16 {
                match self.master.read(&mut bytes) {
                    Ok(0) => break,
                    Ok(n) => self.received.extend_from_slice(&bytes[..n]),
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                    Err(error) if error.raw_os_error() == Some(libc::EIO) => break,
                    Err(error) => panic!("PTY read failed while waiting for exit: {error}"),
                }
            }
            if let Some(status) = self.child.try_wait().unwrap() {
                return status;
            }
            assert!(Instant::now() < deadline, "attach did not exit");
            thread::sleep(Duration::from_millis(10));
        }
    }
}

#[test]
#[ignore = "requires a built cherry-host binary and permission to bind a socket and open PTYs"]
fn shared_clients_type_resize_disconnect_and_explicitly_take_over_without_restarting() {
    let host = Host::start();
    let created = host.json(&[
        "new", "--cwd", "/tmp", "--name", "Shared CLI smoke", "--", "/bin/sh", "-c",
        "printf 'SHARED_READY\\n'; while IFS= read -r line; do printf 'SHARED_OUT:%s\\n' \"$line\"; done",
    ]);
    let id = created["id"].as_str().unwrap();
    let mut first = Attached::new(&host, id, 80, 24);
    first.expect(b"SHARED_READY");
    let mut second = Attached::new(&host, id, 100, 40);
    second.expect(b"SHARED_READY");
    first.master.write_all(b"first-device\n").unwrap();
    first.expect(b"SHARED_OUT:first-device");
    second.expect(b"SHARED_OUT:first-device");
    second.master.write_all(b"second-device\n").unwrap();
    first.expect(b"SHARED_OUT:second-device");
    second.expect(b"SHARED_OUT:second-device");

    let size = libc::winsize {
        ws_row: 15,
        ws_col: 60,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    assert_eq!(
        unsafe { libc::ioctl(first._slave.as_raw_fd(), libc::TIOCSWINSZ, &size) },
        0
    );
    assert_eq!(
        unsafe { libc::kill(first.child.id() as i32, libc::SIGWINCH) },
        0
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let listed = host.json(&["list", "--json"]);
        if listed["sessions"][0]["cols"] == 60 && listed["sessions"][0]["rows"] == 15 {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "host did not choose the smaller shared grid"
        );
        thread::sleep(Duration::from_millis(10));
    }
    second.master.write_all(b"after-resize\n").unwrap();
    first.expect(b"SHARED_OUT:after-resize");
    second.expect(b"SHARED_OUT:after-resize");
    first.master.write_all(&[0x1d]).unwrap();
    assert!(first.wait().success());
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let listed = host.json(&["list", "--json"]);
        if listed["sessions"][0]["cols"] == 100 && listed["sessions"][0]["rows"] == 40 {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "host did not expand after the smaller client detached"
        );
        thread::sleep(Duration::from_millis(10));
    }
    second.master.write_all(b"still-running\n").unwrap();
    second.expect(b"SHARED_OUT:still-running");
    let mut third = Attached::with_takeover(&host, id, 80, 24, true);
    third.expect(b"SHARED_OUT:still-running");
    assert!(
        !second.wait().success(),
        "takeover should disconnect previous client"
    );
    third.master.write_all(b"after-takeover\n").unwrap();
    third.expect(b"SHARED_OUT:after-takeover");
    let listed = host.json(&["list", "--json"]);
    assert_eq!(listed["sessions"][0]["pid"], created["pid"]);
    third.master.write_all(&[0x1d]).unwrap();
    assert!(third.wait().success());
    host.wait_for_detached_running(id, &created["pid"]);
}

#[test]
#[ignore = "requires a built cherry-host binary and permission to bind a socket and open PTYs"]
fn only_the_terminal_that_typed_last_answers_the_programs_queries() {
    const FIRST: &[u8] = b"\x1b[?11;1R";
    const SECOND: &[u8] = b"\x1b[?22;1R";
    let host = Host::start();
    let directory = private_directory();
    let cwd = directory.path().to_str().unwrap();
    // Each round asks for the cursor and reads one reply; a second reply
    // would be read as the next round's go byte, or land in `extra`.
    let created = host.json(&[
        "new", "--cwd", cwd, "--name", "Queries", "--", "/bin/sh", "-c",
        "stty raw -echo; printf 'READY\\r\\n'; for round in 1 2 3; do dd bs=1 count=1 >/dev/null 2>&1; printf 'ASK%s\\033[?6n' $round; dd bs=1 count=8 2>/dev/null > reply$round; printf '\\r\\nROUND%s\\r\\n' $round; done; stty min 0 time 5; dd bs=1 count=64 2>/dev/null > extra; printf 'DONE\\r\\n'; exec sleep 60",
    ]);
    let id = created["id"].as_str().unwrap();
    // The first window has the shared grid's size and shows the stream
    // directly; the larger second one renders a viewport.
    let mut first = Attached::new(&host, id, 80, 24);
    first.expect(b"READY");
    let mut second = Attached::new(&host, id, 100, 40);
    second.expect(b"READY");
    let mut answered = (0, 0);
    for (round, first_types) in [(1, true), (2, false), (3, true)] {
        let asked = (first.cursor_queries(), second.cursor_queries());
        let typist = if first_types { &mut first } else { &mut second };
        typist.master.write_all(b"g").unwrap();
        let marker = format!("ROUND{round}");
        // A request sent to the other terminal would reach it before this
        // output; it would answer too.
        let deadline = Instant::now() + Duration::from_secs(5);
        while !(first.shows(marker.as_bytes()) && second.shows(marker.as_bytes())) {
            assert!(Instant::now() < deadline, "round {round} did not end");
            first.answer(&mut answered.0, FIRST);
            second.answer(&mut answered.1, SECOND);
            thread::sleep(Duration::from_millis(10));
        }
        let expected = if first_types {
            (asked.0 + 1, asked.1)
        } else {
            (asked.0, asked.1 + 1)
        };
        assert_eq!(
            (first.cursor_queries(), second.cursor_queries()),
            expected,
            "round {round}"
        );
        let reply = std::fs::read(directory.path().join(format!("reply{round}"))).unwrap();
        assert_eq!(reply, if first_types { FIRST } else { SECOND });
    }
    first.expect(b"DONE");
    assert_eq!(std::fs::read(directory.path().join("extra")).unwrap(), b"");
    for attached in [&mut first, &mut second] {
        attached.master.write_all(&[0x1d]).unwrap();
        assert!(attached.wait().success());
    }
    host.wait_for_detached_running(id, &created["pid"]);
}

impl Drop for Attached {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
#[ignore = "requires a built cherry-host binary and permission to bind a socket and open PTYs"]
fn attach_disconnect_reconnect_preserves_process_and_terminal_screen() {
    let host = Host::start();
    let created = host.json(&[
        "new",
        "--cwd",
        "/tmp",
        "--name",
        "CLI smoke",
        "--",
        "/bin/sh",
        "-c",
        "printf 'READY\\n'; while IFS= read -r line; do printf 'OUT:%s\\n' \"$line\"; done",
    ]);
    let id = created["id"].as_str().unwrap();
    let pid = &created["pid"];
    let live_remove = host.command().args(["remove", id]).output().unwrap();
    assert!(
        !live_remove.status.success(),
        "removing a live session must be rejected"
    );
    let mut first = Attached::new(&host, id, 80, 24);
    first.expect(b"READY");
    first.master.write_all(b"ping\n").unwrap();
    first.expect(b"OUT:ping");
    // SIGTERM abruptly tears down the adapter connection, without a Detach
    // request. The host must keep its independent child alive.
    assert_eq!(
        unsafe { libc::kill(first.child.id() as i32, libc::SIGTERM) },
        0
    );
    assert_eq!(first.wait().code(), Some(128 + libc::SIGTERM));
    host.wait_for_detached_running(id, pid);

    let mut second = Attached::new(&host, id, 100, 40);
    second.expect(b"OUT:ping");
    second.master.write_all(b"pong\n").unwrap();
    second.expect(b"OUT:pong");
    second.master.write_all(&[0x1d]).unwrap();
    assert!(second.wait().success());
    host.wait_for_detached_running(id, pid);
    let killed = host.command().args(["kill", id]).output().unwrap();
    assert!(
        killed.status.success(),
        "{}",
        String::from_utf8_lossy(&killed.stderr)
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    while host.json(&["list", "--json"])["sessions"][0]["state"] != "exited" {
        assert!(Instant::now() < deadline, "session did not exit after kill");
        thread::sleep(Duration::from_millis(20));
    }
    let removed = host.command().args(["remove", id]).output().unwrap();
    assert!(
        removed.status.success(),
        "{}",
        String::from_utf8_lossy(&removed.stderr)
    );
    assert!(host.json(&["list", "--json"])["sessions"]
        .as_array()
        .unwrap()
        .is_empty());
}

#[test]
#[ignore = "requires a built cherry-host binary and permission to bind a socket and open PTYs"]
fn piped_input_reaches_the_session_before_detaching() {
    let host = Host::start();
    let directory = tempfile::tempdir().unwrap();
    let marker = directory.path().join("ran");
    let created = host.json(&["new", "--cwd=/tmp", "--name=Piped", "--", "/bin/sh"]);
    let id = created["id"].as_str().unwrap();
    let status = directory.path().join("status.json");
    let mut child = host
        .command()
        .args(["attach", id, "--status-file"])
        .arg(&status)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    writeln!(stdin, "echo ok > '{}'", marker.display()).unwrap();
    drop(stdin);
    let deadline = Instant::now() + Duration::from_secs(5);
    let exit = loop {
        if let Some(exit) = child.try_wait().unwrap() {
            break exit;
        }
        assert!(
            Instant::now() < deadline,
            "attach did not detach at end of input"
        );
        thread::sleep(Duration::from_millis(10));
    };
    assert!(exit.success());
    let value: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&status).unwrap()).unwrap();
    assert_eq!(value["outcome"], "detached");
    let deadline = Instant::now() + Duration::from_secs(5);
    while std::fs::read_to_string(&marker).ok().as_deref() != Some("ok\n") {
        assert!(
            Instant::now() < deadline,
            "input piped before end of file was dropped"
        );
        thread::sleep(Duration::from_millis(20));
    }
    host.wait_for_detached_running(id, &created["pid"]);
}

#[test]
#[ignore = "requires a built cherry-host binary and permission to bind a socket and open PTYs"]
fn detaching_behind_input_the_program_never_reads_gives_up_and_keeps_the_session() {
    let host = Host::start();
    let directory = tempfile::tempdir().unwrap();
    let ready = directory.path().join("ready");
    // In raw mode a full terminal input queue blocks the host's writes
    // instead of dropping input.
    let created = host.json(&[
        "new",
        "--cwd=/tmp",
        "--name=Busy",
        "--",
        "/bin/sh",
        "-c",
        &format!("stty raw -echo; touch '{}'; exec sleep 60", ready.display()),
    ]);
    let id = created["id"].as_str().unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !ready.exists() {
        assert!(Instant::now() < deadline, "session did not start");
        thread::sleep(Duration::from_millis(10));
    }
    let status = directory.path().join("status.json");
    let mut child = host
        .command()
        .args(["attach", id, "--detach-key", "none", "--status-file"])
        .arg(&status)
        .env("CHERRY_CLI_DETACH_WAIT_MS", "1000")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    // More than the host holds for a program that is not reading (1 MiB),
    // little enough that the client reaches the end and queues Detach.
    let mut stdin = child.stdin.take().unwrap();
    let writer = thread::spawn(move || {
        let _ = stdin.write_all(&vec![b'x'; 3 * 512 * 1024]);
    });
    let deadline = Instant::now() + Duration::from_secs(20);
    let exit = loop {
        if let Some(exit) = child.try_wait().unwrap() {
            break exit;
        }
        assert!(Instant::now() < deadline, "the detach never ended");
        thread::sleep(Duration::from_millis(20));
    };
    writer.join().unwrap();
    let mut error = String::new();
    child
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut error)
        .unwrap();
    assert!(exit.success(), "{error}");
    assert!(error.contains("without the host's confirmation"), "{error}");
    let value: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&status).unwrap()).unwrap();
    assert_eq!(value["outcome"], "detached");
    assert!(value["message"].as_str().unwrap().contains("discarded"));
    host.wait_for_detached_running(id, &created["pid"]);
}

#[test]
#[ignore = "requires a built cherry-host binary and permission to bind a socket and open PTYs"]
fn piped_input_a_slow_program_works_through_is_all_delivered_before_detaching() {
    // More than the host holds for a session (1 MiB), for a program far
    // slower than the pipe. The host stops reading until the program has
    // worked through most of it, longer than the detach wait; its Pongs
    // meanwhile show the client that the input still moves.
    const PASTE: usize = 1280 * 1024;
    let host = Host::start();
    let directory = tempfile::tempdir().unwrap();
    let ready = directory.path().join("ready");
    let pasted = directory.path().join("pasted");
    let created = host.json(&[
        "new",
        "--cwd=/tmp",
        "--name=Slow",
        "--",
        "/bin/sh",
        "-c",
        &format!(
            "stty raw -echo; touch '{}'; while :; do dd bs=1 count=16384 2>/dev/null; sleep 0.05; done > '{}'",
            ready.display(),
            pasted.display()
        ),
    ]);
    let id = created["id"].as_str().unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !ready.exists() {
        assert!(Instant::now() < deadline, "session did not start");
        thread::sleep(Duration::from_millis(10));
    }
    let status = directory.path().join("status.json");
    let mut child = host
        .command()
        .args(["attach", id, "--detach-key", "none", "--status-file"])
        .arg(&status)
        .env("CHERRY_CLI_DETACH_WAIT_MS", "2000")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let paste: Vec<u8> = (0..PASTE).map(|i| b'a' + (i % 26) as u8).collect();
    let mut stdin = child.stdin.take().unwrap();
    let writer = {
        let paste = paste.clone();
        thread::spawn(move || stdin.write_all(&paste).unwrap())
    };
    let started = Instant::now();
    let deadline = started + Duration::from_secs(60);
    let exit = loop {
        if let Some(exit) = child.try_wait().unwrap() {
            break exit;
        }
        assert!(Instant::now() < deadline, "the detach never ended");
        thread::sleep(Duration::from_millis(20));
    };
    writer.join().unwrap();
    let mut error = String::new();
    child
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut error)
        .unwrap();
    assert!(exit.success(), "{error}");
    assert_eq!(error, "");
    let value: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&status).unwrap()).unwrap();
    assert_eq!(value["outcome"], "detached");
    assert!(value["message"].is_null(), "{value}");
    // The host queued everything for the program before its Ok.
    let deadline = Instant::now() + Duration::from_secs(30);
    while std::fs::metadata(&pasted).map_or(0, |m| m.len()) < PASTE as u64 {
        assert!(
            Instant::now() < deadline,
            "the program did not get all input"
        );
        thread::sleep(Duration::from_millis(50));
    }
    assert!(
        started.elapsed() > Duration::from_secs(4),
        "the program read faster than intended"
    );
    assert!(
        std::fs::read(&pasted).unwrap() == paste,
        "input was changed"
    );
    host.wait_for_detached_running(id, &created["pid"]);
}

/// A fake `ssh` that runs the remote command on this machine, with the real
/// cherry-host on its PATH and a private HOME, as sshd would.
struct FakeRemote {
    directory: tempfile::TempDir,
    socket: PathBuf,
    home: PathBuf,
}

impl FakeRemote {
    fn new() -> Self {
        let directory = private_directory();
        let bin = directory.path().join("bin");
        let home = directory.path().join("home");
        std::fs::create_dir(&bin).unwrap();
        std::fs::create_dir(&home).unwrap();
        std::os::unix::fs::symlink(host_binary(), bin.join("cherry-host")).unwrap();
        let ssh = bin.join("ssh");
        std::fs::write(
            &ssh,
            format!(
                "#!/bin/sh\nfor command; do :; done\nunset XDG_STATE_HOME CHERRY_HOST_SOCKET\nPATH='{}:/usr/bin:/bin' HOME='{}' exec /bin/sh -c \"$command\"\n",
                bin.display(),
                home.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&ssh, std::fs::Permissions::from_mode(0o700)).unwrap();
        Self {
            // Created by the first host that starts.
            socket: directory.path().join("sockets").join("host.sock"),
            home,
            directory,
        }
    }

    fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cherry"));
        command
            .args(["--host", "fakebox", "--socket"])
            .arg(&self.socket)
            .env(
                "PATH",
                format!(
                    "{}:/usr/bin:/bin",
                    self.directory.path().join("bin").display()
                ),
            )
            .env("CHERRY_HOST_PATH", "/nonexistent/cherry-host")
            .env_remove("CHERRY_SESSION_ID")
            .stdin(Stdio::null());
        command
    }

    fn state_created(&self) -> bool {
        self.home.join("Library").exists() || self.home.join(".local").exists()
    }
}

impl Drop for FakeRemote {
    fn drop(&mut self) {
        // Stop a host the test started, locally: this never starts one.
        let _ = Command::new(env!("CARGO_BIN_EXE_cherry"))
            .arg("--socket")
            .arg(&self.socket)
            .arg("shutdown")
            .env("CHERRY_HOST_PATH", "/nonexistent/cherry-host")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
}

#[test]
#[ignore = "requires a built cherry-host binary and permission to bind a socket and open PTYs"]
fn remote_kill_remove_and_shutdown_never_start_a_host_through_the_real_gateway() {
    let remote = FakeRemote::new();
    for arguments in [&["kill", "S"][..], &["remove", "S"], &["shutdown"]] {
        let output = remote.command().args(arguments).output().unwrap();
        let error = String::from_utf8_lossy(&output.stderr);
        assert_eq!(output.status.code(), Some(1), "{arguments:?}: {error}");
        assert!(
            error.contains(&format!(
                "cherry: cherry-host on fakebox: no cherry-host is running at {} (this command never starts one)",
                remote.socket.display()
            )),
            "{arguments:?}: {error}"
        );
        assert_eq!(
            error.matches("no cherry-host is running").count(),
            1,
            "{error}"
        );
        assert!(
            !remote.socket.parent().unwrap().exists(),
            "{arguments:?} created the socket directory"
        );
        assert!(!remote.state_created(), "{arguments:?} started a host");
    }

    // list may start the host; the others then reach it.
    let listed = remote.command().args(["list", "--json"]).output().unwrap();
    assert!(
        listed.status.success(),
        "{}",
        String::from_utf8_lossy(&listed.stderr)
    );
    assert!(remote.socket.exists());
    assert!(remote.state_created());
    let killed = remote
        .command()
        .args(["kill", "no-such-session"])
        .output()
        .unwrap();
    assert_eq!(killed.status.code(), Some(1));
    let error = String::from_utf8_lossy(&killed.stderr);
    assert!(
        error.contains("host rejected request") && error.contains("unknown session"),
        "{error}"
    );
    let stopped = remote.command().arg("shutdown").output().unwrap();
    assert!(
        stopped.status.success(),
        "{}",
        String::from_utf8_lossy(&stopped.stderr)
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    while remote.socket.exists() {
        assert!(Instant::now() < deadline, "the host did not stop");
        thread::sleep(Duration::from_millis(20));
    }
    // Stopped: kill no longer starts it again.
    let output = remote.command().args(["kill", "S"]).output().unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(!remote.socket.exists());
}
