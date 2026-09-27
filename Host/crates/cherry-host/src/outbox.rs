//! A connection's outgoing frames. The session worker never blocks on a slow
//! client. A client that takes its output slowly but takes it can hold the
//! session's program back instead (`Outbox::pacing`): once more than
//! `HOLD_HIGH_WATER` of output waits for it (what its writer took and has
//! not written counts), until no more than `HOLD_LOW_WATER` does, it can
//! take only so much more now. The worker lets the program's output through
//! as fast as the fastest of the session's clients takes it (see
//! `session::Worker::pace`): not at all while one keeps up. The others fall
//! behind, and so does one that takes nothing for a while: when a client's
//! queued output exceeds its budget, that output is dropped and the client
//! is marked lagging. Once its writer has drained the queue, the worker
//! sends it a fresh snapshot (`Attached{reason: Resync}`), which supersedes
//! everything else it had queued. Only a failed write, which means the peer
//! is gone, ends the attachment.
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
//!
//! Frames are written by the connection's writer thread, or, while nothing
//! is queued ahead of them and the writer is idle, right away by whoever
//! pushes them (`set_socket`): the session worker writes output straight to
//! the client's socket without blocking, so the writer thread wakes only for
//! what the socket does not take at once. The rest of a frame written in
//! part is queued first (`Kind::Rest`) and never dropped, so frames never
//! interleave and nothing reaches the peer out of order.
//!
//! Events for a subscribed connection (`push_event`) are queued in order
//! with its replies, and bounded on their own (`EVENT_LIMIT`,
//! `EVENT_BYTES`): the latest `changed` or `progress` of a session replaces
//! one still queued, in its place (but never moves ahead of the session's
//! `added` or `removed`, nor a `changed` ahead of its `exited`), and a
//! subscriber that falls behind all the same has its queued events dropped
//! for one `resync`, which tells it to list the sessions again; each
//! session's latest progress still queued, which a listing does not tell,
//! follows it. Events never hold back the session workers that publish
//! them, nor count against the replies' bound.
use crate::{signals::Wake, stream::MAX_CLIPBOARD};
use cherry_protocol::{
    encode_frame, encode_output_frame, output_frame_parts, priority, ServerMessage, SessionEvent,
    SessionInfo, OUTPUT_HEADER,
};
use std::{
    collections::{HashMap, VecDeque},
    io::{self, Write},
    os::unix::{io::AsRawFd, net::UnixStream},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Condvar, Mutex, OnceLock,
    },
    time::{Duration, Instant},
};

/// Queued output beyond this marks the client as lagging.
pub const OUTPUT_BUDGET: usize = 4 * 1024 * 1024;
/// Queued output frames merge up to this much output (see
/// `State::merge_output`).
pub const MERGED_OUTPUT: usize = 256 * 1024;
/// While more than this much output waits for a client that takes some,
/// it can hold the session's program back (`Outbox::pacing`), until no more
/// than the low mark does. Its socket holds `priority::SOCKET_BUFFER_BYTES`
/// more.
pub const HOLD_HIGH_WATER: usize = 512 * 1024;
pub const HOLD_LOW_WATER: usize = 128 * 1024;
/// Output that reached the client after it began to hold the session back
/// (the program's output already on its way) may wait for it too, up to
/// this much more: the session then goes on at the client's pace from
/// there, rather than stop until the client took it (see
/// `Outbox::pacing`).
pub const HOLD_SLACK: usize = 256 * 1024;
/// The most output that waits for a client the session's program goes at
/// the pace of, normally (see `Outbox::pacing`).
pub const PACE_WINDOW: usize = HOLD_HIGH_WATER + HOLD_SLACK;
/// A client that takes over pacing the program from another one (see
/// `Outbox::lead`) may keep this much output waiting at most: less than
/// `OUTPUT_BUDGET` by more than what may be on its way to it already.
pub const LEAD_LIMIT: usize = OUTPUT_BUDGET - 1024 * 1024;
/// While it may hold the session back, the session's worker is woken once
/// the client took at least this much more and takes no more for now (its
/// writer waits for its socket; see `session::Worker::pace`): the program
/// gets the output in steps this small at a slow client's pace, and in the
/// bursts it takes at a faster one.
pub const PACE_STEP: usize = 8 * 1024;
/// While its writer goes on writing, the worker is woken at least every this
/// much it wrote.
const PACE_BURST: usize = 256 * 1024;
/// A client that takes its output slowly counts as taking none of it once
/// it took none for this long, or for `IDLE_GAPS` times the longest it
/// recently went without taking any while output waited for it, if that is
/// longer (a slow reader takes its output in steps: `cherry attach` reads
/// 16 KiB at a time as its terminal takes it). It then paces the program no
/// more while another client takes output (see `Pacing::Slow`).
pub const IDLE_AFTER: Duration = Duration::from_millis(250);
const IDLE_GAPS: u32 = 3;
/// How long the longest waits of a client are remembered (see `Gaps`).
const GAP_WINDOW: Duration = Duration::from_secs(1);
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
/// The writer tries again this often while its socket is full (see
/// `Outbox::wait_writable`).
const WRITABLE_RECHECK: Duration = Duration::from_millis(10);
const CLIPBOARD: &[u8] = b"\x1b]52;";
/// A subscriber with more events than this queued, or more bytes of them,
/// has fallen behind (see `Outbox::push_event`).
pub const EVENT_LIMIT: usize = 1024;
pub const EVENT_BYTES: usize = 4 * 1024 * 1024;

/// What an event reports the latest of: a newer one replaces it while it is
/// still queued.
#[derive(Clone, PartialEq, Eq, Hash, Debug)]
pub enum EventKey {
    /// A session's `changed`, which carries all of its `SessionInfo`.
    Changed(String),
    /// A session's `progress`.
    Progress(String),
}

impl EventKey {
    /// `event`'s key, if a newer event replaces it, and the keys of the
    /// events it seals (see `Outbox::push_event`): a later change of the
    /// session never passes its addition, its removal or its exit (the
    /// change that follows an exit says so).
    pub fn of(event: &SessionEvent) -> (Option<Self>, Vec<Self>) {
        match event {
            SessionEvent::Changed { session } => {
                (Some(Self::Changed(session.id.clone())), Vec::new())
            }
            SessionEvent::Progress { id, .. } => (Some(Self::Progress(id.clone())), Vec::new()),
            SessionEvent::Added {
                session: SessionInfo { id, .. },
            }
            | SessionEvent::Removed { id } => (
                None,
                vec![Self::Changed(id.clone()), Self::Progress(id.clone())],
            ),
            SessionEvent::Exited { id, .. } => (None, vec![Self::Changed(id.clone())]),
            SessionEvent::Bell { .. }
            | SessionEvent::Notification { .. }
            | SessionEvent::Resync => (None, Vec::new()),
        }
    }
}

/// The `resync` event, which replaces the events a subscriber fell behind
/// on.
fn resync_frame() -> Arc<Vec<u8>> {
    static FRAME: OnceLock<Arc<Vec<u8>>> = OnceLock::new();
    FRAME
        .get_or_init(|| {
            Arc::new(
                encode_frame(&ServerMessage::Event {
                    event: SessionEvent::Resync,
                })
                .expect("the resync event encodes"),
            )
        })
        .clone()
}

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
    /// A new shared size without a snapshot (`ServerMessage::Resized`):
    /// superseded like a replacement, and supersedes nothing, since it
    /// carries no screen.
    Resized,
    /// The rest of a frame written in part: it goes first, and is never
    /// dropped or superseded.
    Rest,
    Control,
    /// Queries for the client's terminal (see `Outbox::push_query`).
    Query,
    /// The last frame; the writer stops after it.
    Final,
    /// An event for a subscriber (see `Outbox::push_event`).
    Event,
    /// The place of an event that a newer one of its key replaces; its
    /// frame is the latest in `State::latest`, until it is sealed.
    Latest,
}

impl Kind {
    /// Events are counted apart from the other frames.
    fn is_event(self) -> bool {
        matches!(self, Kind::Event | Kind::Latest)
    }
}

/// An `Output` frame (see `cherry_protocol::encode_output_frame`), which
/// carries the renderer bytes as they are.
#[derive(Clone)]
pub struct Output {
    pub frame: Arc<Vec<u8>>,
}

impl Output {
    pub fn new(offset: u64, data: &[u8]) -> io::Result<Self> {
        Ok(Self {
            frame: Arc::new(encode_output_frame(offset, data)?),
        })
    }

    /// The renderer bytes.
    pub fn data(&self) -> &[u8] {
        output_data(&self.frame)
    }
}

/// The renderer bytes of an `Output` frame.
fn output_data(frame: &[u8]) -> &[u8] {
    frame.get(OUTPUT_HEADER..).unwrap_or_default()
}

struct Item {
    frame: Arc<Vec<u8>>,
    /// Bytes of `frame` written already: the part of a `Rest` that went out
    /// at once (the rest shares the frame, uncopied).
    start: usize,
    kind: Kind,
    /// An `Output` frame (or its rest), whose renderer bytes are scanned
    /// for live-only tokens if it is dropped.
    output: bool,
    /// A `Latest` event's key, and which of its key's events it is.
    key: Option<EventKey>,
    seq: u64,
}

impl Item {
    /// What is left to write.
    fn bytes(&self) -> &[u8] {
        &self.frame[self.start..]
    }

    /// The rest of an `Output` frame written in part.
    fn output_rest(&self) -> bool {
        self.kind == Kind::Rest && self.output
    }

    /// Whether it counts as output waiting for the client
    /// (`State::waiting`): an `Output` frame, or the rest of one.
    fn waiting_output(&self) -> bool {
        self.kind == Kind::Output || self.output_rest()
    }
}

/// The longest a client went without taking anything while output waited
/// for it, in the `GAP_WINDOW` its latest wait fell in and the one before.
#[derive(Default)]
struct Gaps {
    /// When the current window began.
    window: Option<Instant>,
    current: Duration,
    previous: Duration,
}

impl Gaps {
    /// It took output at `now`, after waiting `gap`.
    fn note(&mut self, gap: Duration, now: Instant) {
        let elapsed = now.saturating_duration_since(*self.window.get_or_insert(now));
        if elapsed >= GAP_WINDOW {
            self.previous = if elapsed < 2 * GAP_WINDOW {
                self.current
            } else {
                Duration::ZERO
            };
            self.current = Duration::ZERO;
            self.window = Some(now);
        }
        self.current = self.current.max(gap);
    }

    /// The longest wait up to `at` (its last progress): in the window it
    /// fell in and the one before.
    fn longest(&self, at: Instant) -> Duration {
        let Some(window) = self.window else {
            return Duration::ZERO;
        };
        match at.saturating_duration_since(window) {
            elapsed if elapsed < GAP_WINDOW => self.current.max(self.previous),
            elapsed if elapsed < 2 * GAP_WINDOW => self.current,
            _ => Duration::ZERO,
        }
    }
}

#[derive(Default)]
struct State {
    items: VecDeque<Item>,
    /// Bytes queued, events aside.
    bytes: usize,
    /// Bytes of `Output` frames queued: the output budget's.
    output_bytes: usize,
    /// Bytes of the rest of `Output` frames written in part, queued.
    rest_bytes: usize,
    /// Bytes of output the writer took from the queue and has not written
    /// yet: output waits for the client until it is written.
    writing_output: usize,
    /// Bytes the peer took since the session's worker was last woken for
    /// them (see `PACE_STEP`).
    paced: usize,
    /// Events queued, and their bytes.
    events: usize,
    event_bytes: usize,
    /// The latest frame of each key with an event queued (`Kind::Latest`),
    /// and that item's `seq`.
    latest: HashMap<EventKey, (u64, Arc<Vec<u8>>)>,
    next_seq: u64,
    /// Live-only tokens of output dropped since the last resync.
    carry: Carry,
    /// Queries held while the client lags, for after its resync.
    held: VecDeque<Arc<Vec<u8>>>,
    /// Bytes of queries queued or held.
    query_bytes: usize,
    /// Bytes written to the peer so far.
    written: u64,
    /// Since when the peer has taken nothing while output waited: the
    /// last write, or when output started to wait.
    progress_at: Option<Instant>,
    /// When the peer last took anything.
    took_at: Option<Instant>,
    /// How long it recently went without taking anything while output
    /// waited for it.
    gaps: Gaps,
    /// More than `HOLD_HIGH_WATER` of output waits, and not yet no more
    /// than `HOLD_LOW_WATER` again: the session may hold its output back
    /// for this client while it takes some (see `Outbox::pacing`).
    holding: bool,
    /// How much output may wait for the client while it holds the session
    /// back: the most that waited since it began to, from
    /// `HOLD_HIGH_WATER` up to `PACE_WINDOW`, or more for a while after it
    /// took over pacing the session from another client (see
    /// `Outbox::lead`).
    hold_limit: usize,
    lagging: bool,
    closed: bool,
    dead: bool,
    waker: Option<Arc<Wake>>,
    /// The writer thread is writing an item it took from the queue.
    writing: bool,
    /// The connection's socket, for frames written without the writer
    /// thread (see `Outbox::set_socket`).
    socket: Option<UnixStream>,
}

impl State {
    /// The peer is gone: nothing more is written or queued.
    fn fail(&mut self) {
        self.dead = true;
        self.writing = false;
        self.holding = false;
        self.items.clear();
        self.bytes = 0;
        self.output_bytes = 0;
        self.rest_bytes = 0;
        self.writing_output = 0;
        self.carry = Carry::default();
        self.held.clear();
        self.query_bytes = 0;
        self.events = 0;
        self.event_bytes = 0;
        self.latest.clear();
    }

    /// Queued bytes that are not terminal output.
    fn reply_bytes(&self) -> usize {
        self.bytes - self.output_bytes
    }

    /// Output that waits for the client: queued, or taken by the writer and
    /// not written yet.
    fn waiting(&self) -> usize {
        self.output_bytes + self.rest_bytes + self.writing_output
    }

    fn push(&mut self, frame: Arc<Vec<u8>>, kind: Kind, output: bool) {
        self.waiting_from_now();
        self.bytes += frame.len();
        if kind == Kind::Output {
            self.output_bytes += frame.len();
        }
        self.items.push_back(Item {
            frame,
            start: 0,
            kind,
            output,
            key: None,
            seq: 0,
        });
    }

    /// Queue an event; a keyed one keeps its frame in `latest`.
    fn push_event(&mut self, frame: Arc<Vec<u8>>, key: Option<EventKey>) {
        self.events += 1;
        self.event_bytes += frame.len();
        let seq = self.next_seq;
        self.next_seq += 1;
        let (frame, kind) = match &key {
            Some(key) => {
                self.latest.insert(key.clone(), (seq, frame));
                (Arc::default(), Kind::Latest)
            }
            None => (frame, Kind::Event),
        };
        self.items.push_back(Item {
            frame,
            start: 0,
            kind,
            output: false,
            key,
            seq,
        });
    }

    /// Nothing newer replaces the queued event of `key` any more: it keeps
    /// the frame it has, and the next one of its key is queued anew.
    fn seal(&mut self, key: &EventKey) {
        let Some((seq, frame)) = self.latest.remove(key) else {
            return;
        };
        if let Some(item) = self
            .items
            .iter_mut()
            .rev()
            .find(|item| item.kind == Kind::Latest && item.seq == seq)
        {
            item.frame = frame;
            item.kind = Kind::Event;
        }
    }

    /// Drop queued items of the stale kinds, keeping the live-only tokens of
    /// dropped output.
    fn drop_where(&mut self, stale: impl Fn(Kind) -> bool) {
        let mut bytes = 0;
        let mut output_bytes = 0;
        let mut rest_bytes = 0;
        let carry = &mut self.carry;
        self.items.retain(|item| {
            if stale(item.kind) {
                if item.output {
                    carry.scan(output_data(&item.frame));
                }
                return false;
            }
            if !item.kind.is_event() {
                bytes += item.bytes().len();
            }
            if item.kind == Kind::Output {
                output_bytes += item.frame.len();
            }
            if item.output_rest() {
                rest_bytes += item.bytes().len();
            }
            true
        });
        self.bytes = bytes;
        self.output_bytes = output_bytes;
        self.rest_bytes = rest_bytes;
        self.release_hold();
    }

    /// Output starts to wait for the peer now, unless some waits already:
    /// its stall clock starts.
    fn waiting_from_now(&mut self) {
        if self.bytes == 0 && !self.writing {
            self.progress_at = Some(Instant::now());
        }
    }

    /// The peer took `bytes`.
    fn took(&mut self, bytes: usize) {
        self.took_by(bytes, Instant::now());
    }

    /// The peer took `bytes` at `now`.
    fn took_by(&mut self, bytes: usize, now: Instant) {
        self.written += bytes as u64;
        self.progress_at = Some(now);
        self.took_at = Some(now);
    }

    /// The writer wrote `bytes` of the item it took from the queue, which
    /// is output when `output`. Whether the session's worker is to be woken:
    /// the client no longer holds the session back, or, while it does, it
    /// took `PACE_BURST` since the worker last heard.
    fn wrote(&mut self, bytes: usize, output: bool) -> bool {
        let now = Instant::now();
        // Output waited for the peer since its last write, or since output
        // started to wait.
        if let Some(since) = self.progress_at.filter(|_| output) {
            self.gaps.note(now.saturating_duration_since(since), now);
        }
        self.took_by(bytes, now);
        if output {
            let excess = self.waiting().saturating_sub(self.hold_limit);
            self.writing_output = self.writing_output.saturating_sub(bytes);
            // What a client that took over pacing lets wait beyond the
            // window shrinks by half of what it takes (see `Outbox::lead`),
            // once what waited beyond that (more than `LEAD_LIMIT`) is
            // taken.
            if self.hold_limit > PACE_WINDOW {
                let counted = bytes.saturating_sub(excess);
                self.hold_limit = self
                    .hold_limit
                    .saturating_sub(counted.div_ceil(2))
                    .max(PACE_WINDOW);
            }
        }
        if self.release_hold() {
            return true;
        }
        if self.holding {
            self.paced += bytes;
        }
        self.paced_at(PACE_BURST)
    }

    /// The writer waits for the client to take more: whether the session's
    /// worker is to be woken for what it took since it last heard (at least
    /// `PACE_STEP`, while the client holds the session back).
    fn blocked(&mut self) -> bool {
        self.paced_at(PACE_STEP)
    }

    fn paced_at(&mut self, step: usize) -> bool {
        let due = self.holding && self.paced >= step;
        if due {
            self.paced = 0;
        }
        due
    }

    /// Once no more than `HOLD_LOW_WATER` of output waits, the client
    /// holds nothing back any more; whether it just stopped.
    fn release_hold(&mut self) -> bool {
        let released = self.holding && self.waiting() <= HOLD_LOW_WATER;
        if released {
            self.holding = false;
            self.paced = 0;
        }
        released
    }

    /// The subscriber fell behind: its queued events give way to one
    /// `resync`, followed by each session's latest `progress` still queued,
    /// which listing the sessions cannot tell (at most one per session).
    fn resync_events(&mut self) {
        let mut progress: Vec<(u64, EventKey, Arc<Vec<u8>>)> = self
            .latest
            .drain()
            .filter(|(key, _)| matches!(key, EventKey::Progress(_)))
            .map(|(key, (seq, frame))| (seq, key, frame))
            .collect();
        progress.sort_by_key(|(seq, ..)| *seq);
        self.items.retain(|item| !item.kind.is_event());
        self.events = 0;
        self.event_bytes = 0;
        self.push_event(resync_frame(), None);
        for (_, key, frame) in progress {
            self.push_event(frame, Some(key));
        }
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

impl State {
    /// While output waits behind the socket, output that continues the
    /// last output queued joins it, up to `MERGED_OUTPUT` (the renderer
    /// gets the same bytes in fewer, bigger frames, which cost it less per
    /// byte). Whether it did. Output nothing waits ahead of goes at once,
    /// as it is.
    fn merge_output(&mut self, output: &Output) -> bool {
        let Some(last) = self.items.back_mut() else {
            return false;
        };
        if last.kind != Kind::Output {
            return false;
        }
        let Some((offset, data)) = output_frame_parts(&last.frame) else {
            return false;
        };
        let Some((next, more)) = output_frame_parts(&output.frame) else {
            return false;
        };
        if offset.checked_add(data.len() as u64) != Some(next)
            || data.len() + more.len() > MERGED_OUTPUT
        {
            return false;
        }
        // Its own copy the first time (another client's queue may hold the
        // same frame), then in place.
        let frame = Arc::make_mut(&mut last.frame);
        frame.extend_from_slice(more);
        let length = (frame.len() - 4) as u32;
        frame[..4].copy_from_slice(&length.to_be_bytes());
        self.bytes += more.len();
        self.output_bytes += more.len();
        true
    }
}

/// Queued items a resync snapshot supersedes: all but replies (and the
/// rest of a frame already written in part).
fn superseded_by_resync(kind: Kind) -> bool {
    matches!(
        kind,
        Kind::Output | Kind::Carried | Kind::Resync | Kind::Replacement { .. } | Kind::Resized
    )
}

/// Write as much of `bytes` to `socket`, which is nonblocking, as it takes
/// now. None when the write failed: the peer is gone.
fn send_now(socket: &UnixStream, bytes: &[u8]) -> Option<usize> {
    #[cfg(target_os = "linux")]
    const FLAGS: libc::c_int = libc::MSG_NOSIGNAL;
    #[cfg(not(target_os = "linux"))]
    const FLAGS: libc::c_int = 0;
    let mut sent = 0;
    while sent < bytes.len() {
        let rest = &bytes[sent..];
        let n = unsafe { libc::send(socket.as_raw_fd(), rest.as_ptr().cast(), rest.len(), FLAGS) };
        if n < 0 {
            let error = io::Error::last_os_error();
            match error.kind() {
                io::ErrorKind::Interrupted => continue,
                io::ErrorKind::WouldBlock => break,
                _ => return None,
            }
        }
        sent += n as usize;
    }
    Some(sent)
}

impl State {
    /// Write `frame` (an `Output` frame when `output`) right away when
    /// nothing is queued ahead of it and the writer is idle; what the
    /// socket does not take is queued as the rest of the frame, first.
    /// Returns `Some(queued)` when it was written, in whole or in part
    /// (`queued`: its rest waits for the writer), and None when it was not
    /// written and still has to be queued. Marks the connection dead when
    /// the write fails.
    fn write_now(&mut self, frame: &Arc<Vec<u8>>, output: bool) -> Option<Result<bool, ()>> {
        if !self.items.is_empty() || self.writing {
            return None;
        }
        let socket = self.socket.as_ref()?;
        let Some(sent) = send_now(socket, frame) else {
            return Some(Err(()));
        };
        if sent == 0 {
            return None;
        }
        self.took(sent);
        if sent == frame.len() {
            return Some(Ok(false));
        }
        self.waiting_from_now();
        self.bytes += frame.len() - sent;
        if output {
            self.rest_bytes += frame.len() - sent;
        }
        self.items.push_back(Item {
            frame: frame.clone(),
            start: sent,
            kind: Kind::Rest,
            output,
            key: None,
            seq: 0,
        });
        Some(Ok(true))
    }
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

/// How a client paces the session's program (see `Outbox::pacing`).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Pacing {
    /// No more than `HOLD_HIGH_WATER` of output waits for it: it takes its
    /// output as fast as the program makes it, for now.
    KeepsUp,
    /// It takes its output slowly, but takes it: it can take `room` more
    /// now, and holds the program back until `until` at most if it takes
    /// nothing more. `waiting`: the output that waits for it. It has taken
    /// nothing since `since` (its last progress, or when output started to
    /// wait), and from `idle` (see `IDLE_AFTER`) counts as taking nothing:
    /// once another client took anything since `since`, it paces nothing
    /// (see `session::Worker::pace`).
    Slow {
        room: usize,
        until: Instant,
        waiting: usize,
        since: Instant,
        idle: Instant,
    },
    /// It paces nothing: it lags, is gone or closing, or took none of its
    /// output for the stall.
    Out,
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
    /// The connection serves an attached renderer: its writer runs at
    /// interactive priority.
    interactive: AtomicBool,
}

impl Outbox {
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Write frames to `socket` (the connection's, nonblocking, which the
    /// writer thread writes to as well) right away while nothing is queued
    /// and the writer is idle.
    pub fn set_socket(&self, socket: UnixStream) {
        self.lock().socket = Some(socket);
    }

    /// Wait until the socket takes more (the writer's writes find it full).
    /// False without a socket to wait for.
    fn wait_writable(&self) -> bool {
        let Some(fd) = self.lock().socket.as_ref().map(AsRawFd::as_raw_fd) else {
            return false;
        };
        let mut poll = libc::pollfd {
            fd,
            events: libc::POLLOUT,
            revents: 0,
        };
        // Until there is room or the connection is shut down (a vanished
        // peer is noticed by the reader, which shuts the socket down), or
        // `WRITABLE_RECHECK`: a macOS Unix socket reports room only once
        // its peer read nearly all it holds, though it takes more as soon
        // as the peer reads any. Trying again sooner keeps a slow peer's
        // socket topped up, and shows that it reads (`pacing`).
        unsafe {
            libc::poll(&mut poll, 1, WRITABLE_RECHECK.as_millis() as libc::c_int);
        }
        true
    }

    /// Whether the writer serves an attached renderer, and so runs at
    /// interactive priority.
    pub fn set_interactive(&self, interactive: bool) {
        self.interactive.store(interactive, Ordering::Relaxed);
    }

    /// Write `frame` now if nothing is ahead of it, or queue it as `kind`.
    /// False when the connection turned out to be gone.
    fn deliver(&self, state: &mut State, frame: Arc<Vec<u8>>, kind: Kind, output: bool) -> bool {
        match state.write_now(&frame, kind == Kind::Output) {
            Some(Ok(queued_rest)) => {
                if queued_rest {
                    self.ready.notify_one();
                }
                true
            }
            Some(Err(())) => {
                state.fail();
                self.ready.notify_all();
                self.drained.notify_all();
                if let Some(waker) = state.waker.clone() {
                    waker.wake();
                }
                false
            }
            None => {
                state.push(frame, kind, output);
                self.ready.notify_one();
                true
            }
        }
    }

    /// Terminal output. A client that cannot keep up stops receiving it;
    /// the live-only tokens of what it misses are kept for its resync.
    pub fn push_output(&self, output: &Output) -> Push {
        let mut state = self.lock();
        if state.dead || state.closed {
            return Push::Gone;
        }
        if state.lagging {
            state.carry.scan(output.data());
            return Push::Lagging;
        }
        // An empty queue always accepts one frame, however large (a big
        // clipboard write must still reach a client that keeps up).
        if state.output_bytes > 0 && state.output_bytes + output.frame.len() > OUTPUT_BUDGET {
            state.lagging = true;
            // It paces nothing any more, and once resynchronized it starts
            // afresh: it keeps up until more than `HOLD_HIGH_WATER` waits
            // again, with no room left over from before.
            state.holding = false;
            state.paced = 0;
            state.hold_queries(|kind| kind == Kind::Output);
            state.drop_where(|kind| kind == Kind::Output);
            state.carry.scan(output.data());
            return Push::Lagging;
        }
        let queued = if state.merge_output(output) {
            self.ready.notify_one();
            true
        } else {
            self.deliver(&mut state, output.frame.clone(), Kind::Output, true)
        };
        if !queued {
            return Push::Gone;
        }
        let waiting = state.waiting();
        if waiting > HOLD_HIGH_WATER {
            if !state.holding {
                state.holding = true;
                state.hold_limit = 0;
            }
            state.hold_limit = state.hold_limit.max(waiting.min(PACE_WINDOW));
        }
        Push::Queued
    }

    /// How the client paces the session's program (see
    /// `session::Worker::pace`), and when it last took anything. While no
    /// more than `HOLD_HIGH_WATER` of output waits for it (until no more
    /// than `HOLD_LOW_WATER` does again once more did), it keeps up. Beyond
    /// that it takes its output slowly: if it took some within `stall`, it
    /// can take as much more now as it took since the most waited for it
    /// (up to `PACE_WINDOW`), and holds the program back until `stall`
    /// after its last progress at most if it takes nothing more (a peer
    /// that is slow but reads gets the output at its own pace, as a
    /// program's terminal does: the program waits, unless another client
    /// takes it faster), or, while another client takes output, until it
    /// took none for a while (`IDLE_AFTER`). A client that takes nothing
    /// for `stall`, lags, or is gone or closing, paces nothing: output goes
    /// on without it, and once more than `OUTPUT_BUDGET` waits it lags (see
    /// `push_output`) and is resynchronized once it drains.
    pub fn pacing(&self, stall: Duration) -> (Pacing, Option<Instant>) {
        let state = self.lock();
        let pacing = if state.lagging || state.dead || state.closed {
            Pacing::Out
        } else if !state.holding {
            Pacing::KeepsUp
        } else {
            let now = Instant::now();
            let since = state.progress_at.unwrap_or(now);
            let until = since + stall;
            let waiting = state.waiting();
            let idle = (state.gaps.longest(since) * IDLE_GAPS)
                .max(IDLE_AFTER)
                .min(stall);
            if now < until {
                Pacing::Slow {
                    room: state.hold_limit.saturating_sub(waiting),
                    until,
                    waiting,
                    since,
                    idle: since + idle,
                }
            } else {
                Pacing::Out
            }
        };
        (pacing, state.took_at)
    }

    /// The session's program goes at this client's pace now, in place of
    /// another client's (which left, stalled, or took nothing while this
    /// one took its output; see `session::Worker::pace`): the output that
    /// waits for it may go on waiting, up to `LEAD_LIMIT`, so the program
    /// goes on at its pace from here, rather than stop until it took all
    /// that. What waits beyond `PACE_WINDOW` shrinks by half of what it
    /// takes (see `State::wrote`): the program goes on at half its pace
    /// until it caught up.
    pub fn lead(&self) {
        let mut state = self.lock();
        if state.holding {
            let waiting = state.waiting();
            state.hold_limit = state.hold_limit.max(waiting.min(LEAD_LIMIT));
        }
    }

    /// Whether the session's program is held back for this client alone,
    /// and so how much more output it can take now and until when at most
    /// (see `pacing`).
    #[cfg(test)]
    fn holds_back(&self, stall: Duration) -> Option<(usize, Instant)> {
        match self.pacing(stall).0 {
            Pacing::Slow { room, until, .. } => Some((room, until)),
            Pacing::KeepsUp | Pacing::Out => None,
        }
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
        state.push(frame, Kind::Resync, false);
        if let Some(output) = carried {
            state.push(output.frame, Kind::Carried, true);
        }
        while let Some(query) = state.held.pop_front() {
            state.push(query, Kind::Query, false);
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
        if state.lagging {
            state.query_bytes += frame.len();
            state.held.push_back(frame);
            return true;
        }
        match state.write_now(&frame, false) {
            Some(Ok(_)) => true,
            Some(Err(())) => {
                drop(state);
                self.fail();
                false
            }
            None => {
                state.query_bytes += frame.len();
                state.push(frame, Kind::Query, false);
                self.ready.notify_one();
                true
            }
        }
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
            Kind::Resized => true,
            _ => false,
        });
        state.push(frame, Kind::Replacement { full }, false);
        self.ready.notify_one();
        true
    }

    /// A new shared size without a snapshot (`ServerMessage::Resized`), in
    /// order with the output: a later replacement or resync supersedes it
    /// while it is queued, and it supersedes nothing.
    pub fn push_resized(&self, frame: Arc<Vec<u8>>) -> bool {
        let mut state = self.lock();
        if state.dead || state.closed {
            return false;
        }
        self.deliver(&mut state, frame, Kind::Resized, false)
    }

    /// A reply or notice that is never dropped.
    pub fn push_control(&self, frame: Arc<Vec<u8>>) -> bool {
        let mut state = self.lock();
        if state.dead || state.closed {
            return false;
        }
        self.deliver(&mut state, frame, Kind::Control, false)
    }

    /// An event for this subscribed connection, in order with its replies.
    /// One with a `key` replaces the frame of an event with that key still
    /// queued, which keeps its place. Events of the keys in `seals` never
    /// pass this one (a session's `added`, `removed` or `exited`): the next
    /// of each is queued behind it. Beyond `EVENT_LIMIT` events or
    /// `EVENT_BYTES` (a queue with no other event takes one of any size),
    /// the subscriber has fallen behind: its queued events give way to one
    /// `resync` (see `State::resync_events`), and this event follows it.
    /// False once the connection is gone or closing.
    pub fn push_event(
        &self,
        frame: Arc<Vec<u8>>,
        key: Option<EventKey>,
        seals: &[EventKey],
    ) -> bool {
        let mut state = self.lock();
        if state.dead || state.closed {
            return false;
        }
        for sealed in seals {
            state.seal(sealed);
        }
        let replaced = key
            .as_ref()
            .and_then(|key| state.latest.get(key))
            .map(|(_, queued)| queued.len());
        let behind = match replaced {
            Some(replaced) => {
                state.events > 1 && state.event_bytes - replaced + frame.len() > EVENT_BYTES
            }
            None => {
                state.events > 0
                    && (state.events >= EVENT_LIMIT
                        || state.event_bytes + frame.len() > EVENT_BYTES)
            }
        };
        if behind {
            // This event supersedes the one of its key a resync would keep.
            if let Some(key) = &key {
                state.latest.remove(key);
            }
            state.resync_events();
        } else if let Some(replaced) = replaced {
            state.event_bytes = state.event_bytes - replaced + frame.len();
            if let Some((_, queued)) = key.as_ref().and_then(|key| state.latest.get_mut(key)) {
                *queued = frame;
            }
            return true;
        }
        state.push_event(frame, key);
        self.ready.notify_one();
        true
    }

    /// The last frame of the connection.
    pub fn push_final(&self, frame: Arc<Vec<u8>>) {
        let mut state = self.lock();
        if state.dead || state.closed {
            return;
        }
        state.push(frame, Kind::Final, false);
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
            if let Some(mut item) = state.items.pop_front() {
                if item.kind == Kind::Latest {
                    // Unsealed, it is its key's latest.
                    if let Some((_, frame)) =
                        item.key.as_ref().and_then(|key| state.latest.remove(key))
                    {
                        item.frame = frame;
                    }
                }
                if item.kind.is_event() {
                    state.events -= 1;
                    state.event_bytes -= item.frame.len();
                } else {
                    state.bytes -= item.bytes().len();
                }
                if item.kind == Kind::Output {
                    state.output_bytes -= item.frame.len();
                }
                if item.output_rest() {
                    state.rest_bytes -= item.bytes().len();
                }
                if item.waiting_output() {
                    // It waits for the client until it is written.
                    state.writing_output = item.bytes().len();
                }
                if item.kind == Kind::Query {
                    state.query_bytes -= item.frame.len();
                }
                state.writing = true;
                // A lagging client that drained is resynchronized.
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
            state.fail();
            state.waker.clone()
        };
        self.ready.notify_all();
        self.drained.notify_all();
        if let Some(waker) = waker {
            waker.wake();
        }
    }

    /// Write queued frames until the outbox closes or a write fails. Writes
    /// wait as long as the peer is alive (a nonblocking socket is waited
    /// for, see `set_socket`); liveness is judged by the reader.
    pub fn write_all_to(&self, mut writer: impl Write) {
        while let Some(item) = self.next() {
            priority::interactive(self.interactive.load(Ordering::Relaxed));
            let output = item.waiting_output();
            for chunk in item.bytes().chunks(WRITE_CHUNK) {
                let mut rest = chunk;
                while !rest.is_empty() {
                    match writer.write(rest) {
                        Ok(0) => {
                            self.fail();
                            return;
                        }
                        Ok(n) => {
                            rest = &rest[n..];
                            self.wrote(n, output);
                        }
                        Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                            // The client takes no more for now: the
                            // session's worker hears what it took.
                            self.blocked();
                            if !self.wait_writable() {
                                self.fail();
                                return;
                            }
                        }
                        Err(_) => {
                            self.fail();
                            return;
                        }
                    }
                }
            }
            if writer.flush().is_err() {
                self.fail();
                return;
            }
            if item.kind == Kind::Final {
                return;
            }
            let mut state = self.lock();
            state.writing = false;
            state.writing_output = 0;
        }
    }

    /// The writer wrote `bytes` of its item (output when `output`): the
    /// session's worker is woken when that matters to it (see
    /// `State::wrote`).
    fn wrote(&self, bytes: usize, output: bool) {
        self.wake_if(|state| state.wrote(bytes, output));
    }

    /// The writer waits for the client to take more (see `State::blocked`).
    fn blocked(&self) {
        self.wake_if(State::blocked);
    }

    fn wake_if(&self, due: impl FnOnce(&mut State) -> bool) {
        let waker = {
            let mut state = self.lock();
            if !due(&mut state) {
                return;
            }
            state.waker.clone()
        };
        if let Some(waker) = waker {
            waker.wake();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::signals;

    fn frame(len: usize) -> Arc<Vec<u8>> {
        Arc::new(vec![0; len])
    }

    /// Output of `len` frame bytes (at least its header's).
    fn output(len: usize) -> Output {
        text(len, b"")
    }

    /// An `Output` frame holding `data`, padded to `len` bytes when that is
    /// more than it takes. The padding (zeros) holds no token.
    fn text(len: usize, data: &[u8]) -> Output {
        let mut frame = encode_output_frame(0, data).unwrap();
        frame.resize(len.max(frame.len()), 0);
        Output {
            frame: Arc::new(frame),
        }
    }

    fn drain(outbox: &Outbox) -> Vec<(Kind, usize)> {
        let mut items = Vec::new();
        let state = outbox.lock();
        for item in &state.items {
            items.push((item.kind, item.bytes().len()));
        }
        items
    }

    #[test]
    fn output_that_waits_merges_with_the_output_it_continues() {
        // No socket: every frame waits for the writer.
        let outbox = Outbox::default();
        let at = |offset: u64, data: &[u8]| Output::new(offset, data).unwrap();
        assert!(outbox.push_control(frame(1)));
        let first = at(10, b"ab");
        assert_eq!(outbox.push_output(&first), Push::Queued);
        assert_eq!(outbox.push_output(&at(12, b"cd")), Push::Queued);
        assert_eq!(outbox.push_output(&at(14, b"")), Push::Queued);
        // Output that does not continue it is a frame of its own, and so
        // is output behind another kind of frame.
        assert_eq!(outbox.push_output(&at(20, b"x")), Push::Queued);
        assert!(outbox.push_query(frame(5)));
        assert_eq!(outbox.push_output(&at(21, b"y")), Push::Queued);
        let header = OUTPUT_HEADER;
        assert_eq!(
            drain(&outbox),
            vec![
                (Kind::Control, 1),
                (Kind::Output, header + 4),
                (Kind::Output, header + 1),
                (Kind::Query, 5),
                (Kind::Output, header + 1)
            ]
        );
        assert_eq!(outbox.lock().output_bytes, 3 * header + 6);
        // The frame another client's queue may share is left alone.
        assert_eq!(output_frame_parts(&first.frame), Some((10, &b"ab"[..])));
        // Up to MERGED_OUTPUT of output in one frame.
        let big = vec![b'z'; MERGED_OUTPUT - 2];
        assert_eq!(outbox.push_output(&at(100, &big)), Push::Queued);
        assert_eq!(
            outbox.push_output(&at(100 + big.len() as u64, b"12")),
            Push::Queued
        );
        assert_eq!(
            outbox.push_output(&at(102 + big.len() as u64, b"3")),
            Push::Queued
        );
        let queued = drain(&outbox);
        assert_eq!(
            &queued[queued.len() - 2..],
            [
                (Kind::Output, header + MERGED_OUTPUT),
                (Kind::Output, header + 1)
            ]
        );
        // Each a whole frame, whose length word counts the merged output.
        let mut outputs = Vec::new();
        outbox.close();
        while let Some(item) = outbox.next() {
            if item.kind == Kind::Output {
                let frame = &item.frame[..];
                let message = cherry_protocol::read_frame::<_, ServerMessage>(&mut &frame[..]);
                let Ok(Some(ServerMessage::Output { offset, data })) = message else {
                    panic!("not an output frame");
                };
                outputs.push((offset, data.len()));
            }
        }
        assert_eq!(
            outputs,
            [
                (10, 4),
                (20, 1),
                (21, 1),
                (100, MERGED_OUTPUT),
                (100 + MERGED_OUTPUT as u64, 1)
            ]
        );
    }

    #[test]
    fn a_client_that_takes_its_output_holds_the_session_back_while_too_much_waits() {
        let stall = Duration::from_secs(60);
        let outbox = Outbox::default();
        let (waker, woken) = Wake::pair().unwrap();
        outbox.set_waker(waker);
        let chunk = 64 * 1024;
        let mut offset = 0u64;
        let mut push = |outbox: &Outbox| {
            let output = Output::new(offset, &vec![b'x'; chunk]).unwrap();
            offset += chunk as u64;
            outbox.push_output(&output)
        };
        // Up to the high mark it holds nothing back.
        while outbox.lock().waiting() + chunk <= HOLD_HIGH_WATER {
            assert_eq!(push(&outbox), Push::Queued);
            assert_eq!(outbox.holds_back(stall), None);
        }
        assert_eq!(push(&outbox), Push::Queued);
        let waiting = outbox.lock().waiting();
        assert!(waiting > HOLD_HIGH_WATER, "{waiting}");
        // It can take no more for now.
        let (room, until) = outbox.holds_back(stall).expect("held back");
        assert_eq!(room, 0);
        assert!(until > Instant::now() + stall - Duration::from_secs(1));
        // Output the writer took from the queue waits until it is written.
        signals::drain(&woken);
        let mut item = outbox.next().unwrap();
        assert_eq!(outbox.holds_back(stall).map(|(room, _)| room), Some(0));
        assert!(!readable(&woken), "woken for nothing taken");
        // As the client takes it, less waits, and it can take that much
        // more; the session's worker is woken for every PACE_STEP it took.
        // It holds the session back down to the low mark, and the worker
        // hears when it stops.
        let (mut taken, mut steps) = (0, 0);
        let mut written = 0;
        loop {
            if written == item.bytes().len() {
                outbox.lock().writing = false;
                item = outbox.next().unwrap();
                written = 0;
            }
            let n = (item.bytes().len() - written).min(1024);
            written += n;
            taken += n;
            outbox.wrote(n, true);
            // The client takes no more for now.
            outbox.blocked();
            let left = outbox.lock().waiting();
            assert_eq!(left, waiting - taken);
            match outbox.holds_back(stall) {
                Some((room, _)) => {
                    assert_eq!(room, taken);
                    assert!(left > HOLD_LOW_WATER, "{left}");
                    if readable(&woken) {
                        signals::drain(&woken);
                        steps += 1;
                    }
                    assert_eq!(steps, taken / PACE_STEP, "after {taken} bytes");
                }
                None => {
                    assert!(left <= HOLD_LOW_WATER, "{left}");
                    assert!(readable(&woken), "the worker was not woken");
                    break;
                }
            }
        }
        // Never beyond the budget: output is held back long before.
        const { assert!(HOLD_HIGH_WATER + MERGED_OUTPUT < OUTPUT_BUDGET) };
    }

    #[test]
    fn a_client_that_takes_output_in_bursts_wakes_the_worker_per_burst() {
        let outbox = Outbox::default();
        let (waker, woken) = Wake::pair().unwrap();
        outbox.set_waker(waker);
        assert!(outbox.push_control(frame(1)));
        let big = Output::new(0, &vec![b'x'; 2 * HOLD_HIGH_WATER]).unwrap();
        assert_eq!(outbox.push_output(&big), Push::Queued);
        assert!(outbox.holds_back(Duration::from_secs(60)).is_some());
        outbox.next().unwrap();
        outbox.lock().writing = false;
        outbox.next().unwrap();
        // While it goes on taking output, the worker hears of it every
        // PACE_BURST, not every PACE_STEP.
        for _ in 0..PACE_BURST / 1024 - 1 {
            outbox.wrote(1024, true);
        }
        assert!(!readable(&woken), "woken mid-burst");
        outbox.wrote(1024, true);
        assert!(readable(&woken), "not woken after a long burst");
        signals::drain(&woken);
        // Once it takes no more for now, the worker hears of what it took,
        // if that is at least PACE_STEP.
        outbox.wrote(PACE_STEP - 1, true);
        outbox.blocked();
        assert!(!readable(&woken), "woken for less than a step");
        outbox.wrote(1, true);
        outbox.blocked();
        assert!(readable(&woken), "not woken for a step");
    }

    /// The writer takes `bytes` of what is queued, from the item it holds
    /// (`item`) on.
    fn take(outbox: &Outbox, item: &mut Option<(Item, usize)>, mut bytes: usize) {
        while bytes > 0 {
            let (current, written) = match item {
                Some((current, written)) if *written < current.bytes().len() => (current, written),
                _ => {
                    outbox.lock().writing = false;
                    *item = Some((outbox.next().unwrap(), 0));
                    continue;
                }
            };
            let n = bytes.min(current.bytes().len() - *written);
            *written += n;
            bytes -= n;
            outbox.wrote(n, current.waiting_output());
        }
    }

    #[test]
    fn output_already_on_its_way_waits_too_within_bounds() {
        let stall = Duration::from_secs(60);
        let outbox = Outbox::default();
        let chunk = 64 * 1024;
        let mut offset = 0;
        let mut push = |len: usize| {
            let output = Output::new(offset, &vec![b'x'; len]).unwrap();
            offset += len as u64;
            assert_eq!(outbox.push_output(&output), Push::Queued);
        };
        // Behind a reply: nothing is written at once.
        assert!(outbox.push_control(frame(1)));
        for _ in 0..9 {
            push(chunk);
        }
        // Beyond the high mark: it can take no more for now.
        let waiting = outbox.lock().waiting();
        assert!(waiting > HOLD_HIGH_WATER);
        assert_eq!(outbox.holds_back(stall).map(|(room, _)| room), Some(0));
        // As it takes output, it can take as much more: what reached it
        // beyond the high mark (the program's output already on its way)
        // waits as well, and the session goes on at its pace from there.
        let mut item = None;
        take(&outbox, &mut item, 1 + 100_000);
        assert_eq!(outbox.lock().waiting(), waiting - 100_000);
        assert_eq!(
            outbox.holds_back(stall).map(|(room, _)| room),
            Some(100_000)
        );
        // But no more than HOLD_SLACK beyond the high mark: beyond it, the
        // client must take the rest first.
        push(HOLD_SLACK);
        push(HOLD_SLACK);
        let waiting = outbox.lock().waiting();
        let over = waiting - (HOLD_HIGH_WATER + HOLD_SLACK);
        assert_eq!(outbox.holds_back(stall).map(|(room, _)| room), Some(0));
        take(&outbox, &mut item, over - 10);
        assert_eq!(outbox.holds_back(stall).map(|(room, _)| room), Some(0));
        take(&outbox, &mut item, 20);
        assert_eq!(outbox.holds_back(stall).map(|(room, _)| room), Some(10));
    }

    #[test]
    fn a_client_keeps_up_until_too_much_waits_and_paces_nothing_once_it_lags() {
        let stall = Duration::from_secs(60);
        let outbox = Outbox::default();
        assert_eq!(outbox.pacing(stall), (Pacing::KeepsUp, None));
        let at = |offset: usize, len: usize| Output::new(offset as u64, &vec![b'x'; len]).unwrap();
        let most = HOLD_HIGH_WATER - OUTPUT_HEADER;
        assert_eq!(outbox.push_output(&at(0, most)), Push::Queued);
        assert_eq!(outbox.pacing(stall).0, Pacing::KeepsUp);
        assert_eq!(outbox.push_output(&at(most, 1)), Push::Queued);
        let waiting = outbox.lock().waiting();
        assert!(matches!(
            outbox.pacing(stall).0,
            Pacing::Slow { room: 0, waiting: w, .. } if w == waiting
        ));
        // When it last took anything comes along.
        let before = Instant::now();
        outbox.lock().took(10);
        assert!(outbox.pacing(stall).1.is_some_and(|at| at >= before));
        // More than the low mark of it will still wait once it lags: the
        // rest of a frame its writer wrote in part, say.
        let rest = frame(HOLD_LOW_WATER * 2);
        {
            let mut state = outbox.lock();
            state.bytes += rest.len();
            state.rest_bytes += rest.len();
            state.items.push_front(Item {
                frame: rest,
                start: 0,
                kind: Kind::Rest,
                output: true,
                key: None,
                seq: 0,
            });
        }
        // Beyond its budget it lags, and paces nothing.
        assert_eq!(
            outbox.push_output(&at(most + 1, OUTPUT_BUDGET)),
            Push::Lagging
        );
        assert_eq!(outbox.pacing(stall).0, Pacing::Out);
        // Resynchronized, it starts afresh: it keeps up until more than
        // `HOLD_HIGH_WATER` waits again, with no room left over from before.
        outbox.take_superseded();
        assert!(outbox.push_snapshot(frame(100), None));
        assert!(outbox.lock().waiting() > HOLD_LOW_WATER);
        assert_eq!(outbox.pacing(stall).0, Pacing::KeepsUp);
    }

    #[test]
    fn a_slow_client_counts_as_taking_nothing_after_a_few_of_its_longest_waits() {
        let stall = Duration::from_secs(60);
        let outbox = Outbox::default();
        let big = Output::new(0, &vec![b'x'; HOLD_HIGH_WATER + 1]).unwrap();
        assert!(outbox.push_control(frame(1)));
        assert_eq!(outbox.push_output(&big), Push::Queued);
        let idle = |outbox: &Outbox, stall| match outbox.pacing(stall).0 {
            Pacing::Slow { since, idle, .. } => idle - since,
            other => panic!("{other:?}"),
        };
        // A client that took nothing yet: `IDLE_AFTER`, within its stall.
        assert_eq!(idle(&outbox, stall), IDLE_AFTER);
        assert_eq!(idle(&outbox, IDLE_AFTER / 2), IDLE_AFTER / 2);
        // A client that takes output in steps, with waits between them
        // (a slow terminal behind `cherry attach`): a few of its longest.
        let mut item = None;
        take(&outbox, &mut item, 1);
        std::thread::sleep(Duration::from_millis(120));
        take(&outbox, &mut item, 1);
        let waited = idle(&outbox, stall);
        assert!(
            (3 * Duration::from_millis(120)..3 * Duration::from_millis(400)).contains(&waited),
            "{waited:?}"
        );
        // A wait while nothing waited for it does not count, nor one for a
        // frame other than output (a reply, say).
        let left = outbox.lock().waiting();
        take(&outbox, &mut item, left);
        outbox.lock().writing = false;
        assert_eq!(outbox.pacing(stall).0, Pacing::KeepsUp);
        std::thread::sleep(Duration::from_millis(200));
        assert!(outbox.push_control(frame(1)));
        std::thread::sleep(Duration::from_millis(200));
        let big = Output::new(big.data().len() as u64, &vec![b'x'; HOLD_HIGH_WATER + 1]).unwrap();
        assert_eq!(outbox.push_output(&big), Push::Queued);
        let mut item = None;
        take(&outbox, &mut item, 2);
        assert_eq!(idle(&outbox, stall), waited);
    }

    #[test]
    fn the_longest_waits_are_those_of_the_last_two_windows() {
        let start = Instant::now();
        let ms = Duration::from_millis;
        let mut gaps = Gaps::default();
        assert_eq!(gaps.longest(start), Duration::ZERO);
        gaps.note(ms(300), start);
        gaps.note(ms(10), start + ms(500));
        assert_eq!(gaps.longest(start + ms(500)), ms(300));
        // A new window: the last one's longest is kept.
        gaps.note(ms(20), start + ms(1200));
        assert_eq!(gaps.longest(start + ms(1200)), ms(300));
        // Its last progress a window later: only the window it fell in.
        assert_eq!(gaps.longest(start + ms(2300)), ms(20));
        gaps.note(ms(30), start + ms(2300));
        assert_eq!(gaps.longest(start + ms(2300)), ms(30));
        // Nothing for two windows: nothing is kept.
        assert_eq!(gaps.longest(start + ms(4400)), Duration::ZERO);
        gaps.note(ms(5), start + ms(4400));
        assert_eq!(gaps.longest(start + ms(4400)), ms(5));
    }

    #[test]
    fn a_client_that_takes_over_pacing_lets_what_waits_wait_and_catches_up() {
        let stall = Duration::from_secs(60);
        let outbox = Outbox::default();
        let room = |outbox: &Outbox| outbox.holds_back(stall).map(|(room, _)| room);
        let mut offset = 0;
        let mut push = |len: usize| {
            let output = Output::new(offset, &vec![b'x'; len]).unwrap();
            offset += len as u64;
            assert_eq!(outbox.push_output(&output), Push::Queued);
        };
        // Behind a reply: nothing is written at once. Far behind: another
        // client paced the program.
        assert!(outbox.push_control(frame(1)));
        for _ in 0..8 {
            push(MERGED_OUTPUT);
        }
        let waiting = outbox.lock().waiting();
        assert!(waiting > PACE_WINDOW);
        assert_eq!(room(&outbox), Some(0));
        // The program now goes at its pace: as it takes output it can take
        // more at once, half as much, rather than only once all but
        // PACE_WINDOW of what waits was taken.
        outbox.lead();
        assert_eq!(outbox.lock().hold_limit, waiting);
        let mut item = None;
        take(&outbox, &mut item, 1 + 100_000);
        assert_eq!(room(&outbox), Some(50_000));
        // As the program goes on at that pace, what waits shrinks until no
        // more than PACE_WINDOW does; the program never stops meanwhile.
        let mut steps = 0;
        while outbox.lock().hold_limit > PACE_WINDOW {
            // Frames merge while they wait, so this fills it, but for a
            // header at most.
            push(room(&outbox).unwrap());
            let before = room(&outbox).unwrap();
            assert!(before <= OUTPUT_HEADER, "{before}");
            take(&outbox, &mut item, 64 * 1024);
            // Half as much (rounded up per write, less the header of a
            // frame that did not merge), and all of it once caught up.
            let gained = room(&outbox).unwrap() - before;
            let half = 32 * 1024;
            let expected = if outbox.lock().hold_limit > PACE_WINDOW {
                half - OUTPUT_HEADER - 2..=half
            } else {
                half..=2 * half
            };
            assert!(expected.contains(&gained), "{gained}");
            steps += 1;
            assert!(steps < 1000, "never caught up");
        }
        let left = outbox.lock().waiting();
        assert!(left <= PACE_WINDOW, "{left}");
        // Then it can take as much more as it takes.
        assert_eq!(room(&outbox), Some(PACE_WINDOW - left));
        take(&outbox, &mut item, 1000);
        assert_eq!(room(&outbox), Some(PACE_WINDOW - left + 1000));
        // What may keep waiting is bounded well within the budget.
        drop(item);
        let outbox = Outbox::default();
        assert!(outbox.push_control(frame(1)));
        let mut offset = 0;
        while outbox.lock().waiting() + MERGED_OUTPUT < OUTPUT_BUDGET {
            let output = Output::new(offset, &vec![b'x'; MERGED_OUTPUT]).unwrap();
            offset += MERGED_OUTPUT as u64;
            assert_eq!(outbox.push_output(&output), Push::Queued);
        }
        outbox.lead();
        assert_eq!(outbox.lock().hold_limit, LEAD_LIMIT);
        assert_eq!(room(&outbox), Some(0));
        // What waits beyond that goes first, at its full pace; then the
        // program goes on at half its pace.
        let mut item = None;
        let excess = outbox.lock().waiting() - LEAD_LIMIT;
        take(&outbox, &mut item, 1 + excess - 1000);
        assert_eq!(outbox.lock().hold_limit, LEAD_LIMIT);
        assert_eq!(room(&outbox), Some(0));
        take(&outbox, &mut item, 2000);
        assert_eq!(outbox.lock().hold_limit, LEAD_LIMIT - 500);
        assert_eq!(room(&outbox), Some(500));
        // A client that holds nothing back has nothing to keep waiting.
        let outbox = Outbox::default();
        outbox.lead();
        assert_eq!(outbox.lock().hold_limit, 0);
        assert_eq!(outbox.pacing(stall).0, Pacing::KeepsUp);
    }

    #[test]
    fn a_client_that_takes_nothing_holds_nothing_back_once_its_stall_ends() {
        let outbox = Outbox::default();
        let big = Output::new(0, &vec![b'x'; HOLD_HIGH_WATER + 1]).unwrap();
        assert_eq!(outbox.push_output(&big), Push::Queued);
        let stall = Duration::from_millis(100);
        assert!(outbox.holds_back(stall).is_some());
        std::thread::sleep(stall + Duration::from_millis(20));
        assert_eq!(outbox.holds_back(stall), None);
        // Taking some of it (the writer's) holds the session back again.
        outbox.lock().took(1);
        assert!(outbox.holds_back(stall).is_some());
        // A lagging client, and one that is gone, hold nothing back.
        let rest = Output::new(big.data().len() as u64, &vec![b'y'; OUTPUT_BUDGET]).unwrap();
        assert_eq!(outbox.push_output(&rest), Push::Lagging);
        assert_eq!(outbox.holds_back(stall), None);
        let outbox = Outbox::default();
        assert_eq!(outbox.push_output(&big), Push::Queued);
        outbox.close();
        assert_eq!(outbox.holds_back(stall), None);
    }

    /// Whether a wake socket has a wakeup waiting.
    fn readable(woken: &UnixStream) -> bool {
        let mut fd = libc::pollfd {
            fd: woken.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        unsafe { libc::poll(&mut fd, 1, 0) > 0 }
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
        assert_eq!(outbox.push_output(&output(50)), Push::Queued);
        assert_eq!(
            drain(&outbox),
            vec![(Kind::Control, 10), (Kind::Resync, 100), (Kind::Output, 50)]
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
            outbox.push_output(&text(40, b"ls\r\n\x1b]52;c;QUJD\x07")),
            Push::Queued
        );
        assert!(outbox.push_replacement(frame(100), false));
        assert_eq!(outbox.push_output(&output(50)), Push::Queued);
        assert!(outbox.push_replacement(frame(200), false));
        assert_eq!(
            drain(&outbox),
            vec![
                (Kind::Control, 1),
                (Kind::Output, 40),
                (Kind::Output, 50),
                (REFRESH, 200)
            ]
        );
        assert!(!outbox.is_lagging());
        assert!(!outbox.full_replacement_queued());
        // A full one is superseded only by another full one.
        assert!(outbox.push_replacement(frame(300), true));
        assert!(outbox.full_replacement_queued());
        assert!(outbox.push_replacement(frame(20), false));
        assert_eq!(outbox.push_output(&output(60)), Push::Queued);
        assert!(outbox.push_replacement(frame(400), true));
        assert_eq!(
            drain(&outbox),
            vec![
                (Kind::Control, 1),
                (Kind::Output, 40),
                (Kind::Output, 50),
                (Kind::Output, 60),
                (FULL, 400)
            ]
        );
        // Nor a resync, which the output after it does not continue.
        assert!(outbox.push_snapshot(frame(500), Some(text(70, b"\x07"))));
        assert_eq!(outbox.push_output(&output(80)), Push::Queued);
        assert!(outbox.push_replacement(frame(30), false));
        assert_eq!(
            drain(&outbox),
            vec![
                (Kind::Control, 1),
                (Kind::Resync, 500),
                (Kind::Carried, 70),
                (Kind::Output, 80),
                (REFRESH, 30)
            ]
        );
    }

    #[test]
    fn a_resync_carries_the_live_only_output_it_supersedes() {
        let outbox = Outbox::default();
        assert!(outbox.push_control(frame(1)));
        assert_eq!(
            outbox.push_output(&text(40, b"ls\r\n\x1b]52;c;QUJD\x07")),
            Push::Queued
        );
        assert!(outbox.push_replacement(frame(50), true));
        assert_eq!(
            outbox.push_output(&text(40, b"\x1b]9;done\x07 more")),
            Push::Queued
        );
        let carried = outbox.take_superseded();
        assert_eq!(carried, b"\x1b]52;c;QUJD\x07\x1b]9;done\x07");
        assert_eq!(drain(&outbox), vec![(Kind::Control, 1)]);
        assert!(outbox.push_snapshot(frame(100), Some(text(60, &carried))));
        assert_eq!(
            drain(&outbox),
            vec![(Kind::Control, 1), (Kind::Resync, 100), (Kind::Carried, 60)]
        );
        // Superseded in turn, the carried output is carried again.
        assert_eq!(outbox.push_output(&text(50, b"\x07")), Push::Queued);
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
        assert_eq!(outbox.push_output(&output(50)), Push::Queued);
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
                (Kind::Output, 50)
            ]
        );
        let mut written = Vec::new();
        outbox.close();
        outbox.write_all_to(&mut written);
        assert_eq!(written.len(), 11 + 1 + 100 + 20 + 12 + 13 + 14 + 50);
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

    fn bytes(text: &str) -> Arc<Vec<u8>> {
        Arc::new(text.as_bytes().to_vec())
    }

    /// Everything the writer sends until the outbox closes.
    fn written(outbox: &Outbox) -> Vec<u8> {
        let mut written = Vec::new();
        outbox.close();
        outbox.write_all_to(&mut written);
        written
    }

    #[test]
    fn a_sessions_latest_change_replaces_the_one_queued_in_its_place() {
        let outbox = Outbox::default();
        let changed = |id: &str| Some(EventKey::Changed(id.into()));
        assert!(outbox.push_control(bytes("ok|")));
        assert!(outbox.push_event(bytes("a1|"), changed("a"), &[]));
        assert!(outbox.push_event(bytes("bell|"), None, &[]));
        assert!(outbox.push_event(bytes("b1|"), changed("b"), &[]));
        assert!(outbox.push_control(bytes("pong|")));
        assert!(outbox.push_event(bytes("a2|"), changed("a"), &[]));
        assert!(outbox.push_event(bytes("p1|"), Some(EventKey::Progress("a".into())), &[]));
        assert!(outbox.push_event(bytes("p2|"), Some(EventKey::Progress("a".into())), &[]));
        let counted = |outbox: &Outbox| {
            let state = outbox.lock();
            (state.events, state.event_bytes)
        };
        assert_eq!(counted(&outbox), (4, "a2|bell|b1|p2|".len()));
        // Once written, a change is queued anew.
        assert_eq!(outbox.next().unwrap().frame.as_slice(), b"ok|");
        assert_eq!(outbox.next().unwrap().frame.as_slice(), b"a2|");
        assert!(outbox.push_event(bytes("a3|"), changed("a"), &[]));
        assert_eq!(written(&outbox), b"bell|b1|pong|p2|a3|");
        assert_eq!(counted(&outbox), (0, 0));
    }

    #[test]
    fn a_change_never_passes_its_sessions_addition_or_removal() {
        let outbox = Outbox::default();
        let changed = || Some(EventKey::Changed("a".into()));
        let seals = [
            EventKey::Changed("a".into()),
            EventKey::Progress("a".into()),
        ];
        assert!(outbox.push_event(bytes("changed 1|"), changed(), &[]));
        assert!(outbox.push_event(bytes("changed 2|"), changed(), &[]));
        assert!(outbox.push_event(bytes("removed|"), None, &seals));
        assert!(outbox.push_event(bytes("added|"), None, &seals));
        assert!(outbox.push_event(bytes("changed 3|"), changed(), &[]));
        assert!(outbox.push_event(bytes("changed 4|"), changed(), &[]));
        // Another session's are not held back.
        assert!(outbox.push_event(bytes("b 1|"), Some(EventKey::Changed("b".into())), &[]));
        assert!(outbox.push_event(bytes("removed b|"), None, &seals));
        assert!(outbox.push_event(bytes("b 2|"), Some(EventKey::Changed("b".into())), &[]));
        assert_eq!(
            written(&outbox),
            b"changed 2|removed|added|changed 4|b 2|removed b|"
        );
    }

    #[test]
    fn a_sessions_exit_comes_before_the_change_that_says_so() {
        let outbox = Outbox::default();
        let session = |state, exit_code| SessionInfo {
            id: "a".into(),
            name: "a".into(),
            cwd: "/".into(),
            command: vec!["sh".into()],
            cols: 80,
            rows: 24,
            state,
            pid: None,
            exit_code,
            attached: false,
            exit_signal: None,
            title: None,
            pwd: None,
            foreground: None,
            clients: 0,
            owner: None,
            tags: Default::default(),
            created_at: 0,
            alternate_screen: false,
            kitty_keyboard_flags: 0,
            application_cursor_keys: false,
            bracketed_paste: None,
            request_id: None,
            ended_by: None,
            holder_log: None,
        };
        let running = SessionEvent::Changed {
            session: session(cherry_protocol::SessionState::Running, None),
        };
        let exited = SessionEvent::Exited {
            id: "a".into(),
            exit_code: 3,
            signal: None,
            ended_by: None,
            holder_log: None,
        };
        let ended = SessionEvent::Changed {
            session: session(cherry_protocol::SessionState::Exited, Some(3)),
        };
        // All queued before the writer takes any of them.
        for event in [&running, &exited, &ended] {
            let (key, seals) = EventKey::of(event);
            let frame = encode_frame(&ServerMessage::Event {
                event: event.clone(),
            })
            .unwrap();
            assert!(outbox.push_event(Arc::new(frame), key, &seals));
        }
        let written = written(&outbox);
        let mut frames = written.as_slice();
        let mut events = Vec::new();
        while let Some(ServerMessage::Event { event }) =
            cherry_protocol::read_frame(&mut frames).unwrap()
        {
            events.push(event);
        }
        assert_eq!(events, [running, exited, ended]);
    }

    #[test]
    fn a_subscriber_that_falls_behind_gets_one_resync_instead_of_its_events() {
        let resync = resync_frame();
        let outbox = Outbox::default();
        assert!(outbox.push_control(bytes("ok|")));
        assert!(outbox.push_event(bytes("changed|"), Some(EventKey::Changed("a".into())), &[]));
        for _ in 1..EVENT_LIMIT {
            assert!(outbox.push_event(bytes("bell|"), None, &[]));
        }
        assert_eq!(outbox.lock().events, EVENT_LIMIT);
        // Replies and events are bounded apart.
        assert!(!outbox.backlogged());
        assert!(outbox.push_event(bytes("late|"), None, &[]));
        assert!(outbox.push_control(bytes("pong|")));
        // Nothing of the dropped events is left: a change is queued anew.
        assert!(outbox.push_event(
            bytes("changed again|"),
            Some(EventKey::Changed("a".into())),
            &[]
        ));
        assert_eq!(
            written(&outbox),
            [&b"ok|"[..], &resync, b"late|pong|changed again|"].concat()
        );
        // By bytes too, and an empty queue takes one event of any size.
        let outbox = Outbox::default();
        let big = Arc::new(vec![b'x'; EVENT_BYTES + 1]);
        assert!(outbox.push_event(big.clone(), None, &[]));
        assert!(outbox.push_event(bytes("next|"), None, &[]));
        assert_eq!(written(&outbox), [&resync[..], b"next|"].concat());
        // A replacement that grows past the bound as well, which follows the
        // resync.
        let outbox = Outbox::default();
        assert!(outbox.push_event(bytes("small|"), Some(EventKey::Changed("a".into())), &[]));
        assert!(outbox.push_event(big.clone(), Some(EventKey::Changed("a".into())), &[]));
        assert!(outbox.push_event(bytes("bell|"), None, &[]));
        assert!(outbox.push_event(bytes("large|"), Some(EventKey::Changed("a".into())), &[]));
        assert!(outbox.push_event(big.clone(), Some(EventKey::Changed("a".into())), &[]));
        assert_eq!(written(&outbox), [&resync[..], &big[..]].concat());
        // A closed or failed connection takes no more.
        assert!(!outbox.push_event(bytes("gone|"), None, &[]));
    }

    #[test]
    fn a_resync_is_followed_by_each_sessions_latest_progress() {
        let resync = resync_frame();
        let progress = |id: &str| Some(EventKey::Progress(id.into()));
        let seals = |id: &str| [EventKey::Changed(id.into()), EventKey::Progress(id.into())];
        let outbox = Outbox::default();
        assert!(outbox.push_event(bytes("a 1|"), progress("a"), &[]));
        assert!(outbox.push_event(bytes("b 1|"), progress("b"), &[]));
        assert!(outbox.push_event(bytes("a 2|"), progress("a"), &[]));
        assert!(outbox.push_event(bytes("changed|"), Some(EventKey::Changed("a".into())), &[]));
        // A removed session's is not.
        assert!(outbox.push_event(bytes("c 1|"), progress("c"), &[]));
        assert!(outbox.push_event(bytes("removed c|"), None, &seals("c")));
        while outbox.lock().events < EVENT_LIMIT {
            assert!(outbox.push_event(bytes("bell|"), None, &[]));
        }
        assert!(outbox.push_event(bytes("late|"), None, &[]));
        // Kept in their order, and replaced in their place.
        assert!(outbox.push_event(bytes("b 2|"), progress("b"), &[]));
        assert_eq!(written(&outbox), [&resync[..], b"a 2|b 2|late|"].concat());
        // A report that puts the subscriber behind replaces its session's.
        let outbox = Outbox::default();
        let big = Arc::new(vec![b'x'; EVENT_BYTES]);
        assert!(outbox.push_event(bytes("a 1|"), progress("a"), &[]));
        assert!(outbox.push_event(bytes("b 1|"), progress("b"), &[]));
        assert!(outbox.push_event(bytes("bell|"), None, &[]));
        assert!(outbox.push_event(big.clone(), progress("a"), &[]));
        assert_eq!(written(&outbox), [&resync[..], b"b 1|", &big[..]].concat());
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

    /// An outbox that writes to one end of a socket pair, nonblocking as a
    /// connection's is; the other end.
    fn connected() -> (Outbox, UnixStream) {
        let (ours, theirs) = UnixStream::pair().unwrap();
        ours.set_nonblocking(true).unwrap();
        let outbox = Outbox::default();
        outbox.set_socket(ours);
        theirs.set_nonblocking(true).unwrap();
        (outbox, theirs)
    }

    /// What arrived at `peer` so far.
    fn arrived(peer: &mut UnixStream) -> Vec<u8> {
        let mut received = Vec::new();
        let mut buffer = [0u8; 65536];
        loop {
            match std::io::Read::read(peer, &mut buffer) {
                Ok(0) => return received,
                Ok(n) => received.extend_from_slice(&buffer[..n]),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => return received,
                Err(error) => panic!("{error}"),
            }
        }
    }

    #[test]
    fn frames_nothing_waits_ahead_of_go_out_without_the_writer() {
        let (outbox, mut peer) = connected();
        let first = text(0, b"out");
        assert_eq!(outbox.push_output(&first), Push::Queued);
        assert!(outbox.push_control(Arc::new(b"ctl".to_vec())));
        assert!(outbox.push_query(Arc::new(b"qry".to_vec())));
        assert!(outbox.push_resized(Arc::new(b"rsz".to_vec())));
        // Written at once, in order; nothing is left for a writer thread.
        assert_eq!(
            arrived(&mut peer),
            [&first.frame[..], b"ctlqryrsz"].concat()
        );
        assert!(drain(&outbox).is_empty());
        assert_eq!(outbox.written(), first.frame.len() as u64 + 9);
        // While the writer holds an item, frames queue behind it.
        outbox.lock().writing = true;
        assert!(outbox.push_control(Arc::new(b"later".to_vec())));
        assert_eq!(drain(&outbox), vec![(Kind::Control, 5)]);
        assert!(arrived(&mut peer).is_empty());
        outbox.lock().writing = false;
        // And behind anything queued.
        assert_eq!(outbox.push_output(&text(40, b"")), Push::Queued);
        assert_eq!(drain(&outbox), vec![(Kind::Control, 5), (Kind::Output, 40)]);
    }

    #[test]
    fn the_rest_of_a_frame_written_in_part_goes_first_and_is_never_dropped() {
        let (outbox, mut peer) = connected();
        // Far more than the socket takes at once.
        let big: Vec<u8> = (0..8 * 1024 * 1024).map(|i| (i % 251) as u8).collect();
        let first = Output {
            frame: Arc::new(big.clone()),
        };
        assert_eq!(outbox.push_output(&first), Push::Queued);
        let queued = drain(&outbox);
        assert_eq!(queued.len(), 1);
        assert_eq!(queued[0].0, Kind::Rest);
        let sent = big.len() - queued[0].1;
        assert!(sent > 0, "part of it was written at once");
        assert_eq!(outbox.written(), sent as u64);
        assert_eq!(outbox.lock().bytes, big.len() - sent);
        // The rest is not a copy: it shares the frame.
        assert!(Arc::ptr_eq(&outbox.lock().items[0].frame, &first.frame));
        // Output behind it that exceeds the budget is dropped, the rest is
        // not; a resync keeps it ahead of its snapshot.
        assert_eq!(
            outbox.push_output(&output(OUTPUT_BUDGET - 10)),
            Push::Queued
        );
        assert_eq!(outbox.push_output(&output(100)), Push::Lagging);
        assert_eq!(drain(&outbox)[0].0, Kind::Rest);
        assert!(outbox.push_snapshot(frame(7), None));
        assert_eq!(
            drain(&outbox)
                .iter()
                .map(|(kind, _)| *kind)
                .collect::<Vec<_>>(),
            vec![Kind::Rest, Kind::Resync]
        );
        // The writer sends the rest, then the snapshot: the peer gets whole
        // frames in order.
        // The writer waits for room in the nonblocking socket.
        let writer = outbox.lock().socket.as_ref().unwrap().try_clone().unwrap();
        outbox.close();
        let reader = std::thread::spawn(move || {
            let mut all = Vec::new();
            peer.set_nonblocking(false).unwrap();
            std::io::Read::read_to_end(&mut peer, &mut all).unwrap();
            all
        });
        outbox.write_all_to(&writer);
        writer.shutdown(std::net::Shutdown::Both).unwrap();
        let all = reader.join().unwrap();
        assert_eq!(all.len(), big.len() + 7);
        assert!(all[..big.len()] == big[..], "the frame arrived whole");
        assert_eq!(&all[big.len()..], &[0; 7]);
    }

    #[test]
    fn a_failed_write_ends_the_connection() {
        let (outbox, peer) = connected();
        drop(peer);
        assert_eq!(outbox.push_output(&output(3)), Push::Gone);
        assert!(outbox.is_dead());
        assert!(!outbox.push_control(frame(1)));
    }
}
