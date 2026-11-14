//! The contract of the scorer port: the rules every [`Scorer`] keeps, as a
//! check that runs one.
//!
//! [`check`] asks the scorer it is given and returns the names of the
//! properties that fail. Every property is about which candidates a
//! pattern matches and none is about a score: how well a candidate matches
//! is the scorer's own, and nothing above the port may rest on it but
//! through [`rank`](crate::rank).
//!
//! What matches is one rule, stated by [`IN_ORDER`], [`LACKING`] and
//! [`OUT_OF_ORDER`] together: the pattern's Unicode scalar values all occur
//! in the candidate, in the pattern's order, adjacent or apart. The other
//! properties say what that rule leaves no room for: folding case, taking a
//! composed character for its parts, reading a character of the pattern as
//! syntax. [`SWEEP`] asks the rule of generated texts.

use crate::Scorer;

/// A scorer answers one entry for each candidate.
pub const ONE_EACH: &str = "one answer for each candidate";
/// A pattern whose characters are in a candidate in order, adjacent or
/// apart, matches it.
pub const IN_ORDER: &str =
    "a pattern whose characters are in a candidate in order, adjacent or apart, matches it";
/// A pattern with a character the candidate lacks does not match it.
pub const LACKING: &str = "a pattern with a character the candidate lacks does not match it";
/// A pattern whose characters are in a candidate in another order, or that
/// repeats a character more often than the candidate has it, does not
/// match it.
pub const OUT_OF_ORDER: &str =
    "a pattern's characters out of order, or more of one than the candidate has, do not match it";
/// The empty pattern matches every candidate, the empty one too, and no
/// other pattern matches the empty candidate.
pub const EMPTY: &str =
    "the empty pattern matches every candidate, and no other matches the empty candidate";
/// Case is kept: a letter does not match its other case.
pub const CASE: &str = "a letter does not match its other case";
/// A Unicode scalar value matches itself alone: an accented letter is not
/// its base letter, a composed character is not its decomposed form, and a
/// combining mark is a character of the candidate like any other.
pub const SCALARS: &str = "a scalar value matches itself alone, composed or not";
/// No character of a pattern is syntax: `^`, `$`, `!`, `'`, a backslash
/// and a space are each a character to find.
pub const NO_SYNTAX: &str = "no character of a pattern is syntax";
/// Generated patterns and candidates, from a fixed seed, over four small
/// alphabets: a candidate is matched exactly when the pattern is in order
/// in it.
pub const SWEEP: &str =
    "generated candidates are matched exactly when the pattern is in order in them";

/// Every property, by name.
pub const PROPERTIES: [&str; 9] = [
    ONE_EACH,
    IN_ORDER,
    LACKING,
    OUT_OF_ORDER,
    EMPTY,
    CASE,
    SCALARS,
    NO_SYNTAX,
    SWEEP,
];

/// Holds `scorer` to the contract, and returns the names of the properties
/// that fail: none when it keeps them all.
pub fn check(scorer: &mut impl Scorer) -> Vec<&'static str> {
    let one_each = [0, 1, 4].into_iter().all(|count| {
        let candidates = ["abc", "", "b", "xyz"];
        scorer.scores("b", &candidates[..count]).len() == count
    });
    let in_order = holds(scorer, IN_ORDER_CASES);
    let lacking = holds(scorer, LACKING_CASES);
    let out_of_order = holds(scorer, OUT_OF_ORDER_CASES);
    let empty = holds(scorer, EMPTY_CASES);
    let case = holds(scorer, CASE_CASES);
    let scalars = holds(scorer, SCALARS_CASES);
    let no_syntax = holds(scorer, NO_SYNTAX_CASES);
    let sweep = sweep_holds(scorer);
    [
        (ONE_EACH, one_each),
        (IN_ORDER, in_order),
        (LACKING, lacking),
        (OUT_OF_ORDER, out_of_order),
        (EMPTY, empty),
        (CASE, case),
        (SCALARS, scalars),
        (NO_SYNTAX, no_syntax),
        (SWEEP, sweep),
    ]
    .into_iter()
    .filter_map(|(name, holds)| (!holds).then_some(name))
    .collect()
}

/// A pattern, and candidates asked with it in one call, each with whether
/// the pattern matches it.
type Case = (&'static str, &'static [(&'static str, bool)]);

/// Whether `scorer` matches exactly the candidates each case says, and
/// answers an entry for each.
fn holds(scorer: &mut impl Scorer, cases: &[Case]) -> bool {
    cases.iter().all(|(pattern, expected)| {
        let candidates: Vec<&str> = expected.iter().map(|&(candidate, _)| candidate).collect();
        let matched = scorer.scores(pattern, &candidates);
        matched
            .iter()
            .map(Option::is_some)
            .eq(expected.iter().map(|&(_, matches)| matches))
    })
}

/// [`IN_ORDER`]: the characters together, apart, and at either end.
const IN_ORDER_CASES: &[Case] = &[
    (
        "ace",
        &[
            ("ace", true),
            ("abcde", true),
            ("a-c-e", true),
            ("xxaxxcxxexx", true),
        ],
    ),
    (
        "b",
        &[("b", true), ("abc", true), ("ab", true), ("bc", true)],
    ),
];

/// [`LACKING`]: one character is missing, with a candidate that has them
/// all between two that do not.
const LACKING_CASES: &[Case] = &[
    (
        "axe",
        &[
            ("abcde", false),
            ("axe", true),
            ("ae", false),
            ("ax", false),
            ("xe", false),
        ],
    ),
    ("z", &[("abc", false)]),
];

/// [`OUT_OF_ORDER`]: every character is there, and the order or the count
/// is not.
const OUT_OF_ORDER_CASES: &[Case] = &[
    ("ba", &[("ab", false), ("aab", false), ("bxa", true)]),
    ("eca", &[("abcde", false)]),
    ("aa", &[("a", false), ("ba", false), ("aba", true)]),
    ("aba", &[("ab", false), ("aab", false), ("abxa", true)]),
];

/// [`EMPTY`]: the empty pattern, and the empty candidate.
const EMPTY_CASES: &[Case] = &[
    ("", &[("abc", true), ("", true), (" ", true)]),
    ("a", &[("", false)]),
    (" ", &[("", false)]),
];

/// [`CASE`]: each case of a letter, as a pattern and in a candidate.
const CASE_CASES: &[Case] = &[
    ("a", &[("A", false), ("a", true)]),
    ("A", &[("a", false), ("A", true)]),
    ("Re", &[("reload", false), ("Reload", true)]),
];

/// [`SCALARS`]: `é` is U+00E9, and `e\u{301}` its decomposed form.
const SCALARS_CASES: &[Case] = &[
    ("é", &[("e", false), ("é", true), ("e\u{301}", false)]),
    ("e", &[("é", false), ("e\u{301}", true)]),
    ("\u{301}", &[("e\u{301}", true), ("é", false)]),
    (
        "e\u{301}",
        &[("e\u{301}", true), ("é", false), ("e", false)],
    ),
    ("漢字", &[("漢x字", true), ("字漢", false)]),
    ("🙂", &[("a🙂b", true), ("ab", false)]),
];

/// [`NO_SYNTAX`]: the characters a matching library may read as an anchor,
/// a negation, a quote, an escape or a separator.
const NO_SYNTAX_CASES: &[Case] = &[
    ("^a", &[("a", false), ("^a", true), ("x^xa", true)]),
    ("a$", &[("a", false), ("a$", true)]),
    ("!a", &[("a", false), ("b", false), ("!a", true)]),
    ("'a", &[("a", false), ("'a", true)]),
    (
        "a b",
        &[("ab", false), ("a b", true), ("b a", false), ("a-b", false)],
    ),
    ("\\ ", &[(" ", false), ("\\ ", true)]),
];

/// The alphabets [`SWEEP`] draws from: three letters; two cases and
/// punctuation; accented, combining, wide and astral characters; and the
/// characters of [`NO_SYNTAX`] with a tab and a line feed.
const ALPHABETS: [&[char]; 4] = [
    &['a', 'b', 'c'],
    &['a', 'A', 'b', ' ', '-', '_', '/', '.'],
    &['a', 'é', 'e', '\u{301}', '漢', '🙂', 'A', ' '],
    &['^', '$', '!', '\'', '\\', ' ', 'a', '\t', '\n'],
];

/// How many patterns [`SWEEP`] asks, each with [`SWEEP_CANDIDATES`]
/// candidates.
const SWEEP_PATTERNS: u64 = 2_000;

/// How many candidates [`SWEEP`] asks each pattern with.
const SWEEP_CANDIDATES: usize = 10;

/// Whether [`SWEEP`] holds of `scorer`.
fn sweep_holds(scorer: &mut impl Scorer) -> bool {
    let mut generator = Generator(42);
    (0..SWEEP_PATTERNS).all(|round| {
        let alphabet = ALPHABETS[usize::try_from(round).unwrap_or(0) % ALPHABETS.len()];
        let pattern = generator.text(alphabet, 5);
        let candidates: Vec<String> = (0..SWEEP_CANDIDATES)
            .map(|_| generator.text(alphabet, 9))
            .collect();
        let borrowed: Vec<&str> = candidates.iter().map(String::as_str).collect();
        let matched = scorer.scores(&pattern, &borrowed);
        matched.iter().map(Option::is_some).eq(borrowed
            .iter()
            .map(|candidate| in_order(&pattern, candidate)))
    })
}

/// The rule itself, as the contract's own test: whether the scalar values
/// of `pattern` all occur in `candidate`, in order.
fn in_order(pattern: &str, candidate: &str) -> bool {
    let mut rest = candidate.chars();
    pattern
        .chars()
        .all(|wanted| rest.any(|have| have == wanted))
}

/// A linear congruential generator: the same texts on every run, on every
/// machine.
struct Generator(u64);

impl Generator {
    /// The next number.
    fn next(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        self.0 >> 33
    }

    /// The next number below `bound`, which is not 0.
    fn below(&mut self, bound: usize) -> usize {
        usize::try_from(self.next()).unwrap_or(0) % bound
    }

    /// A text of at most `longest` characters of `alphabet`.
    fn text(&mut self, alphabet: &[char], longest: usize) -> String {
        let len = self.below(longest + 1);
        (0..len)
            .map(|_| alphabet[self.below(alphabet.len())])
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::{
        CASE, EMPTY, IN_ORDER, LACKING, NO_SYNTAX, ONE_EACH, OUT_OF_ORDER, PROPERTIES, SCALARS,
        SWEEP, check,
    };
    use crate::Scorer;

    /// A scorer that matches a candidate when `matches` says so of the
    /// pattern and the candidate, and scores every match 0.
    struct By<F>(F);

    impl<F: Fn(&str, &str) -> bool> Scorer for By<F> {
        fn scores(&mut self, pattern: &str, candidates: &[&str]) -> Vec<Option<u32>> {
            candidates
                .iter()
                .map(|candidate| (self.0)(pattern, candidate).then_some(0))
                .collect()
        }
    }

    /// Whether the characters of `pattern` all occur in `candidate`, in
    /// order: the rule, for the scorers below to bend.
    fn within(pattern: &str, candidate: &str) -> bool {
        let mut rest = candidate.chars();
        pattern
            .chars()
            .all(|wanted| rest.any(|have| have == wanted))
    }

    #[test]
    fn a_scorer_that_keeps_the_rule_keeps_the_contract() {
        assert_eq!(check(&mut By(within)), [""; 0]);
    }

    #[test]
    fn the_properties_are_nine_and_each_is_named_once() {
        let mut names = PROPERTIES.to_vec();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), 9);
    }

    #[test]
    fn a_scorer_that_matches_everything_is_reported() {
        assert_eq!(
            check(&mut By(|_: &str, _: &str| true)),
            [
                LACKING,
                OUT_OF_ORDER,
                EMPTY,
                CASE,
                SCALARS,
                NO_SYNTAX,
                SWEEP
            ]
        );
    }

    #[test]
    fn a_scorer_that_needs_the_characters_adjacent_is_reported() {
        let adjacent = |pattern: &str, candidate: &str| candidate.contains(pattern);

        assert_eq!(
            check(&mut By(adjacent)),
            [IN_ORDER, OUT_OF_ORDER, SCALARS, NO_SYNTAX, SWEEP]
        );
    }

    #[test]
    fn a_scorer_that_ignores_ascii_case_is_reported() {
        let folded = |pattern: &str, candidate: &str| {
            within(
                &pattern.to_ascii_lowercase(),
                &candidate.to_ascii_lowercase(),
            )
        };

        assert_eq!(check(&mut By(folded)), [CASE, SWEEP]);
    }

    #[test]
    fn a_scorer_that_takes_the_characters_in_any_order_is_reported() {
        // Each character of the pattern takes one of the candidate's,
        // wherever it is.
        let any_order = |pattern: &str, candidate: &str| {
            let mut left: Vec<char> = candidate.chars().collect();
            pattern.chars().all(|wanted| {
                left.iter()
                    .position(|&have| have == wanted)
                    .map(|at| left.swap_remove(at))
                    .is_some()
            })
        };

        assert_eq!(
            check(&mut By(any_order)),
            [OUT_OF_ORDER, SCALARS, NO_SYNTAX, SWEEP]
        );
    }

    #[test]
    fn a_scorer_that_strips_an_accent_is_reported() {
        let stripped = |pattern: &str, candidate: &str| {
            within(&pattern.replace('é', "e"), &candidate.replace('é', "e"))
        };

        assert_eq!(check(&mut By(stripped)), [SCALARS, SWEEP]);
    }

    #[test]
    fn a_scorer_that_keeps_only_the_first_scalar_of_a_cluster_is_reported() {
        // A combining mark joins the character before it, and only that
        // character is kept of the candidate.
        let first_of_each = |pattern: &str, candidate: &str| {
            let kept: String = candidate
                .chars()
                .filter(|have| !('\u{300}'..='\u{36f}').contains(have))
                .collect();
            within(pattern, &kept)
        };

        assert_eq!(check(&mut By(first_of_each)), [SCALARS, SWEEP]);
    }

    #[test]
    fn a_scorer_that_splits_the_pattern_at_spaces_is_reported() {
        // Each word of the pattern is looked for on its own, from the
        // candidate's start.
        let words = |pattern: &str, candidate: &str| {
            pattern
                .split(' ')
                .filter(|word| !word.is_empty())
                .all(|word| within(word, candidate))
        };

        assert_eq!(check(&mut By(words)), [EMPTY, NO_SYNTAX, SWEEP]);
    }

    #[test]
    fn a_scorer_that_matches_nothing_for_the_empty_pattern_is_reported() {
        let never_empty =
            |pattern: &str, candidate: &str| !pattern.is_empty() && within(pattern, candidate);

        assert_eq!(check(&mut By(never_empty)), [EMPTY, SWEEP]);
    }

    /// A scorer that keeps the rule and answers one entry too few.
    struct OneTooFew;

    impl Scorer for OneTooFew {
        fn scores(&mut self, pattern: &str, candidates: &[&str]) -> Vec<Option<u32>> {
            let mut scores = By(within).scores(pattern, candidates);
            scores.pop();
            scores
        }
    }

    #[test]
    fn a_scorer_that_answers_one_entry_too_few_is_reported() {
        assert!(check(&mut OneTooFew).contains(&ONE_EACH));
    }

    /// A scorer that keeps the rule and answers one entry more.
    struct OneTooMany;

    impl Scorer for OneTooMany {
        fn scores(&mut self, pattern: &str, candidates: &[&str]) -> Vec<Option<u32>> {
            let mut scores = By(within).scores(pattern, candidates);
            scores.push(None);
            scores
        }
    }

    #[test]
    fn a_scorer_that_answers_one_entry_more_is_reported() {
        assert!(check(&mut OneTooMany).contains(&ONE_EACH));
    }
}
