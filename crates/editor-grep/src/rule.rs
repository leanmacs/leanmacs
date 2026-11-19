//! The rule of which matches a project search answers (the crate docs,
//! "The rule of a search"), over the files port and an engine of the
//! search port.

use std::cell::RefCell;
use std::collections::HashMap;
use std::ops::Range;
use std::path::{Path, PathBuf};

use editor_search::{Compiled, CompiledPattern, Engine};

use crate::{Files, Flow, Read, Refusal, RefusalKind, refusal_before_search};

/// An open buffer's text, as the pieces it is held in: what a search reads
/// in place of the buffer's file.
pub trait Text {
    /// The text's pieces, in order. Joined, they are the whole text.
    fn pieces(&self) -> Vec<&str>;
}

impl Text for String {
    fn pieces(&self) -> Vec<&str> {
        vec![self]
    }
}

/// An open buffer's text, searched in place of the file at its path.
pub struct Overlay {
    /// The file's path, spelled as the buffer spells it.
    pub path: PathBuf,
    /// The buffer's text.
    pub text: Box<dyn Text + Send>,
}

impl Overlay {
    /// `text` in place of the file at `path`.
    pub fn new(path: impl Into<PathBuf>, text: impl Text + Send + 'static) -> Self {
        Self {
            path: path.into(),
            text: Box::new(text),
        }
    }
}

/// How much a search answers before it stops.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Limits {
    /// How many files with a match it answers.
    pub files: usize,
    /// How many matches it answers, over every file.
    pub matches: usize,
}

/// What a search is asked.
pub struct Request {
    /// The directory whose files are searched: absolute, with no `..`.
    pub root: PathBuf,
    /// The pattern, in the syntax of `editor-search`.
    pub pattern: String,
    /// Open buffers' texts, each searched in place of its file.
    pub overlays: Vec<Overlay>,
    /// Where it stops.
    pub limits: Limits,
}

/// Where a file's matches were found.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Source {
    /// In the file on disk.
    Disk,
    /// In an open buffer's text, in place of the file.
    Buffer,
}

/// One match: its row, and its byte offsets in the file.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Match {
    /// The row it is on, from 0.
    pub row: usize,
    /// Where it starts.
    pub start: usize,
    /// Where it stops.
    pub stop: usize,
}

/// A file with matches, as a search answers it.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Found {
    /// Its path: the root, as the request spelled it, joined with the
    /// walk's path under it.
    pub path: PathBuf,
    /// Where its matches were found.
    pub source: Source,
    /// Its matches, in order. Never empty.
    pub matches: Vec<Match>,
}

/// What a search came to.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct Summary {
    /// How many files with a match it answered.
    pub files: usize,
    /// How many matches it answered.
    pub matches: usize,
    /// Whether it stopped at a limit with more to answer.
    pub truncated: bool,
}

/// A search with its pattern compiled: compiled once, before the walk, and
/// asked of every row and every overlay.
pub struct Search<C> {
    /// The pattern.
    pattern: CompiledPattern<C>,
}

impl<C: Compiled> Search<C> {
    /// The search `request` asks for, its pattern compiled by `engine`, or
    /// why it may not run: a root that is not absolute or has a `..`
    /// component ([`RefusalKind::NotAbsolute`]), or a pattern that does not
    /// parse or that `engine` refuses ([`RefusalKind::Invalid`], with the
    /// sentence the echo area says). Nothing is walked.
    pub fn prepare<E: Engine<Compiled = C>>(
        engine: &mut E,
        request: &Request,
    ) -> Result<Self, Refusal> {
        if let Some(refusal) = refusal_before_search(&request.root) {
            return Err(refusal);
        }
        let pattern = CompiledPattern::new(engine, &request.pattern)
            .map_err(|refusal| Refusal::new(RefusalKind::Invalid, refusal.reason()))?;
        Ok(Self { pattern })
    }

    /// Runs the search over `files`, telling `found` each file with a match
    /// in the walk's order, with `word` the text's word class for `\<` and
    /// `\>`. `stopped` is asked before each file and each row; once it is
    /// true nothing more is read, and what was found so far is the summary.
    pub fn run(
        &mut self,
        files: &impl Files,
        word: &dyn Fn(char) -> bool,
        request: &Request,
        stopped: &dyn Fn() -> bool,
        found: &mut dyn FnMut(Found),
    ) -> Result<Summary, Refusal> {
        let overlays: HashMap<&Path, &dyn Text> = request
            .overlays
            .iter()
            .map(|overlay| (overlay.path.as_path(), &*overlay.text as &dyn Text))
            .collect();
        let limits = request.limits;
        let pattern = RefCell::new(&mut self.pattern);
        let mut summary = Summary::default();
        files.walk(&request.root, &mut |relative| {
            if stopped() {
                return Flow::Stop;
            }
            let path = request.root.join(relative);
            // One match past the room left says the search is truncated.
            let room = limits.matches - summary.matches;
            let (source, matches) = match overlays.get(path.as_path()) {
                Some(text) => (
                    Source::Buffer,
                    in_text(&mut pattern.borrow_mut(), *text, word, room + 1),
                ),
                None => (
                    Source::Disk,
                    in_file(files, &pattern, &path, word, stopped, room + 1),
                ),
            };
            if matches.is_empty() {
                return Flow::Go;
            }
            if summary.files == limits.files {
                summary.truncated = true;
                return Flow::Stop;
            }
            let mut matches = matches;
            if matches.len() > room {
                matches.truncate(room);
                summary.truncated = true;
            }
            if !matches.is_empty() {
                summary.files += 1;
                summary.matches += matches.len();
                found(Found {
                    path,
                    source,
                    matches,
                });
            }
            if summary.truncated {
                Flow::Stop
            } else {
                Flow::Go
            }
        })?;
        Ok(summary)
    }
}

/// The non-empty matches of `pattern` in the text made of `pieces`, from
/// its start to its end.
fn non_empty<C: Compiled>(
    pattern: &mut CompiledPattern<C>,
    pieces: &[&str],
    word: &dyn Fn(char) -> bool,
) -> Vec<Range<usize>> {
    let len = pieces.iter().map(|piece| piece.len()).sum();
    pattern
        .matches(pieces, word, 0, len)
        .unwrap_or_default()
        .into_iter()
        .filter(|found| !found.is_empty())
        .collect()
}

/// The first `most` matches of `pattern` in the file at `path`, read
/// through `files` row by row; none when it cannot be read or is binary.
fn in_file<C: Compiled>(
    files: &impl Files,
    pattern: &RefCell<&mut CompiledPattern<C>>,
    path: &Path,
    word: &dyn Fn(char) -> bool,
    stopped: &dyn Fn() -> bool,
    most: usize,
) -> Vec<Match> {
    let mut matches = Vec::new();
    let read = files.rows(
        path,
        &mut |text| !stopped() && !non_empty(&mut pattern.borrow_mut(), &[text], word).is_empty(),
        &mut |row| {
            for found in non_empty(&mut pattern.borrow_mut(), &[row.text], word) {
                matches.push(Match {
                    row: row.number,
                    start: row.offset + found.start,
                    stop: row.offset + found.end,
                });
                if matches.len() == most {
                    return Flow::Stop;
                }
            }
            Flow::Go
        },
    );
    match read {
        Ok(Read::Searched) => matches,
        // A file that cannot be read, or is binary, has no match: the walk
        // goes on.
        Ok(Read::Binary) | Err(_) => Vec::new(),
    }
}

/// The first `most` matches of `pattern` in `text`, an open buffer's, with
/// each one's row counted by the line feeds before it.
fn in_text<C: Compiled>(
    pattern: &mut CompiledPattern<C>,
    text: &dyn Text,
    word: &dyn Fn(char) -> bool,
    most: usize,
) -> Vec<Match> {
    let pieces = text.pieces();
    let mut row = 0;
    // How far the line feeds are counted: the piece, and the offset of its
    // start in the text.
    let mut piece = 0;
    let mut base = 0;
    let mut counted = 0;
    non_empty(pattern, &pieces, word)
        .into_iter()
        .take(most)
        .map(|found| {
            while counted < found.start {
                let here = pieces[piece];
                let end = (found.start - base).min(here.len());
                let from = counted - base;
                row += here.as_bytes()[from..end]
                    .iter()
                    .filter(|&&byte| byte == b'\n')
                    .count();
                counted = base + end;
                if end == here.len() {
                    piece += 1;
                    base += here.len();
                }
            }
            Match {
                row,
                start: found.start,
                stop: found.end,
            }
        })
        .collect()
}

/// Every match of `request`'s pattern under its root: [`Search::prepare`]
/// then [`Search::run`].
pub fn search<E: Engine>(
    files: &impl Files,
    engine: &mut E,
    word: &dyn Fn(char) -> bool,
    request: &Request,
    stopped: &dyn Fn() -> bool,
    found: &mut dyn FnMut(Found),
) -> Result<Summary, Refusal> {
    Search::prepare(engine, request)?.run(files, word, request, stopped, found)
}

#[cfg(test)]
mod tests {
    use std::cell::{Cell, RefCell};
    use std::path::{Path, PathBuf};
    use std::rc::Rc;

    use editor_search::{Engine, Literal, LiteralRun, Refusal as PatternRefusal, Sequence};

    use super::{Found, Limits, Match, Overlay, Request, Source, Summary, search};
    use crate::fake::FakeFiles;
    use crate::{Files, Flow, Read, Refusal, RefusalKind, Row};

    /// The text's word class, as `editor-text` states it.
    fn word(c: char) -> bool {
        c.is_ascii_alphanumeric() || c == '_' || u32::from(c) >= 0x80
    }

    const WIDE: Limits = Limits {
        files: 100,
        matches: 1_000,
    };

    fn request(root: &str, pattern: &str) -> Request {
        Request {
            root: PathBuf::from(root),
            pattern: pattern.to_owned(),
            overlays: Vec::new(),
            limits: WIDE,
        }
    }

    /// What a search of `request` over `files` finds, and its summary.
    fn run(files: &impl Files, request: &Request) -> (Vec<Found>, Result<Summary, Refusal>) {
        let mut found = Vec::new();
        let summary = search(files, &mut Literal, &word, request, &|| false, &mut |f| {
            found.push(f);
        });
        (found, summary)
    }

    fn at(row: usize, start: usize, stop: usize) -> Match {
        Match { row, start, stop }
    }

    fn disk(path: &str, matches: Vec<Match>) -> Found {
        Found {
            path: PathBuf::from(path),
            source: Source::Disk,
            matches,
        }
    }

    /// A port that refuses to be asked anything.
    struct Untouchable;

    impl Files for Untouchable {
        fn walk(&self, _: &Path, _: &mut dyn FnMut(&Path) -> Flow) -> Result<(), Refusal> {
            panic!("walked")
        }

        fn rows(
            &self,
            _: &Path,
            _: &mut dyn FnMut(&str) -> bool,
            _: &mut dyn FnMut(Row<'_>) -> Flow,
        ) -> Result<Read, Refusal> {
            panic!("read")
        }
    }

    #[test]
    fn a_root_that_is_not_absolute_and_a_pattern_that_does_not_parse_are_refused_before_any_walk() {
        let refused = |root: &str, pattern: &str| {
            let refusal = run(&Untouchable, &request(root, pattern)).1.unwrap_err();
            (refusal.kind, refusal.detail)
        };

        assert_eq!(refused("w", "x").0, RefusalKind::NotAbsolute);
        assert_eq!(refused("/w/../v", "x").0, RefusalKind::NotAbsolute);
        assert_eq!(
            refused("/w", r"\("),
            (RefusalKind::Invalid, r"E54: Unmatched \(".to_owned())
        );
        assert_eq!(
            refused("/w", "a.b"),
            (RefusalKind::Invalid, Literal::REFUSAL.to_owned())
        );
    }

    #[test]
    fn a_root_the_walk_refuses_is_refused() {
        let files = FakeFiles::new().file("/w/f", "x");

        assert_eq!(
            run(&files, &request("/v", "x")).1.unwrap_err().kind,
            RefusalKind::NotFound
        );
        assert_eq!(
            run(&files, &request("/w/f", "x")).1.unwrap_err().kind,
            RefusalKind::NotADirectory
        );
    }

    #[test]
    fn files_are_answered_in_walk_order_with_each_matchs_row_and_offsets() {
        let files = FakeFiles::new()
            .file("/w/b.txt", "foo\nx foo foo\n")
            .file("/w/a/c.txt", "no\r\nfoo\r\n")
            .file("/w/a-d.txt", "nothing here")
            .file("/w/.hidden", "foo")
            .file("/w/gen/e", "foo")
            .file("/w/bin", "foo\0")
            .excluded("/w/gen");

        let (found, summary) = run(&files, &request("/w", "foo"));

        assert_eq!(
            found,
            [
                disk("/w/a/c.txt", vec![at(1, 4, 7)]),
                disk("/w/b.txt", vec![at(0, 0, 3), at(1, 6, 9), at(1, 10, 13)]),
            ]
        );
        assert_eq!(
            summary,
            Ok(Summary {
                files: 2,
                matches: 4,
                truncated: false
            })
        );
    }

    #[test]
    fn a_path_is_the_root_as_spelled_joined_with_the_walks() {
        let files = FakeFiles::new().file("/w/./s/a", "foo");

        let (found, _) = run(&files, &request("/w/./s", "foo"));

        assert_eq!(found, [disk("/w/./s/a", vec![at(0, 0, 3)])]);
    }

    #[test]
    fn an_empty_match_is_not_answered() {
        let files = FakeFiles::new().file("/w/a", "ab\nx\n").file("/w/b", "ab");

        let (found, summary) = run(&files, &request("/w", r"x\|"));

        assert_eq!(found, [disk("/w/a", vec![at(1, 3, 4)])]);
        assert_eq!(summary.map(|s| s.matches), Ok(1));
    }

    #[test]
    fn an_overlay_is_searched_in_place_of_its_file() {
        let files = FakeFiles::new()
            .file("/w/a", "foo\n")
            .file("/w/b", "foo\n")
            .file("/w/gen/c", "foo")
            .excluded("/w/gen");
        let mut asked = request("/w", "foo");
        asked.overlays = vec![
            Overlay::new("/w/a", String::from("bar\nx foo\nfoo")),
            Overlay::new("/w/gen/c", String::from("foo")),
            Overlay::new("/w/new", String::from("foo")),
        ];

        let (found, _) = run(&files, &asked);

        assert_eq!(
            found,
            [
                Found {
                    path: PathBuf::from("/w/a"),
                    source: Source::Buffer,
                    matches: vec![at(1, 6, 9), at(2, 10, 13)],
                },
                disk("/w/b", vec![at(0, 0, 3)]),
            ]
        );
    }

    /// Text held in several pieces.
    struct Pieces(Vec<String>);

    impl super::Text for Pieces {
        fn pieces(&self) -> Vec<&str> {
            self.0.iter().map(String::as_str).collect()
        }
    }

    #[test]
    fn an_overlay_held_in_pieces_is_searched_across_them_and_an_overlay_with_no_match_is_not_answered()
     {
        let files = FakeFiles::new().file("/w/a", "").file("/w/b", "foo");
        let mut asked = request("/w", "foo");
        let pieces = ["x\nf", "o", "o\n\nfo", "o"].map(String::from).to_vec();
        asked.overlays = vec![
            Overlay::new("/w/a", Pieces(pieces)),
            Overlay::new("/w/b", String::from("bar")),
        ];

        let (found, _) = run(&files, &asked);

        assert_eq!(
            found,
            [Found {
                path: PathBuf::from("/w/a"),
                source: Source::Buffer,
                matches: vec![at(1, 2, 5), at(3, 7, 10)],
            }]
        );
    }

    #[test]
    fn a_word_start_and_end_are_checked_with_the_class_handed_in() {
        let files = FakeFiles::new().file("/w/a", "éfoo foo_ foo\nfoo");
        let mut asked = request("/w", r"\<foo\>");

        let (on_disk, _) = run(&files, &asked);
        asked.overlays = vec![Overlay::new("/w/a", String::from("éfoo foo"))];
        let (in_buffer, _) = run(&files, &asked);

        assert_eq!(on_disk, [disk("/w/a", vec![at(0, 11, 14), at(1, 15, 18)])]);
        assert_eq!(in_buffer[0].matches, [at(0, 6, 9)]);
    }

    #[test]
    fn the_files_limit_stops_the_walk_and_truncates() {
        let files = FakeFiles::new()
            .file("/w/a", "x")
            .file("/w/b", "x")
            .file("/w/c", "y")
            .file("/w/d", "x");
        let mut asked = request("/w", "x");
        asked.limits = Limits {
            files: 2,
            matches: 100,
        };

        let (found, summary) = run(&files, &asked);

        assert_eq!(found.len(), 2);
        assert_eq!(
            summary,
            Ok(Summary {
                files: 2,
                matches: 2,
                truncated: true
            })
        );
        // At the limit with nothing more to answer, it is complete.
        asked.limits.files = 3;
        assert_eq!(run(&files, &asked).1.map(|s| s.truncated), Ok(false));
    }

    #[test]
    fn the_matches_limit_cuts_a_file_short_and_truncates() {
        let files = FakeFiles::new()
            .file("/w/a", "x x\n")
            .file("/w/b", "x\nx\n");
        let mut asked = request("/w", "x");
        asked.limits = Limits {
            files: 100,
            matches: 3,
        };

        let (found, summary) = run(&files, &asked);

        assert_eq!(
            found,
            [
                disk("/w/a", vec![at(0, 0, 1), at(0, 2, 3)]),
                disk("/w/b", vec![at(0, 0, 1)]),
            ]
        );
        assert_eq!(
            summary,
            Ok(Summary {
                files: 2,
                matches: 3,
                truncated: true
            })
        );
        asked.limits.matches = 4;
        assert_eq!(run(&files, &asked).1.map(|s| s.truncated), Ok(false));
        // An overlay is cut short the same way.
        asked.limits.matches = 1;
        asked.overlays = vec![Overlay::new("/w/a", String::from("x x"))];
        let (found, summary) = run(&files, &asked);
        assert_eq!(found[0].matches, [at(0, 0, 1)]);
        assert_eq!(summary.map(|s| s.truncated), Ok(true));
    }

    #[test]
    fn stopped_is_asked_before_each_file_and_each_row_and_ends_the_search() {
        let files = FakeFiles::new()
            .file("/w/a", "x\nx\nx\n")
            .file("/w/b", "x\n");
        let asked = Cell::new(0);
        let stop_after = Cell::new(usize::MAX);
        let stopped = || {
            asked.set(asked.get() + 1);
            asked.get() > stop_after.get()
        };
        let mut found = Vec::new();
        let request = request("/w", "x");
        search(&files, &mut Literal, &word, &request, &stopped, &mut |f| {
            found.push(f);
        })
        .expect("a summary");
        // Two files and four rows.
        assert!(asked.get() >= 6, "asked {} times", asked.get());

        // Stopped from the third question on: the first file's first row
        // alone is read.
        asked.set(0);
        stop_after.set(2);
        found.clear();
        let summary = search(&files, &mut Literal, &word, &request, &stopped, &mut |f| {
            found.push(f);
        });
        assert_eq!(found, [disk("/w/a", vec![at(0, 0, 1)])]);
        assert_eq!(summary.map(|s| s.truncated), Ok(false));
    }

    /// The fake engine, counting the branches it compiles.
    struct Counting(Rc<RefCell<usize>>);

    impl Engine for Counting {
        type Compiled = LiteralRun;

        fn compile(&mut self, sequence: &Sequence) -> Result<LiteralRun, PatternRefusal> {
            *self.0.borrow_mut() += 1;
            Literal.compile(sequence)
        }
    }

    #[test]
    fn the_pattern_is_compiled_once_a_branch_a_search() {
        let files = FakeFiles::new()
            .file("/w/a", "foo\nbar\nbaz\n")
            .file("/w/b", "x\nfoo bar\n")
            .file("/w/c", "bar");
        let mut asked = request("/w", r"foo\|bar");
        asked.overlays = vec![Overlay::new("/w/c", String::from("foo\nbar"))];
        let compiled = Rc::new(RefCell::new(0));
        let mut found = 0;

        search(
            &files,
            &mut Counting(Rc::clone(&compiled)),
            &word,
            &asked,
            &|| false,
            &mut |_| found += 1,
        )
        .expect("a summary");

        assert_eq!(found, 3);
        assert_eq!(
            *compiled.borrow(),
            2,
            "one compile for each of two branches"
        );
    }
}
