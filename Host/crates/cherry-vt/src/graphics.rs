//! Kitty graphics: the PNG decoder libghostty-vt calls, and the commands
//! that give a fresh renderer the images and placements of a terminal's
//! active screen (`Terminal::graphics_replay`).
use anyhow::Result;
use std::{collections::BTreeMap, ffi::c_void, fmt::Write as _, io::Write as _, sync::Once};

/// Images wider or taller than this are refused, as Ghostty does.
pub const MAX_IMAGE_SIDE: u32 = 10_000;
/// The most bytes a decoded PNG may take (RGBA): larger ones are refused
/// before they are decoded. No larger image fits in a session terminal's
/// image storage (`IMAGE_STORAGE_BYTES`), which would refuse it after
/// decoding.
pub const MAX_DECODED_BYTES: usize = crate::IMAGE_STORAGE_BYTES as usize;
/// Base64 bytes per chunk of a re-sent image (a multiple of 4).
const CHUNK: usize = 4096;

/// `GhosttySysImage` in sys.h.
#[repr(C)]
pub(crate) struct SysImage {
    width: u32,
    height: u32,
    data: *mut u8,
    data_len: usize,
}

/// `CherryPlacement` in shim.c.
#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub(crate) struct RawPlacement {
    pub image_id: u32,
    pub placement_id: u32,
    pub x_offset: u32,
    pub y_offset: u32,
    pub source_x: u32,
    pub source_y: u32,
    pub source_width: u32,
    pub source_height: u32,
    pub columns: u32,
    pub rows: u32,
    pub z: i32,
    pub viewport_col: i32,
    pub viewport_row: i32,
    pub grid_cols: u32,
    pub grid_rows: u32,
    pub generation: u64,
    pub is_virtual: bool,
    pub visible: bool,
    pub has_pixels: bool,
}

/// `CherryImage` in shim.c.
#[repr(C)]
pub(crate) struct RawImage {
    pub width: u32,
    pub height: u32,
    pub format: i32,
    pub data: *const u8,
    pub len: usize,
    pub number: u32,
}

type DecodePng = extern "C" fn(*mut c_void, *const c_void, *const u8, usize, *mut SysImage) -> bool;

unsafe extern "C" {
    fn cherry_vt_install_png(decode: DecodePng) -> i32;
    fn ghostty_alloc(allocator: *const c_void, len: usize) -> *mut u8;
    fn ghostty_free(allocator: *const c_void, bytes: *mut c_void, len: usize);
}

/// Install the PNG decoder, once per process, before the first terminal.
pub(crate) fn install_png_decoder() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        // Only an unknown option fails, which this one is not.
        let _ = unsafe { cherry_vt_install_png(decode_png) };
    });
}

/// Decode `data` (a PNG) into 8-bit RGBA pixels allocated with Ghostty's
/// `allocator`, which takes them. False, and nothing allocated, for a PNG
/// that is malformed, too large or anything else that goes wrong; a panic
/// never leaves this function.
extern "C" fn decode_png(
    _userdata: *mut c_void,
    allocator: *const c_void,
    data: *const u8,
    len: usize,
    out: *mut SysImage,
) -> bool {
    if data.is_null() || out.is_null() {
        return false;
    }
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let bytes = unsafe { std::slice::from_raw_parts(data, len) };
        let decoded = decode_with(bytes, |len| {
            let ptr = unsafe { ghostty_alloc(allocator, len) };
            (!ptr.is_null()).then_some(GhosttyBuffer {
                allocator,
                ptr,
                len,
            })
        });
        let Ok((width, height, buffer)) = decoded else {
            return false;
        };
        let (data, data_len) = buffer.into_raw();
        unsafe {
            out.write(SysImage {
                width,
                height,
                data,
                data_len,
            });
        }
        true
    }))
    .unwrap_or(false)
}

/// Bytes from `ghostty_alloc`, freed unless handed over (`into_raw`).
struct GhosttyBuffer {
    allocator: *const c_void,
    ptr: *mut u8,
    len: usize,
}

impl GhosttyBuffer {
    fn into_raw(self) -> (*mut u8, usize) {
        let raw = (self.ptr, self.len);
        std::mem::forget(self);
        raw
    }
}

impl AsMut<[u8]> for GhosttyBuffer {
    fn as_mut(&mut self) -> &mut [u8] {
        unsafe { std::slice::from_raw_parts_mut(self.ptr, self.len) }
    }
}

impl Drop for GhosttyBuffer {
    fn drop(&mut self) {
        unsafe { ghostty_free(self.allocator, self.ptr.cast(), self.len) };
    }
}

/// A PNG as 8-bit RGBA: width, height and pixels.
pub fn decode_rgba(bytes: &[u8]) -> Result<(u32, u32, Vec<u8>)> {
    decode_with(bytes, |len| Some(vec![0; len]))
}

/// A PNG as 8-bit RGBA in a buffer of `alloc`'s (given the length it must
/// have). A PNG that decodes to 8-bit RGBA is decoded straight into it;
/// any other goes through a buffer of its own first. Refused before any
/// decoding: images over `MAX_IMAGE_SIDE` pixels a side or
/// `MAX_DECODED_BYTES` as RGBA.
fn decode_with<B: AsMut<[u8]>>(
    bytes: &[u8],
    alloc: impl FnOnce(usize) -> Option<B>,
) -> Result<(u32, u32, B)> {
    let limits = png::Limits {
        bytes: MAX_DECODED_BYTES,
    };
    let mut decoder = png::Decoder::new_with_limits(std::io::Cursor::new(bytes), limits);
    decoder.set_transformations(png::Transformations::normalize_to_color8());
    let mut reader = decoder.read_info()?;
    let (width, height) = {
        let info = reader.info();
        (info.width, info.height)
    };
    anyhow::ensure!(
        width > 0 && height > 0 && width <= MAX_IMAGE_SIDE && height <= MAX_IMAGE_SIDE,
        "a {width}x{height} PNG"
    );
    let pixels = width as usize * height as usize;
    anyhow::ensure!(
        pixels * 4 <= MAX_DECODED_BYTES,
        "a {width}x{height} PNG is too large"
    );
    let size = reader
        .output_buffer_size()
        .ok_or_else(|| anyhow::anyhow!("a PNG too large to decode"))?;
    anyhow::ensure!(size <= MAX_DECODED_BYTES, "a PNG too large to decode");
    let rgba8 = reader.output_color_type() == (png::ColorType::Rgba, png::BitDepth::Eight);
    if rgba8 && size == pixels * 4 {
        let mut out = alloc(size).ok_or_else(|| anyhow::anyhow!("out of memory"))?;
        reader.next_frame(out.as_mut())?;
        return Ok((width, height, out));
    }
    let mut buffer = vec![0; size];
    let frame = reader.next_frame(&mut buffer)?;
    anyhow::ensure!(
        frame.bit_depth == png::BitDepth::Eight,
        "a PNG of {:?} bits",
        frame.bit_depth
    );
    let channels = match frame.color_type {
        png::ColorType::Grayscale => 1,
        png::ColorType::GrayscaleAlpha => 2,
        png::ColorType::Rgb => 3,
        png::ColorType::Rgba => 4,
        png::ColorType::Indexed => anyhow::bail!("an unexpanded palette"),
    };
    let row = frame.line_size;
    anyhow::ensure!(
        row >= width as usize * channels && buffer.len() >= row * height as usize,
        "a short PNG frame"
    );
    let mut out = alloc(pixels * 4).ok_or_else(|| anyhow::anyhow!("out of memory"))?;
    let target = out.as_mut();
    let mut at = 0;
    for line in buffer.chunks(row).take(height as usize) {
        for pixel in line[..width as usize * channels].chunks_exact(channels) {
            target[at..at + 4].copy_from_slice(&match *pixel {
                [gray] => [gray, gray, gray, 255],
                [gray, alpha] => [gray, gray, gray, alpha],
                [r, g, b] => [r, g, b, 255],
                [r, g, b, a] => [r, g, b, a],
                _ => unreachable!(),
            });
            at += 4;
        }
    }
    Ok((width, height, out))
}

// GhosttyKittyImageFormat.
const FORMAT_RGB: i32 = 0;
const FORMAT_RGBA: i32 = 1;
const FORMAT_GRAY_ALPHA: i32 = 3;
const FORMAT_GRAY: i32 = 4;

/// Pixels of a stored image as 8-bit RGBA, or None for a format that is
/// not raw pixels or data of the wrong length.
pub(crate) fn to_rgba(width: u32, height: u32, format: i32, data: &[u8]) -> Option<Vec<u8>> {
    let pixels = width as usize * height as usize;
    let channels = match format {
        FORMAT_RGB => 3,
        FORMAT_RGBA => 4,
        FORMAT_GRAY_ALPHA => 2,
        FORMAT_GRAY => 1,
        _ => return None,
    };
    if data.len() != pixels * channels {
        return None;
    }
    if channels == 4 {
        return Some(data.to_vec());
    }
    let mut rgba = Vec::with_capacity(pixels * 4);
    for pixel in data.chunks_exact(channels) {
        rgba.extend_from_slice(&match *pixel {
            [gray] => [gray, gray, gray, 255],
            [gray, alpha] => [gray, gray, gray, alpha],
            [r, g, b] => [r, g, b, 255],
            _ => unreachable!(),
        });
    }
    Some(rgba)
}

/// What `Terminal::graphics_replay` gives: kitty graphics commands, all
/// with `q=2`, and what the budget left out.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct GraphicsReplay {
    /// The commands: every image kept, then the placements of those.
    pub bytes: Vec<u8>,
    /// Images re-sent.
    pub images: usize,
    /// Placements re-sent.
    pub placements: usize,
    /// Images on screen left out because the budget had no room for them,
    /// and the bytes of RGBA pixels they hold.
    pub dropped: usize,
    pub dropped_bytes: usize,
    /// Of those, numbered images whose ID was too high to give them again
    /// (see `Terminal::graphics_replay`).
    pub unnamed: usize,
}

/// The compressed pixels of images re-sent, by image ID and generation.
#[derive(Default)]
pub(crate) struct Cache {
    entries: std::collections::HashMap<(u32, u64), std::rc::Rc<Vec<u8>>>,
    bytes: usize,
}

impl Cache {
    pub fn get(&self, key: &(u32, u64)) -> Option<&std::rc::Rc<Vec<u8>>> {
        self.entries.get(key)
    }

    pub fn insert(&mut self, key: (u32, u64), payload: std::rc::Rc<Vec<u8>>) {
        self.bytes += payload.len();
        if let Some(old) = self.entries.insert(key, payload) {
            self.bytes -= old.len();
        }
    }

    pub fn retain(&mut self, keep: impl Fn(&(u32, u64)) -> bool) {
        let bytes = &mut self.bytes;
        self.entries.retain(|key, payload| {
            let kept = keep(key);
            if !kept {
                *bytes -= payload.len();
            }
            kept
        });
    }

    /// Drop entries, largest first, until at most `limit` bytes are kept.
    pub fn shrink_to(&mut self, limit: usize) {
        while self.bytes > limit {
            let Some(key) = self
                .entries
                .iter()
                .max_by_key(|(_, payload)| payload.len())
                .map(|(key, _)| *key)
            else {
                break;
            };
            if let Some(payload) = self.entries.remove(&key) {
                self.bytes -= payload.len();
            }
        }
    }
}

/// One image to re-send and its placements (see `replay`).
pub(crate) struct Candidate {
    pub id: u32,
    pub generation: u64,
    pub placements: Vec<RawPlacement>,
}

/// The images that `placements` show in the top `rows` rows of a screen
/// (and its `cols` left columns, when given), newest first: those of
/// virtual placements (unicode placeholders), and of direct placements
/// whose rows (and columns) all lie there. Placements of images whose data
/// is still pending, and direct ones partly or wholly outside, are left
/// out.
pub(crate) fn candidates(
    placements: &[RawPlacement],
    cols: Option<u16>,
    rows: u16,
) -> Vec<Candidate> {
    let mut images: BTreeMap<u32, Candidate> = BTreeMap::new();
    for placement in placements {
        let shown = placement.is_virtual
            || (placement.visible
                && placement.viewport_row >= 0
                && placement.viewport_col >= 0
                && i64::from(placement.viewport_row) + i64::from(placement.grid_rows.max(1))
                    <= i64::from(rows)
                && cols.is_none_or(|cols| {
                    i64::from(placement.viewport_col) + i64::from(placement.grid_cols.max(1))
                        <= i64::from(cols)
                }));
        if !shown || !placement.has_pixels {
            continue;
        }
        images
            .entry(placement.image_id)
            .or_insert_with(|| Candidate {
                id: placement.image_id,
                generation: placement.generation,
                placements: Vec::new(),
            })
            .placements
            .push(*placement);
    }
    let mut images: Vec<Candidate> = images.into_values().collect();
    images.sort_by(|a, b| b.generation.cmp(&a.generation).then(b.id.cmp(&a.id)));
    for image in &mut images {
        // Virtual placements first, then direct ones top to bottom, in a
        // stable order.
        image.placements.sort_by_key(|p| {
            (
                !p.is_virtual,
                p.viewport_row,
                p.viewport_col,
                p.z,
                p.placement_id,
            )
        });
    }
    images
}

/// `rgba` pixels zlib-compressed and in base64: the payload of `transmit`.
pub(crate) fn encode_pixels(rgba: &[u8]) -> Vec<u8> {
    base64(&miniz_oxide::deflate::compress_to_vec_zlib(rgba, 1))
}

/// The most bytes `encode_pixels` can take for `raw` bytes of pixels, at
/// least: deflate never shrinks data by more than about 1032 to 1, and
/// base64 grows it by a third.
pub(crate) fn encoded_at_least(raw: usize) -> usize {
    raw / 1032 * 4 / 3
}

/// How a re-sent image is named: by its ID, or by its number (`I=`), which
/// makes the receiver give it the lowest free ID.
#[derive(Clone, Copy)]
pub(crate) enum Name {
    Id(u32),
    Number(u32),
}

/// `a=t` for an image of `width` by `height` RGBA pixels whose `payload`
/// is `encode_pixels`'s, in base64 chunks, with `q=2` on every chunk.
pub(crate) fn transmit(name: Name, width: u32, height: u32, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(payload.len() + payload.len() / CHUNK * 24 + 64);
    let chunks: Vec<&[u8]> = if payload.is_empty() {
        vec![&[][..]]
    } else {
        payload.chunks(CHUNK).collect()
    };
    let name = match name {
        Name::Id(id) => format!("i={id}"),
        Name::Number(number) => format!("I={number}"),
    };
    for (index, chunk) in chunks.iter().enumerate() {
        let more = u8::from(index + 1 < chunks.len());
        if index == 0 {
            let _ = write!(
                out,
                "\x1b_Ga=t,{name},s={width},v={height},f=32,o=z,q=2,m={more};"
            );
        } else {
            let _ = write!(out, "\x1b_Gm={more},q=2;");
        }
        out.extend_from_slice(chunk);
        out.extend_from_slice(b"\x1b\\");
    }
    out
}

/// A stand-in image under `id`, which holds that ID while numbered images
/// are given theirs (see `Terminal::graphics_replay`).
pub(crate) fn filler(id: u32) -> Vec<u8> {
    format!("\x1b_Ga=t,i={id},s=1,v=1,f=32,q=2;AAAAAA==\x1b\\").into_bytes()
}

/// Deletes every image and placement a receiver holds (all IDs, 1 to
/// 2^32 - 1, and the data of each; `d=R`), quietly: a receiver that is not
/// fresh is brought to where a reset would leave its images before they
/// are re-sent (`Terminal::refresh_with`, a window that paints a
/// viewport). Like every delete, it also abandons a chunked transmission
/// the receiver has not finished.
pub const IMAGE_RESET: &[u8] = b"\x1b_Ga=d,d=R,x=1,y=4294967295,q=2\x1b\\";

/// Deletes the stand-in image under `id` (`filler`).
pub(crate) fn remove_filler(id: u32) -> Vec<u8> {
    format!("\x1b_Ga=d,d=I,i={id},q=2\x1b\\").into_bytes()
}

/// `a=p` for one placement. A direct one is placed at its cell, where the
/// cursor is moved first, and leaves the cursor there (`C=1`).
pub(crate) fn place(placement: &RawPlacement) -> Vec<u8> {
    let mut keys = String::from("a=p");
    let p = placement;
    if p.is_virtual {
        keys.push_str(",U=1");
    }
    let _ = write!(keys, ",i={}", p.image_id);
    // Not its placement ID: an ID Ghostty gave it (it had none) cannot be
    // told from one the program gave, and would stand for the program's own.
    for (key, value) in [
        ("x", p.source_x),
        ("y", p.source_y),
        ("w", p.source_width),
        ("h", p.source_height),
        ("X", p.x_offset),
        ("Y", p.y_offset),
        ("c", p.columns),
        ("r", p.rows),
    ] {
        // A virtual placement has no pixel offsets or source rectangle of
        // its own to keep.
        if value != 0 && (!p.is_virtual || matches!(key, "c" | "r")) {
            let _ = write!(keys, ",{key}={value}");
        }
    }
    if p.z != 0 && !p.is_virtual {
        let _ = write!(keys, ",z={}", p.z);
    }
    let mut out = Vec::new();
    if !p.is_virtual {
        let _ = write!(out, "\x1b[{};{}H", p.viewport_row + 1, p.viewport_col + 1);
        keys.push_str(",C=1");
    }
    let _ = write!(out, "\x1b_G{keys},q=2\x1b\\");
    out
}

/// `bytes` in standard base64, padded (RFC 4648).
pub fn base64(bytes: &[u8]) -> Vec<u8> {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = Vec::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b = [
            chunk[0],
            chunk.get(1).copied().unwrap_or(0),
            chunk.get(2).copied().unwrap_or(0),
        ];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        out.push(ALPHABET[(n >> 18) as usize & 63]);
        out.push(ALPHABET[(n >> 12) as usize & 63]);
        out.push(if chunk.len() > 1 {
            ALPHABET[(n >> 6) as usize & 63]
        } else {
            b'='
        });
        out.push(if chunk.len() > 2 {
            ALPHABET[n as usize & 63]
        } else {
            b'='
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_pads_as_rfc_4648() {
        assert_eq!(base64(b""), b"");
        assert_eq!(base64(b"f"), b"Zg==");
        assert_eq!(base64(b"fo"), b"Zm8=");
        assert_eq!(base64(b"foo"), b"Zm9v");
        assert_eq!(base64(b"foobar"), b"Zm9vYmFy");
    }

    #[test]
    fn large_images_go_in_chunks_of_4096_bytes() {
        // Noise does not compress.
        let mut state = 0x2545_f491_u32;
        let rgba: Vec<u8> = (0..64 * 64 * 4)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                state as u8
            })
            .collect();
        let out = transmit(Name::Id(3), 64, 64, &encode_pixels(&rgba));
        let text = String::from_utf8(out).unwrap();
        let chunks: Vec<&str> = text.split("\x1b\\").filter(|c| !c.is_empty()).collect();
        assert!(chunks.len() > 4, "{}", chunks.len());
        assert!(chunks[0].starts_with("\x1b_Ga=t,i=3,s=64,v=64,f=32,o=z,q=2,m=1;"));
        for chunk in &chunks[1..chunks.len() - 1] {
            assert!(chunk.starts_with("\x1b_Gm=1,q=2;"), "{chunk:.20}");
            assert_eq!(chunk.len(), "\x1b_Gm=1,q=2;".len() + CHUNK);
        }
        assert!(chunks.last().unwrap().starts_with("\x1b_Gm=0,q=2;"));
    }

    #[test]
    fn stored_formats_become_rgba() {
        assert_eq!(
            to_rgba(1, 1, FORMAT_RGB, &[1, 2, 3]),
            Some(vec![1, 2, 3, 255])
        );
        assert_eq!(
            to_rgba(1, 1, FORMAT_GRAY_ALPHA, &[9, 7]),
            Some(vec![9, 9, 9, 7])
        );
        assert_eq!(to_rgba(1, 1, FORMAT_GRAY, &[5]), Some(vec![5, 5, 5, 255]));
        assert_eq!(to_rgba(1, 1, FORMAT_RGB, &[1, 2]), None);
        assert_eq!(to_rgba(1, 1, 2, &[1, 2, 3, 4]), None);
    }
}
