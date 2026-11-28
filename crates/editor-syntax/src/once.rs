//! A text parsed once: parsed whole with a host grammar, its layers found
//! by the injection rule ([`crate::inject`]), and each layer answered with
//! its language's captures, all at once and kept nowhere.
//!
//! It is what a rendered view of a generated text asks
//! (`lean/Editor/Markdown/`): the text it renders is not the text a buffer
//! holds, so no session parses it, and the answer is wanted in the call,
//! not delivered later. Nothing here starts a thread or touches a session.
//!
//! # The rule ([`parse`])
//!
//! - **The table** names each language a layer may be of, the host's
//!   included, by the name an injection gives: the grammar it is parsed
//!   with, the query its captures are answered with, and the injections
//!   query its layers find layers of their own with, if any
//!   ([`OnceLanguage`]). The host's own entry's injections query is the
//!   one the host's layers are found with.
//! - **The host comes first**, at depth 0 over the whole text, with the
//!   captures of its query over the whole text
//!   ([`crate::query::captures_in`]).
//! - **Each layer follows** in the order [`crate::inject::layers`] finds
//!   them, by depth and then by start, with the captures of its language's
//!   query over the hull of its ranges, uncut: a node may run across a gap
//!   between two of its ranges, as a tree parsed in ranges allows.
//! - **A language the table does not name** injects nothing, as in a
//!   session.
//! - **An unknown host**, one the table does not name or whose grammar the
//!   syntax has no parser for, answers `None`.

use std::collections::BTreeMap;
use std::ops::Range;
use std::sync::Arc;

use editor_text::Snapshot;

use crate::inject::{self, Languages};
use crate::port::{Capture, GrammarName, Syntax};
use crate::query::captures_in;

/// A language a text parsed once may hold: the grammar its layers are
/// parsed with, the query their captures are answered with, and the
/// injections query they find layers of their own with, if it has one.
pub struct OnceLanguage<Q> {
    /// The grammar its layers are parsed with.
    pub grammar: GrammarName,
    /// The query its layers' captures are answered with.
    pub query: Arc<Q>,
    /// The injections query its layers find layers of their own with.
    pub injections: Option<Arc<Q>>,
}

impl<Q> Clone for OnceLanguage<Q> {
    fn clone(&self) -> Self {
        Self {
            grammar: self.grammar.clone(),
            query: self.query.clone(),
            injections: self.injections.clone(),
        }
    }
}

/// A layer of a text parsed once, the host included: its language's name,
/// how deep it is (0 for the host), the ranges of the text it is of, and
/// its language's query's captures over them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OnceLayer {
    /// The language's name, as the table names it.
    pub language: String,
    /// How deep it is: 0 for the host, 1 for an injection of the host's.
    pub depth: u32,
    /// The ranges of the text it is of, sorted and apart.
    pub ranges: Vec<Range<usize>>,
    /// The captures of its language's query over the hull of its ranges,
    /// in the order [`captures_in`] answers.
    pub captures: Vec<Capture>,
}

/// The table as the injection rule reads it: the host's injections, and
/// each language's grammar and own injections.
struct Table<'a, Q> {
    /// The host's injections query.
    host: Option<&'a Q>,
    /// The languages, by name.
    languages: &'a BTreeMap<String, OnceLanguage<Q>>,
}

impl<Q> Languages<Q> for Table<'_, Q> {
    fn host_injections(&self) -> Option<&Q> {
        self.host
    }

    fn grammar(&self, name: &str) -> Option<&GrammarName> {
        self.languages.get(name).map(|language| &language.grammar)
    }

    fn injections(&self, name: &str) -> Option<&Q> {
        self.languages.get(name)?.injections.as_deref()
    }
}

/// `text` parsed once with the language `host` of `languages`, and its
/// layers, each with its language's captures, by the rule of the module
/// docs: the host first, then each layer by depth and start. `None` for a
/// host the table does not name or whose grammar `syntax` has no parser
/// for.
pub fn parse<S: Syntax>(
    syntax: &S,
    host: &str,
    text: &Snapshot,
    languages: &BTreeMap<String, OnceLanguage<S::Query>>,
) -> Option<Vec<OnceLayer>> {
    let own = languages.get(host)?;
    let mut parser = syntax.parser(&own.grammar)?;
    let tree = syntax.parse(&mut parser, text, None);
    let whole = 0..text.len();
    let mut answered = vec![OnceLayer {
        language: host.to_owned(),
        depth: 0,
        ranges: vec![whole.clone()],
        captures: captures_in(syntax, &own.query, &tree, text, whole).unwrap_or_default(),
    }];
    let table = Table {
        host: own.injections.as_deref(),
        languages,
    };
    for layer in inject::layers(syntax, &table, &tree, text, &mut BTreeMap::new()) {
        let Some(language) = languages.get(&layer.language) else {
            continue;
        };
        let (Some(first), Some(last)) = (layer.ranges.first(), layer.ranges.last()) else {
            continue;
        };
        let hull = first.start..last.end;
        let captures =
            captures_in(syntax, &language.query, &layer.tree, text, hull).unwrap_or_default();
        answered.push(OnceLayer {
            language: layer.language,
            depth: layer.depth,
            ranges: layer.ranges,
            captures,
        });
    }
    Some(answered)
}

#[cfg(test)]
mod tests {
    use editor_text::Text;

    use super::*;
    use crate::fake::{GRAMMAR, Parens, ParensQuery};
    use crate::port::QueryKind;

    /// A query of the fake's grammar.
    fn query(source: &str) -> Arc<ParensQuery> {
        Arc::new(Parens.compile(&GrammarName::new(GRAMMAR), source).unwrap())
    }

    /// Each list's text, its children included, is `parens` again.
    const INJECTIONS: &str =
        "list @injection.content #set! injection.language parens #set! injection.include-children";

    /// A language of the fake's grammar answered with its shipped
    /// highlights, finding layers with `injections`, if given.
    fn language(injections: Option<&str>) -> OnceLanguage<ParensQuery> {
        let grammar = GrammarName::new(GRAMMAR);
        OnceLanguage {
            query: query(
                &Parens
                    .shipped_query(&grammar, QueryKind::Highlights)
                    .unwrap(),
            ),
            injections: injections.map(query),
            grammar,
        }
    }

    /// A table of the one language `parens`, nesting through lists.
    fn nesting() -> BTreeMap<String, OnceLanguage<ParensQuery>> {
        BTreeMap::from([(GRAMMAR.to_owned(), language(Some(INJECTIONS)))])
    }

    /// The range from `start` to `end`.
    fn span(start: usize, end: usize) -> Range<usize> {
        start..end
    }

    /// Each layer's language, depth and ranges.
    fn shape(layers: &[OnceLayer]) -> Vec<(String, u32, Vec<Range<usize>>)> {
        layers
            .iter()
            .map(|layer| (layer.language.clone(), layer.depth, layer.ranges.clone()))
            .collect()
    }

    #[test]
    fn the_host_comes_first_at_depth_0_over_the_whole_text() {
        let snapshot = Text::from("a (b) c").snapshot();
        let layers = parse(&Parens, GRAMMAR, &snapshot, &nesting()).unwrap();
        assert_eq!(shape(&layers)[0], (GRAMMAR.to_owned(), 0, vec![span(0, 7)]));
    }

    #[test]
    fn nested_layers_follow_by_depth_and_then_by_start() {
        // Two lists, the first with one inside it.
        let snapshot = Text::from("(a (b)) (c)").snapshot();
        let layers = parse(&Parens, GRAMMAR, &snapshot, &nesting()).unwrap();
        assert_eq!(
            shape(&layers),
            [
                (GRAMMAR.to_owned(), 0, vec![span(0, 11)]),
                // Every list the host holds, then the one inside the
                // first, found again by the first's layer.
                (GRAMMAR.to_owned(), 1, vec![span(0, 7)]),
                (GRAMMAR.to_owned(), 1, vec![span(3, 6)]),
                (GRAMMAR.to_owned(), 1, vec![span(8, 11)]),
                (GRAMMAR.to_owned(), 2, vec![span(3, 6)]),
            ]
        );
    }

    #[test]
    fn a_language_the_table_does_not_name_injects_nothing() {
        // The host finds `parens` layers, but the table names only `host`.
        let table = BTreeMap::from([("host".to_owned(), language(Some(INJECTIONS)))]);
        let snapshot = Text::from("(a) (b)").snapshot();
        let layers = parse(&Parens, "host", &snapshot, &table).unwrap();
        assert_eq!(shape(&layers), [("host".to_owned(), 0, vec![span(0, 7)])]);
    }

    #[test]
    fn an_unknown_host_is_none() {
        let snapshot = Text::from("(a)").snapshot();
        assert!(parse(&Parens, "other", &snapshot, &nesting()).is_none());
        let unparsed = BTreeMap::from([(
            "other".to_owned(),
            OnceLanguage {
                grammar: GrammarName::new("no-such-grammar"),
                ..language(None)
            },
        )]);
        assert!(parse(&Parens, "other", &snapshot, &unparsed).is_none());
    }

    #[test]
    fn each_layers_captures_are_its_querys_over_its_ranges() {
        let snapshot = Text::from("(a (b)) (c)").snapshot();
        let table = nesting();
        let layers = parse(&Parens, GRAMMAR, &snapshot, &table).unwrap();
        let own = &table[GRAMMAR];
        let host = Parens.parse(&mut crate::fake::ParensParser, &snapshot, None);
        assert_eq!(
            layers[0].captures,
            captures_in(&Parens, &own.query, &host, &snapshot, 0..11).unwrap()
        );
        for layer in &layers[1..] {
            let tree = Parens.parse_in(&mut crate::fake::ParensParser, &snapshot, &layer.ranges);
            let hull = layer.ranges[0].start..layer.ranges[layer.ranges.len() - 1].end;
            assert!(!layer.captures.is_empty());
            assert_eq!(
                layer.captures,
                captures_in(&Parens, &own.query, &tree, &snapshot, hull).unwrap()
            );
        }
    }
}
