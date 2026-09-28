//! ssh's standard error. It passes through to ours as it arrives, except the
//! lines the remote cherry-host prints about its own failure
//! (`cherry-host: …`). Those are held so the CLI can report them once, in its
//! own error message, or print them when the connection ends.
//!
//! A quiet relay passes nothing through and prints nothing: an attachment's
//! connection once its screen shows the session, and every connection an
//! attachment makes to reconnect, where ssh's complaints would land in the
//! middle of the session's screen. The last lines are kept for messages.
use crate::sys;
use std::{
    collections::VecDeque,
    io::{self, Read},
    process::ChildStderr,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Condvar, Mutex,
    },
    thread,
    time::Duration,
};

const REPORT_PREFIX: &[u8] = b"cherry-host: ";
/// A line longer than this is passed through even if it looks like a report.
const MAX_REPORT_LINE: usize = 4096;
/// Only the latest reports are kept.
const MAX_REPORTS: usize = 16;
/// While quiet, the latest lines kept, each at most `MAX_REPORT_LINE` bytes.
const MAX_HELD: usize = 4;
/// What ssh says when the master connection it was told to use (a
/// ControlPath) refused a new session: the server's `MaxSessions` (10 by
/// default) is reached on that connection. ssh then gives up rather than
/// connecting directly.
pub const MUX_SESSION_REFUSED: &str = "Session open refused by peer";

#[derive(Default)]
struct State {
    reports: Vec<String>,
    /// Lines that a quiet relay did not pass through, the latest last.
    held: VecDeque<String>,
    /// ssh closed its standard error.
    closed: bool,
    /// ssh said its master connection refused the session
    /// (`MUX_SESSION_REFUSED`).
    mux_refused: bool,
}

type Shared = Arc<(Mutex<State>, Condvar)>;

pub struct StderrRelay {
    shared: Shared,
    quiet: Arc<AtomicBool>,
}

impl StderrRelay {
    pub fn start(mut source: ChildStderr, quiet: bool) -> io::Result<Self> {
        let shared: Shared = Arc::default();
        let quiet = Arc::new(AtomicBool::new(quiet));
        let state = shared.clone();
        let silenced = quiet.clone();
        thread::Builder::new()
            .name("cherry-ssh-stderr".into())
            .spawn(move || {
                let mut filter = ReportFilter::default();
                let mut line = Vec::new();
                let mut refusal = RefusalWatch::default();
                let mut buffer = [0u8; 4096];
                loop {
                    let n = match source.read(&mut buffer) {
                        Ok(0) => break,
                        Ok(n) => n,
                        Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                        Err(_) => break,
                    };
                    if refusal.feed(&buffer[..n]) {
                        note_mux_refusal(&state);
                    }
                    let (passed, reports) = filter.feed(&buffer[..n]);
                    let quiet = silenced.load(Ordering::Relaxed);
                    publish(&state, &passed, reports, quiet, &mut line, false);
                }
                let (passed, reports) = filter.finish();
                let quiet = silenced.load(Ordering::Relaxed);
                publish(&state, &passed, reports, quiet, &mut line, true);
            })?;
        Ok(Self { shared, quiet })
    }

    /// Pass nothing through from now on, and print nothing when the
    /// connection ends.
    pub fn silence(&self) {
        self.quiet.store(true, Ordering::Relaxed);
    }

    pub fn is_quiet(&self) -> bool {
        self.quiet.load(Ordering::Relaxed)
    }

    /// Take the reports held so far, first waiting up to `timeout` until
    /// there is one or ssh closed its standard error.
    pub fn take_reports(&self, timeout: Duration) -> Vec<String> {
        let (lock, changed) = &*self.shared;
        let state = lock.lock().unwrap_or_else(|error| error.into_inner());
        let (mut state, _) = changed
            .wait_timeout_while(state, timeout, |state| {
                state.reports.is_empty() && !state.closed
            })
            .unwrap_or_else(|error| error.into_inner());
        std::mem::take(&mut state.reports)
    }

    /// Whether ssh said its master connection refused the session
    /// (`MUX_SESSION_REFUSED`), first waiting up to `timeout` until it said
    /// so or closed its standard error.
    pub fn mux_refused(&self, timeout: Duration) -> bool {
        let (lock, changed) = &*self.shared;
        let state = lock.lock().unwrap_or_else(|error| error.into_inner());
        let (state, _) = changed
            .wait_timeout_while(state, timeout, |state| !state.mux_refused && !state.closed)
            .unwrap_or_else(|error| error.into_inner());
        state.mux_refused
    }

    /// The last line a quiet relay held, or else the last report, first
    /// waiting up to `timeout` until ssh closed its standard error: ssh may
    /// explain why it ended just after its output ended.
    pub fn last_line(&self, timeout: Duration) -> Option<String> {
        let (lock, changed) = &*self.shared;
        let state = lock.lock().unwrap_or_else(|error| error.into_inner());
        let (state, _) = changed
            .wait_timeout_while(state, timeout, |state| !state.closed)
            .unwrap_or_else(|error| error.into_inner());
        state.held.back().or(state.reports.last()).cloned()
    }
}

fn note_mux_refusal(shared: &Shared) {
    let (lock, changed) = &**shared;
    let mut state = lock.lock().unwrap_or_else(|error| error.into_inner());
    state.mux_refused = true;
    changed.notify_all();
}

/// Looks for `MUX_SESSION_REFUSED` in ssh's standard error, line by line.
#[derive(Default)]
struct RefusalWatch {
    line: Vec<u8>,
}

impl RefusalWatch {
    /// True when `bytes` complete (or hold) a line saying it.
    fn feed(&mut self, bytes: &[u8]) -> bool {
        let mut found = false;
        for &byte in bytes {
            if byte == b'\n' {
                self.line.clear();
                continue;
            }
            if self.line.len() < MAX_REPORT_LINE {
                self.line.push(byte);
            }
            if byte == b'r' && self.line.ends_with(MUX_SESSION_REFUSED.as_bytes()) {
                found = true;
            }
        }
        found
    }
}

/// Pass `passed` through, or hold its lines when `quiet`; record `reports`.
/// `line` is the unfinished line held so far.
fn publish(
    shared: &Shared,
    passed: &[u8],
    reports: Vec<String>,
    quiet: bool,
    line: &mut Vec<u8>,
    closed: bool,
) {
    let mut held = Vec::new();
    if quiet {
        for &byte in passed {
            if byte == b'\n' {
                held.extend(complete_line(line));
            } else if line.len() < MAX_REPORT_LINE {
                line.push(byte);
            }
        }
        if closed {
            held.extend(complete_line(line));
        }
    } else if !passed.is_empty() {
        // Our stderr may share a non-blocking file description with the
        // terminal. Bytes it does not accept within a second are dropped
        // rather than stalling ssh.
        let _ = sys::write_all(libc::STDERR_FILENO, passed, Duration::from_secs(1), false);
    }
    if reports.is_empty() && held.is_empty() && !closed {
        return;
    }
    let (lock, changed) = &**shared;
    let mut state = lock.lock().unwrap_or_else(|error| error.into_inner());
    state.reports.extend(reports);
    let excess = state.reports.len().saturating_sub(MAX_REPORTS);
    state.reports.drain(..excess);
    state.held.extend(held);
    let excess = state.held.len().saturating_sub(MAX_HELD);
    state.held.drain(..excess);
    state.closed |= closed;
    changed.notify_all();
}

/// The line held so far, trimmed, unless it is blank; the line starts over.
fn complete_line(line: &mut Vec<u8>) -> Option<String> {
    let text = String::from_utf8_lossy(line).trim().to_owned();
    line.clear();
    (!text.is_empty()).then_some(text)
}

/// Splits a byte stream into bytes to pass on and complete report lines.
#[derive(Default)]
struct ReportFilter {
    /// The current line so far, while it may be a report.
    held: Vec<u8>,
    /// Inside a line that is not a report.
    passing: bool,
}

impl ReportFilter {
    fn feed(&mut self, bytes: &[u8]) -> (Vec<u8>, Vec<String>) {
        let mut passed = Vec::with_capacity(bytes.len());
        let mut reports = Vec::new();
        for &byte in bytes {
            if self.passing {
                passed.push(byte);
                self.passing = byte != b'\n';
                continue;
            }
            self.held.push(byte);
            if byte == b'\n' {
                self.end_line(&mut passed, &mut reports);
                continue;
            }
            let matched = self.held.len().min(REPORT_PREFIX.len());
            if self.held[..matched] != REPORT_PREFIX[..matched] || self.held.len() > MAX_REPORT_LINE
            {
                passed.append(&mut self.held);
                self.passing = true;
            }
        }
        (passed, reports)
    }

    /// At end of file: an unterminated line is complete too.
    fn finish(&mut self) -> (Vec<u8>, Vec<String>) {
        let mut passed = Vec::new();
        let mut reports = Vec::new();
        if !self.held.is_empty() {
            self.end_line(&mut passed, &mut reports);
        }
        (passed, reports)
    }

    fn end_line(&mut self, passed: &mut Vec<u8>, reports: &mut Vec<String>) {
        if self.held.starts_with(REPORT_PREFIX) {
            reports.push(String::from_utf8_lossy(&self.held).trim_end().to_owned());
            self.held.clear();
        } else {
            passed.append(&mut self.held);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn filter(chunks: &[&[u8]]) -> (Vec<u8>, Vec<String>) {
        let mut filter = ReportFilter::default();
        let mut passed = Vec::new();
        let mut reports = Vec::new();
        for chunk in chunks {
            let (bytes, lines) = filter.feed(chunk);
            passed.extend(bytes);
            reports.extend(lines);
        }
        let (bytes, lines) = filter.finish();
        passed.extend(bytes);
        reports.extend(lines);
        (passed, reports)
    }

    #[test]
    fn a_master_refusing_the_session_is_noticed_across_reads() {
        let mut watch = RefusalWatch::default();
        assert!(!watch.feed(b"Warning: Permanently added 'studio'\n"));
        assert!(
            !watch.feed(b"mux_client_request_session: session request failed: Session open ref")
        );
        assert!(watch.feed(b"used by peer\r\n"));
        let mut watch = RefusalWatch::default();
        assert!(!watch.feed(b"channel 3: open failed: administratively prohibited\n"));
    }

    #[test]
    fn cherry_host_reports_are_held_and_everything_else_passes_through() {
        let stream = b"Warning: Permanently added 'devbox'.\r\ncherry-host: no cherry-host is running at /tmp/x/host.sock\r\nbash: cherry-hostile\ncherry-host:\n";
        for split in 0..stream.len() {
            let (passed, reports) = filter(&[&stream[..split], &stream[split..]]);
            assert_eq!(
                passed,
                b"Warning: Permanently added 'devbox'.\r\nbash: cherry-hostile\ncherry-host:\n",
                "split at {split}"
            );
            assert_eq!(
                reports,
                ["cherry-host: no cherry-host is running at /tmp/x/host.sock"],
                "split at {split}"
            );
        }
    }

    #[test]
    fn prompts_without_a_newline_are_not_held() {
        let mut filter = ReportFilter::default();
        assert_eq!(filter.feed(b"Password: ").0, b"Password: ");
        assert_eq!(filter.feed(b"x\n").0, b"x\n");
        // A possible report is held only until it cannot be one.
        assert!(filter.feed(b"cherry").0.is_empty());
        assert_eq!(filter.feed(b"!").0, b"cherry!");
    }

    #[test]
    fn an_unterminated_report_at_end_of_file_is_kept_and_long_lines_pass() {
        let (passed, reports) = filter(&[b"cherry-host: exiting"]);
        assert!(passed.is_empty());
        assert_eq!(reports, ["cherry-host: exiting"]);
        let long = [REPORT_PREFIX, &[b'x'; MAX_REPORT_LINE]].concat();
        let (passed, reports) = filter(&[&long, b"\n"]);
        assert_eq!(passed.len(), long.len() + 1);
        assert!(reports.is_empty());
    }

    #[test]
    fn a_quiet_relay_holds_the_latest_lines_instead_of_passing_them() {
        let quiet_relay = |shared| StderrRelay {
            shared,
            quiet: Arc::new(AtomicBool::new(true)),
        };
        let shared: Shared = Arc::default();
        let mut line = Vec::new();
        let chunks: [&[u8]; 3] = [
            b"\r\none\r\ntwo\nthree\n",
            b"ssh: connect to host devbox",
            b" port 22: Network is unreachable\r\n\n",
        ];
        for chunk in chunks {
            publish(&shared, chunk, Vec::new(), true, &mut line, false);
        }
        let relay = quiet_relay(shared);
        // ssh has not closed its standard error yet.
        assert_eq!(
            relay.last_line(Duration::from_millis(10)).as_deref(),
            Some("ssh: connect to host devbox port 22: Network is unreachable")
        );
        publish(
            &relay.shared,
            b"last words",
            Vec::new(),
            true,
            &mut line,
            true,
        );
        assert_eq!(
            Vec::from(relay.shared.0.lock().unwrap().held.clone()),
            [
                "two",
                "three",
                "ssh: connect to host devbox port 22: Network is unreachable",
                "last words"
            ]
        );
        assert_eq!(
            relay.last_line(Duration::ZERO).as_deref(),
            Some("last words")
        );

        // Without a held line, the last report; with neither, nothing.
        let shared: Shared = Arc::default();
        let report = vec!["cherry-host: host exited".to_owned()];
        publish(&shared, b"", report, true, &mut Vec::new(), true);
        assert_eq!(
            quiet_relay(shared).last_line(Duration::ZERO).as_deref(),
            Some("cherry-host: host exited")
        );
        assert_eq!(quiet_relay(Arc::default()).last_line(Duration::ZERO), None);
    }
}
