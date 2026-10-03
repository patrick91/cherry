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
    home: PathBuf,
    child: Child,
    host_id: Option<String>,
}

impl Host {
    fn start() -> Self {
        Self::start_with(&[])
    }

    /// A daemon with extra environment, such as `CHERRY_HOST_TEST_BUILD`.
    fn start_with(env: &[(&str, &str)]) -> Self {
        let directory = private_directory();
        let socket = directory.path().join("host.sock");
        // The daemon keeps its state under HOME; never the real one.
        let home = directory.path().join("home");
        std::fs::create_dir(&home).unwrap();
        let mut command = Self::serve_command(&socket, &home);
        command.envs(env.iter().copied());
        let child = command.spawn().unwrap();
        let mut host = Self {
            _directory: directory,
            socket,
            home,
            child,
            host_id: None,
        };
        host.wait_ready();
        host.host_id = Some(
            host.json(&["list", "--json"])["host_id"]
                .as_str()
                .unwrap()
                .to_owned(),
        );
        host
    }

    fn serve(socket: &Path, home: &Path) -> Child {
        Self::serve_command(socket, home).spawn().unwrap()
    }

    fn serve_command(socket: &Path, home: &Path) -> Command {
        let mut command = Command::new(host_binary());
        command
            .arg("serve")
            .arg("--socket")
            .arg(socket)
            .env("HOME", home)
            .env_remove("XDG_STATE_HOME")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit());
        command
    }

    fn wait_ready(&mut self) {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if UnixStream::connect(&self.socket).is_ok() {
                break;
            }
            assert!(
                self.child.try_wait().unwrap().is_none(),
                "host exited during startup"
            );
            assert!(Instant::now() < deadline, "host did not become ready");
            thread::sleep(Duration::from_millis(10));
        }
    }

    /// SIGKILL the daemon; its sessions' holders keep them running.
    fn crash(&mut self) {
        self.child.kill().unwrap();
        self.child.wait().unwrap();
    }

    /// Start another daemon on the same socket and state, as a supervisor
    /// or the next client would.
    fn respawn(&mut self) {
        self.child = Self::serve(&self.socket, &self.home);
        self.wait_ready();
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

    /// `cherry attach <id>`.
    fn command_attach(&self, id: &str) -> Command {
        let mut command = self.command();
        command.args(["attach", id]);
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

impl Host {
    /// End every session and remove it, so that its holder exits; gives up
    /// after a few seconds.
    fn end_sessions(&self) {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let Ok(output) = self
                .command()
                .args(["list", "--json"])
                .stderr(Stdio::null())
                .output()
            else {
                return;
            };
            let Ok(listing) = serde_json::from_slice::<serde_json::Value>(&output.stdout) else {
                return;
            };
            let sessions = listing["sessions"].as_array().cloned().unwrap_or_default();
            if sessions.is_empty() || Instant::now() >= deadline {
                return;
            }
            for session in sessions {
                let Some(id) = session["id"].as_str() else {
                    continue;
                };
                let action = if session["state"] == "running" {
                    "kill"
                } else {
                    "remove"
                };
                let _ = self
                    .command()
                    .args([action, id])
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status();
            }
            thread::sleep(Duration::from_millis(50));
        }
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        // Best effort cleanup also runs if an assertion fails mid-attachment.
        // Sessions live in holders, which outlive the daemon: with the
        // daemon up, each is ended and removed, so its holder exits. Those
        // left then (the daemon died, or a session would not end) are killed.
        if matches!(self.child.try_wait(), Ok(None)) {
            self.end_sessions();
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        kill_holders(&self.home);
    }
}

/// Kill the holders of the daemons using `home`, found from their manifests
/// (`<state>/sessions/<id>.json`), and their sessions' programs: a holder
/// whose session runs never exits by itself.
fn kill_holders(home: &Path) {
    let base = if cfg!(target_os = "macos") {
        home.join("Library/Application Support/cherry-host")
    } else {
        home.join(".local/state/cherry-host")
    };
    let manifests = std::fs::read_dir(base)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|state| std::fs::read_dir(state.path().join("sessions")).ok())
        .flatten()
        .flatten();
    for manifest in manifests {
        let Some(pid) = std::fs::read(manifest.path())
            .ok()
            .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
            .and_then(|manifest| manifest["holder_pid"].as_i64())
            .and_then(|pid| i32::try_from(pid).ok())
        else {
            continue;
        };
        // Only while that process is still a holder.
        if !command_of(pid).is_some_and(|command| command.contains(" hold ")) {
            continue;
        }
        // Its session's leader is its child, leading a process group of its
        // own: found before the holder goes, which would leave it to init.
        for leader in children(pid) {
            unsafe {
                libc::kill(-leader, libc::SIGKILL);
                libc::kill(leader, libc::SIGKILL);
            }
        }
        unsafe {
            libc::kill(pid, libc::SIGKILL);
        }
    }
}

/// What `ps` shows as `pid`'s command, while it runs.
fn command_of(pid: i32) -> Option<String> {
    let output = Command::new("/bin/ps")
        .args(["-p", &pid.to_string(), "-o", "command="])
        .output()
        .ok()?;
    let command = String::from_utf8_lossy(&output.stdout).trim().to_string();
    (!command.is_empty()).then_some(command)
}

/// The processes whose parent is `pid`.
fn children(pid: i32) -> Vec<i32> {
    let Ok(output) = Command::new("/bin/ps")
        .args(["-A", "-o", "pid=,ppid="])
        .output()
    else {
        return Vec::new();
    };
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace().map(str::parse::<i32>);
            match (fields.next(), fields.next()) {
                (Some(Ok(child)), Some(Ok(parent))) if parent == pid => Some(child),
                _ => None,
            }
        })
        .collect()
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
        let mut command = host.command();
        command.args(["attach", id]);
        if takeover {
            command.arg("--takeover");
        }
        Self::with_command(command, cols, rows)
    }

    fn with_command(command: Command, cols: u16, rows: u16) -> Self {
        Self::with_window(command, cols, rows, (0, 0))
    }

    /// Attached through a terminal of `cols` by `rows` cells and `pixels`
    /// (width, height; 0 when it does not say).
    fn with_window(mut command: Command, cols: u16, rows: u16, pixels: (u16, u16)) -> Self {
        let (mut master, mut slave) = (-1, -1);
        let mut size = libc::winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: pixels.0,
            ws_ypixel: pixels.1,
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
fn two_running_attachments_of_one_client_never_take_turns() {
    // A client that starts again while its earlier run still goes (a tab
    // whose adapter is started before the old one stops): the newer
    // replaces the older, which ends rather than connecting again and
    // replacing the newer in turn.
    let host = Host::start();
    let created = host.json(&[
        "new",
        "--cwd",
        "/tmp",
        "--",
        "/bin/sh",
        "-c",
        "printf 'ONE_CLIENT\\n'; exec sleep 600",
    ]);
    let id = created["id"].as_str().unwrap();
    let run = |cols, rows| {
        let mut command = host.command();
        command
            .args(["attach", id, "--client-id", "tab-1"])
            // A lost connection would be connected again at once.
            .env("CHERRY_CLI_RECONNECT_WINDOW_MS", "30000");
        Attached::with_command(command, cols, rows)
    };
    let mut older = run(80, 24);
    older.expect(b"ONE_CLIENT");
    let mut newer = run(100, 30);
    newer.expect(b"ONE_CLIENT");
    assert!(
        older.wait().success(),
        "the older run ends, as a detach does"
    );
    // The newer one holds the session alone, at its size, from then on.
    let until = Instant::now() + Duration::from_secs(3);
    while Instant::now() < until {
        let listing = host.json(&["list", "--json"]);
        let session = &listing["sessions"][0];
        assert_eq!(
            (&session["clients"], &session["cols"], &session["rows"]),
            (
                &serde_json::json!(1),
                &serde_json::json!(100),
                &serde_json::json!(30)
            ),
            "{listing}"
        );
        thread::sleep(Duration::from_millis(100));
    }
    newer.master.write_all(&[0x1d]).unwrap();
    assert!(newer.wait().success());
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
fn an_escape_typed_just_before_a_termination_signal_reaches_the_session() {
    // The attachment holds a lone Escape for a moment (it could begin an
    // encoded detach key). A SIGTERM then must still deliver it: dropped,
    // it would leave Neovim in insert mode and type the next command.
    let host = Host::start();
    let created = host.json(&[
        "new",
        "--cwd",
        "/tmp",
        "--",
        "/bin/sh",
        "-c",
        "printf 'READY\\n'; while IFS= read -r line; do printf 'HEX:%s:END\\n' \"$(printf '%s' \"$line\" | od -An -tx1 | tr -d ' \\n')\"; done",
    ]);
    let id = created["id"].as_str().unwrap();
    let pid = &created["pid"];
    let mut first = Attached::new(&host, id, 80, 24);
    first.expect(b"READY");
    first.master.write_all(b"x\n").unwrap();
    first.expect(b"HEX:78:END");
    first.master.write_all(b"\x1b").unwrap();
    // Once the attachment has read it, and well within the 25 ms it holds
    // it. (Linux moves what the master writes to the terminal's input a
    // moment later, so its unread count can still be 0 right after the
    // write.) Should the signal come later on a busy machine, the Escape
    // has left anyway and the test passes without testing anything.
    thread::sleep(Duration::from_millis(5));
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let mut unread: libc::c_int = 0;
        assert_eq!(
            unsafe { libc::ioctl(first._slave.as_raw_fd(), libc::FIONREAD, &mut unread) },
            0
        );
        if unread == 0 {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the attachment never read the Escape"
        );
        thread::sleep(Duration::from_millis(1));
    }
    assert_eq!(
        unsafe { libc::kill(first.child.id() as i32, libc::SIGTERM) },
        0
    );
    assert_eq!(first.wait().code(), Some(128 + libc::SIGTERM));
    host.wait_for_detached_running(id, pid);
    let mut second = Attached::new(&host, id, 80, 24);
    second.master.write_all(b"y\n").unwrap();
    // The Escape, then y; without it the line would be 79 alone.
    second.expect(b"HEX:1b79:END");
    second.master.write_all(&[0x1d]).unwrap();
    assert!(second.wait().success());
    let killed = host.command().args(["kill", id]).output().unwrap();
    assert!(killed.status.success());
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
        // A daemon a gateway started has no parent to stop it, and it would
        // outlive this directory. Its holders go first: their sessions then
        // count as ended, so the shutdown (refused while sessions run) is
        // not refused. It is sent locally, which never starts a host.
        kill_holders(&self.home);
        let deadline = Instant::now() + Duration::from_secs(3);
        while self.socket.exists() && Instant::now() < deadline {
            let _ = Command::new(env!("CARGO_BIN_EXE_cherry"))
                .arg("--socket")
                .arg(&self.socket)
                .arg("shutdown")
                .env("CHERRY_HOST_PATH", "/nonexistent/cherry-host")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
            thread::sleep(Duration::from_millis(50));
        }
        // Whatever still serves or holds sessions for this socket.
        for (pid, _) in processes_using(&self.socket) {
            unsafe {
                libc::kill(pid, libc::SIGKILL);
            }
        }
    }
}

/// The cherry-host daemons and holders using `socket` (`cherry-host serve
/// --socket <socket>`, `cherry-host hold --socket <socket>`), with their
/// commands.
fn processes_using(socket: &Path) -> Vec<(i32, String)> {
    let Ok(output) = Command::new("/bin/ps")
        .args(["-A", "-o", "pid=,command="])
        .output()
    else {
        return Vec::new();
    };
    let serve = format!(" serve --socket {}", socket.display());
    let hold = format!(" hold --socket {}", socket.display());
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| {
            let (pid, command) = line.trim_start().split_once(' ')?;
            let command = command.trim();
            (command.ends_with(&serve) || command.ends_with(&hold))
                .then(|| Some((pid.parse().ok()?, command.to_owned())))?
        })
        .collect()
}

/// A daemon speaking `version` at `socket` as `host_id`, as the real one
/// answers: every Hello with a Welcome of its own version, and a `Replace`
/// from a client of a newer version by removing its socket, answering Ok
/// and listening no more (sessions would carry on in their holders). What
/// it was sent, in order.
fn daemon_speaking(
    socket: &Path,
    version: u32,
    host_id: &str,
) -> std::sync::Arc<std::sync::Mutex<Vec<cherry_protocol::ClientMessage>>> {
    use cherry_protocol::{read_frame, write_frame, ClientMessage, ServerMessage};
    let directory = socket.parent().unwrap();
    std::fs::create_dir_all(directory).unwrap();
    std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700)).unwrap();
    let listener = std::os::unix::net::UnixListener::bind(socket).unwrap();
    let requests = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let heard = requests.clone();
    let socket = socket.to_path_buf();
    let host_id = host_id.to_owned();
    thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else {
                continue;
            };
            let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
            let mut hello = None;
            while let Ok(Some(request)) = read_frame::<_, ClientMessage>(&mut stream) {
                heard.lock().unwrap().push(request.clone());
                let reply = match request {
                    ClientMessage::Hello { version: client } => {
                        hello = Some(client);
                        ServerMessage::Welcome {
                            version,
                            host_id: host_id.clone(),
                            build: None,
                        }
                    }
                    ClientMessage::Replace if hello.is_some_and(|client| client > version) => {
                        std::fs::remove_file(&socket).unwrap();
                        let _ = write_frame(&mut stream, &ServerMessage::Ok);
                        return;
                    }
                    _ => ServerMessage::error("version_mismatch", "only replace is accepted"),
                };
                let _ = write_frame(&mut stream, &reply);
            }
        }
    });
    requests
}

#[test]
#[ignore = "requires a built cherry-host binary and permission to bind a socket and open PTYs"]
fn the_real_gateway_replaces_an_older_remote_daemon_and_reports_a_newer_one() {
    use cherry_protocol::{ClientMessage, PROTOCOL_VERSION};
    // An update: the remote machine's cherry-host is this build now, and
    // the daemon of the previous one still runs there.
    let remote = FakeRemote::new();
    let older = PROTOCOL_VERSION - 1;
    let requests = daemon_speaking(&remote.socket, older, &format!("daemon-{older}"));
    // kill, remove and shutdown never replace it; they say what does.
    let output = remote.command().args(["kill", "S"]).output().unwrap();
    assert_eq!(output.status.code(), Some(1));
    let error = String::from_utf8_lossy(&output.stderr);
    assert!(
        error.contains(&format!(
            "cherry-host on fakebox: a cherry-host speaking protocol {older} is running"
        )) && error.contains("replace it"),
        "{error}"
    );
    assert!(!requests.lock().unwrap().contains(&ClientMessage::Replace));
    assert!(!remote.state_created());
    // list replaces it through the gateway, which starts the new daemon.
    let listed = remote.command().args(["list", "--json"]).output().unwrap();
    assert!(
        listed.status.success(),
        "{}",
        String::from_utf8_lossy(&listed.stderr)
    );
    let listing: serde_json::Value = serde_json::from_slice(&listed.stdout).unwrap();
    let host_id = listing["host_id"].as_str().unwrap().to_owned();
    assert_ne!(host_id, format!("daemon-{older}"));
    assert_eq!(listing["sessions"], serde_json::json!([]));
    let heard = requests.lock().unwrap().clone();
    assert_eq!(heard.last(), Some(&ClientMessage::Replace), "{heard:?}");
    assert!(remote.state_created());
    // It serves the socket now, for every client.
    let again = remote.command().args(["list", "--json"]).output().unwrap();
    assert!(again.status.success());
    let listing: serde_json::Value = serde_json::from_slice(&again.stdout).unwrap();
    assert_eq!(listing["host_id"], host_id.as_str());
    drop(remote);

    // A newer daemon is never replaced, and the error says so.
    let remote = FakeRemote::new();
    let newer = PROTOCOL_VERSION + 1;
    let requests = daemon_speaking(&remote.socket, newer, &format!("daemon-{newer}"));
    for arguments in [&["list", "--json"][..], &["kill", "S"]] {
        let output = remote.command().args(arguments).output().unwrap();
        assert_eq!(output.status.code(), Some(1), "{arguments:?}");
        let error = String::from_utf8_lossy(&output.stderr);
        assert!(
            error.contains(&format!(
                "cherry-host on fakebox: a cherry-host speaking protocol {newer} is running"
            )) && error.contains("newer than this cherry-host"),
            "{arguments:?}: {error}"
        );
    }
    assert!(!requests.lock().unwrap().contains(&ClientMessage::Replace));
    assert!(!remote.state_created());
    assert!(remote.socket.exists());
}

#[test]
#[ignore = "requires a built cherry-host binary and permission to bind a socket and open PTYs"]
fn the_real_gateway_leaves_a_host_of_another_identity_to_the_client() {
    use cherry_protocol::{ClientMessage, PROTOCOL_VERSION};
    let output_of = |remote: &FakeRemote, arguments: &[&str]| {
        remote.command().args(arguments).output().unwrap()
    };
    let stderr =
        |output: &std::process::Output| String::from_utf8_lossy(&output.stderr).to_string();
    // The host a client knows from before: its identity is kept in its
    // state directory. It stops, and the previous version of cherry-host
    // serves the socket under that identity, as before an update there.
    let remote = FakeRemote::new();
    let listed = output_of(&remote, &["list", "--json"]);
    assert!(listed.status.success(), "{}", stderr(&listed));
    let intended = serde_json::from_slice::<serde_json::Value>(&listed.stdout).unwrap()["host_id"]
        .as_str()
        .unwrap()
        .to_owned();
    let stopped = output_of(&remote, &["shutdown"]);
    assert!(stopped.status.success(), "{}", stderr(&stopped));
    let deadline = Instant::now() + Duration::from_secs(5);
    while remote.socket.exists() {
        assert!(Instant::now() < deadline, "the host did not stop");
        thread::sleep(Duration::from_millis(20));
    }
    let older = PROTOCOL_VERSION - 1;
    let requests = daemon_speaking(&remote.socket, older, &intended);
    // A client that expects another host neither uses nor replaces it,
    // whether its command may start a host or not: its identity is checked
    // before its version, as it is locally.
    let stranger = uuid::Uuid::new_v4().to_string();
    for arguments in [&["list", "--json"][..], &["kill", "S"]] {
        let output = output_of(
            &remote,
            &[&["--expected-host-id", stranger.as_str()][..], arguments].concat(),
        );
        assert_eq!(output.status.code(), Some(1), "{arguments:?}");
        assert!(
            stderr(&output).contains(&format!(
                "host identity changed (expected {stranger}, received {intended})"
            )),
            "{arguments:?}: {}",
            stderr(&output)
        );
    }
    assert!(!requests.lock().unwrap().contains(&ClientMessage::Replace));
    // The intended host is replaced, and the next daemon is that host.
    let listed = output_of(
        &remote,
        &["--expected-host-id", intended.as_str(), "list", "--json"],
    );
    assert!(listed.status.success(), "{}", stderr(&listed));
    let listing: serde_json::Value = serde_json::from_slice(&listed.stdout).unwrap();
    assert_eq!(listing["host_id"], intended.as_str());
    let heard = requests.lock().unwrap().clone();
    assert_eq!(heard.last(), Some(&ClientMessage::Replace), "{heard:?}");
    drop(remote);

    // A newer host of another identity is refused for its identity too;
    // the intended one for its version.
    let remote = FakeRemote::new();
    let newer = PROTOCOL_VERSION + 1;
    let other = uuid::Uuid::new_v4().to_string();
    let requests = daemon_speaking(&remote.socket, newer, &other);
    let output = output_of(
        &remote,
        &["--expected-host-id", stranger.as_str(), "list", "--json"],
    );
    assert_eq!(output.status.code(), Some(1));
    assert!(
        stderr(&output).contains(&format!(
            "host identity changed (expected {stranger}, received {other})"
        )),
        "{}",
        stderr(&output)
    );
    let output = output_of(
        &remote,
        &["--expected-host-id", other.as_str(), "list", "--json"],
    );
    assert_eq!(output.status.code(), Some(1));
    assert!(
        stderr(&output).contains("newer than this cherry-host"),
        "{}",
        stderr(&output)
    );
    assert!(!requests.lock().unwrap().contains(&ClientMessage::Replace));
    assert!(!remote.state_created());
}

#[test]
#[ignore = "requires a built cherry-host binary and permission to bind a socket and open PTYs"]
fn a_fake_remote_dropped_with_a_running_session_leaves_nothing_behind() {
    // The harness itself: a daemon a gateway started has no parent to stop
    // it, and a running session's holder never exits by itself.
    let remote = FakeRemote::new();
    let socket = remote.socket.clone();
    let created = remote
        .command()
        .args([
            "new",
            "--cwd=/tmp",
            "--name=Left",
            "--",
            "/bin/sh",
            "-c",
            "trap '' HUP TERM; exec sleep 60",
        ])
        .output()
        .unwrap();
    assert!(
        created.status.success(),
        "{}",
        String::from_utf8_lossy(&created.stderr)
    );
    let created: serde_json::Value = serde_json::from_slice(&created.stdout).unwrap();
    let program = i32::try_from(created["pid"].as_i64().unwrap()).unwrap();
    let using = processes_using(&socket);
    assert!(
        using.iter().any(|(_, command)| command.contains(" serve "))
            && using.iter().any(|(_, command)| command.contains(" hold ")),
        "{using:?}"
    );
    // Should the harness regress, this test does not leave them either.
    struct Leftovers(PathBuf);
    impl Drop for Leftovers {
        fn drop(&mut self) {
            for (pid, _) in processes_using(&self.0) {
                unsafe {
                    libc::kill(pid, libc::SIGKILL);
                }
            }
        }
    }
    let _leftovers = Leftovers(socket.clone());
    drop(remote);
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let using = processes_using(&socket);
        let program_runs = command_of(program).is_some_and(|command| command.contains("sleep"));
        if using.is_empty() && !program_runs {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "left behind: {using:?}, the program running: {program_runs}"
        );
        thread::sleep(Duration::from_millis(50));
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

fn frame(message: &impl cherry_protocol::Message) -> Vec<u8> {
    cherry_protocol::encode_frame(message).unwrap()
}

fn next_response(output: &mut impl Read) -> cherry_protocol::Response {
    cherry_protocol::read_frame(output)
        .unwrap()
        .expect("control output ended")
}

/// `cherry control` on `command`: its Welcome, then each request with its
/// id and the answer echoing it, then the end of its input ends it.
fn control_lists_and_kills(mut command: Command, host_id: Option<&str>, kill: Option<&str>) {
    use cherry_protocol::{ClientMessage, Request, Response, ServerMessage, PROTOCOL_VERSION};
    let mut child = command
        .arg("control")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = child.stdout.take().unwrap();
    let welcome = next_response(&mut stdout);
    let ServerMessage::Welcome {
        version,
        host_id: welcomed,
        ..
    } = welcome.message
    else {
        panic!("expected welcome, received {welcome:?}");
    };
    assert_eq!(version, PROTOCOL_VERSION);
    if let Some(host_id) = host_id {
        assert_eq!(welcomed, host_id);
    }
    let mut requests = frame(&Request::new(Some(1), ClientMessage::List));
    if let Some(id) = kill {
        requests.extend(frame(&Request::new(
            Some(2),
            ClientMessage::Kill { id: id.into() },
        )));
    }
    requests.extend(frame(&ClientMessage::Ping));
    stdin.write_all(&requests).unwrap();
    let listed = next_response(&mut stdout);
    let Response {
        req: Some(1),
        message: ServerMessage::Sessions {
            host_id, sessions, ..
        },
    } = listed
    else {
        panic!("expected sessions for request 1, received {listed:?}");
    };
    assert_eq!(host_id, welcomed);
    if let Some(id) = kill {
        let session = sessions.iter().find(|session| session.id == id).unwrap();
        assert_eq!(session.owner.as_deref(), Some("dev.cherry.test"));
        assert_eq!(
            session.tags.get("cherry.tab").map(String::as_str),
            Some("T1")
        );
        assert_eq!(
            next_response(&mut stdout),
            Response::new(Some(2), ServerMessage::Ok)
        );
    }
    assert_eq!(
        next_response(&mut stdout),
        Response::new(None, ServerMessage::Pong)
    );
    drop(stdin);
    let status = child.wait().unwrap();
    let mut error = String::new();
    child
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut error)
        .unwrap();
    assert!(status.success(), "{error}");
    let mut rest = Vec::new();
    stdout.read_to_end(&mut rest).unwrap();
    assert!(rest.is_empty(), "control wrote more than frames: {rest:?}");
}

#[test]
#[ignore = "requires a built cherry-host binary and permission to bind a socket and open PTYs"]
fn control_relays_requests_with_ids_and_new_records_owner_and_tags() {
    let host = Host::start();
    let created = host.json(&[
        "new",
        "--cwd=/",
        "--name=tagged",
        "--owner=dev.cherry.test",
        "--tag=cherry.tab=T1",
        "--env=LANG=C",
        "--",
        "/bin/sh",
        "-c",
        "sleep 30",
    ]);
    assert_eq!(created["owner"], "dev.cherry.test");
    assert_eq!(created["tags"]["cherry.tab"], "T1");
    control_lists_and_kills(
        host.command(),
        host.host_id.as_deref(),
        created["id"].as_str(),
    );
}

#[test]
#[ignore = "requires a built cherry-host binary and permission to bind a socket and open PTYs"]
fn control_starts_a_remote_host_through_the_real_gateway() {
    let remote = FakeRemote::new();
    control_lists_and_kills(remote.command(), None, None);
    assert!(remote.socket.exists());
    assert!(remote.state_created());
}

/// Wait until the status file satisfies `accept`, returning it.
fn wait_for_status(
    path: &Path,
    limit: Duration,
    accept: impl Fn(&serde_json::Value) -> bool,
) -> serde_json::Value {
    let deadline = Instant::now() + limit;
    let mut last = None;
    loop {
        if let Ok(bytes) = std::fs::read(path) {
            let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
            if accept(&value) {
                return value;
            }
            last = Some(value);
        }
        assert!(
            Instant::now() < deadline,
            "status never matched; last {last:?}"
        );
        thread::sleep(Duration::from_millis(10));
    }
}

#[test]
#[ignore = "requires a built cherry-host binary and permission to bind a socket and open PTYs"]
fn an_attachment_reconnects_by_itself_after_the_daemon_is_killed_and_restarted() {
    let mut host = Host::start();
    let directory = private_directory();
    let status = directory.path().join("status.json");
    let created = host.json(&[
        "new",
        "--cwd",
        "/tmp",
        "--name",
        "Crash",
        "--",
        "/bin/sh",
        "-c",
        "printf 'READY\\n'; while IFS= read -r line; do printf 'OUT:%s\\n' \"$line\"; done",
    ]);
    let id = created["id"].as_str().unwrap();
    let mut command = host.command();
    command.args(["attach", id, "--status-file"]).arg(&status);
    let mut attached = Attached::with_command(command, 80, 24);
    attached.expect(b"READY");
    let attached_live = |reconnecting: bool| {
        move |status: &serde_json::Value| {
            status["outcome"] == "attached" && status["reconnecting"] == reconnecting
        }
    };
    wait_for_status(&status, Duration::from_secs(5), attached_live(false));
    attached.master.write_all(b"before\n").unwrap();
    attached.expect(b"OUT:before");

    // The daemon dies; the session lives on in its holder.
    host.crash();
    let reconnecting = wait_for_status(&status, Duration::from_secs(5), attached_live(true));
    assert_eq!(reconnecting["viewport"], false);
    assert!(attached.child.try_wait().unwrap().is_none());
    host.respawn();
    // Its next attempt (at most 2 s apart) finds the new daemon, which
    // knows the session once its holder registered again.
    wait_for_status(&status, Duration::from_secs(15), attached_live(false));
    attached.master.write_all(b"after\n").unwrap();
    attached.expect(b"OUT:after");
    let listed = host.json(&["list", "--json"]);
    let session = &listed["sessions"][0];
    assert_eq!(session["id"], id);
    assert_eq!(session["state"], "running");
    assert_eq!(session["pid"], created["pid"], "the program was restarted");
    assert_eq!(session["attached"], true);

    attached.master.write_all(&[0x1d]).unwrap();
    assert!(attached.wait().success());
    assert_eq!(
        wait_for_status(&status, Duration::from_secs(5), |status| status["outcome"]
            != "attached")["outcome"],
        "detached"
    );
    host.wait_for_detached_running(id, &created["pid"]);
}

#[test]
#[ignore = "requires a built cherry-host binary and permission to bind a socket and open PTYs"]
fn restart_replaces_the_daemon_and_keeps_its_running_sessions() {
    let mut host = Host::start();
    // Dropped before `host`, whose cleanup then ends the holders.
    let _daemons = Daemons(host.socket.clone());
    let created = host.json(&[
        "new",
        "--cwd",
        "/tmp",
        "--name",
        "Kept",
        "--",
        "/bin/sh",
        "-c",
        "exec sleep 60",
    ]);
    let id = created["id"].as_str().unwrap().to_owned();
    let daemons = |host: &Host| serving_daemons(&host.socket);
    assert_eq!(daemons(&host), [host.child.id() as i32]);
    // No cherry-host could be started (this command's CHERRY_HOST_PATH
    // names nothing): the restart is refused, and the host keeps running.
    let refused = host.command().arg("restart").output().unwrap();
    assert!(!refused.status.success());
    let stderr = String::from_utf8_lossy(&refused.stderr);
    assert!(stderr.contains("refusing to restart"), "{stderr}");
    assert!(host.child.try_wait().unwrap().is_none());
    assert_eq!(daemons(&host), [host.child.id() as i32]);
    // A conditional restart that names another daemon leaves this one
    // running (exit 4), on the connection that checked it.
    let status = host.json(&["status", "--json"]);
    let pid = status["host"]["pid"].as_u64().unwrap().to_string();
    let executable = status["host"]["executable"].as_str().unwrap().to_owned();
    let build = status["host"]["build"].as_str().unwrap().to_owned();
    for (option, value) in [
        ("--if-pid", "1"),
        ("--if-executable", "/nonexistent/cherry-host"),
        ("--if-build", "20000101000000.other"),
    ] {
        let unmet = host
            .command()
            .args(["restart", option, value])
            .env("CHERRY_HOST_PATH", host_binary())
            .env("HOME", &host.home)
            .env_remove("XDG_STATE_HOME")
            .output()
            .unwrap();
        assert_eq!(unmet.status.code(), Some(4), "{option}");
        assert!(
            String::from_utf8_lossy(&unmet.stderr).contains("keeps running"),
            "{}",
            String::from_utf8_lossy(&unmet.stderr)
        );
        assert!(host.child.try_wait().unwrap().is_none());
        assert_eq!(daemons(&host), [host.child.id() as i32]);
    }
    // The new daemon is this build's, with the test's private state; the
    // conditions name the daemon that runs.
    let output = host
        .command()
        .args([
            "restart",
            "--if-pid",
            &pid,
            "--if-executable",
            &executable,
            "--if-build",
            &build,
        ])
        .env("CHERRY_HOST_PATH", host_binary())
        .env("HOME", &host.home)
        .env_remove("XDG_STATE_HOME")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    // The old daemon exited; another serves the same socket and state.
    let old = host.child.wait().unwrap();
    assert!(old.success(), "{old}");
    let now = daemons(&host);
    assert_eq!(now.len(), 1, "{now:?}");
    assert_ne!(now[0], host.child.id() as i32);
    let deadline = Instant::now() + Duration::from_secs(10);
    let session = loop {
        let listing = host.json(&["list", "--json"]);
        assert_eq!(listing["host_id"].as_str(), host.host_id.as_deref());
        if let Some(session) = listing["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|session| session["id"] == id.as_str())
        {
            break session.clone();
        }
        assert!(Instant::now() < deadline, "the session was not adopted");
        thread::sleep(Duration::from_millis(50));
    };
    assert_eq!(session["state"], "running");
    assert_eq!(session["pid"], created["pid"], "the program was restarted");
    // Leave nothing behind: the new daemon is not the test's child.
    host.end_sessions();
    let stopped = host.command().arg("shutdown").status().unwrap();
    assert!(stopped.success());
    let deadline = Instant::now() + Duration::from_secs(5);
    while !daemons(&host).is_empty() {
        assert!(Instant::now() < deadline, "the new daemon did not stop");
        thread::sleep(Duration::from_millis(50));
    }
    // Restart is local only.
    let remote = host
        .command()
        .args(["--host", "example", "restart"])
        .output()
        .unwrap();
    assert!(!remote.status.success());
    assert!(String::from_utf8_lossy(&remote.stderr).contains("local only"));
}

/// Read a client's terminal (the PTY master) at `rate` bytes a second (as
/// fast as it comes: None) until `stop` is set, noting when each read came
/// and how much it took.
fn read_terminal(
    master: File,
    rate: Option<usize>,
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
) -> thread::JoinHandle<Vec<(Instant, usize)>> {
    thread::spawn(move || {
        let mut master = master;
        let started = Instant::now();
        let (mut total, mut arrivals) = (0, Vec::new());
        let mut bytes = [0u8; 16 * 1024];
        while !stop.load(std::sync::atomic::Ordering::SeqCst) {
            let want = match rate {
                Some(rate) => {
                    let allowed = (rate as f64 * started.elapsed().as_secs_f64()) as usize;
                    allowed.saturating_sub(total).min(bytes.len())
                }
                None => bytes.len(),
            };
            if want < 1024 {
                thread::sleep(Duration::from_millis(5));
                continue;
            }
            match master.read(&mut bytes[..want]) {
                Ok(0) => break,
                Ok(n) => {
                    total += n;
                    arrivals.push((Instant::now(), n));
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(1));
                }
                Err(_) => break,
            }
        }
        arrivals
    })
}

#[test]
#[ignore = "requires a built cherry-host binary and permission to bind a socket and open PTYs"]
fn a_slow_terminal_holds_back_neither_the_program_nor_a_faster_window() {
    // One window's terminal takes its output slowly: the program goes at
    // the pace of the session's faster window, which gets its output
    // evenly, without long pauses; the slow terminal takes output all along
    // at its own pace, falling behind (it is resynchronized instead).
    let host = Host::start();
    let created = host.json(&[
        "new",
        "--cwd",
        "/tmp",
        "--",
        "/bin/sh",
        "-c",
        "stty -echo; exec yes \"$(printf %0120d 7)\"",
    ]);
    let id = created["id"].as_str().unwrap();
    let mut fast = Attached::new(&host, id, 80, 24);
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let rate = 50 * 1024;
    let fast_reader = read_terminal(fast.master.try_clone().unwrap(), None, stop.clone());
    // The fast window's pace alone, on this machine (a debug build takes
    // about 800 KB/s here, a loaded CI runner far less).
    thread::sleep(Duration::from_secs(1));
    let alone_from = Instant::now();
    thread::sleep(Duration::from_secs(2));
    let alone_to = Instant::now();
    let mut slow = Attached::new(&host, id, 80, 24);
    let slow_reader = read_terminal(slow.master.try_clone().unwrap(), Some(rate), stop.clone());
    // The slow window's buffers fill first.
    thread::sleep(Duration::from_secs(3));
    let from = Instant::now();
    thread::sleep(Duration::from_secs(4));
    let to = Instant::now();
    stop.store(true, std::sync::atomic::Ordering::SeqCst);
    let window = |arrivals: &[(Instant, usize)]| -> Vec<(Instant, usize)> {
        arrivals
            .iter()
            .copied()
            .filter(|(at, _)| (from..=to).contains(at))
            .collect()
    };
    let all_fast_arrivals = fast_reader.join().unwrap();
    let fast_arrivals = window(&all_fast_arrivals);
    let slow_arrivals = window(&slow_reader.join().unwrap());
    let bytes = |arrivals: &[(Instant, usize)]| arrivals.iter().map(|(_, n)| n).sum::<usize>();
    let alone_rate = all_fast_arrivals
        .iter()
        .filter(|(at, _)| (alone_from..=alone_to).contains(at))
        .map(|(_, n)| n)
        .sum::<usize>() as f64
        / (alone_to - alone_from).as_secs_f64();
    let seconds = (to - from).as_secs_f64();
    let (fast_rate, slow_rate) = (
        bytes(&fast_arrivals) as f64 / seconds,
        bytes(&slow_arrivals) as f64 / seconds,
    );
    // The slow terminal takes output all along, at its pace.
    assert!(slow_rate > 0.8 * rate as f64, "slow {slow_rate:.0} B/s");
    // The program, and so the other window, keeps going at its own pace:
    // at least half what it took alone, and well past the slow one's.
    assert!(
        fast_rate > 0.5 * alone_rate && fast_rate > 2.0 * slow_rate,
        "fast {fast_rate:.0} B/s (alone {alone_rate:.0} B/s), slow {slow_rate:.0} B/s"
    );
    // Evenly: no long pause.
    let mut last = from;
    let mut longest = Duration::ZERO;
    for (at, _) in fast_arrivals.iter().copied().chain([(to, 0)]) {
        longest = longest.max(at - last);
        last = at;
    }
    assert!(
        longest < Duration::from_millis(500),
        "the other window waited {longest:?} for output"
    );
    let _ = fast.child.kill();
    let _ = slow.child.kill();
    let _ = fast.child.wait();
    let _ = slow.child.wait();
}

/// Kills whatever daemon serves `socket` when a test ends, however it ends:
/// one that the CLI started (a restart, a handover) is not the test's child.
struct Daemons(PathBuf);

impl Drop for Daemons {
    fn drop(&mut self) {
        for (pid, command) in processes_using(&self.0) {
            if command.contains(" serve ") {
                unsafe {
                    libc::kill(pid, libc::SIGKILL);
                }
            }
        }
    }
}

fn serving_daemons(socket: &Path) -> Vec<i32> {
    processes_using(socket)
        .into_iter()
        .filter(|(_, command)| command.contains(" serve "))
        .map(|(pid, _)| pid)
        .collect()
}

#[test]
#[ignore = "requires a built cherry-host binary and permission to bind a socket and open PTYs"]
fn status_and_doctor_describe_a_running_host() {
    let host = Host::start();
    let created = host.json(&[
        "new",
        "--cwd",
        "/tmp",
        "--",
        "/bin/sh",
        "-c",
        "exec sleep 60",
    ]);
    let status = host.json(&["status", "--json"]);
    assert_eq!(status["running"], true);
    assert_eq!(status["build"], cherry_protocol::BUILD);
    assert_eq!(status["client"]["build"], cherry_protocol::BUILD);
    assert_eq!(status["host"]["pid"], host.child.id());
    assert_eq!(status["host"]["build"], cherry_protocol::BUILD);
    assert_eq!(status["host"]["socket"], host.socket.display().to_string());
    assert_eq!(status["host"]["sessions"], 1);
    assert_eq!(status["host"]["max_sessions"], 128);
    assert_eq!(status["host"]["holders_registered"], 1);
    assert!(status["host"]["uptime_ms"].as_u64().is_some());
    assert!(status["host"]["state_dir"]
        .as_str()
        .unwrap()
        .starts_with(host.home.to_str().unwrap()));
    let sessions = status["sessions"].as_array().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["id"], created["id"]);
    assert_eq!(sessions[0]["holder_build"], cherry_protocol::BUILD);
    let text = host.command().arg("status").output().unwrap();
    assert!(text.status.success());
    let text = String::from_utf8_lossy(&text.stdout);
    assert!(
        text.starts_with(&format!(
            "cherry-host {}, protocol {}, pid {}, up ",
            cherry_protocol::BUILD,
            cherry_protocol::PROTOCOL_VERSION,
            host.child.id()
        )),
        "{text}"
    );
    assert!(text.contains("sessions     1 of 128 (1 running)"), "{text}");

    let doctor = host
        .command()
        .arg("doctor")
        .env("CHERRY_HOST_PATH", host_binary())
        .env("HOME", &host.home)
        .output()
        .unwrap();
    let report = String::from_utf8_lossy(&doctor.stdout);
    assert!(doctor.status.success(), "{report}");
    assert!(
        report.contains("the host runs this cherry's build and protocol"),
        "{report}"
    );
    assert!(report.contains("PID file"), "{report}");
    assert!(report.ends_with("No problems found.\n"), "{report}");

    // An older build of this protocol is a problem doctor names.
    drop(host);
    let host = Host::start_with(&[("CHERRY_HOST_TEST_BUILD", OLD_BUILD)]);
    let doctor = handing_over(&host, None).arg("doctor").output().unwrap();
    let report = String::from_utf8_lossy(&doctor.stdout);
    assert_eq!(doctor.status.code(), Some(1), "{report}");
    assert!(
        report.contains(&format!(
            "PROBLEM  the host runs build {OLD_BUILD}, older than this cherry's {NEW_BUILD}"
        )),
        "{report}"
    );
    assert!(report.contains("fix: `cherry restart`"), "{report}");
}

/// A build older than `NEW_BUILD`, which the daemons of these tests report.
const OLD_BUILD: &str = "20000101000000.0ld0000";
/// The build the CLI acts as (`CHERRY_TEST_BUILD`), and the cherry-host it
/// would start says (`CHERRY_HOST_TEST_BUILD`, read by its `--version`).
const NEW_BUILD: &str = "20300101000000.n3w0000";

/// A `cherry` for `host` that could hand its daemon over: it acts as
/// `NEW_BUILD`, its cherry-host to start is the test's (the daemon's own
/// executable) and says `NEW_BUILD`, and everything uses the host's private
/// HOME. The daemon it starts reports `serve_build` (none: this build's).
fn handing_over(host: &Host, serve_build: Option<&str>) -> Command {
    let mut command = host.command();
    command
        .env("CHERRY_HOST_PATH", host_binary())
        .env("HOME", &host.home)
        .env_remove("XDG_STATE_HOME")
        .env("CHERRY_TEST_BUILD", NEW_BUILD)
        .env("CHERRY_HOST_TEST_BUILD", NEW_BUILD);
    match serve_build {
        Some(build) => command.env("CHERRY_HOST_TEST_SERVE_BUILD", build),
        None => command.env_remove("CHERRY_HOST_TEST_SERVE_BUILD"),
    };
    command
}

fn wait_for_exit(child: &mut Child, what: &str) -> std::process::ExitStatus {
    // Bounded, so that a client that never hands over fails rather than
    // waits for good.
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status;
        }
        assert!(Instant::now() < deadline, "{what}");
        thread::sleep(Duration::from_millis(50));
    }
}

#[test]
#[ignore = "requires a built cherry-host binary and permission to bind a socket and open PTYs"]
fn a_client_hands_an_older_build_of_its_protocol_over_to_its_own() {
    let mut host = Host::start_with(&[("CHERRY_HOST_TEST_BUILD", OLD_BUILD)]);
    let _daemons = Daemons(host.socket.clone());
    let created = host.json(&[
        "new",
        "--cwd",
        "/tmp",
        "--",
        "/bin/sh",
        "-c",
        "exec sleep 60",
    ]);
    let id = created["id"].as_str().unwrap().to_owned();
    assert_eq!(created["holder_build"], OLD_BUILD);
    // A client that may not start a host (status) leaves it alone, though it
    // could start the newer build, and so does a development build (this
    // tree's own, which never orders against another).
    let status = handing_over(&host, Some(NEW_BUILD))
        .args(["status", "--json"])
        .output()
        .unwrap();
    assert!(status.status.success());
    let status: serde_json::Value = serde_json::from_slice(&status.stdout).unwrap();
    assert_eq!(status["build"], OLD_BUILD);
    assert!(host
        .command()
        .arg("list")
        .env("CHERRY_HOST_PATH", host_binary())
        .env("HOME", &host.home)
        .status()
        .unwrap()
        .success());
    assert_eq!(serving_daemons(&host.socket), [host.child.id() as i32]);
    // `list` of a newer build, whose cherry-host is the daemon's own
    // executable updated, hands the daemon over.
    let listed = handing_over(&host, Some(NEW_BUILD))
        .args(["list", "--json"])
        .output()
        .unwrap();
    assert!(
        listed.status.success(),
        "{}",
        String::from_utf8_lossy(&listed.stderr)
    );
    let replaced = wait_for_exit(
        &mut host.child,
        "the daemon of the older build was not replaced",
    );
    assert!(replaced.success(), "{replaced}");
    let now = serving_daemons(&host.socket);
    assert_eq!(now.len(), 1, "{now:?}");
    let status = host.json(&["status", "--json"]);
    assert_eq!(status["build"], NEW_BUILD);
    assert_eq!(status["host_id"].as_str(), host.host_id.as_deref());
    // The session carries on in its holder, which keeps its own build.
    let deadline = Instant::now() + Duration::from_secs(10);
    let session = loop {
        let listing = host.json(&["status", "--json"]);
        if let Some(session) = listing["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|session| session["id"] == id.as_str())
        {
            break session.clone();
        }
        assert!(Instant::now() < deadline, "the session was not adopted");
        thread::sleep(Duration::from_millis(50));
    };
    assert_eq!(session["state"], "running");
    assert_eq!(session["pid"], created["pid"]);
    assert_eq!(session["holder_build"], OLD_BUILD);
    // Connecting again changes nothing: the daemon is that build now.
    assert!(handing_over(&host, Some(NEW_BUILD))
        .arg("list")
        .status()
        .unwrap()
        .success());
    assert_eq!(serving_daemons(&host.socket), now);
    host.end_sessions();
    assert!(host.command().arg("shutdown").status().unwrap().success());
}

#[test]
#[ignore = "requires a built cherry-host binary and permission to bind a socket and open PTYs"]
fn a_handover_the_old_build_wins_is_not_tried_again() {
    let mut host = Host::start_with(&[("CHERRY_HOST_TEST_BUILD", OLD_BUILD)]);
    let _daemons = Daemons(host.socket.clone());
    // The replacement comes back as the old build, as when a client of the
    // old build started the next daemon first.
    let listed = handing_over(&host, Some(OLD_BUILD))
        .arg("list")
        .output()
        .unwrap();
    assert!(
        listed.status.success(),
        "{}",
        String::from_utf8_lossy(&listed.stderr)
    );
    assert!(
        String::from_utf8_lossy(&listed.stderr).contains("not trying again for an hour"),
        "{}",
        String::from_utf8_lossy(&listed.stderr)
    );
    wait_for_exit(&mut host.child, "the daemon was not asked to make way");
    let after_first = serving_daemons(&host.socket);
    assert_eq!(after_first.len(), 1, "{after_first:?}");
    let status = host.json(&["status", "--json"]);
    assert_eq!(status["build"], OLD_BUILD);
    let record: serde_json::Value = serde_json::from_slice(
        &std::fs::read(
            PathBuf::from(status["host"]["state_dir"].as_str().unwrap()).join("handover.json"),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(record["from"], OLD_BUILD);
    assert_eq!(record["to"], NEW_BUILD);
    // Every later client of the new build leaves it alone: no loop.
    for command in [
        &["list"][..],
        &["list", "--json"],
        &["new", "--cwd", "/tmp", "--", "true"],
    ] {
        let output = handing_over(&host, Some(OLD_BUILD))
            .args(command)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(serving_daemons(&host.socket), after_first);
    }
    host.end_sessions();
    assert!(host.command().arg("shutdown").status().unwrap().success());
}

#[test]
#[ignore = "requires a built cherry-host binary and permission to bind a socket and open PTYs"]
fn a_client_never_replaces_a_newer_unordered_or_foreign_daemon() {
    for build in [
        "99990101000000.future0",
        "0.1.0-elsewhere",
        "dev-20000101000000.0ld0000",
    ] {
        let host = Host::start_with(&[("CHERRY_HOST_TEST_BUILD", build)]);
        let _daemons = Daemons(host.socket.clone());
        let listed = handing_over(&host, Some(NEW_BUILD))
            .arg("list")
            .output()
            .unwrap();
        assert!(listed.status.success());
        assert_eq!(serving_daemons(&host.socket), [host.child.id() as i32]);
        assert_eq!(host.json(&["status", "--json"])["build"], build);
    }
    // An older build of another installation (a copy of cherry-host that
    // is not the daemon's executable) is left alone too.
    let host = Host::start_with(&[("CHERRY_HOST_TEST_BUILD", OLD_BUILD)]);
    let _daemons = Daemons(host.socket.clone());
    let copy = host.home.join("cherry-host");
    std::fs::copy(host_binary(), &copy).unwrap();
    let listed = handing_over(&host, Some(NEW_BUILD))
        .env("CHERRY_HOST_PATH", &copy)
        .arg("list")
        .output()
        .unwrap();
    assert!(listed.status.success());
    assert_eq!(serving_daemons(&host.socket), [host.child.id() as i32]);
    // An attachment never hands over, even of its own installation.
    let created = host.json(&[
        "new",
        "--cwd",
        "/tmp",
        "--",
        "/bin/sh",
        "-c",
        "exec sleep 60",
    ]);
    let attached = handing_over(&host, Some(NEW_BUILD))
        .args(["attach", created["id"].as_str().unwrap()])
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(
        attached.status.success(),
        "{}",
        String::from_utf8_lossy(&attached.stderr)
    );
    assert_eq!(serving_daemons(&host.socket), [host.child.id() as i32]);
    assert_eq!(host.json(&["status", "--json"])["build"], OLD_BUILD);
}

#[test]
#[ignore = "requires a built cherry-host binary and permission to bind a socket and open PTYs"]
fn kitty_images_come_back_when_attaching_again_and_programs_see_pixels() {
    let host = Host::start();
    // Image 7 (one RGB pixel) placed at the cursor; image 9 (two pixels)
    // placed virtually, shown by two placeholder cells (U+10EEEE, row and
    // column diacritics, the image ID as the foreground colour). Then, for
    // each line, the PTY's size as the program sees it.
    let script = format!(
        r#"printf '\033_Ga=T,f=24,s=1,v=1,i=7,q=2;AQID\033\\\r\n'
printf '\033_Ga=T,U=1,f=24,s=2,v=1,i=9,c=2,r=1,q=2;AQIDBAUG\033\\'
printf '\033[38;5;9m\364\216\273\256\314\205\314\205\364\216\273\256\314\205\314\215\033[m\r\n'
printf 'READY\n'
while IFS= read -r line; do
  perl -e 'ioctl(STDIN, {}, my $w = "\0" x 8) or die "TIOCGWINSZ: $!"; printf("PIXELS:%d:%d:%d:%d\n", unpack("S4", $w))'
done"#,
        libc::TIOCGWINSZ
    );
    let created = host.json(&[
        "new", "--cwd", "/tmp", "--name", "Kitty", "--", "/bin/sh", "-c", &script,
    ]);
    let id = created["id"].as_str().unwrap();
    // A window of 10x21-pixel cells.
    let mut first = Attached::with_window(host.command_attach(id), 80, 24, (800, 504));
    first.expect(b"READY");
    first.master.write_all(b"size\n").unwrap();
    first.expect(b"PIXELS:24:80:800:504");
    first.master.write_all(&[0x1d]).unwrap();
    assert!(first.wait().success());
    host.wait_for_detached_running(id, &created["pid"]);

    let mut second = Attached::with_window(host.command_attach(id), 80, 24, (800, 504));
    second.expect(b"READY");
    // The images come after the snapshot's reset, quietly.
    second.expect(b"U=1,i=9");
    let received = String::from_utf8_lossy(&second.received).into_owned();
    let after = &received[received.rfind("\x1bc").expect("the snapshot's reset")..];
    let commands: Vec<&str> = after
        .split("\x1b_G")
        .skip(1)
        .map(|command| command.split([';', '\x1b']).next().unwrap())
        .collect();
    let has = |keys: &[&str]| {
        commands
            .iter()
            .any(|control| keys.iter().all(|key| control.split(',').any(|k| k == *key)))
    };
    assert!(has(&["a=t", "i=7", "q=2"]), "{commands:?}");
    assert!(has(&["a=p", "i=7", "q=2"]), "{commands:?}");
    assert!(has(&["a=t", "i=9", "q=2"]), "{commands:?}");
    assert!(has(&["a=p", "U=1", "i=9", "q=2"]), "{commands:?}");
    assert!(
        commands
            .iter()
            .all(|control| control.split(',').any(|key| key == "q=2")),
        "{commands:?}"
    );
    // The program still sees the window's pixels.
    let reports = |attached: &Attached| {
        String::from_utf8_lossy(&attached.received)
            .matches("PIXELS:24:80:800:504")
            .count()
    };
    let before = reports(&second);
    second.master.write_all(b"size\n").unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while reports(&second) == before {
        assert!(Instant::now() < deadline, "no second report");
        second.expect(b"PIXELS");
        thread::sleep(Duration::from_millis(20));
        let mut bytes = [0u8; 4096];
        if let Ok(n) = second.master.read(&mut bytes) {
            second.received.extend_from_slice(&bytes[..n]);
        }
    }
    second.master.write_all(&[0x1d]).unwrap();
    assert!(second.wait().success());
}

impl Attached {
    /// The terminal changes to `cols` by `rows`, and signals the attachment.
    fn resize(&self, cols: u16, rows: u16) {
        let size = libc::winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        assert_eq!(
            unsafe { libc::ioctl(self._slave.as_raw_fd(), libc::TIOCSWINSZ, &size) },
            0
        );
        assert_eq!(
            unsafe { libc::kill(self.child.id() as i32, libc::SIGWINCH) },
            0
        );
    }

    /// Keep reading the terminal for `duration`, as a terminal would.
    fn read_for(&mut self, duration: Duration) {
        let deadline = Instant::now() + duration;
        while Instant::now() < deadline {
            let mut bytes = [0u8; 16384];
            match self.master.read(&mut bytes) {
                Ok(n) => self.received.extend_from_slice(&bytes[..n]),
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(error) => panic!("PTY read failed: {error}"),
            }
            thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Host {
    /// The session's grid (columns, rows) and whether a client is attached.
    fn grid(&self, id: &str) -> ((u64, u64), bool) {
        let listing = self.json(&["list", "--json"]);
        let session = listing["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|session| session["id"] == id)
            .unwrap()
            .clone();
        (
            (
                session["cols"].as_u64().unwrap(),
                session["rows"].as_u64().unwrap(),
            ),
            session["attached"] == true,
        )
    }

    fn wait_for_grid(&self, id: &str, cols: u64, rows: u64, attached: &mut Attached) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while self.grid(id).0 != (cols, rows) {
            assert!(
                Instant::now() < deadline,
                "the session never took {cols}x{rows}: {:?}",
                self.grid(id)
            );
            attached.read_for(Duration::from_millis(20));
        }
    }
}

/// A program that appends each size its terminal is given to `log`, as
/// "ROWS COLS" (`stty size`), the first when it starts.
fn size_logger(log: &Path) -> String {
    format!(
        r#"trap 'stty size >> "{log}"' WINCH; stty size >> "{log}"; printf 'READY\n'; while :; do sleep 1 & wait $!; done"#,
        log = log.display()
    )
}

fn logged_sizes(log: &Path) -> Vec<String> {
    std::fs::read_to_string(log)
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect()
}

#[test]
#[ignore = "requires a built cherry-host binary and permission to bind a socket and open PTYs"]
fn an_attachment_with_a_size_file_passes_on_only_the_sizes_its_window_settled_at() {
    let host = Host::start();
    let directory = private_directory();
    let log = directory.path().join("sizes.log");
    let size_file = directory.path().join("size.json");
    let created = host.json(&[
        "new",
        "--cwd",
        "/tmp",
        "--name",
        "Settled",
        "--",
        "/bin/sh",
        "-c",
        &size_logger(&log),
    ]);
    let id = created["id"].as_str().unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while logged_sizes(&log).is_empty() {
        assert!(Instant::now() < deadline, "the program never started");
        thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(logged_sizes(&log), ["32 120"]);

    // The window settles at 100x30; its terminal is still at another size
    // (Ghostty's for a new surface), which the session never sees.
    std::fs::write(&size_file, br#"{"cols":100,"rows":30}"#).unwrap();
    let mut command = host.command_attach(id);
    command.arg("--size-file").arg(&size_file);
    let mut attached = Attached::with_command(command, 80, 24);
    attached.read_for(Duration::from_millis(400));
    assert_eq!(host.grid(id), ((120, 32), false), "it attached unsettled");
    attached.resize(100, 30);
    attached.expect(b"READY");
    host.wait_for_grid(id, 100, 30, &mut attached);

    // A full-screen transition: the window passes through sizes while the
    // file says hold, and the host hears only of the one it settles at.
    std::fs::write(&size_file, br#"{"hold":true}"#).unwrap();
    attached.resize(70, 20);
    attached.read_for(Duration::from_millis(150));
    attached.resize(140, 40);
    attached.read_for(Duration::from_millis(300));
    assert_eq!(host.grid(id), ((100, 30), true), "it resized while held");
    std::fs::write(&size_file, br#"{"cols":140,"rows":40}"#).unwrap();
    host.wait_for_grid(id, 140, 40, &mut attached);
    // Settled, it passes resizes on as they come.
    attached.resize(120, 36);
    host.wait_for_grid(id, 120, 36, &mut attached);
    attached.read_for(Duration::from_millis(200));
    assert_eq!(logged_sizes(&log), ["32 120", "30 100", "40 140", "36 120"]);
    attached.master.write_all(&[0x1d]).unwrap();
    assert!(attached.wait().success());
}

#[test]
#[ignore = "requires a built cherry-host binary and permission to bind a socket and open PTYs"]
fn a_size_file_that_never_names_the_window_holds_it_back_only_so_long() {
    let host = Host::start();
    let directory = private_directory();
    let log = directory.path().join("sizes.log");
    let size_file = directory.path().join("size.json");
    let created = host.json(&[
        "new",
        "--cwd",
        "/tmp",
        "--name",
        "Unsettled",
        "--",
        "/bin/sh",
        "-c",
        &size_logger(&log),
    ]);
    let id = created["id"].as_str().unwrap();
    // No file at all: the attachment waits for it, then attaches at its
    // terminal's size.
    let mut command = host.command_attach(id);
    command
        .arg("--size-file")
        .arg(&size_file)
        .env("CHERRY_CLI_SIZE_FILE_WAIT_MS", "300");
    let started = Instant::now();
    let mut attached = Attached::with_command(command, 80, 24);
    attached.expect(b"READY");
    host.wait_for_grid(id, 80, 24, &mut attached);
    assert!(started.elapsed() >= Duration::from_millis(300));
    // A hold the app never ends holds one resize back for as long, and
    // none after it.
    std::fs::write(&size_file, br#"{"hold":true}"#).unwrap();
    attached.resize(100, 30);
    attached.read_for(Duration::from_millis(100));
    assert_eq!(host.grid(id).0, (80, 24));
    host.wait_for_grid(id, 100, 30, &mut attached);
    attached.resize(90, 28);
    host.wait_for_grid(id, 90, 28, &mut attached);
    attached.master.write_all(&[0x1d]).unwrap();
    assert!(attached.wait().success());
}
