//! The tree-sitter adapter keeps the registration contract on the fixture
//! grammar library (`editor-syntax-fixture-ini`): it loads a native grammar
//! from a library path and a symbol, and refuses, as values, a library that
//! is not there, a file that is no library, a symbol the library does not
//! export and a grammar of an ABI the pinned library does not speak (the
//! crate docs, "How grammars are loaded").
//!
//! The check is `editor-syntax`'s, the one the fake with its table keeps
//! (`editor_syntax::contract::registration::check`). No file is created:
//! the sources name the built fixture library, a file of the fixture's
//! that is no library, and a path beside the library that is never made.

use std::path::{Path, PathBuf};

use editor_syntax::contract::registration::{RegistrationCorpus, check};
use editor_syntax::{GrammarName, GrammarSource, ReparsePolicy, Syntax};
use editor_syntax_fixture_ini as fixture;
use editor_syntax_treesitter::TreeSitter;
use editor_text::Text;

/// A source of `symbol` in `library`, declaring no policy.
fn source(library: impl Into<PathBuf>, symbol: &str) -> GrammarSource {
    GrammarSource {
        library: library.into(),
        symbol: symbol.to_owned(),
        policy: None,
    }
}

/// A path beside the fixture library, of its kind, that is never made.
fn absent_library() -> PathBuf {
    let library = Path::new(fixture::LIBRARY);
    let extension = library
        .extension()
        .and_then(|extension| extension.to_str())
        .unwrap_or("so");
    library.with_file_name(format!("libtree-sitter-absent.{extension}"))
}

/// The registration corpus over the fixture library.
fn corpus() -> RegistrationCorpus {
    RegistrationCorpus {
        new: source(fixture::LIBRARY, fixture::SYMBOL),
        overriding: source(fixture::LIBRARY, fixture::OVERRIDING_SYMBOL),
        // The compiled-in `json` parses it with errors, the fixture to a
        // section with a pair.
        override_text: "[a]\nk = v\n".to_owned(),
        not_found: source(absent_library(), fixture::SYMBOL),
        not_loadable: source(fixture::NOT_A_LIBRARY, fixture::SYMBOL),
        unsupported_abi: source(fixture::LIBRARY, fixture::ABI_0_SYMBOL),
        missing_symbol: source(fixture::LIBRARY, "tree_sitter_absent"),
    }
}

#[test]
fn the_adapter_keeps_the_registration_contract_on_the_fixture_library() {
    assert_eq!(check(TreeSitter::default, &corpus()), [""; 0]);
}

#[test]
fn the_fixture_grammar_is_not_compiled_in() {
    let name = source(fixture::LIBRARY, fixture::SYMBOL).name();

    assert_eq!(name, GrammarName::new(fixture::NAME));
    assert!(!TreeSitter::default().grammars().contains(&name));
}

#[test]
fn a_grammar_loaded_from_a_library_stays_usable_after_its_syntax_is_dropped() {
    let name = GrammarName::new(fixture::NAME);
    let mut parser = {
        let syntax = TreeSitter::default();
        let source = GrammarSource {
            policy: Some(ReparsePolicy::Incremental),
            ..source(fixture::LIBRARY, fixture::SYMBOL)
        };
        assert_eq!(syntax.register(&source), Ok(name.clone()));
        syntax
            .parser(&name)
            .expect("the registered grammar opens a parser")
    };

    // The library is never unloaded: the parser still points into its code.
    let other = TreeSitter::default();
    let snapshot = Text::from("[s]\nk = v\n").snapshot();
    let tree = other.parse(&mut parser, &snapshot, None);
    let kinds: Vec<String> = other
        .nodes(&tree)
        .into_iter()
        .filter(|node| node.named)
        .map(|node| node.kind)
        .collect();
    assert_eq!(
        kinds,
        [
            "document",
            "section",
            "section_name",
            "pair",
            "key",
            "value"
        ]
    );
}
