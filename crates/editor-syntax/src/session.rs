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
//! 3. The result is the new base, delivered or not.
//! 4. **The delivery rule.** The result is delivered only if its revision is
//!    at least the newest the session has been told of
//!    ([`Session::touch`]). Delivering sets that revision to the result's,
//!    keeps the result ([`Session::parsed`]) and hands it to each consumer.
//!    A result older than a revision the session has been told of is
//!    [`Outcome::Stale`]: nobody sees it, and it serves only as the base of
//!    the next parse. So the revisions delivered only grow, and a result
//!    tagged with a revision older than the current one is never handed
//!    out.
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

use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use editor_text::{Patch, Revision, Snapshot};

use crate::port::{GrammarName, Syntax};

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

/// One text's parse state.
pub struct Session<S: Syntax> {
    /// The grammar it parses with.
    grammar: GrammarName,
    /// Where the text is read.
    source: Box<dyn Source>,
    /// The parser and the base, which only a round takes.
    work: Mutex<Work<S>>,
    /// What the round delivers into and a touch tells.
    state: Mutex<State<S::Tree>>,
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
struct State<T> {
    /// The newest revision the session has been told of or delivered.
    current: Revision,
    /// The last result delivered.
    delivered: Option<Arc<Parsed<T>>>,
    /// Who is handed each result.
    consumers: Vec<Box<dyn Consumer<T>>>,
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
        let reached = |state: &mut State<S::Tree>| {
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
        let tree = syntax.parse(parser, &latest.snapshot, edited.as_ref());
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
    use std::ops::Range;
    use std::sync::Weak;

    use editor_text::{InputEdit, Text};

    use super::*;
    use crate::fake::{GRAMMAR, Parens, ParensParser, ParensQuery, ParensTree};
    use crate::port::{Capture, Node, QueryError};

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
    #[derive(Default)]
    pub(crate) struct Recording {
        pub(crate) olds: Mutex<Vec<Option<Vec<InputEdit>>>>,
        pub(crate) hook: Mutex<Option<Box<dyn FnOnce() + Send>>>,
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
            Parens.parse(parser, text, old)
        }
        fn edit(&self, tree: &mut ParensTree, edit: &InputEdit) {
            Parens.edit(tree, edit);
        }
        fn compile(&self, grammar: &GrammarName, source: &str) -> Result<ParensQuery, QueryError> {
            Parens.compile(grammar, source)
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
        fn nodes(&self, tree: &ParensTree) -> Vec<Node> {
            Parens.nodes(tree)
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
            let text = Arc::new(Mutex::new(Text::from(text)));
            let syntax = Recording::default();
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
        fixture.replace(0..0, "(");
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

    #[test]
    fn a_session_knows_its_grammar_and_a_delivered_text_is_the_snapshot_parsed() {
        let fixture = Fixture::new("(a)");
        fixture.session.parse_once(&fixture.syntax);

        assert_eq!(fixture.session.grammar().as_str(), GRAMMAR);
        let parsed = fixture.session.parsed().unwrap();
        assert_eq!(parsed.snapshot.to_string(), "(a)");
    }
}
