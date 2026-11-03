//! `cherry`'s agent commands (docs/specs/agent-cli.md): every command line
//! that is not the session host's goes to the Cherry app over its control
//! socket as one `runCommand` request, which the app parses and runs (its
//! commands' table, help, guide and skill install are the app's), and the
//! answer's output and exit status are this process's.
//!
//! The wire is the app's (Swift-synthesized Codable: camelCase keys, an
//! enum case with a payload as `{"case":{"_0":…}}`, nil left out). One
//! request line per connection, then the one answer line. When the app asks
//! for standard input (`needsStandardInput`) or files (`needsFiles`: a
//! `--schema FILE`, read here, relative to this process's directory), the
//! request is sent again with them. `cherry skill setup|status|remove`
//! places the skill's files on this Mac through two more rounds: the app
//! asks what some paths are (`needsPaths`, answered in `paths`), then hands
//! the file operations to perform here (`operations`, answered in
//! `operationResults`), so the files are always the caller's Mac's. A tab
//! on another Mac sends its token with the request (`cherryAuth`), as the
//! Swift client did.

use serde_json::{json, Map, Value};
use std::{
    ffi::OsString,
    io::{self, Read, Write},
    os::unix::{
        fs::{FileTypeExt, MetadataExt},
        net::UnixStream,
    },
    path::{Component, Path, PathBuf},
    time::Duration,
};

pub const SOCKET_ENVIRONMENT_KEY: &str = "CHERRY_CONTROL_SOCKET";
pub const SOCKET_NAMESPACE_ENVIRONMENT_KEY: &str = "CHERRY_CONTROL_NAMESPACE";
pub const PROCESS_ID_ENVIRONMENT_KEY: &str = "CHERRY_PROCESS_ID";
pub const AGENT_ID_ENVIRONMENT_KEY: &str = "CHERRY_AGENT_ID";
pub const PROJECT_ROOT_ENVIRONMENT_KEY: &str = "CHERRY_PROJECT_ROOT";
pub const TOKEN_ENVIRONMENT_KEY: &str = "CHERRY_MCP_TOKEN";
pub const CONTROL_MACHINE_ENVIRONMENT_KEY: &str = "CHERRY_CONTROL_MACHINE";

/// The variables the app's skill install reads (`cherry skill setup`), sent
/// when set.
const FORWARDED_VARIABLES: &[&str] = &[
    "HOME",
    "PATH",
    "CLAUDE_CONFIG_DIR",
    "CODEX_HOME",
    "PI_CODING_AGENT_DIR",
    "XDG_CONFIG_HOME",
];

/// The longest a command waits for its answer: the longest wait a command
/// can ask for (300 s) and its margins.
const READ_TIMEOUT: Duration = Duration::from_secs(340);
const WRITE_TIMEOUT: Duration = Duration::from_secs(10);
/// Rounds of one command: the first request, then again with standard
/// input, files, paths or operation results the app asked for (a skill's
/// folder, then its files, then their contents, then the operations, then
/// their results).
const MAXIMUM_ROUNDS: usize = 10;
/// What an operation after a failed one of its group gets.
const NOT_ATTEMPTED: &str = "not attempted: an earlier step failed";

/// An error with the app's code, printed as `code: message`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ControlError {
    pub code: String,
    pub message: String,
    /// The error's other fields (a menu's options, a schema's problems),
    /// printed as JSON on the next line.
    pub rest: Option<String>,
}

impl ControlError {
    fn new(code: &str, message: impl Into<String>) -> Self {
        ControlError {
            code: code.to_string(),
            message: message.into(),
            rest: None,
        }
    }

    pub fn line(&self) -> String {
        let mut line = format!("{}: {}", self.code, self.message);
        if let Some(rest) = &self.rest {
            line.push('\n');
            line.push_str(rest);
        }
        line
    }
}

/// What the app answered a `runCommand`.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct CommandAnswer {
    pub standard_output: String,
    pub standard_error: String,
    pub exit_code: i64,
    pub needs_standard_input: bool,
    pub needs_files: Vec<String>,
    pub needs_paths: Vec<String>,
    /// File operations to perform here (`cherry skill`), nil when none.
    pub operations: Option<Vec<Operation>>,
}

/// One file operation the app hands `cherry` (`cherry skill setup|remove`).
/// A group's operations stop at its first failure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Operation {
    pub group: i64,
    pub kind: OperationKind,
    pub path: String,
    pub contents: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OperationKind {
    CreateDirectory,
    Write,
    Remove,
}

/// What a path is: `lstat`'s kind (`entry`), `stat`'s through links
/// (`target`), whether it is an executable file, and a directory's names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PathDescription {
    pub path: String,
    pub entry: &'static str,
    pub target: &'static str,
    pub executable: bool,
    pub entries: Option<Vec<String>>,
}

/// A tab of another Mac's token and id (`CherryControlCredentials`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Credentials {
    pub token: String,
    pub process_id: String,
}

/// What the command sends besides its words: read once from the process.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Caller {
    pub socket: PathBuf,
    pub credentials: Option<Credentials>,
    pub control_machine: Option<String>,
    pub caller_process_id: Option<String>,
    pub project_root: Option<String>,
    pub working_directory: Option<String>,
    pub environment: Vec<(String, String)>,
    pub standard_output_is_terminal: bool,
    pub standard_input_is_piped: bool,
}

/// What the request carries that changes between rounds.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Supplied {
    pub standard_input: Option<String>,
    /// Each file asked for, its contents nil when unreadable or not UTF-8.
    pub files: Vec<(String, Option<String>)>,
    /// Each path asked for, described.
    pub paths: Vec<PathDescription>,
    /// One per operation performed, its error nil on success; nil until the
    /// app handed operations.
    pub operation_results: Option<Vec<Option<String>>>,
}

fn variable(name: &str) -> Option<String> {
    std::env::var(name).ok()
}

fn trimmed(value: Option<String>) -> Option<String> {
    value
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

/// The tab the environment names: CHERRY_PROCESS_ID, else (only when it is
/// unset) CHERRY_AGENT_ID, trimmed.
fn tab_id(lookup: &impl Fn(&str) -> Option<String>) -> Option<String> {
    trimmed(lookup(PROCESS_ID_ENVIRONMENT_KEY).or_else(|| lookup(AGENT_ID_ENVIRONMENT_KEY)))
}

/// Whether `value` is a UUID as Foundation's `UUID(uuidString:)` takes one:
/// 36 characters, hex digits with hyphens at 8, 13, 18 and 23.
pub fn is_uuid(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => *byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        })
}

impl Caller {
    /// This process's: its environment, directory, executable and standard
    /// streams.
    pub fn current() -> Caller {
        let lookup = |name: &str| variable(name);
        let executable = std::env::current_exe()
            .ok()
            .map(|path| std::fs::canonicalize(&path).unwrap_or(path));
        Caller::from(
            &lookup,
            executable.as_deref(),
            std::env::current_dir()
                .ok()
                .map(|path| path.to_string_lossy().into_owned()),
            unsafe { libc::isatty(libc::STDOUT_FILENO) } == 1,
            standard_input_is_piped(),
        )
    }

    pub fn from(
        lookup: &impl Fn(&str) -> Option<String>,
        executable: Option<&Path>,
        working_directory: Option<String>,
        standard_output_is_terminal: bool,
        standard_input_is_piped: bool,
    ) -> Caller {
        let tab = tab_id(lookup);
        let credentials = trimmed(lookup(TOKEN_ENVIRONMENT_KEY))
            .zip(tab.clone())
            .map(|(token, process_id)| Credentials { token, process_id });
        Caller {
            socket: socket_path(lookup, executable),
            credentials,
            control_machine: trimmed(lookup(CONTROL_MACHINE_ENVIRONMENT_KEY)),
            caller_process_id: tab.filter(|id| is_uuid(id)),
            project_root: lookup(PROJECT_ROOT_ENVIRONMENT_KEY),
            working_directory,
            environment: FORWARDED_VARIABLES
                .iter()
                .filter_map(|name| lookup(name).map(|value| (name.to_string(), value)))
                .collect(),
            standard_output_is_terminal,
            standard_input_is_piped,
        }
    }

    /// The request line's JSON: `runCommand`, in an envelope with the
    /// tab's token on another Mac.
    pub fn request(&self, arguments: &[String], supplied: &Supplied) -> Value {
        let mut context = Map::new();
        if let Some(id) = &self.caller_process_id {
            context.insert("callerProcessID".into(), json!(id));
        }
        if let Some(root) = &self.project_root {
            context.insert("projectRoot".into(), json!(root));
        }
        if let Some(directory) = &self.working_directory {
            context.insert("workingDirectory".into(), json!(directory));
        }
        context.insert("interface".into(), json!("cli"));

        let mut command = Map::new();
        command.insert("arguments".into(), json!(arguments));
        command.insert("context".into(), Value::Object(context));
        command.insert(
            "standardOutputIsTerminal".into(),
            json!(self.standard_output_is_terminal),
        );
        command.insert(
            "standardInputIsPiped".into(),
            json!(self.standard_input_is_piped),
        );
        if let Some(text) = &supplied.standard_input {
            command.insert("standardInput".into(), json!(text));
        }
        if !supplied.files.is_empty() {
            let files: Vec<Value> = supplied
                .files
                .iter()
                .map(|(path, contents)| match contents {
                    Some(contents) => json!({"path": path, "contents": contents}),
                    None => json!({"path": path}),
                })
                .collect();
            command.insert("files".into(), Value::Array(files));
        }
        if !supplied.paths.is_empty() {
            let paths: Vec<Value> = supplied
                .paths
                .iter()
                .map(|described| {
                    let mut object = Map::new();
                    object.insert("path".into(), json!(described.path));
                    object.insert("entry".into(), json!(described.entry));
                    object.insert("target".into(), json!(described.target));
                    object.insert("executable".into(), json!(described.executable));
                    if let Some(entries) = &described.entries {
                        object.insert("entries".into(), json!(entries));
                    }
                    Value::Object(object)
                })
                .collect();
            command.insert("paths".into(), Value::Array(paths));
        }
        if let Some(results) = &supplied.operation_results {
            let results: Vec<Value> = results
                .iter()
                .map(|error| match error {
                    Some(error) => json!({"error": error}),
                    None => json!({}),
                })
                .collect();
            command.insert("operationResults".into(), Value::Array(results));
        }
        if !self.environment.is_empty() {
            let environment: Map<String, Value> = self
                .environment
                .iter()
                .map(|(name, value)| (name.clone(), json!(value)))
                .collect();
            command.insert("environment".into(), Value::Object(environment));
        }
        command.insert("cliBuild".into(), json!(cherry_protocol::BUILD));

        let request = json!({"runCommand": {"_0": Value::Object(command)}});
        match &self.credentials {
            Some(credentials) => json!({
                "cherryAuth": {"token": credentials.token, "processID": credentials.process_id},
                "request": request,
            }),
            None => request,
        }
    }

    /// "Cherry on <Mac> is not reachable": a device tab's forward is down.
    fn unreachable(&self, detail: &str) -> ControlError {
        let machine = self.control_machine.as_deref().unwrap_or("the other Mac");
        ControlError::new(
            "cherry_unreachable",
            format!(
                "Cherry on {machine} is not reachable ({detail}). Its connection to this Mac comes back when Cherry there reconnects."
            ),
        )
    }

    /// One request and its answer; on another Mac, a connection that never
    /// answered is "not reachable".
    fn send(&self, request: &Value) -> Result<Value, ControlError> {
        let result = send_line(&self.socket, request);
        match result {
            Err(error) if self.credentials.is_some() => Err(match error.code.as_str() {
                "cherry_unavailable" => self.unreachable(&format!(
                    "its control socket {} did not answer",
                    self.socket.display()
                )),
                "empty_response" | "read_failed" | "write_failed" => {
                    self.unreachable("the connection closed without an answer")
                }
                _ => error,
            }),
            other => other,
        }
    }

    /// Runs `arguments` in the app: the request, then again with what it
    /// asks for, until it answers with output.
    pub fn run(
        &self,
        arguments: &[String],
        read_standard_input: &mut dyn FnMut() -> String,
        read_file: &dyn Fn(&str) -> Option<String>,
    ) -> Result<CommandAnswer, ControlError> {
        let mut supplied = Supplied::default();
        for _ in 0..MAXIMUM_ROUNDS {
            let answer = parse_answer(self.send(&self.request(arguments, &supplied))?)?;
            let mut asked = false;
            if answer.needs_standard_input {
                if supplied.standard_input.is_some() {
                    return Err(asked_again("standard input"));
                }
                supplied.standard_input = Some(read_standard_input());
                asked = true;
            }
            for path in &answer.needs_files {
                if supplied.files.iter().any(|(known, _)| known == path) {
                    return Err(asked_again(path));
                }
                supplied.files.push((path.clone(), read_file(path)));
                asked = true;
            }
            for path in &answer.needs_paths {
                if supplied.paths.iter().any(|known| &known.path == path) {
                    return Err(asked_again(path));
                }
                supplied.paths.push(describe_path(path));
                asked = true;
            }
            if let Some(operations) = &answer.operations {
                if supplied.operation_results.is_some() {
                    return Err(ControlError::new(
                        "unexpected_response",
                        "Cherry handed file operations again after their results.",
                    ));
                }
                supplied.operation_results = Some(perform_operations(operations));
                asked = true;
            }
            if !asked {
                return Ok(answer);
            }
        }
        Err(ControlError::new(
            "unexpected_response",
            "Cherry kept asking for more input.",
        ))
    }
}

fn asked_again(what: &str) -> ControlError {
    ControlError::new(
        "unexpected_response",
        format!("Cherry asked again for {what}, which it was sent."),
    )
}

// MARK: Files here (`cherry skill`)

fn kind(metadata: &std::fs::Metadata) -> &'static str {
    let file_type = metadata.file_type();
    if file_type.is_symlink() {
        "link"
    } else if file_type.is_dir() {
        "directory"
    } else {
        "file"
    }
}

/// `path` as the app's installer looks at it: never through a link for
/// `entry`, through them for `target` and the rest.
pub fn describe_path(path: &str) -> PathDescription {
    let entry = std::fs::symlink_metadata(path)
        .map(|metadata| kind(&metadata))
        .unwrap_or("none");
    let followed = std::fs::metadata(path).ok();
    let target = followed.as_ref().map(kind).unwrap_or("none");
    let executable = followed
        .as_ref()
        .is_some_and(|metadata| metadata.is_file() && metadata.mode() & 0o111 != 0);
    let entries = (target == "directory")
        .then(|| std::fs::read_dir(path).ok())
        .flatten()
        .map(|listing| {
            let mut names: Vec<String> = listing
                .filter_map(Result::ok)
                .map(|entry| entry.file_name().to_string_lossy().into_owned())
                .collect();
            names.sort();
            names
        });
    PathDescription {
        path: path.to_string(),
        entry,
        target,
        executable,
        entries,
    }
}

/// Performs `operations` in order: one result per operation, nil on
/// success. After a failure the rest of its group is not attempted.
pub fn perform_operations(operations: &[Operation]) -> Vec<Option<String>> {
    let mut failed_groups = Vec::new();
    operations
        .iter()
        .map(|operation| {
            if failed_groups.contains(&operation.group) {
                return Some(NOT_ATTEMPTED.to_string());
            }
            let outcome = perform(operation);
            let error = outcome
                .err()
                .map(|error| format!("{}: {error}", operation.path));
            if error.is_some() {
                failed_groups.push(operation.group);
            }
            error
        })
        .collect()
}

fn perform(operation: &Operation) -> io::Result<()> {
    let path = Path::new(&operation.path);
    match operation.kind {
        OperationKind::CreateDirectory => std::fs::create_dir_all(path),
        OperationKind::Write => {
            write_atomically(path, operation.contents.as_deref().unwrap_or("").as_bytes())
        }
        OperationKind::Remove => {
            let is_directory = std::fs::symlink_metadata(path)?.is_dir();
            if is_directory {
                std::fs::remove_dir(path)
            } else {
                std::fs::remove_file(path)
            }
        }
    }
}

/// `contents` at `path` through a new file beside it renamed over it: a link
/// at `path` is replaced, never written through.
fn write_atomically(path: &Path, contents: &[u8]) -> io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    use std::sync::atomic::{AtomicUsize, Ordering};
    static COUNTER: AtomicUsize = AtomicUsize::new(0);
    let directory = path.parent().unwrap_or_else(|| Path::new("/"));
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let temporary = directory.join(format!(
        ".{name}.cherry-{}-{}.tmp",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let written = (|| {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o644)
            .open(&temporary)?;
        file.write_all(contents)?;
        file.sync_all()?;
        std::fs::rename(&temporary, path)
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    written
}

/// Whether standard input is a pipe, a file or a socket: what a missing
/// text argument reads (never a terminal, nor /dev/null, a device).
fn standard_input_is_piped() -> bool {
    let mut status: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(libc::STDIN_FILENO, &mut status) } != 0 {
        return false;
    }
    matches!(
        status.st_mode & libc::S_IFMT,
        libc::S_IFIFO | libc::S_IFREG | libc::S_IFSOCK
    )
}

// MARK: The socket's path

/// `CHERRY_CONTROL_SOCKET` (an empty one is unset), else the path the app
/// of this `cherry` listens on: `/tmp/cherry-<uid>/<namespace>/control.sock`
/// (`CherryControl.socketURL`).
pub fn socket_path(lookup: &impl Fn(&str) -> Option<String>, executable: Option<&Path>) -> PathBuf {
    if let Some(path) = trimmed(lookup(SOCKET_ENVIRONMENT_KEY)) {
        return PathBuf::from(path);
    }
    let uid = unsafe { libc::getuid() };
    PathBuf::from(format!("/tmp/cherry-{uid}"))
        .join(socket_namespace(lookup, executable))
        .join("control.sock")
}

/// `CherryControl.socketNamespace`: `CHERRY_CONTROL_NAMESPACE`, else the
/// enclosing app's name (or `cherry-dev` outside an app) and a hash of its
/// path, so each copy of Cherry has its own socket. The app hashes its path
/// as Foundation gives it, decomposed (NFD), and this one as the file
/// system has it: an app under a path with accents can hash otherwise, so
/// its tabs' `CHERRY_CONTROL_SOCKET` is what they use.
pub fn socket_namespace(
    lookup: &impl Fn(&str) -> Option<String>,
    executable: Option<&Path>,
) -> String {
    if let Some(namespace) = trimmed(lookup(SOCKET_NAMESPACE_ENVIRONMENT_KEY)) {
        return sanitized_component(&namespace);
    }
    let (identity, label) = identity(executable);
    let hash = format!("{:016x}", fnv1a(identity.to_string_lossy().as_bytes()));
    format!("{}-{}", sanitized_component(&label), &hash[..12])
}

/// The enclosing app (the path through its first component ending in
/// `.app`), else the executable's directory, else the current directory;
/// and its label.
fn identity(executable: Option<&Path>) -> (PathBuf, String) {
    let Some(executable) = executable else {
        let directory = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"));
        return (directory, "cherry-dev".to_string());
    };
    let mut path = PathBuf::new();
    for component in executable.components() {
        path.push(component.as_os_str());
        if let Component::Normal(name) = component {
            let name = name.to_string_lossy();
            if name.to_lowercase().ends_with(".app") {
                let label = Path::new(name.as_ref())
                    .file_stem()
                    .map(|stem| stem.to_string_lossy().into_owned())
                    .unwrap_or_default();
                return (path, label);
            }
        }
    }
    let directory = executable
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("/"));
    (directory, "cherry-dev".to_string())
}

fn fnv1a(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 14_695_981_039_346_656_037;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(1_099_511_628_211);
    }
    hash
}

/// Letters, digits, `.`, `_` and `-` kept, every other run one `-`; then
/// `.`, `-` and `_` trimmed at both ends, at most 48 characters, else
/// "default".
fn sanitized_component(value: &str) -> String {
    let mut output = String::new();
    for character in value.chars() {
        if character.is_alphanumeric() || matches!(character, '.' | '_' | '-') {
            output.push(character);
        } else if !output.ends_with('-') {
            output.push('-');
        }
    }
    let trimmed: String = output
        .trim_matches(|character| matches!(character, '.' | '-' | '_'))
        .chars()
        .take(48)
        .collect();
    if trimmed.is_empty() {
        "default".to_string()
    } else {
        trimmed
    }
}

// MARK: The connection

fn not_private(reason: impl std::fmt::Display) -> ControlError {
    ControlError::new(
        "socket_not_private",
        format!("Cherry's control socket is not private to this user: {reason}."),
    )
}

/// Only a socket of this user's, in a directory no one else may enter, and
/// only while the process behind it is this user's (`UnixIO`'s rules): an
/// answer from another account's socket would steer the agent.
fn connect(path: &Path) -> Result<UnixStream, ControlError> {
    let unavailable = || {
        ControlError::new(
            "cherry_unavailable",
            format!(
                "Could not connect to Cherry at {}. Make sure the Cherry app is running.",
                path.display()
            ),
        )
    };
    let euid = cherry_protocol::euid();
    let directory = path.parent().unwrap_or_else(|| Path::new("/"));
    match std::fs::symlink_metadata(directory) {
        Err(error)
            if error.kind() == io::ErrorKind::NotFound
                || error.raw_os_error() == Some(libc::ENOTDIR) =>
        {
            return Err(unavailable())
        }
        Err(error) => {
            return Err(not_private(format!(
                "{} cannot be looked at ({error})",
                directory.display()
            )))
        }
        Ok(metadata) => {
            if !metadata.is_dir() {
                return Err(not_private(format!(
                    "{} is not a real directory",
                    directory.display()
                )));
            }
            if metadata.uid() != euid {
                return Err(not_private(format!(
                    "{} is owned by uid {}, not this user; another account may have created it. Remove it or set {SOCKET_ENVIRONMENT_KEY} to a private path",
                    directory.display(),
                    metadata.uid()
                )));
            }
            if metadata.mode() & 0o077 != 0 {
                return Err(not_private(format!(
                    "{} must be private (mode 0700, not {:o})",
                    directory.display(),
                    metadata.mode() & 0o777
                )));
            }
        }
    }
    // Links are followed: a forward from another Mac can be a link inside
    // a private directory (only this user can put one there).
    match std::fs::metadata(path) {
        Ok(metadata) => {
            if !metadata.file_type().is_socket() || metadata.uid() != euid {
                return Err(not_private(format!(
                    "{} is not a socket owned by this user",
                    path.display()
                )));
            }
        }
        Err(error)
            if error.kind() == io::ErrorKind::NotFound
                || error.raw_os_error() == Some(libc::ENOTDIR) => {}
        Err(error) => {
            return Err(not_private(format!(
                "{} cannot be looked at ({error})",
                path.display()
            )))
        }
    }
    let stream = UnixStream::connect(path).map_err(|_| unavailable())?;
    match cherry_protocol::peer_uid(&stream) {
        Ok(uid) if uid == euid => Ok(stream),
        Ok(uid) => Err(not_private(format!(
            "the process listening on {} is uid {uid}, not this user",
            path.display()
        ))),
        Err(_) => Err(not_private(format!(
            "the process listening on {} could not be identified",
            path.display()
        ))),
    }
}

#[cfg(target_os = "macos")]
fn set_no_sigpipe(stream: &UnixStream) {
    use std::os::unix::io::AsRawFd;
    let value: libc::c_int = 1;
    unsafe {
        libc::setsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_NOSIGPIPE,
            (&value as *const libc::c_int).cast(),
            std::mem::size_of::<libc::c_int>() as libc::socklen_t,
        );
    }
}

#[cfg(not(target_os = "macos"))]
fn set_no_sigpipe(_stream: &UnixStream) {}

fn is_timeout(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
    )
}

/// Sends `request` as one line, then reads the one answer line.
fn send_line(path: &Path, request: &Value) -> Result<Value, ControlError> {
    let mut stream = connect(path)?;
    set_no_sigpipe(&stream);
    let socket_failed = || {
        ControlError::new(
            "socket_failed",
            "Failed to configure Cherry control socket timeout.",
        )
    };
    stream
        .set_read_timeout(Some(READ_TIMEOUT))
        .map_err(|_| socket_failed())?;
    stream
        .set_write_timeout(Some(WRITE_TIMEOUT))
        .map_err(|_| socket_failed())?;

    let mut line = serde_json::to_vec(request)
        .map_err(|error| ControlError::new("invalid_request", error.to_string()))?;
    line.push(b'\n');
    match stream.write_all(&line) {
        Ok(()) => {}
        // The app answered and closed early: read its answer.
        Err(error) if error.kind() == io::ErrorKind::BrokenPipe => {}
        Err(error) if is_timeout(&error) => {
            return Err(ControlError::new(
                "request_timed_out",
                "Timed out writing Cherry control request.",
            ))
        }
        Err(_) => {
            return Err(ControlError::new(
                "write_failed",
                "Failed to write Cherry control request.",
            ))
        }
    }
    let _ = stream.shutdown(std::net::Shutdown::Write);

    let mut answer = Vec::new();
    let mut buffer = [0u8; 8192];
    loop {
        match stream.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => {
                answer.extend_from_slice(&buffer[..count]);
                if answer.last() == Some(&b'\n') {
                    break;
                }
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) if is_timeout(&error) => {
                return Err(ControlError::new(
                    "request_timed_out",
                    "Timed out waiting for Cherry response.",
                ))
            }
            Err(_) => {
                return Err(ControlError::new(
                    "read_failed",
                    "Failed to read Cherry response.",
                ))
            }
        }
    }
    if answer.last() == Some(&b'\n') {
        answer.pop();
    }
    if answer.is_empty() {
        return Err(ControlError::new(
            "empty_response",
            "Cherry closed the control connection without a response.",
        ));
    }
    serde_json::from_slice(&answer).map_err(|error| {
        ControlError::new(
            "unexpected_response",
            format!("Cherry's answer is not JSON: {error}"),
        )
    })
}

/// The command's answer, or the app's error: `invalid_request` from an app
/// that cannot decode `runCommand` says it predates it.
pub fn parse_answer(answer: Value) -> Result<CommandAnswer, ControlError> {
    if let Some(error) = answer.get("error").and_then(Value::as_object) {
        let code = error
            .get("code")
            .and_then(Value::as_str)
            .unwrap_or("error")
            .to_string();
        if code == "invalid_request" {
            return Err(ControlError::new(
                "cherry_outdated",
                "This Cherry app predates cherry's agent commands (control protocol 3); update Cherry.",
            ));
        }
        let message = error
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let rest: Map<String, Value> = error
            .iter()
            .filter(|(key, _)| key.as_str() != "code" && key.as_str() != "message")
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect();
        return Err(ControlError {
            code,
            message,
            rest: (!rest.is_empty()).then(|| Value::Object(rest).to_string()),
        });
    }
    let Some(result) = answer
        .pointer("/result/runCommand/_0")
        .and_then(Value::as_object)
    else {
        return Err(ControlError::new(
            "unexpected_response",
            "Cherry returned an unexpected response for runCommand.",
        ));
    };
    let text = |key: &str| {
        result
            .get(key)
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string()
    };
    Ok(CommandAnswer {
        standard_output: text("standardOutput"),
        standard_error: text("standardError"),
        exit_code: result.get("exitCode").and_then(Value::as_i64).unwrap_or(1),
        needs_standard_input: result
            .get("needsStandardInput")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        needs_files: result
            .get("needsFiles")
            .and_then(Value::as_array)
            .map(|paths| {
                paths
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default(),
        needs_paths: result
            .get("needsPaths")
            .and_then(Value::as_array)
            .map(|paths| {
                paths
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default(),
        operations: match result.get("operations") {
            None | Some(Value::Null) => None,
            Some(value) => Some(parse_operations(value)?),
        },
    })
}

fn parse_operations(value: &Value) -> Result<Vec<Operation>, ControlError> {
    let invalid = || {
        ControlError::new(
            "unexpected_response",
            "Cherry handed file operations this cherry cannot read.",
        )
    };
    let list = value.as_array().ok_or_else(invalid)?;
    list.iter()
        .map(|operation| {
            let kind = match operation.get("kind").and_then(Value::as_str) {
                Some("createDirectory") => OperationKind::CreateDirectory,
                Some("write") => OperationKind::Write,
                Some("remove") => OperationKind::Remove,
                _ => return Err(invalid()),
            };
            let path = operation
                .get("path")
                .and_then(Value::as_str)
                .ok_or_else(invalid)?;
            Ok(Operation {
                group: operation.get("group").and_then(Value::as_i64).unwrap_or(0),
                kind,
                path: path.to_string(),
                contents: operation
                    .get("contents")
                    .and_then(Value::as_str)
                    .map(str::to_string),
            })
        })
        .collect()
}

/// An exit status as this process can give it: 0…255, a negative one 1.
fn exit_status(code: i64) -> u8 {
    if code < 0 {
        1
    } else {
        code.min(255) as u8
    }
}

/// Runs one agent command (the words after `cherry`) and says the exit
/// status to give.
pub fn run(arguments: &[OsString]) -> u8 {
    let words: Vec<String> = arguments
        .iter()
        .map(|word| word.to_string_lossy().into_owned())
        .collect();
    let caller = Caller::current();
    let mut read_standard_input = || {
        let mut bytes = Vec::new();
        let _ = io::stdin().read_to_end(&mut bytes);
        String::from_utf8_lossy(&bytes).into_owned()
    };
    let read_file = |path: &str| {
        std::fs::read(path)
            .ok()
            .and_then(|bytes| String::from_utf8(bytes).ok())
    };
    match caller.run(&words, &mut read_standard_input, &read_file) {
        Ok(answer) => {
            let mut stdout = io::stdout();
            let _ = stdout.write_all(answer.standard_output.as_bytes());
            let _ = stdout.flush();
            let mut stderr = io::stderr();
            let _ = stderr.write_all(answer.standard_error.as_bytes());
            let _ = stderr.flush();
            exit_status(answer.exit_code)
        }
        Err(error) => {
            eprintln!("{}", error.line());
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn lookup(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let map: HashMap<String, String> = pairs
            .iter()
            .map(|(key, value)| (key.to_string(), value.to_string()))
            .collect();
        move |name: &str| map.get(name).cloned()
    }

    #[test]
    fn namespaces_match_the_apps() {
        // From CherryControl.socketNamespace (Swift), for these executables.
        let cases = [
            (
                "/Applications/Cherry.app/Contents/MacOS/cherry",
                "Cherry-3a09121f2b14",
            ),
            (
                "/Users/me/dist/CherryDev.app/Contents/MacOS/cherry",
                "CherryDev-39ecc197c360",
            ),
            (
                "/Users/me/x/Host/target/debug/cherry",
                "cherry-dev-aadcb68ce811",
            ),
            (
                "/tmp/My Cherry (2).APP/Contents/MacOS/cherry",
                "My-Cherry-2-2aa3c325ca0e",
            ),
        ];
        let none = lookup(&[]);
        for (executable, expected) in cases {
            assert_eq!(
                socket_namespace(&none, Some(Path::new(executable))),
                expected,
                "{executable}"
            );
        }
        let named = lookup(&[(SOCKET_NAMESPACE_ENVIRONMENT_KEY, "  a b//c.. ")]);
        assert_eq!(socket_namespace(&named, None), "a-b-c");
        assert_eq!(sanitized_component("___"), "default");
        assert_eq!(sanitized_component("é-x"), "é-x");
    }

    #[test]
    fn the_socket_comes_from_the_environment_unless_empty() {
        let executable = Path::new("/Applications/Cherry.app/Contents/MacOS/cherry");
        let set = lookup(&[(SOCKET_ENVIRONMENT_KEY, " /tmp/p/control.sock ")]);
        assert_eq!(
            socket_path(&set, Some(executable)),
            PathBuf::from("/tmp/p/control.sock")
        );
        let empty = lookup(&[(SOCKET_ENVIRONMENT_KEY, "")]);
        let uid = unsafe { libc::getuid() };
        assert_eq!(
            socket_path(&empty, Some(executable)),
            PathBuf::from(format!(
                "/tmp/cherry-{uid}/Cherry-3a09121f2b14/control.sock"
            ))
        );
    }

    #[test]
    fn uuids_are_foundations() {
        assert!(is_uuid("3F2A0000-1111-2222-3333-444455556666"));
        assert!(is_uuid("3f2a0000-1111-2222-3333-444455556666"));
        assert!(!is_uuid("3F2A00001111222233334444555566 66"));
        assert!(!is_uuid("{3F2A0000-1111-2222-3333-444455556666}"));
        assert!(!is_uuid("web"));
    }

    #[test]
    fn a_this_mac_request() {
        let id = "3F2A0000-1111-2222-3333-444455556666";
        let caller = Caller::from(
            &lookup(&[
                (PROCESS_ID_ENVIRONMENT_KEY, &format!(" {id} ")),
                (PROJECT_ROOT_ENVIRONMENT_KEY, "/p"),
                ("HOME", "/Users/me"),
                ("CODEX_HOME", "/c"),
                ("UNRELATED", "x"),
            ]),
            None,
            Some("/p/src".into()),
            false,
            true,
        );
        assert_eq!(caller.credentials, None);
        let request = caller.request(&["send".into(), "web".into()], &Supplied::default());
        assert_eq!(
            request,
            json!({"runCommand": {"_0": {
                "arguments": ["send", "web"],
                "context": {"callerProcessID": id, "projectRoot": "/p", "workingDirectory": "/p/src", "interface": "cli"},
                "standardOutputIsTerminal": false,
                "standardInputIsPiped": true,
                "environment": {"HOME": "/Users/me", "CODEX_HOME": "/c"},
                "cliBuild": cherry_protocol::BUILD,
            }}})
        );

        let supplied = Supplied {
            standard_input: Some("text\n".into()),
            files: vec![("s.json".into(), Some("{}".into())), ("gone".into(), None)],
            ..Supplied::default()
        };
        let command = &caller.request(&[], &supplied)["runCommand"]["_0"];
        assert_eq!(command["standardInput"], json!("text\n"));
        assert_eq!(
            command["files"],
            json!([{"path": "s.json", "contents": "{}"}, {"path": "gone"}])
        );
    }

    #[test]
    fn a_device_request_has_its_token() {
        // A tab id that is no UUID is still the token's id, but no claim.
        let caller = Caller::from(
            &lookup(&[
                (TOKEN_ENVIRONMENT_KEY, " abc "),
                (AGENT_ID_ENVIRONMENT_KEY, "tab-1"),
                (CONTROL_MACHINE_ENVIRONMENT_KEY, "patmini"),
            ]),
            None,
            None,
            true,
            false,
        );
        let request = caller.request(&["ls".into()], &Supplied::default());
        assert_eq!(
            request["cherryAuth"],
            json!({"token": "abc", "processID": "tab-1"})
        );
        assert_eq!(
            request["request"]["runCommand"]["_0"]["arguments"],
            json!(["ls"])
        );
        assert_eq!(
            request["request"]["runCommand"]["_0"]["context"],
            json!({"interface": "cli"})
        );
        assert_eq!(caller.control_machine.as_deref(), Some("patmini"));

        // An empty CHERRY_PROCESS_ID hides CHERRY_AGENT_ID, as Swift's `??` does.
        let caller = Caller::from(
            &lookup(&[
                (TOKEN_ENVIRONMENT_KEY, "abc"),
                (PROCESS_ID_ENVIRONMENT_KEY, " "),
                (AGENT_ID_ENVIRONMENT_KEY, "tab-1"),
            ]),
            None,
            None,
            true,
            false,
        );
        assert_eq!(caller.credentials, None);
    }

    #[test]
    fn answers_and_errors() {
        let answer = parse_answer(json!({"result": {"runCommand": {"_0": {
            "standardOutput": "out", "standardError": "", "exitCode": 2, "needsFiles": ["a"]
        }}}}))
        .unwrap();
        assert_eq!(answer.standard_output, "out");
        assert_eq!(answer.exit_code, 2);
        assert_eq!(answer.needs_files, vec!["a".to_string()]);
        assert!(!answer.needs_standard_input);

        let error = parse_answer(json!({"error": {"code": "invalid_request", "message": "x"}}))
            .unwrap_err();
        assert_eq!(error.code, "cherry_outdated");

        let error = parse_answer(json!({"error": {"code": "agent_awaiting_input", "message": "Pick one", "prompt": {"options": ["a"]}}})).unwrap_err();
        assert_eq!(
            error.line(),
            "agent_awaiting_input: Pick one\n{\"prompt\":{\"options\":[\"a\"]}}"
        );

        let error = parse_answer(json!({"result": {"callTool": {}}})).unwrap_err();
        assert_eq!(error.code, "unexpected_response");

        assert_eq!(exit_status(-3), 1);
        assert_eq!(exit_status(300), 255);
        assert_eq!(exit_status(7), 7);
    }

    fn set_mode(path: &Path, mode: u32) {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
    }

    #[test]
    fn paths_are_described_as_the_installer_looks_at_them() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path();
        let file = root.join("SKILL.md");
        std::fs::write(&file, "text").unwrap();
        let folder = root.join("skills");
        std::fs::create_dir(&folder).unwrap();
        std::fs::write(folder.join("b"), "").unwrap();
        std::fs::write(folder.join("a"), "").unwrap();
        let link = root.join("link");
        std::os::unix::fs::symlink(&folder, &link).unwrap();
        let tool = root.join("claude");
        std::fs::write(&tool, "#!/bin/sh\n").unwrap();
        set_mode(&tool, 0o755);

        let described = describe_path(&file.to_string_lossy());
        assert_eq!(
            (
                described.entry,
                described.target,
                described.executable,
                described.entries
            ),
            ("file", "file", false, None)
        );
        let described = describe_path(&folder.to_string_lossy());
        assert_eq!(
            (described.entry, described.target),
            ("directory", "directory")
        );
        assert_eq!(
            described.entries,
            Some(vec!["a".to_string(), "b".to_string()])
        );
        let described = describe_path(&link.to_string_lossy());
        assert_eq!((described.entry, described.target), ("link", "directory"));
        assert_eq!(
            described.entries,
            Some(vec!["a".to_string(), "b".to_string()])
        );
        let described = describe_path(&tool.to_string_lossy());
        assert!(described.executable);
        let missing = root.join("nothing/here");
        let described = describe_path(&missing.to_string_lossy());
        assert_eq!(
            (
                described.entry,
                described.target,
                described.executable,
                described.entries
            ),
            ("none", "none", false, None)
        );
        // Under a file: ENOTDIR is none too.
        let under = describe_path(&file.join("x").to_string_lossy());
        assert_eq!(under.entry, "none");
    }

    fn operation(
        group: i64,
        kind: OperationKind,
        path: &Path,
        contents: Option<&str>,
    ) -> Operation {
        Operation {
            group,
            kind,
            path: path.to_string_lossy().into_owned(),
            contents: contents.map(str::to_string),
        }
    }

    #[test]
    fn operations_run_in_order_and_a_group_stops_at_its_first_failure() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path();
        let skill = root.join("a/b/cherry");
        let file = skill.join("SKILL.md");
        let results = perform_operations(&[
            operation(0, OperationKind::CreateDirectory, &skill, None),
            operation(0, OperationKind::Write, &file, Some("hello\n")),
        ]);
        assert_eq!(results, vec![None, None]);
        assert_eq!(std::fs::read_to_string(&file).unwrap(), "hello\n");
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o644
        );
        // No temporary file is left beside it.
        let names: Vec<_> = std::fs::read_dir(&skill)
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        assert_eq!(names, vec![std::ffi::OsString::from("SKILL.md")]);

        let results = perform_operations(&[
            operation(1, OperationKind::Remove, &file, None),
            operation(1, OperationKind::Remove, &skill, None),
        ]);
        assert_eq!(results, vec![None, None]);
        assert!(!skill.exists());

        // A "folder" that is a file (a failure root gets too): the write
        // fails, the rest of its group is not attempted, a later group
        // still is.
        let locked = root.join("locked");
        std::fs::write(&locked, "a file").unwrap();
        let later = root.join("later.rules");
        let results = perform_operations(&[
            operation(2, OperationKind::Write, &locked.join("SKILL.md"), Some("x")),
            operation(
                2,
                OperationKind::Write,
                &locked.join(".cherry-skill"),
                Some("y"),
            ),
            operation(3, OperationKind::Write, &later, Some("rules\n")),
        ]);
        let first = results[0].clone().expect("the write fails");
        assert!(
            first.starts_with(&format!("{}: ", locked.join("SKILL.md").display())),
            "{first}"
        );
        assert!(first.contains("Not a directory"), "{first}");
        assert_eq!(results[1].as_deref(), Some(NOT_ATTEMPTED));
        assert_eq!(results[2], None);
        assert_eq!(std::fs::read_to_string(&later).unwrap(), "rules\n");
        assert_eq!(std::fs::read_to_string(&locked).unwrap(), "a file");
    }

    #[test]
    fn a_write_replaces_a_link_never_its_target() {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path();
        let elsewhere = root.join("elsewhere.md");
        std::fs::write(&elsewhere, "theirs").unwrap();
        let link = root.join("SKILL.md");
        std::os::unix::fs::symlink(&elsewhere, &link).unwrap();
        let results =
            perform_operations(&[operation(0, OperationKind::Write, &link, Some("ours"))]);
        assert_eq!(results, vec![None]);
        assert!(!std::fs::symlink_metadata(&link)
            .unwrap()
            .file_type()
            .is_symlink());
        assert_eq!(std::fs::read_to_string(&link).unwrap(), "ours");
        assert_eq!(std::fs::read_to_string(&elsewhere).unwrap(), "theirs");
    }

    #[test]
    fn paths_operations_and_their_results_are_sent_and_read() {
        let caller = Caller::from(&lookup(&[]), None, None, false, false);
        let supplied = Supplied {
            paths: vec![PathDescription {
                path: "/h/.claude".into(),
                entry: "link",
                target: "directory",
                executable: false,
                entries: Some(vec!["skills".into()]),
            }],
            operation_results: Some(vec![
                None,
                Some("/x: Permission denied (os error 13)".into()),
            ]),
            ..Supplied::default()
        };
        let command = &caller.request(&[], &supplied)["runCommand"]["_0"];
        assert_eq!(
            command["paths"],
            json!([{"path": "/h/.claude", "entry": "link", "target": "directory", "executable": false, "entries": ["skills"]}])
        );
        assert_eq!(
            command["operationResults"],
            json!([{}, {"error": "/x: Permission denied (os error 13)"}])
        );
        let empty = &caller.request(&[], &Supplied::default())["runCommand"]["_0"];
        assert!(empty.get("paths").is_none() && empty.get("operationResults").is_none());

        let answer = parse_answer(json!({"result": {"runCommand": {"_0": {
            "standardOutput": "", "standardError": "", "exitCode": 0,
            "needsPaths": ["/h/.claude"],
            "operations": [
                {"group": 1, "kind": "createDirectory", "path": "/h/s"},
                {"group": 1, "kind": "write", "path": "/h/s/SKILL.md", "contents": "x"},
                {"group": 2, "kind": "remove", "path": "/h/r"}
            ]
        }}}}))
        .unwrap();
        assert_eq!(answer.needs_paths, vec!["/h/.claude".to_string()]);
        let operations = answer.operations.unwrap();
        assert_eq!(operations.len(), 3);
        assert_eq!(operations[1].kind, OperationKind::Write);
        assert_eq!(operations[1].contents.as_deref(), Some("x"));
        assert_eq!(operations[2].group, 2);
        let bad = parse_answer(json!({"result": {"runCommand": {"_0": {
            "exitCode": 0, "operations": [{"kind": "chmod", "path": "/x"}]
        }}}}));
        assert_eq!(bad.unwrap_err().code, "unexpected_response");
    }
}
