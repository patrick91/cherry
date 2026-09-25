//! What the daemon and its sessions inherit. The daemon may be started by any
//! client (a Cherry tab, an SSH gateway, a script), so nothing identifying that
//! client may leak into sessions created later by others. What a session
//! should have from its own client, that client sends with `Create`.
use anyhow::{bail, Context, Result};
use std::{
    collections::BTreeMap,
    ffi::OsString,
    path::{Component, Path, PathBuf},
};

/// A `Create` carries at most this many variables,
const MAX_CLIENT_VARS: usize = 1024;
/// and this many bytes of names and values.
const MAX_CLIENT_ENV_BYTES: usize = 256 * 1024;

/// Variables the daemon keeps from whoever started it, and passes to sessions.
pub fn inherited(key: &str) -> bool {
    matches!(
        key,
        "HOME"
            | "USER"
            | "LOGNAME"
            | "SHELL"
            | "PATH"
            | "TMPDIR"
            | "TZ"
            | "LANG"
            | "XDG_RUNTIME_DIR"
    ) || key.starts_with("LC_")
        || (key.len() > "XDG__HOME".len() && key.starts_with("XDG_") && key.ends_with("_HOME"))
}

/// The allowlisted part of this process's environment.
pub fn inherited_vars() -> Vec<(OsString, OsString)> {
    std::env::vars_os()
        .filter(|(key, _)| key.to_str().is_some_and(inherited))
        .collect()
}

fn is_locale(key: &str) -> bool {
    key == "LANG" || key.starts_with("LC_")
}

/// The variables a `Create` sets: any a program can be given, a non-empty
/// name without `=` or NUL and a value without NUL. Clients run as the
/// daemon's user (the socket admits no other), so they may set whatever
/// their own shell could.
pub fn client_env(env: BTreeMap<String, String>) -> Result<BTreeMap<String, String>> {
    if env.len() > MAX_CLIENT_VARS
        || env.iter().map(|(k, v)| k.len() + v.len()).sum::<usize>() > MAX_CLIENT_ENV_BYTES
    {
        bail!(
            "environment exceeds limit ({MAX_CLIENT_VARS} variables, {MAX_CLIENT_ENV_BYTES} bytes)"
        );
    }
    for (key, value) in &env {
        if key.is_empty() || key.contains('=') || key.contains('\0') || value.contains('\0') {
            bail!("invalid environment variable {key:?}");
        }
    }
    Ok(env)
}

/// The complete environment of a new session, whose working directory is
/// `pwd` (see `logical_cwd`).
pub fn session_env(
    session_id: &str,
    agent_link: &Path,
    client: &BTreeMap<String, String>,
    pwd: &Path,
) -> Vec<(OsString, OsString)> {
    session_env_from(inherited_vars(), session_id, agent_link, client, pwd)
}

/// The daemon's variables (`inherited`), the host's defaults, then the
/// client's, which replace any of them, then what only the host knows: the
/// session's ID and working directory.
fn session_env_from(
    daemon: Vec<(OsString, OsString)>,
    session_id: &str,
    agent_link: &Path,
    client: &BTreeMap<String, String>,
    pwd: &Path,
) -> Vec<(OsString, OsString)> {
    let mut env: BTreeMap<OsString, OsString> = daemon.into_iter().collect();
    // A client's locale replaces the daemon's as a whole: the locale of
    // whoever started the daemon (an LC_ALL, say) would otherwise override
    // the LANG this client asked for. The daemon's is only a fallback.
    if client.keys().any(|key| is_locale(key)) {
        env.retain(|key, _| !key.to_str().is_some_and(is_locale));
    }
    env.entry("PATH".into())
        .or_insert_with(|| "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin".into());
    if !env.contains_key(&OsString::from("SHELL")) {
        if let Some(shell) = crate::paths::passwd_shell() {
            env.insert("SHELL".into(), shell);
        }
    }
    for (key, value) in [
        ("TERM", "xterm-256color"),
        ("COLORTERM", "truecolor"),
        ("TERM_PROGRAM", "Cherry"),
    ] {
        env.insert(key.into(), value.into());
    }
    // The link leads to the agent of a client using sessions, while one
    // is connected (see `cherry_protocol::AGENT_LINK_NAME`).
    env.insert("SSH_AUTH_SOCK".into(), agent_link.into());
    for (key, value) in client {
        env.insert(key.into(), value.into());
    }
    env.insert("CHERRY_SESSION_ID".into(), session_id.into());
    env.insert("PWD".into(), pwd.into());
    env.into_iter().collect()
}

/// A working directory as a client names it: absolute, `~`, or `~/…`
/// (expanded with the daemon's HOME). The daemon's own cwd is `/` and never
/// used.
fn expand_cwd(cwd: &str) -> Result<PathBuf> {
    Ok(if cwd.is_empty() || cwd == "~" {
        crate::paths::home_dir()?
    } else if let Some(rest) = cwd.strip_prefix("~/") {
        crate::paths::home_dir()?.join(rest)
    } else if cwd.starts_with('/') {
        PathBuf::from(cwd)
    } else {
        bail!("working directory must be absolute or start with ~/: {cwd}");
    })
}

/// A session's `PWD`, for the directory `cwd` that resolved to `resolved`
/// (`resolve_cwd`): `cwd` as the client named it (expanded, without
/// repeated or trailing slashes) when that names the same directory
/// without `..`, as a shell keeps a path through symbolic links; otherwise
/// `resolved`. Shells trust `PWD` only when it names their directory.
pub fn logical_cwd(cwd: &str, resolved: &Path) -> PathBuf {
    let Ok(path) = expand_cwd(cwd) else {
        return resolved.to_path_buf();
    };
    // Components drop repeated and trailing slashes and `.`.
    let logical: PathBuf = path.components().collect();
    let names_it = !logical
        .components()
        .any(|component| component == Component::ParentDir)
        && logical
            .canonicalize()
            .is_ok_and(|canonical| canonical == resolved);
    if names_it {
        logical
    } else {
        resolved.to_path_buf()
    }
}

/// Resolve a session's working directory (see `expand_cwd`) to its
/// canonical path, which must be a directory.
pub fn resolve_cwd(cwd: &str) -> Result<PathBuf> {
    let path = expand_cwd(cwd)?;
    let resolved = path.canonicalize().with_context(|| {
        format!(
            "working directory {} does not exist on the host",
            path.display()
        )
    })?;
    if !resolved.is_dir() {
        bail!(
            "working directory {} is not a directory",
            resolved.display()
        );
    }
    Ok(resolved)
}

/// Mark every descriptor above stderr close-on-exec. Async-signal-safe, for
/// use between fork and exec.
pub fn cloexec_from_3() {
    cloexec_from_3_below(None);
}

/// One past the highest open descriptor, from `/dev/fd`. Only a process
/// with a single thread can rely on it until it forks: no other thread can
/// open a descriptor meanwhile.
pub fn open_fd_end() -> Option<libc::c_int> {
    std::fs::read_dir("/dev/fd")
        .ok()?
        .filter_map(|entry| {
            entry
                .ok()?
                .file_name()
                .to_str()?
                .parse::<libc::c_int>()
                .ok()
        })
        .max()
        .map(|fd| fd + 1)
}

/// `cloexec_from_3`, looking no further than `end` (see `open_fd_end`)
/// where there is no faster way than a descriptor at a time: macOS, whose
/// descriptor limit can be a million.
pub fn cloexec_from_3_below(end: Option<libc::c_int>) {
    #[cfg(target_os = "linux")]
    unsafe {
        if libc::syscall(
            libc::SYS_close_range,
            3u32,
            u32::MAX,
            libc::CLOSE_RANGE_CLOEXEC,
        ) == 0
        {
            return;
        }
    }
    let mut limit: libc::rlimit = unsafe { std::mem::zeroed() };
    let max = if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) } == 0 {
        limit.rlim_cur.min(1 << 20) as libc::c_int
    } else {
        1024
    };
    let max = end.map_or(max, |end| end.min(max));
    for fd in 3..max {
        unsafe {
            let flags = libc::fcntl(fd, libc::F_GETFD);
            if flags >= 0 && flags & libc::FD_CLOEXEC == 0 {
                libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC);
            }
        }
    }
}

/// Close descriptors above stderr inherited from whoever started the daemon.
/// A long-lived daemon must not keep, say, a script's lock file open.
pub fn close_inherited_fds() {
    let fds: Vec<libc::c_int> = std::fs::read_dir("/dev/fd")
        .into_iter()
        .flatten()
        .filter_map(|entry| entry.ok()?.file_name().to_str()?.parse().ok())
        .filter(|fd| *fd > 2)
        .collect();
    // The listing's own descriptor is already closed and simply fails here.
    for fd in fds {
        unsafe {
            libc::close(fd);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_open_descriptors_end_below_the_bound() {
        let file = std::fs::File::open("/dev/null").unwrap();
        let fd = std::os::unix::io::AsRawFd::as_raw_fd(&file);
        assert!(open_fd_end().unwrap() > fd);
    }

    #[test]
    fn only_neutral_variables_are_inherited() {
        for key in [
            "HOME",
            "PATH",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "XDG_CONFIG_HOME",
            "XDG_STATE_HOME",
            "XDG_RUNTIME_DIR",
            "TZ",
        ] {
            assert!(inherited(key), "{key}");
        }
        for key in [
            "SSH_AUTH_SOCK",
            "CHERRY_PROCESS_ID",
            "PWD",
            "OLDPWD",
            "XDG_SESSION_ID",
            "XDG__HOME",
            "DISPLAY",
            "TERM",
        ] {
            assert!(!inherited(key), "{key}");
        }
    }

    fn vars(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    #[test]
    fn clients_may_set_any_variable_a_program_can_be_given() {
        let ok = vars(&[
            ("LANG", "en_US.UTF-8"),
            ("PATH", "/opt/bin:/usr/bin"),
            ("TERM", "xterm-ghostty"),
            ("BASH_FUNC_greet%%", "() {  echo hi\n}"),
            ("lower.case-name", ""),
        ]);
        assert_eq!(client_env(ok.clone()).unwrap(), ok);
        for (key, value) in [("", "x"), ("A=B", "x"), ("NUL\0", "x"), ("VALUE", "a\0b")] {
            let error = client_env(vars(&[(key, value)])).unwrap_err().to_string();
            assert!(error.contains("invalid environment variable"), "{error}");
        }
        let many: BTreeMap<String, String> = (0..=MAX_CLIENT_VARS)
            .map(|n| (format!("V{n}"), String::new()))
            .collect();
        assert!(client_env(many).is_err());
        let long = vars(&[("LONG", &"x".repeat(MAX_CLIENT_ENV_BYTES))]);
        assert!(client_env(long).is_err());
    }

    #[test]
    fn the_client_overrides_the_host_defaults_but_not_the_session_identity() {
        let daemon: Vec<(OsString, OsString)> = [("HOME", "/home/u"), ("PATH", "/bin")]
            .into_iter()
            .map(|(k, v)| (k.into(), v.into()))
            .collect();
        let env = |client: &[(&str, &str)]| -> BTreeMap<String, String> {
            session_env_from(
                daemon.clone(),
                "id",
                Path::new("/s/agent.sock"),
                &vars(client),
                Path::new("/work/here"),
            )
            .into_iter()
            .map(|(k, v)| (k.into_string().unwrap(), v.into_string().unwrap()))
            .collect()
        };
        let defaults = env(&[]);
        for (key, value) in [
            ("TERM", "xterm-256color"),
            ("TERM_PROGRAM", "Cherry"),
            ("COLORTERM", "truecolor"),
            ("SSH_AUTH_SOCK", "/s/agent.sock"),
            ("PATH", "/bin"),
            ("CHERRY_SESSION_ID", "id"),
            ("PWD", "/work/here"),
        ] {
            assert_eq!(defaults.get(key).map(String::as_str), Some(value), "{key}");
        }
        let chosen = env(&[
            ("TERM", "xterm-ghostty"),
            ("TERM_PROGRAM", "ghostty"),
            ("SSH_AUTH_SOCK", "/agent"),
            ("PATH", "/opt/bin"),
            ("EXTRA", "1"),
            ("CHERRY_SESSION_ID", "forged"),
            ("PWD", "/elsewhere"),
        ]);
        for (key, value) in [
            ("TERM", "xterm-ghostty"),
            ("TERM_PROGRAM", "ghostty"),
            ("SSH_AUTH_SOCK", "/agent"),
            ("PATH", "/opt/bin"),
            ("EXTRA", "1"),
            ("CHERRY_SESSION_ID", "id"),
            ("PWD", "/work/here"),
        ] {
            assert_eq!(chosen.get(key).map(String::as_str), Some(value), "{key}");
        }
    }

    #[test]
    fn pwd_keeps_the_path_the_client_named_when_it_names_the_directory() {
        let dir = tempfile::Builder::new()
            .prefix("ch-")
            .tempdir_in("/tmp")
            .unwrap();
        let real = dir.path().join("real");
        std::fs::create_dir(&real).unwrap();
        std::os::unix::fs::symlink(&real, dir.path().join("link")).unwrap();
        let link = format!("{}/link", dir.path().display());
        let resolved = resolve_cwd(&link).unwrap();
        assert_eq!(resolved, real.canonicalize().unwrap());
        // Through the link, tidied.
        for named in [
            link.clone(),
            format!("{link}/"),
            link.replace("/link", "//link/."),
        ] {
            assert_eq!(
                logical_cwd(&named, &resolved),
                PathBuf::from(&link),
                "{named}"
            );
        }
        // `..` is not trusted; nor is a path that is not the directory.
        let up = format!("{link}/../link");
        assert_eq!(logical_cwd(&up, &resolve_cwd(&up).unwrap()), resolved);
        assert_eq!(logical_cwd("/", &resolved), resolved);
        let home = crate::paths::home_dir().unwrap();
        assert_eq!(logical_cwd("~", &home.canonicalize().unwrap()), home);
    }

    #[test]
    fn a_client_locale_replaces_the_daemon_locale() {
        let daemon: Vec<(OsString, OsString)> = [
            ("HOME", "/home/u"),
            ("LANG", "C"),
            ("LC_ALL", "C"),
            ("LC_CTYPE", "POSIX"),
            ("TZ", "Asia/Tokyo"),
        ]
        .into_iter()
        .map(|(k, v)| (k.into(), v.into()))
        .collect();
        let env = |client: &[(&str, &str)]| -> BTreeMap<String, String> {
            let client = client
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect();
            session_env_from(
                daemon.clone(),
                "id",
                Path::new("/s/agent.sock"),
                &client,
                Path::new("/"),
            )
            .into_iter()
            .filter(|(key, _)| {
                key == "LANG" || key == "TZ" || key.to_string_lossy().starts_with("LC_")
            })
            .map(|(k, v)| (k.into_string().unwrap(), v.into_string().unwrap()))
            .collect()
        };
        let pairs = |pairs: &[(&str, &str)]| -> BTreeMap<String, String> {
            pairs
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect()
        };
        assert_eq!(
            env(&[("LANG", "en_US.UTF-8")]),
            pairs(&[("LANG", "en_US.UTF-8"), ("TZ", "Asia/Tokyo")])
        );
        assert_eq!(
            env(&[("LC_TIME", "en_GB.UTF-8"), ("TZ", "UTC")]),
            pairs(&[("LC_TIME", "en_GB.UTF-8"), ("TZ", "UTC")])
        );
        // A client that sends no locale gets the daemon's.
        assert_eq!(
            env(&[]),
            pairs(&[
                ("LANG", "C"),
                ("LC_ALL", "C"),
                ("LC_CTYPE", "POSIX"),
                ("TZ", "Asia/Tokyo")
            ])
        );
    }

    #[test]
    fn working_directories_expand_home_and_reject_relative_paths() {
        let home = crate::paths::home_dir().unwrap().canonicalize().unwrap();
        assert_eq!(resolve_cwd("~").unwrap(), home);
        assert_eq!(resolve_cwd("").unwrap(), home);
        assert_eq!(resolve_cwd("/").unwrap(), PathBuf::from("/"));
        for relative in [".", "src", "~other/x", "./x"] {
            let error = resolve_cwd(relative).unwrap_err().to_string();
            assert!(error.contains("absolute or start with ~/"), "{error}");
        }
        assert!(resolve_cwd("/does/not/exist")
            .unwrap_err()
            .to_string()
            .contains("does not exist"));
    }
}
