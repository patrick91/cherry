use super::*;
use std::{
    ffi::CString,
    fs,
    os::unix::fs::symlink,
    sync::atomic::{AtomicU32, Ordering},
    time::Duration,
};

fn b64(bytes: &[u8]) -> String {
    String::from_utf8(cherry_vt::base64(bytes)).unwrap()
}

/// A graphics command whose payload is `path` in base64.
fn command(control: &str, path: impl AsRef<[u8]>) -> Vec<u8> {
    format!("\x1b_G{control};{}\x1b\\", b64(path.as_ref())).into_bytes()
}

fn path_bytes(path: &Path) -> &[u8] {
    path.as_os_str().as_bytes()
}

/// Pseudo-random bytes.
fn noise(len: usize, seed: u32) -> Vec<u8> {
    let mut state = seed | 1;
    (0..len)
        .map(|_| {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            state as u8
        })
        .collect()
}

/// A media layer whose temporary files are those under `temporary`.
fn media(temporary: &[&Path]) -> Media {
    Media::new(Places::only(
        temporary.iter().map(|dir| dir.to_path_buf()).collect(),
    ))
    .unwrap()
}

/// Feed `bytes` `step` bytes at a time, as reads of the PTY, and let every
/// read finish: what went on, and the replies to refused commands.
fn run(media: &mut Media, bytes: &[u8], step: usize) -> (Vec<u8>, Vec<Vec<u8>>) {
    let mut out = Vec::new();
    let mut replies = Vec::new();
    for piece in bytes.chunks(step.max(1)) {
        media.feed(piece, &mut |bytes: &[u8]| out.extend_from_slice(bytes));
        drain(media, &mut out, &mut replies);
    }
    (out, replies)
}

fn drain(media: &mut Media, out: &mut Vec<u8>, replies: &mut Vec<Vec<u8>>) {
    while media.holds_output() {
        media.wait(Instant::now() + Duration::from_secs(10));
        if let Some(reply) = media.finish(Instant::now()) {
            replies.push(reply);
        }
        media.resume(1000, &mut |bytes: &[u8]| out.extend_from_slice(bytes));
    }
}

/// The data of a direct transmission's chunks, and each chunk's control
/// data.
fn transmitted(out: &[u8]) -> (Vec<String>, Vec<u8>) {
    let text = String::from_utf8_lossy(out).into_owned();
    let mut controls = Vec::new();
    let mut payload = Vec::new();
    for command in text.split("\x1b_G").skip(1) {
        let command = command.split("\x1b\\").next().unwrap();
        let (control, data) = command.split_once(';').unwrap_or((command, ""));
        controls.push(control.to_owned());
        payload.extend_from_slice(data.as_bytes());
    }
    (controls, decode_base64(&payload).unwrap())
}

#[test]
fn output_without_media_commands_goes_on_unchanged_however_it_is_read() {
    let mut stream = Vec::new();
    stream.extend_from_slice(b"text \x1b[1;31mred\x1b[m\x1b]2;title\x07");
    // Direct transmissions, a placement, a delete, an APC of another
    // kind, `ESC ESC _ G`, a graphics command abandoned by ESC and one
    // aborted by CAN, a file medium on a command that carries no data,
    // and a lone ESC.
    stream.extend_from_slice(b"\x1b_Ga=T,f=24,s=1,v=1,i=7;AQID\x1b\\");
    stream.extend_from_slice(b"\x1b_Ga=t,t=d,i=8,m=1;AAAA\x1b\\\x1b_Gm=0;AAAA\x1b\\");
    stream.extend_from_slice(b"\x1b_Ga=p,i=7,t=f\x1b\\\x1b_Ga=d,d=a\x1b\\");
    stream.extend_from_slice(b"\x1b_Xnot graphics\x1b\\\x1b\x1b_Ga=d\x1b\\");
    stream.extend_from_slice(b"\x1b_Ga=t,t=f;lost\x1b[31m\x1b_Ga=T,t=f;x\x18y");
    stream.extend_from_slice(b"\x1b\x1b[0m\xe2\x82\xacend");
    // Commands far too long to be read for, of either kind.
    for control in [&b"a=t,f=100;"[..], b"a=t,t=f;"] {
        stream.extend_from_slice(b"\x1b_G");
        stream.extend_from_slice(control);
        stream.extend(std::iter::repeat_n(b'A', MAX_COMMAND + 10));
        stream.extend_from_slice(b"\x1b\\ok");
    }
    for step in [1, 2, 3, 7, 64, 4096, stream.len()] {
        let mut media = media(&[]);
        let (out, replies) = run(&mut media, &stream, step);
        assert!(out == stream, "split every {step} bytes");
        assert!(replies.is_empty());
        assert!(!media.holds_output());
    }
}

#[test]
fn a_file_transmission_becomes_a_direct_one_in_chunks() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("image.png");
    let data = noise(10_000, 3);
    fs::write(&file, &data).unwrap();
    let cmd = command("a=T,f=100,t=f,i=5,q=1,c=4", path_bytes(&file));
    let stream = [&b"before\r\n"[..], &cmd, b"after\x1b[6n"].concat();
    let expected = [
        &b"before\r\n"[..],
        &direct(b"a=T,f=100,t=f,i=5,q=1,c=4", &data),
        b"after\x1b[6n",
    ]
    .concat();
    for step in [1, 5, 13, 100, stream.len()] {
        let mut media = media(&[]);
        let (out, replies) = run(&mut media, &stream, step);
        assert!(out == expected, "split every {step} bytes");
        assert!(replies.is_empty());
    }
    let chunks = direct(b"a=T,f=100,t=f,i=5,q=1,c=4", &data);
    let (controls, payload) = transmitted(&chunks);
    assert_eq!(
        controls,
        ["a=T,f=100,i=5,q=1,c=4,m=1", "m=1,q=1", "m=1,q=1", "m=0,q=1"]
    );
    assert_eq!(payload, data);
    // Each chunk carries 4096 bytes of base64 but the last.
    let text = String::from_utf8(chunks).unwrap();
    let sizes: Vec<usize> = text
        .split("\x1b\\")
        .filter(|command| !command.is_empty())
        .map(|command| command.split_once(';').unwrap().1.len())
        .collect();
    assert_eq!(sizes[..3], [4096, 4096, 4096]);
    // A command with no action transmits; a small one is one command.
    assert_eq!(
        direct(b"t=f,f=24,s=1,v=1", &[1, 2, 3]),
        b"\x1b_Ga=t,f=24,s=1,v=1;AQID\x1b\\"
    );
    assert_eq!(direct(b"t=f", &[]), b"\x1b_Ga=t;\x1b\\");
    // A query goes in one command, however long.
    let query = direct(b"a=q,t=t,i=31", &data);
    assert_eq!(query.windows(3).filter(|w| *w == b"\x1b_G").count(), 1);
    assert!(query.starts_with(b"\x1b_Ga=q,i=31;"));
}

#[test]
fn offset_and_size_pick_the_bytes_read() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("data");
    let data = noise(100, 5);
    fs::write(&file, &data).unwrap();
    let path = path_bytes(&file);
    let read_with = |control: &str| {
        let mut media = media(&[]);
        let (out, replies) = run(&mut media, &command(control, path), 4096);
        (transmitted(&out).1, replies)
    };
    assert_eq!(read_with("t=f,i=1,O=10,S=20").0, &data[10..30]);
    assert_eq!(read_with("t=f,i=1,O=90").0, &data[90..]);
    assert_eq!(read_with("t=f,i=1,O=100").0, b"");
    for (control, code) in [
        ("t=f,i=1,S=101", "EINVAL"),
        ("t=f,i=1,O=50,S=51", "EINVAL"),
        ("t=f,i=1,O=101", "EINVAL"),
        ("t=f,i=1,O=x", "EINVAL"),
    ] {
        let (_, replies) = read_with(control);
        assert_eq!(replies.len(), 1, "{control}");
        let reply = String::from_utf8_lossy(&replies[0]).into_owned();
        assert!(
            reply.starts_with(&format!("\x1b_Gi=1;{code}: ")),
            "{control}: {reply:?}"
        );
    }
}

#[test]
fn a_temporary_file_is_read_only_where_it_may_be_and_deleted() {
    let temporary = tempfile::tempdir().unwrap();
    let elsewhere = tempfile::tempdir().unwrap();
    let data = noise(300, 7);
    let mut media = media(&[temporary.path()]);
    let mut send = |control: &str, path: &Path| {
        let (out, replies) = run(&mut media, &command(control, path_bytes(path)), 4096);
        (
            out,
            replies
                .into_iter()
                .map(|r| String::from_utf8(r).unwrap())
                .collect::<Vec<_>>(),
        )
    };

    let file = temporary.path().join("tty-graphics-protocol-1.rgba");
    fs::write(&file, &data).unwrap();
    let (out, replies) = send("a=t,t=t,i=2", &file);
    assert!(replies.is_empty(), "{replies:?}");
    assert_eq!(transmitted(&out).1, data);
    assert!(!file.exists(), "a temporary file is deleted once read");

    // Deleted too when the read is refused once the file is known to be
    // the program's to hand over.
    fs::write(&file, &data).unwrap();
    let (out, replies) = send("a=t,t=t,i=2,S=999", &file);
    assert!(out.is_empty());
    assert!(replies[0].starts_with("\x1b_Gi=2;EINVAL: "), "{replies:?}");
    assert!(!file.exists());

    // Not in a temporary directory, or not named for the protocol: refused
    // and left alone.
    let outside = elsewhere.path().join("tty-graphics-protocol-2.rgba");
    fs::write(&outside, &data).unwrap();
    let (out, replies) = send("a=t,t=t,i=2", &outside);
    assert!(out.is_empty());
    assert!(
        replies[0].contains("not in a temporary directory"),
        "{replies:?}"
    );
    assert!(outside.exists());
    let unnamed = temporary.path().join("image.rgba");
    fs::write(&unnamed, &data).unwrap();
    let (_, replies) = send("a=t,t=t,i=2", &unnamed);
    assert!(replies[0].contains("not named correctly"), "{replies:?}");
    assert!(unnamed.exists());

    // A symbolic link, even to a file in the temporary directory: refused,
    // and neither it nor its target deleted.
    let target = temporary.path().join("tty-graphics-protocol-target");
    fs::write(&target, &data).unwrap();
    let link = temporary.path().join("tty-graphics-protocol-link");
    symlink(&target, &link).unwrap();
    let (out, replies) = send("a=t,t=t,i=2", &link);
    assert!(out.is_empty());
    assert!(replies[0].starts_with("\x1b_Gi=2;ELOOP: "), "{replies:?}");
    assert!(link.symlink_metadata().is_ok() && target.exists());

    // A directory named for the protocol is found through its canonical
    // path, and the mark may be in the directory's name.
    let inner = temporary.path().join("tty-graphics-protocol-dir");
    fs::create_dir(&inner).unwrap();
    let file = inner.join("x");
    fs::write(&file, &data).unwrap();
    let (out, replies) = send(
        "a=t,t=t,i=2",
        &inner.join("..").join("tty-graphics-protocol-dir/x"),
    );
    assert!(replies.is_empty(), "{replies:?}");
    assert_eq!(transmitted(&out).1, data);
    assert!(!file.exists());
}

#[test]
fn only_regular_files_are_read_and_others_are_never_opened() {
    let dir = tempfile::tempdir().unwrap();
    let data = noise(50, 9);
    let regular = dir.path().join("regular");
    fs::write(&regular, &data).unwrap();
    // A FIFO would block an open (no writer comes) and a read.
    let fifo = dir.path().join("fifo");
    let name = CString::new(fifo.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    let to_fifo = dir.path().join("to-fifo");
    symlink(&fifo, &to_fifo).unwrap();
    let to_regular = dir.path().join("to-regular");
    symlink(&regular, &to_regular).unwrap();
    let to_null = dir.path().join("to-null");
    symlink("/dev/null", &to_null).unwrap();
    let mut media = media(&[]);
    let mut send = |path: &Path| {
        let started = Instant::now();
        let (out, replies) = run(&mut media, &command("a=t,t=f,i=3", path_bytes(path)), 4096);
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "{path:?} blocked"
        );
        (
            out,
            replies
                .into_iter()
                .map(|r| String::from_utf8(r).unwrap())
                .collect::<Vec<_>>(),
        )
    };
    for refused in [
        fifo.as_path(),
        &to_fifo,
        Path::new("/dev/null"),
        &to_null,
        Path::new("/dev/zero"),
        dir.path(),
    ] {
        let (out, replies) = send(refused);
        assert!(out.is_empty(), "{refused:?}");
        assert_eq!(replies.len(), 1, "{refused:?}");
        assert!(
            replies[0].starts_with("\x1b_Gi=3;EBADF: "),
            "{refused:?}: {replies:?}"
        );
    }
    // A file is found through a symbolic link.
    let (out, replies) = send(&to_regular);
    assert!(replies.is_empty(), "{replies:?}");
    assert_eq!(transmitted(&out).1, data);
    assert!(regular.exists(), "a file (t=f) is never deleted");
    // Missing, or relative.
    let (_, replies) = send(&dir.path().join("missing"));
    assert!(replies[0].starts_with("\x1b_Gi=3;ENOENT: "), "{replies:?}");
    let (_, replies) = send(Path::new("relative/path"));
    assert!(replies[0].contains("not an absolute path"), "{replies:?}");
}

#[test]
fn data_beyond_the_image_storage_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let big = dir.path().join("big");
    // Sparse: no disk is used.
    File::create(&big)
        .unwrap()
        .set_len(MAX_BYTES as u64 + 1)
        .unwrap();
    let mut media = media(&[]);
    let (out, replies) = run(&mut media, &command("t=f,i=4", path_bytes(&big)), 4096);
    assert!(out.is_empty());
    assert!(
        String::from_utf8_lossy(&replies[0]).starts_with("\x1b_Gi=4;EFBIG: "),
        "{replies:?}"
    );
    // Part of it is read.
    let (out, replies) = run(
        &mut media,
        &command("t=f,i=4,O=1000,S=10", path_bytes(&big)),
        4096,
    );
    assert!(replies.is_empty());
    assert_eq!(transmitted(&out).1, [0; 10]);
    // A query carries far less.
    let query = dir.path().join("query");
    fs::write(&query, noise(MAX_QUERY + 1, 1)).unwrap();
    let (out, replies) = run(
        &mut media,
        &command("a=q,t=f,i=4", path_bytes(&query)),
        4096,
    );
    assert!(out.is_empty());
    assert!(String::from_utf8_lossy(&replies[0]).starts_with("\x1b_Gi=4;EFBIG: "));
}

/// A POSIX shared memory object holding `data`, as a program makes one.
fn shared_memory(data: &[u8]) -> CString {
    static NEXT: AtomicU32 = AtomicU32::new(0);
    // macOS allows 31 bytes.
    let name = CString::new(format!(
        "/cherry-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::SeqCst)
    ))
    .unwrap();
    unsafe {
        let fd = libc::shm_open(
            name.as_ptr(),
            libc::O_CREAT | libc::O_EXCL | libc::O_RDWR,
            0o600 as libc::c_uint,
        );
        assert!(fd >= 0, "shm_open: {}", io::Error::last_os_error());
        assert_eq!(libc::ftruncate(fd, data.len() as libc::off_t), 0);
        let map = libc::mmap(
            std::ptr::null_mut(),
            data.len(),
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_SHARED,
            fd,
            0,
        );
        assert_ne!(map, libc::MAP_FAILED);
        std::ptr::copy_nonoverlapping(data.as_ptr(), map.cast(), data.len());
        libc::munmap(map, data.len());
        libc::close(fd);
    }
    name
}

fn unlinked(name: &CString) -> bool {
    let fd = unsafe { libc::shm_open(name.as_ptr(), libc::O_RDONLY, 0 as libc::c_uint) };
    if fd >= 0 {
        unsafe {
            libc::close(fd);
            libc::shm_unlink(name.as_ptr());
        }
    }
    fd < 0
}

#[test]
fn shared_memory_is_read_and_unlinked() {
    let data = noise(10_000, 11);
    let name = shared_memory(&data);
    let mut media = media(&[]);
    let control = format!("a=t,f=100,t=s,i=6,S={}", data.len());
    let (out, replies) = run(&mut media, &command(&control, name.as_bytes()), 4096);
    assert!(replies.is_empty(), "{replies:?}");
    assert_eq!(transmitted(&out).1, data);
    assert!(unlinked(&name));
    // Raw pixels without a size: the bytes the pixels take, though the
    // object may be larger (macOS rounds it up to pages).
    let pixels = [1, 2, 3, 4, 5, 6, 7, 8];
    let name = shared_memory(&[&pixels[..], &[0xee; 100]].concat());
    let (out, replies) = run(
        &mut media,
        &command("t=s,f=32,s=2,v=1,i=6", name.as_bytes()),
        4096,
    );
    assert!(replies.is_empty(), "{replies:?}");
    assert_eq!(transmitted(&out).1, pixels);
    assert!(unlinked(&name));
    // At an offset that is not a page's.
    let name = shared_memory(&data);
    let (out, _) = run(
        &mut media,
        &command("t=s,f=100,i=6,O=5000,S=7", name.as_bytes()),
        4096,
    );
    assert_eq!(transmitted(&out).1, &data[5000..5007]);
    // Unlinked when the read is refused too (past its end, which may be
    // rounded up to pages).
    let name = shared_memory(&data);
    let (out, replies) = run(
        &mut media,
        &command("t=s,i=6,S=1000000", name.as_bytes()),
        4096,
    );
    assert!(out.is_empty());
    assert!(String::from_utf8_lossy(&replies[0]).starts_with("\x1b_Gi=6;EINVAL: "));
    assert!(unlinked(&name));
    // A missing object, and names that are not POSIX ones.
    let (_, replies) = run(
        &mut media,
        &command("t=s,i=6", "/cherry-missing-object"),
        4096,
    );
    assert!(String::from_utf8_lossy(&replies[0]).starts_with("\x1b_Gi=6;ENOENT: "));
    for bad in ["no-slash", "/a/b", "/"] {
        let (_, replies) = run(&mut media, &command("t=s,i=6", bad), 4096);
        assert!(String::from_utf8_lossy(&replies[0]).starts_with("\x1b_Gi=6;EINVAL: "));
    }
}

#[test]
fn refusals_are_answered_as_the_command_asks_and_go_nowhere_else() {
    let reply = |control: &str| {
        let mut media = media(&[]);
        let stream = [
            &b"a"[..],
            &command(control, "/nonexistent/cherry/file"),
            b"b",
        ]
        .concat();
        let (out, replies) = run(&mut media, &stream, 3);
        assert_eq!(out, b"ab", "{control}");
        replies
            .into_iter()
            .next()
            .map(|r| String::from_utf8(r).unwrap())
    };
    assert_eq!(
        reply("a=T,t=f,i=7").as_deref(),
        Some("\x1b_Gi=7;ENOENT: cannot open the file: no such file or directory\x1b\\")
    );
    // Errors are answered under q=1, and nothing under q=2.
    assert!(reply("a=T,t=f,i=7,q=1").is_some());
    assert!(reply("a=T,t=f,i=7,q=2").is_none());
    // Only a command that names its image is answered.
    assert!(reply("a=T,t=f").is_none());
    assert!(reply("a=T,t=f,p=3").is_none());
    assert_eq!(
        reply("a=T,t=f,I=3,p=4").as_deref(),
        Some("\x1b_GI=3,p=4;ENOENT: cannot open the file: no such file or directory\x1b\\")
    );
    // A payload that is not a path, and none.
    let mut media = media(&[]);
    let (out, replies) = run(&mut media, b"\x1b_Gt=f,i=9;%%%\x1b\\", 4096);
    assert!(out.is_empty());
    assert!(String::from_utf8_lossy(&replies[0]).starts_with("\x1b_Gi=9;EINVAL: "));
    let (_, replies) = run(&mut media, b"\x1b_Gt=f,i=9\x1b\\", 4096);
    assert!(String::from_utf8_lossy(&replies[0]).contains("no path"));
}

#[test]
fn only_data_carrying_commands_name_a_medium() {
    assert_eq!(medium(b"t=f"), Some(Medium::File));
    assert_eq!(medium(b"a=T,t=t,i=1"), Some(Medium::Temporary));
    assert_eq!(medium(b"a=q,t=s"), Some(Medium::Shared));
    assert_eq!(medium(b"a=f,t=f,r=2"), Some(Medium::File));
    assert_eq!(medium(b"t=d"), None);
    assert_eq!(medium(b"a=p,t=f"), None);
    assert_eq!(medium(b"a=d,t=f"), None);
    assert_eq!(medium(b"t=f,t=d"), None);
}

#[test]
fn commands_after_a_read_wait_for_it_and_are_read_in_turn() {
    let dir = tempfile::tempdir().unwrap();
    let (first, second) = (dir.path().join("1"), dir.path().join("2"));
    fs::write(&first, noise(10, 1)).unwrap();
    fs::write(&second, noise(20, 2)).unwrap();
    let stream = [
        &b"x"[..],
        &command("t=f,i=1", path_bytes(&first)),
        b"between",
        &command("t=f,i=2", path_bytes(&second)),
        b"y",
    ]
    .concat();
    let mut media = media(&[]);
    let mut out = Vec::new();
    media.feed(&stream, &mut |bytes: &[u8]| out.extend_from_slice(bytes));
    // Only what came before the first command went on.
    assert_eq!(out, b"x");
    assert!(media.holds_output() && media.reading());
    // More output waits behind it, in order.
    media.feed(b"z", &mut |bytes: &[u8]| out.extend_from_slice(bytes));
    assert_eq!(out, b"x");
    drain(&mut media, &mut out, &mut Vec::new());
    let expected = [
        &b"x"[..],
        &direct(b"t=f,i=1", &noise(10, 1)),
        b"between",
        &direct(b"t=f,i=2", &noise(20, 2)),
        b"yz",
    ]
    .concat();
    assert_eq!(out, expected);
}

#[test]
fn a_read_that_takes_too_long_is_refused_and_the_output_goes_on() {
    fn slow(_: &Source, _: &Places) -> Result<Vec<u8>, Refusal> {
        std::thread::sleep(Duration::from_secs(5));
        Ok(vec![1, 2, 3])
    }
    let mut media = media(&[]);
    media.reader = slow;
    media.timeout = Duration::from_millis(200);
    let mut out = Vec::new();
    let mut replies = Vec::new();
    for round in 0..MAX_STUCK {
        media.feed(&command("t=f,i=1", "/x"), &mut |bytes: &[u8]| {
            out.extend_from_slice(bytes)
        });
        media.feed(b"after", &mut |bytes: &[u8]| out.extend_from_slice(bytes));
        assert!(!media.due(Instant::now()), "round {round}");
        assert!(media.deadline().is_some());
        drain(&mut media, &mut out, &mut replies);
    }
    assert_eq!(out, b"after".repeat(MAX_STUCK));
    assert_eq!(replies.len(), MAX_STUCK);
    assert!(String::from_utf8_lossy(&replies[0]).starts_with("\x1b_Gi=1;ETIMEDOUT: "));
    // Those reads still run: the next command is refused at once.
    let started = Instant::now();
    media.feed(&command("t=f,i=1", "/x"), &mut |bytes: &[u8]| {
        out.extend_from_slice(bytes)
    });
    assert!(media.due(Instant::now()));
    drain(&mut media, &mut out, &mut replies);
    assert!(started.elapsed() < Duration::from_millis(150));
    assert!(String::from_utf8_lossy(replies.last().unwrap()).starts_with("\x1b_Gi=1;EBUSY: "));
}

/// Ghostty takes a one-byte value that is not a digit as that byte, and
/// any other as a number: `t=102` is `t=f`, `a=84` is `a=T`. The holder
/// reads keys as Ghostty does (`cherry_vt::kitty`), so a medium written in
/// numbers is one too, and a renderer never gets it to read.
#[test]
fn keys_are_read_as_ghostty_reads_them() {
    for control in [
        "t=102",
        "t=0102",
        "t=+102",
        "t=1_02",
        "a=84,t=f",
        "a=+116,t=102",
        "a=113,t=f",
    ] {
        assert_eq!(medium(control.as_bytes()), Some(Medium::File), "{control}");
    }
    assert_eq!(medium(b"t=116"), Some(Medium::Temporary));
    assert_eq!(medium(b"a=84,t=115"), Some(Medium::Shared));
    // What Ghostty refuses, or never reads as `t`, names none: no
    // terminal reads anything for it.
    for control in [
        "t=F",
        "T=f",
        " t=f",
        "t= f",
        "t=f ",
        "t=358",
        "a=t,,t=f",
        "i=123456789012,t=f",
        "a=112,t=f",
        "t=f,o=x",
        "t=100",
    ] {
        assert_eq!(medium(control.as_bytes()), None, "{control:?}");
    }
}

#[test]
fn media_written_in_numbers_are_read_like_letters() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("image");
    let data = noise(5000, 21);
    fs::write(&file, &data).unwrap();
    for control in [
        "a=84,t=102,i=5",
        "a=+116,t=0102,i=5",
        "t=1_02,i=5,O=1_0,S=+20",
    ] {
        let mut media = media(&[]);
        let (out, replies) = run(&mut media, &command(control, path_bytes(&file)), 4096);
        assert!(replies.is_empty(), "{control}: {replies:?}");
        let (controls, payload) = transmitted(&out);
        let expected = if control.contains("O=") {
            &data[10..30]
        } else {
            &data[..]
        };
        assert_eq!(payload, expected, "{control}");
        // A direct transmission, its keys as Ghostty reads them.
        assert!(
            controls
                .iter()
                .all(|c| !c.contains("t=") && !c.contains("O=") && !c.contains("S=")),
            "{controls:?}"
        );
        assert!(controls[0].starts_with(if control.starts_with("a=84") {
            "a=T,i=5"
        } else {
            "a=t,i=5"
        }));
    }
    // A temporary file (`t=116`), deleted once read.
    let temporary = tempfile::tempdir().unwrap();
    let file = temporary.path().join("tty-graphics-protocol-n");
    fs::write(&file, &data).unwrap();
    let mut media = media(&[temporary.path()]);
    let (out, replies) = run(&mut media, &command("t=116,i=2", path_bytes(&file)), 4096);
    assert!(replies.is_empty(), "{replies:?}");
    assert_eq!(transmitted(&out).1, data);
    assert!(!file.exists());
    // Shared memory (`t=115`), unlinked.
    let name = shared_memory(&data);
    // (Its size: macOS rounds the object up to pages.)
    let (out, replies) = run(
        &mut media,
        &command(
            &format!("t=115,i=2,f=100,S={}", data.len()),
            name.as_bytes(),
        ),
        4096,
    );
    assert!(replies.is_empty(), "{replies:?}");
    assert_eq!(transmitted(&out).1, data);
    assert!(unlinked(&name));
    // Refused as Ghostty answers: `i=+7` is image 7, `q=3` silences all.
    let mut reply = |control: &str| {
        let (_, replies) = run(&mut media, &command(control, "/nonexistent/cherry"), 4096);
        replies
            .into_iter()
            .next()
            .map(|r| String::from_utf8(r).unwrap())
    };
    assert!(reply("a=84,t=102,i=+7")
        .unwrap()
        .starts_with("\x1b_Gi=7;ENOENT: "));
    assert_eq!(reply("t=102,i=7,q=3"), None);
    assert!(reply("t=102,i=7,q=1").is_some());
}

/// Kitty's protocol asks for `a=f` on every chunk of an animation frame
/// (Ghostty takes either); a converted one carries it.
#[test]
fn a_converted_animation_frame_says_so_on_every_chunk() {
    let data = noise(10_000, 4);
    let (controls, payload) = transmitted(&direct(b"a=f,t=f,i=3,r=2,q=1", &data));
    assert_eq!(payload, data);
    assert_eq!(
        controls,
        [
            "a=f,i=3,r=2,q=1,m=1",
            "a=f,m=1,q=1",
            "a=f,m=1,q=1",
            "a=f,m=0,q=1"
        ]
    );
}

/// A converted transmission is framed as it goes out, not all at once:
/// the holder keeps the data read and the chunk going out, not the data
/// again in base64 and framed.
#[test]
fn a_converted_transmission_is_framed_as_it_goes() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("big");
    let data = noise(1 << 20, 8);
    fs::write(&file, &data).unwrap();
    let mut media = media(&[]);
    let mut out = Vec::new();
    media.feed(
        &command("a=T,t=f,f=100,i=9", path_bytes(&file)),
        &mut |bytes: &[u8]| out.extend_from_slice(bytes),
    );
    media.wait(Instant::now() + Duration::from_secs(10));
    assert_eq!(media.finish(Instant::now()), None);
    assert!(
        media.held() <= 2 * CHUNK + 64,
        "{} bytes held for {} read",
        media.held(),
        data.len()
    );
    let mut replies = Vec::new();
    drain(&mut media, &mut out, &mut replies);
    assert_eq!(transmitted(&out).1, data);
    assert_eq!(media.held(), 0);
}

/// A temporary file is deleted from the directory it was read in, and only
/// when the name still holds the file read.
#[test]
fn a_temporary_file_is_deleted_only_as_it_was_read() {
    let temporary = tempfile::tempdir().unwrap();
    let data = noise(300, 17);
    let places = Places::only(vec![temporary.path().to_path_buf()]);
    let file = temporary.path().join("tty-graphics-protocol-swap");
    let source = |path: &Path| Source {
        medium: Medium::Temporary,
        path: path_bytes(path).to_vec(),
        offset: 0,
        size: None,
        pixels: None,
        limit: MAX_BYTES,
    };
    // Another file put in its place after the read is left alone.
    fs::write(&file, &data).unwrap();
    let read = read_temporary_with(&file, &source(&file), &places, |name| {
        let other = name.with_extension("other");
        fs::write(&other, b"someone else's").unwrap();
        fs::rename(&other, name).unwrap();
    });
    assert_eq!(read.unwrap(), data);
    assert_eq!(fs::read(&file).unwrap(), b"someone else's");
    fs::remove_file(&file).unwrap();
    // A directory moved away after the read, and a link to another put in
    // its place: the file is deleted where it was read, never through the
    // link.
    let inner = temporary.path().join("tty-graphics-protocol-dir");
    let moved = temporary.path().join("moved");
    let elsewhere = tempfile::tempdir().unwrap();
    fs::create_dir(&inner).unwrap();
    fs::write(inner.join("x"), &data).unwrap();
    fs::write(elsewhere.path().join("x"), b"elsewhere").unwrap();
    let read = read_temporary_with(&inner.join("x"), &source(&inner.join("x")), &places, |_| {
        fs::rename(&inner, &moved).unwrap();
        symlink(elsewhere.path(), &inner).unwrap();
    });
    assert_eq!(read.unwrap(), data);
    assert_eq!(fs::read(elsewhere.path().join("x")).unwrap(), b"elsewhere");
    assert!(!moved.join("x").exists(), "the file read is deleted");
}

/// Bytes Ghostty ignores inside a command (0xa0 and up) are ignored here
/// too, and the 8-bit ST ends one as `ESC \` does: such a command is read
/// as Ghostty would read it.
#[test]
fn a_command_is_read_through_the_bytes_ghostty_ignores() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("image");
    let data = noise(100, 2);
    fs::write(&file, &data).unwrap();
    let path = b64(path_bytes(&file));
    for stream in [
        format!("\x1b_\u{a0}Ga=T,t=\u{e9}f,i=5;{path}\x1b\\"),
        format!("\x1b_Ga=T,t=f,i=5;{path}\u{9c}"),
    ] {
        let stream = stream
            .chars()
            .map(|c| u8::try_from(u32::from(c)).unwrap())
            .collect::<Vec<u8>>();
        for step in [1, 3, stream.len()] {
            let mut media = media(&[]);
            let (out, replies) = run(&mut media, &stream, step);
            assert!(replies.is_empty(), "{replies:?}");
            assert_eq!(transmitted(&out).1, data, "{stream:?} every {step}");
        }
    }
}
