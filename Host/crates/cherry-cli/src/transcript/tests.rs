use super::*;
use serde_json::json;
use std::io::Write;

fn session(pid: u32, cwd: &str) -> SessionInfo {
    serde_json::from_value(json!({
        "id": "s1",
        "name": "agent",
        "cwd": cwd,
        "command": ["/bin/zsh"],
        "cols": 80,
        "rows": 24,
        "state": "running",
        "pid": pid,
        "exit_code": null,
        "attached": false,
        "exit_signal": null,
        "clients": 0,
    }))
    .unwrap()
}

fn process(pid: u32, ppid: u32, started: SystemTime, command: &str) -> Process {
    Process {
        pid,
        ppid,
        started,
        command: command.to_owned(),
    }
}

fn dirs(root: &Path) -> Dirs {
    Dirs {
        claude: root.join("claude"),
        codex: root.join("codex"),
        pi_sessions: root.join("pi/sessions"),
        amp_logs: root.join("amp/logs/threads"),
    }
}

fn write_lines(path: &Path, lines: &[Value]) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .unwrap();
    for line in lines {
        writeln!(file, "{line}").unwrap();
    }
}

fn entries(items: Vec<Item>) -> Vec<Entry> {
    Batch::collect(items, true).entries
}

fn claude_items(lines: &[Value]) -> Vec<Item> {
    let mut items = Vec::new();
    for (offset, line) in lines.iter().enumerate() {
        claude_record(line, offset as u64, &mut items);
    }
    items
}

fn claude_conversation() -> Vec<Value> {
    vec![
        json!({"type": "user", "uuid": "u1", "timestamp": "2026-11-04T10:00:00Z",
               "message": {"role": "user", "content": "Fix the tests<system-reminder>be brief</system-reminder>"}}),
        json!({"type": "user", "uuid": "meta", "isMeta": true,
               "message": {"role": "user", "content": "Caveat: local commands"}}),
        json!({"type": "assistant", "uuid": "a1", "timestamp": "2026-11-04T10:00:01Z",
               "message": {"role": "assistant", "content": [
                   {"type": "thinking", "thinking": "hmm"},
                   {"type": "text", "text": "I'll run them."},
                   {"type": "tool_use", "id": "toolu_1", "name": "Bash",
                    "input": {"command": "swift test --filter Key\necho done", "description": "Run tests"}}]}}),
        json!({"type": "user", "uuid": "u2", "toolUseResult": {},
               "message": {"role": "user", "content": [
                   {"type": "tool_result", "tool_use_id": "toolu_1", "content": "47 tests passed"}]}}),
        json!({"type": "ai-title", "aiTitle": "Fix the key tests"}),
        json!({"type": "assistant", "uuid": "side", "isSidechain": true,
               "message": {"content": [{"type": "text", "text": "a subagent"}]}}),
        json!({"type": "api-request-blob", "message": {"content": [{"type": "text", "text": "request copy"}]}}),
        json!({"type": "system", "uuid": "c1", "subtype": "compact_boundary"}),
        json!({"type": "user", "uuid": "summary", "isCompactSummary": true, "message": {"content": "Summary of before"}}),
        json!({"type": "user", "uuid": "u3",
               "message": {"content": "<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args></command-args>"}}),
        json!({"type": "user", "uuid": "u4", "message": {"content": "<local-command-stdout>Set model to Opus</local-command-stdout>"}}),
        json!({"type": "user", "uuid": "u5", "message": {"content": [{"type": "text", "text": "[Request interrupted by user]"}]}}),
        json!({"type": "user", "uuid": "u6", "message": {"content":
            "<task-notification>\n<task-id>b1</task-id>\n<summary>Monitor event: \"CI\"</summary>\n</task-notification>"}}),
    ]
}

#[test]
fn ps_elapsed_times_and_lines() {
    assert_eq!(parse_etime("00:07"), Some(Duration::from_secs(7)));
    assert_eq!(
        parse_etime("17:57:38"),
        Some(Duration::from_secs(17 * 3600 + 57 * 60 + 38))
    );
    assert_eq!(
        parse_etime("05-07:09:48"),
        Some(Duration::from_secs(5 * 86_400 + 7 * 3600 + 9 * 60 + 48))
    );
    assert_eq!(parse_etime("x"), None);
    let now = SystemTime::now();
    let process = parse_ps_line("  26635 26634 05-07:09:48 claude --resume  abc", now).unwrap();
    assert_eq!((process.pid, process.ppid), (26635, 26634));
    assert_eq!(process.command, "claude --resume abc");
    assert_eq!(
        now.duration_since(process.started).unwrap(),
        Duration::from_secs(457_788)
    );
}

#[test]
fn claude_records_become_the_conversation_a_client_shows() {
    let items = claude_items(&claude_conversation());
    assert!(items.contains(&Item::Title("Fix the key tests".into())));
    assert_eq!(
        entries(items),
        vec![
            Entry::User {
                id: "u1".into(),
                time: Some("2026-11-04T10:00:00Z".into()),
                text: "Fix the tests".into()
            },
            Entry::Assistant {
                id: "a1#1".into(),
                time: Some("2026-11-04T10:00:01Z".into()),
                text: "I'll run them.".into()
            },
            Entry::Tool {
                id: "toolu_1".into(),
                time: Some("2026-11-04T10:00:01Z".into()),
                name: "Bash".into(),
                summary: "swift test --filter Key".into(),
                result: Some("47 tests passed".into()),
                status: ToolStatus::Ok,
            },
            Entry::Note {
                id: "c1".into(),
                time: None,
                text: "Conversation compacted".into()
            },
            Entry::Note {
                id: "u3".into(),
                time: None,
                text: "Ran /model".into()
            },
            Entry::Note {
                id: "u5".into(),
                time: None,
                text: "Interrupted".into()
            },
            Entry::Note {
                id: "u6".into(),
                time: None,
                text: "Monitor event: \"CI\"".into()
            },
        ]
    );
}

#[test]
fn a_long_result_is_cut_and_an_error_says_so() {
    let long = "x".repeat(RESULT_CHARS + 50);
    let items = claude_items(&[
        json!({"type": "assistant", "uuid": "a", "message": {"content": [
            {"type": "tool_use", "id": "t", "name": "Read", "input": {"file_path": "/a/b.swift"}}]}}),
        json!({"type": "user", "uuid": "u", "message": {"content": [
            {"type": "tool_result", "tool_use_id": "t", "is_error": true, "content": [{"type": "text", "text": long}]}]}}),
    ]);
    let Entry::Tool {
        summary,
        result,
        status,
        ..
    } = &entries(items)[0]
    else {
        panic!()
    };
    assert_eq!(summary, "/a/b.swift");
    assert_eq!(*status, ToolStatus::Error);
    let result = result.as_ref().unwrap();
    assert_eq!(result.chars().count(), RESULT_CHARS + 1);
    assert!(result.ends_with('…'));
}

#[test]
fn codex_completed_items_become_entries() {
    let lines = [
        json!({"timestamp": "t0", "type": "session_meta", "payload": {"id": "019a", "cwd": "/work"}}),
        json!({"timestamp": "t1", "type": "event_msg", "payload": {"type": "item_completed", "item": {
            "type": "UserMessage", "id": "m1", "content": [{"type": "text", "text": "Port the printer"}]}}}),
        json!({"timestamp": "t2", "type": "response_item", "payload": {"type": "message", "role": "assistant",
            "content": [{"type": "output_text", "text": "not shown twice"}]}}),
        json!({"timestamp": "t3", "type": "event_msg", "payload": {"type": "item_completed", "item": {
            "type": "CommandExecution", "id": "c1", "command": ["zsh", "-lc", "cargo test"],
            "parsed_cmd": [{"type": "unknown", "cmd": "cargo test"}], "aggregated_output": "error: 1 failed",
            "exit_code": 101, "status": "failed"}}}),
        json!({"timestamp": "t4", "type": "event_msg", "payload": {"type": "item_completed", "item": {
            "type": "FileChange", "id": "f1", "changes": {"/work/src/a.rs": {"type": "update"}}, "status": "completed",
            "stdout": "", "stderr": ""}}}),
        json!({"timestamp": "t5", "type": "event_msg", "payload": {"type": "item_completed", "item": {
            "type": "AgentMessage", "id": "m2", "content": [{"type": "text", "text": "Fixed it."}]}}}),
        json!({"timestamp": "t6", "type": "event_msg", "payload": {"type": "item_completed", "item": {
            "type": "Reasoning", "id": "r1", "summary_text": ["thinking"]}}}),
        json!({"timestamp": "t7", "type": "event_msg", "payload": {"type": "item_completed", "item": {
            "type": "ContextCompaction", "id": "k1"}}}),
    ];
    let mut items = Vec::new();
    for (offset, line) in lines.iter().enumerate() {
        codex_record(line, offset as u64, &mut items);
    }
    assert_eq!(
        entries(items),
        vec![
            Entry::User {
                id: "m1".into(),
                time: Some("t1".into()),
                text: "Port the printer".into()
            },
            Entry::Tool {
                id: "c1".into(),
                time: Some("t3".into()),
                name: "Shell".into(),
                summary: "cargo test".into(),
                result: Some("error: 1 failed".into()),
                status: ToolStatus::Error,
            },
            Entry::Tool {
                id: "f1".into(),
                time: Some("t4".into()),
                name: "Edit".into(),
                summary: "a.rs".into(),
                result: None,
                status: ToolStatus::Ok,
            },
            Entry::Assistant {
                id: "m2".into(),
                time: Some("t5".into()),
                text: "Fixed it.".into()
            },
            Entry::Note {
                id: "k1".into(),
                time: Some("t7".into()),
                text: "Conversation compacted".into()
            },
        ]
    );
}

#[test]
fn pi_messages_become_entries() {
    let lines = [
        json!({"type": "session", "version": 3, "id": "p-1", "cwd": "/work"}),
        json!({"type": "message", "id": "a", "timestamp": "t1", "message": {"role": "system", "content": "prompt"}}),
        json!({"type": "message", "id": "b", "timestamp": "t2", "message": {"role": "user", "content": "Tidy the notes"}}),
        json!({"type": "message", "id": "c", "timestamp": "t3", "message": {"role": "assistant", "content": [
            {"type": "thinking", "thinking": "…"},
            {"type": "toolCall", "id": "call_1", "name": "bash", "arguments": {"command": "ls notes"}}]}}),
        json!({"type": "message", "id": "d", "timestamp": "t4", "message": {"role": "toolResult", "toolCallId": "call_1",
            "toolName": "bash", "content": [{"type": "text", "text": "a.md\nb.md"}], "isError": false}}),
        json!({"type": "message", "id": "e", "timestamp": "t5", "message": {"role": "assistant", "content": [
            {"type": "text", "text": "Tidied 12 notes"}]}}),
        json!({"type": "session_info", "id": "f", "name": "Notes cleanup"}),
        json!({"type": "message", "id": "g", "timestamp": "t6", "message": {"role": "bashExecution",
            "command": "git status", "output": "clean", "exitCode": 0}}),
    ];
    let mut items = Vec::new();
    for (offset, line) in lines.iter().enumerate() {
        pi_record(line, offset as u64, &mut items);
    }
    assert!(items.contains(&Item::Title("Notes cleanup".into())));
    assert_eq!(
        entries(items),
        vec![
            Entry::User {
                id: "b".into(),
                time: Some("t2".into()),
                text: "Tidy the notes".into()
            },
            Entry::Tool {
                id: "call_1".into(),
                time: Some("t3".into()),
                name: "bash".into(),
                summary: "ls notes".into(),
                result: Some("a.md\nb.md".into()),
                status: ToolStatus::Ok,
            },
            Entry::Assistant {
                id: "e".into(),
                time: Some("t5".into()),
                text: "Tidied 12 notes".into()
            },
            Entry::Tool {
                id: "g".into(),
                time: Some("t6".into()),
                name: "Shell".into(),
                summary: "git status".into(),
                result: Some("clean".into()),
                status: ToolStatus::Ok,
            },
        ]
    );
}

#[test]
fn amp_messages_become_entries() {
    let messages = [
        json!({"role": "user", "messageId": 0, "content": [{"type": "text", "text": "Read the docs"}]}),
        json!({"role": "assistant", "messageId": 1, "state": {"type": "complete"}, "content": [
            {"type": "thinking", "thinking": ""},
            {"type": "text", "text": "Reading."},
            {"type": "tool_use", "id": "toolu_a", "name": "read_web_page", "input": {"url": "https://x.dev", "objective": "API"}}]}),
        json!({"role": "user", "messageId": 2, "content": [
            {"type": "tool_result", "toolUseID": "toolu_a", "run": {"status": "done", "result": "# Docs"}}]}),
    ];
    let mut items = Vec::new();
    for (index, message) in messages.iter().enumerate() {
        amp_message(message, index, &mut items);
    }
    assert_eq!(
        entries(items),
        vec![
            Entry::User {
                id: "m0".into(),
                time: None,
                text: "Read the docs".into()
            },
            Entry::Assistant {
                id: "m1#1".into(),
                time: None,
                text: "Reading.".into()
            },
            Entry::Tool {
                id: "toolu_a".into(),
                time: None,
                name: "read_web_page".into(),
                summary: "https://x.dev".into(),
                result: Some("# Docs".into()),
                status: ToolStatus::Ok,
            },
        ]
    );
    assert_eq!(iso_time(1_793_816_143_921), "2026-11-04T18:15:43.921Z");
}

fn located(agent: Agent, path: PathBuf) -> Located {
    Located {
        agent,
        session_id: Some("abc".into()),
        path: Some(path),
        amp: None,
    }
}

#[test]
fn a_read_returns_the_latest_entries_and_its_cursor_only_what_follows() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("abc.jsonl");
    let mut lines = Vec::new();
    for index in 0..10 {
        lines.push(json!({"type": "user", "uuid": format!("u{index}"), "message": {"content": format!("prompt {index}")}}));
    }
    write_lines(&path, &lines);

    let first = read(located(Agent::Claude, path.clone()), None, 3).unwrap();
    assert!(first.reset);
    assert!(first.more_before);
    let ids: Vec<_> = first.entries.iter().map(entry_id).collect();
    assert_eq!(ids, ["u7", "u8", "u9"]);

    // A tool call, its result, and a line still being written.
    write_lines(
        &path,
        &[
            json!({"type": "assistant", "uuid": "a1", "message": {"content": [
            {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ls"}}]}}),
        ],
    );
    let second = read(
        located(Agent::Claude, path.clone()),
        Some(&first.cursor),
        50,
    )
    .unwrap();
    assert!(!second.reset);
    assert_eq!(second.entries.len(), 1);
    assert!(matches!(
        &second.entries[0],
        Entry::Tool {
            status: ToolStatus::Running,
            ..
        }
    ));

    let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
    writeln!(
        file,
        "{}",
        json!({"type": "user", "uuid": "u10", "message": {"content": [
        {"type": "tool_result", "tool_use_id": "t1", "content": "a b"}]}})
    )
    .unwrap();
    write!(file, "{{\"type\": \"user\", \"uuid\": \"u11\", \"mess").unwrap();
    drop(file);
    let third = read(
        located(Agent::Claude, path.clone()),
        Some(&second.cursor),
        50,
    )
    .unwrap();
    assert_eq!(
        third.entries,
        vec![Entry::ToolResult {
            id: "t1".into(),
            result: "a b".into(),
            status: ToolStatus::Ok
        }]
    );

    // The rest of the line arrives: it is read from its start.
    let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
    writeln!(file, "age\": {{\"content\": \"later\"}}}}").unwrap();
    drop(file);
    let fourth = read(
        located(Agent::Claude, path.clone()),
        Some(&third.cursor),
        50,
    )
    .unwrap();
    assert_eq!(
        fourth.entries.iter().map(entry_id).collect::<Vec<_>>(),
        ["u11"]
    );

    // Another file (a new session) reads again from the end.
    let other = directory.path().join("def.jsonl");
    write_lines(
        &other,
        &[json!({"type": "user", "uuid": "x", "message": {"content": "hi"}})],
    );
    let fifth = read(located(Agent::Claude, other), Some(&fourth.cursor), 50).unwrap();
    assert!(fifth.reset);
    assert_eq!(
        fifth.entries.iter().map(entry_id).collect::<Vec<_>>(),
        ["x"]
    );
}

fn entry_id(entry: &Entry) -> &str {
    match entry {
        Entry::User { id, .. }
        | Entry::Assistant { id, .. }
        | Entry::Tool { id, .. }
        | Entry::ToolResult { id, .. }
        | Entry::Note { id, .. } => id,
    }
}

#[test]
fn a_file_not_written_yet_is_an_empty_conversation() {
    let directory = tempfile::tempdir().unwrap();
    let read = read(
        located(Agent::Claude, directory.path().join("none.jsonl")),
        None,
        10,
    )
    .unwrap();
    assert!(read.entries.is_empty());
    assert!(read.reset);
}

#[test]
fn cursors_round_trip_and_reject_anything_else() {
    for cursor in [
        Cursor::File {
            device: 1,
            inode: 2,
            offset: 3,
        },
        Cursor::Amp {
            thread: "T-01a1".into(),
            messages: 4,
        },
    ] {
        assert_eq!(Cursor::parse(&cursor.render()), Some(cursor));
    }
    for text in [
        "",
        "v1:file:1:2",
        "v2:file:1:2:3",
        "v1:file:1:2:3:4",
        "v1:amp:T:x",
    ] {
        assert_eq!(Cursor::parse(text), None, "{text}");
    }
}

#[test]
fn claude_code_names_the_session_of_its_process() {
    let directory = tempfile::tempdir().unwrap();
    let dirs = dirs(directory.path());
    let started = SystemTime::now() - Duration::from_secs(600);
    let millis = started.duration_since(UNIX_EPOCH).unwrap().as_millis() as u64;
    write_lines(
        &dirs.claude.join("sessions/300.json"),
        &[json!({
        "pid": 300, "sessionId": "abc", "cwd": "/Users/me/my.project", "startedAt": millis + 900})],
    );
    write_lines(
        &dirs.claude.join("projects/-Users-me-my-project/abc.jsonl"),
        &[json!({"type": "mode"})],
    );
    let all = [
        process(200, 1, started, "/bin/zsh -l"),
        process(300, 200, started, "claude --dangerously-skip-permissions"),
        process(400, 1, started, "unrelated"),
    ];
    let found = locate(&session(200, "/Users/me/my.project"), &all, &dirs).unwrap();
    assert_eq!(found.agent, Agent::Claude);
    assert_eq!(found.session_id.as_deref(), Some("abc"));
    assert_eq!(
        found.path,
        Some(dirs.claude.join("projects/-Users-me-my-project/abc.jsonl"))
    );

    // A record a gone process left, whose pid came back for another.
    let again = [
        process(200, 1, started, "/bin/zsh -l"),
        process(300, 200, SystemTime::now(), "claude"),
    ];
    assert!(locate(&session(200, "/Users/me/my.project"), &again, &dirs).is_err());
}

#[test]
fn a_codex_rollout_is_the_one_its_process_started_in_the_folder() {
    let directory = tempfile::tempdir().unwrap();
    let dirs = dirs(directory.path());
    let (year, month, day) = civil_day(SystemTime::now());
    let day_dir = dirs
        .codex
        .join(format!("sessions/{year}/{month:02}/{day:02}"));
    write_lines(
        &day_dir.join("rollout-a-other.jsonl"),
        &[json!({"type": "session_meta", "payload": {"id": "other", "cwd": "/elsewhere"}})],
    );
    write_lines(
        &day_dir.join("rollout-b-mine.jsonl"),
        &[json!({"type": "session_meta", "payload": {"id": "mine", "cwd": "/work"}})],
    );
    let started = SystemTime::now() - Duration::from_secs(1);
    let all = [
        process(10, 1, started, "/bin/zsh"),
        process(11, 10, started, "node /opt/bin/codex.js"),
    ];
    let found = locate(&session(10, "/work/"), &all, &dirs).unwrap();
    assert_eq!(found.agent, Agent::Codex);
    assert_eq!(found.session_id.as_deref(), Some("mine"));

    // A process started after every rollout was written last has none.
    let later = [process(
        10,
        1,
        SystemTime::now() + Duration::from_secs(60),
        "codex",
    )];
    assert!(locate(&session(10, "/work"), &later, &dirs).is_err());
}

#[test]
fn a_pi_session_is_found_in_its_folder() {
    let directory = tempfile::tempdir().unwrap();
    let dirs = dirs(directory.path());
    assert_eq!(pi_folder("/Users/me/notes"), "--Users-me-notes--");
    write_lines(
        &dirs.pi_sessions.join("--Users-me-notes--/2026_p-1.jsonl"),
        &[json!({"type": "session", "id": "p-1", "cwd": "/Users/me/notes"})],
    );
    let started = SystemTime::now() - Duration::from_secs(1);
    let all = [process(20, 1, started, "bun /Users/me/.bun/bin/pi")];
    let found = locate(&session(20, "/Users/me/notes"), &all, &dirs).unwrap();
    assert_eq!(
        (found.agent, found.session_id.as_deref()),
        (Agent::Pi, Some("p-1"))
    );
}

#[test]
fn an_amp_thread_is_the_one_whose_log_names_its_process() {
    let directory = tempfile::tempdir().unwrap();
    let dirs = dirs(directory.path());
    write_lines(
        &dirs.amp_logs.join("T-old.log"),
        &[json!({"pid": 3011, "threadId": "T-old"})],
    );
    write_lines(
        &dirs.amp_logs.join("T-mine.log"),
        &[json!({"pid": 301, "threadId": "T-mine"})],
    );
    let started = SystemTime::now() - Duration::from_secs(1);
    let all = [
        process(30, 1, started, "/bin/zsh"),
        process(301, 30, started, "/Users/me/.amp/bin/amp"),
    ];
    let found = locate(&session(30, "/work"), &all, &dirs).unwrap();
    assert_eq!(
        (found.agent, found.session_id.as_deref()),
        (Agent::Amp, Some("T-mine"))
    );
    assert_eq!(found.amp, Some(PathBuf::from("/Users/me/.amp/bin/amp")));
    assert!(names_pid(&dirs.amp_logs.join("T-old.log"), 3011));
    assert!(!names_pid(&dirs.amp_logs.join("T-old.log"), 301));
}

#[test]
fn a_session_running_no_agent_says_so() {
    let directory = tempfile::tempdir().unwrap();
    let all = [process(40, 1, SystemTime::now(), "/bin/zsh -l")];
    let error = locate(&session(40, "/work"), &all, &dirs(directory.path())).unwrap_err();
    assert!(error
        .to_string()
        .contains("no Claude Code, Codex, Pi or Amp conversation"));
    let error = locate(&session(41, "/work"), &all, &dirs(directory.path())).unwrap_err();
    assert!(error.to_string().contains("is not running"));
}
