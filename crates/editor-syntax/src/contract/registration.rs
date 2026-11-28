//! The registration contract: the rules every [`Syntax`] that registers
//! grammars at run time keeps ([`Syntax::register`]), as a check of its own,
//! separate from [`super::check`].
//!
//! [`check`] registers the sources of a [`RegistrationCorpus`] (a grammar
//! not listed, one whose name is already listed, compiled in or registered
//! before from the corpus's `before`, and one source for each refusal),
//! each property on a fresh syntax so no property sees another's
//! registrations, and returns the names of the properties that fail. [`check_unsupported`] is the check of an adapter that loads no
//! grammar at run time: every source is refused as
//! [`RegistrationRefusal::Unsupported`], and nothing it lists changes.
//!
//! [`check`] is held against the fake with a table
//! ([`crate::fake::Libraries`], over [`crate::fake::libraries::corpus`]), in
//! this module's tests, and against the real adapter on its fixture grammar
//! library (`crates/editor-syntax-treesitter/tests/registration.rs`, over
//! `editor-syntax-fixture-ini`), which compiles in no grammar, so its corpus
//! registers the name it overrides first, from the `json` of
//! `editor-syntax-fixture-grammars`. [`check_unsupported`] is held against
//! [`crate::fake::Parens`], the fake with no table.
//!
//! Each property is seen to bite on a broken registering syntax written to
//! break it, in this module's tests.

use editor_text::Text;

use crate::port::{
    GrammarName, GrammarSource, QueryKind, RegistrationRefusal, ReparsePolicy, Syntax,
};

/// What the registration contract registers: owned sources, since a real
/// adapter's fixture paths are known only at run time.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RegistrationCorpus {
    /// A source of a grammar that is not listed, which loads.
    pub new: GrammarSource,
    /// A source of `overriding`'s name, registered on the fresh syntax
    /// before [`OVERRIDES`] registers `overriding`: `None` where that name
    /// is compiled in (the fake's `parens`), `Some` for a syntax that
    /// compiles in no grammar (the real adapter). Its policy, else whole,
    /// is not `overriding`'s.
    pub before: Option<GrammarSource>,
    /// A source of a grammar whose name is listed, compiled in or
    /// registered from `before`, which loads. Where the name is compiled
    /// in, the compiled-in grammar ships a query; either way, the listed
    /// grammar's policy is not the one this source gives (its declared
    /// policy, else whole), so [`OVERRIDES`] tells the newly registered
    /// grammar's queries and policy from the listed one's.
    pub overriding: GrammarSource,
    /// A text the listed grammar of `overriding`'s name and the one
    /// `overriding` loads parse to different trees.
    pub override_text: String,
    /// A source whose library is not there.
    pub not_found: GrammarSource,
    /// A source whose file is no library this platform can open.
    pub not_loadable: GrammarSource,
    /// A source whose grammar is of an ABI the parsing library does not
    /// speak.
    pub unsupported_abi: GrammarSource,
    /// A source whose library does not export its symbol.
    pub missing_symbol: GrammarSource,
}

impl RegistrationCorpus {
    /// Its six sources, in the order of its fields.
    pub fn sources(&self) -> [GrammarSource; 6] {
        [
            self.new.clone(),
            self.overriding.clone(),
            self.not_found.clone(),
            self.not_loadable.clone(),
            self.unsupported_abi.clone(),
            self.missing_symbol.clone(),
        ]
    }
}

/// A registration answers its source's name, which was not listed before;
/// once registered, the name is listed beside every grammar listed before,
/// opens a parser, and ships no query of any kind.
pub const REGISTERS: &str = "a registration answers its source's name, which is then listed beside every grammar listed before, opens a parser and ships no query";
/// The overriding source's name is listed, compiled in or registered
/// before from the corpus's `before`, with a policy other than the
/// source's, and, compiled in, ships a query; registering it leaves the
/// list as it was, with the name once; a parser opened afterwards parses
/// the corpus's text to another tree than the listed grammar, and a parser
/// opened before still parses it as the listed grammar does; the name then
/// ships no query of any kind, and its policy is the source's (its
/// declared policy, else whole), not the listed one.
pub const OVERRIDES: &str = "registering a name already listed (compiled in, or registered before) lists it once, a parser opened afterwards parses with the newly registered grammar, one opened before keeps the grammar it was opened with, and the name ships no query and takes the source's policy";
/// A registered grammar whose source declares no policy is reparsed whole,
/// and the same source declaring incremental is reparsed incrementally.
pub const DEFAULT_POLICY: &str = "a registered grammar with no declared policy is reparsed whole, and one declared incremental incrementally";
/// The source whose library is not there is refused as not found, and
/// the grammars listed are as before.
pub const NOT_FOUND: &str =
    "a library that is not there is refused as not found, and the grammars listed are unchanged";
/// The source whose file is no library is refused as not loadable, and the
/// grammars listed are as before.
pub const NOT_LOADABLE: &str =
    "a file that is no library is refused as not loadable, and the grammars listed are unchanged";
/// The source of a grammar of another ABI is refused as an unsupported
/// ABI, and the grammars listed are as before.
pub const UNSUPPORTED_ABI: &str = "a grammar of another ABI is refused as an unsupported ABI, and the grammars listed are unchanged";
/// The source whose symbol the library lacks is refused as a missing
/// symbol, and the grammars listed are as before.
pub const MISSING_SYMBOL: &str = "a symbol the library does not export is refused as missing, and the grammars listed are unchanged";
/// Every source given is refused as unsupported, and the grammars listed,
/// whether each opens a parser and each one's policy are unchanged; at
/// least one source is given, so the property is never held by none.
pub const UNSUPPORTED: &str = "every registration is refused as unsupported, and the grammars listed, their parsers and their policies are unchanged";

/// The registration contract's properties.
pub const PROPERTIES: [&str; 8] = [
    REGISTERS,
    OVERRIDES,
    DEFAULT_POLICY,
    NOT_FOUND,
    NOT_LOADABLE,
    UNSUPPORTED_ABI,
    MISSING_SYMBOL,
    UNSUPPORTED,
];

/// The names of the properties, all but [`UNSUPPORTED`], that the syntaxes
/// `make` makes fail over `corpus`: each property is asked of a fresh one.
pub fn check<S: Syntax>(make: impl Fn() -> S, corpus: &RegistrationCorpus) -> Vec<&'static str> {
    let refusals = [
        (NOT_FOUND, &corpus.not_found, RegistrationRefusal::NotFound),
        (
            NOT_LOADABLE,
            &corpus.not_loadable,
            RegistrationRefusal::NotLoadable,
        ),
        (
            UNSUPPORTED_ABI,
            &corpus.unsupported_abi,
            RegistrationRefusal::UnsupportedAbi,
        ),
        (
            MISSING_SYMBOL,
            &corpus.missing_symbol,
            RegistrationRefusal::MissingSymbol,
        ),
    ];
    let mut failed = Vec::new();
    if !registers(&make(), &corpus.new) {
        failed.push(REGISTERS);
    }
    if !overrides(&make(), corpus) {
        failed.push(OVERRIDES);
    }
    if !default_policy(&make, &corpus.new) {
        failed.push(DEFAULT_POLICY);
    }
    for (name, source, refusal) in refusals {
        if !refused(&make(), source, refusal) {
            failed.push(name);
        }
    }
    failed
}

/// The names of the properties `syntax`, an adapter that loads no grammar
/// at run time, fails over `sources`: [`UNSUPPORTED`], or none.
pub fn check_unsupported<S: Syntax>(syntax: &S, sources: &[GrammarSource]) -> Vec<&'static str> {
    let held = !sources.is_empty()
        && sources.iter().all(|source| {
            let before = readout(syntax);
            syntax.register(source) == Err(RegistrationRefusal::Unsupported)
                && readout(syntax) == before
        });
    if held { Vec::new() } else { vec![UNSUPPORTED] }
}

/// Each grammar `syntax` lists, with whether it opens a parser and its
/// policy.
fn readout<S: Syntax>(syntax: &S) -> Vec<(GrammarName, bool, Option<ReparsePolicy>)> {
    syntax
        .grammars()
        .into_iter()
        .map(|grammar| {
            let opens = syntax.parser(&grammar).is_some();
            let policy = syntax.reparse_policy(&grammar);
            (grammar, opens, policy)
        })
        .collect()
}

/// [`REGISTERS`], of `source`.
fn registers<S: Syntax>(syntax: &S, source: &GrammarSource) -> bool {
    let name = source.name();
    let before = syntax.grammars();
    if before.contains(&name) || syntax.register(source) != Ok(name.clone()) {
        return false;
    }
    let after = syntax.grammars();
    after.contains(&name)
        && before.iter().all(|grammar| after.contains(grammar))
        && syntax.parser(&name).is_some()
        && QueryKind::ALL
            .iter()
            .all(|kind| syntax.shipped_query(&name, *kind).is_none())
}

/// The nodes of `text` as `parser` parses it whole.
fn nodes_of<S: Syntax>(syntax: &S, parser: &mut S::Parser, text: &str) -> Vec<crate::port::Node> {
    let snapshot = Text::from(text).snapshot();
    syntax.nodes(&syntax.parse(parser, &snapshot, None))
}

/// Whether `syntax` ships a query of any kind for `name`.
fn ships_any<S: Syntax>(syntax: &S, name: &GrammarName) -> bool {
    QueryKind::ALL
        .iter()
        .any(|kind| syntax.shipped_query(name, *kind).is_some())
}

/// [`OVERRIDES`], of the corpus's source registered before, if any, and
/// its overriding source and text.
fn overrides<S: Syntax>(syntax: &S, corpus: &RegistrationCorpus) -> bool {
    let name = corpus.overriding.name();
    let policy = corpus.overriding.policy.unwrap_or(ReparsePolicy::Whole);
    if let Some(first) = &corpus.before
        && (first.name() != name || syntax.register(first) != Ok(name.clone()))
    {
        return false;
    }
    let before = syntax.grammars();
    let Some(mut opened_before) = syntax.parser(&name) else {
        return false;
    };
    if !before.contains(&name)
        || (corpus.before.is_none() && !ships_any(syntax, &name))
        || syntax.reparse_policy(&name) == Some(policy)
    {
        return false;
    }
    let listed = nodes_of(syntax, &mut opened_before, &corpus.override_text);
    if syntax.register(&corpus.overriding) != Ok(name.clone()) || syntax.grammars() != before {
        return false;
    }
    let Some(mut opened_after) = syntax.parser(&name) else {
        return false;
    };
    nodes_of(syntax, &mut opened_after, &corpus.override_text) != listed
        && nodes_of(syntax, &mut opened_before, &corpus.override_text) == listed
        && !ships_any(syntax, &name)
        && syntax.reparse_policy(&name) == Some(policy)
}

/// [`DEFAULT_POLICY`], of `source` declaring no policy and then declaring
/// incremental, each on a fresh syntax.
fn default_policy<S: Syntax>(make: &impl Fn() -> S, source: &GrammarSource) -> bool {
    let policy_of = |policy| {
        let syntax = make();
        let source = GrammarSource {
            policy,
            ..source.clone()
        };
        let name = syntax.register(&source).ok()?;
        syntax.reparse_policy(&name)
    };
    policy_of(None) == Some(ReparsePolicy::Whole)
        && policy_of(Some(ReparsePolicy::Incremental)) == Some(ReparsePolicy::Incremental)
}

/// A refusal property: `source` is refused with `refusal`, and the grammars
/// listed are as before.
fn refused<S: Syntax>(syntax: &S, source: &GrammarSource, refusal: RegistrationRefusal) -> bool {
    let before = syntax.grammars();
    syntax.register(source) == Err(refusal) && syntax.grammars() == before
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;
    use std::ops::Range;
    use std::sync::{Mutex, PoisonError};

    use editor_text::{InputEdit, Snapshot};

    use super::*;
    use crate::fake::libraries::{self, Libraries, LibrariesParser};
    use crate::fake::{PARENS_HIGHLIGHTS, Parens, ParensQuery, ParensTree};
    use crate::port::{Capture, Match, Node, QueryError, QueryKind, Setting};

    #[test]
    fn the_properties_are_eight_and_each_is_named_once() {
        let mut names = PROPERTIES.to_vec();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), 8);
    }

    #[test]
    fn the_fake_with_its_table_keeps_the_registration_contract() {
        assert_eq!(
            check(|| Libraries::new(libraries::table()), &libraries::corpus()),
            [""; 0]
        );
    }

    #[test]
    fn the_fake_with_no_table_refuses_every_registration_as_unsupported() {
        assert_eq!(
            check_unsupported(&Parens, &libraries::corpus().sources()),
            [""; 0]
        );
    }

    /// One rule a broken registering syntax breaks; everything else it
    /// answers as the fake with its table does.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum Flaw {
        /// A registered name that is not compiled in is not listed.
        Unlisted,
        /// A listed name opens the grammar it was first listed with, here
        /// the compiled-in one, registered over or not.
        ListedWins,
        /// A name registered a second time keeps its first registration.
        FirstRegistrationWins,
        /// A parser reads which grammar its name has when it parses, not
        /// when it was opened.
        OpenParsersChange,
        /// A registered grammar not compiled in whose source declares no
        /// policy is incremental.
        IncrementalByDefault,
        /// A registered grammar is whole, whatever its source declares.
        AlwaysWhole,
        /// A registered grammar not compiled in ships the fake's
        /// highlights.
        ShipsForRegistered,
        /// A compiled-in name ships its compiled-in queries, registered or
        /// not.
        ShipsAfterOverride,
        /// A compiled-in name keeps its compiled-in policy, registered or
        /// not.
        CompiledPolicyAfterOverride,
        /// A library that is not there is refused as not loadable.
        NotLoadableForMissing,
        /// A file that is no library is refused as not found.
        NotFoundForNoLibrary,
        /// A grammar of another ABI is refused as a missing symbol.
        MissingSymbolForOtherAbi,
        /// A source refused as a missing symbol is listed all the same.
        ListsRefused,
        /// Every source is refused as unsupported, and listed all the same.
        UnsupportedButLists,
    }

    /// The fake with its table and one flaw.
    struct BrokenRegistering {
        flaw: Flaw,
        libraries: Libraries,
        /// The sources registered, by name: the last of each.
        registered: Mutex<Vec<GrammarSource>>,
        /// Names listed though their registration was refused.
        listed_anyway: Mutex<BTreeSet<GrammarName>>,
    }

    /// The broken syntax's parser: the name it was opened for, and the
    /// fake's parser then.
    struct BrokenParser {
        name: GrammarName,
        opened: LibrariesParser,
    }

    impl BrokenRegistering {
        fn new(flaw: Flaw) -> Self {
            Self {
                flaw,
                libraries: Libraries::new(libraries::table()),
                registered: Mutex::new(Vec::new()),
                listed_anyway: Mutex::new(BTreeSet::new()),
            }
        }

        /// The source `name` was last registered from, if it was.
        fn source_of(&self, name: &GrammarName) -> Option<GrammarSource> {
            self.registered
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .iter()
                .rev()
                .find(|source| source.name() == *name)
                .cloned()
        }

        /// Lists `name` though its registration was refused.
        fn list_anyway(&self, name: GrammarName) {
            self.listed_anyway
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .insert(name);
        }
    }

    impl Syntax for BrokenRegistering {
        type Parser = BrokenParser;
        type Tree = ParensTree;
        type Query = ParensQuery;

        fn grammars(&self) -> Vec<GrammarName> {
            let mut names = self.libraries.grammars();
            if self.flaw == Flaw::Unlisted {
                let compiled = Parens.grammars();
                names.retain(|name| compiled.contains(name));
            }
            for name in self
                .listed_anyway
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .iter()
            {
                if !names.contains(name) {
                    names.push(name.clone());
                }
            }
            names
        }

        fn parser(&self, grammar: &GrammarName) -> Option<BrokenParser> {
            let opened = if self.flaw == Flaw::ListedWins && Parens.grammars().contains(grammar) {
                Libraries::new(libraries::table()).parser(grammar)
            } else {
                self.libraries.parser(grammar)
            }?;
            Some(BrokenParser {
                name: grammar.clone(),
                opened,
            })
        }

        fn reparse_policy(&self, grammar: &GrammarName) -> Option<ReparsePolicy> {
            let compiled = Parens.reparse_policy(grammar);
            let source = self.source_of(grammar);
            match (self.flaw, source) {
                (Flaw::CompiledPolicyAfterOverride, _) if compiled.is_some() => compiled,
                (Flaw::IncrementalByDefault, Some(source))
                    if source.policy.is_none() && compiled.is_none() =>
                {
                    Some(ReparsePolicy::Incremental)
                }
                (Flaw::AlwaysWhole, Some(_)) => Some(ReparsePolicy::Whole),
                _ => self.libraries.reparse_policy(grammar),
            }
        }

        fn register(&self, source: &GrammarSource) -> Result<GrammarName, RegistrationRefusal> {
            if self.flaw == Flaw::FirstRegistrationWins && self.source_of(&source.name()).is_some()
            {
                return Ok(source.name());
            }
            if self.flaw == Flaw::UnsupportedButLists {
                self.list_anyway(source.name());
                return Err(RegistrationRefusal::Unsupported);
            }
            let answer = self.libraries.register(source);
            match answer {
                Ok(_) => self
                    .registered
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .push(source.clone()),
                Err(RegistrationRefusal::MissingSymbol) if self.flaw == Flaw::ListsRefused => {
                    self.list_anyway(source.name());
                }
                Err(_) => {}
            }
            match (self.flaw, answer) {
                (Flaw::NotLoadableForMissing, Err(RegistrationRefusal::NotFound)) => {
                    Err(RegistrationRefusal::NotLoadable)
                }
                (Flaw::NotFoundForNoLibrary, Err(RegistrationRefusal::NotLoadable)) => {
                    Err(RegistrationRefusal::NotFound)
                }
                (Flaw::MissingSymbolForOtherAbi, Err(RegistrationRefusal::UnsupportedAbi)) => {
                    Err(RegistrationRefusal::MissingSymbol)
                }
                (_, answer) => answer,
            }
        }

        fn parse(
            &self,
            parser: &mut BrokenParser,
            text: &Snapshot,
            old: Option<&ParensTree>,
        ) -> ParensTree {
            if self.flaw == Flaw::OpenParsersChange
                && let Some(mut now) = self.libraries.parser(&parser.name)
            {
                return self.libraries.parse(&mut now, text, old);
            }
            self.libraries.parse(&mut parser.opened, text, old)
        }

        fn edit(&self, tree: &mut ParensTree, edit: &InputEdit) {
            self.libraries.edit(tree, edit);
        }

        fn compile(&self, grammar: &GrammarName, source: &str) -> Result<ParensQuery, QueryError> {
            self.libraries.compile(grammar, source)
        }

        fn shipped_query(&self, grammar: &GrammarName, kind: QueryKind) -> Option<String> {
            let compiled = Parens.grammars().contains(grammar);
            match self.flaw {
                Flaw::ShipsForRegistered if !compiled && self.source_of(grammar).is_some() => {
                    return (kind == QueryKind::Highlights).then(|| PARENS_HIGHLIGHTS.to_owned());
                }
                Flaw::ShipsAfterOverride if compiled => return Parens.shipped_query(grammar, kind),
                _ => {}
            }
            self.libraries.shipped_query(grammar, kind)
        }

        fn capture_names(&self, query: &ParensQuery) -> Vec<String> {
            self.libraries.capture_names(query)
        }

        fn captures(
            &self,
            query: &ParensQuery,
            tree: &ParensTree,
            text: &Snapshot,
            range: Range<usize>,
        ) -> Vec<Capture> {
            self.libraries.captures(query, tree, text, range)
        }

        fn matches(
            &self,
            query: &ParensQuery,
            tree: &ParensTree,
            text: &Snapshot,
            range: Range<usize>,
        ) -> Vec<Match> {
            self.libraries.matches(query, tree, text, range)
        }

        fn pattern_settings(&self, query: &ParensQuery, pattern: usize) -> Vec<Setting> {
            self.libraries.pattern_settings(query, pattern)
        }

        fn parse_in(
            &self,
            parser: &mut BrokenParser,
            text: &Snapshot,
            ranges: &[Range<usize>],
        ) -> ParensTree {
            self.libraries.parse_in(&mut parser.opened, text, ranges)
        }

        fn nodes(&self, tree: &ParensTree) -> Vec<Node> {
            self.libraries.nodes(tree)
        }

        fn has_errors(&self, tree: &ParensTree) -> bool {
            self.libraries.has_errors(tree)
        }
    }

    /// The registration properties `flaw` fails.
    fn failed(flaw: Flaw) -> Vec<&'static str> {
        check(|| BrokenRegistering::new(flaw), &libraries::corpus())
    }

    #[test]
    fn a_syntax_that_does_not_list_a_registered_grammar_is_reported() {
        assert_eq!(failed(Flaw::Unlisted), [REGISTERS]);
    }

    #[test]
    fn a_syntax_whose_compiled_in_grammar_wins_over_a_registered_one_is_reported() {
        assert_eq!(failed(Flaw::ListedWins), [OVERRIDES]);
    }

    /// The path of a second library of grammars, beside the fake's table,
    /// exporting another `parens`.
    const OTHER_LIBRARY: &str = "/fake/other.so";

    /// The fake's table, with [`OTHER_LIBRARY`] exporting a `parens` of
    /// angle brackets.
    fn table_with_other() -> std::collections::BTreeMap<std::path::PathBuf, libraries::FakeLibrary>
    {
        let mut table = libraries::table();
        table.insert(
            OTHER_LIBRARY.into(),
            libraries::FakeLibrary::Exports(std::collections::BTreeMap::from([(
                "tree_sitter_parens".to_owned(),
                libraries::FakeExport::Grammar(crate::fake::Delimiters {
                    open: '<',
                    close: '>',
                }),
            )])),
        );
        table
    }

    /// The fake's corpus, its overriding name registered before: the
    /// table's `parens` of braces, incremental, then [`OTHER_LIBRARY`]'s of
    /// angle brackets, declaring no policy, over a text the two parse to
    /// different trees.
    fn corpus_registered_before() -> RegistrationCorpus {
        RegistrationCorpus {
            before: Some(GrammarSource {
                library: libraries::GRAMMARS_LIBRARY.into(),
                symbol: "tree_sitter_parens".to_owned(),
                policy: Some(ReparsePolicy::Incremental),
            }),
            overriding: GrammarSource {
                library: OTHER_LIBRARY.into(),
                symbol: "tree_sitter_parens".to_owned(),
                policy: None,
            },
            override_text: "{a} <b>".to_owned(),
            ..libraries::corpus()
        }
    }

    #[test]
    fn the_fake_keeps_overrides_over_a_name_registered_before() {
        assert_eq!(
            check(
                || Libraries::new(table_with_other()),
                &corpus_registered_before()
            ),
            [""; 0]
        );
    }

    #[test]
    fn a_syntax_that_keeps_the_first_registration_of_a_name_registered_before_is_reported() {
        let failed = check(
            || BrokenRegistering {
                libraries: Libraries::new(table_with_other()),
                ..BrokenRegistering::new(Flaw::FirstRegistrationWins)
            },
            &corpus_registered_before(),
        );

        assert_eq!(failed, [OVERRIDES]);
    }

    #[test]
    fn a_syntax_whose_open_parsers_change_grammar_on_a_registration_is_reported() {
        assert_eq!(failed(Flaw::OpenParsersChange), [OVERRIDES]);
    }

    #[test]
    fn a_syntax_that_reparses_a_registered_grammar_incrementally_by_default_is_reported() {
        assert_eq!(failed(Flaw::IncrementalByDefault), [DEFAULT_POLICY]);
    }

    #[test]
    fn a_syntax_that_reparses_a_registered_grammar_whole_whatever_its_source_declares_is_reported()
    {
        assert_eq!(failed(Flaw::AlwaysWhole), [DEFAULT_POLICY]);
    }

    #[test]
    fn a_syntax_that_ships_a_query_for_a_registered_grammar_is_reported() {
        assert_eq!(failed(Flaw::ShipsForRegistered), [REGISTERS]);
    }

    #[test]
    fn a_syntax_that_ships_the_compiled_in_queries_of_a_name_it_overrode_is_reported() {
        assert_eq!(failed(Flaw::ShipsAfterOverride), [OVERRIDES]);
    }

    #[test]
    fn a_syntax_that_keeps_the_compiled_in_policy_of_a_name_it_overrode_is_reported() {
        assert_eq!(failed(Flaw::CompiledPolicyAfterOverride), [OVERRIDES]);
    }

    #[test]
    fn a_syntax_that_answers_not_loadable_for_a_missing_file_is_reported() {
        assert_eq!(failed(Flaw::NotLoadableForMissing), [NOT_FOUND]);
    }

    #[test]
    fn a_syntax_that_answers_not_found_for_a_file_that_is_no_library_is_reported() {
        assert_eq!(failed(Flaw::NotFoundForNoLibrary), [NOT_LOADABLE]);
    }

    #[test]
    fn a_syntax_that_answers_missing_symbol_for_a_grammar_of_another_abi_is_reported() {
        assert_eq!(failed(Flaw::MissingSymbolForOtherAbi), [UNSUPPORTED_ABI]);
    }

    #[test]
    fn a_syntax_that_lists_a_grammar_it_refused_is_reported() {
        assert_eq!(failed(Flaw::ListsRefused), [MISSING_SYMBOL]);
    }

    #[test]
    fn a_syntax_that_refuses_as_unsupported_but_lists_the_grammar_is_reported() {
        let syntax = BrokenRegistering::new(Flaw::UnsupportedButLists);

        assert_eq!(
            check_unsupported(&syntax, &libraries::corpus().sources()),
            [UNSUPPORTED]
        );
    }

    #[test]
    fn an_overriding_source_that_declares_the_compiled_in_policy_fails_overrides() {
        let mut corpus = libraries::corpus();
        corpus.overriding.policy = Some(ReparsePolicy::Incremental);

        assert_eq!(
            check(|| Libraries::new(libraries::table()), &corpus),
            [OVERRIDES]
        );
    }

    #[test]
    fn an_empty_list_of_sources_fails_unsupported() {
        assert_eq!(check_unsupported(&Parens, &[]), [UNSUPPORTED]);
    }
}
