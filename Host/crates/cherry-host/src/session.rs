//! A session as the daemon serves it. The session itself (its PTY, program,
//! terminal state and output offset) lives in a holder process (see
//! `holder`); here, one worker thread per session owns the holder link and
//! every attachment: their outboxes, lag and resync, the shared grid and its
//! replacements, the choice of who answers queries, and input backpressure.
//! What the worker needs from the terminal (snapshots) it asks the holder
//! for, and replies come in order with the output, each at exactly the
//! offset its bytes show.
use crate::{
    daemon::{self, Host},
    environment,
    holder::LINK_FD,
    link::{self, kind, Frame},
    outbox::{Outbox, Output, Push},
    paths, screen,
    signals::{self, Wake},
};
use anyhow::{bail, Context, Result};
use cherry_protocol::{
    encode_frame, error_code, valid_size, AttachReason, ForegroundProcess, ProgressState,
    ServerMessage, SessionEvent, SessionInfo, SessionState, MAX_SCREEN_TEXT_BYTES,
    MAX_SNAPSHOT_BYTES,
};
use std::{
    collections::{BTreeMap, VecDeque},
    os::unix::{ffi::OsStrExt, fs::MetadataExt, io::AsRawFd, net::UnixStream, process::CommandExt},
    path::{Path, PathBuf},
    process::Stdio,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{self, Receiver, SyncSender, TryRecvError},
        Arc, Condvar, Mutex, OnceLock,
    },
    thread,
    time::{Duration, Instant},
};
use uuid::Uuid;

/// A connection with input to deliver waits (and stops reading frames) while
/// more than this many bytes of its session's input wait for the PTY, and
/// resumes below the low mark.
pub const INPUT_HIGH_WATER: usize = 1024 * 1024;
pub const INPUT_LOW_WATER: usize = 256 * 1024;
/// Grid changes requested by clients apply once the size has settled.
const GRID_SETTLE: Duration = Duration::from_millis(75);
/// Workers are woken by events; this only bounds a missed wakeup.
const IDLE_WAIT: Duration = Duration::from_secs(60);
const RESYNC_RETRY: Duration = Duration::from_secs(1);
/// How long a new holder may take to start its session.
const LAUNCH_TIMEOUT: Duration = Duration::from_secs(10);
/// Bytes taken from the holder link per pass, so commands keep a turn.
const LINK_READ: usize = 4 * 1024 * 1024;
/// How long a removed session's holder gets to take its last frame.
const REMOVE_FLUSH: Duration = Duration::from_secs(1);
/// Callers sharing one screen request, at most: beyond them the holder is
/// not answering, and more are turned away rather than kept waiting.
const SCREEN_WAITERS: usize = 64;
/// Screen requests (each of its own kind: with or without the history, and
/// its `max_lines`) a holder has at most: beyond them it is not answering,
/// and callers of another kind are turned away rather than asking it more.
const SCREEN_REQUESTS: usize = 8;

/// A validated request for a new session.
pub struct Launch {
    pub name: String,
    pub cwd: PathBuf,
    /// The session's `PWD`: `cwd` as the client named it, when it could
    /// (see `environment::logical_cwd`).
    pub pwd: PathBuf,
    pub command: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub cols: u16,
    pub rows: u16,
    /// Who created the session, and the metadata they keep with it.
    pub owner: Option<String>,
    pub tags: BTreeMap<String, String>,
    /// `SSH_AUTH_SOCK` for the session: the link clients keep pointed at
    /// their current agent.
    pub agent_link: PathBuf,
    /// The `Create` it answers, kept by the holder so that a daemon adopting
    /// the session keeps retries idempotent.
    pub receipt: link::Receipt,
}

pub struct Session {
    pub info: Arc<Mutex<SessionInfo>>,
    tx: SyncSender<Command>,
    wake: Arc<Wake>,
    kill_requested: Arc<AtomicBool>,
    pub input: Arc<InputGate>,
    /// Whether a holder is connected.
    linked: Arc<AtomicBool>,
    /// Lets the worker begin (see `start`).
    start: Mutex<Option<SyncSender<()>>>,
}

pub enum Command {
    Attach {
        lease: u64,
        cols: u16,
        rows: u16,
        takeover: bool,
        /// The client's terminal answers queries (see `Worker::send_query`).
        answers_queries: bool,
        outbox: Arc<Outbox>,
        abort: UnixStream,
        cancelled: Arc<AtomicBool>,
        /// Whether the attachment was established.
        ack: SyncSender<bool>,
    },
    Input {
        lease: u64,
        data: Vec<u8>,
    },
    /// Input without an attachment (`SendInput`): delivered whatever
    /// becomes of the connection that sent it.
    Send {
        data: Vec<u8>,
    },
    /// Read the screen as text; the reply is a `ScreenText` or an `Error`.
    Screen {
        scrollback: bool,
        max_lines: Option<u32>,
        reply: SyncSender<ServerMessage>,
    },
    /// Rename or retag the session; acknowledged once applied (true), or
    /// once found removed (false).
    Update {
        name: Option<String>,
        tags: Option<BTreeMap<String, String>>,
        ack: SyncSender<bool>,
    },
    Resize {
        lease: u64,
        cols: u16,
        rows: u16,
    },
    /// A voluntary detach. It follows the lease's earlier input through the
    /// command queue and the holder link, and that input is still
    /// delivered.
    Detach {
        lease: u64,
        ack: SyncSender<()>,
    },
    /// Forget the exited session: its holder exits, and so does the
    /// worker, before the acknowledgement.
    Remove {
        ack: SyncSender<()>,
    },
}

/// Input accepted from connections but not yet written to the PTY (the
/// holder acknowledges what it wrote), shared so connections can stop
/// reading while the child is not consuming it.
#[derive(Default)]
pub struct InputGate {
    pending: Mutex<usize>,
    drained: Condvar,
    /// Bytes released so far: shows whether the program is making progress.
    released: AtomicU64,
}

impl InputGate {
    fn lock(&self) -> std::sync::MutexGuard<'_, usize> {
        self.pending.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn reserve(&self, bytes: usize) {
        *self.lock() += bytes;
    }

    pub fn released(&self) -> u64 {
        self.released.load(Ordering::SeqCst)
    }

    pub fn release(&self, bytes: usize) {
        if bytes == 0 {
            return;
        }
        self.released.fetch_add(bytes as u64, Ordering::SeqCst);
        let mut pending = self.lock();
        *pending = pending.saturating_sub(bytes);
        if *pending < INPUT_LOW_WATER {
            self.drained.notify_all();
        }
    }

    pub fn full(&self) -> bool {
        *self.lock() > INPUT_HIGH_WATER
    }

    /// Wait up to `timeout` for pending input to drop below the low mark.
    pub fn wait_for_room(&self, timeout: Duration) -> bool {
        let pending = self.lock();
        let (pending, _) = self
            .drained
            .wait_timeout_while(pending, timeout, |pending| *pending >= INPUT_LOW_WATER)
            .unwrap_or_else(|e| e.into_inner());
        *pending < INPUT_LOW_WATER
    }
}

struct Attachment {
    lease: u64,
    /// The client's window.
    cols: u16,
    rows: u16,
    /// Whether the window shows the session's stream directly, so its own
    /// scrollback holds the history: it had the grid's size when it last got
    /// a replacement, and has had since, or the grid is following it there.
    /// Otherwise it renders a viewport from a copy of the screens.
    direct: bool,
    outbox: Arc<Outbox>,
    abort: UnixStream,
    cancelled: Arc<AtomicBool>,
    /// After a failed resync snapshot, when to try again.
    resync_after: Option<Instant>,
    /// Its terminal answers queries (see `Worker::send_query`).
    answers_queries: bool,
}

impl Attachment {
    /// Whether a replacement for a grid of `size` must be a full snapshot:
    /// the window rendered a viewport and now matches the grid, or it
    /// supersedes a full one (see `Worker::send_resized`).
    fn needs_full(&self, size: (u16, u16)) -> bool {
        ((self.cols, self.rows) == size && !self.direct) || self.outbox.full_replacement_queued()
    }
}

fn now_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_millis() as u64)
}

/// The file this daemon was started from, when it started: its device and
/// inode.
static EXECUTABLE: OnceLock<Option<(u64, u64)>> = OnceLock::new();

/// Note which file this daemon runs from, so that a replacement (an update
/// installed over it) can be told apart later.
pub fn note_executable() {
    let _ = EXECUTABLE.set(
        installed_executable()
            .ok()
            .and_then(|path| std::fs::metadata(path).ok())
            .map(|meta| (meta.dev(), meta.ino())),
    );
}

/// Where this daemon's executable is now. macOS follows it when it (or the
/// app bundle holding it) moves; elsewhere it is the path it was started
/// from.
fn installed_executable() -> Result<PathBuf> {
    #[cfg(target_os = "macos")]
    if let Some(path) = crate::processes::own_executable() {
        return Ok(path);
    }
    let path = std::env::current_exe().context("locating cherry-host")?;
    if std::fs::metadata(&path).is_err() {
        bail!(
            "this host's executable {} was removed; restart the host to start new sessions (running ones carry on)",
            path.display()
        );
    }
    Ok(path)
}

/// The program a new holder runs. On Linux it is this daemon's own image
/// (`/proc/self/exe`), even after the installed file was replaced or
/// removed, as package upgrades do. Elsewhere it is the executable at
/// `installed_executable`, which, if another build was installed over this
/// one, is that build: the link allows it (see `link`, `Launch`).
fn holder_command() -> Result<std::process::Command> {
    #[cfg(target_os = "linux")]
    {
        let image = Path::new("/proc/self/exe");
        if std::fs::symlink_metadata(image).is_ok() {
            let mut command = std::process::Command::new(image);
            // What ps shows: the installed path rather than the alias.
            if let Ok(path) = std::env::current_exe() {
                let path = path.as_os_str().as_bytes();
                let path = path.strip_suffix(b" (deleted)").unwrap_or(path);
                command.arg0(std::ffi::OsStr::from_bytes(path));
            }
            return Ok(command);
        }
    }
    let path = installed_executable()?;
    let identity = std::fs::metadata(&path)
        .ok()
        .map(|meta| (meta.dev(), meta.ino()));
    if let Some(Some(started)) = EXECUTABLE.get() {
        static REPORTED: AtomicBool = AtomicBool::new(false);
        if identity != Some(*started) && !REPORTED.swap(true, Ordering::SeqCst) {
            daemon::log(format_args!(
                "{} now holds another build than this host's; new sessions run that build",
                path.display()
            ));
        }
    }
    Ok(std::process::Command::new(path))
}

/// Start a holder for a new session and hand it the launch: returns the
/// link, and the holder's first frame (`HolderHello`).
fn start_holder(
    socket: &Path,
    launch: &link::Launch,
    cwd: &Path,
    env: &[(Vec<u8>, Vec<u8>)],
) -> Result<(UnixStream, Frame)> {
    let (ours, theirs) = UnixStream::pair().context("creating the session's link")?;
    let mut command = holder_command()?;
    command
        .arg("hold")
        .arg("--socket")
        .arg(socket)
        // Like the daemon: neutral variables only, and no directory pinned.
        .env_clear()
        .envs(environment::inherited_vars())
        .current_dir("/")
        .stdin(Stdio::null())
        .stdout(Stdio::null());
    let fd = theirs.as_raw_fd();
    let limit = daemon::child_fd_limit();
    unsafe {
        command.pre_exec(move || {
            // Never the daemon's child, so that it outlives the daemon and a
            // daemon crash cannot take it along: a session of its own, and a
            // grandchild that init adopts.
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            match libc::fork() {
                -1 => return Err(std::io::Error::last_os_error()),
                0 => {}
                _ => libc::_exit(0),
            }
            // Only the link is inherited, as descriptor 3. Without accept4,
            // macOS sets close-on-exec on an accepted connection only after
            // accept returns, so another thread's client could otherwise
            // leak in.
            environment::cloexec_from_3();
            if fd == LINK_FD {
                libc::fcntl(fd, libc::F_SETFD, 0);
            } else if libc::dup2(fd, LINK_FD) == -1 {
                return Err(std::io::Error::last_os_error());
            }
            // The daemon raises its own descriptor limit; holders, and the
            // sessions they start, get the limit the user had.
            if let Some(limit) = limit {
                libc::setrlimit(libc::RLIMIT_NOFILE, &limit);
            }
            Ok(())
        });
    }
    let mut intermediate = command.spawn().context("starting the session's holder")?;
    drop(theirs);
    let _ = intermediate.wait();
    let mut stream = ours;
    stream.set_read_timeout(Some(LAUNCH_TIMEOUT))?;
    stream.set_write_timeout(Some(LAUNCH_TIMEOUT))?;
    link::write_blocking(
        &mut stream,
        &link::encode(
            kind::LAUNCH,
            launch,
            &link::launch_data(cwd.as_os_str().as_bytes(), env),
        ),
    )
    .context("handing the session to its holder")?;
    match link::read_blocking(&mut stream).context("waiting for the session's holder")? {
        Some(frame) if frame.kind == kind::HOLDER_HELLO => Ok((stream, frame)),
        Some(frame) if frame.kind == kind::FAILED => {
            bail!("{}", frame.meta::<link::Failed>()?.message)
        }
        Some(frame) => bail!("the session's holder sent a frame of kind {}", frame.kind),
        None => bail!("the session's holder exited before starting the session"),
    }
}

fn foreground(foreground: link::Foreground) -> ForegroundProcess {
    ForegroundProcess {
        pid: foreground.pid,
        name: foreground.name,
    }
}

fn progress_state(state: &str) -> Option<ProgressState> {
    Some(match state {
        "remove" => ProgressState::Remove,
        "set" => ProgressState::Set,
        "error" => ProgressState::Error,
        "indeterminate" => ProgressState::Indeterminate,
        "pause" => ProgressState::Pause,
        _ => return None,
    })
}

/// A client event for a holder's `Event`.
fn session_event(id: &str, event: link::Event) -> Option<SessionEvent> {
    let id = id.to_string();
    Some(match event {
        link::Event::Bell => SessionEvent::Bell { id },
        link::Event::Notification { title, body } => SessionEvent::Notification { id, title, body },
        link::Event::Progress { state, value } => SessionEvent::Progress {
            id,
            state: progress_state(&state)?,
            value: value.map(|value| value.min(100)),
        },
        link::Event::Exited { exit_code, signal } => SessionEvent::Exited {
            id,
            exit_code,
            signal,
        },
    })
}

impl Session {
    /// Start a new session in a holder of its own.
    pub fn spawn(launch: Launch, host: &Arc<Host>) -> Result<Arc<Self>> {
        let Launch {
            name,
            cwd,
            pwd,
            mut command,
            env,
            cols,
            rows,
            owner,
            tags,
            agent_link,
            receipt,
        } = launch;
        if !valid_size(cols, rows) {
            bail!("terminal size must be 2–500 columns and 1–200 rows");
        }
        if name.len() > 256
            || command.len() > 256
            || command.iter().map(String::len).sum::<usize>() > 65536
            || command.iter().any(|arg| arg.contains('\0'))
        {
            bail!("launch description exceeds limit");
        }
        if command.is_empty() {
            let shell = std::env::var_os("SHELL")
                .filter(|shell| !shell.is_empty())
                .or_else(crate::paths::passwd_shell)
                .unwrap_or_else(|| "/bin/sh".into());
            command = vec![shell.to_string_lossy().into_owned(), "-l".into()];
        }
        let id = Uuid::new_v4().to_string();
        let env: Vec<(Vec<u8>, Vec<u8>)> = environment::session_env(&id, &agent_link, &env, &pwd)
            .into_iter()
            .map(|(key, value)| (key.into_encoded_bytes(), value.into_encoded_bytes()))
            .collect();
        let launch = link::Launch {
            id,
            name,
            command,
            cols,
            rows,
            owner,
            tags,
            created_at: now_millis(),
            state_dir: host.state.to_string_lossy().into_owned(),
            kill_grace_ms: daemon::config().kill_grace.as_millis() as u64,
            receipt: Some(receipt),
        };
        let (stream, hello) = start_holder(&host.socket, &launch, &cwd, &env)?;
        let version = hello.version;
        // A new holder has kept nothing to report.
        let (session, _) = Self::adopt(host, stream, hello.meta()?, version)?;
        Ok(session)
    }

    /// Serve the session a holder registered (`HolderHello`) on `stream`.
    /// Returns it, and what its holder kept while no daemon was connected,
    /// to publish once the session is known. Its worker waits for `start`,
    /// so that subscribers hear of the session before anything about it.
    pub fn adopt(
        host: &Arc<Host>,
        stream: UnixStream,
        hello: link::HolderHello,
        version: u16,
    ) -> Result<(Arc<Self>, Vec<SessionEvent>)> {
        stream.set_read_timeout(None)?;
        stream.set_write_timeout(None)?;
        stream.set_nonblocking(true)?;
        let link::HolderHello {
            id,
            session,
            offset,
            events,
            receipt,
            ..
        } = hello;
        let exit =
            (!session.running).then(|| (session.exit_code.unwrap_or(1), session.exit_signal));
        let info = Arc::new(Mutex::new(SessionInfo {
            id: id.clone(),
            name: session.name,
            cwd: session.cwd,
            command: session.command,
            cols: session.cols,
            rows: session.rows,
            state: if session.running {
                SessionState::Running
            } else {
                SessionState::Exited
            },
            pid: session.pid,
            exit_code: session.exit_code.filter(|_| !session.running),
            attached: false,
            exit_signal: session.exit_signal.filter(|_| !session.running),
            title: session.title,
            pwd: session.pwd,
            foreground: session.foreground.map(foreground),
            clients: 0,
            owner: session.owner,
            tags: session.tags,
            created_at: session.created_at,
            alternate_screen: session.alternate_screen,
            kitty_keyboard_flags: session.kitty_keyboard_flags,
            // Off from a holder older than link version 4, which never
            // reports it.
            application_cursor_keys: session.application_cursor_keys,
            // The holder keeps the Create's receipt for the next daemon.
            request_id: receipt.map(|receipt| receipt.request_id),
        }));
        let (wake, wake_rx) = Wake::pair()?;
        let (tx, rx) = mpsc::sync_channel(64);
        let kill_requested = Arc::new(AtomicBool::new(false));
        let input = Arc::new(InputGate::default());
        let linked = Arc::new(AtomicBool::new(true));
        let (start, started) = mpsc::sync_channel(1);
        let session = Arc::new(Self {
            info: info.clone(),
            tx,
            wake: wake.clone(),
            kill_requested: kill_requested.clone(),
            input: input.clone(),
            linked: linked.clone(),
            start: Mutex::new(Some(start)),
        });
        let worker = Worker {
            id: id.clone(),
            host: host.clone(),
            info,
            rx,
            wake,
            wake_rx,
            kill_requested,
            linked,
            link: Some(HolderLink {
                stream,
                reader: link::Reader::default(),
                writer: link::Writer::default(),
                version,
            }),
            attached: Vec::new(),
            input,
            unacknowledged: 0,
            offset,
            grid_due: None,
            typist: None,
            next_req: 1,
            requests: BTreeMap::new(),
            waiting: VecDeque::new(),
            resyncing: false,
            exit,
            removed: false,
            removed_ack: None,
        };
        let exited = exit.is_some();
        let events = events
            .into_iter()
            .filter_map(|event| serde_json::from_value(event).ok())
            .filter_map(|event| session_event(&id, event))
            // An exit the hello does not report is not believed.
            .filter(|event| exited || !matches!(event, SessionEvent::Exited { .. }))
            .collect();
        thread::Builder::new()
            .name("cherry-session".into())
            .spawn(move || {
                // Until started, or until the session is dropped unstarted.
                let _ = started.recv();
                worker.run()
            })
            .context("starting session worker")?;
        Ok((session, events))
    }

    /// Let the worker serve the session, once it is registered and
    /// announced.
    pub fn start(&self) {
        let start = self.start.lock().unwrap_or_else(|e| e.into_inner()).take();
        if let Some(start) = start {
            let _ = start.send(());
        }
    }

    /// Queue a command for the worker, waiting while its queue is full.
    pub fn send(&self, command: Command) -> Result<()> {
        self.tx
            .send(command)
            .map_err(|_| anyhow::anyhow!("session is unavailable"))?;
        self.wake();
        Ok(())
    }

    pub fn wake(&self) {
        self.wake.wake();
    }

    pub fn kill(&self) {
        self.kill_requested.store(true, Ordering::SeqCst);
        self.wake();
    }

    /// Whether its holder is connected.
    pub fn is_linked(&self) -> bool {
        self.linked.load(Ordering::SeqCst)
    }

    pub fn is_running(&self) -> bool {
        self.snapshot_info().state == SessionState::Running
    }

    /// Forget the exited session: its holder removes its manifest and
    /// exits. Returns once the link is closed.
    pub fn remove(&self) {
        let (ack, acknowledged) = mpsc::sync_channel(1);
        if self.send(Command::Remove { ack }).is_ok() {
            let _ = acknowledged.recv();
        }
    }

    pub fn snapshot_info(&self) -> SessionInfo {
        self.info.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        // The worker ends once every handle is gone.
        self.wake();
    }
}

fn frame(message: &ServerMessage) -> Option<Arc<Vec<u8>>> {
    encode_frame(message).ok().map(Arc::new)
}

fn attached_frame(
    session: SessionInfo,
    offset: u64,
    snapshot: Vec<u8>,
    reason: AttachReason,
) -> Result<Arc<Vec<u8>>> {
    Ok(Replacement::new(session, offset, snapshot, reason)?.frame)
}

fn output_frame(offset: u64, data: Vec<u8>) -> Result<Output> {
    let message = ServerMessage::Output { offset, data };
    let frame = Arc::new(encode_frame(&message)?);
    let ServerMessage::Output { data, .. } = message else {
        unreachable!()
    };
    Ok(Output {
        frame,
        data: Arc::new(data),
    })
}

/// A resync `Attached` frame, with what it was made from.
struct Replacement {
    session: SessionInfo,
    offset: u64,
    snapshot: Vec<u8>,
    reason: AttachReason,
    frame: Arc<Vec<u8>>,
}

impl Replacement {
    fn new(
        session: SessionInfo,
        offset: u64,
        snapshot: Vec<u8>,
        reason: AttachReason,
    ) -> Result<Self> {
        let message = ServerMessage::Attached {
            session,
            offset,
            snapshot,
            reason,
        };
        let frame = Arc::new(encode_frame(&message)?);
        let ServerMessage::Attached {
            session, snapshot, ..
        } = message
        else {
            unreachable!()
        };
        Ok(Self {
            session,
            offset,
            snapshot,
            reason,
            frame,
        })
    }

    /// Resynchronize a client with this snapshot, which supersedes its queued
    /// output. The live-only tokens of the output it missed (see `outbox`)
    /// follow it as output; the snapshot's offset moves back by their
    /// length, so the stream stays contiguous and live output resumes at
    /// `offset`.
    fn push_to(&self, outbox: &Outbox) {
        let carried = outbox.take_superseded();
        if !carried.is_empty() {
            if let Ok((frame, carried)) = self.with_carried(carried) {
                outbox.push_snapshot(frame, Some(carried));
                return;
            }
        }
        outbox.push_snapshot(self.frame.clone(), None);
    }

    fn with_carried(&self, carried: Vec<u8>) -> Result<(Arc<Vec<u8>>, Output)> {
        let start = self
            .offset
            .checked_sub(carried.len() as u64)
            .context("carried output exceeds the stream")?;
        let attached = Self::new(
            self.session.clone(),
            start,
            self.snapshot.clone(),
            self.reason,
        )?;
        Ok((attached.frame, output_frame(start, carried)?))
    }
}

/// A snapshot from the holder: the renderer stream that shows the output
/// up to `offset`, for a grid of `size`.
struct Snapshot {
    bytes: Vec<u8>,
    offset: u64,
    size: (u16, u16),
}

/// An attach waiting for its snapshot.
struct PendingAttach {
    lease: u64,
    cols: u16,
    rows: u16,
    takeover: bool,
    answers_queries: bool,
    outbox: Arc<Outbox>,
    abort: UnixStream,
    cancelled: Arc<AtomicBool>,
    ack: SyncSender<bool>,
    /// Whether its size changed the grid.
    resized: bool,
    /// Other attachments whose replacement for the new grid is full: they
    /// get the same snapshot.
    full_others: Vec<u64>,
}

/// What a request to the holder is for.
enum Request {
    Attach(PendingAttach),
    /// Replacements for a new grid size (`full` or the screens only), for
    /// these attachments.
    Replace {
        full: bool,
        leases: Vec<u64>,
    },
    /// Resync snapshots for lagging attachments.
    Resync {
        leases: Vec<u64>,
    },
    /// The final screen for attachments lagging when the session exited;
    /// the exit follows it.
    Final {
        leases: Vec<u64>,
    },
    Detach {
        ack: SyncSender<()>,
    },
    /// The screen with or without its history, limited to `max_lines` or
    /// not, for every caller that asked the same while it was pending.
    /// `whole`: the holder is too old to limit the text itself.
    Screen {
        scrollback: bool,
        max_lines: Option<u32>,
        whole: bool,
        replies: Vec<SyncSender<ServerMessage>>,
    },
}

struct HolderLink {
    stream: UnixStream,
    reader: link::Reader,
    writer: link::Writer,
    /// The link version the holder registered with.
    version: u16,
}

struct Worker {
    id: String,
    host: Arc<Host>,
    info: Arc<Mutex<SessionInfo>>,
    rx: Receiver<Command>,
    wake: Arc<Wake>,
    wake_rx: UnixStream,
    kill_requested: Arc<AtomicBool>,
    linked: Arc<AtomicBool>,
    link: Option<HolderLink>,
    attached: Vec<Attachment>,
    input: Arc<InputGate>,
    /// Input bytes sent to the holder and not yet acknowledged.
    unacknowledged: usize,
    /// The output offset: where the holder's next output starts.
    offset: u64,
    /// When to apply a settled grid change, and its target.
    grid_due: Option<(Instant, (u16, u16))>,
    /// Of the attachments whose terminal answers queries, the one that most
    /// recently sent input: it answers them (see `send_query`).
    typist: Option<u64>,
    next_req: u64,
    requests: BTreeMap<u64, Request>,
    /// Attaches waiting for the one in progress: one at a time, so each
    /// sees the grid the previous one left.
    waiting: VecDeque<Command>,
    /// A resync snapshot has been asked for.
    resyncing: bool,
    /// How the session ended, once it has.
    exit: Option<(u32, Option<i32>)>,
    removed: bool,
    /// Acknowledges a `Remove` once the worker is gone.
    removed_ack: Option<SyncSender<()>>,
}

impl Worker {
    fn info(&self) -> std::sync::MutexGuard<'_, SessionInfo> {
        self.info.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn size(&self) -> (u16, u16) {
        let info = self.info();
        (info.cols, info.rows)
    }

    fn running(&self) -> bool {
        self.exit.is_none()
    }

    fn changed(&self) {
        let session = self.info().clone();
        self.host.publish(SessionEvent::Changed { session });
    }

    /// Queue a frame for the holder, if one is connected and its link
    /// version knows the frame's kind.
    fn tell(&mut self, frame: Vec<u8>) -> bool {
        match &mut self.link {
            Some(link) if kind::since(frame[4]) <= link.version => {
                link.writer.push(frame);
                true
            }
            _ => false,
        }
    }

    /// Ask the holder for a snapshot; returns the request's ID.
    fn request_snapshot(&mut self, kind: &str, request: Request) -> Option<u64> {
        let req = self.next_req;
        let max = (kind == "limited").then_some(MAX_SNAPSHOT_BYTES);
        let sent = self.tell(link::encode(
            kind::SNAPSHOT,
            &link::SnapshotRequest {
                req,
                kind: kind.into(),
                max,
            },
            &[],
        ));
        if !sent {
            return None;
        }
        self.next_req += 1;
        self.requests.insert(req, request);
        Some(req)
    }

    /// The shared grid: the smallest size any attachment asked for.
    fn desired_size(&self) -> Option<(u16, u16)> {
        self.attached
            .iter()
            .map(|a| (a.cols, a.rows))
            .reduce(|(cols, rows), (c, r)| (cols.min(c), rows.min(r)))
    }

    fn update_attached_flag(&self) {
        {
            let mut info = self.info();
            let clients = u32::try_from(self.attached.len()).unwrap_or(u32::MAX);
            if info.clients == clients {
                return;
            }
            info.attached = !self.attached.is_empty();
            info.clients = clients;
        }
        self.changed();
    }

    /// Apply a changed grid once it has been stable for GRID_SETTLE, so a
    /// window drag sends one snapshot rather than one per step.
    fn schedule_grid(&mut self) {
        match self.desired_size() {
            Some(target) if target != self.size() => {
                if self.grid_due.map(|(_, pending)| pending) != Some(target) {
                    self.grid_due = Some((Instant::now() + GRID_SETTLE, target));
                }
            }
            _ => self.grid_due = None,
        }
    }

    fn apply_due_grid(&mut self) {
        let Some((due, _)) = self.grid_due else {
            return;
        };
        if Instant::now() < due {
            return;
        }
        self.grid_due = None;
        if let Some((cols, rows)) = self.desired_size() {
            self.change_size(cols, rows);
        }
    }

    fn change_size(&mut self, cols: u16, rows: u16) {
        if self.size() == (cols, rows) || !self.running() {
            return;
        }
        self.resize(cols, rows);
        self.send_resized(|_| true);
    }

    /// Resize the terminal. The holder applies it before any request that
    /// follows, so the snapshots asked for next have the new size.
    fn resize(&mut self, cols: u16, rows: u16) {
        if !self.tell(link::encode(kind::RESIZE, &link::Size { cols, rows }, &[])) {
            return;
        }
        {
            let mut info = self.info();
            info.cols = cols;
            info.rows = rows;
        }
        self.changed();
    }

    /// Send the attachments `due` selects an `Attached{Resize}` for the
    /// grid's size, called when the grid or their window changed. Most get
    /// the screens without history (`Terminal::refresh`), which is small
    /// however much history the session keeps: a window of another size
    /// renders a viewport from a copy of the screens, and a window that
    /// showed the stream directly, such as one whose own resize the grid
    /// followed, keeps its own scrollback. Only a window that rendered a
    /// viewport and now matches the grid gets a full snapshot, since its
    /// scrollback lacks the history since it left the stream. Either is
    /// queued behind the client's output, and supersedes an older
    /// replacement still queued, which is why one that supersedes a full one
    /// is full. A lagging client gets the new size with its resync.
    fn send_resized(&mut self, due: impl Fn(&Attachment) -> bool) {
        let (full, refresh) = self.replacements_for(self.size(), due);
        if !full.is_empty() {
            self.request_snapshot(
                "limited",
                Request::Replace {
                    full: true,
                    leases: full,
                },
            );
        }
        if !refresh.is_empty() {
            self.request_snapshot(
                "refresh",
                Request::Replace {
                    full: false,
                    leases: refresh,
                },
            );
        }
    }

    /// The attachments `due` selects that need a full replacement for a grid
    /// of `size`, and those that need the screens only.
    fn replacements_for(
        &self,
        size: (u16, u16),
        due: impl Fn(&Attachment) -> bool,
    ) -> (Vec<u64>, Vec<u64>) {
        let mut full = Vec::new();
        let mut refresh = Vec::new();
        for attachment in &self.attached {
            if attachment.outbox.is_lagging() || !due(attachment) {
                continue;
            }
            if attachment.needs_full(size) {
                full.push(attachment.lease);
            } else {
                refresh.push(attachment.lease);
            }
        }
        (full, refresh)
    }

    /// Replacements have arrived for a grid of `size`.
    fn replace(
        &mut self,
        full: bool,
        leases: &[u64],
        reply: Result<Arc<Vec<u8>>, String>,
        size: (u16, u16),
    ) {
        for attachment in &mut self.attached {
            if !leases.contains(&attachment.lease) || attachment.outbox.is_lagging() {
                continue;
            }
            match &reply {
                Ok(frame) => {
                    attachment.outbox.push_replacement(frame.clone(), full);
                    attachment.direct = (attachment.cols, attachment.rows) == size;
                }
                Err(error) => {
                    if let Some(frame) = frame(&ServerMessage::error(
                        error_code::SNAPSHOT_FAILED,
                        error.clone(),
                    )) {
                        attachment.outbox.push_control(frame);
                    }
                    // It keeps the grid it had, which its window no longer
                    // matches.
                    attachment.direct = false;
                }
            }
        }
    }

    fn broadcast(&self, message: &ServerMessage) {
        if let Some(frame) = frame(message) {
            for attachment in &self.attached {
                attachment.outbox.push_control(frame.clone());
            }
        }
    }

    fn send_to(&self, lease: u64, message: &ServerMessage) {
        if let (Some(attachment), Some(frame)) = (
            self.attached.iter().find(|a| a.lease == lease),
            frame(message),
        ) {
            attachment.outbox.push_control(frame);
        }
    }

    /// Drop the lease's input still waiting in the holder; the holder
    /// acknowledges it.
    fn discard_lease(&mut self, lease: u64) {
        if self.running() {
            self.tell(link::encode(
                kind::DISCARD_LEASE,
                &link::Lease { lease },
                &[],
            ));
        }
    }

    /// Drop attachments whose connection ended or whose peer is gone.
    fn release_gone(&mut self) {
        let before = self.attached.len();
        let mut gone = Vec::new();
        self.attached.retain(|attachment| {
            let dead = attachment.outbox.is_dead();
            if attachment.cancelled.load(Ordering::SeqCst) || dead {
                gone.push(attachment.lease);
                if dead {
                    // Unblock the connection's reader.
                    let _ = attachment.abort.shutdown(std::net::Shutdown::Both);
                }
                false
            } else {
                true
            }
        });
        for lease in gone {
            self.discard_lease(lease);
        }
        if self.attached.len() != before {
            self.update_attached_flag();
            self.schedule_grid();
        }
    }

    /// Ask for a fresh snapshot for lagging clients whose queues have
    /// drained, one request at a time.
    fn resync_lagging(&mut self) {
        // After the exit, a lagging client gets the final screen instead.
        if self.resyncing || !self.running() {
            return;
        }
        let now = Instant::now();
        let leases: Vec<u64> = self
            .attached
            .iter()
            .filter(|attachment| {
                attachment.resync_after.is_none_or(|after| now >= after)
                    && attachment.outbox.resync_due()
            })
            .map(|attachment| attachment.lease)
            .collect();
        if !leases.is_empty()
            && self
                .request_snapshot("limited", Request::Resync { leases })
                .is_some()
        {
            self.resyncing = true;
        }
    }

    /// Send the attachments in `leases` a fresh `Attached{Resync}`. It
    /// replaces their queued output and any older snapshot.
    fn resync(&mut self, leases: &[u64], reply: Result<Replacement, String>, size: (u16, u16)) {
        let now = Instant::now();
        for attachment in &mut self.attached {
            if !leases.contains(&attachment.lease) {
                continue;
            }
            match &reply {
                Ok(replacement) => {
                    replacement.push_to(&attachment.outbox);
                    attachment.resync_after = None;
                    attachment.direct = (attachment.cols, attachment.rows) == size;
                }
                Err(error) => {
                    if let Some(frame) = self::frame(&ServerMessage::error(
                        error_code::SNAPSHOT_FAILED,
                        error.clone(),
                    )) {
                        attachment.outbox.push_control(frame);
                    }
                    attachment.resync_after = Some(now + RESYNC_RETRY);
                }
            }
        }
    }

    /// A query the host does not answer goes to one attachment, whose
    /// terminal answers it: of those whose terminal answers queries, the one
    /// that most recently sent input (its user is there), or else the most
    /// recently attached one. Every attachment gets the same output, and the
    /// host cannot tell a reply from typed input, so each terminal that
    /// received a query would send a reply of its own. A client without
    /// such a terminal (a script feeding input) never gets one: nothing
    /// would answer, or the reply would reach the wrong program. With
    /// nobody to answer it is dropped, as queries are while detached.
    fn send_query(&self, data: Vec<u8>) {
        let answers = |attachment: &&Attachment| {
            attachment.answers_queries
                && !attachment.cancelled.load(Ordering::SeqCst)
                && !attachment.outbox.is_dead()
        };
        let typist = self.typist;
        let Some(responder) = self
            .attached
            .iter()
            .filter(answers)
            .find(|attachment| Some(attachment.lease) == typist)
            .or_else(|| self.attached.iter().rev().find(answers))
        else {
            return;
        };
        if let Some(frame) = frame(&ServerMessage::Query { data }) {
            responder.outbox.push_query(frame);
        }
    }

    fn emit_output(&mut self, offset: u64, data: Vec<u8>) {
        // The holder counts the stream; the two agree unless a frame was
        // lost, and then the holder's count is the truth.
        self.offset = offset + data.len() as u64;
        if self.attached.is_empty() || data.is_empty() {
            return;
        }
        let Ok(output) = output_frame(offset, data) else {
            return;
        };
        let mut gone = false;
        for attachment in &self.attached {
            gone |= attachment.outbox.push_output(&output) == Push::Gone;
        }
        if gone {
            self.release_gone();
        }
    }

    fn handle(&mut self, command: Command) {
        match command {
            Command::Attach {
                lease,
                cols,
                rows,
                takeover,
                answers_queries,
                outbox,
                abort,
                cancelled,
                ack,
            } => self.attach(PendingAttach {
                lease,
                cols,
                rows,
                takeover,
                answers_queries,
                outbox,
                abort,
                cancelled,
                ack,
                resized: false,
                full_others: Vec::new(),
            }),
            Command::Input { lease, data } => {
                let attachment = self
                    .attached
                    .iter()
                    .find(|a| a.lease == lease && !a.cancelled.load(Ordering::SeqCst));
                let attached = attachment.is_some();
                if attachment.is_some_and(|a| a.answers_queries) {
                    self.typist = Some(lease);
                }
                let len = data.len();
                if attached
                    && self.running()
                    && self.tell(link::encode(
                        kind::INPUT,
                        &link::InputMeta { lease: Some(lease) },
                        &data,
                    ))
                {
                    self.unacknowledged += len;
                } else {
                    self.input.release(len);
                }
            }
            Command::Send { data } => {
                let len = data.len();
                if self.running()
                    && self.tell(link::encode(
                        kind::INPUT,
                        &link::InputMeta { lease: None },
                        &data,
                    ))
                {
                    self.unacknowledged += len;
                } else {
                    self.input.release(len);
                }
            }
            Command::Screen {
                scrollback,
                max_lines,
                reply,
            } => self.screen(scrollback, max_lines, reply),
            Command::Update { name, tags, ack } => {
                let applied = !self.removed;
                if applied {
                    self.update(name, tags);
                }
                let _ = ack.send(applied);
            }
            Command::Resize { lease, cols, rows } => {
                if !valid_size(cols, rows) {
                    self.send_to(
                        lease,
                        &ServerMessage::error(error_code::RESIZE_FAILED, "invalid terminal size"),
                    );
                    return;
                }
                let Some(index) = self
                    .attached
                    .iter()
                    .position(|a| a.lease == lease && !a.cancelled.load(Ordering::SeqCst))
                else {
                    return;
                };
                let attachment = &mut self.attached[index];
                let changed = (attachment.cols, attachment.rows) != (cols, rows);
                attachment.cols = cols;
                attachment.rows = rows;
                self.schedule_grid();
                let size = self.size();
                let target = self.grid_due.map_or(size, |(_, target)| target);
                if (cols, rows) != target {
                    // The client renders a viewport once it stops waiting
                    // for the grid.
                    self.attached[index].direct = false;
                } else if target == size && changed {
                    // The grid keeps its size (another client set it, or
                    // this one went back to it), and this window now
                    // matches it: repainted, it shows the session's stream.
                    self.send_resized(|a| a.lease == lease);
                }
                // Otherwise the grid follows this window, and the client
                // waits for it on what it shows.
            }
            Command::Detach { lease, ack } => {
                if let Some(index) = self.attached.iter().position(|a| a.lease == lease) {
                    self.attached.remove(index);
                    self.update_attached_flag();
                    self.schedule_grid();
                    // The holder keeps the lease's input for delivery, and
                    // says so in order with it.
                    let req = self.next_req;
                    if self.running()
                        && self.tell(link::encode(
                            kind::DETACH,
                            &link::DetachMeta { req, lease },
                            &[],
                        ))
                    {
                        self.next_req += 1;
                        self.requests.insert(req, Request::Detach { ack });
                        return;
                    }
                }
                let _ = ack.send(());
            }
            Command::Remove { ack } => {
                self.remove();
                self.removed_ack = Some(ack);
            }
        }
    }

    /// Ask the holder for the screen as text: `reply` gets it (see
    /// `screen_text`), or why it cannot. A caller that asks while the same
    /// request is pending shares its answer, so a holder that does not
    /// answer (a stopped one) is asked once, not once per caller, and at
    /// most `SCREEN_REQUESTS` requests wait for it.
    fn screen(
        &mut self,
        scrollback: bool,
        max_lines: Option<u32>,
        reply: SyncSender<ServerMessage>,
    ) {
        let refusal = match &self.link {
            _ if self.removed => Some((error_code::UNKNOWN_SESSION, "the session was removed")),
            None => Some((
                error_code::REQUEST_FAILED,
                "the session's holder is gone, and its screen with it",
            )),
            Some(link) if link.version < kind::since(kind::SCREEN) => Some((
                error_code::UNSUPPORTED_OPERATION,
                "this session's holder is too old to read its screen",
            )),
            Some(_) => None,
        };
        if let Some((code, message)) = refusal {
            let _ = reply.send(ServerMessage::error(code, message));
            return;
        }
        let not_answering = |reply: SyncSender<ServerMessage>| {
            let _ = reply.send(ServerMessage::error(
                error_code::REQUEST_FAILED,
                "the session's holder is not answering",
            ));
        };
        let mut screens = 0;
        let mut pending = None;
        for request in self.requests.values_mut() {
            if let Request::Screen {
                scrollback: of,
                max_lines: limit,
                replies,
                ..
            } = request
            {
                screens += 1;
                if (*of, *limit) == (scrollback, max_lines) {
                    pending = Some(replies);
                }
            }
        }
        if let Some(replies) = pending {
            if replies.len() < SCREEN_WAITERS {
                replies.push(reply);
            } else {
                not_answering(reply);
            }
            return;
        }
        if screens >= SCREEN_REQUESTS {
            not_answering(reply);
            return;
        }
        // An older holder would ignore the limit: it is sent the request
        // without one, and its whole text is limited here.
        let whole = self
            .link
            .as_ref()
            .is_some_and(|link| link.version < link::SCREEN_LINES_VERSION);
        let req = self.next_req;
        self.next_req += 1;
        self.tell(link::encode(
            kind::SCREEN,
            &link::ScreenRequest {
                req,
                scrollback,
                max_lines: max_lines.filter(|_| !whole),
            },
            &[],
        ));
        self.requests.insert(
            req,
            Request::Screen {
                scrollback,
                max_lines,
                whole,
                replies: vec![reply],
            },
        );
    }

    /// The answer to `Screen` (with `scrollback` and `max_lines`), from the
    /// holder's; `whole` when the holder did not limit its text.
    fn screen_text(
        &self,
        reply: link::ScreenReply,
        text: Vec<u8>,
        (scrollback, max_lines, whole): (bool, Option<u32>, bool),
    ) -> ServerMessage {
        if let Some(error) = reply.error {
            return ServerMessage::error(error_code::REQUEST_FAILED, error);
        }
        let mut text = String::from_utf8(text)
            .unwrap_or_else(|error| String::from_utf8_lossy(error.as_bytes()).into_owned());
        let cursor_row = match max_lines {
            Some(max_lines) if whole => screen::limit_whole(
                &mut text,
                reply.cursor_row,
                self.size().1,
                scrollback && !reply.alternate_screen,
                max_lines,
            ),
            // Counted from the first line: the lines dropped here (none
            // from a holder that keeps to the limit) move it up.
            Some(_) => {
                let dropped = screen::keep_last(&mut text, MAX_SCREEN_TEXT_BYTES);
                u16::try_from(usize::from(reply.cursor_row).saturating_sub(dropped)).unwrap_or(0)
            }
            None => {
                screen::keep_last(&mut text, MAX_SCREEN_TEXT_BYTES);
                reply.cursor_row
            }
        };
        ServerMessage::ScreenText {
            id: self.id.clone(),
            text,
            cursor_row,
            cursor_col: reply.cursor_col,
            alternate_screen: reply.alternate_screen,
        }
    }

    /// A new name or tags. The holder keeps them for the next daemon.
    fn update(&mut self, name: Option<String>, tags: Option<BTreeMap<String, String>>) {
        let changed = {
            let mut info = self.info();
            let before = (info.name.clone(), info.tags.clone());
            if let Some(name) = &name {
                info.name.clone_from(name);
            }
            if let Some(tags) = &tags {
                info.tags.clone_from(tags);
            }
            before != (info.name.clone(), info.tags.clone())
        };
        if changed {
            self.tell(link::encode(
                kind::UPDATE,
                &link::Update { name, tags },
                &[],
            ));
            self.changed();
        }
    }

    fn attach(&mut self, mut pending: PendingAttach) {
        if pending.cancelled.load(Ordering::SeqCst) {
            let _ = pending.ack.send(false);
            return;
        }
        if self
            .requests
            .values()
            .any(|request| matches!(request, Request::Attach(_)))
        {
            self.waiting.push_back(Command::Attach {
                lease: pending.lease,
                cols: pending.cols,
                rows: pending.rows,
                takeover: pending.takeover,
                answers_queries: pending.answers_queries,
                outbox: pending.outbox,
                abort: pending.abort,
                cancelled: pending.cancelled,
                ack: pending.ack,
            });
            return;
        }
        if self.removed {
            if let Some(frame) = frame(&ServerMessage::error(
                error_code::REQUEST_FAILED,
                "the session was removed",
            )) {
                pending.outbox.push_control(frame);
            }
            let _ = pending.ack.send(false);
            return;
        }
        if !self.running() {
            // The final screen and the exit; the grid stays as it was.
            if self.link.is_none() {
                self.attach_exited(
                    pending,
                    Ok(Snapshot {
                        bytes: Vec::new(),
                        offset: self.offset,
                        size: self.size(),
                    }),
                );
            } else {
                self.request_snapshot("limited", Request::Attach(pending));
            }
            return;
        }
        self.release_gone();
        let (cols, rows) = (pending.cols, pending.rows);
        let dimensions = match (pending.takeover, self.desired_size()) {
            (false, Some((c, r))) => (cols.min(c), rows.min(r)),
            _ => (cols, rows),
        };
        let resized = dimensions != self.size();
        pending.resized = resized;
        let mut refresh = Vec::new();
        if resized {
            self.resize(dimensions.0, dimensions.1);
            if !pending.takeover {
                // The other windows get replacements for the new size;
                // those that need a full snapshot get this one's.
                let (full, screens) = self.replacements_for(dimensions, |_| true);
                pending.full_others = full;
                refresh = screens;
            }
        }
        self.request_snapshot("limited", Request::Attach(pending));
        if !refresh.is_empty() {
            self.request_snapshot(
                "refresh",
                Request::Replace {
                    full: false,
                    leases: refresh,
                },
            );
        }
    }

    /// Answer an attach to an exited session: its final screen, then the
    /// exit.
    fn attach_exited(&mut self, pending: PendingAttach, snapshot: Result<Snapshot, String>) {
        let mut session = self.info().clone();
        let (exit_code, signal) = self.exit.unwrap_or((1, None));
        let exit = ServerMessage::Exit {
            id: session.id.clone(),
            exit_code,
            signal,
        };
        let attached = snapshot.and_then(
            |Snapshot {
                 bytes,
                 offset,
                 size: (cols, rows),
             }| {
                session.cols = cols;
                session.rows = rows;
                attached_frame(session, offset, bytes, AttachReason::Attach)
                    .map_err(|error| error.to_string())
            },
        );
        match attached {
            Ok(attached) => {
                pending.outbox.push_control(attached);
                if let Some(exit) = frame(&exit) {
                    pending.outbox.push_control(exit);
                }
                let _ = pending.ack.send(true);
            }
            Err(error) => {
                if let Some(frame) =
                    frame(&ServerMessage::error(error_code::SNAPSHOT_FAILED, error))
                {
                    pending.outbox.push_control(frame);
                }
                let _ = pending.ack.send(false);
            }
        }
    }

    /// The snapshot for an attach has arrived.
    fn attached(&mut self, pending: PendingAttach, snapshot: Result<Snapshot, String>) {
        if !self.running() {
            return self.attach_exited(pending, snapshot);
        }
        // The grid the snapshot shows: the grid may have changed since it
        // was asked for.
        let shown = snapshot
            .as_ref()
            .map_or(self.size(), |snapshot| snapshot.size);
        let PendingAttach {
            lease,
            cols,
            rows,
            takeover,
            answers_queries,
            outbox,
            abort,
            cancelled,
            ack,
            resized,
            full_others,
        } = pending;
        let mut session = self.info().clone();
        let frames = snapshot.and_then(
            |Snapshot {
                 bytes,
                 offset,
                 size: (grid_cols, grid_rows),
             }| {
                session.cols = grid_cols;
                session.rows = grid_rows;
                let frames = || -> Result<_> {
                    let others = (!full_others.is_empty())
                        .then(|| {
                            attached_frame(
                                session.clone(),
                                offset,
                                bytes.clone(),
                                AttachReason::Resize,
                            )
                        })
                        .transpose()?;
                    Ok((
                        attached_frame(
                            session.clone(),
                            offset,
                            bytes.clone(),
                            AttachReason::Attach,
                        )?,
                        others,
                    ))
                };
                frames().map_err(|error| error.to_string())
            },
        );
        let (own, others) = match frames {
            Ok(frames) => frames,
            Err(error) => {
                if let Some(frame) =
                    frame(&ServerMessage::error(error_code::SNAPSHOT_FAILED, error))
                {
                    outbox.push_control(frame);
                }
                if resized {
                    // Return to the size the remaining clients asked for.
                    self.schedule_grid();
                }
                let _ = ack.send(false);
                return;
            }
        };
        // Its connection may have ended (or given up) while it waited: it
        // takes nothing over then.
        let gone = cancelled.load(Ordering::SeqCst);
        if takeover && !gone {
            let taken_over = frame(&ServerMessage::error(
                error_code::TAKEN_OVER,
                "session was taken over by another attachment; its programs are still running",
            ));
            for previous in std::mem::take(&mut self.attached) {
                self.discard_lease(previous.lease);
                previous.cancelled.store(true, Ordering::SeqCst);
                if let Some(frame) = &taken_over {
                    previous.outbox.push_final(frame.clone());
                }
                // The old writer delivers the diagnostic, then closes.
                let _ = previous.abort.shutdown(std::net::Shutdown::Read);
            }
        } else if let Some(others) = others {
            self.replace(true, &full_others, Ok(others), shown);
        }
        if gone {
            self.update_attached_flag();
            self.schedule_grid();
            let _ = ack.send(false);
            return;
        }
        outbox.set_waker(self.wake.clone());
        outbox.push_control(own);
        self.attached.push(Attachment {
            lease,
            cols,
            rows,
            direct: (cols, rows) == shown,
            outbox,
            abort,
            cancelled,
            resync_after: None,
            answers_queries,
        });
        self.update_attached_flag();
        self.schedule_grid();
        // Another window changed the grid while this snapshot was pending:
        // the replacements for the new grid went to the windows attached
        // then, so this one gets its own. The holder answers in order, so
        // it follows the snapshot already queued.
        if shown != self.size() {
            self.send_resized(|attachment| attachment.lease == lease);
        }
        let _ = ack.send(true);
    }

    fn on_snapshot(&mut self, reply: link::SnapshotReply, bytes: Vec<u8>) {
        let Some(request) = self.requests.remove(&reply.req) else {
            return;
        };
        let size = (reply.cols, reply.rows);
        let snapshot = match reply.error {
            Some(error) => Err(error),
            None => Ok(Snapshot {
                bytes,
                offset: reply.offset,
                size,
            }),
        };
        match request {
            Request::Attach(pending) => {
                self.attached(pending, snapshot);
                // The next attach, now that this one's grid is known.
                while let Some(command) = self.waiting.pop_front() {
                    self.handle(command);
                    if self
                        .requests
                        .values()
                        .any(|request| matches!(request, Request::Attach(_)))
                    {
                        break;
                    }
                }
            }
            Request::Replace { full, leases } => {
                let mut session = self.info().clone();
                session.cols = size.0;
                session.rows = size.1;
                let frame = snapshot.and_then(|Snapshot { bytes, offset, .. }| {
                    attached_frame(session, offset, bytes, AttachReason::Resize)
                        .map_err(|error| error.to_string())
                });
                self.replace(full, &leases, frame, size);
            }
            Request::Resync { leases } => {
                self.resyncing = false;
                let replacement = self.replacement(snapshot, size);
                let caught_up = replacement.is_ok();
                self.resync(&leases, replacement, size);
                // The grid changed while the resync was pending, and its
                // replacements skipped these clients, which were lagging:
                // caught up now, they get one for the new grid too.
                if caught_up && size != self.size() && self.running() {
                    self.send_resized(|attachment| leases.contains(&attachment.lease));
                }
            }
            Request::Final { leases } => {
                let replacement = self.replacement(snapshot, size);
                self.resync(&leases, replacement, size);
                self.announce_exit();
            }
            Request::Detach { ack } => {
                let _ = ack.send(());
            }
            // Not a snapshot's: answered on its own (`screen_text`).
            Request::Screen { replies, .. } => {
                let error = ServerMessage::error(
                    error_code::REQUEST_FAILED,
                    "the session's holder answered with a snapshot",
                );
                for reply in replies {
                    let _ = reply.send(error.clone());
                }
            }
        }
    }

    fn replacement(
        &self,
        snapshot: Result<Snapshot, String>,
        size: (u16, u16),
    ) -> Result<Replacement, String> {
        let mut session = self.info().clone();
        session.cols = size.0;
        session.rows = size.1;
        snapshot.and_then(|Snapshot { bytes, offset, .. }| {
            Replacement::new(session, offset, bytes, AttachReason::Resync)
                .map_err(|error| error.to_string())
        })
    }

    /// The session has exited (or its holder is gone).
    fn exited(&mut self, exit_code: u32, signal: Option<i32>) {
        if self.exit.is_some() {
            return;
        }
        self.exit = Some((exit_code, signal));
        {
            let mut info = self.info();
            info.state = SessionState::Exited;
            info.exit_code = Some(exit_code);
            info.exit_signal = signal;
            info.foreground = None;
        }
        self.host.publish(SessionEvent::Exited {
            id: self.id.clone(),
            exit_code,
            signal,
        });
        self.changed();
        // No later resync can reach a client that is lagging now (its queue
        // may still hold an older snapshot), so it gets the final screen
        // before the exit instead of ending on a stale one.
        let lagging: Vec<u64> = self
            .attached
            .iter()
            .filter(|attachment| attachment.outbox.is_lagging())
            .map(|attachment| attachment.lease)
            .collect();
        if lagging.is_empty()
            || self
                .request_snapshot("limited", Request::Final { leases: lagging })
                .is_none()
        {
            self.announce_exit();
        }
    }

    /// Tell every attachment how the session ended, and let them go. Queued
    /// frames stay with the connection writers.
    fn announce_exit(&mut self) {
        let (exit_code, signal) = self.exit.unwrap_or((1, None));
        self.broadcast(&ServerMessage::Exit {
            id: self.id.clone(),
            exit_code,
            signal,
        });
        self.attached.clear();
        self.typist = None;
        self.grid_due = None;
        self.update_attached_flag();
    }

    /// What the holder reports about the session. Its size is not taken:
    /// the grid is this worker's to set, and a report of an older resize
    /// can arrive after a newer one was asked for.
    fn apply_info(&mut self, update: link::Info) {
        let changed = {
            let mut info = self.info();
            let before = info.clone();
            if let Some(title) = update.title {
                info.title = title.filter(|title| !title.is_empty());
            }
            if let Some(pwd) = update.pwd {
                info.pwd = pwd.filter(|pwd| !pwd.is_empty());
            }
            if let Some(foreground) = update.foreground {
                info.foreground = foreground.map(self::foreground);
            }
            if let Some(alternate) = update.alternate_screen {
                info.alternate_screen = alternate;
            }
            if let Some(flags) = update.kitty_keyboard_flags {
                info.kitty_keyboard_flags = flags;
            }
            if let Some(application) = update.application_cursor_keys {
                info.application_cursor_keys = application;
            }
            *info != before
        };
        if changed {
            self.changed();
        }
    }

    fn on_frame(&mut self, frame: Frame) {
        match frame.kind {
            kind::OUTPUT => {
                if let Ok(meta) = frame.meta::<link::OutputMeta>() {
                    self.emit_output(meta.offset, frame.data);
                }
            }
            kind::QUERY => self.send_query(frame.data),
            kind::SNAPSHOT_REPLY => {
                if let Ok(reply) = frame.meta::<link::SnapshotReply>() {
                    self.on_snapshot(reply, frame.data);
                }
            }
            kind::INPUT_ACK => {
                if let Ok(ack) = frame.meta::<link::InputAck>() {
                    let bytes = usize::try_from(ack.bytes)
                        .unwrap_or(usize::MAX)
                        .min(self.unacknowledged);
                    self.unacknowledged -= bytes;
                    self.input.release(bytes);
                }
            }
            kind::DETACH_DONE => {
                if let Ok(done) = frame.meta::<link::Req>() {
                    if let Some(Request::Detach { ack }) = self.requests.remove(&done.req) {
                        let _ = ack.send(());
                    }
                }
            }
            kind::EXITED => {
                if let Ok(exited) = frame.meta::<link::Exited>() {
                    self.exited(exited.exit_code, exited.signal);
                }
            }
            kind::INFO => {
                if let Ok(info) = frame.meta::<link::Info>() {
                    self.apply_info(info);
                }
            }
            kind::EVENT => match frame.meta::<link::Event>() {
                Ok(link::Event::Exited { exit_code, signal }) => self.exited(exit_code, signal),
                Ok(event) => {
                    if let Some(event) = session_event(&self.id, event) {
                        self.host.publish(event);
                    }
                }
                Err(_) => {}
            },
            kind::SCREEN_REPLY => {
                if let Ok(reply) = frame.meta::<link::ScreenReply>() {
                    if let Some(Request::Screen {
                        scrollback,
                        max_lines,
                        whole,
                        replies,
                    }) = self.requests.remove(&reply.req)
                    {
                        let text =
                            self.screen_text(reply, frame.data, (scrollback, max_lines, whole));
                        for to in replies {
                            let _ = to.send(text.clone());
                        }
                    }
                }
            }
            // A newer holder's: ignored.
            _ => {}
        }
    }

    /// Take what the holder sent.
    fn pump_link(&mut self) {
        let Some(link) = &mut self.link else {
            return;
        };
        let open = link.reader.fill(link.stream.as_raw_fd(), LINK_READ);
        loop {
            let Some(link) = &mut self.link else {
                return;
            };
            match link.reader.next() {
                Ok(Some(frame)) => self.on_frame(frame),
                Ok(None) => break,
                Err(error) => {
                    daemon::log(format_args!("session {}: {error:#}", self.id));
                    return self.lost();
                }
            }
        }
        if !open {
            self.lost();
        }
    }

    fn flush_link(&mut self) {
        let Some(link) = &mut self.link else {
            return;
        };
        if !link.writer.flush(link.stream.as_raw_fd()) {
            self.lost();
        }
    }

    /// The holder is gone: it crashed, or closed its link. The session is
    /// over unless it registers again.
    fn lost(&mut self) {
        if self.link.take().is_none() {
            return;
        }
        self.linked.store(false, Ordering::SeqCst);
        // Nothing sent to it will be acknowledged now.
        self.input.release(std::mem::take(&mut self.unacknowledged));
        if self.removed {
            return;
        }
        if self.running() {
            daemon::log(format_args!("session {}: its holder is gone", self.id));
        }
        let requests = std::mem::take(&mut self.requests);
        self.resyncing = false;
        let mut final_screen = false;
        for request in requests.into_values() {
            match request {
                Request::Attach(pending) => self.waiting.push_front(Command::Attach {
                    lease: pending.lease,
                    cols: pending.cols,
                    rows: pending.rows,
                    takeover: pending.takeover,
                    answers_queries: pending.answers_queries,
                    outbox: pending.outbox,
                    abort: pending.abort,
                    cancelled: pending.cancelled,
                    ack: pending.ack,
                }),
                Request::Detach { ack } => {
                    let _ = ack.send(());
                }
                Request::Screen { replies, .. } => {
                    let error = ServerMessage::error(
                        error_code::REQUEST_FAILED,
                        "the session's holder is gone, and its screen with it",
                    );
                    for reply in replies {
                        let _ = reply.send(error.clone());
                    }
                }
                Request::Final { .. } => final_screen = true,
                Request::Replace { .. } | Request::Resync { .. } => {}
            }
        }
        // It ended as a hangup would have ended it; how is unknown.
        self.exited(1, None);
        if final_screen {
            self.announce_exit();
        }
        // Attaches get what is left: an empty screen and the exit.
        while let Some(command) = self.waiting.pop_front() {
            self.handle(command);
        }
    }

    /// Forget the session: tell its holder, which exits, or remove the
    /// manifest of one that is gone.
    fn remove(&mut self) {
        if self.removed {
            return;
        }
        self.removed = true;
        match self.link.take() {
            Some(mut link) => {
                link.writer.push(link::bare(kind::REMOVE));
                link.writer.flush_all(link.stream.as_raw_fd(), REMOVE_FLUSH);
            }
            None => {
                let _ = std::fs::remove_file(paths::manifest_path(&self.host.state, &self.id));
            }
        }
        self.linked.store(false, Ordering::SeqCst);
        self.input.release(std::mem::take(&mut self.unacknowledged));
        for request in std::mem::take(&mut self.requests).into_values() {
            match request {
                Request::Detach { ack } => {
                    let _ = ack.send(());
                }
                Request::Screen { replies, .. } => {
                    let error = ServerMessage::error(
                        error_code::UNKNOWN_SESSION,
                        "the session was removed",
                    );
                    for reply in replies {
                        let _ = reply.send(error.clone());
                    }
                }
                _ => {}
            }
        }
        self.attached.clear();
        self.update_attached_flag();
    }

    fn next_wait(&self) -> Duration {
        let now = Instant::now();
        let mut wait = IDLE_WAIT;
        if let Some((due, _)) = self.grid_due {
            wait = wait.min(due.saturating_duration_since(now));
        }
        for attachment in &self.attached {
            if let Some(after) = attachment.resync_after {
                wait = wait.min(after.saturating_duration_since(now));
            }
        }
        wait
    }

    fn run(mut self) {
        loop {
            if self.kill_requested.swap(false, Ordering::SeqCst) && self.running() {
                self.tell(link::bare(kind::KILL));
            }
            // Bounded per pass so output keeps flowing under a command flood.
            // Their wakeups are drained below, so a full batch means more
            // may be queued: look again without sleeping.
            let mut handled = 0;
            let mut abandoned = false;
            while handled < 64 {
                match self.rx.try_recv() {
                    Ok(command) => self.handle(command),
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => {
                        abandoned = true;
                        break;
                    }
                }
                handled += 1;
            }
            if let Some(ack) = self.removed_ack.take() {
                // Its descriptors are closed once the remover hears back.
                // Later commands find the session unavailable.
                drop(self);
                let _ = ack.send(());
                return;
            }
            if abandoned {
                // Every handle is gone: replaced by the session its holder
                // registered again. The holder link, if any, closes with
                // this thread.
                return;
            }
            self.release_gone();
            self.pump_link();
            // Output may have left a client lagging with nothing queued.
            self.resync_lagging();
            self.apply_due_grid();
            self.flush_link();
            let wait = if handled == 64 {
                Duration::ZERO
            } else {
                self.next_wait()
            };
            let (fd, events) = match &self.link {
                Some(link) => (
                    link.stream.as_raw_fd(),
                    libc::POLLIN
                        | if link.writer.is_empty() {
                            0
                        } else {
                            libc::POLLOUT
                        },
                ),
                None => (-1, 0),
            };
            let mut poll = [
                libc::pollfd {
                    fd,
                    events,
                    revents: 0,
                },
                libc::pollfd {
                    fd: self.wake_rx.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                },
            ];
            let millis = wait.as_micros().div_ceil(1000).min(i32::MAX as u128) as libc::c_int;
            unsafe {
                libc::poll(poll.as_mut_ptr(), 2, millis);
            }
            signals::drain(&self.wake_rx);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_input_gate_has_hysteresis() {
        let gate = InputGate::default();
        gate.reserve(INPUT_HIGH_WATER + 1);
        assert!(gate.full());
        assert!(!gate.wait_for_room(Duration::from_millis(1)));
        gate.release(INPUT_HIGH_WATER - INPUT_LOW_WATER);
        assert!(!gate.full());
        assert!(!gate.wait_for_room(Duration::from_millis(1)));
        gate.release(2);
        assert!(gate.wait_for_room(Duration::from_millis(1)));
    }

    #[test]
    fn holder_events_become_client_events() {
        assert_eq!(
            session_event("s", link::Event::Bell),
            Some(SessionEvent::Bell { id: "s".into() })
        );
        assert_eq!(
            session_event(
                "s",
                link::Event::Progress {
                    state: "set".into(),
                    value: Some(250)
                }
            ),
            Some(SessionEvent::Progress {
                id: "s".into(),
                state: ProgressState::Set,
                value: Some(100)
            })
        );
        // A state from a newer holder is dropped.
        assert_eq!(
            session_event(
                "s",
                link::Event::Progress {
                    state: "sparkle".into(),
                    value: None
                }
            ),
            None
        );
    }
}
