//! A holder's terminal, on a thread of its own, so that its output path
//! (reading the PTY, the display stream, the link) never waits for
//! libghostty-vt to parse.
//!
//! The holder hands the terminal its share of the output (`feed`) in chunks
//! of `CHUNK` bytes, or what it has once that waited `MAX_HOLD` (`flush`),
//! and at once when it holds a query the host answers: a flood costs a
//! hand-off (and at most one wakeup of the thread) per chunk rather than
//! per read, and the program's queries are answered without delay.
//! What parsing produces (replies for the program, events, changes in the
//! terminal state clients follow) waits for the holder (`take`), which is
//! woken for it (`wakeups`). Whatever else reads or changes the terminal
//! (a snapshot, the screen as text, a resize) runs on the thread after
//! everything fed to it before (`call`) while the holder waits: it sees the
//! terminal exactly as the output it has read, and so sent, so far left it.
//!
//! The holder stops reading the PTY while more than `HIGH_WATER` bytes wait
//! to be parsed, until they drain to `LOW_WATER`: a program cannot outrun
//! the terminal, and a request never waits long for it.
use crate::{
    screen::{self, TerminalState},
    signals::Wake,
};
use anyhow::{Context, Result};
use cherry_protocol::priority;
use cherry_vt::{Osc99, Terminal, VtEvent};
use std::{
    collections::VecDeque,
    os::unix::{io::AsRawFd, io::RawFd, net::UnixStream},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc, Condvar, Mutex, MutexGuard,
    },
    thread::JoinHandle,
    time::{Duration, Instant},
};

/// Output is handed over in chunks of this size while more follows at once,
/// and chunks the thread has not taken yet are joined up to it.
const CHUNK: usize = 64 * 1024;
/// Output waits no longer than this to be handed over, however busy the
/// holder is (a query the host answers is in it, say).
const MAX_HOLD: Duration = Duration::from_millis(1);
/// The terminal takes a chunk this much at a time, and its events after
/// each: as many as a read gave it before, at most (see
/// `cherry_vt::MAX_PENDING_EVENTS`).
const SLICE: usize = 16 * 1024;
/// Bytes waiting to be parsed beyond which the holder stops reading, and
/// to which they drain before it reads again.
const HIGH_WATER: usize = 512 * 1024;
const LOW_WATER: usize = 128 * 1024;
/// Replies waiting for the holder are bounded, as those waiting for the
/// program are (`holder::MAX_PENDING_REPLIES`).
const MAX_REPLIES: usize = 1024 * 1024;

/// What parsing reported, in order.
pub enum Report {
    Event(VtEvent),
    /// The terminal state changed (checked after output that holds an
    /// escape sequence, which alone can change it).
    State(TerminalState),
}

/// What parsing produced since the holder last took it.
#[derive(Default)]
pub struct Parsed {
    /// For the program, in order.
    pub replies: Vec<u8>,
    pub reports: Vec<Report>,
}

impl Parsed {
    fn is_empty(&self) -> bool {
        self.replies.is_empty() && self.reports.is_empty()
    }
}

type Call = Box<dyn FnOnce(&mut Terminal) + Send>;

enum Command {
    /// Output for the terminal, and the kitty notifications (OSC 99) in it,
    /// each where it came (see `stream::Batch::notifications`).
    Feed {
        bytes: Vec<u8>,
        notifications: Vec<(usize, Vec<u8>)>,
    },
    Call(Call),
}

#[derive(Default)]
struct Queue {
    commands: VecDeque<Command>,
    /// Output handed over and not parsed yet.
    bytes: usize,
    parsed: Parsed,
    /// The holder was woken and has not taken what waits since.
    woken: bool,
    /// The holder stopped reading (`HIGH_WATER`): woken once the bytes
    /// drain to `LOW_WATER`.
    paused: bool,
    /// The thread waits for a command.
    idle: bool,
    stop: bool,
}

struct Shared {
    queue: Mutex<Queue>,
    work: Condvar,
    wake: Arc<Wake>,
    interactive: AtomicBool,
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, Queue> {
        // The thread aborts the process rather than unwind (see `run`).
        self.queue
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn push(&self, queue: &mut Queue, command: Command) {
        queue.commands.push_back(command);
        if queue.idle {
            self.work.notify_one();
        }
    }
}

pub struct TerminalThread {
    shared: Arc<Shared>,
    wakeups: UnixStream,
    thread: Option<JoinHandle<()>>,
    /// Output not handed over yet, and the notifications in it (`flush`).
    pending: Vec<u8>,
    marks: Vec<(usize, Vec<u8>)>,
    /// When the oldest of it came.
    since: Option<Instant>,
    /// Whether the holder may read more, as last seen.
    accepting: bool,
}

impl TerminalThread {
    /// Start the thread that owns `terminal`. The holder has forked its
    /// child already: nothing forks once it runs.
    pub fn start(terminal: Terminal) -> Result<Self> {
        let (wake, wakeups) = Wake::pair().context("creating the terminal thread's wakeups")?;
        let shared = Arc::new(Shared {
            queue: Mutex::default(),
            work: Condvar::new(),
            wake,
            interactive: AtomicBool::new(priority::is_interactive()),
        });
        let thread = std::thread::Builder::new()
            .name("terminal".into())
            .spawn({
                let shared = shared.clone();
                move || run(&shared, terminal)
            })
            .context("starting the terminal thread")?;
        Ok(Self {
            shared,
            wakeups,
            thread: Some(thread),
            pending: Vec::new(),
            marks: Vec::new(),
            since: None,
            accepting: true,
        })
    }

    /// Readable when something waits to be taken (`take`), or the holder
    /// may read again: drain it with `signals::drain`.
    pub fn wakeups(&self) -> &UnixStream {
        &self.wakeups
    }

    pub fn wakeup_fd(&self) -> RawFd {
        self.wakeups.as_raw_fd()
    }

    /// Output for the terminal, and the kitty notifications in it, each
    /// where it came. It is handed over once `CHUNK` bytes gather, or with
    /// `flush`, which the holder calls before it sleeps: while output
    /// keeps coming, a flood costs one hand-off per chunk rather than per
    /// read. Returns whether the holder may read more.
    pub fn feed(&mut self, bytes: Vec<u8>, notifications: Vec<(usize, Vec<u8>)>) -> bool {
        if !self.has_pending() {
            self.since = Some(Instant::now());
        }
        let base = self.pending.len();
        if base == 0 {
            self.pending = bytes;
        } else {
            self.pending.extend_from_slice(&bytes);
        }
        self.marks.extend(
            notifications
                .into_iter()
                .map(|(at, sequence)| (base + at, sequence)),
        );
        if self.due() {
            self.flush();
        }
        self.accepting
    }

    /// Whether output waits to be handed over (`flush`).
    pub fn has_pending(&self) -> bool {
        !self.pending.is_empty() || !self.marks.is_empty()
    }

    /// Whether what waits must be handed over now: a chunk's worth, or
    /// held for `MAX_HOLD`.
    pub fn due(&self) -> bool {
        self.pending.len() >= CHUNK || self.since.is_some_and(|since| since.elapsed() >= MAX_HOLD)
    }

    /// How long what waits may still wait to be handed over (`MAX_HOLD`).
    pub fn hold_left(&self) -> Option<Duration> {
        self.since
            .map(|since| MAX_HOLD.saturating_sub(since.elapsed()))
    }

    /// Hand over the output fed so far; whether the holder may read more.
    pub fn flush(&mut self) -> bool {
        let mut queue = self.shared.lock();
        self.since = None;
        if self.has_pending() {
            let bytes = std::mem::take(&mut self.pending);
            let notifications = std::mem::take(&mut self.marks);
            queue.bytes += bytes.len();
            match queue.commands.back_mut() {
                // Not taken yet: one command, up to a chunk.
                Some(Command::Feed {
                    bytes: tail,
                    notifications: marks,
                }) if tail.len() + bytes.len() <= CHUNK => {
                    let base = tail.len();
                    tail.extend_from_slice(&bytes);
                    marks.extend(
                        notifications
                            .into_iter()
                            .map(|(at, sequence)| (base + at, sequence)),
                    );
                }
                _ => self.shared.push(
                    &mut queue,
                    Command::Feed {
                        bytes,
                        notifications,
                    },
                ),
            }
            if queue.bytes > HIGH_WATER {
                queue.paused = true;
            }
        }
        self.accepting = !queue.paused;
        self.accepting
    }

    /// What parsing produced since last taken, and whether the holder may
    /// read more.
    pub fn take(&mut self) -> (Parsed, bool) {
        let mut queue = self.shared.lock();
        queue.woken = false;
        self.accepting = !queue.paused;
        (std::mem::take(&mut queue.parsed), self.accepting)
    }

    /// Whether everything fed so far was parsed, and what that produced
    /// taken (`take`).
    pub fn settled(&self) -> bool {
        if self.has_pending() {
            return false;
        }
        let queue = self.shared.lock();
        queue.bytes == 0 && queue.commands.is_empty() && queue.parsed.is_empty()
    }

    /// Run `f` on the terminal once it has parsed everything fed to it so
    /// far, and wait for its answer. What that parsing produced waits in
    /// `take`.
    pub fn call<R: Send + 'static>(
        &mut self,
        f: impl FnOnce(&mut Terminal) -> R + Send + 'static,
    ) -> R {
        self.flush();
        let (answer, answered) = mpsc::sync_channel(1);
        {
            let mut queue = self.shared.lock();
            self.shared.push(
                &mut queue,
                Command::Call(Box::new(move |terminal| {
                    let _ = answer.send(f(terminal));
                })),
            );
        }
        answered
            .recv()
            .expect("the terminal thread ends the process rather than a call")
    }

    /// Wait until the terminal has parsed everything fed to it so far.
    pub fn sync(&mut self) {
        self.call(|_| ());
    }

    /// The thread's priority follows the holder's (`priority::interactive`),
    /// at once, idle or not.
    pub fn set_interactive(&self, on: bool) {
        if self.shared.interactive.swap(on, Ordering::Relaxed) != on {
            let queue = self.shared.lock();
            if queue.idle {
                self.shared.work.notify_one();
            }
        }
    }
}

impl Drop for TerminalThread {
    fn drop(&mut self) {
        {
            let mut queue = self.shared.lock();
            queue.stop = true;
            self.shared.work.notify_one();
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// A panic on the terminal thread ends the process, as a libghostty-vt
/// abort does: the holder cannot go on without its terminal.
struct AbortOnPanic;

impl Drop for AbortOnPanic {
    fn drop(&mut self) {
        if std::thread::panicking() {
            std::process::abort();
        }
    }
}

fn run(shared: &Shared, mut terminal: Terminal) {
    let _abort = AbortOnPanic;
    // Signals are the holder's (SIGCHLD wakes its loop).
    unsafe {
        let mut all: libc::sigset_t = std::mem::zeroed();
        libc::sigfillset(&mut all);
        libc::pthread_sigmask(libc::SIG_BLOCK, &all, std::ptr::null_mut());
    }
    let mut osc99 = Osc99::default();
    let mut state = screen::terminal_state(&terminal);
    loop {
        let command = {
            let mut queue = shared.lock();
            loop {
                priority::interactive(shared.interactive.load(Ordering::Relaxed));
                if let Some(command) = queue.commands.pop_front() {
                    break command;
                }
                if queue.stop {
                    return;
                }
                queue.idle = true;
                queue = shared
                    .work
                    .wait(queue)
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                queue.idle = false;
            }
        };
        let (bytes, notifications) = match command {
            Command::Call(call) => {
                call(&mut terminal);
                continue;
            }
            Command::Feed {
                bytes,
                notifications,
            } => (bytes, notifications),
        };
        let mut parsed = Parsed::default();
        // Kitty notifications, which the terminal does not report, in
        // order with what it does.
        let mut at = 0;
        for (position, sequence) in notifications {
            feed(&mut terminal, &bytes[at..position], &mut parsed);
            at = position;
            if let Some(event @ VtEvent::Notification { .. }) = osc99.feed(&sequence) {
                parsed.reports.push(Report::Event(event));
            }
        }
        feed(&mut terminal, &bytes[at..], &mut parsed);
        // Only an escape sequence can switch screens or change the kitty
        // keyboard flags or DECCKM, and every chunk ends where a pass of
        // whole ones did.
        if bytes.contains(&0x1b) {
            let now = screen::terminal_state(&terminal);
            if now.is_some() && now != state {
                state = now;
                parsed.reports.extend(now.map(Report::State));
            }
        }
        let mut queue = shared.lock();
        queue.bytes -= bytes.len();
        let mut wake = false;
        if !parsed.is_empty() {
            let room = MAX_REPLIES.saturating_sub(queue.parsed.replies.len());
            let replies = &parsed.replies[..parsed.replies.len().min(room)];
            queue.parsed.replies.extend_from_slice(replies);
            queue.parsed.reports.append(&mut parsed.reports);
            wake = true;
        }
        if queue.paused && queue.bytes <= LOW_WATER {
            queue.paused = false;
            wake = true;
        }
        if wake && !queue.woken {
            queue.woken = true;
            shared.wake.wake();
        }
    }
}

fn feed(terminal: &mut Terminal, bytes: &[u8], parsed: &mut Parsed) {
    for slice in bytes.chunks(SLICE) {
        let replies = terminal.feed(slice);
        parsed.replies.extend_from_slice(&replies);
        parsed
            .reports
            .extend(terminal.take_events().into_iter().map(Report::Event));
    }
}
