//! Locating a pattern in a text with errors allowed: where a quote is now,
//! after the text around it, or the quote itself, was edited.
//!
//! [`locate`] is what the editor asks: a pattern, a text, the byte offset
//! where the pattern is expected and the most errors allowed in; a byte
//! span of the text out, or none. Which spans of the text are within the
//! errors is a [`Searcher`]'s to say, the port an approximate matching
//! library fills; which of them is answered is decided here, once.
//!
//! # The rule
//!
//! An error is one byte inserted, deleted or substituted: the distance is
//! byte-wise Levenshtein, as the library's is.
//!
//! 1. The empty pattern is answered none, and the searcher is not asked.
//! 2. A span the searcher reports is a candidate when it is within the
//!    text, both its ends are on character boundaries, and its errors are
//!    at most the errors allowed.
//! 3. The answer is a candidate with the fewest errors; of those, the one
//!    whose start is nearest the expected offset; then the earliest; then
//!    the longest. No candidate answers none.
//!
//! "Fewest errors" is all an asker may rest on: which of several equally
//! good spans a library reports is its own, so the ties above order what
//! was reported and promise nothing about what was not.
//!
//! A span whose end cuts a character is dropped, not moved to a boundary:
//! on text that is not ASCII a library's best span can cut one, and then
//! the answer is a worse span or none. That is safe for the editor, which
//! shows a quote it cannot place as drifted and never moves it wrongly.
//!
//! # The fake and the contract
//!
//! [`Scan`] is the port's fake: every span of the text whose ends are
//! character boundaries, measured one by one. [`contract::check_searcher`](crate::contract::check_searcher)
//! is what a real adapter is held to: it passes on the fake in this
//! crate's tests, and each real adapter runs it in its own.

use std::ops::Range;

/// One span of a text that a [`Searcher`] reports: its byte range and how
/// many errors the pattern has against it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Span {
    /// The byte offset of its first byte.
    pub start: usize,
    /// The byte offset just past its last byte.
    pub end: usize,
    /// The byte-wise Levenshtein distance between the pattern and the
    /// span's bytes.
    pub errors: u32,
}

/// The port: what finds the spans of a text within some errors of a
/// pattern.
pub trait Searcher {
    /// Spans of `text` whose byte-wise Levenshtein distance to `pattern`
    /// is at most `max_errors`, each with its distance. It reports at
    /// least one span with the fewest errors any span of the text has,
    /// when that is at most `max_errors`, and none when no span is within
    /// them; more spans, of the same or more errors, are its own to report.
    ///
    /// It is never asked with the empty pattern: [`locate`] answers that
    /// itself.
    fn spans(&mut self, pattern: &str, text: &str, max_errors: u32) -> Vec<Span>;
}

/// The byte span of `text` that `pattern` is answered at, by the rule of
/// the module docs, over what `searcher` reports; `near` is the byte
/// offset where the pattern is expected.
pub fn locate(
    searcher: &mut impl Searcher,
    pattern: &str,
    text: &str,
    near: usize,
    max_errors: u32,
) -> Option<Range<usize>> {
    if pattern.is_empty() {
        return None;
    }
    searcher
        .spans(pattern, text, max_errors)
        .into_iter()
        .filter(|span| {
            span.start <= span.end
                && span.end <= text.len()
                && text.is_char_boundary(span.start)
                && text.is_char_boundary(span.end)
                && span.errors <= max_errors
        })
        .min_by_key(|span| {
            (
                span.errors,
                span.start.abs_diff(near),
                span.start,
                std::cmp::Reverse(span.end),
            )
        })
        .map(|span| span.start..span.end)
}

/// The fake searcher: every span of the text whose ends are character
/// boundaries, measured one by one, and those within the errors reported.
///
/// It is the rule itself, so slow: a text of `n` characters has about
/// `n²/2` spans. It is public, not `cfg(test)`, so the tests of any crate
/// above the port run on it.
#[derive(Debug, Default, Clone, Copy)]
pub struct Scan;

impl Searcher for Scan {
    fn spans(&mut self, pattern: &str, text: &str, max_errors: u32) -> Vec<Span> {
        let boundaries: Vec<usize> = text
            .char_indices()
            .map(|(at, _)| at)
            .chain([text.len()])
            .collect();
        let mut spans = Vec::new();
        for (index, &start) in boundaries.iter().enumerate() {
            for &end in &boundaries[index..] {
                let errors = distance(pattern.as_bytes(), &text.as_bytes()[start..end]);
                if errors <= max_errors {
                    spans.push(Span { start, end, errors });
                }
            }
        }
        spans
    }
}

/// The byte-wise Levenshtein distance between `a` and `b`: the fewest
/// bytes inserted, deleted or substituted that turn one into the other.
pub(crate) fn distance(a: &[u8], b: &[u8]) -> u32 {
    let mut row: Vec<u32> = (0..=b.len())
        .map(|at| u32::try_from(at).unwrap_or(u32::MAX))
        .collect();
    for (i, &left) in a.iter().enumerate() {
        let mut diagonal = row[0];
        row[0] = u32::try_from(i + 1).unwrap_or(u32::MAX);
        for (j, &right) in b.iter().enumerate() {
            let above = row[j + 1];
            let substituted = diagonal + u32::from(left != right);
            row[j + 1] = substituted.min(above + 1).min(row[j] + 1);
            diagonal = above;
        }
    }
    row[b.len()]
}

#[cfg(test)]
mod tests {
    use super::{Scan, Searcher, Span, distance, locate};
    use crate::contract;

    #[test]
    fn the_distance_counts_bytes_inserted_deleted_and_substituted() {
        assert_eq!(distance(b"", b""), 0);
        assert_eq!(distance(b"abc", b"abc"), 0);
        assert_eq!(distance(b"abc", b"axc"), 1);
        assert_eq!(distance(b"abc", b"ac"), 1);
        assert_eq!(distance(b"ac", b"abc"), 1);
        assert_eq!(distance(b"kitten", b"sitting"), 3);
        assert_eq!(distance(b"", b"abc"), 3);
        // `é` is two bytes, and `e` one: a substitution and a deletion.
        assert_eq!(distance("é".as_bytes(), b"e"), 2);
    }

    #[test]
    fn the_fake_keeps_the_contract() {
        assert_eq!(contract::check_searcher(&mut Scan), [""; 0]);
    }

    #[test]
    fn the_fake_reports_every_boundary_span_within_the_errors() {
        let mut spans = Scan.spans("ab", "xab", 0);
        spans.sort_by_key(|span| (span.start, span.end));
        assert_eq!(
            spans,
            [Span {
                start: 1,
                end: 3,
                errors: 0
            }]
        );
        // No span of `é` cuts it.
        assert!(
            Scan.spans("a", "é", 2)
                .iter()
                .all(|span| span.start % 2 == 0 && span.end % 2 == 0)
        );
    }

    #[test]
    fn the_pattern_at_the_expected_offset_is_answered_there() {
        assert_eq!(locate(&mut Scan, "needle", "a needle", 2, 1), Some(2..8));
    }

    #[test]
    fn one_substitution_is_answered_with_its_span() {
        assert_eq!(
            locate(&mut Scan, "needle", "xx neddle yy", 0, 1),
            Some(3..9)
        );
    }

    #[test]
    fn an_insertion_is_answered_with_the_longer_span() {
        assert_eq!(
            locate(&mut Scan, "needle", "xx neeedle yy", 0, 1),
            Some(3..10)
        );
    }

    #[test]
    fn of_two_spans_with_equal_errors_the_one_nearer_the_expected_offset_is_answered() {
        let text = "needle .......... needle";

        assert_eq!(locate(&mut Scan, "needle", text, 0, 1), Some(0..6));
        assert_eq!(locate(&mut Scan, "needle", text, 16, 1), Some(18..24));
    }

    #[test]
    fn fewer_errors_win_over_nearness() {
        let text = "neddle .......... needle";

        assert_eq!(locate(&mut Scan, "needle", text, 0, 2), Some(18..24));
    }

    #[test]
    fn the_empty_pattern_is_answered_none_without_asking() {
        /// A searcher that must not be asked.
        struct Never;
        impl Searcher for Never {
            fn spans(&mut self, _: &str, _: &str, _: u32) -> Vec<Span> {
                panic!("asked")
            }
        }

        assert_eq!(locate(&mut Never, "", "text", 0, 3), None);
    }

    #[test]
    fn no_span_within_the_errors_is_answered_none() {
        assert_eq!(locate(&mut Scan, "needle", "haystack", 0, 1), None);
        assert_eq!(locate(&mut Scan, "needle", "", 0, 1), None);
    }

    #[test]
    fn multibyte_text_is_answered_on_character_boundaries() {
        // `é` against `e` is two errors, so `caf`, one deletion, is
        // answered; and no span that cuts the `é` is.
        let answer = locate(&mut Scan, "cafe", "un café noir", 0, 2);
        assert_eq!(answer, Some(3..6));
        // `で` and `だ` differ in their last byte: one error.
        let answer = locate(&mut Scan, "漢字です", "これは漢字だす", 0, 3);
        assert_eq!(answer, Some(9..21));
    }

    /// A searcher that reports the spans it was made with, whatever it is
    /// asked.
    struct Canned(Vec<Span>);

    impl Searcher for Canned {
        fn spans(&mut self, _: &str, _: &str, _: u32) -> Vec<Span> {
            self.0.clone()
        }
    }

    /// A span of `start..end` with `errors`.
    fn span(start: usize, end: usize, errors: u32) -> Span {
        Span { start, end, errors }
    }

    #[test]
    fn a_reported_span_that_cuts_a_character_is_dropped() {
        // `é` is bytes 1 and 2: a span ending at 2 cuts it.
        let mut searcher = Canned(vec![span(0, 2, 0), span(0, 3, 1)]);

        assert_eq!(locate(&mut searcher, "ab", "aéb", 0, 1), Some(0..3));
        let mut searcher = Canned(vec![span(2, 4, 0)]);
        assert_eq!(locate(&mut searcher, "ab", "aéb", 0, 1), None);
    }

    #[test]
    fn a_reported_span_past_the_text_or_over_the_errors_is_dropped() {
        let mut searcher = Canned(vec![span(0, 9, 0), span(3, 1, 0), span(0, 1, 2)]);

        assert_eq!(locate(&mut searcher, "ab", "abc", 0, 1), None);
    }

    #[test]
    fn of_equally_near_spans_the_earliest_and_then_the_longest_is_answered() {
        let mut searcher = Canned(vec![span(6, 8, 1), span(4, 6, 1), span(4, 7, 1)]);

        assert_eq!(locate(&mut searcher, "ab", "0123456789", 5, 1), Some(4..7));
    }
}
