//! Signals, polling and non-blocking descriptor helpers.
use anyhow::{bail, Context, Result};
use std::{
    cell::RefCell,
    io,
    os::fd::RawFd,
    sync::{
        atomic::{AtomicBool, AtomicI32, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};

static TERMINATION_SIGNAL: AtomicI32 = AtomicI32::new(0);
static RESIZE_PENDING: AtomicBool = AtomicBool::new(false);

thread_local! {
    /// Set on a thread whose work another thread may abandon (an
    /// attachment's attempt to connect again): see `abandon_when`.
    static ABANDONED: RefCell<Option<Arc<AtomicBool>>> = const { RefCell::new(None) };
}

/// From now on, `interrupted` on this thread fails once `flag` is set, as
/// it does after a termination signal: every wait checks it at least every
/// 100 ms.
pub fn abandon_when(flag: Arc<AtomicBool>) {
    ABANDONED.with(|abandoned| *abandoned.borrow_mut() = Some(flag));
}

extern "C" fn handle_signal(signal: libc::c_int) {
    if signal == libc::SIGWINCH {
        RESIZE_PENDING.store(true, Ordering::Relaxed);
    } else {
        TERMINATION_SIGNAL.store(signal, Ordering::Relaxed);
    }
}

/// The termination signal received so far, if any.
pub fn termination_signal() -> Option<i32> {
    match TERMINATION_SIGNAL.load(Ordering::Relaxed) {
        0 => None,
        signal => Some(signal),
    }
}

/// True once per burst of SIGWINCH.
pub fn take_resize() -> bool {
    RESIZE_PENDING.swap(false, Ordering::Relaxed)
}

pub fn interrupted() -> Result<()> {
    if let Some(signal) = termination_signal() {
        bail!("interrupted by signal {signal}");
    }
    let abandoned = ABANDONED.with(|abandoned| {
        abandoned
            .borrow()
            .as_ref()
            .is_some_and(|flag| flag.load(Ordering::Relaxed))
    });
    if abandoned {
        bail!("abandoned");
    }
    Ok(())
}

pub struct SignalGuard {
    saved: Vec<(i32, libc::sigaction)>,
}

impl SignalGuard {
    pub fn install() -> Result<Self> {
        let mut guard = Self { saved: Vec::new() };
        for signal in [
            libc::SIGWINCH,
            libc::SIGINT,
            libc::SIGTERM,
            libc::SIGHUP,
            libc::SIGQUIT,
            libc::SIGPIPE,
        ] {
            let mut action = unsafe { std::mem::zeroed::<libc::sigaction>() };
            let mut previous = unsafe { std::mem::zeroed::<libc::sigaction>() };
            action.sa_sigaction = if signal == libc::SIGPIPE {
                libc::SIG_IGN
            } else {
                handle_signal as *const () as usize
            };
            // No SA_RESTART: a signal interrupts poll() so it is noticed promptly.
            unsafe {
                libc::sigemptyset(&mut action.sa_mask);
            }
            if unsafe { libc::sigaction(signal, &action, &mut previous) } != 0 {
                return Err(io::Error::last_os_error())
                    .context("could not install terminal signal handler");
            }
            guard.saved.push((signal, previous));
        }
        Ok(guard)
    }
}

impl Drop for SignalGuard {
    fn drop(&mut self) {
        for (signal, previous) in self.saved.iter().rev() {
            unsafe {
                libc::sigaction(*signal, previous, std::ptr::null_mut());
            }
        }
    }
}

pub fn set_nonblocking(fd: RawFd) -> Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error()).context("could not configure host transport");
    }
    Ok(())
}

/// A regular file or /dev/null: reading and writing never wait. Darwin's
/// poll rejects both even though read and write work; a file has bytes or
/// its end available at once, and null is always at its end.
pub fn never_waits(fd: RawFd) -> bool {
    let mut info = unsafe { std::mem::zeroed::<libc::stat>() };
    if unsafe { libc::fstat(fd, &mut info) } != 0 {
        return false;
    }
    if info.st_mode & libc::S_IFMT == libc::S_IFREG {
        return true;
    }
    if info.st_mode & libc::S_IFMT != libc::S_IFCHR {
        return false;
    }
    let mut null_info = unsafe { std::mem::zeroed::<libc::stat>() };
    unsafe {
        libc::stat(c"/dev/null".as_ptr(), &mut null_info) == 0 && info.st_rdev == null_info.st_rdev
    }
}

pub fn pollfd(fd: RawFd, events: libc::c_short) -> libc::pollfd {
    libc::pollfd {
        fd,
        events,
        revents: 0,
    }
}

/// poll(2) that treats EINTR as a timeout. Entries with a negative fd are
/// ignored by the kernel.
pub fn poll(fds: &mut [libc::pollfd], timeout: Duration) -> Result<()> {
    // Round up so a sub-millisecond wait does not become a busy loop.
    let millis = timeout.as_micros().div_ceil(1000).min(i32::MAX as u128) as i32;
    let result = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, millis) };
    if result < 0 {
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error).context("host transport polling failed");
        }
        for fd in fds.iter_mut() {
            fd.revents = 0;
        }
    }
    for fd in fds {
        if fd.fd >= 0 && fd.revents & libc::POLLNVAL != 0 {
            bail!("host transport file descriptor closed");
        }
    }
    Ok(())
}

/// Write everything, failing only when the descriptor accepts nothing for
/// `idle` (or a termination signal arrives, when `check_signals` is set).
pub fn write_all(fd: RawFd, mut bytes: &[u8], idle: Duration, check_signals: bool) -> Result<()> {
    let mut deadline = Instant::now() + idle;
    while !bytes.is_empty() {
        if check_signals {
            interrupted()?;
        }
        if let Some(n) = write_some(fd, bytes)? {
            bytes = &bytes[n..];
            deadline = Instant::now() + idle;
            continue;
        }
        let now = Instant::now();
        if now >= deadline {
            bail!(blocked_output(idle));
        }
        let mut fds = [pollfd(fd, libc::POLLOUT)];
        poll(
            &mut fds,
            Duration::from_millis(100).min(deadline.saturating_duration_since(now)),
        )?;
    }
    Ok(())
}

pub fn blocked_output(idle: Duration) -> String {
    format!(
        "output is blocked; nothing was written for {} s",
        idle.as_secs()
    )
}

/// One non-blocking write of a non-empty buffer. `Ok(None)` means the
/// descriptor accepts nothing right now.
pub fn write_some(fd: RawFd, bytes: &[u8]) -> io::Result<Option<usize>> {
    let n = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
    if n > 0 {
        return Ok(Some(n as usize));
    }
    if n == 0 {
        return Err(io::Error::new(
            io::ErrorKind::WriteZero,
            "output stopped accepting data",
        ));
    }
    let error = io::Error::last_os_error();
    match error.kind() {
        io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted => Ok(None),
        _ => Err(error),
    }
}

/// One non-blocking read. `Ok(None)` means nothing is available right now,
/// `Ok(Some(0))` end of file.
pub fn read_some(fd: RawFd, buffer: &mut [u8]) -> io::Result<Option<usize>> {
    let n = unsafe { libc::read(fd, buffer.as_mut_ptr().cast(), buffer.len()) };
    if n >= 0 {
        return Ok(Some(n as usize));
    }
    let error = io::Error::last_os_error();
    match error.kind() {
        io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted => Ok(None),
        _ => Err(error),
    }
}
