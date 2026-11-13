//! A snapshot: a document's text as it was at one moment, and the third
//! example of a handle.
//!
//! [`editor_ffi_document_snapshot`] hands out an owned snapshot of a
//! document, and the functions here read it: its text, its revision, length
//! and row count in one record, and the conversions between a byte offset
//! and a point. A snapshot never changes and is `Send + Sync`
//! ([`editor_text::Snapshot`]), so it sits behind no lock, and it outlives
//! its document.
//!
//! What a row, a point and a position are is the text's rule, pinned by
//! `editor-text`'s own tests. This module converts numbers and forwards.
//!
//! A column is counted in bytes or in UTF-16 code units. The unit crosses
//! as a tag ([`ColumnUnit`]), so a third unit is a tag and not a function.
//! Offsets cross as `usize`, as a document's do; rows and columns as `u64`,
//! in and out. A row or a column that no `usize` holds is refused, never
//! cut down.
//!
//! What a selection covers in the snapshot's text
//! ([`editor_ffi_snapshot_extents`]) is asked and answered in words; the
//! module docs of [`crate::marker`] give both layouts.

use std::sync::atomic::{AtomicU64, Ordering};

use editor_text::{Point, PointUtf16};

use crate::document::{Document, RawText};
use crate::log::RawWords;
use crate::marker::{self, MarkStatus};
use crate::text;

/// A document's text as it was when the snapshot was taken.
pub struct Snapshot(editor_text::Snapshot);

/// The unit a point's column is counted in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColumnUnit {
    /// Bytes of UTF-8.
    Bytes = 0,
    /// UTF-16 code units.
    Utf16 = 1,
}

impl ColumnUnit {
    /// The number that stands for this unit across the boundary.
    pub const fn tag(self) -> u8 {
        self as u8
    }

    /// The unit `tag` stands for, if it is one.
    pub const fn from_tag(tag: u8) -> Option<Self> {
        match tag {
            0 => Some(Self::Bytes),
            1 => Some(Self::Utf16),
            _ => None,
        }
    }
}

impl Snapshot {
    /// The row and column of the byte offset `offset`, with the column in
    /// `unit`. `None` when the offset is not a position of the text.
    pub fn point_of(&self, unit: ColumnUnit, offset: usize) -> Option<RawPoint> {
        let (row, column) = match unit {
            ColumnUnit::Bytes => {
                let point = self.0.offset_to_point(offset)?;
                (point.row, point.column)
            }
            ColumnUnit::Utf16 => {
                let point = self.0.offset_to_point_utf16(offset)?;
                (point.row, point.column)
            }
        };
        Some(RawPoint {
            row: row as u64,
            column: column as u64,
        })
    }

    /// The byte offset of the point `row`, `column`, with the column in
    /// `unit`. `None` when the point names no position of the text, and
    /// when no `usize` holds the row or the column.
    pub fn offset_of(&self, unit: ColumnUnit, row: u64, column: u64) -> Option<u64> {
        let (row, column) = (usize::try_from(row).ok()?, usize::try_from(column).ok()?);
        let offset = match unit {
            ColumnUnit::Bytes => self.0.point_to_offset(Point::new(row, column))?,
            ColumnUnit::Utf16 => self.0.point_utf16_to_offset(PointUtf16::new(row, column))?,
        };
        Some(offset as u64)
    }

    /// What the selection `words` spell
    /// ([`marker::decode_selection`]) covers in the text
    /// ([`editor_text::Snapshot::extents`]), as words
    /// ([`marker::extent_words`]). Refused as
    /// [`MarkStatus::Unreadable`] when the words cannot be read, and as
    /// [`MarkStatus::BadSelection`] when they spell no selection or the
    /// text has no extents for the one they spell.
    pub fn extents_words(&self, words: &[u8]) -> Result<Vec<u8>, MarkStatus> {
        let selection = marker::decode_selection(words).map_err(MarkStatus::undecoded)?;
        let extents = self.0.extents(&selection).ok_or(MarkStatus::BadSelection)?;
        Ok(marker::extent_words(&extents))
    }
}

/// How many snapshots [`editor_ffi_document_snapshot`] has handed out that
/// [`editor_ffi_snapshot_free`] has not taken back.
static LIVE: AtomicU64 = AtomicU64::new(0);

/// A snapshot of the text of `document` as it is now, owned by the caller,
/// who must hand it to [`editor_ffi_snapshot_free`] exactly once. Later
/// edits to the document do not change it, and it may be freed before or
/// after the document.
///
/// # Safety
///
/// `document` came from
/// [`editor_ffi_document_new`](crate::document::editor_ffi_document_new) and
/// has not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_document_snapshot(document: *const Document) -> *mut Snapshot {
    // SAFETY: the caller guarantees `document` points to a live document.
    let snapshot = unsafe { &*document }.snapshot();
    LIVE.fetch_add(1, Ordering::Relaxed);
    Box::into_raw(Box::new(Snapshot(snapshot)))
}

/// What a snapshot is, as it crosses the boundary: one record, filled in
/// one call.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RawSnapshotInfo {
    /// The revision of its document the snapshot holds: how many edits the
    /// document had accepted.
    pub revision: u64,
    /// The length of the text in bytes.
    pub byte_len: u64,
    /// How many rows the text has: one more than its line feeds.
    pub row_count: u64,
}

/// Fills `out` with the revision, the length in bytes and the row count of
/// `snapshot`.
///
/// # Safety
///
/// `snapshot` came from [`editor_ffi_document_snapshot`] and has not been
/// freed, and `out` points to a writable [`RawSnapshotInfo`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_snapshot_info(
    snapshot: *const Snapshot,
    out: *mut RawSnapshotInfo,
) {
    // SAFETY: the caller guarantees `snapshot` points to a live snapshot.
    let snapshot = &unsafe { &*snapshot }.0;
    let info = RawSnapshotInfo {
        revision: snapshot.revision().get(),
        byte_len: snapshot.len() as u64,
        row_count: snapshot.row_count() as u64,
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(info) };
}

/// Fills `out` with a copy of the whole text of `snapshot`.
///
/// # Safety
///
/// `snapshot` came from [`editor_ffi_document_snapshot`] and has not been
/// freed, and `out` points to a writable [`RawText`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_snapshot_read(snapshot: *const Snapshot, out: *mut RawText) {
    // SAFETY: the caller guarantees `snapshot` points to a live snapshot.
    let (text, text_len) = text::lend(unsafe { &*snapshot }.0.to_string());
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(RawText { text, text_len }) };
}

/// A row and a column as they cross the boundary. The unit of the column is
/// the one the call that filled it was asked for.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RawPoint {
    /// Which row, from 0.
    pub row: u64,
    /// How far into the row.
    pub column: u64,
}

/// [`Snapshot::point_of`] for C: returns whether the byte offset `offset`
/// is a position of `snapshot`, and if so fills `out` with its row and its
/// column, counted in the unit `unit` is the tag of.
///
/// False, with `out` untouched, also when `unit` is the tag of no
/// [`ColumnUnit`].
///
/// # Safety
///
/// `snapshot` came from [`editor_ffi_document_snapshot`] and has not been
/// freed, and `out` points to a writable [`RawPoint`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_snapshot_point_of(
    snapshot: *const Snapshot,
    unit: u8,
    offset: usize,
    out: *mut RawPoint,
) -> bool {
    let Some(unit) = ColumnUnit::from_tag(unit) else {
        return false;
    };
    // SAFETY: the caller guarantees `snapshot` points to a live snapshot.
    let Some(point) = unsafe { &*snapshot }.point_of(unit, offset) else {
        return false;
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(point) };
    true
}

/// [`Snapshot::offset_of`] for C: returns whether the point `row`, `column`
/// names a position of `snapshot`, with the column counted in the unit
/// `unit` is the tag of, and if so fills `out` with its byte offset.
///
/// False, with `out` untouched, also when `unit` is the tag of no
/// [`ColumnUnit`].
///
/// # Safety
///
/// `snapshot` came from [`editor_ffi_document_snapshot`] and has not been
/// freed, and `out` points to a writable `u64`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_snapshot_offset_of(
    snapshot: *const Snapshot,
    unit: u8,
    row: u64,
    column: u64,
    out: *mut u64,
) -> bool {
    let Some(unit) = ColumnUnit::from_tag(unit) else {
        return false;
    };
    // SAFETY: the caller guarantees `snapshot` points to a live snapshot.
    let Some(offset) = unsafe { &*snapshot }.offset_of(unit, row, column) else {
        return false;
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(offset) };
    true
}

/// [`Snapshot::extents_words`] for C: fills `out` with what the selection
/// the `len` bytes at `words` spell covers in `snapshot`, as words, and the
/// status [`MarkStatus::Done`]; or with no words and the status that says
/// why there are none.
///
/// # Safety
///
/// `snapshot` came from [`editor_ffi_document_snapshot`] and has not been
/// freed; `words` points to `len` readable bytes; and `out` points to a
/// writable [`RawWords`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_snapshot_extents(
    snapshot: *const Snapshot,
    words: *const u8,
    len: usize,
    out: *mut RawWords,
) {
    // SAFETY: the caller guarantees the pointer and the length.
    let words = unsafe { crate::words::borrow(words, len) };
    // SAFETY: the caller guarantees `snapshot` points to a live snapshot.
    let raw = match unsafe { &*snapshot }.extents_words(words) {
        Ok(extents) => RawWords::with_status(MarkStatus::Done as u64, extents),
        Err(status) => RawWords::with_status(status as u64, Vec::new()),
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
}

/// Frees `snapshot`.
///
/// # Safety
///
/// `snapshot` came from [`editor_ffi_document_snapshot`], has not been
/// freed, and is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_snapshot_free(snapshot: *mut Snapshot) {
    // SAFETY: the caller guarantees `snapshot` is a box
    // `editor_ffi_document_snapshot` gave up, taken back this once.
    drop(unsafe { Box::from_raw(snapshot) });
    LIVE.fetch_sub(1, Ordering::Relaxed);
}

/// How many snapshots [`editor_ffi_document_snapshot`] has made that have
/// not been freed. This is what makes a snapshot's finaliser, and the
/// lifetime of the editor's table of snapshots, observable to a test.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_snapshot_live() -> u64 {
    LIVE.load(Ordering::Relaxed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::words::tests::buffer;

    /// A snapshot of a document holding `text`.
    fn snapshot(text: &str) -> Snapshot {
        Snapshot(Document::new(text).snapshot())
    }

    #[test]
    fn a_column_unit_is_named_by_its_tag() {
        assert_eq!(ColumnUnit::from_tag(0), Some(ColumnUnit::Bytes));
        assert_eq!(ColumnUnit::from_tag(1), Some(ColumnUnit::Utf16));
        for unit in [ColumnUnit::Bytes, ColumnUnit::Utf16] {
            assert_eq!(ColumnUnit::from_tag(unit.tag()), Some(unit));
        }
    }

    #[test]
    fn a_tag_that_names_no_column_unit_is_refused() {
        assert_eq!(ColumnUnit::from_tag(2), None);
        assert_eq!(ColumnUnit::from_tag(u8::MAX), None);
    }

    #[test]
    fn the_unit_chooses_which_of_the_texts_points_is_asked_for() {
        // "😀" is four bytes and two UTF-16 units, so the two columns of
        // the "x" after it differ.
        let snapshot = snapshot("a\n😀x");

        let bytes = RawPoint { row: 1, column: 4 };
        let units = RawPoint { row: 1, column: 2 };
        assert_eq!(snapshot.point_of(ColumnUnit::Bytes, 6), Some(bytes));
        assert_eq!(snapshot.point_of(ColumnUnit::Utf16, 6), Some(units));
        assert_eq!(snapshot.offset_of(ColumnUnit::Bytes, 1, 4), Some(6));
        assert_eq!(snapshot.offset_of(ColumnUnit::Utf16, 1, 2), Some(6));
    }

    #[test]
    fn the_extents_of_a_selection_are_the_texts_written_as_words() {
        // Characters of one, two and four bytes, and a line break of each
        // kind.
        const TEXT: &str = "héllo\r\n😀 wörld\nend";
        let snapshot = snapshot(TEXT);
        let text = Document::new(TEXT).snapshot();

        // A selection of each shape: what each covers is the text's rule,
        // so each answer is compared with what the text itself answers.
        for words in [
            &[0, 0, 2, 1, 3, 12, 8][..],
            &[1, 1, 2, 0, 0, 5, 3],
            &[2, 0, 1, 4, 13],
            &[3, 0, 1, 1, 20],
        ] {
            let words = buffer(words);
            let selection = marker::decode_selection(&words).expect("a selection");
            let extents = text.extents(&selection).expect("a selection that fits");

            assert_eq!(
                snapshot.extents_words(&words),
                Ok(marker::extent_words(&extents)),
                "{selection:?}"
            );
        }
    }

    #[test]
    fn a_selection_with_no_extents_is_refused_as_its_status() {
        let snapshot = snapshot("héllo");

        // Words that cannot be read.
        assert_eq!(
            snapshot.extents_words(&buffer(&[4, 0, 1, 0, 0])),
            Err(MarkStatus::Unreadable)
        );
        assert_eq!(snapshot.extents_words(&[]), Err(MarkStatus::Unreadable));
        // Words that spell no selection.
        assert_eq!(
            snapshot.extents_words(&buffer(&[1, 0, 0])),
            Err(MarkStatus::BadSelection)
        );
        // A selection the text has no extents for: an end inside "é".
        let astray = buffer(&[1, 0, 1, 0, 2]);
        let selection = marker::decode_selection(&astray).expect("a selection");
        assert_eq!(Document::new("héllo").snapshot().extents(&selection), None);
        assert_eq!(
            snapshot.extents_words(&astray),
            Err(MarkStatus::BadSelection)
        );
    }

    #[test]
    fn what_the_text_refuses_is_refused_in_either_unit() {
        let snapshot = snapshot("a\n😀x");

        for unit in [ColumnUnit::Bytes, ColumnUnit::Utf16] {
            // Inside "😀", and past the end.
            assert_eq!(snapshot.point_of(unit, 3), None);
            assert_eq!(snapshot.point_of(unit, 8), None);
            // A row the text does not have, and a column no row is as long
            // as.
            assert_eq!(snapshot.offset_of(unit, 2, 0), None);
            assert_eq!(snapshot.offset_of(unit, 0, u64::MAX), None);
            assert_eq!(snapshot.offset_of(unit, u64::MAX, 0), None);
        }
    }
}
