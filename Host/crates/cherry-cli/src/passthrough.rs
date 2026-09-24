//! Session output that acts on the terminal rather than on its screen:
//! clipboard writes, titles, the working directory, notifications, colours
//! and bells. A viewport frame repaints only the screen, so in viewport mode
//! these are picked out of the output and written to the window as they are.
//! The output holds no queries: the host sends those apart, to one client
//! (`ServerMessage::Query`), which writes them to its window in either mode.
//!
//! The scanner follows the host's tokenizer (`DisplayStream`): ESC restarts
//! an unfinished escape or CSI sequence, CAN and SUB abort any control, C0
//! controls inside an escape or CSI sequence execute at once, and an OSC ends
//! at BEL or ST while other strings end at ST only. It keeps its state across
//! calls, so a sequence split across output frames is found whole.

/// Longest control sequence kept, as the host limits them.
const MAX_CONTROL: usize = 64 * 1024;
/// OSC 52 clipboard writes carry base64 text; the host passes up to 8 MiB.
const MAX_CLIPBOARD: usize = 8 * 1024 * 1024;
const CLIPBOARD: &[u8] = b"\x1b]52;";

#[derive(Default)]
pub struct Passthrough {
    state: State,
    /// The unfinished control sequence, from its ESC.
    pending: Vec<u8>,
    /// It cannot be passed through (too long, or not of interest): the rest
    /// of it is skipped.
    discarding: bool,
    /// Inside an OSC or string: the previous byte was ESC.
    escaped: bool,
    /// Inside an OSC: whether it can pass through is decided.
    checked: bool,
}

#[derive(Default, Clone, Copy, PartialEq, Eq)]
enum State {
    #[default]
    Ground,
    Escape,
    Csi,
    Osc,
    /// DCS, APC, PM and SOS.
    String,
}

impl Passthrough {
    /// Scan `bytes`, which follow everything scanned before; returns the
    /// sequences to write through, back to back.
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<u8> {
        let mut found = Vec::new();
        for &byte in bytes {
            if let Some(sequence) = self.byte(byte) {
                found.extend_from_slice(&sequence);
            }
        }
        found
    }

    /// The output restarts at a sequence boundary (a replacement snapshot).
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    fn byte(&mut self, byte: u8) -> Option<Vec<u8>> {
        match self.state {
            State::Ground => {
                match byte {
                    0x1b => self.start(),
                    0x07 => return Some(vec![byte]),
                    _ => {}
                }
                None
            }
            State::Escape | State::Csi => {
                match byte {
                    0x1b => self.start(),
                    0x18 | 0x1a => self.end(),
                    0x07 => return Some(vec![byte]),
                    // Other C0 controls execute without ending the sequence.
                    0x00..=0x1f => {}
                    _ => {
                        self.push(byte);
                        if self.state == State::Escape {
                            match byte {
                                b'[' => self.state = State::Csi,
                                b']' => self.state = State::Osc,
                                b'P' | b'_' | b'^' | b'X' => self.state = State::String,
                                0x20..=0x2f => {}
                                _ => self.end(),
                            }
                        } else if (0x40..=0x7e).contains(&byte) {
                            return self.finish();
                        }
                    }
                }
                None
            }
            State::Osc | State::String => {
                if self.escaped && byte != b'\\' {
                    // ESC and anything but ST abandons the string and starts
                    // a new escape sequence.
                    self.start();
                    return self.byte(byte);
                }
                if byte == 0x18 || byte == 0x1a {
                    self.end();
                    return None;
                }
                self.push(byte);
                let end =
                    (self.escaped && byte == b'\\') || (self.state == State::Osc && byte == 0x07);
                self.escaped = byte == 0x1b;
                if end {
                    return self.finish();
                }
                if !self.checked {
                    self.check(byte);
                }
                None
            }
        }
    }

    fn start(&mut self) {
        self.pending.clear();
        self.pending.push(0x1b);
        self.state = State::Escape;
        self.discarding = false;
        self.escaped = false;
        self.checked = false;
    }

    fn push(&mut self, byte: u8) {
        if !self.discarding {
            self.pending.push(byte);
            if self.pending.len() > self.limit() {
                self.discard();
            }
        }
    }

    fn discard(&mut self) {
        self.pending.clear();
        self.pending.shrink_to(MAX_CONTROL);
        self.discarding = true;
    }

    fn limit(&self) -> usize {
        if self.state == State::Osc && self.pending.starts_with(CLIPBOARD) {
            MAX_CLIPBOARD
        } else {
            MAX_CONTROL
        }
    }

    /// Stop keeping a string as soon as it cannot be one to pass through,
    /// so image data and hyperlinks are not copied: at once for DCS, APC,
    /// PM and SOS, and once an OSC's code is complete. `byte` was just added.
    fn check(&mut self, byte: u8) {
        let keep = match self.state {
            _ if self.discarding => true,
            State::String => false,
            _ if byte.is_ascii_digit() => return,
            _ => osc_code(&self.pending[2..self.pending.len() - 1]).is_some(),
        };
        self.checked = true;
        if !keep {
            self.discard();
        }
    }

    fn end(&mut self) {
        self.pending.clear();
        // A clipboard write's buffer is not kept.
        self.pending.shrink_to(MAX_CONTROL);
        self.state = State::Ground;
        self.discarding = false;
        self.escaped = false;
        self.checked = false;
    }

    fn finish(&mut self) -> Option<Vec<u8>> {
        let found =
            (!self.discarding && passes(&self.pending)).then(|| std::mem::take(&mut self.pending));
        self.end();
        found
    }
}

/// Whether a complete control sequence passes through.
fn passes(token: &[u8]) -> bool {
    if let Some(body) = token.strip_prefix(b"\x1b]") {
        let Some(digits) = body.iter().position(|b| !b.is_ascii_digit()) else {
            return false;
        };
        // `OSC code ;` or a bare `OSC code` (a reset), then the terminator.
        if !matches!(body[digits], b';' | 0x07 | 0x1b) {
            return false;
        }
        let Some(code) = osc_code(&body[..digits]) else {
            return false;
        };
        // Queries ask with `?`; the host sends them apart, and none belongs
        // in the output. Titles, the working directory and notifications
        // may contain one as text.
        return match code {
            0 | 1 | 2 | 7 | 9 | 777 => true,
            // Kitty notifications ask with `p=?` in their metadata.
            99 => !body
                .strip_suffix(b"\x07")
                .or_else(|| body.strip_suffix(b"\x1b\\"))
                .unwrap_or(body)
                .split(|&b| b == b';')
                .nth(1)
                .is_some_and(|metadata| metadata.split(|&b| b == b':').any(|item| item == b"p=?")),
            _ => !body.contains(&b'?'),
        };
    }
    // The title stack (XTWINOPS 22 and 23); not the window operations.
    let Some(body) = token.strip_prefix(b"\x1b[") else {
        return false;
    };
    let Some(params) = body.strip_suffix(b"t") else {
        return false;
    };
    let first = params.split(|&b| b == b';').next().unwrap_or_default();
    matches!(first, b"22" | b"23") && params.iter().all(|&b| b.is_ascii_digit() || b == b';')
}

/// The OSC codes that pass through: titles (0-2), the working directory (7),
/// notifications (9, 99, 777), the clipboard (52) and colours, whose
/// settings apply to the colours viewport frames paint with (4, 5, 10-19,
/// 21, 104, 105, 110-119).
fn osc_code(digits: &[u8]) -> Option<u32> {
    let code: u32 = std::str::from_utf8(digits).ok()?.parse().ok()?;
    matches!(
        code,
        0 | 1 | 2 | 7 | 9 | 52 | 99 | 777 | 4 | 5 | 10..=19 | 21 | 104 | 105 | 110..=119
    )
    .then_some(code)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Each sequence passed through, scanned one by one.
    fn passed(bytes: &[u8]) -> Vec<Vec<u8>> {
        let mut scanner = Passthrough::default();
        let mut found = Vec::new();
        for &byte in bytes {
            if let Some(sequence) = scanner.byte(byte) {
                found.push(sequence);
            }
        }
        found
    }

    #[test]
    fn terminal_sequences_pass_and_screen_content_does_not() {
        let stream = concat!(
            "text\x1b[1;31mred\x1b[0m\x1b]8;;https://x\x1b\\link\x1b]8;;\x1b\\",
            "\x1b]52;c;aGVsbG8=\x07",
            "\x1b]2;TITLE?\x1b\\",
            "\x1b]0;both\x07\x1b]7;file://h/tmp\x07",
            "\x1b]9;done?\x07\x1b]777;notify;T?;B?\x07\x1b]99;;hi\x1b\\",
            "\x1b]99;i=1:d=0;Deploy now?\x1b\\\x1b]99;;Continue?\x07",
            "\x07\x1b[22;0t\x1b[23;0t",
            "\x1b]4;1;rgb:ff/00/00\x07\x1b]104\x07\x1b]13;red\x07",
            "\x1bP$qm\x1b\\\x1b_Gf=100;AAAA\x1b\\\x1b]133;A\x07\x1b]1337;File=x\x07",
            "\x1b[?1049h\x1b[H\x1b[2J\x1b[8;40;100t\x1b[3;1;1t\x1b[>4;2m",
        )
        .as_bytes();
        assert_eq!(
            passed(stream),
            [
                &b"\x1b]52;c;aGVsbG8=\x07"[..],
                b"\x1b]2;TITLE?\x1b\\",
                b"\x1b]0;both\x07",
                b"\x1b]7;file://h/tmp\x07",
                b"\x1b]9;done?\x07",
                b"\x1b]777;notify;T?;B?\x07",
                b"\x1b]99;;hi\x1b\\",
                b"\x1b]99;i=1:d=0;Deploy now?\x1b\\",
                b"\x1b]99;;Continue?\x07",
                b"\x07",
                b"\x1b[22;0t",
                b"\x1b[23;0t",
                b"\x1b]4;1;rgb:ff/00/00\x07",
                b"\x1b]104\x07",
                b"\x1b]13;red\x07",
            ]
        );
        let mut scanner = Passthrough::default();
        assert_eq!(scanner.feed(b"a\x07b\x1b]2;T\x07c"), b"\x07\x1b]2;T\x07");
    }

    #[test]
    fn queries_never_pass() {
        // The host sends them apart; were one in the output, the window
        // would answer it a second time.
        for query in [
            &b"\x1b[?6n"[..],
            b"\x1b[5n",
            b"\x1b[1$w",
            b"\x1b[21t",
            b"\x1b[4$p",
            b"\x1b[x",
            b"\x1b[?4m",
            b"\x1bP+q544e\x1b\\",
            b"\x1b]52;c;?\x07",
            b"\x1b]11;?\x1b\\",
            b"\x1b]4;1;?\x07",
            b"\x1b]99;i=1:p=?;\x1b\\",
            b"\x1b]99;p=?\x07",
        ] {
            assert!(passed(query).is_empty(), "{query:?}");
        }
    }

    #[test]
    fn sequences_split_across_frames_are_found_whole() {
        let stream = b"a\x1b]52;c;aGVsbG8=\x07b\x1b]2;T\x1b\\c\x1b[22;0t\x07";
        let whole = Passthrough::default().feed(stream);
        assert_eq!(whole.len(), stream.len() - 3);
        for split in 0..=stream.len() {
            let mut scanner = Passthrough::default();
            let mut found = scanner.feed(&stream[..split]);
            found.extend(scanner.feed(&stream[split..]));
            assert_eq!(found, whole, "split at {split}");
        }
    }

    #[test]
    fn terminators_aborts_and_restarts_follow_the_host() {
        // BEL ends the OSC; it is not a bell of its own.
        assert_eq!(passed(b"\x1b]2;T\x07"), [b"\x1b]2;T\x07".to_vec()]);
        // A BEL inside a CSI sequence rings; the sequence continues.
        assert_eq!(
            passed(b"\x1b[22\x07;0t"),
            [b"\x07".to_vec(), b"\x1b[22;0t".to_vec()]
        );
        // CAN and SUB abort, including strings.
        assert_eq!(passed(b"\x1b]2;T\x18\x07"), [b"\x07".to_vec()]);
        assert!(passed(b"\x1b]52;c;AA\x1a").is_empty());
        // ESC restarts an unfinished CSI; ESC plus anything but `\`
        // abandons a string.
        assert_eq!(passed(b"\x1b[2\x1b[22;0t"), [b"\x1b[22;0t".to_vec()]);
        assert_eq!(
            passed(b"\x1b]2;lost\x1b]2;kept\x1b\\"),
            [b"\x1b]2;kept\x1b\\".to_vec()]
        );
        // BEL does not end a DCS string, and nothing in one passes.
        assert_eq!(passed(b"\x1bP+q54\x0745\x1b\\\x07"), [b"\x07".to_vec()]);
    }

    #[test]
    fn oversized_strings_are_skipped_without_growing() {
        let mut scanner = Passthrough::default();
        let mut title = b"\x1b]2;".to_vec();
        title.resize(MAX_CONTROL + 10, b'x');
        assert!(scanner.feed(&title).is_empty());
        assert!(scanner.pending.capacity() <= MAX_CONTROL * 2);
        // The rest of it, then a normal title.
        assert_eq!(scanner.feed(b"xx\x07\x1b]2;ok\x07"), b"\x1b]2;ok\x07");
        // Clipboard writes may be larger.
        let mut clipboard = b"\x1b]52;c;".to_vec();
        clipboard.resize(MAX_CONTROL * 4, b'A');
        clipboard.push(0x07);
        assert_eq!(passed(&clipboard), [clipboard.clone()]);
        // Image data is never copied.
        let mut scanner = Passthrough::default();
        let mut image = b"\x1b_Gf=100;".to_vec();
        image.resize(4096, b'A');
        scanner.feed(&image);
        assert!(scanner.pending.is_empty());
        let mut hyperlink = b"\x1b]8;;".to_vec();
        hyperlink.resize(4096, b'x');
        scanner.reset();
        scanner.feed(&hyperlink);
        assert!(scanner.pending.is_empty());
    }
}
