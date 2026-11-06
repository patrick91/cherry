//! `cherry control`: Cherry's control connection to a host. The CLI connects
//! as every command does (socket checks, ssh and the gateway, agent lending,
//! replacing an older host) and says Hello itself. Standard output then
//! carries the host's Welcome followed by every byte the host sends, and
//! standard input every byte for the host, relayed verbatim both ways: the
//! app speaks the protocol, starting with its first request after Hello.
//! With `--allow-requests` (a phone, through `mobile-gateway`) only requests
//! with those `op`s go on, whole frames; any other is answered
//! `not_allowed` here.
use crate::{
    sys::{self, interrupted, poll, pollfd, read_some, write_some, NonBlocking},
    timing::timing,
    transport::{stopped_reading, Transport, RPC_TIMEOUT},
};
use anyhow::{bail, Context, Result};
use cherry_protocol::{
    encode_frame, error_code, frame_length, Response, ServerMessage, PROTOCOL_VERSION,
};
use std::{
    os::fd::RawFd,
    time::{Duration, Instant},
};

/// Bytes read from one side and not yet written to the other, at most per
/// direction; beyond it that side is not read until the other catches up.
const HIGH_WATER: usize = 1024 * 1024;
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
/// be relayed any more. `allowed`: the only requests to send on (see the
/// module documentation).
pub fn relay(
    transport: &mut Transport,
    host_id: String,
    build: Option<String>,
    allowed: Option<Vec<String>>,
) -> Result<u32> {
    let mut filter = allowed.map(RequestFilter::new);
    let welcome = encode_frame(&ServerMessage::Welcome {
        version: PROTOCOL_VERSION,
        host_id,
        build,
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
            // A signal ends the wait, so it lasts until the next deadline.
            pollfd(sys::signal_wake_fd(), libc::POLLIN),
        ];
        let wait = if read_input && input_never_waits {
            Duration::ZERO
        } else {
            [transport.closed_deadline(), quiet_until]
                .into_iter()
                .flatten()
                .min()
                .map_or(Duration::MAX, |deadline| {
                    deadline.saturating_duration_since(now)
                })
        };
        poll(&mut fds, wait)?;
        if fds[4].revents != 0 {
            sys::clear_signal_wake();
        }
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
                Ok(Some(n)) => match filter.as_mut() {
                    None => transport.queue_bytes(&buffer[..n]),
                    Some(filter) => {
                        for frame in filter.push(&buffer[..n])? {
                            match frame {
                                Filtered::Send(bytes) => transport.queue_bytes(&bytes),
                                Filtered::Refuse(answer) => output.push(&answer),
                            }
                        }
                    }
                },
                Err(error) => return Err(error).context("could not read standard input"),
            }
        }
    }
}

/// Standard output, non-blocking while relaying so that neither direction
/// waits for the other, restored on drop.
struct Output {
    output: NonBlocking,
    never_waits: bool,
    bytes: Vec<u8>,
    written: usize,
}

impl Output {
    fn new(fd: RawFd) -> Result<Self> {
        Ok(Self {
            output: NonBlocking::set(fd, "standard output")?,
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
            self.output.fd()
        } else {
            -1
        }
    }

    /// Write what the output accepts now. False once the reader closed it.
    fn flush(&mut self) -> Result<bool> {
        while self.pending() > 0 {
            match write_some(self.output.fd(), &self.bytes[self.written..]) {
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
            self.output.fd(),
            &self.bytes[self.written..],
            timing().closed_wait,
            true,
        );
        self.bytes.clear();
        self.written = 0;
    }
}

/// What becomes of a whole frame from standard input under
/// `--allow-requests`.
#[derive(Debug, PartialEq, Eq)]
enum Filtered {
    /// The frame as it came, for the host.
    Send(Vec<u8>),
    /// The `not_allowed` answer, for standard output.
    Refuse(Vec<u8>),
}

/// Splits standard input into frames and lets through only JSON requests
/// whose `op` is allowed.
struct RequestFilter {
    allowed: Vec<String>,
    pending: Vec<u8>,
}

impl RequestFilter {
    fn new(allowed: Vec<String>) -> Self {
        Self {
            allowed,
            pending: Vec::new(),
        }
    }

    /// The frames `bytes` completed; an error for bytes that are no frame.
    fn push(&mut self, bytes: &[u8]) -> Result<Vec<Filtered>> {
        self.pending.extend_from_slice(bytes);
        let mut frames = Vec::new();
        let mut start = 0;
        while self.pending.len() - start >= 4 {
            let word: [u8; 4] = self.pending[start..start + 4].try_into().unwrap();
            let Ok(length) = frame_length(word) else {
                bail!("standard input sent something that is not a frame");
            };
            let end = start + 4 + length;
            if self.pending.len() < end {
                break;
            }
            frames.push(self.judge(&self.pending[start..end])?);
            start = end;
        }
        self.pending.drain(..start);
        Ok(frames)
    }

    fn judge(&self, frame: &[u8]) -> Result<Filtered> {
        let body = &frame[4..];
        // A binary frame (an attachment's input) has no `op`.
        let request = (body.first() == Some(&b'{'))
            .then(|| serde_json::from_slice::<serde_json::Value>(body).ok())
            .flatten();
        let op = request.as_ref().and_then(|value| value["op"].as_str());
        if op.is_some_and(|op| self.allowed.iter().any(|allowed| allowed == op)) {
            return Ok(Filtered::Send(frame.to_vec()));
        }
        let req = request.as_ref().and_then(|value| value["req"].as_u64());
        let message = match op {
            Some(op) => format!("this connection may not send {op}"),
            None => "this connection sends only requests".to_owned(),
        };
        let answer = encode_frame(&Response::new(
            req,
            ServerMessage::error(error_code::NOT_ALLOWED, message),
        ))
        .context("could not encode a refusal")?;
        Ok(Filtered::Refuse(answer))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cherry_protocol::{read_frame, ClientMessage, Request};

    fn frame(request: &Request) -> Vec<u8> {
        encode_frame(request).unwrap()
    }

    #[test]
    fn only_allowed_requests_go_on_and_the_rest_are_answered_not_allowed() {
        let mut filter = RequestFilter::new(vec!["list".into(), "ping".into()]);
        let list = frame(&Request::new(Some(1), ClientMessage::List));
        let kill = frame(&Request::new(
            Some(2),
            ClientMessage::Kill { id: "s".into() },
        ));
        let ping = frame(&Request::new(None, ClientMessage::Ping));
        let mut bytes = [list.clone(), kill, ping.clone()].concat();
        // Split mid-frame: the filter waits for the rest.
        let rest = bytes.split_off(list.len() + 3);
        let first = filter.push(&bytes).unwrap();
        assert_eq!(first, vec![Filtered::Send(list)]);
        let second = filter.push(&rest).unwrap();
        assert_eq!(second.len(), 2);
        let Filtered::Refuse(answer) = &second[0] else {
            panic!("expected the kill refused, got {:?}", second[0]);
        };
        let answer: Response = read_frame(&mut &answer[..]).unwrap().unwrap();
        assert_eq!(answer.req, Some(2));
        assert!(matches!(
            answer.message,
            ServerMessage::Error { ref code, .. } if code == error_code::NOT_ALLOWED
        ));
        assert_eq!(second[1], Filtered::Send(ping));
    }

    #[test]
    fn binary_frames_and_bytes_that_are_no_frame_go_nowhere() {
        let mut filter = RequestFilter::new(vec!["input".into()]);
        let input = cherry_protocol::encode_input_frame(b"ls\r").unwrap();
        let answers = filter.push(&input).unwrap();
        assert!(matches!(answers[..], [Filtered::Refuse(_)]));
        assert!(filter.push(&[0, 0, 0, 0]).is_err());
    }
}
