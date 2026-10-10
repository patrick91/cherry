//! Program status records (OSC 7501): what the programs in a terminal say
//! they are doing. libghostty-vt checks each report against the
//! specification (https://www.superlogical.com/rex/docs/build/program-status)
//! and keeps nothing; the records are kept here, by the rules it gives its
//! embedder.
use crate::events::ProgramStatusReport;
pub use crate::events::{ProgramState, ProgramStatusKind};

/// At most this many records; a new one beyond it replaces the one updated
/// longest ago. The specification asks for at least 64.
pub const MAX_PROGRAM_STATUS_RECORDS: usize = 64;

/// One record: the latest report about its id.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProgramStatusRecord {
    /// Empty for the root record (the program itself); `/` separates a
    /// child from its parent.
    pub id: String,
    pub state: ProgramState,
    /// What a blocked program needs, when it said.
    pub kind: Option<ProgramStatusKind>,
    /// 0–100, only for `Working` and `Blocked`.
    pub progress: Option<u8>,
    /// A stable name for the program (`claude-code`, `cargo`), empty when
    /// it gave none.
    pub app: String,
    /// The program's text, decoded, without control or invisible
    /// formatting characters, but untrusted.
    pub title: String,
    pub message: String,
}

/// The records, the one updated longest ago first.
#[derive(Debug, Default)]
pub(crate) struct Records {
    records: Vec<ProgramStatusRecord>,
}

impl Records {
    pub(crate) fn records(&self) -> &[ProgramStatusRecord] {
        &self.records
    }

    /// Apply a report; whether the records changed. A report replaces its
    /// record whole; a clear removes the record and every record beneath
    /// it, or every record when its id is empty.
    pub(crate) fn apply(&mut self, report: ProgramStatusReport) -> bool {
        let Some(state) = report.state else {
            let before = self.records.len();
            if report.id.is_empty() {
                self.records.clear();
            } else {
                self.records
                    .retain(|record| !is_within(&record.id, &report.id));
            }
            return self.records.len() != before;
        };
        let record = ProgramStatusRecord {
            state,
            kind: report.kind,
            progress: report.progress,
            app: report.app,
            title: visible(&report.title),
            message: visible(&report.message),
            id: report.id,
        };
        let previous = self
            .records
            .iter()
            .position(|existing| existing.id == record.id)
            .map(|index| self.records.remove(index));
        let changed = previous.as_ref() != Some(&record);
        self.records.push(record);
        if self.records.len() > MAX_PROGRAM_STATUS_RECORDS {
            self.records.remove(0);
        }
        changed
    }

    /// The program that reported ended (it exited, or a shell started a new
    /// prompt): its `working`, `blocked` and `idle` records go; `done` and
    /// `error` stay until the user has seen them. Whether any went.
    pub(crate) fn end_program(&mut self) -> bool {
        let before = self.records.len();
        self.records
            .retain(|record| matches!(record.state, ProgramState::Done | ProgramState::Error));
        self.records.len() != before
    }
}

/// `id` is `ancestor` or beneath it.
fn is_within(id: &str, ancestor: &str) -> bool {
    id.strip_prefix(ancestor)
        .is_some_and(|rest| rest.is_empty() || rest.starts_with('/'))
}

/// Text without the invisible formatting characters a program could use to
/// make it read as something else: direction overrides and isolates, zero
/// width spaces and marks, word joiners and the byte order mark. The zero
/// width joiner stays, as emoji need it.
fn visible(text: &str) -> String {
    text.chars()
        .filter(|&c| {
            !matches!(c,
                '\u{00AD}' | '\u{061C}' | '\u{180E}'
                | '\u{200B}' | '\u{200C}' | '\u{200E}' | '\u{200F}'
                | '\u{202A}'..='\u{202E}'
                | '\u{2060}'..='\u{2064}'
                | '\u{2066}'..='\u{2069}'
                | '\u{FEFF}' | '\u{FFF9}'..='\u{FFFB}')
                && !c.is_control()
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn report(id: &str, state: Option<ProgramState>) -> ProgramStatusReport {
        ProgramStatusReport {
            state,
            kind: None,
            progress: None,
            id: id.into(),
            app: String::new(),
            title: String::new(),
            message: String::new(),
        }
    }

    fn ids(records: &Records) -> Vec<&str> {
        records
            .records()
            .iter()
            .map(|record| record.id.as_str())
            .collect()
    }

    #[test]
    fn a_report_replaces_its_record_whole() {
        let mut records = Records::default();
        assert!(records.apply(ProgramStatusReport {
            message: "Writing notes.txt".into(),
            ..report("", Some(ProgramState::Working))
        }));
        assert!(records.apply(report("", Some(ProgramState::Working))));
        assert_eq!(records.records()[0].message, "");
        // The same report again changes nothing.
        assert!(!records.apply(report("", Some(ProgramState::Working))));
        assert_eq!(records.records().len(), 1);
    }

    #[test]
    fn a_clear_removes_the_record_and_its_children_only() {
        let mut records = Records::default();
        for id in ["build", "build/test", "builder", "deploy"] {
            records.apply(report(id, Some(ProgramState::Working)));
        }
        assert!(records.apply(report("build", None)));
        assert_eq!(ids(&records), ["builder", "deploy"]);
        assert!(!records.apply(report("missing", None)));
        assert!(records.apply(report("", None)));
        assert!(records.records().is_empty());
    }

    #[test]
    fn the_record_updated_longest_ago_makes_room() {
        let mut records = Records::default();
        for n in 0..MAX_PROGRAM_STATUS_RECORDS {
            records.apply(report(&n.to_string(), Some(ProgramState::Working)));
        }
        // Updating "0" makes "1" the oldest.
        records.apply(report("0", Some(ProgramState::Done)));
        records.apply(report("new", Some(ProgramState::Working)));
        assert_eq!(records.records().len(), MAX_PROGRAM_STATUS_RECORDS);
        assert!(!ids(&records).contains(&"1"));
        assert!(ids(&records).contains(&"0"));
    }

    #[test]
    fn an_ended_program_keeps_only_what_the_user_has_not_seen() {
        let mut records = Records::default();
        records.apply(report("a", Some(ProgramState::Working)));
        records.apply(report("b", Some(ProgramState::Blocked)));
        records.apply(report("c", Some(ProgramState::Idle)));
        records.apply(report("d", Some(ProgramState::Done)));
        records.apply(report("e", Some(ProgramState::Error)));
        assert!(records.end_program());
        assert_eq!(ids(&records), ["d", "e"]);
        assert!(!records.end_program());
    }

    #[test]
    fn invisible_formatting_is_removed_from_the_text() {
        let mut records = Records::default();
        records.apply(ProgramStatusReport {
            title: "a\u{202E}b\u{200B}c".into(),
            message: "family 👨\u{200D}👩\u{2066}x\u{2069}".into(),
            ..report("", Some(ProgramState::Done))
        });
        assert_eq!(records.records()[0].title, "abc");
        assert_eq!(records.records()[0].message, "family 👨\u{200D}👩x");
    }
}
