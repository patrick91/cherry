//! `cherry host transcript`: the conversation of the agent a session runs,
//! for a client that shows it (Cherry for iPhone), and the agent's own id
//! for the session, which resumes it.
//!
//! Claude Code, Codex and Pi keep a conversation in a JSON Lines file on
//! this machine; Amp keeps it on its server, which `amp threads export`
//! reads. The agent and its session come from the session's processes:
//! Claude Code's `sessions/<pid>.json` names each of its processes'
//! sessions; a Codex rollout or a Pi session file is the one the agent's
//! process started in the session's folder; Amp's thread logs name the
//! process that runs each thread. Entries are trimmed (a tool call to a
//! one-line summary and the start of its result), and a cursor lets the next
//! read return only what is new.

use anyhow::{bail, Context, Result};
use cherry_protocol::SessionInfo;
use serde::Serialize;
use serde_json::Value;
use std::{
    collections::HashMap,
    fs::{self, File},
    io::{BufRead, BufReader, Read, Seek, SeekFrom},
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

/// Entries a read returns at most unless asked for fewer or more.
pub const DEFAULT_LIMIT: usize = 200;
/// The most entries a read returns.
pub const MAX_LIMIT: usize = 2000;
/// A message's text is cut after this many characters, a tool's result
/// after `RESULT_CHARS` and its summary after `SUMMARY_CHARS`.
const TEXT_CHARS: usize = 20_000;
const RESULT_CHARS: usize = 2_000;
const SUMMARY_CHARS: usize = 200;
/// A first read starts this far from the end of the file and widens 4×
/// until it has the entries it wants, the whole file, or `MAX_WINDOW`.
const FIRST_WINDOW: u64 = 1 << 20;
const MAX_WINDOW: u64 = 64 << 20;
/// A session file created this long before its process started (`ps`
/// counts whole seconds) is still that process's.
const START_SLACK: Duration = Duration::from_secs(5);
/// How far Claude Code's record of when it started may be from when `ps`
/// says its process did: a record left by a process that is gone, whose pid
/// came back, is farther.
const CLAUDE_START_SLACK: Duration = Duration::from_secs(120);
/// The longest first line (a Codex rollout's `session_meta` carries its
/// instructions) read to learn a session file's folder and id.
const MAX_HEADER_BYTES: u64 = 4 << 20;
/// The most of an Amp thread log read to find its process.
const MAX_LOG_BYTES: u64 = 16 << 20;
const AMP_EXPORT_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Agent {
    Claude,
    Codex,
    Pi,
    Amp,
}

/// Where each agent keeps its sessions, with the environment overrides the
/// agents read.
#[derive(Clone, Debug)]
pub struct Dirs {
    pub claude: PathBuf,
    pub codex: PathBuf,
    pub pi_sessions: PathBuf,
    pub amp_logs: PathBuf,
}

impl Dirs {
    pub fn from_environment() -> Result<Dirs> {
        let var = |name: &str| {
            std::env::var_os(name)
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
        };
        let home = var("HOME").context("HOME is not set")?;
        let pi = var("PI_CODING_AGENT_DIR").unwrap_or_else(|| home.join(".pi/agent"));
        Ok(Dirs {
            claude: var("CLAUDE_CONFIG_DIR").unwrap_or_else(|| home.join(".claude")),
            codex: var("CODEX_HOME").unwrap_or_else(|| home.join(".codex")),
            pi_sessions: var("PI_CODING_AGENT_SESSION_DIR").unwrap_or_else(|| pi.join("sessions")),
            amp_logs: var("XDG_CACHE_HOME")
                .unwrap_or_else(|| home.join(".cache"))
                .join("amp/logs/threads"),
        })
    }
}

/// A process as `ps` lists it.
#[derive(Clone, Debug)]
pub struct Process {
    pub pid: u32,
    pub ppid: u32,
    pub started: SystemTime,
    pub command: String,
}

/// Every process on this machine.
pub fn processes() -> Result<Vec<Process>> {
    let output = Command::new("/bin/ps")
        .args(["-A", "-o", "pid=,ppid=,etime=,command="])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .context("running ps")?;
    if !output.status.success() {
        bail!("ps failed ({})", output.status);
    }
    let now = SystemTime::now();
    Ok(String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| parse_ps_line(line, now))
        .collect())
}

fn parse_ps_line(line: &str, now: SystemTime) -> Option<Process> {
    let mut words = line.split_whitespace();
    let pid = words.next()?.parse().ok()?;
    let ppid = words.next()?.parse().ok()?;
    let elapsed = parse_etime(words.next()?)?;
    let command = words.collect::<Vec<_>>().join(" ");
    Some(Process {
        pid,
        ppid,
        started: now.checked_sub(elapsed)?,
        command,
    })
}

/// `ps`'s elapsed time: `[[dd-]hh:]mm:ss`.
fn parse_etime(text: &str) -> Option<Duration> {
    let (days, rest) = match text.split_once('-') {
        Some((days, rest)) => (days.parse::<u64>().ok()?, rest),
        None => (0, text),
    };
    let parts = rest
        .split(':')
        .map(|part| part.parse::<u64>().ok())
        .collect::<Option<Vec<_>>>()?;
    let (hours, minutes, seconds) = match parts.as_slice() {
        [minutes, seconds] => (0, *minutes, *seconds),
        [hours, minutes, seconds] => (*hours, *minutes, *seconds),
        _ => return None,
    };
    Some(Duration::from_secs(
        ((days * 24 + hours) * 60 + minutes) * 60 + seconds,
    ))
}

/// The process `root` and its descendants, `root` first.
fn tree(all: &[Process], root: u32) -> Vec<&Process> {
    let mut found: Vec<&Process> = all.iter().filter(|p| p.pid == root).collect();
    let mut index = 0;
    while index < found.len() && found.len() < 4096 {
        let parent = found[index].pid;
        found.extend(all.iter().filter(|p| p.ppid == parent && p.pid != parent));
        index += 1;
    }
    found
}

/// The agent session a Cherry session runs.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Located {
    pub agent: Agent,
    /// The agent's own id for the session, which resumes it (`claude
    /// --resume ID`, `codex resume ID`, `pi --session PATH`, `amp threads
    /// continue ID`).
    pub session_id: Option<String>,
    /// Its file; none for Amp, whose threads are on its server.
    pub path: Option<PathBuf>,
    /// The `amp` that runs the thread, which exports it.
    #[serde(skip)]
    amp: Option<PathBuf>,
}

/// Which agent session `session` runs, from its processes.
pub fn locate(session: &SessionInfo, all: &[Process], dirs: &Dirs) -> Result<Located> {
    let Some(pid) = session.pid else {
        bail!("session {} runs no program", session.id);
    };
    let tree = tree(all, pid);
    if tree.is_empty() {
        bail!(
            "session {}'s program (pid {pid}) is not running",
            session.id
        );
    }
    if let Some(found) = tree.iter().find_map(|process| claude(dirs, process)) {
        return Ok(found);
    }
    let folders = folders(session);
    let hint = session
        .tags
        .get("cherry.agent")
        .map(|agent| agent.to_ascii_lowercase())
        .unwrap_or_default();
    for process in &tree {
        let agent = agent_named(process)
            .or_else(|| (process.pid == pid).then(|| agent_hinted(&hint)).flatten());
        let found = match agent {
            Some(Agent::Codex) => codex(dirs, process, &folders),
            Some(Agent::Pi) => pi(dirs, process, &folders),
            Some(Agent::Amp) => amp(dirs, process),
            Some(Agent::Claude) | None => None,
        };
        if let Some(found) = found {
            return Ok(found);
        }
    }
    bail!(
        "no Claude Code, Codex, Pi or Amp conversation found for session {}",
        session.id
    )
}

/// The folders the session's agent may name as its own: where the session
/// started, and where its shell says it is.
fn folders(session: &SessionInfo) -> Vec<String> {
    let mut folders = Vec::new();
    for folder in [Some(&session.cwd), session.pwd.as_ref()]
        .into_iter()
        .flatten()
    {
        let folder = folder.trim_end_matches('/');
        let folder = if folder.is_empty() { "/" } else { folder };
        if !folders.iter().any(|f| f == folder) {
            folders.push(folder.to_owned());
        }
    }
    folders
}

fn agent_named(process: &Process) -> Option<Agent> {
    for word in process.command.split_whitespace().take(3) {
        if word.contains("/pi-coding-agent/") {
            return Some(Agent::Pi);
        }
        let name = Path::new(word)
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or(word);
        let name = name.strip_suffix(".js").unwrap_or(name);
        match name {
            "codex" => return Some(Agent::Codex),
            "pi" => return Some(Agent::Pi),
            "amp" => return Some(Agent::Amp),
            _ if name.starts_with("codex-") => return Some(Agent::Codex),
            _ => {}
        }
    }
    None
}

/// The agent a session's `cherry.agent` tag names, for a program that runs
/// it under another name.
fn agent_hinted(hint: &str) -> Option<Agent> {
    match hint {
        "pi" => Some(Agent::Pi),
        hint if hint.contains("codex") => Some(Agent::Codex),
        hint if hint.contains("amp") => Some(Agent::Amp),
        _ => None,
    }
}

fn claude(dirs: &Dirs, process: &Process) -> Option<Located> {
    let record = fs::read(
        dirs.claude
            .join("sessions")
            .join(format!("{}.json", process.pid)),
    )
    .ok()?;
    let record: Value = serde_json::from_slice(&record).ok()?;
    if record.get("pid").and_then(Value::as_u64) != Some(u64::from(process.pid)) {
        return None;
    }
    if let Some(started) = record.get("startedAt").and_then(Value::as_u64) {
        let started = UNIX_EPOCH + Duration::from_millis(started);
        let apart = started
            .duration_since(process.started)
            .or_else(|_| process.started.duration_since(started))
            .unwrap_or_default();
        if apart > CLAUDE_START_SLACK {
            return None;
        }
    }
    let session_id = record.get("sessionId")?.as_str()?.to_owned();
    let cwd = record
        .get("cwd")
        .and_then(Value::as_str)
        .unwrap_or_default();
    Some(Located {
        agent: Agent::Claude,
        path: Some(claude_transcript(&dirs.claude, cwd, &session_id)),
        session_id: Some(session_id),
        amp: None,
    })
}

/// `projects/<folder>/<session>.jsonl`, the folder named as Claude Code
/// names it (every character but letters and digits a `-`), or found among
/// the others.
fn claude_transcript(dir: &Path, cwd: &str, session_id: &str) -> PathBuf {
    let name = format!("{session_id}.jsonl");
    let folder: String = cwd
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    let direct = dir.join("projects").join(folder).join(&name);
    if direct.is_file() {
        return direct;
    }
    fs::read_dir(dir.join("projects"))
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| entry.path().join(&name))
        .find(|path| path.is_file())
        .unwrap_or(direct)
}

fn codex(dirs: &Dirs, process: &Process, folders: &[String]) -> Option<Located> {
    // `sessions/YYYY/MM/DD/rollout-….jsonl`, from the day before the
    // process started (the folders are named for the local day).
    let since = process
        .started
        .checked_sub(Duration::from_secs(86_400))
        .unwrap_or(UNIX_EPOCH);
    let first_day = civil_day(since);
    let mut files = Vec::new();
    for (year, year_dir) in numbered(&dirs.codex.join("sessions")) {
        for (month, month_dir) in numbered(&year_dir) {
            for (day, day_dir) in numbered(&month_dir) {
                if (year, month, day) < first_day {
                    continue;
                }
                files.extend(
                    fs::read_dir(&day_dir)
                        .into_iter()
                        .flatten()
                        .flatten()
                        .map(|entry| entry.path())
                        .filter(|path| {
                            path.file_name()
                                .and_then(|name| name.to_str())
                                .is_some_and(|name| {
                                    name.starts_with("rollout-") && name.ends_with(".jsonl")
                                })
                        }),
                );
            }
        }
    }
    let (path, header) = started_by(process, files, |header| {
        header
            .pointer("/payload/cwd")
            .and_then(Value::as_str)
            .is_some_and(|cwd| {
                folders
                    .iter()
                    .any(|folder| folder == cwd.trim_end_matches('/'))
            })
    })?;
    Some(Located {
        agent: Agent::Codex,
        session_id: header
            .pointer("/payload/id")
            .and_then(Value::as_str)
            .map(str::to_owned),
        path: Some(path),
        amp: None,
    })
}

fn pi(dirs: &Dirs, process: &Process, folders: &[String]) -> Option<Located> {
    let files = folders
        .iter()
        .flat_map(|folder| {
            fs::read_dir(dirs.pi_sessions.join(pi_folder(folder)))
                .into_iter()
                .flatten()
                .flatten()
                .map(|entry| entry.path())
        })
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "jsonl")
        })
        .collect();
    let (path, header) = started_by(process, files, |header| {
        header.get("type").and_then(Value::as_str) == Some("session")
    })?;
    Some(Located {
        agent: Agent::Pi,
        session_id: header.get("id").and_then(Value::as_str).map(str::to_owned),
        path: Some(path),
        amp: None,
    })
}

/// `--<path>--`: Pi drops the leading separator and makes `/`, `\` and `:`
/// a `-`.
fn pi_folder(cwd: &str) -> String {
    format!(
        "--{}--",
        cwd.trim_start_matches(['/', '\\'])
            .replace(['/', '\\', ':'], "-")
    )
}

fn amp(dirs: &Dirs, process: &Process) -> Option<Located> {
    let since = process
        .started
        .checked_sub(START_SLACK)
        .unwrap_or(UNIX_EPOCH);
    let mut newest: Option<(SystemTime, String)> = None;
    for entry in fs::read_dir(&dirs.amp_logs).ok()?.flatten() {
        let path = entry.path();
        let Some(thread) = path
            .file_name()
            .and_then(|name| name.to_str())
            .and_then(|name| name.strip_suffix(".log"))
            .filter(|name| name.starts_with("T-"))
        else {
            continue;
        };
        let Ok(modified) = entry.metadata().and_then(|meta| meta.modified()) else {
            continue;
        };
        if modified < since || newest.as_ref().is_some_and(|(time, _)| modified <= *time) {
            continue;
        }
        if names_pid(&path, process.pid) {
            newest = Some((modified, thread.to_owned()));
        }
    }
    let (_, thread) = newest?;
    Some(Located {
        agent: Agent::Amp,
        session_id: Some(thread),
        path: None,
        amp: Some(amp_executable(process)),
    })
}

/// Whether an Amp thread log has a line of process `pid` (`"pid":PID`).
fn names_pid(path: &Path, pid: u32) -> bool {
    let mut bytes = Vec::new();
    if File::open(path)
        .and_then(|file| file.take(MAX_LOG_BYTES).read_to_end(&mut bytes))
        .is_err()
    {
        return false;
    }
    let needle = format!("\"pid\":{pid}");
    memchr::memmem::find_iter(&bytes, needle.as_bytes())
        .any(|at| !bytes.get(at + needle.len()).is_some_and(u8::is_ascii_digit))
}

/// The `amp` the process runs, else the first on PATH or where Amp installs.
fn amp_executable(process: &Process) -> PathBuf {
    let program = process.command.split_whitespace().next().unwrap_or("amp");
    if program.starts_with('/')
        && Path::new(program)
            .file_name()
            .is_some_and(|name| name == "amp")
    {
        return PathBuf::from(program);
    }
    let home = std::env::var_os("HOME").map(PathBuf::from);
    std::env::var_os("PATH")
        .map(|path| std::env::split_paths(&path).collect::<Vec<_>>())
        .unwrap_or_default()
        .into_iter()
        .chain(
            home.iter()
                .flat_map(|home| [home.join(".amp/bin"), home.join(".local/bin")]),
        )
        .map(|dir| dir.join("amp"))
        .find(|path| path.is_file())
        .unwrap_or_else(|| PathBuf::from("amp"))
}

/// Of the session files whose first line `accept` takes (the session's
/// folder), the one `process` started: the first created since it started,
/// else (a session it resumed) the one written last since it started.
fn started_by(
    process: &Process,
    files: Vec<PathBuf>,
    accept: impl Fn(&Value) -> bool,
) -> Option<(PathBuf, Value)> {
    let since = process
        .started
        .checked_sub(START_SLACK)
        .unwrap_or(UNIX_EPOCH);
    let mut first_created: Option<(SystemTime, PathBuf, Value)> = None;
    let mut last_written: Option<(SystemTime, PathBuf, Value)> = None;
    for path in files {
        let Ok(meta) = fs::metadata(&path) else {
            continue;
        };
        let Ok(modified) = meta.modified() else {
            continue;
        };
        if modified < since {
            continue;
        }
        let Some(header) = header(&path) else {
            continue;
        };
        if !accept(&header) {
            continue;
        }
        let created = meta.created().unwrap_or(modified);
        if created >= since
            && first_created
                .as_ref()
                .is_none_or(|(time, ..)| created < *time)
        {
            first_created = Some((created, path.clone(), header.clone()));
        }
        if last_written
            .as_ref()
            .is_none_or(|(time, ..)| modified > *time)
        {
            last_written = Some((modified, path, header));
        }
    }
    first_created
        .or(last_written)
        .map(|(_, path, header)| (path, header))
}

/// A session file's first line, its header.
fn header(path: &Path) -> Option<Value> {
    let mut line = Vec::new();
    BufReader::new(File::open(path).ok()?)
        .take(MAX_HEADER_BYTES)
        .read_until(b'\n', &mut line)
        .ok()?;
    serde_json::from_slice(&line).ok()
}

/// The entries of `dir` named by a number, with it.
fn numbered(dir: &Path) -> Vec<(u32, PathBuf)> {
    fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let number = entry.file_name().to_str()?.parse().ok()?;
            Some((number, entry.path()))
        })
        .collect()
}

/// The UTC date of `time` (year, month, day).
fn civil_day(time: SystemTime) -> (u32, u32, u32) {
    let days = time
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        / 86_400;
    civil_from_days(days as i64)
}

/// Howard Hinnant's `civil_from_days`.
fn civil_from_days(days: i64) -> (u32, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    (year as u32, month as u32, day as u32)
}

/// `2026-11-04T15:42:32.293Z` from milliseconds since 1970.
fn iso_time(millis: u64) -> String {
    let seconds = millis / 1000;
    let (year, month, day) = civil_from_days((seconds / 86_400) as i64);
    let time = seconds % 86_400;
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        time / 3600,
        time / 60 % 60,
        time % 60,
        millis % 1000
    )
}

// MARK: - Entries

/// One thing in a conversation, as a client shows it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Entry {
    User {
        id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        time: Option<String>,
        text: String,
    },
    Assistant {
        id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        time: Option<String>,
        text: String,
    },
    Tool {
        id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        time: Option<String>,
        name: String,
        summary: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        result: Option<String>,
        status: ToolStatus,
    },
    /// A tool an earlier read returned has finished.
    ToolResult {
        id: String,
        result: String,
        status: ToolStatus,
    },
    /// What happened to the conversation rather than in it: a compaction, a
    /// slash command, an interruption, an API error.
    Note {
        id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        time: Option<String>,
        text: String,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolStatus {
    Running,
    Ok,
    Error,
}

#[derive(Debug, PartialEq, Eq)]
enum Item {
    Entry(Entry),
    Title(String),
}

/// A read, and where the next one starts.
#[derive(Debug, Serialize)]
pub struct Transcript {
    #[serde(flatten)]
    pub located: Located,
    pub title: Option<String>,
    pub cursor: String,
    /// The entries replace what an earlier read returned (a first read, or
    /// the session's file changed); otherwise they come after it.
    pub reset: bool,
    /// Older entries were left out.
    pub more_before: bool,
    pub entries: Vec<Entry>,
}

/// Where a read ended: a file's identity and the offset after its last whole
/// line, or how many of an Amp thread's messages were complete.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Cursor {
    File {
        device: u64,
        inode: u64,
        offset: u64,
    },
    Amp {
        thread: String,
        messages: usize,
    },
}

impl Cursor {
    fn parse(text: &str) -> Option<Cursor> {
        let mut parts = text.split(':');
        let cursor = match (parts.next()?, parts.next()?) {
            ("v1", "file") => Cursor::File {
                device: parts.next()?.parse().ok()?,
                inode: parts.next()?.parse().ok()?,
                offset: parts.next()?.parse().ok()?,
            },
            ("v1", "amp") => Cursor::Amp {
                thread: parts.next()?.to_owned(),
                messages: parts.next()?.parse().ok()?,
            },
            _ => return None,
        };
        parts.next().is_none().then_some(cursor)
    }

    fn render(&self) -> String {
        match self {
            Cursor::File {
                device,
                inode,
                offset,
            } => format!("v1:file:{device}:{inode}:{offset}"),
            Cursor::Amp { thread, messages } => format!("v1:amp:{thread}:{messages}"),
        }
    }
}

/// The entries of a read, a tool's result put on its tool.
#[derive(Default)]
struct Batch {
    entries: Vec<Entry>,
    title: Option<String>,
    tools: HashMap<String, usize>,
}

impl Batch {
    /// `keep_updates`: keep the results of tools this read did not return
    /// (they belong to an earlier read's), else drop them.
    fn collect(items: Vec<Item>, keep_updates: bool) -> Batch {
        let mut batch = Batch::default();
        for item in items {
            match item {
                Item::Title(title) => batch.title = Some(title),
                Item::Entry(Entry::ToolResult { id, result, status }) => {
                    let tool = batch
                        .tools
                        .get(&id)
                        .and_then(|&index| batch.entries.get_mut(index));
                    if let Some(Entry::Tool {
                        result: r,
                        status: s,
                        ..
                    }) = tool
                    {
                        *r = Some(result);
                        *s = status;
                    } else if keep_updates {
                        batch.entries.push(Entry::ToolResult { id, result, status });
                    }
                }
                Item::Entry(entry) => {
                    if let Entry::Tool { id, .. } = &entry {
                        batch.tools.insert(id.clone(), batch.entries.len());
                    }
                    batch.entries.push(entry);
                }
            }
        }
        batch
    }

    /// Entries a client shows (not the results of earlier reads' tools).
    fn shown(&self) -> usize {
        self.entries
            .iter()
            .filter(|entry| !matches!(entry, Entry::ToolResult { .. }))
            .count()
    }

    /// The last `limit` shown entries, and whether any were left out.
    fn last(self, limit: usize) -> (Vec<Entry>, Option<String>, bool) {
        let shown = self.shown();
        if shown <= limit {
            return (self.entries, self.title, false);
        }
        let mut skip = shown - limit;
        let entries = self
            .entries
            .into_iter()
            .skip_while(|entry| {
                if skip == 0 {
                    return false;
                }
                if !matches!(entry, Entry::ToolResult { .. }) {
                    skip -= 1;
                }
                true
            })
            .collect();
        (entries, self.title, true)
    }
}

/// The conversation of `located`, after `after` (an earlier read's cursor),
/// at most `limit` entries: the latest.
pub fn read(located: Located, after: Option<&str>, limit: usize) -> Result<Transcript> {
    let limit = limit.clamp(1, MAX_LIMIT);
    let after = after.and_then(Cursor::parse);
    match located.agent {
        Agent::Amp => read_amp(located, after, limit),
        _ => read_file(located, after, limit),
    }
}

fn read_file(located: Located, after: Option<Cursor>, limit: usize) -> Result<Transcript> {
    let path = located.path.clone().context("the session has no file")?;
    let mut file = match File::open(&path) {
        Ok(file) => file,
        // Agents write the file with the session's first message.
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Transcript {
                located,
                title: None,
                cursor: Cursor::File {
                    device: 0,
                    inode: 0,
                    offset: 0,
                }
                .render(),
                reset: true,
                more_before: false,
                entries: Vec::new(),
            });
        }
        Err(error) => return Err(error).with_context(|| format!("reading {}", path.display())),
    };
    let meta = file.metadata()?;
    let (device, inode, len) = (meta.dev(), meta.ino(), meta.len());
    let agent = located.agent;
    if let Some(Cursor::File {
        device: d,
        inode: i,
        offset,
    }) = after
    {
        if d == device && i == inode && offset <= len && len - offset <= MAX_WINDOW {
            let (end, items) = parse_range(&mut file, offset, len, false, agent)?;
            let batch = Batch::collect(items, true);
            // More than a client asked for since its last read: it gets the
            // latest instead, as a first read.
            if batch.shown() <= limit {
                return Ok(Transcript {
                    located,
                    title: batch.title,
                    cursor: Cursor::File {
                        device,
                        inode,
                        offset: end,
                    }
                    .render(),
                    reset: false,
                    more_before: false,
                    entries: batch.entries,
                });
            }
        }
    }
    let mut window = FIRST_WINDOW;
    loop {
        let start = len.saturating_sub(window);
        let (end, items) = parse_range(&mut file, start, len, start > 0, agent)?;
        let batch = Batch::collect(items, false);
        if batch.shown() >= limit || start == 0 || window >= MAX_WINDOW {
            let (entries, title, cut) = batch.last(limit);
            return Ok(Transcript {
                located,
                title,
                cursor: Cursor::File {
                    device,
                    inode,
                    offset: end,
                }
                .render(),
                reset: true,
                more_before: start > 0 || cut,
                entries,
            });
        }
        window *= 4;
    }
}

/// The items of the whole lines in `start..end` of `file`, and the offset
/// after the last one (a line still being written is read next time).
/// `partial_start`: `start` may be inside a line, which is skipped.
fn parse_range(
    file: &mut File,
    start: u64,
    end: u64,
    partial_start: bool,
    agent: Agent,
) -> Result<(u64, Vec<Item>)> {
    file.seek(SeekFrom::Start(start))?;
    let mut bytes = Vec::with_capacity((end - start) as usize);
    file.by_ref().take(end - start).read_to_end(&mut bytes)?;
    let mut position = 0;
    if partial_start {
        match memchr::memchr(b'\n', &bytes) {
            Some(newline) => position = newline + 1,
            None => return Ok((start, Vec::new())),
        }
    }
    let mut items = Vec::new();
    while let Some(length) = memchr::memchr(b'\n', &bytes[position..]) {
        let line = &bytes[position..position + length];
        if let Ok(record) = serde_json::from_slice::<Value>(line) {
            let offset = start + position as u64;
            match agent {
                Agent::Claude => claude_record(&record, offset, &mut items),
                Agent::Codex => codex_record(&record, offset, &mut items),
                Agent::Pi => pi_record(&record, offset, &mut items),
                Agent::Amp => {}
            }
        }
        position += length + 1;
    }
    Ok((start + position as u64, items))
}

fn read_amp(located: Located, after: Option<Cursor>, limit: usize) -> Result<Transcript> {
    let thread = located.session_id.clone().context("no Amp thread")?;
    let executable = located.amp.clone().unwrap_or_else(|| PathBuf::from("amp"));
    let mut command = Command::new(&executable);
    command.args(["threads", "export", &thread]);
    let export = output_within(command, AMP_EXPORT_TIMEOUT)
        .with_context(|| format!("exporting Amp thread {thread}"))?;
    let export: Value =
        serde_json::from_slice(&export).context("Amp's thread export is not JSON")?;
    let messages = export
        .get("messages")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();
    // A message still being written is read again next time.
    let complete = match messages.last() {
        Some(last)
            if str_at(last, "role") == Some("assistant")
                && last.pointer("/state/type").and_then(Value::as_str) != Some("complete") =>
        {
            messages.len() - 1
        }
        _ => messages.len(),
    };
    let start = match after {
        Some(Cursor::Amp {
            thread: t,
            messages: n,
        }) if t == thread && n <= messages.len() => Some(n),
        _ => None,
    };
    let mut items = Vec::new();
    if let Some(title) = str_at(&export, "title").filter(|title| !title.is_empty()) {
        items.push(Item::Title(title.to_owned()));
    }
    for (index, message) in messages.iter().enumerate().skip(start.unwrap_or(0)) {
        amp_message(message, index, &mut items);
    }
    let cursor = Cursor::Amp {
        thread,
        messages: complete,
    }
    .render();
    let batch = Batch::collect(items, start.is_some());
    if start.is_some() && batch.shown() <= limit {
        return Ok(Transcript {
            located,
            title: batch.title,
            cursor,
            reset: false,
            more_before: false,
            entries: batch.entries,
        });
    }
    let batch = if start.is_some() {
        // Too much since the last read: the latest, as a first read.
        let mut items = Vec::new();
        for (index, message) in messages.iter().enumerate() {
            amp_message(message, index, &mut items);
        }
        Batch::collect(items, false)
    } else {
        batch
    };
    let (entries, title, cut) = batch.last(limit);
    Ok(Transcript {
        located,
        title: title.or_else(|| str_at(&export, "title").map(str::to_owned)),
        cursor,
        reset: true,
        more_before: cut,
        entries,
    })
}

/// A command's standard output, if it succeeds within `timeout`.
fn output_within(mut command: Command, timeout: Duration) -> Result<Vec<u8>> {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let mut stdout = child.stdout.take().expect("piped");
    let mut stderr = child.stderr.take().expect("piped");
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        stdout.read_to_end(&mut bytes).map(|_| bytes)
    });
    let errors = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = stderr.read_to_end(&mut bytes);
        bytes
    });
    let deadline = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            bail!("it did not finish within {} s", timeout.as_secs());
        }
        std::thread::sleep(Duration::from_millis(25));
    };
    let bytes = reader
        .join()
        .map_err(|_| anyhow::anyhow!("reading its output failed"))??;
    let errors = errors.join().unwrap_or_default();
    if !status.success() {
        let why = String::from_utf8_lossy(&errors);
        bail!("{status}: {}", why.trim());
    }
    Ok(bytes)
}

// MARK: - Agents' records

fn str_at<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

fn flag(value: &Value, key: &str) -> bool {
    value.get(key).and_then(Value::as_bool) == Some(true)
}

/// `text` cut after `max` characters, with an ellipsis.
fn clip(text: &str, max: usize) -> String {
    match text.char_indices().nth(max) {
        Some((at, _)) => format!("{}…", &text[..at]),
        None => text.to_owned(),
    }
}

fn first_line(text: &str) -> &str {
    text.lines()
        .find(|line| !line.trim().is_empty())
        .unwrap_or("")
        .trim()
}

/// The text of a message's content: a string, or text blocks (an image as
/// `[image]`).
fn content_text(content: Option<&Value>) -> String {
    match content {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Array(blocks)) => blocks
            .iter()
            .filter_map(|block| match block {
                Value::String(text) => Some(text.as_str()),
                _ => match str_at(block, "type") {
                    Some("text" | "input_text" | "output_text" | "Text") => str_at(block, "text"),
                    Some("image" | "input_image") => Some("[image]"),
                    _ => None,
                },
            })
            .collect::<Vec<_>>()
            .join("\n\n"),
        Some(Value::Null) | None => String::new(),
        Some(other) => other.to_string(),
    }
}

/// A tool call's input in one line: its command, path, pattern, URL or
/// query, else its first string, else its JSON.
fn summarize(input: Option<&Value>) -> String {
    const KEYS: [&str; 12] = [
        "command",
        "cmd",
        "file_path",
        "path",
        "pattern",
        "url",
        "query",
        "description",
        "prompt",
        "subject",
        "objective",
        "name",
    ];
    let line = match input {
        None | Some(Value::Null) => return String::new(),
        Some(Value::String(text)) => first_line(text).to_owned(),
        Some(Value::Object(map)) => KEYS
            .iter()
            .find_map(|key| match map.get(*key) {
                Some(Value::String(text)) => Some(first_line(text).to_owned()),
                Some(Value::Array(words)) if words.iter().all(Value::is_string) => Some(
                    words
                        .iter()
                        .filter_map(Value::as_str)
                        .collect::<Vec<_>>()
                        .join(" "),
                ),
                _ => None,
            })
            .or_else(|| {
                map.values()
                    .find_map(Value::as_str)
                    .map(|text| first_line(text).to_owned())
            })
            .unwrap_or_else(|| Value::Object(map.clone()).to_string()),
        Some(other) => other.to_string(),
    };
    clip(&line, SUMMARY_CHARS)
}

fn note(id: String, time: Option<String>, text: &str) -> Item {
    Item::Entry(Entry::Note {
        id,
        time,
        text: text.to_owned(),
    })
}

/// `text` without its `<tag>…</tag>` parts.
fn without_tagged(text: &str, tag: &str) -> String {
    let (open, close) = (format!("<{tag}>"), format!("</{tag}>"));
    let mut kept = String::new();
    let mut rest = text;
    while let Some(start) = rest.find(&open) {
        kept.push_str(&rest[..start]);
        match rest[start..].find(&close) {
            Some(end) => rest = &rest[start + end + close.len()..],
            None => {
                rest = "";
                break;
            }
        }
    }
    kept.push_str(rest);
    kept
}

/// What is between `<tag>` and `</tag>` in `text`.
fn tagged<'a>(text: &'a str, tag: &str) -> Option<&'a str> {
    let start = text.find(&format!("<{tag}>"))? + tag.len() + 2;
    let end = text[start..].find(&format!("</{tag}>"))? + start;
    Some(text[start..end].trim())
}

/// A prompt the user typed into Claude Code, or what Claude Code wrote in
/// its place: a slash command, a shell command, an interruption.
fn claude_prompt(id: String, time: Option<String>, text: &str, items: &mut Vec<Item>) {
    let text = without_tagged(text, "system-reminder");
    let text = text.trim();
    if text.is_empty() {
        return;
    }
    // Output Claude Code shows after a slash or shell command.
    let output = [
        "<local-command-",
        "<bash-stdout>",
        "<bash-stderr>",
        "<command-message>",
    ]
    .iter()
    .any(|prefix| text.starts_with(prefix));
    if let Some(command) = tagged(text, "command-name") {
        items.push(note(id, time, &format!("Ran {command}")));
    } else if let Some(command) = tagged(text, "bash-input") {
        items.push(note(id, time, &format!("! {command}")));
    } else if text.starts_with("<task-notification>") {
        // A background task Claude Code started has news for it.
        let summary = tagged(text, "summary").unwrap_or("A background task finished");
        items.push(note(id, time, &clip(summary, SUMMARY_CHARS)));
    } else if output {
    } else if text.starts_with("[Request interrupted by user") {
        items.push(note(id, time, "Interrupted"));
    } else {
        items.push(Item::Entry(Entry::User {
            id,
            time,
            text: clip(text, TEXT_CHARS),
        }));
    }
}

fn claude_record(record: &Value, offset: u64, items: &mut Vec<Item>) {
    if flag(record, "isSidechain") {
        return;
    }
    let id = str_at(record, "uuid").map_or_else(|| format!("@{offset}"), str::to_owned);
    let time = str_at(record, "timestamp").map(str::to_owned);
    match str_at(record, "type") {
        Some("ai-title") => {
            if let Some(title) = str_at(record, "aiTitle").filter(|title| !title.is_empty()) {
                items.push(Item::Title(title.to_owned()));
            }
        }
        Some("system") if str_at(record, "subtype") == Some("compact_boundary") => {
            items.push(note(id, time, "Conversation compacted"));
        }
        Some("user") => {
            // Claude Code's own context, and the summary after a compaction
            // (the boundary says so).
            if flag(record, "isMeta") || flag(record, "isCompactSummary") {
                return;
            }
            match record.pointer("/message/content") {
                Some(Value::String(text)) => claude_prompt(id, time, text, items),
                Some(Value::Array(blocks)) => {
                    let mut text = Vec::new();
                    for block in blocks {
                        match str_at(block, "type") {
                            Some("tool_result") => {
                                let Some(tool) = str_at(block, "tool_use_id") else {
                                    continue;
                                };
                                items.push(Item::Entry(Entry::ToolResult {
                                    id: tool.to_owned(),
                                    result: clip(
                                        content_text(block.get("content")).trim(),
                                        RESULT_CHARS,
                                    ),
                                    status: if flag(block, "is_error") {
                                        ToolStatus::Error
                                    } else {
                                        ToolStatus::Ok
                                    },
                                }));
                            }
                            Some("text") => text.extend(str_at(block, "text")),
                            Some("image") => text.push("[image]"),
                            _ => {}
                        }
                    }
                    if !text.is_empty() {
                        claude_prompt(id, time, &text.join("\n\n"), items);
                    }
                }
                _ => {}
            }
        }
        Some("assistant") => {
            let Some(Value::Array(blocks)) = record.pointer("/message/content") else {
                return;
            };
            let api_error = flag(record, "isApiErrorMessage");
            for (index, block) in blocks.iter().enumerate() {
                let block_id = if index == 0 {
                    id.clone()
                } else {
                    format!("{id}#{index}")
                };
                match str_at(block, "type") {
                    Some("text") => {
                        let text = str_at(block, "text").unwrap_or_default().trim();
                        if text.is_empty() {
                            continue;
                        }
                        if api_error {
                            items.push(note(block_id, time.clone(), &clip(text, TEXT_CHARS)));
                        } else {
                            items.push(Item::Entry(Entry::Assistant {
                                id: block_id,
                                time: time.clone(),
                                text: clip(text, TEXT_CHARS),
                            }));
                        }
                    }
                    Some("tool_use") => {
                        let Some(tool) = str_at(block, "id") else {
                            continue;
                        };
                        items.push(Item::Entry(Entry::Tool {
                            id: tool.to_owned(),
                            time: time.clone(),
                            name: str_at(block, "name").unwrap_or("Tool").to_owned(),
                            summary: summarize(block.get("input")),
                            result: None,
                            status: ToolStatus::Running,
                        }));
                    }
                    _ => {}
                }
            }
        }
        _ => {}
    }
}

fn codex_record(record: &Value, offset: u64, items: &mut Vec<Item>) {
    if str_at(record, "type") != Some("event_msg") {
        return;
    }
    let Some(payload) = record.get("payload") else {
        return;
    };
    let time = str_at(record, "timestamp").map(str::to_owned);
    let fallback = format!("@{offset}");
    match str_at(payload, "type") {
        Some("item_completed") => {
            if let Some(item) = payload.get("item") {
                codex_item(item, time, fallback, items);
            }
        }
        // Codex before item_completed.
        Some("user_message") => {
            if let Some(text) = str_at(payload, "message")
                .map(str::trim)
                .filter(|text| !text.is_empty())
            {
                items.push(Item::Entry(Entry::User {
                    id: fallback,
                    time,
                    text: clip(text, TEXT_CHARS),
                }));
            }
        }
        Some("agent_message") => {
            if let Some(text) = str_at(payload, "message")
                .map(str::trim)
                .filter(|text| !text.is_empty())
            {
                items.push(Item::Entry(Entry::Assistant {
                    id: fallback,
                    time,
                    text: clip(text, TEXT_CHARS),
                }));
            }
        }
        _ => {}
    }
}

fn codex_item(item: &Value, time: Option<String>, fallback: String, items: &mut Vec<Item>) {
    let id = str_at(item, "id").map_or(fallback, str::to_owned);
    let failed = |status: Option<&str>| {
        matches!(status, Some("failed" | "declined" | "error" | "cancelled"))
    };
    let tool = |name: &str, summary: String, result: String, ok: bool| {
        Item::Entry(Entry::Tool {
            id: id.clone(),
            time: time.clone(),
            name: name.to_owned(),
            summary,
            result: (!result.trim().is_empty()).then(|| clip(result.trim(), RESULT_CHARS)),
            status: if ok {
                ToolStatus::Ok
            } else {
                ToolStatus::Error
            },
        })
    };
    match str_at(item, "type") {
        Some("UserMessage") => {
            let text = content_text(item.get("content"));
            if !text.trim().is_empty() {
                items.push(Item::Entry(Entry::User {
                    id,
                    time,
                    text: clip(text.trim(), TEXT_CHARS),
                }));
            }
        }
        Some("AgentMessage") => {
            let text = content_text(item.get("content"));
            if !text.trim().is_empty() {
                items.push(Item::Entry(Entry::Assistant {
                    id,
                    time,
                    text: clip(text.trim(), TEXT_CHARS),
                }));
            }
        }
        Some("CommandExecution") => {
            let summary = item
                .pointer("/parsed_cmd/0/cmd")
                .and_then(Value::as_str)
                .map(|command| clip(first_line(command), SUMMARY_CHARS))
                .unwrap_or_else(|| summarize(item.get("command")));
            let ok = item
                .get("exit_code")
                .and_then(Value::as_i64)
                .is_none_or(|code| code == 0)
                && !failed(str_at(item, "status"));
            items.push(tool(
                "Shell",
                summary,
                str_at(item, "aggregated_output")
                    .unwrap_or_default()
                    .to_owned(),
                ok,
            ));
        }
        Some("FileChange") => {
            let files = item
                .get("changes")
                .and_then(Value::as_object)
                .map(|changes| {
                    changes
                        .keys()
                        .map(|path| {
                            Path::new(path)
                                .file_name()
                                .and_then(|n| n.to_str())
                                .unwrap_or(path)
                        })
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .unwrap_or_default();
            let output = [str_at(item, "stdout"), str_at(item, "stderr")]
                .into_iter()
                .flatten()
                .filter(|text| !text.trim().is_empty())
                .collect::<Vec<_>>()
                .join("\n");
            items.push(tool(
                "Edit",
                clip(&files, SUMMARY_CHARS),
                output,
                !failed(str_at(item, "status")),
            ));
        }
        Some("McpToolCall") => {
            let name = match (str_at(item, "server"), str_at(item, "tool")) {
                (Some(server), Some(tool)) => format!("{server} {tool}"),
                (_, Some(tool)) => tool.to_owned(),
                _ => "MCP".to_owned(),
            };
            let error = item.get("error").filter(|error| !error.is_null());
            let result = match error {
                Some(Value::String(text)) => text.clone(),
                Some(other) => other.to_string(),
                None => content_text(item.pointer("/result/content")),
            };
            let ok = error.is_none()
                && !flag(item.get("result").unwrap_or(&Value::Null), "isError")
                && !failed(str_at(item, "status"));
            items.push(tool(&name, summarize(item.get("arguments")), result, ok));
        }
        Some("Extension") => {
            let name = match str_at(item, "kind") {
                Some(kind) if kind.contains("search") => "Web search".to_owned(),
                Some(kind) => kind.to_owned(),
                None => "Extension".to_owned(),
            };
            let results = item
                .get("results")
                .and_then(Value::as_array)
                .map(|results| {
                    results
                        .iter()
                        .filter_map(|result| str_at(result, "title"))
                        .collect::<Vec<_>>()
                        .join("\n")
                })
                .unwrap_or_default();
            items.push(tool(&name, summarize(item.get("query")), results, true));
        }
        Some("ImageView") => {
            let path = str_at(item, "path").unwrap_or_default();
            let name = Path::new(path)
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or(path);
            items.push(tool("View image", name.to_owned(), String::new(), true));
        }
        Some("ContextCompaction") => items.push(note(id, time, "Conversation compacted")),
        _ => {}
    }
}

fn pi_record(record: &Value, offset: u64, items: &mut Vec<Item>) {
    let id = str_at(record, "id").map_or_else(|| format!("@{offset}"), str::to_owned);
    let time = str_at(record, "timestamp").map(str::to_owned);
    match str_at(record, "type") {
        Some("session_info") => {
            if let Some(name) = str_at(record, "name").filter(|name| !name.is_empty()) {
                items.push(Item::Title(name.to_owned()));
            }
        }
        Some("compaction") => items.push(note(id, time, "Conversation compacted")),
        Some("branch_summary") => items.push(note(id, time, "Went back to an earlier point")),
        Some("message") => {
            let Some(message) = record.get("message") else {
                return;
            };
            match str_at(message, "role") {
                Some("user") => {
                    let text = content_text(message.get("content"));
                    if !text.trim().is_empty() {
                        items.push(Item::Entry(Entry::User {
                            id,
                            time,
                            text: clip(text.trim(), TEXT_CHARS),
                        }));
                    }
                }
                Some("assistant") => {
                    let Some(Value::Array(blocks)) = message.get("content") else {
                        return;
                    };
                    for (index, block) in blocks.iter().enumerate() {
                        let block_id = if index == 0 {
                            id.clone()
                        } else {
                            format!("{id}#{index}")
                        };
                        match str_at(block, "type") {
                            Some("text") => {
                                let text = str_at(block, "text").unwrap_or_default().trim();
                                if !text.is_empty() {
                                    items.push(Item::Entry(Entry::Assistant {
                                        id: block_id,
                                        time: time.clone(),
                                        text: clip(text, TEXT_CHARS),
                                    }));
                                }
                            }
                            Some("toolCall") => {
                                let Some(tool) = str_at(block, "id") else {
                                    continue;
                                };
                                items.push(Item::Entry(Entry::Tool {
                                    id: tool.to_owned(),
                                    time: time.clone(),
                                    name: str_at(block, "name").unwrap_or("tool").to_owned(),
                                    summary: summarize(block.get("arguments")),
                                    result: None,
                                    status: ToolStatus::Running,
                                }));
                            }
                            _ => {}
                        }
                    }
                }
                Some("toolResult") => {
                    if let Some(tool) = str_at(message, "toolCallId") {
                        items.push(Item::Entry(Entry::ToolResult {
                            id: tool.to_owned(),
                            result: clip(content_text(message.get("content")).trim(), RESULT_CHARS),
                            status: if flag(message, "isError") {
                                ToolStatus::Error
                            } else {
                                ToolStatus::Ok
                            },
                        }));
                    }
                }
                Some("bashExecution") => {
                    let output = str_at(message, "output").unwrap_or_default().trim();
                    items.push(Item::Entry(Entry::Tool {
                        id,
                        time,
                        name: "Shell".to_owned(),
                        summary: summarize(message.get("command")),
                        result: (!output.is_empty()).then(|| clip(output, RESULT_CHARS)),
                        status: if message.get("exitCode").and_then(Value::as_i64) == Some(0) {
                            ToolStatus::Ok
                        } else {
                            ToolStatus::Error
                        },
                    }));
                }
                _ => {}
            }
        }
        _ => {}
    }
}

fn amp_message(message: &Value, index: usize, items: &mut Vec<Item>) {
    let id = match message.get("messageId") {
        Some(Value::Number(number)) => format!("m{number}"),
        Some(Value::String(text)) => text.clone(),
        _ => format!("m@{index}"),
    };
    let time = match message.get("createdAt") {
        Some(Value::String(text)) => Some(text.clone()),
        Some(Value::Number(number)) => number.as_u64().map(iso_time),
        _ => None,
    };
    let Some(Value::Array(blocks)) = message.get("content") else {
        return;
    };
    let role = str_at(message, "role");
    let mut text = Vec::new();
    for (index, block) in blocks.iter().enumerate() {
        let block_id = if index == 0 {
            id.clone()
        } else {
            format!("{id}#{index}")
        };
        match (role, str_at(block, "type")) {
            (Some("user"), Some("text")) => text.extend(str_at(block, "text")),
            (Some("user"), Some("tool_result")) => {
                let Some(tool) = str_at(block, "toolUseID") else {
                    continue;
                };
                let result = match block.pointer("/run/result") {
                    Some(Value::String(text)) => text.clone(),
                    Some(Value::Null) | None => String::new(),
                    Some(other) => other.to_string(),
                };
                let status = match block.pointer("/run/status").and_then(Value::as_str) {
                    Some("done") => ToolStatus::Ok,
                    Some("error" | "rejected-by-user" | "cancelled" | "rejected") => {
                        ToolStatus::Error
                    }
                    _ => ToolStatus::Running,
                };
                items.push(Item::Entry(Entry::ToolResult {
                    id: tool.to_owned(),
                    result: clip(result.trim(), RESULT_CHARS),
                    status,
                }));
            }
            (Some("assistant"), Some("text")) => {
                let text = str_at(block, "text").unwrap_or_default().trim();
                if !text.is_empty() {
                    items.push(Item::Entry(Entry::Assistant {
                        id: block_id,
                        time: time.clone(),
                        text: clip(text, TEXT_CHARS),
                    }));
                }
            }
            (Some("assistant"), Some("tool_use")) => {
                let Some(tool) = str_at(block, "id") else {
                    continue;
                };
                items.push(Item::Entry(Entry::Tool {
                    id: tool.to_owned(),
                    time: time.clone(),
                    name: str_at(block, "name").unwrap_or("tool").to_owned(),
                    summary: summarize(block.get("input")),
                    result: None,
                    status: ToolStatus::Running,
                }));
            }
            _ => {}
        }
    }
    let text = text.join("\n\n");
    if !text.trim().is_empty() {
        items.push(Item::Entry(Entry::User {
            id,
            time,
            text: clip(text.trim(), TEXT_CHARS),
        }));
    }
}

#[cfg(test)]
mod tests;
