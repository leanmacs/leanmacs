//! Excerpt documents: a document whose text is made of ranges of other
//! documents, its sources ([`editor_text::excerpt`]).
//!
//! An excerpt document is a [`Document`] like any other to every reader:
//! its text is the excerpt list's assembled text, so a snapshot of it, its
//! edit log, its markers and layout's patches are a plain text's. What
//! differs is in three places:
//!
//! - **It is caught up whenever it is locked** (`Document::lock`), under
//!   its list's lock, then its text's, then each source's in ascending key
//!   order. Every excerpt document takes its sources' locks in that one
//!   order, and an edit to a source takes only the source's own, so no two
//!   threads can wait for each other.
//! - **It holds its sources strongly** ([`Excerpted`]): a source document
//!   that is freed leaves its text to the excerpt documents that read it,
//!   read as it was when it was freed, since nothing can edit it any more.
//! - **Its edits are its sources'.** A replace ([`Document::replace_status`])
//!   or a transaction ([`Document::apply`]) of an excerpt document is made
//!   of its sources by [`Excerpts::edit`]: one transaction on each source
//!   it changes, with the caller's origin, all or nothing, and one catch-up
//!   of the excerpt document. It takes the locks a catch-up takes, in the
//!   same order, so the argument above still holds. Each source it changed
//!   tells the syntax service, once every lock is let go. An edit that
//!   reaches an excerpt of a freed source is refused
//!   ([`ReplaceStatus::NoSuchSource`],
//!   [`ApplyStatus::NoSuchSource`]):
//!   nothing could undo it. An edit outside one excerpt is refused as
//!   [`ReplaceStatus::OutsideExcerpt`] or
//!   [`ApplyStatus::OutsideExcerpt`].
//! - **Its inverse, edit script and trace are refused**, before it is
//!   locked, so a refusal catches nothing up: applying an edit script
//!   answers
//!   [`ApplyStatus::Excerpted`],
//!   applying an inverse
//!   [`InverseStatus::Excerpted`](crate::inverse::InverseStatus::Excerpted),
//!   and a trace nothing. Marking, reading the log, forgetting it and
//!   dropping kept inverses work as on any document.
//! - **Where an offset is** ([`Document::locate`],
//!   [`editor_ffi_excerpts_locate`]): which excerpt holds it and the offset
//!   in its source, so the editor can tell which source an edit reaches
//!   before it makes it.
//!
//! **What hands an excerpt document out**: [`editor_ffi_excerpts_new`], a
//! document handle like those [`crate::document`] lists, freed by
//! [`editor_ffi_document_free`](crate::document::editor_ffi_document_free),
//! which gives up the anchors it holds in its sources.
//!
//! **Its list crosses as words**: [`editor_ffi_excerpts_set`] takes a C
//! array of the source documents' handles, which the glue builds from a Lean
//! `Array`, and words: the count of excerpts, then three words for each,
//! the index of its source in that array, its start and its end. It
//! answers with a status ([`ExcerptStatus`]).

use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};

use editor_text::excerpt::{Edited, ExcerptError, Excerpts, SourceKey, Wanted};
use editor_text::{Origin, Revision, Text, Transaction};

use crate::document::{Document, ReplaceStatus, hand_out};
use crate::transaction::ApplyStatus;
use crate::words::Reader;

/// One source of an excerpt document: its document's key, its text, held
/// strongly, and whether its document still lives
/// ([`Document::alive`]).
type Source = (u64, Arc<Mutex<Text>>, Weak<()>);

/// The list of an excerpt document and the texts of its sources, each by
/// its document's key, sorted by key with no key twice. The texts are held
/// strongly: an excerpt document keeps reading a source whose document was
/// freed, and edits only those whose document lives.
#[derive(Default)]
pub struct Excerpted {
    /// The list.
    list: Excerpts,
    /// The sources the list names.
    sources: Vec<Source>,
}

/// `text`, locked; a poisoned lock is used as it is, as a document does.
fn lock(text: &Mutex<Text>) -> MutexGuard<'_, Text> {
    text.lock().unwrap_or_else(PoisonError::into_inner)
}

/// What `work` returns of `sources`, each locked in the order given, which
/// is ascending key order, and handed over with its key.
fn locked<T>(sources: &[Source], work: impl FnOnce(&mut [(SourceKey, &mut Text)]) -> T) -> T {
    let mut guards: Vec<(u64, MutexGuard<'_, Text>)> = sources
        .iter()
        .map(|(key, text, _)| (*key, lock(text)))
        .collect();
    let mut texts: Vec<(SourceKey, &mut Text)> = guards
        .iter_mut()
        .map(|(key, guard)| (SourceKey(*key), &mut **guard))
        .collect();
    work(&mut texts)
}

/// `sources` sorted by key with no key twice.
fn sorted(mut sources: Vec<Source>) -> Vec<Source> {
    sources.sort_by_key(|(key, _, _)| *key);
    sources.dedup_by_key(|(key, _, _)| *key);
    sources
}

impl Excerpted {
    /// Catches `assembled`, the document's text, up with the sources
    /// ([`Excerpts::refresh`]). Its caller holds this list's lock and the
    /// text's; the sources' are taken here, in ascending key order.
    pub(crate) fn refresh(&mut self, assembled: &mut Text) {
        let Self { list, sources } = self;
        // Only the list writes the text, an edit of it being the list's
        // too, so the list is never refused here.
        let _ = locked(sources, |texts| list.refresh(assembled, texts));
    }

    /// Makes the transaction `make` builds of `assembled`, the document's
    /// text, caught up, an edit of the sources ([`Excerpts::edit`]). Its
    /// caller holds this list's lock and the text's; the sources' are taken
    /// here, in ascending key order, and held from the catch-up to the
    /// edit, so the transaction is built of the text the edit is checked
    /// against. `make` refuses with `None`, which is
    /// [`ExcerptError::BadRange`].
    ///
    /// The text is caught up with every source, and the edit is then given
    /// only those whose document lives: one that reaches a freed source is
    /// refused with [`ExcerptError::NoSuchSource`].
    pub(crate) fn edit(
        &mut self,
        assembled: &mut Text,
        origin: Origin,
        make: impl FnOnce(&editor_text::Snapshot) -> Option<Transaction>,
    ) -> Result<Edited, ExcerptError> {
        let Self { list, sources } = self;
        let alive: Vec<bool> = sources
            .iter()
            .map(|(_, _, alive)| alive.upgrade().is_some())
            .collect();
        locked(sources, |texts| {
            list.refresh(assembled, texts)?;
            let transaction = make(assembled.current()).ok_or(ExcerptError::BadRange)?;
            let mut living: Vec<(SourceKey, &mut Text)> = texts
                .iter_mut()
                .zip(alive)
                .filter(|(_, alive)| *alive)
                .map(|((key, text), _)| (*key, &mut **text))
                .collect();
            list.edit(assembled, &transaction, origin, &mut living)
        })
    }

    /// Gives up every anchor the list holds in its sources and empties it.
    pub(crate) fn release(&mut self) {
        let Self { list, sources } = self;
        locked(sources, |texts| list.release(texts));
        sources.clear();
    }
}

/// How replacing an excerpt document's list ended, as it crosses the
/// boundary. The refusals are looked for in this order, all before
/// anything changes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExcerptStatus {
    /// The list was replaced.
    Done = 0,
    /// Refused: the document is not an excerpt document.
    NotExcerpts = 1,
    /// Refused: a source is an excerpt document.
    Excerpted = 2,
    /// Refused: the words could not be read, or an index names no source
    /// of the array.
    Unreadable = 3,
    /// Refused: a range is not two positions of its source in order.
    BadRange = 4,
}

impl Document {
    /// Replaces the list of this excerpt document with the excerpts `words`
    /// spell over `sources`, in the layout the module docs give. Anything but [`ExcerptStatus::Done`] changed nothing;
    /// the order of the refusals is [`ExcerptStatus`]'s.
    ///
    /// The list's lock is taken, then the text's, then every source's of
    /// the list as it is and as it will be, in ascending key order, so the
    /// anchors of an excerpt dropped from the list are given up even when
    /// its source is not among `sources`. Afterwards the document holds the
    /// texts of the sources the new list names, and no others.
    pub fn set_excerpts(&self, sources: &[&Document], words: &[u8]) -> ExcerptStatus {
        let Some(mut excerpted) = self.excerpted() else {
            return ExcerptStatus::NotExcerpts;
        };
        if sources.iter().any(|source| source.is_excerpts()) {
            return ExcerptStatus::Excerpted;
        }
        let Some((wanted, named)) = read(sources, words) else {
            return ExcerptStatus::Unreadable;
        };
        let mut every = excerpted.sources.clone();
        every.extend(named.iter().cloned());
        let every = sorted(every);

        let mut text = self.text_locked();
        let Excerpted { list, .. } = &mut *excerpted;
        let set = locked(&every, |texts| list.set(&mut text, &wanted, texts));
        match set {
            Ok(_) => {
                excerpted.sources = named;
                ExcerptStatus::Done
            }
            Err(ExcerptError::BadRange) => ExcerptStatus::BadRange,
            Err(ExcerptError::Excerpted) => ExcerptStatus::Excerpted,
            // Every source of both lists was given, and only the list
            // writes the text: neither is expected. The rest are an edit's
            // refusals, which replacing a list does not make.
            Err(
                ExcerptError::NoSuchSource
                | ExcerptError::Moved
                | ExcerptError::OutsideExcerpt
                | ExcerptError::BadChange
                | ExcerptError::BadSelection,
            ) => ExcerptStatus::Unreadable,
        }
    }
}

/// How asking where an offset of an excerpt document is ended, as it
/// crosses the boundary ([`Document::locate`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LocateStatus {
    /// Found: the record holds the excerpt and the offset in its source.
    Found = 0,
    /// The document is not an excerpt document.
    NotExcerpts = 1,
    /// The offset is not a position of the excerpt text.
    BadPosition = 2,
    /// The list is empty, so no excerpt holds the offset.
    Empty = 3,
}

/// Where an offset of an excerpt document is: one record, filled in one
/// call ([`editor_ffi_excerpts_locate`]).
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RawLocated {
    /// The index of the excerpt in the list.
    pub excerpt: usize,
    /// The offset in the excerpt's source, as the source is now.
    pub offset: usize,
}

impl Document {
    /// Makes `transaction`, an edit of this excerpt document, of its
    /// sources, recording `origin` as who made each source's edit, and
    /// returns the excerpt document's revision after it. Anything but `Ok`
    /// changed no source.
    ///
    /// The list's lock is taken, then the text's, then the sources', in
    /// ascending key order: a catch-up's order. Each source the edit
    /// changed tells the syntax service once they are let go; the excerpt
    /// document itself is not parsed.
    pub(crate) fn edit_excerpts(
        &self,
        transaction: &Transaction,
        origin: Origin,
    ) -> Result<Revision, ApplyStatus> {
        self.edit_excerpts_with(origin, |_| Some(transaction.clone()))
    }

    /// [`edit_excerpts`](Self::edit_excerpts) of the transaction `make`
    /// builds of the excerpt text caught up, under the same locks
    /// ([`Excerpted::edit`]). `make` refuses with `None`, which is
    /// [`ApplyStatus::BadChange`].
    fn edit_excerpts_with(
        &self,
        origin: Origin,
        make: impl FnOnce(&editor_text::Snapshot) -> Option<Transaction>,
    ) -> Result<Revision, ApplyStatus> {
        let Some(mut excerpted) = self.excerpted() else {
            // Only an excerpt document comes here.
            return Err(ApplyStatus::BadChange);
        };
        let mut text = self.text_locked();
        let edited = excerpted.edit(&mut text, origin, make);
        drop(text);
        drop(excerpted);
        let edited = edited.map_err(|error| match error {
            ExcerptError::BadChange => ApplyStatus::BadChange,
            ExcerptError::BadSelection => ApplyStatus::BadSelection,
            ExcerptError::OutsideExcerpt => ApplyStatus::OutsideExcerpt,
            ExcerptError::NoSuchSource => ApplyStatus::NoSuchSource,
            // A transaction that could not be built is one that does not
            // fit. Only the list writes the text and a source is never an
            // excerpt document, so neither of the others is expected.
            ExcerptError::BadRange | ExcerptError::Moved | ExcerptError::Excerpted => {
                ApplyStatus::BadChange
            }
        })?;
        for (key, revision) in edited.sources {
            crate::syntax::touched(key.0, revision);
        }
        Ok(edited.revision)
    }

    /// [`Document::replace_status`] of an excerpt document: the replace is
    /// checked as a plain text's would be, against the text caught up, and
    /// then made of the sources with the default origin.
    pub(crate) fn replace_excerpts(&self, start: usize, end: usize, text: &str) -> ReplaceStatus {
        let replaced = self.edit_excerpts_with(Origin::default(), |current| {
            // As a plain text's replace: an identity change set has no
            // boundary at the range for the fit to refuse.
            if !current.is_char_boundary(start) || !current.is_char_boundary(end) {
                return None;
            }
            editor_text::ChangeSet::replacing(current.len(), start..end, text).map(Transaction::new)
        });
        match replaced {
            Ok(_) => ReplaceStatus::Done,
            Err(ApplyStatus::OutsideExcerpt) => ReplaceStatus::OutsideExcerpt,
            Err(ApplyStatus::NoSuchSource) => ReplaceStatus::NoSuchSource,
            // A range that is not two positions in order is refused as a
            // change set that does not fit, or a selection, which a replace
            // has none of: both are a bad range here. The rest are not
            // expected of a replace.
            Err(
                ApplyStatus::BadChange
                | ApplyStatus::BadSelection
                | ApplyStatus::Unreadable
                | ApplyStatus::Moved
                | ApplyStatus::Excerpted
                | ApplyStatus::Applied,
            ) => ReplaceStatus::BadRange,
        }
    }

    /// Which excerpt of this excerpt document holds the position `offset`
    /// of its text, caught up first, and the offset in that excerpt's
    /// source as the source is now ([`Excerpts::locate`]). An excerpt holds
    /// both its ends.
    pub fn locate(&self, offset: usize) -> Result<(usize, usize), LocateStatus> {
        let Some(mut excerpted) = self.excerpted() else {
            return Err(LocateStatus::NotExcerpts);
        };
        let mut text = self.text_locked();
        excerpted.refresh(&mut text);
        if !text.current().is_char_boundary(offset) {
            return Err(LocateStatus::BadPosition);
        }
        excerpted
            .list
            .locate(offset)
            .map(|(excerpt, _, offset)| (excerpt, offset))
            .ok_or(LocateStatus::Empty)
    }
}

/// [`Document::locate`] for C: fills `out` with the excerpt of `document`
/// that holds `offset` and the offset in its source, and returns a
/// [`LocateStatus`] as its number. `out` is written only for
/// [`LocateStatus::Found`].
///
/// # Safety
///
/// `document` is a document handle this library handed out and has not
/// taken back, and `out` points to a writable [`RawLocated`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_excerpts_locate(
    document: *const Document,
    offset: usize,
    out: *mut RawLocated,
) -> u64 {
    // SAFETY: the caller guarantees `document` points to a live document.
    match unsafe { &*document }.locate(offset) {
        Ok((excerpt, offset)) => {
            // SAFETY: the caller guarantees `out` is writable.
            unsafe { out.write(RawLocated { excerpt, offset }) };
            LocateStatus::Found as u64
        }
        Err(status) => status as u64,
    }
}

/// The excerpts `words` spell over `sources`, in the layout the module docs
/// give, and the texts of the sources they name, sorted by key with no key
/// twice. `None` when the words cannot be read or an index names no source.
fn read(sources: &[&Document], words: &[u8]) -> Option<(Vec<Wanted>, Vec<Source>)> {
    let mut reader = Reader::new(words)?;
    let count = reader.count(3)?;
    let mut wanted = Vec::with_capacity(count);
    let mut named = Vec::with_capacity(count);
    for _ in 0..count {
        let source = sources.get(reader.size()?)?;
        let range = reader.size()?..reader.size()?;
        wanted.push(Wanted {
            source: SourceKey(source.key()),
            range,
        });
        named.push((source.key(), source.text(), source.alive()));
    }
    reader.finish()?;
    Some((wanted, sorted(named)))
}

/// A new excerpt document with no excerpts, owned by the caller, who must
/// hand it to [`editor_ffi_document_free`](crate::document::editor_ffi_document_free)
/// exactly once. It is counted live as any document is.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_excerpts_new() -> *mut Document {
    hand_out(Document::excerpts())
}

/// [`Document::set_excerpts`] for C: replaces the list of `document` with
/// the excerpts the `words_len` bytes at `words` spell, over the
/// `source_count` documents at `sources`, and returns an [`ExcerptStatus`]
/// as its number.
///
/// # Safety
///
/// `document` and each of the `source_count` pointers at `sources` are
/// document handles this library handed out and has not taken back, and
/// `words` points to `words_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_excerpts_set(
    document: *const Document,
    sources: *const *const Document,
    source_count: usize,
    words: *const u8,
    words_len: usize,
) -> u64 {
    // SAFETY: the caller guarantees the pointers and the counts.
    let (handles, words) = unsafe {
        (
            handles(sources, source_count),
            crate::words::borrow(words, words_len),
        )
    };
    // SAFETY: the caller guarantees each handle points to a live document.
    let sources: Vec<&Document> = handles.iter().map(|&each| unsafe { &*each }).collect();
    // SAFETY: the caller guarantees `document` points to a live document.
    unsafe { &*document }.set_excerpts(&sources, words) as u64
}

/// The `count` handles at `pointer` as a slice, which is empty for a count
/// of 0 whatever the pointer.
///
/// # Safety
///
/// Unless `count` is 0, `pointer` points to `count` readable pointers that
/// outlive the slice.
unsafe fn handles<'a>(pointer: *const *const Document, count: usize) -> &'a [*const Document] {
    if count == 0 {
        return &[];
    }
    // SAFETY: the caller guarantees the pointer and the count.
    unsafe { std::slice::from_raw_parts(pointer, count) }
}

/// Whether `document` is an excerpt document.
///
/// # Safety
///
/// `document` is a document handle this library handed out and has not
/// taken back.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_document_is_excerpts(document: *const Document) -> bool {
    // SAFETY: the caller guarantees `document` points to a live document.
    unsafe { &*document }.is_excerpts()
}

#[cfg(test)]
mod tests {
    use std::thread;

    use editor_text::{Anchor, Bias, ChangeSet, Marker, MarkerId, Origin, Revision, Transaction};

    use super::*;
    use crate::display::text_ref;
    use crate::inverse::InverseStatus;
    use crate::snapshot::Snapshot;
    use crate::transaction::ApplyStatus;
    use crate::words::tests::buffer;

    /// The first source; excerpts take its second row, `4..8`.
    const ONE: &str = "one\ntwo\nthree\n";
    /// The second source; excerpts take its first row, `0..6`.
    const TWO: &str = "alpha\nbeta\n";

    /// An excerpt document of the second row of `one` and the first of
    /// `two`.
    fn rows_of(one: &Document, two: &Document) -> Document {
        let excerpts = Document::excerpts();
        let status = excerpts.set_excerpts(&[one, two], &buffer(&[2, 0, 4, 8, 1, 0, 6]));
        assert_eq!(status, ExcerptStatus::Done);
        excerpts
    }

    #[test]
    fn an_excerpt_document_over_two_documents_reads_their_ranges_joined() {
        let (one, two) = (Document::new(ONE), Document::new(TWO));

        let excerpts = rows_of(&one, &two);

        assert!(excerpts.is_excerpts());
        assert!(!one.is_excerpts());
        assert_eq!(excerpts.read(), "two\n\nalpha\n");
        assert_eq!(Document::excerpts().read(), "");
    }

    #[test]
    fn an_edit_to_a_source_reaches_the_next_snapshot_and_layouts_patch() {
        let (one, two) = (Document::new(ONE), Document::new(TWO));
        let excerpts = rows_of(&one, &two);
        let before = Snapshot::of(&excerpts);
        let revision = before.text().revision();

        assert!(one.replace(5, 5, "X"));
        let after = Snapshot::of(&excerpts);

        assert_eq!(after.text().to_string(), "tXwo\n\nalpha\n");
        assert_eq!(after.text().revision().get(), revision.get() + 1);
        assert_eq!(before.text().to_string(), "two\n\nalpha\n");
        let patch = text_ref(&before)
            .changes
            .since(revision)
            .expect("the excerpt document's log holds it");
        assert_eq!(patch.edits.len(), 1);
        assert_eq!((patch.edits[0].new.start, patch.edits[0].new.end), (1, 2));
    }

    /// The transaction that replaces `range` of a text of `len` bytes with
    /// `text`.
    fn replacing(len: usize, range: std::ops::Range<usize>, text: &str) -> Transaction {
        Transaction::new(ChangeSet::replacing(len, range, text).expect("a range within the length"))
    }

    /// The transaction over the fixture's excerpt text that inserts "X" in
    /// the first excerpt, at 1, and replaces the first byte of the second,
    /// at 5, with "A".
    fn both() -> Transaction {
        let mut changes = ChangeSet::new();
        changes.retain(1);
        changes.insert("X");
        changes.retain(4);
        changes.insert("A");
        changes.delete(1);
        changes.retain(5);
        Transaction::new(changes)
    }

    #[test]
    fn a_replace_and_an_apply_on_an_excerpt_document_edit_its_sources() {
        let (one, two) = (Document::new(ONE), Document::new(TWO));
        let excerpts = rows_of(&one, &two);
        let revision = excerpts.snapshot().revision();

        assert_eq!(excerpts.replace_status(1, 1, "X"), ReplaceStatus::Done);
        assert_eq!(one.read(), "one\ntXwo\nthree\n");
        assert_eq!(excerpts.read(), "tXwo\n\nalpha\n");
        assert_eq!(excerpts.snapshot().revision().get(), revision.get() + 1);

        let applied = excerpts.apply(&replacing(12, 6..7, "A"), Origin::new(5));
        assert_eq!(applied, Ok(excerpts.snapshot().revision()));
        assert_eq!(two.read(), "Alpha\nbeta\n");
        let entry = two
            .changes_since(Revision::new(0))
            .expect("the log holds it");
        assert_eq!(entry.edits.len(), 1);
        assert_eq!(excerpts.read(), "tXwo\n\nAlpha\n");
        // The bool of a replace is whether it was done.
        assert!(excerpts.replace(0, 0, "!"));
        assert_eq!(one.read(), "one\n!tXwo\nthree\n");
    }

    #[test]
    fn a_transaction_across_both_excerpts_edits_both_sources() {
        let (one, two) = (Document::new(ONE), Document::new(TWO));
        let excerpts = rows_of(&one, &two);

        // The changes of `both`, as words, and no selection before or
        // after.
        let words = buffer(&[6, 0, 1, 2, 1, 0, 4, 2, 1, 1, 1, 0, 5, 0, 0]);

        let applied = excerpts.apply_words(&words, b"XA", 9);

        assert_eq!(applied.status, ApplyStatus::Applied as u64);
        assert_eq!(one.read(), "one\ntXwo\nthree\n");
        assert_eq!(two.read(), "Alpha\nbeta\n");
        assert_eq!(excerpts.read(), "tXwo\n\nAlpha\n");
        assert_eq!(applied.revision, excerpts.snapshot().revision().get());
    }

    #[test]
    fn an_excerpt_documents_refused_edits_say_why_and_change_nothing() {
        let (one, two) = (Document::new("héllo\n"), Document::new(TWO));
        let excerpts = Document::excerpts();
        assert_eq!(
            excerpts.set_excerpts(&[&one, &two], &buffer(&[2, 0, 0, 7, 1, 0, 6])),
            ExcerptStatus::Done
        );
        assert_eq!(excerpts.read(), "héllo\n\nalpha\n");
        let revision = excerpts.snapshot().revision();
        let selection = |at| {
            editor_text::Selection::new(vec![editor_text::SelectionRange::new(at, at)], 0)
                .expect("one range")
        };

        // The separator, a range past the end and one backwards, and an
        // offset inside "é", inserting and inserting nothing.
        for (start, end, text, status) in [
            (7, 8, "", ReplaceStatus::OutsideExcerpt),
            (0, 99, "", ReplaceStatus::BadRange),
            (3, 1, "", ReplaceStatus::BadRange),
            (2, 2, "x", ReplaceStatus::BadRange),
            (2, 2, "", ReplaceStatus::BadRange),
            (2, 3, "", ReplaceStatus::BadRange),
        ] {
            assert_eq!(
                excerpts.replace_status(start, end, text),
                status,
                "{start}..{end} {text:?}"
            );
        }
        assert!(!excerpts.replace(7, 8, ""));
        for (transaction, status) in [
            (replacing(14, 7..8, ""), ApplyStatus::OutsideExcerpt),
            (
                replacing(14, 1..1, "X").with_after(selection(99)),
                ApplyStatus::BadSelection,
            ),
            (replacing(13, 1..1, "X"), ApplyStatus::BadChange),
            (replacing(14, 2..2, "X"), ApplyStatus::BadChange),
        ] {
            assert_eq!(excerpts.apply(&transaction, Origin::new(1)), Err(status));
        }

        assert_eq!(one.read(), "héllo\n");
        assert_eq!(two.read(), TWO);
        assert_eq!(excerpts.read(), "héllo\n\nalpha\n");
        assert_eq!(excerpts.snapshot().revision(), revision);
    }

    #[test]
    fn an_excerpt_documents_inverse_edit_script_and_trace_are_still_refused() {
        let (one, two) = (Document::new(ONE), Document::new(TWO));
        let excerpts = rows_of(&one, &two);
        let revision = excerpts.snapshot().revision();

        assert_eq!(
            excerpts.apply_script(
                revision.get(),
                &editor_text::Snapshot::default(),
                &[],
                Origin::new(1)
            ),
            Err(ApplyStatus::Excerpted)
        );
        assert_eq!(
            excerpts
                .apply_inverse(Revision::new(1), Revision::new(1), Origin::new(1))
                .map(|inverted| inverted.revision),
            Err(InverseStatus::Excerpted)
        );
        assert_eq!(excerpts.trace(0..3), None);
        // Words that cannot be read are that, on an excerpt document too.
        assert_eq!(
            excerpts.apply_words(&[], b"", 1).status,
            ApplyStatus::Unreadable as u64
        );

        assert_eq!(excerpts.read(), "two\n\nalpha\n");
        assert_eq!(excerpts.snapshot().revision(), revision);
    }

    #[test]
    fn an_edit_that_reaches_a_freed_source_is_refused_and_changes_neither() {
        let (one, two) = (Document::new(ONE), Document::new(TWO));
        let excerpts = rows_of(&one, &two);
        assert!(one.replace(0, 0, "zero\n"));
        let two_revision = two.snapshot().revision();
        drop(one);

        assert_eq!(
            excerpts.apply(&both(), Origin::new(1)),
            Err(ApplyStatus::NoSuchSource)
        );
        assert_eq!(
            excerpts.replace_status(1, 1, "X"),
            ReplaceStatus::NoSuchSource
        );

        assert_eq!(two.read(), TWO);
        assert_eq!(two.snapshot().revision(), two_revision);
        assert_eq!(excerpts.read(), "two\n\nalpha\n");
        // The other source is still edited through it.
        assert_eq!(excerpts.replace_status(5, 5, "A"), ReplaceStatus::Done);
        assert_eq!(two.read(), "Aalpha\nbeta\n");
    }

    #[test]
    fn locate_answers_an_excerpt_and_a_source_offset_or_why_not() {
        let (one, two) = (Document::new(ONE), Document::new(TWO));
        let excerpts = rows_of(&one, &two);
        assert!(one.replace(0, 0, "zero\n"));

        assert_eq!(excerpts.locate(0), Ok((0, 9)));
        assert_eq!(excerpts.locate(4), Ok((0, 13)));
        assert_eq!(excerpts.locate(5), Ok((1, 0)));
        assert_eq!(excerpts.locate(11), Ok((1, 6)));
        assert_eq!(excerpts.locate(12), Err(LocateStatus::BadPosition));
        assert_eq!(one.locate(0), Err(LocateStatus::NotExcerpts));
        assert_eq!(Document::excerpts().locate(0), Err(LocateStatus::Empty));
        let wide = Document::new("é");
        let over = Document::excerpts();
        assert_eq!(
            over.set_excerpts(&[&wide], &buffer(&[1, 0, 0, 2])),
            ExcerptStatus::Done
        );
        assert_eq!(over.locate(1), Err(LocateStatus::BadPosition));
    }

    #[test]
    fn markers_forgetting_and_dropping_inverses_work_on_an_excerpt_document() {
        let (one, two) = (Document::new(ONE), Document::new(TWO));
        let excerpts = rows_of(&one, &two);
        let marked = excerpts
            .mark(Marker::Anchor(Anchor::new(5, Bias::Before)))
            .expect("5 is a position");

        assert!(one.replace(0, 0, "zero\n"));
        assert!(two.replace(0, 0, "A"));

        assert_eq!(
            excerpts.marker(marked),
            Some(Marker::Anchor(Anchor::new(5, Bias::Before)))
        );
        let revision = excerpts.snapshot().revision();
        assert_eq!(excerpts.forget(revision), Ok(()));
        assert_eq!(excerpts.drop_inverses(revision, revision), Ok(()));
        assert_eq!(excerpts.read(), "two\n\nAalpha\n");
    }

    #[test]
    fn replacing_a_list_is_refused_in_order_and_changes_nothing() {
        let (one, two) = (Document::new(ONE), Document::new(TWO));
        let excerpts = rows_of(&one, &two);
        let other = rows_of(&one, &two);
        let revision = excerpts.snapshot().revision();

        // A plain document, whatever its sources and words.
        assert_eq!(
            one.set_excerpts(&[&other], &buffer(&[1, 0, 9, 0, 1])),
            ExcerptStatus::NotExcerpts
        );
        // A source that is an excerpt document, whatever the words.
        assert_eq!(
            excerpts.set_excerpts(&[&one, &other], &buffer(&[1, 0, 9, 0, 1])),
            ExcerptStatus::Excerpted
        );
        // Words left over, and an index of no source.
        assert_eq!(
            excerpts.set_excerpts(&[&one], &buffer(&[1, 0, 0, 9, 1])),
            ExcerptStatus::Unreadable
        );
        assert_eq!(
            excerpts.set_excerpts(&[&one], &buffer(&[1, 1, 0, 9])),
            ExcerptStatus::Unreadable
        );
        // A range out of order.
        assert_eq!(
            excerpts.set_excerpts(&[&one], &buffer(&[1, 0, 9, 0])),
            ExcerptStatus::BadRange
        );

        assert_eq!(excerpts.read(), "two\n\nalpha\n");
        assert_eq!(excerpts.snapshot().revision(), revision);
    }

    #[test]
    fn a_list_that_drops_a_source_the_caller_leaves_out_gives_up_its_anchors_and_its_text() {
        let (one, two) = (Document::new(ONE), Document::new(TWO));
        let excerpts = rows_of(&one, &two);
        let one_text = Arc::downgrade(&one.text());

        // Only the second source is given: the first is dropped from the
        // list all the same.
        assert_eq!(
            excerpts.set_excerpts(&[&two], &buffer(&[1, 0, 6, 10])),
            ExcerptStatus::Done
        );

        assert_eq!(excerpts.read(), "beta");
        assert_eq!(one.marker(MarkerId::new(0)), None);
        assert_eq!(one.marker(MarkerId::new(1)), None);
        drop(one);
        assert!(
            one_text.upgrade().is_none(),
            "the excerpt document let it go"
        );
    }

    #[test]
    fn a_freed_source_is_read_as_it_was_when_it_was_freed() {
        let (one, two) = (Document::new(ONE), Document::new(TWO));
        let excerpts = rows_of(&one, &two);

        assert!(one.replace(5, 5, "X"));
        drop(one);

        assert_eq!(excerpts.read(), "tXwo\n\nalpha\n");
        assert!(two.replace(0, 0, "A"));
        assert_eq!(excerpts.read(), "tXwo\n\nAalpha\n");
    }

    #[test]
    fn a_freed_excerpt_document_gives_up_its_anchors_in_its_sources() {
        let (one, two) = (Document::new(ONE), Document::new(TWO));
        let excerpts = rows_of(&one, &two);
        assert!(one.marker(MarkerId::new(0)).is_some());

        drop(excerpts);

        for id in 0..2 {
            assert_eq!(one.marker(MarkerId::new(id)), None);
            assert_eq!(two.marker(MarkerId::new(id)), None);
        }
    }

    #[test]
    fn two_excerpt_documents_over_two_sources_in_opposite_orders_are_read_while_a_source_is_edited()
    {
        /// How many reads and edits each thread makes.
        const ROUNDS: usize = 300;
        let (one, two) = (Document::new(ONE), Document::new(TWO));
        let forward = rows_of(&one, &two);
        let backward = Document::excerpts();
        assert_eq!(
            backward.set_excerpts(&[&two, &one], &buffer(&[2, 0, 0, 6, 1, 4, 8])),
            ExcerptStatus::Done
        );

        thread::scope(|scope| {
            scope.spawn(|| {
                for _ in 0..ROUNDS {
                    assert!(forward.read().ends_with("\n\nalpha\n"));
                }
            });
            scope.spawn(|| {
                for _ in 0..ROUNDS {
                    assert!(backward.read().starts_with("alpha\n\n"));
                }
            });
            scope.spawn(|| {
                for _ in 0..ROUNDS {
                    assert!(one.replace(5, 5, "x"));
                }
            });
        });

        let expected = format!("t{}wo\n", "x".repeat(ROUNDS));
        assert_eq!(forward.read(), format!("{expected}\nalpha\n"));
        assert_eq!(backward.read(), format!("alpha\n\n{expected}"));
    }

    #[test]
    fn a_source_edited_through_an_excerpt_document_and_directly_while_another_reads_it_finishes() {
        /// How many reads and edits each thread makes.
        const ROUNDS: usize = 300;
        let (one, two) = (Document::new(ONE), Document::new(TWO));
        let forward = rows_of(&one, &two);
        let backward = Document::excerpts();
        assert_eq!(
            backward.set_excerpts(&[&two, &one], &buffer(&[2, 0, 0, 6, 1, 4, 8])),
            ExcerptStatus::Done
        );

        thread::scope(|scope| {
            scope.spawn(|| {
                for _ in 0..ROUNDS {
                    assert_eq!(forward.replace_status(1, 1, "x"), ReplaceStatus::Done);
                }
            });
            scope.spawn(|| {
                for _ in 0..ROUNDS {
                    assert!(one.replace(5, 5, "y"));
                }
            });
            scope.spawn(|| {
                for _ in 0..ROUNDS {
                    assert!(backward.read().starts_with("alpha\n\nt"));
                }
            });
        });

        let row = one.read()[4..].to_owned();
        assert_eq!(row.len(), "two\nthree\n".len() + 2 * ROUNDS);
        assert_eq!(row.matches('x').count(), ROUNDS);
        assert_eq!(row.matches('y').count(), ROUNDS);
        assert_eq!(
            forward.read(),
            format!("{}\nalpha\n", &row[..row.len() - 6])
        );
    }
}
