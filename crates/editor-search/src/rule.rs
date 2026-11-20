//! The rule of which match a search answers (the crate docs, "The rule of
//! which match"), over an engine of the port.

use std::ops::Range;

use crate::{Compiled, Engine, Pattern, Pieces, Refusal};

/// What a search answers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Searched {
    /// A match from `start` to `stop`, byte offsets; `wrapped` when the
    /// search went past the text's end (forward) or its start (backward)
    /// to find it.
    Found {
        /// Where the match starts.
        start: usize,
        /// Where it stops.
        stop: usize,
        /// Whether the search wrapped round the text to find it.
        wrapped: bool,
    },
    /// The pattern matches nowhere in the text.
    NotFound,
}

/// Why an offset was refused: it is not a position of the text.
const NOT_A_POSITION: &str = "the offset is not a position in the text";
/// Why a range was refused: it is not two positions in order.
const NOT_A_RANGE: &str = "the range is not two positions in order";

/// The match of `pattern` that a search from `offset` answers in the text
/// made of `pieces`, forward or backward: the crate docs' rule, with
/// `word` the text's word class for `\<` and `\>`.
///
/// Refused when the pattern does not parse, when `engine` refuses one of
/// its branches, or when `offset` is not a position of the text (past its
/// end, or inside a character).
pub fn search(
    engine: &mut impl Engine,
    pattern: &str,
    pieces: &[&str],
    word: &dyn Fn(char) -> bool,
    forward: bool,
    offset: usize,
) -> Result<Searched, Refusal> {
    let mut compiled = CompiledPattern::new(engine, pattern)?;
    let haystack = Pieces::new(pieces);
    let mut walk = Walk::new(&mut compiled.branches, &haystack, word);
    if !haystack.is_position(offset) {
        return Err(Refusal::new(NOT_A_POSITION));
    }
    let answer = if forward {
        walk.forward(offset)
    } else {
        walk.backward(offset)
    };
    Ok(match answer {
        Some((found, wrapped)) => Searched::Found {
            start: found.start,
            stop: found.end,
            wrapped,
        },
        None => Searched::NotFound,
    })
}

/// The matches of `pattern` in the text made of `pieces` that start at or
/// after `start` and before `stop`, in order: the crate docs' rule, with
/// `word` the text's word class for `\<` and `\>`.
///
/// Refused when the pattern does not parse, when `engine` refuses one of
/// its branches, or when `start` and `stop` are not two positions of the
/// text in order.
pub fn matches(
    engine: &mut impl Engine,
    pattern: &str,
    pieces: &[&str],
    word: &dyn Fn(char) -> bool,
    start: usize,
    stop: usize,
) -> Result<Vec<Range<usize>>, Refusal> {
    CompiledPattern::new(engine, pattern)?.matches(pieces, word, start, stop)
}

/// A pattern parsed and compiled once, to be asked of many texts: what a
/// search of many files compiles before it reads the first, so its engine
/// compiles each branch once a search, not once a text.
pub struct CompiledPattern<C> {
    /// The pattern's top-level branches, in order, each compiled.
    branches: Vec<Branch<C>>,
}

impl<C: Compiled> CompiledPattern<C> {
    /// `pattern` parsed, and each of its top-level branches compiled by
    /// `engine`. Refused when the pattern does not parse, or when `engine`
    /// refuses one of its branches.
    pub fn new<E: Engine<Compiled = C>>(engine: &mut E, pattern: &str) -> Result<Self, Refusal> {
        let pattern = Pattern::parse(pattern)?;
        let branches = pattern
            .branches()
            .iter()
            .map(|branch| {
                Ok(Branch {
                    word_start: branch.word_start(),
                    word_end: branch.word_end(),
                    compiled: engine.compile(branch.sequence())?,
                })
            })
            .collect::<Result<_, Refusal>>()?;
        Ok(Self { branches })
    }

    /// The matches of the pattern in the text made of `pieces` that start
    /// at or after `start` and before `stop`, in order: what [`matches()`]
    /// answers, with nothing compiled again.
    ///
    /// Refused when `start` and `stop` are not two positions of the text
    /// in order.
    pub fn matches(
        &mut self,
        pieces: &[&str],
        word: &dyn Fn(char) -> bool,
        start: usize,
        stop: usize,
    ) -> Result<Vec<Range<usize>>, Refusal> {
        let haystack = Pieces::new(pieces);
        if start > stop || !haystack.is_position(start) || !haystack.is_position(stop) {
            return Err(Refusal::new(NOT_A_RANGE));
        }
        Ok(Walk::new(&mut self.branches, &haystack, word).within(start, stop))
    }
}

/// A top-level branch, compiled, with the word checks the core makes.
struct Branch<C> {
    /// Whether a word must start where a match starts.
    word_start: bool,
    /// Whether a word must end where a match ends.
    word_end: bool,
    /// The branch without them, as the engine compiled it.
    compiled: C,
}

/// The walk of a pattern's matches over one text.
struct Walk<'h, 'a, 'b, C> {
    /// The text.
    haystack: &'h Pieces<'a>,
    /// The text's word class.
    word: &'h dyn Fn(char) -> bool,
    /// The pattern's top-level branches, in order, compiled.
    branches: &'b mut [Branch<C>],
}

impl<'h, 'a, 'b, C: Compiled> Walk<'h, 'a, 'b, C> {
    /// The walk of the compiled `branches` over `haystack`.
    fn new(
        branches: &'b mut [Branch<C>],
        haystack: &'h Pieces<'a>,
        word: &'h dyn Fn(char) -> bool,
    ) -> Self {
        Self {
            haystack,
            word,
            branches,
        }
    }

    /// The next match of the walk from `at` whose start is at most `to`:
    /// the leftmost of the branches' answers, the earlier branch's on a
    /// tie, each branch's answer being its leftmost candidate that passes
    /// the word checks.
    fn next(&mut self, at: usize, to: usize) -> Option<Range<usize>> {
        let haystack = self.haystack;
        let word = self.word;
        let mut best: Option<Range<usize>> = None;
        for branch in self.branches.iter_mut() {
            // A later branch wins only by starting before the best so far.
            let limit = match &best {
                Some(found) if found.start == at => break,
                Some(found) => previous(haystack, found.start),
                None => to,
            };
            let mut from = at;
            while from <= limit {
                let Some(candidate) = branch.compiled.find(haystack, from, limit) else {
                    break;
                };
                // An answer outside what was asked is taken for none, so
                // the walk always moves on.
                let sound = from <= candidate.start
                    && candidate.start <= limit
                    && candidate.start <= candidate.end
                    && candidate.end <= haystack.len();
                if !sound {
                    break;
                }
                if passes(haystack, word, branch, &candidate) {
                    best = Some(candidate);
                    break;
                }
                from = next(haystack, candidate.start);
            }
        }
        best
    }

    /// Where the walk goes on after `found`: from its end, or one character
    /// further when it is empty.
    fn after(&self, found: &Range<usize>) -> usize {
        if found.is_empty() {
            next(self.haystack, found.end)
        } else {
            found.end
        }
    }

    /// The first match that starts after `offset`, walked from its row's
    /// start, or else the text's first match, wrapped.
    fn forward(&mut self, offset: usize) -> Option<(Range<usize>, bool)> {
        let len = self.haystack.len();
        let mut at = self.haystack.row_start(offset);
        while at <= len {
            let Some(found) = self.next(at, len) else {
                break;
            };
            if found.start > offset {
                return Some((found, false));
            }
            at = self.after(&found);
        }
        // No match starts after `offset`, so the text's first match, if
        // any, starts at or before it.
        self.wrap_forward(offset)
    }

    /// The text's first match, wrapped, which starts at or before `offset`
    /// if there is one.
    fn wrap_forward(&mut self, offset: usize) -> Option<(Range<usize>, bool)> {
        self.next(0, offset).map(|found| (found, true))
    }

    /// The last match that starts before `offset`, walking rows upward
    /// from its row, or else the text's last match, wrapped.
    fn backward(&mut self, offset: usize) -> Option<(Range<usize>, bool)> {
        if offset > 0 {
            let before = previous(self.haystack, offset);
            if let Some(found) = self.last(before, 0) {
                return Some((found, false));
            }
        }
        // No match starts before `offset`, so the text's last match, if
        // any, is on its row or below.
        let floor = self.haystack.row_start(offset);
        self.last(self.haystack.len(), floor)
            .map(|found| (found, true))
    }

    /// The last match that starts at or before `to`, walking each row from
    /// its start, from `to`'s row upward, and no row that starts before
    /// `floor`.
    fn last(&mut self, mut to: usize, floor: usize) -> Option<Range<usize>> {
        let mut row = self.haystack.row_start(to);
        loop {
            let mut at = row;
            let mut last = None;
            while at <= to {
                let Some(found) = self.next(at, to) else {
                    break;
                };
                at = self.after(&found);
                last = Some(found);
            }
            if last.is_some() {
                return last;
            }
            if row == 0 || row <= floor {
                return None;
            }
            // The row above ends at the line feed before this one.
            to = row - 1;
            row = self.haystack.row_start(to);
        }
    }

    /// The matches that start in `start..stop`, walked from `start`'s row
    /// start.
    fn within(&mut self, start: usize, stop: usize) -> Vec<Range<usize>> {
        let mut found = Vec::new();
        if stop <= start {
            return found;
        }
        let to = previous(self.haystack, stop);
        let mut at = self.haystack.row_start(start);
        while at <= to {
            let Some(next) = self.next(at, to) else {
                break;
            };
            at = self.after(&next);
            if next.start >= start {
                found.push(next);
            }
        }
        found
    }
}

/// Whether `candidate` passes `branch`'s word checks in `haystack`, with
/// `word` the word class.
fn passes<C>(
    haystack: &Pieces<'_>,
    word: &dyn Fn(char) -> bool,
    branch: &Branch<C>,
    candidate: &Range<usize>,
) -> bool {
    let is_word = |c: Option<char>| c.is_some_and(word);
    let starts = || {
        is_word(haystack.char_at(candidate.start))
            && !is_word(haystack.char_before(candidate.start))
    };
    let ends = || {
        is_word(haystack.char_before(candidate.end)) && !is_word(haystack.char_at(candidate.end))
    };
    (!branch.word_start || starts()) && (!branch.word_end || ends())
}

/// The position one character after `at`; one past the text's end at its
/// end.
fn next(haystack: &Pieces<'_>, at: usize) -> usize {
    at + haystack.char_at(at).map_or(1, char::len_utf8)
}

/// The position one character before `at`, which is after the text's
/// start.
fn previous(haystack: &Pieces<'_>, at: usize) -> usize {
    at - haystack.char_before(at).map_or(1, char::len_utf8)
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::ops::Range;
    use std::rc::Rc;

    use super::{CompiledPattern, Searched, matches, search};
    use crate::{Compiled, Engine, Literal, LiteralRun, Pieces, Refusal, Sequence};

    /// The text's word class, as `editor-text` states it: an ASCII letter
    /// or digit, `_`, or any character from U+0080 up.
    fn word(c: char) -> bool {
        c.is_ascii_alphanumeric() || c == '_' || u32::from(c) >= 0x80
    }

    /// A search forward from `offset` in `text`, cut into `pieces` pieces
    /// of about equal length.
    fn forward(pattern: &str, text: &str, offset: usize) -> Searched {
        search(&mut Literal, pattern, &cut(text, 3), &word, true, offset).unwrap()
    }

    /// A search backward from `offset` in `text`.
    fn backward(pattern: &str, text: &str, offset: usize) -> Searched {
        search(&mut Literal, pattern, &cut(text, 3), &word, false, offset).unwrap()
    }

    /// The matches in `start..stop` of `text`.
    fn within(pattern: &str, text: &str, start: usize, stop: usize) -> Vec<(usize, usize)> {
        matches(&mut Literal, pattern, &cut(text, 3), &word, start, stop)
            .unwrap()
            .into_iter()
            .map(|found| (found.start, found.end))
            .collect()
    }

    /// `text` cut at character boundaries into `count` pieces or fewer.
    fn cut(text: &str, count: usize) -> Vec<&str> {
        let size = text.len().div_ceil(count).max(1);
        let mut pieces = Vec::new();
        let mut start = 0;
        while start < text.len() {
            let mut end = (start + size).min(text.len());
            while !text.is_char_boundary(end) {
                end += 1;
            }
            pieces.push(&text[start..end]);
            start = end;
        }
        pieces
    }

    fn found(start: usize, stop: usize) -> Searched {
        Searched::Found {
            start,
            stop,
            wrapped: false,
        }
    }

    fn wrapped(start: usize, stop: usize) -> Searched {
        Searched::Found {
            start,
            stop,
            wrapped: true,
        }
    }

    #[test]
    fn forward_from_before_at_and_inside_a_match_answers_the_next_one() {
        let text = "x foo foo";
        assert_eq!(forward("foo", text, 0), found(2, 5));
        assert_eq!(forward("foo", text, 1), found(2, 5));
        // At a match's start, and inside it, the next one.
        assert_eq!(forward("foo", text, 2), found(6, 9));
        assert_eq!(forward("foo", text, 3), found(6, 9));
    }

    #[test]
    fn forward_goes_on_from_the_end_of_a_match_at_or_before_the_offset() {
        // `cpo-c`: the walk from the row's start takes `abab` at 0, then
        // goes on from its end, so the overlapping one at 2 is never a
        // match.
        assert_eq!(forward("abab", "abababab", 0), found(4, 8));
        assert_eq!(forward("abab", "abababab", 1), found(4, 8));
        assert_eq!(forward("abab", "abababab", 4), wrapped(0, 4));
        // The walk starts at the offset's row start, not the text's.
        assert_eq!(forward("abab", "ab\nabababab", 3), found(7, 11));
        assert_eq!(forward("abab", "ab\nbabababab", 4), found(8, 12));
    }

    #[test]
    fn forward_finds_the_first_match_after_the_cursor_on_its_row_or_below() {
        assert_eq!(forward("b", "abab", 1), found(3, 4));
        assert_eq!(forward("foo", "x\nfoo\nfoo", 0), found(2, 5));
        assert_eq!(forward("foo", "x\nfoo\nfoo", 2), found(6, 9));
    }

    #[test]
    fn forward_wraps_to_the_texts_first_match() {
        assert_eq!(forward("foo", "foo bar\nbaz", 5), wrapped(0, 3));
        assert_eq!(forward("a", "a\nb a\nc", 4), wrapped(0, 1));
        // The only match, at the offset itself: the same match, wrapped.
        assert_eq!(forward("foo", "x foo y", 2), wrapped(2, 5));
    }

    #[test]
    fn backward_answers_the_last_match_that_starts_before_the_offset() {
        let text = "foo foo foo";
        assert_eq!(backward("foo", text, 10), found(8, 11));
        assert_eq!(backward("foo", text, 9), found(8, 11));
        // A match at the offset itself is not taken.
        assert_eq!(backward("foo", text, 8), found(4, 7));
        assert_eq!(backward("foo", text, 5), found(4, 7));
        // Rows upward.
        assert_eq!(backward("foo", "foo\nbar\nbaz", 9), found(0, 3));
        assert_eq!(backward("ba", "foo\nbar\nbaz", 11), found(8, 10));
        assert_eq!(backward("ba", "foo\nbar\nbaz", 8), found(4, 6));
    }

    #[test]
    fn backward_takes_each_rows_matches_from_its_start() {
        // The row's walk takes 0 and 4, never 2.
        assert_eq!(backward("abab", "abababab", 8), found(4, 8));
        assert_eq!(backward("abab", "abababab", 4), found(0, 4));
        assert_eq!(backward("abab", "abababab", 3), found(0, 4));
        assert_eq!(backward("abab", "abababab\nx", 10), found(4, 8));
    }

    #[test]
    fn backward_wraps_to_the_texts_last_match() {
        assert_eq!(backward("foo", "foo foo", 0), wrapped(4, 7));
        assert_eq!(backward("foo", "x\nfoo\nfoo foo", 1), wrapped(10, 13));
        assert_eq!(backward("foo", "x foo y", 2), wrapped(2, 5));
        assert_eq!(backward("foo", "x foo y", 1), wrapped(2, 5));
    }

    #[test]
    fn a_pattern_that_matches_nowhere_is_not_found() {
        assert_eq!(forward("x", "foo\nbar", 2), Searched::NotFound);
        assert_eq!(backward("x", "foo\nbar", 2), Searched::NotFound);
        assert_eq!(forward("x", "", 0), Searched::NotFound);
        assert_eq!(backward("x", "", 0), Searched::NotFound);
        assert_eq!(within("x", "", 0, 0), []);
    }

    #[test]
    fn a_word_start_and_end_are_checked_with_the_texts_class() {
        let whole = r"\<foo\>";
        assert_eq!(forward(whole, "food foo", 0), found(5, 8));
        assert_eq!(forward(whole, "_foo foo", 0), found(5, 8));
        assert_eq!(forward(whole, "foo_ foo", 0), found(5, 8));
        // A character from U+0080 up is a word character.
        assert_eq!(forward(whole, "éfoo foo", 0), found(6, 9));
        assert_eq!(forward(whole, "fooé foo", 0), found(6, 9));
        // Punctuation and a row's ends are not.
        assert_eq!(forward(whole, "x(foo)", 0), found(2, 5));
        assert_eq!(forward(whole, "x\nfoo\n", 0), found(2, 5));
        assert_eq!(forward(whole, "food", 0), Searched::NotFound);
        // `\<` alone, and `\>` alone.
        assert_eq!(forward(r"\<oo", "foo oo", 0), found(4, 6));
        assert_eq!(forward(r"fo\>", "foo fo", 0), found(4, 6));
        assert_eq!(backward(whole, "foo food", 8), found(0, 3));
    }

    #[test]
    fn a_candidate_that_fails_the_word_check_is_retried_one_character_after_its_start() {
        // `aa` at 0 ends inside a word; the walk tries again from 1, not
        // from 2, and finds `aa` at 1, which ends at the word's end.
        assert_eq!(within(r"aa\>", "aaa", 0, 3), [(1, 3)]);
        assert_eq!(within(r"\<aa", "aaa aa", 0, 6), [(0, 2), (4, 6)]);
        // One character is a whole character.
        assert_eq!(within(r"éé\>", "ééé", 0, 6), [(2, 6)]);
    }

    #[test]
    fn alternatives_are_searched_one_by_one_and_the_leftmost_wins() {
        assert_eq!(forward(r"\<foo\>\|\<bar\>", "xbar bar foo", 0), found(5, 8));
        assert_eq!(forward(r"foo\|bar", "bar foo", 0), found(4, 7));
        assert_eq!(within(r"foo\|bar", "bar foo", 0, 7), [(0, 3), (4, 7)]);
        // Of two that start together, the earlier.
        assert_eq!(within(r"ab\|a", "ab", 0, 2), [(0, 2)]);
        assert_eq!(within(r"a\|ab", "ab", 0, 2), [(0, 1)]);
    }

    #[test]
    fn an_empty_match_steps_one_character() {
        // The second alternative is empty, so it matches everywhere the
        // first does not.
        assert_eq!(within(r"x\|", "ab", 0, 2), [(0, 0), (1, 1)]);
        assert_eq!(within(r"x\|", "éa", 0, 3), [(0, 0), (2, 2)]);
        assert_eq!(within(r"a\|", "ab", 0, 2), [(0, 1), (1, 1)]);
        assert_eq!(forward(r"x\|", "ab", 0), found(1, 1));
        assert_eq!(forward(r"x\|", "ab", 2), wrapped(0, 0));
        assert_eq!(backward(r"x\|", "ab", 2), found(1, 1));
        assert_eq!(backward(r"x\|", "ab\nc", 3), found(2, 2));
    }

    #[test]
    fn escaped_specials_case_and_offsets_in_bytes() {
        assert_eq!(forward(r"a\.b", "axb a.b", 0), found(4, 7));
        assert_eq!(forward("Foo", "foo Foo", 0), found(4, 7));
        assert_eq!(forward("漢字", "é漢字 漢字", 0), found(2, 8));
        assert_eq!(forward("漢字", "é漢字 漢字", 2), found(9, 15));
    }

    #[test]
    fn a_carriage_return_is_a_character_of_its_row() {
        let text = "foo\r\nfoo\r\n";
        assert_eq!(forward(r"\<foo\>", text, 0), found(5, 8));
        assert_eq!(forward("o\r", text, 0), found(2, 4));
        assert_eq!(backward("foo", text, 10), found(5, 8));
        assert_eq!(within("\r", text, 0, 10), [(3, 4), (8, 9)]);
    }

    #[test]
    fn matches_in_a_range_are_walked_from_its_starts_row_start() {
        assert_eq!(within("aa", "aaaa", 1, 4), [(2, 4)]);
        assert_eq!(within("aa", "aaaa", 0, 4), [(0, 2), (2, 4)]);
        assert_eq!(within("aa", "x\naaaa", 3, 6), [(4, 6)]);
        // A match that starts in the range and ends after it is answered.
        assert_eq!(within("foo", "foo foo", 0, 5), [(0, 3), (4, 7)]);
        assert_eq!(within("foo", "foo foo", 0, 4), [(0, 3)]);
        assert_eq!(within("foo", "foo foo", 1, 4), []);
        assert_eq!(within("foo", "foo\nfoo\nfoo", 2, 9), [(4, 7), (8, 11)]);
        assert_eq!(within("foo", "foo foo", 3, 3), []);
    }

    #[test]
    fn a_pattern_that_does_not_parse_or_compile_is_refused() {
        let pieces = ["a.b"];
        let refused = |pattern: &str| {
            search(&mut Literal, pattern, &pieces, &word, true, 0)
                .unwrap_err()
                .reason()
                .to_owned()
        };
        assert_eq!(refused(r"\("), r"E54: Unmatched \(");
        assert_eq!(
            refused("~"),
            "E33: No previous substitute regular expression"
        );
        assert_eq!(refused(""), "the pattern is empty");
        assert_eq!(refused("a.b"), Literal::REFUSAL);
        assert_eq!(refused(r"a\|."), Literal::REFUSAL);
        assert_eq!(
            matches(&mut Literal, "a*", &pieces, &word, 0, 3)
                .unwrap_err()
                .reason(),
            Literal::REFUSAL
        );
    }

    #[test]
    fn an_offset_that_is_not_a_position_is_refused() {
        let pieces = ["é", "a"];
        let reason = |result: Result<Searched, Refusal>| result.unwrap_err().reason().to_owned();
        assert_eq!(
            reason(search(&mut Literal, "a", &pieces, &word, true, 1)),
            "the offset is not a position in the text"
        );
        assert_eq!(
            reason(search(&mut Literal, "a", &pieces, &word, false, 4)),
            "the offset is not a position in the text"
        );
        assert!(search(&mut Literal, "a", &pieces, &word, true, 3).is_ok());
        let range = |start, stop| {
            matches(&mut Literal, "a", &pieces, &word, start, stop)
                .unwrap_err()
                .reason()
                .to_owned()
        };
        assert_eq!(range(2, 1), "the range is not two positions in order");
        assert_eq!(range(1, 3), "the range is not two positions in order");
        assert_eq!(range(0, 4), "the range is not two positions in order");
    }

    /// Each question an engine was asked: `from` and `to`.
    type Asked = Rc<RefCell<Vec<(usize, usize)>>>;

    /// The fake, recording each question it is asked.
    struct Recording(Asked);

    /// A run compiled by [`Recording`].
    struct RecordingRun(LiteralRun, Asked);

    impl Engine for Recording {
        type Compiled = RecordingRun;

        fn compile(&mut self, sequence: &Sequence) -> Result<RecordingRun, Refusal> {
            Ok(RecordingRun(Literal.compile(sequence)?, Rc::clone(&self.0)))
        }
    }

    impl Compiled for RecordingRun {
        fn find(&mut self, haystack: &Pieces<'_>, from: usize, to: usize) -> Option<Range<usize>> {
            self.1.borrow_mut().push((from, to));
            self.0.find(haystack, from, to)
        }
    }

    /// The fake, counting the sequences it compiles.
    struct Counting(Rc<RefCell<usize>>);

    impl Engine for Counting {
        type Compiled = LiteralRun;

        fn compile(&mut self, sequence: &Sequence) -> Result<LiteralRun, Refusal> {
            *self.0.borrow_mut() += 1;
            Literal.compile(sequence)
        }
    }

    #[test]
    fn a_compiled_pattern_compiles_each_branch_once_and_answers_matches_in_many_texts() {
        let compiled = Rc::new(RefCell::new(0));
        let mut engine = Counting(Rc::clone(&compiled));
        let mut pattern = CompiledPattern::new(&mut engine, r"\<foo\>\|bar").expect("it compiles");
        let mut answers = Vec::new();
        for text in ["foo bar", "food", "x\nbar foo", ""] {
            let pieces = cut(text, 2);
            let found = pattern
                .matches(&pieces, &word, 0, text.len())
                .expect("a range");
            answers.push(
                found
                    .into_iter()
                    .map(|m| (m.start, m.end))
                    .collect::<Vec<_>>(),
            );
        }

        assert_eq!(*compiled.borrow(), 2, "one compile a branch");
        assert_eq!(
            answers,
            [vec![(0, 3), (4, 7)], vec![], vec![(2, 5), (6, 9)], vec![]]
        );
        assert_eq!(
            pattern.matches(&["ab"], &word, 2, 1).unwrap_err().reason(),
            "the range is not two positions in order"
        );
        assert_eq!(
            CompiledPattern::new(&mut Literal, r"\(")
                .err()
                .map(|r| r.reason().to_owned()),
            Some(r"E54: Unmatched \(".to_owned())
        );
    }

    #[test]
    fn a_backward_search_asks_each_row_once_within_the_row() {
        // The match is on the first row, and the search starts at the
        // last: every row is walked, each with one question inside it.
        let rows = 2_000;
        let text = format!("foo\n{}", "x\n".repeat(rows));
        let asked = Asked::default();
        let mut engine = Recording(Rc::clone(&asked));
        let pieces = cut(&text, 7);
        let answer = search(&mut engine, "foo", &pieces, &word, false, text.len()).unwrap();
        assert_eq!(answer, found(0, 3));
        let haystack = Pieces::new(&pieces);
        let asked = asked.borrow();
        assert!(asked.len() <= rows + 3, "{} questions", asked.len());
        for &(from, to) in asked.iter() {
            assert_eq!(
                haystack.row_start(from),
                haystack.row_start(to),
                "{from}..={to}"
            );
        }
    }

    #[test]
    fn a_backward_search_that_wraps_walks_each_row_once_more_at_most() {
        let rows = 2_000;
        let text = format!("{}foo", "x\n".repeat(rows));
        let asked = Asked::default();
        let mut engine = Recording(Rc::clone(&asked));
        let pieces = cut(&text, 7);
        let answer = search(&mut engine, "foo", &pieces, &word, false, 1).unwrap();
        assert_eq!(answer, wrapped(2 * rows, 2 * rows + 3));
        assert!(asked.borrow().len() <= 2 * rows + 3);
    }

    #[test]
    fn a_forward_search_asks_once_past_the_offsets_row() {
        let text = format!("x\n{}foo", "y\n".repeat(2_000));
        let asked = Asked::default();
        let mut engine = Recording(Rc::clone(&asked));
        let pieces = cut(&text, 7);
        let answer = search(&mut engine, "foo", &pieces, &word, true, 0).unwrap();
        assert_eq!(answer, found(text.len() - 3, text.len()));
        assert_eq!(asked.borrow().len(), 1);
    }
}
