//! The regex adapter held to the engine port's contract.
//!
//! The check is `editor-search`'s, the same one its fake passes
//! (`editor_search::contract::check`): where a literal is found, on its
//! cases and on its sweep of generated texts cut into generated pieces.

use editor_search::contract;
use editor_search_regex::RegexEngine;

#[test]
fn the_regex_engine_keeps_the_engine_ports_contract() {
    assert_eq!(contract::check(&mut RegexEngine::new()), [""; 0]);
}

#[test]
fn an_engine_that_has_compiled_other_patterns_keeps_the_contract() {
    use editor_search::{Compiled, Engine, Pattern, Pieces};

    let mut engine = RegexEngine::new();
    let pattern = Pattern::parse(r"^\(a\|b\)*.$").unwrap();
    let mut compiled = engine.compile(pattern.branches()[0].sequence()).unwrap();
    compiled.find(&Pieces::new(&["ab", "c\nd"]), 0, 5);

    assert_eq!(contract::check(&mut engine), [""; 0]);
}
