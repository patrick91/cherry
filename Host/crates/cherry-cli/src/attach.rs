//! The interactive attachment: terminal input to the host, host output to the
//! terminal, with a local renderer for windows that differ from the shared grid.
//!
//! When the connection to the host is lost while the session may still run
//! (its end of file, a failed read or write, a host that went silent, a
//! daemon that crashed, restarted or made way for a newer one), the
//! attachment keeps its terminal (raw mode, the screen, the renderer's copy)
//! and connects again for `RECONNECT_WINDOW`: at once, then with backoff.
//! Once attached again it starts over from the host's new snapshot and
//! output offset. It never connects again after the session exited, another
//! client took over, a detach, or a failure that connecting again cannot
//! resolve: another host identity, a protocol version this cherry cannot use
//! or replace, or a session the host no longer has.
//!
//! A reattachment lost again within `RECONNECT_HEALTHY` continues the same
//! reconnection: the window still counts from its first loss and the backoff
//! goes on, so a host that drops every attachment is not attached to in a
//! loop. Each attempt runs on a thread of its own, so the terminal is read
//! meanwhile, and may take `RECONNECT_ATTEMPT` (`RECONNECT_ATTEMPT_SSH` over
//! ssh) to connect, then as long for each answer, so one that hangs leaves
//! time for the next. What ssh, or a host started to reconnect, prints never
//! reaches the screen; its last line goes into the message if the
//! attachment gives up.
//!
//! Input is never sent twice, and never sent blind. What the lost connection
//! had not delivered is dropped with it, since the host may or may not have
//! queued it. Terminal input typed while reconnecting is discarded, with a
//! notice on the screen: the screen it was typed at is stale, and the program
//! may be in another state (or another program in front) once the attachment
//! is back; the terminal's reports from then would be stale too. The detach
//! key and end of input still detach. A paste is never cut into keystrokes:
//! the rest of a paste the terminal began before the attachment was back
//! (its start went with the lost connection, or came while reconnecting) is
//! discarded too, until its end marker (or until the terminal sends nothing
//! for `PASTE_TAIL_WAIT`), since without its start the program would take it
//! as typed, and run each line of it. A paste that the lost connection left
//! open in the session (its start marker was written to the connection,
//! and its end was not) is then ended, its end marker sent first, when the
//! session still has bracketed paste on, so that the program does not take
//! what is typed next as pasted.
//!
//! Input that is not a terminal (a pipe or a file) has no one watching what
//! arrived. Once some of it went to the lost connection, the attachment ends
//! as disconnected rather than go on with a part possibly missing; before
//! that, it is not read while reconnecting and continues once reattached.
use crate::{
    input::{DetachInput, DetachKey, Leftover, DEVICE_ATTRIBUTES, PASTE_END, PASTE_START},
    is_unresolvable, message_kind,
    passthrough::Passthrough,
    status::{Live, StatusFile},
    sys::{self, interrupted, poll, pollfd, read_some, set_nonblocking},
    timing::timing,
    transport::{is_lost, lost, Transport, RPC_TIMEOUT, SSH_TAIL_WAIT},
    unexpected, unresolvable,
};
use anyhow::{anyhow, bail, Context, Result};
use cherry_protocol::{
    error_code, valid_size, ClientMessage, ServerMessage, DEFAULT_COLS, DEFAULT_ROWS,
    MAX_INPUT_BYTES,
};
use std::{
    borrow::Cow,
    collections::VecDeque,
    io::{self, Write},
    os::{
        fd::{AsRawFd, RawFd},
        unix::net::UnixStream,
    },
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};

/// Terminal input is queued for the host while less than this is waiting
/// to be sent. Beyond it the terminal is read only to see the detach key.
pub const INPUT_HIGH_WATER: usize = 1024 * 1024;
/// How much input read beyond that may wait to be queued (see `Overflow`).
const INPUT_OVERFLOW: usize = 64 * 1024;
/// Coalesce SIGWINCH bursts (window drags) into at most one resize per period.
const RESIZE_COALESCE: Duration = Duration::from_millis(50);
/// After requesting a new grid size, wait this long for the host's
/// replacement snapshot before painting the new window size from the local
/// copy. When this client sets the grid, the snapshot switches straight to the
/// new size without a viewport in between (whose modes() would, for example,
/// make the terminal report focus again).
pub const GRID_WAIT: Duration = Duration::from_millis(300);
/// Upper bound on one poll, which also bounds how late a signal that arrives
/// just before poll() is noticed.
const MAX_WAIT: Duration = Duration::from_millis(250);
const RENDER_SCROLLBACK_BYTES: usize = 1024 * 1024;
/// A keyboard detach waits this long at most for the host's confirmation.
const KEY_DETACH_WAIT: Duration = Duration::from_secs(2);
/// On leaving, how long the terminal may take to answer the query written
/// after the reset (see `read_reports`). The answer ends the wait, so only a
/// terminal that never answers pays it in full; one behind a slow link or a
/// backlog of output answers late.
pub const REPORT_WAIT: Duration = Duration::from_secs(3);
/// Terminal input set aside while detaching, at most.
const MAX_SET_ASIDE: usize = 64 * 1024;
/// End of input (piped stdin) waits for the host's confirmation that
/// everything before it was queued for the session while that input keeps
/// moving, and gives up after this long without progress. A host that
/// stopped reading because the program is not reading its input reads the
/// Detach only when the program catches up, perhaps never.
pub const DETACH_WAIT: Duration = Duration::from_secs(5);
/// How long an attachment that lost its connection keeps trying to connect
/// again, counted from the loss; then it ends as disconnected.
pub const RECONNECT_WINDOW: Duration = Duration::from_secs(30);
/// The first attempt to connect again is immediate; after it the next waits
/// this long, doubling up to `RECONNECT_MAX_DELAY`.
const RECONNECT_FIRST_DELAY: Duration = Duration::from_millis(250);
const RECONNECT_MAX_DELAY: Duration = Duration::from_secs(2);
/// A reattachment lost within this long continues the reconnection it ended
/// (its window and backoff); one that lasted longer starts a new one.
pub const RECONNECT_HEALTHY: Duration = Duration::from_secs(10);
/// How long one attempt to connect again may take to connect (starting a
/// host and saying Hello included), and then wait for each answer. Over ssh
/// connecting takes longer (`RECONNECT_ATTEMPT_SSH`; ssh's own
/// ConnectTimeout is 10 s).
pub const RECONNECT_ATTEMPT: Duration = Duration::from_secs(5);
pub const RECONNECT_ATTEMPT_SSH: Duration = Duration::from_secs(15);
/// Once reattached, the rest of a paste the terminal began before is
/// discarded until its end marker, or until the terminal sends nothing for
/// this long: a paste arrives without pauses.
pub const PASTE_TAIL_WAIT: Duration = Duration::from_secs(1);
/// Painted over the top line, once per reconnection, when terminal input
/// (keys, or reports such as focus changes) is discarded while
/// reconnecting: it ends an unfinished sequence and a
/// synchronized update the lost output left open, then saves and restores
/// the cursor (with its pen and character sets) around the line. The host's
/// new snapshot replaces the screen.
const RECONNECT_NOTICE: &[u8] =
    b"\x18\x1b[?2026l\x1b7\x1b(B\x0f\x1b[1;1H\x1b[0;7m cherry: reconnecting; input is discarded \x1b[0m\x1b[K\x1b8";

pub enum Outcome {
    /// The host confirmed the detach.
    Detached,
    /// The host did not confirm the detach; the message says why. The
    /// connection is dropped, so the host discards input not yet delivered
    /// to the session.
    DetachedUnconfirmed(String),
    Exited {
        code: u32,
        signal: Option<i32>,
    },
    TakenOver(String),
}

/// Connects again, for an attachment that lost its connection.
pub struct Reconnect<'a> {
    /// Connect the slot to the host and say Hello, giving up at the
    /// deadline, on the attempt's own thread. The caller pins the host
    /// identity; an `Unresolvable` failure ends the reconnection, any other
    /// is retried.
    pub connect: &'a mut (dyn FnMut(&mut Option<Transport>, Instant) -> Result<()> + Send),
    /// How long one attempt may take to connect, and then wait for each
    /// answer (`RECONNECT_ATTEMPT`).
    pub attempt: Duration,
}

pub fn attach(
    slot: &mut Option<Transport>,
    id: &str,
    takeover: bool,
    detach_key: DetachKey,
    status: &mut StatusFile,
    reconnect: &mut Reconnect,
) -> Result<Outcome> {
    let physical = physical_size();
    let sent_size = protocol_size(physical);
    let first = request_attach(
        slot.as_mut().expect("connected"),
        id,
        sent_size,
        takeover,
        RPC_TIMEOUT,
    )?;
    status.attached = true;
    // Dropped in reverse on every exit: the terminal reset is written, and
    // the reports the terminal still sends are read, while its input is
    // raw; then the mode is restored. Each step has its own short deadline.
    let terminal = RawTerminal::enter(libc::STDIN_FILENO)?;
    let mut output = TerminalOutput::new(libc::STDOUT_FILENO, terminal.raw_input())?;
    let mut renderer = Renderer::new(physical);
    let result = Attachment {
        id,
        output: &mut output,
        renderer: &mut renderer,
        status,
        input: DetachInput::new(detach_key),
        stdin_is_file: sys::never_waits(libc::STDIN_FILENO),
        stdin_is_terminal: unsafe { libc::isatty(libc::STDIN_FILENO) } == 1,
        stdin_open: true,
        buffer: vec![0u8; MAX_INPUT_BYTES],
        connected_at: Instant::now(),
        streak: None,
        terminal_paste: PasteMarkers::default(),
        paste_tail: None,
    }
    .run(slot, reconnect, first, sent_size);
    // Before the reset changes the copy's modes.
    output.reporting = renderer.reporting();
    output.reset = renderer.detach_reset();
    result
}

/// The host's answer to an Attach: the grid, the output offset the snapshot
/// stands for, and the snapshot.
struct Snapshot {
    canonical: (u16, u16),
    offset: u64,
    bytes: Vec<u8>,
}

/// The host answered an Attach with an error.
#[derive(Debug)]
struct Refused {
    code: String,
    message: String,
}

impl std::fmt::Display for Refused {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "host rejected request ({}): {}",
            self.code, self.message
        )
    }
}

impl std::error::Error for Refused {}

/// Attach at `size` and wait for the snapshot, as long as something arrives
/// every `idle`.
fn request_attach(
    transport: &mut Transport,
    id: &str,
    size: (u16, u16),
    takeover: bool,
    idle: Duration,
) -> Result<Snapshot> {
    transport.send(&ClientMessage::Attach {
        id: id.into(),
        cols: size.0,
        rows: size.1,
        takeover,
        // A query written to the output is answered on the input only when
        // both are one terminal.
        answers_queries: unsafe { libc::isatty(libc::STDOUT_FILENO) } == 1
            && same_terminal(libc::STDIN_FILENO, libc::STDOUT_FILENO),
    })?;
    // The host expects heartbeats from its acknowledgement on, which can be
    // long before a large snapshot has arrived.
    transport.start_heartbeat();
    match transport.receive(idle)? {
        ServerMessage::Attached {
            session,
            offset,
            snapshot,
            ..
        } if session.id == id => Ok(Snapshot {
            canonical: (session.cols, session.rows),
            offset,
            bytes: snapshot,
        }),
        ServerMessage::Error { code, message } => Err(Refused { code, message }.into()),
        message => {
            unexpected("attached session", message)?;
            unreachable!()
        }
    }
}

/// What lasts as long as the attachment, across connections.
struct Attachment<'a> {
    id: &'a str,
    output: &'a mut TerminalOutput,
    /// Outlives the attachment, so the caller can derive the terminal reset
    /// from the final screen.
    renderer: &'a mut Renderer,
    status: &'a mut StatusFile,
    input: DetachInput,
    stdin_is_file: bool,
    stdin_is_terminal: bool,
    stdin_open: bool,
    buffer: Vec<u8>,
    /// When the current connection attached.
    connected_at: Instant,
    /// The reconnection the last lost connection belonged to, if any.
    streak: Option<Streak>,
    /// Whether the terminal is sending a paste, from all its input, sent or
    /// discarded.
    terminal_paste: PasteMarkers,
    /// The rest of a paste the terminal began before this connection is
    /// being discarded: since when, or since the last of it arrived.
    paste_tail: Option<Instant>,
}

/// One reconnection: from a loss after a connection that lasted
/// `RECONNECT_HEALTHY`, through the reattachments that were lost again
/// sooner. Its window counts from its first loss, and its backoff goes on
/// from attempt to attempt, reattachments included.
struct Streak {
    since: Instant,
    /// The wait before the next attempt: none before the first.
    delay: Duration,
    /// Why the last attempt failed, or that its reattachment was lost soon.
    failure: Option<anyhow::Error>,
}

impl Streak {
    fn new(since: Instant) -> Self {
        Self {
            since,
            delay: Duration::ZERO,
            failure: None,
        }
    }

    /// An attempt ended: the next one waits longer.
    fn back_off(&mut self) {
        self.delay = if self.delay.is_zero() {
            RECONNECT_FIRST_DELAY
        } else {
            (self.delay * 2).min(RECONNECT_MAX_DELAY)
        };
    }
}

/// What belongs to one connection to the host.
struct Connection {
    /// The offset the next output starts at.
    offset: u64,
    /// The grid size last requested.
    sent_size: (u16, u16),
    overflow: Overflow,
    resize_at: Option<Instant>,
    awaiting_grid: Option<((u16, u16), Instant)>,
    detach: Option<Detaching>,
}

enum Reconnected {
    Attached(Box<Reattached>),
    /// Detached (the detach key or end of input) while reconnecting.
    Ended(Outcome),
}

/// A connection attached again.
struct Reattached {
    transport: Transport,
    snapshot: Snapshot,
    /// The grid size requested.
    size: (u16, u16),
    /// The window's size then.
    physical: (u16, u16),
}

/// How an attempt to connect again ended.
enum Attempted {
    Done(Result<Box<Reattached>>),
    /// Detached (the detach key or end of input) meanwhile.
    Detached,
}

/// What waiting while reconnecting ended with.
enum Waited {
    /// Nothing yet.
    Pending,
    /// The attempt running meanwhile ended.
    Woken,
    /// The detach key or the end of terminal input.
    Detached,
}

impl Attachment<'_> {
    fn run(
        &mut self,
        slot: &mut Option<Transport>,
        reconnect: &mut Reconnect,
        first: Snapshot,
        sent_size: (u16, u16),
    ) -> Result<Outcome> {
        let (mut snapshot, mut sent_size) = (first, sent_size);
        // A paste the lost connection left open in the session, still to be
        // ended.
        let mut open_paste = false;
        loop {
            let transport = slot.as_mut().expect("connected");
            let mut connection = None;
            let result = match self.start(transport, snapshot, sent_size) {
                Err(error) => Err(error),
                Ok(started) => {
                    let connection = connection.insert(started);
                    let open = std::mem::take(&mut open_paste) && self.renderer.bracketed_paste();
                    connection.overflow = Overflow::new(open);
                    // The terminal is still sending a paste it began before:
                    // its rest is discarded, and the paste is ended after it.
                    self.paste_tail =
                        (self.stdin_is_terminal && self.terminal_paste.open).then(Instant::now);
                    let ended = if open && self.paste_tail.is_none() {
                        connection.overflow.forward(transport, PASTE_END)
                    } else {
                        Ok(())
                    };
                    ended.and_then(|()| self.attached(transport, connection))
                }
            };
            let lost = match result {
                Ok(outcome) => return Ok(outcome),
                // A lost connection while detaching ends the detach (see
                // `attached`); other failures are final.
                Err(error)
                    if !is_lost(&error)
                        || connection.as_ref().is_some_and(|c| c.detach.is_some()) =>
                {
                    return Err(error)
                }
                Err(error) => error,
            };
            let mut overflow = connection.map(|connection| connection.overflow);
            if let Some(overflow) = overflow.as_mut() {
                open_paste = overflow.paste_left_open(transport);
            }
            let forwarded = overflow.is_some_and(|o| o.forwarded);
            if forwarded && !self.stdin_is_terminal && !timing().reconnect_window.is_zero() {
                return Err(anyhow!("{lost:#}; the attachment does not connect again, since input it read from a pipe or a file and sent before the loss may not have reached the session"));
            }
            match self.reconnect(slot, reconnect, lost)? {
                Reconnected::Attached(reattached) => {
                    *slot = Some(reattached.transport);
                    snapshot = reattached.snapshot;
                    sent_size = reattached.size;
                    self.renderer.physical = reattached.physical;
                }
                Reconnected::Ended(outcome) => return Ok(outcome),
            }
        }
    }

    /// Paint a connection's first snapshot, which the connection's output
    /// continues. From then on the screen shows the session, and what ssh
    /// prints is kept off it.
    fn start(
        &mut self,
        transport: &mut Transport,
        snapshot: Snapshot,
        sent_size: (u16, u16),
    ) -> Result<Connection> {
        transport.silence_stderr();
        self.connected_at = Instant::now();
        let write = self.renderer.replace(snapshot.canonical, &snapshot.bytes)?;
        drop(snapshot.bytes);
        self.output.write_all(&write, transport)?;
        self.publish(false);
        Ok(Connection {
            offset: snapshot.offset,
            sent_size,
            overflow: Overflow::default(),
            resize_at: None,
            awaiting_grid: None,
            detach: None,
        })
    }

    /// Write the status file's live state, when it changed.
    fn publish(&mut self, reconnecting: bool) {
        self.status.live(Live {
            viewport: self.renderer.viewport(),
            reconnecting,
        });
    }

    /// The attachment on one connection: until it ends, or until the
    /// connection is lost (an error that `is_lost`).
    fn attached(
        &mut self,
        transport: &mut Transport,
        connection: &mut Connection,
    ) -> Result<Outcome> {
        let id = self.id;
        let Connection {
            offset,
            sent_size,
            overflow,
            resize_at,
            awaiting_grid,
            detach,
        } = connection;
        loop {
            interrupted()?;
            let now = Instant::now();
            if detach.is_none() {
                overflow.release(transport)?;
                if self
                    .paste_tail
                    .is_some_and(|since| now >= since + timing().paste_tail_wait)
                {
                    self.end_paste_tail(transport, overflow)?;
                }
                let expired = self.input.expire(now);
                self.forward_input(transport, overflow, &expired.data)?;
                if expired.detach {
                    *detach = Some(queue_detach(transport, overflow, KEY_DETACH_WAIT, false)?);
                }
            }
            if sys::take_resize() && resize_at.is_none() {
                *resize_at = Some(now + RESIZE_COALESCE);
            }
            if resize_at.is_some_and(|at| now >= at) {
                *resize_at = None;
                let physical = physical_size();
                let size = protocol_size(physical);
                // The host reads nothing after Detach; the window is repainted
                // from the local copy instead.
                if size != *sent_size && detach.is_none() {
                    transport.queue(&ClientMessage::Resize {
                        cols: size.0,
                        rows: size.1,
                    })?;
                    *sent_size = size;
                    *awaiting_grid = Some((physical, now + timing().grid_wait));
                } else if let Some((awaited, _)) = awaiting_grid.as_mut() {
                    // The grid change requested before is still on its way (a
                    // terminal can signal one resize several times): the window
                    // follows its snapshot, or the copy once the wait ends.
                    *awaited = physical;
                } else {
                    self.output
                        .write_all(&self.renderer.resize_physical(physical)?, transport)?;
                }
            }
            if let Some((physical, at)) = *awaiting_grid {
                if now >= at {
                    // The shared grid did not follow this window (another client
                    // is smaller, or it is beyond the protocol limit).
                    *awaiting_grid = None;
                    self.output
                        .write_all(&self.renderer.resize_physical(physical)?, transport)?;
                }
            }
            transport.heartbeat(now)?;
            // Drain buffered frames before polling so a snapshot and live output in
            // one read cannot leave the live bytes waiting for another network event.
            while let Some(message) = transport.next_message()? {
                match message {
                    ServerMessage::Output { offset: next, data } => {
                        check_output_offset(offset, next, data.len())?;
                        let write = self.renderer.output(&data)?;
                        if !write.is_empty() {
                            self.output.write_all(&write, transport)?;
                        }
                    }
                    // Queries the host leaves to this client's terminal; its
                    // replies arrive as input. Once detaching, that input belongs
                    // to the local shell, so a reply could not reach the program.
                    ServerMessage::Query { data } => {
                        if detach.is_none() {
                            let write = self.renderer.query(&data)?;
                            self.output.write_all(&write, transport)?;
                        }
                    }
                    // A replacement snapshot (shared size change or resync after
                    // this client fell behind): output resumes at its offset.
                    ServerMessage::Attached {
                        session,
                        offset: next,
                        snapshot,
                        ..
                    } if session.id == id => {
                        *offset = next;
                        if let Some((physical, _)) = awaiting_grid.take() {
                            self.renderer.physical = physical;
                        }
                        self.output.write_all(
                            &self
                                .renderer
                                .replace((session.cols, session.rows), &snapshot)?,
                            transport,
                        )?;
                    }
                    ServerMessage::Exit {
                        id: exited,
                        exit_code,
                        signal,
                    } if exited == id => {
                        paint(self.renderer, self.output, transport)?;
                        return Ok(Outcome::Exited {
                            code: exit_code,
                            signal,
                        });
                    }
                    // The host answered a Ping sent behind earlier input, or
                    // noted that the program consumed input it held back.
                    ServerMessage::Pong => {
                        if let Some(detach) = detach.as_mut() {
                            detach.progressed();
                        }
                    }
                    ServerMessage::Ok if detach.is_some() => {
                        paint(self.renderer, self.output, transport)?;
                        return Ok(Outcome::Detached);
                    }
                    // Events go only to subscribed connections and screen text
                    // only to whoever asked for it; an attachment does neither.
                    ServerMessage::Event { .. } | ServerMessage::ScreenText { .. } => {}
                    ServerMessage::Error { code, message } => match code.as_str() {
                        // The shared size or a replacement snapshot could not be
                        // produced; the attachment itself continues.
                        error_code::RESIZE_FAILED | error_code::SNAPSHOT_FAILED => {}
                        error_code::TAKEN_OVER => {
                            paint(self.renderer, self.output, transport)?;
                            return Ok(Outcome::TakenOver(message));
                        }
                        _ => {
                            paint(self.renderer, self.output, transport)?;
                            bail!("host rejected request ({code}): {message}");
                        }
                    },
                    message => {
                        paint(self.renderer, self.output, transport)?;
                        bail!(
                            "expected session output, received {}",
                            message_kind(&message)
                        );
                    }
                }
            }
            paint(self.renderer, self.output, transport)?;
            self.publish(false);
            // A host that stopped reading decides the outcome by what it sent
            // before closing: its Ok, a takeover notice, or nothing.
            transport.write_ready()?;
            if detach.is_none() {
                // Those writes (and the ones made while terminal output waited)
                // may have made room for the input waiting beyond the mark. Once
                // queued it has the transport polled; left waiting, nothing but
                // new input or a deadline would end the poll.
                overflow.release(transport)?;
            }
            let now = Instant::now();
            let stalled = transport.stalled_for(now);
            let heartbeat_timeout = timing().heartbeat_timeout;
            // While detaching, the detach wait is the limit.
            if detach.is_none() && stalled >= heartbeat_timeout {
                return Err(lost(format!(
                    "the host accepted and sent nothing for {} s; the connection appears to be dead{}. The session may still be running on the host",
                    stalled.as_secs(),
                    ssh_said(transport)
                )));
            }
            if transport.closed_deadline().is_some_and(|at| now >= at) {
                if detach.is_some() {
                    return Ok(Outcome::DetachedUnconfirmed(
                        "detached, but the host stopped reading the connection without confirming the detach; input not yet delivered to the session may have been discarded".into(),
                    ));
                }
                return Err(lost(connection_lost(id, transport)));
            }
            // The host confirms with Ok once earlier input was queued for the
            // session; it cannot while the session is not consuming input.
            if let Some(detach) = detach.as_ref() {
                if now >= detach.deadline(transport) {
                    return Ok(Outcome::DetachedUnconfirmed(detach.gave_up()));
                }
            }
            // Once detaching, terminal input belongs to the local shell: it is
            // set aside without the terminal's reports (see `Leftover`).
            let read_limit = match detach.as_ref() {
                _ if !self.stdin_open => 0,
                None => overflow.room(transport, &self.input).min(self.buffer.len()),
                Some(_) if self.output.sets_input_aside() => self.buffer.len(),
                Some(_) => 0,
            };
            let read_stdin = read_limit > 0;
            // Input waits beyond the mark only while the transport is polled.
            debug_assert!(
                detach.is_some()
                    || overflow.waiting.is_empty()
                    || transport.pending() >= timing().input_high_water
            );
            let mut fds = [
                pollfd(transport.read_fd(), libc::POLLIN),
                pollfd(
                    if transport.pending() > 0 {
                        transport.write_fd()
                    } else {
                        -1
                    },
                    libc::POLLOUT,
                ),
                pollfd(
                    if read_stdin && !self.stdin_is_file {
                        libc::STDIN_FILENO
                    } else {
                        -1
                    },
                    libc::POLLIN,
                ),
            ];
            let wait = if read_stdin && self.stdin_is_file {
                Duration::ZERO
            } else {
                let mut deadline = now + MAX_WAIT;
                for candidate in [
                    detach
                        .is_none()
                        .then(|| self.input.next_deadline())
                        .flatten(),
                    detach
                        .is_none()
                        .then(|| {
                            self.paste_tail
                                .map(|since| since + timing().paste_tail_wait)
                        })
                        .flatten(),
                    *resize_at,
                    awaiting_grid.as_ref().map(|(_, at)| *at),
                    transport.next_ping(),
                    detach.as_ref().map(|detach| detach.deadline(transport)),
                    (detach.is_none() && transport.pending() > 0)
                        .then(|| now + heartbeat_timeout.saturating_sub(stalled)),
                    transport.closed_deadline(),
                ]
                .into_iter()
                .flatten()
                {
                    deadline = deadline.min(candidate);
                }
                deadline.saturating_duration_since(now)
            };
            poll(&mut fds, wait)?;
            interrupted()?;
            if fds[1].revents != 0 {
                transport.write_ready()?;
            }
            if fds[0].revents != 0 && !transport.read_ready()? {
                if detach.is_some() {
                    // The host closes the connection only after its Ok, which
                    // would have been handled before this end of file.
                    paint(self.renderer, self.output, transport)?;
                    return Ok(Outcome::DetachedUnconfirmed(
                        "detached, but the host closed the connection without confirming the detach; input not yet delivered to the session may have been discarded".into(),
                    ));
                }
                return Err(lost(connection_lost(id, transport)));
            }
            if read_stdin && (self.stdin_is_file || fds[2].revents != 0) {
                match read_some(libc::STDIN_FILENO, &mut self.buffer[..read_limit]) {
                    Ok(None) => {}
                    Ok(Some(0)) => {
                        self.stdin_open = false;
                        if detach.is_none() {
                            // End of input detaches, after everything read before it.
                            let rest = self.input.finish();
                            self.forward_input(transport, overflow, &rest)?;
                            *detach = Some(queue_detach(
                                transport,
                                overflow,
                                timing().detach_wait,
                                true,
                            )?);
                        }
                    }
                    Ok(Some(n)) if detach.is_some() => {
                        self.output.set_input_aside(&self.buffer[..n])
                    }
                    Ok(Some(n)) => {
                        let now = Instant::now();
                        let parsed = self.input.feed(&self.buffer[..n], now);
                        self.forward_input(transport, overflow, &parsed.data)?;
                        if parsed.detach {
                            *detach =
                                Some(queue_detach(transport, overflow, KEY_DETACH_WAIT, false)?);
                        }
                    }
                    Err(error) => return Err(error).context("could not read terminal input"),
                }
            }
        }
    }

    /// The connection in `slot` was lost (`lost` says how): connect again
    /// and attach again, until the reconnection's window ends (see
    /// `Streak`). Meanwhile the terminal is read (when it is one) only to
    /// see the detach key or the end of input; what else it sends is
    /// discarded.
    fn reconnect(
        &mut self,
        slot: &mut Option<Transport>,
        reconnect: &mut Reconnect,
        lost: anyhow::Error,
    ) -> Result<Reconnected> {
        self.publish(true);
        let now = Instant::now();
        let mut streak = match self.streak.take() {
            Some(mut streak)
                if now.saturating_duration_since(self.connected_at)
                    < timing().reconnect_healthy =>
            {
                streak.failure = Some(anyhow!("attached again, but lost the connection again"));
                streak
            }
            _ => Streak::new(now),
        };
        let result = self.reconnect_within(slot, reconnect, lost, &mut streak);
        self.streak = Some(streak);
        result
    }

    fn reconnect_within(
        &mut self,
        slot: &mut Option<Transport>,
        reconnect: &mut Reconnect,
        lost: anyhow::Error,
        streak: &mut Streak,
    ) -> Result<Reconnected> {
        let window = timing().reconnect_window;
        let deadline = streak.since + window;
        let mut next_attempt = Instant::now() + streak.delay;
        let mut noticed = false;
        loop {
            interrupted()?;
            let now = Instant::now();
            if now >= deadline {
                return Err(match &streak.failure {
                    Some(failure) if !window.is_zero() => anyhow!(
                        "{lost:#}; could not reconnect within {} ({failure:#})",
                        seconds(window)
                    ),
                    _ => lost,
                });
            }
            if now < next_attempt {
                if let Waited::Detached =
                    self.wait(next_attempt.min(deadline), None, &mut noticed)?
                {
                    return Ok(Reconnected::Ended(detached_while_reconnecting()));
                }
                continue;
            }
            // The lost connection is stopped by the first attempt, unless
            // the attachment ends before one runs: then the caller stops it
            // once the outcome is written.
            let attempted = self.attempt(slot, reconnect, deadline, &mut noticed);
            streak.back_off();
            match attempted? {
                Attempted::Detached => {
                    return Ok(Reconnected::Ended(detached_while_reconnecting()))
                }
                Attempted::Done(Ok(reattached)) => return Ok(Reconnected::Attached(reattached)),
                // Nothing that trying again could change.
                Attempted::Done(Err(error)) if is_unresolvable(&error) => {
                    return Err(anyhow!("{lost:#}; could not reconnect: {error:#}"));
                }
                Attempted::Done(Err(error)) => {
                    streak.failure = Some(error);
                    next_attempt = Instant::now() + streak.delay;
                }
            }
        }
    }

    /// Run one attempt (`attempt`) on a thread of its own, reading the
    /// terminal meanwhile. It stops the connection in `slot` first, off this
    /// thread. When the attachment ends meanwhile (the detach key, the end
    /// of input, a signal), the attempt is abandoned, and the connection it
    /// made is left in `slot` for the caller to stop once the outcome is
    /// written.
    fn attempt(
        &mut self,
        slot: &mut Option<Transport>,
        reconnect: &mut Reconnect,
        deadline: Instant,
        noticed: &mut bool,
    ) -> Result<Attempted> {
        let id = self.id;
        let limit = reconnect.attempt;
        let connect = &mut *reconnect.connect;
        let old = slot.take();
        let abandoned = Arc::new(AtomicBool::new(false));
        // Its other end closes when the attempt ends, which wakes this thread.
        let (done, ending) = UnixStream::pair().context("could not connect again")?;
        std::thread::scope(|scope| {
            let worker = scope.spawn({
                let abandoned = abandoned.clone();
                move || {
                    sys::abandon_when(abandoned.clone());
                    drop(old);
                    let mut connected = None;
                    let result = attempt(connect, &mut connected, id, deadline, limit);
                    // A failed attempt's connection (and its ssh) is stopped
                    // here, unless the attachment is ending.
                    if !abandoned.load(Ordering::Relaxed) {
                        connected = None;
                    }
                    drop(ending);
                    (result, connected)
                }
            });
            let waited = loop {
                match self.wait(Instant::now() + MAX_WAIT, Some(done.as_raw_fd()), noticed) {
                    Ok(Waited::Pending) => {}
                    waited => break waited,
                }
            };
            if !matches!(waited, Ok(Waited::Woken)) {
                abandoned.store(true, Ordering::Relaxed);
            }
            let (result, connected) = worker
                .join()
                .unwrap_or_else(|panic| std::panic::resume_unwind(panic));
            *slot = connected;
            Ok(match waited? {
                Waited::Detached => Attempted::Detached,
                _ => Attempted::Done(result),
            })
        })
    }

    /// Wait until `until` at most (and `MAX_WAIT`) for the terminal, or for
    /// `wake` to be readable or closed, while reconnecting. Terminal input
    /// is read only to see the detach key and the end of input.
    fn wait(&mut self, until: Instant, wake: Option<RawFd>, noticed: &mut bool) -> Result<Waited> {
        let now = Instant::now();
        let read = self.stdin_open && self.stdin_is_terminal;
        let mut fds = [
            pollfd(if read { libc::STDIN_FILENO } else { -1 }, libc::POLLIN),
            pollfd(wake.unwrap_or(-1), libc::POLLIN),
        ];
        let mut wake_at = until.min(now + MAX_WAIT);
        if let Some(at) = self.input.next_deadline() {
            wake_at = wake_at.min(at);
        }
        poll(&mut fds, wake_at.saturating_duration_since(now))?;
        interrupted()?;
        let expired = self.input.expire(Instant::now());
        self.discard(&expired.data, noticed);
        if expired.detach {
            return Ok(Waited::Detached);
        }
        if read && fds[0].revents != 0 {
            match read_some(libc::STDIN_FILENO, &mut self.buffer) {
                Ok(None) => {}
                Ok(Some(0)) => {
                    self.stdin_open = false;
                    return Ok(Waited::Detached);
                }
                Ok(Some(n)) => {
                    let parsed = self.input.feed(&self.buffer[..n], Instant::now());
                    let data = parsed.data;
                    self.discard(&data, noticed);
                    if parsed.detach {
                        return Ok(Waited::Detached);
                    }
                }
                Err(error) => return Err(error).context("could not read terminal input"),
            }
        }
        Ok(if fds[1].revents != 0 {
            Waited::Woken
        } else {
            Waited::Pending
        })
    }

    /// Terminal input for the host, in order. The rest of a paste the
    /// terminal began before this connection is discarded until the paste
    /// ends; then the paste the session still has open, if any, is ended.
    fn forward_input(
        &mut self,
        transport: &mut Transport,
        overflow: &mut Overflow,
        data: &[u8],
    ) -> Result<()> {
        let mut data = data;
        if self.paste_tail.is_some() {
            let Some(end) = self.terminal_paste.until_closed(data) else {
                if !data.is_empty() {
                    self.paste_tail = Some(Instant::now());
                }
                return Ok(());
            };
            data = &data[end..];
            self.end_paste_tail(transport, overflow)?;
        }
        self.terminal_paste.feed(data);
        overflow.forward(transport, data)
    }

    /// The rest of the terminal's paste is over (its end marker came, or
    /// nothing did for `PASTE_TAIL_WAIT`): end the paste the session has
    /// open, if it still has bracketed paste on.
    fn end_paste_tail(&mut self, transport: &mut Transport, overflow: &mut Overflow) -> Result<()> {
        self.paste_tail = None;
        self.terminal_paste = PasteMarkers::default();
        if overflow.paste.open && self.renderer.bracketed_paste() {
            overflow.forward(transport, PASTE_END)?;
        }
        Ok(())
    }

    /// Terminal input read while reconnecting is dropped; the first time,
    /// the screen says so.
    fn discard(&mut self, data: &[u8], noticed: &mut bool) {
        self.terminal_paste.feed(data);
        if data.is_empty() || *noticed {
            return;
        }
        *noticed = true;
        self.output.notice(RECONNECT_NOTICE);
    }
}

/// One attempt, on its own thread: connect into `slot`, say Hello and
/// attach at the window's size now, never past `deadline`. Connecting may
/// take `limit`, and after it each answer may take `limit` without
/// progress (a snapshot that keeps arriving may take longer), so an attempt
/// that hangs leaves time for the next. A host that does not know the
/// session is asked whether it may yet.
fn attempt(
    connect: &mut (dyn FnMut(&mut Option<Transport>, Instant) -> Result<()> + Send),
    slot: &mut Option<Transport>,
    id: &str,
    deadline: Instant,
    limit: Duration,
) -> Result<Box<Reattached>> {
    connect(slot, deadline.min(Instant::now() + limit))?;
    let transport = slot.as_mut().expect("connected");
    transport.set_deadline(deadline);
    // Resizes until now are in the size sent with the Attach.
    let _ = sys::take_resize();
    let physical = physical_size();
    let size = protocol_size(physical);
    // Never a takeover: the others who lost their connection with this one
    // attach again too.
    match request_attach(transport, id, size, false, limit) {
        Ok(snapshot) => {
            transport.clear_deadline();
            Ok(Box::new(Reattached {
                transport: slot.take().expect("connected"),
                snapshot,
                size,
                physical,
            }))
        }
        Err(error) => match error.downcast_ref::<Refused>() {
            Some(refused)
                if refused.code == error_code::UNKNOWN_SESSION
                    && !may_return(transport, id, limit)? =>
            {
                Err(unresolvable(format!("the host no longer has session {id}")))
            }
            _ => Err(error),
        },
    }
}

/// After the host said it does not know the session: whether it may yet,
/// because a host that just restarted still expects sessions to register
/// again (`pending_holders`), or it lists the session by now. The host
/// waits a while for the holders it expects before it answers either.
fn may_return(transport: &mut Transport, id: &str, idle: Duration) -> Result<bool> {
    transport.send(&ClientMessage::List)?;
    match transport.receive(idle)? {
        ServerMessage::Sessions {
            sessions,
            pending_holders,
            ..
        } => Ok(pending_holders > 0 || sessions.iter().any(|session| session.id == id)),
        message => {
            unexpected("session list", message)?;
            unreachable!()
        }
    }
}

fn detached_while_reconnecting() -> Outcome {
    Outcome::DetachedUnconfirmed(
        "detached while reconnecting to the host; the session may still be running there. Input not delivered before the connection was lost was not resent, and input typed while reconnecting was discarded".into(),
    )
}

/// `30 s`, or `0.5 s` below a second.
fn seconds(duration: Duration) -> String {
    if duration.subsec_millis() == 0 {
        format!("{} s", duration.as_secs())
    } else {
        format!("{:.1} s", duration.as_secs_f64())
    }
}

fn connection_lost(id: &str, transport: &Transport) -> String {
    format!("connection lost while attached to {id}{}; the session may still be running on the host. Reattach to resume; input was not resent", ssh_said(transport))
}

/// ` (<what ssh said last>)`, once what ssh prints is kept off the screen.
fn ssh_said(transport: &Transport) -> String {
    transport
        .stderr_tail(SSH_TAIL_WAIT)
        .map(|line| format!(" ({line})"))
        .unwrap_or_default()
}

/// Paint the frame for output received since the last one, in viewport mode.
fn paint(
    renderer: &mut Renderer,
    output: &TerminalOutput,
    transport: &mut Transport,
) -> Result<()> {
    if let Some(frame) = renderer.flush()? {
        output.write_all(&frame, transport)?;
    }
    Ok(())
}

/// Waiting for the host's Ok once Detach is queued.
struct Detaching {
    /// The longest wait (without progress, when `follows_progress`).
    wait: Duration,
    /// When Detach was queued, or the host last showed progress.
    since: Instant,
    /// End of input waits while the input before it keeps moving: the
    /// transport accepts it, or the host answers the Pings behind it. The
    /// detach key waits a fixed time, since the user is waiting.
    follows_progress: bool,
}

impl Detaching {
    fn deadline(&self, transport: &Transport) -> Instant {
        let since = if self.follows_progress {
            self.since.max(transport.progress())
        } else {
            self.since
        };
        since + self.wait
    }

    fn progressed(&mut self) {
        if self.follows_progress {
            self.since = Instant::now();
        }
    }

    /// Why the detach ended without the host's Ok when the wait ran out.
    fn gave_up(&self) -> String {
        let progress = if self.follows_progress {
            " without progress"
        } else {
            ""
        };
        format!("detached without the host's confirmation after {}{progress} (the session is not reading its input, or the connection stalled); input not yet delivered to the session was discarded", seconds(self.wait))
    }
}

/// Input on its way to the host. What is read while the transport holds more
/// than `INPUT_HIGH_WATER` waits here, in order, until there is room for it
/// there. A host whose program is not reading its input stops reading the
/// connection, and the transport then stops taking input. The terminal is
/// still read (with a detach key only), up to `INPUT_OVERFLOW` more, so the
/// detach key typed behind that input is seen; beyond it input waits in the
/// terminal. The detach key typed behind more than that, such as after a
/// large paste, is not seen until the program reads.
#[derive(Default)]
struct Overflow {
    waiting: Vec<u8>,
    /// Input was queued on this connection.
    forwarded: bool,
    /// Whether the input queued so far leaves a paste open in the session.
    paste: PasteMarkers,
    /// Where queued input opened or closed a paste (the transport's
    /// `queued_total` once the frame with the marker was queued; never, for
    /// input the transport dropped), and whether one was open after it:
    /// oldest first, those the transport has not taken yet.
    paste_changes: VecDeque<(u64, bool)>,
    /// Whether the input the transport took so far leaves a paste open.
    sent_paste: bool,
}

impl Overflow {
    /// A connection's input, which starts inside a paste when the session
    /// has one open.
    fn new(open_paste: bool) -> Self {
        let mut overflow = Self::default();
        overflow.paste.open = open_paste;
        overflow.sent_paste = open_paste;
        overflow
    }

    /// Whether the session may have a paste open that the input sent on
    /// this connection left: its start marker went to the transport, and
    /// its end did not. What the transport never took never reached it.
    fn paste_left_open(&mut self, transport: &Transport) -> bool {
        self.settle(transport);
        self.sent_paste
    }

    /// Apply the changes the transport has taken.
    fn settle(&mut self, transport: &Transport) {
        let sent = transport.sent_total();
        while let Some(&(at, open)) = self.paste_changes.front() {
            if at > sent {
                break;
            }
            self.sent_paste = open;
            self.paste_changes.pop_front();
        }
    }

    /// Queue input for the host behind what is waiting here, or wait here.
    fn forward(&mut self, transport: &mut Transport, data: &[u8]) -> Result<()> {
        if self.waiting.is_empty() && transport.pending() < timing().input_high_water {
            self.queue(transport, data)
        } else {
            self.waiting.extend_from_slice(data);
            Ok(())
        }
    }

    /// Queue what waits here once the transport has room.
    fn release(&mut self, transport: &mut Transport) -> Result<()> {
        if !self.waiting.is_empty() && transport.pending() < timing().input_high_water {
            self.queue_waiting(transport)?;
        }
        Ok(())
    }

    fn queue_waiting(&mut self, transport: &mut Transport) -> Result<()> {
        let waiting = std::mem::take(&mut self.waiting);
        self.queue(transport, &waiting)
    }

    fn queue(&mut self, transport: &mut Transport, data: &[u8]) -> Result<()> {
        self.forwarded |= !data.is_empty();
        // One frame at a time, as the transport sends them, so that each
        // marker is placed at the end of its frame.
        for chunk in data.chunks(MAX_INPUT_BYTES) {
            let (open, queued) = (self.paste.open, transport.queued_total());
            self.paste.feed(chunk);
            transport.queue_input(chunk)?;
            if self.paste.open != open {
                let at = transport.queued_total();
                let at = if at == queued { u64::MAX } else { at };
                self.paste_changes.push_back((at, self.paste.open));
            }
        }
        self.settle(transport);
        Ok(())
    }

    /// How much terminal input may be read now.
    fn room(&self, transport: &Transport, input: &DetachInput) -> usize {
        if self.waiting.is_empty() && transport.pending() < timing().input_high_water {
            usize::MAX
        } else if input.detaches() {
            INPUT_OVERFLOW.saturating_sub(self.waiting.len())
        } else {
            0
        }
    }
}

/// Whether the input queued so far leaves a bracketed paste open: its start
/// marker was queued, and its end marker not yet.
#[derive(Default)]
struct PasteMarkers {
    open: bool,
    /// How much of the marker awaited has matched.
    matched: usize,
}

impl PasteMarkers {
    /// Feed `data` while a paste is open: how much of it the paste takes,
    /// its end marker included, once the paste ends in it.
    fn until_closed(&mut self, data: &[u8]) -> Option<usize> {
        for (index, byte) in data.iter().enumerate() {
            if !self.open {
                return Some(index);
            }
            self.feed(std::slice::from_ref(byte));
        }
        (!self.open).then_some(data.len())
    }

    fn feed(&mut self, data: &[u8]) {
        for &byte in data {
            let marker = if self.open { PASTE_END } else { PASTE_START };
            self.matched = if byte == marker[self.matched] {
                self.matched + 1
            } else {
                usize::from(byte == 0x1b)
            };
            if self.matched == marker.len() {
                self.open = !self.open;
                self.matched = 0;
            }
        }
    }
}

/// Queue Detach behind everything read so far, including input still
/// waiting for room in the transport. If the host does not take that input,
/// the detach gives up after its wait and the input is discarded.
fn queue_detach(
    transport: &mut Transport,
    overflow: &mut Overflow,
    wait: Duration,
    follows_progress: bool,
) -> Result<Detaching> {
    overflow.queue_waiting(transport)?;
    transport.queue(&ClientMessage::Detach)?;
    // The host reads nothing after Detach.
    transport.stop_heartbeat();
    Ok(Detaching {
        wait,
        since: Instant::now(),
        follows_progress,
    })
}

/// Keeps a copy of the host's canonical screen. A window of the same size
/// gets the host's stream directly, with its own history. Any other size
/// (including one beyond the protocol's 500x200 limit) gets a top-left
/// viewport painted from the copy, because raw VT has implicit right and
/// bottom edges, and the output that acts on the terminal itself rather than
/// its screen (see `Passthrough`). Either way the window answers the queries
/// the host sends this client (`query`).
pub struct Renderer {
    terminal: Option<cherry_vt::Terminal>,
    canonical: (u16, u16),
    /// The real window size, never clamped.
    physical: (u16, u16),
    /// modes() last written in viewport mode; None in direct mode, where the
    /// window follows the session's stream.
    sent_modes: Option<Vec<u8>>,
    /// Viewport mode: the screen the last modes() left the window on.
    window: WindowScreen,
    /// Viewport mode: output arrived since the last frame.
    dirty: bool,
    /// Tells which screen modes() leaves the window on (see
    /// `entered_alternate`).
    scratch: Option<cherry_vt::Terminal>,
    /// Follows the output in both modes, so a sequence that a mode change
    /// falls inside is still found whole.
    passthrough: Passthrough,
    /// A query was written to the window, which may still answer it.
    queried: bool,
}

/// What the window may still send once the attachment ends.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Reporting {
    /// Reports the user's shell must not read: mouse, focus or colour
    /// scheme reports, keys in the kitty encoding, or answers to queries.
    pub reports: bool,
    /// X10 mouse reports encode their coordinates in UTF-8 (mode 1005).
    pub utf8_mouse: bool,
}

/// Modes that make a terminal send reports of its own accord: mouse
/// tracking, focus and colour scheme changes.
const REPORT_MODES: [u16; 6] = [9, 1000, 1002, 1003, 1004, 2031];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum WindowScreen {
    Primary,
    Alternate {
        /// The mode that entered it.
        mode: u16,
        /// 1049's saved cursor is the window's own primary cursor: modes()
        /// entered the alternate screen from the primary one, and its
        /// ?1049h saved that cursor. Not when the window followed the
        /// session onto the alternate screen in direct mode: then modes()
        /// is written on the alternate screen and saves nothing for the
        /// primary one.
        primary_saved: bool,
    },
}

impl Renderer {
    pub fn new(physical: (u16, u16)) -> Self {
        Self {
            terminal: None,
            canonical: (0, 0),
            physical,
            sent_modes: None,
            // The user's shell, before anything is written.
            window: WindowScreen::Primary,
            dirty: false,
            scratch: None,
            passthrough: Passthrough::default(),
            queried: false,
        }
    }

    fn direct(&self) -> bool {
        self.canonical == self.physical
    }

    /// The window shows a viewport of the shared grid (see `Renderer`),
    /// rather than the session's stream.
    pub fn viewport(&self) -> bool {
        self.terminal.is_some() && !self.direct()
    }

    /// The session has bracketed paste on (mode 2004), by the copy.
    fn bracketed_paste(&self) -> bool {
        self.terminal
            .as_ref()
            .and_then(|terminal| terminal.modes().ok())
            .is_some_and(|modes| modes.windows(8).any(|window| window == b"\x1b[?2004h"))
    }

    fn terminal(&self) -> &cherry_vt::Terminal {
        self.terminal.as_ref().expect("renderer has a snapshot")
    }

    /// Start over from a snapshot; returns the bytes to write.
    pub fn replace(&mut self, canonical: (u16, u16), snapshot: &[u8]) -> Result<Vec<u8>> {
        if !valid_size(canonical.0, canonical.1) {
            bail!("host sent invalid terminal dimensions");
        }
        if self.sent_modes.is_none() && canonical != self.physical {
            // Leaving direct mode: the window shows the replaced copy's screen.
            self.window = self.followed_screen()?;
        }
        let mut terminal =
            cherry_vt::Terminal::new(canonical.0, canonical.1, RENDER_SCROLLBACK_BYTES)?;
        let _ = terminal.feed(snapshot);
        self.terminal = Some(terminal);
        self.canonical = canonical;
        self.dirty = false;
        // The host sends whole sequences: output resumes at a boundary.
        self.passthrough.reset();
        if self.direct() {
            self.sent_modes = None;
            Ok(snapshot.to_vec())
        } else {
            self.frame()
        }
    }

    /// Track output; returns what to write to the window now. In direct
    /// mode that is the output itself. In viewport mode `flush` paints the
    /// screen, and what acts on the terminal itself is written through now.
    pub fn output<'a>(&mut self, bytes: &'a [u8]) -> Result<Cow<'a, [u8]>> {
        let found = self.passthrough.feed(bytes);
        self.feed(bytes);
        if self.direct() {
            return Ok(Cow::Borrowed(bytes));
        }
        self.dirty |= !bytes.is_empty();
        Ok(Cow::Owned(found))
    }

    /// A query for the window to answer (`ServerMessage::Query`), which
    /// follows all output before it; returns what to write to the window.
    /// An answer can depend on the screen (a cursor report), so in viewport
    /// mode the window first shows the screen up to the query.
    pub fn query(&mut self, bytes: &[u8]) -> Result<Vec<u8>> {
        self.queried = true;
        let mut write = if self.direct() {
            Vec::new()
        } else {
            self.flush()?.unwrap_or_default()
        };
        write.extend_from_slice(bytes);
        Ok(write)
    }

    /// Feed the copy. Its replies are discarded: the host answers most
    /// queries, and the window the rest.
    fn feed(&mut self, bytes: &[u8]) {
        if let Some(terminal) = &mut self.terminal {
            let _ = terminal.feed(bytes);
        }
    }

    /// The frame for output received since the last one, in viewport mode.
    pub fn flush(&mut self) -> Result<Option<Vec<u8>>> {
        if !self.dirty {
            return Ok(None);
        }
        self.dirty = false;
        self.frame().map(Some)
    }

    pub fn resize_physical(&mut self, physical: (u16, u16)) -> Result<Vec<u8>> {
        if physical == self.physical && self.direct() {
            return Ok(Vec::new());
        }
        self.physical = physical;
        self.dirty = false;
        if self.direct() {
            // Back to the direct stream: a full snapshot resets the window.
            self.sent_modes = None;
            self.terminal().snapshot()
        } else {
            if self.sent_modes.is_none() {
                // Leaving direct mode: the window shows the copy's screen.
                self.window = self.followed_screen()?;
            }
            self.frame()
        }
    }

    /// The window's screen in direct mode, where it followed the copy's
    /// stream; the primary one before any snapshot.
    fn followed_screen(&mut self) -> Result<WindowScreen> {
        let Some(terminal) = &self.terminal else {
            return Ok(WindowScreen::Primary);
        };
        let modes = terminal.modes()?;
        Ok(match self.entered_alternate(&modes)? {
            Some(mode) => WindowScreen::Alternate {
                mode,
                primary_saved: false,
            },
            None => WindowScreen::Primary,
        })
    }

    /// What the window may still send, from the modes it was last given:
    /// modes() in viewport mode, the session's own in direct mode.
    pub fn reporting(&self) -> Reporting {
        let copy;
        let modes: &[u8] = match (&self.sent_modes, &self.terminal) {
            (Some(modes), _) => modes,
            (None, Some(terminal)) => {
                copy = terminal.modes().unwrap_or_default();
                &copy
            }
            (None, None) => &[],
        };
        let set = |mode: u16| {
            let set = format!("\x1b[?{mode}h");
            modes
                .windows(set.len())
                .any(|window| window == set.as_bytes())
        };
        // Kitty keyboard flags other than none.
        let kitty = modes.windows(3).any(|window| window == b"\x1b[=");
        Reporting {
            reports: self.queried || kitty || REPORT_MODES.into_iter().any(set),
            utf8_mouse: set(1005),
        }
    }

    /// The terminal reset for leaving the window (see `terminal_reset`).
    ///
    /// In direct mode the window mirrors the session, so it leaves the
    /// alternate screen the way the session entered it, and the copy tells
    /// where the reset leaves the cursor: DECRC restores origin mode, and
    /// leaving origin mode afterwards homes the cursor, so the cursor is put
    /// back explicitly.
    ///
    /// In viewport mode the window is on the screen the last modes() left it
    /// on; output not yet painted changed only the copy. When modes() entered
    /// the alternate screen from the primary one, it saved the window's own
    /// primary cursor (the prompt the user attached from, or the last primary
    /// frame's cursor) in 1049's slot, so `?1049l` returns to it whichever of
    /// 47, 1047 or 1049 the session used; leaving 47 or 1047 would carry the
    /// program's cursor onto the primary screen. When the window followed the
    /// session onto the alternate screen in direct mode and a resize then
    /// switched it to a viewport, that slot holds the session's cursor (1049)
    /// or nothing of the window's (47, 1047), so the reset leaves the way the
    /// session entered, as in direct mode. Viewport frames never turn origin
    /// mode on.
    pub fn detach_reset(&mut self) -> Vec<u8> {
        let Some(terminal) = &mut self.terminal else {
            return terminal_reset(LEAVE_ANY_ALTERNATE);
        };
        if self.sent_modes.is_some() {
            let leave = match self.window {
                WindowScreen::Primary => Vec::new(),
                WindowScreen::Alternate {
                    primary_saved: true,
                    ..
                } => LEAVE_ALTERNATE.to_vec(),
                WindowScreen::Alternate { mode, .. } => format!("\x1b[?{mode}l").into_bytes(),
            };
            return terminal_reset(&leave);
        }
        let leave = alternate_screen(terminal)
            .map(|mode| format!("\x1b[?{mode}l"))
            .unwrap_or_default();
        let mut reset = terminal_reset(leave.as_bytes());
        terminal.feed(&reset);
        let replies = terminal.feed(b"\x1b[?6$p\x1b[6n");
        if mode_is_set(&replies, 6) {
            // The margins are reset, so the report is absolute.
            if let Some((row, col)) = cursor_report(&replies) {
                let _ = write!(reset, "\x1b[?6l\x1b[{row};{col}H");
            }
        }
        reset
    }

    /// The mode that `modes` (from `modes()`) enters the alternate screen
    /// with, if any. A scratch terminal answers: the copy's stream can stop
    /// inside a sequence, which a query fed to the copy would break. modes()
    /// first leaves any alternate screen, so the scratch terminal's earlier
    /// state does not matter, and it is kept for the next time.
    fn entered_alternate(&mut self, modes: &[u8]) -> Result<Option<u16>> {
        let scratch = match &mut self.scratch {
            Some(scratch) => scratch,
            None => self.scratch.insert(cherry_vt::Terminal::new(2, 1, 0)?),
        };
        let _ = scratch.feed(modes);
        Ok(alternate_screen(scratch))
    }

    /// A viewport frame, preceded by modes() when entering viewport mode or
    /// when the modes changed. Resending unchanged modes would re-trigger
    /// their side effects (focus reports, screen switches) on every frame.
    fn frame(&mut self) -> Result<Vec<u8>> {
        let terminal = self.terminal();
        let modes = terminal.modes()?;
        let viewport = terminal.viewport(self.physical.0, self.physical.1)?;
        let mut frame = Vec::with_capacity(modes.len() + viewport.len() + 8);
        if self.sent_modes.as_ref() != Some(&modes) {
            // Its ?1049h saves the primary cursor only on the primary screen.
            let primary_saved = match self.window {
                WindowScreen::Primary => true,
                WindowScreen::Alternate { primary_saved, .. } => primary_saved,
            };
            self.window = match self.entered_alternate(&modes)? {
                Some(mode) => WindowScreen::Alternate {
                    mode,
                    primary_saved,
                },
                None => WindowScreen::Primary,
            };
            // One synchronized update: the frame's closing ?2026l ends it.
            frame.extend_from_slice(b"\x1b[?2026h");
            frame.extend_from_slice(&modes);
            self.sent_modes = Some(modes);
        }
        frame.extend_from_slice(&viewport);
        Ok(frame)
    }
}

/// The mode that put `terminal` on its alternate screen, if it is on one.
/// The query is fed to `terminal`, where it would break a sequence that the
/// next output chunk completes, so a live copy is asked only on detach.
fn alternate_screen(terminal: &mut cherry_vt::Terminal) -> Option<u16> {
    let replies = terminal.feed(b"\x1b[?1049$p\x1b[?1047$p\x1b[?47$p");
    [1049, 1047, 47]
        .into_iter()
        .find(|&mode| mode_is_set(&replies, mode))
}

pub fn check_output_offset(expected: &mut u64, received: u64, len: usize) -> Result<()> {
    if received != *expected {
        bail!("session output is out of sequence (expected {}, received {received}); detach and reattach for a fresh screen", *expected);
    }
    *expected = expected
        .checked_add(len as u64)
        .context("session output offset overflow")?;
    Ok(())
}

/// The window size as the terminal reports it, unclamped.
fn physical_size() -> (u16, u16) {
    for fd in [libc::STDIN_FILENO, libc::STDOUT_FILENO] {
        let mut size = unsafe { std::mem::zeroed::<libc::winsize>() };
        if unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, &mut size) } == 0
            && size.ws_col > 0
            && size.ws_row > 0
        {
            return (size.ws_col, size.ws_row);
        }
    }
    (DEFAULT_COLS, DEFAULT_ROWS)
}

/// The size requested from the host, within the protocol's limits.
pub fn protocol_size((cols, rows): (u16, u16)) -> (u16, u16) {
    let size = (cols.clamp(2, 500), rows.clamp(1, 200));
    debug_assert!(valid_size(size.0, size.1));
    size
}

pub struct RawTerminal {
    fd: RawFd,
    saved: Option<libc::termios>,
}

impl RawTerminal {
    pub fn enter(fd: RawFd) -> Result<Self> {
        if unsafe { libc::isatty(fd) } != 1 {
            return Ok(Self { fd, saved: None });
        }
        let mut original = unsafe { std::mem::zeroed::<libc::termios>() };
        if unsafe { libc::tcgetattr(fd, &mut original) } != 0 {
            return Err(io::Error::last_os_error()).context("could not read terminal mode");
        }
        let mut raw = original;
        unsafe {
            libc::cfmakeraw(&mut raw);
        }
        if unsafe { libc::tcsetattr(fd, libc::TCSANOW, &raw) } != 0 {
            return Err(io::Error::last_os_error()).context("could not enter raw terminal mode");
        }
        Ok(Self {
            fd,
            saved: Some(original),
        })
    }

    /// The terminal input, when it is in raw mode.
    pub fn raw_input(&self) -> Option<RawFd> {
        self.saved.is_some().then_some(self.fd)
    }
}

impl Drop for RawTerminal {
    fn drop(&mut self) {
        if let Some(original) = &self.saved {
            loop {
                if unsafe { libc::tcsetattr(self.fd, libc::TCSANOW, original) } == 0 {
                    break;
                }
                if io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
                    break;
                }
            }
        }
    }
}

/// Pen, character sets, the kitty keyboard stack and modifyOtherKeys are
/// kept per screen.
const SCREEN_RESET: &[u8] = b"\x1b[0m\x1b(B\x1b)B\x1b*B\x1b+B\x0f\x1b[<8u\x1b[=0u\x1b[>4m";

/// Modes a session can change, at their usual defaults. Left alone: DECARM
/// (8), which libghostty defaults to off, and modes whose default comes from
/// the user's terminal settings (alternate scroll 1007, Meta and Alt keys
/// 1035, 1036 and 1039, grapheme clustering 2027).
const MODE_RESET: &[u8] = concat!(
    "\x1b[2l\x1b[4l\x1b[12h\x1b[20l\x1b[?1l\x1b>\x1b[?4l\x1b[?5l\x1b[?7h\x1b[?9l",
    "\x1b[?40l\x1b[?45l\x1b[?66l\x1b[?67l\x1b[?1000l\x1b[?1002l\x1b[?1003l",
    "\x1b[?1004l\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?1016l\x1b[?1045l",
    "\x1b[?2004l\x1b[?2031l\x1b[?2033l\x1b[?2048l\x1b[?5522l",
    "\x1b[?12l\x1b[?25h\x1b[0 q"
)
.as_bytes();

/// Leaves the alternate screen for the primary cursor that ?1049h saved,
/// whichever mode entered it. Leaving 47 and 1047 afterwards, on the primary
/// screen, moves nothing and clears those modes too.
const LEAVE_ALTERNATE: &[u8] = b"\x1b[?1049l\x1b[?1047l\x1b[?47l";

/// Leaves any alternate screen without moving the primary screen's cursor,
/// for when the window's screen is not known: before a snapshot was written,
/// and when unwinding before `Renderer::detach_reset`.
/// ?1049l restores the cursor 1049 saved even on the primary screen, and
/// tmux keeps that cursor apart from DECSC, so in a pane where an earlier
/// program used 1049 it is that program's stale position. ?1049h first saves
/// the current cursor, so on the primary screen the pair leaves it in place.
/// On the alternate screen, ?1049h saves that screen's own cursor (xterm,
/// Ghostty) or does nothing (tmux), and ?1049l returns to the primary cursor
/// saved when the window entered it.
const LEAVE_ANY_ALTERNATE: &[u8] = b"\x1b[?1049h\x1b[?1049l\x1b[?1047l\x1b[?47l";

/// Written when leaving a terminal, even when the still-running program never
/// sent its own teardown: everything a snapshot or live output can change
/// that would otherwise break the user's shell. `leave_alternate` switches
/// from the alternate screen to the primary one.
pub fn terminal_reset(leave_alternate: &[u8]) -> Vec<u8> {
    let mut reset = Vec::with_capacity(512);
    // End an unfinished sequence and a synchronized update.
    reset.extend_from_slice(b"\x18\x1b[?2026l");
    reset.extend_from_slice(SCREEN_RESET);
    reset.extend_from_slice(leave_alternate);
    // Reset the margins without moving the cursor (each reset homes it).
    // DECRC restores origin mode too; see Renderer::detach_reset.
    reset.extend_from_slice(b"\x1b7\x1b[?6l\x1b[?69l\x1b[r\x1b8");
    reset.extend_from_slice(SCREEN_RESET);
    reset.extend_from_slice(MODE_RESET);
    reset
}

/// Whether a DECRQM reply in `replies` reports `mode` as set.
fn mode_is_set(replies: &[u8], mode: u16) -> bool {
    let reply = format!("\x1b[?{mode};1$y");
    replies
        .windows(reply.len())
        .any(|window| window == reply.as_bytes())
}

/// The last cursor position report (`ESC [ row ; col R`) in `replies`.
fn cursor_report(replies: &[u8]) -> Option<(u16, u16)> {
    let text = std::str::from_utf8(replies).ok()?;
    let end = text.rfind('R')?;
    let start = text[..end].rfind("\x1b[")? + 2;
    let (row, col) = text[start..end].split_once(';')?;
    Some((row.parse().ok()?, col.parse().ok()?))
}

pub struct TerminalOutput {
    fd: RawFd,
    original_flags: i32,
    restore_screen: bool,
    /// The same terminal's input, in raw mode. Input that arrives once the
    /// attachment ended is read, so the reports the terminal sent for the
    /// session never reach the user's shell (see `Leftover`).
    input: Option<RawFd>,
    /// Terminal input read while detaching, sorted once `reporting` is known.
    aside: Vec<u8>,
    /// `Renderer::reporting` once the attachment ended.
    pub reporting: Reporting,
    /// Written on drop; `Renderer::detach_reset` once the attachment ended.
    pub reset: Vec<u8>,
}

impl TerminalOutput {
    pub fn new(fd: RawFd, input: Option<RawFd>) -> Result<Self> {
        let original_flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if original_flags < 0 {
            return Err(io::Error::last_os_error()).context("could not read terminal output flags");
        }
        set_nonblocking(fd)?;
        let restore_screen = unsafe { libc::isatty(fd) } == 1;
        Ok(Self {
            fd,
            original_flags,
            restore_screen,
            input: input.filter(|&input| restore_screen && same_terminal(input, fd)),
            aside: Vec::new(),
            reporting: Reporting::default(),
            reset: terminal_reset(LEAVE_ANY_ALTERNATE),
        })
    }

    /// Whether terminal input read once the attachment ended is set aside
    /// for the local shell. Beyond `MAX_SET_ASIDE` it waits in the terminal.
    pub fn sets_input_aside(&self) -> bool {
        self.input.is_some() && self.aside.len() < MAX_SET_ASIDE
    }

    pub fn set_input_aside(&mut self, bytes: &[u8]) {
        self.aside.extend_from_slice(bytes);
    }

    /// Best effort, while no host connection needs heartbeats: a terminal
    /// that takes nothing for a second loses the rest, which the next
    /// snapshot's leading CAN cuts off.
    pub fn notice(&self, bytes: &[u8]) {
        let _ = sys::write_all(self.fd, bytes, Duration::from_secs(1), true);
    }

    /// Write everything, failing only when the terminal accepts nothing for
    /// `RPC_TIMEOUT`. While a slow terminal catches up, the heartbeat keeps
    /// going, so the host does not take the attachment for a dead one.
    pub fn write_all(&self, mut bytes: &[u8], transport: &mut Transport) -> Result<()> {
        let mut deadline = Instant::now() + RPC_TIMEOUT;
        while !bytes.is_empty() {
            interrupted()?;
            if transport.next_ping().is_some_and(|at| Instant::now() >= at) {
                transport.heartbeat(Instant::now())?;
                transport.write_ready()?;
            }
            if let Some(n) =
                sys::write_some(self.fd, bytes).context("could not write terminal output")?
            {
                bytes = &bytes[n..];
                deadline = Instant::now() + RPC_TIMEOUT;
                continue;
            }
            let now = Instant::now();
            if now >= deadline {
                bail!(
                    "could not write terminal output: {}",
                    sys::blocked_output(RPC_TIMEOUT)
                );
            }
            // Pings and input the transport did not take yet.
            transport.write_ready()?;
            let mut fds = [
                pollfd(self.fd, libc::POLLOUT),
                pollfd(
                    if transport.pending() > 0 {
                        transport.write_fd()
                    } else {
                        -1
                    },
                    libc::POLLOUT,
                ),
            ];
            let wake = transport
                .next_ping()
                .map_or(deadline, |at| at.min(deadline));
            poll(
                &mut fds,
                Duration::from_millis(100).min(wake.saturating_duration_since(now)),
            )?;
        }
        Ok(())
    }
}

impl Drop for TerminalOutput {
    fn drop(&mut self) {
        let mut leftover = Leftover::new(self.reporting.utf8_mouse);
        leftover.feed(&self.aside);
        if self.restore_screen {
            // Drained only when the terminal may still send reports, or to
            // complete one read in part: a query whose answer arrives late
            // would reach the shell itself. After a termination signal the
            // reset is one bounded attempt, and nothing is waited for.
            let drain = self.input.filter(|_| {
                (self.reporting.reports || leftover.unfinished())
                    && sys::termination_signal().is_none()
            });
            if drain.is_some() {
                self.reset.extend_from_slice(DEVICE_ATTRIBUTES);
            }
            let written =
                sys::write_all(self.fd, &self.reset, Duration::from_millis(100), false).is_ok();
            if let Some(input) = drain.filter(|_| written) {
                leftover.await_answer();
                read_reports(input, &mut leftover, timing().report_wait);
            }
        }
        if let Some(input) = self.input {
            give_back(input, &leftover.finish());
        }
        unsafe {
            libc::fcntl(self.fd, libc::F_SETFL, self.original_flags);
        }
    }
}

/// Whether two descriptors are the same terminal device.
fn same_terminal(a: RawFd, b: RawFd) -> bool {
    let device = |fd: RawFd| {
        let mut info = unsafe { std::mem::zeroed::<libc::stat>() };
        (unsafe { libc::fstat(fd, &mut info) } == 0 && info.st_mode & libc::S_IFMT == libc::S_IFCHR)
            .then_some(info.st_rdev)
    };
    device(a).is_some_and(|device_a| device(b) == Some(device_a))
}

/// Read the terminal's input until it answered `DEVICE_ATTRIBUTES`, written
/// after the reset. Terminals answer in order, so every report generated
/// before the reset took effect (mouse and focus reports, kitty key events)
/// has arrived by then, even over a slow link. Gives up after `wait`, for a
/// terminal that does not answer.
fn read_reports(fd: RawFd, leftover: &mut Leftover, wait: Duration) {
    let deadline = Instant::now() + wait;
    let mut buffer = [0u8; 4096];
    while !leftover.answered() && sys::termination_signal().is_none() {
        let now = Instant::now();
        if now >= deadline {
            return;
        }
        let mut fds = [pollfd(fd, libc::POLLIN)];
        if poll(&mut fds, deadline - now).is_err() {
            return;
        }
        if fds[0].revents == 0 {
            continue;
        }
        match read_some(fd, &mut buffer) {
            Ok(None) => {}
            Ok(Some(0)) | Err(_) => return,
            Ok(Some(n)) => leftover.feed(&buffer[..n]),
        }
    }
}

/// Return keystrokes to the terminal's input queue, for the program that
/// reads it next: the user's shell. TIOCSTI needs the terminal to be this
/// process's controlling terminal, and Linux may refuse it
/// (dev.tty.legacy_tiocsti); the keystrokes are lost then.
fn give_back(fd: RawFd, keys: &[u8]) {
    for key in keys {
        if unsafe { libc::ioctl(fd, libc::TIOCSTI, key as *const u8) } != 0 {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What the window receives for live output right away.
    fn live(renderer: &mut Renderer, bytes: &[u8]) -> Vec<u8> {
        renderer.output(bytes).unwrap().into_owned()
    }

    fn contains(haystack: &[u8], needle: &[u8]) -> bool {
        haystack
            .windows(needle.len())
            .any(|window| window == needle)
    }

    #[test]
    fn output_offsets_reject_loss_duplicates_and_overflow() {
        let mut offset = 10;
        check_output_offset(&mut offset, 10, 4).unwrap();
        assert_eq!(offset, 14);
        assert!(check_output_offset(&mut offset, 10, 4).is_err());
        assert!(check_output_offset(&mut offset, 20, 4).is_err());
        let mut maximum = u64::MAX;
        assert!(check_output_offset(&mut maximum, u64::MAX, 1).is_err());
    }

    #[test]
    fn equal_sizes_pass_the_host_stream_through() {
        let mut renderer = Renderer::new((80, 24));
        assert_eq!(
            renderer.replace((80, 24), b"\x1bcSNAPSHOT").unwrap(),
            b"\x1bcSNAPSHOT"
        );
        assert_eq!(live(&mut renderer, b"live"), b"live");
        assert_eq!(renderer.flush().unwrap(), None);
    }

    #[test]
    fn viewport_mode_sends_modes_once_and_never_resets_per_frame() {
        let mut renderer = Renderer::new((100, 40));
        let first = renderer
            .replace((80, 24), b"\x1b[?1004h\x1b[?1049hEDITOR")
            .unwrap();
        assert!(first.starts_with(b"\x1b[?2026h"), "{first:?}");
        assert!(contains(&first, b"\x1b[?1004h"), "modes missing");
        assert!(contains(&first, b"EDITOR"));
        assert!(!contains(&first, b"\x1bc"), "no RIS in viewport mode");

        assert!(live(&mut renderer, b" more").is_empty());
        let frame = renderer.flush().unwrap().expect("a frame");
        assert!(contains(&frame, b"EDITOR more"));
        assert!(!contains(&frame, b"\x1bc"));
        assert!(!contains(&frame, b"\x1b[?1004h"), "unchanged modes resent");
        assert!(!contains(&frame, b"\x1b[?1049"), "unchanged modes resent");
        assert_eq!(renderer.flush().unwrap(), None, "nothing new to paint");

        // A mode change after output is sent once, then not again.
        live(&mut renderer, b"\x1b[?1004l");
        let changed = renderer.flush().unwrap().unwrap();
        assert!(changed.starts_with(b"\x1b[?2026h"));
        assert!(contains(&changed, b"\x1b[?1004l"));
        live(&mut renderer, b"!");
        let next = renderer.flush().unwrap().unwrap();
        assert!(!contains(&next, b"\x1b[?1004"));

        // A replacement snapshot with the same modes does not resend them.
        let replaced = renderer.replace((80, 24), b"\x1b[?1049hREPLACED").unwrap();
        assert!(contains(&replaced, b"REPLACED"));
        assert!(!contains(&replaced, b"\x1b[?1049h"));
    }

    #[test]
    fn viewport_mode_writes_what_acts_on_the_terminal_through() {
        let mut window = window((100, 40), &[]);
        let mut renderer = Renderer::new((100, 40));
        window.feed(&renderer.replace((80, 24), b"").unwrap());
        // A clipboard write split across output frames, a title and a bell.
        let first = live(&mut renderer, b"copied \x1b]52;c;aGVs");
        assert!(first.is_empty(), "{first:?}");
        let written = live(&mut renderer, b"bG8=\x07\x1b]2;TITLE\x07\x07text");
        assert_eq!(written, b"\x1b]52;c;aGVsbG8=\x07\x1b]2;TITLE\x07\x07");
        let frame = renderer.flush().unwrap().unwrap();
        assert!(contains(&frame, b"copied text"), "{frame:?}");
        assert!(!contains(&frame, b"\x1b]52;") && !contains(&frame, b"\x1b]2;"));
        assert!(!contains(&frame, b"\x07"), "{frame:?}");
        window.feed(&written);
        window.feed(&frame);
        // A cursor query comes after a frame showing the screen up to it,
        // so the window answers with the session's cursor.
        assert!(live(&mut renderer, b"\r\nAB").is_empty());
        let written = renderer.query(b"\x1b[?6n").unwrap();
        assert!(written.ends_with(b"\x1b[?6n"), "{written:?}");
        window.feed(&written[..written.len() - 5]);
        assert_eq!(window.inspect().unwrap().cursor, (2, 1));
        assert_eq!(renderer.flush().unwrap(), None);
        // Nothing to paint first: only the query.
        assert_eq!(
            renderer.query(b"\x1b]52;c;?\x07").unwrap(),
            b"\x1b]52;c;?\x07"
        );
        assert!(live(&mut renderer, b"CD").is_empty());
        let frame = renderer.flush().unwrap().unwrap();
        assert!(contains(&frame, b"ABCD"), "{frame:?}");
        assert_eq!(renderer.flush().unwrap(), None);

        // In direct mode the output and the queries are written as they
        // are.
        let mut renderer = Renderer::new((80, 24));
        renderer.replace((80, 24), b"").unwrap();
        let output = b"x\x1b]52;c;aGk=\x07\x07";
        assert!(
            matches!(renderer.output(output).unwrap(), Cow::Borrowed(bytes) if bytes == output)
        );
        assert_eq!(renderer.query(b"\x1b[?6n").unwrap(), b"\x1b[?6n");
    }

    #[test]
    fn the_window_reports_after_report_modes_or_queries() {
        let reporting = |snapshot: &[u8]| {
            let mut renderer = Renderer::new((80, 24));
            renderer.replace((80, 24), snapshot).unwrap();
            renderer.reporting()
        };
        assert_eq!(Renderer::new((80, 24)).reporting(), Reporting::default());
        let plain = b"\x1b[?1049h\x1b[?2004h\x1b[?1h\x1b[?1006h\x1b[>4;2m$ ";
        assert_eq!(reporting(plain), Reporting::default());
        for modes in [
            &b"\x1b[?9h"[..],
            b"\x1b[?1000h",
            b"\x1b[?1002h",
            b"\x1b[?1003h",
            b"\x1b[?1004h",
            b"\x1b[?2031h",
            b"\x1b[>1u",
        ] {
            assert!(reporting(modes).reports, "{modes:?}");
        }
        let utf8 = reporting(b"\x1b[?1000h\x1b[?1005h");
        assert!(utf8.reports && utf8.utf8_mouse);
        assert!(!reporting(b"\x1b[?1000h").utf8_mouse);

        // A query written to the window, in direct mode as in viewport mode.
        for physical in [(80, 24), (100, 40)] {
            let mut renderer = Renderer::new(physical);
            renderer.replace((80, 24), b"").unwrap();
            live(&mut renderer, b"\x1b]2;title?\x07\x1b]52;c;aGk=\x07\x07");
            assert!(!renderer.reporting().reports, "{physical:?}");
            renderer.query(b"\x1b]13;?\x07").unwrap();
            assert!(renderer.reporting().reports, "{physical:?}");
        }

        // A viewport window has the modes of the last frame.
        let mut renderer = Renderer::new((100, 40));
        renderer.replace((80, 24), b"\x1b[?1003h").unwrap();
        live(&mut renderer, b"\x1b[?1003l");
        assert!(renderer.reporting().reports, "not painted yet");
        renderer.flush().unwrap();
        assert!(!renderer.reporting().reports);
        live(&mut renderer, b"\x1b[?1004h");
        assert!(!renderer.reporting().reports, "not painted yet");
    }

    #[test]
    fn switching_between_viewport_and_direct_rendering() {
        let mut renderer = Renderer::new((100, 40));
        renderer.replace((80, 24), b"\x1b[?1004hTEXT").unwrap();
        // The window now matches the grid: full snapshot, starting with RIS.
        let direct = renderer.resize_physical((80, 24)).unwrap();
        assert!(direct.starts_with(b"\x18\x1bc") || direct.starts_with(b"\x1bc"));
        assert!(contains(&direct, b"TEXT"));
        assert_eq!(live(&mut renderer, b"raw"), b"raw");
        assert!(renderer.resize_physical((80, 24)).unwrap().is_empty());
        // Leaving direct mode sends the modes again.
        let viewport = renderer.resize_physical((90, 30)).unwrap();
        assert!(viewport.starts_with(b"\x1b[?2026h"));
        assert!(contains(&viewport, b"\x1b[?1004h"));
        let again = renderer.resize_physical((91, 30)).unwrap();
        assert!(!contains(&again, b"\x1b[?1004h"));
    }

    #[test]
    fn windows_beyond_the_protocol_limit_use_the_viewport() {
        let physical = (600, 250);
        assert_eq!(protocol_size(physical), (500, 200));
        assert_eq!(protocol_size((1, 0)), (2, 1));
        let mut renderer = Renderer::new(physical);
        let first = renderer.replace((500, 200), b"\x1bcWIDE").unwrap();
        assert!(
            first.starts_with(b"\x1b[?2026h"),
            "clamped size treated as equal"
        );
        assert!(live(&mut renderer, b"x").is_empty());
    }

    /// Every mode the reset manages, at a non-default value.
    const SESSION_MODES: &[u8] = concat!(
        "\x1b[2h\x1b[4h\x1b[12l\x1b[20h\x1b[?1h\x1b=\x1b[?4h\x1b[?5h\x1b[?7l\x1b[?9h",
        "\x1b[?12h\x1b[?25l\x1b[?40h\x1b[?45h\x1b[?66h\x1b[?67h\x1b[?1000h\x1b[?1002h",
        "\x1b[?1003h\x1b[?1004h\x1b[?1005h\x1b[?1006h\x1b[?1015h\x1b[?1016h\x1b[?1045h",
        "\x1b[?2004h\x1b[?2026h\x1b[?2031h\x1b[?2033h\x1b[?5522h",
        "\x1b[>1u\x1b[>3u\x1b[>4;2m\x1b(0\x1b)0\x1b*0\x1b+0\x0e\x1b[1;31m",
    )
    .as_bytes();

    /// What a window shows after `bytes`.
    fn window(size: (u16, u16), bytes: &[&[u8]]) -> cherry_vt::Terminal {
        let mut window = cherry_vt::Terminal::new(size.0, size.1, 0).unwrap();
        for bytes in bytes {
            window.feed(bytes);
        }
        window
    }

    /// Default margins, keyboard, pen and character sets. The reset
    /// designates ASCII, as terminals start; libghostty starts with UTF-8
    /// designations, which print the same.
    fn fresh_state() -> String {
        window((80, 24), &[b"\x1b(B\x1b)B\x1b*B\x1b+B"])
            .inspect()
            .unwrap()
            .state
    }

    #[test]
    fn detach_reset_returns_modes_margins_and_keyboard_to_defaults() {
        // Origin mode inside top, bottom, left and right margins: the cursor
        // is at row 7, column 13.
        let snapshot = [
            SESSION_MODES,
            b"\x1b[3;20r\x1b[?69h\x1b[5;40s\x1b[?6h\x1b[5;9H".as_slice(),
        ]
        .concat();
        let mut renderer = Renderer::new((80, 24));
        let written = renderer.replace((80, 24), &snapshot).unwrap();
        let reset = renderer.detach_reset();
        let mut window = window((80, 24), &[&written, &reset]);
        let state = window.inspect().unwrap();
        assert!(state.modes.is_empty(), "{:?}", state.modes);
        assert_eq!(state.kitty_flags, 0);
        assert_eq!(state.state, fresh_state());
        assert_eq!(state.cursor, (12, 6), "the cursor moved");
        // Without origin mode, a new scroll region no longer shifts CUP.
        window.feed(b"\x1b[5;10r\x1b[1;1H\x1b[<u");
        let state = window.inspect().unwrap();
        assert_eq!(state.cursor, (0, 0));
        assert_eq!(state.kitty_flags, 0, "a later pop exposed old flags");
    }

    #[test]
    fn detach_reset_leaves_the_alternate_screen_with_both_screens_reset() {
        // The primary cursor was saved in origin mode at row 7, column 9.
        let snapshot = [
            b"\x1b[3;20r\x1b[?6h\x1b[5;9H\x1b[?1049h".as_slice(),
            SESSION_MODES,
            b"\x1b[12;40H",
        ]
        .concat();
        let mut renderer = Renderer::new((80, 24));
        let written = renderer.replace((80, 24), &snapshot).unwrap();
        let reset = renderer.detach_reset();
        assert!(contains(&reset, b"\x1b[?1049l"));
        assert!(!contains(&reset, b"\x1b[?47l"));
        let mut window = window((80, 24), &[&written, &reset]);
        let state = window.inspect().unwrap();
        assert!(!state.alternate);
        assert!(state.modes.is_empty(), "{:?}", state.modes);
        assert_eq!(state.cursor, (8, 6));
        assert_eq!(state.state, fresh_state());
        // The next program on the alternate screen starts from defaults too.
        window.feed(b"\x1b[?1049h");
        let state = window.inspect().unwrap();
        assert_eq!(state.kitty_flags, 0);
        assert!(!state.state.contains(">4;2m"), "{:?}", state.state);
    }

    #[test]
    fn detach_reset_keeps_the_cursor_on_the_primary_screen() {
        // A stale saved cursor must not be restored by leaving a screen that
        // is not active.
        let snapshot = b"\x1b[2;2H\x1b7\x1b[10;10Hprompt$ ";
        let mut renderer = Renderer::new((80, 24));
        let written = renderer.replace((80, 24), snapshot).unwrap();
        let reset = renderer.detach_reset();
        assert!(!contains(&reset, b"\x1b[?1049l"), "{reset:?}");
        assert!(
            !contains(&reset, b"\x1b[?6l\x1b[10"),
            "no origin fix needed"
        );
        let state = window((80, 24), &[&written, &reset]).inspect().unwrap();
        assert_eq!(state.cursor, (17, 9));
    }

    /// A 30x8 window with the user's prompt on row 1 and the cursor below.
    const PROMPT: &[u8] = b"motd\r\n$ cherry attach S\r\n";

    #[test]
    fn detaching_from_a_viewport_returns_the_cursor_to_the_prompt() {
        for entry in [47, 1047, 1049] {
            // A smaller session on the alternate screen, its cursor on row 3.
            let snapshot = format!("\x1b[?{entry}h\x1b[3;4HEDIT");
            let mut renderer = Renderer::new((30, 8));
            let first = renderer.replace((20, 5), snapshot.as_bytes()).unwrap();
            // A mode change resends modes() while on the alternate screen.
            assert!(live(&mut renderer, b"\x1b[?1004hMORE").is_empty());
            let resent = renderer.flush().unwrap().unwrap();
            assert!(contains(&resent, b"\x1b[?1004h"), "?{entry}");
            let reset = renderer.detach_reset();
            let mut window = window((30, 8), &[PROMPT, &first, &resent]);
            assert!(window.inspect().unwrap().alternate, "?{entry}");
            window.feed(&reset);
            let state = window.inspect().unwrap();
            assert!(!state.alternate, "?{entry}");
            assert_eq!(state.cursor, (0, 2), "?{entry}: {reset:?}");
            assert!(
                state.active[1].contains("$ cherry attach S"),
                "?{entry}: {:?}",
                state.active
            );
            assert!(state.modes.is_empty(), "?{entry}: {:?}", state.modes);
        }
    }

    #[test]
    fn detaching_from_a_viewport_keeps_the_last_primary_frames_cursor() {
        for entry in [47, 1047, 1049] {
            let mut renderer = Renderer::new((30, 8));
            let shell = renderer.replace((20, 5), b"$ vim").unwrap();
            live(
                &mut renderer,
                format!("\x1b[?{entry}h\x1b[3;4HEDIT").as_bytes(),
            );
            let editor = renderer.flush().unwrap().unwrap();
            let reset = renderer.detach_reset();
            let state = window((30, 8), &[PROMPT, &shell, &editor, &reset])
                .inspect()
                .unwrap();
            assert!(!state.alternate, "?{entry}");
            assert_eq!(state.cursor, (5, 0), "?{entry}: {reset:?}");
            assert!(state.active[0].contains("$ vim"), "{:?}", state.active);
        }
    }

    /// A session's snapshot: "motd" and "$ prog" on its primary screen, then
    /// a program on the alternate screen with its cursor at column 7, row 2.
    fn editing_session(size: (u16, u16), entry: u16) -> Vec<u8> {
        let mut session = cherry_vt::Terminal::new(size.0, size.1, 0).unwrap();
        session.feed(b"motd\r\n$ prog\r\n");
        session.feed(format!("\x1b[?{entry}h\x1b[3;4HEDIT").as_bytes());
        session.snapshot().unwrap()
    }

    #[test]
    fn a_viewport_the_window_entered_on_the_alternate_screen_is_left_as_the_session_would() {
        for entry in [47, 1047, 1049] {
            // The session's own teardown: 1049 returns to the primary cursor
            // it saved, 47 and 1047 keep the program's.
            let teardown = if entry == 1049 { (0, 2) } else { (7, 2) };
            let snapshot = editing_session((30, 8), entry);
            // The window grows and the shared grid does not follow; modes()
            // is then resent on the alternate screen.
            let mut renderer = Renderer::new((30, 8));
            let mut resized = window(
                (30, 8),
                &[PROMPT, &renderer.replace((30, 8), &snapshot).unwrap()],
            );
            resized.resize(40, 10).unwrap();
            resized.feed(&renderer.resize_physical((40, 10)).unwrap());
            live(&mut renderer, b"\x1b[?1004h");
            resized.feed(&renderer.flush().unwrap().unwrap());
            assert!(resized.inspect().unwrap().alternate, "?{entry}");
            let reset = renderer.detach_reset();
            resized.feed(&reset);
            let state = resized.inspect().unwrap();
            assert!(!state.alternate, "?{entry}");
            assert!(state.modes.is_empty(), "?{entry}: {:?}", state.modes);
            assert_eq!(state.cursor, teardown, "?{entry}: {reset:?}");

            // The shared grid shrinks under the window instead.
            let mut renderer = Renderer::new((30, 8));
            let direct = renderer.replace((30, 8), &snapshot).unwrap();
            let smaller = editing_session((20, 5), entry);
            let frame = renderer.replace((20, 5), &smaller).unwrap();
            let reset = renderer.detach_reset();
            let state = window((30, 8), &[PROMPT, &direct, &frame, &reset])
                .inspect()
                .unwrap();
            assert!(!state.alternate, "?{entry}");
            assert_eq!(state.cursor, teardown, "?{entry}: {reset:?}");

            // Once the program exits, the next one saves the window's cursor.
            let mut renderer = Renderer::new((30, 8));
            let mut resized = window(
                (30, 8),
                &[PROMPT, &renderer.replace((30, 8), &snapshot).unwrap()],
            );
            resized.resize(40, 10).unwrap();
            resized.feed(&renderer.resize_physical((40, 10)).unwrap());
            live(&mut renderer, format!("\x1b[?{entry}l\r\n$ vim").as_bytes());
            resized.feed(&renderer.flush().unwrap().unwrap());
            live(
                &mut renderer,
                format!("\x1b[?{entry}h\x1b[2;2HX").as_bytes(),
            );
            resized.feed(&renderer.flush().unwrap().unwrap());
            resized.feed(&renderer.detach_reset());
            let state = resized.inspect().unwrap();
            assert!(!state.alternate, "?{entry}");
            assert_eq!(state.cursor, (5, 3), "?{entry}");
        }
    }

    #[test]
    fn a_viewport_entered_on_the_primary_screen_keeps_the_windows_cursor() {
        for entry in [47, 1047, 1049] {
            let mut renderer = Renderer::new((30, 8));
            let direct = renderer.replace((30, 8), b"\x1bcmotd\r\n$ vim").unwrap();
            let mut resized = window((30, 8), &[&direct]);
            resized.resize(40, 10).unwrap();
            resized.feed(&renderer.resize_physical((40, 10)).unwrap());
            live(
                &mut renderer,
                format!("\x1b[?{entry}h\x1b[3;4HEDIT").as_bytes(),
            );
            resized.feed(&renderer.flush().unwrap().unwrap());
            let reset = renderer.detach_reset();
            resized.feed(&reset);
            let state = resized.inspect().unwrap();
            assert!(!state.alternate, "?{entry}");
            assert_eq!(state.cursor, (5, 1), "?{entry}: {reset:?}");
            assert!(state.active[1].contains("$ vim"), "{:?}", state.active);
        }
    }

    #[test]
    fn detaching_before_a_viewport_frame_leaves_the_screen_the_window_shows() {
        // The copy entered the alternate screen; no frame showed it yet.
        let mut renderer = Renderer::new((30, 8));
        let shell = renderer.replace((20, 5), b"$ vim").unwrap();
        live(&mut renderer, b"\x1b[?1047h\x1b[3;4HEDIT");
        let reset = renderer.detach_reset();
        let state = window((30, 8), &[PROMPT, &shell, &reset])
            .inspect()
            .unwrap();
        assert!(!state.alternate);
        assert_eq!(state.cursor, (5, 0), "{reset:?}");
        // The copy left the alternate screen; the window still shows it.
        let mut renderer = Renderer::new((30, 8));
        let editor = renderer
            .replace((20, 5), b"\x1b[?1047h\x1b[3;4HEDIT")
            .unwrap();
        live(&mut renderer, b"\x1b[?1047l");
        let reset = renderer.detach_reset();
        let state = window((30, 8), &[PROMPT, &editor, &reset])
            .inspect()
            .unwrap();
        assert!(!state.alternate);
        assert_eq!(state.cursor, (0, 2), "{reset:?}");
    }

    #[test]
    fn without_a_screen_copy_the_reset_leaves_any_alternate_screen() {
        let mut renderer = Renderer::new((80, 24));
        let reset = renderer.detach_reset();
        assert!(contains(&reset, LEAVE_ANY_ALTERNATE));
        let state = window((80, 24), &[b"\x1b[?1049h\x1b[?1004h", &reset])
            .inspect()
            .unwrap();
        assert!(!state.alternate && state.modes.is_empty());
        // On the primary screen, ?1049l must not restore a stale cursor:
        // one saved with DECSC, or one an earlier program's 1049 left
        // behind. libghostty keeps both in one slot, so the second case only
        // stands in for tmux, which keeps 1049's apart (checked in tmux).
        for stale in [&b"\x1b[2;2H\x1b7"[..], b"\x1b[2;2H\x1b[?1049h\x1b[?1049l"] {
            let state = window((80, 24), &[stale, b"\x1b[10;10H", &reset])
                .inspect()
                .unwrap();
            assert_eq!(state.cursor, (9, 9), "{stale:?}");
        }
    }

    #[test]
    fn paste_markers_tell_whether_the_queued_input_leaves_a_paste_open() {
        let open_after = |chunks: &[&[u8]]| {
            let mut markers = PasteMarkers::default();
            for chunk in chunks {
                markers.feed(chunk);
            }
            markers.open
        };
        assert!(!open_after(&[b"typed \x1b[A"]));
        assert!(open_after(&[b"\x1b[200~text"]));
        assert!(!open_after(&[b"\x1b[200~text\x1b[201~after"]));
        // Markers split anywhere, an escape inside a paste, a stray end.
        let paste = b"\x1b\x1b[200~a\x1bb\x1b[201~\x1b[201~";
        for split in 0..paste.len() {
            assert!(!open_after(&[&paste[..split], &paste[split..]]), "{split}");
        }
        assert!(open_after(&[b"\x1b[2", b"00~", b"\x1b[20"]));
        assert!(!open_after(&[b"\x1b[200~", b"\x1b[2", b"01~"]));
    }

    #[test]
    fn the_rest_of_an_open_paste_ends_with_its_end_marker() {
        let open = || {
            let mut markers = PasteMarkers::default();
            markers.feed(b"\x1b[200~");
            markers
        };
        let mut markers = open();
        assert_eq!(markers.until_closed(b"text\r\x1b[201~typed"), Some(11));
        assert!(!markers.open);
        // Nothing of an ended paste, or all of one that goes on.
        assert_eq!(markers.until_closed(b"typed"), Some(0));
        let mut markers = open();
        assert_eq!(markers.until_closed(b"more\r\x1b[20"), None);
        assert_eq!(markers.until_closed(b"1~"), Some(2));
        assert_eq!(open().until_closed(b"\x1b[201~"), Some(6));
    }

    #[test]
    fn bracketed_paste_follows_the_sessions_mode() {
        let mut renderer = Renderer::new((80, 24));
        assert!(!renderer.bracketed_paste(), "no copy yet");
        renderer.replace((80, 24), b"\x1b[?2004h$ ").unwrap();
        assert!(renderer.bracketed_paste());
        live(&mut renderer, b"\x1b[?2004l");
        assert!(!renderer.bracketed_paste());
        // A viewport's copy too.
        let mut renderer = Renderer::new((100, 40));
        renderer.replace((80, 24), b"\x1b[?2004h").unwrap();
        assert!(renderer.bracketed_paste());
    }

    #[test]
    fn query_replies_are_parsed() {
        assert!(mode_is_set(b"\x1b[?1049;2$y\x1b[?6;1$y", 6));
        assert!(!mode_is_set(b"\x1b[?6;2$y", 6));
        assert!(!mode_is_set(b"\x1b[?16;1$y", 6));
        assert_eq!(cursor_report(b"\x1b[?6;1$y\x1b[12;34R"), Some((12, 34)));
        assert_eq!(cursor_report(b"\x1b[?6;1$y"), None);
    }
}
