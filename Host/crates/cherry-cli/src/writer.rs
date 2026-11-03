//! Terminal output written on a thread of its own.
//!
//! An attachment's thread decodes the host's frames, follows them in its
//! screen copy and writes them to the terminal. A terminal's PTY takes little
//! at a time (macOS: under 1 KiB per write), so writing waited on the
//! terminal after every frame while the decoding and the copy waited on the
//! writing: during a flood the two never overlapped. `Writer` queues the
//! bytes and writes them, in order, from its own thread, so the attachment
//! goes back to the connection while the terminal drains.
//!
//! The queue is bounded (`QUEUE_BYTES`, counting what the thread took from
//! it and has not written yet), so a terminal that stops taking output still
//! stops the attachment from reading the connection, as a waiting write did:
//! the attachment then waits for room (see `attach::TerminalOutput`),
//! sending heartbeats and reading the keys typed meanwhile. Room comes back
//! as the terminal takes output, a little at a time (`ROOM_STEP`), not a
//! whole queue at a time: the attachment reads the connection at the
//! terminal's pace, evenly, which is the pace the host holds a program to
//! for a slow terminal (and so the pace its other clients see). Output
//! small enough for one write (echo, a prompt) is written by the caller
//! itself when nothing is queued, so keystrokes are echoed without a thread
//! wakeup.
use crate::sys::{pollfd, write_some};
use cherry_protocol::priority;
use std::{
    io::{self, Read, Write},
    os::{
        fd::{AsRawFd, RawFd},
        unix::net::UnixStream,
    },
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Condvar, Mutex, MutexGuard,
    },
    thread::JoinHandle,
    time::{Duration, Instant},
};

/// Output waiting for the terminal, at most: queued for the thread, or
/// taken by it and not written yet.
pub const QUEUE_BYTES: usize = 256 * 1024;
/// A caller that waits for room (`Writer::arm`) is woken once this much is
/// free (or as much as it waits for, if less).
pub const ROOM_STEP: usize = 16 * 1024;
/// Output up to this long is written by the caller when nothing is queued
/// (one write, as a terminal takes it at once), and only what the terminal
/// did not take is queued.
const DIRECT_BYTES: usize = 1024;
/// How often the thread checks whether it is to stop while the terminal
/// takes nothing.
const STOP_CHECK: Duration = Duration::from_millis(100);

pub struct Writer {
    fd: RawFd,
    shared: Arc<Shared>,
    /// This end of a socket pair with the thread: readable once the thread
    /// made room after `arm` (or ended, closing its end). Written to stop
    /// the thread's wait for the terminal at once (`finish`).
    wake: UnixStream,
    thread: Option<JoinHandle<()>>,
}

struct Shared {
    state: Mutex<State>,
    /// Signalled when output is queued into an empty queue, or the thread is
    /// to stop.
    queued: Condvar,
    /// Bytes the thread wrote so far.
    written: AtomicU64,
    /// Stop at once, dropping what is left.
    abandon: AtomicBool,
}

#[derive(Default)]
struct State {
    queue: Vec<u8>,
    /// Bytes of the batch the thread took from the queue that it has not
    /// written yet.
    unwritten: usize,
    /// The thread is writing a batch it took from the queue.
    busy: bool,
    /// The caller waits for this much room (none: it does not): the thread
    /// wakes it once there is (`Writer::arm`).
    wants_room: usize,
    /// The caller waits for the thread to take the queue
    /// (`Writer::arm_drained`).
    wants_taken: bool,
    /// Nothing more is queued: the thread ends once the queue is written.
    finish: bool,
    /// Why a write failed; the thread ended, and nothing more is written.
    error: Option<io::Error>,
}

impl State {
    /// How much more may be queued.
    fn room(&self) -> usize {
        QUEUE_BYTES.saturating_sub(self.queue.len() + self.unwritten)
    }
}

fn copy(error: &io::Error) -> io::Error {
    match error.raw_os_error() {
        Some(code) => io::Error::from_raw_os_error(code),
        None => io::Error::new(error.kind(), error.to_string()),
    }
}

impl Writer {
    /// Write to `fd` (non-blocking) from a new thread.
    pub fn start(fd: RawFd) -> io::Result<Self> {
        let (wake, notify) = UnixStream::pair()?;
        wake.set_nonblocking(true)?;
        notify.set_nonblocking(true)?;
        let shared = Arc::new(Shared {
            state: Mutex::new(State::default()),
            queued: Condvar::new(),
            written: AtomicU64::new(0),
            abandon: AtomicBool::new(false),
        });
        let thread = std::thread::Builder::new()
            .name("terminal output".into())
            .spawn({
                let shared = shared.clone();
                move || run(fd, &shared, notify)
            })?;
        Ok(Self {
            fd,
            shared,
            wake,
            thread: Some(thread),
        })
    }

    fn state(&self) -> MutexGuard<'_, State> {
        self.shared
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Queue as much of `bytes` as there is room for, after what is queued;
    /// returns how much. Zero when the queue is full, or `bytes` empty.
    pub fn push(&self, bytes: &[u8]) -> io::Result<usize> {
        let mut state = self.state();
        if let Some(error) = &state.error {
            return Err(copy(error));
        }
        if state.finish || bytes.is_empty() {
            return Ok(0);
        }
        let mut direct = 0;
        if bytes.len() <= DIRECT_BYTES && state.queue.is_empty() && !state.busy {
            // Nothing is queued or being written, and the thread takes
            // nothing while the lock is held: written in order.
            direct = write_some(self.fd, bytes)?.unwrap_or(0);
            self.shared
                .written
                .fetch_add(direct as u64, Ordering::Relaxed);
            if direct == bytes.len() {
                return Ok(direct);
            }
        }
        let rest = &bytes[direct..];
        let n = state.room().min(rest.len());
        if n > 0 {
            let was_empty = state.queue.is_empty();
            state.queue.extend_from_slice(&rest[..n]);
            drop(state);
            if was_empty {
                self.shared.queued.notify_one();
            }
        }
        Ok(direct + n)
    }

    /// After `push` found the queue full: have the thread make `wake_fd`
    /// readable once the terminal took `ROOM_STEP` (or `wanted`, if less)
    /// and so made room for that much. False when there is that much room
    /// already (or the thread failed), so `push` is tried again instead.
    pub fn arm(&self, wanted: usize) -> bool {
        let mut state = self.state();
        let wanted = wanted.clamp(1, ROOM_STEP);
        let full = state.error.is_none() && state.room() < wanted;
        if full {
            state.wants_room = wanted;
        }
        full
    }

    /// How much could be queued now (see `push`).
    pub fn room(&self) -> usize {
        self.state().room()
    }

    /// Have the thread make `wake_fd` readable once it took everything
    /// queued now (it may still be writing it). False when nothing is
    /// queued (or the thread failed): the caller need not wait.
    pub fn arm_drained(&self) -> bool {
        let mut state = self.state();
        let queued = state.error.is_none() && !state.queue.is_empty();
        state.wants_taken |= queued;
        queued
    }

    /// Whether nothing is queued: the thread took everything (it may still
    /// be writing the last of it).
    pub fn drained(&self) -> bool {
        self.state().queue.is_empty()
    }

    /// Readable after `arm` or `arm_drained`, once the thread took the
    /// queue or ended.
    pub fn wake_fd(&self) -> RawFd {
        self.wake.as_raw_fd()
    }

    /// Read what woke `wake_fd`; true when the thread ended.
    pub fn clear_wake(&self) -> bool {
        let mut buffer = [0u8; 64];
        loop {
            match (&self.wake).read(&mut buffer) {
                Ok(0) => return true,
                Ok(_) => {}
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                Err(_) => return false,
            }
        }
    }

    /// Bytes written to the terminal so far: progress.
    pub fn written(&self) -> u64 {
        self.shared.written.load(Ordering::Relaxed)
    }

    /// No more output: write what is queued while the terminal takes it,
    /// dropping the rest once it takes nothing for `idle` (at once when
    /// `idle` is zero) or `stop` says so; then the thread ends. Afterwards
    /// the descriptor is the caller's alone.
    pub fn finish(&mut self, idle: Duration, stop: impl Fn() -> bool) {
        let Some(thread) = self.thread.take() else {
            return;
        };
        self.state().finish = true;
        self.shared.queued.notify_one();
        let mut progress = (self.written(), Instant::now());
        loop {
            let now = Instant::now();
            let written = self.written();
            if written != progress.0 {
                progress = (written, now);
            }
            let deadline = progress.1 + idle;
            if now >= deadline || stop() {
                self.shared.abandon.store(true, Ordering::Relaxed);
                self.shared.queued.notify_one();
                // Ends the thread's wait for the terminal.
                let _ = (&self.wake).write(b"x");
                break;
            }
            let mut fds = [pollfd(self.wake.as_raw_fd(), libc::POLLIN)];
            let wait = STOP_CHECK.min(deadline - now);
            let millis = wait.as_micros().div_ceil(1000) as i32;
            unsafe { libc::poll(fds.as_mut_ptr(), 1, millis) };
            if fds[0].revents != 0 && self.clear_wake() {
                break;
            }
        }
        let _ = thread.join();
    }
}

impl Drop for Writer {
    fn drop(&mut self) {
        self.finish(Duration::ZERO, || true);
    }
}

/// The thread: write what is queued, in order, until told to finish (and
/// the queue is empty) or to stop, or a write fails. Its end of the socket
/// pair closes when it ends, which wakes a caller waiting for room.
fn run(fd: RawFd, shared: &Shared, notify: UnixStream) {
    // Signals go to the attachment's thread, whose polls they interrupt.
    unsafe {
        let mut all = std::mem::zeroed::<libc::sigset_t>();
        libc::sigfillset(&mut all);
        libc::pthread_sigmask(libc::SIG_BLOCK, &all, std::ptr::null_mut());
    }
    // It puts the session's frames on the screen, as the attachment's
    // thread does.
    priority::interactive(true);
    let mut batch = Vec::new();
    loop {
        let mut state = shared
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        state.busy = false;
        loop {
            if shared.abandon.load(Ordering::Relaxed) {
                return;
            }
            if !state.queue.is_empty() {
                break;
            }
            if state.finish {
                return;
            }
            state = shared
                .queued
                .wait(state)
                .unwrap_or_else(|poisoned| poisoned.into_inner());
        }
        batch.clear();
        std::mem::swap(&mut state.queue, &mut batch);
        state.busy = true;
        state.unwritten = batch.len();
        if std::mem::take(&mut state.wants_taken) {
            let _ = (&notify).write(b"x");
        }
        drop(state);
        if let Err(error) = write_batch(fd, &batch, shared, &notify) {
            let mut state = shared
                .state
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            state.error = Some(error);
            state.queue = Vec::new();
            state.unwritten = 0;
            state.busy = false;
            // A caller waiting for room hears of the failure.
            if std::mem::take(&mut state.wants_room) > 0 {
                let _ = (&notify).write(b"x");
            }
            return;
        }
    }
}

fn write_batch(
    fd: RawFd,
    mut bytes: &[u8],
    shared: &Shared,
    notify: &UnixStream,
) -> io::Result<()> {
    while !bytes.is_empty() {
        if shared.abandon.load(Ordering::Relaxed) {
            return Ok(());
        }
        match write_some(fd, bytes)? {
            Some(n) => {
                bytes = &bytes[n..];
                shared.written.fetch_add(n as u64, Ordering::Relaxed);
                // Room for as much more, and for a caller waiting for it.
                let mut state = shared
                    .state
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                state.unwritten = state.unwritten.saturating_sub(n);
                if state.wants_room > 0 && state.room() >= state.wants_room {
                    state.wants_room = 0;
                    let _ = (&(*notify)).write(b"x");
                }
            }
            None => {
                // The terminal takes nothing now: wait until it does, or
                // until told to stop.
                let mut fds = [
                    pollfd(fd, libc::POLLOUT),
                    pollfd(notify.as_raw_fd(), libc::POLLIN),
                ];
                let millis = STOP_CHECK.as_millis() as i32;
                unsafe { libc::poll(fds.as_mut_ptr(), 2, millis) };
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sys::{poll, set_nonblocking};
    use std::{
        fs::File,
        os::fd::{FromRawFd, OwnedFd},
        thread,
    };

    /// A pipe standing in for the terminal: its read end, and its write
    /// end, non-blocking as `TerminalOutput` makes the terminal.
    fn terminal() -> (File, OwnedFd) {
        let mut fds = [0; 2];
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        set_nonblocking(fds[1]).unwrap();
        unsafe { (File::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) }
    }

    fn read_all(mut read: File) -> thread::JoinHandle<Vec<u8>> {
        thread::spawn(move || {
            let mut all = Vec::new();
            read.read_to_end(&mut all).unwrap();
            all
        })
    }

    /// Queue all of `bytes`, waiting for room as the attachment does.
    fn push_all(writer: &Writer, mut bytes: &[u8]) {
        while !bytes.is_empty() {
            let n = writer.push(bytes).unwrap();
            bytes = &bytes[n..];
            if n == 0 && writer.arm(bytes.len()) {
                let mut fds = [pollfd(writer.wake_fd(), libc::POLLIN)];
                poll(&mut fds, Duration::from_secs(5)).unwrap();
                assert_ne!(fds[0].revents, 0, "no room within 5 s");
                writer.clear_wake();
            }
        }
    }

    /// Queue until the queue is full and the thread is stuck writing to a
    /// terminal that takes nothing (nobody reads).
    fn fill(writer: &Writer) -> usize {
        let chunk = vec![b'x'; 64 * 1024];
        let mut queued = 0;
        loop {
            match writer.push(&chunk).unwrap() {
                0 => {
                    // The thread may not have taken its first batch yet.
                    let written = writer.written();
                    thread::sleep(Duration::from_millis(100));
                    if writer.written() == written {
                        // Counted when room came after all: the thread
                        // took its batch between the two pushes.
                        match writer.push(&chunk).unwrap() {
                            0 => return queued,
                            n => queued += n,
                        }
                    }
                }
                n => queued += n,
            }
        }
    }

    #[test]
    fn output_is_written_in_order_whether_written_directly_or_queued() {
        let (read, write) = terminal();
        let reader = read_all(read);
        let mut writer = Writer::start(write.as_raw_fd()).unwrap();
        let mut expected = Vec::new();
        for i in 0..3000usize {
            // Echo-sized pieces (written directly when nothing is queued)
            // between frames larger than the queue.
            let len = if i % 50 == 0 { 300_000 } else { i % 1500 + 1 };
            let piece: Vec<u8> = (0..len).map(|j| (i * 31 + j) as u8).collect();
            push_all(&writer, &piece);
            expected.extend_from_slice(&piece);
        }
        writer.finish(Duration::from_secs(5), || false);
        drop(write);
        let written = reader.join().unwrap();
        assert!(
            written == expected,
            "{} of {} bytes, out of order",
            written.len(),
            expected.len()
        );
        assert_eq!(writer.written(), expected.len() as u64);
    }

    #[test]
    fn a_full_queue_wakes_the_caller_once_the_terminal_takes_some() {
        let (read, write) = terminal();
        let mut writer = Writer::start(write.as_raw_fd()).unwrap();
        let queued = fill(&writer);
        assert!(queued >= QUEUE_BYTES, "{queued}");
        assert!(writer.arm(1), "the queue is full");
        let mut fds = [pollfd(writer.wake_fd(), libc::POLLIN)];
        poll(&mut fds, Duration::from_millis(200)).unwrap();
        assert_eq!(fds[0].revents, 0, "woken while the terminal took nothing");
        // The terminal reads again: the thread makes room and says so.
        let reader = read_all(read);
        let mut fds = [pollfd(writer.wake_fd(), libc::POLLIN)];
        poll(&mut fds, Duration::from_secs(5)).unwrap();
        assert_ne!(fds[0].revents, 0, "not woken");
        assert!(!writer.clear_wake(), "the thread still runs");
        assert_eq!(writer.push(b"more").unwrap(), 4);
        writer.finish(Duration::from_secs(5), || false);
        drop(write);
        let written = reader.join().unwrap();
        assert_eq!(written.len(), queued + 4);
        assert!(written.ends_with(b"xmore"));
    }

    #[test]
    fn room_comes_back_as_the_terminal_takes_output_not_a_queue_at_a_time() {
        let (mut read, write) = terminal();
        let mut writer = Writer::start(write.as_raw_fd()).unwrap();
        fill(&writer);
        assert_eq!(writer.room(), 0);
        // Waiting for more room than a step is waiting for a step.
        assert!(writer.arm(1024 * 1024));
        // The terminal takes a little: the thread, still writing what it
        // took from the queue, makes room for that much and wakes the
        // caller for it.
        let mut buffer = vec![0; 64 * 1024];
        let mut taken = 0;
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let mut fds = [pollfd(writer.wake_fd(), libc::POLLIN)];
            poll(&mut fds, Duration::ZERO).unwrap();
            if fds[0].revents != 0 {
                break;
            }
            assert!(Instant::now() < deadline, "not woken");
            taken += read.read(&mut buffer[..4096]).unwrap();
            thread::sleep(Duration::from_millis(2));
        }
        writer.clear_wake();
        let room = writer.room();
        assert!(room >= ROOM_STEP, "{room}");
        // Far less than the queue: what the terminal took, and what the
        // thread wrote to it since (the pipe's buffer).
        assert!(room <= taken + 128 * 1024, "{room} after {taken}");
        assert!(room < QUEUE_BYTES, "{room}");
        // A caller that waits for less is woken for as much.
        assert!(!writer.arm(1), "there is room");
        let reader = thread::spawn(move || {
            let mut all = Vec::new();
            read.read_to_end(&mut all).unwrap();
            all.len()
        });
        writer.finish(Duration::from_secs(5), || false);
        drop(write);
        reader.join().unwrap();
    }

    #[test]
    fn the_caller_is_woken_once_the_thread_took_what_was_queued() {
        let (read, write) = terminal();
        let mut writer = Writer::start(write.as_raw_fd()).unwrap();
        // Nothing queued: nothing to wait for.
        assert!(writer.drained());
        assert!(!writer.arm_drained());
        // Queued behind a terminal that takes nothing: the thread holds
        // one batch and the rest waits.
        fill(&writer);
        assert!(!writer.drained());
        assert!(writer.arm_drained());
        let mut fds = [pollfd(writer.wake_fd(), libc::POLLIN)];
        poll(&mut fds, Duration::from_millis(200)).unwrap();
        assert_eq!(fds[0].revents, 0, "woken while the queue waited");
        // The terminal reads: the thread takes the queue and says so.
        let reader = read_all(read);
        let mut fds = [pollfd(writer.wake_fd(), libc::POLLIN)];
        poll(&mut fds, Duration::from_secs(5)).unwrap();
        assert_ne!(fds[0].revents, 0, "not woken");
        writer.clear_wake();
        writer.finish(Duration::from_secs(5), || false);
        assert!(writer.drained());
        drop(write);
        reader.join().unwrap();
    }

    #[test]
    fn finishing_gives_up_on_a_terminal_that_takes_nothing() {
        let (_read, write) = terminal();
        let mut writer = Writer::start(write.as_raw_fd()).unwrap();
        fill(&writer);
        let started = Instant::now();
        writer.finish(Duration::from_millis(300), || false);
        let waited = started.elapsed();
        assert!(waited >= Duration::from_millis(300), "{waited:?}");
        assert!(waited < Duration::from_millis(1500), "{waited:?}");
        // Nothing is queued once finished.
        assert_eq!(writer.push(b"late").unwrap(), 0);

        // Told to stop (a termination signal), it stops at once.
        let (_read, write) = terminal();
        let mut writer = Writer::start(write.as_raw_fd()).unwrap();
        fill(&writer);
        let started = Instant::now();
        writer.finish(Duration::from_secs(15), || true);
        assert!(started.elapsed() < Duration::from_millis(500));
    }

    #[test]
    fn a_failed_write_is_reported_to_the_caller() {
        let (read, write) = terminal();
        drop(read);
        let writer = Writer::start(write.as_raw_fd()).unwrap();
        // Written directly: the error is the caller's at once.
        let error = writer.push(b"x").unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::BrokenPipe);
        // Written by the thread: every push after it fails.
        assert!(writer.push(&vec![b'x'; 64 * 1024]).unwrap() > 0);
        let deadline = Instant::now() + Duration::from_secs(5);
        let error = loop {
            match writer.push(b"y") {
                Err(error) => break error,
                Ok(_) => assert!(Instant::now() < deadline, "the failure was not reported"),
            }
            thread::sleep(Duration::from_millis(5));
        };
        assert_eq!(error.kind(), io::ErrorKind::BrokenPipe);
        assert!(!writer.arm(1), "a failed writer is never waited for");
    }
}
