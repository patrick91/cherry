//! A session's holder: `cherry-host hold`, one process per session.
//!
//! The daemon starts it (a double fork with `setsid`: it is never the
//! daemon's child, so it outlives the daemon) with the daemon's end of a
//! socket pair as descriptor 3 and a `Launch` on it. The holder owns
//! everything a session needs to outlive the daemon: the PTY master; the
//! child, which it spawns and reaps, so the child's session ID stays
//! reserved while its members are signalled (see `processes`); the kill
//! escalation; the headless terminal and the display stream, so the screen
//! stays exact and terminal queries are answered while no daemon runs;
//! pending input; the output offset; and the session's metadata (title,
//! working directory, foreground process, whether the alternate screen
//! shows, the kitty keyboard flags, application cursor keys, exit status),
//! which it reports as it changes (`link::Info`). A libghostty-vt abort ends only this session.
//!
//! When the link drops, the session carries on and the holder redials the
//! daemon socket at once when an entry appears in the socket's directory,
//! and otherwise with backoff (250 ms to 2 s; up to 30 s while it watches
//! the directory), then registers again (`HolderHello`). Meanwhile it keeps
//! bells, notifications, progress reports and the session's exit, bounded,
//! for the next daemon, until that daemon has taken them.
//! It exits once the session has exited and either a daemon told it to
//! remove the session (so a retained exited session stays inspectable
//! across daemon restarts) or a daemon refused it for good
//! (`link::Refused`). A manifest in the state directory (`paths::Manifest`)
//! tells a starting daemon to expect it.
use crate::{
    daemon::log,
    environment,
    link::{self, kind, Frame},
    paths, processes, screen, signals,
    stream::{Batch, DisplayStream},
    watch::DirWatch,
};
use anyhow::{bail, Context, Result};
use cherry_protocol::{valid_size, MAX_SNAPSHOT_BYTES};
use cherry_vt::{Osc99, ProgressState, Terminal, VtEvent};
use portable_pty::{native_pty_system, MasterPty, PtySize};
use std::{
    collections::VecDeque,
    ffi::OsStr,
    fs::OpenOptions,
    io,
    os::unix::{
        ffi::OsStrExt,
        fs::OpenOptionsExt,
        io::{AsRawFd, FromRawFd, RawFd},
        net::UnixStream,
        process::CommandExt,
    },
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

/// The descriptor a new holder finds its first link on.
pub const LINK_FD: RawFd = 3;
/// Terminal replies waiting for a child that never reads stdin are bounded.
const MAX_PENDING_REPLIES: usize = 1024 * 1024;
/// The holder is woken by events; this only bounds a missed wakeup.
const IDLE_WAIT: Duration = Duration::from_secs(60);
/// Session members are not the holder's children, so their exits are
/// polled while a termination is in progress.
const TERMINATION_POLL: Duration = Duration::from_millis(50);
const LAUNCH_TIMEOUT: Duration = Duration::from_secs(10);
/// Redialing a daemon that went away backs off from the first delay to the
/// last; while the socket's directory is watched, which notices a daemon
/// binding the socket, to the longer one.
const REDIAL_FIRST: Duration = Duration::from_millis(250);
const REDIAL_MAX: Duration = Duration::from_secs(2);
const REDIAL_WATCHED_MAX: Duration = Duration::from_secs(30);
/// After an entry appeared in the socket's directory and the dial failed:
/// the daemon may be between binding and listening.
const REDIAL_SOON: Duration = Duration::from_millis(50);
/// The terminal is not read while this much output waits for the daemon,
/// until it drains to the low mark: a program cannot outrun the daemon.
const LINK_HIGH_WATER: usize = 4 * 1024 * 1024;
const LINK_LOW_WATER: usize = 1024 * 1024;
/// Bytes taken from the link per pass, so output keeps flowing under a
/// flood of requests.
const LINK_READ: usize = 1024 * 1024;
/// Output waits for the link to drain, up to this much, and then travels in
/// one frame: bigger frames the busier the daemon, none delayed while it
/// keeps up.
const OUTPUT_BATCH: usize = 256 * 1024;
/// Notifications kept for the next daemon, the latest ones.
const HELD_NOTIFICATIONS: usize = 16;
/// After output or input, the foreground process is looked at after each
/// of these delays: a program that starts without output is noticed too.
const FOREGROUND_CHECKS: [Duration; 3] = [
    Duration::from_millis(50),
    Duration::from_millis(250),
    Duration::from_millis(1000),
];

/// `cherry-host hold`: take the `Launch` on descriptor 3, start the session
/// and hold it until it has exited and been removed.
pub fn hold(socket: &Path) -> Result<()> {
    // Started as /proc/self/exe (see `session::holder_command`), whose name
    // the kernel would give it otherwise.
    #[cfg(target_os = "linux")]
    unsafe {
        libc::prctl(
            libc::PR_SET_NAME,
            c"cherry-host".as_ptr() as libc::c_ulong,
            0,
            0,
            0,
        );
    }
    let mut stream = unsafe { UnixStream::from_raw_fd(LINK_FD) };
    // Inherited without close-on-exec; the child must not get it.
    unsafe {
        libc::fcntl(LINK_FD, libc::F_SETFD, libc::FD_CLOEXEC);
    }
    stream.set_read_timeout(Some(LAUNCH_TIMEOUT))?;
    let frame = link::read_blocking(&mut stream)?
        .context("the daemon closed the link before launching a session")?;
    if frame.kind != kind::LAUNCH {
        bail!("expected a launch, not a link frame of kind {}", frame.kind);
    }
    let launch: link::Launch = frame.meta()?;
    let (cwd, env) = link::parse_launch_data(&frame.data)?;
    let holder = match Holder::start(socket, launch, &cwd, &env, stream.try_clone()?) {
        Ok(holder) => holder,
        Err(error) => {
            // The daemon answers the Create with it; nothing to log.
            let failed = link::encode(
                kind::FAILED,
                &link::Failed {
                    message: format!("{error:#}"),
                },
                &[],
            );
            let _ = link::write_blocking(&mut stream, &failed);
            std::process::exit(1);
        }
    };
    drop(stream);
    holder.run();
    Ok(())
}

fn size(cols: u16, rows: u16) -> PtySize {
    PtySize {
        cols,
        rows,
        pixel_width: 0,
        pixel_height: 0,
    }
}

/// Start the session's program on a new PTY. Returns the master and the
/// session leader.
fn spawn(
    command: &[String],
    cwd: &[u8],
    env: &[(Vec<u8>, Vec<u8>)],
    cols: u16,
    rows: u16,
) -> Result<(Box<dyn MasterPty + Send>, libc::pid_t)> {
    let pair = native_pty_system().openpty(size(cols, rows))?;
    let fd = pair
        .master
        .as_raw_fd()
        .context("PTY implementation has no Unix descriptor")?;
    // One thread does all I/O. Nonblocking writes keep a child that stops
    // reading its input from wedging output, termination or the link.
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        if flags < 0 || libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) < 0 {
            return Err(io::Error::last_os_error().into());
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
    let mut child = std::process::Command::new(&command[0]);
    child
        .args(&command[1..])
        .env_clear()
        .envs(
            env.iter()
                .map(|(key, value)| (OsStr::from_bytes(key), OsStr::from_bytes(value))),
        )
        .current_dir(OsStr::from_bytes(cwd))
        .stdin(slave.try_clone()?)
        .stdout(slave.try_clone()?)
        .stderr(slave);
    // The holder has one thread: nothing opens a descriptor above this one
    // before the fork.
    let fd_end = environment::open_fd_end();
    unsafe {
        child.pre_exec(move || {
            // Start from the dispositions a login would have, whatever the
            // holder inherited (a nohup'd starter ignores SIGHUP).
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
                return Err(io::Error::last_os_error());
            }
            if libc::ioctl(0, libc::TIOCSCTTY as _, 0) == -1 {
                return Err(io::Error::last_os_error());
            }
            // Only the terminal is inherited. The holder already has the
            // descriptor limit the user had (the daemon restored it). It
            // opens everything close-on-exec: this only makes sure.
            environment::cloexec_from_3_below(fd_end);
            Ok(())
        });
    }
    let child = child
        .spawn()
        .with_context(|| format!("launching {}", command[0]))?;
    Ok((pair.master, child.id() as libc::pid_t))
}

/// Bytes waiting for the PTY. Terminal replies (no lease) outlive
/// attachments. Input from an attachment is discarded when the daemon says
/// so (a takeover, an abnormal disconnect) and delivered after a detach.
/// Input the daemon sent is acknowledged once written or discarded
/// (`InputAck`), which is how the daemon applies backpressure.
#[derive(Default)]
struct PendingInput {
    chunks: VecDeque<InputChunk>,
    len: usize,
    user_len: usize,
}

struct InputChunk {
    lease: Option<u64>,
    user: bool,
    /// Acknowledged to the daemon when written or discarded.
    ack: bool,
    bytes: VecDeque<u8>,
}

/// Acknowledgements: bytes per lease.
type Acks = Vec<(Option<u64>, u64)>;

fn add_ack(acks: &mut Acks, lease: Option<u64>, bytes: usize) {
    if bytes == 0 {
        return;
    }
    match acks.last_mut() {
        Some((last, total)) if *last == lease => *total += bytes as u64,
        _ => acks.push((lease, bytes as u64)),
    }
}

impl PendingInput {
    fn push(&mut self, lease: Option<u64>, user: bool, ack: bool, bytes: &[u8]) {
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
            .filter(|chunk| chunk.lease == lease && chunk.user == user && chunk.ack == ack)
        {
            last.bytes.extend(bytes);
        } else {
            self.chunks.push_back(InputChunk {
                lease,
                user,
                ack,
                bytes: bytes.iter().copied().collect(),
            });
        }
    }

    /// Drop a lease's unsent input; returns the bytes to acknowledge.
    fn discard_lease(&mut self, lease: u64) -> usize {
        let mut removed = 0;
        let mut acked = 0;
        self.chunks.retain(|chunk| {
            if chunk.lease == Some(lease) {
                removed += chunk.bytes.len();
                if chunk.ack {
                    acked += chunk.bytes.len();
                }
                false
            } else {
                true
            }
        });
        self.len -= removed;
        self.user_len -= removed;
        acked
    }

    /// Keep a detached lease's input for delivery.
    fn keep_lease(&mut self, lease: u64) {
        for chunk in &mut self.chunks {
            if chunk.lease == Some(lease) {
                chunk.lease = None;
            }
        }
    }

    /// The daemon that sent the input is gone: its leases mean nothing to
    /// the next one, and nothing is acknowledged to it. The input is still
    /// delivered.
    fn forget_link(&mut self) {
        for chunk in &mut self.chunks {
            chunk.lease = None;
            chunk.ack = false;
        }
    }

    /// Drop everything; returns the bytes to acknowledge.
    fn clear(&mut self) -> Acks {
        let mut acks = Acks::new();
        for chunk in self.chunks.drain(..) {
            if chunk.ack {
                add_ack(&mut acks, chunk.lease, chunk.bytes.len());
            }
        }
        self.len = 0;
        self.user_len = 0;
        acks
    }

    /// Write as much as the PTY accepts; returns the bytes to acknowledge
    /// and whether any user input was written.
    fn write_to(&mut self, fd: libc::c_int) -> (Acks, bool) {
        let mut acks = Acks::new();
        let mut typed = false;
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
                typed = true;
            }
            if chunk.ack {
                add_ack(&mut acks, chunk.lease, n);
            }
            if !chunk.bytes.is_empty() {
                break;
            }
            self.chunks.pop_front();
        }
        (acks, typed)
    }
}

/// An explicit kill in progress: SIGHUP, then SIGTERM after the grace period,
/// then SIGKILL after another.
struct Termination {
    started: Instant,
    stage: u8,
}

/// The connection to a daemon.
struct Link {
    stream: UnixStream,
    reader: link::Reader,
    writer: link::Writer,
    since: Instant,
    /// Output not yet in a frame, and the offset it starts at.
    output: Vec<u8>,
    output_offset: u64,
    /// The events the hello carried, until the daemon has them: it sent a
    /// frame other than `REFUSED`, or the link lasted (see `disconnect`).
    offered: Vec<link::Event>,
    /// The daemon refused the hello, so it took none of them.
    turned_away: bool,
}

impl Link {
    /// Queue the output waiting to be sent as one frame.
    fn push_output(&mut self) {
        if self.output.is_empty() {
            return;
        }
        let frame = link::encode(
            kind::OUTPUT,
            &link::OutputMeta {
                offset: self.output_offset,
            },
            &self.output,
        );
        self.output.clear();
        self.writer.push(frame);
    }

    /// Bytes waiting for the daemon.
    fn waiting(&self) -> usize {
        self.writer.len() + self.output.len()
    }
}

/// What happened while no daemon was connected, for the next one, in
/// order: the latest `HELD_NOTIFICATIONS` notifications, and the latest
/// bell and progress report, each where it came.
#[derive(Default)]
struct Held {
    events: VecDeque<link::Event>,
}

impl Held {
    fn keep(&mut self, event: link::Event) {
        let same = std::mem::discriminant(&event);
        match event {
            link::Event::Notification { .. } => {
                let kept = self
                    .events
                    .iter()
                    .filter(|held| std::mem::discriminant(*held) == same)
                    .count();
                if kept >= HELD_NOTIFICATIONS {
                    let oldest = self
                        .events
                        .iter()
                        .position(|held| std::mem::discriminant(held) == same);
                    self.events.remove(oldest.expect("counted"));
                }
            }
            _ => self
                .events
                .retain(|held| std::mem::discriminant(held) != same),
        }
        self.events.push_back(event);
    }

    fn take(&mut self) -> Vec<link::Event> {
        self.events.drain(..).collect()
    }

    /// Keep again the events a daemon did not take, ahead of those kept
    /// since.
    fn restore(&mut self, events: Vec<link::Event>) {
        let since = std::mem::take(&mut self.events);
        for event in events.into_iter().chain(since) {
            self.keep(event);
        }
    }
}

/// The events among frames for the daemon that it never got.
fn unwritten_events(frames: Vec<Vec<u8>>) -> Vec<link::Event> {
    frames
        .into_iter()
        .filter(|frame| matches!(frame.get(4), Some(&kind::EVENT | &kind::EXITED)))
        .filter_map(|frame| link::decode(&frame[4..]).ok())
        .filter_map(|frame| match frame.kind {
            kind::EXITED => frame
                .meta::<link::Exited>()
                .ok()
                .map(|exited| link::Event::Exited {
                    exit_code: exited.exit_code,
                    signal: exited.signal,
                }),
            _ => frame.meta::<link::Event>().ok(),
        })
        .collect()
}

fn progress_name(state: ProgressState) -> &'static str {
    match state {
        ProgressState::Remove => "remove",
        ProgressState::Set => "set",
        ProgressState::Error => "error",
        ProgressState::Indeterminate => "indeterminate",
        ProgressState::Pause => "pause",
    }
}

struct Holder {
    id: String,
    socket: PathBuf,
    manifest: Option<PathBuf>,
    state: link::SessionState,
    receipt: Option<link::Receipt>,
    /// Closed once the session has exited, which hangs up the terminal.
    master: Option<Box<dyn MasterPty + Send>>,
    pid: libc::pid_t,
    terminal: Terminal,
    display: DisplayStream,
    osc99: Osc99,
    offset: u64,
    pending_input: PendingInput,
    eof: bool,
    termination: Option<Termination>,
    kill_grace: Duration,
    link: Option<Link>,
    /// When to dial the daemon again, and the delay after that.
    redial_at: Option<Instant>,
    backoff: Duration,
    /// After a change in the socket's directory: one quick retry.
    quick_redial: bool,
    /// The daemon at the socket refused it for good: dial again only when
    /// the socket's directory changes.
    refused: bool,
    /// Why, as last logged.
    refusal: Option<String>,
    watch: Option<DirWatch>,
    held: Held,
    /// Changes the daemon has not been told about.
    info: link::Info,
    /// Output waits for the daemon (`LINK_HIGH_WATER`).
    paused: bool,
    removed: bool,
    child_exits: UnixStream,
    /// The next look at the foreground process, and how many were due.
    foreground_due: Option<Instant>,
    foreground_step: usize,
}

impl Holder {
    fn start(
        socket: &Path,
        launch: link::Launch,
        cwd: &[u8],
        env: &[(Vec<u8>, Vec<u8>)],
        stream: UnixStream,
    ) -> Result<Self> {
        let link::Launch {
            id,
            name,
            command,
            cols,
            rows,
            owner,
            tags,
            created_at,
            state_dir,
            kill_grace_ms,
            receipt,
        } = launch;
        if !valid_size(cols, rows) {
            bail!("terminal size must be 2–500 columns and 1–200 rows");
        }
        if command.is_empty() {
            bail!("no command to launch");
        }
        let terminal = Terminal::new(cols, rows, screen::SCROLLBACK_BYTES)?;
        // Before the child exists, so its exit always wakes us.
        let child_exits = signals::child_exits().context("installing the child-exit handler")?;
        let (master, pid) = spawn(&command, cwd, env, cols, rows)?;
        let manifest = paths::Manifest {
            id: id.clone(),
            holder_pid: std::process::id(),
            created_at,
            link_version: link::LINK_VERSION,
            holder_started: processes::start_identity(unsafe { libc::getpid() }),
        };
        let manifest = match paths::write_manifest(Path::new(&state_dir), &manifest) {
            Ok(path) => Some(path),
            Err(error) => {
                log(format_args!(
                    "session {id}: cannot write its manifest ({error:#}); a restarted daemon will not wait for it"
                ));
                None
            }
        };
        stream.set_nonblocking(true)?;
        let mut holder = Self {
            id,
            socket: socket.to_path_buf(),
            manifest,
            state: link::SessionState {
                name,
                cwd: String::from_utf8_lossy(cwd).into_owned(),
                command,
                cols,
                rows,
                running: true,
                pid: Some(pid as u32),
                exit_code: None,
                exit_signal: None,
                title: None,
                pwd: None,
                foreground: None,
                owner,
                tags,
                created_at,
                alternate_screen: false,
                kitty_keyboard_flags: 0,
                application_cursor_keys: false,
            },
            receipt,
            master: Some(master),
            pid,
            terminal,
            display: DisplayStream::default(),
            osc99: Osc99::default(),
            offset: 0,
            pending_input: PendingInput::default(),
            eof: false,
            termination: None,
            kill_grace: Duration::from_millis(kill_grace_ms),
            link: None,
            redial_at: None,
            backoff: REDIAL_FIRST,
            quick_redial: false,
            refused: false,
            refusal: None,
            watch: None,
            held: Held::default(),
            info: link::Info::default(),
            paused: false,
            removed: false,
            child_exits,
            foreground_due: None,
            foreground_step: 0,
        };
        // The child may not have run its program yet: look again soon.
        holder.sample_foreground();
        holder.activity();
        holder.info = link::Info::default();
        holder.connect(stream);
        Ok(holder)
    }

    fn master_fd(&self) -> libc::c_int {
        self.master
            .as_ref()
            .and_then(|master| master.as_raw_fd())
            .unwrap_or(-1)
    }

    /// Queue a frame for the daemon, behind the output before it.
    fn send(&mut self, frame: Vec<u8>) {
        if let Some(link) = &mut self.link {
            link.push_output();
            link.writer.push(frame);
        }
    }

    /// Register with the daemon at the other end of `stream`.
    fn connect(&mut self, stream: UnixStream) {
        let offered = self.held.take();
        let hello = link::HolderHello {
            id: self.id.clone(),
            holder_pid: std::process::id(),
            session: self.state.clone(),
            offset: self.offset,
            receipt: self.receipt.clone(),
            events: offered
                .iter()
                .filter_map(|event| serde_json::to_value(event).ok())
                .collect(),
        };
        let mut writer = link::Writer::default();
        writer.push(link::encode(kind::HOLDER_HELLO, &hello, &[]));
        self.link = Some(Link {
            stream,
            reader: link::Reader::default(),
            writer,
            since: Instant::now(),
            output: Vec::new(),
            output_offset: self.offset,
            offered,
            turned_away: false,
        });
        // The hello carries the whole state.
        self.info = link::Info::default();
        self.watch = None;
        self.redial_at = None;
        self.quick_redial = false;
        self.refused = false;
    }

    /// The daemon went away: keep the session going and dial again, at
    /// once (a successor may be listening already), then with backoff. A
    /// link that did not last backs off from the start. The next daemon
    /// hears of the events this one never got: those not written to the
    /// link in full, and those the hello carried unless the daemon said it
    /// had them (a daemon that fails within moments of taking them may be
    /// told them twice). Those written but not read yet are gone with it.
    fn disconnect(&mut self) {
        let Some(mut link) = self.link.take() else {
            return;
        };
        let lasted = link.since.elapsed() >= REDIAL_MAX;
        let unwritten = link.writer.take_unwritten();
        // A daemon that never got the hello (the first frame) took nothing.
        let hello_unwritten = unwritten
            .first()
            .is_some_and(|frame| frame.get(4) == Some(&kind::HOLDER_HELLO));
        let mut untaken = std::mem::take(&mut link.offered);
        if lasted && !link.turned_away && !hello_unwritten {
            untaken.clear();
        }
        untaken.extend(unwritten_events(unwritten));
        drop(link);
        self.held.restore(untaken);
        self.info = link::Info::default();
        self.pending_input.forget_link();
        self.paused = false;
        self.watch = self.socket.parent().and_then(DirWatch::new);
        if lasted && !self.refused {
            self.backoff = REDIAL_FIRST;
            self.redial_at = Some(Instant::now());
        } else {
            self.schedule_redial();
        }
    }

    /// When to dial next. Only a timer can find a daemon while the socket's
    /// directory is not watched (it may not exist yet), so then the timer
    /// runs more often.
    fn schedule_redial(&mut self) {
        if self.watch.is_none() {
            self.watch = self.socket.parent().and_then(DirWatch::new);
        }
        let quick = std::mem::take(&mut self.quick_redial);
        let (delay, backoff) =
            redial_delay(self.backoff, self.watch.is_some(), quick, self.refused);
        self.backoff = backoff;
        self.redial_at = delay.map(|delay| Instant::now() + delay);
    }

    /// The daemon will not serve this holder. For good: only another daemon
    /// binding the socket may; otherwise it dials again with backoff.
    fn refused(&mut self, refused: link::Refused) {
        if !refused.retry {
            if self.refusal.as_ref() != Some(&refused.reason) {
                log(format_args!(
                    "session {}: the host at {} refused it ({}); waiting for another host",
                    self.id,
                    self.socket.display(),
                    refused.reason
                ));
            }
            self.refusal = Some(refused.reason);
            self.refused = true;
        }
        if let Some(link) = &mut self.link {
            link.turned_away = true;
        }
        self.disconnect();
    }

    fn redial(&mut self) {
        self.redial_at = None;
        match dial(&self.socket) {
            Ok(stream) => self.connect(stream),
            Err(_) => self.schedule_redial(),
        }
    }

    fn send_acks(&mut self, acks: Acks) {
        for (lease, bytes) in acks {
            self.send(link::encode(
                kind::INPUT_ACK,
                &link::InputAck { lease, bytes },
                &[],
            ));
        }
    }

    fn event(&mut self, event: link::Event) {
        if self.link.is_some() {
            // The event object is the meta.
            self.send(link::encode(kind::EVENT, &event, &[]));
        } else {
            self.held.keep(event);
        }
    }

    fn vt_event(&mut self, event: VtEvent) {
        match event {
            VtEvent::Title(title) => {
                let title = (!title.is_empty()).then_some(title);
                if self.state.title != title {
                    self.state.title = title.clone();
                    self.info.title = Some(title);
                }
            }
            VtEvent::Pwd(pwd) => {
                let pwd = (!pwd.is_empty()).then_some(pwd);
                if self.state.pwd != pwd {
                    self.state.pwd = pwd.clone();
                    self.info.pwd = Some(pwd);
                }
            }
            VtEvent::Bell => self.event(link::Event::Bell),
            VtEvent::Notification { title, body } => {
                self.event(link::Event::Notification { title, body })
            }
            VtEvent::Progress { state, value } => self.event(link::Event::Progress {
                state: progress_name(state).into(),
                value,
            }),
        }
    }

    fn queue_replies(&mut self, replies: &[u8]) {
        let queued = self.pending_input.len - self.pending_input.user_len;
        if queued + replies.len() <= MAX_PENDING_REPLIES {
            self.pending_input.push(None, false, false, replies);
        }
    }

    /// Read available output; false once the PTY reports end of file.
    fn read_output(&mut self) -> bool {
        let fd = self.master_fd();
        let mut buf = [0u8; 16384];
        let mut output = Batch::default();
        let mut open = true;
        // Only an escape sequence can switch screens or change the kitty
        // keyboard flags or DECCKM, and the terminal gets only whole ones.
        let mut escaped = false;
        // Bounded work per wake gives input, requests and termination a
        // turn under output floods. One frame carries the whole burst.
        let mut reads = 0;
        while reads < 16 {
            let n = unsafe { libc::read(fd, buf.as_mut_ptr().cast(), buf.len()) };
            if n < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                open = error.kind() == io::ErrorKind::WouldBlock;
                break;
            }
            if n == 0 {
                open = false;
                break;
            }
            reads += 1;
            let mut batch = self.display.feed(&buf[..n as usize]);
            // Kitty notifications, which the terminal does not report, in
            // order with what it does.
            let terminal = std::mem::take(&mut batch.terminal);
            escaped |= terminal.contains(&0x1b);
            let mut at = 0;
            for (position, sequence) in std::mem::take(&mut batch.notifications) {
                self.feed_terminal(&terminal[at..position]);
                at = position;
                if let Some(VtEvent::Notification { title, body }) = self.osc99.feed(&sequence) {
                    self.event(link::Event::Notification { title, body });
                }
            }
            self.feed_terminal(&terminal[at..]);
            output.append(batch);
        }
        if escaped {
            self.check_terminal_state();
        }
        if reads > 0 {
            self.emit(output);
            self.activity();
        }
        open
    }

    /// Whether the alternate screen shows, the kitty keyboard flags and
    /// application cursor keys: the daemon is told when they change.
    fn check_terminal_state(&mut self) {
        let Some(now) = screen::terminal_state(&self.terminal) else {
            return;
        };
        if self.state.alternate_screen != now.alternate_screen {
            self.state.alternate_screen = now.alternate_screen;
            self.info.alternate_screen = Some(now.alternate_screen);
        }
        if self.state.kitty_keyboard_flags != now.kitty_keyboard_flags {
            self.state.kitty_keyboard_flags = now.kitty_keyboard_flags;
            self.info.kitty_keyboard_flags = Some(now.kitty_keyboard_flags);
        }
        if self.state.application_cursor_keys != now.application_cursor_keys {
            self.state.application_cursor_keys = now.application_cursor_keys;
            self.info.application_cursor_keys = Some(now.application_cursor_keys);
        }
    }

    /// Output for the terminal: its replies wait for the program, and what
    /// it reports is taken as it comes.
    fn feed_terminal(&mut self, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        let replies = self.terminal.feed(bytes);
        self.queue_replies(&replies);
        for event in self.terminal.take_events() {
            self.vt_event(event);
        }
    }

    /// Renderer output and the queries in it, in order. Without a daemon
    /// the output only advances the offset, and queries are dropped, as
    /// they are while nobody is attached.
    fn emit(&mut self, output: Batch) {
        let Batch {
            display, queries, ..
        } = output;
        let mut at = 0;
        for (position, query) in queries {
            if position > at {
                self.emit_output(&display[at..position]);
                at = position;
            }
            self.send(link::encode(kind::QUERY, &link::Empty {}, &query));
        }
        if at < display.len() {
            self.emit_output(&display[at..]);
        }
    }

    fn emit_output(&mut self, data: &[u8]) {
        let offset = self.offset;
        self.offset += data.len() as u64;
        if let Some(link) = &mut self.link {
            if link.output.is_empty() {
                link.output_offset = offset;
            }
            link.output.extend_from_slice(data);
            if link.output.len() >= OUTPUT_BATCH {
                link.push_output();
            }
        }
    }

    /// Output or input: the foreground process may change.
    fn activity(&mut self) {
        self.foreground_step = 0;
        if self.foreground_due.is_none() {
            self.foreground_due = Some(Instant::now() + FOREGROUND_CHECKS[0]);
        }
    }

    fn check_foreground(&mut self) {
        let Some(due) = self.foreground_due else {
            return;
        };
        let now = Instant::now();
        if now < due {
            return;
        }
        self.sample_foreground();
        self.foreground_step += 1;
        self.foreground_due = FOREGROUND_CHECKS
            .get(self.foreground_step)
            .map(|delay| now + *delay);
    }

    /// The terminal's foreground process group and its leader's name.
    fn sample_foreground(&mut self) {
        let group = self
            .master
            .as_ref()
            .filter(|_| self.state.running)
            .and_then(|master| master.process_group_leader())
            .filter(|&group| group > 0);
        let foreground = group.map(|group| link::Foreground {
            pid: group as u32,
            name: processes::process_name(group),
        });
        if foreground != self.state.foreground {
            self.state.foreground = foreground.clone();
            self.info.foreground = Some(foreground);
        }
    }

    fn resize(&mut self, cols: u16, rows: u16) {
        if !self.state.running
            || !valid_size(cols, rows)
            || (self.state.cols, self.state.rows) == (cols, rows)
        {
            return;
        }
        let replies = match self.terminal.resize(cols, rows) {
            Ok(replies) => replies,
            Err(error) => {
                log(format_args!(
                    "session {}: resize failed: {error:#}",
                    self.id
                ));
                return;
            }
        };
        if let Some(master) = &self.master {
            if let Err(error) = master.resize(size(cols, rows)) {
                log(format_args!(
                    "session {}: resizing the terminal failed: {error:#}",
                    self.id
                ));
            }
        }
        self.queue_replies(&replies);
        self.state.cols = cols;
        self.state.rows = rows;
        self.info.cols = Some(cols);
        self.info.rows = Some(rows);
    }

    /// The terminal as a renderer stream: the whole of it, limited to `max`
    /// bytes (oldest history dropped), or its screens without history.
    fn snapshot(&self, request: &link::SnapshotRequest) -> Result<Vec<u8>> {
        let raw = match request.kind.as_str() {
            "full" => self.terminal.snapshot()?,
            "limited" => self
                .terminal
                .snapshot_limited(request.max.unwrap_or(MAX_SNAPSHOT_BYTES))?,
            "refresh" => {
                let raw = self.terminal.refresh()?;
                if raw.len() > MAX_SNAPSHOT_BYTES {
                    bail!(
                        "the screen needs a {}-byte refresh; the limit is {MAX_SNAPSHOT_BYTES} bytes",
                        raw.len()
                    );
                }
                raw
            }
            other => bail!("unknown snapshot kind {other:?}"),
        };
        let display = DisplayStream::default().feed(&raw).display;
        if display.len() > link::MAX_FRAME - 64 * 1024 {
            bail!("the snapshot exceeds the link's frame limit");
        }
        Ok(display)
    }

    /// The screen as text (see `screen::read`).
    fn screen(&self, request: &link::ScreenRequest) -> Result<screen::ScreenText> {
        screen::read(
            &self.terminal,
            self.state.cols,
            self.state.rows,
            request.scrollback,
            request.max_lines,
        )
    }

    fn handle(&mut self, frame: Frame) {
        if frame.kind != kind::REFUSED {
            // Only a daemon that took the hello sends anything else.
            if let Some(link) = &mut self.link {
                link.offered.clear();
            }
        }
        match frame.kind {
            kind::INPUT => {
                let Ok(meta) = frame.meta::<link::InputMeta>() else {
                    return;
                };
                if self.eof {
                    self.send_acks(vec![(meta.lease, frame.data.len() as u64)]);
                } else {
                    self.pending_input.push(meta.lease, true, true, &frame.data);
                }
            }
            kind::DISCARD_LEASE => {
                if let Ok(meta) = frame.meta::<link::Lease>() {
                    let discarded = self.pending_input.discard_lease(meta.lease);
                    self.send_acks(vec![(Some(meta.lease), discarded as u64)]);
                }
            }
            kind::DETACH => {
                if let Ok(meta) = frame.meta::<link::DetachMeta>() {
                    self.pending_input.keep_lease(meta.lease);
                    self.send(link::encode(
                        kind::DETACH_DONE,
                        &link::Req { req: meta.req },
                        &[],
                    ));
                }
            }
            kind::RESIZE => {
                if let Ok(size) = frame.meta::<link::Size>() {
                    self.resize(size.cols, size.rows);
                }
            }
            kind::SNAPSHOT => {
                let Ok(request) = frame.meta::<link::SnapshotRequest>() else {
                    return;
                };
                let (bytes, error) = match self.snapshot(&request) {
                    Ok(bytes) => (bytes, None),
                    Err(error) => (Vec::new(), Some(format!("{error:#}"))),
                };
                let reply = link::SnapshotReply {
                    req: request.req,
                    kind: request.kind,
                    offset: self.offset,
                    cols: self.state.cols,
                    rows: self.state.rows,
                    error,
                };
                self.send(link::encode(kind::SNAPSHOT_REPLY, &reply, &bytes));
            }
            kind::SCREEN => {
                let Ok(request) = frame.meta::<link::ScreenRequest>() else {
                    return;
                };
                let frame = match self.screen(&request) {
                    Ok(screen) => link::encode(
                        kind::SCREEN_REPLY,
                        &link::ScreenReply {
                            req: request.req,
                            cursor_row: screen.cursor_row,
                            cursor_col: screen.cursor_col,
                            alternate_screen: screen.alternate_screen,
                            error: None,
                        },
                        screen.text.as_bytes(),
                    ),
                    Err(error) => link::encode(
                        kind::SCREEN_REPLY,
                        &link::ScreenReply {
                            req: request.req,
                            cursor_row: 0,
                            cursor_col: 0,
                            alternate_screen: false,
                            error: Some(format!("{error:#}")),
                        },
                        &[],
                    ),
                };
                self.send(frame);
            }
            kind::UPDATE => {
                if let Ok(update) = frame.meta::<link::Update>() {
                    if let Some(name) = update.name {
                        self.state.name = name;
                    }
                    if let Some(tags) = update.tags {
                        self.state.tags = tags;
                    }
                }
            }
            kind::KILL if self.state.running && self.termination.is_none() => {
                self.begin_termination();
            }
            kind::REMOVE => self.removed = true,
            kind::REFUSED => self.refused(frame.meta().unwrap_or(link::Refused {
                reason: "no reason given".into(),
                retry: true,
            })),
            // Launch only starts a holder; other kinds are for daemons, or
            // from a newer daemon.
            _ => {}
        }
    }

    /// Take what the daemon sent.
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
                Ok(Some(frame)) => self.handle(frame),
                Ok(None) => break,
                Err(error) => {
                    log(format_args!("session {}: {error:#}", self.id));
                    self.disconnect();
                    return;
                }
            }
        }
        if !open {
            self.disconnect();
        }
    }

    fn flush_link(&mut self) {
        if !self.info.is_empty() && self.link.is_some() {
            let info = std::mem::take(&mut self.info);
            self.send(link::encode(kind::INFO, &info, &[]));
        }
        let Some(link) = &mut self.link else {
            self.info = link::Info::default();
            return;
        };
        // Output goes as soon as the link has room; until then it gathers.
        if link.writer.is_empty() {
            link.push_output();
        }
        let mut flushed = link.writer.flush(link.stream.as_raw_fd());
        if flushed && link.writer.is_empty() && !link.output.is_empty() {
            link.push_output();
            flushed = link.writer.flush(link.stream.as_raw_fd());
        }
        if !flushed {
            self.disconnect();
            return;
        }
        let waiting = link.waiting();
        if waiting > LINK_HIGH_WATER {
            self.paused = true;
        } else if waiting <= LINK_LOW_WATER {
            self.paused = false;
        }
    }

    fn begin_termination(&mut self) {
        processes::signal_session(self.pid, libc::SIGHUP);
        self.termination = Some(Termination {
            started: Instant::now(),
            stage: 0,
        });
    }

    /// Advance an explicit kill, or notice a natural exit.
    fn check_exit(&mut self) {
        let leader_exited = processes::exited(self.pid);
        if let Some(termination) = &mut self.termination {
            // The exited leader stays unreaped until the sweep is over, so its
            // session ID cannot be reused by an unrelated process meanwhile.
            let survivors = processes::live_members(self.pid);
            if leader_exited && (survivors.is_empty() || termination.stage >= 2) {
                self.finish();
                return;
            }
            let grace = self.kill_grace;
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
            return;
        }
        // A natural exit is a hangup, as in any terminal: the master closes
        // and the kernel signals the foreground job. Jobs that ignore SIGHUP
        // (nohup, disown) keep running.
        if leader_exited {
            self.finish();
        }
    }

    fn finish(&mut self) {
        // Never blocks this, the session's only thread: a leader that has
        // not exited after all is looked at again at its next wakeup (its
        // exit sends SIGCHLD).
        let Some(status) = processes::reap(self.pid) else {
            return;
        };
        // Bytes written before exit are part of the transcript.
        if !self.eof {
            self.read_output();
        }
        self.termination = None;
        self.eof = true;
        let acks = self.pending_input.clear();
        self.send_acks(acks);
        // Closing the master hangs up the terminal. The screen stays, for
        // snapshots until the session is removed.
        self.master = None;
        self.state.running = false;
        self.state.exit_code = Some(status.code);
        self.state.exit_signal = status.signal;
        self.sample_foreground();
        self.foreground_due = None;
        // The last changes, then the exit, after the last output.
        if !self.info.is_empty() && self.link.is_some() {
            let info = std::mem::take(&mut self.info);
            self.send(link::encode(kind::INFO, &info, &[]));
        }
        if self.link.is_some() {
            self.send(link::encode(
                kind::EXITED,
                &link::Exited {
                    exit_code: status.code,
                    signal: status.signal,
                },
                &[],
            ));
        } else {
            // The next daemon hears of it, after what happened before it.
            self.held.keep(link::Event::Exited {
                exit_code: status.code,
                signal: status.signal,
            });
        }
    }

    fn write_input(&mut self) {
        if self.eof {
            let acks = self.pending_input.clear();
            self.send_acks(acks);
            return;
        }
        if self.pending_input.len == 0 {
            return;
        }
        let (acks, typed) = self.pending_input.write_to(self.master_fd());
        self.send_acks(acks);
        if typed {
            self.activity();
        }
    }

    /// Nobody can find this exited session again: its manifest, and so the
    /// host's state, was removed while no daemon was connected.
    fn orphaned(&self) -> bool {
        !self.state.running
            && self.link.is_none()
            && self
                .manifest
                .as_ref()
                .is_some_and(|manifest| !manifest.exists())
    }

    fn next_wait(&self) -> Duration {
        let now = Instant::now();
        let mut wait = IDLE_WAIT;
        if self.termination.is_some() {
            wait = wait.min(TERMINATION_POLL);
        }
        for due in [self.redial_at, self.foreground_due].into_iter().flatten() {
            wait = wait.min(due.saturating_duration_since(now));
        }
        wait
    }

    fn run(mut self) {
        loop {
            self.pump_link();
            if !self.eof && !self.paused {
                self.eof = !self.read_output();
            }
            if self.state.running {
                self.check_exit();
            }
            self.write_input();
            self.check_foreground();
            self.flush_link();
            if !self.state.running && self.removed {
                break;
            }
            if !self.state.running && self.refused {
                log(format_args!(
                    "session {}: it has exited and no host serves it; exiting",
                    self.id
                ));
                break;
            }
            if self.orphaned() {
                log(format_args!(
                    "session {}: its manifest is gone; exiting",
                    self.id
                ));
                break;
            }
            if self.link.is_none() && self.redial_at.is_some_and(|at| Instant::now() >= at) {
                self.redial();
                continue;
            }
            self.wait();
        }
        if let Some(manifest) = &self.manifest {
            let _ = std::fs::remove_file(manifest);
        }
        // Whatever is still queued (nothing, normally) goes with the process.
        if let Some(link) = &mut self.link {
            link.push_output();
            link.writer
                .flush_all(link.stream.as_raw_fd(), Duration::from_secs(1));
        }
    }

    fn wait(&mut self) {
        let master = if self.eof || self.master.is_none() {
            -1
        } else {
            self.master_fd()
        };
        let mut master_events = 0;
        if !self.paused {
            master_events |= libc::POLLIN;
        }
        if self.pending_input.len > 0 {
            master_events |= libc::POLLOUT;
        }
        let (link_fd, link_events) = match &self.link {
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
        let watch_fd = self.watch.as_ref().map_or(-1, DirWatch::fd);
        let mut poll = [
            libc::pollfd {
                fd: if master_events == 0 { -1 } else { master },
                events: master_events,
                revents: 0,
            },
            libc::pollfd {
                fd: link_fd,
                events: link_events,
                revents: 0,
            },
            libc::pollfd {
                fd: self.child_exits.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: watch_fd,
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        let wait = self.next_wait();
        let millis = wait.as_micros().div_ceil(1000).min(i32::MAX as u128) as libc::c_int;
        unsafe {
            libc::poll(poll.as_mut_ptr(), poll.len() as libc::nfds_t, millis);
        }
        signals::drain(&self.child_exits);
        if poll[3].revents != 0 {
            // Watch afresh: the directory may have been replaced. Whatever
            // changed before the new watch, the dial below finds.
            self.watch = self.socket.parent().and_then(DirWatch::new);
            if self.link.is_none() {
                // A daemon may have bound its socket: dial now, and once
                // more soon if it is not listening yet.
                self.redial_at = Some(Instant::now());
                self.quick_redial = true;
                self.refused = false;
            }
        }
    }
}

/// How long to wait before dialing again (None: only when the socket's
/// directory changes), and the backoff after that, from the backoff so
/// far; whether the directory is `watched`; whether a change in it asks
/// for a `quick` retry; and whether the daemon `refused` the holder for
/// good. Without a watch only the timer can find a daemon, so the delay
/// never exceeds `REDIAL_MAX` then, however long the backoff grew while the
/// directory was watched (it may have gone since).
fn redial_delay(
    backoff: Duration,
    watched: bool,
    quick: bool,
    refused: bool,
) -> (Option<Duration>, Duration) {
    let max = if watched {
        REDIAL_WATCHED_MAX
    } else {
        REDIAL_MAX
    };
    if quick {
        (Some(REDIAL_SOON), backoff)
    } else if refused {
        ((!watched).then_some(REDIAL_WATCHED_MAX), backoff)
    } else {
        let delay = backoff.min(max);
        (Some(delay), (delay * 2).min(max))
    }
}

/// Connect to the daemon without blocking: a daemon whose backlog is full
/// is dialed again later rather than stalling the session.
fn dial(socket: &Path) -> io::Result<UnixStream> {
    cherry_protocol::verify_socket_path(socket)?;
    let path = socket.as_os_str().as_bytes();
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if path.len() >= address.sun_path.len() {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    address.sun_family = libc::AF_UNIX as _;
    for (slot, byte) in address.sun_path.iter_mut().zip(path) {
        *slot = *byte as libc::c_char;
    }
    let length = std::mem::size_of::<libc::sockaddr_un>() as libc::socklen_t;
    #[cfg(target_os = "macos")]
    {
        address.sun_len = length as u8;
    }
    let fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let stream = unsafe { UnixStream::from_raw_fd(fd) };
    unsafe {
        libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
        let flags = libc::fcntl(fd, libc::F_GETFL);
        libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
        if libc::connect(fd, (&address as *const libc::sockaddr_un).cast(), length) != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    cherry_protocol::verify_peer(&stream)?;
    Ok(stream)
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
        pending.push(Some(1), true, true, b"old command");
        pending.push(None, false, false, b"\x1b[1;1R");
        pending.push(Some(1), true, true, b"old remainder");
        pending.push(Some(2), true, true, b"new command");
        assert_eq!(pending.discard_lease(1), 24);
        assert_eq!(bytes(&pending), b"\x1b[1;1Rnew command");
        assert_eq!(pending.len, bytes(&pending).len());
        assert_eq!(pending.user_len, 11);
    }

    #[test]
    fn detached_input_is_kept_for_delivery() {
        let mut pending = PendingInput::default();
        pending.push(Some(1), true, true, b"echo marker\r");
        pending.keep_lease(1);
        assert_eq!(pending.discard_lease(1), 0);
        assert_eq!(bytes(&pending), b"echo marker\r");
        assert_eq!(pending.clear(), vec![(None, 12)]);
    }

    #[test]
    fn input_is_acknowledged_per_lease_as_written_and_not_to_a_later_daemon() {
        let (reader, writer) = UnixStream::pair().unwrap();
        let mut pending = PendingInput::default();
        pending.push(Some(1), true, true, b"ab");
        pending.push(None, false, false, b"\x1b[0n");
        pending.push(Some(1), true, true, b"c");
        pending.push(None, true, true, b"de");
        let (acks, typed) = pending.write_to(writer.as_raw_fd());
        assert!(typed);
        assert_eq!(acks, vec![(Some(1), 3), (None, 2)]);
        pending.push(Some(4), true, true, b"old daemon");
        pending.forget_link();
        assert_eq!(pending.discard_lease(4), 0);
        let (acks, _) = pending.write_to(writer.as_raw_fd());
        assert!(acks.is_empty());
        drop(writer);
        let mut all = Vec::new();
        io::Read::read_to_end(&mut &reader, &mut all).unwrap();
        assert_eq!(all, b"ab\x1b[0ncdeold daemon");
    }

    #[test]
    fn the_redial_delay_backs_off_and_never_exceeds_the_unwatched_limit_without_a_watch() {
        // Backing off while the socket's directory is watched...
        let mut backoff = REDIAL_FIRST;
        let mut delays = Vec::new();
        for _ in 0..10 {
            let (delay, next) = redial_delay(backoff, true, false, false);
            delays.push(delay.unwrap());
            backoff = next;
        }
        assert_eq!(delays[0], REDIAL_FIRST);
        assert_eq!(delays[1], REDIAL_FIRST * 2);
        assert_eq!(*delays.last().unwrap(), REDIAL_WATCHED_MAX);
        assert_eq!(backoff, REDIAL_WATCHED_MAX);
        // ...then the directory goes, and with it the watch: only the
        // timer can find a daemon now, at most REDIAL_MAX apart.
        let (delay, next) = redial_delay(backoff, false, false, false);
        assert_eq!(delay, Some(REDIAL_MAX));
        assert_eq!(next, REDIAL_MAX);
        let (delay, _) = redial_delay(next, false, false, false);
        assert_eq!(delay, Some(REDIAL_MAX));
        // A change in the directory: a quick retry, the backoff kept.
        assert_eq!(
            redial_delay(REDIAL_MAX, true, true, false),
            (Some(REDIAL_SOON), REDIAL_MAX)
        );
        // Refused for good: only a change in a watched directory dials,
        // or a slow timer without a watch.
        assert_eq!(
            redial_delay(REDIAL_FIRST, true, false, true),
            (None, REDIAL_FIRST)
        );
        assert_eq!(
            redial_delay(REDIAL_FIRST, false, false, true),
            (Some(REDIAL_WATCHED_MAX), REDIAL_FIRST)
        );
    }

    #[test]
    fn held_events_keep_their_order() {
        let mut held = Held::default();
        let notification = |body: &str| link::Event::Notification {
            title: String::new(),
            body: body.into(),
        };
        held.keep(link::Event::Bell);
        held.keep(notification("one"));
        held.keep(link::Event::Progress {
            state: "set".into(),
            value: Some(1),
        });
        held.keep(notification("two"));
        held.keep(link::Event::Exited {
            exit_code: 3,
            signal: None,
        });
        assert_eq!(
            kinds(held.take()),
            ["bell", "notification", "progress", "notification", "exited"]
        );
    }

    fn kinds(events: Vec<link::Event>) -> Vec<String> {
        events
            .iter()
            .map(|event| serde_json::to_value(event).unwrap()["kind"].to_string())
            .map(|kind| kind.trim_matches('"').to_string())
            .collect()
    }

    #[test]
    fn events_never_written_to_a_gone_daemon_are_found_again() {
        let mut writer = link::Writer::default();
        writer.push(link::encode(
            kind::OUTPUT,
            &link::OutputMeta { offset: 0 },
            b"\x07",
        ));
        writer.push(link::encode(kind::EVENT, &link::Event::Bell, &[]));
        writer.push(link::encode(kind::INFO, &link::Info::default(), &[]));
        writer.push(link::encode(
            kind::EVENT,
            &link::Event::Notification {
                title: String::new(),
                body: "done".into(),
            },
            &[],
        ));
        writer.push(link::encode(
            kind::EXITED,
            &link::Exited {
                exit_code: 3,
                signal: None,
            },
            &[],
        ));
        assert_eq!(
            unwritten_events(writer.take_unwritten()),
            [
                link::Event::Bell,
                link::Event::Notification {
                    title: String::new(),
                    body: "done".into(),
                },
                link::Event::Exited {
                    exit_code: 3,
                    signal: None,
                },
            ]
        );
        assert!(writer.is_empty());
        assert_eq!(writer.len(), 0);
    }

    #[test]
    fn events_a_daemon_did_not_take_are_kept_ahead_of_newer_ones() {
        let mut held = Held::default();
        let notification = |body: String| link::Event::Notification {
            title: String::new(),
            body,
        };
        held.keep(link::Event::Bell);
        held.keep(notification("offered".into()));
        let offered = held.take();
        held.keep(link::Event::Progress {
            state: "set".into(),
            value: Some(1),
        });
        held.keep(link::Event::Bell);
        held.restore(offered.clone());
        assert_eq!(kinds(held.take()), ["notification", "progress", "bell"]);
        // Within the same bounds: the offered notification is the oldest.
        for n in 0..HELD_NOTIFICATIONS {
            held.keep(notification(n.to_string()));
        }
        held.restore(offered);
        let events = held.take();
        assert_eq!(events.len(), HELD_NOTIFICATIONS + 1);
        assert_eq!(events[0], link::Event::Bell);
        assert_eq!(events[1], notification("0".into()));
    }

    #[test]
    fn held_events_are_bounded_and_keep_the_latest_state() {
        let mut held = Held::default();
        for n in 0..40 {
            held.keep(link::Event::Notification {
                title: String::new(),
                body: n.to_string(),
            });
            held.keep(link::Event::Bell);
            held.keep(link::Event::Progress {
                state: "set".into(),
                value: Some(n),
            });
        }
        let events = serde_json::to_value(held.take()).unwrap();
        assert_eq!(events.as_array().unwrap().len(), HELD_NOTIFICATIONS + 2);
        assert_eq!(events[0]["body"], "24");
        assert_eq!(events[HELD_NOTIFICATIONS]["kind"], "bell");
        assert_eq!(events[HELD_NOTIFICATIONS + 1]["value"], 39);
        assert!(held.take().is_empty());
    }
}
