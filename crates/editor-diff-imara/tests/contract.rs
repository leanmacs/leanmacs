//! The imara adapter held to the line diff port's contract.
//!
//! The check is `editor-diff`'s, the same one its fake passes
//! (`editor_diff::contract::check`): what a script gives, what it keeps,
//! where its steps start and stop, and the engine's own hunks.

use editor_diff::{LineDiff, Step, contract, lines, run, script};
use editor_diff_imara::ImaraDiff;

#[test]
fn the_imara_engine_keeps_the_line_diff_ports_contract() {
    assert_eq!(contract::check(&mut ImaraDiff::new()), [""; 0]);
}

#[test]
fn an_engine_that_has_diffed_other_texts_keeps_the_contract() {
    let mut engine = ImaraDiff::new();
    engine.hunks(&lines("x\ny\nz\n"), &lines("z\ny\nx\n"));
    assert_eq!(contract::check(&mut engine), [""; 0]);
}

#[test]
fn a_moved_block_of_many_lines_is_a_script_that_applies() {
    let old: String = (0..2000).map(|line| format!("line {line}\n")).collect();
    let new: String = (1000..2000)
        .chain(0..1000)
        .map(|line| format!("line {line}\n"))
        .collect();
    let steps = script(&mut ImaraDiff::new(), &old, &new, 100_000);
    assert_eq!(run(&old, &new, &steps).as_deref(), Some(new.as_str()));
    assert!(
        steps
            .iter()
            .any(|step| matches!(step, Step::Retain(count) if *count > 1000))
    );
}
