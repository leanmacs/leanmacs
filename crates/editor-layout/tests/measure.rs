//! Measuring a run ([`Layout::measure`]): how wide a text is laid out in
//! faces over the default face, unbroken, in whole points, which is what
//! a generator computes align-to stops from.
//!
//! The shaper is the fake: a glyph of the default family is 10 pixels
//! across at the base size, and one of the family `narrow` 7.

use editor_layout::Layout;
use editor_layout::face::{Color, Face, FaceDef};
use editor_layout::scene::Decoration;
use editor_layout::shaper::fake::CellShaper;

/// The fake, with the family `narrow`, and the faces `narrow` (its
/// family) and `red` (a foreground alone) defined.
fn layout_of(advance: f32) -> Layout<CellShaper> {
    let mut layout = Layout::new(CellShaper::new(advance, 16.0).with_family("narrow", 7.0, 16.0));
    layout.define(&[
        FaceDef {
            name: "narrow".to_owned(),
            face: Face {
                family: Some("narrow".to_owned()),
                ..Face::default()
            },
        },
        FaceDef {
            name: "red".to_owned(),
            face: Face {
                foreground: Some(Color::rgb(200, 0, 0)),
                ..Face::default()
            },
        },
    ]);
    layout
}

/// A decoration of `face` over the bytes `start` to `stop`.
fn decoration(start: usize, stop: usize, face: &str) -> Decoration {
    Decoration {
        start,
        stop,
        face: face.to_owned(),
    }
}

#[test]
fn an_empty_run_measures_nothing() {
    assert_eq!(layout_of(10.0).measure("", &[]), 0);
}

#[test]
fn a_run_measures_its_glyphs_in_the_fonts_its_faces_give() {
    let mut layout = layout_of(10.0);
    assert_eq!(layout.measure("abc", &[]), 30);
    assert_eq!(layout.measure("abc", &[decoration(0, 3, "narrow")]), 21);
    // Part of it in `narrow`.
    assert_eq!(layout.measure("abc", &[decoration(1, 3, "narrow")]), 24);
    // A face of paint alone measures as none.
    assert_eq!(layout.measure("abc", &[decoration(0, 3, "red")]), 30);
}

#[test]
fn a_run_measures_in_points_at_any_scale() {
    let mut layout = layout_of(10.0);
    layout.set_scale(2.0);
    // 60 pixels at scale 2.
    assert_eq!(layout.measure("abc", &[]), 30);
    assert_eq!(layout.measure("abc", &[decoration(0, 3, "narrow")]), 21);
}

#[test]
fn a_part_of_a_point_is_rounded_up() {
    // 22.5 pixels.
    assert_eq!(layout_of(7.5).measure("abc", &[]), 23);
    // At scale 1.5, `abc` is 45 pixels: 30 points, and float noise in
    // the division adds none.
    let mut layout = layout_of(10.0);
    layout.set_scale(1.5);
    assert_eq!(layout.measure("abc", &[]), 30);
}

#[test]
fn a_tab_reaches_its_stop_and_a_line_feed_ends_the_run() {
    let mut layout = layout_of(10.0);
    // Tabs 8 columns wide: `a`, seven spaces, `b`.
    assert_eq!(layout.measure("a\tb", &[]), 90);
    assert_eq!(layout.measure("ab\ncdef", &[]), 20);
    assert_eq!(layout.measure("ab\r\ncdef", &[]), 20);
}
