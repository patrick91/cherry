//! The session's modes without a copy of its screen, for a window that shows
//! the session's stream as it is (direct mode, see `attach::Renderer`).
//!
//! In direct mode the attachment reads from its copy of the session only the
//! modes: the screen that shows and the mode that entered it, the reports the
//! window may still send (mouse, focus, colour scheme, kitty keyboard flags),
//! bracketed paste and origin mode (see `Renderer::detach_reset`). Those
//! change only through control sequences, so a small libghostty terminal (the
//! shadow) is fed the stream's escape and CSI sequences and nothing else: no
//! text, no strings (OSC, DCS, APC, PM, SOS), and none of the sequences that
//! act only on the pen, the character sets, the cursor's position, the
//! margins or the screen's cells (SGR, cursor moves, erases, scrolls: see
//! `acts_on_modes`), which full-screen programs send most. It then holds the
//! modes the copy would, from the same parser, while text runs are skipped
//! with `memchr` rather than laid out on a screen.
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
//! What the shadow cannot tell is where the cursor is: text and the cursor
//! moves it is not fed move it. Only a reset that leaves origin mode on needs
//! it, so a sequence that may set origin mode is noted (`origin`), and the
//! renderer keeps a full copy from then on.

use anyhow::Result;
use memchr::{memchr, memchr3};

/// The shadow's screen. Its size matters to no mode; small keeps what the
/// sequences it is fed do to the screen (a reset, a screen switch, DECALN)
/// cheap.
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
                // Everything up to ESC, CAN or SUB (or, in an OSC, BEL) is
                // the string's.
                State::Osc | State::DcsData => {
                    let found = if matches!(self.state, State::Osc) {
                        rest.iter()
                            .position(|&byte| matches!(byte, 0x07 | 0x18 | 0x1a | 0x1b))
                    } else {
                        memchr3(0x1b, 0x18, 0x1a, rest)
                    };
                    let Some(found) = found else { break };
                    at += found + 1;
                    if rest[found] == 0x1b {
                        self.escape();
                    } else {
                        self.state = State::Ground;
                    }
                }
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
        self.push_run(&[byte]);
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

/// Whether a whole escape or CSI sequence goes to the shadow: all but a
/// lone ST, RI, IND and NEL (which move the cursor and may scroll), the
/// designations of the G0-G3 character sets, and the CSI sequences that
/// act on the screen only (see `screen_final`).
fn acts_on_modes(sequence: &[u8]) -> bool {
    if let Some((&last, parameters)) = sequence.strip_prefix(b"\x1b[").and_then(<[u8]>::split_last)
    {
        // Parameters alone are digits and the separators `:` and `;`.
        return !(screen_final(last) && parameters.iter().all(|byte| matches!(byte, b'0'..=b';')));
    }
    !matches!(
        sequence,
        b"\x1b\\"
            | b"\x1bM"
            | b"\x1bD"
            | b"\x1bE"
            | [0x1b, b'(' | b')' | b'*' | b'+', b'0' | b'A' | b'B']
    )
}

/// The final of a CSI sequence that, with parameters alone (no private
/// marker or intermediate byte), acts only on the pen, the cursor's
/// position, the margins or the screen's cells in libghostty (its
/// `stream.zig` and `Terminal.zig`): SGR (m), the cursor moves (CUU A, CUD
/// B, CUF C, CUB D, CNL E, CPL F, CHA G, CUP H, HPA `, HPR a, VPA d, VPR e,
/// HVP f), the erases (ED J, EL K, ECH X), inserts and deletes (ICH @, IL
/// L, DL M, DCH P), scrolls (SU S, SD T) and the top and bottom margins
/// (DECSTBM r). None changes a mode, the screen that shows or a keyboard
/// setting, and what they change decides nothing about those for the
/// sequences the shadow is fed. With a marker or an intermediate some are
/// other sequences (`CSI ? 6 r` restores origin mode, `CSI > 4 ; 2 m` sets
/// modifyOtherKeys), and those still go to the shadow.
fn screen_final(byte: u8) -> bool {
    matches!(
        byte,
        b'@'..=b'H' | b'J'..=b'M' | b'P' | b'S' | b'T' | b'X' | b'`' | b'a' | b'd'..=b'f'
            | b'm' | b'r'
    )
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
    use std::io::Write;

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
            // Screen-only sequences among the modes, and the same finals
            // with a marker or an intermediate, which are other sequences.
            b"\x1b[?6h\x1b[s\x1b[?6l\x1b[5;5H\x1b[2J\x1b[u",
            b"\x1b[?6h\x1b[?6s\x1b[?6l\x1b[3;4r\x1b[K\x1b[?6r",
            b"\x1b[?6h\x1b7\x1b[?6l\x1bM\x1bD\x1bE\x1b(0\x1b8",
            b"\x1b[?6h\x1b[3;3H\x1b#8\x1b[2;2f",
            b"\x1b[?1049h\x1b[2J\x1b[H\x1b[>4;2m\x1b[1;5r\x1bM\x1b[?1049l\x1b[>4m",
            b"\x1b[?1h\x1b[?1s\x1b[2A\x1b[?1l\x1b[3B\x1b[?1r\x1b[?2J\x1b[?1K",
            b"\x1b[>1u\x1b[5S\x1b[2T\x1b[3L\x1b[2M\x1b[4@\x1b[P\x1b[X\x1b[=5;2u",
            b"\x1b((B\x1b(=\x1b[1$K\x1b[2 @\x1b[?1049;2004h\x1b[1:2H\x1b[;r",
            b"\x1b[20h\x1b[2;12l\x1b[H\x1b[20l\x1b[K\x1b[12h",
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
            // Screen-only sequences (see `screen_final`), and the same
            // finals with a marker or an intermediate.
            b"\x1b[K",
            b"\x1b[2K",
            b"\x1b[?2K",
            b"\x1b[J",
            b"\x1b[?2J",
            b"\x1b[3;4H",
            b"\x1b[5A",
            b"\x1b[2X",
            b"\x1b[3@",
            b"\x1b[2 @",
            b"\x1b[2L",
            b"\x1b[M",
            b"\x1b[P",
            b"\x1b[S",
            b"\x1b[2T",
            b"\x1b[r",
            b"\x1b[3G",
            b"\x1b[4d",
            b"\x1b[1$K",
            b"\x1bM",
            b"\x1bD",
            b"\x1bE",
            b"\x1b(0",
            b"\x1b(B",
            b"\x1b[?6h",
            b"\x1b[?6l",
            b"\x1b[?6s",
            b"\x1b[?6r",
            b"\x1b[s",
            b"\x1b[u",
            b"\x1b#8",
            b"\x1b[>4;2m",
            b"\x1b[>4m",
            b"\x1b[?1h",
            b"\x1b[?1l",
            b"\x1b[20h",
            b"\x1b[20l",
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
            b"\x1b[?1000h",
            b"\x1b[?1006h",
            b"\x1b[20h",
            b"\x1b[?1h",
            b"\x1b=",
            b"\x1b[>4;2m",
            b"\x1b[1 q",
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

    /// A frame of a full-screen program, as Neovim and ncurses programs
    /// draw them: text between cursor moves, erases, scrolls, inserts and
    /// deletes, margins, pens and character sets, and no mode.
    fn frame(n: usize) -> Vec<u8> {
        let mut frame = b"\x1b[H".to_vec();
        for row in 1..=24 {
            let colour = (n * 7 + row) % 256;
            write!(
                frame,
                "\x1b[{row};1H\x1b[K\x1b(B\x1b[m\x1b[38;5;{colour}m{n:>6} {row}\x1b[m"
            )
            .unwrap();
            write!(frame, "\x1b[{}X\x1b[{}G|", row % 7, row * 3 % 80 + 1).unwrap();
        }
        frame.extend_from_slice(
            concat!(
                "\x1b[3;20r\x1b[5S\x1b[2T\x1b[r\x1b[2L\x1b[3M\x1b[4@\x1b[2P",
                "\x1bM\x1bD\x1bE\x1b[J\x1b[1J\x1b[2J\x1b[3J\x1b[1K\x1b[2K",
                "\x1b[7`\x1b[2a\x1b[4d\x1b[e\x1b[2;2f",
                "\x1b[A\x1b[2B\x1b[3C\x1b[D\x1b[E\x1b[F",
                "\x1b(0lqqk\x1b(B\x1b)0\x0eq\x0f\x1b[1;4;38:2::1:2:3mx\x1b[m",
            )
            .as_bytes(),
        );
        frame
    }

    /// A session that full-screen programs run in: they enter and leave
    /// the alternate screens, and between their frames (see `frame`, left
    /// out without `frames`), each a synchronized update, set and reset the
    /// modes the attachment reads: cursor keys and the keypad, bracketed
    /// paste, focus and mouse reports, kitty keyboard flags,
    /// modifyOtherKeys, the cursor's style and origin mode.
    fn full_screen_session(frames: bool) -> Vec<u8> {
        let steps: [&[u8]; 12] = [
            // Neovim starts, changes modes as it goes, and quits.
            b"$ nvim\r\n\x1b[?1049h\x1b[22;0;0t\x1b[?1h\x1b=\x1b[H\x1b[2J\x1b[?2004h\x1b[?1004h\
              \x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[>1u\x1b[>4;2m\x1b[2 q",
            b"\x1b[?1l\x1b>",
            b"\x1b[?1h\x1b=\x1b[?1002l\x1b[?1003h",
            b"\x1b[>5u\x1b[=3;1u",
            b"\x1b[<u\x1b[?2004l\x1b[?1s\x1b[?1l",
            b"\x1b[?1r\x1b7\x1b[?6h\x1b[5;10r\x1b[2;3H\x1b8",
            b"\x1b[?1004l\x1b[?1006l\x1b[?1000l\x1b[?1003l\x1b[<u\x1b[>4m\x1b[?1l\x1b>\
              \x1b[0 q\x1b[?1049l\x1b[23;0;0t",
            // At the prompt, and a program that uses ANSI modes.
            b"\r\x1b[K$ less\x1b[K\r\n\x1b[?2004h\x1b[?2004l\x1b[4h\x1b[20h",
            // Programs on the other alternate screens.
            b"\x1b[4l\x1b[20l\x1b[?1047h\x1b[?1h\x1b=\x1b[>3u",
            b"\x1b[?1047l\x1b[?47h\x1b[?1000h\x1b[?1005h",
            b"\x1b[?1000l\x1b[?1005l\x1b[?47l\x1b[?1049h\x1b[?6h\x1b[?2004h",
            b"\x1b[?6l\x1b[?1049l\x1b[?2004l\x1b[?1l\x1b>",
        ];
        let mut session = Vec::new();
        for (n, step) in steps.into_iter().enumerate() {
            session.extend_from_slice(step);
            session.extend_from_slice(b"\x1b[?2026h\x1b[?25l");
            if frames {
                session.extend(frame(n));
            }
            session.extend_from_slice(b"\x1b[?25h\x1b[?2026l");
        }
        session
    }

    /// What the attachment reads (see `reading`), without writing to the
    /// terminal, which may be inside a sequence.
    fn modes_now(terminal: &cherry_vt::Terminal) -> (Vec<u8>, Vec<bool>) {
        let screens = [1049, 1047, 47, 6, 2026].map(|mode| terminal.mode(mode, false).unwrap());
        (terminal.modes().unwrap(), screens.to_vec())
    }

    #[test]
    fn screen_sequences_never_reach_the_shadow() {
        let mut tracker = Tracker::new().unwrap();
        for n in 0..3 {
            let frame = frame(n);
            tracker.feed(&frame[..frame.len() / 3]);
            tracker.feed(&frame[frame.len() / 3..]);
        }
        assert_eq!(tracker.forwarded, 0);
        assert_eq!(tracker.state, State::Ground);
        // The same finals with a private marker or an intermediate, and the
        // other escape sequences, may act on modes: they are fed whole.
        for sequence in [
            &b"\x1b[?2J"[..],
            b"\x1b[?1K",
            b"\x1b[>4;2m",
            b"\x1b[?6r",
            b"\x1b[?1S",
            b"\x1b[>T",
            b"\x1b[2 @",
            b"\x1b[1$K",
            b"\x1b[1;1;2;2;1$r",
            b"\x1b[?1;2H",
            b"\x1b[=5H",
            b"\x1b[4h",
            b"\x1b[20l",
            b"\x1b[s",
            b"\x1b[u",
            b"\x1b[!p",
            b"\x1b((B",
            b"\x1b(=",
            b"\x1b#8",
            b"\x1b7",
            b"\x1b8",
            b"\x1b=",
            b"\x1bc",
        ] {
            let mut tracker = Tracker::new().unwrap();
            tracker.feed(sequence);
            assert_eq!(tracker.forwarded, sequence.len() as u64, "{sequence:?}");
        }
    }

    /// The tracker, which skips the frames' sequences, against a copy of
    /// the session that is fed every byte: what the attachment reads from
    /// them is the same after every piece, the session fed whole or in
    /// random pieces.
    #[test]
    fn a_full_screen_program_keeps_its_modes() {
        let session = full_screen_session(true);
        let mut without_frames = Tracker::new().unwrap();
        without_frames.feed(&full_screen_session(false));
        let mut seed: u64 = 0x9e37_79b9_7f4a_7c15;
        let mut next = move || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };
        for longest in [usize::MAX, 1, 7, 64, 1020] {
            let mut tracker = Tracker::new().unwrap();
            let mut copy = cherry_vt::Terminal::new(80, 24, 0).unwrap();
            let mut fed = 0;
            while fed < session.len() {
                let cut = ((next() % longest as u64) as usize + 1).min(session.len() - fed);
                let piece = &session[fed..fed + cut];
                tracker.feed(piece);
                copy.feed(piece);
                fed += cut;
                assert_eq!(
                    modes_now(&tracker.shadow),
                    modes_now(&copy),
                    "pieces of {longest} at most, {fed} bytes in"
                );
            }
            assert_eq!(reading(&mut tracker.shadow), reading(&mut copy));
            // Only the modes reached the shadow, none of the frames.
            assert_eq!(tracker.forwarded, without_frames.forwarded);
        }
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
