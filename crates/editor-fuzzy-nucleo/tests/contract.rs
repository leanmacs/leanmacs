//! The nucleo adapter held to the scorer port's contract.
//!
//! The check is `editor-fuzzy`'s, the same one its fake passes
//! (`editor_fuzzy::contract::check`): which candidates a pattern matches,
//! on its cases and on its sweep of generated texts. It asks nothing of a
//! score.

use editor_fuzzy::contract;
use editor_fuzzy_nucleo::NucleoScorer;

#[test]
fn the_nucleo_scorer_keeps_the_scorer_ports_contract() {
    assert_eq!(contract::check(&mut NucleoScorer::new()), [""; 0]);
}

#[test]
fn a_scorer_that_has_answered_other_questions_keeps_the_contract() {
    use editor_fuzzy::Scorer;

    let mut scorer = NucleoScorer::new();
    scorer.scores("some pattern", &["some other pattern", "", "som"]);

    assert_eq!(contract::check(&mut scorer), [""; 0]);
}
