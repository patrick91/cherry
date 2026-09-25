//! Notice entries appearing in a directory without polling it: a holder
//! waiting for a daemon learns the moment one binds its socket. kqueue on
//! macOS, inotify on Linux. Anything that fails here only means the holder
//! redials on its timer instead.
use std::{
    os::unix::io::{AsRawFd, FromRawFd, OwnedFd, RawFd},
    path::Path,
};

/// A descriptor that becomes readable when the directory's entries change,
/// and stays readable: it is used once, then replaced.
pub struct DirWatch {
    queue: OwnedFd,
    /// The watched directory (kqueue watches an open descriptor).
    #[cfg(target_os = "macos")]
    _dir: OwnedFd,
}

impl DirWatch {
    #[cfg(target_os = "macos")]
    pub fn new(dir: &Path) -> Option<Self> {
        use std::os::unix::ffi::OsStrExt;
        let path = std::ffi::CString::new(dir.as_os_str().as_bytes()).ok()?;
        let dir = unsafe { libc::open(path.as_ptr(), libc::O_EVTONLY | libc::O_CLOEXEC) };
        if dir < 0 {
            return None;
        }
        let dir = unsafe { OwnedFd::from_raw_fd(dir) };
        let queue = unsafe { libc::kqueue() };
        if queue < 0 {
            return None;
        }
        let queue = unsafe { OwnedFd::from_raw_fd(queue) };
        unsafe {
            libc::fcntl(queue.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC);
        }
        let change = libc::kevent {
            ident: dir.as_raw_fd() as libc::uintptr_t,
            filter: libc::EVFILT_VNODE,
            flags: libc::EV_ADD | libc::EV_CLEAR,
            fflags: libc::NOTE_WRITE | libc::NOTE_DELETE | libc::NOTE_RENAME,
            data: 0,
            udata: std::ptr::null_mut(),
        };
        let added = unsafe {
            libc::kevent(
                queue.as_raw_fd(),
                &change,
                1,
                std::ptr::null_mut(),
                0,
                std::ptr::null(),
            )
        };
        (added == 0).then_some(Self { queue, _dir: dir })
    }

    #[cfg(target_os = "linux")]
    pub fn new(dir: &Path) -> Option<Self> {
        use std::os::unix::ffi::OsStrExt;
        let path = std::ffi::CString::new(dir.as_os_str().as_bytes()).ok()?;
        let queue = unsafe { libc::inotify_init1(libc::IN_NONBLOCK | libc::IN_CLOEXEC) };
        if queue < 0 {
            return None;
        }
        let queue = unsafe { OwnedFd::from_raw_fd(queue) };
        let mask = libc::IN_CREATE
            | libc::IN_MOVED_TO
            | libc::IN_ATTRIB
            | libc::IN_DELETE_SELF
            | libc::IN_MOVE_SELF;
        let watch = unsafe { libc::inotify_add_watch(queue.as_raw_fd(), path.as_ptr(), mask) };
        (watch >= 0).then_some(Self { queue })
    }

    pub fn fd(&self) -> RawFd {
        self.queue.as_raw_fd()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn readable(fd: RawFd, millis: i32) -> bool {
        let mut poll = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        unsafe { libc::poll(&mut poll, 1, millis) > 0 }
    }

    #[test]
    fn a_socket_bound_in_the_directory_is_noticed() {
        let dir = tempfile::Builder::new()
            .prefix("ch-")
            .tempdir_in("/tmp")
            .unwrap();
        let watch = DirWatch::new(dir.path()).unwrap();
        assert!(!readable(watch.fd(), 0));
        let _listener = std::os::unix::net::UnixListener::bind(dir.path().join("s")).unwrap();
        assert!(readable(watch.fd(), 5000));
    }
}
