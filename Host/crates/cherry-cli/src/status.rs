//! `attach --status-file`: why the attachment ended, written atomically on
//! every exit path so a supervising app can tell a session exit from a detach
//! or a lost connection.
use serde::Serialize;
use std::{
    io::Write,
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Status {
    pub outcome: Outcome,
    pub exit_code: Option<u32>,
    pub signal: Option<i32>,
    pub message: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    /// This client detached; the session keeps running.
    Detached,
    /// The hosted program ended.
    Exited,
    /// The connection to the host was lost; the session may still run.
    Disconnected,
    /// Another client attached with --takeover.
    TakenOver,
    /// Could not attach.
    Failed,
}

impl Status {
    pub fn new(outcome: Outcome, message: Option<String>) -> Self {
        Self {
            outcome,
            exit_code: None,
            signal: None,
            message,
        }
    }

    pub fn exited(exit_code: u32, signal: Option<i32>) -> Self {
        Self {
            outcome: Outcome::Exited,
            exit_code: Some(exit_code),
            signal,
            message: None,
        }
    }
}

pub struct StatusFile {
    path: Option<PathBuf>,
    /// Set once the host confirmed the attachment; later errors are
    /// disconnections rather than failures to attach.
    pub attached: bool,
    status: Option<Status>,
    written: bool,
}

impl StatusFile {
    pub fn new(path: Option<PathBuf>) -> Self {
        Self {
            path,
            attached: false,
            status: None,
            written: false,
        }
    }

    /// Record the outcome; `finish` writes it.
    pub fn set(&mut self, status: Status) {
        self.status = Some(status);
    }

    /// Write the recorded outcome, or one derived from `error`. Only the first
    /// call writes.
    pub fn finish(&mut self, error: Option<&str>) {
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
        file.sync_all()?;
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
        assert!(json(&Status::new(Outcome::Disconnected, None)).contains(r#""disconnected""#));
        assert!(json(&Status::new(Outcome::Failed, None)).contains(r#""failed""#));
    }

    #[test]
    fn status_is_replaced_atomically_and_only_the_first_outcome_is_written() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("status.json");
        std::fs::write(&path, b"old").unwrap();
        let mut file = StatusFile::new(Some(path.clone()));
        file.attached = true;
        file.finish(Some("connection lost"));
        file.set(Status::new(Outcome::Detached, None));
        file.finish(None);
        let value: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(value["outcome"], "disconnected");
        assert_eq!(value["message"], "connection lost");
        let names: Vec<_> = std::fs::read_dir(directory.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        assert_eq!(names, ["status.json"], "temporary file left behind");
    }
}
