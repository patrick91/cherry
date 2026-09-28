mod connection;
mod daemon;
mod environment;
mod holder;
mod launch;
mod link;
mod outbox;
mod paths;
mod processes;
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
        Action::Hold => {
            daemon::set_log_role(daemon::Role::Holder);
            holder::hold(&path)
        }
    }
}
