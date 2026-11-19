//! The triple_accel adapter held to the searcher port's contract.
//!
//! The check is `editor-fuzzy`'s, the same one its fake passes
//! (`editor_fuzzy::contract::check_searcher`): which spans are reported
//! and with how many errors, against an exhaustive oracle, on its cases
//! and on its sweep of generated texts from a fixed seed.

use editor_fuzzy::contract;
use editor_fuzzy::locate::{self, Searcher};
use editor_fuzzy_triple_accel::TripleAccel;

#[test]
fn the_triple_accel_searcher_keeps_the_searcher_ports_contract() {
    assert_eq!(contract::check_searcher(&mut TripleAccel::new()), [""; 0]);
}

#[test]
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
fn a_pattern_with_no_span_near_enough_reports_none() {
    let spans = TripleAccel::new().spans("needle", "haystack haystack", 1);

    assert_eq!(spans, []);
}
