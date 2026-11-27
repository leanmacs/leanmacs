//! The idle refresh on the real Rust grammar: a worker on a manual clock,
//! stepped by hand, follows edits that break the syntax and mend it, each
//! reparsed incrementally; once the clock passes the idle interval, the
//! tree delivered and what it draws are a fresh parse's and a fresh
//! highlight's, while the text still has its error and after it is mended.
//!
//! Timing is the worker's rule, pinned by `editor-syntax`'s own tests; this
//! is the real grammar's wiring of it. Nothing sleeps. The grammar is
//! registered from the native library `editor-syntax-fixture-grammars`
//! builds, and drawn with the highlights staged beside it.

use std::ops::Range;
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::time::Duration;

use editor_syntax::clock::ManualClock;
use editor_syntax::highlight::{self, HighlightSpan, Highlighter};
use editor_syntax::{
    GrammarName, GrammarSource, Latest, ReparsePolicy, Session, Source, Syntax, Worker,
};
use editor_syntax_fixture_grammars::RUST;
use editor_syntax_treesitter::{TreeSitter, TreeSitterQuery};
use editor_text::{Revision, Snapshot, Text};

/// The text edited.
const ITEMS: &str = include_str!("../../../tests/syntax/rust/items.rs");

/// The worker's idle interval.
const INTERVAL: Duration = Duration::from_millis(500);

/// A text behind a lock, as a document holds one.
struct TextSource(Weak<Mutex<Text>>);

impl Source for TextSource {
    fn latest(&self, since: Option<Revision>) -> Option<Latest> {
        let text = self.0.upgrade()?;
        let text = text.lock().unwrap_or_else(PoisonError::into_inner);
        Some(Latest {
            snapshot: text.snapshot(),
            patch: since.and_then(|since| text.changes_since(since).ok()),
        })
    }
}

/// An adapter with the fixture's Rust grammar registered, incremental.
fn syntax() -> TreeSitter {
    let syntax = TreeSitter::default();
    let source = GrammarSource {
        library: RUST.library.into(),
        symbol: RUST.symbol.to_owned(),
        policy: Some(ReparsePolicy::Incremental),
    };
    assert_eq!(syntax.register(&source), Ok(GrammarName::new("rust")));
    syntax
}

/// Rust's highlights, the fixture's, each capture in a face named after it.
fn highlighter() -> Highlighter<TreeSitterQuery> {
    let grammar = GrammarName::new("rust");
    let query = syntax().compile(&grammar, RUST.highlights).unwrap();
    let names = syntax().capture_names(&query);
    let faces = names.iter().cloned().map(Some).collect();
    Highlighter::new(Arc::new(query), names.len(), faces).unwrap()
}

/// A worker over the real syntax on `clock`, a text of [`ITEMS`] and its
/// session, drawn with Rust's highlights and parsed once.
struct Rig {
    clock: ManualClock,
    worker: Worker<TreeSitter>,
    text: Arc<Mutex<Text>>,
    session: Arc<Session<TreeSitter>>,
}

impl Rig {
    fn new() -> Self {
        let clock = ManualClock::new();
        let worker = Worker::new(Arc::new(syntax()), Arc::new(clock.clone()), INTERVAL);
        let text = Arc::new(Mutex::new(Text::from(ITEMS)));
        let source = Box::new(TextSource(Arc::downgrade(&text)));
        let session = Arc::new(Session::new(&syntax(), GrammarName::new("rust"), source).unwrap());
        session.set_highlighter(highlighter());
        let rig = Self {
            clock,
            worker,
            text,
            session,
        };
        rig.worker.handle().touch(&rig.session, Revision::new(0));
        rig.worker.step();
        rig
    }

    /// The text as it is now.
    fn snapshot(&self) -> Snapshot {
        self.text.lock().unwrap().snapshot()
    }

    /// Replaces `range` with `with`, touches the session and steps its
    /// round, with the clock moved on a little, short of the interval.
    fn edit(&self, range: Range<usize>, with: &str) {
        let revision = {
            let mut text = self.text.lock().unwrap();
            text.replace(range, with).unwrap();
            text.current().revision()
        };
        self.clock.advance(10);
        self.worker.handle().touch(&self.session, revision);
        assert!(self.worker.step().is_some(), "the edit's round did not run");
        assert_eq!(
            self.worker.step(),
            None,
            "a refresh ran before the interval"
        );
    }

    /// Types `typed` at `at`, a character at a time.
    fn type_at(&self, at: usize, typed: &str) {
        for (offset, c) in typed.char_indices() {
            self.edit(at + offset..at + offset, c.encode_utf8(&mut [0; 4]));
        }
    }

    /// Moves the clock past the interval and steps the refresh, then holds
    /// the tree delivered to a fresh parse of the text and what it draws to
    /// a fresh highlight.
    fn quiet_and_fresh(&self) {
        self.clock.advance(INTERVAL.as_millis().try_into().unwrap());
        assert!(self.worker.step().is_some(), "the refresh did not run");
        assert_eq!(self.worker.step(), None);

        let snapshot = self.snapshot();
        let mut parser = syntax().parser(&GrammarName::new("rust")).unwrap();
        let fresh = syntax().parse(&mut parser, &snapshot, None);
        let parsed = self.session.parsed().unwrap();
        assert_eq!(parsed.revision, snapshot.revision());
        assert_eq!(syntax().nodes(&parsed.tree), syntax().nodes(&fresh));

        let highlights = self.session.highlights(&snapshot).unwrap();
        let mut drawn: Vec<HighlightSpan> = Vec::new();
        highlights.spans(&syntax(), 0..snapshot.len(), &mut drawn);
        let fresh_drawn = highlight::fresh(&syntax(), &highlighter(), None, &mut parser, &snapshot);
        assert_eq!(drawn, fresh_drawn);
    }
}

/// Whether the tree `rig`'s session delivered last equals a fresh parse of
/// the text as it is now.
fn delivered_is_fresh(rig: &Rig) -> bool {
    let snapshot = rig.snapshot();
    let mut parser = syntax().parser(&GrammarName::new("rust")).unwrap();
    let fresh = syntax().parse(&mut parser, &snapshot, None);
    rig.session.parsed().is_some_and(|parsed| {
        parsed.revision == snapshot.revision()
            && syntax().nodes(&parsed.tree) == syntax().nodes(&fresh)
    })
}

/// Whether a fresh parse of the text as it is now has an error.
fn has_errors(rig: &Rig) -> bool {
    let mut parser = syntax().parser(&GrammarName::new("rust")).unwrap();
    syntax().has_errors(&syntax().parse(&mut parser, &rig.snapshot(), None))
}

#[test]
fn rust_edits_that_break_and_mend_the_syntax_converge_after_the_idle_interval() {
    let rig = Rig::new();
    let item = ITEMS.find("pub struct Point").unwrap();
    // The `}` that closes `struct Point`, and where `fn g(` is typed: the
    // end of the text.
    let close = ITEMS.find("usize,\n}\n").unwrap() + "usize,\n".len();

    // A stray `x` typed before the struct, then its closing `}` replaced
    // with a `,`: tree-sitter's incremental reparse of this differs from a
    // fresh parse (found by a sweep of random edits, on 2026-11-16).
    rig.type_at(item, "x");
    rig.edit(close + 1..close + 2, ",");
    assert!(has_errors(&rig));
    assert!(
        !delivered_is_fresh(&rig),
        "the incremental tree equals a fresh parse: the sequence no longer tests the refresh"
    );
    rig.quiet_and_fresh();

    // More typed while the text has its errors: an unclosed `fn g(`.
    let end = rig.snapshot().len();
    rig.type_at(end, "fn g(");
    rig.type_at(end + "fn g(".len(), "a: u8");
    assert!(has_errors(&rig));
    rig.quiet_and_fresh();

    // Mended: the `,` back to `}`, the `x` taken out, and `fn g` closed.
    rig.edit(close + 1..close + 2, "");
    rig.type_at(close + 1, "}");
    rig.edit(item..item + 1, "");
    let end = rig.snapshot().len();
    rig.type_at(end, ")");
    rig.type_at(end + 1, " {");
    rig.type_at(end + 3, "}\n");
    assert!(!has_errors(&rig));
    rig.quiet_and_fresh();
}
