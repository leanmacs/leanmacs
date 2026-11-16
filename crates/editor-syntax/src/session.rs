//! One text's parse state, and the rule for which result is handed out.
//!
//! A [`Session`] parses one text with one grammar, off the editor thread.
//! It reaches the text through a [`Source`], which hands it the text as it
//! is now and the edit log's patch since the tree it last parsed, and it
//! hands each result it delivers to its [`Consumer`]s. Parsing never passes
//! through Lean: the bytes go from the snapshot's chunks to the parser.
//!
//! # A round ([`Session::parse_once`])
//!
//! 1. The source is asked for the text as it is now and what changed since
//!    the revision of the last tree parsed, the *base*. A text that is gone
//!    ends the session ([`Outcome::Gone`]); one still at the base's revision
//!    needs nothing ([`Outcome::UpToDate`]).
//! 2. With a base and a patch that chains from it (`patch.from` is the
//!    base's revision and `patch.to` the snapshot's), a clone of the base
//!    tree is told each of the patch's edits, in order, and the text is
//!    reparsed with it. Otherwise (the first parse, a log that has
//!    forgotten the base's revision, a patch that does not chain) the text
//!    is parsed whole.
//! 3. **The fallback rule** ([`reparse`]). An incremental reparse whose tree
//!    has an error or a missing node ([`Syntax::has_errors`]) is dropped,
//!    and the text parsed whole: how a library recovers from an error can
//!    depend on what it reuses, so only a fresh parse is sure to give the
//!    tree a fresh parse gives. A reparse with no error is kept, and the
//!    contract ([`crate::contract::INCREMENTAL`]) holds it equal to a fresh
//!    parse. So the tree of a round is always the tree a fresh parse of
//!    its snapshot gives. The second parse is the worker's: the editor
//!    thread never waits for it.
//! 4. The result is the new base, delivered or not.
//! 5. **The delivery rule.** The result is delivered only if its revision is
//!    at least the newest the session has been told of
//!    ([`Session::touch`]). Delivering sets that revision to the result's,
//!    keeps the result ([`Session::parsed`]) and hands it to each consumer.
//!    A result older than a revision the session has been told of is
//!    [`Outcome::Stale`]: nobody sees it, and it serves only as the base of
//!    the next parse. So the revisions delivered only grow, and a result
//!    tagged with a revision older than the current one is never handed
//!    out.
//!
//! # A question of captures ([`Session::captures`])
//!
//! A question of a query's captures in a range of a snapshot is answered
//! from the tree delivered, never parsed for, so it never waits. It is
//! refused, checked in this order, when the query is of another grammar
//! than the session's ([`CapturesRefusal::WrongGrammar`]), when the range
//! is not two positions of the snapshot's text in order
//! ([`CapturesRefusal::BadRange`]), and when the tree delivered last is not
//! of the snapshot's revision, older or newer
//! ([`CapturesRefusal::NotParsed`]): a caller asks again after the next
//! delivery. Otherwise it answers what [`crate::query::captures_in`]
//! answers of that tree. The order is what the Lean model of the syntax
//! interface reproduces.
//!
//! # Highlights ([`Session::highlights`])
//!
//! A session may be given a [`Highlighter`] ([`Session::set_highlighter`]),
//! and then says what a snapshot of its text is drawn with, from the tree
//! delivered last, of revision M, for a snapshot of revision N. It is
//! asked once a frame, and what it answers is fixed for that frame:
//!
//! - with no highlighter, or nothing delivered yet, nothing: the text is
//!   drawn plain until the first parse arrives;
//! - when M is N, the tree delivered answers;
//! - when M is older, the tree delivered still answers, carried: the
//!   source is asked for the patch from M ([`Source::latest`]), and the
//!   spans are carried through it ([`crate::highlight`], "Carrying through
//!   a patch"). When the text has moved on past N, or the log has
//!   forgotten M, nothing, for that frame: the next one draws again;
//! - when M is newer (a scene of an old snapshot), nothing.
//!
//! So the old highlights stay, carried through the edits since, until the
//! reparse that replaces them is delivered, and an edit never waits for a
//! parse: a question of highlights takes the state lock, lets it go, and
//! then the source's, and never the work lock.
//!
//! # Locks
//!
//! A session has two: the *work* lock, over the parser and the base, which
//! only the round takes, so only the worker; and the *state* lock, over the
//! newest revision told, the result delivered and the consumers, which the
//! round takes only to deliver and [`Session::touch`] takes to tell. A
//! parse holds the work lock and no other: it takes the document's lock
//! only inside [`Source::latest`], and never the state lock while it
//! parses, so an edit's touch never waits for a parse. A consumer is
//! called under the state lock and must not call back into the session.

use std::ops::Range;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use editor_text::{Patch, Revision, Snapshot};

use crate::highlight::{Highlighter, Highlights};
use crate::port::{Capture, GrammarName, Syntax};
use crate::query::{captures_in, positions};

/// How the session reaches its text: the text as it is now and, when the
/// log can still say, what changed since a revision.
pub trait Source: Send + Sync {
    /// The text as it is now and, when `since` is given and the log can
    /// still say, the patch from `since` to it. `None` when the text is
    /// gone.
    ///
    /// The snapshot and the patch are taken together, so the patch reaches
    /// exactly the snapshot's revision.
    fn latest(&self, since: Option<Revision>) -> Option<Latest>;
}

/// What a [`Source`] answers.
#[derive(Clone)]
pub struct Latest {
    /// The text as it is now.
    pub snapshot: Snapshot,
    /// What changed from the revision asked about to the snapshot's, when
    /// one was asked about and the log can still say.
    pub patch: Option<Patch>,
}

/// A parse result, tagged with the revision it parsed.
pub struct Parsed<T> {
    /// The revision of the text the tree is of.
    pub revision: Revision,
    /// The text the tree is of.
    pub snapshot: Snapshot,
    /// The tree.
    pub tree: T,
}

/// What is handed each result a session delivers.
pub trait Consumer<T>: Send + Sync {
    /// `parsed` is delivered: its revision is at least every revision the
    /// session has been told of, and greater than every one delivered
    /// before. Called under the session's state lock: it must not call
    /// back into the session.
    fn deliver(&self, parsed: &Parsed<T>);
}

/// How a round ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// A tree of this revision was parsed and delivered.
    Delivered(Revision),
    /// A tree of this revision was parsed and not delivered: the session
    /// had been told of a newer revision by then.
    Stale(Revision),
    /// The text is still at the revision of the last tree parsed.
    UpToDate,
    /// The text is gone: the session has nothing more to do.
    Gone,
}

/// Why a question of captures was refused ([`Session::captures`]), in the
/// order the refusals are checked.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CapturesRefusal {
    /// The query is of another grammar than the session parses with.
    WrongGrammar,
    /// The range is not two positions of the snapshot's text in order.
    BadRange,
    /// No tree of the snapshot's revision is the one delivered last.
    NotParsed,
}

/// A tree as a round makes it ([`reparse`]).
pub struct Reparse<T> {
    /// The tree.
    pub tree: T,
    /// Whether it is the incremental parse's, kept: false for a whole
    /// parse, asked for or fallen back to.
    pub incremental: bool,
}

/// The tree of `text` as a round makes it: parsed with `old`, a tree of an
/// earlier text told every edit since, when there is one; and parsed whole
/// when there is none, or when the incremental parse's tree has an error or
/// a missing node (the fallback rule of the module docs).
pub fn reparse<S: Syntax>(
    syntax: &S,
    parser: &mut S::Parser,
    text: &Snapshot,
    old: Option<&S::Tree>,
) -> Reparse<S::Tree> {
    if let Some(old) = old {
        let tree = syntax.parse(parser, text, Some(old));
        if !syntax.has_errors(&tree) {
            return Reparse {
                tree,
                incremental: true,
            };
        }
    }
    Reparse {
        tree: syntax.parse(parser, text, None),
        incremental: false,
    }
}

/// One text's parse state.
pub struct Session<S: Syntax> {
    /// The grammar it parses with.
    grammar: GrammarName,
    /// Where the text is read.
    source: Box<dyn Source>,
    /// The parser and the base, which only a round takes.
    work: Mutex<Work<S>>,
    /// What the round delivers into and a touch tells.
    state: Mutex<State<S>>,
    /// Woken at each delivery.
    delivered: Condvar,
    /// Whether the session is in a worker's queue
    /// ([`crate::worker::Worker`]): a session is queued at most once.
    pub(crate) queued: AtomicBool,
}

/// What only a round takes.
struct Work<S: Syntax> {
    /// The parser.
    parser: S::Parser,
    /// The last tree parsed, delivered or not, with its revision.
    base: Option<(Revision, S::Tree)>,
}

/// What a round delivers into and a touch tells.
struct State<S: Syntax> {
    /// The newest revision the session has been told of or delivered.
    current: Revision,
    /// The last result delivered.
    delivered: Option<Arc<Parsed<S::Tree>>>,
    /// Who is handed each result.
    consumers: Vec<Box<dyn Consumer<S::Tree>>>,
    /// What the text is drawn with, once one is set.
    highlighter: Option<Arc<Highlighter<S::Query>>>,
}

/// `mutex`, locked. A round and a touch leave what they guard whole at
/// every point a panic could leave it, so a poisoned lock is used as it is.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

impl<S: Syntax> Session<S> {
    /// A session that parses the text `source` reads with `grammar`, which
    /// has been told of revision 0; `None` when `syntax` has no such
    /// grammar.
    pub fn new(syntax: &S, grammar: GrammarName, source: Box<dyn Source>) -> Option<Self> {
        let parser = syntax.parser(&grammar)?;
        Some(Self {
            grammar,
            source,
            work: Mutex::new(Work { parser, base: None }),
            state: Mutex::new(State {
                current: Revision::default(),
                delivered: None,
                consumers: Vec::new(),
                highlighter: None,
            }),
            delivered: Condvar::new(),
            queued: AtomicBool::new(false),
        })
    }

    /// The grammar it parses with.
    pub fn grammar(&self) -> &GrammarName {
        &self.grammar
    }

    /// Hands `consumer` every result delivered from now on.
    pub fn subscribe(&self, consumer: Box<dyn Consumer<S::Tree>>) {
        lock(&self.state).consumers.push(consumer);
    }

    /// Tells the session the text has reached `revision`. A revision older
    /// than one it has been told of changes nothing. Queueing it for a
    /// parse is the worker's ([`crate::worker::Handle::touch`]).
    pub fn touch(&self, revision: Revision) {
        let mut state = lock(&self.state);
        state.current = state.current.max(revision);
    }

    /// The newest revision the session has been told of or delivered.
    pub fn current(&self) -> Revision {
        lock(&self.state).current
    }

    /// The last result delivered, if any.
    pub fn parsed(&self) -> Option<Arc<Parsed<S::Tree>>> {
        lock(&self.state).delivered.clone()
    }

    /// The last result delivered once its revision is at least `revision`,
    /// waiting for a delivery up to `bound`; `None` when none has come by
    /// then. For tests, and for nothing on the editor thread.
    pub fn wait_for(&self, revision: Revision, bound: Duration) -> Option<Arc<Parsed<S::Tree>>> {
        let state = lock(&self.state);
        let reached = |state: &mut State<S>| {
            state
                .delivered
                .as_ref()
                .is_some_and(|parsed| parsed.revision >= revision)
        };
        let (mut state, _) = self
            .delivered
            .wait_timeout_while(state, bound, |state| !reached(state))
            .unwrap_or_else(PoisonError::into_inner);
        if reached(&mut state) {
            state.delivered.clone()
        } else {
            None
        }
    }

    /// Draws the text with `highlighter` from now on, in place of any
    /// before, and says whether there was one before.
    pub fn set_highlighter(&self, highlighter: Highlighter<S::Query>) -> bool {
        lock(&self.state)
            .highlighter
            .replace(Arc::new(highlighter))
            .is_some()
    }

    /// What `snapshot` is drawn with, as the module docs say
    /// ("Highlights"): none with no highlighter or nothing delivered, the
    /// tree delivered when it is of the snapshot's revision, the tree
    /// delivered carried through the log's patch when it is older, and
    /// none when the patch cannot be had of exactly the snapshot's
    /// revision, or the tree is newer.
    ///
    /// It takes the state lock and lets it go, and then the source's,
    /// never the work lock: it never waits for a parse.
    pub fn highlights(&self, snapshot: &Snapshot) -> Option<Highlights<S>> {
        let (parsed, highlighter) = {
            let state = lock(&self.state);
            (state.delivered.clone()?, state.highlighter.clone()?)
        };
        let revision = snapshot.revision();
        if parsed.revision == revision {
            return Some(Highlights::new(parsed, highlighter, None));
        }
        if parsed.revision > revision {
            return None;
        }
        let latest = self.source.latest(Some(parsed.revision))?;
        let patch = latest
            .patch
            .filter(|patch| patch.from == parsed.revision && patch.to == revision)?;
        (latest.snapshot.revision() == revision)
            .then(|| Highlights::new(parsed, highlighter, Some(patch)))
    }

    /// The captures of `query`, compiled for `grammar`, in `range` of
    /// `text`, from the tree delivered last when it is of `text`'s
    /// revision; or why not, as the module docs say.
    pub fn captures(
        &self,
        syntax: &S,
        grammar: &GrammarName,
        query: &S::Query,
        text: &Snapshot,
        range: Range<usize>,
    ) -> Result<Vec<Capture>, CapturesRefusal> {
        if *grammar != self.grammar {
            return Err(CapturesRefusal::WrongGrammar);
        }
        let range = positions(text, range).map_err(|_| CapturesRefusal::BadRange)?;
        let parsed = self
            .parsed()
            .filter(|parsed| parsed.revision == text.revision())
            .ok_or(CapturesRefusal::NotParsed)?;
        // The tree's text is of the same revision, so the range is one of
        // its positions too.
        captures_in(syntax, query, &parsed.tree, &parsed.snapshot, range)
            .map_err(|_| CapturesRefusal::BadRange)
    }

    /// One round, as the module docs say.
    pub fn parse_once(&self, syntax: &S) -> Outcome {
        let mut work = lock(&self.work);
        let since = work.base.as_ref().map(|(revision, _)| *revision);
        let Some(latest) = self.source.latest(since) else {
            return Outcome::Gone;
        };
        let revision = latest.snapshot.revision();
        if since == Some(revision) {
            return Outcome::UpToDate;
        }
        let Work { parser, base } = &mut *work;
        let edited = match (base.as_ref(), &latest.patch) {
            (Some((from, tree)), Some(patch)) if patch.from == *from && patch.to == revision => {
                let mut edited = tree.clone();
                for edit in &patch.edits {
                    syntax.edit(&mut edited, &edit.input_edit());
                }
                Some(edited)
            }
            _ => None,
        };
        let tree = reparse(syntax, parser, &latest.snapshot, edited.as_ref()).tree;
        *base = Some((revision, tree.clone()));
        drop(work);
        self.deliver(Parsed {
            revision,
            snapshot: latest.snapshot,
            tree,
        })
    }

    /// The delivery rule.
    fn deliver(&self, parsed: Parsed<S::Tree>) -> Outcome {
        let mut state = lock(&self.state);
        let revision = parsed.revision;
        if revision < state.current {
            return Outcome::Stale(revision);
        }
        state.current = revision;
        let parsed = Arc::new(parsed);
        for consumer in &state.consumers {
            consumer.deliver(&parsed);
        }
        state.delivered = Some(parsed);
        self.delivered.notify_all();
        Outcome::Delivered(revision)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use std::sync::Weak;

    use editor_text::{InputEdit, Text};

    use super::*;
    use crate::fake::{GRAMMAR, Parens, ParensParser, ParensQuery, ParensTree};
    use crate::highlight::Highlighter;
    use crate::port::{Node, QueryError, QueryKind};

    /// A text behind a lock, as a document holds one, read as a source.
    pub(crate) struct TextSource(pub(crate) Weak<Mutex<Text>>);

    impl Source for TextSource {
        fn latest(&self, since: Option<Revision>) -> Option<Latest> {
            let text = self.0.upgrade()?;
            let text = lock(&text);
            Some(Latest {
                snapshot: text.snapshot(),
                patch: since.and_then(|since| text.changes_since(since).ok()),
            })
        }
    }

    /// The fake, recording what each parse was handed as its old tree (the
    /// edits that tree was told, or `None` for a whole parse), and running
    /// a hook once, inside the next parse.
    ///
    /// With `recovers_otherwise`, it recovers from an error as a real
    /// library may: an incremental parse whose tree has an error or a
    /// missing node answers another tree than a fresh parse would, the
    /// tree of the text with one more atom.
    #[derive(Default)]
    pub(crate) struct Recording {
        pub(crate) olds: Mutex<Vec<Option<Vec<InputEdit>>>>,
        pub(crate) asked: Mutex<Vec<Range<usize>>>,
        pub(crate) hook: Mutex<Option<Box<dyn FnOnce() + Send>>>,
        pub(crate) recovers_otherwise: bool,
    }

    impl Syntax for Recording {
        type Parser = ParensParser;
        type Tree = ParensTree;
        type Query = ParensQuery;

        fn grammars(&self) -> Vec<GrammarName> {
            Parens.grammars()
        }
        fn parser(&self, grammar: &GrammarName) -> Option<ParensParser> {
            Parens.parser(grammar)
        }
        fn parse(
            &self,
            parser: &mut ParensParser,
            text: &Snapshot,
            old: Option<&ParensTree>,
        ) -> ParensTree {
            lock(&self.olds).push(old.map(|old| old.edits().to_vec()));
            if let Some(hook) = lock(&self.hook).take() {
                hook();
            }
            let tree = Parens.parse(parser, text, old);
            if self.recovers_otherwise && old.is_some() && Parens.has_errors(&tree) {
                let other = Text::from(format!("{text} x").as_str()).snapshot();
                return Parens.parse(parser, &other, None);
            }
            tree
        }
        fn edit(&self, tree: &mut ParensTree, edit: &InputEdit) {
            Parens.edit(tree, edit);
        }
        fn compile(&self, grammar: &GrammarName, source: &str) -> Result<ParensQuery, QueryError> {
            Parens.compile(grammar, source)
        }
        fn shipped_query(&self, grammar: &GrammarName, kind: crate::QueryKind) -> Option<String> {
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
            lock(&self.asked).push(range.clone());
            Parens.captures(query, tree, text, range)
        }
        fn nodes(&self, tree: &ParensTree) -> Vec<Node> {
            Parens.nodes(tree)
        }
        fn has_errors(&self, tree: &ParensTree) -> bool {
            Parens.has_errors(tree)
        }
    }

    /// A consumer that records the revisions it is handed.
    pub(crate) struct Revisions(pub(crate) Arc<Mutex<Vec<Revision>>>);

    impl<T> Consumer<T> for Revisions {
        fn deliver(&self, parsed: &Parsed<T>) {
            lock(&self.0).push(parsed.revision);
        }
    }

    /// A text, a session over it with the recording syntax, and the
    /// revisions its consumer has been handed.
    struct Fixture {
        text: Arc<Mutex<Text>>,
        syntax: Recording,
        session: Arc<Session<Recording>>,
        delivered: Arc<Mutex<Vec<Revision>>>,
    }

    impl Fixture {
        fn new(text: &str) -> Self {
            Self::with(text, Recording::default())
        }

        /// A fixture whose syntax is `syntax`.
        fn with(text: &str, syntax: Recording) -> Self {
            let text = Arc::new(Mutex::new(Text::from(text)));
            let session = Session::new(
                &syntax,
                GrammarName::new(GRAMMAR),
                Box::new(TextSource(Arc::downgrade(&text))),
            )
            .unwrap();
            let delivered = Arc::new(Mutex::new(Vec::new()));
            session.subscribe(Box::new(Revisions(delivered.clone())));
            Self {
                text,
                syntax,
                session: Arc::new(session),
                delivered,
            }
        }

        /// Replaces `range` with `with`, and returns the revision.
        fn replace(&self, range: Range<usize>, with: &str) -> Revision {
            replace(&self.text, range, with)
        }

        fn delivered(&self) -> Vec<Revision> {
            lock(&self.delivered).clone()
        }

        fn olds(&self) -> Vec<Option<Vec<InputEdit>>> {
            lock(&self.syntax.olds).clone()
        }

        /// Whether the delivered tree equals a fresh parse of the text now.
        fn delivered_is_fresh(&self) -> bool {
            let snapshot = lock(&self.text).snapshot();
            let fresh = Parens.parse(&mut ParensParser, &snapshot, None);
            self.session.parsed().is_some_and(|parsed| {
                parsed.revision == snapshot.revision()
                    && Parens.nodes(&parsed.tree) == Parens.nodes(&fresh)
            })
        }
    }

    /// Replaces `range` of `text` with `with`, and returns the revision.
    pub(crate) fn replace(text: &Mutex<Text>, range: Range<usize>, with: &str) -> Revision {
        let mut text = lock(text);
        text.replace(range, with).unwrap();
        text.current().revision()
    }

    #[test]
    fn a_grammar_the_syntax_lacks_makes_no_session() {
        let text = Arc::new(Mutex::new(Text::from("")));
        let source = Box::new(TextSource(Arc::downgrade(&text)));

        assert!(Session::new(&Parens, GrammarName::new("rust"), source).is_none());
    }

    #[test]
    fn the_first_round_parses_the_whole_text_and_delivers_it() {
        let fixture = Fixture::new("(a b)");

        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::Delivered(Revision::new(0))
        );
        assert_eq!(fixture.olds(), [None]);
        assert_eq!(fixture.delivered(), [Revision::new(0)]);
        assert!(fixture.delivered_is_fresh());
    }

    #[test]
    fn a_round_with_nothing_new_parses_nothing() {
        let fixture = Fixture::new("(a b)");
        fixture.session.parse_once(&fixture.syntax);

        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::UpToDate
        );
        assert_eq!(fixture.olds().len(), 1);
        assert_eq!(fixture.delivered(), [Revision::new(0)]);
    }

    #[test]
    fn a_round_after_edits_reparses_with_the_base_told_the_patchs_edits_in_order() {
        let fixture = Fixture::new("(a b)\n(c)");
        fixture.session.parse_once(&fixture.syntax);
        fixture.replace(1..2, "xyz");
        fixture.replace(0..0, "w ");
        let patch = lock(&fixture.text).changes_since(Revision::new(0)).unwrap();

        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::Delivered(Revision::new(2))
        );
        let told: Vec<InputEdit> = patch.edits.iter().map(|edit| edit.input_edit()).collect();
        assert_eq!(patch.edits.len(), 2);
        assert_eq!(fixture.olds(), [None, Some(told)]);
        assert!(fixture.delivered_is_fresh());
    }

    #[test]
    fn an_incremental_reparse_whose_tree_has_an_error_is_dropped_for_a_whole_parse() {
        let fixture = Fixture::with(
            "(a b)",
            Recording {
                recovers_otherwise: true,
                ..Recording::default()
            },
        );
        fixture.session.parse_once(&fixture.syntax);
        let revision = fixture.replace(0..0, "(");
        let patch = lock(&fixture.text).changes_since(Revision::new(0)).unwrap();

        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::Delivered(revision)
        );
        let told: Vec<InputEdit> = patch.edits.iter().map(|edit| edit.input_edit()).collect();
        assert_eq!(fixture.olds(), [None, Some(told), None]);
        assert!(fixture.delivered_is_fresh());
    }

    #[test]
    fn an_incremental_reparse_whose_tree_has_no_error_is_kept() {
        let fixture = Fixture::with(
            "(a b",
            Recording {
                recovers_otherwise: true,
                ..Recording::default()
            },
        );
        fixture.session.parse_once(&fixture.syntax);
        let revision = fixture.replace(4..4, ")");

        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::Delivered(revision)
        );
        assert_eq!(fixture.olds().len(), 2);
        assert!(fixture.olds()[1].is_some());
        assert!(fixture.delivered_is_fresh());
    }

    #[test]
    fn a_log_that_has_forgotten_the_base_gives_a_whole_parse() {
        let fixture = Fixture::new("(a b)");
        fixture.session.parse_once(&fixture.syntax);
        let revision = fixture.replace(0..0, "x ");
        lock(&fixture.text).forget(revision).unwrap();

        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::Delivered(revision)
        );
        assert_eq!(fixture.olds(), [None, None]);
        assert!(fixture.delivered_is_fresh());
    }

    /// A source whose patches claim to start a revision later than asked.
    struct Unchained(TextSource);

    impl Source for Unchained {
        fn latest(&self, since: Option<Revision>) -> Option<Latest> {
            let mut latest = self.0.latest(since)?;
            if let Some(patch) = &mut latest.patch {
                patch.from = Revision::new(patch.from.get() + 1);
            }
            Some(latest)
        }
    }

    #[test]
    fn a_patch_that_does_not_chain_from_the_base_gives_a_whole_parse() {
        let text = Arc::new(Mutex::new(Text::from("(a)")));
        let syntax = Recording::default();
        let source = Box::new(Unchained(TextSource(Arc::downgrade(&text))));
        let session = Session::new(&syntax, GrammarName::new(GRAMMAR), source).unwrap();
        session.parse_once(&syntax);
        replace(&text, 0..0, "b ");

        assert_eq!(
            session.parse_once(&syntax),
            Outcome::Delivered(Revision::new(1))
        );
        assert_eq!(lock(&syntax.olds).clone(), [None, None]);
    }

    #[test]
    fn a_text_that_is_gone_ends_the_session() {
        let fixture = Fixture::new("(a)");
        let Fixture {
            text,
            syntax,
            session,
            ..
        } = fixture;
        drop(text);

        assert_eq!(session.parse_once(&syntax), Outcome::Gone);
        assert!(session.parsed().is_none());
    }

    #[test]
    fn a_result_older_than_the_current_revision_is_not_delivered() {
        let fixture = Fixture::new("(a b)");
        fixture.replace(0..0, "x ");
        // Inside the parse of revision 1, the text is edited to revision 2
        // and the session is told so.
        let (text, session) = (fixture.text.clone(), fixture.session.clone());
        *lock(&fixture.syntax.hook) = Some(Box::new(move || {
            let revision = replace(&text, 0..0, "y ");
            session.touch(revision);
        }));
        fixture.session.touch(Revision::new(1));

        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::Stale(Revision::new(1))
        );
        assert_eq!(fixture.delivered(), []);
        assert!(fixture.session.parsed().is_none());

        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::Delivered(Revision::new(2))
        );
        assert_eq!(fixture.delivered(), [Revision::new(2)]);
        assert!(fixture.delivered_is_fresh());
    }

    #[test]
    fn a_stale_result_is_the_base_of_the_next_parse() {
        let fixture = Fixture::new("(a b)");
        fixture.replace(0..0, "x ");
        let (text, session) = (fixture.text.clone(), fixture.session.clone());
        *lock(&fixture.syntax.hook) = Some(Box::new(move || {
            let revision = replace(&text, 1..1, "z");
            session.touch(revision);
        }));
        fixture.session.parse_once(&fixture.syntax);
        let patch = lock(&fixture.text).changes_since(Revision::new(1)).unwrap();

        fixture.session.parse_once(&fixture.syntax);
        let told: Vec<InputEdit> = patch.edits.iter().map(|edit| edit.input_edit()).collect();
        assert_eq!(fixture.olds(), [None, Some(told)]);
    }

    #[test]
    fn a_late_touch_does_not_lower_the_current_revision() {
        let fixture = Fixture::new("");
        fixture.session.touch(Revision::new(5));
        fixture.session.touch(Revision::new(3));

        assert_eq!(fixture.session.current(), Revision::new(5));
    }

    #[test]
    fn a_result_newer_than_the_last_touch_is_delivered() {
        // The worker can see an edit before the edit's touch arrives.
        let fixture = Fixture::new("(a)");
        fixture.replace(0..0, "b ");
        fixture.replace(0..0, "c ");

        assert_eq!(
            fixture.session.parse_once(&fixture.syntax),
            Outcome::Delivered(Revision::new(2))
        );
        assert_eq!(fixture.session.current(), Revision::new(2));
        fixture.session.touch(Revision::new(1));
        assert_eq!(fixture.session.current(), Revision::new(2));
    }

    #[test]
    fn waiting_for_a_revision_answers_the_delivered_result_once_it_reaches_it() {
        let fixture = Fixture::new("(a)");

        assert!(
            fixture
                .session
                .wait_for(Revision::new(0), Duration::ZERO)
                .is_none()
        );
        fixture.session.parse_once(&fixture.syntax);
        let parsed = fixture.session.wait_for(Revision::new(0), Duration::ZERO);
        assert_eq!(parsed.map(|parsed| parsed.revision), Some(Revision::new(0)));
        assert!(
            fixture
                .session
                .wait_for(Revision::new(1), Duration::ZERO)
                .is_none()
        );
    }

    /// The captures of every atom and list, in `range` of `snapshot`, as
    /// the session answers them with a query compiled for its grammar,
    /// said to be of `grammar`.
    fn captures(
        fixture: &Fixture,
        grammar: &str,
        snapshot: &Snapshot,
        range: Range<usize>,
    ) -> Result<Vec<Capture>, CapturesRefusal> {
        let query = Parens
            .compile(&GrammarName::new(GRAMMAR), "atom @atom\nlist @list")
            .unwrap();
        fixture.session.captures(
            &fixture.syntax,
            &GrammarName::new(grammar),
            &query,
            snapshot,
            range,
        )
    }

    #[test]
    fn a_question_of_captures_is_refused_for_its_grammar_then_its_range_then_a_tree_not_parsed() {
        let fixture = Fixture::new("(é)");
        let snapshot = lock(&fixture.text).snapshot();

        assert_eq!(
            captures(&fixture, "rust", &snapshot, 2..4),
            Err(CapturesRefusal::WrongGrammar)
        );
        assert_eq!(
            captures(&fixture, GRAMMAR, &snapshot, 2..4),
            Err(CapturesRefusal::BadRange)
        );
        assert_eq!(
            captures(&fixture, GRAMMAR, &snapshot, Range { start: 3, end: 1 }),
            Err(CapturesRefusal::BadRange)
        );
        assert_eq!(
            captures(&fixture, GRAMMAR, &snapshot, 0..5),
            Err(CapturesRefusal::BadRange)
        );
        assert_eq!(
            captures(&fixture, GRAMMAR, &snapshot, 0..4),
            Err(CapturesRefusal::NotParsed)
        );
        fixture.session.parse_once(&fixture.syntax);
        assert_eq!(
            captures(&fixture, "rust", &snapshot, 0..4),
            Err(CapturesRefusal::WrongGrammar)
        );
        assert_eq!(
            captures(&fixture, GRAMMAR, &snapshot, 0..5),
            Err(CapturesRefusal::BadRange)
        );
    }

    #[test]
    fn captures_are_answered_only_from_a_delivered_tree_of_the_snapshots_own_revision() {
        let fixture = Fixture::new("(a b)");
        let first = lock(&fixture.text).snapshot();
        fixture.session.parse_once(&fixture.syntax);
        let ranges = |answer: Result<Vec<Capture>, CapturesRefusal>| {
            answer.map(|captures| captures.iter().map(Capture::range).collect::<Vec<_>>())
        };

        assert_eq!(
            ranges(captures(&fixture, GRAMMAR, &first, 0..5)),
            Ok(vec![0..5, 1..2, 3..4])
        );
        fixture.replace(5..5, " c");
        let second = lock(&fixture.text).snapshot();
        // The tree delivered is of the first revision still.
        assert_eq!(
            captures(&fixture, GRAMMAR, &second, 0..7),
            Err(CapturesRefusal::NotParsed)
        );
        assert_eq!(
            ranges(captures(&fixture, GRAMMAR, &first, 3..4)),
            Ok(vec![0..5, 3..4])
        );
        fixture.session.parse_once(&fixture.syntax);
        // Now it is of the second: a tree newer than the snapshot answers
        // nothing either.
        assert_eq!(
            captures(&fixture, GRAMMAR, &first, 0..5),
            Err(CapturesRefusal::NotParsed)
        );
        assert_eq!(
            ranges(captures(&fixture, GRAMMAR, &second, 3..7)),
            Ok(vec![0..5, 3..4, 6..7])
        );
    }

    /// The fake's shipped highlights, each capture drawn in a face named
    /// after it.
    fn parens_highlighter() -> Highlighter<ParensQuery> {
        let grammar = GrammarName::new(GRAMMAR);
        let source = Parens
            .shipped_query(&grammar, QueryKind::Highlights)
            .unwrap();
        let query = Parens.compile(&grammar, &source).unwrap();
        let names = Parens.capture_names(&query);
        let faces = names
            .iter()
            .map(|name| Some(format!("syntax.{name}")))
            .collect();
        Highlighter::new(Arc::new(query), names.len(), faces).unwrap()
    }

    /// The spans `session` draws over the whole of `snapshot`, each with
    /// the name of its face; none when it draws nothing.
    fn highlighted(
        syntax: &Recording,
        session: &Session<Recording>,
        snapshot: &Snapshot,
    ) -> Option<Vec<(Range<usize>, String)>> {
        let highlights = session.highlights(snapshot)?;
        let mut spans = Vec::new();
        highlights.spans(syntax, 0..snapshot.len(), &mut spans);
        Some(
            spans
                .into_iter()
                .map(|span| (span.bytes, highlights.faces()[span.face].clone()))
                .collect(),
        )
    }

    /// The fresh highlights of `snapshot`, each with the name of its face.
    fn fresh_of(snapshot: &Snapshot) -> Vec<(Range<usize>, String)> {
        let highlighter = parens_highlighter();
        crate::highlight::fresh(&Parens, &highlighter, &mut ParensParser, snapshot)
            .into_iter()
            .map(|span| (span.bytes, highlighter.names()[span.face].clone()))
            .collect()
    }

    #[test]
    fn no_highlights_before_the_first_delivery_or_without_a_highlighter() {
        let fixture = Fixture::new("(a b)");
        let snapshot = lock(&fixture.text).snapshot();
        fixture.session.parse_once(&fixture.syntax);
        // Delivered, but no highlighter.
        assert!(fixture.session.highlights(&snapshot).is_none());

        let fixture = Fixture::new("(a b)");
        assert!(!fixture.session.set_highlighter(parens_highlighter()));
        assert!(fixture.session.highlights(&snapshot).is_none());
        fixture.session.parse_once(&fixture.syntax);
        assert_eq!(
            highlighted(&fixture.syntax, &fixture.session, &snapshot),
            Some(fresh_of(&snapshot))
        );
        // A second highlighter replaces the first.
        assert!(fixture.session.set_highlighter(parens_highlighter()));
    }

    #[test]
    fn the_highlights_of_a_newer_snapshot_are_the_delivered_ones_carried() {
        let fixture = Fixture::new("(ab cd)");
        fixture.session.set_highlighter(parens_highlighter());
        fixture.session.parse_once(&fixture.syntax);
        // `x` typed inside `ab`, told and not parsed.
        let revision = fixture.replace(2..2, "x");
        fixture.session.touch(revision);
        let snapshot = lock(&fixture.text).snapshot();

        let carried = highlighted(&fixture.syntax, &fixture.session, &snapshot).unwrap();
        // Revision 0's spans, carried around the `x`, which is plain: not
        // none, and not what a fresh parse of revision 1 draws.
        assert_eq!(
            carried,
            [
                (0..2, "syntax.list".to_owned()),
                (3..8, "syntax.list".to_owned()),
                (0..1, "syntax.punctuation.bracket".to_owned()),
                (1..2, "syntax.variable".to_owned()),
                (3..4, "syntax.variable".to_owned()),
                (5..7, "syntax.variable".to_owned()),
                (7..8, "syntax.punctuation.bracket".to_owned()),
            ]
        );
        assert_ne!(carried, fresh_of(&snapshot));
        assert_eq!(
            fixture.session.highlights(&snapshot).unwrap().revision(),
            Revision::new(0)
        );
    }

    #[test]
    fn the_delivered_highlights_replace_the_carried_ones() {
        let fixture = Fixture::new("(ab cd)");
        fixture.session.set_highlighter(parens_highlighter());
        fixture.session.parse_once(&fixture.syntax);
        let revision = fixture.replace(2..2, "x");
        fixture.session.touch(revision);
        let snapshot = lock(&fixture.text).snapshot();

        fixture.session.parse_once(&fixture.syntax);
        assert_eq!(
            highlighted(&fixture.syntax, &fixture.session, &snapshot),
            Some(fresh_of(&snapshot))
        );
    }

    #[test]
    fn a_published_snapshot_the_text_has_moved_past_draws_nothing() {
        let fixture = Fixture::new("(a b)");
        fixture.session.set_highlighter(parens_highlighter());
        fixture.session.parse_once(&fixture.syntax);
        fixture.replace(0..0, "x ");
        let published = lock(&fixture.text).snapshot();
        // The text moves on past the snapshot published.
        fixture.replace(0..0, "y ");

        assert!(fixture.session.highlights(&published).is_none());
        // A snapshot older than the tree delivered draws nothing either.
        let first = Text::from("(a b)").snapshot();
        fixture.session.parse_once(&fixture.syntax);
        assert!(fixture.session.highlights(&first).is_none());
    }

    #[test]
    fn a_log_that_has_forgotten_the_delivered_revision_draws_nothing() {
        let fixture = Fixture::new("(a b)");
        fixture.session.set_highlighter(parens_highlighter());
        fixture.session.parse_once(&fixture.syntax);
        let revision = fixture.replace(0..0, "x ");
        lock(&fixture.text).forget(revision).unwrap();
        let snapshot = lock(&fixture.text).snapshot();

        assert!(fixture.session.highlights(&snapshot).is_none());
    }

    #[test]
    fn the_query_is_asked_only_of_the_range_mapped_back() {
        let fixture = Fixture::new("(a)\n(bb)\n(c)\n");
        fixture.session.set_highlighter(parens_highlighter());
        fixture.session.parse_once(&fixture.syntax);
        // `zz` put in at the start of the second row: revision 0's second
        // row, 4..8, is 6..10 now.
        let revision = fixture.replace(4..4, "zz");
        fixture.session.touch(revision);
        let snapshot = lock(&fixture.text).snapshot();
        let highlights = fixture.session.highlights(&snapshot).unwrap();
        lock(&fixture.syntax.asked).clear();

        let mut spans = Vec::new();
        highlights.spans(&fixture.syntax, 6..10, &mut spans);
        // The port is asked the range mapped back, a byte wider each side.
        assert_eq!(lock(&fixture.syntax.asked).clone(), vec![3..9]);
        let ranges: Vec<Range<usize>> = spans.into_iter().map(|span| span.bytes).collect();
        assert_eq!(ranges, [6..10, 6..7, 7..9, 9..10]);
    }

    #[test]
    fn a_session_knows_its_grammar_and_a_delivered_text_is_the_snapshot_parsed() {
        let fixture = Fixture::new("(a)");
        fixture.session.parse_once(&fixture.syntax);

        assert_eq!(fixture.session.grammar().as_str(), GRAMMAR);
        let parsed = fixture.session.parsed().unwrap();
        assert_eq!(parsed.snapshot.to_string(), "(a)");
    }
}
