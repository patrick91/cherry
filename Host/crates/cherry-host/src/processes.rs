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
pub fn is_zombie(pid: libc::pid_t) -> bool {
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

/// How `waitid` says a child ended (`si_code`). The values are the same on
/// macOS and Linux; the libc crate spells them out only for Linux.
const CLD_EXITED: libc::c_int = 1;
const CLD_KILLED: libc::c_int = 2;
const CLD_DUMPED: libc::c_int = 3;

/// Observe exit without reaping: the kernel keeps the leader's PID, and so the
/// session ID, reserved until `reap`. A stopped or continued child has not
/// exited: macOS reports those to `waitid` even without WSTOPPED or
/// WCONTINUED, so only an exit, a killing signal or a core dump counts.
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
            && matches!(info.si_code, CLD_EXITED | CLD_KILLED | CLD_DUMPED)
    }
}

/// A process's name (the executable's, as the kernel keeps it); empty when
/// it cannot be read.
pub fn process_name(pid: libc::pid_t) -> String {
    #[cfg(target_os = "macos")]
    unsafe {
        let mut info: libc::proc_bsdinfo = std::mem::zeroed();
        let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
        if libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            (&mut info as *mut libc::proc_bsdinfo).cast(),
            size,
        ) != size
        {
            return String::new();
        }
        let name = |chars: &[libc::c_char]| {
            let bytes: Vec<u8> = chars
                .iter()
                .take_while(|&&c| c != 0)
                .map(|&c| c as u8)
                .collect();
            String::from_utf8_lossy(&bytes).into_owned()
        };
        // The long name when there is one; the short one is cut at 16.
        let long = name(&info.pbi_name);
        if long.is_empty() {
            name(&info.pbi_comm)
        } else {
            long
        }
    }
    #[cfg(target_os = "linux")]
    {
        std::fs::read_to_string(format!("/proc/{pid}/comm"))
            .map(|name| name.trim_end_matches('\n').to_string())
            .unwrap_or_default()
    }
}

/// When a process started, as a token that another process with the same
/// PID (after the PID was reused, or after a reboot) never has: the start
/// time to the microsecond on macOS; on Linux the boot and the start time
/// in clock ticks since it. None when it cannot be read.
pub fn start_identity(pid: libc::pid_t) -> Option<String> {
    #[cfg(target_os = "macos")]
    unsafe {
        let mut info: libc::proc_bsdinfo = std::mem::zeroed();
        let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
        (libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            (&mut info as *mut libc::proc_bsdinfo).cast(),
            size,
        ) == size)
            .then(|| format!("{}.{:06}", info.pbi_start_tvsec, info.pbi_start_tvusec))
    }
    #[cfg(target_os = "linux")]
    {
        let boot = std::fs::read_to_string("/proc/sys/kernel/random/boot_id").ok()?;
        let stat = std::fs::read(format!("/proc/{pid}/stat")).ok()?;
        // After the parenthesised command name: the state (field 3) comes
        // first, and the start time is field 22.
        let end = stat.iter().rposition(|&b| b == b')')?;
        let fields = std::str::from_utf8(&stat[end + 1..]).ok()?;
        let started = fields.split_ascii_whitespace().nth(22 - 3)?;
        Some(format!("{}/{started}", boot.trim()))
    }
}

/// Where this process's executable is now. The kernel follows it when it,
/// or a directory above it such as an app bundle, is moved or renamed. None
/// once it was deleted.
#[cfg(target_os = "macos")]
pub fn own_executable() -> Option<std::path::PathBuf> {
    use std::os::unix::ffi::OsStringExt;
    let mut buffer = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    let length = unsafe {
        libc::proc_pidpath(
            libc::getpid(),
            buffer.as_mut_ptr().cast(),
            buffer.len() as u32,
        )
    };
    if length <= 0 {
        return None;
    }
    buffer.truncate(length as usize);
    Some(std::ffi::OsString::from_vec(buffer).into())
}

/// How a process ended: its exit code (128 + signal for signal deaths) and
/// the terminating signal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExitStatus {
    pub code: u32,
    pub signal: Option<i32>,
}

/// Reap an exited child. Never blocks: None while the child has not exited
/// (a stopped one has not), so the caller tries again when it does. A child
/// that cannot be waited for (someone else reaped it) ended with code 1.
pub fn reap(pid: libc::pid_t) -> Option<ExitStatus> {
    let mut status = 0;
    let result = loop {
        let result = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
        if result == -1 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted
        {
            continue;
        }
        break result;
    };
    let ended = result == pid && (libc::WIFEXITED(status) || libc::WIFSIGNALED(status));
    if result == 0 || (result == pid && !ended) {
        return None;
    }
    if !ended {
        return Some(ExitStatus {
            code: 1,
            signal: None,
        });
    }
    Some(if libc::WIFSIGNALED(status) {
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
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::process::CommandExt;

    #[test]
    fn a_start_identity_tells_processes_apart() {
        let own = start_identity(unsafe { libc::getpid() });
        assert!(own.is_some());
        assert_eq!(start_identity(unsafe { libc::getpid() }), own);
        // Started later than this process: another identity.
        std::thread::sleep(std::time::Duration::from_millis(20));
        let mut child = std::process::Command::new("/bin/sleep")
            .arg("60")
            .spawn()
            .unwrap();
        let other = start_identity(child.id() as libc::pid_t);
        child.kill().unwrap();
        child.wait().unwrap();
        assert!(other.is_some());
        assert_ne!(other, own);
    }

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
            reap_within(leader, Duration::from_secs(5)),
            ExitStatus {
                code: 128 + libc::SIGKILL as u32,
                signal: Some(libc::SIGKILL),
            }
        );
    }

    use std::time::{Duration, Instant};

    /// Reap `pid` once it exits.
    fn reap_within(pid: libc::pid_t, timeout: Duration) -> ExitStatus {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(status) = reap(pid) {
                return status;
            }
            assert!(Instant::now() < deadline, "{pid} did not exit");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    /// Until `pid`'s state (as `ps` shows it) starts with `state`.
    fn wait_for_state(pid: libc::pid_t, state: char) {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let output = std::process::Command::new("/bin/ps")
                .args(["-p", &pid.to_string(), "-o", "stat="])
                .output()
                .unwrap();
            if String::from_utf8_lossy(&output.stdout)
                .trim()
                .starts_with(state)
            {
                return;
            }
            assert!(Instant::now() < deadline, "{pid} never reached {state}");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn a_stopped_or_continued_child_has_not_exited_and_reaping_it_does_not_block() {
        let pid = std::process::Command::new("/bin/sleep")
            .arg("60")
            .spawn()
            .unwrap()
            .id() as libc::pid_t;
        // Killed however the test ends, until it is reaped.
        struct Kill(Option<libc::pid_t>);
        impl Drop for Kill {
            fn drop(&mut self) {
                if let Some(pid) = self.0 {
                    unsafe {
                        libc::kill(pid, libc::SIGKILL);
                        libc::waitpid(pid, std::ptr::null_mut(), 0);
                    }
                }
            }
        }
        let mut kill = Kill(Some(pid));
        assert!(!exited(pid));
        assert_eq!(reap(pid), None);
        unsafe { libc::kill(pid, libc::SIGSTOP) };
        wait_for_state(pid, 'T');
        // Stopped: macOS's waitid reports it (CLD_STOPPED) although only
        // exits were asked for.
        for _ in 0..3 {
            assert!(!exited(pid));
            assert_eq!(reap(pid), None);
        }
        unsafe { libc::kill(pid, libc::SIGCONT) };
        std::thread::sleep(Duration::from_millis(50));
        assert!(!exited(pid));
        assert_eq!(reap(pid), None);
        // Killed while stopped: now it has exited.
        unsafe { libc::kill(pid, libc::SIGSTOP) };
        wait_for_state(pid, 'T');
        unsafe { libc::kill(pid, libc::SIGKILL) };
        let deadline = Instant::now() + Duration::from_secs(5);
        while !exited(pid) {
            assert!(Instant::now() < deadline, "the kill was never seen");
            std::thread::sleep(Duration::from_millis(10));
        }
        // Observed without reaping: it is still there to reap.
        assert!(exited(pid));
        assert_eq!(
            reap(pid),
            Some(ExitStatus {
                code: 128 + libc::SIGKILL as u32,
                signal: Some(libc::SIGKILL),
            })
        );
        kill.0 = None;
        // Reaped: nothing left to wait for.
        assert!(!exited(pid));
    }
}
