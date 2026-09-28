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
    /// The cherry-host executable to run.
    pub bin: PathBuf,
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
            bin: BIN.into(),
        }
    }

    pub fn path(&self) -> &Path {
        self.dir.path()
    }

    /// `cherry-host <action> --socket <this socket>` with this HOME.
    pub fn command(&self, action: &str) -> Command {
        let mut command = Command::new(&self.bin);
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
    /// Daemons `respawn` replaced that may not have exited yet.
    retired: Vec<Child>,
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
            retired: Vec::new(),
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

    /// Kill this daemon without warning (SIGKILL), as a crash would end it.
    /// Its sessions carry on in their holders.
    pub fn crash(&mut self) {
        self.child.kill().unwrap();
        self.child.wait().unwrap();
    }

    /// Start another daemon on the same socket and state directory, after
    /// `crash` or a `Replace`, whether or not the previous one has exited
    /// (see `wait_retired`).
    pub fn respawn(&mut self) {
        let env = self.env.clone();
        let previous = std::mem::replace(
            &mut self.child,
            spawn_serve(&self.sandbox, &env, self.fd_limit),
        );
        self.retired.push(previous);
        self.wait_ready();
    }

    /// How the daemons `respawn` replaced exited.
    pub fn wait_retired(&mut self) -> Vec<std::process::ExitStatus> {
        self.retired
            .drain(..)
            .map(|mut child| wait_child(&mut child, Duration::from_secs(5)))
            .collect()
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

    /// The sessions, once this daemon (a new one, after `respawn`) has
    /// every holder it expects: they register as soon as its socket
    /// appears, but a loaded machine may take longer than the one wait its
    /// first List makes for them.
    pub fn adopted(&self) -> Vec<SessionInfo> {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            match self.call(ClientMessage::List) {
                ServerMessage::Sessions {
                    sessions,
                    pending_holders: 0,
                    ..
                } => return sessions,
                ServerMessage::Sessions {
                    pending_holders, ..
                } => assert!(
                    Instant::now() < deadline,
                    "{pending_holders} holders never registered"
                ),
                other => panic!("list failed {other:?}"),
            }
            thread::sleep(Duration::from_millis(15));
        }
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
                client_id: None,
                cell_width: None,
                cell_height: None,
            },
        )
        .unwrap();
        match receive(&mut socket) {
            ServerMessage::Attached {
                reason,
                session,
                offset,
                snapshot,
                ..
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
        // Also clean up if an assertion fails. Sessions live in holders,
        // which outlive the daemon: end and remove every session, so its
        // holder exits, then stop the daemon and whatever holder is left.
        end_sessions(&self.socket);
        for child in self.retired.iter_mut().chain([&mut self.child]) {
            let _ = child.kill();
            let _ = child.wait();
        }
        kill_holders(&self.sandbox);
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

/// Kill every running session of the daemon at `socket` and remove every
/// session, so their holders exit. Gives up after a few seconds.
pub fn end_sessions(socket: &Path) {
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        let Some(mut connection) = quiet_connect(socket) else {
            break;
        };
        // A List can wait for holders to register.
        let _ = connection.set_read_timeout(Some(Duration::from_secs(2)));
        let _ = write_frame(&mut connection, &ClientMessage::List);
        let Ok(Some(ServerMessage::Sessions { sessions, .. })) = read_frame(&mut connection) else {
            break;
        };
        if sessions.is_empty() || Instant::now() >= deadline {
            break;
        }
        for session in sessions {
            let request = match session.state {
                SessionState::Running => ClientMessage::Kill { id: session.id },
                SessionState::Exited => ClientMessage::Remove { id: session.id },
            };
            let _ = write_frame(&mut connection, &request);
            let _ = read_frame::<_, ServerMessage>(&mut connection);
        }
        thread::sleep(Duration::from_millis(50));
    }
}

/// The holder processes of a sandbox's sessions, from their manifests:
/// session ID and holder PID.
pub fn holders(sandbox: &Sandbox) -> Vec<(String, i32)> {
    let Ok(states) = fs::read_dir(sandbox.state_base()) else {
        return Vec::new();
    };
    states
        .flatten()
        .filter_map(|state| fs::read_dir(state.path().join("sessions")).ok())
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let manifest: serde_json::Value =
                serde_json::from_slice(&fs::read(entry.path()).ok()?).ok()?;
            Some((
                manifest["id"].as_str()?.to_string(),
                i32::try_from(manifest["holder_pid"].as_u64()?).ok()?,
            ))
        })
        .collect()
}

/// The holder of session `id`, once its manifest is written.
pub fn holder_of(sandbox: &Sandbox, id: &str) -> i32 {
    wait_until(&format!("the holder of {id}"), || {
        holders(sandbox).iter().any(|(session, _)| session == id)
    });
    holders(sandbox)
        .into_iter()
        .find(|(session, _)| session == id)
        .unwrap()
        .1
}

/// Whether `pid` is a live `cherry-host hold` process.
pub fn is_holder(pid: i32) -> bool {
    let output = Command::new("/bin/ps")
        .args(["-p", &pid.to_string(), "-o", "stat=,command="])
        .output()
        .unwrap();
    let status = String::from_utf8_lossy(&output.stdout);
    let status = status.trim();
    !status.is_empty() && !status.starts_with('Z') && status.contains(" hold ")
}

/// The processes whose parent is `pid`.
pub fn children(pid: i32) -> Vec<i32> {
    // ps is portable between macOS and Linux, unlike /proc.
    let output = Command::new("/bin/ps")
        .args(["-A", "-o", "pid=,ppid="])
        .output()
        .unwrap();
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

/// Kill the holders a sandbox's daemons left behind (a test that failed
/// with its daemon down): their programs get the hangup.
pub fn kill_holders(sandbox: &Sandbox) {
    for (_, pid) in holders(sandbox) {
        if is_holder(pid) {
            kill_holder(pid);
        }
    }
}

/// SIGKILL a holder and its session's program (its child, which leads a
/// process group of its own): a program that ignores the hangup would
/// otherwise run on.
pub fn kill_holder(pid: i32) {
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

/// A connection subscribed to events: the host's `Ok` has come.
pub fn subscribe(host: &Host) -> UnixStream {
    let mut socket = host.connect();
    write_frame(&mut socket, &ClientMessage::Subscribe).unwrap();
    assert_eq!(receive(&mut socket), ServerMessage::Ok);
    socket
}

/// The next event on a subscribed connection.
pub fn next_event(socket: &mut UnixStream) -> SessionEvent {
    match receive(socket) {
        ServerMessage::Event { event } => event,
        other => panic!("expected an event, not {other:?}"),
    }
}

/// Whether no process has this ID any more: it has exited and been reaped.
pub fn is_gone(pid: u32) -> bool {
    let output = Command::new("/bin/ps")
        .args(["-p", &pid.to_string(), "-o", "stat="])
        .output()
        .unwrap();
    String::from_utf8_lossy(&output.stdout).trim().is_empty()
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
        owner: None,
        tags: BTreeMap::new(),
        colors: None,
    }
}

pub fn shell(script: &str) -> Vec<String> {
    vec!["/bin/sh".into(), "-c".into(), script.into()]
}

/// A shell script that can use `$CHERRY_TEST_DIR`, set by the script itself
/// so that `create` needs no environment.
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
    /// The grid sizes the host announced without a snapshot (`Resized`).
    pub resized: Vec<(u16, u16)>,
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
            resized: Vec::new(),
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
                ..
            } => {
                let mut replacement = Self::new(session.cols, session.rows, *offset, snapshot);
                replacement.attached = std::mem::take(&mut self.attached);
                replacement.attached.push(*reason);
                replacement.resized = std::mem::take(&mut self.resized);
                replacement.exit = self.exit;
                replacement.queries = std::mem::take(&mut self.queries);
                *self = replacement;
            }
            // The grid changed size here, and the program repaints: the
            // copy follows, as a renderer's does.
            ServerMessage::Resized { offset, cols, rows } => {
                assert_eq!(*offset, self.offset, "a resize is placed in the stream");
                self.terminal.resize(*cols, *rows).unwrap();
                (self.cols, self.rows) = (*cols, *rows);
                self.resized.push((*cols, *rows));
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

    /// Apply messages until `done` holds; `what` names it in a timeout.
    pub fn wait_for(&mut self, socket: &mut UnixStream, what: &str, done: impl Fn(&Self) -> bool) {
        self.receive_until(socket, what, done)
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

/// Stop a daemon that a test started with `cherry-host start`: end and
/// remove its sessions (so their holders exit), shut it down and wait for
/// its socket to disappear.
pub fn stop_daemon(socket: &Path) {
    end_sessions(socket);
    if let Some(mut connection) = quiet_connect(socket) {
        let _ = connection.set_read_timeout(Some(Duration::from_secs(5)));
        let _ = write_frame(&mut connection, &ClientMessage::Shutdown);
        let _ = read_frame::<_, ServerMessage>(&mut connection);
    }
    let deadline = Instant::now() + Duration::from_secs(5);
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

/// The holder link (see `src/link.rs`), spelled out here so that the tests
/// pin its wire format: `length:u32be kind:u8 version:u16be
/// meta_length:u32be meta data`.
pub mod link {
    use std::io::{self, Read, Write};

    pub const HOLDER_HELLO: u8 = 1;
    pub const OUTPUT: u8 = 2;
    pub const QUERY: u8 = 3;
    pub const SNAPSHOT_REPLY: u8 = 4;
    pub const INPUT_ACK: u8 = 5;
    pub const DETACH_DONE: u8 = 6;
    pub const EXITED: u8 = 7;
    pub const FAILED: u8 = 8;
    pub const INFO: u8 = 9;
    pub const EVENT: u8 = 10;
    pub const SCREEN_REPLY: u8 = 11;
    pub const HISTORY_CLEARED: u8 = 12;
    pub const LAUNCH: u8 = 64;
    pub const INPUT: u8 = 65;
    pub const DISCARD_LEASE: u8 = 66;
    pub const DETACH: u8 = 67;
    pub const RESIZE: u8 = 68;
    pub const SNAPSHOT: u8 = 69;
    pub const KILL: u8 = 70;
    pub const REMOVE: u8 = 71;
    pub const SCREEN: u8 = 72;
    pub const UPDATE: u8 = 73;
    pub const REFUSED: u8 = 74;
    pub const ATTENDED: u8 = 75;
    pub const PACE: u8 = 76;
    pub const CLEAR_HISTORY: u8 = 77;
    /// What this build's daemon and holders speak.
    pub const VERSION: u16 = 8;

    #[derive(Debug)]
    pub struct Frame {
        pub kind: u8,
        pub version: u16,
        pub meta: serde_json::Value,
        pub data: Vec<u8>,
    }

    pub fn encode(kind: u8, version: u16, meta: &serde_json::Value, data: &[u8]) -> Vec<u8> {
        let meta = serde_json::to_vec(meta).unwrap();
        let length = 1 + 2 + 4 + meta.len() + data.len();
        let mut frame = Vec::new();
        frame.extend_from_slice(&(length as u32).to_be_bytes());
        frame.push(kind);
        frame.extend_from_slice(&version.to_be_bytes());
        frame.extend_from_slice(&(meta.len() as u32).to_be_bytes());
        frame.extend_from_slice(&meta);
        frame.extend_from_slice(data);
        frame
    }

    pub fn send(
        stream: &mut impl Write,
        kind: u8,
        version: u16,
        meta: serde_json::Value,
        data: &[u8],
    ) {
        stream
            .write_all(&encode(kind, version, &meta, data))
            .unwrap();
    }

    /// The next frame; None at end of file.
    pub fn read(stream: &mut impl Read) -> io::Result<Option<Frame>> {
        let mut length = [0u8; 4];
        match stream.read(&mut length[..1])? {
            0 => return Ok(None),
            _ => stream.read_exact(&mut length[1..])?,
        }
        let mut body = vec![0; u32::from_be_bytes(length) as usize];
        stream.read_exact(&mut body)?;
        let meta_length = u32::from_be_bytes(body[3..7].try_into().unwrap()) as usize;
        Ok(Some(Frame {
            kind: body[0],
            version: u16::from_be_bytes([body[1], body[2]]),
            meta: serde_json::from_slice(&body[7..7 + meta_length]).unwrap(),
            data: body[7 + meta_length..].to_vec(),
        }))
    }

    /// The next frame, which must come.
    pub fn next(stream: &mut impl Read) -> Frame {
        read(stream).unwrap().expect("the link closed")
    }

    /// Frames until one of `kind`, which is returned; the others are
    /// passed to `each`.
    pub fn until(stream: &mut impl Read, kind: u8, mut each: impl FnMut(&Frame)) -> Frame {
        loop {
            let frame = next(stream);
            if frame.kind == kind {
                return frame;
            }
            each(&frame);
        }
    }
}
