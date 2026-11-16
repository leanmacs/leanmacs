//! The fixture frame of real text, and the reference image it is compared
//! with.
//!
//! This is the one place the crate names the real shaper. It is included
//! by `tests/reference.rs` and `tests/reuse.rs`, the two tests the
//! `Renderer` port's module docs name as wiring, and by the two examples,
//! which draw the same frame; nothing else includes it.
//!
//! The fonts are the five fixture files under `tests/fonts` at the
//! repository's root, compiled in: no file is read when a test runs, and
//! no font of the machine is used.

// Each test binary and each example uses its own part of this module.
#![allow(dead_code)]

use std::ops::Range;

use editor_layout::Layout;
use editor_layout::face::{Color, Face, FaceDef, Underline, UnderlineStyle};
use editor_layout::frame::Frame;
use editor_layout::scene::{
    Cursor as SceneCursor, CursorShape, Decoration, Rect, Scene, StatusField,
};
use editor_render::port::Target;
use editor_render_wgpu::{Antialiasing, Image, Settings, SubpixelOrder};
use editor_shape_parley::{FontSet, ParleyShaper};

/// Noto Sans: the default family, with a ligature for `fi`.
const SANS: &[u8] = include_bytes!("../../../../tests/fonts/NotoSans-Regular.subset.ttf");
/// Noto Sans Mono.
const MONO: &[u8] = include_bytes!("../../../../tests/fonts/NotoSansMono-Regular.subset.ttf");
/// Noto Sans Hebrew.
const HEBREW: &[u8] = include_bytes!("../../../../tests/fonts/NotoSansHebrew-Regular.ttf");
/// Noto Sans JP.
const JP: &[u8] = include_bytes!("../../../../tests/fonts/NotoSansJP-Regular.subset.otf");
/// Noto Emoji.
const EMOJI: &[u8] = include_bytes!("../../../../tests/fonts/NotoEmoji.subset.ttf");

/// How far across the fixture frame is.
pub const WIDTH: u32 = 256;
/// How far down.
pub const HEIGHT: u32 = 96;

/// The target the fixture frame is drawn on: its own size, at scale 1.
pub const TARGET: Target = Target {
    width: WIDTH,
    height: HEIGHT,
    scale: 1.0,
};

/// The colour behind the fixture's text: the default face's background.
pub const BACKGROUND: [u8; 4] = [0xf8, 0xf8, 0xf8, 0xff];

/// The settings the reference image is drawn with: subpixel antialiasing
/// in the order red, green, blue, and hinting.
pub fn settings() -> Settings {
    Settings {
        antialiasing: Antialiasing::Subpixel(SubpixelOrder::Rgb),
        ..Settings::default()
    }
}

/// A layout over the real shaper and the fixture fonts: Noto Sans the
/// default family, and the Hebrew, the CJK and the emoji font its
/// fallbacks.
pub fn layout() -> Layout<ParleyShaper> {
    let files: Vec<Vec<u8>> = [SANS, MONO, HEBREW, JP, EMOJI]
        .iter()
        .map(|bytes| bytes.to_vec())
        .collect();
    let fallbacks = ["Noto Sans Hebrew", "Noto Sans JP", "Noto Emoji"];
    let fonts = FontSet::only("Noto Sans", &fallbacks, files).expect("the fixture fonts");
    Layout::new(ParleyShaper::new(fonts))
}

/// The text of the fixture: a ligature (`fi`), a right-to-left run, a
/// character of the CJK fallback and one of the emoji fallback, in two
/// short rows.
pub const TEXT: &str = "fine שלום 日\nunder line 😀";

/// The faces of the fixture.
fn theme() -> Vec<FaceDef> {
    let named = |name: &str, face: Face| FaceDef {
        name: name.to_owned(),
        face,
    };
    let rgb = |red: u8, green: u8, blue: u8| Some(Color::rgb(red, green, blue));
    vec![
        named(
            "default",
            Face {
                foreground: rgb(0x20, 0x20, 0x20),
                background: rgb(0xf8, 0xf8, 0xf8),
                ..Face::default()
            },
        ),
        named(
            "note",
            Face {
                foreground: rgb(0, 0, 0xc0),
                underline: Some(Underline {
                    style: UnderlineStyle::Single,
                    color: None,
                }),
                ..Face::default()
            },
        ),
        named(
            "mark",
            Face {
                background: rgb(0xff, 0xf0, 0xa0),
                underline: Some(Underline {
                    style: UnderlineStyle::Curly,
                    color: rgb(0xc0, 0, 0),
                }),
                ..Face::default()
            },
        ),
        named(
            "selection",
            Face {
                background: rgb(0xc0, 0xd8, 0xff),
                ..Face::default()
            },
        ),
        named(
            "mode-line",
            Face {
                foreground: rgb(0xf0, 0xf0, 0xf0),
                background: rgb(0x40, 0x40, 0x40),
                ..Face::default()
            },
        ),
        named(
            "cursor",
            Face {
                foreground: rgb(0xff, 0xff, 0xff),
                background: rgb(0xc0, 0, 0),
                ..Face::default()
            },
        ),
    ]
}

/// The scene of `text` in one view the size of the fixture: its selection
/// from `selected.start` to its head at `selected.end`, where a block
/// cursor is; the second row's first word underlined and its second
/// marked; and a status row.
pub fn scene_of(text: &str, selected: Range<usize>) -> Scene {
    let rect = Rect {
        x: 0,
        y: 0,
        width: WIDTH,
        height: HEIGHT,
    };
    let mut scene = Scene::of_text(text, rect).selecting(selected);
    scene.faces = Some(theme());
    let second = text.find('\n').map_or(0, |end| end + 1);
    let shown = &mut scene.views[0];
    shown.decorations = vec![
        Decoration {
            start: second,
            stop: second + "under".len(),
            face: "note".to_owned(),
        },
        Decoration {
            start: second + "under ".len(),
            stop: second + "under line".len(),
            face: "mark".to_owned(),
        },
    ];
    shown.cursor = SceneCursor {
        shape: CursorShape::Block,
        face: "cursor".to_owned(),
    };
    shown.status = vec![StatusField {
        text: "frame.png  1:8".to_owned(),
        face: "mode-line".to_owned(),
        ..StatusField::default()
    }];
    scene
}

/// The selection of the fixture: from the `n` of `fine` across the space
/// into the right-to-left run, with its head, and so the cursor, on the
/// run's second letter.
pub const SELECTED: Range<usize> = 2..7;

/// The fixture frame: [`TEXT`] with [`SELECTED`] selected.
pub fn fixture_frame() -> Frame {
    layout().frame(&scene_of(TEXT, SELECTED))
}

/// The picture the PNG file `bytes` holds ([`Image::from_png`]).
pub fn decode(bytes: &[u8]) -> Image {
    Image::from_png(bytes).expect("a PNG file of 8 bits a channel, RGB or RGBA")
}

/// How `image` differs from `reference` ([`Image::difference`]).
pub fn difference(image: &Image, reference: &Image) -> Option<(u8, usize)> {
    image.difference(reference)
}
