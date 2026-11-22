//! How the adapter's masks are compared with Core Text's own drawing of a
//! line: the masks laid where Core Text lays its glyphs, on its own grid
//! ([`on_the_grid`]), which is where the painter lays them too, joined
//! into one picture of coverage, and measured against the capture's.
//!
//! The example `check` runs it on demand on macOS, over the captures under
//! `tests/coretext/`; its rules are tested here, in the gate, on small
//! images made in code.

use editor_raster::{GlyphImage, Kind, SUBPIXEL_BINS};

/// How far under a line of the grid a place may be and still be on it, in
/// pixels: more than the error of a sum of advances, and far less than any
/// step of the grid.
pub const ON_THE_LINE: f64 = 1.0 / 1024.0;

/// The coverage of each pixel of a capture whose bytes are coverage, 255
/// being full ink: from 0 to 1.
pub fn coverage(capture: &[u8]) -> Vec<f32> {
    capture
        .iter()
        .map(|value| f32::from(*value) / 255.0)
        .collect()
}

/// The coverage of each pixel of a capture whose bytes are a grey drawn
/// on white, 255 being the white ground.
pub fn coverage_of_grey(capture: &[u8]) -> Vec<f32> {
    capture
        .iter()
        .map(|value| f32::from(255 - *value) / 255.0)
        .collect()
}

/// Where Core Text puts a glyph whose place is `x` pixels across at
/// `scale`, drawn as native apps draw (`CTLineDraw` with the context's
/// default subpixel flags): `x` floored to `max(1, 4 - scale)` places a
/// pixel, thirds of a pixel at scale 1, halves at scale 2 and whole
/// pixels from scale 3, as the whole pixel it falls in and the bin of the
/// place past that pixel's left edge, in twelfths of a pixel. A place
/// within [`ON_THE_LINE`] under a line is on it.
///
/// It is Core Text's rule, measured on macOS 27.2.1 (2026-11-20) by
/// drawing one glyph across a pixel in steps of 1/400: its image changed
/// at 0.3325 and 0.6675 px at scale 1, at 0.5 px at scale 2, and only at
/// whole pixels at scale 3. The painter's rule is the same
/// (`editor-render-wgpu`'s `glyphs::bin_of`), and its placement test holds
/// it to Core Text's positions.
pub fn on_the_grid(x: f64, scale: u32) -> (i32, u8) {
    let places = 4_u32.saturating_sub(scale.max(1)).max(1) as u8;
    let lines = ((x + ON_THE_LINE) * f64::from(places)).floor() as i64;
    let per = i64::from(places);
    let bin = lines.rem_euclid(per) as u8 * (SUBPIXEL_BINS / places);
    (lines.div_euclid(per) as i32, bin)
}

/// One glyph's place on a line, as Core Text gives it
/// (`tests/coretext/positions.txt`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Position {
    /// The scale it was laid out at.
    pub scale: u32,
    /// The glyph's id.
    pub glyph: u32,
    /// Its place across, in device pixels from the line's origin.
    pub x: f64,
    /// Its place up.
    pub y: f64,
    /// Its advance, from the font's metrics.
    pub advance: f64,
}

/// The positions of a file of them: one line a glyph, `<scale> <glyph id>
/// <x px> <y px> <advance px>`, lines that start with `#` and empty ones
/// left out. Refused, with the line, when one is not of that form.
pub fn positions(text: &str) -> Result<Vec<Position>, String> {
    text.lines()
        .filter(|line| !line.trim().is_empty() && !line.starts_with('#'))
        .map(|line| {
            let fields: Vec<&str> = line.split_whitespace().collect();
            let refused = || format!("not a position: {line:?}");
            let [scale, glyph, x, y, advance] = fields[..] else {
                return Err(refused());
            };
            let number = |field: &str| field.parse::<f64>().map_err(|_| refused());
            Ok(Position {
                scale: scale.parse().map_err(|_| refused())?,
                glyph: glyph.parse().map_err(|_| refused())?,
                x: number(x)?,
                y: number(y)?,
                advance: number(advance)?,
            })
        })
        .collect()
}

/// A glyph's mask and where it is laid: the whole pixel of its place
/// across, and the row of its baseline, from the picture's top left.
#[derive(Debug, Clone, Copy)]
pub struct Laid<'a> {
    /// The mask.
    pub image: &'a GlyphImage,
    /// The whole pixel its place is in, across.
    pub x: i32,
    /// The row its baseline is on, down from the top.
    pub baseline: i32,
}

/// The picture of `laid`, `size` pixels across and down: each mask at its
/// whole pixel plus its own offsets, and where two overlap, joined as
/// `1 - (1 - a)(1 - b)`. Only masks are laid; any other kind is left out.
pub fn compose(laid: &[Laid<'_>], size: (u32, u32)) -> Vec<f32> {
    let (width, height) = (size.0 as i32, size.1 as i32);
    let mut picture = vec![0.0_f32; (width * height) as usize];
    for glyph in laid.iter().filter(|glyph| glyph.image.kind == Kind::Mask) {
        let image = glyph.image;
        let (left, top) = (glyph.x + image.left, glyph.baseline - image.top);
        for (at, value) in image.data.iter().enumerate() {
            let (column, row) = (
                at as i32 % image.width as i32,
                at as i32 / image.width as i32,
            );
            let (x, y) = (left + column, top + row);
            if (0..width).contains(&x) && (0..height).contains(&y) {
                let pixel = &mut picture[(y * width + x) as usize];
                let covered = f32::from(*value) / 255.0;
                *pixel = 1.0 - (1.0 - *pixel) * (1.0 - covered);
            }
        }
    }
    picture
}

/// What is measured of a picture of coverage on its own.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Measure {
    /// Its coverage, summed.
    pub ink: f64,
}

impl Measure {
    /// The measure of `picture`.
    pub fn of(picture: &[f32]) -> Measure {
        Measure {
            ink: picture.iter().map(|value| f64::from(*value)).sum(),
        }
    }
}

/// How far from half covered a pixel must be, in both pictures, for its
/// darkness to be counted: one 255th. A capture of light text on a dark
/// ground has its coverage rebuilt from 8-bit channels, and lands pixels
/// on the half line that a mask draws a 255th to the other side of it.
pub const UNDECIDED: f32 = 1.0 / 255.0;

/// Whether a pixel of `coverage` is dark: more than half covered.
fn dark(coverage: f32) -> bool {
    coverage > 0.5
}

/// Whether a pixel of `coverage` is clear of the half line by more than
/// [`UNDECIDED`].
fn decided(coverage: f32) -> bool {
    (coverage - 0.5).abs() > UNDECIDED
}

/// How one picture of coverage compares with another of the same size.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Comparison {
    /// The first's ink as a part of the second's.
    pub ink: f64,
    /// The first's dark pixels as a part of the second's, counted only
    /// where both are more than [`UNDECIDED`] from half covered.
    pub dark: f64,
    /// The largest difference of coverage at any pixel.
    pub worst: f32,
}

/// How far a comparison may go and still pass.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Tolerance {
    /// The least and the most the ink may be, as a part.
    pub ink: (f64, f64),
    /// The least and the most the dark pixels may be, as a part.
    pub dark: (f64, f64),
    /// The largest difference of coverage allowed at any pixel.
    pub worst: f32,
}

/// The thresholds a capture at scale 2 is held to: the ink and the dark
/// pixels within half a percent, and no pixel more than 2 of 255 off. The
/// masks are laid on Core Text's own grid, so they should be Core Text's
/// own pixels: measured on 2026-11-20, `sentence.png` was, to the byte.
pub const AT_SCALE_TWO: Tolerance = Tolerance {
    ink: (0.995, 1.005),
    dark: (0.995, 1.005),
    worst: 2.0 / 255.0,
};

/// The thresholds a capture at scale 1 is held to: as at scale 2, but no
/// pixel more than 0.08 off. Core Text's own line drawing puts a few
/// glyphs a little off the thirds its grid is measured at: drawn at
/// exact thirds, the masks of `sentence-14.png` and
/// `sentence-14-dark.png` were 0.020 and 0.071 off at the worst pixel,
/// and the best fit of the two places, 86/256 and 170/256 of a pixel, was
/// no better than 0.016 and 0.071 (2026-11-20, macOS 27.2.1).
pub const AT_SCALE_ONE: Tolerance = Tolerance {
    worst: 0.08,
    ..AT_SCALE_TWO
};

/// The thresholds a capture drawn at `scale` is held to.
pub fn thresholds(scale: u32) -> Tolerance {
    if scale <= 1 {
        AT_SCALE_ONE
    } else {
        AT_SCALE_TWO
    }
}

/// How `ours` compares with `theirs`, two pictures of coverage of the
/// same size.
pub fn compare(ours: &[f32], theirs: &[f32]) -> Comparison {
    let (one, other) = (Measure::of(ours), Measure::of(theirs));
    let counted: Vec<(f32, f32)> = ours
        .iter()
        .zip(theirs)
        .filter(|(a, b)| decided(**a) && decided(**b))
        .map(|(a, b)| (*a, *b))
        .collect();
    let darks = |pick: fn(&(f32, f32)) -> f32| {
        counted.iter().filter(|pair| dark(pick(pair))).count() as f64
    };
    Comparison {
        ink: one.ink / other.ink,
        dark: darks(|pair| pair.0) / darks(|pair| pair.1),
        worst: ours
            .iter()
            .zip(theirs)
            .map(|(a, b)| (a - b).abs())
            .fold(0.0, f32::max),
    }
}

impl Comparison {
    /// Whether it is within `tolerance`: a sentence that says what is not.
    pub fn within(&self, tolerance: Tolerance) -> Result<(), String> {
        let mut misses = Vec::new();
        if !(tolerance.ink.0..=tolerance.ink.1).contains(&self.ink) {
            misses.push(format!("ink x{:.4}", self.ink));
        }
        if !(tolerance.dark.0..=tolerance.dark.1).contains(&self.dark) {
            misses.push(format!("dark pixels x{:.4}", self.dark));
        }
        // A difference of whole 255ths comes out of f32 a hair either side
        // of its value: a millionth is far less than one 255th.
        if self.worst > tolerance.worst + 1e-6 {
            misses.push(format!("a pixel {:.3} off", self.worst));
        }
        if misses.is_empty() {
            Ok(())
        } else {
            Err(misses.join(", "))
        }
    }
}

impl std::fmt::Display for Comparison {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "ink x{:.4}, dark pixels x{:.4}, worst pixel {:.3}",
            self.ink, self.dark, self.worst
        )
    }
}

#[cfg(test)]
mod tests {
    use editor_raster::{GlyphImage, Kind};

    use super::{
        AT_SCALE_ONE, AT_SCALE_TWO, Laid, Measure, Position, compare, compose, coverage,
        coverage_of_grey, on_the_grid, positions, thresholds,
    };

    /// A mask `width` by `height` of `value` everywhere, its top `top`
    /// above the baseline and its left at the pen.
    fn block(width: u32, height: u32, value: u8, top: i32) -> GlyphImage {
        GlyphImage {
            kind: Kind::Mask,
            width,
            height,
            left: 0,
            top,
            data: vec![value; (width * height) as usize],
        }
    }

    /// A picture of a stem: 20 rows of 4 full columns between half-covered
    /// edge columns, on a ground of 12 columns.
    fn stem() -> Vec<f32> {
        let row = [0.0, 0.0, 0.5, 1.0, 1.0, 1.0, 1.0, 0.5, 0.0, 0.0, 0.0, 0.0];
        row.iter().copied().cycle().take(row.len() * 20).collect()
    }

    #[test]
    fn a_capture_is_read_as_coverage_either_way_up() {
        assert_eq!(coverage(&[0, 255, 51]), vec![0.0, 1.0, 0.2]);
        assert_eq!(coverage_of_grey(&[255, 0, 204]), vec![0.0, 1.0, 0.2]);
    }

    #[test]
    fn a_place_is_floored_to_thirds_at_scale_one_halves_at_two_and_pixels_from_three() {
        // In twelfths of a pixel: a third is bin 4, a half bin 6.
        for (x, scale, expected) in [
            (16.0, 1, (16, 0)),
            (16.3, 1, (16, 0)),
            (24.4, 1, (24, 4)),
            (24.8, 1, (24, 8)),
            (-0.25, 1, (-1, 8)),
            (16.8, 2, (16, 6)),
            (33.6, 2, (33, 6)),
            (50.4, 2, (50, 0)),
            (50.9, 3, (50, 0)),
            (50.9, 4, (50, 0)),
            (16.4, 0, (16, 4)),
        ] {
            assert_eq!(on_the_grid(x, scale), expected, "{x} at {scale}");
        }
    }

    #[test]
    fn a_place_a_hair_under_a_line_is_on_it() {
        // Under the line by far less than 1/1024 of a pixel, it is on it;
        // by more, it is not.
        assert_eq!(on_the_grid(25.0 + 1.0 / 3.0 - 1e-12, 1), (25, 4));
        assert_eq!(on_the_grid(16.5 - 1e-9, 2), (16, 6));
        assert_eq!(on_the_grid(25.0 + 1.0 / 3.0 - 1.0 / 512.0, 1), (25, 0));
    }

    #[test]
    fn a_capture_at_scale_one_may_be_further_off_at_its_worst_pixel() {
        assert_eq!(thresholds(2), AT_SCALE_TWO);
        assert_eq!(thresholds(1), AT_SCALE_ONE);
        assert_eq!(AT_SCALE_TWO.worst, 2.0 / 255.0);
        assert_eq!(AT_SCALE_ONE.worst, 0.08);
        assert_eq!(AT_SCALE_ONE.ink, AT_SCALE_TWO.ink);
        assert_eq!(AT_SCALE_ONE.dark, (0.995, 1.005));
    }

    #[test]
    fn a_pixel_a_255th_either_side_of_half_is_not_counted_dark_or_light() {
        // The stem, with one of its full columns 128 in ours and 127 in
        // theirs at every row: 20 pixels either side of the half line.
        let mut ours = stem();
        let mut theirs = stem();
        for row in 0..20 {
            ours[row * 12 + 3] = 128.0 / 255.0;
            theirs[row * 12 + 3] = 127.0 / 255.0;
        }
        let comparison = compare(&ours, &theirs);
        assert_eq!(comparison.dark, 1.0, "{comparison}");
        assert_eq!(comparison.within(AT_SCALE_TWO), Ok(()));
        // Two 255ths from half, it is counted.
        for row in 0..20 {
            ours[row * 12 + 3] = 129.0 / 255.0;
            theirs[row * 12 + 3] = 126.0 / 255.0;
        }
        let comparison = compare(&ours, &theirs);
        assert!(comparison.dark > 1.2, "{comparison}");
    }

    #[test]
    fn a_file_of_positions_is_read_line_by_line() {
        let text = "# a comment\n1 85 0.0 0.0 8.4\n\n2 73 16.8 -0.5 16.8\n";
        assert_eq!(
            positions(text),
            Ok(vec![
                Position {
                    scale: 1,
                    glyph: 85,
                    x: 0.0,
                    y: 0.0,
                    advance: 8.4
                },
                Position {
                    scale: 2,
                    glyph: 73,
                    x: 16.8,
                    y: -0.5,
                    advance: 16.8
                },
            ])
        );
        assert!(positions("1 85 0.0 0.0").is_err());
        assert!(positions("1 x 0.0 0.0 8.4").is_err());
    }

    #[test]
    fn identical_pictures_pass() {
        let comparison = compare(&stem(), &stem());
        assert_eq!(comparison.ink, 1.0);
        assert_eq!(comparison.dark, 1.0);
        assert_eq!(comparison.worst, 0.0);
        assert_eq!(comparison.within(AT_SCALE_TWO), Ok(()));
    }

    #[test]
    fn a_picture_a_column_heavier_fails_on_ink() {
        // The stem with its right edge column full and the next half.
        let heavier: Vec<f32> = stem()
            .chunks(12)
            .flat_map(|row| {
                let mut row = row.to_vec();
                row[7] = 1.0;
                row[8] = 0.5;
                row
            })
            .collect();
        let comparison = compare(&heavier, &stem());
        assert!(comparison.ink > 1.005, "{comparison}");
        assert!(
            comparison
                .within(AT_SCALE_TWO)
                .is_err_and(|miss| miss.contains("ink")),
            "{comparison}"
        );
    }

    #[test]
    fn one_pixel_off_by_three_tenths_fails_on_the_worst_pixel() {
        let mut off = stem();
        off[2] = 0.8;
        let comparison = compare(&off, &stem());
        let miss = comparison.within(AT_SCALE_TWO).expect_err("a pixel off");
        assert!(miss.contains("pixel") && !miss.contains("ink"), "{miss}");
    }

    #[test]
    fn a_pixel_two_of_255_off_passes_and_three_does_not() {
        let off = |by: f32| {
            // A full pixel of the stem, a little lighter: still dark.
            let mut picture = stem();
            picture[3] -= by / 255.0;
            compare(&picture, &stem())
        };
        assert_eq!(off(2.0).within(AT_SCALE_TWO), Ok(()), "{}", off(2.0));
        assert!(off(3.0).within(AT_SCALE_TWO).is_err(), "{}", off(3.0));
    }

    #[test]
    fn two_overlapping_half_covers_compose_to_three_quarters() {
        let half = block(2, 1, 128, 1);
        let laid = [
            Laid {
                image: &half,
                x: 0,
                baseline: 1,
            },
            Laid {
                image: &half,
                x: 1,
                baseline: 1,
            },
        ];
        let picture = compose(&laid, (3, 1));
        let half = 128.0 / 255.0;
        let expected = [half, 1.0 - (1.0 - half) * (1.0 - half), half];
        for (got, wanted) in picture.iter().zip(expected) {
            assert!((got - wanted).abs() < 1e-6, "{picture:?}");
        }
        assert!((picture[1] - 0.75).abs() < 0.01);
    }

    #[test]
    fn a_mask_is_laid_at_its_whole_pixel_and_offsets_and_clipped_to_the_picture() {
        let image = GlyphImage {
            left: -1,
            ..block(3, 2, 255, 2)
        };
        let laid = [Laid {
            image: &image,
            x: 1,
            baseline: 3,
        }];
        // Its left is at 1 - 1 = 0, and its top 2 above row 3: rows 1 and 2.
        let picture = compose(&laid, (4, 4));
        let inked: Vec<usize> = (0..16).filter(|at| picture[*at] > 0.0).collect();
        assert_eq!(inked, vec![4, 5, 6, 8, 9, 10]);
        // Laid past the picture's edge, what is outside is left out.
        let edge = [Laid {
            image: &image,
            x: 3,
            baseline: 1,
        }];
        assert_eq!(Measure::of(&compose(&edge, (4, 4))).ink, 2.0);
    }
}
