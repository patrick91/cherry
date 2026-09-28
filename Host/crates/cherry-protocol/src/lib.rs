//! Versioned, length-prefixed protocol shared by the local socket, the SSH
//! gateway and `cherry control`.
//!
//! # Frames
//!
//! A frame is a 4-byte big-endian length followed by that many bytes, at
//! most [`MAX_FRAME_BYTES`]. A client sends [`Request`]s (a [`ClientMessage`])
//! and the host sends [`Response`]s (a [`ServerMessage`]). A frame whose
//! first byte is `{` holds a JSON message, tagged by `op` (a client's) or
//! `type` (the host's): the handshake and every control message. An
//! attachment's terminal bytes travel as they are, in binary frames, whose
//! first byte is their kind ([`binary_kind`]; version 6):
//!
//! - `Output` (1, host to client): the offset (8 bytes, big-endian), then
//!   the output.
//! - `Input` (2, client to host): the input.
//! - `Query` (3, host to client): the query.
//! - `Attached` (4, host to client): the length of a JSON header (4 bytes,
//!   big-endian), the header (an object with `session`, `offset`, `reason`
//!   and `refreshes`), then the snapshot.
//!
//! Those four messages have no JSON form, and a binary frame carries no
//! `req`. Terminal bytes inside JSON messages (`SendInput`) are standard
//! base64 strings. Unknown fields are ignored everywhere (the `Attached`
//! header's too), so a field can be added without breaking an older peer;
//! an unknown `op`, `type` or binary kind cannot be decoded. A field that
//! changes what the answer means (`ClientMessage::Screen`'s `max_lines`) is
//! ignored by an older host of the same version too, so its documentation
//! says how a client tells a host that knows it. See [`Message`] for
//! encoding and decoding frames.
//!
//! # Versions
//!
//! Normal operation needs the same [`PROTOCOL_VERSION`] on both sides: the
//! bundled CLI, app and host ship together. A connection starts with the
//! client's `Hello`, which the host always answers with `Welcome` and its own
//! version, whatever version the client speaks. When the versions differ,
//! the client either disconnects or, only when the host speaks a *lower*
//! version, sends `Replace`. The host then accepts nothing else: to a client
//! speaking a higher version it stops accepting connections, removes its
//! socket, releases its state directory's lock and answers `Ok`, then exits,
//! so the client can start its own host at once. Sessions carry on (they
//! live in processes of their own) and the new host serves them. Any other
//! request after a mismatch, or a `Replace` from a client speaking a lower
//! version, is answered with `Error{version_mismatch}`. Either way the
//! connection then closes; a frame the host cannot decode closes it
//! unanswered. Once the versions match (protocol 7), a JSON request it
//! cannot decode is answered with an `Error` instead (`unsupported_operation`
//! for an unknown `op`, `request_failed` for fields it cannot take; see
//! [`undecodable_request`]) and the connection carries on. A host speaking a higher version is reported, never replaced.
//!
//! ## Frozen forever
//!
//! Every version sends and accepts these exact shapes (shown without the
//! optional `req`, which a peer may add and which is echoed as below), so any
//! two versions can always negotiate:
//!
//! - `{"op":"hello","version":<u32>}`
//! - `{"type":"welcome","version":<u32>,"host_id":"<host id>"}`, the answer
//!   to every `Hello`, whatever its version; a host of protocol 7 may add
//!   `"build":"<build>"` (see [`BUILD`]), which every version ignores
//! - `{"op":"replace"}`, only after a `Welcome` with a lower version
//! - `{"type":"ok"}`
//! - `{"type":"error","code":"<code>","message":"<text>"}`
//!
//! A host answers a first frame that decodes as a request other than `Hello`
//! with `Error{version_mismatch}` and closes the connection; one it cannot
//! decode (malformed, an unknown `op`, an invalid `req`) closes it
//! unanswered. The SSH gateway writes the line `CHERRY-GATEWAY <version>\n`
//! before relaying frames; that line keeps its shape too, so a client can
//! report which version the gateway speaks.
//!
//! # Requests
//!
//! Any request may carry `"req": <u64>`, which the host echoes on its reply,
//! so one connection can have several requests in flight. The host answers
//! every request with exactly one frame, except `Input` and `Resize`, which
//! are answered only when they fail, and `Refresh`, which is answered with a
//! replacement snapshot (or an error). Frames the host sends on its own never
//! carry a `req`: `Event`s, and attachment traffic. `Attach`, `Input`,
//! `Resize`, `Refresh` and `Detach` belong to an attachment: every frame that
//! answers them (`Attached`, an `Error`, the `Ok` after `Detach`) is attachment traffic,
//! like `Output`, `Query`, `Exit` and the keepalive `Pong`s of a paused
//! attachment, and a `req` on them is ignored. A connection carries at most
//! one attachment, whose frames carry no session ID: a control connection
//! (`Subscribe`, `SendInput`, `Screen`, …) never attaches.
//!
//! # Events
//!
//! After `Subscribe` (answered `Ok`) the host pushes `Event{event}` frames on
//! that connection: sessions added, changed (any `SessionInfo` field) and
//! removed; bells, desktop notifications and progress reports from the
//! programs; exits; and `resync`, which means the subscriber fell behind and
//! missed events, so it lists the sessions again. A subscriber's queue is
//! bounded and keeps only the latest `changed` of each session. A subscribed
//! connection is exempt from the idle limit but must send `Ping` at least
//! every [`HEARTBEAT_INTERVAL`]; one that sends nothing for
//! [`HEARTBEAT_TIMEOUT`] is dropped.
use serde::{Deserialize, Serialize};
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

pub mod priority;

pub const PROTOCOL_VERSION: u32 = 7;
/// This build of cherry and cherry-host: `<YYYYMMDDHHMMSS>.<revision>` when
/// it was given at build time (`CHERRY_BUILD_ID`: the app's
/// CFBundleVersion), otherwise `dev-<commit time>.<revision>`, a development
/// build that never orders against another (`build_is_newer`). Set by
/// `build.rs`; the daemon reports it in `Welcome` and each session its
/// holder's (`SessionInfo::holder_build`).
pub const BUILD: &str = env!("CHERRY_BUILD_ID");
/// What `--version` prints after the program's name.
pub const VERSION: &str = concat!(
    env!("CARGO_PKG_VERSION"),
    " (build ",
    env!("CHERRY_BUILD_ID"),
    ")"
);

/// When a build was made, as `YYYYMMDDHHMMSS` read as a number: the part of
/// a `BUILD` before its first `.`, when it has exactly 14 digits. None for a
/// build that does not say (a package version).
pub fn build_stamp(build: &str) -> Option<u64> {
    let stamp = build.split('.').next()?;
    (stamp.len() == 14 && stamp.bytes().all(|b| b.is_ascii_digit()))
        .then(|| stamp.parse().ok())
        .flatten()
}

/// Whether `build` was made after `other`: both carry a build time
/// (`build_stamp`) and `build`'s is later. Builds that cannot be ordered
/// (either has no time, or the times are equal) are neither newer nor
/// older, so two copies never take turns replacing each other's daemon.
pub fn build_is_newer(build: &str, other: &str) -> bool {
    matches!((build_stamp(build), build_stamp(other)), (Some(a), Some(b)) if a > b)
}

/// The build a `--version` line names (`cherry-host 0.1.0 (build B)`).
pub fn build_in_version(line: &str) -> Option<&str> {
    let start = line.find("(build ")? + "(build ".len();
    let end = start + line[start..].find(')')?;
    let build = line[start..end].trim();
    (!build.is_empty()).then_some(build)
}
/// The environment variable in which the CLI tells a remote
/// `cherry-host gateway` which host identity it expects
/// (`--expected-host-id`, or the host an attachment reconnects to). The
/// gateway neither replaces nor reports a host of another identity: it
/// relays it, and the client refuses its Welcome, as it would locally. A
/// variable rather than an option, so that a cherry-host of another
/// version ignores it and still answers with its preamble, which tells the
/// CLI what it is.
pub const EXPECTED_HOST_ID_VAR: &str = "CHERRY_EXPECTED_HOST_ID";
pub const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;

/// The first byte of a binary frame: what it carries (see the crate
/// documentation). A JSON frame starts with `{`, which no kind is.
pub mod binary_kind {
    /// `ServerMessage::Output`: the offset (8 bytes, big-endian), then the
    /// output.
    pub const OUTPUT: u8 = 1;
    /// `ClientMessage::Input`: the input.
    pub const INPUT: u8 = 2;
    /// `ServerMessage::Query`: the query.
    pub const QUERY: u8 = 3;
    /// `ServerMessage::Attached`: the length of its JSON header (4 bytes,
    /// big-endian), the header, then the snapshot.
    pub const ATTACHED: u8 = 4;
}

/// The bytes of an `Output` frame before its output: the length word, the
/// kind and the offset.
pub const OUTPUT_HEADER: usize = 4 + 1 + 8;
/// The most bytes one `Input` or `SendInput` carries.
pub const MAX_INPUT_BYTES: usize = 64 * 1024;
/// Keep snapshots well below the frame limit so an attach can never exceed
/// it, header and all.
pub const MAX_SNAPSHOT_BYTES: usize = 8 * 1024 * 1024;
/// `ScreenText::text` is at most this long: the oldest lines are dropped to
/// fit. Plain text doubles at most in JSON, so the frame always fits.
pub const MAX_SCREEN_TEXT_BYTES: usize = 4 * 1024 * 1024;
pub const DEFAULT_COLS: u16 = 120;
pub const DEFAULT_ROWS: u16 = 32;
/// A connection that is neither attached nor subscribed must send its next
/// frame within this, or the host closes it.
pub const IDLE_TIMEOUT: Duration = Duration::from_secs(10);
/// Attached and subscribed clients send `Ping` at least this often.
pub const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(15);
/// The host drops an attached or subscribed client that has sent nothing for
/// this long, so a vanished laptop cannot pin the shared grid size.
pub const HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(45);
/// `SessionInfo::owner` is at most this long.
pub const MAX_OWNER_BYTES: usize = 256;
/// A session has at most this many tags,
pub const MAX_TAGS: usize = 64;
/// each with a non-empty key of at most this length,
pub const MAX_TAG_KEY_BYTES: usize = 128;
/// and all keys and values together at most this long.
pub const MAX_TAG_BYTES: usize = 16 * 1024;
/// `ClientMessage::Attach::client_id` is at most this long.
pub const MAX_CLIENT_ID_BYTES: usize = 128;

/// Error codes in `ServerMessage::Error`.
pub mod error_code {
    /// The first frame was not a `Hello`, or a request came after a `Welcome`
    /// that reported another version (see the crate documentation). Frozen.
    pub const VERSION_MISMATCH: &str = "version_mismatch";
    /// Any other failure; the message says why.
    pub const REQUEST_FAILED: &str = "request_failed";
    /// Another client attached with `takeover`; this attachment ended.
    pub const TAKEN_OVER: &str = "taken_over";
    /// A newer attachment of the same client (`ClientMessage::Attach`'s
    /// `client_id`) replaced this one, which ended; the client runs on
    /// there, so this one does not connect again (protocol 5).
    pub const REPLACED: &str = "replaced";
    /// Non-fatal while attached: the canonical size could not change.
    pub const RESIZE_FAILED: &str = "resize_failed";
    pub const SNAPSHOT_FAILED: &str = "snapshot_failed";
    /// The host does not implement this request.
    pub const UNSUPPORTED_OPERATION: &str = "unsupported_operation";
    /// No session has this ID: it never existed or was removed.
    pub const UNKNOWN_SESSION: &str = "unknown_session";
    /// The session has exited, so it takes no input.
    pub const NOT_RUNNING: &str = "not_running";
    /// The host already serves as many connections as it takes
    /// (`cherry-host`'s `MAX_CONNECTIONS`); it sends this before the
    /// `Welcome` and closes the connection. Try again later.
    pub const TOO_MANY_CONNECTIONS: &str = "too_many_connections";
}

/// Why a session ended other than by its program exiting
/// (`SessionInfo::ended_by`, `SessionEvent::Exited::ended_by`).
pub mod ended_by {
    /// The session's holder (`cherry-host hold`) went away while the
    /// program ran: it crashed or was killed. Its exit status (1) is not
    /// the program's; the host then ends what is left of the program (SIGHUP,
    /// then SIGTERM, then SIGKILL).
    pub const HOLDER_LOST: &str = "holder_lost";
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
    /// Whether any client is attached (`clients > 0`).
    pub attached: bool,
    /// Terminating signal, when the process did not exit normally.
    pub exit_signal: Option<i32>,
    /// The title the program set (OSC 0 or 2), when it set a non-empty one.
    #[serde(default)]
    pub title: Option<String>,
    /// The working directory the program last reported, exactly as reported:
    /// a `file://host/path` URI (OSC 7, percent-encoded) or a plain path
    /// (OSC 9;9, OSC 1337 CurrentDir). None until it reports a non-empty one.
    #[serde(default)]
    pub pwd: Option<String>,
    /// The terminal's foreground process group, while the session runs. The
    /// session is busy when its `pid` differs from the session's `pid`.
    #[serde(default)]
    pub foreground: Option<ForegroundProcess>,
    /// How many clients are attached.
    #[serde(default)]
    pub clients: u32,
    /// Who created the session (`ClientMessage::Create::owner`).
    #[serde(default)]
    pub owner: Option<String>,
    /// Client metadata from `Create` or the last `Update`.
    #[serde(default)]
    pub tags: BTreeMap<String, String>,
    /// When the host created the session, in milliseconds since the Unix
    /// epoch.
    #[serde(default)]
    pub created_at: u64,
    /// Whether the program shows the alternate screen (a full-screen
    /// program such as an editor or a pager), as the host's terminal has it.
    #[serde(default)]
    pub alternate_screen: bool,
    /// The kitty keyboard protocol flags the program enabled on the active
    /// screen (0 when it uses legacy key encoding).
    #[serde(default)]
    pub kitty_keyboard_flags: u32,
    /// Whether the program put cursor keys in application mode (DECCKM,
    /// `CSI ? 1 h`), as the host's terminal has it: in legacy key encoding,
    /// unmodified arrows, Home and End are then sent as `ESC O x` rather
    /// than `ESC [ x`. It does not apply while [`Self::kitty_keyboard_flags`]
    /// is not 0: the program then gets the kitty encoding, which sends them
    /// in a CSI form (`ESC [ x` for an unmodified press), never as `ESC O x`.
    /// False from a host, or a session's holder, that does not report it.
    #[serde(default)]
    pub application_cursor_keys: bool,
    /// Whether the program turned on bracketed paste (DECSET 2004), as the
    /// host's terminal has it: a paste is then wrapped in `ESC [ 200 ~` and
    /// `ESC [ 201 ~`, so the program takes it as text rather than typed
    /// lines. None when it is not known: from a host older than protocol 7,
    /// or for a session whose holder predates link version 7.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bracketed_paste: Option<bool>,
    /// The `request_id` of the `Create` that made the session. It survives
    /// host restarts; None for a session whose host did not record it.
    #[serde(default)]
    pub request_id: Option<String>,
    /// Why the session ended, when its program's exit did not end it
    /// ([`ended_by`]): `holder_lost` when its holder crashed. None while
    /// it runs, and for a normal exit.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ended_by: Option<String>,
    /// With `ended_by`: the host log that holds what the holder wrote
    /// (its panic, if it panicked), when the host writes one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub holder_log: Option<String>,
    /// The build of the process that holds the session (its holder, see
    /// [`BUILD`]), which keeps the code it started with when the daemon is
    /// updated. None for a holder that does not say (older than this field)
    /// and from an older host.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub holder_build: Option<String>,
}

/// The colours a session's terminal reports (`ClientMessage::Create`'s
/// `colors`), each as `#rrggbb`.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub struct TerminalColors {
    pub foreground: Rgb,
    pub background: Rgb,
    /// The foreground's when left out.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<Rgb>,
    /// A dark colour scheme rather than a light one.
    pub dark: bool,
}

/// A colour, `#rrggbb` in JSON.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rgb(pub [u8; 3]);

impl Serialize for Rgb {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let [r, g, b] = self.0;
        serializer.serialize_str(&format!("#{r:02x}{g:02x}{b:02x}"))
    }
}

impl<'de> Deserialize<'de> for Rgb {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        let hex = text
            .strip_prefix('#')
            .filter(|hex| hex.len() == 6 && hex.bytes().all(|b| b.is_ascii_hexdigit()))
            .ok_or_else(|| serde::de::Error::custom(format!("not a #rrggbb colour: {text:?}")))?;
        let channel = |at: usize| u8::from_str_radix(&hex[at..at + 2], 16).unwrap_or(0);
        Ok(Self([channel(0), channel(2), channel(4)]))
    }
}

/// The process group in the foreground of a session's terminal.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ForegroundProcess {
    /// The process group ID, which is its leader's process ID.
    pub pid: u32,
    /// The leader's process name; empty when it could not be read.
    pub name: String,
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

/// A frame from a client: a message and the optional request ID that the
/// host echoes on its reply. Without `req` it is exactly the bare message,
/// and a bare message decodes as a `Request` without one. `req` is reserved:
/// no message has a field of that name.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Request {
    #[serde(flatten)]
    pub message: ClientMessage,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub req: Option<u64>,
}

impl Request {
    pub fn new(req: Option<u64>, message: ClientMessage) -> Self {
        Self { message, req }
    }
}

impl From<ClientMessage> for Request {
    fn from(message: ClientMessage) -> Self {
        Self::new(None, message)
    }
}

/// A frame from the host: a message and, on the reply to a request that had
/// one, that request's `req`. Events and attachment traffic have none.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Response {
    #[serde(flatten)]
    pub message: ServerMessage,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub req: Option<u64>,
}

impl Response {
    pub fn new(req: Option<u64>, message: ServerMessage) -> Self {
        Self { message, req }
    }
}

impl From<ServerMessage> for Response {
    fn from(message: ServerMessage) -> Self {
        Self::new(None, message)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum ClientMessage {
    /// The first frame of every connection. Frozen.
    Hello {
        version: u32,
    },
    /// Ask a host that answered `Welcome` with a lower version to make way
    /// (see the crate documentation). Frozen.
    Replace,
    List,
    /// Start a session; answered `Created`. A retry with the same `request_id`
    /// and the same launch (everything but the size) answers the session the
    /// first one created.
    Create {
        /// A UUID chosen by the client.
        request_id: String,
        name: String,
        /// Absolute, `~` or `~/…` on the host. The session's `PWD` is set to
        /// it when it resolves to the canonical directory (`SessionInfo::cwd`
        /// is canonical).
        cwd: String,
        /// Empty for the user's login shell.
        command: Vec<String>,
        /// Variables for the session: any non-empty name without `=` or
        /// NUL, and values without NUL, at most 1024 of them and 256 KiB
        /// in all. The host's own defaults (`TERM`, `TERM_PROGRAM`,
        /// `SSH_AUTH_SOCK`, …) apply only to variables the client does not
        /// set; `CHERRY_SESSION_ID` and `PWD` are always the host's.
        #[serde(default)]
        env: BTreeMap<String, String>,
        cols: u16,
        rows: u16,
        /// The app variant creating the session, so that each restores only
        /// its own. At most `MAX_OWNER_BYTES`.
        #[serde(default)]
        owner: Option<String>,
        /// Client metadata kept with the session (Cherry records its tab ID,
        /// kind, agent and command). Within `MAX_TAGS`, `MAX_TAG_KEY_BYTES`
        /// and `MAX_TAG_BYTES`.
        #[serde(default)]
        tags: BTreeMap<String, String>,
        /// The colours and appearance the session's terminal reports to its
        /// program (OSC 10, 11 and 12 queries, and the colour-scheme query
        /// `CSI ? 996 n`): the client's own terminal's, so a program that
        /// asks sees the terminal it is shown in. Without them (or from a
        /// host older than protocol 7, which ignores them) the host reports
        /// light grey on black, dark. Not part of what a retry must repeat
        /// (like the size).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        colors: Option<TerminalColors>,
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
        /// Names the client across its connections (Cherry passes a tab's
        /// ID; at most `MAX_CLIENT_ID_BYTES`, empty is none). An attachment
        /// of the session that carries the same ID is dropped when this one
        /// is made, as if its connection had ended (its unsent input is
        /// discarded, and nobody is told `taken_over`): a client that
        /// starts again, or connects again before the host noticed the
        /// lost connection, never leaves a stale attachment behind that
        /// holds the shared grid at its size. The dropped attachment is
        /// sent `error_code::REPLACED` last, so a copy of the client that
        /// still runs ends rather than connecting again (which would drop
        /// this one in turn).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        client_id: Option<String>,
    },
    /// Terminal input for the attached session, at most `MAX_INPUT_BYTES`.
    /// A binary frame only (`binary_kind::INPUT`).
    #[serde(skip)]
    Input {
        data: Vec<u8>,
    },
    Resize {
        cols: u16,
        rows: u16,
    },
    /// Ask for a replacement snapshot of the grid (`Attached{Resize}`),
    /// queued behind the attachment's output like any replacement; the host
    /// answers only with it, or with `Error{snapshot_failed}`. A client that
    /// follows the stream without a copy of the screen (see `Attached`'s
    /// `refreshes`) asks for one when it needs the screen: to paint a
    /// viewport, say. One already on its way answers it too.
    Refresh,
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
    /// Make way for a new host of this version (protocol 7), as `Replace`
    /// does for a newer one: the host stops accepting connections, releases
    /// its socket and lock, answers `Ok` and exits, whatever sessions run.
    /// They carry on in their holders, which register with the host started
    /// next (`cherry restart` starts it). For a host whose executable was
    /// replaced or removed by an update of the same protocol.
    Restart,
    /// Push `ServerMessage::Event`s on this connection from now on; answered
    /// `Ok`. See the crate documentation.
    Subscribe,
    /// Write `data` (at most `MAX_INPUT_BYTES`) to a session's terminal
    /// without attaching; answered `Ok`, or `Error{not_running}` once the
    /// session has exited.
    SendInput {
        id: String,
        #[serde(with = "base64_bytes")]
        data: Vec<u8>,
    },
    /// Read a session's screen as plain text; answered `ScreenText`. With
    /// `scrollback`, the retained history above the screen comes first.
    /// With `max_lines`, only the last that many lines of that text come,
    /// and `ScreenText::cursor_row` counts from the first of them. A host
    /// that knows `max_lines` sends `Sessions::pending_holders`; an older
    /// one ignores it and answers as without it (the whole text, and the
    /// cursor's row on the screen), so a client that relies on it lists
    /// the sessions first.
    Screen {
        id: String,
        scrollback: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        max_lines: Option<u32>,
    },
    /// Clear the history above a session's screen (protocol 7), as `ED 3`
    /// (`CSI 3 J`) would at this point of its output: snapshots, `Screen`
    /// and every later attachment show none of it. Answered `Ok`;
    /// `Error{unsupported_operation}` for a session whose holder predates
    /// link version 7. Attached clients keep the history their own
    /// terminals show.
    ClearHistory {
        id: String,
    },
    /// Describe the host (protocol 7): answered `Status`. An older host of
    /// this version answers `Error{unsupported_operation}`.
    Status,
    /// Rename a session or replace its tags (the whole map); answered `Ok`.
    /// A field left out is kept.
    Update {
        id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        tags: Option<BTreeMap<String, String>>,
    },
}

impl ClientMessage {
    pub fn hello() -> Self {
        Self::Hello {
            version: PROTOCOL_VERSION,
        }
    }

    /// Whether this request belongs to the connection's attachment, so that
    /// everything answering it is attachment traffic, which carries no `req`.
    pub fn belongs_to_attachment(&self) -> bool {
        matches!(
            self,
            Self::Attach { .. }
                | Self::Input { .. }
                | Self::Resize { .. }
                | Self::Refresh
                | Self::Detach
        )
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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    /// The answer to every `Hello`, with the host's own version. Frozen:
    /// `build` is the one field added to it, which every version ignores.
    Welcome {
        version: u32,
        host_id: String,
        /// The daemon's build ([`BUILD`]). None from a host older than the
        /// field. A client of the same version replaces a daemon of an
        /// older build only through `Restart` (see the CLI).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        build: Option<String>,
    },
    Sessions {
        host_id: String,
        sessions: Vec<SessionInfo>,
        /// How many sessions a host that just started still expects to
        /// hear from: their processes outlived the previous host and have
        /// not registered with this one yet, so they may not be in
        /// `sessions` (one that registers while the list is made can be
        /// both listed and counted, but a session is never neither). 0
        /// when the list is complete. A client that misses a session it
        /// knows should list again while this is not 0. Always sent by a
        /// host that knows it (and `ClientMessage::Screen`'s `max_lines`);
        /// missing from an older host's list.
        #[serde(default)]
        pending_holders: u32,
        /// Sessions whose holders were gone when this host started, without
        /// having ended: each left its manifest behind (it was killed with
        /// the user's processes at a log out, or by a signal) instead of
        /// removing it as a holder does when it exits. They are not in
        /// `sessions`. A session ended on purpose (Kill, Remove, its
        /// program's exit) is never here. Sorted; for this host's lifetime.
        /// Left out when empty, and by an older host.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        lost_sessions: Vec<String>,
    },
    Created {
        session: SessionInfo,
    },
    /// Initial attachment or an atomic replacement snapshot after the
    /// shared terminal grid changes or a lagging client is resynchronized.
    /// Subsequent Output resumes at offset. A binary frame only
    /// (`binary_kind::ATTACHED`): everything but the snapshot is its JSON
    /// header.
    #[serde(skip)]
    Attached {
        session: SessionInfo,
        offset: u64,
        snapshot: Vec<u8>,
        reason: AttachReason,
        /// The host answers `ClientMessage::Refresh`, so a client that
        /// shows the stream as it is need not keep a copy of the screen.
        /// Every host of this version sends true.
        refreshes: bool,
    },
    /// The shared grid changed to `cols` by `rows` at `offset` without a
    /// replacement snapshot, because the program shows the alternate
    /// screen and redraws it itself (full-screen programs repaint when
    /// their terminal is resized). Sent instead of `Attached{Resize}` to a
    /// client that renders the stream and keeps a copy of it: the output
    /// before `offset` was made for the old size, the output from
    /// `offset` on for the new one. The client resizes its copy there and
    /// keeps what its window shows until the repaint arrives (a window of
    /// another size then paints its viewport from the resized copy), and
    /// continues with the output at `offset`, which follows in stream
    /// order. Never sent in reply to
    /// `Attach`, nor to a client that needs history (a window that painted
    /// a viewport and now matches the grid gets a full `Attached{Resize}`).
    Resized {
        offset: u64,
        cols: u16,
        rows: u16,
    },
    /// offset is the first byte position of this chunk, not its end. A
    /// binary frame only (`binary_kind::OUTPUT`).
    #[serde(skip)]
    Output {
        offset: u64,
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
    /// is attached they are dropped. A binary frame only
    /// (`binary_kind::QUERY`).
    #[serde(skip)]
    Query {
        data: Vec<u8>,
    },
    Exit {
        id: String,
        exit_code: u32,
        signal: Option<i32>,
    },
    Pong,
    /// Frozen.
    Ok,
    /// Frozen.
    Error {
        code: String,
        message: String,
    },
    /// Pushed to a subscribed connection; never carries `req`.
    Event {
        event: SessionEvent,
    },
    /// The answer to `Screen`: the screen as plain text, lines separated by
    /// `\n`, trailing blanks (and blank rows at the end) trimmed and
    /// soft-wrapped rows joined into one line. The cursor is zero-based, and
    /// `alternate_screen` tells which screen it is on.
    ///
    /// Without `max_lines`, `cursor_row` is the cursor's row on the active
    /// screen (row 0 is its top row, whatever `text` holds above it). With
    /// `max_lines`, it is the line of `text` that holds the cursor: the
    /// cursor is on `text.split('\n').nth(cursor_row)`, or below the last
    /// line when blank rows after the text hold it. When the cursor is above
    /// the lines returned (fewer asked for than lie below it), and for
    /// `max_lines` 0 (an empty text), it is 0. `cursor_col` is the cursor's
    /// column on the screen either way. (For a session whose process
    /// predates `max_lines`, the host limits the whole text itself and
    /// estimates the cursor's line from its row.)
    ScreenText {
        id: String,
        text: String,
        cursor_row: u16,
        cursor_col: u16,
        alternate_screen: bool,
    },
    /// The answer to `Status`.
    Status {
        status: HostStatus,
    },
}

/// What a daemon says about itself (`ServerMessage::Status`, `cherry
/// status`). Fields a newer host adds are ignored by an older client.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct HostStatus {
    pub host_id: String,
    /// Its protocol version.
    pub version: u32,
    /// Its build ([`BUILD`]).
    pub build: String,
    pub pid: u32,
    /// When it started, in milliseconds since the Unix epoch.
    pub started_at: u64,
    /// How long it has run, in milliseconds (on the clock that stops while
    /// the machine sleeps).
    pub uptime_ms: u64,
    pub socket: String,
    pub state_dir: String,
    /// The log it writes to, when that is a file (`host.log`).
    #[serde(default)]
    pub log_path: Option<String>,
    /// Where its executable is now, when it can tell.
    #[serde(default)]
    pub executable: Option<String>,
    /// Its executable was removed or replaced (by an update) since it
    /// started: new sessions run the executable found there now, or fail
    /// when there is none.
    #[serde(default)]
    pub executable_changed: bool,
    /// Sessions it serves, and how many of them run.
    pub sessions: u32,
    pub running_sessions: u32,
    /// The most sessions it keeps, exited ones included.
    pub max_sessions: u32,
    /// Open connections (clients and holders' links) and the most it serves.
    pub connections: u32,
    pub max_connections: u32,
    /// Sessions whose holders are connected to it.
    pub holders_registered: u32,
    /// Holders that outlived the previous daemon and have not registered
    /// with this one yet (`Sessions::pending_holders`).
    pub holders_expected: u32,
    /// Sessions whose holders were gone when it started
    /// (`Sessions::lost_sessions`).
    #[serde(default)]
    pub lost_sessions: u32,
    /// Its descriptor limit (the soft `RLIMIT_NOFILE`), when known.
    #[serde(default)]
    pub fd_limit: Option<u64>,
}

impl ServerMessage {
    pub fn error(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self::Error {
            code: code.into(),
            message: message.into(),
        }
    }
}

/// What a subscribed connection is told (`ServerMessage::Event`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SessionEvent {
    Added {
        session: SessionInfo,
    },
    /// Any field of the session changed: state, size, clients, title, pwd,
    /// foreground process, name, tags, the alternate screen, the kitty
    /// keyboard flags or application cursor keys.
    Changed {
        session: SessionInfo,
    },
    Removed {
        id: String,
    },
    /// The program rang the bell (BEL).
    Bell {
        id: String,
    },
    /// The program asked for a desktop notification (OSC 9, OSC 777 or
    /// OSC 99). `title` is empty when it gave none.
    Notification {
        id: String,
        title: String,
        body: String,
    },
    /// The program reported progress (OSC 9;4). `value` is a percentage,
    /// absent when it gave none.
    Progress {
        id: String,
        state: ProgressState,
        value: Option<u8>,
    },
    Exited {
        id: String,
        /// 128 + signal number when the process was killed by a signal.
        exit_code: u32,
        signal: Option<i32>,
        /// As `SessionInfo::ended_by`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        ended_by: Option<String>,
        /// As `SessionInfo::holder_log`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        holder_log: Option<String>,
    },
    /// This subscriber fell behind and missed events: list the sessions
    /// again.
    Resync,
}

/// A progress report's state (OSC 9;4).
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProgressState {
    /// Stop showing progress.
    Remove,
    /// Determinate progress.
    Set,
    Error,
    Indeterminate,
    Pause,
}

/// Why session tags exceed the protocol's limits, if they do.
pub fn check_tags(tags: &BTreeMap<String, String>) -> Result<(), String> {
    if tags.len() > MAX_TAGS {
        return Err(format!("a session has at most {MAX_TAGS} tags"));
    }
    if tags
        .keys()
        .any(|key| key.is_empty() || key.len() > MAX_TAG_KEY_BYTES)
    {
        return Err(format!(
            "tag keys must be 1 to {MAX_TAG_KEY_BYTES} bytes long"
        ));
    }
    if tags
        .iter()
        .map(|(key, value)| key.len() + value.len())
        .sum::<usize>()
        > MAX_TAG_BYTES
    {
        return Err(format!("tags exceed {MAX_TAG_BYTES} bytes"));
    }
    Ok(())
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

/// The socket path used when neither --socket nor CHERRY_HOST_SOCKET is set.
pub fn builtin_socket_path() -> PathBuf {
    PathBuf::from(format!("/tmp/cherry-host-{}/host.sock", euid()))
}

/// Where the host serving `socket` keeps its durable state (identity, lock,
/// log, PID file and session manifests), without creating it:
/// `~/Library/Application Support/cherry-host/<key>` on macOS and
/// `${XDG_STATE_HOME:-~/.local/state}/cherry-host/<key>` elsewhere. The key
/// is `default` for the built-in socket and a stable hash of any other
/// socket path.
pub fn state_dir(socket: &Path) -> io::Result<PathBuf> {
    let home = home_dir()?;
    #[cfg(target_os = "macos")]
    let base = home.join("Library/Application Support");
    #[cfg(not(target_os = "macos"))]
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .unwrap_or_else(|| home.join(".local/state"));
    Ok(base.join("cherry-host").join(state_key(socket)))
}

/// The last part of `state_dir`.
pub fn state_key(socket: &Path) -> String {
    if socket == builtin_socket_path() {
        return "default".into();
    }
    // FNV-1a: stable across builds and platforms, unlike std's hasher.
    let hash = socket
        .as_os_str()
        .as_encoded_bytes()
        .iter()
        .fold(0xcbf2_9ce4_8422_2325u64, |hash, &byte| {
            (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
        });
    format!("{hash:016x}")
}

/// HOME when it is an absolute path, otherwise the password database entry.
pub fn home_dir() -> io::Result<PathBuf> {
    if let Some(home) = std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|home| home.is_absolute())
    {
        return Ok(home);
    }
    passwd_field(|entry| entry.pw_dir)
        .map(PathBuf::from)
        .ok_or_else(|| {
            io::Error::other("cannot determine this user's home directory (HOME is not set)")
        })
}

/// A field of this user's password database entry, when it is not empty.
pub fn passwd_field(
    field: impl Fn(&libc::passwd) -> *mut libc::c_char,
) -> Option<std::ffi::OsString> {
    use std::os::unix::ffi::OsStringExt;
    let mut buffer = vec![0 as libc::c_char; 16 * 1024];
    let mut entry: libc::passwd = unsafe { std::mem::zeroed() };
    let mut result = std::ptr::null_mut();
    let status = unsafe {
        libc::getpwuid_r(
            euid(),
            &mut entry,
            buffer.as_mut_ptr(),
            buffer.len(),
            &mut result,
        )
    };
    if status != 0 || result.is_null() {
        return None;
    }
    let value = field(&entry);
    if value.is_null() {
        return None;
    }
    let bytes = unsafe { std::ffi::CStr::from_ptr(value) }
        .to_bytes()
        .to_vec();
    (!bytes.is_empty()).then(|| std::ffi::OsString::from_vec(bytes))
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

fn invalid(message: impl Into<Box<dyn std::error::Error + Send + Sync>>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

/// A message that travels in frames: a JSON frame, or a binary one for an
/// attachment's terminal bytes (see the crate documentation).
pub trait Message: Sized {
    /// Append the frame's body: what follows its length word.
    fn encode_body(&self, out: &mut Vec<u8>) -> io::Result<()>;
    /// The message in a frame's body.
    fn decode_body(body: &[u8]) -> io::Result<Self>;
}

/// Whether a frame's body is a JSON message rather than a binary frame.
fn is_json(body: &[u8]) -> bool {
    body.first() == Some(&b'{')
}

fn json_body<T: Serialize>(value: &T, out: &mut Vec<u8>) -> io::Result<()> {
    serde_json::to_writer(out, value).map_err(invalid)
}

fn from_json<T: for<'de> Deserialize<'de>>(body: &[u8]) -> io::Result<T> {
    serde_json::from_slice(body).map_err(invalid)
}

/// The frame of `ClientMessage::Input { data }` (at most
/// `MAX_INPUT_BYTES`; a longer one is the caller's to split).
pub fn encode_input_frame(data: &[u8]) -> io::Result<Vec<u8>> {
    binary_frame(binary_kind::INPUT, &[], data)
}

/// The frame of `ServerMessage::Output { offset, data }`: `OUTPUT_HEADER`
/// bytes, then `data`.
pub fn encode_output_frame(offset: u64, data: &[u8]) -> io::Result<Vec<u8>> {
    binary_frame(binary_kind::OUTPUT, &offset.to_be_bytes(), data)
}

/// The frame of `ServerMessage::Query { data }`.
pub fn encode_query_frame(data: &[u8]) -> io::Result<Vec<u8>> {
    binary_frame(binary_kind::QUERY, &[], data)
}

/// The JSON header of an `Attached` frame, borrowed to encode it.
#[derive(Serialize)]
struct AttachedHeaderRef<'a> {
    session: &'a SessionInfo,
    offset: u64,
    reason: AttachReason,
    refreshes: bool,
}

/// The JSON header of an `Attached` frame, as decoded.
#[derive(Deserialize)]
struct AttachedHeader {
    session: SessionInfo,
    offset: u64,
    reason: AttachReason,
    #[serde(default)]
    refreshes: bool,
}

/// The frame of `ServerMessage::Attached`, with `snapshot` as it is.
pub fn encode_attached_frame(
    session: &SessionInfo,
    offset: u64,
    reason: AttachReason,
    refreshes: bool,
    snapshot: &[u8],
) -> io::Result<Vec<u8>> {
    let header = serde_json::to_vec(&AttachedHeaderRef {
        session,
        offset,
        reason,
        refreshes,
    })
    .map_err(invalid)?;
    let header_len = u32::try_from(header.len()).map_err(|_| invalid("frame exceeds limit"))?;
    let mut frame = Vec::with_capacity(4 + 1 + 4 + header.len() + snapshot.len());
    frame.extend_from_slice(&[0; 4]);
    frame.push(binary_kind::ATTACHED);
    frame.extend_from_slice(&header_len.to_be_bytes());
    frame.extend_from_slice(&header);
    frame.extend_from_slice(snapshot);
    seal(frame)
}

/// A binary frame: `kind`, `head`, then `data`.
fn binary_frame(kind: u8, head: &[u8], data: &[u8]) -> io::Result<Vec<u8>> {
    let mut frame = Vec::with_capacity(4 + 1 + head.len() + data.len());
    frame.extend_from_slice(&[0; 4]);
    frame.push(kind);
    frame.extend_from_slice(head);
    frame.extend_from_slice(data);
    seal(frame)
}

/// Fill in the length word of `frame`, whose body follows 4 bytes left for
/// it; an error when the body exceeds `MAX_FRAME_BYTES`.
fn seal(mut frame: Vec<u8>) -> io::Result<Vec<u8>> {
    let len = frame.len() - 4;
    if len > MAX_FRAME_BYTES {
        return Err(invalid("frame exceeds limit"));
    }
    frame[..4].copy_from_slice(&(len as u32).to_be_bytes());
    Ok(frame)
}

/// The offset and the output of an `Output` frame (length word included),
/// or None when it is not one.
pub fn output_frame_parts(frame: &[u8]) -> Option<(u64, &[u8])> {
    if frame.len() < OUTPUT_HEADER || frame[4] != binary_kind::OUTPUT {
        return None;
    }
    let offset = u64::from_be_bytes(frame[5..OUTPUT_HEADER].try_into().ok()?);
    Some((offset, &frame[OUTPUT_HEADER..]))
}

/// A binary frame's message from the host.
fn decode_server_binary(body: &[u8]) -> io::Result<ServerMessage> {
    let (&kind, rest) = body.split_first().ok_or_else(|| invalid("empty frame"))?;
    match kind {
        binary_kind::OUTPUT => {
            if rest.len() < 8 {
                return Err(invalid("truncated output frame"));
            }
            let (offset, data) = rest.split_at(8);
            Ok(ServerMessage::Output {
                offset: u64::from_be_bytes(offset.try_into().unwrap()),
                data: data.to_vec(),
            })
        }
        binary_kind::QUERY => Ok(ServerMessage::Query {
            data: rest.to_vec(),
        }),
        binary_kind::ATTACHED => {
            if rest.len() < 4 {
                return Err(invalid("truncated attached frame"));
            }
            let (len, rest) = rest.split_at(4);
            let len = u32::from_be_bytes(len.try_into().unwrap()) as usize;
            if len > rest.len() {
                return Err(invalid("attached header exceeds the frame"));
            }
            let (header, snapshot) = rest.split_at(len);
            if !is_json(header) {
                return Err(invalid("attached header is not a JSON object"));
            }
            let header: AttachedHeader = from_json(header)?;
            Ok(ServerMessage::Attached {
                session: header.session,
                offset: header.offset,
                snapshot: snapshot.to_vec(),
                reason: header.reason,
                refreshes: header.refreshes,
            })
        }
        kind => Err(invalid(format!("unexpected binary frame of kind {kind}"))),
    }
}

/// A binary frame's message from a client.
fn decode_client_binary(body: &[u8]) -> io::Result<ClientMessage> {
    let (&kind, rest) = body.split_first().ok_or_else(|| invalid("empty frame"))?;
    match kind {
        binary_kind::INPUT => Ok(ClientMessage::Input {
            data: rest.to_vec(),
        }),
        kind => Err(invalid(format!("unexpected binary frame of kind {kind}"))),
    }
}

impl ServerMessage {
    /// Whether it travels in a binary frame.
    fn is_binary(&self) -> bool {
        matches!(
            self,
            Self::Output { .. } | Self::Query { .. } | Self::Attached { .. }
        )
    }

    /// The binary frame of a message that has one.
    fn binary_frame(&self) -> Option<io::Result<Vec<u8>>> {
        Some(match self {
            Self::Output { offset, data } => encode_output_frame(*offset, data),
            Self::Query { data } => encode_query_frame(data),
            Self::Attached {
                session,
                offset,
                snapshot,
                reason,
                refreshes,
            } => encode_attached_frame(session, *offset, *reason, *refreshes, snapshot),
            _ => return None,
        })
    }
}

/// Append a binary frame's body (made whole, length word and all) to `out`.
fn append_body(frame: io::Result<Vec<u8>>, out: &mut Vec<u8>) -> io::Result<()> {
    out.extend_from_slice(&frame?[4..]);
    Ok(())
}

impl Message for ClientMessage {
    fn encode_body(&self, out: &mut Vec<u8>) -> io::Result<()> {
        match self {
            Self::Input { data } => append_body(encode_input_frame(data), out),
            message => json_body(message, out),
        }
    }

    fn decode_body(body: &[u8]) -> io::Result<Self> {
        if is_json(body) {
            from_json(body)
        } else {
            decode_client_binary(body)
        }
    }
}

impl Message for Request {
    /// A binary frame carries no `req`: `Input` is attachment traffic,
    /// whose `req` the host ignores.
    fn encode_body(&self, out: &mut Vec<u8>) -> io::Result<()> {
        match &self.message {
            ClientMessage::Input { .. } => self.message.encode_body(out),
            _ => json_body(self, out),
        }
    }

    fn decode_body(body: &[u8]) -> io::Result<Self> {
        if is_json(body) {
            from_json(body)
        } else {
            decode_client_binary(body).map(Self::from)
        }
    }
}

impl Message for ServerMessage {
    fn encode_body(&self, out: &mut Vec<u8>) -> io::Result<()> {
        match self.binary_frame() {
            Some(frame) => append_body(frame, out),
            None => json_body(self, out),
        }
    }

    fn decode_body(body: &[u8]) -> io::Result<Self> {
        if is_json(body) {
            from_json(body)
        } else {
            decode_server_binary(body)
        }
    }
}

impl Message for Response {
    /// A binary frame carries no `req`: it is attachment traffic.
    fn encode_body(&self, out: &mut Vec<u8>) -> io::Result<()> {
        if self.message.is_binary() {
            self.message.encode_body(out)
        } else {
            json_body(self, out)
        }
    }

    fn decode_body(body: &[u8]) -> io::Result<Self> {
        if is_json(body) {
            from_json(body)
        } else {
            decode_server_binary(body).map(Self::from)
        }
    }
}

pub fn write_frame<W: Write, T: Message>(writer: &mut W, value: &T) -> io::Result<()> {
    let bytes = encode_frame(value)?;
    writer.write_all(&bytes)?;
    writer.flush()
}

/// A complete frame (length prefix and body), for callers that queue bytes.
pub fn encode_frame<T: Message>(value: &T) -> io::Result<Vec<u8>> {
    let mut frame = vec![0; 4];
    value.encode_body(&mut frame)?;
    seal(frame)
}

/// A frame's body length from its length word; an error when no frame can
/// have it (zero, or beyond `MAX_FRAME_BYTES`).
pub fn frame_length(word: [u8; 4]) -> io::Result<usize> {
    let len = u32::from_be_bytes(word) as usize;
    if len == 0 || len > MAX_FRAME_BYTES {
        return Err(invalid("invalid frame length"));
    }
    Ok(len)
}

pub fn read_frame<R: Read, T: Message>(reader: &mut R) -> io::Result<Option<T>> {
    match read_frame_body(reader)? {
        Some(bytes) => T::decode_body(&bytes).map(Some),
        None => Ok(None),
    }
}

/// A frame's body (what follows its length word), undecoded; None at end
/// of file. For a reader that answers a frame it cannot decode (see
/// `RequestProblem`).
pub fn read_frame_body<R: Read>(reader: &mut R) -> io::Result<Option<Vec<u8>>> {
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
    let len = frame_length(header)?;
    let mut bytes = vec![0; len];
    reader.read_exact(&mut bytes)?;
    Ok(Some(bytes))
}

/// What a host answers a JSON request of a negotiated connection that it
/// cannot decode (protocol 7): an unknown `op` (a newer client's request)
/// is `unsupported_operation`, a known one with fields it cannot take
/// `request_failed`, each with the frame's `req` when that is a number. The
/// connection carries on. None for a body that is no JSON object with an
/// `op`, which ends the connection unanswered.
pub fn undecodable_request(body: &[u8], error: &io::Error) -> Option<Response> {
    if !is_json(body) {
        return None;
    }
    let value: serde_json::Value = serde_json::from_slice(body).ok()?;
    let op = value.get("op")?.as_str()?.to_string();
    let req = value.get("req").and_then(serde_json::Value::as_u64);
    let unknown = serde_json::from_value::<ClientMessage>(serde_json::json!({ "op": op }))
        .err()
        .is_some_and(|error| error.to_string().contains("unknown variant"));
    let message = if unknown {
        ServerMessage::error(
            error_code::UNSUPPORTED_OPERATION,
            format!("this host (protocol {PROTOCOL_VERSION}) does not know the request {op:?}"),
        )
    } else {
        ServerMessage::error(
            error_code::REQUEST_FAILED,
            format!("malformed {op} request: {error}"),
        )
    };
    Some(Response::new(req, message))
}

/// Terminal bytes inside JSON messages (`SendInput`) travel as standard
/// base64 strings (4/3 expansion) instead of JSON number arrays (3–4x
/// expansion).
pub mod base64_bytes {
    use serde::{
        de::{Error, Visitor},
        Deserializer, Serializer,
    };

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

    /// Each character's value, or `INVALID` for one outside the alphabet
    /// (padding included).
    const INVALID: u8 = 0xff;
    static VALUES: [u8; 256] = {
        let mut values = [INVALID; 256];
        let mut i = 0;
        while i < 64 {
            values[ALPHABET[i] as usize] = i as u8;
            i += 1;
        }
        values
    };

    pub fn decode(text: &str) -> Result<Vec<u8>, &'static str> {
        let text = text.as_bytes();
        if text.len() % 4 != 0 {
            return Err("base64 length is not a multiple of 4");
        }
        let Some(split) = text.len().checked_sub(4) else {
            return Ok(Vec::new());
        };
        // Every group but the last has no padding: a table lookup per
        // character, and one check per group.
        let (body, last) = text.split_at(split);
        let mut out = vec![0u8; body.len() / 4 * 3];
        for (group, bytes) in body.chunks_exact(4).zip(out.chunks_exact_mut(3)) {
            let [a, b, c, d] = [0, 1, 2, 3].map(|i| VALUES[group[i] as usize]);
            if (a | b | c | d) & 0xc0 != 0 {
                return Err("invalid base64");
            }
            let n =
                (u32::from(a) << 18) | (u32::from(b) << 12) | (u32::from(c) << 6) | u32::from(d);
            bytes.copy_from_slice(&n.to_be_bytes()[1..]);
        }
        // The last group may end in one or two `=`, and nothing after them.
        let mut n = 0u32;
        let mut padding = 0;
        for (i, &c) in last.iter().enumerate() {
            let value = match VALUES[c as usize] {
                INVALID if c == b'=' && i >= 2 => {
                    padding += 1;
                    0
                }
                INVALID => return Err("invalid base64"),
                _ if padding > 0 => return Err("invalid base64 padding"),
                value => value,
            };
            n = (n << 6) | u32::from(value);
        }
        out.extend_from_slice(&n.to_be_bytes()[1..4 - padding]);
        Ok(out)
    }

    pub fn serialize<S: Serializer>(bytes: &[u8], serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&encode(bytes))
    }

    /// Decodes the string where the deserializer has it (the frame's own
    /// bytes, when it can lend them), rather than copying it first.
    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Vec<u8>, D::Error> {
        struct Base64;
        impl Visitor<'_> for Base64 {
            type Value = Vec<u8>;

            fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                formatter.write_str("a base64 string")
            }

            fn visit_str<E: Error>(self, text: &str) -> Result<Vec<u8>, E> {
                decode(text).map_err(E::custom)
            }
        }
        deserializer.deserialize_str(Base64)
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
    fn terminal_bytes_travel_as_they_are_in_binary_frames() {
        let data: Vec<u8> = (0..=255).chain(b"\x1b[1mhi{".iter().copied()).collect();
        // Output: kind, offset, bytes.
        let frame = encode_frame(&ServerMessage::Output {
            offset: 1 << 40,
            data: data.clone(),
        })
        .unwrap();
        assert_eq!(frame.len(), OUTPUT_HEADER + data.len());
        assert_eq!(
            u32::from_be_bytes(frame[..4].try_into().unwrap()) as usize,
            frame.len() - 4
        );
        assert_eq!(frame[4], binary_kind::OUTPUT);
        assert_eq!(&frame[5..13], &(1u64 << 40).to_be_bytes());
        assert_eq!(&frame[13..], &data[..]);
        assert_eq!(frame, encode_output_frame(1 << 40, &data).unwrap());
        assert_eq!(output_frame_parts(&frame), Some((1 << 40, &data[..])));
        // Query and Input: kind, bytes.
        let frame = encode_frame(&ServerMessage::Query {
            data: b"\x1b[?6n".to_vec(),
        })
        .unwrap();
        assert_eq!(frame, b"\0\0\0\x06\x03\x1b[?6n");
        assert_eq!(output_frame_parts(&frame), None);
        let frame = encode_frame(&ClientMessage::Input {
            data: b"ls\r".to_vec(),
        })
        .unwrap();
        assert_eq!(frame, b"\0\0\0\x04\x02ls\r");
        // An empty one is a frame of its kind alone.
        assert_eq!(encode_input_frame(b"").unwrap(), b"\0\0\0\x01\x02");
        // Attached: kind, header length, JSON header, snapshot.
        let session = session_info();
        let frame = encode_frame(&ServerMessage::Attached {
            session: session.clone(),
            offset: 7,
            snapshot: b"\x1bcSCREEN".to_vec(),
            reason: AttachReason::Resize,
            refreshes: true,
        })
        .unwrap();
        assert_eq!(frame[4], binary_kind::ATTACHED);
        let header_len = u32::from_be_bytes(frame[5..9].try_into().unwrap()) as usize;
        let header: serde_json::Value = serde_json::from_slice(&frame[9..9 + header_len]).unwrap();
        assert_eq!(header["offset"], 7);
        assert_eq!(header["reason"], "resize");
        assert_eq!(header["refreshes"], true);
        assert_eq!(header["session"]["id"], "3f6c");
        assert_eq!(&frame[9 + header_len..], b"\x1bcSCREEN");
        // The largest snapshot fits a frame, whatever its header.
        const { assert!(MAX_SNAPSHOT_BYTES + 64 * 1024 < MAX_FRAME_BYTES) };
    }

    #[test]
    fn the_json_forms_of_binary_messages_are_gone() {
        for text in [
            r#"{"type":"output","offset":0,"data":"eA=="}"#,
            r#"{"type":"query","data":"eA=="}"#,
            r#"{"type":"attached","session":{},"offset":0,"snapshot":"","reason":"attach"}"#,
        ] {
            let frame = [&(text.len() as u32).to_be_bytes()[..], text.as_bytes()].concat();
            assert!(
                read_frame::<_, ServerMessage>(&mut frame.as_slice()).is_err(),
                "{text}"
            );
            assert!(read_frame::<_, Response>(&mut frame.as_slice()).is_err());
        }
        let text = r#"{"op":"input","data":"eA=="}"#;
        let frame = [&(text.len() as u32).to_be_bytes()[..], text.as_bytes()].concat();
        assert!(read_frame::<_, ClientMessage>(&mut frame.as_slice()).is_err());
        assert!(read_frame::<_, Request>(&mut frame.as_slice()).is_err());
        // And serde refuses to make them.
        assert!(serde_json::to_string(&ClientMessage::Input { data: vec![1] }).is_err());
        assert!(serde_json::to_string(&ServerMessage::Query { data: vec![1] }).is_err());
    }

    #[test]
    fn malformed_binary_frames_are_rejected() {
        let frame = |body: &[u8]| [&(body.len() as u32).to_be_bytes()[..], body].concat();
        for body in [
            // Unknown kinds, and a JSON frame that does not start with `{`.
            &[9u8, 1, 2][..],
            &[0],
            b" {\"type\":\"ok\"}",
            // Output too short to hold its offset.
            &[binary_kind::OUTPUT, 0, 0, 0, 0, 0, 0, 0],
            // An Attached header longer than the frame, not JSON, or
            // without its fields.
            &[binary_kind::ATTACHED, 0, 0, 0, 9, b'{', b'}'],
            &[binary_kind::ATTACHED, 0, 0],
            &[binary_kind::ATTACHED, 0, 0, 0, 2, b'[', b']'],
            &[binary_kind::ATTACHED, 0, 0, 0, 2, b'{', b'}'],
            // A client's frame from the host.
            &[binary_kind::INPUT, b'x'],
        ] {
            assert!(
                read_frame::<_, Response>(&mut frame(body).as_slice()).is_err(),
                "{body:?}"
            );
        }
        // The host's frames from a client.
        for kind in [
            binary_kind::OUTPUT,
            binary_kind::QUERY,
            binary_kind::ATTACHED,
            7,
        ] {
            let body = [kind, 0, 0, 0, 0, 0, 0, 0, 0, 0];
            assert!(read_frame::<_, Request>(&mut frame(&body).as_slice()).is_err());
            assert!(read_frame::<_, ClientMessage>(&mut frame(&body).as_slice()).is_err());
        }
        // A binary frame cut short is an error, as a JSON one is.
        let output = encode_output_frame(0, b"abc").unwrap();
        assert!(read_frame::<_, Response>(&mut &output[..output.len() - 1]).is_err());
        // Frames beyond the limit are refused both ways.
        assert!(encode_output_frame(0, &vec![0; MAX_FRAME_BYTES - 9]).is_ok());
        assert!(encode_output_frame(0, &vec![0; MAX_FRAME_BYTES - 8]).is_err());
        assert!(frame_length((MAX_FRAME_BYTES as u32 + 1).to_be_bytes()).is_err());
        assert!(frame_length([0; 4]).is_err());
        assert_eq!(
            frame_length((MAX_FRAME_BYTES as u32).to_be_bytes()).unwrap(),
            MAX_FRAME_BYTES
        );
    }

    #[test]
    fn binary_frames_carry_no_request_id() {
        // Attachment traffic, whose req is ignored: none is sent.
        let input = Request::new(
            Some(4),
            ClientMessage::Input {
                data: b"x".to_vec(),
            },
        );
        let frame = encode_frame(&input).unwrap();
        assert_eq!(frame, encode_input_frame(b"x").unwrap());
        assert_eq!(
            read_frame::<_, Request>(&mut frame.as_slice()).unwrap(),
            Some(Request::from(ClientMessage::Input {
                data: b"x".to_vec()
            }))
        );
        let output = Response::new(
            Some(4),
            ServerMessage::Output {
                offset: 1,
                data: b"x".to_vec(),
            },
        );
        let frame = encode_frame(&output).unwrap();
        assert_eq!(frame, encode_output_frame(1, b"x").unwrap());
        assert_eq!(
            read_frame::<_, Response>(&mut frame.as_slice())
                .unwrap()
                .unwrap()
                .req,
            None
        );
    }

    /// The decoder before the lookup table: the table must accept and
    /// reject exactly what it did.
    fn reference_decode(text: &str) -> Result<Vec<u8>, &'static str> {
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

    #[test]
    fn base64_decoding_matches_the_reference_on_any_input() {
        // Every character in every position of a short string, then random
        // strings over an alphabet weighted towards the tricky ones.
        let mut texts = Vec::new();
        for c in 0..=255u8 {
            for position in 0..8 {
                let mut text = b"QUJDREVG".to_vec();
                text[position] = c;
                texts.push(text.clone());
                text.truncate(4);
                if position < 4 {
                    texts.push(text);
                }
            }
        }
        let mut seed = 0x2545_f491_4f6c_dd1du64;
        let mut next = move || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };
        let pool = b"AZaz09+/==*-_ \n\0\xff";
        for _ in 0..20_000 {
            let len = (next() % 24) as usize;
            texts.push(
                (0..len)
                    .map(|_| match next() % 4 {
                        0 => pool[(next() % pool.len() as u64) as usize],
                        _ => base64_bytes::encode(&[next() as u8]).as_bytes()[0],
                    })
                    .collect(),
            );
        }
        for text in texts {
            // The decoder takes a str; bytes that are not UTF-8 never reach it.
            let Ok(text) = std::str::from_utf8(&text) else {
                continue;
            };
            assert_eq!(
                base64_bytes::decode(text),
                reference_decode(text),
                "{text:?}"
            );
        }
        for len in 0..300usize {
            let bytes: Vec<u8> = (0..len).map(|i| (i * 131 + len) as u8).collect();
            let text = base64_bytes::encode(&bytes);
            assert_eq!(base64_bytes::decode(&text).unwrap(), bytes);
            assert_eq!(reference_decode(&text).unwrap(), bytes);
        }
    }

    #[test]
    fn base64_fields_decode_from_escaped_and_borrowed_strings() {
        // A peer may escape characters JSON allows it to escape; the
        // decoder then gets a string of its own rather than the frame's.
        for text in [
            r#"{"op":"send_input","id":"s","data":"Zm9vYmFy"}"#,
            r#"{"op":"send_input","id":"s","data":"Zm9vYmFy"}"#,
            r#"{"op":"send_input","id":"s","data":"Zm9vYmFy","req":null}"#,
        ] {
            let expected = ClientMessage::SendInput {
                id: "s".into(),
                data: b"foobar".to_vec(),
            };
            assert_eq!(
                serde_json::from_str::<Request>(text).unwrap().message,
                expected,
                "{text}"
            );
            assert_eq!(
                serde_json::from_slice::<ClientMessage>(text.as_bytes()).unwrap(),
                expected,
                "{text}"
            );
        }
        let error =
            serde_json::from_str::<ClientMessage>(r#"{"op":"send_input","id":"s","data":"Zm=v"}"#)
                .unwrap_err()
                .to_string();
        assert!(error.contains("invalid base64 padding"), "{error}");
        assert!(serde_json::from_str::<ClientMessage>(
            r#"{"op":"send_input","id":"s","data":[1,2]}"#
        )
        .is_err());
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
                client_id: None,
                ..
            })
        ));
        // A client ID is optional, and sent only when there is one.
        assert!(matches!(
            serde_json::from_str::<ClientMessage>(
                r#"{"op":"attach","id":"a","cols":80,"rows":24,"takeover":false,"answers_queries":true,"client_id":"tab-1"}"#
            ),
            Ok(ClientMessage::Attach {
                client_id: Some(id),
                ..
            }) if id == "tab-1"
        ));
        assert!(!json(&ClientMessage::Attach {
            id: "a".into(),
            cols: 80,
            rows: 24,
            takeover: false,
            answers_queries: true,
            client_id: None,
        })
        .contains("client_id"));
    }
    fn json<T: Serialize>(value: &T) -> String {
        serde_json::to_string(value).unwrap()
    }

    #[test]
    fn frozen_shapes_never_change() {
        let hello = ClientMessage::Hello { version: 4 };
        let welcome = ServerMessage::Welcome {
            version: 4,
            host_id: "0b7e3c4a-6f1d-4d0e-9a51-2f3c4d5e6f70".into(),
            build: None,
        };
        let error = ServerMessage::error("version_mismatch", "expected 5");
        let frozen = [
            (json(&hello), r#"{"op":"hello","version":4}"#),
            (json(&ClientMessage::Replace), r#"{"op":"replace"}"#),
            (
                json(&welcome),
                r#"{"type":"welcome","version":4,"host_id":"0b7e3c4a-6f1d-4d0e-9a51-2f3c4d5e6f70"}"#,
            ),
            (json(&ServerMessage::Ok), r#"{"type":"ok"}"#),
            (
                json(&error),
                r#"{"type":"error","code":"version_mismatch","message":"expected 5"}"#,
            ),
            // Without a request ID the envelopes add nothing.
            (
                json(&Request::from(hello.clone())),
                r#"{"op":"hello","version":4}"#,
            ),
            (json(&Response::from(ServerMessage::Ok)), r#"{"type":"ok"}"#),
            (
                json(&Response::new(Some(9), ServerMessage::Ok)),
                r#"{"type":"ok","req":9}"#,
            ),
        ];
        for (actual, expected) in frozen {
            assert_eq!(actual, expected);
        }
        assert_eq!(
            encode_frame(&hello).unwrap(),
            b"\0\0\0\x1a{\"op\":\"hello\",\"version\":4}"
        );
        assert_eq!(error_code::VERSION_MISMATCH, "version_mismatch");
        // What any other version sends decodes, whatever it adds.
        for text in [
            r#"{"op":"hello","version":99}"#,
            r#"{"version":99,"op":"hello","req":3,"capabilities":["x"]}"#,
        ] {
            assert_eq!(
                serde_json::from_str::<ClientMessage>(text).unwrap(),
                ClientMessage::Hello { version: 99 }
            );
            assert!(matches!(
                serde_json::from_str::<Request>(text).unwrap().message,
                ClientMessage::Hello { version: 99 }
            ));
        }
        assert_eq!(
            serde_json::from_str::<Request>(r#"{"op":"replace","req":1,"exe":"/x"}"#).unwrap(),
            Request::new(Some(1), ClientMessage::Replace)
        );
        for text in [
            r#"{"type":"welcome","version":2,"host_id":"h"}"#,
            r#"{"type":"welcome","version":2,"host_id":"h","req":5,"features":{}}"#,
        ] {
            assert!(matches!(
                serde_json::from_str::<Response>(text).unwrap().message,
                ServerMessage::Welcome { version: 2, host_id, .. } if host_id == "h"
            ));
        }
        assert_eq!(
            serde_json::from_str::<Response>(
                r#"{"type":"error","code":"c","message":"m","hint":1}"#
            )
            .unwrap(),
            Response::from(ServerMessage::error("c", "m"))
        );
    }

    #[test]
    fn welcome_and_sessions_carry_builds_that_older_peers_ignore() {
        let welcome = ServerMessage::Welcome {
            version: 7,
            host_id: "h".into(),
            build: Some("20260927101500.abc1234".into()),
        };
        let text = json(&welcome);
        assert_eq!(
            text,
            r#"{"type":"welcome","version":7,"host_id":"h","build":"20260927101500.abc1234"}"#
        );
        assert_eq!(
            serde_json::from_str::<ServerMessage>(&text).unwrap(),
            welcome
        );
        // An older host's Welcome has none.
        assert!(matches!(
            serde_json::from_str::<ServerMessage>(
                r#"{"type":"welcome","version":7,"host_id":"h"}"#
            )
            .unwrap(),
            ServerMessage::Welcome { build: None, .. }
        ));
        let old = r#"{"id":"s","name":"n","cwd":"/","command":[],"cols":80,"rows":24,"state":"running","pid":1,"exit_code":null,"attached":false,"exit_signal":null}"#;
        let mut session: SessionInfo = serde_json::from_str(old).unwrap();
        assert_eq!(session.holder_build, None);
        assert!(!json(&session).contains("holder_build"));
        session.holder_build = Some("20260101000000.old1234".into());
        assert!(json(&session).contains(r#""holder_build":"20260101000000.old1234""#));
    }

    #[test]
    fn status_is_asked_and_answered() {
        assert_eq!(json(&ClientMessage::Status), r#"{"op":"status"}"#);
        let status = HostStatus {
            host_id: "h".into(),
            version: PROTOCOL_VERSION,
            build: BUILD.into(),
            pid: 42,
            started_at: 1,
            uptime_ms: 2,
            socket: "/tmp/x/host.sock".into(),
            state_dir: "/state".into(),
            log_path: Some("/state/host.log".into()),
            executable: None,
            executable_changed: false,
            sessions: 3,
            running_sessions: 2,
            max_sessions: 128,
            connections: 4,
            max_connections: 1024,
            holders_registered: 3,
            holders_expected: 0,
            lost_sessions: 0,
            fd_limit: Some(16384),
        };
        let reply = ServerMessage::Status {
            status: status.clone(),
        };
        let text = json(&Response::new(Some(3), reply.clone()));
        assert!(
            text.starts_with(r#"{"type":"status","status":{"host_id":"h""#),
            "{text}"
        );
        assert_eq!(
            serde_json::from_str::<Response>(&text).unwrap(),
            Response::new(Some(3), reply)
        );
    }

    #[test]
    fn builds_order_by_their_time_and_only_then() {
        assert_eq!(build_stamp("20260927101500.abc1234"), Some(20260927101500));
        assert_eq!(build_stamp("20260927101500"), Some(20260927101500));
        for unordered in [
            "0.1.0",
            "",
            "2026092710150.abc",
            "2026092710150x.abc",
            "local",
        ] {
            assert_eq!(build_stamp(unordered), None, "{unordered}");
        }
        let old = "20260101000000.aaaaaaa";
        let new = "20260927101500.bbbbbbb";
        assert!(build_is_newer(new, old));
        assert!(!build_is_newer(old, new));
        // The same time, or a build without one, is never newer.
        assert!(!build_is_newer("20260101000000.bbbbbbb", old));
        assert!(!build_is_newer(new, "0.1.0"));
        assert!(!build_is_newer("0.1.0", old));
        assert_eq!(
            build_in_version("cherry-host 0.1.0 (build 20260927101500.abc1234)\n"),
            Some("20260927101500.abc1234")
        );
        assert_eq!(build_in_version("cherry-host 0.1.0"), None);
        assert_eq!(build_in_version(&format!("cherry {VERSION}")), Some(BUILD));
        assert!(!BUILD.is_empty());
        // A development build (no CHERRY_BUILD_ID) never orders.
        let dev = "dev-20260927221521.96a826b";
        assert_eq!(build_stamp(dev), None);
        assert!(!build_is_newer(dev, old) && !build_is_newer(old, dev));
        if BUILD.starts_with("dev-") {
            assert_eq!(build_stamp(BUILD), None);
        }
    }

    #[test]
    fn request_ids_are_optional_and_echoed_as_plain_numbers() {
        assert_eq!(
            json(&Request::new(Some(7), ClientMessage::List)),
            r#"{"op":"list","req":7}"#
        );
        for (text, req) in [
            (r#"{"op":"list"}"#, None),
            (r#"{"req":7,"op":"list"}"#, Some(7)),
            (r#"{"op":"list","req":null}"#, None),
            (
                r#"{"op":"list","req":18446744073709551615}"#,
                Some(u64::MAX),
            ),
        ] {
            assert_eq!(
                serde_json::from_str::<Request>(text).unwrap(),
                Request::new(req, ClientMessage::List),
                "{text}"
            );
        }
        for text in [
            r#"{"op":"list","req":-1}"#,
            r#"{"op":"list","req":"7"}"#,
            r#"{"op":"list","req":1.5}"#,
            r#"{"req":7}"#,
            r#"{"op":"future_thing","req":7}"#,
        ] {
            assert!(serde_json::from_str::<Request>(text).is_err(), "{text}");
        }
        // A reader of bare messages ignores the ID.
        assert_eq!(
            serde_json::from_str::<ClientMessage>(r#"{"op":"ping","req":3}"#).unwrap(),
            ClientMessage::Ping
        );
        assert_eq!(
            serde_json::from_str::<ServerMessage>(r#"{"type":"pong","req":3}"#).unwrap(),
            ServerMessage::Pong
        );
    }

    fn session_info() -> SessionInfo {
        SessionInfo {
            id: "3f6c".into(),
            name: "Shell".into(),
            cwd: "/work".into(),
            command: vec!["/bin/zsh".into(), "-l".into()],
            cols: 120,
            rows: 32,
            state: SessionState::Running,
            pid: Some(4242),
            exit_code: None,
            attached: true,
            exit_signal: None,
            title: Some("vim — main.rs".into()),
            pwd: Some("file://studio/Users/me/My%20Code".into()),
            foreground: Some(ForegroundProcess {
                pid: 4300,
                name: "nvim".into(),
            }),
            clients: 2,
            owner: Some("com.example.cherry".into()),
            tags: BTreeMap::from([
                ("kind".into(), "agent".into()),
                ("tab".into(), "6d1f".into()),
            ]),
            created_at: 1_790_000_000_123,
            alternate_screen: true,
            kitty_keyboard_flags: 31,
            application_cursor_keys: true,
            bracketed_paste: Some(true),
            request_id: Some("d7c0f7d8-8f5e-4a51-9f47-5d0c1f1f2a3b".into()),
            ended_by: None,
            holder_log: None,
            holder_build: None,
        }
    }

    fn every_client_message() -> Vec<ClientMessage> {
        let bytes: Vec<u8> = (0..=255).collect();
        vec![
            ClientMessage::hello(),
            ClientMessage::Replace,
            ClientMessage::List,
            ClientMessage::Create {
                request_id: "d7c0f7d8-8f5e-4a51-9f47-5d0c1f1f2a3b".into(),
                name: "build".into(),
                cwd: "~/src".into(),
                command: vec!["make".into(), "-j8".into()],
                env: BTreeMap::from([("TERM".into(), "xterm-ghostty".into())]),
                cols: 500,
                rows: 200,
                owner: Some("com.example.cherry".into()),
                tags: BTreeMap::from([("tab".into(), "6d1f".into())]),
                colors: None,
            },
            ClientMessage::Create {
                request_id: "d7c0f7d8-8f5e-4a51-9f47-5d0c1f1f2a3c".into(),
                name: "light".into(),
                cwd: "/".into(),
                command: Vec::new(),
                env: BTreeMap::new(),
                cols: 80,
                rows: 24,
                owner: None,
                tags: BTreeMap::new(),
                colors: Some(TerminalColors {
                    foreground: Rgb([0x1f, 0x23, 0x28]),
                    background: Rgb([0xff, 0xff, 0xff]),
                    cursor: None,
                    dark: false,
                }),
            },
            ClientMessage::Attach {
                id: "s".into(),
                cols: 80,
                rows: 24,
                takeover: true,
                answers_queries: false,
                client_id: None,
            },
            ClientMessage::Attach {
                id: "s".into(),
                cols: 500,
                rows: 200,
                takeover: false,
                answers_queries: true,
                client_id: Some("6d1f0c2e-3b4a-4c5d-8e9f-0a1b2c3d4e5f".into()),
            },
            ClientMessage::Input {
                data: bytes.clone(),
            },
            ClientMessage::Resize {
                cols: u16::MAX,
                rows: 1,
            },
            ClientMessage::Refresh,
            ClientMessage::Detach,
            ClientMessage::Ping,
            ClientMessage::Kill { id: "s".into() },
            ClientMessage::Remove { id: "s".into() },
            ClientMessage::Shutdown,
            ClientMessage::Subscribe,
            ClientMessage::SendInput {
                id: "s".into(),
                data: bytes,
            },
            ClientMessage::SendInput {
                id: "s".into(),
                data: Vec::new(),
            },
            ClientMessage::Screen {
                id: "s".into(),
                scrollback: true,
                max_lines: None,
            },
            ClientMessage::Screen {
                id: "s".into(),
                scrollback: false,
                max_lines: Some(u32::MAX),
            },
            ClientMessage::Update {
                id: "s".into(),
                name: Some("renamed".into()),
                tags: Some(BTreeMap::new()),
            },
            ClientMessage::Update {
                id: "s".into(),
                name: None,
                tags: None,
            },
            ClientMessage::ClearHistory { id: "s".into() },
            ClientMessage::Restart,
        ]
    }

    fn every_server_message() -> Vec<ServerMessage> {
        let session = session_info();
        let exited = SessionInfo {
            state: SessionState::Exited,
            pid: None,
            exit_code: Some(130),
            exit_signal: Some(2),
            attached: false,
            clients: 0,
            title: None,
            pwd: None,
            foreground: None,
            owner: None,
            tags: BTreeMap::new(),
            alternate_screen: false,
            kitty_keyboard_flags: 0,
            application_cursor_keys: false,
            request_id: None,
            ..session_info()
        };
        let events = vec![
            SessionEvent::Added {
                session: session.clone(),
            },
            SessionEvent::Changed {
                session: exited.clone(),
            },
            SessionEvent::Removed { id: "s".into() },
            SessionEvent::Bell { id: "s".into() },
            SessionEvent::Notification {
                id: "s".into(),
                title: String::new(),
                body: "done \u{2713}\n\"quoted\"".into(),
            },
            SessionEvent::Progress {
                id: "s".into(),
                state: ProgressState::Set,
                value: Some(100),
            },
            SessionEvent::Progress {
                id: "s".into(),
                state: ProgressState::Indeterminate,
                value: None,
            },
            SessionEvent::Exited {
                id: "s".into(),
                exit_code: 137,
                signal: Some(9),
                ended_by: None,
                holder_log: None,
            },
            SessionEvent::Exited {
                id: "s".into(),
                exit_code: 1,
                signal: None,
                ended_by: Some(ended_by::HOLDER_LOST.into()),
                holder_log: Some("/state/host.log".into()),
            },
            SessionEvent::Resync,
        ];
        let mut messages = vec![
            ServerMessage::Welcome {
                version: PROTOCOL_VERSION,
                host_id: "h".into(),
                build: None,
            },
            ServerMessage::Sessions {
                host_id: "h".into(),
                sessions: vec![session.clone(), exited],
                pending_holders: 0,
                lost_sessions: Vec::new(),
            },
            ServerMessage::Sessions {
                host_id: "h".into(),
                sessions: Vec::new(),
                pending_holders: u32::MAX,
                lost_sessions: vec!["lost-a".into(), "lost-b".into()],
            },
            ServerMessage::Created {
                session: session.clone(),
            },
            ServerMessage::Attached {
                session,
                offset: u64::MAX,
                snapshot: (0..=255).rev().collect(),
                reason: AttachReason::Resync,
                refreshes: true,
            },
            ServerMessage::Resized {
                offset: u64::MAX,
                cols: 500,
                rows: 1,
            },
            ServerMessage::Output {
                offset: 3,
                data: vec![0x1b, b'[', b'H', 0],
            },
            ServerMessage::Query {
                data: b"\x1b[6n".to_vec(),
            },
            ServerMessage::Exit {
                id: "s".into(),
                exit_code: 0,
                signal: None,
            },
            ServerMessage::Pong,
            ServerMessage::Ok,
            ServerMessage::error(error_code::NOT_RUNNING, "session exited"),
            ServerMessage::ScreenText {
                id: "s".into(),
                text: "$ ls\nfile\n$ ".into(),
                cursor_row: 2,
                cursor_col: 2,
                alternate_screen: false,
            },
        ];
        messages.extend(
            events
                .into_iter()
                .map(|event| ServerMessage::Event { event }),
        );
        messages
    }

    #[test]
    fn every_message_round_trips_with_and_without_a_request_id() {
        for message in every_client_message() {
            let bare = encode_frame(&message).unwrap();
            // Without an ID the envelope is the bare message.
            assert_eq!(encode_frame(&Request::from(message.clone())).unwrap(), bare);
            // Binary frames (`Input`) carry none.
            let binary = !is_json(&bare[4..]);
            assert_eq!(binary, matches!(message, ClientMessage::Input { .. }));
            for req in [None, Some(0), Some(41), Some(u64::MAX)] {
                let request = Request::new(req, message.clone());
                let frame = encode_frame(&request).unwrap();
                let decoded: Request = read_frame(&mut frame.as_slice()).unwrap().unwrap();
                let expected = Request::new(req.filter(|_| !binary), message.clone());
                assert_eq!(decoded, expected);
                // A reader of bare messages understands it too.
                let bare: ClientMessage = read_frame(&mut frame.as_slice()).unwrap().unwrap();
                assert_eq!(bare, message);
            }
        }
        for message in every_server_message() {
            let bare = encode_frame(&message).unwrap();
            assert_eq!(
                encode_frame(&Response::from(message.clone())).unwrap(),
                bare
            );
            let binary = !is_json(&bare[4..]);
            assert_eq!(binary, message.is_binary(), "{message:?}");
            let decoded: Response = read_frame(&mut bare.as_slice()).unwrap().unwrap();
            assert_eq!(decoded, Response::from(message.clone()));
            for req in [Some(0), Some(u64::MAX)] {
                let response = Response::new(req, message.clone());
                let frame = encode_frame(&response).unwrap();
                let decoded: Response = read_frame(&mut frame.as_slice()).unwrap().unwrap();
                let expected = Response::new(req.filter(|_| !binary), message.clone());
                assert_eq!(decoded, expected);
                let bare: ServerMessage = read_frame(&mut frame.as_slice()).unwrap().unwrap();
                assert_eq!(bare, message);
            }
        }
    }

    #[test]
    fn large_binary_payloads_round_trip_through_the_envelopes() {
        let snapshot: Vec<u8> = (0..MAX_SNAPSHOT_BYTES).map(|i| (i * 7) as u8).collect();
        let response = Response::new(
            Some(1),
            ServerMessage::Attached {
                session: session_info(),
                offset: 12,
                snapshot,
                reason: AttachReason::Attach,
                refreshes: true,
            },
        );
        let frame = encode_frame(&response).unwrap();
        assert!(frame.len() <= MAX_FRAME_BYTES + 4);
        // A binary frame, which carries no request ID.
        let decoded = read_frame::<_, Response>(&mut frame.as_slice())
            .unwrap()
            .unwrap();
        assert!(decoded == Response::from(response.message));
        let request = Request::new(
            Some(2),
            ClientMessage::SendInput {
                id: "s".into(),
                data: vec![0xff; MAX_INPUT_BYTES],
            },
        );
        let frame = encode_frame(&request).unwrap();
        assert_eq!(
            read_frame::<_, Request>(&mut frame.as_slice())
                .unwrap()
                .unwrap(),
            request
        );
    }

    #[test]
    fn protocol_4_messages_have_these_shapes() {
        for (message, expected) in [
            (ClientMessage::Subscribe, r#"{"op":"subscribe"}"#),
            (
                ClientMessage::SendInput {
                    id: "s".into(),
                    data: b"ls\r".to_vec(),
                },
                r#"{"op":"send_input","id":"s","data":"bHMN"}"#,
            ),
            (
                ClientMessage::Screen {
                    id: "s".into(),
                    scrollback: false,
                    max_lines: None,
                },
                r#"{"op":"screen","id":"s","scrollback":false}"#,
            ),
            (
                ClientMessage::Screen {
                    id: "s".into(),
                    scrollback: true,
                    max_lines: Some(40),
                },
                r#"{"op":"screen","id":"s","scrollback":true,"max_lines":40}"#,
            ),
            (
                ClientMessage::Update {
                    id: "s".into(),
                    name: Some("n".into()),
                    tags: None,
                },
                r#"{"op":"update","id":"s","name":"n"}"#,
            ),
            (
                ClientMessage::Update {
                    id: "s".into(),
                    name: None,
                    tags: Some(BTreeMap::from([("k".into(), "v".into())])),
                },
                r#"{"op":"update","id":"s","tags":{"k":"v"}}"#,
            ),
        ] {
            assert_eq!(json(&message), expected);
        }
        for (message, expected) in [
            (
                ServerMessage::ScreenText {
                    id: "s".into(),
                    text: "$ ".into(),
                    cursor_row: 0,
                    cursor_col: 2,
                    alternate_screen: true,
                },
                r#"{"type":"screen_text","id":"s","text":"$ ","cursor_row":0,"cursor_col":2,"alternate_screen":true}"#,
            ),
            (
                ServerMessage::Event {
                    event: SessionEvent::Removed { id: "s".into() },
                },
                r#"{"type":"event","event":{"kind":"removed","id":"s"}}"#,
            ),
            (
                ServerMessage::Event {
                    event: SessionEvent::Bell { id: "s".into() },
                },
                r#"{"type":"event","event":{"kind":"bell","id":"s"}}"#,
            ),
            (
                ServerMessage::Event {
                    event: SessionEvent::Notification {
                        id: "s".into(),
                        title: "t".into(),
                        body: "b".into(),
                    },
                },
                r#"{"type":"event","event":{"kind":"notification","id":"s","title":"t","body":"b"}}"#,
            ),
            (
                ServerMessage::Event {
                    event: SessionEvent::Progress {
                        id: "s".into(),
                        state: ProgressState::Error,
                        value: Some(40),
                    },
                },
                r#"{"type":"event","event":{"kind":"progress","id":"s","state":"error","value":40}}"#,
            ),
            (
                ServerMessage::Event {
                    event: SessionEvent::Exited {
                        id: "s".into(),
                        exit_code: 130,
                        signal: Some(2),
                        ended_by: None,
                        holder_log: None,
                    },
                },
                r#"{"type":"event","event":{"kind":"exited","id":"s","exit_code":130,"signal":2}}"#,
            ),
            (
                ServerMessage::Event {
                    event: SessionEvent::Exited {
                        id: "s".into(),
                        exit_code: 1,
                        signal: None,
                        ended_by: Some(ended_by::HOLDER_LOST.into()),
                        holder_log: Some("/state/host.log".into()),
                    },
                },
                r#"{"type":"event","event":{"kind":"exited","id":"s","exit_code":1,"signal":null,"ended_by":"holder_lost","holder_log":"/state/host.log"}}"#,
            ),
            (
                ServerMessage::Event {
                    event: SessionEvent::Resync,
                },
                r#"{"type":"event","event":{"kind":"resync"}}"#,
            ),
        ] {
            assert_eq!(json(&message), expected);
        }
        let added = json(&ServerMessage::Event {
            event: SessionEvent::Added {
                session: session_info(),
            },
        });
        assert!(
            added.starts_with(r#"{"type":"event","event":{"kind":"added","session":{"id":"3f6c","#)
        );
        assert!(added.contains(
            r#""title":"vim — main.rs","pwd":"file://studio/Users/me/My%20Code","foreground":{"pid":4300,"name":"nvim"},"clients":2,"owner":"com.example.cherry","tags":{"kind":"agent","tab":"6d1f"},"created_at":1790000000123,"alternate_screen":true,"kitty_keyboard_flags":31,"application_cursor_keys":true,"bracketed_paste":true,"request_id":"d7c0f7d8-8f5e-4a51-9f47-5d0c1f1f2a3b""#
        ), "{added}");
        assert_eq!(
            json(&ServerMessage::Sessions {
                host_id: "h".into(),
                sessions: Vec::new(),
                pending_holders: 2,
                lost_sessions: Vec::new(),
            }),
            r#"{"type":"sessions","host_id":"h","sessions":[],"pending_holders":2}"#
        );
        // Lost sessions only when there are any.
        assert_eq!(
            json(&ServerMessage::Sessions {
                host_id: "h".into(),
                sessions: Vec::new(),
                pending_holders: 0,
                lost_sessions: vec!["s1".into()],
            }),
            r#"{"type":"sessions","host_id":"h","sessions":[],"pending_holders":0,"lost_sessions":["s1"]}"#
        );
        // Sent even when 0: its presence tells a host that knows it.
        assert_eq!(
            json(&ServerMessage::Sessions {
                host_id: "h".into(),
                sessions: Vec::new(),
                pending_holders: 0,
                lost_sessions: Vec::new(),
            }),
            r#"{"type":"sessions","host_id":"h","sessions":[],"pending_holders":0}"#
        );
        for (state, name) in [
            (ProgressState::Remove, "remove"),
            (ProgressState::Set, "set"),
            (ProgressState::Error, "error"),
            (ProgressState::Indeterminate, "indeterminate"),
            (ProgressState::Pause, "pause"),
        ] {
            assert_eq!(json(&state), format!("\"{name}\""));
        }
    }

    #[test]
    fn requests_that_cannot_be_decoded_are_answered_not_dropped() {
        let error = io::Error::new(io::ErrorKind::InvalidData, "bad");
        let answer = |body: &str| undecodable_request(body.as_bytes(), &error);
        match answer(r#"{"op":"teleport","req":7,"id":"s"}"#) {
            Some(Response {
                req: Some(7),
                message: ServerMessage::Error { code, .. },
            }) => assert_eq!(code, error_code::UNSUPPORTED_OPERATION),
            other => panic!("{other:?}"),
        }
        let colors = r##"{"op":"create","req":8,"request_id":"r","name":"n","cwd":"/","command":[],"cols":80,"rows":24,"colors":{"foreground":"#ｅ5e5e5","background":"#000000","dark":true}}"##;
        match answer(colors) {
            Some(Response {
                req: Some(8),
                message: ServerMessage::Error { code, .. },
            }) => assert_eq!(code, error_code::REQUEST_FAILED),
            other => panic!("{other:?}"),
        }
        // No req, or not a JSON request at all.
        assert!(matches!(
            answer(r#"{"op":"teleport"}"#),
            Some(Response { req: None, .. })
        ));
        assert!(answer("{not json").is_none());
        assert!(answer(r#"{"type":"ok"}"#).is_none());
        assert!(undecodable_request(&[2, 1, 2], &error).is_none());
    }

    #[test]
    fn protocol_7_messages_have_these_shapes() {
        assert_eq!(
            json(&ClientMessage::ClearHistory { id: "s".into() }),
            r#"{"op":"clear_history","id":"s"}"#
        );
        assert_eq!(json(&ClientMessage::Restart), r#"{"op":"restart"}"#);
        let create = |colors| ClientMessage::Create {
            request_id: "r".into(),
            name: "n".into(),
            cwd: "/".into(),
            command: Vec::new(),
            env: BTreeMap::new(),
            cols: 80,
            rows: 24,
            owner: None,
            tags: BTreeMap::new(),
            colors,
        };
        assert_eq!(
            json(&create(Some(TerminalColors {
                foreground: Rgb([0x1f, 0x23, 0x28]),
                background: Rgb([0xff, 0xfe, 0x0a]),
                cursor: Some(Rgb([0, 0x80, 0xff])),
                dark: false,
            }))),
            r##"{"op":"create","request_id":"r","name":"n","cwd":"/","command":[],"env":{},"cols":80,"rows":24,"owner":null,"tags":{},"colors":{"foreground":"#1f2328","background":"#fffe0a","cursor":"#0080ff","dark":false}}"##
        );
        // Left out without colours, so an older host sees what it knows.
        assert!(!json(&create(None)).contains("colors"));
        let colors: TerminalColors = serde_json::from_str(
            r##"{"foreground":"#E5E5E5","background":"#000000","dark":true}"##,
        )
        .unwrap();
        assert_eq!(
            colors,
            TerminalColors {
                foreground: Rgb([0xe5, 0xe5, 0xe5]),
                background: Rgb([0, 0, 0]),
                cursor: None,
                dark: true,
            }
        );
        for bad in [
            "\"e5e5e5\"",
            "\"#e5e5\"",
            "\"#gggggg\"",
            "\"#e5e5e5e5\"",
            "7",
        ] {
            assert!(serde_json::from_str::<Rgb>(bad).is_err(), "{bad}");
        }
        // Unknown until the holder reports it: left out, and read as None.
        let unknown = SessionInfo {
            bracketed_paste: None,
            ..session_info()
        };
        assert!(!json(&unknown).contains("bracketed_paste"));
        let off = SessionInfo {
            bracketed_paste: Some(false),
            ..session_info()
        };
        assert!(json(&off).contains(r#""bracketed_paste":false"#));
        // Why it ended: left out unless a holder was lost.
        let normal = json(&session_info());
        assert!(!normal.contains("ended_by") && !normal.contains("holder_log"));
        let lost = SessionInfo {
            state: SessionState::Exited,
            exit_code: Some(1),
            ended_by: Some(ended_by::HOLDER_LOST.into()),
            holder_log: Some("/state/host.log".into()),
            ..session_info()
        };
        assert!(json(&lost).contains(r#""ended_by":"holder_lost","holder_log":"/state/host.log""#));
        assert_eq!(
            serde_json::from_str::<SessionInfo>(&json(&lost)).unwrap(),
            lost
        );
    }

    #[test]
    fn create_metadata_and_new_session_fields_are_optional() {
        let create = serde_json::from_str::<ClientMessage>(
            r#"{"op":"create","request_id":"r","name":"n","cwd":"/","command":[],"cols":80,"rows":24}"#,
        )
        .unwrap();
        assert!(matches!(
            create,
            ClientMessage::Create { owner: None, ref tags, ref env, colors: None, .. } if tags.is_empty() && env.is_empty()
        ));
        let info = serde_json::from_str::<SessionInfo>(
            r#"{"id":"s","name":"n","cwd":"/","command":[],"cols":80,"rows":24,"state":"exited","pid":null,"exit_code":0,"attached":false,"exit_signal":null}"#,
        )
        .unwrap();
        assert_eq!(
            (info.title, info.pwd, info.foreground, info.clients),
            (None, None, None, 0)
        );
        assert_eq!(
            (info.owner, info.tags, info.created_at),
            (None, BTreeMap::new(), 0)
        );
        assert_eq!(
            (
                info.alternate_screen,
                info.kitty_keyboard_flags,
                info.application_cursor_keys,
                info.bracketed_paste,
                info.request_id
            ),
            (false, 0, false, None, None)
        );
        // What a host of an earlier stage sends.
        assert_eq!(
            serde_json::from_str::<ServerMessage>(
                r#"{"type":"sessions","host_id":"h","sessions":[]}"#
            )
            .unwrap(),
            ServerMessage::Sessions {
                host_id: "h".into(),
                sessions: Vec::new(),
                pending_holders: 0,
                lost_sessions: Vec::new(),
            }
        );
        assert_eq!(
            serde_json::from_str::<ClientMessage>(r#"{"op":"screen","id":"s","scrollback":true}"#)
                .unwrap(),
            ClientMessage::Screen {
                id: "s".into(),
                scrollback: true,
                max_lines: None,
            }
        );
    }

    #[test]
    fn attachment_requests_are_told_apart_from_control_requests() {
        for message in every_client_message() {
            let attachment = matches!(
                message,
                ClientMessage::Attach { .. }
                    | ClientMessage::Input { .. }
                    | ClientMessage::Resize { .. }
                    | ClientMessage::Refresh
                    | ClientMessage::Detach
            );
            assert_eq!(message.belongs_to_attachment(), attachment, "{message:?}");
        }
    }

    #[test]
    fn tags_are_bounded() {
        let tags = |entries: &[(&str, String)]| -> BTreeMap<String, String> {
            entries
                .iter()
                .map(|(key, value)| (key.to_string(), value.clone()))
                .collect()
        };
        check_tags(&BTreeMap::new()).unwrap();
        check_tags(&tags(&[("tab", "x".repeat(MAX_TAG_BYTES - 3))])).unwrap();
        assert!(check_tags(&tags(&[("tab", "x".repeat(MAX_TAG_BYTES - 2))])).is_err());
        assert!(check_tags(&tags(&[("", String::new())])).is_err());
        let long_key = "k".repeat(MAX_TAG_KEY_BYTES + 1);
        assert!(check_tags(&tags(&[(long_key.as_str(), String::new())])).is_err());
        let many: BTreeMap<String, String> = (0..=MAX_TAGS)
            .map(|n| (n.to_string(), String::new()))
            .collect();
        assert!(check_tags(&many).is_err());
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
