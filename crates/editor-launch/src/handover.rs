//! The hand-over record: what the launcher is handed when an editor is to
//! be started with a fallback. A restart writes it at
//! `<state>/session/handover` (Lean, `Editor.Restart.Handover.encode`),
//! once, naming the session the new run restores; a cold start that picks
//! a per-user editor writes it at `<data>/launch/cold-<pid>`
//! ([`crate::launch`], [`crate::editors`]), with no session. Only the
//! launcher and its watcher read or rewrite it, to add a `failed` line.
//!
//! The record is UTF-8 text, one field per line, each line ending in a
//! newline:
//!
//! ```text
//! leanmacs-handover 1
//! session <the index the new run restores>   (only a restart's)
//! shipped <the shipped default executable>
//! candidate <path>        (repeated, in the order they are tried)
//! argument <arg>          (repeated: the editor's own arguments)
//! failed <path>           (repeated: the launcher's)
//! ```
//!
//! A value is the rest of its line, with `\` written `\\` and a newline
//! written `\n`; nothing else is escaped. The first line is the version. A
//! record of a later version is refused with [`Refused::Newer`], so a
//! launcher never half-reads a format it does not know.
//!
//! A record with no `session` line is a cold start's. It is still format
//! 1: only the launcher that wrote it reads it back (its watcher's fallback
//! runs the same binary), and Lean only encodes, always with a session.
//!
//! # Where an addition goes
//!
//! A new field is a new line kind here, in [`decode`] and [`encode`], in
//! Lean's encoder (`lean/Editor/Restart/Handover.lean`) and in the fixture
//! both read, `tests/launch/handover-v1`; a field only the launcher writes
//! is in the cold fixture, `tests/launch/handover-cold`, which only the
//! Rust tests read. A field an older launcher must not skip raises
//! [`VERSION`]. Lean's encoding of the fixture's value is held to the same
//! file by `ContractTest.launchRecordChecks`
//! (`lean/ContractTest/Editor/Restart/Launch.lean`).
//!
//! The arguments the launcher execs a hand-over's candidate with
//! ([`crate::launch`]) are a fixture both sides read too,
//! `tests/launch/arguments-v1`, one a line: a new launch flag is a line
//! there, in the launcher's test of it
//! (`the_hand_over_exec_arguments_are_the_checked_in_fixture`) and in Lean's
//! `Editor.Restart.Launch.strip`, whose reading of the file
//! `ContractTest.launchRecordChecks` holds.

use std::fmt;
use std::path::PathBuf;

/// The format this launcher reads and writes.
pub const VERSION: u32 = 1;

/// The first word of the record's first line.
pub const MAGIC: &str = "leanmacs-handover";

/// A decoded record.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Handover {
    /// The session index the new run restores: a restart's. A cold
    /// start's record has none, and its editor restores as any start does.
    pub session: Option<PathBuf>,
    /// The shipped default executable.
    pub shipped: PathBuf,
    /// The executables to try, in order.
    pub candidates: Vec<PathBuf>,
    /// The editor's own arguments, handed on after the launch flags.
    pub arguments: Vec<String>,
    /// The candidates that failed, in the order they did.
    pub failed: Vec<PathBuf>,
}

impl Handover {
    /// Marks `candidate` failed, once.
    pub fn mark_failed(&mut self, candidate: &PathBuf) {
        if !self.failed.contains(candidate) {
            self.failed.push(candidate.clone());
        }
    }

    /// The first candidate not marked failed.
    #[must_use]
    pub fn next(&self) -> Option<&PathBuf> {
        self.candidates.iter().find(|c| !self.failed.contains(c))
    }
}

/// Why a record was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refused {
    /// Its version is later than [`VERSION`].
    Newer(u32),
    /// It is not a record this launcher can read, with the reason.
    Malformed(String),
}

impl fmt::Display for Refused {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Newer(v) => write!(
                f,
                "it is of format {v}, later than this launcher's {VERSION}"
            ),
            Self::Malformed(why) => write!(f, "it is not a hand-over record: {why}"),
        }
    }
}

/// `value` as a field's value: `\` as `\\` and a newline as `\n`.
#[must_use]
pub fn escape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for c in value.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            c => out.push(c),
        }
    }
    out
}

/// A field's value read back.
///
/// # Errors
///
/// A `\` followed by anything but `\` or `n`, or by nothing.
pub fn unescape(field: &str) -> Result<String, String> {
    let mut out = String::with_capacity(field.len());
    let mut chars = field.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('\\') => out.push('\\'),
                Some('n') => out.push('\n'),
                Some(other) => return Err(format!("an unknown escape \\{other}")),
                None => return Err("a \\ at the end of a line".to_owned()),
            }
        } else {
            out.push(c);
        }
    }
    Ok(out)
}

fn path_text(path: &std::path::Path) -> String {
    escape(&path.to_string_lossy())
}

/// The record's text; a record with no session has no `session` line.
#[must_use]
pub fn encode(handover: &Handover) -> String {
    let mut out = format!("{MAGIC} {VERSION}\n");
    if let Some(session) = &handover.session {
        out.push_str(&format!("session {}\n", path_text(session)));
    }
    out.push_str(&format!("shipped {}\n", path_text(&handover.shipped)));
    for c in &handover.candidates {
        out.push_str(&format!("candidate {}\n", path_text(c)));
    }
    for a in &handover.arguments {
        out.push_str(&format!("argument {}\n", escape(a)));
    }
    for f in &handover.failed {
        out.push_str(&format!("failed {}\n", path_text(f)));
    }
    out
}

/// Reads a record.
///
/// # Errors
///
/// [`Refused::Newer`] for a later version, and [`Refused::Malformed`] for
/// anything else this launcher cannot read: bytes that are not UTF-8, a
/// first line that is not the magic and a version, a field it does not
/// know, a bad escape, a missing `shipped`, or a last line with no newline.
/// A missing `session` is a cold start's record, and no fault.
pub fn decode(bytes: &[u8]) -> Result<Handover, Refused> {
    let malformed = |why: &str| Refused::Malformed(why.to_owned());
    let text = std::str::from_utf8(bytes).map_err(|_| malformed("it is not UTF-8"))?;
    let Some(body) = text.strip_suffix('\n') else {
        return Err(malformed("its last line has no newline"));
    };
    let mut lines = body.split('\n');
    let first = lines.next().unwrap_or_default();
    let version = first
        .strip_prefix(MAGIC)
        .and_then(|rest| rest.strip_prefix(' '))
        .and_then(|v| v.parse::<u32>().ok())
        .ok_or_else(|| malformed("its first line is not `leanmacs-handover <version>`"))?;
    if version > VERSION {
        return Err(Refused::Newer(version));
    }
    let mut shipped = None;
    let mut handover = Handover::default();
    for (n, line) in lines.enumerate() {
        let (key, field) = line
            .split_once(' ')
            .ok_or_else(|| Refused::Malformed(format!("line {} has no value", n + 2)))?;
        let value =
            unescape(field).map_err(|why| Refused::Malformed(format!("line {}: {why}", n + 2)))?;
        match key {
            "session" => handover.session = Some(PathBuf::from(value)),
            "shipped" => shipped = Some(PathBuf::from(value)),
            "candidate" => handover.candidates.push(PathBuf::from(value)),
            "argument" => handover.arguments.push(value),
            "failed" => handover.failed.push(PathBuf::from(value)),
            other => {
                return Err(Refused::Malformed(format!(
                    "line {} is a field it does not know, `{other}`",
                    n + 2
                )));
            }
        }
    }
    handover.shipped = shipped.ok_or_else(|| malformed("it names no shipped executable"))?;
    Ok(handover)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The fixture's value, which Lean's encoder must reproduce byte for
    /// byte (`ModelTest.restartHandoverChecks`).
    fn fixture() -> Handover {
        Handover {
            session: Some(
                "/Users/a/Library/Application Support/Leanmacs/session/session-3.json".into(),
            ),
            shipped: "/Applications/Leanmacs.app/Contents/MacOS/editor".into(),
            candidates: vec![
                "/Users/a/Library/Application Support/Leanmacs/executables/7/editor".into(),
                "/Applications/Leanmacs.app/Contents/MacOS/editor".into(),
            ],
            arguments: vec![
                "--state".into(),
                "/tmp/état\ttab".into(),
                "two\nlines and a \\ back".into(),
            ],
            failed: Vec::new(),
        }
    }

    #[test]
    fn the_checked_in_fixture_decodes_to_its_value_and_encodes_back() {
        let bytes = include_bytes!("../../../tests/launch/handover-v1");
        assert_eq!(decode(bytes), Ok(fixture()));
        assert_eq!(encode(&fixture()).as_bytes(), bytes);
    }

    /// The cold fixture's value: what a cold start writes
    /// (`crate::launch`), with no session.
    fn cold_fixture() -> Handover {
        Handover {
            session: None,
            shipped: "/Applications/Leanmacs.app/Contents/MacOS/editor".into(),
            candidates: vec![
                "/Users/a/.local/share/leanmacs/editors/3f9a0c/10/editor".into(),
                "/Users/a/.local/share/leanmacs/editors/3f9a0c/2/editor".into(),
                "/Applications/Leanmacs.app/Contents/MacOS/editor".into(),
            ],
            arguments: vec!["--state".into(), "/tmp/two words".into()],
            failed: Vec::new(),
        }
    }

    #[test]
    fn the_checked_in_cold_fixture_has_no_session_and_encodes_back() {
        let bytes = include_bytes!("../../../tests/launch/handover-cold");
        assert_eq!(decode(bytes), Ok(cold_fixture()));
        assert_eq!(encode(&cold_fixture()).as_bytes(), bytes);
        let mut failed = cold_fixture();
        failed.mark_failed(&failed.candidates[0].clone());
        assert_eq!(decode(encode(&failed).as_bytes()), Ok(failed));
    }

    #[test]
    fn a_record_round_trips_with_failed_lines() {
        let mut handover = fixture();
        handover.mark_failed(&"/x/bad".into());
        handover.mark_failed(&"/x/bad".into());
        assert_eq!(handover.failed, [PathBuf::from("/x/bad")]);
        assert_eq!(decode(encode(&handover).as_bytes()), Ok(handover));
    }

    #[test]
    fn escaping_keeps_backslashes_newlines_tabs_spaces_and_non_ascii() {
        for value in ["a\\b", "a\nb", "a\tb", " lead and trail ", "ü→∀", "\\n", ""] {
            assert_eq!(unescape(&escape(value)), Ok(value.to_owned()), "{value:?}");
            assert!(!escape(value).contains('\n'));
        }
        assert_eq!(escape("a\\b\nc"), "a\\\\b\\nc");
        assert!(unescape("a\\t").is_err());
        assert!(unescape("a\\").is_err());
    }

    #[test]
    fn a_later_version_is_refused() {
        assert_eq!(
            decode(b"leanmacs-handover 2\nsession /s\nshipped /e\nwhatever new\n"),
            Err(Refused::Newer(2))
        );
    }

    #[test]
    fn what_is_not_a_record_is_refused_with_why() {
        for bytes in [
            &b""[..],
            b"leanmacs-handover 1",
            b"something else 1\n",
            b"leanmacs-handover x\n",
            b"leanmacs-handover 1\nsession /s\n",
            b"leanmacs-handover 1\ncandidate /c\n",
            b"leanmacs-handover 1\nsession /s\nshipped /e\nnew /x\n",
            b"leanmacs-handover 1\nsession /s\nshipped /e\ncandidate\n",
            b"leanmacs-handover 1\nsession /s\\q\nshipped /e\n",
            b"leanmacs-handover 1\nsession \xff\nshipped /e\n",
        ] {
            assert!(
                matches!(decode(bytes), Err(Refused::Malformed(_))),
                "{:?}",
                String::from_utf8_lossy(bytes)
            );
        }
    }

    #[test]
    fn the_next_candidate_is_the_first_not_failed() {
        let mut handover = fixture();
        assert_eq!(handover.next(), Some(&handover.candidates[0].clone()));
        let first = handover.candidates[0].clone();
        handover.mark_failed(&first);
        assert_eq!(handover.next(), Some(&handover.candidates[1].clone()));
        let second = handover.candidates[1].clone();
        handover.mark_failed(&second);
        assert_eq!(handover.next(), None);
    }
}
