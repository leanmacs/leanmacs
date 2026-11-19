//! The contract of the files port: the rules every [`Files`] keeps, as a
//! check that runs one.
//!
//! [`check`] runs every property in a fresh subdirectory of a directory its
//! caller owns, and returns the names of those that fail. Each makes only
//! what is inside its own subdirectory, through the [`Ground`] it is given.
//!
//! Ignore-file semantics are not in the contract: the fake has no ignore
//! files. [`EXCLUDED`] asks the ground to exclude a path by whatever means
//! the implementation honours (the fake's list, or an ignore file the real
//! ground writes); what each ignore file means is pinned by the adapter's
//! own tests.
//!
//! Seen to bite: each property fails on an implementation written in this
//! module's tests to break it, and on no other property's.
//!
//! # The ground
//!
//! The port has no way to make a file. The check needs files, so its caller
//! supplies them as a [`Ground`]: for the fake, its tree in memory
//! ([`FakeFiles::ground`](crate::fake::FakeFiles::ground)); for a real
//! adapter, `std::fs` in a temporary directory.
//!
//! # Where an addition goes
//!
//! A new rule is a named `pub const`, an entry of [`PROPERTIES`], a step of
//! [`check`], and in this module's tests an implementation written to break
//! it.

use std::path::{Path, PathBuf};

use crate::{Files, Flow, Read, RefusalKind};

/// What [`check`] needs done that the port has no method for. It must not
/// be built on the [`Files`] being checked. Each method panics if it cannot
/// do what it is asked: the check's directory is its caller's own.
pub trait Ground {
    /// Writes `bytes` to the file at `path`, making it and the directories
    /// above it if they are not there.
    fn write(&self, path: &Path, bytes: &[u8]);

    /// Makes the directory `path` and the directories above it.
    fn make_dir(&self, path: &Path);

    /// Has the walk leave out `path`, a file or a directory, and everything
    /// under it: the fake lists it, a real ground writes an ignore file the
    /// adapter honours.
    fn exclude(&self, path: &Path);
}

/// Files are walked depth first, each directory's entries by the bytes of
/// their names: `a/b` before `a-c`.
pub const ORDER: &str = "files are walked depth first, each directory's entries by name";
/// An entry whose name starts with `.` is not walked, nor anything under
/// it.
pub const HIDDEN: &str = "a hidden entry is not walked, nor anything under it";
/// An excluded file, and everything under an excluded directory, is not
/// walked.
pub const EXCLUDED: &str = "an excluded entry is not walked, nor anything under it";
/// A walk visits files, never a directory, an empty one among them.
pub const FILES_ONLY: &str = "a walk visits files alone";
/// An empty file has no rows.
pub const EMPTY: &str = "an empty file has no rows";
/// Rows are numbered from 0, each with the byte offset of its start, and a
/// line feed at the end makes no row after it.
pub const NUMBERED: &str = "rows are numbered from 0 with the offsets of their starts";
/// The last row is a row though no line feed ends it.
pub const LAST_ROW: &str = "the last row without a line feed is a row";
/// A `\r` before a line feed is kept in the row's text.
pub const CARRIAGE_RETURN: &str = "a carriage return is kept in its row";
/// A row that is not UTF-8 is decoded lossily.
pub const LOSSY: &str = "a row that is not UTF-8 is decoded lossily";
/// `holds` is asked of each row once, in order, and only the rows it held
/// for are visited.
pub const HOLDS: &str = "holds is asked once a row and only held rows are visited";
/// [`Flow::Stop`] ends a walk and a read.
pub const STOP: &str = "a stop ends a walk and a read";
/// A file with a NUL byte is [`Read::Binary`], and no row of it is
/// visited.
pub const BINARY: &str = "a binary file is binary and no row of it is visited";
/// A root that is not there is [`RefusalKind::NotFound`], and a file given
/// as the root [`RefusalKind::NotADirectory`].
pub const REFUSED: &str = "a root not there, or a file, is refused as such";

/// Every property, by name.
pub const PROPERTIES: [&str; 13] = [
    ORDER,
    HIDDEN,
    EXCLUDED,
    FILES_ONLY,
    EMPTY,
    NUMBERED,
    LAST_ROW,
    CARRIAGE_RETURN,
    LOSSY,
    HOLDS,
    STOP,
    BINARY,
    REFUSED,
];

/// Holds `files` to the contract in fresh subdirectories of `dir`, which
/// is there and empty, made through `ground`, and returns the names of the
/// properties that fail: none when it keeps them all.
pub fn check(files: &impl Files, ground: &impl Ground, dir: &Path) -> Vec<&'static str> {
    let steps: [(&'static str, Step<_, _>); 13] = [
        (ORDER, order),
        (HIDDEN, hidden),
        (EXCLUDED, excluded),
        (FILES_ONLY, files_only),
        (EMPTY, empty),
        (NUMBERED, numbered),
        (LAST_ROW, last_row),
        (CARRIAGE_RETURN, carriage_return),
        (LOSSY, lossy),
        (HOLDS, holds),
        (STOP, stop),
        (BINARY, binary),
        (REFUSED, refused),
    ];
    steps
        .into_iter()
        .enumerate()
        .filter_map(|(index, (name, step))| {
            let here = dir.join(format!("p{index}"));
            ground.make_dir(&here);
            (!step(files, ground, &here)).then_some(name)
        })
        .collect()
}

/// One property: whether `files` keeps it in `dir`.
type Step<F, G> = fn(&F, &G, &Path) -> bool;

/// The paths a walk of `root` visits, or none when it is refused.
fn walked(files: &impl Files, root: &Path) -> Option<Vec<PathBuf>> {
    let mut seen = Vec::new();
    files
        .walk(root, &mut |path| {
            seen.push(path.to_path_buf());
            Flow::Go
        })
        .ok()?;
    Some(seen)
}

/// Rows as (number, offset, text).
type Rows = Vec<(usize, usize, String)>;

/// What a read of `path` visits, as (number, offset, text), with `holds`
/// holding for every row, and what it came to; none when refused.
fn read_all(files: &impl Files, path: &Path) -> Option<(Read, Rows)> {
    let mut rows = Vec::new();
    let read = files
        .rows(path, &mut |_| true, &mut |row| {
            rows.push((row.number, row.offset, row.text.to_owned()));
            Flow::Go
        })
        .ok()?;
    Some((read, rows))
}

/// The rows `bytes` reads as when every row is held, written to a file in
/// `dir`.
fn rows_of(
    files: &impl Files,
    ground: &impl Ground,
    dir: &Path,
    bytes: &[u8],
) -> Option<(Read, Rows)> {
    let path = dir.join("f");
    ground.write(&path, bytes);
    read_all(files, &path)
}

/// Paths from their spellings.
fn paths(spelled: &[&str]) -> Vec<PathBuf> {
    spelled.iter().map(PathBuf::from).collect()
}

/// A row as (number, offset, text).
fn row(number: usize, offset: usize, text: &str) -> (usize, usize, String) {
    (number, offset, text.to_owned())
}

fn order(files: &impl Files, ground: &impl Ground, dir: &Path) -> bool {
    for name in ["b", "a-c", "a/b", "a/a/z", "a0"] {
        ground.write(&dir.join(name), b"x\n");
    }
    walked(files, dir) == Some(paths(&["a/a/z", "a/b", "a-c", "a0", "b"]))
}

fn hidden(files: &impl Files, ground: &impl Ground, dir: &Path) -> bool {
    for name in [".hidden", ".git/config", "d/.x", "d/y", ".d/z", "e"] {
        ground.write(&dir.join(name), b"x\n");
    }
    walked(files, dir) == Some(paths(&["d/y", "e"]))
}

fn excluded(files: &impl Files, ground: &impl Ground, dir: &Path) -> bool {
    for name in ["keep", "skip", "gen/x", "gen/y/z", "sub/skip", "sub/keep"] {
        ground.write(&dir.join(name), b"x\n");
    }
    ground.exclude(&dir.join("skip"));
    ground.exclude(&dir.join("gen"));
    walked(files, dir) == Some(paths(&["keep", "sub/keep", "sub/skip"]))
}

fn files_only(files: &impl Files, ground: &impl Ground, dir: &Path) -> bool {
    ground.make_dir(&dir.join("empty"));
    ground.write(&dir.join("d/f"), b"x");
    walked(files, dir) == Some(paths(&["d/f"]))
}

fn empty(files: &impl Files, ground: &impl Ground, dir: &Path) -> bool {
    rows_of(files, ground, dir, b"") == Some((Read::Searched, Vec::new()))
}

fn numbered(files: &impl Files, ground: &impl Ground, dir: &Path) -> bool {
    rows_of(files, ground, dir, "x\nyé\n\nz\n".as_bytes())
        == Some((
            Read::Searched,
            vec![
                row(0, 0, "x"),
                row(1, 2, "yé"),
                row(2, 6, ""),
                row(3, 7, "z"),
            ],
        ))
}

fn last_row(files: &impl Files, ground: &impl Ground, dir: &Path) -> bool {
    rows_of(files, ground, dir, b"a\nbc")
        == Some((Read::Searched, vec![row(0, 0, "a"), row(1, 2, "bc")]))
        && rows_of(files, ground, dir, b"\n") == Some((Read::Searched, vec![row(0, 0, "")]))
}

fn carriage_return(files: &impl Files, ground: &impl Ground, dir: &Path) -> bool {
    rows_of(files, ground, dir, b"a\r\nb\r\n")
        == Some((Read::Searched, vec![row(0, 0, "a\r"), row(1, 3, "b\r")]))
}

fn lossy(files: &impl Files, ground: &impl Ground, dir: &Path) -> bool {
    rows_of(files, ground, dir, b"a\xffb\nc")
        == Some((
            Read::Searched,
            vec![row(0, 0, "a\u{fffd}b"), row(1, 4, "c")],
        ))
}

fn holds(files: &impl Files, ground: &impl Ground, dir: &Path) -> bool {
    let path = dir.join("f");
    ground.write(&path, b"one\ntwo\nthree\nfour\n");
    let mut asked = Vec::new();
    let mut visited = Vec::new();
    let read = files.rows(
        &path,
        &mut |text| {
            asked.push(text.to_owned());
            text.contains('o')
        },
        &mut |row| {
            visited.push(row.number);
            Flow::Go
        },
    );
    read == Ok(Read::Searched) && asked == ["one", "two", "three", "four"] && visited == [0, 1, 3]
}

fn stop(files: &impl Files, ground: &impl Ground, dir: &Path) -> bool {
    for name in ["a", "b", "c"] {
        ground.write(&dir.join(name), b"x\nx\nx\n");
    }
    let mut seen = Vec::new();
    let walk = files.walk(dir, &mut |path| {
        seen.push(path.to_path_buf());
        Flow::Stop
    });
    let mut visited = 0;
    let read = files.rows(&dir.join("a"), &mut |_| true, &mut |_| {
        visited += 1;
        Flow::Stop
    });
    walk.is_ok() && seen == paths(&["a"]) && read == Ok(Read::Searched) && visited == 1
}

fn binary(files: &impl Files, ground: &impl Ground, dir: &Path) -> bool {
    rows_of(files, ground, dir, b"x\nx\0y\nx\n") == Some((Read::Binary, Vec::new()))
}

fn refused(files: &impl Files, ground: &impl Ground, dir: &Path) -> bool {
    ground.write(&dir.join("f"), b"x");
    let kind = |files: &_, path: &Path| match Files::walk(files, path, &mut |_| Flow::Go) {
        Ok(()) => None,
        Err(refusal) => Some(refusal.kind),
    };
    kind(files, &dir.join("missing")) == Some(RefusalKind::NotFound)
        && kind(files, &dir.join("f")) == Some(RefusalKind::NotADirectory)
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::{
        BINARY, CARRIAGE_RETURN, EMPTY, EXCLUDED, FILES_ONLY, HIDDEN, HOLDS, LAST_ROW, LOSSY,
        NUMBERED, ORDER, PROPERTIES, REFUSED, STOP, check,
    };
    use crate::contract::Ground as _;
    use crate::fake::FakeFiles;
    use crate::{Files, Flow, Read, Refusal, RefusalKind, Row};

    /// The rule an implementation written here breaks.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum Flaw {
        /// Walks in the order of the paths' spellings.
        SpelledOrder,
        /// Walks hidden entries.
        WalksHidden,
        /// Walks excluded entries.
        WalksExcluded,
        /// Visits directories too.
        VisitsDirectories,
        /// Gives an empty file one empty row.
        EmptyRow,
        /// Numbers rows from 1.
        FromOne,
        /// Drops a last row with no line feed.
        DropsLastRow,
        /// Strips a `\r`.
        StripsReturn,
        /// Refuses a row that is not UTF-8.
        RefusesLossy,
        /// Visits every row, held or not.
        VisitsAll,
        /// Goes on after a stop.
        IgnoresStop,
        /// Reads a binary file as text.
        ReadsBinary,
        /// Refuses every root as failed.
        RefusesAsFailed,
    }

    /// The fake, with one rule broken.
    struct Flawed {
        /// The fake it is built on.
        inner: FakeFiles,
        /// The rule it breaks.
        flaw: Flaw,
    }

    impl Files for Flawed {
        fn walk(&self, root: &Path, visit: &mut dyn FnMut(&Path) -> Flow) -> Result<(), Refusal> {
            if self.flaw == Flaw::RefusesAsFailed {
                return Err(Refusal::new(RefusalKind::Failed, "no"));
            }
            let mut seen: Vec<_> = self
                .inner
                .listing(root)?
                .into_iter()
                .filter(|entry| {
                    (!entry.directory || self.flaw == Flaw::VisitsDirectories)
                        && (!entry.hidden || self.flaw == Flaw::WalksHidden)
                        && (!entry.excluded || self.flaw == Flaw::WalksExcluded)
                })
                .map(|entry| entry.relative)
                .collect();
            if self.flaw == Flaw::SpelledOrder {
                seen.sort_by(|a, b| a.as_os_str().cmp(b.as_os_str()));
            }
            for path in seen {
                if visit(&path) == Flow::Stop && self.flaw != Flaw::IgnoresStop {
                    break;
                }
            }
            Ok(())
        }

        fn rows(
            &self,
            path: &Path,
            holds: &mut dyn FnMut(&str) -> bool,
            visit: &mut dyn FnMut(Row<'_>) -> Flow,
        ) -> Result<Read, Refusal> {
            let bytes = self
                .inner
                .bytes(path)
                .ok_or_else(|| Refusal::new(RefusalKind::NotFound, path.display().to_string()))?;
            if bytes.contains(&0) && self.flaw != Flaw::ReadsBinary {
                return Ok(Read::Binary);
            }
            if self.flaw == Flaw::RefusesLossy && std::str::from_utf8(&bytes).is_err() {
                return Err(Refusal::new(RefusalKind::Failed, "not UTF-8"));
            }
            let mut texts: Vec<(usize, String)> = Vec::new();
            let mut offset = 0;
            for piece in bytes.split(|&byte| byte == b'\n') {
                texts.push((offset, String::from_utf8_lossy(piece).into_owned()));
                offset += piece.len() + 1;
            }
            let ends_in_feed = bytes.last() == Some(&b'\n');
            if ends_in_feed || (bytes.is_empty() && self.flaw != Flaw::EmptyRow) {
                texts.pop();
            }
            if !ends_in_feed && !bytes.is_empty() && self.flaw == Flaw::DropsLastRow {
                texts.pop();
            }
            for (number, (offset, text)) in texts.iter().enumerate() {
                let text = if self.flaw == Flaw::StripsReturn {
                    text.trim_end_matches('\r')
                } else {
                    text
                };
                let held = holds(text);
                if !held && self.flaw != Flaw::VisitsAll {
                    continue;
                }
                let number = if self.flaw == Flaw::FromOne {
                    number + 1
                } else {
                    number
                };
                let flow = visit(Row {
                    number,
                    offset: *offset,
                    text,
                });
                if flow == Flow::Stop && self.flaw != Flaw::IgnoresStop {
                    break;
                }
            }
            Ok(Read::Searched)
        }
    }

    /// The properties a fake with `flaw` fails; none for no flaw.
    fn failures(flaw: Option<Flaw>) -> Vec<&'static str> {
        let fake = FakeFiles::new();
        let ground = fake.ground();
        let dir = Path::new("/fake/contract");
        ground.make_dir(dir);
        match flaw {
            None => check(&fake, &ground, dir),
            Some(flaw) => check(&Flawed { inner: fake, flaw }, &ground, dir),
        }
    }

    #[test]
    fn the_fake_keeps_the_contract() {
        assert_eq!(failures(None), [""; 0]);
    }

    #[test]
    fn every_property_is_listed_once() {
        let mut names = PROPERTIES.to_vec();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), PROPERTIES.len());
    }

    #[test]
    fn each_broken_rule_fails_the_properties_that_rest_on_it() {
        let cases = [
            (Flaw::SpelledOrder, vec![ORDER]),
            (Flaw::WalksHidden, vec![HIDDEN]),
            (Flaw::WalksExcluded, vec![EXCLUDED]),
            (
                Flaw::VisitsDirectories,
                vec![ORDER, HIDDEN, EXCLUDED, FILES_ONLY],
            ),
            (Flaw::EmptyRow, vec![EMPTY]),
            (
                Flaw::FromOne,
                vec![NUMBERED, LAST_ROW, CARRIAGE_RETURN, LOSSY, HOLDS],
            ),
            (Flaw::DropsLastRow, vec![LAST_ROW, LOSSY]),
            (Flaw::StripsReturn, vec![CARRIAGE_RETURN]),
            (Flaw::RefusesLossy, vec![LOSSY]),
            (Flaw::VisitsAll, vec![HOLDS]),
            (Flaw::IgnoresStop, vec![STOP]),
            (Flaw::ReadsBinary, vec![BINARY]),
            (
                Flaw::RefusesAsFailed,
                vec![ORDER, HIDDEN, EXCLUDED, FILES_ONLY, STOP, REFUSED],
            ),
        ];
        for (flaw, expected) in cases {
            assert_eq!(failures(Some(flaw)), expected, "{flaw:?}");
        }
    }
}
