use crate::{
    daemon, environment,
    outbox::{Outbox, Output, Push},
    processes,
    signals::{self, Wake},
    stream::{Batch, DisplayStream},
};
use anyhow::{bail, Context, Result};
use cherry_protocol::{
    encode_frame, error_code, valid_size, AttachReason, ServerMessage, SessionInfo, SessionState,
    MAX_SNAPSHOT_BYTES,
};
use cherry_vt::Terminal;
use portable_pty::{native_pty_system, MasterPty, PtySize};
use std::{
    collections::{BTreeMap, VecDeque},
    fs::OpenOptions,
    os::unix::{fs::OpenOptionsExt, io::AsRawFd, net::UnixStream, process::CommandExt},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{self, Receiver, SyncSender},
        Arc, Condvar, Mutex,
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
/// Terminal replies waiting for a child that never reads stdin are bounded.
const MAX_PENDING_REPLIES: usize = 1024 * 1024;
/// Grid changes requested by clients apply once the size has settled.
const GRID_SETTLE: Duration = Duration::from_millis(75);
/// Workers are woken by events; this only bounds a missed wakeup.
const IDLE_WAIT: Duration = Duration::from_secs(60);
/// Session members are not our children, so their exits are polled while a
/// termination is in progress.
const TERMINATION_POLL: Duration = Duration::from_millis(50);
const RESYNC_RETRY: Duration = Duration::from_secs(1);

/// A validated request for a new session.
pub struct Launch {
    pub name: String,
    pub cwd: PathBuf,
    pub command: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub cols: u16,
    pub rows: u16,
    /// `SSH_AUTH_SOCK` for the session: the link clients keep pointed at
    /// their current agent.
    pub agent_link: PathBuf,
}

pub struct Session {
    pub info: Arc<Mutex<SessionInfo>>,
    tx: SyncSender<Command>,
    wake: Arc<Wake>,
    kill_requested: Arc<AtomicBool>,
    pub input: Arc<InputGate>,
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
    Resize {
        lease: u64,
        cols: u16,
        rows: u16,
    },
    /// A voluntary detach. It follows the lease's earlier input through the
    /// command queue, and that input is still delivered.
    Detach {
        lease: u64,
        ack: SyncSender<()>,
    },
}

/// Input accepted from connections but not yet written to the PTY, shared so
/// connections can stop reading while the child is not consuming it.
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

/// Bytes waiting for the PTY. Terminal replies (no lease) outlive controller
/// leases. User input from a lease is discarded when that controller is
/// taken over or disconnects abnormally, but delivered after a detach.
#[derive(Default)]
struct PendingInput {
    chunks: VecDeque<InputChunk>,
    len: usize,
    user_len: usize,
}

struct InputChunk {
    lease: Option<u64>,
    user: bool,
    bytes: VecDeque<u8>,
}

impl PendingInput {
    fn push(&mut self, lease: Option<u64>, user: bool, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        self.len += bytes.len();
        if user {
            self.user_len += bytes.len();
        }
        if let Some(last) = self
            .chunks
            .back_mut()
            .filter(|chunk| chunk.lease == lease && chunk.user == user)
        {
            last.bytes.extend(bytes);
        } else {
            self.chunks.push_back(InputChunk {
                lease,
                user,
                bytes: bytes.iter().copied().collect(),
            });
        }
    }

    /// Drop a lease's unsent input; returns the user bytes removed.
    fn discard_lease(&mut self, lease: u64) -> usize {
        let mut removed = 0;
        self.chunks.retain(|chunk| {
            if chunk.lease == Some(lease) {
                removed += chunk.bytes.len();
                false
            } else {
                true
            }
        });
        self.len -= removed;
        self.user_len -= removed;
        removed
    }

    /// Keep a detached lease's input for delivery.
    fn keep_lease(&mut self, lease: u64) {
        for chunk in &mut self.chunks {
            if chunk.lease == Some(lease) {
                chunk.lease = None;
            }
        }
    }

    /// Drop everything; returns the user bytes removed.
    fn clear(&mut self) -> usize {
        let user = self.user_len;
        self.chunks.clear();
        self.len = 0;
        self.user_len = 0;
        user
    }

    /// Write as much as the PTY accepts; returns the user bytes written.
    fn write_to(&mut self, fd: libc::c_int) -> usize {
        let mut written = 0;
        while let Some(chunk) = self.chunks.front_mut() {
            let bytes = chunk.bytes.make_contiguous();
            let n = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
            if n <= 0 {
                break;
            }
            let n = n as usize;
            chunk.bytes.drain(..n);
            self.len -= n;
            if chunk.user {
                self.user_len -= n;
                written += n;
            }
            if !chunk.bytes.is_empty() {
                break;
            }
            self.chunks.pop_front();
        }
        written
    }
}

impl Session {
    pub fn spawn(launch: Launch) -> Result<Arc<Self>> {
        let Launch {
            name,
            cwd,
            mut command,
            env,
            cols,
            rows,
            agent_link,
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
        let terminal = Terminal::new(cols, rows, 1024 * 1024)?;
        let pair = native_pty_system().openpty(size(cols, rows))?;
        let fd = pair
            .master
            .as_raw_fd()
            .context("PTY implementation has no Unix descriptor")?;
        // The one session worker owns all I/O. Nonblocking writes prevent a child
        // which stops reading input from wedging termination or other sessions.
        unsafe {
            let flags = libc::fcntl(fd, libc::F_GETFL);
            if flags < 0 || libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) < 0 {
                return Err(std::io::Error::last_os_error().into());
            }
        }
        let tty = pair.master.tty_name().context("PTY has no terminal name")?;
        let slave = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_NOCTTY)
            .open(&tty)
            .with_context(|| format!("opening {}", tty.display()))?;
        drop(pair.slave);
        let id = Uuid::new_v4().to_string();
        let (wake, wake_rx) = Wake::pair()?;
        // Registered before the child exists, so its exit always wakes us.
        signals::register(&wake);
        let mut child = std::process::Command::new(&command[0]);
        child
            .args(&command[1..])
            .env_clear()
            .envs(environment::session_env(&id, &agent_link, &env))
            .current_dir(&cwd)
            .stdin(slave.try_clone()?)
            .stdout(slave.try_clone()?)
            .stderr(slave);
        let limit = daemon::child_fd_limit();
        unsafe {
            child.pre_exec(move || {
                // Start from the dispositions a login would have, whatever
                // the daemon inherited (a nohup'd starter ignores SIGHUP).
                for signal in [
                    libc::SIGCHLD,
                    libc::SIGHUP,
                    libc::SIGINT,
                    libc::SIGQUIT,
                    libc::SIGTERM,
                    libc::SIGALRM,
                    libc::SIGTSTP,
                    libc::SIGTTIN,
                    libc::SIGTTOU,
                ] {
                    libc::signal(signal, libc::SIG_DFL);
                }
                if libc::setsid() == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                if libc::ioctl(0, libc::TIOCSCTTY as _, 0) == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                // Only the terminal is inherited. Without accept4, macOS sets
                // close-on-exec on an accepted connection only after accept
                // returns, so another thread's client could otherwise leak in.
                // Done before the limit drops: the sweep stops at the limit.
                environment::cloexec_from_3();
                // The daemon raises its own descriptor limit; sessions get the
                // limit the user had.
                if let Some(limit) = limit {
                    libc::setrlimit(libc::RLIMIT_NOFILE, &limit);
                }
                Ok(())
            });
        }
        let child = child
            .spawn()
            .with_context(|| format!("launching {}", command[0]))?;
        let pid = child.id();
        let info = Arc::new(Mutex::new(SessionInfo {
            id,
            name,
            cwd: cwd.to_string_lossy().into(),
            command,
            cols,
            rows,
            state: SessionState::Running,
            pid: Some(pid),
            exit_code: None,
            attached: false,
            exit_signal: None,
        }));
        let (tx, rx) = mpsc::sync_channel(64);
        let kill_requested = Arc::new(AtomicBool::new(false));
        let input = Arc::new(InputGate::default());
        let session = Arc::new(Self {
            info: info.clone(),
            tx,
            wake: wake.clone(),
            kill_requested: kill_requested.clone(),
            input: input.clone(),
        });
        let worker = Worker {
            info,
            master: pair.master,
            _child: child,
            pid: pid as libc::pid_t,
            terminal,
            rx,
            wake,
            wake_rx,
            attached: Vec::new(),
            offset: 0,
            pending_input: PendingInput::default(),
            input,
            display: DisplayStream::default(),
            eof: false,
            kill_requested,
            termination: None,
            grid_due: None,
            typist: None,
        };
        if let Err(error) = thread::Builder::new()
            .name("cherry-session".into())
            .spawn(move || worker.run())
        {
            // The worker owns the child; without it nobody would reap or
            // hang up the session, so end it now.
            processes::kill_session(pid as libc::pid_t);
            let _ = processes::reap(pid as libc::pid_t);
            return Err(error).context("starting session worker");
        }
        Ok(session)
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

    pub fn snapshot_info(&self) -> SessionInfo {
        self.info.lock().unwrap().clone()
    }
}

fn size(cols: u16, rows: u16) -> PtySize {
    PtySize {
        cols,
        rows,
        pixel_width: 0,
        pixel_height: 0,
    }
}

fn frame(message: &ServerMessage) -> Option<Arc<Vec<u8>>> {
    encode_frame(message).ok().map(Arc::new)
}

/// The terminal as a renderer stream, oldest history dropped to fit a frame.
fn snapshot_bytes(terminal: &Terminal) -> Result<Vec<u8>> {
    let raw = terminal.snapshot_limited(MAX_SNAPSHOT_BYTES)?;
    Ok(DisplayStream::default().feed(&raw).display)
}

/// The terminal's screens without history (`Terminal::refresh`) as a
/// renderer stream.
fn refresh_bytes(terminal: &Terminal) -> Result<Vec<u8>> {
    let raw = terminal.refresh()?;
    if raw.len() > MAX_SNAPSHOT_BYTES {
        bail!(
            "the screen needs a {}-byte refresh; the limit is {MAX_SNAPSHOT_BYTES} bytes",
            raw.len()
        );
    }
    Ok(DisplayStream::default().feed(&raw).display)
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

/// An explicit kill in progress: SIGHUP, then SIGTERM after the grace period,
/// then SIGKILL after another.
struct Termination {
    started: Instant,
    stage: u8,
}

struct Worker {
    info: Arc<Mutex<SessionInfo>>,
    master: Box<dyn MasterPty + Send>,
    /// Kept for its handle; the worker reaps the leader itself.
    _child: std::process::Child,
    pid: libc::pid_t,
    terminal: Terminal,
    rx: Receiver<Command>,
    wake: Arc<Wake>,
    wake_rx: UnixStream,
    attached: Vec<Attachment>,
    offset: u64,
    pending_input: PendingInput,
    input: Arc<InputGate>,
    display: DisplayStream,
    eof: bool,
    kill_requested: Arc<AtomicBool>,
    termination: Option<Termination>,
    /// When to apply a settled grid change, and its target.
    grid_due: Option<(Instant, (u16, u16))>,
    /// Of the attachments whose terminal answers queries, the one that most
    /// recently sent input: it answers them (see `send_query`).
    typist: Option<u64>,
}

impl Worker {
    fn master_fd(&self) -> libc::c_int {
        self.master.as_raw_fd().unwrap_or(-1)
    }

    fn size(&self) -> (u16, u16) {
        let info = self.info.lock().unwrap();
        (info.cols, info.rows)
    }

    /// The shared grid: the smallest size any attachment asked for.
    fn desired_size(&self) -> Option<(u16, u16)> {
        self.attached
            .iter()
            .map(|a| (a.cols, a.rows))
            .reduce(|(cols, rows), (c, r)| (cols.min(c), rows.min(r)))
    }

    fn update_attached_flag(&self) {
        self.info.lock().unwrap().attached = !self.attached.is_empty();
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
        if self.size() == (cols, rows) {
            return;
        }
        if let Err(error) = self.resize(cols, rows) {
            self.broadcast(&ServerMessage::error(
                error_code::RESIZE_FAILED,
                error.to_string(),
            ));
            return;
        }
        self.send_resized(None, |_| true);
    }

    /// Send the attachments `due` selects an `Attached{Resize}` for the
    /// grid's size, called when the grid or their window changed. Most get
    /// the screens without history (`Terminal::refresh`), which is small
    /// however much history the session keeps: a window of another size
    /// renders a viewport from a copy of the screens, and a window that
    /// showed the stream directly, such as one whose own resize the grid
    /// followed, keeps its own scrollback. Only a window that rendered a
    /// viewport and now matches the grid gets a full snapshot, since its
    /// scrollback lacks the history since it left the stream (`snapshot`,
    /// the session's snapshot bytes when made already). Either is queued
    /// behind the client's output, and supersedes an older replacement
    /// still queued, which is why one that supersedes a full one is full. A
    /// lagging client gets the new size with its resync.
    fn send_resized(&mut self, snapshot: Option<Vec<u8>>, due: impl Fn(&Attachment) -> bool) {
        let size = self.size();
        let session = self.info.lock().unwrap().clone();
        let (terminal, offset) = (&self.terminal, self.offset);
        let make = |bytes: Result<Vec<u8>>| {
            bytes
                .and_then(|snapshot| {
                    attached_frame(session.clone(), offset, snapshot, AttachReason::Resize)
                })
                .map_err(|error| error.to_string())
        };
        let mut snapshot = snapshot;
        let mut full = None;
        let mut refresh = None;
        for attachment in &mut self.attached {
            if attachment.outbox.is_lagging() || !due(attachment) {
                continue;
            }
            let matches = (attachment.cols, attachment.rows) == size;
            let needs_full = attachment.needs_full(size);
            let replacement = if needs_full {
                full.get_or_insert_with(|| {
                    make(snapshot.take().map_or_else(|| snapshot_bytes(terminal), Ok))
                })
            } else {
                refresh.get_or_insert_with(|| make(refresh_bytes(terminal)))
            };
            match replacement {
                Ok(frame) => {
                    attachment
                        .outbox
                        .push_replacement(frame.clone(), needs_full);
                    attachment.direct = matches;
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

    fn resize(&mut self, cols: u16, rows: u16) -> Result<()> {
        if !valid_size(cols, rows) {
            bail!("invalid terminal size");
        }
        if self.size() == (cols, rows) {
            return Ok(());
        }
        let replies = self.terminal.resize(cols, rows)?;
        self.master.resize(size(cols, rows))?;
        self.queue_replies(&replies);
        let mut info = self.info.lock().unwrap();
        info.cols = cols;
        info.rows = rows;
        Ok(())
    }

    fn queue_replies(&mut self, replies: &[u8]) {
        let queued = self.pending_input.len - self.pending_input.user_len;
        if queued + replies.len() <= MAX_PENDING_REPLIES {
            self.pending_input.push(None, false, replies);
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

    /// Drop attachments whose connection ended or whose peer is gone.
    fn release_gone(&mut self) {
        let before = self.attached.len();
        let mut released = 0;
        let pending = &mut self.pending_input;
        self.attached.retain(|attachment| {
            let dead = attachment.outbox.is_dead();
            if attachment.cancelled.load(Ordering::SeqCst) || dead {
                released += pending.discard_lease(attachment.lease);
                if dead {
                    // Unblock the connection's reader.
                    let _ = attachment.abort.shutdown(std::net::Shutdown::Both);
                }
                false
            } else {
                true
            }
        });
        self.input.release(released);
        if self.attached.len() != before {
            self.update_attached_flag();
            self.schedule_grid();
        }
    }

    /// Send a fresh snapshot to lagging clients whose queues have drained.
    fn resync_lagging(&mut self) {
        let now = Instant::now();
        self.resync_where(|attachment| {
            attachment.resync_after.is_none_or(|after| now >= after)
                && attachment.outbox.resync_due()
        });
    }

    /// Send a fresh `Attached{Resync}` to the attachments `due` selects. It
    /// replaces their queued output and any older snapshot.
    fn resync_where(&mut self, due: impl Fn(&Attachment) -> bool) {
        let now = Instant::now();
        if !self.attached.iter().any(&due) {
            return;
        }
        let size = self.size();
        let session = self.info.lock().unwrap().clone();
        let replacement = snapshot_bytes(&self.terminal).and_then(|snapshot| {
            Replacement::new(session, self.offset, snapshot, AttachReason::Resync)
        });
        for attachment in &mut self.attached {
            if !due(attachment) {
                continue;
            }
            match &replacement {
                Ok(replacement) => {
                    replacement.push_to(&attachment.outbox);
                    attachment.resync_after = None;
                    attachment.direct = (attachment.cols, attachment.rows) == size;
                }
                Err(error) => {
                    if let Some(frame) = self::frame(&ServerMessage::error(
                        error_code::SNAPSHOT_FAILED,
                        error.to_string(),
                    )) {
                        attachment.outbox.push_control(frame);
                    }
                    attachment.resync_after = Some(now + RESYNC_RETRY);
                }
            }
        }
    }

    /// Send renderer output, and the queries in it to the responder, in
    /// order.
    fn emit(&mut self, output: Batch) {
        let Batch {
            display, queries, ..
        } = output;
        if queries.is_empty() {
            self.emit_output(display);
            return;
        }
        let mut at = 0;
        for (position, query) in queries {
            if position > at {
                self.emit_output(display[at..position].to_vec());
                at = position;
            }
            self.send_query(query);
        }
        if at < display.len() {
            self.emit_output(display[at..].to_vec());
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

    fn emit_output(&mut self, data: Vec<u8>) {
        let offset = self.offset;
        self.offset += data.len() as u64;
        if self.attached.is_empty() {
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
            } => {
                let attached = self.attach(
                    lease,
                    cols,
                    rows,
                    takeover,
                    answers_queries,
                    outbox,
                    abort,
                    cancelled,
                );
                let _ = ack.send(attached);
            }
            Command::Input { lease, data } => {
                let attachment = self
                    .attached
                    .iter()
                    .find(|a| a.lease == lease && !a.cancelled.load(Ordering::SeqCst));
                let attached = attachment.is_some();
                if attachment.is_some_and(|a| a.answers_queries) {
                    self.typist = Some(lease);
                }
                if attached && !self.eof {
                    self.pending_input.push(Some(lease), true, &data);
                } else {
                    self.input.release(data.len());
                }
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
                    self.send_resized(None, |a| a.lease == lease);
                }
                // Otherwise the grid follows this window, and the client
                // waits for it on what it shows.
            }
            Command::Detach { lease, ack } => {
                if let Some(index) = self.attached.iter().position(|a| a.lease == lease) {
                    self.attached.remove(index);
                    self.pending_input.keep_lease(lease);
                    self.update_attached_flag();
                    self.schedule_grid();
                }
                let _ = ack.send(());
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn attach(
        &mut self,
        lease: u64,
        cols: u16,
        rows: u16,
        takeover: bool,
        answers_queries: bool,
        outbox: Arc<Outbox>,
        abort: UnixStream,
        cancelled: Arc<AtomicBool>,
    ) -> bool {
        if cancelled.load(Ordering::SeqCst) {
            return false;
        }
        self.release_gone();
        let dimensions = match (takeover, self.desired_size()) {
            (false, Some((c, r))) => (cols.min(c), rows.min(r)),
            _ => (cols, rows),
        };
        let resized = dimensions != self.size();
        if resized {
            if let Err(error) = self.resize(dimensions.0, dimensions.1) {
                if let Some(frame) = frame(&ServerMessage::error(
                    error_code::RESIZE_FAILED,
                    error.to_string(),
                )) {
                    outbox.push_control(frame);
                }
                return false;
            }
        }
        // Snapshot failure must not revoke the previous controllers.
        let session = self.info.lock().unwrap().clone();
        let frames = snapshot_bytes(&self.terminal).and_then(|snapshot| {
            // The other windows get replacements for the new size; those
            // that need a full snapshot get the same one.
            let others = (resized
                && !takeover
                && self
                    .attached
                    .iter()
                    .any(|a| !a.outbox.is_lagging() && a.needs_full(dimensions)))
            .then(|| snapshot.clone());
            Ok((
                attached_frame(session, self.offset, snapshot, AttachReason::Attach)?,
                others,
            ))
        });
        let (own, others) = match frames {
            Ok(frames) => frames,
            Err(error) => {
                if let Some(frame) = frame(&ServerMessage::error(
                    error_code::SNAPSHOT_FAILED,
                    error.to_string(),
                )) {
                    outbox.push_control(frame);
                }
                if resized {
                    // Return to the size the remaining clients asked for.
                    self.schedule_grid();
                }
                return false;
            }
        };
        if takeover {
            let taken_over = frame(&ServerMessage::error(
                error_code::TAKEN_OVER,
                "session was taken over by another attachment; its programs are still running",
            ));
            let mut released = 0;
            for previous in std::mem::take(&mut self.attached) {
                released += self.pending_input.discard_lease(previous.lease);
                previous.cancelled.store(true, Ordering::SeqCst);
                if let Some(frame) = &taken_over {
                    previous.outbox.push_final(frame.clone());
                }
                // The old writer delivers the diagnostic, then closes.
                let _ = previous.abort.shutdown(std::net::Shutdown::Read);
            }
            self.input.release(released);
        } else if resized {
            self.send_resized(others, |_| true);
        }
        outbox.set_waker(self.wake.clone());
        outbox.push_control(own);
        self.attached.push(Attachment {
            lease,
            cols,
            rows,
            direct: (cols, rows) == dimensions,
            outbox,
            abort,
            cancelled,
            resync_after: None,
            answers_queries,
        });
        self.update_attached_flag();
        self.schedule_grid();
        true
    }

    /// Read available output; false once the PTY reports end of file.
    fn read_output(&mut self) -> bool {
        let fd = self.master_fd();
        let mut buf = [0u8; 16384];
        let mut output = Batch::default();
        let mut open = true;
        // Bounded work per wake gives input and termination a turn under
        // output floods. One frame carries the whole burst.
        let mut reads = 0;
        while reads < 16 {
            let n = unsafe { libc::read(fd, buf.as_mut_ptr().cast(), buf.len()) };
            if n < 0 {
                let error = std::io::Error::last_os_error();
                if error.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                open = error.kind() == std::io::ErrorKind::WouldBlock;
                break;
            }
            if n == 0 {
                open = false;
                break;
            }
            reads += 1;
            let mut batch = self.display.feed(&buf[..n as usize]);
            let replies = self.terminal.feed(&std::mem::take(&mut batch.terminal));
            self.queue_replies(&replies);
            output.append(batch);
        }
        if !output.display.is_empty() || !output.queries.is_empty() {
            self.emit(output);
        }
        open
    }

    fn begin_termination(&mut self) {
        processes::signal_session(self.pid, libc::SIGHUP);
        self.termination = Some(Termination {
            started: Instant::now(),
            stage: 0,
        });
    }

    /// Advance an explicit kill, or notice a natural exit. True once the
    /// session has ended and its leader has been reaped.
    fn check_exit(&mut self) -> bool {
        let leader_exited = processes::exited(self.pid);
        if let Some(termination) = &mut self.termination {
            // The exited leader stays unreaped until the sweep is over, so its
            // session ID cannot be reused by an unrelated process meanwhile.
            let survivors = processes::live_members(self.pid);
            if leader_exited && (survivors.is_empty() || termination.stage >= 2) {
                self.finish();
                return true;
            }
            let grace = daemon::config().kill_grace;
            let elapsed = termination.started.elapsed();
            if termination.stage >= 2 {
                // SIGKILL cannot be ignored, but a sweep can miss a member
                // (one forked meanwhile, a listing that failed): repeat it
                // until the leader is gone.
                processes::kill_session(self.pid);
            } else if elapsed >= grace * 2 {
                termination.stage = 2;
                processes::kill_session(self.pid);
            } else if termination.stage < 1 && elapsed >= grace {
                termination.stage = 1;
                processes::signal_session(self.pid, libc::SIGTERM);
            }
            return false;
        }
        // A natural exit is a hangup, as in any terminal: the master closes
        // and the kernel signals the foreground job. Jobs that ignore SIGHUP
        // (nohup, disown) keep running.
        if leader_exited {
            self.finish();
        }
        leader_exited
    }

    fn finish(&mut self) {
        // Bytes written before exit are part of the transcript.
        if !self.eof {
            self.read_output();
        }
        let status = processes::reap(self.pid);
        let id = {
            let mut info = self.info.lock().unwrap();
            info.state = SessionState::Exited;
            info.exit_code = Some(status.code);
            info.exit_signal = status.signal;
            info.id.clone()
        };
        // No later resync can reach a client that is lagging now (its queue
        // may still hold an older snapshot), so it gets the final screen
        // before the exit instead of ending on a stale one.
        self.resync_where(|attachment| attachment.outbox.is_lagging());
        self.broadcast(&ServerMessage::Exit {
            id,
            exit_code: status.code,
            signal: status.signal,
        });
    }

    fn next_wait(&self) -> Duration {
        let now = Instant::now();
        let mut wait = IDLE_WAIT;
        if self.termination.is_some() {
            wait = wait.min(TERMINATION_POLL);
        }
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
            if self.kill_requested.swap(false, Ordering::SeqCst) && self.termination.is_none() {
                self.begin_termination();
            }
            // Bounded per pass so output keeps flowing under a command flood.
            // Their wakeups are drained below, so a full batch means more
            // may be queued: look again without sleeping.
            let mut handled = 0;
            while handled < 64 {
                match self.rx.try_recv() {
                    Ok(command) => self.handle(command),
                    Err(_) => break,
                }
                handled += 1;
            }
            self.release_gone();
            self.resync_lagging();
            self.apply_due_grid();
            if !self.eof {
                self.eof = !self.read_output();
                // Output may have left a client lagging with nothing queued.
                self.resync_lagging();
            }
            if self.check_exit() {
                break;
            }
            if self.eof {
                let dropped = self.pending_input.clear();
                self.input.release(dropped);
            } else {
                let written = self.pending_input.write_to(self.master_fd());
                self.input.release(written);
            }
            let wait = if handled == 64 {
                Duration::ZERO
            } else {
                self.next_wait()
            };
            let mut poll = [
                libc::pollfd {
                    fd: if self.eof { -1 } else { self.master_fd() },
                    events: libc::POLLIN
                        | if self.pending_input.len == 0 {
                            0
                        } else {
                            libc::POLLOUT
                        },
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
        self.serve_exited();
    }

    /// Keep an exited session's screen for inspection and re-attachment,
    /// without its PTY or a polling loop.
    fn serve_exited(self) {
        let Self {
            info,
            terminal,
            rx,
            offset,
            master,
            attached,
            mut pending_input,
            input,
            ..
        } = self;
        input.release(pending_input.clear());
        // Closing the master hangs up the terminal. Queued Exit frames stay
        // with the connection writers.
        drop(attached);
        drop(master);
        info.lock().unwrap().attached = false;
        while let Ok(command) = rx.recv() {
            match command {
                Command::Attach { outbox, ack, .. } => {
                    let session = info.lock().unwrap().clone();
                    let exit = ServerMessage::Exit {
                        id: session.id.clone(),
                        exit_code: session.exit_code.unwrap_or(1),
                        signal: session.exit_signal,
                    };
                    match snapshot_bytes(&terminal).and_then(|snapshot| {
                        attached_frame(session, offset, snapshot, AttachReason::Attach)
                    }) {
                        Ok(attached) => {
                            outbox.push_control(attached);
                            if let Some(exit) = frame(&exit) {
                                outbox.push_control(exit);
                            }
                            let _ = ack.send(true);
                        }
                        Err(error) => {
                            if let Some(frame) = frame(&ServerMessage::error(
                                error_code::SNAPSHOT_FAILED,
                                error.to_string(),
                            )) {
                                outbox.push_control(frame);
                            }
                            let _ = ack.send(false);
                        }
                    }
                }
                Command::Input { data, .. } => input.release(data.len()),
                Command::Detach { ack, .. } => {
                    let _ = ack.send(());
                }
                Command::Resize { .. } => {}
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bytes(pending: &PendingInput) -> Vec<u8> {
        pending
            .chunks
            .iter()
            .flat_map(|chunk| chunk.bytes.iter().copied())
            .collect()
    }

    #[test]
    fn replacing_controller_discards_only_its_unsent_input() {
        let mut pending = PendingInput::default();
        pending.push(Some(1), true, b"old command");
        pending.push(None, false, b"\x1b[1;1R");
        pending.push(Some(1), true, b"old remainder");
        pending.push(Some(2), true, b"new command");
        assert_eq!(pending.discard_lease(1), 24);
        assert_eq!(bytes(&pending), b"\x1b[1;1Rnew command");
        assert_eq!(pending.len, bytes(&pending).len());
        assert_eq!(pending.user_len, 11);
    }

    #[test]
    fn detached_input_is_kept_for_delivery() {
        let mut pending = PendingInput::default();
        pending.push(Some(1), true, b"echo marker\r");
        pending.keep_lease(1);
        assert_eq!(pending.discard_lease(1), 0);
        assert_eq!(bytes(&pending), b"echo marker\r");
        assert_eq!(pending.clear(), 12);
    }

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
}
