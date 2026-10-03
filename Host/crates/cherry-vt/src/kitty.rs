//! Kitty graphics commands (`ESC _ G <control> ; <payload> ESC \`), read as
//! the pinned Ghostty reads them (`Parser` in
//! `src/terminal/kitty/graphics_command.zig` at the revision
//! `Scripts/build-host-vt` builds), so that what the host and `cherry
//! attach` decide about a command (which action it takes, whether it names
//! a file) is what a Ghostty terminal does with it.
//!
//! How Ghostty reads the control data, byte by byte:
//! - a key is one byte before `=` (only a letter is kept); any other key
//!   (none, or longer) is ignored, and so is everything after it up to the
//!   payload;
//! - a value is what follows up to `,` or `;`, at most 11 bytes (a longer
//!   one is ignored, and so is everything after it up to the payload): one
//!   byte that is not a digit is that byte (`t=f`), anything else a number
//!   in base 10 (`t=102` is `t=f` too), as Zig's `parseInt` reads it: an
//!   optional sign, digits, and `_` between them (`+102`, `0102`, `1_02`),
//!   signed for `z`, `H` and `V`, else unsigned (`-0` is 0). A value that
//!   is not such a number (empty, a space, `102 `) makes it refuse the
//!   whole command;
//! - a key given twice keeps its last value;
//! - the payload begins at the first `;` that ends a key or value (one that
//!   a key too long to keep swallows does not), and a command whose control
//!   data ends without a value (`a=t,`, or nothing at all) is refused;
//! - the action (`a`, `t` when absent), the medium (`t`), the compression
//!   (`o`) and what a deletion deletes (`d`) must each be a byte Ghostty
//!   knows (a number above 255 is refused), else the command is refused.
//!   `t` and `o` are checked only for the actions that transmit (`t`, `T`,
//!   `q`, `f`), `d` only for a deletion.
//!
//! Bytes from 0xa0 up are skipped: Ghostty's parser of escape sequences
//! ignores them inside a command, and never hands them over. An 8-bit
//! control (0x80 to 0x9f) ends the command there (ST, 0x9c) or abandons it;
//! the callers end it before. The payload is not looked at (Ghostty also
//! refuses a command whose payload is not base64).

/// Where a transmission's data is (`t=`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Medium {
    /// In the command's payload (`d`, the default).
    Direct,
    /// A file (`f`).
    File,
    /// A temporary file, deleted once read (`t`).
    Temporary,
    /// POSIX shared memory (`s`).
    Shared,
}

/// The most bytes of a key or value Ghostty keeps (its `kv_temp`).
const TEMP: usize = 11;

/// The keys Ghostty reads as signed numbers.
fn signed(key: u8) -> bool {
    matches!(key, b'z' | b'H' | b'V')
}

/// The keys whose values are letters (an action, a medium, a compression,
/// what to delete): written back as the letter, the others as numbers.
fn lettered(key: u8) -> bool {
    matches!(key, b'a' | b't' | b'o' | b'd')
}

fn index(key: u8) -> Option<usize> {
    match key {
        b'a'..=b'z' => Some(usize::from(key - b'a')),
        b'A'..=b'Z' => Some(26 + usize::from(key - b'A')),
        _ => None,
    }
}

/// A command's control data as Ghostty reads it: each key's value.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Control {
    values: [u32; 52],
    present: u64,
    /// The keys, in the order they were first given.
    order: Vec<u8>,
}

impl Default for Control {
    fn default() -> Self {
        Self {
            values: [0; 52],
            present: 0,
            order: Vec::new(),
        }
    }
}

impl Control {
    fn put(&mut self, key: u8, value: u32) {
        let Some(at) = index(key) else {
            return;
        };
        if self.present & (1 << at) == 0 {
            self.order.push(key);
        }
        self.values[at] = value;
        self.present |= 1 << at;
    }

    /// The value of `key`, as Ghostty reads it: a letter value is its byte
    /// (`t=f` and `t=102` both give 102).
    pub fn get(&self, key: u8) -> Option<u32> {
        let at = index(key)?;
        (self.present & (1 << at) != 0).then_some(self.values[at])
    }

    /// Set `key` (a letter) to `value`; one already given keeps its place.
    pub fn set(&mut self, key: u8, value: u32) {
        self.put(key, value);
    }

    /// Drop `key`.
    pub fn remove(&mut self, key: u8) {
        if let Some(at) = index(key) {
            self.present &= !(1 << at);
            self.order.retain(|&k| k != key);
        }
    }

    /// The value of `key` as a byte, when it is one.
    pub fn byte(&self, key: u8) -> Option<u8> {
        self.get(key).and_then(|value| u8::try_from(value).ok())
    }

    /// The action (`a`; `t` when absent). For a command Ghostty takes
    /// (`parse`) it is one of `t`, `T`, `q`, `p`, `d`, `f`, `a` and `c`.
    pub fn action(&self) -> u8 {
        match self.get(b'a') {
            None => b't',
            Some(value) => u8::try_from(value).unwrap_or(0),
        }
    }

    /// Whether the action transmits data (`t`, `T`, `q`, `f`): the only
    /// ones whose medium Ghostty reads.
    pub fn transmits(&self) -> bool {
        matches!(self.action(), b't' | b'T' | b'q' | b'f')
    }

    /// Where the data of a command that transmits is (`t`); None for any
    /// other action, or a medium Ghostty does not know.
    pub fn medium(&self) -> Option<Medium> {
        if !self.transmits() {
            return None;
        }
        match self.get(b't').map(u8::try_from) {
            None => Some(Medium::Direct),
            Some(Ok(b'd')) => Some(Medium::Direct),
            Some(Ok(b'f')) => Some(Medium::File),
            Some(Ok(b't')) => Some(Medium::Temporary),
            Some(Ok(b's')) => Some(Medium::Shared),
            Some(_) => None,
        }
    }

    /// Whether it names a medium other than its own payload (`t` given,
    /// and not `d`), whatever its action: a command a terminal that reads
    /// files must never get.
    pub fn names_medium(&self) -> bool {
        self.get(b't').is_some_and(|t| t != u32::from(b'd'))
    }

    /// Whether renderers may get the command (`q=2` added): its action is
    /// one they carry out silently (not a query, which the host answers),
    /// it names no medium but its payload, and its compression and format,
    /// when given, are ones Ghostty knows.
    pub fn for_renderers(&self) -> bool {
        matches!(
            self.action(),
            b't' | b'T' | b'p' | b'd' | b'f' | b'a' | b'c'
        ) && !self.names_medium()
            && self.get(b'o').is_none_or(|o| o == u32::from(b'z'))
            && self
                .get(b'f')
                .is_none_or(|f| matches!(f, 0 | 24 | 32 | 100))
    }

    /// `q`: 0 answers everything, 1 errors only, more nothing.
    pub fn quiet(&self) -> u32 {
        self.get(b'q').unwrap_or(0)
    }

    /// Whether more chunks of this transmission follow (`m` above 0, which
    /// Ghostty reads only for a direct transmission).
    pub fn more(&self) -> bool {
        self.medium() == Some(Medium::Direct) && self.get(b'm').is_some_and(|m| m > 0)
    }

    /// The keys given, in order.
    pub fn keys(&self) -> impl Iterator<Item = u8> + '_ {
        self.order.iter().copied()
    }

    /// The control data again, as `k=v,…` (the keys `keep` keeps, in the
    /// order they were first given, each once with its value): letter
    /// values of `a`, `t`, `o` and `d` as the letter, everything else as a
    /// number in base 10. Ghostty reads it exactly as it read the original,
    /// but for the keys left out, and so do terminals that take only the
    /// letters.
    pub fn encode(&self, mut keep: impl FnMut(u8) -> bool) -> Vec<u8> {
        use std::io::Write as _;
        let mut out = Vec::with_capacity(self.order.len() * 6);
        for &key in &self.order {
            let Some(value) = self.get(key).filter(|_| keep(key)) else {
                continue;
            };
            if !out.is_empty() {
                out.push(b',');
            }
            out.push(key);
            out.push(b'=');
            match u8::try_from(value) {
                Ok(letter) if lettered(key) && letter.is_ascii_alphabetic() => out.push(letter),
                _ if signed(key) => {
                    let _ = write!(out, "{}", value as i32);
                }
                _ => {
                    let _ = write!(out, "{value}");
                }
            }
        }
        out
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum State {
    Key,
    KeyIgnore,
    Value,
    ValueIgnore,
    Payload,
}

/// Ghostty's parser, over a command's bytes after `ESC _ G`, one at a time
/// (see the module's documentation).
#[derive(Clone, Debug)]
pub struct Parser {
    state: State,
    temp: [u8; TEMP],
    len: usize,
    key: u8,
    control: Control,
    /// A value was not one Ghostty takes: it refuses the command.
    failed: bool,
}

impl Default for Parser {
    fn default() -> Self {
        Self {
            state: State::Key,
            temp: [0; TEMP],
            len: 0,
            key: 0,
            control: Control::default(),
            failed: false,
        }
    }
}

impl Parser {
    pub fn new() -> Self {
        Self::default()
    }

    /// Read the next byte of the command: true when it is the `;` that
    /// ends its control data (what follows is the payload, which the parser
    /// does not read).
    pub fn feed(&mut self, byte: u8) -> bool {
        if byte >= 0xa0 {
            // Ghostty's parser of escape sequences never hands these over:
            // it ignores them in a command.
            return false;
        }
        match self.state {
            State::Key => match byte {
                b'=' => {
                    if self.len == 1 {
                        self.key = self.temp[0];
                        self.state = State::Value;
                    } else {
                        // Keys are one byte: one of any other length is
                        // ignored, with its value.
                        self.state = State::ValueIgnore;
                    }
                    self.len = 0;
                }
                b';' => {
                    self.state = State::Payload;
                    return true;
                }
                _ => self.accumulate(byte, State::KeyIgnore),
            },
            State::KeyIgnore => {
                if byte == b'=' {
                    self.state = State::ValueIgnore;
                }
            }
            State::Value => match byte {
                b',' => self.finish_value(State::Key),
                b';' => {
                    self.finish_value(State::Payload);
                    return true;
                }
                _ => self.accumulate(byte, State::ValueIgnore),
            },
            State::ValueIgnore => match byte {
                b',' => self.state = State::KeyIgnore,
                b';' => {
                    self.state = State::Payload;
                    return true;
                }
                _ => {}
            },
            State::Payload => {}
        }
        false
    }

    /// Whether the payload began (`feed` returned true).
    pub fn in_payload(&self) -> bool {
        self.state == State::Payload
    }

    /// The control data so far, whatever Ghostty would make of the command.
    pub fn control(&self) -> &Control {
        &self.control
    }

    /// The command's control data, once all of it was fed (to the payload,
    /// or the command's end): None for a command Ghostty refuses.
    pub fn finish(mut self) -> Option<Control> {
        match self.state {
            // Control data that ends with a key, or nothing.
            State::Key | State::KeyIgnore => return None,
            State::Value => self.finish_value(State::Payload),
            State::ValueIgnore | State::Payload => {}
        }
        if self.failed {
            return None;
        }
        let control = self.control;
        let letter = |key: u8| -> Option<Option<u8>> {
            match control.get(key) {
                None => Some(None),
                Some(value) => u8::try_from(value).ok().map(Some),
            }
        };
        match letter(b'a')?.unwrap_or(b't') {
            b't' | b'T' | b'q' | b'f' => {
                if !matches!(letter(b't')?, None | Some(b'd' | b'f' | b't' | b's')) {
                    return None;
                }
                if !matches!(letter(b'o')?, None | Some(b'z')) {
                    return None;
                }
            }
            b'd' => {
                if !matches!(
                    letter(b'd')?,
                    None | Some(
                        b'a' | b'A'
                            | b'i'
                            | b'I'
                            | b'n'
                            | b'N'
                            | b'c'
                            | b'C'
                            | b'f'
                            | b'F'
                            | b'p'
                            | b'P'
                            | b'q'
                            | b'Q'
                            | b'r'
                            | b'R'
                            | b'x'
                            | b'X'
                            | b'y'
                            | b'Y'
                            | b'z'
                            | b'Z'
                    )
                ) {
                    return None;
                }
            }
            b'p' | b'a' | b'c' => {}
            _ => return None,
        }
        Some(control)
    }

    fn accumulate(&mut self, byte: u8, overflow: State) {
        if self.len == TEMP {
            self.state = overflow;
            self.len = 0;
            return;
        }
        self.temp[self.len] = byte;
        self.len += 1;
    }

    fn finish_value(&mut self, next: State) {
        self.state = next;
        let text = &self.temp[..self.len];
        self.len = 0;
        if let [byte] = *text {
            if !byte.is_ascii_digit() {
                self.control.put(self.key, u32::from(byte));
                return;
            }
        }
        match number(text, signed(self.key)) {
            Some(value) => self.control.put(self.key, value),
            None => self.failed = true,
        }
    }
}

/// `text` as Zig's `std.fmt.parseInt` reads it in base 10: an optional
/// sign, then digits with `_` between them; as an `i32` (its bits) when
/// `signed`, else a `u32` (where only `-0` is negative). None when it is
/// not such a number, or does not fit.
fn number(text: &[u8], signed: bool) -> Option<u32> {
    let (negative, digits) = match text.first()? {
        b'+' => (false, &text[1..]),
        b'-' => (true, &text[1..]),
        _ => (false, text),
    };
    if digits.first().is_none_or(|&b| b == b'_') || digits.last() == Some(&b'_') {
        return None;
    }
    let digits = digits.iter().filter(|&&b| b != b'_');
    if signed {
        let mut value: i32 = 0;
        for &byte in digits {
            let digit = i32::from(byte.is_ascii_digit().then(|| byte - b'0')?);
            value = value.checked_mul(10)?;
            value = if negative {
                value.checked_sub(digit)?
            } else {
                value.checked_add(digit)?
            };
        }
        Some(value as u32)
    } else {
        let mut value: u32 = 0;
        for &byte in digits {
            let digit = u32::from(byte.is_ascii_digit().then(|| byte - b'0')?);
            value = value.checked_mul(10)?;
            value = if negative {
                value.checked_sub(digit)?
            } else {
                value.checked_add(digit)?
            };
        }
        Some(value)
    }
}

/// A command as Ghostty reads it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Command<'a> {
    pub control: Control,
    /// What follows the `;` that ends the control data; None without one.
    pub payload: Option<&'a [u8]>,
}

/// The command whose bytes between `ESC _ G` and `ESC \` are `body`, as
/// Ghostty reads it; None for one it refuses.
pub fn parse(body: &[u8]) -> Option<Command<'_>> {
    let mut parser = Parser::new();
    let mut payload = None;
    for (at, &byte) in body.iter().enumerate() {
        if parser.feed(byte) {
            payload = Some(&body[at + 1..]);
            break;
        }
    }
    Some(Command {
        control: parser.finish()?,
        payload,
    })
}

/// The command `control` and `payload` make, for a renderer: `ESC _ G`,
/// the control data as `Control::encode` writes it but `q`, then `q=2` (a
/// renderer stays silent: the host answers), then `;` and the payload when
/// there is one (without the bytes Ghostty ignores), and `ESC \`.
pub fn silenced(control: &Control, payload: Option<&[u8]>) -> Vec<u8> {
    let keys = control.encode(|key| key != b'q');
    let mut out = Vec::with_capacity(keys.len() + payload.map_or(0, <[u8]>::len) + 12);
    out.extend_from_slice(b"\x1b_G");
    out.extend(keys);
    if out.len() > 3 {
        out.push(b',');
    }
    out.extend_from_slice(b"q=2");
    if let Some(payload) = payload {
        out.push(b';');
        out.extend(payload.iter().filter(|&&b| b < 0xa0));
    }
    out.extend_from_slice(b"\x1b\\");
    out
}

/// What renderers get of a kitty graphics command whose bytes between
/// `ESC _ G` and its end are `body`: the command as Ghostty reads it,
/// `silenced`, when `Control::for_renderers` allows it and its control data
/// names no medium even read loosely (`may_name_medium`). None for one only
/// the host may get: a query, one that names a file, a temporary file or
/// shared memory however it is written, or one Ghostty refuses.
pub fn for_renderers(body: &[u8]) -> Option<Vec<u8>> {
    let control = &body[..body.iter().position(|&b| b == b';').unwrap_or(body.len())];
    if may_name_medium(control) {
        return None;
    }
    let command = parse(body)?;
    command
        .control
        .for_renderers()
        .then(|| silenced(&command.control, command.payload))
}

/// Whether control data (`control`: a command's bytes after `ESC _ G` up to
/// its first `;`, or all of them without one) may make a terminal read a
/// file, a temporary file or shared memory: its `t` key, as Ghostty reads
/// it, names anything but `d` (whatever the action, and whether or not
/// Ghostty takes the rest), or, read loosely as another terminal might (a
/// key or value with spaces around it, in either case, among items Ghostty
/// ignores), any `t` item has a value other than `d` (or 100).
pub fn may_name_medium(control: &[u8]) -> bool {
    let mut parser = Parser::new();
    for &byte in control {
        parser.feed(byte);
    }
    if parser.control().names_medium() {
        return true;
    }
    // In the value state the last value is not read yet.
    if parser.state == State::Value {
        parser.finish_value(State::Payload);
        if parser.control().names_medium() {
            return true;
        }
    }
    control.split(|&b| b == b',').any(|item| {
        let mut parts = item.splitn(2, |&b| b == b'=');
        let key = parts.next().unwrap_or_default().trim_ascii();
        let value = parts.next().map(<[u8]>::trim_ascii);
        key.eq_ignore_ascii_case(b"t")
            && value.is_some_and(|value| value != b"d" && number(value, false) != Some(100))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn control(text: &str) -> Option<Control> {
        parse(text.as_bytes()).map(|command| command.control)
    }

    fn medium(text: &str) -> Option<Medium> {
        control(text).and_then(|control| control.medium())
    }

    #[test]
    fn values_are_letters_or_numbers_as_ghostty_reads_them() {
        for text in [
            "t=f",
            "t=102",
            "t=0102",
            "t=+102",
            "t=1_02",
            "t=1__0_2",
            "t=00000102",
        ] {
            assert_eq!(medium(text), Some(Medium::File), "{text}");
        }
        assert_eq!(medium("t=116"), Some(Medium::Temporary));
        assert_eq!(medium("t=t"), Some(Medium::Temporary));
        assert_eq!(medium("t=115"), Some(Medium::Shared));
        assert_eq!(medium("t=100"), Some(Medium::Direct));
        for (text, action) in [
            ("a=84", b'T'),
            ("a=+116", b't'),
            ("a=113", b'q'),
            ("a=1_12", b'p'),
            ("a=T", b'T'),
            ("", b't'),
        ] {
            let command = format!("{text};AAAA");
            let parsed = parse(command.as_bytes()).expect(text);
            assert_eq!(parsed.control.action(), action, "{text}");
            assert_eq!(parsed.payload, Some(&b"AAAA"[..]));
        }
        assert_eq!(medium("a=84,t=102"), Some(Medium::File));
        assert_eq!(medium("a=+116,t=f"), Some(Medium::File));
        // Any other single byte is itself.
        let parsed = control("i=x,X=-,Y=+,z=_").unwrap();
        assert_eq!(parsed.get(b'i'), Some(u32::from(b'x')));
        assert_eq!(parsed.get(b'X'), Some(u32::from(b'-')));
        assert_eq!(parsed.get(b'Y'), Some(u32::from(b'+')));
        assert_eq!(parsed.get(b'z'), Some(u32::from(b'_')));
        // Signed keys, and the last value of a key given twice.
        let parsed = control("z=-5,H=-2147483648,V=+7,i=1,i=2").unwrap();
        assert_eq!(parsed.get(b'z'), Some(-5i32 as u32));
        assert_eq!(parsed.get(b'H'), Some(i32::MIN as u32));
        assert_eq!(parsed.get(b'V'), Some(7));
        assert_eq!(parsed.get(b'i'), Some(2));
        assert_eq!(control("i=-0").unwrap().get(b'i'), Some(0));
        assert_eq!(control("i=4294967295").unwrap().get(b'i'), Some(u32::MAX));
    }

    #[test]
    fn commands_ghostty_refuses_are_refused() {
        for text in [
            // Not a byte, or not a medium, action, compression or deletion
            // Ghostty knows.
            "t=358",
            "t=F",
            "t=x",
            "a=z,i=31",
            "a=84,t=f,o=x",
            "a=d,d=w",
            "a=d,d=356",
            // Numbers Zig does not read.
            "t=",
            "t= f",
            "t=f ",
            "t=1 02",
            "t=_102",
            "t=102_",
            "t=-102",
            "t=0x66",
            "i=4294967296",
            "z=-2147483649",
            "i=-1",
            // Control data that ends without a value.
            "",
            "a=t,",
            "a=t,b",
            "aaaaaaaaaaaa",
        ] {
            assert_eq!(control(text), None, "{text:?}");
        }
        // Not medium, compression or deletion checks where Ghostty makes
        // none.
        assert!(control("a=p,t=x,o=q").is_some());
        assert!(control("a=d,t=x").is_some());
    }

    #[test]
    fn keys_ghostty_ignores_leave_the_rest_unread() {
        for text in [
            // A key of another length, or none, and all that follows.
            " t=f",
            "T=f",
            "tt=f",
            "=f,t=f",
            "hello=world,t=f",
            "a=t,,t=f",
            "a=t,f,t=f",
            // A value too long to keep, and all that follows.
            "i=123456789012,t=f",
            // A non-letter key is read (its value must be a number) but not
            // kept.
            "!=1",
        ] {
            let parsed = control(text).unwrap_or_else(|| panic!("{text:?}"));
            assert!(!parsed.names_medium(), "{text:?}");
            assert_eq!(parsed.medium(), Some(Medium::Direct), "{text:?}");
        }
        assert_eq!(control("!=abc"), None);
        // A `;` that a key too long to keep swallows does not begin the
        // payload: the next one past a value does.
        let parsed = parse(b"t=f,aaaaaaaaaaaaa;junk=x;cGF0aA==").unwrap();
        assert_eq!(parsed.control.medium(), Some(Medium::File));
        assert_eq!(parsed.payload, Some(&b"cGF0aA=="[..]));
        assert_eq!(parse(b"a=t;x;y").unwrap().payload, Some(&b"x;y"[..]));
        assert_eq!(parse(b"a=p").unwrap().payload, None);
    }

    #[test]
    fn control_data_is_written_back_as_ghostty_reads_it() {
        let parsed = control("a=84,t=100,i=+05,z=-3,o=122,f=d,q=1,C=x,q=0").unwrap();
        assert_eq!(
            parsed.encode(|_| true),
            b"a=T,t=d,i=5,z=-3,o=z,f=100,q=0,C=120"
        );
        assert_eq!(
            parsed.encode(|key| key != b'q'),
            b"a=T,t=d,i=5,z=-3,o=z,f=100,C=120"
        );
        assert_eq!(
            control(&String::from_utf8(parsed.encode(|_| true)).unwrap()),
            Some(parsed)
        );
        assert_eq!(control("a=p,!=1,i=3").unwrap().encode(|_| true), b"a=p,i=3");
    }

    #[test]
    fn renderers_get_only_commands_that_read_their_payload() {
        for text in [
            "a=T,f=100,i=1",
            "t=d",
            "t=100",
            "a=p,U=1",
            "a=d,d=a",
            "a=f,i=1",
            "m=1",
            "a=a,s=3",
            "a=c",
        ] {
            assert!(control(text).unwrap().for_renderers(), "{text}");
        }
        for text in [
            "a=q", "a=113", "t=f", "t=102", "a=p,t=f", "a=d,t=s", "a=p,o=x", "f=7",
        ] {
            assert!(!control(text).unwrap().for_renderers(), "{text}");
        }
    }

    /// What the pinned libghostty-vt answers `control` (with `i=1,s=1,v=1,
    /// f=24` before it, and three bytes of pixels): nothing when it refused
    /// the command, else its reply. Its terminal reads no file (Cherry
    /// never enables a medium), so it says "unsupported medium" for one.
    fn ghostty(terminal: &mut crate::Terminal, control: &str) -> Option<String> {
        let reply =
            terminal.feed(format!("\x1b_Gi=1,s=1,v=1,f=24,{control};AAAA\x1b\\").as_bytes());
        (!reply.is_empty()).then(|| String::from_utf8_lossy(&reply).into_owned())
    }

    /// Check `control` against libghostty-vt: it takes it exactly when
    /// `parse` does (as far as its answers tell), and refuses a medium
    /// exactly when `medium` names one.
    fn agrees(terminal: &mut crate::Terminal, control: &str) {
        let full = format!("i=1,s=1,v=1,f=24,{control};AAAA");
        let parsed = parse(full.as_bytes());
        let theirs = ghostty(terminal, control);
        // Ghostty also refuses a payload that is not base64, which `parse`
        // does not look at: a `;` in `control` may begin the payload.
        // A deletion never answers.
        let answers = |c: &Command| c.payload == Some(b"AAAA") && c.control.action() != b'd';
        if parsed.as_ref().is_none_or(answers) || theirs.is_some() {
            assert_eq!(
                parsed.is_some(),
                theirs.is_some(),
                "{control:?}: {theirs:?}"
            );
        }
        let ours = parsed.map(|c| c.control);
        let (Some(ours), Some(theirs)) = (ours, theirs) else {
            return;
        };
        let names = ours.medium().is_some_and(|medium| medium != Medium::Direct);
        assert_eq!(
            names,
            theirs.contains("unsupported medium"),
            "{control:?}: {theirs:?}"
        );
        assert_eq!(
            names,
            ours.names_medium() && ours.transmits(),
            "{control:?}"
        );
    }

    #[test]
    fn ghostty_reads_control_data_as_parse_does() {
        crate::graphics::install_png_decoder();
        let mut terminal = crate::Terminal::new(10, 5, 0).unwrap();
        terminal
            .set_image_storage_limit(crate::IMAGE_STORAGE_BYTES)
            .unwrap();
        for control in [
            "t=f",
            "t=102",
            "t=0102",
            "t=+102",
            "t=1_02",
            "t=116",
            "t=115",
            "t=100",
            "t=d",
            "a=84,t=f",
            "a=+116,t=102",
            "a=113,t=116",
            "a=T",
            "a=84",
            "a=q,t=s",
            "t=F",
            "T=f",
            " t=f",
            "t= f",
            "t=f ",
            "t=358",
            "t=-102",
            "t=",
            "a=t,,t=f",
            "a=t,f,t=f",
            "x=123456789012,t=f",
            "t=f,aaaaaaaaaaaaa;junk=x",
            "a=z",
            "a=p,t=f",
            "a=112",
            "t=f,o=x",
            "t=f,o=122",
            "z=-5,t=1__0_2",
            "t=00000000102",
            "t=000000000102",
        ] {
            agrees(&mut terminal, control);
        }
        // Random control data from pieces Ghostty reads in every way.
        let keys: &[&str] = &[
            "a", "t", "o", "x", "y", "z", "c", "r", "T", " t", "tt", "!", "", "t ",
        ];
        let values: &[&str] = &[
            "t",
            "T",
            "q",
            "p",
            "z",
            "f",
            "s",
            "d",
            "102",
            "116",
            "115",
            "100",
            "84",
            "+116",
            "0102",
            "1_02",
            "_1",
            "1_",
            "-0",
            "-1",
            "358",
            "",
            " ",
            "f ",
            "4294967296",
            "123456789012",
            "x",
            "=",
            "-",
            "+",
            "122",
            "112",
            "113",
        ];
        let mut state = 0x9e37_79b9_u32;
        let mut next = |n: usize| {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            state as usize % n
        };
        for _ in 0..4000 {
            let mut control = String::new();
            for item in 0..1 + next(4) {
                if item > 0 {
                    control.push(if next(20) == 0 { ';' } else { ',' });
                }
                control.push_str(keys[next(keys.len())]);
                if next(12) != 0 {
                    control.push('=');
                    control.push_str(values[next(values.len())]);
                }
            }
            agrees(&mut terminal, &control);
        }
    }

    #[test]
    fn a_medium_is_found_however_it_is_written() {
        for text in [
            "t=f",
            "t=102",
            "t=0102",
            "t=+102",
            "t=1_02",
            "t=116",
            "t=t",
            "t=115",
            "a=p,t=f",
            "t=F",
            "T=f",
            " t=f",
            "t= f",
            "t=f ",
            "t=358",
            "a=t,,t=f",
            "i=123456789012,t=f",
            "t=",
            "t=100,t=f",
        ] {
            assert!(may_name_medium(text.as_bytes()), "{text:?}");
        }
        for text in [
            "",
            "a=T,f=100,i=1",
            "t=d",
            "t=100",
            "t=+100",
            "a=t,t=d,q=2",
            " t = d ",
            "a=p,U=1,i=3",
            "m=1",
        ] {
            assert!(!may_name_medium(text.as_bytes()), "{text:?}");
        }
    }
}
