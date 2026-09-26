//! The session's modes without a copy of its screen, for a window that shows
//! the session's stream as it is (direct mode, see `attach::Renderer`).
//!
//! In direct mode the attachment reads from its copy of the session only the
//! modes: the screen that shows and the mode that entered it, the reports the
//! window may still send (mouse, focus, colour scheme, kitty keyboard flags),
//! bracketed paste and origin mode (see `Renderer::detach_reset`). Those
//! change only through control sequences, so a small libghostty terminal (the
//! shadow) is fed the stream's escape and CSI sequences and nothing else: no
//! text, no SGR, no strings (OSC, DCS, APC, PM, SOS). It then holds the modes
//! the copy would, from the same parser, while text runs are skipped with
//! `memchr` rather than laid out on a screen.
//!
//! The scanner follows libghostty's parser (vt100.net's state machine) to
//! tell where each sequence ends: ESC starts a sequence anywhere, CAN and SUB
//! abort any, C0 controls inside an escape or CSI sequence execute without
//! ending it, raw C1 bytes act as controls inside escape, CSI and DCS
//! sequences and SOS, PM and APC strings (not in text, which is UTF-8, nor in
//! OSC and DCS data), an OSC ends at BEL or ST, and the other strings at ST.
//! A sequence is fed to the shadow whole, so its parser takes it as the
//! copy's does.
//!
//! What the shadow cannot tell is where the cursor is: text moves it. Only a
//! reset that leaves origin mode on needs it, so a sequence that may set
//! origin mode is noted (`origin`), and the renderer keeps a full copy from
//! then on.

use anyhow::Result;
use memchr::{memchr, memchr3};

/// The shadow's screen. Its size matters to no mode; small keeps what the
/// sequences do to the screen (erases, scrolls) cheap.
const SHADOW_COLS: u16 = 20;
const SHADOW_ROWS: u16 = 5;
/// Longest sequence kept, as the host limits them (see `passthrough`); a
/// longer one is skipped.
const MAX_SEQUENCE: usize = 64 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum State {
    Ground,
    /// After ESC.
    Escape,
    /// After ESC and intermediate bytes (0x20-0x2F).
    EscapeIntermediate,
    Csi,
    Osc,
    /// A DCS before its final byte.
    DcsHeader(Dcs),
    /// A DCS's data, passed through or ignored: to ST.
    DcsData,
    /// SOS, PM and APC strings: to ST.
    Apc,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Dcs {
    Entry,
    Param,
    Intermediate,
}

pub struct Tracker {
    shadow: cherry_vt::Terminal,
    state: State,
    /// The escape or CSI sequence being read, from its ESC.
    pending: Vec<u8>,
    /// It is longer than `MAX_SEQUENCE`: skipped.
    discarding: bool,
    /// Whole sequences for the shadow, fed at the end of `feed`.
    batch: Vec<u8>,
    /// A sequence that may set origin mode (DECSET or XTRESTORE of 6)
    /// passed.
    origin: bool,
    /// Bytes fed to the shadow.
    forwarded: u64,
}

impl Tracker {
    pub fn new() -> Result<Self> {
        Ok(Self {
            shadow: cherry_vt::Terminal::new(SHADOW_COLS, SHADOW_ROWS, 0)?,
            state: State::Ground,
            pending: Vec::with_capacity(64),
            discarding: false,
            batch: Vec::new(),
            origin: false,
            forwarded: 0,
        })
    }

    /// The terminal that holds the session's modes (not its screen).
    pub fn shadow(&self) -> &cherry_vt::Terminal {
        &self.shadow
    }

    pub fn shadow_mut(&mut self) -> &mut cherry_vt::Terminal {
        &mut self.shadow
    }

    /// Origin mode may have been set (see the module documentation).
    pub fn origin(&self) -> bool {
        self.origin
    }

    /// Follow `bytes`, which continue everything fed before.
    pub fn feed(&mut self, bytes: &[u8]) {
        let mut at = 0;
        while at < bytes.len() {
            let rest = &bytes[at..];
            match self.state {
                // Text and C0 controls: only ESC matters.
                State::Ground => match memchr(0x1b, rest) {
                    Some(found) => {
                        at += found + 1;
                        self.escape();
                    }
                    None => break,
                },
                // Everything up to BEL, ESC, CAN or SUB is the string's.
                State::Osc => match rest
                    .iter()
                    .position(|&byte| matches!(byte, 0x07 | 0x18 | 0x1a | 0x1b))
                {
                    Some(found) => {
                        at += found + 1;
                        if rest[found] == 0x1b {
                            self.escape();
                        } else {
                            self.state = State::Ground;
                        }
                    }
                    None => break,
                },
                State::DcsData => match memchr3(0x1b, 0x18, 0x1a, rest) {
                    Some(found) => {
                        at += found + 1;
                        if rest[found] == 0x1b {
                            self.escape();
                        } else {
                            self.state = State::Ground;
                        }
                    }
                    None => break,
                },
                // Parameters and intermediates, taken as a run.
                State::Csi => {
                    let run = rest
                        .iter()
                        .position(|&byte| !(0x20..=0x3f).contains(&byte))
                        .unwrap_or(rest.len());
                    self.push_run(&rest[..run]);
                    at += run;
                    if let Some(&byte) = rest.get(run) {
                        at += 1;
                        self.byte(byte);
                    }
                }
                _ => {
                    at += 1;
                    self.byte(rest[0]);
                }
            }
        }
        if !self.batch.is_empty() {
            // Its replies are the host's to answer.
            let _ = self.shadow.feed(&self.batch);
            self.forwarded += self.batch.len() as u64;
            self.batch.clear();
        }
    }

    /// A byte inside an escape, CSI or DCS sequence, or an SOS, PM or APC
    /// string.
    fn byte(&mut self, byte: u8) {
        // What leads anywhere (C1 bytes: not in OSC or DCS data, which do
        // not come here).
        match byte {
            0x1b => return self.escape(),
            0x18 | 0x1a | 0x80..=0x8f | 0x91..=0x97 | 0x99 | 0x9a | 0x9c => return self.ground(),
            0x98 | 0x9e | 0x9f => return self.enter(State::Apc),
            0x90 => return self.enter(State::DcsHeader(Dcs::Entry)),
            0x9d => return self.enter(State::Osc),
            0x9b => {
                self.escape();
                self.push(b'[');
                self.state = State::Csi;
                return;
            }
            _ => {}
        }
        match self.state {
            State::Escape => match byte {
                b'[' => {
                    self.push(byte);
                    self.state = State::Csi;
                }
                b']' => self.enter(State::Osc),
                b'P' => self.enter(State::DcsHeader(Dcs::Entry)),
                b'X' | b'^' | b'_' => self.enter(State::Apc),
                0x20..=0x2f => {
                    self.push(byte);
                    self.state = State::EscapeIntermediate;
                }
                0x30..=0x7e => {
                    self.push(byte);
                    self.dispatch();
                }
                // C0 controls execute, DEL and 0xA0-0xFF are ignored.
                _ => {}
            },
            State::EscapeIntermediate => match byte {
                0x20..=0x2f => self.push(byte),
                0x30..=0x7e => {
                    self.push(byte);
                    self.dispatch();
                }
                _ => {}
            },
            State::Csi => match byte {
                0x20..=0x3f => self.push(byte),
                0x40..=0x7e => {
                    self.push(byte);
                    self.dispatch();
                }
                _ => {}
            },
            State::DcsHeader(dcs) => {
                self.state = match (dcs, byte) {
                    (_, 0x40..=0x7e) => State::DcsData,
                    (_, 0x20..=0x2f) => State::DcsHeader(Dcs::Intermediate),
                    (Dcs::Intermediate, 0x30..=0x3f) => State::DcsData,
                    (_, 0x3a) => State::DcsData,
                    (Dcs::Entry, 0x30..=0x3f) => State::DcsHeader(Dcs::Param),
                    (Dcs::Param, 0x30..=0x39 | 0x3b) => State::DcsHeader(Dcs::Param),
                    (Dcs::Param, 0x3c..=0x3f) => State::DcsData,
                    _ => State::DcsHeader(dcs),
                }
            }
            // The string's own bytes.
            State::Apc => {}
            State::Ground | State::Osc | State::DcsData => unreachable!(),
        }
    }

    fn escape(&mut self) {
        self.pending.clear();
        self.pending.push(0x1b);
        self.discarding = false;
        self.state = State::Escape;
    }

    fn ground(&mut self) {
        self.pending.clear();
        self.discarding = false;
        self.state = State::Ground;
    }

    /// A string whose content no mode depends on.
    fn enter(&mut self, state: State) {
        self.ground();
        self.state = state;
    }

    fn push(&mut self, byte: u8) {
        if self.discarding {
            return;
        }
        if self.pending.len() >= MAX_SEQUENCE {
            self.discarding = true;
            self.pending.clear();
            self.pending.shrink_to(64);
            return;
        }
        self.pending.push(byte);
    }

    fn push_run(&mut self, bytes: &[u8]) {
        if self.discarding || bytes.is_empty() {
            return;
        }
        if self.pending.len() + bytes.len() > MAX_SEQUENCE {
            self.discarding = true;
            self.pending.clear();
            self.pending.shrink_to(64);
            return;
        }
        self.pending.extend_from_slice(bytes);
    }

    /// A whole escape or CSI sequence ends in `pending`.
    fn dispatch(&mut self) {
        if !self.discarding && acts_on_modes(&self.pending) {
            self.origin |= may_set_origin(&self.pending);
            self.batch.extend_from_slice(&self.pending);
        }
        self.ground();
    }
}

/// Whether a whole escape or CSI sequence goes to the shadow: all but SGR,
/// which sets the pen only, and a lone ST.
fn acts_on_modes(sequence: &[u8]) -> bool {
    if sequence == b"\x1b\\" {
        return false;
    }
    if let Some(body) = sequence.strip_prefix(b"\x1b[") {
        if let Some((b'm', parameters)) = body.split_last() {
            return !parameters
                .iter()
                .all(|&byte| byte.is_ascii_digit() || byte == b';' || byte == b':');
        }
    }
    true
}

/// A DECSET or XTRESTORE naming mode 6 (origin).
fn may_set_origin(sequence: &[u8]) -> bool {
    let Some(body) = sequence.strip_prefix(b"\x1b[?") else {
        return false;
    };
    let Some((b'h' | b'r', parameters)) = body.split_last() else {
        return false;
    };
    parameters.split(|&byte| byte == b';').any(|parameter| {
        let digits = parameter
            .iter()
            .position(|&byte| byte != b'0')
            .map_or(&[][..], |start| &parameter[start..]);
        digits == b"6"
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What the attachment reads from a copy: the modes (`modes()`, which
    /// carries the screen switch, kitty flags and modifyOtherKeys), which
    /// alternate screen mode shows, and origin mode.
    fn reading(terminal: &mut cherry_vt::Terminal) -> (Vec<u8>, Vec<u8>) {
        let modes = terminal.modes().unwrap();
        let replies = terminal.feed(b"\x18\x1b[?1049$p\x1b[?1047$p\x1b[?47$p\x1b[?6$p\x1b[?2026$p");
        (modes, replies)
    }

    /// Feed `chunks` to a tracker and to a copy of the session, and compare
    /// what the attachment reads from them.
    fn agrees(chunks: &[&[u8]]) {
        let mut tracker = Tracker::new().unwrap();
        let mut copy = cherry_vt::Terminal::new(80, 24, 0).unwrap();
        for chunk in chunks {
            tracker.feed(chunk);
            copy.feed(chunk);
        }
        assert_eq!(
            reading(&mut tracker.shadow),
            reading(&mut copy),
            "{chunks:?}"
        );
    }

    #[test]
    fn modes_follow_the_copy() {
        for stream in [
            &b"text\x1b[?1049h\x1b[1;31mred\x1b[0m\x1b[?2004h\x1b[?1000;1006h"[..],
            b"\x1b[?1047h\x1b[?1004h\x1b[>1u\x1b[>3u\x1b[<u\x1b[>4;2m",
            b"\x1b[?47h\x1b[?1049l\x1b[?2026h\x1b=\x1b[?1h",
            b"\x1b[?1049h\x1b[?2004h\x1bc",
            b"\x1b[?2004h\x1b[?2004s\x1b[?2004l\x1b[?2004r",
            b"\x1b[?1000h\x1b[?1000s\x1b[?1049h\x1b[?1000l\x1b[?1049l\x1b[?1000r",
            b"\x1b[=5;1u\x1b[?1049h\x1b[=1;1u\x1b[?1049l",
            b"\x1b[4h\x1b[20h\x1b[?7l\x1b[?25l\x1b[5 q\x1b[?12h",
            b"\x1b[?6h\x1b[3;20r\x1b7\x1b[?6l\x1b8",
            b"\x1b[?1049h\x1b[?6h\x1b[?1049l",
            // Titles, hyperlinks, clipboard writes, images and DCS carry
            // bytes that would be sequences in text.
            b"\x1b]2;\x1b[?1049h\x07\x1b]8;;x\x1b\\\x1b[?1004h",
            b"\x1b]2;T\x1b[?2004h\x1b[?1000h",
            b"\x1bP1$r\x1b[?1049h\x1b\\\x1b[?2004h",
            b"\x1b_Gf=100;\x1b[?1049h\x1b\\\x1bPtmux;\x1b\x1b[?1004h\x1b\\",
            b"\x1b^pm\x9b?1049h\x1b[?2004h",
            // Aborts, restarts and C0 controls inside sequences.
            b"\x1b[?1049\x18h\x1b[?10\x1b[?2004h\x1b[?100\n4h",
            b"\x1b[?1049\x1a\x1b[?1\x07000h",
            // Raw C1 bytes: controls inside sequences, text outside.
            b"\x9b?1049h\x1b[\x9b?2004h\x1b[?1\x85004h\x1b(\x9b?1000h",
            b"\x1b]0;\x9b?1049h\x07\x1bP\x9b?1049h\x1b\\\x1b\x9d2;x\x07",
            b"\x1b\x7fc\x1b[?\xa01049h",
            b"\x1bP\x90\x9b?2004h\x1bX\x9c\x1b[?1004h",
            b"\x1b[\x98x\x9b?1049h\x1b[\x9ey\x9b?2004h\x1b[\x9fz\x9b?1004h",
            b"\x1b(\x9b?1049h\x1b(\x5b?2004h\x1b[?\x90q\x9b?1004h",
            b"\x1bP1\x9b?1049h\x1bP1;2$\x9b?2004h\x1bP$1\x9b?1004h",
            b"\x1b[?1049\x9ch\x1b[?2004\x85h\x1b[?1000\x9ah",
            // Charsets, keypad, DECALN, soft and full resets.
            b"\x1b(0\x1b)0\x0e\x1b=\x1b#8\x1b[!p\x1b[?1l",
            b"\x1b[?1049h\x1b[?1004h\x1b[>1u\x1bc\x1b[?2004h",
        ] {
            agrees(&[stream]);
            // Split anywhere.
            for split in 0..=stream.len() {
                agrees(&[&stream[..split], &stream[split..]]);
            }
        }
    }

    #[test]
    fn random_streams_follow_the_copy() {
        // A fixed pseudo-random mix of text, sequences, strings, aborts
        // and raw C1 bytes, cut into random chunks.
        let pieces: &[&[u8]] = &[
            b"hello world ",
            "日本語 🎉 ".as_bytes(),
            b"\r\n",
            b"\x1b[1;31m",
            b"\x1b[0m",
            b"\x1b[38:2:1:2:3m",
            b"\x1b[?1049h",
            b"\x1b[?1049l",
            b"\x1b[?1047h",
            b"\x1b[?47l",
            b"\x1b[?2004h",
            b"\x1b[?2004l",
            b"\x1b[?1000;1006h",
            b"\x1b[?1003l",
            b"\x1b[?1004h",
            b"\x1b[?2026h",
            b"\x1b[?2026l",
            b"\x1b[>1u",
            b"\x1b[<u",
            b"\x1b[=3;2u",
            b"\x1b[>4;1m",
            b"\x1b[?1s",
            b"\x1b[?1r",
            b"\x1b7",
            b"\x1b8",
            b"\x1bc",
            b"\x1b=",
            b"\x1b>",
            b"\x1b[5;10r",
            b"\x1b[H\x1b[2J",
            b"\x1b]2;title\x07",
            b"\x1b]8;;http://x\x1b\\",
            b"\x1bP+q544e\x1b\\",
            b"\x1b_Gi=1;AAAA\x1b\\",
            b"\x1b[",
            b"\x1b]",
            b"\x1bP",
            b"\x18",
            b"\x1a",
            b"\x1b",
            b"\x9b",
            b"\x9c",
            b"\x9d",
            b"\x90",
            b"\x98",
            b"\x9e",
            b"\x9f",
            b"\x1b(",
            b"\x1bP1;2",
            b"\x1bP$",
            b"\x1bX",
            b"\x85",
            b"\x07",
            b"?1049h",
            b"?2004h",
            b"1000h",
        ];
        let mut seed: u64 = 0x2545_f491_4f6c_dd1d;
        let mut next = move || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };
        for _ in 0..2000 {
            let mut stream = Vec::new();
            for _ in 0..(next() % 60) {
                stream.extend_from_slice(pieces[(next() % pieces.len() as u64) as usize]);
            }
            let mut chunks = Vec::new();
            let mut rest = &stream[..];
            while !rest.is_empty() {
                let cut = ((next() % 16) as usize + 1).min(rest.len());
                chunks.push(&rest[..cut]);
                rest = &rest[cut..];
            }
            agrees(&chunks);
        }
    }

    #[test]
    fn the_comparison_tells_modes_apart() {
        for mode in [
            &b"\x1b[?1049h"[..],
            b"\x1b[?47h",
            b"\x1b[?6h",
            b"\x1b[?2004h",
            b"\x1b[>1u",
            b"\x1b[?1004h",
        ] {
            let mut copy = cherry_vt::Terminal::new(80, 24, 0).unwrap();
            copy.feed(mode);
            let mut tracker = Tracker::new().unwrap();
            assert_ne!(reading(&mut tracker.shadow), reading(&mut copy), "{mode:?}");
        }
    }

    #[test]
    fn text_and_pens_never_reach_the_shadow() {
        let mut tracker = Tracker::new().unwrap();
        tracker.feed(b"plain \x1b[1;38;5;208mtext\x1b[0m\r\n");
        tracker.feed(b"\x1b]8;;http://x\x1b\\link\x1b]8;;\x1b\\");
        tracker.feed(b"\x1bP+q544e\x1b\\\x1b_Gf=100;AAAA\x1b\\");
        assert_eq!(tracker.forwarded, 0);
        assert_eq!(tracker.state, State::Ground);
        let modes = tracker.shadow.modes().unwrap();
        tracker.feed(b"\x1b[?1049h");
        assert_ne!(tracker.shadow.modes().unwrap(), modes);
    }

    #[test]
    fn origin_mode_is_noticed() {
        for (stream, origin) in [
            (&b"\x1b[?6h"[..], true),
            (b"\x1b[?1;06;7h", true),
            (b"\x1b[?6r", true),
            (b"\x1b[?6l", false),
            (b"\x1b[?16h", false),
            (b"\x1b[6h", false),
            (b"\x1b[?60h", false),
        ] {
            let mut tracker = Tracker::new().unwrap();
            tracker.feed(stream);
            assert_eq!(tracker.origin(), origin, "{stream:?}");
        }
    }

    #[test]
    fn oversized_sequences_are_skipped() {
        let mut tracker = Tracker::new().unwrap();
        let mut long = b"\x1b[?".to_vec();
        long.resize(MAX_SEQUENCE + 10, b'1');
        long.push(b'h');
        tracker.feed(&long);
        assert!(tracker.pending.capacity() <= MAX_SEQUENCE * 2);
        tracker.feed(b"\x1b[?2004h");
        assert!(tracker
            .shadow
            .modes()
            .unwrap()
            .windows(8)
            .any(|window| window == b"\x1b[?2004h"));
    }
}
