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
//! # The library's limit
//!
//! The library (0.3.1) adds a score up in a `u16` and does not check the
//! sum. Past it a build with overflow checks panics and one without wraps
//! the score, so a better match scores below a worse one.
//!
//! - **What the sum can reach** depends on the pattern's length alone: at
//!   most 26 for each scalar value of the pattern and 10 more for the
//!   first, so `26 n + 10` for a pattern of `n`. Read from its source
//!   (`score.rs`, `fuzzy_optimal.rs`: 16 for a match, a bonus of at most
//!   10, twice that for the first, and penalties that stop at zero), and
//!   measured on 2026-11-14 in a build with overflow checks: nine
//!   patterns (words, spaces, delimiters, mixed case, digits, with and
//!   without a character that is not ASCII) against ten candidates each
//!   (the pattern itself, led, followed, doubled, one character in two,
//!   and with 200,000 characters before or after), at growing lengths
//!   until each panicked. No score was above `26 n + 10`; the highest was 65,530, at
//!   2,520; and the first panic was at 2,521, never sooner.
//! - **The candidate's length does not count.** Short patterns against
//!   candidates of five million characters scored as they do against
//!   short ones. A candidate too long for the library's matrix is scored
//!   by its greedy pass, which is the library's own fallback.
//! - **So a pattern longer than 2,000 scalar values is not handed to
//!   it**, which leaves a fifth of the room unused for what the
//!   measurement did not reach. What matches such a pattern is decided
//!   here, by the port's rule, and every match scores the same: the
//!   adapter cannot say which is better, so the order above it is the
//!   candidates' own, after a candidate that is the pattern. A pattern of
//!   2,000 or fewer is scored by the library whatever the candidates are.
//!
//! # Tests
//!
//! The two cases the adapter exists for, by name; that an adapter asked
//! again answers for the new pattern; the limit (a pattern of several
//! thousand characters is answered, the matches of one past the limit
//! score the same, and at the limit and in a long candidate the library
//! still scores a closer match higher); and the port's contract
//! (`tests/contract.rs`). No test pins a score's value.

use editor_fuzzy::Scorer;
use nucleo_matcher::pattern::{Atom, AtomKind, CaseMatching, Normalization};
use nucleo_matcher::{Config, Matcher, Utf32Str};

/// The longest pattern, in scalar values, that the library is asked to
/// score (the crate docs, "The library's limit").
const MAX_SCORED_PATTERN: usize = 2_000;

/// The score of every match of a pattern longer than
/// [`MAX_SCORED_PATTERN`]. One call scores with one pattern, so this is
/// never compared with a score of the library's.
const UNSCORED: u32 = 0;

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
    #[expect(
        clippy::disallowed_methods,
        reason = "`Default` is the constructor by its other name, in the adapter that owns it"
    )]
    fn default() -> Self {
        Self::new()
    }
}

impl Scorer for NucleoScorer {
    fn scores(&mut self, pattern: &str, candidates: &[&str]) -> Vec<Option<u32>> {
        // A pattern the library cannot score is not handed to it: what
        // matches is decided here, and every match scores the same.
        if pattern.chars().nth(MAX_SCORED_PATTERN).is_some() {
            return candidates
                .iter()
                .map(|candidate| in_order(pattern, candidate).then_some(UNSCORED))
                .collect();
        }
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

/// Whether the scalar values of `pattern` all occur in `candidate`, in
/// order, adjacent or apart, with case kept: the port's rule of what
/// matches, for a pattern the library is not asked.
fn in_order(pattern: &str, candidate: &str) -> bool {
    let mut rest = candidate.chars();
    pattern
        .chars()
        .all(|wanted| rest.any(|found| found == wanted))
}

#[cfg(test)]
mod tests {
    use super::{MAX_SCORED_PATTERN, NucleoScorer};
    use editor_fuzzy::Scorer;

    /// Which of `candidates` a new scorer matches `pattern` to.
    #[expect(
        clippy::disallowed_methods,
        reason = "the adapter's own tests: the library is what they hold to the port"
    )]
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
    #[expect(
        clippy::disallowed_methods,
        reason = "the adapter's own tests: the library is what they hold to the port"
    )]
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

    /// A text of `count` scalar values: `unit` again and again, cut to
    /// `count`.
    fn long(unit: &str, count: usize) -> String {
        unit.chars().cycle().take(count).collect()
    }

    /// `text` with an `x` after each of its scalar values.
    fn apart(text: &str) -> String {
        text.chars().flat_map(|c| [c, 'x']).collect()
    }

    /// The units the long patterns are made of, each one the library
    /// scores at its most for a character: a word, words after spaces, and
    /// a word that is not ASCII.
    const UNITS: [&str; 3] = ["a", "a ", "é"];

    #[test]
    fn a_pattern_of_several_thousand_characters_is_answered_and_matches_what_it_is_in_order_in() {
        for unit in UNITS {
            let pattern = long(unit, 4200);
            let followed = format!("{pattern}x");
            let led = format!("x{pattern}");
            let apart = apart(&pattern);
            let short = long(unit, 4199);
            let other = format!("{short}x");

            assert_eq!(
                matched(
                    &pattern,
                    &[&pattern, &followed, &led, &apart, &short, &other]
                ),
                [true, true, true, true, false, false],
                "of {unit:?}"
            );
        }
    }

    #[test]
    #[expect(
        clippy::disallowed_methods,
        reason = "the adapter's own tests: the library is what they hold to the port"
    )]
    fn the_matches_of_a_pattern_longer_than_the_library_is_asked_score_the_same() {
        let pattern = long("a", MAX_SCORED_PATTERN + 1);
        let followed = format!("{pattern}x");
        let apart = apart(&pattern);

        let scores = NucleoScorer::new().scores(&pattern, &[&apart, &pattern, "a", &followed]);

        assert_eq!(scores[2], None);
        assert!(scores[0].is_some());
        assert_eq!(scores[1], scores[0]);
        assert_eq!(scores[3], scores[0]);
    }

    #[test]
    #[expect(
        clippy::disallowed_methods,
        reason = "the adapter's own tests: the library is what they hold to the port"
    )]
    fn the_longest_pattern_the_library_is_asked_is_scored_by_it() {
        // Adjacent from the candidate's start scores above one character
        // in two, which is the library's doing: a wrapped score, or one
        // given here, would not say so.
        for unit in UNITS {
            let pattern = long(unit, MAX_SCORED_PATTERN);
            let followed = format!("{pattern}x");
            let apart = apart(&pattern);

            let scores = NucleoScorer::new().scores(&pattern, &[&apart, &followed]);

            assert!(scores[0].is_some(), "of {unit:?}");
            assert!(scores[1] > scores[0], "of {unit:?}");
        }
    }

    #[test]
    #[expect(
        clippy::disallowed_methods,
        reason = "the adapter's own tests: the library is what they hold to the port"
    )]
    fn a_short_pattern_is_scored_in_a_candidate_of_any_length() {
        let far = format!("a{}b", "x".repeat(200_000));
        let near = format!("ab{}", "x".repeat(200_000));
        let lacking = "ax".repeat(100_000);

        let scores = NucleoScorer::new().scores("ab", &[&far, &near, &lacking]);

        assert!(scores[0].is_some());
        assert!(scores[1] > scores[0]);
        assert_eq!(scores[2], None);
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
