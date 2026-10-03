//! Keeps kitty graphics commands that name a file, a temporary file or
//! shared memory (`t=` other than `d`) from the window's terminal
//! (`MediaGuard`), whichever holder sent them. The terminal runs on this
//! machine, and the session's output may come from another (an SSH host's
//! session): such a command would have it read, delete or unlink this
//! machine's files and shared memory, and answer whether they exist. The
//! holder never passes one on (see the host's `stream::route_graphics`),
//! but a holder older than that, or one that misbehaves, could; `cherry
//! attach` checks everything it writes to the terminal.
//!
//! The guard reads the bytes as Ghostty's parser of escape sequences does,
//! so it finds every command that terminal would carry out: begun by
//! `ESC _`, `ESC X` or `ESC ^` (Ghostty reads SOS and PM as APC) or their
//! 8-bit forms (0x9f, 0x98, 0x9e, which Ghostty heeds inside an escape
//! sequence, a control sequence or a device control string), behind bytes
//! it ignores there (DEL, 0xa0 and up), and ended by `ESC`, ST (0x9c), CAN,
//! SUB or another 8-bit control, at each of which Ghostty carries it out.
//! Of a command (`ESC _ G …`), the guard holds the control data back until
//! its first `;` (or its end): a command whose control data may name a
//! medium (`cherry_vt::kitty::may_name_medium`: as Ghostty reads it, or as
//! another terminal might) is dropped, and CAN takes its place, which ends
//! the string its introducer began without a command; any other goes on as
//! it is.

use std::borrow::Cow;

const ESC: u8 = 0x1b;
const CAN: u8 = 0x18;
const SUB: u8 = 0x1a;
/// The most control data held back without a `;`: a command with more is
/// dropped (Ghostty keeps no key or value longer than 11 bytes, and no
/// program writes this much before its payload).
const MAX_CONTROL: usize = 4096;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum State {
    #[default]
    Ground,
    Escape,
    EscapeIntermediate,
    Csi,
    Osc,
    Dcs,
    /// SOS, PM or APC (one state to Ghostty), not a kitty command.
    String,
    /// Just begun one of those: its first byte tells whether it is a kitty
    /// command.
    Identify,
    /// A kitty graphics command (`G` and what follows).
    Kitty,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum Decision {
    #[default]
    Undecided,
    Pass,
    Drop,
}

#[derive(Default)]
pub struct MediaGuard {
    state: State,
    decision: Decision,
    /// The command's bytes held back while undecided (from its `G`).
    held: Vec<u8>,
    /// Its control data so far, without the bytes Ghostty ignores.
    control: Vec<u8>,
}

impl MediaGuard {
    /// What of `bytes`, which follow everything filtered before, may be
    /// written to the terminal: all of them, but commands that may name a
    /// medium (and the bytes of one held back until it is decided).
    pub fn filter<'a>(&mut self, bytes: &'a [u8]) -> Cow<'a, [u8]> {
        if self.state == State::Ground && memchr::memchr(ESC, bytes).is_none() {
            // Text: an 8-bit control there is not one.
            return Cow::Borrowed(bytes);
        }
        let mut out = Vec::with_capacity(bytes.len() + 1);
        let mut at = 0;
        while at < bytes.len() {
            // Runs that change nothing go at once: text up to an ESC, and a
            // decided command's bytes up to what may end it.
            let rest = &bytes[at..];
            let run = match (self.state, self.decision) {
                (State::Ground, _) => memchr::memchr(ESC, rest).unwrap_or(rest.len()),
                (State::Kitty, Decision::Pass | Decision::Drop) => rest
                    .iter()
                    .position(|&b| matches!(b, ESC | CAN | SUB | 0x80..=0x9f))
                    .unwrap_or(rest.len()),
                _ => 0,
            };
            if self.state != State::Kitty || self.decision == Decision::Pass {
                out.extend_from_slice(&rest[..run]);
            }
            at += run;
            if let Some(&byte) = bytes.get(at) {
                self.step(byte, &mut out);
                at += 1;
            }
        }
        if out == bytes {
            Cow::Borrowed(bytes)
        } else {
            Cow::Owned(out)
        }
    }

    fn step(&mut self, byte: u8, out: &mut Vec<u8>) {
        if self.state == State::Kitty {
            self.command(byte, out);
            return;
        }
        out.push(byte);
        self.state = match (self.state, byte) {
            (State::Ground, ESC) => State::Escape,
            (State::Ground, _) => State::Ground,
            // Anywhere else: ESC begins a sequence, CAN and SUB end any.
            (_, ESC) => State::Escape,
            (_, CAN | SUB) => State::Ground,
            // OSC strings take everything else but BEL as data (8-bit
            // controls too: Ghostty reads them so).
            (State::Osc, 0x07) => State::Ground,
            (State::Osc, _) => State::Osc,
            // In SOS, PM and APC their own introducers are ignored.
            (State::String | State::Identify, 0x98 | 0x9e | 0x9f) => self.state,
            (_, 0x80..=0x9f) => eight_bit(byte),
            (State::Escape, b'[') => State::Csi,
            (State::Escape, b']') => State::Osc,
            (State::Escape, b'P') => State::Dcs,
            (State::Escape, b'X' | b'^' | b'_') => State::Identify,
            (State::Escape | State::EscapeIntermediate, 0x20..=0x2f) => State::EscapeIntermediate,
            (State::Escape | State::EscapeIntermediate, 0x30..=0x7e) => State::Ground,
            (State::Csi, 0x40..=0x7e) => State::Ground,
            (State::Identify, b'G') => {
                out.pop();
                self.held.push(byte);
                self.decision = Decision::Undecided;
                State::Kitty
            }
            // Ignored there: Ghostty identifies the string by the byte
            // after them.
            (State::Identify, 0xa0..=0xff) => State::Identify,
            (State::Identify, _) => State::String,
            // C0 controls, DEL and bytes Ghostty ignores, parameters and
            // data: the state holds.
            (state, _) => state,
        };
    }

    /// One byte of a kitty command, or the one that ends it.
    fn command(&mut self, byte: u8, out: &mut Vec<u8>) {
        // Ignored by Ghostty inside it: kept with it, and not part of its
        // control data.
        let ignored = matches!(byte, 0x98 | 0x9e | 0x9f | 0xa0..=0xff);
        match byte {
            0x98 | 0x9e | 0x9f => {}
            // It ends here (Ghostty carries it out), and what ends it
            // acts as it does anywhere.
            ESC | CAN | SUB | 0x80..=0x9f => {
                self.decide(out);
                let dropped = self.decision == Decision::Drop;
                self.held.clear();
                self.control.clear();
                self.state = State::String;
                self.decision = Decision::Undecided;
                // An 8-bit control after a dropped command would print as
                // text (CAN left the terminal in its ground state): it goes
                // with the command.
                if dropped && (0x80..=0x9f).contains(&byte) {
                    self.state = State::Ground;
                    return;
                }
                self.step(byte, out);
                return;
            }
            _ => {}
        }
        match self.decision {
            Decision::Pass => out.push(byte),
            Decision::Drop => {}
            Decision::Undecided => {
                self.held.push(byte);
                if byte == b';' {
                    self.decide(out);
                } else if !ignored {
                    self.control.push(byte);
                    if self.control.len() > MAX_CONTROL {
                        self.drop_command(out);
                    }
                }
            }
        }
    }

    /// Decide the command held back, by its control data so far.
    fn decide(&mut self, out: &mut Vec<u8>) {
        if self.decision != Decision::Undecided {
            return;
        }
        if cherry_vt::kitty::may_name_medium(&self.control) {
            self.drop_command(out);
        } else {
            self.decision = Decision::Pass;
            out.append(&mut self.held);
        }
    }

    fn drop_command(&mut self, out: &mut Vec<u8>) {
        self.decision = Decision::Drop;
        self.held.clear();
        // The terminal has the command's introducer: CAN ends the string
        // it began, before any of the command.
        out.push(CAN);
    }
}

/// The state an 8-bit control leads to outside the ground state and OSC
/// strings, as Ghostty's parser has it: each is its 7-bit form.
fn eight_bit(byte: u8) -> State {
    match byte {
        0x9b => State::Csi,
        0x9d => State::Osc,
        0x90 => State::Dcs,
        0x98 | 0x9e | 0x9f => State::Identify,
        // ST, and the controls carried out at once.
        _ => State::Ground,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What libghostty-vt, which reads no file (Cherry never enables a
    /// medium), answers `bytes`.
    fn ghostty(bytes: &[u8]) -> String {
        let mut terminal = cherry_vt::Terminal::new(20, 5, 0).unwrap();
        terminal
            .set_image_storage_limit(cherry_vt::IMAGE_STORAGE_BYTES)
            .unwrap();
        String::from_utf8_lossy(&terminal.feed(bytes)).into_owned()
    }

    fn filtered(bytes: &[u8]) -> Vec<u8> {
        MediaGuard::default().filter(bytes).into_owned()
    }

    /// A command for each way to name a medium, asked as a query so that
    /// a terminal that carries it out answers.
    const QUERIES: &[&[u8]] = &[
        b"\x1b_Ga=q,i=1,s=1,v=1,f=24,t=f;L2V0Yw==\x1b\\",
        b"\x1b_Ga=q,i=1,s=1,v=1,f=24,t=102;L2V0Yw==\x1b\\",
        b"\x1b_Ga=q,i=1,s=1,v=1,f=24,t=0102;L2V0Yw==\x1b\\",
        b"\x1b_Ga=q,i=1,s=1,v=1,f=24,t=+102;L2V0Yw==\x1b\\",
        b"\x1b_Ga=q,i=1,s=1,v=1,f=24,t=1_02;L2V0Yw==\x1b\\",
        b"\x1b_Ga=113,i=1,s=1,v=1,f=24,t=116;L2V0Yw==\x1b\\",
        b"\x1b_Ga=+113,i=1,s=1,v=1,f=24,t=115;L2V0Yw==\x1b\\",
        b"\x1b_Ga=q,i=1,s=1,v=1,f=24,t=\xc3f;L2V0Yw==\x1b\\",
        b"\x1b_Ga=q,i=1,s=1,v=1,f=24,t=f;L2V0Yw==\x9c",
        b"\x1b_Ga=q,i=1,s=1,v=1,f=24,t=f;L2V0Yw==\x18",
        b"\x1b_Ga=q,i=1,s=1,v=1,f=24,t=f;L2V0Yw==\x85",
        b"\x1b_Ga=q,i=1,s=1,v=1,f=24,t=f;L2V0Yw==\x1b[m",
        b"\x1b_Ga=q,i=1,s=1,v=1,f=24,t=f\x1b\\",
        b"\x1b[\x9fGa=q,i=1,s=1,v=1,f=24,t=f;L2V0Yw==\x9c",
        b"\x1b\x9fGa=q,i=1,s=1,v=1,f=24,t=f;L2V0Yw==\x9c",
        b"\x1bP1;2\x9fGa=q,i=1,s=1,v=1,f=24,t=f;L2V0Yw==\x9c",
        b"\x1b\xa0_Ga=q,i=1,s=1,v=1,f=24,t=f;L2V0Yw==\x1b\\",
        b"\x1b\x7f_Ga=q,i=1,s=1,v=1,f=24,t=f;L2V0Yw==\x1b\\",
        b"\x1b_\xa0Ga=q,i=1,s=1,v=1,f=24,t=f;L2V0Yw==\x1b\\",
        b"\x1bXGa=q,i=1,s=1,v=1,f=24,t=f;L2V0Yw==\x1b\\",
        b"\x1b^Ga=q,i=1,s=1,v=1,f=24,t=f;L2V0Yw==\x1b\\",
    ];

    #[test]
    fn ghostty_would_read_each_of_these() {
        for &query in QUERIES {
            assert!(
                ghostty(query).contains("unsupported medium"),
                "{:?}",
                String::from_utf8_lossy(query)
            );
        }
    }

    #[test]
    fn commands_that_name_a_medium_never_reach_the_terminal() {
        for &query in QUERIES {
            let text = String::from_utf8_lossy(query).into_owned();
            let stream = [&b"before"[..], query, b"after"].concat();
            for split in 0..=stream.len() {
                let mut guard = MediaGuard::default();
                let mut out = guard.filter(&stream[..split]).into_owned();
                out.extend_from_slice(&guard.filter(&stream[split..]));
                assert!(
                    !contains(&out, b"t="),
                    "{text:?} split at {split}: {:?}",
                    String::from_utf8_lossy(&out)
                );
                assert_eq!(ghostty(&out), "", "{text:?} split at {split}");
                assert!(contains(&out, b"before") && contains(&out, b"after"));
            }
        }
    }

    fn contains(haystack: &[u8], needle: &[u8]) -> bool {
        haystack
            .windows(needle.len())
            .any(|window| window == needle)
    }

    #[test]
    fn everything_else_goes_on_as_it_is() {
        for bytes in [
            &b"plain text \xc3\xa9 \x9f\x9c"[..],
            b"\x1b[1;31mred\x1b[m\x1b]2;title \xc4\x9fG t=f\x07",
            b"\x1b_Ga=T,f=24,s=1,v=1,i=7,q=2;AQID\x1b\\",
            b"\x1b_Ga=t,t=d,i=8,m=1;AAAA\x1b\\\x1b_Gm=0;AAAA\x1b\\",
            b"\x1b_Ga=p,U=1,i=7,t=100\x1b\\",
            b"\x1b_Ga=d,d=a\x1b\\",
            b"\x1b_Xother t=f\x1b\\",
            b"\x1bP+q544e\x1b\\",
        ] {
            let mut guard = MediaGuard::default();
            assert!(
                matches!(guard.filter(bytes), Cow::Borrowed(passed) if passed == bytes),
                "{:?}",
                String::from_utf8_lossy(bytes)
            );
        }
        // A command waits for its control data, then goes on whole.
        let mut guard = MediaGuard::default();
        assert_eq!(&*guard.filter(b"x\x1b_Ga=T,i="), b"x\x1b_");
        assert_eq!(&*guard.filter(b"5;AA"), b"Ga=T,i=5;AA");
        assert_eq!(&*guard.filter(b"AA\x1b\\y"), b"AA\x1b\\y");
    }

    #[test]
    fn a_dropped_command_leaves_the_terminal_where_ghostty_would() {
        // CAN ends the string its introducer began: the text after it
        // shows, and nothing else does.
        assert_eq!(
            filtered(b"a\x1b_Gt=f,i=1;eA==\x1b\\b"),
            b"a\x1b_\x18\x1b\\b"
        );
        assert_eq!(filtered(b"a\x1b[\x9fGt=f;eA==\x9cb"), b"a\x1b[\x9f\x18b");
        let mut terminal = cherry_vt::Terminal::new(10, 2, 0).unwrap();
        terminal.feed(&filtered(b"a\x1b[\x9fGt=f;eA==\x9cb"));
        assert_eq!(terminal.screen_text().unwrap().trim_end(), "ab");
        // A command too long to decide before its payload is dropped.
        let long = [
            &b"\x1b_Gi=1"[..],
            &b",x=1".repeat(MAX_CONTROL),
            b";AAAA\x1b\\",
        ]
        .concat();
        assert_eq!(filtered(&long), b"\x1b_\x18\x1b\\");
    }

    /// Random output made of the pieces that begin, fill and end kitty
    /// graphics commands in every way Ghostty reads them, through the guard
    /// in random pieces: libghostty-vt, reading what the guard let through,
    /// never tries a medium.
    #[test]
    fn ghostty_never_tries_a_medium_the_guard_let_through() {
        const BEFORE: &[&[u8]] = &[
            b"",
            b"text",
            b"\x1b[",
            b"\x1b[?",
            b"\x1b(",
            b"\x1b",
            b"\x1bP1;2",
            b"\x1bP",
            b"\x1b]0;x",
            b"\x1b_X",
            b"\x1b^",
            b"\x1b_Ga=p,U=1,i=1;AA",
            b"\x1b_G",
            b"\xc3",
            b"\x9c",
            b"\x1b]2;\xc4",
        ];
        const OPEN: &[&[u8]] = &[
            b"\x1b_",
            b"\x9f",
            b"\x1b\x9f",
            b"\x1b\xa0_",
            b"\x1b\x7f_",
            b"\x1b\x01_",
            b"\x1b_\xa0",
            b"\x1b\xff\x7f_",
            b"\x98",
            b"\x90",
            b"\x9d",
            b"\x9b",
            b"",
            b"\x1bX",
            b"\x1b^",
            b"\x9e",
        ];
        const KEYS: &[&[u8]] = &[
            b"a=q", b"a=113", b"a=T", b"a=84", b"i=1", b"s=1", b"v=1", b"f=24", b"t=f", b"t=102",
            b"t=0102", b"t=1_02", b"t=\xc3f", b"t=d", b"t=115", b"t=116", b"q=0", b"x=1", b"\xa0",
            b"T=f", b" t=f", b"m=1", b"t", b"=",
        ];
        const PAYLOAD: &[&[u8]] = &[
            b";AAAA",
            b";L2V0Yw==",
            b";AA\xc3AA",
            b"",
            b";",
            b";AA\x9cAA",
        ];
        const CLOSE: &[&[u8]] = &[
            b"\x1b\\",
            b"\x9c",
            b"\x18",
            b"\x1a",
            b"\x1bX",
            b"\x85",
            b"\x07",
            b"",
            b"\x1b[",
            b"\x1b\\\x9c",
            b"\xc3\x9c",
        ];
        let mut state = 0x2545_f491_u32;
        let mut next = |n: usize| {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            state as usize % n
        };
        for _ in 0..3000 {
            let mut output = Vec::new();
            for _ in 0..1 + next(4) {
                output.extend_from_slice(BEFORE[next(BEFORE.len())]);
                output.extend_from_slice(OPEN[next(OPEN.len())]);
                if next(4) != 0 {
                    output.push(b'G');
                }
                output.extend_from_slice(b"a=q,i=1,s=1,v=1,f=24");
                for _ in 0..next(4) {
                    output.push(b',');
                    output.extend_from_slice(KEYS[next(KEYS.len())]);
                }
                output.extend_from_slice(PAYLOAD[next(PAYLOAD.len())]);
                output.extend_from_slice(CLOSE[next(CLOSE.len())]);
            }
            let mut guard = MediaGuard::default();
            let mut out = Vec::new();
            let mut at = 0;
            while at < output.len() {
                let end = output.len().min(at + 1 + next(16));
                out.extend_from_slice(&guard.filter(&output[at..end]));
                at = end;
            }
            let replies = ghostty(&out);
            assert!(
                !replies.contains("medium"),
                "{:?}: {:?} -> {replies:?}",
                String::from_utf8_lossy(&output),
                String::from_utf8_lossy(&out)
            );
        }
    }
}
