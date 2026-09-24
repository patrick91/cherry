//! Versioned, length-prefixed protocol shared by the local socket and SSH gateway.
//!
//! Client and host must run the same `PROTOCOL_VERSION`; a mismatch is reported
//! as `version_mismatch` and nothing else happens on that connection. There is
//! no compatibility with older protocol versions.
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    ffi::OsStr,
    io::{self, Read, Write},
    os::unix::{
        fs::{FileTypeExt, MetadataExt},
        io::AsRawFd,
        net::UnixStream,
    },
    path::{Path, PathBuf},
    time::Duration,
};

pub const PROTOCOL_VERSION: u32 = 3;
pub const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_INPUT_BYTES: usize = 64 * 1024;
/// Snapshots are base64 inside JSON (4/3 expansion). Keep the raw bytes well
/// below the frame limit so an attach can never exceed it.
pub const MAX_SNAPSHOT_BYTES: usize = 8 * 1024 * 1024;
pub const DEFAULT_COLS: u16 = 120;
pub const DEFAULT_ROWS: u16 = 32;
/// Attached clients send `Ping` at least this often.
pub const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(15);
/// The host drops an attached client that has sent nothing for this long, so a
/// vanished laptop cannot pin the shared grid size.
pub const HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(45);

/// Error codes in `ServerMessage::Error`.
pub mod error_code {
    pub const VERSION_MISMATCH: &str = "version_mismatch";
    pub const REQUEST_FAILED: &str = "request_failed";
    pub const TAKEN_OVER: &str = "taken_over";
    /// Non-fatal while attached: the canonical size could not change.
    pub const RESIZE_FAILED: &str = "resize_failed";
    pub const SNAPSHOT_FAILED: &str = "snapshot_failed";
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionInfo {
    pub id: String,
    pub name: String,
    pub cwd: String,
    pub command: Vec<String>,
    pub cols: u16,
    pub rows: u16,
    pub state: SessionState,
    pub pid: Option<u32>,
    /// Exit status; 128 + signal number when the process was killed by a signal.
    pub exit_code: Option<u32>,
    pub attached: bool,
    /// Terminating signal, when the process did not exit normally.
    pub exit_signal: Option<i32>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SessionState {
    Running,
    Exited,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionList {
    pub host_id: String,
    pub sessions: Vec<SessionInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum ClientMessage {
    Hello {
        version: u32,
    },
    List,
    Create {
        request_id: String,
        name: String,
        cwd: String,
        command: Vec<String>,
        #[serde(default)]
        env: BTreeMap<String, String>,
        cols: u16,
        rows: u16,
    },
    Attach {
        id: String,
        cols: u16,
        rows: u16,
        /// Disconnect every other attachment first.
        takeover: bool,
        /// Whether the client's terminal answers the queries it is sent
        /// (`ServerMessage::Query`): the client writes them to a terminal
        /// whose replies it reads as input. A client whose input or output
        /// is not that terminal (a script, a pipe) is sent none.
        answers_queries: bool,
    },
    Input {
        #[serde(with = "base64_bytes")]
        data: Vec<u8>,
    },
    Resize {
        cols: u16,
        rows: u16,
    },
    Detach,
    /// Liveness probe; the host answers `Pong`.
    Ping,
    Kill {
        id: String,
    },
    /// Forget a completed session; running sessions must be terminated first.
    Remove {
        id: String,
    },
    /// A host with live sessions refuses shutdown.
    Shutdown,
}

impl ClientMessage {
    pub fn hello() -> Self {
        Self::Hello {
            version: PROTOCOL_VERSION,
        }
    }
}

/// Why the host sent an `Attached` snapshot.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AttachReason {
    /// Reply to this connection's `Attach`.
    Attach,
    /// The shared grid size changed.
    Resize,
    /// This client fell behind; its queued output was dropped.
    Resync,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    Welcome {
        version: u32,
        host_id: String,
    },
    Sessions {
        host_id: String,
        sessions: Vec<SessionInfo>,
    },
    Created {
        session: SessionInfo,
    },
    Attached {
        /// Initial attachment or an atomic replacement snapshot after the
        /// shared terminal grid changes or a lagging client is resynchronized.
        /// Subsequent Output resumes at offset.
        session: SessionInfo,
        offset: u64,
        #[serde(with = "base64_bytes")]
        snapshot: Vec<u8>,
        reason: AttachReason,
    },
    /// offset is the first byte position of this chunk, not its end.
    Output {
        offset: u64,
        #[serde(with = "base64_bytes")]
        data: Vec<u8>,
    },
    /// Terminal queries the host does not answer itself (a cursor report,
    /// a clipboard read, colour or window reports, capabilities it does not
    /// know). The client writes them to its terminal, whose replies come back
    /// as ordinary `Input`. They are live only: not part of the output
    /// stream (no offset) or of any snapshot. Each goes to one attached
    /// client, in order with its output. Of the clients that answer queries
    /// (`ClientMessage::Attach`), that is the one that most recently sent
    /// input, or else the most recently attached one. While no such client
    /// is attached they are dropped.
    Query {
        #[serde(with = "base64_bytes")]
        data: Vec<u8>,
    },
    Exit {
        id: String,
        exit_code: u32,
        signal: Option<i32>,
    },
    Pong,
    Ok,
    Error {
        code: String,
        message: String,
    },
}

impl ServerMessage {
    pub fn error(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self::Error {
            code: code.into(),
            message: message.into(),
        }
    }
}

pub fn valid_size(cols: u16, rows: u16) -> bool {
    (2..=500).contains(&cols) && (1..=200).contains(&rows)
}

pub fn default_socket_path() -> PathBuf {
    if let Some(path) = std::env::var_os("CHERRY_HOST_SOCKET") {
        return path.into();
    }
    // A short path also fits sockaddr_un on macOS. This directory must be 0700;
    // clients verify ownership before trusting it (see `verify_socket_path`).
    PathBuf::from(format!("/tmp/cherry-host-{}/host.sock", unsafe {
        libc::geteuid()
    }))
}

fn euid() -> u32 {
    unsafe { libc::geteuid() }
}

/// The directory must exist, not be a symlink, be owned by this user and be
/// inaccessible to others. Another user can create a predictable /tmp path
/// first; a client must never trust a socket inside such a directory.
pub fn verify_private_dir(dir: &Path) -> io::Result<()> {
    let meta = std::fs::symlink_metadata(dir)?;
    if meta.file_type().is_symlink() || !meta.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("{} is not a real directory", dir.display()),
        ));
    }
    if meta.uid() != euid() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!(
                "{} is owned by uid {}, not this user; another account may have created it. Remove it or set CHERRY_HOST_SOCKET to a private path",
                dir.display(),
                meta.uid()
            ),
        ));
    }
    if meta.mode() & 0o077 != 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("{} must be private (mode 0700)", dir.display()),
        ));
    }
    Ok(())
}

/// Verify the socket's directory and, when present, the socket file itself.
pub fn verify_socket_path(path: &Path) -> io::Result<()> {
    if !path.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "socket path must be absolute",
        ));
    }
    let dir = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "socket needs a parent directory",
        )
    })?;
    verify_private_dir(dir)?;
    match std::fs::symlink_metadata(path) {
        Ok(meta) => {
            if !meta.file_type().is_socket() || meta.uid() != euid() {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    format!("{} is not a socket owned by this user", path.display()),
                ));
            }
            Ok(())
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}

/// The effective uid of the process on the other end of a Unix socket.
#[cfg(target_os = "linux")]
pub fn peer_uid(stream: &UnixStream) -> io::Result<u32> {
    unsafe {
        let mut credentials: libc::ucred = std::mem::zeroed();
        let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
        if libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut len,
        ) != 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(credentials.uid)
    }
}

/// The effective uid of the process on the other end of a Unix socket.
#[cfg(target_os = "macos")]
pub fn peer_uid(stream: &UnixStream) -> io::Result<u32> {
    unsafe {
        let mut uid = 0;
        let mut gid = 0;
        if libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(uid)
    }
}

/// Both ends of every host connection must belong to the same user.
pub fn verify_peer(stream: &UnixStream) -> io::Result<()> {
    let uid = peer_uid(stream)?;
    if uid != euid() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("socket peer is uid {uid}, not this user"),
        ));
    }
    Ok(())
}

/// Connect to a host socket only after verifying its directory, the socket
/// file and the listening process all belong to this user.
pub fn connect_verified(path: &Path) -> io::Result<UnixStream> {
    verify_socket_path(path)?;
    let stream = UnixStream::connect(path)?;
    verify_peer(&stream)?;
    Ok(stream)
}

/// Name of the stable agent-socket link in the directory that holds the
/// host's socket (the `state_dir` of `update_agent_link`). Sessions receive
/// `SSH_AUTH_SOCK=<that directory>/agent.sock`. Like tmux's
/// update-environment, the link follows the clients that use sessions: the
/// local CLI repoints it at the caller's agent only for `new` and `attach`,
/// and the SSH gateway repoints it on every connection at the agent forwarded
/// to it, which the CLI forwards only for `attach` (other commands run
/// `ssh -a`). A client's agent is only lent while that client uses sessions:
/// a moment after its last connection ends (it may connect again, or hand
/// over to the next client, as `new` does to `attach`), the daemon calls
/// `release_agent_link`, and the link goes back to the agent of a client that
/// still lends one, or is removed. An agent that disappears is given up
/// within a second, even while its client stays connected. An agent path left
/// behind could be recreated by another local user once its owner removes it
/// (sshd removes a forwarded agent's /tmp directory, for example).
pub const AGENT_LINK_NAME: &str = "agent.sock";

/// Directory beside the link that records which client lent which agent: an
/// entry named after the client's process ID is a symlink to its agent.
pub const AGENT_CLIENTS_DIR: &str = "agent-clients";

/// Atomically repoint `<state_dir>/agent.sock` at `agent`, and record this
/// process as the client lending it, when `agent` is an existing socket owned
/// by this user that does not lead back to the link. Errors are ignored by
/// callers: agent forwarding is a convenience, never a reason to fail a
/// connection.
pub fn update_agent_link(state_dir: &Path, agent: Option<&OsStr>) -> io::Result<()> {
    lend_agent(state_dir, agent, std::process::id())
}

fn lend_agent(state_dir: &Path, agent: Option<&OsStr>, client: u32) -> io::Result<()> {
    let Some(agent) = agent.filter(|a| !a.is_empty()) else {
        return Ok(());
    };
    let agent = Path::new(agent);
    if !agent.is_absolute() || !is_own_socket(agent) {
        return Ok(());
    }
    verify_private_dir(state_dir)?;
    let link = state_dir.join(AGENT_LINK_NAME);
    // Never point the link at itself, however the path to it is spelled (a
    // symlinked directory, /tmp against /private/tmp) or linked.
    if leads_through(agent, &link) {
        return Ok(());
    }
    let clients = agent_clients(state_dir)?;
    let _lock = lock_agent_clients(&clients)?;
    replace_symlink(&clients.join(client.to_string()), agent)?;
    if std::fs::read_link(&link).is_ok_and(|current| current == agent) {
        return Ok(());
    }
    replace_symlink(&link, agent)
}

/// Forget the clients that no longer lend their agent: those for which
/// `lends(pid)` is false, and those whose agent is no longer a socket owned
/// by this user. The link keeps an agent that a remaining client lends;
/// otherwise it moves to the most recently lent remaining agent, or is
/// removed. `lends` is asked while the records are locked, so a client that
/// lends its agent at the same time does so before or after the whole
/// release, never in the middle of it.
pub fn release_agent_link(state_dir: &Path, lends: impl Fn(u32) -> bool) -> io::Result<()> {
    verify_private_dir(state_dir)?;
    let link = state_dir.join(AGENT_LINK_NAME);
    // Created before any agent is lent: without it, there is nothing to do.
    match std::fs::symlink_metadata(state_dir.join(AGENT_CLIENTS_DIR)) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        _ => {}
    }
    let clients = agent_clients(state_dir)?;
    let _lock = lock_agent_clients(&clients)?;
    let mut lent = Vec::new();
    for entry in std::fs::read_dir(&clients)? {
        let entry = entry?;
        // Skips the lock and temporary files.
        let Some(pid) = entry
            .file_name()
            .to_str()
            .and_then(|name| name.parse::<u32>().ok())
        else {
            continue;
        };
        let path = entry.path();
        let agent = std::fs::read_link(&path)
            .ok()
            .filter(|agent| is_own_socket(agent) && lends(pid));
        match agent {
            Some(agent) => {
                let lent_at = std::fs::symlink_metadata(&path)
                    .and_then(|meta| meta.modified())
                    .ok();
                lent.push((lent_at, agent));
            }
            None => remove_if_present(&path)?,
        }
    }
    let current = std::fs::read_link(&link).ok();
    if current.is_some_and(|current| lent.iter().any(|(_, agent)| *agent == current)) {
        return Ok(());
    }
    match lent.into_iter().max_by(|a, b| a.0.cmp(&b.0)) {
        Some((_, agent)) => replace_symlink(&link, &agent),
        None => remove_if_present(&link),
    }
}

/// An existing socket (after following links) owned by this user.
fn is_own_socket(path: &Path) -> bool {
    std::fs::metadata(path).is_ok_and(|meta| meta.file_type().is_socket() && meta.uid() == euid())
}

/// Whether resolving `path` passes through the file at `link` itself.
fn leads_through(path: &Path, link: &Path) -> bool {
    let Ok(meta) = std::fs::symlink_metadata(link) else {
        return false;
    };
    let target = (meta.dev(), meta.ino());
    let mut current = path.to_path_buf();
    // Like the kernel, give up on a chain this long: it cannot be used.
    for _ in 0..40 {
        let Ok(meta) = std::fs::symlink_metadata(&current) else {
            return false;
        };
        if (meta.dev(), meta.ino()) == target {
            return true;
        }
        if !meta.file_type().is_symlink() {
            return false;
        }
        let Ok(next) = std::fs::read_link(&current) else {
            return false;
        };
        // An absolute target replaces the path; a relative one is resolved
        // from the link's directory.
        current = match current.parent() {
            Some(parent) => parent.join(next),
            None => next,
        };
    }
    true
}

/// `<state_dir>/agent-clients`, created private on first use.
fn agent_clients(state_dir: &Path) -> io::Result<PathBuf> {
    use std::os::unix::fs::DirBuilderExt;
    let clients = state_dir.join(AGENT_CLIENTS_DIR);
    match std::fs::DirBuilder::new().mode(0o700).create(&clients) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }
    verify_private_dir(&clients)?;
    Ok(clients)
}

/// Serializes changes to the link and the client records between clients
/// and the daemon. Released when the file is dropped.
fn lock_agent_clients(clients: &Path) -> io::Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(clients.join(".lock"))?;
    loop {
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } == 0 {
            return Ok(file);
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

/// Atomically make `path` a symlink to `target`.
fn replace_symlink(path: &Path, target: &Path) -> io::Result<()> {
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    let temporary = path.with_file_name(format!(".{name}.{}.tmp", std::process::id()));
    let _ = std::fs::remove_file(&temporary);
    std::os::unix::fs::symlink(target, &temporary)?;
    std::fs::rename(&temporary, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&temporary);
    })
}

fn remove_if_present(path: &Path) -> io::Result<()> {
    match std::fs::remove_file(path) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
        _ => Ok(()),
    }
}

pub fn write_frame<W: Write, T: Serialize>(writer: &mut W, value: &T) -> io::Result<()> {
    let bytes = encode_frame(value)?;
    writer.write_all(&bytes)?;
    writer.flush()
}

/// A complete frame (length prefix + JSON), for callers that queue bytes.
pub fn encode_frame<T: Serialize>(value: &T) -> io::Result<Vec<u8>> {
    let body =
        serde_json::to_vec(value).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    if body.len() > MAX_FRAME_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame exceeds limit",
        ));
    }
    let mut frame = Vec::with_capacity(4 + body.len());
    frame.extend_from_slice(&(body.len() as u32).to_be_bytes());
    frame.extend_from_slice(&body);
    Ok(frame)
}

pub fn read_frame<R: Read, T: DeserializeOwned>(reader: &mut R) -> io::Result<Option<T>> {
    let mut header = [0u8; 4];
    loop {
        match reader.read(&mut header[..1]) {
            Ok(0) => return Ok(None),
            Ok(_) => break,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    reader.read_exact(&mut header[1..])?;
    let len = u32::from_be_bytes(header) as usize;
    if len == 0 || len > MAX_FRAME_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid frame length",
        ));
    }
    let mut bytes = vec![0; len];
    reader.read_exact(&mut bytes)?;
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

/// Terminal bytes travel as standard base64 strings (4/3 expansion) instead of
/// JSON number arrays (3–4x expansion).
pub mod base64_bytes {
    use serde::{de::Error, Deserialize, Deserializer, Serializer};

    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    pub fn encode(bytes: &[u8]) -> String {
        let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
        for chunk in bytes.chunks(3) {
            let b = [
                chunk[0],
                *chunk.get(1).unwrap_or(&0),
                *chunk.get(2).unwrap_or(&0),
            ];
            let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
            out.push(ALPHABET[(n >> 18) as usize & 63] as char);
            out.push(ALPHABET[(n >> 12) as usize & 63] as char);
            out.push(if chunk.len() > 1 {
                ALPHABET[(n >> 6) as usize & 63] as char
            } else {
                '='
            });
            out.push(if chunk.len() > 2 {
                ALPHABET[n as usize & 63] as char
            } else {
                '='
            });
        }
        out
    }

    pub fn decode(text: &str) -> Result<Vec<u8>, &'static str> {
        let text = text.as_bytes();
        if text.len() % 4 != 0 {
            return Err("base64 length is not a multiple of 4");
        }
        let mut out = Vec::with_capacity(text.len() / 4 * 3);
        for (index, chunk) in text.chunks(4).enumerate() {
            let last = index + 1 == text.len() / 4;
            let mut n = 0u32;
            let mut padding = 0;
            for (i, &c) in chunk.iter().enumerate() {
                let value = match c {
                    b'A'..=b'Z' => c - b'A',
                    b'a'..=b'z' => c - b'a' + 26,
                    b'0'..=b'9' => c - b'0' + 52,
                    b'+' => 62,
                    b'/' => 63,
                    b'=' if last && i >= 2 => {
                        padding += 1;
                        0
                    }
                    _ => return Err("invalid base64"),
                };
                if padding > 0 && c != b'=' {
                    return Err("invalid base64 padding");
                }
                n = (n << 6) | u32::from(value);
            }
            out.push((n >> 16) as u8);
            if padding < 2 {
                out.push((n >> 8) as u8);
            }
            if padding < 1 {
                out.push(n as u8);
            }
        }
        Ok(out)
    }

    pub fn serialize<S: Serializer>(bytes: &[u8], serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&encode(bytes))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Vec<u8>, D::Error> {
        let text = String::deserialize(deserializer)?;
        decode(&text).map_err(D::Error::custom)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn framing_handles_binary_payload_and_consecutive_messages() {
        let mut bytes = Vec::new();
        write_frame(
            &mut bytes,
            &ClientMessage::Input {
                data: vec![0, 255, 27],
            },
        )
        .unwrap();
        write_frame(&mut bytes, &ClientMessage::Detach).unwrap();
        let mut reader = bytes.as_slice();
        assert!(
            matches!(read_frame(&mut reader).unwrap(), Some(ClientMessage::Input {data}) if data == [0,255,27])
        );
        assert!(matches!(
            read_frame(&mut reader).unwrap(),
            Some(ClientMessage::Detach)
        ));
        assert!(read_frame::<_, ClientMessage>(&mut reader)
            .unwrap()
            .is_none());
    }
    #[test]
    fn rejects_oversize_and_truncated_frames() {
        let header = ((MAX_FRAME_BYTES + 1) as u32).to_be_bytes();
        assert!(read_frame::<_, ClientMessage>(&mut header.as_slice()).is_err());
        assert!(read_frame::<_, ClientMessage>(&mut [0u8, 0].as_slice()).is_err());
        assert!(read_frame::<_, ClientMessage>(&mut [0u8, 0, 0, 2, b'{'].as_slice()).is_err());
    }
    #[test]
    fn base64_round_trips_every_length_and_rejects_garbage() {
        for len in 0..70usize {
            let bytes: Vec<u8> = (0..len).map(|i| (i * 37 + 11) as u8).collect();
            let text = base64_bytes::encode(&bytes);
            assert_eq!(text.len(), len.div_ceil(3) * 4);
            assert_eq!(base64_bytes::decode(&text).unwrap(), bytes);
        }
        assert_eq!(base64_bytes::encode(b"foobar"), "Zm9vYmFy");
        assert_eq!(base64_bytes::encode(b"fo"), "Zm8=");
        assert!(base64_bytes::decode("Zm9").is_err());
        assert!(base64_bytes::decode("Zm=v").is_err());
        assert!(base64_bytes::decode("Z===").is_err());
        assert!(base64_bytes::decode("Zm8=Zm8=").is_err());
        assert!(base64_bytes::decode("Zm*v").is_err());
    }
    #[test]
    fn terminal_bytes_are_compact_on_the_wire() {
        let data = vec![b'x'; 3000];
        let frame = encode_frame(&ServerMessage::Output { offset: 0, data }).unwrap();
        assert!(frame.len() < 4100, "frame was {} bytes", frame.len());
        let frame = encode_frame(&ServerMessage::Query {
            data: b"\x1b[?6n".to_vec(),
        })
        .unwrap();
        assert_eq!(&frame[4..], br#"{"type":"query","data":"G1s/Nm4="}"#);
        assert!(MAX_SNAPSHOT_BYTES.div_ceil(3) * 4 + 4096 < MAX_FRAME_BYTES);
    }
    #[test]
    fn messages_without_required_fields_are_rejected() {
        assert!(serde_json::from_str::<ClientMessage>(r#"{"op":"future_thing"}"#).is_err());
        assert!(serde_json::from_str::<ClientMessage>(
            r#"{"op":"attach","id":"a","cols":80,"rows":24}"#
        )
        .is_err());
        assert!(serde_json::from_str::<ClientMessage>(
            r#"{"op":"attach","id":"a","cols":80,"rows":24,"takeover":false}"#
        )
        .is_err());
        assert!(matches!(
            serde_json::from_str::<ClientMessage>(
                r#"{"op":"attach","id":"a","cols":80,"rows":24,"takeover":false,"answers_queries":true}"#
            ),
            Ok(ClientMessage::Attach {
                answers_queries: true,
                ..
            })
        ));
    }
    #[test]
    fn private_directory_checks_reject_shared_paths() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("cherry-protocol-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir(&dir).unwrap();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(verify_private_dir(&dir).is_err());
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        verify_private_dir(&dir).unwrap();
        verify_socket_path(&dir.join("host.sock")).unwrap();
        std::fs::write(dir.join("host.sock"), b"not a socket").unwrap();
        assert!(verify_socket_path(&dir.join("host.sock")).is_err());
        let link = dir.with_extension("link");
        let _ = std::fs::remove_file(&link);
        std::os::unix::fs::symlink(&dir, &link).unwrap();
        assert!(verify_private_dir(&link).is_err());
        assert!(verify_socket_path(Path::new("relative/host.sock")).is_err());
        let _ = std::fs::remove_file(&link);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A private directory under /tmp (short enough for socket paths),
    /// removed on drop.
    struct Scratch(PathBuf);

    impl Scratch {
        fn new(name: &str) -> Self {
            use std::os::unix::fs::PermissionsExt;
            let dir = PathBuf::from(format!("/tmp/cp-{}-{name}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir(&dir).unwrap();
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
            Self(dir)
        }
    }

    impl Scratch {
        fn private(&self, name: &str) -> PathBuf {
            use std::os::unix::fs::DirBuilderExt;
            let dir = self.0.join(name);
            std::fs::DirBuilder::new().mode(0o700).create(&dir).unwrap();
            dir
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// A running child, killed on drop, standing in for a client process.
    struct Client(std::process::Child);

    impl Client {
        fn new() -> Self {
            Self(
                std::process::Command::new("/bin/sleep")
                    .arg("30")
                    .spawn()
                    .unwrap(),
            )
        }

        fn pid(&self) -> u32 {
            self.0.id()
        }
    }

    impl Drop for Client {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    #[test]
    fn the_agent_link_never_leads_back_to_itself() {
        let root = Scratch::new("self");
        let state = root.private("state");
        let agent = root.0.join("agent");
        let _listener = std::os::unix::net::UnixListener::bind(&agent).unwrap();
        let link = state.join(AGENT_LINK_NAME);
        update_agent_link(&state, Some(agent.as_os_str())).unwrap();
        assert_eq!(std::fs::read_link(&link).unwrap(), agent);
        // The link itself, through another spelling of its directory (like
        // /tmp and /private/tmp on macOS) and through another symlink.
        let alias = root.0.join("alias");
        std::os::unix::fs::symlink(&root.0, &alias).unwrap();
        let other = root.0.join("other");
        std::os::unix::fs::symlink(&link, &other).unwrap();
        for itself in [
            state.join(AGENT_LINK_NAME),
            alias.join("state").join(AGENT_LINK_NAME),
            other,
        ] {
            update_agent_link(&state, Some(itself.as_os_str())).unwrap();
            assert_eq!(std::fs::read_link(&link).unwrap(), agent, "{itself:?}");
        }
        // A relative symlink is resolved from its own directory.
        let relative = state.join("relative");
        std::os::unix::fs::symlink(AGENT_LINK_NAME, &relative).unwrap();
        update_agent_link(&state, Some(relative.as_os_str())).unwrap();
        assert_eq!(std::fs::read_link(&link).unwrap(), agent);
        std::fs::metadata(&link).unwrap();
    }

    /// As the daemon decides by default: a client lends its agent while its
    /// process runs, unless it is `released`.
    fn running_except(released: Option<u32>) -> impl Fn(u32) -> bool {
        move |pid| {
            Some(pid) != released
                && i32::try_from(pid).is_ok_and(|pid| unsafe { libc::kill(pid, 0) } == 0)
        }
    }

    #[test]
    fn a_lent_agent_is_handed_back_or_removed_once_its_client_is_gone() {
        let root = Scratch::new("lend");
        let state = root.private("state");
        let agent = |name: &str| {
            let path = root.0.join(name);
            (std::os::unix::net::UnixListener::bind(&path).unwrap(), path)
        };
        let (_first, first) = agent("a1");
        let (_second, second) = agent("a2");
        let link = state.join(AGENT_LINK_NAME);
        let current = || std::fs::read_link(&link).ok();
        let (one, two) = (Client::new(), Client::new());
        lend_agent(&state, Some(first.as_os_str()), one.pid()).unwrap();
        lend_agent(&state, Some(second.as_os_str()), two.pid()).unwrap();
        assert_eq!(current(), Some(second.clone()));
        // The most recent client leaves: back to the other client's agent.
        release_agent_link(&state, running_except(Some(two.pid()))).unwrap();
        assert_eq!(current(), Some(first.clone()));
        // A client that still lends the linked agent keeps it linked.
        let three = Client::new();
        lend_agent(&state, Some(first.as_os_str()), three.pid()).unwrap();
        release_agent_link(&state, running_except(Some(one.pid()))).unwrap();
        assert_eq!(current(), Some(first.clone()));
        // Its process exits. The caller decides whether it still lends (for
        // a moment after it leaves, say).
        drop(three);
        release_agent_link(&state, |_| true).unwrap();
        assert_eq!(current(), Some(first.clone()));
        release_agent_link(&state, running_except(None)).unwrap();
        assert_eq!(current(), None);
        // An agent that disappeared is never linked again, whoever lends it.
        let four = Client::new();
        lend_agent(&state, Some(second.as_os_str()), four.pid()).unwrap();
        let five = Client::new();
        lend_agent(&state, Some(first.as_os_str()), five.pid()).unwrap();
        std::fs::remove_file(&second).unwrap();
        release_agent_link(&state, |pid| pid != five.pid()).unwrap();
        assert_eq!(current(), None);
        let clients = state.join(AGENT_CLIENTS_DIR);
        let left: Vec<_> = std::fs::read_dir(&clients)
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .filter(|name| !name.to_string_lossy().starts_with('.'))
            .collect();
        assert!(left.is_empty(), "{left:?}");
        drop((one, two, four));
    }

    #[test]
    fn only_sockets_of_this_user_are_lent() {
        let root = Scratch::new("owner");
        let state = root.private("state");
        let file = root.0.join("file");
        std::fs::write(&file, b"").unwrap();
        for agent in [
            file.as_os_str(),
            OsStr::new("relative/agent"),
            OsStr::new(""),
        ] {
            update_agent_link(&state, Some(agent)).unwrap();
        }
        update_agent_link(&state, None).unwrap();
        assert!(std::fs::symlink_metadata(state.join(AGENT_LINK_NAME)).is_err());
        assert!(std::fs::symlink_metadata(state.join(AGENT_CLIENTS_DIR)).is_err());
    }
}
