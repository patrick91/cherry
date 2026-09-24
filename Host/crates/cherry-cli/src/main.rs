mod attach;
mod input;
mod passthrough;
mod status;
mod stderr_relay;
mod sys;
mod timing;
mod transport;

use anyhow::{anyhow, bail, Context, Result};
use cherry_protocol::{
    error_code, ClientMessage, ServerMessage, SessionList, DEFAULT_COLS, DEFAULT_ROWS,
    PROTOCOL_VERSION,
};
use clap::{Parser, Subcommand};
use input::DetachKey;
use status::{Outcome, Status, StatusFile};
use std::{
    collections::BTreeMap, ffi::OsString, io::Write, path::PathBuf, process::ExitCode,
    time::Duration,
};
use transport::{Transport, RPC_TIMEOUT};

/// Interactive SSH may wait for a password or a host key confirmation.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(120);

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
    /// Start the local host daemon. list, new and attach also start it when needed.
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
        /// Absolute path, `~` or `~/…` on the host.
        #[arg(long, allow_hyphen_values = true)]
        cwd: String,
        #[arg(long, default_value = "Terminal", allow_hyphen_values = true)]
        name: String,
        /// Reusing this UUID makes retries of session creation idempotent.
        #[arg(long)]
        request_id: Option<uuid::Uuid>,
        /// Program and arguments, after --. Defaults to the host's login shell.
        #[arg(last = true)]
        command: Vec<String>,
    },
    /// Attach to a session. Ctrl-] detaches without stopping it; press it
    /// twice to send Ctrl-] to the session.
    Attach {
        id: String,
        /// Disconnect this session's other clients and take their place.
        #[arg(long)]
        takeover: bool,
        /// Key that detaches, or `none` to forward all input unchanged.
        #[arg(long, value_enum, default_value = "ctrl-]")]
        detach_key: DetachKey,
        /// Write why the attachment ended to this file as JSON.
        #[arg(long)]
        status_file: Option<PathBuf>,
    },
    /// Terminate a session on the host.
    Kill { id: String },
    /// Remove an exited session from the host's retained session list.
    Remove { id: String },
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Start,
    Query,
    Mutation,
    Attach,
}

impl Action {
    fn kind(&self) -> Kind {
        match self {
            Action::Start => Kind::Start,
            Action::List { .. } => Kind::Query,
            Action::Attach { .. } => Kind::Attach,
            Action::Shutdown | Action::New { .. } | Action::Kill { .. } | Action::Remove { .. } => {
                Kind::Mutation
            }
        }
    }
}

fn main() -> ExitCode {
    let arguments: Vec<OsString> = std::env::args_os().collect();
    let cli = match Cli::try_parse_from(&arguments) {
        Ok(cli) => cli,
        Err(error) => {
            if error.use_stderr() {
                status::report_usage_error(&arguments, &error.to_string());
            }
            error.exit();
        }
    };
    let kind = cli.command.kind();
    let mut status = StatusFile::new(match &cli.command {
        Action::Attach { status_file, .. } => status_file.clone(),
        _ => None,
    });
    let result = match sys::SignalGuard::install() {
        Ok(_signals) => run(cli, &mut status),
        Err(error) => Err(error),
    };
    let message = failure_message(kind, &result);
    status.finish(message.as_deref());
    match result {
        Ok(code) => ExitCode::from(code.min(255) as u8),
        Err(_) => {
            eprintln!("cherry: {}", message.unwrap_or_default());
            let signal = sys::termination_signal().unwrap_or(0);
            ExitCode::from(if signal > 0 { (128 + signal) as u8 } else { 1 })
        }
    }
}

fn failure_message(kind: Kind, result: &Result<u32>) -> Option<String> {
    let error = result.as_ref().err()?;
    Some(match sys::termination_signal() {
        Some(signal) => interruption_message(kind, signal),
        None => format!("{error:#}"),
    })
}

fn interruption_message(kind: Kind, signal: i32) -> String {
    let outcome = match kind {
        Kind::Start => "; cherry-host may still be starting",
        Kind::Query => "",
        Kind::Mutation => {
            "; the request may already have reached the host. Run `cherry list` to check its outcome"
        }
        Kind::Attach => "; the host session was not terminated",
    };
    format!("interrupted by signal {signal}{outcome}")
}

/// Write the attachment status before the transport is dropped: stopping ssh
/// can take a moment, and a supervisor may stop waiting for it.
fn run(cli: Cli, status: &mut StatusFile) -> Result<u32> {
    let kind = cli.command.kind();
    let mut transport = None;
    let result = execute(cli, &mut transport, status);
    status.finish(failure_message(kind, &result).as_deref());
    drop(transport);
    result
}

fn execute(cli: Cli, slot: &mut Option<Transport>, status: &mut StatusFile) -> Result<u32> {
    if let Action::Start = cli.command {
        if cli.host.is_some() {
            bail!("start is local only; list, new and attach start the remote host when needed");
        }
        transport::start_local_host(&transport::local_socket_path(cli.socket.as_deref())?)?;
        return Ok(0);
    }
    if let Action::Attach { id, .. } = &cli.command {
        if std::env::var_os("CHERRY_SESSION_ID").is_some_and(|current| current == id.as_str()) {
            bail!("refusing to attach session {id} from inside itself: its output would feed back into its own input");
        }
    }
    let kind = cli.command.kind();
    // Only commands that need a session start a daemon; kill, remove and
    // shutdown report that none is running instead.
    let auto_start =
        matches!(kind, Kind::Query | Kind::Attach) || matches!(cli.command, Action::New { .. });
    let interactive = kind == Kind::Attach;
    let links_agent = interactive || matches!(cli.command, Action::New { .. });
    let transport = slot.insert(Transport::connect(
        cli.host.as_deref(),
        cli.socket.as_deref(),
        interactive,
        auto_start,
        links_agent,
    )?);
    handshake(transport, cli.expected_host_id, interactive)?;

    match cli.command {
        Action::Start => unreachable!(),
        Action::Shutdown => {
            transport.send(&ClientMessage::Shutdown)?;
            expect_ok(transport, "shutdown acknowledgement")
        }
        Action::List { json } => {
            transport.send(&ClientMessage::List)?;
            match transport.receive(RPC_TIMEOUT)? {
                ServerMessage::Sessions { host_id, sessions } => {
                    let mut text = String::new();
                    if json {
                        text = serde_json::to_string(&SessionList { host_id, sessions })?;
                        text.push('\n');
                    } else {
                        for session in sessions {
                            text.push_str(&format!(
                                "{}\t{}\t{:?}\t{}\n",
                                session.id, session.name, session.state, session.cwd
                            ));
                        }
                    }
                    print(&text)?;
                    Ok(0)
                }
                message => {
                    unexpected("session list", message)?;
                    unreachable!()
                }
            }
        }
        Action::New {
            cwd,
            name,
            request_id,
            command,
        } => {
            // A fixed size keeps a retried request identical; the first
            // attachment sets the real size.
            transport.send(&ClientMessage::Create {
                request_id: request_id.unwrap_or_else(uuid::Uuid::new_v4).to_string(),
                name,
                cwd,
                command,
                env: session_environment(std::env::vars_os()),
                cols: DEFAULT_COLS,
                rows: DEFAULT_ROWS,
            })?;
            match transport.receive(RPC_TIMEOUT)? {
                ServerMessage::Created { session } => {
                    print(&format!("{}\n", serde_json::to_string(&session)?))?;
                    Ok(0)
                }
                message => {
                    unexpected("created session", message)?;
                    unreachable!()
                }
            }
        }
        Action::Kill { id } => {
            transport.send(&ClientMessage::Kill { id })?;
            expect_ok(transport, "kill acknowledgement")
        }
        Action::Remove { id } => {
            transport.send(&ClientMessage::Remove { id })?;
            expect_ok(transport, "remove acknowledgement")
        }
        Action::Attach {
            id,
            takeover,
            detach_key,
            ..
        } => match attach::attach(transport, &id, takeover, detach_key, &mut status.attached)? {
            attach::Outcome::Detached => {
                status.set(Status::new(Outcome::Detached, None));
                Ok(0)
            }
            attach::Outcome::DetachedUnconfirmed(message) => {
                // The terminal is restored by now.
                eprintln!("cherry: {message}");
                status.set(Status::new(Outcome::Detached, Some(message)));
                Ok(0)
            }
            attach::Outcome::Exited { code, signal } => {
                status.set(Status::exited(code, signal));
                Ok(code)
            }
            attach::Outcome::TakenOver(message) => {
                status.set(Status::new(Outcome::TakenOver, Some(message.clone())));
                Err(anyhow!(message))
            }
        },
    }
}

fn handshake(
    transport: &mut Transport,
    expected_host_id: Option<uuid::Uuid>,
    interactive: bool,
) -> Result<()> {
    transport.send(&ClientMessage::hello())?;
    match transport.receive(if interactive {
        HANDSHAKE_TIMEOUT
    } else {
        Duration::from_secs(30)
    })? {
        ServerMessage::Welcome { version, host_id } if version == PROTOCOL_VERSION => {
            if let Some(expected) = expected_host_id {
                if host_id != expected.to_string() {
                    bail!("host identity changed (expected {expected}, received {host_id}); reconnect to the intended host before using this session");
                }
            }
            Ok(())
        }
        ServerMessage::Welcome { version, .. } => bail!(
            "protocol version mismatch: cherry-host speaks version {version}, this cherry speaks version {PROTOCOL_VERSION}; install the same Cherry version on both machines"
        ),
        ServerMessage::Error { code, message } if code == error_code::VERSION_MISMATCH => bail!(
            "host rejected request ({code}): {message}; this cherry speaks protocol version {PROTOCOL_VERSION}. Install the same Cherry version on both machines"
        ),
        message => unexpected("welcome", message),
    }
}

/// Like print!, but a closed stdout is an error rather than a panic.
fn print(text: &str) -> Result<()> {
    let mut stdout = std::io::stdout().lock();
    stdout
        .write_all(text.as_bytes())
        .and_then(|()| stdout.flush())
        .context("could not write to standard output")
}

fn expect_ok(transport: &mut Transport, expected: &str) -> Result<u32> {
    match transport.receive(RPC_TIMEOUT)? {
        ServerMessage::Ok => Ok(0),
        message => {
            unexpected(expected, message)?;
            unreachable!()
        }
    }
}

/// Locale categories (POSIX and glibc). Other `LC_` names, such as iTerm2's
/// LC_TERMINAL, describe the invoking terminal rather than the locale.
const LOCALE_VARIABLES: &[&str] = &[
    "LANG",
    "LC_ALL",
    "LC_ADDRESS",
    "LC_COLLATE",
    "LC_CTYPE",
    "LC_IDENTIFICATION",
    "LC_MEASUREMENT",
    "LC_MESSAGES",
    "LC_MONETARY",
    "LC_NAME",
    "LC_NUMERIC",
    "LC_PAPER",
    "LC_TELEPHONE",
    "LC_TIME",
];

/// The locale and time zone of the invoking terminal; everything else comes
/// from the host.
fn session_environment(
    variables: impl IntoIterator<Item = (OsString, OsString)>,
) -> BTreeMap<String, String> {
    variables
        .into_iter()
        .filter_map(|(key, value)| Some((key.into_string().ok()?, value.into_string().ok()?)))
        .filter(|(key, _)| key == "TZ" || LOCALE_VARIABLES.contains(&key.as_str()))
        .collect()
}

pub(crate) fn unexpected(expected: &str, message: ServerMessage) -> Result<()> {
    match message {
        ServerMessage::Error { code, message } => {
            bail!("host rejected request ({code}): {message}")
        }
        other => bail!("expected {expected}, received {}", message_kind(&other)),
    }
}

pub(crate) fn message_kind(message: &ServerMessage) -> &'static str {
    match message {
        ServerMessage::Welcome { .. } => "welcome",
        ServerMessage::Sessions { .. } => "sessions",
        ServerMessage::Created { .. } => "created",
        ServerMessage::Attached { .. } => "attached",
        ServerMessage::Output { .. } => "output",
        ServerMessage::Query { .. } => "query",
        ServerMessage::Exit { .. } => "exit",
        ServerMessage::Pong => "pong",
        ServerMessage::Ok => "ok",
        ServerMessage::Error { .. } => "error",
    }
}

pub(crate) fn validate_host(value: &str) -> std::result::Result<String, String> {
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;
    use transport::{remote_gateway_command, unstable_location, FrameDecoder};

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
        assert_eq!(
            remote_gateway_command(None, true).unwrap(),
            "cherry-host gateway"
        );
        assert_eq!(
            remote_gateway_command(None, false).unwrap(),
            "cherry-host gateway --no-start"
        );
        let socket = Path::new("/tmp/it's $HOME; $(oops)");
        assert_eq!(
            remote_gateway_command(Some(socket), true).unwrap(),
            "cherry-host gateway --socket '/tmp/it'\\''s $HOME; $(oops)'"
        );
        assert_eq!(
            remote_gateway_command(Some(socket), false).unwrap(),
            "cherry-host gateway --no-start --socket '/tmp/it'\\''s $HOME; $(oops)'"
        );
    }

    fn frame(message: &ServerMessage) -> Vec<u8> {
        cherry_protocol::encode_frame(message).unwrap()
    }

    #[test]
    fn decoder_accepts_partial_and_batched_frames() {
        let data = frame(&ServerMessage::Ok);
        let mut decoder = FrameDecoder::with_bytes(&data[..2], false);
        assert!(decoder.next().unwrap().is_none());
        decoder.push(&data[2..]);
        decoder.push(&data);
        assert!(matches!(decoder.next().unwrap(), Some(ServerMessage::Ok)));
        assert!(matches!(decoder.next().unwrap(), Some(ServerMessage::Ok)));
        assert!(decoder.next().unwrap().is_none());
    }

    #[test]
    fn decoder_rejects_oversized_frame_before_allocating_payload() {
        let mut decoder = FrameDecoder::with_bytes(
            &((cherry_protocol::MAX_FRAME_BYTES + 1) as u32).to_be_bytes(),
            false,
        );
        assert!(decoder.next().is_err());
    }

    #[test]
    fn gateway_preamble_skips_shell_output_split_across_reads() {
        let stream = b"Welcome to devbox\r\nlast login: never\nCHERRY-GATEWAY ";
        let tail = [b"3\n".as_slice(), &frame(&ServerMessage::Ok)].concat();
        for split in 0..stream.len() {
            let mut decoder = FrameDecoder::with_bytes(&stream[..split], true);
            assert!(decoder.next().unwrap().is_none());
            decoder.push(&stream[split..]);
            assert!(decoder.next().unwrap().is_none());
            decoder.push(&tail);
            assert!(matches!(decoder.next().unwrap(), Some(ServerMessage::Ok)));
        }
        // Without junk the preamble is the first line.
        let mut decoder = FrameDecoder::with_bytes(
            &[
                b"CHERRY-GATEWAY 3\n".as_slice(),
                &frame(&ServerMessage::Pong),
            ]
            .concat(),
            true,
        );
        assert!(matches!(decoder.next().unwrap(), Some(ServerMessage::Pong)));
    }

    #[test]
    fn gateway_preamble_errors_name_the_cause() {
        let mut decoder = FrameDecoder::with_bytes(b"CHERRY-GATEWAY 4\n", true);
        let error = decoder.next().unwrap_err().to_string();
        assert!(
            error.contains("version 4") && error.contains("version 3"),
            "{error}"
        );

        let mut junk = b"Welcome\n".to_vec();
        junk.resize(70 * 1024, b'x');
        let mut decoder = FrameDecoder::with_bytes(&junk, true);
        let error = decoder.next().unwrap_err().to_string();
        assert!(
            error.contains("non-interactive shell startup files"),
            "{error}"
        );
        assert!(error.contains("\"Welcome\""), "{error}");

        // Without a preamble, frame bytes are never decoded as a length.
        let mut decoder = FrameDecoder::with_bytes(b"Welc", true);
        assert!(decoder.next().unwrap().is_none());
    }

    #[test]
    fn a_missing_gateway_is_blamed_on_the_gateway_and_shell_output_is_a_clue() {
        // Harmless shell output, then the connection closed or went quiet.
        let mut decoder = FrameDecoder::with_bytes(b"Welcome to devbox\nLast login\n", true);
        assert!(decoder.next().unwrap().is_none());
        let closed = decoder.closed_error(true).to_string();
        assert!(
            closed.contains("closed before cherry-host gateway started"),
            "{closed}"
        );
        assert!(
            closed.contains("errors from ssh or cherry-host"),
            "{closed}"
        );
        assert!(
            closed.contains("printed \"Welcome to devbox\" first"),
            "{closed}"
        );
        assert!(!closed.contains("startup files"), "{closed}");
        let timeout = decoder.timeout_error().to_string();
        assert!(timeout.contains("gateway to start"), "{timeout}");
        assert!(timeout.contains("\"Welcome to devbox\""), "{timeout}");
        assert!(timeout.contains("startup files"), "{timeout}");

        let quiet = FrameDecoder::with_bytes(b"", true);
        assert_eq!(
            quiet.timeout_error().to_string(),
            "timed out waiting for cherry-host gateway to start"
        );
        assert!(!quiet.closed_error(true).to_string().contains("printed"));
        let local = FrameDecoder::with_bytes(b"", false);
        assert_eq!(
            local.closed_error(false).to_string(),
            "host connection closed unexpectedly"
        );
        assert_eq!(
            local.timeout_error().to_string(),
            "timed out waiting for host"
        );
    }

    #[test]
    fn attachment_timing_defaults_to_the_protocol() {
        let timing = timing::timing();
        assert_eq!(
            timing.heartbeat_interval,
            cherry_protocol::HEARTBEAT_INTERVAL
        );
        assert_eq!(timing.heartbeat_timeout, cherry_protocol::HEARTBEAT_TIMEOUT);
        assert_eq!(timing.escape_wait, input::ESCAPE_WAIT);
        assert_eq!(timing.grid_wait, attach::GRID_WAIT);
        assert_eq!(timing.detach_wait, attach::DETACH_WAIT);
        assert_eq!(timing.report_wait, attach::REPORT_WAIT);
        assert_eq!(timing.closed_wait, transport::CLOSED_WAIT);
    }

    #[test]
    fn cli_accepts_global_options_and_literal_command_arguments() {
        let cli = Cli::try_parse_from([
            "cherry", "--host", "studio", "new", "--cwd", "/work", "--name", "test", "--", "sh",
            "-c", "printf x",
        ])
        .unwrap();
        assert_eq!(cli.host.as_deref(), Some("studio"));
        assert!(
            matches!(cli.command, Action::New { command, .. } if command == ["sh", "-c", "printf x"])
        );
        assert!(Cli::try_parse_from(["cherry", "list", "--json", "--host", "studio"]).is_ok());
    }

    #[test]
    fn names_and_directories_may_start_with_a_hyphen() {
        for arguments in [
            &["cherry", "new", "--name=-dev", "--cwd=-odd"][..],
            &["cherry", "new", "--name", "-dev", "--cwd=-odd"],
        ] {
            let cli = Cli::try_parse_from(arguments).unwrap();
            assert!(
                matches!(&cli.command, Action::New { name, cwd, .. } if name == "-dev" && cwd == "-odd"),
                "{arguments:?}"
            );
        }
        let cli =
            Cli::try_parse_from(["cherry", "new", "--name=--", "--cwd=~/x", "--", "sh"]).unwrap();
        assert!(
            matches!(&cli.command, Action::New { name, command, .. } if name == "--" && *command == ["sh"])
        );
    }

    #[test]
    fn attach_options_parse_and_reject_unknown_detach_keys() {
        let cli = Cli::try_parse_from([
            "cherry",
            "attach",
            "S",
            "--detach-key",
            "none",
            "--status-file",
            "/tmp/s.json",
        ])
        .unwrap();
        assert!(matches!(
            cli.command,
            Action::Attach {
                detach_key: DetachKey::None,
                status_file: Some(_),
                takeover: false,
                ..
            }
        ));
        let cli = Cli::try_parse_from(["cherry", "attach", "S"]).unwrap();
        assert!(matches!(
            cli.command,
            Action::Attach {
                detach_key: DetachKey::CtrlBracket,
                ..
            }
        ));
        let error =
            Cli::try_parse_from(["cherry", "attach", "S", "--detach-key", "ctrl-a"]).unwrap_err();
        assert_eq!(error.exit_code(), 2);
    }

    #[test]
    fn sessions_receive_only_locale_and_time_zone() {
        let environment = session_environment(
            [
                ("LANG", "en_GB.UTF-8"),
                ("LC_CTYPE", "UTF-8"),
                ("LC_ALL", "C"),
                ("LC_TIME", "en_DK.UTF-8"),
                ("LC_TERMINAL", "iTerm2"),
                ("LC_TERMINAL_VERSION", "3.5.0"),
                ("TZ", "Europe/Rome"),
                ("PATH", "/bin"),
                ("SSH_AUTH_SOCK", "/tmp/agent"),
                ("CHERRY_PROCESS_ID", "7"),
                ("LANGUAGE", "it"),
            ]
            .map(|(key, value)| (OsString::from(key), OsString::from(value))),
        );
        assert_eq!(
            environment.keys().collect::<Vec<_>>(),
            ["LANG", "LC_ALL", "LC_CTYPE", "LC_TIME", "TZ"]
        );
    }

    #[test]
    fn helpers_on_translocated_or_read_only_volumes_are_refused() {
        assert!(unstable_location(Path::new(
            "/private/var/folders/x/AppTranslocation/1234/d/Cherry.app/Contents/MacOS/cherry-host"
        ))
        .is_some());
        let directory = tempfile::tempdir().unwrap();
        assert!(unstable_location(&directory.path().join("cherry-host")).is_none());
        // The sealed macOS system volume is read-only.
        #[cfg(target_os = "macos")]
        assert!(unstable_location(Path::new("/usr/bin/true")).is_some());
    }

    #[test]
    fn interruption_wording_depends_on_the_command() {
        assert_eq!(
            interruption_message(Kind::Query, 15),
            "interrupted by signal 15"
        );
        assert!(interruption_message(Kind::Mutation, 2).contains("may already have reached"));
        assert!(!interruption_message(Kind::Mutation, 2).contains("not terminated"));
        assert!(interruption_message(Kind::Attach, 1).contains("not terminated"));
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
            let _raw = attach::RawTerminal::enter(slave).unwrap();
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
}
