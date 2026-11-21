//! A snapshot: a document's text as it was at one moment, and the third
//! example of a handle.
//!
//! [`editor_ffi_document_snapshot`] hands out an owned snapshot of a
//! document, and the functions here read it: its text, whole, by one row or
//! by a range; its revision, length and row count in one record; the
//! conversions between a byte offset and a point; and where a motion leads
//! from a position. A snapshot never changes and is `Send + Sync`
//! ([`editor_text::Snapshot`]), so it sits behind no lock, and it outlives
//! its document.
//!
//! **What hands a snapshot handle out.** Every `# Safety` section below
//! asks for "a snapshot handle this library handed out and has not taken
//! back". The functions that hand one out are:
//!
//! - [`editor_ffi_document_snapshot`], a snapshot of a document;
//! - [`editor_ffi_files_take`](crate::files::editor_ffi_files_take), the
//!   text of a file the file service loaded, in the result of the load.
//!
//! Each makes its handle with the crate-private `Snapshot::hand_out`, the
//! one place a handle is made and counted live, and
//! [`editor_ffi_snapshot_free`] is the one function that takes a handle
//! back. A function that only reads a handle, such as
//! [`editor_ffi_document_from_snapshot`](crate::document::editor_ffi_document_from_snapshot)
//! or [`editor_ffi_files_save`](crate::files::editor_ffi_files_save),
//! leaves it the caller's.
//!
//! **A snapshot knows where it came from.** One taken of a document carries
//! the document's key and its [`Source`]: the document's text, held weakly
//! ([`Snapshot::of`]). So the display reaches the document's markers and
//! edit log through the snapshot handle it is given, and Lean's display
//! binding needs nothing but its table of snapshots: a published scene's
//! markers are read with [`Snapshot::marker`], and layout pulls patches
//! with [`Source::changes_since`], on a clone of the snapshot's source
//! that the display hands it as its changes port (`impl Changes for
//! Source`, in [`crate::display`]). That is the one path to the log from a
//! snapshot. A source does not keep the document alive: once the document
//! is freed it answers as a snapshot with none does. One no document holds,
//! a file's text as it was loaded, has a key of its own and no source
//! ([`Snapshot::loaded`]). Keys are given out once in the process, to
//! documents and to such snapshots alike.
//!
//! **A snapshot of an excerpt document carries its list** as it was when the
//! snapshot was taken ([`Snapshot::placed`]), read under the same locks as
//! its text ([`crate::excerpts`], "A snapshot carries its list"): so the
//! display places the headers and translates the sources' highlights by the
//! list of the text it draws, whatever the sources did since.
//!
//! What a row, a point, a position, a cell and a word are is the text's
//! rule, pinned by `editor-text`'s own tests. This module converts numbers
//! and forwards.
//!
//! A column is counted in bytes, in UTF-16 code units or in cells. The
//! unit crosses as a tag ([`ColumnUnit`]), so another unit is a tag and not
//! a function. Offsets cross as `usize`, as a document's do; rows and
//! columns as `u64`, in and out. A row or a column that no `usize` holds is
//! refused, never cut down.
//!
//! A bracket and a quote cross as tags as well ([`crate::pair`]), for the
//! two reads of a pair ([`editor_ffi_snapshot_unmatched`],
//! [`editor_ffi_snapshot_quoted`]), each of which answers with a status
//! ([`PairStatus`]) and fills its out parameters only when it found
//! something.
//!
//! A motion crosses as a tag too, with a count and a column for the two
//! motions by rows ([`editor_ffi_snapshot_motion`]; the table of tags is in
//! [`crate::motion`]), so another motion is a tag and not a function. Its
//! count and its column are the one place a number too large for a `usize`
//! is not refused: it is read as the largest, which means the same to a
//! motion that stops at the last row and at the end of a row's content.
//!
//! One row and a range are read as the whole text is, into an owned buffer
//! the caller hands back ([`editor_ffi_snapshot_row`],
//! [`editor_ffi_snapshot_slice`]), but as options: a row the text lacks and
//! a range that is not two positions in order are refused.
//!
//! What a selection covers in the snapshot's text
//! ([`editor_ffi_snapshot_extents`]) is asked and answered in words; the
//! module docs of [`crate::marker`] give both layouts.

use std::sync::{Arc, Mutex, PoisonError, Weak};

use std::ops::Range;

use editor_text::excerpt::Placed;
use editor_text::{
    Bracket, Marker, MarkerId, Motion, Patch, Point, PointCells, PointUtf16, Quote, Revision, Text,
};

use crate::document::{Document, RawText, next_key};
use crate::live::Live;
use crate::log::RawWords;
use crate::marker::{self, MarkStatus};
use crate::pair::{self, PairStatus};
use crate::{motion, text};

/// A document's text as it was when the snapshot was taken, or a file's
/// text as it was loaded, and where it came from.
pub struct Snapshot {
    /// The text.
    text: editor_text::Snapshot,
    /// The key of the text it is of: its document's, or, for one no
    /// document holds, a key of its own ([`next_key`]).
    key: u64,
    /// Where it came from.
    source: Source,
    /// For a snapshot of an excerpt document, its list as it was when the
    /// snapshot was taken, read under the same locks as the text
    /// ([`crate::excerpts`], "A snapshot carries its list"); `None` for any
    /// other.
    placed: Option<Arc<[Placed]>>,
}

/// Where a snapshot's text came from: the text of the document it was taken
/// of, held weakly so it does not keep the document alive, or nothing for a
/// snapshot no document holds. It is cloned out of its snapshot by whatever
/// must reach the document after the call that was handed the snapshot: the
/// display's layout keeps one to pull patches through.
#[derive(Clone, Default)]
pub struct Source(Option<Weak<Mutex<Text>>>);

impl Source {
    /// What changed in the document's text since `revision`, up to the
    /// document's revision now; `None` when there is no document, the
    /// document is gone, or its log refuses
    /// ([`editor_text::Text::changes_since`]).
    pub fn changes_since(&self, revision: Revision) -> Option<Patch> {
        self.read(|text| text.changes_since(revision).ok())
    }

    /// Whether there is a document and it is still alive.
    pub fn has_document(&self) -> bool {
        self.read(|_| Some(())).is_some()
    }

    /// `read` of the document's text, locked, if there is a document and it
    /// is still alive. A poisoned lock is used as it is, as a document does.
    fn read<T>(&self, read: impl FnOnce(&Text) -> Option<T>) -> Option<T> {
        let text = self.0.as_ref()?.upgrade()?;
        let text = text.lock().unwrap_or_else(PoisonError::into_inner);
        read(&text)
    }
}

/// The syntax service reaches a document's text through a source, as
/// layout does: the text as it is now and the patch since a revision, read
/// under one lock so the patch reaches exactly the snapshot.
impl editor_syntax::Source for Source {
    fn latest(&self, since: Option<Revision>) -> Option<editor_syntax::Latest> {
        self.read(|text| {
            Some(editor_syntax::Latest {
                snapshot: text.snapshot(),
                patch: since.and_then(|since| text.changes_since(since).ok()),
            })
        })
    }
}

/// The unit a point's column is counted in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColumnUnit {
    /// Bytes of UTF-8.
    Bytes = 0,
    /// UTF-16 code units.
    Utf16 = 1,
    /// Cells: how many cells of the row start before the position.
    Cells = 2,
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
            2 => Some(Self::Cells),
            _ => None,
        }
    }
}

impl Snapshot {
    /// A snapshot of `document`'s text as it is now, with the document as
    /// its source.
    pub fn of(document: &Document) -> Self {
        let (text, placed) = match document.snapshot_placed() {
            Some((text, placed)) => (text, Some(placed)),
            None => (document.snapshot(), None),
        };
        Self {
            text,
            key: document.key(),
            source: Source(Some(document.shared())),
            placed,
        }
    }

    /// A snapshot no document holds, such as a file's text as it was
    /// loaded: a key of its own, and no source.
    pub fn loaded(text: editor_text::Snapshot) -> Self {
        Self {
            text,
            key: next_key(),
            source: Source::default(),
            placed: None,
        }
    }

    /// For a snapshot of an excerpt document, its list as it was when the
    /// snapshot was taken: each excerpt's source, the source's snapshot it
    /// read, its range there and its range of this text. `None` for a
    /// snapshot of any other document and one no document holds.
    pub fn placed(&self) -> Option<&[Placed]> {
        self.placed.as_deref()
    }

    /// The key of its text: its document's, or its own when no document
    /// holds it.
    pub fn key(&self) -> u64 {
        self.key
    }

    /// The marker numbered `id` in its document's text as it is now; `None`
    /// when it has no document, the document is gone, or it holds no such
    /// marker.
    pub fn marker(&self, id: u64) -> Option<Marker> {
        self.source
            .read(|text| text.marker(MarkerId::new(id)).cloned())
    }

    /// Where it came from, through which its document's edit log is
    /// reached ([`Source::changes_since`]).
    pub fn source(&self) -> &Source {
        &self.source
    }
}

impl Snapshot {
    /// Hands `snapshot` out as a handle the caller owns, and counts it
    /// live: the caller must hand it to [`editor_ffi_snapshot_free`]
    /// exactly once. This is the one place a snapshot handle is made, so it
    /// is the one place one is counted.
    pub(crate) fn hand_out(snapshot: Self) -> *mut Self {
        LIVE.add();
        Box::into_raw(Box::new(snapshot))
    }

    /// The snapshot behind the handle.
    pub(crate) fn text(&self) -> &editor_text::Snapshot {
        &self.text
    }

    /// The row and column of the byte offset `offset`, with the column in
    /// `unit`. `None` when the offset is not a position of the text.
    pub fn point_of(&self, unit: ColumnUnit, offset: usize) -> Option<RawPoint> {
        let (row, column) = match unit {
            ColumnUnit::Bytes => {
                let point = self.text.offset_to_point(offset)?;
                (point.row, point.column)
            }
            ColumnUnit::Utf16 => {
                let point = self.text.offset_to_point_utf16(offset)?;
                (point.row, point.column)
            }
            ColumnUnit::Cells => {
                let point = self.text.offset_to_point_cells(offset)?;
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
            ColumnUnit::Bytes => self.text.point_to_offset(Point::new(row, column))?,
            ColumnUnit::Utf16 => self
                .text
                .point_utf16_to_offset(PointUtf16::new(row, column))?,
            ColumnUnit::Cells => self
                .text
                .point_cells_to_offset(PointCells::new(row, column))?,
        };
        Some(offset as u64)
    }

    /// Where `motion` leads from the byte offset `offset`
    /// ([`editor_text::Snapshot::motion`]). `None` when the offset is not a
    /// position of the text.
    pub fn motion(&self, motion: Motion, offset: usize) -> Option<u64> {
        Some(self.text.motion(motion, offset)? as u64)
    }

    /// The bracket the walk from the byte offset `offset` leaves unbalanced
    /// ([`editor_text::Snapshot::unmatched`]). `None` when the offset is not
    /// a position of the text; `Some(None)` when there is no such bracket.
    pub fn unmatched(
        &self,
        bracket: Bracket,
        opening: bool,
        forward: bool,
        escaped: bool,
        skip_quoted: bool,
        offset: usize,
    ) -> Option<Option<u64>> {
        let found = self
            .text
            .unmatched(bracket, opening, forward, escaped, skip_quoted, offset)?;
        Some(found.map(|at| at as u64))
    }

    /// The quoted string round the byte offset `offset`
    /// ([`editor_text::Snapshot::quoted`]). `None` when the offset is not a
    /// position of the text; `Some(None)` when there is no such string.
    pub fn quoted(&self, quote: Quote, offset: usize) -> Option<Option<Range<u64>>> {
        let found = self.text.quoted(quote, offset)?;
        Some(found.map(|range| range.start as u64..range.end as u64))
    }

    /// A copy of the content of the row `row`: the row without its line
    /// break ([`editor_text::Snapshot::row_to_string`]). `None` when the
    /// text has no such row, and when no `usize` holds the row.
    pub fn row(&self, row: u64) -> Option<String> {
        self.text.row_to_string(usize::try_from(row).ok()?)
    }

    /// A copy of the text from the byte offset `start` up to, not
    /// including, `end` ([`editor_text::Snapshot::slice_to_string`]).
    /// `None` unless both are positions of the text and `start <= end`.
    pub fn slice(&self, start: usize, end: usize) -> Option<String> {
        self.text.slice_to_string(start..end)
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
        let extents = self
            .text
            .extents(&selection)
            .ok_or(MarkStatus::BadSelection)?;
        Ok(marker::extent_words(&extents))
    }
}

/// How many snapshot handles this library has handed out
/// ([`Snapshot::hand_out`]) that [`editor_ffi_snapshot_free`] has not taken
/// back.
pub(crate) static LIVE: Live = Live::new();

/// A snapshot of the text of `document` as it is now, owned by the caller,
/// who must hand it to [`editor_ffi_snapshot_free`] exactly once. Later
/// edits to the document do not change it, and it may be freed before or
/// after the document.
///
/// # Safety
///
/// `document` is a document handle this library handed out and has not
/// taken back ([`crate::document`]).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_document_snapshot(document: *const Document) -> *mut Snapshot {
    // SAFETY: the caller guarantees `document` points to a live document.
    Snapshot::hand_out(Snapshot::of(unsafe { &*document }))
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
/// `snapshot` is a snapshot handle this library handed out and has not
/// taken back, and `out` points to a writable [`RawSnapshotInfo`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_snapshot_info(
    snapshot: *const Snapshot,
    out: *mut RawSnapshotInfo,
) {
    // SAFETY: the caller guarantees `snapshot` points to a live snapshot.
    let snapshot = &unsafe { &*snapshot }.text;
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
/// `snapshot` is a snapshot handle this library handed out and has not
/// taken back, and `out` points to a writable [`RawText`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_snapshot_read(snapshot: *const Snapshot, out: *mut RawText) {
    // SAFETY: the caller guarantees `snapshot` points to a live snapshot.
    let (text, text_len) = text::lend(unsafe { &*snapshot }.text.to_string());
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
/// `snapshot` is a snapshot handle this library handed out and has not
/// taken back, and `out` points to a writable [`RawPoint`].
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
/// `snapshot` is a snapshot handle this library handed out and has not
/// taken back, and `out` points to a writable `u64`.
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

/// [`Snapshot::motion`] for C: returns whether the byte offset `offset` is
/// a position of `snapshot`, and if so fills `out` with where the motion
/// `motion` is the tag of leads from it ([`motion::motion_of`]). `count`
/// and `column` are read for the two motions by rows and for no other.
///
/// False, with `out` untouched, also when `motion` is the tag of no
/// motion.
///
/// # Safety
///
/// `snapshot` is a snapshot handle this library handed out and has not
/// taken back, and `out` points to a writable `u64`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_snapshot_motion(
    snapshot: *const Snapshot,
    motion: u8,
    count: u64,
    column: u64,
    offset: usize,
    out: *mut u64,
) -> bool {
    let Some(motion) = motion::motion_of(motion, count, column) else {
        return false;
    };
    // SAFETY: the caller guarantees `snapshot` points to a live snapshot.
    let Some(answer) = unsafe { &*snapshot }.motion(motion, offset) else {
        return false;
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(answer) };
    true
}

/// [`Snapshot::unmatched`] for C: the bracket the tag `bracket` names
/// ([`pair::bracket_of`]) that the walk from the byte offset `offset` of
/// `snapshot` leaves unbalanced, an opening one when `opening`, strictly
/// after the offset when `forward` and before it otherwise, counting only
/// the brackets whose escapedness is `escaped`, and passing over those Vim
/// guesses are quoted when `skip_quoted`. Returns
/// [`PairStatus::Found`] with `out` filled, [`PairStatus::NotFound`], or
/// [`PairStatus::Refused`] for an offset that is not a position or a tag of
/// no bracket, with `out` untouched.
///
/// # Safety
///
/// `snapshot` is a snapshot handle this library handed out and has not
/// taken back, and `out` points to a writable `u64`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_snapshot_unmatched(
    snapshot: *const Snapshot,
    bracket: u8,
    opening: bool,
    forward: bool,
    escaped: bool,
    skip_quoted: bool,
    offset: usize,
    out: *mut u64,
) -> u8 {
    let Some(bracket) = pair::bracket_of(bracket) else {
        return PairStatus::Refused as u8;
    };
    // SAFETY: the caller guarantees `snapshot` points to a live snapshot.
    let answer =
        unsafe { &*snapshot }.unmatched(bracket, opening, forward, escaped, skip_quoted, offset);
    match answer {
        None => PairStatus::Refused as u8,
        Some(None) => PairStatus::NotFound as u8,
        Some(Some(at)) => {
            // SAFETY: the caller guarantees `out` is writable.
            unsafe { out.write(at) };
            PairStatus::Found as u8
        }
    }
}

/// [`Snapshot::quoted`] for C: the quoted string of the quote the tag
/// `quote` names ([`pair::quote_of`]) round the byte offset `offset` of
/// `snapshot`, from its opening quote's start to its closing quote's end.
/// Returns [`PairStatus::Found`] with `start` and `stop` filled,
/// [`PairStatus::NotFound`], or [`PairStatus::Refused`] for an offset that
/// is not a position or a tag of no quote, with both untouched.
///
/// # Safety
///
/// `snapshot` is a snapshot handle this library handed out and has not
/// taken back, and `start` and `stop` each point to a writable `u64`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_snapshot_quoted(
    snapshot: *const Snapshot,
    quote: u8,
    offset: usize,
    start: *mut u64,
    stop: *mut u64,
) -> u8 {
    let Some(quote) = pair::quote_of(quote) else {
        return PairStatus::Refused as u8;
    };
    // SAFETY: the caller guarantees `snapshot` points to a live snapshot.
    match unsafe { &*snapshot }.quoted(quote, offset) {
        None => PairStatus::Refused as u8,
        Some(None) => PairStatus::NotFound as u8,
        Some(Some(range)) => {
            // SAFETY: the caller guarantees both are writable.
            unsafe {
                start.write(range.start);
                stop.write(range.end);
            }
            PairStatus::Found as u8
        }
    }
}

/// [`Snapshot::row`] for C: returns whether `snapshot` has the row `row`,
/// and if so fills `out` with a copy of its content, the row without its
/// line break, in a buffer the caller hands back with
/// [`editor_ffi_text_free`](crate::text::editor_ffi_text_free). False, with
/// `out` untouched, otherwise.
///
/// # Safety
///
/// `snapshot` is a snapshot handle this library handed out and has not
/// taken back, and `out` points to a writable [`RawText`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_snapshot_row(
    snapshot: *const Snapshot,
    row: u64,
    out: *mut RawText,
) -> bool {
    // SAFETY: the caller guarantees `snapshot` points to a live snapshot.
    let Some(content) = unsafe { &*snapshot }.row(row) else {
        return false;
    };
    let (text, text_len) = text::lend(content);
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(RawText { text, text_len }) };
    true
}

/// [`Snapshot::slice`] for C: returns whether `start` and `end` are
/// positions of `snapshot` in order, and if so fills `out` with a copy of
/// the text between them, in a buffer the caller hands back with
/// [`editor_ffi_text_free`](crate::text::editor_ffi_text_free). False, with
/// `out` untouched, otherwise.
///
/// # Safety
///
/// `snapshot` is a snapshot handle this library handed out and has not
/// taken back, and `out` points to a writable [`RawText`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_snapshot_slice(
    snapshot: *const Snapshot,
    start: usize,
    end: usize,
    out: *mut RawText,
) -> bool {
    // SAFETY: the caller guarantees `snapshot` points to a live snapshot.
    let Some(slice) = unsafe { &*snapshot }.slice(start, end) else {
        return false;
    };
    let (text, text_len) = text::lend(slice);
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(RawText { text, text_len }) };
    true
}

/// [`Snapshot::extents_words`] for C: fills `out` with what the selection
/// the `len` bytes at `words` spell covers in `snapshot`, as words, and the
/// status [`MarkStatus::Done`]; or with no words and the status that says
/// why there are none.
///
/// # Safety
///
/// `snapshot` is a snapshot handle this library handed out and has not
/// taken back; `words` points to `len` readable bytes; and `out` points to a
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
/// `snapshot` is a snapshot handle this library handed out and has not
/// taken back, and it is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_snapshot_free(snapshot: *mut Snapshot) {
    // SAFETY: the caller guarantees `snapshot` is a box
    // `Snapshot::hand_out` gave up, taken back this once.
    drop(unsafe { Box::from_raw(snapshot) });
    LIVE.free();
}

/// How many snapshot handles this library has handed out that have not been
/// freed, whichever function handed each out. This is what makes a
/// snapshot's finaliser, and the lifetime of the editor's table of
/// snapshots, observable to a test, which waits for it to come down with
/// [`editor_ffi_live_await`](crate::live::editor_ffi_live_await).
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_snapshot_live() -> u64 {
    LIVE.count()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::words::tests::buffer;

    /// A snapshot of a document holding `text`.
    fn snapshot(text: &str) -> Snapshot {
        Snapshot::of(&Document::new(text))
    }

    #[test]
    fn a_documents_snapshot_reaches_its_documents_log_markers_and_key() {
        let document = Document::new("ab");
        let snapshot = Snapshot::of(&document);
        assert_eq!(snapshot.key(), document.key());
        let id = document
            .lock()
            .mark(Marker::Anchor(editor_text::Anchor {
                offset: 2,
                bias: editor_text::Bias::Before,
            }))
            .unwrap();
        assert!(document.replace(0, 0, "x"));
        // A clone of its source answers as it does, after the snapshot too.
        let source = snapshot.source().clone();
        let patch = source.changes_since(snapshot.text().revision()).unwrap();
        assert_eq!(patch.edits.len(), 1);
        // The marker as the document holds it now, moved by the edit.
        assert_eq!(
            snapshot.marker(id.get()),
            Some(Marker::Anchor(editor_text::Anchor {
                offset: 3,
                bias: editor_text::Bias::Before,
            }))
        );
        assert_eq!(snapshot.marker(id.get() + 1), None);
        // The snapshot does not keep its document alive.
        drop(document);
        assert_eq!(source.changes_since(Revision::new(0)), None);
        assert_eq!(snapshot.marker(id.get()), None);
    }

    #[test]
    fn a_snapshot_no_document_holds_has_a_key_of_its_own_and_no_source() {
        let document = Document::new("ab");
        let first = Snapshot::loaded(document.snapshot());
        let second = Snapshot::loaded(document.snapshot());
        assert_ne!(first.key(), document.key());
        assert_ne!(first.key(), second.key());
        assert_eq!(first.source().changes_since(Revision::new(0)), None);
        assert_eq!(first.marker(0), None);
    }

    #[test]
    fn two_documents_have_two_keys() {
        assert_ne!(Document::new("a").key(), Document::new("a").key());
    }

    #[test]
    fn a_column_unit_is_named_by_its_tag() {
        assert_eq!(ColumnUnit::from_tag(0), Some(ColumnUnit::Bytes));
        assert_eq!(ColumnUnit::from_tag(1), Some(ColumnUnit::Utf16));
        assert_eq!(ColumnUnit::from_tag(2), Some(ColumnUnit::Cells));
        for unit in [ColumnUnit::Bytes, ColumnUnit::Utf16, ColumnUnit::Cells] {
            assert_eq!(ColumnUnit::from_tag(unit.tag()), Some(unit));
        }
    }

    #[test]
    fn a_tag_that_names_no_column_unit_is_refused() {
        assert_eq!(ColumnUnit::from_tag(3), None);
        assert_eq!(ColumnUnit::from_tag(u8::MAX), None);
    }

    #[test]
    fn the_cells_unit_asks_the_text_for_its_point_in_cells() {
        // "é" is two bytes and "😀" four, and each is one cell and one or
        // two UTF-16 units, so the three columns of the "x" differ.
        const TEXT: &str = "a\né😀x";
        let snapshot = snapshot(TEXT);
        let text = Document::new(TEXT).snapshot();
        let cells = text.offset_to_point_cells(8).expect("a position");
        let expected = RawPoint {
            row: cells.row as u64,
            column: cells.column as u64,
        };

        assert_eq!(snapshot.point_of(ColumnUnit::Cells, 8), Some(expected));
        assert_eq!(
            snapshot.offset_of(ColumnUnit::Cells, expected.row, expected.column),
            Some(8)
        );
        assert_ne!(snapshot.point_of(ColumnUnit::Bytes, 8), Some(expected));
        assert_ne!(snapshot.point_of(ColumnUnit::Utf16, 8), Some(expected));
        // What the text refuses is refused: an offset inside "😀" and one
        // past the end, a row the text does not have, and a column no row
        // is as long as or no `usize` holds.
        assert_eq!(snapshot.point_of(ColumnUnit::Cells, 5), None);
        assert_eq!(snapshot.point_of(ColumnUnit::Cells, 10), None);
        assert_eq!(snapshot.offset_of(ColumnUnit::Cells, 2, 0), None);
        assert_eq!(snapshot.offset_of(ColumnUnit::Cells, 1, 4), None);
        assert_eq!(snapshot.offset_of(ColumnUnit::Cells, 0, u64::MAX), None);
        assert_eq!(snapshot.offset_of(ColumnUnit::Cells, u64::MAX, 0), None);
    }

    /// Characters of one, two and four bytes, a blank line, punctuation
    /// and a line break of each kind, so that no two motions answer alike
    /// everywhere.
    const MOVED_IN: &str = "foo.bar  x\r\n\r\n\tsé😀! y\nend";

    #[test]
    fn a_motion_is_what_the_text_answers_for_it() {
        let snapshot = snapshot(MOVED_IN);
        let text = Document::new(MOVED_IN).snapshot();

        // What each motion answers is the text's rule, so each answer is
        // compared with what the text itself answers.
        for tag in 0..motion::TAGS {
            let motion = motion::motion_of(tag, 1, 2).expect("the tag of a motion");
            for offset in [3, 7, 15] {
                let expected = text.motion(motion, offset).expect("a position");

                assert_eq!(
                    snapshot.motion(motion, offset),
                    Some(expected as u64),
                    "{motion:?} from {offset}"
                );
            }
        }
    }

    #[test]
    fn a_motion_from_an_offset_that_is_no_position_is_refused() {
        let snapshot = snapshot(MOVED_IN);

        for tag in 0..motion::TAGS {
            let motion = motion::motion_of(tag, 1, 2).expect("the tag of a motion");
            // Inside "é", past the end, and as far as an offset goes.
            for offset in [17, MOVED_IN.len() + 1, usize::MAX] {
                assert_eq!(snapshot.motion(motion, offset), None, "{motion:?}");
            }
        }
    }

    /// Brackets of each kind, nested, escaped, quoted, across rows, and
    /// quotes of each kind with an escaped one, so that no two reads answer
    /// alike everywhere.
    const PAIRED_IN: &str = "f(a [b] {\\(c\\)} \")\")\r\n\"x\\\"y\" 'z' `é`\n(";

    #[test]
    fn a_pair_is_what_the_text_answers_for_it() {
        let snapshot = snapshot(PAIRED_IN);
        let text = Document::new(PAIRED_IN).snapshot();

        let offsets: Vec<usize> = (0..=PAIRED_IN.len())
            .filter(|&offset| PAIRED_IN.is_char_boundary(offset))
            .collect();
        for tag in 0..pair::TAGS {
            let bracket = pair::bracket_of(tag).expect("the tag of a bracket");
            let quote = pair::quote_of(tag).expect("the tag of a quote");
            for &offset in &offsets {
                for (opening, forward, escaped, skip_quoted) in [
                    (false, true, false, false),
                    (true, false, false, false),
                    (true, true, false, false),
                    (false, true, true, false),
                    (true, false, true, false),
                    (false, true, false, true),
                    (true, false, false, true),
                ] {
                    let expected = text
                        .unmatched(bracket, opening, forward, escaped, skip_quoted, offset)
                        .expect("a position");
                    assert_eq!(
                        snapshot.unmatched(bracket, opening, forward, escaped, skip_quoted, offset),
                        Some(expected.map(|at| at as u64)),
                        "{bracket:?} {opening} {forward} {escaped} {skip_quoted} from {offset}"
                    );
                }
                let expected = text.quoted(quote, offset).expect("a position");
                assert_eq!(
                    snapshot.quoted(quote, offset),
                    Some(expected.map(|range| range.start as u64..range.end as u64)),
                    "{quote:?} from {offset}"
                );
            }
        }
    }

    #[test]
    fn a_pair_from_an_offset_that_is_no_position_is_refused() {
        let snapshot = snapshot(PAIRED_IN);
        // Inside "é", past the end, and as far as an offset goes.
        let inside = PAIRED_IN.find('é').expect("an é") + 1;
        for tag in 0..pair::TAGS {
            let bracket = pair::bracket_of(tag).expect("the tag of a bracket");
            let quote = pair::quote_of(tag).expect("the tag of a quote");
            for offset in [inside, PAIRED_IN.len() + 1, usize::MAX] {
                assert_eq!(
                    snapshot.unmatched(bracket, false, true, false, false, offset),
                    None
                );
                assert_eq!(snapshot.quoted(quote, offset), None);
            }
        }
    }

    #[test]
    fn a_pair_for_c_says_found_not_found_or_refused_and_fills_only_what_it_found() {
        let snapshot = snapshot("(a) \"b\"");
        let handle: *const Snapshot = &snapshot;
        let mut out = 99_u64;
        let (mut start, mut stop) = (98_u64, 99_u64);

        // SAFETY: the handle and the out parameters are live and writable.
        unsafe {
            assert_eq!(
                editor_ffi_snapshot_unmatched(handle, 0, false, true, false, false, 0, &mut out),
                PairStatus::Found as u8
            );
            assert_eq!(out, 2);
            assert_eq!(
                editor_ffi_snapshot_unmatched(handle, 1, false, true, false, false, 0, &mut out),
                PairStatus::NotFound as u8
            );
            assert_eq!(
                editor_ffi_snapshot_unmatched(handle, 0, false, true, false, false, 99, &mut out),
                PairStatus::Refused as u8
            );
            assert_eq!(
                editor_ffi_snapshot_unmatched(
                    handle,
                    pair::TAGS,
                    false,
                    true,
                    false,
                    false,
                    0,
                    &mut out
                ),
                PairStatus::Refused as u8
            );
            assert_eq!(out, 2);
            assert_eq!(
                editor_ffi_snapshot_quoted(handle, 0, 5, &mut start, &mut stop),
                PairStatus::Found as u8
            );
            assert_eq!((start, stop), (4, 7));
            assert_eq!(
                editor_ffi_snapshot_quoted(handle, 1, 5, &mut start, &mut stop),
                PairStatus::NotFound as u8
            );
            assert_eq!(
                editor_ffi_snapshot_quoted(handle, 0, 99, &mut start, &mut stop),
                PairStatus::Refused as u8
            );
            assert_eq!(
                editor_ffi_snapshot_quoted(handle, pair::TAGS, 5, &mut start, &mut stop),
                PairStatus::Refused as u8
            );
        }
        assert_eq!((start, stop), (4, 7));
    }

    #[test]
    fn a_row_and_a_range_are_read_as_the_text_reads_them() {
        let snapshot = snapshot(MOVED_IN);
        let text = Document::new(MOVED_IN).snapshot();

        for row in 0..4 {
            let expected = text.row_to_string(row).expect("a row of the text");

            assert_eq!(snapshot.row(row as u64), Some(expected), "row {row}");
        }
        // Through characters of several bytes and a line break, an empty
        // range, and the whole text.
        for (start, end) in [(14, 28), (5, 5), (0, MOVED_IN.len())] {
            let expected = text.slice_to_string(start..end).expect("two positions");

            assert_eq!(snapshot.slice(start, end), Some(expected), "{start}..{end}");
        }
    }

    #[test]
    fn a_row_the_text_lacks_and_a_range_that_is_not_two_positions_in_order_are_refused() {
        let snapshot = snapshot(MOVED_IN);

        assert_eq!(snapshot.row(4), None);
        assert_eq!(snapshot.row(u64::MAX), None);
        // Backwards, an end inside "é", past the end, and as far as an
        // offset goes.
        for (start, end) in [
            (5, 3),
            (0, 17),
            (17, 20),
            (0, MOVED_IN.len() + 1),
            (usize::MAX, usize::MAX),
        ] {
            assert_eq!(snapshot.slice(start, end), None, "{start}..{end}");
        }
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
