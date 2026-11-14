//! The bound on one very long row: laying out the rows around a position of
//! a row of N bytes costs the segments those rows touch, not N.
//!
//! The row is a mebibyte. A frame from its middle, the rows a view shows
//! from there, and moves of a few lines up and down from there are each
//! counted in bytes shaped by the fake ([`CellShaper::bytes_shaped`]), and
//! each must stay within two segments. A segment is at most
//! [`SEGMENT_BYTES`] of the buffer; the shaper is handed it with its tabs
//! expanded, up to the tab width times longer, so the row here has none.

use editor_layout::Layout;
use editor_layout::scene::{Cursor, Rect, Scene, TextKey, TextRef, View, ViewId};
use editor_layout::shaper::fake::CellShaper;
use editor_layout::tabs::SEGMENT_BYTES;
use editor_text::Text;

/// The most a call may shape.
const BOUND: usize = 2 * SEGMENT_BYTES;

/// A row of a mebibyte, of letters, spaces and characters of several
/// bytes, between two short rows. It has no tab: the fake counts the bytes
/// of the expanded text, and a tab widens its segment's.
fn long_text() -> TextRef {
    let unit = "abcdefg é😀xyz ";
    let row = unit.repeat((1 << 20) / unit.len());
    let text = format!("head\n{row}\ntail");
    TextRef::fixed(TextKey(1), Text::from(text.as_str()).snapshot())
}

/// A position near the middle of the long row.
fn middle(text: &TextRef) -> usize {
    let mut at = text.snapshot.len() / 2;
    while !text.snapshot.is_char_boundary(at) {
        at -= 1;
    }
    at
}

/// The bytes a fresh layout shapes while `run` runs on it.
fn shaped(run: impl FnOnce(&mut Layout<CellShaper>)) -> usize {
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    run(&mut layout);
    layout.shaper().bytes_shaped()
}

#[test]
fn a_frame_from_the_middle_of_a_long_row_shapes_at_most_two_segments() {
    let text = long_text();
    let anchor = middle(&text);
    let scene = Scene {
        views: vec![View {
            id: ViewId(1),
            rect: Rect {
                x: 0,
                y: 0,
                width: 800,
                height: 20 * 16,
            },
            text: Some(text.clone()),
            scroll: anchor,
            cursor: Cursor::default(),
            ..View::default()
        }],
        ..Scene::default()
    };
    let mut rows = 0;
    let bytes = shaped(|layout| rows = layout.frame(&scene).views[0].rows.len());
    assert_eq!(rows, 20);
    assert!(bytes <= BOUND, "{bytes} bytes shaped");
}

#[test]
fn the_rows_shown_from_the_middle_of_a_long_row_shape_at_most_two_segments() {
    let text = long_text();
    let anchor = middle(&text);
    let mut first = None;
    let bytes = shaped(|layout| {
        let rows = layout
            .rows_shown(&text, 800.0, 20.0 * 16.0, anchor)
            .unwrap();
        first = rows.first().copied();
    });
    let first = first.unwrap();
    assert!(first.start <= anchor && anchor < first.stop);
    assert!(bytes <= BOUND, "{bytes} bytes shaped");
}

#[test]
fn a_move_in_the_middle_of_a_long_row_shapes_at_most_two_segments() {
    let text = long_text();
    let anchor = middle(&text);
    for lines in [-3, -1, 1, 3] {
        let mut moved = None;
        let bytes = shaped(|layout| {
            moved = Some(
                layout
                    .lines_from(&text, 800.0, anchor, lines, None)
                    .unwrap(),
            );
        });
        let moved = moved.unwrap();
        assert_ne!(moved.position, anchor);
        assert!(bytes <= BOUND, "{lines} lines: {bytes} bytes shaped");
    }
}
