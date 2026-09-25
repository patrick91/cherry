//! One connection to the daemon socket. A client's is served here: a reader
//! (this thread) and a writer thread that drains the connection's outbox. A
//! holder's (its first frame is a `HolderHello`, see `link`) is handed to
//! the session it holds.
//!
//! A client connection may attach to one session (`Attach`), and may
//! subscribe to events (`Subscribe`, see `Host::publish`); either way it
//! must then send a frame every heartbeat timeout rather than every idle
//! timeout. Requests are answered in order, one at a time; a request that
//! waits for a session (an attach, a screen, input its program has no room
//! for yet) holds back the ones after it.
use crate::{
    daemon::{self, Host},
    environment, link,
    outbox::Outbox,
    session::{Command, Launch, Session},
};
use anyhow::{bail, Context, Result};
use cherry_protocol::{
    encode_frame, error_code, read_frame, write_frame, ClientMessage, Request, Response,
    ServerMessage, SessionEvent, SessionState, MAX_FRAME_BYTES, PROTOCOL_VERSION,
};
use std::{
    collections::{BTreeMap, HashMap},
    io::{self, Read},
    os::unix::{io::AsRawFd, net::UnixStream},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
    },
    thread,
    time::{Duration, Instant},
};
use uuid::Uuid;

/// How long a closing connection's writer may take to flush final replies.
const FLUSH_TIMEOUT: Duration = Duration::from_secs(5);
/// How often a paused connection re-checks the reasons to end it.
const PAUSE_POLL: Duration = Duration::from_millis(100);
/// How long an attach or a detach waits for the session's holder.
const HOLDER_TIMEOUT: Duration = Duration::from_secs(30);
/// How long a `Screen` or an `Update` waits for the session.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
pub const MAX_SESSIONS: usize = 128;
const MAX_RECEIPTS: usize = 4096;
/// A session's name is at most this long.
const MAX_NAME_BYTES: usize = 256;

/// A failed request with an error code of its own (`error_code`) rather
/// than `request_failed`.
#[derive(Debug)]
pub struct Refused {
    pub code: &'static str,
    pub message: String,
}

impl std::fmt::Display for Refused {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for Refused {}

fn refused(code: &'static str, message: impl Into<String>) -> anyhow::Error {
    Refused {
        code,
        message: message.into(),
    }
    .into()
}

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

    pub fn insert(&mut self, request: String, fingerprint: String, session: String) {
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

/// After a `Hello` of another version, the one request a client may make:
/// `Replace`, when it speaks a higher version. This host then stops
/// accepting connections and releases its socket and lock before answering
/// `Ok`, so the client can start its own host at once, and exits. Sessions
/// carry on in their holders, which register with the new host. Anything
/// else is refused and the connection ends.
fn mismatched(mut stream: UnixStream, host: &Arc<Host>, version: u32) -> Result<()> {
    let Some(Request { message, req }) = read_frame(&mut stream)? else {
        return Ok(());
    };
    let reply = match message {
        ClientMessage::Replace if version > PROTOCOL_VERSION => {
            {
                // After any launch in progress, and before any other.
                let _launch = host.launches.lock().unwrap_or_else(|e| e.into_inner());
                host.stop();
            }
            daemon::log(format_args!(
                "replaced by a client speaking protocol {version}; exiting, and leaving the sessions to the next host"
            ));
            host.wait_until_released(FLUSH_TIMEOUT);
            ServerMessage::Ok
        }
        ClientMessage::Replace => ServerMessage::error(
            error_code::VERSION_MISMATCH,
            format!("this host speaks protocol {PROTOCOL_VERSION}, which a client speaking protocol {version} does not replace"),
        ),
        _ => ServerMessage::error(
            error_code::VERSION_MISMATCH,
            format!("this host speaks protocol {PROTOCOL_VERSION}, not {version}; after a version mismatch only replace is accepted"),
        ),
    };
    write_frame(&mut stream, &Response::new(req, reply))?;
    Ok(())
}

/// Stop accepting connections and release the socket and lock, unless
/// sessions are running: `Shutdown` stops the host, and those who ask for it
/// expect their programs to have ended. It ends everything: exited sessions
/// are removed, so their holders exit rather than wait for the next host.
fn stop_without_sessions(host: &Host) -> Result<()> {
    // A daemon that just started sees every session first, as `List` does.
    host.wait_for_holders(None);
    // After any launch or registration in progress, and before any other.
    let _launch = host.launches.lock().unwrap_or_else(|e| e.into_inner());
    let removed: Vec<(String, Arc<Session>)> = {
        let mut registry = host.registry();
        if registry
            .sessions
            .values()
            .any(|s| s.snapshot_info().state == SessionState::Running)
        {
            bail!("host still owns running sessions");
        }
        registry.receipts = Receipts::default();
        registry.sessions.drain().collect()
    };
    // Their holders exit once told, while this host still runs.
    for (id, session) in removed {
        session.remove();
        host.publish(SessionEvent::Removed { id });
    }
    host.stop();
    Ok(())
}

/// A connection's first frame.
enum First {
    Client(Request),
    /// A holder registering its session.
    Holder(link::Frame),
}

/// Read the first frame: a client's `Request`, or a holder's `HolderHello`,
/// whose kind byte can never start a JSON body. None at end of file; an
/// error for anything else.
fn read_first(stream: &mut UnixStream) -> io::Result<Option<First>> {
    let mut header = [0u8; 4];
    loop {
        match stream.read(&mut header[..1]) {
            Ok(0) => return Ok(None),
            Ok(_) => break,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    stream.read_exact(&mut header[1..])?;
    let len = u32::from_be_bytes(header) as usize;
    if len == 0 || len > MAX_FRAME_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid frame length",
        ));
    }
    let mut body = vec![0; len];
    stream.read_exact(&mut body)?;
    if body[0] == link::kind::HOLDER_HELLO {
        return link::decode(&body)
            .map(|frame| Some(First::Holder(frame)))
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error.to_string()));
    }
    serde_json::from_slice(&body)
        .map(|request| Some(First::Client(request)))
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

fn run(mut stream: UnixStream, host: &Arc<Host>) -> Result<()> {
    // Darwin inherits O_NONBLOCK from the listener; framed reads use timeouts.
    stream.set_nonblocking(false)?;
    stream.set_read_timeout(Some(daemon::config().idle_timeout))?;
    stream.set_write_timeout(Some(FLUSH_TIMEOUT))?;
    let (version, req) = match read_first(&mut stream)? {
        None => return Ok(()),
        Some(First::Holder(frame)) => {
            host.register(stream, frame);
            return Ok(());
        }
        Some(First::Client(Request {
            message: ClientMessage::Hello { version },
            req,
        })) => (version, req),
        Some(First::Client(_)) => {
            write_frame(
                &mut stream,
                &ServerMessage::error(
                    error_code::VERSION_MISMATCH,
                    format!("expected Cherry host protocol version {PROTOCOL_VERSION}"),
                ),
            )?;
            return Ok(());
        }
    };
    // Every Hello is welcomed, whatever its version: the client learns which
    // version this host speaks.
    write_frame(
        &mut stream,
        &Response::new(
            req,
            ServerMessage::Welcome {
                version: PROTOCOL_VERSION,
                host_id: host.id.clone(),
            },
        ),
    )?;
    if version != PROTOCOL_VERSION {
        return mismatched(stream, host, version);
    }
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
        subscribed: false,
        stream,
        host: host.clone(),
        outbox,
        last_probe: None,
    };
    connection.serve();
    if connection.subscribed {
        host.unsubscribe(connection.lease);
    }
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
    /// Names this connection: its attachment, its subscription.
    lease: u64,
    cancelled: Arc<AtomicBool>,
    attached: Option<Arc<Session>>,
    /// Whether it asked for events.
    subscribed: bool,
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
    /// Queue a frame: the reply to the request `req` identified, if any.
    fn reply(&self, req: Option<u64>, message: ServerMessage) {
        if let Ok(frame) = encode_frame(&Response::new(req, message)) {
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
            let (message, req) = match read_frame::<_, Request>(&mut self.stream) {
                Ok(Some(Request { message, req })) => (message, req),
                Ok(None) | Err(_) => return,
            };
            // Whatever answers an attachment's requests is attachment traffic.
            let req = req.filter(|_| !message.belongs_to_attachment());
            if self.cancelled.load(Ordering::SeqCst) {
                return;
            }
            // Only input waits for room: this client's heartbeats and resizes
            // keep flowing while another client's paste fills the session.
            if matches!(message, ClientMessage::Input { .. }) && !self.wait_for_input_room() {
                return;
            }
            let flow = match self.dispatch(message, req) {
                Ok((reply, flow)) => {
                    if let Some(reply) = reply {
                        self.reply(req, reply);
                    }
                    flow
                }
                Err(error) => {
                    let code = error
                        .downcast_ref::<Refused>()
                        .map_or(error_code::REQUEST_FAILED, |refused| refused.code);
                    self.reply(req, ServerMessage::error(code, format!("{error:#}")));
                    Flow::Continue
                }
            };
            if matches!(flow, Flow::Close) {
                return;
            }
        }
    }

    /// How long this connection may go without sending a frame: the
    /// heartbeat timeout once attached or subscribed.
    fn silence_limit(&self) -> Duration {
        if self.attached.is_some() || self.subscribed {
            daemon::config().heartbeat_timeout
        } else {
            daemon::config().idle_timeout
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
                self.reply(None, ServerMessage::Pong);
            }
        }
    }

    /// Serve one request (`req` identifies it); returns the reply, if the
    /// request did not send one itself.
    fn dispatch(
        &mut self,
        message: ClientMessage,
        req: Option<u64>,
    ) -> Result<(Option<ServerMessage>, Flow)> {
        let reply = match message {
            ClientMessage::Hello { .. } => bail!("connection already negotiated"),
            ClientMessage::Replace => {
                bail!("replace is accepted only from a client speaking a newer protocol")
            }
            ClientMessage::Subscribe => {
                if !self.subscribed {
                    // Every event follows the Ok. One published before the
                    // subscription is in what the client lists next.
                    self.reply(req, ServerMessage::Ok);
                    self.host.subscribe(self.lease, &self.outbox);
                    self.subscribed = true;
                    // Fails only once the peer is gone, which the next read
                    // reports.
                    let _ = self
                        .stream
                        .set_read_timeout(Some(daemon::config().heartbeat_timeout));
                    return Ok((None, Flow::Continue));
                }
                ServerMessage::Ok
            }
            ClientMessage::SendInput { id, data } => {
                if data.len() > cherry_protocol::MAX_INPUT_BYTES {
                    bail!("input frame exceeds limit");
                }
                self.send_input(&id, data)?;
                ServerMessage::Ok
            }
            ClientMessage::Screen {
                id,
                scrollback,
                max_lines,
            } => {
                let session = self.session(&id)?;
                let (reply, replied) = mpsc::sync_channel(1);
                session
                    .send(Command::Screen {
                        scrollback,
                        max_lines,
                        reply,
                    })
                    .map_err(|_| self.gone(&id))?;
                match replied.recv_timeout(REQUEST_TIMEOUT) {
                    Ok(reply) => reply,
                    Err(mpsc::RecvTimeoutError::Timeout) => bail!("the session did not answer"),
                    Err(mpsc::RecvTimeoutError::Disconnected) => return Err(self.gone(&id)),
                }
            }
            ClientMessage::Update { id, name, tags } => {
                if name
                    .as_ref()
                    .is_some_and(|name| name.len() > MAX_NAME_BYTES)
                {
                    bail!("a session name is at most {MAX_NAME_BYTES} bytes");
                }
                if let Some(tags) = &tags {
                    cherry_protocol::check_tags(tags).map_err(anyhow::Error::msg)?;
                }
                let session = self.session(&id)?;
                let (ack, acknowledged) = mpsc::sync_channel(1);
                session
                    .send(Command::Update { name, tags, ack })
                    .map_err(|_| self.gone(&id))?;
                match acknowledged.recv_timeout(REQUEST_TIMEOUT) {
                    Ok(true) => ServerMessage::Ok,
                    Ok(false) => return Err(unknown_session(&id)),
                    Err(mpsc::RecvTimeoutError::Timeout) => bail!("the session did not answer"),
                    Err(mpsc::RecvTimeoutError::Disconnected) => return Err(self.gone(&id)),
                }
            }
            ClientMessage::Ping => ServerMessage::Pong,
            ClientMessage::List => {
                // A daemon that just started lists the sessions of holders
                // still registering again, as it would a moment later.
                self.host.wait_for_holders(None);
                // Counted before the sessions are: a holder that registers
                // in between is listed, counted, or both, never neither.
                let pending_holders = self.host.pending_holders();
                let registry = self.host.registry();
                let mut sessions: Vec<_> = registry
                    .sessions
                    .values()
                    .map(|s| s.snapshot_info())
                    .collect();
                sessions.sort_by(|a, b| a.id.cmp(&b.id));
                ServerMessage::Sessions {
                    host_id: self.host.id.clone(),
                    sessions,
                    pending_holders,
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
                owner,
                tags,
            } => self.create(request_id, name, cwd, command, env, cols, rows, owner, tags)?,
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
                let attach = session.send(Command::Attach {
                    lease: self.lease,
                    cols,
                    rows,
                    takeover,
                    answers_queries,
                    outbox: self.outbox.clone(),
                    abort: self.stream.try_clone()?,
                    cancelled: self.cancelled.clone(),
                    ack,
                });
                attach.map_err(|_| self.gone(&id))?;
                // The worker replies itself: the snapshot, or why it failed.
                match acknowledged.recv_timeout(HOLDER_TIMEOUT) {
                    Ok(true) => {
                        self.attached = Some(session);
                        self.stream
                            .set_read_timeout(Some(daemon::config().heartbeat_timeout))?;
                    }
                    Ok(false) => {}
                    Err(mpsc::RecvTimeoutError::Timeout) => {
                        // A stopped holder: give up, and end the connection
                        // rather than attach it later.
                        self.cancelled.store(true, Ordering::SeqCst);
                        session.wake();
                        bail!("the session did not answer");
                    }
                    Err(mpsc::RecvTimeoutError::Disconnected) => return Err(self.gone(&id)),
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
                        // The input is delivered whenever a stopped holder
                        // resumes; the detach need not wait for it.
                        let _ = acknowledged.recv_timeout(HOLDER_TIMEOUT);
                    }
                }
                return Ok((Some(ServerMessage::Ok), Flow::Close));
            }
            ClientMessage::Kill { id } => {
                self.session(&id)?.kill();
                ServerMessage::Ok
            }
            ClientMessage::Remove { id } => {
                self.host.wait_for_holders(Some(&id));
                let session = {
                    let mut registry = self.host.registry();
                    let session = registry
                        .sessions
                        .get(&id)
                        .ok_or_else(|| unknown_session(&id))?
                        .clone();
                    if session.snapshot_info().state == SessionState::Running {
                        bail!("terminate the running session before removing it");
                    }
                    registry.sessions.remove(&id);
                    registry.receipts.remove_session(&id);
                    session
                };
                // Its holder exits once told.
                session.remove();
                self.host.publish(SessionEvent::Removed { id });
                ServerMessage::Ok
            }
            ClientMessage::Shutdown => {
                stop_without_sessions(&self.host)?;
                // Acknowledge once the socket is gone and the lock is free:
                // the client may start a new host right away.
                self.host.wait_until_released(FLUSH_TIMEOUT);
                ServerMessage::Ok
            }
        };
        Ok((Some(reply), Flow::Continue))
    }

    fn session(&self, id: &str) -> Result<Arc<Session>> {
        self.host.wait_for_holders(Some(id));
        self.host
            .registry()
            .sessions
            .get(id)
            .cloned()
            .ok_or_else(|| unknown_session(id))
    }

    /// Why the worker of a session found a moment ago is gone: the session
    /// was removed meanwhile, unless it is still listed.
    fn gone(&self, id: &str) -> anyhow::Error {
        if self.host.registry().sessions.contains_key(id) {
            anyhow::anyhow!("session is unavailable")
        } else {
            unknown_session(id)
        }
    }

    /// Write to a session's terminal without attaching. Like an attached
    /// client's input it counts against the session's input waiting for
    /// its program (`InputGate`); while too much waits, this waits for room,
    /// up to `Config::input_wait`, and then fails, rather than hold back
    /// this connection's other requests for good.
    fn send_input(&self, id: &str, data: Vec<u8>) -> Result<()> {
        let session = self.session(id)?;
        let not_running = || refused(error_code::NOT_RUNNING, "the session has exited");
        if !session.is_running() {
            return Err(not_running());
        }
        if session.input.full() && !session.input.wait_for_room(daemon::config().input_wait) {
            bail!("the session's program is not reading its input");
        }
        if !session.is_running() {
            return Err(not_running());
        }
        let len = data.len();
        session.input.reserve(len);
        if session.send(Command::Send { data }).is_err() {
            session.input.release(len);
            return Err(self.gone(id));
        }
        Ok(())
    }

    /// The existing session for a retried request, if any.
    fn receipt(&self, request_id: &str, fingerprint: &str) -> Result<Option<ServerMessage>> {
        let mut registry = self.host.registry();
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
        owner: Option<String>,
        tags: BTreeMap<String, String>,
    ) -> Result<ServerMessage> {
        Uuid::parse_str(&request_id).context("request_id must be a UUID")?;
        if name.len() > 256 || cwd.len() > 4096 {
            bail!("launch description exceeds limit");
        }
        if owner
            .as_ref()
            .is_some_and(|owner| owner.len() > cherry_protocol::MAX_OWNER_BYTES)
        {
            bail!("owner exceeds {} bytes", cherry_protocol::MAX_OWNER_BYTES);
        }
        cherry_protocol::check_tags(&tags).map_err(anyhow::Error::msg)?;
        // The size is attachment state, not part of what was launched: a
        // retry from a resized terminal is still the same request.
        let fingerprint = serde_json::to_string(&(&name, &cwd, &command, &env, &owner, &tags))?;
        if let Some(created) = self.receipt(&request_id, &fingerprint)? {
            return Ok(created);
        }
        let env = environment::client_env(env)?;
        // Resolving the directory can block on a hung filesystem; do it
        // before taking any lock shared with other clients.
        let resolved = environment::resolve_cwd(&cwd)?;
        let pwd = environment::logical_cwd(&cwd, &resolved);
        // The session must not start with an agent whose client is gone.
        self.host.prune_agent_link();
        // A retry of a request whose session a restarted daemon has not
        // seen again yet must find it.
        self.host.wait_for_holders(None);
        let _launch = self.host.launches.lock().unwrap_or_else(|e| e.into_inner());
        if self.host.stopping.load(Ordering::SeqCst) {
            bail!("host is shutting down");
        }
        if let Some(created) = self.receipt(&request_id, &fingerprint)? {
            return Ok(created);
        }
        if self.host.registry().sessions.len() >= MAX_SESSIONS {
            bail!("host session limit reached ({MAX_SESSIONS} including exited sessions; remove finished sessions)");
        }
        let session = Session::spawn(
            Launch {
                name,
                cwd: resolved,
                pwd,
                command,
                env,
                cols,
                rows,
                owner,
                tags,
                agent_link: self.host.agent_link(),
                receipt: link::Receipt {
                    request_id: request_id.clone(),
                    fingerprint: fingerprint.clone(),
                },
            },
            &self.host,
        )?;
        let info = session.snapshot_info();
        {
            let mut registry = self.host.registry();
            registry
                .receipts
                .insert(request_id, fingerprint, info.id.clone());
            registry.sessions.insert(info.id.clone(), session.clone());
        }
        self.host.publish(SessionEvent::Added {
            session: info.clone(),
        });
        session.start();
        Ok(ServerMessage::Created { session: info })
    }
}

fn unknown_session(id: &str) -> anyhow::Error {
    refused(error_code::UNKNOWN_SESSION, format!("unknown session {id}"))
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
