//! The holder link: how a session's holder (`cherry-host hold`) and the
//! daemon talk. It is the only interface between different versions of
//! cherry-host: a holder keeps running the code it started with while
//! daemons are replaced around it, so a daemon must speak every link version
//! a holder that may still be alive speaks.
//!
//! # Frames
//!
//! ```text
//! frame  = length:u32be kind:u8 version:u16be meta_length:u32be meta data
//! ```
//!
//! `length` counts everything after itself. `version` is the sender's
//! [`LINK_VERSION`], in every frame. `meta` is a JSON object (`{}` when there
//! is nothing to say) and `data` raw bytes: terminal output, input, snapshots
//! and screen text travel as they are, never as base64. At most
//! [`MAX_FRAME`] bytes.
//!
//! # Compatibility
//!
//! A peer ignores frames of a kind it does not know and meta fields it does
//! not know. New behaviour is additive: a new kind, or a new optional field,
//! and a daemon sends a holder only what the link version it registered with
//! understands. The first frame a holder sends on a connection to the daemon
//! socket is `HolderHello`, whose first body byte (its kind, 1) can never
//! start a client's JSON frame. A daemon that will not serve a holder says
//! so (`Refused`), and whether to try again, before it closes the link.
//!
//! `Launch`, and the command that starts a holder (`cherry-host hold
//! --socket <path>` with the link on descriptor 3), cross versions too. On
//! Linux a daemon starts its own image (`/proc/self/exe`), but macOS has no
//! such path: a daemon whose executable was replaced by another build (an
//! app update) starts that build. So `Launch` fields are additive with
//! defaults as well, and a holder that cannot serve a `Launch` answers
//! `Failed`, which the daemon reports to the client that asked.
//!
//! - Version 1, the base set. Holder to daemon: `HolderHello`, `Output`,
//!   `Query`, `SnapshotReply`, `InputAck`, `DetachDone`, `Exited`, and
//!   `Failed` (only in answer to `Launch`). Daemon to holder: `Launch` (only
//!   on the link a new holder is started with), `Input`, `DiscardLease`,
//!   `Detach`, `Resize`, `Snapshot`, `Kill`, `Remove`, and `Refused` (only
//!   in answer to `HolderHello`).
//! - Version 2 adds session metadata and screen text. Holder to daemon:
//!   `Info`, `Event`, `ScreenReply`. Daemon to holder: `Screen`, `Update`.
//! - Version 3 adds terminal state and limited screen text, as fields:
//!   `alternate_screen` and `kitty_keyboard_flags` in `Info` and in the
//!   hello's session, and `max_lines` in `Screen`, which only a holder of
//!   version 3 or later is sent (it then limits the text and counts
//!   `cursor_row` from its first line; see `ScreenRequest`). The `Create`
//!   request ID a client sees (`SessionInfo::request_id`) is the hello's
//!   `receipt`, which every version carries.
//! - Version 4 adds application cursor keys (DECCKM), as a field:
//!   `application_cursor_keys` in `Info` and in the hello's session. A
//!   daemon takes it as off for an older holder, which never reports it.
//! - Version 5 adds, daemon to holder, `Attended` (whether any client is
//!   attached, which the holder serves at interactive priority; see
//!   `cherry_protocol::priority`), and the snapshot kind `resized`, which
//!   a daemon sends right behind a `RESIZE`: the screens, as `refresh`
//!   gives them, unless the alternate screen shows, whose program redraws
//!   it itself when the terminal is resized, and nothing was output since
//!   the last `RESIZE` took effect (the reply's offset is then where it
//!   did, and the output after it was made for the new size); then the
//!   reply's `kind` is `size` and it holds no bytes. The holder serves it
//!   before it reads more output when it arrives with its `RESIZE`, and a
//!   `size` reply takes no work, so the pass goes on. An older holder is
//!   sent neither (it would answer an unknown snapshot kind with an
//!   error).
//! - Version 6 adds, daemon to holder, `Pace`: how far the holder may read
//!   the program's output (`limit`, an output offset), so that the program
//!   goes at the pace of the session's fastest client when all of them take
//!   their output slowly, without the daemon ever leaving the link unread
//!   (see `session::Worker::pace`); `null` lifts it. A holder without a daemon
//!   reads freely. An older holder is never sent it, and is never held
//!   back: its slow clients lag and are resynchronized instead.
//!
//! Replies (`SnapshotReply`, `ScreenReply`, `DetachDone`) come in the order
//! of their requests, and in order with the output: a `SnapshotReply` shows
//! exactly the output before it, up to its `offset`.
use anyhow::{bail, Context, Result};
use serde::{de::DeserializeOwned, Deserialize, Deserializer, Serialize};
use std::{
    collections::{BTreeMap, VecDeque},
    io::{self, Read, Write},
    os::unix::io::RawFd,
};

/// The link version this build speaks.
pub const LINK_VERSION: u16 = 6;
/// The oldest link version whose holders limit screen text themselves
/// (`ScreenRequest::max_lines`).
pub const SCREEN_LINES_VERSION: u16 = 3;
/// The oldest link version whose holders answer the snapshot kind
/// `resized`.
pub const RESIZED_SNAPSHOT_VERSION: u16 = 5;
/// The oldest link version whose holders take `Pace`.
pub const PACE_VERSION: u16 = 6;
/// The oldest link version this daemon adopts holders of.
pub const MIN_LINK_VERSION: u16 = 1;
/// Frames are at most this long (an 8 MiB snapshot, and room to spare).
pub const MAX_FRAME: usize = 32 * 1024 * 1024;
/// Bytes before the meta: kind, version and the meta length.
const HEADER: usize = 1 + 2 + 4;
/// The room a read into `Reader`'s buffer has, at least.
const READ_CHUNK: usize = 64 * 1024;

/// Frame kinds. Holder to daemon below 64, daemon to holder from 64.
pub mod kind {
    pub const HOLDER_HELLO: u8 = 1;
    pub const OUTPUT: u8 = 2;
    pub const QUERY: u8 = 3;
    pub const SNAPSHOT_REPLY: u8 = 4;
    pub const INPUT_ACK: u8 = 5;
    pub const DETACH_DONE: u8 = 6;
    pub const EXITED: u8 = 7;
    pub const FAILED: u8 = 8;
    /// Version 2.
    pub const INFO: u8 = 9;
    /// Version 2.
    pub const EVENT: u8 = 10;
    /// Version 2.
    pub const SCREEN_REPLY: u8 = 11;

    pub const LAUNCH: u8 = 64;
    pub const INPUT: u8 = 65;
    pub const DISCARD_LEASE: u8 = 66;
    pub const DETACH: u8 = 67;
    pub const RESIZE: u8 = 68;
    pub const SNAPSHOT: u8 = 69;
    pub const KILL: u8 = 70;
    pub const REMOVE: u8 = 71;
    /// Version 2.
    pub const SCREEN: u8 = 72;
    /// Version 2.
    pub const UPDATE: u8 = 73;
    pub const REFUSED: u8 = 74;
    /// Version 5.
    pub const ATTENDED: u8 = 75;
    /// Version 6.
    pub const PACE: u8 = 76;

    /// The link version that introduced a daemon-to-holder kind.
    pub fn since(kind: u8) -> u16 {
        match kind {
            SCREEN | UPDATE => 2,
            ATTENDED => 5,
            PACE => 6,
            _ => 1,
        }
    }
}

/// One decoded frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub kind: u8,
    /// The sender's link version.
    pub version: u16,
    pub meta: Vec<u8>,
    pub data: Vec<u8>,
}

impl Frame {
    /// The meta as `T`; unknown fields are ignored.
    pub fn meta<T: DeserializeOwned>(&self) -> Result<T> {
        serde_json::from_slice(&self.meta)
            .with_context(|| format!("malformed link frame of kind {}", self.kind))
    }
}

/// A complete frame.
pub fn encode(kind: u8, meta: &impl Serialize, data: &[u8]) -> Vec<u8> {
    let meta = serde_json::to_vec(meta).expect("link meta serializes");
    let length = HEADER + meta.len() + data.len();
    let mut frame = Vec::with_capacity(4 + length);
    frame.extend_from_slice(&(length as u32).to_be_bytes());
    frame.push(kind);
    frame.extend_from_slice(&LINK_VERSION.to_be_bytes());
    frame.extend_from_slice(&(meta.len() as u32).to_be_bytes());
    frame.extend_from_slice(&meta);
    frame.extend_from_slice(data);
    frame
}

/// A frame with an empty meta.
pub fn bare(kind: u8) -> Vec<u8> {
    encode(kind, &Empty {}, &[])
}

/// Decode a frame body (everything after the length).
pub fn decode(body: &[u8]) -> Result<Frame> {
    if body.len() < HEADER {
        bail!("truncated link frame");
    }
    let kind = body[0];
    let version = u16::from_be_bytes([body[1], body[2]]);
    let meta_len = u32::from_be_bytes([body[3], body[4], body[5], body[6]]) as usize;
    let Some(meta) = body.get(HEADER..HEADER + meta_len) else {
        bail!("link frame meta exceeds the frame");
    };
    Ok(Frame {
        kind,
        version,
        meta: meta.to_vec(),
        data: body[HEADER + meta_len..].to_vec(),
    })
}

/// Read one frame, blocking; None at end of file.
pub fn read_blocking(reader: &mut impl Read) -> io::Result<Option<Frame>> {
    let mut length = [0u8; 4];
    let mut got = 0;
    while got < 4 {
        match reader.read(&mut length[got..]) {
            Ok(0) if got == 0 => return Ok(None),
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(n) => got += n,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    let length = u32::from_be_bytes(length) as usize;
    if !(HEADER..=MAX_FRAME).contains(&length) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid link frame length",
        ));
    }
    let mut body = vec![0; length];
    reader.read_exact(&mut body)?;
    decode(&body)
        .map(Some)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error.to_string()))
}

/// Frames arriving on a nonblocking descriptor.
#[derive(Default)]
pub struct Reader {
    buffer: Vec<u8>,
    start: usize,
}

impl Reader {
    /// Take in what the descriptor has, up to `limit` bytes. False at end of
    /// file or on an error: the link is gone.
    pub fn fill(&mut self, fd: RawFd, limit: usize) -> bool {
        if self.start > 0 && self.start == self.buffer.len() {
            self.buffer.clear();
            self.start = 0;
        }
        // Frames left for a later pass (a reader that stops early, as a
        // holder does after a costly request, see `holder::Holder::pump_link`)
        // keep the buffer from being emptied:
        // what was taken goes once it is at least as much as what is left,
        // so the buffer never holds more than twice what waits in it.
        if self.start > 0 && self.start >= self.buffered() {
            self.compact();
        }
        let mut taken = 0;
        while taken < limit {
            // Read into the buffer's spare room: nothing is zeroed or
            // copied first.
            self.buffer.reserve(READ_CHUNK);
            let spare = self.buffer.spare_capacity_mut();
            let want = spare.len().min(limit - taken);
            let n = unsafe { libc::read(fd, spare.as_mut_ptr().cast(), want) };
            if n < 0 {
                let error = io::Error::last_os_error();
                match error.kind() {
                    io::ErrorKind::Interrupted => continue,
                    io::ErrorKind::WouldBlock => return true,
                    _ => return false,
                }
            }
            if n == 0 {
                return false;
            }
            // The read initialized them.
            unsafe { self.buffer.set_len(self.buffer.len() + n as usize) };
            taken += n as usize;
        }
        true
    }

    /// The next complete frame, if one has arrived. An error means the peer
    /// broke the framing, and the link must end.
    pub fn next(&mut self) -> Result<Option<Frame>> {
        let available = &self.buffer[self.start..];
        if available.len() < 4 {
            self.compact();
            return Ok(None);
        }
        let length = u32::from_be_bytes(available[..4].try_into().unwrap()) as usize;
        if !(HEADER..=MAX_FRAME).contains(&length) {
            bail!("invalid link frame length {length}");
        }
        if available.len() < 4 + length {
            self.compact();
            return Ok(None);
        }
        let frame = decode(&available[4..4 + length])?;
        self.start += 4 + length;
        Ok(Some(frame))
    }

    /// Whether nothing is buffered.
    #[cfg(test)]
    pub fn is_empty(&self) -> bool {
        self.start == self.buffer.len()
    }

    /// Bytes read and not yet taken as frames.
    pub fn buffered(&self) -> usize {
        self.buffer.len() - self.start
    }

    fn compact(&mut self) {
        if self.start > 0 {
            self.buffer.drain(..self.start);
            self.start = 0;
        }
    }
}

/// Frames waiting for a nonblocking descriptor.
#[derive(Default)]
pub struct Writer {
    queue: VecDeque<Vec<u8>>,
    /// Bytes of the front frame already written.
    written: usize,
    len: usize,
}

impl Writer {
    pub fn push(&mut self, frame: Vec<u8>) {
        self.len += frame.len();
        self.queue.push_back(frame);
    }

    /// Bytes waiting.
    pub fn len(&self) -> usize {
        self.len - self.written
    }

    /// The frames not written in full, oldest first, for a link that is
    /// gone (its peer never acts on part of a frame); none are left.
    pub fn take_unwritten(&mut self) -> Vec<Vec<u8>> {
        self.written = 0;
        self.len = 0;
        self.queue.drain(..).collect()
    }

    pub fn is_empty(&self) -> bool {
        self.queue.is_empty()
    }

    /// Write what the descriptor accepts. False on an error: the link is
    /// gone.
    pub fn flush(&mut self, fd: RawFd) -> bool {
        while let Some(frame) = self.queue.front() {
            let rest = &frame[self.written..];
            let n = unsafe { libc::write(fd, rest.as_ptr().cast(), rest.len()) };
            if n < 0 {
                let error = io::Error::last_os_error();
                match error.kind() {
                    io::ErrorKind::Interrupted => continue,
                    io::ErrorKind::WouldBlock => return true,
                    _ => return false,
                }
            }
            self.written += n as usize;
            if self.written == frame.len() {
                self.len -= frame.len();
                self.written = 0;
                self.queue.pop_front();
            }
        }
        true
    }

    /// Write everything, blocking up to `timeout` in all.
    pub fn flush_all(&mut self, fd: RawFd, timeout: std::time::Duration) -> bool {
        let deadline = std::time::Instant::now() + timeout;
        loop {
            if !self.flush(fd) {
                return false;
            }
            if self.is_empty() {
                return true;
            }
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            if left.is_zero() {
                return false;
            }
            let mut poll = libc::pollfd {
                fd,
                events: libc::POLLOUT,
                revents: 0,
            };
            unsafe {
                libc::poll(&mut poll, 1, left.as_millis().max(1) as libc::c_int);
            }
        }
    }
}

/// Write a whole frame to a blocking stream.
pub fn write_blocking(writer: &mut impl Write, frame: &[u8]) -> io::Result<()> {
    writer.write_all(frame)?;
    writer.flush()
}

#[derive(Serialize, Deserialize, Default)]
pub struct Empty {}

/// Absent: unchanged; null: cleared; a value: set.
fn changed<'de, D: Deserializer<'de>, T: Deserialize<'de>>(
    deserializer: D,
) -> Result<Option<Option<T>>, D::Error> {
    Option::<T>::deserialize(deserializer).map(Some)
}

/// The foreground process group of a session's terminal.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct Foreground {
    pub pid: u32,
    #[serde(default)]
    pub name: String,
}

/// What the holder keeps about its session, and sends with every
/// `HolderHello`.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct SessionState {
    pub name: String,
    pub cwd: String,
    pub command: Vec<String>,
    pub cols: u16,
    pub rows: u16,
    pub running: bool,
    /// The session leader.
    pub pid: Option<u32>,
    #[serde(default)]
    pub exit_code: Option<u32>,
    #[serde(default)]
    pub exit_signal: Option<i32>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub pwd: Option<String>,
    #[serde(default)]
    pub foreground: Option<Foreground>,
    #[serde(default)]
    pub owner: Option<String>,
    #[serde(default)]
    pub tags: BTreeMap<String, String>,
    /// Milliseconds since the Unix epoch.
    #[serde(default)]
    pub created_at: u64,
    /// Version 3: whether the terminal shows its alternate screen.
    #[serde(default)]
    pub alternate_screen: bool,
    /// Version 3: the active screen's kitty keyboard flags.
    #[serde(default)]
    pub kitty_keyboard_flags: u32,
    /// Version 4: whether cursor keys are in application mode (DECCKM).
    #[serde(default)]
    pub application_cursor_keys: bool,
}

/// The `Create` that made a session, so that a daemon adopting it keeps
/// retries idempotent.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct Receipt {
    pub request_id: String,
    pub fingerprint: String,
}

/// Something the program did that is reported rather than shown. Unknown
/// kinds are ignored.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Event {
    Bell,
    Notification {
        #[serde(default)]
        title: String,
        #[serde(default)]
        body: String,
    },
    Progress {
        /// remove, set, error, indeterminate or pause.
        state: String,
        #[serde(default)]
        value: Option<u8>,
    },
    /// Only in `HolderHello::events`: the session exited while no daemon
    /// was connected. (A connected daemon is sent `Exited`.)
    Exited {
        exit_code: u32,
        #[serde(default)]
        signal: Option<i32>,
    },
}

/// Holder to daemon, first on every connection. Its meta.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct HolderHello {
    pub id: String,
    pub holder_pid: u32,
    pub session: SessionState,
    /// The output offset: the next `Output` starts here.
    pub offset: u64,
    #[serde(default)]
    pub receipt: Option<Receipt>,
    /// Events that happened while no daemon was connected (bounded), as
    /// JSON objects: kinds this daemon does not know are skipped. An
    /// `exited` event comes last. The holder offers them again to the next
    /// daemon unless this one got the hello and then sent a frame other
    /// than `REFUSED`, or kept the link for a while (two seconds).
    #[serde(default)]
    pub events: Vec<serde_json::Value>,
}

/// Daemon to holder, first on the link a new holder starts with. The data
/// holds the working directory and then `KEY=VALUE` environment entries,
/// each followed by a NUL byte.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Launch {
    pub id: String,
    pub name: String,
    pub command: Vec<String>,
    pub cols: u16,
    pub rows: u16,
    #[serde(default)]
    pub owner: Option<String>,
    #[serde(default)]
    pub tags: BTreeMap<String, String>,
    pub created_at: u64,
    /// Where the holder keeps its manifest (`sessions/<id>.json`).
    pub state_dir: String,
    /// Between SIGHUP, SIGTERM and SIGKILL when killing the session.
    pub kill_grace_ms: u64,
    #[serde(default)]
    pub receipt: Option<Receipt>,
}

#[derive(Serialize, Deserialize)]
pub struct Failed {
    pub message: String,
}

/// Daemon to holder, instead of serving it; the link closes after it.
#[derive(Serialize, Deserialize, Debug)]
pub struct Refused {
    pub reason: String,
    /// False: this daemon will never serve the holder (its link version is
    /// too old, its hello unusable). The holder then dials again only when
    /// the socket's directory changes (another daemon may bind it), and a
    /// holder whose session has exited exits. True (the default): a
    /// passing condition, such as a daemon that is stopping; it dials again
    /// with backoff.
    #[serde(default = "retry_by_default")]
    pub retry: bool,
}

fn retry_by_default() -> bool {
    true
}

#[derive(Serialize, Deserialize)]
pub struct OutputMeta {
    pub offset: u64,
}

#[derive(Serialize, Deserialize)]
pub struct InputMeta {
    /// The attachment it comes from; none for input sent without one.
    #[serde(default)]
    pub lease: Option<u64>,
}

#[derive(Serialize, Deserialize)]
pub struct InputAck {
    #[serde(default)]
    pub lease: Option<u64>,
    /// Input bytes written to the terminal or discarded.
    pub bytes: u64,
}

#[derive(Serialize, Deserialize)]
pub struct Lease {
    pub lease: u64,
}

#[derive(Serialize, Deserialize)]
pub struct DetachMeta {
    pub req: u64,
    pub lease: u64,
}

#[derive(Serialize, Deserialize)]
pub struct Req {
    pub req: u64,
}

#[derive(Serialize, Deserialize)]
pub struct Size {
    pub cols: u16,
    pub rows: u16,
}

/// A snapshot request: `full`, `limited` (to `max` bytes, the oldest
/// history dropped to fit), `refresh` (the screens without history) or,
/// from version 5, `resized` (`refresh`, or no bytes and the reply kind
/// `size` while the alternate screen shows and nothing was output since
/// the last resize; see the version notes).
#[derive(Serialize, Deserialize)]
pub struct SnapshotRequest {
    pub req: u64,
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max: Option<usize>,
}

/// The data is the snapshot as a renderer stream, which shows exactly the
/// output up to `offset`.
#[derive(Serialize, Deserialize)]
pub struct SnapshotReply {
    pub req: u64,
    /// The request's kind, or what a `resized` request was answered with
    /// (`refresh` or `size`).
    pub kind: String,
    pub offset: u64,
    pub cols: u16,
    pub rows: u16,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// Daemon to holder, version 5: whether any client is attached to the
/// session. Sent when that changes; a holder without a daemon has none.
#[derive(Serialize, Deserialize)]
pub struct Attended {
    pub attached: bool,
}

/// Daemon to holder, version 6: read the program's output only while the
/// output offset is below `limit` (and no further than it, as nearly as a
/// read allows); None: read freely. The latest one counts. A holder that
/// loses its daemon reads freely again.
#[derive(Serialize, Deserialize, Debug, PartialEq, Eq)]
pub struct Pace {
    #[serde(default)]
    pub limit: Option<u64>,
}

/// The screen as text, with its history when `scrollback`.
#[derive(Serialize, Deserialize)]
pub struct ScreenRequest {
    pub req: u64,
    pub scrollback: bool,
    /// Version 3: only the last this many lines of the text, and then
    /// `ScreenReply::cursor_row` is the line of the (limited) text that
    /// holds the cursor rather than its row on the screen (see
    /// `cherry_protocol::ServerMessage::ScreenText`). Only sent to holders
    /// of version 3 or later: an older one would ignore it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_lines: Option<u32>,
}

/// The data is the screen as UTF-8 text.
#[derive(Serialize, Deserialize)]
pub struct ScreenReply {
    pub req: u64,
    pub cursor_row: u16,
    pub cursor_col: u16,
    pub alternate_screen: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// What changed about the session. Absent fields are unchanged; `null`
/// clears the title, the working directory and the foreground process.
/// Sent only when something changed, after the output that changed it.
#[derive(Serialize, Deserialize, Default, Debug, PartialEq, Eq)]
pub struct Info {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cols: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rows: Option<u16>,
    #[serde(
        default,
        deserialize_with = "changed",
        skip_serializing_if = "Option::is_none"
    )]
    pub title: Option<Option<String>>,
    #[serde(
        default,
        deserialize_with = "changed",
        skip_serializing_if = "Option::is_none"
    )]
    pub pwd: Option<Option<String>>,
    #[serde(
        default,
        deserialize_with = "changed",
        skip_serializing_if = "Option::is_none"
    )]
    pub foreground: Option<Option<Foreground>>,
    /// Version 3: whether the terminal shows its alternate screen.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub alternate_screen: Option<bool>,
    /// Version 3: the active screen's kitty keyboard flags.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kitty_keyboard_flags: Option<u32>,
    /// Version 4: whether cursor keys are in application mode (DECCKM).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub application_cursor_keys: Option<bool>,
}

impl Info {
    pub fn is_empty(&self) -> bool {
        *self == Self::default()
    }
}

#[derive(Serialize, Deserialize)]
pub struct Exited {
    pub exit_code: u32,
    #[serde(default)]
    pub signal: Option<i32>,
}

/// A rename or new tags; absent fields are kept.
#[derive(Serialize, Deserialize, Default)]
pub struct Update {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tags: Option<BTreeMap<String, String>>,
}

/// Environment entries: names and values, as bytes.
pub type Env = Vec<(Vec<u8>, Vec<u8>)>;

/// `Launch` data: the working directory, then the environment.
pub fn launch_data(cwd: &[u8], env: &[(Vec<u8>, Vec<u8>)]) -> Vec<u8> {
    let mut data = Vec::new();
    data.extend_from_slice(cwd);
    data.push(0);
    for (key, value) in env {
        data.extend_from_slice(key);
        data.push(b'=');
        data.extend_from_slice(value);
        data.push(0);
    }
    data
}

/// The working directory and environment of `Launch` data.
pub fn parse_launch_data(data: &[u8]) -> Result<(Vec<u8>, Env)> {
    let mut entries = data.split(|&b| b == 0);
    let cwd = entries
        .next()
        .context("launch without a directory")?
        .to_vec();
    let mut env = Vec::new();
    for entry in entries.filter(|entry| !entry.is_empty()) {
        let at = entry
            .iter()
            .position(|&b| b == b'=')
            .context("malformed launch environment")?;
        env.push((entry[..at].to_vec(), entry[at + 1..].to_vec()));
    }
    Ok((cwd, env))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_round_trip_and_carry_the_version() {
        let frame = encode(kind::OUTPUT, &OutputMeta { offset: 7 }, b"\x1b[1mhi\0");
        assert_eq!(
            u32::from_be_bytes(frame[..4].try_into().unwrap()) as usize,
            frame.len() - 4
        );
        let decoded = decode(&frame[4..]).unwrap();
        assert_eq!(decoded.kind, kind::OUTPUT);
        assert_eq!(decoded.version, LINK_VERSION);
        assert_eq!(decoded.data, b"\x1b[1mhi\0");
        assert_eq!(decoded.meta::<OutputMeta>().unwrap().offset, 7);
        let mut stream = &frame[..];
        assert_eq!(read_blocking(&mut stream).unwrap(), Some(decoded));
        assert_eq!(read_blocking(&mut stream).unwrap(), None);
    }

    #[test]
    fn frames_arrive_in_pieces() {
        let frames = [
            encode(kind::QUERY, &Empty {}, b"\x1b[?6n"),
            bare(kind::KILL),
            encode(kind::RESIZE, &Size { cols: 90, rows: 30 }, &[]),
        ]
        .concat();
        let (mut ours, theirs) = std::os::unix::net::UnixStream::pair().unwrap();
        ours.set_nonblocking(true).unwrap();
        theirs.set_nonblocking(true).unwrap();
        let mut reader = Reader::default();
        let mut kinds = Vec::new();
        for piece in frames.chunks(3) {
            (&theirs).write_all(piece).unwrap();
            assert!(reader.fill(std::os::unix::io::AsRawFd::as_raw_fd(&ours), 1 << 20));
            while let Some(frame) = reader.next().unwrap() {
                kinds.push(frame.kind);
            }
        }
        assert_eq!(kinds, [kind::QUERY, kind::KILL, kind::RESIZE]);
        assert!(reader.is_empty());
        drop(theirs);
        assert!(!reader.fill(std::os::unix::io::AsRawFd::as_raw_fd(&ours), 1 << 20));
        let _ = ours.flush();
    }

    #[test]
    fn a_reader_that_stops_early_keeps_its_buffer_bounded() {
        let (ours, theirs) = std::os::unix::net::UnixStream::pair().unwrap();
        ours.set_nonblocking(true).unwrap();
        let frame = encode(kind::OUTPUT, &OutputMeta { offset: 0 }, &[b'x'; 4000]);
        const FRAMES: usize = 4000;
        // The holder's side keeps its end full.
        let writer = std::thread::spawn(move || {
            for _ in 0..FRAMES {
                (&theirs).write_all(&frame).unwrap();
            }
        });
        let fd = std::os::unix::io::AsRawFd::as_raw_fd(&ours);
        let mut reader = Reader::default();
        let mut taken = 0;
        let limit: usize = 64 * 1024;
        while taken < FRAMES {
            // Take a few frames and leave the rest for later, as a worker
            // that a client holds back does; at most `limit` waits here.
            let room = limit.saturating_sub(reader.buffered());
            // False once the writer is done and its end closed.
            let _ = reader.fill(fd, room);
            for _ in 0..4 {
                if reader.next().unwrap().is_some() {
                    taken += 1;
                }
            }
            assert!(
                reader.buffer.len() <= 2 * limit + 8192,
                "{} bytes after {taken} frames",
                reader.buffer.len()
            );
        }
        writer.join().unwrap();
    }

    #[test]
    fn unknown_fields_are_ignored_and_changes_distinguish_clearing() {
        let info: Info =
            serde_json::from_str(r#"{"title":null,"pwd":"file:///tmp","future":1}"#).unwrap();
        assert_eq!(info.title, Some(None));
        assert_eq!(info.pwd, Some(Some("file:///tmp".into())));
        assert_eq!(info.foreground, None);
        assert_eq!(serde_json::to_string(&Info::default()).unwrap(), "{}");
        assert_eq!(
            serde_json::to_string(&Info {
                title: Some(None),
                ..Info::default()
            })
            .unwrap(),
            r#"{"title":null}"#
        );
        // Version 3's terminal state, absent from older holders' frames.
        assert_eq!(
            serde_json::to_string(&Info {
                alternate_screen: Some(false),
                kitty_keyboard_flags: Some(3),
                ..Info::default()
            })
            .unwrap(),
            r#"{"alternate_screen":false,"kitty_keyboard_flags":3}"#
        );
        // Version 4's, likewise.
        assert_eq!(
            serde_json::to_string(&Info {
                application_cursor_keys: Some(true),
                ..Info::default()
            })
            .unwrap(),
            r#"{"application_cursor_keys":true}"#
        );
        let info: Info = serde_json::from_str(r#"{"application_cursor_keys":false}"#).unwrap();
        assert_eq!(info.application_cursor_keys, Some(false));
        assert!(!info.is_empty());
        let old: Info = serde_json::from_str(r#"{"alternate_screen":true}"#).unwrap();
        assert_eq!(old.application_cursor_keys, None);
        let old: SessionState = serde_json::from_str(
            r#"{"name":"n","cwd":"/","command":[],"cols":80,"rows":24,"running":true,"pid":7}"#,
        )
        .unwrap();
        assert_eq!(
            (
                old.alternate_screen,
                old.kitty_keyboard_flags,
                old.application_cursor_keys
            ),
            (false, 0, false)
        );
        let request: ScreenRequest =
            serde_json::from_str(r#"{"req":1,"scrollback":true}"#).unwrap();
        assert_eq!(request.max_lines, None);
        assert_eq!(
            serde_json::to_string(&ScreenRequest {
                req: 2,
                scrollback: false,
                max_lines: None,
            })
            .unwrap(),
            r#"{"req":2,"scrollback":false}"#
        );
    }

    #[test]
    fn a_refusal_without_a_verdict_allows_retrying() {
        let refused: Refused = serde_json::from_str(r#"{"reason":"busy"}"#).unwrap();
        assert!(refused.retry);
        let refused: Refused =
            serde_json::from_str(r#"{"reason":"old","retry":false,"later":1}"#).unwrap();
        assert!(!refused.retry);
        assert_eq!(kind::since(kind::REFUSED), 1);
    }

    #[test]
    fn a_holder_is_told_whether_anyone_attached_only_from_version_5() {
        assert_eq!(kind::since(kind::ATTENDED), 5);
        assert!(LINK_VERSION >= kind::since(kind::ATTENDED));
        assert_eq!(RESIZED_SNAPSHOT_VERSION, 5);
        let frame = encode(kind::ATTENDED, &Attended { attached: true }, &[]);
        let decoded = decode(&frame[4..]).unwrap();
        assert!(decoded.meta::<Attended>().unwrap().attached);
        let later: Attended = serde_json::from_str(r#"{"attached":false,"clients":2}"#).unwrap();
        assert!(!later.attached);
    }

    #[test]
    fn launch_data_keeps_arbitrary_bytes() {
        let env = vec![
            (b"PATH".to_vec(), b"/bin:/usr/bin".to_vec()),
            (b"ODD".to_vec(), b"a=b\xff".to_vec()),
            (b"EMPTY".to_vec(), Vec::new()),
        ];
        let data = launch_data(b"/tmp/\xfe dir", &env);
        assert_eq!(
            parse_launch_data(&data).unwrap(),
            (b"/tmp/\xfe dir".to_vec(), env)
        );
    }
}
