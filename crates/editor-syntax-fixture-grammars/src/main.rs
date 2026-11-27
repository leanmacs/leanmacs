//! Prints the fixture grammars' directory and nothing else, for
//! `mise run ffi-test` to hand to Lean's test programs.

fn main() {
    println!("{}", editor_syntax_fixture_grammars::DIRECTORY);
}
