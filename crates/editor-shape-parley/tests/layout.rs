//! Layout over the real shaper: wiring only.
//!
//! What layout shapes, and when, is `editor-layout`'s rule, pinned there
//! on the port's fake; what a `shape` call costs is this crate's, pinned
//! in `tests/adapter.rs`. These tests put the two together and compare
//! the adapter's counters with layout's own, and with the longest segment
//! layout hands a shaper, by name. They state no row, no width and no
//! number of layout's.

mod common;

use editor_layout::Layout;
use editor_layout::scene::{Padding, Rect, Scene};
use editor_layout::tabs::SEGMENT_BYTES;
use editor_shape_parley::{ParleyShaper, ShapeCounters};

use common::shaper;

/// A view's rectangle `width` pixels across, tall enough for every row of
/// the texts here.
fn rect(width: u32) -> Rect {
    Rect {
        x: 0,
        y: 0,
        width,
        height: 4000,
    }
}

/// Twenty rows of two words, the row `changed` with one more.
fn twenty_rows(changed: Option<usize>) -> String {
    (0..20)
        .map(|row| match changed {
            Some(at) if at == row => format!("row {row} edited"),
            _ => format!("row {row}"),
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// How many segments layout says it shaped while `run` ran, and what its
/// shaper counted meanwhile. Of layout's counters only that one is read:
/// the others are layout's own business, and it may add to them.
fn counted(
    layout: &mut Layout<ParleyShaper>,
    run: impl FnOnce(&mut Layout<ParleyShaper>),
) -> (u64, ShapeCounters) {
    let (laid, shaped) = (layout.counters().shaped, layout.shaper().counters());
    run(layout);
    let (laid_after, shaped_after) = (layout.counters().shaped, layout.shaper().counters());
    (
        laid_after - laid,
        ShapeCounters {
            layouts: shaped_after.layouts - shaped.layouts,
            bytes: shaped_after.bytes - shaped.bytes,
        },
    )
}

#[test]
fn layout_builds_one_parley_layout_for_each_segment_it_shapes() {
    let mut layout = Layout::new(shaper());
    let text = twenty_rows(None);
    let steps: Vec<(&str, Scene)> = vec![
        ("a first frame", Scene::of_text(&text, rect(800))),
        ("the same frame again", Scene::of_text(&text, rect(800))),
        (
            "a row edited",
            Scene::of_text(&twenty_rows(Some(7)), rect(800)),
        ),
        ("a narrower view", Scene::of_text(&text, rect(40))),
        (
            "a cursor placed",
            Scene::of_text(&text, rect(40)).selecting(3..3),
        ),
        (
            "the cursor moved",
            Scene::of_text(&text, rect(40)).selecting(30..30),
        ),
    ];
    let mut any = 0;
    for (step, scene) in steps {
        let (laid, shaped) = counted(&mut layout, |layout| {
            let frame = layout.frame(&scene);
            assert!(!frame.views[0].rows.is_empty(), "{step}");
        });
        // Whatever layout says it shaped, the adapter built that many
        // Parley layouts and no more: none for a break, a reuse, a font's
        // metrics or a cursor.
        assert_eq!(shaped.layouts, laid, "{step}");
        any += shaped.layouts;
    }
    assert!(any > 0);
    // The queries go through the same entries.
    let scene = Scene::of_text(&text, rect(40));
    let shown = scene.views[0].text.clone().expect("a text");
    let (laid, shaped) = counted(&mut layout, |layout| {
        layout
            .rows_shown(&shown, 40.0, 100.0, Padding::default(), 0)
            .expect("rows");
        layout
            .lines_from(&shown, 300.0, 0, 0, 3, None)
            .expect("a move");
    });
    assert_eq!(shaped.layouts, laid);
}

#[test]
fn no_parley_layout_holds_a_whole_long_row() {
    // One row of four times the longest segment, with no tab, so that
    // what a shaper is handed is as long as the bytes of the row it is
    // cut from.
    let unit = "abcdefg xyz ";
    let row = unit.repeat(4 * SEGMENT_BYTES / unit.len());
    let mut scene = Scene::of_text(&row, rect(800));
    scene.views[0].rect.height = 400;
    scene.views[0].scroll = row.len() / 2;
    let mut layout = Layout::new(shaper());
    let (laid, shaped) = counted(&mut layout, |layout| {
        let frame = layout.frame(&scene);
        assert!(!frame.views[0].rows.is_empty());
    });
    assert!(laid > 0);
    assert_eq!(shaped.layouts, laid);
    // Each layout holds at most a segment, and all of them less than the
    // row.
    let segment = u64::try_from(SEGMENT_BYTES).expect("a length");
    assert!(shaped.bytes <= segment * laid, "{shaped:?}");
    assert!(shaped.bytes < u64::try_from(row.len()).expect("a length"));
}

#[test]
fn a_selection_across_latin_and_hebrew_covers_the_glyphs_of_what_is_selected() {
    // `abc`, a space, then four Hebrew letters of two bytes each, drawn
    // right to left. Bytes 2 to 8 are `c`, the space and the first two
    // Hebrew letters, which are the two rightmost glyphs of the line: what
    // is selected is not one stretch of the line.
    let selected = 2..8;
    let scene = Scene::of_text("abc שלום", rect(800)).selecting(selected.clone());
    let mut layout = Layout::new(shaper());
    let frame = layout.frame(&scene);
    let view = &frame.views[0];
    let glyphs = &view.rows[0].line.glyphs;
    let advances: f32 = glyphs
        .iter()
        .filter(|glyph| selected.contains(&glyph.cluster))
        .map(|glyph| glyph.advance)
        .sum();
    assert!(advances > 0.0);
    // Every area is wider than nothing, and together they are as wide as
    // the glyphs of the selected characters: no more and no less is
    // covered.
    assert!(!view.selections.is_empty());
    assert!(view.selections.iter().all(|area| area.width > 0.0));
    let covered: f32 = view.selections.iter().map(|area| area.width).sum();
    assert!((covered - advances).abs() < 0.01, "{covered} of {advances}");
}
