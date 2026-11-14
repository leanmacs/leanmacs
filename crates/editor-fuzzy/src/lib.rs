//! Fuzzy matching: which candidates a pattern matches, and in what order.
//!
//! [`rank`] is what the editor asks: a pattern and candidates in, the
//! indices of the candidates the pattern matches out, best first. What
//! matches and how well is a [`Scorer`]'s to say, the port a matching
//! library fills; the order is decided here, once, from its scores. The
//! crate has no dependencies and knows nothing about Lean.
//!
//! # The order
//!
//! 1. A candidate that is the pattern, byte for byte, comes first, whatever
//!    its score.
//! 2. Then the higher score.
//! 3. Then the order the candidates came in: among candidates that are the
//!    pattern, and among candidates of one score.
//!
//! A candidate the scorer did not match is never answered, a candidate that
//! is the pattern included.
//!
//! The first rule is here and not a scorer's because a library's scores do
//! not give it: one scores `w` the same in `w` and in `wq`. Written here it
//! is written once, and tested on a scorer that answers canned scores.
//!
//! # Where an addition goes
//!
//! | Addition | Where | Pinned by |
//! |---|---|---|
//! | A rule of the order | [`rank`] | The tests here, on a scorer that answers canned scores |
//! | Something more a scorer is asked (a case rule, a limit) | An argument of [`Scorer::scores`], as data | The tests here |

/// The port: what scores candidates against a pattern.
pub trait Scorer {
    /// One entry for each of `candidates`, in their order: a score, higher
    /// for a better match, where `pattern` matches the candidate, and
    /// `None` where it does not.
    ///
    /// The whole list is asked at once, so an implementation reads the
    /// pattern once and reuses what it holds from one candidate to the
    /// next.
    fn scores(&mut self, pattern: &str, candidates: &[&str]) -> Vec<Option<u32>>;
}

/// The indices of the `candidates` that `pattern` matches, best first: the
/// order of the crate's documentation, over what `scorer` answers.
///
/// The scorer is asked once. Where it answers fewer entries than there are
/// candidates the rest are not matched, and entries past the last
/// candidate are ignored.
pub fn rank(scorer: &mut impl Scorer, pattern: &str, candidates: &[&str]) -> Vec<usize> {
    let scores = scorer.scores(pattern, candidates);
    // Each matched candidate: what it is ordered by, and its index. `zip`
    // stops at the shorter of the two, which is both rules about a scorer
    // that answers the wrong number of entries.
    let mut matched: Vec<(Standing, usize)> = candidates
        .iter()
        .zip(scores)
        .enumerate()
        .filter_map(|(index, (&candidate, score))| {
            let score = score?;
            let standing = if candidate == pattern {
                Standing::Exact
            } else {
                Standing::Scored(score)
            };
            Some((standing, index))
        })
        .collect();
    // The sort is stable, so what compares equal keeps the candidates'
    // order; and best is greatest, so the comparison is turned round.
    matched.sort_by(|(a, _), (b, _)| b.cmp(a));
    matched.into_iter().map(|(_, index)| index).collect()
}

/// What a matched candidate is ordered by. A later variant is a better
/// match, and of two `Scored` the higher score: the derived order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Standing {
    /// The pattern matches it, with this score.
    Scored(u32),
    /// It is the pattern. Its score is not looked at: two candidates that
    /// are the pattern are one string, and keep their order.
    Exact,
}

#[cfg(test)]
mod tests {
    use super::{Scorer, rank};

    /// A scorer that answers the scores it was made with, whatever it is
    /// asked, and records what it was asked.
    struct Canned {
        /// What it answers.
        scores: Vec<Option<u32>>,
        /// Each question: the pattern and the candidates.
        asked: Vec<(String, Vec<String>)>,
    }

    impl Canned {
        /// A scorer that answers `scores`.
        fn new(scores: &[Option<u32>]) -> Self {
            Self {
                scores: scores.to_vec(),
                asked: Vec::new(),
            }
        }
    }

    impl Scorer for Canned {
        fn scores(&mut self, pattern: &str, candidates: &[&str]) -> Vec<Option<u32>> {
            self.asked.push((
                pattern.to_owned(),
                candidates
                    .iter()
                    .map(|&candidate| candidate.to_owned())
                    .collect(),
            ));
            self.scores.clone()
        }
    }

    #[test]
    fn only_the_candidates_the_scorer_matched_are_answered() {
        let mut scorer = Canned::new(&[None, Some(1), None, Some(1)]);

        assert_eq!(rank(&mut scorer, "p", &["a", "b", "c", "d"]), [1, 3]);
    }

    #[test]
    fn no_candidates_answer_none() {
        assert_eq!(rank(&mut Canned::new(&[]), "p", &[]), [0; 0]);
    }

    #[test]
    fn a_higher_score_comes_first() {
        let mut scorer = Canned::new(&[Some(1), Some(30), Some(7)]);

        assert_eq!(rank(&mut scorer, "p", &["a", "b", "c"]), [1, 2, 0]);
    }

    #[test]
    fn equal_scores_keep_the_order_the_candidates_came_in() {
        let mut scorer = Canned::new(&[Some(5), Some(9), Some(5), Some(9), Some(5)]);

        assert_eq!(
            rank(&mut scorer, "p", &["a", "b", "c", "d", "e"]),
            [1, 3, 0, 2, 4]
        );
    }

    #[test]
    fn a_candidate_that_is_the_pattern_comes_first_though_its_score_is_lower() {
        let mut scorer = Canned::new(&[Some(90), Some(2), Some(40)]);

        assert_eq!(rank(&mut scorer, "w", &["wq", "w", "rewrite"]), [1, 0, 2]);
    }

    #[test]
    fn two_candidates_that_are_the_pattern_keep_their_order_whatever_their_scores() {
        let mut scorer = Canned::new(&[Some(50), Some(1), Some(9)]);

        assert_eq!(rank(&mut scorer, "w", &["wq", "w", "w"]), [1, 2, 0]);
    }

    #[test]
    fn a_candidate_that_is_the_pattern_and_was_not_matched_is_not_answered() {
        let mut scorer = Canned::new(&[Some(3), None]);

        assert_eq!(rank(&mut scorer, "w", &["wq", "w"]), [0]);
    }

    #[test]
    fn the_scorer_is_asked_once_with_the_pattern_and_the_candidates_as_given() {
        let mut scorer = Canned::new(&[Some(1), Some(2)]);

        rank(&mut scorer, "a pattern", &["one", "two"]);

        assert_eq!(
            scorer.asked,
            [(
                "a pattern".to_owned(),
                vec!["one".to_owned(), "two".to_owned()]
            )]
        );
    }

    #[test]
    fn fewer_scores_than_candidates_leave_the_rest_unmatched() {
        let mut scorer = Canned::new(&[Some(1), Some(2)]);

        // The third candidate is the pattern and has no score: not matched.
        assert_eq!(rank(&mut scorer, "c", &["a", "b", "c", "d"]), [1, 0]);
    }

    #[test]
    fn more_scores_than_candidates_are_ignored() {
        let mut scorer = Canned::new(&[Some(1), Some(2), Some(99), None, Some(7)]);

        assert_eq!(rank(&mut scorer, "p", &["a", "b"]), [1, 0]);
    }
}
