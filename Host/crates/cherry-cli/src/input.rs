//! Recognizes the local detach key in terminal input and forwards everything
//! else unchanged and in order.
use std::time::{Duration, Instant};

const DETACH_BYTE: u8 = 0x1d;
/// A lone Escape, or the start of an encoded key split across reads, is held
/// this long before it is forwarded.
pub const ESCAPE_WAIT: Duration = Duration::from_millis(25);
/// After the detach key, wait this long for a second press. Pressing it twice
/// in a row sends the key itself (Vim's Ctrl-], or a nested attach) instead.
pub const REPEAT_WAIT: Duration = Duration::from_millis(400);
const PASTE_START: &[u8] = b"\x1b[200~";
const PASTE_END: &[u8] = b"\x1b[201~";
const MAX_SEQUENCE: usize = 64;
/// Kitty keyboard protocol lock modifiers: Caps Lock and Num Lock.
const LOCK_MODIFIERS: u32 = 64 | 128;
const CTRL_MODIFIER: u32 = 4;
/// Kitty key codes for modifier keys themselves (shift through ISO level 5).
const MODIFIER_KEYS: std::ops::RangeInclusive<u32> = 57441..=57454;

#[derive(Clone, Copy, Debug, PartialEq, Eq, clap::ValueEnum)]
pub enum DetachKey {
    /// Ctrl-] detaches; press it twice to send Ctrl-] to the session.
    #[value(name = "ctrl-]")]
    CtrlBracket,
    /// Never detach from the keyboard; input is forwarded unchanged.
    None,
}

#[derive(Default, Debug, PartialEq, Eq)]
pub struct Parsed {
    /// Input to forward, in order, before any detach.
    pub data: Vec<u8>,
    pub detach: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Token {
    PasteStart,
    DetachPress,
    /// A key release or a modifier key on its own: ignored between the two
    /// presses of the detach key, forwarded otherwise.
    Neutral,
    Other,
}

enum Step {
    /// Part of a sequence that may still be the detach key or a paste start.
    Hold,
    /// The byte completes a control sequence.
    Complete,
    /// Not a candidate: forward what is held and handle the byte on its own.
    Release,
    /// Not a candidate: forward what is held together with the byte.
    ReleaseWith,
}

pub struct DetachInput {
    enabled: bool,
    escape_wait: Duration,
    /// An unfinished escape sequence, held until it is complete.
    pending: Vec<u8>,
    pending_since: Option<Instant>,
    /// Inside a bracketed paste: how much of the end marker has matched.
    paste_end: Option<usize>,
    /// The detach key was pressed once.
    armed_since: Option<Instant>,
}

impl DetachInput {
    pub fn new(key: DetachKey) -> Self {
        Self {
            enabled: key == DetachKey::CtrlBracket,
            escape_wait: crate::timing::timing().escape_wait,
            pending: Vec::new(),
            pending_since: None,
            paste_end: None,
            armed_since: None,
        }
    }

    /// Whether a detach key is recognized at all.
    pub fn detaches(&self) -> bool {
        self.enabled
    }

    pub fn feed(&mut self, bytes: &[u8], now: Instant) -> Parsed {
        let mut parsed = Parsed::default();
        if !self.enabled {
            parsed.data.extend_from_slice(bytes);
            return parsed;
        }
        for &byte in bytes {
            self.byte(byte, now, &mut parsed);
            if parsed.detach {
                // Anything after the decision belongs to the local terminal.
                break;
            }
        }
        parsed
    }

    /// Apply the escape and repeat timers.
    pub fn expire(&mut self, now: Instant) -> Parsed {
        let mut parsed = Parsed::default();
        if self
            .pending_since
            .is_some_and(|since| now >= since + self.escape_wait)
        {
            let sequence = self.take_pending();
            self.token(Token::Other, &sequence, now, &mut parsed);
        }
        if !parsed.detach
            && self
                .armed_since
                .is_some_and(|since| now >= since + REPEAT_WAIT)
        {
            self.armed_since = None;
            parsed.detach = true;
        }
        parsed
    }

    /// When `expire` next has something to do.
    pub fn next_deadline(&self) -> Option<Instant> {
        let escape = self.pending_since.map(|since| since + self.escape_wait);
        let repeat = self.armed_since.map(|since| since + REPEAT_WAIT);
        match (escape, repeat) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        }
    }

    /// End of input: what is still held, unless the detach key came first.
    pub fn finish(&mut self) -> Vec<u8> {
        let pending = self.take_pending();
        if self.armed_since.take().is_some() {
            Vec::new()
        } else {
            pending
        }
    }

    fn take_pending(&mut self) -> Vec<u8> {
        self.pending_since = None;
        std::mem::take(&mut self.pending)
    }

    fn byte(&mut self, byte: u8, now: Instant, parsed: &mut Parsed) {
        if let Some(matched) = self.paste_end {
            // Pasted text is never a key press.
            parsed.data.push(byte);
            self.paste_end = paste_end_step(matched, byte);
            return;
        }
        if !self.pending.is_empty() {
            match step(&self.pending, byte) {
                Step::Hold => {
                    self.pending.push(byte);
                    return;
                }
                Step::Complete => {
                    self.pending.push(byte);
                    let sequence = self.take_pending();
                    self.token(classify(&sequence), &sequence, now, parsed);
                    return;
                }
                Step::ReleaseWith => {
                    self.pending.push(byte);
                    let sequence = self.take_pending();
                    self.token(Token::Other, &sequence, now, parsed);
                    return;
                }
                Step::Release => {
                    let sequence = self.take_pending();
                    self.token(Token::Other, &sequence, now, parsed);
                    if parsed.detach {
                        return;
                    }
                }
            }
        }
        match byte {
            0x1b => {
                self.pending.push(byte);
                self.pending_since = Some(now);
            }
            DETACH_BYTE => self.token(Token::DetachPress, &[byte], now, parsed),
            _ => self.token(Token::Other, &[byte], now, parsed),
        }
    }

    fn token(&mut self, token: Token, bytes: &[u8], now: Instant, parsed: &mut Parsed) {
        if self.armed_since.is_some() {
            match token {
                Token::DetachPress => {
                    // Pressed twice: send the key exactly as the terminal encoded it.
                    parsed.data.extend_from_slice(bytes);
                    self.armed_since = None;
                }
                Token::Neutral => {}
                Token::PasteStart | Token::Other => {
                    self.armed_since = None;
                    parsed.detach = true;
                }
            }
            return;
        }
        match token {
            Token::DetachPress => self.armed_since = Some(now),
            Token::PasteStart => {
                parsed.data.extend_from_slice(bytes);
                self.paste_end = Some(0);
            }
            Token::Neutral | Token::Other => parsed.data.extend_from_slice(bytes),
        }
    }
}

fn paste_end_step(matched: usize, byte: u8) -> Option<usize> {
    let matched = if byte == PASTE_END[matched] {
        matched + 1
    } else if byte == 0x1b {
        1
    } else {
        0
    };
    (matched < PASTE_END.len()).then_some(matched)
}

/// Only `ESC [` followed by digits, `;` and `:` can become the detach key
/// (kitty `CSI 93;5u`, modifyOtherKeys `CSI 27;5;93~`) or a paste start.
fn step(pending: &[u8], byte: u8) -> Step {
    if pending.len() == 1 {
        return match byte {
            b'[' => Step::Hold,
            // Alt+Ctrl-] is another key, not the detach key.
            DETACH_BYTE => Step::ReleaseWith,
            _ => Step::Release,
        };
    }
    match byte {
        b'0'..=b'9' | b';' | b':' if pending.len() < MAX_SEQUENCE => Step::Hold,
        0x40..=0x7e => Step::Complete,
        0x20..=0x3f => Step::ReleaseWith,
        _ => Step::Release,
    }
}

fn classify(sequence: &[u8]) -> Token {
    if sequence == PASTE_START {
        return Token::PasteStart;
    }
    let Ok(parameters) = std::str::from_utf8(&sequence[2..sequence.len() - 1]) else {
        return Token::Other;
    };
    let fields: Vec<&str> = parameters.split(';').collect();
    match sequence[sequence.len() - 1] {
        b'u' => kitty_key(&fields),
        b'~' if fields.len() == 3 && fields[0] == "27" && fields[2] == "93" => {
            if number(fields[1]).is_some_and(ctrl_only) {
                Token::DetachPress
            } else {
                Token::Other
            }
        }
        _ => Token::Other,
    }
}

/// `CSI key[:alternates] ; modifiers[:event] [; text] u`
fn kitty_key(fields: &[&str]) -> Token {
    if fields.is_empty() || fields.len() > 3 {
        return Token::Other;
    }
    let key = fields[0].split(':').next().and_then(number);
    let mut modifiers = fields.get(1).copied().unwrap_or("").split(':');
    let mods = match modifiers.next() {
        None | Some("") => Some(1),
        Some(value) => number(value),
    };
    let event = match modifiers.next() {
        None | Some("") => Some(1),
        Some(value) => number(value),
    };
    let release = event == Some(3);
    match key {
        Some(93) if mods.is_some_and(ctrl_only) => match event {
            Some(1 | 2) => Token::DetachPress,
            Some(3) => Token::Neutral,
            _ => Token::Other,
        },
        Some(key) if MODIFIER_KEYS.contains(&key) => Token::Neutral,
        _ if release => Token::Neutral,
        _ => Token::Other,
    }
}

fn number(text: &str) -> Option<u32> {
    if text.is_empty() || !text.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    text.parse().ok()
}

/// Control alone, ignoring Caps Lock and Num Lock (encoded as 1 + bits).
fn ctrl_only(mods: u32) -> bool {
    mods >= 1 && (mods - 1) & !LOCK_MODIFIERS == CTRL_MODIFIER
}

/// Terminal input read once the attachment is over: while the host confirms
/// a detach, and until the terminal answered the query written after the
/// final reset. The terminal may still send reports it generated for the
/// session (mouse, focus, keys in the kitty encoding, replies to queries);
/// they are dropped, since the user's shell would print them. Keystrokes are
/// kept for the shell.
#[derive(Default)]
pub struct Leftover {
    kept: Vec<u8>,
    /// An unfinished escape sequence.
    pending: Vec<u8>,
    state: Report,
    /// X10 mouse coordinates are UTF-8 encoded (mode 1005).
    utf8_mouse: bool,
    /// The device attributes query was written; its answer ends the wait.
    awaiting: bool,
    answered: bool,
}

#[derive(Default, Clone, Copy, PartialEq, Eq)]
enum Report {
    #[default]
    Ground,
    Escape,
    Csi,
    /// `ESC O`: a key in application mode.
    Ss3,
    /// OSC, DCS, APC, PM or SOS: always a reply.
    String {
        escaped: bool,
    },
    /// An X10 mouse report: `ESC [ M` and three characters, each a byte,
    /// or UTF-8 encoded with mode 1005.
    Mouse {
        /// Characters not yet started.
        left: u8,
        /// UTF-8 continuation bytes the current character still has.
        continuation: u8,
    },
}

/// Final bytes of keys in the legacy encodings (cursor, editing and
/// function keys, back tab).
const KEY_FINALS: &[u8] = b"ABCDEFHPQRSZ~";
/// The answer to `DEVICE_ATTRIBUTES` starts with this and ends with `c`.
const ATTRIBUTES_ANSWER: &[u8] = b"\x1b[?";
/// Primary device attributes, which every terminal answers.
pub const DEVICE_ATTRIBUTES: &[u8] = b"\x1b[c";

impl Leftover {
    /// `utf8_mouse`: the terminal encodes X10 mouse coordinates in UTF-8
    /// (mode 1005); otherwise each is one byte, 0x80 and above included.
    pub fn new(utf8_mouse: bool) -> Self {
        Self {
            utf8_mouse,
            ..Self::default()
        }
    }

    pub fn feed(&mut self, bytes: &[u8]) {
        for &byte in bytes {
            self.byte(byte);
        }
    }

    /// `DEVICE_ATTRIBUTES` was written: its answer, which the terminal
    /// sends after every report it generated before, ends the wait.
    pub fn await_answer(&mut self) {
        self.awaiting = true;
    }

    pub fn answered(&self) -> bool {
        self.answered
    }

    /// The input ends inside an escape sequence, or with an Escape key that
    /// may be one's start: the rest is still on its way.
    pub fn unfinished(&self) -> bool {
        self.state != Report::Ground
    }

    /// The keystrokes, and an Escape key still held.
    pub fn finish(&mut self) -> Vec<u8> {
        if self.state == Report::Escape {
            self.kept.push(0x1b);
        }
        self.state = Report::Ground;
        self.pending.clear();
        std::mem::take(&mut self.kept)
    }

    fn byte(&mut self, byte: u8) {
        match self.state {
            Report::Ground => {
                if byte == 0x1b {
                    self.start();
                } else {
                    self.kept.push(byte);
                }
            }
            Report::Escape => match byte {
                b'[' => {
                    self.pending.push(byte);
                    self.state = Report::Csi;
                }
                b'O' => self.state = Report::Ss3,
                b']' | b'P' | b'_' | b'^' | b'X' => self.state = Report::String { escaped: false },
                // The first was the Escape key.
                0x1b => self.kept.push(0x1b),
                // Alt and a key.
                _ => {
                    self.kept.extend_from_slice(&[0x1b, byte]);
                    self.state = Report::Ground;
                }
            },
            Report::Csi => {
                if byte == b'M' && self.pending.len() == 2 {
                    self.state = Report::Mouse {
                        left: 3,
                        continuation: 0,
                    };
                } else if (0x40..=0x7e).contains(&byte) {
                    self.pending.push(byte);
                    self.complete();
                } else if (0x20..=0x3f).contains(&byte) {
                    // Keys are short: a longer sequence is dropped whole.
                    if self.pending.len() <= MAX_SEQUENCE {
                        self.pending.push(byte);
                    }
                } else {
                    // Not a sequence a terminal sends.
                    self.state = Report::Ground;
                    self.byte(byte);
                }
            }
            Report::Ss3 => {
                self.state = Report::Ground;
                if byte == 0x1b {
                    self.kept.extend_from_slice(b"\x1bO");
                    self.start();
                } else {
                    self.kept.extend_from_slice(&[0x1b, b'O', byte]);
                }
            }
            Report::String { escaped } => match byte {
                b'\\' if escaped => self.state = Report::Ground,
                _ if escaped => {
                    self.start();
                    self.byte(byte);
                }
                0x07 => self.state = Report::Ground,
                0x1b => self.state = Report::String { escaped: true },
                _ => {}
            },
            Report::Mouse { left, continuation } => self.mouse(byte, left, continuation),
        }
    }

    fn mouse(&mut self, byte: u8, mut left: u8, mut continuation: u8) {
        if continuation > 0 && byte & 0xc0 == 0x80 {
            continuation -= 1;
        } else if byte == 0x1b {
            // Never part of a report (coordinates start at 0x21, or are 0
            // beyond the last one): the report was cut short.
            self.start();
            return;
        } else if left == 0 {
            // The last character was cut short.
            self.state = Report::Ground;
            self.byte(byte);
            return;
        } else {
            left -= 1;
            continuation = if !self.utf8_mouse {
                0
            } else {
                match byte {
                    0xc2..=0xdf => 1,
                    0xe0..=0xef => 2,
                    0xf0..=0xf4 => 3,
                    _ => 0,
                }
            };
        }
        self.state = if left == 0 && continuation == 0 {
            Report::Ground
        } else {
            Report::Mouse { left, continuation }
        };
    }

    fn start(&mut self) {
        self.pending.clear();
        self.pending.push(0x1b);
        self.state = Report::Escape;
    }

    /// A complete CSI sequence: kept only when it is a key in a legacy
    /// encoding. Mouse and focus reports, kitty keys (`u`, or `:` event
    /// types) and answers (with a private prefix, or finals keys never
    /// use) are dropped.
    fn complete(&mut self) {
        self.state = Report::Ground;
        let sequence = std::mem::take(&mut self.pending);
        let (&last, body) = sequence[2..].split_last().expect("a final byte");
        if self.awaiting && last == b'c' && sequence.starts_with(ATTRIBUTES_ANSWER) {
            self.answered = true;
            return;
        }
        let private = matches!(body.first(), Some(b'<' | b'=' | b'>' | b'?'));
        if sequence.len() <= MAX_SEQUENCE
            && !private
            && !body.contains(&b':')
            && KEY_FINALS.contains(&last)
        {
            self.kept.extend_from_slice(&sequence);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn later(start: Instant, wait: Duration) -> Instant {
        start + wait + Duration::from_millis(1)
    }

    #[test]
    fn a_single_press_detaches_after_the_repeat_wait() {
        let now = Instant::now();
        let mut input = DetachInput::new(DetachKey::CtrlBracket);
        let parsed = input.feed(b"ls\x1d", now);
        assert_eq!(parsed.data, b"ls");
        assert!(!parsed.detach);
        assert_eq!(input.next_deadline(), Some(now + REPEAT_WAIT));
        assert_eq!(input.expire(now), Parsed::default());
        let expired = input.expire(later(now, REPEAT_WAIT));
        assert!(expired.detach);
        assert!(expired.data.is_empty());
    }

    #[test]
    fn pressing_twice_sends_the_key_as_the_terminal_encoded_it() {
        for key in [
            b"\x1d".as_slice(),
            b"\x1b[93;5u",
            b"\x1b[93;69u",
            b"\x1b[27;5;93~",
        ] {
            let now = Instant::now();
            let mut input = DetachInput::new(DetachKey::CtrlBracket);
            let mut bytes = key.to_vec();
            bytes.extend_from_slice(key);
            bytes.extend_from_slice(b"after");
            let parsed = input.feed(&bytes, now);
            assert_eq!(parsed.data, [key, b"after"].concat(), "{key:?}");
            assert!(!parsed.detach);
            assert_eq!(input.next_deadline(), None);
            assert!(!input.expire(later(now, REPEAT_WAIT)).detach);
        }
    }

    #[test]
    fn other_input_after_one_press_detaches_immediately_and_is_not_sent() {
        let now = Instant::now();
        let mut input = DetachInput::new(DetachKey::CtrlBracket);
        let parsed = input.feed(b"hello\x1dnot-sent", now);
        assert_eq!(parsed.data, b"hello");
        assert!(parsed.detach);
    }

    #[test]
    fn kitty_and_modify_other_keys_encodings_detach_with_lock_modifiers() {
        for key in [
            b"\x1b[93;5u".as_slice(),
            b"\x1b[93;5:1u",
            b"\x1b[93;5:2u",
            b"\x1b[93;69u",    // Caps Lock
            b"\x1b[93;133u",   // Num Lock
            b"\x1b[93;197:1u", // both
            b"\x1b[93:125;5u", // with an alternate key
            b"\x1b[27;5;93~",  // modifyOtherKeys
            b"\x1b[27;69;93~", // modifyOtherKeys with Caps Lock
        ] {
            let now = Instant::now();
            let mut input = DetachInput::new(DetachKey::CtrlBracket);
            let parsed = input.feed(key, now);
            assert!(parsed.data.is_empty(), "{key:?}");
            assert!(input.expire(later(now, REPEAT_WAIT)).detach, "{key:?}");
        }
    }

    #[test]
    fn other_keys_and_modifiers_are_forwarded_unchanged() {
        let now = Instant::now();
        let mut input = DetachInput::new(DetachKey::CtrlBracket);
        let bytes: &[u8] =
            b"hello\x1b[A\x1b[93;6u\x1b[93;5:3u\x1b[27;2;93~\x1b[93;3u\x1b[<0;3;4M\x1bOA\x1bxworld";
        let parsed = input.feed(bytes, now);
        assert_eq!(parsed.data, bytes);
        assert!(!parsed.detach);
        assert_eq!(input.next_deadline(), None);
    }

    #[test]
    fn key_releases_and_modifier_keys_between_presses_are_ignored() {
        let now = Instant::now();
        let mut input = DetachInput::new(DetachKey::CtrlBracket);
        // Press, release, Ctrl release, press again: one literal key press.
        let parsed = input.feed(b"\x1b[93;5u\x1b[93;5:3u\x1b[57442;5:3u\x1b[93;5u", now);
        assert_eq!(parsed.data, b"\x1b[93;5u");
        assert!(!parsed.detach);
    }

    #[test]
    fn encoded_keys_are_recognized_at_every_read_boundary() {
        for key in [b"\x1b[93;5u".as_slice(), b"\x1b[93;69:1u", b"\x1b[27;5;93~"] {
            for split in 0..=key.len() {
                let now = Instant::now();
                let mut input = DetachInput::new(DetachKey::CtrlBracket);
                assert_eq!(input.feed(b"before", now).data, b"before");
                let first = input.feed(&key[..split], now);
                assert!(first.data.is_empty() && !first.detach);
                let mut tail = key[split..].to_vec();
                tail.extend_from_slice(b"never-sent");
                let second = input.feed(&tail, now);
                assert!(second.detach, "key={key:?} split={split}");
                assert!(second.data.is_empty());
                assert!(input.finish().is_empty());
            }
        }
    }

    #[test]
    fn a_held_prefix_is_forwarded_after_the_escape_wait_or_at_the_end() {
        let now = Instant::now();
        let mut input = DetachInput::new(DetachKey::CtrlBracket);
        assert!(input.feed(b"\x1b[93;", now).data.is_empty());
        assert_eq!(input.next_deadline(), Some(now + ESCAPE_WAIT));
        let expired = input.expire(later(now, ESCAPE_WAIT));
        assert_eq!(expired.data, b"\x1b[93;");
        assert!(!expired.detach);
        assert!(input.feed(b"\x1b", now).data.is_empty());
        assert_eq!(input.finish(), b"\x1b");
        assert!(input.feed(b"x\x1d", now).data == b"x");
        assert!(input.finish().is_empty(), "the detach key came first");
    }

    #[test]
    fn bracketed_paste_never_detaches_even_across_reads() {
        let now = Instant::now();
        let mut input = DetachInput::new(DetachKey::CtrlBracket);
        let first = input.feed(b"\x1b[200~one\x1dtwo\x1b[93;5u\x1b[20", now);
        assert_eq!(first.data, b"\x1b[200~one\x1dtwo\x1b[93;5u\x1b[20");
        assert!(!first.detach);
        let second = input.feed(b"1~\x1d", now);
        assert_eq!(second.data, b"1~");
        assert!(!second.detach);
        assert!(input.expire(later(now, REPEAT_WAIT)).detach);
        // A paste start split across reads is recognized too.
        let mut input = DetachInput::new(DetachKey::CtrlBracket);
        assert!(input.feed(b"\x1b[20", now).data.is_empty());
        assert_eq!(
            input.feed(b"0~\x1d\x1b[201~", now).data,
            b"\x1b[200~\x1d\x1b[201~"
        );
    }

    #[test]
    fn disabled_detection_forwards_everything_without_delay() {
        let now = Instant::now();
        let mut input = DetachInput::new(DetachKey::None);
        let parsed = input.feed(b"\x1d\x1b\x1b[93;5u\x1b[93;", now);
        assert_eq!(parsed.data, b"\x1d\x1b\x1b[93;5u\x1b[93;");
        assert!(!parsed.detach);
        assert_eq!(input.next_deadline(), None);
        assert_eq!(input.finish(), b"");
    }

    /// Keystrokes in the encodings a shell reads.
    const KEYS: &[u8] =
        b"ls -l\r\x7f\x03\x1b[A\x1bOB\x1b[1;5C\x1b[15~\x1b[Z\x1bx\x1b[200~pasted\x1b[201~\xc3\xa9";

    /// Reports a terminal sends for a session's modes and queries, whatever
    /// the X10 mouse encoding.
    const REPORTS: &[&[u8]] = &[
        b"\x1b[<35;10;5M",
        b"\x1b[<0;1;1m",
        b"\x1b[32;1;1M",
        b"\x1b[M #!",
        b"\x1b[I",
        b"\x1b[O",
        b"\x1b[97u",
        b"\x1b[93;5:3u",
        b"\x1b[1;1:3A",
        b"\x1b[0n",
        b"\x1b[?997;1n",
        b"\x1b[?3;11R",
        b"\x1b[?1;2$y",
        b"\x1b[48;24;80;480;640t",
        b"\x1b[>1;4000;0c",
        b"\x1b]11;rgb:0000/0000/0000\x1b\\",
        b"\x1b]52;c;aGk=\x07",
        b"\x1bP1+r544e=787465726d\x1b\\",
        b"\x1b_Gi=1;OK\x1b\\",
    ];

    /// X10 mouse reports with one byte per coordinate: 0x80 and above for
    /// columns and rows 96 to 223 (some look like UTF-8), 0 past the last.
    const X10_BYTES: &[&[u8]] = &[b"\x1b[MC\x84%", b"\x1b[M#\xc5\x85", b"\x1b[M \xff\x00"];

    /// The same positions in UTF-8 (mode 1005).
    const X10_UTF8: &[&[u8]] = &[
        b"\x1b[MC\xc2\x84%",
        b"\x1b[M#\xc3\x85\xc2\x85",
        b"\x1b[M \xc3\xbf\x00",
        b"\x1b[M\xc3\xa0!\xc3\xa0",
    ];

    #[test]
    fn leftover_input_keeps_keystrokes_and_drops_reports() {
        for (utf8_mouse, mouse) in [(false, X10_BYTES), (true, X10_UTF8)] {
            let reports: Vec<&[u8]> = REPORTS.iter().chain(mouse).copied().collect();
            let mut stream = Vec::new();
            for (index, report) in reports.iter().enumerate() {
                stream.extend_from_slice(report);
                stream.push(b'a' + index as u8);
            }
            stream.extend_from_slice(KEYS);
            let expected: Vec<u8> = (0..reports.len() as u8)
                .map(|index| b'a' + index)
                .chain(KEYS.iter().copied())
                .collect();
            for split in 0..=stream.len() {
                let mut leftover = Leftover::new(utf8_mouse);
                leftover.feed(&stream[..split]);
                leftover.feed(&stream[split..]);
                assert!(!leftover.answered());
                assert!(!leftover.unfinished());
                assert_eq!(
                    String::from_utf8_lossy(&leftover.finish()),
                    String::from_utf8_lossy(&expected),
                    "utf8_mouse {utf8_mouse}, split at {split}"
                );
            }
        }
    }

    #[test]
    fn a_mouse_report_never_hides_the_answer_or_keys_after_it() {
        for utf8_mouse in [false, true] {
            let mut leftover = Leftover::new(utf8_mouse);
            leftover.await_answer();
            // A report cut short by the next escape sequence.
            leftover.feed(b"\x1b[MC");
            assert!(leftover.unfinished());
            leftover.feed(b"\x1b[?62;22c");
            assert!(leftover.answered(), "utf8_mouse {utf8_mouse}");
            assert!(!leftover.unfinished());
            assert!(leftover.finish().is_empty());
        }
        let mut leftover = Leftover::new(false);
        leftover.await_answer();
        leftover.feed(b"\x1b[MC\x84%l\x1b[MC\x85%\x1b[?62;22c");
        assert!(leftover.answered());
        assert_eq!(leftover.finish(), b"l");
    }

    #[test]
    fn leftover_input_waits_for_the_answer_to_its_own_query() {
        let mut leftover = Leftover::default();
        // An answer before the query was written is not the one awaited.
        leftover.feed(b"\x1b[?62;22c");
        assert!(!leftover.answered());
        leftover.await_answer();
        leftover.feed(b"\x1b[<35;1;1Mx\x1b[?62;22");
        assert!(!leftover.answered());
        leftover.feed(b"cy\x1b");
        assert!(leftover.answered());
        // Typed after the answer, and a held Escape key.
        assert_eq!(leftover.finish(), b"xy\x1b");
        // An unfinished report is dropped.
        leftover.feed(b"z\x1b[<35;1");
        assert_eq!(leftover.finish(), b"z");
        // Overlong sequences are not keys.
        let mut long = b"\x1b[".to_vec();
        long.resize(200, b'1');
        long.extend_from_slice(b"~k");
        leftover.feed(&long);
        assert_eq!(leftover.finish(), b"k");
    }

    #[test]
    fn alt_ctrl_bracket_is_not_the_detach_key() {
        let now = Instant::now();
        let mut input = DetachInput::new(DetachKey::CtrlBracket);
        let parsed = input.feed(b"\x1b\x1d", now);
        assert_eq!(parsed.data, b"\x1b\x1d");
        assert_eq!(input.next_deadline(), None);
    }
}
