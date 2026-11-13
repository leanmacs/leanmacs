//! A document made from a snapshot through C, called the way the C glue
//! calls it: with raw pointers and out-records.
//!
//! This is an integration test of its own, so a process of its own, because
//! it counts the live documents and the live snapshots of its process:
//! `tests/snapshot.rs` and `tests/c_api.rs` each own those counts in
//! theirs, and tests in one file run side by side in one process.
//!
//! What a text made from a snapshot holds is `editor-text`'s rule
//! (`Text::from_snapshot`), pinned by that crate's tests. This test asks
//! `editor-text` for the answer and compares: it writes none of it out.

use std::mem::MaybeUninit;
use std::slice;

use editor_ffi::document::{
    Document, RawText, editor_ffi_document_free, editor_ffi_document_from_snapshot,
    editor_ffi_document_live, editor_ffi_document_new, editor_ffi_document_read,
    editor_ffi_document_replace,
};
use editor_ffi::snapshot::{
    RawSnapshotInfo, Snapshot, editor_ffi_document_snapshot, editor_ffi_snapshot_free,
    editor_ffi_snapshot_info, editor_ffi_snapshot_live, editor_ffi_snapshot_read,
};
use editor_ffi::text::editor_ffi_text_free;

/// The text a record holds, with its buffer handed back.
///
/// # Safety
///
/// `raw` was filled by the library and its buffer has not been handed back.
unsafe fn taken(raw: RawText) -> String {
    // SAFETY: the record's buffer is `text_len` bytes, owned by this caller
    // until it is handed back.
    let text = unsafe { slice::from_raw_parts(raw.text, raw.text_len) }.to_vec();
    // SAFETY: the buffer came from the library in this record, and is handed
    // back once.
    unsafe { editor_ffi_text_free(raw.text, raw.text_len) };
    String::from_utf8(text).expect("the library's text is UTF-8")
}

/// The text of `document`.
///
/// # Safety
///
/// `document` is a live document handle.
unsafe fn document_read(document: *const Document) -> String {
    let mut raw = MaybeUninit::<RawText>::uninit();
    // SAFETY: the caller guarantees `document`; `raw` is writable for one
    // record, which the call fills.
    unsafe {
        editor_ffi_document_read(document, raw.as_mut_ptr());
        taken(raw.assume_init())
    }
}

/// The text of `snapshot`.
///
/// # Safety
///
/// `snapshot` is a live snapshot handle.
unsafe fn snapshot_read(snapshot: *const Snapshot) -> String {
    let mut raw = MaybeUninit::<RawText>::uninit();
    // SAFETY: the caller guarantees `snapshot`; `raw` is writable for one
    // record, which the call fills.
    unsafe {
        editor_ffi_snapshot_read(snapshot, raw.as_mut_ptr());
        taken(raw.assume_init())
    }
}

/// The revision of `snapshot`.
///
/// # Safety
///
/// `snapshot` is a live snapshot handle.
unsafe fn snapshot_revision(snapshot: *const Snapshot) -> u64 {
    let mut raw = MaybeUninit::<RawSnapshotInfo>::uninit();
    // SAFETY: the caller guarantees `snapshot`; `raw` is writable for one
    // record, which the call fills.
    unsafe {
        editor_ffi_snapshot_info(snapshot, raw.as_mut_ptr());
        raw.assume_init().revision
    }
}

/// Replaces the bytes `start..end` of `document` with `text`.
///
/// # Safety
///
/// `document` is a live document handle.
unsafe fn document_replace(document: *const Document, start: usize, end: usize, text: &str) {
    // SAFETY: the caller guarantees `document`; the pointer and length are
    // those of `text`, alive for the call.
    let replaced =
        unsafe { editor_ffi_document_replace(document, start, end, text.as_ptr(), text.len()) };
    assert!(replaced);
}

#[test]
fn a_document_made_from_a_snapshot_through_c_is_a_live_document_of_its_own() {
    let documents = editor_ffi_document_live();
    let snapshots = editor_ffi_snapshot_live();
    // Two- and four-byte characters, a CRLF, and the character the byte
    // 0xFF is kept as.
    let text = "h\u{e9}llo\r\nw\u{f6}rld\n\u{1F600}x\u{10DCFF}";

    // What `editor-text` makes of a snapshot of the same text after the
    // same edit: the answer the document is compared with.
    let mut reference = editor_text::Text::from(text);
    reference.replace(0..1, "J").expect("the edit fits");
    let expected = editor_text::Text::from_snapshot(&reference.snapshot());
    let held = reference.current().to_string();

    // SAFETY: the pointer and length are those of `text`, alive for the
    // call. Below, every handle came from the library and none is used
    // after the call that frees it.
    unsafe {
        let source = editor_ffi_document_new(text.as_ptr(), text.len());
        document_replace(source, 0, 1, "J");
        let snapshot = editor_ffi_document_snapshot(source);
        assert_eq!(editor_ffi_snapshot_live(), snapshots + 1);

        let copy = editor_ffi_document_from_snapshot(snapshot);

        // It is a document, counted live from the call that made it, and
        // making it handed out no snapshot.
        assert_eq!(editor_ffi_document_live(), documents + 2);
        assert_eq!(editor_ffi_snapshot_live(), snapshots + 1);
        assert_eq!(document_read(copy), expected.current().to_string());
        let of_copy = editor_ffi_document_snapshot(copy);
        assert_eq!(
            snapshot_revision(of_copy),
            expected.current().revision().get()
        );
        editor_ffi_snapshot_free(of_copy);

        // An edit to it changes neither the snapshot nor the document the
        // snapshot was taken from.
        document_replace(copy, 0, 0, "copy: ");
        assert_eq!(document_read(copy), format!("copy: {held}"));
        assert_eq!(snapshot_read(snapshot), held);
        assert_eq!(document_read(source), held);

        // It outlives both.
        editor_ffi_snapshot_free(snapshot);
        editor_ffi_document_free(source);
        assert_eq!(document_read(copy), format!("copy: {held}"));
        assert_eq!(editor_ffi_document_live(), documents + 1);

        editor_ffi_document_free(copy);
        assert_eq!(editor_ffi_document_live(), documents);
        assert_eq!(editor_ffi_snapshot_live(), snapshots);
    }
}
