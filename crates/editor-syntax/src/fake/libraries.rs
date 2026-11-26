//! The fake with a table: [`Libraries`], the port's fake that "loads"
//! grammars at run time from an in-memory table of libraries, keyed by
//! path, so registration ([`Syntax::register`]) is tested with no file.
//!
//! Its compiled-in grammar is `parens` ([`super::Parens`]'s). A library in
//! the table is no library ([`FakeLibrary::NotALibrary`]) or exports
//! symbols ([`FakeLibrary::Exports`]), each a grammar of the fake's shape
//! with other [`Delimiters`] ([`FakeExport::Grammar`]) or one of an ABI the
//! fake does not speak ([`FakeExport::OtherAbi`]). A registration is
//! refused as the table says:
//!
//! - a path not in the table: [`RegistrationRefusal::NotFound`];
//! - a file that is no library: [`RegistrationRefusal::NotLoadable`];
//! - a symbol the library does not export:
//!   [`RegistrationRefusal::MissingSymbol`];
//! - a grammar of another ABI: [`RegistrationRefusal::UnsupportedAbi`].
//!
//! A grammar it exports is handed to the core's [`Registry`], which decides
//! everything else ([`crate::registry`]): the name, the policy, the
//! override of `parens`, provenance, the listing. Nothing touches the disk:
//! the paths are only keys.
//!
//! [`table`] and [`corpus`] are what [`crate::contract::registration`]
//! holds it to.

use std::collections::BTreeMap;
use std::ops::Range;
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard, PoisonError};

use editor_text::{InputEdit, Snapshot};

use super::{
    Delimiters, GRAMMAR, PARENS, Parens, ParensQuery, ParensTree, compile, parse_ranges,
    parse_whole,
};
use crate::contract::registration::RegistrationCorpus;
use crate::port::{
    Capture, GrammarName, GrammarSource, Match, Node, QueryError, QueryErrorKind, QueryKind,
    RegistrationRefusal, ReparsePolicy, Setting, Syntax,
};
use crate::registry::Registry;

/// A file at a path of the fake's table.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FakeLibrary {
    /// A file that is not a library this platform can open.
    NotALibrary,
    /// A library, and the symbols it exports.
    Exports(BTreeMap<String, FakeExport>),
}

/// What a symbol of a fake library hands out.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FakeExport {
    /// A grammar of the fake's shape, with these delimiters.
    Grammar(Delimiters),
    /// A grammar of an ABI the fake does not speak.
    OtherAbi,
}

/// The fake with a table of libraries it registers grammars from.
pub struct Libraries {
    /// The libraries, by path.
    table: BTreeMap<PathBuf, FakeLibrary>,
    /// The grammars registered.
    registry: Mutex<Registry<Delimiters>>,
}

impl Clone for Libraries {
    fn clone(&self) -> Self {
        Self {
            table: self.table.clone(),
            registry: Mutex::new(self.registry().clone()),
        }
    }
}

/// The fake with a table's parser: the delimiters of the grammar it was
/// opened for, kept for good, so a registration afterwards does not change
/// what it parses.
#[derive(Debug, Clone, Copy)]
pub struct LibrariesParser(Delimiters);

impl Libraries {
    /// The fake over `table`, with no grammar registered.
    pub fn new(table: BTreeMap<PathBuf, FakeLibrary>) -> Self {
        Self {
            table,
            registry: Mutex::new(Registry::new()),
        }
    }

    /// The registry, locked. It is never left half-changed, so a poisoned
    /// lock is used as it is.
    fn registry(&self) -> MutexGuard<'_, Registry<Delimiters>> {
        self.registry.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The delimiters of `grammar`: the registered entry's, else
    /// `parens`'s for the compiled-in name; `None` for a grammar it lacks.
    fn delimiters(&self, grammar: &GrammarName) -> Option<Delimiters> {
        match self.registry().get(grammar) {
            Some(entry) => Some(entry.grammar),
            None => (grammar.as_str() == GRAMMAR).then_some(PARENS),
        }
    }

    /// The grammar `source` names in the table, or why not.
    fn load(&self, source: &GrammarSource) -> Result<Delimiters, RegistrationRefusal> {
        match self.table.get(&source.library) {
            None => Err(RegistrationRefusal::NotFound),
            Some(FakeLibrary::NotALibrary) => Err(RegistrationRefusal::NotLoadable),
            Some(FakeLibrary::Exports(symbols)) => match symbols.get(&source.symbol) {
                None => Err(RegistrationRefusal::MissingSymbol),
                Some(FakeExport::OtherAbi) => Err(RegistrationRefusal::UnsupportedAbi),
                Some(FakeExport::Grammar(delimiters)) => Ok(*delimiters),
            },
        }
    }
}

impl Syntax for Libraries {
    type Parser = LibrariesParser;
    type Tree = ParensTree;
    type Query = ParensQuery;

    fn grammars(&self) -> Vec<GrammarName> {
        self.registry().grammars(Parens.grammars())
    }

    fn parser(&self, grammar: &GrammarName) -> Option<LibrariesParser> {
        self.delimiters(grammar).map(LibrariesParser)
    }

    fn reparse_policy(&self, grammar: &GrammarName) -> Option<ReparsePolicy> {
        match self.registry().get(grammar) {
            Some(entry) => Some(entry.policy),
            None => Parens.reparse_policy(grammar),
        }
    }

    fn register(&self, source: &GrammarSource) -> Result<GrammarName, RegistrationRefusal> {
        // The load reads only the table, so it runs under the lock.
        self.registry().register(source, |source| self.load(source))
    }

    fn parse(
        &self,
        parser: &mut LibrariesParser,
        text: &Snapshot,
        _: Option<&ParensTree>,
    ) -> ParensTree {
        parse_whole(text, parser.0)
    }

    fn edit(&self, tree: &mut ParensTree, edit: &InputEdit) {
        Parens.edit(tree, edit);
    }

    fn compile(&self, grammar: &GrammarName, source: &str) -> Result<ParensQuery, QueryError> {
        let Some(delimiters) = self.delimiters(grammar) else {
            return Err(QueryError {
                kind: QueryErrorKind::Language,
                offset: 0,
            });
        };
        compile(source, delimiters)
    }

    fn shipped_query(&self, grammar: &GrammarName, kind: QueryKind) -> Option<String> {
        // A registered grammar ships no query, a compiled-in name it
        // replaces included.
        if self.registry().get(grammar).is_some() {
            return None;
        }
        Parens.shipped_query(grammar, kind)
    }

    fn capture_names(&self, query: &ParensQuery) -> Vec<String> {
        Parens.capture_names(query)
    }

    fn captures(
        &self,
        query: &ParensQuery,
        tree: &ParensTree,
        text: &Snapshot,
        range: Range<usize>,
    ) -> Vec<Capture> {
        Parens.captures(query, tree, text, range)
    }

    fn matches(
        &self,
        query: &ParensQuery,
        tree: &ParensTree,
        text: &Snapshot,
        range: Range<usize>,
    ) -> Vec<Match> {
        Parens.matches(query, tree, text, range)
    }

    fn pattern_settings(&self, query: &ParensQuery, pattern: usize) -> Vec<Setting> {
        Parens.pattern_settings(query, pattern)
    }

    fn parse_in(
        &self,
        parser: &mut LibrariesParser,
        text: &Snapshot,
        ranges: &[Range<usize>],
    ) -> ParensTree {
        parse_ranges(text, ranges, parser.0)
    }

    fn nodes(&self, tree: &ParensTree) -> Vec<Node> {
        Parens.nodes(tree)
    }

    fn has_errors(&self, tree: &ParensTree) -> bool {
        Parens.has_errors(tree)
    }
}

/// The library of the table that holds grammars.
pub const GRAMMARS_LIBRARY: &str = "/fake/grammars.so";

/// The file of the table that is no library.
pub const NOT_A_LIBRARY: &str = "/fake/not-a-library.txt";

/// The fake's table: [`GRAMMARS_LIBRARY`] exports `tree_sitter_brackets`
/// (lists in `[` and `]`), `tree_sitter_parens` (lists in `{` and `}`,
/// which overrides the compiled-in `parens`) and `tree_sitter_future` (a
/// grammar of another ABI); [`NOT_A_LIBRARY`] is no library.
pub fn table() -> BTreeMap<PathBuf, FakeLibrary> {
    let exports = BTreeMap::from([
        (
            "tree_sitter_brackets".to_owned(),
            FakeExport::Grammar(Delimiters {
                open: '[',
                close: ']',
            }),
        ),
        (
            "tree_sitter_parens".to_owned(),
            FakeExport::Grammar(Delimiters {
                open: '{',
                close: '}',
            }),
        ),
        ("tree_sitter_future".to_owned(), FakeExport::OtherAbi),
    ]);
    BTreeMap::from([
        (
            PathBuf::from(GRAMMARS_LIBRARY),
            FakeLibrary::Exports(exports),
        ),
        (PathBuf::from(NOT_A_LIBRARY), FakeLibrary::NotALibrary),
    ])
}

/// A source of `symbol` in `library`, declaring no policy.
fn source(library: &str, symbol: &str) -> GrammarSource {
    GrammarSource {
        library: PathBuf::from(library),
        symbol: symbol.to_owned(),
        policy: None,
    }
}

/// What [`crate::contract::registration::check`] holds [`Libraries`] over
/// [`table`] to. `override_text`, `{a} (b)`, is a list and an atom to the
/// registered `parens` and an atom and a list to the compiled-in one.
pub fn corpus() -> RegistrationCorpus {
    RegistrationCorpus {
        new: source(GRAMMARS_LIBRARY, "tree_sitter_brackets"),
        overriding: source(GRAMMARS_LIBRARY, "tree_sitter_parens"),
        override_text: "{a} (b)".to_owned(),
        not_found: source("/fake/missing.so", "tree_sitter_brackets"),
        not_loadable: source(NOT_A_LIBRARY, "tree_sitter_brackets"),
        unsupported_abi: source(GRAMMARS_LIBRARY, "tree_sitter_future"),
        missing_symbol: source(GRAMMARS_LIBRARY, "tree_sitter_absent"),
    }
}

#[cfg(test)]
mod tests {
    use editor_text::Text;

    use super::*;
    use crate::contract;
    use crate::fake::PARENS_CORPUS;

    #[test]
    fn the_fake_with_a_table_keeps_the_syntax_contract_for_parens() {
        assert_eq!(
            contract::check(&Libraries::new(table()), &PARENS_CORPUS),
            [""; 0]
        );
    }

    #[test]
    fn a_registered_brackets_grammar_parses_brackets_as_lists() {
        let syntax = Libraries::new(table());
        let brackets = syntax.register(&corpus().new).unwrap();
        let snapshot = Text::from("[a] (b)").snapshot();
        let mut parser = syntax.parser(&brackets).unwrap();

        let shape: Vec<_> = syntax
            .nodes(&syntax.parse(&mut parser, &snapshot, None))
            .into_iter()
            .map(|node| (node.kind, node.start..node.end))
            .collect();

        assert_eq!(brackets, GrammarName::new("brackets"));
        assert_eq!(
            shape,
            [
                ("document".to_owned(), 0..7),
                ("list".to_owned(), 0..3),
                ("[".to_owned(), 0..1),
                ("atom".to_owned(), 1..2),
                ("]".to_owned(), 2..3),
                ("atom".to_owned(), 4..7),
            ]
        );
    }
}
