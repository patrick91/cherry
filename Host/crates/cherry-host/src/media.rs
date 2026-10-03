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
//! A command's keys are read as Ghostty reads them (`cherry_vt::kitty`):
//! `t=102` is `t=f` and `a=84` is `a=T`, and a command Ghostty refuses (or
//! that names its image by both ID and number, which it refuses before
//! reading) is not read.
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
//!   is deleted once read, whether or not that worked: in the directory it
//!   was read in, only while its name holds the file read;
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
//! a graphics command (APC), which ends at ST (`ESC \` or 0x9c); CAN, SUB
//! or another 8-bit control abort it, an ESC followed by anything but `\`
//! abandons it and begins a new sequence, and bytes from 0xa0 up, which
//! Ghostty ignores in it, are ignored. (A command an 8-bit control begins,
//! or in SOS or PM, is not read: the display stream gives it to the host
//! alone.)
//! Everything but a media command passes through byte for byte, in order,
//! and a command split across reads is found whole.
use crate::signals::{self, Wake};
use cherry_vt::kitty::{self, Control};
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
    fn parse(control: &Control, payload: &[u8]) -> Result<Self, Refusal> {
        let medium = medium_of(control).ok_or_else(|| Refusal::new("EINVAL", "no medium"))?;
        let invalid = |key: &str| Refusal::new("EINVAL", format!("invalid {key}"));
        let value = |key: u8| u64::from(control.get(key).unwrap_or(0));
        // Ghostty's default format is RGBA (32), as is 0.
        let format = control.get(b'f').filter(|&f| f != 0).unwrap_or(32);
        let (width, height) = (value(b's'), value(b'v'));
        let compressed = control.get(b'o').is_some();
        // Ghostty ignores bytes from 0xa0 up in a command.
        let payload: Vec<u8> = payload.iter().copied().filter(|&b| b < 0xa0).collect();
        let path = decode_base64(&payload).ok_or_else(|| invalid("path (not base64)"))?;
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
        let size = value(b'S');
        Ok(Self {
            medium,
            path,
            offset: value(b'O'),
            size: (size > 0).then_some(size),
            pixels,
            limit: if control.action() == b'q' {
                MAX_QUERY
            } else {
                MAX_BYTES
            },
        })
    }
}

/// The medium of a command whose control data (as Ghostty reads it) names
/// one to read: one that transmits (`a=t`, the default, `T`, `q`, or `f`,
/// an animation frame) from a file, a temporary file or shared memory, and
/// names its image by ID or number, not both (Ghostty refuses that before
/// it reads anything).
fn medium_of(control: &Control) -> Option<Medium> {
    let both = control.get(b'i').is_some_and(|i| i > 0) && control.get(b'I').is_some_and(|n| n > 0);
    match control.medium()? {
        _ if both => None,
        kitty::Medium::Direct => None,
        kitty::Medium::File => Some(Medium::File),
        kitty::Medium::Temporary => Some(Medium::Temporary),
        kitty::Medium::Shared => Some(Medium::Shared),
    }
}

/// The medium a graphics command's control data names, when it carries
/// data from anywhere but the output (see `medium_of`), read as Ghostty
/// reads it (`cherry_vt::kitty`): `t=102` is `t=f`, and a command Ghostty
/// refuses names none (tests).
#[cfg(test)]
pub fn medium(control: &[u8]) -> Option<Medium> {
    let mut parser = kitty::Parser::new();
    for &byte in control {
        parser.feed(byte);
    }
    medium_of(&parser.finish()?)
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
    read_temporary_with(path, source, places, |_| {})
}

/// `read_temporary`, with `between` run after the read and before the
/// deletion (tests change the file system there).
fn read_temporary_with(
    path: &Path,
    source: &Source,
    places: &Places,
    between: impl FnOnce(&Path),
) -> Result<Vec<u8>, Refusal> {
    let (Some(parent), Some(name)) = (path.parent(), path.file_name()) else {
        return Err(Refusal::new("EINVAL", "not a file's path"));
    };
    let opening = |error: io::Error| Refusal::io(&error, "cannot open the file");
    let parent = std::fs::canonicalize(parent).map_err(opening)?;
    // The directory, opened once: the file is looked at, read and deleted
    // in it, whatever its path comes to name meanwhile; and where it is is
    // asked of the directory itself.
    let dir = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&parent)
        .map_err(opening)?;
    let canonical = directory_path(&dir, &parent)?.join(name);
    if !contains(canonical.as_os_str().as_bytes(), TEMPORARY_MARK) {
        return Err(Refusal::new("EINVAL", "temporary file not named correctly"));
    }
    if !places.temporary(&canonical) {
        return Err(Refusal::new(
            "EINVAL",
            "temporary file not in a temporary directory",
        ));
    }
    if system_file(&canonical) {
        return Err(Refusal::new("EBADF", "a system file is never read"));
    }
    let name = CString::new(name.as_bytes()).map_err(|_| Refusal::new("EINVAL", "not a name"))?;
    let looked = stat_at(&dir, &name).map_err(opening)?;
    match looked.st_mode & libc::S_IFMT {
        libc::S_IFREG => {}
        libc::S_IFLNK => {
            return Err(Refusal::new(
                "ELOOP",
                "the temporary file is a symbolic link",
            ))
        }
        _ => return Err(Refusal::not_regular()),
    }
    // The program handed it over: deleted however the read goes, but only
    // the file looked at, never one put in its place.
    let read = open_at(&dir, &name, &looked).and_then(|file| read_range(&file, source));
    between(&canonical);
    if stat_at(&dir, &name)
        .is_ok_and(|now| (now.st_dev, now.st_ino) == (looked.st_dev, looked.st_ino))
    {
        unsafe { libc::unlinkat(dir.as_raw_fd(), name.as_ptr(), 0) };
    }
    read
}

/// The path of the opened directory `dir`, as the system has it now (it
/// was found at `path`): one a link put in its path since cannot change.
fn directory_path(dir: &File, path: &Path) -> Result<PathBuf, Refusal> {
    #[cfg(target_os = "macos")]
    {
        use std::os::unix::ffi::OsStringExt;
        let mut buffer = vec![0u8; libc::PATH_MAX as usize + 1];
        if unsafe { libc::fcntl(dir.as_raw_fd(), libc::F_GETPATH, buffer.as_mut_ptr()) } == 0 {
            if let Some(len) = buffer.iter().position(|&b| b == 0) {
                buffer.truncate(len);
                return Ok(PathBuf::from(std::ffi::OsString::from_vec(buffer)));
            }
        }
    }
    #[cfg(target_os = "linux")]
    {
        if let Ok(found) = std::fs::read_link(format!("/proc/self/fd/{}", dir.as_raw_fd())) {
            // A directory removed meanwhile is " (deleted)" there.
            return if found.is_absolute() && found.exists() {
                Ok(found)
            } else {
                Err(Refusal::new("ENOENT", "the directory was removed"))
            };
        }
    }
    // Without either: the path, if it still names the directory opened.
    let opened = dir
        .metadata()
        .map_err(|error| Refusal::io(&error, "cannot open the file"))?;
    let named = std::fs::symlink_metadata(path)
        .map_err(|error| Refusal::io(&error, "cannot open the file"))?;
    if (opened.dev(), opened.ino()) != (named.dev(), named.ino()) {
        return Err(Refusal::new(
            "EBADF",
            "the directory changed while it was opened",
        ));
    }
    Ok(path.to_path_buf())
}

/// `name` in `dir`, not following a link.
fn stat_at(dir: &File, name: &CString) -> io::Result<libc::stat> {
    let mut stat = std::mem::MaybeUninit::<libc::stat>::zeroed();
    let done = unsafe {
        libc::fstatat(
            dir.as_raw_fd(),
            name.as_ptr(),
            stat.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    };
    if done != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { stat.assume_init() })
}

/// Open `name` in `dir`, which was `looked` at as a regular file, read-only
/// and as `open_regular` does: it must still be that file.
fn open_at(dir: &File, name: &CString, looked: &libc::stat) -> Result<File, Refusal> {
    let fd = unsafe {
        libc::openat(
            dir.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_NOCTTY | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(Refusal::io(
            &io::Error::last_os_error(),
            "cannot open the file",
        ));
    }
    let file = unsafe { File::from_raw_fd(fd) };
    let opened = file
        .metadata()
        .map_err(|error| Refusal::io(&error, "cannot read the file"))?;
    if !opened.file_type().is_file() || (opened.dev(), opened.ino()) != identity(looked) {
        return Err(Refusal::new(
            "EBADF",
            "the file changed while it was opened",
        ));
    }
    Ok(file)
}

/// A file's device and inode, as `MetadataExt` gives them (the types of
/// `stat`'s differ between systems).
#[allow(clippy::unnecessary_cast)]
fn identity(stat: &libc::stat) -> (u64, u64) {
    (stat.st_dev as u64, stat.st_ino as u64)
}

/// Under `/proc`, `/sys` or `/dev` (but `/dev/shm`): never read.
fn system_file(path: &Path) -> bool {
    let bytes = path.as_os_str().as_bytes();
    let under = |dir: &[u8]| bytes.starts_with(dir);
    under(b"/proc/") || under(b"/sys/") || (under(b"/dev/") && !under(b"/dev/shm/"))
}

/// Open `path`, canonical (no link in it), read-only as a regular file
/// (see the module's documentation).
fn open_regular(path: &Path) -> Result<File, Refusal> {
    if system_file(path) {
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

/// Raw bytes per chunk of a converted transmission: `CHUNK` in base64.
const CHUNK_DATA: usize = CHUNK / 4 * 3;

/// The command a media command becomes once its data is read: a direct
/// transmission of the data, with the command's other keys as Ghostty
/// reads them (not `t=`, `S=`, `O=` or `m=`; `a=t` when it had no action),
/// in base64 chunks of `CHUNK` bytes, `m=1` on all but the last. The
/// chunks after the first carry `q=` as the command did, and `a=f` too for
/// an animation frame, as kitty's protocol asks (Ghostty takes either). A
/// query goes in one command.
///
/// Each chunk is framed as it goes out (`next_chunk`): the data is kept
/// once, not again in base64 and framed.
struct Ready {
    /// The first chunk's control data.
    first: Vec<u8>,
    /// The later chunks' control data after `m=`.
    rest: Vec<u8>,
    /// Their own action (`a=f,`), before `m=`.
    action: &'static [u8],
    data: Vec<u8>,
    /// Raw bytes per chunk (all of them for a query).
    step: usize,
    /// Where the next chunk begins in `data`; None once the last is out.
    at: Option<usize>,
}

impl Ready {
    fn new(control: &Control, data: Vec<u8>) -> Self {
        let mut first = Vec::with_capacity(32);
        if control.get(b'a').is_none() {
            first.extend_from_slice(b"a=t");
        }
        let keys = control.encode(|key| !matches!(key, b't' | b'S' | b'O' | b'm'));
        if !first.is_empty() && !keys.is_empty() {
            first.push(b',');
        }
        first.extend(keys);
        let rest = control
            .get(b'q')
            .map(|_| control.encode(|key| key == b'q'))
            .unwrap_or_default();
        let query = control.action() == b'q';
        Self {
            first,
            rest,
            action: if control.action() == b'f' {
                b"a=f,"
            } else {
                b""
            },
            step: if query { data.len().max(1) } else { CHUNK_DATA },
            data,
            at: Some(0),
        }
    }

    /// The next chunk, framed; None once all went.
    fn next_chunk(&mut self) -> Option<Vec<u8>> {
        let at = self.at?;
        let end = self.data.len().min(at + self.step);
        let more = end < self.data.len();
        let payload = cherry_vt::base64(&self.data[at..end]);
        let mut out = Vec::with_capacity(payload.len() + self.first.len() + 16);
        out.extend_from_slice(b"\x1b_G");
        if at == 0 {
            out.extend_from_slice(&self.first);
            if more {
                out.extend_from_slice(if self.first.is_empty() {
                    b"m=1"
                } else {
                    b",m=1"
                });
            }
        } else {
            out.extend_from_slice(self.action);
            out.extend_from_slice(if more { b"m=1" } else { b"m=0" });
            if !self.rest.is_empty() {
                out.push(b',');
                out.extend_from_slice(&self.rest);
            }
        }
        out.push(b';');
        out.extend_from_slice(&payload);
        out.extend_from_slice(b"\x1b\\");
        self.at = more.then_some(end);
        Some(out)
    }
}

/// All of a converted command (see `Ready`) at once (tests).
#[cfg(test)]
pub fn direct(control: &[u8], data: &[u8]) -> Vec<u8> {
    let mut parser = kitty::Parser::new();
    for &byte in control {
        parser.feed(byte);
    }
    let mut ready = Ready::new(&parser.finish().expect("control data"), data.to_vec());
    std::iter::from_fn(|| ready.next_chunk())
        .flatten()
        .collect()
}

/// What a terminal answers a command it refused for `refusal`, as Ghostty
/// encodes it: only when it names its image (`i=` or `I=`, then `p=`, and
/// `r=` for an animation frame), and as its `q=` allows (1 answers errors,
/// more silences them too).
pub fn refusal_reply(control: &Control, refusal: &Refusal) -> Option<Vec<u8>> {
    let positive = |key: u8| control.get(key).filter(|&value| value > 0);
    if (positive(b'i').is_none() && positive(b'I').is_none()) || control.quiet() >= 2 {
        return None;
    }
    let frame = (control.action() == b'f').then(|| positive(b'r')).flatten();
    let mut named = Vec::new();
    for (key, value) in [
        ("i", positive(b'i')),
        ("I", positive(b'I')),
        ("p", positive(b'p')),
        ("r", frame),
    ] {
        if let Some(value) = value {
            if !named.is_empty() {
                named.push(b',');
            }
            named.extend_from_slice(format!("{key}={value}").as_bytes());
        }
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
    control: Control,
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
    /// In `Control`: reads the control data as Ghostty does.
    parser: kitty::Parser,
    job: Option<Job>,
    /// A read's command, converted, going out: the chunks still to frame,
    /// and the one going out.
    ready: Option<Ready>,
    chunk: Vec<u8>,
    chunk_at: usize,
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
            parser: kitty::Parser::new(),
            job: None,
            ready: None,
            chunk: Vec::new(),
            chunk_at: 0,
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
        self.job.is_some() || self.converting() || self.after_at < self.after.len()
    }

    /// A read command's chunks are going out.
    fn converting(&self) -> bool {
        self.ready.is_some() || self.chunk_at < self.chunk.len()
    }

    /// Bytes of converted output held, framed, for `resume` (tests).
    #[cfg(test)]
    fn held(&self) -> usize {
        self.chunk.len() - self.chunk_at
    }

    /// A read is under way (or finished, and not taken by `finish` yet).
    pub fn reading(&self) -> bool {
        self.job.is_some()
    }

    /// Whether `finish` or `resume` has something to do now.
    pub fn due(&self, now: Instant) -> bool {
        match &self.job {
            Some(job) => now >= job.deadline || job.outcome().is_some(),
            None => self.converting() || self.after_at < self.after.len(),
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
                self.ready = Some(Ready::new(&job.control, data));
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
        if self.chunk_at == self.chunk.len() {
            if let Some(ready) = &mut self.ready {
                match ready.next_chunk() {
                    Some(chunk) => {
                        self.chunk = chunk;
                        self.chunk_at = 0;
                    }
                    None => {
                        self.ready = None;
                        self.chunk = Vec::new();
                        self.chunk_at = 0;
                    }
                }
            }
        }
        if self.chunk_at < self.chunk.len() {
            let end = self.chunk.len().min(self.chunk_at + max.max(1));
            pass(&self.chunk[self.chunk_at..end]);
            let went = end - self.chunk_at;
            self.chunk_at = end;
            if end == self.chunk.len() && self.ready.as_ref().is_none_or(|r| r.at.is_none()) {
                self.ready = None;
                self.chunk = Vec::new();
                self.chunk_at = 0;
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
                    self.parser = kitty::Parser::new();
                } else if byte >= 0xa0 {
                    // Ghostty ignores it there (and so does the display
                    // stream): it is left out.
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
                    // The 8-bit ST ends it, as `ESC \` does.
                    0x9c => {
                        self.token.extend_from_slice(b"\x1b\\");
                        return self.complete(pass);
                    }
                    // CAN and SUB abort it, and so does any other 8-bit
                    // control (the display stream makes it a 7-bit one).
                    0x18 | 0x1a | 0x80..=0x9f => {
                        self.token.push(byte);
                        self.release(pass);
                    }
                    ESC => {
                        self.token.push(byte);
                        self.escaped = true;
                    }
                    _ if self.scan == Scan::Control && self.parser.feed(byte) => {
                        // The payload begins: a media command's is read.
                        self.token.push(byte);
                        let reads = self.parser.clone().finish().as_ref().and_then(medium_of);
                        if reads.is_some() {
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
        let Some((control, source)) = kitty::parse(body)
            .filter(|command| medium_of(&command.control).is_some())
            .map(|command| {
                let source = Source::parse(&command.control, command.payload.unwrap_or_default());
                (command.control, source)
            })
        else {
            self.release(pass);
            return false;
        };
        let job = Job {
            control,
            outcome: Arc::default(),
            deadline: Instant::now() + self.timeout,
        };
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
