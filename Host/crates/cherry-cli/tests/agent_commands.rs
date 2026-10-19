//! `cherry`'s agent commands go to Cherry's helper (`CherryMCP cli`) with
//! their arguments unchanged; the session-host commands stay its own.

use std::{os::unix::fs::PermissionsExt, path::Path, process::Command};

/// A stand-in helper that prints the arguments it got, one per line.
fn stand_in(directory: &Path) -> std::path::PathBuf {
    let helper = directory.join("helper");
    std::fs::write(&helper, "#!/bin/sh\nprintf '%s\\n' \"$@\"\nexit 7\n").unwrap();
    let permissions = std::fs::Permissions::from_mode(0o755);
    std::fs::set_permissions(&helper, permissions).unwrap();
    helper
}

fn cherry(helper: Option<&Path>, arguments: &[&str]) -> std::process::Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cherry"));
    command.args(arguments).env_remove("CHERRY_MCP_HELPER");
    if let Some(helper) = helper {
        command.env("CHERRY_MCP_HELPER", helper);
    }
    command.output().unwrap()
}

#[test]
fn agent_commands_run_the_helper_with_their_arguments() {
    let directory = tempfile::tempdir().unwrap();
    let helper = stand_in(directory.path());
    let output = cherry(Some(&helper), &["send", "3F2A", "two words", "-"]);
    assert_eq!(output.status.code(), Some(7));
    let printed = String::from_utf8(output.stdout).unwrap();
    assert_eq!(printed, "cli\nsend\n3F2A\ntwo words\n-\n");

    let output = cherry(Some(&helper), &["restart", "3F2A"]);
    let printed = String::from_utf8(output.stdout).unwrap();
    assert_eq!(printed, "cli\nrestart\n3F2A\n");
}

#[test]
fn an_agent_command_without_a_helper_says_so() {
    let output = cherry(None, &["ls"]);
    assert_eq!(output.status.code(), Some(127));
    let message = String::from_utf8(output.stderr).unwrap();
    assert!(message.contains("ls is an agent command"), "{message}");
    assert!(message.contains("cherry host"), "{message}");
}

#[test]
fn host_commands_never_run_the_helper() {
    let directory = tempfile::tempdir().unwrap();
    let helper = stand_in(directory.path());
    let output = cherry(Some(&helper), &["host", "--help"]);
    assert_eq!(output.status.code(), Some(0));
    let help = String::from_utf8(output.stdout).unwrap();
    assert!(help.contains("Usage: cherry host"), "{help}");
    assert!(help.contains("doctor"), "{help}");

    let output = cherry(Some(&helper), &["list", "--help"]);
    assert_eq!(output.status.code(), Some(0));
    assert!(!String::from_utf8(output.stdout).unwrap().starts_with("cli"));

    let output = cherry(Some(&helper), &[]);
    assert_eq!(output.status.code(), Some(0));
    let overview = String::from_utf8(output.stdout).unwrap();
    assert!(overview.contains("cherry skill show"), "{overview}");
    assert!(overview.contains("host"), "{overview}");
}
