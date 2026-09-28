//! `cherry-host version` and `cherry-host status`: what this executable is,
//! and what answers at a socket, for a client that checks a machine before
//! it uses it (Cherry's Add Mac, docs/specs/remote-devices.md). Neither
//! starts, replaces nor changes a host.
use crate::{daemon, launch::Probe};
use cherry_protocol::PROTOCOL_VERSION;
use serde::Serialize;

/// `cherry-host version --json`.
#[derive(Serialize, Debug, PartialEq, Eq)]
pub struct VersionReport {
    /// The client protocol this cherry-host speaks.
    pub protocol: u32,
    /// Its build (`daemon::build`).
    pub build: String,
    /// The package version.
    pub version: String,
    /// The operating system it was built for (`macos`, `linux`).
    pub os: &'static str,
    /// The architecture it was built for (`aarch64`, `x86_64`).
    pub arch: &'static str,
    /// The oldest macOS it runs on; null on other systems.
    pub min_macos: Option<&'static str>,
}

pub fn version() -> VersionReport {
    VersionReport {
        protocol: PROTOCOL_VERSION,
        build: daemon::build().to_owned(),
        version: env!("CARGO_PKG_VERSION").to_owned(),
        os: std::env::consts::OS,
        arch: std::env::consts::ARCH,
        min_macos: min_macos(),
    }
}

/// The deployment target this executable was built for: the one the build
/// set (`MACOSX_DEPLOYMENT_TARGET`), else Rust's default for the target.
fn min_macos() -> Option<&'static str> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    Some(match option_env!("MACOSX_DEPLOYMENT_TARGET") {
        Some(target) if !target.is_empty() => target,
        _ if cfg!(target_arch = "aarch64") => "11.0",
        _ => "10.12",
    })
}

/// `cherry-host status --json`: whether a host answers at the socket, and
/// who it is. Only a Hello is sent (`launch::probe`).
#[derive(Serialize, Debug, PartialEq, Eq)]
pub struct StatusReport {
    /// Something listens at the socket.
    pub running: bool,
    /// `absent`, `ready` (this protocol), `older` (an older protocol, which
    /// a client replaces), `other` (a newer protocol, or one too old to
    /// replace), `unresponsive`, or `error`: the socket could not be
    /// checked (its directory is not private, another account listens on
    /// it, it could not be reached), with `error`; `running` is then false,
    /// meaning none of this user's hosts answered, not that nothing listens.
    pub state: &'static str,
    /// The protocol it speaks, when it said.
    pub protocol: Option<u32>,
    /// Its build, when it said (protocol 7 and later).
    pub build: Option<String>,
    /// Its identity, when it welcomed the probe.
    pub host_id: Option<String>,
    /// Why an unresponsive host did not answer, or the socket could not be
    /// checked.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

pub fn status(probe: Probe) -> StatusReport {
    let report = |state, protocol, build, host_id| StatusReport {
        running: true,
        state,
        protocol,
        build,
        host_id,
        error: None,
    };
    match probe {
        Probe::Absent => StatusReport {
            running: false,
            ..report("absent", None, None, None)
        },
        Probe::Ready { host_id, build } => {
            report("ready", Some(PROTOCOL_VERSION), build, Some(host_id))
        }
        Probe::Older { version, host_id } => report("older", Some(version), None, Some(host_id)),
        Probe::OtherVersion { version, host_id } => report("other", version, None, host_id),
        Probe::Unresponsive(why) => StatusReport {
            error: Some(why),
            ..report("unresponsive", None, None, None)
        },
    }
}

/// The socket could not be checked (`launch::probe_existing` failed).
pub fn status_error(error: &anyhow::Error) -> StatusReport {
    StatusReport {
        running: false,
        state: "error",
        protocol: None,
        build: None,
        host_id: None,
        error: Some(format!("{error:#}")),
    }
}

/// `status` without `--json`: one line.
pub fn status_line(report: &StatusReport) -> String {
    match report.state {
        "absent" => "no cherry-host is running".to_owned(),
        "error" => format!(
            "the host socket could not be checked: {}",
            report.error.as_deref().unwrap_or("no reason")
        ),
        "unresponsive" => format!(
            "a cherry-host is running but did not answer ({})",
            report.error.as_deref().unwrap_or("no reason")
        ),
        _ => format!(
            "cherry-host {} running, protocol {}, build {}",
            report.host_id.as_deref().unwrap_or("(unknown identity)"),
            report
                .protocol
                .map_or_else(|| "unknown".to_owned(), |version| version.to_string()),
            report.build.as_deref().unwrap_or("unknown"),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_names_the_protocol_build_and_platform() {
        let report = version();
        assert_eq!(report.protocol, PROTOCOL_VERSION);
        assert_eq!(report.build, daemon::build());
        assert_eq!(report.arch, std::env::consts::ARCH);
        assert_eq!(report.min_macos.is_some(), cfg!(target_os = "macos"));
        let json: serde_json::Value = serde_json::to_value(&report).unwrap();
        for key in ["protocol", "build", "arch", "min_macos", "os", "version"] {
            assert!(json.get(key).is_some(), "{key}: {json}");
        }
    }

    #[test]
    fn status_reports_every_probe_outcome() {
        let json = |probe| serde_json::to_value(status(probe)).unwrap();
        assert_eq!(
            json(Probe::Absent),
            serde_json::json!({"running": false, "state": "absent", "protocol": null, "build": null, "host_id": null})
        );
        assert_eq!(
            json(Probe::Ready {
                host_id: "h".into(),
                build: Some("b".into())
            }),
            serde_json::json!({"running": true, "state": "ready", "protocol": PROTOCOL_VERSION, "build": "b", "host_id": "h"})
        );
        assert_eq!(
            json(Probe::Older {
                version: 5,
                host_id: "h".into()
            }),
            serde_json::json!({"running": true, "state": "older", "protocol": 5, "build": null, "host_id": "h"})
        );
        assert_eq!(
            json(Probe::OtherVersion {
                version: None,
                host_id: None
            })["state"],
            "other"
        );
        let error =
            serde_json::to_value(status_error(&anyhow::anyhow!("refusing to use /x"))).unwrap();
        assert_eq!(
            error,
            serde_json::json!({"running": false, "state": "error", "protocol": null, "build": null, "host_id": null, "error": "refusing to use /x"})
        );
        let unresponsive = json(Probe::Unresponsive("busy".into()));
        assert_eq!(unresponsive["running"], true);
        assert_eq!(unresponsive["error"], "busy");
    }
}
