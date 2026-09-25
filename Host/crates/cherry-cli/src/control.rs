//! `cherry control`: Cherry's control connection to a host. The CLI connects
//! as every command does (socket checks, ssh and the gateway, agent lending,
//! replacing an older host) and says Hello itself. Standard output then
//! carries the host's Welcome followed by every byte the host sends, and
//! standard input every byte for the host, relayed verbatim both ways: the
//! app speaks the protocol, starting with its first request after Hello.
use crate::{
    sys::{self, interrupted, poll, pollfd, read_some, set_nonblocking, write_some},
    timing::timing,
    transport::{stopped_reading, Transport, RPC_TIMEOUT},
};
use anyhow::{Context, Result};
use cherry_protocol::{encode_frame, ServerMessage, PROTOCOL_VERSION};
use std::{
    io,
    os::fd::RawFd,
    time::{Duration, Instant},
};

/// Bytes read from one side and not yet written to the other, at most per
/// direction; beyond it that side is not read until the other catches up.
const HIGH_WATER: usize = 1024 * 1024;
/// Upper bound on one poll, which also bounds how late a signal that arrives
/// just before poll() is noticed.
const MAX_WAIT: Duration = Duration::from_millis(250);
/// Once standard input ended: how long the host may take to answer what it
/// read and close, counted from when bytes last moved either way.
pub const QUIET_WAIT: Duration = RPC_TIMEOUT;

/// Relay until either side closes. Standard input closing is the app's way
/// to end the connection: what it wrote before is still sent, the host's
/// answers are still relayed until the host closes (or nothing moves for
/// `QUIET_WAIT`), and the command succeeds. The host closing its end first
/// is an error: its end of file, or writes to it failing (then what it sent
/// before has `CLOSED_WAIT` to arrive). A host that is connected but reads
/// nothing only stops the relay from reading standard input once
/// `HIGH_WATER` bytes wait for it; the app's own request timeouts judge it.
/// A closed standard output ends the relay too, successfully: nothing can
/// be relayed any more.
pub fn relay(transport: &mut Transport, host_id: String) -> Result<u32> {
    let welcome = encode_frame(&ServerMessage::Welcome {
        version: PROTOCOL_VERSION,
        host_id,
    })
    .context("could not encode the host's welcome")?;
    let mut output = Output::new(libc::STDOUT_FILENO)?;
    output.push(&welcome);
    // Frames that arrived with the Welcome.
    output.push(&transport.take_buffered());
    let input_never_waits = sys::never_waits(libc::STDIN_FILENO);
    let mut input_open = true;
    let mut host_open = true;
    // Once the input closed: when bytes last moved.
    let mut closing: Option<Instant> = None;
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        interrupted()?;
        if !output.flush()? {
            return Ok(0);
        }
        transport.write_ready()?;
        if !input_open && transport.pending() == 0 && !transport.finished_sending() {
            transport.close_write();
        }
        let now = Instant::now();
        let host_gone = !host_open || transport.closed_deadline().is_some_and(|at| now >= at);
        let quiet_until = closing.map(|since| {
            since.max(transport.progress()).max(transport.received()) + timing().quiet_wait
        });
        let quiet = quiet_until.is_some_and(|at| now >= at);
        if host_gone || quiet {
            // What the host sent before it closed reaches the app first.
            output.finish();
            return if input_open {
                Err(transport.closed_error())
            } else {
                Ok(0)
            };
        }
        let read_input = input_open && transport.pending() < HIGH_WATER;
        let mut fds = [
            pollfd(
                if output.pending() < HIGH_WATER {
                    transport.read_fd()
                } else {
                    -1
                },
                libc::POLLIN,
            ),
            pollfd(
                if transport.pending() > 0 {
                    transport.write_fd()
                } else {
                    -1
                },
                libc::POLLOUT,
            ),
            pollfd(
                if read_input && !input_never_waits {
                    libc::STDIN_FILENO
                } else {
                    -1
                },
                libc::POLLIN,
            ),
            pollfd(output.poll_fd(), libc::POLLOUT),
        ];
        let wait = if read_input && input_never_waits {
            Duration::ZERO
        } else {
            let mut deadline = now + MAX_WAIT;
            for candidate in [transport.closed_deadline(), quiet_until]
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
        if fds[0].revents != 0 {
            match transport.read_raw(&mut buffer)? {
                None => {}
                Some(0) => host_open = false,
                Some(n) => output.push(&buffer[..n]),
            }
        }
        if read_input && (input_never_waits || fds[2].revents != 0) {
            match read_some(libc::STDIN_FILENO, &mut buffer) {
                Ok(None) => {}
                Ok(Some(0)) => {
                    input_open = false;
                    closing = Some(Instant::now());
                }
                Ok(Some(n)) => transport.queue_bytes(&buffer[..n]),
                Err(error) => return Err(error).context("could not read standard input"),
            }
        }
    }
}

/// Standard output, non-blocking while relaying so that neither direction
/// waits for the other, restored on drop.
struct Output {
    fd: RawFd,
    original_flags: i32,
    never_waits: bool,
    bytes: Vec<u8>,
    written: usize,
}

impl Output {
    fn new(fd: RawFd) -> Result<Self> {
        let original_flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if original_flags < 0 {
            return Err(io::Error::last_os_error()).context("could not read standard output flags");
        }
        set_nonblocking(fd)?;
        Ok(Self {
            fd,
            original_flags,
            never_waits: sys::never_waits(fd),
            bytes: Vec::new(),
            written: 0,
        })
    }

    fn push(&mut self, bytes: &[u8]) {
        if self.pending() == 0 {
            self.bytes.clear();
            self.written = 0;
        }
        self.bytes.extend_from_slice(bytes);
    }

    fn pending(&self) -> usize {
        self.bytes.len() - self.written
    }

    /// What to poll for room, if anything waits.
    fn poll_fd(&self) -> RawFd {
        if self.pending() > 0 && !self.never_waits {
            self.fd
        } else {
            -1
        }
    }

    /// Write what the output accepts now. False once the reader closed it.
    fn flush(&mut self) -> Result<bool> {
        while self.pending() > 0 {
            match write_some(self.fd, &self.bytes[self.written..]) {
                Ok(Some(n)) => self.written += n,
                Ok(None) => break,
                Err(error) if stopped_reading(&error) => return Ok(false),
                Err(error) => return Err(error).context("could not write to standard output"),
            }
        }
        if self.pending() == 0 {
            self.bytes.clear();
            self.written = 0;
        } else if self.written >= HIGH_WATER {
            self.bytes.drain(..self.written);
            self.written = 0;
        }
        Ok(true)
    }

    /// Write what is left, giving up when the output accepts nothing for
    /// `CLOSED_WAIT` or is closed.
    fn finish(&mut self) {
        let _ = sys::write_all(
            self.fd,
            &self.bytes[self.written..],
            timing().closed_wait,
            true,
        );
        self.bytes.clear();
        self.written = 0;
    }
}

impl Drop for Output {
    fn drop(&mut self) {
        unsafe {
            libc::fcntl(self.fd, libc::F_SETFL, self.original_flags);
        }
    }
}
