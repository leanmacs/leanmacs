//! Injections: text of one language held in a node of another's, parsed
//! as a layer of its own and drawn over the text around it (a fenced block
//! of Rust in Markdown, a macro's token tree in Rust).
//!
//! What crosses from Lean is plain data in the core's terms: an
//! [`Injections`], the host's injections query and, by name, each
//! [`Language`] an injection may name, with the grammar it is parsed with,
//! the highlighter it is drawn with, and its own injections query.
//!
//! # The injection rule ([`found`])
//!
//! An injections query's matches over the hull of the ranges a tree is of
//! (`within`: the whole text for the host, a layer's ranges for a layer)
//! each say one injection, or none:
//!
//! 1. **The language** is the text of the match's first
//!    `injection.language` capture, trimmed and lower-cased in ASCII;
//!    failing that, the value of the pattern's `injection.language`
//!    setting. With neither, the match injects nothing.
//! 2. **The content** is the ranges of the match's `injection.content`
//!    captures, each with its node's named children taken out unless the
//!    pattern sets `injection.include-children`, so a fence's code keeps
//!    its punctuation and leaves out the `> ` a block quote puts before each
//!    line. Each range is cut to `within`, so a nested layer stays inside
//!    its parent's ranges, empty ones are dropped, and the rest are sorted
//!    and made one where they touch.
//! 3. **A match injects nothing** when no range is left, or when its
//!    language is not one of the languages known: nothing aliases a name,
//!    so a fence of `rs` injects nothing. A layer's injection over the
//!    layer's own ranges makes no progress and is dropped ([`layers`]);
//!    the host's over the whole text is a layer, as the inline text of a
//!    Markdown document that is one paragraph is.
//! 4. **Each match is a layer of its own.** `injection.combined` is not
//!    built: a pattern that sets it is one injection per match.
//!
//! The injections found are in the order of their first range's start.
//!
//! # Layers ([`layers`])
//!
//! The layers of a text are the host's injections, then each layer's own,
//! when its language has an injections query, down to [`MAX_DEPTH`] below
//! the host; in order of depth and then of start. Each is parsed whole in
//! its ranges ([`Syntax::parse_in`]) by a parser of its grammar, one kept
//! for each grammar. Injected regions are small (a fence, a macro's token
//! tree), and a tree parsed whole equals a fresh parse with nothing to
//! prove; reusing a layer's tree across rounds is an open question
//! (`docs/design/rust-library.md`).
//!
//! [`layers`] reads the languages through [`Languages`]: the host's
//! injections query and, by name, a language's grammar and own injections
//! query. A session's [`Injections`] is one; a text parsed once
//! ([`crate::once`]) hands its own table.
//!
//! [`fresh`] is a whole host parse and its layers: what the tests compare
//! a session's layers with.

use std::collections::{BTreeMap, VecDeque};
use std::ops::Range;
use std::sync::Arc;

use editor_text::Snapshot;

use crate::highlight::Highlighter;
use crate::port::{GrammarName, Syntax};
use crate::query::widened;

/// How many layers deep injections are found below the host: a layer of
/// that depth finds none of its own.
pub const MAX_DEPTH: u32 = 3;

/// The capture whose text names an injection's language.
const LANGUAGE: &str = "injection.language";
/// The capture of the nodes that hold an injection's text.
const CONTENT: &str = "injection.content";
/// The setting that keeps a content node's named children in.
const INCLUDE_CHILDREN: &str = "injection.include-children";

/// A language an injection may name: the grammar its text is parsed with,
/// what it is drawn with, and its own injections query, if it has one.
pub struct Language<Q> {
    /// The grammar its layers are parsed with.
    pub grammar: GrammarName,
    /// What its layers are drawn with: a query of `grammar` and its faces.
    pub highlighter: Arc<Highlighter<Q>>,
    /// The injections query its layers find layers of their own with.
    pub injections: Option<Arc<Q>>,
}

impl<Q> Clone for Language<Q> {
    fn clone(&self) -> Self {
        Self {
            grammar: self.grammar.clone(),
            highlighter: self.highlighter.clone(),
            injections: self.injections.clone(),
        }
    }
}

/// A text's injections: the host's injections query, and the languages an
/// injection may name, by name.
pub struct Injections<Q> {
    /// The host's injections query; none finds no layer.
    pub query: Option<Arc<Q>>,
    /// The languages, by the name an injection gives.
    pub languages: BTreeMap<String, Language<Q>>,
}

impl<Q> Default for Injections<Q> {
    fn default() -> Self {
        Self {
            query: None,
            languages: BTreeMap::new(),
        }
    }
}

impl<Q> Clone for Injections<Q> {
    fn clone(&self) -> Self {
        Self {
            query: self.query.clone(),
            languages: self.languages.clone(),
        }
    }
}

/// Where [`layers`] reads its languages from: the host's injections query
/// and, by the name an injection gives, the grammar a language is parsed
/// with and its own injections query. A name it has no grammar for is not
/// a language known, so it injects nothing.
pub trait Languages<Q> {
    /// The host's injections query; none finds no layer.
    fn host_injections(&self) -> Option<&Q>;
    /// The grammar the language `name` is parsed with, if it is known.
    fn grammar(&self, name: &str) -> Option<&GrammarName>;
    /// The injections query the language `name`'s layers find layers of
    /// their own with, if it has one.
    fn injections(&self, name: &str) -> Option<&Q>;
}

impl<Q> Languages<Q> for Injections<Q> {
    fn host_injections(&self) -> Option<&Q> {
        self.query.as_deref()
    }

    fn grammar(&self, name: &str) -> Option<&GrammarName> {
        self.languages.get(name).map(|language| &language.grammar)
    }

    fn injections(&self, name: &str) -> Option<&Q> {
        self.languages.get(name)?.injections.as_deref()
    }
}

/// An injection found: its language and the ranges of its text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Found {
    /// The language's name.
    pub language: String,
    /// The ranges of the text, sorted and apart.
    pub ranges: Vec<Range<usize>>,
}

/// A layer: an injection parsed.
#[derive(Debug, Clone)]
pub struct Layer<T> {
    /// The language's name.
    pub language: String,
    /// The grammar it was parsed with.
    pub grammar: GrammarName,
    /// The ranges of the text it is of, sorted and apart.
    pub ranges: Vec<Range<usize>>,
    /// How deep it is: 1 for an injection of the host's.
    pub depth: u32,
    /// Its tree, of the bytes in `ranges` only.
    pub tree: T,
}

/// `range` with `holes`, sorted ranges within it, taken out.
fn without(range: Range<usize>, holes: &[Range<usize>]) -> Vec<Range<usize>> {
    let mut parts = Vec::new();
    let mut from = range.start;
    for hole in holes {
        if hole.start > from {
            parts.push(from..hole.start.min(range.end));
        }
        from = from.max(hole.end);
    }
    if from < range.end {
        parts.push(from..range.end);
    }
    parts
}

/// `ranges`, each cut to `within`, the empty ones dropped, sorted, and those
/// that touch made one.
fn cut_to(ranges: &[Range<usize>], within: &[Range<usize>]) -> Vec<Range<usize>> {
    let mut cut: Vec<Range<usize>> = ranges
        .iter()
        .flat_map(|range| {
            within
                .iter()
                .map(|bound| range.start.max(bound.start)..range.end.min(bound.end))
        })
        .filter(|range| !range.is_empty())
        .collect();
    cut.sort_by_key(|range| range.start);
    let mut merged: Vec<Range<usize>> = Vec::new();
    for range in cut {
        match merged.last_mut() {
            Some(last) if range.start <= last.end => last.end = last.end.max(range.end),
            _ => merged.push(range),
        }
    }
    merged
}

/// The injections `query`'s matches in `tree`, a tree of the bytes of
/// `text` in `within`, say, by the injection rule of the module docs:
/// each of a language `known` says is one, in the order of its first
/// range's start.
pub fn found<S: Syntax>(
    syntax: &S,
    query: &S::Query,
    tree: &S::Tree,
    text: &Snapshot,
    within: &[Range<usize>],
    known: &dyn Fn(&str) -> bool,
) -> Vec<Found> {
    let (Some(first), Some(last)) = (within.first(), within.last()) else {
        return Vec::new();
    };
    let names = syntax.capture_names(query);
    let index_of = |name: &str| {
        names
            .iter()
            .position(|known| known == name)
            .and_then(|index| u32::try_from(index).ok())
    };
    let (language_capture, content_capture) = (index_of(LANGUAGE), index_of(CONTENT));
    let hull = first.start..last.end;
    let mut found = Vec::new();
    for found_match in syntax.matches(query, tree, text, widened(text, &hull)) {
        let settings = syntax.pattern_settings(query, found_match.pattern);
        let named = found_match
            .captures
            .iter()
            .find(|capture| Some(capture.capture) == language_capture)
            .and_then(|capture| text.slice_to_string(capture.range()))
            .map(|name| name.trim().to_ascii_lowercase());
        let set = || {
            settings
                .iter()
                .find(|setting| setting.key == LANGUAGE)
                .and_then(|setting| setting.value.clone())
        };
        let Some(language) = named.or_else(set) else {
            continue;
        };
        let include_children = settings
            .iter()
            .any(|setting| setting.key == INCLUDE_CHILDREN);
        let content: Vec<Range<usize>> = found_match
            .captures
            .iter()
            .filter(|capture| Some(capture.capture) == content_capture)
            .flat_map(|capture| {
                if include_children {
                    vec![capture.range()]
                } else {
                    without(capture.range(), &capture.named_children)
                }
            })
            .collect();
        let ranges = cut_to(&content, within);
        if ranges.is_empty() || !known(&language) {
            continue;
        }
        found.push(Found { language, ranges });
    }
    found.sort_by_key(|found| found.ranges[0].start);
    found
}

/// The layers of `host`, the tree of `text`, by `languages`, as the module
/// docs say: in order of depth, then of start. A grammar's parser is taken
/// from `parsers`, or opened and kept there on first use.
pub fn layers<S: Syntax, L: Languages<S::Query> + ?Sized>(
    syntax: &S,
    languages: &L,
    host: &S::Tree,
    text: &Snapshot,
    parsers: &mut BTreeMap<GrammarName, S::Parser>,
) -> Vec<Layer<S::Tree>> {
    let Some(query) = languages.host_injections() else {
        return Vec::new();
    };
    let known = |name: &str| languages.grammar(name).is_some();
    let whole = 0..text.len();
    let within = std::slice::from_ref(&whole);
    let mut pending: VecDeque<(u32, Found)> = found(syntax, query, host, text, within, &known)
        .into_iter()
        .map(|found| (1, found))
        .collect();
    let mut layers = Vec::new();
    while let Some((depth, injection)) = pending.pop_front() {
        let Some(grammar) = languages.grammar(&injection.language) else {
            continue;
        };
        let parser = match parsers.get_mut(grammar) {
            Some(parser) => parser,
            None => {
                let Some(opened) = syntax.parser(grammar) else {
                    continue;
                };
                parsers.entry(grammar.clone()).or_insert(opened)
            }
        };
        let tree = syntax.parse_in(parser, text, &injection.ranges);
        if depth < MAX_DEPTH
            && let Some(own) = languages.injections(&injection.language)
        {
            let nested = found(syntax, own, &tree, text, &injection.ranges, &known);
            // An injection over the layer's own ranges makes no progress.
            pending.extend(
                nested
                    .into_iter()
                    .filter(|found| found.ranges != injection.ranges)
                    .map(|found| (depth + 1, found)),
            );
        }
        layers.push(Layer {
            language: injection.language,
            grammar: grammar.clone(),
            ranges: injection.ranges,
            depth,
            tree,
        });
    }
    layers.sort_by_key(|layer| (layer.depth, layer.ranges[0].start));
    layers
}

/// A tree and its layers.
pub type Layered<T> = (T, Vec<Layer<T>>);

/// A whole parse of `text` with `grammar` and its layers by `injections`:
/// the reference a session's layers are compared with. `None` for a
/// grammar `syntax` does not have.
pub fn fresh<S: Syntax>(
    syntax: &S,
    grammar: &GrammarName,
    injections: &Injections<S::Query>,
    text: &Snapshot,
) -> Option<Layered<S::Tree>> {
    let mut parser = syntax.parser(grammar)?;
    let host = syntax.parse(&mut parser, text, None);
    let layers = layers(syntax, injections, &host, text, &mut BTreeMap::new());
    Some((host, layers))
}

#[cfg(test)]
mod tests {
    use editor_text::{InputEdit, Text};

    use super::*;
    use crate::fake::{GRAMMAR, Parens, ParensParser, ParensQuery};
    use crate::port::{Capture, Match, MatchCapture, Node, QueryError, QueryKind, Setting};

    /// A syntax that answers canned matches, capture names and settings,
    /// whatever it is asked.
    struct Canned {
        /// The capture names.
        names: Vec<&'static str>,
        /// The matches.
        matches: Vec<Match>,
        /// The settings of each pattern.
        settings: Vec<Vec<Setting>>,
    }

    impl Syntax for Canned {
        type Parser = ();
        type Tree = ();
        type Query = ();

        fn grammars(&self) -> Vec<GrammarName> {
            Vec::new()
        }
        fn parser(&self, _: &GrammarName) -> Option<()> {
            None
        }
        fn reparse_policy(&self, _: &GrammarName) -> Option<crate::ReparsePolicy> {
            None
        }
        fn register(
            &self,
            _: &crate::GrammarSource,
        ) -> Result<GrammarName, crate::RegistrationRefusal> {
            Err(crate::RegistrationRefusal::Unsupported)
        }
        fn parse(&self, _: &mut (), _: &Snapshot, _: Option<&()>) {}
        fn edit(&self, _: &mut (), _: &InputEdit) {}
        fn compile(&self, _: &GrammarName, _: &str) -> Result<(), QueryError> {
            Ok(())
        }
        fn shipped_query(&self, _: &GrammarName, _: QueryKind) -> Option<String> {
            None
        }
        fn capture_names(&self, _: &()) -> Vec<String> {
            self.names.iter().map(|name| (*name).to_owned()).collect()
        }
        fn captures(&self, _: &(), _: &(), _: &Snapshot, _: Range<usize>) -> Vec<Capture> {
            crate::query::flatten(&self.matches)
        }
        fn matches(&self, _: &(), _: &(), _: &Snapshot, _: Range<usize>) -> Vec<Match> {
            self.matches.clone()
        }
        fn pattern_settings(&self, _: &(), pattern: usize) -> Vec<Setting> {
            self.settings.get(pattern).cloned().unwrap_or_default()
        }
        fn parse_in(&self, _: &mut (), _: &Snapshot, _: &[Range<usize>]) {}
        fn nodes(&self, _: &()) -> Vec<Node> {
            Vec::new()
        }
        fn has_errors(&self, _: &()) -> bool {
            false
        }
    }

    /// A capture of capture `capture` over `range`, with `children`.
    fn capture(capture: u32, range: Range<usize>, children: &[Range<usize>]) -> MatchCapture {
        MatchCapture {
            capture,
            start: range.start,
            end: range.end,
            named_children: children.to_vec(),
        }
    }

    /// The range from `start` to `end`.
    fn span(start: usize, end: usize) -> Range<usize> {
        start..end
    }

    /// The setting `key`, with `value`.
    fn setting(key: &str, value: Option<&str>) -> Setting {
        Setting {
            key: key.to_owned(),
            value: value.map(str::to_owned),
        }
    }

    /// What `syntax` finds in `text`, within `within`, with `rust` and
    /// `json` the languages known.
    fn found_in(syntax: &Canned, text: &str, within: &[Range<usize>]) -> Vec<Found> {
        let snapshot = Text::from(text).snapshot();
        let known = |name: &str| name == "rust" || name == "json";
        found(syntax, &(), &(), &snapshot, within, &known)
    }

    /// `(language, ranges)` as a found injection.
    fn injection(language: &str, ranges: &[Range<usize>]) -> Found {
        Found {
            language: language.to_owned(),
            ranges: ranges.to_vec(),
        }
    }

    /// The capture names of an injections query: 0 the language, 1 the
    /// content.
    const NAMES: [&str; 2] = ["injection.language", "injection.content"];

    #[test]
    fn the_language_is_a_captures_text_trimmed_and_lower_cased() {
        // `~~~ RuSt \n{x}\n`: the info string, then the content.
        let syntax = Canned {
            names: NAMES.to_vec(),
            matches: vec![Match {
                pattern: 0,
                captures: vec![capture(0, 3..9, &[]), capture(1, 10..14, &[])],
            }],
            settings: vec![vec![setting("injection.language", Some("json"))]],
        };

        assert_eq!(
            found_in(&syntax, "~~~ RuSt \n{x}\n", &[span(0, 14)]),
            [injection("rust", &[span(10, 14)])]
        );
    }

    #[test]
    fn the_language_is_the_patterns_setting_when_no_capture_names_one() {
        let syntax = Canned {
            names: NAMES.to_vec(),
            matches: vec![Match {
                pattern: 0,
                captures: vec![capture(1, 2..5, &[])],
            }],
            settings: vec![vec![setting("injection.language", Some("json"))]],
        };

        assert_eq!(
            found_in(&syntax, "a [1] b", &[span(0, 7)]),
            [injection("json", &[span(2, 5)])]
        );
    }

    #[test]
    fn a_match_with_no_language_or_one_not_known_injects_nothing() {
        let nameless = Canned {
            names: NAMES.to_vec(),
            matches: vec![Match {
                pattern: 0,
                captures: vec![capture(1, 2..5, &[])],
            }],
            settings: vec![vec![setting("injection.language", None)]],
        };
        assert_eq!(found_in(&nameless, "a [1] b", &[span(0, 7)]), []);

        let unknown = Canned {
            names: NAMES.to_vec(),
            matches: vec![Match {
                pattern: 0,
                captures: vec![capture(0, 0..2, &[]), capture(1, 3..6, &[])],
            }],
            settings: vec![],
        };
        assert_eq!(found_in(&unknown, "rs [1]", &[span(0, 6)]), []);
    }

    #[test]
    fn a_content_nodes_named_children_are_taken_out_unless_the_pattern_includes_them() {
        // `> a\n> b\n`: a content node over all of it, whose named
        // children are the two `> `.
        let content = || Match {
            pattern: 0,
            captures: vec![capture(1, 0..8, &[0..2, 4..6])],
        };
        let without_children = Canned {
            names: NAMES.to_vec(),
            matches: vec![content()],
            settings: vec![vec![setting("injection.language", Some("rust"))]],
        };
        assert_eq!(
            found_in(&without_children, "> a\n> b\n", &[span(0, 8)]),
            [injection("rust", &[2..4, 6..8])]
        );

        let with_children = Canned {
            settings: vec![vec![
                setting("injection.language", Some("rust")),
                setting("injection.include-children", None),
            ]],
            ..without_children
        };
        assert_eq!(
            found_in(&with_children, "> a\n> b\n", &[span(0, 9)]),
            [injection("rust", &[span(0, 8)])]
        );
    }

    #[test]
    fn ranges_are_cut_to_the_parents_and_ones_equal_to_the_parents_are_kept() {
        let syntax = Canned {
            names: NAMES.to_vec(),
            matches: vec![
                Match {
                    pattern: 0,
                    captures: vec![capture(1, 1..9, &[])],
                },
                Match {
                    pattern: 0,
                    captures: vec![capture(1, 3..7, &[])],
                },
            ],
            settings: vec![vec![setting("injection.language", Some("rust"))]],
        };

        assert_eq!(
            found_in(&syntax, "0123456789", &[span(0, 10)]),
            [
                injection("rust", &[span(1, 9)]),
                injection("rust", &[span(3, 7)])
            ]
        );
        // Within two ranges, the second match is cut to them; the first is
        // the parent's own ranges once cut, which `layers` drops for a
        // layer's injections and keeps for the host's.
        assert_eq!(
            found_in(&syntax, "0123456789", &[2..4, 6..8]),
            [
                injection("rust", &[2..4, 6..8]),
                injection("rust", &[3..4, 6..7])
            ]
        );
        assert_eq!(
            found_in(&syntax, "0123456789", &[span(1, 9)]),
            [
                injection("rust", &[span(1, 9)]),
                injection("rust", &[span(3, 7)])
            ]
        );
    }

    #[test]
    fn injections_are_in_the_order_of_their_first_ranges_start() {
        let syntax = Canned {
            names: NAMES.to_vec(),
            matches: vec![
                Match {
                    pattern: 0,
                    captures: vec![capture(1, 6..8, &[])],
                },
                Match {
                    pattern: 1,
                    captures: vec![capture(1, 1..3, &[])],
                },
            ],
            settings: vec![
                vec![setting("injection.language", Some("rust"))],
                vec![setting("injection.language", Some("json"))],
            ],
        };

        assert_eq!(
            found_in(&syntax, "0123456789", &[span(0, 10)]),
            [
                injection("json", &[span(1, 3)]),
                injection("rust", &[span(6, 8)])
            ]
        );
    }

    /// The fake's injections: each list's text, its children included, is
    /// `parens` again, drawn with its shipped highlights.
    fn nested() -> Injections<ParensQuery> {
        let grammar = GrammarName::new(GRAMMAR);
        let query = Arc::new(
            Parens
                .compile(
                    &grammar,
                    "list @injection.content #set! injection.language parens #set! injection.include-children",
                )
                .unwrap(),
        );
        let highlights = Parens
            .compile(
                &grammar,
                &Parens
                    .shipped_query(&grammar, QueryKind::Highlights)
                    .unwrap(),
            )
            .unwrap();
        let count = Parens.capture_names(&highlights).len();
        let highlighter = Highlighter::new(Arc::new(highlights), count, vec![None; count]).unwrap();
        let language = Language {
            grammar,
            highlighter: Arc::new(highlighter),
            injections: Some(query.clone()),
        };
        Injections {
            query: Some(query),
            languages: BTreeMap::from([(GRAMMAR.to_owned(), language)]),
        }
    }

    #[test]
    fn layers_nest_down_to_the_bound_and_no_further() {
        // Six lists inside one another, the outermost the whole text, which
        // the host injects as any other.
        let snapshot = Text::from("((((((a))))))").snapshot();
        let (_, layers) = fresh(&Parens, &GrammarName::new(GRAMMAR), &nested(), &snapshot).unwrap();

        let shape: Vec<(u32, Vec<Range<usize>>)> = layers
            .iter()
            .map(|layer| (layer.depth, layer.ranges.clone()))
            .collect();
        // The host finds every list; each layer of depth 1 or 2 finds the
        // lists inside its own, its own left out; one of depth 3 finds
        // none.
        let mut expected = Vec::new();
        for depth in 1..=MAX_DEPTH {
            for start in depth - 1..6 {
                // A list is found once for each chain of lists from the
                // host's down to it, `depth` long.
                for _ in 0..binomial(start, depth - 1) {
                    expected.push((depth, vec![span(start as usize, 13 - start as usize)]));
                }
            }
        }
        assert_eq!(shape, expected);
        assert!(layers.iter().all(|layer| layer.language == GRAMMAR));
    }

    #[test]
    fn a_hosts_injection_over_the_whole_text_is_a_layer_and_a_layers_over_its_own_ranges_is_not() {
        // The root is the whole text: the host injects it, as a Markdown
        // document of one paragraph injects its inline text, and the layer
        // that makes finds only its own ranges again.
        let grammar = GrammarName::new(GRAMMAR);
        let query = Arc::new(
            Parens
                .compile(
                    &grammar,
                    "document @injection.content #set! injection.language parens #set! injection.include-children",
                )
                .unwrap(),
        );
        let mut injections = nested();
        injections.query = Some(query.clone());
        if let Some(language) = injections.languages.get_mut(GRAMMAR) {
            language.injections = Some(query);
        }
        let snapshot = Text::from("a (b)").snapshot();
        let (_, layers) = fresh(&Parens, &grammar, &injections, &snapshot).unwrap();

        let shape: Vec<(u32, Vec<Range<usize>>)> = layers
            .iter()
            .map(|layer| (layer.depth, layer.ranges.clone()))
            .collect();
        assert_eq!(shape, [(1, vec![span(0, 5)])]);
    }

    /// `n` choose `k`.
    fn binomial(n: u32, k: u32) -> u32 {
        (0..k).fold(1, |acc, i| acc * (n - i) / (i + 1))
    }

    #[test]
    fn a_layers_tree_is_the_parse_in_its_ranges() {
        // The root list is not the whole text, so its inner list is the one
        // layer of the host's.
        let snapshot = Text::from("x (a (b c))").snapshot();
        let (_, layers) = fresh(&Parens, &GrammarName::new(GRAMMAR), &nested(), &snapshot).unwrap();

        assert_eq!(layers.len(), 3);
        let inner = &layers[1];
        let alone = Parens.parse_in(&mut ParensParser, &snapshot, &inner.ranges);
        assert_eq!(inner.ranges, [span(5, 10)]);
        assert_eq!(Parens.nodes(&inner.tree), Parens.nodes(&alone));
    }
}
