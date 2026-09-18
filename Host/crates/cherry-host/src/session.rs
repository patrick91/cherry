use crate::stream::DisplayStream;
use anyhow::{bail, Context, Result};
use cherry_protocol::{valid_size, ServerMessage, SessionInfo, SessionState, MAX_INPUT_BYTES};
use cherry_vt::Terminal;
use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use std::{
    collections::{BTreeMap, VecDeque},
    io::{Read, Write},
    os::unix::{io::AsRawFd, net::UnixStream},
    path::Path,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, SyncSender},
        Arc, Mutex,
    },
    thread,
};
use uuid::Uuid;

pub struct Session {
    pub info: Arc<Mutex<SessionInfo>>,
    tx: SyncSender<Command>,
    wake: Mutex<UnixStream>,
    kill_requested: Arc<AtomicBool>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replacing_controller_discards_only_its_unsent_input() {
        let mut pending = PendingInput::default();
        pending.push(Some(1), b"old command");
        pending.push(None, b"\x1b[1;1R");
        pending.push(Some(1), b"old remainder");
        pending.push(Some(2), b"new command");
        pending.discard_lease(1);
        let bytes: Vec<u8> = pending
            .chunks
            .iter()
            .flat_map(|chunk| chunk.bytes.iter().copied())
            .collect();
        assert_eq!(bytes, b"\x1b[1;1Rnew command");
        assert_eq!(pending.len, bytes.len());
    }
}

pub enum Command {
    Attach {
        lease: u64,
        cols: u16,
        rows: u16,
        takeover: bool,
        output: SyncSender<ServerMessage>,
        abort: UnixStream,
        cancelled: Arc<AtomicBool>,
    },
    Input {
        lease: u64,
        data: Vec<u8>,
    },
    Resize {
        lease: u64,
        cols: u16,
        rows: u16,
    },
}

struct Attachment {
    lease: u64,
    cols: u16,
    rows: u16,
    output: SyncSender<ServerMessage>,
    abort: UnixStream,
    cancelled: Arc<AtomicBool>,
}

/// Host-generated terminal replies outlive controller leases. User input does
/// not: bytes still waiting for the PTY must not execute after a handoff.
#[derive(Default)]
struct PendingInput {
    chunks: VecDeque<InputChunk>,
    len: usize,
}

struct InputChunk {
    lease: Option<u64>,
    bytes: VecDeque<u8>,
}

impl PendingInput {
    fn push(&mut self, lease: Option<u64>, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        self.len += bytes.len();
        if let Some(last) = self.chunks.back_mut().filter(|chunk| chunk.lease == lease) {
            last.bytes.extend(bytes);
        } else {
            self.chunks.push_back(InputChunk {
                lease,
                bytes: bytes.iter().copied().collect(),
            });
        }
    }

    fn discard_lease(&mut self, lease: u64) {
        self.chunks.retain(|chunk| chunk.lease != Some(lease));
        self.len = self.chunks.iter().map(|chunk| chunk.bytes.len()).sum();
    }

    fn clear(&mut self) {
        self.chunks.clear();
        self.len = 0;
    }

    fn write_to(&mut self, fd: libc::c_int) {
        let Some(chunk) = self.chunks.front_mut() else {
            return;
        };
        let bytes = chunk.bytes.make_contiguous();
        let n = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
        if n > 0 {
            chunk.bytes.drain(..n as usize);
            self.len -= n as usize;
            if chunk.bytes.is_empty() {
                self.chunks.pop_front();
            }
        }
    }
}

impl Session {
    pub fn spawn(
        name: String,
        cwd: String,
        mut command: Vec<String>,
        env: BTreeMap<String, String>,
        cols: u16,
        rows: u16,
    ) -> Result<Arc<Self>> {
        if !valid_size(cols, rows) {
            bail!("terminal size must be 2–500 columns and 1–200 rows");
        }
        if name.len() > 256
            || cwd.len() > 4096
            || command.len() > 256
            || command.iter().map(String::len).sum::<usize>() > 65536
        {
            bail!("launch description exceeds limit");
        }
        let cwd = if cwd.is_empty() || cwd == "~" {
            std::env::var("HOME").unwrap_or_else(|_| "/".into())
        } else {
            cwd
        };
        let cwd = Path::new(&cwd)
            .canonicalize()
            .context("working directory does not exist on the host")?;
        if !cwd.is_dir() {
            bail!("working directory is not a directory");
        }
        if command.is_empty() {
            command = vec![
                std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into()),
                "-l".into(),
            ];
        }
        let terminal = Terminal::new(cols, rows, 1024 * 1024)?;
        let pair = native_pty_system().openpty(size(cols, rows))?;
        let fd = pair
            .master
            .as_raw_fd()
            .context("PTY implementation has no Unix descriptor")?;
        // The one session worker owns all I/O. Nonblocking writes prevent a child
        // which stops reading input from wedging termination or other sessions.
        unsafe {
            let flags = libc::fcntl(fd, libc::F_GETFL);
            if flags < 0 || libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) < 0 {
                return Err(std::io::Error::last_os_error().into());
            }
        }
        let id = Uuid::new_v4().to_string();
        let mut builder = CommandBuilder::new(&command[0]);
        builder.args(&command[1..]);
        builder.cwd(&cwd);
        builder.env("TERM", "xterm-256color");
        builder.env("COLORTERM", "truecolor");
        builder.env("TERM_PROGRAM", "Cherry");
        builder.env("CHERRY_SESSION_ID", &id);
        for (key, value) in env {
            builder.env(key, value);
        }
        let child = pair
            .slave
            .spawn_command(builder)
            .context("launching PTY child")?;
        drop(pair.slave);
        let info = Arc::new(Mutex::new(SessionInfo {
            id,
            name,
            cwd: cwd.to_string_lossy().into(),
            command,
            cols,
            rows,
            state: SessionState::Running,
            pid: child.process_id(),
            exit_code: None,
            attached: false,
        }));
        let (wake, reader) = UnixStream::pair()?;
        wake.set_nonblocking(true)?;
        reader.set_nonblocking(true)?;
        let (tx, rx) = mpsc::sync_channel(64);
        let kill_requested = Arc::new(AtomicBool::new(false));
        let session = Arc::new(Self {
            info: info.clone(),
            tx,
            wake: Mutex::new(wake),
            kill_requested: kill_requested.clone(),
        });
        thread::Builder::new()
            .name("cherry-session".into())
            .spawn(move || {
                Worker {
                    info,
                    master: pair.master,
                    child,
                    terminal,
                    rx,
                    wake: reader,
                    attached: Vec::new(),
                    offset: 0,
                    pending_input: PendingInput::default(),
                    display: DisplayStream::default(),
                    exit: None,
                    kill_requested,
                }
                .run();
            })?;
        Ok(session)
    }

    pub fn send(&self, command: Command) -> Result<()> {
        self.tx
            .try_send(command)
            .map_err(|_| anyhow::anyhow!("session is unavailable or its input queue is full"))?;
        self.wake();
        Ok(())
    }

    pub fn wake(&self) {
        let _ = self.wake.lock().unwrap().write(&[1]);
    }
    pub fn kill(&self) {
        self.kill_requested.store(true, Ordering::SeqCst);
        self.wake();
    }

    pub fn snapshot_info(&self) -> SessionInfo {
        self.info.lock().unwrap().clone()
    }
}

fn size(cols: u16, rows: u16) -> PtySize {
    PtySize {
        cols,
        rows,
        pixel_width: 0,
        pixel_height: 0,
    }
}

struct Worker {
    info: Arc<Mutex<SessionInfo>>,
    master: Box<dyn MasterPty + Send>,
    child: Box<dyn Child + Send + Sync>,
    terminal: Terminal,
    rx: Receiver<Command>,
    wake: UnixStream,
    attached: Vec<Attachment>,
    offset: u64,
    pending_input: PendingInput,
    display: DisplayStream,
    exit: Option<u32>,
    kill_requested: Arc<AtomicBool>,
}

impl Worker {
    fn release_cancelled(&mut self) {
        // The connection writer owns final replies and socket shutdown. Normal
        // detach must not race its acknowledgement off the wire.
        self.attached.retain(|attachment| {
            if attachment.cancelled.load(Ordering::SeqCst) {
                self.pending_input.discard_lease(attachment.lease);
                false
            } else {
                true
            }
        });
        self.info.lock().unwrap().attached = !self.attached.is_empty();
    }

    fn disconnect(&mut self, lease: u64) {
        self.attached.retain(|attachment| {
            if attachment.lease == lease {
                attachment.cancelled.store(true, Ordering::SeqCst);
                let _ = attachment.abort.shutdown(std::net::Shutdown::Both);
                self.pending_input.discard_lease(lease);
                false
            } else {
                true
            }
        });
        self.info.lock().unwrap().attached = !self.attached.is_empty();
    }

    fn emit(&mut self, message: ServerMessage) {
        self.attached.retain(|attachment| {
            if attachment.output.try_send(message.clone()).is_err() {
                attachment.cancelled.store(true, Ordering::SeqCst);
                let _ = attachment.abort.shutdown(std::net::Shutdown::Both);
                self.pending_input.discard_lease(attachment.lease);
                false
            } else {
                true
            }
        });
        self.info.lock().unwrap().attached = !self.attached.is_empty();
    }

    fn emit_to(&mut self, lease: u64, message: ServerMessage) {
        if self
            .attached
            .iter()
            .find(|a| a.lease == lease)
            .is_some_and(|a| a.output.try_send(message).is_err())
        {
            self.disconnect(lease);
        }
    }

    fn queue_input(&mut self, lease: Option<u64>, bytes: &[u8]) {
        if self.pending_input.len + bytes.len() > 1024 * 1024 {
            if let Some(lease) = lease {
                self.disconnect(lease);
            }
            return;
        }
        self.pending_input.push(lease, bytes);
    }

    fn snapshot(&self) -> Result<ServerMessage> {
        Ok(ServerMessage::Attached {
            session: self.info.lock().unwrap().clone(),
            offset: self.offset,
            snapshot: DisplayStream::default()
                .feed(&self.terminal.snapshot()?)
                .display,
        })
    }

    fn synchronize_size(&mut self) {
        let Some((cols, rows)) = self
            .attached
            .iter()
            .map(|a| (a.cols, a.rows))
            .reduce(|(cols, rows), (c, r)| (cols.min(c), rows.min(r)))
        else {
            return;
        };
        let info = self.info.lock().unwrap().clone();
        if (info.cols, info.rows) == (cols, rows) {
            return;
        }
        match self.resize(cols, rows).and_then(|_| self.snapshot()) {
            Ok(message) => self.emit(message),
            Err(error) => self.emit(ServerMessage::error("resize_failed", error.to_string())),
        }
    }

    fn resize(&mut self, cols: u16, rows: u16) -> Result<()> {
        if !valid_size(cols, rows) {
            bail!("invalid terminal size");
        }
        let old = self.info.lock().unwrap().clone();
        if old.cols == cols && old.rows == rows {
            return Ok(());
        }
        let replies = self.terminal.resize(cols, rows)?;
        self.master.resize(size(cols, rows))?;
        self.queue_input(None, &replies);
        let mut info = self.info.lock().unwrap();
        info.cols = cols;
        info.rows = rows;
        Ok(())
    }

    fn handle(&mut self, command: Command) {
        match command {
            Command::Attach {
                lease,
                cols,
                rows,
                takeover,
                output,
                abort,
                cancelled,
            } => {
                if cancelled.load(Ordering::SeqCst) {
                    return;
                }
                self.release_cancelled();
                let dimensions = if takeover {
                    (cols, rows)
                } else {
                    self.attached
                        .iter()
                        .fold((cols, rows), |(c, r), a| (c.min(a.cols), r.min(a.rows)))
                };
                let old = self.info.lock().unwrap().clone();
                if let Err(error) = self.resize(dimensions.0, dimensions.1) {
                    let _ =
                        output.try_send(ServerMessage::error("resize_failed", error.to_string()));
                    return;
                }
                // Snapshot failure must not revoke the previous controllers.
                let snapshot = match self.terminal.snapshot() {
                    Ok(bytes) => DisplayStream::default().feed(&bytes).display,
                    Err(error) => {
                        let _ = output
                            .try_send(ServerMessage::error("snapshot_failed", error.to_string()));
                        return;
                    }
                };
                if cancelled.load(Ordering::SeqCst) {
                    return;
                }
                if takeover {
                    for previous in self.attached.drain(..) {
                        self.pending_input.discard_lease(previous.lease);
                        previous.cancelled.store(true, Ordering::SeqCst);
                        // Deliver a bounded diagnostic, then the old writer
                        // closes. A slow peer never stalls the new attachment.
                        if previous.output.try_send(ServerMessage::error(
                            "taken_over",
                            "session was taken over by another attachment; its programs are still running",
                        )).is_ok() {
                            let _ = previous.abort.shutdown(std::net::Shutdown::Read);
                        } else {
                            let _ = previous.abort.shutdown(std::net::Shutdown::Both);
                        }
                    }
                }
                self.attached.push(Attachment {
                    lease,
                    cols,
                    rows,
                    output,
                    abort,
                    cancelled,
                });
                self.info.lock().unwrap().attached = true;
                let session = self.info.lock().unwrap().clone();
                let message = ServerMessage::Attached {
                    session,
                    offset: self.offset,
                    snapshot,
                };
                if (old.cols, old.rows) != dimensions {
                    self.emit(message);
                } else {
                    self.emit_to(lease, message);
                }
            }
            Command::Input { lease, data }
                if self
                    .attached
                    .iter()
                    .any(|a| a.lease == lease && !a.cancelled.load(Ordering::SeqCst)) =>
            {
                if data.len() <= MAX_INPUT_BYTES && self.exit.is_none() {
                    self.queue_input(Some(lease), &data);
                } else {
                    self.disconnect(lease);
                }
            }
            Command::Resize { lease, cols, rows } => {
                if !valid_size(cols, rows) {
                    self.emit_to(
                        lease,
                        ServerMessage::error("resize_failed", "invalid terminal size"),
                    );
                    return;
                }
                if let Some(attachment) = self
                    .attached
                    .iter_mut()
                    .find(|a| a.lease == lease && !a.cancelled.load(Ordering::SeqCst))
                {
                    attachment.cols = cols;
                    attachment.rows = rows;
                }
            }
            _ => {}
        }
    }

    fn terminate(&mut self) {
        // Reaping happens only after terminal jobs have been cleaned up, so the
        // owned leader's PID remains reserved throughout this operation.
        if self.exit.is_some() {
            return;
        }
        if let Some(pid) = self.child.process_id() {
            crate::processes::terminate_session(pid as i32);
        }
    }

    fn mark_exited(&mut self, code: u32) {
        if self.exit.is_some() {
            return;
        }
        self.exit = Some(code);
        let id = {
            let mut info = self.info.lock().unwrap();
            info.state = SessionState::Exited;
            info.exit_code = Some(code);
            info.id.clone()
        };
        self.emit(ServerMessage::Exit {
            id,
            exit_code: code,
        });
    }

    fn read_output(&mut self) -> bool {
        let fd = self.master.as_raw_fd().unwrap();
        let mut buf = [0u8; 16384];
        // Bounded work per wake gives input/terminate a turn under output floods.
        for _ in 0..16 {
            let n = unsafe { libc::read(fd, buf.as_mut_ptr().cast(), buf.len()) };
            if n <= 0 {
                if n == 0 {
                    return false;
                }
                let e = std::io::Error::last_os_error();
                return e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::Interrupted;
            }
            let batch = self.display.feed(&buf[..n as usize]);
            let replies = self.terminal.feed(&batch.terminal);
            self.queue_input(None, &replies);
            let data = batch.display;
            if !data.is_empty() {
                let offset = self.offset;
                self.offset += data.len() as u64;
                self.emit(ServerMessage::Output { offset, data });
            }
        }
        true
    }

    fn run(mut self) {
        let mut eof = false;
        loop {
            if self.kill_requested.swap(false, Ordering::SeqCst) {
                self.terminate();
            }
            self.release_cancelled();
            for _ in 0..64 {
                match self.rx.try_recv() {
                    Ok(command) => self.handle(command),
                    Err(_) => break,
                }
            }
            self.release_cancelled();
            self.synchronize_size();
            if !eof {
                eof = !self.read_output();
            }
            if self.exit.is_none()
                && self
                    .child
                    .process_id()
                    .is_some_and(|pid| crate::processes::exit_pending(pid as i32))
            {
                self.terminate();
                if let Ok(Some(status)) = self.child.try_wait() {
                    // Drain bytes written before exit before announcing completion.
                    self.read_output();
                    self.mark_exited(status.exit_code());
                }
            }
            // Retain terminal state for inspection/re-attachment of exited sessions,
            // without retaining the PTY or running a polling loop.
            if self.exit.is_some() {
                self.pending_input.clear();
                self.serve_exited();
                return;
            }
            let fd = if eof {
                -1
            } else {
                self.master.as_raw_fd().unwrap()
            };
            if eof {
                self.pending_input.clear();
            }
            self.pending_input.write_to(fd);
            let mut poll = [
                libc::pollfd {
                    fd,
                    events: libc::POLLIN
                        | if self.pending_input.len == 0 {
                            0
                        } else {
                            libc::POLLOUT
                        },
                    revents: 0,
                },
                libc::pollfd {
                    fd: self.wake.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                },
            ];
            unsafe {
                libc::poll(poll.as_mut_ptr(), 2, 100);
            }
            let mut buf = [0; 128];
            while self.wake.read(&mut buf).is_ok_and(|n| n > 0) {}
        }
    }

    fn serve_exited(self) {
        let Self {
            info,
            terminal,
            rx,
            offset,
            exit,
            master,
            attached,
            ..
        } = self;
        // Don't shut down the connection before its queued Exit/output is written.
        // Dropping this duplicate socket leaves the connection writer in charge.
        drop(attached);
        drop(master);
        info.lock().unwrap().attached = false;
        while let Ok(command) = rx.recv() {
            if let Command::Attach { output, .. } = command {
                match terminal
                    .snapshot()
                    .map(|bytes| DisplayStream::default().feed(&bytes).display)
                {
                    Ok(snapshot) => {
                        let session = info.lock().unwrap().clone();
                        let id = session.id.clone();
                        let _ = output.try_send(ServerMessage::Attached {
                            session,
                            offset,
                            snapshot,
                        });
                        let _ = output.try_send(ServerMessage::Exit {
                            id,
                            exit_code: exit.unwrap_or(1),
                        });
                    }
                    Err(e) => {
                        let _ =
                            output.try_send(ServerMessage::error("snapshot_failed", e.to_string()));
                    }
                }
            }
        }
    }
}
