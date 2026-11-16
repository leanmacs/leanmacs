//! Highlights while a parse is in progress, with the worker on a real
//! thread: an edit and its touch do not wait for the parse, the highlights
//! asked meanwhile are the delivered ones carried through the edits, and
//! once the parse is let go the highlights are a fresh highlight's.
//!
//! Nothing sleeps, and the test fails rather than hangs. Every wait is
//! bounded by [`BOUND`] (a timeout fails with what waited), and the parse
//! held is let go on every path, a failed assertion included, by a drop
//! guard ([`Release`]) that drops before the scope joins its threads.

use std::ops::Range;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::thread;
use std::time::Duration;

use editor_syntax::fake::{GRAMMAR, Parens, ParensParser, ParensQuery, ParensTree};
use editor_syntax::highlight::{self, Highlighter};
use editor_syntax::{
    Capture, GrammarName, Handle, Latest, Node, QueryError, QueryKind, Session, Source, Syntax,
    Worker,
};
use editor_text::{InputEdit, Revision, Snapshot, Text};

/// The longest any step waits: far above any real wait.
const BOUND: Duration = Duration::from_secs(10);

/// `mutex`, locked, poisoned or not.
fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// A text behind a lock, as a document holds one.
struct TextSource(Weak<Mutex<Text>>);

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

/// The fake, whose parse, while its gate is closed, tells the test it has
/// started and then waits to be let go: on a release, or on the release's
/// sender dropped.
struct Gated {
    /// Whether a parse waits.
    closed: Arc<AtomicBool>,
    /// Told when a parse starts waiting.
    entered: Mutex<Sender<()>>,
    /// What a waiting parse waits on.
    release: Mutex<Receiver<()>>,
}

impl Syntax for Gated {
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
        if self.closed.load(Ordering::Acquire) {
            // The test may have stopped listening: it is failing already.
            let _ = lock(&self.entered).send(());
            // A release, or the sender dropped, lets it go.
            let _ = lock(&self.release).recv();
        }
        Parens.parse(parser, text, old)
    }
    fn edit(&self, tree: &mut ParensTree, edit: &InputEdit) {
        Parens.edit(tree, edit);
    }
    fn compile(&self, grammar: &GrammarName, source: &str) -> Result<ParensQuery, QueryError> {
        Parens.compile(grammar, source)
    }
    fn shipped_query(&self, grammar: &GrammarName, kind: QueryKind) -> Option<String> {
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
    ) -> Vec<editor_syntax::Match> {
        Parens.matches(query, tree, text, range)
    }
    fn pattern_settings(&self, query: &ParensQuery, pattern: usize) -> Vec<editor_syntax::Setting> {
        Parens.pattern_settings(query, pattern)
    }
    fn parse_in(
        &self,
        parser: &mut ParensParser,
        text: &Snapshot,
        ranges: &[Range<usize>],
    ) -> ParensTree {
        Parens.parse_in(parser, text, ranges)
    }
    fn nodes(&self, tree: &ParensTree) -> Vec<Node> {
        Parens.nodes(tree)
    }
    fn has_errors(&self, tree: &ParensTree) -> bool {
        Parens.has_errors(tree)
    }
}

/// Lets every parse go when it drops: the gate opened, and the sender a
/// waiting parse listens on dropped, which lets it go as a release does.
/// It drops on every path, a failed assertion included, before the scope
/// joins the worker and the editing thread.
struct Release {
    /// The gate.
    closed: Arc<AtomicBool>,
    /// The sender, until it is dropped.
    sender: Option<Sender<()>>,
}

impl Drop for Release {
    fn drop(&mut self) {
        self.closed.store(false, Ordering::Release);
        self.sender.take();
    }
}

/// Stops the worker's loop when it drops, on every path, so the scope's
/// join of the worker's thread returns.
struct Stop<'a>(&'a Handle<Gated>);

impl Drop for Stop<'_> {
    fn drop(&mut self) {
        self.0.stop();
    }
}

/// The fake's shipped highlights, each capture drawn in a face named after
/// it.
fn highlighter() -> Highlighter<ParensQuery> {
    let grammar = GrammarName::new(GRAMMAR);
    let source = Parens
        .shipped_query(&grammar, QueryKind::Highlights)
        .unwrap();
    let query = Parens.compile(&grammar, &source).unwrap();
    let names = Parens.capture_names(&query);
    let faces = names.iter().map(|name| Some(name.clone())).collect();
    Highlighter::new(Arc::new(query), names.len(), faces).unwrap()
}

/// The spans `session` draws over the whole of `snapshot`, each with its
/// face's name: none when it draws nothing.
fn drawn(
    syntax: &Gated,
    session: &Session<Gated>,
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

/// A fresh highlight of `snapshot`, each span with its face's name.
fn fresh(snapshot: &Snapshot) -> Vec<(Range<usize>, String)> {
    let highlighter = highlighter();
    highlight::fresh(&Parens, &highlighter, &mut ParensParser, snapshot)
        .into_iter()
        .map(|span| (span.bytes, highlighter.names()[span.face].clone()))
        .collect()
}

/// Replaces `range` of `text` with `with`, and returns the revision.
fn replace(text: &Mutex<Text>, range: Range<usize>, with: &str) -> Revision {
    let mut text = lock(text);
    text.replace(range, with).unwrap();
    text.current().revision()
}

#[test]
fn an_edit_during_a_parse_does_not_wait_for_it() {
    let text = Arc::new(Mutex::new(Text::from("(ab cd)\n(ef)\n")));
    let closed = Arc::new(AtomicBool::new(false));
    let (entered_sender, entered) = mpsc::channel();
    let (release_sender, release) = mpsc::channel();
    let syntax = Arc::new(Gated {
        closed: closed.clone(),
        entered: Mutex::new(entered_sender),
        release: Mutex::new(release),
    });
    let source = Box::new(TextSource(Arc::downgrade(&text)));
    let session = Arc::new(Session::new(&*syntax, GrammarName::new(GRAMMAR), source).unwrap());
    session.set_highlighter(highlighter());
    let worker = Worker::new(syntax.clone());
    let handle = worker.handle();
    let first = lock(&text).snapshot();

    thread::scope(|scope| {
        scope.spawn(|| worker.run());
        // Declared in the scope, so both drop, on any path, before the
        // scope joins its threads: the stop first, the release then.
        let release = Release {
            closed: closed.clone(),
            sender: Some(release_sender),
        };
        let _stop = Stop(&handle);

        // Revision 0 is delivered with the gate open.
        handle.touch(&session, first.revision());
        assert!(
            session.wait_for(first.revision(), BOUND).is_some(),
            "revision 0 was not delivered"
        );
        assert_eq!(drawn(&syntax, &session, &first), Some(fresh(&first)));

        // 1. Hold the parse: the gate closed, an edit told, and the worker
        // inside its parse, holding the session's work lock.
        closed.store(true, Ordering::Release);
        handle.touch(&session, replace(&text, 2..2, "x"));
        entered
            .recv_timeout(BOUND)
            .expect("the worker never started the parse");

        // 2. Another edit and its touch, on another thread, bounded.
        let (done_sender, done) = mpsc::channel();
        let (text, handle, session) = (&text, &handle, &session);
        scope.spawn(move || {
            let revision = replace(text, 10..10, " gh");
            handle.touch(session, revision);
            let _ = done_sender.send(());
        });
        done.recv_timeout(BOUND)
            .expect("an edit or its touch waited for a parse in progress");
        let third = lock(text).snapshot();
        assert_eq!(third.revision(), Revision::new(2));

        // 3. The highlights of revision 2, asked on another thread while
        // the parse is still held, bounded: revision 0's, carried through
        // the patch.
        let (spans_sender, spans) = mpsc::channel();
        let (syntax, asked) = (&syntax, third.clone());
        scope.spawn(move || {
            let _ = spans_sender.send(drawn(syntax, session, &asked));
        });
        let carried = spans
            .recv_timeout(BOUND)
            .expect("reading highlights waited for a parse in progress")
            .expect("highlights of a newer snapshot than the tree delivered");
        let patch = lock(text).changes_since(first.revision()).unwrap();
        let expected: Vec<(Range<usize>, String)> = fresh(&first)
            .into_iter()
            .flat_map(|(bytes, face)| {
                highlight::carry(&patch, bytes)
                    .into_iter()
                    .map(move |part| (part, face.clone()))
            })
            .collect();
        assert_eq!(carried, expected);
        assert_ne!(carried, fresh(&third));

        // 4. Let the parse go, wait for revision 2, bounded: the highlights
        // are now a fresh highlight's.
        drop(release);
        assert!(
            session.wait_for(third.revision(), BOUND).is_some(),
            "revision 2 was not delivered once the parse was let go"
        );
        assert_eq!(drawn(syntax, session, &third), Some(fresh(&third)));
    });
}
