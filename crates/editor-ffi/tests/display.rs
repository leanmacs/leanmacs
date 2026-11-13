//! The display handle and its C functions, called the way the C glue calls
//! them: with raw pointers and out-records of words.
//!
//! What layout answers is `editor-layout`'s rule. So every answer here is
//! compared with what an `editor_layout::Layout` over the same fake shaper
//! answers for the same text, called directly in the same test: what is
//! pinned is that the values cross, and that the handle reaches the
//! document's log.
//!
//! This is an integration test of its own, so a process of its own: it
//! counts the live displays of its process, and makes documents, which
//! `tests/c_api.rs` counts in its.

use std::mem::MaybeUninit;
use std::slice;
use std::sync::{Mutex, MutexGuard, PoisonError};

use editor_ffi::display::{
    DisplayStatus, editor_ffi_display_free, editor_ffi_display_live, editor_ffi_display_move,
    editor_ffi_display_new_cells, editor_ffi_display_rows,
};
use editor_ffi::document::{
    Document, editor_ffi_document_free, editor_ffi_document_new, editor_ffi_document_replace,
};
use editor_ffi::log::{RawWords, editor_ffi_document_forget};
use editor_ffi::snapshot::{
    Snapshot, editor_ffi_document_snapshot, editor_ffi_snapshot_free, editor_ffi_snapshot_info,
};
use editor_ffi::text::editor_ffi_text_free;
use editor_layout::Layout;
use editor_layout::scene::{TextKey, TextRef};
use editor_layout::shaper::fake::CellShaper;
use editor_text::Text;

/// Held by each test for its whole run: the tests count the live displays
/// of the process, so no two of them run at once.
static ONE_AT_A_TIME: Mutex<()> = Mutex::new(());

/// The lock that keeps this test the only one running.
fn alone() -> MutexGuard<'static, ()> {
    ONE_AT_A_TIME.lock().unwrap_or_else(PoisonError::into_inner)
}

/// A new document holding `text`.
fn document_new(text: &str) -> *mut Document {
    // SAFETY: the pointer and length are those of `text`, alive for the call.
    unsafe { editor_ffi_document_new(text.as_ptr(), text.len()) }
}

/// The words of a filled record, as numbers, with its status; the buffer is
/// handed back.
///
/// # Safety
///
/// `raw` was filled by the library, and its buffer has not been handed
/// back.
unsafe fn take(raw: RawWords) -> (u64, Vec<u64>) {
    // SAFETY: the record's buffer is `len` bytes, owned until handed back.
    let bytes = unsafe { slice::from_raw_parts(raw.words, raw.len) }.to_vec();
    // SAFETY: the buffer came from the library in this record, handed back
    // once.
    unsafe { editor_ffi_text_free(raw.words, raw.len) };
    let words = bytes
        .as_chunks::<8>()
        .0
        .iter()
        .map(|word| u64::from_le_bytes(*word))
        .collect();
    (raw.status, words)
}

/// The rows a display shows of a snapshot, through C, as pairs; or the
/// status of its refusal.
fn rows(
    display: *const editor_ffi::display::Display,
    snapshot: *const Snapshot,
    width: u64,
    height: u64,
    anchor: usize,
) -> Result<Vec<(usize, usize)>, u64> {
    let mut raw = MaybeUninit::<RawWords>::uninit();
    // SAFETY: both handles are live, and `raw` is writable.
    let (status, words) = unsafe {
        editor_ffi_display_rows(display, snapshot, width, height, anchor, raw.as_mut_ptr());
        take(raw.assume_init())
    };
    if status != DisplayStatus::Done as u64 {
        return Err(status);
    }
    assert_eq!(words.len(), 1 + 2 * words[0] as usize);
    Ok(words[1..]
        .as_chunks::<2>()
        .0
        .iter()
        .map(|[start, stop]| (*start as usize, *stop as usize))
        .collect())
}

/// Where a move goes through C: the position and the goal.
fn moved(
    display: *const editor_ffi::display::Display,
    snapshot: *const Snapshot,
    width: u64,
    position: usize,
    lines: i64,
    goal: Option<u64>,
) -> Result<(usize, u64), u64> {
    let mut raw = MaybeUninit::<RawWords>::uninit();
    // SAFETY: both handles are live, and `raw` is writable.
    let (status, words) = unsafe {
        editor_ffi_display_move(
            display,
            snapshot,
            width,
            position,
            lines,
            goal.is_some(),
            goal.unwrap_or(0),
            raw.as_mut_ptr(),
        );
        take(raw.assume_init())
    };
    if status != DisplayStatus::Done as u64 {
        return Err(status);
    }
    Ok((words[0] as usize, words[1]))
}

/// The rows `Layout` itself shows of `text`, as pairs.
fn rows_directly(text: &str, width: f32, height: f32, anchor: usize) -> Vec<(usize, usize)> {
    let mut layout = Layout::new(CellShaper::new(8.0, 16.0));
    let text = TextRef::fixed(TextKey(0), Text::from(text).snapshot());
    layout
        .rows_shown(&text, width, height, anchor)
        .unwrap()
        .into_iter()
        .map(|row| (row.start, row.stop))
        .collect()
}

#[test]
fn a_display_is_live_from_new_until_free_and_answers_the_queries_as_layout_does() {
    let _alone = alone();
    let before = editor_ffi_display_live();
    let display = editor_ffi_display_new_cells(8, 16);
    assert_eq!(editor_ffi_display_live(), before + 1);
    let text = "abcdefgh\nij\n\tk";
    let document = document_new(text);
    // SAFETY: `document` is live.
    let snapshot = unsafe { editor_ffi_document_snapshot(document) };
    assert_eq!(
        rows(display, snapshot, 32, 64, 2),
        Ok(rows_directly(text, 32.0, 64.0, 2))
    );
    let mut layout = Layout::new(CellShaper::new(8.0, 16.0));
    let direct = TextRef::fixed(TextKey(0), Text::from(text).snapshot());
    for (position, lines, goal) in [(1, 1, None), (6, 2, Some(20)), (13, -3, None)] {
        let expected = layout
            .lines_from(&direct, 32.0, position, lines, goal.map(|goal| goal as f32))
            .unwrap();
        assert_eq!(
            moved(display, snapshot, 32, position, lines, goal),
            Ok((expected.position, expected.goal as u64))
        );
    }
    assert_eq!(
        rows(display, snapshot, 32, 64, 99),
        Err(DisplayStatus::BadPosition as u64)
    );
    assert_eq!(
        moved(display, snapshot, 32, 99, 1, None),
        Err(DisplayStatus::BadPosition as u64)
    );
    // SAFETY: each handle is live and freed once.
    unsafe {
        editor_ffi_snapshot_free(snapshot);
        editor_ffi_document_free(document);
        editor_ffi_display_free(display);
    }
    assert_eq!(editor_ffi_display_live(), before);
}

#[test]
fn a_document_whose_log_was_forgotten_is_laid_out_again_from_its_snapshot() {
    let _alone = alone();
    let display = editor_ffi_display_new_cells(8, 16);
    let document = document_new("abcdefgh\nij");
    // SAFETY: `document` is live.
    let first = unsafe { editor_ffi_document_snapshot(document) };
    assert!(rows(display, first, 32, 64, 0).is_ok());
    let inserted = "0123\n";
    // SAFETY: `document` is live, and `inserted` alive for the call.
    let second = unsafe {
        assert!(editor_ffi_document_replace(
            document,
            0,
            0,
            inserted.as_ptr(),
            inserted.len()
        ));
        let mut info = MaybeUninit::uninit();
        let latest = editor_ffi_document_snapshot(document);
        editor_ffi_snapshot_info(latest, info.as_mut_ptr());
        assert!(editor_ffi_document_forget(
            document,
            info.assume_init().revision
        ));
        latest
    };
    assert_eq!(
        rows(display, second, 32, 64, 0),
        Ok(rows_directly("0123\nabcdefgh\nij", 32.0, 64.0, 0))
    );
    // SAFETY: each handle is live and freed once.
    unsafe {
        editor_ffi_snapshot_free(first);
        editor_ffi_snapshot_free(second);
        editor_ffi_document_free(document);
        editor_ffi_display_free(display);
    }
}
