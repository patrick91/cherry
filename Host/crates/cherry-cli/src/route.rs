//! Which part of `cherry` a command line is for (docs/specs/agent-cli.md).
//!
//! `cherry host …` is the session-host plumbing this crate implements. The
//! old top-level names of those commands stay as hidden aliases: `attach`,
//! `control`, `new`, `kill`, `remove`, `shutdown`, `doctor`, `list` and
//! `status` always, and `start` and `restart` only in their host shapes
//! (nothing but global options, and for `restart` its `--if-*` checks),
//! since `cherry start ID` and `cherry restart ID` are agent commands.
//! Every other command line is an agent command, which goes to the Cherry
//! app over its control socket with the arguments after `cherry` unchanged
//! (`agent.rs`): the app parses and runs it.

use std::{
    ffi::{OsStr, OsString},
    path::Path,
};

/// Global options that take a value (`--host mini`, or `--host=mini`).
const VALUE_OPTIONS: &[&str] = &[
    "--host",
    "--socket",
    "--expected-host-id",
    "--ssh-control-path",
    "--remote-host-path",
];
/// `restart`'s own options, which take a value too.
const RESTART_OPTIONS: &[&str] = &["--if-pid", "--if-executable", "--if-build"];
/// Host commands still accepted at the top level, whatever follows them.
const HOST_ALIASES: &[&str] = &[
    "attach", "control", "new", "kill", "remove", "shutdown", "doctor", "list", "status",
];

#[derive(Debug, PartialEq, Eq)]
pub enum Route {
    /// A host command: parse these arguments (the program name first, then
    /// everything but a leading `host`) as before.
    Host(Vec<OsString>),
    /// An agent command: send the arguments after `cherry` to the app.
    Agent(Vec<OsString>),
    /// `cherry`, `cherry --help` or `cherry help`: the overview.
    Overview,
}

/// How a global option takes its value.
enum Global {
    /// `--name=value`.
    WithValue,
    /// `--name value`.
    TakesNext,
}

/// Whether `argument` is `option=value`.
fn has_value(argument: &str, option: &str) -> bool {
    argument
        .strip_prefix(option)
        .is_some_and(|rest| rest.starts_with('='))
}

fn global(argument: &str) -> Option<Global> {
    if VALUE_OPTIONS.contains(&argument) {
        Some(Global::TakesNext)
    } else if VALUE_OPTIONS.iter().any(|o| has_value(argument, o)) {
        Some(Global::WithValue)
    } else {
        None
    }
}

pub fn route(arguments: &[OsString]) -> Route {
    let program = match arguments.first() {
        Some(program) => program.clone(),
        None => OsString::from("cherry"),
    };
    let rest = arguments.get(1..).unwrap_or_default();

    // The first argument that is not a global option (or its value) names
    // the command.
    let mut index = 0;
    let mut command = None;
    while index < rest.len() {
        let Some(argument) = rest[index].to_str() else {
            break;
        };
        match global(argument) {
            Some(Global::TakesNext) => index += 2,
            Some(Global::WithValue) => index += 1,
            None => {
                command = Some(argument);
                break;
            }
        }
    }
    let Some(command) = command else {
        // Only global options (or a word that is not UTF-8): clap says
        // what is missing or wrong, as before.
        if rest.is_empty() {
            return Route::Overview;
        }
        return Route::Host(arguments.to_vec());
    };
    let after = &rest[index + 1..];
    let host_shape = match command {
        "start" => only_host_options(after, &[]),
        "restart" => only_host_options(after, RESTART_OPTIONS),
        "-V" | "--version" => true,
        _ => HOST_ALIASES.contains(&command),
    };
    if matches!(command, "-h" | "--help" | "help") && after.is_empty() {
        return Route::Overview;
    }
    if command == "host" {
        let mut host = vec![host_program(&program)];
        host.extend_from_slice(&rest[..index]);
        host.extend_from_slice(after);
        return Route::Host(host);
    }
    if host_shape {
        return Route::Host(arguments.to_vec());
    }
    Route::Agent(rest.to_vec())
}

/// `cherry host`'s program name, so clap's usage and errors say
/// `cherry host …`.
fn host_program(program: &OsStr) -> OsString {
    let mut name = match Path::new(program).file_name() {
        Some(name) => name.to_os_string(),
        None => OsString::from("cherry"),
    };
    name.push(" host");
    name
}

/// Whether `arguments` hold only global options, help, and `extra` options
/// with their values: the shape of the host's `start` or `restart`.
fn only_host_options(arguments: &[OsString], extra: &[&str]) -> bool {
    let mut index = 0;
    while index < arguments.len() {
        let Some(argument) = arguments[index].to_str() else {
            return false;
        };
        index += match global(argument) {
            Some(Global::TakesNext) => 2,
            Some(Global::WithValue) => 1,
            None if matches!(argument, "-h" | "--help") => 1,
            None if extra.contains(&argument) => 2,
            None if extra.iter().any(|o| has_value(argument, o)) => 1,
            None => return false,
        };
    }
    true
}

/// `cherry`, `cherry --help`: the agent commands and `host`.
pub const OVERVIEW: &str = "\
Cherry from the command line: its tabs, agents, tasks and todos, and its
session host.

Usage: cherry <COMMAND> [ARGS]...

Agent commands (run `cherry skill show` for the full guide):
  ls, show, read, search, wait        list tabs, a tab's status and output
  send, keys, answer                  type into a tab, answer an agent's menu
  spawn, start, stop, restart, close  make and manage tabs
  rename, select
  task                                Cherry tasks (mine, report, progress, get, list, wait, cancel)
  subscribe, events, unsubscribe      monitors
  ports, services, wait-port          localhost services
  todo, note, project, whoami
  skill                               set up, check, show or remove Cherry's agent skill
  tool NAME [JSON | -]                any Cherry tool by its MCP name

Session host:
  host                                persistent sessions: start, list, new, attach, kill,
                                      remove, status, doctor, restart, shutdown, control
                                      (cherry host --help)

Options:
  -h, --help     Print help
  -V, --version  Print version
";

#[cfg(test)]
mod tests {
    use super::*;

    fn words(list: &[&str]) -> Vec<OsString> {
        list.iter().map(OsString::from).collect()
    }

    fn arguments(line: &str) -> Vec<OsString> {
        let mut all = vec![OsString::from("cherry")];
        all.extend(line.split_whitespace().map(OsString::from));
        all
    }

    fn host(line: &str) -> Route {
        Route::Host(arguments(line))
    }

    fn agent(line: &str) -> Route {
        Route::Agent(arguments(line)[1..].to_vec())
    }

    #[test]
    fn host_subcommand_drops_host_and_keeps_globals_anywhere() {
        let cases = [
            ("host list --json", vec!["cherry host", "list", "--json"]),
            (
                "--host mini host kill S",
                vec!["cherry host", "--host", "mini", "kill", "S"],
            ),
            (
                "--socket=/tmp/s host status --json",
                vec!["cherry host", "--socket=/tmp/s", "status", "--json"],
            ),
            (
                "host --host mini attach S",
                vec!["cherry host", "--host", "mini", "attach", "S"],
            ),
        ];
        for (line, expected) in cases {
            assert_eq!(route(&arguments(line)), Route::Host(words(&expected)));
        }
        let absolute = words(&["/x/bin/cherry", "host", "doctor"]);
        let expected = words(&["cherry host", "doctor"]);
        assert_eq!(route(&absolute), Route::Host(expected));
    }

    #[test]
    fn old_host_names_stay_aliases() {
        for line in [
            "attach S --detach-key none",
            "control --no-start",
            "new --cwd ~ -- zsh",
            "kill S",
            "remove S",
            "shutdown",
            "doctor",
            "list --no-start --json",
            "status --json",
            "--host mini list --json",
            "--socket /tmp/s status",
        ] {
            assert_eq!(route(&arguments(line)), host(line), "{line}");
        }
    }

    #[test]
    fn start_and_restart_go_by_shape() {
        for line in [
            "start",
            "--socket /tmp/s start",
            "start --socket /tmp/s",
            "restart",
            "restart --if-pid 12 --if-build b",
            "restart --if-executable=/x/cherry-host",
            "restart --help",
        ] {
            assert_eq!(route(&arguments(line)), host(line), "{line}");
        }
        for line in [
            "start 3F2A",
            "start --name web --kind command",
            "restart 3F2A",
            "restart --if-pid 12 3F2A",
        ] {
            assert_eq!(route(&arguments(line)), agent(line), "{line}");
        }
    }

    #[test]
    fn everything_else_is_an_agent_command() {
        for line in [
            "ls",
            "show",
            "send 3F2A -",
            "task report -",
            "skill show",
            "tool get_status {}",
            "ports",
            "lsit",
            "--host mini ls",
            "help ls",
        ] {
            assert_eq!(route(&arguments(line)), agent(line), "{line}");
        }
    }

    #[test]
    fn overview_and_version() {
        for line in ["", "--help", "-h", "help"] {
            assert_eq!(route(&arguments(line)), Route::Overview, "{line}");
        }
        for line in ["--version", "-V", "--host mini"] {
            assert_eq!(route(&arguments(line)), host(line), "{line}");
        }
    }
}
