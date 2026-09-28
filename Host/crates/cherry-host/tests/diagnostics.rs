//! What the daemon says about itself: its build (in `Welcome` and each
//! session's holder), `Status`, its PID file, and its log.
mod support;

use cherry_protocol::*;
use std::{
    fs,
    os::unix::{fs::PermissionsExt, net::UnixStream},
    path::Path,
    process::Stdio,
    time::Duration,
};
use support::*;

fn welcome_build(socket: &Path) -> Option<String> {
    let mut stream = UnixStream::connect(socket).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    write_frame(&mut stream, &ClientMessage::hello()).unwrap();
    match receive(&mut stream) {
        ServerMessage::Welcome { build, .. } => build,
        other => panic!("expected welcome, received {other:?}"),
    }
}

fn status(host: &Host) -> HostStatus {
    match host.call(ClientMessage::Status) {
        ServerMessage::Status { status } => status,
        other => panic!("expected status, received {other:?}"),
    }
}

#[test]
fn the_daemon_describes_itself_and_counts_against_its_limits() {
    let host = Host::new();
    assert_eq!(welcome_build(&host.socket).as_deref(), Some(BUILD));
    let before = status(&host);
    assert_eq!(before.version, PROTOCOL_VERSION);
    assert_eq!(before.build, BUILD);
    assert_eq!(before.pid, host.child.id());
    assert_eq!(before.host_id, host.host_id());
    assert_eq!(before.socket, host.socket.display().to_string());
    assert_eq!(
        Path::new(&before.state_dir),
        host.sandbox.state_dir().as_path()
    );
    // Its stderr is the test's, not host.log.
    assert_eq!(before.log_path, None);
    assert_eq!(before.max_sessions, 128);
    assert_eq!(before.max_connections, 1024);
    assert_eq!((before.sessions, before.running_sessions), (0, 0));
    assert!(before.connections >= 1, "{before:?}");
    assert!(before.started_at > 0);
    assert!(!before.executable_changed);
    assert!(before.fd_limit.is_some_and(|limit| limit > 0));

    let session = host.create(shell("exec sleep 60"));
    assert_eq!(session.holder_build.as_deref(), Some(BUILD));
    let after = status(&host);
    assert_eq!((after.sessions, after.running_sessions), (1, 1));
    assert_eq!((after.holders_registered, after.holders_expected), (1, 0));
    assert!(after.uptime_ms >= before.uptime_ms);
    host.kill(&session.id);
}

#[test]
fn holders_keep_the_build_they_started_with_across_daemons() {
    let old = "20000101000000.0ld0000";
    let mut host = Host::with_env(&[("CHERRY_HOST_TEST_BUILD", old)]);
    assert_eq!(welcome_build(&host.socket).as_deref(), Some(old));
    let session = host.create(shell("exec sleep 60"));
    assert_eq!(session.holder_build.as_deref(), Some(old));
    // The next daemon is of another build; the holder is not.
    host.crash();
    let sandbox_env: Vec<(String, String)> =
        vec![("CHERRY_HOST_KILL_GRACE_MS".into(), "100".into())];
    host.child = spawn_serve(&host.sandbox, &sandbox_env, None);
    host.wait_ready();
    assert_eq!(welcome_build(&host.socket).as_deref(), Some(BUILD));
    let adopted = host.adopted();
    let held = adopted.iter().find(|s| s.id == session.id).unwrap();
    assert_eq!(held.holder_build.as_deref(), Some(old));
    assert_eq!(status(&host).build, BUILD);
    host.kill(&session.id);
}

#[test]
fn the_daemon_keeps_a_pid_file_while_it_runs() {
    let host = Host::new();
    let pid_file = host.sandbox.state_dir().join("host.pid");
    let record: serde_json::Value = serde_json::from_slice(&fs::read(&pid_file).unwrap()).unwrap();
    assert_eq!(record["pid"], host.child.id());
    // When it started, so that a process that got the pid later is not it.
    assert!(record["started"]
        .as_str()
        .is_some_and(|started| !started.is_empty()));
    assert_eq!(record["build"], BUILD);
    assert_eq!(record["socket"], host.socket.display().to_string());
    assert!(matches!(
        host.call(ClientMessage::Shutdown),
        ServerMessage::Ok
    ));
    wait_until("the PID file to go", || !pid_file.exists());
}

#[test]
fn a_started_daemon_logs_who_it_is_and_moves_a_long_log_aside() {
    let sandbox = Sandbox::new();
    let _daemon = Started(sandbox.socket.clone());
    let state = sandbox
        .state_base()
        .join(cherry_protocol::state_key(&sandbox.socket));
    fs::create_dir_all(&state).unwrap();
    fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();
    let log = state.join("host.log");
    fs::write(&log, "an old line\n".repeat(20)).unwrap();
    let output = sandbox
        .command("start")
        .env("CHERRY_HOST_LOG_MAX_BYTES", "100")
        .stderr(Stdio::piped())
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(sandbox.state_dir(), state);
    let old = fs::read_to_string(state.join("host.log.1")).unwrap();
    assert!(old.starts_with("an old line\n"), "{old}");
    let text = fs::read_to_string(&log).unwrap();
    let first = text.lines().next().unwrap_or_default();
    // 2026-09-27T10:15:00.123Z cherry-host[1234] daemon <build>: started (…)
    let (time, rest) = first.split_once(' ').unwrap();
    assert!(time.ends_with('Z') && time.len() == 24, "{first}");
    assert!(rest.starts_with("cherry-host["), "{first}");
    assert!(
        rest.contains(&format!(
            "] daemon {BUILD}: started (protocol {PROTOCOL_VERSION}, pid "
        )),
        "{first}"
    );
    let host = status_of(&sandbox.socket);
    assert_eq!(host.log_path.as_deref(), Some(log.to_str().unwrap()));
    assert!(
        first.contains(&format!("cherry-host[{}]", host.pid)),
        "{first}"
    );
    // Within the limit, the log is kept as it is.
    stop_daemon(&sandbox.socket);
    let output = sandbox
        .command("start")
        .env("CHERRY_HOST_LOG_MAX_BYTES", "1000000")
        .output()
        .unwrap();
    assert!(output.status.success());
    let kept = fs::read_to_string(&log).unwrap();
    assert!(kept.starts_with(&text), "{kept}");
    assert_eq!(kept.matches(": started (").count(), 2, "{kept}");
}

fn status_of(socket: &Path) -> HostStatus {
    let mut stream = quiet_connect(socket).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    send(&mut stream, &ClientMessage::Status);
    match receive(&mut stream) {
        ServerMessage::Status { status } => status,
        other => panic!("expected status, received {other:?}"),
    }
}

#[test]
fn the_daemons_log_lines_name_it_and_its_build() {
    let sandbox = Sandbox::new();
    let _daemon = Started(sandbox.socket.clone());
    let output = sandbox.command("start").output().unwrap();
    assert!(output.status.success());
    let log = sandbox.state_dir().join("host.log");
    let host_pid = status_of(&sandbox.socket).pid;
    let mut socket = quiet_connect(&sandbox.socket).unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    send(
        &mut socket,
        &create_request(uuid::Uuid::new_v4().to_string(), shell("exec sleep 60")),
    );
    let session = match receive(&mut socket) {
        ServerMessage::Created { session } => session,
        other => panic!("create failed: {other:?}"),
    };
    let holder = holder_of(&sandbox, &session.id);
    unsafe {
        libc::kill(holder, libc::SIGKILL);
    }
    wait_until("the daemon to log the lost holder", || {
        fs::read_to_string(&log).is_ok_and(|text| {
            text.lines().any(|line| {
                line.contains(&format!(
                    "cherry-host[{host_pid}] daemon {BUILD}: session {}",
                    session.id
                ))
            })
        })
    });
    let _ = session
        .pid
        .map(|pid| unsafe { libc::kill(pid as i32, libc::SIGKILL) });
}

#[test]
fn a_running_daemon_moves_a_long_log_aside_and_its_holders_follow() {
    let sandbox = Sandbox::new();
    let _daemon = Started(sandbox.socket.clone());
    let output = sandbox
        .command("start")
        .env("CHERRY_HOST_LOG_MAX_BYTES", "4000")
        .env("CHERRY_HOST_LOG_CHECK_MS", "50")
        .output()
        .unwrap();
    assert!(output.status.success());
    let log = sandbox.state_dir().join("host.log");
    let old = sandbox.state_dir().join("host.log.1");
    let mut socket = quiet_connect(&sandbox.socket).unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    send(
        &mut socket,
        &create_request(uuid::Uuid::new_v4().to_string(), shell("exit 3")),
    );
    let session = match receive(&mut socket) {
        ServerMessage::Created { session } => session,
        other => panic!("create failed: {other:?}"),
    };
    drop(socket);
    // The log passes its limit while the daemon runs (as its own lines
    // would): it is moved aside, and the daemon's next line starts anew.
    {
        use std::io::Write;
        let mut file = fs::OpenOptions::new().append(true).open(&log).unwrap();
        file.write_all("padding\n".repeat(600).as_bytes()).unwrap();
    }
    wait_until("the running daemon to move its log aside", || {
        old.exists()
            && fs::read_to_string(&log)
                .is_ok_and(|text| text.contains("moved the log past 4000 bytes aside"))
    });
    assert!(fs::read_to_string(&old).unwrap().contains("padding"));
    assert!(!fs::read_to_string(&log).unwrap().contains("padding"));
    // Its holder, which was given the old file, writes to the new one: its
    // session exited, and with the daemon gone and its manifest removed it
    // says so and exits.
    let pid = status_of(&sandbox.socket).pid as i32;
    unsafe {
        libc::kill(pid, libc::SIGKILL);
    }
    fs::remove_file(
        sandbox
            .state_dir()
            .join(format!("sessions/{}.json", session.id)),
    )
    .unwrap();
    wait_until_for(
        "the holder to log into the new file",
        Duration::from_secs(45),
        || {
            fs::read_to_string(&log).is_ok_and(|text| {
                text.contains(&format!(
                    "holder {BUILD}: session {}: its manifest is gone",
                    session.id
                ))
            })
        },
    );
    assert!(!fs::read_to_string(&old)
        .unwrap()
        .contains("its manifest is gone"));
}

fn json_of(command: &mut std::process::Command) -> serde_json::Value {
    let output = command.output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).unwrap()
}

#[test]
fn version_json_names_the_protocol_build_and_platform() {
    let sandbox = Sandbox::new();
    let report = json_of(sandbox.command("version").arg("--json"));
    assert_eq!(report["protocol"], PROTOCOL_VERSION);
    assert_eq!(report["build"], BUILD);
    assert_eq!(report["arch"], std::env::consts::ARCH);
    assert_eq!(report["os"], std::env::consts::OS);
    assert_eq!(report["min_macos"].is_string(), cfg!(target_os = "macos"));
    // Nothing was started.
    assert!(!sandbox.socket.exists());
}

#[test]
fn status_json_describes_the_host_at_the_socket_without_starting_or_replacing_one() {
    // No host: said so, and none is started.
    let sandbox = Sandbox::new();
    let report = json_of(sandbox.command("status").arg("--json"));
    assert_eq!(report["running"], false);
    assert_eq!(report["state"], "absent");
    assert!(report["host_id"].is_null());
    assert!(!sandbox.socket.exists());

    let host = Host::new();
    let report = json_of(host.sandbox.command("status").arg("--json"));
    assert_eq!(report["running"], true);
    assert_eq!(report["state"], "ready");
    assert_eq!(report["protocol"], PROTOCOL_VERSION);
    assert_eq!(report["build"], BUILD);
    assert_eq!(report["host_id"], host.host_id());
    // The same daemon still serves, with no session made.
    let after = status(&host);
    assert_eq!(after.pid, host.child.id());
    assert_eq!(after.sessions, 0);
}

#[test]
fn status_json_reports_a_socket_it_cannot_trust_as_json_and_exits_0() {
    // A socket directory other accounts can read: never trusted, and said
    // so as JSON, so a client probing a machine can read why.
    let sandbox = Sandbox::new();
    let shared = sandbox.path().join("shared");
    fs::create_dir(&shared).unwrap();
    fs::set_permissions(&shared, fs::Permissions::from_mode(0o755)).unwrap();
    let output = std::process::Command::new(&sandbox.bin)
        .args(["status", "--json", "--socket"])
        .arg(shared.join("host.sock"))
        .env("HOME", &sandbox.home)
        .output()
        .unwrap();
    assert_eq!(
        output.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let report: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(report["running"], false);
    assert_eq!(report["state"], "error");
    assert!(report["host_id"].is_null());
    let error = report["error"].as_str().unwrap();
    assert!(error.contains(&shared.display().to_string()), "{error}");
    assert!(!shared.join("host.sock").exists());
}
