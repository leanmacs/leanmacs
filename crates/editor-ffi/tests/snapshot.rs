//! The C functions over a snapshot of a document, called the way the C glue
//! calls them: with raw pointers, tags and out-records.
//!
//! This is an integration test of its own, so a process of its own, because
//! it makes documents: `tests/c_api.rs` counts the live documents of its
//! process, and a document made here beside it would be counted there. The
//! one test below owns both counts of this process.

use std::mem::MaybeUninit;
use std::time::Duration;
use std::{ptr, slice, thread};

use editor_wait::HangGuard;

use editor_ffi::document::{
    Document, RawText, ReplaceStatus, editor_ffi_document_free, editor_ffi_document_new,
    editor_ffi_document_replace,
};
use editor_ffi::live::{SNAPSHOTS, editor_ffi_live_await};
use editor_ffi::motion;
use editor_ffi::snapshot::{
    ColumnUnit, RawPoint, RawSnapshotInfo, Snapshot, editor_ffi_document_snapshot,
    editor_ffi_snapshot_free, editor_ffi_snapshot_info, editor_ffi_snapshot_live,
    editor_ffi_snapshot_motion, editor_ffi_snapshot_offset_of, editor_ffi_snapshot_point_of,
    editor_ffi_snapshot_read, editor_ffi_snapshot_row, editor_ffi_snapshot_slice,
};
use editor_ffi::text::editor_ffi_text_free;

/// The tag of the unit that counts a column in bytes.
const BYTES: u8 = ColumnUnit::Bytes.tag();

/// The tag of the unit that counts a column in UTF-16 code units.
const UTF16: u8 = ColumnUnit::Utf16.tag();

/// The tag of the unit that counts a column in cells.
const CELLS: u8 = ColumnUnit::Cells.tag();

/// A tag that names no unit.
const NO_UNIT: u8 = 3;

/// A tag that names no motion.
const NO_MOTION: u8 = motion::TAGS;

/// The free a wait for the live count ends on
/// (`editor_ffi_live_await`, which takes it in milliseconds,
/// [`HangGuard::as_millis`]); only a hang reaches the bound.
const FREED: HangGuard = HangGuard::on(
    "the free of the snapshot freed on another thread",
    Duration::from_secs(10),
);

/// A new document holding `text`.
fn document_new(text: &str) -> *mut Document {
    // SAFETY: the pointer and length are those of `text`, alive for the call.
    unsafe { editor_ffi_document_new(text.as_ptr(), text.len()) }
}

/// Replaces the bytes `start..end` of `document` with `text`, and returns
/// whether the library did.
///
/// # Safety
///
/// `document` came from [`document_new`] and has not been freed.
unsafe fn document_replace(
    document: *const Document,
    start: usize,
    end: usize,
    text: &str,
) -> bool {
    // SAFETY: the caller guarantees `document`; the pointer and length are
    // those of `text`, alive for the call.
    let status =
        unsafe { editor_ffi_document_replace(document, start, end, text.as_ptr(), text.len()) };
    status == ReplaceStatus::Done as u64
}

/// The text of `snapshot`, read as the glue reads it: fill the record, copy
/// the text, hand the buffer back.
///
/// # Safety
///
/// `snapshot` came from [`editor_ffi_document_snapshot`] and has not been
/// freed.
unsafe fn snapshot_read(snapshot: *const Snapshot) -> String {
    let mut raw = MaybeUninit::<RawText>::uninit();
    // SAFETY: the caller guarantees `snapshot`, and `raw` is writable for
    // one record.
    unsafe { editor_ffi_snapshot_read(snapshot, raw.as_mut_ptr()) };
    // SAFETY: the call filled the record.
    let raw = unsafe { raw.assume_init() };
    // SAFETY: the record's buffer is `text_len` bytes, owned by this caller
    // until it is handed back.
    let text = unsafe { slice::from_raw_parts(raw.text, raw.text_len) }.to_vec();
    // SAFETY: the buffer came from the library in this record, and is handed
    // back once.
    unsafe { editor_ffi_text_free(raw.text, raw.text_len) };
    String::from_utf8(text).expect("a snapshot's text is UTF-8")
}

/// The revision, the length in bytes and the row count of `snapshot`.
///
/// # Safety
///
/// `snapshot` came from [`editor_ffi_document_snapshot`] and has not been
/// freed.
unsafe fn snapshot_info(snapshot: *const Snapshot) -> (u64, u64, u64) {
    let mut raw = MaybeUninit::<RawSnapshotInfo>::uninit();
    // SAFETY: the caller guarantees `snapshot`, and `raw` is writable for
    // one record.
    unsafe { editor_ffi_snapshot_info(snapshot, raw.as_mut_ptr()) };
    // SAFETY: the call filled the record.
    let raw = unsafe { raw.assume_init() };
    (raw.revision, raw.byte_len, raw.row_count)
}

/// The row and column of the byte offset `offset` of `snapshot`, with the
/// column in the unit `unit` names; `None` when the library returns false.
///
/// # Safety
///
/// `snapshot` came from [`editor_ffi_document_snapshot`] and has not been
/// freed.
unsafe fn point_of(snapshot: *const Snapshot, unit: u8, offset: usize) -> Option<(u64, u64)> {
    let mut raw = MaybeUninit::<RawPoint>::uninit();
    // SAFETY: the caller guarantees `snapshot`, and `raw` is writable for
    // one record.
    let found = unsafe { editor_ffi_snapshot_point_of(snapshot, unit, offset, raw.as_mut_ptr()) };
    // SAFETY: the call returned true, so it filled the record.
    found
        .then(|| unsafe { raw.assume_init() })
        .map(|point| (point.row, point.column))
}

/// The byte offset of the point `row`, `column` of `snapshot`, with the
/// column in the unit `unit` names; `None` when the library returns false.
///
/// # Safety
///
/// `snapshot` came from [`editor_ffi_document_snapshot`] and has not been
/// freed.
unsafe fn offset_of(snapshot: *const Snapshot, unit: u8, row: u64, column: u64) -> Option<u64> {
    let mut offset = MaybeUninit::<u64>::uninit();
    // SAFETY: the caller guarantees `snapshot`, and `offset` is writable.
    let found =
        unsafe { editor_ffi_snapshot_offset_of(snapshot, unit, row, column, offset.as_mut_ptr()) };
    // SAFETY: the call returned true, so it filled the offset.
    found.then(|| unsafe { offset.assume_init() })
}

/// What an out-value holds before a call, to see that a refusal leaves it
/// untouched.
const UNTOUCHED: u64 = 0xDEAD_BEEF;

/// Where the motion `tag` names, with `count` and `column`, leads from the
/// byte offset `offset` of `snapshot`; `None` when the library returns
/// false, which must leave the out-value as it was.
///
/// # Safety
///
/// `snapshot` came from [`editor_ffi_document_snapshot`] and has not been
/// freed.
unsafe fn motion_from(
    snapshot: *const Snapshot,
    tag: u8,
    count: u64,
    column: u64,
    offset: usize,
) -> Option<u64> {
    let mut answer = UNTOUCHED;
    // SAFETY: the caller guarantees `snapshot`, and `answer` is writable.
    let found =
        unsafe { editor_ffi_snapshot_motion(snapshot, tag, count, column, offset, &mut answer) };
    if !found {
        assert_eq!(answer, UNTOUCHED, "a refusal wrote the out-value");
    }
    found.then_some(answer)
}

/// The text a read filled `raw` with, copied as the glue copies it, with
/// the buffer handed back; `None` when the read returned false, which must
/// leave the record as it was.
///
/// # Safety
///
/// When `found`, the library filled `raw` with a buffer that has not been
/// handed back.
unsafe fn text_read(found: bool, raw: RawText) -> Option<String> {
    if !found {
        assert!(raw.text.is_null(), "a refusal wrote the record");
        assert_eq!(raw.text_len, UNTOUCHED as usize);
        return None;
    }
    // SAFETY: the record's buffer is `text_len` bytes, owned by this caller
    // until it is handed back.
    let text = unsafe { slice::from_raw_parts(raw.text, raw.text_len) }.to_vec();
    // SAFETY: the buffer came from the library in this record, and is handed
    // back once.
    unsafe { editor_ffi_text_free(raw.text, raw.text_len) };
    Some(String::from_utf8(text).expect("a snapshot's text is UTF-8"))
}

/// A record no read has filled.
fn unfilled() -> RawText {
    RawText {
        text: ptr::null_mut(),
        text_len: UNTOUCHED as usize,
    }
}

/// The content of the row `row` of `snapshot`; `None` when the library
/// returns false.
///
/// # Safety
///
/// `snapshot` came from [`editor_ffi_document_snapshot`] and has not been
/// freed.
unsafe fn row_read(snapshot: *const Snapshot, row: u64) -> Option<String> {
    let mut raw = unfilled();
    // SAFETY: the caller guarantees `snapshot`, and `raw` is writable for
    // one record.
    let found = unsafe { editor_ffi_snapshot_row(snapshot, row, &mut raw) };
    // SAFETY: the record is as the call left it.
    unsafe { text_read(found, raw) }
}

/// The text of `snapshot` from the byte offset `start` up to `end`; `None`
/// when the library returns false.
///
/// # Safety
///
/// `snapshot` came from [`editor_ffi_document_snapshot`] and has not been
/// freed.
unsafe fn slice_read(snapshot: *const Snapshot, start: usize, end: usize) -> Option<String> {
    let mut raw = unfilled();
    // SAFETY: the caller guarantees `snapshot`, and `raw` is writable for
    // one record.
    let found = unsafe { editor_ffi_snapshot_slice(snapshot, start, end, &mut raw) };
    // SAFETY: the record is as the call left it.
    unsafe { text_read(found, raw) }
}

#[expect(
    clippy::disallowed_methods,
    reason = "inferred-waits W81: the process-wide live count of snapshots come down, on the C function `editor_ffi_live_await`"
)]
#[test]
fn a_snapshot_is_taken_and_read_through_c_and_is_live_from_the_call_that_made_it_until_its_free() {
    let before = editor_ffi_snapshot_live();

    // Three rows. "é" and "ö" are two bytes and one UTF-16 unit each, and
    // "😀" is four bytes and two units: it starts row 2 at byte 15, and the
    // "x" after it is at byte 19.
    let text = "héllo\r\nwörld\n😀x";
    let document = document_new(text);
    assert_eq!(editor_ffi_snapshot_live(), before);

    // SAFETY: here and below, `document` came from `document_new` and each
    // snapshot from `editor_ffi_document_snapshot`, and none is used after
    // the call that frees it.
    unsafe {
        let first = editor_ffi_document_snapshot(document);
        assert_eq!(editor_ffi_snapshot_live(), before + 1);

        // The document is edited after the snapshot was taken.
        assert!(document_replace(document, 0, 1, "J"));
        assert!(document_replace(document, 15, 20, ""));
        let second = editor_ffi_document_snapshot(document);
        assert_eq!(editor_ffi_snapshot_live(), before + 2);

        // Each snapshot reads what the document held when it was taken, at
        // the revision it had then.
        assert_eq!(snapshot_read(first), text);
        assert_eq!(snapshot_info(first), (0, 20, 3));
        assert_eq!(snapshot_read(second), "Jéllo\r\nwörld\n");
        assert_eq!(snapshot_info(second), (2, 15, 3));

        // A point crosses in both units.
        assert_eq!(point_of(first, BYTES, 19), Some((2, 4)));
        assert_eq!(point_of(first, UTF16, 19), Some((2, 2)));
        assert_eq!(point_of(first, BYTES, 6), Some((0, 6)));
        assert_eq!(point_of(first, UTF16, 6), Some((0, 5)));
        assert_eq!(point_of(first, BYTES, 20), Some((2, 5)));
        assert_eq!(offset_of(first, BYTES, 2, 4), Some(19));
        assert_eq!(offset_of(first, UTF16, 2, 2), Some(19));
        assert_eq!(offset_of(first, BYTES, 1, 0), Some(8));
        // In the second snapshot row 2 is the empty row after the last line
        // feed.
        assert_eq!(point_of(second, BYTES, 15), Some((2, 0)));
        assert_eq!(offset_of(second, UTF16, 2, 0), Some(15));

        // What is not a position is refused: an offset inside a character
        // and one past the end; a point in a row the text does not have,
        // past the end of its row, inside a character, and between the two
        // units of one.
        assert_eq!(point_of(first, BYTES, 2), None);
        assert_eq!(point_of(first, UTF16, 16), None);
        assert_eq!(point_of(first, BYTES, 21), None);
        assert_eq!(point_of(first, BYTES, usize::MAX), None);
        assert_eq!(offset_of(first, BYTES, 3, 0), None);
        assert_eq!(offset_of(first, BYTES, 0, 8), None);
        assert_eq!(offset_of(first, BYTES, 2, 1), None);
        assert_eq!(offset_of(first, UTF16, 2, 1), None);
        // A row and a column as large as the boundary carries.
        assert_eq!(offset_of(first, BYTES, u64::MAX, 0), None);
        assert_eq!(offset_of(first, UTF16, 0, u64::MAX), None);

        // A unit tag no one defined is refused, for a query either unit
        // answers.
        assert_eq!(point_of(first, NO_UNIT, 0), None);
        assert_eq!(offset_of(first, NO_UNIT, 0, 0), None);
        assert_eq!(point_of(first, u8::MAX, 0), None);

        // What a motion, a column in cells and a read answer are the text's
        // rules: each answer below is compared with what the text itself
        // answers, asked of a snapshot beside the handle.
        let beside = editor_text::Text::from(text).snapshot();

        // A point crosses in cells too, both ways: the "x" after "😀".
        let cells = beside.offset_to_point_cells(19).expect("a position");
        let (row, column) = (cells.row as u64, cells.column as u64);
        assert_eq!(point_of(first, CELLS, 19), Some((row, column)));
        assert_eq!(offset_of(first, CELLS, row, column), Some(19));
        assert_ne!(point_of(first, BYTES, 19), Some((row, column)));
        assert_eq!(point_of(first, CELLS, 16), None);
        assert_eq!(offset_of(first, CELLS, 3, 0), None);
        assert_eq!(offset_of(first, CELLS, 0, u64::MAX), None);

        // Every motion crosses under its tag, from the start of the text,
        // from inside a word and from a line break, with a count and a
        // column for the two that take them.
        for tag in 0..motion::TAGS {
            let named = motion::motion_of(tag, 1, 3).expect("the tag of a motion");
            for offset in [0, 4, 6, 12, 20] {
                let expected = beside.motion(named, offset).expect("a position");
                assert_eq!(
                    motion_from(first, tag, 1, 3, offset),
                    Some(expected as u64),
                    "{named:?} from {offset}"
                );
            }
            // An offset inside a character, one past the end and one as
            // large as the boundary carries are refused, whichever motion
            // it is.
            assert_eq!(motion_from(first, tag, 1, 3, 2), None);
            assert_eq!(motion_from(first, tag, 1, 3, 21), None);
            assert_eq!(motion_from(first, tag, 1, 3, usize::MAX), None);
        }
        // A count and a column as large as the boundary carries are
        // answered, not refused.
        let down = motion::motion_of(16, u64::MAX, u64::MAX).expect("the tag of a motion");
        let expected = beside.motion(down, 0).expect("a position");
        assert_eq!(
            motion_from(first, 16, u64::MAX, u64::MAX, 0),
            Some(expected as u64)
        );
        // A tag no one defined is refused, for an offset every motion
        // answers.
        assert_eq!(motion_from(first, NO_MOTION, 0, 0, 0), None);
        assert_eq!(motion_from(first, u8::MAX, 0, 0, 0), None);

        // A row is read without its line break, and a range exactly, each
        // in a buffer that is handed back.
        for row in 0..3 {
            let expected = beside.row_to_string(row).expect("a row of the text");
            assert_eq!(row_read(first, row as u64), Some(expected), "row {row}");
        }
        assert_eq!(row_read(first, 3), None);
        assert_eq!(row_read(first, u64::MAX), None);
        for (start, end) in [(1, 9), (15, 20), (4, 4), (0, 20)] {
            let expected = beside.slice_to_string(start..end).expect("two positions");
            assert_eq!(
                slice_read(first, start, end),
                Some(expected),
                "{start}..{end}"
            );
        }
        // The second snapshot reads what its document held, not the first's
        // text.
        assert_eq!(slice_read(second, 0, 1).as_deref(), Some("J"));
        // A range that is backwards, splits a character, runs past the end
        // or is as large as the boundary carries is refused.
        assert_eq!(slice_read(first, 9, 1), None);
        assert_eq!(slice_read(first, 0, 2), None);
        assert_eq!(slice_read(first, 16, 20), None);
        assert_eq!(slice_read(first, 0, 21), None);
        assert_eq!(slice_read(first, usize::MAX, usize::MAX), None);

        // A snapshot outlives its document.
        editor_ffi_document_free(document);
        assert_eq!(snapshot_read(first), text);
        assert_eq!(snapshot_read(second), "Jéllo\r\nwörld\n");
        assert_eq!(editor_ffi_snapshot_live(), before + 2);

        editor_ffi_snapshot_free(first);
        assert_eq!(editor_ffi_snapshot_live(), before + 1);
        assert_eq!(snapshot_info(second), (2, 15, 3));

        // Freed on another thread, as a finaliser may free it, and waited
        // for on the free. A pointer is not `Send`, so it crosses as its
        // address.
        let second = second as usize;
        let freeing = thread::spawn(move || editor_ffi_snapshot_free(second as *mut Snapshot));
        assert!(editor_ffi_live_await(SNAPSHOTS, before, FREED.as_millis()));
        freeing.join().expect("the free's thread");
        assert_eq!(editor_ffi_snapshot_live(), before);
    }
}
