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
//! with `q=2`, so only the host replies.
use cherry_vt::Terminal;
use std::{collections::HashMap, sync::Mutex};

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
#[derive(Default)]
pub struct Batch {
    /// For the host terminal.
    pub terminal: Vec<u8>,
    /// For every renderer: the output stream.
    pub display: Vec<u8>,
    /// For the renderer that answers queries: each with its position in
    /// `display` (the length `display` had when it came).
    pub queries: Vec<(usize, Vec<u8>)>,
}

impl Batch {
    /// Append the batch that follows this one.
    pub fn append(&mut self, next: Batch) {
        let base = self.display.len();
        self.terminal.extend(next.terminal);
        self.display.extend(next.display);
        for (at, query) in next.queries {
            self.push_query(base + at, &query);
        }
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

    fn limit(&self) -> usize {
        if self.mode == Mode::Osc && self.pending.starts_with(CLIPBOARD) {
            MAX_CLIPBOARD
        } else {
            MAX_CONTROL
        }
    }

    fn finish(&mut self, batch: &mut Batch) {
        if !self.discarding {
            match route(&self.pending) {
                Route::Both => {
                    batch.terminal.extend(&self.pending);
                    batch.display.extend(display_sequence(&self.pending));
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
/// commands; the renderer draws images but must stay silent (`q=2`).
fn route_graphics(token: &[u8]) -> Route {
    let Some(body) = token
        .strip_prefix(b"\x1b_G")
        .and_then(|rest| rest.strip_suffix(b"\x1b\\"))
    else {
        return Route::Both;
    };
    let control_end = body.iter().position(|&b| b == b';').unwrap_or(body.len());
    let (control, payload) = body.split_at(control_end);
    let keys: Vec<&[u8]> = control
        .split(|&b| b == b',')
        .filter(|key| !key.is_empty())
        .collect();
    if keys.contains(&&b"a=q"[..]) {
        return Route::Host;
    }
    let mut quiet = b"\x1b_G".to_vec();
    for key in keys.iter().filter(|key| !key.starts_with(b"q=")) {
        quiet.extend(*key);
        quiet.push(b',');
    }
    quiet.extend(b"q=2");
    quiet.extend(payload);
    quiet.extend(b"\x1b\\");
    Route::Split {
        display: quiet,
        query: Vec::new(),
    }
}

/// Modes the host owns because it answers them: in-band resize reports (2048)
/// and the visibility report (2033). Letting the renderer enable them would
/// inject a second report.
const HOST_MODES: [&[u8]; 2] = [b"2048", b"2033"];

fn display_sequence(bytes: &[u8]) -> Vec<u8> {
    if bytes.starts_with(b"\x1b[?") && matches!(bytes.last(), Some(b'h' | b'l')) {
        let modes: Vec<_> = bytes[3..bytes.len() - 1]
            .split(|&b| b == b';')
            .filter(|mode| !HOST_MODES.contains(mode))
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
        stream.feed(b"\x1b]52;c;");
        stream.feed(&vec![b'A'; MAX_CLIPBOARD + 1]);
        assert!(stream.pending.len() <= MAX_CLIPBOARD);
        assert_eq!(stream.feed(b"\x07ok").display, b"ok");
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

    fn host_replies(bytes: &[u8]) -> Vec<u8> {
        cherry_vt::Terminal::new(80, 24, 4096).unwrap().feed(bytes)
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
        assert_eq!(split(b"\x1b_G\x1b\\").display, b"\x1b_Gq=2\x1b\\");
    }
}
