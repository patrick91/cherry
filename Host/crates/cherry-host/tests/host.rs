//! Protocol behaviour of attached clients: snapshots, output, input, sizes.
mod support;

use cherry_protocol::*;
use cherry_vt::Terminal;
use std::{
    collections::BTreeMap,
    fs,
    io::{Read, Write},
    os::unix::net::UnixStream,
    sync::{
        atomic::{AtomicU64, AtomicUsize, Ordering},
        Arc,
    },
    thread,
    time::{Duration, Instant},
};
use support::*;
use uuid::Uuid;

#[test]
fn disconnect_preserves_process_and_reattach_restores_screen_and_input() {
    let host = Host::new();
    let session = host.create(vec!["/bin/sh".into()]);
    let (mut first, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    // The command line echoes `CHERRY_%s`; only its output joins the words.
    input(&mut first, b"printf 'CHERRY_%s\\n' PERSISTED\r");
    screen.wait_text(&mut first, "CHERRY_PERSISTED");
    drop(first);
    let detached = host.wait(&session.id, |s| !s.attached);
    assert_eq!(detached.pid, session.pid);
    assert_eq!(detached.state, SessionState::Running);
    let (mut second, resumed, offset, snapshot) = host.attach(&session.id, 100, 30);
    assert_eq!(resumed.pid, session.pid);
    assert_eq!((resumed.cols, resumed.rows), (100, 30));
    let mut screen = Screen::new(100, 30, offset, &snapshot);
    assert!(screen.text().contains("CHERRY_PERSISTED"));
    input(&mut second, b"printf 'AFTER_%s\\n' RECONNECT; exit 7\r");
    assert_eq!(screen.wait_exit(&mut second), (7, None));
    assert!(screen.text().contains("AFTER_RECONNECT"));
    let exited = host.wait(&session.id, |s| s.state == SessionState::Exited);
    assert_eq!(exited.exit_code, Some(7));
    assert_eq!(exited.exit_signal, None);
}

#[test]
fn create_retries_are_idempotent_whatever_the_terminal_size() {
    let host = Host::new();
    let request_id = Uuid::new_v4().to_string();
    let request = |cols, rows, command: &str| ClientMessage::Create {
        request_id: request_id.clone(),
        name: "retry".into(),
        cwd: "/tmp".into(),
        command: shell(command),
        env: BTreeMap::new(),
        cols,
        rows,
        owner: None,
        tags: BTreeMap::new(),
        colors: None,
    };
    let a = match host.call(request(80, 24, "sleep 60")) {
        ServerMessage::Created { session } => session,
        other => panic!("{other:?}"),
    };
    // Retried from a resized terminal: still the same launch.
    let b = match host.call(request(132, 40, "sleep 60")) {
        ServerMessage::Created { session } => session,
        other => panic!("{other:?}"),
    };
    assert_eq!(a.id, b.id);
    assert_eq!(a.pid, b.pid);
    assert_eq!(host.sessions().len(), 1);
    // Reusing the request for something else is refused.
    match host.call(request(80, 24, "sleep 61")) {
        ServerMessage::Error { code, message } => {
            assert_eq!(code, "request_failed");
            assert!(message.contains("different launch"), "{message}");
        }
        other => panic!("{other:?}"),
    }
    let (_first, _, _, _) = host.attach(&a.id, 80, 24);
    let (_second, shared, _, _) = host.attach(&a.id, 80, 24);
    assert_eq!(shared.pid, a.pid);
    assert!(matches!(
        host.call(ClientMessage::Shutdown),
        ServerMessage::Error { .. }
    ));
    host.kill(&a.id);
    host.wait(&a.id, |s| s.state == SessionState::Exited);
    // Removing the session forgets its receipt.
    assert!(matches!(
        host.call(ClientMessage::Remove { id: a.id.clone() }),
        ServerMessage::Ok
    ));
    let c = match host.call(request(80, 24, "sleep 60")) {
        ServerMessage::Created { session } => session,
        other => panic!("{other:?}"),
    };
    assert_ne!(c.id, a.id);
    host.kill(&c.id);
}

#[test]
fn takeover_moves_live_session_without_restarting_or_accepting_stale_input() {
    let host = Host::new();
    let session = host.create(shell(
        "stty -echo; printf 'ORIGINAL_SCREEN\\n'; while IFS= read -r line; do printf 'INPUT:%s\\n' \"$line\"; stty size; done",
    ));
    let (mut first, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut original = Screen::new(80, 24, offset, &snapshot);
    original.wait_text(&mut first, "ORIGINAL_SCREEN");

    let (mut second, resumed, offset, snapshot) =
        host.attach_with_takeover(&session.id, 100, 30, true);
    assert_eq!(resumed.id, session.id);
    assert_eq!(resumed.pid, session.pid);
    assert_eq!(resumed.state, SessionState::Running);
    assert_eq!((resumed.cols, resumed.rows), (100, 30));
    let mut screen = Screen::new(100, 30, offset, &snapshot);
    assert!(screen.text().contains("ORIGINAL_SCREEN"));

    // The old peer receives a useful terminal diagnostic and EOF. An input or
    // detach racing its cleanup can neither reach the PTY nor revoke the new
    // controller. Socket closure can reject these writes before protocol read.
    let _ = write_frame(
        &mut first,
        &ClientMessage::Input {
            data: b"STALE_INPUT\n".to_vec(),
        },
    );
    let _ = write_frame(&mut first, &ClientMessage::Detach);
    loop {
        match receive(&mut first) {
            ServerMessage::Error { code, message } => {
                assert_eq!(code, "taken_over");
                assert!(message.contains("still running"));
                break;
            }
            ServerMessage::Output { .. } => {}
            other => panic!("unexpected old controller reply: {other:?}"),
        }
    }
    assert!(read_frame::<_, ServerMessage>(&mut first)
        .unwrap()
        .is_none());
    drop(first);
    assert!(host.wait(&session.id, |s| s.attached).attached);

    send(
        &mut second,
        &ClientMessage::Resize {
            cols: 90,
            rows: 28,
            cell_width: None,
            cell_height: None,
        },
    );
    screen.wait_size(&mut second, 90, 28);
    input(&mut second, b"NEW_CONTROLLER\n");
    screen.wait_text(&mut second, "INPUT:NEW_CONTROLLER");
    screen.wait_text(&mut second, "28 90");
    assert!(!screen.text().contains("STALE_INPUT"));
    let current = host.wait(&session.id, |s| s.cols == 90 && s.rows == 28);
    assert_eq!(current.pid, session.pid);
    assert!(current.attached);
    let (_third, shared, _, _) = host.attach(&session.id, 90, 28);
    assert_eq!(shared.pid, session.pid);
}

#[test]
fn shared_attachments_both_type_and_resize_to_smallest_client_until_detach() {
    let host = Host::new();
    let session = host.create(shell(
        "stty -echo; printf 'READY\\n'; while IFS= read -r line; do printf 'INPUT:%s\\n' \"$line\"; stty size; done",
    ));
    let (mut first, _, offset, snapshot) = host.attach(&session.id, 100, 30);
    let mut screen1 = Screen::new(100, 30, offset, &snapshot);
    screen1.wait_text(&mut first, "READY");
    let (mut second, info, offset, snapshot) = host.attach(&session.id, 80, 24);
    assert_eq!(info.pid, session.pid);
    assert_eq!((info.cols, info.rows), (80, 24));
    let mut screen2 = Screen::new(80, 24, offset, &snapshot);
    screen1.wait_size(&mut first, 80, 24);
    assert_eq!(screen1.attached, vec![AttachReason::Resize]);
    assert_eq!(screen1.offset, screen2.offset);
    assert_eq!(screen1.text(), screen2.text());

    input(&mut first, b"FROM_FIRST\n");
    screen1.wait_text(&mut first, "24 80");
    screen2.wait_text(&mut second, "24 80");
    assert!(screen1.text().contains("INPUT:FROM_FIRST"));
    assert_eq!(screen1.text(), screen2.text());
    input(&mut second, b"FROM_SECOND\n");
    screen1.wait_text(&mut first, "INPUT:FROM_SECOND");
    screen2.wait_text(&mut second, "INPUT:FROM_SECOND");

    // Each requested size is retained. Growing the smaller client grows the
    // shared PTY only as far as the other client's dimensions.
    send(
        &mut second,
        &ClientMessage::Resize {
            cols: 120,
            rows: 40,
            cell_width: None,
            cell_height: None,
        },
    );
    screen1.wait_size(&mut first, 100, 30);
    screen2.wait_size(&mut second, 100, 30);
    assert_eq!(screen1.offset, screen2.offset);
    assert_eq!(screen1.text(), screen2.text());

    send(&mut first, &ClientMessage::Detach);
    loop {
        if matches!(receive(&mut first), ServerMessage::Ok) {
            break;
        }
    }
    assert!(read_frame::<_, ServerMessage>(&mut first)
        .unwrap()
        .is_none());
    drop(first);
    screen2.wait_size(&mut second, 120, 40);
    input(&mut second, b"STILL_RUNNING\n");
    screen2.wait_text(&mut second, "INPUT:STILL_RUNNING");
    screen2.wait_text(&mut second, "40 120");
    let info = host.wait(&session.id, |s| s.cols == 120 && s.rows == 40);
    assert_eq!(info.pid, session.pid);
    assert!(info.attached);
    drop(second);
    let info = host.wait(&session.id, |s| !s.attached);
    assert_eq!(info.state, SessionState::Running);
}

#[test]
fn rapid_resizes_are_coalesced_into_one_snapshot_while_other_windows_watch() {
    let host = Host::new();
    let session = host.create(shell("exec sleep 60"));
    // A larger window elsewhere gets a replacement for every grid change.
    let (mut other, _, offset, snapshot) = host.attach(&session.id, 120, 45);
    let mut other_screen = Screen::new(120, 45, offset, &snapshot);
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 100, 30);
    let mut screen = Screen::new(100, 30, offset, &snapshot);
    // Like a window drag: one step every 10 ms. The host applies a size
    // once it has been stable for its settle time (75 ms): a step that
    // comes that much later (a stalled test thread on a busy machine, as
    // macOS CI runners can be) ends one drag and starts another, which is
    // allowed its replacements. Each gap is measured, with 25 ms of slack
    // for the way from this socket to the session.
    const SETTLE: Duration = Duration::from_millis(75);
    const SLACK: Duration = Duration::from_millis(25);
    let mut sent_at: Option<Instant> = None;
    let mut paused = 0usize;
    for step in 0..20u16 {
        let now = Instant::now();
        if let Some(gap) = sent_at.map(|at| now - at) {
            // After one settle time the grid follows the step before; after
            // two, the next step also changes it at once.
            if gap + SLACK >= SETTLE * 2 {
                paused += 2;
            } else if gap + SLACK >= SETTLE {
                paused += 1;
            }
        }
        sent_at = Some(now);
        send(
            &mut socket,
            &ClientMessage::Resize {
                cols: 80 + step,
                rows: 20 + step,
                cell_width: None,
                cell_height: None,
            },
        );
        thread::sleep(Duration::from_millis(10));
    }
    screen.wait_size(&mut socket, 99, 39);
    other_screen.wait_size(&mut other, 99, 39);
    // Nothing else follows once the size has settled: the first step may
    // change the grid at once, the rest once the size settled. (The other
    // window also got one when this one attached.) Without a pause in the
    // drag that is 3 at most.
    for (socket, screen) in [(&mut socket, &mut screen), (&mut other, &mut other_screen)] {
        socket
            .set_read_timeout(Some(Duration::from_millis(400)))
            .unwrap();
        while let Ok(Some(message)) = read_frame::<_, ServerMessage>(socket) {
            screen.apply(&message);
        }
        assert!(
            screen.attached.len() <= 3 + paused,
            "{} snapshots for one drag ({paused} allowed for steps that came a settle time late): {:?}",
            screen.attached.len(),
            screen.attached
        );
    }
    assert_eq!((screen.cols, screen.rows), (99, 39));
    let info = host.session(&session.id);
    assert_eq!((info.cols, info.rows), (99, 39));
}

#[test]
fn a_lone_windows_drag_changes_the_grid_at_every_step() {
    // Nobody else would get a replacement per step: the grid follows the
    // only window at once (its client sends at most one resize per 50 ms).
    let host = Host::new();
    let session = host.create(shell("exec sleep 60"));
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 100, 30);
    let mut screen = Screen::new(100, 30, offset, &snapshot);
    send(
        &mut socket,
        &ClientMessage::Resize {
            cols: 90,
            rows: 25,
            cell_width: None,
            cell_height: None,
        },
    );
    screen.wait_size(&mut socket, 90, 25);
    let started = Instant::now();
    send(
        &mut socket,
        &ClientMessage::Resize {
            cols: 91,
            rows: 26,
            cell_width: None,
            cell_height: None,
        },
    );
    screen.wait_size(&mut socket, 91, 26);
    // Not held back for the size to settle, even on a busy machine.
    assert!(started.elapsed() < Duration::from_secs(5));
    assert_eq!(
        screen.attached,
        [AttachReason::Resize, AttachReason::Resize]
    );
    let info = host.session(&session.id);
    assert_eq!((info.cols, info.rows), (91, 26));
}

#[test]
fn a_lagging_client_is_resynchronized_instead_of_disconnected() {
    let host = Host::new();
    // About 12 MiB without pauses: far more than one client may have
    // waiting for it (see `flood`).
    let session = host.create(shell(
        "stty -echo; IFS= read -r start; dd if=/dev/zero bs=65536 count=192 2>/dev/null | tr '\\0' x; printf '\\r\\nFLOOD_%s\\r\\n' COMPLETE; IFS= read -r line; printf 'LIVE:%s\\r\\n' \"$line\"; exec sleep 60",
    ));
    let (mut stalled, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut stalled_screen = Screen::new(80, 24, offset, &snapshot);
    let (mut active, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    input(&mut active, b"start\n");
    // The stalled socket is intentionally not read during the flood.
    screen.wait_text(&mut active, "FLOOD_COMPLETE");
    assert!(host.session(&session.id).attached);
    input(&mut active, b"AFTER_SLOW_PEER\n");
    screen.wait_text(&mut active, "LIVE:AFTER_SLOW_PEER");

    // The slow client catches up through a fresh snapshot and continues at
    // its offset, with every later byte in order.
    stalled
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    stalled_screen.wait_text(&mut stalled, "LIVE:AFTER_SLOW_PEER");
    assert!(
        stalled_screen.attached.contains(&AttachReason::Resync),
        "{:?}",
        stalled_screen.attached
    );
    assert_eq!(stalled_screen.offset, screen.offset);
    assert_eq!(stalled_screen.text(), screen.text());
    input(&mut stalled, b"FROM_SLOW_PEER\n");
    let info = host.session(&session.id);
    assert_eq!(info.pid, session.pid);
    assert!(info.attached);
}

/// What one attachment received while it read `socket` until `done` said
/// so: its output, in order, and the reasons of its replacements.
struct Received {
    output: Vec<u8>,
    replacements: Vec<AttachReason>,
}

/// Read an attachment's frames, pausing `pause` after each, until the
/// output holds `until`.
fn read_until(socket: &mut UnixStream, mut offset: u64, until: &[u8], pause: Duration) -> Received {
    socket
        .set_read_timeout(Some(Duration::from_secs(20)))
        .unwrap();
    let mut received = Received {
        output: Vec::new(),
        replacements: Vec::new(),
    };
    let deadline = Instant::now() + Duration::from_secs(120);
    let mut seen = false;
    while !seen {
        assert!(Instant::now() < deadline, "timed out waiting for {until:?}");
        match receive(socket) {
            ServerMessage::Output { offset: at, data } => {
                assert_eq!(at, offset, "output out of order");
                offset += data.len() as u64;
                // Where it may end, only: the output is long.
                let from = received.output.len().saturating_sub(until.len());
                received.output.extend_from_slice(&data);
                seen = received.output[from..]
                    .windows(until.len())
                    .any(|window| window == until);
            }
            ServerMessage::Attached {
                offset: at, reason, ..
            } => {
                offset = at;
                received.replacements.push(reason);
            }
            _ => {}
        }
        if !pause.is_zero() {
            thread::sleep(pause);
        }
    }
    received
}

/// A flood of `mib` MiB of `x`, then `FLOOD_COMPLETE`, the last of its
/// output, once the session reads a line; the program then creates `done`
/// and waits. A client that reads none of it falls behind only past what
/// its socket holds (the daemon asks for a 1 MiB send buffer, which Linux
/// doubles and a write may overshoot by half again), its 4 MiB output
/// budget and the frame its writer is writing: 12 MiB is well past that
/// everywhere.
fn flood(mib: usize, done: &std::path::Path) -> Vec<String> {
    shell(&format!(
        "stty -echo; IFS= read -r start; dd if=/dev/zero bs=65536 count={} 2>/dev/null | tr '\\0' x; printf '\\r\\nFLOOD_%s' COMPLETE; : > '{}'; exec sleep 60",
        mib * 16,
        done.display()
    ))
}

#[test]
fn a_flood_travels_in_big_frames_and_an_echo_after_it_at_once() {
    let host = Host::new();
    let session = host.create(shell(
        "stty -echo; IFS= read -r start; dd if=/dev/zero bs=65536 count=128 2>/dev/null | tr '\\0' x; printf '\\r\\nFLOOD_%s\\r\\n' COMPLETE; while IFS= read -r line; do printf 'ECHO:%s\\r\\n' \"$line\"; done",
    ));
    let (mut socket, _, offset, _) = host.attach(&session.id, 80, 24);
    input(&mut socket, b"start\n");
    socket
        .set_read_timeout(Some(Duration::from_secs(20)))
        .unwrap();
    let mut offset = offset;
    let (mut bytes, mut frames) = (0usize, 0usize);
    let mut tail = Vec::new();
    while !tail.windows(14).any(|window| window == b"FLOOD_COMPLETE") {
        if let ServerMessage::Output { offset: at, data } = receive(&mut socket) {
            assert_eq!(at, offset);
            offset += data.len() as u64;
            bytes += data.len();
            frames += 1;
            tail.extend_from_slice(&data);
            tail.drain(..tail.len().saturating_sub(64));
        }
    }
    // 8 MiB: in frames far bigger than a PTY read (1 KiB on macOS). How far
    // depends on how quickly this reader keeps up (a loaded CI runner got
    // about 7 KiB), so ask for four PTY reads a frame.
    assert!(bytes >= 8 * 1024 * 1024);
    assert!(
        bytes / frames >= 4 * 1024,
        "{frames} frames for {bytes} bytes"
    );
    // Output after the flood is not held back.
    let sent = Instant::now();
    input(&mut socket, b"typed\n");
    let mut echoed = Vec::new();
    while !echoed.windows(10).any(|window| window == b"ECHO:typed") {
        if let ServerMessage::Output { data, .. } = receive(&mut socket) {
            echoed.extend_from_slice(&data);
        }
    }
    assert!(
        sent.elapsed() < Duration::from_secs(2),
        "{:?}",
        sent.elapsed()
    );
}

#[test]
fn a_slow_client_gets_all_of_a_flood_at_its_own_pace() {
    // It never takes no output for the stall: it is held to, not dropped.
    let host = Host::new();
    let done = host.sandbox.home.join("flooded");
    let session = host.create(flood(10, &done));
    let (mut slow, _, offset, _) = host.attach(&session.id, 80, 24);
    input(&mut slow, b"start\n");
    // Far slower than the program: the flood waits for this client.
    let received = read_until(
        &mut slow,
        offset,
        b"FLOOD_COMPLETE",
        Duration::from_millis(2),
    );
    assert!(
        received.replacements.is_empty(),
        "resynchronized: {:?}",
        received.replacements
    );
    let floods = received.output.iter().filter(|&&b| b == b'x').count();
    assert_eq!(floods, 10 * 1024 * 1024, "every byte of the flood arrived");
    assert!(done.exists());
}

#[test]
fn a_client_that_pauses_holds_the_program_back_with_bounded_buffers() {
    let host = Host::new();
    let done = host.sandbox.home.join("flooded");
    let session = host.create(flood(32, &done));
    let (mut slow, _, mut offset, _) = host.attach(&session.id, 80, 24);
    input(&mut slow, b"start\n");
    slow.set_read_timeout(Some(Duration::from_secs(20)))
        .unwrap();
    // A little of the flood, then a pause shorter than the stall.
    let mut taken = 0;
    while taken < 2 * 1024 * 1024 {
        match receive(&mut slow) {
            ServerMessage::Output { offset: at, data } => {
                assert_eq!(at, offset);
                offset += data.len() as u64;
                taken += data.iter().filter(|&&b| b == b'x').count();
            }
            ServerMessage::Attached { reason, .. } => panic!("replaced: {reason:?}"),
            _ => {}
        }
    }
    thread::sleep(Duration::from_millis(1200));
    // What the program wrote meanwhile waits in bounded buffers (the
    // client's socket and queue, the daemon's and the holder's link, the
    // PTY): nowhere near the 30 MiB left of the flood.
    assert!(!done.exists(), "the program was not held back");
    let received = read_until(&mut slow, offset, b"FLOOD_COMPLETE", Duration::ZERO);
    assert!(
        received.replacements.is_empty(),
        "resynchronized: {:?}",
        received.replacements
    );
    let floods = received.output.iter().filter(|&&b| b == b'x').count();
    assert_eq!(taken + floods, 32 * 1024 * 1024);
}

#[test]
fn a_client_that_takes_nothing_holds_the_program_back_only_until_its_stall_ends() {
    let stall = Duration::from_millis(1000);
    let host = Host::with_env(&[("CHERRY_HOST_STALL_TIMEOUT_MS", "1000")]);
    let done = host.sandbox.home.join("flooded");
    let session = host.create(flood(12, &done));
    let (mut stuck, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    input(&mut stuck, b"start\n");
    // Nothing reads the attachment, the only one: it holds the program back
    // (a flood of this size is over in well under a second otherwise)...
    let started = Instant::now();
    thread::sleep(stall / 2);
    assert!(!done.exists(), "the program was not held back");
    // ...until its stall ends; then the program goes on.
    while !done.exists() {
        assert!(
            started.elapsed() < stall + Duration::from_secs(5),
            "the program is still held back"
        );
        thread::sleep(Duration::from_millis(20));
    }
    // Once it reads, it catches up through a fresh snapshot.
    stuck
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    screen.wait_text(&mut stuck, "FLOOD_COMPLETE");
    assert!(
        screen.attached.contains(&AttachReason::Resync),
        "{:?}",
        screen.attached
    );
}

#[test]
fn only_clients_that_take_their_output_hold_the_program_back() {
    let host = Host::with_env(&[("CHERRY_HOST_STALL_TIMEOUT_MS", "300")]);
    let done = host.sandbox.home.join("flooded");
    let session = host.create(flood(12, &done));
    let (mut stuck, _, stuck_offset, stuck_snapshot) = host.attach(&session.id, 80, 24);
    let (mut slow, _, offset, _) = host.attach(&session.id, 80, 24);
    input(&mut slow, b"start\n");
    // The slow client gets every byte; the one that takes nothing does not
    // hold it (or the program) back.
    let received = read_until(
        &mut slow,
        offset,
        b"FLOOD_COMPLETE",
        Duration::from_millis(1),
    );
    assert!(
        received.replacements.is_empty(),
        "resynchronized: {:?}",
        received.replacements
    );
    let floods = received.output.iter().filter(|&&b| b == b'x').count();
    assert_eq!(floods, 12 * 1024 * 1024);
    let mut screen = Screen::new(80, 24, stuck_offset, &stuck_snapshot);
    stuck
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    screen.wait_text(&mut stuck, "FLOOD_COMPLETE");
    assert!(
        screen.attached.contains(&AttachReason::Resync),
        "{:?}",
        screen.attached
    );
}

/// Read `socket` as a client that takes `rate` bytes a second, in reads of
/// a few KiB, until `stop` is set; returns how much it read.
fn read_slowly(
    mut socket: UnixStream,
    rate: usize,
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
) -> thread::JoinHandle<usize> {
    thread::spawn(move || {
        use std::io::Read;
        socket
            .set_read_timeout(Some(Duration::from_millis(100)))
            .unwrap();
        let started = Instant::now();
        let mut total = 0;
        let mut bytes = [0u8; 16 * 1024];
        while !stop.load(std::sync::atomic::Ordering::SeqCst) {
            let allowed = (rate as f64 * started.elapsed().as_secs_f64()) as usize;
            let want = allowed.saturating_sub(total).min(bytes.len());
            if want < 4096 {
                thread::sleep(Duration::from_millis(5));
                continue;
            }
            match socket.read(&mut bytes[..want]) {
                Ok(0) => break,
                Ok(n) => total += n,
                Err(_) => {}
            }
        }
        total
    })
}

#[test]
fn a_slow_client_that_holds_a_flood_back_keeps_nobody_else_waiting() {
    // A client that takes its output slowly holds the program back; what
    // the session's other clients ask for meanwhile (the screen, an attach,
    // a detach) is answered at once all the same, not behind the output
    // held back for it.
    let host = Host::new();
    let done = host.sandbox.home.join("flooded");
    let session = host.create(flood(64, &done));
    let (mut slow, _, _, _) = host.attach(&session.id, 80, 24);
    input(&mut slow, b"start\n");
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let reader = read_slowly(slow, 200 * 1024, stop.clone());
    // By now the program is held back for it.
    thread::sleep(Duration::from_millis(1500));
    let quick = |what: &str, started: Instant| {
        let took = started.elapsed();
        assert!(took < Duration::from_secs(1), "{what} took {took:?}");
    };
    let started = Instant::now();
    let screen = host.call(ClientMessage::Screen {
        id: session.id.clone(),
        scrollback: false,
        max_lines: None,
    });
    assert!(
        matches!(screen, ServerMessage::ScreenText { .. }),
        "{screen:?}"
    );
    quick("the screen", started);
    let started = Instant::now();
    let (mut other, ..) = host.attach(&session.id, 80, 24);
    quick("an attach", started);
    let started = Instant::now();
    send(&mut other, &ClientMessage::Detach);
    other
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    while !matches!(receive(&mut other), ServerMessage::Ok) {}
    quick("a detach", started);
    // All the while the program was held back.
    assert!(!done.exists(), "the program was not held back");
    stop.store(true, std::sync::atomic::Ordering::SeqCst);
    let read = reader.join().unwrap();
    assert!(read > 200 * 1024, "the slow client took only {read} bytes");
}

/// A client's end of an attachment whose terminal takes at most `rate`
/// bytes a second (0: as fast as they come), in reads of at most 16 KiB.
struct Throttled {
    socket: UnixStream,
    rate: Arc<AtomicUsize>,
    started: Instant,
    taken: usize,
}

impl Read for Throttled {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        let want = loop {
            let rate = self.rate.load(Ordering::SeqCst);
            if rate == 0 {
                break buffer.len();
            }
            let allowed = (rate as f64 * self.started.elapsed().as_secs_f64()) as usize;
            let want = allowed
                .saturating_sub(self.taken)
                .min(buffer.len())
                .min(16 * 1024);
            if want >= buffer.len().min(4096) {
                break want;
            }
            thread::sleep(Duration::from_millis(2));
        };
        let read = self.socket.read(&mut buffer[..want])?;
        self.taken += read;
        Ok(read)
    }
}

/// Follow an attachment's screen on a thread, taking its output at `rate`
/// (see `Throttled`), until the screen shows `until`. `offset` tells how far
/// it got; the thread returns the screen, and when output arrived.
fn follow_slowly(
    socket: UnixStream,
    rate: Arc<AtomicUsize>,
    mut screen: Screen,
    until: &'static str,
    offset: Arc<AtomicU64>,
) -> thread::JoinHandle<(Screen, Vec<Instant>)> {
    thread::spawn(move || {
        socket
            .set_read_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        let mut client = Throttled {
            socket,
            rate,
            started: Instant::now(),
            taken: 0,
        };
        let mut arrivals = Vec::new();
        let deadline = Instant::now() + Duration::from_secs(120);
        while !screen.text().contains(until) {
            assert!(Instant::now() < deadline, "timed out waiting for {until:?}");
            let message = read_frame::<_, ServerMessage>(&mut client)
                .unwrap()
                .expect("the attachment ended");
            screen.apply(&message);
            if matches!(message, ServerMessage::Output { .. }) {
                arrivals.push(Instant::now());
            }
            offset.store(screen.offset, Ordering::SeqCst);
        }
        (screen, arrivals)
    })
}

/// The longest wait between `arrivals`, and from the last to `to`.
fn longest_gap(arrivals: impl IntoIterator<Item = Instant>, to: Instant) -> Duration {
    let mut arrivals = arrivals.into_iter();
    let Some(mut last) = arrivals.next() else {
        return Duration::MAX;
    };
    let mut longest = Duration::ZERO;
    for at in arrivals.chain([to]) {
        longest = longest.max(at.saturating_duration_since(last));
        last = at;
    }
    longest
}

#[test]
fn a_slow_client_does_not_hold_back_a_faster_one() {
    // The program goes at the pace of its fastest client: a slower one falls
    // behind, lags, and catches up through resyncs, ending on the final
    // screen all the same.
    let host = Host::new();
    let done = host.sandbox.home.join("flooded");
    let session = host.create(flood(48, &done));
    let (slow, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let slow = follow_slowly(
        slow,
        Arc::new(AtomicUsize::new(1024 * 1024)),
        Screen::new(80, 24, offset, &snapshot),
        "FLOOD_COMPLETE",
        Arc::default(),
    );
    let (mut fast, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    let started = Instant::now();
    input(&mut fast, b"start\n");
    fast.set_read_timeout(Some(Duration::from_secs(20)))
        .unwrap();
    screen.wait_text(&mut fast, "FLOOD_COMPLETE");
    // At the slow client's pace it would have taken 48 seconds.
    let took = started.elapsed();
    assert!(took < Duration::from_secs(20), "the flood took {took:?}");
    // The fast client got every byte of it.
    assert!(screen.attached.is_empty(), "{:?}", screen.attached);
    assert!(screen.offset - offset > 48 * 1024 * 1024);
    let (slow, _) = slow.join().unwrap();
    assert!(
        slow.attached.contains(&AttachReason::Resync),
        "{:?}",
        slow.attached
    );
    assert_eq!(slow.offset, screen.offset);
    assert_eq!(slow.text(), screen.text());
    assert!(done.exists());
}

#[test]
fn a_client_that_takes_nothing_holds_back_nobody_while_another_takes_its_output() {
    // With the stall it has (2 seconds), it does not hold the program back
    // at all: the client that takes its output gets it without a pause.
    let host = Host::new();
    let done = host.sandbox.home.join("flooded");
    let session = host.create(flood(24, &done));
    let (mut stuck, _, stuck_offset, stuck_snapshot) = host.attach(&session.id, 80, 24);
    let (mut fast, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    input(&mut fast, b"start\n");
    fast.set_read_timeout(Some(Duration::from_secs(20)))
        .unwrap();
    let mut arrivals = Vec::new();
    while !screen.text().contains("FLOOD_COMPLETE") {
        if let ServerMessage::Output { .. } = screen.receive(&mut fast) {
            arrivals.push(Instant::now());
        }
    }
    let longest = longest_gap(arrivals, Instant::now());
    assert!(
        longest < Duration::from_secs(1),
        "the client that takes its output waited {longest:?} for it"
    );
    assert!(screen.attached.is_empty(), "{:?}", screen.attached);
    assert!(screen.offset - offset > 24 * 1024 * 1024);
    // The other catches up through a resync once it reads.
    let mut stuck_screen = Screen::new(80, 24, stuck_offset, &stuck_snapshot);
    stuck
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    stuck_screen.wait_text(&mut stuck, "FLOOD_COMPLETE");
    assert!(
        stuck_screen.attached.contains(&AttachReason::Resync),
        "{:?}",
        stuck_screen.attached
    );
    assert_eq!(stuck_screen.offset, screen.offset);
    assert_eq!(stuck_screen.text(), screen.text());
}

/// 200000 numbered lines of 80 bytes, once the session reads a line, then
/// `FLOOD_COMPLETE`, the last of its output: the screen tells how far the
/// program got (see `watch_program`).
const NUMBERED_FLOOD: &str = "stty -echo; IFS= read -r start; awk 'BEGIN { for (i = 0; i < 200000; i++) printf \"%09d %069d\\n\", i, 0 }'; printf 'FLOOD_%s' COMPLETE; exec sleep 60";

/// Watch how far the program of `id` (`NUMBERED_FLOOD`) gets for `span`:
/// the longest it went without a new line, and the first and last line it
/// had written.
fn watch_program(host: &Host, id: &str, span: Duration) -> (Duration, u64, u64) {
    let line = || match host.call(ClientMessage::Screen {
        id: id.into(),
        scrollback: false,
        max_lines: None,
    }) {
        ServerMessage::ScreenText { text, .. } => text
            .lines()
            .rev()
            .find_map(|line| line.get(..9)?.parse::<u64>().ok())
            .unwrap_or(0),
        other => panic!("{other:?}"),
    };
    let started = Instant::now();
    let first = line();
    let (mut last, mut since, mut stopped) = (first, started, Duration::ZERO);
    while started.elapsed() < span {
        thread::sleep(Duration::from_millis(50));
        let now = line();
        if now != last {
            (last, since) = (now, Instant::now());
        }
        stopped = stopped.max(since.elapsed());
    }
    (stopped, first, last)
}

/// A fast client and a slow one on a session of `NUMBERED_FLOOD`: the slow
/// one takes its output at `rate` on a thread (see `follow_slowly`), and
/// the fast one takes it until the slow one is `behind` bytes behind.
struct Race {
    fast: UnixStream,
    fast_offset: u64,
    slow: thread::JoinHandle<(Screen, Vec<Instant>)>,
    rate: Arc<AtomicUsize>,
}

fn race(host: &Host, id: &str, rate: usize, behind: u64) -> Race {
    let (slow, _, offset, snapshot) = host.attach(id, 80, 24);
    let rate = Arc::new(AtomicUsize::new(rate));
    let slow_offset = Arc::new(AtomicU64::new(offset));
    let slow = follow_slowly(
        slow,
        rate.clone(),
        Screen::new(80, 24, offset, &snapshot),
        "FLOOD_COMPLETE",
        slow_offset.clone(),
    );
    let (mut fast, _, mut offset, _) = host.attach(id, 80, 24);
    input(&mut fast, b"start\n");
    fast.set_read_timeout(Some(Duration::from_secs(20)))
        .unwrap();
    while offset < slow_offset.load(Ordering::SeqCst) + behind {
        match receive(&mut fast) {
            ServerMessage::Output { offset: at, data } => {
                assert_eq!(at, offset);
                offset += data.len() as u64;
            }
            ServerMessage::Attached { reason, .. } => panic!("replaced: {reason:?}"),
            _ => {}
        }
    }
    Race {
        fast,
        fast_offset: offset,
        slow,
        rate,
    }
}

/// The slow client of a `race` (`slow`, at `rate`) takes the rest of the
/// flood as fast as it comes: every byte arrives, without a resync, and
/// without a pause since `from`. Its screen.
fn finish_race(
    slow: thread::JoinHandle<(Screen, Vec<Instant>)>,
    rate: &AtomicUsize,
    from: Instant,
) -> Screen {
    rate.store(0, Ordering::SeqCst);
    let (slow, arrivals) = slow.join().unwrap();
    assert!(slow.attached.is_empty(), "{:?}", slow.attached);
    assert!(slow.text().contains("000199999"), "{}", slow.text());
    let since = arrivals.into_iter().filter(|&at| at >= from);
    let longest = longest_gap(since, Instant::now());
    assert!(
        longest < Duration::from_secs(1),
        "the slow client waited {longest:?} for output"
    );
    slow
}

#[test]
fn a_client_that_becomes_the_fastest_takes_over_pacing_at_once() {
    // A fast client and one that takes its output at 512 KiB/s: the program
    // goes at the fast one's pace, and the slow one falls behind (3.5 MiB,
    // well within its budget: it does not lag). Once the fast one detaches,
    // the program goes on at once at the slow one's pace, rather than stop
    // until it took what waits for it; it gets every byte all the same.
    let host = Host::new();
    let session = host.create(shell(NUMBERED_FLOOD));
    let Race {
        mut fast,
        slow,
        rate,
        ..
    } = race(&host, &session.id, 512 * 1024, 3584 * 1024);
    send(&mut fast, &ClientMessage::Detach);
    while !matches!(receive(&mut fast), ServerMessage::Ok) {}
    let takeover = Instant::now();
    let (stopped, first, last) = watch_program(&host, &session.id, Duration::from_secs(3));
    assert!(
        stopped < Duration::from_secs(1),
        "the program stopped for {stopped:?} (lines {first} to {last})"
    );
    // At half its pace at least (while it catches up), and not beyond what
    // it takes.
    assert!(last - first > 3000, "lines {first} to {last}");
    assert!(last < 150_000, "the program was not held back: line {last}");
    finish_race(slow, &rate, takeover);
}

/// A fast client stops reading while the slow one, 2 MiB behind, reads on
/// at `rate`: the program goes on at the slow one's pace once the fast one
/// took nothing for a while (`outbox::IDLE_AFTER`), not only once its stall
/// (2 seconds) ends. The fast one lags meanwhile, and catches up through a
/// resync.
fn a_client_stops_taking_its_output(rate: usize) {
    let host = Host::new();
    let session = host.create(shell(NUMBERED_FLOOD));
    let Race {
        mut fast,
        fast_offset,
        slow,
        rate,
    } = race(&host, &session.id, rate, 2048 * 1024);
    let stopped_reading = Instant::now();
    let (stopped, first, last) = watch_program(&host, &session.id, Duration::from_secs(3));
    assert!(
        stopped < Duration::from_millis(1000),
        "the program stopped for {stopped:?} (lines {first} to {last})"
    );
    assert!(last < 150_000, "the program was not held back: line {last}");
    let slow = finish_race(slow, &rate, stopped_reading);
    let mut screen = Screen::new(80, 24, fast_offset, &[]);
    screen.wait_text(&mut fast, "FLOOD_COMPLETE");
    assert!(
        screen.attached.contains(&AttachReason::Resync),
        "{:?}",
        screen.attached
    );
    assert_eq!(screen.offset, slow.offset);
    assert_eq!(screen.text(), slow.text());
}

#[test]
fn a_client_that_stops_taking_its_output_holds_back_nobody_while_another_takes_it() {
    a_client_stops_taking_its_output(1024 * 1024);
}

#[test]
fn a_client_that_stops_taking_its_output_holds_back_nobody_while_a_slow_one_takes_it() {
    // Over a link as slow as 100 KiB/s: by the time the fast one's stall
    // would end, the slow one took little more than 200 KiB.
    a_client_stops_taking_its_output(100 * 1024);
}

/// Many lines where every cell has its own true colour: a large snapshot.
const STYLED_HISTORY: &str = r#"awk 'BEGIN { for (i = 0; i < 6000; i++) { line = ""; for (j = 0; j < 78; j++) line = line sprintf("\033[38;2;%d;%d;%dm%c", (i * 7 + j) % 256, (j * 13) % 256, (i + j * 3) % 256, 65 + (i + j) % 26); print line "\033[0m" } }'"#;

#[test]
fn a_client_lagging_when_its_session_exits_still_gets_the_final_screen() {
    let host = Host::new();
    // Far more styled output than a client may have queued, then the last
    // lines a user needs to see (a build's error, say) and an exit.
    let session = host.create(shell(&format!(
        "stty -echo; IFS= read -r start; {STYLED_HISTORY}; printf 'FINAL_%s\\n' MARKER; exit 3"
    )));
    let (mut stalled, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut stalled_screen = Screen::new(80, 24, offset, &snapshot);
    let (mut active, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    input(&mut active, b"start\n");
    active
        .set_read_timeout(Some(Duration::from_secs(30)))
        .unwrap();
    assert_eq!(screen.wait_exit(&mut active), (3, None));
    assert!(screen.text().contains("FINAL_MARKER"), "{}", screen.text());
    // Only now does the stalled client read what the host kept for it.
    stalled
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    assert_eq!(stalled_screen.wait_exit(&mut stalled), (3, None));
    assert!(
        stalled_screen.attached.contains(&AttachReason::Resync),
        "{:?}",
        stalled_screen.attached
    );
    assert!(
        stalled_screen.text().contains("FINAL_MARKER"),
        "the lagging client exited on a stale screen:\n{}",
        stalled_screen.text()
    );
    assert_eq!(stalled_screen.offset, screen.offset);
    assert_eq!(stalled_screen.text(), screen.text());
}

#[test]
fn a_flooding_session_does_not_delay_another_session() {
    let host = Host::new();
    let flood = host.create(shell("exec yes CHERRY_FLOOD"));
    // Its only client never reads.
    let (_stalled, _, _, _) = host.attach(&flood.id, 80, 24);
    let echo = host.create(shell(
        "stty -echo; while IFS= read -r line; do printf 'ECHO:%s\\n' \"$line\"; done",
    ));
    let (mut socket, _, offset, snapshot) = host.attach(&echo.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    thread::sleep(Duration::from_millis(200));
    for round in 0..5 {
        let started = Instant::now();
        input(&mut socket, format!("ping{round}\n").as_bytes());
        screen.wait_text(&mut socket, &format!("ECHO:ping{round}"));
        let elapsed = started.elapsed();
        assert!(
            elapsed < Duration::from_millis(1500),
            "echo took {elapsed:?} while another session flooded"
        );
    }
    assert_eq!(host.session(&flood.id).state, SessionState::Running);
}

#[test]
fn detached_terminal_queries_receive_replies() {
    let host = Host::new();
    let session=host.create(shell(r"stty raw -echo; printf '\033[6n'; dd bs=1 count=6 2>/dev/null | od -An -tx1; printf QUERY_COMPLETE"));
    host.wait(&session.id, |s| s.state == SessionState::Exited);
    let (_socket, _, _, snapshot) = host.attach(&session.id, 80, 24);
    let mut renderer = Terminal::new(80, 24, 2000).unwrap();
    renderer.feed(&snapshot);
    let text = renderer.screen_text().unwrap();
    assert!(text.contains("QUERY_COMPLETE"), "{text}");
    assert!(
        text.split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .contains("1b 5b 31 3b 31 52"),
        "{text}"
    );
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

#[test]
fn attached_queries_have_exactly_one_responder() {
    let host = Host::new();
    let session = host.create(shell_in(
        host.dir(),
        r#"stty raw -echo
printf 'READY\r\n'
dd bs=1 count=1 >/dev/null 2>&1
printf '\033[6n\033]52;c;?\007\033[?6n\033[>4n'
dd bs=1 count=6 2>/dev/null | od -An -tx1 > "$CHERRY_TEST_DIR/reply"
stty min 0 time 5
dd bs=1 count=64 2>/dev/null | od -An -tx1 > "$CHERRY_TEST_DIR/extra"
printf 'DONE\r\n'
exec sleep 60"#,
    ));
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    screen.wait_text(&mut socket, "READY");
    input(&mut socket, b"g");
    let mut output = Vec::new();
    let mut queries = Vec::new();
    while !contains(&output, b"DONE") {
        match receive(&mut socket) {
            ServerMessage::Output { data, .. } => output.extend(data),
            ServerMessage::Query { data } => queries.push((output.len(), data)),
            _ => {}
        }
    }
    // The host answered the cursor report, so the renderer never saw it; the
    // queries the host does not answer went to this client, apart from the
    // output and where they stood in it. A setting stays in the output.
    assert!(!contains(&output, b"\x1b[6n"));
    assert!(!contains(&output, b"\x1b]52;c;?\x07"));
    assert!(!contains(&output, b"\x1b[?6n"));
    assert!(contains(&output, b"\x1b[>4n"));
    let before_query = output.len() - b"\x1b[>4nDONE\r\n".len();
    assert_eq!(
        queries,
        [(before_query, b"\x1b]52;c;?\x07\x1b[?6n".to_vec())],
        "{:?}",
        String::from_utf8_lossy(&output)
    );
    let reply = fs::read_to_string(host.dir().join("reply")).unwrap();
    assert_eq!(
        reply.split_whitespace().collect::<Vec<_>>().join(" "),
        "1b 5b 32 3b 31 52"
    );
    let extra = fs::read_to_string(host.dir().join("extra")).unwrap();
    assert!(extra.trim().is_empty(), "second reply: {extra}");
}

#[test]
fn large_clipboard_writes_reach_attached_clients() {
    let host = Host::new();
    let session = host.create(shell(
        "stty raw -echo; IFS= read -r start; printf '\\033]52;c;'; head -c 3000000 /dev/zero | tr '\\0' A; printf '\\007CLIP_DONE\\r\\n'; exec sleep 60",
    ));
    let (mut socket, _, _, _) = host.attach(&session.id, 80, 24);
    input(&mut socket, b"go\n");
    let mut output = Vec::new();
    while !contains(&output, b"CLIP_DONE") {
        if let ServerMessage::Output { data, .. } = receive(&mut socket) {
            output.extend(data);
        }
    }
    let expected = [&b"\x1b]52;c;"[..], &vec![b'A'; 3_000_000], b"\x07"].concat();
    assert!(
        contains(&output, &expected),
        "clipboard write was not forwarded intact"
    );
}

#[test]
fn clipboard_writes_reach_each_attached_client_once_and_never_a_snapshot() {
    let sandbox = Sandbox::new();
    let log = sandbox.path().join("stderr.log");
    let host = Host::launch_with_stderr(
        sandbox,
        &[],
        None,
        std::process::Stdio::from(fs::File::create(&log).unwrap()),
    );
    // A write, one over the bound, then a read, whose answer (none should
    // come from the host) the program records.
    let session = host.create(shell_in(
        host.dir(),
        r#"stty raw -echo
printf 'READY\r\n'
dd bs=1 count=1 >/dev/null 2>&1
printf '\033]52;c;aGVsbG8=\007'
printf '\033]52;c;'; head -c 8400000 /dev/zero | tr '\0' A; printf '\007'
printf '\033]52;c;?\007'
stty min 0 time 5
dd bs=1 count=64 2>/dev/null | od -An -tx1 > "$CHERRY_TEST_DIR/reply"
printf 'CLIP_DONE\r\n'
exec sleep 60"#,
    ));
    let (mut first, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    screen.wait_text(&mut first, "READY");
    let (mut second, _, _, _) = host.attach(&session.id, 80, 24);
    input(&mut first, b"g");
    let mut queries = Vec::new();
    let mut read_all = |socket: &mut UnixStream| {
        let mut output = Vec::new();
        while !contains(&output, b"CLIP_DONE") {
            match receive(socket) {
                ServerMessage::Output { data, .. } => output.extend(data),
                ServerMessage::Query { data } => queries.push(data),
                _ => {}
            }
        }
        output
    };
    for output in [read_all(&mut first), read_all(&mut second)] {
        // The write reached each client once; the oversized one reached
        // none; the read is no output.
        assert_eq!(
            output
                .windows(b"\x1b]52;".len())
                .filter(|w| w == b"\x1b]52;")
                .count(),
            1,
            "{:?}",
            String::from_utf8_lossy(&output[..output.len().min(400)])
        );
        assert!(contains(&output, b"\x1b]52;c;aGVsbG8=\x07"));
    }
    // The read went to one client, whose terminal answers it (Cherry's
    // surface asks the user first); the host did not answer it.
    assert_eq!(queries, [b"\x1b]52;c;?\x07".to_vec()]);
    let reply = fs::read_to_string(host.dir().join("reply")).unwrap();
    assert!(reply.trim().is_empty(), "the host answered: {reply}");
    // A later attachment's snapshot never replays a clipboard write.
    let (_third, _, _, snapshot) = host.attach(&session.id, 80, 24);
    assert!(!contains(&snapshot, b"\x1b]52;"));
    // The dropped write is logged.
    wait_until("the dropped write to be logged", || {
        fs::read_to_string(&log)
            .unwrap_or_default()
            .contains("dropped 1 clipboard write(s) (OSC 52) over 8388608 bytes")
    });
}

#[test]
fn a_session_created_as_reached_over_ssh_names_its_terminal_in_ssh_tty() {
    let host = Host::new();
    let create = |env: BTreeMap<String, String>| {
        let ClientMessage::Create {
            request_id,
            name,
            cwd,
            command,
            cols,
            rows,
            owner,
            tags,
            colors,
            ..
        } = create_request(
            Uuid::new_v4().to_string(),
            shell_in(
                host.dir(),
                r#"printf '%s|%s|%s\n' "${SSH_TTY-unset}" "$(tty)" "${SSH_CONNECTION-unset}" > "$CHERRY_TEST_DIR/tty.$$.tmp"; mv "$CHERRY_TEST_DIR/tty.$$.tmp" "$CHERRY_TEST_DIR/tty-$MARK""#,
            ),
        )
        else {
            unreachable!()
        };
        match host.call(ClientMessage::Create {
            request_id,
            name,
            cwd,
            command,
            env,
            cols,
            rows,
            owner,
            tags,
            colors,
        }) {
            ServerMessage::Created { session } => session,
            other => panic!("create failed: {other:?}"),
        }
    };
    let read = |mark: &str| {
        let path = host.dir().join(format!("tty-{mark}"));
        wait_until("the session to report its terminal", || path.exists());
        fs::read_to_string(&path).unwrap().trim().to_owned()
    };
    create(BTreeMap::from([
        ("MARK".into(), "ssh".into()),
        ("SSH_CONNECTION".into(), "127.0.0.1 0 127.0.0.1 22".into()),
        ("SSH_TTY".into(), "/dev/ttys999".into()),
    ]));
    let fields: Vec<String> = read("ssh").split('|').map(str::to_owned).collect();
    assert_eq!(fields[0], fields[1], "{fields:?}");
    assert!(fields[0].starts_with("/dev/"), "{fields:?}");
    assert_eq!(fields[2], "127.0.0.1 0 127.0.0.1 22");
    // Without SSH_CONNECTION the host sets none of them.
    create(BTreeMap::from([("MARK".into(), "local".into())]));
    let local = read("local");
    assert!(
        local.starts_with("unset|/dev/") && local.ends_with("|unset"),
        "{local}"
    );
}

#[test]
fn reattach_inside_alternate_screen_restores_underlying_primary_buffer() {
    let host = Host::new();
    let session=host.create(shell(r"stty raw -echo; printf 'PRIMARY_SCREEN\033[?1049h\033[2J\033[HALTERNATE_SCREEN'; dd bs=1 count=1 >/dev/null 2>&1; printf '\033[?1049l'; sleep 2"));
    // Wait for the application to enter its alternate screen, not merely for spawn.
    let deadline = Instant::now() + Duration::from_secs(5);
    let (mut socket, mut screen) = loop {
        let (socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
        let screen = Screen::new(80, 24, offset, &snapshot);
        if screen.text().contains("ALTERNATE_SCREEN") {
            break (socket, screen);
        }
        drop(socket);
        host.wait(&session.id, |s| !s.attached);
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(15));
    };
    input(&mut socket, b"x");
    screen.wait_text(&mut socket, "PRIMARY_SCREEN");
}

#[test]
fn reattaching_a_full_screen_app_at_other_sizes_restores_the_primary_screen() {
    let host = Host::new();
    let primary = "PRIMARY_TOP\r\nline 1\r\nline 2\r\nPRIMARY_BOTTOM";
    let alternate = "\x1b[?1049h\x1b[2J\x1b[HALTERNATE_APP\x1b[5;3Hbody";
    let session = host.create(shell(&format!(
        "stty raw -echo; printf '{}'; printf '{}'; dd bs=1 count=1 >/dev/null 2>&1; printf '\\033[?1049lEXITED_APP'; exec sleep 60",
        primary,
        alternate.replace('\x1b', "\\033"),
    )));
    let mut reference = Terminal::new(80, 24, 1024 * 1024).unwrap();
    reference.feed(primary.as_bytes());
    reference.feed(alternate.as_bytes());
    // Attach at the original size until the app is on its alternate screen.
    loop {
        let (socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
        let screen = Screen::new(80, 24, offset, &snapshot);
        drop(socket);
        host.wait(&session.id, |s| !s.attached);
        if screen.text().contains("body") {
            break;
        }
        thread::sleep(Duration::from_millis(15));
    }
    // Larger, then smaller than the grid the app started on.
    for (cols, rows) in [(110, 35), (60, 15)] {
        let (socket, info, offset, snapshot) = host.attach(&session.id, cols, rows);
        assert_eq!((info.cols, info.rows), (cols, rows));
        reference.resize(cols, rows).unwrap();
        let screen = Screen::new(cols, rows, offset, &snapshot);
        assert_eq!(
            screen.terminal.inspect().unwrap().active,
            reference.inspect().unwrap().active,
            "snapshot at {cols}x{rows}"
        );
        drop(socket);
        host.wait(&session.id, |s| !s.attached);
    }
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 60, 15);
    let mut screen = Screen::new(60, 15, offset, &snapshot);
    input(&mut socket, b"q");
    screen.wait_text(&mut socket, "EXITED_APP");
    reference.feed(b"\x1b[?1049lEXITED_APP");
    let (actual, expected) = (
        screen.terminal.inspect().unwrap(),
        reference.inspect().unwrap(),
    );
    assert_eq!(actual.active, expected.active);
    assert_eq!(actual.cursor, expected.cursor);
    assert!(screen.text().contains("PRIMARY_BOTTOM"));
}

/// A real full-screen program through the host: startup queries, a reattach
/// at a new size, and the primary screen after it quits.
#[test]
#[ignore = "needs nvim on PATH"]
fn neovim_survives_reattach_at_a_new_size() {
    if std::process::Command::new("nvim")
        .arg("--version")
        .output()
        .is_err()
    {
        eprintln!("skipped: nvim not found");
        return;
    }
    let host = Host::new();
    let session = host.create(shell(
        "printf 'BEFORE_%s\\n' NVIM; nvim --clean -n; printf 'AFTER_%s\\n' NVIM; exec sleep 60",
    ));
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    screen.wait_text(&mut socket, "~");
    // Neovim negotiates the kitty keyboard protocol with the host, so a bare
    // ESC byte is not Escape; stay in normal mode.
    input(&mut socket, b":call setline(1, 'hello from nvim')\r");
    // In the buffer, not just on the command line being typed.
    screen.wait_for(&mut socket, "the line in the buffer", |screen| {
        screen.text().starts_with("hello from nvim")
    });
    drop(socket);
    host.wait(&session.id, |s| !s.attached);
    let (mut socket, info, offset, snapshot) = host.attach(&session.id, 110, 35);
    assert_eq!((info.cols, info.rows), (110, 35));
    let mut screen = Screen::new(110, 35, offset, &snapshot);
    assert!(
        screen.text().starts_with("hello from nvim"),
        "{}",
        screen.text()
    );
    // Neovim redraws for the new size: its buffer line, a `~` on each of the
    // other 32 rows above the status and command lines. Only then type: the
    // resize reaches it as SIGWINCH, and input already waiting on its
    // terminal can be read first (it would echo the old width, and no redraw
    // would ever show SIZE_110).
    screen.wait_for(&mut socket, "the redraw at 110x35", |screen| {
        screen
            .text()
            .lines()
            .filter(|line| line.starts_with('~'))
            .count()
            == 32
    });
    input(&mut socket, b":echo 'SIZE_'.&columns\r");
    screen.wait_text(&mut socket, "SIZE_110");
    input(&mut socket, b":qa!\r");
    screen.wait_text(&mut socket, "AFTER_NVIM");
    assert!(screen.text().contains("BEFORE_NVIM"), "{}", screen.text());
    assert!(!screen.text().contains("hello from nvim"));
}

#[test]
fn invalid_protocol_and_launch_do_not_create_sessions() {
    let host = Host::new();
    let launch = |cwd: &str, env: BTreeMap<String, String>| ClientMessage::Create {
        request_id: Uuid::new_v4().to_string(),
        name: "bad".into(),
        cwd: cwd.into(),
        command: vec![],
        env,
        cols: 80,
        rows: 24,
        owner: None,
        tags: BTreeMap::new(),
        colors: None,
    };
    let error = |message: ServerMessage| match message {
        ServerMessage::Error { message, .. } => message,
        other => panic!("{other:?}"),
    };
    // Every Hello is welcomed with the host's own version; after a mismatch
    // the host accepts nothing but Replace, and closes the connection.
    let mut socket = UnixStream::connect(&host.socket).unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    write_frame(&mut socket, &ClientMessage::Hello { version: 999 }).unwrap();
    assert!(matches!(
        receive(&mut socket),
        ServerMessage::Welcome {
            version: PROTOCOL_VERSION,
            ..
        }
    ));
    write_frame(&mut socket, &launch("/tmp", BTreeMap::new())).unwrap();
    assert!(
        matches!(receive(&mut socket), ServerMessage::Error { code, .. } if code == error_code::VERSION_MISMATCH)
    );
    assert!(read_frame::<_, ServerMessage>(&mut socket)
        .unwrap()
        .is_none());
    // A first frame that is not a Hello is refused the same way.
    let mut socket = UnixStream::connect(&host.socket).unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    write_frame(&mut socket, &launch("/tmp", BTreeMap::new())).unwrap();
    assert!(
        matches!(receive(&mut socket), ServerMessage::Error { code, .. } if code == error_code::VERSION_MISMATCH)
    );
    assert!(error(host.call(launch("/does/not/exist", BTreeMap::new()))).contains("does not exist"));
    assert!(error(host.call(launch(".", BTreeMap::new())))
        .contains("must be absolute or start with ~/"));
    // Any variable a program can be given may be set; no other.
    assert!(error(host.call(launch(
        "/tmp",
        BTreeMap::from([("NOT=A NAME".into(), "1".into())])
    )))
    .contains("invalid environment variable"));
    assert!(error(host.call(ClientMessage::Create {
        request_id: Uuid::new_v4().to_string(),
        name: "bad".into(),
        cwd: "/tmp".into(),
        command: vec!["/does/not/exist".into()],
        env: BTreeMap::new(),
        cols: 80,
        rows: 24,
        owner: None,
        tags: BTreeMap::new(),
        colors: None,
    }))
    .contains("/does/not/exist"));
    assert!(host.sessions().is_empty());
}

/// The next frame, with its request ID.
fn response(socket: &mut UnixStream) -> (Option<u64>, ServerMessage) {
    let Response { req, message } = read_frame(socket)
        .unwrap()
        .expect("unexpected connection EOF");
    (req, message)
}

#[test]
fn replies_echo_request_ids_and_several_requests_can_be_in_flight() {
    let host = Host::new();
    let session = host.create(shell("exec sleep 60"));
    let mut socket = UnixStream::connect(&host.socket).unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    write_frame(&mut socket, &Request::new(Some(41), ClientMessage::hello())).unwrap();
    assert!(matches!(
        response(&mut socket),
        (
            Some(41),
            ServerMessage::Welcome {
                version: PROTOCOL_VERSION,
                ..
            }
        )
    ));
    let requests = [
        (1, ClientMessage::Ping),
        (2, ClientMessage::List),
        (
            u64::MAX,
            ClientMessage::Kill {
                id: "missing".into(),
            },
        ),
        (3, ClientMessage::Ping),
    ];
    for (req, message) in &requests {
        write_frame(&mut socket, &Request::new(Some(*req), message.clone())).unwrap();
    }
    assert!(matches!(
        response(&mut socket),
        (Some(1), ServerMessage::Pong)
    ));
    assert!(matches!(
        response(&mut socket),
        (Some(2), ServerMessage::Sessions { sessions, .. }) if sessions.iter().any(|s| s.id == session.id)
    ));
    assert!(matches!(
        response(&mut socket),
        (Some(u64::MAX), ServerMessage::Error { code, .. }) if code == error_code::UNKNOWN_SESSION
    ));
    assert!(matches!(
        response(&mut socket),
        (Some(3), ServerMessage::Pong)
    ));
    // A request without an ID gets a reply without one.
    write_frame(&mut socket, &ClientMessage::Ping).unwrap();
    assert!(matches!(response(&mut socket), (None, ServerMessage::Pong)));
    // Whatever answers an attachment's requests carries none.
    write_frame(
        &mut socket,
        &Request::new(
            Some(5),
            ClientMessage::Input {
                data: b"x".to_vec(),
            },
        ),
    )
    .unwrap();
    assert!(matches!(
        response(&mut socket),
        (None, ServerMessage::Error { .. })
    ));
    write_frame(
        &mut socket,
        &Request::new(
            Some(6),
            ClientMessage::Attach {
                id: session.id.clone(),
                cols: 80,
                rows: 24,
                takeover: false,
                answers_queries: false,
                client_id: None,
                cell_width: None,
                cell_height: None,
            },
        ),
    )
    .unwrap();
    assert!(matches!(
        response(&mut socket),
        (None, ServerMessage::Attached { .. })
    ));
    host.kill(&session.id);
}

#[test]
fn protocol_4_control_requests_are_answered_on_one_connection() {
    let host = Host::new();
    let session = host.create(shell(
        "stty -echo; while IFS= read -r line; do printf 'GOT:%s\\n' \"$line\"; done",
    ));
    let mut socket = host.connect();
    let mut requests = vec![
        (1, ClientMessage::Subscribe),
        (
            2,
            ClientMessage::SendInput {
                id: session.id.clone(),
                data: b"typed\n".to_vec(),
            },
        ),
        (
            3,
            ClientMessage::Update {
                id: session.id.clone(),
                name: Some("renamed".into()),
                tags: None,
            },
        ),
        (
            4,
            ClientMessage::Screen {
                id: session.id.clone(),
                scrollback: false,
                max_lines: None,
            },
        ),
    ];
    // Requests naming a session that does not exist.
    let missing = Uuid::new_v4().to_string();
    for (req, message) in [
        (
            6,
            ClientMessage::Kill {
                id: missing.clone(),
            },
        ),
        (
            7,
            ClientMessage::Remove {
                id: missing.clone(),
            },
        ),
        (
            8,
            ClientMessage::SendInput {
                id: missing.clone(),
                data: b"x".to_vec(),
            },
        ),
        (
            9,
            ClientMessage::Screen {
                id: missing.clone(),
                scrollback: true,
                max_lines: None,
            },
        ),
        (
            10,
            ClientMessage::Update {
                id: missing.clone(),
                name: None,
                tags: Some(BTreeMap::new()),
            },
        ),
    ] {
        requests.push((req, message));
    }
    for (req, message) in &requests {
        write_frame(&mut socket, &Request::new(Some(*req), message.clone())).unwrap();
    }
    // Each reply echoes its request's ID, in order; events carry none.
    let mut replies = Vec::new();
    while replies.len() < requests.len() {
        match response(&mut socket) {
            (None, ServerMessage::Event { .. }) => {}
            (req, reply) => replies.push((req.unwrap(), reply)),
        }
    }
    assert!(matches!(&replies[0], (1, ServerMessage::Ok)), "{replies:?}");
    assert!(matches!(&replies[1], (2, ServerMessage::Ok)), "{replies:?}");
    assert!(matches!(&replies[2], (3, ServerMessage::Ok)), "{replies:?}");
    assert!(
        matches!(&replies[3], (4, ServerMessage::ScreenText { id, alternate_screen: false, .. }) if *id == session.id),
        "{replies:?}"
    );
    for (req, reply) in &replies[4..] {
        assert!(
            matches!(reply, ServerMessage::Error { code, message } if code == error_code::UNKNOWN_SESSION && message.contains(&missing)),
            "{req}: {reply:?}"
        );
    }
    // An attach's answer is attachment traffic, which carries no ID. And
    // Replace is only for a client that was told of a lower version.
    for (message, expected) in [
        (
            ClientMessage::Attach {
                id: missing.clone(),
                cols: 80,
                rows: 24,
                takeover: false,
                answers_queries: false,
                client_id: None,
                cell_width: None,
                cell_height: None,
            },
            error_code::UNKNOWN_SESSION,
        ),
        (ClientMessage::Replace, error_code::REQUEST_FAILED),
    ] {
        write_frame(&mut socket, &Request::new(Some(11), message)).unwrap();
        loop {
            match response(&mut socket) {
                (None, ServerMessage::Event { .. }) => {}
                (req, ServerMessage::Error { code, .. }) => {
                    assert_eq!(code, expected);
                    assert_eq!(req, (expected == error_code::REQUEST_FAILED).then_some(11));
                    break;
                }
                other => panic!("{other:?}"),
            }
        }
    }
    let renamed = host.wait(&session.id, |s| s.name == "renamed");
    assert_eq!(renamed.clients, 0);
    let mut typed = false;
    for _ in 0..250 {
        if let ServerMessage::ScreenText { text, .. } = host.call(ClientMessage::Screen {
            id: session.id.clone(),
            scrollback: true,
            max_lines: None,
        }) {
            typed = text.contains("GOT:typed");
            if typed {
                break;
            }
        }
        thread::sleep(Duration::from_millis(20));
    }
    assert!(typed);
    host.kill(&session.id);
}

#[test]
fn sessions_report_their_owner_tags_clients_and_creation_time() {
    let host = Host::new();
    let before = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;
    let tags = BTreeMap::from([
        ("tab".to_string(), "6d1f".to_string()),
        ("kind".to_string(), "agent".to_string()),
    ]);
    let request = |owner: Option<&str>, tags: BTreeMap<String, String>| ClientMessage::Create {
        request_id: Uuid::new_v4().to_string(),
        name: "tagged".into(),
        cwd: "/tmp".into(),
        command: shell("exec sleep 60"),
        env: BTreeMap::new(),
        cols: 80,
        rows: 24,
        owner: owner.map(str::to_string),
        tags,
        colors: None,
    };
    let created = match host.call(request(Some("com.example.cherry"), tags.clone())) {
        ServerMessage::Created { session } => session,
        other => panic!("{other:?}"),
    };
    assert_eq!(created.owner.as_deref(), Some("com.example.cherry"));
    assert_eq!(created.tags, tags);
    assert_eq!(created.clients, 0);
    assert!(created.created_at >= before, "{created:?}");
    let (_first, attached, ..) = host.attach(&created.id, 80, 24);
    assert_eq!(attached.created_at, created.created_at);
    let (_second, ..) = host.attach(&created.id, 80, 24);
    let listed = host.wait(&created.id, |s| s.clients == 2);
    assert!(listed.attached);
    assert_eq!((listed.owner, listed.tags), (created.owner, tags));
    // Metadata is bounded.
    let error = |message: ServerMessage| match message {
        ServerMessage::Error { message, .. } => message,
        other => panic!("{other:?}"),
    };
    let long_owner = "o".repeat(MAX_OWNER_BYTES + 1);
    assert!(error(host.call(request(Some(&long_owner), BTreeMap::new()))).contains("owner"));
    let too_many: BTreeMap<String, String> = (0..=MAX_TAGS)
        .map(|n| (n.to_string(), String::new()))
        .collect();
    assert!(error(host.call(request(None, too_many))).contains("tags"));
    assert_eq!(host.sessions().len(), 1);
    host.kill(&created.id);
}

#[test]
fn working_directories_are_expanded_on_the_host() {
    let host = Host::new();
    let home = host.sandbox.home.canonicalize().unwrap();
    fs::create_dir(home.join("project")).unwrap();
    for (cwd, expected) in [
        ("~", home.clone()),
        ("", home.clone()),
        ("~/project", home.join("project")),
        ("/tmp", fs::canonicalize("/tmp").unwrap()),
    ] {
        let created = match host.call(ClientMessage::Create {
            request_id: Uuid::new_v4().to_string(),
            name: "cwd".into(),
            cwd: cwd.into(),
            command: shell("pwd -P; exec sleep 60"),
            env: BTreeMap::new(),
            cols: 80,
            rows: 24,
            owner: None,
            tags: BTreeMap::new(),
            colors: None,
        }) {
            ServerMessage::Created { session } => session,
            other => panic!("{cwd}: {other:?}"),
        };
        assert_eq!(created.cwd, expected.to_string_lossy(), "{cwd}");
        let (mut socket, _, offset, snapshot) = host.attach(&created.id, 80, 24);
        let mut screen = Screen::new(80, 24, offset, &snapshot);
        screen.wait_text(&mut socket, &expected.to_string_lossy());
        host.kill(&created.id);
    }
}

#[test]
fn large_styled_history_still_attaches_within_one_frame() {
    let host = Host::new();
    let session = host.create(shell(&format!(
        "{STYLED_HISTORY}; printf 'HISTORY_%s\\n' DONE; exec sleep 60"
    )));
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    screen.wait_text(&mut socket, "HISTORY_DONE");
    drop(socket);
    host.wait(&session.id, |s| !s.attached);
    let (_socket, _, _, snapshot) = host.attach(&session.id, 80, 24);
    assert!(snapshot.len() <= MAX_SNAPSHOT_BYTES, "{}", snapshot.len());
    let screen = Screen::new(80, 24, 0, &snapshot);
    assert!(screen.text().contains("HISTORY_DONE"));
    assert!(!screen.terminal.inspect().unwrap().history.is_empty());
}

#[test]
fn attaching_during_live_output_reproduces_the_final_screen() {
    let host = Host::new();
    let session = host.create(shell(
        "i=0; while [ $i -lt 4000 ]; do printf 'row %05d\\n' $i; i=$((i+1)); [ $((i % 200)) -eq 0 ] && sleep 0.03; done; printf 'END\\n'; exec sleep 60",
    ));
    // Attach while the loop is still printing.
    let (mut probe, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut first = Screen::new(80, 24, offset, &snapshot);
    first.wait_text(&mut probe, "row 00");
    let mut attachments = Vec::new();
    for _ in 0..3 {
        let (socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
        attachments.push((socket, Screen::new(80, 24, offset, &snapshot)));
        thread::sleep(Duration::from_millis(20));
    }
    let mut transcript = String::new();
    for i in 0..4000 {
        transcript.push_str(&format!("row {i:05}\r\n"));
    }
    transcript.push_str("END\r\n");
    let mut reference = Terminal::new(80, 24, 1024 * 1024).unwrap();
    reference.feed(transcript.as_bytes());
    let expected = reference.inspect().unwrap();
    for (mut socket, mut screen) in attachments {
        while !screen.text().contains("END") {
            screen.receive(&mut socket);
        }
        let actual = screen.terminal.inspect().unwrap();
        assert_eq!(actual.active, expected.active);
        assert_eq!(actual.cursor, expected.cursor);
    }
}

/// Attach once the snapshot satisfies `ready`, re-attaching until it does.
fn attach_when(host: &Host, id: &str, ready: impl Fn(&str) -> bool) -> (UnixStream, Screen) {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let (socket, _, offset, snapshot) = host.attach(id, 80, 24);
        let screen = Screen::new(80, 24, offset, &snapshot);
        if ready(&screen.text()) {
            return (socket, screen);
        }
        drop(socket);
        assert!(Instant::now() < deadline, "{}", screen.text());
        thread::sleep(Duration::from_millis(15));
    }
}

#[test]
fn sequences_split_across_reads_survive_attach() {
    let host = Host::new();
    // A true-colour SGR and a UTF-8 character, each cut in two: the program
    // waits for the test between the halves.
    let session = host.create(shell_in(
        host.dir(),
        r#"stty raw -echo
printf 'A\033[38;2;255;0'
while [ ! -e "$CHERRY_TEST_DIR/second" ]; do sleep 0.01; done
printf ';0mRED\342\202'
while [ ! -e "$CHERRY_TEST_DIR/third" ]; do sleep 0.01; done
printf '\254END\r\n'
exec sleep 60"#,
    ));
    // Attached while the host holds half an SGR sequence...
    let first = attach_when(&host, &session.id, |text| text.contains('A'));
    assert!(!first.1.text().contains("RED"), "{}", first.1.text());
    fs::write(host.dir().join("second"), []).unwrap();
    // ...and while it holds half a UTF-8 character.
    let second = attach_when(&host, &session.id, |text| text.contains("ARED"));
    assert!(!second.1.text().contains('€'), "{}", second.1.text());
    fs::write(host.dir().join("third"), []).unwrap();
    let mut reference = Terminal::new(80, 24, 1024).unwrap();
    reference.feed(b"A\x1b[38;2;255;0;0mRED\xe2\x82\xacEND\r\n");
    let expected = reference.inspect().unwrap();
    for (mut socket, mut screen) in [first, second] {
        screen.wait_text(&mut socket, "END");
        assert!(screen.text().contains("ARED€END"), "{}", screen.text());
        assert_eq!(screen.terminal.inspect().unwrap().active, expected.active);
    }
}

#[test]
fn silent_attachments_are_evicted_and_the_grid_regrows() {
    let host = Host::with_env(&[("CHERRY_HOST_HEARTBEAT_TIMEOUT_MS", "600")]);
    let session = host.create(shell("exec sleep 60"));
    let (mut active, _, offset, snapshot) = host.attach(&session.id, 100, 30);
    let mut screen = Screen::new(100, 30, offset, &snapshot);
    let (mut silent, info, _, _) = host.attach(&session.id, 60, 20);
    assert_eq!((info.cols, info.rows), (60, 20));
    active
        .set_read_timeout(Some(Duration::from_millis(100)))
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut sizes = Vec::new();
    // The active client keeps sending heartbeats; the other goes quiet.
    while (screen.cols, screen.rows) != (100, 30) || sizes.is_empty() {
        assert!(Instant::now() < deadline, "grid never regrew: {sizes:?}");
        send(&mut active, &ClientMessage::Ping);
        while let Ok(Some(message)) = read_frame::<_, ServerMessage>(&mut active) {
            screen.apply(&message);
            if let ServerMessage::Attached { session, .. } = &message {
                sizes.push((session.cols, session.rows));
            }
        }
    }
    assert_eq!(sizes, vec![(60, 20), (100, 30)]);
    // The evicted client's connection was closed. (macOS refuses socket
    // options once the peer has closed, so this may fail.)
    let _ = silent.set_read_timeout(Some(Duration::from_secs(5)));
    loop {
        match read_frame::<_, ServerMessage>(&mut silent) {
            Ok(Some(_)) => {}
            Ok(None) => break,
            Err(error) => panic!("expected the host to close the connection: {error}"),
        }
    }
    let info = host.session(&session.id);
    assert!(info.attached);
    assert_eq!((info.cols, info.rows), (100, 30));
}

/// Read with a short timeout while pinging, until `done` holds.
fn ping_until(
    socket: &mut UnixStream,
    screen: &mut Screen,
    what: &str,
    done: impl Fn(&Screen) -> bool,
) {
    socket
        .set_read_timeout(Some(Duration::from_millis(100)))
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !done(screen) {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        send(socket, &ClientMessage::Ping);
        while let Ok(Some(message)) = read_frame::<_, ServerMessage>(socket) {
            screen.apply(&message);
        }
    }
}

#[test]
fn a_paste_held_for_a_program_that_stopped_reading_never_ends_the_attachment() {
    let host = Host::with_env(&[("CHERRY_HOST_HEARTBEAT_TIMEOUT_MS", "600")]);
    const SIZE: usize = 2 * 1024 * 1024;
    // Taken before the program starts, so its sleep ends more than 3 s
    // from now, whatever the speed of this machine.
    let started = Instant::now();
    // Busy for five heartbeat timeouts before it reads anything, as behind
    // a hung plugin or a stalled network read.
    let session = host.create(shell_in(
        host.dir(),
        &format!(
            r#"stty raw -echo; printf 'READY\r\n'; sleep 3; head -c {SIZE} > "$CHERRY_TEST_DIR/paste"; printf 'PASTED\r\n'; exec sleep 60"#
        ),
    ));
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    screen.wait_text(&mut socket, "READY");
    let payload: Vec<u8> = (0..SIZE).map(|i| b'a' + (i % 26) as u8).collect();
    let mut writer = socket.try_clone().unwrap();
    writer
        .set_write_timeout(Some(Duration::from_secs(20)))
        .unwrap();
    let chunks = payload.clone();
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let stopped = stop.clone();
    // Like a real client: the paste, then heartbeats, which wait behind it.
    let sender = thread::spawn(move || {
        for chunk in chunks.chunks(MAX_INPUT_BYTES) {
            write_frame(
                &mut writer,
                &ClientMessage::Input {
                    data: chunk.to_vec(),
                },
            )
            .unwrap();
        }
        while !stopped.load(std::sync::atomic::Ordering::SeqCst) {
            write_frame(&mut writer, &ClientMessage::Ping).unwrap();
            thread::sleep(Duration::from_millis(100));
        }
    });
    socket
        .set_read_timeout(Some(Duration::from_secs(20)))
        .unwrap();
    // Meanwhile the host keeps telling the client it is alive: its writes
    // are blocked, and silence would make it give up on the connection.
    let mut pongs_while_stuck = 0;
    while !screen.text().contains("PASTED") {
        match read_frame::<_, ServerMessage>(&mut socket) {
            Ok(Some(ServerMessage::Pong)) => {
                if started.elapsed() < Duration::from_millis(2500) {
                    pongs_while_stuck += 1;
                }
            }
            Ok(Some(message)) => screen.apply(&message),
            Ok(None) => panic!("the host closed the connection"),
            Err(error) => panic!("{error}"),
        }
    }
    assert!(started.elapsed() > Duration::from_secs(3));
    assert!(pongs_while_stuck >= 3, "{pongs_while_stuck} Pongs");
    stop.store(true, std::sync::atomic::Ordering::SeqCst);
    sender.join().unwrap();
    assert_eq!(fs::read(host.dir().join("paste")).unwrap(), payload);
    assert!(host.session(&session.id).attached);
}

#[test]
fn a_client_that_hangs_up_while_its_input_is_held_is_evicted_at_once() {
    // Far longer than this test: only the hangup can end the attachment.
    let host = Host::with_env(&[("CHERRY_HOST_HEARTBEAT_TIMEOUT_MS", "60000")]);
    let session = host.create(shell_in(
        host.dir(),
        r#"stty raw -echo; printf ready > "$CHERRY_TEST_DIR/ready"; exec sleep 60"#,
    ));
    wait_until("program", || host.dir().join("ready").exists());
    // A client pastes far more than the program reads (nothing), then
    // hangs up while its writes are blocked.
    let (paster, _, _, _) = host.attach(&session.id, 60, 20);
    let mut writer = paster.try_clone().unwrap();
    writer
        .set_write_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let sent = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counted = sent.clone();
    let pasting = thread::spawn(move || {
        let mut frame = Vec::new();
        write_frame(
            &mut frame,
            &ClientMessage::Input {
                data: vec![b'x'; MAX_INPUT_BYTES],
            },
        )
        .unwrap();
        for _ in 0..40 {
            if writer.write_all(&frame).is_err() {
                break;
            }
            counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        }
    });
    let (mut active, info, offset, snapshot) = host.attach(&session.id, 100, 30);
    assert_eq!((info.cols, info.rows), (60, 20));
    let mut screen = Screen::new(60, 20, offset, &snapshot);
    // The host holds the paste: the paster's writes stop being accepted.
    wait_until("the paste to be held", || {
        let before = sent.load(std::sync::atomic::Ordering::SeqCst);
        thread::sleep(Duration::from_millis(300));
        before > 16 && sent.load(std::sync::atomic::Ordering::SeqCst) == before
    });
    assert!(host.session(&session.id).attached);
    // Its process ends: the blocked write fails and the connection closes.
    let _ = paster.shutdown(std::net::Shutdown::Both);
    pasting.join().unwrap();
    drop(paster);
    ping_until(&mut active, &mut screen, "the grid to regrow", |screen| {
        (screen.cols, screen.rows) == (100, 30)
    });
    let info = host.session(&session.id);
    assert!(info.attached);
    assert_eq!((info.cols, info.rows), (100, 30));
}

#[test]
fn another_clients_stuck_paste_does_not_stall_this_client() {
    // Longer than this test: the paster is never evicted meanwhile.
    let host = Host::with_env(&[("CHERRY_HOST_HEARTBEAT_TIMEOUT_MS", "20000")]);
    let session = host.create(shell_in(
        host.dir(),
        r#"stty raw -echo; printf ready > "$CHERRY_TEST_DIR/ready"; exec sleep 60"#,
    ));
    wait_until("program", || host.dir().join("ready").exists());
    let (paster, _, _, _) = host.attach(&session.id, 80, 24);
    let mut writer = paster.try_clone().unwrap();
    writer
        .set_write_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let pasting = thread::spawn(move || {
        let mut frame = Vec::new();
        write_frame(
            &mut frame,
            &ClientMessage::Input {
                data: vec![b'x'; MAX_INPUT_BYTES],
            },
        )
        .unwrap();
        for _ in 0..40 {
            if writer.write_all(&frame).is_err() {
                break;
            }
        }
    });
    // Let the paste fill the session's input budget.
    thread::sleep(Duration::from_millis(300));
    let (mut other, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    // Its resizes and heartbeats are still read and answered.
    let started = Instant::now();
    send(
        &mut other,
        &ClientMessage::Resize {
            cols: 80,
            rows: 20,
            cell_width: None,
            cell_height: None,
        },
    );
    ping_until(&mut other, &mut screen, "the resize", |screen| {
        (screen.cols, screen.rows) == (80, 20)
    });
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "resize took {:?}",
        started.elapsed()
    );
    assert!(host.session(&session.id).attached);
    drop(paster);
    host.kill(&session.id);
    pasting.join().unwrap();
}

#[test]
fn a_paste_into_a_slow_reader_is_not_mistaken_for_silence() {
    let host = Host::with_env(&[("CHERRY_HOST_HEARTBEAT_TIMEOUT_MS", "300")]);
    const CHUNK: usize = 64 * 1024;
    const CHUNKS: usize = 20;
    const SIZE: usize = CHUNK * CHUNKS;
    // A chunk at a time with a pause after each (one byte per read, so the
    // chunks are exact): the backlog drains for at least CHUNKS pauses,
    // however fast the machine, while the program keeps making progress.
    let session = host.create(shell_in(
        host.dir(),
        &format!(
            r#"stty raw -echo; printf 'READY\r\n'; i=0; while [ $i -lt {CHUNKS} ]; do dd bs=1 count={CHUNK} 2>/dev/null; sleep 0.1; i=$((i + 1)); done > "$CHERRY_TEST_DIR/paste"; printf 'PASTED\r\n'; exec sleep 60"#
        ),
    ));
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    screen.wait_text(&mut socket, "READY");
    let payload: Vec<u8> = (0..SIZE).map(|i| b'a' + (i % 26) as u8).collect();
    let mut writer = socket.try_clone().unwrap();
    writer
        .set_write_timeout(Some(Duration::from_secs(20)))
        .unwrap();
    let chunks = payload.clone();
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let stopped = stop.clone();
    let started = Instant::now();
    // Like a real client: the paste, then heartbeats (which cannot overtake
    // the paste).
    let sender = thread::spawn(move || {
        for chunk in chunks.chunks(MAX_INPUT_BYTES) {
            write_frame(
                &mut writer,
                &ClientMessage::Input {
                    data: chunk.to_vec(),
                },
            )
            .unwrap();
        }
        while !stopped.load(std::sync::atomic::Ordering::SeqCst) {
            write_frame(&mut writer, &ClientMessage::Ping).unwrap();
            thread::sleep(Duration::from_millis(100));
        }
    });
    socket
        .set_read_timeout(Some(Duration::from_secs(30)))
        .unwrap();
    screen.wait_text(&mut socket, "PASTED");
    // Every pause follows input sent after `started`.
    assert!(started.elapsed() >= Duration::from_millis(100) * CHUNKS as u32);
    stop.store(true, std::sync::atomic::Ordering::SeqCst);
    sender.join().unwrap();
    assert_eq!(fs::read(host.dir().join("paste")).unwrap(), payload);
    assert!(host.session(&session.id).attached);
}

#[test]
fn a_client_whose_input_is_held_hears_whether_the_program_consumes_it() {
    // A client whose paste the host holds back sees its writes blocked, and
    // cannot tell a slow program from a stuck one. The host tells it with a
    // Pong about once a second while the program works through the input.
    for reads in [true, false] {
        // The host's own heartbeats while input is held come every third of
        // this, after the test.
        let host = Host::with_env(&[("CHERRY_HOST_HEARTBEAT_TIMEOUT_MS", "20000")]);
        let program = if reads {
            // Far slower than the paste arrives, with pauses between reads.
            r#"while :; do dd bs=1 count=16384 2>/dev/null; sleep 0.05; done > /dev/null"#
        } else {
            "exec sleep 60"
        };
        let session = host.create(shell_in(
            host.dir(),
            &format!(r#"stty raw -echo; printf 'READY\r\n'; {program}"#),
        ));
        let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
        let mut screen = Screen::new(80, 24, offset, &snapshot);
        screen.wait_text(&mut socket, "READY");
        let mut writer = socket.try_clone().unwrap();
        writer
            .set_write_timeout(Some(Duration::from_secs(20)))
            .unwrap();
        // Twice what the host holds for a session, and never a Ping.
        let sender = thread::spawn(move || {
            for _ in 0..32 {
                let data = vec![b'x'; MAX_INPUT_BYTES];
                if write_frame(&mut writer, &ClientMessage::Input { data }).is_err() {
                    break;
                }
            }
        });
        socket
            .set_read_timeout(Some(Duration::from_millis(200)))
            .unwrap();
        let started = Instant::now();
        let (mut pongs, mut settled_pongs) = (0, 0);
        while started.elapsed() < Duration::from_secs(3) {
            match read_frame::<_, ServerMessage>(&mut socket) {
                Ok(Some(ServerMessage::Pong)) => {
                    pongs += 1;
                    // The PTY's own buffer may still take the first bytes
                    // of the paste in its first moments, which the host
                    // cannot tell from the program reading them: once it
                    // is full, only the program makes progress.
                    if started.elapsed() > Duration::from_secs(1) {
                        settled_pongs += 1;
                    }
                }
                Ok(Some(message)) => screen.apply(&message),
                Ok(None) => panic!("the host closed the connection"),
                Err(_) => {}
            }
        }
        if reads {
            assert!(pongs >= 2, "{pongs} Pongs");
        } else {
            assert_eq!(settled_pongs, 0, "{pongs} Pongs");
        }
        assert!(host.session(&session.id).attached);
        host.kill(&session.id);
        drop(socket);
        sender.join().unwrap();
    }
}

#[test]
fn detach_delivers_input_sent_before_it() {
    let host = Host::new();
    let session = host.create(vec!["/bin/sh".into()]);
    for round in 0..10 {
        let marker = host.dir().join(format!("marker-{round}"));
        let (mut socket, _, _, _) = host.attach(&session.id, 80, 24);
        // One write: the input and the detach arrive together.
        let mut bytes = Vec::new();
        write_frame(
            &mut bytes,
            &ClientMessage::Input {
                data: format!("echo marker > '{}'\r", marker.display()).into_bytes(),
            },
        )
        .unwrap();
        write_frame(&mut bytes, &ClientMessage::Detach).unwrap();
        socket.write_all(&bytes).unwrap();
        loop {
            match receive(&mut socket) {
                ServerMessage::Ok => break,
                ServerMessage::Output { .. } => {}
                other => panic!("{other:?}"),
            }
        }
        wait_until(&format!("marker {round}"), || marker.exists());
        host.wait(&session.id, |s| !s.attached);
    }
}

#[test]
fn large_pastes_are_delivered_without_disconnecting() {
    let host = Host::new();
    const SIZE: usize = 5 * 1024 * 1024;
    let session = host.create(shell_in(
        host.dir(),
        &format!(
            "stty raw -echo; printf 'READY\\r\\n'; head -c {SIZE} > \"$CHERRY_TEST_DIR/paste\"; printf 'PASTED\\r\\n'; exec sleep 60"
        ),
    ));
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    screen.wait_text(&mut socket, "READY");
    let payload: Vec<u8> = (0..SIZE).map(|i| b'a' + (i % 26) as u8).collect();
    let mut writer = socket.try_clone().unwrap();
    writer
        .set_write_timeout(Some(Duration::from_secs(30)))
        .unwrap();
    let chunks = payload.clone();
    let sender = thread::spawn(move || {
        for chunk in chunks.chunks(MAX_INPUT_BYTES) {
            write_frame(
                &mut writer,
                &ClientMessage::Input {
                    data: chunk.to_vec(),
                },
            )
            .unwrap();
        }
    });
    socket
        .set_read_timeout(Some(Duration::from_secs(30)))
        .unwrap();
    // Replies and output keep flowing while the paste drains.
    screen.wait_text(&mut socket, "PASTED");
    sender.join().unwrap();
    assert_eq!(fs::read(host.dir().join("paste")).unwrap(), payload);
    assert!(host.session(&session.id).attached);
    send(&mut socket, &ClientMessage::Ping);
    loop {
        match screen.receive(&mut socket) {
            ServerMessage::Pong => break,
            ServerMessage::Output { .. } => {}
            other => panic!("{other:?}"),
        }
    }
}

#[test]
fn stdio_gateway_flushes_binary_frames_without_newlines() {
    let host = Host::new();
    let mut gateway = host
        .sandbox
        .command("gateway")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .spawn()
        .unwrap();
    let mut stdin = gateway.stdin.take().unwrap();
    let mut stdout = gateway.stdout.take().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    let reader = thread::spawn(move || {
        use std::io::Read;
        let mut preamble = vec![0u8; format!("CHERRY-GATEWAY {PROTOCOL_VERSION}\n").len()];
        let result = stdout
            .read_exact(&mut preamble)
            .map(|_| preamble.to_vec())
            .and_then(|preamble| Ok((preamble, read_frame::<_, ServerMessage>(&mut stdout)?)));
        let _ = tx.send(result);
    });
    write_frame(&mut stdin, &ClientMessage::hello()).unwrap();
    let result = rx.recv_timeout(Duration::from_secs(3));
    drop(stdin);
    let _ = gateway.kill();
    let _ = gateway.wait();
    reader.join().unwrap();
    let (preamble, welcome) = result.unwrap().unwrap();
    assert_eq!(
        preamble,
        format!("CHERRY-GATEWAY {PROTOCOL_VERSION}\n").as_bytes()
    );
    assert!(matches!(welcome, Some(ServerMessage::Welcome { .. })));
}

#[test]
fn bursts_of_small_frames_are_all_handled_promptly() {
    let host = Host::new();
    let session = host.create(shell_in(
        host.dir(),
        r#"stty raw -echo; printf 'READY\r\n'; head -c 500 > "$CHERRY_TEST_DIR/bytes"; printf 'GOT\r\n'; exec sleep 60"#,
    ));
    let (mut socket, _, offset, snapshot) = host.attach(&session.id, 80, 24);
    let mut screen = Screen::new(80, 24, offset, &snapshot);
    screen.wait_text(&mut socket, "READY");
    // Far more frames than the session's command queue holds, in one write.
    let mut burst = Vec::new();
    for i in 0..500 {
        write_frame(
            &mut burst,
            &ClientMessage::Input {
                data: vec![b'a' + (i % 26) as u8],
            },
        )
        .unwrap();
    }
    socket.write_all(&burst).unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    screen.wait_text(&mut socket, "GOT");
    let expected: Vec<u8> = (0..500).map(|i| b'a' + (i % 26) as u8).collect();
    assert_eq!(fs::read(host.dir().join("bytes")).unwrap(), expected);
}
