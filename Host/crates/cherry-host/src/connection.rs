//! One client connection: a reader (this thread) and a writer thread that
//! drains the connection's outbox.
use crate::{
    daemon::{self, Host},
    environment,
    outbox::Outbox,
    session::{Command, Launch, Session},
};
use anyhow::{bail, Context, Result};
use cherry_protocol::{
    encode_frame, error_code, read_frame, write_frame, ClientMessage, ServerMessage, SessionState,
    PROTOCOL_VERSION,
};
use std::{
    collections::{BTreeMap, HashMap},
    os::unix::{io::AsRawFd, net::UnixStream},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
    },
    thread,
    time::{Duration, Instant},
};
use uuid::Uuid;

/// A connection that is not attached must send its next request within this.
const IDLE_TIMEOUT: Duration = Duration::from_secs(10);
/// How long a closing connection's writer may take to flush final replies.
const FLUSH_TIMEOUT: Duration = Duration::from_secs(5);
/// How often a paused connection re-checks the reasons to end it.
const PAUSE_POLL: Duration = Duration::from_millis(100);
pub const MAX_SESSIONS: usize = 128;
const MAX_RECEIPTS: usize = 4096;

/// Idempotency receipts for `Create`, keyed by request ID. Bounded: the least
/// recently used receipt is evicted first. Receipts of removed sessions are
/// pruned with them.
pub struct Receipts {
    entries: HashMap<String, Receipt>,
    order: BTreeMap<u64, String>,
    next: u64,
    capacity: usize,
}

struct Receipt {
    fingerprint: String,
    session: String,
    stamp: u64,
}

impl Default for Receipts {
    fn default() -> Self {
        Self::with_capacity(MAX_RECEIPTS)
    }
}

impl Receipts {
    fn with_capacity(capacity: usize) -> Self {
        Self {
            entries: HashMap::new(),
            order: BTreeMap::new(),
            next: 0,
            capacity,
        }
    }

    /// The session created by this request, refreshing its receipt.
    fn get(&mut self, request: &str) -> Option<(&str, &str)> {
        let stamp = self.next;
        let receipt = self.entries.get_mut(request)?;
        self.order.remove(&receipt.stamp);
        receipt.stamp = stamp;
        self.order.insert(stamp, request.to_string());
        self.next += 1;
        Some((&receipt.fingerprint, &receipt.session))
    }

    fn insert(&mut self, request: String, fingerprint: String, session: String) {
        if let Some(previous) = self.entries.remove(&request) {
            self.order.remove(&previous.stamp);
        }
        while self.entries.len() >= self.capacity {
            let Some((_, oldest)) = self.order.pop_first() else {
                break;
            };
            self.entries.remove(&oldest);
        }
        let stamp = self.next;
        self.next += 1;
        self.order.insert(stamp, request.clone());
        self.entries.insert(
            request,
            Receipt {
                fingerprint,
                session,
                stamp,
            },
        );
    }

    fn remove_session(&mut self, session: &str) {
        let order = &mut self.order;
        self.entries.retain(|_, receipt| {
            if receipt.session == session {
                order.remove(&receipt.stamp);
                false
            } else {
                true
            }
        });
    }
}

pub fn serve(stream: UnixStream, host: &Arc<Host>) {
    let _ = run(stream, host);
}

fn run(mut stream: UnixStream, host: &Arc<Host>) -> Result<()> {
    // Darwin inherits O_NONBLOCK from the listener; framed reads use timeouts.
    stream.set_nonblocking(false)?;
    stream.set_read_timeout(Some(IDLE_TIMEOUT))?;
    stream.set_write_timeout(Some(FLUSH_TIMEOUT))?;
    match read_frame(&mut stream)? {
        Some(ClientMessage::Hello { version }) if version == PROTOCOL_VERSION => {}
        _ => {
            write_frame(
                &mut stream,
                &ServerMessage::error(
                    error_code::VERSION_MISMATCH,
                    format!("expected Cherry host protocol version {PROTOCOL_VERSION}"),
                ),
            )?;
            return Ok(());
        }
    }
    write_frame(
        &mut stream,
        &ServerMessage::Welcome {
            version: PROTOCOL_VERSION,
            host_id: host.id.clone(),
        },
    )?;
    // The writer blocks as long as the peer is alive; a vanished peer is
    // detected by the reader's timeouts and the socket is then shut down.
    stream.set_write_timeout(None)?;
    let outbox = Arc::new(Outbox::default());
    let writer_stream = stream.try_clone()?;
    let writer_outbox = outbox.clone();
    let (done, finished) = mpsc::channel::<()>();
    let writer = thread::Builder::new()
        .name("cherry-writer".into())
        .spawn(move || {
            writer_outbox.write_all_to(&writer_stream);
            let _ = writer_stream.shutdown(std::net::Shutdown::Both);
            let _ = done.send(());
        })?;
    let mut connection = Connection {
        lease: host.next_lease.fetch_add(1, Ordering::Relaxed),
        cancelled: Arc::new(AtomicBool::new(false)),
        attached: None,
        stream,
        host: host.clone(),
        outbox,
        last_probe: None,
    };
    connection.serve();
    // An attachment still held here ended abnormally: its unsent input is
    // discarded. A voluntary detach already went through the worker.
    connection.cancelled.store(true, Ordering::SeqCst);
    if let Some(session) = connection.attached.take() {
        session.wake();
    }
    connection.outbox.close();
    if finished.recv_timeout(FLUSH_TIMEOUT).is_err() {
        let _ = connection.stream.shutdown(std::net::Shutdown::Both);
    }
    let _ = writer.join();
    Ok(())
}

struct Connection {
    lease: u64,
    cancelled: Arc<AtomicBool>,
    attached: Option<Arc<Session>>,
    stream: UnixStream,
    host: Arc<Host>,
    outbox: Arc<Outbox>,
    last_probe: Option<Instant>,
}

enum Flow {
    Continue,
    Close,
}

impl Connection {
    fn reply(&self, message: &ServerMessage) {
        if let Ok(frame) = encode_frame(message) {
            self.outbox.push_control(Arc::new(frame));
        }
    }

    fn serve(&mut self) {
        loop {
            if self.cancelled.load(Ordering::SeqCst) || self.outbox.is_dead() {
                return;
            }
            if !self.wait_for_reply_room() {
                return;
            }
            // Any frame counts as a heartbeat; an attached client that sends
            // nothing for the heartbeat timeout is treated as gone.
            let message = match read_frame::<_, ClientMessage>(&mut self.stream) {
                Ok(Some(message)) => message,
                Ok(None) | Err(_) => return,
            };
            if self.cancelled.load(Ordering::SeqCst) {
                return;
            }
            // Only input waits for room: this client's heartbeats and resizes
            // keep flowing while another client's paste fills the session.
            if matches!(message, ClientMessage::Input { .. }) && !self.wait_for_input_room() {
                return;
            }
            let flow = match self.dispatch(message) {
                Ok((reply, flow)) => {
                    if let Some(reply) = reply {
                        self.reply(&reply);
                    }
                    flow
                }
                Err(error) => {
                    self.reply(&ServerMessage::error(
                        error_code::REQUEST_FAILED,
                        format!("{error:#}"),
                    ));
                    Flow::Continue
                }
            };
            if matches!(flow, Flow::Close) {
                return;
            }
        }
    }

    /// How long this connection may go without sending a frame: the
    /// heartbeat timeout once attached.
    fn silence_limit(&self) -> Duration {
        if self.attached.is_some() {
            daemon::config().heartbeat_timeout
        } else {
            IDLE_TIMEOUT
        }
    }

    /// While the client leaves more replies unread than any working client
    /// could, stop reading its requests. False when the connection should
    /// end: its writer stopped, or it neither read nor sent anything for
    /// its silence limit.
    fn wait_for_reply_room(&mut self) -> bool {
        if !self.outbox.backlogged() {
            return true;
        }
        let mut silence = Silence::new(self.silence_limit(), self.outbox.written());
        loop {
            if self.outbox.wait_for_reply_room(PAUSE_POLL) {
                return !self.outbox.is_dead();
            }
            if self.cancelled.load(Ordering::SeqCst) || silence.expired(self.outbox.written()) {
                return false;
            }
        }
    }

    /// While the session's PTY is not consuming input, hold this input frame
    /// and stop reading: the client's writes then block instead of the host
    /// buffering without bound. The pause is the host's doing, so the
    /// client's silence proves nothing (its heartbeats wait behind the held
    /// input, however long the program takes): only a hangup, a failed write,
    /// a takeover or the session's end stops the wait. False when the
    /// connection should end.
    fn wait_for_input_room(&mut self) -> bool {
        let Some(session) = self.attached.clone() else {
            return true;
        };
        if !session.input.full() {
            return true;
        }
        let paused = Instant::now();
        let keepalive = daemon::config().heartbeat_timeout / 3;
        let mut reported = session.input.released();
        loop {
            if session.input.wait_for_room(PAUSE_POLL) {
                return true;
            }
            if self.cancelled.load(Ordering::SeqCst) || self.outbox.is_dead() {
                return false;
            }
            let finished = match hangup(&self.stream) {
                // Nothing left to read: hand this frame on, and the next read
                // reports the end right away.
                Some(0) => return true,
                Some(_) => true,
                None => false,
            };
            let released = session.input.released();
            let quiet_since = self.last_probe.map_or(paused, |probe| probe.max(paused));
            // At most one Pong a second. To a peer that finished sending: if
            // it is still reading, it is waiting for this input to drain; if
            // it is gone, a write fails and the outbox reports it. And while
            // the program consumes the input held back: a client waiting to
            // detach behind it cannot tell from its blocked writes that the
            // input still moves. Other clients ignore it.
            let progress = (finished || released != reported)
                && self
                    .last_probe
                    .is_none_or(|probe| probe.elapsed() >= Duration::from_secs(1));
            // And a heartbeat every third of the timeout while nothing moves:
            // the client's writes are blocked, and without hearing from the
            // host it would take the connection for dead.
            if progress || quiet_since.elapsed() >= keepalive {
                reported = released;
                self.last_probe = Some(Instant::now());
                self.reply(&ServerMessage::Pong);
            }
        }
    }

    fn dispatch(&mut self, message: ClientMessage) -> Result<(Option<ServerMessage>, Flow)> {
        let reply = match message {
            ClientMessage::Hello { .. } => bail!("connection already negotiated"),
            ClientMessage::Ping => ServerMessage::Pong,
            ClientMessage::List => {
                let registry = self.host.registry.lock().unwrap();
                let mut sessions: Vec<_> = registry
                    .sessions
                    .values()
                    .map(|s| s.snapshot_info())
                    .collect();
                sessions.sort_by(|a, b| a.id.cmp(&b.id));
                ServerMessage::Sessions {
                    host_id: self.host.id.clone(),
                    sessions,
                }
            }
            ClientMessage::Create {
                request_id,
                name,
                cwd,
                command,
                env,
                cols,
                rows,
            } => self.create(request_id, name, cwd, command, env, cols, rows)?,
            ClientMessage::Attach {
                id,
                cols,
                rows,
                takeover,
                answers_queries,
            } => {
                if self.attached.is_some() {
                    bail!("connection already attached");
                }
                if !cherry_protocol::valid_size(cols, rows) {
                    bail!("invalid terminal size");
                }
                let session = self.session(&id)?;
                let (ack, acknowledged) = mpsc::sync_channel(1);
                session.send(Command::Attach {
                    lease: self.lease,
                    cols,
                    rows,
                    takeover,
                    answers_queries,
                    outbox: self.outbox.clone(),
                    abort: self.stream.try_clone()?,
                    cancelled: self.cancelled.clone(),
                    ack,
                })?;
                // The worker replies itself: the snapshot, or why it failed.
                match acknowledged.recv() {
                    Ok(true) => {
                        self.attached = Some(session);
                        self.stream
                            .set_read_timeout(Some(daemon::config().heartbeat_timeout))?;
                    }
                    Ok(false) => {}
                    Err(_) => bail!("session is unavailable"),
                }
                return Ok((None, Flow::Continue));
            }
            ClientMessage::Input { data } => {
                if data.len() > cherry_protocol::MAX_INPUT_BYTES {
                    bail!("input frame exceeds limit");
                }
                let session = self
                    .attached
                    .as_ref()
                    .context("attach before sending input")?;
                let len = data.len();
                session.input.reserve(len);
                if let Err(error) = session.send(Command::Input {
                    lease: self.lease,
                    data,
                }) {
                    session.input.release(len);
                    return Err(error);
                }
                return Ok((None, Flow::Continue));
            }
            ClientMessage::Resize { cols, rows } => {
                self.attached
                    .as_ref()
                    .context("attach before resize")?
                    .send(Command::Resize {
                        lease: self.lease,
                        cols,
                        rows,
                    })?;
                return Ok((None, Flow::Continue));
            }
            ClientMessage::Detach => {
                // Ordered after this connection's earlier input, which is
                // queued for the PTY before the acknowledgement.
                if let Some(session) = self.attached.take() {
                    let (ack, acknowledged) = mpsc::sync_channel(1);
                    if session
                        .send(Command::Detach {
                            lease: self.lease,
                            ack,
                        })
                        .is_ok()
                    {
                        let _ = acknowledged.recv();
                    }
                }
                return Ok((Some(ServerMessage::Ok), Flow::Close));
            }
            ClientMessage::Kill { id } => {
                self.session(&id)?.kill();
                ServerMessage::Ok
            }
            ClientMessage::Remove { id } => {
                let mut registry = self.host.registry.lock().unwrap();
                let session = registry.sessions.get(&id).context("unknown session")?;
                if session.snapshot_info().state == SessionState::Running {
                    bail!("terminate the running session before removing it");
                }
                registry.sessions.remove(&id);
                registry.receipts.remove_session(&id);
                ServerMessage::Ok
            }
            ClientMessage::Shutdown => {
                {
                    let _launch = self.host.launches.lock().unwrap();
                    if self
                        .host
                        .registry
                        .lock()
                        .unwrap()
                        .sessions
                        .values()
                        .any(|s| s.snapshot_info().state == SessionState::Running)
                    {
                        bail!("host still owns running sessions");
                    }
                    self.host.stop();
                }
                // Acknowledge once the socket is gone and the lock is free:
                // the client may start a new host right away.
                self.host.wait_until_released(FLUSH_TIMEOUT);
                ServerMessage::Ok
            }
        };
        Ok((Some(reply), Flow::Continue))
    }

    fn session(&self, id: &str) -> Result<Arc<Session>> {
        self.host
            .registry
            .lock()
            .unwrap()
            .sessions
            .get(id)
            .cloned()
            .context("unknown session")
    }

    /// The existing session for a retried request, if any.
    fn receipt(&self, request_id: &str, fingerprint: &str) -> Result<Option<ServerMessage>> {
        let mut registry = self.host.registry.lock().unwrap();
        let Some((previous, id)) = registry.receipts.get(request_id) else {
            return Ok(None);
        };
        if previous != fingerprint {
            bail!("request_id already used with a different launch");
        }
        let id = id.to_string();
        let session = registry.sessions.get(&id).context(
            "the session from this request was removed; use a new request_id for a new session",
        )?;
        Ok(Some(ServerMessage::Created {
            session: session.snapshot_info(),
        }))
    }

    #[allow(clippy::too_many_arguments)]
    fn create(
        &self,
        request_id: String,
        name: String,
        cwd: String,
        command: Vec<String>,
        env: BTreeMap<String, String>,
        cols: u16,
        rows: u16,
    ) -> Result<ServerMessage> {
        Uuid::parse_str(&request_id).context("request_id must be a UUID")?;
        if name.len() > 256 || cwd.len() > 4096 {
            bail!("launch description exceeds limit");
        }
        // The size is attachment state, not part of what was launched: a
        // retry from a resized terminal is still the same request.
        let fingerprint = serde_json::to_string(&(&name, &cwd, &command, &env))?;
        if let Some(created) = self.receipt(&request_id, &fingerprint)? {
            return Ok(created);
        }
        let env = environment::client_env(env)?;
        // Resolving the directory can block on a hung filesystem; do it
        // before taking any lock shared with other clients.
        let resolved = environment::resolve_cwd(&cwd)?;
        // The session must not start with an agent whose client is gone.
        self.host.prune_agent_link();
        let _launch = self.host.launches.lock().unwrap();
        if self.host.stopping.load(Ordering::SeqCst) {
            bail!("host is shutting down");
        }
        if let Some(created) = self.receipt(&request_id, &fingerprint)? {
            return Ok(created);
        }
        if self.host.registry.lock().unwrap().sessions.len() >= MAX_SESSIONS {
            bail!("host session limit reached ({MAX_SESSIONS} including exited sessions; remove finished sessions)");
        }
        let session = Session::spawn(Launch {
            name,
            cwd: resolved,
            command,
            env,
            cols,
            rows,
            agent_link: self.host.agent_link(),
        })?;
        let info = session.snapshot_info();
        let mut registry = self.host.registry.lock().unwrap();
        registry
            .receipts
            .insert(request_id, fingerprint, info.id.clone());
        registry.sessions.insert(info.id.clone(), session);
        Ok(ServerMessage::Created { session: info })
    }
}

/// How long a paused connection has gone without a frame or any progress.
struct Silence {
    limit: Duration,
    since: Instant,
    progress: u64,
}

impl Silence {
    /// Starts when the connection pauses, right after its last frame.
    fn new(limit: Duration, progress: u64) -> Self {
        Self {
            limit,
            since: Instant::now(),
            progress,
        }
    }

    /// Whether the limit has passed without `progress` changing.
    fn expired(&mut self, progress: u64) -> bool {
        if progress != self.progress {
            self.progress = progress;
            self.since = Instant::now();
        }
        self.since.elapsed() >= self.limit
    }
}

/// Whether the peer has stopped sending, and how many bytes are still
/// unread if so.
fn hangup(stream: &UnixStream) -> Option<usize> {
    let mut fd = libc::pollfd {
        fd: stream.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    #[cfg(target_os = "linux")]
    {
        fd.events |= libc::POLLRDHUP;
    }
    if unsafe { libc::poll(&mut fd, 1, 0) } <= 0 {
        return None;
    }
    #[cfg(target_os = "linux")]
    let closed = libc::POLLHUP | libc::POLLERR | libc::POLLRDHUP;
    #[cfg(not(target_os = "linux"))]
    let closed = libc::POLLHUP | libc::POLLERR;
    if fd.revents & closed == 0 {
        return None;
    }
    let mut unread: libc::c_int = 0;
    if unsafe { libc::ioctl(stream.as_raw_fd(), libc::FIONREAD, &mut unread) } != 0 {
        return Some(0);
    }
    Some(unread.max(0) as usize)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn receipts_are_bounded_least_recently_used() {
        let mut receipts = Receipts::with_capacity(3);
        for n in 0..3 {
            receipts.insert(format!("r{n}"), "f".into(), format!("s{n}"));
        }
        // Touch r0 so r1 becomes the oldest.
        assert_eq!(receipts.get("r0"), Some(("f", "s0")));
        receipts.insert("r3".into(), "f".into(), "s3".into());
        assert!(receipts.get("r1").is_none());
        for kept in ["r0", "r2", "r3"] {
            assert!(receipts.get(kept).is_some(), "{kept}");
        }
        assert_eq!(receipts.entries.len(), 3);
        assert_eq!(receipts.order.len(), 3);
    }

    #[test]
    fn removing_a_session_prunes_its_receipts() {
        let mut receipts = Receipts::with_capacity(8);
        receipts.insert("a".into(), "f".into(), "s1".into());
        receipts.insert("b".into(), "f".into(), "s2".into());
        receipts.remove_session("s1");
        assert!(receipts.get("a").is_none());
        assert_eq!(receipts.get("b"), Some(("f", "s2")));
        assert_eq!(receipts.order.len(), 1);
    }
}
