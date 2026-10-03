//! Starting, trusting, identifying and keeping the daemon alive.
mod support;

use cherry_protocol::*;
use std::{
    collections::{BTreeMap, HashMap},
    fs::{self, File},
    io::Write,
    os::unix::{
        fs::{MetadataExt, PermissionsExt},
        io::AsRawFd,
        net::{UnixListener, UnixStream},
        process::CommandExt,
    },
    path::{Path, PathBuf},
    process::{Command, Output, Stdio},
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    },
    thread,
    time::{Duration, Instant},
};
use support::*;
use uuid::Uuid;

/// The documented cap, including exited sessions.
const MAX_SESSIONS: usize = 128;

/// A listener that is not a cherry-host daemon, counting connections.
struct Impostor {
    accepted: Arc<AtomicUsize>,
}

fn impostor(path: &Path, reply: Option<ServerMessage>) -> Impostor {
    let listener = UnixListener::bind(path).unwrap();
    let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o777));
    let accepted = Arc::new(AtomicUsize::new(0));
    let counter = accepted.clone();
    thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else {
                continue;
            };
            counter.fetch_add(1, Ordering::SeqCst);
            let reply = reply.clone();
            thread::spawn(move || {
                if let Some(reply) = reply {
                    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
                    let _ = read_frame::<_, ClientMessage>(&mut stream);
                    let _ = write_frame(&mut stream, &reply);
                }
                thread::sleep(Duration::from_secs(5));
            });
        }
    });
    Impostor { accepted }
}

fn welcome() -> ServerMessage {
    ServerMessage::Welcome {
        version: PROTOCOL_VERSION,
        host_id: Uuid::new_v4().to_string(),
        build: None,
    }
}

fn run(mut command: Command, stdin: &[u8]) -> Output {
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let _ = child.stdin.take().unwrap().write_all(stdin);
    child.wait_with_output().unwrap()
}

fn hello() -> Vec<u8> {
    encode_frame(&ClientMessage::hello()).unwrap()
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

/// `cherry-host <action> --socket <socket>` with a private HOME.
fn command(sandbox: &Sandbox, action: &str, socket: &Path) -> Command {
    let mut command = Command::new(BIN);
    command
        .arg(action)
        .arg("--socket")
        .arg(socket)
        .env("HOME", &sandbox.home)
        .env_remove("XDG_STATE_HOME")
        .env_remove("CHERRY_HOST_SOCKET")
        .env_remove(EXPECTED_HOST_ID_VAR);
    command
}

/// Every way a client reaches a host: each must verify what it connects to.
const CLIENT_ACTIONS: &[&[&str]] = &[&["start"], &["gateway"], &["gateway", "--no-start"]];

/// `cherry-host <action…> --socket <socket>` with a private HOME.
fn client_command(sandbox: &Sandbox, action: &[&str], socket: &Path) -> Command {
    let mut command = command(sandbox, action[0], socket);
    command.args(&action[1..]);
    command
}

#[test]
fn start_and_gateway_never_trust_a_directory_others_can_enter() {
    let sandbox = Sandbox::new();
    for mode in [0o755, 0o777] {
        let dir = sandbox.path().join(format!("shared-{mode:o}"));
        fs::create_dir(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(mode)).unwrap();
        let socket = dir.join("host.sock");
        let fake = impostor(&socket, Some(welcome()));
        let started = run(command(&sandbox, "start", &socket), b"");
        assert!(!started.status.success());
        let message = stderr(&started);
        assert!(message.contains("CHERRY_HOST_SOCKET"), "{message}");
        assert!(
            message.contains(&format!("owned by uid {}", unsafe { libc::geteuid() })),
            "{message}"
        );
        assert!(message.contains("0700"), "{message}");
        for action in &CLIENT_ACTIONS[1..] {
            let gateway = run(client_command(&sandbox, action, &socket), &hello());
            assert!(!gateway.status.success(), "{action:?}");
            assert!(
                gateway.stdout.is_empty(),
                "{action:?} relayed to an impostor"
            );
            assert!(stderr(&gateway).contains("0700"), "{}", stderr(&gateway));
        }
        assert_eq!(fake.accepted.load(Ordering::SeqCst), 0);
        // Nothing was spawned in its place either.
        assert!(!sandbox.home.join("Library").exists());
        assert!(!sandbox.home.join(".local").exists());
    }
    // A symlink to a private directory is not trusted either.
    let real = sandbox.path().join("real");
    fs::create_dir(&real).unwrap();
    fs::set_permissions(&real, fs::Permissions::from_mode(0o700)).unwrap();
    let fake = impostor(&real.join("host.sock"), Some(welcome()));
    let link = sandbox.path().join("link");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    for action in &CLIENT_ACTIONS[1..] {
        let gateway = run(
            client_command(&sandbox, action, &link.join("host.sock")),
            &hello(),
        );
        assert!(!gateway.status.success());
        assert!(gateway.stdout.is_empty());
        assert!(stderr(&gateway).contains("symlink"), "{}", stderr(&gateway));
    }
    assert_eq!(fake.accepted.load(Ordering::SeqCst), 0);
    // Relative socket paths are refused before anything is touched.
    for action in CLIENT_ACTIONS.iter().chain([&["serve"][..]].iter()) {
        let output = run(
            client_command(&sandbox, action, Path::new("relative/host.sock")),
            b"",
        );
        assert!(!output.status.success());
        assert!(
            stderr(&output).contains("must be absolute"),
            "{}",
            stderr(&output)
        );
    }
}

#[test]
fn serve_refuses_unsafe_socket_paths_and_creates_private_ones() {
    let sandbox = Sandbox::new();
    let shared = sandbox.path().join("shared");
    fs::create_dir(&shared).unwrap();
    fs::set_permissions(&shared, fs::Permissions::from_mode(0o755)).unwrap();
    let output = run(command(&sandbox, "serve", &shared.join("host.sock")), b"");
    assert!(!output.status.success());
    assert!(stderr(&output).contains("mode 0700"), "{}", stderr(&output));

    let occupied = sandbox.path().join("occupied");
    fs::create_dir(&occupied).unwrap();
    fs::set_permissions(&occupied, fs::Permissions::from_mode(0o700)).unwrap();
    fs::write(occupied.join("host.sock"), b"not a socket").unwrap();
    let output = run(command(&sandbox, "serve", &occupied.join("host.sock")), b"");
    assert!(!output.status.success());
    let message = stderr(&output);
    assert!(message.contains("refusing to replace"), "{message}");
    assert!(message.contains("is a regular file"), "{message}");
    // start and gateway name the file, not the (fine) directory.
    for action in CLIENT_ACTIONS {
        let output = run(
            client_command(&sandbox, action, &occupied.join("host.sock")),
            &hello(),
        );
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        let message = stderr(&output);
        assert!(
            message.contains(&format!(
                "cannot use {}: it is a regular file",
                occupied.join("host.sock").display()
            )),
            "{message}"
        );
        assert!(message.contains("Remove it"), "{message}");
        assert!(!message.contains("socket directory"), "{message}");
    }
    assert_eq!(
        fs::read(occupied.join("host.sock")).unwrap(),
        b"not a socket"
    );

    // A missing directory is created private; the socket is owner-only.
    let fresh = sandbox.path().join("fresh");
    let socket = fresh.join("host.sock");
    assert!(run(command(&sandbox, "start", &socket), b"")
        .status
        .success());
    let _daemon = Started(socket.clone());
    assert_eq!(fs::metadata(&fresh).unwrap().mode() & 0o7777, 0o700);
    assert_eq!(fs::symlink_metadata(&socket).unwrap().mode() & 0o777, 0o600);
}

#[test]
fn a_live_socket_is_never_replaced_even_without_its_lock_file() {
    let host = Host::new();
    let id = host.host_id();
    let session = host.create(shell("exec sleep 60"));
    // A tmp cleaner or a user deleted the lock file.
    fs::remove_file(host.sandbox.state_dir().join("host.lock")).unwrap();
    let second = run(host.sandbox.command("serve"), b"");
    assert!(!second.status.success());
    assert!(
        stderr(&second).contains("already serving"),
        "{}",
        stderr(&second)
    );
    assert_eq!(host.host_id(), id);
    assert_eq!(host.session(&session.id).state, SessionState::Running);
}

#[test]
fn stale_sockets_are_replaced_and_the_identity_survives_restarts() {
    let mut host = Host::new();
    let id = host.host_id();
    let state = host.sandbox.state_dir();
    // Durable state lives outside the socket directory.
    for name in ["host-id", "host.lock"] {
        assert!(state.join(name).exists(), "{name}");
        assert!(!host.dir().join(name).exists(), "{name}");
    }
    assert_eq!(fs::metadata(&state).unwrap().mode() & 0o7777, 0o700);
    #[cfg(target_os = "macos")]
    assert!(state.starts_with(
        host.sandbox
            .home
            .join("Library/Application Support/cherry-host")
    ));

    // A clean shutdown removes the socket.
    assert!(matches!(
        host.call(ClientMessage::Shutdown),
        ServerMessage::Ok
    ));
    assert!(wait_child(&mut host.child, Duration::from_secs(5)).success());
    assert!(!host.socket.exists());
    host.child = spawn_serve(&host.sandbox, &[], None);
    host.wait_ready();
    assert_eq!(host.host_id(), id);

    // A crash leaves a stale socket behind; the next daemon replaces it.
    host.child.kill().unwrap();
    host.child.wait().unwrap();
    assert!(host.socket.exists());
    host.child = spawn_serve(&host.sandbox, &[], None);
    host.wait_ready();
    assert_eq!(host.host_id(), id);
    host.restart();
    assert_eq!(host.host_id(), id);
}

#[test]
fn concurrent_first_starts_share_one_daemon() {
    let sandbox = Sandbox::new();
    let socket = sandbox.path().join("fresh").join("host.sock");
    let starts: Vec<_> = (0..8)
        .map(|_| {
            let socket = socket.clone();
            let home = sandbox.home.clone();
            thread::spawn(move || {
                Command::new(BIN)
                    .args(["start", "--socket"])
                    .arg(&socket)
                    .env("HOME", home)
                    .env_remove("XDG_STATE_HOME")
                    .output()
                    .unwrap()
            })
        })
        .collect();
    let _daemon = Started(socket.clone());
    for start in starts {
        let output = start.join().unwrap();
        assert!(output.status.success(), "{}", stderr(&output));
    }
    let daemons = Command::new("pgrep")
        .args(["-f", &format!("serve --socket {}", socket.display())])
        .output()
        .unwrap();
    assert_eq!(
        String::from_utf8_lossy(&daemons.stdout).lines().count(),
        1,
        "{}",
        String::from_utf8_lossy(&daemons.stdout)
    );
}

#[test]
fn auto_started_daemons_give_sessions_a_clean_environment() {
    let sandbox = Sandbox::new();
    let started = sandbox
        .command("start")
        .env("CHERRY_PROCESS_ID", "1111")
        .env("CHERRY_AGENT_ID", "2222")
        .env("FOO", "bar")
        .env("SSH_AUTH_SOCK", "/tmp/ssh-dead/agent.1")
        // A script's locale: LC_ALL would override any LANG a later client
        // asks for.
        .env("LANG", "C")
        .env("LC_ALL", "C")
        .env("LC_CTYPE", "POSIX")
        .env("TZ", "Asia/Tokyo")
        .current_dir(sandbox.path())
        .status()
        .unwrap();
    assert!(started.success());
    let _daemon = Started(sandbox.socket.clone());
    let mut socket = quiet_connect(&sandbox.socket).unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let env_file = sandbox.path().join("env");
    send(
        &mut socket,
        &ClientMessage::Create {
            request_id: Uuid::new_v4().to_string(),
            name: "env".into(),
            cwd: "/tmp".into(),
            command: shell(&format!(
                "env > '{0}.tmp' && mv '{0}.tmp' '{0}'; exec sleep 60",
                env_file.display()
            )),
            env: BTreeMap::from([
                ("LANG".into(), "en_US.UTF-8".into()),
                ("TZ".into(), "UTC".into()),
            ]),
            cols: 80,
            rows: 24,
            owner: None,
            tags: BTreeMap::new(),
            colors: None,
            cell_width: None,
            cell_height: None,
        },
    );
    let session = match receive(&mut socket) {
        ServerMessage::Created { session } => session,
        other => panic!("{other:?}"),
    };
    wait_until("session environment", || env_file.exists());
    let env: HashMap<String, String> = fs::read_to_string(&env_file)
        .unwrap()
        .lines()
        .filter_map(|line| {
            let (key, value) = line.split_once('=')?;
            Some((key.to_string(), value.to_string()))
        })
        .collect();
    for leaked in [
        "CHERRY_PROCESS_ID",
        "CHERRY_AGENT_ID",
        "FOO",
        "LC_ALL",
        "LC_CTYPE",
    ] {
        assert!(
            !env.contains_key(leaked),
            "{leaked} leaked into the session"
        );
    }
    assert_eq!(
        env.get("SSH_AUTH_SOCK").map(PathBuf::from),
        Some(sandbox.path().join(AGENT_LINK_NAME))
    );
    assert_eq!(env.get("LANG").map(String::as_str), Some("en_US.UTF-8"));
    assert_eq!(env.get("TZ").map(String::as_str), Some("UTC"));
    assert_eq!(
        env.get("HOME").map(PathBuf::from),
        Some(sandbox.home.clone())
    );
    assert_eq!(env.get("TERM").map(String::as_str), Some("xterm-256color"));
    assert_eq!(env.get("CHERRY_SESSION_ID"), Some(&session.id));
    assert_ne!(
        env.get("PWD").map(String::as_str),
        Some(sandbox.path().to_str().unwrap())
    );
    assert!(env.contains_key("PATH"));
}

#[test]
fn the_daemon_does_not_keep_descriptors_of_whoever_started_it() {
    let sandbox = Sandbox::new();
    // Like `exec 9>deploy.lock; flock -n 9` in a script that then runs cherry.
    let lock_path = sandbox.path().join("script.lock");
    let lock = File::create(&lock_path).unwrap();
    assert_eq!(
        unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
        0
    );
    let fd = lock.as_raw_fd();
    let mut start = sandbox.command("start");
    unsafe {
        start.pre_exec(move || {
            // dup2 clears close-on-exec on the copy.
            if libc::dup2(fd, 42) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    assert!(start.status().unwrap().success());
    let _daemon = Started(sandbox.socket.clone());
    drop(lock);
    let again = File::open(&lock_path).unwrap();
    // A child another test forked (and has not yet exec'd) can hold a copy
    // for a moment; a daemon that kept one would hold it for good.
    wait_until("the daemon to release the starter's lock file", || unsafe {
        libc::flock(again.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) == 0
    });
}

fn fd_listing(text: &str) -> Vec<u32> {
    let mut fds: Vec<u32> = text
        .split_whitespace()
        .map(|fd| fd.parse().unwrap())
        .collect();
    fds.sort();
    fds
}

/// What `ls /dev/fd` lists when only 0, 1 and 2 are inherited: `ls` opens
/// descriptors of its own (one on Linux, two on macOS).
fn clean_fd_listing() -> Vec<u32> {
    let mut command = Command::new("/bin/sh");
    command
        .args(["-c", "ls /dev/fd"])
        .current_dir("/tmp")
        .stdin(Stdio::null())
        .stderr(Stdio::null());
    unsafe {
        command.pre_exec(|| {
            for fd in 3..1024 {
                libc::close(fd);
            }
            Ok(())
        });
    }
    let output = command.output().unwrap();
    assert!(output.status.success());
    fd_listing(&String::from_utf8_lossy(&output.stdout))
}

#[test]
fn sessions_inherit_only_their_terminal() {
    let host = Host::new();
    let clean = clean_fd_listing();
    // Connections accepted while sessions start: a descriptor the accept
    // loop has not yet marked close-on-exec must still not leak.
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let hammer = {
        let socket = host.socket.clone();
        let stop = stop.clone();
        thread::spawn(move || {
            while !stop.load(Ordering::SeqCst) {
                drop(UnixStream::connect(&socket));
                // Leave room in the listen backlog for the test's requests.
                thread::sleep(Duration::from_micros(100));
            }
        })
    };
    let count = 40;
    for n in 0..count {
        let listing = host.dir().join(format!("fds-{n}"));
        host.create(shell(&format!(
            "ls /dev/fd > '{0}.tmp' && mv '{0}.tmp' '{0}'; exec sleep 60",
            listing.display()
        )));
    }
    stop.store(true, Ordering::SeqCst);
    hammer.join().unwrap();
    for n in 0..count {
        let listing = host.dir().join(format!("fds-{n}"));
        wait_until("descriptor listing", || listing.exists());
        assert_eq!(
            fd_listing(&fs::read_to_string(&listing).unwrap()),
            clean,
            "session {n} inherited descriptors"
        );
    }
}

#[test]
fn the_gateway_announces_itself_and_repoints_the_agent_link() {
    let host = Host::new();
    let agents = tempfile::Builder::new()
        .prefix("ch-agent-")
        .tempdir_in("/tmp")
        .unwrap();
    for name in ["first.sock", "second.sock"] {
        let agent = agents.path().join(name);
        let _listener = UnixListener::bind(&agent).unwrap();
        let gateway = LendingGateway::start(&host, &agent);
        assert_eq!(
            fs::read_link(host.dir().join(AGENT_LINK_NAME)).unwrap(),
            agent
        );
        gateway.finish();
    }
}

/// A gateway that lends `agent` and stays connected until `finish`.
struct LendingGateway {
    child: std::process::Child,
}

impl LendingGateway {
    fn start(host: &Host, agent: &Path) -> Self {
        let mut child = host
            .sandbox
            .command("gateway")
            .env("SSH_AUTH_SOCK", agent)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        child.stdin.as_mut().unwrap().write_all(&hello()).unwrap();
        // The link is updated before the preamble is written.
        let stdout = child.stdout.as_mut().unwrap();
        let preamble = format!("CHERRY-GATEWAY {PROTOCOL_VERSION}\n").into_bytes();
        let mut announced = vec![0; preamble.len()];
        std::io::Read::read_exact(stdout, &mut announced).unwrap();
        assert_eq!(announced, preamble);
        assert!(matches!(
            read_frame::<_, ServerMessage>(stdout).unwrap(),
            Some(ServerMessage::Welcome { .. })
        ));
        Self { child }
    }

    /// Close its input, as when the SSH connection ends.
    fn finish(mut self) {
        drop(self.child.stdin.take());
        assert!(wait_child(&mut self.child, Duration::from_secs(5)).success());
    }

    /// Kill it, leaving no chance to clean up.
    fn kill(mut self) {
        self.child.kill().unwrap();
        self.child.wait().unwrap();
    }
}

impl Drop for LendingGateway {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Agents owned by this user, in a private directory with a short path.
struct Agents {
    dir: tempfile::TempDir,
    listeners: Vec<UnixListener>,
}

impl Agents {
    fn new() -> Self {
        let dir = tempfile::Builder::new()
            .prefix("ch-agent-")
            .tempdir_in("/tmp")
            .unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        Self {
            dir,
            listeners: Vec::new(),
        }
    }

    fn add(&mut self, name: &str) -> PathBuf {
        let path = self.dir.path().join(name);
        self.listeners.push(UnixListener::bind(&path).unwrap());
        path
    }
}

#[test]
fn a_clients_agent_is_lent_to_sessions_only_while_that_client_is_connected() {
    let host = Host::with_env(&[("CHERRY_HOST_AGENT_GRACE_MS", "300")]);
    let mut agents = Agents::new();
    let (first, second, third) = (agents.add("a1"), agents.add("a2"), agents.add("a3"));
    let link = host.dir().join(AGENT_LINK_NAME);
    let current = || fs::read_link(&link).ok();
    let one = LendingGateway::start(&host, &first);
    assert_eq!(current(), Some(first.clone()));
    let two = LendingGateway::start(&host, &second);
    assert_eq!(current(), Some(second.clone()));
    // The most recent client leaves: the link returns to the agent of the
    // client still connected.
    two.finish();
    wait_until("the link to return to the first agent", || {
        current() == Some(first.clone())
    });
    // Also when a client is killed without any chance to clean up.
    let three = LendingGateway::start(&host, &third);
    assert_eq!(current(), Some(third.clone()));
    three.kill();
    wait_until("the link to return after a kill", || {
        current() == Some(first.clone())
    });
    // Once nobody lends an agent, sessions get none rather than a path its
    // owner gives up (sshd removes a forwarded agent's directory in /tmp),
    // which another local user could create again.
    one.finish();
    wait_until("the link to be removed", || {
        fs::symlink_metadata(&link).is_err()
    });
    let clients = host.dir().join(AGENT_CLIENTS_DIR);
    let left: Vec<_> = fs::read_dir(&clients)
        .unwrap()
        .map(|entry| entry.unwrap().file_name())
        .filter(|name| !name.to_string_lossy().starts_with('.'))
        .collect();
    assert!(left.is_empty(), "{left:?}");
}

#[test]
fn a_client_that_keeps_running_lends_its_agent_until_its_last_connection_ends() {
    let host = Host::with_env(&[("CHERRY_HOST_AGENT_GRACE_MS", "300")]);
    let mut agents = Agents::new();
    let agent = agents.add("agent");
    let link = host.dir().join(AGENT_LINK_NAME);
    // As the local CLI does: connect, then lend the caller's agent.
    let first = host.connect();
    update_agent_link(host.dir(), Some(agent.as_os_str())).unwrap();
    assert_eq!(fs::read_link(&link).unwrap(), agent);
    let second = host.connect();
    drop(first);
    // Far longer than the grace period for a client between connections.
    thread::sleep(Duration::from_millis(1200));
    assert_eq!(fs::read_link(&link).unwrap(), agent);
    drop(second);
    // This process keeps running without a connection.
    wait_until("the link to be removed", || {
        fs::symlink_metadata(&link).is_err()
    });
}

#[test]
fn a_client_that_exits_leaves_its_agent_to_the_next_client_for_a_moment() {
    // The default grace period.
    let host = Host::new();
    let mut agents = Agents::new();
    let agent = agents.add("agent");
    let link = host.dir().join(AGENT_LINK_NAME);
    // As `cherry new` does: lend the agent, start a session, and exit.
    let new = LendingGateway::start(&host, &agent);
    let session = host.create(shell_in(
        host.dir(),
        r#"while [ ! -e "$CHERRY_TEST_DIR/go" ]; do sleep 0.02; done
if [ -S "$SSH_AUTH_SOCK" ]; then echo agent; else echo none; fi > "$CHERRY_TEST_DIR/checking"
mv "$CHERRY_TEST_DIR/checking" "$CHERRY_TEST_DIR/checked"; exec sleep 60"#,
    ));
    new.finish();
    // The session's first command, which runs after that, still reaches it.
    fs::write(host.dir().join("go"), b"").unwrap();
    wait_until("the session's check", || {
        host.dir().join("checked").exists()
    });
    assert_eq!(
        fs::read_to_string(host.dir().join("checked")).unwrap(),
        "agent\n"
    );
    // The `cherry attach` that follows keeps it lent after that grace
    // period is over.
    let attach = LendingGateway::start(&host, &agent);
    thread::sleep(Duration::from_millis(2500));
    assert_eq!(fs::read_link(&link).unwrap(), agent);
    attach.finish();
    wait_until("the link to be removed", || {
        fs::symlink_metadata(&link).is_err()
    });
    host.kill(&session.id);
}

#[test]
fn an_agent_that_goes_away_is_given_up_even_while_its_client_stays() {
    // Far longer than this test: only the agents going away end the lending.
    let host = Host::with_env(&[("CHERRY_HOST_AGENT_GRACE_MS", "60000")]);
    let mut agents = Agents::new();
    let (first, second) = (agents.add("a1"), agents.add("a2"));
    let link = host.dir().join(AGENT_LINK_NAME);
    let current = || fs::read_link(&link).ok();
    let one = LendingGateway::start(&host, &first);
    let two = LendingGateway::start(&host, &second);
    assert_eq!(current(), Some(second.clone()));
    // The second client stays connected while its agent goes away
    // (`ssh-agent -k`): the link must not keep naming a path that another
    // user could create.
    fs::remove_file(&second).unwrap();
    wait_until("the link to return to the first agent", || {
        current() == Some(first.clone())
    });
    // A client that left lends its agent for a while longer, but not once
    // the agent is gone (sshd removes it with the SSH connection).
    one.finish();
    assert_eq!(current(), Some(first.clone()));
    fs::remove_file(&first).unwrap();
    wait_until("the link to be removed", || {
        fs::symlink_metadata(&link).is_err()
    });
    two.finish();
}

#[test]
fn sessions_never_start_with_the_agent_of_a_client_that_is_gone() {
    let host = Host::new();
    let mut agents = Agents::new();
    let agent = agents.add("agent");
    let link = host.dir().join(AGENT_LINK_NAME);
    // A client that lent its agent and exited without the daemon seeing its
    // connection end (it was refused at the connection limit, say).
    let mut gone = Command::new("/bin/sh")
        .args(["-c", "exit 0"])
        .spawn()
        .unwrap();
    let pid = gone.id();
    gone.wait().unwrap();
    let clients = host.dir().join(AGENT_CLIENTS_DIR);
    std::os::unix::fs::DirBuilderExt::mode(&mut fs::DirBuilder::new(), 0o700)
        .create(&clients)
        .unwrap();
    std::os::unix::fs::symlink(&agent, clients.join(pid.to_string())).unwrap();
    std::os::unix::fs::symlink(&agent, &link).unwrap();
    let session = host.create(shell("exec sleep 60"));
    assert!(fs::symlink_metadata(&link).is_err());
    assert!(fs::symlink_metadata(clients.join(pid.to_string())).is_err());
    host.kill(&session.id);
}

#[test]
fn a_new_host_can_start_as_soon_as_shutdown_is_acknowledged() {
    let sandbox = Sandbox::new();
    let _daemon = Started(sandbox.socket.clone());
    for round in 0..5 {
        let output = sandbox.command("start").output().unwrap();
        assert!(
            output.status.success(),
            "round {round}: {}",
            stderr(&output)
        );
        // Another client stays connected across the shutdown, which keeps
        // the old daemon running for a moment.
        let idle = quiet_connect(&sandbox.socket).unwrap();
        let mut socket = quiet_connect(&sandbox.socket).unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(10)))
            .unwrap();
        send(&mut socket, &ClientMessage::Shutdown);
        assert!(matches!(receive(&mut socket), ServerMessage::Ok));
        assert!(
            fs::symlink_metadata(&sandbox.socket).is_err(),
            "round {round}: the socket outlived the acknowledgement"
        );
        // As `cherry shutdown; cherry list` does.
        let output = sandbox.command("start").output().unwrap();
        assert!(
            output.status.success(),
            "round {round}: {}",
            stderr(&output)
        );
        assert!(quiet_connect(&sandbox.socket).is_some());
        drop(idle);
    }
}

/// The daemon's answer to `request`, asked again while it closes
/// connections unanswered: short of descriptors, it can accept a connection
/// and then have none to serve it with. Gives up after 20 s.
fn call_while_short(host: &Host, request: &ClientMessage) -> ServerMessage {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let answer = quiet_connect(&host.socket).and_then(|mut socket| {
            socket.set_read_timeout(Some(Duration::from_secs(5))).ok()?;
            write_frame(&mut socket, request).ok()?;
            read_frame::<_, ServerMessage>(&mut socket).ok()?
        });
        if let Some(answer) = answer {
            return answer;
        }
        assert!(
            Instant::now() < deadline,
            "the daemon never answered {request:?}"
        );
        thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn a_log_that_cannot_be_written_never_stops_the_daemon() {
    // Every write to stderr fails (EPIPE), where `eprintln!` would panic.
    let mut host = Host::launch_with_stderr(
        Sandbox::new(),
        &[],
        Some(FdLimit {
            soft: 64,
            hard: Some(64),
        }),
        broken_pipe(),
    );
    // Out of descriptors, every accept is reported.
    let mut sessions = Vec::new();
    while sessions.len() < 64 {
        let Some(mut socket) = quiet_connect(&host.socket) else {
            break;
        };
        let _ = socket.set_read_timeout(Some(Duration::from_secs(5)));
        let request = create_request(Uuid::new_v4().to_string(), shell("exec sleep 60"));
        if write_frame(&mut socket, &request).is_err() {
            break;
        }
        match read_frame::<_, ServerMessage>(&mut socket) {
            Ok(Some(ServerMessage::Created { session })) => sessions.push(session),
            _ => break,
        }
    }
    let burst: Vec<UnixStream> = (0..100)
        .filter_map(|_| UnixStream::connect(&host.socket).ok())
        .collect();
    thread::sleep(Duration::from_millis(500));
    assert!(
        host.child.try_wait().unwrap().is_none(),
        "the daemon exited"
    );
    drop(burst);
    // Descriptors come free as the daemon closes those connections; until
    // then it may still accept a connection and close it unanswered.
    for session in &sessions {
        let killed = call_while_short(
            &host,
            &ClientMessage::Kill {
                id: session.id.clone(),
            },
        );
        assert_eq!(killed, ServerMessage::Ok);
    }
    wait_until("the sessions to exit", || {
        let ServerMessage::Sessions {
            sessions: listed, ..
        } = call_while_short(&host, &ClientMessage::List)
        else {
            panic!("the daemon did not list its sessions");
        };
        sessions.iter().all(|session| {
            listed
                .iter()
                .any(|s| s.id == session.id && s.state == SessionState::Exited)
        })
    });
    // A diagnostic while starting: the host identity is replaced.
    let id = host.host_id();
    fs::write(host.sandbox.state_dir().join("host-id"), b"garbage").unwrap();
    host.restart_with_stderr(broken_pipe());
    assert_ne!(host.host_id(), id);
}

#[test]
fn only_a_client_speaking_a_newer_protocol_replaces_the_daemon() {
    let mut host = Host::new();
    let id = host.host_id();
    let hello = |version: u32| {
        let mut socket = UnixStream::connect(&host.socket).unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        write_frame(
            &mut socket,
            &Request::new(Some(1), ClientMessage::Hello { version }),
        )
        .unwrap();
        assert!(matches!(
            read_frame(&mut socket).unwrap(),
            Some(Response {
                req: Some(1),
                message: ServerMessage::Welcome {
                    version: PROTOCOL_VERSION,
                    host_id,
                    ..
                },
            }) if host_id == id
        ));
        socket
    };
    // A client speaking an older protocol is refused.
    let mut older = hello(PROTOCOL_VERSION - 1);
    write_frame(&mut older, &Request::new(Some(2), ClientMessage::Replace)).unwrap();
    assert!(matches!(
        read_frame(&mut older).unwrap(),
        Some(Response {
            req: Some(2),
            message: ServerMessage::Error { code, .. },
        }) if code == error_code::VERSION_MISMATCH
    ));
    assert!(read_frame::<_, Response>(&mut older).unwrap().is_none());
    assert_eq!(host.host_id(), id);
    // A newer one replaces it even while sessions run: they carry on in
    // their holders. It is answered once the socket is gone and the lock is
    // free.
    let session = host.create(shell(
        "stty -echo; printf 'BEFORE_%s\\n' REPLACE; while IFS= read -r line; do printf 'INPUT:%s\\n' \"$line\"; done",
    ));
    let (mut attached, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    screen.wait_text(&mut attached, "BEFORE_REPLACE");
    let mut newer = hello(PROTOCOL_VERSION + 1);
    write_frame(&mut newer, &Request::new(Some(3), ClientMessage::Replace)).unwrap();
    assert_eq!(
        read_frame::<_, Response>(&mut newer).unwrap(),
        Some(Response::new(Some(3), ServerMessage::Ok))
    );
    assert!(!host.socket.exists());
    let status = wait_child(&mut host.child, Duration::from_secs(5));
    assert!(status.success(), "host exited with {status}");
    // Its clients are disconnected.
    while let Ok(Some(_)) = read_frame::<_, ServerMessage>(&mut attached) {}
    // Its successor starts on the same socket, with the same identity, and
    // lists the session at once: the same program, the same screen.
    host.child = spawn_serve(&host.sandbox, &[], None);
    host.wait_ready();
    assert_eq!(host.host_id(), id);
    let adopted = host.session(&session.id);
    assert_eq!(adopted.state, SessionState::Running);
    assert_eq!(adopted.pid, session.pid);
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    assert!(
        screen.text().contains("BEFORE_REPLACE"),
        "{}",
        screen.text()
    );
    input(&mut socket, b"AFTER\n");
    screen.wait_text(&mut socket, "INPUT:AFTER");
}

#[test]
fn start_and_gateway_never_start_a_second_daemon_beside_another_version() {
    let sandbox = Sandbox::new();
    // One too old to make way (it refuses a Hello of another version), and
    // a newer one, which is never replaced.
    for (reply, version, advice) in [
        (
            ServerMessage::error(
                "version_mismatch",
                "expected Cherry host protocol version 2",
            ),
            "protocol 2".to_string(),
            "stop it",
        ),
        (
            ServerMessage::Welcome {
                version: PROTOCOL_VERSION + 1,
                host_id: Uuid::new_v4().to_string(),
                build: None,
            },
            format!("protocol {}", PROTOCOL_VERSION + 1),
            "newer than this cherry-host",
        ),
    ] {
        let dir = sandbox.path().join(version.replace(' ', "-"));
        fs::create_dir(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        let socket = dir.join("host.sock");
        let fake = impostor(&socket, Some(reply));
        for action in CLIENT_ACTIONS {
            let output = run(client_command(&sandbox, action, &socket), &hello());
            assert!(!output.status.success());
            let message = stderr(&output);
            assert!(
                message.contains(&format!("a cherry-host speaking {version} is running")),
                "{message}"
            );
            assert!(message.contains(advice), "{message}");
            assert!(output.stdout.is_empty(), "{action:?} relayed");
        }
        assert!(fake.accepted.load(Ordering::SeqCst) >= CLIENT_ACTIONS.len());
        // No daemon was started, so no state was created, and the old
        // daemon's socket is untouched.
        assert!(!sandbox.home.join("Library").exists());
        assert!(!sandbox.home.join(".local").exists());
        assert!(socket.exists());
    }
}

/// A host speaking the protocol before this one, as it answers: every
/// Hello with a Welcome of its own version, and a `Replace` from a newer
/// client by removing its socket, answering Ok and listening no more. What
/// it was sent, in order.
fn older_host(path: &Path) -> Arc<std::sync::Mutex<Vec<ClientMessage>>> {
    host_speaking(path, PROTOCOL_VERSION - 1, "older-host")
}

/// A host speaking `version` as `host_id`, as `older_host` describes.
fn host_speaking(
    path: &Path,
    version: u32,
    host_id: &str,
) -> Arc<std::sync::Mutex<Vec<ClientMessage>>> {
    let listener = UnixListener::bind(path).unwrap();
    let host_id = host_id.to_owned();
    let requests = Arc::new(std::sync::Mutex::new(Vec::new()));
    let heard = requests.clone();
    let path = path.to_path_buf();
    thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else {
                continue;
            };
            let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
            let mut replaced = false;
            while let Ok(Some(request)) = read_frame::<_, ClientMessage>(&mut stream) {
                heard.lock().unwrap().push(request.clone());
                let reply = match request {
                    ClientMessage::Hello { .. } => ServerMessage::Welcome {
                        version,
                        host_id: host_id.clone(),
                        build: None,
                    },
                    ClientMessage::Replace => {
                        fs::remove_file(&path).unwrap();
                        replaced = true;
                        ServerMessage::Ok
                    }
                    _ => ServerMessage::error("version_mismatch", "only replace"),
                };
                let _ = write_frame(&mut stream, &reply);
                if replaced {
                    break;
                }
            }
            if replaced {
                return;
            }
        }
    });
    requests
}

#[test]
fn only_the_gateway_replaces_a_daemon_speaking_an_older_protocol_and_starts_its_own() {
    let sandbox = Sandbox::new();
    let requests = older_host(&sandbox.socket);
    // Neither `start` nor a gateway that may not start a host replaces
    // it: they say what does.
    for action in [&["start"][..], &["gateway", "--no-start"]] {
        let output = run(client_command(&sandbox, action, &sandbox.socket), &hello());
        assert!(!output.status.success(), "{action:?}");
        let message = stderr(&output);
        assert!(
            message.contains(&format!(
                "a cherry-host speaking protocol {} is running",
                PROTOCOL_VERSION - 1
            )),
            "{message}"
        );
        assert!(message.contains("replace it"), "{message}");
        assert!(output.stdout.is_empty(), "{action:?} relayed");
    }
    assert!(!requests.lock().unwrap().contains(&ClientMessage::Replace));
    assert!(!sandbox.home.join("Library").exists());
    assert!(!sandbox.home.join(".local").exists());
    // The gateway asks it to make way, as a client of this version does,
    // starts a daemon of its own and relays to it.
    let _started = Started(sandbox.socket.clone());
    let output = run(
        client_command(&sandbox, &["gateway"], &sandbox.socket),
        &hello(),
    );
    assert!(output.status.success(), "{}", stderr(&output));
    let preamble = format!("CHERRY-GATEWAY {PROTOCOL_VERSION}\n");
    assert!(
        output.stdout.starts_with(preamble.as_bytes()),
        "{:?}",
        String::from_utf8_lossy(&output.stdout)
    );
    let mut relayed = &output.stdout[preamble.len()..];
    match read_frame::<_, ServerMessage>(&mut relayed).unwrap() {
        Some(ServerMessage::Welcome {
            version, host_id, ..
        }) => {
            assert_eq!(version, PROTOCOL_VERSION);
            assert_ne!(host_id, "older-host");
        }
        other => panic!("expected the new daemon's welcome, not {other:?}"),
    }
    let requests = requests.lock().unwrap().clone();
    assert_eq!(
        requests
            .iter()
            .filter(|r| **r == ClientMessage::Replace)
            .count(),
        1,
        "{requests:?}"
    );
    assert_eq!(requests.last(), Some(&ClientMessage::Replace));
    // The new daemon serves the socket now.
    let mut socket = quiet_connect(&sandbox.socket).expect("the new daemon");
    write_frame(&mut socket, &ClientMessage::List).unwrap();
    assert!(matches!(
        read_frame::<_, ServerMessage>(&mut socket).unwrap(),
        Some(ServerMessage::Sessions { .. })
    ));
}

/// On Linux a client starts the enabled systemd user service rather than a
/// daemon of its own. When the unit's ExecStart runs an older cherry-host,
/// replacing the host it started only starts that one again: the report
/// says so, names the program, and starts like every report of another
/// version (which the CLI relies on).
#[cfg(target_os = "linux")]
#[test]
fn a_service_that_starts_an_older_host_is_reported_with_its_program() {
    let sandbox = Sandbox::new();
    let bin = sandbox.path().join("bin");
    fs::create_dir(&bin).unwrap();
    let started = sandbox.path().join("unit-started");
    // A user manager whose enabled unit serves this socket, with the
    // previous cherry-host as its ExecStart.
    let systemctl = bin.join("systemctl");
    fs::write(
        &systemctl,
        format!(
            "#!/bin/sh\n[ \"$1\" = --user ] || exit 1\ncase \"$2\" in\n  is-enabled) exit 0 ;;\n  show-environment) printf 'LANG=C.UTF-8\\nCHERRY_HOST_SOCKET=%s\\n' '{}' ;;\n  show) echo 'ExecStart={{ path=/opt/previous/cherry-host ; argv[]=/opt/previous/cherry-host serve ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }}' ;;\n  start) : > '{}' ;;\n  *) exit 1 ;;\nesac\n",
            sandbox.socket.display(),
            started.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&systemctl, fs::Permissions::from_mode(0o755)).unwrap();
    // Each start of the unit runs the previous cherry-host (a fake here).
    let (sender, runs) = std::sync::mpsc::channel();
    let socket = sandbox.socket.clone();
    thread::spawn(move || {
        for _ in 0..2 {
            let deadline = Instant::now() + Duration::from_secs(15);
            while !started.exists() {
                if Instant::now() >= deadline {
                    return;
                }
                thread::sleep(Duration::from_millis(10));
            }
            fs::remove_file(&started).unwrap();
            if sender.send(older_host(&socket)).is_err() {
                return;
            }
        }
    });
    let command = |action: &[&str]| {
        let mut command = client_command(&sandbox, action, &sandbox.socket);
        let path = std::env::var("PATH").unwrap_or_default();
        command.env("PATH", format!("{}:{path}", bin.display()));
        command
    };
    let expected = format!(
        "cherry-host: a cherry-host speaking protocol {} is running at {}: the systemd user service cherry-host.service started it, and its ExecStart runs that older cherry-host (/opt/previous/cherry-host); install this version (protocol {PROTOCOL_VERSION}, ",
        PROTOCOL_VERSION - 1,
        sandbox.socket.display()
    );
    // Nothing runs: starting the unit starts the previous version.
    let output = run(command(&["start"]), b"");
    assert!(!output.status.success());
    assert!(
        stderr(&output).starts_with(&expected),
        "{}",
        stderr(&output)
    );
    let first = runs.recv_timeout(Duration::from_secs(5)).unwrap();
    // The gateway replaces it, and the unit brings it back.
    let output = run(command(&["gateway"]), &hello());
    assert!(!output.status.success());
    assert!(output.stdout.is_empty(), "relayed");
    assert!(
        stderr(&output).starts_with(&expected),
        "{}",
        stderr(&output)
    );
    let replaced = first.lock().unwrap().clone();
    assert_eq!(
        replaced.last(),
        Some(&ClientMessage::Replace),
        "{replaced:?}"
    );
    let second = runs.recv_timeout(Duration::from_secs(5)).unwrap();
    assert!(!second.lock().unwrap().contains(&ClientMessage::Replace));
    // No daemon of this version was started beside the unit.
    assert!(!sandbox.home.join(".local").exists());
}

/// Stops a daemon of this version serving the socket when dropped, if one
/// does; a fake host of another version is left alone.
struct StartedIfAny(PathBuf);

impl Drop for StartedIfAny {
    fn drop(&mut self) {
        let Ok(mut connection) = UnixStream::connect(&self.0) else {
            return;
        };
        let _ = connection.set_read_timeout(Some(Duration::from_secs(2)));
        let ours = write_frame(&mut connection, &ClientMessage::hello()).is_ok()
            && matches!(
                read_frame::<_, ServerMessage>(&mut connection),
                Ok(Some(ServerMessage::Welcome { version, .. })) if version == PROTOCOL_VERSION
            );
        drop(connection);
        if ours {
            stop_daemon(&self.0);
        }
    }
}

#[test]
fn a_gateway_neither_replaces_nor_reports_a_host_of_another_identity() {
    // A local client checks a host's identity before its version: a host
    // that is not the intended one is neither used nor replaced. A gateway
    // told the identity its client expects relays such a host untouched,
    // for the client to refuse its Welcome.
    let preamble = format!("CHERRY-GATEWAY {PROTOCOL_VERSION}\n");
    let welcome_of = |output: &Output| {
        assert!(output.status.success(), "{}", stderr(output));
        assert!(
            output.stdout.starts_with(preamble.as_bytes()),
            "{:?}",
            String::from_utf8_lossy(&output.stdout)
        );
        let mut relayed = &output.stdout[preamble.len()..];
        match read_frame::<_, ServerMessage>(&mut relayed).unwrap() {
            Some(ServerMessage::Welcome {
                version, host_id, ..
            }) => (version, host_id),
            other => panic!("expected a welcome, not {other:?}"),
        }
    };
    let gateway = |sandbox: &Sandbox, action: &[&str], expected: &str| {
        let mut command = client_command(sandbox, action, &sandbox.socket);
        command.env(EXPECTED_HOST_ID_VAR, expected);
        run(command, &hello())
    };
    for version in [PROTOCOL_VERSION - 1, PROTOCOL_VERSION + 1] {
        let sandbox = Sandbox::new();
        // Should a gateway start a daemon, it is stopped however this ends.
        let _started = StartedIfAny(sandbox.socket.clone());
        let requests = host_speaking(&sandbox.socket, version, "another-host");
        for action in [&["gateway"][..], &["gateway", "--no-start"]] {
            let output = gateway(&sandbox, action, "intended-host");
            assert_eq!(
                welcome_of(&output),
                (version, "another-host".to_string()),
                "{action:?}"
            );
            assert_eq!(stderr(&output), "", "{action:?}");
        }
        assert!(!requests.lock().unwrap().contains(&ClientMessage::Replace));
        assert!(!sandbox.home.join("Library").exists());
        assert!(!sandbox.home.join(".local").exists());
        assert!(sandbox.socket.exists());
        if version > PROTOCOL_VERSION {
            // The intended one: reported, as without an expected identity.
            let output = gateway(&sandbox, &["gateway"], "another-host");
            assert!(!output.status.success());
            assert!(output.stdout.is_empty());
            assert!(
                stderr(&output).contains("newer than this cherry-host"),
                "{}",
                stderr(&output)
            );
            continue;
        }
        // The intended one: replaced, as without an expected identity.
        let output = gateway(&sandbox, &["gateway"], "another-host");
        let (version, host_id) = welcome_of(&output);
        assert_eq!(version, PROTOCOL_VERSION);
        assert_ne!(host_id, "another-host");
        let requests = requests.lock().unwrap().clone();
        assert_eq!(
            requests.last(),
            Some(&ClientMessage::Replace),
            "{requests:?}"
        );
    }
}

#[test]
fn start_reports_a_listener_that_does_not_answer_instead_of_replacing_it() {
    let sandbox = Sandbox::new();
    let fake = impostor(&sandbox.socket, None);
    let started = Instant::now();
    let output = run(sandbox.command("start"), b"");
    assert!(!output.status.success());
    assert!(
        stderr(&output).contains("did not answer"),
        "{}",
        stderr(&output)
    );
    assert!(started.elapsed() < Duration::from_secs(8));
    assert_eq!(fake.accepted.load(Ordering::SeqCst), 1);
    assert!(sandbox.socket.exists());
    let mut gateway = sandbox.command("gateway");
    gateway.arg("--no-start");
    let output = run(gateway, &hello());
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    assert!(
        stderr(&output).contains("did not answer"),
        "{}",
        stderr(&output)
    );
    assert_eq!(fake.accepted.load(Ordering::SeqCst), 2);
    assert!(sandbox.socket.exists());
}

#[test]
fn a_gateway_that_may_not_start_a_host_reports_that_none_is_running() {
    let sandbox = Sandbox::new();
    // A stale socket file: nothing listens on it any more.
    let stale = sandbox.path().join("stale");
    fs::create_dir(&stale).unwrap();
    fs::set_permissions(&stale, fs::Permissions::from_mode(0o700)).unwrap();
    drop(UnixListener::bind(stale.join("host.sock")).unwrap());
    for socket in [
        // No socket directory, as before the first host ever ran.
        sandbox.path().join("absent").join("host.sock"),
        // The directory, but no socket.
        sandbox.socket.clone(),
        stale.join("host.sock"),
    ] {
        let started = Instant::now();
        let output = run(
            client_command(&sandbox, &["gateway", "--no-start"], &socket),
            &hello(),
        );
        assert_eq!(output.status.code(), Some(1));
        assert!(output.stdout.is_empty(), "wrote the preamble");
        assert_eq!(
            stderr(&output),
            format!(
                "cherry-host: no cherry-host is running at {}\n",
                socket.display()
            )
        );
        assert!(started.elapsed() < Duration::from_secs(5));
    }
    // Nothing was created or started: no socket directory, no socket, no
    // state directory.
    assert!(!sandbox.path().join("absent").exists());
    assert!(!sandbox.socket.exists());
    assert!(stale.join("host.sock").exists());
    assert!(!sandbox.state_base().exists());

    // With a host running it relays like the plain gateway.
    let host = Host::new();
    let mut gateway = host.sandbox.command("gateway");
    gateway.arg("--no-start");
    let mut request = hello();
    request.extend(encode_frame(&ClientMessage::List).unwrap());
    let output = run(gateway, &request);
    assert!(output.status.success(), "{}", stderr(&output));
    let preamble = format!("CHERRY-GATEWAY {PROTOCOL_VERSION}\n").into_bytes();
    assert!(output.stdout.starts_with(&preamble));
    let mut frames = &output.stdout[preamble.len()..];
    assert!(matches!(
        read_frame::<_, ServerMessage>(&mut frames).unwrap(),
        Some(ServerMessage::Welcome { .. })
    ));
    assert!(matches!(
        read_frame::<_, ServerMessage>(&mut frames).unwrap(),
        Some(ServerMessage::Sessions { host_id, .. }) if host_id == host.host_id()
    ));
}

#[test]
fn running_out_of_descriptors_never_stops_the_daemon() {
    let mut host = Host::with_fd_limit(64);
    let try_call = |request: &ClientMessage| {
        let mut socket = quiet_connect(&host.socket)?;
        socket.set_read_timeout(Some(Duration::from_secs(5))).ok()?;
        write_frame(&mut socket, request).ok()?;
        read_frame::<_, ServerMessage>(&mut socket).ok()?
    };
    let mut sessions = Vec::new();
    loop {
        // Out of descriptors, a create fails, or its connection is dropped.
        match try_call(&create_request(
            Uuid::new_v4().to_string(),
            shell("exec sleep 60"),
        )) {
            Some(ServerMessage::Created { session }) => sessions.push(session),
            Some(ServerMessage::Error { message, .. }) => {
                assert!(message.contains("Too many open files"), "{message}");
                break;
            }
            None => break,
            Some(other) => panic!("{other:?}"),
        }
        assert!(sessions.len() < 64, "the descriptor limit was not applied");
    }
    assert!(sessions.len() >= 3, "{} sessions", sessions.len());
    // More connections than the daemon can hold descriptors for.
    let burst: Vec<UnixStream> = (0..100)
        .filter_map(|_| UnixStream::connect(&host.socket).ok())
        .collect();
    thread::sleep(Duration::from_millis(500));
    assert!(
        host.child.try_wait().unwrap().is_none(),
        "the daemon exited"
    );
    drop(burst);
    // Service resumes once those connections are gone.
    wait_until("service to resume", || {
        quiet_connect(&host.socket).is_some_and(|mut socket| {
            write_frame(&mut socket, &ClientMessage::List).is_ok()
                && matches!(
                    read_frame::<_, ServerMessage>(&mut socket),
                    Ok(Some(ServerMessage::Sessions { .. }))
                )
        })
    });
    for session in &sessions {
        assert_eq!(host.session(&session.id).state, SessionState::Running);
        assert_eq!(unsafe { libc::kill(session.pid.unwrap() as i32, 0) }, 0);
    }
    // Descriptors of removed sessions are available to a new one.
    for session in &sessions[..2] {
        host.kill(&session.id);
        host.wait(&session.id, |s| s.state == SessionState::Exited);
        assert!(matches!(
            host.call(ClientMessage::Remove {
                id: session.id.clone()
            }),
            ServerMessage::Ok
        ));
    }
    assert!(matches!(
        host.call(create_request(
            Uuid::new_v4().to_string(),
            shell("exec sleep 60")
        )),
        ServerMessage::Created { .. }
    ));
}

/// The peer check is the daemon's last line of defence once another user can
/// reach the socket path.
#[test]
#[ignore = "needs root, as in the Linux container suite"]
fn connections_from_other_users_are_dropped() {
    if unsafe { libc::geteuid() } != 0 {
        eprintln!("skipped: needs root");
        return;
    }
    let host = Host::new();
    fs::set_permissions(host.dir(), fs::Permissions::from_mode(0o711)).unwrap();
    fs::set_permissions(&host.socket, fs::Permissions::from_mode(0o777)).unwrap();
    let hello = hello();
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    address.sun_family = libc::AF_UNIX as _;
    for (slot, byte) in address
        .sun_path
        .iter_mut()
        .zip(host.socket.as_os_str().as_encoded_bytes())
    {
        *slot = *byte as libc::c_char;
    }
    let status = unsafe {
        match libc::fork() {
            0 => {
                if libc::setgid(65534) != 0 || libc::setuid(65534) != 0 {
                    libc::_exit(2);
                }
                let fd = libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0);
                if libc::connect(
                    fd,
                    (&address as *const libc::sockaddr_un).cast(),
                    std::mem::size_of::<libc::sockaddr_un>() as libc::socklen_t,
                ) != 0
                {
                    libc::_exit(3);
                }
                let timeout = libc::timeval {
                    tv_sec: 3,
                    tv_usec: 0,
                };
                libc::setsockopt(
                    fd,
                    libc::SOL_SOCKET,
                    libc::SO_RCVTIMEO,
                    (&timeout as *const libc::timeval).cast(),
                    std::mem::size_of::<libc::timeval>() as libc::socklen_t,
                );
                libc::write(fd, hello.as_ptr().cast(), hello.len());
                let mut buffer = [0u8; 64];
                let n = libc::read(fd, buffer.as_mut_ptr().cast(), buffer.len());
                let timed_out = n < 0
                    && std::io::Error::last_os_error().kind() == std::io::ErrorKind::WouldBlock;
                // Closed without an answer (EOF, or a reset because the hello
                // was never read): 0. Answered: 1. Neither within 3 s: 4.
                libc::_exit(if n > 0 {
                    1
                } else if timed_out {
                    4
                } else {
                    0
                });
            }
            pid => {
                let mut status = 0;
                libc::waitpid(pid, &mut status, 0);
                status
            }
        }
    };
    fs::set_permissions(host.dir(), fs::Permissions::from_mode(0o700)).unwrap();
    assert!(libc::WIFEXITED(status));
    assert_eq!(libc::WEXITSTATUS(status), 0, "another user was served");
    assert!(host.sessions().is_empty());
}

#[cfg(target_os = "linux")]
#[test]
fn start_uses_the_enabled_systemd_service_for_the_default_socket() {
    let sandbox = Sandbox::new();
    let bin = sandbox.path().join("bin");
    fs::create_dir(&bin).unwrap();
    let systemctl = bin.join("systemctl");
    // The service runs in the user manager's environment, never the
    // client's. It is never started on the real built-in socket here.
    fs::write(
        &systemctl,
        r#"#!/bin/sh
echo "$*" >> "$FAKE_SYSTEMCTL_LOG"
case "$*" in
  *is-enabled*) exit "$FAKE_SYSTEMCTL_ENABLED" ;;
  *show-environment*)
    echo "HOME=$HOME"
    [ -z "$FAKE_MANAGER_SOCKET" ] || echo "CHERRY_HOST_SOCKET=$FAKE_MANAGER_SOCKET"
    exit 0 ;;
  *start*)
    [ -n "$FAKE_MANAGER_SOCKET" ] || exit 1
    CHERRY_HOST_SOCKET="$FAKE_MANAGER_SOCKET" setsid "$FAKE_HOST_BIN" serve </dev/null >/dev/null 2>&1 &
    exit 0 ;;
esac
exit 1
"#,
    )
    .unwrap();
    fs::set_permissions(&systemctl, fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap());
    let is_enabled = "--user is-enabled --quiet cherry-host.service";
    let show_environment = "--user show-environment";
    // `cherry-host start` with CHERRY_HOST_SOCKET=`socket_env` in the
    // client's environment only.
    let start = |socket_env: &Path,
                 explicit: Option<&Path>,
                 enabled: bool,
                 manager_socket: Option<&Path>,
                 log: &Path| {
        let mut command = Command::new(BIN);
        command.arg("start");
        if let Some(socket) = explicit {
            command.arg("--socket").arg(socket);
        }
        command
            .env("CHERRY_HOST_SOCKET", socket_env)
            .env("HOME", &sandbox.home)
            .env_remove("XDG_STATE_HOME")
            .env("PATH", &path)
            .env("FAKE_SYSTEMCTL_LOG", log)
            .env("FAKE_SYSTEMCTL_ENABLED", if enabled { "0" } else { "1" })
            .env(
                "FAKE_MANAGER_SOCKET",
                manager_socket.map_or(PathBuf::new(), Path::to_path_buf),
            )
            .env("FAKE_HOST_BIN", BIN);
        let output = command.output().unwrap();
        assert!(output.status.success(), "{}", stderr(&output));
    };
    let calls = |log: &Path| -> Vec<String> {
        fs::read_to_string(log)
            .unwrap_or_default()
            .lines()
            .map(str::to_string)
            .collect()
    };

    // Enabled, and the manager's environment points the service at this
    // socket: the service is started.
    let log = sandbox.path().join("enabled.log");
    start(&sandbox.socket, None, true, Some(&sandbox.socket), &log);
    let daemon = Started(sandbox.socket.clone());
    assert_eq!(
        calls(&log),
        [
            is_enabled,
            show_environment,
            "--user start cherry-host.service"
        ]
    );
    drop(daemon);

    // CHERRY_HOST_SOCKET set only in the client: the service serves the
    // built-in path, so the client starts its own daemon.
    let log = sandbox.path().join("client-only.log");
    start(&sandbox.socket, None, true, None, &log);
    let daemon = Started(sandbox.socket.clone());
    assert_eq!(calls(&log), [is_enabled, show_environment]);
    drop(daemon);

    // Disabled service: the client starts its own daemon.
    let log = sandbox.path().join("disabled.log");
    start(&sandbox.socket, None, false, Some(&sandbox.socket), &log);
    let daemon = Started(sandbox.socket.clone());
    assert_eq!(calls(&log), [is_enabled]);
    drop(daemon);

    // Another socket is never the service's.
    let other = sandbox.path().join("other.sock");
    let log = sandbox.path().join("other.log");
    start(
        &sandbox.socket,
        Some(&other),
        true,
        Some(&sandbox.socket),
        &log,
    );
    let _daemon = Started(other);
    assert_eq!(calls(&log), [is_enabled, show_environment]);
}

#[test]
fn each_socket_has_its_own_state_directory() {
    let first = Host::new();
    let second = Host::launch(
        Sandbox {
            home: first.sandbox.home.clone(),
            ..Sandbox::new()
        },
        &[],
        None,
    );
    let ids = [first.host_id(), second.host_id()];
    assert_ne!(ids[0], ids[1]);
    let mut stored: Vec<String> = fs::read_dir(first.sandbox.state_base())
        .unwrap()
        .map(|entry| fs::read_to_string(entry.unwrap().path().join("host-id")).unwrap())
        .collect();
    stored.sort();
    let mut expected = ids.to_vec();
    expected.sort();
    assert_eq!(stored, expected);
}

#[test]
fn the_session_cap_fits_a_default_shell_descriptor_limit() {
    // macOS shells start with a soft limit of 256; the daemon raises its own
    // soft limit, and its sessions keep the one the user had.
    let host = Host::with_soft_fd_limit(256);
    let limit_file = host.dir().join("limit");
    let mut ids = vec![
        host.create(shell(&format!(
            "ulimit -n > '{}'; exec sleep 60",
            limit_file.display()
        )))
        .id,
    ];
    while ids.len() < MAX_SESSIONS {
        ids.push(host.create(shell("exec sleep 60")).id);
    }
    let _attached: Vec<_> = ids[..32].iter().map(|id| host.attach(id, 80, 24)).collect();
    match host.call(create_request(
        Uuid::new_v4().to_string(),
        shell("exec sleep 60"),
    )) {
        ServerMessage::Error { message, .. } => {
            assert!(message.contains("session limit"), "{message}")
        }
        other => panic!("{other:?}"),
    }
    wait_until("session limit report", || limit_file.exists());
    assert_eq!(fs::read_to_string(&limit_file).unwrap().trim(), "256");
    assert_eq!(host.sessions().len(), MAX_SESSIONS);
}

#[test]
fn the_socket_and_its_directory_stay_fresh_for_tmp_cleaners() {
    let host = Host::with_env(&[("CHERRY_HOST_TOUCH_INTERVAL_MS", "100")]);
    // Age both, as an age-based cleaner would see them after an idle week.
    let old = libc::timespec {
        tv_sec: 1_000_000_000,
        tv_nsec: 0,
    };
    for path in [host.socket.as_path(), host.dir()] {
        let path = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
        assert_eq!(
            unsafe {
                libc::utimensat(
                    libc::AT_FDCWD,
                    path.as_ptr(),
                    [old, old].as_ptr(),
                    libc::AT_SYMLINK_NOFOLLOW,
                )
            },
            0
        );
    }
    wait_until("fresh timestamps", || {
        [host.socket.as_path(), host.dir()].iter().all(|path| {
            let meta = fs::symlink_metadata(path).unwrap();
            meta.mtime() > 1_000_000_000 && meta.atime() > 1_000_000_000
        })
    });
}

#[test]
fn a_connection_over_the_limit_is_told_why_and_the_log_says_so_once() {
    let sandbox = Sandbox::new();
    let log = sandbox.path().join("stderr.log");
    let mut host = Host::launch_with_stderr(
        sandbox,
        &[("CHERRY_HOST_MAX_CONNECTIONS", "2")],
        None,
        Stdio::from(File::create(&log).unwrap()),
    );
    let _held = (host.connect(), host.connect());
    // Every one after that gets an Error before its Welcome, and is closed.
    for _ in 0..3 {
        let mut refused = UnixStream::connect(&host.socket).unwrap();
        refused
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        match read_frame::<_, ServerMessage>(&mut refused) {
            Ok(Some(ServerMessage::Error { code, message })) => {
                assert_eq!(code, error_code::TOO_MANY_CONNECTIONS);
                assert!(message.contains("2 connections"), "{message}");
            }
            other => panic!("expected the refusal, not {other:?}"),
        }
        assert!(matches!(
            read_frame::<_, ServerMessage>(&mut refused),
            Ok(None) | Err(_)
        ));
    }
    // One line for the burst, not one per connection.
    let text = fs::read_to_string(&log).unwrap();
    assert_eq!(
        text.matches("refused a connection: already serving 2 connections")
            .count(),
        1,
        "{text}"
    );
    // A slot that frees up is used again.
    drop(_held);
    wait_until("a connection to be served again", || {
        quiet_connect(&host.socket).is_some()
    });
    let _ = host.child.kill();
}

#[test]
fn a_session_whose_holder_crashed_names_the_log_the_holder_wrote_to() {
    let sandbox = Sandbox::new();
    let started = sandbox.command("start").status().unwrap();
    assert!(started.success());
    let _daemon = Started(sandbox.socket.clone());
    let mut socket = quiet_connect(&sandbox.socket).unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    send(
        &mut socket,
        &create_request(Uuid::new_v4().to_string(), shell("exec sleep 60")),
    );
    let session = match receive(&mut socket) {
        ServerMessage::Created { session } => session,
        other => panic!("create failed: {other:?}"),
    };
    let _stray = Stray::new(session.pid.unwrap() as i32);
    unsafe {
        libc::kill(holder_of(&sandbox, &session.id), libc::SIGKILL);
    }
    let log = sandbox.state_dir().join("host.log");
    wait_until("the session to end", || {
        let mut socket = quiet_connect(&sandbox.socket).unwrap();
        send(&mut socket, &ClientMessage::List);
        let ServerMessage::Sessions { sessions, .. } = receive(&mut socket) else {
            return false;
        };
        sessions.iter().any(|s| {
            s.id == session.id
                && s.state == SessionState::Exited
                && s.ended_by.as_deref() == Some(ended_by::HOLDER_LOST)
                && s.holder_log.as_deref() == Some(log.to_str().unwrap())
        })
    });
}
