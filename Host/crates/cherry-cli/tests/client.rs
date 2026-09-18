use cherry_protocol::{
    read_frame, write_frame, ClientMessage, ServerMessage, SessionInfo, SessionState,
    PROTOCOL_VERSION,
};
use std::{
    fs::File,
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{
            fs::PermissionsExt,
            net::{UnixListener, UnixStream},
        },
    },
    process::{Child, Command, Stdio},
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};

fn session() -> SessionInfo {
    SessionInfo {
        id: "test-session".into(),
        name: "Example".into(),
        cwd: "/work".into(),
        command: vec!["/bin/sh".into()],
        cols: 120,
        rows: 32,
        state: SessionState::Running,
        pid: Some(42),
        exit_code: None,
        attached: true,
    }
}

fn listener() -> (tempfile::TempDir, UnixListener, Command) {
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("host.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    let mut command = Command::new(env!("CARGO_BIN_EXE_cherry"));
    command.args(["--socket", socket.to_str().unwrap()]);
    (directory, listener, command)
}

fn accept(listener: UnixListener) -> UnixStream {
    accept_with_capabilities(listener, &[])
}

fn accept_with_capabilities(listener: UnixListener, capabilities: &[&str]) -> UnixStream {
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut stream = loop {
        match listener.accept() {
            Ok((stream, _)) => break stream,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                assert!(Instant::now() < deadline, "client did not connect");
                thread::sleep(Duration::from_millis(10));
            }
            Err(error) => panic!("accept failed: {error}"),
        }
    };
    stream.set_nonblocking(false).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    assert!(matches!(
        read_frame(&mut stream).unwrap(),
        Some(ClientMessage::Hello {
            version: PROTOCOL_VERSION
        })
    ));
    write_frame(
        &mut stream,
        &ServerMessage::Welcome {
            version: PROTOCOL_VERSION,
            host_id: "host-1".into(),
            capabilities: capabilities.iter().map(|value| (*value).into()).collect(),
        },
    )
    .unwrap();
    stream
}

fn wait(child: &mut Child) -> std::process::ExitStatus {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("client did not exit within five seconds");
        }
        thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn list_json_has_host_identity_and_plain_session_descriptors() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_frame(&mut stream).unwrap(),
            Some(ClientMessage::List)
        ));
        write_frame(
            &mut stream,
            &ServerMessage::Sessions {
                host_id: "host-1".into(),
                sessions: vec![session()],
            },
        )
        .unwrap();
    });
    let result = command.args(["list", "--json"]).output().unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    let value: serde_json::Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(value["host_id"], "host-1");
    assert_eq!(value["sessions"][0]["attached"], true);
    server.join().unwrap();
}

#[test]
fn create_preserves_request_id_and_command_without_shell_interpolation() {
    let (_directory, listener, mut command) = listener();
    let request_id = "12345678-1234-4234-8234-123456789abc";
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        match read_frame(&mut stream).unwrap().unwrap() {
            ClientMessage::Create {
                request_id: id,
                cwd,
                command,
                ..
            } => {
                assert_eq!(id, request_id);
                assert_eq!(cwd, "/work/space ' literal");
                assert_eq!(command, ["printf", "%s", "$(not-a-shell)"]);
            }
            other => panic!("wrong request: {other:?}"),
        }
        write_frame(&mut stream, &ServerMessage::Created { session: session() }).unwrap();
    });
    let result = command
        .args([
            "new",
            "--cwd",
            "/work/space ' literal",
            "--name",
            "Example",
            "--request-id",
            request_id,
            "--json",
            "--",
            "printf",
            "%s",
            "$(not-a-shell)",
        ])
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    let value: serde_json::Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(value["id"], "test-session");
    assert!(
        value.get("session").is_none(),
        "new should return a plain descriptor"
    );
    server.join().unwrap();
}

#[test]
fn detach_escape_is_local_and_preserves_prior_input() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_frame(&mut stream).unwrap(),
            Some(ClientMessage::Attach {
                takeover: false,
                ..
            })
        ));
        write_frame(
            &mut stream,
            &ServerMessage::Attached {
                session: session(),
                offset: 42,
                snapshot: b"screen".to_vec(),
            },
        )
        .unwrap();
        // Input already contains the detach escape, so the client may close as
        // soon as Attached arrives. Sending unrelated output here races that
        // intentional close; this test verifies the exact incoming messages.
        assert!(
            matches!(read_frame(&mut stream).unwrap(), Some(ClientMessage::Input { data }) if data == b"hello")
        );
        assert!(matches!(
            read_frame(&mut stream).unwrap(),
            Some(ClientMessage::Detach)
        ));
    });
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(b"hello\x1dnot-sent")
        .unwrap();
    assert!(wait(&mut child).success());
    let mut output = Vec::new();
    child
        .stdout
        .take()
        .unwrap()
        .read_to_end(&mut output)
        .unwrap();
    assert!(output.starts_with(b"screen"));
    server.join().unwrap();
}

#[test]
fn takeover_is_explicit_and_requires_host_capability() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept_with_capabilities(listener, &["attach_takeover"]);
        assert!(matches!(
            read_frame(&mut stream).unwrap(),
            Some(ClientMessage::Attach { id, takeover: true, .. }) if id == "test-session"
        ));
        write_frame(
            &mut stream,
            &ServerMessage::Attached {
                session: session(),
                offset: 42,
                snapshot: b"restored screen".to_vec(),
            },
        )
        .unwrap();
        assert!(matches!(
            read_frame(&mut stream).unwrap(),
            Some(ClientMessage::Detach)
        ));
    });
    let result = command
        .args(["attach", "test-session", "--takeover"])
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(result.stdout.starts_with(b"restored screen"));
    server.join().unwrap();
}

#[test]
fn takeover_against_old_host_exits_before_sending_attach() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(read_frame::<_, ClientMessage>(&mut stream)
            .unwrap()
            .is_none());
    });
    let result = command
        .args(["attach", "--takeover", "test-session"])
        .output()
        .unwrap();
    assert!(!result.status.success());
    let error = String::from_utf8_lossy(&result.stderr);
    assert!(error.contains("does not support taking over"), "{error}");
    assert!(error.contains("update cherry-host"), "{error}");
    assert!(
        error.contains("disconnect its current controller"),
        "{error}"
    );
    server.join().unwrap();
}

#[test]
fn shared_resize_replaces_canonical_state_and_continues_at_the_new_offset() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept_with_capabilities(listener, &["multi_attach"]);
        assert!(matches!(
            read_frame(&mut stream).unwrap(),
            Some(ClientMessage::Attach {
                takeover: false,
                ..
            })
        ));
        let mut descriptor = session();
        descriptor.cols = 80;
        descriptor.rows = 24;
        write_frame(
            &mut stream,
            &ServerMessage::Attached {
                session: descriptor.clone(),
                offset: 0,
                snapshot: b"\x1bcPREVIOUS".to_vec(),
            },
        )
        .unwrap();
        write_frame(
            &mut stream,
            &ServerMessage::Output {
                offset: 0,
                data: b"-output".to_vec(),
            },
        )
        .unwrap();
        descriptor.cols = 60;
        descriptor.rows = 15;
        write_frame(
            &mut stream,
            &ServerMessage::Attached {
                session: descriptor,
                offset: 7,
                snapshot: b"\x1bcRESIZED".to_vec(),
            },
        )
        .unwrap();
        write_frame(
            &mut stream,
            &ServerMessage::Output {
                offset: 7,
                data: b"-continued".to_vec(),
            },
        )
        .unwrap();
        write_frame(
            &mut stream,
            &ServerMessage::Exit {
                id: "test-session".into(),
                exit_code: 0,
            },
        )
        .unwrap();
    });
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    assert!(wait(&mut child).success());
    let mut output = Vec::new();
    child
        .stdout
        .take()
        .unwrap()
        .read_to_end(&mut output)
        .unwrap();
    let mut screen = cherry_vt::Terminal::new(80, 24, 1024 * 1024).unwrap();
    screen.feed(&output);
    let text = screen.screen_text().unwrap();
    assert!(text.contains("RESIZED-continued"), "{text:?}");
    assert!(!text.contains("PREVIOUS"), "{text:?}");
    server.join().unwrap();
}

#[test]
fn out_of_sequence_output_fails_without_sending_any_input() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_frame(&mut stream).unwrap(),
            Some(ClientMessage::Attach { .. })
        ));
        write_frame(
            &mut stream,
            &ServerMessage::Attached {
                session: session(),
                offset: 42,
                snapshot: vec![],
            },
        )
        .unwrap();
        write_frame(
            &mut stream,
            &ServerMessage::Output {
                offset: 43,
                data: b"lost".to_vec(),
            },
        )
        .unwrap();
        assert!(read_frame::<_, ClientMessage>(&mut stream)
            .unwrap()
            .is_none());
    });
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    assert!(!wait(&mut child).success());
    let mut error = String::new();
    child
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut error)
        .unwrap();
    assert!(error.contains("out of sequence"), "{error}");
    server.join().unwrap();
}

struct Pty {
    master: File,
    slave: File,
}
impl Pty {
    fn open() -> Self {
        let (mut master, mut slave) = (-1, -1);
        let mut size = libc::winsize {
            ws_row: 24,
            ws_col: 80,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        assert_eq!(
            unsafe {
                libc::openpty(
                    &mut master,
                    &mut slave,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::addr_of_mut!(size),
                )
            },
            0
        );
        Self {
            master: unsafe { File::from_raw_fd(master) },
            slave: unsafe { File::from_raw_fd(slave) },
        }
    }
    fn termios(&self) -> libc::termios {
        let mut mode = unsafe { std::mem::zeroed() };
        assert_eq!(
            unsafe { libc::tcgetattr(self.slave.as_raw_fd(), &mut mode) },
            0
        );
        mode
    }
}

#[test]
fn controller_replacement_restores_terminal_mode_and_reports_the_handoff() {
    let (_directory, listener, mut command) = listener();
    let (replace_tx, replace_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let mut stream = accept_with_capabilities(listener, &["attach_takeover"]);
        assert!(matches!(
            read_frame(&mut stream).unwrap(),
            Some(ClientMessage::Attach {
                takeover: false,
                ..
            })
        ));
        write_frame(
            &mut stream,
            &ServerMessage::Attached {
                session: session(),
                offset: 0,
                snapshot: b"ready".to_vec(),
            },
        )
        .unwrap();
        replace_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        write_frame(
            &mut stream,
            &ServerMessage::Error {
                code: "taken_over".into(),
                message: "Another device took over this session. The session is still running."
                    .into(),
            },
        )
        .unwrap();
        assert!(read_frame::<_, ClientMessage>(&mut stream)
            .unwrap()
            .is_none());
    });
    let pty = Pty::open();
    let original = pty.termios();
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while pty.termios().c_lflag & libc::ICANON != 0 {
        assert!(Instant::now() < deadline, "client did not enter raw mode");
        thread::sleep(Duration::from_millis(10));
    }
    replace_tx.send(()).unwrap();
    assert!(!wait(&mut child).success());
    let restored = pty.termios();
    assert_eq!(
        restored.c_lflag & !libc::PENDIN,
        original.c_lflag & !libc::PENDIN
    );
    assert_eq!(restored.c_iflag, original.c_iflag);
    assert_eq!(restored.c_oflag, original.c_oflag);
    assert_eq!(restored.c_cflag, original.c_cflag);
    assert_eq!(restored.c_cc, original.c_cc);
    let mut error = String::new();
    child
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut error)
        .unwrap();
    assert!(
        error.contains("Another device took over this session"),
        "{error}"
    );
    assert!(error.contains("still running"), "{error}");
    server.join().unwrap();
}

#[test]
fn real_pty_forwards_resize_and_control_c_and_restores_mode_on_sigterm() {
    let (_directory, listener, mut command) = listener();
    let (input_tx, input_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_frame(&mut stream).unwrap(),
            Some(ClientMessage::Attach {
                cols: 80,
                rows: 24,
                ..
            })
        ));
        write_frame(
            &mut stream,
            &ServerMessage::Attached {
                session: session(),
                offset: 0,
                snapshot: b"ready".to_vec(),
            },
        )
        .unwrap();
        assert!(matches!(
            read_frame(&mut stream).unwrap(),
            Some(ClientMessage::Resize {
                cols: 101,
                rows: 41
            })
        ));
        assert!(
            matches!(read_frame(&mut stream).unwrap(), Some(ClientMessage::Input { data }) if data == [3])
        );
        input_tx.send(()).unwrap();
        assert!(read_frame::<_, ClientMessage>(&mut stream)
            .unwrap()
            .is_none());
    });
    let mut pty = Pty::open();
    let original = pty.termios();
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while pty.termios().c_lflag & libc::ICANON != 0 {
        assert!(Instant::now() < deadline, "client did not enter raw mode");
        thread::sleep(Duration::from_millis(10));
    }
    let size = libc::winsize {
        ws_row: 41,
        ws_col: 101,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    assert_eq!(
        unsafe { libc::ioctl(pty.slave.as_raw_fd(), libc::TIOCSWINSZ, &size) },
        0
    );
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGWINCH) }, 0);
    // Leave enough time for SIGWINCH to be handled before enqueueing input.
    thread::sleep(Duration::from_millis(150));
    pty.master.write_all(&[3]).unwrap();
    input_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGTERM) }, 0);
    assert_eq!(wait(&mut child).code(), Some(128 + libc::SIGTERM));
    let restored = pty.termios();
    assert_eq!(
        restored.c_lflag & !libc::PENDIN,
        original.c_lflag & !libc::PENDIN
    );
    assert_eq!(restored.c_iflag, original.c_iflag);
    assert_eq!(restored.c_oflag, original.c_oflag);
    assert_eq!(restored.c_cflag, original.c_cflag);
    assert_eq!(restored.c_cc, original.c_cc);
    server.join().unwrap();
}

#[test]
fn ssh_metadata_uses_batch_auth_and_one_quoted_gateway_command() {
    let directory = tempfile::tempdir().unwrap();
    let ssh = directory.path().join("ssh");
    let log = directory.path().join("arguments");
    std::fs::write(
        &ssh,
        "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$CHERRY_TEST_SSH_LOG\"\nexit 1\n",
    )
    .unwrap();
    std::fs::set_permissions(&ssh, std::fs::Permissions::from_mode(0o700)).unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_cherry"))
        .args([
            "--host",
            "user@studio",
            "--socket",
            "/tmp/a'b; $(literal)",
            "list",
            "--json",
        ])
        .env("PATH", directory.path())
        .env("CHERRY_TEST_SSH_LOG", &log)
        .output()
        .unwrap();
    assert!(!output.status.success());
    let arguments = std::fs::read_to_string(log).unwrap();
    assert_eq!(arguments, "-T\n-o\nBatchMode=yes\n-o\nConnectTimeout=10\n--\nuser@studio\ncherry-host gateway --socket '/tmp/a'\\''b; $(literal)'\n");
}

#[test]
fn terminating_cli_reaps_its_ssh_process_within_a_bounded_time() {
    let directory = tempfile::tempdir().unwrap();
    let ssh = directory.path().join("ssh");
    let pid_file = directory.path().join("ssh.pid");
    std::fs::write(
        &ssh,
        "#!/bin/sh\nprintf '%s' \"$$\" > \"$CHERRY_TEST_SSH_PID\"\nexec /bin/sleep 30\n",
    )
    .unwrap();
    std::fs::set_permissions(&ssh, std::fs::Permissions::from_mode(0o700)).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_cherry"))
        .args(["--host", "studio", "list", "--json"])
        .env("PATH", directory.path())
        .env("CHERRY_TEST_SSH_PID", &pid_file)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    let ssh_pid = loop {
        if let Ok(pid) = std::fs::read_to_string(&pid_file) {
            if let Ok(pid) = pid.parse::<i32>() {
                break pid;
            }
        }
        assert!(Instant::now() < deadline, "SSH did not start");
        thread::sleep(Duration::from_millis(10));
    };
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGTERM) }, 0);
    assert_eq!(wait(&mut child).code(), Some(128 + libc::SIGTERM));
    assert_eq!(
        unsafe { libc::kill(ssh_pid, 0) },
        -1,
        "SSH child leaked after CLI termination"
    );
    assert_eq!(
        std::io::Error::last_os_error().raw_os_error(),
        Some(libc::ESRCH)
    );
}

#[test]
fn pinned_host_mismatch_stops_before_sending_a_mutation() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(
            read_frame::<_, ClientMessage>(&mut stream)
                .unwrap()
                .is_none(),
            "client sent a request to the wrong host"
        );
    });
    let output = command
        .args([
            "--expected-host-id",
            "12345678-1234-4234-8234-123456789abc",
            "kill",
            "test-session",
        ])
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("host identity changed"));
    server.join().unwrap();
}

#[test]
fn remove_dispatches_a_retained_session_removal_request() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(
            matches!(read_frame(&mut stream).unwrap(), Some(ClientMessage::Remove { id }) if id == "test-session")
        );
        write_frame(&mut stream, &ServerMessage::Ok).unwrap();
    });
    let output = command.args(["remove", "test-session"]).output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    server.join().unwrap();
}

#[test]
fn shutdown_dispatches_the_host_maintenance_request() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_frame(&mut stream).unwrap(),
            Some(ClientMessage::Shutdown)
        ));
        write_frame(&mut stream, &ServerMessage::Ok).unwrap();
    });
    let output = command.arg("shutdown").output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    server.join().unwrap();
}

#[test]
fn enhanced_detach_key_split_across_reads_is_never_forwarded() {
    for encoding in [b"\x1b[93;5u".as_slice(), b"\x1b[27;5;93~"] {
        let (_directory, listener, mut command) = listener();
        let server = thread::spawn(move || {
            let mut stream = accept(listener);
            assert!(matches!(
                read_frame(&mut stream).unwrap(),
                Some(ClientMessage::Attach { .. })
            ));
            write_frame(
                &mut stream,
                &ServerMessage::Attached {
                    session: session(),
                    offset: 0,
                    snapshot: vec![],
                },
            )
            .unwrap();
            assert!(matches!(
                read_frame(&mut stream).unwrap(),
                Some(ClientMessage::Detach)
            ));
        });
        let mut child = command
            .args(["attach", "test-session"])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let split = 4;
        child
            .stdin
            .as_mut()
            .unwrap()
            .write_all(&encoding[..split])
            .unwrap();
        thread::sleep(Duration::from_millis(2));
        child
            .stdin
            .as_mut()
            .unwrap()
            .write_all(&encoding[split..])
            .unwrap();
        assert!(wait(&mut child).success());
        server.join().unwrap();
    }
}

#[test]
fn eof_forwards_an_unfinished_key_sequence_before_detaching() {
    let (_directory, listener, mut command) = listener();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_frame(&mut stream).unwrap(),
            Some(ClientMessage::Attach { .. })
        ));
        write_frame(
            &mut stream,
            &ServerMessage::Attached {
                session: session(),
                offset: 0,
                snapshot: vec![],
            },
        )
        .unwrap();
        assert!(
            matches!(read_frame(&mut stream).unwrap(), Some(ClientMessage::Input { data }) if data == b"\x1b[93;")
        );
        assert!(matches!(
            read_frame(&mut stream).unwrap(),
            Some(ClientMessage::Detach)
        ));
    });
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(b"\x1b[93;").unwrap();
    drop(stdin);
    assert!(wait(&mut child).success());
    server.join().unwrap();
}

#[test]
fn stalled_stdout_still_handles_sigterm_and_restores_tty_and_pipe_flags() {
    let (_directory, listener, mut command) = listener();
    let (ready_tx, ready_rx) = mpsc::channel();
    let (proceed_tx, proceed_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_frame(&mut stream).unwrap(),
            Some(ClientMessage::Attach { .. })
        ));
        ready_tx.send(()).unwrap();
        proceed_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        write_frame(
            &mut stream,
            &ServerMessage::Attached {
                session: session(),
                offset: 0,
                snapshot: vec![b'x'; 262_144],
            },
        )
        .unwrap();
        assert!(read_frame::<_, ClientMessage>(&mut stream)
            .unwrap()
            .is_none());
    });
    let pty = Pty::open();
    let original = pty.termios();
    let mut descriptors = [-1; 2];
    assert_eq!(unsafe { libc::pipe(descriptors.as_mut_ptr()) }, 0);
    for fd in descriptors {
        assert_eq!(
            unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) },
            0
        );
    }
    let _reader = unsafe { File::from_raw_fd(descriptors[0]) };
    let mut writer = unsafe { File::from_raw_fd(descriptors[1]) };
    // Darwin adds a kernel bookkeeping flag on the first successful write.
    // Prime that independently, so equality checks only this client's changes.
    writer.write_all(b"x").unwrap();
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(writer.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    ready_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    // Snapshot before TerminalOutput changes the descriptor flags.
    let flags = unsafe { libc::fcntl(writer.as_raw_fd(), libc::F_GETFL) };
    proceed_tx.send(()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while pty.termios().c_lflag & libc::ICANON != 0 {
        assert!(Instant::now() < deadline, "client did not enter raw mode");
        thread::sleep(Duration::from_millis(10));
    }
    // Never consume stdout. The snapshot is larger than the pipe's capacity.
    thread::sleep(Duration::from_millis(50));
    let signalled = Instant::now();
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGTERM) }, 0);
    assert_eq!(wait(&mut child).code(), Some(128 + libc::SIGTERM));
    assert!(
        signalled.elapsed() < Duration::from_secs(2),
        "signal cleanup waited for stdout to drain"
    );
    assert_eq!(
        pty.termios().c_lflag & !libc::PENDIN,
        original.c_lflag & !libc::PENDIN
    );
    assert_eq!(
        unsafe { libc::fcntl(writer.as_raw_fd(), libc::F_GETFL) },
        flags,
        "pipe flags leaked to the invoking process"
    );
    server.join().unwrap();
}

#[test]
fn redirected_regular_file_preserves_append_mode_and_has_no_screen_cleanup() {
    let (directory, listener, mut command) = listener();
    let file_path = directory.path().join("output");
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&file_path)
        .unwrap();
    file.write_all(b"existing:").unwrap();
    let (ready_tx, ready_rx) = mpsc::channel();
    let (proceed_tx, proceed_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_frame(&mut stream).unwrap(),
            Some(ClientMessage::Attach { .. })
        ));
        ready_tx.send(()).unwrap();
        proceed_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        write_frame(
            &mut stream,
            &ServerMessage::Attached {
                session: session(),
                offset: 0,
                snapshot: b"snapshot".to_vec(),
            },
        )
        .unwrap();
        assert!(matches!(
            read_frame(&mut stream).unwrap(),
            Some(ClientMessage::Detach)
        ));
    });
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(Stdio::null())
        .stdout(file.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    ready_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let flags = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFL) };
    proceed_tx.send(()).unwrap();
    assert!(wait(&mut child).success());
    assert_eq!(std::fs::read(&file_path).unwrap(), b"existing:snapshot");
    assert_eq!(
        unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFL) },
        flags
    );
    server.join().unwrap();
}

#[test]
fn detaching_a_tui_resets_keyboard_cursor_and_focus_reporting_modes() {
    let (_directory, listener, mut command) = listener();
    let enabled_modes = b"\x1b[>1u\x1b[>4;2m\x1b[?1h\x1b=\x1b[?1004h";
    let (ready_tx, ready_rx) = mpsc::channel();
    let (proceed_tx, proceed_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let mut stream = accept(listener);
        assert!(matches!(
            read_frame(&mut stream).unwrap(),
            Some(ClientMessage::Attach { .. })
        ));
        ready_tx.send(()).unwrap();
        proceed_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        write_frame(
            &mut stream,
            &ServerMessage::Attached {
                session: session(),
                offset: 0,
                snapshot: enabled_modes.to_vec(),
            },
        )
        .unwrap();
        assert!(matches!(
            read_frame(&mut stream).unwrap(),
            Some(ClientMessage::Detach)
        ));
    });
    let mut pty = Pty::open();
    pty.slave.write_all(b"x").unwrap();
    pty.master.read_exact(&mut [0u8; 1]).unwrap();
    let mut child = command
        .args(["attach", "test-session"])
        .stdin(pty.slave.try_clone().unwrap())
        .stdout(pty.slave.try_clone().unwrap())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    ready_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let original_flags = unsafe { libc::fcntl(pty.slave.as_raw_fd(), libc::F_GETFL) };
    proceed_tx.send(()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while pty.termios().c_lflag & libc::ICANON != 0 {
        assert!(Instant::now() < deadline, "client did not enter raw mode");
        thread::sleep(Duration::from_millis(10));
    }
    pty.master.write_all(&[0x1d]).unwrap();
    assert!(wait(&mut child).success());
    assert_eq!(
        unsafe { libc::fcntl(pty.slave.as_raw_fd(), libc::F_GETFL) },
        original_flags
    );
    let master_flags = unsafe { libc::fcntl(pty.master.as_raw_fd(), libc::F_GETFL) };
    assert_eq!(
        unsafe {
            libc::fcntl(
                pty.master.as_raw_fd(),
                libc::F_SETFL,
                master_flags | libc::O_NONBLOCK,
            )
        },
        0
    );
    let mut received = Vec::new();
    let mut buffer = [0u8; 1024];
    loop {
        match pty.master.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => received.extend_from_slice(&buffer[..n]),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
            Err(error) => panic!("reading terminal cleanup: {error}"),
        }
    }
    assert!(received.starts_with(enabled_modes));
    let cleanup = &received[enabled_modes.len()..];
    for reset in [
        b"\x1b[=0u".as_slice(),
        b"\x1b[>4;0m",
        b"\x1b[?1l",
        b"\x1b>",
        b"\x1b[?1004l",
        b"\x1b[?1049l",
    ] {
        assert!(
            cleanup.windows(reset.len()).any(|bytes| bytes == reset),
            "missing terminal mode reset {reset:?}"
        );
    }
    server.join().unwrap();
}
