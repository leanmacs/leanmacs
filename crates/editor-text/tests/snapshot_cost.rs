//! What a snapshot, a transaction, a pull, a motion and a read of a part of
//! the text cost, counted as bytes allocated and never as time.
//!
//! A snapshot is taken for every reader of a text, so it must not copy the
//! text, and the edit that follows one must copy only the part of the tree
//! it changes. A transaction is applied for every keystroke, so it must
//! copy neither the text nor the log it is recorded in; and a consumer
//! that pulls what changed across many entries must not pay for each entry
//! again for every later one. A file is loaded once for a buffer, and must
//! not be copied a third time on the way to the rope. A motion is asked
//! for every key that moves a cursor, so it must walk the rope and copy
//! none of the text out to scan it; and reading one row or a range must
//! not read the whole text. All are counted here
//! with an allocator that adds up what each thread asks for. A count is
//! the same on every machine, where a duration is not.
//!
//! The file costs are counted on the published fake of the file port, used
//! as a caller would use it: no test here makes a real file.
//!
//! This is a test binary of its own because a global allocator is for a
//! whole binary. The counts are per thread, so the harness running the
//! tests in parallel cannot make one disturb another.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use editor_text::excerpt::{Excerpts, SourceKey, Wanted};
use editor_text::fs::{
    FakeFs, Fs, FsError, FsErrorKind, Kind, Modified, Permissions, Pieces, Stat,
};
use editor_text::{
    Anchor, Bias, ChangeSet, Marker, Motion, Origin, Revision, Text, Transaction, WordKind, file,
};

/// The system allocator, counting the bytes each thread asks it for.
struct Counting;

thread_local! {
    /// The bytes this thread has asked for so far. It is never lowered: a
    /// free does not undo the work of an allocation.
    static ALLOCATED: Cell<usize> = const { Cell::new(0) };
}

/// Adds `bytes` to this thread's count.
fn count(bytes: usize) {
    // A thread that is being torn down has no count left, and what it
    // allocates then is no test's work.
    let _ = ALLOCATED.try_with(|allocated| allocated.set(allocated.get() + bytes));
}

// SAFETY: every method hands its arguments to the system allocator
// unchanged, so its guarantees are the system allocator's. The count is a
// thread-local `Cell` with a `const` initialiser, which allocates nothing.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        count(layout.size());
        // SAFETY: the caller's contract is passed on unchanged.
        unsafe { System.alloc(layout) }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        count(layout.size());
        // SAFETY: the caller's contract is passed on unchanged.
        unsafe { System.alloc_zeroed(layout) }
    }

    unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        // A block that grows may be copied whole, so the whole new size is
        // counted.
        count(new_size);
        // SAFETY: the caller's contract is passed on unchanged.
        unsafe { System.realloc(pointer, layout, new_size) }
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        // SAFETY: the caller's contract is passed on unchanged.
        unsafe { System.dealloc(pointer, layout) }
    }
}

#[global_allocator]
static ALLOCATOR: Counting = Counting;

/// What `work` returns, and how many bytes this thread allocated while it
/// ran.
fn allocated_by<T>(work: impl FnOnce() -> T) -> (T, usize) {
    let before = ALLOCATED.get();
    let value = work();
    (value, ALLOCATED.get() - before)
}

/// The length of the text the costs are counted on: a megabyte.
const LENGTH: usize = 1 << 20;

/// One line of that text, with a multi-byte character in it.
const LINE: &str = "a line of the text, with an é in it\n";

/// A megabyte of [`LINE`], rounded up to a whole line.
fn megabyte() -> String {
    let text = LINE.repeat(LENGTH / LINE.len() + 1);
    assert!(text.len() >= LENGTH);
    text
}

#[test]
fn the_allocator_counts_what_this_thread_allocates() {
    let (bytes, counted) = allocated_by(|| vec![0_u8; 4096]);

    assert_eq!(bytes.len(), 4096);
    assert!(counted >= 4096, "{counted} bytes counted");
}

#[test]
fn taking_a_snapshot_of_a_megabyte_of_text_copies_none_of_it() {
    let string = megabyte();
    let text = Text::from(string.as_str());

    let (snapshot, counted) = allocated_by(|| text.snapshot());

    // Measured: 0 bytes. A snapshot is a new reference to the tree's root.
    // The bound leaves room for a library that allocates a small header.
    assert!(counted < 1024, "{counted} bytes allocated");
    assert_eq!(snapshot.len(), string.len());
}

#[test]
fn an_edit_after_a_snapshot_copies_a_small_fraction_of_the_text() {
    let string = megabyte();
    let mut text = Text::from(string.as_str());
    let snapshot = text.snapshot();
    // The start of the line in the middle of the text.
    let middle = LINE.len() * (string.len() / LINE.len() / 2);

    let (result, counted) = allocated_by(|| text.replace(middle..middle, "x"));

    assert_eq!(result, Ok(()));
    // Measured: 6,457 bytes. 4,472 are the nodes from the root to one leaf,
    // which the edit copies because the snapshot still holds the old ones;
    // the rest is the edit's change set, its log entry and its kept
    // inverse, here the first of each, which also allocates the log's
    // queue and the first node of the map the inverses are kept in. With
    // no snapshot held the same edit allocates the same: a transaction is
    // applied to a clone of the tree, which holds the old nodes as a
    // snapshot would. (Before a transaction kept its inverse, that was
    // 4,761, and before edits were transactions, 1,048.) The bound is a
    // sixteenth of the text.
    assert!(counted < LENGTH / 16, "{counted} bytes allocated");
    assert_eq!(snapshot.len(), string.len());
    assert_eq!(text.current().len(), string.len() + 1);
}

/// How many transactions the log's costs are counted over.
const TRANSACTIONS: usize = 1_000;

/// [`TRANSACTIONS`] transactions for a text that starts as `string`, to
/// apply in order: each inserts one byte at the start of a line, two lines
/// on from the one before, so no two of their edits touch.
fn insertions(string: &str) -> Vec<Transaction> {
    (0..TRANSACTIONS)
        .map(|index| {
            // The bytes inserted so far are all before this line.
            let at = LINE.len() * 2 * index + index;
            let changes = ChangeSet::replacing(string.len() + index, at..at, "x")
                .expect("a range within the length");
            Transaction::new(changes)
        })
        .collect()
}

#[test]
fn a_transaction_copies_neither_the_text_nor_the_log() {
    let string = megabyte();
    let mut text = Text::from(string.as_str());
    let transactions = insertions(&string);

    let (accepted, counted) = allocated_by(|| {
        transactions
            .iter()
            .filter(|transaction| text.apply(transaction, Origin::new(1)).is_ok())
            .count()
    });

    assert_eq!(accepted, TRANSACTIONS);
    assert_eq!(text.current().len(), string.len() + TRANSACTIONS);
    // Measured: 4,017,400 bytes in all, 4,017 a transaction: the nodes of
    // the tree the edit copies, the entry's one edit (96 bytes), the log's
    // queue as it doubles, and the kept inverse, which is the changes of
    // the transaction's inverse (two retains and a delete) and the map's
    // node for it. Without the kept inverse it was 3,651. Copying the text
    // for each would be a megabyte a transaction, and copying the log tens
    // of kilobytes. The bound is a sixty-fourth of the text.
    assert!(
        counted / TRANSACTIONS < LENGTH / 64,
        "{counted} bytes allocated by {TRANSACTIONS} transactions"
    );
}

/// How many anchors the cost of moving markers is counted over.
const ANCHORS: usize = 10_000;

#[test]
fn a_transaction_on_a_text_that_holds_anchors_allocates_a_bounded_amount_for_each() {
    let string = megabyte();
    // One byte inserted at the start of the line in the middle.
    let middle = LINE.len() * (string.len() / LINE.len() / 2);
    let transaction = Transaction::new(
        ChangeSet::replacing(string.len(), middle..middle, "x").expect("a range in the text"),
    );
    let mut bare = Text::from(string.as_str());
    let mut marked = Text::from(string.as_str());
    // An anchor at the start of each of the first lines, made in falling
    // order, so the text does not hold them sorted by offset.
    let lines = string.len() / LINE.len();
    let ids: Vec<_> = (0..ANCHORS)
        .rev()
        .map(|index| {
            let offset = LINE.len() * (index * lines / ANCHORS);
            let anchor = Anchor::new(offset, Bias::After);
            (
                offset,
                marked.mark(Marker::Anchor(anchor)).expect("a position"),
            )
        })
        .collect();

    let (without, bare_counted) = allocated_by(|| bare.apply(&transaction, Origin::new(1)));
    let (with, counted) = allocated_by(|| marked.apply(&transaction, Origin::new(1)));

    assert!(without.is_ok() && with.is_ok());
    for (offset, id) in ids {
        let moved = offset + usize::from(offset >= middle);
        assert_eq!(
            marked.marker(id),
            Some(&Marker::Anchor(Anchor::new(moved, Bias::After)))
        );
    }
    // Measured: 320,000 bytes more than the same transaction on a text
    // that holds none, 32 an anchor: the ends gathered to be sorted by
    // offset (an offset, a bias and a place, 24 bytes) and where each went
    // (8 bytes). Nothing is allocated for each change of the transaction
    // or for each byte of the text. The bound is 64 bytes an anchor.
    let for_the_anchors = counted - bare_counted;
    assert!(
        for_the_anchors <= ANCHORS * 64,
        "{for_the_anchors} bytes allocated for {ANCHORS} anchors"
    );
}

#[test]
fn the_inverse_of_a_delete_of_a_megabyte_allocates_it_once() {
    let string = megabyte();
    let before = Text::from(string.as_str()).snapshot();
    let delete = ChangeSet::replacing(string.len(), 0..string.len(), "").expect("the whole text");

    let (inverse, counted) = allocated_by(|| delete.invert(&before));

    let inverse = inverse.expect("it fits");
    assert_eq!(inverse.len_after(), string.len());
    // Measured: 1,048,804 bytes: the string the removed text is read into,
    // sized once, and the change set's one change. Reading it a piece of
    // the rope at a time into a string that doubles was 4,193,504. The
    // bound is the text and a half.
    assert!(counted < string.len() * 3 / 2, "{counted} bytes allocated");
}

/// The transaction that inserts `string` into an empty text.
fn inserting(string: &str) -> Transaction {
    Transaction::new(ChangeSet::replacing(0, 0..0, string).expect("an empty range"))
}

/// The inverse of the run from `first` to `last`, applied to `text`: the
/// revision it produced, if it was accepted.
fn inverted(text: &mut Text, first: u64, last: u64) -> Option<u64> {
    text.apply_inverse(Revision::new(first), Revision::new(last), Origin::new(2))
        .ok()
        .map(|inverted| inverted.revision.get())
}

#[test]
fn a_transaction_that_inserts_a_megabyte_keeps_no_second_copy_of_it() {
    let string = megabyte();
    let transaction = inserting(&string);
    let mut text = Text::new();

    let (result, counted) = allocated_by(|| text.apply(&transaction, Origin::new(1)));

    assert!(result.is_ok());
    assert_eq!(text.current().len(), string.len());
    // Measured: 1,194,328 bytes: the rope's pieces, and 1,696 for the log
    // entry and the kept inverse, which is a delete of the length and
    // holds none of the text. Keeping the transaction too, for a redo,
    // would be a megabyte more. The bound is the text and a half.
    assert!(counted < string.len() * 3 / 2, "{counted} bytes allocated");
}

#[test]
fn the_inverse_of_an_insert_of_a_megabyte_reads_it_back_once() {
    let string = megabyte();
    let mut text = Text::new();
    text.apply(&inserting(&string), Origin::new(1))
        .expect("it fits");

    let (revision, counted) = allocated_by(|| inverted(&mut text, 1, 1));

    assert_eq!(revision, Some(2));
    assert!(text.current().is_empty());
    // Measured: 1,049,980 bytes: the megabyte the inverse removes, read
    // out of the rope once, into a string of its length, for the inverse
    // of the inverse. The bound is the text and a half.
    assert!(counted < string.len() * 3 / 2, "{counted} bytes allocated");
}

#[test]
fn the_inverse_of_an_inverse_is_applied_without_a_copy_of_it() {
    let string = megabyte();
    let mut text = Text::new();
    text.apply(&inserting(&string), Origin::new(1))
        .expect("it fits");
    assert_eq!(inverted(&mut text, 1, 1), Some(2));

    let (revision, counted) = allocated_by(|| inverted(&mut text, 2, 2));

    assert_eq!(revision, Some(3));
    assert_eq!(text.current().len(), string.len());
    // Measured: 1,192,664 bytes, what an insert of the megabyte allocates:
    // the kept inverse, which holds the megabyte, is applied where it is kept.
    // A clone of it first would be a megabyte more. The bound is the text
    // and a half.
    assert!(counted < string.len() * 3 / 2, "{counted} bytes allocated");
}

#[test]
fn the_inverse_of_a_long_run_allocates_a_bounded_amount_for_each_revision() {
    let string = megabyte();
    let mut text = Text::from(string.as_str());
    for transaction in insertions(&string) {
        text.apply(&transaction, Origin::new(1)).expect("it fits");
    }

    let (revision, counted) = allocated_by(|| inverted(&mut text, 1, TRANSACTIONS as u64));

    assert_eq!(revision, Some(TRANSACTIONS as u64 + 1));
    assert_eq!(text.current().len(), string.len());
    // Measured: 1,738 bytes a revision of the run. The inverses are
    // composed pairwise as a balanced tree, ten levels deep here; the
    // rest is the one transaction applied, with its thousand changes.
    // Composing them one after the other would copy every change again
    // at each step: about 64,000 bytes a revision. The bound is 4 KiB a
    // revision.
    assert!(
        counted / TRANSACTIONS < 4096,
        "{counted} bytes allocated for a run of {TRANSACTIONS} revisions"
    );
}

#[test]
fn the_inverse_of_one_revision_copies_neither_the_text_nor_what_is_kept() {
    let string = megabyte();
    let mut text = Text::from(string.as_str());
    for transaction in insertions(&string) {
        text.apply(&transaction, Origin::new(1)).expect("it fits");
    }
    let last = TRANSACTIONS as u64;

    let (revision, counted) = allocated_by(|| inverted(&mut text, last, last));

    assert_eq!(revision, Some(last + 1));
    assert_eq!(text.current().len(), string.len() + TRANSACTIONS - 1);
    // Measured: 3,777 bytes: what any transaction of one change costs on
    // this text. Nothing is sized by the text or by the thousand inverses
    // kept. The bound is a sixty-fourth of the text.
    assert!(counted < LENGTH / 64, "{counted} bytes allocated");
}

#[test]
fn a_pull_across_many_entries_allocates_a_bounded_amount_for_each() {
    let string = megabyte();
    let mut text = Text::from(string.as_str());
    for transaction in insertions(&string) {
        text.apply(&transaction, Origin::new(1)).expect("it fits");
    }

    let (patch, counted) = allocated_by(|| text.changes_since(Revision::new(0)));

    let patch = patch.expect("a revision the log reaches");
    assert_eq!(patch.edits.len(), TRANSACTIONS);
    // Measured: 957,696 bytes in all, 957 an entry skipped: the entries are
    // composed pairwise as a balanced tree, ten levels deep here, and each
    // level allocates one edit (96 bytes) for each entry. Composing them
    // one after the other would allocate for every entry again at each
    // step: about 48,000 bytes an entry. The bound is 4 KiB an entry.
    assert!(
        counted / TRANSACTIONS < 4096,
        "{counted} bytes allocated across {TRANSACTIONS} entries"
    );
}

#[test]
fn a_text_made_from_a_snapshot_copies_none_of_the_text() {
    let string = megabyte();
    let snapshot = Text::from(string.as_str()).snapshot();

    let (text, counted) = allocated_by(|| Text::from_snapshot(&snapshot));

    assert_eq!(text.current().len(), string.len());
    assert_eq!(text.current().revision(), Revision::new(0));
    // Measured: 0 bytes. The text is a new reference to the snapshot's
    // tree; making it from the snapshot's string would be the megabyte of
    // the rope again. The bound leaves room for a small header.
    assert!(counted < 1024, "{counted} bytes allocated");
}

/// Every motion: the fifteen that take nothing but a kind of word, and one
/// each way by rows.
fn motions() -> [Motion; 17] {
    [
        Motion::NextCell,
        Motion::PreviousCell,
        Motion::NextWordStart(WordKind::Word),
        Motion::NextWordEnd(WordKind::Word),
        Motion::PreviousWordStart(WordKind::Word),
        Motion::PreviousWordEnd(WordKind::Word),
        Motion::NextWordStart(WordKind::BigWord),
        Motion::NextWordEnd(WordKind::BigWord),
        Motion::PreviousWordStart(WordKind::BigWord),
        Motion::PreviousWordEnd(WordKind::BigWord),
        Motion::LineStart,
        Motion::LineEnd,
        Motion::LineFirstNonBlank,
        Motion::TextStart,
        Motion::TextEnd,
        Motion::RowsUp {
            count: 1_000,
            column: 7,
        },
        Motion::RowsDown {
            count: 1_000,
            column: 30,
        },
    ]
}

#[test]
fn a_motion_in_a_megabyte_of_text_allocates_nothing_sized_by_the_text() {
    let string = megabyte();
    let snapshot = Text::from(string.as_str()).snapshot();
    // Inside the second word of the line in the middle of the text.
    let middle = LINE.len() * (string.len() / LINE.len() / 2) + 3;

    for motion in motions() {
        let (answer, counted) = allocated_by(|| snapshot.motion(motion, middle));

        assert!(answer.is_some(), "{motion:?}");
        // Measured: 0 bytes for each. A motion walks the rope from the
        // position, a cell at a time; a copy of the text to scan would be
        // the megabyte, and a list of its cells more.
        assert!(counted < 1024, "{motion:?}: {counted} bytes allocated");
    }
}

#[test]
fn a_word_motion_across_a_megabyte_of_blanks_walks_it_and_allocates_nothing() {
    // One row with no word in it: the motion passes every cell of the
    // text.
    let string = " ".repeat(LENGTH);
    let snapshot = Text::from(string.as_str()).snapshot();

    let (forward, counted_forward) =
        allocated_by(|| snapshot.motion(Motion::NextWordStart(WordKind::Word), 0));
    let (back, counted_back) =
        allocated_by(|| snapshot.motion(Motion::PreviousWordEnd(WordKind::Word), LENGTH));

    assert_eq!(forward, Some(LENGTH));
    assert_eq!(back, Some(0));
    // Measured: 0 bytes each way.
    assert!(counted_forward < 1024, "{counted_forward} bytes allocated");
    assert!(counted_back < 1024, "{counted_back} bytes allocated");
}

#[test]
fn reading_a_row_or_a_range_of_a_megabyte_allocates_what_it_returns_and_not_the_text() {
    let string = megabyte();
    let snapshot = Text::from(string.as_str()).snapshot();
    let row = string.len() / LINE.len() / 2;
    let start = LINE.len() * row;

    let (content, counted_row) = allocated_by(|| snapshot.row_to_string(row));
    let (slice, counted_slice) = allocated_by(|| snapshot.slice_to_string(start..start + 100));

    assert_eq!(content.as_deref(), Some(LINE.trim_end_matches('\n')));
    assert_eq!(slice.as_deref(), Some(&string[start..start + 100]));
    // Measured: 164 bytes for the row, whose content is 36, and 228 for
    // the range of 100: the string returned, grown as its pieces are
    // joined, with every size it had counted. Reading the whole text to
    // cut either out would be the megabyte.
    assert!(counted_row < 1024, "{counted_row} bytes allocated");
    assert!(counted_slice < 1024, "{counted_slice} bytes allocated");
}

/// Where the file the costs are counted on is, in the fake.
const FILE: &str = "/dir/a megabyte.txt";

/// A megabyte of [`LINE`] with a byte that is not UTF-8 in place of every
/// thousandth byte: about a thousand of them.
fn megabyte_with_invalid_bytes() -> Vec<u8> {
    let mut bytes = megabyte().into_bytes();
    for byte in bytes.iter_mut().step_by(1000) {
        *byte = 0xFF;
    }
    bytes
}

#[test]
fn loading_a_megabyte_allocates_the_bytes_read_and_the_rope_and_no_third_copy() {
    let string = megabyte();
    let fs = FakeFs::new();
    fs.file(FILE, string.as_bytes());

    let (loaded, counted) = allocated_by(|| file::load(&fs, Path::new(FILE), u64::MAX));

    let loaded = loaded.expect("the file loads");
    assert_eq!(loaded.text.current().len(), string.len());
    // Measured: 2,205,480 bytes: the bytes the file system hands over
    // (1,048,580), the rope (1,155,584, which is what `Text::from` of the
    // same string allocates), and 1,316 bytes of the fake's own record of
    // the two calls. A copy of the bytes, or of the text, on the way would
    // be a megabyte more: seen once by hand, with the bytes cloned in
    // `load`, as 3,254,060. The bound is two and a half megabytes.
    assert!(counted < LENGTH * 5 / 2, "{counted} bytes allocated");
    assert!(counted > LENGTH * 2, "{counted} bytes allocated");
}

#[test]
fn loading_a_megabyte_with_invalid_bytes_allocates_under_six_megabytes() {
    let bytes = megabyte_with_invalid_bytes();
    let fs = FakeFs::new();
    fs.file(FILE, &bytes);

    let (loaded, counted) = allocated_by(|| file::load(&fs, Path::new(FILE), u64::MAX));

    let loaded = loaded.expect("the file loads");
    assert_eq!(loaded.text.current().to_bytes(), bytes);
    // Measured: 5,354,364 bytes: the bytes read, the decoded string, which
    // grows once past its first size since each invalid byte is four bytes
    // of text (a megabyte, then two), and the rope. One more copy passes
    // six megabytes: seen once by hand, with the bytes cloned in `load`, as
    // 6,402,944.
    assert!(counted < LENGTH * 6, "{counted} bytes allocated");
}

/// A file system that counts the bytes it is given to write and keeps none
/// of them. It holds no file at [`FILE`] until one is renamed into place,
/// and none at any other path, which is where a save's temporary file is,
/// until one is written; a file it holds is as long as what was written.
///
/// The cost of a save is counted on this and not on the published fake:
/// the fake keeps every byte it is written, so through it the count would
/// be the megabyte the fake stores. It touches no file either. Everything a
/// save *does* is pinned on the published fake, in `src/file.rs`.
#[derive(Default)]
struct Discard {
    /// How many bytes it was given to write.
    written: AtomicU64,
    /// Whether a file has been written, at a path that is not [`FILE`].
    made: AtomicBool,
    /// Whether a file has been renamed into place.
    renamed: AtomicBool,
}

impl Fs for Discard {
    fn stat(&self, path: &Path) -> Result<Option<Stat>, FsError> {
        let there = if path == Path::new(FILE) {
            &self.renamed
        } else {
            &self.made
        };
        Ok(there.load(Ordering::SeqCst).then(|| Stat {
            kind: Kind::File,
            size: self.written.load(Ordering::SeqCst),
            modified: Modified::default(),
            permissions: Permissions::new(0o644),
        }))
    }

    fn read(&self, _: &Path) -> Result<Vec<u8>, FsError> {
        Err(FsError::new(FsErrorKind::NotFound, "nothing is kept"))
    }

    fn write(
        &self,
        _: &Path,
        pieces: &mut Pieces<'_>,
        _: Option<Permissions>,
    ) -> Result<(), FsError> {
        for piece in pieces {
            self.written.fetch_add(piece.len() as u64, Ordering::SeqCst);
        }
        self.made.store(true, Ordering::SeqCst);
        Ok(())
    }

    fn rename(&self, _: &Path, _: &Path) -> Result<(), FsError> {
        self.renamed.store(true, Ordering::SeqCst);
        Ok(())
    }

    fn remove(&self, _: &Path) -> Result<(), FsError> {
        Ok(())
    }

    fn resolve(&self, _: &Path) -> Result<PathBuf, FsError> {
        Err(FsError::new(FsErrorKind::NotFound, "nothing is kept"))
    }

    fn read_link(&self, _: &Path) -> Result<Option<PathBuf>, FsError> {
        Ok(None)
    }
}

#[test]
fn saving_a_megabyte_allocates_nothing_sized_by_the_text() {
    let string = megabyte();
    let snapshot = Text::from(string.as_str()).snapshot();
    let fs = Discard::default();

    let (saved, counted) = allocated_by(|| {
        file::save(
            &fs,
            Path::new(FILE),
            &snapshot,
            file::Expect::Absent,
            &|| false,
        )
    });

    let saved = saved.expect("the file is saved");
    assert_eq!(saved.size, string.len() as u64);
    assert_eq!(fs.written.load(Ordering::SeqCst), string.len() as u64);
    // Measured: 256 bytes: the paths of the file and of its temporary
    // file. The text is handed over a rope piece at a time, each borrowed.
    // Collecting it first (`to_bytes`) is a megabyte: seen once by hand as
    // 1,048,836. The bound is 4 KiB.
    assert!(counted < 4096, "{counted} bytes allocated");
}

#[test]
fn saving_a_megabyte_with_escapes_copies_a_piece_at_a_time_and_never_the_text() {
    let bytes = megabyte_with_invalid_bytes();
    let snapshot = Text::from_bytes(&bytes).snapshot();
    let fs = Discard::default();

    let (saved, counted) = allocated_by(|| {
        file::save(
            &fs,
            Path::new(FILE),
            &snapshot,
            file::Expect::Absent,
            &|| false,
        )
    });

    let saved = saved.expect("the file is saved");
    assert_eq!(saved.size, bytes.len() as u64);
    // Measured: 1,051,871 bytes in all: a piece that holds an escape is
    // copied as it is written, and here nearly every piece holds one. No
    // single allocation is sized by the text; collecting it first is a
    // megabyte more: seen once by hand as 2,103,766. The bound is a
    // megabyte and a half.
    assert!(counted < LENGTH * 3 / 2, "{counted} bytes allocated");
}

#[test]
fn catching_an_excerpt_up_after_a_one_byte_insert_allocates_nothing_sized_by_its_source() {
    let string = megabyte();
    let mut source = Text::from(string.as_str());
    // A kilobyte from the start of the line in the middle of the text.
    let middle = LINE.len() * (string.len() / LINE.len() / 2);
    let wanted = [Wanted {
        source: SourceKey(0),
        range: middle..middle + 1024,
    }];
    let mut excerpts = Excerpts::new();
    let mut assembled = Text::new();
    excerpts
        .set(&mut assembled, &wanted, &mut [(SourceKey(0), &mut source)])
        .expect("the range is two positions");
    source
        .replace(middle + 10..middle + 10, "x")
        .expect("a position");

    let (caught_up, counted) =
        allocated_by(|| excerpts.refresh(&mut assembled, &mut [(SourceKey(0), &mut source)]));

    assert!(matches!(caught_up, Ok(Some(_))));
    assert_eq!(assembled.current().len(), 1025);
    // Measured: 3,665 bytes: the source's one-edit patch, the change set of
    // the catch-up and the byte it inserts, the excerpt's new entry, and the
    // transaction on the kilobyte of the assembled text, its log entry and
    // the inverse kept and dropped. Copying the source would be a megabyte,
    // and copying the excerpt a kilobyte. The bound is a sixty-fourth of the
    // source.
    assert!(counted < LENGTH / 64, "{counted} bytes allocated");
}
