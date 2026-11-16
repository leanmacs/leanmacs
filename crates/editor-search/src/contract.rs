//! The contract of the engine port: the rules every [`Engine`] keeps, as a
//! check that runs one.
//!
//! [`check`] asks the engine it is given and returns the names of the
//! properties that fail. Every case is a literal, parsed from its escaped
//! spelling, since the port's fake answers nothing else: the rule is that
//! a literal is found where it first occurs in `from..=to`, across the
//! pieces' boundaries, with case kept and each scalar value itself alone.
//! [`SWEEP`] asks the rule of generated texts cut into generated pieces.
//! What only a regex shows (`.`, collections, anchors, repetition) is
//! pinned by the adapter's own tests.

use std::ops::Range;

use crate::{Compiled, Engine, Pattern, Pieces};

/// A literal is found at its leftmost occurrence.
pub const LEFTMOST: &str = "a literal is found at its leftmost occurrence";
/// A literal is found across the pieces' boundaries, and empty pieces
/// change nothing.
pub const ACROSS: &str = "a literal is found across the pieces' boundaries";
/// A literal that is not in the text is not found, in an empty text too.
pub const ABSENT: &str = "a literal that is not in the text is not found";
/// Case is kept: a letter does not match its other case.
pub const CASE: &str = "a letter does not match its other case";
/// A Unicode scalar value matches itself alone: an accented letter is not
/// its base letter, and a composed character is not its decomposed form.
pub const SCALARS: &str = "a scalar value matches itself alone, composed or not";
/// A character that is syntax elsewhere, escaped in the pattern, is a
/// character to find.
pub const NO_SYNTAX: &str = "an escaped special is a character to find";
/// A match starts in `from..=to`: none that starts before `from` or after
/// `to` is answered, and one may end after `to`.
pub const SPAN: &str = "a match starts in from..=to and may end after to";
/// No match holds a line feed, and a literal is found on any row.
pub const NO_LINE_FEED: &str = "no match holds a line feed";
/// Generated texts, cut into generated pieces, and literals, from a fixed
/// seed, over four small alphabets: each answer is a naive scan's.
pub const SWEEP: &str = "generated literals are found where a naive scan finds them";

/// Every property, by name.
pub const PROPERTIES: [&str; 9] = [
    LEFTMOST,
    ACROSS,
    ABSENT,
    CASE,
    SCALARS,
    NO_SYNTAX,
    SPAN,
    NO_LINE_FEED,
    SWEEP,
];

/// Holds `engine` to the contract, and returns the names of the properties
/// that fail: none when it keeps them all.
pub fn check(engine: &mut impl Engine) -> Vec<&'static str> {
    [
        (LEFTMOST, holds(engine, LEFTMOST_CASES)),
        (ACROSS, holds(engine, ACROSS_CASES)),
        (ABSENT, holds(engine, ABSENT_CASES)),
        (CASE, holds(engine, CASE_CASES)),
        (SCALARS, holds(engine, SCALARS_CASES)),
        (NO_SYNTAX, holds(engine, NO_SYNTAX_CASES)),
        (SPAN, holds(engine, SPAN_CASES)),
        (NO_LINE_FEED, holds(engine, NO_LINE_FEED_CASES)),
        (SWEEP, sweep_holds(engine)),
    ]
    .into_iter()
    .filter_map(|(name, holds)| (!holds).then_some(name))
    .collect()
}

/// The pieces of a text, a literal, `from` and `to`, and the match the
/// literal answers there, as a start and an end, or none.
type Case = (
    &'static [&'static str],
    &'static str,
    usize,
    usize,
    Option<(usize, usize)>,
);

/// Whether `engine` answers each case's match.
fn holds(engine: &mut impl Engine, cases: &[Case]) -> bool {
    cases.iter().all(|&(pieces, literal, from, to, expected)| {
        let haystack = Pieces::new(pieces);
        let expected = expected.map(|(start, end)| start..end);
        found(engine, literal, &haystack, from, to).is_some_and(|answer| answer == expected)
    })
}

/// What `engine` answers for `literal` in `haystack` from `from` to `to`;
/// none when it refuses to compile it.
fn found(
    engine: &mut impl Engine,
    literal: &str,
    haystack: &Pieces<'_>,
    from: usize,
    to: usize,
) -> Option<Option<Range<usize>>> {
    let pattern = Pattern::parse(&escaped(literal)).ok()?;
    let [branch] = pattern.branches() else {
        return None;
    };
    let mut compiled = engine.compile(branch.sequence()).ok()?;
    Some(compiled.find(haystack, from, to))
}

/// `literal` spelt as a pattern that matches it: each character the
/// syntax reads specially, escaped.
fn escaped(literal: &str) -> String {
    let mut pattern = String::with_capacity(literal.len());
    for c in literal.chars() {
        if "\\.*[]~^$".contains(c) {
            pattern.push('\\');
        }
        pattern.push(c);
    }
    pattern
}

/// [`LEFTMOST`]: the first of several occurrences, at the start, the end
/// and the middle, overlapping too.
const LEFTMOST_CASES: &[Case] = &[
    (&["xabab"], "ab", 0, 5, Some((1, 3))),
    (&["abab"], "ab", 0, 4, Some((0, 2))),
    (&["xxab"], "ab", 0, 4, Some((2, 4))),
    (&["aaaa"], "aa", 0, 4, Some((0, 2))),
    (&["abcabc"], "c", 0, 6, Some((2, 3))),
];

/// [`ACROSS`]: a literal split between two pieces and three, with empty
/// pieces among them.
const ACROSS_CASES: &[Case] = &[
    (&["xa", "b"], "ab", 0, 3, Some((1, 3))),
    (&["fo", "o"], "foo", 0, 3, Some((0, 3))),
    (&["f", "o", "o"], "foo", 0, 3, Some((0, 3))),
    (&["", "f", "", "oo", ""], "foo", 0, 3, Some((0, 3))),
    (&["a", "b", "ab"], "ab", 1, 4, Some((2, 4))),
    (&["é", "漢"], "é漢", 0, 5, Some((0, 5))),
];

/// [`ABSENT`]: a missing character, a near miss and an empty text.
const ABSENT_CASES: &[Case] = &[
    (&["abc"], "x", 0, 3, None),
    (&["ab", "c"], "abd", 0, 3, None),
    (&["aab"], "abb", 0, 3, None),
    (&["ab"], "abc", 0, 2, None),
    (&[], "a", 0, 0, None),
    (&[""], "a", 0, 0, None),
];

/// [`CASE`]: each case of a letter.
const CASE_CASES: &[Case] = &[
    (&["A"], "a", 0, 1, None),
    (&["a"], "A", 0, 1, None),
    (&["Reload reload"], "reload", 0, 13, Some((7, 13))),
];

/// [`SCALARS`]: `é` is U+00E9, and `e\u{301}` its decomposed form.
const SCALARS_CASES: &[Case] = &[
    (&["e é"], "é", 0, 4, Some((2, 4))),
    (&["é"], "e", 0, 2, None),
    (&["é e\u{301}"], "e\u{301}", 0, 6, Some((3, 6))),
    (&["e\u{301}"], "é", 0, 3, None),
    (&["e\u{301}"], "e", 0, 3, Some((0, 1))),
    (&["x🙂"], "🙂", 0, 5, Some((1, 5))),
];

/// [`NO_SYNTAX`]: what a regex reads as a wildcard, a repeat, a class, an
/// anchor or a group.
const NO_SYNTAX_CASES: &[Case] = &[
    (&["axb a.b"], "a.b", 0, 7, Some((4, 7))),
    (&["aab a*b"], "a*b", 0, 7, Some((4, 7))),
    (&["a [a]"], "[a]", 0, 5, Some((2, 5))),
    (&["a^b ^"], "^", 0, 5, Some((1, 2))),
    (&["$a$"], "a$", 0, 3, Some((1, 3))),
    (&["x\\y"], "\\", 0, 3, Some((1, 2))),
    (&["~"], "~", 0, 1, Some((0, 1))),
    (&["ab (a|b)+"], "(a|b)+", 0, 9, Some((3, 9))),
    (&["a{2} \\s"], "{2} \\s", 0, 7, Some((1, 7))),
];

/// [`SPAN`]: `from` and `to` at, before and after an occurrence.
const SPAN_CASES: &[Case] = &[
    (&["abab"], "ab", 1, 4, Some((2, 4))),
    (&["abab"], "ab", 1, 1, None),
    (&["abab"], "ab", 2, 2, Some((2, 4))),
    (&["abab"], "ab", 0, 0, Some((0, 2))),
    (&["xab"], "ab", 0, 1, Some((1, 3))),
    (&["xxab"], "ab", 0, 1, None),
    (&["abab"], "ab", 3, 4, None),
    (&["ab\nab"], "ab", 1, 5, Some((3, 5))),
    (&["ab", "\na", "b"], "ab", 1, 3, Some((3, 5))),
];

/// [`NO_LINE_FEED`]: a literal broken by a line feed is not there, and a
/// literal on a later row is.
const NO_LINE_FEED_CASES: &[Case] = &[
    (&["a\nb"], "ab", 0, 3, None),
    (&["a\nb ab"], "ab", 0, 6, Some((4, 6))),
    (&["\n", "\na"], "a", 0, 3, Some((2, 3))),
    (&["ab\r\nab"], "b\r", 0, 6, Some((1, 3))),
];

/// The alphabets [`SWEEP`] draws from: three letters; two cases, rows and
/// a carriage return; accented, combining, wide and astral characters; and
/// the characters of [`NO_SYNTAX`].
const ALPHABETS: [&[char]; 4] = [
    &['a', 'b', 'c'],
    &['a', 'A', 'b', ' ', '\n', '\r'],
    &['a', 'é', 'e', '\u{301}', '漢', '🙂', '\n'],
    &[
        '\\', '.', '*', '[', ']', '~', '^', '$', '(', '|', '+', '{', 'a', '\n',
    ],
];

/// How many texts [`SWEEP`] asks of, each with [`SWEEP_QUESTIONS`]
/// questions.
const SWEEP_TEXTS: u64 = 2_000;

/// How many questions [`SWEEP`] asks of each text.
const SWEEP_QUESTIONS: usize = 5;

/// Whether [`SWEEP`] holds of `engine`.
fn sweep_holds(engine: &mut impl Engine) -> bool {
    let mut generator = Generator(42);
    (0..SWEEP_TEXTS).all(|round| {
        let alphabet = ALPHABETS[usize::try_from(round).unwrap_or(0) % ALPHABETS.len()];
        let text = generator.text(alphabet, 12);
        let pieces = generator.cut(&text);
        let haystack = Pieces::new(&pieces);
        let positions: Vec<usize> = text
            .char_indices()
            .map(|(at, _)| at)
            .chain([text.len()])
            .collect();
        let letters: Vec<char> = alphabet.iter().copied().filter(|&c| c != '\n').collect();
        (0..SWEEP_QUESTIONS).all(|_| {
            let mut literal = generator.text(&letters, 2);
            literal.push(letters[generator.below(letters.len())]);
            let from = positions[generator.below(positions.len())];
            let later: Vec<usize> = positions.iter().copied().filter(|&at| at >= from).collect();
            let to = later[generator.below(later.len())];
            found(engine, &literal, &haystack, from, to) == Some(scan(&text, &literal, from, to))
        })
    })
}

/// The rule itself, as the contract's own test: the first position in
/// `from..=to` where `text` continues with `literal`.
fn scan(text: &str, literal: &str, from: usize, to: usize) -> Option<Range<usize>> {
    (from..=to)
        .filter(|&at| text.is_char_boundary(at))
        .find(|&at| text[at..].starts_with(literal))
        .map(|at| at..at + literal.len())
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

    /// `text` cut at character boundaries into up to five pieces, some of
    /// them empty.
    fn cut<'t>(&mut self, text: &'t str) -> Vec<&'t str> {
        let positions: Vec<usize> = text
            .char_indices()
            .map(|(at, _)| at)
            .chain([text.len()])
            .collect();
        let mut cuts: Vec<usize> = (0..self.below(5))
            .map(|_| positions[self.below(positions.len())])
            .collect();
        cuts.sort_unstable();
        let mut pieces = Vec::with_capacity(cuts.len() + 1);
        let mut start = 0;
        for cut in cuts {
            pieces.push(&text[start..cut]);
            start = cut;
        }
        pieces.push(&text[start..]);
        pieces
    }
}

#[cfg(test)]
mod tests {
    use std::ops::Range;

    use super::{
        ACROSS, CASE, LEFTMOST, NO_LINE_FEED, NO_SYNTAX, PROPERTIES, SCALARS, SPAN, SWEEP, check,
    };
    use crate::{Compiled, Engine, Literal, Pieces, Refusal, Sequence};

    #[test]
    fn the_fake_keeps_the_contract() {
        assert_eq!(check(&mut Literal), [""; 0]);
    }

    #[test]
    fn the_properties_are_nine_and_each_is_named_once() {
        let mut names = PROPERTIES.to_vec();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), 9);
    }

    /// The rule of a finder: the text as one string, the literal, `from`
    /// and `to`, and the answer.
    type Finder = fn(&str, &str, usize, usize) -> Option<Range<usize>>;

    /// An engine that compiles a literal run and answers what its finder
    /// says, over the text made one string.
    struct By(Finder);

    /// A literal compiled by [`By`].
    struct ByRun(Finder, String);

    impl Engine for By {
        type Compiled = ByRun;

        fn compile(&mut self, sequence: &Sequence) -> Result<ByRun, Refusal> {
            let literal = sequence.literal().ok_or(Refusal::new("not literal"))?;
            Ok(ByRun(self.0, literal))
        }
    }

    impl Compiled for ByRun {
        fn find(&mut self, haystack: &Pieces<'_>, from: usize, to: usize) -> Option<Range<usize>> {
            let text: String = haystack.pieces().concat();
            (self.0)(&text, &self.1, from, to)
        }
    }

    /// The rule, for the finders below to bend.
    fn first(text: &str, literal: &str, from: usize, to: usize) -> Option<Range<usize>> {
        (from..=to)
            .filter(|&at| text.is_char_boundary(at))
            .find(|&at| text[at..].starts_with(literal))
            .map(|at| at..at + literal.len())
    }

    #[test]
    fn an_engine_that_keeps_the_rule_keeps_the_contract() {
        assert_eq!(check(&mut By(first)), [""; 0]);
    }

    #[test]
    fn an_engine_that_finds_nothing_is_reported() {
        assert_eq!(
            check(&mut By(|_, _, _, _| None)),
            [
                LEFTMOST,
                ACROSS,
                CASE,
                SCALARS,
                NO_SYNTAX,
                SPAN,
                NO_LINE_FEED,
                SWEEP
            ]
        );
    }

    #[test]
    fn an_engine_that_finds_the_rightmost_is_reported() {
        let rightmost = |text: &str, literal: &str, from: usize, to: usize| {
            (from..=to)
                .rev()
                .filter(|&at| text.is_char_boundary(at))
                .find(|&at| text[at..].starts_with(literal))
                .map(|at| at..at + literal.len())
        };
        assert_eq!(check(&mut By(rightmost)), [LEFTMOST, NO_SYNTAX, SWEEP]);
    }

    /// An engine that looks in the piece that holds `from` alone.
    struct OnePiece;

    impl Engine for OnePiece {
        type Compiled = OnePieceRun;

        fn compile(&mut self, sequence: &Sequence) -> Result<OnePieceRun, Refusal> {
            Ok(OnePieceRun(sequence.literal().ok_or(Refusal::new("x"))?))
        }
    }

    /// A literal compiled by [`OnePiece`].
    struct OnePieceRun(String);

    impl Compiled for OnePieceRun {
        fn find(&mut self, haystack: &Pieces<'_>, from: usize, to: usize) -> Option<Range<usize>> {
            let index = haystack.piece_holding(from);
            let piece = haystack.pieces().get(index)?;
            let start = haystack.start_of(index);
            let found = first(piece, &self.0, from - start, (to - start).min(piece.len()))?;
            Some(found.start + start..found.end + start)
        }
    }

    #[test]
    fn an_engine_that_does_not_cross_a_pieces_boundary_is_reported() {
        assert_eq!(check(&mut OnePiece), [ACROSS, SPAN, NO_LINE_FEED, SWEEP]);
    }

    #[test]
    fn an_engine_that_ignores_ascii_case_is_reported() {
        let folded = |text: &str, literal: &str, from: usize, to: usize| {
            first(
                &text.to_ascii_lowercase(),
                &literal.to_ascii_lowercase(),
                from,
                to,
            )
        };
        assert_eq!(check(&mut By(folded)), [CASE, SWEEP]);
    }

    #[test]
    fn an_engine_that_strips_a_combining_mark_is_reported() {
        let stripped = |text: &str, literal: &str, from: usize, to: usize| {
            // The mark is taken for nothing: the literal without it is
            // looked for, and the answer keeps the text's offsets.
            let literal: String = literal.chars().filter(|&c| c != '\u{301}').collect();
            first(text, &literal, from, to)
        };
        assert_eq!(check(&mut By(stripped)), [SCALARS, SWEEP]);
    }

    #[test]
    fn an_engine_that_reads_a_dot_as_any_character_is_reported() {
        let wild = |text: &str, literal: &str, from: usize, to: usize| {
            (from..=to)
                .filter(|&at| text.is_char_boundary(at))
                .find(|&at| {
                    let mut have = text[at..].chars();
                    literal
                        .chars()
                        .all(|want| have.next().is_some_and(|c| want == '.' || c == want))
                })
                .map(|at| {
                    let len: usize = text[at..]
                        .chars()
                        .take(literal.chars().count())
                        .map(char::len_utf8)
                        .sum();
                    at..at + len
                })
        };
        assert_eq!(check(&mut By(wild)), [NO_SYNTAX, SWEEP]);
    }

    #[test]
    fn an_engine_that_ignores_to_is_reported() {
        let unbounded = |text: &str, literal: &str, from: usize, _to: usize| {
            first(text, literal, from, text.len())
        };
        assert_eq!(check(&mut By(unbounded)), [SPAN, SWEEP]);
    }

    #[test]
    fn an_engine_that_ignores_from_is_reported() {
        let unbounded =
            |text: &str, literal: &str, _from: usize, to: usize| first(text, literal, 0, to);
        assert_eq!(check(&mut By(unbounded)), [ACROSS, SPAN, SWEEP]);
    }

    #[test]
    fn an_engine_that_skips_line_feeds_is_reported() {
        let joined = |text: &str, literal: &str, from: usize, to: usize| {
            // The text's line feeds are passed over while matching, so a
            // match can hold one.
            (from..=to)
                .filter(|&at| text.is_char_boundary(at))
                .find_map(|at| {
                    let mut end = at;
                    for want in literal.chars() {
                        while text[end..].starts_with('\n') {
                            end += 1;
                        }
                        let have = text[end..].chars().next()?;
                        if have != want {
                            return None;
                        }
                        end += have.len_utf8();
                    }
                    Some(at..end)
                })
        };
        assert_eq!(check(&mut By(joined)), [SPAN, NO_LINE_FEED, SWEEP]);
    }

    #[test]
    fn an_engine_that_refuses_everything_is_reported_on_every_property() {
        /// An engine that compiles nothing.
        struct Refuses;

        impl Engine for Refuses {
            type Compiled = ByRun;

            fn compile(&mut self, _: &Sequence) -> Result<ByRun, Refusal> {
                Err(Refusal::new("no"))
            }
        }

        assert_eq!(check(&mut Refuses), PROPERTIES);
    }
}
