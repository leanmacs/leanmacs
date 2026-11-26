//! The tree-sitter adapter refuses every registration of a grammar at run
//! time as unsupported, and lists the grammars it lists before: it loads no
//! grammar at run time until native libraries are (the crate docs, "What
//! each method forwards to").
//!
//! The check is `editor-syntax`'s, the one any adapter that loads no
//! grammar runs (`editor_syntax::contract::registration::check_unsupported`).
//! No file is created: the adapter reads none, so the sources name a path
//! that does not exist.

use std::path::PathBuf;

use editor_syntax::contract::registration::check_unsupported;
use editor_syntax::{GrammarSource, ReparsePolicy};
use editor_syntax_treesitter::TreeSitter;

/// A source of `symbol` at a path that does not exist, declaring `policy`.
fn source(symbol: &str, policy: Option<ReparsePolicy>) -> GrammarSource {
    GrammarSource {
        library: PathBuf::from("/nonexistent/libtree-sitter-grammar.so"),
        symbol: symbol.to_owned(),
        policy,
    }
}

#[test]
fn the_adapter_refuses_every_registration_as_unsupported() {
    let policies = [
        None,
        Some(ReparsePolicy::Incremental),
        Some(ReparsePolicy::Whole),
    ];
    // A grammar not compiled in, then one that is.
    let sources: Vec<GrammarSource> = ["tree_sitter_python", "tree_sitter_rust"]
        .into_iter()
        .flat_map(|symbol| policies.map(|policy| source(symbol, policy)))
        .collect();

    assert_eq!(check_unsupported(&TreeSitter, &sources), [""; 0]);
}
