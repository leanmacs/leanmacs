//! Layout at a scale: a theme states its lengths in points, and layout
//! multiplies them by the scale it was last told
//! ([`Layout::set_scale`]) before it asks the shaper for a font. So the
//! same theme at scale 2 gives rows twice as tall and lines twice as wide
//! as at scale 1, in a frame whose rectangles are still physical pixels.
//!
//! Every test sets the scale on a layout that has already laid its scene
//! out at scale 1: a style or a base font kept from before the change
//! would show as a row that is the size it was.
//!
//! The shaper is the fake, whose geometry is exact and linear in a font's
//! size: every number here is a whole number of 64ths, so a length at a
//! scale is compared exactly.

use std::ops::Range;

use editor_layout::Layout;
use editor_layout::face::{Face, FaceDef};
use editor_layout::frame::{Area, Frame, ViewFrame};
use editor_layout::scene::{Decoration, Rect, Scene, StatusField, TextKey, TextRef, View, ViewId};
use editor_layout::shaper::fake::CellShaper;
use editor_layout::shaper::{Length, LineHeight};
use editor_text::{Selection, SelectionRange, Text};

/// The fake shaper: at the base size a glyph is 10 pixels across and a
/// line 16 down.
fn shaper() -> CellShaper {
    CellShaper::new(10.0, 16.0)
}

/// A face of the size `points` and nothing else.
fn sized(points: u32) -> Face {
    Face {
        size: Some(Length::pixels(points)),
        ..Face::default()
    }
}

/// A face of the line height `line_height` and nothing else.
fn lined(line_height: LineHeight) -> Face {
    Face {
        line_height: Some(line_height),
        ..Face::default()
    }
}

/// The theme: a default face of 14 points, `tall` with lines 20 points
/// down, `loose` with lines one and a half times its font's own, and `big`
/// of 21 points.
fn theme() -> Vec<FaceDef> {
    [
        ("default", sized(14)),
        ("tall", lined(LineHeight::Pixels(Length::pixels(20)))),
        ("loose", lined(LineHeight::Multiple(96))),
        ("big", sized(21)),
    ]
    .into_iter()
    .map(|(name, face)| FaceDef {
        name: name.to_owned(),
        face,
    })
    .collect()
}

/// The text of [`four_rows`]: each row but the first is named after the
/// face it is in.
const FOUR_ROWS: &str = "plain\ntall\nloose\nbig";

/// A scene of one view, `rect`, of `text` as text 1 in the theme, with no
/// selection, decoration or status field.
fn themed(text: &str, rect: Rect) -> Scene {
    Scene {
        views: vec![View {
            id: ViewId(1),
            rect,
            text: Some(TextRef::fixed(TextKey(1), Text::from(text).snapshot())),
            ..View::default()
        }],
        faces: Some(theme()),
        ..Scene::default()
    }
}

/// A scene of one view, `rect`, of four rows, each in one face of the
/// theme: the default face, `tall`, `loose` and `big`. It has a status
/// row, and a selection of the first row's bytes 1 to 3 with its cursor at
/// 3.
fn four_rows(rect: Rect) -> Scene {
    let decoration = |bytes: Range<usize>, face: &str| Decoration {
        start: bytes.start,
        stop: bytes.end,
        face: face.to_owned(),
    };
    let mut scene = themed(FOUR_ROWS, rect);
    let view = &mut scene.views[0];
    view.selections = vec![Selection::new(vec![SelectionRange::new(1, 3)], 0).unwrap()];
    view.decorations = vec![
        decoration(6..10, "tall"),
        decoration(11..16, "loose"),
        decoration(17..20, "big"),
    ];
    view.status = vec![StatusField {
        text: "status".to_owned(),
        face: "mode-line".to_owned(),
    }];
    scene
}

/// A rectangle at the frame's top left, `width` across and `height` down.
fn rect(width: u32, height: u32) -> Rect {
    Rect {
        x: 0,
        y: 0,
        width,
        height,
    }
}

/// The one view of `frame`.
fn view(frame: &Frame) -> &ViewFrame {
    assert_eq!(frame.views.len(), 1);
    &frame.views[0]
}

/// `area` with every length times `scale`.
fn area_at(area: Area, scale: f32) -> Area {
    Area {
        x: area.x * scale,
        y: area.y * scale,
        width: area.width * scale,
        height: area.height * scale,
    }
}

/// Requires `scaled` to be `one` with every length a theme decides times
/// `scale`: each row's height, baseline, `y` and width, each glyph's `x`
/// and advance, the status row's height, baseline and width, every
/// cursor's box and every selection's area; with the bytes of each row and
/// the view's rectangle what they were.
fn assert_scaled(one: &ViewFrame, scaled: &ViewFrame, scale: f32) {
    assert_eq!(scaled.rect, one.rect);
    assert_eq!(scaled.rows.len(), one.rows.len());
    for (index, (now, then)) in scaled.rows.iter().zip(&one.rows).enumerate() {
        assert_eq!(now.bytes, then.bytes, "row {index}");
        assert_eq!(now.height, then.height * scale, "row {index}");
        assert_eq!(now.baseline, then.baseline * scale, "row {index}");
        assert_eq!(now.y, then.y * scale, "row {index}");
        assert_eq!(now.line.width, then.line.width * scale, "row {index}");
        assert_eq!(now.line.glyphs.len(), then.line.glyphs.len(), "row {index}");
        for (glyph, was) in now.line.glyphs.iter().zip(&then.line.glyphs) {
            assert_eq!(glyph.id, was.id, "row {index}");
            assert_eq!(glyph.x, was.x * scale, "row {index}");
            assert_eq!(glyph.advance, was.advance * scale, "row {index}");
        }
    }
    match (&scaled.status, &one.status) {
        (Some(now), Some(then)) => {
            assert_eq!(now.height, then.height * scale);
            assert_eq!(now.baseline, then.baseline * scale);
            assert_eq!(now.line.width, then.line.width * scale);
            // It is at the bottom of the rectangle, which is as tall as it
            // was.
            assert_eq!(now.y, one.rect.height as f32 - now.height);
        }
        (None, None) => {}
        (now, then) => panic!("a status row in one frame only: {now:?} and {then:?}"),
    }
    assert_eq!(scaled.cursors.len(), one.cursors.len());
    for (now, then) in scaled.cursors.iter().zip(&one.cursors) {
        assert_eq!(now.area, area_at(then.area, scale));
    }
    assert_eq!(
        scaled.selections,
        one.selections
            .iter()
            .map(|area| area_at(*area, scale))
            .collect::<Vec<_>>()
    );
}

/// The bytes of each row of the one view of `frame`.
fn row_bytes(frame: &Frame) -> Vec<Range<usize>> {
    view(frame)
        .rows
        .iter()
        .map(|row| row.bytes.clone())
        .collect()
}

#[test]
fn the_same_theme_at_scale_two_gives_rows_twice_as_tall_and_lines_twice_as_wide() {
    // Wide enough that nothing wraps and tall enough for every row at
    // either scale.
    let scene = four_rows(rect(400, 200));
    let mut layout = Layout::new(shaper());
    let one = layout.frame(&scene);
    // What the theme comes to at scale 1, on the fake: a glyph of the
    // default face 8.75 across, and rows 14, 20, 21 and 21 down.
    let heights =
        |frame: &Frame| -> Vec<f32> { view(frame).rows.iter().map(|row| row.height).collect() };
    assert_eq!(heights(&one), [14.0, 20.0, 21.0, 21.0]);
    assert_eq!(view(&one).rows[0].line.width, 5.0 * 8.75);
    assert_eq!(view(&one).cursors.len(), 1);
    assert_eq!(view(&one).selections.len(), 1);
    assert!(view(&one).status.is_some());

    layout.set_scale(2.0);
    let two = layout.frame(&scene);
    assert_eq!(heights(&two), [28.0, 40.0, 42.0, 42.0]);
    assert_eq!(view(&two).rows[0].line.width, 5.0 * 17.5);
    assert_scaled(view(&one), view(&two), 2.0);
}

#[test]
fn a_view_twice_as_large_at_scale_two_breaks_its_rows_where_scale_one_does() {
    let text = "the quick brown fox jumps over the lazy dog";
    let mut layout = Layout::new(shaper());
    // Eight glyphs of 8.75 fit 75 pixels, and five rows of 14 fit 70.
    let one = layout.frame(&themed(text, rect(75, 70)));
    assert_eq!(
        row_bytes(&one),
        [0..8, 8..16, 16..24, 24..32, 32..40],
        "the text wraps"
    );
    layout.set_scale(2.0);
    let two = layout.frame(&themed(text, rect(150, 140)));
    assert_eq!(row_bytes(&two), row_bytes(&one));
}

#[test]
fn a_view_of_the_same_size_at_scale_two_shows_half_as_many_rows() {
    let text = (0..20)
        .map(|row| format!("row{row}"))
        .collect::<Vec<_>>()
        .join("\n");
    // Eight rows of 14 pixels.
    let scene = themed(&text, rect(400, 112));
    let mut layout = Layout::new(shaper());
    assert_eq!(view(&layout.frame(&scene)).rows.len(), 8);
    layout.set_scale(2.0);
    assert_eq!(view(&layout.frame(&scene)).rows.len(), 4);
}

#[test]
fn a_fractional_scale_scales_every_length_by_it() {
    let scene = four_rows(rect(400, 200));
    let mut layout = Layout::new(shaper());
    let one = layout.frame(&scene);
    layout.set_scale(1.5);
    let scaled = layout.frame(&scene);
    // A row of 14 points is 21 pixels down, and its five glyphs of 8.75
    // are 13.125 each.
    assert_eq!(view(&scaled).rows[0].height, 21.0);
    assert_eq!(view(&scaled).rows[0].line.width, 5.0 * 13.125);
    assert_scaled(view(&one), view(&scaled), 1.5);
}

#[test]
fn at_scale_one_a_frame_is_the_frame_of_a_layout_never_told_a_scale() {
    let scene = four_rows(rect(400, 200));
    let mut never = Layout::new(shaper());
    never.frame(&scene);
    let expected = never.frame(&scene);

    let mut told = Layout::new(shaper());
    assert_eq!(told.scale(), 1.0);
    told.frame(&scene);
    told.set_scale(1.0);
    assert_eq!(told.frame(&scene), expected);
    // Nothing was laid out again for it.
    assert_eq!(told.counters(), never.counters());
    assert_eq!(told.shaper().bytes_shaped(), never.shaper().bytes_shaped());

    // Away and back, the views are what they were: a font's id is its
    // shaper's for a spec, and the specs at 1 are the ones it had.
    told.set_scale(2.0);
    assert_eq!(told.scale(), 2.0);
    assert_ne!(told.frame(&scene).views, expected.views);
    told.set_scale(1.0);
    assert_eq!(told.frame(&scene).views, expected.views);
}

#[test]
fn the_queries_answer_at_the_scale_last_set() {
    let rows = (0..20)
        .map(|row| format!("row{row}"))
        .collect::<Vec<_>>()
        .join("\n");
    let mut layout = Layout::new(shaper());
    // The theme reaches a layout with a scene: this one shows the text in
    // a view too short for any row of it.
    layout.frame(&themed(&rows, rect(400, 1)));
    let text = TextRef::fixed(TextKey(1), Text::from(rows.as_str()).snapshot());
    // A text nothing has laid out: every row of it is an estimate.
    let other = TextRef::fixed(TextKey(2), Text::from("a\nb\nc").snapshot());
    assert_eq!(layout.rows_shown(&text, 400.0, 112.0, 0).unwrap().len(), 8);
    assert_eq!(layout.height_estimate(&other, 400.0), 3.0 * 14.0);
    // No frame between the change and the queries.
    layout.set_scale(2.0);
    assert_eq!(layout.rows_shown(&text, 400.0, 112.0, 0).unwrap().len(), 4);
    assert_eq!(layout.height_estimate(&other, 400.0), 3.0 * 28.0);
}

#[test]
fn the_vertical_padding_is_points() {
    // A mode line padded 3 points, under no other face: at scale 1 its
    // row is 16 + 2 × 3, and at scale 2 it is 32 + 2 × 6.
    let mut layout = Layout::new(shaper());
    layout.define(&[FaceDef {
        name: "mode-line".to_owned(),
        face: Face {
            vertical_padding: Some(Length::pixels(3)),
            ..Face::default()
        },
    }]);
    assert_eq!(layout.heights().status, 22);
    layout.set_scale(2.0);
    assert_eq!(layout.heights().status, 32 + 12);
    assert_eq!(layout.heights().message, 32 + 12);
    assert_eq!(layout.heights().text, 32);
}
