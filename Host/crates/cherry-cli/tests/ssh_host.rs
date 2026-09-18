//! Real SSH acceptance test against an explicitly configured disposable host.
//! The server must have cherry-host on its SSH PATH and Neovim installed.
//! CHERRY_TEST_SSH_HOST=alias CHERRY_TEST_SSH_CONFIG=/tmp/config
//! cargo test -p cherry-cli --test ssh_host -- --ignored
//! Optional CHERRY_TEST_SSH_SOCKET selects an isolated remote socket directory.
use std::{
    fs::File,
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::fs::PermissionsExt,
    },
    path::PathBuf,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

struct RemoteHost {
    wrapper: tempfile::TempDir,
    alias: String,
    config: PathBuf,
    socket: Option<String>,
    host_id: Option<String>,
    sessions: Vec<String>,
}

impl RemoteHost {
    fn new() -> Self {
        let alias = std::env::var("CHERRY_TEST_SSH_HOST")
            .expect("set CHERRY_TEST_SSH_HOST to a disposable test SSH host alias");
        let config = PathBuf::from(
            std::env::var_os("CHERRY_TEST_SSH_CONFIG")
                .expect("set CHERRY_TEST_SSH_CONFIG to a test SSH config"),
        );
        assert!(config.is_file());
        let wrapper = tempfile::tempdir().unwrap();
        let ssh = wrapper.path().join("ssh");
        // This only chooses an isolated configuration. Transport and crypto use
        // the real system SSH binary, including the configured known-host check.
        std::fs::write(
            &ssh,
            "#!/bin/sh\nexec /usr/bin/ssh -F \"$CHERRY_TEST_SSH_CONFIG\" \"$@\"\n",
        )
        .unwrap();
        std::fs::set_permissions(ssh, std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut host = Self {
            wrapper,
            alias,
            config,
            socket: std::env::var("CHERRY_TEST_SSH_SOCKET").ok(),
            host_id: None,
            sessions: Vec::new(),
        };
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
        command.arg("--host").arg(&self.alias);
        if let Some(socket) = &self.socket {
            command.arg("--socket").arg(socket);
        }
        if let Some(id) = &self.host_id {
            command.arg("--expected-host-id").arg(id);
        }
        let mut path = vec![self.wrapper.path().to_path_buf()];
        path.extend(std::env::split_paths(
            &std::env::var_os("PATH").unwrap_or_default(),
        ));
        command
            .env("PATH", std::env::join_paths(path).unwrap())
            .env("CHERRY_TEST_SSH_CONFIG", &self.config);
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

    fn create(&mut self, name: &str, command: &[&str]) -> serde_json::Value {
        let mut args = vec!["new", "--cwd", "/tmp", "--name", name, "--"];
        args.extend(command);
        let created = self.json(&args);
        self.sessions
            .push(created["id"].as_str().unwrap().to_owned());
        created
    }

    fn wait_for(&self, id: &str, predicate: impl Fn(&serde_json::Value) -> bool) {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let listing = self.json(&["list", "--json"]);
            let session = listing["sessions"]
                .as_array()
                .unwrap()
                .iter()
                .find(|session| session["id"] == id)
                .unwrap();
            if predicate(session) {
                return;
            }
            assert!(
                Instant::now() < deadline,
                "unexpected session state: {session}"
            );
            thread::sleep(Duration::from_millis(50));
        }
    }

    fn kill_and_remove(&mut self, id: &str) {
        let killed = self.command().args(["kill", id]).output().unwrap();
        assert!(
            killed.status.success(),
            "{}",
            String::from_utf8_lossy(&killed.stderr)
        );
        self.wait_for(id, |session| session["state"] == "exited");
        let removed = self.command().args(["remove", id]).output().unwrap();
        assert!(
            removed.status.success(),
            "{}",
            String::from_utf8_lossy(&removed.stderr)
        );
        self.sessions.retain(|session| session != id);
    }
}

impl Drop for RemoteHost {
    fn drop(&mut self) {
        // Clean up only the sessions created by this test, never unrelated work.
        for id in &self.sessions {
            let _ = self
                .command()
                .args(["kill", id])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        }
    }
}

struct Attached {
    master: File,
    _slave: File,
    child: Child,
    received: Vec<u8>,
}

impl Attached {
    fn new(host: &RemoteHost, id: &str, cols: u16, rows: u16) -> Self {
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
        let child = host
            .command()
            .args(["attach", id])
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

    fn send(&mut self, bytes: &[u8]) {
        self.master.write_all(bytes).unwrap();
    }

    fn expect(&mut self, needle: &[u8]) {
        let deadline = Instant::now() + Duration::from_secs(15);
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
            // A real terminal continues reading while its adapter exits. A
            // shared resize can repaint several full frames, so leaving this
            // PTY unread would block output before the detach key is handled.
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

    fn disconnect(&mut self) {
        assert_eq!(
            unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) },
            0
        );
        assert_eq!(self.wait().code(), Some(128 + libc::SIGTERM));
    }
}

impl Drop for Attached {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
#[ignore = "requires explicit disposable SSH host, known-host configuration, cherry-host and Neovim"]
fn real_ssh_shell_and_neovim_survive_disconnect_reconnect_and_resize() {
    let mut host = RemoteHost::new();
    let shell = host.create("SSH shell smoke", &["/bin/sh", "-c", "printf 'SSH_READY\\n'; while IFS= read -r line; do printf 'SSH_OUT:%s\\n' \"$line\"; done"]);
    let id = shell["id"].as_str().unwrap();
    let mut first = Attached::new(&host, id, 80, 24);
    first.expect(b"SSH_READY");
    first.send(b"before-disconnect\n");
    first.expect(b"SSH_OUT:before-disconnect");
    first.disconnect();
    host.wait_for(id, |session| {
        session["state"] == "running"
            && session["attached"] == false
            && session["pid"] == shell["pid"]
    });
    let mut second = Attached::new(&host, id, 100, 40);
    second.expect(b"SSH_OUT:before-disconnect");
    second.send(b"after-reconnect\n");
    second.expect(b"SSH_OUT:after-reconnect");
    let mut shared = Attached::new(&host, id, 80, 20);
    shared.expect(b"SSH_OUT:after-reconnect");
    shared.send(b"from-shared-device\n");
    second.expect(b"SSH_OUT:from-shared-device");
    shared.expect(b"SSH_OUT:from-shared-device");
    second.send(b"from-original-device\n");
    shared.expect(b"SSH_OUT:from-original-device");
    second.expect(b"SSH_OUT:from-original-device");
    shared.send(&[0x1d]);
    assert!(shared.wait().success());
    second.send(b"after-other-device-left\n");
    second.expect(b"SSH_OUT:after-other-device-left");
    second.send(&[0x1d]);
    assert!(second.wait().success());
    host.kill_and_remove(id);

    let editor = host.create("SSH Neovim smoke", &["nvim", "--clean", "-n"]);
    let id = editor["id"].as_str().unwrap();
    let mut first = Attached::new(&host, id, 80, 24);
    first.expect(b"NVIM");
    first.send(b"iREMOTE_NEOVIM_STATE\x1b");
    first.expect(b"REMOTE_NEOVIM_STATE");
    first.disconnect();
    host.wait_for(id, |session| {
        session["state"] == "running"
            && session["attached"] == false
            && session["pid"] == editor["pid"]
    });
    let mut second = Attached::new(&host, id, 110, 35);
    second.expect(b"REMOTE_NEOVIM_STATE");
    second.send(b"A_AND_CONTINUED\x1b");
    second.expect(b"_AND_CONTINUED");
    let mut shared = Attached::new(&host, id, 80, 24);
    shared.expect(b"REMOTE_NEOVIM_STATE_AND_CONTINUED");
    shared.send(b"A_SHARED\x1b");
    second.expect(b"_SHARED");
    shared.expect(b"_SHARED");
    second.send(b"A_BOTH_TYPE\x1b");
    second.expect(b"_BOTH_TYPE");
    shared.expect(b"_BOTH_TYPE");
    shared.send(&[0x1d]);
    assert!(shared.wait().success());
    second.send(&[0x1d]);
    assert!(second.wait().success());
    host.kill_and_remove(id);
}
