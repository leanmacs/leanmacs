//! The painter's tests: on the fake rasteriser, with no font and no GPU.
//!
//! The frames are of two sorts. Where a test is about a number of the
//! frame (a glyph's offset, a row's height, a cursor's area), the frame is
//! built by hand from the frame's public data, so the number is the one
//! the test states. Where it is about what a whole view comes to, the
//! frame is laid out on layout's fake shaper, and what is expected is
//! read from that frame's own numbers.

use std::ops::Range;
use std::sync::Arc;

use editor_layout::Layout;
use editor_layout::face::{Color, Face, FaceDef, Paint, Underline, UnderlineStyle};
use editor_layout::frame::{Area, CursorBox, Frame, FrameRow, ViewFrame};
use editor_layout::scene::{
    Cursor, CursorShape, Decoration, Rect, Scene, Side, StatusField, ViewId,
};
use editor_layout::shaper::fake::CellShaper;
use editor_layout::shaper::{Glyph, ResolvedFontId, VisualLine};
use editor_render::port::Target;

use super::{Painter, thickness};
use crate::glyphs::fake::{FakeRasterizer, font};
use crate::glyphs::{GlyphKey, bin_of};
use crate::quads::{Quad, QuadKind};
use crate::{Antialiasing, Masks, Settings, SubpixelOrder};

/// The page size of the painters here.
const PAGE: u32 = 64;

const WHITE: Color = Color::rgb(0xff, 0xff, 0xff);
const BLACK: Color = Color::rgb(0, 0, 0);
const RED: Color = Color::rgb(0xff, 0, 0);
const GREEN: Color = Color::rgb(0, 0xff, 0);
const BLUE: Color = Color::rgb(0, 0, 0xff);
const YELLOW: Color = Color::rgb(0xff, 0xff, 0);
const GREY: Color = Color::rgb(0x80, 0x80, 0x80);

/// The width and the height of every image of the fake rasteriser.
const GLYPH: (u32, u32) = (FakeRasterizer::WIDTH, FakeRasterizer::HEIGHT);

/// Settings that hint, antialias as `antialiasing` says, and give the
/// atlas `budget` bytes.
fn settings(antialiasing: Antialiasing, budget: u64) -> Settings {
    Settings {
        antialiasing,
        hinting: true,
        atlas_budget: budget,
        ..Settings::default()
    }
}

/// A painter over the fake rasteriser, antialiasing as `antialiasing`
/// says for a device that blends by a coverage for each channel, with an
/// atlas that never fills.
fn painter_with(antialiasing: Antialiasing) -> Painter<FakeRasterizer> {
    Painter::new(
        FakeRasterizer::new(),
        &settings(antialiasing, u64::MAX),
        true,
        PAGE,
    )
}

/// A painter over the fake rasteriser that asks for plain masks, with an
/// atlas of pages `page` pixels across and down and one page of masks
/// for its budget.
fn tight(page: u32) -> Painter<FakeRasterizer> {
    let budget = u64::from(page * page);
    Painter::new(
        FakeRasterizer::new(),
        &settings(Antialiasing::Grayscale, budget),
        true,
        page,
    )
}

/// A painter over `rasterizer` that asks for plain masks, with an atlas
/// that never fills.
fn painter_over(rasterizer: FakeRasterizer) -> Painter<FakeRasterizer> {
    Painter::new(
        rasterizer,
        &settings(Antialiasing::Grayscale, u64::MAX),
        true,
        PAGE,
    )
}

/// A painter over the fake rasteriser as it comes.
fn painter() -> Painter<FakeRasterizer> {
    painter_over(FakeRasterizer::new())
}

/// A target of 400 by 300 pixels at `scale`.
fn target(scale: f32) -> Target {
    Target {
        width: 400,
        height: 300,
        scale,
    }
}

/// The glyph `id` of font 0 at `x`, ten pixels across, drawn at its pen
/// position; its cluster is `cluster`.
fn glyph(id: u32, cluster: usize, x: f32) -> Glyph {
    Glyph {
        id,
        font: ResolvedFontId(0),
        cluster,
        x,
        dx: 0.0,
        dy: 0.0,
        advance: 10.0,
    }
}

/// A row at `y`, 16 pixels down with its baseline at 12, of `glyphs`
/// painted by `runs`, with the content hash `hash`.
fn row(y: f32, glyphs: Vec<Glyph>, runs: Vec<(Range<usize>, Paint)>, hash: u64) -> FrameRow {
    let bytes = 0..glyphs.len();
    let width = glyphs.last().map_or(0.0, |last| last.x + last.advance);
    FrameRow {
        x: 0.0,
        y,
        height: 16.0,
        baseline: 12.0,
        bytes: bytes.clone(),
        line: Arc::new(VisualLine {
            bytes,
            glyphs,
            width,
            height: 16.0,
            baseline: 12.0,
        }),
        runs,
        hash,
    }
}

/// A row at `y` of the glyphs `ids`, ten pixels apart, in the base paint.
fn plain_row(y: f32, ids: &[u32], hash: u64) -> FrameRow {
    let glyphs = ids
        .iter()
        .enumerate()
        .map(|(index, id)| glyph(*id, index, index as f32 * 10.0))
        .collect();
    row(y, glyphs, vec![(0..ids.len(), Paint::default())], hash)
}

/// A view at the target's top left, 200 by 100, of `rows`: white behind,
/// blue selections, no status row and no cursor.
fn view(rows: Vec<FrameRow>) -> ViewFrame {
    ViewFrame {
        id: ViewId(1),
        rect: Rect {
            x: 0,
            y: 0,
            width: 200,
            height: 100,
        },
        background: WHITE,
        rows,
        status: None,
        cursors: Vec::new(),
        selections: Vec::new(),
        selection: BLUE,
    }
}

/// The frame of `views`, of generation 0, whose font 0 is 16 pixels.
fn frame(views: Vec<ViewFrame>) -> Frame {
    Frame {
        views,
        generation: 0,
        fonts: Arc::from(vec![font(16.0)]),
    }
}

/// The frame of one view of `rows`.
fn frame_of(rows: Vec<FrameRow>) -> Frame {
    frame(vec![view(rows)])
}

/// The quads of `painter` of `kind` and `color`.
fn quads_of(painter: &Painter<FakeRasterizer>, kind: QuadKind, color: Color) -> Vec<Quad> {
    painter
        .quads()
        .iter()
        .filter(|quad| quad.kind == kind && quad.color == color)
        .copied()
        .collect()
}

/// Where each of `quads` is and how large: left, top, width, height.
fn boxes(quads: &[Quad]) -> Vec<(i32, i32, u32, u32)> {
    quads
        .iter()
        .map(|quad| (quad.x, quad.y, quad.width, quad.height))
        .collect()
}

/// The fills of `color` among the quads of `painter`, as boxes.
fn fills(painter: &Painter<FakeRasterizer>, color: Color) -> Vec<(i32, i32, u32, u32)> {
    boxes(&quads_of(painter, QuadKind::Fill, color))
}

/// The base paint with `foreground`.
fn ink(foreground: Color) -> Paint {
    Paint {
        foreground,
        ..Paint::default()
    }
}

#[test]
fn a_glyphs_quad_is_at_the_frames_own_x_plus_dx_and_baseline_plus_dy() {
    // Three glyphs of a row 16 pixels down a view at 20, 30. The first is
    // drawn 3 pixels right of its pen position and 2 above the baseline,
    // the second at its pen position, the third 4.5 pixels left of it and
    // 5 below.
    let glyphs = vec![
        Glyph {
            dx: 3.0,
            dy: -2.0,
            ..glyph(7, 0, 10.0)
        },
        glyph(8, 1, 20.0),
        Glyph {
            dx: -4.5,
            dy: 5.0,
            ..glyph(9, 2, 30.0)
        },
    ];
    let mut shown = view(vec![row(16.0, glyphs, vec![(0..3, ink(RED))], 1)]);
    shown.rect = Rect {
        x: 20,
        y: 30,
        width: 200,
        height: 100,
    };
    let mut painter = painter();
    painter.paint(&frame(vec![shown]), target(1.0));
    // An image's left edge is at the glyph's place and its top its own
    // height above the baseline (the fake rasteriser's placement). The
    // row's top is at 30 + 16 and its baseline 12 below that.
    let top = |baseline: i32| 30 + 16 + baseline - GLYPH.1 as i32;
    assert_eq!(
        boxes(&quads_of(&painter, QuadKind::Mask, RED)),
        vec![
            (20 + 13, top(10), GLYPH.0, GLYPH.1),
            (20 + 20, top(12), GLYPH.0, GLYPH.1),
            // 25.5 across: the pixel 25, and the image of its second
            // quarter.
            (20 + 25, top(17), GLYPH.0, GLYPH.1),
        ]
    );
    let bins: Vec<u8> = painter
        .rasterizer()
        .asked
        .iter()
        .map(|(key, _, _)| key.bin)
        .collect();
    assert_eq!(bins, vec![0, 0, 2]);
}

#[test]
fn a_glyph_is_drawn_from_the_image_of_its_fractions_bin() {
    // Cells 10.25 pixels across: each glyph is a quarter of a pixel
    // further into its pixel than the one before.
    let rect = Rect {
        x: 0,
        y: 0,
        width: 200,
        height: 100,
    };
    let laid = Layout::new(CellShaper::new(10.25, 16.0)).frame(&Scene::of_text("abcde", rect));
    let glyphs = &laid.views[0].rows[0].line.glyphs;
    let places: Vec<(i32, u8)> = glyphs
        .iter()
        .map(|glyph| bin_of(glyph.x + glyph.dx))
        .collect();
    assert!(places.iter().any(|(_, bin)| *bin != 0), "{places:?}");
    let mut painter = painter();
    painter.paint(&laid, target(1.0));
    let asked: Vec<(u32, u8)> = painter
        .rasterizer()
        .asked
        .iter()
        .map(|(key, _, _)| (key.glyph, key.bin))
        .collect();
    let expected: Vec<(u32, u8)> = glyphs
        .iter()
        .zip(&places)
        .map(|(glyph, (_, bin))| (glyph.id, *bin))
        .collect();
    assert_eq!(asked, expected);
    let lefts: Vec<i32> = quads_of(&painter, QuadKind::Mask, BLACK)
        .iter()
        .map(|quad| quad.x)
        .collect();
    let wholes: Vec<i32> = places.iter().map(|(whole, _)| *whole).collect();
    assert_eq!(lefts, wholes);
}

/// The faces of the view the order test lays out.
fn theme() -> Vec<FaceDef> {
    let named = |name: &str, face: Face| FaceDef {
        name: name.to_owned(),
        face,
    };
    vec![
        named(
            "mark",
            Face {
                background: Some(YELLOW),
                underline: Some(Underline {
                    style: UnderlineStyle::Single,
                    color: Some(RED),
                }),
                strike_through: Some(true),
                ..Face::default()
            },
        ),
        named(
            "selection",
            Face {
                background: Some(BLUE),
                ..Face::default()
            },
        ),
        named(
            "mode-line",
            Face {
                background: Some(GREY),
                ..Face::default()
            },
        ),
        named(
            "cursor",
            Face {
                foreground: Some(WHITE),
                background: Some(GREEN),
                ..Face::default()
            },
        ),
    ]
}

/// The scene of one view of `ab cd` and `ef`: `ab` marked, `cd` selected
/// with a block cursor on the `c`, and a status row.
fn dressed_scene() -> Scene {
    let rect = Rect {
        x: 0,
        y: 0,
        width: 200,
        height: 64,
    };
    // The selection is from its anchor after the `d` back to its head on
    // the `c`, where the cursor is.
    let (anchor, head) = (5, 3);
    let mut scene = Scene::of_text("ab cd\nef", rect).selecting(anchor..head);
    scene.faces = Some(theme());
    let shown = &mut scene.views[0];
    shown.decorations = vec![Decoration {
        start: 0,
        stop: 2,
        face: "mark".to_owned(),
    }];
    shown.cursor = Cursor {
        shape: CursorShape::Block,
        face: "cursor".to_owned(),
    };
    shown.status = vec![StatusField {
        text: "st".to_owned(),
        face: "mode-line".to_owned(),
        ..StatusField::default()
    }];
    scene
}

/// The frame of [`dressed_scene`], laid out on the fake shaper.
fn dressed() -> Frame {
    Layout::new(CellShaper::new(10.0, 16.0)).frame(&dressed_scene())
}

#[test]
fn a_view_is_drawn_back_to_front() {
    let laid = dressed();
    let mut painter = painter();
    painter.paint(&laid, target(1.0));
    // What each quad is and its colour, with a run of the same counted
    // once.
    let mut order: Vec<(QuadKind, Color)> = painter
        .quads()
        .iter()
        .map(|quad| (quad.kind, quad.color))
        .collect();
    order.dedup();
    assert_eq!(
        order,
        vec![
            // The view's background.
            (QuadKind::Fill, WHITE),
            // The backgrounds of the runs that are not white: the marked
            // one, then the selected one; and the selection's area.
            (QuadKind::Fill, YELLOW),
            (QuadKind::Fill, BLUE),
            // The glyphs of the text rows.
            (QuadKind::Mask, BLACK),
            // The marked run's underline and its strike-through.
            (QuadKind::Fill, RED),
            (QuadKind::Fill, BLACK),
            // The status row: its background, then its glyphs.
            (QuadKind::Fill, GREY),
            (QuadKind::Mask, BLACK),
            // The cursor, and the glyph under it again in its foreground.
            (QuadKind::Fill, GREEN),
            (QuadKind::Mask, WHITE),
        ]
    );
    // The blue is drawn twice over the selected glyphs: the run's
    // background, and the selection's area as the frame gives it.
    let shown = &laid.views[0];
    let blues = fills(&painter, BLUE);
    assert_eq!(blues.len(), 1 + shown.selections.len());
    let area = shown.selections[0];
    let expected = Quad::over(area.x, area.y, area.width, area.height, BLUE);
    assert_eq!(blues.last(), boxes(&[expected]).last());
    // The status row's background is the view's width, where the frame
    // puts the row.
    let status = shown.status.as_ref().expect("a status row");
    let behind = Quad::over(0.0, status.y, 200.0, status.height, GREY);
    assert_eq!(fills(&painter, GREY), boxes(&[behind]));
    // And every glyph of the frame has its quad, once: those of the text
    // rows and of the status row in black.
    let glyphs: usize = shown.rows.iter().map(|row| row.line.glyphs.len()).sum();
    let drawn = quads_of(&painter, QuadKind::Mask, BLACK).len();
    assert_eq!(drawn, glyphs + status.line.glyphs.len());
}

#[test]
fn a_status_rows_boxes_are_filled_in_their_colour() {
    let rect = Rect {
        x: 0,
        y: 0,
        width: 200,
        height: 64,
    };
    let mut scene = Scene::of_text("ab", rect);
    let mut faces = theme();
    faces.push(FaceDef {
        name: "badge".to_owned(),
        face: Face {
            background: Some(GREEN),
            ..Face::default()
        },
    });
    scene.faces = Some(faces);
    // A badge padded 3 on the left, in a colour unlike the row's, and a
    // field padded 2 on the right in the row's own.
    scene.views[0].status = vec![
        StatusField {
            text: "ab".to_owned(),
            face: "badge".to_owned(),
            side: Side::Left,
            padding: 3,
        },
        StatusField {
            text: "c".to_owned(),
            face: "mode-line".to_owned(),
            side: Side::Right,
            padding: 2,
        },
    ];
    let laid = Layout::new(CellShaper::new(10.0, 16.0)).frame(&scene);
    let status = laid.views[0].status.as_ref().expect("a status row");
    let mut painter = painter();
    painter.paint(&laid, target(1.0));
    // The badge's box, its padding and its text, across exactly the box
    // and down the row; then its run's background over its glyphs.
    let badge = status.boxes[0];
    assert_eq!((badge.x, badge.width, badge.background), (0.0, 26.0, GREEN));
    let y = status.y as i32;
    assert_eq!(fills(&painter, GREEN), vec![(0, y, 26, 16), (3, y, 20, 16)]);
    // The field in the row's colour adds nothing to the row's background.
    assert_eq!(status.boxes[1].background, GREY);
    assert_eq!(fills(&painter, GREY), vec![(0, y, 200, 16)]);
}

/// Where the second view of [`side_by_side`] is.
const SECOND: (i32, i32) = (150, 90);

/// Two views of the dressed scene's one, with a marked field more in its
/// status row, each cut to 45 pixels across so that its last glyph, its
/// selection and its status row reach past its right edge: the first at
/// the target's top left, the second at [`SECOND`].
fn side_by_side() -> Frame {
    let mut scene = dressed_scene();
    scene.views[0].status.push(StatusField {
        text: "!".to_owned(),
        face: "mark".to_owned(),
        ..StatusField::default()
    });
    let laid = Layout::new(CellShaper::new(10.0, 16.0)).frame(&scene);
    let mut first = laid.views[0].clone();
    first.rect.width = 45;
    let mut second = first.clone();
    second.id = ViewId(2);
    second.rect.x = SECOND.0 as u32;
    second.rect.y = SECOND.1 as u32;
    Frame {
        views: vec![first, second],
        ..laid
    }
}

#[test]
fn every_view_of_a_frame_is_drawn_from_its_own_top_left() {
    let both = side_by_side();
    // The first view alone: what a view at the target's top left comes
    // to, which the tests of one view pin.
    let alone = Frame {
        views: vec![both.views[0].clone()],
        ..both.clone()
    };
    let mut one = painter();
    one.paint(&alone, target(1.0));
    let mut two = painter();
    two.paint(&both, target(1.0));
    // Each thing a view draws is drawn twice: as the first view draws it,
    // and then the same moved to where the second view is.
    let twice = |quads: &[Quad]| -> Vec<Quad> {
        let moved = quads.iter().map(|quad| quad.moved(SECOND.0, SECOND.1));
        quads.iter().copied().chain(moved).collect()
    };
    // The marked runs are one of the text and one of the status row, so
    // each of their parts is two quads a view; their backgrounds are three,
    // with the marked status field's box, under its run's.
    let parts = [
        ("the view's background", QuadKind::Fill, WHITE, 1),
        (
            "the marked runs' backgrounds and the marked field's box",
            QuadKind::Fill,
            YELLOW,
            3,
        ),
        (
            "the selected run's background and the selection's area",
            QuadKind::Fill,
            BLUE,
            2,
        ),
        ("the underlines", QuadKind::Fill, RED, 2),
        ("the strike-throughs", QuadKind::Fill, BLACK, 2),
        ("the status row's background", QuadKind::Fill, GREY, 1),
        ("the cursor's cell", QuadKind::Fill, GREEN, 1),
        ("the glyph under the cursor", QuadKind::Mask, WHITE, 1),
    ];
    for (part, kind, color, count) in parts {
        let first = quads_of(&one, kind, color);
        assert_eq!(first.len(), count, "{part}");
        assert_eq!(quads_of(&two, kind, color), twice(&first), "{part}");
    }
    // The glyphs of the text rows, and those of the status row.
    let glyphs = quads_of(&one, QuadKind::Mask, BLACK);
    assert!(glyphs.len() > 3);
    assert_eq!(quads_of(&two, QuadKind::Mask, BLACK), twice(&glyphs));
    // And the views are drawn one after the other, each whole.
    assert_eq!(two.quads(), twice(one.quads()));
}

#[test]
fn text_in_the_views_own_background_draws_no_background_of_its_own() {
    let mut painter = painter();
    painter.paint(&frame_of(vec![plain_row(0.0, &[1, 2, 3], 1)]), target(1.0));
    let kinds: Vec<QuadKind> = painter.quads().iter().map(|quad| quad.kind).collect();
    assert_eq!(
        kinds,
        vec![
            QuadKind::Fill,
            QuadKind::Mask,
            QuadKind::Mask,
            QuadKind::Mask
        ]
    );
    assert_eq!(fills(&painter, WHITE), vec![(0, 0, 200, 100)]);
}

#[test]
fn the_backgrounds_of_rows_of_broken_heights_meet_with_no_gap() {
    // Two rows 16.5 pixels down each, on yellow.
    let on_yellow = Paint {
        background: YELLOW,
        ..Paint::default()
    };
    let tall = |y: f32, hash: u64| FrameRow {
        height: 16.5,
        ..row(y, vec![glyph(1, 0, 0.0)], vec![(0..1, on_yellow)], hash)
    };
    let mut painter = painter();
    painter.paint(&frame_of(vec![tall(0.0, 1), tall(16.5, 2)]), target(1.0));
    // The first is from 0 to 17 (16.5 rounded) and the second from there
    // to 33.
    assert_eq!(
        fills(&painter, YELLOW),
        vec![(0, 0, 10, 17), (0, 17, 10, 16)]
    );
}

/// The underline quads of a row of two glyphs, from 0 to 20 across with
/// its baseline at 12, underlined in `style`, at `scale`.
fn underlined(style: UnderlineStyle, scale: f32) -> Vec<(i32, i32, u32, u32)> {
    let paint = Paint {
        underline: Some((style, RED)),
        ..Paint::default()
    };
    let glyphs = vec![glyph(1, 0, 0.0), glyph(2, 1, 10.0)];
    let mut painter = painter();
    painter.paint(
        &frame_of(vec![row(0.0, glyphs, vec![(0..2, paint)], 1)]),
        target(scale),
    );
    fills(&painter, RED)
}

#[test]
fn an_underline_is_drawn_in_its_style_below_the_baseline() {
    assert_eq!(
        underlined(UnderlineStyle::Single, 1.0),
        vec![(0, 13, 20, 1)]
    );
    assert_eq!(
        underlined(UnderlineStyle::Double, 1.0),
        vec![(0, 13, 20, 1), (0, 15, 20, 1)]
    );
    // Dots: every other pixel.
    let dots: Vec<(i32, i32, u32, u32)> = (0..10).map(|dot| (dot * 2, 13, 1, 1)).collect();
    assert_eq!(underlined(UnderlineStyle::Dotted, 1.0), dots);
    // Dashes: three pixels on and three off, the last cut at the run's
    // end.
    assert_eq!(
        underlined(UnderlineStyle::Dashed, 1.0),
        vec![(0, 13, 3, 1), (6, 13, 3, 1), (12, 13, 3, 1), (18, 13, 2, 1)]
    );
    // Curly: steps two pixels across, one up and one down.
    let steps: Vec<(i32, i32, u32, u32)> = (0..10)
        .map(|step| (step * 2, 13 + step % 2, 2, 1))
        .collect();
    assert_eq!(underlined(UnderlineStyle::Curly, 1.0), steps);
}

#[test]
fn a_line_the_painter_sizes_is_as_thick_as_the_scale() {
    assert_eq!(
        [
            thickness(1.0),
            thickness(1.25),
            thickness(1.5),
            thickness(2.0),
            thickness(3.0),
            thickness(0.5)
        ],
        [1, 1, 2, 2, 3, 1]
    );
    // At scale 2 an underline is two pixels thick, two below the
    // baseline, and its pattern twice as long.
    assert_eq!(
        underlined(UnderlineStyle::Single, 2.0),
        vec![(0, 14, 20, 2)]
    );
    assert_eq!(
        underlined(UnderlineStyle::Double, 2.0),
        vec![(0, 14, 20, 2), (0, 18, 20, 2)]
    );
    let dots: Vec<(i32, i32, u32, u32)> = (0..5).map(|dot| (dot * 4, 14, 2, 2)).collect();
    assert_eq!(underlined(UnderlineStyle::Dotted, 2.0), dots);
}

#[test]
fn a_strike_through_is_drawn_through_the_glyphs_in_their_colour() {
    let paint = Paint {
        strike_through: true,
        ..ink(RED)
    };
    let glyphs = vec![glyph(1, 0, 0.0), glyph(2, 1, 10.0)];
    let struck = frame_of(vec![row(0.0, glyphs, vec![(0..2, paint)], 1)]);
    let mut painter = painter();
    painter.paint(&struck, target(1.0));
    // Three tenths of the font's 16 pixels above the baseline at 12:
    // 7.2, so 7.
    assert_eq!(fills(&painter, RED), vec![(0, 7, 20, 1)]);
    painter.paint(&struck, target(2.0));
    assert_eq!(fills(&painter, RED), vec![(0, 7, 20, 2)]);
}

/// The quads a cursor of `shape` comes to: in the cursor's green, and in
/// its white. The cursor is on the second row of a view, over the area
/// `area`; the row has one glyph, at 10 across.
fn cursor_quads(shape: CursorShape, area: Area, scale: f32) -> (Vec<Quad>, Vec<Quad>) {
    let mut shown = view(vec![
        plain_row(0.0, &[1], 1),
        row(
            16.0,
            vec![glyph(2, 0, 10.0)],
            vec![(0..1, Paint::default())],
            2,
        ),
    ]);
    shown.cursors = vec![CursorBox {
        area,
        shape,
        paint: Paint {
            foreground: WHITE,
            background: GREEN,
            ..Paint::default()
        },
    }];
    let mut painter = painter();
    painter.paint(&frame(vec![shown]), target(scale));
    let green = quads_of(&painter, QuadKind::Fill, GREEN);
    let white = quads_of(&painter, QuadKind::Mask, WHITE);
    // A cursor is the last thing drawn.
    let last = green.len() + white.len();
    let tail = &painter.quads()[painter.quads().len() - last..];
    assert!(tail.iter().all(|quad| quad.color != BLACK), "{tail:?}");
    (green, white)
}

/// The cell of the second row's glyph: ten across from 10, the row's 16
/// down from 16.
const CELL: Area = Area {
    x: 10.0,
    y: 16.0,
    width: 10.0,
    height: 16.0,
};

#[test]
fn a_block_cursor_fills_its_cell_and_draws_the_glyph_under_it_again() {
    let (green, white) = cursor_quads(CursorShape::Block, CELL, 1.0);
    assert_eq!(boxes(&green), vec![(10, 16, 10, 16)]);
    // The glyph's own quad, in the cursor's foreground: its image begins
    // at the cell's left and stands on the baseline, 12 below the row's
    // top.
    let top = 16 + 12 - GLYPH.1 as i32;
    assert_eq!(boxes(&white), vec![(10, top, GLYPH.0, GLYPH.1)]);
    assert_eq!(white[0].page, 1);
}

#[test]
fn the_glyph_under_a_block_cursor_is_cut_to_the_cursors_area() {
    // A cursor four pixels across and eight down, from the row's top:
    // the glyph's image is six across and reaches from 2 below the row's
    // top to 12 below.
    let narrow = Area {
        width: 4.0,
        height: 8.0,
        ..CELL
    };
    let (green, white) = cursor_quads(CursorShape::Block, narrow, 1.0);
    assert_eq!(boxes(&green), vec![(10, 16, 4, 8)]);
    assert_eq!(boxes(&white), vec![(10, 18, 4, 6)]);
    // A cursor that is on no glyph draws none.
    let aside = Area { x: 100.0, ..CELL };
    let (_, white) = cursor_quads(CursorShape::Block, aside, 1.0);
    assert!(white.is_empty());
}

#[test]
fn a_rows_x_moves_its_glyphs_its_run_backgrounds_and_a_block_cursors_glyphs() {
    // One glyph at 10 across on a red background, in a row that a padded
    // view puts 8.4 pixels in and 8 down: drawn at 8 (8.4 on its pixel,
    // as a row's top is), and its cursor's cell 8.4 further in too.
    let on_red = Paint {
        foreground: BLACK,
        background: RED,
        ..Paint::default()
    };
    let at = |x: f32| FrameRow {
        x,
        ..row(8.0, vec![glyph(2, 0, 10.0)], vec![(0..1, on_red)], 1)
    };
    let cursor = |x: f32| CursorBox {
        area: Area {
            x: x + 10.0,
            y: 8.0,
            width: 10.0,
            height: 16.0,
        },
        shape: CursorShape::Block,
        paint: Paint {
            foreground: WHITE,
            background: GREEN,
            ..Paint::default()
        },
    };
    let painted = |x: f32| {
        let mut shown = view(vec![at(x)]);
        shown.cursors = vec![cursor(x)];
        let mut painter = painter();
        painter.paint(&frame(vec![shown]), target(1.0));
        (
            boxes(&quads_of(&painter, QuadKind::Mask, BLACK)),
            fills(&painter, RED),
            boxes(&quads_of(&painter, QuadKind::Mask, WHITE)),
        )
    };
    let (glyphs, backgrounds, under) = painted(0.0);
    let (moved_glyphs, moved_backgrounds, moved_under) = painted(8.4);
    let by = |quads: Vec<(i32, i32, u32, u32)>| -> Vec<(i32, i32, u32, u32)> {
        quads
            .into_iter()
            .map(|(x, y, width, height)| (x + 8, y, width, height))
            .collect()
    };
    assert_eq!(glyphs.len(), 1);
    assert_eq!(moved_glyphs, by(glyphs));
    assert_eq!(backgrounds.len(), 1);
    assert_eq!(moved_backgrounds, by(backgrounds));
    // The glyph a block cursor draws again is the row's, moved with it,
    // and cut to the cursor's cell.
    assert_eq!(under.len(), 1);
    assert_eq!(moved_under.len(), 1);
    assert_eq!(moved_under[0].0, under[0].0 + 8);
}

#[test]
fn a_bar_an_underline_and_a_hollow_cursor_are_lines_as_thick_as_the_scale() {
    let green = |shape, scale| boxes(&cursor_quads(shape, CELL, scale).0);
    assert_eq!(green(CursorShape::Bar, 1.0), vec![(10, 16, 1, 16)]);
    assert_eq!(green(CursorShape::Bar, 2.0), vec![(10, 16, 2, 16)]);
    assert_eq!(green(CursorShape::Underline, 1.0), vec![(10, 31, 10, 1)]);
    assert_eq!(green(CursorShape::Underline, 2.0), vec![(10, 30, 10, 2)]);
    // The top, the bottom, the left and the right edge.
    assert_eq!(
        green(CursorShape::Hollow, 1.0),
        vec![
            (10, 16, 10, 1),
            (10, 31, 10, 1),
            (10, 16, 1, 16),
            (19, 16, 1, 16)
        ]
    );
    assert_eq!(
        green(CursorShape::Hollow, 2.0),
        vec![
            (10, 16, 10, 2),
            (10, 30, 10, 2),
            (10, 16, 2, 16),
            (18, 16, 2, 16)
        ]
    );
    // None of them draws the glyph again.
    for shape in [
        CursorShape::Bar,
        CursorShape::Underline,
        CursorShape::Hollow,
    ] {
        assert!(cursor_quads(shape, CELL, 1.0).1.is_empty(), "{shape:?}");
    }
}

#[test]
fn a_row_seen_again_takes_its_quads_from_the_row_cache_and_asks_the_rasteriser_nothing() {
    let rect = Rect {
        x: 0,
        y: 0,
        width: 200,
        height: 100,
    };
    let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
    let first = layout.frame(&Scene::of_text("one\ntwo", rect).selecting(0..0));
    let moved = layout.frame(&Scene::of_text("one\ntwo", rect).selecting(5..5));
    assert_ne!(first.views[0].cursors, moved.views[0].cursors);
    let mut painter = painter();
    let drawn = painter.paint(&first, target(1.0));
    let asked = painter.rasterizer().asked.len();
    let glyphs = quads_of(&painter, QuadKind::Mask, BLACK);
    assert_eq!(drawn.rows_rebuilt, 2);
    // "one" and "two" share an `o`: five images for six glyphs.
    assert_eq!((drawn.glyphs_rasterised, drawn.glyphs_reused), (5, 1));

    let again = painter.paint(&moved, target(1.0));
    assert_eq!((again.rows_rebuilt, again.rows_reused), (0, 2));
    assert_eq!((again.glyphs_rasterised, again.glyphs_reused), (0, 0));
    assert_eq!(painter.rasterizer().asked.len(), asked);
    // The rows' glyphs are drawn as they were; only the cursor moved, to
    // where the second frame puts it.
    assert_eq!(quads_of(&painter, QuadKind::Mask, BLACK)[..6], glyphs[..6]);
    let cursor = moved.views[0].cursors[0];
    let area = cursor.area;
    let cell = Quad::over(
        area.x,
        area.y,
        area.width,
        area.height,
        cursor.paint.background,
    );
    assert!(painter.quads()[1..].contains(&cell), "{cell:?}");
}

#[test]
fn what_a_paint_whose_draw_was_refused_did_is_answered_by_the_next_paint() {
    // Two rows that share a glyph: four images for five glyphs.
    let shown = frame_of(vec![
        plain_row(0.0, &[1, 2, 3], 1),
        plain_row(16.0, &[3, 4], 2),
    ]);
    // What the frame costs a painter none of whose draws is refused.
    let whole = painter().paint(&shown, target(1.0));
    assert_eq!((whole.rows_rebuilt, whole.rows_reused), (2, 0));
    assert_eq!((whole.glyphs_rasterised, whole.glyphs_reused), (4, 1));

    let mut painter = painter();
    assert_eq!(painter.paint(&shown, target(1.0)), whole);
    painter.refused();
    // The frame is tried again. Nothing is done twice, and what was done
    // for it is answered now: its rows are built, not reused.
    assert_eq!(painter.paint(&shown, target(1.0)), whole);
    assert_eq!(painter.rasterizer().asked.len(), 4);
    // Refused once more, it is answered once more, and no more than once.
    painter.refused();
    assert_eq!(painter.paint(&shown, target(1.0)), whole);
    // That draw is not refused: the frame costs nothing more.
    let again = painter.paint(&shown, target(1.0));
    assert_eq!((again.rows_rebuilt, again.rows_reused), (0, 2));
    assert_eq!((again.glyphs_rasterised, again.glyphs_reused), (0, 0));
}

#[test]
fn what_a_refused_draw_built_is_built_whatever_frame_is_presented_next() {
    let (kept, lost, new) = (
        plain_row(0.0, &[1, 2, 3], 1),
        plain_row(16.0, &[3, 4], 2),
        plain_row(32.0, &[5], 3),
    );
    // One row is presented. Then a frame with a second row, whose draw is
    // refused: it built that row, with one image more and one it held.
    let refused = |painter: &mut Painter<FakeRasterizer>| {
        painter.paint(&frame_of(vec![kept.clone()]), target(1.0));
        let drawn = painter.paint(&frame_of(vec![kept.clone(), lost.clone()]), target(1.0));
        assert_eq!((drawn.rows_rebuilt, drawn.rows_reused), (1, 1));
        assert_eq!((drawn.glyphs_rasterised, drawn.glyphs_reused), (1, 1));
        painter.refused();
    };
    // A newer frame is presented in its place, with a third row. The row
    // the refused draw built is built, and only the row held since a draw
    // was presented is reused.
    let mut painter = painter();
    refused(&mut painter);
    let all = frame_of(vec![kept.clone(), lost.clone(), new.clone()]);
    let drawn = painter.paint(&all, target(1.0));
    assert_eq!((drawn.rows_rebuilt, drawn.rows_reused), (2, 1));
    assert_eq!((drawn.glyphs_rasterised, drawn.glyphs_reused), (2, 1));
    // A newer frame that does not show the row the refused draw built:
    // it was built all the same, for a frame that was never presented.
    let mut painter = self::painter();
    refused(&mut painter);
    let drawn = painter.paint(&frame_of(vec![kept.clone(), new.clone()]), target(1.0));
    assert_eq!((drawn.rows_rebuilt, drawn.rows_reused), (2, 1));
    assert_eq!((drawn.glyphs_rasterised, drawn.glyphs_reused), (2, 1));
}

#[test]
fn a_row_moved_is_drawn_from_what_was_kept_where_it_now_is() {
    let mut painter = painter();
    painter.paint(&frame_of(vec![plain_row(0.0, &[1, 2], 1)]), target(1.0));
    let before = quads_of(&painter, QuadKind::Mask, BLACK);
    let asked = painter.rasterizer().asked.len();
    // The same row, 48 pixels lower, in a view 20 further right.
    let mut shown = view(vec![plain_row(48.0, &[1, 2], 1)]);
    shown.rect.x = 20;
    let drawn = painter.paint(&frame(vec![shown]), target(1.0));
    assert_eq!((drawn.rows_rebuilt, drawn.rows_reused), (0, 1));
    assert_eq!(painter.rasterizer().asked.len(), asked);
    let moved: Vec<Quad> = before.iter().map(|quad| quad.moved(20, 48)).collect();
    assert_eq!(quads_of(&painter, QuadKind::Mask, BLACK), moved);
}

#[test]
fn a_dropped_row_lets_its_glyphs_go_so_the_atlas_stays_within_its_budget() {
    // A budget of one page of masks, and forty frames of one row each,
    // every row of three glyphs no other has.
    let page = 32;
    let budget = u64::from(page * page);
    let mut painter = tight(page);
    let mut evicted = 0;
    for step in 0..40_u32 {
        let ids = [step * 3, step * 3 + 1, step * 3 + 2];
        let drawn = painter.paint(
            &frame_of(vec![plain_row(0.0, &ids, u64::from(step) + 1)]),
            target(1.0),
        );
        assert_eq!(drawn.glyphs_rasterised, 3);
        assert!(drawn.atlas_bytes <= budget, "at frame {step}");
        evicted += drawn.glyphs_evicted;
    }
    assert!(evicted > 0);
    assert_eq!(painter.glyph_stats().over_budget, 0);
    assert_eq!(painter.glyph_stats().evicted, evicted);
}

#[test]
fn pages_added_past_the_budget_for_glyphs_in_use_are_given_back_at_a_later_draw() {
    // A budget of one page of masks, and a frame of four rows of ten
    // glyphs each, no two alike: more images in use than a page holds.
    let page = 32;
    let budget = u64::from(page * page);
    let mut painter = tight(page);
    let rows: Vec<FrameRow> = (0..4_u32)
        .map(|row| {
            let ids: Vec<u32> = (0..10).map(|glyph| row * 10 + glyph).collect();
            plain_row(row as f32 * 16.0, &ids, u64::from(row) + 1)
        })
        .collect();
    let crowded = painter.paint(&frame_of(rows), target(1.0));
    // In use wins: the atlas is past its budget, and nothing was let go.
    assert_eq!(crowded.glyphs_rasterised, 40);
    assert!(crowded.atlas_bytes > budget);
    assert_eq!(crowded.glyphs_evicted, 0);
    assert!(painter.glyph_stats().over_budget > 0);
    // Then one short row of the first of those glyphs is all there is:
    // the four rows are dropped, and let their glyphs go.
    let short = frame_of(vec![plain_row(0.0, &[0], 100)]);
    painter.paint(&short, target(1.0));
    // The draw after that begins by giving back the pages nothing uses.
    let later = painter.paint(&short, target(1.0));
    assert!(later.atlas_bytes <= budget, "{later:?}");
    assert!(later.glyphs_evicted > 0);
    // The glyph still shown is drawn from its own image.
    let shown = quads_of(&painter, QuadKind::Mask, BLACK);
    assert_eq!(shown.len(), 1);
    let made = painter.rasterizer().image(mask_key(0)).expect("an image");
    assert_eq!(read(&painter, &shown[0]), made.data);
}

/// The bytes the atlas of `painter` holds where `quad` reads.
fn read(painter: &Painter<FakeRasterizer>, quad: &Quad) -> Vec<u8> {
    painter
        .atlas()
        .region(quad.page, (quad.u, quad.v), (quad.width, quad.height))
}

/// The key of the plain mask of the glyph `glyph` of font 0 at bin 0.
fn mask_key(glyph: u32) -> GlyphKey {
    GlyphKey {
        font: ResolvedFontId(0),
        glyph,
        bin: 0,
        subpixel: false,
    }
}

#[test]
fn a_frame_of_another_generation_is_rasterised_afresh_and_keeps_its_glyphs_in_use() {
    let mut painter = tight(32);
    let kept = plain_row(0.0, &[1, 2, 3], 1);
    let first = painter.paint(&frame_of(vec![kept.clone()]), target(1.0));
    assert_eq!(first.glyphs_rasterised, 3);
    // The same row under another generation: its font ids may mean other
    // fonts, so nothing kept is used.
    let later = |rows: Vec<FrameRow>| Frame {
        generation: 1,
        ..frame_of(rows)
    };
    let second = painter.paint(&later(vec![kept.clone()]), target(1.0));
    assert_eq!((second.rows_rebuilt, second.rows_reused), (1, 0));
    assert_eq!((second.glyphs_rasterised, second.glyphs_reused), (3, 0));
    // The row stays on screen while forty other rows come and go, in an
    // atlas of one page: its images are still its own.
    for step in 0..40_u32 {
        let ids = [100 + step * 3, 101 + step * 3, 102 + step * 3];
        let churn = plain_row(16.0, &ids, 100 + u64::from(step));
        painter.paint(&later(vec![kept.clone(), churn]), target(1.0));
    }
    assert!(painter.glyph_stats().evicted > 0);
    let glyphs = quads_of(&painter, QuadKind::Mask, BLACK);
    for (quad, id) in glyphs.iter().zip([1, 2, 3]) {
        let made = painter.rasterizer().image(mask_key(id)).expect("an image");
        assert_eq!(read(&painter, quad), made.data, "glyph {id}");
    }
}

#[test]
fn another_scale_builds_the_rows_again_and_keeps_the_glyph_images() {
    let mut painter = painter();
    let shown = frame_of(vec![plain_row(0.0, &[1, 2, 3], 1)]);
    painter.paint(&shown, target(1.0));
    let drawn = painter.paint(&shown, target(2.0));
    assert_eq!((drawn.rows_rebuilt, drawn.rows_reused), (1, 0));
    // A frame is in physical pixels: the images are the same ones, and
    // the rasteriser is asked for none.
    assert_eq!((drawn.glyphs_rasterised, drawn.glyphs_reused), (0, 3));
    assert_eq!(painter.rasterizer().asked.len(), 3);
}

#[test]
fn a_glyph_with_no_image_is_counted_and_draws_nothing() {
    let mut rasterizer = FakeRasterizer::new();
    rasterizer.missing.insert(2);
    let mut painter = painter_over(rasterizer);
    // The second glyph has no image, and the fourth names a font the
    // frame does not have.
    let stray = Glyph {
        font: ResolvedFontId(9),
        ..glyph(4, 3, 30.0)
    };
    let glyphs = vec![
        glyph(1, 0, 0.0),
        glyph(2, 1, 10.0),
        glyph(3, 2, 20.0),
        stray,
    ];
    let shown = frame_of(vec![row(0.0, glyphs, vec![(0..4, Paint::default())], 1)]);
    let drawn = painter.paint(&shown, target(1.0));
    assert_eq!((drawn.glyphs_rasterised, drawn.glyphs_skipped), (2, 2));
    let lefts: Vec<i32> = quads_of(&painter, QuadKind::Mask, BLACK)
        .iter()
        .map(|quad| quad.x)
        .collect();
    assert_eq!(lefts, vec![0, 20]);
    // Drawn again from the kept row, nothing is skipped: nothing is
    // asked.
    assert_eq!(painter.paint(&shown, target(1.0)).glyphs_skipped, 0);
}

#[test]
fn nothing_is_drawn_outside_a_view_or_outside_the_target() {
    // A view 25 pixels across of a row of three glyphs: the third's image
    // is from 20 to 26.
    let mut shown = view(vec![plain_row(0.0, &[1, 2, 3], 1)]);
    shown.rect.width = 25;
    let mut painter = painter();
    painter.paint(&frame(vec![shown.clone()]), target(1.0));
    let widths: Vec<u32> = quads_of(&painter, QuadKind::Mask, BLACK)
        .iter()
        .map(|quad| quad.width)
        .collect();
    assert_eq!(widths, vec![GLYPH.0, GLYPH.0, 5]);
    // On a target 12 pixels across and 8 down, the view itself is cut:
    // the first glyph's image, from 2 to 12 down, is cut at 8, and the
    // second's, from 10 across, at 12.
    let small = Target {
        width: 12,
        height: 8,
        scale: 1.0,
    };
    painter.paint(&frame(vec![shown]), small);
    assert_eq!(fills(&painter, WHITE), vec![(0, 0, 12, 8)]);
    assert_eq!(
        boxes(&quads_of(&painter, QuadKind::Mask, BLACK)),
        vec![(0, 2, GLYPH.0, 6), (10, 2, 2, 6)]
    );
}

#[test]
fn a_view_away_from_the_targets_top_left_is_clipped_to_its_own_rectangle() {
    // Two views 45 pixels across and 40 down, the second at 150, 90. In
    // each, a row of five glyphs, the fifth's image from 40 to 46, and a
    // selection that reaches past the view on every side, as far as the
    // other view.
    let beyond = Area {
        x: -200.0,
        y: -200.0,
        width: 500.0,
        height: 500.0,
    };
    let shown = |x: u32, y: u32| {
        let mut shown = view(vec![plain_row(0.0, &[1, 2, 3, 4, 5], 1)]);
        shown.rect = Rect {
            x,
            y,
            width: 45,
            height: 40,
        };
        shown.selections = vec![beyond];
        shown
    };
    let mut painter = painter();
    painter.paint(&frame(vec![shown(0, 0), shown(150, 90)]), target(1.0));
    // Each selection is cut to its own view on all four sides: neither
    // view draws in the other's rectangle.
    assert_eq!(
        fills(&painter, BLUE),
        vec![(0, 0, 45, 40), (150, 90, 45, 40)]
    );
    // And the fifth glyph is cut at its view's right edge, wherever that
    // is.
    let glyphs = boxes(&quads_of(&painter, QuadKind::Mask, BLACK));
    let top = 12 - GLYPH.1 as i32;
    assert_eq!(glyphs.len(), 10);
    assert_eq!(glyphs[4], (40, top, 5, GLYPH.1));
    assert_eq!(glyphs[9], (150 + 40, 90 + top, 5, GLYPH.1));
}

#[test]
fn a_glyph_across_a_change_of_paint_is_drawn_in_the_paint_of_its_first_byte() {
    // One glyph for two bytes, a ligature, the first byte red and the
    // second blue.
    let ligature = Glyph {
        advance: 20.0,
        ..glyph(5, 0, 0.0)
    };
    let mut both = row(
        0.0,
        vec![ligature],
        vec![(0..1, ink(RED)), (1..2, ink(BLUE))],
        1,
    );
    both.bytes = 0..2;
    let mut painter = painter();
    painter.paint(&frame_of(vec![both]), target(1.0));
    assert_eq!(quads_of(&painter, QuadKind::Mask, RED).len(), 1);
    assert!(quads_of(&painter, QuadKind::Mask, BLUE).is_empty());
}

#[test]
fn each_kind_of_image_is_drawn_as_its_kind_of_quad() {
    let mut rasterizer = FakeRasterizer::new();
    rasterizer.colour.insert(2);
    let shown = frame_of(vec![plain_row(0.0, &[1, 2], 1)]);
    let kinds = |painter: &Painter<FakeRasterizer>| -> Vec<QuadKind> {
        painter.quads()[1..].iter().map(|quad| quad.kind).collect()
    };
    let mut plain = painter_over(rasterizer);
    plain.paint(&shown, target(1.0));
    assert_eq!(kinds(&plain), vec![QuadKind::Mask, QuadKind::Color]);

    let mut rasterizer = FakeRasterizer::new();
    rasterizer.colour.insert(2);
    let stripes = Antialiasing::Subpixel(SubpixelOrder::Rgb);
    let mut subpixel = Painter::new(rasterizer, &settings(stripes, u64::MAX), true, PAGE);
    subpixel.paint(&shown, target(1.0));
    assert_eq!(kinds(&subpixel), vec![QuadKind::Subpixel, QuadKind::Color]);
    // Each reads a page of its own.
    let pages: Vec<u32> = subpixel.quads()[1..].iter().map(|quad| quad.page).collect();
    assert_ne!(pages[0], pages[1]);
    // And the rasteriser was asked for subpixel masks, hinted as the
    // painter was told.
    assert!(
        subpixel
            .rasterizer()
            .asked
            .iter()
            .all(|(key, _, hint)| key.subpixel && *hint)
    );
}

#[test]
fn glyphs_are_asked_for_fitted_to_the_pixel_grid_or_not_as_the_settings_say() {
    let shown = frame_of(vec![plain_row(0.0, &[1, 2], 1)]);
    // Whether each glyph was asked for hinted, by a painter told
    // `hinting`.
    let asked = |hinting: bool| -> Vec<bool> {
        let settings = Settings {
            hinting,
            ..settings(Antialiasing::Grayscale, u64::MAX)
        };
        let mut painter = Painter::new(FakeRasterizer::new(), &settings, true, PAGE);
        painter.paint(&shown, target(1.0));
        let asked = &painter.rasterizer().asked;
        asked.iter().map(|(_, _, hint)| *hint).collect()
    };
    assert_eq!(asked(false), vec![false, false]);
    assert_eq!(asked(true), vec![true, true]);
}

#[test]
fn a_subpixel_mask_is_kept_in_the_order_of_the_displays_stripes() {
    let shown = frame_of(vec![plain_row(0.0, &[1], 1)]);
    let key = GlyphKey {
        subpixel: true,
        ..mask_key(1)
    };
    let kept = |order: SubpixelOrder| {
        let mut painter = painter_with(Antialiasing::Subpixel(order));
        painter.paint(&shown, target(1.0));
        let made = painter.rasterizer().image(key).expect("an image").data;
        (read(&painter, &painter.quads()[1]), made)
    };
    // Red, green, blue: as the rasteriser gives it.
    let (held, made) = kept(SubpixelOrder::Rgb);
    assert_eq!(held, made);
    // Blue, green, red: the first and the third coverage of each pixel
    // change places.
    let (held, made) = kept(SubpixelOrder::Bgr);
    let swapped: Vec<u8> = made
        .as_chunks::<4>()
        .0
        .iter()
        .flat_map(|pixel| [pixel[2], pixel[1], pixel[0], pixel[3]])
        .collect();
    assert_eq!(held, swapped);
    assert_ne!(held, made);
}

#[test]
fn the_kind_of_mask_asked_for_follows_the_scale_and_the_device() {
    let shown = frame_of(vec![plain_row(0.0, &[1, 2], 1)]);
    let kinds = |painter: &Painter<FakeRasterizer>| -> Vec<QuadKind> {
        painter.quads()[1..].iter().map(|quad| quad.kind).collect()
    };
    // Left to the display: subpixel masks at scale 1.
    let mut painter = painter_with(Antialiasing::Auto);
    painter.paint(&shown, target(1.0));
    assert_eq!(kinds(&painter), vec![QuadKind::Subpixel; 2]);
    // And plain masks at scale 2: the rows are built again, from images
    // of the other kind.
    let drawn = painter.paint(&shown, target(2.0));
    assert_eq!(kinds(&painter), vec![QuadKind::Mask; 2]);
    assert_eq!((drawn.rows_rebuilt, drawn.glyphs_rasterised), (1, 2));
    // Back at scale 1 the subpixel masks are still held.
    let drawn = painter.paint(&shown, target(1.0));
    assert_eq!(kinds(&painter), vec![QuadKind::Subpixel; 2]);
    assert_eq!((drawn.glyphs_rasterised, drawn.glyphs_reused), (0, 2));
    // A device that cannot blend by a coverage for each channel is given
    // plain masks whatever the setting.
    let stripes = Antialiasing::Subpixel(SubpixelOrder::Rgb);
    let mut plain = Painter::new(
        FakeRasterizer::new(),
        &settings(stripes, u64::MAX),
        false,
        PAGE,
    );
    plain.paint(&shown, target(1.0));
    assert_eq!(kinds(&plain), vec![QuadKind::Mask; 2]);
}

#[test]
fn a_painter_says_which_masks_its_last_paint_asked_for() {
    let shown = frame_of(vec![plain_row(0.0, &[1, 2], 1)]);
    let rgb = Some(Masks::Subpixel(SubpixelOrder::Rgb));
    // Left to the display, on a device that blends by a coverage for each
    // channel.
    let mut painter = painter_with(Antialiasing::Auto);
    // Nothing painted, nothing to say.
    assert_eq!(painter.masks(), None);
    // Subpixel masks, red first, at scale 1; plain ones at scale 2; and
    // it is the last paint's that is said.
    painter.paint(&shown, target(1.0));
    assert_eq!(painter.masks(), rgb);
    painter.paint(&shown, target(2.0));
    assert_eq!(painter.masks(), Some(Masks::Plain));
    painter.paint(&shown, target(1.0));
    assert_eq!(painter.masks(), rgb);
    // A paint whose draw the device then refuses asked for its masks all
    // the same.
    painter.paint(&shown, target(2.0));
    painter.refused();
    assert_eq!(painter.masks(), Some(Masks::Plain));
    // The order a setting names, at any scale.
    let bgr = SubpixelOrder::Bgr;
    let mut named = painter_with(Antialiasing::Subpixel(bgr));
    for scale in [1.0, 2.0] {
        named.paint(&shown, target(scale));
        assert_eq!(named.masks(), Some(Masks::Subpixel(bgr)), "at {scale}");
    }
    // Plain masks where a setting says so, and on a device that cannot
    // blend by a coverage for each channel whatever the setting says.
    let mut grey = painter_with(Antialiasing::Grayscale);
    let stripes = Antialiasing::Subpixel(SubpixelOrder::Rgb);
    let mut cannot = Painter::new(
        FakeRasterizer::new(),
        &settings(stripes, u64::MAX),
        false,
        PAGE,
    );
    for scale in [1.0, 2.0] {
        grey.paint(&shown, target(scale));
        assert_eq!(grey.masks(), Some(Masks::Plain), "at {scale}");
        cannot.paint(&shown, target(scale));
        assert_eq!(cannot.masks(), Some(Masks::Plain), "at {scale}");
    }
}
