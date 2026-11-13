//! The C functions that mark a document and ask what a selection covers,
//! called the way the C glue calls them: with raw pointers, buffers of
//! words and out-records.
//!
//! Where a marker goes when the text is edited and what a selection covers
//! are the text's rules. So every answer here is compared with what an
//! [`editor_text::Text`] given the same markers and the same transaction
//! answers, written as words by this crate's own encoder: what is pinned
//! is that the values cross.
//!
//! This is an integration test of its own, so a process of its own, because
//! it makes documents: `tests/c_api.rs` counts the live documents of its
//! process, and a document made here beside it would be counted there.

use std::mem::MaybeUninit;
use std::slice;

use editor_ffi::document::{Document, editor_ffi_document_free, editor_ffi_document_new};
use editor_ffi::log::RawWords;
use editor_ffi::marker::{
    self, MarkStatus, RawMarked, editor_ffi_document_mark, editor_ffi_document_marker,
    editor_ffi_document_place, editor_ffi_document_unmark,
};
use editor_ffi::snapshot::{
    editor_ffi_document_snapshot, editor_ffi_snapshot_extents, editor_ffi_snapshot_free,
};
use editor_ffi::text::editor_ffi_text_free;
use editor_ffi::transaction::{self, ApplyStatus, RawApplied, editor_ffi_document_apply};
use editor_text::{MarkerId, Origin, Text};

/// The buffer that holds `words`: each as eight bytes, least significant
/// first.
fn buffer(words: &[u64]) -> Vec<u8> {
    words.iter().flat_map(|word| word.to_le_bytes()).collect()
}

/// A new document holding `text`.
fn document_new(text: &str) -> *mut Document {
    // SAFETY: the pointer and length are those of `text`, alive for the call.
    unsafe { editor_ffi_document_new(text.as_ptr(), text.len()) }
}

/// The status and the bytes of a filled record, read as the glue reads
/// them: copy the buffer, then hand it back.
///
/// # Safety
///
/// `raw` was filled by the library, and its buffer has not been handed
/// back.
unsafe fn take_words(raw: RawWords) -> (u64, Vec<u8>) {
    // SAFETY: the record's buffer is `len` bytes, owned by this caller
    // until it is handed back.
    let bytes = unsafe { slice::from_raw_parts(raw.words, raw.len) }.to_vec();
    // SAFETY: the buffer came from the library in this record, and is
    // handed back once.
    unsafe { editor_ffi_text_free(raw.words, raw.len) };
    (raw.status, bytes)
}

/// Marks `document` with the marker `words` spell, and returns the status
/// and the id the library reported.
///
/// # Safety
///
/// `document` came from [`document_new`] and has not been freed.
unsafe fn document_mark(document: *const Document, words: &[u8]) -> (u64, u64) {
    let mut raw = MaybeUninit::<RawMarked>::uninit();
    // SAFETY: the caller guarantees `document`; the pointer and length are
    // those of `words`, alive for the call; and `raw` is writable for one
    // record.
    unsafe { editor_ffi_document_mark(document, words.as_ptr(), words.len(), raw.as_mut_ptr()) };
    // SAFETY: the call filled the record.
    let raw = unsafe { raw.assume_init() };
    (raw.status, raw.id)
}

/// The status and the words of the marker of `document` with the number
/// `id`.
///
/// # Safety
///
/// `document` came from [`document_new`] and has not been freed.
unsafe fn document_marker(document: *const Document, id: u64) -> (u64, Vec<u8>) {
    let mut raw = MaybeUninit::<RawWords>::uninit();
    // SAFETY: the caller guarantees `document`, and `raw` is writable for
    // one record.
    unsafe { editor_ffi_document_marker(document, id, raw.as_mut_ptr()) };
    // SAFETY: the call filled the record, whose buffer is handed back here.
    unsafe { take_words(raw.assume_init()) }
}

/// Puts the marker `words` spell in place of the marker of `document` with
/// the number `id`, and returns the status the library reported.
///
/// # Safety
///
/// `document` came from [`document_new`] and has not been freed.
unsafe fn document_place(document: *const Document, id: u64, words: &[u8]) -> u64 {
    // SAFETY: the caller guarantees `document`; the pointer and length are
    // those of `words`, alive for the call.
    unsafe { editor_ffi_document_place(document, id, words.as_ptr(), words.len()) }
}

/// What the selection `words` spell covers in a snapshot of `document`
/// taken now: the status and the words the library reported.
///
/// # Safety
///
/// `document` came from [`document_new`] and has not been freed.
unsafe fn document_extents(document: *const Document, words: &[u8]) -> (u64, Vec<u8>) {
    // SAFETY: the caller guarantees `document`.
    let snapshot = unsafe { editor_ffi_document_snapshot(document) };
    let mut raw = MaybeUninit::<RawWords>::uninit();
    // SAFETY: `snapshot` is live until the free below; the pointer and
    // length are those of `words`, alive for the call; and `raw` is
    // writable for one record.
    unsafe { editor_ffi_snapshot_extents(snapshot, words.as_ptr(), words.len(), raw.as_mut_ptr()) };
    // SAFETY: the snapshot came from the call above and is freed this once.
    unsafe { editor_ffi_snapshot_free(snapshot) };
    // SAFETY: the call filled the record, whose buffer is handed back here.
    unsafe { take_words(raw.assume_init()) }
}

const DONE: u64 = MarkStatus::Done as u64;
const UNREADABLE: u64 = MarkStatus::Unreadable as u64;
const NO_SUCH_MARKER: u64 = MarkStatus::NoSuchMarker as u64;

/// What the marker of `text` with the id `id` is written as.
fn held(text: &Text, id: MarkerId) -> (u64, Vec<u8>) {
    let marker = text.marker(id).expect("a marker the text holds");
    (DONE, marker::marker_words(marker))
}

#[test]
fn a_document_is_marked_and_a_selections_extents_are_read_through_c() {
    // "é" is the bytes 1 and 2, and "ö" 8 and 9; the text is 13 bytes on
    // two rows.
    const TEXT: &str = "héllo\nwörld";
    let document = document_new(TEXT);
    // The same text, to ask what the text's rules answer.
    let mut text = Text::from(TEXT);

    // An anchor with bias after, and a line-wise selection of two ranges.
    let anchor = buffer(&[0, 3, 1]);
    let selection = buffer(&[1, 2, 1, 2, 10, 7, 1, 0]);
    let anchor_marker = marker::decode(&anchor).expect("an anchor");
    let selection_marker = marker::decode(&selection).expect("a selection");
    let anchor_of_text = text.mark(anchor_marker.clone()).expect("a position");
    let selection_of_text = text.mark(selection_marker).expect("positions");

    // SAFETY: `document` is live until the free at the end of this block,
    // and every buffer a call fills is handed back by the helper that made
    // the call.
    unsafe {
        // Each kind of marker is marked, and reads back.
        let (status, anchor_id) = document_mark(document, &anchor);
        assert_eq!(status, DONE);
        let (status, selection_id) = document_mark(document, &selection);
        assert_eq!(status, DONE);
        assert_ne!(anchor_id, selection_id);
        assert_eq!(
            document_marker(document, anchor_id),
            held(&text, anchor_of_text)
        );
        assert_eq!(
            document_marker(document, selection_id),
            held(&text, selection_of_text)
        );

        // A transaction moves both: "XY" is inserted at 3, and "wö" goes.
        let words = buffer(&[5, 0, 3, 2, 2, 0, 4, 1, 3, 0, 3, 0, 0]);
        let mut applied = MaybeUninit::<RawApplied>::uninit();
        editor_ffi_document_apply(
            document,
            words.as_ptr(),
            words.len(),
            b"XY".as_ptr(),
            2,
            7,
            applied.as_mut_ptr(),
        );
        assert_eq!(applied.assume_init().status, ApplyStatus::Applied as u64);
        let same = transaction::decode(&words, b"XY").expect("a transaction");
        text.apply(&same, Origin::new(7)).expect("it fits");
        assert_eq!(
            document_marker(document, anchor_id),
            held(&text, anchor_of_text)
        );
        assert_eq!(
            document_marker(document, selection_id),
            held(&text, selection_of_text)
        );
        // The markers did move: neither is written as it was marked.
        assert_ne!(document_marker(document, anchor_id).1, anchor);
        assert_ne!(document_marker(document, selection_id).1, selection);

        // A marker is put somewhere else, and made the other kind.
        let cursor = buffer(&[1, 1, 0, 1, 4, 4]);
        assert_eq!(document_place(document, anchor_id, &cursor), DONE);
        text.place(
            anchor_of_text,
            marker::decode(&cursor).expect("a selection"),
        )
        .expect("a position");
        assert_eq!(
            document_marker(document, anchor_id),
            held(&text, anchor_of_text)
        );

        // Each refusal crosses as its status, and changes nothing. What
        // the text refuses is the text's rule: the status is the one of
        // its own refusal of the same place.
        let unknown_of_text = MarkerId::new(selection_of_text.get() + 1);
        let unknown_id = selection_id + 1;
        for (id, of_text, words) in [
            (anchor_id, anchor_of_text, &[0, 99, 0][..]),
            (anchor_id, anchor_of_text, &[1, 0, 0, 1, 0, 99]),
            (unknown_id, unknown_of_text, &[0, 0, 0]),
        ] {
            let words = buffer(words);
            let refusal = text
                .place(of_text, marker::decode(&words).expect("a marker"))
                .expect_err("a place the text refuses");
            assert_eq!(
                document_place(document, id, &words),
                MarkStatus::of(refusal) as u64
            );
        }
        // Marking is refused as placing is.
        let refusal = text
            .mark(marker::decode(&buffer(&[0, 99, 0])).expect("an anchor"))
            .expect_err("a marker the text refuses");
        assert_eq!(
            document_mark(document, &buffer(&[0, 99, 0])),
            (MarkStatus::of(refusal) as u64, 0)
        );
        assert_eq!(document_place(document, anchor_id, &[1, 2, 3]), UNREADABLE);
        assert_eq!(document_mark(document, &[]), (UNREADABLE, 0));
        assert_eq!(
            document_marker(document, anchor_id),
            held(&text, anchor_of_text)
        );

        // What a selection covers, of each shape.
        for words in [
            &[0, 0, 1, 1, 9][..],
            &[1, 0, 2, 3, 3, 12, 5],
            &[2, 0, 1, 8, 8],
            &[3, 0, 1, 1, 12],
        ] {
            let words = buffer(words);
            let selection = marker::decode_selection(&words).expect("a selection");
            let extents = text.current().extents(&selection).expect("it fits");
            assert_eq!(
                document_extents(document, &words),
                (DONE, marker::extent_words(&extents)),
                "{selection:?}"
            );
        }
        // A selection the text has no extents for, and words that spell
        // none.
        let astray = buffer(&[1, 0, 1, 0, 2]);
        let selection = marker::decode_selection(&astray).expect("a selection");
        assert_eq!(text.current().extents(&selection), None);
        assert_eq!(
            document_extents(document, &astray),
            (MarkStatus::BadSelection as u64, Vec::new())
        );
        assert_eq!(
            document_extents(document, &buffer(&[9, 0, 1, 0, 0])),
            (UNREADABLE, Vec::new())
        );

        // A marker that is given up is gone, and its id names nothing.
        assert!(editor_ffi_document_unmark(document, selection_id));
        assert!(!editor_ffi_document_unmark(document, selection_id));
        assert!(!editor_ffi_document_unmark(document, unknown_id + 7));
        assert_eq!(
            document_marker(document, selection_id),
            (NO_SUCH_MARKER, Vec::new())
        );

        editor_ffi_document_free(document);
    }
}
