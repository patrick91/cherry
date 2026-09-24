//! Enumerate and signal live members of a PTY's kernel session. Never use
//! persisted PIDs: members are found by session ID while the unreaped leader
//! keeps that ID reserved.
#[cfg(target_os = "macos")]
#[link(name = "proc")]
unsafe extern "C" {
    fn proc_listallpids(buffer: *mut libc::c_void, buffersize: libc::c_int) -> libc::c_int;
}

fn session_members(leader: libc::pid_t) -> Vec<libc::pid_t> {
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

/// Exited processes keep their PID until reaped but can no longer run.
fn is_zombie(pid: libc::pid_t) -> bool {
    #[cfg(target_os = "macos")]
    unsafe {
        let mut info: libc::proc_bsdinfo = std::mem::zeroed();
        let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            (&mut info as *mut libc::proc_bsdinfo).cast(),
            size,
        ) != size
            || info.pbi_status == libc::SZOMB
    }
    #[cfg(target_os = "linux")]
    {
        // The state follows the parenthesised command name, which may itself
        // contain parentheses.
        std::fs::read(format!("/proc/{pid}/stat")).map_or(true, |stat| {
            let state = stat
                .iter()
                .rposition(|&b| b == b')')
                .and_then(|end| stat.get(end + 2));
            matches!(state, None | Some(b'Z' | b'X'))
        })
    }
}

/// Members of the leader's session that can still run. The leader itself is
/// included until it has exited.
pub fn live_members(leader: libc::pid_t) -> Vec<libc::pid_t> {
    session_members(leader)
        .into_iter()
        .filter(|pid| !is_zombie(*pid))
        .collect()
}

/// Send `signal` to every live member of the leader's session, followed by
/// SIGCONT (except for SIGKILL and SIGSTOP) so stopped jobs act on it.
pub fn signal_session(leader: libc::pid_t, signal: libc::c_int) {
    signal_members(leader, live_members(leader), signal);
}

/// Signal the listed members and the leader. The leader is signalled even
/// when the listing is incomplete (an unreadable /proc, no descriptors
/// left): it is unreaped, so its PID cannot belong to anyone else.
fn signal_members(leader: libc::pid_t, members: Vec<libc::pid_t>, signal: libc::c_int) {
    let others = members.into_iter().filter(|pid| *pid != leader);
    for pid in others.chain([leader]) {
        // Re-check right before signalling: a member that exited since the
        // listing may already have a new, unrelated owner of its PID.
        if pid == leader || unsafe { libc::getsid(pid) } == leader {
            unsafe {
                libc::kill(pid, signal);
                if !matches!(signal, libc::SIGKILL | libc::SIGSTOP) {
                    libc::kill(pid, libc::SIGCONT);
                }
            }
        }
    }
}

/// The last resort: stop every member first, so none can fork a replacement
/// during the sweep, then SIGKILL them all.
pub fn kill_session(leader: libc::pid_t) {
    for _ in 0..2 {
        signal_members(leader, live_members(leader), libc::SIGSTOP);
    }
    signal_session(leader, libc::SIGKILL);
}

/// Observe exit without reaping: the kernel keeps the leader's PID, and so the
/// session ID, reserved until `reap`.
pub fn exited(pid: libc::pid_t) -> bool {
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

/// How a process ended: its exit code (128 + signal for signal deaths) and
/// the terminating signal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExitStatus {
    pub code: u32,
    pub signal: Option<i32>,
}

/// Reap an exited child.
pub fn reap(pid: libc::pid_t) -> ExitStatus {
    let mut status = 0;
    let reaped = loop {
        let result = unsafe { libc::waitpid(pid, &mut status, 0) };
        if result == -1 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted
        {
            continue;
        }
        break result == pid;
    };
    if !reaped {
        return ExitStatus {
            code: 1,
            signal: None,
        };
    }
    if libc::WIFSIGNALED(status) {
        let signal = libc::WTERMSIG(status);
        ExitStatus {
            code: 128 + signal as u32,
            signal: Some(signal),
        }
    } else {
        ExitStatus {
            code: libc::WEXITSTATUS(status) as u32,
            signal: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::process::CommandExt;

    #[test]
    fn the_leader_is_signalled_even_when_listing_members_fails() {
        let mut command = std::process::Command::new("/bin/sleep");
        command.arg("60");
        unsafe {
            command.pre_exec(|| {
                libc::setsid();
                Ok(())
            });
        }
        let leader = command.spawn().unwrap().id() as libc::pid_t;
        // As if /proc could not be read: no members were listed.
        signal_members(leader, Vec::new(), libc::SIGKILL);
        assert_eq!(
            reap(leader),
            ExitStatus {
                code: 128 + libc::SIGKILL as u32,
                signal: Some(libc::SIGKILL),
            }
        );
    }
}
