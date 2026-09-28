//! Handing a local daemon of this protocol over to a newer build of its own
//! installation (an update of the same protocol), through `Restart`.
//!
//! Only `list`, `new` and `control` (the Mac app's control helper) do it,
//! never an attachment, and only when every one of these holds:
//!
//! - the daemon says its build, and this cherry's build is newer
//!   (`cherry_protocol::build_is_newer`: only builds given an explicit
//!   `CHERRY_BUILD_ID` order at all, so a development build never takes over
//!   a daemon);
//! - the cherry-host this cherry would start says (`--version`) a build newer
//!   than the daemon's;
//! - that cherry-host is the daemon's own executable (the same file), or the
//!   daemon reports its executable was replaced or removed since it started:
//!   another installation (a development copy, another app) never takes it;
//! - no systemd user service manages the daemon (on Linux), whose unit would
//!   start its own `ExecStart` again;
//! - no handover between the same two builds came back with a replacement
//!   that was not newer in the last `RETRY_AFTER` (`handover.json` in the
//!   state directory): another client's older build won the race to start
//!   the next daemon, and trying again would only take turns with it.
use crate::{diagnose, transport::Transport, transport::RPC_TIMEOUT};
use cherry_protocol::{build_is_newer, ClientMessage, HostStatus, ServerMessage};
use std::{
    fs,
    io::Write,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

/// How long a handover whose replacement was not newer is not tried again.
pub const RETRY_AFTER: Duration = Duration::from_secs(60 * 60);
/// Where the last such handover is recorded, in the state directory.
pub const RECORD: &str = "handover.json";

/// This cherry's build: `cherry_protocol::BUILD`, or `CHERRY_TEST_BUILD`,
/// which tests set to act as another build.
pub fn own_build() -> &'static str {
    static BUILD: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    BUILD.get_or_init(|| {
        std::env::var("CHERRY_TEST_BUILD")
            .ok()
            .filter(|build| !build.is_empty())
            .unwrap_or_else(|| cherry_protocol::BUILD.to_owned())
    })
}

/// A handover from the daemon's build to the one this cherry would start.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Attempt {
    pub from: String,
    pub to: String,
}

/// The cherry-host to hand the daemon at `socket` over to, when it should
/// be (see the module documentation); `transport` has said Hello and is
/// asked the daemon's `Status`.
pub fn candidate(
    transport: &mut Transport,
    socket: &Path,
    daemon_build: Option<&str>,
) -> Option<(PathBuf, Attempt)> {
    let daemon_build = daemon_build?;
    if !build_is_newer(own_build(), daemon_build) || systemd_manages() {
        return None;
    }
    let executable = crate::transport::runnable_host_executable().ok()?;
    let build = diagnose::executable_build(&executable)?;
    if !build_is_newer(&build, daemon_build) {
        return None;
    }
    let attempt = Attempt {
        from: daemon_build.to_owned(),
        to: build,
    };
    let state = cherry_protocol::state_dir(socket).ok()?;
    if recently_failed(&state, &attempt, SystemTime::now()) {
        return None;
    }
    let status = status(transport)?;
    let own_installation = status
        .executable
        .as_deref()
        .is_some_and(|daemon| same_file(Path::new(daemon), &executable));
    (own_installation || status.executable_changed).then_some((executable, attempt))
}

fn status(transport: &mut Transport) -> Option<HostStatus> {
    transport.send(&ClientMessage::Status).ok()?;
    match transport.receive(RPC_TIMEOUT).ok()? {
        ServerMessage::Status { status } => Some(status),
        _ => None,
    }
}

/// Whether two paths name one file (a hard link, or another spelling).
fn same_file(a: &Path, b: &Path) -> bool {
    match (fs::metadata(a), fs::metadata(b)) {
        (Ok(a), Ok(b)) => (a.dev(), a.ino()) == (b.dev(), b.ino()),
        _ => false,
    }
}

/// Whether the systemd user service manages the local daemon (it would
/// start its own `ExecStart` again after a handover).
#[cfg(target_os = "linux")]
fn systemd_manages() -> bool {
    std::process::Command::new("systemctl")
        .args(["--user", "is-enabled", "--quiet", "cherry-host.service"])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

#[cfg(not(target_os = "linux"))]
fn systemd_manages() -> bool {
    false
}

#[derive(serde::Serialize, serde::Deserialize)]
struct Record {
    #[serde(flatten)]
    attempt: Attempt,
    /// Seconds since the Unix epoch.
    at: u64,
}

fn seconds(at: SystemTime) -> u64 {
    at.duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_secs())
}

/// Whether a handover between the same builds came back with a replacement
/// that was not newer within `RETRY_AFTER` of `now` (the record in the
/// daemon's state directory `state`).
pub fn recently_failed(state: &Path, attempt: &Attempt, now: SystemTime) -> bool {
    let Some(record) = fs::read(state.join(RECORD))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Record>(&bytes).ok())
    else {
        return false;
    };
    record.attempt == *attempt && seconds(now).saturating_sub(record.at) < RETRY_AFTER.as_secs()
}

/// After a handover: the daemon that answers now says `now_build`. One that
/// is not newer than the daemon handed over (another client's older build
/// started first) is recorded, so that nobody tries the same handover again
/// for a while.
pub fn note_outcome(socket: &Path, attempt: &Attempt, now_build: Option<&str>) {
    if let Ok(state) = cherry_protocol::state_dir(socket) {
        note_outcome_in(&state, attempt, now_build, SystemTime::now());
    }
}

fn note_outcome_in(state: &Path, attempt: &Attempt, now_build: Option<&str>, now: SystemTime) {
    if now_build.is_some_and(|build| build_is_newer(build, &attempt.from)) {
        return;
    }
    eprintln!(
        "cherry: handed the cherry-host of build {} over to build {}, but build {} answers now; not trying again for an hour",
        attempt.from,
        attempt.to,
        now_build.unwrap_or("(unknown)")
    );
    let path = state.join(RECORD);
    let Ok(bytes) = serde_json::to_vec(&Record {
        attempt: attempt.clone(),
        at: seconds(now),
    }) else {
        return;
    };
    let dir = state;
    let temporary = dir.join(format!(".{RECORD}.{}.tmp", std::process::id()));
    let written = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&temporary)
        .and_then(|mut file| file.write_all(&bytes))
        .and_then(|()| fs::rename(&temporary, &path));
    if written.is_err() {
        let _ = fs::remove_file(&temporary);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_handover_whose_replacement_was_not_newer_waits_an_hour() {
        let state = tempfile::tempdir().unwrap();
        let attempt = Attempt {
            from: "20260101000000.aaaaaaa".into(),
            to: "20260927101500.bbbbbbb".into(),
        };
        let now = SystemTime::now();
        assert!(!recently_failed(state.path(), &attempt, now));
        // The replacement was the new build: nothing is recorded.
        note_outcome_in(state.path(), &attempt, Some("20260927101500.bbbbbbb"), now);
        assert!(!state.path().join(RECORD).exists());
        // The old build (or none that says) won the race: recorded.
        note_outcome_in(state.path(), &attempt, Some("20260101000000.aaaaaaa"), now);
        assert!(recently_failed(state.path(), &attempt, now));
        assert!(recently_failed(
            state.path(),
            &attempt,
            now + RETRY_AFTER - Duration::from_secs(1)
        ));
        assert!(!recently_failed(state.path(), &attempt, now + RETRY_AFTER));
        // Only for that pair of builds.
        let other = Attempt {
            from: attempt.from.clone(),
            to: "20261001000000.ccccccc".into(),
        };
        assert!(!recently_failed(state.path(), &other, now));
        note_outcome_in(state.path(), &other, None, now);
        assert!(recently_failed(state.path(), &other, now));
    }
}
