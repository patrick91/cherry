//! The CLI against scripted fake hosts (and a fake ssh), without a daemon.
use cherry_protocol::{
    encode_frame, read_frame, write_frame, AttachReason, ClientMessage, ServerMessage, SessionInfo,
    SessionState, DEFAULT_COLS, DEFAULT_ROWS, PROTOCOL_VERSION,
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
    process::{Child, ChildStdout, Command, Stdio},
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

fn sized_session(cols: u16, rows: u16) -> SessionInfo {
    SessionInfo {
        id: "test-session".into(),
        name: "Example".into(),
        cwd: "/work".into(),
        command: vec!["/bin/sh".into()],
        cols,
        rows,
        state: SessionState::Running,
        pid: Some(42),
        exit_code: None,
        attached: true,
        exit_signal: None,
    }
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
    fn new(mut stdout: ChildStdout) -> Self {
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
        write_frame(
            &mut stream,
            &ServerMessage::Sessions {
                host_id: "host-1".into(),
                sessions: vec![session()],
            },
        )
        .unwrap();
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
/// (queued input takes at least 4/3 of its size in frames), with a host that
/// takes none. Returns how much was pasted.
fn paste_past_the_limit(pipe: &mut InputPipe, host: &UnixStream) -> usize {
    const CHUNK: usize = 4096;
    let beyond = SMALL_INPUT_HIGH_WATER * 3 / 4 + CHUNK + INPUT_OVERFLOW / 2;
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
                },
                ServerMessage::Attached {
                    reason: AttachReason::Attach,
                    session: sized_session(DEFAULT_COLS, DEFAULT_ROWS),
                    offset: 0,
                    snapshot: b"ready".to_vec(),
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
        (
            &["list", "--json"][..],
            ServerMessage::Sessions {
                host_id: "host-1".into(),
                sessions: vec![],
            },
        ),
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
    let output = command
        .args(["attach", "test-session", "--status-file"])
        .arg(&status)
        .stdin(Stdio::piped())
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    server.join().unwrap();
    let value = read_status(&status);
    assert_eq!(value["outcome"], "disconnected");
    assert!(value["message"]
        .as_str()
        .unwrap()
        .contains("connection lost"));
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
            },
        )
        .unwrap();
        assert!(matches!(
            read_client(&mut stream),
            Some(ClientMessage::Resize {
                cols: 101,
                rows: 41
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
                rows: 41
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
                rows: 41
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
    // Only an attachment forwards the agent: no other command's connection
    // lasts as long as the sessions that would use it.
    let batch = "-a\n-o\nBatchMode=yes\n-o\nConnectTimeout=10\n";
    // Only commands that need a session may start the remote host.
    for (arguments, batch, gateway) in [
        (&["list", "--json"][..], batch, "gateway"),
        (&["new", "--cwd=/work"], batch, "gateway"),
        (&["attach", "S"], "", "gateway"),
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
        b"CHERRY-GATEWAY 3\n",
        &frames(&[
            ServerMessage::Welcome {
                version: PROTOCOL_VERSION,
                host_id: "remote".into(),
            },
            ServerMessage::Sessions {
                host_id: "remote".into(),
                sessions: vec![session()],
            },
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
        for arguments in [&["kill", "S"][..], &["remove", "S"], &["shutdown"]] {
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
        error.contains("version 2") && error.contains("version 3"),
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
    for arguments in [&["kill", "S"][..], &["remove", "S"], &["shutdown"]] {
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
                Some(ClientMessage::List) => ServerMessage::Sessions {
                    host_id: "host-1".into(),
                    sessions: vec![],
                },
                Some(ClientMessage::Kill { .. }) => ServerMessage::Ok,
                Some(ClientMessage::Attach { .. }) => {
                    write_frame(
                        &mut stream,
                        &ServerMessage::Attached {
                            reason: AttachReason::Attach,
                            session: session(),
                            offset: 0,
                            snapshot: Vec::new(),
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
