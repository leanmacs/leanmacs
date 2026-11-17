//! Where a position is drawn in a view ([`Layout::spot`]): the x of its
//! left edge and the y of the top of the row that holds it, both from the
//! view's own top left, padding included, and that row's height. It is
//! the walk the rows query takes, so a position it does not show has no
//! spot, and the padding is taken off at the layout's scale as the frame
//! takes it off.
//!
//! The shaper is the fake, at 10 pixels across and 16 down at the base
//! size, so every number here is worked by hand.

use std::sync::Arc;

use editor_layout::Layout;
use editor_layout::face::{Face, FaceDef};
use editor_layout::query::{QueryError, Spot};
use editor_layout::scene::{FixedSpans, Padding, TextKey, TextRef};
use editor_layout::shaper::Length;
use editor_layout::shaper::fake::CellShaper;
use editor_text::Text;

/// A layout on the fake at `scale`.
fn layout_at(scale: f32) -> Layout<CellShaper> {
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    layout.set_scale(scale);
    layout
}

/// `text`, as text 1.
fn text_of(text: &str) -> TextRef {
    TextRef::fixed(TextKey(1), Text::from(text).snapshot())
}

/// The spot of `position` in a view 200 by 160 of `text`, with `padding`,
/// from `anchor`.
fn spot(
    layout: &mut Layout<CellShaper>,
    text: &TextRef,
    padding: Padding,
    anchor: usize,
    position: usize,
) -> Result<Option<Spot>, QueryError> {
    layout.spot(text, 200.0, 160.0, padding, anchor, position)
}

#[test]
fn a_position_is_at_its_column_on_its_row_counted_from_the_anchor() {
    let text = text_of("ab\ncd\nefgh\nij");
    let mut layout = layout_at(1.0);
    // `h`, the fourth column of the third row shown.
    assert_eq!(
        spot(&mut layout, &text, Padding::default(), 0, 9),
        Ok(Some(Spot {
            x: 30.0,
            y: 32.0,
            height: 16.0
        }))
    );
    // From the second row on, it is on the second row shown.
    assert_eq!(
        spot(&mut layout, &text, Padding::default(), 3, 9),
        Ok(Some(Spot {
            x: 30.0,
            y: 16.0,
            height: 16.0
        }))
    );
}

#[test]
fn the_padding_is_taken_off_at_the_layouts_scale() {
    let text = text_of("ab\ncd\nefgh\nij");
    let mut layout = layout_at(2.0);
    // A view 400 by 400, which holds the rows at scale 2 with the padding.
    let mut spot = |padding| {
        layout
            .spot(&text, 400.0, 400.0, padding, 0, 9)
            .unwrap()
            .unwrap()
    };
    let bare = spot(Padding::default());
    let moved = spot(Padding {
        across: 8,
        down: 8,
        top: 32,
    });
    // 8 points across and 8 + 32 down, each at scale 2.
    assert_eq!(moved.x, bare.x + 16.0);
    assert_eq!(moved.y, bare.y + 80.0);
    assert_eq!(moved.height, bare.height);
    // The rows themselves are at the scale: two rows of 32 above `h`.
    assert_eq!(bare.y, 64.0);
}

#[test]
fn a_taller_row_pushes_the_rows_after_it_down_by_its_own_height() {
    // The second row is in `big`, twice the base size: 32 tall.
    let spans = FixedSpans::new(&["big"], vec![(3..5, 0)]);
    let text = text_of("ab\ncd\nefgh\nij").with_spans(Arc::new(spans));
    let mut layout = layout_at(1.0);
    layout.define(&[FaceDef {
        name: "big".to_owned(),
        face: Face {
            size: Some(Length::pixels(32)),
            ..Face::default()
        },
    }]);
    assert_eq!(
        spot(&mut layout, &text, Padding::default(), 0, 4),
        Ok(Some(Spot {
            x: 20.0,
            y: 16.0,
            height: 32.0
        }))
    );
    assert_eq!(
        spot(&mut layout, &text, Padding::default(), 0, 9),
        Ok(Some(Spot {
            x: 30.0,
            y: 48.0,
            height: 16.0
        }))
    );
}

#[test]
fn a_position_the_view_does_not_show_has_no_spot() {
    // Twenty rows: a view 160 tall shows ten of them.
    let text: String = (0..20).map(|row| format!("{row:02}\n")).collect();
    let text = text_of(&text);
    let mut layout = layout_at(1.0);
    // Before the anchor.
    assert_eq!(spot(&mut layout, &text, Padding::default(), 6, 3), Ok(None));
    // The last row that fits, and the first past it.
    assert!(matches!(
        spot(&mut layout, &text, Padding::default(), 0, 27),
        Ok(Some(_))
    ));
    assert_eq!(
        spot(&mut layout, &text, Padding::default(), 0, 30),
        Ok(None)
    );
}

#[test]
fn an_offset_that_is_not_a_position_is_refused() {
    let text = text_of("é\nab");
    let mut layout = layout_at(1.0);
    assert_eq!(
        spot(&mut layout, &text, Padding::default(), 0, 1),
        Err(QueryError::BadPosition)
    );
    assert_eq!(
        spot(&mut layout, &text, Padding::default(), 1, 0),
        Err(QueryError::BadPosition)
    );
}
