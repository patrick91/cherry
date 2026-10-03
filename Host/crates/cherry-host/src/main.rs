mod connection;
mod daemon;
mod environment;
mod holder;
mod launch;
mod link;
mod media;
mod outbox;
mod paths;
mod ports;
mod processes;
mod project_info;
mod report;
mod screen;
mod session;
mod signals;
mod stream;
mod terminal_thread;
mod watch;

use anyhow::Result;
use cherry_protocol::default_socket_path;
use clap::{Parser, Subcommand};
use std::path::PathBuf;

#[derive(Parser)]
#[command(
    about = "Portable persistent terminal host for Cherry",
    version = daemon::version()
)]
struct Args {
    #[arg(long, global = true)]
    socket: Option<PathBuf>,
    #[command(subcommand)]
    command: Action,
}
#[derive(Subcommand)]
enum Action {
    /// Make sure a host serves the socket, starting one if none is running.
    Start,
    /// Run the host in the foreground.
    Serve,
    /// Relay protocol frames between stdin/stdout and the host (for SSH),
    /// starting one if none is running, and replacing one that speaks an
    /// older protocol (its sessions carry on). With CHERRY_EXPECTED_HOST_ID
    /// set, a host of another identity is relayed as it is, for the client
    /// to refuse.
    Gateway {
        /// Fail when no host of this version is running instead of starting
        /// or replacing one.
        #[arg(long)]
        no_start: bool,
    },
    /// Describe this cherry-host: its protocol, build, system and
    /// architecture, and the oldest macOS it runs on.
    Version {
        #[arg(long)]
        json: bool,
    },
    /// Say whether a cherry-host answers at the socket, and its protocol,
    /// build and identity. Only says Hello: never starts, replaces or
    /// changes a host.
    Status {
        #[arg(long)]
        json: bool,
    },
    /// Describe project folders on this machine for a Cherry on another
    /// Mac: whether each exists, its git top level, common directory and
    /// worktrees, and its cherry.toml (at most 256 KiB). Reads only; never
    /// starts or talks to a host.
    ProjectInfo {
        #[arg(long)]
        json: bool,
        /// The folders, absolute (or relative to the current directory).
        #[arg(required = true)]
        paths: Vec<PathBuf>,
    },
    /// The TCP ports the process trees of these pids listen on (a
    /// session's program and what it started), for a Cherry on another Mac
    /// that forwards them. Reads only; never starts or talks to a host.
    Ports {
        #[arg(long)]
        json: bool,
        /// Process ids of this machine (at most 256).
        #[arg(required = true)]
        pids: Vec<i32>,
    },
    /// Hold one session for the daemon (started by the daemon, with its
    /// link on descriptor 3).
    #[command(hide = true)]
    Hold,
}

fn main() {
    if let Err(e) = run() {
        daemon::log(format_args!("{e:#}"));
        std::process::exit(1);
    }
}
fn run() -> Result<()> {
    let args = Args::parse();
    let path = args.socket.unwrap_or_else(default_socket_path);
    match args.command {
        Action::Start => launch::start(&path),
        Action::Serve => {
            daemon::set_log_role(daemon::Role::Daemon);
            daemon::serve(&path)
        }
        Action::Gateway { no_start } => {
            // Set by the CLI (see `cherry_protocol::EXPECTED_HOST_ID_VAR`).
            let expected = std::env::var(cherry_protocol::EXPECTED_HOST_ID_VAR)
                .ok()
                .filter(|id| !id.is_empty());
            launch::gateway(&path, !no_start, expected.as_deref())
        }
        Action::Version { json } => {
            let report = report::version();
            if json {
                println!("{}", serde_json::to_string(&report)?);
            } else {
                println!(
                    "cherry-host {} (build {}), protocol {}, {} {}{}",
                    report.version,
                    report.build,
                    report.protocol,
                    report.os,
                    report.arch,
                    report
                        .min_macos
                        .map(|version| format!(", macOS {version} or later"))
                        .unwrap_or_default()
                );
            }
            Ok(())
        }
        Action::Status { json } => {
            // A socket that cannot be trusted or reached is reported too,
            // so that a client always gets JSON it can read.
            let report = match launch::probe_existing(&path) {
                Ok(probe) => report::status(probe),
                Err(error) => report::status_error(&error),
            };
            if json {
                println!("{}", serde_json::to_string(&report)?);
            } else {
                println!("{}", report::status_line(&report));
            }
            Ok(())
        }
        Action::ProjectInfo { json, paths } => {
            let report = project_info::report(&paths);
            if json {
                println!("{}", serde_json::to_string(&report)?);
            } else {
                for project in &report.projects {
                    let what = match (&project.git, project.is_directory, project.exists) {
                        (Some(git), _, _) => format!("git repository at {}", git.top_level),
                        (None, true, _) => "a folder".to_owned(),
                        (None, false, true) => "not a folder".to_owned(),
                        (None, false, false) => "missing".to_owned(),
                    };
                    let toml = match &project.cherry_toml {
                        Some(toml) if toml.text.is_some() => ", cherry.toml",
                        Some(_) => ", cherry.toml (not sent)",
                        None => "",
                    };
                    println!("{}: {what}{toml}", project.path);
                }
            }
            Ok(())
        }
        Action::Ports { json, pids } => {
            let report = ports::report(&pids);
            if json {
                println!("{}", serde_json::to_string(&report)?);
            } else {
                if let Some(error) = &report.error {
                    println!("the listening sockets could not be read: {error}");
                }
                for process in &report.processes {
                    let ports = process
                        .ports
                        .iter()
                        .map(|listener| format!("{}:{}", listener.host, listener.port))
                        .collect::<Vec<_>>();
                    match (process.alive, ports.is_empty()) {
                        (false, _) => println!("{}: not running", process.pid),
                        (true, true) => println!("{}: no listening ports", process.pid),
                        (true, false) => println!("{}: {}", process.pid, ports.join(", ")),
                    }
                }
            }
            Ok(())
        }
        Action::Hold => {
            daemon::set_log_role(daemon::Role::Holder);
            holder::hold(&path)
        }
    }
}
