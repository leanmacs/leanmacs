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
//! | [`editor_ffi_syntax_settle`] | for tests: wait, with a bound, for the snapshot's revision to be delivered |
//!
//! **A query is answered from the tree delivered, never parsed for.**
//! [`editor_ffi_syntax_captures`] answers only when the last tree the
//! document's session delivered is of the snapshot's revision, and is
//! otherwise [`CapturesStatus::NotParsed`]: the editor thread never waits
//! for a parse. A caller asks again after the next delivery. The rule and
//! the order of the refusals are the session's (`Session::captures`).
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

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};
use std::thread;
use std::time::Duration;

use editor_syntax::{
    Capture, CapturesRefusal, GrammarName, Handle, QueryErrorKind, Session, Syntax, Worker,
};
use editor_syntax_treesitter::TreeSitter;
use editor_text::Revision;

use crate::log::RawWords;
use crate::snapshot::Snapshot;
use crate::{text, words};

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
    /// The query.
    query: <TreeSitter as Syntax>::Query,
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
    SYNTAXES.get_or_init(|| Syntaxes {
        syntax: Arc::new(TreeSitter),
        worker: Mutex::new(None),
        attached: Mutex::new(HashMap::new()),
    })
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
    pub fn attach(&self, snapshot: &Snapshot, grammar: &str) -> AttachStatus {
        let grammar = GrammarName::new(grammar);
        if !self.grammars().contains(&grammar) {
            return AttachStatus::UnknownGrammar;
        }
        let source = snapshot.source();
        if !source.has_document() {
            return AttachStatus::NoDocument;
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

    /// Waits up to `bound` for a tree of `snapshot`'s revision, or a newer
    /// one, to be delivered; whether one was. False at once when its
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
                    query: Box::into_raw(Box::new(SyntaxQuery { grammar, query })),
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

/// For tests, like the other readouts: waits up to `bound_ms` milliseconds
/// for a tree of `snapshot`'s revision, or a newer one, to be delivered,
/// and returns whether one was. It blocks on the session's delivery and
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
    use crate::words::tests::words_of;

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
