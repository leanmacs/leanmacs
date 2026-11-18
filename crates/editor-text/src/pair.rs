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

/// What a bracket walk that passes over quoted brackets knows of quotes
/// (the locals of Vim 9.1's `findmatchlimit` of the same names).
#[derive(Debug, Default)]
struct QuoteState {
    /// Whether the quotes of the row the walk is in have been counted.
    counted: bool,
    /// Whether the row's double quotes start and end strings
    /// (`do_quotes`): its count of them is even, or a string goes on
    /// across its line break.
    read: bool,
    /// Whether the walk is inside a string (`inquote`).
    inside: bool,
    /// Whether the walk started inside a string, so that brackets inside
    /// one are counted (`start_in_quotes`); `None` until the first row's
    /// quotes are counted.
    start: Option<bool>,
}

/// What [`Snapshot::quote_walk`] makes of a position.
enum Step {
    /// A character that may be a bracket: it is read.
    Read,
    /// A quote or a row's end: no bracket.
    Passed,
    /// A single quote and what it holds: the walk goes on from the given
    /// position, the other single quote.
    Over(usize),
}

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
    /// backslashes stands right before it. The walk crosses rows. This is
    /// Vim 9.1's `findmatchlimit` with `cpo` not holding `M`, and holding
    /// `%` unless `skip_quoted`.
    ///
    /// When `skip_quoted`, brackets Vim guesses are quoted are passed over,
    /// as its default `cpo` does (`Snapshot::quote_walk` has the rule);
    /// otherwise quotes are characters like any other.
    ///
    /// `Some(None)` when there is no such bracket; `None` unless `offset`
    /// is a position.
    pub fn unmatched(
        &self,
        bracket: Bracket,
        opening: bool,
        forward: bool,
        escaped: bool,
        skip_quoted: bool,
        offset: usize,
    ) -> Option<Option<usize>> {
        let (mut row, _) = self.row_of_position(offset)?;
        let (sought, other) = if opening {
            (bracket.opening(), bracket.closing())
        } else {
            (bracket.closing(), bracket.opening())
        };
        let mut content = self.row_content(row)?;
        // Within the line break, the walk is where the row's content ends:
        // Vim's NUL.
        let mut at = offset.min(content.end);
        let mut quotes = QuoteState::default();
        let mut depth = 0_usize;
        loop {
            // The next position, which is a row's end at its line break.
            let mut entered = false;
            if forward {
                if at == content.end {
                    row += 1;
                    if row >= self.row_count() {
                        return Some(None);
                    }
                    content = self.row_content(row)?;
                    at = content.start;
                    entered = true;
                } else {
                    at += self.char_at(at)?.len_utf8();
                }
            } else if at == content.start {
                let Some(above) = row.checked_sub(1) else {
                    return Some(None);
                };
                row = above;
                content = self.row_content(row)?;
                at = content.end;
                entered = true;
            } else {
                at -= self.char_before(at)?.len_utf8();
            }
            if skip_quoted && (entered || !quotes.counted) {
                self.count_row_quotes(&mut quotes, row, &content, at, forward);
            }
            quotes.start.get_or_insert(false);
            if skip_quoted {
                match self.quote_walk(&mut quotes, &content, at, forward) {
                    Step::Over(to) => {
                        at = to;
                        continue;
                    }
                    Step::Passed => continue,
                    Step::Read => {}
                }
            }
            if at == content.end {
                continue;
            }
            let character = self.char_at(at)?;
            if (!quotes.inside || quotes.start == Some(true))
                && (character == sought || character == other)
                && self.escaped(at) == escaped
            {
                if character == other {
                    depth += 1;
                } else if depth == 0 {
                    return Some(Some(at));
                } else {
                    depth -= 1;
                }
            }
        }
    }

    /// Vim 9.1's count of the double quotes of the row `row`, whose content
    /// is `content`, when the walk enters it at `at` (`do_quotes`, in
    /// `findmatchlimit`). A double quote is counted unless a backslash
    /// escapes it or a single quote stands on each side of it.
    ///
    /// With an even count the row's quotes are read (`quotes.read`), and
    /// the walk starts outside a string. With an odd one they are not,
    /// unless the row or the one above it ends in a backslash, a string
    /// that goes on: then they are read, and whether the walk is inside a
    /// string, and whether it started inside one, are Vim's guess from
    /// where the walk is and which way it goes.
    fn count_row_quotes(
        &self,
        quotes: &mut QuoteState,
        row: usize,
        content: &Range<usize>,
        at: usize,
        forward: bool,
    ) {
        quotes.counted = true;
        // Whether an even number of quotes stands before where the walk
        // looks: one past the position going back. Vim's `at_start`, which
        // is true when the count passes over that byte.
        let looked = at + usize::from(!forward);
        let mut even_at_start = true;
        let mut count = 0_usize;
        let mut walked = content.start;
        while walked < content.end {
            if walked == looked {
                even_at_start = count.is_multiple_of(2);
            }
            let byte = self.byte_in(content, walked);
            if byte == b'"'
                && (walked == content.start
                    || self.byte_in(content, walked - 1) != b'\''
                    || self.byte_in(content, walked + 1) != b'\'')
            {
                count += 1;
            }
            if byte == b'\\' && self.byte_in(content, walked + 1) != 0 {
                walked += 1;
            }
            walked += 1;
        }
        quotes.read = count.is_multiple_of(2);
        if quotes.read {
            return;
        }
        quotes.inside = false;
        // An odd count is never of an empty row.
        if self.byte_in(content, content.end - 1) == b'\\' {
            quotes.read = true;
            if quotes.start.is_none() {
                quotes.inside = true;
                quotes.start = Some(true);
            } else if !forward {
                quotes.inside = true;
            }
        }
        let Some(above) = row.checked_sub(1).and_then(|above| self.row_content(above)) else {
            return;
        };
        if above.end > above.start && self.byte_in(&above, above.end - 1) == b'\\' {
            quotes.read = true;
            if quotes.start.is_none() {
                quotes.inside = even_at_start;
                if quotes.inside {
                    quotes.start = Some(true);
                }
            } else if forward {
                quotes.inside = true;
            }
        }
    }

    /// What the quotes at the position `at` of a row whose content is
    /// `content` do to the walk, as Vim 9.1's default `cpo` has it
    /// (`findmatchlimit`):
    ///
    /// - **A row's end** that no backslash is right before ends any string:
    ///   the walk is outside one from there.
    /// - **A double quote** that no odd number of backslashes is before
    ///   starts or ends a string, when the row's quotes are read. Brackets
    ///   inside a string are passed over, unless the walk started inside
    ///   one.
    /// - **A single quote** with one character and another single quote
    ///   after it (`'x'`), or a backslash, a character and a single quote
    ///   (`'\x'`), going forward, or a single quote two or three bytes
    ///   before it, after one character or a backslash and one character,
    ///   going back, is passed over with what it holds. Its character is
    ///   one byte: a character of several holds no bracket.
    fn quote_walk(
        &self,
        quotes: &mut QuoteState,
        content: &Range<usize>,
        at: usize,
        forward: bool,
    ) -> Step {
        if at == content.end {
            if at == content.start || self.byte_in(content, at - 1) != b'\\' {
                quotes.inside = false;
                quotes.start = Some(false);
            }
            return Step::Passed;
        }
        match self.byte_in(content, at) {
            b'"' => {
                let mut run = at;
                while run > content.start && self.byte_in(content, run - 1) == b'\\' {
                    run -= 1;
                }
                if quotes.read && (at - run).is_multiple_of(2) {
                    quotes.inside = !quotes.inside;
                    quotes.start = Some(false);
                }
                Step::Passed
            }
            b'\'' if forward => {
                if self.byte_in(content, at + 1) == 0 {
                    Step::Read
                } else if self.byte_in(content, at + 1) == b'\\'
                    && self.byte_in(content, at + 2) != 0
                    && self.byte_in(content, at + 3) == b'\''
                {
                    Step::Over(at + 3)
                } else if self.byte_in(content, at + 2) == b'\'' {
                    Step::Over(at + 2)
                } else {
                    Step::Read
                }
            }
            b'\'' if at - content.start > 1 => {
                if self.byte_in(content, at - 2) == b'\'' {
                    Step::Over(at - 2)
                } else if self.byte_in(content, at - 2) == b'\\'
                    && at - content.start > 2
                    && self.byte_in(content, at - 3) == b'\''
                {
                    Step::Over(at - 3)
                } else {
                    Step::Read
                }
            }
            _ => Step::Read,
        }
    }

    /// The byte at `offset` of a row whose content is `content`, or 0, Vim's
    /// NUL, at or past the content's end.
    fn byte_in(&self, content: &Range<usize>, offset: usize) -> u8 {
        if offset >= content.end {
            return 0;
        }
        self.chunk_at(offset)
            .and_then(|(chunk, start)| chunk.as_bytes().get(offset - start).copied())
            .unwrap_or(0)
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
            .unmatched(bracket, opening, forward, escaped, false, offset)
    }

    /// What `unmatched` answers in `text` passing over quoted brackets, for
    /// brackets that are not escaped: Vim's `[(` when `forward` is false,
    /// and its `])` when it is true.
    fn skipping(text: &str, bracket: Bracket, forward: bool, offset: usize) -> Option<usize> {
        Text::from(text)
            .snapshot()
            .unmatched(bracket, !forward, forward, false, true, offset)
            .expect("a position")
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
    fn the_walk_crosses_rows_and_unless_it_skips_quoted_brackets_quotes_are_characters() {
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

    // Each answer that passes over quoted brackets below is what the
    // installed Vim 9.1.1752 answers, run headless with `-Nu NONE`: `[(`
    // for a walk back, `])` for one forward and `[{` and `]}` for braces.

    #[test]
    fn a_bracket_inside_a_string_is_passed_over() {
        // (a "b)" c) and (a ")" b): both ways, from outside the string.
        assert_eq!(skipping("(a \"b)\" c)", Bracket::Round, true, 0), Some(9));
        assert_eq!(skipping("(a \")\" b)", Bracket::Round, false, 8), Some(0));
        assert_eq!(skipping("{a \"}\" b}", Bracket::Curly, true, 0), Some(8));
        assert_eq!(skipping("[a \"]\" b]", Bracket::Square, true, 0), Some(8));
        // Through characters of several bytes: (é "ü)" ö).
        assert_eq!(skipping("(é \"ü)\" ö)", Bracket::Round, true, 0), Some(12));
    }

    #[test]
    fn strings_are_read_from_where_the_walk_starts() {
        // The quote the walk starts on is not read, so from it the string
        // is behind the walk: (a "b)" c) from the opening quote.
        assert_eq!(skipping("(a \"b)\" c)", Bracket::Round, true, 3), Some(5));
        // From inside a string the walk takes its first quote as one that
        // opens: back from inside (a ")" b) there is no bracket.
        assert_eq!(skipping("(a \")\" b)", Bracket::Round, false, 4), None);
        // "(a)": inside, the pair is found both ways.
        assert_eq!(skipping("\"(a)\"", Bracket::Round, true, 1), Some(3));
        assert_eq!(skipping("\"(a)\"", Bracket::Round, false, 3), Some(1));
    }

    #[test]
    fn with_an_odd_number_of_quotes_in_the_row_no_bracket_is_passed_over() {
        // x " (a "b)" c): three quotes.
        assert_eq!(
            skipping("x \" (a \"b)\" c)", Bracket::Round, true, 4),
            Some(9)
        );
        assert_eq!(
            skipping("x \" (a \"b)\" c)", Bracket::Round, false, 9),
            Some(4)
        );
    }

    #[test]
    fn an_escaped_double_quote_is_not_counted_and_starts_no_string() {
        // (a \"b)" c): one quote counted, so none is read.
        assert_eq!(skipping("(a \\\"b)\" c)", Bracket::Round, true, 0), Some(6));
        // (a \"b) \" c): none counted, and neither starts a string, so the
        // first closing bracket is counted going back.
        assert_eq!(
            skipping("(a \\\"b) \\\" c)", Bracket::Round, false, 12),
            None
        );
        // ("a\\" b) ")": the backslash is escaped, and the quote after it
        // closes the string.
        assert_eq!(
            skipping("(\"a\\\\\" b) \")\"", Bracket::Round, true, 0),
            Some(8)
        );
    }

    #[test]
    fn a_double_quote_between_two_single_quotes_is_not_counted() {
        // (a '"' ")" b): the quotes counted are the two round ")", and the
        // single-quoted one is passed over with its quotes.
        assert_eq!(
            skipping("(a '\"' \")\" b)", Bracket::Round, true, 0),
            Some(12)
        );
    }

    #[test]
    fn a_character_in_single_quotes_is_passed_over() {
        // (a ')' b) and (a '\)' b), both ways.
        assert_eq!(skipping("(a ')' b)", Bracket::Round, true, 0), Some(8));
        assert_eq!(skipping("(a ')' b)", Bracket::Round, false, 8), Some(0));
        assert_eq!(skipping("(a '\\)' b)", Bracket::Round, true, 0), Some(9));
        assert_eq!(skipping("(a '\\)' b)", Bracket::Round, false, 9), Some(0));
        // ('(' x): a single quote at the row's second byte or earlier is not
        // looked back from.
        assert_eq!(skipping("('(' x)", Bracket::Round, true, 0), Some(6));
        // Without skipping, the quoted brackets are counted.
        assert_eq!(
            unmatched("(a ')' b)", Bracket::Round, false, true, false, 0),
            Some(Some(4))
        );
    }

    #[test]
    fn quotes_in_other_rows_are_read_in_their_own_row() {
        // {\n  "}"\n}: the string is in the middle row.
        assert_eq!(skipping("{\n  \"}\"\n}", Bracket::Curly, true, 0), Some(8));
        assert_eq!(skipping("{\n  \"}\"\n}", Bracket::Curly, false, 8), Some(0));
        // " ( "x\n): forward from the bracket the walk takes the second quote
        // to open a string, which the row's end closes.
        assert_eq!(skipping("\" ( \"x\n)", Bracket::Round, true, 2), Some(7));
        assert_eq!(skipping("\" ( \"x\n)", Bracket::Round, false, 7), None);
    }

    #[test]
    fn a_row_that_ends_in_a_backslash_carries_a_string_into_the_next() {
        // (a "b\\\nc) d" e): each row has one quote, and the first ends in a
        // backslash, so the string goes on across the line break.
        let text = "(a \"b\\\nc) d\" e)";
        assert_eq!(skipping(text, Bracket::Round, true, 0), Some(14));
        // From inside the string, its brackets are counted.
        assert_eq!(skipping(text, Bracket::Round, true, 3), Some(8));
        assert_eq!(skipping(text, Bracket::Round, false, 8), Some(0));
        assert_eq!(skipping(text, Bracket::Round, false, 9), None);
        assert_eq!(
            skipping("(a \"b\\\n c)\" d)", Bracket::Round, true, 0),
            Some(13)
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
            snapshot.unmatched(Bracket::Round, false, true, false, false, 0),
            Some(Some(text.len() - 1))
        );
        assert_eq!(
            snapshot.unmatched(Bracket::Round, true, false, false, false, text.len() - 1),
            Some(Some(0))
        );
        // The last escaped opening bracket, from inside its pair, and its
        // partner.
        let last = text.len() - 1 - "\\(x\\) ".len() + 1;
        assert_eq!(
            snapshot.unmatched(Bracket::Round, true, false, true, false, last + 1),
            Some(Some(last))
        );
        assert_eq!(
            snapshot.unmatched(Bracket::Round, false, true, true, false, last),
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
