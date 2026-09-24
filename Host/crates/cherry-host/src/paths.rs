//! Where a host keeps its socket and its durable state.
//!
//! The socket lives in its own private directory (by default under /tmp, so
//! the path stays short enough for sockaddr_un). The host identity, lock and
//! log live in a per-user state directory that tmp cleaners never touch:
//! `~/Library/Application Support/cherry-host/<key>` on macOS and
//! `${XDG_STATE_HOME:-~/.local/state}/cherry-host/<key>` elsewhere. The key is
//! `default` for the default socket and a stable hash of any other socket path.
use anyhow::{bail, Context, Result};
use std::{
    ffi::{CStr, CString, OsString},
    fs, io,
    os::unix::{
        ffi::{OsStrExt, OsStringExt},
        fs::{DirBuilderExt, FileTypeExt, MetadataExt, OpenOptionsExt},
    },
    path::{Path, PathBuf},
};

/// sockaddr_un holds 104 bytes on macOS; stay below it everywhere.
const MAX_SOCKET_PATH: usize = 100;

/// The socket path used when neither --socket nor CHERRY_HOST_SOCKET is set.
pub fn builtin_socket_path() -> PathBuf {
    PathBuf::from(format!("/tmp/cherry-host-{}/host.sock", euid()))
}

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

/// The state directory for `socket`, without creating it.
pub fn state_dir(socket: &Path) -> Result<PathBuf> {
    let home = home_dir()?;
    #[cfg(target_os = "macos")]
    let base = home.join("Library/Application Support");
    #[cfg(not(target_os = "macos"))]
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .unwrap_or_else(|| home.join(".local/state"));
    Ok(base.join("cherry-host").join(state_key(socket)))
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

fn state_key(socket: &Path) -> String {
    if socket == builtin_socket_path() {
        return "default".into();
    }
    // FNV-1a: stable across builds and platforms, unlike std's hasher.
    let hash = socket
        .as_os_str()
        .as_bytes()
        .iter()
        .fold(0xcbf2_9ce4_8422_2325u64, |hash, &byte| {
            (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
        });
    format!("{hash:016x}")
}

/// HOME when it is an absolute path, otherwise the password database entry.
pub fn home_dir() -> Result<PathBuf> {
    if let Some(home) = std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|home| home.is_absolute())
    {
        return Ok(home);
    }
    passwd_field(|entry| entry.pw_dir)
        .map(PathBuf::from)
        .context("cannot determine this user's home directory (HOME is not set)")
}

/// The login shell from the password database.
pub fn passwd_shell() -> Option<OsString> {
    passwd_field(|entry| entry.pw_shell)
}

fn passwd_field(field: impl Fn(&libc::passwd) -> *mut libc::c_char) -> Option<OsString> {
    let mut buffer = vec![0 as libc::c_char; 16 * 1024];
    let mut entry: libc::passwd = unsafe { std::mem::zeroed() };
    let mut result = std::ptr::null_mut();
    let status = unsafe {
        libc::getpwuid_r(
            euid(),
            &mut entry,
            buffer.as_mut_ptr(),
            buffer.len(),
            &mut result,
        )
    };
    if status != 0 || result.is_null() {
        return None;
    }
    let value = field(&entry);
    if value.is_null() {
        return None;
    }
    let bytes = unsafe { CStr::from_ptr(value) }.to_bytes().to_vec();
    (!bytes.is_empty()).then(|| OsString::from_vec(bytes))
}

/// Read the host identity, creating it on first use. It survives daemon
/// restarts, so clients can tell a restarted host from a different one.
/// Called with the state directory's lock held, so nothing else writes it.
pub fn host_id(state: &Path) -> Result<String> {
    use io::{Read, Write};
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
            // Sessions never outlive the daemon, so a lost identity only
            // makes the next host look new, which it is.
            crate::daemon::log(format_args!(
                "replacing the unreadable host identity in {}",
                path.display()
            ));
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error).with_context(|| format!("opening {}", path.display())),
    }
    let id = uuid::Uuid::new_v4().to_string();
    // Complete and on disk before it gets its name: a crash leaves either
    // the old file or the new identity, never a partial one.
    let temporary = state.join(format!(".host-id.{}.tmp", std::process::id()));
    let _ = fs::remove_file(&temporary);
    let written = fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&temporary)
        .and_then(|mut file| {
            file.write_all(id.as_bytes())?;
            file.sync_all()
        })
        .and_then(|()| fs::rename(&temporary, &path));
    if let Err(error) = written {
        let _ = fs::remove_file(&temporary);
        return Err(error).with_context(|| format!("writing {}", path.display()));
    }
    if let Ok(dir) = fs::File::open(state) {
        let _ = dir.sync_all();
    }
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
        assert_eq!(state_key(&builtin_socket_path()), "default");
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
