//! Kitty graphics transmitted from a file, a temporary file or POSIX shared
//! memory (`t=f`, `t=t`, `t=s`). The program names where its data is, and
//! a terminal reads it. Here the holder does, on the machine the session
//! runs on (the right one over SSH too), before the display stream: it
//! reads the data and puts the command back in the program's output as a
//! direct transmission (`t=d`) of that data, in chunks, so the session's
//! terminal and every renderer get the same image wherever they run.
//! Neither ever reads a file itself (`stream::route_graphics` keeps a
//! command that names one from the renderers).
//!
//! What is read, and how:
//! - regular files only, never a device, FIFO, socket or directory, and
//!   nothing under `/proc`, `/sys` or `/dev` (but `/dev/shm`), as kitty and
//!   Ghostty refuse them. A file is looked at before it is opened, so a
//!   device or FIFO is never opened, then opened without following a link,
//!   without blocking and without taking a controlling terminal, and must
//!   be the file looked at. A file (`t=f`) is found through symbolic links
//!   (its canonical path is opened);
//! - a temporary file (`t=t`) only when its canonical path names
//!   `tty-graphics-protocol` and lies in a temporary directory (`/tmp`,
//!   `/dev/shm`, the holder's and the session's `TMPDIR` and, on macOS, the
//!   user's temporary directory), and it is not itself a symbolic link. It
//!   is deleted once read, whether or not that worked;
//! - shared memory (`t=s`) by its POSIX name (`/name`), and unlinked once
//!   read (opened or not);
//! - from `O=` bytes in, `S=` bytes exactly when given, else to the end
//!   (for shared memory holding raw pixels, the bytes its `s=`, `v=` and
//!   `f=` call for, as Ghostty reads it: its size is rounded up to pages),
//!   and at most `MAX_BYTES`, what a screen keeps of images. A query
//!   (`a=q`) goes on in one command, so it carries at most `MAX_QUERY`.
//!
//! A command it cannot serve goes to neither the terminal nor the
//! renderers. It is answered as a terminal answers (`ENOENT: …`,
//! `EBADF: …`), as its `q=` and `i=`/`I=` allow, in order with the replies
//! of the session's terminal (see `Holder::read_output`).
//!
//! The read runs on a thread of its own, so a slow file (on a network
//! mount, say) never holds up the holder's loop: the output the program
//! wrote after the command waits behind it, and the PTY is not read
//! meanwhile, as when output waits for the terminal or the daemon. A read
//! that takes longer than `READ_TIMEOUT` is refused, and its thread left to
//! finish; while `MAX_STUCK` of those still run, a command is refused at
//! once.
//!
//! The scanner follows the display stream's tokenizer: only `ESC _` begins
//! a graphics command (APC), which ends at ST; CAN or SUB abort it, and an
//! ESC followed by anything but `\` abandons it and begins a new sequence.
//! Everything but a media command passes through byte for byte, in order,
//! and a command split across reads is found whole.
use crate::signals::{self, Wake};
use std::{
    ffi::{CString, OsStr},
    fs::{File, OpenOptions},
    io,
    os::unix::{
        ffi::OsStrExt,
        fs::{FileExt, MetadataExt, OpenOptionsExt},
        io::{AsRawFd, FromRawFd, RawFd},
        net::UnixStream,
    },
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};

/// The most bytes a command's data may have: what each screen of a
/// session's terminal keeps of images.
pub const MAX_BYTES: usize = cherry_vt::IMAGE_STORAGE_BYTES as usize;
/// A query's data goes on in one command, which the display stream bounds
/// (64 KiB): at most this many bytes, in base64.
pub const MAX_QUERY: usize = 32 * 1024;
/// How long a read may take before its command is refused.
pub const READ_TIMEOUT: Duration = Duration::from_secs(5);
/// Reads that timed out and may still be blocked, at most: beyond, a
/// command is refused at once.
const MAX_STUCK: usize = 4;
/// Base64 bytes per chunk of a converted transmission (a multiple of 4),
/// as kitty sends them.
const CHUNK: usize = 4096;
/// A command whose control data is longer than this is not one to read
/// for (it goes on as it is).
const MAX_CONTROL: usize = 1024;
/// A media command is at most this long, as the display stream bounds
/// control strings: a longer one goes on as it is, and is dropped there.
const MAX_COMMAND: usize = 64 * 1024;
/// A temporary file's path names this (kitty's rule).
const TEMPORARY_MARK: &[u8] = b"tty-graphics-protocol";
const ESC: u8 = 0x1b;

/// Where a command's data is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Medium {
    File,
    Temporary,
    Shared,
}

/// Why a command was not served: an errno-style code and a message, as a
/// terminal replies (`CODE: message`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
    pub code: &'static str,
    pub message: String,
}

impl Refusal {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    /// A failed system call, by its error.
    fn io(error: &io::Error, what: &str) -> Self {
        let code = match error.raw_os_error() {
            Some(libc::ENOENT) | Some(libc::ENOTDIR) => "ENOENT",
            Some(libc::EACCES) | Some(libc::EPERM) => "EACCES",
            Some(libc::ELOOP) => "ELOOP",
            Some(libc::ENAMETOOLONG) => "ENAMETOOLONG",
            Some(libc::ENOMEM) => "ENOMEM",
            Some(libc::EIO) => "EIO",
            _ => "EBADF",
        };
        let description = io::Error::from_raw_os_error(error.raw_os_error().unwrap_or(libc::EIO))
            .to_string()
            .split(" (os error")
            .next()
            .unwrap_or_default()
            .to_lowercase();
        Self::new(code, format!("{what}: {description}"))
    }

    fn not_regular() -> Self {
        Self::new("EBADF", "not a regular file")
    }
}

/// Where temporary files may be: canonical temporary directories, found
/// when a temporary file is read (on the reading thread: a directory on a
/// slow mount never holds up the holder).
#[derive(Clone, Debug, Default)]
pub struct Places {
    candidates: Vec<PathBuf>,
}

impl Places {
    /// `/tmp`, `/dev/shm`, the holder's `TMPDIR`, the session's
    /// (`session_tmpdir`, from its environment) and, on macOS, the user's
    /// temporary directory.
    pub fn new(session_tmpdir: Option<&[u8]>) -> Self {
        let mut candidates: Vec<PathBuf> = vec!["/tmp".into(), "/dev/shm".into()];
        if let Some(dir) = std::env::var_os("TMPDIR") {
            candidates.push(dir.into());
        }
        if let Some(dir) = session_tmpdir {
            candidates.push(PathBuf::from(OsStr::from_bytes(dir)));
        }
        #[cfg(target_os = "macos")]
        if let Some(dir) = darwin_user_temp_dir() {
            candidates.push(dir);
        }
        candidates.retain(|dir| dir.is_absolute());
        Self { candidates }
    }

    /// Exactly these directories (tests).
    #[cfg(test)]
    pub fn only(candidates: Vec<PathBuf>) -> Self {
        Self { candidates }
    }

    /// Whether `path`, canonical, lies in a temporary directory.
    fn temporary(&self, path: &Path) -> bool {
        self.candidates
            .iter()
            .filter_map(|dir| std::fs::canonicalize(dir).ok())
            .any(|dir| path.starts_with(&dir) && path != dir)
    }
}

#[cfg(target_os = "macos")]
fn darwin_user_temp_dir() -> Option<PathBuf> {
    let mut buffer = vec![0u8; 1024];
    let len = unsafe {
        libc::confstr(
            libc::_CS_DARWIN_USER_TEMP_DIR,
            buffer.as_mut_ptr().cast(),
            buffer.len(),
        )
    };
    if len == 0 || len > buffer.len() {
        return None;
    }
    buffer.truncate(len - 1);
    Some(PathBuf::from(OsStr::from_bytes(&buffer)))
}

/// What a media command asks to be read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Source {
    pub medium: Medium,
    /// The file's path or the shared memory's name.
    pub path: Vec<u8>,
    /// `O=`.
    pub offset: u64,
    /// `S=`; None when not given (or 0).
    pub size: Option<u64>,
    /// For shared memory without `S=`: the bytes raw pixels take (`s=`,
    /// `v=`, `f=` 24 or 32, uncompressed).
    pub pixels: Option<u64>,
    /// At most this many bytes.
    pub limit: usize,
}

impl Source {
    /// The source a media command's control data and payload (the path,
    /// in base64) name.
    fn parse(control: &[u8], payload: &[u8]) -> Result<Self, Refusal> {
        let medium = medium(control).ok_or_else(|| Refusal::new("EINVAL", "no medium"))?;
        let invalid = |key: &str| Refusal::new("EINVAL", format!("invalid {key}"));
        let number = |value: &[u8], key: &str| -> Result<u64, Refusal> {
            std::str::from_utf8(value)
                .ok()
                .and_then(|value| value.parse().ok())
                .ok_or_else(|| invalid(key))
        };
        let (mut offset, mut size, mut format, mut width, mut height) = (0, 0, 32, 0, 0);
        let (mut compressed, mut query) = (false, false);
        for (key, value) in keys(control) {
            match key {
                b"O" => offset = number(value, "offset (O)")?,
                b"S" => size = number(value, "size (S)")?,
                b"f" => format = number(value, "format (f)")?,
                b"s" => width = number(value, "width (s)")?,
                b"v" => height = number(value, "height (v)")?,
                b"o" => compressed = !value.is_empty(),
                b"a" => query = value == b"q",
                _ => {}
            }
        }
        let path = decode_base64(payload).ok_or_else(|| invalid("path (not base64)"))?;
        if path.is_empty() {
            return Err(Refusal::new("EINVAL", "no path"));
        }
        if path.contains(&0) {
            return Err(invalid("path"));
        }
        let bytes_per_pixel = match format {
            24 => Some(3),
            32 => Some(4),
            _ => None,
        };
        let pixels = bytes_per_pixel
            .filter(|_| !compressed && width > 0 && height > 0)
            .and_then(|bytes| width.checked_mul(height)?.checked_mul(bytes));
        Ok(Self {
            medium,
            path,
            offset,
            size: (size > 0).then_some(size),
            pixels,
            limit: if query { MAX_QUERY } else { MAX_BYTES },
        })
    }
}

/// The keys of a command's control data (`k=v,k=v`), in order; a key
/// given twice counts as the last one.
fn keys(control: &[u8]) -> impl Iterator<Item = (&[u8], &[u8])> {
    control
        .split(|&b| b == b',')
        .filter(|item| !item.is_empty())
        .map(|item| match item.iter().position(|&b| b == b'=') {
            Some(at) => (&item[..at], &item[at + 1..]),
            None => (item, &[][..]),
        })
}

/// The medium a graphics command's control data names, when it carries
/// data from anywhere but the output: its action transmits (`a=t`, the
/// default, `T`, `q`, or `f`, an animation frame) and its `t=` is `f`, `t`
/// or `s`.
pub fn medium(control: &[u8]) -> Option<Medium> {
    let mut medium = None;
    let mut transmits = true;
    for (key, value) in keys(control) {
        match key {
            b"t" => {
                medium = match value {
                    b"f" => Some(Medium::File),
                    b"t" => Some(Medium::Temporary),
                    b"s" => Some(Medium::Shared),
                    _ => None,
                }
            }
            b"a" => transmits = matches!(value, b"t" | b"T" | b"q" | b"f"),
            _ => {}
        }
    }
    medium.filter(|_| transmits)
}

/// Read what `source` names (see the module's documentation).
pub fn read(source: &Source, places: &Places) -> Result<Vec<u8>, Refusal> {
    match source.medium {
        Medium::Shared => read_shared(source),
        medium => {
            if !source.path.starts_with(b"/") {
                return Err(Refusal::new("EINVAL", "not an absolute path"));
            }
            let path = Path::new(OsStr::from_bytes(&source.path));
            if medium == Medium::File {
                read_file(path, source)
            } else {
                read_temporary(path, source, places)
            }
        }
    }
}

fn read_file(path: &Path, source: &Source) -> Result<Vec<u8>, Refusal> {
    let canonical =
        std::fs::canonicalize(path).map_err(|error| Refusal::io(&error, "cannot open the file"))?;
    let file = open_regular(&canonical)?;
    read_range(&file, source)
}

fn read_temporary(path: &Path, source: &Source, places: &Places) -> Result<Vec<u8>, Refusal> {
    let (Some(parent), Some(name)) = (path.parent(), path.file_name()) else {
        return Err(Refusal::new("EINVAL", "not a file's path"));
    };
    let canonical = std::fs::canonicalize(parent)
        .map_err(|error| Refusal::io(&error, "cannot open the file"))?
        .join(name);
    if !contains(canonical.as_os_str().as_bytes(), TEMPORARY_MARK) {
        return Err(Refusal::new("EINVAL", "temporary file not named correctly"));
    }
    if !places.temporary(&canonical) {
        return Err(Refusal::new(
            "EINVAL",
            "temporary file not in a temporary directory",
        ));
    }
    let metadata = std::fs::symlink_metadata(&canonical)
        .map_err(|error| Refusal::io(&error, "cannot open the file"))?;
    if metadata.file_type().is_symlink() {
        return Err(Refusal::new(
            "ELOOP",
            "the temporary file is a symbolic link",
        ));
    }
    if !metadata.file_type().is_file() {
        return Err(Refusal::not_regular());
    }
    // The program handed it over: deleted however the read goes.
    let read = open_regular(&canonical).and_then(|file| read_range(&file, source));
    let _ = std::fs::remove_file(&canonical);
    read
}

/// Open `path`, canonical (no link in it), read-only as a regular file
/// (see the module's documentation).
fn open_regular(path: &Path) -> Result<File, Refusal> {
    let bytes = path.as_os_str().as_bytes();
    let under = |dir: &[u8]| bytes.starts_with(dir);
    if under(b"/proc/") || under(b"/sys/") || (under(b"/dev/") && !under(b"/dev/shm/")) {
        return Err(Refusal::new("EBADF", "a system file is never read"));
    }
    let looked = std::fs::symlink_metadata(path)
        .map_err(|error| Refusal::io(&error, "cannot open the file"))?;
    if !looked.file_type().is_file() {
        return Err(Refusal::not_regular());
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_NOCTTY)
        .open(path)
        .map_err(|error| Refusal::io(&error, "cannot open the file"))?;
    let opened = file
        .metadata()
        .map_err(|error| Refusal::io(&error, "cannot read the file"))?;
    if !opened.file_type().is_file() || (opened.dev(), opened.ino()) != (looked.dev(), looked.ino())
    {
        return Err(Refusal::new(
            "EBADF",
            "the file changed while it was opened",
        ));
    }
    Ok(file)
}

/// The bytes to read of data `len` bytes long: where they start and how
/// many there are.
fn range(len: u64, source: &Source, pixels: Option<u64>) -> Result<(u64, usize), Refusal> {
    if source.offset > len {
        return Err(Refusal::new("EINVAL", "the offset (O) is past the end"));
    }
    let available = len - source.offset;
    let size = source.size.or(pixels).unwrap_or(available);
    if size > source.limit as u64 {
        return Err(Refusal::new(
            "EFBIG",
            format!("more than {} bytes", source.limit),
        ));
    }
    if size > available {
        return Err(Refusal::new(
            "EINVAL",
            "the data is shorter than its size (S)",
        ));
    }
    Ok((source.offset, size as usize))
}

fn read_range(file: &File, source: &Source) -> Result<Vec<u8>, Refusal> {
    let len = file
        .metadata()
        .map_err(|error| Refusal::io(&error, "cannot read the file"))?
        .len();
    let (start, size) = range(len, source, None)?;
    let mut data = vec![0; size];
    file.read_exact_at(&mut data, start)
        .map_err(|error| match error.kind() {
            io::ErrorKind::UnexpectedEof => {
                Refusal::new("EINVAL", "the data is shorter than its size (S)")
            }
            _ => Refusal::io(&error, "cannot read the file"),
        })?;
    Ok(data)
}

fn read_shared(source: &Source) -> Result<Vec<u8>, Refusal> {
    let name = &source.path;
    // A POSIX name: a slash, then at least one byte and no other slash.
    if name.len() < 2 || name[0] != b'/' || name[1..].contains(&b'/') || name.len() > 255 {
        return Err(Refusal::new("EINVAL", "not a shared memory name"));
    }
    let name = CString::new(name.clone()).map_err(|_| Refusal::new("EINVAL", "not a name"))?;
    let fd = unsafe { libc::shm_open(name.as_ptr(), libc::O_RDONLY, 0 as libc::c_uint) };
    if fd < 0 {
        return Err(Refusal::io(
            &io::Error::last_os_error(),
            "cannot open the shared memory",
        ));
    }
    let memory = unsafe { File::from_raw_fd(fd) };
    let read = read_memory(&memory, source);
    drop(memory);
    unsafe { libc::shm_unlink(name.as_ptr()) };
    read
}

fn read_memory(memory: &File, source: &Source) -> Result<Vec<u8>, Refusal> {
    let len = memory
        .metadata()
        .map_err(|error| Refusal::io(&error, "cannot read the shared memory"))?
        .len();
    let (start, size) = range(len, source, source.pixels)?;
    if size == 0 {
        return Ok(Vec::new());
    }
    // Linux keeps shared memory in a file system that reads as any file;
    // macOS maps it only.
    if cfg!(target_os = "linux") {
        let mut data = vec![0; size];
        memory
            .read_exact_at(&mut data, start)
            .map_err(|error| Refusal::io(&error, "cannot read the shared memory"))?;
        return Ok(data);
    }
    let page = u64::try_from(unsafe { libc::sysconf(libc::_SC_PAGESIZE) })
        .ok()
        .filter(|&page| page > 0)
        .unwrap_or(4096);
    let base = start - start % page;
    let skip = (start - base) as usize;
    let length = skip + size;
    let map = unsafe {
        libc::mmap(
            std::ptr::null_mut(),
            length,
            libc::PROT_READ,
            libc::MAP_SHARED,
            memory.as_raw_fd(),
            base as libc::off_t,
        )
    };
    if map == libc::MAP_FAILED {
        return Err(Refusal::io(
            &io::Error::last_os_error(),
            "cannot map the shared memory",
        ));
    }
    let data = unsafe { std::slice::from_raw_parts(map.cast::<u8>().add(skip), size) }.to_vec();
    unsafe { libc::munmap(map, length) };
    Ok(data)
}

/// Base64 (standard alphabet, padding optional); None for anything else.
fn decode_base64(text: &[u8]) -> Option<Vec<u8>> {
    let text = text
        .strip_suffix(b"==")
        .or_else(|| text.strip_suffix(b"="))
        .unwrap_or(text);
    if text.len() % 4 == 1 {
        return None;
    }
    let value = |byte: u8| -> Option<u32> {
        Some(match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        } as u32)
    };
    let mut out = Vec::with_capacity(text.len() / 4 * 3 + 2);
    for group in text.chunks(4) {
        let mut n = 0;
        for (index, &byte) in group.iter().enumerate() {
            n |= value(byte)? << (18 - 6 * index);
        }
        let bytes = [(n >> 16) as u8, (n >> 8) as u8, n as u8];
        out.extend_from_slice(&bytes[..group.len() - 1]);
    }
    Some(out)
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    memchr::memmem::find(haystack, needle).is_some()
}

/// The command a media command becomes once its data is read: a direct
/// transmission of `data`, with the command's other keys (not `t=`, `S=`,
/// `O=` or `m=`; `a=t` when it had no action), in base64 chunks of `CHUNK`
/// bytes, `m=1` on all but the last, which carry `q=` as the command did.
/// A query goes in one command.
pub fn direct(control: &[u8], data: &[u8]) -> Vec<u8> {
    let mut first = Vec::with_capacity(control.len() + 8);
    let mut query = false;
    let mut quiet = None;
    let mut action = false;
    for item in control
        .split(|&b| b == b',')
        .filter(|item| !item.is_empty())
    {
        let key = item.split(|&b| b == b'=').next().unwrap_or_default();
        match key {
            b"t" | b"S" | b"O" | b"m" => continue,
            b"a" => {
                action = true;
                query = item == b"a=q";
            }
            b"q" => quiet = Some(item),
            _ => {}
        }
        if !first.is_empty() {
            first.push(b',');
        }
        first.extend_from_slice(item);
    }
    if !action {
        first.splice(
            0..0,
            if first.is_empty() {
                &b"a=t"[..]
            } else {
                b"a=t,"
            }
            .iter()
            .copied(),
        );
    }
    let payload = cherry_vt::base64(data);
    let chunks: Vec<&[u8]> = if payload.is_empty() || query {
        vec![&payload]
    } else {
        payload.chunks(CHUNK).collect()
    };
    let mut out = Vec::with_capacity(payload.len() + chunks.len() * 24 + first.len());
    for (index, chunk) in chunks.iter().enumerate() {
        let more = index + 1 < chunks.len();
        out.extend_from_slice(b"\x1b_G");
        if index == 0 {
            out.extend_from_slice(&first);
            if more {
                out.extend_from_slice(b",m=1");
            }
        } else {
            out.extend_from_slice(if more { b"m=1" } else { b"m=0" });
            if let Some(quiet) = quiet {
                out.push(b',');
                out.extend_from_slice(quiet);
            }
        }
        out.push(b';');
        out.extend_from_slice(chunk);
        out.extend_from_slice(b"\x1b\\");
    }
    out
}

/// What a terminal answers a command it refused for `refusal`, as its
/// `q=` allows (`q=2` silences errors too) and only when it names its
/// image (`i=` or `I=`), as Ghostty encodes it.
pub fn refusal_reply(control: &[u8], refusal: &Refusal) -> Option<Vec<u8>> {
    let mut named = Vec::new();
    for key in [&b"i"[..], b"I", b"p"] {
        let value = keys(control)
            .filter(|(k, _)| *k == key)
            .last()
            .and_then(|(_, value)| std::str::from_utf8(value).ok()?.parse::<u32>().ok())
            .filter(|&value| value > 0);
        if let Some(value) = value {
            if key == b"p" && named.is_empty() {
                break;
            }
            if !named.is_empty() {
                named.push(b',');
            }
            named.extend_from_slice(key);
            named.push(b'=');
            named.extend_from_slice(value.to_string().as_bytes());
        }
    }
    let quiet = keys(control)
        .filter(|(k, _)| *k == b"q")
        .last()
        .map(|(_, v)| v);
    if named.is_empty() || quiet == Some(b"2") {
        return None;
    }
    let mut reply = b"\x1b_G".to_vec();
    reply.extend(named);
    reply.push(b';');
    reply.extend_from_slice(refusal.code.as_bytes());
    reply.extend_from_slice(b": ");
    // The message is the holder's own, but never carries a control.
    reply.extend(
        refusal
            .message
            .bytes()
            .filter(|&b| (0x20..0x7f).contains(&b)),
    );
    reply.extend_from_slice(b"\x1b\\");
    Some(reply)
}

#[derive(Default, Clone, Copy, PartialEq, Eq, Debug)]
enum Scan {
    #[default]
    Ground,
    /// `token` holds an ESC.
    Escape,
    /// `token` holds `ESC _`.
    Apc,
    /// `token` holds `ESC _ G` and the control data so far.
    Control,
    /// `token` holds a media command's control data and its payload so
    /// far.
    Payload,
}

/// What reads a source (`read`; tests stand in their own).
type Reader = fn(&Source, &Places) -> Result<Vec<u8>, Refusal>;
type Outcome = Arc<Mutex<Option<Result<Vec<u8>, Refusal>>>>;

/// A read under way, for a command's control data.
struct Job {
    control: Vec<u8>,
    outcome: Outcome,
    deadline: Instant,
}

impl Job {
    fn outcome(&self) -> std::sync::MutexGuard<'_, Option<Result<Vec<u8>, Refusal>>> {
        self.outcome.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// The holder's media layer, between the PTY and the display stream (see
/// the module's documentation).
pub struct Media {
    scan: Scan,
    /// The unfinished token, from its ESC.
    token: Vec<u8>,
    /// In `Control` or `Payload`: the last byte was ESC.
    escaped: bool,
    job: Option<Job>,
    /// A read's command, converted, going out.
    ready: Vec<u8>,
    ready_at: usize,
    /// The program's output after the command, not looked at yet.
    after: Vec<u8>,
    after_at: usize,
    places: Arc<Places>,
    wake: Arc<Wake>,
    wakeups: UnixStream,
    /// Reading threads still running (those that timed out included).
    running: Arc<AtomicUsize>,
    reader: Reader,
    timeout: Duration,
}

impl Media {
    pub fn new(places: Places) -> io::Result<Self> {
        let (wake, wakeups) = Wake::pair()?;
        Ok(Self {
            scan: Scan::Ground,
            token: Vec::new(),
            escaped: false,
            job: None,
            ready: Vec::new(),
            ready_at: 0,
            after: Vec::new(),
            after_at: 0,
            places: Arc::new(places),
            wake,
            wakeups,
            running: Arc::new(AtomicUsize::new(0)),
            reader: read,
            timeout: READ_TIMEOUT,
        })
    }

    /// Readable when a read finished: drain it with `drain_wakeups`.
    pub fn wakeup_fd(&self) -> RawFd {
        self.wakeups.as_raw_fd()
    }

    pub fn drain_wakeups(&self) {
        signals::drain(&self.wakeups);
    }

    /// Output waits here (a read under way, its command's chunks, the
    /// output after it): the PTY is not read until it went on.
    pub fn holds_output(&self) -> bool {
        self.job.is_some() || self.ready_at < self.ready.len() || self.after_at < self.after.len()
    }

    /// A read is under way (or finished, and not taken by `finish` yet).
    pub fn reading(&self) -> bool {
        self.job.is_some()
    }

    /// Whether `finish` or `resume` has something to do now.
    pub fn due(&self, now: Instant) -> bool {
        match &self.job {
            Some(job) => now >= job.deadline || job.outcome().is_some(),
            None => self.ready_at < self.ready.len() || self.after_at < self.after.len(),
        }
    }

    /// When the read under way times out.
    pub fn deadline(&self) -> Option<Instant> {
        self.job.as_ref().map(|job| job.deadline)
    }

    /// Wait until the read under way finished or timed out, at most until
    /// `until`.
    pub fn wait(&self, until: Instant) {
        while let Some(job) = &self.job {
            let now = Instant::now();
            if job.outcome().is_some() || now >= job.deadline || now >= until {
                return;
            }
            let left = job.deadline.min(until) - now;
            let mut poll = libc::pollfd {
                fd: self.wakeup_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            let millis = left.as_millis().clamp(1, i32::MAX as u128) as libc::c_int;
            unsafe { libc::poll(&mut poll, 1, millis) };
            self.drain_wakeups();
        }
    }

    /// The program's output, which follows all it fed before: what goes on
    /// at once to `pass`, in order. A media command starts a read, and
    /// what follows it waits (see `resume`).
    pub fn feed(&mut self, bytes: &[u8], pass: &mut impl FnMut(&[u8])) {
        if self.holds_output() {
            self.after.extend_from_slice(bytes);
            return;
        }
        if let Some(end) = self.scan(bytes, pass) {
            self.after.extend_from_slice(&bytes[end..]);
        }
    }

    /// A finished read: its command's chunks go out next (`resume`), or
    /// what to answer the program when it was refused. Nothing while the
    /// read is under way.
    pub fn finish(&mut self, now: Instant) -> Option<Vec<u8>> {
        let job = self.job.as_ref()?;
        let outcome = job.outcome().take();
        let outcome = match outcome {
            Some(outcome) => outcome,
            None if now >= job.deadline => Err(Refusal::new(
                "ETIMEDOUT",
                format!(
                    "reading the data took more than {} seconds",
                    self.timeout.as_secs_f32()
                ),
            )),
            None => return None,
        };
        let job = self.job.take()?;
        match outcome {
            Ok(data) => {
                self.ready = direct(&job.control, &data);
                self.ready_at = 0;
                None
            }
            Err(refusal) => refusal_reply(&job.control, &refusal),
        }
    }

    /// Up to about `max` bytes of the output that waits, to `pass`: a read
    /// command's chunks, then the output after it, which may start another
    /// read. Returns how many went (0 while a read is under way).
    pub fn resume(&mut self, max: usize, pass: &mut impl FnMut(&[u8])) -> usize {
        if self.job.is_some() {
            return 0;
        }
        if self.ready_at < self.ready.len() {
            let end = self.ready.len().min(self.ready_at + max.max(1));
            pass(&self.ready[self.ready_at..end]);
            let went = end - self.ready_at;
            self.ready_at = end;
            if end == self.ready.len() {
                self.ready = Vec::new();
                self.ready_at = 0;
            }
            return went;
        }
        if self.after_at < self.after.len() {
            let after = std::mem::take(&mut self.after);
            let end = after.len().min(self.after_at + max.max(1));
            let slice = &after[self.after_at..end];
            let went = self.scan(slice, pass).unwrap_or(slice.len());
            self.after = after;
            self.after_at += went;
            if self.after_at == self.after.len() {
                self.after.clear();
                self.after.shrink_to(MAX_COMMAND);
                self.after_at = 0;
            }
            return went;
        }
        0
    }

    /// Scan `bytes`, passing on all but a media command, which starts a
    /// read: where it ended in `bytes`, if one did.
    fn scan(&mut self, bytes: &[u8], pass: &mut impl FnMut(&[u8])) -> Option<usize> {
        let mut at = 0;
        while at < bytes.len() {
            if self.scan == Scan::Ground {
                // Only `ESC _` begins a command: what comes before it goes
                // on as it is, and so does all of it when there is none (but
                // an ESC at the end, which might).
                let rest = &bytes[at..];
                match memchr::memmem::find(rest, b"\x1b_") {
                    Some(found) => {
                        if found > 0 {
                            pass(&rest[..found]);
                        }
                        self.hold(b"\x1b_", Scan::Apc);
                        at += found + 2;
                    }
                    None => {
                        let held = usize::from(rest.last() == Some(&ESC));
                        if rest.len() > held {
                            pass(&rest[..rest.len() - held]);
                        }
                        if held == 1 {
                            self.hold(&[ESC], Scan::Escape);
                        }
                        return None;
                    }
                }
                continue;
            }
            let byte = bytes[at];
            at += 1;
            if self.step(byte, pass) {
                return Some(at);
            }
        }
        None
    }

    fn hold(&mut self, bytes: &[u8], scan: Scan) {
        self.token.clear();
        self.token.extend_from_slice(bytes);
        self.scan = scan;
        self.escaped = false;
    }

    /// Pass the token on as it is: it is not a media command.
    fn release(&mut self, pass: &mut impl FnMut(&[u8])) {
        if !self.token.is_empty() {
            pass(&self.token);
        }
        self.token.clear();
        self.scan = Scan::Ground;
        self.escaped = false;
    }

    /// One byte outside the ground state's fast path; whether it completed
    /// a media command (whose read started).
    fn step(&mut self, byte: u8, pass: &mut impl FnMut(&[u8])) -> bool {
        match self.scan {
            Scan::Ground => {
                if byte == ESC {
                    self.hold(&[ESC], Scan::Escape);
                } else {
                    pass(&[byte]);
                }
            }
            Scan::Escape => {
                if byte == b'_' {
                    self.token.push(byte);
                    self.scan = Scan::Apc;
                } else {
                    self.release(pass);
                    return self.step(byte, pass);
                }
            }
            Scan::Apc => {
                if byte == b'G' {
                    self.token.push(byte);
                    self.scan = Scan::Control;
                } else {
                    self.release(pass);
                    return self.step(byte, pass);
                }
            }
            Scan::Control | Scan::Payload => {
                if self.escaped {
                    self.escaped = false;
                    if byte == b'\\' {
                        self.token.push(byte);
                        return self.complete(pass);
                    }
                    // ESC and anything but `\` abandons the command, as the
                    // display stream does; the ESC begins what comes next.
                    self.token.pop();
                    self.release(pass);
                    self.hold(&[ESC], Scan::Escape);
                    return self.step(byte, pass);
                }
                match byte {
                    // CAN and SUB abort it.
                    0x18 | 0x1a => {
                        self.token.push(byte);
                        self.release(pass);
                    }
                    ESC => {
                        self.token.push(byte);
                        self.escaped = true;
                    }
                    b';' if self.scan == Scan::Control => {
                        self.token.push(byte);
                        let control = &self.token[3..self.token.len() - 1];
                        if medium(control).is_some() {
                            self.scan = Scan::Payload;
                        } else {
                            self.release(pass);
                        }
                    }
                    _ => {
                        self.token.push(byte);
                        let limit = if self.scan == Scan::Control {
                            MAX_CONTROL
                        } else {
                            MAX_COMMAND
                        };
                        if self.token.len() > limit {
                            self.release(pass);
                        }
                    }
                }
            }
        }
        false
    }

    /// A whole graphics command (`token`, from ESC to ST): a media command
    /// starts its read; any other goes on.
    fn complete(&mut self, pass: &mut impl FnMut(&[u8])) -> bool {
        let body = &self.token[3..self.token.len() - 2];
        let (control, payload) = match body.iter().position(|&b| b == b';') {
            Some(at) => (&body[..at], &body[at + 1..]),
            None => (body, &[][..]),
        };
        if medium(control).is_none() {
            self.release(pass);
            return false;
        }
        let job = Job {
            control: control.to_vec(),
            outcome: Arc::default(),
            deadline: Instant::now() + self.timeout,
        };
        let source = Source::parse(control, payload);
        self.token.clear();
        self.scan = Scan::Ground;
        self.escaped = false;
        let refused = match source {
            Err(refusal) => Some(refusal),
            Ok(_) if self.running.load(Ordering::SeqCst) >= MAX_STUCK => {
                Some(Refusal::new("EBUSY", "earlier reads have not finished"))
            }
            Ok(source) => self.spawn(source, &job).err(),
        };
        if let Some(refusal) = refused {
            *job.outcome() = Some(Err(refusal));
        }
        self.job = Some(job);
        true
    }

    /// Start the thread that reads `source` for `job`.
    fn spawn(&self, source: Source, job: &Job) -> Result<(), Refusal> {
        let (places, wake, running) =
            (self.places.clone(), self.wake.clone(), self.running.clone());
        let (outcome, reader) = (job.outcome.clone(), self.reader);
        self.running.fetch_add(1, Ordering::SeqCst);
        let spawned = std::thread::Builder::new()
            .name("media".into())
            .spawn(move || {
                // Signals are the holder's (SIGCHLD wakes its loop).
                unsafe {
                    let mut all: libc::sigset_t = std::mem::zeroed();
                    libc::sigfillset(&mut all);
                    libc::pthread_sigmask(libc::SIG_BLOCK, &all, std::ptr::null_mut());
                }
                let read = reader(&source, &places);
                *outcome.lock().unwrap_or_else(|e| e.into_inner()) = Some(read);
                running.fetch_sub(1, Ordering::SeqCst);
                wake.wake();
            });
        if spawned.is_err() {
            self.running.fetch_sub(1, Ordering::SeqCst);
            return Err(Refusal::new("ENOMEM", "cannot start reading the data"));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests;
