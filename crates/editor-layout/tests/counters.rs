//! What layout costs, counted: segments shaped, segments broken into
//! visual lines, and laid-out segments reused as they were
//! ([`Counters`]). A count is the same on every machine, where a duration
//! is not.
//!
//! The texts are built with `editor_text::Text` and edited one change per
//! transaction, so no count depends on how the text's log joins edits
//! into a patch, which is `editor-text`'s rule.

use std::sync::{Arc, Mutex};

use editor_layout::Layout;
use editor_layout::cache::Counters;
use editor_layout::scene::{Changes, Cursor, Rect, Scene, TextKey, TextRef, View, ViewId};
use editor_layout::shaper::fake::CellShaper;
use editor_text::{Patch, Revision, Selection, SelectionRange, Text};

/// A text behind a lock, as the binding holds one, and its changes.
#[derive(Clone)]
struct Shared(Arc<Mutex<Text>>);

impl Changes for Shared {
    fn since(&self, revision: Revision) -> Option<Patch> {
        self.0.lock().unwrap().changes_since(revision).ok()
    }
}

impl Shared {
    /// A shared text holding `text`.
    fn new(text: &str) -> Self {
        Self(Arc::new(Mutex::new(Text::from(text))))
    }

    /// The text as it is now, as key 1.
    fn now(&self) -> TextRef {
        TextRef {
            key: TextKey(1),
            snapshot: self.0.lock().unwrap().snapshot(),
            changes: Arc::new(self.clone()),
        }
    }

    /// Puts `text` in place of `range`, as one transaction.
    fn replace(&self, range: std::ops::Range<usize>, text: &str) {
        self.0.lock().unwrap().replace(range, text).unwrap();
    }
}

/// Twenty rows of one word.
fn twenty_words() -> String {
    (0..20)
        .map(|row| format!("word{row}"))
        .collect::<Vec<_>>()
        .join("\n")
}

/// A scene of one view of `text`, `width` pixels wide and tall enough for
/// forty rows, with a cursor at `cursor`.
fn scene(text: &TextRef, width: u32, cursor: usize) -> Scene {
    scene_rows(text, width, cursor, 40)
}

/// [`scene`] with a view `rows` rows tall.
fn scene_rows(text: &TextRef, width: u32, cursor: usize, rows: u32) -> Scene {
    Scene {
        views: vec![View {
            id: ViewId(1),
            rect: Rect {
                x: 0,
                y: 0,
                width,
                height: rows * 16,
            },
            text: Some(text.clone()),
            scroll: 0,
            selections: vec![Selection::new(vec![SelectionRange::new(cursor, cursor)], 0).unwrap()],
            cursor: Cursor::default(),
            decorations: vec![],
            status: vec![],
        }],
        ..Scene::default()
    }
}

/// What `layout` counted while `run` ran.
fn counted(layout: &mut Layout<CellShaper>, run: impl FnOnce(&mut Layout<CellShaper>)) -> Counters {
    let before = layout.counters();
    run(layout);
    let after = layout.counters();
    Counters {
        shaped: after.shaped - before.shaped,
        broken: after.broken - before.broken,
        reused: after.reused - before.reused,
    }
}

/// A count of `shaped`, `broken` and `reused`.
fn count(shaped: u64, broken: u64, reused: u64) -> Counters {
    Counters {
        shaped,
        broken,
        reused,
    }
}

#[test]
fn a_first_frame_shapes_every_row_it_shows_and_the_next_reuses_them() {
    let text = TextRef::fixed(TextKey(1), Text::from(twenty_words().as_str()).snapshot());
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    let first = counted(&mut layout, |layout| {
        layout.frame(&scene(&text, 400, 0));
    });
    assert_eq!(first, count(20, 20, 0));
    let again = counted(&mut layout, |layout| {
        layout.frame(&scene(&text, 400, 0));
    });
    assert_eq!(again, count(0, 0, 20));
}

#[test]
fn a_width_change_breaks_every_row_again_and_shapes_none() {
    let text = TextRef::fixed(TextKey(1), Text::from(twenty_words().as_str()).snapshot());
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    layout.frame(&scene(&text, 400, 0));
    let wider = counted(&mut layout, |layout| {
        layout.frame(&scene(&text, 500, 0));
    });
    assert_eq!(wider, count(0, 20, 0));
}

#[test]
fn a_cursor_move_neither_shapes_nor_breaks() {
    let text = TextRef::fixed(TextKey(1), Text::from(twenty_words().as_str()).snapshot());
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    layout.frame(&scene(&text, 400, 0));
    let moved = counted(&mut layout, |layout| {
        layout.frame(&scene(&text, 400, 12));
    });
    assert_eq!(moved, count(0, 0, 20));
}

#[test]
fn a_font_change_shapes_every_row_again() {
    let text = TextRef::fixed(TextKey(1), Text::from(twenty_words().as_str()).snapshot());
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    layout.frame(&scene(&text, 400, 0));
    layout.shaper().change_fonts();
    let reshaped = counted(&mut layout, |layout| {
        layout.frame(&scene(&text, 400, 0));
    });
    assert_eq!(reshaped, count(20, 20, 0));
}

#[test]
fn a_query_reuses_what_a_frame_laid_out() {
    let text = TextRef::fixed(TextKey(1), Text::from(twenty_words().as_str()).snapshot());
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    layout.frame(&scene(&text, 400, 0));
    let queried = counted(&mut layout, |layout| {
        layout.rows_shown(&text, 400.0, 5.0 * 16.0, 0).unwrap();
        layout.lines_from(&text, 400.0, 0, 3, None).unwrap();
    });
    assert_eq!((queried.shaped, queried.broken), (0, 0));
}

#[test]
fn an_edit_reshapes_only_the_row_it_touched() {
    let shared = Shared::new(&twenty_words());
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    layout.frame(&scene(&shared.now(), 400, 0));
    // One character into row 5, "word5", which starts at byte 30.
    shared.replace(31..31, "x");
    let edited = counted(&mut layout, |layout| {
        layout.frame(&scene(&shared.now(), 400, 0));
    });
    assert_eq!(edited, count(1, 1, 19));
}

#[test]
fn a_line_feed_shapes_the_two_rows_it_made_and_moves_the_rest() {
    let shared = Shared::new(&twenty_words());
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    layout.frame(&scene(&shared.now(), 400, 0));
    shared.replace(0..0, "\n");
    let edited = counted(&mut layout, |layout| {
        layout.frame(&scene(&shared.now(), 400, 0));
    });
    assert_eq!(edited, count(2, 2, 19));
}

#[test]
fn an_edit_below_the_view_reshapes_nothing_shown() {
    let shared = Shared::new(&twenty_words());
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    layout.frame(&scene_rows(&shared.now(), 400, 0, 10));
    // Row 15 is not shown, and a line feed there moves no row shown.
    let row_15 = shared.now().snapshot.row_range(15).unwrap().start;
    shared.replace(row_15..row_15, "new\n");
    let edited = counted(&mut layout, |layout| {
        layout.frame(&scene_rows(&shared.now(), 400, 0, 10));
    });
    assert_eq!(edited, count(0, 0, 10));
}
