//! Pairs: the bracket a walk leaves unbalanced, and the quoted string round
//! a position.
//!
//! Two reads of a snapshot that Vim's `%` and its block and quote objects
//! are built on ([`Snapshot::unmatched`], [`Snapshot::quoted`]). Each walks
//! the rope by characters from the position it is given, as a motion does
//! (the private module `motion`), and builds nothing: no string, no list of
//! the text's characters.
//!
//! These are primitives. Which bracket a key asks for, a count, where a
//! text object starts and ends, and the blanks round a quoted string are
//! the editor's rules, and are not here.

use std::ops::Range;

use crate::snapshot::Snapshot;

/// A kind of bracket: a pair of an opening character and a closing one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Bracket {
    /// `(` and `)`.
    Round,
    /// `[` and `]`.
    Square,
    /// `{` and `}`.
    Curly,
}

impl Bracket {
    /// The opening character.
    pub fn opening(self) -> char {
        match self {
            Bracket::Round => '(',
            Bracket::Square => '[',
            Bracket::Curly => '{',
        }
    }

    /// The closing character.
    pub fn closing(self) -> char {
        match self {
            Bracket::Round => ')',
            Bracket::Square => ']',
            Bracket::Curly => '}',
        }
    }
}

/// A kind of quote: one character that opens a quoted string and closes
/// it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Quote {
    /// `"`.
    Double,
    /// `'`.
    Single,
    /// `` ` ``.
    Back,
}

impl Quote {
    /// The quote's character.
    pub fn character(self) -> char {
        match self {
            Quote::Double => '"',
            Quote::Single => '\'',
            Quote::Back => '`',
        }
    }
}

/// The character that escapes the one after it: a backslash, Vim's default
/// `quoteescape`, and the backslash its block objects and `%` count.
const ESCAPE: char = '\\';

impl Snapshot {
    /// The first bracket of the kind `bracket` that the walk from the
    /// position `offset` leaves unbalanced: an opening one when `opening`
    /// and a closing one otherwise, walking strictly after `offset` when
    /// `forward` and strictly before it otherwise.
    ///
    /// Each bracket of the other side the walk meets raises the depth, and
    /// each of the side sought lowers it; the answer is the first of the
    /// side sought met at depth 0. Only brackets whose escapedness is
    /// `escaped` are counted: a bracket is escaped when an odd number of
    /// backslashes stands right before it. The walk crosses rows and
    /// treats quotes as any other character. This is Vim 9.1's
    /// `findmatchlimit` with `cpo` holding `%` and not `M`.
    ///
    /// `Some(None)` when there is no such bracket; `None` unless `offset`
    /// is a position.
    pub fn unmatched(
        &self,
        bracket: Bracket,
        opening: bool,
        forward: bool,
        escaped: bool,
        offset: usize,
    ) -> Option<Option<usize>> {
        if !self.is_char_boundary(offset) {
            return None;
        }
        let (sought, other) = if opening {
            (bracket.opening(), bracket.closing())
        } else {
            (bracket.closing(), bracket.opening())
        };
        let mut depth = 0_usize;
        let mut at = offset;
        // Strictly after the position: the character there is passed over.
        if forward {
            let Some(here) = self.char_at(at) else {
                return Some(None);
            };
            at += here.len_utf8();
        }
        loop {
            // The character the walk meets next, and where it starts.
            let (start, character) = if forward {
                let Some(next) = self.char_at(at) else {
                    return Some(None);
                };
                at += next.len_utf8();
                (at - next.len_utf8(), next)
            } else {
                let Some(before) = self.char_before(at) else {
                    return Some(None);
                };
                at -= before.len_utf8();
                (at, before)
            };
            if (character == sought || character == other) && self.escaped(start) == escaped {
                if character == other {
                    depth += 1;
                } else if depth == 0 {
                    return Some(Some(start));
                } else {
                    depth -= 1;
                }
            }
        }
    }

    /// Whether an odd number of backslashes stands right before the
    /// position `offset`. A line feed is no backslash, so the count stays
    /// in the row.
    fn escaped(&self, offset: usize) -> bool {
        let mut count = 0_usize;
        let mut at = offset;
        while self.char_before(at) == Some(ESCAPE) {
            count += 1;
            at -= ESCAPE.len_utf8();
        }
        count % 2 == 1
    }

    /// The quoted string of the kind `quote` round the position `offset`,
    /// within its row: from its opening quote through its closing one.
    /// This is Vim 9.1's `current_quote` for a cursor with no Visual area
    /// and `quoteescape` a backslash, where a backslash escapes the
    /// character after it. The cursor is `offset`, or where the row's
    /// content ends when `offset` is past it, between a carriage return and
    /// its line feed.
    ///
    /// - **On a quote**, the row's pairs are walked from its start: an
    ///   opening quote is the next quote, escaped or not, and its closing
    ///   one the next quote after it that is not escaped. The answer is the
    ///   first pair whose span holds the cursor, and there is none once an
    ///   opening quote is after it.
    /// - **Elsewhere**, the opening quote is the nearest quote before the
    ///   cursor that is not escaped. With none, it is the row's first
    ///   quote, escaped or not, which is after the cursor unless an escaped
    ///   one is before it. The closing quote is the next one after the
    ///   opening one that is not escaped.
    ///
    /// Nothing outside the row is read. `Some(None)` when a quote is
    /// missing; `None` unless `offset` is a position.
    pub fn quoted(&self, quote: Quote, offset: usize) -> Option<Option<Range<usize>>> {
        let (row, _) = self.row_of_position(offset)?;
        let content = self.row_content(row)?;
        let quote = quote.character();
        let cursor = offset.min(content.end);
        let found = if self.char_at(cursor).filter(|_| cursor < content.end) == Some(quote) {
            self.pair_holding(&content, quote, cursor)
        } else {
            let mut open = self.previous_quote(&content, quote, cursor);
            if open >= content.end || self.char_at(open) != Some(quote) {
                open = match self.next_quote(&content, quote, open, false) {
                    Some(open) => open,
                    None => return Some(None),
                };
            }
            self.next_quote(&content, quote, open + 1, true)
                .map(|close| open..close + 1)
        };
        Some(found)
    }

    /// The first pair of quotes of the row whose content is `content` that
    /// holds `cursor`, walked from the row's start.
    fn pair_holding(
        &self,
        content: &Range<usize>,
        quote: char,
        cursor: usize,
    ) -> Option<Range<usize>> {
        let mut from = content.start;
        loop {
            let open = self.next_quote(content, quote, from, false)?;
            if open > cursor {
                return None;
            }
            let close = self.next_quote(content, quote, open + 1, true)?;
            if cursor <= close {
                return Some(open..close + 1);
            }
            from = close + 1;
        }
    }

    /// Where the first quote at or after `from` within `content` starts,
    /// passing over each character a backslash escapes when `escapes`
    /// (Vim's `find_next_quote`).
    fn next_quote(
        &self,
        content: &Range<usize>,
        quote: char,
        from: usize,
        escapes: bool,
    ) -> Option<usize> {
        let mut at = from;
        while at < content.end {
            let character = self.char_at(at)?;
            if escapes && character == ESCAPE {
                at += character.len_utf8();
                if at >= content.end {
                    return None;
                }
                at += self.char_at(at)?.len_utf8();
                continue;
            }
            if character == quote {
                return Some(at);
            }
            at += character.len_utf8();
        }
        None
    }

    /// Where the nearest quote before `from` within `content` that is not
    /// escaped starts, or the row's start when there is none (Vim's
    /// `find_prev_quote`): a character after an odd number of backslashes
    /// is passed over with them.
    fn previous_quote(&self, content: &Range<usize>, quote: char, from: usize) -> usize {
        let mut at = from;
        while at > content.start {
            at -= self.char_before(at).map_or(1, char::len_utf8);
            let mut run = at;
            while run > content.start && self.char_before(run) == Some(ESCAPE) {
                run -= ESCAPE.len_utf8();
            }
            if (at - run) % 2 == 1 {
                at = run;
            } else if self.char_at(at) == Some(quote) {
                break;
            }
        }
        at
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Text;

    /// What `unmatched` answers in `text`.
    fn unmatched(
        text: &str,
        bracket: Bracket,
        opening: bool,
        forward: bool,
        escaped: bool,
        offset: usize,
    ) -> Option<Option<usize>> {
        Text::from(text)
            .snapshot()
            .unmatched(bracket, opening, forward, escaped, offset)
    }

    /// What `quoted` answers in `text`.
    fn quoted(text: &str, quote: Quote, offset: usize) -> Option<Option<Range<usize>>> {
        Text::from(text).snapshot().quoted(quote, offset)
    }

    #[test]
    fn each_bracket_has_its_two_characters_and_each_quote_its_one() {
        let pairs = [Bracket::Round, Bracket::Square, Bracket::Curly]
            .map(|bracket| (bracket.opening(), bracket.closing()));
        assert_eq!(pairs, [('(', ')'), ('[', ']'), ('{', '}')]);
        let quotes = [Quote::Double, Quote::Single, Quote::Back].map(Quote::character);
        assert_eq!(quotes, ['"', '\'', '`']);
    }

    #[test]
    fn a_closing_bracket_forward_is_the_first_one_the_walk_leaves_unbalanced() {
        // "f(a, (b), c)": the inner pair is passed over.
        let text = "f(a, (b), c)";
        assert_eq!(
            unmatched(text, Bracket::Round, false, true, false, 3),
            Some(Some(11))
        );
        // From the opening bracket itself, its own partner.
        assert_eq!(
            unmatched(text, Bracket::Round, false, true, false, 1),
            Some(Some(11))
        );
        assert_eq!(
            unmatched(text, Bracket::Round, false, true, false, 5),
            Some(Some(7))
        );
    }

    #[test]
    fn an_opening_bracket_backward_is_the_first_one_the_walk_leaves_unbalanced() {
        let text = "f(a, (b), c)";
        assert_eq!(
            unmatched(text, Bracket::Round, true, false, false, 9),
            Some(Some(1))
        );
        // From a closing bracket, its own partner: the walk is strict.
        assert_eq!(
            unmatched(text, Bracket::Round, true, false, false, 11),
            Some(Some(1))
        );
        assert_eq!(
            unmatched(text, Bracket::Round, true, false, false, 7),
            Some(Some(5))
        );
    }

    #[test]
    fn the_walk_is_strict_about_the_position_it_starts_from() {
        // From the closing bracket going on, it is not its own answer.
        assert_eq!(
            unmatched("(a) b)", Bracket::Round, false, true, false, 2),
            Some(Some(5))
        );
        // From an opening bracket going back, nor is it.
        assert_eq!(
            unmatched("((a)", Bracket::Round, true, false, false, 1),
            Some(Some(0))
        );
    }

    #[test]
    fn an_opening_bracket_forward_mirrors_the_walk_back() {
        // A closing bracket met first raises the depth.
        assert_eq!(
            unmatched("x (a)", Bracket::Round, true, true, false, 0),
            Some(Some(2))
        );
        assert_eq!(
            unmatched("x) (a)", Bracket::Round, true, true, false, 0),
            Some(None)
        );
        assert_eq!(
            unmatched("x ((a))", Bracket::Round, true, true, false, 2),
            Some(Some(3))
        );
    }

    #[test]
    fn only_the_brackets_of_the_kind_asked_for_are_counted() {
        let text = "(a [b) c] {d})";
        assert_eq!(
            unmatched(text, Bracket::Round, false, true, false, 0),
            Some(Some(5))
        );
        assert_eq!(
            unmatched(text, Bracket::Square, false, true, false, 4),
            Some(Some(8))
        );
        assert_eq!(
            unmatched(text, Bracket::Curly, true, false, false, 12),
            Some(Some(10))
        );
    }

    #[test]
    fn an_escaped_bracket_is_counted_only_when_escaped_brackets_are_asked_for() {
        // "(a \( b)": the escaped one is passed over, and is the one found.
        let text = "(a \\( b)";
        assert_eq!(
            unmatched(text, Bracket::Round, true, false, false, 6),
            Some(Some(0))
        );
        assert_eq!(
            unmatched(text, Bracket::Round, true, false, true, 6),
            Some(Some(4))
        );
        // Two backslashes escape each other, and the bracket after them is
        // not escaped.
        let text = "a \\\\( b)";
        assert_eq!(
            unmatched(text, Bracket::Round, true, false, false, 6),
            Some(Some(4))
        );
        assert_eq!(
            unmatched(text, Bracket::Round, true, false, true, 6),
            Some(None)
        );
        // "\(a\)": the escaped pair matches as escaped.
        let text = "\\(a\\)";
        assert_eq!(
            unmatched(text, Bracket::Round, false, true, true, 1),
            Some(Some(4))
        );
        assert_eq!(
            unmatched(text, Bracket::Round, false, true, false, 1),
            Some(None)
        );
    }

    #[test]
    fn the_walk_crosses_rows_and_quotes_are_characters_like_any_other() {
        // A pair across rows, one of them with a carriage return and a line
        // feed, and a closing bracket inside quotes counted.
        let text = "{\r\n  a\n\")\"\n}";
        assert_eq!(
            unmatched(text, Bracket::Curly, false, true, false, 0),
            Some(Some(11))
        );
        assert_eq!(
            unmatched(text, Bracket::Curly, true, false, false, 11),
            Some(Some(0))
        );
        assert_eq!(
            unmatched("(a \")\" b)", Bracket::Round, false, true, false, 0),
            Some(Some(4))
        );
    }

    #[test]
    fn offsets_are_bytes_through_characters_of_several() {
        // "é" is two bytes and "😀" four.
        let text = "(é😀)";
        assert_eq!(
            unmatched(text, Bracket::Round, false, true, false, 0),
            Some(Some(7))
        );
        assert_eq!(
            unmatched(text, Bracket::Round, true, false, false, 7),
            Some(Some(0))
        );
    }

    #[test]
    fn with_no_bracket_left_unbalanced_there_is_no_answer() {
        assert_eq!(
            unmatched("(a", Bracket::Round, false, true, false, 0),
            Some(None)
        );
        assert_eq!(
            unmatched("a)", Bracket::Round, true, false, false, 2),
            Some(None)
        );
        assert_eq!(
            unmatched("", Bracket::Round, false, true, false, 0),
            Some(None)
        );
        assert_eq!(
            unmatched("", Bracket::Round, true, false, false, 0),
            Some(None)
        );
    }

    #[test]
    fn the_bracket_walk_is_refused_from_an_offset_that_is_no_position() {
        // Inside "é", and past the end.
        for offset in [2, 5, usize::MAX] {
            for forward in [false, true] {
                assert_eq!(
                    unmatched("(é)", Bracket::Round, true, forward, false, offset),
                    None,
                    "{offset}"
                );
            }
        }
    }

    #[test]
    fn a_deep_nesting_is_walked_through() {
        let depth = 10_000;
        let text = format!("{}{}", "(".repeat(depth), ")".repeat(depth));
        assert_eq!(
            unmatched(&text, Bracket::Round, false, true, false, 0),
            Some(Some(2 * depth - 1))
        );
        assert_eq!(
            unmatched(&text, Bracket::Round, true, false, false, 2 * depth - 1),
            Some(Some(0))
        );
    }

    #[test]
    fn a_text_of_many_pieces_is_walked_as_its_string_is() {
        // Escaped pairs, each a backslash and a bracket that the rope's
        // pieces split somewhere, and an unescaped pair round them all.
        let middle = "\\(x\\) ".repeat(50_000);
        let text = format!("({middle})");
        let snapshot = Text::from(text.as_str()).snapshot();
        assert!(snapshot.chunks().count() > 1);
        assert_eq!(
            snapshot.unmatched(Bracket::Round, false, true, false, 0),
            Some(Some(text.len() - 1))
        );
        assert_eq!(
            snapshot.unmatched(Bracket::Round, true, false, false, text.len() - 1),
            Some(Some(0))
        );
        // The last escaped opening bracket, from inside its pair, and its
        // partner.
        let last = text.len() - 1 - "\\(x\\) ".len() + 1;
        assert_eq!(
            snapshot.unmatched(Bracket::Round, true, false, true, last + 1),
            Some(Some(last))
        );
        assert_eq!(
            snapshot.unmatched(Bracket::Round, false, true, true, last),
            Some(Some(last + 3))
        );
    }

    #[test]
    fn a_cursor_before_the_first_quote_takes_the_first_string() {
        assert_eq!(quoted("x = \"ab\" y", Quote::Double, 0), Some(Some(4..8)));
        assert_eq!(quoted("x = \"ab\" y", Quote::Double, 5), Some(Some(4..8)));
    }

    #[test]
    fn a_cursor_on_a_quote_takes_the_pair_that_holds_it_walking_from_the_row_start() {
        let text = "\"a\" \"b\"";
        // On the opening quote and on the closing one of each string.
        assert_eq!(quoted(text, Quote::Double, 0), Some(Some(0..3)));
        assert_eq!(quoted(text, Quote::Double, 2), Some(Some(0..3)));
        assert_eq!(quoted(text, Quote::Double, 4), Some(Some(4..7)));
        assert_eq!(quoted(text, Quote::Double, 6), Some(Some(4..7)));
        // A quote no pair holds: the last of an odd number.
        assert_eq!(quoted("\"a\" \"", Quote::Double, 4), Some(None));
    }

    #[test]
    fn between_two_strings_the_closing_quote_before_and_the_opening_one_after_are_a_pair() {
        assert_eq!(quoted("\"a\" x \"b\"", Quote::Double, 4), Some(Some(2..7)));
    }

    #[test]
    fn an_escaped_quote_does_not_close_a_string() {
        // "a\"b"
        let text = "\"a\\\"b\"";
        assert_eq!(quoted(text, Quote::Double, 1), Some(Some(0..6)));
        assert_eq!(quoted(text, Quote::Double, 4), Some(Some(0..6)));
        // Two backslashes escape each other.
        assert_eq!(quoted("\"a\\\\\"b\"", Quote::Double, 6), Some(None));
        assert_eq!(quoted("\"a\\\\\"b\"", Quote::Double, 1), Some(Some(0..5)));
    }

    #[test]
    fn with_no_quote_before_the_cursor_the_rows_first_quote_opens_escaped_or_not() {
        // \"x y "a": the escaped quote is the row's first.
        let text = "\\\"x y \"a\"";
        assert_eq!(quoted(text, Quote::Double, 3), Some(Some(1..7)));
        // An escaped quote before the cursor is no quote before it.
        let text = "x \\\"a\" y";
        assert_eq!(quoted(text, Quote::Double, 4), Some(Some(3..6)));
    }

    #[test]
    fn a_missing_quote_is_no_string() {
        assert_eq!(quoted("a \"b", Quote::Double, 0), Some(None));
        assert_eq!(quoted("x \"ab\" y", Quote::Double, 7), Some(None));
        assert_eq!(quoted("ab", Quote::Double, 1), Some(None));
        assert_eq!(quoted("", Quote::Double, 0), Some(None));
        // The empty row between two rows that have quotes.
        assert_eq!(quoted("\"a\"\n\n\"b\"", Quote::Double, 4), Some(None));
    }

    #[test]
    fn each_kind_of_quote_is_its_own_character() {
        let text = "\"a\" 'b' `c`";
        assert_eq!(quoted(text, Quote::Double, 1), Some(Some(0..3)));
        assert_eq!(quoted(text, Quote::Single, 5), Some(Some(4..7)));
        assert_eq!(quoted(text, Quote::Back, 9), Some(Some(8..11)));
        assert_eq!(quoted("'a'", Quote::Double, 1), Some(None));
    }

    #[test]
    fn a_quote_never_leaves_its_row() {
        // A string that would run across the line break is none.
        assert_eq!(quoted("\"a\nb\"", Quote::Double, 1), Some(None));
        assert_eq!(quoted("\"a\nb\"", Quote::Double, 3), Some(None));
        // In a row that ends in a carriage return and a line feed, from
        // inside the string, from the line break and from between its two
        // bytes: where the content ends the cursor is on no quote, and the
        // nearest one before it opens no string.
        let text = "\"a\"\r\nb";
        assert_eq!(quoted(text, Quote::Double, 1), Some(Some(0..3)));
        assert_eq!(quoted(text, Quote::Double, 3), Some(None));
        assert_eq!(quoted(text, Quote::Double, 4), Some(None));
    }

    #[test]
    fn offsets_of_a_quote_are_bytes_through_characters_of_several() {
        assert_eq!(quoted("é\"😀\"", Quote::Double, 3), Some(Some(2..8)));
    }

    #[test]
    fn the_quote_walk_is_refused_from_an_offset_that_is_no_position() {
        for offset in [1, 4, usize::MAX] {
            assert_eq!(quoted("é\"", Quote::Double, offset), None, "{offset}");
        }
    }
}
