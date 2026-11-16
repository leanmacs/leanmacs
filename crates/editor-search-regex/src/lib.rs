//! The search engine port's real adapter: [`RegexEngine`], an [`Engine`]
//! over regex-cursor.
//!
//! The port, its fake, its contract, the pattern syntax and the rule of
//! which match a search answers are `editor-search`'s. This crate is thin:
//! it turns a [`Sequence`] of the pattern tree into the library's own tree
//! (`regex_syntax::hir::Hir`), never into a pattern string, builds the
//! library's meta regex from it, and searches the pieces of a text through
//! a cursor of its own, so a rope's chunks are searched where they lie. No
//! regex-cursor, regex-automata or regex-syntax type is public, and no
//! other crate depends on the libraries (`deny.toml`).
//!
//! What it decides, each so that what matches is the syntax of
//! `editor-search`'s module docs:
//!
//! - **No line feed is matched.** `.`, a negated collection and the
//!   negated classes `\S`, `\D` and `\W` are classes of every character
//!   but theirs and a line feed. `\s` is a space or a tab, `\d` is
//!   `[0-9]` and `\w` is `[0-9A-Za-z_]`, ASCII only.
//! - **`^` and `$` are a row's**: `Look::StartLF` and `Look::EndLF`, at
//!   the text's ends or beside a line feed. A carriage return is a
//!   character of its row, as the core has it, so in a text with CRLF
//!   rows `$` holds after the `\r`, before the `\n`: `a$` does not match
//!   `a\r\n`, and `.$` matches its `\r`.
//! - **Alternation is leftmost-first**, the library's default, and a
//!   repetition is greedy unless the tree says lazy (`\{-…}`).
//! - **Case is kept**: no class is folded, and a character is its UTF-8
//!   bytes.
//! - **A pattern too large for the library's limits** (its compiled size)
//!   is refused with Vim's sentence for one too large,
//!   `E363: pattern uses more memory than 'maxmempattern'`.
//!
//! # A search, and the library's bug
//!
//! [`Compiled::find`] asks the library for the leftmost-first match that
//! starts at or after `from`, in a span that ends at the end of the row
//! that holds `to`, and answers it when it starts by `to`. No match holds
//! a line feed, so none that starts by `to` ends past that row, and `$`
//! holds at the span's end whatever follows. The look-behind of `^` sees
//! the text before `from`, across a piece's boundary.
//!
//! The cursor shows the library the text only up to that end: the pieces
//! after it are not handed over, and the last one is cut there. The
//! library (0.1.5) can panic otherwise, on an overflow in
//! `Input::get_chunk_end`, when its literal prefilter moves to a chunk that
//! starts after the span's end (seen on 2026-11-16, with
//! `\(ab\|a\)\+` in the pieces `"\raaé"`, `"a\na"`, `"a\r"` from 3
//! to 3; pinned by a test here). What is not shown changes no answer, by
//! the reasoning above.
//!
//! The regex and its scratch memory (the library's `Cache`) are made once
//! for a compiled sequence and reused for each search with it.
//!
//! # Tests
//!
//! What only a regex shows, by name: `.` and the negated collections and
//! classes never match a line feed; `\s` is a space or a tab; `^` and `$`
//! hold per row, see the text outside the span, and treat a carriage
//! return as a character; alternation is leftmost-first; `*` is greedy
//! and `\{-}` lazy; a regex is matched across pieces, and how a text is
//! cut changes no answer (a sweep from a fixed seed); a pattern too large
//! is refused; and the core's rule over this engine, with its recorded
//! `\>` limit. The port's contract runs in `tests/contract.rs`.

use std::ops::Range;

use editor_search::pattern::{Atom, Class, Item, Repeat};
use editor_search::{Compiled, Engine, Pieces, Refusal, Sequence};
use regex_cursor::engines::meta::{Cache, Regex};
use regex_cursor::{Cursor, Input};
use regex_syntax::hir::{self, ClassUnicode, ClassUnicodeRange, Hir, Look};

/// Why a sequence the library cannot compile within its limits is
/// refused: Vim's sentence for a pattern too large to compile.
const TOO_LARGE: &str = "E363: pattern uses more memory than 'maxmempattern'";

/// The engine over regex-cursor. It keeps nothing between compiles.
#[derive(Debug, Default, Clone, Copy)]
pub struct RegexEngine;

impl RegexEngine {
    /// An engine.
    pub fn new() -> Self {
        Self
    }
}

/// A sequence compiled by [`RegexEngine`]: the library's regex and the
/// scratch memory its searches reuse.
pub struct RegexMatcher {
    /// The regex.
    regex: Regex,
    /// Its searches' scratch memory, made once and reused.
    cache: Cache,
}

impl std::fmt::Debug for RegexMatcher {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RegexMatcher").finish_non_exhaustive()
    }
}

impl Engine for RegexEngine {
    type Compiled = RegexMatcher;

    fn compile(&mut self, sequence: &Sequence) -> Result<RegexMatcher, Refusal> {
        let regex = Regex::builder()
            .build_from_hir::<PiecesCursor<'_>>(&of_sequence(sequence))
            .map_err(|_| Refusal::new(TOO_LARGE))?;
        let cache = regex.create_cache();
        Ok(RegexMatcher { regex, cache })
    }
}

impl Compiled for RegexMatcher {
    fn find(&mut self, haystack: &Pieces<'_>, from: usize, to: usize) -> Option<Range<usize>> {
        if from > to || to > haystack.len() {
            return None;
        }
        // The search ends at the end of the row that holds `to`: no match
        // holds a line feed, so none that starts by `to` goes further, and
        // `$` holds there whatever follows. The cursor shows the library
        // the text up to there and no further (the crate docs, "The
        // library's bug").
        let end = haystack.row_end(to);
        let mut input = Input::new(PiecesCursor::new(haystack, from, end));
        input.set_span(from..end);
        let found = self.regex.search_with(&mut self.cache, &mut input)?;
        (found.start() <= to).then(|| found.range())
    }
}

/// The library's tree for `sequence`: its items in order, between the
/// row's anchors it holds.
fn of_sequence(sequence: &Sequence) -> Hir {
    let mut parts = Vec::with_capacity(sequence.items().len() + 2);
    if sequence.row_start() {
        parts.push(Hir::look(Look::StartLF));
    }
    parts.extend(sequence.items().iter().map(of_item));
    if sequence.row_end() {
        parts.push(Hir::look(Look::EndLF));
    }
    Hir::concat(parts)
}

/// The library's tree for `item`: its atom, repeated as it says.
fn of_item(item: &Item) -> Hir {
    let atom = of_atom(item.atom());
    let repeat = item.repeat();
    if repeat == Repeat::ONCE {
        return atom;
    }
    Hir::repetition(hir::Repetition {
        min: repeat.min(),
        max: repeat.max(),
        greedy: repeat.greedy(),
        sub: Box::new(atom),
    })
}

/// The library's tree for `atom`.
///
/// The match is exhaustive: every kind of atom is something this engine
/// must compile, and a new kind is a new thing to compile here.
fn of_atom(atom: &Atom) -> Hir {
    match atom {
        Atom::Char(c) => Hir::literal(c.encode_utf8(&mut [0; 4]).as_bytes()),
        Atom::Any => all_but(&[]),
        Atom::Class(class) => match class {
            Class::Space => one_of(SPACE),
            Class::NotSpace => all_but(SPACE),
            Class::Digit => one_of(DIGIT),
            Class::NotDigit => all_but(DIGIT),
            Class::Word => one_of(WORD),
            Class::NotWord => all_but(WORD),
        },
        Atom::Collection(collection) if collection.negated() => all_but(collection.ranges()),
        Atom::Collection(collection) => one_of(collection.ranges()),
        Atom::Group(alternatives) => {
            Hir::alternation(alternatives.iter().map(of_sequence).collect())
        }
    }
}

/// `\s`: a space or a tab.
const SPACE: &[(char, char)] = &[(' ', ' '), ('\t', '\t')];
/// `\d`: `[0-9]`.
const DIGIT: &[(char, char)] = &[('0', '9')];
/// `\w`: `[0-9A-Za-z_]`.
const WORD: &[(char, char)] = &[('0', '9'), ('A', 'Z'), ('_', '_'), ('a', 'z')];

/// The class of the characters of `ranges`.
fn one_of(ranges: &[(char, char)]) -> Hir {
    Hir::class(hir::Class::Unicode(class(ranges)))
}

/// The class of every character but those of `ranges` and a line feed.
fn all_but(ranges: &[(char, char)]) -> Hir {
    let mut class = class(ranges);
    class.push(ClassUnicodeRange::new('\n', '\n'));
    class.negate();
    Hir::class(hir::Class::Unicode(class))
}

/// The library's class of `ranges`.
fn class(ranges: &[(char, char)]) -> ClassUnicode {
    ClassUnicode::new(
        ranges
            .iter()
            .map(|&(low, high)| ClassUnicodeRange::new(low, high)),
    )
}

/// The library's cursor over the pieces of a haystack, up to an end: one
/// piece is the chunk it hands the engine, the last one cut at the end,
/// and it moves a piece forward or back.
#[derive(Clone)]
struct PiecesCursor<'p> {
    /// The pieces, none empty.
    pieces: &'p [&'p str],
    /// The index of the current piece.
    index: usize,
    /// The offset the current piece starts at.
    offset: usize,
    /// Where the text the cursor shows ends: no byte from here on is
    /// handed to the engine.
    end: usize,
}

impl<'p> PiecesCursor<'p> {
    /// A cursor that shows `haystack` up to `end`, at the piece that holds
    /// `from`, which is at most `end`.
    fn new(haystack: &'p Pieces<'_>, from: usize, end: usize) -> Self {
        let pieces = haystack.pieces();
        // The piece that holds `from`; at `end`, the one that holds the
        // byte before it, so the chunk shown is not empty while the text
        // shown is not.
        let index = if from < end {
            haystack.piece_holding(from)
        } else {
            haystack.piece_holding(end.saturating_sub(1))
        };
        let offset = if pieces.is_empty() {
            0
        } else {
            haystack.start_of(index)
        };
        Self {
            pieces,
            index,
            offset,
            end,
        }
    }
}

impl Cursor for PiecesCursor<'_> {
    fn chunk(&self) -> &[u8] {
        // Empty only when the text shown is: the haystack holds no empty
        // piece, and no piece that starts at the end or after it is shown.
        let piece = self
            .pieces
            .get(self.index)
            .map_or(&[][..], |piece| piece.as_bytes());
        &piece[..piece.len().min(self.end.saturating_sub(self.offset))]
    }

    fn utf8_aware(&self) -> bool {
        // Each piece is a `&str`, so no character is split between two,
        // and the end is a character boundary.
        true
    }

    fn advance(&mut self) -> bool {
        let next = self.offset + self.pieces.get(self.index).map_or(0, |piece| piece.len());
        if self.index + 1 >= self.pieces.len() || next >= self.end {
            return false;
        }
        self.offset = next;
        self.index += 1;
        true
    }

    fn backtrack(&mut self) -> bool {
        if self.index == 0 {
            return false;
        }
        self.index -= 1;
        self.offset -= self.pieces[self.index].len();
        true
    }

    fn total_bytes(&self) -> Option<usize> {
        Some(self.end)
    }

    fn offset(&self) -> usize {
        self.offset
    }
}

#[cfg(test)]
mod tests {
    use std::ops::Range;

    use editor_search::{Compiled, Engine, Pattern, Pieces, Searched, matches, search};

    use super::RegexEngine;

    /// Where `pattern`, one branch, first matches in `pieces` from `from`
    /// to `to`.
    fn find(pattern: &str, pieces: &[&str], from: usize, to: usize) -> Option<Range<usize>> {
        let parsed = Pattern::parse(pattern).unwrap();
        let [branch] = parsed.branches() else {
            panic!("{pattern:?} is not one branch");
        };
        let mut compiled = RegexEngine
            .compile(branch.sequence())
            .unwrap_or_else(|refusal| panic!("{pattern:?}: {}", refusal.reason()));
        compiled.find(&Pieces::new(pieces), from, to)
    }

    /// Where `pattern` first matches in `text`, from its start.
    fn first(pattern: &str, text: &str) -> Option<Range<usize>> {
        find(pattern, &[text], 0, text.len())
    }

    /// The text's word class, as `editor-text` states it.
    fn word(c: char) -> bool {
        c.is_ascii_alphanumeric() || c == '_' || u32::from(c) >= 0x80
    }

    /// Every match of `pattern` in `text`, by the core's rule.
    fn all(pattern: &str, text: &str) -> Vec<(usize, usize)> {
        matches(&mut RegexEngine, pattern, &[text], &word, 0, text.len())
            .unwrap()
            .into_iter()
            .map(|found| (found.start, found.end))
            .collect()
    }

    #[test]
    fn a_dot_never_matches_a_line_feed() {
        assert_eq!(first(".", "\na"), Some(1..2));
        assert_eq!(first("a.b", "a\nb"), None);
        assert_eq!(first(".*", "ab\ncd"), Some(0..2));
        assert_eq!(first("a.b", "a\rb"), Some(0..3));
        assert_eq!(first("..", "é漢"), Some(0..5));
    }

    #[test]
    fn a_negated_collection_or_class_never_matches_a_line_feed() {
        assert_eq!(first("[^a]", "a\nb"), Some(2..3));
        assert_eq!(first("a[^x]b", "a\nb"), None);
        assert_eq!(first(r"a\Sb", "a\nb"), None);
        assert_eq!(first(r"a\Db", "a\nb"), None);
        assert_eq!(first(r"a\Wb", "a\nb"), None);
        assert_eq!(first(r"a\Wb", "a-b"), Some(0..3));
    }

    #[test]
    fn a_space_is_a_space_or_a_tab() {
        assert_eq!(first(r"\s", "a\n\tb"), Some(2..3));
        assert_eq!(first(r"\s", "a b"), Some(1..2));
        assert_eq!(first(r"\s", "a\u{a0}\u{2003}\rb"), None);
        assert_eq!(first(r"\S", "\n \ta"), Some(3..4));
    }

    #[test]
    fn digits_and_word_characters_are_ascii() {
        assert_eq!(first(r"\d\+", "x٣12"), Some(3..5));
        assert_eq!(first(r"\D", "12a"), Some(2..3));
        assert_eq!(first(r"\w\+", "é_ab9-"), Some(2..6));
        assert_eq!(first(r"\W", "ab\nc-"), Some(4..5));
    }

    #[test]
    fn a_collection_with_ranges() {
        assert_eq!(first(r"[a-c]\+", "xabcd"), Some(1..4));
        assert_eq!(first("[]a]", "x]"), Some(1..2));
        assert_eq!(first("[é-ü]", "aö"), Some(1..3));
        assert_eq!(first(r"[\t-]", "a-"), Some(1..2));
        assert_eq!(first("[^a-z]", "abC"), Some(2..3));
    }

    #[test]
    fn a_caret_and_a_dollar_hold_at_each_rows_ends() {
        assert_eq!(first("^b", "ab\nb"), Some(3..4));
        assert_eq!(first("a$", "ab\na"), Some(3..4));
        assert_eq!(first("a$", "a\nb"), Some(0..1));
        assert_eq!(first("^$", "a\n\nb"), Some(2..2));
        assert_eq!(all("^", "a\nb\n"), [(0, 0), (2, 2)]);
        assert_eq!(all("$", "a\nb"), [(1, 1)]);
        // In the empty text.
        assert_eq!(find("^", &[], 0, 0), Some(0..0));
        assert_eq!(find("$", &[], 0, 0), Some(0..0));
    }

    #[test]
    fn a_dollar_holds_before_the_line_feed_so_a_carriage_return_is_before_it() {
        // `$` is the end of the row, which ends at its line feed; a
        // carriage return is a character of the row, as the core has it.
        assert_eq!(first("a$", "a\r\nb"), None);
        assert_eq!(first("a\r$", "a\r\nb"), Some(0..2));
        assert_eq!(first(".$", "a\r\nb"), Some(1..2));
        assert_eq!(first("^b", "a\rb"), None);
    }

    #[test]
    fn the_anchors_see_the_text_outside_the_span() {
        // From 1, `^` does not hold: the character before is no line feed.
        assert_eq!(find("^a", &["aa"], 1, 2), None);
        assert_eq!(find("^a", &["a\n", "a"], 1, 3), Some(2..3));
        // Across a piece's boundary, both ways.
        assert_eq!(find("^b", &["a", "b"], 1, 2), None);
        assert_eq!(find("^b", &["a\n", "b"], 2, 3), Some(2..3));
        assert_eq!(find("a$", &["a", "b"], 0, 1), None);
        assert_eq!(find("a$", &["a", "\nb"], 0, 1), Some(0..1));
        // A match may end after `to`, and none starts after it.
        assert_eq!(find("ab", &["xab"], 0, 1), Some(1..3));
        assert_eq!(find("b", &["xab"], 0, 1), None);
    }

    #[test]
    fn alternation_is_leftmost_first() {
        assert_eq!(first(r"\(a\|ab\)", "ab"), Some(0..1));
        assert_eq!(first(r"\(ab\|a\)", "ab"), Some(0..2));
        assert_eq!(first(r"x\(a\|ab\)c", "xabc"), Some(0..4));
        // The leftmost start wins whatever the alternative.
        assert_eq!(first(r"\(b\|a\)", "ab"), Some(0..1));
    }

    #[test]
    fn a_star_is_greedy_and_a_brace_with_a_dash_lazy() {
        assert_eq!(first("a*", "aaa"), Some(0..3));
        assert_eq!(first(r"a\{-}", "aaa"), Some(0..0));
        assert_eq!(first(r"a\{-1,}", "aaa"), Some(0..1));
        assert_eq!(first(r"a\{2,3}", "aaaa"), Some(0..3));
        assert_eq!(first(r"a\{-2,3}", "aaaa"), Some(0..2));
        assert_eq!(first(r"a\{2}", "aaaa"), Some(0..2));
        assert_eq!(first(r"a\{,2}", "aaa"), Some(0..2));
        assert_eq!(first(r"a\+", "baa"), Some(1..3));
        assert_eq!(first(r"ba\=b", "bb"), Some(0..2));
        assert_eq!(first(r"ba\?b", "bab"), Some(0..3));
        assert_eq!(first(r"\(ab\)\+", "ababx"), Some(0..4));
        assert_eq!(first(r".\{-}b", "aab"), Some(0..3));
    }

    #[test]
    fn a_regex_is_matched_across_the_pieces() {
        assert_eq!(find("fo*", &["f", "oo", "o x"], 0, 6), Some(0..4));
        assert_eq!(find("o.x", &["f", "oo", "o x"], 0, 6), Some(3..6));
        assert_eq!(find("[é]", &["x", "é"], 0, 3), Some(1..3));
        assert_eq!(find(r"\(ab\)*$", &["a", "ba", "b\n"], 0, 4), Some(0..4));
    }

    #[test]
    fn how_a_text_is_cut_into_pieces_changes_no_answer() {
        // Generated texts, each cut into generated pieces, from a fixed
        // seed: every pattern answers in the pieces what it answers in
        // the text as one piece, from every `from` to every `to`.
        let mut patterns: Vec<_> = [
            ".",
            "a*",
            "^a",
            "a$",
            "^$",
            "[^a]b",
            r"\s\S",
            "é.",
            r"\(ab\|a\)\+",
            r"b\{-1,}a",
            r".\{2}$",
        ]
        .into_iter()
        .map(|pattern| {
            let parsed = Pattern::parse(pattern).unwrap();
            let compiled = RegexEngine
                .compile(parsed.branches()[0].sequence())
                .unwrap();
            (pattern, compiled)
        })
        .collect();
        let alphabet = ['a', 'b', ' ', '\n', 'é', '\r'];
        let mut seed: u64 = 7;
        let mut below = |bound: usize| {
            seed = seed
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407);
            usize::try_from(seed >> 33).unwrap_or(0) % bound
        };
        for _ in 0..200 {
            let len = below(10);
            let text: String = (0..len).map(|_| alphabet[below(alphabet.len())]).collect();
            let positions: Vec<usize> = text
                .char_indices()
                .map(|(at, _)| at)
                .chain([text.len()])
                .collect();
            let mut cuts: Vec<usize> = (0..below(4))
                .map(|_| positions[below(positions.len())])
                .collect();
            cuts.sort_unstable();
            let mut pieces = Vec::new();
            let mut start = 0;
            for cut in cuts {
                pieces.push(&text[start..cut]);
                start = cut;
            }
            pieces.push(&text[start..]);
            let cut = Pieces::new(&pieces);
            let whole = Pieces::new(&[&text]);
            for (pattern, compiled) in &mut patterns {
                for &from in &positions {
                    for &to in positions.iter().filter(|&&to| to >= from) {
                        assert_eq!(
                            compiled.find(&cut, from, to),
                            compiled.find(&whole, from, to),
                            "{pattern:?} in {pieces:?} from {from} to {to}"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn a_search_that_ends_inside_a_piece_before_the_last_is_answered() {
        // The library's bug (the crate docs): with the whole text shown,
        // this search panicked in regex-cursor 0.1.5.
        let pieces = ["\raaé", "a\na", "a\r"];
        assert_eq!(find(r"\(ab\|a\)\+", &pieces, 3, 3), None);
        assert_eq!(find(r"\(ab\|a\)\+", &pieces, 3, 5), Some(5..6));
    }

    #[test]
    fn an_empty_sequence_matches_the_empty_string() {
        assert_eq!(all(r"x\|", "ab"), [(0, 0), (1, 1)]);
    }

    #[test]
    fn a_pattern_too_large_to_compile_is_refused_with_vims_sentence() {
        let parsed = Pattern::parse(r"\(\(.\{1000}\)\{1000}\)\{1000}").unwrap();
        let refusal = RegexEngine
            .compile(parsed.branches()[0].sequence())
            .err()
            .map(|refusal| refusal.reason().to_owned());
        assert_eq!(
            refusal.as_deref(),
            Some("E363: pattern uses more memory than 'maxmempattern'")
        );
    }

    #[test]
    fn a_search_with_the_regex_engine_keeps_the_cores_rule() {
        let pieces = ["foo bar\n", "baz foo"];
        let forward = search(&mut RegexEngine, r"ba.", &pieces, &word, true, 4);
        assert_eq!(
            forward,
            Ok(Searched::Found {
                start: 8,
                stop: 11,
                wrapped: false
            })
        );
        let backward = search(&mut RegexEngine, r"^\w\+", &pieces, &word, false, 8);
        assert_eq!(
            backward,
            Ok(Searched::Found {
                start: 0,
                stop: 3,
                wrapped: false
            })
        );
        assert_eq!(
            all(r"\<ba.\>\|foo$", "foo bar\nbaz foo"),
            [(4, 7), (8, 11), (12, 15)]
        );
    }

    #[test]
    fn a_word_end_checked_against_the_engines_match_can_miss_a_shorter_one() {
        // The recorded limit: Vim backtracks `.*` to end at `z`; the
        // engine answers the longest match, `xy z!`, whose end is no word
        // end, and the walk moves on.
        assert_eq!(all(r"\<x.*\>", "xy z!"), []);
        // A branch whose longest match ends at the word's end is found.
        assert_eq!(all(r"\<x\S*\>", "xy z!"), [(0, 2)]);
    }
}
