//! `attach --status-file`: the attachment's live state while it runs, and
//! why it ended, written atomically on every exit path so a supervising app
//! can tell a session exit from a detach or a lost connection.
//!
//! While attached the file holds `{"outcome":"attached","viewport":…,
//! "reconnecting":…,"exit_code":null,"signal":null,"message":null}`, rewritten
//! whenever the viewport or reconnecting state changes, with `pid` and
//! `started` (this process's pid and kernel start time, `start_identity`),
//! so a supervisor can signal this process itself rather than a wrapper
//! that runs it (SIGUSR1: reconnect now) after checking the pid is still
//! this process's. The final outcome
//! replaces it when the command ends; a `disconnected` or `failed` one that
//! connecting again can never resolve says `"reconnectable":false`. A reader
//! never sees a partial file.
use serde::Serialize;
use std::{
    io::Write,
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Status {
    pub outcome: Outcome,
    /// While attached: the window shows a viewport of a shared grid of
    /// another size, rather than the session's stream as it is.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub viewport: Option<bool>,
    /// While attached: the connection to the host was lost and the
    /// attachment is connecting again.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reconnecting: Option<bool>,
    /// While attached: this process's pid.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
    /// While attached: when this process started, as `start_identity`
    /// gives it (macOS: `seconds.microseconds`); left out when unknown.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started: Option<String>,
    pub exit_code: Option<u32>,
    pub signal: Option<i32>,
    pub message: Option<String>,
    /// With a `disconnected` or `failed` outcome: false when connecting
    /// again can never resume the attachment (another host identity
    /// answers, a protocol this cherry cannot use, or the host no longer
    /// has the session), so a supervisor stops retrying. Left out
    /// otherwise.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reconnectable: Option<bool>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    /// Still attached (or connecting again); not a final outcome.
    Attached,
    /// This client detached; the session keeps running.
    Detached,
    /// The hosted program ended.
    Exited,
    /// The connection to the host was lost; the session may still run.
    Disconnected,
    /// Another client attached with --takeover.
    TakenOver,
    /// Another attachment of this client (--client-id) replaced this one.
    Replaced,
    /// Could not attach.
    Failed,
}

impl Status {
    pub fn new(outcome: Outcome, message: Option<String>) -> Self {
        Self {
            outcome,
            viewport: None,
            reconnecting: None,
            pid: None,
            started: None,
            exit_code: None,
            signal: None,
            message,
            reconnectable: None,
        }
    }

    pub fn exited(exit_code: u32, signal: Option<i32>) -> Self {
        Self {
            exit_code: Some(exit_code),
            signal,
            ..Self::new(Outcome::Exited, None)
        }
    }

    /// The live state of a running attachment.
    pub fn attached(live: Live) -> Self {
        Self {
            viewport: Some(live.viewport),
            reconnecting: Some(live.reconnecting),
            pid: Some(std::process::id()),
            started: start_identity(std::process::id() as libc::pid_t),
            ..Self::new(Outcome::Attached, None)
        }
    }
}

/// When the process `pid` started, as the kernel keeps it: on macOS
/// `seconds.microseconds` (`proc_bsdinfo`, the same value `sysctl`'s
/// `kinfo_proc.kp_proc.p_starttime` gives); on Linux the boot id and the
/// start time in clock ticks. None when it cannot be read.
pub fn start_identity(pid: libc::pid_t) -> Option<String> {
    #[cfg(target_os = "macos")]
    unsafe {
        let mut info: libc::proc_bsdinfo = std::mem::zeroed();
        let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
        (libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            (&mut info as *mut libc::proc_bsdinfo).cast(),
            size,
        ) == size)
            .then(|| format!("{}.{:06}", info.pbi_start_tvsec, info.pbi_start_tvusec))
    }
    #[cfg(target_os = "linux")]
    {
        let boot = std::fs::read_to_string("/proc/sys/kernel/random/boot_id").ok()?;
        let stat = std::fs::read(format!("/proc/{pid}/stat")).ok()?;
        let end = stat.iter().rposition(|&b| b == b')')?;
        let fields = std::str::from_utf8(&stat[end + 1..]).ok()?;
        let started = fields.split_ascii_whitespace().nth(22 - 3)?;
        Some(format!("{}/{started}", boot.trim()))
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let _ = pid;
        None
    }
}

/// What the status file says while the attachment runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Live {
    pub viewport: bool,
    pub reconnecting: bool,
}

pub struct StatusFile {
    path: Option<PathBuf>,
    /// Set once the host confirmed the attachment; later errors are
    /// disconnections rather than failures to attach.
    pub attached: bool,
    status: Option<Status>,
    /// The live state last written.
    live: Option<Live>,
    /// The final outcome was written; nothing is written after it.
    written: bool,
}

impl StatusFile {
    pub fn new(path: Option<PathBuf>) -> Self {
        Self {
            path,
            attached: false,
            status: None,
            live: None,
            written: false,
        }
    }

    /// While attached: write the live state when it changed. A failure is
    /// not reported here, in the middle of the session's screen; the final
    /// write reports its own. The live state is not synced to disk, which
    /// would hold up the attachment for nothing: it matters only while this
    /// process runs.
    pub fn live(&mut self, live: Live) {
        self.attached = true;
        if self.written || self.live == Some(live) {
            return;
        }
        self.live = Some(live);
        if let Some(path) = &self.path {
            let _ = write(path, &Status::attached(live), false);
        }
    }

    /// Record the outcome; `finish` writes it.
    pub fn set(&mut self, status: Status) {
        self.status = Some(status);
    }

    /// Write the recorded outcome, or one derived from `error`; `is_final`:
    /// connecting again can never resolve the failure (see
    /// `Status::reconnectable`). Only the first call writes.
    pub fn finish(&mut self, error: Option<&str>, is_final: bool) {
        if self.written {
            return;
        }
        let Some(path) = self.path.clone() else {
            return;
        };
        self.written = true;
        let status = match (self.status.take(), error) {
            (Some(status), _) => status,
            (None, message) => Status::new(
                if self.attached {
                    Outcome::Disconnected
                } else {
                    Outcome::Failed
                },
                Some(message.unwrap_or("the attachment ended").to_owned()),
            ),
        };
        let status = Status {
            reconnectable: (is_final
                && matches!(status.outcome, Outcome::Disconnected | Outcome::Failed))
            .then_some(false),
            ..status
        };
        if let Err(error) = write_atomically(&path, &status) {
            eprintln!(
                "cherry: could not write status file {}: {error}",
                path.display()
            );
        }
    }
}

/// Write beside the target and rename, so a reader never sees a partial file.
pub fn write_atomically(path: &Path, status: &Status) -> std::io::Result<()> {
    write(path, status, true)
}

/// `write_atomically`, synced to disk before the rename when `durable`.
fn write(path: &Path, status: &Status, durable: bool) -> std::io::Result<()> {
    let name = path
        .file_name()
        .ok_or_else(|| std::io::Error::other("status file path has no file name"))?;
    let mut temporary_name = std::ffi::OsString::from(".");
    temporary_name.push(name);
    temporary_name.push(format!(".{}.tmp", std::process::id()));
    let temporary = path.with_file_name(temporary_name);
    let _ = std::fs::remove_file(&temporary);
    let result = (|| {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&temporary)?;
        let mut json = serde_json::to_vec(status)?;
        json.push(b'\n');
        file.write_all(&json)?;
        if durable {
            file.sync_all()?;
        }
        std::fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

/// Best effort for a command line clap rejected: report the usage error
/// through `--status-file` when one can be found.
pub fn report_usage_error(arguments: &[std::ffi::OsString], message: &str) {
    let mut path = None;
    let mut iterator = arguments.iter().skip(1);
    while let Some(argument) = iterator.next() {
        let Some(argument) = argument.to_str() else {
            continue;
        };
        if argument == "--" {
            break;
        }
        if argument == "--status-file" {
            path = iterator.next().map(PathBuf::from);
        } else if let Some(value) = argument.strip_prefix("--status-file=") {
            path = Some(PathBuf::from(value));
        }
    }
    let Some(path) = path else {
        return;
    };
    let _ = write_atomically(
        &path,
        &Status::new(Outcome::Failed, Some(message.trim().to_owned())),
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_json_matches_the_app_contract() {
        let json = |status: &Status| serde_json::to_string(status).unwrap();
        assert_eq!(
            json(&Status::new(Outcome::Detached, None)),
            r#"{"outcome":"detached","exit_code":null,"signal":null,"message":null}"#
        );
        assert_eq!(
            json(&Status::exited(137, Some(9))),
            r#"{"outcome":"exited","exit_code":137,"signal":9,"message":null}"#
        );
        assert_eq!(
            json(&Status::new(Outcome::TakenOver, Some("moved".into()))),
            r#"{"outcome":"taken_over","exit_code":null,"signal":null,"message":"moved"}"#
        );
        assert_eq!(
            json(&Status::new(Outcome::Replaced, Some("again".into()))),
            r#"{"outcome":"replaced","exit_code":null,"signal":null,"message":"again"}"#
        );
        assert!(json(&Status::new(Outcome::Disconnected, None)).contains(r#""disconnected""#));
        assert!(json(&Status::new(Outcome::Failed, None)).contains(r#""failed""#));
        assert_eq!(
            json(&Status::attached(Live {
                viewport: true,
                reconnecting: false
            })),
            format!(
                r#"{{"outcome":"attached","viewport":true,"reconnecting":false,"pid":{},"started":"{}","exit_code":null,"signal":null,"message":null}}"#,
                std::process::id(),
                start_identity(std::process::id() as libc::pid_t).unwrap()
            )
        );
    }

    #[test]
    fn the_start_identity_is_the_kernels_and_tells_processes_apart() {
        let own = start_identity(std::process::id() as libc::pid_t).unwrap();
        assert_eq!(
            start_identity(std::process::id() as libc::pid_t).unwrap(),
            own
        );
        let mut child = std::process::Command::new("/bin/sleep")
            .arg("5")
            .spawn()
            .unwrap();
        let other = start_identity(child.id() as libc::pid_t).unwrap();
        let _ = child.kill();
        let _ = child.wait();
        // Compared as numbers: Linux's clock ticks after the boot id gain
        // digits (9897, then 10544), macOS's seconds and microseconds don't.
        let started =
            |identity: &str| -> f64 { identity.rsplit('/').next().unwrap().parse().unwrap() };
        assert!(started(&other) >= started(&own), "{other} < {own}");
        assert_ne!(other, own);
        assert_eq!(start_identity(i32::MAX), None);
    }

    #[test]
    fn the_live_state_is_rewritten_on_changes_until_the_final_outcome() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("status.json");
        let read = || -> serde_json::Value {
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap()
        };
        let mut file = StatusFile::new(Some(path.clone()));
        let live = |viewport, reconnecting| Live {
            viewport,
            reconnecting,
        };
        file.live(live(false, false));
        assert!(file.attached);
        assert_eq!(read()["outcome"], "attached");
        assert_eq!(read()["reconnecting"], false);
        // Unchanged: not written again.
        std::fs::write(&path, b"{}").unwrap();
        file.live(live(false, false));
        assert_eq!(read(), serde_json::json!({}));
        file.live(live(false, true));
        assert_eq!(read()["reconnecting"], true);
        assert_eq!(read()["viewport"], false);
        file.live(live(true, false));
        assert_eq!(read()["viewport"], true);
        assert_eq!(read()["reconnecting"], false);
        file.finish(Some("connection lost"), false);
        let last = read();
        assert_eq!(last["outcome"], "disconnected");
        assert!(last.get("viewport").is_none() && last.get("reconnecting").is_none());
        // Nothing after the final outcome.
        file.live(live(false, true));
        assert_eq!(read(), last);
        let names: Vec<_> = std::fs::read_dir(directory.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        assert_eq!(names, ["status.json"], "temporary file left behind");

        // Without a path nothing is written, but the attachment is known.
        let mut file = StatusFile::new(None);
        file.live(live(false, false));
        assert!(file.attached);
    }

    #[test]
    fn status_is_replaced_atomically_and_only_the_first_outcome_is_written() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("status.json");
        std::fs::write(&path, b"old").unwrap();
        let mut file = StatusFile::new(Some(path.clone()));
        file.attached = true;
        file.finish(Some("connection lost"), false);
        file.set(Status::new(Outcome::Detached, None));
        file.finish(None, false);
        let value: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(value["outcome"], "disconnected");
        assert_eq!(value["message"], "connection lost");
        assert!(value.get("reconnectable").is_none(), "{value}");
        let names: Vec<_> = std::fs::read_dir(directory.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        assert_eq!(names, ["status.json"], "temporary file left behind");
    }

    #[test]
    fn an_ending_no_reconnection_can_resolve_says_so() {
        let directory = tempfile::tempdir().unwrap();
        let read = |name: &str| -> serde_json::Value {
            serde_json::from_slice(&std::fs::read(directory.path().join(name)).unwrap()).unwrap()
        };
        let mut lost = StatusFile::new(Some(directory.path().join("lost.json")));
        lost.attached = true;
        lost.finish(Some("host identity changed"), true);
        assert_eq!(read("lost.json")["outcome"], "disconnected");
        assert_eq!(read("lost.json")["reconnectable"], false);
        let mut refused = StatusFile::new(Some(directory.path().join("refused.json")));
        refused.finish(Some("the host no longer has session s"), true);
        assert_eq!(read("refused.json")["outcome"], "failed");
        assert_eq!(read("refused.json")["reconnectable"], false);
        // An outcome recorded before (an exit) never says it.
        let mut exited = StatusFile::new(Some(directory.path().join("exited.json")));
        exited.set(Status::exited(0, None));
        exited.finish(None, true);
        assert!(read("exited.json").get("reconnectable").is_none());
    }
}
