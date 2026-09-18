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

struct Host {
    _directory: tempfile::TempDir,
    socket: PathBuf,
    child: Child,
    host_id: Option<String>,
}

impl Host {
    fn start() -> Self {
        let directory = tempfile::tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let socket = directory.path().join("host.sock");
        let host_binary = std::env::var_os("CHERRY_TEST_HOST")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                Path::new(env!("CARGO_BIN_EXE_cherry")).with_file_name("cherry-host")
            });
        let child = Command::new(host_binary)
            .arg("serve")
            .arg("--socket")
            .arg(&socket)
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
