//! The display stream as it was before its fast paths (`DisplayStream`'s
//! byte-at-a-time state machine and routing, verbatim): the reference the
//! differential tests hold the fast paths to (see `stream::tests`).
#![allow(dead_code)]
use cherry_vt::Terminal;
use std::{collections::HashMap, sync::Mutex};

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
        // Mode reports (DECRQM), DEC private and ANSI.
        (b'p', Some(b'?') | None, b"$") => true,
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
        // Program status (OSC 7501): the host keeps it and answers `?`.
        b"7501" => Route::Host,
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
/// commands; the renderer draws images but must stay silent (`q=2`), and
/// gets only what `cherry_vt::kitty::for_renderers` gives it.
fn route_graphics(token: &[u8]) -> Route {
    let Some(body) = token
        .strip_prefix(b"\x1b_G")
        .and_then(|rest| rest.strip_suffix(b"\x1b\\"))
    else {
        return Route::Both;
    };
    match cherry_vt::kitty::for_renderers(body) {
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
