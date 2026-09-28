//! Where a host keeps its socket and its durable state.
//!
//! The socket lives in its own private directory (by default under /tmp, so
//! the path stays short enough for sockaddr_un). The host identity, lock,
//! log and session manifests live in a per-user state directory that tmp
//! cleaners never touch:
//! `~/Library/Application Support/cherry-host/<key>` on macOS and
//! `${XDG_STATE_HOME:-~/.local/state}/cherry-host/<key>` elsewhere. The key is
//! `default` for the default socket and a stable hash of any other socket path.
use anyhow::{bail, Context, Result};
use std::{
    ffi::{CString, OsString},
    fs, io,
    os::unix::{
        ffi::OsStrExt,
        fs::{DirBuilderExt, FileTypeExt, MetadataExt, OpenOptionsExt},
    },
    path::{Path, PathBuf},
};

/// sockaddr_un holds 104 bytes on macOS; stay below it everywhere.
const MAX_SOCKET_PATH: usize = 100;

pub fn euid() -> u32 {
    unsafe { libc::geteuid() }
}

/// Create (mode 0700) or verify the directory that holds the socket.
pub fn socket_dir(socket: &Path) -> Result<PathBuf> {
    let dir = socket_parent(socket)?;
    ensure_private_dir(dir, false).map_err(|error| untrusted_socket_dir(dir, error))?;
    Ok(dir.to_path_buf())
}

/// The directory that holds `socket`, after checking that the path is
/// usable at all. Creates nothing.
pub fn socket_parent(socket: &Path) -> Result<&Path> {
    if !socket.is_absolute() {
        bail!("socket path must be absolute: {}", socket.display());
    }
    if socket.as_os_str().len() > MAX_SOCKET_PATH {
        bail!(
            "socket path exceeds the portable Unix socket path limit ({MAX_SOCKET_PATH} bytes): {}",
            socket.display()
        );
    }
    socket.parent().context("socket needs a parent directory")
}

/// Explain an unusable socket directory, naming its owner and the way out.
pub fn untrusted_socket_dir(dir: &Path, error: impl std::fmt::Display) -> anyhow::Error {
    let owner = match fs::symlink_metadata(dir) {
        Ok(meta) => format!(
            " It is owned by uid {} with mode {:o}{}.",
            meta.uid(),
            meta.mode() & 0o7777,
            if meta.file_type().is_symlink() {
                " and is a symlink"
            } else {
                ""
            }
        ),
        Err(_) => String::new(),
    };
    anyhow::anyhow!(
        "cannot use socket directory {}: {error}.{owner} The host needs a directory owned by this user (uid {}) with mode 0700 that is not a symlink. Remove or fix it, or set CHERRY_HOST_SOCKET to a socket path inside a private directory.",
        dir.display(),
        euid()
    )
}

/// Explain a socket path that holds something other than this user's socket.
pub fn occupied_socket_path(path: &Path, action: &str) -> anyhow::Error {
    let what = match fs::symlink_metadata(path) {
        Ok(meta) => {
            let kind = meta.file_type();
            let kind = if kind.is_file() {
                "a regular file"
            } else if kind.is_dir() {
                "a directory"
            } else if kind.is_symlink() {
                "a symlink"
            } else if kind.is_socket() {
                "a socket"
            } else if kind.is_fifo() {
                "a named pipe"
            } else {
                "a device"
            };
            format!("it is {kind} owned by uid {}", meta.uid())
        }
        Err(error) => error.to_string(),
    };
    anyhow::anyhow!(
        "{action} {}: {what}, not a socket owned by this user (uid {}). Remove it, or set CHERRY_HOST_SOCKET to another socket path.",
        path.display(),
        euid()
    )
}

/// Create `dir` with mode 0700 unless it exists, tolerating a concurrent
/// creator, then verify that it is a private directory owned by this user.
fn ensure_private_dir(dir: &Path, parents: bool) -> io::Result<()> {
    match fs::symlink_metadata(dir) {
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            if parents {
                if let Some(parent) = dir.parent() {
                    fs::DirBuilder::new()
                        .recursive(true)
                        .mode(0o700)
                        .create(parent)?;
                }
            }
            match fs::DirBuilder::new().mode(0o700).create(dir) {
                Ok(()) => {}
                // Another client created it first; verify what is there now.
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                Err(error) => return Err(error),
            }
        }
        Err(error) => return Err(error),
    }
    cherry_protocol::verify_private_dir(dir)
}

/// The state directory for `socket`, without creating it
/// (`cherry_protocol::state_dir`).
pub fn state_dir(socket: &Path) -> Result<PathBuf> {
    Ok(cherry_protocol::state_dir(socket)?)
}

/// Create (mode 0700) or verify the state directory for `socket`.
pub fn open_state_dir(socket: &Path) -> Result<PathBuf> {
    let dir = state_dir(socket)?;
    ensure_private_dir(&dir, true).with_context(|| {
        format!(
            "cannot use state directory {}; it must be a directory owned by this user with mode 0700",
            dir.display()
        )
    })?;
    Ok(dir)
}

#[cfg(test)]
fn state_key(socket: &Path) -> String {
    cherry_protocol::state_key(socket)
}

/// HOME when it is an absolute path, otherwise the password database entry.
pub fn home_dir() -> Result<PathBuf> {
    Ok(cherry_protocol::home_dir()?)
}

/// The login shell from the password database.
pub fn passwd_shell() -> Option<OsString> {
    cherry_protocol::passwd_field(|entry| entry.pw_shell)
}

/// Sessions outlive the daemon in their holders, and each holder keeps a
/// manifest here: `<state dir>/sessions/<id>.json`.
pub const SESSIONS_DIR: &str = "sessions";

/// What a starting daemon learns about a session held by a holder process
/// (see `holder`): which holders to expect.
#[derive(serde::Serialize, serde::Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct Manifest {
    pub id: String,
    pub holder_pid: u32,
    /// Milliseconds since the Unix epoch.
    pub created_at: u64,
    pub link_version: u16,
    /// When the holder process started (`processes::start_identity`): a
    /// process that got its PID later, or after a reboot, is not it.
    #[serde(default)]
    pub holder_started: Option<String>,
    /// The holder's build (`cherry_protocol::BUILD`), for `cherry doctor`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub build: Option<String>,
}

/// Where the manifest of session `id` lives.
pub fn manifest_path(state: &Path, id: &str) -> PathBuf {
    state.join(SESSIONS_DIR).join(format!("{id}.json"))
}

/// Write a holder's manifest, whole: returns its path. It is not flushed
/// to disk: it only matters while its holder runs, and no holder outlives a
/// crash of the system.
pub fn write_manifest(state: &Path, manifest: &Manifest) -> Result<PathBuf> {
    let dir = state.join(SESSIONS_DIR);
    ensure_private_dir(&dir, false)
        .with_context(|| format!("cannot use sessions directory {}", dir.display()))?;
    let name = format!("{}.json", manifest.id);
    write_atomic(&dir, &name, &serde_json::to_vec(manifest)?, false)?;
    Ok(dir.join(name))
}

/// The manifests in the state directory, with their paths. Unreadable ones
/// are skipped (and left alone).
pub fn read_manifests(state: &Path) -> Vec<(PathBuf, Manifest)> {
    let dir = state.join(SESSIONS_DIR);
    let Ok(entries) = fs::read_dir(&dir) else {
        return Vec::new();
    };
    entries
        .filter_map(|entry| {
            let path = entry.ok()?.path();
            if path.extension()? != "json" {
                return None;
            }
            let bytes = fs::read(&path).ok()?;
            let manifest: Manifest = serde_json::from_slice(&bytes).ok()?;
            (path.file_stem()? == manifest.id.as_str()).then_some((path, manifest))
        })
        .collect()
}

/// Replace `dir/name` with `bytes`: readers see the old file or the new
/// one, never a partial one. A `durable` file is on disk before it gets its
/// name, so a crash of the system leaves one of them too.
fn write_atomic(dir: &Path, name: &str, bytes: &[u8], durable: bool) -> Result<()> {
    use io::Write;
    let path = dir.join(name);
    let temporary = dir.join(format!(".{name}.{}.tmp", std::process::id()));
    let _ = fs::remove_file(&temporary);
    let written = fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&temporary)
        .and_then(|mut file| {
            file.write_all(bytes)?;
            if durable {
                file.sync_all()?;
            }
            Ok(())
        })
        .and_then(|()| fs::rename(&temporary, &path));
    if let Err(error) = written {
        let _ = fs::remove_file(&temporary);
        return Err(error).with_context(|| format!("writing {}", path.display()));
    }
    if durable {
        if let Ok(dir) = fs::File::open(dir) {
            let _ = dir.sync_all();
        }
    }
    Ok(())
}

/// Read the host identity, creating it on first use. It survives daemon
/// restarts, so clients can tell a restarted host from a different one.
/// Called with the state directory's lock held, so nothing else writes it.
pub fn host_id(state: &Path) -> Result<String> {
    use io::Read;
    let path = state.join("host-id");
    match fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&path)
    {
        Ok(file) => {
            let mut bytes = Vec::new();
            file.take(128)
                .read_to_end(&mut bytes)
                .with_context(|| format!("reading {}", path.display()))?;
            if let Some(id) = std::str::from_utf8(&bytes)
                .ok()
                .and_then(|id| uuid::Uuid::parse_str(id.trim()).ok())
            {
                return Ok(id.to_string());
            }
            // Only an edit or a disk fault garbles it. The next host looks
            // new to clients, although held sessions may carry over to it.
            crate::daemon::log(format_args!(
                "replacing the unreadable host identity in {}",
                path.display()
            ));
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error).with_context(|| format!("opening {}", path.display())),
    }
    let id = uuid::Uuid::new_v4().to_string();
    write_atomic(state, "host-id", id.as_bytes(), true)?;
    Ok(id)
}

/// Set a path's access and modification times to now without following
/// symlinks, so age-based tmp cleaners leave a live socket alone.
pub fn touch(path: &Path) {
    let Ok(path) = CString::new(path.as_os_str().as_bytes()) else {
        return;
    };
    unsafe {
        libc::utimensat(
            libc::AT_FDCWD,
            path.as_ptr(),
            std::ptr::null(),
            libc::AT_SYMLINK_NOFOLLOW,
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_keys_are_stable_and_distinguish_sockets() {
        assert_eq!(
            state_key(&cherry_protocol::builtin_socket_path()),
            "default"
        );
        let key = state_key(Path::new("/tmp/elsewhere/host.sock"));
        assert_eq!(key.len(), 16);
        assert_eq!(key, state_key(Path::new("/tmp/elsewhere/host.sock")));
        assert_ne!(key, state_key(Path::new("/tmp/elsewhere2/host.sock")));
        // Pinned so that a toolchain change can never move existing state.
        assert_eq!(state_key(Path::new("/x")), "07d64e07b49caeb2");
    }

    #[test]
    fn the_host_identity_is_written_whole_and_kept() {
        let state = tempfile::tempdir().unwrap();
        let id = host_id(state.path()).unwrap();
        assert!(uuid::Uuid::parse_str(&id).is_ok());
        assert_eq!(host_id(state.path()).unwrap(), id);
        let path = state.path().join("host-id");
        assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o600);
        // No temporary file is left behind.
        let names: Vec<_> = fs::read_dir(state.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        assert_eq!(names, ["host-id"]);
        // An empty or garbled file (a crash, an edit) is replaced rather
        // than keeping every later daemon from starting.
        for broken in [&b""[..], b"not-a-uuid", b"\xff\xfe"] {
            fs::write(&path, broken).unwrap();
            let replaced = host_id(state.path()).unwrap();
            assert_ne!(replaced, id);
            assert_eq!(host_id(state.path()).unwrap(), replaced);
        }
    }
}
