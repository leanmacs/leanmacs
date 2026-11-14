//! The fixture frame: one scene laid out on the fake shaper, described as
//! text, equal to the file checked in at `tests/display/frame.expected`.
//!
//! The same scene is published from Lean through the real binding by
//! `ffi-test display ../tests/display/frame.expected` (lean/FfiTest.lean),
//! which requires the published frame's text to equal the same file. So the
//! two sides are compared through one file, and this crate owns it: when
//! layout's rules change, the file is rewritten here from the text this
//! test prints on failure, and the Lean check follows.
//!
//! The scene, which `lean/FfiTest.lean` builds the same way:
//!
//! - cells 8 pixels across and 16 down, tabs 8 columns wide;
//! - view 1, at 0,0 and 96 by 80 (12 columns; 5 rows, of which its status
//!   row is the last), shows text A from offset 0, with the selections
//!   3..7 and, in a second selection, a cursor at 18; the decorations, in
//!   this order, 0..2 in `keyword`, 17..18 in `number` and 1..5 in
//!   `emphasis`; block cursors in `cursor.normal`; the status fields
//!   `fixture.rs` in `mode-line` and ` 1:8` in `position`, a buffer name
//!   and a position;
//! - view 2, at 0,80 and 64 by 32 (8 columns, 2 rows), shows text B from
//!   offset 6, with a cursor at 12; bar cursors in `cursor.insert`;
//! - the frame 96 by 112, view 1 focused, the echo `fixture`;
//! - the faces of [`theme`], which `FfiTest.fixtureTheme` states the same
//!   way: `default`, `keyword`, `emphasis`, `number`, `selection`,
//!   `mode-line`, `position` and `cursor.normal`, and not `cursor.insert`.
//!
//! What the frame shows of the faces, in view 1's first row, `fn main() {`:
//!
//! - `0..1`, under `keyword` alone: its foreground and its weight, and the
//!   default face's background, which it does not set;
//! - `1..2`, under `keyword` and the later `emphasis`: the later one's
//!   foreground and slant, and the earlier one's weight, which the later
//!   does not set;
//! - `3..5`, under `emphasis` and the selection: the selection's
//!   background with `emphasis`'s foreground;
//! - `5..7`, selected alone, and `7..11` under no span, in the default face.
//!
//! View 2's cursors name a face the theme does not define, and have the
//! default face's paint.

use editor_layout::Layout;
use editor_layout::face::{Color, Face, FaceDef, Underline, UnderlineStyle};
use editor_layout::scene::{
    Cursor, CursorShape, Decoration, Rect, Scene, Size, StatusField, TextKey, TextRef, View, ViewId,
};
use editor_layout::shaper::fake::CellShaper;
use editor_layout::shaper::{Slant, Weight};
use editor_text::{Selection, SelectionRange, Text};

/// Text A of the fixture.
const TEXT_A: &str = "fn main() {\n\tlet x = 1;\n}\nabcdefghijklmnopqrstuvwxyz\n";
/// Text B of the fixture.
const TEXT_B: &str = "hello\nworld wide web";

/// The selection of the cursors and ranges `ranges`.
fn selection(ranges: &[(usize, usize)]) -> Selection {
    Selection::new(
        ranges
            .iter()
            .map(|&(anchor, head)| SelectionRange::new(anchor, head))
            .collect(),
        0,
    )
    .unwrap()
}

/// The fixture's faces, in the order they are sent.
fn theme() -> Vec<FaceDef> {
    let named = |name: &str, face: Face| FaceDef {
        name: name.to_owned(),
        face,
    };
    let foreground = |red: u8, green: u8, blue: u8| Face {
        foreground: Some(Color::rgb(red, green, blue)),
        ..Face::default()
    };
    let background = |red: u8, green: u8, blue: u8| Some(Color::rgb(red, green, blue));
    vec![
        named(
            "default",
            Face {
                background: background(0xf8, 0xf8, 0xf8),
                ..foreground(0x20, 0x20, 0x20)
            },
        ),
        named(
            "keyword",
            Face {
                weight: Some(Weight::BOLD),
                ..foreground(0, 0, 0xc0)
            },
        ),
        named(
            "emphasis",
            Face {
                slant: Some(Slant::Italic),
                ..foreground(0, 0x80, 0)
            },
        ),
        named(
            "number",
            Face {
                underline: Some(Underline {
                    style: UnderlineStyle::Single,
                    color: None,
                }),
                ..foreground(0xc0, 0, 0)
            },
        ),
        named(
            "selection",
            Face {
                background: background(0xc0, 0xd8, 0xff),
                ..Face::default()
            },
        ),
        named(
            "mode-line",
            Face {
                background: background(0x40, 0x40, 0x40),
                ..foreground(0xff, 0xff, 0xff)
            },
        ),
        named("position", foreground(0xff, 0xff, 0)),
        named(
            "cursor.normal",
            Face {
                background: background(0x20, 0x20, 0x20),
                ..foreground(0xf8, 0xf8, 0xf8)
            },
        ),
    ]
}

/// The fixture scene.
fn scene() -> Scene {
    let a = TextRef::fixed(TextKey(1), Text::from(TEXT_A).snapshot());
    let b = TextRef::fixed(TextKey(2), Text::from(TEXT_B).snapshot());
    Scene {
        size: Size {
            width: 96,
            height: 112,
        },
        views: vec![
            View {
                id: ViewId(1),
                rect: Rect {
                    x: 0,
                    y: 0,
                    width: 96,
                    height: 80,
                },
                text: Some(a),
                scroll: 0,
                selections: vec![selection(&[(3, 7)]), selection(&[(18, 18)])],
                cursor: Cursor {
                    shape: CursorShape::Block,
                    face: "cursor.normal".to_owned(),
                },
                decorations: vec![
                    Decoration {
                        start: 0,
                        stop: 2,
                        face: "keyword".to_owned(),
                    },
                    Decoration {
                        start: 17,
                        stop: 18,
                        face: "number".to_owned(),
                    },
                    Decoration {
                        start: 1,
                        stop: 5,
                        face: "emphasis".to_owned(),
                    },
                ],
                status: vec![
                    StatusField {
                        text: "fixture.rs".to_owned(),
                        face: "mode-line".to_owned(),
                    },
                    StatusField {
                        text: " 1:8".to_owned(),
                        face: "position".to_owned(),
                    },
                ],
            },
            View {
                id: ViewId(2),
                rect: Rect {
                    x: 0,
                    y: 80,
                    width: 64,
                    height: 32,
                },
                text: Some(b),
                scroll: 6,
                selections: vec![selection(&[(12, 12)])],
                cursor: Cursor {
                    shape: CursorShape::Bar,
                    face: "cursor.insert".to_owned(),
                },
                decorations: vec![],
                status: vec![],
            },
        ],
        focused: Some(ViewId(1)),
        echo: "fixture".to_owned(),
        pending: String::new(),
        preedit: None,
        faces: Some(theme()),
    }
}

#[test]
fn the_fixture_scene_lays_out_into_the_fixture_frame() {
    let mut layout = Layout::new(CellShaper::new(8.0, 16.0));
    let described = layout.frame(&scene()).describe();
    let expected = include_str!("../../../tests/display/frame.expected");
    assert!(
        described == expected,
        "the frame differs from tests/display/frame.expected; it is now:\n{described}"
    );
}
