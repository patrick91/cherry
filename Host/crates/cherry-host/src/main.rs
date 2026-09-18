mod processes;
mod session;
mod stream;

use anyhow::{bail, Context, Result};
use cherry_protocol::{
    default_socket_path, read_frame, write_frame, ClientMessage, ServerMessage, SessionState,
    PROTOCOL_VERSION,
};
use clap::{Parser, Subcommand};
use session::{Command as SessionCommand, Session};
use std::{
    collections::HashMap,
    fs::{self, OpenOptions},
    io,
    os::unix::{
        fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt},
        io::AsRawFd,
        net::{UnixListener, UnixStream},
        process::CommandExt,
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc, Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};
use uuid::Uuid;

#[derive(Parser)]
#[command(about = "Portable persistent terminal host for Cherry", version)]
struct Args {
    #[arg(long, global = true)]
    socket: Option<PathBuf>,
    #[command(subcommand)]
    command: Action,
}
#[derive(Subcommand)]
enum Action {
    Start,
    Serve,
    Gateway,
}

fn main() {
    if let Err(e) = run() {
        eprintln!("cherry-host: {e:#}");
        std::process::exit(1);
    }
}
fn run() -> Result<()> {
    let args = Args::parse();
    let path = args.socket.unwrap_or_else(default_socket_path);
    match args.command {
        Action::Start => start(&path),
        Action::Serve => serve(&path),
        Action::Gateway => gateway(&path),
    }
}

fn ready(path: &Path) -> bool {
    let Ok(mut stream) = UnixStream::connect(path) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(1)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(1)));
    write_frame(
        &mut stream,
        &ClientMessage::Hello {
            version: PROTOCOL_VERSION,
        },
    )
    .is_ok()
        && matches!(
            read_frame(&mut stream),
            Ok(Some(ServerMessage::Welcome {
                version: PROTOCOL_VERSION,
                ..
            }))
        )
}

fn start(path: &Path) -> Result<()> {
    if ready(path) {
        return Ok(());
    }
    let dir = private_parent(path)?;
    let log = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(dir.join("host.log"))?;
    let mut command = Command::new(std::env::current_exe()?);
    command
        .arg("serve")
        .arg("--socket")
        .arg(path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(log);
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() < 0 {
                Err(io::Error::last_os_error())
            } else {
                Ok(())
            }
        });
    }
    let mut child = command.spawn().context("starting detached host")?;
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if ready(path) {
            return Ok(());
        }
        if let Some(status) = child.try_wait()? {
            if ready(path) {
                return Ok(());
            }
            bail!(
                "host exited ({status}); inspect {}",
                dir.join("host.log").display()
            );
        }
        thread::sleep(Duration::from_millis(30));
    }
    bail!(
        "host did not become ready; inspect {}",
        dir.join("host.log").display()
    )
}

fn gateway(path: &Path) -> Result<()> {
    start(path)?;
    let mut socket = UnixStream::connect(path)?;
    let mut input_socket = socket.try_clone()?;
    // Exiting this process closes the gateway connection, never the daemon.
    thread::spawn(move || {
        let _ = io::copy(&mut io::stdin().lock(), &mut input_socket);
        let _ = input_socket.shutdown(std::net::Shutdown::Write);
    });
    // stdout is line-buffered even when redirected. Protocol frames contain no
    // literal newline, so io::copy alone can withhold an entire handshake.
    use io::{Read, Write};
    let mut output = io::stdout().lock();
    let mut bytes = [0u8; 16384];
    loop {
        let n = socket.read(&mut bytes)?;
        if n == 0 {
            break;
        }
        output.write_all(&bytes[..n])?;
        output.flush()?;
    }
    Ok(())
}

fn private_parent(path: &Path) -> Result<PathBuf> {
    if !path.is_absolute() {
        bail!("socket path must be absolute");
    }
    if path.as_os_str().as_encoded_bytes().len() > 100 {
        bail!("socket path exceeds portable Unix socket path limit (100 bytes)");
    }
    let dir = path.parent().context("socket needs a parent directory")?;
    match fs::symlink_metadata(dir) {
        Ok(meta) => {
            if !meta.is_dir()
                || meta.file_type().is_symlink()
                || meta.uid() != unsafe { libc::geteuid() }
                || meta.mode() & 0o077 != 0
            {
                bail!("socket directory must be owned by this user, private (0700), and not a symlink: {}",dir.display());
            }
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            use std::os::unix::fs::DirBuilderExt;
            fs::DirBuilder::new().mode(0o700).create(dir)?;
        }
        Err(e) => return Err(e.into()),
    }
    Ok(dir.to_path_buf())
}

struct Registry {
    sessions: HashMap<String, Arc<Session>>,
    requests: HashMap<String, (String, String)>,
}
struct Host {
    id: String,
    registry: Mutex<Registry>,
    launches: Mutex<()>,
    stopping: AtomicBool,
    next_lease: AtomicU64,
    connections: std::sync::atomic::AtomicUsize,
}
struct SocketGuard(PathBuf);
impl Drop for SocketGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

fn serve(path: &Path) -> Result<()> {
    let dir = private_parent(path)?;
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(dir.join("host.lock"))?;
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        bail!("another host owns this state directory");
    }
    if let Ok(meta) = fs::symlink_metadata(path) {
        if !meta.file_type().is_socket() || meta.uid() != unsafe { libc::geteuid() } {
            bail!("refusing to replace a non-owned socket path");
        }
        fs::remove_file(path)?;
    }
    let host_id_path = dir.join("host-id");
    let id = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&host_id_path)
    {
        Ok(file) => {
            use io::Read;
            let mut id = String::new();
            file.take(128).read_to_string(&mut id)?;
            Uuid::parse_str(id.trim())
                .context("invalid host identity")?
                .to_string()
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            use io::Write;
            let id = Uuid::new_v4().to_string();
            let mut file = OpenOptions::new()
                .create_new(true)
                .write(true)
                .mode(0o600)
                .open(&host_id_path)?;
            file.write_all(id.as_bytes())?;
            file.sync_all()?;
            id
        }
        Err(e) => return Err(e.into()),
    };
    let listener = UnixListener::bind(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    let _socket = SocketGuard(path.to_path_buf());
    let host = Arc::new(Host {
        id,
        registry: Mutex::new(Registry {
            sessions: HashMap::new(),
            requests: HashMap::new(),
        }),
        launches: Mutex::new(()),
        stopping: AtomicBool::new(false),
        next_lease: AtomicU64::new(1),
        connections: std::sync::atomic::AtomicUsize::new(0),
    });
    listener.set_nonblocking(true)?;
    while !host.stopping.load(Ordering::SeqCst) {
        match listener.accept() {
            Ok((stream, _)) => {
                if !same_user(&stream) || host.connections.load(Ordering::Relaxed) >= 128 {
                    drop(stream);
                    continue;
                }
                host.connections.fetch_add(1, Ordering::Relaxed);
                let host = host.clone();
                thread::spawn(move || {
                    let _ = connection(stream, &host);
                    host.connections.fetch_sub(1, Ordering::Relaxed);
                });
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(10))
            }
            Err(e) => return Err(e.into()),
        }
    }
    // Let the shutdown reply reach its client before closing the process.
    thread::sleep(Duration::from_millis(50));
    drop(lock);
    Ok(())
}

#[cfg(target_os = "linux")]
fn same_user(stream: &UnixStream) -> bool {
    unsafe {
        let mut credentials: libc::ucred = std::mem::zeroed();
        let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut len,
        ) == 0
            && credentials.uid == libc::geteuid()
    }
}
#[cfg(target_os = "macos")]
fn same_user(stream: &UnixStream) -> bool {
    unsafe {
        let mut uid = 0;
        let mut gid = 0;
        libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) == 0 && uid == libc::geteuid()
    }
}

fn connection(mut stream: UnixStream, host: &Arc<Host>) -> Result<()> {
    // Darwin inherits O_NONBLOCK from the listener; framed reads use timeouts.
    stream.set_nonblocking(false)?;
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    match read_frame(&mut stream)? {
        Some(ClientMessage::Hello { version }) if version == PROTOCOL_VERSION => {}
        _ => {
            write_frame(
                &mut stream,
                &ServerMessage::error(
                    "version_mismatch",
                    format!("expected Cherry host protocol version {PROTOCOL_VERSION}"),
                ),
            )?;
            return Ok(());
        }
    }
    write_frame(
        &mut stream,
        &ServerMessage::Welcome {
            version: PROTOCOL_VERSION,
            host_id: host.id.clone(),
            capabilities: vec![
                "snapshot_attach".into(),
                "multi_attach".into(),
                "attach_takeover".into(),
                "create_idempotency".into(),
            ],
        },
    )?;
    let (tx, rx) = mpsc::sync_channel::<ServerMessage>(64);
    let mut writer = stream.try_clone()?;
    let writer_thread = thread::spawn(move || {
        while let Ok(message) = rx.recv() {
            let taken_over =
                matches!(&message, ServerMessage::Error { code, .. } if code == "taken_over");
            if write_frame(&mut writer, &message).is_err() {
                break;
            }
            if taken_over {
                break;
            }
        }
        let _ = writer.shutdown(std::net::Shutdown::Both);
    });
    let lease = host.next_lease.fetch_add(1, Ordering::Relaxed);
    let cancelled = Arc::new(AtomicBool::new(false));
    let mut attached: Option<Arc<Session>> = None;
    while let Ok(Some(message)) = read_frame::<_, ClientMessage>(&mut stream) {
        if cancelled.load(Ordering::SeqCst) {
            break;
        }
        let close_after_reply = matches!(message, ClientMessage::Detach);
        let result: Result<Option<ServerMessage>> = (|| match message {
            ClientMessage::List => {
                let registry = host.registry.lock().unwrap();
                let mut sessions: Vec<_> = registry
                    .sessions
                    .values()
                    .map(|s| s.snapshot_info())
                    .collect();
                sessions.sort_by(|a, b| a.id.cmp(&b.id));
                Ok(Some(ServerMessage::Sessions {
                    host_id: host.id.clone(),
                    sessions,
                }))
            }
            ClientMessage::Create {
                request_id,
                name,
                cwd,
                command,
                env,
                cols,
                rows,
            } => {
                let _launch = host.launches.lock().unwrap();
                if host.stopping.load(Ordering::SeqCst) {
                    bail!("host is shutting down");
                }
                Uuid::parse_str(&request_id).context("request_id must be a UUID")?;
                let fingerprint =
                    serde_json::to_string(&(&name, &cwd, &command, &env, cols, rows))?;
                let registry = host.registry.lock().unwrap();
                if let Some((previous, id)) = registry.requests.get(&request_id) {
                    if previous != &fingerprint {
                        bail!("request_id already used with a different launch");
                    }
                    let original=registry.sessions.get(id).context("the session from this request was removed; use a new request_id for a new session")?;
                    return Ok(Some(ServerMessage::Created {
                        session: original.snapshot_info(),
                    }));
                }
                if registry.sessions.len() >= 128 {
                    bail!("host session limit reached (128 including retained exited sessions)");
                }
                if registry.requests.len() >= 4096 {
                    bail!("host launch history limit reached; restart the host after all sessions finish");
                }
                if env.len() > 128
                    || env.iter().map(|(k, v)| k.len() + v.len()).sum::<usize>() > 65536
                {
                    bail!("environment exceeds limit");
                }
                drop(registry);
                let session = Session::spawn(name, cwd, command, env, cols, rows)?;
                let mut registry = host.registry.lock().unwrap();
                let info = session.snapshot_info();
                registry
                    .requests
                    .insert(request_id, (fingerprint, info.id.clone()));
                registry.sessions.insert(info.id.clone(), session);
                Ok(Some(ServerMessage::Created { session: info }))
            }
            ClientMessage::Attach {
                id,
                cols,
                rows,
                takeover,
            } => {
                if attached.is_some() {
                    bail!("connection already attached");
                }
                if !cherry_protocol::valid_size(cols, rows) {
                    bail!("invalid terminal size");
                }
                let session = host
                    .registry
                    .lock()
                    .unwrap()
                    .sessions
                    .get(&id)
                    .cloned()
                    .context("unknown session")?;
                session.send(SessionCommand::Attach {
                    lease,
                    cols,
                    rows,
                    takeover,
                    output: tx.clone(),
                    abort: stream.try_clone()?,
                    cancelled: cancelled.clone(),
                })?;
                attached = Some(session);
                stream.set_read_timeout(None)?;
                Ok(None)
            }
            ClientMessage::Input { data } => {
                if data.len() > cherry_protocol::MAX_INPUT_BYTES {
                    bail!("input frame exceeds limit");
                }
                attached
                    .as_ref()
                    .context("attach before sending input")?
                    .send(SessionCommand::Input { lease, data })?;
                Ok(None)
            }
            ClientMessage::Resize { cols, rows } => {
                attached
                    .as_ref()
                    .context("attach before resize")?
                    .send(SessionCommand::Resize { lease, cols, rows })?;
                Ok(None)
            }
            ClientMessage::Detach => {
                cancelled.store(true, Ordering::SeqCst);
                if let Some(session) = attached.take() {
                    session.wake();
                }
                Ok(Some(ServerMessage::Ok))
            }
            ClientMessage::Kill { id } => {
                let session = host
                    .registry
                    .lock()
                    .unwrap()
                    .sessions
                    .get(&id)
                    .cloned()
                    .context("unknown session")?;
                session.kill();
                Ok(Some(ServerMessage::Ok))
            }
            ClientMessage::Remove { id } => {
                let mut registry = host.registry.lock().unwrap();
                let session = registry.sessions.get(&id).context("unknown session")?;
                if session.snapshot_info().state == SessionState::Running {
                    bail!("terminate the running session before removing it");
                }
                registry.sessions.remove(&id);
                Ok(Some(ServerMessage::Ok))
            }
            ClientMessage::Shutdown => {
                let _launch = host.launches.lock().unwrap();
                if host
                    .registry
                    .lock()
                    .unwrap()
                    .sessions
                    .values()
                    .any(|s| s.snapshot_info().state == SessionState::Running)
                {
                    bail!("host still owns running sessions");
                }
                host.stopping.store(true, Ordering::SeqCst);
                Ok(Some(ServerMessage::Ok))
            }
            ClientMessage::Hello { .. } => bail!("connection already negotiated"),
        })();
        let reply = match result {
            Ok(reply) => reply,
            Err(e) => Some(ServerMessage::error("request_failed", format!("{e:#}"))),
        };
        if let Some(reply) = reply {
            if tx.send(reply).is_err() {
                break;
            }
        }
        if close_after_reply {
            break;
        }
    }
    cancelled.store(true, Ordering::SeqCst);
    if let Some(session) = attached {
        session.wake();
    }
    drop(tx);
    // Drop read side before joining; a slow/malicious peer cannot keep this
    // handler alive beyond the writer's bounded socket timeout.
    drop(stream);
    let _ = writer_thread.join();
    Ok(())
}
