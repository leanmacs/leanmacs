//! The grammars registered at run time: the core's decisions about a
//! registration ([`crate::Syntax::register`]), which an adapter holds and
//! supplies only the load step to.
//!
//! An adapter keeps a [`Registry`] of its own grammar type behind a lock
//! (its `register` takes `&self`), and hands [`Registry::register`] the
//! step that turns a [`GrammarSource`] into its grammar, or a refusal: the
//! fake's table lookup ([`crate::fake::Libraries`]), and a real library's
//! `dlopen` once it loads one. Everything else is decided here:
//!
//! - **The name** is the source's ([`GrammarSource::name`]): its symbol
//!   without the `tree_sitter_` prefix.
//! - **The policy** is the one the source declares, and
//!   [`ReparsePolicy::Whole`] when it declares none: a grammar loaded at
//!   run time has not been swept for
//!   [`crate::contract::GRAMMAR_QUALITY`].
//! - **A later registration of a name replaces the earlier one**, and a
//!   registered entry wins over a compiled-in grammar of the same name, for
//!   parsers opened afterwards. A parser opened before keeps the grammar it
//!   was opened with: it is the adapter's value, not a reference into this.
//! - **A refusal leaves everything as it was.**
//! - **The listing** ([`Registry::grammars`]) is the compiled-in names in
//!   their order, then each registered name that is not compiled in, in the
//!   order it was first registered, each name once.
//! - **Provenance.** Each entry keeps its source, so the queries declared
//!   beside a grammar's library can be found from it.
//! - **A registered grammar ships no query.** Queries for it are read in
//!   Lean, from beside its library, and handed in as a mode's override, so
//!   an adapter answers `shipped_query` with `None` for every registered
//!   name, a compiled-in name it overrides included. This module keeps no
//!   query, so it cannot answer one.
//!
//! The rules are pinned by this module's tests and mirrored in Lean's pure
//! model (`lean/Editor/SyntaxTree/Registration/Model.lean`).

use crate::port::{GrammarName, GrammarSource, RegistrationRefusal, ReparsePolicy};

/// A grammar registered: the adapter's grammar, the policy it was
/// registered with, and the source it came from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Registered<G> {
    /// The adapter's grammar.
    pub grammar: G,
    /// How its texts are reparsed.
    pub policy: ReparsePolicy,
    /// Where it came from.
    pub source: GrammarSource,
}

/// The grammars registered, by name, in the order each name was first
/// registered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Registry<G> {
    /// Each name with its entry, in the order the name was first
    /// registered.
    entries: Vec<(GrammarName, Registered<G>)>,
}

impl<G> Default for Registry<G> {
    fn default() -> Self {
        Self::new()
    }
}

impl<G> Registry<G> {
    /// A registry that holds no grammar.
    pub const fn new() -> Self {
        Self {
            entries: Vec::new(),
        }
    }

    /// Registers the grammar `load` makes of `source` under the source's
    /// name, with the source's policy or [`ReparsePolicy::Whole`], in place
    /// of any grammar of that name before; or answers `load`'s refusal and
    /// changes nothing.
    pub fn register(
        &mut self,
        source: &GrammarSource,
        load: impl FnOnce(&GrammarSource) -> Result<G, RegistrationRefusal>,
    ) -> Result<GrammarName, RegistrationRefusal> {
        let grammar = load(source)?;
        let name = source.name();
        let entry = Registered {
            grammar,
            policy: source.policy.unwrap_or(ReparsePolicy::Whole),
            source: source.clone(),
        };
        match self.entries.iter_mut().find(|(known, _)| *known == name) {
            Some((_, held)) => *held = entry,
            None => self.entries.push((name.clone(), entry)),
        }
        Ok(name)
    }

    /// The grammar registered under `name`, if one is.
    pub fn get(&self, name: &GrammarName) -> Option<&Registered<G>> {
        self.entries
            .iter()
            .find(|(known, _)| known == name)
            .map(|(_, entry)| entry)
    }

    /// The grammars to list: the `compiled` names in their order, then each
    /// registered name that is not among them, in the order it was first
    /// registered; each name once.
    pub fn grammars(&self, compiled: impl IntoIterator<Item = GrammarName>) -> Vec<GrammarName> {
        let mut names: Vec<GrammarName> = Vec::new();
        for name in compiled
            .into_iter()
            .chain(self.entries.iter().map(|(name, _)| name.clone()))
        {
            if !names.contains(&name) {
                names.push(name);
            }
        }
        names
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;

    /// A source of `symbol` in `library`, declaring `policy`.
    fn source(library: &str, symbol: &str, policy: Option<ReparsePolicy>) -> GrammarSource {
        GrammarSource {
            library: PathBuf::from(library),
            symbol: symbol.to_owned(),
            policy,
        }
    }

    /// A load that hands out `grammar`.
    fn loads(
        grammar: &'static str,
    ) -> impl FnOnce(&GrammarSource) -> Result<&'static str, RegistrationRefusal> {
        move |_| Ok(grammar)
    }

    /// The names `names`.
    fn names(names: &[&str]) -> Vec<GrammarName> {
        names.iter().map(|name| GrammarName::new(*name)).collect()
    }

    /// The compiled-in names the tests list beside the registry's.
    fn compiled() -> Vec<GrammarName> {
        names(&["json", "rust"])
    }

    #[test]
    fn a_registration_that_loads_answers_the_sources_name_and_is_listed_after_the_compiled_in_names()
     {
        let mut registry = Registry::new();

        let answered = registry.register(
            &source("/a.so", "tree_sitter_python", None),
            loads("python"),
        );

        assert_eq!(answered, Ok(GrammarName::new("python")));
        assert_eq!(
            registry.grammars(compiled()),
            names(&["json", "rust", "python"])
        );
        assert_eq!(
            registry
                .get(&GrammarName::new("python"))
                .map(|entry| entry.grammar),
            Some("python")
        );
    }

    #[test]
    fn a_registered_grammar_records_the_source_it_came_from() {
        let mut registry = Registry::new();
        let python = source("/lib/python.so", "tree_sitter_python", None);

        registry.register(&python, loads("python")).unwrap();

        assert_eq!(
            registry
                .get(&GrammarName::new("python"))
                .map(|entry| &entry.source),
            Some(&python)
        );
    }

    #[test]
    fn a_source_that_declares_no_policy_is_registered_whole_and_a_declared_policy_is_kept() {
        let mut registry = Registry::new();
        registry
            .register(&source("/a.so", "tree_sitter_a", None), loads("a"))
            .unwrap();
        registry
            .register(
                &source("/b.so", "tree_sitter_b", Some(ReparsePolicy::Incremental)),
                loads("b"),
            )
            .unwrap();
        registry
            .register(
                &source("/c.so", "tree_sitter_c", Some(ReparsePolicy::Whole)),
                loads("c"),
            )
            .unwrap();

        let policy = |name: &str| {
            registry
                .get(&GrammarName::new(name))
                .map(|entry| entry.policy)
        };
        assert_eq!(policy("a"), Some(ReparsePolicy::Whole));
        assert_eq!(policy("b"), Some(ReparsePolicy::Incremental));
        assert_eq!(policy("c"), Some(ReparsePolicy::Whole));
    }

    #[test]
    fn a_second_registration_of_a_name_replaces_the_first_and_lists_it_once() {
        let mut registry = Registry::new();
        registry
            .register(&source("/a.so", "tree_sitter_a", None), loads("first a"))
            .unwrap();
        registry
            .register(&source("/b.so", "tree_sitter_b", None), loads("b"))
            .unwrap();
        let again = source(
            "/other.so",
            "tree_sitter_a",
            Some(ReparsePolicy::Incremental),
        );

        assert_eq!(
            registry.register(&again, loads("second a")),
            Ok(GrammarName::new("a"))
        );

        assert_eq!(
            registry.grammars(compiled()),
            names(&["json", "rust", "a", "b"])
        );
        let entry = registry.get(&GrammarName::new("a")).unwrap();
        assert_eq!(entry.grammar, "second a");
        assert_eq!(entry.source, again);
        assert_eq!(entry.policy, ReparsePolicy::Incremental);
    }

    #[test]
    fn a_registered_name_that_is_compiled_in_is_listed_once_in_the_compiled_order() {
        let mut registry = Registry::new();
        registry
            .register(&source("/x.so", "tree_sitter_x", None), loads("x"))
            .unwrap();
        registry
            .register(&source("/json.so", "tree_sitter_json", None), loads("json"))
            .unwrap();

        assert_eq!(registry.grammars(compiled()), names(&["json", "rust", "x"]));
        assert!(registry.get(&GrammarName::new("json")).is_some());
    }

    #[test]
    fn a_refused_load_answers_its_refusal_and_leaves_the_registry_unchanged() {
        let mut registry = Registry::new();
        let python = source("/a.so", "tree_sitter_python", None);
        registry.register(&python, loads("python")).unwrap();
        let before = registry.clone();

        let refused = registry.register(
            &source(
                "/b.so",
                "tree_sitter_python",
                Some(ReparsePolicy::Incremental),
            ),
            |_| Err(RegistrationRefusal::MissingSymbol),
        );
        let refused_new = registry.register(&source("/c.so", "tree_sitter_go", None), |_| {
            Err(RegistrationRefusal::NotFound)
        });

        assert_eq!(refused, Err(RegistrationRefusal::MissingSymbol));
        assert_eq!(refused_new, Err(RegistrationRefusal::NotFound));
        assert_eq!(registry, before);
        assert_eq!(
            registry.grammars(compiled()),
            names(&["json", "rust", "python"])
        );
    }
}
