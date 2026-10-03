//! Keep renderer and host at complete VT/UTF-8 boundaries and give every
//! terminal query exactly one responder. Incomplete tokens stay here, not in
//! snapshots.
//!
//! The host terminal answers a fixed set of queries whether or not a client
//! is attached; those are removed from the renderers' stream. Every other
//! query (`CSI ?6n`, an OSC 52 read, OSC 13–19 colour queries, `CSI 19–21
//! t`, ANSI `$p`, an XTGETTCAP name the host does not know, …) is split out
//! of it too, into `Batch::queries`: the session sends those to one attached
//! renderer (`ServerMessage::Query`), whose terminal answers. They are not
//! part of the offset-accounted output, so neither snapshots nor a lagging
//! client's resync repeat them. Kitty graphics commands reach the renderers
//! with `q=2`, so only the host replies, and only as Ghostty reads them,
//! never one that names a file (see `route_graphics`).
//!
//! Where Ghostty acts on 8-bit controls (inside an escape sequence, a
//! control sequence or a string other than OSC) they are made their 7-bit
//! forms, and bytes Ghostty ignores there are dropped
//! (`eight_bit_control`), so no renderer reads a sequence the tokenizer did
//! not see: a kitty graphics command begun by 0x9f inside a control
//! sequence is one, routed as any other.
//!
//! Output floods are mostly text and short CSI sequences, so the ground
//! state passes runs of text through whole and routes a CSI or OSC sequence
//! that arrives complete without buffering it; everything else goes through
//! the byte-at-a-time state machine (`step`), which the fast paths match
//! exactly.
use cherry_vt::{kitty, Terminal};
use std::{borrow::Cow, collections::HashMap, sync::Mutex};

#[derive(Default)]
pub struct DisplayStream {
    pending: Vec<u8>,
    mode: Mode,
    escaped: bool,
    utf8_left: usize,
    discarding: bool,
    /// In `Mode::String`: what began it (`P`, `X`, `^` or `_`).
    string: u8,
    transfer: Transfer,
    /// OSC 52 clipboard writes dropped for exceeding `MAX_CLIPBOARD` since
    /// `take_dropped_clipboard_writes` last read it.
    dropped_clipboard_writes: usize,
}

/// A chunked kitty graphics transmission (`m=1`) that has begun and not
/// ended, as renderers get it (`q=2`): a snapshot taken meanwhile carries
/// it, so the chunks that follow complete it on the renderer as on the
/// host. At most `cherry_protocol::MAX_SNAPSHOT_GRAPHICS_BYTES`; a longer
/// one is dropped, and so are its later chunks.
#[derive(Default)]
struct Transfer {
    chunks: Vec<u8>,
    /// Its chunks go on, but it was dropped.
    dropped: bool,
}

impl Transfer {
    fn observe(&mut self, token: &[u8]) {
        if token == b"\x1bc" {
            // A reset abandons it.
            *self = Self::default();
            return;
        }
        let Some(body) = token
            .strip_prefix(b"\x1b_G")
            .and_then(|rest| rest.strip_suffix(b"\x1b\\"))
        else {
            return;
        };
        // One Ghostty refuses does nothing.
        let Some(command) = kitty::parse(body) else {
            return;
        };
        let control = &command.control;
        let more = control.more();
        // A chunk says only whether more follow (and `a=f`, which kitty
        // asks for on every chunk of an animation frame).
        let continues = control.keys().all(|key| match key {
            b'm' | b'q' => true,
            b'a' => control.action() == b'f',
            _ => false,
        });
        if continues {
            if self.chunks.is_empty() && !self.dropped {
                return;
            }
        } else {
            match control.action() {
                // A new transmission replaces it.
                b't' | b'T' | b'f' => {}
                // A deletion abandons it, as it does on a terminal.
                b'd' => {
                    *self = Self::default();
                    return;
                }
                // A probe, a placement or an animation command leaves it
                // alone.
                _ => return,
            }
            *self = Self::default();
            if !more {
                return;
            }
        }
        if !more {
            *self = Self::default();
            return;
        }
        if self.dropped {
            return;
        }
        let Some(display) = kitty::for_renderers(body) else {
            return;
        };
        if self.chunks.len() + display.len() > cherry_protocol::MAX_SNAPSHOT_GRAPHICS_BYTES {
            *self = Self {
                chunks: Vec::new(),
                dropped: true,
            };
            return;
        }
        self.chunks.extend(display);
    }
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
    /// `terminal` holds a query the host answers: its reply goes to the
    /// program once the host terminal has parsed it.
    pub answered: bool,
}

impl Batch {
    /// Append the batch that follows this one (what `feed_into` does).
    #[cfg(test)]
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
        self.answered |= next.answered;
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

    /// Bytes for the host terminal and every renderer alike.
    fn both(&mut self, bytes: &[u8]) {
        self.terminal.extend_from_slice(bytes);
        self.display.extend_from_slice(bytes);
    }

    /// A complete token, routed.
    fn token(&mut self, token: &[u8]) {
        if token.starts_with(KITTY_NOTIFICATION) {
            self.notifications
                .push((self.terminal.len(), token.to_vec()));
        }
        match route(token) {
            Route::Both => {
                self.terminal.extend_from_slice(token);
                self.display.extend_from_slice(&display_sequence(token));
            }
            Route::Host => {
                self.answered = true;
                self.terminal.extend_from_slice(token);
            }
            Route::Display => self.display.extend_from_slice(token),
            Route::Query => self.query(token),
            Route::Forward => {
                self.terminal.extend_from_slice(token);
                self.query(token);
            }
            Route::Split { display, query } => {
                // Whatever of it the host answers (a colour query, a kitty
                // graphics command's acknowledgement).
                self.answered = true;
                self.terminal.extend_from_slice(token);
                self.display.extend(display);
                self.query(&query);
            }
        }
    }
}
const MAX_CONTROL: usize = 64 * 1024;
/// The longest CSI or OSC sequence the ground state routes without
/// buffering it; a longer one takes the byte-at-a-time path. Far below
/// `MAX_CONTROL`, so the fast path never meets the discard rule.
const MAX_FAST_TOKEN: usize = 4096;
/// OSC 52 clipboard writes carry base64 text and go only to the renderer;
/// they may be much larger than other control strings.
pub const MAX_CLIPBOARD: usize = 8 * 1024 * 1024;
const CLIPBOARD: &[u8] = b"\x1b]52;";
const KITTY_NOTIFICATION: &[u8] = b"\x1b]99;";
const ENQ: u8 = 0x05;
const ESC: u8 = 0x1b;

impl DisplayStream {
    /// The chunks of a kitty graphics transmission that has begun and not
    /// ended, as renderers got them (see `Transfer`); empty when none.
    pub fn unfinished_transfer(&self) -> &[u8] {
        &self.transfer.chunks
    }

    /// How many clipboard writes were dropped for their size since the last
    /// call (the holder logs them).
    pub fn take_dropped_clipboard_writes(&mut self) -> usize {
        std::mem::take(&mut self.dropped_clipboard_writes)
    }

    pub fn feed(&mut self, bytes: &[u8]) -> Batch {
        let mut batch = Batch {
            terminal: Vec::with_capacity(bytes.len()),
            display: Vec::with_capacity(bytes.len()),
            ..Batch::default()
        };
        self.feed_into(bytes, &mut batch);
        batch
    }

    /// Feed `bytes`, which follow what `batch` holds: what `feed` would
    /// return, appended to it (`Batch::append`), without a batch of its own.
    pub fn feed_into(&mut self, bytes: &[u8], batch: &mut Batch) {
        let mut at = 0;
        while at < bytes.len() {
            if self.mode == Mode::Ground {
                at = self.ground(bytes, at, batch);
            } else {
                self.step(&bytes[at..at + 1], batch);
                at += 1;
            }
        }
    }

    /// The ground state, from `start`: text and complete CSI sequences
    /// that every parser gets unchanged (SGR, cursor movement, erasing)
    /// pass through as one run, which ends at the input's end (where a
    /// UTF-8 character it ends inside is held back) or at the first ENQ
    /// or other escape sequence. A complete CSI or OSC sequence there is
    /// routed in place. Returns where `step`, or the next call, goes on.
    fn ground(&mut self, bytes: &[u8], start: usize, batch: &mut Batch) -> usize {
        let mut at = start;
        loop {
            let Some(stop) = memchr::memchr2(ESC, ENQ, &bytes[at..]).map(|stop| at + stop) else {
                let cut = at + self.hold_utf8_tail(&bytes[at..]);
                batch.both(&bytes[start..cut]);
                return bytes.len();
            };
            let csi = complete_csi(&bytes[stop..]);
            if let Some(len) = csi.filter(|&len| unchanged_csi(&bytes[stop..stop + len])) {
                at = stop + len;
                continue;
            }
            // An unfinished character before ESC or ENQ is passed on as
            // it is, as `step` would.
            batch.both(&bytes[start..stop]);
            if bytes[stop] == ENQ {
                batch.control(ENQ);
                return stop + 1;
            }
            if let Some(len) = csi.or_else(|| complete_osc(&bytes[stop..])) {
                batch.token(&bytes[stop..stop + len]);
                return stop + len;
            }
            self.pending.push(ESC);
            self.mode = Mode::Escape;
            return stop + 1;
        }
    }

    /// Keep a UTF-8 character that `run` ends inside for the next read,
    /// as `step` would; returns where it starts (`run.len()` when none).
    fn hold_utf8_tail(&mut self, run: &[u8]) -> usize {
        // Its lead byte is the last non-continuation byte, at most three
        // from the end.
        for back in 1..=run.len().min(3) {
            let at = run.len() - back;
            let needed = match run[at] {
                0x80..=0xbf => continue,
                0xc2..=0xdf => 1,
                0xe0..=0xef => 2,
                0xf0..=0xf4 => 3,
                _ => 0,
            };
            // `back - 1` continuation bytes follow the lead byte.
            if needed >= back {
                self.pending.extend_from_slice(&run[at..]);
                self.mode = Mode::Utf8;
                self.utf8_left = needed - (back - 1);
                return at;
            }
            break;
        }
        run.len()
    }

    /// Byte at a time: whatever the ground state's fast paths leave.
    fn step(&mut self, bytes: &[u8], batch: &mut Batch) {
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
                self.finish(batch);
                self.step(&[b], batch);
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
                self.step(&[b], batch);
                continue;
            }
            if matches!(self.mode, Mode::Escape | Mode::Csi | Mode::String) && b >= 0x7f {
                match b {
                    0x80..=0x9f => {
                        self.eight_bit_control(b, batch);
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
                self.finish(batch);
            } else if self.pending.len() > self.limit() {
                // Oversized control strings cannot grow memory without bound.
                if self.limit() == MAX_CLIPBOARD {
                    self.dropped_clipboard_writes += 1;
                }
                self.pending.clear();
                self.discarding = true;
            }
        }
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
            batch.token(&self.pending);
            self.transfer.observe(&self.pending);
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

/// The length of the CSI sequence `bytes` starts with, when it is complete
/// and has only parameter and intermediate bytes before its final byte:
/// `step` treats those bytes no differently. Anything else (an embedded
/// control, ESC, CAN/SUB, a byte from 0x7f up, or the end of the input) is
/// left to `step`.
fn complete_csi(bytes: &[u8]) -> Option<usize> {
    if bytes.get(1) != Some(&b'[') {
        return None;
    }
    for (at, &b) in bytes.iter().enumerate().take(MAX_FAST_TOKEN).skip(2) {
        match b {
            0x20..=0x3f => {}
            0x40..=0x7e => return Some(at + 1),
            _ => return None,
        }
    }
    None
}

/// The length of the OSC sequence `bytes` starts with, when it is complete,
/// ends in BEL or ST, and holds no ESC, CAN or SUB before its terminator:
/// `step` accumulates every other byte of an OSC string.
fn complete_osc(bytes: &[u8]) -> Option<usize> {
    if bytes.get(1) != Some(&b']') {
        return None;
    }
    let end = bytes.len().min(MAX_FAST_TOKEN);
    let body = bytes.get(2..end)?;
    let at = body
        .iter()
        .position(|&b| matches!(b, 0x07 | 0x1b | 0x18 | 0x1a))?;
    match body[at] {
        0x07 => Some(2 + at + 1),
        0x1b if body.get(at + 1) == Some(&b'\\') => Some(2 + at + 2),
        _ => None,
    }
}

/// Where a complete token goes.
#[derive(Debug, PartialEq, Eq)]
enum Route {
    /// Both the host terminal and the renderers.
    Both,
    /// Only the host, which answers it.
    Host,
    /// Only the renderers (the host neither needs nor answers it).
    Display,
    /// Only the responding renderer: a query the host has no answer for.
    Query,
    /// The host terminal, which does not answer it, and the responding
    /// renderer, which does.
    Forward,
    /// The host gets the token; the renderers get `display` and the
    /// responding renderer `query` instead.
    Split { display: Vec<u8>, query: Vec<u8> },
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

/// Whether a CSI sequence (`body` its bytes between `CSI` and the final
/// byte `last`) may be one the host answers or a query (see `route_csi` and
/// `csi_query`). Most (SGR, cursor movement, erasing) are neither.
fn csi_may_query(last: u8, body: &[u8]) -> bool {
    match last {
        b'c' | b'n' | b'p' | b'q' | b'u' | b't' | b'x' | b'w' | b'y' | b'|' => true,
        b'm' | b'S' => body.first() == Some(&b'?'),
        _ => false,
    }
}

/// Whether a complete CSI sequence goes to the host and, unchanged, to
/// every renderer: routed `Both` and left alone by `display_sequence`.
fn unchanged_csi(token: &[u8]) -> bool {
    let (&last, body) = token[2..].split_last().expect("a complete CSI sequence");
    // `display_sequence` takes the host's modes out of DEC private modes.
    let private_mode = body.first() == Some(&b'?') && matches!(last, b'h' | b'l');
    !(csi_may_query(last, body) || private_mode)
}

fn route_csi(token: &[u8]) -> Route {
    let Some((&last, body)) = token[2..].split_last() else {
        return Route::Both;
    };
    if !csi_may_query(last, body) {
        return Route::Both;
    }
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
        // Status and cursor reports, and the colour-scheme report.
        (b'n', None, b"") => matches!(params, b"5" | b"6"),
        (b'n', Some(b'?'), b"") => params == b"996",
        // DEC private mode reports; ANSI mode requests are not answered.
        (b'p', Some(b'?'), b"$") => true,
        // XTVERSION.
        (b'q', Some(b'>'), b"") => true,
        // Kitty keyboard flags, whatever the parameters.
        (b'u', Some(b'?'), b"") => true,
        // Text area and cell size reports.
        (b't', None, b"") => matches!(params, b"14" | b"16" | b"18"),
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

/// Report requests the host does not answer, which only make the terminal
/// reply.
fn csi_query(last: u8, prefix: Option<u8>, params: &[u8], intermediates: &[u8]) -> bool {
    let first = params.split(|&b| b == b';').next().unwrap_or_default();
    match (last, prefix, intermediates) {
        // Status reports (DSR, DECXCPR and the other DEC reports); `CSI > n`
        // sets key modifier options instead.
        (b'n', None | Some(b'?'), b"") => true,
        // ANSI mode requests (DECRQM without `?`).
        (b'p', None, b"$") => true,
        // Window and title reports (XTWINOPS); not the window operations or
        // the title stack.
        (b't', None, b"") => matches!(
            first,
            b"11" | b"13" | b"14" | b"15" | b"16" | b"18" | b"19" | b"20" | b"21"
        ),
        // Terminal parameters (DECREQTPARM), presentation and terminal state
        // (DECRQPSR, DECRQTSR), the user-preferred supplemental set
        // (DECRQUPSS), rectangle checksums (DECRQCRA) and graphic rendition
        // (XTREPORTSGR).
        (b'x', None, b"")
        | (b'w', None, b"$")
        | (b'u', None, b"$" | b"&")
        | (b'y', None, b"*")
        | (b'|', None, b"#") => true,
        // Key modifier options and graphics attributes (XTQMODKEYS,
        // XTSMGRAPHICS).
        (b'm' | b'S', Some(b'?'), b"") => true,
        _ => false,
    }
}

/// Split an OSC token into its body fields and terminator.
fn osc_parts(token: &[u8]) -> Option<(Vec<&[u8]>, &'static [u8])> {
    let (body, terminator): (&[u8], &'static [u8]) = if token.ends_with(b"\x1b\\") {
        (&token[2..token.len() - 2], b"\x1b\\")
    } else if token.ends_with(b"\x07") {
        (&token[2..token.len() - 1], b"\x07")
    } else {
        return None;
    };
    Some((body.split(|&b| b == b';').collect(), terminator))
}

fn osc(fields: &[&[u8]], terminator: &[u8]) -> Vec<u8> {
    let mut out = b"\x1b]".to_vec();
    for (index, field) in fields.iter().enumerate() {
        if index > 0 {
            out.push(b';');
        }
        out.extend(*field);
    }
    out.extend(terminator);
    out
}

/// The host answers the `answered` parts of a token; the renderers get
/// `display`, the settings among the rest, and the responding renderer
/// `query`, the queries among the rest.
fn split_route(answered: bool, display: Vec<u8>, query: Vec<u8>) -> Route {
    match (answered, display.is_empty(), query.is_empty()) {
        (false, _, true) => Route::Both,
        (false, true, false) => Route::Forward,
        (true, true, true) => Route::Host,
        _ => Route::Split { display, query },
    }
}

/// `code;index;spec;index;spec…` (palette and special colours): the pairs
/// whose spec is `?` are queries, the others settings. Returns the settings
/// and the queries, each as an OSC of its own.
fn indexed_colours(fields: &[&[u8]], terminator: &[u8]) -> (bool, Vec<u8>, Vec<u8>) {
    let mut queried = false;
    let mut sets = vec![fields[0]];
    let mut queries = vec![fields[0]];
    for pair in fields[1..].chunks(2) {
        match pair {
            [_, b"?"] => {
                queried = true;
                queries.extend(pair);
            }
            _ => sets.extend(pair),
        }
    }
    let each = |fields: Vec<&[u8]>| {
        if fields.len() > 1 {
            osc(&fields, terminator)
        } else {
            Vec::new()
        }
    };
    (queried, each(sets), each(queries))
}

fn route_osc(token: &[u8]) -> Route {
    if token.starts_with(CLIPBOARD) {
        // Clipboard reads and writes belong to the renderers; the host has
        // no clipboard. A read (`52;selection;?`) is a query.
        let body = token
            .strip_suffix(b"\x07")
            .or_else(|| token.strip_suffix(b"\x1b\\"))
            .unwrap_or(token);
        return if body.rsplit(|&b| b == b';').next() == Some(b"?") {
            Route::Query
        } else {
            Route::Display
        };
    }
    let Some((fields, terminator)) = osc_parts(token) else {
        return Route::Both;
    };
    match fields[0] {
        // Kitty clipboard: the host always replies (with an error).
        b"5522" => Route::Host,
        // Palette: `4;index;spec;index;spec…`. The host answers queries.
        b"4" => {
            let (answered, sets, _) = indexed_colours(&fields, terminator);
            split_route(answered, sets, Vec::new())
        }
        // Special colours: the host has none to report.
        b"5" => {
            let (_, sets, queries) = indexed_colours(&fields, terminator);
            split_route(false, sets, queries)
        }
        // Dynamic colours: each value applies to the next colour number. The
        // host answers queries for 10–12 only.
        code @ (b"10" | b"11" | b"12" | b"13" | b"14" | b"15" | b"16" | b"17" | b"18" | b"19") => {
            let start: usize = std::str::from_utf8(code)
                .ok()
                .and_then(|code| code.parse().ok())
                .unwrap_or(10);
            let mut answered = false;
            let mut display = Vec::new();
            let mut query = Vec::new();
            for (index, value) in fields[1..].iter().enumerate() {
                let number = start + index;
                let one = osc(&[number.to_string().as_bytes(), value], terminator);
                match (*value == b"?", number) {
                    (true, ..=12) => answered = true,
                    (true, 13..=19) => query.extend(one),
                    _ => display.extend(one),
                }
            }
            split_route(answered, display, query)
        }
        // Kitty colour protocol: `key=?` queries, `key=value` sets, `key`
        // resets. The host answers the queries.
        b"21" => {
            let mut answered = false;
            let mut sets = vec![&b"21"[..]];
            for item in &fields[1..] {
                if item.ends_with(b"=?") {
                    answered = true;
                } else {
                    sets.push(item);
                }
            }
            split_route(
                answered,
                if sets.len() > 1 {
                    osc(&sets, terminator)
                } else {
                    Vec::new()
                },
                Vec::new(),
            )
        }
        // Pointer shapes: `?names` asks which are supported.
        b"22" if fields.get(1).is_some_and(|names| names.starts_with(b"?")) => Route::Forward,
        // Kitty notifications: `p=?` in the metadata asks what is supported.
        b"99"
            if fields.get(1).is_some_and(|metadata| {
                metadata.split(|&b| b == b':').any(|item| item == b"p=?")
            }) =>
        {
            Route::Forward
        }
        _ => Route::Both,
    }
}

/// XTGETTCAP names the host knows go to the host; the responding renderer is
/// asked for the rest.
fn route_xtgettcap(token: &[u8]) -> Route {
    let Some(names) = token
        .strip_prefix(b"\x1bP+q")
        .and_then(|rest| rest.strip_suffix(b"\x1b\\"))
    else {
        return Route::Host;
    };
    let mut answered = false;
    let mut forward = Vec::new();
    for name in names.split(|&b| b == b';') {
        if host_answers_capability(name) {
            answered = true;
        } else {
            if !forward.is_empty() {
                forward.push(b';');
            }
            forward.extend(name);
        }
    }
    let forward = if forward.is_empty() {
        forward
    } else {
        [&b"\x1bP+q"[..], &forward, b"\x1b\\"].concat()
    };
    split_route(answered, Vec::new(), forward)
}

type Capabilities = Option<(Terminal, HashMap<Vec<u8>, bool>)>;
static CAPABILITIES: Mutex<Capabilities> = Mutex::new(None);

/// Whether the host terminal answers an XTGETTCAP name. Capabilities do not
/// depend on terminal state, so a scratch terminal is asked once per name.
fn host_answers_capability(name: &[u8]) -> bool {
    if name.is_empty() || name.len() > 256 {
        return false;
    }
    let mut guard = CAPABILITIES.lock().unwrap_or_else(|e| e.into_inner());
    if guard.is_none() {
        let Ok(terminal) = Terminal::new(10, 2, 1024) else {
            return false;
        };
        *guard = Some((terminal, HashMap::new()));
    }
    let (terminal, known) = guard.as_mut().unwrap();
    if let Some(&answered) = known.get(name) {
        return answered;
    }
    let answered = !terminal
        .feed(&[&b"\x1bP+q"[..], name, b"\x1b\\"].concat())
        .is_empty();
    if known.len() < 4096 {
        known.insert(name.to_vec(), answered);
    }
    answered
}

/// Kitty graphics: the host answers `a=q` probes and acknowledges other
/// commands; the renderer draws images but must stay silent (`q=2`). A
/// renderer never reads a file, a temporary file or shared memory for an
/// image: the holder reads those and passes the command on as a direct
/// transmission (see `media`), so one that names a medium still (one the
/// holder took for no command), however it is written, goes to the host
/// alone, which refuses it. Renderers get a command only as Ghostty reads
/// it, written again (`cherry_vt::kitty::for_renderers`); one Ghostty
/// refuses, and a query, the host alone.
fn route_graphics(token: &[u8]) -> Route {
    let Some(body) = token
        .strip_prefix(b"\x1b_G")
        .and_then(|rest| rest.strip_suffix(b"\x1b\\"))
    else {
        return Route::Both;
    };
    match kitty::for_renderers(body) {
        Some(display) => Route::Split {
            display,
            query: Vec::new(),
        },
        None => Route::Host,
    }
}

/// Modes the host owns because it answers them: in-band resize reports (2048)
/// and the visibility report (2033). Letting the renderer enable them would
/// inject a second report.
const HOST_MODES: [&[u8]; 2] = [b"2048", b"2033"];

fn display_sequence(bytes: &[u8]) -> Cow<'_, [u8]> {
    if bytes.starts_with(b"\x1b[?") && matches!(bytes.last(), Some(b'h' | b'l')) {
        let modes: Vec<_> = bytes[3..bytes.len() - 1]
            .split(|&b| b == b';')
            .filter(|mode| !HOST_MODES.contains(mode))
            .collect();
        if modes.len() != bytes[3..bytes.len() - 1].split(|&b| b == b';').count() {
            if modes.is_empty() {
                return Cow::Borrowed(&[]);
            }
            let mut out = b"\x1b[?".to_vec();
            for (i, mode) in modes.iter().enumerate() {
                if i > 0 {
                    out.push(b';');
                }
                out.extend(*mode);
            }
            out.push(*bytes.last().unwrap());
            return Cow::Owned(out);
        }
    }
    Cow::Borrowed(bytes)
}

#[cfg(test)]
mod reference;

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
    fn large_clipboard_writes_reach_only_the_renderer() {
        let mut stream = DisplayStream::default();
        let payload = vec![b'A'; 6 * 1024 * 1024];
        let sequence = [&b"\x1b]52;c;"[..], &payload, b"\x07"].concat();
        let mut display = Vec::new();
        let mut terminal = Vec::new();
        // Arrives across many PTY reads, like real output.
        for chunk in sequence.chunks(16 * 1024) {
            let batch = stream.feed(chunk);
            display.extend(batch.display);
            terminal.extend(batch.terminal);
        }
        assert_eq!(display, sequence);
        assert!(terminal.is_empty());
        // Beyond the clipboard bound the write is dropped, and the stream
        // recovers at the next terminator.
        assert_eq!(stream.take_dropped_clipboard_writes(), 0);
        stream.feed(b"\x1b]52;c;");
        stream.feed(&vec![b'A'; MAX_CLIPBOARD + 1]);
        assert!(stream.pending.len() <= MAX_CLIPBOARD);
        assert_eq!(stream.feed(b"\x07ok").display, b"ok");
        // Counted once, for the holder's log line.
        assert_eq!(stream.take_dropped_clipboard_writes(), 1);
        assert_eq!(stream.take_dropped_clipboard_writes(), 0);
        // Other control strings keep the small bound.
        stream.feed(b"\x1b]2;");
        stream.feed(&vec![b'x'; MAX_CONTROL + 1]);
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
    fn host_owns_report_modes_without_losing_other_modes() {
        let mut stream = DisplayStream::default();
        let batch = stream.feed(b"\x1b[?2048h\x1b[?2004;2048h\x1b[?2048l\x1b[?2033;1004h");
        assert_eq!(batch.display, b"\x1b[?2004h\x1b[?1004h");
        assert_eq!(
            batch.terminal,
            b"\x1b[?2048h\x1b[?2004;2048h\x1b[?2048l\x1b[?2033;1004h"
        );
    }

    fn split(token: &[u8]) -> Batch {
        let mut stream = DisplayStream::default();
        let mut batch = Batch::default();
        for byte in token {
            batch.append(stream.feed(&[*byte]));
        }
        batch
    }

    /// Every query, back to back.
    fn queries(batch: &Batch) -> Vec<u8> {
        batch
            .queries
            .iter()
            .flat_map(|(_, query)| query.iter().copied())
            .collect()
    }

    /// What a session's terminal, which keeps kitty images, answers.
    fn host_replies(bytes: &[u8]) -> Vec<u8> {
        let mut terminal = cherry_vt::Terminal::new(80, 24, 4096).unwrap();
        terminal
            .set_image_storage_limit(crate::holder::IMAGE_STORAGE_BYTES)
            .unwrap();
        terminal.feed(bytes)
    }

    /// Every query has exactly one responder: either the host answers it
    /// and no renderer sees it, or the host is silent and it goes only to
    /// the responding renderer, never into the stream every renderer gets.
    /// Host replies come from the real library, so a library change that
    /// adds or drops an answer fails here.
    #[test]
    fn query_corpus_has_one_responder_across_fragmented_reads() {
        let corpus: &[(&str, &[u8])] = &[
            ("status", b"\x1b[5n"),
            ("cursor", b"\x1b[6n"),
            ("DEC cursor", b"\x1b[?6n"),
            ("printer status", b"\x1b[?15n"),
            ("locator status", b"\x1b[?53n"),
            ("primary attributes", b"\x1b[c"),
            ("primary attributes 0", b"\x1b[0c"),
            ("secondary attributes", b"\x1b[>c"),
            ("tertiary attributes", b"\x1b[=c"),
            ("DECID", b"\x1bZ"),
            ("private mode", b"\x1b[?1$p"),
            ("ANSI mode", b"\x1b[4$p"),
            ("kitty keyboard", b"\x1b[?u"),
            ("kitty keyboard with a parameter", b"\x1b[?1u"),
            ("version", b"\x1b[>q"),
            ("cell size", b"\x1b[18t"),
            ("pixel area", b"\x1b[14t"),
            ("pixel cell", b"\x1b[16t"),
            ("window state", b"\x1b[11t"),
            ("window position", b"\x1b[13t"),
            ("screen size", b"\x1b[19t"),
            ("icon title", b"\x1b[20t"),
            ("window title", b"\x1b[21t"),
            ("pixel area of screen", b"\x1b[14;2t"),
            ("terminal parameters", b"\x1b[x"),
            ("presentation state", b"\x1b[1$w"),
            ("terminal state", b"\x1b[1$u"),
            ("supplemental set", b"\x1b[&u"),
            ("rectangle checksum", b"\x1b[1;1;1;1;2;2*y"),
            ("graphic rendition", b"\x1b[1;1;2;2#|"),
            ("key modifier options", b"\x1b[?4m"),
            ("graphics attributes", b"\x1b[?1;1;0S"),
            ("color scheme", b"\x1b[?996n"),
            ("answerback", b"\x05"),
            ("palette", b"\x1b]4;1;?\x07"),
            ("special colour", b"\x1b]5;0;?\x07"),
            ("foreground", b"\x1b]10;?\x07"),
            ("background", b"\x1b]11;?\x1b\\"),
            ("cursor color", b"\x1b]12;?\x07"),
            ("pointer foreground", b"\x1b]13;?\x07"),
            ("highlight background", b"\x1b]17;?\x07"),
            ("highlight foreground", b"\x1b]19;?\x07"),
            ("clipboard read", b"\x1b]52;c;?\x07"),
            ("pointer shapes", b"\x1b]22;?default,text\x1b\\"),
            ("notification support", b"\x1b]99;i=1:p=?;\x1b\\"),
            ("kitty colors", b"\x1b]21;foreground=?\x1b\\"),
            ("kitty clipboard read", b"\x1b]5522;type=read\x1b\\"),
            ("kitty clipboard write", b"\x1b]5522;type=write\x1b\\"),
            ("SGR state", b"\x1bP$qm\x1b\\"),
            ("invalid DECRQSS", b"\x1bP$qz\x1b\\"),
            ("termcap known", b"\x1bP+q4d73\x1b\\"),
            ("termcap terminal name", b"\x1bP+q544e\x1b\\"),
            (
                "kitty graphics probe",
                b"\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\",
            ),
        ];
        for &(label, query) in corpus {
            let batch = split(query);
            assert!(
                batch.terminal.is_empty() || batch.terminal == query,
                "{label}: host must see the query unchanged or not at all"
            );
            assert!(
                batch.display.is_empty(),
                "{label}: the renderers' stream holds {:?}",
                String::from_utf8_lossy(&batch.display)
            );
            let host_answered = !host_replies(&batch.terminal).is_empty();
            let forwarded = queries(&batch) == query;
            assert!(
                host_answered != forwarded,
                "{label}: host answered={host_answered}, forwarded={forwarded}"
            );
        }
    }

    #[test]
    fn settings_still_reach_every_renderer() {
        for setting in [
            &b"\x1b[>4n"[..],
            b"\x1b[>4;2m",
            b"\x1b[22;0t",
            b"\x1b[8;24;80t",
            b"\x1b[1$}",
            b"\x1b]5;0;red\x07",
            b"\x1b]13;red\x07",
            b"\x1b]22;text\x1b\\",
            b"\x1b]99;i=1:d=0;Done\x1b\\",
            b"\x1b]52;c;aGk=\x07",
            b"\x07",
        ] {
            let batch = split(setting);
            assert_eq!(batch.display, setting, "{setting:?}");
            assert!(batch.queries.is_empty(), "{setting:?}");
        }
    }

    #[test]
    fn mixed_queries_split_between_host_renderers_and_responder() {
        // The host answers its queries; the settings they were combined
        // with reach every renderer and the other queries the responder, in
        // the original terminator.
        let cases: &[(&[u8], &[u8], &[u8])] = &[
            (b"\x1b]4;1;?;2;red\x07", b"\x1b]4;2;red\x07", b""),
            (b"\x1b]10;red;?\x07", b"\x1b]10;red\x07", b""),
            (b"\x1b]10;?;?;?;?\x1b\\", b"", b"\x1b]13;?\x1b\\"),
            (
                b"\x1b]11;?;blue;?\x07",
                b"\x1b]12;blue\x07",
                b"\x1b]13;?\x07",
            ),
            (
                b"\x1b]21;foreground=?;background=blue;cursor\x1b\\",
                b"\x1b]21;background=blue;cursor\x1b\\",
                b"",
            ),
            (b"\x1bP+q4d73;544e\x1b\\", b"", b"\x1bP+q544e\x1b\\"),
        ];
        for &(token, display, query) in cases {
            let batch = split(token);
            let label = String::from_utf8_lossy(token);
            assert_eq!(batch.terminal, token, "{label}");
            assert_eq!(batch.display, display, "{label}");
            assert_eq!(queries(&batch), query, "{label}");
            assert!(!host_replies(token).is_empty());
            assert!(host_replies(display).is_empty());
            assert!(host_replies(query).is_empty());
        }
        // Queries the host does not answer, with settings and no host part.
        for (token, display, query) in [
            (
                &b"\x1b]13;red;?\x07"[..],
                &b"\x1b]13;red\x07"[..],
                &b"\x1b]14;?\x07"[..],
            ),
            (
                b"\x1b]5;0;?;1;blue\x07",
                b"\x1b]5;1;blue\x07",
                b"\x1b]5;0;?\x07",
            ),
        ] {
            let batch = split(token);
            assert_eq!(batch.terminal, token);
            assert_eq!(batch.display, display);
            assert_eq!(queries(&batch), query);
        }
    }

    #[test]
    fn queries_keep_their_place_in_the_stream() {
        let mut stream = DisplayStream::default();
        let mut batch = stream.feed(b"ab\x1b[?6n\x1b]13;?\x07cd\x1b[?");
        assert_eq!(batch.display, b"abcd");
        // Adjacent queries travel together.
        assert_eq!(batch.queries, [(2, b"\x1b[?6n\x1b]13;?\x07".to_vec())]);
        // A query completed by a later read, and one interrupting UTF-8.
        batch.append(stream.feed(b"15nef\xe2\x05\x82\xac"));
        assert_eq!(batch.display, b"abcdef\xe2\x82\xac");
        assert_eq!(
            batch.queries,
            [
                (2, b"\x1b[?6n\x1b]13;?\x07".to_vec()),
                (4, b"\x1b[?15n".to_vec()),
                (7, b"\x05".to_vec()),
            ]
        );
        // ENQ inside a CSI sequence is a query as well; other C0 controls
        // stay in the stream.
        let batch = DisplayStream::default().feed(b"\x1b[1\x05\x07m");
        assert_eq!(batch.display, b"\x07\x1b[1m");
        assert_eq!(batch.queries, [(0, b"\x05".to_vec())]);
    }

    /// Everything a batch holds, for comparisons.
    type Parts = (
        Vec<u8>,
        Vec<u8>,
        Vec<(usize, Vec<u8>)>,
        Vec<(usize, Vec<u8>)>,
    );
    fn parts(batch: Batch) -> Parts {
        (
            batch.terminal,
            batch.display,
            batch.queries,
            batch.notifications,
        )
    }

    /// The fast paths (whole runs of text and plain CSI sequences, complete
    /// CSI and OSC sequences) agree with the byte-at-a-time state machine,
    /// wherever reads split the output: a byte at a time never completes a
    /// sequence on a fast path.
    #[test]
    fn read_boundaries_do_not_change_the_split() {
        let long_csi = [&b"\x1b["[..], &vec![b';'; MAX_FAST_TOKEN + 10], b"m"].concat();
        let long_osc = [&b"\x1b]2;"[..], &vec![b'x'; MAX_FAST_TOKEN + 10], b"\x07"].concat();
        let pieces: &[&[u8]] = &[
            b"plain text\r\n",
            "h\u{e9}llo \u{65e5}\u{672c} \u{1f389}\r\n".as_bytes(),
            b"\x1b[1;31mred\x1b[0m \x1b[38;5;208m\x1b[48;2;1;2;3m",
            b"\x1b[H\x1b[2J\x1b[12;40H\x1b[K\x1b[?25l\x1b[?25h",
            b"\x1b[?2004;2048h\x1b[?2033l",
            b"\x1b[6n\x1b[c\x1b[?6n\x1b[18t\x1b[?4m",
            b"\x1b]0;title \xe2\x9c\x93\x07\x1b]8;;file:///x\x1b\\link\x1b]8;;\x1b\\",
            b"\x1b]99;i=1:d=0;Done\x1b\\\x1b]99;i=1:p=?;\x1b\\",
            b"\x1b]11;?\x1b\\\x1b]10;red;?\x07\x1b]13;?\x07\x1b]52;c;aGk=\x07\x1b]52;c;?\x07",
            b"\x05",
            b"\xe2\x82",
            b"\xf0\x9f",
            b"\xc3\x1b[m\xe2\x05\x82",
            b"\x1b[12;\x1b[5n\x1b[1\x07m\x1b[1\x18\x1b[\x7f1m\x1b[1\xc3m",
            b"\x1b]2;x\x18\x1b]2;y\x1bZ\x1b]2;z\x1a",
            b"\x1bP$qm\x1b\\\x1bP+q544e;4d73\x1b\\\x1b_Ga=t,q=0;AAAA\x1b\\",
            b"\x1b(B\x1b7\x1b8\x1b=\x1b>\x1bZ\x1b",
            b"\x80\xbf\xc0\xf5\xff\x07\x08\t",
            &long_csi,
            &long_osc,
        ];
        let mut seed = 7u32;
        let mut next = |bound: usize| {
            seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12_345);
            (seed >> 8) as usize % bound
        };
        let mut output = Vec::new();
        for _ in 0..3000 {
            output.extend_from_slice(pieces[next(pieces.len())]);
        }
        let reference = parts(split(&output));
        let whole = parts(DisplayStream::default().feed(&output));
        assert!(whole == reference, "one read");
        for most in [2, 7, 64, 1024] {
            let mut stream = DisplayStream::default();
            let mut batch = Batch::default();
            let mut at = 0;
            while at < output.len() {
                let end = (at + 1 + next(most)).min(output.len());
                batch.append(stream.feed(&output[at..end]));
                at = end;
            }
            assert!(parts(batch) == reference, "reads of up to {most} bytes");
        }
        // A read that ends inside a character keeps it for the next.
        for character in ["\u{e9}", "\u{65e5}", "\u{1f389}"] {
            let character = character.as_bytes();
            for cut in 1..character.len() {
                let mut stream = DisplayStream::default();
                let first = stream.feed(&[b"ab", &character[..cut]].concat());
                assert_eq!(
                    (first.terminal, first.display),
                    (b"ab".to_vec(), b"ab".to_vec())
                );
                let rest = stream.feed(&[&character[cut..], b"z\x1b[m"].concat());
                let whole = [character, b"z\x1b[m"].concat();
                assert_eq!((rest.terminal, rest.display), (whole.clone(), whole));
            }
        }
    }

    /// A xorshift generator for the differential tests.
    struct Rng(u64);

    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            self.0
        }
        fn below(&mut self, n: usize) -> usize {
            (self.next() % n as u64) as usize
        }
        fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
            &items[self.below(items.len())]
        }
        fn chance(&mut self, percent: usize) -> bool {
            self.below(100) < percent
        }
        fn bytes(&mut self, items: &[&'static [u8]]) -> &'static [u8] {
            items[self.below(items.len())]
        }
    }

    fn parameters(r: &mut Rng, out: &mut Vec<u8>) {
        for i in 0..r.below(5) {
            if i > 0 {
                out.push(if r.chance(90) { b';' } else { b':' });
            }
            let parameter = r.bytes(&[
                &b"0"[..],
                b"1",
                b"2",
                b"5",
                b"6",
                b"11",
                b"13",
                b"14",
                b"15",
                b"16",
                b"18",
                b"19",
                b"20",
                b"21",
                b"38",
                b"48",
                b"996",
                b"2004",
                b"2048",
                b"2033",
                b"1049",
                b"1004",
                b"4",
                b"255",
                b"12345",
            ]);
            out.extend_from_slice(parameter);
        }
    }

    fn csi(r: &mut Rng, out: &mut Vec<u8>) {
        out.extend_from_slice(b"\x1b[");
        if r.chance(30) {
            out.push(*r.pick(b"?<=>"));
        }
        parameters(r, out);
        if r.chance(15) {
            out.push(*r.pick(b" !\"#$%&'()*+,-./"));
        }
        if r.chance(3) {
            // Odd bytes inside a CSI sequence.
            out.push(*r.pick(&[0x07u8, 0x05, 0x18, 0x1a, 0x1b, 0x7f, 0x80, 0xc3, 0x0a, 0x0d]));
            if r.chance(50) {
                parameters(r, out);
            }
        }
        if r.chance(1) {
            out.resize(out.len() + r.below(70_000), b'1');
        }
        if r.chance(1) {
            out.resize(out.len() + MAX_FAST_TOKEN - 6 + r.below(12), b';');
        }
        if r.chance(95) {
            out.push(*r.pick(b"mmmmmmmmcnpqutxwyS|hlHJKABCDGfrsr@`~"));
        }
    }

    fn osc(r: &mut Rng, out: &mut Vec<u8>) {
        out.extend_from_slice(b"\x1b]");
        let code = r.bytes(&[
            &b"0"[..],
            b"2",
            b"4",
            b"5",
            b"8",
            b"10",
            b"11",
            b"12",
            b"13",
            b"17",
            b"19",
            b"21",
            b"22",
            b"52",
            b"99",
            b"133",
            b"5522",
            b"7",
            b"",
        ]);
        out.extend_from_slice(code);
        for _ in 0..r.below(4) {
            out.push(b';');
            out.extend_from_slice(match r.below(8) {
                0 => &b"?"[..],
                1 => b"1;?",
                2 => b"rgb:00/11/22",
                3 => b"i=1:p=?",
                4 => b"foreground=?",
                5 => "t\u{ef}tle \u{2713} \u{65e5}\u{672c}".as_bytes(),
                6 => b"c;aGVsbG8=",
                _ => b"file:///tmp/x",
            });
        }
        if r.chance(3) {
            out.push(*r.pick(&[0x05u8, 0x0a, 0x7f, 0x9c, 0x00, 0x1b]));
        }
        if r.chance(1) {
            out.resize(out.len() + MAX_FAST_TOKEN - 16 + r.below(30), b'x');
        }
        if r.chance(1) {
            out.resize(out.len() + MAX_CONTROL - 6 + r.below(20), b'y');
        }
        match r.below(10) {
            0..=4 => out.push(0x07),
            5..=7 => out.extend_from_slice(b"\x1b\\"),
            8 => out.push(*r.pick(&[0x18u8, 0x1a, 0x1b])),
            _ => {}
        }
    }

    fn string(r: &mut Rng, out: &mut Vec<u8>) {
        match r.below(5) {
            0 => out.extend_from_slice(b"\x1bP$qm"),
            1 => out.extend_from_slice(b"\x1bP+q544e;4d73;6b31"),
            2 => out.extend_from_slice(b"\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA"),
            3 => out.extend_from_slice(b"\x1b_Ga=t,q=0;AAAA"),
            _ => {
                out.push(0x1b);
                out.push(*r.pick(b"P_^X"));
                out.extend_from_slice(b"junk\x07more");
            }
        }
        match r.below(4) {
            0..=2 => out.extend_from_slice(b"\x1b\\"),
            _ => out.push(*r.pick(&[0x18u8, 0x1b, 0x07])),
        }
    }

    fn text(r: &mut Rng, out: &mut Vec<u8>) {
        for _ in 0..r.below(200) {
            match r.below(40) {
                0 => out.extend_from_slice("\u{e9}".as_bytes()),
                1 => out.extend_from_slice("\u{65e5}\u{672c}".as_bytes()),
                2 => out.extend_from_slice("\u{1f389}".as_bytes()),
                // Stray and cut characters.
                3 => out.push(*r.pick(&[
                    0xc2u8, 0xe2, 0xf0, 0xf4, 0xe0, 0xc0, 0xc1, 0xf5, 0xff, 0x80, 0xbf,
                ])),
                4 => out
                    .push(*r.pick(&[0x07u8, 0x05, 0x18, 0x1a, 0x0a, 0x0d, 0x08, 0x09, 0x00, 0x7f])),
                5 => {
                    let rocket = "\u{1f680}".as_bytes();
                    out.extend_from_slice(&rocket[..1 + r.below(3)]);
                }
                _ => out.push(b'a' + r.below(26) as u8),
            }
        }
    }

    fn output(r: &mut Rng) -> Vec<u8> {
        let mut out = Vec::new();
        for _ in 0..1 + r.below(60) {
            match r.below(12) {
                0..=3 => text(r, &mut out),
                4..=6 => csi(r, &mut out),
                7..=8 => osc(r, &mut out),
                9 => string(r, &mut out),
                10 => {
                    out.push(0x1b);
                    out.push(*r.pick(b"Z78=>c()#% \x1b\x18[]\\M"));
                    if r.chance(50) {
                        out.push(*r.pick(b"B0A5@G"));
                    }
                }
                _ => out.push(0x1b),
            }
        }
        out
    }

    /// Everything a batch holds, the reference's or the fast one's.
    type Split = (
        Vec<u8>,
        Vec<u8>,
        Vec<(usize, Vec<u8>)>,
        Vec<(usize, Vec<u8>)>,
    );

    fn fast(batch: Batch) -> Split {
        (
            batch.terminal,
            batch.display,
            batch.queries,
            batch.notifications,
        )
    }

    fn slow(batch: reference::Batch) -> Split {
        (
            batch.terminal,
            batch.display,
            batch.queries,
            batch.notifications,
        )
    }

    /// The fast paths against the byte-at-a-time state machine they
    /// replaced (`reference`, which is HEAD's stream.rs of before them):
    /// random output of every kind, read in random pieces, then flushed
    /// with terminators, must split the same, read by read.
    #[test]
    fn the_fast_paths_split_output_as_the_reference_does() {
        for seed in [1u64, 31, 97, 4242] {
            let mut r = Rng(seed.wrapping_mul(0x9e37_79b9_7f4a_7c15) | 1);
            for input in 0..1000 {
                let bytes = output(&mut r);
                let mut ours = DisplayStream::default();
                let mut theirs = reference::DisplayStream::default();
                // The same, gathered read after read as the holder does.
                let mut gathering = DisplayStream::default();
                let (mut gathered, mut appended) = (Batch::default(), reference::Batch::default());
                let mode = r.below(4);
                let mut at = 0;
                while at < bytes.len() {
                    let len = match mode {
                        0 => bytes.len() - at,
                        1 => 1,
                        2 => 1 + r.below(8),
                        _ => 1 + r.below(2048),
                    }
                    .min(bytes.len() - at);
                    let piece = &bytes[at..at + len];
                    let (b, a) = (theirs.feed(piece), ours.feed(piece));
                    appended.append(reference::Batch {
                        terminal: b.terminal.clone(),
                        display: b.display.clone(),
                        queries: b.queries.clone(),
                        notifications: b.notifications.clone(),
                    });
                    let (a, b) = (fast(a), slow(b));
                    assert!(
                        a == b,
                        "seed {seed} input {input}, read at {at} of {len}: {:?}",
                        String::from_utf8_lossy(&bytes)
                    );
                    gathering.feed_into(piece, &mut gathered);
                    at += len;
                }
                assert!(
                    fast(gathered) == slow(appended),
                    "seed {seed} input {input}"
                );
                // Whatever is left pending ends the same way.
                for tail in [&b"\x07"[..], b"\x1b\\", b"\x18", b"ok\xe2", b"\x82\xac"] {
                    assert!(fast(ours.feed(tail)) == slow(theirs.feed(tail)));
                }
            }
        }
    }

    /// Snapshots go through a fresh display stream in one piece (see
    /// `holder::Holder::snapshot`): those of a terminal fed random output
    /// split as before too.
    #[test]
    fn snapshots_split_as_the_reference_does() {
        let mut r = Rng(99);
        for _ in 0..150 {
            let mut terminal = Terminal::new(80, 24, 64 * 1024).unwrap();
            let _ = terminal.feed(&output(&mut r));
            let _ = terminal.feed(b"\x1b\\\x18");
            for raw in [
                terminal.snapshot().unwrap(),
                terminal.refresh().unwrap(),
                terminal.viewport(40, 10).unwrap(),
                terminal.modes().unwrap(),
            ] {
                assert!(
                    fast(DisplayStream::default().feed(&raw))
                        == slow(reference::DisplayStream::default().feed(&raw))
                );
            }
        }
    }

    #[test]
    fn queries_the_host_answers_are_marked() {
        for (bytes, answered) in [
            (&b"text \x1b[1;31mred\x1b[0m\r\n"[..], false),
            (b"\x1b[c", true),
            (b"ab\x1b[6ncd", true),
            (b"\x1b]11;?\x07", true),
            (b"\x1b_Ga=t,q=0;AAAA\x1b\\", true),
            // Only a client answers these.
            (b"\x1b[?6n\x1b]13;?\x07\x05", false),
            (b"\x1b]2;title\x07\x1b[?1049h", false),
        ] {
            assert_eq!(
                DisplayStream::default().feed(bytes).answered,
                answered,
                "{bytes:?}"
            );
            // Byte after byte too.
            assert_eq!(split(bytes).answered, answered, "{bytes:?}");
        }
    }

    #[test]
    fn an_unfinished_chunked_transmission_is_kept_until_it_ends() {
        let mut stream = DisplayStream::default();
        stream.feed(b"\x1b_Ga=T,f=100,i=3,m=1;AAAA\x1b\\text");
        assert_eq!(
            stream.unfinished_transfer(),
            b"\x1b_Ga=T,f=100,i=3,m=1,q=2;AAAA\x1b\\"
        );
        // A probe, a placement or another command in between leaves it
        // alone.
        stream.feed(b"\x1b_Ga=q,i=1,s=1,v=1;AAAA\x1b\\\x1b[H\x1b_Ga=p,U=1,i=3\x1b\\");
        stream.feed(b"\x1b_Gm=1;BBBB\x1b");
        stream.feed(b"\\");
        assert_eq!(
            stream.unfinished_transfer(),
            b"\x1b_Ga=T,f=100,i=3,m=1,q=2;AAAA\x1b\\\x1b_Gm=1,q=2;BBBB\x1b\\"
        );
        // Its last chunk ends it.
        stream.feed(b"\x1b_Gm=0;CCCC\x1b\\");
        assert!(stream.unfinished_transfer().is_empty());
        // Continuation chunks without a beginning are not kept.
        stream.feed(b"\x1b_Gm=1;DDDD\x1b\\");
        assert!(stream.unfinished_transfer().is_empty());
        // A new transmission replaces one, and a reset or a deletion
        // abandons it.
        stream.feed(b"\x1b_Ga=t,i=4,m=1;AAAA\x1b\\\x1b_Ga=t,i=5,m=1;BBBB\x1b\\");
        assert_eq!(
            stream.unfinished_transfer(),
            b"\x1b_Ga=t,i=5,m=1,q=2;BBBB\x1b\\"
        );
        stream.feed(b"\x1bc");
        assert!(stream.unfinished_transfer().is_empty());
        stream.feed(b"\x1b_Ga=t,i=4,m=1;AAAA\x1b\\\x1b_Ga=d,d=i,i=9\x1b\\");
        assert!(stream.unfinished_transfer().is_empty());
        // One too large for a snapshot is dropped, with the rest of it.
        let chunk = [&b"\x1b_Gm=1;"[..], &[b'A'; 4096], b"\x1b\\"].concat();
        stream.feed(b"\x1b_Ga=t,i=6,m=1;AAAA\x1b\\");
        for _ in 0..(cherry_protocol::MAX_SNAPSHOT_GRAPHICS_BYTES / 4096 + 1) {
            stream.feed(&chunk);
        }
        assert!(stream.unfinished_transfer().is_empty());
        stream.feed(&chunk);
        assert!(stream.unfinished_transfer().is_empty());
        stream.feed(b"\x1b_Gm=0;AAAA\x1b\\\x1b_Ga=t,i=7,m=1;AAAA\x1b\\");
        assert_eq!(
            stream.unfinished_transfer(),
            b"\x1b_Ga=t,i=7,m=1,q=2;AAAA\x1b\\"
        );
    }

    #[test]
    fn kitty_graphics_reach_the_renderer_silenced() {
        let transmit = b"\x1b_Gi=32,s=1,v=1,a=t,t=d,f=24,q=0;AAAA\x1b\\";
        let batch = split(transmit);
        assert_eq!(batch.terminal, transmit);
        assert_eq!(
            batch.display,
            b"\x1b_Gi=32,s=1,v=1,a=t,t=d,f=24,q=2;AAAA\x1b\\"
        );
        assert!(!host_replies(&batch.terminal).is_empty());
        assert!(host_replies(&batch.display).is_empty());
        let chunk = split(b"\x1b_Gm=0;\x1b\\");
        assert_eq!(chunk.display, b"\x1b_Gm=0,q=2;\x1b\\");
        assert_eq!(split(b"\x1b_G;AAAA\x1b\\").display, b"\x1b_Gq=2;AAAA\x1b\\");
        // One Ghostty refuses (here, without control data or payload) is
        // the host's alone.
        assert!(split(b"\x1b_G\x1b\\").display.is_empty());
    }

    #[test]
    fn a_command_that_names_a_file_never_reaches_a_renderer() {
        // The holder reads files and shared memory (see `media`); one it did
        // not take for a command goes to the host alone, which refuses it.
        for command in [
            &b"\x1b_Ga=T,t=f,i=1;L3RtcC94\x1b\\"[..],
            b"\x1b_Gt=t,i=1;L3RtcC94\x1b\\",
            b"\x1b_Ga=f,t=s,i=1;L3g=\x1b\\",
        ] {
            let batch = split(command);
            assert_eq!(batch.terminal, command);
            assert!(batch.display.is_empty(), "{command:?}");
            assert!(batch.answered);
        }
        // Nor does a medium on a command that carries no data (Ghostty
        // reads none for it, but another terminal might).
        let place = split(b"\x1b_Ga=p,t=f,i=1\x1b\\");
        assert!(place.display.is_empty());
    }

    /// Ghostty reads `t=102` as `t=f` and `a=84` as `a=T` (see
    /// `cherry_vt::kitty`): renderers get a command only as Ghostty reads
    /// it, and never one that names a medium, however it is written.
    #[test]
    fn renderers_get_graphics_only_as_ghostty_reads_them() {
        for command in [
            &b"\x1b_Ga=T,t=102,i=1;L3RtcC94\x1b\\"[..],
            b"\x1b_Ga=T,t=0102,i=1;L3RtcC94\x1b\\",
            b"\x1b_Ga=T,t=+102,i=1;L3RtcC94\x1b\\",
            b"\x1b_Ga=T,t=1_02,i=1;L3RtcC94\x1b\\",
            b"\x1b_Gt=116,i=1;L3RtcC94\x1b\\",
            b"\x1b_Ga=84,t=115,i=1;L3g=\x1b\\",
            b"\x1b_Ga=+116,t=f,i=1;L3RtcC94\x1b\\",
            b"\x1b_Ga=T,t=f,aaaaaaaaaaaaa;x=1;L3RtcC94\x1b\\",
            // A medium as another terminal might read it.
            b"\x1b_Ga=T,T=f,i=1;L3RtcC94\x1b\\",
            b"\x1b_Ga=T, t=f ,i=1;L3RtcC94\x1b\\",
            // A medium on any action, a query, a compression or format
            // Ghostty does not know, and a command it refuses: the host's
            // alone.
            b"\x1b_Ga=p,t=f,i=1\x1b\\",
            b"\x1b_Ga=113,i=1,s=1,v=1,f=24;AAAA\x1b\\",
            b"\x1b_Ga=T,o=x,i=1;AAAA\x1b\\",
            b"\x1b_Ga=T,f=7,i=1;AAAA\x1b\\",
            b"\x1b_Ga=T,i=1,x=junk;AAAA\x1b\\",
            b"\x1b_G\x1b\\",
        ] {
            let batch = split(command);
            assert_eq!(batch.terminal, command);
            assert!(
                batch.display.is_empty(),
                "{:?}: {:?}",
                String::from_utf8_lossy(command),
                String::from_utf8_lossy(&batch.display)
            );
        }
        // The keys as Ghostty reads them, with `q=2`; and only those.
        assert_eq!(
            split(b"\x1b_Ga=84,i=+05,f=100,q=0,t=100,!=3;AAAA\x1b\\").display,
            b"\x1b_Ga=T,i=5,f=100,t=d,q=2;AAAA\x1b\\"
        );
        // What Ghostty ignores is not passed on (and a `t` among it, which
        // another terminal might read, keeps the command from renderers).
        assert_eq!(
            split(b"\x1b_Ga=t,i=5,hello=world,x=7;AAAA\x1b\\").display,
            b"\x1b_Ga=t,i=5,q=2;AAAA\x1b\\"
        );
        assert!(split(b"\x1b_Ga=t,i=5,hello=world,t=f;AAAA\x1b\\")
            .display
            .is_empty());
    }

    /// Kitty graphics commands that Ghostty reads as such, but a 7-bit
    /// tokenizer would not: begun or ended by 8-bit C1 controls (APC 0x9f,
    /// ST 0x9c) in an escape, control or device control sequence, or behind
    /// bytes Ghostty ignores there (DEL, 0xa0 to 0xff). Each asks (`a=q`)
    /// for a file, so a terminal that executes it answers.
    const SMUGGLED: &[&[u8]] = &[
        b"\x1b[\x9fGa=q,i=1,s=1,v=1,f=24,t=f;L2V0Yw==\x9c",
        b"\x1b[?\x9fGa=q,i=1,s=1,v=1,f=24,t=f;L2V0Yw==\x9c",
        b"\x1b(\x9fGa=q,i=1,s=1,v=1,f=24,t=f;L2V0Yw==\x9c",
        b"\x1b\x9fGa=q,i=1,s=1,v=1,f=24,t=f;L2V0Yw==\x9c",
        b"\x1bP1;2\x9fGa=q,i=1,s=1,v=1,f=24,t=f;L2V0Yw==\x9c",
        b"\x1b\xa0_Ga=q,i=1,s=1,v=1,f=24,t=f;L2V0Yw==\x1b\\",
        b"\x1b\x7f_Ga=q,i=1,s=1,v=1,f=24,t=f;L2V0Yw==\x1b\\",
        b"\x1b\xff\x7f\xc3_Ga=q,i=1,s=1,v=1,f=24,t=f;L2V0Yw==\x1b\\",
        b"\x1b_\xa0Ga=q,i=1,s=1,v=1,f=24,t=f;L2V0Yw==\x1b\\",
        b"\x1b_Ga=q,i=1,s=1,v=1,f=24,t=\xc3f;L2V0Yw==\x1b\\",
        b"\x1b_Ga=p,i=1;\x9c\x1b[\x9fGa=q,i=1,s=1,v=1,f=24,t=f;L2V0Yw==\x9c\x1b\\",
        b"\x1b_Ga=q,i=1,s=1,v=1,f=24,t=102;L2V0Yw==\x9cmore\x1b\\",
    ];

    /// What libghostty-vt, a renderer that reads no file, answers `bytes`.
    fn renderer_replies(bytes: &[u8]) -> Vec<u8> {
        host_replies(bytes)
    }

    #[test]
    fn graphics_in_8_bit_controls_never_reach_a_renderer() {
        for &command in SMUGGLED {
            let text = String::from_utf8_lossy(command).into_owned();
            // As one read, and byte after byte.
            for batch in [DisplayStream::default().feed(command), split(command)] {
                assert!(
                    renderer_replies(&batch.display).is_empty(),
                    "{text:?}: {:?}",
                    String::from_utf8_lossy(&batch.display)
                );
            }
        }
    }

    /// Random output made of the pieces that begin, fill and end kitty
    /// graphics commands in every way Ghostty reads them (7-bit and 8-bit
    /// introducers and terminators, bytes it ignores, keys in letters and
    /// numbers): libghostty-vt, reading what renderers get, never answers,
    /// so no command reaches them that the host did not silence, and none
    /// names a medium.
    fn smuggling_output(next: &mut impl FnMut(usize) -> usize) -> Vec<u8> {
        const BEFORE: &[&[u8]] = &[
            b"",
            b"text",
            b"\x1b[",
            b"\x1b[?",
            b"\x1b[1;",
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
            b"\x1b\x9e",
        ];
        const KEYS: &[&[u8]] = &[
            b"a=q", b"a=113", b"a=+113", b"a=T", b"a=84", b"a=t", b"i=1", b"i=+1", b"s=1", b"v=1",
            b"f=24", b"t=f", b"t=102", b"t=0102", b"t=1_02", b"t=\xc3f", b"t=d", b"t=115", b"q=0",
            b"x=1", b"\xa0", b"T=f", b" t=f", b"m=1",
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
        let mut out = Vec::new();
        for _ in 0..1 + next(4) {
            out.extend_from_slice(BEFORE[next(BEFORE.len())]);
            out.extend_from_slice(OPEN[next(OPEN.len())]);
            if next(4) != 0 {
                out.push(b'G');
            }
            // A query, which renderers never get, and pixels for it.
            out.extend_from_slice(b"a=q,i=1,s=1,v=1,f=24");
            for _ in 0..next(4) {
                out.push(b',');
                out.extend_from_slice(KEYS[next(KEYS.len())]);
            }
            out.extend_from_slice(PAYLOAD[next(PAYLOAD.len())]);
            out.extend_from_slice(CLOSE[next(CLOSE.len())]);
        }
        out
    }

    #[test]
    fn no_renderer_ever_answers_a_kitty_command() {
        let mut state = 0x2545_f491_u32;
        let mut next = |n: usize| {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            state as usize % n
        };
        for _ in 0..3000 {
            let output = smuggling_output(&mut next);
            let mut stream = DisplayStream::default();
            let mut batch = Batch::default();
            let mut at = 0;
            while at < output.len() {
                let end = output.len().min(at + 1 + next(16));
                batch.append(stream.feed(&output[at..end]));
                at = end;
            }
            assert!(
                renderer_replies(&batch.display).is_empty(),
                "{:?}: {:?}",
                String::from_utf8_lossy(&output),
                String::from_utf8_lossy(&batch.display)
            );
        }
    }

    #[test]
    fn an_animation_frames_chunks_continue_it() {
        let mut stream = DisplayStream::default();
        stream.feed(b"\x1b_Ga=f,i=3,r=2,f=24,s=1,v=1,m=1;AAAA\x1b\\");
        stream.feed(b"\x1b_Ga=f,m=1;BBBB\x1b\\");
        assert_eq!(
            stream.unfinished_transfer(),
            b"\x1b_Ga=f,i=3,r=2,f=24,s=1,v=1,m=1,q=2;AAAA\x1b\\\x1b_Ga=f,m=1,q=2;BBBB\x1b\\"
        );
        stream.feed(b"\x1b_Ga=102,m=0;CCCC\x1b\\");
        assert!(stream.unfinished_transfer().is_empty());
    }
}
