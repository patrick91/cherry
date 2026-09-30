//! A shell's two-line prompt through window resizes: the host's terminal
//! clears the prompt for the shell's redraw (OSC 133), so the screen shows
//! exactly one prompt, the output above it intact, and the window, painted
//! from the host's replacements, shows the same. Real zsh (macOS ships it
//! at /bin/zsh) with a private ZDOTDIR, never the user's startup files.
#![cfg(target_os = "macos")]
mod support;

use cherry_protocol::*;
use cherry_vt::Terminal;
use std::{fs, os::unix::net::UnixStream, path::Path, time::Duration};
use support::*;

/// The prompt's first line: wider than some of the windows below.
const TOP: &str = "PROMPT_TOP ~/github/patrick91/cherry on codex/persistent-sessions [!?] via rust";

/// How a prompt is marked. Cherry's zsh integration (cherry-integration.zsh
/// in ShellProcessController.swift) marks it once, before it, from precmd:
/// zsh's redraw after a resize writes no mark. Ghostty's own marks every
/// line of it in PS1, so every redraw marks it again.
const INTEGRATIONS: [(&str, &str); 2] = [
    (
        "cherry",
        r#"PROMPT=$'__TOP__\n❯ '
precmd() { print -n -- $'\e]133;D;'$?$'\a\e]133;A\a' }
preexec() { print -n -- $'\e]133;C\a' }
"#,
    ),
    (
        "ghostty",
        r#"PROMPT=$'%{\e]133;A;cl=line\a%}__TOP__\n%{\e]133;P;k=s\a%}❯ %{\e]133;B\a%}'
precmd() { print -n -- $'\e]133;D;'$?$'\a' }
preexec() { print -n -- $'\e]133;C\a' }
"#,
    ),
];

/// A window that shows the session's stream directly and takes the host's
/// replacements, as the attach adapter's does when its size is the grid's.
struct Window {
    terminal: Terminal,
    offset: u64,
}

impl Window {
    /// Apply what arrives until nothing has for `quiet`.
    fn settle(&mut self, socket: &mut UnixStream, quiet: Duration) {
        socket.set_read_timeout(Some(quiet)).unwrap();
        while let Ok(Some(message)) = read_frame::<_, ServerMessage>(socket) {
            match message {
                ServerMessage::Output { offset, data } => {
                    assert_eq!(offset, self.offset, "output out of sequence");
                    self.offset += data.len() as u64;
                    self.terminal.feed(&data);
                }
                ServerMessage::Attached {
                    session,
                    offset,
                    snapshot,
                    reason,
                    ..
                } => {
                    assert_eq!(reason, AttachReason::Resize);
                    if snapshot.starts_with(b"\x18\x1bc") {
                        self.terminal =
                            Terminal::new(session.cols, session.rows, 1024 * 1024).unwrap();
                    } else {
                        self.terminal.resize(session.cols, session.rows).unwrap();
                    }
                    self.terminal.feed(&snapshot);
                    self.offset = offset;
                }
                ServerMessage::Resized { offset, cols, rows } => {
                    assert_eq!(offset, self.offset);
                    self.terminal.resize(cols, rows).unwrap();
                }
                ServerMessage::Pong | ServerMessage::Query { .. } => {}
                other => panic!("unexpected message {other:?}"),
            }
        }
        socket.set_read_timeout(None).unwrap();
    }
}

/// The session's screen as a new client of `cols` × `rows` gets it.
fn host_screen(host: &Host, id: &str, cols: u16, rows: u16) -> Terminal {
    let (_socket, _, _, snapshot) = host.attach(id, cols, rows);
    let mut terminal = Terminal::new(cols, rows, 1024 * 1024).unwrap();
    terminal.feed(&snapshot);
    terminal
}

fn resize_through(integration: &str, script: &str, dir: &Path, sizes: &[u16], pause: Duration) {
    let host = Host::new();
    let zdotdir = dir.join(format!("{integration}-{}", pause.as_millis()));
    fs::create_dir_all(&zdotdir).unwrap();
    fs::write(
        zdotdir.join(".zshrc"),
        format!("print SHELL_STARTED\n{}", script.replace("__TOP__", TOP)),
    )
    .unwrap();
    let session = host.create(shell(&format!(
        "export TERM=xterm-256color LANG=en_US.UTF-8 ZDOTDIR='{}'; exec /bin/zsh -i",
        zdotdir.display()
    )));
    let (mut socket, info, offset, snapshot) = host.attach(&session.id, 100, 30);
    let mut window = Window {
        terminal: Terminal::new(info.cols, info.rows, 1024 * 1024).unwrap(),
        offset,
    };
    window.terminal.feed(&snapshot);
    for _ in 0..200 {
        window.settle(&mut socket, Duration::from_millis(100));
        if window.terminal.screen_text().unwrap().contains('❯') {
            break;
        }
    }
    assert!(
        window.terminal.screen_text().unwrap().contains('❯'),
        "no prompt"
    );
    input(&mut socket, b"echo hello\r");
    window.settle(&mut socket, Duration::from_millis(500));

    for &cols in sizes {
        send(
            &mut socket,
            &ClientMessage::Resize {
                cols,
                rows: 30,
                cell_width: None,
                cell_height: None,
            },
        );
        // The window takes its new size before the host's replacement.
        window.terminal.resize(cols, 30).unwrap();
        window.settle(&mut socket, pause);
    }
    window.settle(&mut socket, Duration::from_millis(1000));

    let last = *sizes.last().unwrap();
    let screen = host_screen(&host, &session.id, last, 30);
    let label = format!("{integration}, {} ms between resizes", pause.as_millis());
    // One prompt below the command and its output, which stay.
    assert_eq!(
        screen.screen_text().unwrap(),
        format!("SHELL_STARTED\n{TOP}\n❯ echo hello\nhello\n{TOP}\n❯"),
        "{label}: {:#?}",
        screen.inspect().unwrap().active
    );
    // The window shows the host's screen.
    assert_eq!(
        window.terminal.inspect().unwrap().active,
        screen.inspect().unwrap().active,
        "{label}"
    );
}

#[test]
fn a_two_line_zsh_prompt_stays_one_prompt_through_resizes() {
    let dir = tempfile::tempdir().unwrap();
    // Narrower and wider than its first line, which wraps and unwraps.
    let sizes = [70, 45, 90, 40, 100, 60, 50, 35, 120];
    for (integration, script) in INTEGRATIONS {
        // Settled between resizes, and a burst.
        for pause in [Duration::from_millis(300), Duration::from_millis(20)] {
            resize_through(integration, script, dir.path(), &sizes, pause);
        }
    }
}
