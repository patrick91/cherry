//! The long-lived daemon: owns the socket, the state directory's lock, the
//! registry of sessions and every client connection, and never exits
//! because of a transient error. Sessions themselves live in holder
//! processes (see `holder`), which register with whichever daemon serves
//! the socket, so a daemon can crash or be replaced without ending them.
use crate::{
    connection::{self, Receipts},
    environment,
    link::{self, kind, Frame},
    outbox::{EventKey, Outbox},
    paths, processes,
    session::{self, Session},
};
use anyhow::{bail, Context, Result};
use cherry_protocol::{encode_frame, ServerMessage, SessionEvent};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    fs::{self, File, OpenOptions},
    io::{self, Write},
    os::unix::{
        fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt},
        io::AsRawFd,
        net::{UnixListener, UnixStream},
    },
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
        mpsc::{self, RecvTimeoutError},
        Arc, Condvar, Mutex, OnceLock,
    },
    thread,
    time::{Duration, Instant},
};

pub const MAX_CONNECTIONS: usize = 128;
/// Timestamps of the socket and its directory are refreshed this often, so
/// age-based tmp cleaners never consider them stale.
const TOUCH_INTERVAL: Duration = Duration::from_secs(60 * 60);
/// The daemon's own descriptor limit is raised to at most this.
const MAX_FD_LIMIT: libc::rlim_t = 16384;
/// How long a client keeps lending its agent after its last connection ends:
/// it may connect again, or hand over to the next client, as `cherry new`
/// does to the `cherry attach` that follows it.
const AGENT_RELEASE_GRACE: Duration = Duration::from_secs(2);
/// How often lent agents are checked while clients may be lending them.
const AGENT_CHECK_INTERVAL: Duration = Duration::from_secs(1);
/// How long `List` (and a request naming a session) waits for the holders a
/// starting daemon expects to register again.
const HOLDER_WAIT: Duration = Duration::from_secs(1);
/// How long telling a holder why it is turned away may take.
const REFUSAL_TIMEOUT: Duration = Duration::from_secs(1);
/// Bells, notifications and progress reports published while nobody is
/// subscribed wait this long for the next subscriber, at most this many:
/// the ones a holder kept while no daemon ran reach the app that
/// reconnects after the daemon it used went away.
const UNOBSERVED_FOR: Duration = Duration::from_secs(30);
const UNOBSERVED_EVENTS: usize = 64;
/// How long a `SendInput` waits for its session's program to take earlier
/// input when too much of it waits already.
const INPUT_WAIT: Duration = Duration::from_secs(5);
/// A session's output goes at the pace of its fastest client that takes
/// some of it (see `session::Worker::pace`), so a flood reaches that client
/// whole; one that takes none of it for this long holds nothing back any
/// more, and lags instead, so that a stuck client never stops the program
/// for good. While another client takes output, it holds nothing back after
/// a much shorter while (see `outbox::IDLE_AFTER`).
const STALL_TIMEOUT: Duration = Duration::from_secs(2);

/// Write one line to the daemon's log (its stderr). A failed write, such as
/// a full disk or a closed journal stream, is ignored: unlike `eprintln!`,
/// logging never panics, and the daemon never ends because of it.
pub fn log(message: impl std::fmt::Display) {
    let _ = writeln!(io::stderr().lock(), "cherry-host: {message}");
}

/// Tunables read once when `serve` starts. The environment overrides exist
/// for tests.
pub struct Config {
    /// An attached or subscribed client that sends nothing for this long is
    /// dropped.
    pub heartbeat_timeout: Duration,
    /// Any other client that sends nothing for this long is dropped.
    pub idle_timeout: Duration,
    /// How long a `SendInput` waits for room (see `INPUT_WAIT`).
    pub input_wait: Duration,
    /// Delay between SIGHUP, SIGTERM and SIGKILL when killing a session.
    pub kill_grace: Duration,
    /// How often the socket's timestamps are refreshed.
    pub touch_interval: Duration,
    /// How long a client keeps lending its agent after its last connection.
    pub agent_grace: Duration,
    /// How long requests wait for the holders a starting daemon expects
    /// (see `HOLDER_WAIT`).
    pub holder_wait: Duration,
    /// How long a client that takes none of its output holds the session's
    /// output back (see `STALL_TIMEOUT`).
    pub stall_timeout: Duration,
}

pub fn config() -> &'static Config {
    static CONFIG: OnceLock<Config> = OnceLock::new();
    CONFIG.get_or_init(|| {
        let millis = |name: &str| {
            std::env::var(name)
                .ok()
                .and_then(|value| value.parse().ok())
                .map(Duration::from_millis)
        };
        Config {
            heartbeat_timeout: millis("CHERRY_HOST_HEARTBEAT_TIMEOUT_MS")
                .unwrap_or(cherry_protocol::HEARTBEAT_TIMEOUT),
            idle_timeout: millis("CHERRY_HOST_IDLE_TIMEOUT_MS")
                .unwrap_or(cherry_protocol::IDLE_TIMEOUT),
            input_wait: millis("CHERRY_HOST_INPUT_WAIT_MS").unwrap_or(INPUT_WAIT),
            kill_grace: millis("CHERRY_HOST_KILL_GRACE_MS").unwrap_or(Duration::from_secs(2)),
            touch_interval: millis("CHERRY_HOST_TOUCH_INTERVAL_MS").unwrap_or(TOUCH_INTERVAL),
            agent_grace: millis("CHERRY_HOST_AGENT_GRACE_MS").unwrap_or(AGENT_RELEASE_GRACE),
            holder_wait: millis("CHERRY_HOST_HOLDER_WAIT_MS").unwrap_or(HOLDER_WAIT),
            stall_timeout: millis("CHERRY_HOST_STALL_TIMEOUT_MS").unwrap_or(STALL_TIMEOUT),
        }
    })
}

static CHILD_FD_LIMIT: OnceLock<libc::rlimit> = OnceLock::new();

/// The descriptor limit sessions should start with: the one the daemon had
/// before raising its own.
pub fn child_fd_limit() -> Option<libc::rlimit> {
    CHILD_FD_LIMIT.get().copied()
}

/// Raise the soft descriptor limit toward the hard limit. macOS shells start
/// with 256, which a daemon with many sessions and clients would exhaust.
fn raise_fd_limit() {
    let mut limit: libc::rlimit = unsafe { std::mem::zeroed() };
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) } != 0 {
        return;
    }
    let _ = CHILD_FD_LIMIT.set(limit);
    #[allow(unused_mut)]
    let mut target = limit.rlim_max.min(MAX_FD_LIMIT);
    #[cfg(target_os = "macos")]
    {
        // The kernel refuses more than kern.maxfilesperproc.
        let mut max: libc::c_int = 0;
        let mut size = std::mem::size_of::<libc::c_int>();
        if unsafe {
            libc::sysctlbyname(
                c"kern.maxfilesperproc".as_ptr(),
                (&mut max as *mut libc::c_int).cast(),
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        } == 0
            && max > 0
        {
            target = target.min(max as libc::rlim_t);
        }
    }
    if target <= limit.rlim_cur {
        return;
    }
    let raised = libc::rlimit {
        rlim_cur: target,
        rlim_max: limit.rlim_max,
    };
    if unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &raised) } != 0 {
        // Older macOS releases cap the soft limit at OPEN_MAX.
        #[cfg(target_os = "macos")]
        unsafe {
            let fallback = libc::rlimit {
                rlim_cur: target.min(10240),
                rlim_max: limit.rlim_max,
            };
            libc::setrlimit(libc::RLIMIT_NOFILE, &fallback);
        }
    }
}

pub struct Registry {
    pub sessions: HashMap<String, Arc<Session>>,
    pub receipts: Receipts,
}

pub struct Host {
    pub id: String,
    /// The socket this daemon serves, which holders dial.
    pub socket: PathBuf,
    /// Holds the socket and the agent link given to sessions.
    pub socket_dir: PathBuf,
    /// The state directory: identity, lock, log and session manifests.
    pub state: PathBuf,
    pub registry: Mutex<Registry>,
    /// Sessions whose holders have manifests but have not registered with
    /// this daemon yet, and are still waited for.
    expected: Mutex<HashSet<String>>,
    expected_changed: Condvar,
    /// The same holders, with their manifests, until they register, are
    /// turned away, or are gone: those a `List` reports as pending, however
    /// long they take.
    awaited: Mutex<HashMap<String, paths::Manifest>>,
    /// Sessions whose holders were gone when this daemon started, without
    /// having ended: each left its manifest behind (a holder that exits
    /// removes it), so it was killed, as a log out or restart kills the
    /// user's processes (`ServerMessage::Sessions::lost_sessions`). Sorted.
    pub lost: Vec<String>,
    /// Serializes launches with each other and with shutdown.
    pub launches: Mutex<()>,
    pub stopping: AtomicBool,
    pub next_lease: AtomicU64,
    pub connections: AtomicUsize,
    stop: UnixStream,
    /// Set once a stopping daemon removed its socket and released its lock.
    released: Mutex<bool>,
    released_changed: Condvar,
    /// Client processes with an open connection or a pending agent release.
    clients: Mutex<HashMap<u32, Client>>,
    /// Wakes `watch_agents` when a connection arrives.
    agents_wake: mpsc::SyncSender<()>,
    /// Holders turned away, for the log.
    refusals: Mutex<Diagnostics>,
    /// Subscribed connections, and what they have not heard yet.
    subscribers: Mutex<Subscribers>,
}

/// Connections that asked for events (`Subscribe`).
#[derive(Default)]
struct Subscribers {
    /// Each one's lease (which names its connection) and outbox.
    connections: Vec<(u64, Arc<Outbox>)>,
    /// Bells, notifications and progress reports published while there
    /// were none, and when (see `UNOBSERVED_FOR`).
    unobserved: VecDeque<(Instant, Arc<Vec<u8>>)>,
}

#[derive(Default)]
struct Client {
    connections: usize,
    /// Releases of its agent that wait out `Config::agent_grace`.
    releases: usize,
}

impl Host {
    pub fn stop(&self) {
        self.stopping.store(true, Ordering::SeqCst);
        let _ = (&self.stop).write(&[1]);
    }

    /// Tell every subscribed connection (see `Outbox::push_event`). Events
    /// are pushed to all of them in the order they are published. What only
    /// an event reports (bells, notifications, progress) waits for the next
    /// subscriber while there is none, briefly (`UNOBSERVED_FOR`); the rest
    /// a subscriber learns by listing the sessions.
    pub fn publish(&self, event: SessionEvent) {
        let (key, seals) = EventKey::of(&event);
        let kept = matches!(
            event,
            SessionEvent::Bell { .. }
                | SessionEvent::Notification { .. }
                | SessionEvent::Progress { .. }
        );
        if !kept && self.subscribers().connections.is_empty() {
            return;
        }
        let Ok(frame) = encode_frame(&ServerMessage::Event { event }) else {
            return;
        };
        let frame = Arc::new(frame);
        let mut subscribers = self.subscribers();
        subscribers
            .connections
            .retain(|(_, outbox)| outbox.push_event(frame.clone(), key.clone(), &seals));
        if subscribers.connections.is_empty() && kept {
            let now = Instant::now();
            let unobserved = &mut subscribers.unobserved;
            while unobserved.len() >= UNOBSERVED_EVENTS
                || unobserved
                    .front()
                    .is_some_and(|(at, _)| now.duration_since(*at) >= UNOBSERVED_FOR)
            {
                unobserved.pop_front();
            }
            unobserved.push_back((now, frame));
        }
    }

    /// Push events to `outbox` from now on, starting with those nobody has
    /// heard yet (see `publish`).
    pub fn subscribe(&self, lease: u64, outbox: &Arc<Outbox>) {
        let mut subscribers = self.subscribers();
        let now = Instant::now();
        for (at, frame) in std::mem::take(&mut subscribers.unobserved) {
            if now.duration_since(at) < UNOBSERVED_FOR {
                outbox.push_event(frame, None, &[]);
            }
        }
        subscribers.connections.push((lease, outbox.clone()));
    }

    pub fn unsubscribe(&self, lease: u64) {
        self.subscribers()
            .connections
            .retain(|(subscriber, _)| *subscriber != lease);
    }

    fn subscribers(&self) -> std::sync::MutexGuard<'_, Subscribers> {
        self.subscribers.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Wait up to `HOLDER_WAIT` (`Config::holder_wait`) for the holders
    /// this daemon expects to register again: every one of them, or only
    /// `id`'s. Those still missing then are not waited for again.
    pub fn wait_for_holders(&self, id: Option<&str>) {
        let mut expected = self.expected.lock().unwrap_or_else(|e| e.into_inner());
        let pending = |expected: &HashSet<String>| match id {
            Some(id) => expected.contains(id),
            None => !expected.is_empty(),
        };
        if !pending(&expected) {
            return;
        }
        let deadline = Instant::now() + config().holder_wait;
        while pending(&expected) {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            expected = self
                .expected_changed
                .wait_timeout(expected, left)
                .unwrap_or_else(|e| e.into_inner())
                .0;
        }
        match id {
            Some(id) => {
                expected.remove(id);
            }
            None => expected.clear(),
        }
    }

    /// A holder dialed the socket and said `HolderHello` (`frame`): serve its
    /// session. A holder this daemon can never serve is told so (see
    /// `link::Refused`). A holder whose session is already served over
    /// another link is turned away for now, as is every holder while the
    /// daemon stops: the next daemon adopts them.
    pub fn register(self: &Arc<Self>, stream: UnixStream, frame: Frame) {
        #[derive(serde::Deserialize)]
        struct Named {
            id: String,
        }
        let named = frame.meta::<Named>().ok().map(|named| named.id);
        if frame.version < link::MIN_LINK_VERSION {
            let reason = format!(
                "this host serves holders of link version {} or later, not {}",
                link::MIN_LINK_VERSION,
                frame.version
            );
            return self.refuse(stream, named.as_deref(), reason, false, true);
        }
        let hello: link::HolderHello = match frame.meta() {
            Ok(hello) => hello,
            Err(error) => {
                let reason = format!("{error:#}");
                return self.refuse(stream, named.as_deref(), reason, false, true);
            }
        };
        if uuid::Uuid::parse_str(&hello.id).is_err() {
            let reason = "its session ID is not a UUID".to_string();
            return self.refuse(stream, None, reason, false, true);
        }
        let id = hello.id.clone();
        let receipt = hello.receipt.clone();
        // After any launch in progress, and never once stopping.
        let launch = self.launches.lock().unwrap_or_else(|e| e.into_inner());
        if self.stopping.load(Ordering::SeqCst) {
            drop(launch);
            let reason = "this host is stopping".to_string();
            return self.refuse(stream, Some(&id), reason, true, false);
        }
        let replaced = self.registry().sessions.get(&id).cloned();
        if replaced.as_ref().is_some_and(|session| session.is_linked()) {
            drop(launch);
            let reason = "another holder of this session is connected".to_string();
            return self.refuse(stream, Some(&id), reason, true, true);
        }
        let (session, held) = match Session::adopt(self, stream, hello, frame.version) {
            Ok(adopted) => adopted,
            Err(error) => {
                // Out of resources: to the holder it is a lost link, and it
                // dials again with backoff.
                self.refusals
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .report(format_args!("session {id}: cannot serve it: {error:#}"));
                return;
            }
        };
        let info = session.snapshot_info();
        {
            let mut registry = self.registry();
            if let Some(receipt) = receipt {
                registry
                    .receipts
                    .insert(receipt.request_id, receipt.fingerprint, id.clone());
            }
            registry.sessions.insert(id.clone(), session.clone());
        }
        {
            let mut expected = self.expected.lock().unwrap_or_else(|e| e.into_inner());
            expected.remove(&id);
        }
        self.expected_changed.notify_all();
        self.awaited().remove(&id);
        drop(launch);
        self.publish(match replaced {
            Some(_) => SessionEvent::Changed { session: info },
            None => SessionEvent::Added { session: info },
        });
        // What happened while it had no daemon, once the session is known.
        for event in held {
            self.publish(event);
        }
        session.start();
    }

    /// Turn a holder away, telling it why and whether to dial again, and
    /// stop waiting for it.
    fn refuse(
        &self,
        mut stream: UnixStream,
        id: Option<&str>,
        reason: String,
        retry: bool,
        report: bool,
    ) {
        if let Some(id) = id {
            self.expected
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .remove(id);
            self.expected_changed.notify_all();
            self.awaited().remove(id);
        }
        if report {
            let holder = id.map_or_else(
                || "a session holder".to_string(),
                |id| format!("the holder of session {id}"),
            );
            self.refusals
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .report(format_args!("refusing {holder}: {reason}"));
        }
        let _ = stream.set_write_timeout(Some(REFUSAL_TIMEOUT));
        let _ = link::write_blocking(
            &mut stream,
            &link::encode(kind::REFUSED, &link::Refused { reason, retry }, &[]),
        );
    }

    pub fn registry(&self) -> std::sync::MutexGuard<'_, Registry> {
        self.registry.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn awaited(&self) -> std::sync::MutexGuard<'_, HashMap<String, paths::Manifest>> {
        self.awaited.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// How many holders this daemon found manifests of when it started and
    /// still waits to hear from (`ServerMessage::Sessions::pending_holders`):
    /// they have not registered, and their processes still run (a stopped
    /// one registers once it is continued). One that is gone is forgotten;
    /// its session is not coming back.
    pub fn pending_holders(&self) -> u32 {
        let mut awaited = self.awaited();
        awaited.retain(|_, manifest| {
            holder_exists(manifest) && !processes::is_zombie(manifest.holder_pid as libc::pid_t)
        });
        u32::try_from(awaited.len()).unwrap_or(u32::MAX)
    }

    /// After `stop`, wait up to `timeout` until the daemon no longer holds
    /// its socket or its lock, so that a new host can start at once.
    pub fn wait_until_released(&self, timeout: Duration) {
        let released = self.released.lock().unwrap_or_else(|e| e.into_inner());
        let _ = self
            .released_changed
            .wait_timeout_while(released, timeout, |released| !*released);
    }

    fn set_released(&self) {
        *self.released.lock().unwrap_or_else(|e| e.into_inner()) = true;
        self.released_changed.notify_all();
    }

    pub fn agent_link(&self) -> PathBuf {
        self.socket_dir.join(cherry_protocol::AGENT_LINK_NAME)
    }

    /// Forget agents lent by clients that are gone, before a session starts.
    pub fn prune_agent_link(&self) {
        self.release_agents(None);
    }

    /// Forget the agents of clients that no longer lend them, and agents
    /// that are gone (see `release_agent_link`). A client lends its agent
    /// while it has a connection, while its release waits out the grace
    /// period, and, unless it is `released`, while its process runs (its
    /// connection may not have been accepted yet).
    fn release_agents(&self, released: Option<u32>) {
        let _ = cherry_protocol::release_agent_link(&self.socket_dir, |pid| {
            self.clients().contains_key(&pid) || (Some(pid) != released && process_exists(pid))
        });
    }

    fn client_connected(&self, pid: u32) {
        self.update_client(pid, |client| client.connections += 1);
    }

    /// A connection of client process `pid` ended. After its last one, a
    /// client that lent its agent (`update_agent_link`) keeps lending it for
    /// the grace period; the link then returns to an agent that another
    /// client lends, or is removed. An agent that disappears meanwhile is
    /// given up at once: another user could create its path again.
    fn client_left(&self, pid: u32) {
        let last = self.update_client(pid, |client| {
            client.connections = client.connections.saturating_sub(1);
            let last = client.connections == 0;
            client.releases += usize::from(last);
            last
        });
        if !last {
            return;
        }
        // The record of what it lent: a symlink to its agent.
        let record = self
            .socket_dir
            .join(cherry_protocol::AGENT_CLIENTS_DIR)
            .join(pid.to_string());
        let lent = fs::symlink_metadata(&record).is_ok();
        let deadline = Instant::now() + config().agent_grace;
        while lent
            && Instant::now() < deadline
            && !self.client_is_connected(pid)
            && is_own_socket(&record)
        {
            thread::sleep(Duration::from_millis(20));
        }
        self.update_client(pid, |client| client.releases -= 1);
        if lent {
            self.release_agents(Some(pid));
        }
    }

    fn client_is_connected(&self, pid: u32) -> bool {
        self.clients()
            .get(&pid)
            .is_some_and(|client| client.connections > 0)
    }

    /// Change what is known about client process `pid`, forgetting it once
    /// it has neither connections nor pending releases.
    fn update_client<T>(&self, pid: u32, change: impl FnOnce(&mut Client) -> T) -> T {
        let mut clients = self.clients();
        let client = clients.entry(pid).or_default();
        let result = change(client);
        if client.connections == 0 && client.releases == 0 {
            clients.remove(&pid);
        }
        result
    }

    fn clients(&self) -> std::sync::MutexGuard<'_, HashMap<u32, Client>> {
        self.clients.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// An existing socket (after following links) owned by this user.
fn is_own_socket(path: &Path) -> bool {
    fs::metadata(path).is_ok_and(|meta| meta.file_type().is_socket() && meta.uid() == paths::euid())
}

fn process_exists(pid: u32) -> bool {
    // 0 and values beyond pid_t would address process groups.
    i32::try_from(pid).is_ok_and(|pid| pid > 0 && unsafe { libc::kill(pid, 0) } == 0)
}

/// Whether the holder a manifest names still runs: its PID exists, and was
/// not given to another process since (unless that cannot be told).
fn holder_exists(manifest: &paths::Manifest) -> bool {
    if !process_exists(manifest.holder_pid) {
        return false;
    }
    match (
        &manifest.holder_started,
        processes::start_identity(manifest.holder_pid as libc::pid_t),
    ) {
        (Some(recorded), Some(current)) => *recorded == current,
        _ => true,
    }
}

/// Check lent agents every `AGENT_CHECK_INTERVAL` while clients are
/// connected or an agent is linked. A client can stay connected after its
/// agent is gone (`ssh-agent -k`, or the agent's owner exited), and the link
/// must not keep naming a path that another local user could create.
fn watch_agents(host: &Host, wake: mpsc::Receiver<()>) {
    let mut next = Instant::now() + AGENT_CHECK_INTERVAL;
    while !host.stopping.load(Ordering::SeqCst) {
        let busy = host.connections.load(Ordering::SeqCst) > 0
            || fs::symlink_metadata(host.agent_link()).is_ok();
        if !busy {
            if wake.recv().is_err() {
                return;
            }
            next = Instant::now() + AGENT_CHECK_INTERVAL;
            continue;
        }
        let now = Instant::now();
        if now >= next {
            host.release_agents(None);
            next = now + AGENT_CHECK_INTERVAL;
            continue;
        }
        if let Err(RecvTimeoutError::Disconnected) = wake.recv_timeout(next - now) {
            return;
        }
    }
}

/// The process at the other end of a connection.
#[cfg(target_os = "linux")]
fn peer_pid(stream: &UnixStream) -> Option<u32> {
    let mut credentials: libc::ucred = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let found = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut len,
        )
    } == 0;
    // 0: the peer is in another PID namespace.
    (found && credentials.pid > 0).then_some(credentials.pid as u32)
}

/// The process at the other end of a connection.
#[cfg(target_os = "macos")]
fn peer_pid(stream: &UnixStream) -> Option<u32> {
    let mut pid: libc::pid_t = 0;
    let mut len = std::mem::size_of::<libc::pid_t>() as libc::socklen_t;
    let found = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_LOCAL,
            libc::LOCAL_PEERPID,
            (&mut pid as *mut libc::pid_t).cast(),
            &mut len,
        )
    } == 0;
    (found && pid > 0).then_some(pid as u32)
}

/// Removes the socket this daemon bound, and nothing that replaced it.
struct SocketGuard {
    path: PathBuf,
    identity: (u64, u64),
}

impl Drop for SocketGuard {
    fn drop(&mut self) {
        if fs::symlink_metadata(&self.path)
            .is_ok_and(|meta| (meta.dev(), meta.ino()) == self.identity)
        {
            let _ = fs::remove_file(&self.path);
        }
    }
}

pub fn serve(path: &Path) -> Result<()> {
    // Nothing the starter left open (a script's lock file, a pipe) may be
    // held for the daemon's lifetime, and its cwd must not pin a volume.
    environment::close_inherited_fds();
    let _ = std::env::set_current_dir("/");
    // Connection threads and session workers run at interactive priority
    // while they serve an attachment; every other thread, and the holders
    // started from them, at the default class.
    cherry_protocol::priority::prepare_process();
    let _ = config();
    raise_fd_limit();
    session::note_executable();
    let socket_dir = paths::socket_dir(path)?;
    let state = paths::open_state_dir(path)?;
    let lock_path = state.join("host.lock");
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&lock_path)
        .with_context(|| format!("opening {}", lock_path.display()))?;
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        bail!(
            "another cherry-host is already running for {} (it holds {})",
            path.display(),
            lock_path.display()
        );
    }
    remove_stale_socket(path)?;
    let id = paths::host_id(&state)?;
    // Holders that outlived the last daemon register again; wait for them
    // before answering who has which sessions. A holder that is gone left
    // its manifest behind, and its PID may belong to another process now.
    let mut expected = HashSet::new();
    let mut awaited = HashMap::new();
    let mut lost = Vec::new();
    for (manifest_path, manifest) in paths::read_manifests(&state) {
        if !holder_exists(&manifest) {
            let _ = fs::remove_file(manifest_path);
            lost.push(manifest.id);
        } else if manifest.link_version >= link::MIN_LINK_VERSION {
            expected.insert(manifest.id.clone());
            awaited.insert(manifest.id.clone(), manifest);
        }
    }
    lost.sort();
    let listener =
        UnixListener::bind(path).with_context(|| format!("binding {}", path.display()))?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    let meta = fs::symlink_metadata(path)?;
    let socket = SocketGuard {
        path: path.to_path_buf(),
        identity: (meta.dev(), meta.ino()),
    };
    let (stop, stopped) = UnixStream::pair()?;
    stop.set_nonblocking(true)?;
    let (agents_wake, agents_woken) = mpsc::sync_channel(1);
    let host = Arc::new(Host {
        id,
        socket: path.to_path_buf(),
        socket_dir,
        state,
        registry: Mutex::new(Registry {
            sessions: HashMap::new(),
            receipts: Receipts::default(),
        }),
        expected: Mutex::new(expected),
        expected_changed: Condvar::new(),
        awaited: Mutex::new(awaited),
        lost,
        launches: Mutex::new(()),
        stopping: AtomicBool::new(false),
        next_lease: AtomicU64::new(1),
        connections: AtomicUsize::new(0),
        stop,
        released: Mutex::new(false),
        released_changed: Condvar::new(),
        clients: Mutex::new(HashMap::new()),
        agents_wake,
        refusals: Mutex::new(Diagnostics::default()),
        subscribers: Mutex::new(Subscribers::default()),
    });
    let watched = host.clone();
    if let Err(error) = thread::Builder::new()
        .name("cherry-agents".into())
        .spawn(move || watch_agents(&watched, agents_woken))
    {
        log(format_args!("cannot watch lent agents: {error}"));
    }
    accept_loop(&listener, &stopped, &host, path);
    // Give up the socket and the lock before Shutdown or Replace is
    // acknowledged, so a client can start a new host right away instead of
    // reaching a listener that no longer accepts. A successor that takes
    // the lock must never find our socket and have it deleted afterwards:
    // remove it first. Holders keep their sessions when this process exits
    // and register with the successor.
    drop(listener);
    drop(socket);
    drop(lock);
    host.set_released();
    // Let shutdown replies reach their clients before the process ends.
    let deadline = Instant::now() + Duration::from_millis(500);
    while host.connections.load(Ordering::SeqCst) > 0 && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(10));
    }
    Ok(())
}

/// Replace a socket only when nothing is listening on it.
fn remove_stale_socket(path: &Path) -> Result<()> {
    let meta = match fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error).with_context(|| format!("inspecting {}", path.display())),
    };
    if !meta.file_type().is_socket() || meta.uid() != paths::euid() {
        return Err(paths::occupied_socket_path(path, "refusing to replace"));
    }
    // A listener with a full backlog can refuse a connection for a moment.
    for attempt in 0..3 {
        match UnixStream::connect(path) {
            Ok(_) => bail!("a host is already serving {}", path.display()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
            Err(error) if error.kind() == io::ErrorKind::ConnectionRefused => {
                if attempt < 2 {
                    thread::sleep(Duration::from_millis(50));
                }
            }
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("checking whether {} is live", path.display()))
            }
        }
    }
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error).with_context(|| format!("removing stale {}", path.display())),
    }
}

/// Rate-limited diagnostics for the host log.
#[derive(Default)]
struct Diagnostics {
    last: Option<Instant>,
    suppressed: usize,
}

impl Diagnostics {
    fn report(&mut self, message: impl std::fmt::Display) {
        if self
            .last
            .is_some_and(|last| last.elapsed() < Duration::from_secs(5))
        {
            self.suppressed += 1;
            return;
        }
        if self.suppressed > 0 {
            log(format_args!(
                "{message} ({} similar messages suppressed)",
                self.suppressed
            ));
        } else {
            log(message);
        }
        self.last = Some(Instant::now());
        self.suppressed = 0;
    }
}

fn accept_loop(listener: &UnixListener, stopped: &UnixStream, host: &Arc<Host>, path: &Path) {
    let _ = listener.set_nonblocking(true);
    let _ = stopped.set_nonblocking(true);
    // Held in reserve so that, out of descriptors, a pending connection can
    // still be accepted and closed instead of waking poll() forever.
    let mut reserve = File::open("/dev/null").ok();
    let mut diagnostics = Diagnostics::default();
    let interval = config().touch_interval;
    let mut next_touch = Instant::now() + interval;
    while !host.stopping.load(Ordering::SeqCst) {
        let now = Instant::now();
        if now >= next_touch {
            paths::touch(path);
            if let Some(dir) = path.parent() {
                paths::touch(dir);
            }
            next_touch = now + interval;
        }
        let timeout = next_touch
            .saturating_duration_since(now)
            .as_millis()
            .min(i32::MAX as u128) as libc::c_int;
        let mut fds = [
            libc::pollfd {
                fd: listener.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: stopped.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            },
        ];
        if unsafe { libc::poll(fds.as_mut_ptr(), 2, timeout) } < 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                diagnostics.report(format_args!("poll: {error}"));
                thread::sleep(Duration::from_millis(100));
            }
            continue;
        }
        if fds[1].revents != 0 {
            break;
        }
        if fds[0].revents == 0 {
            continue;
        }
        loop {
            match listener.accept() {
                Ok((stream, _)) => admit(stream, host, &mut diagnostics),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error)
                    if matches!(
                        error.raw_os_error(),
                        Some(libc::ECONNABORTED | libc::EINTR | libc::EPROTO)
                    ) => {}
                Err(error) if matches!(error.raw_os_error(), Some(libc::EMFILE | libc::ENFILE)) => {
                    diagnostics.report(format_args!(
                        "cannot accept a connection: {error}; closing it"
                    ));
                    // Use the reserved descriptor to take the connection off
                    // the backlog, close it, and keep serving.
                    drop(reserve.take());
                    if let Ok((stream, _)) = listener.accept() {
                        drop(stream);
                    }
                    reserve = File::open("/dev/null").ok();
                    if reserve.is_none() {
                        thread::sleep(Duration::from_millis(100));
                    }
                    break;
                }
                Err(error) => {
                    diagnostics.report(format_args!("accept: {error}"));
                    thread::sleep(Duration::from_millis(100));
                    break;
                }
            }
        }
    }
}

fn admit(stream: UnixStream, host: &Arc<Host>, diagnostics: &mut Diagnostics) {
    if cherry_protocol::verify_peer(&stream).is_err() {
        return;
    }
    // A client's frames, or a holder's link (see `connection`).
    cherry_protocol::priority::grow_send_buffer(stream.as_raw_fd());
    if host.connections.fetch_add(1, Ordering::SeqCst) >= MAX_CONNECTIONS {
        host.connections.fetch_sub(1, Ordering::SeqCst);
        return;
    }
    // Counted from the accept on: a client's next connection is then known
    // before its previous one's agent release looks for it.
    let client = peer_pid(&stream);
    if let Some(pid) = client {
        host.client_connected(pid);
    }
    let _ = host.agents_wake.try_send(());
    let connection_host = host.clone();
    let spawned = thread::Builder::new()
        .name("cherry-connection".into())
        .spawn(move || {
            // Interactive once it attaches (see `connection`).
            cherry_protocol::priority::interactive(false);
            connection::serve(stream, &connection_host);
            connection_host.connections.fetch_sub(1, Ordering::SeqCst);
            if let Some(pid) = client {
                connection_host.client_left(pid);
            }
        });
    if let Err(error) = spawned {
        host.connections.fetch_sub(1, Ordering::SeqCst);
        if let Some(pid) = client {
            host.update_client(pid, |client| {
                client.connections = client.connections.saturating_sub(1)
            });
        }
        diagnostics.report(format_args!("cannot start a connection thread: {error}"));
    }
}
