//! ssh's standard error. It passes through to ours as it arrives, except the
//! lines the remote cherry-host prints about its own failure
//! (`cherry-host: …`). Those are held so the CLI can report them once, in its
//! own error message, or print them when the connection ends.
use crate::sys;
use std::{
    io::{self, Read},
    process::ChildStderr,
    sync::{Arc, Condvar, Mutex},
    thread,
    time::Duration,
};

const REPORT_PREFIX: &[u8] = b"cherry-host: ";
/// A line longer than this is passed through even if it looks like a report.
const MAX_REPORT_LINE: usize = 4096;
/// Only the latest reports are kept.
const MAX_REPORTS: usize = 16;

#[derive(Default)]
struct State {
    reports: Vec<String>,
    /// ssh closed its standard error.
    closed: bool,
}

type Shared = Arc<(Mutex<State>, Condvar)>;

pub struct StderrRelay {
    shared: Shared,
}

impl StderrRelay {
    pub fn start(mut source: ChildStderr) -> io::Result<Self> {
        let shared: Shared = Arc::default();
        let state = shared.clone();
        thread::Builder::new()
            .name("cherry-ssh-stderr".into())
            .spawn(move || {
                let mut filter = ReportFilter::default();
                let mut buffer = [0u8; 4096];
                loop {
                    let n = match source.read(&mut buffer) {
                        Ok(0) => break,
                        Ok(n) => n,
                        Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                        Err(_) => break,
                    };
                    let (passed, reports) = filter.feed(&buffer[..n]);
                    publish(&state, &passed, reports, false);
                }
                let (passed, reports) = filter.finish();
                publish(&state, &passed, reports, true);
            })?;
        Ok(Self { shared })
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
}

fn publish(shared: &Shared, passed: &[u8], reports: Vec<String>, closed: bool) {
    if !passed.is_empty() {
        // Our stderr may share a non-blocking file description with the
        // terminal. Bytes it does not accept within a second are dropped
        // rather than stalling ssh.
        let _ = sys::write_all(libc::STDERR_FILENO, passed, Duration::from_secs(1), false);
    }
    if reports.is_empty() && !closed {
        return;
    }
    let (lock, changed) = &**shared;
    let mut state = lock.lock().unwrap_or_else(|error| error.into_inner());
    state.reports.extend(reports);
    let excess = state.reports.len().saturating_sub(MAX_REPORTS);
    state.reports.drain(..excess);
    state.closed |= closed;
    changed.notify_all();
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
}
