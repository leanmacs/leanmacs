//! What the syntax wiring tests share: the six grammars the `languages`
//! package ships, registered from the native libraries
//! `editor-syntax-fixture-grammars` builds, since the process's syntax
//! service compiles in no grammar (`editor_ffi::syntax`, "The adapter
//! compiles in no grammar").
//!
//! [`registered`] registers each on the process's service once per test
//! binary, through the worker's queue as a grammar job's registration goes,
//! and waits on every answer. Its `OnceLock` blocks a test that calls it
//! while another is registering until every answer is in, so no test's
//! result depends on how the tests are scheduled. Every test that names a
//! grammar calls it first. [`adapter`] is a local adapter, the tests'
//! oracle, with the six registered on it directly.

use std::sync::OnceLock;
use std::sync::mpsc;
use std::time::Duration;

use editor_wait::HangGuard;

use editor_ffi::syntax::syntaxes;
use editor_syntax::{GrammarName, GrammarSource, ReparsePolicy, Syntax};
use editor_syntax_fixture_grammars::{ALL, Grammar};
use editor_syntax_treesitter::TreeSitter;

/// hang guard: a registration's answer; only a hang reaches the bound, and
/// the test then fails as a hang.
const REGISTRATION: HangGuard = HangGuard::on("a registration", Duration::from_secs(10));

/// The source of `grammar`'s library, with its policy.
fn source(grammar: &Grammar) -> GrammarSource {
    GrammarSource {
        library: grammar.library.into(),
        symbol: grammar.symbol.to_owned(),
        policy: Some(if grammar.incremental {
            ReparsePolicy::Incremental
        } else {
            ReparsePolicy::Whole
        }),
    }
}

/// Registers the six on the process's syntax service, once per test
/// binary, and returns once every registration is answered.
pub fn registered() {
    /// Set once every registration is answered.
    static REGISTERED: OnceLock<()> = OnceLock::new();
    REGISTERED.get_or_init(|| {
        let handle = syntaxes().handle().expect("the syntax worker starts");
        for grammar in &ALL {
            let (sender, answers) = mpsc::channel();
            handle.register(
                source(grammar),
                Box::new(move |answer| {
                    let _ = sender.send(answer);
                }),
            );
            assert_eq!(
                editor_wait::recv(&answers, REGISTRATION),
                Ok(Some(Ok(GrammarName::new(grammar.name)))),
                "{}",
                grammar.name
            );
        }
    });
}

/// A local adapter with the six registered on it.
pub fn adapter() -> TreeSitter {
    let syntax = TreeSitter::default();
    for grammar in &ALL {
        assert_eq!(
            syntax.register(&source(grammar)),
            Ok(GrammarName::new(grammar.name)),
            "{}",
            grammar.name
        );
    }
    syntax
}
