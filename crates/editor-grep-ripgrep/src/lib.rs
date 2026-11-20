//! The project search port's real adapter: [`RipgrepFiles`], over
//! ripgrep's libraries. `ignore` walks a root as ripgrep does, honouring
//! `.gitignore`, `.ignore`, `.git/info/exclude`, the global excludes and
//! hidden files; `grep-searcher` reads a file a block at a time, numbers
//! its rows, detects a binary file and transcodes one with a UTF-16 byte
//! order mark. Which rows hold is the port's `holds`, asked through a
//! matcher of our own: no regex of the libraries decides a match.
//!
//! No type of the libraries is public here, and `deny.toml` lets no other
//! crate depend on them.
//!
//! # The walk
//!
//! `ignore::WalkBuilder` over the root, on the calling thread, with
//! `standard_filters` on (hidden entries, `.gitignore` and `.ignore` files
//! in the root and above it, `.git/info/exclude` and the global excludes),
//! `require_git(false)`, so a `.gitignore` is honoured in a directory that
//! is not a repository, `follow_links(false)`, and each directory's entries
//! sorted by the bytes of their names. Only regular files are visited; a
//! symbolic link is not followed. An entry the walk cannot read is left
//! out. The root is asked of the disk first, so a root that is not there,
//! is not a directory or cannot be read is a refusal of its own kind.
//!
//! `ignore` reimplements git's rules; it can differ from git at the edges.
//! A file force-added though an ignore file names it is tracked by git and
//! left out of a search.
//!
//! # The read
//!
//! `grep_searcher::SearcherBuilder` with line numbers, a line feed for the
//! row's end, binary detection that quits at a NUL byte, and no memory map
//! (`MmapChoice::never`: no `unsafe`, and nothing undefined when a file is
//! cut short while it is mapped). The matcher declares no line terminator,
//! so the searcher takes its row-by-row path: each row, without its line
//! feed, is handed to the matcher once, which asks the port's `holds` of
//! it, decoded lossily. The rows held are kept and visited once the read
//! ends, since a NUL byte found in a later block makes the whole file
//! binary, and none of its rows is visited.

use std::cell::RefCell;
use std::io;
use std::path::Path;

use editor_grep::{Files, Flow, Read, Refusal, RefusalKind, Row};
use grep_matcher::{Match, Matcher, NoCaptures, NoError};
use grep_searcher::{
    BinaryDetection, MmapChoice, Searcher, SearcherBuilder, Sink, SinkFinish, SinkMatch,
};
use ignore::WalkBuilder;

/// The files under a root, walked and read with ripgrep's libraries.
pub struct RipgrepFiles {
    /// The reader, kept from one read to the next for its buffers.
    searcher: RefCell<Searcher>,
}

impl RipgrepFiles {
    /// The adapter, over the machine's files.
    pub fn new() -> Self {
        let searcher = SearcherBuilder::new()
            .line_number(true)
            .binary_detection(BinaryDetection::quit(b'\0'))
            .memory_map(MmapChoice::never())
            .build();
        Self {
            searcher: RefCell::new(searcher),
        }
    }
}

impl Default for RipgrepFiles {
    fn default() -> Self {
        Self::new()
    }
}

/// The refusal of `path` that `error` says.
fn refusal(path: &Path, error: &io::Error) -> Refusal {
    let kind = match error.kind() {
        io::ErrorKind::NotFound => RefusalKind::NotFound,
        io::ErrorKind::NotADirectory => RefusalKind::NotADirectory,
        io::ErrorKind::PermissionDenied => RefusalKind::Denied,
        _ => RefusalKind::Failed,
    };
    Refusal::new(kind, format!("cannot search {}: {error}", path.display()))
}

impl Files for RipgrepFiles {
    fn walk(&self, root: &Path, visit: &mut dyn FnMut(&Path) -> Flow) -> Result<(), Refusal> {
        let metadata = std::fs::metadata(root).map_err(|error| refusal(root, &error))?;
        if !metadata.is_dir() {
            return Err(Refusal::new(
                RefusalKind::NotADirectory,
                format!("cannot search {}: it is not a directory", root.display()),
            ));
        }
        std::fs::read_dir(root).map_err(|error| refusal(root, &error))?;
        let walk = WalkBuilder::new(root)
            .standard_filters(true)
            .require_git(false)
            .follow_links(false)
            .sort_by_file_name(|a, b| a.as_encoded_bytes().cmp(b.as_encoded_bytes()))
            .build();
        for entry in walk {
            // An entry the walk cannot read is left out.
            let Ok(entry) = entry else { continue };
            if !entry.file_type().is_some_and(|kind| kind.is_file()) {
                continue;
            }
            let Ok(relative) = entry.path().strip_prefix(root) else {
                continue;
            };
            if visit(relative) == Flow::Stop {
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
        let matcher = RowMatcher {
            holds: RefCell::new(holds),
        };
        let mut kept = Kept::default();
        self.searcher
            .borrow_mut()
            .search_path(&matcher, path, &mut kept)
            .map_err(|error| refusal(path, &error))?;
        if kept.binary {
            return Ok(Read::Binary);
        }
        for (number, offset, text) in &kept.rows {
            let row = Row {
                number: *number,
                offset: *offset,
                text,
            };
            if visit(row) == Flow::Stop {
                break;
            }
        }
        Ok(Read::Searched)
    }
}

/// The matcher the searcher asks of each row: a row matches as a whole
/// when the port's `holds` holds for its text.
struct RowMatcher<'h> {
    /// The port's predicate.
    holds: RefCell<&'h mut dyn FnMut(&str) -> bool>,
}

impl Matcher for RowMatcher<'_> {
    type Captures = NoCaptures;
    type Error = NoError;

    fn find_at(&self, haystack: &[u8], at: usize) -> Result<Option<Match>, NoError> {
        // The searcher hands each row alone, without its line feed.
        let row = haystack.get(at..).unwrap_or_default();
        let row = row.strip_suffix(b"\n").unwrap_or(row);
        let text = String::from_utf8_lossy(row);
        let held = (self.holds.borrow_mut())(&text);
        Ok(held.then(|| Match::new(at, haystack.len())))
    }

    fn new_captures(&self) -> Result<NoCaptures, NoError> {
        Ok(NoCaptures::new())
    }
}

/// A row held, as (number, offset, text).
type Held = (usize, usize, String);

/// What a read keeps: the rows held, and whether the file was found to be
/// binary.
#[derive(Default)]
struct Kept {
    /// The rows held.
    rows: Vec<Held>,
    /// Whether a NUL byte was found.
    binary: bool,
}

impl Sink for Kept {
    type Error = io::Error;

    fn matched(&mut self, _: &Searcher, found: &SinkMatch<'_>) -> Result<bool, io::Error> {
        let bytes = found.bytes();
        let bytes = bytes.strip_suffix(b"\n").unwrap_or(bytes);
        let number = found.line_number().map_or(0, |line| line.saturating_sub(1));
        self.rows.push((
            usize::try_from(number).unwrap_or(usize::MAX),
            usize::try_from(found.absolute_byte_offset()).unwrap_or(usize::MAX),
            String::from_utf8_lossy(bytes).into_owned(),
        ));
        Ok(true)
    }

    fn finish(&mut self, _: &Searcher, finish: &SinkFinish) -> Result<(), io::Error> {
        self.binary = finish.binary_byte_offset().is_some();
        Ok(())
    }
}
