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
    daemon::{self, log, utc_timestamp},
    environment,
    link::{self, kind, Frame},
    media::{self, Media},
    paths, processes, screen, signals,
    stream::{Batch, DisplayStream},
    terminal_thread::{Report, TerminalThread},
    watch::DirWatch,
};
use anyhow::{bail, Context, Result};
use cherry_protocol::{priority, valid_size, MAX_SNAPSHOT_BYTES, MAX_SNAPSHOT_GRAPHICS_BYTES};
use cherry_vt::{GraphicsReplay, ProgressState, Terminal, VtEvent};
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
    sync::OnceLock,
    time::{Duration, Instant, SystemTime},
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
/// until it drains to the low mark: a program cannot outrun the daemon. (The
/// session's clients, when all of them take their output slowly, hold the
/// program back to the fastest one's pace through `link::Pace`, see
/// `session::Worker::pace`.)
const LINK_HIGH_WATER: usize = 1024 * 1024;
const LINK_LOW_WATER: usize = 256 * 1024;
/// Bytes taken from the link per pass, so output keeps flowing under a
/// flood of requests.
const LINK_READ: usize = 1024 * 1024;
/// PTY reads per pass, of at most this many bytes each (macOS returns at
/// most 1 KiB per read, Linux up to the buffer's size).
const READS_PER_PASS: usize = 16;
const READ_BYTES: usize = 16 * 1024;

/// What a poll found ready (see `Holder::run`).
#[derive(Clone, Copy)]
struct Ready {
    /// The PTY's output (or its end).
    master: bool,
    /// Frames from the daemon (or the link's end).
    link: bool,
    /// A child exited (`child_exits`).
    child: bool,
}

impl Ready {
    const ALL: Self = Self {
        master: true,
        link: true,
        child: true,
    };
}
/// Requests that take work (a snapshot, the screen as text) served per
/// pass: output read meanwhile goes out before the next one.
const COSTLY_PER_PASS: usize = 1;
/// Output waits for the link to drain, up to this much, and then travels in
/// one frame: bigger frames the busier the daemon, none delayed while it
/// keeps up.
const OUTPUT_BATCH: usize = 256 * 1024;
/// Output gathers up to this much while more of it is ready at once, or
/// for up to `FLOOD_DELAY` during a flood (see `Holder::flush_link`).
const GATHER_BYTES: usize = 64 * 1024;
/// Output that has come without a pause of `FLOOD_PAUSE` for `FLOOD_AFTER`
/// is a flood (see `Holder::flooding`).
const FLOOD_AFTER: Duration = Duration::from_millis(10);
const FLOOD_PAUSE: Duration = Duration::from_millis(1);
const FLOOD_DELAY: Duration = Duration::from_millis(1);
/// During a flood a read that finds nothing is tried again this many times
/// at most, yielding in between, before the holder polls (see
/// `Holder::read_output`).
const FLOOD_RETRIES: usize = 64;
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
    install_panic_hook();
    // Its stderr is the daemon's log when `cherry-host start` started the
    // daemon: its lines follow that log when the daemon moves it aside.
    if let Ok(state) = paths::state_dir(socket) {
        let log_file = state.join("host.log");
        if daemon::writes_to_log(&log_file, libc::STDERR_FILENO) {
            daemon::follow_log_file(log_file);
        }
    }
    // Its threads (its loop and its terminal's, see `terminal_thread`) run
    // at interactive priority while a client is attached
    // (`link::Attended`), and at the default class otherwise; the program it
    // starts is not affected.
    priority::prepare_process();
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
    let _ = SESSION.set(launch.id.clone());
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

/// The session this holder holds, once its launch was read: for its panic
/// report.
static SESSION: OnceLock<String> = OnceLock::new();

/// Log a panic of this holder (to its stderr, the daemon's log when a
/// `cherry-host start` started the daemon) with when it happened, the
/// session and the build, then report it as Rust does. The daemon then
/// reports the session as ended by `holder_lost`.
fn install_panic_hook() {
    let default = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        log(panic_report(
            SESSION.get().map(String::as_str),
            SystemTime::now(),
            &info.to_string(),
        ));
        default(info);
    }));
}

/// The line a holder's panic hook logs.
fn panic_report(session: Option<&str>, at: SystemTime, panic: &str) -> String {
    let executable = std::env::current_exe()
        .map(|path| path.display().to_string())
        .unwrap_or_else(|_| "?".into());
    format!(
        "holder of session {} (pid {}) panicked at {}; build cherry-host {} (link {}, protocol {}, {executable}): {panic}",
        session.unwrap_or("(not launched yet)"),
        std::process::id(),
        utc_timestamp(at),
        cherry_protocol::VERSION,
        link::LINK_VERSION,
        cherry_protocol::PROTOCOL_VERSION,
    )
}

/// The PTY's size: its pixels are the grid's in cells of `cell` pixels, or
/// 0×0 while neither the Create nor a client gave a cell size.
fn size(cols: u16, rows: u16, cell: Option<(u32, u32)>) -> PtySize {
    let (width, height) = cell.unwrap_or((0, 0));
    let pixels = |cells: u16, side: u32| u16::try_from(u32::from(cells) * side).unwrap_or(u16::MAX);
    PtySize {
        cols,
        rows,
        pixel_width: pixels(cols, width),
        pixel_height: pixels(rows, height),
    }
}

/// The kitty images each screen of a session's terminal keeps, in bytes.
pub const IMAGE_STORAGE_BYTES: u64 = cherry_vt::IMAGE_STORAGE_BYTES;
/// How often at most a holder logs that a snapshot left images out.
const DROPPED_IMAGES_LOG_INTERVAL: Duration = Duration::from_secs(60);

/// What the terminal reports of its colours, from a `Launch`'s.
fn terminal_colors(colors: cherry_protocol::TerminalColors) -> cherry_vt::Colors {
    cherry_vt::Colors {
        foreground: colors.foreground.0,
        background: colors.background.0,
        cursor: colors.cursor.unwrap_or(colors.foreground).0,
        light: !colors.dark,
    }
}

/// Turn on IUTF8 on the session's terminal, as Terminal.app, iTerm2 and
/// Ghostty do: the line discipline then erases a whole UTF-8 character on
/// backspace in canonical mode (`cat`, `read`), not its last byte.
fn set_iutf8(fd: libc::c_int) -> io::Result<()> {
    unsafe {
        let mut termios: libc::termios = std::mem::zeroed();
        if libc::tcgetattr(fd, &mut termios) != 0 {
            return Err(io::Error::last_os_error());
        }
        termios.c_iflag |= libc::IUTF8;
        if libc::tcsetattr(fd, libc::TCSANOW, &termios) != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

/// A session whose environment says it is reached over SSH
/// (`SSH_CONNECTION`: the Mac app's tabs of another Mac, so that programs
/// copy with OSC 52 rather than to that Mac's pasteboard) gets `SSH_TTY`
/// naming its own terminal, as sshd sets it. Only the holder knows that
/// path; any `SSH_TTY` the client sent is replaced. Other sessions' are left
/// as they are.
fn with_ssh_tty(env: &[(Vec<u8>, Vec<u8>)], tty: &Path) -> Vec<(Vec<u8>, Vec<u8>)> {
    if !env.iter().any(|(key, _)| key == b"SSH_CONNECTION") {
        return env.to_vec();
    }
    env.iter()
        .filter(|(key, _)| key != b"SSH_TTY")
        .cloned()
        .chain([(b"SSH_TTY".to_vec(), tty.as_os_str().as_bytes().to_vec())])
        .collect()
}

/// Start the session's program on a new PTY of `size`. Returns the master
/// and the session leader.
fn spawn(
    command: &[String],
    cwd: &[u8],
    env: &[(Vec<u8>, Vec<u8>)],
    size: PtySize,
) -> Result<(Box<dyn MasterPty + Send>, libc::pid_t)> {
    let pair = native_pty_system().openpty(size)?;
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
    let env = with_ssh_tty(env, &tty);
    let slave = OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOCTTY)
        .open(&tty)
        .with_context(|| format!("opening {}", tty.display()))?;
    drop(pair.slave);
    set_iutf8(slave.as_raw_fd()).context("setting IUTF8 on the session's terminal")?;
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
    // The holder has one thread until its terminal's starts, after the
    // fork: nothing opens a descriptor above this one before it.
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
    /// Output not yet in a frame, the offset it starts at, and since when
    /// it waits.
    output: Vec<u8>,
    output_offset: u64,
    output_since: Option<Instant>,
    /// The events the hello carried, until the daemon has them: it sent a
    /// frame other than `REFUSED`, or the link lasted (see `disconnect`).
    offered: Vec<link::Event>,
    /// The daemon refused the hello, so it took none of them.
    turned_away: bool,
    /// Frames were left in `reader` for the next pass (`pump_link`).
    backlog: bool,
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
        self.output_since = None;
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

/// `terminal` as a renderer stream: the whole of it, limited to `max`
/// bytes (oldest history dropped), or its screens without history; and the
/// kind of snapshot that is (see `link::SnapshotRequest`). `resized`: the
/// last resize took effect where the output ends now.
///
/// Full and limited snapshots re-send the kitty images on screen, in at
/// most `MAX_SNAPSHOT_GRAPHICS_BYTES` on top of the limit (see
/// `cherry_vt::Terminal::snapshot_with`); what they left out is returned.
fn snapshot(
    terminal: &mut Terminal,
    mut kind: String,
    max: Option<usize>,
    resized: bool,
    unfinished: &[u8],
    graphics_asked: bool,
) -> Result<(String, Vec<u8>, Option<GraphicsReplay>)> {
    if kind == "resized" {
        // A full-screen program repaints when its terminal is resized:
        // only where the new size took effect is needed, and the reply
        // says that is here. So it may, only while nothing was output
        // since the resize: a copy that followed the output at the old
        // size would have taken the program's repaint for the new one
        // (or whatever else came meanwhile) at the wrong size.
        if resized && terminal.cursor()?.alternate {
            return Ok(("size".into(), Vec::new(), None));
        }
        kind = "refresh".into();
    }
    let mut graphics = None;
    let raw = match kind.as_str() {
        "full" | "limited" => {
            let max = (kind == "limited").then(|| max.unwrap_or(MAX_SNAPSHOT_BYTES));
            let (raw, replay) =
                terminal.snapshot_with(max, MAX_SNAPSHOT_GRAPHICS_BYTES, unfinished)?;
            graphics = Some(replay);
            raw
        }
        // For a window that paints a viewport, with the images on screen
        // (link version 9), which come on top of the limit.
        "refresh" if graphics_asked => {
            let (raw, replay) = terminal.refresh_with(
                MAX_SNAPSHOT_BYTES,
                MAX_SNAPSHOT_GRAPHICS_BYTES,
                unfinished,
            )?;
            graphics = Some(replay);
            raw
        }
        "refresh" => {
            let raw = terminal.refresh()?;
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
    // The kitty graphics it re-sends keep their `q=2` through the stream.
    let display = DisplayStream::default().feed(&raw).display;
    if display.len() > link::MAX_FRAME - 64 * 1024 {
        bail!("the snapshot exceeds the link's frame limit");
    }
    Ok((kind, display, graphics))
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
    /// The headless terminal, parsing on a thread of its own.
    terminal: TerminalThread,
    /// Kitty graphics data in files and shared memory, read before the
    /// display stream (see `media`).
    media: Media,
    display: DisplayStream,
    offset: u64,
    /// Where in the output the daemon's last `RESIZE` took effect; None
    /// when it changed nothing (or none came from this daemon). A `resized`
    /// snapshot request is answered `size` only while nothing followed it
    /// (see `snapshot`).
    resized_at: Option<u64>,
    /// The cell size in pixels the daemon last gave (link version 8), which
    /// the terminal and the PTY have; None until one comes.
    cell: Option<(u32, u32)>,
    /// When a snapshot last logged images it left out.
    images_logged: Option<Instant>,
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
    /// How far the daemon lets the program's output be read, while the
    /// session's clients take their output slowly (`link::Pace`).
    limit: Option<u64>,
    /// Since when it lets nothing more through (see `follow_pace`).
    held_since: Option<Instant>,
    /// Output waits for the terminal (`terminal_thread::HIGH_WATER`).
    parsing: bool,
    /// The last pass read as much as it may: more output is ready (see
    /// `read_output`).
    more_output: bool,
    /// What the last poll found ready (all of it after a pass without a
    /// poll): a pass skips the reads that would find nothing (see `run`).
    ready: Ready,
    /// The buffer PTY reads go to.
    read_buffer: Vec<u8>,
    /// Since when output has come without a pause of `FLOOD_PAUSE`, and
    /// when it last came (see `flooding`).
    run_since: Option<Instant>,
    last_output: Option<Instant>,
    /// Whether a drained read is retried at once during a flood (see
    /// `read_output`).
    spinning: bool,
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
        let cell = launch.cell();
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
            colors,
            ..
        } = launch;
        if !valid_size(cols, rows) {
            bail!("terminal size must be 2–500 columns and 1–200 rows");
        }
        if command.is_empty() {
            bail!("no command to launch");
        }
        let mut terminal = Terminal::new(cols, rows, screen::SCROLLBACK_BYTES)?;
        // The window the session is created for: its program sees that
        // window's pixels from the start (see `size`).
        if let Some((width, height)) = cell {
            terminal.resize_cells(cols, rows, width, height)?;
        }
        // Kitty images, which snapshots re-send (see `snapshot`).
        terminal.set_image_storage_limit(IMAGE_STORAGE_BYTES)?;
        // What the program is told of its terminal's colours: the app's.
        if let Some(colors) = colors {
            terminal.set_colors(terminal_colors(colors))?;
        }
        // Before the child exists, so its exit always wakes us.
        let child_exits = signals::child_exits().context("installing the child-exit handler")?;
        let (master, pid) = spawn(&command, cwd, env, size(cols, rows, cell))?;
        let manifest = paths::Manifest {
            id: id.clone(),
            holder_pid: std::process::id(),
            created_at,
            link_version: link::LINK_VERSION,
            holder_started: processes::start_identity(unsafe { libc::getpid() }),
            build: Some(daemon::build().to_owned()),
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
        // After the fork: the child inherits none of its descriptors.
        let terminal = TerminalThread::start(terminal)?;
        let session_tmpdir = env
            .iter()
            .rev()
            .find(|(key, _)| key == b"TMPDIR")
            .map(|(_, value)| value.as_slice());
        let media = Media::new(media::Places::new(session_tmpdir))
            .context("creating the media reader's wakeups")?;
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
                bracketed_paste: Some(false),
                modify_other_keys: Some(false),
            },
            receipt,
            master: Some(master),
            pid,
            terminal,
            media,
            display: DisplayStream::default(),
            offset: 0,
            resized_at: None,
            cell,
            images_logged: None,
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
            limit: None,
            held_since: None,
            parsing: false,
            more_output: false,
            ready: Ready::ALL,
            read_buffer: vec![0; READ_BYTES],
            run_since: None,
            last_output: None,
            spinning: true,
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
        // The hello carries the state as the output read so far left it.
        self.settle_terminal();
        let offered = self.held.take();
        let hello = link::HolderHello {
            id: self.id.clone(),
            holder_pid: std::process::id(),
            session: self.state.clone(),
            offset: self.offset,
            receipt: self.receipt.clone(),
            build: Some(daemon::build().to_owned()),
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
            output_since: None,
            offered,
            turned_away: false,
            backlog: false,
        });
        // The hello carries the whole state.
        self.info = link::Info::default();
        // A daemon's `resized` requests follow its own resizes, and it holds
        // the program back itself.
        self.resized_at = None;
        self.limit = None;
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
        // Without a daemon nobody is attached.
        self.interactive(false);
        self.held.restore(untaken);
        self.info = link::Info::default();
        self.pending_input.forget_link();
        self.paused = false;
        self.limit = None;
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

    /// Read available output; false once the PTY reports end of file. At
    /// most `READS_PER_PASS` reads: whether it read as much as that, so
    /// that more output is ready, is `more_output`. As far as the daemon
    /// lets it (`credit`) when `paced`; the output a program left when it
    /// exited is read whatever the daemon said.
    fn read_output(&mut self, paced: bool) -> bool {
        // A kitty graphics command whose data the media layer read: its
        // transmission goes on below. One it refused is answered here,
        // after the replies to the output before it.
        if let Some(reply) = self.media.finish(Instant::now()) {
            self.settle_terminal();
            self.queue_replies(&reply);
        }
        let fd = self.master_fd();
        let mut credit = if paced { self.credit() } else { usize::MAX };
        let mut output = Batch::default();
        let mut open = true;
        // Bounded work per wake gives input, requests and termination a
        // turn under output floods. One frame carries the whole burst, and
        // the terminal gets it in one hand-off, whole tokens only.
        let mut reads = 0;
        let mut drained = false;
        // During a flood the program refills the PTY within microseconds
        // of a read (a PTY holds a few KiB, so it writes a little at a
        // time): the holder reads again at once, yielding in between,
        // rather than sleep in poll and pay a wakeup for every few KiB,
        // which is what limits a flood's rate once the holder is faster
        // than the program. As long as that finds more output.
        let mut retries = 0;
        let mut found = false;
        let spin = self.spinning && self.flooding();
        while reads < READS_PER_PASS && credit > 0 {
            // No more than the daemon lets through: display output is no
            // longer than what it is read from, but for a few bytes.
            let want = self.read_buffer.len().min(credit);
            // Output the media layer holds goes first, as if it were read
            // now; while a read is under way, the PTY waits behind it.
            if self.media.holds_output() {
                let display = &mut self.display;
                let went = self.media.resume(want, &mut |bytes: &[u8]| {
                    display.feed_into(bytes, &mut output)
                });
                if went == 0 {
                    break;
                }
                reads += 1;
                credit = credit.saturating_sub(went);
                continue;
            }
            let buffer = &mut self.read_buffer;
            let n = unsafe { libc::read(fd, buffer.as_mut_ptr().cast(), want) };
            if n < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                if error.kind() == io::ErrorKind::WouldBlock && spin && retries < FLOOD_RETRIES {
                    retries += 1;
                    std::thread::yield_now();
                    continue;
                }
                open = error.kind() == io::ErrorKind::WouldBlock;
                drained = true;
                break;
            }
            if n == 0 {
                open = false;
                drained = true;
                break;
            }
            found |= retries > 0;
            reads += 1;
            credit = credit.saturating_sub(n as usize);
            let display = &mut self.display;
            self.media
                .feed(&self.read_buffer[..n as usize], &mut |bytes: &[u8]| {
                    display.feed_into(bytes, &mut output)
                });
        }
        // Output the media layer holds is ready at once, unless it waits
        // for a read.
        if self.media.holds_output() {
            drained = !self.media.due(Instant::now());
        }
        let dropped = self.display.take_dropped_clipboard_writes();
        if dropped > 0 {
            log(format_args!(
                "session {}: dropped {dropped} clipboard write(s) (OSC 52) over {} bytes",
                self.id,
                crate::stream::MAX_CLIPBOARD
            ));
        }
        // The last pass left output ready: the time since is no pause of the
        // program's (see `flooding`).
        let continued = std::mem::replace(&mut self.more_output, !drained);
        // Reading again at once pays off while it finds output: after a
        // pass that read all it may, or a retry that found some. It stops
        // once the retries found none (a program that writes a little now
        // and then), until a pass reads all it may again.
        if !drained || found {
            self.spinning = true;
        } else if retries > 0 {
            self.spinning = false;
        }
        if reads > 0 {
            let now = Instant::now();
            if !continued
                && self
                    .last_output
                    .is_none_or(|last| now.saturating_duration_since(last) >= FLOOD_PAUSE)
            {
                self.run_since = Some(now);
            }
            self.last_output = Some(now);
            // The terminal's share, with the kitty notifications in it,
            // which the terminal does not report, where they came.
            let terminal = std::mem::take(&mut output.terminal);
            let notifications = std::mem::take(&mut output.notifications);
            self.parsing = !self.terminal.feed(terminal, notifications);
            // A query the host answers is parsed at once, so the program
            // gets its reply without delay.
            if output.answered {
                self.parsing = !self.terminal.flush();
            }
            self.emit(output);
            self.activity();
        }
        open
    }

    /// Take what the terminal produced since last taken: replies for the
    /// program, its events and changes in its state, in order.
    fn collect_terminal(&mut self) {
        let (parsed, accepting) = self.terminal.take();
        self.parsing = !accepting;
        self.queue_replies(&parsed.replies);
        for report in parsed.reports {
            match report {
                Report::Event(event) => self.vt_event(event),
                Report::State(state) => self.terminal_state(state),
            }
        }
    }

    /// Wait until the terminal has parsed the output read so far, and take
    /// what that produced.
    fn settle_terminal(&mut self) {
        self.terminal.sync();
        self.collect_terminal();
    }

    /// Whether the program floods: its output has come without a pause of
    /// `FLOOD_PAUSE` for `FLOOD_AFTER`, and still does. Interactive output
    /// (an echo, a prompt, an editor's repaint) comes in bursts shorter
    /// than that, with pauses between them. A wait with output ready (for
    /// the daemon to let more through, say) is no pause.
    fn flooding(&self) -> bool {
        match (self.run_since, self.last_output) {
            (Some(since), Some(last)) => {
                last.saturating_duration_since(since) >= FLOOD_AFTER && last.elapsed() < FLOOD_PAUSE
            }
            _ => false,
        }
    }

    /// Whether the PTY is read: its output was not all read, neither the
    /// daemon nor the terminal has too much of it waiting, and the daemon
    /// lets more through (`credit`).
    fn reading(&self) -> bool {
        !self.eof && !self.paused && !self.parsing && self.master.is_some() && self.credit() > 0
    }

    /// The time the daemon let nothing more through does not count as a
    /// pause of the program's output (see `flooding`): a flood held back
    /// for a slow client goes on as one once the client takes more.
    fn follow_pace(&mut self) {
        let held = self.credit() == 0;
        match self.held_since {
            None if held => self.held_since = Some(Instant::now()),
            Some(since) if !held => {
                self.held_since = None;
                let held_for = since.elapsed();
                for at in [&mut self.run_since, &mut self.last_output]
                    .into_iter()
                    .flatten()
                {
                    *at += held_for;
                }
            }
            _ => {}
        }
    }

    /// How much more of the program's output the daemon lets through
    /// (`link::Pace`): while the session's clients take their output
    /// slowly, what the fastest of them can take.
    fn credit(&self) -> usize {
        self.limit.map_or(usize::MAX, |limit| {
            usize::try_from(limit.saturating_sub(self.offset)).unwrap_or(usize::MAX)
        })
    }

    /// The holder's priority, and its terminal thread's.
    fn interactive(&self, on: bool) {
        priority::interactive(on);
        self.terminal.set_interactive(on);
    }

    /// Info not sent yet goes before a reply to a request, so the daemon
    /// knows the state of the terminal the reply was taken from.
    fn send_info(&mut self) {
        if !self.info.is_empty() && self.link.is_some() {
            let info = std::mem::take(&mut self.info);
            self.send(link::encode(kind::INFO, &info, &[]));
        }
    }

    /// Whether the alternate screen shows, the kitty keyboard flags,
    /// application cursor keys, bracketed paste and modifyOtherKeys: the
    /// daemon is told when they change.
    fn terminal_state(&mut self, now: screen::TerminalState) {
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
        if self.state.bracketed_paste != Some(now.bracketed_paste) {
            self.state.bracketed_paste = Some(now.bracketed_paste);
            self.info.bracketed_paste = Some(now.bracketed_paste);
        }
        if self.state.modify_other_keys != Some(now.modify_other_keys) {
            self.state.modify_other_keys = Some(now.modify_other_keys);
            self.info.modify_other_keys = Some(now.modify_other_keys);
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
                link.output_since = Some(Instant::now());
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

    /// Resize the terminal to `cols` by `rows`, and to cells of `cell`
    /// pixels when one is given (otherwise they stay as they are); whether
    /// the grid changed. A new cell size alone resizes the terminal and the
    /// PTY too (whose pixels change, which signals the program), but not
    /// the grid.
    fn resize(&mut self, cols: u16, rows: u16, cell: Option<(u32, u32)>) -> bool {
        let cell = cell.or(self.cell);
        let grid = (self.state.cols, self.state.rows) != (cols, rows);
        if !self.state.running || !valid_size(cols, rows) || (!grid && cell == self.cell) {
            return false;
        }
        // Where the output read so far ends, as the program's own terminal
        // is resized after it.
        let resized = self.terminal.call(move |terminal| match cell {
            Some((width, height)) => terminal.resize_cells(cols, rows, width, height),
            None => terminal.resize(cols, rows),
        });
        // The replies to that output go first.
        self.collect_terminal();
        let replies = match resized {
            Ok(replies) => replies,
            Err(error) => {
                log(format_args!(
                    "session {}: resize failed: {error:#}",
                    self.id
                ));
                return false;
            }
        };
        if let Some(master) = &self.master {
            if let Err(error) = master.resize(size(cols, rows, cell)) {
                log(format_args!(
                    "session {}: resizing the terminal failed: {error:#}",
                    self.id
                ));
            }
        }
        self.queue_replies(&replies);
        self.cell = cell;
        self.state.cols = cols;
        self.state.rows = rows;
        self.info.cols = Some(cols);
        self.info.rows = Some(rows);
        grid
    }

    /// The terminal as a renderer stream, exactly as the output up to
    /// `self.offset` left it (see `snapshot`). What the terminal reported
    /// of that output is taken first, and goes before the reply.
    fn take_snapshot(&mut self, request: &link::SnapshotRequest) -> Result<(String, Vec<u8>)> {
        let kind = request.kind.clone();
        let max = request.max;
        let resized = self.resized_at == Some(self.offset);
        // A kitty image whose chunks are still coming (see
        // `DisplayStream::unfinished_transfer`).
        let unfinished = self.display.unfinished_transfer().to_vec();
        let graphics = request.graphics;
        let snapshot = self
            .terminal
            .call(move |terminal| snapshot(terminal, kind, max, resized, &unfinished, graphics));
        self.collect_terminal();
        self.send_info();
        let (kind, bytes, graphics) = snapshot?;
        let due = self
            .images_logged
            .is_none_or(|at| at.elapsed() >= DROPPED_IMAGES_LOG_INTERVAL);
        if let Some(graphics) = graphics.filter(|graphics| graphics.dropped > 0 && due) {
            self.images_logged = Some(Instant::now());
            log(format_args!(
                "session {}: the snapshot re-sends {} of {} images on screen, leaving out {} bytes of pixels: {} did not fit in {MAX_SNAPSHOT_GRAPHICS_BYTES} bytes, {} are numbered images whose ID it cannot give again (logged at most once a minute)",
                self.id,
                graphics.images,
                graphics.images + graphics.dropped,
                graphics.dropped_bytes,
                graphics.dropped - graphics.unnamed,
                graphics.unnamed
            ));
        }
        Ok((kind, bytes))
    }

    /// The screen as text (see `screen::read`), exactly as the output up to
    /// `self.offset` left it.
    fn screen(&mut self, request: &link::ScreenRequest) -> Result<screen::ScreenText> {
        let (scrollback, max_lines) = (request.scrollback, request.max_lines);
        let screen = self
            .terminal
            .call(move |terminal| screen::read(terminal, scrollback, max_lines));
        self.collect_terminal();
        self.send_info();
        screen
    }

    /// Clear the terminal's history (`link::kind::CLEAR_HISTORY`), as ED 3
    /// would where the output read so far ends: snapshots and the screen
    /// as text then show none of it. The program's output is left alone.
    fn clear_history(&mut self, req: u64) {
        let cleared = self.terminal.call(|terminal| {
            // ED 3 clears the history of the screen that shows.
            if terminal.cursor().is_ok_and(|cursor| cursor.alternate) {
                return Ok(None);
            }
            terminal.clear_history().map(Some)
        });
        self.collect_terminal();
        let (outcome, error) = match cleared {
            Ok(Some(_)) => ("cleared", None),
            Ok(None) => ("alternate_screen", None),
            Err(error) => {
                log(format_args!(
                    "session {}: clearing its history failed: {error:#}",
                    self.id
                ));
                ("failed", Some(format!("{error:#}")))
            }
        };
        self.send(link::encode(
            kind::HISTORY_CLEARED,
            &link::HistoryCleared {
                req,
                outcome: outcome.into(),
                error,
            },
            &[],
        ));
    }

    /// Serve one frame from the daemon; whether that took work (a
    /// snapshot, the screen as text: see `pump_link`).
    fn handle(&mut self, frame: Frame) -> bool {
        if frame.kind != kind::REFUSED {
            // Only a daemon that took the hello sends anything else.
            if let Some(link) = &mut self.link {
                link.offered.clear();
            }
        }
        match frame.kind {
            kind::INPUT => {
                let Ok(meta) = frame.meta::<link::InputMeta>() else {
                    return false;
                };
                if self.eof {
                    self.send_acks(vec![(meta.lease, frame.data.len() as u64)]);
                } else {
                    // Replies to the queries in the output read before
                    // this input go to the program before it, as they
                    // would if the holder parsed the output itself: the
                    // terminal first parses what it has not yet. (A query
                    // the display stream knows the host answers is handed
                    // to it at once, see `read_output`, so this is quick.)
                    if !self.terminal.settled() {
                        self.settle_terminal();
                    }
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
                    let cell = self.cell;
                    let resized = self.resize(size.cols, size.rows, size.cell());
                    // A new cell size alone leaves where the grid last
                    // changed as it was.
                    if resized || self.cell == cell {
                        self.resized_at = resized.then_some(self.offset);
                    }
                }
            }
            kind::SNAPSHOT => {
                let Ok(request) = frame.meta::<link::SnapshotRequest>() else {
                    return false;
                };
                let (kind, bytes, error) = match self.take_snapshot(&request) {
                    Ok((kind, bytes)) => (kind, bytes, None),
                    Err(error) => (request.kind.clone(), Vec::new(), Some(format!("{error:#}"))),
                };
                // Where the size took effect alone is no work.
                let costly = kind != "size";
                let reply = link::SnapshotReply {
                    req: request.req,
                    kind,
                    offset: self.offset,
                    cols: self.state.cols,
                    rows: self.state.rows,
                    error,
                };
                self.send(link::encode(kind::SNAPSHOT_REPLY, &reply, &bytes));
                return costly;
            }
            kind::SCREEN => {
                let Ok(request) = frame.meta::<link::ScreenRequest>() else {
                    return false;
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
                return true;
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
            kind::ATTENDED => {
                if let Ok(attended) = frame.meta::<link::Attended>() {
                    self.interactive(attended.attached);
                }
            }
            kind::PACE => {
                if let Ok(pace) = frame.meta::<link::Pace>() {
                    self.limit = pace.limit;
                }
            }
            kind::CLEAR_HISTORY => {
                if let Ok(request) = frame.meta::<link::Req>() {
                    self.clear_history(request.req);
                }
                return true;
            }
            kind::REFUSED => self.refused(frame.meta().unwrap_or(link::Refused {
                reason: "no reason given".into(),
                retry: true,
            })),
            // Launch only starts a holder; other kinds are for daemons, or
            // from a newer daemon.
            _ => {}
        }
        false
    }

    /// Take what the daemon sent. Requests that take work (`COSTLY_PER_PASS`)
    /// are served one per pass, so the output read before the next one goes
    /// out first; the frames after it wait in the reader (`Link::backlog`).
    /// A `resized` request answered `size` takes none, so one that follows
    /// its resize is answered in the same pass, before the program's
    /// repaint is read. A link that ended is taken in whole first.
    fn pump_link(&mut self) {
        let Some(link) = &mut self.link else {
            return;
        };
        let open = link.reader.fill(link.stream.as_raw_fd(), LINK_READ);
        link.backlog = false;
        let mut costly = 0;
        loop {
            let Some(link) = &mut self.link else {
                return;
            };
            if open && costly >= COSTLY_PER_PASS {
                link.backlog = true;
                return;
            }
            match link.reader.next() {
                Ok(Some(frame)) => {
                    if self.handle(frame) {
                        costly += 1;
                    }
                }
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
        // Output goes as soon as the link has room; until then it gathers.
        // It also gathers, up to `GATHER_BYTES`, while the program's output
        // keeps coming (the pass read as much as it may, so more is ready
        // at once), and during a flood for up to `FLOOD_DELAY`: a flood
        // travels in fewer, bigger frames, which cost the daemon and the
        // clients less per byte. Output after a pause (an echo, a prompt,
        // a repaint) goes at once.
        // Nothing gathers once the daemon lets no more through.
        let flooding = self.flooding() && self.credit() > 0;
        let gather = self.link.as_ref().is_some_and(|link| {
            link.output.len() < GATHER_BYTES
                && ((self.more_output && self.reading())
                    || (flooding
                        && link
                            .output_since
                            .is_some_and(|since| since.elapsed() < FLOOD_DELAY)))
        });
        let Some(link) = &mut self.link else {
            self.info = link::Info::default();
            return;
        };
        if link.writer.is_empty() && !gather {
            link.push_output();
        }
        let mut flushed = link.writer.flush(link.stream.as_raw_fd());
        if flushed && link.writer.is_empty() && !link.output.is_empty() && !gather {
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
        // Never blocks this, the session's I/O thread: a leader that has
        // not exited after all is looked at again at its next wakeup (its
        // exit sends SIGCHLD).
        let Some(status) = processes::reap(self.pid) else {
            return;
        };
        // Bytes written before exit are part of the transcript, however far
        // the daemon lets the output be read, and so are the kitty images
        // the media layer reads for them: those reads are waited for, in
        // all for at most `media::READ_TIMEOUT`.
        if !self.eof {
            let until = Instant::now() + media::READ_TIMEOUT;
            loop {
                self.media.wait(until);
                self.read_output(false);
                if !self.media.holds_output() || Instant::now() >= until {
                    break;
                }
            }
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
        // The last changes, then the exit, after the last output and what
        // the terminal made of it.
        self.terminal.sync();
        self.collect_terminal();
        self.send_info();
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
        if self.link.as_ref().is_some_and(|link| link.backlog) {
            return Duration::ZERO;
        }
        let now = Instant::now();
        // Output the media layer holds goes on at once (see `read_output`).
        if self.reading() && self.media.due(now) {
            return Duration::ZERO;
        }
        let mut wait = IDLE_WAIT;
        if self.termination.is_some() {
            wait = wait.min(TERMINATION_POLL);
        }
        // A read it waits for times out.
        let media = self.media.deadline().filter(|_| self.media.reading());
        for due in [self.redial_at, self.foreground_due, media]
            .into_iter()
            .flatten()
        {
            wait = wait.min(due.saturating_duration_since(now));
        }
        // Output held for the terminal is handed over by `MAX_HOLD`.
        if let Some(left) = self.terminal.hold_left() {
            wait = wait.min(left);
        }
        // Output gathering during a flood goes by `FLOOD_DELAY` (output
        // that waits for the link to drain goes when it does).
        let gathering = self
            .link
            .as_ref()
            .filter(|link| link.writer.is_empty() && self.flooding() && self.credit() > 0)
            .and_then(|link| link.output_since);
        if let Some(since) = gathering {
            wait = wait.min(FLOOD_DELAY.saturating_sub(since.elapsed()));
        }
        wait
    }

    fn run(mut self) {
        loop {
            // What the terminal made of the output so far: its replies go
            // to the program below.
            self.collect_terminal();
            self.follow_pace();
            // Each read, and the exit check, only when the last poll found
            // something for it (every one after a pass without a poll):
            // under a flood a pass is a few reads, so a read that finds
            // nothing costs as much as one that finds output.
            let ready = std::mem::replace(&mut self.ready, Ready::ALL);
            // Output first, and out before any request is served, so that
            // request work (a snapshot, the screen as text) never delays it.
            if self.reading()
                && (ready.master || self.more_output || self.media.due(Instant::now()))
            {
                self.eof = !self.read_output(true);
                self.flush_link();
            }
            if ready.link || self.link.as_ref().is_some_and(|link| link.backlog) {
                self.pump_link();
            }
            // Input the daemon just sent goes to the program at once.
            self.write_input();
            // A child's exit wakes the holder (`child_exits`); a kill in
            // progress looks at the session's members every pass.
            if self.state.running && (ready.child || self.termination.is_some()) {
                self.check_exit();
            }
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
        // Output held for the terminal waits for more to join it (see
        // `next_wait`) for at most `terminal_thread::MAX_HOLD`: during a
        // flood the terminal takes it a chunk at a time, woken once per
        // chunk rather than per pass.
        self.poll(self.next_wait());
        if self.terminal.has_pending() && self.terminal.due() {
            self.parsing = !self.terminal.flush();
        }
    }

    /// Wait up to `wait` for something to do, and note what is ready.
    fn poll(&mut self, wait: Duration) {
        let master = if self.eof || self.master.is_none() {
            -1
        } else {
            self.master_fd()
        };
        let mut master_events = 0;
        // Not while output waits in the media layer, which goes first.
        if !self.paused && !self.parsing && self.credit() > 0 && !self.media.holds_output() {
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
            libc::pollfd {
                fd: self.terminal.wakeup_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: self.media.wakeup_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        let millis = wait.as_micros().div_ceil(1000).min(i32::MAX as u128) as libc::c_int;
        let ready = unsafe { libc::poll(poll.as_mut_ptr(), poll.len() as libc::nfds_t, millis) };
        let readable = |fd: &libc::pollfd| {
            fd.revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0
        };
        self.ready = if ready < 0 {
            // Interrupted (a child's exit, say): look at everything.
            Ready::ALL
        } else {
            Ready {
                // Not asked about while it was not read: tried next pass.
                master: master_events & libc::POLLIN == 0 || readable(&poll[0]),
                link: readable(&poll[1]),
                child: poll[2].revents != 0,
            }
        };
        if self.ready.child {
            signals::drain(&self.child_exits);
        }
        if poll[4].revents != 0 {
            // Taken at the top of the loop.
            signals::drain(self.terminal.wakeups());
        }
        if poll[5].revents != 0 {
            // A read finished: taken by the next `read_output`.
            self.media.drain_wakeups();
        }
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
    priority::grow_send_buffer(fd);
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

    #[test]
    fn a_session_reached_over_ssh_gets_its_own_terminal_as_ssh_tty() {
        let pair = |key: &str, value: &str| (key.as_bytes().to_vec(), value.as_bytes().to_vec());
        let tty = Path::new("/dev/ttys042");
        // Not over SSH: unchanged, whatever SSH_TTY says.
        let local = vec![
            pair("TERM", "xterm-256color"),
            pair("SSH_TTY", "/dev/ttys001"),
        ];
        assert_eq!(with_ssh_tty(&local, tty), local);
        // Over SSH: this session's terminal, once, in place of the client's.
        let remote = vec![
            pair("SSH_CONNECTION", "127.0.0.1 0 127.0.0.1 22"),
            pair("SSH_TTY", "/dev/ttys001"),
        ];
        assert_eq!(
            with_ssh_tty(&remote, tty),
            [
                pair("SSH_CONNECTION", "127.0.0.1 0 127.0.0.1 22"),
                pair("SSH_TTY", "/dev/ttys042"),
            ]
        );
    }

    #[test]
    fn a_panic_report_names_the_time_the_session_and_the_build() {
        let at = SystemTime::UNIX_EPOCH + Duration::from_millis(1_790_000_000_123);
        assert_eq!(utc_timestamp(at), "2026-09-21T14:13:20.123Z");
        assert_eq!(
            utc_timestamp(SystemTime::UNIX_EPOCH + Duration::from_secs(951_782_400)),
            "2000-02-29T00:00:00.000Z"
        );
        let report = panic_report(Some("3f6c"), at, "panicked at src/x.rs:1:2:\nboom");
        assert!(
            report.starts_with(&format!(
                "holder of session 3f6c (pid {}) panicked at 2026-09-21T14:13:20.123Z; build cherry-host {} (link {}, protocol {},",
                std::process::id(),
                cherry_protocol::VERSION,
                link::LINK_VERSION,
                cherry_protocol::PROTOCOL_VERSION
            )),
            "{report}"
        );
        assert!(
            report.ends_with("): panicked at src/x.rs:1:2:\nboom"),
            "{report}"
        );
        assert!(panic_report(None, at, "p").contains("session (not launched yet)"));
    }

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
