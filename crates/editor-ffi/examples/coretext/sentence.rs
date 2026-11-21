//! The frame of the sentence, as each capture of it was drawn.
//!
//! One view the capture's size, its background the ground, and one row of
//! the sentence `the window draws this` in the text colour over the
//! ground, in the fixture font Noto Sans Mono at 14 pixels for each of the
//! capture's scale. Each glyph's id and pen place across are Core Text's
//! (`tests/coretext/positions.txt`, `MARGIN + x`), the baseline is the
//! capture's, and the target's scale is the capture's, so the painter
//! floors each place to Core Text's grid itself, as it does in the window.
//! No shaper runs. The captures, the positions and the font are compiled
//! in, so nothing reads a file.

use std::sync::Arc;

use editor_layout::face::{Color, Paint};
use editor_layout::frame::{Frame, FrameRow, ViewFrame};
use editor_layout::scene::{Rect, ViewId};
use editor_layout::shaper::{Glyph, ResolvedFont, ResolvedFontId, VisualLine};
use editor_raster_coretext::compare::positions;
use editor_render::port::Target;

use crate::measure::Colours;

/// The sentence.
const SENTENCE: &str = "the window draws this";

/// The fixture font, Noto Sans Mono, the stand-in for Menlo.
const MONO: &[u8] = include_bytes!("../../../../tests/fonts/NotoSansMono-Regular.subset.ttf");

/// Core Text's places of the sentence's glyphs.
const POSITIONS: &str = include_str!("../../../../tests/coretext/positions.txt");

/// The margin left of the line's origin in every capture, in pixels.
const MARGIN: f32 = 16.0;

/// The size of the sentence, in points: pixels at scale 1.
const POINTS: f32 = 14.0;

/// One capture of the sentence, as macOS composited it.
pub struct Capture {
    /// Its file's name, under `tests/coretext/composited/`.
    pub name: &'static str,
    /// The file.
    pub bytes: &'static [u8],
    /// The scale it was drawn at.
    pub scale: u32,
    /// Its ground and its text.
    pub colours: Colours,
    /// Its baseline, in pixels up from its bottom.
    pub baseline_up: u32,
}

const BLACK: [u8; 3] = [0, 0, 0];
const WHITE: [u8; 3] = [0xff, 0xff, 0xff];
const LIGHT: [u8; 3] = [0xd8, 0xde, 0xe9];
const DARK: [u8; 3] = [0x2e, 0x34, 0x40];
const GREY: [u8; 3] = [0x80, 0x80, 0x80];

/// The five captures (`tests/coretext/README.md`).
pub const CAPTURES: [Capture; 5] = [
    Capture {
        name: "sentence.png",
        bytes: include_bytes!("../../../../tests/coretext/composited/sentence.png"),
        scale: 2,
        colours: Colours {
            ground: WHITE,
            text: BLACK,
        },
        baseline_up: 25,
    },
    Capture {
        name: "sentence-dark.png",
        bytes: include_bytes!("../../../../tests/coretext/composited/sentence-dark.png"),
        scale: 2,
        colours: Colours {
            ground: DARK,
            text: LIGHT,
        },
        baseline_up: 25,
    },
    Capture {
        name: "sentence-14.png",
        bytes: include_bytes!("../../../../tests/coretext/composited/sentence-14.png"),
        scale: 1,
        colours: Colours {
            ground: WHITE,
            text: BLACK,
        },
        baseline_up: 21,
    },
    Capture {
        name: "sentence-14-dark.png",
        bytes: include_bytes!("../../../../tests/coretext/composited/sentence-14-dark.png"),
        scale: 1,
        colours: Colours {
            ground: DARK,
            text: LIGHT,
        },
        baseline_up: 21,
    },
    Capture {
        name: "sentence-grey.png",
        bytes: include_bytes!("../../../../tests/coretext/composited/sentence-grey.png"),
        scale: 2,
        colours: Colours {
            ground: WHITE,
            text: GREY,
        },
        baseline_up: 25,
    },
];

impl Capture {
    /// Whether its text is lighter than its ground: light on dark.
    pub fn light_on_dark(&self) -> bool {
        let sum = |rgb: [u8; 3]| rgb.iter().map(|value| u32::from(*value)).sum::<u32>();
        sum(self.colours.text) > sum(self.colours.ground)
    }
}

/// `rgb` as a colour of layout's.
fn color(rgb: [u8; 3]) -> Color {
    Color::rgb(rgb[0], rgb[1], rgb[2])
}

/// The frame of `capture`'s sentence on a target `size` pixels across and
/// down, and that target. The error says why the positions do not give
/// the sentence.
pub fn frame(capture: &Capture, size: (u32, u32)) -> Result<(Frame, Target), String> {
    let (width, height) = size;
    let placed: Vec<_> = positions(POSITIONS)?
        .into_iter()
        .filter(|position| position.scale == capture.scale)
        .collect();
    if placed.len() != SENTENCE.chars().count() {
        return Err(format!(
            "{} places at scale {}, for {} characters",
            placed.len(),
            capture.scale,
            SENTENCE.chars().count()
        ));
    }
    let glyphs: Vec<Glyph> = SENTENCE
        .char_indices()
        .zip(&placed)
        .map(|((cluster, _), position)| Glyph {
            id: position.glyph,
            font: ResolvedFontId(0),
            cluster,
            x: MARGIN + position.x as f32,
            dx: 0.0,
            dy: 0.0,
            advance: position.advance as f32,
        })
        .collect();
    let end = placed
        .last()
        .map_or(0.0, |last| (last.x + last.advance) as f32);
    let bytes = 0..SENTENCE.len();
    let paint = Paint {
        foreground: color(capture.colours.text),
        background: color(capture.colours.ground),
        underline: None,
        strike_through: false,
    };
    let line = Arc::new(VisualLine {
        bytes: bytes.clone(),
        glyphs,
        width: MARGIN + end,
        height: height as f32,
        baseline: (height - capture.baseline_up) as f32,
    });
    let row = FrameRow::text_row(0.0, 0.0, bytes.clone(), line, vec![(bytes, paint)], 1);
    let font = ResolvedFont {
        data: Arc::new(MONO),
        file: 1,
        index: 0,
        size: POINTS * capture.scale as f32,
        coords: Vec::new(),
        embolden: false,
        skew: None,
    };
    let frame = Frame {
        ground: color(capture.colours.ground),
        views: vec![ViewFrame {
            id: ViewId(1),
            rect: Rect {
                x: 0,
                y: 0,
                width,
                height,
            },
            background: color(capture.colours.ground),
            rows: vec![row],
            status: None,
            cursors: Vec::new(),
            selections: Vec::new(),
            selection: color(capture.colours.ground),
        }],
        generation: 0,
        fonts: Arc::from(vec![font]),
        dividers: Vec::new(),
    };
    let target = Target {
        width,
        height,
        scale: capture.scale as f32,
    };
    Ok((frame, target))
}
