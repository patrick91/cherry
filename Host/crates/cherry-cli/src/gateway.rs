//! `cherry host mobile-gateway`: the forced command of the keys Cherry adds
//! to `~/.ssh/authorized_keys` for Cherry for iOS
//! (docs/specs/mobile-pairing.md › authorized_keys). sshd runs it whatever
//! the phone asks, with the phone's command line in `SSH_ORIGINAL_COMMAND`.
//! It runs that line, as this cherry, only when it is one Cherry for iOS
//! sends, and refuses anything else:
//!
//! - its locator (`/bin/sh -c SCRIPT cherry-mobile [PATH]`), never run: the
//!   answer is this cherry's path;
//! - `host control --no-start`, relaying only the requests the phone makes
//!   (`PHONE_REQUESTS`: no `create`, `kill` or `replace`);
//! - `host attach ID --detach-key none --client-id mobile-…`;
//! - `host transcript ID [--limit N] [--after CURSOR]`;
//!
//! each with `--expected-host-id` if given. The program the phone names
//! (its first word) is never run; nor are other options, a shell, a
//! subsystem or another host. Attaching to a session still lets the phone
//! type into it, and a terminal session runs what it types: the key
//! reaches Cherry's sessions, not a login.
use cherry_protocol::MAX_CLIENT_ID_BYTES;
use std::{os::unix::process::CommandExt, process::Command};

/// The control requests Cherry for iOS makes: it lists and follows
/// sessions, reads their screens and types into them.
pub const PHONE_REQUESTS: &[&str] = &["list", "subscribe", "ping", "screen", "send_input"];

/// The longest command line looked at.
const MAX_COMMAND_BYTES: usize = 16 * 1024;
/// The longest transcript cursor (`v1:file:…` or `v1:amp:<thread>:…`).
const MAX_CURSOR_BYTES: usize = 512;

/// What to do for a command line.
#[derive(Debug, PartialEq, Eq)]
pub enum Plan {
    /// Print this cherry's path, for the phone's locator.
    Locate,
    /// Run this cherry with these arguments (after its name).
    Run(Vec<String>),
}

/// Why a command line is refused, said to the phone on standard error.
const REFUSED: &str = "this key reaches only Cherry's sessions, for Cherry for iOS";

/// Runs `cli`'s mobile-gateway: the exit status when it does not become the
/// command (the locator's answer, or a refusal).
pub fn run(cli: &crate::Cli) -> u8 {
    if cli.host.is_some()
        || cli.socket.is_some()
        || cli.expected_host_id.is_some()
        || cli.ssh_control_path.is_some()
        || cli.remote_host_path.is_some()
    {
        eprintln!("cherry: mobile-gateway takes no options");
        return 2;
    }
    let original = std::env::var("SSH_ORIGINAL_COMMAND").ok();
    let plan = match plan(original.as_deref()) {
        Ok(plan) => plan,
        Err(why) => {
            eprintln!("cherry: {REFUSED}: {why}");
            return 1;
        }
    };
    let executable = match std::env::current_exe() {
        Ok(path) => path,
        Err(error) => {
            eprintln!("cherry: could not find this cherry: {error}");
            return 1;
        }
    };
    match plan {
        Plan::Locate => {
            println!("{}", executable.display());
            0
        }
        Plan::Run(arguments) => {
            let error = Command::new(&executable).args(arguments).exec();
            eprintln!("cherry: could not run {}: {error}", executable.display());
            1
        }
    }
}

/// What to do for the phone's command line `original` (None: sshd got no
/// command, a login shell was asked for).
pub fn plan(original: Option<&str>) -> Result<Plan, String> {
    let Some(original) = original else {
        return Err("it runs no shell".into());
    };
    if original.len() > MAX_COMMAND_BYTES {
        return Err("the command is too long".into());
    }
    let words = split(original)?;
    if words.len() >= 4 && words[0] == "/bin/sh" && words[1] == "-c" && words[3] == "cherry-mobile"
    {
        return Ok(Plan::Locate);
    }
    let words: Vec<&str> = words.iter().map(String::as_str).collect();
    let (command, rest) = match words.as_slice() {
        [_program, "host", command, rest @ ..] => (*command, rest),
        _ => return Err("it runs only cherry host control, attach and transcript".into()),
    };
    let options = Options::parse(rest)?;
    let mut arguments = vec!["host".to_owned(), command.to_owned()];
    match command {
        "control" => {
            options.only(&["--no-start", "--expected-host-id"], 0)?;
            arguments.push("--no-start".into());
            arguments.push(format!("--allow-requests={}", PHONE_REQUESTS.join(",")));
        }
        "attach" => {
            options.only(&["--detach-key", "--client-id", "--expected-host-id"], 1)?;
            if options
                .value("--detach-key")
                .is_some_and(|key| key != "none")
            {
                return Err("an attachment has no detach key".into());
            }
            arguments.push(session_id(options.positional[0])?);
            arguments.push("--detach-key=none".into());
            if let Some(id) = options.value("--client-id") {
                arguments.push(format!("--client-id={}", client_id(id)?));
            }
        }
        "transcript" => {
            options.only(&["--limit", "--after", "--expected-host-id"], 1)?;
            arguments.push(session_id(options.positional[0])?);
            if let Some(limit) = options.value("--limit") {
                if limit.is_empty() || !limit.bytes().all(|b| b.is_ascii_digit()) || limit.len() > 5
                {
                    return Err("--limit is a number".into());
                }
                arguments.push(format!("--limit={limit}"));
            }
            if let Some(cursor) = options.value("--after") {
                arguments.push(format!("--after={}", transcript_cursor(cursor)?));
            }
        }
        _ => return Err("it runs only cherry host control, attach and transcript".into()),
    }
    if let Some(id) = options.value("--expected-host-id") {
        arguments.push(format!(
            "--expected-host-id={}",
            uuid_text(id, "a host ID")?
        ));
    }
    Ok(Plan::Run(arguments))
}

/// A command's options and positional words, each option at most once.
struct Options<'a> {
    named: Vec<(&'a str, Option<&'a str>)>,
    positional: Vec<&'a str>,
}

/// The options that take a value.
const VALUE_OPTIONS: &[&str] = &[
    "--expected-host-id",
    "--detach-key",
    "--client-id",
    "--limit",
    "--after",
];

impl<'a> Options<'a> {
    fn parse(words: &[&'a str]) -> Result<Self, String> {
        let mut named: Vec<(&str, Option<&str>)> = Vec::new();
        let mut positional = Vec::new();
        let mut index = 0;
        while index < words.len() {
            let word = words[index];
            index += 1;
            if !word.starts_with('-') {
                positional.push(word);
                continue;
            }
            let (name, value) = match word.split_once('=') {
                Some((name, value)) => (name, Some(value)),
                None if VALUE_OPTIONS.contains(&word) => {
                    let Some(value) = words.get(index) else {
                        return Err(format!("{word} needs a value"));
                    };
                    index += 1;
                    (word, Some(*value))
                }
                None => (word, None),
            };
            if VALUE_OPTIONS.contains(&name) != value.is_some() {
                return Err(format!("{name} is not an option it allows"));
            }
            if named.iter().any(|(seen, _)| *seen == name) {
                return Err(format!("{name} is given twice"));
            }
            named.push((name, value));
        }
        Ok(Self { named, positional })
    }

    /// An error unless every option is one of `allowed` and there are
    /// exactly `positional` other words.
    fn only(&self, allowed: &[&str], positional: usize) -> Result<(), String> {
        if let Some((name, _)) = self.named.iter().find(|(name, _)| !allowed.contains(name)) {
            return Err(format!("{name} is not an option it allows"));
        }
        if self.positional.len() != positional {
            return Err(match positional {
                0 => "the command takes no arguments".into(),
                _ => "the command takes a session ID".into(),
            });
        }
        Ok(())
    }

    fn value(&self, name: &str) -> Option<&'a str> {
        self.named
            .iter()
            .find(|(seen, _)| *seen == name)
            .and_then(|(_, value)| *value)
    }
}

/// A UUID in its hyphenated form, as the host writes session and host IDs.
fn uuid_text(text: &str, what: &str) -> Result<String, String> {
    match uuid::Uuid::try_parse(text) {
        Ok(id) if text.len() == 36 => Ok(id.hyphenated().to_string()),
        _ => Err(format!("{what} is a UUID")),
    }
}

fn session_id(text: &str) -> Result<String, String> {
    uuid_text(text, "a session ID")
}

/// `mobile-` and letters, digits, `-`, `_` or `.`.
fn client_id(text: &str) -> Result<&str, String> {
    let ok = text.len() <= MAX_CLIENT_ID_BYTES
        && text.strip_prefix("mobile-").is_some_and(|rest| {
            !rest.is_empty()
                && rest
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
        });
    ok.then_some(text)
        .ok_or_else(|| "a client ID is mobile-<letters and digits>".into())
}

/// `v1:` and letters, digits, `:`, `-`, `_` or `.`; transcript.rs reads it.
fn transcript_cursor(text: &str) -> Result<&str, String> {
    let ok = text.len() <= MAX_CURSOR_BYTES
        && text.starts_with("v1:")
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b':' | b'-' | b'_' | b'.'));
    ok.then_some(text)
        .ok_or_else(|| "--after is a transcript's cursor".into())
}

/// The words of a command line as Cherry for iOS writes it
/// (`ShellQuote.command`: single-quoted words, `'` as `'\''`), or plain
/// words of letters, digits and `-_./:=,@%+`; anything a shell would expand
/// or treat specially is refused, never interpreted.
fn split(line: &str) -> Result<Vec<String>, String> {
    let mut words = Vec::new();
    let mut word: Option<String> = None;
    let mut characters = line.chars();
    while let Some(character) = characters.next() {
        match character {
            ' ' | '\t' => {
                if let Some(word) = word.take() {
                    words.push(word);
                }
            }
            '\'' => {
                let word = word.get_or_insert_with(String::new);
                loop {
                    match characters.next() {
                        Some('\'') => break,
                        Some(character) => word.push(character),
                        None => return Err("a quote is not closed".into()),
                    }
                }
            }
            '\\' => match characters.next() {
                Some(character) if character != '\n' => {
                    word.get_or_insert_with(String::new).push(character)
                }
                _ => return Err("the command ends in a backslash".into()),
            },
            character if character.is_ascii_alphanumeric() || "-_./:=,@%+".contains(character) => {
                word.get_or_insert_with(String::new).push(character)
            }
            _ => return Err("it runs one plain command".into()),
        }
    }
    words.extend(word);
    Ok(words)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SESSION: &str = "0b9d6c1e-3a3f-4c2b-9a4e-6f1d2c3b4a59";
    const HOST: &str = "12345678-1234-4234-8234-123456789abc";

    fn quoted(words: &[&str]) -> String {
        words
            .iter()
            .map(|word| format!("'{}'", word.replace('\'', r"'\''")))
            .collect::<Vec<_>>()
            .join(" ")
    }

    fn run(words: &[&str]) -> Vec<String> {
        match plan(Some(&quoted(words))) {
            Ok(Plan::Run(arguments)) => arguments,
            other => panic!("expected a run of {words:?}, got {other:?}"),
        }
    }

    #[test]
    fn the_phones_commands_run_as_this_cherry_with_only_the_options_they_allow() {
        assert_eq!(
            run(&[
                "/Applications/Cherry.app/Contents/MacOS/cherry",
                "host",
                "control",
                "--no-start",
                "--expected-host-id",
                HOST,
            ]),
            [
                "host",
                "control",
                "--no-start",
                "--allow-requests=list,subscribe,ping,screen,send_input",
                &format!("--expected-host-id={HOST}"),
            ]
        );
        // Control never starts a host, asked or not.
        assert_eq!(run(&["cherry", "host", "control"])[2], "--no-start");
        assert_eq!(
            run(&[
                "/x/cherry",
                "host",
                "attach",
                SESSION,
                "--detach-key",
                "none",
                "--client-id",
                "mobile-0123456789abcdef",
            ]),
            [
                "host",
                "attach",
                SESSION,
                "--detach-key=none",
                "--client-id=mobile-0123456789abcdef",
            ]
        );
        assert_eq!(
            run(&[
                "/x/cherry",
                "host",
                "transcript",
                SESSION,
                "--limit",
                "200",
                "--after",
                "v1:file:16777232:4512:9001",
            ]),
            [
                "host",
                "transcript",
                SESSION,
                "--limit=200",
                "--after=v1:file:16777232:4512:9001",
            ]
        );
    }

    #[test]
    fn the_locator_is_answered_never_run() {
        let locator = quoted(&[
            "/bin/sh",
            "-c",
            "p=$1; for p in \"$p\"; do printf '%s\\n' \"$p\"; done; exit 127",
            "cherry-mobile",
            "",
        ]);
        assert_eq!(plan(Some(&locator)), Ok(Plan::Locate));
        assert!(plan(Some(&quoted(&["/bin/sh", "-c", "id"]))).is_err());
        assert!(plan(Some(&quoted(&["/bin/zsh", "-c", "id", "cherry-mobile"]))).is_err());
    }

    #[test]
    fn anything_else_is_refused() {
        for words in [
            &["cherry", "host", "new", "--cwd=/", "--", "/bin/sh"][..],
            &["cherry", "host", "kill", SESSION],
            &["cherry", "host", "shutdown"],
            &["cherry", "host", "control", "--host", "elsewhere"],
            &["cherry", "host", "control", "--socket=/tmp/x.sock"],
            &["cherry", "host", "control", "--allow-requests=create"],
            &["cherry", "host", "control", "extra"],
            &["cherry", "host", "attach", SESSION, "--takeover"],
            &["cherry", "host", "attach", SESSION, "--status-file=/tmp/s"],
            &[
                "cherry",
                "host",
                "attach",
                SESSION,
                "--detach-key",
                "ctrl-]",
            ],
            &["cherry", "host", "attach", SESSION, "--client-id", "tab-7"],
            &["cherry", "host", "attach", "--socket=/tmp/x"],
            &["cherry", "host", "attach", SESSION, SESSION],
            &["cherry", "host", "transcript", SESSION, "--locate"],
            &[
                "cherry",
                "host",
                "transcript",
                SESSION,
                "--after",
                "--locate",
            ],
            &["cherry", "host", "transcript", SESSION, "--limit", "-1"],
            &["cherry", "host", "transcript", "-x"],
            &["cherry", "host", "control", "--no-start", "--no-start"],
            &["cherry", "ls"],
            &["cherry", "control", "--no-start"],
            &["sftp-server"],
            &[],
        ] {
            assert!(
                plan(Some(&quoted(words))).is_err(),
                "{words:?} should be refused"
            );
        }
        assert!(plan(None).is_err());
    }

    #[test]
    fn a_command_line_with_shell_syntax_is_refused_not_interpreted() {
        for line in [
            "cherry host control --no-start; id",
            "cherry host control --no-start && id",
            "cherry host control $(id)",
            "cherry host control `id`",
            "cherry host control --no-start | id",
            "cherry host control > /tmp/x",
            "cherry host control \"--no-start\"",
            "cherry host control\n--no-start",
            "cherry host control '--no-start",
            "~/cherry host control",
        ] {
            assert!(plan(Some(line)).is_err(), "{line:?} should be refused");
        }
        // Plain words and the phone's quoting both read.
        assert_eq!(
            split(r"cherry 'host' con'trol' 'it'\''s'").unwrap(),
            ["cherry", "host", "control", "it's"]
        );
        assert_eq!(run(&["cherry", "host", "control"])[1], "control");
    }

    #[test]
    fn ids_are_uuids_in_the_hosts_form() {
        let upper = SESSION.to_uppercase();
        assert_eq!(run(&["cherry", "host", "transcript", &upper])[2], SESSION);
        for id in [
            "0b9d6c1e3a3f4c2b9a4e6f1d2c3b4a59",
            "urn:uuid:0b9d6c1e-3a3f-4c2b-9a4e-6f1d2c3b4a59",
            "not-a-session",
        ] {
            assert!(plan(Some(&quoted(&["cherry", "host", "attach", id]))).is_err());
        }
    }
}
