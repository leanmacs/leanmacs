//! The triple_accel adapter held to the searcher port's contract.
//!
//! The check is `editor-fuzzy`'s, the same one its fake passes
//! (`editor_fuzzy::contract::check_searcher`): which spans are reported
//! and with how many errors, against an exhaustive oracle, on its cases
//! and on its sweep of generated texts from a fixed seed.

use editor_fuzzy::contract;
use editor_fuzzy::locate::{self, Searcher, Span};
use editor_fuzzy_triple_accel::TripleAccel;

#[test]
#[expect(
    clippy::disallowed_methods,
    reason = "the adapter's contract check: the library is what it holds to the port"
)]
fn the_triple_accel_searcher_keeps_the_searcher_ports_contract() {
    assert_eq!(contract::check_searcher(&mut TripleAccel::new()), [""; 0]);
}

#[test]
#[expect(
    clippy::disallowed_methods,
    reason = "the adapter's contract check: the library is what it holds to the port"
)]
fn a_pattern_with_one_substitution_is_found_with_one_error() {
    let text = "fn main() { println!(\"helo, world\"); }";
    let spans = TripleAccel::new().spans("hello, world", text, 3);

    assert_eq!(spans.iter().map(|span| span.errors).min(), Some(1));
    assert_eq!(
        locate::locate(&mut TripleAccel::new(), "hello, world", text, 0, 3),
        Some(22..33)
    );
}

#[test]
#[expect(
    clippy::disallowed_methods,
    reason = "the adapter's contract check: the library is what it holds to the port"
)]
fn a_pattern_with_no_span_near_enough_reports_none() {
    let spans = TripleAccel::new().spans("needle", "haystack haystack", 1);

    assert_eq!(spans, []);
}

#[test]
#[expect(
    clippy::disallowed_methods,
    reason = "the adapter's contract check: the library is what it holds to the port"
)]
fn an_empty_text_is_answered_with_the_empty_span_when_the_pattern_is_within_the_errors_allowed() {
    // Round 20 of the contract's sweep: on x86_64 the library's SIMD search
    // reports no span of an empty text.
    let spans = TripleAccel::new().spans("A", "", 1);

    assert_eq!(
        spans,
        [Span {
            start: 0,
            end: 0,
            errors: 1
        }]
    );
}

#[test]
#[expect(
    clippy::disallowed_methods,
    reason = "the adapter's contract check: the library is what it holds to the port"
)]
fn an_empty_text_reports_the_empty_span_only_when_the_whole_pattern_is_within_the_errors_allowed() {
    assert_eq!(
        TripleAccel::new().spans("ab", "", 2),
        [Span {
            start: 0,
            end: 0,
            errors: 2
        }]
    );
    assert_eq!(TripleAccel::new().spans("ab", "", 1), []);
}
