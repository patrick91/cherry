//! Regressions for owning a process session independently of its attachments.
mod support;

use cherry_protocol::*;
use std::{
    fs,
    io::Write,
    net::Shutdown,
    process::Command,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    },
    thread,
    time::{Duration, Instant},
};
use support::*;

// The sleep ignores SIGHUP and lives in a different process group from the
// foreground shell. Killing only the foreground pgrp cannot pass these tests.
fn background_session(host: &Host) -> (SessionInfo, BackgroundJob) {
    let session = host.create(vec![
        "/bin/bash".into(),
        "-m".into(),
        "-c".into(),
        format!(
            r#"CHERRY_TEST_DIR='{}'; export CHERRY_TEST_DIR
set -m
/bin/bash -c 'trap "" HUP; printf "%s" "$$" > "$CHERRY_TEST_DIR/background.pid"; exec /bin/sleep 60' &
while [ ! -s "$CHERRY_TEST_DIR/background.pid" ]; do sleep 0.01; done
printf ready > "$CHERRY_TEST_DIR/ready"
while [ ! -e "$CHERRY_TEST_DIR/exit" ]; do sleep 0.01; done
exit 23"#,
            host.dir().display()
        ),
    ]);
    wait_until("background job", || host.dir().join("ready").exists());
    let pid = read_pid(&host.dir().join("background.pid"));
    let job = BackgroundJob {
        pid,
        leader: session.pid.unwrap() as i32,
        group: unsafe { libc::getpgid(pid) },
    };
    assert_eq!(unsafe { libc::getsid(pid) }, job.leader);
    assert!(job.group > 0);
    assert_ne!(job.group, job.leader);
    (session, job)
}

struct BackgroundJob {
    pid: i32,
    leader: i32,
    group: i32,
}

impl Drop for BackgroundJob {
    fn drop(&mut self) {
        // Restrict cleanup to the exact owned session and background group.
        if unsafe { libc::getsid(self.pid) } == self.leader
            && unsafe { libc::getpgid(self.pid) } == self.group
        {
            unsafe {
                libc::kill(-self.group, libc::SIGKILL);
            }
        }
    }
}

#[test]
fn explicit_kill_terminates_background_job_control_groups() {
    let host = Host::new();
    let (session, job) = background_session(&host);
    assert!(is_live(job.pid));
    host.kill(&session.id);
    host.wait(&session.id, |s| s.state == SessionState::Exited);
    wait_until("background job termination", || !is_live(job.pid));
}

#[test]
fn natural_shell_exit_leaves_hangup_immune_jobs_running() {
    let host = Host::new();
    let (session, job) = background_session(&host);
    fs::write(host.dir().join("exit"), []).unwrap();
    let exited = host.wait(&session.id, |s| s.state == SessionState::Exited);
    assert_eq!(exited.exit_code, Some(23));
    assert_eq!(exited.exit_signal, None);
    // As in a terminal, tmux or ssh: the hangup reaches jobs, and a job that
    // ignores it keeps running.
    thread::sleep(Duration::from_millis(500));
    assert!(
        is_live(job.pid),
        "a HUP-immune job was killed at shell exit"
    );
}

#[test]
fn nohup_jobs_survive_the_shell_exiting() {
    let host = Host::new();
    let session = host.create(shell_in(
        host.dir(),
        r#"nohup /bin/sleep 60 >/dev/null 2>&1 &
printf '%s' "$!" > "$CHERRY_TEST_DIR/nohup.pid"
# Let nohup ignore SIGHUP before the hangup arrives.
sleep 0.5
exit 0"#,
    ));
    let pid = read_pid(&host.dir().join("nohup.pid"));
    let _stray = Stray::new(pid);
    let exited = host.wait(&session.id, |s| s.state == SessionState::Exited);
    assert_eq!(exited.exit_code, Some(0));
    thread::sleep(Duration::from_millis(500));
    assert!(
        is_live(pid),
        "the nohup'd job was killed when its shell exited"
    );
}

#[test]
fn kill_escalates_to_term_and_kill_for_programs_that_trap_signals() {
    let host = Host::with_env(&[("CHERRY_HOST_KILL_GRACE_MS", "400")]);
    // One process ignores nothing but logs HUP and TERM; the kill must still
    // end it, and each signal must have been delivered first.
    let session = host.create(shell_in(
        host.dir(),
        r#"trap 'echo HUP >> "$CHERRY_TEST_DIR/signals"' HUP
trap 'echo TERM >> "$CHERRY_TEST_DIR/signals"' TERM
printf '%s' "$$" > "$CHERRY_TEST_DIR/trapper.pid"
while true; do sleep 0.05; done"#,
    ));
    let pid = read_pid(&host.dir().join("trapper.pid"));
    let started = Instant::now();
    host.kill(&session.id);
    let exited = host.wait(&session.id, |s| s.state == SessionState::Exited);
    let elapsed = started.elapsed();
    assert_eq!(exited.exit_signal, Some(libc::SIGKILL));
    assert_eq!(exited.exit_code, Some(128 + libc::SIGKILL as u32));
    assert!(!is_live(pid));
    assert!(
        elapsed >= Duration::from_millis(700),
        "SIGKILL came before the grace periods ({elapsed:?})"
    );
    let signals = fs::read_to_string(host.dir().join("signals")).unwrap();
    let signals: Vec<_> = signals.lines().collect();
    assert_eq!(signals.first(), Some(&"HUP"), "{signals:?}");
    assert!(signals.contains(&"TERM"), "{signals:?}");
}

#[test]
fn a_hangup_ends_ordinary_sessions_without_waiting_for_the_grace_period() {
    let host = Host::with_env(&[("CHERRY_HOST_KILL_GRACE_MS", "5000")]);
    let session = host.create(shell("exec sleep 60"));
    let started = Instant::now();
    host.kill(&session.id);
    let exited = host.wait(&session.id, |s| s.state == SessionState::Exited);
    assert!(started.elapsed() < Duration::from_secs(2));
    assert_eq!(exited.exit_signal, Some(libc::SIGHUP));
    assert_eq!(exited.exit_code, Some(128 + libc::SIGHUP as u32));
}

#[test]
fn signal_deaths_are_reported_with_their_signal() {
    let host = Host::new();
    let session = host.create(shell("kill -SEGV $$"));
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    let (code, signal) = screen.wait_exit(&mut socket);
    assert_eq!(signal, Some(libc::SIGSEGV));
    assert_eq!(code, 128 + libc::SIGSEGV as u32);
    let info = host.wait(&session.id, |s| s.state == SessionState::Exited);
    assert_eq!(info.exit_signal, Some(libc::SIGSEGV));
    assert_eq!(info.exit_code, Some(code));
    // Reattaching to the exited session reports the same.
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    assert_eq!(screen.wait_exit(&mut socket), (code, signal));
}

#[test]
fn explicit_detach_acknowledges_before_eof_and_allows_reattach() {
    let host = Host::new();
    let session = host.create(shell("exec /bin/sleep 60"));
    // Exercise the connection writer and session worker racing each other. A
    // detach must release the lease without discarding the queued reply.
    for attempt in 0..32 {
        let (mut socket, _, _, _) = host.attach(&session.id, 80, 24);
        send(&mut socket, &ClientMessage::Detach);
        let reply = read_frame::<_, ServerMessage>(&mut socket).unwrap();
        assert!(
            matches!(reply, Some(ServerMessage::Ok)),
            "detach {attempt} lost its acknowledgement: {reply:?}"
        );
        assert!(
            read_frame::<_, ServerMessage>(&mut socket)
                .unwrap()
                .is_none(),
            "detach must close after acknowledging"
        );
        let detached = host.wait(&session.id, |s| !s.attached);
        assert_eq!(detached.pid, session.pid);
        assert_eq!(detached.state, SessionState::Running);
    }
    let final_attachment = host.attach(&session.id, 80, 24);
    host.kill(&session.id);
    host.wait(&session.id, |s| s.state == SessionState::Exited);
    drop(final_attachment);
}

fn input_frame() -> Vec<u8> {
    let mut bytes = Vec::new();
    write_frame(
        &mut bytes,
        &ClientMessage::Input {
            data: vec![b'x'; MAX_INPUT_BYTES],
        },
    )
    .unwrap();
    bytes
}

#[test]
fn blocked_pty_input_applies_backpressure_and_does_not_prevent_reattach_or_kill() {
    let host = Host::new();
    let session = host.create(shell_in(
        host.dir(),
        r#"stty raw -echo; printf ready > "$CHERRY_TEST_DIR/ready"; exec /bin/sleep 60"#,
    ));
    wait_until("non-reading PTY child", || {
        host.dir().join("ready").exists()
    });
    let unaffected = host.create(shell("exec /bin/sleep 60"));
    let (mut socket, _, _, _) = host.attach(&session.id, 80, 24);
    socket
        .set_write_timeout(Some(Duration::from_millis(500)))
        .unwrap();
    let frame = input_frame();
    // Far more than the input budget, against a child that never reads
    // stdin. The host stops reading instead of buffering or disconnecting.
    let mut sent = 0;
    for _ in 0..128 {
        if socket.write_all(&frame).is_err() {
            break;
        }
        sent += 1;
    }
    assert!(sent > 0, "no input reached the attachment");
    assert!(
        sent * frame.len() < 4 * 1024 * 1024,
        "the host accepted {sent} frames without backpressure"
    );
    assert!(
        host.session(&session.id).attached,
        "a paste disconnected the client"
    );
    let _ = socket.shutdown(Shutdown::Both);
    drop(socket);
    let detached = host.wait(&session.id, |s| !s.attached);
    assert_eq!(detached.pid, session.pid);
    assert_eq!(detached.state, SessionState::Running);

    let (mut reattached, _, _, _) = host.attach(&session.id, 80, 24);
    reattached
        .set_write_timeout(Some(Duration::from_millis(500)))
        .unwrap();
    let abort = reattached.try_clone().unwrap();
    let sent = Arc::new(AtomicUsize::new(0));
    let writer_sent = sent.clone();
    let writer = thread::spawn(move || {
        for _ in 0..128 {
            if reattached.write_all(&frame).is_err() {
                break;
            }
            writer_sent.fetch_add(1, Ordering::SeqCst);
        }
    });
    wait_until("reattached input writer", || {
        sent.load(Ordering::SeqCst) > 0 || writer.is_finished()
    });
    let start = Instant::now();
    host.kill(&session.id);
    let exited = host.wait(&session.id, |s| s.state == SessionState::Exited);
    assert_eq!(exited.pid, session.pid);
    assert!(
        start.elapsed() < Duration::from_secs(3),
        "termination stalled behind input"
    );
    let _ = abort.shutdown(Shutdown::Both);
    writer.join().unwrap();
    assert_eq!(host.session(&unaffected.id).state, SessionState::Running);
}

fn cpu_seconds(pid: u32) -> f64 {
    let output = Command::new("/bin/ps")
        .args(["-p", &pid.to_string(), "-o", "time="])
        .output()
        .unwrap();
    assert!(output.status.success());
    String::from_utf8_lossy(&output.stdout)
        .trim()
        .split(':')
        .fold(0.0, |seconds, part| {
            seconds * 60.0 + part.parse::<f64>().unwrap()
        })
}

#[test]
fn closed_terminal_fds_do_not_spin_while_the_child_is_still_running() {
    let host = Host::new();
    let session = host.create(shell_in(
        host.dir(),
        r#"exec 0</dev/null 1>/dev/null 2>/dev/null
printf ready > "$CHERRY_TEST_DIR/ready"
sleep 2
exit 19"#,
    ));
    wait_until("closed terminal descriptors", || {
        host.dir().join("ready").exists()
    });
    assert_eq!(host.session(&session.id).state, SessionState::Running);
    // The daemon, and the holder that reads the terminal.
    let holder = holder_of(&host.sandbox, &session.id) as u32;
    let cpu = || cpu_seconds(host.child.id()) + cpu_seconds(holder);
    let before = cpu();
    thread::sleep(Duration::from_millis(1500));
    let consumed = cpu() - before;
    assert!(
        consumed < 0.75,
        "host consumed {consumed:.2}s CPU after terminal EOF"
    );
    let exited = host.wait(&session.id, |s| s.state == SessionState::Exited);
    assert_eq!(exited.exit_code, Some(19));
}

#[test]
fn leader_exit_is_noticed_promptly_while_a_job_keeps_the_terminal_open() {
    let host = Host::new();
    // The background job keeps the terminal open, so the PTY never reports
    // end of file: only the child-exit notification reveals the exit.
    let session = host.create(shell_in(
        host.dir(),
        r#"(trap '' HUP; exec /bin/sleep 30) &
printf '%s' "$!" > "$CHERRY_TEST_DIR/job.pid"
IFS= read -r line
exit 3"#,
    ));
    let pid = read_pid(&host.dir().join("job.pid"));
    let _stray = Stray::new(pid);
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    thread::sleep(Duration::from_millis(200));
    let started = Instant::now();
    input(&mut socket, b"\n");
    assert_eq!(screen.wait_exit(&mut socket), (3, None));
    let elapsed = started.elapsed();
    assert!(
        elapsed < Duration::from_millis(500),
        "exit noticed after {elapsed:?}"
    );
    assert!(is_live(pid));
}

/// Context switches of every thread of a process.
fn context_switches(pid: u32) -> u64 {
    #[cfg(target_os = "macos")]
    unsafe {
        let mut info: libc::proc_taskinfo = std::mem::zeroed();
        let size = std::mem::size_of::<libc::proc_taskinfo>() as libc::c_int;
        assert_eq!(
            libc::proc_pidinfo(
                pid as libc::c_int,
                libc::PROC_PIDTASKINFO,
                0,
                (&mut info as *mut libc::proc_taskinfo).cast(),
                size,
            ),
            size
        );
        info.pti_csw as u64
    }
    #[cfg(target_os = "linux")]
    {
        fs::read_dir(format!("/proc/{pid}/task"))
            .unwrap()
            .map(|task| {
                fs::read_to_string(task.unwrap().path().join("status"))
                    .unwrap_or_default()
                    .lines()
                    .filter(|line| line.contains("ctxt_switches"))
                    .filter_map(|line| line.split_whitespace().nth(1)?.parse::<u64>().ok())
                    .sum::<u64>()
            })
            .sum()
    }
}

#[test]
fn an_idle_daemon_and_its_holders_do_not_keep_waking_up() {
    let host = Host::new();
    let sessions: Vec<_> = (0..3)
        .map(|_| host.create(shell("exec sleep 60")))
        .collect();
    let (_attached, _, _, _) = host.attach(&sessions[0].id, 80, 24);
    let holders: Vec<u32> = sessions
        .iter()
        .map(|session| holder_of(&host.sandbox, &session.id) as u32)
        .collect();
    // Past the foreground checks that follow a session's start.
    thread::sleep(Duration::from_millis(1500));
    let processes: Vec<u32> = [host.child.id()].into_iter().chain(holders).collect();
    let total = || -> u64 { processes.iter().map(|&pid| context_switches(pid)).sum() };
    let before = total();
    thread::sleep(Duration::from_secs(2));
    let switches = total() - before;
    // Polling every 10 ms (accept) and 100 ms (each session, in the daemon
    // or its holder) would be about 460 wakeups here.
    assert!(
        switches < 40,
        "{switches} context switches in 2 s while idle"
    );
}
