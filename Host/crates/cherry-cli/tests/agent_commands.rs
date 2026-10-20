//! `cherry`'s agent commands go to the Cherry app over its control socket as
//! one `runCommand` request (with the tab's token on another Mac), and the
//! app's answer is the command's output and exit status; the session-host
//! commands never reach that socket.

use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Write},
    os::unix::{fs::PermissionsExt, net::UnixListener},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{Arc, Mutex},
    thread,
};

/// A stand-in Cherry app: answers each request line with `answer(request)`
/// and keeps the requests.
struct FakeApp {
    _directory: tempfile::TempDir,
    socket: PathBuf,
    requests: Arc<Mutex<Vec<Value>>>,
}

impl FakeApp {
    fn start(answer: impl Fn(&Value, usize) -> Value + Send + 'static) -> FakeApp {
        let directory = tempfile::tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let socket = directory.path().join("control.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let kept = requests.clone();
        thread::spawn(move || {
            for (index, stream) in listener.incoming().enumerate() {
                let Ok(mut stream) = stream else { return };
                let mut line = String::new();
                BufReader::new(&stream).read_line(&mut line).unwrap();
                let request: Value = serde_json::from_str(&line).unwrap();
                let reply = answer(&request, index);
                kept.lock().unwrap().push(request);
                let mut text = reply.to_string();
                text.push('\n');
                let _ = stream.write_all(text.as_bytes());
            }
        });
        FakeApp {
            _directory: directory,
            socket,
            requests,
        }
    }

    fn requests(&self) -> Vec<Value> {
        self.requests.lock().unwrap().clone()
    }
}

fn output(standard_output: &str, standard_error: &str, exit_code: i32) -> Value {
    json!({"result": {"runCommand": {"_0": {
        "standardOutput": standard_output, "standardError": standard_error, "exitCode": exit_code,
    }}}})
}

/// `cherry` with none of this shell's Cherry variables (it may be a Cherry
/// tab, even another Mac's, with a token), talking to `socket`.
fn cherry(socket: Option<&Path>, arguments: &[&str]) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cherry"));
    command.args(arguments).stdin(Stdio::null());
    for (name, _) in std::env::vars_os() {
        if name.to_string_lossy().starts_with("CHERRY_") {
            command.env_remove(name);
        }
    }
    match socket {
        Some(socket) => command.env("CHERRY_CONTROL_SOCKET", socket),
        None => command.env(
            "CHERRY_CONTROL_SOCKET",
            "/nonexistent-cherry-test/control.sock",
        ),
    };
    command
}

fn text(bytes: Vec<u8>) -> String {
    String::from_utf8(bytes).unwrap()
}

fn command_of(request: &Value) -> &Value {
    &request["runCommand"]["_0"]
}

#[test]
fn an_agent_command_is_one_run_command_and_its_answer_is_the_output() {
    let app = FakeApp::start(|_, _| output("ID  NAME\n", "warned\n", 3));
    let id = "3F2A0000-1111-2222-3333-444455556666";
    let result = cherry(Some(&app.socket), &["send", "3F2A", "two words", "--json"])
        .env("CHERRY_PROCESS_ID", id)
        .env("CHERRY_PROJECT_ROOT", "/p")
        .env("CODEX_HOME", "/codex")
        .current_dir("/")
        .output()
        .unwrap();
    assert_eq!(result.status.code(), Some(3));
    assert_eq!(text(result.stdout), "ID  NAME\n");
    assert_eq!(text(result.stderr), "warned\n");

    let requests = app.requests();
    assert_eq!(requests.len(), 1);
    let command = command_of(&requests[0]);
    assert_eq!(
        command["arguments"],
        json!(["send", "3F2A", "two words", "--json"])
    );
    assert_eq!(
        command["context"],
        json!({"callerProcessID": id, "projectRoot": "/p", "workingDirectory": "/", "interface": "cli"})
    );
    assert_eq!(command["standardOutputIsTerminal"], json!(false));
    assert_eq!(command["standardInputIsPiped"], json!(false));
    assert_eq!(command["environment"]["CODEX_HOME"], json!("/codex"));
    assert!(command["cliBuild"]
        .as_str()
        .is_some_and(|build| !build.is_empty()));
    assert!(command.get("standardInput").is_none());
    assert!(requests[0].get("cherryAuth").is_none());

    // `restart ID` is an agent command too, word for word.
    let result = cherry(Some(&app.socket), &["restart", "3F2A"])
        .output()
        .unwrap();
    assert_eq!(result.status.code(), Some(3));
    assert_eq!(
        command_of(&app.requests()[1])["arguments"],
        json!(["restart", "3F2A"])
    );
}

#[test]
fn standard_input_is_sent_once_the_app_asks_for_it() {
    let app = FakeApp::start(
        |request, _| match command_of(request)["standardInput"].as_str() {
            None => json!({"result": {"runCommand": {"_0": {
                "standardOutput": "", "standardError": "", "exitCode": 0, "needsStandardInput": true,
            }}}}),
            Some(text) => output(&format!("got {text}"), "", 0),
        },
    );
    let mut child = cherry(Some(&app.socket), &["task", "report"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"value\":1}\n")
        .unwrap();
    let result = child.wait_with_output().unwrap();
    assert_eq!(result.status.code(), Some(0));
    assert_eq!(text(result.stdout), "got {\"value\":1}\n");
    let requests = app.requests();
    assert_eq!(requests.len(), 2);
    assert_eq!(
        command_of(&requests[0])["standardInputIsPiped"],
        json!(true)
    );
    assert!(command_of(&requests[0]).get("standardInput").is_none());
}

#[test]
fn files_are_read_here_once_the_app_asks_for_them() {
    let directory = tempfile::tempdir().unwrap();
    std::fs::write(
        directory.path().join("schema.json"),
        "{\"type\":\"object\"}",
    )
    .unwrap();
    let app = FakeApp::start(|request, _| match command_of(request).get("files") {
        None => json!({"result": {"runCommand": {"_0": {
            "standardOutput": "", "standardError": "", "exitCode": 0,
            "needsFiles": ["schema.json", "missing.json"],
        }}}}),
        Some(files) => output(&files.to_string(), "", 0),
    });
    let result = cherry(
        Some(&app.socket),
        &["spawn", "agent", "claude", "--schema", "schema.json"],
    )
    .current_dir(directory.path())
    .output()
    .unwrap();
    assert_eq!(result.status.code(), Some(0));
    let files: Value = serde_json::from_str(&text(result.stdout)).unwrap();
    assert_eq!(
        files,
        json!([{"path": "schema.json", "contents": "{\"type\":\"object\"}"}, {"path": "missing.json"}])
    );
}

#[test]
fn an_app_that_asks_again_for_what_it_got_is_an_error() {
    let app = FakeApp::start(|_, _| {
        json!({"result": {"runCommand": {"_0": {
            "standardOutput": "", "standardError": "", "exitCode": 0, "needsStandardInput": true,
        }}}})
    });
    let result = cherry(Some(&app.socket), &["send", "x", "-"])
        .output()
        .unwrap();
    assert_eq!(result.status.code(), Some(1));
    assert!(text(result.stderr).starts_with("unexpected_response: "));
    assert_eq!(app.requests().len(), 2);
}

#[test]
fn a_tab_of_another_mac_sends_its_token() {
    let app = FakeApp::start(|_, _| output("ok\n", "", 0));
    let result = cherry(Some(&app.socket), &["ls"])
        .env("CHERRY_MCP_TOKEN", "abc123")
        .env("CHERRY_PROCESS_ID", "3F2A0000-1111-2222-3333-444455556666")
        .output()
        .unwrap();
    assert_eq!(result.status.code(), Some(0));
    let request = &app.requests()[0];
    assert_eq!(
        request["cherryAuth"],
        json!({"token": "abc123", "processID": "3F2A0000-1111-2222-3333-444455556666"})
    );
    assert_eq!(
        request["request"]["runCommand"]["_0"]["arguments"],
        json!(["ls"])
    );
}

#[test]
fn errors_print_their_code_and_exit_1() {
    let app = FakeApp::start(|_, index| match index {
        0 => json!({"error": {"code": "invalid_request", "message": "The data couldn't be read."}}),
        _ => {
            json!({"error": {"code": "unauthorized", "message": "Cherry refused this Cherry token."}})
        }
    });
    let result = cherry(Some(&app.socket), &["ls"]).output().unwrap();
    assert_eq!(result.status.code(), Some(1));
    assert_eq!(
        text(result.stderr),
        "cherry_outdated: This Cherry app predates cherry's agent commands (control protocol 3); update Cherry.\n"
    );
    let result = cherry(Some(&app.socket), &["ls"]).output().unwrap();
    assert_eq!(result.status.code(), Some(1));
    assert_eq!(
        text(result.stderr),
        "unauthorized: Cherry refused this Cherry token.\n"
    );
}

#[test]
fn without_the_app_an_agent_command_says_so() {
    let result = cherry(None, &["ls"]).output().unwrap();
    assert_eq!(result.status.code(), Some(1));
    let message = text(result.stderr);
    assert!(message.starts_with("cherry_unavailable: Could not connect to Cherry at /nonexistent-cherry-test/control.sock."), "{message}");

    // A device tab's forward that is down is "not reachable".
    let result = cherry(None, &["ls"])
        .env("CHERRY_MCP_TOKEN", "abc")
        .env("CHERRY_PROCESS_ID", "3F2A0000-1111-2222-3333-444455556666")
        .env("CHERRY_CONTROL_MACHINE", "patmini")
        .output()
        .unwrap();
    assert_eq!(result.status.code(), Some(1));
    let message = text(result.stderr);
    assert!(
        message.starts_with(
            "cherry_unreachable: Cherry on patmini is not reachable (its control socket"
        ),
        "{message}"
    );
}

#[test]
fn a_socket_in_a_shared_directory_is_refused() {
    let directory = tempfile::tempdir().unwrap();
    std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o755)).unwrap();
    let socket = directory.path().join("control.sock");
    let _listener = UnixListener::bind(&socket).unwrap();
    let result = cherry(Some(&socket), &["ls"]).output().unwrap();
    assert_eq!(result.status.code(), Some(1));
    let message = text(result.stderr);
    assert!(message.starts_with("socket_not_private: "), "{message}");
    assert!(
        message.contains("must be private (mode 0700, not 755)"),
        "{message}"
    );
}

#[test]
fn host_commands_never_reach_the_app() {
    let app = FakeApp::start(|_, _| output("app\n", "", 0));
    let result = cherry(Some(&app.socket), &["host", "--help"])
        .output()
        .unwrap();
    assert_eq!(result.status.code(), Some(0));
    let help = text(result.stdout);
    assert!(help.contains("Usage: cherry host"), "{help}");
    assert!(help.contains("doctor"), "{help}");

    let result = cherry(Some(&app.socket), &["list", "--help"])
        .output()
        .unwrap();
    assert_eq!(result.status.code(), Some(0));
    assert_ne!(text(result.stdout), "app\n");

    let result = cherry(Some(&app.socket), &[]).output().unwrap();
    assert_eq!(result.status.code(), Some(0));
    let overview = text(result.stdout);
    assert!(overview.contains("cherry skill show"), "{overview}");
    assert!(overview.contains("host"), "{overview}");
    assert!(app.requests().is_empty());
}

/// `cherry skill setup`'s file work: the app asks what some paths are
/// here, then hands the operations to perform here, then prints what it
/// made of their results. Everything supplied is sent again each round.
#[test]
fn skill_files_are_looked_at_and_written_here_as_the_app_asks() {
    let home = tempfile::tempdir().unwrap();
    let claude = home.path().join(".claude");
    std::fs::create_dir(&claude).unwrap();
    let skill = claude.join("skills/cherry");
    let skill_file = skill.join("SKILL.md");
    let claude_path = claude.to_string_lossy().into_owned();
    let skill_path = skill.to_string_lossy().into_owned();
    let skill_file_path = skill_file.to_string_lossy().into_owned();
    let (asked_claude, asked_skill) = (claude_path.clone(), skill_path.clone());
    let (made, written) = (skill_path.clone(), skill_file_path.clone());
    let app = FakeApp::start(move |request, _| {
        let command = command_of(request);
        if command.get("paths").is_none() {
            return json!({"result": {"runCommand": {"_0": {
                "standardOutput": "", "standardError": "", "exitCode": 0,
                "needsPaths": [asked_claude, asked_skill],
            }}}});
        }
        if command.get("operationResults").is_none() {
            return json!({"result": {"runCommand": {"_0": {
                "standardOutput": "", "standardError": "", "exitCode": 0,
                "operations": [
                    {"group": 0, "kind": "createDirectory", "path": made},
                    {"group": 0, "kind": "write", "path": written, "contents": "the skill\n"},
                ],
            }}}});
        }
        output("WHAT  CHANGE\nskill  wrote\n", "", 0)
    });
    let result = cherry(Some(&app.socket), &["skill", "setup"])
        .env("HOME", home.path())
        .output()
        .unwrap();
    assert_eq!(result.status.code(), Some(0), "{}", text(result.stderr));
    assert_eq!(text(result.stdout), "WHAT  CHANGE\nskill  wrote\n");
    assert_eq!(std::fs::read_to_string(&skill_file).unwrap(), "the skill\n");

    let requests = app.requests();
    assert_eq!(requests.len(), 3);
    assert!(command_of(&requests[0]).get("paths").is_none());
    let described = json!([
        {"path": claude_path, "entry": "directory", "target": "directory", "executable": false, "entries": []},
        {"path": skill_path, "entry": "none", "target": "none", "executable": false},
    ]);
    assert_eq!(command_of(&requests[1])["paths"], described);
    assert!(command_of(&requests[1]).get("operationResults").is_none());
    // The last round: the paths as first described, and the results.
    assert_eq!(command_of(&requests[2])["paths"], described);
    assert_eq!(
        command_of(&requests[2])["operationResults"],
        json!([{}, {}])
    );
    assert_eq!(
        command_of(&requests[2])["environment"]["HOME"],
        json!(home.path().to_string_lossy())
    );
}

/// Operations handed again after their results are an error, never a
/// second write.
#[test]
fn operations_handed_twice_are_refused() {
    let home = tempfile::tempdir().unwrap();
    let file = home.path().join("cherry.rules");
    let target = file.to_string_lossy().into_owned();
    let app = FakeApp::start(move |_, _| {
        json!({"result": {"runCommand": {"_0": {
            "standardOutput": "", "standardError": "", "exitCode": 0,
            "operations": [{"group": 0, "kind": "write", "path": target, "contents": "x"}],
        }}}})
    });
    let result = cherry(Some(&app.socket), &["skill", "setup"])
        .output()
        .unwrap();
    assert_eq!(result.status.code(), Some(1));
    assert!(text(result.stderr).starts_with("unexpected_response:"));
    assert_eq!(app.requests().len(), 2);
}
