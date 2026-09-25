//! Event-driven wakeups. A daemon session worker sleeps until a connection
//! or its holder has something for it (`Wake`). A holder turns SIGCHLD into
//! a readable byte (`child_exits`), so it can sleep until its child exits
//! instead of polling for it.
use std::{
    io::{self, Read, Write},
    os::unix::{io::IntoRawFd, net::UnixStream},
    sync::{
        atomic::{AtomicI32, Ordering},
        Arc,
    },
};

/// The sending half of a worker's wake socket.
pub struct Wake(UnixStream);

impl Wake {
    /// A wake handle and the receiving end for `poll`.
    pub fn pair() -> io::Result<(Arc<Self>, UnixStream)> {
        let (sender, receiver) = UnixStream::pair()?;
        sender.set_nonblocking(true)?;
        receiver.set_nonblocking(true)?;
        Ok((Arc::new(Self(sender)), receiver))
    }

    pub fn wake(&self) {
        // A full buffer already guarantees a pending wakeup.
        let _ = (&self.0).write(&[1]);
    }
}

/// Discard queued wake bytes.
pub fn drain(receiver: &UnixStream) {
    let mut buffer = [0u8; 256];
    while (&*receiver).read(&mut buffer).is_ok_and(|n| n > 0) {}
}

static SIGNAL_PIPE: AtomicI32 = AtomicI32::new(-1);

extern "C" fn on_child(_: libc::c_int) {
    let fd = SIGNAL_PIPE.load(Ordering::Relaxed);
    if fd >= 0 {
        unsafe {
            let errno = errno();
            let saved = *errno;
            libc::write(fd, [1u8].as_ptr().cast(), 1);
            *errno = saved;
        }
    }
}

#[cfg(target_os = "macos")]
unsafe fn errno() -> *mut libc::c_int {
    libc::__error()
}
#[cfg(not(target_os = "macos"))]
unsafe fn errno() -> *mut libc::c_int {
    libc::__errno_location()
}

/// A socket that becomes readable whenever a child process exits (drain it
/// with `drain`). Installs the SIGCHLD handler: once per process, before the
/// first child is started, so no exit is missed.
pub fn child_exits() -> io::Result<UnixStream> {
    let (receiver, sender) = UnixStream::pair()?;
    sender.set_nonblocking(true)?;
    receiver.set_nonblocking(true)?;
    SIGNAL_PIPE.store(sender.into_raw_fd(), Ordering::SeqCst);
    unsafe {
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = on_child as extern "C" fn(libc::c_int) as libc::sighandler_t;
        action.sa_flags = libc::SA_RESTART | libc::SA_NOCLDSTOP;
        libc::sigemptyset(&mut action.sa_mask);
        if libc::sigaction(libc::SIGCHLD, &action, std::ptr::null_mut()) != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(receiver)
}
