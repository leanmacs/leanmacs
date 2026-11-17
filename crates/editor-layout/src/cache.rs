//! What layout keeps between calls, per text, and what it counts.
//!
//! **Entries are moved through patches, not cleared.** They are keyed by
//! buffer row, and a [`Patch`] says which rows each edit replaced, so the
//! entries of untouched rows move by the rows an edit added or removed
//! (`Layer::sync`). Patches are pulled through the [`Changes`](crate::scene::Changes) port of the
//! view's [`TextRef`]. When there is no patch to pull (the log has
//! forgotten the revision kept, or the text is gone), the text's state is
//! rebuilt lazily from the snapshot at hand: correct, at the cost of
//! shaping the visible rows once. A snapshot older than what is kept is
//! laid out in a scratch state that is thrown away, so the kept state
//! never moves backwards. A publish drops the state of every text its
//! scene does not name.
//!
//! **Line storage is sparse.** A text's entries are a map of the rows laid
//! out, not a summarised tree: a row not laid out is estimated as one
//! visual line of the default height (`Layout::height_estimate`) and
//! corrected when it is. Moving the entries through a patch costs the
//! entries held, which a publish keeps near the rows shown: those farther
//! than [`KEPT_VIEW_HEIGHTS`](crate::frame::KEPT_VIEW_HEIGHTS) view heights
//! from every view of the text are dropped. A summarised tree waits for a
//! layer that needs sums over the whole text (folds, a scroll bar).
//!
//! Each text a scene or a query names (by its [`TextKey`]) has a wrap
//! layer: the segments laid out so far, at the last width asked. Frames and
//! queries read and fill the same entries, so a query after a frame lays
//! out nothing the frame laid out, and a frame after a query likewise.
//!
//! **What a kept row is of.** An entry is the layout of one segment in
//! the font runs it was shaped with, under the shaper's generation, at a
//! width, and is used again only when all three are what is asked now. A
//! font's id is the shaper's for a spec in physical pixels, which is the
//! faces' spec at the scale layout was last told
//! ([`Layout::set_scale`](crate::Layout::set_scale)). So the scale is in
//! the key as the font, and has no field of its own: at another scale
//! every run is in another font, and each kept row is shaped again when a
//! frame or a query next reaches it. Nothing is dropped for a change of
//! scale but the styles kept by stack of faces and the base font, which
//! are not keyed by a font
//! ([`Styles::set_scale`](crate::decoration::Styles::set_scale)). A row
//! shaped at 28 points at scale 1 is the row of 14 points at scale 2.
//!
//! **A view's status row is kept by view**, not by text
//! (`StatusKept`): its fields are the scene's own text. Each field is a
//! line of its own (`FieldKept`), found again by its text and its font,
//! wherever it is in the row: a field is shaped again when its text or its
//! font change, every field when the shaper's generation changes, and the
//! whole row is dropped when a scene does not name its view. So a
//! line:col that changes shapes that field alone. It is no segment of a
//! text, so the counters below do not count it; a test bounds it by the
//! bytes the fake shaper was asked to shape.
//!
//! # Counters
//!
//! [`Counters`] count the work, for the performance gates. Each frame or
//! query counts each segment it reaches once, by how it got it the first
//! time: `shaped` (shaped and broken), `broken` (a kept shaped line broken
//! again at another width; a shaped segment counts here too) or `reused`
//! (a kept entry as it was).

use std::collections::HashMap;
use std::ops::{Deref, DerefMut};
use std::sync::Arc;

use editor_text::{Patch, Snapshot};

use crate::decoration::{FaceSpanSource, SelectionSource};
use crate::layer::{Layer, LayerEdit};
use crate::scene::{TextKey, TextRef};
use crate::shaper::{FontRun, ShapedLine, VisualLine};
use crate::tabs::{TabLayer, TabSnapshot};
use crate::wrap::{Outcome, WrapLayer};

/// The work layout has done, since it was made.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Counters {
    /// Segments shaped.
    pub shaped: u64,
    /// Segments broken into visual lines: once each time one is shaped,
    /// and once each time a kept one is broken again at another width.
    pub broken: u64,
    /// Segments used as they were kept.
    pub reused: u64,
}

impl Counters {
    /// Adds the outcome of each segment one call reached.
    pub(crate) fn add(&mut self, seen: &HashMap<(usize, usize), Outcome>) {
        for outcome in seen.values() {
            match outcome {
                Outcome::Shaped => {
                    self.shaped += 1;
                    self.broken += 1;
                }
                Outcome::Broken => self.broken += 1,
                Outcome::Reused => self.reused += 1,
            }
        }
    }
}

/// What layout keeps of one text.
pub(crate) struct TextState<L> {
    /// Its wrap layer.
    pub wrap: WrapLayer<L>,
    /// The selections and decorations of the last frame that showed it,
    /// so that a query shapes a row in the fonts the frame did. Read only
    /// while the text is at the revision they were laid out at. The text's
    /// own spans are not kept here: a query resolves them for the snapshot
    /// it is asked about ([`TextRef::spans`](crate::scene::TextRef::spans)),
    /// which an edit makes newer than the last frame's.
    pub sources: Option<(SelectionSource, FaceSpanSource)>,
}

/// What layout keeps, by text.
pub(crate) type Texts<L> = HashMap<TextKey, TextState<L>>;

/// What layout keeps of a view's status row: each field's shaped line, and
/// what it was shaped from, so that a field is shaped again only when its
/// text, its font or the shaper's generation change.
pub(crate) struct StatusKept {
    /// The shaper's generation its lines were shaped under.
    pub generation: u64,
    /// One line per field shaped, in the row's order.
    pub fields: Vec<FieldKept>,
}

/// What layout keeps of one status field.
pub(crate) struct FieldKept {
    /// The text it was shaped from, a tab, a return and a line feed made
    /// spaces.
    pub text: String,
    /// The font run it was shaped with.
    pub runs: Vec<FontRun>,
    /// The line, unbroken, its clusters bytes of `text`.
    pub line: Arc<VisualLine>,
}

/// What layout keeps of one text for one call: the kept state, or, for
/// a snapshot older than what is kept, a scratch state thrown away after
/// the call, so the kept one never moves backwards.
pub(crate) enum Held<'a, L> {
    /// The kept state.
    Kept(&'a mut TextState<L>),
    /// A scratch state.
    Scratch(Box<TextState<L>>),
}

impl<L> Deref for Held<'_, L> {
    type Target = TextState<L>;

    fn deref(&self) -> &TextState<L> {
        match self {
            Self::Kept(state) => state,
            Self::Scratch(state) => state,
        }
    }
}

impl<L> DerefMut for Held<'_, L> {
    fn deref_mut(&mut self) -> &mut TextState<L> {
        match self {
            Self::Kept(state) => state,
            Self::Scratch(state) => state,
        }
    }
}

impl<L: ShapedLine> TextState<L> {
    /// Nothing laid out of `snapshot` yet.
    pub(crate) fn fresh(snapshot: &Snapshot, tab_width: usize, width: Option<f32>) -> Self {
        Self {
            wrap: WrapLayer::new(TabSnapshot::new(snapshot.clone(), tab_width), width),
            sources: None,
        }
    }

    /// Moves the entries to `snapshot` through `patch`, which goes from the
    /// kept revision to the snapshot's.
    fn move_through(&mut self, snapshot: &Snapshot, patch: &Patch) {
        let edits: Vec<LayerEdit<usize>> = patch
            .edits
            .iter()
            .map(|edit| LayerEdit {
                old: edit.old.start..edit.old.end,
                new: edit.new.start..edit.new.end,
            })
            .collect();
        let mut tabs = TabLayer::over(self.wrap.tabs().clone());
        let (moved, tab_edits) = tabs.sync(snapshot, &edits);
        self.wrap.sync(&moved, &tab_edits);
        self.sources = None;
    }
}

/// The state of `text`, ready to lay it out at `width`:
///
/// - what is kept, when it is of the snapshot's revision;
/// - what is kept moved through the patch from its revision to the
///   snapshot's, pulled through `text.changes`;
/// - rebuilt from the snapshot when that patch cannot be had (the log has
///   forgotten it, the text is gone, or it does not reach the snapshot's
///   revision);
/// - a scratch state for a snapshot older than what is kept.
pub(crate) fn state<'a, L: ShapedLine>(
    texts: &'a mut Texts<L>,
    text: &TextRef,
    tab_width: usize,
    width: Option<f32>,
) -> Held<'a, L> {
    let snapshot = &text.snapshot;
    let revision = snapshot.revision();
    let state = texts
        .entry(text.key)
        .or_insert_with(|| TextState::fresh(snapshot, tab_width, width));
    let kept = state.wrap.tabs().buffer().revision();
    if kept > revision {
        return Held::Scratch(Box::new(TextState::fresh(snapshot, tab_width, width)));
    }
    if kept < revision {
        match text.changes.since(kept) {
            Some(patch) if patch.from == kept && patch.to == revision => {
                state.move_through(snapshot, &patch);
            }
            _ => *state = TextState::fresh(snapshot, tab_width, width),
        }
    }
    state.wrap.set_width(width);
    Held::Kept(state)
}

#[cfg(test)]
mod tests {
    use editor_text::Text;

    use crate::Layout;
    use crate::scene::{Cursor, Rect, Scene, TextKey, TextRef, View, ViewId};
    use crate::shaper::fake::CellShaper;

    /// A scene of one view of `text`, 4 cells wide and `rows` rows tall,
    /// from `scroll`.
    fn scene(text: &TextRef, rows: u32, scroll: usize) -> Scene {
        Scene {
            views: vec![View {
                id: ViewId(1),
                rect: Rect {
                    x: 0,
                    y: 0,
                    width: 40,
                    height: rows * 16,
                },
                text: Some(text.clone()),
                scroll,
                cursor: Cursor::default(),
                ..View::default()
            }],
            ..Scene::default()
        }
    }

    #[test]
    fn an_unlaid_row_counts_one_line_until_laid_out() {
        // Ten rows; row 2 wraps into three lines at 4 cells.
        let text = TextRef::fixed(
            TextKey(1),
            Text::from("a\nb\nabcdefghij\nc\nd\ne\nf\ng\nh\ni").snapshot(),
        );
        let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
        assert_eq!(layout.height_estimate(&text, 40.0), 10.0 * 16.0);
        layout.frame(&scene(&text, 3, 0));
        // Only rows 0 and 1 and the first line of row 2 are shown, but row
        // 2 is laid out whole: it is three lines now.
        assert_eq!(layout.height_estimate(&text, 40.0), 12.0 * 16.0);
        // At another width the kept rows are estimates again.
        assert_eq!(layout.height_estimate(&text, 400.0), 10.0 * 16.0);
    }

    #[test]
    fn a_text_edited_since_it_was_laid_out_is_estimated_from_no_kept_row() {
        // Four rows; row 2 wraps into three lines at 4 cells.
        let mut edited = Text::from("a\nb\nabcdefghij\nc");
        let before = TextRef::fixed(TextKey(1), edited.snapshot());
        let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
        layout.frame(&scene(&before, 3, 0));
        assert_eq!(layout.height_estimate(&before, 40.0), 6.0 * 16.0);
        // A row is put before them, so row 2 is "b". What is kept is of
        // the older revision, where row 2 was the wrapped row: until a
        // frame or a query moves it, no row of the edited text is counted
        // by it, and each counts one line.
        edited.replace(0..0, "x\n").unwrap();
        let after = TextRef::fixed(TextKey(1), edited.snapshot());
        assert_eq!(layout.height_estimate(&after, 40.0), 5.0 * 16.0);
    }

    #[test]
    fn rows_farther_than_four_view_heights_from_every_view_are_dropped() {
        let rows: Vec<String> = (0..1000).map(|row| format!("r{row}")).collect();
        let text = TextRef::fixed(TextKey(1), Text::from(rows.join("\n").as_str()).snapshot());
        let start = |row: usize| text.snapshot.row_range(row).unwrap().start;
        let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
        layout.frame(&scene(&text, 10, 0));
        assert_eq!(layout.entries_kept(TextKey(1)), 10);
        // Rows 30 to 39: rows 0 to 9 are within four view heights.
        layout.frame(&scene(&text, 10, start(30)));
        assert_eq!(layout.entries_kept(TextKey(1)), 20);
        layout.frame(&scene(&text, 10, start(500)));
        assert_eq!(layout.entries_kept(TextKey(1)), 10);
    }

    #[test]
    fn rows_near_any_view_of_a_text_are_kept() {
        let rows: Vec<String> = (0..1000).map(|row| format!("r{row}")).collect();
        let text = TextRef::fixed(TextKey(1), Text::from(rows.join("\n").as_str()).snapshot());
        let start = |row: usize| text.snapshot.row_range(row).unwrap().start;
        // Two views of the one text, far more than four view heights
        // apart: rows 0 to 9 and rows 500 to 509.
        let mut two = scene(&text, 10, 0);
        let mut second = scene(&text, 10, start(500)).views.remove(0);
        second.id = ViewId(2);
        two.views.push(second);
        let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
        layout.frame(&two);
        assert_eq!(layout.entries_kept(TextKey(1)), 20);
        // So the next frame shapes nothing.
        let before = layout.counters();
        layout.frame(&two);
        let after = layout.counters();
        assert_eq!(after.shaped, before.shaped);
        assert_eq!(after.reused - before.reused, 20);
    }
}
