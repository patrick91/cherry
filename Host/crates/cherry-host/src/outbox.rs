//! A connection's outgoing frames. The session worker never blocks on a slow
//! client: when a client's queued output exceeds its budget, that output is
//! dropped and the client is marked lagging. Once its writer has drained the
//! queue, the worker sends it a fresh snapshot (`Attached{reason: Resync}`),
//! which supersedes everything else it had queued. Only a failed write, which
//! means the peer is gone, ends the attachment.
//!
//! Output also carries bytes that no snapshot rebuilds because they are not
//! screen state: clipboard writes, titles, the working directory, cursor and
//! pointer shapes, bells, notifications, colour changes and kitty graphics.
//! So a client that keeps up is never dropped output: a replacement for a
//! new shared size is queued behind its output (`push_replacement`), and
//! supersedes only an older replacement still queued. From output a lagging
//! client misses, those tokens are kept (see `Carry`) and follow its resync
//! snapshot, outside the output budget, except kitty graphics: their
//! placements are positioned content that moves the cursor the snapshot
//! restored, and a transmission's chunks cannot be told apart without the
//! stream's earlier ones.
//!
//! Queries for this client's terminal to answer (`push_query`) are not
//! output, and are never dropped for lag. They are queued in order with the
//! output; those behind output or a snapshot that is dropped, and those that
//! come while the client lags, wait for its resync and follow the snapshot
//! and its carried output, so the terminal answers them for the screen it
//! then shows. How many may wait is bounded (`QUERY_LIMIT`).
//!
//! Replies are never dropped. A client that sends requests without reading
//! the replies is not read from while they exceed a bound on the order of
//! what a working client can have queued at most (an attach snapshot, or a
//! resync snapshot with its carried output, one replacement, and queries).
use crate::{signals::Wake, stream::MAX_CLIPBOARD};
use std::{
    collections::VecDeque,
    io::Write,
    sync::{Arc, Condvar, Mutex},
    time::Duration,
};

/// Queued output beyond this marks the client as lagging.
pub const OUTPUT_BUDGET: usize = 4 * 1024 * 1024;
/// Carried tokens other than clipboard writes are kept up to this many
/// bytes, the latest ones.
pub const CARRY_LIMIT: usize = 1024 * 1024;
/// Carried clipboard writes: the latest ones, to at most this many
/// selections.
const CARRY_CLIPBOARDS: usize = 4;
/// A lagging client is resynchronized once its queue is this small.
pub const RESYNC_BELOW: usize = 256 * 1024;
/// Queries waiting for a client, at most; a program that sends more to a
/// client that is not reading them loses the rest.
pub const QUERY_LIMIT: usize = 1024 * 1024;
/// The connection stops reading requests while more than this many bytes of
/// other frames are queued, and resumes at or below the low mark.
pub const REPLY_HIGH_WATER: usize = 32 * 1024 * 1024;
pub const REPLY_LOW_WATER: usize = 16 * 1024 * 1024;
/// Frames are written in pieces of this size, so progress is visible while
/// a large snapshot reaches a slow client.
const WRITE_CHUNK: usize = 64 * 1024;
const CLIPBOARD: &[u8] = b"\x1b]52;";

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Kind {
    Output,
    /// Output a resync carries (see `Carry`). Outside the output budget, so
    /// newer output cannot make the client lag over it and drop it again.
    Carried,
    /// A resync snapshot; it supersedes all but replies queued before it.
    Resync,
    /// A snapshot for a new shared size, queued behind the output leading
    /// up to it; `full` when it carries history.
    Replacement {
        full: bool,
    },
    Control,
    /// Queries for the client's terminal (see `Outbox::push_query`).
    Query,
    /// The last frame; the writer stops after it.
    Final,
}

/// An `Output` frame and the renderer bytes it carries.
pub struct Output {
    pub frame: Arc<Vec<u8>>,
    pub data: Arc<Vec<u8>>,
}

struct Item {
    frame: Arc<Vec<u8>>,
    kind: Kind,
    /// Output's renderer bytes, scanned for live-only tokens if dropped.
    data: Option<Arc<Vec<u8>>>,
}

#[derive(Default)]
struct State {
    items: VecDeque<Item>,
    bytes: usize,
    output_bytes: usize,
    /// Live-only tokens of output dropped since the last resync.
    carry: Carry,
    /// Queries held while the client lags, for after its resync.
    held: VecDeque<Arc<Vec<u8>>>,
    /// Bytes of queries queued or held.
    query_bytes: usize,
    /// Bytes written to the peer so far.
    written: u64,
    lagging: bool,
    closed: bool,
    dead: bool,
    waker: Option<Arc<Wake>>,
}

impl State {
    /// Queued bytes that are not terminal output.
    fn reply_bytes(&self) -> usize {
        self.bytes - self.output_bytes
    }

    fn push(&mut self, frame: Arc<Vec<u8>>, kind: Kind, data: Option<Arc<Vec<u8>>>) {
        self.bytes += frame.len();
        if kind == Kind::Output {
            self.output_bytes += frame.len();
        }
        self.items.push_back(Item { frame, kind, data });
    }

    /// Drop queued items of the stale kinds, keeping the live-only tokens of
    /// dropped output.
    fn drop_where(&mut self, stale: impl Fn(Kind) -> bool) {
        let mut bytes = 0;
        let mut output_bytes = 0;
        let carry = &mut self.carry;
        self.items.retain(|item| {
            if stale(item.kind) {
                if let Some(data) = &item.data {
                    carry.scan(data);
                }
                return false;
            }
            bytes += item.frame.len();
            if item.kind == Kind::Output {
                output_bytes += item.frame.len();
            }
            true
        });
        self.bytes = bytes;
        self.output_bytes = output_bytes;
    }

    /// Hold the queued queries that follow an item of the kinds about to be
    /// dropped, ahead of those held already: they wait for a resync
    /// snapshot, since the output leading up to them is lost.
    fn hold_queries(&mut self, dropped: impl Fn(Kind) -> bool) {
        let mut held = VecDeque::new();
        let mut bytes = 0;
        let mut after_dropped = false;
        self.items.retain(|item| {
            after_dropped |= dropped(item.kind);
            if after_dropped && item.kind == Kind::Query {
                bytes += item.frame.len();
                held.push_back(item.frame.clone());
                false
            } else {
                true
            }
        });
        self.bytes -= bytes;
        held.append(&mut self.held);
        self.held = held;
    }
}

/// Queued items a resync snapshot supersedes: all but replies.
fn superseded_by_resync(kind: Kind) -> bool {
    matches!(
        kind,
        Kind::Output | Kind::Carried | Kind::Resync | Kind::Replacement { .. }
    )
}

/// Live-only tokens kept from output a lagging client missed, in order, for
/// its resync. A token with a key (`live_key`) replaces an earlier one with
/// that key: the latest title of each kind (OSC 0, 1, 2), working directory,
/// cursor shape, pointer shape and bell, and the latest clipboard write to
/// each selection, of which the latest `CARRY_CLIPBOARDS` are kept while
/// they total at most one clipboard write's size (`stream::MAX_CLIPBOARD`).
/// Other tokens (notifications, colours) are kept while they total at most
/// `CARRY_LIMIT` bytes, the latest ones. Keyed tokens other than
/// clipboard writes are bounded by the display stream's control limit, so
/// the whole fits one frame.
#[derive(Default)]
struct Carry {
    /// The latest token of each key, with its arrival number.
    keyed: Vec<(Vec<u8>, u64, Vec<u8>)>,
    /// Other tokens, back to back in arrival order, and each one's arrival
    /// number and length.
    unkeyed: VecDeque<u8>,
    lengths: VecDeque<(u64, usize)>,
    arrivals: u64,
}

impl Carry {
    fn scan(&mut self, data: &[u8]) {
        live_tokens(data, |key, token| self.add(key, token));
    }

    fn add(&mut self, key: Option<&[u8]>, token: &[u8]) {
        let arrival = self.arrivals;
        self.arrivals += 1;
        let Some(key) = key else {
            if token.len() > CARRY_LIMIT {
                return;
            }
            self.unkeyed.extend(token);
            self.lengths.push_back((arrival, token.len()));
            while self.unkeyed.len() > CARRY_LIMIT {
                let (_, len) = self.lengths.pop_front().expect("tokens are counted");
                self.unkeyed.drain(..len);
            }
            return;
        };
        self.keyed.retain(|(other, ..)| other != key);
        self.keyed.push((key.to_vec(), arrival, token.to_vec()));
        if key.starts_with(CLIPBOARD) {
            loop {
                let (count, bytes) = self
                    .keyed
                    .iter()
                    .filter(|(key, ..)| key.starts_with(CLIPBOARD))
                    .fold((0, 0), |(count, bytes), (.., token)| {
                        (count + 1, bytes + token.len())
                    });
                if count == 1 || (count <= CARRY_CLIPBOARDS && bytes <= MAX_CLIPBOARD) {
                    break;
                }
                // The oldest: keyed tokens are in arrival order.
                let oldest = self
                    .keyed
                    .iter()
                    .position(|(key, ..)| key.starts_with(CLIPBOARD))
                    .expect("counted above");
                self.keyed.remove(oldest);
            }
        }
    }

    /// Call `each(key, token)` for the kept tokens in arrival order,
    /// emptying the carry.
    fn drain(&mut self, mut each: impl FnMut(Option<&[u8]>, &[u8])) {
        let keyed = std::mem::take(&mut self.keyed);
        let unkeyed = Vec::from(std::mem::take(&mut self.unkeyed));
        let lengths = std::mem::take(&mut self.lengths);
        let mut keyed = keyed.into_iter().peekable();
        let mut at = 0;
        for (arrival, len) in lengths {
            while let Some((key, _, token)) = keyed.next_if(|(_, earlier, _)| *earlier < arrival) {
                each(Some(&key), &token);
            }
            each(None, &unkeyed[at..at + len]);
            at += len;
        }
        for (key, _, token) in keyed {
            each(Some(&key), &token);
        }
    }

    /// The kept tokens in arrival order; the carry is empty afterwards.
    fn take(&mut self) -> Vec<u8> {
        let mut out = Vec::new();
        self.drain(|_, token| out.extend_from_slice(token));
        out
    }
}

/// Call `each(key, token)` for every token of renderer output that a
/// snapshot cannot rebuild and that is safe to deliver after one (so not
/// kitty graphics, or state a snapshot restores); tokens with a key make
/// earlier ones with the same key redundant. Renderer output holds whole
/// tokens and no queries (`stream::DisplayStream`).
fn live_tokens(data: &[u8], mut each: impl FnMut(Option<&[u8]>, &[u8])) {
    let mut at = 0;
    while let Some(found) = data[at..].iter().position(|&b| b == 0x1b || b == 0x07) {
        let start = at + found;
        if data[start] == 0x07 {
            each(Some(b"\x07"), b"\x07");
            at = start + 1;
            continue;
        }
        let end = token_end(data, start);
        let token = &data[start..end];
        if let Some(key) = live_key(token) {
            each(key, token);
        }
        at = end;
    }
}
/// The end of the escape sequence or control string starting at `start`.
fn token_end(data: &[u8], start: usize) -> usize {
    let rest = &data[start + 1..];
    let string_end = |bell: bool| {
        (1..rest.len())
            .find_map(|i| match rest[i] {
                0x07 if bell => Some(i + 1),
                0x1b if rest.get(i + 1) == Some(&b'\\') => Some(i + 2),
                _ => None,
            })
            .unwrap_or(rest.len())
    };
    let len = match rest.first() {
        None => 0,
        Some(b'[') => rest[1..]
            .iter()
            .position(|b| (0x40..=0x7e).contains(b))
            .map_or(rest.len(), |final_byte| final_byte + 2),
        Some(b']') => string_end(true),
        Some(b'P' | b'_' | b'^' | b'X') => string_end(false),
        Some(_) => rest
            .iter()
            .position(|b| !(0x20..=0x2f).contains(b))
            .map_or(rest.len(), |final_byte| final_byte + 1),
    };
    start + 1 + len
}

/// Whether a token is live-only: `Some(key)`, with the key of the setting it
/// replaces, if any. A clipboard write's key names its selections.
fn live_key(token: &[u8]) -> Option<Option<&[u8]>> {
    if let Some(body) = token.strip_prefix(b"\x1b[") {
        // Cursor shape (DECSCUSR).
        let shape = body
            .strip_suffix(b" q")
            .is_some_and(|params| params.iter().all(u8::is_ascii_digit));
        return shape.then_some(Some(b"\x1b[ q"));
    }
    let body = token.strip_prefix(b"\x1b]")?;
    let code = &body[..body
        .iter()
        .position(|b| !b.is_ascii_digit())
        .unwrap_or(body.len())];
    match code {
        b"52" => {
            // ESC ] 52 ; and the selections, up to the next ;.
            let selections = body
                .get(3..)
                .unwrap_or_default()
                .iter()
                .take_while(|&&b| b != b';')
                .count();
            Some(Some(&token[..CLIPBOARD.len() + selections]))
        }
        b"0" => Some(Some(b"\x1b]0;")),
        b"1" => Some(Some(b"\x1b]1;")),
        b"2" => Some(Some(b"\x1b]2;")),
        b"7" => Some(Some(b"\x1b]7;")),
        b"22" => Some(Some(b"\x1b]22;")),
        // Notifications, and palette, dynamic and kitty colours.
        b"9" | b"99" | b"777" | b"4" | b"5" | b"104" | b"105" | b"21" => Some(None),
        _ if matches!(
            std::str::from_utf8(code).ok()?.parse::<u16>().ok()?,
            10..=19 | 110..=119
        ) =>
        {
            Some(None)
        }
        _ => None,
    }
}

#[derive(PartialEq, Eq, Debug)]
pub enum Push {
    Queued,
    /// The client is behind; this output was not queued.
    Lagging,
    /// The connection is gone or closing.
    Gone,
}

#[derive(Default)]
pub struct Outbox {
    state: Mutex<State>,
    ready: Condvar,
    /// Signalled when queued replies drop to the low mark, or the writer ends.
    drained: Condvar,
}

impl Outbox {
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Terminal output. A client that cannot keep up stops receiving it;
    /// the live-only tokens of what it misses are kept for its resync.
    pub fn push_output(&self, output: &Output) -> Push {
        let mut state = self.lock();
        if state.dead || state.closed {
            return Push::Gone;
        }
        if state.lagging {
            state.carry.scan(&output.data);
            return Push::Lagging;
        }
        // An empty queue always accepts one frame, however large (a big
        // clipboard write must still reach a client that keeps up).
        if state.output_bytes > 0 && state.output_bytes + output.frame.len() > OUTPUT_BUDGET {
            state.lagging = true;
            state.hold_queries(|kind| kind == Kind::Output);
            state.drop_where(|kind| kind == Kind::Output);
            state.carry.scan(&output.data);
            return Push::Lagging;
        }
        state.push(
            output.frame.clone(),
            Kind::Output,
            Some(output.data.clone()),
        );
        self.ready.notify_one();
        Push::Queued
    }

    /// Drop everything queued that a resync snapshot supersedes (all but
    /// replies and queries), and return the live-only tokens of all output
    /// dropped since the last resync, which should follow it
    /// (`push_snapshot`). Queries queued behind what is dropped are held for
    /// after it. The session worker is the only producer, so nothing is
    /// queued between the two calls.
    pub fn take_superseded(&self) -> Vec<u8> {
        let mut state = self.lock();
        // Queries behind a superseded item (an older snapshot or
        // replacement, or output) follow the new snapshot instead.
        state.hold_queries(superseded_by_resync);
        // Output still queued (what the last resync carried) is older than
        // the output dropped or missed since, whose tokens are kept already.
        let mut newer = std::mem::take(&mut state.carry);
        state.drop_where(superseded_by_resync);
        let carry = &mut state.carry;
        newer.drain(|key, token| carry.add(key, token));
        carry.take()
    }

    /// A resync snapshot, then `carried` output (from `take_superseded`),
    /// which does not count toward the output budget, then the queries held
    /// meanwhile. Everything queued but replies is superseded by it, and a
    /// lagging client is caught up.
    pub fn push_snapshot(&self, frame: Arc<Vec<u8>>, carried: Option<Output>) -> bool {
        let mut state = self.lock();
        if state.dead || state.closed {
            return false;
        }
        state.hold_queries(superseded_by_resync);
        state.drop_where(superseded_by_resync);
        state.lagging = false;
        state.push(frame, Kind::Resync, None);
        if let Some(output) = carried {
            state.push(output.frame, Kind::Carried, Some(output.data));
        }
        while let Some(query) = state.held.pop_front() {
            state.push(query, Kind::Query, None);
        }
        self.ready.notify_one();
        true
    }

    /// Queries for the client's terminal to answer, in order with its
    /// output: queued behind it, or held while the client lags and sent
    /// after its resync snapshot. Never dropped for lag, but beyond
    /// `QUERY_LIMIT` waiting bytes a query is dropped.
    pub fn push_query(&self, frame: Arc<Vec<u8>>) -> bool {
        let mut state = self.lock();
        if state.dead || state.closed || state.query_bytes + frame.len() > QUERY_LIMIT {
            return false;
        }
        state.query_bytes += frame.len();
        if state.lagging {
            state.held.push_back(frame);
        } else {
            state.push(frame, Kind::Query, None);
            self.ready.notify_one();
        }
        true
    }

    /// Whether a full replacement is queued, which a newer replacement
    /// supersedes only if it is full too.
    pub fn full_replacement_queued(&self) -> bool {
        self.lock()
            .items
            .iter()
            .any(|item| item.kind == Kind::Replacement { full: true })
    }

    /// A replacement snapshot for a client that keeps up (`full` when it
    /// carries history), queued behind its output, which leads up to it
    /// (their offsets are contiguous), so every byte of that output still
    /// reaches the renderer in order. It supersedes older replacements still
    /// queued, except a full one when it is not full itself
    /// (`full_replacement_queued`): the output between them leads up to it
    /// as well. A later resync supersedes it.
    pub fn push_replacement(&self, frame: Arc<Vec<u8>>, full: bool) -> bool {
        let mut state = self.lock();
        if state.dead || state.closed {
            return false;
        }
        state.drop_where(|kind| match kind {
            Kind::Replacement { full: older } => full || !older,
            _ => false,
        });
        state.push(frame, Kind::Replacement { full }, None);
        self.ready.notify_one();
        true
    }

    /// A reply or notice that is never dropped.
    pub fn push_control(&self, frame: Arc<Vec<u8>>) -> bool {
        let mut state = self.lock();
        if state.dead || state.closed {
            return false;
        }
        state.push(frame, Kind::Control, None);
        self.ready.notify_one();
        true
    }

    /// The last frame of the connection.
    pub fn push_final(&self, frame: Arc<Vec<u8>>) {
        let mut state = self.lock();
        if state.dead || state.closed {
            return;
        }
        state.push(frame, Kind::Final, None);
        state.closed = true;
        self.ready.notify_one();
    }

    /// No more frames; the writer stops once the queue is empty.
    pub fn close(&self) {
        self.lock().closed = true;
        self.ready.notify_all();
    }

    pub fn is_dead(&self) -> bool {
        self.lock().dead
    }

    pub fn is_lagging(&self) -> bool {
        self.lock().lagging
    }

    /// A lagging client whose writer has caught up.
    pub fn resync_due(&self) -> bool {
        let state = self.lock();
        state.lagging && !state.dead && !state.closed && state.bytes <= RESYNC_BELOW
    }

    /// Whether the client has left too many replies unread to send more
    /// requests.
    pub fn backlogged(&self) -> bool {
        self.lock().reply_bytes() > REPLY_HIGH_WATER
    }

    /// Wait up to `timeout` for queued replies to drop to the low mark. True
    /// once they have, or once the writer has stopped.
    pub fn wait_for_reply_room(&self, timeout: Duration) -> bool {
        let state = self.lock();
        let (state, _) = self
            .drained
            .wait_timeout_while(state, timeout, |state| {
                !state.dead && state.reply_bytes() > REPLY_LOW_WATER
            })
            .unwrap_or_else(|e| e.into_inner());
        state.dead || state.reply_bytes() <= REPLY_LOW_WATER
    }

    /// Bytes written to the peer so far: shows whether it is reading.
    pub fn written(&self) -> u64 {
        self.lock().written
    }

    /// Wake the session worker when a lagging client drains or a write fails.
    pub fn set_waker(&self, waker: Arc<Wake>) {
        self.lock().waker = Some(waker);
    }

    fn next(&self) -> Option<Item> {
        let mut state = self.lock();
        loop {
            if state.dead {
                return None;
            }
            if let Some(item) = state.items.pop_front() {
                state.bytes -= item.frame.len();
                if item.kind == Kind::Output {
                    state.output_bytes -= item.frame.len();
                }
                if item.kind == Kind::Query {
                    state.query_bytes -= item.frame.len();
                }
                let waker = (state.lagging && state.bytes <= RESYNC_BELOW)
                    .then(|| state.waker.clone())
                    .flatten();
                if state.reply_bytes() <= REPLY_LOW_WATER {
                    self.drained.notify_all();
                }
                drop(state);
                if let Some(waker) = waker {
                    waker.wake();
                }
                return Some(item);
            }
            if state.closed {
                return None;
            }
            state = self.ready.wait(state).unwrap_or_else(|e| e.into_inner());
        }
    }

    fn fail(&self) {
        let waker = {
            let mut state = self.lock();
            state.dead = true;
            state.items.clear();
            state.bytes = 0;
            state.output_bytes = 0;
            state.carry = Carry::default();
            state.held.clear();
            state.query_bytes = 0;
            state.waker.clone()
        };
        self.ready.notify_all();
        self.drained.notify_all();
        if let Some(waker) = waker {
            waker.wake();
        }
    }

    /// Write queued frames until the outbox closes or a write fails. Writes
    /// block as long as the peer is alive; liveness is judged by the reader.
    pub fn write_all_to(&self, mut writer: impl Write) {
        while let Some(item) = self.next() {
            for chunk in item.frame.chunks(WRITE_CHUNK) {
                if writer.write_all(chunk).is_err() {
                    self.fail();
                    return;
                }
                self.lock().written += chunk.len() as u64;
            }
            if writer.flush().is_err() {
                self.fail();
                return;
            }
            if item.kind == Kind::Final {
                return;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(len: usize) -> Arc<Vec<u8>> {
        Arc::new(vec![0; len])
    }

    /// Output of `len` frame bytes holding `data`.
    fn output(len: usize) -> Output {
        text(len, b"")
    }

    fn text(len: usize, data: &[u8]) -> Output {
        Output {
            frame: frame(len),
            data: Arc::new(data.to_vec()),
        }
    }

    fn drain(outbox: &Outbox) -> Vec<(Kind, usize)> {
        let mut items = Vec::new();
        let state = outbox.lock();
        for item in &state.items {
            items.push((item.kind, item.frame.len()));
        }
        items
    }

    #[test]
    fn a_slow_client_drops_output_but_keeps_replies() {
        let outbox = Outbox::default();
        assert_eq!(outbox.push_output(&output(3 * 1024 * 1024)), Push::Queued);
        assert!(outbox.push_control(frame(10)));
        assert_eq!(outbox.push_output(&output(2 * 1024 * 1024)), Push::Lagging);
        assert!(outbox.is_lagging());
        assert_eq!(drain(&outbox), vec![(Kind::Control, 10)]);
        assert_eq!(outbox.push_output(&output(1)), Push::Lagging);
        assert!(outbox.resync_due());
        assert!(outbox.push_snapshot(frame(100), None));
        assert!(!outbox.is_lagging());
        assert_eq!(outbox.push_output(&output(5)), Push::Queued);
        assert_eq!(
            drain(&outbox),
            vec![(Kind::Control, 10), (Kind::Resync, 100), (Kind::Output, 5)]
        );
    }

    #[test]
    fn live_only_tokens_are_picked_out_of_renderer_output() {
        let data = [
            &b"text\x1b[31mred\x1b[0m\x07\x1b]0;both\x07\x1b]2;title\x1b\\"[..],
            b"\x1b]52;c;QUJD\x07\x1b]8;;https://x\x1b\\link\x1b]8;;\x1b\\",
            b"\x1b[8;24;80t\x1b[22;0t\x1b[5 q\x1b[>4;2m\x1b[>4n\x1bP$r1$r\x1b\\",
            b"\x1bPq#0;2;0;0;0#0~~\x1b\\\x1b_Gi=1,m=1,q=2;AAAA\x1b\\\x1b]9;done\x07",
            b"\x1b]777;notify;a;b\x07\x1b]11;rgb:0/0/0\x07\x1b]112\x07\x1b]7;file:///tmp\x07",
            b"\x1b]133;A\x07\x1b[2J\x1b[H\x1b7\x1b(0q\x1b(B\x1b]22;pointer\x1b\\\xe4\xb8\xad",
        ]
        .concat();
        let mut found = Vec::new();
        live_tokens(&data, |key, token| {
            found.push((key.is_some(), String::from_utf8_lossy(token).into_owned()))
        });
        let expected: &[(bool, &str)] = &[
            (true, "\x07"),
            (true, "\x1b]0;both\x07"),
            (true, "\x1b]2;title\x1b\\"),
            (true, "\x1b]52;c;QUJD\x07"),
            (true, "\x1b[5 q"),
            (false, "\x1b]9;done\x07"),
            (false, "\x1b]777;notify;a;b\x07"),
            (false, "\x1b]11;rgb:0/0/0\x07"),
            (false, "\x1b]112\x07"),
            (true, "\x1b]7;file:///tmp\x07"),
            (true, "\x1b]22;pointer\x1b\\"),
        ];
        let expected: Vec<_> = expected
            .iter()
            .map(|&(keyed, token)| (keyed, token.to_owned()))
            .collect();
        assert_eq!(found, expected);
    }

    #[test]
    fn carried_settings_keep_only_the_latest_and_the_rest_is_bounded() {
        let mut carry = Carry::default();
        carry.scan(b"\x07\x1b]2;one\x07\x1b]52;c;QQ==\x07\x1b]0;icon\x07\x07\x1b]52;p;Qg==\x1b\\\x1b]2;two\x07\x1b]52;c;Qw==\x07");
        // Clipboard writes are kept per selection.
        assert_eq!(
            carry.take(),
            b"\x1b]0;icon\x07\x07\x1b]52;p;Qg==\x1b\\\x1b]2;two\x07\x1b]52;c;Qw==\x07"
        );
        assert!(carry.take().is_empty());
        // Notifications, colours and other unreplaced tokens are kept up to
        // the limit, the latest ones, and large clipboard writes are too.
        let clipboard = |selection: &str, fill: u8| {
            [
                format!("\x1b]52;{selection};").as_bytes(),
                // Two fit one write's size.
                &vec![fill; MAX_CLIPBOARD / 2 - 16],
                b"\x07",
            ]
            .concat()
        };
        carry.scan(b"\x1b]4;1;rgb:00/00/00\x07");
        carry.scan(&clipboard("c", b'A'));
        let notification = b"\x1b]9;n\x07";
        for _ in 0..CARRY_LIMIT / notification.len() {
            carry.scan(notification);
        }
        let colour = b"\x1b]4;1;rgb:ff/00/00\x07";
        carry.scan(colour);
        carry.scan(&clipboard("p", b'B'));
        let carried = carry.take();
        let unkeyed =
            (CARRY_LIMIT - colour.len()) / notification.len() * notification.len() + colour.len();
        assert_eq!(carried.len(), unkeyed + 2 * clipboard("c", 0).len());
        assert!(carried.starts_with(&clipboard("c", b'A')));
        assert!(carried.ends_with(&[&colour[..], &clipboard("p", b'B')].concat()));
        // Clipboard writes to more selections, or more than one write's
        // size, keep the latest.
        for (selection, fill) in [("c", b'A'), ("p", b'B'), ("q", b'C')] {
            carry.scan(&clipboard(selection, fill));
        }
        assert_eq!(
            carry.take(),
            [clipboard("p", b'B'), clipboard("q", b'C')].concat()
        );
        for selection in ["0", "1", "2", "3", "4", "5"] {
            carry.scan(format!("\x1b]52;{selection};QQ==\x07").as_bytes());
        }
        assert_eq!(
            carry.take(),
            b"\x1b]52;2;QQ==\x07\x1b]52;3;QQ==\x07\x1b]52;4;QQ==\x07\x1b]52;5;QQ==\x07"
        );
    }

    const REFRESH: Kind = Kind::Replacement { full: false };
    const FULL: Kind = Kind::Replacement { full: true };

    #[test]
    fn a_replacement_drops_no_output_and_supersedes_older_ones() {
        let outbox = Outbox::default();
        assert!(outbox.push_control(frame(1)));
        assert_eq!(
            outbox.push_output(&text(10, b"ls\r\n\x1b]52;c;QUJD\x07")),
            Push::Queued
        );
        assert!(outbox.push_replacement(frame(100), false));
        assert_eq!(outbox.push_output(&output(5)), Push::Queued);
        assert!(outbox.push_replacement(frame(200), false));
        assert_eq!(
            drain(&outbox),
            vec![
                (Kind::Control, 1),
                (Kind::Output, 10),
                (Kind::Output, 5),
                (REFRESH, 200)
            ]
        );
        assert!(!outbox.is_lagging());
        assert!(!outbox.full_replacement_queued());
        // A full one is superseded only by another full one.
        assert!(outbox.push_replacement(frame(300), true));
        assert!(outbox.full_replacement_queued());
        assert!(outbox.push_replacement(frame(20), false));
        assert_eq!(outbox.push_output(&output(6)), Push::Queued);
        assert!(outbox.push_replacement(frame(400), true));
        assert_eq!(
            drain(&outbox),
            vec![
                (Kind::Control, 1),
                (Kind::Output, 10),
                (Kind::Output, 5),
                (Kind::Output, 6),
                (FULL, 400)
            ]
        );
        // Nor a resync, which the output after it does not continue.
        assert!(outbox.push_snapshot(frame(500), Some(text(7, b"\x07"))));
        assert_eq!(outbox.push_output(&output(8)), Push::Queued);
        assert!(outbox.push_replacement(frame(30), false));
        assert_eq!(
            drain(&outbox),
            vec![
                (Kind::Control, 1),
                (Kind::Resync, 500),
                (Kind::Carried, 7),
                (Kind::Output, 8),
                (REFRESH, 30)
            ]
        );
    }

    #[test]
    fn a_resync_carries_the_live_only_output_it_supersedes() {
        let outbox = Outbox::default();
        assert!(outbox.push_control(frame(1)));
        assert_eq!(
            outbox.push_output(&text(10, b"ls\r\n\x1b]52;c;QUJD\x07")),
            Push::Queued
        );
        assert!(outbox.push_replacement(frame(50), true));
        assert_eq!(
            outbox.push_output(&text(10, b"\x1b]9;done\x07 more")),
            Push::Queued
        );
        let carried = outbox.take_superseded();
        assert_eq!(carried, b"\x1b]52;c;QUJD\x07\x1b]9;done\x07");
        assert_eq!(drain(&outbox), vec![(Kind::Control, 1)]);
        assert!(outbox.push_snapshot(frame(100), Some(text(20, &carried))));
        assert_eq!(
            drain(&outbox),
            vec![(Kind::Control, 1), (Kind::Resync, 100), (Kind::Carried, 20)]
        );
        // Superseded in turn, the carried output is carried again.
        assert_eq!(outbox.push_output(&text(5, b"\x07")), Push::Queued);
        assert_eq!(
            outbox.take_superseded(),
            b"\x1b]52;c;QUJD\x07\x1b]9;done\x07\x07"
        );
        assert_eq!(drain(&outbox), vec![(Kind::Control, 1)]);
    }

    #[test]
    fn a_lagging_client_keeps_the_live_only_output_it_misses() {
        let outbox = Outbox::default();
        let big = 3 * 1024 * 1024;
        assert_eq!(
            outbox.push_output(&text(big, b"\x1b]2;building\x07")),
            Push::Queued
        );
        assert_eq!(
            outbox.push_output(&text(big, b"\x1b]52;c;QUJD\x07\x1b_Gi=1,m=1;AAAA\x1b\\")),
            Push::Lagging
        );
        assert_eq!(
            outbox.push_output(&text(1, b"\x1b_Gm=0;BBBB\x1b\\\x1b]2;done\x07")),
            Push::Lagging
        );
        assert!(outbox.resync_due());
        // Kitty graphics are not carried.
        assert_eq!(
            outbox.take_superseded(),
            b"\x1b]52;c;QUJD\x07\x1b]2;done\x07"
        );
    }

    #[test]
    fn queries_are_never_dropped_for_lag_and_follow_the_resync() {
        let outbox = Outbox::default();
        let big = 3 * 1024 * 1024;
        // Before any output that is dropped: it stays where it is.
        assert!(outbox.push_query(frame(11)));
        assert_eq!(outbox.push_output(&output(big)), Push::Queued);
        assert!(outbox.push_query(frame(12)));
        assert!(outbox.push_control(frame(1)));
        // Replacements supersede no query.
        assert!(outbox.push_replacement(frame(40), false));
        assert!(outbox.push_query(frame(13)));
        assert!(outbox.push_replacement(frame(41), false));
        assert_eq!(
            drain(&outbox),
            vec![
                (Kind::Query, 11),
                (Kind::Output, big),
                (Kind::Query, 12),
                (Kind::Control, 1),
                (Kind::Query, 13),
                (REFRESH, 41)
            ]
        );
        // Falling behind drops the output; the queries after it wait.
        assert_eq!(outbox.push_output(&output(big)), Push::Lagging);
        assert!(outbox.push_query(frame(14)));
        assert_eq!(outbox.push_output(&output(1)), Push::Lagging);
        assert_eq!(
            drain(&outbox),
            vec![(Kind::Query, 11), (Kind::Control, 1), (REFRESH, 41)]
        );
        // They follow the resync snapshot and its carried output, in order,
        // once each.
        assert!(outbox.take_superseded().is_empty());
        assert!(outbox.push_snapshot(frame(100), Some(text(20, b"\x07"))));
        assert_eq!(outbox.push_output(&output(5)), Push::Queued);
        assert_eq!(
            drain(&outbox),
            vec![
                (Kind::Query, 11),
                (Kind::Control, 1),
                (Kind::Resync, 100),
                (Kind::Carried, 20),
                (Kind::Query, 12),
                (Kind::Query, 13),
                (Kind::Query, 14),
                (Kind::Output, 5)
            ]
        );
        let mut written = Vec::new();
        outbox.close();
        outbox.write_all_to(&mut written);
        assert_eq!(written.len(), 11 + 1 + 100 + 20 + 12 + 13 + 14 + 5);
        assert_eq!(outbox.lock().query_bytes, 0);
    }

    #[test]
    fn queries_behind_a_superseded_snapshot_follow_the_new_one() {
        // As the session worker resynchronizes a client (`Replacement::push_to`).
        let resync = |outbox: &Outbox, len: usize| {
            let carried = outbox.take_superseded();
            let carried = (!carried.is_empty()).then(|| text(20, &carried));
            assert!(outbox.push_snapshot(frame(len), carried));
        };
        let outbox = Outbox::default();
        let big = 3 * 1024 * 1024;
        // Behind a replacement, with no output between them: the client
        // falls behind before either was written.
        assert!(outbox.push_control(frame(1)));
        assert!(outbox.push_replacement(frame(40), false));
        assert!(outbox.push_query(frame(13)));
        assert_eq!(outbox.push_output(&output(big)), Push::Queued);
        assert_eq!(outbox.push_output(&output(big)), Push::Lagging);
        assert_eq!(
            drain(&outbox),
            vec![(Kind::Control, 1), (REFRESH, 40), (Kind::Query, 13)]
        );
        assert!(outbox.resync_due());
        resync(&outbox, 100);
        assert_eq!(
            drain(&outbox),
            vec![(Kind::Control, 1), (Kind::Resync, 100), (Kind::Query, 13)]
        );
        // Behind a resync and its carried output, neither written yet, and
        // the query still waiting from before.
        assert_eq!(outbox.push_output(&text(5, b"\x07")), Push::Queued);
        assert!(outbox.push_query(frame(14)));
        assert_eq!(outbox.push_output(&output(big)), Push::Queued);
        assert_eq!(outbox.push_output(&output(big)), Push::Lagging);
        resync(&outbox, 101);
        assert_eq!(
            drain(&outbox),
            vec![
                (Kind::Control, 1),
                (Kind::Resync, 101),
                (Kind::Carried, 20),
                (Kind::Query, 13),
                (Kind::Query, 14)
            ]
        );
        // Queries ahead of everything superseded stay ahead of the resync.
        for kind in [Kind::Control, Kind::Resync, Kind::Carried] {
            assert_eq!(outbox.next().unwrap().kind, kind);
        }
        assert!(outbox.push_query(frame(15)));
        assert_eq!(outbox.push_output(&output(big)), Push::Queued);
        assert_eq!(outbox.push_output(&output(big)), Push::Lagging);
        resync(&outbox, 102);
        assert_eq!(
            drain(&outbox),
            vec![
                (Kind::Query, 13),
                (Kind::Query, 14),
                (Kind::Query, 15),
                (Kind::Resync, 102)
            ]
        );
        let mut written = Vec::new();
        outbox.close();
        outbox.write_all_to(&mut written);
        assert_eq!(outbox.lock().query_bytes, 0);
    }

    #[test]
    fn waiting_queries_are_bounded() {
        let outbox = Outbox::default();
        let query = 64 * 1024;
        for _ in 0..QUERY_LIMIT / query {
            assert!(outbox.push_query(frame(query)));
        }
        assert!(!outbox.push_query(frame(1)));
        // Held ones count too, and sending one makes room.
        assert_eq!(outbox.push_output(&output(OUTPUT_BUDGET)), Push::Queued);
        assert_eq!(outbox.push_output(&output(1)), Push::Lagging);
        assert!(!outbox.push_query(frame(1)));
        assert_eq!(outbox.next().unwrap().kind, Kind::Query);
        assert!(outbox.push_query(frame(1)));
        assert!(!outbox.push_query(frame(query)));
    }

    #[test]
    fn an_idle_client_accepts_one_oversized_frame() {
        let outbox = Outbox::default();
        assert_eq!(outbox.push_output(&output(OUTPUT_BUDGET * 2)), Push::Queued);
        assert_eq!(outbox.push_output(&output(1)), Push::Lagging);
    }

    #[test]
    fn newer_snapshots_replace_queued_ones() {
        let outbox = Outbox::default();
        assert!(outbox.push_control(frame(1)));
        assert!(outbox.push_snapshot(frame(2), None));
        assert_eq!(outbox.push_output(&output(3)), Push::Queued);
        assert!(outbox.push_snapshot(frame(4), None));
        assert_eq!(drain(&outbox), vec![(Kind::Control, 1), (Kind::Resync, 4)]);
    }

    #[test]
    fn carried_output_is_outside_the_output_budget() {
        let outbox = Outbox::default();
        assert_eq!(outbox.push_output(&output(OUTPUT_BUDGET)), Push::Queued);
        assert_eq!(
            outbox.push_output(&text(1, b"\x1b]2;old\x07")),
            Push::Lagging
        );
        // A clipboard write larger than the budget follows the resync.
        let clipboard = [&b"\x1b]52;c;"[..], &vec![b'A'; 3_400_000], b"\x07"].concat();
        let carried = text(
            OUTPUT_BUDGET + 1,
            &[&b"\x1b]2;old\x07"[..], &clipboard].concat(),
        );
        assert_eq!(outbox.take_superseded(), b"\x1b]2;old\x07");
        assert!(outbox.push_snapshot(frame(100), Some(carried)));
        assert_eq!(outbox.next().unwrap().kind, Kind::Resync);
        // Output arriving meanwhile is queued, and new output over the
        // budget drops only itself.
        assert_eq!(outbox.push_output(&text(10, b"tick")), Push::Queued);
        assert!(!outbox.is_lagging());
        assert_eq!(
            outbox.push_output(&text(OUTPUT_BUDGET, b"\x1b]2;new\x07")),
            Push::Lagging
        );
        assert_eq!(drain(&outbox), vec![(Kind::Carried, OUTPUT_BUDGET + 1)]);
        // The carried output, superseded before it was written, is carried
        // again, before what the client missed since.
        assert_eq!(
            outbox.take_superseded(),
            [&clipboard[..], b"\x1b]2;new\x07"].concat()
        );
        assert!(drain(&outbox).is_empty());
    }

    #[test]
    fn unread_replies_are_bounded_with_hysteresis() {
        let outbox = Outbox::default();
        // Output never counts: it is dropped for slow clients instead.
        assert_eq!(outbox.push_output(&output(OUTPUT_BUDGET)), Push::Queued);
        let reply = 1024 * 1024;
        for _ in 0..REPLY_HIGH_WATER / reply {
            assert!(outbox.push_control(frame(reply)));
        }
        assert!(!outbox.backlogged());
        assert!(outbox.push_control(frame(1)));
        assert!(outbox.backlogged());
        assert!(!outbox.wait_for_reply_room(Duration::from_millis(1)));
        // The writer drains to the low mark, and the reader may continue.
        let resumed = std::thread::scope(|scope| {
            let waiter = scope.spawn(|| outbox.wait_for_reply_room(Duration::from_secs(10)));
            while outbox.lock().reply_bytes() > REPLY_LOW_WATER {
                outbox.next().unwrap();
            }
            waiter.join().unwrap()
        });
        assert!(resumed);
        assert!(!outbox.backlogged());
    }

    #[test]
    fn written_bytes_are_counted_as_they_reach_the_peer() {
        let outbox = Outbox::default();
        assert!(outbox.push_control(frame(3 * WRITE_CHUNK + 1)));
        outbox.push_final(frame(5));
        let mut peer = Vec::new();
        outbox.write_all_to(&mut peer);
        assert_eq!(peer.len(), 3 * WRITE_CHUNK + 6);
        assert_eq!(outbox.written(), peer.len() as u64);
    }

    #[test]
    fn writes_stop_after_the_final_frame_or_a_failure() {
        let outbox = Outbox::default();
        assert!(outbox.push_control(Arc::new(b"a".to_vec())));
        outbox.push_final(Arc::new(b"b".to_vec()));
        assert!(!outbox.push_control(Arc::new(b"c".to_vec())));
        let mut written = Vec::new();
        outbox.write_all_to(&mut written);
        assert_eq!(written, b"ab");

        struct Broken;
        impl Write for Broken {
            fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
                Err(std::io::ErrorKind::BrokenPipe.into())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let outbox = Outbox::default();
        assert!(outbox.push_control(frame(1)));
        outbox.write_all_to(Broken);
        assert!(outbox.is_dead());
        assert_eq!(outbox.push_output(&output(1)), Push::Gone);
    }
}
