//! Starting the daemon on demand, and the SSH gateway that relays a remote
//! client's frames to it.
use crate::{environment, paths};
use anyhow::{bail, Context, Result};
use cherry_protocol::{read_frame, write_frame, ClientMessage, ServerMessage, PROTOCOL_VERSION};
use std::{
    fs::{self, OpenOptions},
    io::{self, Read, Seek, Write},
    os::unix::{fs::OpenOptionsExt, net::UnixStream, process::CommandExt},
    path::Path,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

/// What answers at the socket path.
#[derive(Debug, PartialEq, Eq)]
pub enum Probe {
    /// Nothing is listening.
    Absent,
    /// A host speaking this protocol version.
    Ready,
    /// A host speaking another protocol version, when it said which.
    OtherVersion(Option<u32>),
    /// Something is listening but did not complete the handshake.
    Unresponsive(String),
}

/// Ask whoever listens at `path` for its protocol version. The socket and its
/// directory are verified before anything is sent or trusted.
pub fn probe(path: &Path) -> Result<Probe> {
    cherry_protocol::verify_socket_path(path).map_err(|error| untrusted(path, error))?;
    let mut stream = match UnixStream::connect(path) {
        Ok(stream) => stream,
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
            ) =>
        {
            return Ok(Probe::Absent)
        }
        Err(error) => {
            return Err(error).with_context(|| format!("connecting to {}", path.display()))
        }
    };
    cherry_protocol::verify_peer(&stream).map_err(|error| peer_refused(path, error))?;
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    if let Err(error) = write_frame(&mut stream, &ClientMessage::hello()) {
        return Ok(Probe::Unresponsive(error.to_string()));
    }
    Ok(match read_frame::<_, ServerMessage>(&mut stream) {
        Ok(Some(ServerMessage::Welcome { version, .. })) if version == PROTOCOL_VERSION => {
            Probe::Ready
        }
        Ok(Some(ServerMessage::Welcome { version, .. })) => Probe::OtherVersion(Some(version)),
        Ok(Some(ServerMessage::Error { code, message }))
            if code == cherry_protocol::error_code::VERSION_MISMATCH =>
        {
            // "expected Cherry host protocol version N"
            Probe::OtherVersion(
                message
                    .rsplit(' ')
                    .next()
                    .and_then(|version| version.parse().ok()),
            )
        }
        Ok(Some(other)) => Probe::Unresponsive(format!("unexpected reply {other:?}")),
        Ok(None) => Probe::Unresponsive("it closed the connection".into()),
        Err(error) => Probe::Unresponsive(error.to_string()),
    })
}

/// Explain why the socket path failed verification: its directory, or
/// whatever occupies the socket path itself.
fn untrusted(path: &Path, error: io::Error) -> anyhow::Error {
    match path.parent() {
        Some(dir) if error.kind() == io::ErrorKind::PermissionDenied => {
            match cherry_protocol::verify_private_dir(dir) {
                Err(error) => paths::untrusted_socket_dir(dir, error),
                Ok(()) => paths::occupied_socket_path(path, "cannot use"),
            }
        }
        _ => anyhow::Error::new(error).context(format!("refusing to use {}", path.display())),
    }
}

fn peer_refused(path: &Path, error: io::Error) -> anyhow::Error {
    anyhow::anyhow!(
        "refusing to use {}: {error}; another account is listening on this socket",
        path.display()
    )
}

fn other_version(path: &Path, version: Option<u32>) -> anyhow::Error {
    let speaking = version.map_or_else(
        || "another protocol version".to_string(),
        |version| format!("protocol {version}"),
    );
    anyhow::anyhow!(
        "a cherry-host speaking {speaking} is running at {} (this is protocol {PROTOCOL_VERSION}); finish its sessions and stop it (`cherry shutdown` from the matching version), then try again",
        path.display()
    )
}

fn unresponsive(path: &Path, why: &str) -> anyhow::Error {
    anyhow::anyhow!(
        "a cherry-host is running at {} but did not answer ({why}); it may be busy or at its connection limit",
        path.display()
    )
}

fn not_running(path: &Path) -> anyhow::Error {
    anyhow::anyhow!("no cherry-host is running at {}", path.display())
}

/// Check that a host speaking this protocol serves `path`, without starting
/// one or creating anything.
pub fn running(path: &Path) -> Result<()> {
    let dir = paths::socket_parent(path)?;
    // Without its directory the socket never existed; nothing to verify.
    if matches!(fs::symlink_metadata(dir), Err(error) if error.kind() == io::ErrorKind::NotFound) {
        return Err(not_running(path));
    }
    match probe(path)? {
        Probe::Ready => Ok(()),
        Probe::Absent => Err(not_running(path)),
        Probe::OtherVersion(version) => Err(other_version(path, version)),
        Probe::Unresponsive(why) => Err(unresponsive(path, &why)),
    }
}

/// Make sure a host speaking this protocol serves `path`, starting one if
/// nothing is listening. Never starts a second daemon next to a live one.
pub fn start(path: &Path) -> Result<()> {
    paths::socket_dir(path)?;
    match probe(path)? {
        Probe::Ready => return Ok(()),
        Probe::OtherVersion(version) => return Err(other_version(path, version)),
        Probe::Unresponsive(why) => return Err(unresponsive(path, &why)),
        Probe::Absent => {}
    }
    #[cfg(target_os = "linux")]
    if systemd::manages(path) {
        return systemd::start(path);
    }
    let state = paths::open_state_dir(path)?;
    let log_path = state.join("host.log");
    let mut log = OpenOptions::new()
        .create(true)
        .append(true)
        .read(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&log_path)
        .with_context(|| format!("opening {}", log_path.display()))?;
    let log_start = log.seek(io::SeekFrom::End(0))?;
    let mut command = Command::new(std::env::current_exe()?);
    command
        .arg("serve")
        .arg("--socket")
        .arg(path)
        // The daemon outlives this client and serves every later one: it
        // keeps only neutral variables and does not pin this directory.
        .env_clear()
        .envs(environment::inherited_vars())
        .current_dir("/")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(log.try_clone()?);
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(io::Error::last_os_error());
            }
            environment::cloexec_from_3();
            Ok(())
        });
    }
    let mut child = command.spawn().context("starting detached host")?;
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut exited = None;
    loop {
        match probe(path)? {
            Probe::Ready => return Ok(()),
            Probe::OtherVersion(version) => return Err(other_version(path, version)),
            Probe::Absent | Probe::Unresponsive(_) => {}
        }
        if exited.is_none() {
            exited = child.try_wait()?.map(|status| (status, Instant::now()));
        }
        // A daemon started concurrently by another client may hold the lock
        // and still be binding its socket; give it a moment to answer.
        if let Some((status, _)) = exited.filter(|(_, at): &(_, Instant)| {
            at.elapsed() >= Duration::from_secs(2) || Instant::now() >= deadline
        }) {
            let mut output = String::new();
            let _ = log.seek(io::SeekFrom::Start(log_start));
            let _ = (&mut log).take(64 * 1024).read_to_string(&mut output);
            let reason = output
                .lines()
                .rev()
                .find(|line| !line.trim().is_empty())
                .unwrap_or("no output");
            bail!(
                "host exited ({status}): {reason} (log: {})",
                log_path.display()
            );
        }
        if Instant::now() >= deadline {
            bail!("host did not become ready; inspect {}", log_path.display());
        }
        thread::sleep(Duration::from_millis(30));
    }
}

/// The first line on the gateway's stdout. Anything a remote shell prints
/// before it is not part of the protocol stream.
pub fn gateway_preamble() -> String {
    format!("CHERRY-GATEWAY {PROTOCOL_VERSION}\n")
}

/// Relay this process's stdin and stdout to the host at `path`. With
/// `start_host` false, a missing host is an error: nothing is started, and
/// the preamble is written only once a verified host answered.
pub fn gateway(path: &Path, start_host: bool) -> Result<()> {
    if start_host {
        start(path)?;
    } else {
        running(path)?;
    }
    cherry_protocol::verify_socket_path(path).map_err(|error| untrusted(path, error))?;
    let socket = match UnixStream::connect(path) {
        Ok(socket) => socket,
        // It stopped since it answered the probe.
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
            ) =>
        {
            return Err(not_running(path))
        }
        Err(error) => {
            return Err(error).with_context(|| format!("connecting to {}", path.display()))
        }
    };
    cherry_protocol::verify_peer(&socket).map_err(|error| peer_refused(path, error))?;
    // Sessions use a stable agent path; point it at the agent forwarded to
    // this connection. The CLI forwards one only for an attachment. The
    // daemon takes it back a moment after this process's connection ends,
    // however it ends, and within a second once the agent's socket is gone
    // (sshd removes it with the SSH connection).
    if let Some(dir) = path.parent() {
        let _ =
            cherry_protocol::update_agent_link(dir, std::env::var_os("SSH_AUTH_SOCK").as_deref());
    }
    let mut input_socket = socket.try_clone()?;
    let mut output = io::stdout().lock();
    output.write_all(gateway_preamble().as_bytes())?;
    output.flush()?;
    // Exiting this process closes the gateway connection, never the daemon.
    thread::Builder::new()
        .name("cherry-gateway-input".into())
        .spawn(move || {
            let _ = io::copy(&mut io::stdin().lock(), &mut input_socket);
            let _ = input_socket.shutdown(std::net::Shutdown::Write);
        })?;
    // stdout is line-buffered even when redirected. Protocol frames contain no
    // literal newline, so io::copy alone can withhold an entire handshake.
    let mut socket = socket;
    let mut bytes = [0u8; 16384];
    loop {
        let n = match socket.read(&mut bytes) {
            Ok(0) => break,
            Ok(n) => n,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error.into()),
        };
        output.write_all(&bytes[..n])?;
        output.flush()?;
    }
    Ok(())
}

/// On Linux the default host may be a systemd user service. When the user
/// enabled it, clients start the service rather than a daemon of their own,
/// which would live in (and die with) the caller's login session.
#[cfg(target_os = "linux")]
mod systemd {
    use super::*;
    use std::path::PathBuf;

    const UNIT: &str = "cherry-host.service";

    fn systemctl(args: &[&str]) -> Command {
        let mut command = Command::new("systemctl");
        command.arg("--user").args(args).stdin(Stdio::null());
        command
    }

    /// Whether the enabled service serves `path`.
    pub fn manages(path: &Path) -> bool {
        systemctl(&["is-enabled", "--quiet", UNIT])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|status| status.success())
            && service_socket().as_deref() == Some(path)
    }

    /// The unit runs `serve` without --socket in the user manager's
    /// environment, not this client's: it serves the manager's
    /// CHERRY_HOST_SOCKET, or the built-in path. A CHERRY_HOST_SOCKET set
    /// only in a login shell does not move the service.
    fn service_socket() -> Option<PathBuf> {
        let environment = systemctl(&["show-environment"])
            .stderr(Stdio::null())
            .output()
            .ok()
            .filter(|output| output.status.success())
            .map(|output| String::from_utf8_lossy(&output.stdout).into_owned())
            .unwrap_or_default();
        match environment
            .lines()
            .find_map(|line| line.strip_prefix("CHERRY_HOST_SOCKET="))
        {
            // A quoted (unusual) value never matches, and the client then
            // starts its own daemon as without systemd.
            Some(value) => Some(PathBuf::from(value)).filter(|path| path.is_absolute()),
            None => Some(paths::builtin_socket_path()),
        }
    }

    pub fn start(path: &Path) -> Result<()> {
        let status = systemctl(&["start", UNIT])
            .stdout(Stdio::null())
            .status()
            .context("running systemctl --user start")?;
        if !status.success() {
            bail!(
                "systemctl --user start {UNIT} failed ({status}); see journalctl --user -u {UNIT}"
            );
        }
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            match probe(path)? {
                Probe::Ready => return Ok(()),
                Probe::OtherVersion(version) => return Err(other_version(path, version)),
                Probe::Absent | Probe::Unresponsive(_) => {}
            }
            if Instant::now() >= deadline {
                bail!("{UNIT} started but the host did not become ready; see journalctl --user -u {UNIT}");
            }
            thread::sleep(Duration::from_millis(30));
        }
    }
}
