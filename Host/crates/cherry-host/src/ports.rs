//! `cherry-host ports --json PID…`: the TCP ports the process trees of
//! sessions on this machine listen on, for a Cherry on another Mac
//! (docs/specs/remote-devices.md, phase 4a). That Cherry knows each
//! session's program pid (`SessionInfo.pid`) but no pid of this machine means
//! anything there, so it asks here, in one round trip over its SSH master, and
//! forwards the ports it shows. Like `project-info` it is shipped with (and
//! versioned like) the cherry-host Cherry installs, never starts, replaces or
//! talks to a host, and changes nothing: it reads the process table (`ps`)
//! and the listening sockets (`lsof` on macOS, `/proc` on Linux).
use serde::Serialize;
use std::collections::{BTreeSet, HashMap};
use std::process::{Command, Stdio};

/// The answer's format. Cherry refuses a version it does not know.
pub const FORMAT_VERSION: u32 = 1;
/// Pids asked about in one call.
pub const MAX_PIDS: usize = 256;

#[derive(Serialize, Debug, PartialEq, Eq)]
pub struct Report {
    pub version: u32,
    pub processes: Vec<ProcessPorts>,
    /// Why the listening sockets could not be read (no `lsof`, it failed):
    /// every process then reports no ports.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Serialize, Debug, PartialEq, Eq)]
pub struct ProcessPorts {
    /// The pid as asked.
    pub pid: i32,
    /// Whether it runs (a pid that is gone reports no ports).
    pub alive: bool,
    /// What it and its descendants listen on, by port then host.
    pub ports: Vec<Listener>,
}

#[derive(Serialize, Debug, PartialEq, Eq, Clone, PartialOrd, Ord)]
pub struct Listener {
    pub port: u16,
    /// The address it listens on: `127.0.0.1`, `::1`, `*` (every address),
    /// or another of this machine's.
    pub host: String,
    /// The process that listens (the asked pid or a descendant).
    pub pid: i32,
    /// Its command name, when known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
}

/// The report for `pids`, from this machine's process table and sockets.
pub fn report(pids: &[i32]) -> Report {
    let table = process_table();
    let listeners = listening_sockets(pids, &table);
    build(pids, &table, listeners)
}

/// The report from a process table (pid → parent) and the listening
/// sockets read (or why they could not be).
pub fn build(
    pids: &[i32],
    table: &HashMap<i32, i32>,
    listeners: Result<Vec<Listener>, String>,
) -> Report {
    let (listeners, error) = match listeners {
        Ok(listeners) => (listeners, None),
        Err(error) => (Vec::new(), Some(error)),
    };
    let processes = pids
        .iter()
        .take(MAX_PIDS)
        .map(|&pid| {
            let alive = pid > 0 && (table.contains_key(&pid) || is_running(pid));
            let members = if alive {
                descendants(pid, table)
            } else {
                BTreeSet::new()
            };
            let mut seen = BTreeSet::new();
            let mut ports: Vec<Listener> = listeners
                .iter()
                .filter(|listener| members.contains(&listener.pid))
                .filter(|listener| seen.insert((listener.port, listener.host.clone())))
                .cloned()
                .collect();
            ports.sort();
            ProcessPorts { pid, alive, ports }
        })
        .collect();
    Report {
        version: FORMAT_VERSION,
        processes,
        error,
    }
}

/// `pid` and every process below it in `table` (pid → parent).
pub fn descendants(pid: i32, table: &HashMap<i32, i32>) -> BTreeSet<i32> {
    let mut children: HashMap<i32, Vec<i32>> = HashMap::new();
    for (&child, &parent) in table {
        if child != parent {
            children.entry(parent).or_default().push(child);
        }
    }
    let mut members = BTreeSet::from([pid]);
    let mut frontier = vec![pid];
    while let Some(parent) = frontier.pop() {
        for &child in children.get(&parent).into_iter().flatten() {
            if members.insert(child) {
                frontier.push(child);
            }
        }
    }
    members
}

fn is_running(pid: i32) -> bool {
    // Signal 0 checks only; EPERM means it runs as another user.
    let running = unsafe { libc::kill(pid, 0) } == 0;
    running || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// Every process's parent, from `ps -axo pid=,ppid=`.
fn process_table() -> HashMap<i32, i32> {
    ["/bin/ps", "/usr/bin/ps"]
        .iter()
        .find(|path| std::path::Path::new(path).exists())
        .and_then(|ps| {
            Command::new(ps)
                .args(["-axo", "pid=,ppid="])
                .stdin(Stdio::null())
                .stderr(Stdio::null())
                .output()
                .ok()
        })
        .map(|output| parse_process_table(&String::from_utf8_lossy(&output.stdout)))
        .unwrap_or_default()
}

/// `ps -axo pid=,ppid=` lines.
pub fn parse_process_table(text: &str) -> HashMap<i32, i32> {
    text.lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let pid = fields.next()?.parse().ok()?;
            let parent = fields.next()?.parse().ok()?;
            Some((pid, parent))
        })
        .collect()
}

/// The TCP sockets in LISTEN state of the asked processes' trees.
#[cfg(target_os = "macos")]
fn listening_sockets(pids: &[i32], table: &HashMap<i32, i32>) -> Result<Vec<Listener>, String> {
    let members: BTreeSet<i32> = pids
        .iter()
        .take(MAX_PIDS)
        .filter(|pid| **pid > 0)
        .flat_map(|pid| descendants(*pid, table))
        .collect();
    if members.is_empty() {
        return Ok(Vec::new());
    }
    let lsof = ["/usr/sbin/lsof", "/usr/bin/lsof"]
        .iter()
        .find(|path| std::path::Path::new(path).exists())
        .ok_or_else(|| "lsof was not found".to_owned())?;
    let list = members
        .iter()
        .map(|pid| pid.to_string())
        .collect::<Vec<_>>()
        .join(",");
    let output = Command::new(lsof)
        .args([
            "-nP",
            "-a",
            "-p",
            &list,
            "-iTCP",
            "-sTCP:LISTEN",
            "-F",
            "pcnPT",
        ])
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("lsof could not run: {error}"))?;
    let listeners = parse_lsof(&String::from_utf8_lossy(&output.stdout));
    // lsof exits 1 when it found nothing (or some pids are gone).
    if output.status.success() || output.status.code() == Some(1) || !listeners.is_empty() {
        return Ok(listeners);
    }
    let message = String::from_utf8_lossy(&output.stderr).trim().to_owned();
    Err(if message.is_empty() {
        format!("lsof exited with {}", output.status)
    } else {
        message
    })
}

/// On Linux, from `/proc`: each process's socket inodes and the LISTEN
/// sockets of `/proc/net/tcp` and `tcp6`.
#[cfg(target_os = "linux")]
fn listening_sockets(pids: &[i32], table: &HashMap<i32, i32>) -> Result<Vec<Listener>, String> {
    let mut sockets: HashMap<u64, (String, u16)> = HashMap::new();
    for (file, v6) in [("/proc/net/tcp", false), ("/proc/net/tcp6", true)] {
        if let Ok(text) = std::fs::read_to_string(file) {
            sockets.extend(parse_proc_net_tcp(&text, v6));
        }
    }
    let mut listeners = Vec::new();
    let members: BTreeSet<i32> = pids
        .iter()
        .take(MAX_PIDS)
        .filter(|pid| **pid > 0)
        .flat_map(|pid| descendants(*pid, table))
        .collect();
    for pid in members {
        let Ok(entries) = std::fs::read_dir(format!("/proc/{pid}/fd")) else {
            continue;
        };
        let command = std::fs::read_to_string(format!("/proc/{pid}/comm"))
            .ok()
            .map(|name| name.trim().to_owned());
        for entry in entries.flatten() {
            let Ok(target) = std::fs::read_link(entry.path()) else {
                continue;
            };
            let target = target.to_string_lossy();
            let Some(inode) = target
                .strip_prefix("socket:[")
                .and_then(|rest| rest.strip_suffix(']'))
                .and_then(|inode| inode.parse::<u64>().ok())
            else {
                continue;
            };
            if let Some((host, port)) = sockets.get(&inode) {
                listeners.push(Listener {
                    port: *port,
                    host: host.clone(),
                    pid,
                    command: command.clone(),
                });
            }
        }
    }
    Ok(listeners)
}

/// LISTEN (state 0A) sockets of `/proc/net/tcp` (or `tcp6`): inode → address.
#[cfg(any(target_os = "linux", test))]
pub fn parse_proc_net_tcp(text: &str, v6: bool) -> HashMap<u64, (String, u16)> {
    let mut sockets = HashMap::new();
    for line in text.lines().skip(1) {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 10 || fields[3] != "0A" {
            continue;
        }
        let Some((address, port)) = fields[1].split_once(':') else {
            continue;
        };
        let (Ok(port), Ok(inode)) = (u16::from_str_radix(port, 16), fields[9].parse::<u64>())
        else {
            continue;
        };
        let host = if v6 {
            match address {
                "00000000000000000000000000000000" => "*".to_owned(),
                "00000000000000000000000001000000" => "::1".to_owned(),
                other => other.to_owned(),
            }
        } else {
            match u32::from_str_radix(address, 16) {
                // The kernel prints the address bytes as a host-order word.
                Ok(0) => "*".to_owned(),
                Ok(word) => std::net::Ipv4Addr::from(word.to_ne_bytes()).to_string(),
                Err(_) => continue,
            }
        };
        sockets.insert(inode, (host, port));
    }
    sockets
}

#[cfg(any(target_os = "macos", test))]
/// `lsof -F pcnPT` output: a `p` line starts a process (then `c` its
/// command), an `f` line a file, whose `P` (protocol), `n` (address) and
/// `T` (`ST=LISTEN`) lines follow.
pub fn parse_lsof(text: &str) -> Vec<Listener> {
    #[derive(Default)]
    struct File {
        protocol: Option<String>,
        name: Option<String>,
        state: Option<String>,
    }
    let mut listeners = std::collections::BTreeMap::new();
    let mut pid: Option<i32> = None;
    let mut command: Option<String> = None;
    let mut file = File::default();
    let flush =
        |file: &mut File,
         pid: Option<i32>,
         command: &Option<String>,
         listeners: &mut std::collections::BTreeMap<(i32, String, u16), Listener>| {
            let taken = std::mem::take(file);
            let (Some(pid), Some(name)) = (pid, taken.name) else {
                return;
            };
            if taken.protocol.as_deref() != Some("TCP") || taken.state.as_deref() != Some("LISTEN")
            {
                return;
            }
            if let Some((host, port)) = endpoint(&name) {
                listeners
                    .entry((pid, host.clone(), port))
                    .or_insert(Listener {
                        port,
                        host,
                        pid,
                        command: command.clone(),
                    });
            }
        };
    for line in text.lines() {
        let Some(field) = line.chars().next() else {
            continue;
        };
        let value = &line[field.len_utf8()..];
        match field {
            'p' => {
                flush(&mut file, pid, &command, &mut listeners);
                pid = value.parse().ok();
                command = None;
            }
            'c' => command = Some(value.to_owned()),
            'f' => flush(&mut file, pid, &command, &mut listeners),
            'P' => file.protocol = Some(value.to_owned()),
            'n' => file.name = Some(value.to_owned()),
            'T' => {
                if let Some(state) = value.strip_prefix("ST=") {
                    file.state = Some(state.to_owned());
                }
            }
            _ => {}
        }
    }
    flush(&mut file, pid, &command, &mut listeners);
    listeners.into_values().collect()
}

#[cfg(any(target_os = "macos", test))]
/// `127.0.0.1:3000`, `*:8080`, `[::1]:5173` → host and port.
fn endpoint(name: &str) -> Option<(String, u16)> {
    let local = name.split("->").next()?.trim();
    let (host, port) = local.rsplit_once(':')?;
    let port = port.parse().ok()?;
    let host = host.trim_start_matches('[').trim_end_matches(']');
    Some((
        if host.is_empty() {
            "*".to_owned()
        } else {
            host.to_owned()
        },
        port,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lsof_output_gives_the_listening_tcp_sockets_with_their_commands() {
        let text = "p100\ncnode\nf21\nPTCP\nn127.0.0.1:3000\nTST=LISTEN\nf22\nPTCP\nn[::1]:3000\nTST=LISTEN\n\
                    f23\nPTCP\nn127.0.0.1:3000->127.0.0.1:50000\nTST=ESTABLISHED\np200\ncpython3\nf4\nPTCP\nn*:8000\nTST=LISTEN\n\
                    f5\nPUDP\nn*:5353\n";
        assert_eq!(
            parse_lsof(text),
            vec![
                Listener {
                    port: 3000,
                    host: "127.0.0.1".into(),
                    pid: 100,
                    command: Some("node".into())
                },
                Listener {
                    port: 3000,
                    host: "::1".into(),
                    pid: 100,
                    command: Some("node".into())
                },
                Listener {
                    port: 8000,
                    host: "*".into(),
                    pid: 200,
                    command: Some("python3".into())
                },
            ]
        );
    }

    #[test]
    fn a_process_reports_the_ports_of_its_whole_tree_and_nothing_else() {
        // 10 → 11 → 12, and 20 beside them.
        let table = HashMap::from([(10, 1), (11, 10), (12, 11), (20, 1), (1, 0)]);
        let listener = |pid, port: u16| Listener {
            port,
            host: "127.0.0.1".into(),
            pid,
            command: None,
        };
        let report = build(
            &[10, 20, 99_999_999],
            &table,
            Ok(vec![
                listener(12, 5173),
                listener(11, 3000),
                listener(20, 8080),
            ]),
        );
        assert_eq!(report.version, FORMAT_VERSION);
        assert_eq!(report.processes[0].pid, 10);
        assert!(report.processes[0].alive);
        assert_eq!(
            report.processes[0].ports,
            vec![listener(11, 3000), listener(12, 5173)]
        );
        assert_eq!(report.processes[1].ports, vec![listener(20, 8080)]);
        // A pid that is gone: no ports, said so.
        assert!(!report.processes[2].alive);
        assert!(report.processes[2].ports.is_empty());
        let json = serde_json::to_value(&report).unwrap();
        assert_eq!(json["processes"][0]["ports"][0]["port"], 3000);
        assert!(json.get("error").is_none());
    }

    #[test]
    fn sockets_that_cannot_be_read_are_reported_once() {
        let report = build(
            &[std::process::id() as i32],
            &HashMap::new(),
            Err("lsof was not found".into()),
        );
        assert_eq!(report.error.as_deref(), Some("lsof was not found"));
        assert!(report.processes[0].alive);
        assert!(report.processes[0].ports.is_empty());
    }

    #[test]
    fn proc_net_tcp_gives_the_listening_sockets() {
        let text = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n   \
                    0: 0100007F:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 4242 1\n   \
                    1: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 4343 1\n   \
                    2: 0100007F:0BB8 0100007F:C350 01 00000000:00000000 00:00000000 00000000  1000        0 4444 1\n";
        let sockets = parse_proc_net_tcp(text, false);
        assert_eq!(sockets.get(&4242), Some(&("127.0.0.1".to_owned(), 3000)));
        assert_eq!(sockets.get(&4343), Some(&("*".to_owned(), 8080)));
        assert!(!sockets.contains_key(&4444));
    }

    #[test]
    fn this_process_reports_the_port_it_listens_on() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let pid = std::process::id() as i32;
        let report = report(&[pid]);
        if let Some(error) = &report.error {
            // A machine without lsof (a minimal Linux container has /proc).
            eprintln!("skipping: {error}");
            return;
        }
        assert!(report.processes[0].alive);
        assert!(
            report.processes[0]
                .ports
                .iter()
                .any(|found| found.port == port && found.pid == pid),
            "{report:?}"
        );
    }
}
