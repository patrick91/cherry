//! Connections to a host daemon: a verified local socket, or the remote
//! `cherry-host gateway` through the system ssh.
use crate::{
    stderr_relay::StderrRelay,
    sys::{interrupted, poll, pollfd, read_some, set_nonblocking},
    timing::timing,
};
use anyhow::{anyhow, bail, Context, Result};
use cherry_protocol::{
    binary_kind, default_socket_path, output_frame_parts, ClientMessage, Message, ServerMessage,
    HEARTBEAT_INTERVAL, MAX_FRAME_BYTES, MAX_INPUT_BYTES, OUTPUT_HEADER, PROTOCOL_VERSION,
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
/// How long a command other than attach may take to connect, in all:
/// starting a host, ssh and the gateway, Hello, and replacing an older host
/// and connecting again. A command's request counts too.
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
/// The gateway writes this line before relaying frames. Output that a remote
/// shell prints before it (from non-interactive startup files) is skipped.
const GATEWAY_PREAMBLE: &[u8] = b"CHERRY-GATEWAY ";
const MAX_GATEWAY_JUNK: usize = 64 * 1024;
/// How the remote gateway's reports about a host of another protocol
/// version start (see cherry-host's `launch::other_version`).
const OTHER_VERSION_REPORT: &str = "a cherry-host speaking ";
/// When the SSH output ends before the preamble, how long to wait for the
/// remote cherry-host's own explanation on ssh's standard error.
const GATEWAY_REPORT_WAIT: Duration = Duration::from_secs(2);
/// When an SSH connection whose standard error is held ends, how long to
/// wait for ssh's last words (see `Transport::stderr_tail`).
pub const SSH_TAIL_WAIT: Duration = Duration::from_millis(200);
/// Appended to messages about an SSH connection that ended, when ssh's
/// standard error was passed through.
pub const SSH_ERRORS_SHOWN: &str = " (errors from ssh or cherry-host, if any, are shown above)";
/// A Ping follows every this many bytes of input. The host answers when it
/// has read that far, which shows a detach waiting behind a long paste that
/// the input is still moving, even once ssh has taken all of it.
const INPUT_MARK_BYTES: usize = 64 * 1024;
/// Once the host stopped reading this connection, how long what it sent
/// before (a takeover notice, an exit, a detach confirmation) and its end of
/// file may take to arrive.
pub const CLOSED_WAIT: Duration = Duration::from_secs(5);
/// Output frames that arrived together become one message of at most this
/// much output (see `FrameDecoder::next`).
const MERGED_OUTPUT: usize = 1024 * 1024;
/// The host connection is read at most this much at a time.
pub const READ_BYTES: usize = 64 * 1024;
/// An `Output` frame still arriving gives its output so far once this much
/// of it arrived (see `FrameDecoder::next`).
const PARTIAL_OUTPUT: usize = 4 * 1024;

/// Where the host is.
#[derive(Clone, Copy)]
pub struct Target<'a> {
    /// The SSH destination, or None for this machine.
    pub host: Option<&'a str>,
    /// The host socket; with `host`, a path on the remote machine.
    pub socket: Option<&'a Path>,
    /// With `host`: the ControlPath of an SSH master connection that every
    /// ssh this command runs uses when one listens there.
    pub ssh_control_path: Option<&'a Path>,
}

/// What the connection is for, which decides how long connecting may take
/// and how ssh runs.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    /// One request: `CONNECT_TIMEOUT` overall. ssh runs in batch mode (it
    /// cannot prompt) and forwards no agent, since the connection ends right
    /// after.
    Command,
    /// An interactive attachment: no overall limit, and ssh may prompt in
    /// the terminal and forwards the agent as configured.
    Attach,
    /// `cherry control`, a long-lived connection whose standard input and
    /// output carry frames: ssh runs in batch mode and forwards the agent as
    /// configured, and the `CONNECT_TIMEOUT` limit ends with the handshake.
    Control,
    /// An attachment connecting again after it lost its connection: ssh runs
    /// in batch mode, since the terminal shows the session and must not
    /// get a prompt, and forwards the agent as configured. Nothing ssh or a
    /// cherry-host started here prints reaches the terminal (see
    /// `StderrRelay`); the last line is kept for messages. The caller's
    /// deadline limits connecting.
    Reattach,
}

/// The connection to the host ended or failed: its end of file, a failed
/// read or write, or a host that went silent. An attachment connects again
/// (see `attach::RECONNECT_WINDOW`); anything else is final.
#[derive(Debug)]
pub struct ConnectionLost(pub String);

impl std::fmt::Display for ConnectionLost {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for ConnectionLost {}

pub fn lost(message: impl Into<String>) -> anyhow::Error {
    anyhow::Error::new(ConnectionLost(message.into()))
}

/// Whether `error` is (or was caused by) a lost connection.
pub fn is_lost(error: &anyhow::Error) -> bool {
    error.downcast_ref::<ConnectionLost>().is_some()
}

/// `error` from the connection's I/O, marked as a lost connection; its
/// message is unchanged (`context: error`).
fn lost_io(error: io::Error, context: &str) -> anyhow::Error {
    anyhow::Error::new(error).context(ConnectionLost(context.into()))
}

pub struct Transport {
    reader: OwnedFd,
    /// Closed first on drop, so ssh sees end of input and exits by itself.
    writer: Option<OwnedFd>,
    ssh: Option<Child>,
    decoder: FrameDecoder,
    outgoing: Vec<u8>,
    written: usize,
    /// Bytes queued, and bytes written to the connection, since it opened.
    queued_total: u64,
    sent_total: u64,
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
    /// `links_agent`: the command creates, attaches or controls sessions, so
    /// a local connection points the sessions' agent link at the caller's
    /// agent. Remotely only an attachment or a control connection forwards
    /// its agent (see `ssh_command`).
    ///
    /// `deadline` bounds starting a local host and everything sent and
    /// received (None for an attachment). The caller sets it once, so that
    /// connecting again after replacing an older host shares it.
    ///
    /// `expected_host_id`: the identity the caller will insist on. The
    /// remote gateway neither replaces nor reports a host of another
    /// identity, which the caller then refuses as it would locally.
    pub fn connect(
        target: &Target,
        mode: Mode,
        auto_start: bool,
        links_agent: bool,
        expected_host_id: Option<&str>,
        deadline: Option<Instant>,
    ) -> Result<Self> {
        let mut stderr = None;
        let (reader, writer, ssh, decoder): (OwnedFd, OwnedFd, _, _) = match target.host {
            Some(host) => {
                let mut child = ssh_command(
                    host,
                    target.socket,
                    target.ssh_control_path,
                    mode,
                    auto_start,
                    expected_host_id,
                )?
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .context("could not run system ssh")?;
                let reader = child.stdout.take().context("SSH stdout was not piped")?;
                let writer = child.stdin.take().context("SSH stdin was not piped")?;
                let errors = child.stderr.take().context("SSH stderr was not piped")?;
                stderr = Some(
                    StderrRelay::start(errors, mode == Mode::Reattach)
                        .context("could not relay ssh errors")?,
                );
                (
                    reader.into(),
                    writer.into(),
                    Some(child),
                    FrameDecoder::after_preamble(),
                )
            }
            None => {
                let socket = local_socket_path(target.socket)?;
                let stream = connect_local(&socket, auto_start, deadline, mode == Mode::Reattach)?;
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
            queued_total: 0,
            sent_total: 0,
            progress: Instant::now(),
            write_closed: None,
            received: Instant::now(),
            next_ping: None,
            unmarked_input: 0,
            deadline,
            host: target.host.map(str::to_owned),
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

    /// No overall limit from now on (a control connection, once connected).
    pub fn clear_deadline(&mut self) {
        self.deadline = None;
    }

    /// An overall limit from now on.
    pub fn set_deadline(&mut self, deadline: Instant) {
        self.deadline = Some(deadline);
    }

    /// Nothing more from ssh reaches the terminal: an attachment's screen
    /// shows the session. See `stderr_tail`.
    pub fn silence_stderr(&self) {
        if let Some(relay) = &self.stderr {
            relay.silence();
        }
    }

    /// What ssh said last, once `silence_stderr` (or `Mode::Reattach`) kept
    /// it from the terminal; waits up to `wait` for ssh to finish saying it.
    pub fn stderr_tail(&self, wait: Duration) -> Option<String> {
        self.stderr
            .as_ref()
            .filter(|relay| relay.is_quiet())
            .and_then(|relay| relay.last_line(wait))
    }

    /// The bytes received but not yet decoded, which the next frames start
    /// with. Only once the gateway preamble has arrived.
    pub fn take_buffered(&mut self) -> Vec<u8> {
        self.decoder.take_buffered()
    }

    /// Read what is available without decoding it, once `take_buffered`
    /// emptied the decoder: None when nothing is available, `Some(0)` at end
    /// of file (or when the host reset the connection).
    pub fn read_raw(&mut self, buffer: &mut [u8]) -> Result<Option<usize>> {
        match read_some(self.read_fd(), buffer) {
            Ok(Some(n)) if n > 0 => {
                self.received = Instant::now();
                Ok(Some(n))
            }
            Err(error) if error.kind() == io::ErrorKind::ConnectionReset => Ok(Some(0)),
            read => read.context("could not read host connection"),
        }
    }

    /// Append bytes that already are frames to the outgoing buffer, like
    /// `queue`. Dropped once the host stopped reading.
    pub fn queue_bytes(&mut self, bytes: &[u8]) {
        if self.write_closed.is_some() {
            return;
        }
        if self.pending() == 0 {
            self.outgoing.clear();
            self.written = 0;
            self.progress = Instant::now();
        }
        self.outgoing.extend_from_slice(bytes);
        self.queued_total += bytes.len() as u64;
    }

    /// End what is sent, once everything queued was written, while the
    /// host's frames keep arriving: ssh's input closes, or the socket is
    /// shut down for writing. The host answers what it read, then closes.
    pub fn close_write(&mut self) {
        debug_assert_eq!(self.pending(), 0);
        if let Some(writer) = self.writer.take() {
            if self.ssh.is_none() {
                unsafe {
                    libc::shutdown(writer.as_raw_fd(), libc::SHUT_WR);
                }
            }
        }
    }

    /// Whether `close_write` ended what is sent.
    pub fn finished_sending(&self) -> bool {
        self.writer.is_none()
    }

    /// When bytes last arrived from the host.
    pub fn received(&self) -> Instant {
        self.received
    }

    /// Append a frame to the outgoing buffer without writing it. Dropped
    /// once the host stopped reading.
    pub fn queue(&mut self, message: &ClientMessage) -> Result<()> {
        let frame = cherry_protocol::encode_frame(message).context("could not encode request")?;
        self.queue_bytes(&frame);
        Ok(())
    }

    /// How many bytes were queued on this connection so far. Bytes queued
    /// once the host stopped reading are dropped, and not counted.
    pub fn queued_total(&self) -> u64 {
        self.queued_total
    }

    /// How many of the queued bytes (`queued_total`) the connection took.
    /// Taken is not delivered: bytes still on their way when it is lost may
    /// never have reached the host.
    pub fn sent_total(&self) -> u64 {
        self.sent_total
    }

    pub fn queue_input(&mut self, bytes: &[u8]) -> Result<()> {
        for data in bytes.chunks(MAX_INPUT_BYTES) {
            let frame =
                cherry_protocol::encode_input_frame(data).context("could not encode input")?;
            self.queue_bytes(&frame);
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
            result => result.map_err(|error| lost_io(error, "could not send to host")),
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
                self.sent_total += n as u64;
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

    /// Read what is available, up to `max` bytes. False at end of file.
    pub fn read_ready(&mut self, max: usize) -> Result<bool> {
        match self.decoder.read_from(self.read_fd(), max)? {
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
    /// A Pong is never the answer: hosts may send one at any time. Nor is an
    /// Event, which a host pushes on its own (to subscribers only).
    pub fn receive(&mut self, idle: Duration) -> Result<ServerMessage> {
        match self.receive_unless_closed(idle)? {
            Some(message) => Ok(message),
            None => Err(self.closed_error()),
        }
    }

    /// Like `receive`, but None when the host ends the connection (or stops
    /// reading it) first.
    pub fn receive_unless_closed(&mut self, idle: Duration) -> Result<Option<ServerMessage>> {
        let mut progress = Instant::now();
        loop {
            interrupted()?;
            match self.next_message()? {
                Some(ServerMessage::Pong | ServerMessage::Event { .. }) => continue,
                Some(message) => return Ok(Some(message)),
                None => {}
            }
            let limit = self.limit(progress + idle);
            let now = Instant::now();
            if self.closed_deadline().is_some_and(|at| now >= at) {
                return Ok(None);
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
                if !self.read_ready(READ_BYTES)? {
                    return Ok(None);
                }
                progress = Instant::now();
            }
        }
    }

    /// Why the connection ended, for an unexpected end of file. A gateway
    /// that could not reach a host explains why on ssh's standard error and
    /// exits before its preamble.
    pub fn closed_error(&mut self) -> anyhow::Error {
        let quiet = self.stderr.as_ref().is_some_and(StderrRelay::is_quiet);
        if self.decoder.awaiting_preamble() {
            // ssh may deliver the explanation just after the end of output.
            let mut reports = self
                .stderr
                .as_ref()
                .map(|relay| relay.take_reports(GATEWAY_REPORT_WAIT))
                .unwrap_or_default();
            if let Some(report) = reports.pop() {
                if !quiet {
                    print_reports(&reports);
                }
                let reason = report.strip_prefix("cherry-host: ").unwrap_or(&report);
                let host = self.host.as_deref().unwrap_or("the remote host");
                let never = if !self.starts_host && reason.starts_with("no cherry-host is running")
                {
                    " (this command never starts one)"
                } else {
                    ""
                };
                let message = format!("cherry-host on {host}: {reason}{never}");
                // A host of another version that the gateway did not
                // replace (a newer one, one too old to make way, or one that
                // refused): connecting again finds the same.
                return if reason.starts_with(OTHER_VERSION_REPORT) {
                    crate::unresolvable(message)
                } else {
                    anyhow!(message)
                };
            }
        }
        let note = match &self.stderr {
            None => String::new(),
            Some(_) if !quiet => SSH_ERRORS_SHOWN.to_owned(),
            Some(relay) => relay
                .last_line(SSH_TAIL_WAIT)
                .map(|line| format!(": {line}"))
                .unwrap_or_default(),
        };
        self.decoder.closed_error(&note)
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
        // Remote cherry-host errors that no message has reported, unless
        // the terminal shows a session (or connects to one again).
        if let Some(relay) = self.stderr.as_ref().filter(|relay| !relay.is_quiet()) {
            print_reports(&relay.take_reports(Duration::from_millis(200)));
        }
    }
}

/// Errors from writing to a peer that closed its connection or stopped
/// reading it: EPIPE, ECONNRESET, and ENOTCONN (macOS, once the peer is
/// gone).
pub fn stopped_reading(error: &io::Error) -> bool {
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
    control_path: Option<&Path>,
    mode: Mode,
    starts_host: bool,
    expected_host_id: Option<&str>,
) -> Result<Command> {
    crate::validate_host(host).map_err(anyhow::Error::msg)?;
    let alive = format!("ServerAliveInterval={}", HEARTBEAT_INTERVAL.as_secs());
    let mut ssh = Command::new("ssh");
    ssh.arg("-T");
    // Never become a ControlMaster (exiting would end the user's other
    // multiplexed sessions). A ControlPath lets this ssh use the master
    // connection listening there, or connect directly when none is.
    ssh.args(["-o", "ControlMaster=no"]);
    if let Some(path) = control_path {
        ssh.arg("-o").arg(ssh_control_path_option(path)?);
    }
    // Ignore alias settings meant for interactive logins: a RemoteCommand
    // conflicts with ours, forwards can fail to bind.
    for option in [
        "RemoteCommand=none",
        "ClearAllForwardings=yes",
        "PermitLocalCommand=no",
        &alive,
        "ServerAliveCountMax=3",
    ] {
        ssh.args(["-o", option]);
    }
    // The remote gateway points the sessions' agent link at the agent
    // forwarded to it. Only an attachment or a control connection keeps its
    // connection, and so that agent, open; any other command's would vanish
    // right after. Only an attachment connecting for the first time has a
    // terminal to prompt in.
    match mode {
        Mode::Command => {
            ssh.args(["-a", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]);
        }
        Mode::Control | Mode::Reattach => {
            ssh.args(["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]);
        }
        Mode::Attach => {}
    }
    ssh.args(["--", host]).arg(remote_gateway_command(
        socket,
        starts_host,
        expected_host_id,
    )?);
    Ok(ssh)
}

/// `ControlPath=<path>`, with `%` doubled: ssh expands `%` tokens in it.
/// `crate::validate_ssh_control_path` accepted the path, so nothing else in
/// it is special to ssh.
pub fn ssh_control_path_option(path: &Path) -> Result<String> {
    let path = path
        .to_str()
        .context("the SSH control path must be valid UTF-8")?;
    crate::validate_ssh_control_path(path).map_err(anyhow::Error::msg)?;
    Ok(format!("ControlPath={}", path.replace('%', "%%")))
}

/// The command the remote shell runs. The expected host identity goes in
/// the environment (`cherry_protocol::EXPECTED_HOST_ID_VAR`), through `env`
/// so that any login shell runs it: a cherry-host of another version
/// ignores the variable, where it would refuse an option it does not know
/// before its preamble could say what it is.
pub fn remote_gateway_command(
    socket: Option<&Path>,
    starts_host: bool,
    expected_host_id: Option<&str>,
) -> Result<String> {
    let mut command = String::new();
    if let Some(id) = expected_host_id {
        if id.contains('\0') {
            bail!("host identity contains a NUL byte");
        }
        command.push_str(&format!(
            "env {}={} ",
            cherry_protocol::EXPECTED_HOST_ID_VAR,
            shell_quote(id)
        ));
    }
    command.push_str("cherry-host gateway");
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
        command.push_str(&format!(" --socket {}", shell_quote(path)));
    }
    Ok(command)
}

/// `text` as one word for the remote shell.
fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
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
/// listening and `auto_start` allows it, giving up at `deadline`; `quiet`
/// keeps what starting it prints off the terminal (see `start_local_host`).
fn connect_local(
    socket: &Path,
    auto_start: bool,
    deadline: Option<Instant>,
    quiet: bool,
) -> Result<UnixStream> {
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
            start_local_host(socket, deadline, quiet)?;
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

/// Run `cherry-host start` and wait for it, for at most `RPC_TIMEOUT` and
/// never past `deadline`. What it prints goes to our standard error, or,
/// when `quiet` (an attachment's terminal shows a session), only its last
/// line into the error when it fails.
pub fn start_local_host(socket: &Path, deadline: Option<Instant>, quiet: bool) -> Result<()> {
    let limit = Instant::now() + RPC_TIMEOUT;
    let deadline = deadline.map_or(limit, |deadline| deadline.min(limit));
    // Connecting again after a Replace may find the time already spent.
    if Instant::now() >= deadline {
        bail!("timed out starting cherry-host");
    }
    let executable = host_executable()?;
    // The daemon outlives this command; never keep the caller's directory busy.
    let mut child = Command::new(&executable)
        .args(["start", "--socket"])
        .arg(socket)
        .current_dir("/")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(if quiet {
            Stdio::piped()
        } else {
            Stdio::inherit()
        })
        .spawn()
        .with_context(|| {
            format!(
                "could not start {}; install cherry-host beside cherry, on PATH, or set CHERRY_HOST_PATH",
                executable.display()
            )
        })?;
    let mut errors = HeldOutput::new(child.stderr.take())?;
    loop {
        // Before the exit status, so nothing it printed before exiting is
        // missed; it never fills the pipe.
        errors.read_available();
        match child.try_wait()? {
            Some(status) if status.success() => return Ok(()),
            Some(status) => {
                errors.read_available();
                let reason = errors
                    .last_line()
                    .map(|line| format!(": {line}"))
                    .unwrap_or_default();
                bail!("cherry-host start failed ({status}){reason}")
            }
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

/// A child's piped output, read without waiting; only the end is kept.
struct HeldOutput {
    source: Option<std::process::ChildStderr>,
    bytes: Vec<u8>,
}

impl HeldOutput {
    const KEEP: usize = 4096;

    fn new(source: Option<std::process::ChildStderr>) -> Result<Self> {
        if let Some(source) = &source {
            set_nonblocking(source.as_raw_fd())?;
        }
        Ok(Self {
            source,
            bytes: Vec::new(),
        })
    }

    fn read_available(&mut self) {
        let Some(source) = &self.source else {
            return;
        };
        let mut buffer = [0u8; 4096];
        loop {
            match read_some(source.as_raw_fd(), &mut buffer) {
                Ok(Some(n)) if n > 0 => {
                    self.bytes.extend_from_slice(&buffer[..n]);
                    let excess = self.bytes.len().saturating_sub(Self::KEEP);
                    self.bytes.drain(..excess);
                }
                Ok(Some(_)) | Err(_) => {
                    self.source = None;
                    return;
                }
                Ok(None) => return,
            }
        }
    }

    fn last_line(&self) -> Option<String> {
        String::from_utf8_lossy(&self.bytes)
            .lines()
            .map(str::trim)
            .rfind(|line| !line.is_empty())
            .map(str::to_owned)
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
    /// An `Output` frame whose output was given in part: the offset of the
    /// rest, and how long the rest is (see `next`).
    partial: Option<(u64, usize)>,
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

    /// The bytes not decoded yet, leaving the decoder empty. The rest of an
    /// `Output` frame given in part is a frame of its own again.
    pub(crate) fn take_buffered(&mut self) -> Vec<u8> {
        debug_assert!(!self.awaiting_preamble);
        let mut rest = self.bytes.split_off(self.consumed);
        self.bytes.clear();
        self.consumed = 0;
        if let Some((offset, left)) = self.partial.take() {
            let mut frame = Vec::with_capacity(OUTPUT_HEADER + rest.len());
            frame.extend_from_slice(&((1 + 8 + left) as u32).to_be_bytes());
            frame.push(binary_kind::OUTPUT);
            frame.extend_from_slice(&offset.to_be_bytes());
            frame.append(&mut rest);
            rest = frame;
        }
        rest
    }

    /// The next message. An `Output` frame is given as its output arrives,
    /// in parts of at least `PARTIAL_OUTPUT` (and its last), rather than
    /// once it arrived whole: a big frame for a terminal that takes it
    /// slowly then never keeps the connection unread while the terminal
    /// takes the whole of it (see `attach::TerminalOutput::read_size`).
    pub fn next(&mut self) -> Result<Option<ServerMessage>> {
        if self.awaiting_preamble && !self.take_preamble()? {
            return Ok(None);
        }
        if let Some((offset, left)) = self.partial {
            let pending = &self.bytes[self.consumed..];
            let n = pending.len().min(left);
            if n == 0 || (n < left && n < PARTIAL_OUTPUT) {
                return Ok(None);
            }
            let data = pending[..n].to_vec();
            self.consumed += n;
            self.partial = (n < left).then(|| (offset + n as u64, left - n));
            self.compact_consumed();
            return Ok(Some(ServerMessage::Output { offset, data }));
        }
        let pending = &self.bytes[self.consumed..];
        if pending.len() < 4 {
            return Ok(None);
        }
        let word = pending[..4].try_into().unwrap();
        let Ok(len) = cherry_protocol::frame_length(word) else {
            bail!(
                "host sent invalid frame length {}",
                u32::from_be_bytes(word)
            );
        };
        if pending.len() < 4 + len {
            // An `Output` frame still arriving: its output so far.
            if let Some((offset, data)) = output_frame_parts(pending)
                .filter(|(_, data)| data.len() >= PARTIAL_OUTPUT && len > 1 + 8)
            {
                let data = data.to_vec();
                self.partial = Some((offset + data.len() as u64, len - 1 - 8 - data.len()));
                self.consumed = self.bytes.len();
                self.compact_consumed();
                return Ok(Some(ServerMessage::Output { offset, data }));
            }
            return Ok(None);
        }
        let mut message = ServerMessage::decode_body(&pending[4..4 + len])
            .context("host sent an invalid frame")?;
        self.consumed += 4 + len;
        if let ServerMessage::Output { offset, data } = &mut message {
            self.merge_output(*offset, data);
        }
        self.compact_consumed();
        Ok(Some(message))
    }

    /// Once everything received was decoded, the buffer starts afresh.
    fn compact_consumed(&mut self) {
        if self.consumed == self.bytes.len() {
            self.bytes.clear();
            self.consumed = 0;
        }
    }

    /// Take the output of the `Output` frames that follow at once and
    /// continue `data` (at `offset`), up to `MERGED_OUTPUT` in all: one
    /// message rather than one per frame.
    fn merge_output(&mut self, offset: u64, data: &mut Vec<u8>) {
        while data.len() < MERGED_OUTPUT {
            let pending = &self.bytes[self.consumed..];
            let Some(word) = pending.get(..4) else {
                return;
            };
            let len = u32::from_be_bytes(word.try_into().unwrap()) as usize;
            let Some(frame) = pending.get(..4 + len) else {
                return;
            };
            match output_frame_parts(frame) {
                Some((next, more))
                    if Some(next) == offset.checked_add(data.len() as u64)
                        && data.len() + more.len() <= MERGED_OUTPUT =>
                {
                    data.extend_from_slice(more);
                    self.consumed += 4 + len;
                }
                _ => return,
            }
        }
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
            // The remote cherry-host is another build: connecting again
            // runs the same one.
            return Err(crate::unresolvable(format!(
                "protocol version mismatch: the remote cherry-host gateway speaks version {version}, this cherry speaks version {PROTOCOL_VERSION}; install the same Cherry version on both machines"
            )));
        }
        self.consumed += start + GATEWAY_PREAMBLE.len() + end + 1;
        self.awaiting_preamble = false;
        self.junk.clear();
        Ok(true)
    }

    /// Why the connection ended, for an unexpected end of file. `ssh` is
    /// appended to the first part: where ssh's errors are, or what ssh said
    /// last (see `Transport::closed_error`).
    pub fn closed_error(&self, ssh: &str) -> anyhow::Error {
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
    fn read_from(&mut self, fd: RawFd, max: usize) -> Result<Option<usize>> {
        if self.consumed > 0 {
            self.bytes.drain(..self.consumed);
            self.consumed = 0;
        }
        let mut buffer = [0u8; READ_BYTES];
        let read = match read_some(fd, &mut buffer[..max.clamp(1, READ_BYTES)]) {
            // A peer that closed with bytes of ours unread resets the
            // connection (Linux) once what it sent before is read.
            Err(error) if error.kind() == io::ErrorKind::ConnectionReset => Ok(Some(0)),
            read => read,
        };
        match read.map_err(|error| lost_io(error, "could not read host connection"))? {
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A transport over `reader` and `writer`, as if connected locally.
    fn over(reader: OwnedFd, writer: OwnedFd) -> Transport {
        Transport {
            reader,
            writer: Some(writer),
            ssh: None,
            decoder: FrameDecoder::default(),
            outgoing: Vec::new(),
            written: 0,
            queued_total: 0,
            sent_total: 0,
            progress: Instant::now(),
            write_closed: None,
            received: Instant::now(),
            next_ping: None,
            unmarked_input: 0,
            deadline: None,
            host: None,
            stderr: None,
            starts_host: true,
        }
    }

    fn open(path: &str) -> OwnedFd {
        std::fs::File::open(path).unwrap().into()
    }

    #[test]
    fn failed_reads_and_writes_are_lost_connections_with_their_messages() {
        // A write that fails other than by the host no longer reading.
        let mut transport = over(open("/dev/null"), open("/dev/null"));
        transport.queue(&ClientMessage::Ping).unwrap();
        let error = transport.write_ready().unwrap_err();
        assert!(is_lost(&error), "{error:#}");
        assert!(
            format!("{error:#}").starts_with("could not send to host: "),
            "{error:#}"
        );
        assert!(transport.closed_deadline().is_none());

        // A read that fails other than by a reset.
        let mut transport = over(open("/"), open("/dev/null"));
        let error = transport.read_ready(READ_BYTES).unwrap_err();
        assert!(is_lost(&error), "{error:#}");
        assert!(
            format!("{error:#}").starts_with("could not read host connection: "),
            "{error:#}"
        );

        // A host that stopped reading only ends the writing.
        let (local, peer) = UnixStream::pair().unwrap();
        drop(peer);
        let mut transport = over(local.try_clone().unwrap().into(), local.into());
        transport.queue(&ClientMessage::Ping).unwrap();
        transport.write_ready().unwrap();
        assert!(transport.closed_deadline().is_some());
        assert!(!transport.read_ready(READ_BYTES).unwrap(), "end of file");

        // Protocol errors are not lost connections.
        assert!(!is_lost(&anyhow!("host sent invalid JSON frame")));
    }
}
