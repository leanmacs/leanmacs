//! The C functions over a snapshot of a document, called the way the C glue
//! calls them: with raw pointers, tags and out-records.
//!
//! This is an integration test of its own, so a process of its own, because
//! it makes documents: `tests/c_api.rs` counts the live documents of its
//! process, and a document made here beside it would be counted there. The
//! one test below owns both counts of this process.

use std::mem::MaybeUninit;
use std::slice;

use editor_ffi::document::{
    Document, RawText, editor_ffi_document_free, editor_ffi_document_new,
    editor_ffi_document_replace,
};
use editor_ffi::snapshot::{
    ColumnUnit, RawPoint, RawSnapshotInfo, Snapshot, editor_ffi_document_snapshot,
    editor_ffi_snapshot_free, editor_ffi_snapshot_info, editor_ffi_snapshot_live,
    editor_ffi_snapshot_offset_of, editor_ffi_snapshot_point_of, editor_ffi_snapshot_read,
};
use editor_ffi::text::editor_ffi_text_free;

/// The tag of the unit that counts a column in bytes.
const BYTES: u8 = ColumnUnit::Bytes.tag();

/// The tag of the unit that counts a column in UTF-16 code units.
const UTF16: u8 = ColumnUnit::Utf16.tag();

/// A tag that names no unit.
const NO_UNIT: u8 = 2;

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
    unsafe { editor_ffi_document_replace(document, start, end, text.as_ptr(), text.len()) }
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

        // A snapshot outlives its document.
        editor_ffi_document_free(document);
        assert_eq!(snapshot_read(first), text);
        assert_eq!(snapshot_read(second), "Jéllo\r\nwörld\n");
        assert_eq!(editor_ffi_snapshot_live(), before + 2);

        editor_ffi_snapshot_free(first);
        assert_eq!(editor_ffi_snapshot_live(), before + 1);
        assert_eq!(snapshot_info(second), (2, 15, 3));

        editor_ffi_snapshot_free(second);
        assert_eq!(editor_ffi_snapshot_live(), before);
    }
}
