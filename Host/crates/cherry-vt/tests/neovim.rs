//! Real PTY acceptance test, opt-in because it requires `nvim` on PATH.
#![cfg(unix)]
use cherry_vt::Terminal;
use std::{
    fs::File,
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::process::CommandExt,
    },
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

struct Workload(Child);
impl Drop for Workload {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
#[ignore = "requires nvim on PATH; run cargo test -p cherry-vt --test neovim -- --ignored"]
fn reconnect_to_real_neovim_then_restore_the_shell_screen() {
    let (mut master_fd, mut slave_fd) = (-1, -1);
    let mut size = libc::winsize {
        ws_row: 24,
        ws_col: 80,
        ws_xpixel: 640,
        ws_ypixel: 384,
    };
    assert_eq!(
        unsafe {
            libc::openpty(
                &mut master_fd,
                &mut slave_fd,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::addr_of_mut!(size),
            )
        },
        0
    );
    let mut master = unsafe { File::from_raw_fd(master_fd) };
    let slave = unsafe { File::from_raw_fd(slave_fd) };
    unsafe {
        libc::fcntl(master_fd, libc::F_SETFD, libc::FD_CLOEXEC);
    }
    let mut command = Command::new("nvim");
    command
        .args([
            "-u",
            "NONE",
            "-i",
            "NONE",
            "-n",
            "--noplugin",
            "-c",
            "call setline(1, ['Cherry VT reconnect', 'second line'])",
        ])
        .env("TERM", "xterm-256color")
        .stdin(Stdio::from(slave.try_clone().unwrap()))
        .stdout(Stdio::from(slave.try_clone().unwrap()))
        .stderr(Stdio::from(slave.try_clone().unwrap()));
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(std::io::Error::last_os_error());
            }
            if libc::ioctl(0, libc::TIOCSCTTY as _, 0) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut workload = Workload(command.spawn().expect("nvim must be installed"));
    drop(slave);
    let mut original = Terminal::new(80, 24, 1024 * 1024).unwrap();
    // A renderer that follows the shell but misses Neovim's startup, and is
    // brought up to date with a refresh instead of a snapshot.
    let mut follower = Terminal::new(80, 24, 1024 * 1024).unwrap();
    // Retained history plus a cleared screen leaves the primary screen with
    // trailing blank rows under the editor.
    for line in 0..40 {
        let bytes = format!("output line {line}\r\n");
        original.feed(bytes.as_bytes());
        follower.feed(bytes.as_bytes());
    }
    original.feed(b"\x1b[H\x1b[2Jshell prompt> nvim\r\n");
    follower.feed(b"\x1b[H\x1b[2Jshell prompt> nvim\r\n");
    let history = follower.inspect().unwrap().history;
    let mut refreshed = false;
    let mut copy: Option<Terminal> = None;
    let mut quit_sent = false;
    let deadline = Instant::now() + Duration::from_secs(15);
    let mut quiet_since = Instant::now();
    let mut buffer = [0u8; 65536];
    while Instant::now() < deadline {
        let mut poll = libc::pollfd {
            fd: master.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        let ready = unsafe { libc::poll(&mut poll, 1, 20) };
        if ready > 0 {
            match master.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => {
                    let replies = original.feed(&buffer[..n]);
                    if !replies.is_empty() {
                        master.write_all(&replies).unwrap();
                    }
                    if let Some(copy) = copy.as_mut() {
                        copy.feed(&buffer[..n]);
                    }
                    if refreshed {
                        follower.feed(&buffer[..n]);
                    }
                    quiet_since = Instant::now();
                }
                Err(error) if error.raw_os_error() == Some(libc::EIO) => break,
                Err(error) => panic!("PTY read failed: {error}"),
            }
        }
        if !quit_sent
            && quiet_since.elapsed() > Duration::from_millis(150)
            && original
                .screen_text()
                .unwrap()
                .contains("Cherry VT reconnect")
        {
            let mut restored = Terminal::new(80, 24, 1024 * 1024).unwrap();
            restored.feed(&original.snapshot().unwrap());
            let editor = original.inspect().unwrap();
            assert!(editor.alternate);
            assert_eq!(editor, restored.inspect().unwrap());
            copy = Some(restored);
            follower.feed(&original.refresh().unwrap());
            let shown = follower.inspect().unwrap();
            assert_eq!(shown.active, editor.active);
            assert_eq!(shown.cursor, editor.cursor);
            assert_eq!(shown.modes, editor.modes);
            assert_eq!(shown.kitty_flags, editor.kitty_flags);
            refreshed = true;
            master.write_all(b"\x1b:qa!\r").unwrap();
            quit_sent = true;
        }
        if workload.0.try_wait().unwrap().is_some()
            && quiet_since.elapsed() > Duration::from_millis(100)
        {
            break;
        }
    }
    assert!(quit_sent, "Neovim did not render the test buffer in time");
    let copy = copy.unwrap();
    let shell = copy.inspect().unwrap();
    assert_eq!(original.inspect().unwrap(), shell);
    assert!(!shell.alternate);
    assert_eq!(shell.active[0], "shell prompt> nvim");
    assert_eq!(shell.history[0], "output line 0");
    // The follower's own history was left alone, and quitting showed the
    // primary screen the refresh painted under the editor.
    let followed = follower.inspect().unwrap();
    assert_eq!(followed.history, history);
    assert_eq!(followed.active, shell.active);
    assert_eq!(followed.cursor, shell.cursor);
    assert_eq!(followed.modes, shell.modes);
    // PTY EOF can precede waitpid observing the exiting process briefly.
    for _ in 0..50 {
        if workload.0.try_wait().unwrap().is_some() {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!("Neovim failed to exit");
}
