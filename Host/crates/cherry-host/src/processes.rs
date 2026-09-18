//! Enumerate live members of the PTY's kernel session. Never use persisted PIDs.
#[cfg(target_os = "macos")]
#[link(name = "proc")]
unsafe extern "C" {
    fn proc_listallpids(buffer: *mut libc::c_void, buffersize: libc::c_int) -> libc::c_int;
}

pub fn session_members(leader: libc::pid_t) -> Vec<libc::pid_t> {
    #[cfg(target_os = "macos")]
    let candidates = unsafe {
        let count = proc_listallpids(std::ptr::null_mut(), 0).max(0) as usize;
        let mut pids = vec![0i32; count + 128];
        let used = proc_listallpids(
            pids.as_mut_ptr().cast(),
            (pids.len() * std::mem::size_of::<i32>()) as i32,
        )
        .max(0) as usize;
        pids.truncate(used.min(pids.len()));
        pids
    };
    #[cfg(target_os = "linux")]
    let candidates: Vec<libc::pid_t> = std::fs::read_dir("/proc")
        .into_iter()
        .flatten()
        .filter_map(|entry| entry.ok()?.file_name().to_str()?.parse().ok())
        .collect();
    candidates
        .into_iter()
        .filter(|pid| *pid > 0 && unsafe { libc::getsid(*pid) } == leader)
        .collect()
}

pub fn terminate_session(leader: libc::pid_t) {
    // The caller still owns the unreaped leader, reserving this session ID.
    // Stop the leader first, then its jobs, before signalling every live member;
    // job-control shells put background jobs in different process groups.
    unsafe {
        libc::kill(leader, libc::SIGSTOP);
    }
    for _ in 0..2 {
        for pid in session_members(leader) {
            if unsafe { libc::getsid(pid) } == leader {
                unsafe {
                    libc::kill(pid, libc::SIGSTOP);
                }
            }
        }
    }
    for pid in session_members(leader) {
        if pid != leader && unsafe { libc::getsid(pid) } == leader {
            unsafe {
                libc::kill(pid, libc::SIGKILL);
            }
        }
    }
    unsafe {
        libc::kill(leader, libc::SIGKILL);
    }
}

/// Observe exit without reaping: the kernel reserves the leader's PID while we
/// clean up its remaining terminal jobs, avoiding a reused-session-ID race.
pub fn exit_pending(pid: libc::pid_t) -> bool {
    unsafe {
        let mut info: libc::siginfo_t = std::mem::zeroed();
        libc::waitid(
            libc::P_PID,
            pid as libc::id_t,
            &mut info,
            libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
        ) == 0
            && info.si_pid() == pid
    }
}
