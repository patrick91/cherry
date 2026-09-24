//! Shared harness: every daemon runs on a private socket with a private HOME,
//! so its durable state directory never touches the real one.
#![allow(dead_code)]
use cherry_protocol::*;
use cherry_vt::Terminal;
use std::{
    collections::BTreeMap,
    fs,
    os::unix::{fs::PermissionsExt, net::UnixStream, process::CommandExt},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};
use tempfile::TempDir;
use uuid::Uuid;

pub const BIN: &str = env!("CARGO_BIN_EXE_cherry-host");

/// A private directory holding the socket and a fake HOME.
pub struct Sandbox {
    pub dir: TempDir,
    pub socket: PathBuf,
    pub home: PathBuf,
}

impl Default for Sandbox {
    fn default() -> Self {
        Self::new()
    }
}

impl Sandbox {
    pub fn new() -> Self {
        // Short paths: Unix socket addresses are limited to about 100 bytes.
        let dir = tempfile::Builder::new()
            .prefix("ch-")
            .tempdir_in("/tmp")
            .unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let home = dir.path().join("home");
        fs::create_dir(&home).unwrap();
        Self {
            socket: dir.path().join("host.sock"),
            home,
            dir,
        }
    }

    pub fn path(&self) -> &Path {
        self.dir.path()
    }

    /// `cherry-host <action> --socket <this socket>` with this HOME.
    pub fn command(&self, action: &str) -> Command {
        let mut command = Command::new(BIN);
        command
            .arg(action)
            .arg("--socket")
            .arg(&self.socket)
            .env("HOME", &self.home)
            .env_remove("XDG_STATE_HOME")
            .env_remove("CHERRY_HOST_SOCKET");
        command
    }

    /// Where daemons using this HOME keep their state directories.
    pub fn state_base(&self) -> PathBuf {
        #[cfg(target_os = "macos")]
        return self.home.join("Library/Application Support/cherry-host");
        #[cfg(not(target_os = "macos"))]
        return self.home.join(".local/state/cherry-host");
    }

    /// The daemon's state directory (there is one per socket).
    pub fn state_dir(&self) -> PathBuf {
        let base = self.state_base();
        let mut entries: Vec<_> = fs::read_dir(&base)
            .unwrap_or_else(|e| panic!("{}: {e}", base.display()))
            .map(|entry| entry.unwrap().path())
            .collect();
        assert_eq!(entries.len(), 1, "{entries:?}");
        entries.pop().unwrap()
    }
}

pub struct Host {
    pub sandbox: Sandbox,
    pub socket: PathBuf,
    pub child: Child,
    env: Vec<(String, String)>,
    fd_limit: Option<FdLimit>,
}

/// A descriptor limit for the daemon: the soft limit, and the hard limit
/// (unchanged when None).
#[derive(Clone, Copy)]
pub struct FdLimit {
    pub soft: u64,
    pub hard: Option<u64>,
}

impl Host {
    pub fn new() -> Self {
        Self::with_env(&[])
    }

    /// Extra daemon environment, such as the test-only tunables.
    pub fn with_env(env: &[(&str, &str)]) -> Self {
        Self::launch(Sandbox::new(), env, None)
    }

    /// A daemon whose soft and hard descriptor limits are both `limit`.
    pub fn with_fd_limit(limit: u64) -> Self {
        Self::launch(
            Sandbox::new(),
            &[],
            Some(FdLimit {
                soft: limit,
                hard: Some(limit),
            }),
        )
    }

    /// A daemon started with a low soft limit, which it may raise.
    pub fn with_soft_fd_limit(soft: u64) -> Self {
        Self::launch(Sandbox::new(), &[], Some(FdLimit { soft, hard: None }))
    }

    pub fn launch(sandbox: Sandbox, env: &[(&str, &str)], fd_limit: Option<FdLimit>) -> Self {
        Self::launch_with_stderr(sandbox, env, fd_limit, Stdio::inherit())
    }

    /// A daemon whose stderr (its log) is `stderr`.
    pub fn launch_with_stderr(
        sandbox: Sandbox,
        env: &[(&str, &str)],
        fd_limit: Option<FdLimit>,
        stderr: Stdio,
    ) -> Self {
        let mut env: Vec<(String, String)> = env
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        // Kill escalation (HUP, TERM, KILL) finishes quickly in tests.
        if !env.iter().any(|(k, _)| k == "CHERRY_HOST_KILL_GRACE_MS") {
            env.push(("CHERRY_HOST_KILL_GRACE_MS".into(), "100".into()));
        }
        let child = spawn_serve_with_stderr(&sandbox, &env, fd_limit, stderr);
        let socket = sandbox.socket.clone();
        let mut host = Self {
            sandbox,
            socket,
            child,
            env,
            fd_limit,
        };
        host.wait_ready();
        host
    }

    pub fn wait_ready(&mut self) {
        // bind creates the socket pathname before listen accepts connections.
        // Readiness requires a real protocol handshake, not file existence.
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                panic!("host exited during startup: {status}");
            }
            match UnixStream::connect(&self.socket) {
                Ok(mut socket) => {
                    socket
                        .set_read_timeout(Some(Duration::from_secs(5)))
                        .unwrap();
                    write_frame(&mut socket, &ClientMessage::hello()).unwrap();
                    assert!(matches!(
                        receive(&mut socket),
                        ServerMessage::Welcome {
                            version: PROTOCOL_VERSION,
                            ..
                        }
                    ));
                    return;
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
    }

    /// Stop this daemon (it must own no running sessions) and start another
    /// on the same socket and state directory.
    pub fn restart(&mut self) {
        self.restart_with_stderr(Stdio::inherit());
    }

    /// `restart`, with `stderr` as the new daemon's log.
    pub fn restart_with_stderr(&mut self, stderr: Stdio) {
        assert!(matches!(
            self.call(ClientMessage::Shutdown),
            ServerMessage::Ok
        ));
        let status = wait_child(&mut self.child, Duration::from_secs(5));
        assert!(status.success(), "host exited with {status}");
        let env = self.env.clone();
        self.child = spawn_serve_with_stderr(&self.sandbox, &env, self.fd_limit, stderr);
        self.wait_ready();
    }

    pub fn dir(&self) -> &Path {
        self.sandbox.path()
    }

    pub fn host_id(&self) -> String {
        match self.call(ClientMessage::List) {
            ServerMessage::Sessions { host_id, .. } => host_id,
            other => panic!("list failed {other:?}"),
        }
    }

    pub fn connect(&self) -> UnixStream {
        let mut socket = UnixStream::connect(&self.socket).unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        socket
            .set_write_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        write_frame(&mut socket, &ClientMessage::hello()).unwrap();
        assert!(matches!(
            receive(&mut socket),
            ServerMessage::Welcome {
                version: PROTOCOL_VERSION,
                ..
            }
        ));
        socket
    }

    pub fn call(&self, request: ClientMessage) -> ServerMessage {
        let mut socket = self.connect();
        write_frame(&mut socket, &request).unwrap();
        receive(&mut socket)
    }

    pub fn create(&self, command: Vec<String>) -> SessionInfo {
        match self.call(create_request(Uuid::new_v4().to_string(), command)) {
            ServerMessage::Created { session } => session,
            other => panic!("create failed: {other:?}"),
        }
    }

    pub fn sessions(&self) -> Vec<SessionInfo> {
        match self.call(ClientMessage::List) {
            ServerMessage::Sessions { sessions, .. } => sessions,
            other => panic!("list failed {other:?}"),
        }
    }

    pub fn session(&self, id: &str) -> SessionInfo {
        self.sessions().into_iter().find(|s| s.id == id).unwrap()
    }

    pub fn wait(&self, id: &str, predicate: impl Fn(&SessionInfo) -> bool) -> SessionInfo {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let info = self.session(id);
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

    pub fn attach(
        &self,
        id: &str,
        cols: u16,
        rows: u16,
    ) -> (UnixStream, SessionInfo, u64, Vec<u8>) {
        self.attach_with_takeover(id, cols, rows, false)
    }

    pub fn attach_with_takeover(
        &self,
        id: &str,
        cols: u16,
        rows: u16,
        takeover: bool,
    ) -> (UnixStream, SessionInfo, u64, Vec<u8>) {
        self.attach_with(id, cols, rows, takeover, true)
    }

    /// Attach as a client whose terminal answers queries, or not.
    pub fn attach_with(
        &self,
        id: &str,
        cols: u16,
        rows: u16,
        takeover: bool,
        answers_queries: bool,
    ) -> (UnixStream, SessionInfo, u64, Vec<u8>) {
        let mut socket = self.connect();
        write_frame(
            &mut socket,
            &ClientMessage::Attach {
                id: id.into(),
                cols,
                rows,
                takeover,
                answers_queries,
            },
        )
        .unwrap();
        match receive(&mut socket) {
            ServerMessage::Attached {
                reason,
                session,
                offset,
                snapshot,
            } => {
                assert_eq!(reason, AttachReason::Attach);
                (socket, session, offset, snapshot)
            }
            other => panic!("attach failed {other:?}"),
        }
    }

    pub fn kill(&self, id: &str) {
        assert!(matches!(
            self.call(ClientMessage::Kill { id: id.into() }),
            ServerMessage::Ok
        ));
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        // Also clean up if an assertion fails: dropping the daemon alone does
        // not end processes that ignore the hangup.
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let Some(mut socket) = quiet_connect(&self.socket) else {
                break;
            };
            let _ = write_frame(&mut socket, &ClientMessage::List);
            let Ok(Some(ServerMessage::Sessions { sessions, .. })) = read_frame(&mut socket) else {
                break;
            };
            let running: Vec<_> = sessions
                .into_iter()
                .filter(|s| s.state == SessionState::Running)
                .collect();
            if running.is_empty() || Instant::now() >= deadline {
                break;
            }
            for session in running {
                let _ = write_frame(&mut socket, &ClientMessage::Kill { id: session.id });
                let _ = read_frame::<_, ServerMessage>(&mut socket);
            }
            thread::sleep(Duration::from_millis(50));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

pub fn quiet_connect(path: &Path) -> Option<UnixStream> {
    let mut socket = UnixStream::connect(path).ok()?;
    let _ = socket.set_read_timeout(Some(Duration::from_millis(500)));
    let _ = socket.set_write_timeout(Some(Duration::from_millis(500)));
    write_frame(&mut socket, &ClientMessage::hello()).ok()?;
    read_frame::<_, ServerMessage>(&mut socket).ok()??;
    Some(socket)
}

pub fn spawn_serve(
    sandbox: &Sandbox,
    env: &[(String, String)],
    fd_limit: Option<FdLimit>,
) -> Child {
    spawn_serve_with_stderr(sandbox, env, fd_limit, Stdio::inherit())
}

pub fn spawn_serve_with_stderr(
    sandbox: &Sandbox,
    env: &[(String, String)],
    fd_limit: Option<FdLimit>,
    stderr: Stdio,
) -> Child {
    let mut command = sandbox.command("serve");
    command
        .envs(env.iter().map(|(k, v)| (k, v)))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(stderr);
    if let Some(limit) = fd_limit {
        unsafe {
            command.pre_exec(move || {
                let mut current: libc::rlimit = std::mem::zeroed();
                libc::getrlimit(libc::RLIMIT_NOFILE, &mut current);
                let limit = libc::rlimit {
                    rlim_cur: limit.soft as libc::rlim_t,
                    rlim_max: limit
                        .hard
                        .map_or(current.rlim_max, |hard| hard as libc::rlim_t),
                };
                if libc::setrlimit(libc::RLIMIT_NOFILE, &limit) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }
    command.spawn().unwrap()
}

/// The write end of a pipe whose reader is gone: every write fails with
/// EPIPE, as on a full disk or a closed journal stream.
pub fn broken_pipe() -> Stdio {
    use std::os::unix::io::{FromRawFd, OwnedFd};
    let mut fds = [0; 2];
    assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
    unsafe {
        libc::close(fds[0]);
        // Only the daemon gets it (as its stderr).
        libc::fcntl(fds[1], libc::F_SETFD, libc::FD_CLOEXEC);
        Stdio::from(OwnedFd::from_raw_fd(fds[1]))
    }
}

pub fn wait_child(child: &mut Child, timeout: Duration) -> std::process::ExitStatus {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status;
        }
        assert!(Instant::now() < deadline, "process did not exit");
        thread::sleep(Duration::from_millis(10));
    }
}

pub fn receive(socket: &mut UnixStream) -> ServerMessage {
    read_frame(socket)
        .unwrap()
        .expect("unexpected connection EOF")
}

pub fn create_request(request_id: String, command: Vec<String>) -> ClientMessage {
    ClientMessage::Create {
        request_id,
        name: "test".into(),
        cwd: "/tmp".into(),
        command,
        env: BTreeMap::new(),
        cols: 80,
        rows: 24,
    }
}

pub fn shell(script: &str) -> Vec<String> {
    vec!["/bin/sh".into(), "-c".into(), script.into()]
}

/// A shell script that can use `$CHERRY_TEST_DIR` (clients cannot set
/// arbitrary session environment variables).
pub fn shell_in(dir: &Path, script: &str) -> Vec<String> {
    shell(&format!(
        "CHERRY_TEST_DIR='{}'; export CHERRY_TEST_DIR\n{script}",
        dir.display()
    ))
}

pub fn send(socket: &mut UnixStream, message: &ClientMessage) {
    write_frame(socket, message).unwrap();
}

pub fn input(socket: &mut UnixStream, data: &[u8]) {
    send(
        socket,
        &ClientMessage::Input {
            data: data.to_vec(),
        },
    );
}

pub fn wait_until(description: &str, predicate: impl Fn() -> bool) {
    wait_until_for(description, Duration::from_secs(5), predicate)
}

pub fn wait_until_for(description: &str, timeout: Duration, predicate: impl Fn() -> bool) {
    let deadline = Instant::now() + timeout;
    while !predicate() {
        assert!(
            Instant::now() < deadline,
            "timed out waiting for {description}"
        );
        thread::sleep(Duration::from_millis(15));
    }
}

/// A renderer following one attachment: snapshot plus in-order output.
pub struct Screen {
    pub terminal: Terminal,
    pub offset: u64,
    pub cols: u16,
    pub rows: u16,
    pub attached: Vec<AttachReason>,
    pub exit: Option<(u32, Option<i32>)>,
    /// The queries this attachment was sent to answer, each with the output
    /// offset it came at.
    pub queries: Vec<(u64, Vec<u8>)>,
}

impl Screen {
    pub fn new(cols: u16, rows: u16, offset: u64, snapshot: &[u8]) -> Self {
        let mut terminal = Terminal::new(cols, rows, 1024 * 1024).unwrap();
        terminal.feed(snapshot);
        Self {
            terminal,
            offset,
            cols,
            rows,
            attached: Vec::new(),
            exit: None,
            queries: Vec::new(),
        }
    }

    pub fn text(&self) -> String {
        self.terminal.screen_text().unwrap()
    }

    /// Apply one message; returns it for callers that inspect it.
    pub fn receive(&mut self, socket: &mut UnixStream) -> ServerMessage {
        let message = receive(socket);
        self.apply(&message);
        message
    }

    pub fn apply(&mut self, message: &ServerMessage) {
        match message {
            ServerMessage::Output { offset, data } => {
                assert_eq!(
                    *offset, self.offset,
                    "live output must resume at the snapshot's exact boundary"
                );
                self.offset += data.len() as u64;
                self.terminal.feed(data);
            }
            ServerMessage::Attached {
                reason,
                session,
                offset,
                snapshot,
            } => {
                let mut replacement = Self::new(session.cols, session.rows, *offset, snapshot);
                replacement.attached = std::mem::take(&mut self.attached);
                replacement.attached.push(*reason);
                replacement.exit = self.exit;
                replacement.queries = std::mem::take(&mut self.queries);
                *self = replacement;
            }
            ServerMessage::Query { data } => self.queries.push((self.offset, data.clone())),
            ServerMessage::Exit {
                exit_code, signal, ..
            } => self.exit = Some((*exit_code, *signal)),
            ServerMessage::Pong => {}
            other => panic!("unexpected screen message: {other:?}"),
        }
    }

    /// Apply messages until `done` holds. Bounded overall, since heartbeat
    /// replies alone would keep a read timeout from ever firing.
    fn receive_until(&mut self, socket: &mut UnixStream, what: &str, done: impl Fn(&Self) -> bool) {
        let deadline = Instant::now() + SCREEN_WAIT;
        while !done(self) {
            assert!(
                Instant::now() < deadline,
                "timed out waiting for {what}:\n{}",
                self.text()
            );
            match read_frame::<_, ServerMessage>(socket) {
                Ok(Some(message)) => self.apply(&message),
                Ok(None) => panic!("connection closed waiting for {what}:\n{}", self.text()),
                Err(error) => panic!("{error} waiting for {what}:\n{}", self.text()),
            }
        }
    }

    pub fn wait_text(&mut self, socket: &mut UnixStream, needle: &str) {
        self.receive_until(socket, &format!("{needle:?}"), |screen| {
            screen.text().contains(needle)
        });
    }

    pub fn wait_size(&mut self, socket: &mut UnixStream, cols: u16, rows: u16) {
        self.receive_until(socket, &format!("{cols}x{rows}"), |screen| {
            (screen.cols, screen.rows) == (cols, rows)
        });
    }

    pub fn wait_exit(&mut self, socket: &mut UnixStream) -> (u32, Option<i32>) {
        self.receive_until(socket, "the exit", |screen| screen.exit.is_some());
        self.exit.unwrap()
    }
}

/// The longest any screen wait may take.
const SCREEN_WAIT: Duration = Duration::from_secs(60);

/// Whether a process exists and is not a zombie.
pub fn is_live(pid: i32) -> bool {
    // ps is portable between macOS and Linux, unlike /proc.
    let output = Command::new("/bin/ps")
        .args(["-p", &pid.to_string(), "-o", "stat="])
        .output()
        .unwrap();
    let status = String::from_utf8_lossy(&output.stdout);
    !status.trim().is_empty() && !status.trim().starts_with('Z')
}

pub fn read_pid(path: &Path) -> i32 {
    wait_until(&format!("{}", path.display()), || {
        fs::read_to_string(path).is_ok_and(|s| s.trim().parse::<i32>().is_ok())
    });
    fs::read_to_string(path).unwrap().trim().parse().unwrap()
}

/// Kills a stray test process on drop, but only while it is still the
/// process the test started (same PID and process group).
pub struct Stray {
    pub pid: i32,
    group: i32,
}

impl Stray {
    pub fn new(pid: i32) -> Self {
        Self {
            pid,
            group: unsafe { libc::getpgid(pid) },
        }
    }
}

impl Drop for Stray {
    fn drop(&mut self) {
        if self.group > 0 && unsafe { libc::getpgid(self.pid) } == self.group {
            unsafe {
                libc::kill(self.pid, libc::SIGKILL);
            }
        }
    }
}

/// Stop a daemon that a test started with `cherry-host start`: kill its
/// sessions, shut it down and wait for its socket to disappear.
pub fn stop_daemon(socket: &Path) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        let Some(mut connection) = quiet_connect(socket) else {
            break;
        };
        let _ = write_frame(&mut connection, &ClientMessage::List);
        let Ok(Some(ServerMessage::Sessions { sessions, .. })) = read_frame(&mut connection) else {
            break;
        };
        let running: Vec<_> = sessions
            .into_iter()
            .filter(|s| s.state == SessionState::Running)
            .collect();
        if running.is_empty() {
            let _ = write_frame(&mut connection, &ClientMessage::Shutdown);
            let _ = read_frame::<_, ServerMessage>(&mut connection);
            break;
        }
        for session in running {
            let _ = write_frame(&mut connection, &ClientMessage::Kill { id: session.id });
            let _ = read_frame::<_, ServerMessage>(&mut connection);
        }
        thread::sleep(Duration::from_millis(50));
    }
    while socket.exists() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(10));
    }
}

/// Stops a daemon started with `cherry-host start` when dropped.
pub struct Started(pub PathBuf);

impl Drop for Started {
    fn drop(&mut self) {
        stop_daemon(&self.0);
    }
}
