//! What a snapshot, a transaction and a pull cost, counted as bytes
//! allocated and never as time.
//!
//! A snapshot is taken for every reader of a text, so it must not copy the
//! text, and the edit that follows one must copy only the part of the tree
//! it changes. A transaction is applied for every keystroke, so it must
//! copy neither the text nor the log it is recorded in; and a consumer
//! that pulls what changed across many entries must not pay for each entry
//! again for every later one. All are counted here with an allocator that
//! adds up what each thread asks for. A count is the same on every
//! machine, where a duration is not.
//!
//! This is a test binary of its own because a global allocator is for a
//! whole binary. The counts are per thread, so the harness running the
//! tests in parallel cannot make one disturb another.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

use editor_text::{Anchor, Bias, ChangeSet, Marker, Origin, Revision, Text, Transaction};

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
    // Measured: 4,761 bytes. 4,472 are the nodes from the root to one leaf,
    // which the edit copies because the snapshot still holds the old ones;
    // the rest is the edit's change set and its log entry, here the first
    // of the log, which also allocates the log's queue. With no snapshot
    // held the same edit allocates the same: a transaction is applied to a
    // clone of the tree, which holds the old nodes as a snapshot would.
    // (Before edits were transactions, that was 1,048.) The bound is a
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
    // Measured: 3,651,896 bytes in all, 3,651 a transaction: the nodes of
    // the tree the edit copies, the entry's one edit (96 bytes), and the
    // log's queue as it doubles. Copying the text for each would be a
    // megabyte a transaction, and copying the log tens of kilobytes. The
    // bound is a sixty-fourth of the text.
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
