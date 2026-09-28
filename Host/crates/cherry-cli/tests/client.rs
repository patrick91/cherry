//! The CLI against scripted fake hosts (and a fake ssh), without a daemon.
use cherry_protocol::{
    encode_frame, read_frame, write_frame, AttachReason, ClientMessage, Request, Response,
    ServerMessage, SessionEvent, SessionInfo, SessionState, DEFAULT_COLS, DEFAULT_ROWS,
    PROTOCOL_VERSION,
};
use std::{
    fs::File,
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            fs::PermissionsExt,
            net::{UnixListener, UnixStream},
            process::CommandExt,
        },
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        atomic::{AtomicUsize, Ordering},
        mpsc, Arc,
    },
    thread,
    time::{Duration, Instant},
};

fn session() -> SessionInfo {
    sized_session(120, 32)
}

/// Built from JSON, so that fields a newer protocol adds take their
/// defaults.
fn sized_session(cols: u16, rows: u16) -> SessionInfo {
    serde_json::from_value(serde_json::json!({
        "id": "test-session",
        "name": "Example",
        "cwd": "/work",
        "command": ["/bin/sh"],
        "cols": cols,
        "rows": rows,
        "state": SessionState::Running,
        "pid": 42,
        "exit_code": null,
        "attached": true,
        "exit_signal": null,
        "clients": 1,
    }))
    .unwrap()
}

/// A session list, built from JSON like `sized_session`.
fn sessions_reply(host_id: &str, sessions: Vec<SessionInfo>) -> ServerMessage {
    serde_json::from_value(serde_json::json!({
        "type": "sessions",
        "host_id": host_id,
        "sessions": sessions,
    }))
    .unwrap()
}

/// A private directory, as the CLI requires for a host socket.
fn private_directory() -> tempfile::TempDir {
    let directory = tempfile::tempdir().unwrap();
    std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    directory
}

fn listener() -> (tempfile::TempDir, UnixListener, Command) {
    let directory = private_directory();
    let socket = directory.path().join("host.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    let mut command = Command::new(env!("CARGO_BIN_EXE_cherry"));
    command.args(["--socket", socket.to_str().unwrap()]);
    // Never start a real daemon from these tests.
    command.env("CHERRY_HOST_PATH", "/nonexistent/cherry-host");
    command.env_remove("CHERRY_SESSION_ID");
    command.env_remove("SSH_AUTH_SOCK");
    // Fake terminals do not answer the query written when leaving a session
    // that enabled reports; tests that answer it set their own wait.
    command.env("CHERRY_CLI_REPORT_WAIT_MS", "200");
    // A lost connection ends the attachment at once, as it did before
    // attachments connected again; the reconnection tests set their own.
    command.env("CHERRY_CLI_RECONNECT_WINDOW_MS", "0");
    (directory, listener, command)
}

fn accept_raw(listener: UnixListener) -> UnixStream {
    let deadline = Instant::now() + Duration::from_secs(5);
    let stream = loop {
        match listener.accept() {
            Ok((stream, _)) => break stream,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                assert!(Instant::now() < deadline, "client did not connect");
                thread::sleep(Duration::from_millis(5));
            }
            Err(error) => panic!("accept failed: {error}"),
        }
    };
    stream.set_nonblocking(false).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    stream
}

fn accept(listener: UnixListener) -> UnixStream {
    let mut stream = accept_raw(listener);
    assert!(matches!(
        read_frame(&mut stream).unwrap(),
        Some(ClientMessage::Hello {
            version: PROTOCOL_VERSION
        })
    ));
    write_frame(
        &mut stream,
        &ServerMessage::Welcome {
            version: PROTOCOL_VERSION,
            host_id: "host-1".into(),
            build: None,
        },
    )
    .unwrap();
    stream
}

/// Accept, expect an Attach and reply with a snapshot.
fn accept_attach(listener: UnixListener, info: SessionInfo, snapshot: &[u8]) -> UnixStream {
    let mut stream = accept(listener);
    assert!(matches!(
        read_frame(&mut stream).unwrap(),
        Some(ClientMessage::Attach { id, .. }) if id == "test-session"
    ));
    write_frame(
        &mut stream,
        &ServerMessage::Attached {
            reason: AttachReason::Attach,
            session: info,
            offset: 0,
            snapshot: snapshot.to_vec(),
            refreshes: false,
        },
    )
    .unwrap();
    stream
}

fn read_client(stream: &mut UnixStream) -> Option<ClientMessage> {
    read_frame(stream).unwrap()
}

fn wait(child: &mut Child) -> std::process::ExitStatus {
    wait_within(child, Duration::from_secs(5))
}

fn wait_within(child: &mut Child, limit: Duration) -> std::process::ExitStatus {
    let deadline = Instant::now() + limit;
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("client did not exit within {limit:?}");
        }
        thread::sleep(Duration::from_millis(10));
    }
}

fn stderr_of(child: &mut Child) -> String {
    let mut error = String::new();
    child
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut error)
        .unwrap();
    error
}

fn read_status(path: &Path) -> serde_json::Value {
    serde_json::from_slice(&std::fs::read(path).expect("status file written")).unwrap()
}

/// Collects a child's stdout on a thread so tests can wait for markers.
struct Collected {
    received: Vec<u8>,
    chunks: mpsc::Receiver<Vec<u8>>,
}

impl Collected {
    fn new(mut stdout: impl Read + Send + 'static) -> Self {
        let (tx, chunks) = mpsc::channel();
        thread::spawn(move || {
            let mut buffer = [0u8; 65536];
            while let Ok(n) = stdout.read(&mut buffer) {
                if n == 0 || tx.send(buffer[..n].to_vec()).is_err() {
                    break;
                }
            }
        });
        Self {
            received: Vec::new(),
            chunks,
        }
    }

    fn expect(&mut self, needle: &[u8]) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !contains(&self.received, needle) {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.chunks.recv_timeout(left) {
                Ok(chunk) => self.received.extend_from_slice(&chunk),
                Err(_) => panic!(
                    "missing {:?} in {:?}",
                    String::from_utf8_lossy(needle),
                    String::from_utf8_lossy(&self.received)
                ),
            }
        }
    }

    /// Everything up to the end of the output.
    fn all(mut self) -> Vec<u8> {
        loop {
            match self.chunks.recv_timeout(Duration::from_secs(10)) {
                Ok(chunk) => self.received.extend_from_slice(&chunk),
                Err(mpsc::RecvTimeoutError::Disconnected) => return self.received,
                Err(mpsc::RecvTimeoutError::Timeout) => panic!("output did not end"),
            }
        }
    }
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|bytes| bytes == needle)
}

/// An executable shell script.
fn script(path: &Path, body: &str) {
    std::fs::write(path, format!("#!/bin/sh\n{body}")).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
}

#[test]
fn list_json_has_host_identity_and_plain_session_descriptors() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::List)
        ));
        write_frame(&mut stream, &sessions_reply("host-1", vec![session()])).unwrap();
    });
    let result = command.args(["list", "--json"]).output().unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    let value: serde_json::Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(value["host_id"], "host-1");
    assert_eq!(value["sessions"][0]["attached"], true);
    assert_eq!(value["sessions"][0]["state"], "running");
    server.join().unwrap();
}

#[test]
fn create_preserves_request_id_and_command_without_shell_interpolation() {
    let (_directory, listener, mut command) = listener();
    let request_id = "12345678-1234-4234-8234-123456789abc";
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        match read_client(&mut stream).unwrap() {
            ClientMessage::Create {
                request_id: id,
                cwd,
                command,
                name,
                ..
            } => {
                assert_eq!(id, request_id);
                assert_eq!(cwd, "/work/space ' literal");
                assert_eq!(name, "-dev");
                assert_eq!(command, ["printf", "%s", "$(not-a-shell)"]);
            }
            other => panic!("wrong request: {other:?}"),
        }
        write_frame(&mut stream, &ServerMessage::Created { session: session() }).unwrap();
    });
    let result = command
        .args([
            "new",
            "--cwd=/work/space ' literal",
            "--name=-dev",
            "--request-id",
            request_id,
            "--",
            "printf",
            "%s",
            "$(not-a-shell)",
        ])
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    let value: serde_json::Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(value["id"], "test-session");
    assert_eq!(value["state"], "running");
    assert!(
        value.get("session").is_none(),
        "new should return a plain descriptor"
    );
    server.join().unwrap();
}

#[test]
fn create_sends_locale_and_a_fixed_size_so_retries_are_identical() {
    let (_directory, listener, mut command) = listener();
    let (tx, rx) = mpsc::channel();
    let server = thread::spawn(move || {
        for _ in 0..2 {
            let listener = listener.try_clone().unwrap();
            let mut stream = accept(listener);
            let request = read_client(&mut stream).unwrap();
            tx.send(serde_json::to_value(&request).unwrap()).unwrap();
            write_frame(&mut stream, &ServerMessage::Created { session: session() }).unwrap();
        }
    });
    let arguments = [
        "new",
        "--cwd=~/project",
        "--name=Work",
        "--request-id",
        "12345678-1234-4234-8234-123456789abc",
    ];
    command
        .env("LANG", "it_IT.UTF-8")
        .env("LC_CTYPE", "UTF-8")
        .env("TZ", "Europe/Rome")
        .env("UNRELATED", "x");
    // The first attempt from an 80x24 terminal, the retry without a terminal.
    let pty = Pty::open(80, 24);
    let first = command
        .args(arguments)
        .stdin(pty.slave.try_clone().unwrap())
        .output()
        .unwrap();
    assert!(
        first.status.success(),
        "{}",
        String::from_utf8_lossy(&first.stderr)
    );
    let retry = command.stdin(Stdio::null()).output().unwrap();
    assert!(
        retry.status.success(),
        "{}",
        String::from_utf8_lossy(&retry.stderr)
    );
    let first = rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let retry = rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(first, retry, "a retry must repeat the same request");
    assert_eq!(first["cols"], DEFAULT_COLS);
    assert_eq!(first["rows"], DEFAULT_ROWS);
    assert_eq!(first["cwd"], "~/project");
    let environment = first["env"].as_object().unwrap();
    assert_eq!(environment["LANG"], "it_IT.UTF-8");
    assert_eq!(environment["LC_CTYPE"], "UTF-8");
    assert_eq!(environment["TZ"], "Europe/Rome");
    assert!(!environment.contains_key("UNRELATED"));
    assert!(!environment.contains_key("PATH"));
    server.join().unwrap();
}

#[test]
fn detach_escape_is_local_and_preserves_prior_input() {
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, session(), b"screen");
        assert!(
            matches!(read_client(&mut stream), Some(ClientMessage::Input { data }) if data == b"hello")
        );
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Detach)
        ));
        write_frame(&mut stream, &ServerMessage::Ok).unwrap();
    });
    let mut child = command
        .args(["attach", "test-session", "--status-file"])
        .arg(&status)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(b"hello\x1dnot-sent")
        .unwrap();
    assert!(wait(&mut child).success());
    let mut output = Vec::new();
    child
        .stdout
        .take()
        .unwrap()
        .read_to_end(&mut output)
        .unwrap();
    assert!(output.starts_with(b"screen"));
    server.join().unwrap();
    let status = read_status(&status);
    assert_eq!(status["outcome"], "detached");
    assert!(status["exit_code"].is_null() && status["message"].is_null());
}

#[test]
fn pressing_the_detach_key_twice_sends_it_to_the_session() {
    let (_directory, listener, mut command) = listener();
    let (literal_tx, literal_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, session(), b"");
        assert!(
            matches!(read_client(&mut stream), Some(ClientMessage::Input { data }) if data == [0x1d])
        );
        literal_tx.send(()).unwrap();
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Detach)
        ));
    });
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(&[0x1d, 0x1d]).unwrap();
    literal_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    stdin.write_all(&[0x1d]).unwrap();
    assert!(wait(&mut child).success());
    server.join().unwrap();
}

#[test]
fn detach_key_none_forwards_every_byte_and_detaches_only_at_end_of_input() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, session(), b"");
        let mut forwarded = Vec::new();
        loop {
            match read_client(&mut stream) {
                Some(ClientMessage::Input { data }) => forwarded.extend(data),
                Some(ClientMessage::Detach) => break,
                other => panic!("unexpected {other:?}"),
            }
        }
        assert_eq!(forwarded, b"a\x1db\x1b[93;5u\x1b");
    });
    let mut child = command
        .args(["attach", "test-session", "--detach-key", "none"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(b"a\x1db\x1b[93;5u\x1b").unwrap();
    // No detach, no matter how long the key has been held back.
    thread::sleep(Duration::from_millis(600));
    assert!(
        child.try_wait().unwrap().is_none(),
        "detached without a key"
    );
    drop(stdin);
    assert!(wait(&mut child).success());
    server.join().unwrap();
}

#[test]
fn detach_waits_until_the_host_accepted_the_input_sent_before_it() {
    let (_directory, listener, mut command) = listener();
    let (ok_tx, ok_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, session(), b"");
        assert!(
            matches!(read_client(&mut stream), Some(ClientMessage::Input { data }) if data == b"make test\n")
        );
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Detach)
        ));
        // The host acknowledges after queueing the input for the program.
        thread::sleep(Duration::from_millis(300));
        ok_tx.send(Instant::now()).unwrap();
        write_frame(&mut stream, &ServerMessage::Ok).unwrap();
        thread::sleep(Duration::from_secs(3));
    });
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(b"make test\n").unwrap();
    drop(stdin);
    assert!(wait(&mut child).success());
    let exited = Instant::now();
    let acknowledged = ok_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("exited before Ok");
    assert!(exited >= acknowledged);
    assert!(
        exited - acknowledged < Duration::from_secs(2),
        "waited past Ok"
    );
    server.join().unwrap();
}

#[test]
fn a_keyboard_detach_does_not_wait_for_an_unresponsive_host() {
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let (done_tx, done_rx) = mpsc::channel::<()>();
    let server = thread::spawn(move || {
        let stream = accept_attach(listener, session(), b"");
        // Never read again or answer Detach, but keep the connection open.
        let _ = done_rx.recv_timeout(Duration::from_secs(20));
        drop(stream);
    });
    let mut child = command
        .args(["attach", "test-session", "--status-file"])
        .arg(&status)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let started = Instant::now();
    child.stdin.as_mut().unwrap().write_all(b"\x1d").unwrap();
    assert!(wait(&mut child).success());
    assert!(
        started.elapsed() < Duration::from_secs(4),
        "{:?}",
        started.elapsed()
    );
    let error = stderr_of(&mut child);
    assert!(
        error.contains("without the host's confirmation after 2 s"),
        "{error}"
    );
    let status = read_status(&status);
    assert_eq!(status["outcome"], "detached");
    assert!(status["message"].as_str().unwrap().contains("discarded"));
    done_tx.send(()).unwrap();
    server.join().unwrap();
}

#[test]
fn a_detach_behind_input_the_host_never_reads_gives_up_after_the_detach_wait() {
    // More than the socket buffers hold, less than the client's own limit,
    // so the client reaches end of input and queues Detach behind it.
    const PASTE: usize = 512 * 1024;
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let (done_tx, done_rx) = mpsc::channel::<()>();
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, session(), b"");
        // The program prints but never reads its input, so the host never
        // reads this connection again: neither the paste nor the Detach.
        let mut offset = 0;
        while let Err(mpsc::RecvTimeoutError::Timeout) =
            done_rx.recv_timeout(Duration::from_millis(50))
        {
            let data = b"tick ".to_vec();
            let len = data.len() as u64;
            if write_frame(&mut stream, &ServerMessage::Output { offset, data }).is_err() {
                break;
            }
            offset += len;
        }
    });
    let mut child = command
        .args(["attach", "test-session", "--status-file"])
        .arg(&status)
        .env("CHERRY_CLI_DETACH_WAIT_MS", "1000")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut output = Collected::new(child.stdout.take().unwrap());
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(&vec![b'x'; PASTE]).unwrap();
    drop(stdin);
    let ended = Instant::now();
    // Output keeps arriving while the client waits for the host's Ok.
    output.expect(b"tick tick");
    assert!(
        wait_within(&mut child, Duration::from_secs(10)).success(),
        "{}",
        stderr_of(&mut child)
    );
    let waited = ended.elapsed();
    assert!(waited >= Duration::from_millis(1000), "{waited:?}");
    assert!(waited < Duration::from_secs(5), "{waited:?}");
    let error = stderr_of(&mut child);
    assert!(
        error.contains("without the host's confirmation after 1 s without progress"),
        "{error}"
    );
    assert!(
        error.contains("input not yet delivered to the session was discarded"),
        "{error}"
    );
    let status = read_status(&status);
    assert_eq!(status["outcome"], "detached");
    assert!(status["exit_code"].is_null());
    assert!(status["message"].as_str().unwrap().contains("discarded"));
    // The host may already have noticed that the client left.
    let _ = done_tx.send(());
    server.join().unwrap();
}

/// The paste used by the detach tests: a..z repeated.
fn alphabet(len: usize) -> Vec<u8> {
    (0..len).map(|i| b'a' + (i % 26) as u8).collect()
}

/// A host reading the paste at 64 KiB per 160 ms (about 400 KB/s), counted
/// in bytes rather than frames: how the client frames the paste is not the
/// test's to pick. Each Input holds what one read of the client's standard
/// input returned, and a pipe may hold only 8 KiB (Linux gives new pipes two
/// pages while the user's pipes hold more than fs.pipe-user-pages-soft, as
/// for root in a container on a busy Docker host).
struct Pace {
    started: Option<Instant>,
    read: u64,
}

impl Pace {
    fn new() -> Self {
        Self {
            started: None,
            read: 0,
        }
    }

    /// Returns once `len` more bytes have taken their share of the time.
    fn read(&mut self, len: usize) {
        let started = *self.started.get_or_insert_with(Instant::now);
        self.read += len as u64;
        let due = started + Duration::from_micros(self.read * 160_000 / (64 * 1024));
        if let Some(left) = due.checked_duration_since(Instant::now()) {
            thread::sleep(left);
        }
    }
}

/// Whether the client has handed the connection everything up to its
/// Detach: the bytes waiting in `stream` end with it (nothing follows a
/// Detach). `buffer` must be larger than what a connection holds.
fn holds_the_detach(stream: &UnixStream, buffer: &mut [u8]) -> bool {
    let detach = encode_frame(&ClientMessage::Detach).unwrap();
    let n = unsafe {
        libc::recv(
            stream.as_raw_fd(),
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            libc::MSG_PEEK | libc::MSG_DONTWAIT,
        )
    };
    n > 0 && buffer[..n as usize].ends_with(&detach)
}

/// Run `attach` with `paste` on its standard input, then end of input.
fn attach_with_paste(mut command: Command, status: &Path, paste: Vec<u8>) -> Child {
    let mut child = command
        .args(["attach", "test-session", "--detach-key", "none"])
        .arg("--status-file")
        .arg(status)
        .env("CHERRY_CLI_DETACH_WAIT_MS", "1000")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    thread::spawn(move || {
        let _ = stdin.write_all(&paste);
    });
    child
}

/// The paste bytes at `range` of an endless a..z sequence.
fn letters(range: std::ops::Range<usize>) -> Vec<u8> {
    range.map(|i| b'a' + (i % 26) as u8).collect()
}

/// A pipe for a client's standard input, with a second descriptor for its
/// read end that tells how much of it the client has not read.
struct InputPipe {
    write: File,
    read: Option<File>,
    unread: File,
}

impl InputPipe {
    fn new() -> Self {
        let mut fds = [0; 2];
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        for fd in fds {
            // Only the client gets the read end, as its standard input.
            unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
        }
        let read = unsafe { File::from_raw_fd(fds[0]) };
        Self {
            write: unsafe { File::from_raw_fd(fds[1]) },
            unread: read.try_clone().unwrap(),
            read: Some(read),
        }
    }

    fn stdin(&mut self) -> Stdio {
        Stdio::from(self.read.take().unwrap())
    }

    fn unread(&self) -> usize {
        let mut n: libc::c_int = 0;
        assert_eq!(
            unsafe { libc::ioctl(self.unread.as_raw_fd(), libc::FIONREAD, &mut n) },
            0
        );
        n as usize
    }

    /// Write `bytes` and wait up to `limit` for the client to read them all;
    /// false if it did not.
    fn feed(&mut self, bytes: &[u8], limit: Duration) -> bool {
        self.write.write_all(bytes).unwrap();
        let deadline = Instant::now() + limit;
        while self.unread() > 0 {
            if Instant::now() >= deadline {
                return false;
            }
            thread::sleep(Duration::from_millis(1));
        }
        true
    }
}

/// The input the client has handed to the connection so far: that of the
/// whole frames waiting in `stream`, which the host has not read.
fn input_in_connection(stream: &UnixStream) -> usize {
    let mut n: libc::c_int = 0;
    assert_eq!(
        unsafe { libc::ioctl(stream.as_raw_fd(), libc::FIONREAD, &mut n) },
        0
    );
    let mut buffer = vec![0u8; n as usize];
    let n = unsafe {
        libc::recv(
            stream.as_raw_fd(),
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            libc::MSG_PEEK | libc::MSG_DONTWAIT,
        )
    };
    let mut waiting = &buffer[..n.max(0) as usize];
    let mut input = 0;
    while let Ok(Some(message)) = read_frame::<_, ClientMessage>(&mut waiting) {
        if let ClientMessage::Input { data } = message {
            input += data.len();
        }
    }
    input
}

/// The limit on input a client queues for the host in these tests
/// (`CHERRY_CLI_INPUT_HIGH_WATER`), and how much more it reads while that
/// is full, so the detach key typed behind is seen.
const SMALL_INPUT_HIGH_WATER: usize = 64 * 1024;
const INPUT_OVERFLOW: usize = 64 * 1024;

/// Paste into `pipe` a chunk at a time, each read by the client before the
/// next, until the client holds more input than it could below its limit
/// (queued input takes at least its size in frames, and a chunk read below
/// the limit may take it past it), with a host that takes none. Returns how
/// much was pasted.
fn paste_past_the_limit(pipe: &mut InputPipe, host: &UnixStream) -> usize {
    const CHUNK: usize = 4096;
    let beyond = SMALL_INPUT_HIGH_WATER + CHUNK + INPUT_OVERFLOW / 2;
    let mut pasted = 0;
    let mut handed_over = 0;
    loop {
        assert!(
            pipe.feed(&letters(pasted..pasted + CHUNK), Duration::from_secs(10)),
            "the client stopped reading its input holding {} bytes",
            pasted - input_in_connection(host)
        );
        pasted += CHUNK;
        // What the connection holds only grows: look again only when what
        // it held last would leave enough with the client.
        if pasted - handed_over > beyond {
            handed_over = input_in_connection(host);
            if pasted - handed_over > beyond {
                return pasted;
            }
        }
    }
}

#[test]
fn the_detach_key_is_seen_while_the_host_takes_no_input() {
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let mut pipe = InputPipe::new();
    let mut child = Reaped(
        command
            .args(["attach", "test-session", "--status-file"])
            .arg(&status)
            .env(
                "CHERRY_CLI_INPUT_HIGH_WATER",
                SMALL_INPUT_HIGH_WATER.to_string(),
            )
            .stdin(pipe.stdin())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap(),
    );
    // The program is not reading its input, so the host reads nothing more
    // from this connection.
    let mut host = accept_attach(listener, session(), b"");
    let pasted = paste_past_the_limit(&mut pipe, &host);
    // The detach key, behind all that.
    assert!(
        pipe.feed(b"\x1d", Duration::from_secs(10)),
        "the detach key was not read"
    );
    let pressed = Instant::now();
    assert!(wait_within(&mut child.0, Duration::from_secs(10)).success());
    assert!(pressed.elapsed() < Duration::from_secs(8));
    let error = stderr_of(&mut child.0);
    assert!(
        error.contains("without the host's confirmation after 2 s"),
        "{error}"
    );
    let status = read_status(&status);
    assert_eq!(status["outcome"], "detached");
    assert!(status["message"].as_str().unwrap().contains("discarded"));
    // What the host got of the input came in order, without the key. (The
    // connection keeps its read timeout: macOS refuses to change it once the
    // client has closed its end.)
    let mut received = Vec::new();
    while let Ok(Some(message)) = read_frame::<_, ClientMessage>(&mut host) {
        if let ClientMessage::Input { data } = message {
            received.extend(data);
        }
    }
    assert!(received.len() <= pasted);
    assert_eq!(received, letters(0..received.len()));
}

#[test]
fn input_read_while_the_host_takes_none_is_bounded_and_kept_in_order() {
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let mut pipe = InputPipe::new();
    let mut child = Reaped(
        command
            .args(["attach", "test-session", "--status-file"])
            .arg(&status)
            .env(
                "CHERRY_CLI_INPUT_HIGH_WATER",
                SMALL_INPUT_HIGH_WATER.to_string(),
            )
            .stdin(pipe.stdin())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap(),
    );
    let mut host = accept_attach(listener, session(), b"");
    let mut pasted = paste_past_the_limit(&mut pipe, &host);
    // The detach key twice sends it, in its place.
    assert!(pipe.feed(b"\x1d\x1d", Duration::from_secs(10)));
    let mut expected = letters(0..pasted);
    expected.push(0x1d);
    // The client stops reading once it holds its limit and the overflow.
    // Declaring it stopped too early only makes the bound easier to meet.
    const CHUNK: usize = 1024;
    let give_up = pasted + 4 * (SMALL_INPUT_HIGH_WATER + INPUT_OVERFLOW);
    loop {
        let chunk = letters(pasted..pasted + CHUNK);
        expected.extend_from_slice(&chunk);
        pasted += CHUNK;
        if !pipe.feed(&chunk, Duration::from_secs(1)) || pasted >= give_up {
            break;
        }
    }
    let held = pasted - pipe.unread() - input_in_connection(&host);
    assert!(
        held < SMALL_INPUT_HIGH_WATER + INPUT_OVERFLOW + 16 * 1024,
        "the client read {held} bytes of input it could not send"
    );
    // The host takes the input now; the rest of the paste follows, then
    // end of input, which detaches once everything was delivered.
    let reader = thread::spawn(move || {
        host.set_read_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        let mut received = Vec::new();
        loop {
            match read_client(&mut host) {
                Some(ClientMessage::Input { data }) => received.extend(data),
                Some(ClientMessage::Ping) => {}
                Some(ClientMessage::Detach) => break,
                other => panic!("unexpected {other:?}"),
            }
        }
        write_frame(&mut host, &ServerMessage::Ok).unwrap();
        received
    });
    let rest = letters(pasted..pasted + 256 * 1024);
    expected.extend_from_slice(&rest);
    pipe.write.write_all(&rest).unwrap();
    drop(pipe);
    assert!(
        wait_within(&mut child.0, Duration::from_secs(20)).success(),
        "{}",
        stderr_of(&mut child.0)
    );
    let received = reader.join().unwrap();
    assert!(received == expected, "input was lost or reordered");
    let status = read_status(&status);
    assert_eq!(status["outcome"], "detached");
    assert!(status["message"].is_null());
}

#[test]
fn a_detach_behind_input_that_keeps_moving_waits_for_all_of_it() {
    // More than the client buffers, read by the host in about 4 s: far
    // longer than the wait, but never stalled for long. While the client
    // still has input to hand over, the host leaves the Pings unanswered, so
    // only the transport accepting input shows it moving. Once the Detach is
    // in the connection, the rest of the paste waits in the socket buffer,
    // where only the Pongs can show it moving: 8 KiB on macOS, but on Linux
    // over 100 KiB by default and more where buffers are larger, which at
    // this pace can take longer than the wait. So from then on the host
    // answers the Pings, as a real one does.
    const PASTE: usize = 1536 * 1024;
    let (directory, listener, command) = listener();
    let status = directory.path().join("status.json");
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, session(), b"");
        stream
            .set_read_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        let mut received = Vec::with_capacity(PASTE);
        let mut pace = Pace::new();
        let mut waiting = vec![0u8; 4 << 20];
        // How much of the paste was read before the client had handed over
        // everything.
        let mut handed_over = None;
        loop {
            if handed_over.is_none() && holds_the_detach(&stream, &mut waiting) {
                handed_over = Some(received.len());
            }
            match read_client(&mut stream) {
                Some(ClientMessage::Input { data }) => {
                    pace.read(data.len());
                    received.extend(data);
                }
                Some(ClientMessage::Ping) if handed_over.is_some() => {
                    write_frame(&mut stream, &ServerMessage::Pong).unwrap();
                }
                Some(ClientMessage::Ping) => {}
                Some(ClientMessage::Detach) => break,
                other => panic!("unexpected {other:?}"),
            }
        }
        write_frame(&mut stream, &ServerMessage::Ok).unwrap();
        // Otherwise it had read everything before the Detach arrived.
        let handed_over = handed_over.unwrap_or(received.len());
        (received, handed_over)
    });
    let started = Instant::now();
    let mut child = attach_with_paste(command, &status, alphabet(PASTE));
    let exit = wait_within(&mut child, Duration::from_secs(20));
    let error = stderr_of(&mut child);
    assert!(exit.success(), "{error}");
    assert!(
        started.elapsed() > Duration::from_secs(3),
        "the host read faster than intended"
    );
    assert_eq!(error, "");
    let (received, handed_over) = server.join().unwrap();
    assert!(received == alphabet(PASTE), "input was lost");
    // Most of the paste moved with only the transport to show it.
    assert!(
        handed_over > PASTE / 2,
        "only {handed_over} bytes before the Pongs"
    );
    let status = read_status(&status);
    assert_eq!(status["outcome"], "detached");
    assert!(status["message"].is_null());
}

#[test]
fn a_detach_waits_while_the_host_answers_the_pings_behind_the_input() {
    // Like ssh, which accepts megabytes before a slow link carries them:
    // the transport takes everything at once, so only the host's answers to
    // the Pings behind the input show that it still moves.
    const PASTE: usize = 1536 * 1024;
    let (directory, listener, command) = listener();
    let status = directory.path().join("status.json");
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, session(), b"");
        stream
            .set_read_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        let (frames_tx, frames) = mpsc::channel();
        let mut reader = stream.try_clone().unwrap();
        thread::spawn(move || {
            while let Some(message) = read_client(&mut reader) {
                let detach = matches!(message, ClientMessage::Detach);
                frames_tx.send(message).unwrap();
                if detach {
                    break;
                }
            }
        });
        let mut received = Vec::with_capacity(PASTE);
        let mut pace = Pace::new();
        let mut pings = 0;
        loop {
            match frames.recv_timeout(Duration::from_secs(20)).unwrap() {
                ClientMessage::Input { data } => {
                    pace.read(data.len());
                    received.extend(data);
                }
                ClientMessage::Ping => {
                    pings += 1;
                    write_frame(&mut stream, &ServerMessage::Pong).unwrap();
                }
                ClientMessage::Detach => break,
                other => panic!("unexpected {other:?}"),
            }
        }
        write_frame(&mut stream, &ServerMessage::Ok).unwrap();
        (received, pings)
    });
    let mut child = attach_with_paste(command, &status, alphabet(PASTE));
    let exit = wait_within(&mut child, Duration::from_secs(20));
    let error = stderr_of(&mut child);
    assert!(exit.success(), "{error}");
    assert_eq!(error, "");
    let (received, pings) = server.join().unwrap();
    assert!(received == alphabet(PASTE), "input was lost");
    // One behind every 64 KiB of input.
    assert!(pings >= PASTE / (64 * 1024) - 1, "{pings} Pings");
    let status = read_status(&status);
    assert_eq!(status["outcome"], "detached");
    assert!(status["message"].is_null());
}

#[test]
fn a_host_that_closes_without_confirming_the_detach_is_reported() {
    // It read the Detach but closed without its Ok (it crashed, stopped or
    // lost the connection), or it never read that far.
    for reads in [true, false] {
        let (directory, listener, mut command) = listener();
        let status = directory.path().join("status.json");
        let server = thread::spawn(move || {
            let mut stream = accept_attach(listener, session(), b"");
            if reads {
                assert!(
                    matches!(read_client(&mut stream), Some(ClientMessage::Input { data }) if data == b"make test\n")
                );
                assert!(matches!(
                    read_client(&mut stream),
                    Some(ClientMessage::Detach)
                ));
            } else {
                thread::sleep(Duration::from_millis(1500));
            }
            drop(stream);
        });
        let paste = if reads {
            b"make test\n".to_vec()
        } else {
            // More than the socket buffers hold: writing it fails.
            vec![b'x'; 512 * 1024]
        };
        let mut child = command
            .args(["attach", "test-session", "--status-file"])
            .arg(&status)
            // Longer than the test: the close ends the wait, not its limit.
            .env("CHERRY_CLI_DETACH_WAIT_MS", "30000")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let mut stdin = child.stdin.take().unwrap();
        stdin.write_all(&paste).unwrap();
        drop(stdin);
        let exit = wait_within(&mut child, Duration::from_secs(10));
        let error = stderr_of(&mut child);
        assert!(exit.success(), "reads: {reads}: {error}");
        assert!(
            error.contains("the host closed the connection without confirming the detach"),
            "reads: {reads}: {error}"
        );
        server.join().unwrap();
        let status = read_status(&status);
        assert_eq!(status["outcome"], "detached");
        assert!(
            status["message"]
                .as_str()
                .unwrap()
                .contains("may have been discarded"),
            "{status}"
        );
    }
}

#[test]
fn a_detach_ends_once_a_host_that_stopped_reading_sent_nothing_more() {
    // A gateway that stopped reading the connection but keeps it open:
    // sending fails, and neither a confirmation nor an end of file arrives.
    let directory = tempfile::tempdir().unwrap();
    let stream = directory.path().join("stream");
    let go = directory.path().join("go");
    let closed = directory.path().join("closed");
    let status = directory.path().join("status.json");
    std::fs::write(
        &stream,
        [
            format!("CHERRY-GATEWAY {PROTOCOL_VERSION}\n").as_bytes(),
            &frames(&[
                ServerMessage::Welcome {
                    version: PROTOCOL_VERSION,
                    host_id: "remote".into(),
                    build: None,
                },
                ServerMessage::Attached {
                    reason: AttachReason::Attach,
                    session: sized_session(DEFAULT_COLS, DEFAULT_ROWS),
                    offset: 0,
                    snapshot: b"ready".to_vec(),
                    refreshes: false,
                },
            ]),
        ]
        .concat(),
    )
    .unwrap();
    script(
        &directory.path().join("ssh"),
        &format!(
            "/bin/cat '{}'\nwhile [ ! -e '{}' ]; do /bin/sleep 0.02; done\nexec 0<&-\n: > '{}'\nexec /bin/sleep 30\n",
            stream.display(),
            go.display(),
            closed.display()
        ),
    );
    let mut child = Command::new(env!("CARGO_BIN_EXE_cherry"))
        .args([
            "--host",
            "devbox",
            "attach",
            "test-session",
            "--status-file",
        ])
        .arg(&status)
        .env("PATH", directory.path())
        // The end of input waits for the host far longer than the test.
        .env("CHERRY_CLI_DETACH_WAIT_MS", "60000")
        .env("CHERRY_CLI_CLOSED_WAIT_MS", "500")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut output = Collected::new(child.stdout.take().unwrap());
    output.expect(b"ready");
    std::fs::write(&go, "").unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !closed.exists() {
        assert!(Instant::now() < deadline, "ssh did not close its input");
        thread::sleep(Duration::from_millis(10));
    }
    // End of input: the Detach cannot be sent.
    drop(child.stdin.take());
    let exit = wait_within(&mut child, Duration::from_secs(10));
    let error = stderr_of(&mut child);
    assert!(exit.success(), "{error}");
    assert!(
        error.contains("the host stopped reading the connection without confirming the detach"),
        "{error}"
    );
    let status = read_status(&status);
    assert_eq!(status["outcome"], "detached");
    assert!(
        status["message"]
            .as_str()
            .unwrap()
            .contains("may have been discarded"),
        "{status}"
    );
}

#[test]
fn a_resize_while_waiting_for_the_detach_is_never_sent() {
    let (_directory, listener, mut command) = listener();
    let (detached_tx, detached_rx) = mpsc::channel();
    let (resized_tx, resized_rx) = mpsc::channel::<()>();
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, sized_session(80, 24), b"ready");
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Detach)
        ));
        detached_tx.send(()).unwrap();
        resized_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        // The host reads nothing after Detach; a frame written now would
        // meet a closed connection.
        stream
            .set_read_timeout(Some(Duration::from_millis(400)))
            .unwrap();
        let after = read_frame::<_, ClientMessage>(&mut stream);
        assert!(after.is_err(), "sent after Detach: {after:?}");
        write_frame(&mut stream, &ServerMessage::Ok).unwrap();
    });
    let pty = Pty::open(80, 24);
    pty.read_in_background();
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    pty.wait_for_raw_mode();
    (&pty.master).write_all(b"\x1d").unwrap();
    detached_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let size = libc::winsize {
        ws_row: 30,
        ws_col: 100,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    assert_eq!(
        unsafe { libc::ioctl(pty.slave.as_raw_fd(), libc::TIOCSWINSZ, &size) },
        0
    );
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGWINCH) }, 0);
    resized_tx.send(()).unwrap();
    let exit = wait(&mut child);
    assert!(exit.success(), "{}", stderr_of(&mut child));
    server.join().unwrap();
}

#[test]
fn unsolicited_pongs_are_ignored_at_any_time() {
    for (arguments, reply) in [
        (&["list", "--json"][..], sessions_reply("host-1", vec![])),
        (
            &["new", "--cwd=/work"],
            ServerMessage::Created { session: session() },
        ),
        (&["kill", "S"], ServerMessage::Ok),
        (&["remove", "S"], ServerMessage::Ok),
        (&["shutdown"], ServerMessage::Ok),
    ] {
        let (_directory, listener, mut command) = listener();
        let server = thread::spawn(move || {
            let mut stream = accept_raw(listener);
            assert!(matches!(
                read_client(&mut stream),
                Some(ClientMessage::Hello { .. })
            ));
            write_frame(&mut stream, &ServerMessage::Pong).unwrap();
            write_frame(
                &mut stream,
                &ServerMessage::Welcome {
                    version: PROTOCOL_VERSION,
                    host_id: "host-1".into(),
                    build: None,
                },
            )
            .unwrap();
            assert!(read_client(&mut stream).is_some());
            write_frame(&mut stream, &ServerMessage::Pong).unwrap();
            write_frame(&mut stream, &ServerMessage::Pong).unwrap();
            write_frame(&mut stream, &reply).unwrap();
        });
        let output = command
            .args(arguments)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{arguments:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        server.join().unwrap();
    }

    // While attaching, while attached and while waiting for the detach.
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Attach { .. })
        ));
        write_frame(&mut stream, &ServerMessage::Pong).unwrap();
        write_frame(
            &mut stream,
            &ServerMessage::Attached {
                reason: AttachReason::Attach,
                session: sized_session(DEFAULT_COLS, DEFAULT_ROWS),
                offset: 0,
                snapshot: b"screen".to_vec(),
                refreshes: false,
            },
        )
        .unwrap();
        write_frame(&mut stream, &ServerMessage::Pong).unwrap();
        write_frame(
            &mut stream,
            &ServerMessage::Output {
                offset: 0,
                data: b"+live".to_vec(),
            },
        )
        .unwrap();
        assert!(
            matches!(read_client(&mut stream), Some(ClientMessage::Input { data }) if data == b"typed")
        );
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Detach)
        ));
        write_frame(&mut stream, &ServerMessage::Pong).unwrap();
        write_frame(&mut stream, &ServerMessage::Pong).unwrap();
        write_frame(&mut stream, &ServerMessage::Ok).unwrap();
    });
    let mut child = command
        .args(["attach", "test-session", "--status-file"])
        .arg(&status)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut output = Collected::new(child.stdout.take().unwrap());
    output.expect(b"screen+live");
    child.stdin.take().unwrap().write_all(b"typed").unwrap();
    assert!(wait(&mut child).success(), "{}", stderr_of(&mut child));
    server.join().unwrap();
    let status = read_status(&status);
    assert_eq!(status["outcome"], "detached");
    assert!(status["message"].is_null());
}

#[test]
fn takeover_is_sent_only_when_requested() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Attach { id, takeover: true, .. }) if id == "test-session"
        ));
        write_frame(
            &mut stream,
            &ServerMessage::Attached {
                reason: AttachReason::Attach,
                session: session(),
                offset: 42,
                snapshot: b"restored screen".to_vec(),
                refreshes: false,
            },
        )
        .unwrap();
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Detach)
        ));
    });
    let result = command
        .args(["attach", "test-session", "--takeover"])
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(result.stdout.starts_with(b"restored screen"));
    server.join().unwrap();
}

#[test]
fn shared_resize_replaces_canonical_state_and_continues_at_the_new_offset() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut descriptor = sized_session(80, 24);
        let mut stream = accept_attach(listener, descriptor.clone(), b"\x1bcPREVIOUS");
        let frames = |descriptor: SessionInfo| {
            vec![
                ServerMessage::Output {
                    offset: 0,
                    data: b"-output".to_vec(),
                },
                ServerMessage::Attached {
                    reason: AttachReason::Resize,
                    session: descriptor,
                    offset: 7,
                    snapshot: b"\x1bcRESIZED".to_vec(),
                    refreshes: false,
                },
                ServerMessage::Output {
                    offset: 7,
                    data: b"-continued".to_vec(),
                },
                ServerMessage::Exit {
                    signal: None,
                    id: "test-session".into(),
                    exit_code: 0,
                },
            ]
        };
        descriptor.cols = 60;
        descriptor.rows = 15;
        for frame in frames(descriptor) {
            write_frame(&mut stream, &frame).unwrap();
        }
    });
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    assert!(wait(&mut child).success());
    let mut output = Vec::new();
    child
        .stdout
        .take()
        .unwrap()
        .read_to_end(&mut output)
        .unwrap();
    let mut screen = cherry_vt::Terminal::new(120, 32, 1024 * 1024).unwrap();
    screen.feed(&output);
    let text = screen.screen_text().unwrap();
    assert!(text.contains("RESIZED-continued"), "{text:?}");
    assert!(!text.contains("PREVIOUS"), "{text:?}");
    server.join().unwrap();
}

#[test]
fn resync_snapshot_replaces_the_screen_and_resumes_at_its_offset() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, session(), b"\x1bcFIRST");
        for frame in [
            ServerMessage::Output {
                offset: 0,
                data: b"-a".to_vec(),
            },
            // This client fell behind: output 2..500 was dropped.
            ServerMessage::Attached {
                reason: AttachReason::Resync,
                session: session(),
                offset: 500,
                snapshot: b"\x1bcRESYNCED".to_vec(),
                refreshes: false,
            },
            ServerMessage::Output {
                offset: 500,
                data: b"-b".to_vec(),
            },
            ServerMessage::Exit {
                id: "test-session".into(),
                exit_code: 0,
                signal: None,
            },
        ] {
            write_frame(&mut stream, &frame).unwrap();
        }
    });
    let output = command
        .args(["attach", "test-session"])
        .stdin(Stdio::piped())
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let mut screen = cherry_vt::Terminal::new(120, 32, 1024 * 1024).unwrap();
    screen.feed(&output.stdout);
    let text = screen.screen_text().unwrap();
    assert!(text.contains("RESYNCED-b"), "{text:?}");
    assert!(!text.contains("FIRST"), "{text:?}");
    server.join().unwrap();
}

#[test]
fn out_of_sequence_output_fails_without_sending_any_input() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, session(), b"");
        write_frame(
            &mut stream,
            &ServerMessage::Output {
                offset: 43,
                data: b"lost".to_vec(),
            },
        )
        .unwrap();
        assert!(read_client(&mut stream).is_none());
    });
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    assert!(!wait(&mut child).success());
    let error = stderr_of(&mut child);
    assert!(error.contains("out of sequence"), "{error}");
    server.join().unwrap();
}

#[test]
fn resize_and_snapshot_failures_do_not_end_the_attachment() {
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, session(), b"");
        for frame in [
            ServerMessage::error("resize_failed", "cannot resize"),
            ServerMessage::error("snapshot_failed", "too large"),
            ServerMessage::Output {
                offset: 0,
                data: b"still-attached".to_vec(),
            },
            ServerMessage::Exit {
                id: "test-session".into(),
                exit_code: 137,
                signal: Some(9),
            },
        ] {
            write_frame(&mut stream, &frame).unwrap();
        }
    });
    let output = command
        .args(["attach", "test-session", "--status-file"])
        .arg(&status)
        .stdin(Stdio::piped())
        .output()
        .unwrap();
    assert_eq!(
        output.status.code(),
        Some(137),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(contains(&output.stdout, b"still-attached"));
    server.join().unwrap();
    let status = read_status(&status);
    assert_eq!(status["outcome"], "exited");
    assert_eq!(status["exit_code"], 137);
    assert_eq!(status["signal"], 9);
}

#[test]
fn other_host_errors_end_the_attachment_as_a_disconnection() {
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, session(), b"");
        write_frame(&mut stream, &ServerMessage::error("request_failed", "boom")).unwrap();
        assert!(read_client(&mut stream).is_none());
    });
    // Its input stays open: end of input would detach, and the Detach could
    // be sent before the error is read.
    let mut child = command
        .args(["attach", "test-session", "--status-file"])
        .arg(&status)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    assert_eq!(wait(&mut child).code(), Some(1));
    let error = stderr_of(&mut child);
    assert!(
        error.contains("host rejected request (request_failed): boom"),
        "{error}"
    );
    server.join().unwrap();
    let status = read_status(&status);
    assert_eq!(status["outcome"], "disconnected");
    assert!(status["message"].as_str().unwrap().contains("boom"));
}

#[test]
fn a_lost_connection_is_reported_as_disconnected() {
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let server = thread::spawn(move || drop(accept_attach(listener, session(), b"")));
    // Its input stays open: end of input would detach, and the Detach could
    // be handled before the lost connection is noticed.
    let mut child = command
        .args(["attach", "test-session", "--status-file"])
        .arg(&status)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    assert_eq!(wait(&mut child).code(), Some(1));
    server.join().unwrap();
    let value = read_status(&status);
    assert_eq!(value["outcome"], "disconnected");
    assert!(value["message"]
        .as_str()
        .unwrap()
        .contains("connection lost"));
    // Connecting again may resolve it: nothing says otherwise.
    assert!(value.get("reconnectable").is_none(), "{value}");
}

#[test]
fn an_attachment_nothing_can_resume_says_it_is_not_reconnectable() {
    // The host no longer has the session.
    let (directory, gone, mut command) = listener();
    let status = directory.path().join("status.json");
    let server = thread::spawn(move || {
        let mut stream = accept(gone);
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Attach { .. })
        ));
        write_frame(
            &mut stream,
            &ServerMessage::error("unknown_session", "no session test-session"),
        )
        .unwrap();
    });
    let output = command
        .args(["attach", "test-session", "--status-file"])
        .arg(&status)
        .stdin(Stdio::piped())
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    server.join().unwrap();
    let value = read_status(&status);
    assert_eq!(value["outcome"], "failed");
    assert_eq!(value["reconnectable"], false, "{value}");

    // Another host identity answers.
    let (directory, other, mut command) = listener();
    let status = directory.path().join("status.json");
    let server = thread::spawn(move || drop(accept(other)));
    let output = command
        .args([
            "--expected-host-id",
            "12345678-1234-4234-8234-123456789abc",
            "attach",
            "test-session",
            "--status-file",
        ])
        .arg(&status)
        .stdin(Stdio::piped())
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    server.join().unwrap();
    let value = read_status(&status);
    assert_eq!(value["outcome"], "failed");
    assert!(
        value["message"]
            .as_str()
            .unwrap()
            .contains("host identity changed"),
        "{value}"
    );
    assert_eq!(value["reconnectable"], false, "{value}");
}

#[test]
fn a_rejected_attach_is_reported_as_failed() {
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Attach { .. })
        ));
        write_frame(
            &mut stream,
            &ServerMessage::error("request_failed", "unknown session"),
        )
        .unwrap();
    });
    let output = command
        .args(["attach", "test-session", "--status-file"])
        .arg(&status)
        .stdin(Stdio::piped())
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    server.join().unwrap();
    let value = read_status(&status);
    assert_eq!(value["outcome"], "failed");
    assert!(value["message"]
        .as_str()
        .unwrap()
        .contains("host rejected request (request_failed): unknown session"));
}

#[test]
fn attach_failures_before_connecting_still_write_the_status_file() {
    let directory = private_directory();
    let status = directory.path().join("status.json");
    let output = Command::new(env!("CARGO_BIN_EXE_cherry"))
        .arg("--socket")
        .arg(directory.path().join("missing.sock"))
        .args(["attach", "test-session", "--status-file"])
        .arg(&status)
        .env("CHERRY_HOST_PATH", "/nonexistent/cherry-host")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    let value = read_status(&status);
    assert_eq!(value["outcome"], "failed");
    assert!(
        value["message"]
            .as_str()
            .unwrap()
            .contains("could not start"),
        "{value}"
    );

    // A usage error is still exit code 2, and still reported.
    let output = Command::new(env!("CARGO_BIN_EXE_cherry"))
        .args([
            "attach",
            "test-session",
            "--detach-key",
            "ctrl-a",
            "--status-file",
        ])
        .arg(&status)
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(2));
    let value = read_status(&status);
    assert_eq!(value["outcome"], "failed");
    assert!(
        value["message"].as_str().unwrap().contains("ctrl-a"),
        "{value}"
    );
}

#[test]
fn attaching_to_the_session_the_command_runs_in_is_refused() {
    let directory = private_directory();
    let status = directory.path().join("status.json");
    let log = directory.path().join("started");
    let host = directory.path().join("cherry-host");
    script(
        &host,
        &format!("echo started > '{}'\nexit 1\n", log.display()),
    );
    let output = Command::new(env!("CARGO_BIN_EXE_cherry"))
        .arg("--socket")
        .arg(directory.path().join("host.sock"))
        .args(["attach", "test-session", "--status-file"])
        .arg(&status)
        .env("CHERRY_SESSION_ID", "test-session")
        .env("CHERRY_HOST_PATH", &host)
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    let error = String::from_utf8_lossy(&output.stderr);
    assert!(error.contains("inside itself"), "{error}");
    assert!(!log.exists(), "self-attach contacted a host");
    assert_eq!(read_status(&status)["outcome"], "failed");
}

struct Pty {
    master: File,
    slave: File,
}
impl Pty {
    fn open(cols: u16, rows: u16) -> Self {
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
        Self {
            master: unsafe { File::from_raw_fd(master) },
            slave: unsafe { File::from_raw_fd(slave) },
        }
    }
    fn termios(&self) -> libc::termios {
        let mut mode = unsafe { std::mem::zeroed() };
        assert_eq!(
            unsafe { libc::tcgetattr(self.slave.as_raw_fd(), &mut mode) },
            0
        );
        mode
    }
    fn wait_for_raw_mode(&self) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while self.termios().c_lflag & libc::ICANON != 0 {
            assert!(Instant::now() < deadline, "client did not enter raw mode");
            thread::sleep(Duration::from_millis(10));
        }
    }
    /// Keep reading like a terminal would, so the client never blocks on a
    /// full PTY while a test is not looking at its output.
    fn read_in_background(&self) {
        let mut master = self.master.try_clone().unwrap();
        thread::spawn(move || {
            let mut buffer = [0u8; 65536];
            while matches!(master.read(&mut buffer), Ok(n) if n > 0) {}
        });
    }

    /// Everything the client wrote so far, without blocking.
    fn drain(&mut self) -> Vec<u8> {
        let flags = unsafe { libc::fcntl(self.master.as_raw_fd(), libc::F_GETFL) };
        unsafe {
            libc::fcntl(
                self.master.as_raw_fd(),
                libc::F_SETFL,
                flags | libc::O_NONBLOCK,
            );
        }
        let mut received = Vec::new();
        let mut buffer = [0u8; 65536];
        loop {
            match self.master.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => received.extend_from_slice(&buffer[..n]),
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(error) if error.raw_os_error() == Some(libc::EIO) => break,
                Err(error) => panic!("reading terminal output: {error}"),
            }
        }
        received
    }
}

fn assert_mode_restored(original: &libc::termios, restored: &libc::termios) {
    // macOS sets PENDIN itself when returning to canonical input mode.
    assert_eq!(
        restored.c_lflag & !libc::PENDIN,
        original.c_lflag & !libc::PENDIN
    );
    assert_eq!(restored.c_iflag, original.c_iflag);
    assert_eq!(restored.c_oflag, original.c_oflag);
    assert_eq!(restored.c_cflag, original.c_cflag);
    assert_eq!(restored.c_cc, original.c_cc);
}

#[test]
fn only_a_client_whose_input_and_output_are_one_terminal_answers_queries() {
    let pty = Pty::open(80, 24);
    pty.read_in_background();
    let other = Pty::open(80, 24);
    other.read_in_background();
    let terminal = |pty: &Pty| Stdio::from(pty.slave.try_clone().unwrap());
    let cases = [
        ("one terminal", terminal(&pty), terminal(&pty), true),
        ("output to a pipe", terminal(&pty), Stdio::piped(), false),
        ("input from a pipe", Stdio::piped(), terminal(&pty), false),
        ("two terminals", terminal(&pty), terminal(&other), false),
        ("no terminal", Stdio::null(), Stdio::null(), false),
    ];
    for (case, stdin, stdout, answers) in cases {
        let (_directory, listener, mut command) = listener();
        let server = thread::spawn(move || {
            let mut stream = accept(listener);
            // Closing the connection then ends the attach.
            match read_client(&mut stream) {
                Some(ClientMessage::Attach {
                    answers_queries, ..
                }) => answers_queries,
                other => panic!("expected Attach, received {other:?}"),
            }
        });
        let mut child = command
            .args(["attach", "test-session"])
            .stdin(stdin)
            .stdout(stdout)
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        assert_eq!(server.join().unwrap(), answers, "{case}");
        assert_eq!(wait(&mut child).code(), Some(1), "{case}");
    }
}

#[test]
fn controller_replacement_restores_terminal_mode_and_reports_the_handoff() {
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let (replace_tx, replace_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, session(), b"ready");
        replace_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        write_frame(
            &mut stream,
            &ServerMessage::Error {
                code: "taken_over".into(),
                message: "Another device took over this session. The session is still running."
                    .into(),
            },
        )
        .unwrap();
        assert!(read_client(&mut stream).is_none());
    });
    let pty = Pty::open(120, 32);
    pty.read_in_background();
    let original = pty.termios();
    let mut child = command
        .args(["attach", "test-session", "--status-file"])
        .arg(&status)
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    pty.wait_for_raw_mode();
    replace_tx.send(()).unwrap();
    assert_eq!(wait(&mut child).code(), Some(1));
    assert_mode_restored(&original, &pty.termios());
    let error = stderr_of(&mut child);
    assert!(
        error.contains("Another device took over this session"),
        "{error}"
    );
    assert!(error.contains("still running"), "{error}");
    server.join().unwrap();
    let status = read_status(&status);
    assert_eq!(status["outcome"], "taken_over");
    assert!(status["message"].as_str().unwrap().contains("took over"));
}

#[test]
fn a_takeover_is_reported_when_writing_to_the_host_fails_first() {
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, session(), b"");
        // The client is pasting and this host is not reading, so the client
        // has input waiting when another client takes over: the host sends
        // its notice and closes the connection. The client's next write
        // fails before it has read the notice.
        thread::sleep(Duration::from_millis(500));
        write_frame(
            &mut stream,
            &ServerMessage::Error {
                code: "taken_over".into(),
                message: "Another device took over this session.".into(),
            },
        )
        .unwrap();
    });
    let mut child = command
        .args([
            "attach",
            "test-session",
            "--detach-key",
            "none",
            "--status-file",
        ])
        .arg(&status)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let writer = paste_in_background(&mut child);
    let exit = wait_within(&mut child, Duration::from_secs(10));
    let error = stderr_of(&mut child);
    assert_eq!(exit.code(), Some(1), "{error}");
    assert!(error.contains("Another device took over"), "{error}");
    writer.join().unwrap();
    server.join().unwrap();
    let status = read_status(&status);
    assert_eq!(status["outcome"], "taken_over", "{status}");
}

#[test]
fn real_pty_forwards_resize_and_control_c_and_restores_mode_on_sigterm() {
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let (resized_tx, resized_rx) = mpsc::channel();
    let (input_tx, input_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Attach {
                cols: 80,
                rows: 24,
                ..
            })
        ));
        write_frame(
            &mut stream,
            &ServerMessage::Attached {
                reason: AttachReason::Attach,
                session: sized_session(80, 24),
                offset: 0,
                snapshot: b"ready".to_vec(),
                refreshes: false,
            },
        )
        .unwrap();
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Resize {
                cols: 101,
                rows: 41,
                ..
            })
        ));
        resized_tx.send(()).unwrap();
        assert!(
            matches!(read_client(&mut stream), Some(ClientMessage::Input { data }) if data == [3])
        );
        input_tx.send(()).unwrap();
        assert!(read_client(&mut stream).is_none());
    });
    let pty = Pty::open(80, 24);
    pty.read_in_background();
    let original = pty.termios();
    let mut child = command
        .args(["attach", "test-session", "--status-file"])
        .arg(&status)
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    pty.wait_for_raw_mode();
    let size = libc::winsize {
        ws_row: 41,
        ws_col: 101,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    assert_eq!(
        unsafe { libc::ioctl(pty.slave.as_raw_fd(), libc::TIOCSWINSZ, &size) },
        0
    );
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGWINCH) }, 0);
    resized_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    (&pty.master).write_all(&[3]).unwrap();
    input_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGTERM) }, 0);
    assert_eq!(wait(&mut child).code(), Some(128 + libc::SIGTERM));
    assert_mode_restored(&original, &pty.termios());
    let error = stderr_of(&mut child);
    assert!(error.contains("interrupted by signal 15"), "{error}");
    server.join().unwrap();
    let status = read_status(&status);
    assert_eq!(status["outcome"], "disconnected");
    assert!(status["message"].as_str().unwrap().contains("signal 15"));
}

#[test]
fn a_resize_that_sets_the_shared_grid_switches_straight_to_the_new_snapshot() {
    let (_directory, listener, mut command) = listener();
    let (resized_tx, resized_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, sized_session(80, 24), b"\x1bc\x1b[?1004hFIRST");
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Resize {
                cols: 101,
                rows: 41,
                ..
            })
        ));
        // A moment later, as over a network.
        thread::sleep(Duration::from_millis(100));
        for frame in [
            ServerMessage::Attached {
                reason: AttachReason::Resize,
                session: sized_session(101, 41),
                offset: 0,
                snapshot: b"\x1bc\x1b[?1004hRESIZED".to_vec(),
                refreshes: false,
            },
            ServerMessage::Exit {
                id: "test-session".into(),
                exit_code: 0,
                signal: None,
            },
        ] {
            write_frame(&mut stream, &frame).unwrap();
        }
        resized_tx.send(()).unwrap();
    });
    let mut pty = Pty::open(80, 24);
    let mut child = command
        .args(["attach", "test-session"])
        // Far longer than the host takes, so a loaded machine cannot turn
        // the wait into a viewport.
        .env("CHERRY_CLI_GRID_WAIT_MS", "3000")
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    pty.wait_for_raw_mode();
    let size = libc::winsize {
        ws_row: 41,
        ws_col: 101,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    assert_eq!(
        unsafe { libc::ioctl(pty.slave.as_raw_fd(), libc::TIOCSWINSZ, &size) },
        0
    );
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGWINCH) }, 0);
    resized_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let mut received = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(5);
    while child.try_wait().unwrap().is_none() {
        received.extend(pty.drain());
        assert!(Instant::now() < deadline, "client did not exit");
        thread::sleep(Duration::from_millis(10));
    }
    received.extend(pty.drain());
    assert!(child.wait().unwrap().success());
    assert!(contains(&received, b"\x1bc\x1b[?1004hRESIZED"));
    assert!(
        !contains(&received, b"\x1b[?2026h"),
        "painted a viewport while the host was resizing the grid"
    );
    server.join().unwrap();
}

#[test]
fn a_repeated_resize_signal_keeps_waiting_for_the_grid() {
    let (_directory, listener, mut command) = listener();
    let (resized_tx, resized_rx) = mpsc::channel();
    let (repeated_tx, repeated_rx) = mpsc::channel::<()>();
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, sized_session(80, 24), b"\x1bc\x1b[?1004hFIRST");
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Resize {
                cols: 101,
                rows: 41,
                ..
            })
        ));
        resized_tx.send(()).unwrap();
        // The terminal signals the same size again before the grid follows.
        repeated_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        for frame in [
            ServerMessage::Attached {
                reason: AttachReason::Resize,
                session: sized_session(101, 41),
                offset: 0,
                snapshot: b"\x1bc\x1b[?1004hRESIZED".to_vec(),
                refreshes: false,
            },
            ServerMessage::Exit {
                id: "test-session".into(),
                exit_code: 0,
                signal: None,
            },
        ] {
            write_frame(&mut stream, &frame).unwrap();
        }
        // No other size was requested.
        while let Ok(Some(message)) = read_frame::<_, ClientMessage>(&mut stream) {
            assert!(matches!(message, ClientMessage::Ping), "{message:?}");
        }
    });
    let mut pty = Pty::open(80, 24);
    let mut child = command
        .args(["attach", "test-session"])
        // Far longer than the test takes, so only the repeated signal could
        // turn the wait into a viewport.
        .env("CHERRY_CLI_GRID_WAIT_MS", "5000")
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    pty.wait_for_raw_mode();
    let size = libc::winsize {
        ws_row: 41,
        ws_col: 101,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    assert_eq!(
        unsafe { libc::ioctl(pty.slave.as_raw_fd(), libc::TIOCSWINSZ, &size) },
        0
    );
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGWINCH) }, 0);
    resized_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGWINCH) }, 0);
    // Longer than the client coalesces signals for.
    let mut received = Vec::new();
    let settled = Instant::now() + Duration::from_millis(400);
    while Instant::now() < settled {
        received.extend(pty.drain());
        thread::sleep(Duration::from_millis(10));
    }
    repeated_tx.send(()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while child.try_wait().unwrap().is_none() {
        received.extend(pty.drain());
        assert!(Instant::now() < deadline, "client did not exit");
        thread::sleep(Duration::from_millis(10));
    }
    received.extend(pty.drain());
    assert!(child.wait().unwrap().success(), "{}", stderr_of(&mut child));
    assert!(contains(&received, b"\x1bc\x1b[?1004hRESIZED"));
    assert!(
        !contains(&received, b"\x1b[?2026h"),
        "painted a viewport while the host was resizing the grid: {:?}",
        String::from_utf8_lossy(&received)
    );
    server.join().unwrap();
}

#[test]
fn a_window_beyond_the_protocol_limit_gets_a_viewport_not_the_raw_stream() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Attach {
                cols: 500,
                rows: 50,
                ..
            })
        ));
        for frame in [
            ServerMessage::Attached {
                reason: AttachReason::Attach,
                session: sized_session(500, 50),
                offset: 0,
                snapshot: b"\x1bc\x1b[?1004hWIDE-SNAPSHOT".to_vec(),
                refreshes: false,
            },
            ServerMessage::Output {
                offset: 0,
                data: b" LIVE".to_vec(),
            },
            ServerMessage::Exit {
                id: "test-session".into(),
                exit_code: 0,
                signal: None,
            },
        ] {
            write_frame(&mut stream, &frame).unwrap();
        }
    });
    let mut pty = Pty::open(600, 50);
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut received = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(5);
    while child.try_wait().unwrap().is_none() {
        received.extend(pty.drain());
        assert!(Instant::now() < deadline, "client did not exit");
        thread::sleep(Duration::from_millis(10));
    }
    assert!(child.wait().unwrap().success(), "{}", stderr_of(&mut child));
    received.extend(pty.drain());
    assert!(
        received.starts_with(b"\x1b[?2026h"),
        "{:?}",
        String::from_utf8_lossy(&received[..80.min(received.len())])
    );
    assert!(
        !contains(&received, b"\x1bc"),
        "raw snapshot or RIS written"
    );
    // modes() once, then content-only frames.
    let focus = received
        .windows(8)
        .filter(|bytes| *bytes == b"\x1b[?1004h")
        .count();
    assert_eq!(focus, 1, "modes were sent more than once");
    let mut screen = cherry_vt::Terminal::new(600, 50, 0).unwrap();
    screen.feed(&received);
    assert!(screen.screen_text().unwrap().contains("WIDE-SNAPSHOT LIVE"));
    server.join().unwrap();
}

#[test]
fn a_viewport_writes_clipboard_titles_bells_and_queries_through() {
    const ANSWER: &[u8] = b"\x1b[?2;3R";
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        // The shared grid is smaller than the window: a viewport.
        let mut stream = accept_attach(listener, sized_session(80, 24), b"\x1bc");
        let mut offset = 0;
        for data in [
            // A clipboard write split across output frames.
            &b"copied \x1b]52;c;aGVs"[..],
            b"bG8=\x07\x1b]2;TITLE\x07\x07",
            b"\r\nAB",
            // A query the host leaves to this client's terminal, then more
            // output.
            b"\x1b[?6n",
            b"CD",
        ] {
            let message = if data == b"\x1b[?6n" {
                ServerMessage::Query {
                    data: data.to_vec(),
                }
            } else {
                offset += data.len() as u64;
                ServerMessage::Output {
                    offset: offset - data.len() as u64,
                    data: data.to_vec(),
                }
            };
            write_frame(&mut stream, &message).unwrap();
        }
        // The window's answer arrives as input.
        let mut typed = Vec::new();
        while !contains(&typed, ANSWER) {
            match read_client(&mut stream) {
                Some(ClientMessage::Input { data }) => typed.extend(data),
                Some(ClientMessage::Ping) => {}
                other => panic!("unexpected {other:?}"),
            }
        }
        assert_eq!(typed, ANSWER);
        write_frame(
            &mut stream,
            &ServerMessage::Exit {
                id: "test-session".into(),
                exit_code: 0,
                signal: None,
            },
        )
        .unwrap();
    });
    let mut pty = Pty::open(100, 30);
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut received = Vec::new();
    let mut answered = false;
    let deadline = Instant::now() + Duration::from_secs(10);
    while child.try_wait().unwrap().is_none() {
        received.extend(pty.drain());
        // Answer as a terminal does, where the viewport put the cursor.
        if !answered && contains(&received, b"\x1b[?6n") {
            pty.master.write_all(ANSWER).unwrap();
            answered = true;
        }
        assert!(Instant::now() < deadline, "client did not exit");
        thread::sleep(Duration::from_millis(10));
    }
    assert!(child.wait().unwrap().success(), "{}", stderr_of(&mut child));
    received.extend(pty.drain());
    server.join().unwrap();
    assert!(
        contains(&received, b"\x1b]52;c;aGVsbG8=\x07\x1b]2;TITLE\x07\x07"),
        "{:?}",
        String::from_utf8_lossy(&received)
    );
    // The window showed the screen up to the query when it received it.
    let query = received
        .windows(5)
        .position(|bytes| bytes == b"\x1b[?6n")
        .unwrap();
    let mut window = cherry_vt::Terminal::new(100, 30, 0).unwrap();
    window.feed(&received[..query]);
    let state = window.inspect().unwrap();
    assert_eq!(state.cursor, (2, 1));
    assert!(state.active[1].starts_with("AB"), "{:?}", state.active);
    window.feed(&received[query..]);
    let text = window.screen_text().unwrap();
    assert!(text.contains("copied") && text.contains("ABCD"), "{text:?}");
}

#[test]
fn a_query_goes_to_the_terminal_and_its_answer_to_the_host() {
    const ANSWER: &[u8] = b"\x1b]11;rgb:0000/0000/0000\x1b\\";
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        // The window has the grid's size: the stream is written directly.
        let mut stream = accept_attach(listener, sized_session(80, 24), b"\x1bc");
        for message in [
            ServerMessage::Output {
                offset: 0,
                data: b"before ".to_vec(),
            },
            ServerMessage::Query {
                data: b"\x1b]11;?\x1b\\".to_vec(),
            },
            // Queries carry no offset: output continues where it was.
            ServerMessage::Output {
                offset: 7,
                data: b"after".to_vec(),
            },
        ] {
            write_frame(&mut stream, &message).unwrap();
        }
        let mut typed = Vec::new();
        while !contains(&typed, ANSWER) {
            match read_client(&mut stream) {
                Some(ClientMessage::Input { data }) => typed.extend(data),
                Some(ClientMessage::Ping) => {}
                other => panic!("unexpected {other:?}"),
            }
        }
        assert_eq!(typed, ANSWER);
        write_frame(
            &mut stream,
            &ServerMessage::Exit {
                id: "test-session".into(),
                exit_code: 0,
                signal: None,
            },
        )
        .unwrap();
    });
    let mut pty = Pty::open(80, 24);
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut received = Vec::new();
    let mut answered = false;
    let deadline = Instant::now() + Duration::from_secs(10);
    while child.try_wait().unwrap().is_none() {
        received.extend(pty.drain());
        if !answered && contains(&received, b"\x1b]11;?\x1b\\") {
            pty.master.write_all(ANSWER).unwrap();
            answered = true;
        }
        assert!(Instant::now() < deadline, "client did not exit");
        thread::sleep(Duration::from_millis(10));
    }
    assert!(child.wait().unwrap().success(), "{}", stderr_of(&mut child));
    received.extend(pty.drain());
    server.join().unwrap();
    assert!(
        contains(&received, b"before \x1b]11;?\x1b\\after"),
        "{:?}",
        String::from_utf8_lossy(&received)
    );
}

#[test]
fn a_query_arriving_while_detaching_is_not_written_to_the_terminal() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, session(), b"");
        loop {
            match read_client(&mut stream) {
                Some(ClientMessage::Detach) => break,
                Some(ClientMessage::Ping) => {}
                other => panic!("unexpected {other:?}"),
            }
        }
        // Sent before the host read the Detach: the reply could only reach
        // the local shell.
        for message in [
            ServerMessage::Query {
                data: b"\x1b[?6n".to_vec(),
            },
            ServerMessage::Output {
                offset: 0,
                data: b"LAST".to_vec(),
            },
            ServerMessage::Ok,
        ] {
            write_frame(&mut stream, &message).unwrap();
        }
    });
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut output = Collected::new(child.stdout.take().unwrap());
    // The detach key and another key: detach at once.
    child.stdin.as_mut().unwrap().write_all(b"\x1dq").unwrap();
    output.expect(b"LAST");
    assert!(wait(&mut child).success(), "{}", stderr_of(&mut child));
    server.join().unwrap();
    assert!(!contains(&output.received, b"\x1b[?6n"));
}

#[test]
fn detaching_from_a_viewport_returns_the_cursor_to_the_prompt() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        // A smaller session that entered the alternate screen with 1047, which
        // leaves it with the program's cursor when the window uses 1047 too.
        let mut stream = accept_attach(listener, sized_session(20, 5), b"\x1b[?1047h\x1b[3;4HEDIT");
        write_frame(
            &mut stream,
            &ServerMessage::Output {
                offset: 0,
                data: b"\x1b[?1004hMORE".to_vec(),
            },
        )
        .unwrap();
        loop {
            match read_client(&mut stream) {
                Some(ClientMessage::Detach) => break,
                Some(ClientMessage::Ping) => {}
                other => panic!("unexpected {other:?}"),
            }
        }
        write_frame(&mut stream, &ServerMessage::Ok).unwrap();
    });
    let mut pty = Pty::open(30, 8);
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut received = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !contains(&received, b"MORE") {
        received.extend(pty.drain());
        assert!(Instant::now() < deadline, "no viewport frame");
        thread::sleep(Duration::from_millis(10));
    }
    pty.master.write_all(&[0x1d]).unwrap();
    assert!(wait(&mut child).success(), "{}", stderr_of(&mut child));
    received.extend(pty.drain());
    // Replay into a window whose prompt is on row 1, the cursor below it.
    let mut window = cherry_vt::Terminal::new(30, 8, 0).unwrap();
    window.feed(b"motd\r\n$ cherry attach S\r\n");
    window.feed(&received);
    let state = window.inspect().unwrap();
    assert!(!state.alternate);
    assert_eq!(
        state.cursor,
        (0, 2),
        "{:?}",
        String::from_utf8_lossy(&received)
    );
    assert!(
        state.active[1].contains("$ cherry attach S"),
        "{:?}",
        state.active
    );
    assert!(state.modes.is_empty(), "{:?}", state.modes);
    server.join().unwrap();
}

#[test]
fn detaching_from_a_viewport_the_window_entered_on_the_alternate_screen_leaves_as_the_session_would(
) {
    // A session of the window's size, on the alternate screen through 1047.
    let mut session = cherry_vt::Terminal::new(30, 8, 0).unwrap();
    session.feed(b"motd\r\n$ prog\r\n\x1b[?1047h\x1b[3;4HEDIT");
    let snapshot = session.snapshot().unwrap();
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, sized_session(30, 8), &snapshot);
        // The shared grid never follows the window.
        loop {
            match read_client(&mut stream) {
                Some(ClientMessage::Detach) => break,
                Some(ClientMessage::Ping | ClientMessage::Resize { .. }) => {}
                other => panic!("unexpected {other:?}"),
            }
        }
        write_frame(&mut stream, &ServerMessage::Ok).unwrap();
    });
    let mut pty = Pty::open(30, 8);
    let mut child = command
        .args(["attach", "test-session"])
        .env("CHERRY_CLI_GRID_WAIT_MS", "50")
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut direct = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !contains(&direct, b"EDIT") {
        direct.extend(pty.drain());
        assert!(Instant::now() < deadline, "no snapshot");
        thread::sleep(Duration::from_millis(10));
    }
    assert!(!contains(&direct, b"\x1b[?2026h"), "not the direct stream");
    let size = libc::winsize {
        ws_row: 10,
        ws_col: 40,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    assert_eq!(
        unsafe { libc::ioctl(pty.slave.as_raw_fd(), libc::TIOCSWINSZ, &size) },
        0
    );
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGWINCH) }, 0);
    let mut viewport = Vec::new();
    // The frame ends its synchronized update last.
    while !contains(&viewport, b"\x1b[?2026l") {
        viewport.extend(pty.drain());
        assert!(Instant::now() < deadline, "no viewport frame");
        thread::sleep(Duration::from_millis(10));
    }
    pty.master.write_all(&[0x1d]).unwrap();
    assert!(wait(&mut child).success(), "{}", stderr_of(&mut child));
    viewport.extend(pty.drain());
    let mut window = cherry_vt::Terminal::new(30, 8, 0).unwrap();
    window.feed(b"shell\r\n$ cherry attach S\r\n");
    window.feed(&direct);
    window.resize(40, 10).unwrap();
    window.feed(&viewport);
    let state = window.inspect().unwrap();
    assert!(!state.alternate);
    // Where the session's own ?1047l leaves it: the program's cursor.
    assert_eq!(
        state.cursor,
        (7, 2),
        "{:?}",
        String::from_utf8_lossy(&viewport)
    );
    assert!(state.active[1].contains("$ prog"), "{:?}", state.active);
    assert!(state.modes.is_empty(), "{:?}", state.modes);
    server.join().unwrap();
}

#[test]
fn ssh_uses_one_quoted_gateway_command_and_never_becomes_a_control_master() {
    let directory = tempfile::tempdir().unwrap();
    let log = directory.path().join("arguments");
    script(
        &directory.path().join("ssh"),
        "printf '%s\\n' \"$@\" > \"$CHERRY_TEST_SSH_LOG\"\nexit 1\n",
    );
    let options = "-T\n-o\nControlMaster=no\n-o\nRemoteCommand=none\n-o\nClearAllForwardings=yes\n-o\nPermitLocalCommand=no\n-o\nServerAliveInterval=15\n-o\nServerAliveCountMax=3\n";
    // Only an attachment or a control connection forwards the agent: no
    // other command's connection lasts as long as the sessions that would use
    // it. Only an attachment has a terminal to prompt in.
    let batch = "-a\n-o\nBatchMode=yes\n-o\nConnectTimeout=10\n";
    let control = "-o\nBatchMode=yes\n-o\nConnectTimeout=10\n";
    // Only commands that need a session may start the remote host.
    for (arguments, batch, gateway) in [
        (&["list", "--json"][..], batch, "gateway"),
        // A list that only looks (Cherry listing another Mac).
        (
            &["list", "--json", "--no-start"],
            batch,
            "gateway --no-start",
        ),
        (&["new", "--cwd=/work"], batch, "gateway"),
        (&["attach", "S"], "", "gateway"),
        (&["control"], control, "gateway"),
        (&["kill", "S"], batch, "gateway --no-start"),
        (&["remove", "S"], batch, "gateway --no-start"),
        (&["shutdown"], batch, "gateway --no-start"),
    ] {
        let output = Command::new(env!("CARGO_BIN_EXE_cherry"))
            .args(["--host", "user@studio", "--socket", "/tmp/a'b; $(literal)"])
            .args(arguments)
            .env("PATH", directory.path())
            .env("CHERRY_TEST_SSH_LOG", &log)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert!(!output.status.success());
        let logged = std::fs::read_to_string(&log).unwrap();
        assert_eq!(
            logged,
            format!("{options}{batch}--\nuser@studio\ncherry-host {gateway} --socket '/tmp/a'\\''b; $(literal)'\n"),
            "{arguments:?}"
        );
    }
    // The identity a command insists on reaches the gateway, in the
    // environment, so that it neither replaces nor reports another host.
    let id = "5b2e7f3c-9a41-4d8e-b0c6-2f1a9e8d7c6b";
    for (arguments, gateway) in [
        (&["list", "--json"][..], "gateway"),
        (&["kill", "S"], "gateway --no-start"),
    ] {
        let output = Command::new(env!("CARGO_BIN_EXE_cherry"))
            .args(["--host", "user@studio", "--expected-host-id", id])
            .args(arguments)
            .env("PATH", directory.path())
            .env("CHERRY_TEST_SSH_LOG", &log)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert!(!output.status.success());
        let logged = std::fs::read_to_string(&log).unwrap();
        assert!(
            logged.ends_with(&format!(
                "--\nuser@studio\nenv CHERRY_EXPECTED_HOST_ID='{id}' cherry-host {gateway}\n"
            )),
            "{arguments:?}: {logged}"
        );
    }
}

/// A fake ssh that prints `stream`, then reads its input until end of file.
fn fake_ssh(directory: &Path, stream: &[u8], after_input: &str) -> PathBuf {
    let file = directory.join("stream");
    std::fs::write(&file, stream).unwrap();
    script(
        &directory.join("ssh"),
        &format!(
            "/bin/cat '{}'\n/bin/cat > /dev/null\n{after_input}\n",
            file.display()
        ),
    );
    directory.to_path_buf()
}

fn frames(messages: &[ServerMessage]) -> Vec<u8> {
    messages
        .iter()
        .flat_map(|message| encode_frame(message).unwrap())
        .collect()
}

#[test]
fn ssh_shell_output_before_the_gateway_preamble_is_skipped() {
    let directory = tempfile::tempdir().unwrap();
    let log = directory.path().join("exit");
    let stream = [
        b"Welcome to devbox\r\nYou have mail.\n".as_slice(),
        format!("CHERRY-GATEWAY {PROTOCOL_VERSION}\n").as_bytes(),
        &frames(&[
            ServerMessage::Welcome {
                version: PROTOCOL_VERSION,
                host_id: "remote".into(),
                build: None,
            },
            sessions_reply("remote", vec![session()]),
        ]),
    ]
    .concat();
    let path = fake_ssh(
        directory.path(),
        &stream,
        &format!(
            "echo input-closed > '{}'\necho 'cherry-host: a late report' >&2",
            log.display()
        ),
    );
    let output = Command::new(env!("CARGO_BIN_EXE_cherry"))
        .args(["--host", "devbox", "list", "--json"])
        .env("PATH", path)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let value: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(value["host_id"], "remote");
    // ssh ended because its input closed: a signal would have stopped the
    // script before it wrote this.
    assert_eq!(std::fs::read_to_string(&log).unwrap(), "input-closed\n");
    // A remote cherry-host report that no error used is still shown.
    assert_eq!(
        String::from_utf8_lossy(&output.stderr),
        "cherry-host: a late report\n"
    );
}

#[test]
fn a_remote_gateway_that_found_no_host_is_reported_once_by_name() {
    let directory = tempfile::tempdir().unwrap();
    let log = directory.path().join("arguments");
    let report = "cherry-host: no cherry-host is running at /tmp/cherry-host-7/host.sock";
    // What `cherry-host gateway --no-start` does when nothing is running:
    // the reason on stderr, no preamble, exit 1. ssh may deliver the reason
    // after the end of the output.
    for body in [
        format!("printf 'Welcome to devbox\\n'\necho 'Warning: added devbox' >&2\necho '{report}' >&2\nexit 1\n"),
        format!("exec 1>&-\nsleep 0.3\necho '{report}' >&2\nexit 1\n"),
    ] {
        script(
            &directory.path().join("ssh"),
            &format!("printf '%s\\n' \"$@\" > \"$CHERRY_TEST_SSH_LOG\"\n{body}"),
        );
        for arguments in [
            &["kill", "S"][..],
            &["remove", "S"],
            &["shutdown"],
            &["list", "--json", "--no-start"],
        ] {
            let output = Command::new(env!("CARGO_BIN_EXE_cherry"))
                .args(["--host", "devbox"])
                .args(arguments)
                .env("PATH", directory.path())
                .env("CHERRY_TEST_SSH_LOG", &log)
                .stdin(Stdio::null())
                .output()
                .unwrap();
            assert_eq!(output.status.code(), Some(1));
            let error = String::from_utf8_lossy(&output.stderr);
            assert!(
                error.ends_with("cherry: cherry-host on devbox: no cherry-host is running at /tmp/cherry-host-7/host.sock (this command never starts one)\n"),
                "{arguments:?}: {error}"
            );
            assert_eq!(error.matches("no cherry-host is running").count(), 1, "{error}");
            assert_eq!(
                error.contains("Warning: added devbox"),
                body.contains("Warning"),
                "{error}"
            );
            let logged = std::fs::read_to_string(&log).unwrap();
            assert!(
                logged.ends_with("--\ndevbox\ncherry-host gateway --no-start\n"),
                "{logged}"
            );
        }
    }

    // Commands that may start the host report its other refusals the same
    // way, without the note.
    let reason = "a cherry-host speaking protocol 2 is running at /tmp/cherry-host-7/host.sock (this is protocol 3); finish its sessions and stop it (`cherry shutdown` from the matching version), then try again";
    script(
        &directory.path().join("ssh"),
        &format!("printf '%s\\n' \"$@\" > \"$CHERRY_TEST_SSH_LOG\"\necho 'cherry-host: {reason}' >&2\nexit 1\n"),
    );
    for arguments in [
        &["list", "--json"][..],
        &["new", "--cwd=/work"],
        &["attach", "S"],
    ] {
        let output = Command::new(env!("CARGO_BIN_EXE_cherry"))
            .args(["--host", "devbox"])
            .args(arguments)
            .env("PATH", directory.path())
            .env("CHERRY_TEST_SSH_LOG", &log)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(1));
        let error = String::from_utf8_lossy(&output.stderr);
        assert!(
            error.ends_with(&format!("cherry: cherry-host on devbox: {reason}\n")),
            "{arguments:?}: {error}"
        );
        assert_eq!(error.matches("speaking protocol 2").count(), 1, "{error}");
        let logged = std::fs::read_to_string(&log).unwrap();
        assert!(
            logged.ends_with("--\ndevbox\ncherry-host gateway\n"),
            "{logged}"
        );
    }
}

#[test]
fn ssh_shell_output_without_a_gateway_is_explained() {
    let directory = tempfile::tempdir().unwrap();
    std::fs::write(
        directory.path().join("stream"),
        b"Welcome to devbox\nbash: cherry-host: command not found\n",
    )
    .unwrap();
    script(
        &directory.path().join("ssh"),
        &format!(
            "/bin/cat '{}'\nexit 127\n",
            directory.path().join("stream").display()
        ),
    );
    let output = Command::new(env!("CARGO_BIN_EXE_cherry"))
        .args(["--host", "devbox", "list"])
        .env("PATH", directory.path())
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    let error = String::from_utf8_lossy(&output.stderr);
    // The shell output was skipped; the gateway never started.
    assert!(
        error.contains("closed before cherry-host gateway started"),
        "{error}"
    );
    assert!(
        error.contains("printed \"Welcome to devbox\" first"),
        "{error}"
    );
    assert!(!error.contains("frame length"), "{error}");

    // More shell output than is ever skipped is blamed on the startup files.
    let directory = tempfile::tempdir().unwrap();
    let mut junk = b"Welcome to devbox\n".to_vec();
    junk.resize(70 * 1024, b'x');
    let path = fake_ssh(directory.path(), &junk, "");
    let output = Command::new(env!("CARGO_BIN_EXE_cherry"))
        .args(["--host", "devbox", "list"])
        .env("PATH", path)
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    let error = String::from_utf8_lossy(&output.stderr);
    assert!(
        error.contains("printed output before cherry-host gateway started"),
        "{error}"
    );
    assert!(
        error.contains("non-interactive shell startup files"),
        "{error}"
    );
    assert!(error.contains("\"Welcome to devbox\""), "{error}");

    let directory = tempfile::tempdir().unwrap();
    let path = fake_ssh(directory.path(), b"CHERRY-GATEWAY 2\n", "");
    let output = Command::new(env!("CARGO_BIN_EXE_cherry"))
        .args(["--host", "devbox", "list"])
        .env("PATH", path)
        .output()
        .unwrap();
    let error = String::from_utf8_lossy(&output.stderr);
    assert!(
        error.contains("version 2") && error.contains(&format!("version {PROTOCOL_VERSION}")),
        "{error}"
    );
}

#[test]
fn terminating_cli_reaps_its_ssh_process_within_a_bounded_time() {
    for ignores_sigterm in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let pid_file = directory.path().join("ssh.pid");
        script(
            &directory.path().join("ssh"),
            &format!(
                "{}printf '%s' \"$$\" > \"$CHERRY_TEST_SSH_PID\"\nexec /bin/sleep 30\n",
                if ignores_sigterm {
                    "trap '' TERM\n"
                } else {
                    ""
                }
            ),
        );
        let mut child = Command::new(env!("CARGO_BIN_EXE_cherry"))
            .args(["--host", "studio", "list", "--json"])
            .env("PATH", directory.path())
            .env("CHERRY_TEST_SSH_PID", &pid_file)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        let ssh_pid = loop {
            if let Ok(pid) = std::fs::read_to_string(&pid_file) {
                if let Ok(pid) = pid.parse::<i32>() {
                    break pid;
                }
            }
            assert!(Instant::now() < deadline, "SSH did not start");
            thread::sleep(Duration::from_millis(10));
        };
        assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGTERM) }, 0);
        assert_eq!(wait(&mut child).code(), Some(128 + libc::SIGTERM));
        assert_eq!(
            unsafe { libc::kill(ssh_pid, 0) },
            -1,
            "SSH child leaked after CLI termination"
        );
        assert_eq!(
            std::io::Error::last_os_error().raw_os_error(),
            Some(libc::ESRCH)
        );
    }
}

#[test]
fn pinned_host_mismatch_stops_before_sending_a_mutation() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(
            read_client(&mut stream).is_none(),
            "client sent a request to the wrong host"
        );
    });
    let output = command
        .args([
            "--expected-host-id",
            "12345678-1234-4234-8234-123456789abc",
            "kill",
            "test-session",
        ])
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("host identity changed"));
    server.join().unwrap();
}

#[test]
fn version_mismatches_name_both_versions() {
    for reply in [
        ServerMessage::Welcome {
            version: 99,
            host_id: "host-1".into(),
            build: None,
        },
        ServerMessage::error(
            "version_mismatch",
            "expected Cherry host protocol version 99",
        ),
    ] {
        let (_directory, listener, mut command) = listener();
        let server = thread::spawn(move || {
            let mut stream = accept_raw(listener);
            assert!(matches!(
                read_client(&mut stream),
                Some(ClientMessage::Hello { .. })
            ));
            write_frame(&mut stream, &reply).unwrap();
        });
        let output = command.arg("list").output().unwrap();
        assert_eq!(output.status.code(), Some(1));
        let error = String::from_utf8_lossy(&output.stderr);
        assert!(error.contains("version 99"), "{error}");
        assert!(
            error.contains(&format!("version {PROTOCOL_VERSION}")),
            "{error}"
        );
        server.join().unwrap();
    }
}

#[test]
fn remove_dispatches_a_retained_session_removal_request() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(
            matches!(read_client(&mut stream), Some(ClientMessage::Remove { id }) if id == "test-session")
        );
        write_frame(&mut stream, &ServerMessage::Ok).unwrap();
    });
    let output = command.args(["remove", "test-session"]).output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    server.join().unwrap();
}

#[test]
fn shutdown_dispatches_the_host_maintenance_request() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Shutdown)
        ));
        write_frame(&mut stream, &ServerMessage::Ok).unwrap();
    });
    let output = command.arg("shutdown").output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    server.join().unwrap();
}

#[test]
fn interrupting_kill_does_not_claim_the_session_survived() {
    let (_directory, listener, mut command) = listener();
    let (sent_tx, sent_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Kill { .. })
        ));
        sent_tx.send(()).unwrap();
        assert!(read_client(&mut stream).is_none());
    });
    let mut child = command
        .args(["kill", "test-session"])
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    sent_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGTERM) }, 0);
    assert_eq!(wait(&mut child).code(), Some(128 + libc::SIGTERM));
    let error = stderr_of(&mut child);
    assert!(
        error.contains("may already have reached the host"),
        "{error}"
    );
    assert!(!error.contains("not terminated"), "{error}");
    server.join().unwrap();
}

#[test]
fn kill_remove_and_shutdown_never_start_a_host_but_list_does() {
    let directory = private_directory();
    let log = directory.path().join("started");
    let host = directory.path().join("fake-cherry-host");
    script(
        &host,
        &format!(
            "printf '%s %s\\n' \"$*\" \"$(pwd -P)\" >> '{}'\nexit 3\n",
            log.display()
        ),
    );
    let socket = directory.path().join("state").join("host.sock");
    let cherry = || {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cherry"));
        command
            .arg("--socket")
            .arg(&socket)
            .env("CHERRY_HOST_PATH", &host)
            .stdin(Stdio::null());
        command
    };
    for arguments in [
        &["kill", "S"][..],
        &["remove", "S"],
        &["shutdown"],
        &["list", "--json", "--no-start"],
    ] {
        let output = cherry().args(arguments).output().unwrap();
        assert_eq!(output.status.code(), Some(1));
        let error = String::from_utf8_lossy(&output.stderr);
        assert!(
            error.contains("no cherry-host is running"),
            "{arguments:?}: {error}"
        );
        assert!(!log.exists(), "{arguments:?} started a host");
    }
    let output = cherry().arg("list").output().unwrap();
    assert_eq!(output.status.code(), Some(1));
    let error = String::from_utf8_lossy(&output.stderr);
    assert!(error.contains("cherry-host start failed"), "{error}");
    assert_eq!(
        std::fs::read_to_string(&log).unwrap(),
        format!("start --socket {} /\n", socket.display())
    );
}

#[test]
fn a_socket_in_a_directory_others_can_reach_is_never_used() {
    let directory = tempfile::tempdir().unwrap();
    std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o755)).unwrap();
    let socket = directory.path().join("host.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    let log = directory.path().join("started");
    let host = directory.path().join("fake-cherry-host");
    script(
        &host,
        &format!("echo started > '{}'\nexit 1\n", log.display()),
    );
    let output = Command::new(env!("CARGO_BIN_EXE_cherry"))
        .arg("--socket")
        .arg(&socket)
        .arg("list")
        .env("CHERRY_HOST_PATH", &host)
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    let error = String::from_utf8_lossy(&output.stderr);
    assert!(error.contains("refusing to use host socket"), "{error}");
    assert!(error.contains("CHERRY_HOST_SOCKET"), "{error}");
    assert!(
        matches!(listener.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
    );
    assert!(!log.exists());
}

#[test]
fn a_translocated_sibling_host_is_never_started() {
    let directory = tempfile::tempdir().unwrap();
    let bundle = directory
        .path()
        .join("AppTranslocation/0A1B2C/d/Cherry.app/Contents/MacOS");
    std::fs::create_dir_all(&bundle).unwrap();
    let cli = bundle.join("cherry");
    std::fs::copy(env!("CARGO_BIN_EXE_cherry"), &cli).unwrap();
    let log = directory.path().join("started");
    script(
        &bundle.join("cherry-host"),
        &format!("echo started > '{}'\n", log.display()),
    );
    let state = private_directory();
    let output = Command::new(&cli)
        .arg("--socket")
        .arg(state.path().join("host.sock"))
        .arg("list")
        .env_remove("CHERRY_HOST_PATH")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    let error = String::from_utf8_lossy(&output.stderr);
    assert!(error.contains("refusing to start cherry-host"), "{error}");
    assert!(error.contains("App Translocation"), "{error}");
    assert!(!log.exists());
}

#[test]
fn the_agent_link_follows_only_local_clients_that_create_or_attach_sessions() {
    let directory = private_directory();
    let socket = directory.path().join("host.sock");
    let link = directory.path().join("agent.sock");
    let agents = tempfile::tempdir().unwrap();
    let agent = |name: &str| {
        let path = agents.path().join(name);
        (UnixListener::bind(&path).unwrap(), path)
    };
    let (_first, first) = agent("agent.1");
    let (_second, second) = agent("agent.2");
    let (_third, third) = agent("agent.3");
    let run = |arguments: &[&str], agent: &Path| {
        let _ = std::fs::remove_file(&socket);
        let listener = UnixListener::bind(&socket).unwrap();
        listener.set_nonblocking(true).unwrap();
        let server = thread::spawn(move || {
            let mut stream = accept(listener);
            let reply = match read_client(&mut stream) {
                Some(ClientMessage::Create { .. }) => ServerMessage::Created { session: session() },
                Some(ClientMessage::List) => sessions_reply("host-1", vec![]),
                Some(ClientMessage::Kill { .. }) => ServerMessage::Ok,
                Some(ClientMessage::Attach { .. }) => {
                    write_frame(
                        &mut stream,
                        &ServerMessage::Attached {
                            reason: AttachReason::Attach,
                            session: session(),
                            offset: 0,
                            snapshot: Vec::new(),
                            refreshes: false,
                        },
                    )
                    .unwrap();
                    while !matches!(read_client(&mut stream), Some(ClientMessage::Detach)) {}
                    ServerMessage::Ok
                }
                other => panic!("unexpected {other:?}"),
            };
            write_frame(&mut stream, &reply).unwrap();
        });
        let output = Command::new(env!("CARGO_BIN_EXE_cherry"))
            .arg("--socket")
            .arg(&socket)
            .args(arguments)
            .env("CHERRY_HOST_PATH", "/nonexistent/cherry-host")
            .env_remove("CHERRY_SESSION_ID")
            .env("SSH_AUTH_SOCK", agent)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{arguments:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        server.join().unwrap();
        std::fs::read_link(&link).ok()
    };
    assert_eq!(run(&["new", "--cwd=/work"], &first), Some(first.clone()));
    // Listing or ending sessions (as Cherry does all the time) leaves the
    // agent of the client using them in place.
    assert_eq!(run(&["list"], &second), Some(first.clone()));
    assert_eq!(run(&["kill", "S"], &second), Some(first.clone()));
    assert_eq!(run(&["attach", "test-session"], &third), Some(third));
}

#[test]
fn an_encoded_detach_key_split_across_reads_is_never_forwarded() {
    for encoding in [b"\x1b[93;5u".as_slice(), b"\x1b[27;5;93~"] {
        let (_directory, listener, mut command) = listener();
        let server = thread::spawn(move || {
            let mut stream = accept_attach(listener, session(), b"ATTACHED-MARKER");
            // Nothing is forwarded: the next message is Detach itself.
            assert!(matches!(
                read_client(&mut stream),
                Some(ClientMessage::Detach)
            ));
            write_frame(&mut stream, &ServerMessage::Ok).unwrap();
        });
        let mut child = command
            .args(["attach", "test-session"])
            // Hold an unfinished sequence far longer than the gap below.
            .env("CHERRY_CLI_ESCAPE_WAIT_MS", "2000")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        // Only once the snapshot is out is the client reading its input, so
        // the two halves arrive in separate reads.
        let mut output = Collected::new(child.stdout.take().unwrap());
        output.expect(b"ATTACHED-MARKER");
        let mut stdin = child.stdin.take().unwrap();
        stdin.write_all(&encoding[..4]).unwrap();
        thread::sleep(Duration::from_millis(100));
        stdin.write_all(&encoding[4..]).unwrap();
        assert!(wait(&mut child).success(), "{}", stderr_of(&mut child));
        server.join().unwrap();
    }
}

#[test]
fn eof_forwards_an_unfinished_key_sequence_before_detaching() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, session(), b"");
        assert!(
            matches!(read_client(&mut stream), Some(ClientMessage::Input { data }) if data == b"\x1b[93;")
        );
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Detach)
        ));
    });
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(b"\x1b[93;").unwrap();
    drop(stdin);
    assert!(wait(&mut child).success());
    server.join().unwrap();
}

#[test]
fn output_keeps_flowing_while_a_large_paste_waits_for_the_host() {
    const PASTE: usize = 3 * 1024 * 1024;
    let (_directory, listener, mut command) = listener();
    let (seen_tx, seen_rx) = mpsc::channel::<()>();
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, session(), b"");
        stream
            .set_read_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        // Stream output without reading any input until the client showed
        // all of it, like a host whose program is not reading its paste.
        let mut offset = 0;
        for index in 0..64 {
            let mut data = format!("line {index}\r\n").into_bytes();
            if index == 63 {
                data.extend_from_slice(b"ALL-OUTPUT-SHOWN");
            }
            write_frame(
                &mut stream,
                &ServerMessage::Output {
                    offset,
                    data: data.clone(),
                },
            )
            .unwrap();
            offset += data.len() as u64;
            thread::sleep(Duration::from_millis(2));
        }
        seen_rx
            .recv_timeout(Duration::from_secs(20))
            .expect("output stalled behind input");
        let mut received = Vec::with_capacity(PASTE);
        loop {
            match read_client(&mut stream) {
                Some(ClientMessage::Input { data }) => received.extend(data),
                Some(ClientMessage::Detach) => break,
                Some(ClientMessage::Ping) => {}
                other => panic!("unexpected {other:?}"),
            }
        }
        assert_eq!(received.len(), PASTE);
        assert!(received
            .iter()
            .enumerate()
            .all(|(i, &byte)| byte == b'a' + (i % 26) as u8));
        write_frame(&mut stream, &ServerMessage::Ok).unwrap();
    });
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let written = Arc::new(AtomicUsize::new(0));
    let mut stdin = child.stdin.take().unwrap();
    let writer = {
        let written = written.clone();
        thread::spawn(move || {
            let paste: Vec<u8> = (0..PASTE).map(|i| b'a' + (i % 26) as u8).collect();
            for chunk in paste.chunks(16 * 1024) {
                stdin.write_all(chunk).unwrap();
                written.fetch_add(chunk.len(), Ordering::SeqCst);
            }
        })
    };
    let mut output = Collected::new(child.stdout.take().unwrap());
    output.expect(b"ALL-OUTPUT-SHOWN");
    // The client stopped reading its input at its own limit instead of
    // blocking the output behind it.
    thread::sleep(Duration::from_millis(200));
    let accepted = written.load(Ordering::SeqCst);
    assert!(
        accepted < 2 * 1024 * 1024,
        "client buffered {accepted} bytes of input"
    );
    seen_tx.send(()).unwrap();
    writer.join().unwrap();
    assert!(
        wait_within(&mut child, Duration::from_secs(20)).success(),
        "{}",
        stderr_of(&mut child)
    );
    server.join().unwrap();
}

#[test]
fn heartbeats_start_before_the_first_snapshot_and_continue_while_attached() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Attach { .. })
        ));
        // A large first snapshot can take longer than the interval to
        // arrive, and the host already expects heartbeats.
        let started = Instant::now();
        for _ in 0..2 {
            assert!(matches!(
                read_client(&mut stream),
                Some(ClientMessage::Ping)
            ));
        }
        assert!(started.elapsed() >= Duration::from_millis(300));
        write_frame(
            &mut stream,
            &ServerMessage::Attached {
                reason: AttachReason::Attach,
                session: session(),
                offset: 0,
                snapshot: Vec::new(),
                refreshes: false,
            },
        )
        .unwrap();
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Ping)
        ));
        write_frame(&mut stream, &ServerMessage::Pong).unwrap();
        write_frame(
            &mut stream,
            &ServerMessage::Exit {
                id: "test-session".into(),
                exit_code: 0,
                signal: None,
            },
        )
        .unwrap();
    });
    // Standard input stays open: its end would detach.
    let mut child = command
        .args(["attach", "test-session"])
        .env("CHERRY_CLI_HEARTBEAT_INTERVAL_MS", "200")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    assert!(wait(&mut child).success(), "{}", stderr_of(&mut child));
    server.join().unwrap();
}

#[test]
fn heartbeats_continue_while_a_slow_terminal_takes_a_large_snapshot() {
    const SNAPSHOT: usize = 1024 * 1024;
    let (_directory, listener, mut command) = listener();
    let (taken_tx, taken_rx) = mpsc::channel::<()>();
    let server = thread::spawn(move || {
        // The window has the session's size, so the snapshot is written as
        // it is, in one piece.
        let mut stream = accept_attach(
            listener,
            sized_session(DEFAULT_COLS, DEFAULT_ROWS),
            &vec![b'x'; SNAPSHOT],
        );
        stream
            .set_read_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        let (frames_tx, frames) = mpsc::channel();
        let mut reader = stream.try_clone().unwrap();
        thread::spawn(move || {
            while let Ok(Some(message)) = read_frame::<_, ClientMessage>(&mut reader) {
                if frames_tx.send(message).is_err() {
                    break;
                }
            }
        });
        // Pings while the terminal is still taking the snapshot.
        let mut pings = 0;
        while taken_rx.try_recv().is_err() {
            match frames.recv_timeout(Duration::from_millis(20)) {
                Ok(ClientMessage::Ping) => pings += 1,
                Ok(other) => panic!("unexpected {other:?}"),
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(error) => panic!("client went away: {error}"),
            }
        }
        write_frame(
            &mut stream,
            &ServerMessage::Exit {
                id: "test-session".into(),
                exit_code: 0,
                signal: None,
            },
        )
        .unwrap();
        pings
    });
    let mut child = command
        .args(["attach", "test-session"])
        .env("CHERRY_CLI_HEARTBEAT_INTERVAL_MS", "200")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    // A terminal on a slow link: 8 KiB every 20 ms, so the snapshot takes
    // about 2.5 s, many heartbeat intervals.
    let mut stdout = child.stdout.take().unwrap();
    let mut taken = 0;
    let mut buffer = [0u8; 8192];
    while taken < SNAPSHOT {
        thread::sleep(Duration::from_millis(20));
        let n = stdout.read(&mut buffer).unwrap();
        assert!(n > 0, "output ended after {taken} bytes");
        taken += n;
    }
    taken_tx.send(()).unwrap();
    let rest = thread::spawn(move || std::io::copy(&mut stdout, &mut std::io::sink()));
    let exit = wait_within(&mut child, Duration::from_secs(10));
    assert!(exit.success(), "{}", stderr_of(&mut child));
    rest.join().unwrap().unwrap();
    let pings = server.join().unwrap();
    assert!(pings >= 4, "{pings} Pings while the terminal was slow");
}

/// A paste larger than every buffer between the client and a host that is
/// not reading it.
fn paste_in_background(child: &mut Child) -> thread::JoinHandle<()> {
    let mut stdin = child.stdin.take().unwrap();
    thread::spawn(move || {
        let paste: Vec<u8> = (0..3 * 1024 * 1024)
            .map(|i| b'a' + (i % 26) as u8)
            .collect();
        // The client may give up and close its end first.
        let _ = stdin.write_all(&paste);
    })
}

#[test]
fn a_host_that_is_not_reading_input_stays_attached_while_its_output_arrives() {
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, session(), b"");
        stream
            .set_read_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        // Longer than the heartbeat timeout without reading any input, as
        // when the program is busy, but printing.
        for offset in 0..25 {
            write_frame(
                &mut stream,
                &ServerMessage::Output {
                    offset,
                    data: b".".to_vec(),
                },
            )
            .unwrap();
            thread::sleep(Duration::from_millis(100));
        }
        let mut received = 0;
        loop {
            match read_client(&mut stream) {
                Some(ClientMessage::Input { data }) => received += data.len(),
                Some(ClientMessage::Detach) => break,
                Some(ClientMessage::Ping) => {}
                other => panic!("unexpected {other:?}"),
            }
        }
        assert_eq!(received, 3 * 1024 * 1024);
        write_frame(&mut stream, &ServerMessage::Ok).unwrap();
    });
    let mut child = command
        .args([
            "attach",
            "test-session",
            "--detach-key",
            "none",
            "--status-file",
        ])
        .arg(&status)
        .env("CHERRY_CLI_HEARTBEAT_TIMEOUT_MS", "1000")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let writer = paste_in_background(&mut child);
    assert!(
        wait_within(&mut child, Duration::from_secs(20)).success(),
        "{}",
        stderr_of(&mut child)
    );
    writer.join().unwrap();
    server.join().unwrap();
    assert_eq!(read_status(&status)["outcome"], "detached");
}

#[test]
fn an_attachment_whose_host_neither_reads_nor_writes_is_given_up() {
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let (done_tx, done_rx) = mpsc::channel::<()>();
    let server = thread::spawn(move || {
        let stream = accept_attach(listener, session(), b"");
        let _ = done_rx.recv_timeout(Duration::from_secs(20));
        drop(stream);
    });
    let mut child = command
        .args([
            "attach",
            "test-session",
            "--detach-key",
            "none",
            "--status-file",
        ])
        .arg(&status)
        .env("CHERRY_CLI_HEARTBEAT_TIMEOUT_MS", "1000")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let writer = paste_in_background(&mut child);
    let started = Instant::now();
    assert_eq!(
        wait_within(&mut child, Duration::from_secs(10)).code(),
        Some(1)
    );
    assert!(started.elapsed() >= Duration::from_millis(900));
    let error = stderr_of(&mut child);
    assert!(error.contains("appears to be dead"), "{error}");
    done_tx.send(()).unwrap();
    writer.join().unwrap();
    server.join().unwrap();
    let status = read_status(&status);
    assert_eq!(status["outcome"], "disconnected");
    assert!(status["message"]
        .as_str()
        .unwrap()
        .contains("appears to be dead"));
}

#[test]
fn stalled_stdout_still_handles_sigterm_and_restores_tty_and_pipe_flags() {
    let (_directory, listener, mut command) = listener();
    let (ready_tx, ready_rx) = mpsc::channel();
    let (proceed_tx, proceed_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Attach { .. })
        ));
        ready_tx.send(()).unwrap();
        proceed_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        write_frame(
            &mut stream,
            &ServerMessage::Attached {
                reason: AttachReason::Attach,
                session: session(),
                offset: 0,
                snapshot: vec![b'x'; 262_144],
                refreshes: false,
            },
        )
        .unwrap();
        assert!(read_client(&mut stream).is_none());
    });
    // The window matches the session, so the snapshot is written as is.
    let pty = Pty::open(120, 32);
    let original = pty.termios();
    let mut descriptors = [-1; 2];
    assert_eq!(unsafe { libc::pipe(descriptors.as_mut_ptr()) }, 0);
    for fd in descriptors {
        assert_eq!(
            unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) },
            0
        );
    }
    let _reader = unsafe { File::from_raw_fd(descriptors[0]) };
    let mut writer = unsafe { File::from_raw_fd(descriptors[1]) };
    // Darwin adds a kernel bookkeeping flag on the first successful write.
    // Prime that independently, so equality checks only this client's changes.
    writer.write_all(b"x").unwrap();
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(writer.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    ready_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    // Snapshot before TerminalOutput changes the descriptor flags.
    let flags = unsafe { libc::fcntl(writer.as_raw_fd(), libc::F_GETFL) };
    proceed_tx.send(()).unwrap();
    pty.wait_for_raw_mode();
    // Never consume stdout. The snapshot is larger than the pipe's capacity.
    thread::sleep(Duration::from_millis(50));
    let signalled = Instant::now();
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGTERM) }, 0);
    assert_eq!(wait(&mut child).code(), Some(128 + libc::SIGTERM));
    assert!(
        signalled.elapsed() < Duration::from_secs(2),
        "signal cleanup waited for stdout to drain"
    );
    assert_eq!(
        pty.termios().c_lflag & !libc::PENDIN,
        original.c_lflag & !libc::PENDIN
    );
    assert_eq!(
        unsafe { libc::fcntl(writer.as_raw_fd(), libc::F_GETFL) },
        flags,
        "pipe flags leaked to the invoking process"
    );
    server.join().unwrap();
}

#[test]
fn redirected_regular_file_preserves_append_mode_and_has_no_screen_cleanup() {
    let (directory, listener, mut command) = listener();
    let file_path = directory.path().join("output");
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&file_path)
        .unwrap();
    file.write_all(b"existing:").unwrap();
    let (ready_tx, ready_rx) = mpsc::channel();
    let (proceed_tx, proceed_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Attach { .. })
        ));
        ready_tx.send(()).unwrap();
        proceed_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        write_frame(
            &mut stream,
            &ServerMessage::Attached {
                reason: AttachReason::Attach,
                session: session(),
                offset: 0,
                snapshot: b"snapshot".to_vec(),
                refreshes: false,
            },
        )
        .unwrap();
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Detach)
        ));
    });
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(Stdio::null())
        .stdout(file.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    ready_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let flags = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFL) };
    proceed_tx.send(()).unwrap();
    assert!(wait(&mut child).success());
    assert_eq!(std::fs::read(&file_path).unwrap(), b"existing:snapshot");
    assert_eq!(
        unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFL) },
        flags
    );
    server.join().unwrap();
}

#[test]
fn detaching_a_tui_resets_keyboard_cursor_scroll_region_and_charsets() {
    let (_directory, listener, mut command) = listener();
    // Origin mode in a scroll region leaves the cursor at row 11, column 7.
    let enabled_modes = concat!(
        "\x1b[>1u\x1b[>3u\x1b[>4;2m\x1b[?1h\x1b=\x1b[?1004h\x1b[2;20r\x1b(0\x1b[?5h",
        "\x1b[?6h\x1b[?2031h\x1b[?9h\x1b[?67h\x1b[20h\x1b[10;7H"
    )
    .as_bytes();
    let (ready_tx, ready_rx) = mpsc::channel();
    let (proceed_tx, proceed_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Attach { .. })
        ));
        ready_tx.send(()).unwrap();
        proceed_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        write_frame(
            &mut stream,
            &ServerMessage::Attached {
                reason: AttachReason::Attach,
                session: session(),
                offset: 0,
                snapshot: enabled_modes.to_vec(),
                refreshes: false,
            },
        )
        .unwrap();
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Detach)
        ));
    });
    // The same size as the session: the snapshot passes through unchanged.
    let mut pty = Pty::open(120, 32);
    pty.slave.write_all(b"x").unwrap();
    pty.master.read_exact(&mut [0u8; 1]).unwrap();
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    ready_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let original_flags = unsafe { libc::fcntl(pty.slave.as_raw_fd(), libc::F_GETFL) };
    proceed_tx.send(()).unwrap();
    pty.wait_for_raw_mode();
    pty.master.write_all(&[0x1d]).unwrap();
    assert!(wait(&mut child).success());
    assert_eq!(
        unsafe { libc::fcntl(pty.slave.as_raw_fd(), libc::F_GETFL) },
        original_flags
    );
    let received = pty.drain();
    assert!(received.starts_with(enabled_modes), "{received:?}");
    // Replay what the terminal received.
    let mut screen = cherry_vt::Terminal::new(120, 32, 0).unwrap();
    screen.feed(&received);
    let restored = screen.inspect().unwrap();
    assert_eq!(restored.cursor, (6, 10), "the cursor moved");
    assert!(restored.modes.is_empty(), "{:?}", restored.modes);
    assert_eq!(restored.kitty_flags, 0);
    assert!(!restored.state.contains(">4;2m"), "{:?}", restored.state);
    // Neither the old scroll region nor origin mode shifts the next program.
    screen.feed(b"\x1b[5;10r\x1b[1;1H\x1b[<u");
    let next = screen.inspect().unwrap();
    assert_eq!(next.cursor, (0, 0));
    assert_eq!(next.kitty_flags, 0);
    server.join().unwrap();
}

#[test]
fn leaving_a_session_that_enabled_no_reports_sends_no_query() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        // Bracketed paste and the alternate screen: nothing that reports.
        let mut stream = accept_attach(listener, session(), b"\x1b[?2004h\x1b[?1049hplain");
        loop {
            match read_client(&mut stream) {
                Some(ClientMessage::Detach) => break,
                Some(ClientMessage::Ping) => {}
                other => panic!("unexpected {other:?}"),
            }
        }
        write_frame(&mut stream, &ServerMessage::Ok).unwrap();
    });
    let mut pty = Pty::open(120, 32);
    let mut child = command
        .args(["attach", "test-session"])
        // A query would wait for an answer far longer than the test.
        .env("CHERRY_CLI_REPORT_WAIT_MS", "60000")
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    pty.wait_for_raw_mode();
    pty.master.write_all(&[0x1d]).unwrap();
    let exit = wait(&mut child);
    assert!(exit.success(), "{}", stderr_of(&mut child));
    server.join().unwrap();
    let received = pty.drain();
    let reset = received
        .windows(8)
        .position(|bytes| bytes == b"\x1b[?2004l")
        .expect("bracketed paste turned off");
    assert!(
        !contains(&received[reset..], b"\x1b[c"),
        "{:?}",
        String::from_utf8_lossy(&received[reset..])
    );
}

/// Kills the process when the test ends, also when an assertion fails.
struct Reaped(Child);

impl Drop for Reaped {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// What the next program to read `terminal` would get: its pending input.
fn pending_input(terminal: &File) -> Vec<u8> {
    let fd = terminal.as_raw_fd();
    let mut mode = unsafe { std::mem::zeroed::<libc::termios>() };
    assert_eq!(unsafe { libc::tcgetattr(fd, &mut mode) }, 0);
    unsafe { libc::cfmakeraw(&mut mode) };
    mode.c_cc[libc::VMIN] = 0;
    mode.c_cc[libc::VTIME] = 0;
    assert_eq!(unsafe { libc::tcsetattr(fd, libc::TCSANOW, &mode) }, 0);
    let mut buffer = [0u8; 4096];
    let n = unsafe { libc::read(fd, buffer.as_mut_ptr().cast(), buffer.len()) };
    assert!(n >= 0, "{}", std::io::Error::last_os_error());
    buffer[..n as usize].to_vec()
}

/// Whether this process's controlling terminal accepts TIOCSTI. Linux can
/// refuse it (dev.tty.legacy_tiocsti).
fn tiocsti_allowed() -> bool {
    cfg!(target_os = "macos")
        || std::fs::read_to_string("/proc/sys/dev/tty/legacy_tiocsti")
            .map_or(true, |value| value.trim() == "1")
}

#[test]
fn reports_the_terminal_sends_while_detaching_never_reach_the_shell() {
    // Any-motion mouse tracking and focus reports, with each mouse encoding:
    // SGR, one byte per coordinate (0x80 and above past column 95), and
    // UTF-8. Mouse reports while the host confirms, then after the reset.
    let variants: [(&[u8], &[u8], &[u8]); 3] = [
        (
            b"\x1b[?1006h",
            b"\x1b[<35;10;5M\x1b[Ol\x1b[<35;11;5Ms",
            b"\x1b[<35;12;5M",
        ),
        (b"", b"\x1b[MC\x84%\x1b[Ol\x1b[MC\x85%s", b"\x1b[MC\x86%"),
        (
            b"\x1b[?1005h",
            b"\x1b[MC\xc2\x84%\x1b[Ol\x1b[MC\xc2\x85%s",
            b"\x1b[MC\xc2\x86%",
        ),
    ];
    for (encoding, while_detaching, after_reset) in variants {
        let snapshot = [b"\x1b[?1003h\x1b[?1004h", encoding, b"ready"].concat();
        let left = detach_with_reports(&snapshot, while_detaching, after_reset);
        assert!(
            !contains(&left, b"\x1b") && !contains(&left, b"%"),
            "reports reached the shell with {encoding:?}: {:?}",
            String::from_utf8_lossy(&left)
        );
        // The keystrokes are the shell's.
        if tiocsti_allowed() {
            assert_eq!(left, b"ls", "{encoding:?}");
        } else {
            assert!(left.is_empty() || left == b"ls", "{left:?}");
        }
    }
}

/// Attach from a shell to a session whose `snapshot` enables reports,
/// press the detach key, send `while_detaching` from the terminal while the
/// host confirms and `after_reset` before answering the query that follows
/// the reset. Returns what is left in the terminal's input for the shell.
fn detach_with_reports(snapshot: &[u8], while_detaching: &[u8], after_reset: &[u8]) -> Vec<u8> {
    let (directory, listener, _) = listener();
    let socket = directory.path().join("host.sock");
    let exit_file = directory.path().join("exit");
    let (detaching_tx, detaching_rx) = mpsc::channel();
    let (typed_tx, typed_rx) = mpsc::channel::<()>();
    let snapshot = snapshot.to_vec();
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, session(), &snapshot);
        loop {
            match read_client(&mut stream) {
                Some(ClientMessage::Detach) => break,
                Some(ClientMessage::Ping) => {}
                other => panic!("unexpected {other:?}"),
            }
        }
        detaching_tx.send(()).unwrap();
        typed_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        write_frame(&mut stream, &ServerMessage::Ok).unwrap();
    });
    // A shell whose terminal is the PTY: it runs the client, and stays until
    // the test has looked at what the client left in the terminal's input.
    let mut pty = Pty::open(120, 32);
    let mut shell = Command::new("/bin/sh");
    shell
        .args(["-c", r#""$@"; echo $? > "$0"; exec sleep 30"#])
        .arg(&exit_file)
        .arg(env!("CARGO_BIN_EXE_cherry"))
        .arg("--socket")
        .arg(&socket)
        .args(["attach", "test-session"])
        // The answer ends the wait; the test is never that slow to answer.
        .env("CHERRY_CLI_REPORT_WAIT_MS", "10000")
        .env("CHERRY_HOST_PATH", "/nonexistent/cherry-host")
        .env_remove("CHERRY_SESSION_ID")
        .env_remove("SSH_AUTH_SOCK")
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::null());
    unsafe {
        shell.pre_exec(|| {
            if libc::setsid() < 0 || libc::ioctl(0, libc::TIOCSCTTY as _, 0) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let _shell = Reaped(shell.spawn().unwrap());
    pty.wait_for_raw_mode();
    pty.master.write_all(&[0x1d]).unwrap();
    detaching_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    // While the host confirms, the mouse moves, the window loses focus, and
    // the user types to the shell.
    pty.master.write_all(while_detaching).unwrap();
    typed_tx.send(()).unwrap();
    // The reset is followed by a query. The terminal sends the reports it
    // generated before the reset took effect, then the answer.
    let mut received = Vec::new();
    let mut answered = false;
    let deadline = Instant::now() + Duration::from_secs(10);
    let code = loop {
        received.extend(pty.drain());
        if !answered && contains(&received, b"\x1b[c") {
            pty.master
                .write_all(&[after_reset, b"\x1b[I\x1b[?62;22c"].concat())
                .unwrap();
            answered = true;
        }
        if let Ok(code) = std::fs::read_to_string(&exit_file) {
            if code.ends_with('\n') {
                break code;
            }
        }
        assert!(Instant::now() < deadline, "client did not exit");
        thread::sleep(Duration::from_millis(10));
    };
    assert_eq!(code.trim(), "0");
    server.join().unwrap();
    assert!(answered, "{:?}", String::from_utf8_lossy(&received));
    let reset = received
        .windows(8)
        .position(|bytes| bytes == b"\x1b[?1003l")
        .expect("mouse tracking turned off");
    assert!(
        received[reset..].ends_with(b"\x1b[c"),
        "the query follows the reset: {:?}",
        String::from_utf8_lossy(&received[reset..])
    );
    pending_input(&pty.slave)
}

// Protocol 4: `cherry control`, replacing an older host, `new` metadata and
// `--ssh-control-path`.

fn encoded<T: cherry_protocol::Message>(message: &T) -> Vec<u8> {
    encode_frame(message).unwrap()
}

/// A frame around raw JSON, for messages no version knows yet.
fn raw_frame(json: &[u8]) -> Vec<u8> {
    [&(json.len() as u32).to_be_bytes()[..], json].concat()
}

/// The Welcome `cherry control` writes before anything the host sends.
fn welcome(host_id: &str) -> Vec<u8> {
    encoded(&ServerMessage::Welcome {
        version: PROTOCOL_VERSION,
        host_id: host_id.into(),
        build: None,
    })
}

/// The host's end of a connection the client closed: no further frame.
fn assert_client_closed(stream: &mut UnixStream) {
    let mut rest = Vec::new();
    stream.read_to_end(&mut rest).unwrap();
    assert!(rest.is_empty(), "client sent {rest:?}");
}

fn spawn_control(command: &mut Command) -> Child {
    command
        .arg("control")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

#[test]
fn control_writes_the_welcome_then_relays_frames_verbatim_both_ways() {
    let (_directory, listener, mut command) = listener();
    // Requests with and without ids, and one that only the host may judge.
    let requests = [
        encoded(&Request::new(Some(1), ClientMessage::Subscribe)),
        encoded(&Request::new(Some(u64::MAX), ClientMessage::List)),
        raw_frame(br#"{"op":"from_the_future","req":3,"x":[1,2]}"#),
        encoded(&ClientMessage::Ping),
    ]
    .concat();
    let replies = [
        encoded(&Response::new(Some(1), ServerMessage::Ok)),
        encoded(&ServerMessage::Event {
            event: SessionEvent::Bell {
                id: "test-session".into(),
            },
        }),
        encoded(&Response::new(
            Some(u64::MAX),
            sessions_reply("host-1", vec![session()]),
        )),
        raw_frame(br#"{"type":"from_the_future","req":3}"#),
        encoded(&ServerMessage::Pong),
    ]
    .concat();
    let (expected_requests, host_replies) = (requests.clone(), replies.clone());
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        let mut received = vec![0; expected_requests.len()];
        stream.read_exact(&mut received).unwrap();
        assert_eq!(received, expected_requests);
        stream.write_all(&host_replies).unwrap();
        // The app closing its input ends the connection.
        assert_client_closed(&mut stream);
    });
    let mut child = spawn_control(&mut command);
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(&requests).unwrap();
    let mut output = Collected::new(child.stdout.take().unwrap());
    let expected = [welcome("host-1"), replies].concat();
    output.expect(&expected);
    drop(stdin);
    let status = wait(&mut child);
    let error = stderr_of(&mut child);
    assert!(status.success(), "{error}");
    assert_eq!(error, "");
    assert_eq!(output.all(), expected, "standard output holds only frames");
    server.join().unwrap();
}

#[test]
fn control_sends_scripted_input_and_relays_the_answers_that_follow_its_end() {
    // Regular files, which Darwin's poll rejects, on both sides.
    let (directory, listener, mut command) = listener();
    let requests = [
        encoded(&Request::new(Some(7), ClientMessage::List)),
        encoded(&ClientMessage::Ping),
    ]
    .concat();
    let replies = [
        encoded(&Response::new(Some(7), sessions_reply("host-1", vec![]))),
        encoded(&ServerMessage::Pong),
    ]
    .concat();
    let (expected_requests, host_replies) = (requests.clone(), replies.clone());
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        // Everything, then the end of the input, before any answer.
        let mut received = Vec::new();
        stream.read_to_end(&mut received).unwrap();
        assert_eq!(received, expected_requests);
        stream.write_all(&host_replies).unwrap();
    });
    let input = directory.path().join("input");
    let output = directory.path().join("output");
    std::fs::write(&input, &requests).unwrap();
    let result = command
        .arg("control")
        .stdin(File::open(&input).unwrap())
        .stdout(File::create(&output).unwrap())
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert_eq!(
        std::fs::read(&output).unwrap(),
        [welcome("host-1"), replies].concat()
    );
    server.join().unwrap();
}

#[test]
fn control_moves_large_bursts_both_ways_at_once() {
    // Neither direction waits for the other: the host writes while the app
    // still sends, and each reads only after the other side wrote a lot.
    const FRAMES: usize = 64;
    let payload = alphabet(60 * 1024);
    let request = encoded(&Request::new(
        Some(1),
        ClientMessage::SendInput {
            id: "test-session".into(),
            data: payload.clone(),
        },
    ));
    let reply = encoded(&ServerMessage::Output {
        offset: 0,
        data: payload,
    });
    let (_directory, listener, mut command) = listener();
    let (expected, host_reply) = (request.clone(), reply.clone());
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        stream
            .set_read_timeout(Some(Duration::from_secs(30)))
            .unwrap();
        stream
            .set_write_timeout(Some(Duration::from_secs(30)))
            .unwrap();
        let mut writer = stream.try_clone().unwrap();
        let replies = thread::spawn(move || {
            for _ in 0..FRAMES {
                writer.write_all(&host_reply).unwrap();
            }
        });
        let mut received = vec![0; expected.len()];
        for _ in 0..FRAMES {
            stream.read_exact(&mut received).unwrap();
            assert!(received == expected, "request changed on the way");
        }
        replies.join().unwrap();
        assert_client_closed(&mut stream);
    });
    let mut child = spawn_control(&mut command);
    let mut stdin = child.stdin.take().unwrap();
    let sender = thread::spawn(move || {
        for _ in 0..FRAMES {
            stdin.write_all(&request).unwrap();
        }
    });
    let mut stdout = child.stdout.take().unwrap();
    let mut first = vec![0; welcome("host-1").len()];
    stdout.read_exact(&mut first).unwrap();
    assert_eq!(first, welcome("host-1"));
    let mut received = vec![0; reply.len()];
    for _ in 0..FRAMES {
        stdout.read_exact(&mut received).unwrap();
        assert!(received == reply, "reply changed on the way");
    }
    sender.join().unwrap();
    let status = wait_within(&mut child, Duration::from_secs(30));
    assert!(status.success(), "{}", stderr_of(&mut child));
    let mut rest = Vec::new();
    stdout.read_to_end(&mut rest).unwrap();
    assert!(rest.is_empty());
    server.join().unwrap();
}

#[test]
fn control_fails_when_the_host_closes_first_after_relaying_what_it_sent() {
    let (_directory, listener, mut command) = listener();
    let event = encoded(&ServerMessage::Event {
        event: SessionEvent::Resync,
    });
    let sent = event.clone();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        stream.write_all(&sent).unwrap();
    });
    let mut child = spawn_control(&mut command);
    let _stdin = child.stdin.take().unwrap();
    let output = Collected::new(child.stdout.take().unwrap());
    assert_eq!(wait(&mut child).code(), Some(1));
    let error = stderr_of(&mut child);
    assert_eq!(error, "cherry: host connection closed unexpectedly\n");
    assert_eq!(output.all(), [welcome("host-1"), event].concat());
    server.join().unwrap();
}

#[test]
fn control_ends_on_a_termination_signal() {
    let (_directory, listener, mut command) = listener();
    let (connected_tx, connected_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        connected_tx.send(()).unwrap();
        assert_client_closed(&mut stream);
    });
    let mut child = spawn_control(&mut command);
    let _stdin = child.stdin.take().unwrap();
    let mut output = Collected::new(child.stdout.take().unwrap());
    connected_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    output.expect(&welcome("host-1"));
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGTERM) }, 0);
    assert_eq!(wait(&mut child).code(), Some(128 + libc::SIGTERM));
    assert_eq!(output.all(), welcome("host-1"));
    server.join().unwrap();
}

/// A pipe for a child's standard output whose write end the test keeps as
/// well: file status flags belong to the open pipe, so the test sees the
/// flags the child leaves behind. Returns (reader, writer, flags).
fn output_pipe() -> (File, File, i32) {
    let mut descriptors = [-1; 2];
    assert_eq!(unsafe { libc::pipe(descriptors.as_mut_ptr()) }, 0);
    for fd in descriptors {
        assert_eq!(
            unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) },
            0
        );
    }
    let mut reader = unsafe { File::from_raw_fd(descriptors[0]) };
    let mut writer = unsafe { File::from_raw_fd(descriptors[1]) };
    // Darwin adds a kernel bookkeeping flag on the first successful write.
    writer.write_all(b"x").unwrap();
    reader.read_exact(&mut [0]).unwrap();
    let flags = unsafe { libc::fcntl(writer.as_raw_fd(), libc::F_GETFL) };
    assert_eq!(flags & libc::O_NONBLOCK, 0);
    (reader, writer, flags)
}

fn flags_of(file: &File) -> i32 {
    unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFL) }
}

#[test]
fn control_ends_quietly_when_the_app_closes_its_output_and_leaves_its_flags_alone() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Ping)
        ));
        write_frame(&mut stream, &ServerMessage::Pong).unwrap();
        assert_client_closed(&mut stream);
    });
    let (mut reader, writer, flags) = output_pipe();
    let mut child = command
        .arg("control")
        .stdin(Stdio::piped())
        .stdout(writer.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut first = vec![0; welcome("host-1").len()];
    reader.read_exact(&mut first).unwrap();
    assert_eq!(first, welcome("host-1"));
    // The app stops reading, while its input stays open; the Pong is the
    // next thing the client writes.
    drop(reader);
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(&encoded(&ClientMessage::Ping)).unwrap();
    let status = wait(&mut child);
    let error = stderr_of(&mut child);
    assert!(status.success(), "{error}");
    assert_eq!(error, "");
    assert_eq!(flags_of(&writer), flags, "O_NONBLOCK leaked to the app");
    server.join().unwrap();
}

#[test]
fn control_succeeds_when_a_host_never_closes_after_the_input_ended() {
    const QUIET: Duration = Duration::from_millis(500);
    let (_directory, listener, mut command) = listener();
    let (half_closed_tx, half_closed_rx) = mpsc::channel();
    let (done_tx, done_rx) = mpsc::channel::<()>();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Ping)
        ));
        write_frame(&mut stream, &ServerMessage::Pong).unwrap();
        // The app's end of input arrives as end of file ...
        assert_client_closed(&mut stream);
        half_closed_tx.send(()).unwrap();
        // ... but this host never closes its side.
        let _ = done_rx.recv();
    });
    let (mut reader, writer, flags) = output_pipe();
    let mut child = command
        .arg("control")
        .env("CHERRY_CLI_QUIET_WAIT_MS", QUIET.as_millis().to_string())
        .stdin(Stdio::piped())
        .stdout(writer.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(&encoded(&ClientMessage::Ping)).unwrap();
    let expected = [welcome("host-1"), encoded(&ServerMessage::Pong)].concat();
    let mut received = vec![0; expected.len()];
    reader.read_exact(&mut received).unwrap();
    assert_eq!(received, expected);
    let ended = Instant::now();
    drop(stdin);
    half_closed_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let status = wait(&mut child);
    let exited = Instant::now();
    let error = stderr_of(&mut child);
    assert!(status.success(), "{error}");
    assert_eq!(error, "");
    // Once nothing moved for the quiet wait, and not before.
    assert!(exited >= ended + QUIET, "{:?}", exited - ended);
    // Nothing else on standard output.
    assert_eq!(
        unsafe { libc::fcntl(reader.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK) },
        0
    );
    assert!(
        matches!(reader.read(&mut [0]), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock)
    );
    assert_eq!(flags_of(&writer), flags, "O_NONBLOCK leaked to the app");
    drop(done_tx);
    server.join().unwrap();
}

#[test]
fn control_writes_nothing_to_standard_output_when_it_cannot_connect() {
    // Answers that end the handshake, and what the error must say.
    let failures = [
        (
            Some("12345678-1234-4234-8234-123456789abc"),
            ServerMessage::Welcome {
                version: PROTOCOL_VERSION,
                host_id: "host-1".into(),
                build: None,
            },
            "host identity changed",
        ),
        (
            None,
            ServerMessage::Welcome {
                version: PROTOCOL_VERSION + 1,
                host_id: "host-1".into(),
                build: None,
            },
            "protocol version mismatch",
        ),
        // A host older than protocol 4 refuses the Hello outright.
        (
            None,
            ServerMessage::error(
                "version_mismatch",
                "expected Cherry host protocol version 3",
            ),
            "host rejected request (version_mismatch): expected Cherry host protocol version 3",
        ),
    ];
    for (expected_host_id, reply, message) in failures {
        let (_directory, listener, mut command) = listener();
        let server = thread::spawn(move || {
            let mut stream = accept_raw(listener);
            assert!(matches!(
                read_client(&mut stream),
                Some(ClientMessage::Hello { .. })
            ));
            write_frame(&mut stream, &reply).unwrap();
            // Nothing else, and certainly no Replace.
            assert_client_closed(&mut stream);
        });
        if let Some(id) = expected_host_id {
            command.args(["--expected-host-id", id]);
        }
        let output = command
            .arg("control")
            .stdin(Stdio::null())
            .output()
            .unwrap();
        let error = String::from_utf8_lossy(&output.stderr);
        assert_eq!(output.status.code(), Some(1), "{error}");
        assert!(output.stdout.is_empty(), "{message}");
        assert!(error.contains(message), "{error}");
        server.join().unwrap();
    }

    // No host, and none can be started.
    let directory = private_directory();
    let output = Command::new(env!("CARGO_BIN_EXE_cherry"))
        .arg("--socket")
        .arg(directory.path().join("host.sock"))
        .arg("control")
        .env("CHERRY_HOST_PATH", "/nonexistent/cherry-host")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    assert!(String::from_utf8_lossy(&output.stderr).contains("could not start"));

    // Usage errors.
    for arguments in [
        &["control", "extra"][..],
        &["--ssh-control-path", "/tmp/cp", "control"],
        &["--host", "studio", "--ssh-control-path", "cp", "control"],
    ] {
        let output = Command::new(env!("CARGO_BIN_EXE_cherry"))
            .args(arguments)
            .env("PATH", "/nonexistent")
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(2), "{arguments:?}");
        assert!(output.stdout.is_empty(), "{arguments:?}");
    }
}

#[test]
fn control_lends_the_agent_while_it_is_connected() {
    let (directory, listener, mut command) = listener();
    let agents = tempfile::tempdir().unwrap();
    let agent = agents.path().join("agent");
    let _agent = UnixListener::bind(&agent).unwrap();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert_client_closed(&mut stream);
    });
    let mut child = spawn_control(command.env("SSH_AUTH_SOCK", &agent));
    let stdin = child.stdin.take().unwrap();
    let mut output = Collected::new(child.stdout.take().unwrap());
    output.expect(&welcome("host-1"));
    assert_eq!(
        std::fs::read_link(directory.path().join("agent.sock")).ok(),
        Some(agent)
    );
    drop(stdin);
    assert!(wait(&mut child).success(), "{}", stderr_of(&mut child));
    server.join().unwrap();
}

/// A fake ssh for successive connections: run N logs its arguments to
/// `arguments.N`, prints `streams[N - 1]` and saves its input, once that
/// ends, to `input.N`.
fn scripted_ssh(directory: &Path, streams: &[Vec<u8>]) {
    for (index, stream) in streams.iter().enumerate() {
        std::fs::write(directory.join(format!("stream.{}", index + 1)), stream).unwrap();
    }
    script(
        &directory.join("ssh"),
        &format!(
            "d='{}'\nn=$(( $(/bin/cat \"$d/count\" 2>/dev/null || echo 0) + 1 ))\necho \"$n\" > \"$d/count\"\nprintf '%s\\n' \"$@\" > \"$d/arguments.$n\"\n/bin/cat \"$d/stream.$n\"\n/bin/cat > \"$d/input.$n.tmp\"\n/bin/mv \"$d/input.$n.tmp\" \"$d/input.$n\"\n",
            directory.display()
        ),
    );
}

fn read_when_written(path: &Path) -> Vec<u8> {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Ok(bytes) = std::fs::read(path) {
            return bytes;
        }
        assert!(Instant::now() < deadline, "{} not written", path.display());
        thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn control_over_ssh_relays_what_follows_the_gateway_preamble_and_forwards_the_agent() {
    let directory = tempfile::tempdir().unwrap();
    let event = encoded(&ServerMessage::Event {
        event: SessionEvent::Removed { id: "gone".into() },
    });
    let pong = encoded(&ServerMessage::Pong);
    scripted_ssh(
        directory.path(),
        &[[
            b"Welcome to devbox\r\n".as_slice(),
            format!("CHERRY-GATEWAY {PROTOCOL_VERSION}\n").as_bytes(),
            &frames(&[ServerMessage::Welcome {
                version: PROTOCOL_VERSION,
                host_id: "remote".into(),
                build: None,
            }]),
            &event,
            &pong,
        ]
        .concat()],
    );
    let ping = encoded(&ClientMessage::Ping);
    let mut child = Command::new(env!("CARGO_BIN_EXE_cherry"))
        .args([
            "--host",
            "devbox",
            "--ssh-control-path",
            "/tmp/cherry-cp/%h",
            "control",
        ])
        .env("PATH", directory.path())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(&ping).unwrap();
    let output = Collected::new(child.stdout.take().unwrap());
    assert!(wait(&mut child).success(), "{}", stderr_of(&mut child));
    assert_eq!(output.all(), [welcome("remote"), event, pong].concat());
    assert_eq!(
        read_when_written(&directory.path().join("input.1")),
        [encoded(&ClientMessage::hello()), ping].concat()
    );
    // Batch mode (standard input carries frames, not answers to prompts),
    // with the agent forwarded as configured: no -a.
    assert_eq!(
        std::fs::read_to_string(directory.path().join("arguments.1")).unwrap(),
        "-T\n-o\nControlMaster=no\n-o\nControlPath=/tmp/cherry-cp/%%h\n-o\nRemoteCommand=none\n-o\nClearAllForwardings=yes\n-o\nPermitLocalCommand=no\n-o\nServerAliveInterval=15\n-o\nServerAliveCountMax=3\n-o\nBatchMode=yes\n-o\nConnectTimeout=10\n--\ndevbox\ncherry-host gateway\n"
    );
}

#[test]
fn a_master_connection_that_refuses_the_session_is_passed_over_for_a_direct_one() {
    // sshd allows 10 sessions per connection by default (MaxSessions); a
    // full master makes ssh refuse the session and exit. The CLI then
    // connects again without the ControlPath.
    let directory = tempfile::tempdir().unwrap();
    std::fs::write(
        directory.path().join("stream.2"),
        [
            format!("CHERRY-GATEWAY {PROTOCOL_VERSION}\n").into_bytes(),
            welcome("remote"),
            encoded(&ServerMessage::Pong),
        ]
        .concat(),
    )
    .unwrap();
    script(
        &directory.path().join("ssh"),
        &format!(
            "d='{}'\nn=$(( $(/bin/cat \"$d/count\" 2>/dev/null || echo 0) + 1 ))\necho \"$n\" > \"$d/count\"\nprintf '%s\\n' \"$@\" > \"$d/arguments.$n\"\nif [ \"$n\" = 1 ]; then echo 'mux_client_request_session: session request failed: Session open refused by peer' >&2; exit 255; fi\n/bin/cat \"$d/stream.$n\"\n/bin/cat > /dev/null\n",
            directory.path().display()
        ),
    );
    let mut child = Command::new(env!("CARGO_BIN_EXE_cherry"))
        .args([
            "--host",
            "devbox",
            "--ssh-control-path",
            "/tmp/cherry-cp/h",
            "control",
        ])
        .env("PATH", directory.path())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(&encoded(&ClientMessage::Ping))
        .unwrap();
    let output = Collected::new(child.stdout.take().unwrap());
    assert!(wait(&mut child).success(), "{}", stderr_of(&mut child));
    assert_eq!(
        output.all(),
        [welcome("remote"), encoded(&ServerMessage::Pong)].concat()
    );
    let first = std::fs::read_to_string(directory.path().join("arguments.1")).unwrap();
    let second = std::fs::read_to_string(directory.path().join("arguments.2")).unwrap();
    assert!(first.contains("ControlPath=/tmp/cherry-cp/h\n"), "{first}");
    assert!(!second.contains("ControlPath"), "{second}");
    assert!(second.contains("ControlMaster=no\n"), "{second}");
    assert!(!directory.path().join("arguments.3").exists());
}

#[test]
fn a_refused_session_without_a_control_path_is_not_tried_again() {
    let directory = tempfile::tempdir().unwrap();
    let count = directory.path().join("count");
    script(
        &directory.path().join("ssh"),
        &format!(
            "echo x >> '{}'\necho 'mux_client_request_session: session request failed: Session open refused by peer' >&2\nexit 255\n",
            count.display()
        ),
    );
    let output = Command::new(env!("CARGO_BIN_EXE_cherry"))
        .args(["--host", "devbox", "list"])
        .env("PATH", directory.path())
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert_eq!(std::fs::read_to_string(&count).unwrap(), "x\n");
}

#[test]
fn remote_host_path_reaches_the_gateway_command_of_every_ssh() {
    let directory = tempfile::tempdir().unwrap();
    let log = directory.path().join("arguments");
    script(
        &directory.path().join("ssh"),
        "printf '%s\\n' \"$@\" > \"$CHERRY_TEST_SSH_LOG\"\nexit 1\n",
    );
    for (arguments, gateway) in [
        (&["list", "--json"][..], "gateway"),
        (&["attach", "S"], "gateway"),
        (&["control"], "gateway"),
        (&["kill", "S"], "gateway --no-start"),
    ] {
        let output = Command::new(env!("CARGO_BIN_EXE_cherry"))
            .args([
                "--host",
                "studio",
                "--remote-host-path",
                "~/Library/Application Support/Cherry's/cherry-host",
            ])
            .args(arguments)
            .env("PATH", directory.path())
            .env("CHERRY_TEST_SSH_LOG", &log)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert!(!output.status.success());
        let logged = std::fs::read_to_string(&log).unwrap();
        assert!(
            logged.ends_with(&format!(
                "--\nstudio\n\"$HOME\"/'Library/Application Support/Cherry'\\''s/cherry-host' {gateway}\n"
            )),
            "{arguments:?}: {logged}"
        );
    }
}

#[test]
fn control_fails_once_writes_to_the_host_fail_after_relaying_what_it_sent() {
    // A connection whose far end stops taking bytes but never ends what it
    // sends: after the Hello, this ssh closes its input and keeps its output
    // open. Portable, unlike a socket shut down for reading.
    let directory = tempfile::tempdir().unwrap();
    let event = encoded(&ServerMessage::Event {
        event: SessionEvent::Resync,
    });
    let stream = directory.path().join("stream");
    std::fs::write(
        &stream,
        [
            format!("CHERRY-GATEWAY {PROTOCOL_VERSION}\n").as_bytes(),
            &welcome("remote"),
            &event,
        ]
        .concat(),
    )
    .unwrap();
    let closed = directory.path().join("closed");
    script(
        &directory.path().join("ssh"),
        &format!(
            "/bin/cat '{}'\n/bin/dd bs=1 count={} of=/dev/null 2>/dev/null\nexec 0<&-\n: > '{}'\nexec /bin/sleep 30\n",
            stream.display(),
            encoded(&ClientMessage::hello()).len(),
            closed.display()
        ),
    );
    let mut child = Command::new(env!("CARGO_BIN_EXE_cherry"))
        .args(["--host", "devbox", "control"])
        .env("PATH", directory.path())
        .env("CHERRY_CLI_CLOSED_WAIT_MS", "300")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut output = Collected::new(child.stdout.take().unwrap());
    output.expect(&[welcome("remote"), event.clone()].concat());
    read_when_written(&closed);
    // The app's input stays open; this request cannot be sent.
    stdin.write_all(&encoded(&ClientMessage::Ping)).unwrap();
    let status = wait(&mut child);
    assert_eq!(
        stderr_of(&mut child),
        "cherry: host connection closed unexpectedly (errors from ssh or cherry-host, if any, are shown above)\n"
    );
    assert_eq!(status.code(), Some(1));
    assert_eq!(output.all(), [welcome("remote"), event].concat());
}

#[test]
fn every_ssh_uses_the_control_path_with_percent_signs_doubled() {
    let directory = tempfile::tempdir().unwrap();
    let log = directory.path().join("arguments");
    script(
        &directory.path().join("ssh"),
        "printf '%s\\n' \"$@\" > \"$CHERRY_TEST_SSH_LOG\"\nexit 1\n",
    );
    for arguments in [
        &["list", "--json"][..],
        &["new", "--cwd=/work"],
        &["attach", "S"],
        &["kill", "S"],
        &["remove", "S"],
        &["shutdown"],
        &["control"],
    ] {
        let output = Command::new(env!("CARGO_BIN_EXE_cherry"))
            .args([
                "--host",
                "user@studio",
                "--ssh-control-path",
                "/tmp/cherry-501/%C-%h.%%",
            ])
            .args(arguments)
            .env("PATH", directory.path())
            .env("CHERRY_TEST_SSH_LOG", &log)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(1), "{arguments:?}");
        assert!(output.stdout.is_empty(), "{arguments:?}");
        let logged = std::fs::read_to_string(&log).unwrap();
        assert!(
            logged.starts_with(
                "-T\n-o\nControlMaster=no\n-o\nControlPath=/tmp/cherry-501/%%C-%%h.%%%%\n-o\nRemoteCommand=none\n"
            ),
            "{arguments:?}: {logged}"
        );
        assert_eq!(logged.matches("ControlPath").count(), 1, "{logged}");
    }
}

/// A fake `cherry-host` for `start --socket PATH`: it logs its arguments to
/// `log`, then waits for the test to listen at PATH, as a started host would.
fn fake_host_starter(directory: &Path, log: &Path) -> PathBuf {
    let host = directory.join("fake-cherry-host");
    script(
        &host,
        &format!(
            "printf '%s\\n' \"$*\" >> '{}'\ni=0\nwhile [ ! -S \"$3\" ] && [ $i -lt 1000 ]; do sleep 0.01; i=$((i + 1)); done\n",
            log.display()
        ),
    );
    host
}

/// An older host at `listener`: it welcomes the client, expects Replace, and
/// makes way as a host does (its socket gone before the Ok), or, unless it
/// `confirms`, as a host that made way for another client at the same time
/// (gone without answering). Then, once the client started "its" host, the
/// new host at the same path welcomes it with `version` and `serve` goes on.
fn older_host_making_way(
    listener: UnixListener,
    socket: PathBuf,
    started: PathBuf,
    confirms: bool,
    version: u32,
    serve: impl FnOnce(UnixStream) + Send + 'static,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let mut stream = accept_raw(listener);
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Hello {
                version: PROTOCOL_VERSION
            })
        ));
        write_frame(
            &mut stream,
            &ServerMessage::Welcome {
                version: PROTOCOL_VERSION - 1,
                host_id: "host-1".into(),
                build: None,
            },
        )
        .unwrap();
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Replace)
        ));
        std::fs::remove_file(&socket).unwrap();
        if confirms {
            write_frame(&mut stream, &ServerMessage::Ok).unwrap();
        }
        drop(stream);
        let deadline = Instant::now() + Duration::from_secs(5);
        while !started.exists() {
            assert!(Instant::now() < deadline, "the client started no host");
            thread::sleep(Duration::from_millis(5));
        }
        let listener = UnixListener::bind(&socket).unwrap();
        listener.set_nonblocking(true).unwrap();
        let mut stream = accept_raw(listener);
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Hello {
                version: PROTOCOL_VERSION
            })
        ));
        write_frame(
            &mut stream,
            &ServerMessage::Welcome {
                version,
                host_id: "host-1".into(),
                build: None,
            },
        )
        .unwrap();
        serve(stream);
    })
}

#[test]
fn an_older_host_makes_way_and_the_command_goes_on_with_the_host_it_starts() {
    let pong = encoded(&ServerMessage::Pong);
    for (arguments, confirms) in [
        (&["list", "--json"][..], true),
        (&["new", "--cwd=/work"], true),
        (&["attach", "test-session"], true),
        (&["control"], true),
        // The host made way for another client asking at the same moment.
        (&["list", "--json"], false),
        (&["control"], false),
    ] {
        let (directory, listener, mut command) = listener();
        let socket = directory.path().join("host.sock");
        let log = directory.path().join("started");
        let host = fake_host_starter(directory.path(), &log);
        let server = older_host_making_way(
            listener,
            socket.clone(),
            log.clone(),
            confirms,
            PROTOCOL_VERSION,
            |mut stream| {
                let reply = match read_client(&mut stream) {
                    Some(ClientMessage::List) => sessions_reply("host-1", vec![]),
                    Some(ClientMessage::Create { .. }) => {
                        ServerMessage::Created { session: session() }
                    }
                    Some(ClientMessage::Attach { .. }) => {
                        write_frame(
                            &mut stream,
                            &ServerMessage::Attached {
                                reason: AttachReason::Attach,
                                session: session(),
                                offset: 0,
                                snapshot: Vec::new(),
                                refreshes: false,
                            },
                        )
                        .unwrap();
                        while !matches!(read_client(&mut stream), Some(ClientMessage::Detach)) {}
                        ServerMessage::Ok
                    }
                    Some(ClientMessage::Ping) => {
                        write_frame(&mut stream, &ServerMessage::Pong).unwrap();
                        assert_client_closed(&mut stream);
                        return;
                    }
                    other => panic!("unexpected {other:?}"),
                };
                write_frame(&mut stream, &reply).unwrap();
            },
        );
        let mut child = command
            .args(arguments)
            .env("CHERRY_HOST_PATH", &host)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let mut stdin = child.stdin.take().unwrap();
        if arguments == ["control"] {
            stdin.write_all(&encoded(&ClientMessage::Ping)).unwrap();
        }
        drop(stdin);
        let output = Collected::new(child.stdout.take().unwrap());
        let status = wait(&mut child);
        assert!(status.success(), "{arguments:?}: {}", stderr_of(&mut child));
        let stdout = output.all();
        match arguments[0] {
            // Only the new host's Welcome.
            "control" => assert_eq!(stdout, [welcome("host-1"), pong.clone()].concat()),
            "list" => {
                let value: serde_json::Value = serde_json::from_slice(&stdout).unwrap();
                assert_eq!(value["host_id"], "host-1");
            }
            "new" => {
                let value: serde_json::Value = serde_json::from_slice(&stdout).unwrap();
                assert_eq!(value["id"], "test-session");
            }
            _ => {}
        }
        assert_eq!(
            std::fs::read_to_string(&log).unwrap(),
            format!("start --socket {}\n", socket.display()),
            "{arguments:?}"
        );
        server.join().unwrap();
    }
}

#[test]
fn a_host_started_in_place_of_an_older_one_is_not_replaced_again() {
    let (directory, listener, mut command) = listener();
    let socket = directory.path().join("host.sock");
    let log = directory.path().join("started");
    let host = fake_host_starter(directory.path(), &log);
    let server = older_host_making_way(
        listener,
        socket,
        log,
        true,
        PROTOCOL_VERSION - 1,
        |mut stream| assert_client_closed(&mut stream),
    );
    let output = command
        .arg("control")
        .env("CHERRY_HOST_PATH", &host)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    let error = String::from_utf8_lossy(&output.stderr);
    assert!(
        error.contains(&format!(
            "the cherry-host speaking protocol {} was asked to make way, but the host answering now speaks protocol {}, not {PROTOCOL_VERSION}",
            PROTOCOL_VERSION - 1,
            PROTOCOL_VERSION - 1
        )),
        "{error}"
    );
    server.join().unwrap();
}

#[test]
fn replacing_an_older_host_and_connecting_again_share_one_deadline() {
    // The older host takes half the limit to make way, and the host started
    // in its place never answers. Connecting again gets what is left, not a
    // limit of its own, which would take one and a half limits in all.
    const LIMIT: Duration = Duration::from_secs(5);
    let (directory, listener, mut command) = listener();
    let socket = directory.path().join("host.sock");
    let log = directory.path().join("started");
    let host = fake_host_starter(directory.path(), &log);
    let (done_tx, done_rx) = mpsc::channel::<()>();
    let started = log.clone();
    let server = thread::spawn(move || {
        let mut stream = accept_raw(listener);
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Hello { .. })
        ));
        write_frame(
            &mut stream,
            &ServerMessage::Welcome {
                version: PROTOCOL_VERSION - 1,
                host_id: "host-1".into(),
                build: None,
            },
        )
        .unwrap();
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Replace)
        ));
        std::fs::remove_file(&socket).unwrap();
        thread::sleep(LIMIT / 2);
        write_frame(&mut stream, &ServerMessage::Ok).unwrap();
        drop(stream);
        while !started.exists() {
            if !matches!(done_rx.try_recv(), Err(mpsc::TryRecvError::Empty)) {
                return Vec::new();
            }
            thread::sleep(Duration::from_millis(5));
        }
        let listener = UnixListener::bind(&socket).unwrap();
        listener.set_nonblocking(true).unwrap();
        let mut accepted = Vec::new();
        while matches!(done_rx.try_recv(), Err(mpsc::TryRecvError::Empty)) {
            if let Ok((stream, _)) = listener.accept() {
                accepted.push(stream);
            }
            thread::sleep(Duration::from_millis(5));
        }
        accepted
    });
    let began = Instant::now();
    let output = command
        .arg("control")
        .env("CHERRY_HOST_PATH", &host)
        .env(
            "CHERRY_CLI_CONNECT_TIMEOUT_MS",
            LIMIT.as_millis().to_string(),
        )
        .stdin(Stdio::null())
        .output()
        .unwrap();
    let elapsed = began.elapsed();
    drop(done_tx);
    let accepted = server.join().unwrap();
    let error = String::from_utf8_lossy(&output.stderr);
    assert_eq!(output.status.code(), Some(1), "{error}");
    assert!(output.stdout.is_empty());
    assert!(
        error.contains(&format!(
            "the cherry-host speaking protocol {} was asked to make way, but no cherry-host speaking protocol {PROTOCOL_VERSION} could be reached: timed out waiting for host",
            PROTOCOL_VERSION - 1
        )),
        "{error}"
    );
    assert!(elapsed >= LIMIT, "{elapsed:?}");
    assert!(elapsed < LIMIT + LIMIT / 2, "{elapsed:?}");
    // The new host got a Hello and nothing else.
    let [mut stream] = <[UnixStream; 1]>::try_from(accepted).unwrap();
    stream.set_nonblocking(false).unwrap();
    assert!(matches!(
        read_client(&mut stream),
        Some(ClientMessage::Hello { .. })
    ));
    assert_client_closed(&mut stream);
}

#[test]
fn kill_remove_and_shutdown_never_replace_an_older_host() {
    for arguments in [&["kill", "S"][..], &["remove", "S"], &["shutdown"]] {
        let (directory, listener, mut command) = listener();
        let log = directory.path().join("started");
        let host = fake_host_starter(directory.path(), &log);
        let server = thread::spawn(move || {
            let mut stream = accept_raw(listener);
            assert!(matches!(
                read_client(&mut stream),
                Some(ClientMessage::Hello { .. })
            ));
            write_frame(
                &mut stream,
                &ServerMessage::Welcome {
                    version: PROTOCOL_VERSION - 1,
                    host_id: "host-1".into(),
                    build: None,
                },
            )
            .unwrap();
            assert_client_closed(&mut stream);
        });
        let output = command
            .args(arguments)
            .env("CHERRY_HOST_PATH", &host)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(1), "{arguments:?}");
        let error = String::from_utf8_lossy(&output.stderr);
        assert!(
            error.contains(&format!(
                "cherry-host speaks version {}, this cherry speaks version {PROTOCOL_VERSION}; this command never replaces a host",
                PROTOCOL_VERSION - 1
            )),
            "{arguments:?}: {error}"
        );
        assert!(!log.exists(), "{arguments:?} started a host");
        server.join().unwrap();
    }
}

#[test]
fn an_older_host_that_refuses_to_make_way_is_reported_and_left_alone() {
    for arguments in [&["list"][..], &["new", "--cwd=/work"], &["control"]] {
        let (directory, listener, mut command) = listener();
        let log = directory.path().join("started");
        let host = fake_host_starter(directory.path(), &log);
        let server = thread::spawn(move || {
            let mut stream = accept_raw(listener);
            assert!(matches!(
                read_client(&mut stream),
                Some(ClientMessage::Hello { .. })
            ));
            write_frame(
                &mut stream,
                &ServerMessage::Welcome {
                    version: PROTOCOL_VERSION - 1,
                    host_id: "host-1".into(),
                    build: None,
                },
            )
            .unwrap();
            assert!(matches!(
                read_client(&mut stream),
                Some(ClientMessage::Replace)
            ));
            write_frame(
                &mut stream,
                &ServerMessage::error("request_failed", "host still owns running sessions"),
            )
            .unwrap();
        });
        let output = command
            .args(arguments)
            .env("CHERRY_HOST_PATH", &host)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        let error = String::from_utf8_lossy(&output.stderr);
        assert_eq!(output.status.code(), Some(1), "{arguments:?}: {error}");
        assert!(output.stdout.is_empty(), "{arguments:?}");
        assert!(
            error.contains(&format!(
                "could not replace the cherry-host speaking protocol {} (this cherry speaks protocol {PROTOCOL_VERSION}): host rejected request (request_failed): host still owns running sessions",
                PROTOCOL_VERSION - 1
            )),
            "{arguments:?}: {error}"
        );
        assert!(!log.exists(), "{arguments:?} started a host");
        server.join().unwrap();
    }
}

#[test]
fn newer_hosts_and_other_hosts_are_never_replaced() {
    for (version, expected_host_id, message) in [
        (PROTOCOL_VERSION + 1, None, "protocol version mismatch"),
        (
            PROTOCOL_VERSION - 1,
            Some("12345678-1234-4234-8234-123456789abc"),
            "host identity changed",
        ),
    ] {
        for arguments in [&["list"][..], &["attach", "S"], &["control"]] {
            let (_directory, listener, mut command) = listener();
            let server = thread::spawn(move || {
                let mut stream = accept_raw(listener);
                assert!(matches!(
                    read_client(&mut stream),
                    Some(ClientMessage::Hello { .. })
                ));
                write_frame(
                    &mut stream,
                    &ServerMessage::Welcome {
                        version,
                        host_id: "host-1".into(),
                        build: None,
                    },
                )
                .unwrap();
                assert_client_closed(&mut stream);
            });
            if let Some(id) = expected_host_id {
                command.args(["--expected-host-id", id]);
            }
            let output = command
                .args(arguments)
                .stdin(Stdio::null())
                .output()
                .unwrap();
            let error = String::from_utf8_lossy(&output.stderr);
            assert_eq!(output.status.code(), Some(1), "{arguments:?}: {error}");
            assert!(error.contains(message), "{arguments:?}: {error}");
            assert!(output.stdout.is_empty(), "{arguments:?}");
            server.join().unwrap();
        }
    }
}

#[test]
fn an_older_host_behind_a_gateway_makes_way_and_the_next_gateway_starts_a_new_one() {
    let older = |then: &ServerMessage| {
        [
            format!("CHERRY-GATEWAY {PROTOCOL_VERSION}\n").into_bytes(),
            frames(&[
                ServerMessage::Welcome {
                    version: PROTOCOL_VERSION - 1,
                    host_id: "remote".into(),
                    build: None,
                },
                then.clone(),
            ]),
        ]
        .concat()
    };
    let current = |then: &ServerMessage| {
        [
            format!("CHERRY-GATEWAY {PROTOCOL_VERSION}\n").into_bytes(),
            frames(&[
                ServerMessage::Welcome {
                    version: PROTOCOL_VERSION,
                    host_id: "remote".into(),
                    build: None,
                },
                then.clone(),
            ]),
        ]
        .concat()
    };
    let sessions = sessions_reply("remote", vec![]);
    for (arguments, reply, request) in [
        (&["list", "--json"][..], sessions, ClientMessage::List),
        (&["control"], ServerMessage::Pong, ClientMessage::Ping),
    ] {
        let directory = tempfile::tempdir().unwrap();
        scripted_ssh(
            directory.path(),
            &[older(&ServerMessage::Ok), current(&reply)],
        );
        let mut child = Command::new(env!("CARGO_BIN_EXE_cherry"))
            .args(["--host", "devbox"])
            .args(arguments)
            .env("PATH", directory.path())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let mut stdin = child.stdin.take().unwrap();
        if arguments == ["control"] {
            stdin.write_all(&encoded(&request)).unwrap();
        }
        drop(stdin);
        let output = Collected::new(child.stdout.take().unwrap());
        assert!(
            wait(&mut child).success(),
            "{arguments:?}: {}",
            stderr_of(&mut child)
        );
        let stdout = output.all();
        if arguments == ["control"] {
            assert_eq!(stdout, [welcome("remote"), encoded(&reply)].concat());
        } else {
            let value: serde_json::Value = serde_json::from_slice(&stdout).unwrap();
            assert_eq!(value["host_id"], "remote");
        }
        let path = |name: &str| directory.path().join(name);
        assert_eq!(
            read_when_written(&path("input.1")),
            [
                encoded(&ClientMessage::hello()),
                encoded(&ClientMessage::Replace)
            ]
            .concat()
        );
        assert_eq!(
            read_when_written(&path("input.2")),
            [encoded(&ClientMessage::hello()), encoded(&request)].concat()
        );
        // The same gateway both times; it may start a host.
        let first = std::fs::read_to_string(path("arguments.1")).unwrap();
        assert!(
            first.ends_with("--\ndevbox\ncherry-host gateway\n"),
            "{first}"
        );
        assert_eq!(std::fs::read_to_string(path("arguments.2")).unwrap(), first);
        assert!(!path("stream.3").exists() && !path("arguments.3").exists());
    }
}

#[test]
fn new_sends_environment_owner_and_tags() {
    let (_directory, host, mut command) = listener();
    let (tx, rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let mut stream = accept(host);
        let request = read_client(&mut stream).unwrap();
        tx.send(serde_json::to_value(&request).unwrap()).unwrap();
        write_frame(&mut stream, &ServerMessage::Created { session: session() }).unwrap();
    });
    let output = command
        .args([
            "new",
            "--cwd=/work",
            "--env",
            "CHERRY_PROCESS_ID=0F1E",
            "--env=TERM=xterm-ghostty",
            "--env",
            "CHERRY_PROCESS_ID=A=B",
            "--env=LANG=it_IT.UTF-8",
            "--owner=dev.cherry",
            "--tag",
            "cherry.tab=T1",
            "--tag=cherry.kind=agent",
            "--tag",
            "cherry.tab=T2",
            "--tag=empty=",
        ])
        .env("LANG", "en_GB.UTF-8")
        .env("LC_ALL", "C")
        .env("TZ", "Europe/Rome")
        .env("UNRELATED", "x")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let request = rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(request["op"], "create");
    assert_eq!(request["owner"], "dev.cherry");
    assert_eq!(
        request["tags"],
        serde_json::json!({"cherry.kind": "agent", "cherry.tab": "T2", "empty": ""})
    );
    // The last value of a name wins; an explicit locale replaces the
    // terminal's (LC_ALL would override it), TZ still comes along.
    assert_eq!(
        request["env"],
        serde_json::json!({
            "CHERRY_PROCESS_ID": "A=B",
            "LANG": "it_IT.UTF-8",
            "TERM": "xterm-ghostty",
            "TZ": "Europe/Rome",
        })
    );
    server.join().unwrap();

    // Without any: no owner, no tags, the terminal's locale.
    let (_directory, listener, mut command) = listener();
    let (tx, rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        let request = read_client(&mut stream).unwrap();
        tx.send(serde_json::to_value(&request).unwrap()).unwrap();
        write_frame(&mut stream, &ServerMessage::Created { session: session() }).unwrap();
    });
    let output = command
        .args(["new", "--cwd=/work"])
        .env("LANG", "en_GB.UTF-8")
        .env_remove("LC_ALL")
        .env_remove("TZ")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(output.status.success());
    let request = rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert!(request["owner"].is_null());
    assert_eq!(request["tags"], serde_json::json!({}));
    assert_eq!(request["env"]["LANG"], "en_GB.UTF-8");
    server.join().unwrap();
}

#[test]
fn invalid_new_options_are_usage_errors_before_connecting() {
    let (directory, host, _) = listener();
    let too_many: Vec<String> = (0..=cherry_protocol::MAX_TAGS)
        .map(|n| format!("--tag=k{n}=v"))
        .collect();
    let owner = format!(
        "--owner={}",
        "o".repeat(cherry_protocol::MAX_OWNER_BYTES + 1)
    );
    for arguments in [
        vec!["--env", "1ABC=x"],
        vec!["--env", "NO_VALUE"],
        vec!["--env", "A-B=x"],
        vec!["--tag", "no-value"],
        vec!["--tag", "=v"],
        vec![owner.as_str()],
        too_many.iter().map(String::as_str).collect(),
    ] {
        let output = Command::new(env!("CARGO_BIN_EXE_cherry"))
            .arg("--socket")
            .arg(directory.path().join("host.sock"))
            .args(["new", "--cwd=/work"])
            .args(&arguments)
            .env("CHERRY_HOST_PATH", "/nonexistent/cherry-host")
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(2), "{arguments:?}");
        assert!(output.stdout.is_empty());
    }
    assert!(
        matches!(host.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock),
        "a usage error connected"
    );
}

#[test]
fn events_and_screen_text_never_end_a_command_or_an_attachment() {
    let event = ServerMessage::Event {
        event: SessionEvent::Bell {
            id: "test-session".into(),
        },
    };
    let (_directory, host, mut command) = listener();
    let pushed = event.clone();
    let server = thread::spawn(move || {
        let mut stream = accept(host);
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::List)
        ));
        write_frame(&mut stream, &pushed).unwrap();
        write_frame(&mut stream, &sessions_reply("host-1", vec![])).unwrap();
    });
    let output = command.args(["list", "--json"]).output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    server.join().unwrap();

    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, session(), b"screen");
        for message in [
            event,
            ServerMessage::ScreenText {
                id: "test-session".into(),
                text: "stray".into(),
                cursor_row: 0,
                cursor_col: 0,
                alternate_screen: false,
            },
            ServerMessage::Output {
                offset: 0,
                data: b"+live".to_vec(),
            },
        ] {
            write_frame(&mut stream, &message).unwrap();
        }
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Detach)
        ));
        write_frame(&mut stream, &ServerMessage::Ok).unwrap();
    });
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let stdin = child.stdin.take().unwrap();
    let mut output = Collected::new(child.stdout.take().unwrap());
    output.expect(b"screen+live");
    drop(stdin);
    assert!(wait(&mut child).success(), "{}", stderr_of(&mut child));
    assert!(!contains(&output.all(), b"stray"));
    server.join().unwrap();
}

// An attachment that lost its connection connects again.

/// Wait until the status file satisfies `accept`, returning it.
fn wait_for_status(path: &Path, accept: impl Fn(&serde_json::Value) -> bool) -> serde_json::Value {
    let deadline = Instant::now() + Duration::from_secs(10);
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
        thread::sleep(Duration::from_millis(5));
    }
}

fn live(reconnecting: bool) -> impl Fn(&serde_json::Value) -> bool {
    move |status| status["outcome"] == "attached" && status["reconnecting"] == reconnecting
}

/// The live state has exactly the fields the app reads: the attachment's
/// own pid and start time (which the app checks before it signals it)
/// besides its state.
fn assert_live(status: &serde_json::Value, viewport: bool, reconnecting: bool) {
    assert!(
        status["pid"].as_u64().is_some_and(|pid| pid > 1),
        "{status}"
    );
    assert!(
        status["started"]
            .as_str()
            .is_some_and(|started| !started.is_empty()),
        "{status}"
    );
    let mut status = status.clone();
    let object = status.as_object_mut().unwrap();
    object.remove("pid");
    object.remove("started");
    assert_eq!(
        &status,
        &serde_json::json!({
            "outcome": "attached",
            "viewport": viewport,
            "reconnecting": reconnecting,
            "exit_code": null,
            "signal": null,
            "message": null,
        })
    );
}

/// The input the client sends until it ends with `expected`; heartbeats are
/// skipped, anything else fails.
fn input_until(stream: &mut UnixStream, expected: &[u8]) -> Vec<u8> {
    let mut input = Vec::new();
    while !input.ends_with(expected) {
        match read_client(stream) {
            Some(ClientMessage::Input { data }) => input.extend(data),
            Some(ClientMessage::Ping) => {}
            other => panic!("expected input, received {other:?} after {input:?}"),
        }
    }
    input
}

/// A host stops: its connection ends and its socket is gone.
fn host_gone(stream: UnixStream, socket: &Path) {
    drop(stream);
    std::fs::remove_file(socket).unwrap();
}

/// A host starts again at `socket`.
fn host_back(socket: &Path) -> UnixListener {
    let listener = UnixListener::bind(socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    listener
}

/// Answer an Attach (at `size`, never a takeover) with `snapshot` at `offset`.
fn reattach(stream: &mut UnixStream, size: (u16, u16), offset: u64, snapshot: &[u8]) {
    match read_client(stream) {
        Some(ClientMessage::Attach {
            id,
            cols,
            rows,
            takeover: false,
            ..
        }) if id == "test-session" && (cols, rows) == size => {}
        other => panic!("expected an Attach at {size:?}, received {other:?}"),
    }
    write_frame(
        stream,
        &ServerMessage::Attached {
            reason: AttachReason::Attach,
            session: sized_session(size.0, size.1),
            offset,
            snapshot: snapshot.to_vec(),
            refreshes: false,
        },
    )
    .unwrap();
}

fn exit_session(stream: &mut UnixStream, code: u32) {
    write_frame(
        stream,
        &ServerMessage::Exit {
            id: "test-session".into(),
            exit_code: code,
            signal: None,
        },
    )
    .unwrap();
}

/// No client connected (or tried to) since the last accept.
fn assert_no_connection(listener: &UnixListener) {
    match listener.accept() {
        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
        Ok(_) => panic!("the client connected again"),
        Err(error) => panic!("accept failed: {error}"),
    }
}

#[test]
fn a_host_restart_mid_attach_reattaches_within_the_window_and_input_keeps_flowing() {
    let (directory, listener, mut command) = listener();
    let socket = directory.path().join("host.sock");
    let status = directory.path().join("status.json");
    let pty = Pty::open(120, 32);
    let original = pty.termios();
    let mut screen = Collected::new(pty.master.try_clone().unwrap());
    let mut child = command
        .args(["attach", "test-session", "--status-file"])
        .arg(&status)
        .env("CHERRY_CLI_RECONNECT_WINDOW_MS", "20000")
        .env("CHERRY_CLI_HEARTBEAT_INTERVAL_MS", "200")
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut first = accept_attach(listener, session(), b"FIRST-SCREEN");
    screen.expect(b"FIRST-SCREEN");
    assert_live(&wait_for_status(&status, live(false)), false, false);
    (&pty.master).write_all(b"one").unwrap();
    assert_eq!(input_until(&mut first, b"one"), b"one");

    // The daemon crashes. The attachment keeps its terminal and says so.
    host_gone(first, &socket);
    assert_live(&wait_for_status(&status, live(true)), false, true);
    assert_eq!(pty.termios().c_lflag & libc::ICANON, 0, "left raw mode");
    // Typed at a stale screen: discarded, and the screen says so.
    (&pty.master).write_all(b"blind").unwrap();
    screen.expect(b"cherry: reconnecting; input is discarded");

    // A daemon with the same identity comes back: a fresh snapshot, and the
    // output continues at its offset.
    let listener = host_back(&socket);
    let mut second = accept(listener);
    reattach(&mut second, (120, 32), 1000, b"SECOND-SCREEN");
    write_frame(
        &mut second,
        &ServerMessage::Output {
            offset: 1000,
            data: b"+after".to_vec(),
        },
    )
    .unwrap();
    screen.expect(b"SECOND-SCREEN+after");
    assert_live(&wait_for_status(&status, live(false)), false, false);
    // Input goes to the new connection, without what was typed meanwhile,
    // and heartbeats go on.
    (&pty.master).write_all(b"two").unwrap();
    assert_eq!(input_until(&mut second, b"two"), b"two");
    match read_client(&mut second) {
        Some(ClientMessage::Ping) => {}
        other => panic!("expected a heartbeat, received {other:?}"),
    }
    exit_session(&mut second, 3);
    assert_eq!(wait(&mut child).code(), Some(3));
    assert_mode_restored(&original, &pty.termios());
    let status = read_status(&status);
    assert_eq!(status["outcome"], "exited");
    assert_eq!(status["exit_code"], 3);
    assert!(status.get("reconnecting").is_none(), "{status}");
}

#[test]
fn a_host_that_stays_away_for_the_whole_window_ends_the_attachment_as_disconnected() {
    let (directory, listener, mut command) = listener();
    let socket = directory.path().join("host.sock");
    let status = directory.path().join("status.json");
    // Every attempt finds no socket and starts a host, which fails.
    let starter = directory.path().join("cherry-host");
    script(
        &starter,
        "echo 'cherry-host: cannot start here' >&2\nexit 1\n",
    );
    let mut child = command
        .args(["attach", "test-session", "--status-file"])
        .arg(&status)
        .env("CHERRY_HOST_PATH", &starter)
        .env("CHERRY_CLI_RECONNECT_WINDOW_MS", "1500")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let stream = accept_attach(listener, session(), b"");
    wait_for_status(&status, live(false));
    let lost = Instant::now();
    host_gone(stream, &socket);
    wait_for_status(&status, live(true));
    assert_eq!(
        wait_within(&mut child, Duration::from_secs(10)).code(),
        Some(1)
    );
    assert!(lost.elapsed() >= Duration::from_millis(1500));
    // What the host it started said reaches the terminal only in the final
    // message, not once per attempt in the middle of the session's screen.
    let error = stderr_of(&mut child);
    assert!(error.contains("connection lost"), "{error}");
    assert!(
        error.contains("could not reconnect within 1.5 s (cherry-host start failed (exit status: 1): cherry-host: cannot start here)"),
        "{error}"
    );
    assert_eq!(error.matches("cannot start here").count(), 1, "{error}");
    let status = read_status(&status);
    assert_eq!(status["outcome"], "disconnected");
    let message = status["message"].as_str().unwrap();
    assert!(
        message.contains("could not reconnect within 1.5 s"),
        "{message}"
    );
    assert!(message.contains("cannot start here"), "{message}");
}

#[test]
fn an_exit_a_takeover_a_detach_or_a_refusal_never_reconnects() {
    type Host = fn(&mut UnixStream);
    let cases: [(&str, Host, &str, Option<i32>); 5] = [
        ("exit", |stream| exit_session(stream, 0), "exited", Some(0)),
        (
            "takeover",
            |stream| {
                write_frame(
                    stream,
                    &ServerMessage::error("taken_over", "Another device took over"),
                )
                .unwrap()
            },
            "taken_over",
            Some(1),
        ),
        (
            // End of input detaches; the host closes without confirming.
            "detach",
            |stream| loop {
                match read_client(stream) {
                    Some(ClientMessage::Ping) => {}
                    Some(ClientMessage::Detach) => break,
                    other => panic!("expected the detach, received {other:?}"),
                }
            },
            "detached",
            Some(0),
        ),
        (
            "refusal",
            |stream| write_frame(stream, &ServerMessage::error("request_failed", "boom")).unwrap(),
            "disconnected",
            Some(1),
        ),
        (
            "out of sequence",
            |stream| {
                write_frame(
                    stream,
                    &ServerMessage::Output {
                        offset: 7,
                        data: b"x".to_vec(),
                    },
                )
                .unwrap()
            },
            "disconnected",
            Some(1),
        ),
    ];
    for (case, host, outcome, code) in cases {
        let (directory, listener, mut command) = listener();
        let status = directory.path().join("status.json");
        let mut child = command
            .args(["attach", "test-session", "--status-file"])
            .arg(&status)
            .env("CHERRY_CLI_RECONNECT_WINDOW_MS", "20000")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        // The client's input stays open, except where its end detaches.
        let mut stdin = child.stdin.take();
        let mut stream = accept_attach(listener.try_clone().unwrap(), session(), b"");
        wait_for_status(&status, live(false));
        if case == "detach" {
            stdin.take();
        }
        host(&mut stream);
        drop(stream);
        assert_eq!(wait(&mut child).code(), code, "{case}");
        drop(stdin);
        assert_no_connection(&listener);
        let status = read_status(&status);
        assert_eq!(status["outcome"], outcome, "{case}: {status}");
    }
}

#[test]
fn another_host_identity_or_a_newer_protocol_ends_the_reconnection_at_once() {
    for (host_id, version, expected) in [
        ("host-2", PROTOCOL_VERSION, "host identity changed"),
        ("host-1", PROTOCOL_VERSION + 1, "protocol version mismatch"),
    ] {
        let (directory, listener, mut command) = listener();
        let status = directory.path().join("status.json");
        let mut child = command
            .args(["attach", "test-session", "--status-file"])
            .arg(&status)
            .env("CHERRY_CLI_RECONNECT_WINDOW_MS", "20000")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let stream = accept_attach(listener.try_clone().unwrap(), session(), b"");
        wait_for_status(&status, live(false));
        drop(stream);
        let mut other = accept_raw(listener.try_clone().unwrap());
        assert!(matches!(
            read_client(&mut other),
            Some(ClientMessage::Hello { .. })
        ));
        write_frame(
            &mut other,
            &ServerMessage::Welcome {
                version,
                host_id: host_id.into(),
                build: None,
            },
        )
        .unwrap();
        // Well within the window.
        assert_eq!(
            wait_within(&mut child, Duration::from_secs(5)).code(),
            Some(1)
        );
        let error = stderr_of(&mut child);
        assert!(error.contains(expected), "{error}");
        assert!(error.contains("connection lost"), "{error}");
        // Neither used nor replaced.
        assert!(read_client(&mut other).is_none(), "{expected}");
        assert_no_connection(&listener);
        let status = read_status(&status);
        assert_eq!(status["outcome"], "disconnected");
        assert!(status["message"].as_str().unwrap().contains(expected));
    }
}

#[test]
fn a_restarted_host_that_does_not_know_the_session_yet_is_asked_again_only_while_it_may() {
    let unknown = || ServerMessage::error("unknown_session", "unknown session test-session");
    // What the host lists after refusing the Attach, and whether the client
    // tries again.
    let cases: [(&str, Vec<u8>, bool); 3] = [
        (
            "listed by now",
            encode_frame(&sessions_reply("host-1", vec![session()])).unwrap(),
            true,
        ),
        (
            "holders still expected",
            raw_frame(
                br#"{"type":"sessions","host_id":"host-1","sessions":[],"pending_holders":1}"#,
            ),
            true,
        ),
        (
            "gone",
            encode_frame(&sessions_reply("host-1", vec![])).unwrap(),
            false,
        ),
    ];
    for (case, listing, again) in cases {
        let (directory, listener, mut command) = listener();
        let status = directory.path().join("status.json");
        let mut child = command
            .args(["attach", "test-session", "--status-file"])
            .arg(&status)
            .env("CHERRY_CLI_RECONNECT_WINDOW_MS", "20000")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let _stdin = child.stdin.take().unwrap();
        let stream = accept_attach(listener.try_clone().unwrap(), session(), b"");
        wait_for_status(&status, live(false));
        drop(stream);
        let mut restarted = accept(listener.try_clone().unwrap());
        assert!(matches!(
            read_client(&mut restarted),
            Some(ClientMessage::Attach { .. })
        ));
        write_frame(&mut restarted, &unknown()).unwrap();
        assert!(matches!(
            read_client(&mut restarted),
            Some(ClientMessage::List)
        ));
        restarted.write_all(&listing).unwrap();
        // The attempt is over either way.
        assert!(read_client(&mut restarted).is_none(), "{case}");
        if again {
            let mut stream = accept(listener.try_clone().unwrap());
            reattach(&mut stream, (DEFAULT_COLS, DEFAULT_ROWS), 0, b"");
            wait_for_status(&status, live(false));
            exit_session(&mut stream, 0);
            assert_eq!(wait(&mut child).code(), Some(0), "{case}");
            assert_eq!(read_status(&status)["outcome"], "exited", "{case}");
        } else {
            assert_eq!(
                wait_within(&mut child, Duration::from_secs(5)).code(),
                Some(1),
                "{case}"
            );
            let error = stderr_of(&mut child);
            assert!(
                error.contains("the host no longer has session test-session"),
                "{case}: {error}"
            );
            assert_no_connection(&listener);
            assert_eq!(read_status(&status)["outcome"], "disconnected", "{case}");
        }
    }
}

#[test]
fn the_detach_key_ends_a_reconnection_and_the_viewport_is_reported() {
    // The key alone detaches once the wait for a second press ends; the key
    // and another at once detach right away.
    for keys in [&b"\x1d"[..], b"\x1dx"] {
        let (directory, listener, mut command) = listener();
        let socket = directory.path().join("host.sock");
        let status = directory.path().join("status.json");
        // A window larger than the shared grid shows a viewport.
        let pty = Pty::open(100, 40);
        let original = pty.termios();
        let mut screen = Collected::new(pty.master.try_clone().unwrap());
        let mut child = command
            .args(["attach", "test-session", "--status-file"])
            .arg(&status)
            .env("CHERRY_CLI_RECONNECT_WINDOW_MS", "20000")
            .stdin(pty.slave.try_clone().unwrap())
            .stdout(pty.slave.try_clone().unwrap())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let stream = accept_attach(listener, sized_session(80, 24), b"GRID");
        screen.expect(b"GRID");
        assert_live(&wait_for_status(&status, live(false)), true, false);
        host_gone(stream, &socket);
        assert_live(&wait_for_status(&status, live(true)), true, true);
        (&pty.master).write_all(keys).unwrap();
        assert_eq!(wait(&mut child).code(), Some(0), "{keys:?}");
        assert_mode_restored(&original, &pty.termios());
        let error = stderr_of(&mut child);
        assert!(error.contains("detached while reconnecting"), "{error}");
        let status = read_status(&status);
        assert_eq!(status["outcome"], "detached");
        assert!(status["message"]
            .as_str()
            .unwrap()
            .contains("while reconnecting"));
    }
}

/// An attachment reading a pipe, with the detach key off.
fn attach_reading_a_pipe(command: &mut Command, status: &Path) -> Child {
    command
        .args([
            "attach",
            "test-session",
            "--detach-key",
            "none",
            "--status-file",
        ])
        .arg(status)
        .env("CHERRY_CLI_RECONNECT_WINDOW_MS", "20000")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

#[test]
fn piped_input_waits_while_reconnecting_and_follows_once_reattached() {
    let (directory, listener, mut command) = listener();
    let socket = directory.path().join("host.sock");
    let status = directory.path().join("status.json");
    let mut child = attach_reading_a_pipe(&mut command, &status);
    let mut stdin = child.stdin.take().unwrap();
    let first = accept_attach(listener, session(), b"");
    wait_for_status(&status, live(false));
    // Nothing was sent before the loss.
    host_gone(first, &socket);
    wait_for_status(&status, live(true));
    stdin.write_all(b"later").unwrap();
    drop(stdin);
    // A few attempts fail meanwhile.
    thread::sleep(Duration::from_millis(600));
    let mut second = accept(host_back(&socket));
    reattach(&mut second, (DEFAULT_COLS, DEFAULT_ROWS), 0, b"");
    assert_eq!(input_until(&mut second, b"later"), b"later");
    // Then the end of input detaches.
    loop {
        match read_client(&mut second) {
            Some(ClientMessage::Ping) => {}
            Some(ClientMessage::Detach) => break,
            other => panic!("expected the detach, received {other:?}"),
        }
    }
    write_frame(&mut second, &ServerMessage::Ok).unwrap();
    assert!(wait(&mut child).success(), "{}", stderr_of(&mut child));
    assert_eq!(read_status(&status)["outcome"], "detached");
}

#[test]
fn piped_input_sent_before_the_loss_ends_the_attachment_instead() {
    // Whatever of it the host had not handed to the session is gone, and
    // nobody watches a screen to notice: going on could splice two lines.
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let mut child = attach_reading_a_pipe(&mut command, &status);
    let mut stdin = child.stdin.take().unwrap();
    let mut first = accept_attach(listener.try_clone().unwrap(), session(), b"");
    stdin.write_all(b"rm -rf /tmp/pro").unwrap();
    assert_eq!(
        input_until(&mut first, b"rm -rf /tmp/pro"),
        b"rm -rf /tmp/pro"
    );
    drop(first);
    assert_eq!(
        wait_within(&mut child, Duration::from_secs(5)).code(),
        Some(1)
    );
    assert_no_connection(&listener);
    let error = stderr_of(&mut child);
    assert!(error.contains("connection lost"), "{error}");
    assert!(error.contains("does not connect again"), "{error}");
    let status = read_status(&status);
    assert_eq!(status["outcome"], "disconnected");
    assert!(status["message"]
        .as_str()
        .unwrap()
        .contains("from a pipe or a file"));
    drop(stdin);
}

#[test]
fn reconnecting_over_ssh_runs_ssh_in_batch_mode_so_it_never_prompts_in_the_session() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path();
    let greeting = [
        format!("CHERRY-GATEWAY {PROTOCOL_VERSION}\n").into_bytes(),
        frames(&[ServerMessage::Welcome {
            version: PROTOCOL_VERSION,
            host_id: "remote".into(),
            build: None,
        }]),
    ]
    .concat();
    let attached = |snapshot: &[u8]| {
        encoded(&ServerMessage::Attached {
            reason: AttachReason::Attach,
            session: sized_session(DEFAULT_COLS, DEFAULT_ROWS),
            offset: 0,
            snapshot: snapshot.to_vec(),
            refreshes: false,
        })
    };
    // The first connection ends right after attaching (the remote daemon
    // restarted); the second attaches again and the program exits.
    std::fs::write(
        path.join("stream.1"),
        [greeting.clone(), attached(b"FIRST")].concat(),
    )
    .unwrap();
    let exit = encoded(&ServerMessage::Exit {
        id: "test-session".into(),
        exit_code: 4,
        signal: None,
    });
    std::fs::write(
        path.join("stream.2"),
        [greeting, attached(b"SECOND"), exit].concat(),
    )
    .unwrap();
    script(
        &path.join("ssh"),
        &format!(
            "d='{}'\nn=$(( $(/bin/cat \"$d/count\" 2>/dev/null || echo 0) + 1 ))\necho \"$n\" > \"$d/count\"\nprintf '%s\\n' \"$@\" > \"$d/arguments.$n\"\n/bin/cat \"$d/stream.$n\"\n[ \"$n\" = 1 ] && exit 0\n/bin/cat > /dev/null\n",
            path.display()
        ),
    );
    let status = path.join("status.json");
    let mut child = Command::new(env!("CARGO_BIN_EXE_cherry"))
        .args([
            "--host",
            "devbox",
            "attach",
            "test-session",
            "--status-file",
        ])
        .arg(&status)
        .env("PATH", path)
        .env("CHERRY_CLI_RECONNECT_WINDOW_MS", "20000")
        .env("CHERRY_CLI_REPORT_WAIT_MS", "200")
        .env_remove("CHERRY_SESSION_ID")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let _stdin = child.stdin.take().unwrap();
    let output = Collected::new(child.stdout.take().unwrap());
    assert_eq!(
        wait(&mut child).code(),
        Some(4),
        "{}",
        stderr_of(&mut child)
    );
    let output = output.all();
    assert!(contains(&output, b"FIRST") && contains(&output, b"SECOND"));
    assert_eq!(read_status(&status)["outcome"], "exited");
    let options = "-T\n-o\nControlMaster=no\n-o\nRemoteCommand=none\n-o\nClearAllForwardings=yes\n-o\nPermitLocalCommand=no\n-o\nServerAliveInterval=15\n-o\nServerAliveCountMax=3\n";
    let gateway = "--\ndevbox\ncherry-host gateway\n";
    // Attaching may prompt in the terminal; connecting again may not, and
    // forwards the agent as configured (no -a). Connecting again also tells
    // the gateway which host it reattaches to: one of another identity is
    // neither replaced nor used.
    assert_eq!(
        std::fs::read_to_string(path.join("arguments.1")).unwrap(),
        format!("{options}{gateway}")
    );
    assert_eq!(
        std::fs::read_to_string(path.join("arguments.2")).unwrap(),
        format!(
            "{options}-o\nBatchMode=yes\n-o\nConnectTimeout=10\n--\ndevbox\nenv CHERRY_EXPECTED_HOST_ID='remote' cherry-host gateway\n"
        )
    );
}

#[test]
fn a_remote_host_of_another_version_ends_the_reconnection_at_once() {
    // What the remote cherry-host says, once the first connection is lost:
    // on ssh's standard error, a host of another version that the gateway
    // does not replace; or a gateway preamble of another version (another
    // cherry-host build). Connecting again would find the same.
    let newer = PROTOCOL_VERSION + 1;
    let report = format!(
        "a cherry-host speaking protocol {newer} is running at /tmp/cherry-host-7/host.sock; it is newer than this cherry-host (protocol {PROTOCOL_VERSION}), which never replaces it: install the cherry-host (and Cherry) that speaks protocol {newer}"
    );
    for (again, expected) in [
        (
            format!("echo 'cherry-host: {report}' >&2\nexit 1\n"),
            report.clone(),
        ),
        (
            format!("printf 'CHERRY-GATEWAY {newer}\\n'\n/bin/cat > /dev/null\n"),
            format!("the remote cherry-host gateway speaks version {newer}"),
        ),
    ] {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path();
        let first = [
            format!("CHERRY-GATEWAY {PROTOCOL_VERSION}\n").into_bytes(),
            frames(&[
                ServerMessage::Welcome {
                    version: PROTOCOL_VERSION,
                    host_id: "remote".into(),
                    build: None,
                },
                ServerMessage::Attached {
                    reason: AttachReason::Attach,
                    session: sized_session(DEFAULT_COLS, DEFAULT_ROWS),
                    offset: 0,
                    snapshot: b"FIRST".to_vec(),
                    refreshes: false,
                },
            ]),
        ]
        .concat();
        std::fs::write(path.join("stream.1"), first).unwrap();
        script(
            &path.join("ssh"),
            &format!(
                "d='{}'\nn=$(( $(/bin/cat \"$d/count\" 2>/dev/null || echo 0) + 1 ))\necho \"$n\" > \"$d/count\"\nif [ \"$n\" = 1 ]; then /bin/cat \"$d/stream.1\"; exit 0; fi\n{again}",
                path.display()
            ),
        );
        let status = path.join("status.json");
        let mut child = Command::new(env!("CARGO_BIN_EXE_cherry"))
            .args([
                "--host",
                "devbox",
                "attach",
                "test-session",
                "--status-file",
            ])
            .arg(&status)
            .env("PATH", path)
            .env("CHERRY_CLI_RECONNECT_WINDOW_MS", "20000")
            .env("CHERRY_CLI_REPORT_WAIT_MS", "200")
            .env_remove("CHERRY_SESSION_ID")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let _stdin = child.stdin.take().unwrap();
        // Well within the window: one attempt, not one every 2 s.
        assert_eq!(
            wait_within(&mut child, Duration::from_secs(5)).code(),
            Some(1)
        );
        let error = stderr_of(&mut child);
        assert!(error.contains("connection lost"), "{error}");
        assert!(error.contains("could not reconnect: "), "{error}");
        assert!(error.contains(&expected), "{error}");
        assert_eq!(
            std::fs::read_to_string(path.join("count")).unwrap(),
            "2\n",
            "{error}"
        );
        let status = read_status(&status);
        assert_eq!(status["outcome"], "disconnected");
        assert!(
            status["message"].as_str().unwrap().contains(&expected),
            "{status}"
        );
    }
}

/// Serve one connection as a host would, as far as the client goes: Hello,
/// then an Attach answered with a snapshot. False once the client is gone.
fn serve_attach(mut stream: UnixStream, snapshot: &[u8]) -> Option<UnixStream> {
    stream.set_nonblocking(false).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let Ok(Some(ClientMessage::Hello { .. })) = read_frame(&mut stream) else {
        return None;
    };
    write_frame(
        &mut stream,
        &ServerMessage::Welcome {
            version: PROTOCOL_VERSION,
            host_id: "host-1".into(),
            build: None,
        },
    )
    .ok()?;
    let Ok(Some(ClientMessage::Attach { .. })) = read_frame(&mut stream) else {
        return None;
    };
    write_frame(
        &mut stream,
        &ServerMessage::Attached {
            reason: AttachReason::Attach,
            session: session(),
            offset: 0,
            snapshot: snapshot.to_vec(),
            refreshes: false,
        },
    )
    .ok()?;
    Some(stream)
}

#[test]
fn a_host_that_drops_every_attachment_is_attached_to_with_backoff_until_the_window_ends() {
    // A daemon that crashes whenever it serves this session: each
    // reattachment is lost at once, which continues the same reconnection.
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let mut child = command
        .args(["attach", "test-session", "--status-file"])
        .arg(&status)
        .env("CHERRY_CLI_RECONNECT_WINDOW_MS", "2000")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let _stdin = child.stdin.take().unwrap();
    let started = Instant::now();
    let mut attachments = 0;
    while child.try_wait().unwrap().is_none() {
        assert!(
            started.elapsed() < Duration::from_secs(10),
            "the client never gave up ({attachments} attachments)"
        );
        match listener.accept() {
            Ok((stream, _)) => {
                if serve_attach(stream, b"SNAPSHOT").is_some() {
                    attachments += 1;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(5));
            }
            Err(error) => panic!("accept failed: {error}"),
        }
    }
    // The first, then at once, after 250 ms, 500 ms and 1 s; the next would
    // come 2 s later, past the window.
    assert!((3..=7).contains(&attachments), "{attachments} attachments");
    assert_eq!(child.wait().unwrap().code(), Some(1));
    let error = stderr_of(&mut child);
    assert!(
        error.contains(
            "could not reconnect within 2 s (attached again, but lost the connection again)"
        ),
        "{error}"
    );
    assert_eq!(read_status(&status)["outcome"], "disconnected");
}

#[test]
fn a_reattachment_that_lasts_starts_a_new_reconnection() {
    // Each connection lasts longer than a healthy one needs to, and the
    // losses together last longer than the window: each is a reconnection
    // of its own, with the window counted afresh.
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let mut child = command
        .args(["attach", "test-session", "--status-file"])
        .arg(&status)
        .env("CHERRY_CLI_RECONNECT_WINDOW_MS", "1000")
        .env("CHERRY_CLI_RECONNECT_HEALTHY_MS", "300")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let _stdin = child.stdin.take().unwrap();
    let mut stream = accept_attach(listener.try_clone().unwrap(), session(), b"");
    for _ in 0..4 {
        thread::sleep(Duration::from_millis(500));
        drop(stream);
        stream = accept(listener.try_clone().unwrap());
        reattach(&mut stream, (DEFAULT_COLS, DEFAULT_ROWS), 0, b"");
    }
    exit_session(&mut stream, 5);
    assert_eq!(
        wait(&mut child).code(),
        Some(5),
        "{}",
        stderr_of(&mut child)
    );
    assert_eq!(read_status(&status)["outcome"], "exited");
}

#[test]
fn an_attempt_the_host_never_answers_leaves_time_for_the_next() {
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let mut child = command
        .args(["attach", "test-session", "--status-file"])
        .arg(&status)
        .env("CHERRY_CLI_RECONNECT_WINDOW_MS", "5000")
        .env("CHERRY_CLI_RECONNECT_ATTEMPT_MS", "300")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let _stdin = child.stdin.take().unwrap();
    let first = accept_attach(listener.try_clone().unwrap(), session(), b"");
    wait_for_status(&status, live(false));
    drop(first);
    let lost = Instant::now();
    // A hung daemon: the connection is accepted, and nothing answers.
    let mut hung = accept_raw(listener.try_clone().unwrap());
    assert!(matches!(
        read_client(&mut hung),
        Some(ClientMessage::Hello { .. })
    ));
    // The client gives up on it and connects again.
    assert!(read_client(&mut hung).is_none());
    let mut stream = accept(listener.try_clone().unwrap());
    reattach(&mut stream, (DEFAULT_COLS, DEFAULT_ROWS), 0, b"");
    assert!(
        lost.elapsed() < Duration::from_secs(4),
        "{:?}",
        lost.elapsed()
    );
    exit_session(&mut stream, 6);
    assert_eq!(
        wait(&mut child).code(),
        Some(6),
        "{}",
        stderr_of(&mut child)
    );
}

#[test]
fn the_detach_key_ends_a_reconnection_at_once_while_an_attempt_hangs() {
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let pty = Pty::open(120, 32);
    let original = pty.termios();
    let mut screen = Collected::new(pty.master.try_clone().unwrap());
    let mut child = command
        .args(["attach", "test-session", "--status-file"])
        .arg(&status)
        .env("CHERRY_CLI_RECONNECT_WINDOW_MS", "20000")
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let first = accept_attach(listener.try_clone().unwrap(), session(), b"SCREEN");
    screen.expect(b"SCREEN");
    drop(first);
    let mut hung = accept_raw(listener.try_clone().unwrap());
    assert!(matches!(
        read_client(&mut hung),
        Some(ClientMessage::Hello { .. })
    ));
    // The key, then another: a detach at once, without the repeat wait.
    let pressed = Instant::now();
    (&pty.master).write_all(b"\x1dx").unwrap();
    assert_eq!(wait(&mut child).code(), Some(0));
    assert!(
        pressed.elapsed() < Duration::from_secs(2),
        "{:?}",
        pressed.elapsed()
    );
    assert_mode_restored(&original, &pty.termios());
    // The abandoned attempt's connection is closed too.
    assert!(read_client(&mut hung).is_none());
    let error = stderr_of(&mut child);
    assert!(error.contains("detached while reconnecting"), "{error}");
    assert_eq!(read_status(&status)["outcome"], "detached");
}

/// A fake ssh for successive connections: run N prints `stream.N` when
/// there is one and then reads its input until it ends, except the first,
/// which ends as the remote end closed; without one it fails as ssh does
/// with the network down.
fn unreachable_ssh(directory: &Path, streams: &[(usize, Vec<u8>)]) {
    for (run, stream) in streams {
        std::fs::write(directory.join(format!("stream.{run}")), stream).unwrap();
    }
    script(
        &directory.join("ssh"),
        &format!(
            "d='{}'\nn=$(( $(/bin/cat \"$d/count\" 2>/dev/null || echo 0) + 1 ))\necho \"$n\" > \"$d/count\"\nif [ -e \"$d/stream.$n\" ]; then /bin/cat \"$d/stream.$n\"; if [ \"$n\" = 1 ]; then /bin/sleep 0.3; echo 'Connection to devbox closed by remote host.' >&2; exit 255; fi; /bin/cat > /dev/null; exit 0; fi\necho 'ssh: connect to host devbox port 22: Network is unreachable' >&2\nexit 255\n",
            directory.display()
        ),
    );
}

#[test]
fn what_ssh_says_while_reconnecting_never_reaches_the_screen() {
    let greeting = [
        format!("CHERRY-GATEWAY {PROTOCOL_VERSION}\n").into_bytes(),
        frames(&[ServerMessage::Welcome {
            version: PROTOCOL_VERSION,
            host_id: "remote".into(),
            build: None,
        }]),
    ]
    .concat();
    let attached = |snapshot: &[u8]| {
        encoded(&ServerMessage::Attached {
            reason: AttachReason::Attach,
            session: sized_session(DEFAULT_COLS, DEFAULT_ROWS),
            offset: 0,
            snapshot: snapshot.to_vec(),
            refreshes: false,
        })
    };
    let exit = encoded(&ServerMessage::Exit {
        id: "test-session".into(),
        exit_code: 4,
        signal: None,
    });
    // Two attempts fail before the network comes back; or none succeeds.
    for back in [true, false] {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path();
        let mut streams = vec![(1, [greeting.clone(), attached(b"FIRST")].concat())];
        if back {
            streams.push((
                4,
                [greeting.clone(), attached(b"SECOND"), exit.clone()].concat(),
            ));
        }
        unreachable_ssh(path, &streams);
        let status = path.join("status.json");
        let mut child = Command::new(env!("CARGO_BIN_EXE_cherry"))
            .args([
                "--host",
                "devbox",
                "attach",
                "test-session",
                "--status-file",
            ])
            .arg(&status)
            .env("PATH", path)
            .env("CHERRY_CLI_RECONNECT_WINDOW_MS", "1500")
            .env("CHERRY_CLI_REPORT_WAIT_MS", "200")
            .env_remove("CHERRY_SESSION_ID")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let _stdin = child.stdin.take().unwrap();
        let output = Collected::new(child.stdout.take().unwrap());
        let code = wait(&mut child).code();
        let error = stderr_of(&mut child);
        let output = output.all();
        assert!(!contains(&output, b"Network is unreachable"), "{back}");
        assert!(!contains(&output, b"closed by remote host"), "{back}");
        if back {
            assert_eq!(code, Some(4), "{error}");
            assert!(contains(&output, b"SECOND"));
            assert!(!error.contains("Network is unreachable"), "{error}");
            assert!(!error.contains("closed by remote host"), "{error}");
        } else {
            assert_eq!(code, Some(1), "{error}");
            // Once, in the final message, after the terminal is restored.
            assert_eq!(
                error.matches("Network is unreachable").count(),
                1,
                "{error}"
            );
            assert_eq!(error.matches("closed by remote host").count(), 1, "{error}");
            assert!(
                error.contains("connection lost while attached to test-session (Connection to devbox closed by remote host.); "),
                "{error}"
            );
            assert!(
                error.contains("could not reconnect within 1.5 s (the SSH connection closed before cherry-host gateway started: ssh: connect to host devbox port 22: Network is unreachable)"),
                "{error}"
            );
        }
    }
}

/// An attachment (`--detach-key none`, as the app runs it, when `app`) on
/// a PTY, whose first connection shows a session with bracketed paste on.
fn paste_attachment(
    app: bool,
) -> (
    tempfile::TempDir,
    UnixListener,
    Pty,
    Collected,
    Child,
    UnixStream,
    PathBuf,
) {
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let pty = Pty::open(120, 32);
    let mut screen = Collected::new(pty.master.try_clone().unwrap());
    command.args(["attach", "test-session", "--status-file"]);
    command.arg(&status);
    if app {
        command.args(["--detach-key", "none"]);
    }
    let child = command
        .env("CHERRY_CLI_RECONNECT_WINDOW_MS", "20000")
        .env("CHERRY_CLI_PASTE_TAIL_WAIT_MS", "300")
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let first = accept_attach(
        listener.try_clone().unwrap(),
        session(),
        b"\x1b[?2004hPROMPT",
    );
    screen.expect(b"PROMPT");
    (directory, listener, pty, screen, child, first, status)
}

/// The connection is lost; the attachment reconnects and discards what
/// the terminal sends meanwhile (`meanwhile`), until the host answers again
/// with `snapshot`.
fn lose_and_reattach(
    first: UnixStream,
    listener: &UnixListener,
    pty: &Pty,
    screen: &mut Collected,
    status: &Path,
    meanwhile: &[u8],
    snapshot: &[u8],
) -> UnixStream {
    drop(first);
    wait_for_status(status, live(true));
    // The attempt to connect again waits for the host's answer meanwhile.
    if !meanwhile.is_empty() {
        (&pty.master).write_all(meanwhile).unwrap();
        screen.expect(b"cherry: reconnecting; input is discarded");
    }
    let mut second = accept(listener.try_clone().unwrap());
    reattach(&mut second, (120, 32), 0, snapshot);
    wait_for_status(status, live(false));
    second
}

fn finish(mut second: UnixStream, mut child: Child) {
    exit_session(&mut second, 0);
    assert_eq!(
        wait(&mut child).code(),
        Some(0),
        "{}",
        stderr_of(&mut child)
    );
}

#[test]
fn a_paste_the_loss_cut_short_is_ended_once_reattached() {
    // The terminal's paste ended while reconnecting. The session had
    // bracketed paste on; whether it still does decides whether the end
    // marker is sent.
    for app in [false, true] {
        for (snapshot, ended) in [(&b"\x1b[?2004hPROMPT"[..], true), (b"PROMPT", false)] {
            let (_directory, listener, pty, mut screen, child, mut first, status) =
                paste_attachment(app);
            // The start of a paste, and the connection is lost before the rest.
            (&pty.master).write_all(b"\x1b[200~first half").unwrap();
            input_until(&mut first, b"first half");
            let mut second = lose_and_reattach(
                first,
                &listener,
                &pty,
                &mut screen,
                &status,
                b" second half\x1b[201~",
                snapshot,
            );
            (&pty.master).write_all(b"typed").unwrap();
            let input = input_until(&mut second, b"typed");
            if ended {
                assert_eq!(input, b"\x1b[201~typed", "{app}");
            } else {
                assert_eq!(input, b"typed", "{app}");
            }
            finish(second, child);
        }
    }
}

#[test]
fn the_rest_of_a_paste_cut_by_the_loss_never_arrives_as_typed_keys() {
    for app in [false, true] {
        let (_directory, listener, pty, mut screen, child, mut first, status) =
            paste_attachment(app);
        (&pty.master)
            .write_all(b"\x1b[200~cd /tmp/build\r")
            .unwrap();
        input_until(&mut first, b"cd /tmp/build\r");
        // The terminal is still sending the paste when the attachment is
        // back: the rest of it is discarded too, then the paste is ended.
        let mut second = lose_and_reattach(
            first,
            &listener,
            &pty,
            &mut screen,
            &status,
            b"make clean\r",
            b"\x1b[?2004hPROMPT",
        );
        (&pty.master)
            .write_all(b"rm -rf *\r\x1b[201~typed")
            .unwrap();
        assert_eq!(
            input_until(&mut second, b"typed"),
            b"\x1b[201~typed",
            "{app}"
        );
        // Pasted again, from the start: forwarded as it is.
        (&pty.master)
            .write_all(b"\x1b[200~whole\r\x1b[201~")
            .unwrap();
        assert_eq!(
            input_until(&mut second, b"\x1b[201~"),
            b"\x1b[200~whole\r\x1b[201~"
        );
        finish(second, child);
    }
}

#[test]
fn a_paste_begun_while_reconnecting_is_discarded_to_its_end() {
    let (_directory, listener, pty, mut screen, child, first, status) = paste_attachment(true);
    // Nothing of it reached the session: no end marker is sent for it.
    let mut second = lose_and_reattach(
        first,
        &listener,
        &pty,
        &mut screen,
        &status,
        b"\x1b[200~while away\r",
        b"\x1b[?2004hPROMPT",
    );
    (&pty.master)
        .write_all(b"still pasting\r\x1b[201~typed")
        .unwrap();
    assert_eq!(input_until(&mut second, b"typed"), b"typed");
    finish(second, child);
}

#[test]
fn a_paste_whose_end_never_comes_stops_being_discarded_after_a_pause() {
    let (_directory, listener, pty, mut screen, child, mut first, status) = paste_attachment(true);
    (&pty.master).write_all(b"\x1b[200~first half").unwrap();
    input_until(&mut first, b"first half");
    let mut second = lose_and_reattach(
        first,
        &listener,
        &pty,
        &mut screen,
        &status,
        b"",
        b"\x1b[?2004hPROMPT",
    );
    // Nothing arrives for longer than a paste pauses: the paste is ended,
    // and what is typed next goes to the session.
    thread::sleep(Duration::from_millis(600));
    (&pty.master).write_all(b"typed").unwrap();
    assert_eq!(input_until(&mut second, b"typed"), b"\x1b[201~typed");
    finish(second, child);
}

#[test]
fn a_paste_start_the_lost_connection_never_sent_is_not_ended() {
    // The host stops reading: the paste's start marker waits behind other
    // input when the connection is taken for dead, so it never reached the
    // session, and no end marker is sent for it.
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let pty = Pty::open(120, 32);
    let mut screen = Collected::new(pty.master.try_clone().unwrap());
    let mut child = command
        .args([
            "attach",
            "test-session",
            "--detach-key",
            "none",
            "--status-file",
        ])
        .arg(&status)
        .env("CHERRY_CLI_RECONNECT_WINDOW_MS", "20000")
        .env("CHERRY_CLI_HEARTBEAT_TIMEOUT_MS", "1000")
        .env("CHERRY_CLI_PASTE_TAIL_WAIT_MS", "300")
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let silent = accept_attach(
        listener.try_clone().unwrap(),
        session(),
        b"\x1b[?2004hPROMPT",
    );
    screen.expect(b"PROMPT");
    // More than every buffer on the way holds, but less than the client
    // queues: all of it is read and queued, ahead of the paste.
    let mut master = pty.master.try_clone().unwrap();
    let writer = thread::spawn(move || {
        master.write_all(&vec![b'x'; 600 * 1024]).unwrap();
        master.write_all(b"\x1b[200~pasted").unwrap();
    });
    wait_for_status(&status, live(true));
    writer.join().unwrap();
    drop(silent);
    let mut second = accept(listener.try_clone().unwrap());
    reattach(&mut second, (120, 32), 0, b"\x1b[?2004hPROMPT");
    wait_for_status(&status, live(false));
    (&pty.master).write_all(b"\x1b[201~typed").unwrap();
    assert_eq!(input_until(&mut second, b"typed"), b"typed");
    exit_session(&mut second, 0);
    assert_eq!(
        wait(&mut child).code(),
        Some(0),
        "{}",
        stderr_of(&mut child)
    );
}

#[test]
fn a_host_that_went_silent_is_connected_to_again() {
    // Input is waiting and the host neither reads nor writes: the connection
    // is taken for dead after the heartbeat timeout.
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let pty = Pty::open(120, 32);
    pty.read_in_background();
    let mut child = command
        .args([
            "attach",
            "test-session",
            "--detach-key",
            "none",
            "--status-file",
        ])
        .arg(&status)
        .env("CHERRY_CLI_RECONNECT_WINDOW_MS", "20000")
        .env("CHERRY_CLI_HEARTBEAT_TIMEOUT_MS", "1000")
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let silent = accept_attach(listener.try_clone().unwrap(), session(), b"");
    wait_for_status(&status, live(false));
    // A paste larger than every buffer on the way; the writer is stopped
    // by the terminal closing once the test is over.
    let mut master = pty.master.try_clone().unwrap();
    thread::spawn(move || {
        let paste: Vec<u8> = (0..3 * 1024 * 1024)
            .map(|i| b'a' + (i % 26) as u8)
            .collect();
        let _ = master.write_all(&paste);
    });
    wait_for_status(&status, live(true));
    let mut stream = accept(listener.try_clone().unwrap());
    reattach(&mut stream, (120, 32), 0, b"");
    wait_for_status(&status, live(false));
    exit_session(&mut stream, 7);
    assert_eq!(
        wait(&mut child).code(),
        Some(7),
        "{}",
        stderr_of(&mut child)
    );
    drop(silent);
}

#[test]
fn a_gateway_that_stopped_reading_is_connected_to_again() {
    // It stopped reading but keeps its output open: sending fails, and no
    // end of file arrives.
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path();
    let greeting = [
        format!("CHERRY-GATEWAY {PROTOCOL_VERSION}\n").into_bytes(),
        frames(&[ServerMessage::Welcome {
            version: PROTOCOL_VERSION,
            host_id: "remote".into(),
            build: None,
        }]),
    ]
    .concat();
    let attached = |snapshot: &[u8]| {
        encoded(&ServerMessage::Attached {
            reason: AttachReason::Attach,
            session: sized_session(DEFAULT_COLS, DEFAULT_ROWS),
            offset: 0,
            snapshot: snapshot.to_vec(),
            refreshes: false,
        })
    };
    std::fs::write(
        path.join("stream.1"),
        [greeting.clone(), attached(b"FIRST")].concat(),
    )
    .unwrap();
    let exit = encoded(&ServerMessage::Exit {
        id: "test-session".into(),
        exit_code: 8,
        signal: None,
    });
    std::fs::write(
        path.join("stream.2"),
        [greeting, attached(b"SECOND"), exit].concat(),
    )
    .unwrap();
    script(
        &path.join("ssh"),
        &format!(
            "d='{}'\nn=$(( $(/bin/cat \"$d/count\" 2>/dev/null || echo 0) + 1 ))\necho \"$n\" > \"$d/count\"\n/bin/cat \"$d/stream.$n\"\nif [ \"$n\" = 1 ]; then exec 0<&-; exec /bin/sleep 30; fi\n/bin/cat > /dev/null\n",
            path.display()
        ),
    );
    let status = path.join("status.json");
    let mut child = Command::new(env!("CARGO_BIN_EXE_cherry"))
        .args([
            "--host",
            "devbox",
            "attach",
            "test-session",
            "--status-file",
        ])
        .arg(&status)
        .env("PATH", path)
        .env("CHERRY_CLI_RECONNECT_WINDOW_MS", "20000")
        // A heartbeat soon finds that sending fails.
        .env("CHERRY_CLI_HEARTBEAT_INTERVAL_MS", "100")
        .env("CHERRY_CLI_CLOSED_WAIT_MS", "300")
        .env("CHERRY_CLI_REPORT_WAIT_MS", "200")
        .env_remove("CHERRY_SESSION_ID")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let _stdin = child.stdin.take().unwrap();
    let output = Collected::new(child.stdout.take().unwrap());
    assert_eq!(
        wait_within(&mut child, Duration::from_secs(10)).code(),
        Some(8),
        "{}",
        stderr_of(&mut child)
    );
    let output = output.all();
    assert!(contains(&output, b"FIRST") && contains(&output, b"SECOND"));
}

#[test]
fn the_client_id_goes_with_every_attach_including_after_a_lost_connection() {
    let (directory, listener, mut command) = listener();
    let socket = directory.path().join("host.sock");
    let status = directory.path().join("status.json");
    let pty = Pty::open(120, 32);
    let mut screen = Collected::new(pty.master.try_clone().unwrap());
    let mut child = command
        .args([
            "attach",
            "test-session",
            "--client-id",
            "tab-42",
            "--status-file",
        ])
        .arg(&status)
        .env("CHERRY_CLI_RECONNECT_WINDOW_MS", "20000")
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let client_id = |message: Option<ClientMessage>| match message {
        Some(ClientMessage::Attach { client_id, .. }) => client_id,
        other => panic!("expected an Attach, received {other:?}"),
    };
    let mut first = accept(listener.try_clone().unwrap());
    assert_eq!(
        client_id(read_client(&mut first)).as_deref(),
        Some("tab-42")
    );
    write_frame(
        &mut first,
        &ServerMessage::Attached {
            reason: AttachReason::Attach,
            session: session(),
            offset: 0,
            snapshot: b"FIRST".to_vec(),
            refreshes: false,
        },
    )
    .unwrap();
    screen.expect(b"FIRST");
    wait_for_status(&status, live(false));
    // The connection is lost; the attachment connects again as the same
    // client, which replaces what is left of its lost attachment.
    host_gone(first, &socket);
    wait_for_status(&status, live(true));
    let mut second = accept(host_back(&socket));
    assert_eq!(
        client_id(read_client(&mut second)).as_deref(),
        Some("tab-42")
    );
    write_frame(
        &mut second,
        &ServerMessage::Attached {
            reason: AttachReason::Attach,
            session: session(),
            offset: 0,
            snapshot: b"SECOND".to_vec(),
            refreshes: false,
        },
    )
    .unwrap();
    screen.expect(b"SECOND");
    exit_session(&mut second, 0);
    assert_eq!(wait(&mut child).code(), Some(0));

    // Without the option, no client ID is sent.
    drop(listener);
    let (_directory, plain, mut command) = self::listener();
    let server = thread::spawn(move || {
        let mut stream = accept(plain);
        let id = client_id(read_client(&mut stream));
        exit_session(&mut stream, 0);
        id
    });
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    assert_eq!(server.join().unwrap(), None);
    wait(&mut child);
}

#[test]
fn a_replaced_attachment_ends_and_does_not_connect_again() {
    // Another run of this client (the same --client-id) attached, and the
    // host dropped this attachment, saying so last. Connecting again would
    // drop the other in turn, so the attachment ends, as a detach does.
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let spare = listener.try_clone().unwrap();
    let (replace_tx, replace_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, session(), b"ready");
        replace_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        write_frame(
            &mut stream,
            &ServerMessage::error(
                "replaced",
                "another attachment of this client replaced this one; the session keeps running",
            ),
        )
        .unwrap();
        // The host closes the connection after its notice.
        let _ = stream.shutdown(std::net::Shutdown::Both);
    });
    let pty = Pty::open(120, 32);
    pty.read_in_background();
    let original = pty.termios();
    let mut child = command
        .args([
            "attach",
            "test-session",
            "--client-id",
            "tab-7",
            "--status-file",
        ])
        .arg(&status)
        // A lost connection would be connected again at once.
        .env("CHERRY_CLI_RECONNECT_WINDOW_MS", "20000")
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    pty.wait_for_raw_mode();
    replace_tx.send(()).unwrap();
    assert_eq!(wait(&mut child).code(), Some(0));
    assert_mode_restored(&original, &pty.termios());
    let error = stderr_of(&mut child);
    assert!(error.contains("replaced this one"), "{error}");
    server.join().unwrap();
    let status = read_status(&status);
    assert_eq!(status["outcome"], "replaced", "{status}");
    assert!(status["message"]
        .as_str()
        .unwrap()
        .contains("keeps running"));
    // It never connected again.
    assert!(
        matches!(spare.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock),
        "the replaced attachment connected again"
    );
}

/// Set the terminal's size, as a window drag does, and tell the client.
fn resize_window(pty: &Pty, child: &Child, cols: u16, rows: u16) {
    let size = libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    assert_eq!(
        unsafe { libc::ioctl(pty.slave.as_raw_fd(), libc::TIOCSWINSZ, &size) },
        0
    );
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGWINCH) }, 0);
}

#[test]
fn the_first_resize_goes_at_once_and_those_right_after_it_as_one() {
    let (_directory, listener, mut command) = listener();
    let (resized_tx, resized_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, sized_session(80, 24), b"READY");
        let mut sizes = Vec::new();
        loop {
            match read_client(&mut stream) {
                Some(ClientMessage::Resize { cols, rows, .. }) => {
                    sizes.push(((cols, rows), Instant::now()));
                    resized_tx.send((cols, rows)).unwrap();
                    if (cols, rows) == (110, 45) {
                        break;
                    }
                }
                Some(ClientMessage::Ping) => {}
                other => panic!("{other:?}"),
            }
        }
        exit_session(&mut stream, 0);
        sizes
    });
    let pty = Pty::open(80, 24);
    pty.read_in_background();
    let mut child = command
        .args(["attach", "test-session"])
        // Long enough to tell the first resize from the coalesced ones on
        // a busy machine.
        .env("CHERRY_CLI_RESIZE_COALESCE_MS", "1500")
        .env("CHERRY_CLI_GRID_WAIT_MS", "5000")
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    pty.wait_for_raw_mode();
    let signalled = Instant::now();
    resize_window(&pty, &child, 100, 40);
    assert_eq!(
        resized_rx.recv_timeout(Duration::from_secs(5)).unwrap(),
        (100, 40)
    );
    let first = signalled.elapsed();
    assert!(
        first < Duration::from_millis(1000),
        "the first waited {first:?}"
    );
    // A drag goes on: its steps within the period go as one, the last.
    resize_window(&pty, &child, 105, 42);
    thread::sleep(Duration::from_millis(50));
    resize_window(&pty, &child, 110, 45);
    assert_eq!(
        resized_rx.recv_timeout(Duration::from_secs(5)).unwrap(),
        (110, 45)
    );
    // The period runs from when the client sent the first, which it did
    // after the signal (less the moment its loop may have noted the time
    // before it saw the signal): a bound however slowly this thread went.
    let last = signalled.elapsed();
    assert!(
        last >= Duration::from_millis(1400),
        "the drag's steps were not held for the period: {last:?}"
    );
    let sizes: Vec<_> = server
        .join()
        .unwrap()
        .into_iter()
        .map(|(size, _)| size)
        .collect();
    assert_eq!(sizes, [(100, 40), (110, 45)]);
    assert!(wait(&mut child).success());
}

#[test]
fn a_resized_grid_keeps_what_the_window_shows_while_the_program_repaints() {
    // The window follows the grid: nothing is painted for the new size but
    // what the program sends.
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, sized_session(80, 24), b"\x1b[?1049h\x1b[HEDITOR");
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Resize {
                cols: 101,
                rows: 41,
                ..
            })
        ));
        for frame in [
            ServerMessage::Resized {
                offset: 0,
                cols: 101,
                rows: 41,
            },
            ServerMessage::Output {
                offset: 0,
                data: b"\x1b[H\x1b[2JREPAINTED".to_vec(),
            },
            ServerMessage::Exit {
                id: "test-session".into(),
                exit_code: 0,
                signal: None,
            },
        ] {
            write_frame(&mut stream, &frame).unwrap();
        }
    });
    let mut pty = Pty::open(80, 24);
    let mut child = command
        .args(["attach", "test-session"])
        .env("CHERRY_CLI_GRID_WAIT_MS", "5000")
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    pty.wait_for_raw_mode();
    resize_window(&pty, &child, 101, 41);
    let mut received = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(5);
    while child.try_wait().unwrap().is_none() {
        received.extend(pty.drain());
        assert!(Instant::now() < deadline, "client did not exit");
        thread::sleep(Duration::from_millis(10));
    }
    received.extend(pty.drain());
    assert!(child.wait().unwrap().success(), "{}", stderr_of(&mut child));
    server.join().unwrap();
    let after = received
        .windows(6)
        .position(|window| window == b"EDITOR")
        .expect("the snapshot");
    let rest = &received[after..];
    assert!(contains(rest, b"\x1b[H\x1b[2JREPAINTED"));
    // No snapshot, and no viewport frame, for the new size.
    assert!(
        !contains(rest, b"\x1bc"),
        "{:?}",
        String::from_utf8_lossy(rest)
    );
    assert!(
        !contains(rest, b"\x1b[?2026h"),
        "{:?}",
        String::from_utf8_lossy(rest)
    );
}

#[test]
fn a_resized_grid_out_of_step_with_the_output_is_refused() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, sized_session(80, 24), b"READY");
        write_frame(
            &mut stream,
            &ServerMessage::Resized {
                offset: 7,
                cols: 90,
                rows: 30,
            },
        )
        .unwrap();
        let _ = read_client(&mut stream);
    });
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let exit = wait(&mut child);
    let error = stderr_of(&mut child);
    assert_eq!(exit.code(), Some(1), "{error}");
    assert!(error.contains("out of sequence"), "{error}");
    server.join().unwrap();
}

#[test]
fn keys_typed_while_the_terminal_takes_no_output_still_reach_the_host() {
    // The window stopped reading (a stalled terminal, or a frame far larger
    // than the terminal takes at once): the client waits to write, and
    // what is typed meanwhile goes to the host at once, not after the
    // output.
    let (_directory, listener, mut command) = listener();
    let (typed_tx, typed_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, sized_session(80, 24), b"READY");
        // Written while the input is read, as the host does: the client
        // takes the frame only as its terminal takes the output.
        let mut writer = stream.try_clone().unwrap();
        let output = thread::spawn(move || {
            write_frame(
                &mut writer,
                &ServerMessage::Output {
                    offset: 0,
                    data: vec![b'x'; 2 * 1024 * 1024],
                },
            )
            .unwrap();
        });
        assert_eq!(input_until(&mut stream, b"k"), b"k");
        typed_tx.send(()).unwrap();
        output.join().unwrap();
        exit_session(&mut stream, 0);
    });
    let pty = Pty::open(80, 24);
    let mut child = command
        .args(["attach", "test-session", "--detach-key", "none"])
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    pty.wait_for_raw_mode();
    // The terminal is not read until the key has arrived.
    thread::sleep(Duration::from_millis(300));
    (&pty.master).write_all(b"k").unwrap();
    typed_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("the key waited behind the output");
    pty.read_in_background();
    assert!(wait(&mut child).success(), "{}", stderr_of(&mut child));
    server.join().unwrap();
}

#[test]
fn keys_typed_while_output_streams_reach_the_host_before_it_ends() {
    // The terminal takes everything (the client never waits to write), and
    // the host sends frames without a pause: terminal input is looked for
    // between frames too, not only once none are left.
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept_attach(listener, sized_session(80, 24), b"READY");
        let typed = Arc::new(AtomicUsize::new(0));
        let mut reader = stream.try_clone().unwrap();
        let seen = typed.clone();
        thread::spawn(move || {
            assert_eq!(input_until(&mut reader, b"k"), b"k");
            seen.store(1, Ordering::SeqCst);
        });
        let frame = [b"0123456789abcdef".as_slice(); 256].concat();
        let (mut offset, deadline) = (0u64, Instant::now() + Duration::from_secs(10));
        while typed.load(Ordering::SeqCst) == 0 && Instant::now() < deadline {
            write_frame(
                &mut stream,
                &ServerMessage::Output {
                    offset,
                    data: frame.clone(),
                },
            )
            .unwrap();
            offset += frame.len() as u64;
        }
        assert_eq!(
            typed.load(Ordering::SeqCst),
            1,
            "the key waited behind {offset} bytes of output"
        );
        exit_session(&mut stream, 0);
    });
    let pty = Pty::open(80, 24);
    let mut child = command
        .args(["attach", "test-session", "--detach-key", "none"])
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    pty.wait_for_raw_mode();
    pty.read_in_background();
    thread::sleep(Duration::from_millis(300));
    (&pty.master).write_all(b"k").unwrap();
    assert!(
        wait_within(&mut child, Duration::from_secs(15)).success(),
        "{}",
        stderr_of(&mut child)
    );
    server.join().unwrap();
}

#[test]
fn without_a_copy_the_client_asks_the_host_for_one_to_paint_a_viewport() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Attach { .. })
        ));
        // A host that answers Refresh: the client keeps no copy.
        write_frame(
            &mut stream,
            &ServerMessage::Attached {
                reason: AttachReason::Attach,
                session: sized_session(80, 24),
                offset: 0,
                snapshot: b"\x1bc\x1b[?1004hFIRST".to_vec(),
                refreshes: true,
            },
        )
        .unwrap();
        write_frame(
            &mut stream,
            &ServerMessage::Output {
                offset: 0,
                data: b" LIVE".to_vec(),
            },
        )
        .unwrap();
        // The window grows; the grid does not follow it. Once the client
        // stops waiting for the grid, it asks for a copy of the screen.
        let mut asked = Vec::new();
        loop {
            match read_client(&mut stream) {
                Some(ClientMessage::Ping) => {}
                Some(ClientMessage::Refresh) => break,
                other => asked.push(format!("{other:?}")),
            }
        }
        assert_eq!(
            asked,
            ["Some(Resize { cols: 101, rows: 41, cell_width: None, cell_height: None })"]
        );
        for frame in [
            ServerMessage::Attached {
                reason: AttachReason::Resize,
                session: sized_session(80, 24),
                offset: 5,
                snapshot: b"\x1bc\x1b[?1004hFIRST LIVE".to_vec(),
                refreshes: true,
            },
            ServerMessage::Output {
                offset: 5,
                data: b" MORE".to_vec(),
            },
            ServerMessage::Exit {
                id: "test-session".into(),
                exit_code: 0,
                signal: None,
            },
        ] {
            write_frame(&mut stream, &frame).unwrap();
        }
        // Asked once.
        while let Ok(Some(message)) = read_frame::<_, ClientMessage>(&mut stream) {
            assert!(matches!(message, ClientMessage::Ping), "{message:?}");
        }
    });
    let mut pty = Pty::open(80, 24);
    let mut child = command
        .args(["attach", "test-session"])
        .env("CHERRY_CLI_GRID_WAIT_MS", "100")
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    pty.wait_for_raw_mode();
    let mut received = Vec::new();
    let settled = Instant::now() + Duration::from_millis(200);
    while Instant::now() < settled {
        received.extend(pty.drain());
        thread::sleep(Duration::from_millis(10));
    }
    let size = libc::winsize {
        ws_row: 41,
        ws_col: 101,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    assert_eq!(
        unsafe { libc::ioctl(pty.slave.as_raw_fd(), libc::TIOCSWINSZ, &size) },
        0
    );
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGWINCH) }, 0);
    let deadline = Instant::now() + Duration::from_secs(5);
    while child.try_wait().unwrap().is_none() {
        received.extend(pty.drain());
        assert!(Instant::now() < deadline, "client did not exit");
        thread::sleep(Duration::from_millis(10));
    }
    received.extend(pty.drain());
    assert!(child.wait().unwrap().success(), "{}", stderr_of(&mut child));
    // The stream, then a viewport of the copy with its modes, then frames.
    let viewport = received
        .windows(8)
        .position(|bytes| bytes == b"\x1b[?2026h")
        .expect("a viewport");
    assert!(contains(&received[..viewport], b"FIRST LIVE"));
    assert!(
        !contains(&received[viewport..], b"\x1bc"),
        "no RIS in viewport mode"
    );
    assert!(contains(&received[viewport..], b"\x1b[?1004h"));
    let mut screen = cherry_vt::Terminal::new(101, 41, 0).unwrap();
    screen.feed(&received);
    assert!(screen.screen_text().unwrap().contains("FIRST LIVE MORE"));
    server.join().unwrap();
}

#[test]
fn sigusr1_makes_a_reconnecting_attachment_try_again_at_once_and_is_ignored_while_attached() {
    let (directory, listener, mut command) = listener();
    let status = directory.path().join("status.json");
    let mut child = command
        .args(["attach", "test-session", "--status-file"])
        .arg(&status)
        .env("CHERRY_CLI_RECONNECT_WINDOW_MS", "20000")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let _stdin = child.stdin.take().unwrap();
    let pid = child.id() as libc::pid_t;
    let first = accept_attach(listener.try_clone().unwrap(), session(), b"");
    wait_for_status(&status, live(false));
    // Attached: nothing happens, and the process lives on (SIGUSR1 would
    // end it by default).
    unsafe {
        libc::kill(pid, libc::SIGUSR1);
    }
    thread::sleep(Duration::from_millis(300));
    assert!(
        child.try_wait().unwrap().is_none(),
        "{}",
        stderr_of(&mut child)
    );
    assert!(live(false)(&read_status(&status)));
    drop(first);
    // Attempts that fail (the host goes away after the Hello) until the
    // backoff reaches its 2 s at most: 0, 250, 500, 1000 ms, then 2000.
    for _ in 0..4 {
        let mut failing = accept_raw(listener.try_clone().unwrap());
        assert!(matches!(
            read_client(&mut failing),
            Some(ClientMessage::Hello { .. })
        ));
    }
    // Asked to reconnect now, it does not wait out the 2 s.
    thread::sleep(Duration::from_millis(100));
    let asked = Instant::now();
    unsafe {
        libc::kill(pid, libc::SIGUSR1);
    }
    let mut stream = accept(listener.try_clone().unwrap());
    assert!(
        asked.elapsed() < Duration::from_millis(1200),
        "{:?}",
        asked.elapsed()
    );
    reattach(&mut stream, (DEFAULT_COLS, DEFAULT_ROWS), 0, b"");
    wait_for_status(&status, live(false));
    exit_session(&mut stream, 7);
    assert_eq!(
        wait(&mut child).code(),
        Some(7),
        "{}",
        stderr_of(&mut child)
    );
}

/// Accept a connection that says Hello, welcoming it with `build`.
fn accept_with_build(listener: UnixListener, build: Option<&str>) -> UnixStream {
    let mut stream = accept_raw(listener);
    assert!(matches!(
        read_frame(&mut stream).unwrap(),
        Some(ClientMessage::Hello {
            version: PROTOCOL_VERSION
        })
    ));
    write_frame(
        &mut stream,
        &ServerMessage::Welcome {
            version: PROTOCOL_VERSION,
            host_id: "host-1".into(),
            build: build.map(str::to_owned),
        },
    )
    .unwrap();
    stream
}

fn host_status() -> cherry_protocol::HostStatus {
    serde_json::from_value(serde_json::json!({
        "host_id": "host-1",
        "version": PROTOCOL_VERSION,
        "build": "20260101000000.abcdef0",
        "pid": 4242,
        "started_at": 1,
        "uptime_ms": 7_500_000,
        "socket": "/tmp/x/host.sock",
        "state_dir": "/state",
        "log_path": "/state/host.log",
        "sessions": 1,
        "running_sessions": 1,
        "max_sessions": 128,
        "connections": 3,
        "max_connections": 1024,
        "holders_registered": 1,
        "holders_expected": 0,
        "fd_limit": 16384,
    }))
    .unwrap()
}

#[test]
fn status_reports_the_host_its_limits_and_each_holders_build() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept_with_build(listener, Some("20260101000000.abcdef0"));
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Status)
        ));
        write_frame(
            &mut stream,
            &ServerMessage::Status {
                status: host_status(),
            },
        )
        .unwrap();
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::List)
        ));
        let mut held = session();
        held.holder_build = Some("20250101000000.0123456".into());
        write_frame(&mut stream, &sessions_reply("host-1", vec![held])).unwrap();
    });
    let result = command.args(["status", "--json"]).output().unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    server.join().unwrap();
    let value: serde_json::Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(value["running"], true);
    assert_eq!(value["build"], "20260101000000.abcdef0");
    assert_eq!(value["host"]["pid"], 4242);
    assert_eq!(value["host"]["log_path"], "/state/host.log");
    assert_eq!(value["host"]["max_connections"], 1024);
    assert_eq!(value["client"]["build"], cherry_protocol::BUILD);
    assert_eq!(value["sessions"][0]["id"], "test-session");
    assert_eq!(
        value["sessions"][0]["holder_build"],
        "20250101000000.0123456"
    );
}

#[test]
fn status_of_a_host_that_predates_it_still_lists_the_sessions() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept_with_build(listener, None);
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Status)
        ));
        write_frame(
            &mut stream,
            &ServerMessage::error("unsupported_operation", "unknown op"),
        )
        .unwrap();
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::List)
        ));
        write_frame(&mut stream, &sessions_reply("host-1", vec![session()])).unwrap();
    });
    let result = command.arg("status").output().unwrap();
    assert!(result.status.success());
    server.join().unwrap();
    let text = String::from_utf8_lossy(&result.stdout);
    assert!(text.contains("it predates `status`"), "{text}");
    assert!(
        text.lines()
            .any(|line| line.starts_with("test-session") && line.contains("running")),
        "{text}"
    );
}

#[test]
fn status_never_starts_a_host_and_says_none_runs() {
    let directory = private_directory();
    let socket = directory.path().join("host.sock");
    let home = directory.path().join("home");
    std::fs::create_dir(&home).unwrap();
    // A cherry-host that records every run: status must never start one.
    let host = directory.path().join("cherry-host");
    let ran = directory.path().join("ran");
    script(
        &host,
        &format!("echo \"$@\" >> '{}'\nexit 1\n", ran.display()),
    );
    let run = |json: bool| {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cherry"));
        command
            .args(["--socket", socket.to_str().unwrap(), "status"])
            .env("HOME", &home)
            .env("CHERRY_HOST_PATH", &host);
        if json {
            command.arg("--json");
        }
        command.output().unwrap()
    };
    let text = run(false);
    assert_eq!(text.status.code(), Some(3));
    assert!(String::from_utf8_lossy(&text.stdout).starts_with(&format!(
        "cherry-host is not running at {}",
        socket.display()
    )));
    let json = run(true);
    assert_eq!(json.status.code(), Some(3));
    let value: serde_json::Value = serde_json::from_slice(&json.stdout).unwrap();
    assert_eq!(value["running"], false);
    assert_eq!(value["socket"], socket.to_str().unwrap());
    assert!(value["state_dir"]
        .as_str()
        .unwrap()
        .starts_with(home.to_str().unwrap()));
    assert!(!socket.exists());
    assert!(
        !ran.exists(),
        "status ran cherry-host: {:?}",
        std::fs::read_to_string(&ran)
    );
}

/// A private socket directory and HOME for `cherry doctor`, with a fake
/// cherry-host of this build to start.
struct DoctorSandbox {
    directory: tempfile::TempDir,
    socket: PathBuf,
    home: PathBuf,
    state: PathBuf,
    host: PathBuf,
}

impl DoctorSandbox {
    fn new() -> Self {
        let directory = private_directory();
        let socket = directory.path().join("s/host.sock");
        let home = directory.path().join("home");
        std::fs::create_dir(&home).unwrap();
        let base = if cfg!(target_os = "macos") {
            home.join("Library/Application Support/cherry-host")
        } else {
            home.join(".local/state/cherry-host")
        };
        let state = base.join(cherry_protocol::state_key(&socket));
        let host = directory.path().join("cherry-host");
        script(
            &host,
            &format!("echo 'cherry-host {}'\n", cherry_protocol::VERSION),
        );
        Self {
            directory,
            socket,
            home,
            state,
            host,
        }
    }

    fn private_dir(path: &Path) {
        std::fs::create_dir_all(path).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
    }

    fn doctor(&self) -> (Option<i32>, String) {
        let output = Command::new(env!("CARGO_BIN_EXE_cherry"))
            .args(["--socket", self.socket.to_str().unwrap(), "doctor"])
            .env("HOME", &self.home)
            .env_remove("XDG_STATE_HOME")
            .env("CHERRY_HOST_PATH", &self.host)
            .output()
            .unwrap();
        (
            output.status.code(),
            String::from_utf8_lossy(&output.stdout).into_owned(),
        )
    }
}

#[test]
fn doctor_finds_nothing_wrong_where_no_host_ever_ran() {
    let sandbox = DoctorSandbox::new();
    let (code, report) = sandbox.doctor();
    assert_eq!(code, Some(0), "{report}");
    assert!(report.contains("no socket directory"), "{report}");
    assert!(report.ends_with("No problems found.\n"), "{report}");
    assert!(!sandbox.socket.parent().unwrap().exists());
}

#[test]
fn doctor_reports_stale_sockets_and_pid_files_and_holders_without_a_host() {
    let sandbox = DoctorSandbox::new();
    DoctorSandbox::private_dir(sandbox.socket.parent().unwrap());
    // A socket nothing listens on any more.
    drop(UnixListener::bind(&sandbox.socket).unwrap());
    std::fs::set_permissions(&sandbox.socket, std::fs::Permissions::from_mode(0o600)).unwrap();
    DoctorSandbox::private_dir(&sandbox.state);
    // A PID file whose daemon is gone.
    let mut gone = Command::new("true").spawn().unwrap();
    let gone_pid = gone.id();
    gone.wait().unwrap();
    std::fs::write(
        sandbox.state.join("host.pid"),
        format!(r#"{{"pid":{gone_pid},"build":"x","started_at":1,"socket":"/x"}}"#),
    )
    .unwrap();
    // A holder that still runs, and one that is gone.
    let mut holder = Command::new("sleep").arg("30").spawn().unwrap();
    DoctorSandbox::private_dir(&sandbox.state.join("sessions"));
    let held = "7b0c7d16-5f5c-4a8e-9a5a-111111111111";
    let lost = "7b0c7d16-5f5c-4a8e-9a5a-222222222222";
    for (id, pid) in [(held, holder.id()), (lost, gone_pid)] {
        std::fs::write(
            sandbox.state.join(format!("sessions/{id}.json")),
            format!(r#"{{"id":"{id}","holder_pid":{pid},"created_at":1,"link_version":7}}"#),
        )
        .unwrap();
    }
    let (code, report) = sandbox.doctor();
    let _ = holder.kill();
    let _ = holder.wait();
    assert_eq!(code, Some(1), "{report}");
    assert!(
        report.contains(&format!(
            "PROBLEM  stale socket {}: nothing listens on it",
            sandbox.socket.display()
        )),
        "{report}"
    );
    assert!(
        report.contains(&format!(
            "PROBLEM  stale PID file {}",
            sandbox.state.join("host.pid").display()
        )),
        "{report}"
    );
    assert!(
        report.contains(&format!(
            "PROBLEM  1 session is held by holders with no host running: {held} (pid {})",
            holder.id()
        )),
        "{report}"
    );
    assert!(report.contains("fix: `cherry start`"), "{report}");
    // The gone holder is only noted: the next host reports it as lost.
    assert!(
        report.contains("ok       1 session manifest names holders that are gone"),
        "{report}"
    );
    assert!(report.ends_with("3 problems found.\n"), "{report}");
}

#[test]
fn doctor_takes_a_pid_file_whose_pid_another_process_got_for_stale() {
    let sandbox = DoctorSandbox::new();
    DoctorSandbox::private_dir(&sandbox.state);
    // The pid runs, but the process started at another time than the
    // daemon that wrote the file: the pid was reused.
    let mut other = Command::new("sleep").arg("30").spawn().unwrap();
    std::fs::write(
        sandbox.state.join("host.pid"),
        format!(
            r#"{{"pid":{},"started":"1.000000","build":"x","started_at":1,"socket":"/x"}}"#,
            other.id()
        ),
    )
    .unwrap();
    let (code, report) = sandbox.doctor();
    let _ = other.kill();
    let _ = other.wait();
    assert_eq!(code, Some(1), "{report}");
    assert!(
        report.contains(&format!(
            "PROBLEM  stale PID file {}: pid {} is gone",
            sandbox.state.join("host.pid").display(),
            other.id()
        )),
        "{report}"
    );
}

#[test]
fn doctor_reports_directories_others_can_reach_and_a_mismatched_host_executable() {
    let sandbox = DoctorSandbox::new();
    let dir = sandbox.socket.parent().unwrap();
    std::fs::create_dir(dir).unwrap();
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o755)).unwrap();
    script(
        &sandbox.host,
        "echo 'cherry-host 0.1.0 (build 20000101000000.0ld0000)'\n",
    );
    let (code, report) = sandbox.doctor();
    assert_eq!(code, Some(1), "{report}");
    assert!(
        report.contains(&format!(
            "PROBLEM  socket directory {} is not usable",
            dir.display()
        )),
        "{report}"
    );
    assert!(
        report.contains(&format!(
            "PROBLEM  the cherry-host it starts ({}) is build 20000101000000.0ld0000, not this cherry's {}",
            sandbox.host.display(),
            cherry_protocol::BUILD
        )),
        "{report}"
    );
    let _ = &sandbox.directory;
}
