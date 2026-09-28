//! Scheduling and socket tuning for the threads that carry an attached
//! renderer's traffic: keystrokes one way and the program's frames the other
//! cross the attach adapter, the daemon's connection threads and session
//! worker, and the session's holder. Each hop is a thread wakeup, and on a
//! busy machine a wakeup at the default priority can wait 10–40 ms behind
//! other work, while the program (Neovim raises its own priority) and the
//! terminal do not. Those threads run at `QOS_CLASS_USER_INTERACTIVE` while
//! a renderer is attached (`interactive(true)`) and at the default class
//! otherwise, so the output of a session nobody watches never competes with
//! the ones on screen.
//!
//! macOS squashes `USER_INTERACTIVE` (and `USER_INITIATED`) to the default
//! priority in a process without an application role, which a command-line
//! program or daemon does not have. `prepare_process` gives the process the
//! role `TASK_DEFAULT_APPLICATION`, as Neovim does (`os_hint_priority`),
//! which lifts that ceiling and changes nothing for threads at the default
//! class. A process it starts does not inherit the role, so the programs in
//! sessions keep the priority they had. A process's first thread may start
//! with the class of whoever started it (a terminal's, say), so it is set
//! to the default class explicitly, as every thread that uses
//! `interactive` sets its own before it matters.
//!
//! On Linux a thread's priority can be raised (a lower nice value) only
//! with `CAP_SYS_NICE` or an `RLIMIT_NICE` allowance, and lowered for good
//! otherwise, so these calls do nothing there; the kernel's scheduler
//! already favours threads that mostly sleep and wake briefly.
use std::{cell::Cell, os::unix::io::RawFd};

/// Unix socket send buffers are raised to this, or to the largest the
/// system allows. macOS gives Unix sockets 8 KiB, so a frame of a
/// full-screen program's output (10–20 KiB) took several writes and wakeups
/// per hop, and output that waited behind a partial write was merged with
/// the next frame. How much a Unix stream socket holds is its sender's send
/// buffer alone (macOS and Linux alike: the receiver's receive buffer
/// limits nothing, so it is left as it is), so the ends that send output
/// raise theirs (`grow_send_buffer`: both ends of the holder link, the
/// daemon's end of client connections). A client's end keeps the system's
/// buffers: what it sends is input, so the input backpressure and what a
/// detach discards stay as they were.
pub const SOCKET_BUFFER_BYTES: usize = 1024 * 1024;
/// Smaller buffers than this are not worth asking for.
const MIN_SOCKET_BUFFER_BYTES: usize = 64 * 1024;

thread_local! {
    /// Whether the calling thread was last set interactive; None before it
    /// was set at all.
    static INTERACTIVE: Cell<Option<bool>> = const { Cell::new(None) };
}

/// Prepare this process for `interactive`: on macOS, the application role
/// that lets its threads' QoS take effect, and the default class for the
/// calling thread (see the module documentation). Call it once, early, on
/// the main thread of the daemon, of each holder and of an attachment.
pub fn prepare_process() {
    #[cfg(target_os = "macos")]
    macos::take_application_role();
    INTERACTIVE.with(|state| state.set(None));
    interactive(false);
}

/// Run the calling thread at `QOS_CLASS_USER_INTERACTIVE` while `on`
/// (it serves an attached renderer), and at the default class otherwise.
/// Cheap when nothing changes. Does nothing but remember the choice
/// outside macOS.
pub fn interactive(on: bool) {
    INTERACTIVE.with(|state| {
        if state.get() == Some(on) {
            return;
        }
        state.set(Some(on));
        #[cfg(target_os = "macos")]
        macos::set_class(on);
    });
}

/// Whether the calling thread was last set interactive (`interactive`).
pub fn is_interactive() -> bool {
    INTERACTIVE.with(|state| state.get() == Some(true))
}

/// Raise a Unix socket's send buffer toward `SOCKET_BUFFER_BYTES`, as far
/// as the system allows (macOS refuses more than `kern.ipc.maxsockbuf`
/// allows; Linux caps it at `net.core.wmem_max` itself). Never lowers it;
/// failures are ignored, since only latency depends on it. For an end that
/// sends output.
pub fn grow_send_buffer(fd: RawFd) {
    let option = libc::SO_SNDBUF;
    if socket_buffer(fd, option).is_some_and(|size| size >= SOCKET_BUFFER_BYTES) {
        return;
    }
    let mut size = SOCKET_BUFFER_BYTES;
    while size >= MIN_SOCKET_BUFFER_BYTES {
        let value = size as libc::c_int;
        let set = unsafe {
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                option,
                (&value as *const libc::c_int).cast(),
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            )
        };
        if set == 0 {
            return;
        }
        size /= 2;
    }
}

/// A socket's `SO_SNDBUF` or `SO_RCVBUF`, as the system reports it.
pub fn socket_buffer(fd: RawFd, option: libc::c_int) -> Option<usize> {
    let mut value: libc::c_int = 0;
    let mut len = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
    let got = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            option,
            (&mut value as *mut libc::c_int).cast(),
            &mut len,
        )
    };
    (got == 0).then_some(value.max(0) as usize)
}

#[cfg(target_os = "macos")]
mod macos {
    /// `TASK_CATEGORY_POLICY` and `TASK_DEFAULT_APPLICATION` from
    /// `mach/task_policy.h`.
    const TASK_CATEGORY_POLICY: u32 = 1;
    const TASK_DEFAULT_APPLICATION: i32 = 7;

    // Declared here: libc's Mach bindings are deprecated.
    extern "C" {
        static mach_task_self_: libc::mach_port_t;
        fn task_policy_set(
            task: libc::mach_port_t,
            flavor: u32,
            policy_info: *mut i32,
            count: u32,
        ) -> libc::kern_return_t;
    }

    pub fn take_application_role() {
        let mut role = TASK_DEFAULT_APPLICATION;
        // Fails only in a sandbox that forbids it: the threads then keep the
        // default priority, as before.
        unsafe {
            task_policy_set(mach_task_self_, TASK_CATEGORY_POLICY, &mut role, 1);
        }
    }

    pub fn set_class(interactive: bool) {
        let class = if interactive {
            libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE
        } else {
            libc::qos_class_t::QOS_CLASS_DEFAULT
        };
        unsafe {
            libc::pthread_set_qos_class_self_np(class, 0);
        }
    }

    /// The calling thread's scheduling priority, for tests.
    #[cfg(test)]
    pub fn thread_priority() -> i32 {
        extern "C" {
            fn mach_thread_self() -> libc::mach_port_t;
            fn mach_port_deallocate(
                task: libc::mach_port_t,
                name: libc::mach_port_t,
            ) -> libc::kern_return_t;
            fn thread_info(
                thread: libc::mach_port_t,
                flavor: u32,
                info: *mut i32,
                count: *mut u32,
            ) -> libc::kern_return_t;
        }
        unsafe {
            let thread = mach_thread_self();
            let mut info: libc::thread_extended_info = std::mem::zeroed();
            let mut count = libc::THREAD_EXTENDED_INFO_COUNT;
            let result = thread_info(
                thread,
                libc::THREAD_EXTENDED_INFO as u32,
                (&mut info as *mut libc::thread_extended_info).cast(),
                &mut count,
            );
            mach_port_deallocate(mach_task_self_, thread);
            assert_eq!(result, 0, "thread_info");
            info.pth_priority
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::{io::AsRawFd, net::UnixStream};

    /// The calling thread's priority where it can be read.
    fn priority() -> Option<i32> {
        #[cfg(target_os = "macos")]
        return Some(macos::thread_priority());
        #[cfg(not(target_os = "macos"))]
        None
    }

    #[test]
    fn attached_threads_run_above_the_default_priority_and_return_to_it() {
        // Measured on threads nothing joins meanwhile: a thread waiting in
        // join lends the joined thread its priority.
        let (sender, receiver) = std::sync::mpsc::channel();
        let thread = std::thread::spawn(move || {
            prepare_process();
            let prepared = (is_interactive(), priority());
            interactive(true);
            let raised = (is_interactive(), priority());
            // Another thread started meanwhile is not affected.
            let (other_sender, other_receiver) = std::sync::mpsc::channel();
            let other = std::thread::spawn(move || {
                other_sender.send((is_interactive(), priority())).unwrap();
            });
            let other_state = other_receiver.recv().unwrap();
            other.join().unwrap();
            interactive(false);
            let lowered = (is_interactive(), priority());
            sender
                .send((prepared, raised, other_state, lowered))
                .unwrap();
        });
        let (prepared, raised, other, lowered) = receiver.recv().unwrap();
        thread.join().unwrap();
        assert!(!prepared.0 && raised.0 && !other.0 && !lowered.0);
        if let (Some(prepared), Some(raised), Some(other), Some(lowered)) =
            (prepared.1, raised.1, other.1, lowered.1)
        {
            // A QoS clamp on whatever started the tests (`taskpolicy -c
            // utility`, a CI runner's launchd job) caps this process below
            // the default priority, where no class can raise a thread.
            if prepared < 31 {
                eprintln!("QoS is clamped here: the default class runs at {prepared}");
                for (what, priority) in [("raised", raised), ("other", other), ("lowered", lowered)]
                {
                    assert!(priority <= prepared, "{what}: {priority}");
                }
                return;
            }
            // Without the application role, macOS would keep it at 31.
            assert!(raised > 40, "raised to {raised}");
            for (what, priority) in [
                ("prepared", prepared),
                ("other", other),
                ("lowered", lowered),
            ] {
                assert_eq!(priority, 31, "{what}");
            }
        }
    }

    /// Bytes a nonblocking write to `socket` takes while its peer reads
    /// nothing.
    fn holds(socket: &UnixStream) -> usize {
        socket.set_nonblocking(true).unwrap();
        let chunk = vec![b'x'; 64 * 1024];
        let mut held = 0;
        loop {
            let written =
                unsafe { libc::write(socket.as_raw_fd(), chunk.as_ptr().cast(), chunk.len()) };
            if written <= 0 {
                return held;
            }
            held += written as usize;
        }
    }

    #[test]
    fn send_buffers_grow_so_a_frame_travels_in_one_write() {
        let (ours, theirs) = UnixStream::pair().unwrap();
        let before = socket_buffer(ours.as_raw_fd(), libc::SO_SNDBUF).unwrap();
        let receive = socket_buffer(ours.as_raw_fd(), libc::SO_RCVBUF).unwrap();
        grow_send_buffer(ours.as_raw_fd());
        let after = socket_buffer(ours.as_raw_fd(), libc::SO_SNDBUF).unwrap();
        assert!(after >= before, "{after} < {before}");
        #[cfg(target_os = "macos")]
        assert_eq!(after, SOCKET_BUFFER_BYTES);
        assert_eq!(
            socket_buffer(ours.as_raw_fd(), libc::SO_RCVBUF),
            Some(receive)
        );
        // Growing again changes nothing.
        grow_send_buffer(ours.as_raw_fd());
        assert_eq!(
            socket_buffer(ours.as_raw_fd(), libc::SO_SNDBUF),
            Some(after)
        );
        // What a Unix stream holds is its sender's send buffer: a full-screen
        // frame goes in one nonblocking write, where 8 KiB buffers (macOS)
        // took several, and the peer's receive buffer adds nothing.
        #[cfg(target_os = "macos")]
        assert!(holds(&ours) >= 256 * 1024);
        let (plain, _plain_peer) = UnixStream::pair().unwrap();
        let (sender, receiver) = UnixStream::pair().unwrap();
        let size = SOCKET_BUFFER_BYTES as libc::c_int;
        unsafe {
            libc::setsockopt(
                receiver.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_RCVBUF,
                (&size as *const libc::c_int).cast(),
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            );
        }
        assert_eq!(holds(&sender), holds(&plain));
        drop(theirs);
    }
}
