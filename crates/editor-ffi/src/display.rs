//! The display: layout behind a handle, which Lean publishes scenes to and
//! asks the layout queries of.
//!
//! A [`Display`] holds an [`editor_layout::Layout`] over the published fake
//! shaper, [`CellShaper`], whose every glyph has one size: what the display
//! interface's contract is run at (`lean/Editor/Display/Contract.lean`) and
//! what the headless editor needs until a real shaper adapter exists (the
//! display pipeline's phase 3). It is made by
//! [`editor_ffi_display_new_cells`], counted live, and freed by
//! [`editor_ffi_display_free`].
//!
//! **A text crosses as a snapshot handle.** Each query names the snapshot it
//! is about by its handle, and layout keeps what it laid out per key of the
//! text ([`crate::snapshot`]): a document's snapshots share their
//! document's key, and layout pulls the document's patches through the
//! snapshot's source ([`SourceChanges`]) to move what it kept. A snapshot
//! with no source is never moved, only laid out again.
//!
//! **The queries** answer in words ([`crate::log::RawWords`]), with a status
//! ([`DisplayStatus`]):
//!
//! - the rows a view shows ([`editor_ffi_display_rows`]): their count, and
//!   a start and a stop for each;
//! - where a move goes ([`editor_ffi_display_move`]): the position, and the
//!   goal to pass to the next move, in whole pixels.
//!
//! Pixels cross as whole numbers, as Lean's are; a goal x is passed back
//! rounded down. What the answers are is layout's rule, pinned by
//! `editor-layout`'s tests; this module converts and forwards.
//!
//! One lock is held for a call. Lean calls the display from the editor
//! thread only, so it is never contended there; it is a lock because a
//! handle is `Send + Sync` with `&self` methods (the crate's conventions).

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};

use editor_layout::Layout;
use editor_layout::query::{Moved, QueryError, RowRange};
use editor_layout::scene::{Changes, TextKey, TextRef};
use editor_layout::shaper::fake::CellShaper;
use editor_text::{Patch, Revision, Text};

use crate::log::RawWords;
use crate::snapshot::{Snapshot, read_text};
use crate::words::Writer;

/// How a display call ended, as it crosses the boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DisplayStatus {
    /// Answered.
    Done = 0,
    /// Refused: an offset is not a position of the text.
    BadPosition = 1,
}

/// The [`Changes`] of a text, pulled from its document through a snapshot's
/// source.
pub struct SourceChanges(Option<Weak<Mutex<Text>>>);

impl Changes for SourceChanges {
    fn since(&self, revision: Revision) -> Option<Patch> {
        read_text(self.0.as_ref(), |text| text.changes_since(revision).ok())
    }
}

/// The text a snapshot handle stands for, as layout takes it.
pub fn text_ref(snapshot: &Snapshot) -> TextRef {
    TextRef {
        key: TextKey(snapshot.key()),
        snapshot: snapshot.text().clone(),
        changes: Arc::new(SourceChanges(snapshot.source().cloned())),
    }
}

/// Layout behind a handle.
pub struct Display {
    /// The layout.
    layout: Mutex<Layout<CellShaper>>,
}

impl Display {
    /// A display whose every glyph is `advance` pixels across and every
    /// line `line_height` down.
    pub fn cells(advance: u64, line_height: u64) -> Self {
        Self {
            layout: Mutex::new(Layout::new(CellShaper::new(
                advance as f32,
                line_height as f32,
            ))),
        }
    }

    /// The layout, locked. A poisoned lock is used as it is: what layout
    /// keeps is a cache, which a later call checks or lays out again.
    fn layout(&self) -> MutexGuard<'_, Layout<CellShaper>> {
        self.layout.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The rows of `snapshot` a view `width` pixels wide and `height` tall
    /// shows from `anchor` ([`Layout::rows_shown`]).
    pub fn rows(
        &self,
        snapshot: &Snapshot,
        width: u64,
        height: u64,
        anchor: usize,
    ) -> Result<Vec<RowRange>, QueryError> {
        self.layout()
            .rows_shown(&text_ref(snapshot), width as f32, height as f32, anchor)
    }

    /// Where `position` of `snapshot` goes `lines` visual lines away in a
    /// view `width` pixels wide, aiming for `goal` ([`Layout::lines_from`]).
    pub fn lines_from(
        &self,
        snapshot: &Snapshot,
        width: u64,
        position: usize,
        lines: i64,
        goal: Option<u64>,
    ) -> Result<Moved, QueryError> {
        self.layout().lines_from(
            &text_ref(snapshot),
            width as f32,
            position,
            lines,
            goal.map(|goal| goal as f32),
        )
    }
}

/// The record for `answer`: its words, or the status of its refusal.
fn answered<T>(answer: Result<T, QueryError>, write: impl FnOnce(T, &mut Writer)) -> RawWords {
    match answer {
        Ok(value) => {
            let mut writer = Writer::with_capacity(4);
            write(value, &mut writer);
            RawWords::with_status(DisplayStatus::Done as u64, writer.finish())
        }
        Err(QueryError::BadPosition) => {
            RawWords::with_status(DisplayStatus::BadPosition as u64, Vec::new())
        }
    }
}

/// How many display handles this library has handed out
/// ([`editor_ffi_display_new_cells`]) that [`editor_ffi_display_free`] has
/// not taken back.
static LIVE: AtomicU64 = AtomicU64::new(0);

/// A new display over the fake shaper, its glyphs `advance` pixels across
/// and its lines `line_height` down, owned by the caller, who must hand it
/// to [`editor_ffi_display_free`] exactly once.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_display_new_cells(advance: u64, line_height: u64) -> *mut Display {
    LIVE.fetch_add(1, Ordering::Relaxed);
    Box::into_raw(Box::new(Display::cells(advance, line_height)))
}

/// Fills `out` with the rows of `snapshot` a view `width` pixels wide and
/// `height` tall shows from `anchor`: their count, then a start and a stop
/// for each; or with [`DisplayStatus::BadPosition`].
///
/// # Safety
///
/// `display` is a display handle this library handed out and has not taken
/// back, `snapshot` a snapshot handle likewise ([`crate::snapshot`]), and
/// `out` points to a writable [`RawWords`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_display_rows(
    display: *const Display,
    snapshot: *const Snapshot,
    width: u64,
    height: u64,
    anchor: usize,
    out: *mut RawWords,
) {
    // SAFETY: the caller guarantees both handles are live.
    let (display, snapshot) = unsafe { (&*display, &*snapshot) };
    let raw = answered(
        display.rows(snapshot, width, height, anchor),
        |rows, writer| {
            writer.size(rows.len());
            for row in rows {
                writer.size(row.start);
                writer.size(row.stop);
            }
        },
    );
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
}

/// Fills `out` with where `position` of `snapshot` goes `lines` visual
/// lines down (up when negative) in a view `width` pixels wide, aiming for
/// `goal` when `goal_present`: the position reached and the goal to pass
/// on; or with [`DisplayStatus::BadPosition`].
///
/// # Safety
///
/// As [`editor_ffi_display_rows`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_display_move(
    display: *const Display,
    snapshot: *const Snapshot,
    width: u64,
    position: usize,
    lines: i64,
    goal_present: bool,
    goal: u64,
    out: *mut RawWords,
) {
    // SAFETY: the caller guarantees both handles are live.
    let (display, snapshot) = unsafe { (&*display, &*snapshot) };
    let goal = goal_present.then_some(goal);
    let raw = answered(
        display.lines_from(snapshot, width, position, lines, goal),
        |moved, writer| {
            writer.size(moved.position);
            writer.word(moved.goal.max(0.0) as u64);
        },
    );
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
}

/// Frees `display`.
///
/// # Safety
///
/// `display` is a display handle this library handed out and has not taken
/// back, and it is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_display_free(display: *mut Display) {
    // SAFETY: the caller guarantees `display` is a box
    // `editor_ffi_display_new_cells` gave up, taken back this once.
    drop(unsafe { Box::from_raw(display) });
    LIVE.fetch_sub(1, Ordering::Relaxed);
}

/// How many display handles this library has handed out that have not been
/// freed.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_display_live() -> u64 {
    LIVE.load(Ordering::Relaxed)
}

#[cfg(test)]
mod tests {
    use super::text_ref;
    use crate::document::Document;
    use crate::snapshot::Snapshot;

    #[test]
    fn a_documents_snapshot_is_a_text_whose_changes_are_its_documents() {
        let document = Document::new("ab");
        let snapshot = Snapshot::of(&document);
        let text = text_ref(&snapshot);
        assert_eq!(text.key.0, document.key());
        assert!(document.replace(1, 1, "x"));
        let patch = text.changes.since(snapshot.text().revision()).unwrap();
        assert_eq!((patch.edits[0].new.start, patch.edits[0].new.end), (1, 2));
        drop(document);
        assert!(text.changes.since(snapshot.text().revision()).is_none());
    }

    #[test]
    fn a_snapshot_no_document_holds_has_no_changes() {
        let snapshot = Snapshot::loaded(Document::new("ab").snapshot());
        let text = text_ref(&snapshot);
        assert_eq!(text.key.0, snapshot.key());
        assert!(text.changes.since(snapshot.text().revision()).is_none());
    }
}
