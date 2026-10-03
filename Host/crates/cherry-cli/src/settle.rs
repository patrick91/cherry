//! `attach --size-file`: the window size the supervising app settled on.
//!
//! A terminal that runs `cherry attach` as its child can report sizes its
//! window never settles at: Ghostty starts the child of a new surface at a
//! default size and gives it the view's a moment later, and a window going
//! into or out of full screen can lay its views out more than once. Each size
//! the attachment passes on resizes the session, and an inline program (one
//! that draws below its output, such as Claude Code) redraws for each,
//! leaving blank or repeated rows. The app that owns the window knows which
//! size is the one it settled on, and says so in this file:
//!
//! - `{"cols":C,"rows":R}`: the window's grid is C by R cells.
//! - `{"hold":true}`: its size is changing (a full-screen transition); a
//!   grid follows once it settled.
//!
//! The attachment attaches only once its terminal reports the grid the file
//! names, and after a hold sends a resize only once its terminal has the
//! grid the file names again: at most `SIZE_FILE_WAIT` each time, after
//! which it goes on with the size its terminal reports. A missing or
//! unreadable file names nothing: the attachment waits for it before
//! attaching, and after attaching it sends resizes as they come.
use serde::Deserialize;
use std::path::PathBuf;
use std::time::Duration;

/// The longest an attachment waits for the size file to name its window's
/// grid, before attaching or before resizing after a hold.
pub const SIZE_FILE_WAIT: Duration = Duration::from_secs(3);
/// How often a waiting attachment reads the file again (a resize of its
/// terminal wakes it at once too).
pub const SIZE_FILE_POLL: Duration = Duration::from_millis(10);

/// What the file says.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Settled {
    /// The window's size is changing.
    Hold,
    /// The window settled at this grid (columns, rows).
    Grid((u16, u16)),
}

#[derive(Deserialize)]
struct Record {
    #[serde(default)]
    hold: bool,
    cols: Option<u16>,
    rows: Option<u16>,
}

pub struct SizeFile {
    path: PathBuf,
}

impl SizeFile {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    /// What the file says now; None when it is missing or says nothing this
    /// version understands.
    pub fn read(&self) -> Option<Settled> {
        parse(&std::fs::read(&self.path).ok()?)
    }
}

fn parse(bytes: &[u8]) -> Option<Settled> {
    let record: Record = serde_json::from_slice(bytes).ok()?;
    if record.hold {
        return Some(Settled::Hold);
    }
    match (record.cols, record.rows) {
        (Some(cols), Some(rows)) if cols > 0 && rows > 0 => Some(Settled::Grid((cols, rows))),
        _ => None,
    }
}

/// Whether a window of `grid` cells may be passed on now, by what the file
/// says: before attaching, and after a hold.
pub fn settled_at(settled: Option<Settled>, grid: (u16, u16)) -> bool {
    settled == Some(Settled::Grid(grid))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_a_grid_or_a_hold_and_nothing_else() {
        assert_eq!(
            parse(br#"{"cols":98,"rows":29}"#),
            Some(Settled::Grid((98, 29)))
        );
        assert_eq!(parse(br#"{"hold":true}"#), Some(Settled::Hold));
        assert_eq!(
            parse(br#"{"hold":true,"cols":98,"rows":29}"#),
            Some(Settled::Hold)
        );
        assert_eq!(
            parse(br#"{"hold":false,"cols":98,"rows":29}"#),
            Some(Settled::Grid((98, 29)))
        );
        for nothing in [
            &br#"{"cols":98}"#[..],
            br#"{"cols":0,"rows":29}"#,
            br#"{"cols":98,"rows":-1}"#,
            br#"{"cols":"98","rows":29}"#,
            br#"{}"#,
            b"",
            b"{\"cols\":98,\"ro",
        ] {
            assert_eq!(parse(nothing), None, "{}", String::from_utf8_lossy(nothing));
        }
    }

    #[test]
    fn a_window_is_settled_only_at_the_grid_the_file_names() {
        assert!(settled_at(Some(Settled::Grid((98, 29))), (98, 29)));
        assert!(!settled_at(Some(Settled::Grid((98, 29))), (98, 35)));
        assert!(!settled_at(Some(Settled::Hold), (98, 29)));
        assert!(!settled_at(None, (98, 29)));
    }

    #[test]
    fn a_missing_file_names_nothing() {
        let directory = tempfile::tempdir().unwrap();
        let file = SizeFile::new(directory.path().join("size.json"));
        assert_eq!(file.read(), None);
        std::fs::write(
            directory.path().join("size.json"),
            br#"{"cols":80,"rows":24}"#,
        )
        .unwrap();
        assert_eq!(file.read(), Some(Settled::Grid((80, 24))));
    }
}
