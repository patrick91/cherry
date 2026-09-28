//! `cherry status` (what the daemon says about itself and its sessions) and
//! `cherry doctor` (what is wrong with the local host, and how to fix it).
//! Neither starts a host.
use crate::{handover::own_build, transport::Transport, unexpected};
use anyhow::Result;
use cherry_protocol::{
    error_code, read_frame, write_frame, ClientMessage, HostStatus, ServerMessage, SessionInfo,
    SessionState, PROTOCOL_VERSION,
};
use serde_json::json;
use std::{
    collections::BTreeMap,
    fs, io,
    os::unix::{
        fs::{FileTypeExt, MetadataExt},
        net::UnixStream,
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Duration,
};

/// `cherry status`'s exit status when no host is running.
pub const NOT_RUNNING: u32 = 3;
/// How long `doctor` waits for each answer from a daemon.
const DOCTOR_WAIT: Duration = Duration::from_secs(3);
/// A log longer than this is a problem: something writes to it far more
/// than it should. (It is moved aside when the next daemon starts once it
/// passes cherry-host's own limit, 8 MiB.)
const LARGE_LOG_BYTES: u64 = 64 * 1024 * 1024;
/// A daemon needs this many descriptors beyond its connection limit: its
/// listener, sessions' links and the files it opens.
const FD_HEADROOM: u64 = 256;

/// Who answered `cherry status`.
pub struct Greeting<'a> {
    pub host_id: &'a str,
    pub build: Option<&'a str>,
    /// The SSH destination, for a remote host.
    pub remote: Option<&'a str>,
}

/// The build a cherry or cherry-host executable reports (`--version`).
pub fn executable_build(executable: &Path) -> Option<String> {
    let output = Command::new(executable)
        .arg("--version")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()
        .filter(|output| output.status.success())?;
    cherry_protocol::build_in_version(&String::from_utf8_lossy(&output.stdout)).map(str::to_owned)
}

/// Whether something may be listening at `socket`: false only when nothing
/// is there or nothing accepts connections on it.
pub fn listening(socket: &Path) -> bool {
    match cherry_protocol::connect_verified(socket) {
        Ok(_) => true,
        Err(error) => !matches!(
            error.kind(),
            io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
        ),
    }
}

fn client_json() -> serde_json::Value {
    json!({ "build": own_build(), "protocol": PROTOCOL_VERSION })
}

/// `cherry status` when no host runs at `socket`.
pub fn not_running(socket: &Path, as_json: bool) -> Result<u32> {
    let own = own_build();
    let state = cherry_protocol::state_dir(socket).ok();
    let log = state
        .as_ref()
        .map(|state| state.join("host.log"))
        .filter(|log| log.exists());
    if as_json {
        crate::print(&format!(
            "{}\n",
            json!({
                "running": false,
                "socket": socket,
                "state_dir": state,
                "log_path": log,
                "client": client_json(),
            })
        ))?;
    } else {
        let mut text = format!("cherry-host is not running at {}\n", socket.display());
        if let Some(log) = log {
            text.push_str(&format!("  log          {}\n", log.display()));
        }
        text.push_str(&format!(
            "this cherry    {own}, protocol {PROTOCOL_VERSION}\n"
        ));
        crate::print(&text)?;
    }
    Ok(NOT_RUNNING)
}

/// `cherry status` on a connection that said Hello: the host's `Status`
/// (a host that predates it says less), then its sessions.
pub fn status(transport: &mut Transport, greeting: &Greeting, as_json: bool) -> Result<u32> {
    let rpc = crate::transport::RPC_TIMEOUT;
    transport.send(&ClientMessage::Status)?;
    let host = match transport.receive(rpc)? {
        ServerMessage::Status { status } => Some(status),
        ServerMessage::Error { code, .. } if code == error_code::UNSUPPORTED_OPERATION => None,
        message => {
            unexpected("status", message)?;
            unreachable!()
        }
    };
    transport.send(&ClientMessage::List)?;
    let (sessions, pending_holders) = match transport.receive(rpc)? {
        ServerMessage::Sessions {
            sessions,
            pending_holders,
            ..
        } => (sessions, pending_holders),
        message => {
            unexpected("session list", message)?;
            unreachable!()
        }
    };
    let text = if as_json {
        let sessions: Vec<_> = sessions.iter().map(session_json).collect();
        format!(
            "{}\n",
            json!({
                "running": true,
                "remote": greeting.remote,
                "host_id": greeting.host_id,
                "build": greeting.build,
                "protocol": PROTOCOL_VERSION,
                "host": host,
                "pending_holders": pending_holders,
                "sessions": sessions,
                "client": client_json(),
            })
        )
    } else {
        status_text(greeting, host.as_ref(), &sessions, pending_holders)
    };
    crate::print(&text)?;
    Ok(0)
}

fn session_json(session: &SessionInfo) -> serde_json::Value {
    json!({
        "id": session.id,
        "name": session.name,
        "state": session.state,
        "pid": session.pid,
        "exit_code": session.exit_code,
        "clients": session.clients,
        "owner": session.owner,
        "created_at": session.created_at,
        "holder_build": session.holder_build,
    })
}

fn status_text(
    greeting: &Greeting,
    host: Option<&HostStatus>,
    sessions: &[SessionInfo],
    pending_holders: u32,
) -> String {
    let mut text = String::new();
    let own = own_build();
    let build = greeting.build.unwrap_or("(build not reported)");
    let on = greeting
        .remote
        .map(|remote| format!(" on {remote}"))
        .unwrap_or_default();
    match host {
        Some(host) => {
            text.push_str(&format!(
                "cherry-host{on} {build}, protocol {}, pid {}, up {}\n",
                host.version,
                host.pid,
                duration(host.uptime_ms)
            ));
            let row = |text: &mut String, label: &str, value: String| {
                text.push_str(&format!("  {label:<12} {value}\n"));
            };
            row(&mut text, "host id", host.host_id.clone());
            row(&mut text, "socket", host.socket.clone());
            row(&mut text, "state", host.state_dir.clone());
            row(
                &mut text,
                "log",
                host.log_path
                    .clone()
                    .unwrap_or_else(|| "its standard error (not a file)".into()),
            );
            if let Some(executable) = &host.executable {
                let changed = if host.executable_changed {
                    " (replaced or removed since it started; `cherry restart` runs the new one)"
                } else {
                    ""
                };
                row(&mut text, "executable", format!("{executable}{changed}"));
            }
            row(
                &mut text,
                "sessions",
                format!(
                    "{} of {} ({} running)",
                    host.sessions, host.max_sessions, host.running_sessions
                ),
            );
            row(
                &mut text,
                "connections",
                format!("{} of {}", host.connections, host.max_connections),
            );
            let mut holders = format!(
                "{} registered, {} expected",
                host.holders_registered, host.holders_expected
            );
            if host.lost_sessions > 0 {
                holders.push_str(&format!(", {} lost when it started", host.lost_sessions));
            }
            row(&mut text, "holders", holders);
            if let Some(limit) = host.fd_limit {
                row(&mut text, "descriptors", limit.to_string());
            }
        }
        None => {
            text.push_str(&format!(
                "cherry-host{on} {build}, protocol {PROTOCOL_VERSION} (it predates `status`: only its sessions are known)\n  host id      {}\n",
                greeting.host_id
            ));
            if pending_holders > 0 {
                text.push_str(&format!("  holders      {pending_holders} expected\n"));
            }
        }
    }
    text.push_str(&format!(
        "this cherry    {own}, protocol {PROTOCOL_VERSION}\n"
    ));
    if !sessions.is_empty() {
        text.push('\n');
        text.push_str(&format!(
            "{:<36}  {:<7}  {:<24}  NAME\n",
            "SESSION", "STATE", "HOLDER BUILD"
        ));
        for session in sessions {
            let state = match session.state {
                SessionState::Running => "running",
                SessionState::Exited => "exited",
            };
            text.push_str(&format!(
                "{:<36}  {:<7}  {:<24}  {}\n",
                session.id,
                state,
                session.holder_build.as_deref().unwrap_or("-"),
                session.name
            ));
        }
    }
    text
}

/// `3d 4h`, `2h 5m`, `4m 10s`, `12s`.
fn duration(ms: u64) -> String {
    let seconds = ms / 1000;
    let (days, hours, minutes) = (seconds / 86_400, seconds / 3_600 % 24, seconds / 60 % 60);
    match (days, hours, minutes) {
        (0, 0, 0) => format!("{seconds}s"),
        (0, 0, _) => format!("{minutes}m {}s", seconds % 60),
        (0, _, _) => format!("{hours}h {minutes}m"),
        _ => format!("{days}d {hours}h"),
    }
}

/// What `doctor` found: each check's line, and how many were problems.
#[derive(Default)]
struct Report {
    text: String,
    problems: usize,
}

impl Report {
    fn ok(&mut self, what: impl AsRef<str>) {
        self.text.push_str(&format!("ok       {}\n", what.as_ref()));
    }

    fn problem(&mut self, what: impl AsRef<str>, fix: impl AsRef<str>) {
        self.problems += 1;
        self.text.push_str(&format!(
            "PROBLEM  {}\n         fix: {}\n",
            what.as_ref(),
            fix.as_ref()
        ));
    }
}

/// What a daemon that answered said.
struct Answered {
    version: u32,
    build: Option<String>,
    /// None from a host that predates `Status`.
    status: Option<HostStatus>,
    sessions: Vec<SessionInfo>,
}

/// `cherry doctor` for the host at `socket`.
pub fn doctor(socket: &Path) -> Result<u32> {
    let mut report = Report::default();
    check_installation(&mut report);
    let daemon = check_socket(&mut report, socket);
    let state = daemon
        .as_ref()
        .and_then(|daemon| daemon.status.as_ref())
        .map(|status| PathBuf::from(&status.state_dir))
        .or_else(|| cherry_protocol::state_dir(socket).ok());
    if let Some(daemon) = &daemon {
        check_daemon(&mut report, daemon);
    }
    if let Some(state) = &state {
        check_state(&mut report, state, daemon.as_ref());
    }
    let mut limit: libc::rlimit = unsafe { std::mem::zeroed() };
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) } == 0 {
        report.ok(format!(
            "this process's descriptor limit is {} (hard {}); a host started from here raises its own",
            limit.rlim_cur, limit.rlim_max
        ));
    }
    if report.problems == 0 {
        report.text.push_str("No problems found.\n");
    } else {
        report.text.push_str(&format!(
            "{} problem{} found.\n",
            report.problems,
            if report.problems == 1 { "" } else { "s" }
        ));
    }
    crate::print(&report.text)?;
    Ok(u32::from(report.problems > 0))
}

/// This cherry and the cherry-host it would start.
fn check_installation(report: &mut Report) {
    let own = own_build();
    let this = std::env::current_exe().ok();
    report.ok(format!(
        "this cherry is build {own}, protocol {PROTOCOL_VERSION} ({})",
        this.as_deref()
            .map_or_else(|| "?".into(), |path| path.display().to_string())
    ));
    if let Some(reason) = this
        .as_deref()
        .and_then(crate::transport::unstable_location)
    {
        report.problem(
            format!("this cherry runs from a location that goes away: {reason}"),
            "move Cherry to /Applications (or another writable folder) and open it from there",
        );
    }
    match crate::transport::runnable_host_executable() {
        Ok(executable) => match executable_build(&executable) {
            Some(build) if build == own_build() => report.ok(format!(
                "the cherry-host it starts ({}) is the same build",
                executable.display()
            )),
            Some(build) => report.problem(
                format!(
                    "the cherry-host it starts ({}) is build {build}, not this cherry's {own}",
                    executable.display()
                ),
                "install cherry and cherry-host from the same build (they ship together in Cherry.app), or set CHERRY_HOST_PATH to the matching cherry-host",
            ),
            None => report.problem(
                format!(
                    "the cherry-host it starts ({}) does not say its build",
                    executable.display()
                ),
                "install the cherry-host that comes with this cherry (an older one predates builds)",
            ),
        },
        Err(error) => report.problem(
            format!("no cherry-host can be started: {error:#}"),
            "install cherry-host beside cherry, on PATH, or set CHERRY_HOST_PATH",
        ),
    }
}

/// The socket's directory and the socket itself; the daemon's answers when
/// one serves it.
fn check_socket(report: &mut Report, socket: &Path) -> Option<Answered> {
    let Some(dir) = socket.parent() else {
        report.problem(
            format!("{} has no directory", socket.display()),
            "set CHERRY_HOST_SOCKET to an absolute path",
        );
        return None;
    };
    match fs::symlink_metadata(dir) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            report.ok(format!(
                "no socket directory {} yet: no host has run here",
                dir.display()
            ));
            return None;
        }
        _ => match cherry_protocol::verify_private_dir(dir) {
            Ok(()) => report.ok(format!(
                "socket directory {} is private (yours, mode 0700)",
                dir.display()
            )),
            Err(error) => {
                report.problem(
                    format!("socket directory {} is not usable: {error}", dir.display()),
                    "remove it, or make it yours with mode 0700 (chmod 700), or set CHERRY_HOST_SOCKET to a socket in a private directory",
                );
                return None;
            }
        },
    }
    let meta = match fs::symlink_metadata(socket) {
        Ok(meta) => meta,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            report.ok(format!(
                "no host is running (nothing at {})",
                socket.display()
            ));
            return None;
        }
        Err(error) => {
            report.problem(
                format!("cannot inspect {}: {error}", socket.display()),
                "check the socket directory's permissions",
            );
            return None;
        }
    };
    if !meta.file_type().is_socket() || meta.uid() != unsafe { libc::geteuid() } {
        report.problem(
            format!(
                "{} is not a socket of yours (uid {}, {})",
                socket.display(),
                meta.uid(),
                if meta.file_type().is_socket() {
                    "a socket"
                } else {
                    "not a socket"
                }
            ),
            format!(
                "remove it (rm {}), or set CHERRY_HOST_SOCKET to another path",
                socket.display()
            ),
        );
        return None;
    }
    if meta.mode() & 0o077 != 0 {
        report.problem(
            format!(
                "socket {} is open to other users (mode {:o})",
                socket.display(),
                meta.mode() & 0o777
            ),
            "`cherry restart` binds it again with mode 0600",
        );
    }
    let mut stream = match UnixStream::connect(socket) {
        Ok(stream) => stream,
        Err(error) if error.kind() == io::ErrorKind::ConnectionRefused => {
            report.problem(
                format!(
                    "stale socket {}: nothing listens on it (its host ended without removing it)",
                    socket.display()
                ),
                "`cherry start` (or opening Cherry) replaces it with a new host; or remove it",
            );
            return None;
        }
        Err(error) => {
            report.problem(
                format!("cannot connect to {}: {error}", socket.display()),
                "check the socket directory's permissions",
            );
            return None;
        }
    };
    if let Err(error) = cherry_protocol::verify_peer(&stream) {
        report.problem(
            format!("{} is served by another account: {error}", socket.display()),
            "set CHERRY_HOST_SOCKET to a socket in a private directory",
        );
        return None;
    }
    match ask(&mut stream) {
        Ok(answered) => Some(answered),
        Err(error) => {
            report.problem(
                format!(
                    "a host is listening at {} but did not answer: {error}",
                    socket.display()
                ),
                "it may be busy or at its connection limit; if it stays so, `cherry restart` (sessions carry on)",
            );
            None
        }
    }
}

/// Hello, then (when the versions match) `Status` and `List`.
fn ask(stream: &mut UnixStream) -> io::Result<Answered> {
    stream.set_read_timeout(Some(DOCTOR_WAIT))?;
    stream.set_write_timeout(Some(DOCTOR_WAIT))?;
    let receive = |stream: &mut UnixStream| -> io::Result<ServerMessage> {
        read_frame::<_, ServerMessage>(stream)?
            .ok_or_else(|| io::Error::other("it closed the connection"))
    };
    write_frame(stream, &ClientMessage::hello())?;
    let (version, build) = match receive(stream)? {
        ServerMessage::Welcome { version, build, .. } => (version, build),
        ServerMessage::Error { message, .. } => {
            // Older than protocol 4: "expected Cherry host protocol version N".
            let version = message
                .rsplit(' ')
                .next()
                .and_then(|version| version.parse().ok())
                .unwrap_or(0);
            return Ok(Answered {
                version,
                build: None,
                status: None,
                sessions: Vec::new(),
            });
        }
        other => return Err(io::Error::other(format!("unexpected reply {other:?}"))),
    };
    if version != PROTOCOL_VERSION {
        return Ok(Answered {
            version,
            build,
            status: None,
            sessions: Vec::new(),
        });
    }
    write_frame(stream, &ClientMessage::Status)?;
    let status = match receive(stream)? {
        ServerMessage::Status { status } => Some(status),
        _ => None,
    };
    write_frame(stream, &ClientMessage::List)?;
    let sessions = match receive(stream)? {
        ServerMessage::Sessions { sessions, .. } => sessions,
        _ => Vec::new(),
    };
    Ok(Answered {
        version,
        build,
        status,
        sessions,
    })
}

fn check_daemon(report: &mut Report, daemon: &Answered) {
    let own = own_build();
    if daemon.version != PROTOCOL_VERSION {
        if daemon.version < PROTOCOL_VERSION {
            report.problem(
                format!(
                    "the host speaks protocol {}, older than this cherry's {PROTOCOL_VERSION}",
                    daemon.version
                ),
                "`cherry list` (or opening Cherry) replaces it with this version; its sessions carry on",
            );
        } else {
            report.problem(
                format!(
                    "the host speaks protocol {}, newer than this cherry's {PROTOCOL_VERSION}",
                    daemon.version
                ),
                format!(
                    "use the cherry that comes with the Cherry that speaks protocol {}",
                    daemon.version
                ),
            );
        }
        return;
    }
    let build = daemon
        .build
        .as_deref()
        .or(daemon.status.as_ref().map(|status| status.build.as_str()));
    match build {
        Some(build) if build == own_build() => {
            report.ok(format!("the host runs this cherry's build and protocol ({build})"))
        }
        Some(build) if cherry_protocol::build_is_newer(own_build(), build) => report.problem(
            format!("the host runs build {build}, older than this cherry's {own}"),
            "`cherry restart` runs this build (sessions carry on); Cherry and `cherry list` do it themselves when they connect",
        ),
        Some(build) if cherry_protocol::build_is_newer(build, own_build()) => report.problem(
            format!("the host runs build {build}, newer than this cherry's {own}"),
            "this cherry is an old copy: use the cherry of the Cherry that started the host",
        ),
        Some(build) => report.problem(
            format!("the host runs build {build}, not this cherry's {own}"),
            "`cherry restart` runs this cherry's cherry-host (sessions carry on)",
        ),
        None => report.problem(
            "the host does not say its build: it is older than this cherry",
            "`cherry restart` runs this cherry's cherry-host (sessions carry on)",
        ),
    }
    let Some(status) = &daemon.status else {
        report.ok("the host predates `status`; only its sessions were checked");
        return;
    };
    report.ok(format!(
        "the host (pid {}) serves {} of {} sessions ({} running) and {} of {} connections",
        status.pid,
        status.sessions,
        status.max_sessions,
        status.running_sessions,
        status.connections,
        status.max_connections
    ));
    match &status.executable {
        Some(executable) if !Path::new(executable).exists() => report.problem(
            format!("the host's executable {executable} is gone"),
            "`cherry restart` (sessions carry on); new sessions cannot start until then",
        ),
        Some(executable) if status.executable_changed => report.problem(
            format!("the host's executable {executable} was replaced since it started"),
            "`cherry restart` runs the new one (sessions carry on)",
        ),
        _ => {}
    }
    if let Some(reason) = status
        .executable
        .as_deref()
        .and_then(|executable| crate::transport::unstable_location(Path::new(executable)))
    {
        report.problem(
            format!("the host runs from a location that goes away: {reason}"),
            "move Cherry to /Applications, open it from there, then `cherry restart`",
        );
    }
    if let Some(limit) = status.fd_limit {
        let needed = u64::from(status.max_connections) + FD_HEADROOM;
        if limit < needed {
            report.problem(
                format!(
                    "the host's descriptor limit is {limit}, below the {needed} its {} connections need",
                    status.max_connections
                ),
                "raise the hard limit (`launchctl limit maxfiles`, or `ulimit -Hn` where the host starts), then `cherry restart`",
            );
        } else {
            report.ok(format!("the host's descriptor limit is {limit}"));
        }
    }
    if status.sessions >= status.max_sessions {
        report.problem(
            format!(
                "the host is at its limit of {} sessions (exited ones included)",
                status.max_sessions
            ),
            "remove ended sessions (`cherry list`, then `cherry remove ID`)",
        );
    }
    if u64::from(status.connections) * 10 >= u64::from(status.max_connections) * 9 {
        report.problem(
            format!(
                "the host serves {} of its {} connections",
                status.connections, status.max_connections
            ),
            "close clients that are left over (attached terminals, scripts), or `cherry restart`",
        );
    }
    let mut builds: BTreeMap<&str, usize> = BTreeMap::new();
    for session in &daemon.sessions {
        *builds
            .entry(session.holder_build.as_deref().unwrap_or("unknown"))
            .or_default() += 1;
    }
    if !builds.is_empty() {
        let listed: Vec<String> = builds
            .iter()
            .map(|(build, count)| format!("{count} of build {build}"))
            .collect();
        report.ok(format!(
            "holders: {} ({} registered, {} expected); each keeps the build it started with until its session ends",
            listed.join(", "),
            status.holders_registered,
            status.holders_expected
        ));
    }
}

/// A holder's manifest, as much as `doctor` reads of it.
#[derive(serde::Deserialize)]
struct Manifest {
    id: String,
    holder_pid: u32,
    #[serde(default)]
    holder_started: Option<String>,
}

/// Whether the process a PID file or manifest names still runs, and was not
/// given to another process since (when that can be told).
fn runs(pid: u32, started: Option<&str>) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else {
        return false;
    };
    if pid <= 0 || unsafe { libc::kill(pid, 0) } != 0 {
        return false;
    }
    match (started, crate::status::start_identity(pid)) {
        (Some(recorded), Some(current)) => recorded == current,
        _ => true,
    }
}

fn check_state(report: &mut Report, state: &Path, daemon: Option<&Answered>) {
    match fs::symlink_metadata(state) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            report.ok(format!("no state directory {} yet", state.display()));
            return;
        }
        _ => match cherry_protocol::verify_private_dir(state) {
            Ok(()) => report.ok(format!("state directory {} is private", state.display())),
            Err(error) => report.problem(
                format!("state directory {} is not usable: {error}", state.display()),
                "make it yours with mode 0700 (chmod 700), or remove it (the host's identity changes)",
            ),
        },
    }
    let status = daemon.and_then(|daemon| daemon.status.as_ref());
    // The PID file.
    let pid_file = state.join("host.pid");
    #[derive(serde::Deserialize)]
    struct PidFile {
        pid: u32,
        /// The daemon's start identity: a process that got its pid later
        /// is not it.
        #[serde(default)]
        started: Option<String>,
    }
    match fs::read(&pid_file) {
        Ok(bytes) => match serde_json::from_slice::<PidFile>(&bytes) {
            Ok(PidFile { pid, started }) => match status {
                Some(status) if status.pid == pid => {
                    report.ok(format!("PID file {} names the host", pid_file.display()))
                }
                Some(status) => report.problem(
                    format!(
                        "PID file {} names pid {pid}, but the host serving the socket is pid {}",
                        pid_file.display(),
                        status.pid
                    ),
                    format!(
                        "remove it (rm '{}'); `cherry restart` writes it again",
                        pid_file.display()
                    ),
                ),
                None if daemon.is_none() && runs(pid, started.as_deref()) => report.problem(
                    format!(
                        "PID file {} names pid {pid}, which runs, but no host answers at the socket",
                        pid_file.display()
                    ),
                    format!("if pid {pid} is a cherry-host, it lost its socket: end it (kill {pid}; sessions carry on in their holders) and run `cherry start`"),
                ),
                None if daemon.is_none() => report.problem(
                    format!(
                        "stale PID file {}: pid {pid} is gone, or is another process now (its host crashed or was killed)",
                        pid_file.display()
                    ),
                    format!(
                        "remove it (rm '{}'); the next host writes it again",
                        pid_file.display()
                    ),
                ),
                None => {}
            },
            Err(error) => report.problem(
                format!("PID file {} is unreadable: {error}", pid_file.display()),
                format!("remove it (rm '{}')", pid_file.display()),
            ),
        },
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => report.problem(
            format!("cannot read PID file {}: {error}", pid_file.display()),
            "check the state directory's permissions",
        ),
    }
    // The log.
    let log = status
        .and_then(|status| status.log_path.as_deref())
        .map(PathBuf::from)
        .unwrap_or_else(|| state.join("host.log"));
    if let Ok(meta) = fs::metadata(&log) {
        let size = meta.len();
        if size > LARGE_LOG_BYTES {
            report.problem(
                format!("{} is {} MiB", log.display(), size / (1024 * 1024)),
                "look at its end for what repeats; it is moved aside to host.log.1 when the host next starts (`cherry restart`)",
            );
        } else {
            report.ok(format!("{} is {} KiB", log.display(), size.div_ceil(1024)));
        }
    }
    // Holders, when no daemon serves them.
    if daemon.is_some() {
        return;
    }
    let mut held = Vec::new();
    let mut gone = Vec::new();
    if let Ok(entries) = fs::read_dir(state.join("sessions")) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().is_none_or(|extension| extension != "json") {
                continue;
            }
            let Some(manifest) = fs::read(&path)
                .ok()
                .and_then(|bytes| serde_json::from_slice::<Manifest>(&bytes).ok())
            else {
                continue;
            };
            if runs(manifest.holder_pid, manifest.holder_started.as_deref()) {
                held.push(format!("{} (pid {})", manifest.id, manifest.holder_pid));
            } else {
                gone.push(manifest.id);
            }
        }
    }
    held.sort();
    if !held.is_empty() {
        report.problem(
            format!(
                "{} session{} held by holders with no host running: {}",
                held.len(),
                if held.len() == 1 { " is" } else { "s are" },
                held.join(", ")
            ),
            "`cherry start` (or opening Cherry) starts a host, and they register with it",
        );
    }
    if !gone.is_empty() {
        report.ok(format!(
            "{} session manifest{} name{} holders that are gone; the next host reports those sessions as lost and removes them",
            gone.len(),
            if gone.len() == 1 { "" } else { "s" },
            if gone.len() == 1 { "s" } else { "" },
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durations_read_at_a_glance() {
        assert_eq!(duration(12_345), "12s");
        assert_eq!(duration(250_000), "4m 10s");
        assert_eq!(duration(7_500_000), "2h 5m");
        assert_eq!(duration(3 * 86_400_000 + 4 * 3_600_000), "3d 4h");
    }

    #[test]
    fn status_names_each_sessions_holder_build() {
        let session: SessionInfo = serde_json::from_str(
            r#"{"id":"s1","name":"shell","cwd":"/","command":[],"cols":80,"rows":24,"state":"running","pid":1,"exit_code":null,"attached":false,"exit_signal":null,"holder_build":"20260101000000.aaaaaaa"}"#,
        )
        .unwrap();
        let text = status_text(
            &Greeting {
                host_id: "h",
                build: Some("20260927101500.bbbbbbb"),
                remote: None,
            },
            None,
            &[session],
            0,
        );
        assert!(
            text.contains("cherry-host 20260927101500.bbbbbbb"),
            "{text}"
        );
        assert!(
            text.lines()
                .any(|line| line.starts_with("s1") && line.contains("20260101000000.aaaaaaa")),
            "{text}"
        );
    }
}
