//! Syntax trees as they cross the boundary: the process's syntax service,
//! which parses documents with a grammar off the editor thread, and the C
//! functions that attach a document to it, compile queries and ask them.
//!
//! The service is one process-wide [`Syntaxes`]: the real syntax
//! (`editor-syntax-treesitter`), one worker thread named `syntax`, started
//! at the first attach and blocked while it has nothing to parse, and a
//! table of the documents being parsed, by their key, each with its
//! session (`editor_syntax::Session`). Which tree is handed out, when a
//! document is reparsed and how, and what a question of captures answers or
//! why it is refused (`Session::captures`, over `query::captures_in`) are
//! `editor-syntax`'s rules, pinned by its own tests. This module keeps the
//! table of documents, refuses a question about a document not in it
//! ([`CapturesStatus::NotAttached`], checked first), and otherwise forwards
//! to the document's session.
//!
//! **Documents tell the service of their edits.** Every edit path of a
//! document ([`crate::document`]) calls `touched` with the document's key
//! and the revision its edit produced, which queues the document's session
//! for a reparse and does nothing for a document that is not attached; and
//! freeing a document calls `detach`. The session reads the document's
//! text through the snapshot's [`Source`](crate::snapshot::Source), weakly:
//! a document gone ends its session.
//!
//! **Tests use the process's service.** The edit paths reach the one
//! process-wide instance, so a test that made a service of its own would
//! never be told of an edit. The wiring tests (`tests/syntax.rs`) go
//! through the C functions, on the process's service, in parallel: keys are
//! given out once in the process, so no two tests' documents share a
//! session.
//!
//! # The functions
//!
//! | Function | What |
//! |---|---|
//! | [`editor_ffi_syntax_grammars`] | the grammars compiled in, as a list of strings |
//! | [`editor_ffi_syntax_attach`] | parse the snapshot's document with a grammar from now on, in place of any grammar before; a [`AttachStatus`] |
//! | [`editor_ffi_syntax_detach`] | stop parsing the snapshot's document |
//! | [`editor_ffi_syntax_query_new`], [`editor_ffi_syntax_query_free`] | a query handle, or the refusal's kind and offset |
//! | [`editor_ffi_syntax_capture_names`] | a query's capture names, as a list of strings |
//! | [`editor_ffi_syntax_captures`] | a query's captures in a range of the snapshot, as words, with a [`CapturesStatus`] |
//! | [`editor_ffi_syntax_shipped_query`] | the source of the query of a kind a grammar is published with, or a [`ShippedStatus`] |
//! | [`editor_ffi_syntax_highlight`] | draw the snapshot's document with a query's captures in faces from now on; a [`HighlightStatus`] |
//! | [`editor_ffi_syntax_inject`] | find the snapshot's document's injections with a query from now on; an [`InjectStatus`] |
//! | [`editor_ffi_syntax_inject_language`] | parse and draw an injection of a language with a highlights query, faces and its own injections query, if any; an [`InjectLanguageStatus`] |
//! | [`editor_ffi_syntax_keep`] | keep a query as the snapshot's document's query of a kind; a [`KeepStatus`] |
//! | [`editor_ffi_syntax_kept_names`] | the capture names of the query kept of a kind, with a [`KeptStatus`] |
//! | [`editor_ffi_syntax_kept_captures`] | the captures of the query kept of a kind in a range of the snapshot, as words, with a [`KeptStatus`] |
//! | [`editor_ffi_syntax_settle`] | for tests: wait, with a bound, for the snapshot's revision to be delivered |
//!
//! **A query is answered from the tree delivered, never parsed for.**
//! [`editor_ffi_syntax_captures`] answers only when the last tree the
//! document's session delivered is of the snapshot's revision, and is
//! otherwise [`CapturesStatus::NotParsed`]: the editor thread never waits
//! for a parse. A caller asks again after the next delivery. The rule and
//! the order of the refusals are the session's (`Session::captures`).
//!
//! # Highlights
//!
//! **A document is highlighted** by [`editor_ffi_syntax_highlight`]: its
//! session is given a highlighter (`editor_syntax::Highlighter`), the query
//! and a face, or none, for each of its captures, which Lean's config
//! chose. The highlighter shares the query ([`SyntaxQuery`] holds it in an
//! `Arc`), so it outlives the query's handle. Which tree draws a snapshot,
//! and how the delivered spans are carried through edits until the reparse
//! that replaces them, are `editor-syntax`'s (`Session::highlights`).
//!
//! **Highlights reach the display without passing through Lean.** The
//! display makes every text it lays out with [`crate::display::text_ref`],
//! which hands layout the document's session as the text's own spans
//! ([`Syntaxes::spans`], a [`TextSpans`]): a frame, and the rows and move
//! queries, resolve them once each, and ask only the rows they lay out.
//!
//! **A delivery is reported.** The first highlighter set on a session
//! subscribes a [`ParsedNotice`], which pushes one
//! [`EventKind::Parsed`](crate::events::EventKind::Parsed) from the
//! library's source [`SERVICE`] onto the editor queue for each delivery.
//! Lean publishes a scene for it, laid out with the new tree: the old
//! highlights stay until then.
//!
//! **Injections.** [`editor_ffi_syntax_inject`] gives the document's
//! session its injections query, and [`editor_ffi_syntax_inject_language`]
//! a language an injection may name: a grammar's highlights query, a face
//! for each of its captures, and the grammar's own injections query. Each
//! queues the session, whose next round finds the layers and delivers them
//! at the same revision when the text has not moved (`editor_syntax::session`,
//! step 4), so the [`ParsedNotice`] the highlighter subscribed has Lean
//! publish a scene drawn with them, with no key pressed.
//!
//! **Kept queries.** [`editor_ffi_syntax_keep`] has the document's session
//! keep a query of a kind (text objects, indents), and
//! [`editor_ffi_syntax_kept_captures`] answers its captures in a range from
//! the tree delivered, refused as `Session::kept_captures` refuses, and
//! never parsed for.
//!
//! **An attach with the grammar a document is attached with keeps its
//! session**, its tree, its highlighter, its injections and its kept
//! queries; another grammar replaces the session and drops them all, as a
//! detach does.
//!
//! # Layouts
//!
//! - **A list of strings out** ([`RawStrings`]): words, the count of
//!   strings and then the byte length of each, and one string of all of
//!   them end to end, each buffer lent as a text is.
//! - **Captures out** (a [`RawWords`]): the count of captures, then four
//!   words each, its pattern, its capture's index among the query's
//!   names, and the offsets its node starts and ends at.
//! - **A query made** ([`RawQuery`]): the handle, or null, with a status
//!   ([`QueryStatus`]) and, for a refusal, its kind ([`kind_tag`]) and the
//!   byte offset into the query's text where it was found.
//! - **Faces in** ([`editor_ffi_syntax_highlight`]): a list of strings in
//!   the borrowed layout lists of strings cross in, words of the count and
//!   each byte length and one string of them end to end, as
//!   `editor_ffi_fuzzy_rank`'s candidates; the empty string stands for
//!   none.
//! - **A shipped query out**: its source in a [`RawText`], with the status
//!   as the function's result; a kind crosses as a `u8` tag
//!   ([`query_kind_of`]).
//! - **A language in** ([`editor_ffi_syntax_inject_language`]): its name
//!   as a string, its highlights query's handle and faces in the layout of
//!   [`editor_ffi_syntax_highlight`], and its injections query's handle, or
//!   null for none.
//! - **Kept names out** ([`editor_ffi_syntax_kept_names`]): a
//!   [`RawStrings`], with the status as the function's result. **Kept
//!   captures out** ([`editor_ffi_syntax_kept_captures`]): a [`RawWords`] of
//!   the layout of captures, its status a [`KeptStatus`].

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};
use std::thread;
use std::time::Duration;

use editor_layout::scene::{SpansAt, TextSpans};
use editor_syntax::inject::Language;
use editor_syntax::{
    Capture, CapturesRefusal, Consumer, GrammarName, Handle, Highlighter, Highlights, KeptRefusal,
    Parsed, QueryErrorKind, QueryKind, Session, Syntax, Worker,
};
use editor_syntax_treesitter::TreeSitter;
use editor_text::Revision;

use crate::document::RawText;
use crate::events::{Event, Queue, QueueId, Source, SourceKind};
use crate::fuzzy::candidates;
use crate::log::RawWords;
use crate::snapshot::Snapshot;
use crate::{text, words};

/// The syntax service's id, as the source of the events it reports: the
/// library's, numbered after the other services'.
pub const SERVICE: u64 = 6;

/// The real syntax's session of one document.
type SyntaxSession = Session<TreeSitter>;

/// How an attach ended, as it crosses the boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AttachStatus {
    /// The document is parsed with the grammar from now on.
    Attached = 0,
    /// No grammar of that name is compiled in.
    UnknownGrammar = 1,
    /// The snapshot has no document, or its document is gone: a file's
    /// text as it was loaded, say.
    NoDocument = 2,
    /// The worker thread could not be started.
    NoWorker = 3,
}

/// How a question of captures ended, as it crosses the boundary: the
/// `status` of the [`RawWords`] [`editor_ffi_syntax_captures`] fills.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CapturesStatus {
    /// Answered: the record's words are the captures.
    Answered = 0,
    /// The snapshot's document is not attached.
    NotAttached = 1,
    /// No tree of the snapshot's revision has been delivered.
    NotParsed = 2,
    /// The query is of another grammar than the document is parsed with.
    WrongGrammar = 3,
    /// The range is not two positions of the snapshot's text in order.
    BadRange = 4,
}

impl From<CapturesRefusal> for CapturesStatus {
    /// The status of a session's refusal. Every refusal crosses the
    /// boundary as a status of its own, so this matches each one.
    fn from(refusal: CapturesRefusal) -> Self {
        match refusal {
            CapturesRefusal::WrongGrammar => Self::WrongGrammar,
            CapturesRefusal::BadRange => Self::BadRange,
            CapturesRefusal::NotParsed => Self::NotParsed,
        }
    }
}

/// How setting a highlighter ended, as it crosses the boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HighlightStatus {
    /// The text is drawn with the query's captures in the faces from now
    /// on.
    Highlighted = 0,
    /// The snapshot's document is not attached.
    NotAttached = 1,
    /// The query is of another grammar than the document is parsed with.
    WrongGrammar = 2,
    /// The faces are not one for each of the query's capture names, or do
    /// not spell a list of strings.
    BadFaces = 3,
}

/// How asking for a grammar's shipped query ended, as it crosses the
/// boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShippedStatus {
    /// The record holds the query's source.
    Shipped = 0,
    /// No grammar of that name is compiled in.
    UnknownGrammar = 1,
    /// The grammar ships no query of that kind, or the kind's tag is none.
    NoShippedQuery = 2,
}

/// How giving a document an injections query ended, as it crosses the
/// boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InjectStatus {
    /// The document's injections are found with the query from the next
    /// round on.
    Injected = 0,
    /// The snapshot's document is not attached.
    NotAttached = 1,
    /// The query is of another grammar than the document is parsed with.
    WrongGrammar = 2,
}

/// How giving a document a language for its injections ended, as it
/// crosses the boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InjectLanguageStatus {
    /// An injection of the language is parsed and drawn as given from the
    /// next round on.
    Injected = 0,
    /// The snapshot's document is not attached.
    NotAttached = 1,
    /// The injections query is of another grammar than the highlights
    /// query.
    WrongGrammar = 2,
    /// The faces are not one for each of the highlights query's capture
    /// names, or do not spell a list of strings.
    BadFaces = 3,
}

/// How keeping a query ended, as it crosses the boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeepStatus {
    /// The document keeps the query as its query of the kind.
    Kept = 0,
    /// The snapshot's document is not attached.
    NotAttached = 1,
    /// The query is of another grammar than the document is parsed with.
    WrongGrammar = 2,
    /// The kind's tag names no kind.
    NoSuchKind = 3,
}

/// How a question of a kept query ended, as it crosses the boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeptStatus {
    /// Answered.
    Answered = 0,
    /// The snapshot's document is not attached.
    NotAttached = 1,
    /// The document keeps no query of that kind.
    NoQuery = 2,
    /// The range is not two positions of the snapshot's text in order.
    BadRange = 3,
    /// No tree of the snapshot's revision has been delivered.
    NotParsed = 4,
    /// The kind's tag names no kind.
    NoSuchKind = 5,
}

impl From<KeptRefusal> for KeptStatus {
    /// The status of a session's refusal. Every refusal crosses the
    /// boundary as a status of its own, so this matches each one.
    fn from(refusal: KeptRefusal) -> Self {
        match refusal {
            KeptRefusal::NoQuery => Self::NoQuery,
            KeptRefusal::BadRange => Self::BadRange,
            KeptRefusal::NotParsed => Self::NotParsed,
        }
    }
}

/// The kind of query `tag` stands for: 0 is [`QueryKind::Highlights`], 1
/// [`QueryKind::Injections`], 2 [`QueryKind::TextObjects`] and 3
/// [`QueryKind::Indents`].
pub const fn query_kind_of(tag: u8) -> Option<QueryKind> {
    match tag {
        0 => Some(QueryKind::Highlights),
        1 => Some(QueryKind::Injections),
        2 => Some(QueryKind::TextObjects),
        3 => Some(QueryKind::Indents),
        _ => None,
    }
}

/// How making a query ended, as it crosses the boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QueryStatus {
    /// Made: the record holds the handle.
    Made = 0,
    /// No grammar of that name is compiled in.
    UnknownGrammar = 1,
    /// The query was refused: the record holds the kind and the offset.
    Refused = 2,
}

/// The number that stands for `kind` across the boundary.
pub const fn kind_tag(kind: QueryErrorKind) -> u64 {
    match kind {
        QueryErrorKind::Syntax => 0,
        QueryErrorKind::NodeType => 1,
        QueryErrorKind::Field => 2,
        QueryErrorKind::Capture => 3,
        QueryErrorKind::Predicate => 4,
        QueryErrorKind::Structure => 5,
        QueryErrorKind::Language => 6,
    }
}

/// A compiled query, behind a handle, with the grammar it is of.
///
/// **What hands a query handle out.** [`editor_ffi_syntax_query_new`]
/// alone, which counts it live; [`editor_ffi_syntax_query_free`] is the one
/// function that takes one back.
pub struct SyntaxQuery {
    /// The grammar it was compiled for.
    grammar: GrammarName,
    /// The query, shared: a highlighter made of it keeps it after the
    /// handle is freed.
    query: Arc<<TreeSitter as Syntax>::Query>,
}

/// How many query handles are live.
static QUERIES_LIVE: AtomicU64 = AtomicU64::new(0);

/// The process's syntax service: the real syntax, its worker, and the
/// documents attached to it.
pub struct Syntaxes {
    /// The real syntax, shared with the worker.
    syntax: Arc<TreeSitter>,
    /// The worker's handle, once its thread is started.
    worker: Mutex<Option<Handle<TreeSitter>>>,
    /// The documents attached, by key, each with its session.
    attached: Mutex<HashMap<u64, Arc<SyntaxSession>>>,
    /// Where a delivery of a highlighted document is reported: the editor
    /// queue, in the process.
    notices: &'static Queue,
}

/// Reports each delivery of a session with a highlighter: one
/// [`EventKind::Parsed`](crate::events::EventKind::Parsed) from the
/// service on its queue, which makes Lean publish a scene laid out with
/// the new tree. It is subscribed to a session the first time a
/// highlighter is set, and a session never loses its highlighter (a
/// detach, or another grammar, drops the session). It takes only the
/// queue's lock, under the session's state lock, which nothing takes the
/// other way round.
pub struct ParsedNotice(pub &'static Queue);

impl<T> Consumer<T> for ParsedNotice {
    fn deliver(&self, _parsed: &Parsed<T>) {
        self.0.push(Event::parsed(Source {
            kind: SourceKind::Library,
            id: SERVICE,
        }));
    }
}

/// A document's session as the text's own spans: what layout draws under
/// the scene's decorations ([`TextSpans`]). Each frame and each query asks
/// it once ([`Session::highlights`]), and every span after that is one call
/// of [`Highlights::spans`].
struct SessionSpans {
    /// The real syntax.
    syntax: Arc<TreeSitter>,
    /// The document's session.
    session: Arc<SyntaxSession>,
}

impl TextSpans for SessionSpans {
    fn at(&self, snapshot: &editor_text::Snapshot) -> Option<Box<dyn SpansAt>> {
        let highlights = self.session.highlights(snapshot)?;
        Some(Box::new(SpansOf {
            syntax: self.syntax.clone(),
            highlights,
        }))
    }
}

/// What a session draws over one snapshot.
struct SpansOf {
    /// The real syntax.
    syntax: Arc<TreeSitter>,
    /// What the session answered.
    highlights: Highlights<TreeSitter>,
}

impl SpansAt for SpansOf {
    fn faces(&self) -> &[String] {
        self.highlights.faces()
    }

    fn spans(&self, bytes: std::ops::Range<usize>, out: &mut Vec<(std::ops::Range<usize>, usize)>) {
        let mut spans = Vec::new();
        self.highlights.spans(&*self.syntax, bytes, &mut spans);
        out.extend(spans.into_iter().map(|span| (span.bytes, span.face)));
    }
}

/// `mutex`, locked. Nothing here leaves what it guards half-changed, so a
/// poisoned lock is used as it is.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The process's syntax service.
pub fn syntaxes() -> &'static Syntaxes {
    /// The one service.
    static SYNTAXES: OnceLock<Syntaxes> = OnceLock::new();
    SYNTAXES.get_or_init(|| Syntaxes::new(QueueId::Editor.queue()))
}

/// Tells the process's service that the document `key` has reached
/// `revision`. Nothing when it is not attached. Every edit path of a
/// document calls it, once the edit is made and the document's lock let
/// go.
pub(crate) fn touched(key: u64, revision: Revision) {
    syntaxes().touched(key, revision);
}

/// Stops the process's service parsing the document `key`. Freeing a
/// document calls it.
pub(crate) fn detach(key: u64) {
    syntaxes().detach(key);
}

impl Syntaxes {
    /// A service with nothing attached and no worker started, which reports
    /// deliveries of highlighted documents on `notices`. The process has
    /// one ([`syntaxes`]), on the editor queue; a unit test makes one on a
    /// queue of its own.
    pub fn new(notices: &'static Queue) -> Self {
        Self {
            syntax: Arc::new(TreeSitter),
            worker: Mutex::new(None),
            attached: Mutex::new(HashMap::new()),
            notices,
        }
    }

    /// The grammars compiled in.
    pub fn grammars(&self) -> Vec<GrammarName> {
        self.syntax.grammars()
    }

    /// The worker's handle, its thread started if it was not.
    fn worker(&self) -> Option<Handle<TreeSitter>> {
        let mut worker = lock(&self.worker);
        if worker.is_none() {
            let started = Worker::new(self.syntax.clone());
            let handle = started.handle();
            thread::Builder::new()
                .name("syntax".to_owned())
                .spawn(move || started.run())
                .ok()?;
            *worker = Some(handle);
        }
        worker.clone()
    }

    /// Parses the document `snapshot` is of with `grammar` from now on, in
    /// place of any grammar before, starting with a parse of it as it is.
    /// A document already attached with `grammar` keeps its session, its
    /// tree and its highlighter: a switch between two modes of one grammar
    /// does not draw the text plain again.
    pub fn attach(&self, snapshot: &Snapshot, grammar: &str) -> AttachStatus {
        let grammar = GrammarName::new(grammar);
        if !self.grammars().contains(&grammar) {
            return AttachStatus::UnknownGrammar;
        }
        let source = snapshot.source();
        if !source.has_document() {
            return AttachStatus::NoDocument;
        }
        if let Some(session) = self
            .session(snapshot.key())
            .filter(|session| *session.grammar() == grammar)
        {
            if let Some(worker) = lock(&self.worker).clone() {
                worker.touch(&session, snapshot.text().revision());
            }
            return AttachStatus::Attached;
        }
        let Some(session) = Session::new(&*self.syntax, grammar, Box::new(source.clone())) else {
            return AttachStatus::UnknownGrammar;
        };
        let Some(worker) = self.worker() else {
            return AttachStatus::NoWorker;
        };
        let session = Arc::new(session);
        lock(&self.attached).insert(snapshot.key(), session.clone());
        worker.touch(&session, snapshot.text().revision());
        AttachStatus::Attached
    }

    /// Stops parsing the document `key`; whether it was attached.
    pub fn detach(&self, key: u64) -> bool {
        lock(&self.attached).remove(&key).is_some()
    }

    /// The session of the document `key`, if it is attached.
    fn session(&self, key: u64) -> Option<Arc<SyntaxSession>> {
        lock(&self.attached).get(&key).cloned()
    }

    /// Tells the session of the document `key`, if it is attached, of
    /// `revision`, and queues it.
    pub fn touched(&self, key: u64, revision: Revision) {
        let Some(session) = self.session(key) else {
            return;
        };
        if let Some(worker) = lock(&self.worker).clone() {
            worker.touch(&session, revision);
        }
    }

    /// The captures of `query` in `range` of `snapshot`'s text, as the
    /// session of its document answers them (`Session::captures`); not
    /// attached when it has none.
    pub fn captures(
        &self,
        snapshot: &Snapshot,
        query: &SyntaxQuery,
        range: std::ops::Range<usize>,
    ) -> Result<Vec<Capture>, CapturesStatus> {
        let session = self
            .session(snapshot.key())
            .ok_or(CapturesStatus::NotAttached)?;
        session
            .captures(
                &self.syntax,
                &query.grammar,
                &query.query,
                snapshot.text(),
                range,
            )
            .map_err(CapturesStatus::from)
    }

    /// Draws the text of `snapshot`'s document with `query`'s captures in
    /// `faces`, one for each of its capture names (none draws nothing),
    /// from now on, in place of any highlighter before
    /// (`Session::set_highlighter`). The first highlighter set on a session
    /// subscribes [`ParsedNotice`] to it.
    pub fn highlight(
        &self,
        snapshot: &Snapshot,
        query: &SyntaxQuery,
        faces: Vec<Option<String>>,
    ) -> HighlightStatus {
        let Some(session) = self.session(snapshot.key()) else {
            return HighlightStatus::NotAttached;
        };
        if *session.grammar() != query.grammar {
            return HighlightStatus::WrongGrammar;
        }
        let count = self.syntax.capture_names(&query.query).len();
        let Ok(highlighter) = Highlighter::new(query.query.clone(), count, faces) else {
            return HighlightStatus::BadFaces;
        };
        if !session.set_highlighter(highlighter) {
            session.subscribe(Box::new(ParsedNotice(self.notices)));
        }
        HighlightStatus::Highlighted
    }

    /// Has the session of the document `key` start a round: the text's
    /// revision told is `revision`, which it may have reached already.
    fn queue(&self, session: &Arc<SyntaxSession>, revision: Revision) {
        if let Some(worker) = lock(&self.worker).clone() {
            worker.touch(session, revision);
        }
    }

    /// Finds the injections of `snapshot`'s document with `query` from the
    /// next round on, and queues that round.
    pub fn inject(&self, snapshot: &Snapshot, query: &SyntaxQuery) -> InjectStatus {
        let Some(session) = self.session(snapshot.key()) else {
            return InjectStatus::NotAttached;
        };
        if *session.grammar() != query.grammar {
            return InjectStatus::WrongGrammar;
        }
        session.set_injections(Some(query.query.clone()));
        self.queue(&session, snapshot.text().revision());
        InjectStatus::Injected
    }

    /// Parses an injection of the language `name` in `snapshot`'s document
    /// with `highlights`' grammar, draws it with its captures in `faces`,
    /// and finds injections of its own with `injections`, from the next
    /// round on; and queues that round.
    pub fn inject_language(
        &self,
        snapshot: &Snapshot,
        name: &str,
        highlights: &SyntaxQuery,
        faces: Vec<Option<String>>,
        injections: Option<&SyntaxQuery>,
    ) -> InjectLanguageStatus {
        let Some(session) = self.session(snapshot.key()) else {
            return InjectLanguageStatus::NotAttached;
        };
        if injections.is_some_and(|injections| injections.grammar != highlights.grammar) {
            return InjectLanguageStatus::WrongGrammar;
        }
        let count = self.syntax.capture_names(&highlights.query).len();
        let Ok(highlighter) = Highlighter::new(highlights.query.clone(), count, faces) else {
            return InjectLanguageStatus::BadFaces;
        };
        let language = Language {
            grammar: highlights.grammar.clone(),
            highlighter: Arc::new(highlighter),
            injections: injections.map(|injections| injections.query.clone()),
        };
        session.set_language(name.to_owned(), language);
        self.queue(&session, snapshot.text().revision());
        InjectLanguageStatus::Injected
    }

    /// Has `snapshot`'s document keep `query` as its query of `kind`, in
    /// place of any before.
    pub fn keep(&self, snapshot: &Snapshot, kind: QueryKind, query: &SyntaxQuery) -> KeepStatus {
        let Some(session) = self.session(snapshot.key()) else {
            return KeepStatus::NotAttached;
        };
        if *session.grammar() != query.grammar {
            return KeepStatus::WrongGrammar;
        }
        session.keep(kind, query.query.clone());
        KeepStatus::Kept
    }

    /// The capture names of the query `snapshot`'s document keeps of
    /// `kind`, or why not.
    pub fn kept_names(
        &self,
        snapshot: &Snapshot,
        kind: QueryKind,
    ) -> Result<Vec<String>, KeptStatus> {
        let session = self
            .session(snapshot.key())
            .ok_or(KeptStatus::NotAttached)?;
        session
            .kept_names(&self.syntax, kind)
            .ok_or(KeptStatus::NoQuery)
    }

    /// The captures of the query `snapshot`'s document keeps of `kind`, in
    /// `range` of its text, as the session answers them
    /// (`Session::kept_captures`); not attached when it has none.
    pub fn kept_captures(
        &self,
        snapshot: &Snapshot,
        kind: QueryKind,
        range: std::ops::Range<usize>,
    ) -> Result<Vec<Capture>, KeptStatus> {
        let session = self
            .session(snapshot.key())
            .ok_or(KeptStatus::NotAttached)?;
        session
            .kept_captures(&self.syntax, kind, snapshot.text(), range)
            .map(|(_, captures)| captures)
            .map_err(KeptStatus::from)
    }

    /// The source of the query of `kind` the grammar named `grammar` is
    /// published with, or why not.
    pub fn shipped_query(&self, grammar: &str, kind: QueryKind) -> Result<String, ShippedStatus> {
        let grammar = GrammarName::new(grammar);
        if !self.grammars().contains(&grammar) {
            return Err(ShippedStatus::UnknownGrammar);
        }
        self.syntax
            .shipped_query(&grammar, kind)
            .ok_or(ShippedStatus::NoShippedQuery)
    }

    /// The document `key`'s own spans, its highlights, as layout asks them
    /// ([`TextSpans`]); none when it is not attached.
    pub fn spans(&self, key: u64) -> Option<Arc<dyn TextSpans>> {
        let session = self.session(key)?;
        Some(Arc::new(SessionSpans {
            syntax: self.syntax.clone(),
            session,
        }))
    }

    /// Waits up to `bound` for a tree of `snapshot`'s revision, or a newer
    /// one, to be delivered, with layers found with the injections as they
    /// are now (`Session::wait_for`); whether one was. False at once when its
    /// document is not attached.
    pub fn settle(&self, snapshot: &Snapshot, bound: Duration) -> bool {
        self.session(snapshot.key()).is_some_and(|session| {
            session
                .wait_for(snapshot.text().revision(), bound)
                .is_some()
        })
    }

    /// The tree delivered of the document `key`, as nodes, with the revision
    /// it parsed: for the wiring tests, which compare it with a fresh parse.
    pub fn delivered(&self, key: u64) -> Option<(Revision, Vec<editor_syntax::Node>)> {
        let parsed = self.session(key)?.parsed()?;
        Some((parsed.revision, self.syntax.nodes(&parsed.tree)))
    }
}

/// A list of strings out, as one record filled in one call: the words of
/// the lengths, and one string of all of them end to end, each lent as a
/// text is.
#[repr(C)]
pub struct RawStrings {
    /// The words: the count of strings, then the byte length of each.
    pub words: *mut u8,
    /// The length of `words` in bytes.
    pub words_len: usize,
    /// Every string end to end.
    pub text: *mut u8,
    /// The length of `text` in bytes.
    pub text_len: usize,
}

impl RawStrings {
    /// The record of `strings`.
    pub fn of(strings: &[String]) -> Self {
        let (words, words_len) = words::lend(strings_words(strings));
        let (text, text_len) = text::lend(strings.concat());
        Self {
            words,
            words_len,
            text,
            text_len,
        }
    }
}

/// The words of a list of strings: the count, then the byte length of
/// each.
pub fn strings_words(strings: &[String]) -> Vec<u8> {
    let mut writer = words::Writer::with_capacity(1 + strings.len());
    writer.size(strings.len());
    for string in strings {
        writer.size(string.len());
    }
    writer.finish()
}

/// The words of `captures`: the count, then four words each.
pub fn captures_words(captures: &[Capture]) -> Vec<u8> {
    let mut writer = words::Writer::with_capacity(1 + 4 * captures.len());
    writer.size(captures.len());
    for capture in captures {
        writer.size(capture.pattern);
        writer.word(u64::from(capture.capture));
        writer.size(capture.start);
        writer.size(capture.end);
    }
    writer.finish()
}

/// A query made, as it crosses the boundary.
#[repr(C)]
pub struct RawQuery {
    /// A [`QueryStatus`], as its number.
    pub status: u64,
    /// For a refusal, the [`kind_tag`] of why; 0 otherwise.
    pub kind: u64,
    /// For a refusal, the byte offset into the query's text where it was
    /// found; 0 otherwise.
    pub offset: u64,
    /// The handle, when made, owned by the caller, who must hand it to
    /// [`editor_ffi_syntax_query_free`] exactly once; null otherwise.
    pub query: *mut SyntaxQuery,
}

/// Fills `out` with the grammars compiled in, by name.
///
/// # Safety
///
/// `out` points to a writable [`RawStrings`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_syntax_grammars(out: *mut RawStrings) {
    let names: Vec<String> = syntaxes()
        .grammars()
        .into_iter()
        .map(|name| name.0)
        .collect();
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(RawStrings::of(&names)) };
}

/// [`Syntaxes::attach`] for C: parses the document of `snapshot` with the
/// grammar named by the `len` bytes at `grammar` from now on, and returns
/// an [`AttachStatus`] as its number.
///
/// # Safety
///
/// `snapshot` is a snapshot handle this library handed out and has not
/// taken back ([`crate::snapshot`]), and `grammar` points to `len`
/// readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_syntax_attach(
    snapshot: *const Snapshot,
    grammar: *const u8,
    len: usize,
) -> u64 {
    // SAFETY: the caller guarantees the pointer and the length.
    let grammar = unsafe { text::borrow(grammar, len) };
    // SAFETY: the caller guarantees `snapshot` points to a live snapshot.
    syntaxes().attach(unsafe { &*snapshot }, &grammar) as u64
}

/// Stops parsing the document of `snapshot`, and returns whether it was
/// attached.
///
/// # Safety
///
/// `snapshot` is a snapshot handle this library handed out and has not
/// taken back.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_syntax_detach(snapshot: *const Snapshot) -> bool {
    // SAFETY: the caller guarantees `snapshot` points to a live snapshot.
    syntaxes().detach(unsafe { &*snapshot }.key())
}

/// Compiles the query the `source_len` bytes at `source` spell for the
/// grammar the `grammar_len` bytes at `grammar` name, and fills `out`.
///
/// # Safety
///
/// `grammar` points to `grammar_len` readable bytes and `source` to
/// `source_len`, and `out` points to a writable [`RawQuery`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_syntax_query_new(
    grammar: *const u8,
    grammar_len: usize,
    source: *const u8,
    source_len: usize,
    out: *mut RawQuery,
) {
    // SAFETY: the caller guarantees each pointer and its length.
    let (grammar, source) = unsafe {
        (
            text::borrow(grammar, grammar_len),
            text::borrow(source, source_len),
        )
    };
    let service = syntaxes();
    let grammar = GrammarName::new(grammar.as_ref());
    let raw = if !service.grammars().contains(&grammar) {
        RawQuery {
            status: QueryStatus::UnknownGrammar as u64,
            kind: 0,
            offset: 0,
            query: std::ptr::null_mut(),
        }
    } else {
        match service.syntax.compile(&grammar, &source) {
            Ok(query) => {
                QUERIES_LIVE.fetch_add(1, Ordering::Relaxed);
                RawQuery {
                    status: QueryStatus::Made as u64,
                    kind: 0,
                    offset: 0,
                    query: Box::into_raw(Box::new(SyntaxQuery {
                        grammar,
                        query: Arc::new(query),
                    })),
                }
            }
            Err(error) => RawQuery {
                status: QueryStatus::Refused as u64,
                kind: kind_tag(error.kind),
                offset: words::word(error.offset),
                query: std::ptr::null_mut(),
            },
        }
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
}

/// Frees `query`.
///
/// # Safety
///
/// `query` is a query handle [`editor_ffi_syntax_query_new`] handed out and
/// has not been taken back, and it is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_syntax_query_free(query: *mut SyntaxQuery) {
    // SAFETY: the caller guarantees `query` is a box `query_new` gave up,
    // taken back this once.
    drop(unsafe { Box::from_raw(query) });
    QUERIES_LIVE.fetch_sub(1, Ordering::Relaxed);
}

/// How many query handles are live: for tests.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_syntax_query_live() -> u64 {
    QUERIES_LIVE.load(Ordering::Relaxed)
}

/// Fills `out` with the capture names of `query`, in order.
///
/// # Safety
///
/// `query` is a live query handle, and `out` points to a writable
/// [`RawStrings`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_syntax_capture_names(
    query: *const SyntaxQuery,
    out: *mut RawStrings,
) {
    // SAFETY: the caller guarantees `query` points to a live query.
    let names = syntaxes().syntax.capture_names(&unsafe { &*query }.query);
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(RawStrings::of(&names)) };
}

/// [`Syntaxes::captures`] for C: fills `out` with the captures of `query`
/// in the range from `start` to `end` of `snapshot`'s text, as words, and
/// the status [`CapturesStatus::Answered`]; or with no words and the
/// refusal's status.
///
/// # Safety
///
/// `snapshot` is a live snapshot handle, `query` a live query handle, and
/// `out` points to a writable [`RawWords`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_syntax_captures(
    snapshot: *const Snapshot,
    query: *const SyntaxQuery,
    start: usize,
    end: usize,
    out: *mut RawWords,
) {
    // SAFETY: the caller guarantees both handles are live.
    let (snapshot, query) = unsafe { (&*snapshot, &*query) };
    let raw = match syntaxes().captures(snapshot, query, start..end) {
        Ok(captures) => {
            RawWords::with_status(CapturesStatus::Answered as u64, captures_words(&captures))
        }
        Err(status) => RawWords::with_status(status as u64, Vec::new()),
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
}

/// The faces `words` and `strings` spell: a list of strings in the layout
/// lists of strings cross in (`fuzzy::candidates`), the empty string
/// standing for none. `None` when they spell no list.
pub(crate) fn faces_of(words: &[u8], strings: &str) -> Option<Vec<Option<String>>> {
    let faces = candidates(words, strings)?;
    Some(
        faces
            .into_iter()
            .map(|face| (!face.is_empty()).then(|| face.to_owned()))
            .collect(),
    )
}

/// [`Syntaxes::shipped_query`] for C: fills `out` with the source of the
/// query of the kind `kind` tags ([`query_kind_of`]) the grammar the `len`
/// bytes at `grammar` name is published with, and returns
/// [`ShippedStatus::Shipped`]; or returns the refusal's status and leaves
/// `out` alone. A kind tag that names no kind is
/// [`ShippedStatus::NoShippedQuery`].
///
/// # Safety
///
/// `grammar` points to `len` readable bytes, and `out` to a writable
/// [`RawText`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_syntax_shipped_query(
    grammar: *const u8,
    len: usize,
    kind: u8,
    out: *mut RawText,
) -> u64 {
    // SAFETY: the caller guarantees the pointer and the length.
    let grammar = unsafe { text::borrow(grammar, len) };
    let service = syntaxes();
    let shipped = match query_kind_of(kind) {
        Some(kind) => service.shipped_query(&grammar, kind),
        None if service
            .grammars()
            .contains(&GrammarName::new(grammar.as_ref())) =>
        {
            Err(ShippedStatus::NoShippedQuery)
        }
        None => Err(ShippedStatus::UnknownGrammar),
    };
    match shipped {
        Ok(source) => {
            let (text, text_len) = text::lend(source);
            // SAFETY: the caller guarantees `out` is writable.
            unsafe { out.write(RawText { text, text_len }) };
            ShippedStatus::Shipped as u64
        }
        Err(status) => status as u64,
    }
}

/// [`Syntaxes::highlight`] for C: draws the document of `snapshot` with
/// `query`'s captures in the faces the `words_len` bytes at `words` and
/// the `strings_len` bytes at `strings` spell, a list of strings in the
/// borrowed layout (the empty string none), and returns a
/// [`HighlightStatus`] as its number. Faces that spell no list are
/// [`HighlightStatus::BadFaces`].
///
/// # Safety
///
/// `snapshot` is a live snapshot handle and `query` a live query handle,
/// and `words` points to `words_len` readable bytes and `strings` to
/// `strings_len` (no bytes at all may be lent with any pointer).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_syntax_highlight(
    snapshot: *const Snapshot,
    query: *const SyntaxQuery,
    words: *const u8,
    words_len: usize,
    strings: *const u8,
    strings_len: usize,
) -> u64 {
    // SAFETY: the caller guarantees both handles are live, and each
    // pointer and its length for the call.
    let (snapshot, query, words, strings) = unsafe {
        (
            &*snapshot,
            &*query,
            words::borrow(words, words_len),
            words::borrow(strings, strings_len),
        )
    };
    let faces = std::str::from_utf8(strings)
        .ok()
        .and_then(|strings| faces_of(words, strings));
    match faces {
        Some(faces) => syntaxes().highlight(snapshot, query, faces) as u64,
        None => HighlightStatus::BadFaces as u64,
    }
}

/// [`Syntaxes::inject`] for C: finds the injections of the document of
/// `snapshot` with `query` from the next round on, and returns an
/// [`InjectStatus`] as its number.
///
/// # Safety
///
/// `snapshot` is a live snapshot handle and `query` a live query handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_syntax_inject(
    snapshot: *const Snapshot,
    query: *const SyntaxQuery,
) -> u64 {
    // SAFETY: the caller guarantees both handles are live.
    let (snapshot, query) = unsafe { (&*snapshot, &*query) };
    syntaxes().inject(snapshot, query) as u64
}

/// [`Syntaxes::inject_language`] for C: an injection of the language the
/// `name_len` bytes at `name` name is parsed with `highlights`' grammar,
/// drawn with its captures in the faces the `words_len` bytes at `words`
/// and the `strings_len` bytes at `strings` spell (the layout of
/// [`editor_ffi_syntax_highlight`]), and finds injections of its own with
/// `injections`, or none when it is null. Returns an
/// [`InjectLanguageStatus`] as its number.
///
/// # Safety
///
/// `snapshot` is a live snapshot handle, `highlights` a live query handle,
/// and `injections` one or null; `name` points to `name_len` readable
/// bytes, `words` to `words_len` and `strings` to `strings_len`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_syntax_inject_language(
    snapshot: *const Snapshot,
    name: *const u8,
    name_len: usize,
    highlights: *const SyntaxQuery,
    words: *const u8,
    words_len: usize,
    strings: *const u8,
    strings_len: usize,
    injections: *const SyntaxQuery,
) -> u64 {
    // SAFETY: the caller guarantees the handles, each pointer and its
    // length, and that `injections` is live or null.
    let (snapshot, name, highlights, words, strings, injections) = unsafe {
        (
            &*snapshot,
            text::borrow(name, name_len),
            &*highlights,
            words::borrow(words, words_len),
            words::borrow(strings, strings_len),
            injections.as_ref(),
        )
    };
    let faces = std::str::from_utf8(strings)
        .ok()
        .and_then(|strings| faces_of(words, strings));
    match faces {
        Some(faces) => {
            syntaxes().inject_language(snapshot, &name, highlights, faces, injections) as u64
        }
        None => InjectLanguageStatus::BadFaces as u64,
    }
}

/// [`Syntaxes::keep`] for C: the document of `snapshot` keeps `query` as
/// its query of the kind `kind` tags ([`query_kind_of`]). Returns a
/// [`KeepStatus`] as its number.
///
/// # Safety
///
/// `snapshot` is a live snapshot handle and `query` a live query handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_syntax_keep(
    snapshot: *const Snapshot,
    kind: u8,
    query: *const SyntaxQuery,
) -> u64 {
    // SAFETY: the caller guarantees both handles are live.
    let (snapshot, query) = unsafe { (&*snapshot, &*query) };
    match query_kind_of(kind) {
        Some(kind) => syntaxes().keep(snapshot, kind, query) as u64,
        None => KeepStatus::NoSuchKind as u64,
    }
}

/// [`Syntaxes::kept_names`] for C: fills `out` with the capture names of
/// the query the document of `snapshot` keeps of the kind `kind` tags, and
/// returns [`KeptStatus::Answered`]; or returns the refusal's status and
/// leaves `out` alone.
///
/// # Safety
///
/// `snapshot` is a live snapshot handle and `out` points to a writable
/// [`RawStrings`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_syntax_kept_names(
    snapshot: *const Snapshot,
    kind: u8,
    out: *mut RawStrings,
) -> u64 {
    // SAFETY: the caller guarantees `snapshot` is live.
    let snapshot = unsafe { &*snapshot };
    let Some(kind) = query_kind_of(kind) else {
        return KeptStatus::NoSuchKind as u64;
    };
    match syntaxes().kept_names(snapshot, kind) {
        Ok(names) => {
            // SAFETY: the caller guarantees `out` is writable.
            unsafe { out.write(RawStrings::of(&names)) };
            KeptStatus::Answered as u64
        }
        Err(status) => status as u64,
    }
}

/// [`Syntaxes::kept_captures`] for C: fills `out` with the captures of the
/// query the document of `snapshot` keeps of the kind `kind` tags, in the
/// range from `start` to `end`, as words, and the status
/// [`KeptStatus::Answered`]; or with no words and the refusal's status.
///
/// # Safety
///
/// `snapshot` is a live snapshot handle and `out` points to a writable
/// [`RawWords`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_syntax_kept_captures(
    snapshot: *const Snapshot,
    kind: u8,
    start: usize,
    end: usize,
    out: *mut RawWords,
) {
    // SAFETY: the caller guarantees `snapshot` is live.
    let snapshot = unsafe { &*snapshot };
    let answer = match query_kind_of(kind) {
        Some(kind) => syntaxes().kept_captures(snapshot, kind, start..end),
        None => Err(KeptStatus::NoSuchKind),
    };
    let raw = match answer {
        Ok(captures) => {
            RawWords::with_status(KeptStatus::Answered as u64, captures_words(&captures))
        }
        Err(status) => RawWords::with_status(status as u64, Vec::new()),
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
}

/// For tests, like the other readouts: waits up to `bound_ms` milliseconds
/// for a tree of `snapshot`'s revision, or a newer one, to be delivered
/// with layers found with the injections as they are now, and returns
/// whether one was. It blocks on the session's delivery and
/// does not sleep. False at once for a document that is not attached.
///
/// # Safety
///
/// `snapshot` is a live snapshot handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_syntax_settle(
    snapshot: *const Snapshot,
    bound_ms: u64,
) -> bool {
    // SAFETY: the caller guarantees `snapshot` points to a live snapshot.
    syntaxes().settle(unsafe { &*snapshot }, Duration::from_millis(bound_ms))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::Document;
    use crate::events::{EventKind, Queue};
    use crate::words::tests::{buffer, words_of};

    /// The longest a test waits for a delivery.
    const BOUND: Duration = Duration::from_secs(10);

    /// The kinds of the events on `queue`, once it is quit, up to the quit.
    fn drained(queue: &Queue) -> Vec<EventKind> {
        queue.quit();
        let mut kinds = Vec::new();
        loop {
            let event = queue.next();
            if event.kind == EventKind::Quit {
                return kinds;
            }
            kinds.push(event.kind);
        }
    }

    #[test]
    fn a_delivery_with_a_highlighter_pushes_one_parsed_event_and_none_without() {
        static NOTICES: Queue = Queue::new();
        let service = Syntaxes::new(&NOTICES);
        let document = Document::new("{\"a\": 1}");
        let snapshot = Snapshot::of(&document);
        assert_eq!(service.attach(&snapshot, "json"), AttachStatus::Attached);
        assert!(service.settle(&snapshot, BOUND));
        // A second delivery, still with no highlighter.
        assert!(document.replace(7, 8, "2"));
        let second = Snapshot::of(&document);
        service.touched(second.key(), second.text().revision());
        assert!(service.settle(&second, BOUND));

        let grammar = GrammarName::new("json");
        let query = SyntaxQuery {
            query: Arc::new(
                service
                    .syntax
                    .compile(&grammar, "(number) @number")
                    .unwrap(),
            ),
            grammar,
        };
        assert_eq!(
            service.highlight(&second, &query, vec![Some("syntax.number".to_owned())]),
            HighlightStatus::Highlighted
        );
        // Highlighted again: still one notice for each delivery.
        assert_eq!(
            service.highlight(&second, &query, vec![None]),
            HighlightStatus::Highlighted
        );
        assert!(document.replace(7, 8, "3"));
        let third = Snapshot::of(&document);
        service.touched(third.key(), third.text().revision());
        assert!(service.settle(&third, BOUND));

        assert_eq!(drained(&NOTICES), [EventKind::Parsed]);
    }

    #[test]
    fn a_parsed_notice_is_the_syntax_services_event() {
        static NOTICES: Queue = Queue::new();
        let notice = ParsedNotice(&NOTICES);
        let snapshot = Document::new("1").snapshot();
        editor_syntax::Consumer::deliver(
            &notice,
            &editor_syntax::Parsed::new(snapshot.revision(), snapshot, ()),
        );
        NOTICES.quit();
        let event = NOTICES.next();
        assert_eq!(event.kind, EventKind::Parsed);
        assert_eq!(
            (event.source.kind, event.source.id),
            (SourceKind::Library, SERVICE)
        );
    }

    #[test]
    fn faces_cross_as_a_list_of_strings_the_empty_one_none() {
        assert_eq!(
            faces_of(&buffer(&[3, 6, 0, 14]), "stringsyntax.keyword"),
            Some(vec![
                Some("string".to_owned()),
                None,
                Some("syntax.keyword".to_owned())
            ])
        );
        assert_eq!(faces_of(&buffer(&[0]), ""), Some(vec![]));
        // Lengths that do not add up to the string spell no faces.
        assert_eq!(faces_of(&buffer(&[1, 3]), "ab"), None);
    }

    #[test]
    fn each_status_of_a_highlight_and_a_shipped_query_has_a_number_of_its_own() {
        let highlight = [
            HighlightStatus::Highlighted,
            HighlightStatus::NotAttached,
            HighlightStatus::WrongGrammar,
            HighlightStatus::BadFaces,
        ];
        assert_eq!(highlight.map(|status| status as u64), [0, 1, 2, 3]);
        let shipped = [
            ShippedStatus::Shipped,
            ShippedStatus::UnknownGrammar,
            ShippedStatus::NoShippedQuery,
        ];
        assert_eq!(shipped.map(|status| status as u64), [0, 1, 2]);
        assert_eq!(
            [0, 1, 2, 3, 4].map(query_kind_of),
            [
                Some(QueryKind::Highlights),
                Some(QueryKind::Injections),
                Some(QueryKind::TextObjects),
                Some(QueryKind::Indents),
                None
            ]
        );
    }

    #[test]
    fn each_status_of_an_injection_a_keep_and_a_kept_query_has_a_number_of_its_own() {
        let inject = [
            InjectStatus::Injected,
            InjectStatus::NotAttached,
            InjectStatus::WrongGrammar,
        ];
        assert_eq!(inject.map(|status| status as u64), [0, 1, 2]);
        let language = [
            InjectLanguageStatus::Injected,
            InjectLanguageStatus::NotAttached,
            InjectLanguageStatus::WrongGrammar,
            InjectLanguageStatus::BadFaces,
        ];
        assert_eq!(language.map(|status| status as u64), [0, 1, 2, 3]);
        let keep = [
            KeepStatus::Kept,
            KeepStatus::NotAttached,
            KeepStatus::WrongGrammar,
            KeepStatus::NoSuchKind,
        ];
        assert_eq!(keep.map(|status| status as u64), [0, 1, 2, 3]);
        let kept = [
            KeptStatus::Answered,
            KeptStatus::NotAttached,
            KeptStatus::NoQuery,
            KeptStatus::BadRange,
            KeptStatus::NotParsed,
            KeptStatus::NoSuchKind,
        ];
        assert_eq!(kept.map(|status| status as u64), [0, 1, 2, 3, 4, 5]);
        assert_eq!(
            [
                KeptRefusal::NoQuery,
                KeptRefusal::BadRange,
                KeptRefusal::NotParsed
            ]
            .map(KeptStatus::from),
            [
                KeptStatus::NoQuery,
                KeptStatus::BadRange,
                KeptStatus::NotParsed
            ]
        );
    }

    /// `source` compiled as a query of `grammar` by `service`.
    fn query_of(service: &Syntaxes, grammar: &str, source: &str) -> SyntaxQuery {
        let grammar = GrammarName::new(grammar);
        SyntaxQuery {
            query: Arc::new(service.syntax.compile(&grammar, source).unwrap()),
            grammar,
        }
    }

    #[test]
    fn an_injection_a_language_and_a_keep_are_refused_for_a_text_not_attached_or_a_wrong_grammar() {
        static NOTICES: Queue = Queue::new();
        let service = Syntaxes::new(&NOTICES);
        let document = Document::new("[1]");
        let snapshot = Snapshot::of(&document);
        let json = query_of(&service, "json", "(number) @n");
        let rust = query_of(&service, "rust", "(identifier) @i");

        assert_eq!(service.inject(&snapshot, &json), InjectStatus::NotAttached);
        assert_eq!(
            service.inject_language(&snapshot, "json", &json, vec![None], None),
            InjectLanguageStatus::NotAttached
        );
        assert_eq!(
            service.keep(&snapshot, QueryKind::Indents, &json),
            KeepStatus::NotAttached
        );
        assert_eq!(
            service.kept_captures(&snapshot, QueryKind::Indents, 0..3),
            Err(KeptStatus::NotAttached)
        );
        assert_eq!(service.attach(&snapshot, "json"), AttachStatus::Attached);
        assert_eq!(service.inject(&snapshot, &rust), InjectStatus::WrongGrammar);
        assert_eq!(
            service.keep(&snapshot, QueryKind::Indents, &rust),
            KeepStatus::WrongGrammar
        );
        // A language of another grammar than the text's is what an
        // injection is; only its injections query must be of its own.
        assert_eq!(
            service.inject_language(&snapshot, "rust", &rust, vec![None], Some(&json)),
            InjectLanguageStatus::WrongGrammar
        );
        assert_eq!(
            service.inject_language(&snapshot, "rust", &rust, vec![], None),
            InjectLanguageStatus::BadFaces
        );
        assert_eq!(
            service.inject_language(&snapshot, "rust", &rust, vec![None], None),
            InjectLanguageStatus::Injected
        );
        assert_eq!(service.inject(&snapshot, &json), InjectStatus::Injected);
        assert!(service.detach(snapshot.key()));
    }

    #[test]
    fn an_attach_with_the_same_grammar_keeps_the_kept_queries() {
        static NOTICES: Queue = Queue::new();
        let service = Syntaxes::new(&NOTICES);
        let document = Document::new("[1, 2]");
        let snapshot = Snapshot::of(&document);
        assert_eq!(service.attach(&snapshot, "json"), AttachStatus::Attached);
        let numbers = query_of(&service, "json", "(number) @n");
        assert_eq!(
            service.keep(&snapshot, QueryKind::TextObjects, &numbers),
            KeepStatus::Kept
        );
        drop(numbers);

        assert_eq!(service.attach(&snapshot, "json"), AttachStatus::Attached);
        assert!(service.settle(&snapshot, BOUND));
        assert_eq!(
            service.kept_names(&snapshot, QueryKind::TextObjects),
            Ok(vec!["n".to_owned()])
        );
        assert_eq!(
            service
                .kept_captures(&snapshot, QueryKind::TextObjects, 0..6)
                .map(|captures| captures.len()),
            Ok(2)
        );
        assert_eq!(
            service.kept_names(&snapshot, QueryKind::Indents),
            Err(KeptStatus::NoQuery)
        );
        assert!(service.detach(snapshot.key()));
    }

    #[test]
    fn a_detach_drops_the_kept_queries() {
        static NOTICES: Queue = Queue::new();
        let service = Syntaxes::new(&NOTICES);
        let document = Document::new("[1]");
        let snapshot = Snapshot::of(&document);
        assert_eq!(service.attach(&snapshot, "json"), AttachStatus::Attached);
        let numbers = query_of(&service, "json", "(number) @n");
        service.keep(&snapshot, QueryKind::Indents, &numbers);

        assert!(service.detach(snapshot.key()));
        assert_eq!(service.attach(&snapshot, "json"), AttachStatus::Attached);
        assert!(service.settle(&snapshot, BOUND));
        assert_eq!(
            service.kept_captures(&snapshot, QueryKind::Indents, 0..3),
            Err(KeptStatus::NoQuery)
        );
        assert!(service.detach(snapshot.key()));
    }

    #[test]
    fn a_list_of_strings_is_its_count_and_lengths_and_the_strings_end_to_end() {
        let strings = ["json".to_owned(), String::new(), "é".to_owned()];

        assert_eq!(words_of(&strings_words(&strings)), [3, 4, 0, 2]);
        assert_eq!(strings.concat(), "jsoné");
    }

    #[test]
    fn captures_are_their_count_and_four_words_each() {
        let captures = [
            Capture {
                pattern: 1,
                capture: 2,
                start: 3,
                end: 4,
            },
            Capture {
                pattern: 0,
                capture: 0,
                start: 0,
                end: 9,
            },
        ];

        assert_eq!(
            words_of(&captures_words(&captures)),
            [2, 1, 2, 3, 4, 0, 0, 0, 9]
        );
        assert_eq!(words_of(&captures_words(&[])), [0]);
    }

    #[test]
    fn each_kind_of_refusal_has_a_tag_of_its_own() {
        let kinds = [
            QueryErrorKind::Syntax,
            QueryErrorKind::NodeType,
            QueryErrorKind::Field,
            QueryErrorKind::Capture,
            QueryErrorKind::Predicate,
            QueryErrorKind::Structure,
            QueryErrorKind::Language,
        ];
        let tags: Vec<u64> = kinds.into_iter().map(kind_tag).collect();

        assert_eq!(tags, [0, 1, 2, 3, 4, 5, 6]);
    }
}
