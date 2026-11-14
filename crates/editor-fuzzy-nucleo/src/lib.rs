//! The scorer port's real adapter: [`NucleoScorer`], a [`Scorer`] over
//! nucleo-matcher.
//!
//! The port, its fake, its contract and the rule that orders matches are
//! `editor-fuzzy`'s. This crate is thin: it keeps one matcher of the
//! library's for as long as it lives, makes one pattern of the text it is
//! asked with, and scores each candidate with it. No nucleo type is
//! public, and no other crate depends on the library (`deny.toml`).
//!
//! What it decides, each so that what matches is the port's rule (the
//! pattern's Unicode scalar values, in order, adjacent or apart) and
//! nothing the library adds to it:
//!
//! - **A pattern is one fuzzy atom.** The library's own pattern syntax
//!   (`^`, `$`, `!`, `'`, words split at spaces, a backslash before a
//!   space) is not read: every character of the pattern is a character to
//!   find, a space included.
//! - **Case is kept and nothing is normalised.** The library can ignore
//!   case and can take an accented letter for its base letter; it is asked
//!   for neither.
//! - **A text is its scalar values.** The library's feature that cuts a
//!   text into grapheme clusters is off (the manifest says why).
//!
//! The scores are the library's own, widened to the port's `u32` and not
//! looked at here. Nothing in this crate or above it may rest on a score's
//! value: the library says they change between releases.
//!
//! # Tests
//!
//! The two cases the adapter exists for, by name; that an adapter asked
//! again answers for the new pattern; and the port's contract
//! (`tests/contract.rs`). No test pins a score.

use editor_fuzzy::Scorer;
use nucleo_matcher::pattern::{Atom, AtomKind, CaseMatching, Normalization};
use nucleo_matcher::{Config, Matcher, Utf32Str};

/// The scorer over nucleo-matcher.
pub struct NucleoScorer {
    /// The library's matcher: its scratch memory, about 135 KB, which the
    /// library says to make once and reuse.
    matcher: Matcher,
    /// Where a candidate that is not ASCII is spelt as scalar values for
    /// the matcher, reused from one candidate to the next.
    scalars: Vec<char>,
}

impl NucleoScorer {
    /// A scorer with a matcher of its own.
    pub fn new() -> Self {
        Self {
            matcher: Matcher::new(Config::DEFAULT),
            scalars: Vec::new(),
        }
    }
}

impl Default for NucleoScorer {
    fn default() -> Self {
        Self::new()
    }
}

impl Scorer for NucleoScorer {
    fn scores(&mut self, pattern: &str, candidates: &[&str]) -> Vec<Option<u32>> {
        // One fuzzy atom of the whole pattern, with case kept, nothing
        // normalised, and no backslash read as an escape.
        let atom = Atom::new(
            pattern,
            CaseMatching::Respect,
            Normalization::Never,
            AtomKind::Fuzzy,
            false,
        );
        candidates
            .iter()
            .map(|candidate| {
                atom.score(
                    Utf32Str::new(candidate, &mut self.scalars),
                    &mut self.matcher,
                )
                .map(u32::from)
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::NucleoScorer;
    use editor_fuzzy::Scorer;

    /// Which of `candidates` a new scorer matches `pattern` to.
    fn matched(pattern: &str, candidates: &[&str]) -> Vec<bool> {
        NucleoScorer::new()
            .scores(pattern, candidates)
            .iter()
            .map(Option::is_some)
            .collect()
    }

    #[test]
    fn a_pattern_whose_characters_are_in_a_candidate_in_order_but_apart_matches_it() {
        assert_eq!(matched("ace", &["abcde"]), [true]);
    }

    #[test]
    fn a_pattern_with_a_character_the_candidate_lacks_does_not_match_it() {
        assert_eq!(matched("axe", &["abcde"]), [false]);
    }

    #[test]
    fn a_scorer_asked_again_answers_for_the_new_pattern() {
        let mut scorer = NucleoScorer::new();
        let candidates = ["abcde", "xyz", "a-x-e"];
        let matched = |scorer: &mut NucleoScorer, pattern: &str| -> Vec<bool> {
            scorer
                .scores(pattern, &candidates)
                .iter()
                .map(Option::is_some)
                .collect()
        };

        assert_eq!(matched(&mut scorer, "ace"), [true, false, false]);
        assert_eq!(matched(&mut scorer, "axe"), [false, false, true]);
        assert_eq!(matched(&mut scorer, "xyz"), [false, true, false]);
        // And for the first one again, as it did before.
        assert_eq!(matched(&mut scorer, "ace"), [true, false, false]);
    }

    #[test]
    fn an_entry_is_answered_for_each_candidate_in_their_order() {
        assert_eq!(matched("a", &[]), [false; 0]);
        assert_eq!(
            matched("b", &["abc", "", "b", "xyz"]),
            [true, false, true, false]
        );
    }
}
