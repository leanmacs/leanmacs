//! Search within a text: which match of a pattern a search answers, and
//! the matches in a stretch of it.
//!
//! [`search`] and [`matches()`] are what the editor asks: a pattern as the
//! user typed it, a text as the pieces it is held in, and the text's word
//! class, in; a match, or the matches in a range, out. A pattern is parsed
//! here, by our own parser of a subset of Vim's syntax ([`pattern`]).
//! What a branch of it matches at a place is an [`Engine`]'s to say, the
//! port a regex library fills; which match a search answers is decided
//! here, once. The crate has no dependencies and knows nothing about Lean
//! or about the rope.
//!
//! # The rule of which match
//!
//! It is Vim 9.1's under its default options: `cpoptions` holds `c`,
//! `wrapscan` is on, `magic` is on, and case is kept.
//!
//! - **The matches of a pattern in a text are found row by row.** In a
//!   row, the first match is the leftmost-first match from the row's
//!   start; each next one is the leftmost-first match from where the one
//!   before it stopped, or one character further when that one was empty;
//!   and a row's matches end when no further match starts in it. No match
//!   holds a line feed (no pattern that parses matches one), so this is
//!   one leftmost-first walk of the whole text, and it may be begun at any
//!   row's start.
//! - **`\<` and `\>` are checked here**, with the word class the caller
//!   hands in, and an engine is asked for the branch without them. A
//!   candidate whose start is not a word start, or whose end is not a word
//!   end, is passed over, and the walk tries again one character after the
//!   candidate's start. A word starts at a place when the character there
//!   is a word character and the one before is not, or there is none; a
//!   word ends there when the character before is one and the one there is
//!   not, or there is none.
//! - **Top-level alternatives are asked one by one**: the leftmost match
//!   wins, and of two that start together the earlier alternative's.
//! - **Forward from `p`**: the first match that starts after `p`, walking
//!   from `p`'s row start, so a match that starts at or before `p` is
//!   passed over and the walk goes on from its end (`cpo-c`: `abab` in
//!   `abababab` from 0 answers 4). When none starts after `p`, the text's
//!   first match, marked wrapped.
//! - **Backward from `p`**: the last match that starts before `p`, walking
//!   each row from its start, from `p`'s row upward. When there is none,
//!   the text's last match, marked wrapped.
//! - **Matches in a range**: the text's matches that start at or after its
//!   start and before its stop, in order, walked from its start's row
//!   start (`aa` in `aaaa` from 1 answers only `2..4`).
//!
//! **A recorded limit**: `\>` is checked against the match the engine
//! answers, so a branch whose end could match fewer characters (`\<x.*\>`
//! on `xy z!`) can miss a match Vim finds by backtracking. For a literal
//! branch it is exact.
//!
//! **What each engine call is asked.** Every call names a span `from..=to`
//! that a match must start in, and an engine may stop looking at the end
//! of the row that holds `to`. A backward search and the walk of a row ask
//! spans within one row, so a backward search over a large text asks each
//! row once and costs no more than a scan of the rows it walks.
//!
//! # Where an addition goes
//!
//! | Addition | Where | Pinned by |
//! |---|---|---|
//! | A piece of syntax | [`pattern`]: the parser and the tree, an [`pattern::Atom`] variant for a new kind of atom | The parser's tests, on the module docs' table; the adapter's own tests for what it matches |
//! | A rule of which match a search answers | [`search`], [`matches()`] | The tests here, on [`Literal`] and on engines written in them |
//! | A rule every engine keeps about what a literal matches | A property of [`contract`] | Its own tests, on the fake and on engines written to break it |
//!
//! # The fake and the contract
//!
//! [`Literal`] is the port's fake, and everything above the port is tested
//! on it: it compiles a branch that is a run of literal characters and
//! refuses any other. [`contract::check`] is what a real adapter is held
//! to: it passes on the fake in this crate's tests, and each real adapter
//! runs it in its own. Its cases are literal, since the fake answers no
//! other; what only a regex shows is pinned by the adapter's own tests.

pub mod contract;
pub mod pattern;
mod pieces;
mod rule;

use std::ops::Range;

pub use pattern::{Pattern, Sequence};
pub use pieces::Pieces;
pub use rule::{Searched, matches, search};

/// The port: what compiles a sequence of a pattern into something that
/// finds it in a text.
pub trait Engine {
    /// A compiled sequence.
    type Compiled: Compiled;

    /// Compiles `sequence`, a top-level branch without its `\<` and `\>`,
    /// or refuses it with a sentence for the user.
    fn compile(&mut self, sequence: &Sequence) -> Result<Self::Compiled, Refusal>;
}

/// A compiled sequence: what finds it in a text.
pub trait Compiled {
    /// The leftmost-first match that starts in `from..=to`, or none.
    ///
    /// `from` and `to` are positions of `haystack` (byte offsets at
    /// character boundaries), and `from <= to`. The match may end after
    /// `to`. `^` and `$` see the text outside the span: `^` at `from` holds
    /// only at a row's start. No match holds a line feed, so an engine may
    /// stop looking at the end of the row that holds `to`.
    fn find(&mut self, haystack: &Pieces<'_>, from: usize, to: usize) -> Option<Range<usize>>;
}

/// The fake engine: it compiles a sequence that is a run of literal
/// characters, each once and with no anchor, and refuses any other with
/// [`Literal::REFUSAL`]. What it compiles finds the run where it occurs,
/// across the pieces' boundaries.
///
/// It is public, not `cfg(test)`, so the tests of any crate above the port
/// run on it.
#[derive(Debug, Default, Clone, Copy)]
pub struct Literal;

impl Literal {
    /// Why it refuses a sequence that is not a literal run.
    pub const REFUSAL: &str = "the literal engine compiles a run of literal characters only";
}

/// A run of literal characters, compiled by [`Literal`].
#[derive(Debug, Clone)]
pub struct LiteralRun {
    /// The characters.
    text: String,
}

impl Engine for Literal {
    type Compiled = LiteralRun;

    fn compile(&mut self, sequence: &Sequence) -> Result<LiteralRun, Refusal> {
        match sequence.literal() {
            Some(text) => Ok(LiteralRun { text }),
            None => Err(Refusal::new(Self::REFUSAL)),
        }
    }
}

impl Compiled for LiteralRun {
    fn find(&mut self, haystack: &Pieces<'_>, from: usize, to: usize) -> Option<Range<usize>> {
        if from > to || to > haystack.len() {
            return None;
        }
        if self.text.is_empty() {
            return Some(from..from);
        }
        // The characters from `from` to the end of the row that holds
        // `to`: a run holds no line feed, so no occurrence that starts by
        // `to` goes further.
        let end = haystack.row_end(to);
        let window: Vec<(usize, char)> = haystack
            .chars_from(from)
            .take_while(|&(at, _)| at < end)
            .collect();
        let wanted: Vec<char> = self.text.chars().collect();
        (0..window.len())
            .take_while(|&index| window[index].0 <= to)
            .find(|&index| {
                window[index..]
                    .iter()
                    .map(|&(_, c)| c)
                    .take(wanted.len())
                    .eq(wanted.iter().copied())
            })
            .map(|index| window[index].0..window[index].0 + self.text.len())
    }
}

/// Why a pattern, or an engine asked to compile it, gave no search: a
/// sentence for the user, as the echo area says it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    /// The sentence.
    reason: String,
}

impl Refusal {
    /// A refusal that says `reason`.
    pub fn new(reason: impl Into<String>) -> Self {
        Self {
            reason: reason.into(),
        }
    }

    /// The sentence.
    pub fn reason(&self) -> &str {
        &self.reason
    }
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.reason)
    }
}

impl std::error::Error for Refusal {}
