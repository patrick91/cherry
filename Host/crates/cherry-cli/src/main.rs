use anyhow::{bail, Context, Result};
use cherry_protocol::{
    default_socket_path, valid_size, ClientMessage, ServerMessage, SessionList, DEFAULT_COLS,
    DEFAULT_ROWS, MAX_FRAME_BYTES, MAX_INPUT_BYTES, PROTOCOL_VERSION,
};
use clap::{Parser, Subcommand};
use std::{
    ffi::OsString,
    io,
    os::{
        fd::{AsRawFd, RawFd},
        unix::net::UnixStream,
    },
    path::{Path, PathBuf},
    process::{Child, ChildStdin, ChildStdout, Command, ExitCode, Stdio},
    sync::atomic::{AtomicBool, AtomicI32, Ordering},
    time::{Duration, Instant},
};

const RPC_TIMEOUT: Duration = Duration::from_secs(15);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(120);
const DETACH_KEY: u8 = 0x1d;
const DETACH_SEQUENCE_WAIT: Duration = Duration::from_millis(25);
static TERMINATION_SIGNAL: AtomicI32 = AtomicI32::new(0);
static RESIZE_PENDING: AtomicBool = AtomicBool::new(false);

#[derive(Parser, Debug)]
#[command(
    name = "cherry",
    version,
    about = "Persistent Cherry terminal sessions, locally or over SSH"
)]
struct Cli {
    /// SSH host alias (uses your normal SSH configuration and authentication).
    #[arg(long, global = true, value_parser = validate_host)]
    host: Option<String>,
    /// Host socket path; with --host this is a path on the remote machine.
    #[arg(long, global = true)]
    socket: Option<PathBuf>,
    /// Require the saved host identity before reading or changing its sessions.
    #[arg(long, global = true)]
    expected_host_id: Option<uuid::Uuid>,
    #[command(subcommand)]
    command: Action,
}

#[derive(Subcommand, Debug)]
enum Action {
    /// Start the local host daemon. Other commands also start it when needed.
    Start,
    /// Stop the host daemon; refused while it owns any running sessions.
    Shutdown,
    /// List sessions on the selected host.
    List {
        #[arg(long)]
        json: bool,
    },
    /// Create a persistent session and print its JSON descriptor.
    New {
        #[arg(long)]
        cwd: String,
        #[arg(long, default_value = "Terminal")]
        name: String,
        /// Reusing this UUID makes retries of session creation idempotent.
        #[arg(long)]
        request_id: Option<uuid::Uuid>,
        #[arg(long)]
        json: bool,
        /// Program and arguments, after --. Defaults to the host's login shell.
        #[arg(last = true)]
        command: Vec<String>,
    },
    /// Attach to a session. Ctrl-] is reserved for detaching without stopping it.
    Attach {
        id: String,
        /// Disconnect this session's current controller and take its place.
        #[arg(long)]
        takeover: bool,
    },
    /// Terminate a session on the host.
    Kill { id: String },
    /// Remove an exited session from the host's retained session list.
    Remove { id: String },
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let result = SignalGuard::install().and_then(|_signals| run(cli));
    match result {
        Ok(code) => ExitCode::from(code.min(255) as u8),
        Err(error) => {
            eprintln!("cherry: {error:#}");
            let signal = TERMINATION_SIGNAL.load(Ordering::Relaxed);
            ExitCode::from(if signal > 0 { (128 + signal) as u8 } else { 1 })
        }
    }
}

fn run(cli: Cli) -> Result<u32> {
    if matches!(cli.command, Action::Start) {
        if cli.host.is_some() {
            bail!("start is local only; remote commands automatically start the remote host");
        }
        start_local_host(&cli.socket.unwrap_or_else(default_socket_path))?;
        return Ok(0);
    }

    let interactive = matches!(cli.command, Action::Attach { .. });
    let mut transport =
        Transport::connect(cli.host.as_deref(), cli.socket.as_deref(), interactive)?;
    let mut decoder = FrameDecoder::default();
    transport.send(&ClientMessage::Hello {
        version: PROTOCOL_VERSION,
    })?;
    let capabilities = match transport.receive(
        &mut decoder,
        if interactive {
            HANDSHAKE_TIMEOUT
        } else {
            Duration::from_secs(30)
        },
    )? {
        ServerMessage::Welcome {
            version,
            host_id,
            capabilities,
        } if version == PROTOCOL_VERSION => {
            if let Some(expected) = cli.expected_host_id {
                if host_id != expected.to_string() {
                    bail!("host identity changed (expected {expected}, received {host_id}); reconnect to the intended host before using this session");
                }
            }
            capabilities
        }
        ServerMessage::Welcome { version, .. } => {
            bail!("host protocol version {version} is incompatible with client version {PROTOCOL_VERSION}; update Cherry on both machines")
        }
        message => {
            unexpected("welcome", message)?;
            unreachable!()
        }
    };

    match cli.command {
        Action::Start => unreachable!(),
        Action::Shutdown => {
            transport.send(&ClientMessage::Shutdown)?;
            match transport.receive(&mut decoder, RPC_TIMEOUT)? {
                ServerMessage::Ok => Ok(0),
                message => {
                    unexpected("shutdown acknowledgement", message)?;
                    unreachable!()
                }
            }
        }
        Action::List { json } => {
            transport.send(&ClientMessage::List)?;
            match transport.receive(&mut decoder, RPC_TIMEOUT)? {
                ServerMessage::Sessions { host_id, sessions } => {
                    if json {
                        println!(
                            "{}",
                            serde_json::to_string(&SessionList { host_id, sessions })?
                        );
                    } else {
                        for session in sessions {
                            println!(
                                "{}\t{}\t{:?}\t{}",
                                session.id, session.name, session.state, session.cwd
                            );
                        }
                    }
                }
                message => unexpected("session list", message)?,
            }
            Ok(0)
        }
        Action::New {
            cwd,
            name,
            request_id,
            command,
            ..
        } => {
            let (cols, rows) = terminal_size();
            transport.send(&ClientMessage::Create {
                request_id: request_id.unwrap_or_else(uuid::Uuid::new_v4).to_string(),
                name,
                cwd,
                command,
                env: Default::default(),
                cols,
                rows,
            })?;
            match transport.receive(&mut decoder, RPC_TIMEOUT)? {
                ServerMessage::Created { session } => {
                    println!("{}", serde_json::to_string(&session)?)
                }
                message => unexpected("created session", message)?,
            }
            Ok(0)
        }
        Action::Kill { id } => {
            transport.send(&ClientMessage::Kill { id })?;
            match transport.receive(&mut decoder, RPC_TIMEOUT)? {
                ServerMessage::Ok => Ok(0),
                message => {
                    unexpected("kill acknowledgement", message)?;
                    unreachable!()
                }
            }
        }
        Action::Remove { id } => {
            transport.send(&ClientMessage::Remove { id })?;
            match transport.receive(&mut decoder, RPC_TIMEOUT)? {
                ServerMessage::Ok => Ok(0),
                message => {
                    unexpected("remove acknowledgement", message)?;
                    unreachable!()
                }
            }
        }
        Action::Attach { id, takeover } => {
            if takeover
                && !capabilities
                    .iter()
                    .any(|capability| capability == "attach_takeover")
            {
                bail!("this host does not support taking over an attached session; update cherry-host on that machine, or disconnect its current controller before attaching without --takeover");
            }
            let shared_rendering = capabilities
                .iter()
                .any(|capability| capability == "multi_attach");
            attach(
                &mut transport,
                &mut decoder,
                &id,
                takeover,
                shared_rendering,
            )
        }
    }
}

fn unexpected(expected: &str, message: ServerMessage) -> Result<()> {
    match message {
        ServerMessage::Error { code, message } => {
            bail!("host rejected request ({code}): {message}")
        }
        other => bail!("expected {expected}, received {}", message_kind(&other)),
    }
}

fn message_kind(message: &ServerMessage) -> &'static str {
    match message {
        ServerMessage::Welcome { .. } => "welcome",
        ServerMessage::Sessions { .. } => "sessions",
        ServerMessage::Created { .. } => "created",
        ServerMessage::Attached { .. } => "attached",
        ServerMessage::Output { .. } => "output",
        ServerMessage::Exit { .. } => "exit",
        ServerMessage::Ok => "ok",
        ServerMessage::Error { .. } => "error",
    }
}

fn validate_host(value: &str) -> std::result::Result<String, String> {
    if value.is_empty()
        || value.starts_with('-')
        || value.len() > 512
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._-@:[%]".contains(&byte))
    {
        return Err(
            "expected an SSH host alias or user@host, without spaces or shell syntax".into(),
        );
    }
    Ok(value.to_owned())
}

fn remote_gateway_command(socket: Option<&Path>) -> Result<String> {
    match socket {
        None => Ok("cherry-host gateway".into()),
        Some(path) => {
            let path = path
                .to_str()
                .context("remote socket path must be valid UTF-8")?;
            if path.contains('\0') {
                bail!("socket path contains a NUL byte");
            }
            Ok(format!(
                "cherry-host gateway --socket '{}'",
                path.replace('\'', "'\\''")
            ))
        }
    }
}

fn host_executable() -> Result<OsString> {
    if let Some(path) = std::env::var_os("CHERRY_HOST_PATH") {
        if path.is_empty() {
            bail!("CHERRY_HOST_PATH is empty");
        }
        return Ok(path);
    }
    if let Ok(executable) = std::env::current_exe() {
        if let Some(directory) = executable.parent() {
            let sibling = directory.join("cherry-host");
            if sibling.is_file() {
                return Ok(sibling.into_os_string());
            }
        }
    }
    Ok("cherry-host".into())
}

fn start_local_host(socket: &Path) -> Result<()> {
    let mut child = Command::new(host_executable()?)
        .args(["start", "--socket"]).arg(socket)
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::inherit())
        .spawn().context("could not start cherry-host; install it beside cherry, on PATH, or set CHERRY_HOST_PATH")?;
    let deadline = Instant::now() + RPC_TIMEOUT;
    loop {
        match child.try_wait()? {
            Some(status) if status.success() => return Ok(()),
            Some(status) => bail!("cherry-host start failed ({status})"),
            None => {}
        }
        if interrupted().is_err() || Instant::now() >= deadline {
            stop_child(&mut child);
            interrupted()?;
            bail!("timed out starting cherry-host");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

enum Transport {
    Local {
        reader: UnixStream,
        writer: UnixStream,
        deadline: Option<Instant>,
    },
    Ssh {
        reader: ChildStdout,
        writer: ChildStdin,
        child: Child,
        deadline: Option<Instant>,
    },
}

impl Transport {
    fn connect(host: Option<&str>, socket: Option<&Path>, interactive: bool) -> Result<Self> {
        let deadline = (!interactive).then(|| Instant::now() + Duration::from_secs(30));
        let transport = if let Some(host) = host {
            validate_host(host).map_err(anyhow::Error::msg)?;
            let mut ssh = Command::new("ssh");
            ssh.arg("-T");
            if !interactive {
                ssh.args(["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]);
            }
            let mut child = ssh
                .args(["--", host])
                .arg(remote_gateway_command(socket)?)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::inherit())
                .spawn()
                .context("could not run system ssh")?;
            let reader = child.stdout.take().context("SSH stdout was not piped")?;
            let writer = child.stdin.take().context("SSH stdin was not piped")?;
            Self::Ssh {
                reader,
                writer,
                child,
                deadline,
            }
        } else {
            let socket = socket
                .map(Path::to_path_buf)
                .unwrap_or_else(default_socket_path);
            let reader = match UnixStream::connect(&socket) {
                Ok(stream) => stream,
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
                    ) =>
                {
                    start_local_host(&socket)?;
                    UnixStream::connect(&socket)
                        .with_context(|| format!("could not connect to {}", socket.display()))?
                }
                Err(error) => {
                    return Err(error)
                        .with_context(|| format!("could not connect to {}", socket.display()))
                }
            };
            let writer = reader.try_clone()?;
            Self::Local {
                reader,
                writer,
                deadline,
            }
        };
        set_nonblocking(transport.read_fd())?;
        set_nonblocking(transport.write_fd())?;
        Ok(transport)
    }

    fn read_fd(&self) -> RawFd {
        match self {
            Self::Local { reader, .. } => reader.as_raw_fd(),
            Self::Ssh { reader, .. } => reader.as_raw_fd(),
        }
    }

    fn write_fd(&self) -> RawFd {
        match self {
            Self::Local { writer, .. } => writer.as_raw_fd(),
            Self::Ssh { writer, .. } => writer.as_raw_fd(),
        }
    }

    fn send(&mut self, message: &ClientMessage) -> Result<()> {
        let mut frame = Vec::new();
        cherry_protocol::write_frame(&mut frame, message)?;
        write_bytes(self.write_fd(), &frame, self.operation_timeout(RPC_TIMEOUT))
            .context("could not send to host")
    }

    fn send_input(&mut self, bytes: &[u8]) -> Result<()> {
        for data in bytes.chunks(MAX_INPUT_BYTES) {
            self.send(&ClientMessage::Input {
                data: data.to_vec(),
            })?;
        }
        Ok(())
    }

    fn receive(&mut self, decoder: &mut FrameDecoder, timeout: Duration) -> Result<ServerMessage> {
        let deadline = Instant::now() + self.operation_timeout(timeout);
        loop {
            interrupted()?;
            if let Some(message) = decoder.next()? {
                return Ok(message);
            }
            if Instant::now() >= deadline {
                bail!("timed out waiting for host");
            }
            let mut fds = [libc::pollfd {
                fd: self.read_fd(),
                events: libc::POLLIN,
                revents: 0,
            }];
            poll(
                &mut fds,
                Duration::from_millis(100).min(deadline.saturating_duration_since(Instant::now())),
            )?;
            if fds[0].revents != 0 && !decoder.read_from(self.read_fd())? {
                bail!("host connection closed unexpectedly (SSH errors, if any, are shown above)");
            }
        }
    }

    fn operation_timeout(&self, maximum: Duration) -> Duration {
        let deadline = match self {
            Self::Local { deadline, .. } | Self::Ssh { deadline, .. } => deadline,
        };
        deadline
            .map(|deadline| maximum.min(deadline.saturating_duration_since(Instant::now())))
            .unwrap_or(maximum)
    }
}

impl Drop for Transport {
    fn drop(&mut self) {
        if let Self::Ssh { child, .. } = self {
            stop_child(child);
        }
    }
}

fn stop_child(child: &mut Child) {
    if matches!(child.try_wait(), Ok(Some(_))) {
        return;
    }
    let _ = child.kill();
    let deadline = Instant::now() + Duration::from_millis(500);
    while Instant::now() < deadline {
        match child.try_wait() {
            Ok(None) => std::thread::sleep(Duration::from_millis(10)),
            _ => return,
        }
    }
}

#[derive(Default)]
struct FrameDecoder {
    bytes: Vec<u8>,
    consumed: usize,
}

impl FrameDecoder {
    fn next(&mut self) -> Result<Option<ServerMessage>> {
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

    fn read_from(&mut self, fd: RawFd) -> Result<bool> {
        if self.consumed > 0 {
            self.bytes.drain(..self.consumed);
            self.consumed = 0;
        }
        let mut buffer = [0u8; 65536];
        let n = unsafe { libc::read(fd, buffer.as_mut_ptr().cast(), buffer.len()) };
        if n > 0 {
            self.bytes.extend_from_slice(&buffer[..n as usize]);
            if self.bytes.len() > MAX_FRAME_BYTES + 4 + buffer.len() {
                bail!("host frame buffer exceeded limit");
            }
            Ok(true)
        } else if n == 0 {
            Ok(false)
        } else {
            let error = io::Error::last_os_error();
            if matches!(
                error.kind(),
                io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
            ) {
                Ok(true)
            } else {
                Err(error).context("could not read host connection")
            }
        }
    }
}

fn attach(
    transport: &mut Transport,
    decoder: &mut FrameDecoder,
    id: &str,
    takeover: bool,
    shared_rendering: bool,
) -> Result<u32> {
    let (cols, rows) = terminal_size();
    transport.send(&ClientMessage::Attach {
        id: id.into(),
        cols,
        rows,
        takeover,
    })?;
    let (session, mut offset, snapshot) = match transport.receive(decoder, RPC_TIMEOUT)? {
        ServerMessage::Attached {
            session,
            offset,
            snapshot,
        } if session.id == id => (session, offset, snapshot),
        message => {
            unexpected("attached session", message)?;
            unreachable!()
        }
    };
    // Drop the raw-mode guard first on every exit. Screen restoration then has
    // its own short deadline and cannot hold the user's terminal in raw mode.
    let output = TerminalOutput::new(libc::STDOUT_FILENO)?;
    let _terminal = RawTerminal::enter(libc::STDIN_FILENO)?;
    let mut renderer = if shared_rendering {
        Some(SharedRenderer::new(
            (session.cols, session.rows),
            (cols, rows),
            &snapshot,
        )?)
    } else {
        None
    };
    output.write_all(&match &renderer {
        Some(renderer) => renderer.initial(&snapshot)?,
        None => snapshot,
    })?;
    let mut input = [0u8; MAX_INPUT_BYTES];
    let mut detach_input = DetachInput::default();
    let immediate_input = input_is_immediately_readable(libc::STDIN_FILENO);
    loop {
        interrupted()?;
        // Keep a lone Escape responsive while allowing one encoded key event
        // split across adjacent reads to be recognized as the local escape.
        if detach_input.remaining_wait() == Some(Duration::ZERO) {
            let data = detach_input.flush_pending();
            transport.send_input(&data)?;
        }
        if RESIZE_PENDING.swap(false, Ordering::Relaxed) {
            let (cols, rows) = terminal_size();
            transport.send(&ClientMessage::Resize { cols, rows })?;
            if let Some(renderer) = &mut renderer {
                output.write_all(&renderer.resize_physical((cols, rows))?)?;
            }
        }
        // Drain buffered frames before polling so a snapshot and live output in
        // one read cannot leave the live bytes waiting for another network event.
        let mut repaint = false;
        while let Some(message) = decoder.next()? {
            match message {
                ServerMessage::Output { offset: next, data } => {
                    check_output_offset(&mut offset, next, data.len())?;
                    if renderer
                        .as_mut()
                        .is_some_and(|renderer| renderer.update(&data))
                    {
                        repaint = true;
                    } else {
                        output.write_all(&data)?;
                    }
                }
                ServerMessage::Attached {
                    session,
                    offset: next,
                    snapshot,
                } if session.id == id => {
                    // The host serializes a size change and its fresh snapshot
                    // with output. Replace canonical state before consuming the
                    // next frame; no client-side input or output is replayed.
                    offset = next;
                    repaint = false;
                    if let Some(renderer) = &mut renderer {
                        *renderer = SharedRenderer::new(
                            (session.cols, session.rows),
                            terminal_size(),
                            &snapshot,
                        )?;
                        output.write_all(&renderer.initial(&snapshot)?)?;
                    } else {
                        output.write_all(&snapshot)?;
                    }
                }
                ServerMessage::Exit {
                    id: exited_id,
                    exit_code,
                } if exited_id == id => {
                    paint_shared_frame(&output, &renderer, repaint)?;
                    return Ok(exit_code);
                }
                message => {
                    paint_shared_frame(&output, &renderer, repaint)?;
                    unexpected("session output", message)?;
                }
            }
        }
        paint_shared_frame(&output, &renderer, repaint)?;
        let mut fds = [
            libc::pollfd {
                fd: transport.read_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: if immediate_input {
                    -1
                } else {
                    libc::STDIN_FILENO
                },
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        poll(
            &mut fds,
            if immediate_input {
                Duration::ZERO
            } else {
                detach_input
                    .remaining_wait()
                    .unwrap_or(Duration::from_millis(100))
            },
        )?;
        interrupted()?;
        if fds[0].revents != 0 && !decoder.read_from(transport.read_fd())? {
            bail!("connection lost while attached to {id}; the session may still be running on the host. Reattach to resume; input was not resent");
        }
        if immediate_input || fds[1].revents != 0 {
            let n =
                unsafe { libc::read(libc::STDIN_FILENO, input.as_mut_ptr().cast(), input.len()) };
            if n == 0 {
                let data = detach_input.flush_pending();
                transport.send_input(&data)?;
                transport.send(&ClientMessage::Detach)?;
                return Ok(0);
            }
            if n < 0 {
                let error = io::Error::last_os_error();
                if matches!(
                    error.kind(),
                    io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
                ) {
                    continue;
                }
                return Err(error).context("could not read terminal input");
            }
            let bytes = &input[..n as usize];
            let parsed = detach_input.feed(bytes);
            transport.send_input(&parsed.data)?;
            if parsed.detach {
                transport.send(&ClientMessage::Detach)?;
                return Ok(0);
            }
        }
    }
}

fn paint_shared_frame(
    output: &TerminalOutput,
    renderer: &Option<SharedRenderer>,
    repaint: bool,
) -> Result<()> {
    if repaint {
        if let Some(renderer) = renderer {
            output.write_all(
                &renderer
                    .terminal
                    .viewport(renderer.physical.0, renderer.physical.1)?,
            )?;
        }
    }
    Ok(())
}

/// Keep the host's canonical screen even when this device's window is larger.
/// Raw VT has implicit right/bottom edges and cannot simply be broadcast into
/// differently sized emulators. A larger window gets a top-left viewport;
/// equal-sized windows retain the direct stream and normal terminal history.
struct SharedRenderer {
    terminal: cherry_vt::Terminal,
    canonical: (u16, u16),
    physical: (u16, u16),
}

impl SharedRenderer {
    fn new(canonical: (u16, u16), physical: (u16, u16), snapshot: &[u8]) -> Result<Self> {
        if !valid_size(canonical.0, canonical.1) {
            bail!("host sent invalid terminal dimensions");
        }
        let mut terminal = cherry_vt::Terminal::new(canonical.0, canonical.1, 1024 * 1024)?;
        let _ = terminal.feed(snapshot);
        Ok(Self {
            terminal,
            canonical,
            physical,
        })
    }

    fn initial(&self, snapshot: &[u8]) -> Result<Vec<u8>> {
        if self.canonical == self.physical {
            Ok(snapshot.to_vec())
        } else {
            self.terminal.viewport(self.physical.0, self.physical.1)
        }
    }

    fn update(&mut self, bytes: &[u8]) -> bool {
        let _ = self.terminal.feed(bytes);
        self.canonical != self.physical
    }

    fn resize_physical(&mut self, size: (u16, u16)) -> Result<Vec<u8>> {
        self.physical = size;
        if self.canonical == self.physical {
            self.terminal.snapshot()
        } else {
            self.terminal.viewport(self.physical.0, self.physical.1)
        }
    }
}

fn input_is_immediately_readable(fd: RawFd) -> bool {
    // Darwin poll rejects regular files and /dev/null even though read works.
    // Files have bytes or EOF available immediately; null is always EOF.
    let mut info = unsafe { std::mem::zeroed::<libc::stat>() };
    if unsafe { libc::fstat(fd, &mut info) } != 0 {
        return false;
    }
    if info.st_mode & libc::S_IFMT == libc::S_IFREG {
        return true;
    }
    if info.st_mode & libc::S_IFMT != libc::S_IFCHR {
        return false;
    }
    let mut null_info = unsafe { std::mem::zeroed::<libc::stat>() };
    unsafe {
        libc::stat(c"/dev/null".as_ptr(), &mut null_info) == 0 && info.st_rdev == null_info.st_rdev
    }
}

/// Recognize only the reserved local key, leaving all other terminal input
/// untouched. The pending prefix is at most one of these short key encodings.
#[derive(Default)]
struct DetachInput {
    pending: Vec<u8>,
    pending_since: Option<Instant>,
}

struct ParsedInput {
    data: Vec<u8>,
    detach: bool,
}

impl DetachInput {
    const ENCODINGS: &'static [&'static [u8]] = &[
        b"\x1b[93;5u",    // Kitty control + right bracket, default press.
        b"\x1b[93;5:1u",  // Kitty with an explicit press event.
        b"\x1b[93;5:2u",  // Kitty repeated press.
        b"\x1b[27;5;93~", // xterm modifyOtherKeys.
    ];

    fn feed(&mut self, bytes: &[u8]) -> ParsedInput {
        let mut data = Vec::new();
        for &byte in bytes {
            if byte == DETACH_KEY {
                data.extend(self.flush_pending());
                return ParsedInput { data, detach: true };
            }
            self.pending.push(byte);
            loop {
                if Self::ENCODINGS.contains(&self.pending.as_slice()) {
                    self.pending.clear();
                    self.pending_since = None;
                    return ParsedInput { data, detach: true };
                }
                if self.pending.is_empty()
                    || Self::ENCODINGS
                        .iter()
                        .any(|encoding| encoding.starts_with(&self.pending))
                {
                    break;
                }
                data.push(self.pending.remove(0));
            }
        }
        self.pending_since = (!self.pending.is_empty()).then(Instant::now);
        ParsedInput {
            data,
            detach: false,
        }
    }

    fn flush_pending(&mut self) -> Vec<u8> {
        self.pending_since = None;
        std::mem::take(&mut self.pending)
    }

    fn remaining_wait(&self) -> Option<Duration> {
        self.pending_since
            .map(|since| DETACH_SEQUENCE_WAIT.saturating_sub(since.elapsed()))
    }
}

fn check_output_offset(expected: &mut u64, received: u64, len: usize) -> Result<()> {
    if received != *expected {
        bail!("session output is out of sequence (expected {}, received {received}); detach and reattach for a fresh screen", *expected);
    }
    *expected = expected
        .checked_add(len as u64)
        .context("session output offset overflow")?;
    Ok(())
}

fn terminal_size() -> (u16, u16) {
    for fd in [libc::STDIN_FILENO, libc::STDOUT_FILENO] {
        let mut size = unsafe { std::mem::zeroed::<libc::winsize>() };
        if unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, &mut size) } == 0
            && size.ws_col > 0
            && size.ws_row > 0
        {
            let cols = size.ws_col.clamp(2, 500);
            let rows = size.ws_row.clamp(1, 200);
            debug_assert!(valid_size(cols, rows));
            return (cols, rows);
        }
    }
    (DEFAULT_COLS, DEFAULT_ROWS)
}

struct RawTerminal {
    fd: RawFd,
    saved: Option<libc::termios>,
}

impl RawTerminal {
    fn enter(fd: RawFd) -> Result<Self> {
        if unsafe { libc::isatty(fd) } != 1 {
            return Ok(Self { fd, saved: None });
        }
        let mut original = unsafe { std::mem::zeroed::<libc::termios>() };
        if unsafe { libc::tcgetattr(fd, &mut original) } != 0 {
            return Err(io::Error::last_os_error()).context("could not read terminal mode");
        }
        let mut raw = original;
        unsafe {
            libc::cfmakeraw(&mut raw);
        }
        if unsafe { libc::tcsetattr(fd, libc::TCSANOW, &raw) } != 0 {
            return Err(io::Error::last_os_error()).context("could not enter raw terminal mode");
        }
        Ok(Self {
            fd,
            saved: Some(original),
        })
    }
}

impl Drop for RawTerminal {
    fn drop(&mut self) {
        if let Some(original) = &self.saved {
            loop {
                if unsafe { libc::tcsetattr(self.fd, libc::TCSANOW, original) } == 0 {
                    break;
                }
                if io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
                    break;
                }
            }
        }
    }
}

struct TerminalOutput {
    fd: RawFd,
    original_flags: i32,
    restore_screen: bool,
}
impl TerminalOutput {
    fn new(fd: RawFd) -> Result<Self> {
        let original_flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if original_flags < 0 {
            return Err(io::Error::last_os_error()).context("could not read terminal output flags");
        }
        set_nonblocking(fd)?;
        Ok(Self {
            fd,
            original_flags,
            restore_screen: unsafe { libc::isatty(fd) } == 1,
        })
    }

    fn write_all(&self, bytes: &[u8]) -> Result<()> {
        write_bytes(self.fd, bytes, RPC_TIMEOUT).context("could not write terminal output")
    }
}

impl Drop for TerminalOutput {
    fn drop(&mut self) {
        if self.restore_screen {
            // Return to normal terminal modes even when the still-running TUI
            // never sent its own teardown. Clear enhanced keys on both screens;
            // these flags can be tracked separately by terminal emulators.
            let reset = concat!(
                "\x18\x1b[?2026l\x1b[0m\x1b[?25h",
                "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1005l",
                "\x1b[?1006l\x1b[?1015l\x1b[?1016l\x1b[?1004l\x1b[?2004l",
                "\x1b[=0u\x1b[>4;0m\x1b[?1049l\x1b[=0u\x1b[>4;0m",
                "\x1b[?1l\x1b>\x1b[?7h\x1b[4l\x1b[0 q"
            );
            // The signal is already being handled by unwinding. Make one bounded
            // cleanup attempt even after it, then restore the inherited flags.
            let _ = write_bytes_with_policy(
                self.fd,
                reset.as_bytes(),
                Duration::from_millis(100),
                false,
            );
        }
        unsafe {
            libc::fcntl(self.fd, libc::F_SETFL, self.original_flags);
        }
    }
}

extern "C" fn handle_signal(signal: libc::c_int) {
    if signal == libc::SIGWINCH {
        RESIZE_PENDING.store(true, Ordering::Relaxed);
    } else {
        TERMINATION_SIGNAL.store(signal, Ordering::Relaxed);
    }
}

struct SignalGuard {
    saved: Vec<(i32, libc::sigaction)>,
}
impl SignalGuard {
    fn install() -> Result<Self> {
        let mut guard = Self { saved: Vec::new() };
        for signal in [
            libc::SIGWINCH,
            libc::SIGINT,
            libc::SIGTERM,
            libc::SIGHUP,
            libc::SIGQUIT,
            libc::SIGPIPE,
        ] {
            let mut action = unsafe { std::mem::zeroed::<libc::sigaction>() };
            let mut previous = unsafe { std::mem::zeroed::<libc::sigaction>() };
            action.sa_sigaction = if signal == libc::SIGPIPE {
                libc::SIG_IGN
            } else {
                handle_signal as *const () as usize
            };
            unsafe {
                libc::sigemptyset(&mut action.sa_mask);
            }
            if unsafe { libc::sigaction(signal, &action, &mut previous) } != 0 {
                return Err(io::Error::last_os_error())
                    .context("could not install terminal signal handler");
            }
            guard.saved.push((signal, previous));
        }
        Ok(guard)
    }
}
impl Drop for SignalGuard {
    fn drop(&mut self) {
        for (signal, previous) in self.saved.iter().rev() {
            unsafe {
                libc::sigaction(*signal, previous, std::ptr::null_mut());
            }
        }
    }
}

fn interrupted() -> Result<()> {
    let signal = TERMINATION_SIGNAL.load(Ordering::Relaxed);
    if signal != 0 {
        bail!("interrupted by signal {signal}; the host session was not terminated");
    }
    Ok(())
}

fn set_nonblocking(fd: RawFd) -> Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error()).context("could not configure host transport");
    }
    Ok(())
}

fn poll(fds: &mut [libc::pollfd], timeout: Duration) -> Result<()> {
    let result = unsafe {
        libc::poll(
            fds.as_mut_ptr(),
            fds.len() as libc::nfds_t,
            timeout.as_millis().min(i32::MAX as u128) as i32,
        )
    };
    if result < 0 && io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
        return Err(io::Error::last_os_error()).context("host transport polling failed");
    }
    for fd in fds {
        if fd.revents & libc::POLLNVAL != 0 {
            bail!("host transport file descriptor closed");
        }
    }
    Ok(())
}

fn write_bytes(fd: RawFd, bytes: &[u8], timeout: Duration) -> Result<()> {
    write_bytes_with_policy(fd, bytes, timeout, true)
}

fn write_bytes_with_policy(
    fd: RawFd,
    mut bytes: &[u8],
    timeout: Duration,
    check_signals: bool,
) -> Result<()> {
    let deadline = Instant::now() + timeout;
    while !bytes.is_empty() {
        if check_signals {
            interrupted()?;
        }
        if Instant::now() >= deadline {
            bail!("output is blocked; write timed out");
        }
        let n = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
        if n > 0 {
            bytes = &bytes[n as usize..];
            continue;
        }
        if n == 0 {
            bail!("output stopped accepting data");
        }
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::Interrupted {
            continue;
        }
        if error.kind() != io::ErrorKind::WouldBlock {
            return Err(error.into());
        }
        let mut fds = [libc::pollfd {
            fd,
            events: libc::POLLOUT,
            revents: 0,
        }];
        poll(
            &mut fds,
            Duration::from_millis(100).min(deadline.saturating_duration_since(Instant::now())),
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ssh_alias_rejects_options_and_shell_syntax() {
        for bad in [
            "",
            "-oProxyCommand=bad",
            "host name",
            "x;sh",
            "$(touch /tmp/x)",
            "x\ny",
            "'host'",
        ] {
            assert!(validate_host(bad).is_err(), "{bad:?}");
        }
        for good in [
            "studio",
            "dev@mac.local",
            "10.0.0.1",
            "[fe80::1%en0]",
            "my-host",
        ] {
            assert!(validate_host(good).is_ok(), "{good:?}");
        }
    }

    #[test]
    fn remote_command_quotes_socket_as_one_shell_argument() {
        assert_eq!(remote_gateway_command(None).unwrap(), "cherry-host gateway");
        let command = remote_gateway_command(Some(Path::new("/tmp/it's $HOME; $(oops)"))).unwrap();
        assert_eq!(
            command,
            "cherry-host gateway --socket '/tmp/it'\\''s $HOME; $(oops)'"
        );
    }

    #[test]
    fn output_offsets_reject_loss_duplicates_and_overflow() {
        let mut offset = 10;
        check_output_offset(&mut offset, 10, 4).unwrap();
        assert_eq!(offset, 14);
        assert!(check_output_offset(&mut offset, 10, 4).is_err());
        assert!(check_output_offset(&mut offset, 20, 4).is_err());
        let mut maximum = u64::MAX;
        assert!(check_output_offset(&mut maximum, u64::MAX, 1).is_err());
    }

    #[test]
    fn decoder_accepts_partial_and_batched_frames() {
        let mut data = Vec::new();
        cherry_protocol::write_frame(&mut data, &ServerMessage::Ok).unwrap();
        let mut decoder = FrameDecoder::default();
        decoder.bytes.extend_from_slice(&data[..2]);
        assert!(decoder.next().unwrap().is_none());
        decoder.bytes.extend_from_slice(&data[2..]);
        decoder.bytes.extend_from_slice(&data);
        assert!(matches!(decoder.next().unwrap(), Some(ServerMessage::Ok)));
        assert!(matches!(decoder.next().unwrap(), Some(ServerMessage::Ok)));
        assert!(decoder.next().unwrap().is_none());
    }

    #[test]
    fn decoder_rejects_oversized_frame_before_allocating_payload() {
        let mut decoder = FrameDecoder {
            bytes: ((MAX_FRAME_BYTES + 1) as u32).to_be_bytes().to_vec(),
            consumed: 0,
        };
        assert!(decoder.next().is_err());
    }

    #[test]
    fn cli_accepts_global_options_and_literal_command_arguments() {
        let cli = Cli::try_parse_from([
            "cherry", "--host", "studio", "new", "--cwd", "/work", "--name", "test", "--json",
            "--", "sh", "-c", "printf x",
        ])
        .unwrap();
        assert_eq!(cli.host.as_deref(), Some("studio"));
        assert!(
            matches!(cli.command, Action::New { command, .. } if command == ["sh", "-c", "printf x"])
        );
        assert!(Cli::try_parse_from(["cherry", "list", "--json", "--host", "studio"]).is_ok());
    }

    #[test]
    fn raw_terminal_restores_real_pty_settings_on_scope_exit() {
        let mut master = -1;
        let mut slave = -1;
        assert_eq!(
            unsafe {
                libc::openpty(
                    &mut master,
                    &mut slave,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                )
            },
            0
        );
        let mut original = unsafe { std::mem::zeroed::<libc::termios>() };
        assert_eq!(unsafe { libc::tcgetattr(slave, &mut original) }, 0);
        {
            let _raw = RawTerminal::enter(slave).unwrap();
            let mut active = unsafe { std::mem::zeroed::<libc::termios>() };
            assert_eq!(unsafe { libc::tcgetattr(slave, &mut active) }, 0);
            assert_eq!(active.c_lflag & (libc::ICANON | libc::ECHO | libc::ISIG), 0);
        }
        let mut restored = unsafe { std::mem::zeroed::<libc::termios>() };
        assert_eq!(unsafe { libc::tcgetattr(slave, &mut restored) }, 0);
        assert_eq!(restored.c_iflag, original.c_iflag);
        assert_eq!(restored.c_oflag, original.c_oflag);
        assert_eq!(restored.c_cflag, original.c_cflag);
        // macOS sets PENDIN itself when returning to canonical input mode.
        assert_eq!(
            restored.c_lflag & !libc::PENDIN,
            original.c_lflag & !libc::PENDIN
        );
        assert_eq!(restored.c_cc, original.c_cc);
        unsafe {
            libc::close(master);
            libc::close(slave);
        }
    }

    #[test]
    fn enhanced_detach_sequences_are_recognized_at_every_read_boundary() {
        for encoding in DetachInput::ENCODINGS {
            for split in 0..=encoding.len() {
                let mut input = DetachInput::default();
                let prefix = input.feed(b"before");
                assert_eq!(prefix.data, b"before");
                let first = input.feed(&encoding[..split]);
                assert!(first.data.is_empty());
                if split == encoding.len() {
                    assert!(first.detach);
                    continue;
                }
                assert!(!first.detach);
                let mut tail = encoding[split..].to_vec();
                tail.extend_from_slice(b"never-sent");
                let second = input.feed(&tail);
                assert!(second.detach, "encoding={encoding:?} split={split}");
                assert!(second.data.is_empty());
                assert!(input.flush_pending().is_empty());
            }
        }
    }

    #[test]
    fn detach_recognizer_preserves_other_keys_text_and_partial_input() {
        let mut input = DetachInput::default();
        let bytes = b"hello\x1b[A\x1b[93;6u\x1b[93;5:3u\x1b[27;2;93~world";
        let parsed = input.feed(bytes);
        assert_eq!(parsed.data, bytes);
        assert!(!parsed.detach);
        assert!(input.feed(b"\x1b[93;").data.is_empty());
        assert_eq!(input.flush_pending(), b"\x1b[93;");
        assert!(input.remaining_wait().is_none());
        assert!(input.feed(b"\x1b").data.is_empty());
        input.pending_since = Some(Instant::now() - DETACH_SEQUENCE_WAIT);
        assert_eq!(input.remaining_wait(), Some(Duration::ZERO));
        assert_eq!(input.flush_pending(), b"\x1b");
        let parsed = input.feed(b"prior\x1dlater");
        assert!(parsed.detach);
        assert_eq!(parsed.data, b"prior");
    }
}
