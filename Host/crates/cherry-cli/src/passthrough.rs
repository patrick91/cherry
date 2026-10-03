//! Session output that acts on the terminal rather than on its screen:
//! clipboard writes, titles, the working directory, notifications, colours
//! and bells, and the kitty graphics that do not depend on where the
//! session's cursor is. A viewport frame repaints only the screen, so in
//! viewport mode these are picked out of the output and written to the
//! window as they are. The output holds no queries: the host sends those
//! apart, to one client (`ServerMessage::Query`), which writes them to its
//! window in either mode.
//!
//! Kitty graphics (`Passthrough::graphics`): transmissions (`a=t`, and
//! their chunks), virtual placements (`U=1`, shown by unicode placeholder
//! cells, which the frames paint wherever they are), deletions and the
//! animation commands, which name images rather than cells, pass, with
//! `q=2`. What places an image at the session's cursor does not: the
//! window's cursor is not there. `a=T` passes as `a=t` (the image is
//! transmitted, not placed), and `a=p` without `U=1`, or a deletion at the
//! cursor (`d=c`), is dropped: the next frame places (or deletes) on the
//! window what the copy of the screen placed (see `Renderer`), when the
//! window shows it whole. Keys are read as Ghostty reads them
//! (`cherry_vt::kitty`): `a=84` is `a=T`; and a command that may name a
//! medium never passes (see `MediaGuard`).
//!
//! The scanner follows the host's tokenizer (`DisplayStream`): ESC restarts
//! an unfinished escape or CSI sequence, CAN and SUB abort any control, C0
//! controls inside an escape or CSI sequence execute at once, and an OSC ends
//! at BEL or ST while other strings end at ST only. It keeps its state across
//! calls, so a sequence split across output frames is found whole.

use cherry_vt::kitty;

/// Longest control sequence kept, as the host limits them.
const MAX_CONTROL: usize = 64 * 1024;
/// The chunks of an unfinished kitty transmission kept, at most (see
/// `Passthrough::unfinished_transfer`), as the host keeps them.
const MAX_TRANSFER: usize = cherry_protocol::MAX_SNAPSHOT_GRAPHICS_BYTES;
const GRAPHICS: &[u8] = b"\x1b_G";
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
    /// The chunks of a kitty transmission that began and has not ended, as
    /// they passed (see `unfinished_transfer`).
    transfer: Vec<u8>,
    /// One is on its way, whether or not its chunks are kept.
    transferring: bool,
    /// Its chunks were too many to keep.
    transfer_dropped: bool,
    /// A transmission without an image ID passed since `take_unnamed`.
    unnamed: bool,
    /// Kitty graphics passed since `take_graphics`.
    graphics: bool,
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
        let mut at = 0;
        while at < bytes.len() {
            // Text: only ESC and BEL matter.
            if self.state == State::Ground {
                match memchr::memchr2(0x1b, 0x07, &bytes[at..]) {
                    Some(skip) => at += skip,
                    None => break,
                }
            }
            if let Some(sequence) = self.byte(bytes[at]) {
                found.extend_from_slice(&sequence);
            }
            at += 1;
        }
        found
    }

    /// The output restarts at a sequence boundary (a replacement snapshot).
    pub fn reset(&mut self) {
        *self = Self::default();
    }

    /// The chunks of a kitty transmission the output began (`m=1`) and has
    /// not ended, as they passed: written again after the window's images
    /// were deleted (which abandons a transmission), the chunks still to
    /// come complete it. At most `MAX_TRANSFER` bytes; a longer one is not
    /// kept.
    pub fn unfinished_transfer(&self) -> &[u8] {
        &self.transfer
    }

    /// Whether a transmission without an image ID (`i=`) passed since last
    /// asked: the window gives the image an ID of its own, which may not be
    /// the one the screen copy gave it.
    pub fn take_unnamed(&mut self) -> bool {
        std::mem::take(&mut self.unnamed)
    }

    /// Whether kitty graphics passed since last asked.
    pub fn take_graphics(&mut self) -> bool {
        std::mem::take(&mut self.graphics)
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

    /// A whole kitty graphics command (`ESC _ G … ESC \`): what of it
    /// passes (see the module's documentation), with `q=2`, its keys as
    /// Ghostty reads them (`cherry_vt::kitty`). Never one whose control
    /// data may name a medium (see `MediaGuard`), nor one Ghostty refuses.
    fn graphics(&mut self, token: &[u8]) -> Option<Vec<u8>> {
        let body = &token[GRAPHICS.len()..token.len() - 2];
        let raw = &body[..body.iter().position(|&b| b == b';').unwrap_or(body.len())];
        if kitty::may_name_medium(raw) {
            return None;
        }
        let command = kitty::parse(body)?;
        // Ghostty ends a command at an 8-bit control: not one to pass.
        if body.iter().any(|b| (0x80..=0x9f).contains(b)) {
            return None;
        }
        let mut control = command.control;
        let more = control.more();
        let virtual_placement = control.get(b'U').is_some_and(|u| u != 0);
        // A chunk, which only says whether more follow (and `a=f`, which
        // kitty asks for on every chunk of a frame): of the transmission on
        // its way, or of none this one saw begin (not kept).
        let only_chunk = control.keys().all(|key| match key {
            b'm' | b'q' => true,
            b'a' => control.action() == b'f',
            _ => false,
        });
        let chunk = only_chunk && self.transferring;
        let action = if only_chunk { b't' } else { control.action() };
        match action {
            b't' | b'f' | b'a' | b'c' => {}
            b'T' if virtual_placement => {}
            // Transmitted, not placed at the session's cursor (which the
            // session does once its last chunk came).
            b'T' => control.set(b'a', u32::from(b't')),
            b'p' if virtual_placement => {}
            b'd' => {
                // Every deletion abandons a transmission on its way.
                self.end_transfer();
                if matches!(control.byte(b'd'), Some(b'c' | b'C')) {
                    return None;
                }
            }
            // A placement at the session's cursor.
            b'p' => return None,
            // A query (the host answers those), or what is not known.
            _ => return None,
        }
        if !control.for_renderers() {
            return None;
        }
        let out = kitty::silenced(&control, command.payload);
        // Placements and animation commands leave it alone, as a terminal
        // does (only deletions abandon it).
        if chunk || (!only_chunk && matches!(action, b't' | b'T' | b'f')) {
            self.follow_transfer(chunk, more, &out);
        }
        if !only_chunk
            && matches!(action, b't' | b'T')
            && control.get(b'i').is_none_or(|id| id == 0)
        {
            self.unnamed = true;
        }
        self.graphics = true;
        Some(out)
    }

    /// Keep the chunks of a transmission on its way, as they passed: a
    /// new transmission replaces it, its last chunk ends it.
    fn follow_transfer(&mut self, chunk: bool, more: bool, passed: &[u8]) {
        if !chunk {
            self.end_transfer();
        }
        if !more {
            self.end_transfer();
            return;
        }
        self.transferring = true;
        if self.transfer_dropped {
            return;
        }
        if self.transfer.len() + passed.len() > MAX_TRANSFER {
            self.transfer = Vec::new();
            self.transfer_dropped = true;
            return;
        }
        self.transfer.extend_from_slice(passed);
    }

    fn end_transfer(&mut self) {
        self.transfer = Vec::new();
        self.transferring = false;
        self.transfer_dropped = false;
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
    /// so other strings' data and hyperlinks are not copied: at once for
    /// DCS, PM, SOS and an APC other than kitty graphics, and once an
    /// OSC's code is complete. `byte` was just added.
    fn check(&mut self, byte: u8) {
        let keep = match self.state {
            _ if self.discarding => true,
            State::String => self.pending == GRAPHICS,
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
        let found = if self.discarding {
            None
        } else if self.pending.starts_with(GRAPHICS) && self.pending.ends_with(b"\x1b\\") {
            let token = std::mem::take(&mut self.pending);
            self.graphics(&token)
        } else {
            passes(&self.pending).then(|| std::mem::take(&mut self.pending))
        };
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
            "\x1bP$qm\x1b\\\x1b_Xother\x1b\\\x1b]133;A\x07\x1b]1337;File=x\x07",
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
        // Other strings' data is never copied, and kitty graphics no more
        // than the host passes.
        let mut scanner = Passthrough::default();
        let mut string = b"\x1bPq".to_vec();
        string.resize(4096, b'A');
        scanner.feed(&string);
        assert!(scanner.pending.is_empty());
        let mut image = b"\x1b_Gf=100;".to_vec();
        image.resize(MAX_CONTROL + 10, b'A');
        scanner.reset();
        assert!(scanner.feed(&image).is_empty());
        assert!(scanner.pending.capacity() <= MAX_CONTROL * 2);
        assert_eq!(
            scanner.feed(b"AA\x1b\\\x1b_Ga=t;AAAA\x1b\\"),
            b"\x1b_Ga=t,q=2;AAAA\x1b\\"
        );
        let mut hyperlink = b"\x1b]8;;".to_vec();
        hyperlink.resize(4096, b'x');
        scanner.reset();
        scanner.feed(&hyperlink);
        assert!(scanner.pending.is_empty());
    }

    /// What passes of each command, and whether an image passed without
    /// an ID.
    fn graphics(commands: &[&[u8]]) -> (Vec<Vec<u8>>, bool) {
        let mut scanner = Passthrough::default();
        let passed = commands
            .iter()
            .flat_map(|command| passed_by(&mut scanner, command))
            .collect();
        (passed, scanner.take_unnamed())
    }

    fn passed_by(scanner: &mut Passthrough, bytes: &[u8]) -> Vec<Vec<u8>> {
        let mut found = Vec::new();
        for &byte in bytes {
            if let Some(sequence) = scanner.byte(byte) {
                found.push(sequence);
            }
        }
        found
    }

    #[test]
    fn kitty_transmissions_virtual_placements_and_deletions_pass_quietly() {
        let (passed, unnamed) = graphics(&[
            b"\x1b_Ga=t,f=24,s=1,v=1,i=7;AQID\x1b\\",
            b"\x1b_Gf=100,i=8,q=0;AAAA\x1b\\",
            b"\x1b_Ga=T,U=1,f=24,s=1,v=1,i=9,c=2,r=1,q=1;AQID\x1b\\",
            b"\x1b_Ga=p,U=1,i=7,c=2,r=1\x1b\\",
            b"\x1b_Ga=d,d=i,i=7\x1b\\",
            b"\x1b_Ga=d,d=A\x1b\\",
            b"\x1b_Ga=f,i=9,r=2,f=24,s=1,v=1;AQID\x1b\\",
            b"\x1b_Ga=a,i=9,s=3\x1b\\",
        ]);
        assert!(!unnamed);
        assert_eq!(
            passed,
            [
                &b"\x1b_Ga=t,f=24,s=1,v=1,i=7,q=2;AQID\x1b\\"[..],
                b"\x1b_Gf=100,i=8,q=2;AAAA\x1b\\",
                b"\x1b_Ga=T,U=1,f=24,s=1,v=1,i=9,c=2,r=1,q=2;AQID\x1b\\",
                b"\x1b_Ga=p,U=1,i=7,c=2,r=1,q=2\x1b\\",
                b"\x1b_Ga=d,d=i,i=7,q=2\x1b\\",
                b"\x1b_Ga=d,d=A,q=2\x1b\\",
                b"\x1b_Ga=f,i=9,r=2,f=24,s=1,v=1,q=2;AQID\x1b\\",
                b"\x1b_Ga=a,i=9,s=3,q=2\x1b\\",
            ]
        );
    }

    #[test]
    fn kitty_placements_at_the_sessions_cursor_do_not_pass() {
        // Transmitted and not placed, as Ghostty reads it in letters or
        // numbers.
        for command in [
            &b"\x1b_Ga=T,f=24,s=1,v=1,i=7,C=1;AQID\x1b\\"[..],
            b"\x1b_Ga=84,f=24,s=1,v=1,i=+7,C=1;AQID\x1b\\",
        ] {
            let (passed, unnamed) = graphics(&[command]);
            assert_eq!(
                passed,
                [b"\x1b_Ga=t,f=24,s=1,v=1,i=7,C=1,q=2;AQID\x1b\\".to_vec()]
            );
            assert!(!unnamed);
        }
        for command in [
            &b"\x1b_Ga=p,i=7,p=3,c=2\x1b\\"[..],
            b"\x1b_Ga=p,I=4\x1b\\",
            b"\x1b_Ga=112,i=7\x1b\\",
            b"\x1b_Ga=d,d=c\x1b\\",
            b"\x1b_Ga=d,d=C\x1b\\",
            b"\x1b_Ga=d,d=99\x1b\\",
        ] {
            let (passed, _) = graphics(&[command]);
            assert!(passed.is_empty(), "{command:?}");
        }
        // Queries are the host's, and unknown actions are not passed.
        for command in [&b"\x1b_Ga=q,i=1,s=1,v=1;AAAA\x1b\\"[..], b"\x1b_Ga=z\x1b\\"] {
            let (passed, _) = graphics(&[command]);
            assert!(passed.is_empty(), "{command:?}");
        }
        // An image without an ID gets one of the window's own.
        for command in [
            &b"\x1b_Ga=T,f=24,s=1,v=1;AQID\x1b\\"[..],
            b"\x1b_Ga=t,I=3,f=24,s=1,v=1;AQID\x1b\\",
            b"\x1b_Gf=24,s=1,v=1,i=0;AQID\x1b\\",
        ] {
            assert!(graphics(&[command]).1, "{command:?}");
        }
    }

    #[test]
    fn a_kitty_transmission_on_its_way_is_kept_until_it_ends() {
        let mut scanner = Passthrough::default();
        // `a=T` is passed, and kept, as `a=t`.
        let first = scanner.feed(b"\x1b_Ga=T,f=24,s=2,v=1,i=5,m=1;AQID\x1b\\text");
        assert_eq!(first, b"\x1b_Ga=t,f=24,s=2,v=1,i=5,m=1,q=2;AQID\x1b\\");
        assert_eq!(scanner.unfinished_transfer(), first);
        // A chunk of it, split anywhere, and a placement in between.
        scanner.feed(b"\x1b_Gm=1;BB");
        scanner.feed(b"BB\x1b\\\x1b_Ga=p,U=1,i=5\x1b\\");
        assert_eq!(
            scanner.unfinished_transfer(),
            [&first[..], b"\x1b_Gm=1,q=2;BBBB\x1b\\"].concat()
        );
        // Its last chunk ends it.
        assert_eq!(
            scanner.feed(b"\x1b_Gm=0;CCCC\x1b\\"),
            b"\x1b_Gm=0,q=2;CCCC\x1b\\"
        );
        assert!(scanner.unfinished_transfer().is_empty());
        // A chunk of none this scanner saw begin passes, and is not kept.
        assert_eq!(
            scanner.feed(b"\x1b_Gm=1;DDDD\x1b\\"),
            b"\x1b_Gm=1,q=2;DDDD\x1b\\"
        );
        assert!(scanner.unfinished_transfer().is_empty());
        // A new transmission replaces one, and a deletion abandons it.
        scanner.feed(b"\x1b_Ga=t,i=6,m=1;AAAA\x1b\\\x1b_Ga=t,i=7,m=1;BBBB\x1b\\");
        assert_eq!(
            scanner.unfinished_transfer(),
            b"\x1b_Ga=t,i=7,m=1,q=2;BBBB\x1b\\"
        );
        scanner.feed(b"\x1b_Ga=d,d=i,i=3\x1b\\");
        assert!(scanner.unfinished_transfer().is_empty());
        // One too long to keep is dropped, with the rest of it.
        scanner.feed(b"\x1b_Ga=t,i=8,m=1;AAAA\x1b\\");
        let chunk = [&b"\x1b_Gm=1;"[..], &[b'A'; 4096], b"\x1b\\"].concat();
        for _ in 0..(MAX_TRANSFER / 4096 + 1) {
            assert!(!scanner.feed(&chunk).is_empty());
        }
        assert!(scanner.unfinished_transfer().is_empty());
        scanner.feed(&chunk);
        assert!(scanner.unfinished_transfer().is_empty());
        scanner.feed(b"\x1b_Gm=0;AAAA\x1b\\\x1b_Ga=t,i=9,m=1;AAAA\x1b\\");
        assert_eq!(
            scanner.unfinished_transfer(),
            b"\x1b_Ga=t,i=9,m=1,q=2;AAAA\x1b\\"
        );
        assert!(scanner.take_graphics());
        assert!(!scanner.take_graphics());
    }
}
