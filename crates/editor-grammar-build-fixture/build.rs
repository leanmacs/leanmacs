//! Compiles the fixture's one grammar, `broken`, whose source does not
//! compile (`broken/src/parser.c`): `editor-grammar-build` records the
//! failure in the report and warns, and the build goes on (README.md).

use editor_grammar_build::{Grammar, build};

fn main() {
    build(&[Grammar::directory("broken", "broken")]);
}
