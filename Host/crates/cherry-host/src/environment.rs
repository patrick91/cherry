//! What the daemon and its sessions inherit. The daemon may be started by any
//! client (a Cherry tab, an SSH gateway, a script), so nothing identifying that
//! client may leak into sessions created later by others.
use anyhow::{bail, Context, Result};
use std::{
    collections::BTreeMap,
    ffi::OsString,
    path::{Path, PathBuf},
};

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

/// A `Create` may only choose the session's locale and time zone.
pub fn client_env(env: BTreeMap<String, String>) -> Result<BTreeMap<String, String>> {
    if env.len() > 128 || env.iter().map(|(k, v)| k.len() + v.len()).sum::<usize>() > 65536 {
        bail!("environment exceeds limit");
    }
    for (key, value) in &env {
        if !(key == "TZ" || is_locale(key)) {
            bail!("environment variable {key:?} cannot be set by a client; only LANG, LC_* and TZ are accepted");
        }
        if key.contains('=') || key.contains('\0') || value.contains('\0') {
            bail!("invalid environment variable {key:?}");
        }
    }
    Ok(env)
}

/// The complete environment of a new session.
pub fn session_env(
    session_id: &str,
    agent_link: &Path,
    client: &BTreeMap<String, String>,
) -> Vec<(OsString, OsString)> {
    session_env_from(inherited_vars(), session_id, agent_link, client)
}

fn session_env_from(
    daemon: Vec<(OsString, OsString)>,
    session_id: &str,
    agent_link: &Path,
    client: &BTreeMap<String, String>,
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
        ("CHERRY_SESSION_ID", session_id),
    ] {
        env.insert(key.into(), value.into());
    }
    // The link leads to the agent of a client using sessions, while one
    // is connected (see `cherry_protocol::AGENT_LINK_NAME`).
    env.insert("SSH_AUTH_SOCK".into(), agent_link.into());
    for (key, value) in client {
        env.insert(key.into(), value.into());
    }
    env.into_iter().collect()
}

/// Resolve a session's working directory: absolute, `~`, or `~/…` (expanded
/// with the daemon's HOME). The daemon's own cwd is `/` and never used.
pub fn resolve_cwd(cwd: &str) -> Result<PathBuf> {
    let path = if cwd.is_empty() || cwd == "~" {
        crate::paths::home_dir()?
    } else if let Some(rest) = cwd.strip_prefix("~/") {
        crate::paths::home_dir()?.join(rest)
    } else if cwd.starts_with('/') {
        PathBuf::from(cwd)
    } else {
        bail!("working directory must be absolute or start with ~/: {cwd}");
    };
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

    #[test]
    fn clients_may_only_set_locale_and_time_zone() {
        let ok = BTreeMap::from([
            ("LANG".to_string(), "en_US.UTF-8".to_string()),
            ("LC_CTYPE".into(), "C".into()),
            ("TZ".into(), "UTC".into()),
        ]);
        assert_eq!(client_env(ok.clone()).unwrap(), ok);
        let error = client_env(BTreeMap::from([("PATH".into(), "/evil".into())]))
            .unwrap_err()
            .to_string();
        assert!(error.contains("PATH") && error.contains("LANG"), "{error}");
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
            session_env_from(daemon.clone(), "id", Path::new("/s/agent.sock"), &client)
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
