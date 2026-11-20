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
//! - **The scalar search for an empty text.** The SIMD search of 0.4.0,
//!   which x86 takes, reports no span of an empty text: its loop over
//!   anti-diagonals never reports the one that ends at offset 0, the
//!   empty text's only span. The contract's sweep caught it (pattern `A`,
//!   an empty text, one error allowed). The scalar search, which other
//!   machines take, has no such gap, so the empty text is asked of it and
//!   every other text of the SIMD search.
//!
//! The library counts bytes, so a span it reports can cut a character of
//! a text that is not ASCII. The port allows that, and the rule above it
//! drops such a span.
//!
//! # Tests
//!
//! The port's contract, and three cases of its own: a pattern with one
//! substitution is found with one error, a pattern with no span near
//! enough reports none, and an empty text reports the empty span exactly
//! when the whole pattern is within the errors allowed
//! (`tests/contract.rs`).

use editor_fuzzy::locate::{Searcher, Span};
use triple_accel::SearchType;
use triple_accel::levenshtein::{
    LEVENSHTEIN_COSTS, levenshtein_search_naive_with_opts, levenshtein_search_simd_with_opts,
};

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
        let search = if text.is_empty() {
            levenshtein_search_naive_with_opts
        } else {
            levenshtein_search_simd_with_opts
        };
        search(
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
