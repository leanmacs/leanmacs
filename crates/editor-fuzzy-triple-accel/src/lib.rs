//! The searcher port's real adapter: [`TripleAccel`], a [`Searcher`] over
//! triple_accel.
//!
//! The port, its fake, its contract and the rule that picks the span a
//! pattern is located at are `editor-fuzzy`'s (`editor_fuzzy::locate`).
//! This crate is thin: it asks the library for the spans of the text within
//! the errors allowed and reports each as the port's [`Span`]. It chooses
//! nothing. No triple_accel type is public, and no other crate depends on
//! the library (`deny.toml`).
//!
//! What it asks of the library, each so that what it reports is the
//! port's (spans within `max_errors` byte edits, at least one with the
//! fewest errors any span has, and none when no span is within them):
//!
//! - **Levenshtein costs.** One for an insertion, a deletion or a
//!   substitution, and no transposition: the port's distance.
//! - **The best spans.** `SearchType::Best` reports the spans with the
//!   fewest errors found; of those that end at one place or overlap
//!   wholly, the longest. That is at least one span with the fewest
//!   errors, which is all the port asks.
//! - **Not anchored.** A span may start anywhere in the text.
//!
//! The library counts bytes, so a span it reports can cut a character of
//! a text that is not ASCII. The port allows that, and the rule above it
//! drops such a span.
//!
//! # Tests
//!
//! The port's contract, and two cases of its own: a pattern with one
//! substitution is found with one error, and a pattern with no span near
//! enough reports none (`tests/contract.rs`).

use editor_fuzzy::locate::{Searcher, Span};
use triple_accel::SearchType;
use triple_accel::levenshtein::{LEVENSHTEIN_COSTS, levenshtein_search_simd_with_opts};

/// The searcher over triple_accel. It keeps nothing between questions.
#[derive(Debug)]
pub struct TripleAccel {
    /// Nothing: the field keeps the constructor the one way to make one,
    /// which `editor-fuzzy`'s `clippy.toml` refuses its tests.
    _private: (),
}

impl TripleAccel {
    /// A searcher.
    pub fn new() -> Self {
        Self { _private: () }
    }
}

impl Default for TripleAccel {
    fn default() -> Self {
        Self::new()
    }
}

impl Searcher for TripleAccel {
    fn spans(&mut self, pattern: &str, text: &str, max_errors: u32) -> Vec<Span> {
        levenshtein_search_simd_with_opts(
            pattern.as_bytes(),
            text.as_bytes(),
            max_errors,
            SearchType::Best,
            LEVENSHTEIN_COSTS,
            false,
        )
        .map(|found| Span {
            start: found.start,
            end: found.end,
            errors: found.k,
        })
        .collect()
    }
}
