mod attach;
mod control;
mod diagnose;
mod guard;
mod handover;
mod input;
mod passthrough;
mod settle;
mod status;
mod stderr_relay;
mod sys;
mod timing;
mod tracker;
mod transport;
mod writer;

use anyhow::{anyhow, bail, Context, Result};
use cherry_protocol::{
    error_code, ClientMessage, ServerMessage, SessionInfo, DEFAULT_COLS, DEFAULT_ROWS,
    MAX_CLIENT_ID_BYTES, MAX_OWNER_BYTES, MAX_TAG_KEY_BYTES, PROTOCOL_VERSION,
};
use clap::{error::ErrorKind, CommandFactory, Parser, Subcommand};
use input::DetachKey;
use status::{Outcome, Status, StatusFile};
use std::{
    cmp::Ordering,
    collections::BTreeMap,
    ffi::OsString,
    io::Write,
    path::{Path, PathBuf},
    process::ExitCode,
    time::{Duration, Instant},
};
use timing::timing;
use transport::{Mode, Target, Transport, RPC_TIMEOUT};

/// Interactive SSH may wait for a password or a host key confirmation.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(120);
/// `--ssh-control-path` is at most this long, so that it fits a Unix socket
/// address (104 bytes on macOS) with room to spare.
const MAX_SSH_CONTROL_PATH_BYTES: usize = 100;
/// The longest `--remote-host-path` accepted.
const MAX_REMOTE_HOST_PATH_BYTES: usize = 1024;

#[derive(Parser, Debug)]
#[command(
    name = "cherry",
    version = cherry_protocol::VERSION,
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
    /// With --host: every ssh this command runs uses the SSH master connection
    /// listening at this ControlPath, or connects directly when none is. An
    /// absolute path of at most 100 bytes.
    #[arg(long, global = true, value_parser = validate_ssh_control_path)]
    ssh_control_path: Option<PathBuf>,
    /// With --host: the cherry-host the remote machine runs, when it is not
    /// on the remote login shell's PATH. An absolute path, or `~/…` for one
    /// under the remote home directory.
    #[arg(long, global = true, value_parser = validate_remote_host_path)]
    remote_host_path: Option<String>,
    #[command(subcommand)]
    command: Action,
}

#[derive(Subcommand, Debug)]
enum Action {
    /// Start the local host daemon. list, new, attach and control also start it
    /// when needed.
    Start,
    /// Stop the host daemon; refused while it owns any running sessions.
    Shutdown,
    /// Restart the local host daemon, whatever sessions run: they carry on
    /// in their holders, and the new daemon (this cherry's cherry-host)
    /// adopts them. For a daemon whose executable an update replaced or
    /// removed.
    Restart {
        /// Only when the running daemon has this pid; otherwise it is left
        /// running and the command fails (exit 4). With the other --if-*
        /// options, a client checks and restarts on one connection, so it
        /// never restarts a daemon that changed since it looked.
        #[arg(long, value_name = "PID")]
        if_pid: Option<u32>,
        /// Only when the running daemon's executable is this file.
        #[arg(long, value_name = "PATH")]
        if_executable: Option<PathBuf>,
        /// Only when the running daemon reports this build.
        #[arg(long, value_name = "BUILD")]
        if_build: Option<String>,
    },
    /// List sessions on the selected host.
    List {
        #[arg(long)]
        json: bool,
        /// Never start a host, nor replace one speaking an older protocol:
        /// when none of this version runs, say so and fail (for a client
        /// that only looks, such as Cherry listing another Mac).
        #[arg(long)]
        no_start: bool,
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
        /// Set a variable in the session's environment; repeatable, the last
        /// value of a name wins. This terminal's locale (LANG, LC_*) and TZ
        /// are passed too, unless a locale variable, or TZ, is set here.
        #[arg(long = "env", value_name = "NAME=VALUE", value_parser = parse_env)]
        env: Vec<(String, String)>,
        /// Who creates the session, such as the app that restores it later.
        /// A value starting with `-` needs the `--owner=VALUE` form, so that
        /// a missing value is an error rather than the next option's name.
        #[arg(long, value_parser = validate_owner)]
        owner: Option<String>,
        /// Metadata kept with the session; repeatable, the last value of a key
        /// wins. A key starting with `-` needs the `--tag=KEY=VALUE` form.
        #[arg(long = "tag", value_name = "KEY=VALUE", value_parser = parse_tag)]
        tags: Vec<(String, String)>,
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
        /// Name this client (1 to 128 bytes; Cherry passes a tab's ID): an
        /// attachment of the session with the same ID, left by an earlier
        /// run or a lost connection, is dropped when this one attaches.
        #[arg(long, value_parser = validate_client_id)]
        client_id: Option<String>,
        /// A file the app that runs this attachment in its window keeps the
        /// window's settled grid in (`{"cols":C,"rows":R}`, or
        /// `{"hold":true}` while its size changes): attach once the terminal
        /// has that grid, and after a hold resize once it has it again, each
        /// within 3 s.
        #[arg(long)]
        size_file: Option<PathBuf>,
    },
    /// Terminate a session on the host.
    Kill { id: String },
    /// Remove an exited session from the host's retained session list.
    Remove { id: String },
    /// Connect to the host and relay protocol frames between standard input
    /// and output until either side closes, for Cherry. Standard output
    /// starts with the host's Welcome; send requests, not Hello.
    Control {
        /// Never start a host, nor replace one speaking an older protocol:
        /// when none of this version runs, say so and fail.
        #[arg(long)]
        no_start: bool,
    },
    /// Describe the host daemon: its pid, uptime, build and protocol, its
    /// socket, state directory and log, its sessions and connections against
    /// their limits, its holders, and the build each session's holder runs.
    /// Never starts a host; exits with status 3 when none is running.
    Status {
        #[arg(long)]
        json: bool,
    },
    /// Check the local host for problems: socket and state permissions,
    /// stale sockets and PID files, a daemon whose executable was moved,
    /// replaced or runs from a disk image, a protocol or build that differs
    /// from this cherry's, the descriptor limit, the log's size, and holders
    /// left without a daemon. Says how to fix each; exits with status 1 when
    /// it found any. Never starts a host.
    Doctor,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Start,
    Query,
    Mutation,
    Attach,
    Control,
}

impl Action {
    fn kind(&self) -> Kind {
        match self {
            Action::Start => Kind::Start,
            Action::List { .. } | Action::Status { .. } | Action::Doctor => Kind::Query,
            Action::Attach { .. } => Kind::Attach,
            Action::Control { .. } => Kind::Control,
            Action::Shutdown
            | Action::Restart { .. }
            | Action::New { .. }
            | Action::Kill { .. }
            | Action::Remove { .. } => Kind::Mutation,
        }
    }

    /// Only commands that need a session start a host, and only they replace
    /// one speaking an older protocol; kill, remove and shutdown report that
    /// none is running (or that it speaks another version) instead.
    fn starts_host(&self) -> bool {
        matches!(
            self,
            Action::List {
                no_start: false,
                ..
            } | Action::New { .. }
                | Action::Attach { .. }
                | Action::Control { no_start: false }
        )
    }
}

impl Cli {
    /// What clap cannot check one value at a time. A failure is a usage
    /// error like clap's own (exit status 2).
    fn validate(self) -> std::result::Result<Self, clap::Error> {
        // Here rather than as a clap requirement, which misses a --host given
        // after the command.
        if self.ssh_control_path.is_some() && self.host.is_none() {
            return Err(Cli::command().error(
                ErrorKind::MissingRequiredArgument,
                "--ssh-control-path needs --host",
            ));
        }
        if self.remote_host_path.is_some() && self.host.is_none() {
            return Err(Cli::command().error(
                ErrorKind::MissingRequiredArgument,
                "--remote-host-path needs --host",
            ));
        }
        if let Action::New { tags, .. } = &self.command {
            let tags: BTreeMap<_, _> = tags.iter().cloned().collect();
            if let Err(message) = cherry_protocol::check_tags(&tags) {
                return Err(Cli::command().error(ErrorKind::ValueValidation, message));
            }
        }
        Ok(self)
    }
}

fn main() -> ExitCode {
    let arguments: Vec<OsString> = std::env::args_os().collect();
    let cli = match Cli::try_parse_from(&arguments).and_then(Cli::validate) {
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
    status.finish(message.as_deref(), final_failure(&result));
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

/// A failure that connecting again can never resolve (see
/// `attach::is_final`); an interruption never is.
fn final_failure(result: &Result<u32>) -> bool {
    result
        .as_ref()
        .err()
        .is_some_and(|error| sys::termination_signal().is_none() && attach::is_final(error))
}

fn interruption_message(kind: Kind, signal: i32) -> String {
    let outcome = match kind {
        Kind::Start => "; cherry-host may still be starting",
        Kind::Query => "",
        Kind::Mutation => {
            "; the request may already have reached the host. Run `cherry list` to check its outcome"
        }
        Kind::Attach => "; the host session was not terminated",
        Kind::Control => "",
    };
    format!("interrupted by signal {signal}{outcome}")
}

/// Write the attachment status before the transport is dropped: stopping ssh
/// can take a moment, and a supervisor may stop waiting for it.
fn run(cli: Cli, status: &mut StatusFile) -> Result<u32> {
    let kind = cli.command.kind();
    let mut transport = None;
    let result = execute(cli, &mut transport, status);
    status.finish(
        failure_message(kind, &result).as_deref(),
        final_failure(&result),
    );
    drop(transport);
    result
}

fn execute(cli: Cli, slot: &mut Option<Transport>, status: &mut StatusFile) -> Result<u32> {
    if let Action::Start = cli.command {
        if cli.host.is_some() {
            bail!("start is local only; list, new, attach and control start the remote host when needed");
        }
        transport::start_local_host(
            &transport::local_socket_path(cli.socket.as_deref())?,
            None,
            false,
        )?;
        return Ok(0);
    }
    if let Action::Doctor = cli.command {
        if cli.host.is_some() {
            bail!("doctor is local only; run it on the remote machine (ssh HOST cherry doctor)");
        }
        return diagnose::doctor(&transport::local_socket_path(cli.socket.as_deref())?);
    }

    // Where to start the next host once this one made way.
    let restart_socket = match cli.command {
        Action::Restart { .. } if cli.host.is_some() => {
            bail!("restart is local only");
        }
        Action::Restart { .. } => {
            // Found and checked before the running host is asked to stop:
            // one that cannot be started would leave no host at all.
            let executable = transport::runnable_host_executable()
                .context("refusing to restart the host; it keeps running")?;
            Some((
                transport::local_socket_path(cli.socket.as_deref())?,
                executable,
            ))
        }
        _ => None,
    };
    if let Action::Attach { id, .. } = &cli.command {
        if std::env::var_os("CHERRY_SESSION_ID").is_some_and(|current| current == id.as_str()) {
            bail!("refusing to attach session {id} from inside itself: its output would feed back into its own input");
        }
    }
    let mode = match cli.command.kind() {
        Kind::Attach => Mode::Attach,
        Kind::Control => Mode::Control,
        _ => Mode::Command,
    };
    // A client using sessions lends its agent to them while connected.
    let links_agent = matches!(
        cli.command,
        Action::New { .. } | Action::Attach { .. } | Action::Control { .. }
    );
    let target = Target {
        host: cli.host.as_deref(),
        socket: cli.socket.as_deref(),
        ssh_control_path: cli.ssh_control_path.as_deref(),
        remote_host_path: cli.remote_host_path.as_deref(),
    };
    // One limit for all of it, replacing a host and connecting again
    // included; an attachment may wait for ssh to prompt instead.
    let deadline = (mode != Mode::Attach).then(|| Instant::now() + timing().connect_timeout);
    let connected = connect(
        slot,
        &target,
        mode,
        cli.command.starts_host(),
        links_agent,
        cli.expected_host_id.map(|id| id.to_string()).as_deref(),
        deadline,
    );
    let Welcomed {
        host_id,
        build: host_build,
    } = match (connected, &cli.command) {
        // No host to describe: `status` says so rather than failing.
        (Err(error), Action::Status { json }) if target.host.is_none() => {
            let socket = transport::local_socket_path(target.socket)?;
            if !diagnose::listening(&socket) {
                return diagnose::not_running(&socket, *json);
            }
            return Err(error);
        }
        (connected, _) => connected?,
    };
    let transport = slot.as_mut().expect("connected");

    match cli.command {
        Action::Start | Action::Doctor => unreachable!(),
        Action::Status { json } => diagnose::status(
            transport,
            &diagnose::Greeting {
                host_id: &host_id,
                build: host_build.as_deref(),
                remote: target.host,
            },
            json,
        ),
        Action::Shutdown => {
            transport.send(&ClientMessage::Shutdown)?;
            expect_ok(transport, "shutdown acknowledgement")
        }
        Action::Restart {
            if_pid,
            if_executable,
            if_build,
        } => {
            if if_pid.is_some() || if_executable.is_some() || if_build.is_some() {
                let condition = RestartCondition {
                    pid: if_pid,
                    executable: if_executable,
                    build: if_build,
                };
                transport.send(&ClientMessage::Status)?;
                let status = match transport.receive(RPC_TIMEOUT)? {
                    ServerMessage::Status { status } => Some(status),
                    ServerMessage::Error { code, .. }
                        if code == cherry_protocol::error_code::UNSUPPORTED_OPERATION =>
                    {
                        None
                    }
                    message => {
                        unexpected("status", message)?;
                        unreachable!()
                    }
                };
                if let Err(why) = condition.check(status.as_ref()) {
                    eprintln!("cherry: not restarting the host, which keeps running: {why}");
                    return Ok(RESTART_CONDITION_UNMET);
                }
            }
            transport.send(&ClientMessage::Restart)?;
            expect_ok(transport, "restart acknowledgement")?;
            *slot = None;
            let (socket, executable) = restart_socket.expect("a restart's socket");
            transport::start_local_host_from(&executable, &socket, None, false)?;
            Ok(0)
        }
        Action::List { json, .. } => {
            transport.send(&ClientMessage::List)?;
            match transport.receive(RPC_TIMEOUT)? {
                ServerMessage::Sessions {
                    host_id,
                    sessions,
                    pending_holders,
                    ..
                } => {
                    let mut text = String::new();
                    if json {
                        text = serde_json::to_string(&ListJson {
                            host_id: &host_id,
                            pending_holders,
                            sessions: &sessions,
                        })?;
                        text.push('\n');
                    } else {
                        for session in sessions {
                            text.push_str(&format!(
                                "{}\t{}\t{}\t{}\n",
                                session.id,
                                session.name,
                                listed_state(&session),
                                session.cwd
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
            env,
            owner,
            tags,
            command,
        } => {
            // A fixed size keeps a retried request identical; the first
            // attachment sets the real size.
            transport.send(&ClientMessage::Create {
                request_id: request_id.unwrap_or_else(uuid::Uuid::new_v4).to_string(),
                name,
                cwd,
                command,
                env: session_environment(std::env::vars_os(), env),
                cols: DEFAULT_COLS,
                rows: DEFAULT_ROWS,
                owner,
                tags: tags.into_iter().collect(),
                colors: None,
                cell_width: None,
                cell_height: None,
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
            client_id,
            size_file,
            ..
        } => {
            // Connecting again finds the same host (the identity it welcomed
            // this attachment with), or gives up at once.
            let mut connect_again = |slot: &mut Option<Transport>, deadline: Instant| {
                connect(
                    slot,
                    &target,
                    Mode::Reattach,
                    true,
                    links_agent,
                    Some(&host_id),
                    Some(deadline),
                )
                .map(drop)
            };
            let mut reconnect = attach::Reconnect {
                connect: &mut connect_again,
                attempt: if target.host.is_some() {
                    timing().reconnect_attempt_ssh
                } else {
                    timing().reconnect_attempt
                },
            };
            let outcome = attach::attach(
                slot,
                &attach::Target {
                    id: &id,
                    takeover,
                    client_id: client_id.as_deref(),
                    size_file: size_file.map(settle::SizeFile::new),
                },
                detach_key,
                status,
                &mut reconnect,
            )?;
            attached(status, outcome)
        }
        Action::Control { .. } => {
            transport.clear_deadline();
            control::relay(transport, host_id, host_build)
        }
    }
}

/// What an attachment's outcome means for the status file and the exit code.
fn attached(status: &mut StatusFile, outcome: attach::Outcome) -> Result<u32> {
    match outcome {
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
        attach::Outcome::Replaced(message) => {
            // The terminal is restored by now.
            eprintln!("cherry: {message}");
            status.set(Status::new(Outcome::Replaced, Some(message)));
            Ok(0)
        }
    }
}

/// `list --json`: the host's identity, how many sessions a host that just
/// restarted still expects back, and the sessions.
#[derive(serde::Serialize)]
struct ListJson<'a> {
    host_id: &'a str,
    pending_holders: u32,
    sessions: &'a [SessionInfo],
}

/// A connection failure that connecting again cannot resolve: another host
/// answers, or one speaking a protocol version this cherry cannot use or
/// replace. An attachment that lost its connection stops reconnecting.
#[derive(Debug)]
pub(crate) struct Unresolvable(pub String);

impl std::fmt::Display for Unresolvable {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for Unresolvable {}

pub(crate) fn unresolvable(message: impl Into<String>) -> anyhow::Error {
    anyhow::Error::new(Unresolvable(message.into()))
}

pub(crate) fn is_unresolvable(error: &anyhow::Error) -> bool {
    error.downcast_ref::<Unresolvable>().is_some()
}

/// Connect and say Hello, returning the host's identity. A command that may
/// start a host (`starts_host`) also replaces one speaking an older
/// protocol: it asks that host to make way (`Replace`), then goes on with the
/// host that connecting again starts. Remotely the gateway (the remote
/// machine's cherry-host) does both itself before it relays anything, as
/// this does locally; should a gateway relay an older host's Welcome, it is
/// answered the same way, and the next gateway starts the new host. A host
/// speaking a newer protocol is reported, never replaced.
///
/// A host that is not `expected_host_id` is neither used nor replaced: its
/// identity is checked before its version. The remote gateway is told the
/// expected identity, and relays such a host untouched for this to refuse.
///
/// Locally, `list`, `new` and `control` (never an attachment) also hand a
/// daemon of this protocol over to a newer build of its own installation
/// (see `handover`): they ask it to make way (`Restart`) and start the new
/// one, once. Its sessions carry on in their holders, which keep their own
/// builds.
///
/// `deadline` limits all of it, replacing a host and connecting again
/// included. Failures that connecting again cannot resolve are
/// `Unresolvable`.
fn connect(
    slot: &mut Option<Transport>,
    target: &Target,
    mode: Mode,
    starts_host: bool,
    links_agent: bool,
    expected_host_id: Option<&str>,
    deadline: Option<Instant>,
) -> Result<Welcomed> {
    let mut replaced = None;
    let mut handing_over: Option<handover::Attempt> = None;
    let made_way = |version: u32| {
        format!(
            "the cherry-host speaking protocol {version} was asked to make way, but no cherry-host speaking protocol {PROTOCOL_VERSION} could be reached"
        )
    };
    // A master connection that refuses the session (it has as many as the
    // server allows) is not used again: this connects directly, once.
    let mut target = *target;
    loop {
        let connected = Transport::connect(
            &target,
            mode,
            starts_host,
            links_agent,
            expected_host_id,
            deadline,
        );
        let transport = match (connected, replaced) {
            (Ok(transport), _) => slot.insert(transport),
            (Err(error), None) => return Err(error),
            (Err(error), Some(version)) => return Err(error.context(made_way(version))),
        };
        let version = match (handshake(transport, expected_host_id, mode), replaced) {
            (Ok(Greeting::Ready { host_id, build }), _) => {
                let hands_over = starts_host
                    && target.host.is_none()
                    && matches!(mode, Mode::Command | Mode::Control);
                if !hands_over {
                    return Ok(Welcomed { host_id, build });
                }
                let socket = transport::local_socket_path(target.socket)?;
                if let Some(attempt) = handing_over.take() {
                    handover::note_outcome(&socket, &attempt, build.as_deref());
                    return Ok(Welcomed { host_id, build });
                }
                let Some((executable, attempt)) =
                    handover::candidate(transport, &socket, build.as_deref())
                else {
                    return Ok(Welcomed { host_id, build });
                };
                if !restart_for_build(transport, &attempt) {
                    // It refused, and keeps serving this connection.
                    return Ok(Welcomed { host_id, build });
                }
                *slot = None;
                transport::start_local_host_from(&executable, &socket, deadline, false)
                    .context("the cherry-host of an older build was asked to make way, but its replacement did not start")?;
                handing_over = Some(attempt);
                continue;
            }
            (Ok(Greeting::Older { version }), _) => version,
            (Err(_), _) if target.ssh_control_path.is_some() && transport.mux_session_refused() => {
                *slot = None;
                target.ssh_control_path = None;
                continue;
            }
            (Err(error), None) => return Err(error),
            (Err(error), Some(previous)) => return Err(error.context(made_way(previous))),
        };
        if let Some(previous) = replaced {
            return Err(unresolvable(format!(
                "the cherry-host speaking protocol {previous} was asked to make way, but the host answering now speaks protocol {version}, not {PROTOCOL_VERSION}; install the cherry-host that comes with this cherry"
            )));
        }
        if !starts_host {
            return Err(unresolvable(format!(
                "protocol version mismatch: cherry-host speaks version {version}, this cherry speaks version {PROTOCOL_VERSION}; this command never replaces a host (list, new, attach and control replace an older one)"
            )));
        }
        replace(transport, version)?;
        replaced = Some(version);
        // The old host is gone; so is this connection (and its ssh).
        *slot = None;
    }
}

/// Who answered a connection: the host's identity and build.
struct Welcomed {
    host_id: String,
    build: Option<String>,
}

/// Ask a daemon of this protocol but an older build to make way
/// (`Restart`). True once it did (its Ok, or the end of the connection when
/// another client asked first); false when it refused and keeps running.
fn restart_for_build(transport: &mut Transport, attempt: &handover::Attempt) -> bool {
    if transport.send(&ClientMessage::Restart).is_err() {
        return true;
    }
    match transport.receive_unless_closed(RPC_TIMEOUT) {
        Ok(Some(ServerMessage::Error { code, message })) => {
            eprintln!(
                "cherry: the cherry-host of build {} did not make way for build {} ({code}: {message}); using it",
                attempt.from, attempt.to
            );
            false
        }
        _ => true,
    }
}

enum Greeting {
    /// The host speaks this protocol.
    Ready {
        host_id: String,
        build: Option<String>,
    },
    /// The host speaks an older protocol; nothing but `Replace` may follow.
    Older { version: u32 },
}

fn handshake(
    transport: &mut Transport,
    expected_host_id: Option<&str>,
    mode: Mode,
) -> Result<Greeting> {
    transport.send(&ClientMessage::hello())?;
    // Other modes' connection deadline bounds this too.
    match transport.receive(if mode == Mode::Attach {
        HANDSHAKE_TIMEOUT
    } else {
        timing().connect_timeout
    })? {
        ServerMessage::Welcome {
            version,
            host_id,
            build,
        } => {
            // Before anything else: a host that is not the intended one is
            // neither used nor replaced.
            if let Some(expected) = expected_host_id {
                if host_id != expected {
                    return Err(unresolvable(format!("host identity changed (expected {expected}, received {host_id}); reconnect to the intended host before using this session")));
                }
            }
            match version.cmp(&PROTOCOL_VERSION) {
                Ordering::Equal => Ok(Greeting::Ready { host_id, build }),
                Ordering::Less => Ok(Greeting::Older { version }),
                Ordering::Greater => Err(unresolvable(format!(
                    "protocol version mismatch: cherry-host speaks version {version}, this cherry speaks version {PROTOCOL_VERSION}; install the same Cherry version on both machines"
                ))),
            }
        }
        // A host older than protocol 4 refuses a Hello of another version
        // outright; it cannot be replaced.
        ServerMessage::Error { code, message } if code == error_code::VERSION_MISMATCH => {
            Err(unresolvable(format!(
                "host rejected request ({code}): {message}; this cherry speaks protocol version {PROTOCOL_VERSION}. Install the same Cherry version on both machines"
            )))
        }
        message => {
            unexpected("welcome", message)?;
            unreachable!()
        }
    }
}

/// Ask a host that welcomed us with an older `version` to make way. On its
/// Ok it no longer listens and has released its lock: a new host may start.
/// A host answers the first Replace and exits, so when several clients ask
/// at once (as an updated app's tabs reconnect), the others may see it end
/// the connection instead; connecting again finds whichever host follows.
/// An Error is a refusal, and the host keeps running.
fn replace(transport: &mut Transport, version: u32) -> Result<()> {
    let context = || {
        format!("could not replace the cherry-host speaking protocol {version} (this cherry speaks protocol {PROTOCOL_VERSION})")
    };
    transport
        .send(&ClientMessage::Replace)
        .with_context(context)?;
    match transport
        .receive_unless_closed(RPC_TIMEOUT)
        .with_context(context)?
    {
        Some(ServerMessage::Ok) | None => Ok(()),
        // A refusal: the host keeps running, and asking again changes nothing.
        Some(message) => Err(unresolvable(format!(
            "{}: {:#}",
            context(),
            unexpected("replace acknowledgement", message).unwrap_err()
        ))),
    }
}

/// Like print!, but a closed stdout is an error rather than a panic.
/// A session's state as `cherry list` prints it: `Running` or `Exited`,
/// and `Exited (the session host crashed)` when its holder was lost rather
/// than its program ending (`SessionInfo::ended_by`).
fn listed_state(session: &SessionInfo) -> String {
    match session.ended_by.as_deref() {
        Some(cherry_protocol::ended_by::HOLDER_LOST) => {
            format!("{:?} (the session host crashed)", session.state)
        }
        _ => format!("{:?}", session.state),
    }
}

pub(crate) fn print(text: &str) -> Result<()> {
    let mut stdout = std::io::stdout().lock();
    stdout
        .write_all(text.as_bytes())
        .and_then(|()| stdout.flush())
        .context("could not write to standard output")
}

/// `restart --if-*` found a daemon other than the one it was told about.
const RESTART_CONDITION_UNMET: u32 = 4;

/// What `restart --if-pid/--if-executable/--if-build` requires of the
/// running daemon, checked on the connection that then asks it to restart.
#[derive(Debug, Default)]
struct RestartCondition {
    pid: Option<u32>,
    executable: Option<PathBuf>,
    build: Option<String>,
}

impl RestartCondition {
    /// Why the daemon (`status`: its `Status`, or None when it does not
    /// answer one) is not the expected one.
    fn check(
        &self,
        status: Option<&cherry_protocol::HostStatus>,
    ) -> std::result::Result<(), String> {
        let Some(status) = status else {
            return Err("it does not report its pid, executable or build".into());
        };
        if let Some(pid) = self.pid {
            if status.pid != pid {
                return Err(format!("its pid is {}, not {pid}", status.pid));
            }
        }
        if let Some(expected) = &self.executable {
            let running = status.executable.as_deref().map(Path::new);
            let same = running.is_some_and(|running| {
                running == expected
                    || matches!(
                        (running.canonicalize(), expected.canonicalize()),
                        (Ok(a), Ok(b)) if a == b
                    )
            });
            if !same {
                return Err(format!(
                    "its executable is {}, not {}",
                    running.map_or("unknown".into(), |path| path.display().to_string()),
                    expected.display()
                ));
            }
        }
        if let Some(build) = &self.build {
            if &status.build != build {
                return Err(format!("its build is {}, not {build}", status.build));
            }
        }
        Ok(())
    }
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

/// The variables given with `--env` (the last value of a name wins), and
/// the locale and time zone of the invoking terminal; everything else comes
/// from the host. A locale variable given explicitly replaces the terminal's
/// locale as a whole, as a client's locale replaces the host's: an inherited
/// LC_ALL would otherwise override the LANG asked for.
fn session_environment(
    variables: impl IntoIterator<Item = (OsString, OsString)>,
    explicit: impl IntoIterator<Item = (String, String)>,
) -> BTreeMap<String, String> {
    let explicit: BTreeMap<String, String> = explicit.into_iter().collect();
    let sets_locale = explicit
        .keys()
        .any(|key| LOCALE_VARIABLES.contains(&key.as_str()));
    let mut environment: BTreeMap<String, String> = variables
        .into_iter()
        .filter_map(|(key, value)| Some((key.into_string().ok()?, value.into_string().ok()?)))
        .filter(|(key, _)| {
            key == "TZ" || (!sets_locale && LOCALE_VARIABLES.contains(&key.as_str()))
        })
        .collect();
    environment.extend(explicit);
    environment
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
        ServerMessage::Resized { .. } => "resized",
        ServerMessage::Output { .. } => "output",
        ServerMessage::Query { .. } => "query",
        ServerMessage::Exit { .. } => "exit",
        ServerMessage::Pong => "pong",
        ServerMessage::Ok => "ok",
        ServerMessage::Error { .. } => "error",
        ServerMessage::Event { .. } => "event",
        ServerMessage::ScreenText { .. } => "screen text",
        ServerMessage::Status { .. } => "status",
    }
}

/// `NAME=VALUE`, where NAME is a portable environment variable name: a
/// letter or underscore, then letters, digits and underscores.
fn parse_env(value: &str) -> std::result::Result<(String, String), String> {
    let (name, value) = value
        .split_once('=')
        .ok_or("expected NAME=VALUE".to_string())?;
    let mut bytes = name.bytes();
    if !bytes
        .next()
        .is_some_and(|first| first.is_ascii_alphabetic() || first == b'_')
        || !bytes.all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
    {
        return Err(format!(
            "invalid variable name {name:?}: use a letter or underscore, then letters, digits or underscores"
        ));
    }
    Ok((name.to_owned(), value.to_owned()))
}

/// `KEY=VALUE`, with a key of 1 to `MAX_TAG_KEY_BYTES` bytes.
fn parse_tag(value: &str) -> std::result::Result<(String, String), String> {
    let (key, value) = value
        .split_once('=')
        .ok_or("expected KEY=VALUE".to_string())?;
    if key.is_empty() || key.len() > MAX_TAG_KEY_BYTES {
        return Err(format!(
            "tag keys must be 1 to {MAX_TAG_KEY_BYTES} bytes long"
        ));
    }
    Ok((key.to_owned(), value.to_owned()))
}

fn validate_client_id(value: &str) -> std::result::Result<String, String> {
    if value.is_empty() || value.len() > MAX_CLIENT_ID_BYTES {
        return Err(format!(
            "a client ID is 1 to {MAX_CLIENT_ID_BYTES} bytes long"
        ));
    }
    Ok(value.to_owned())
}

fn validate_owner(value: &str) -> std::result::Result<String, String> {
    if value.len() > MAX_OWNER_BYTES {
        return Err(format!("the owner is at most {MAX_OWNER_BYTES} bytes long"));
    }
    Ok(value.to_owned())
}

/// An absolute path of at most `MAX_SSH_CONTROL_PATH_BYTES` that ssh reads
/// back unchanged once `%` is doubled: ssh's option parser splits at spaces,
/// removes quotes and backslashes and (before OpenSSH 8.7) stops at `=`, and
/// expands `${NAME}` with no way to escape it.
pub(crate) fn validate_ssh_control_path(value: &str) -> std::result::Result<PathBuf, String> {
    if !value.starts_with('/')
        || value.len() > MAX_SSH_CONTROL_PATH_BYTES
        || value.contains("${")
        || value
            .chars()
            .any(|c| c.is_control() || c.is_whitespace() || "\"'\\=".contains(c))
    {
        return Err(format!(
            "expected an absolute path of at most {MAX_SSH_CONTROL_PATH_BYTES} bytes, without spaces, quotes, backslashes, '=', '${{' or control characters"
        ));
    }
    Ok(PathBuf::from(value))
}

/// The remote cherry-host: an absolute path, or `~/…` under the remote home
/// directory (see `transport::remote_host_word`), of at most
/// `MAX_REMOTE_HOST_PATH_BYTES`, without control characters, backslashes
/// (which fish reads as escapes even inside single quotes) or `!` (which
/// csh and tcsh expand as history even inside single quotes).
pub(crate) fn validate_remote_host_path(value: &str) -> std::result::Result<String, String> {
    let rest = value.strip_prefix("~/").or_else(|| value.strip_prefix('/'));
    if rest.is_none_or(str::is_empty)
        || value.len() > MAX_REMOTE_HOST_PATH_BYTES
        || value
            .chars()
            .any(|c| c.is_control() || c == '\\' || c == '!')
    {
        return Err(format!(
            "expected an absolute path or ~/PATH of at most {MAX_REMOTE_HOST_PATH_BYTES} bytes, without control characters, backslashes or '!'"
        ));
    }
    Ok(value.to_owned())
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

    fn host_status(pid: u32, executable: Option<&str>, build: &str) -> cherry_protocol::HostStatus {
        cherry_protocol::HostStatus {
            host_id: "h".into(),
            version: cherry_protocol::PROTOCOL_VERSION,
            build: build.into(),
            pid,
            started_at: 1,
            uptime_ms: 2,
            socket: "/tmp/x/host.sock".into(),
            state_dir: "/state".into(),
            log_path: None,
            executable: executable.map(Into::into),
            executable_changed: false,
            sessions: 0,
            running_sessions: 0,
            max_sessions: 128,
            connections: 1,
            max_connections: 1024,
            holders_registered: 0,
            holders_expected: 0,
            lost_sessions: 0,
            fd_limit: None,
        }
    }

    #[test]
    fn a_conditional_restart_needs_the_daemon_it_names() {
        let running = host_status(42, Some("/opt/a/cherry-host"), "20260101000000.old");
        let all = RestartCondition {
            pid: Some(42),
            executable: Some("/opt/a/cherry-host".into()),
            build: Some("20260101000000.old".into()),
        };
        assert_eq!(all.check(Some(&running)), Ok(()));
        assert_eq!(RestartCondition::default().check(Some(&running)), Ok(()));
        let pid = RestartCondition {
            pid: Some(43),
            ..Default::default()
        };
        assert_eq!(
            pid.check(Some(&running)),
            Err("its pid is 42, not 43".into())
        );
        let executable = RestartCondition {
            executable: Some("/opt/b/cherry-host".into()),
            ..Default::default()
        };
        assert_eq!(
            executable.check(Some(&running)),
            Err("its executable is /opt/a/cherry-host, not /opt/b/cherry-host".into())
        );
        let unknown = host_status(42, None, "b");
        assert!(executable
            .check(Some(&unknown))
            .unwrap_err()
            .contains("unknown"));
        let build = RestartCondition {
            build: Some("new".into()),
            ..Default::default()
        };
        assert_eq!(
            build.check(Some(&running)),
            Err("its build is 20260101000000.old, not new".into())
        );
        // A host that does not answer Status is never restarted on a condition.
        assert!(all.check(None).is_err());
    }

    #[test]
    fn restart_takes_its_conditions() {
        let cli = Cli::try_parse_from([
            "cherry",
            "restart",
            "--if-pid",
            "7",
            "--if-executable",
            "/x/cherry-host",
            "--if-build",
            "b",
        ])
        .unwrap();
        match cli.command {
            Action::Restart {
                if_pid,
                if_executable,
                if_build,
            } => {
                assert_eq!(if_pid, Some(7));
                assert_eq!(if_executable, Some(PathBuf::from("/x/cherry-host")));
                assert_eq!(if_build.as_deref(), Some("b"));
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn list_says_when_a_session_host_crashed() {
        let session: SessionInfo = serde_json::from_str(
            r#"{"id":"s","name":"n","cwd":"/","command":[],"cols":80,"rows":24,"state":"exited","pid":null,"exit_code":1,"attached":false,"exit_signal":null}"#,
        )
        .unwrap();
        assert_eq!(listed_state(&session), "Exited");
        let lost = SessionInfo {
            ended_by: Some(cherry_protocol::ended_by::HOLDER_LOST.into()),
            ..session
        };
        assert_eq!(listed_state(&lost), "Exited (the session host crashed)");
    }
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
            remote_gateway_command(None, true, None, None).unwrap(),
            "cherry-host gateway"
        );
        assert_eq!(
            remote_gateway_command(None, false, None, None).unwrap(),
            "cherry-host gateway --no-start"
        );
        let socket = Path::new("/tmp/it's $HOME; $(oops)");
        assert_eq!(
            remote_gateway_command(Some(socket), true, None, None).unwrap(),
            "cherry-host gateway --socket '/tmp/it'\\''s $HOME; $(oops)'"
        );
        assert_eq!(
            remote_gateway_command(Some(socket), false, None, None).unwrap(),
            "cherry-host gateway --no-start --socket '/tmp/it'\\''s $HOME; $(oops)'"
        );
    }

    #[test]
    fn remote_command_runs_the_given_cherry_host_as_one_word_every_shell_expands() {
        // Under the remote home: `"$HOME"/'…'`, which sh, bash, zsh and fish
        // expand alike; the rest is quoted, spaces and quotes included.
        assert_eq!(
            remote_gateway_command(None, true, None, Some("~/.cherry/bin/cherry-host")).unwrap(),
            "\"$HOME\"/'.cherry/bin/cherry-host' gateway"
        );
        assert_eq!(
            remote_gateway_command(
                Some(Path::new("/tmp/h.sock")),
                false,
                Some("id"),
                Some("~/Cherry's things/$(x) `y`/cherry-host"),
            )
            .unwrap(),
            "env CHERRY_EXPECTED_HOST_ID='id' \"$HOME\"/'Cherry'\\''s things/$(x) `y`/cherry-host' gateway --no-start --socket '/tmp/h.sock'"
        );
        // Anything else is quoted as it is: a `~` elsewhere is not expanded.
        assert_eq!(
            remote_gateway_command(None, true, None, Some("/opt/cherry host/cherry-host")).unwrap(),
            "'/opt/cherry host/cherry-host' gateway"
        );
        assert!(remote_gateway_command(None, true, None, Some("~/a\\b")).is_err());
        assert!(remote_gateway_command(None, true, None, Some("~/a\0b")).is_err());
        // csh and tcsh expand history (`!`) even inside single quotes.
        assert!(remote_gateway_command(None, true, None, Some("~/a!b")).is_err());
        assert!(remote_gateway_command(None, true, None, Some("/a!!/cherry-host")).is_err());
    }

    #[test]
    fn remote_host_path_words_run_the_same_file_in_sh_bash_zsh_csh_tcsh_and_fish() {
        // Each available shell, with HOME set to a directory with a space
        // and a quote in its name, runs the word as a command.
        let home = tempfile::tempdir().unwrap();
        let home = home.path().join("it's home");
        let directory = home.join("Cherry's bin $(x)");
        std::fs::create_dir_all(&directory).unwrap();
        let program = directory.join("cherry host");
        std::fs::write(&program, "#!/bin/sh\nprintf 'ran %s' \"$1\"\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
        let word = transport::remote_host_word("~/Cherry's bin $(x)/cherry host").unwrap();
        let mut ran = 0;
        for shell in [
            "/bin/sh",
            "/bin/bash",
            "/bin/zsh",
            "/bin/csh",
            "/bin/tcsh",
            "/usr/bin/fish",
            "/opt/homebrew/bin/fish",
            "/usr/local/bin/fish",
        ] {
            if !Path::new(shell).exists() {
                continue;
            }
            let output = std::process::Command::new(shell)
                .args(["-c", &format!("{word} gateway")])
                .env("HOME", &home)
                .output()
                .unwrap();
            assert_eq!(
                String::from_utf8_lossy(&output.stdout),
                "ran gateway",
                "{shell}: {}",
                String::from_utf8_lossy(&output.stderr)
            );
            ran += 1;
        }
        assert!(ran >= 1);
    }

    #[test]
    fn remote_host_path_is_absolute_or_under_home_and_needs_host() {
        for good in [
            "/usr/local/bin/cherry-host",
            "~/.cherry/bin/cherry-host",
            "~/a b/c'd",
        ] {
            assert_eq!(
                validate_remote_host_path(good).as_deref(),
                Ok(good),
                "{good:?}"
            );
        }
        for bad in [
            "",
            "~",
            "~/",
            "/",
            "cherry-host",
            "~user/bin/cherry-host",
            "/a\nb",
            "/a\\b",
            "~/bin!/cherry-host",
        ] {
            assert!(validate_remote_host_path(bad).is_err(), "{bad:?}");
        }
        let error = Cli::try_parse_from(["cherry", "--remote-host-path", "/x/cherry-host", "list"])
            .and_then(Cli::validate)
            .unwrap_err();
        assert!(
            error
                .to_string()
                .contains("--remote-host-path needs --host"),
            "{error}"
        );
        let cli = Cli::try_parse_from([
            "cherry",
            "control",
            "--host",
            "studio",
            "--remote-host-path",
            "~/bin/cherry-host",
        ])
        .and_then(Cli::validate)
        .unwrap();
        assert_eq!(cli.remote_host_path.as_deref(), Some("~/bin/cherry-host"));
    }

    #[test]
    fn remote_command_passes_the_expected_host_identity_in_the_environment() {
        let id = "0f0e8a52-0b5c-4d4b-9f8e-0c1d2e3f4a5b";
        assert_eq!(
            remote_gateway_command(None, true, Some(id), None).unwrap(),
            format!("env CHERRY_EXPECTED_HOST_ID='{id}' cherry-host gateway")
        );
        assert_eq!(
            remote_gateway_command(Some(Path::new("/tmp/h.sock")), false, Some(id), None).unwrap(),
            format!(
                "env CHERRY_EXPECTED_HOST_ID='{id}' cherry-host gateway --no-start --socket '/tmp/h.sock'"
            )
        );
        // Whatever identity a host welcomed an attachment with stays one word.
        assert_eq!(
            remote_gateway_command(None, true, Some("it's $(odd)"), None).unwrap(),
            "env CHERRY_EXPECTED_HOST_ID='it'\\''s $(odd)' cherry-host gateway"
        );
        assert!(remote_gateway_command(None, true, Some("a\0b"), None).is_err());
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
    fn decoder_takes_binary_frames_and_merges_output_that_arrived_together() {
        let output = |offset: u64, data: &[u8]| {
            frame(&ServerMessage::Output {
                offset,
                data: data.to_vec(),
            })
        };
        let stream = [
            output(10, b"ab"),
            output(12, b"cd"),
            output(14, b""),
            output(14, b"ef"),
            // Not contiguous: a message of its own.
            output(30, b"x"),
            frame(&ServerMessage::Query {
                data: b"\x1b[?6n".to_vec(),
            }),
            output(31, b"y"),
            frame(&ServerMessage::Ok),
            output(32, b"z"),
        ]
        .concat();
        let mut decoder = FrameDecoder::with_bytes(&stream, false);
        let mut messages = Vec::new();
        while let Some(message) = decoder.next().unwrap() {
            messages.push(message);
        }
        let output = |offset: u64, data: &[u8]| ServerMessage::Output {
            offset,
            data: data.to_vec(),
        };
        assert_eq!(
            messages,
            [
                output(10, b"abcdef"),
                output(30, b"x"),
                ServerMessage::Query {
                    data: b"\x1b[?6n".to_vec()
                },
                output(31, b"y"),
                ServerMessage::Ok,
                output(32, b"z"),
            ]
        );
        // What has not arrived whole is left for later, split anywhere.
        for split in 1..stream.len() {
            let mut decoder = FrameDecoder::with_bytes(&stream[..split], false);
            let mut got = Vec::new();
            while let Some(message) = decoder.next().unwrap() {
                got.push(message);
            }
            decoder.push(&stream[split..]);
            while let Some(message) = decoder.next().unwrap() {
                got.push(message);
            }
            let bytes = |messages: &[ServerMessage]| -> Vec<u8> {
                messages
                    .iter()
                    .flat_map(|message| match message {
                        ServerMessage::Output { data, .. } => data.clone(),
                        _ => b"|".to_vec(),
                    })
                    .collect()
            };
            assert_eq!(bytes(&got), bytes(&messages), "split at {split}");
        }
    }

    #[test]
    fn decoder_gives_a_big_output_frame_as_it_arrives() {
        let data: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect();
        let stream = [
            frame(&ServerMessage::Output {
                offset: 1000,
                data: data.clone(),
            }),
            frame(&ServerMessage::Query {
                data: b"\x1b[c".to_vec(),
            }),
            frame(&ServerMessage::Output {
                offset: 201_000,
                data: b"after".to_vec(),
            }),
        ]
        .concat();
        let mut decoder = FrameDecoder::with_bytes(&[], false);
        let mut output = Vec::new();
        let mut offset = 1000;
        let mut rest = Vec::new();
        for piece in stream.chunks(16 * 1024 + 7) {
            decoder.push(piece);
            while let Some(message) = decoder.next().unwrap() {
                match message {
                    ServerMessage::Output { offset: at, data } => {
                        // In parts, contiguous, none tiny but the last.
                        assert_eq!(at, offset);
                        offset += data.len() as u64;
                        assert!(data.len() >= 4096 || offset == 201_000 || at == 201_000);
                        if at < 201_000 {
                            output.push(data);
                        } else {
                            rest.push(ServerMessage::Output { offset: at, data });
                        }
                    }
                    other => rest.push(other),
                }
            }
        }
        assert!(output.len() > 1, "not given in parts");
        assert_eq!(output.concat(), data);
        assert_eq!(
            rest,
            [
                ServerMessage::Query {
                    data: b"\x1b[c".to_vec()
                },
                ServerMessage::Output {
                    offset: 201_000,
                    data: b"after".to_vec()
                }
            ]
        );
        // What was not given yet is a whole frame again.
        let mut decoder = FrameDecoder::with_bytes(&stream[..50_000], false);
        let Some(ServerMessage::Output {
            offset,
            data: first,
        }) = decoder.next().unwrap()
        else {
            panic!("no output yet");
        };
        assert_eq!(offset, 1000);
        let mut again = decoder.take_buffered();
        again.extend_from_slice(&stream[50_000..]);
        let mut decoder = FrameDecoder::with_bytes(&again, false);
        let Some(ServerMessage::Output {
            offset,
            data: second,
        }) = decoder.next().unwrap()
        else {
            panic!("not an output frame");
        };
        assert_eq!(offset, 1000 + first.len() as u64);
        assert_eq!([first, second].concat(), data);
    }

    #[test]
    fn decoder_rejects_malformed_binary_frames() {
        for body in [
            &[9u8, 1, 2][..],
            &[cherry_protocol::binary_kind::OUTPUT, 0, 0],
            &[cherry_protocol::binary_kind::INPUT, b'x'],
            &[cherry_protocol::binary_kind::ATTACHED, 0, 0, 0, 9, b'{'],
            b"{\"type\":\"output\",\"offset\":0,\"data\":\"eA==\"}",
        ] {
            let frame = [&(body.len() as u32).to_be_bytes()[..], body].concat();
            let mut decoder = FrameDecoder::with_bytes(&frame, false);
            let error = decoder.next().unwrap_err();
            assert!(
                format!("{error:#}").contains("host sent an invalid frame"),
                "{error:#}"
            );
        }
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
        let tail = [
            format!("{PROTOCOL_VERSION}\n").as_bytes(),
            &frame(&ServerMessage::Ok),
        ]
        .concat();
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
                format!("CHERRY-GATEWAY {PROTOCOL_VERSION}\n").as_bytes(),
                &frame(&ServerMessage::Pong),
            ]
            .concat(),
            true,
        );
        assert!(matches!(decoder.next().unwrap(), Some(ServerMessage::Pong)));
    }

    #[test]
    fn gateway_preamble_errors_name_the_cause() {
        let other = PROTOCOL_VERSION + 1;
        let mut decoder =
            FrameDecoder::with_bytes(format!("CHERRY-GATEWAY {other}\n").as_bytes(), true);
        let error = decoder.next().unwrap_err().to_string();
        assert!(
            error.contains(&format!("version {other}"))
                && error.contains(&format!("version {PROTOCOL_VERSION}")),
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
        let closed = decoder
            .closed_error(transport::SSH_ERRORS_SHOWN)
            .to_string();
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
        assert!(!quiet
            .closed_error(transport::SSH_ERRORS_SHOWN)
            .to_string()
            .contains("printed"));
        let local = FrameDecoder::with_bytes(b"", false);
        assert_eq!(
            local.closed_error("").to_string(),
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
        assert_eq!(timing.connect_timeout, transport::CONNECT_TIMEOUT);
        assert_eq!(timing.quiet_wait, control::QUIET_WAIT);
        assert_eq!(control::QUIET_WAIT, RPC_TIMEOUT);
        assert_eq!(
            timing.heartbeat_interval,
            cherry_protocol::HEARTBEAT_INTERVAL
        );
        assert_eq!(timing.heartbeat_timeout, cherry_protocol::HEARTBEAT_TIMEOUT);
        assert_eq!(timing.escape_wait, input::ESCAPE_WAIT);
        assert_eq!(timing.grid_wait, attach::GRID_WAIT);
        assert_eq!(timing.resize_coalesce, attach::RESIZE_COALESCE);
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
        let cli = Cli::try_parse_from(["cherry", "attach", "S", "--client-id", "tab-7"]).unwrap();
        assert!(matches!(
            cli.command,
            Action::Attach { client_id: Some(id), .. } if id == "tab-7"
        ));
        for bad in [String::new(), "x".repeat(MAX_CLIENT_ID_BYTES + 1)] {
            let error =
                Cli::try_parse_from(["cherry", "attach", "S", "--client-id", &bad]).unwrap_err();
            assert_eq!(error.exit_code(), 2, "{bad:?}");
        }
        let longest = "x".repeat(MAX_CLIENT_ID_BYTES);
        assert!(Cli::try_parse_from(["cherry", "attach", "S", "--client-id", &longest]).is_ok());
        let cli = Cli::try_parse_from(["cherry", "attach", "S", "--size-file", "/tmp/size.json"])
            .unwrap();
        assert!(matches!(
            cli.command,
            Action::Attach { size_file: Some(path), .. } if path == Path::new("/tmp/size.json")
        ));
    }

    fn terminal_environment() -> impl Iterator<Item = (OsString, OsString)> {
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
        .map(|(key, value)| (OsString::from(key), OsString::from(value)))
        .into_iter()
    }

    fn pairs(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
        pairs
            .iter()
            .map(|(key, value)| (key.to_string(), value.to_string()))
            .collect()
    }

    #[test]
    fn sessions_receive_only_locale_and_time_zone() {
        let environment = session_environment(terminal_environment(), []);
        assert_eq!(
            environment.keys().collect::<Vec<_>>(),
            ["LANG", "LC_ALL", "LC_CTYPE", "LC_TIME", "TZ"]
        );
    }

    #[test]
    fn explicit_variables_win_and_an_explicit_locale_replaces_the_terminals() {
        // Anything with a valid name, the last value of a name winning.
        let environment = session_environment(
            terminal_environment(),
            pairs(&[
                ("CHERRY_PROCESS_ID", "1"),
                ("TERM", "xterm-ghostty"),
                ("CHERRY_PROCESS_ID", "2"),
                ("TZ", "UTC"),
                ("EMPTY", ""),
            ]),
        );
        let expected = pairs(&[
            ("CHERRY_PROCESS_ID", "2"),
            ("EMPTY", ""),
            ("LANG", "en_GB.UTF-8"),
            ("LC_ALL", "C"),
            ("LC_CTYPE", "UTF-8"),
            ("LC_TIME", "en_DK.UTF-8"),
            ("TERM", "xterm-ghostty"),
            ("TZ", "UTC"),
        ]);
        assert_eq!(environment.into_iter().collect::<Vec<_>>(), expected);

        // The terminal's LC_ALL would override the LANG asked for.
        let environment = session_environment(
            terminal_environment(),
            pairs(&[("LANG", "it_IT.UTF-8"), ("LC_TERMINAL", "Cherry")]),
        );
        let expected = pairs(&[
            ("LANG", "it_IT.UTF-8"),
            ("LC_TERMINAL", "Cherry"),
            ("TZ", "Europe/Rome"),
        ]);
        assert_eq!(environment.into_iter().collect::<Vec<_>>(), expected);
    }

    #[test]
    fn new_options_parse_repeatedly_and_reject_invalid_names() {
        let cli = Cli::try_parse_from([
            "cherry",
            "new",
            "--cwd=/work",
            "--env",
            "A=1=2",
            "--env=_B9=",
            "--owner=-dev.cherry",
            "--tag",
            "cherry.tab=T",
            "--tag=-odd=",
            "--",
            "sh",
        ])
        .unwrap()
        .validate()
        .unwrap();
        let Action::New {
            env,
            owner,
            tags,
            command,
            ..
        } = cli.command
        else {
            panic!("not new");
        };
        assert_eq!(env, pairs(&[("A", "1=2"), ("_B9", "")]));
        assert_eq!(owner.as_deref(), Some("-dev.cherry"));
        assert_eq!(tags, pairs(&[("cherry.tab", "T"), ("-odd", "")]));
        assert_eq!(command, ["sh"]);

        for bad in ["NOVALUE", "=x", "1A=x", "A-B=x", "A B=x", "É=x"] {
            let error =
                Cli::try_parse_from(["cherry", "new", "--cwd=/", "--env", bad]).unwrap_err();
            assert_eq!(error.exit_code(), 2, "{bad:?}");
        }
        let long_key = format!("{}=v", "k".repeat(MAX_TAG_KEY_BYTES + 1));
        for bad in ["novalue", "=v", long_key.as_str()] {
            let error =
                Cli::try_parse_from(["cherry", "new", "--cwd=/", "--tag", bad]).unwrap_err();
            assert_eq!(error.exit_code(), 2, "{bad:?}");
        }
        // A missing value is an error, never the next option taken as one;
        // a value starting with `-` needs the `--option=value` form.
        for arguments in [
            &["--owner", "--name", "x"][..],
            &["--owner", "-dev.cherry"],
            &["--tag", "--x=1"],
            &["--tag", "-odd=v"],
            &["--env", "--name"],
            &["--owner"],
            &["--tag"],
            &["--env"],
        ] {
            let error = Cli::try_parse_from(["cherry", "new", "--cwd=/"].iter().chain(arguments))
                .unwrap_err();
            assert_eq!(error.exit_code(), 2, "{arguments:?}");
        }
        let max_key = format!("{}=v", "k".repeat(MAX_TAG_KEY_BYTES));
        assert!(Cli::try_parse_from(["cherry", "new", "--cwd=/", "--tag", &max_key]).is_ok());
        let owner = "o".repeat(MAX_OWNER_BYTES);
        assert!(Cli::try_parse_from(["cherry", "new", "--cwd=/", "--owner", &owner]).is_ok());
        let owner = "o".repeat(MAX_OWNER_BYTES + 1);
        let error =
            Cli::try_parse_from(["cherry", "new", "--cwd=/", "--owner", &owner]).unwrap_err();
        assert_eq!(error.exit_code(), 2);

        // The protocol's limits on all tags together are usage errors too.
        let mut arguments = vec!["cherry".to_string(), "new".into(), "--cwd=/".into()];
        arguments.extend((0..=cherry_protocol::MAX_TAGS).map(|n| format!("--tag=k{n}=v")));
        let error = Cli::try_parse_from(&arguments)
            .unwrap()
            .validate()
            .unwrap_err();
        assert_eq!(error.exit_code(), 2);
        assert!(error.to_string().contains("at most"), "{error}");
        // A key given twice counts once.
        let arguments: Vec<String> = ["cherry", "new", "--cwd=/"]
            .into_iter()
            .map(String::from)
            .chain((0..=cherry_protocol::MAX_TAGS).map(|_| "--tag=k=v".to_string()))
            .collect();
        assert!(Cli::try_parse_from(&arguments).unwrap().validate().is_ok());
    }

    #[test]
    fn control_parses_with_global_options_and_takes_no_arguments() {
        let cli = Cli::try_parse_from([
            "cherry",
            "--host",
            "studio",
            "--ssh-control-path",
            "/tmp/cherry-501/%h",
            "--expected-host-id",
            "12345678-1234-4234-8234-123456789abc",
            "control",
        ])
        .unwrap();
        assert!(matches!(cli.command, Action::Control { no_start: false }));
        assert!(cli.command.starts_host());
        let looking =
            Cli::try_parse_from(["cherry", "--host", "studio", "control", "--no-start"]).unwrap();
        assert!(matches!(
            looking.command,
            Action::Control { no_start: true }
        ));
        assert!(!looking.command.starts_host());
        assert_eq!(
            cli.ssh_control_path.as_deref(),
            Some(Path::new("/tmp/cherry-501/%h"))
        );
        assert!(Cli::try_parse_from(["cherry", "control", "--host", "studio"]).is_ok());
        let error = Cli::try_parse_from(["cherry", "control", "extra"]).unwrap_err();
        assert_eq!(error.exit_code(), 2);
    }

    #[test]
    fn ssh_control_path_needs_host_and_a_path_ssh_reads_back_unchanged() {
        let parse = |arguments: &[&str]| {
            Cli::try_parse_from(std::iter::once(&"cherry").chain(arguments)).and_then(Cli::validate)
        };
        for arguments in [
            &["--ssh-control-path", "/tmp/cp", "list"][..],
            &["list", "--ssh-control-path", "/tmp/cp"],
            &["start", "--ssh-control-path", "/tmp/cp"],
        ] {
            let error = parse(arguments).unwrap_err();
            assert_eq!(error.exit_code(), 2, "{arguments:?}");
            assert!(error.to_string().contains("needs --host"), "{error}");
        }
        // Global options go anywhere.
        for arguments in [
            &["--ssh-control-path", "/tmp/cp", "list", "--host", "h"][..],
            &["list", "--host", "h", "--ssh-control-path", "/tmp/cp"],
            &["--host", "h", "control", "--ssh-control-path", "/tmp/cp"],
        ] {
            let cli = parse(arguments).unwrap();
            assert_eq!(cli.host.as_deref(), Some("h"), "{arguments:?}");
            assert_eq!(
                cli.ssh_control_path.as_deref(),
                Some(Path::new("/tmp/cp")),
                "{arguments:?}"
            );
        }
        let longest = format!("/{}", "x".repeat(MAX_SSH_CONTROL_PATH_BYTES - 1));
        let too_long = format!("{longest}x");
        for good in [
            "/tmp/cp",
            "/tmp/cherry-501/%h-%p.%C",
            "/var/folders/x/T/cherry~ssh/ä#1,+@:",
            "/tmp/$HOME",
            longest.as_str(),
        ] {
            assert_eq!(
                validate_ssh_control_path(good).map(PathBuf::into_os_string),
                Ok(OsString::from(good)),
                "{good:?}"
            );
            let cli = Cli::try_parse_from([
                "cherry",
                "--host",
                "studio",
                "--ssh-control-path",
                good,
                "list",
            ]);
            assert!(cli.is_ok(), "{good:?}");
        }
        for bad in [
            "",
            "relative/cp",
            "~/cp",
            too_long.as_str(),
            "/tmp/a b",
            "/tmp/a\tb",
            "/tmp/a\nb",
            "/tmp/a\0b",
            "/tmp/\"cp\"",
            "/tmp/'cp'",
            "/tmp/a\\b",
            "/tmp/a=b",
            "/tmp/${HOME}",
            "/tmp/\u{a0}",
        ] {
            assert!(validate_ssh_control_path(bad).is_err(), "{bad:?}");
        }
        let error = Cli::try_parse_from([
            "cherry",
            "--host",
            "studio",
            "--ssh-control-path",
            "relative",
            "list",
        ])
        .unwrap_err();
        assert_eq!(error.exit_code(), 2);
        // Not UTF-8.
        use std::os::unix::ffi::OsStrExt;
        let error = Cli::try_parse_from([
            OsString::from("cherry"),
            "--host".into(),
            "studio".into(),
            "--ssh-control-path".into(),
            std::ffi::OsStr::from_bytes(b"/tmp/\xff").into(),
            "list".into(),
        ])
        .unwrap_err();
        assert_eq!(error.exit_code(), 2);
    }

    #[test]
    fn ssh_control_path_option_doubles_percent_signs() {
        assert_eq!(
            transport::ssh_control_path_option(Path::new("/tmp/cp")).unwrap(),
            "ControlPath=/tmp/cp"
        );
        assert_eq!(
            transport::ssh_control_path_option(Path::new("/tmp/%h/%%x%")).unwrap(),
            "ControlPath=/tmp/%%h/%%%%x%%"
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
