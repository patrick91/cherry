//! Keep renderer and host at complete VT/UTF-8 boundaries and suppress queries
//! already answered by the host. Incomplete tokens stay here, not in snapshots.
#[derive(Default)]
pub struct DisplayStream {
    pending: Vec<u8>,
    mode: Mode,
    escaped: bool,
    utf8_left: usize,
    discarding: bool,
}
#[derive(Default, PartialEq, Eq)]
enum Mode {
    #[default]
    Ground,
    Escape,
    Csi,
    Osc,
    String,
    Utf8,
}
pub struct Batch {
    pub terminal: Vec<u8>,
    pub display: Vec<u8>,
}
const MAX_CONTROL: usize = 64 * 1024;

impl DisplayStream {
    pub fn feed(&mut self, bytes: &[u8]) -> Batch {
        let mut batch = Batch {
            terminal: Vec::new(),
            display: Vec::new(),
        };
        for &b in bytes {
            if self.mode == Mode::Ground {
                match b {
                    0x1b => {
                        self.pending.push(b);
                        self.mode = Mode::Escape;
                    }
                    0xc2..=0xf4 => {
                        self.pending.push(b);
                        self.mode = Mode::Utf8;
                        self.utf8_left = if b < 0xe0 {
                            1
                        } else if b < 0xf0 {
                            2
                        } else {
                            3
                        };
                    }
                    _ => {
                        batch.terminal.push(b);
                        batch.display.push(b);
                    }
                }
                continue;
            }
            if self.mode == Mode::Utf8 && !(0x80..=0xbf).contains(&b) {
                self.finish(&mut batch);
                let next = self.feed(&[b]);
                batch.terminal.extend(next.terminal);
                batch.display.extend(next.display);
                continue;
            }
            // ESC starts a new sequence even inside an unfinished CSI or
            // escape sequence. The abandoned prefix had no display effect.
            if b == 0x1b && matches!(self.mode, Mode::Csi | Mode::Escape) {
                self.pending.clear();
                self.pending.push(b);
                self.mode = Mode::Escape;
                self.discarding = false;
                continue;
            }
            if b == 0x18 || b == 0x1a {
                // CAN/SUB abort an unfinished control without exposing its
                // partial prefix to either parser or recovery journal.
                self.pending.clear();
                self.reset();
                batch.terminal.push(b);
                batch.display.push(b);
                continue;
            }
            if matches!(self.mode, Mode::Csi | Mode::Escape) && b < 0x20 {
                // Embedded C0 controls execute immediately, without ending
                // the CSI (a BEL here must not make a query evade filtering).
                batch.terminal.push(b);
                batch.display.push(b);
                continue;
            }
            if matches!(self.mode, Mode::Osc | Mode::String) && self.escaped && b != b'\\' {
                // ESC followed by anything except ST abandons the old
                // string and is the start of a fresh escape sequence.
                self.pending.clear();
                self.pending.push(0x1b);
                self.mode = Mode::Escape;
                self.escaped = false;
                self.discarding = false;
                let next = self.feed(&[b]);
                batch.terminal.extend(next.terminal);
                batch.display.extend(next.display);
                continue;
            }
            if !self.discarding {
                self.pending.push(b);
            }
            let complete = match self.mode {
                Mode::Escape => match b {
                    b'[' => {
                        self.mode = Mode::Csi;
                        false
                    }
                    b']' => {
                        self.mode = Mode::Osc;
                        false
                    }
                    b'P' | b'_' | b'^' | b'X' => {
                        self.mode = Mode::String;
                        false
                    }
                    0x20..=0x2f => false,
                    _ => true,
                },
                Mode::Csi => (0x40..=0x7e).contains(&b) || b == 0x18 || b == 0x1a,
                Mode::Osc | Mode::String => {
                    let end = (self.escaped && b == b'\\')
                        || (self.mode == Mode::Osc && b == 7)
                        || b == 0x18
                        || b == 0x1a;
                    self.escaped = b == 0x1b;
                    end
                }
                Mode::Utf8 => {
                    self.utf8_left -= 1;
                    self.utf8_left == 0
                }
                Mode::Ground => unreachable!(),
            };
            if complete {
                self.finish(&mut batch);
            } else if self.pending.len() > MAX_CONTROL {
                // Oversized control strings cannot grow memory without bound.
                self.pending.clear();
                self.discarding = true;
            }
        }
        batch
    }

    fn finish(&mut self, batch: &mut Batch) {
        if !self.discarding {
            batch.terminal.extend(&self.pending);
            if !is_query(&self.pending) {
                batch.display.extend(display_sequence(&self.pending));
            }
        }
        self.pending.clear();
        self.reset();
    }
    fn reset(&mut self) {
        self.mode = Mode::Ground;
        self.escaped = false;
        self.discarding = false;
        self.utf8_left = 0;
    }
}

fn display_sequence(bytes: &[u8]) -> Vec<u8> {
    // In-band resize reports belong to the PTY host. Letting the frontend
    // enable this mode would inject a second size report on each resize.
    if bytes.starts_with(b"\x1b[?") && matches!(bytes.last(), Some(b'h' | b'l')) {
        let modes: Vec<_> = bytes[3..bytes.len() - 1]
            .split(|&b| b == b';')
            .filter(|mode| *mode != b"2048")
            .collect();
        if modes.len() != bytes[3..bytes.len() - 1].split(|&b| b == b';').count() {
            if modes.is_empty() {
                return Vec::new();
            }
            let mut out = b"\x1b[?".to_vec();
            for (i, mode) in modes.iter().enumerate() {
                if i > 0 {
                    out.push(b';');
                }
                out.extend(*mode);
            }
            out.push(*bytes.last().unwrap());
            return out;
        }
    }
    bytes.to_vec()
}

fn is_query(bytes: &[u8]) -> bool {
    if bytes == b"\x1bZ" {
        return true;
    }
    if bytes.starts_with(b"\x1b[") {
        let last = bytes.last().copied().unwrap_or_default();
        let body = &bytes[2..bytes.len() - 1];
        return match last {
            b'c' | b'n' => true,
            b'p' => body.ends_with(b"$"),
            b'q' => body.starts_with(b">"),
            b'u' => body.starts_with(b"?"),
            b't' => matches!(
                body.split(|b| *b == b';').next().unwrap_or_default(),
                b"14" | b"16" | b"18" | b"19" | b"20" | b"21"
            ),
            _ => false,
        };
    }
    if bytes.starts_with(b"\x1b]") {
        let body = &bytes[2..];
        let code = body.split(|b| *b == b';').next().unwrap_or_default();
        return matches!(code, b"4" | b"10" | b"11" | b"12" | b"17" | b"19" | b"52")
            && body.contains(&b'?');
    }
    bytes.starts_with(b"\x1bP$q") || bytes.starts_with(b"\x1bP+q")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn splits_queries_and_utf8_without_duplicating_responses() {
        let mut stream = DisplayStream::default();
        assert!(stream.feed(b"\x1b[6").terminal.is_empty());
        let batch = stream.feed(b"nhello\x1b[31m");
        assert_eq!(batch.terminal, b"\x1b[6nhello\x1b[31m");
        assert_eq!(batch.display, b"hello\x1b[31m");
        assert!(stream.feed(&[0xe2, 0x82]).display.is_empty());
        assert_eq!(stream.feed(&[0xac]).display, [0xe2, 0x82, 0xac]);
    }
    #[test]
    fn osc_queries_are_answered_only_by_host_but_setters_pass() {
        let mut stream = DisplayStream::default();
        assert!(stream.feed(b"\x1b]11;?\x1b").terminal.is_empty());
        let batch = stream.feed(b"\\\x1b]11;rgb:00/00/00\x07");
        assert_eq!(batch.display, b"\x1b]11;rgb:00/00/00\x07");
        assert!(batch.terminal.starts_with(b"\x1b]11;?\x1b\\"));
    }
    #[test]
    fn malformed_large_controls_are_bounded() {
        let mut stream = DisplayStream::default();
        stream.feed(b"\x1b]");
        stream.feed(&vec![b'x'; MAX_CONTROL * 2]);
        assert!(stream.pending.len() <= MAX_CONTROL);
        assert_eq!(stream.feed(b"\x07ok").display, b"ok");
    }
    #[test]
    fn interrupted_queries_do_not_escape_filtering() {
        let mut stream = DisplayStream::default();
        let batch = stream.feed(b"\x1b[12;\x1b[6nOK");
        assert_eq!(batch.terminal, b"\x1b[6nOK");
        assert_eq!(batch.display, b"OK");
        let batch = stream.feed(b"\x1b]unfinished\x1b[5nEND");
        assert_eq!(batch.terminal, b"\x1b[5nEND");
        assert_eq!(batch.display, b"END");
    }
    #[test]
    fn cancellations_and_embedded_c0_preserve_ground_boundary() {
        let mut stream = DisplayStream::default();
        let batch = stream.feed(b"\x1b[6\x07n\x1b[1;\x18text");
        assert_eq!(batch.terminal, b"\x07\x1b[6n\x18text");
        assert_eq!(batch.display, b"\x07\x18text");
    }
    #[test]
    fn host_owns_in_band_resize_reports_without_losing_other_modes() {
        let mut stream = DisplayStream::default();
        let batch = stream.feed(b"\x1b[?2048h\x1b[?2004;2048h\x1b[?2048l");
        assert_eq!(batch.display, b"\x1b[?2004h");
        assert_eq!(batch.terminal, b"\x1b[?2048h\x1b[?2004;2048h\x1b[?2048l");
    }
    #[test]
    fn query_corpus_has_one_responder_across_fragmented_reads() {
        let queries: &[(&str, &[u8])] = &[
            ("status", b"\x1b[5n"),
            ("cursor", b"\x1b[6n"),
            ("primary attributes", b"\x1b[c"),
            ("secondary attributes", b"\x1b[>c"),
            ("mode", b"\x1b[?1$p"),
            ("kitty keyboard", b"\x1b[?u"),
            ("version", b"\x1b[>q"),
            ("cell size", b"\x1b[18t"),
            ("pixel area", b"\x1b[14t"),
            ("pixel cell", b"\x1b[16t"),
            ("color scheme", b"\x1b[?996n"),
            ("palette", b"\x1b]4;1;?\x07"),
            ("foreground", b"\x1b]10;?\x07"),
            ("background", b"\x1b]11;?\x07"),
            ("cursor color", b"\x1b]12;?\x07"),
            ("SGR state", b"\x1bP$qm\x1b\\"),
        ];
        for &(label, query) in queries {
            let mut stream = DisplayStream::default();
            let mut host = cherry_vt::Terminal::new(80, 24, 4096).unwrap();
            let mut frontend = cherry_vt::Terminal::new(80, 24, 4096).unwrap();
            let mut replies = Vec::new();
            for byte in query {
                let batch = stream.feed(&[*byte]);
                replies.extend(host.feed(&batch.terminal));
                assert!(
                    frontend.feed(&batch.display).is_empty(),
                    "frontend answered {label}"
                );
            }
            assert!(!replies.is_empty(), "host did not answer {label}");
        }
    }
}
