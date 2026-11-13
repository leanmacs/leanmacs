//! Property tests of the crate, through its public API alone.
//!
//! Each property drives a [`Text`] and a reference, a `String`, with the
//! same generated steps and compares the two.
//!
//! # Deterministic and hermetic
//!
//! Every property runs through [`check`], which fixes what decides a pass:
//! the number of cases and the generator's seed. It turns failure
//! persistence off, so no `proptest-regressions` file is written beside the
//! sources. `proptest`'s default configuration reads `PROPTEST_*` variables
//! from the environment, so the `proptest!` macro is not used, and every
//! collection strategy below states its own size. The library is built
//! without its default features: no fork, no timeout, no temporary file.
//! What the environment can still change is how a failure is shrunk and
//! printed.
//!
//! # What the generators favour
//!
//! Text that breaks index code: characters of one to four bytes (the last
//! is two UTF-16 units), every line ending, the escape characters a raw
//! byte is kept as, U+FFFD, NUL and the empty string. One case in eight
//! is a text of kilobytes to hundreds of kilobytes, which the rope holds
//! in many pieces.

use std::fmt::Debug;

use editor_text::Text;
use proptest::collection::vec;
use proptest::prelude::*;
use proptest::sample::select;
use proptest::test_runner::{Config, RngAlgorithm, TestCaseError, TestRng, TestRunner};

/// Runs `property` on `cases` values of `strategy`, from a fixed seed, and
/// panics with the smallest failing value if one fails.
fn check<S>(cases: u32, strategy: S, property: impl Fn(S::Value) -> Result<(), TestCaseError>)
where
    S: Strategy,
    S::Value: Debug,
{
    let config = Config {
        cases,
        failure_persistence: None,
        ..Config::default()
    };
    let mut runner =
        TestRunner::new_with_rng(config, TestRng::deterministic_rng(RngAlgorithm::ChaCha));
    if let Err(failure) = runner.run(&strategy, property) {
        panic!("{failure}");
    }
}

/// The pieces a generated text is made of.
const FRAGMENTS: &[&str] = &[
    "",
    "a",
    "b",
    " ",
    "hello",
    "\n",
    "\n",
    "\r",
    "\r\n",
    "\0",
    // Two, three and four bytes; the last is two UTF-16 units.
    "é",
    "ö",
    "€",
    "😀",
    "\u{FFFD}",
    // The characters the bytes 0x80 and 0xFF are kept as.
    "\u{10DC80}",
    "\u{10DCFF}",
];

/// A text of up to `fragments` pieces of [`FRAGMENTS`].
fn short_text(fragments: usize) -> impl Strategy<Value = String> {
    vec(select(FRAGMENTS), 0..=fragments).prop_map(|pieces| pieces.concat())
}

/// A text to start from: seven in eight are short, and the eighth is a
/// short text repeated until the rope holds it in many pieces.
fn initial_text() -> impl Strategy<Value = String> {
    prop_oneof![
        7 => short_text(24),
        1 => (short_text(24), 200_usize..4_000).prop_map(|(text, times)| text.repeat(times)),
    ]
}

/// One generated edit, before it is fitted to a text.
#[derive(Debug, Clone)]
struct Step {
    /// Where the range starts, as a number to cut down to the text.
    start: usize,
    /// Where the range ends, likewise.
    end: usize,
    /// Whether to move both offsets onto character boundaries and put them
    /// in order, so that the edit is one the text accepts.
    fitted: bool,
    /// What to put in place of the range.
    insert: String,
}

impl Step {
    /// The range this step names in `reference`. Unfitted, an offset may be
    /// inside a character, up to two past the end, or after the other one.
    fn range(&self, reference: &str) -> (usize, usize) {
        let reach = reference.len() + 3;
        let (start, end) = (self.start % reach, self.end % reach);
        if !self.fitted {
            return (start, end);
        }
        let (start, end) = (floor(reference, start), floor(reference, end));
        (start.min(end), start.max(end))
    }
}

/// The last character boundary of `reference` at or before `offset`.
fn floor(reference: &str, offset: usize) -> usize {
    let mut offset = offset.min(reference.len());
    while !reference.is_char_boundary(offset) {
        offset -= 1;
    }
    offset
}

/// Up to `steps` edits, three in four of them fitted.
fn steps(steps: usize) -> impl Strategy<Value = Vec<Step>> {
    let step = (
        any::<usize>(),
        any::<usize>(),
        prop::bool::weighted(0.75),
        short_text(6),
    )
        .prop_map(|(start, end, fitted, insert)| Step {
            start,
            end,
            fitted,
            insert,
        });
    vec(step, 0..=steps)
}

/// Whether a replace of `start..end` is one a text holding `reference`
/// accepts: both offsets are character boundaries within it, in order.
fn accepts(reference: &str, start: usize, end: usize) -> bool {
    start <= end && reference.is_char_boundary(start) && reference.is_char_boundary(end)
}

#[test]
fn edits_agree_with_a_string() {
    check(256, (initial_text(), steps(16)), |(initial, steps)| {
        let mut reference = initial;
        let mut text = Text::from(reference.as_str());
        let mut accepted = 0;

        for step in steps {
            let (start, end) = step.range(&reference);
            let expected = accepts(&reference, start, end);

            let result = text.replace(start..end, &step.insert);

            prop_assert_eq!(result.is_ok(), expected, "replace {}..{}", start, end);
            if expected {
                reference.replace_range(start..end, &step.insert);
                accepted += 1;
            }
            prop_assert_eq!(&text.current().to_string(), &reference);
            prop_assert_eq!(text.current().len(), reference.len());
            prop_assert_eq!(text.current().revision().get(), accepted);
        }
        Ok(())
    });
}
