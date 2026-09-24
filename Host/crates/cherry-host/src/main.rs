mod connection;
mod daemon;
mod environment;
mod launch;
mod outbox;
mod paths;
mod processes;
mod session;
mod signals;
mod stream;

use anyhow::Result;
use cherry_protocol::default_socket_path;
use clap::{Parser, Subcommand};
use std::path::PathBuf;

#[derive(Parser)]
#[command(about = "Portable persistent terminal host for Cherry", version)]
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
    /// Relay protocol frames between stdin/stdout and the host (for SSH).
    Gateway {
        /// Fail when no host is running instead of starting one.
        #[arg(long)]
        no_start: bool,
    },
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
        Action::Serve => daemon::serve(&path),
        Action::Gateway { no_start } => launch::gateway(&path, !no_start),
    }
}
