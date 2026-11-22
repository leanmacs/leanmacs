//! The adapter's masks against Core Text's own drawing of the weight
//! sentence (`tests/coretext/`), compiled in.
//!
//! For each capture, the sentence is drawn again from the adapter's masks:
//! each glyph at Core Text's own place (`positions.txt`), floored to Core
//! Text's own grid as the painter floors it (thirds of a pixel at scale 1,
//! halves at scale 2), to a whole pixel and a bin, in the luminance bucket
//! of the capture's text colour; the masks are joined into one picture of
//! coverage and measured against the capture's
//! (`editor_raster_coretext::compare`). Each must be within the thresholds
//! of its scale (`compare::thresholds`), and each control must miss them:
//! a control that passed
//! would show the comparison cannot see what it claims to. On a miss, the
//! same capture is drawn again at Core Text's exact fractions of a pixel
//! (`CoreTextRasterizer::draw_at`) and printed: if that is within and the
//! grid is not, the grid is what differs.

use std::io::Cursor;

use editor_raster::{
    Color, GlyphImage, GlyphKey, GlyphRequest, Rasterize, ResolvedFontId, luminance_bucket,
};
use editor_raster_coretext::CoreTextRasterizer;
use editor_raster_coretext::compare::{
    Comparison, Laid, Position, compare, compose, coverage, coverage_of_grey, on_the_grid,
    positions, thresholds,
};

use crate::contract::mono;

/// Core Text's places of the sentence's glyphs.
const POSITIONS: &str = include_str!("../../../../tests/coretext/positions.txt");

/// The margin left of the line's origin in every capture, in pixels.
const MARGIN: f64 = 16.0;

/// One capture of the sentence.
pub struct Capture {
    /// Its file's name.
    pub name: &'static str,
    /// The file.
    pub bytes: &'static [u8],
    /// The scale it was drawn at.
    pub scale: u32,
    /// The text's colour.
    pub text: Color,
    /// Whether its values are a grey on white (`sentence.png`), and not a
    /// coverage.
    pub grey: bool,
    /// Its baseline, in pixels up from its bottom.
    pub baseline_up: u32,
}

const BLACK: Color = Color::rgb(0, 0, 0);
const LIGHT: Color = Color::rgb(0xd8, 0xde, 0xe9);
const GREY: Color = Color::rgb(0x80, 0x80, 0x80);

/// The five captures.
pub const CAPTURES: [Capture; 5] = [
    Capture {
        name: "sentence.png",
        bytes: include_bytes!("../../../../tests/coretext/sentence.png"),
        scale: 2,
        text: BLACK,
        grey: true,
        baseline_up: 25,
    },
    Capture {
        name: "sentence-dark.png",
        bytes: include_bytes!("../../../../tests/coretext/sentence-dark.png"),
        scale: 2,
        text: LIGHT,
        grey: false,
        baseline_up: 25,
    },
    Capture {
        name: "sentence-14.png",
        bytes: include_bytes!("../../../../tests/coretext/sentence-14.png"),
        scale: 1,
        text: BLACK,
        grey: false,
        baseline_up: 21,
    },
    Capture {
        name: "sentence-14-dark.png",
        bytes: include_bytes!("../../../../tests/coretext/sentence-14-dark.png"),
        scale: 1,
        text: LIGHT,
        grey: false,
        baseline_up: 21,
    },
    Capture {
        name: "sentence-grey.png",
        bytes: include_bytes!("../../../../tests/coretext/sentence-grey.png"),
        scale: 2,
        text: GREY,
        grey: false,
        baseline_up: 25,
    },
];

/// A capture's coverage, and its size.
pub fn read(capture: &Capture) -> (Vec<f32>, (u32, u32)) {
    let mut reader = png::Decoder::new(Cursor::new(capture.bytes))
        .read_info()
        .expect("a PNG file");
    let mut buffer = vec![0; reader.output_buffer_size().expect("a size that fits")];
    let info = reader.next_frame(&mut buffer).expect("the image's data");
    assert_eq!(
        info.color_type,
        png::ColorType::Grayscale,
        "{}",
        capture.name
    );
    assert_eq!(info.bit_depth, png::BitDepth::Eight, "{}", capture.name);
    buffer.truncate(info.buffer_size());
    let values = if capture.grey {
        coverage_of_grey(&buffer)
    } else {
        coverage(&buffer)
    };
    (values, (info.width, info.height))
}

/// Where each glyph goes at `scale`: its place across from the bitmap's
/// left, and its id.
pub fn places(scale: u32) -> Vec<(f64, u32)> {
    let all: Vec<Position> = positions(POSITIONS).expect("Core Text's positions");
    all.iter()
        .filter(|position| position.scale == scale)
        .map(|position| (MARGIN + position.x, position.glyph))
        .collect()
}

/// How the glyphs are placed and drawn.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Placing {
    /// On Core Text's grid, the painter's bins, through the port.
    Bins,
    /// At Core Text's exact fractions of a pixel.
    Exact,
}

/// The sentence of `capture` drawn from the masks of `rasterizer`, in
/// `bucket`, placed as `placing` says.
pub fn drawn(
    rasterizer: &mut CoreTextRasterizer,
    capture: &Capture,
    size: (u32, u32),
    bucket: u8,
    placing: Placing,
) -> Vec<f32> {
    let font = mono(14.0 * capture.scale as f32);
    let baseline = (size.1 - capture.baseline_up) as i32;
    let masks: Vec<(GlyphImage, i32)> = places(capture.scale)
        .into_iter()
        .filter_map(|(x, glyph)| {
            let (whole, image) = match placing {
                Placing::Bins => {
                    let (whole, bin) = on_the_grid(x, capture.scale);
                    let key = GlyphKey {
                        font: ResolvedFontId(0),
                        glyph,
                        bin,
                        subpixel: false,
                        bucket,
                    };
                    let request = GlyphRequest {
                        font: &font,
                        key,
                        hint: false,
                    };
                    (whole, rasterizer.rasterize(&request))
                }
                Placing::Exact => {
                    let whole = x.floor();
                    let image = rasterizer.draw_at(&font, glyph, x - whole, bucket);
                    (whole as i32, image)
                }
            };
            Some((image?, whole))
        })
        .collect();
    let laid: Vec<Laid<'_>> = masks
        .iter()
        .map(|(image, x)| Laid {
            image,
            x: *x,
            baseline,
        })
        .collect();
    compose(&laid, size)
}

/// Compares `capture` with the adapter's drawing of it, smoothed or not,
/// in `bucket`, placed as `placing` says.
pub fn against(capture: &Capture, smoothing: bool, bucket: u8, placing: Placing) -> Comparison {
    let (theirs, size) = read(capture);
    let mut rasterizer = CoreTextRasterizer::new(smoothing);
    let ours = drawn(&mut rasterizer, capture, size, bucket, placing);
    compare(&ours, &theirs)
}

/// Runs the comparisons and the controls: whether every comparison was
/// within its thresholds and every control outside them.
pub fn run() -> bool {
    let mut held = true;
    for scale in [1, 2] {
        let tolerance = thresholds(scale);
        println!(
            "compare: thresholds at scale {scale}: ink {:?}, dark pixels {:?}, worst pixel {:.4}",
            tolerance.ink, tolerance.dark, tolerance.worst
        );
    }
    for capture in &CAPTURES {
        let bucket = luminance_bucket(capture.text);
        let comparison = against(capture, true, bucket, Placing::Bins);
        let verdict = comparison.within(thresholds(capture.scale));
        println!(
            "compare: {} (bucket {bucket}), on Core Text's grid: {comparison}: {}",
            capture.name,
            verdict
                .as_ref()
                .map_or_else(|miss| format!("MISSES ({miss})"), |()| "within".to_owned())
        );
        if verdict.is_err() {
            held = false;
            let exact = against(capture, true, bucket, Placing::Exact);
            println!(
                "compare: {} at Core Text's exact offsets: {exact}: {}",
                capture.name,
                exact
                    .within(thresholds(capture.scale))
                    .map_or_else(|miss| format!("misses ({miss})"), |()| "within".to_owned())
            );
        }
    }
    // The controls, each of which must miss.
    let controls: [(&str, &Capture, bool, u8); 5] = [
        ("(a) light on dark at bucket 0", &CAPTURES[1], true, 0),
        ("(a) light on dark at bucket 0", &CAPTURES[3], true, 0),
        ("(b) black on white not smoothed", &CAPTURES[0], false, 0),
        ("(b) black on white not smoothed", &CAPTURES[2], false, 0),
        (
            "(c) grey at its linear light's bucket 0",
            &CAPTURES[4],
            true,
            0,
        ),
    ];
    for (name, capture, smoothing, bucket) in controls {
        let comparison = against(capture, smoothing, bucket, Placing::Bins);
        let missed = comparison.within(thresholds(capture.scale)).is_err();
        println!(
            "compare: control {name}, {}: {comparison}: {}",
            capture.name,
            if missed {
                "misses, as it must"
            } else {
                "WITHIN: the comparison cannot see it"
            }
        );
        held &= missed;
    }
    held
}
