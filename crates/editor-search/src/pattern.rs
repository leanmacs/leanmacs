//! The pattern syntax: a subset of Vim's `magic` syntax, parsed into a tree
//! of the crate's own.
//!
//! [`Pattern::parse`] reads what the user typed. Its answer is a
//! [`Pattern`]: the top-level alternatives, each a [`Branch`]. A branch
//! says whether a word starts at its start (`\<`) and ends at its end
//! (`\>`), which the core checks (the crate docs, "The rule of which
//! match"), and holds a [`Sequence`], which is what an engine compiles: an
//! optional `^` and `$`, and the items between, each an [`Atom`] with its
//! [`Repeat`]. A group (`\(…\)`) is an atom that holds sequences of its
//! own, one for each of its alternatives.
//!
//! # What is built
//!
//! | Typed | Means |
//! |---|---|
//! | Any other character, and `\` before one of `\ / . * [ ] ~ ^ $` | That character |
//! | `.` | Any character but a line feed |
//! | `[…]`, `[^…]` | A collection, with ranges `a-z`, `]` first literal, and `\\ \] \^ \- \t` inside. A negated one never matches a line feed. A `[` with no closing `]` is a literal `[` |
//! | `*` after an atom; `\+`; `\=` and `\?`; `\{n,m}` `\{n}` `\{n,}` `\{,m}` `\{}`; `\{-…}` | Greedy repetition; one or more; zero or one; counted; and the same lazily. `*` at the start of a sequence is a literal `*` |
//! | `^` at the start of a sequence, `$` at its end | The start and the end of a row. Elsewhere each is literal |
//! | `\(…\)`, `\|` | A group, and alternatives (leftmost-first) |
//! | `\s \S \d \D \w \W \t` | A space or a tab; not one; `[0-9]`; not; `[0-9A-Za-z_]`; not; a tab. A negated class never matches a line feed |
//! | `\<` at the start of a branch, `\>` at its end | A word starts there; a word ends there |
//!
//! A sequence is a top-level branch or one alternative of a group: `^`
//! after `\(` or `\|` is an anchor, as in Vim, and so is `$` before `\|`
//! or `\)`.
//!
//! # What is refused
//!
//! Each refusal carries the sentence Vim gives where it has one:
//! `E54: Unmatched \(`, `E55: Unmatched \)`, `E51: Too many \(` (Vim
//! allows nine groups), `E64: \+ follows nothing` (and the same for `\=`,
//! `\?`, `\{`, and `*` after `\<`), `E61: Nested *` and `E62: Nested \+`
//! (a multi after a multi), `E554: Syntax error in \{...}`,
//! `E944: Reverse range in character class`, and, for `~`,
//! `E33: No previous substitute regular expression`. The empty pattern is
//! refused. The rest are refused as `<atom> is not built in a pattern`: a
//! line feed, `\n` and `\_x` (a match across rows); `\%`, `\@`, `\z` and
//! the back-references `\1` to `\9`; `\c`, `\C`, `\v`, `\m`, `\M` and
//! `\V`; `[:alpha:]`-style classes; `\<` or `\>` away from a branch's
//! end; and every other escape.
//!
//! So no pattern that parses matches a line feed, which the rule of which
//! match rests on.

use crate::Refusal;

/// A parsed pattern: its top-level alternatives, in the order typed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pattern {
    /// The alternatives; never empty.
    branches: Vec<Branch>,
}

/// One top-level alternative of a pattern.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Branch {
    /// Whether a word starts where a match starts (`\<` first).
    word_start: bool,
    /// Whether a word ends where a match ends (`\>` last).
    word_end: bool,
    /// What an engine is asked to match.
    sequence: Sequence,
}

/// A run of items, with the row's anchors: what an engine compiles, and
/// each alternative of a group.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sequence {
    /// Whether a match starts at a row's start (`^` first).
    row_start: bool,
    /// Whether a match ends at a row's end (`$` last): before its line
    /// feed, or at the text's end.
    row_end: bool,
    /// The items, in order.
    items: Vec<Item>,
}

/// An atom and how often it repeats.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Item {
    /// What is matched.
    atom: Atom,
    /// How often.
    repeat: Repeat,
}

/// What one item matches once.
///
/// An engine matches on it exhaustively: it must compile every variant,
/// and a new variant is a new thing every engine is asked to do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Atom {
    /// This character. Never a line feed.
    Char(char),
    /// Any character but a line feed (`.`).
    Any,
    /// One of the backslash classes.
    Class(Class),
    /// A collection (`[…]`).
    Collection(Collection),
    /// A group (`\(…\)`): its alternatives, leftmost-first. Never empty.
    Group(Vec<Sequence>),
}

/// A backslash class. None matches a line feed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Class {
    /// `\s`: a space or a tab.
    Space,
    /// `\S`: any character but a space, a tab or a line feed.
    NotSpace,
    /// `\d`: `[0-9]`.
    Digit,
    /// `\D`: any character but `[0-9]` or a line feed.
    NotDigit,
    /// `\w`: `[0-9A-Za-z_]`.
    Word,
    /// `\W`: any character but `[0-9A-Za-z_]` or a line feed.
    NotWord,
}

/// A collection: the characters of its ranges, or every character but
/// those and a line feed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Collection {
    /// Whether it is negated (`[^…]`).
    negated: bool,
    /// Its ranges, each inclusive and in order (a single character is a
    /// range of one). None holds a line feed.
    ranges: Vec<(char, char)>,
}

/// How often an atom repeats: from `min` to `max` times (no `max` is no
/// bound), as many as can (`greedy`) or as few.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Repeat {
    /// The fewest.
    min: u32,
    /// The most, or none for no bound.
    max: Option<u32>,
    /// Whether as many as can are matched.
    greedy: bool,
}

impl Pattern {
    /// Parses `text` as the user typed it, or refuses it with the sentence
    /// the module docs give.
    pub fn parse(text: &str) -> Result<Pattern, Refusal> {
        if text.is_empty() {
            return Err(Refusal::new(EMPTY));
        }
        let mut parser = Parser {
            chars: text.chars().collect(),
            at: 0,
            groups: 0,
        };
        let mut branches = Vec::new();
        loop {
            let (sequence, word_start, word_end) = parser.sequence(true)?;
            branches.push(Branch {
                word_start,
                word_end,
                sequence,
            });
            if parser.eat_escaped('|') {
                continue;
            }
            if parser.at_escaped(')') {
                return Err(Refusal::new(UNMATCHED_CLOSE));
            }
            return Ok(Pattern { branches });
        }
    }

    /// The top-level alternatives, in the order typed; never empty.
    pub fn branches(&self) -> &[Branch] {
        &self.branches
    }
}

/// The empty pattern's refusal.
const EMPTY: &str = "the pattern is empty";
/// A `\(` with no `\)`.
const UNMATCHED_OPEN: &str = r"E54: Unmatched \(";
/// A `\)` with no `\(`.
const UNMATCHED_CLOSE: &str = r"E55: Unmatched \)";
/// A tenth group.
const TOO_MANY_GROUPS: &str = r"E51: Too many \(";
/// `~`, the last substitute's string, while no `:s` has run.
const NO_SUBSTITUTE: &str = "E33: No previous substitute regular expression";
/// A `\{` that is not closed by `}` or `\}`, or holds something but
/// digits, `-` first and one `,`.
const BRACES: &str = r"E554: Syntax error in \{...}";
/// A collection's range from a character to one before it.
const REVERSE_RANGE: &str = "E944: Reverse range in character class";
/// `\<` anywhere but the start of a top-level branch.
const WORD_START_AWAY: &str = r"\< away from the start of a branch is not built in a pattern";
/// `\>` anywhere but the end of a top-level branch.
const WORD_END_AWAY: &str = r"\> away from the end of a branch is not built in a pattern";

/// The refusal of `atom`, as typed, which the subset does not build.
fn not_built(atom: &str) -> Refusal {
    Refusal::new(format!("{atom} is not built in a pattern"))
}

/// The most groups a pattern may hold, as in Vim.
const MAX_GROUPS: u32 = 9;

/// A pattern's characters, read from left to right.
struct Parser {
    /// The pattern.
    chars: Vec<char>,
    /// The index of the next character to read.
    at: usize,
    /// How many groups have been opened.
    groups: u32,
}

/// One element of a collection, as read.
enum Element {
    /// A character, and the index after it.
    Char(char, usize),
    /// Something not built, and the index after it.
    Refused(Refusal, usize),
}

impl Parser {
    /// The character `ahead` places after the next one to read.
    fn peek(&self, ahead: usize) -> Option<char> {
        self.chars.get(self.at + ahead).copied()
    }

    /// Whether the next two characters are `\` and `c`.
    fn at_escaped(&self, c: char) -> bool {
        self.peek(0) == Some('\\') && self.peek(1) == Some(c)
    }

    /// Reads `\` and `c` when they come next.
    fn eat_escaped(&mut self, c: char) -> bool {
        let there = self.at_escaped(c);
        if there {
            self.at += 2;
        }
        there
    }

    /// Reads `c` when it comes next.
    fn eat(&mut self, c: char) -> bool {
        let there = self.peek(0) == Some(c);
        if there {
            self.at += 1;
        }
        there
    }

    /// Whether a sequence ends `ahead` places on: at the pattern's end, or
    /// before `\|` or `\)`.
    fn ends(&self, ahead: usize) -> bool {
        match self.peek(ahead) {
            None => true,
            Some('\\') => matches!(self.peek(ahead + 1), Some('|' | ')')),
            Some(_) => false,
        }
    }

    /// Reads a sequence up to its end, which it leaves unread: a top-level
    /// branch when `top`, and then whether it starts with `\<` and ends
    /// with `\>`, or an alternative of a group.
    fn sequence(&mut self, top: bool) -> Result<(Sequence, bool, bool), Refusal> {
        let row_start = self.eat('^');
        let word_start = top && self.eat_escaped('<');
        let mut sequence = Sequence {
            row_start,
            row_end: false,
            items: Vec::new(),
        };
        let mut word_end = false;
        // Whether the last thing read was a multi, which no multi follows.
        let mut after_multi = false;
        while !self.ends(0) {
            match (self.peek(0), self.peek(1)) {
                (Some('$'), _) if self.ends(1) => {
                    self.at += 1;
                    sequence.row_end = true;
                }
                (Some('\\'), Some('>')) => {
                    let last = self.ends(2) || (self.peek(2) == Some('$') && self.ends(3));
                    if !top || !last {
                        return Err(Refusal::new(WORD_END_AWAY));
                    }
                    self.at += 2;
                    word_end = true;
                }
                (Some('*'), _) if sequence.items.is_empty() && !word_start => {
                    // At a sequence's start, after `^` too, a star is itself.
                    self.at += 1;
                    sequence.items.push(Item {
                        atom: Atom::Char('*'),
                        repeat: Repeat::ONCE,
                    });
                    after_multi = false;
                }
                (Some('*'), _) => {
                    self.at += 1;
                    let repeat = Repeat {
                        min: 0,
                        max: None,
                        greedy: true,
                    };
                    let Some(last) = sequence.items.last_mut() else {
                        return Err(Refusal::new("E64: * follows nothing"));
                    };
                    if after_multi {
                        return Err(Refusal::new("E61: Nested *"));
                    }
                    last.repeat = repeat;
                    after_multi = true;
                }
                (Some('\\'), Some(multi @ ('+' | '=' | '?' | '{'))) => {
                    self.at += 2;
                    let Some(last) = sequence.items.last_mut() else {
                        return Err(Refusal::new(format!(r"E64: \{multi} follows nothing")));
                    };
                    if after_multi {
                        return Err(Refusal::new(format!(r"E62: Nested \{multi}")));
                    }
                    last.repeat = match multi {
                        '+' => Repeat {
                            min: 1,
                            max: None,
                            greedy: true,
                        },
                        '{' => self.braces()?,
                        _ => Repeat {
                            min: 0,
                            max: Some(1),
                            greedy: true,
                        },
                    };
                    after_multi = true;
                }
                _ => {
                    let atom = self.atom()?;
                    sequence.items.push(Item {
                        atom,
                        repeat: Repeat::ONCE,
                    });
                    after_multi = false;
                }
            }
        }
        Ok((sequence, word_start, word_end))
    }

    /// Reads one atom.
    fn atom(&mut self) -> Result<Atom, Refusal> {
        let Some(c) = self.peek(0) else {
            unreachable!("an atom is read only before a sequence's end");
        };
        self.at += 1;
        match c {
            '.' => Ok(Atom::Any),
            '~' => Err(Refusal::new(NO_SUBSTITUTE)),
            '\n' => Err(not_built(r"\n")),
            '[' => match self.collection(self.at - 1)? {
                Some((collection, after)) => {
                    self.at = after;
                    Ok(Atom::Collection(collection))
                }
                None => Ok(Atom::Char('[')),
            },
            '\\' => self.escaped(),
            c => Ok(Atom::Char(c)),
        }
    }

    /// Reads what follows a backslash, which has been read.
    fn escaped(&mut self) -> Result<Atom, Refusal> {
        let Some(c) = self.peek(0) else {
            // A trailing backslash is a backslash, as in Vim.
            return Ok(Atom::Char('\\'));
        };
        self.at += 1;
        match c {
            '\\' | '/' | '.' | '*' | '[' | ']' | '~' | '^' | '$' => Ok(Atom::Char(c)),
            't' => Ok(Atom::Char('\t')),
            's' => Ok(Atom::Class(Class::Space)),
            'S' => Ok(Atom::Class(Class::NotSpace)),
            'd' => Ok(Atom::Class(Class::Digit)),
            'D' => Ok(Atom::Class(Class::NotDigit)),
            'w' => Ok(Atom::Class(Class::Word)),
            'W' => Ok(Atom::Class(Class::NotWord)),
            '(' => self.group(),
            '<' => Err(Refusal::new(WORD_START_AWAY)),
            '_' | '%' | 'z' => {
                // The atom is named with the character that says which.
                let mut atom = format!("\\{c}");
                if let Some(which) = self.peek(0) {
                    atom.push(which);
                }
                Err(not_built(&atom))
            }
            '@' => {
                let mut atom = String::from(r"\@");
                let mut ahead = 0;
                while let Some(which) = self
                    .peek(ahead)
                    .filter(|which| "<=!>".contains(*which) || which.is_ascii_digit())
                {
                    atom.push(which);
                    ahead += 1;
                }
                Err(not_built(&atom))
            }
            c => Err(not_built(&format!("\\{c}"))),
        }
    }

    /// Reads a group, whose `\(` has been read, through its `\)`.
    fn group(&mut self) -> Result<Atom, Refusal> {
        self.groups += 1;
        if self.groups > MAX_GROUPS {
            return Err(Refusal::new(TOO_MANY_GROUPS));
        }
        let mut alternatives = Vec::new();
        loop {
            let (sequence, _, _) = self.sequence(false)?;
            alternatives.push(sequence);
            if self.eat_escaped('|') {
                continue;
            }
            if self.eat_escaped(')') {
                return Ok(Atom::Group(alternatives));
            }
            return Err(Refusal::new(UNMATCHED_OPEN));
        }
    }

    /// Reads the rest of a `\{…}`, whose `\{` has been read.
    fn braces(&mut self) -> Result<Repeat, Refusal> {
        let greedy = !self.eat('-');
        let first = self.digits();
        let (min, max) = if self.eat(',') {
            (first.unwrap_or(0), self.digits())
        } else {
            match first {
                Some(n) => (n, Some(n)),
                None => (0, None),
            }
        };
        // Either `}` or `\}` closes it, as in Vim.
        self.eat('\\');
        if !self.eat('}') {
            return Err(Refusal::new(BRACES));
        }
        // A reversed range is put in order, as in Vim.
        let (min, max) = match max {
            Some(max) if max < min => (max, Some(min)),
            max => (min, max),
        };
        Ok(Repeat { min, max, greedy })
    }

    /// Reads a run of decimal digits, if one comes next, as a number that
    /// stops at the largest.
    fn digits(&mut self) -> Option<u32> {
        let mut number: Option<u32> = None;
        while let Some(digit) = self.peek(0).and_then(|c| c.to_digit(10)) {
            self.at += 1;
            number = Some(number.unwrap_or(0).saturating_mul(10).saturating_add(digit));
        }
        number
    }

    /// The collection whose `[` is at `open`, and the index after its `]`;
    /// none when no `]` closes it, so its `[` is a character. Something
    /// not built inside a closed collection refuses the pattern.
    fn collection(&self, open: usize) -> Result<Option<(Collection, usize)>, Refusal> {
        let chars = &self.chars;
        let mut at = open + 1;
        let negated = chars.get(at) == Some(&'^');
        if negated {
            at += 1;
        }
        let mut ranges = Vec::new();
        // The first refusal inside, which counts only once a `]` closes it.
        let mut refusal: Option<Refusal> = None;
        let mut first = true;
        loop {
            match chars.get(at) {
                None => return Ok(None),
                Some(']') if !first => break,
                Some(_) => {}
            }
            first = false;
            match self.element(at) {
                Element::Refused(why, after) => {
                    refusal.get_or_insert(why);
                    at = after;
                }
                Element::Char(low, after) => {
                    // A range, when a `-` follows with something but the
                    // closing `]` after it.
                    let ranged = chars.get(after) == Some(&'-')
                        && chars.get(after + 1).is_some_and(|&c| c != ']');
                    if !ranged {
                        ranges.push((low, low));
                        at = after;
                        continue;
                    }
                    match self.element(after + 1) {
                        Element::Refused(why, after) => {
                            refusal.get_or_insert(why);
                            at = after;
                        }
                        Element::Char(high, after) => {
                            if high < low {
                                refusal.get_or_insert(Refusal::new(REVERSE_RANGE));
                            }
                            ranges.push((low, high));
                            at = after;
                        }
                    }
                }
            }
        }
        match refusal {
            Some(refusal) => Err(refusal),
            None => Ok(Some((Collection { negated, ranges }, at + 1))),
        }
    }

    /// The element of a collection at `at`.
    fn element(&self, at: usize) -> Element {
        let chars = &self.chars;
        let c = chars[at];
        match (c, chars.get(at + 1).copied()) {
            ('[', Some(kind @ (':' | '=' | '.'))) => {
                // `[:name:]`, `[=x=]` or `[.x.]`, when it is closed;
                // otherwise the `[` is a character.
                let closing = (at + 2..chars.len().saturating_sub(1))
                    .find(|&end| chars[end] == kind && chars[end + 1] == ']');
                match closing {
                    Some(end) => {
                        let class: String = chars[at..end + 2].iter().collect();
                        Element::Refused(not_built(&class), end + 2)
                    }
                    None => Element::Char('[', at + 1),
                }
            }
            ('\\', Some(escaped @ ('\\' | ']' | '^' | '-'))) => Element::Char(escaped, at + 2),
            ('\\', Some('t')) => Element::Char('\t', at + 2),
            ('\\', Some(special @ ('e' | 'r' | 'b' | 'n' | 'd' | 'o' | 'x' | 'u' | 'U'))) => {
                Element::Refused(not_built(&format!("\\{special}")), at + 2)
            }
            // A backslash before anything else is a backslash, as in Vim.
            ('\\', _) => Element::Char('\\', at + 1),
            ('\n', _) => Element::Refused(not_built(r"\n"), at + 1),
            (c, _) => Element::Char(c, at + 1),
        }
    }
}

impl Branch {
    /// Whether a word must start where a match starts (`\<`).
    pub fn word_start(&self) -> bool {
        self.word_start
    }

    /// Whether a word must end where a match ends (`\>`).
    pub fn word_end(&self) -> bool {
        self.word_end
    }

    /// What an engine is asked to match: the branch without `\<` and
    /// `\>`.
    pub fn sequence(&self) -> &Sequence {
        &self.sequence
    }
}

impl Sequence {
    /// Whether a match starts at a row's start (`^`).
    pub fn row_start(&self) -> bool {
        self.row_start
    }

    /// Whether a match ends at a row's end (`$`): before its line feed, or
    /// at the text's end.
    pub fn row_end(&self) -> bool {
        self.row_end
    }

    /// The items, in order.
    pub fn items(&self) -> &[Item] {
        &self.items
    }

    /// The characters of the sequence, when it is a run of literal
    /// characters, each once and no anchor; otherwise none.
    pub fn literal(&self) -> Option<String> {
        if self.row_start || self.row_end {
            return None;
        }
        self.items
            .iter()
            .map(|item| match item.atom {
                Atom::Char(c) if item.repeat == Repeat::ONCE => Some(c),
                _ => None,
            })
            .collect()
    }
}

impl Item {
    /// What is matched.
    pub fn atom(&self) -> &Atom {
        &self.atom
    }

    /// How often.
    pub fn repeat(&self) -> Repeat {
        self.repeat
    }
}

impl Collection {
    /// Whether it is negated (`[^…]`): it then matches every character but
    /// those of its ranges and a line feed.
    pub fn negated(&self) -> bool {
        self.negated
    }

    /// Its ranges, each inclusive, in the order typed. None holds a line
    /// feed.
    pub fn ranges(&self) -> &[(char, char)] {
        &self.ranges
    }
}

impl Repeat {
    /// Once: an atom with no multi after it.
    pub const ONCE: Repeat = Repeat {
        min: 1,
        max: Some(1),
        greedy: true,
    };

    /// The fewest times.
    pub fn min(&self) -> u32 {
        self.min
    }

    /// The most times, or none for no bound.
    pub fn max(&self) -> Option<u32> {
        self.max
    }

    /// Whether as many as can are matched (otherwise as few).
    pub fn greedy(&self) -> bool {
        self.greedy
    }
}

#[cfg(test)]
mod tests {
    use super::{Atom, Branch, Class, Collection, Item, Pattern, Repeat, Sequence};

    /// The reason `text` is refused, or a note that it parsed.
    fn refused(text: &str) -> String {
        match Pattern::parse(text) {
            Ok(pattern) => format!("parsed as {pattern:?}"),
            Err(refusal) => refusal.reason().to_owned(),
        }
    }

    /// The one branch `text` parses to.
    fn one(text: &str) -> Branch {
        let pattern = Pattern::parse(text).unwrap_or_else(|refusal| {
            panic!("{text:?} was refused: {}", refusal.reason());
        });
        assert_eq!(pattern.branches().len(), 1, "{text:?}");
        pattern.branches()[0].clone()
    }

    /// The items of the one branch `text` parses to, with no anchor and no
    /// word check.
    fn items(text: &str) -> Vec<Item> {
        let branch = one(text);
        assert!(!branch.word_start() && !branch.word_end(), "{text:?}");
        let sequence = branch.sequence();
        assert!(!sequence.row_start() && !sequence.row_end(), "{text:?}");
        sequence.items().to_vec()
    }

    fn once(atom: Atom) -> Item {
        Item {
            atom,
            repeat: Repeat::ONCE,
        }
    }

    fn repeated(atom: Atom, min: u32, max: Option<u32>, greedy: bool) -> Item {
        Item {
            atom,
            repeat: Repeat { min, max, greedy },
        }
    }

    fn chars(text: &str) -> Vec<Item> {
        text.chars().map(|c| once(Atom::Char(c))).collect()
    }

    fn collection(negated: bool, ranges: &[(char, char)]) -> Atom {
        Atom::Collection(Collection {
            negated,
            ranges: ranges.to_vec(),
        })
    }

    fn sequence(row_start: bool, row_end: bool, items: Vec<Item>) -> Sequence {
        Sequence {
            row_start,
            row_end,
            items,
        }
    }

    #[test]
    fn a_character_is_itself_and_so_is_an_escaped_special() {
        assert_eq!(items("foo(a|b)+?{}"), chars("foo(a|b)+?{}"));
        assert_eq!(items(r"\\\/\.\*\[\]\~\^\$"), chars(r"\/.*[]~^$"));
        assert_eq!(items("é漢🙂\r"), chars("é漢🙂\r"));
        assert_eq!(items("a b"), chars("a b"));
    }

    #[test]
    fn a_trailing_backslash_is_a_backslash() {
        assert_eq!(items(r"a\"), chars(r"a\"));
    }

    #[test]
    fn a_dot_is_any_character_and_a_tab_escape_is_a_tab() {
        assert_eq!(
            items(r"a.\t"),
            [
                once(Atom::Char('a')),
                once(Atom::Any),
                once(Atom::Char('\t'))
            ]
        );
    }

    #[test]
    fn the_backslash_classes() {
        assert_eq!(
            items(r"\s\S\d\D\w\W"),
            [
                Class::Space,
                Class::NotSpace,
                Class::Digit,
                Class::NotDigit,
                Class::Word,
                Class::NotWord
            ]
            .map(|class| once(Atom::Class(class)))
        );
    }

    #[test]
    fn a_collection_with_ranges_and_its_escapes() {
        assert_eq!(
            items("[a-cx]"),
            [once(collection(false, &[('a', 'c'), ('x', 'x')]))]
        );
        assert_eq!(
            items("[^ab]"),
            [once(collection(true, &[('a', 'a'), ('b', 'b')]))]
        );
        // `]` first is literal, also after `^`.
        assert_eq!(
            items("[]a]"),
            [once(collection(false, &[(']', ']'), ('a', 'a')]))]
        );
        assert_eq!(items("[^]]"), [once(collection(true, &[(']', ']')]))]);
        // The escapes inside a collection.
        assert_eq!(
            items(r"[\\\]\^\-\t]"),
            [once(collection(
                false,
                &[
                    ('\\', '\\'),
                    (']', ']'),
                    ('^', '^'),
                    ('-', '-'),
                    ('\t', '\t')
                ]
            ))]
        );
        // `-` first or last is literal, and so is `^` not first.
        assert_eq!(
            items("[-a^-]"),
            [once(collection(
                false,
                &[('-', '-'), ('a', 'a'), ('^', '^'), ('-', '-')]
            ))]
        );
        // A backslash before any other character is a backslash, as in Vim.
        assert_eq!(
            items(r"[\a]"),
            [once(collection(false, &[('\\', '\\'), ('a', 'a')]))]
        );
        // Specials are themselves inside.
        assert_eq!(
            items("[.*~$]"),
            [once(collection(
                false,
                &[('.', '.'), ('*', '*'), ('~', '~'), ('$', '$')]
            ))]
        );
        assert_eq!(items("[é-ü]"), [once(collection(false, &[('é', 'ü')]))]);
    }

    #[test]
    fn a_bracket_with_no_closing_bracket_is_a_bracket() {
        assert_eq!(items("[ab"), chars("[ab"));
        assert_eq!(items("a["), chars("a["));
        assert_eq!(items("[^"), chars("[^"));
        // An escaped `]` does not close it.
        assert_eq!(items(r"[a\]"), chars(r"[a]"));
    }

    #[test]
    fn the_multis() {
        let a = || Atom::Char('a');
        assert_eq!(items("a*"), [repeated(a(), 0, None, true)]);
        assert_eq!(items(r"a\+"), [repeated(a(), 1, None, true)]);
        assert_eq!(items(r"a\="), [repeated(a(), 0, Some(1), true)]);
        assert_eq!(items(r"a\?"), [repeated(a(), 0, Some(1), true)]);
        assert_eq!(items(r"a\{2,5}"), [repeated(a(), 2, Some(5), true)]);
        assert_eq!(items(r"a\{3}"), [repeated(a(), 3, Some(3), true)]);
        assert_eq!(items(r"a\{3,}"), [repeated(a(), 3, None, true)]);
        assert_eq!(items(r"a\{,4}"), [repeated(a(), 0, Some(4), true)]);
        assert_eq!(items(r"a\{}"), [repeated(a(), 0, None, true)]);
        assert_eq!(items(r"a\{,}"), [repeated(a(), 0, None, true)]);
        // Lazily.
        assert_eq!(items(r"a\{-}"), [repeated(a(), 0, None, false)]);
        assert_eq!(items(r"a\{-1,3}"), [repeated(a(), 1, Some(3), false)]);
        assert_eq!(items(r"a\{-2}"), [repeated(a(), 2, Some(2), false)]);
        // `\}` closes it too, and a reversed range is put in order, as in Vim.
        assert_eq!(items(r"a\{2,5\}"), [repeated(a(), 2, Some(5), true)]);
        assert_eq!(items(r"a\{5,2}"), [repeated(a(), 2, Some(5), true)]);
        // A multi takes the atom before it alone.
        assert_eq!(
            items("ab*"),
            [
                once(Atom::Char('a')),
                repeated(Atom::Char('b'), 0, None, true)
            ]
        );
        assert_eq!(items(".*"), [repeated(Atom::Any, 0, None, true)]);
    }

    #[test]
    fn a_star_at_the_start_of_a_sequence_is_a_star() {
        assert_eq!(items("*a"), chars("*a"));
        assert_eq!(one("^*").sequence(), &sequence(true, false, chars("*")));
        assert_eq!(
            items(r"\(*\)"),
            [once(Atom::Group(vec![sequence(false, false, chars("*"))]))]
        );
        let pattern = Pattern::parse(r"a\|*").unwrap();
        assert_eq!(
            pattern.branches()[1].sequence(),
            &sequence(false, false, chars("*"))
        );
    }

    #[test]
    fn a_group_and_its_alternatives() {
        assert_eq!(
            items(r"x\(ab\|c\)*"),
            [
                once(Atom::Char('x')),
                repeated(
                    Atom::Group(vec![
                        sequence(false, false, chars("ab")),
                        sequence(false, false, chars("c"))
                    ]),
                    0,
                    None,
                    true
                )
            ]
        );
        // An empty group, and an empty alternative.
        assert_eq!(
            items(r"\(\|a\)"),
            [once(Atom::Group(vec![
                sequence(false, false, vec![]),
                sequence(false, false, chars("a"))
            ]))]
        );
    }

    #[test]
    fn top_level_alternatives_are_branches_in_order() {
        let pattern = Pattern::parse(r"foo\|bar\|").unwrap();
        let sequences: Vec<&Sequence> = pattern.branches().iter().map(Branch::sequence).collect();
        assert_eq!(
            sequences,
            [
                &sequence(false, false, chars("foo")),
                &sequence(false, false, chars("bar")),
                &sequence(false, false, vec![])
            ]
        );
    }

    #[test]
    fn a_caret_first_and_a_dollar_last_are_the_rows_anchors() {
        assert_eq!(one("^foo$").sequence(), &sequence(true, true, chars("foo")));
        assert_eq!(one("^").sequence(), &sequence(true, false, vec![]));
        assert_eq!(one("$").sequence(), &sequence(false, true, vec![]));
        // Elsewhere each is itself.
        assert_eq!(items("a^b$c"), chars("a^b$c"));
        assert_eq!(one("^^$$").sequence(), &sequence(true, true, chars("^$")));
        // At each branch's ends, and at a group alternative's.
        let pattern = Pattern::parse(r"^a$\|^b$").unwrap();
        for branch in pattern.branches() {
            assert!(branch.sequence().row_start() && branch.sequence().row_end());
        }
        assert_eq!(
            items(r"\(^a\|b$\)"),
            [once(Atom::Group(vec![
                sequence(true, false, chars("a")),
                sequence(false, true, chars("b"))
            ]))]
        );
    }

    #[test]
    fn word_boundaries_at_a_branchs_ends() {
        let branch = one(r"\<foo\>");
        assert!(branch.word_start() && branch.word_end());
        assert_eq!(branch.sequence(), &sequence(false, false, chars("foo")));
        let branch = one(r"\<foo");
        assert!(branch.word_start() && !branch.word_end());
        let branch = one(r"foo\>");
        assert!(!branch.word_start() && branch.word_end());
        // With the row's anchors outside them.
        let branch = one(r"^\<foo\>$");
        assert!(branch.word_start() && branch.word_end());
        assert_eq!(branch.sequence(), &sequence(true, true, chars("foo")));
        // On each branch.
        let pattern = Pattern::parse(r"\<foo\>\|\<bar\>").unwrap();
        assert_eq!(pattern.branches().len(), 2);
        for branch in pattern.branches() {
            assert!(branch.word_start() && branch.word_end());
        }
    }

    #[test]
    fn a_literal_sequence_answers_its_characters() {
        assert_eq!(one(r"a\.b").sequence().literal().as_deref(), Some("a.b"));
        assert_eq!(one(r"\<foo\>").sequence().literal().as_deref(), Some("foo"));
        assert_eq!(one("a.b").sequence().literal(), None);
        assert_eq!(one("^ab").sequence().literal(), None);
        assert_eq!(one("ab$").sequence().literal(), None);
        assert_eq!(one("ab*").sequence().literal(), None);
        assert_eq!(one("[a]").sequence().literal(), None);
    }

    #[test]
    fn the_sentences_vim_gives() {
        assert_eq!(refused(r"\(a"), r"E54: Unmatched \(");
        assert_eq!(refused(r"\(a\|b"), r"E54: Unmatched \(");
        assert_eq!(refused(r"a\)"), r"E55: Unmatched \)");
        assert_eq!(refused(r"a\|b\)"), r"E55: Unmatched \)");
        assert_eq!(refused(r"\+"), r"E64: \+ follows nothing");
        assert_eq!(refused(r"\="), r"E64: \= follows nothing");
        assert_eq!(refused(r"\?"), r"E64: \? follows nothing");
        assert_eq!(refused(r"\{2}"), r"E64: \{ follows nothing");
        assert_eq!(refused(r"a\|\+"), r"E64: \+ follows nothing");
        assert_eq!(refused(r"\(\+\)"), r"E64: \+ follows nothing");
        assert_eq!(refused(r"^\+"), r"E64: \+ follows nothing");
        assert_eq!(refused(r"\<*"), r"E64: * follows nothing");
        assert_eq!(
            refused("~"),
            "E33: No previous substitute regular expression"
        );
        assert_eq!(
            refused("a~"),
            "E33: No previous substitute regular expression"
        );
        assert_eq!(refused("a**"), "E61: Nested *");
        assert_eq!(refused(r"a*\+"), r"E62: Nested \+");
        assert_eq!(refused(r"a\{2}\="), r"E62: Nested \=");
        assert_eq!(refused(r"a\+\{2}"), r"E62: Nested \{");
        assert_eq!(refused(r"a\{2"), r"E554: Syntax error in \{...}");
        assert_eq!(refused(r"a\{x}"), r"E554: Syntax error in \{...}");
        assert_eq!(refused(r"a\{1,2,3}"), r"E554: Syntax error in \{...}");
        assert_eq!(refused("[z-a]"), "E944: Reverse range in character class");
        assert_eq!(
            refused(r"\(\(\(\(\(\(\(\(\(\(a\)\)\)\)\)\)\)\)\)\)"),
            r"E51: Too many \("
        );
        assert_eq!(
            refused(r"\(a\)\(a\)\(a\)\(a\)\(a\)\(a\)\(a\)\(a\)\(a\)\(a\)"),
            r"E51: Too many \("
        );
        // Nine groups are allowed.
        assert!(Pattern::parse(r"\(a\)\(a\)\(a\)\(a\)\(a\)\(a\)\(a\)\(a\)\(a\)").is_ok());
    }

    #[test]
    fn the_empty_pattern_is_refused() {
        assert_eq!(refused(""), "the pattern is empty");
    }

    #[test]
    fn what_is_not_built_is_refused_by_name() {
        for (text, atom) in [
            ("a\nb", r"\n"),
            (r"a\nb", r"\n"),
            (r"\_s", r"\_s"),
            (r"\_.", r"\_."),
            (r"\_", r"\_"),
            (r"\%(a\)", r"\%("),
            (r"\%V", r"\%V"),
            (r"\%^", r"\%^"),
            (r"a\@=", r"\@="),
            (r"a\@<!", r"\@<!"),
            (r"\zs", r"\zs"),
            (r"\z(", r"\z("),
            (r"\(a\)\1", r"\1"),
            (r"\9", r"\9"),
            (r"\c", r"\c"),
            (r"\C", r"\C"),
            (r"\v", r"\v"),
            (r"\m", r"\m"),
            (r"\M", r"\M"),
            (r"\V", r"\V"),
            ("[[:alpha:]]", "[:alpha:]"),
            ("[[=a=]]", "[=a=]"),
            ("[[.a.]]", "[.a.]"),
            (r"\i", r"\i"),
            (r"\k", r"\k"),
            (r"\a", r"\a"),
            (r"\x", r"\x"),
            (r"\u", r"\u"),
            (r"\e", r"\e"),
            (r"\r", r"\r"),
            (r"\&", r"\&"),
            (r"\-", r"\-"),
            (r"[\n]", r"\n"),
            (r"[\e]", r"\e"),
            (r"[\d65]", r"\d"),
            ("[\n]", r"\n"),
        ] {
            assert_eq!(
                refused(text),
                format!("{atom} is not built in a pattern"),
                "{text:?}"
            );
        }
    }

    #[test]
    fn a_word_boundary_away_from_a_branchs_end_is_refused() {
        let start = r"\< away from the start of a branch is not built in a pattern";
        let end = r"\> away from the end of a branch is not built in a pattern";
        assert_eq!(refused(r"a\<b"), start);
        assert_eq!(refused(r"\(\<a\)"), start);
        assert_eq!(refused(r"\<\<a"), start);
        assert_eq!(refused(r"a\>b"), end);
        assert_eq!(refused(r"\(a\>\)"), end);
        assert_eq!(refused(r"a\>\>"), end);
        // `^` after `\<` is a character, and `$` before `\>`.
        let branch = one(r"\<^a$\>");
        assert!(branch.word_start() && branch.word_end());
        assert_eq!(branch.sequence(), &sequence(false, false, chars("^a$")));
    }

    #[test]
    fn an_unclosed_collection_with_something_unbuilt_in_it_is_a_bracket() {
        // The class inside is not refused: with no `]` to close the outer
        // collection, its `[` is a character, and what follows is read
        // again, as a collection of the characters `:alph`.
        assert_eq!(
            items("[[:alpha:]"),
            [
                once(Atom::Char('[')),
                once(collection(
                    false,
                    &[
                        (':', ':'),
                        ('a', 'a'),
                        ('l', 'l'),
                        ('p', 'p'),
                        ('h', 'h'),
                        ('a', 'a'),
                        (':', ':')
                    ]
                ))
            ]
        );
    }
}
