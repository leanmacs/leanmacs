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
//! - **Its edits are refused** in this phase, before it is locked, so a
//!   refusal catches nothing up: [`Document::replace`] returns false,
//!   applying a transaction or an edit script answers
//!   [`ApplyStatus::Excerpted`](crate::transaction::ApplyStatus::Excerpted),
//!   applying an inverse
//!   [`InverseStatus::Excerpted`](crate::inverse::InverseStatus::Excerpted),
//!   and a trace nothing. Marking, reading the log, forgetting it and
//!   dropping kept inverses work as on any document.
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

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use editor_text::Text;
use editor_text::excerpt::{ExcerptError, Excerpts, SourceKey, Wanted};

use crate::document::{Document, hand_out};
use crate::words::Reader;

/// The list of an excerpt document and the texts of its sources, each by
/// its document's key, sorted by key with no key twice. The texts are held
/// strongly: an excerpt document keeps reading a source whose document was
/// freed.
#[derive(Default)]
pub struct Excerpted {
    /// The list.
    list: Excerpts,
    /// The texts of the sources the list names.
    sources: Vec<(u64, Arc<Mutex<Text>>)>,
}

/// `text`, locked; a poisoned lock is used as it is, as a document does.
fn lock(text: &Mutex<Text>) -> MutexGuard<'_, Text> {
    text.lock().unwrap_or_else(PoisonError::into_inner)
}

/// What `work` returns of `sources`, each locked in the order given, which
/// is ascending key order, and handed over with its key.
fn locked<T>(
    sources: &[(u64, Arc<Mutex<Text>>)],
    work: impl FnOnce(&mut [(SourceKey, &mut Text)]) -> T,
) -> T {
    let mut guards: Vec<(u64, MutexGuard<'_, Text>)> = sources
        .iter()
        .map(|(key, text)| (*key, lock(text)))
        .collect();
    let mut texts: Vec<(SourceKey, &mut Text)> = guards
        .iter_mut()
        .map(|(key, guard)| (SourceKey(*key), &mut **guard))
        .collect();
    work(&mut texts)
}

/// `sources` sorted by key with no key twice.
fn sorted(mut sources: Vec<(u64, Arc<Mutex<Text>>)>) -> Vec<(u64, Arc<Mutex<Text>>)> {
    sources.sort_by_key(|(key, _)| *key);
    sources.dedup_by_key(|(key, _)| *key);
    sources
}

impl Excerpted {
    /// Catches `assembled`, the document's text, up with the sources
    /// ([`Excerpts::refresh`]). Its caller holds this list's lock and the
    /// text's; the sources' are taken here, in ascending key order.
    pub(crate) fn refresh(&mut self, assembled: &mut Text) {
        let Self { list, sources } = self;
        // Only the list writes the text, every edit of it being refused,
        // so the list is never refused here.
        let _ = locked(sources, |texts| list.refresh(assembled, texts));
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
            // writes the text: neither is expected.
            Err(ExcerptError::NoSuchSource | ExcerptError::Moved) => ExcerptStatus::Unreadable,
        }
    }
}

/// The excerpts `words` spell over `sources`, in the layout the module docs
/// give, and the texts of the sources they name, sorted by key with no key
/// twice. `None` when the words cannot be read or an index names no source.
#[allow(clippy::type_complexity)]
fn read(
    sources: &[&Document],
    words: &[u8],
) -> Option<(Vec<Wanted>, Vec<(u64, Arc<Mutex<Text>>)>)> {
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
        named.push((source.key(), source.text()));
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

    #[test]
    fn edits_to_an_excerpt_document_are_refused_and_change_nothing() {
        let (one, two) = (Document::new(ONE), Document::new(TWO));
        let excerpts = rows_of(&one, &two);
        let revision = excerpts.snapshot().revision();
        let insert = Transaction::new(
            ChangeSet::replacing(11, 0..0, "!").expect("a range within the length"),
        );

        assert!(!excerpts.replace(0, 0, "!"));
        assert_eq!(
            excerpts.apply(&insert, Origin::new(1)),
            Err(ApplyStatus::Excerpted)
        );
        // A transaction whose words cannot be read is still refused as an
        // excerpt document's edit.
        assert_eq!(
            excerpts.apply_words(&[], b"", 1).status,
            ApplyStatus::Excerpted as u64
        );
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

        assert_eq!(excerpts.read(), "two\n\nalpha\n");
        assert_eq!(excerpts.snapshot().revision(), revision);
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
}
