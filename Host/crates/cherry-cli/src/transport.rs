//! Connections to a host daemon: a verified local socket, or the remote
//! `cherry-host gateway` through the system ssh.
use crate::{
    stderr_relay::StderrRelay,
    sys::{interrupted, poll, pollfd, read_some, set_nonblocking},
    timing::timing,
};
use anyhow::{anyhow, bail, Context, Result};
use cherry_protocol::{
    default_socket_path, ClientMessage, ServerMessage, HEARTBEAT_INTERVAL, MAX_FRAME_BYTES,
    MAX_INPUT_BYTES, PROTOCOL_VERSION,
};
use std::{
    io,
    os::{
        fd::{AsRawFd, OwnedFd, RawFd},
        unix::net::UnixStream,
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

pub const RPC_TIMEOUT: Duration = Duration::from_secs(15);
/// The gateway writes this line before relaying frames. Output that a remote
/// shell prints before it (from non-interactive startup files) is skipped.
const GATEWAY_PREAMBLE: &[u8] = b"CHERRY-GATEWAY ";
const MAX_GATEWAY_JUNK: usize = 64 * 1024;
/// When the SSH output ends before the preamble, how long to wait for the
/// remote cherry-host's own explanation on ssh's standard error.
const GATEWAY_REPORT_WAIT: Duration = Duration::from_secs(2);
/// A Ping follows every this many bytes of input. The host answers when it
/// has read that far, which shows a detach waiting behind a long paste that
/// the input is still moving, even once ssh has taken all of it.
const INPUT_MARK_BYTES: usize = 64 * 1024;
/// Once the host stopped reading this connection, how long what it sent
/// before (a takeover notice, an exit, a detach confirmation) and its end of
/// file may take to arrive.
pub const CLOSED_WAIT: Duration = Duration::from_secs(5);

pub struct Transport {
    reader: OwnedFd,
    /// Closed first on drop, so ssh sees end of input and exits by itself.
    writer: Option<OwnedFd>,
    ssh: Option<Child>,
    decoder: FrameDecoder,
    outgoing: Vec<u8>,
    written: usize,
    /// When the outgoing buffer last made progress (or became non-empty).
    progress: Instant,
    /// When the host stopped reading this connection, if it did. Nothing is
    /// sent after that.
    write_closed: Option<Instant>,
    /// When bytes last arrived from the host.
    received: Instant,
    /// While attached: when the next Ping is due.
    next_ping: Option<Instant>,
    /// Input queued since the last Ping.
    unmarked_input: usize,
    /// Overall limit for non-interactive commands.
    deadline: Option<Instant>,
    /// The SSH destination, for messages.
    host: Option<String>,
    /// ssh's standard error, holding the remote cherry-host's error reports.
    stderr: Option<StderrRelay>,
    /// Whether the remote gateway may start a host.
    starts_host: bool,
}

impl Transport {
    /// `links_agent`: the command creates or attaches a session, so a local
    /// connection points the sessions' agent link at the caller's agent.
    /// Remotely only an attachment forwards its agent (see `ssh_command`).
    pub fn connect(
        host: Option<&str>,
        socket: Option<&Path>,
        interactive: bool,
        auto_start: bool,
        links_agent: bool,
    ) -> Result<Self> {
        let deadline = (!interactive).then(|| Instant::now() + Duration::from_secs(30));
        let mut stderr = None;
        let (reader, writer, ssh, decoder): (OwnedFd, OwnedFd, _, _) = match host {
            Some(host) => {
                let mut child = ssh_command(host, socket, interactive, auto_start)?
                    .stdin(Stdio::piped())
                    .stdout(Stdio::piped())
                    .stderr(Stdio::piped())
                    .spawn()
                    .context("could not run system ssh")?;
                let reader = child.stdout.take().context("SSH stdout was not piped")?;
                let writer = child.stdin.take().context("SSH stdin was not piped")?;
                let errors = child.stderr.take().context("SSH stderr was not piped")?;
                stderr = Some(StderrRelay::start(errors).context("could not relay ssh errors")?);
                (
                    reader.into(),
                    writer.into(),
                    Some(child),
                    FrameDecoder::after_preamble(),
                )
            }
            None => {
                let socket = local_socket_path(socket)?;
                let stream = connect_local(&socket, auto_start)?;
                // Like tmux, the link follows the clients that use sessions,
                // not every list. Agent forwarding is a convenience; it never
                // fails a command.
                if let Some(directory) = socket.parent().filter(|_| links_agent) {
                    let _ = cherry_protocol::update_agent_link(
                        directory,
                        std::env::var_os("SSH_AUTH_SOCK").as_deref(),
                    );
                }
                let writer = stream.try_clone()?;
                (stream.into(), writer.into(), None, FrameDecoder::default())
            }
        };
        let transport = Self {
            reader,
            writer: Some(writer),
            ssh,
            decoder,
            outgoing: Vec::new(),
            written: 0,
            progress: Instant::now(),
            write_closed: None,
            received: Instant::now(),
            next_ping: None,
            unmarked_input: 0,
            deadline,
            host: host.map(str::to_owned),
            stderr,
            starts_host: auto_start,
        };
        set_nonblocking(transport.read_fd())?;
        set_nonblocking(transport.write_fd())?;
        Ok(transport)
    }

    pub fn read_fd(&self) -> RawFd {
        self.reader.as_raw_fd()
    }

    pub fn write_fd(&self) -> RawFd {
        self.writer.as_ref().map_or(-1, AsRawFd::as_raw_fd)
    }

    pub fn is_ssh(&self) -> bool {
        self.ssh.is_some()
    }

    /// Append a frame to the outgoing buffer without writing it. Dropped
    /// once the host stopped reading.
    pub fn queue(&mut self, message: &ClientMessage) -> Result<()> {
        if self.write_closed.is_some() {
            return Ok(());
        }
        if self.pending() == 0 {
            self.outgoing.clear();
            self.written = 0;
            self.progress = Instant::now();
        }
        let frame = cherry_protocol::encode_frame(message).context("could not encode request")?;
        self.outgoing.extend_from_slice(&frame);
        Ok(())
    }

    pub fn queue_input(&mut self, bytes: &[u8]) -> Result<()> {
        for data in bytes.chunks(MAX_INPUT_BYTES) {
            self.queue(&ClientMessage::Input {
                data: data.to_vec(),
            })?;
            self.unmarked_input += data.len();
            if self.unmarked_input >= INPUT_MARK_BYTES {
                self.queue(&ClientMessage::Ping)?;
                self.unmarked_input = 0;
            }
        }
        Ok(())
    }

    /// Bytes queued but not yet accepted by the transport.
    pub fn pending(&self) -> usize {
        self.outgoing.len() - self.written
    }

    /// When the transport last accepted bytes (or the outgoing buffer
    /// became non-empty).
    pub fn progress(&self) -> Instant {
        self.progress
    }

    /// How long the transport has accepted nothing while bytes are queued,
    /// and delivered nothing either. A host whose program is not reading a
    /// large paste stops reading this connection, but its output still
    /// arrives.
    pub fn stalled_for(&self, now: Instant) -> Duration {
        if self.pending() == 0 {
            Duration::ZERO
        } else {
            now.saturating_duration_since(self.progress.max(self.received))
        }
    }

    /// Send Ping every heartbeat interval from now on, including while
    /// `receive` waits (for example for a large first snapshot).
    pub fn start_heartbeat(&mut self) {
        self.next_ping = Some(Instant::now() + timing().heartbeat_interval);
    }

    /// No more Pings: after Detach the host reads nothing else.
    pub fn stop_heartbeat(&mut self) {
        self.next_ping = None;
    }

    /// When the next Ping is due, if heartbeats are on.
    pub fn next_ping(&self) -> Option<Instant> {
        self.next_ping
    }

    /// Queue a Ping if one is due.
    pub fn heartbeat(&mut self, now: Instant) -> Result<()> {
        if self.next_ping.is_some_and(|at| now >= at) {
            self.queue(&ClientMessage::Ping)?;
            self.next_ping = Some(now + timing().heartbeat_interval);
        }
        Ok(())
    }

    /// Write as much of the outgoing buffer as the transport accepts now.
    ///
    /// A host that stopped reading only ends the writing: what is left is
    /// dropped, and what the host sent before it closed is still read. That
    /// decides the outcome: a takeover closes the old client's connection
    /// right after its notice, and a write can fail before the notice is
    /// read. The end of file, or `closed_deadline`, then ends the connection.
    pub fn write_ready(&mut self) -> Result<()> {
        match self.write_available() {
            Err(error) if stopped_reading(&error) => {
                self.outgoing.clear();
                self.written = 0;
                self.write_closed.get_or_insert_with(Instant::now);
                Ok(())
            }
            result => result.context("could not send to host"),
        }
    }

    /// Once the host stopped reading: when the connection counts as lost even
    /// though its end of file has not arrived.
    pub fn closed_deadline(&self) -> Option<Instant> {
        self.write_closed.map(|at| at + timing().closed_wait)
    }

    fn write_available(&mut self) -> io::Result<()> {
        while self.pending() > 0 {
            let bytes = &self.outgoing[self.written..];
            let n = unsafe { libc::write(self.write_fd(), bytes.as_ptr().cast(), bytes.len()) };
            if n > 0 {
                self.written += n as usize;
                self.progress = Instant::now();
                continue;
            }
            let error = io::Error::last_os_error();
            match error.kind() {
                io::ErrorKind::Interrupted => continue,
                io::ErrorKind::WouldBlock => break,
                _ => return Err(error),
            }
        }
        if self.pending() == 0 {
            self.outgoing.clear();
            self.written = 0;
        } else if self.written >= 64 * 1024 && self.written * 2 >= self.outgoing.len() {
            // A continuous paste may never fully drain; drop what was sent.
            self.outgoing.drain(..self.written);
            self.written = 0;
        }
        Ok(())
    }

    /// Queue a request and wait until the transport has accepted it.
    pub fn send(&mut self, message: &ClientMessage) -> Result<()> {
        self.queue(message)?;
        loop {
            interrupted()?;
            self.write_ready()?;
            if self.pending() == 0 {
                return Ok(());
            }
            let limit = self.limit(self.progress + RPC_TIMEOUT);
            let now = Instant::now();
            if now >= limit {
                bail!("timed out sending to host");
            }
            let mut fds = [pollfd(self.write_fd(), libc::POLLOUT)];
            poll(
                &mut fds,
                Duration::from_millis(100).min(limit.saturating_duration_since(now)),
            )?;
        }
    }

    /// Read what is available. False at end of file.
    pub fn read_ready(&mut self) -> Result<bool> {
        match self.decoder.read_from(self.read_fd())? {
            None => Ok(false),
            Some(0) => Ok(true),
            Some(_) => {
                self.received = Instant::now();
                Ok(true)
            }
        }
    }

    pub fn next_message(&mut self) -> Result<Option<ServerMessage>> {
        self.decoder.next()
    }

    /// Wait for the next message, failing when nothing arrives for `idle`.
    /// A Pong is never the answer: hosts may send one at any time.
    pub fn receive(&mut self, idle: Duration) -> Result<ServerMessage> {
        let mut progress = Instant::now();
        loop {
            interrupted()?;
            match self.next_message()? {
                Some(ServerMessage::Pong) => continue,
                Some(message) => return Ok(message),
                None => {}
            }
            let limit = self.limit(progress + idle);
            let now = Instant::now();
            if self.closed_deadline().is_some_and(|at| now >= at) {
                return Err(self.closed_error());
            }
            if now >= limit {
                return Err(self.timeout_error());
            }
            self.heartbeat(now)?;
            let wait = [self.next_ping, self.closed_deadline()]
                .into_iter()
                .flatten()
                .fold(limit, Instant::min)
                .saturating_duration_since(now);
            let mut fds = [
                pollfd(self.read_fd(), libc::POLLIN),
                pollfd(
                    if self.pending() > 0 {
                        self.write_fd()
                    } else {
                        -1
                    },
                    libc::POLLOUT,
                ),
            ];
            poll(&mut fds, Duration::from_millis(100).min(wait))?;
            if fds[1].revents != 0 {
                self.write_ready()?;
            }
            if fds[0].revents != 0 {
                if !self.read_ready()? {
                    return Err(self.closed_error());
                }
                progress = Instant::now();
            }
        }
    }

    /// Why the connection ended, for an unexpected end of file. A gateway
    /// that could not reach a host explains why on ssh's standard error and
    /// exits before its preamble.
    pub fn closed_error(&mut self) -> anyhow::Error {
        if self.decoder.awaiting_preamble() {
            // ssh may deliver the explanation just after the end of output.
            let mut reports = self
                .stderr
                .as_ref()
                .map(|relay| relay.take_reports(GATEWAY_REPORT_WAIT))
                .unwrap_or_default();
            if let Some(report) = reports.pop() {
                print_reports(&reports);
                let reason = report.strip_prefix("cherry-host: ").unwrap_or(&report);
                let host = self.host.as_deref().unwrap_or("the remote host");
                let never = if !self.starts_host && reason.starts_with("no cherry-host is running")
                {
                    " (this command never starts one)"
                } else {
                    ""
                };
                return anyhow!("cherry-host on {host}: {reason}{never}");
            }
        }
        self.decoder.closed_error(self.is_ssh())
    }

    fn timeout_error(&self) -> anyhow::Error {
        self.decoder.timeout_error()
    }

    fn limit(&self, candidate: Instant) -> Instant {
        self.deadline
            .map_or(candidate, |deadline| deadline.min(candidate))
    }
}

impl Drop for Transport {
    fn drop(&mut self) {
        self.writer.take();
        if let Some(child) = &mut self.ssh {
            stop_ssh(child, self.reader.as_raw_fd());
        }
        // Remote cherry-host errors that no message has reported.
        if let Some(relay) = &self.stderr {
            print_reports(&relay.take_reports(Duration::from_millis(200)));
        }
    }
}

/// Errors from writing to a peer that closed its connection or stopped
/// reading it: EPIPE, ECONNRESET, and ENOTCONN (macOS, once the peer is
/// gone).
fn stopped_reading(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::BrokenPipe | io::ErrorKind::NotConnected | io::ErrorKind::ConnectionReset
    )
}

fn print_reports(reports: &[String]) {
    for report in reports {
        let _ = crate::sys::write_all(
            libc::STDERR_FILENO,
            format!("{report}\n").as_bytes(),
            Duration::from_secs(1),
            false,
        );
    }
}

/// Never SIGKILL ssh first: it may be multiplexing other sessions, and an
/// orderly exit lets it deliver what it already accepted. Its stdin is
/// already closed; wait, then SIGTERM, then SIGKILL.
fn stop_ssh(child: &mut Child, reader: RawFd) {
    if wait_for_exit(child, reader, Duration::from_secs(1)) {
        return;
    }
    unsafe {
        libc::kill(child.id() as libc::pid_t, libc::SIGTERM);
    }
    if wait_for_exit(child, reader, Duration::from_secs(1)) {
        return;
    }
    let _ = child.kill();
    let _ = child.wait();
}

/// Wait for ssh to exit, discarding its output so a full pipe cannot keep it
/// from noticing the end of its input.
fn wait_for_exit(child: &mut Child, reader: RawFd, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    let mut draining = true;
    let mut scratch = [0u8; 16384];
    loop {
        if !matches!(child.try_wait(), Ok(None)) {
            return true;
        }
        let now = Instant::now();
        if now >= deadline {
            return false;
        }
        let wait = deadline
            .saturating_duration_since(now)
            .min(Duration::from_millis(10));
        if draining {
            let mut fds = [pollfd(reader, libc::POLLIN)];
            if poll(&mut fds, wait).is_err() {
                draining = false;
            } else if fds[0].revents != 0 {
                if let Ok(Some(0)) | Err(_) = read_some(reader, &mut scratch) {
                    draining = false;
                }
            }
        } else {
            std::thread::sleep(wait);
        }
    }
}

/// `starts_host` lets the remote gateway start a host when none is running.
pub fn ssh_command(
    host: &str,
    socket: Option<&Path>,
    interactive: bool,
    starts_host: bool,
) -> Result<Command> {
    crate::validate_host(host).map_err(anyhow::Error::msg)?;
    let alive = format!("ServerAliveInterval={}", HEARTBEAT_INTERVAL.as_secs());
    let mut ssh = Command::new("ssh");
    ssh.arg("-T");
    // Never become a ControlMaster (exiting would end the user's other
    // multiplexed sessions), and ignore alias settings meant for interactive
    // logins: a RemoteCommand conflicts with ours, forwards can fail to bind.
    for option in [
        "ControlMaster=no",
        "RemoteCommand=none",
        "ClearAllForwardings=yes",
        "PermitLocalCommand=no",
        &alive,
        "ServerAliveCountMax=3",
    ] {
        ssh.args(["-o", option]);
    }
    if !interactive {
        // The remote gateway points the sessions' agent link at the agent
        // forwarded to it. Only an attachment keeps its connection, and so
        // that agent, open; any other command's would vanish right after.
        ssh.args(["-a", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]);
    }
    ssh.args(["--", host])
        .arg(remote_gateway_command(socket, starts_host)?);
    Ok(ssh)
}

pub fn remote_gateway_command(socket: Option<&Path>, starts_host: bool) -> Result<String> {
    let mut command = String::from("cherry-host gateway");
    if !starts_host {
        command.push_str(" --no-start");
    }
    if let Some(path) = socket {
        let path = path
            .to_str()
            .context("remote socket path must be valid UTF-8")?;
        if path.contains('\0') {
            bail!("socket path contains a NUL byte");
        }
        command.push_str(&format!(" --socket '{}'", path.replace('\'', "'\\''")));
    }
    Ok(command)
}

pub fn local_socket_path(socket: Option<&Path>) -> Result<PathBuf> {
    let path = socket
        .map(Path::to_path_buf)
        .unwrap_or_else(default_socket_path);
    std::path::absolute(&path)
        .with_context(|| format!("invalid host socket path {}", path.display()))
}

/// Connect only to a socket in a private directory owned by this user and
/// served by a process of this user. Start the daemon only when nothing is
/// listening and `auto_start` allows it.
fn connect_local(socket: &Path, auto_start: bool) -> Result<UnixStream> {
    match cherry_protocol::connect_verified(socket) {
        Ok(stream) => Ok(stream),
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
            ) =>
        {
            if !auto_start {
                bail!(
                    "no cherry-host is running at {} (this command never starts one)",
                    socket.display()
                );
            }
            start_local_host(socket)?;
            cherry_protocol::connect_verified(socket)
                .map_err(|error| untrusted_socket(socket, error))
                .context("cherry-host started but its socket is not reachable")
        }
        Err(error) => Err(untrusted_socket(socket, error)),
    }
}

fn untrusted_socket(socket: &Path, error: io::Error) -> anyhow::Error {
    if error.kind() == io::ErrorKind::PermissionDenied {
        anyhow!(
            "refusing to use host socket {}: {error}. The socket must be in a private directory owned by you; set CHERRY_HOST_SOCKET (or --socket) to use another path",
            socket.display()
        )
    } else {
        anyhow::Error::new(error).context(format!(
            "could not connect to host socket {} (set CHERRY_HOST_SOCKET or --socket to use another path)",
            socket.display()
        ))
    }
}

pub fn start_local_host(socket: &Path) -> Result<()> {
    let executable = host_executable()?;
    // The daemon outlives this command; never keep the caller's directory busy.
    let mut child = Command::new(&executable)
        .args(["start", "--socket"])
        .arg(socket)
        .current_dir("/")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .with_context(|| {
            format!(
                "could not start {}; install cherry-host beside cherry, on PATH, or set CHERRY_HOST_PATH",
                executable.display()
            )
        })?;
    let deadline = Instant::now() + RPC_TIMEOUT;
    loop {
        match child.try_wait()? {
            Some(status) if status.success() => return Ok(()),
            Some(status) => bail!("cherry-host start failed ({status})"),
            None => {}
        }
        if interrupted().is_err() || Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            interrupted()?;
            bail!("timed out starting cherry-host");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn host_executable() -> Result<PathBuf> {
    if let Some(path) = std::env::var_os("CHERRY_HOST_PATH") {
        if path.is_empty() {
            bail!("CHERRY_HOST_PATH is empty");
        }
        return Ok(path.into());
    }
    if let Ok(executable) = std::env::current_exe() {
        if let Some(directory) = executable.parent() {
            let sibling = directory.join("cherry-host");
            if sibling.is_file() {
                if let Some(reason) = unstable_location(&sibling) {
                    bail!(
                        "refusing to start cherry-host from {}: {reason}, and persistent sessions would stop when it goes away. Move Cherry to /Applications (or another writable folder) and open it from there, or set CHERRY_HOST_PATH",
                        sibling.display()
                    );
                }
                return Ok(sibling);
            }
        }
    }
    Ok("cherry-host".into())
}

/// Why a helper at `path` must not become the long-lived daemon.
pub fn unstable_location(path: &Path) -> Option<&'static str> {
    if path.to_string_lossy().contains("/AppTranslocation/") {
        return Some(
            "macOS is running this copy of Cherry from a temporary App Translocation location",
        );
    }
    #[cfg(target_os = "macos")]
    if read_only_volume(path) {
        return Some("it is on a read-only volume, such as a mounted disk image");
    }
    None
}

#[cfg(target_os = "macos")]
fn read_only_volume(path: &Path) -> bool {
    use std::os::unix::ffi::OsStrExt;
    let Ok(path) = std::ffi::CString::new(path.as_os_str().as_bytes()) else {
        return false;
    };
    let mut info = unsafe { std::mem::zeroed::<libc::statvfs>() };
    unsafe { libc::statvfs(path.as_ptr(), &mut info) == 0 && info.f_flag & libc::ST_RDONLY != 0 }
}

fn junk_message(first_line: &str) -> String {
    format!(
        "the remote shell printed output before cherry-host gateway started; remove output from non-interactive shell startup files such as ~/.bashrc (first line: {first_line:?})"
    )
}

#[derive(Default)]
pub struct FrameDecoder {
    bytes: Vec<u8>,
    consumed: usize,
    /// SSH output starts with the gateway preamble.
    awaiting_preamble: bool,
    /// Bytes that preceded the preamble, kept for the error message.
    junk: Vec<u8>,
}

impl FrameDecoder {
    pub fn after_preamble() -> Self {
        Self {
            awaiting_preamble: true,
            ..Self::default()
        }
    }

    /// No SSH gateway preamble has arrived yet.
    pub fn awaiting_preamble(&self) -> bool {
        self.awaiting_preamble
    }

    pub fn next(&mut self) -> Result<Option<ServerMessage>> {
        if self.awaiting_preamble && !self.take_preamble()? {
            return Ok(None);
        }
        let pending = &self.bytes[self.consumed..];
        if pending.len() < 4 {
            return Ok(None);
        }
        let len = u32::from_be_bytes(pending[..4].try_into().unwrap()) as usize;
        if len == 0 || len > MAX_FRAME_BYTES {
            bail!("host sent invalid frame length {len}");
        }
        if pending.len() < 4 + len {
            return Ok(None);
        }
        let message =
            serde_json::from_slice(&pending[4..4 + len]).context("host sent invalid JSON frame")?;
        self.consumed += 4 + len;
        if self.consumed == self.bytes.len() {
            self.bytes.clear();
            self.consumed = 0;
        }
        Ok(Some(message))
    }

    /// Find `CHERRY-GATEWAY <version>\n`, skipping up to 64 KiB before it.
    fn take_preamble(&mut self) -> Result<bool> {
        let pending = &self.bytes[self.consumed..];
        let Some(start) = pending
            .windows(GATEWAY_PREAMBLE.len())
            .position(|window| window == GATEWAY_PREAMBLE)
        else {
            // Keep a possible partial marker at the end for the next read.
            let keep = GATEWAY_PREAMBLE.len() - 1;
            if pending.len() > keep {
                let skipped = pending.len() - keep;
                self.junk.extend_from_slice(&pending[..skipped]);
                self.consumed += skipped;
            }
            if self.junk.len() > MAX_GATEWAY_JUNK {
                bail!(junk_message(&self.junk_line().unwrap_or_default()));
            }
            return Ok(false);
        };
        let line = &pending[start + GATEWAY_PREAMBLE.len()..];
        let Some(end) = line.iter().position(|&byte| byte == b'\n') else {
            if line.len() > 32 {
                bail!("the remote cherry-host gateway sent an invalid preamble");
            }
            return Ok(false);
        };
        self.junk.extend_from_slice(&pending[..start]);
        if self.junk.len() > MAX_GATEWAY_JUNK {
            bail!(junk_message(&self.junk_line().unwrap_or_default()));
        }
        let version = std::str::from_utf8(&line[..end])
            .ok()
            .and_then(|text| text.trim_end_matches('\r').parse::<u32>().ok())
            .context("the remote cherry-host gateway sent an invalid preamble")?;
        if version != PROTOCOL_VERSION {
            bail!(
                "protocol version mismatch: the remote cherry-host gateway speaks version {version}, this cherry speaks version {PROTOCOL_VERSION}; install the same Cherry version on both machines"
            );
        }
        self.consumed += start + GATEWAY_PREAMBLE.len() + end + 1;
        self.awaiting_preamble = false;
        self.junk.clear();
        Ok(true)
    }

    /// Why the connection ended, for an unexpected end of file.
    pub fn closed_error(&self, ssh: bool) -> anyhow::Error {
        let ssh = if ssh {
            " (errors from ssh or cherry-host, if any, are shown above)"
        } else {
            ""
        };
        if !self.awaiting_preamble {
            return anyhow!("host connection closed unexpectedly{ssh}");
        }
        // Shell output before the preamble is skipped, so here it is only a
        // clue: the gateway failed or never ran.
        let printed = self
            .junk_line()
            .map(|junk| format!("; the remote shell printed {junk:?} first"))
            .unwrap_or_default();
        anyhow!("the SSH connection closed before cherry-host gateway started{ssh}{printed}")
    }

    /// Nothing arrived in time.
    pub fn timeout_error(&self) -> anyhow::Error {
        if !self.awaiting_preamble {
            return anyhow!("timed out waiting for host");
        }
        // A startup file that prints may also be what keeps the shell busy.
        match self.junk_line() {
            Some(junk) => anyhow!(
                "timed out waiting for cherry-host gateway to start; the remote shell printed {junk:?} first, so check non-interactive shell startup files such as ~/.bashrc"
            ),
            None => anyhow!("timed out waiting for cherry-host gateway to start"),
        }
    }

    /// The first non-empty line printed before the preamble, if any.
    fn junk_line(&self) -> Option<String> {
        let mut junk = self.junk.clone();
        if self.awaiting_preamble {
            junk.extend_from_slice(&self.bytes[self.consumed..]);
        }
        let line = junk
            .split(|&byte| byte == b'\n')
            .map(|line| String::from_utf8_lossy(line).trim().to_owned())
            .find(|line| !line.is_empty())?;
        Some(line.chars().take(160).collect())
    }

    /// Bytes read (0 when none are available), or None at end of file.
    fn read_from(&mut self, fd: RawFd) -> Result<Option<usize>> {
        if self.consumed > 0 {
            self.bytes.drain(..self.consumed);
            self.consumed = 0;
        }
        let mut buffer = [0u8; 65536];
        let read = match read_some(fd, &mut buffer) {
            // A peer that closed with bytes of ours unread resets the
            // connection (Linux) once what it sent before is read.
            Err(error) if error.kind() == io::ErrorKind::ConnectionReset => Ok(Some(0)),
            read => read,
        };
        match read.context("could not read host connection")? {
            None => Ok(Some(0)),
            Some(0) => Ok(None),
            Some(n) => {
                self.bytes.extend_from_slice(&buffer[..n]);
                if self.bytes.len() > MAX_FRAME_BYTES + 4 + buffer.len() {
                    bail!("host frame buffer exceeded limit");
                }
                Ok(Some(n))
            }
        }
    }

    #[cfg(test)]
    pub fn with_bytes(bytes: &[u8], awaiting_preamble: bool) -> Self {
        Self {
            bytes: bytes.to_vec(),
            awaiting_preamble,
            ..Self::default()
        }
    }

    #[cfg(test)]
    pub fn push(&mut self, bytes: &[u8]) {
        self.bytes.extend_from_slice(bytes);
    }
}
