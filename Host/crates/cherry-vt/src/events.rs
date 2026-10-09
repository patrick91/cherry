//! What programs tell their terminal besides what to draw: a title, a working
//! directory, the bell, desktop notifications and progress reports.
use std::collections::VecDeque;

/// Something a program did that a terminal reports rather than shows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VtEvent {
    /// The title changed (OSC 0 or 2); empty when the program cleared it
    /// or reset the terminal (RIS).
    Title(String),
    /// The working directory changed, exactly as the program reported it: a
    /// `file://host/path` URI (OSC 7, percent-encoded) or a plain path
    /// (OSC 9;9, OSC 1337 CurrentDir). Empty when the program cleared it
    /// or reset the terminal.
    Pwd(String),
    /// The bell (BEL).
    Bell,
    /// A desktop notification: OSC 9 or OSC 777 from the terminal, OSC 99
    /// through [`Osc99`]. `title` is empty when the program gave none.
    Notification { title: String, body: String },
    /// A progress report (OSC 9;4). `value` is a percentage (0–100), absent
    /// when the program gave none. A reset (RIS) reports `Remove`.
    Progress {
        state: ProgressState,
        value: Option<u8>,
    },
    /// The program status records changed (`Terminal::program_status`):
    /// an OSC 7501 report, a new shell prompt (OSC 133 A) or a reset.
    ProgramStatus,
}

/// What a program status report (OSC 7501) says. Strings the program did
/// not send are empty. `title` and `message` are decoded and hold no
/// control characters, but are the program's text: untrusted.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ProgramStatusReport {
    /// None for a clear: remove the record with this id and every record
    /// beneath it, or every record when the id is empty.
    pub state: Option<ProgramState>,
    /// What a blocked program needs, when it said.
    pub kind: Option<ProgramStatusKind>,
    /// 0–100, only for `Working` and `Blocked`.
    pub progress: Option<u8>,
    /// Empty for the root record; `/` separates a child from its parent.
    pub id: String,
    pub app: String,
    pub title: String,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProgramState {
    Idle,
    Working,
    Done,
    Blocked,
    Error,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProgramStatusKind {
    Permission,
    Question,
    Auth,
}

impl ProgramStatusReport {
    /// From `GhosttyProgramStatusState` and `GhosttyProgramStatusKind`;
    /// None for a state this version does not know.
    pub(crate) fn from_raw(state: i32, kind: i32, progress: i32) -> Option<Self> {
        let state = match state {
            0 => Some(ProgramState::Idle),
            1 => Some(ProgramState::Working),
            2 => Some(ProgramState::Done),
            3 => Some(ProgramState::Blocked),
            4 => Some(ProgramState::Error),
            5 => None,
            _ => return None,
        };
        let kind = match (state, kind) {
            (Some(ProgramState::Blocked), 1) => Some(ProgramStatusKind::Permission),
            (Some(ProgramState::Blocked), 2) => Some(ProgramStatusKind::Question),
            (Some(ProgramState::Blocked), 3) => Some(ProgramStatusKind::Auth),
            _ => None,
        };
        let progress = match state {
            Some(ProgramState::Working | ProgramState::Blocked) => {
                u8::try_from(progress).ok().filter(|value| *value <= 100)
            }
            _ => None,
        };
        Some(Self {
            state,
            kind,
            progress,
            id: String::new(),
            app: String::new(),
            title: String::new(),
            message: String::new(),
        })
    }
}

/// What a progress report asks for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProgressState {
    /// Stop showing progress.
    Remove,
    /// Determinate progress.
    Set,
    Error,
    Indeterminate,
    Pause,
}

impl ProgressState {
    /// From `GhosttyTerminalProgressState`; None for a state this version
    /// does not know.
    pub(crate) fn from_raw(state: i32) -> Option<Self> {
        Some(match state {
            0 => Self::Remove,
            1 => Self::Set,
            2 => Self::Error,
            3 => Self::Indeterminate,
            4 => Self::Pause,
            _ => return None,
        })
    }
}

/// At most this many events wait to be taken: beyond it, the oldest are
/// dropped, except that the latest title, working directory and progress
/// report are kept apart when no later one of their kind waits (see
/// `Terminal::take_events`). `Terminal::title()` and `Terminal::pwd()`
/// always give the current values.
pub const MAX_PENDING_EVENTS: usize = 256;
/// The text of the events waiting to be taken is at most this long in all
/// (besides the title and working directory kept apart).
pub const MAX_PENDING_EVENT_BYTES: usize = 256 * 1024;

/// Events not taken yet, in order. A title, working directory or progress
/// report replaces one that nothing followed, a bell right after a bell adds
/// nothing, and a title or working directory the program set to the value
/// it already had is not reported again.
#[derive(Debug, Default)]
pub(crate) struct Pending {
    events: VecDeque<VtEvent>,
    bytes: usize,
    /// State the bound dropped from `events` (a title, working directory or
    /// progress report that no later one of its kind replaces), oldest
    /// first, at most one of each kind: taken before `events`, so that no
    /// taker misses the current value, which is not reported again.
    dropped: Vec<VtEvent>,
    title: String,
    pwd: String,
}

impl Pending {
    pub(crate) fn push(&mut self, event: VtEvent) {
        match &event {
            VtEvent::Title(title) if *title == self.title => return,
            VtEvent::Title(title) => self.title.clone_from(title),
            VtEvent::Pwd(pwd) if *pwd == self.pwd => return,
            VtEvent::Pwd(pwd) => self.pwd.clone_from(pwd),
            _ => {}
        }
        let replaces = matches!(
            (self.events.back(), &event),
            (Some(VtEvent::Bell), VtEvent::Bell)
                | (Some(VtEvent::Title(_)), VtEvent::Title(_))
                | (Some(VtEvent::Pwd(_)), VtEvent::Pwd(_))
                | (Some(VtEvent::Progress { .. }), VtEvent::Progress { .. })
                | (Some(VtEvent::ProgramStatus), VtEvent::ProgramStatus)
        );
        if replaces {
            let last = self.events.pop_back().expect("a last event");
            self.bytes -= text_len(&last);
        }
        self.bytes += text_len(&event);
        self.events.push_back(event);
        while self.events.len() > MAX_PENDING_EVENTS || self.bytes > MAX_PENDING_EVENT_BYTES {
            let Some(oldest) = self.events.pop_front() else {
                break;
            };
            self.bytes -= text_len(&oldest);
            let kind = std::mem::discriminant(&oldest);
            let state = matches!(
                oldest,
                VtEvent::Title(_)
                    | VtEvent::Pwd(_)
                    | VtEvent::Progress { .. }
                    | VtEvent::ProgramStatus
            );
            if state
                && !self
                    .events
                    .iter()
                    .any(|event| std::mem::discriminant(event) == kind)
            {
                self.dropped
                    .retain(|event| std::mem::discriminant(event) != kind);
                self.dropped.push(oldest);
            }
        }
    }

    /// The last title (or, with `pwd`, working directory) reported, taken
    /// or not; empty before any.
    pub(crate) fn reported(&self, pwd: bool) -> &str {
        if pwd {
            &self.pwd
        } else {
            &self.title
        }
    }

    pub(crate) fn take(&mut self) -> Vec<VtEvent> {
        self.bytes = 0;
        let mut events = std::mem::take(&mut self.dropped);
        events.extend(self.events.drain(..));
        events
    }
}

fn text_len(event: &VtEvent) -> usize {
    match event {
        VtEvent::Title(text) | VtEvent::Pwd(text) => text.len(),
        VtEvent::Notification { title, body } => title.len() + body.len(),
        VtEvent::Bell | VtEvent::Progress { .. } | VtEvent::ProgramStatus => 0,
    }
}

/// Notifications assembled at once by an [`Osc99`]; beyond it the oldest
/// unfinished one is forgotten.
const MAX_UNFINISHED: usize = 16;
/// A notification's title and body together are cut to this length.
const MAX_NOTIFICATION_BYTES: usize = 64 * 1024;

/// Kitty desktop notifications (OSC 99), which libghostty-vt parses but
/// drops, so they never become a [`VtEvent`] from `Terminal::take_events`.
/// A reader of the output stream that sees whole control strings (the
/// host's display stream) hands each OSC 99 sequence to `feed`, which
/// assembles notifications sent in chunks and returns each once complete.
/// Keep one per session.
#[derive(Debug, Default)]
pub struct Osc99 {
    /// Notifications still receiving chunks, oldest first.
    unfinished: VecDeque<Unfinished>,
}

/// What the payload of an OSC 99 chunk is.
#[derive(Clone, Copy)]
enum Part {
    Title,
    Body,
    /// A part of the notification that is not reported (an icon, buttons).
    Unreported,
}

#[derive(Debug, Default)]
struct Unfinished {
    id: Vec<u8>,
    title: Vec<u8>,
    body: Vec<u8>,
}

impl Osc99 {
    /// Take one complete sequence, `ESC ] 99 ; metadata ; payload` ended by
    /// BEL or `ESC \`, and return the notification it completes. The
    /// metadata (`key=value` pairs separated by `:`) may give an identifier
    /// (`i`), say that chunks follow (`d=0`), that the payload is the body
    /// rather than the title (`p=body`) and that it is base64 (`e=1`).
    /// Chunks of one identifier (none is an identifier too) are joined until
    /// one without `d=0` completes the notification, whatever its payload
    /// type: icons, buttons and types this does not know are parts of the
    /// notification whose payload is not reported. Queries, close requests
    /// and liveness checks are not notifications: they give None, as do
    /// malformed sequences and notifications with neither title nor body.
    pub fn feed(&mut self, sequence: &[u8]) -> Option<VtEvent> {
        let body = sequence.strip_prefix(b"\x1b]99;")?;
        let body = body
            .strip_suffix(b"\x07")
            .or_else(|| body.strip_suffix(b"\x1b\\"))?;
        let split = body.iter().position(|&byte| byte == b';')?;
        let (metadata, payload) = (&body[..split], &body[split + 1..]);
        let (mut id, mut done, mut kind, mut base64) = (&b""[..], true, &b"title"[..], false);
        for item in metadata.split(|&byte| byte == b':') {
            let Some(equals) = item.iter().position(|&byte| byte == b'=') else {
                continue;
            };
            let (key, value) = (&item[..equals], &item[equals + 1..]);
            match key {
                b"i" if is_identifier(value) => id = value,
                b"d" if value == b"0" => done = false,
                b"d" => done = true,
                b"p" => kind = value,
                b"e" => base64 = value == b"1",
                _ => {}
            }
        }
        let part = match kind {
            // Requests about notifications, not parts of one.
            b"?" | b"close" | b"alive" => return None,
            b"title" => Part::Title,
            b"body" => Part::Body,
            // Icons, buttons and types this does not know (kitty asks
            // terminals to ignore payloads of unknown types): the chunk
            // still says whether the notification is done.
            _ => Part::Unreported,
        };
        let payload = match part {
            Part::Unreported => Vec::new(),
            _ if base64 => decode_base64(payload)?,
            _ => payload.to_vec(),
        };
        let mut notification = match self.unfinished.iter().position(|u| u.id == id) {
            Some(index) => self
                .unfinished
                .remove(index)
                .expect("an unfinished notification"),
            None => Unfinished {
                id: id.to_vec(),
                ..Unfinished::default()
            },
        };
        let room = MAX_NOTIFICATION_BYTES
            .saturating_sub(notification.title.len() + notification.body.len());
        let text = match part {
            Part::Body => &mut notification.body,
            Part::Title | Part::Unreported => &mut notification.title,
        };
        text.extend_from_slice(&payload[..payload.len().min(room)]);
        if !done {
            self.unfinished.push_back(notification);
            if self.unfinished.len() > MAX_UNFINISHED {
                self.unfinished.pop_front();
            }
            return None;
        }
        let title = String::from_utf8_lossy(&notification.title).into_owned();
        let body = String::from_utf8_lossy(&notification.body).into_owned();
        (!title.is_empty() || !body.is_empty()).then_some(VtEvent::Notification { title, body })
    }
}

/// The notification one OSC 99 sequence shows on its own (see
/// [`Osc99::feed`]); None when it is only a chunk or not a notification.
pub fn parse_osc99(sequence: &[u8]) -> Option<VtEvent> {
    Osc99::default().feed(sequence)
}

/// Kitty's notification identifiers: `[A-Za-z0-9_+.-]`, not empty.
fn is_identifier(value: &[u8]) -> bool {
    !value.is_empty()
        && value.len() <= 256
        && value
            .iter()
            .all(|&byte| byte.is_ascii_alphanumeric() || b"_+-.".contains(&byte))
}

/// Standard base64, padding optional.
fn decode_base64(text: &[u8]) -> Option<Vec<u8>> {
    let text = text
        .strip_suffix(b"==")
        .or_else(|| text.strip_suffix(b"="))
        .unwrap_or(text);
    if text.len() % 4 == 1 {
        return None;
    }
    let mut out = Vec::with_capacity(text.len() / 4 * 3 + 2);
    let (mut bits, mut count) = (0u32, 0);
    for &byte in text {
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        };
        bits = (bits << 6) | u32::from(value);
        count += 6;
        if count >= 8 {
            count -= 8;
            out.push((bits >> count) as u8);
        }
    }
    Some(out)
}
