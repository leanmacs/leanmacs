//! Prints the fixture grammar library's path and nothing else, for
//! `mise run ffi-test` to hand to Lean's `contract-test`.

fn main() {
    println!("{}", editor_syntax_fixture_ini::LIBRARY);
}
