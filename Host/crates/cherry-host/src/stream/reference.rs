//! The display stream as it was before its fast paths: `DisplayStream`'s
//! byte-at-a-time state machine, verbatim, and its CSI routing without the
//! fast path's early return (`csi_may_query`). It is the reference the
//! differential tests hold the fast paths to (see `stream::tests`). The rest
//! of the routing (OSC, DCS and APC, `csi_query`, `display_sequence`) is
//! `stream`'s own: a fast path that adds an early return to one of those
//! needs its own copy here again.
#![allow(dead_code)]
use super::{csi_query, display_sequence, route_graphics, route_osc, route_xtgettcap, Route};

#[derive(Default)]
pub struct DisplayStream {
    pending: Vec<u8>,
    mode: Mode,
    escaped: bool,
    utf8_left: usize,
    discarding: bool,
    /// In `Mode::String`: what began it (`P`, `X`, `^` or `_`).
    string: u8,
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
#[derive(Default)]
pub struct Batch {
    /// For the host terminal.
    pub terminal: Vec<u8>,
    /// For every renderer: the output stream.
    pub display: Vec<u8>,
    /// For the renderer that answers queries: each with its position in
    /// `display` (the length `display` had when it came).
    pub queries: Vec<(usize, Vec<u8>)>,
    /// Complete kitty notification sequences (OSC 99), which the host
    /// terminal does not report (see `cherry_vt::Osc99`), each with its
    /// position in `terminal` (the length `terminal` had when it came), so
    /// that it is reported in order with what the terminal reports.
    pub notifications: Vec<(usize, Vec<u8>)>,
}

impl Batch {
    /// Append the batch that follows this one.
    pub fn append(&mut self, next: Batch) {
        let base = self.display.len();
        let terminal_base = self.terminal.len();
        self.terminal.extend(next.terminal);
        self.display.extend(next.display);
        for (at, query) in next.queries {
            self.push_query(base + at, &query);
        }
        self.notifications.extend(
            next.notifications
                .into_iter()
                .map(|(at, sequence)| (terminal_base + at, sequence)),
        );
    }

    fn query(&mut self, bytes: &[u8]) {
        self.push_query(self.display.len(), bytes);
    }

    /// Queries with nothing between them travel together.
    fn push_query(&mut self, at: usize, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        match self.queries.last_mut() {
            Some((last, query)) if *last == at => query.extend_from_slice(bytes),
            _ => self.queries.push((at, bytes.to_vec())),
        }
    }

    /// A C0 control, executed where it stands. ENQ asks the terminal for its
    /// answerback message: a query.
    fn control(&mut self, byte: u8) {
        self.terminal.push(byte);
        if byte == ENQ {
            self.query(&[byte]);
        } else {
            self.display.push(byte);
        }
    }
}
const MAX_CONTROL: usize = 64 * 1024;
/// OSC 52 clipboard writes carry base64 text and go only to the renderer;
/// they may be much larger than other control strings.
pub const MAX_CLIPBOARD: usize = 8 * 1024 * 1024;
const CLIPBOARD: &[u8] = b"\x1b]52;";
const KITTY_NOTIFICATION: &[u8] = b"\x1b]99;";
const ENQ: u8 = 0x05;

impl DisplayStream {
    pub fn feed(&mut self, bytes: &[u8]) -> Batch {
        let mut batch = Batch::default();
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
                    ENQ => batch.control(b),
                    _ => {
                        batch.terminal.push(b);
                        batch.display.push(b);
                    }
                }
                continue;
            }
            if self.mode == Mode::Utf8 && !(0x80..=0xbf).contains(&b) {
                self.finish(&mut batch);
                batch.append(self.feed(&[b]));
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
                batch.control(b);
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
                batch.append(self.feed(&[b]));
                continue;
            }
            if matches!(self.mode, Mode::Escape | Mode::Csi | Mode::String) && b >= 0x7f {
                match b {
                    0x80..=0x9f => {
                        self.eight_bit_control(b, &mut batch);
                        continue;
                    }
                    // DEL is a string's data.
                    0x7f if self.mode == Mode::String => {}
                    // Ghostty ignores DEL in a sequence, and 0xa0 and up
                    // anywhere but in an OSC string.
                    _ => continue,
                }
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
                        self.string = b;
                        false
                    }
                    0x20..=0x2f => false,
                    _ => true,
                },
                Mode::Csi => (0x40..=0x7e).contains(&b),
                Mode::Osc | Mode::String => {
                    let end = (self.escaped && b == b'\\') || (self.mode == Mode::Osc && b == 7);
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
            } else if self.pending.len() > self.limit() {
                // Oversized control strings cannot grow memory without bound.
                self.pending.clear();
                self.discarding = true;
            }
        }
        batch
    }

    /// An 8-bit C1 control (0x80 to 0x9f) inside an escape sequence, a
    /// control sequence or a string other than OSC (whose data it is):
    /// Ghostty acts on it as on its 7-bit form (`ESC` and the byte less
    /// 0x40), so it is made that form, and the host's terminal, every
    /// renderer and this stream read one sequence. ST (0x9c) ends a string;
    /// in SOS, PM or APC a string's own introducer is ignored, as Ghostty
    /// ignores it; anything else abandons what came so far (which had no
    /// display effect, as when ESC does) and begins its own sequence. A
    /// kitty graphics command so begun is routed as any other, never
    /// passed as text a renderer would take for one.
    fn eight_bit_control(&mut self, b: u8, batch: &mut Batch) {
        if self.mode == Mode::String {
            if b == 0x9c {
                if self.discarding {
                    self.pending.clear();
                    self.reset();
                } else {
                    self.pending.extend_from_slice(b"\x1b\\");
                    self.finish(batch);
                }
                return;
            }
            if matches!(b, 0x98 | 0x9e | 0x9f) && matches!(self.string, b'X' | b'^' | b'_') {
                return;
            }
        }
        self.pending.clear();
        self.reset();
        let seven = [0x1b, b - 0x40];
        match b {
            0x9c => {}
            0x90 | 0x98 | 0x9e | 0x9f => {
                self.pending.extend_from_slice(&seven);
                self.mode = Mode::String;
                self.string = b - 0x40;
            }
            0x9b => {
                self.pending.extend_from_slice(&seven);
                self.mode = Mode::Csi;
            }
            0x9d => {
                self.pending.extend_from_slice(&seven);
                self.mode = Mode::Osc;
            }
            _ => {
                self.pending.extend_from_slice(&seven);
                self.finish(batch);
            }
        }
    }

    fn limit(&self) -> usize {
        if self.mode == Mode::Osc && self.pending.starts_with(CLIPBOARD) {
            MAX_CLIPBOARD
        } else {
            MAX_CONTROL
        }
    }

    fn finish(&mut self, batch: &mut Batch) {
        if self.mode == Mode::String
            && matches!(self.string, b'X' | b'^')
            && self.pending.get(2) == Some(&b'G')
        {
            // Ghostty reads SOS and PM as it reads APC: a kitty graphics
            // command in one is one, and is routed as one.
            self.pending[1] = b'_';
        }
        if !self.discarding {
            if self.pending.starts_with(KITTY_NOTIFICATION) {
                batch
                    .notifications
                    .push((batch.terminal.len(), self.pending.clone()));
            }
            match route(&self.pending) {
                Route::Both => {
                    batch.terminal.extend(&self.pending);
                    batch
                        .display
                        .extend_from_slice(&display_sequence(&self.pending));
                }
                Route::Host => batch.terminal.extend(&self.pending),
                Route::Display => batch.display.extend(&self.pending),
                Route::Query => batch.query(&self.pending),
                Route::Forward => {
                    batch.terminal.extend(&self.pending);
                    batch.query(&self.pending);
                }
                Route::Split { display, query } => {
                    batch.terminal.extend(&self.pending);
                    batch.display.extend(display);
                    batch.query(&query);
                }
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

fn route(token: &[u8]) -> Route {
    if token == b"\x1bZ" {
        return Route::Host;
    }
    if token.starts_with(b"\x1b[") {
        return route_csi(token);
    }
    if token.starts_with(b"\x1b]") {
        return route_osc(token);
    }
    if token.starts_with(b"\x1bP$q") {
        // DECRQSS: the host answers every request, valid or not.
        return Route::Host;
    }
    if token.starts_with(b"\x1bP+q") {
        return route_xtgettcap(token);
    }
    if token.starts_with(b"\x1b_G") {
        return route_graphics(token);
    }
    Route::Both
}

fn route_csi(token: &[u8]) -> Route {
    let Some((&last, body)) = token[2..].split_last() else {
        return Route::Both;
    };
    let (prefix, rest) = match body.first() {
        Some(&b @ (b'<' | b'=' | b'>' | b'?')) => (Some(b), &body[1..]),
        _ => (None, body),
    };
    let split = rest
        .iter()
        .position(|b| (0x20..=0x2f).contains(b))
        .unwrap_or(rest.len());
    let (params, intermediates) = rest.split_at(split);
    let host = match (last, prefix, intermediates) {
        // Device attributes (primary, secondary, tertiary).
        (b'c', None | Some(b'>' | b'='), b"") => true,
        // Status and cursor reports, the extended cursor report (DECXCPR)
        // and the colour-scheme report.
        (b'n', None, b"") => matches!(params, b"5" | b"6"),
        (b'n', Some(b'?'), b"") => matches!(params, b"6" | b"996"),
        // Mode reports (DECRQM), DEC private and ANSI.
        (b'p', Some(b'?') | None, b"$") => true,
        // XTVERSION.
        (b'q', Some(b'>'), b"") => true,
        // Kitty keyboard flags, whatever the parameters.
        (b'u', Some(b'?'), b"") => true,
        // Text area, cell and screen size reports.
        (b't', None, b"") => matches!(params, b"14" | b"16" | b"18" | b"19"),
        _ => false,
    };
    if host {
        Route::Host
    } else if csi_query(last, prefix, params, intermediates) {
        Route::Forward
    } else {
        Route::Both
    }
}
