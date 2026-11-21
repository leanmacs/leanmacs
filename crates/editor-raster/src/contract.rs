//! The contract of the [`Rasterize`] port: the rules the fake and every
//! real adapter are held to, and what the painter assumes of an image.
//!
//! [`check`] asks fresh rasterisers for the glyphs of a [`Fixture`] and
//! returns the properties that fail, each by name with what was seen. The
//! published fake runs it in this crate's tests; swash's adapter runs it in
//! `editor-render-wgpu`'s tests, in the gate; Core Text's runs it on
//! demand, on macOS (`mise run coretext-check`).
//!
//! The fixture is the caller's: a font from its own library and the ids of
//! `H`, `I` and the space, read from that font's own character map. The
//! font is monospaced, so `H` and `I` are both centred in one cell. The
//! rules state relations only (where the ink is, whether two images are
//! equal, which has more ink), never a pixel count, so one contract holds
//! for every font, size and rasteriser.
//!
//! A property goes here when the painter or the cache relies on it; one
//! adapter's own behaviour is that adapter's test.

use std::fmt;

use crate::{GlyphImage, GlyphKey, GlyphRequest, Kind, Rasterize, ResolvedFont, ResolvedFontId};

/// An image's data is its width by its height in its kind's bytes, and a
/// space draws nothing.
pub const SHAPE: &str =
    "an image's data is its width by its height in its kind's bytes, and a space draws nothing";
/// A mask asked for is a mask, and a subpixel mask a subpixel or a plain
/// one.
pub const KINDS: &str = "a mask asked for is a mask, and a subpixel mask a subpixel or a plain one";
/// The same request gives the same image, twice and on a fresh
/// rasteriser.
pub const SAME: &str = "the same request gives the same image, twice and on a fresh rasteriser";
/// Each bin moves the ink right of the bin before it by the difference of
/// their offsets, and keeps it.
pub const BIN: &str = "each bin moves the ink right of the bin before it by the difference of their offsets, and keeps it";
/// A capital stands on the baseline, and glyphs are placed from the pen.
pub const BASELINE: &str = "a capital stands on the baseline, and glyphs are placed from the pen";
/// The luminance changes the image only for a rasteriser that reads it,
/// and lighter text is never thinner.
pub const LUMINANCE: &str = "the luminance changes the image only for a rasteriser that reads it, and lighter text is never thinner";

/// Every property, by name.
pub const PROPERTIES: [&str; 6] = [SHAPE, KINDS, SAME, BIN, BASELINE, LUMINANCE];

/// How far the ink's move from one bin to the next may be from the
/// difference of their offsets ([`GlyphKey::offset`], a twelfth of a
/// pixel), in pixels: under half a twelfth, so that a bin drawn as the bin
/// before it fails, and wide enough for a hinter that moves a stem in
/// steps of its own (swash's hinted moves were 0.061 to 0.115 px a bin).
pub const BIN_TOLERANCE: f64 = 0.04;

/// How much the ink may change across the bins, as a part of the least.
pub const BIN_INK: f64 = 0.03;

/// How much of a capital's ink must be above the baseline.
pub const ABOVE: f64 = 0.95;

/// How far apart the ink centres of `H` and `I` may be, in pixels.
pub const CENTRES: f64 = 1.0;

/// What the contract is run over: the caller's.
#[derive(Debug, Clone)]
pub struct Fixture {
    /// A monospaced font, with its bytes, at the size to check.
    pub font: ResolvedFont,
    /// The id of its `H`.
    pub h: u32,
    /// The id of its `I`.
    pub i: u32,
    /// The id of its space.
    pub space: u32,
    /// Whether the outlines are fitted to the pixel grid.
    pub hint: bool,
}

/// A property that failed, and what was seen.
#[derive(Debug, Clone, PartialEq)]
pub struct Failure {
    /// Which ([`PROPERTIES`]).
    pub property: &'static str,
    /// What was seen.
    pub detail: String,
}

impl fmt::Display for Failure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}: {}", self.property, self.detail)
    }
}

/// The key of `glyph` at `bin`, a mask or a subpixel mask, in `bucket`.
fn key(glyph: u32, bin: u8, subpixel: bool, bucket: u8) -> GlyphKey {
    GlyphKey {
        font: ResolvedFontId(0),
        glyph,
        bin,
        subpixel,
        bucket,
    }
}

/// Asks `rasterizer` for `key` in the fixture's font.
fn ask(rasterizer: &mut dyn Rasterize, fixture: &Fixture, key: GlyphKey) -> Option<GlyphImage> {
    rasterizer.rasterize(&GlyphRequest {
        font: &fixture.font,
        key,
        hint: fixture.hint,
    })
}

/// The coverage of each pixel of a mask, from 0 to 1, with its column and
/// row; nothing for an image of another kind.
fn coverage(image: &GlyphImage) -> impl Iterator<Item = (u32, u32, f64)> + '_ {
    let width = image.width.max(1);
    let data: &[u8] = if image.kind == Kind::Mask {
        &image.data
    } else {
        &[]
    };
    data.iter().enumerate().map(move |(at, value)| {
        let at = at as u32;
        (at % width, at / width, f64::from(*value) / 255.0)
    })
}

/// How much ink a mask has: its coverage summed.
pub fn ink(image: &GlyphImage) -> f64 {
    coverage(image).map(|(_, _, value)| value).sum()
}

/// Where a mask's ink is centred across, in pixels right of the glyph's
/// whole-pixel place (the pen's pixel): `None` for no ink.
pub fn centre(image: &GlyphImage) -> Option<f64> {
    let total = ink(image);
    (total > 0.0).then(|| {
        let moment: f64 = coverage(image)
            .map(|(column, _, value)| (f64::from(column) + 0.5) * value)
            .sum();
        f64::from(image.left) + moment / total
    })
}

/// How much of a mask's ink is in rows above the baseline, as a part of
/// it.
pub fn above_baseline(image: &GlyphImage) -> f64 {
    let total = ink(image);
    if total == 0.0 {
        return 0.0;
    }
    let above: f64 = coverage(image)
        .filter(|(_, row, _)| i64::from(*row) < i64::from(image.top))
        .map(|(_, _, value)| value)
        .sum();
    above / total
}

/// Whether `image`'s data is its width by its height in its kind's bytes.
fn shaped(image: &GlyphImage) -> bool {
    image.data.len() as u64
        == u64::from(image.width) * u64::from(image.height) * u64::from(image.kind.bytes())
}

/// Runs every property over rasterisers `make` makes, fresh where a
/// property says so, on `fixture`: the properties that fail, with what
/// was seen. An empty list is a pass.
pub fn check(make: &mut dyn FnMut() -> Box<dyn Rasterize>, fixture: &Fixture) -> Vec<Failure> {
    let mut failures = Vec::new();
    let mut fail = |property: &'static str, detail: String| {
        failures.push(Failure { property, detail });
    };

    // Shape.
    {
        let mut rasterizer = make();
        for (name, glyph) in [("H", fixture.h), ("I", fixture.i)] {
            for subpixel in [false, true] {
                for bin in 0..crate::SUBPIXEL_BINS {
                    match ask(&mut *rasterizer, fixture, key(glyph, bin, subpixel, 0)) {
                        None => fail(SHAPE, format!("{name} at bin {bin} has no image")),
                        Some(image) if !shaped(&image) => fail(
                            SHAPE,
                            format!(
                                "{name} at bin {bin} is {} by {} of {:?} with {} bytes",
                                image.width,
                                image.height,
                                image.kind,
                                image.data.len()
                            ),
                        ),
                        Some(_) => {}
                    }
                }
            }
        }
        match ask(&mut *rasterizer, fixture, key(fixture.space, 0, false, 0)) {
            None => fail(SHAPE, "the space has no image".to_owned()),
            Some(image) if image.width * image.height != 0 || !image.data.is_empty() => fail(
                SHAPE,
                format!(
                    "the space is {} by {} with {} bytes",
                    image.width,
                    image.height,
                    image.data.len()
                ),
            ),
            Some(_) => {}
        }
    }

    // Kinds.
    {
        let mut rasterizer = make();
        if let Some(image) = ask(&mut *rasterizer, fixture, key(fixture.h, 0, false, 0))
            && image.kind != Kind::Mask
        {
            fail(KINDS, format!("a mask asked for is {:?}", image.kind));
        }
        if let Some(image) = ask(&mut *rasterizer, fixture, key(fixture.h, 0, true, 0))
            && image.kind == Kind::Color
        {
            fail(KINDS, "a subpixel mask asked for is in colour".to_owned());
        }
    }

    // The same twice.
    {
        let mut rasterizer = make();
        for asked in [key(fixture.h, 1, false, 0), key(fixture.i, 2, true, 0)] {
            let first = ask(&mut *rasterizer, fixture, asked);
            let again = ask(&mut *rasterizer, fixture, asked);
            let fresh = ask(&mut *make(), fixture, asked);
            if first != again {
                fail(SAME, format!("{asked:?} twice gives two images"));
            }
            if first != fresh {
                fail(
                    SAME,
                    format!("{asked:?} on a fresh rasteriser gives another image"),
                );
            }
        }
    }

    // A bin moves the image.
    {
        let mut rasterizer = make();
        let bins: Vec<Option<GlyphImage>> = (0..crate::SUBPIXEL_BINS)
            .map(|bin| ask(&mut *rasterizer, fixture, key(fixture.h, bin, false, 0)))
            .collect();
        let centres: Option<Vec<f64>> = bins
            .iter()
            .map(|image| image.as_ref().and_then(centre))
            .collect();
        match centres {
            None => fail(BIN, "H has no ink at some bin".to_owned()),
            Some(centres) => {
                let offset = |bin: u8| f64::from(key(fixture.h, bin, false, 0).offset());
                for (bin, pair) in (1..crate::SUBPIXEL_BINS).zip(centres.windows(2)) {
                    let moved = pair[1] - pair[0];
                    let step = offset(bin) - offset(bin - 1);
                    if (moved - step).abs() > BIN_TOLERANCE {
                        fail(
                            BIN,
                            format!(
                                "from bin {} to {bin} the ink moves {moved:.3} px, not {step:.3} ({centres:.3?})",
                                bin - 1
                            ),
                        );
                    }
                }
                let inks: Vec<f64> = bins.iter().flatten().map(ink).collect();
                let least = inks.iter().copied().fold(f64::INFINITY, f64::min);
                let most = inks.iter().copied().fold(0.0, f64::max);
                if most > least * (1.0 + BIN_INK) {
                    fail(BIN, format!("the ink across the bins is {inks:.1?}"));
                }
            }
        }
    }

    // The baseline and the pen.
    {
        let mut rasterizer = make();
        let h = ask(&mut *rasterizer, fixture, key(fixture.h, 0, false, 0));
        let i = ask(&mut *rasterizer, fixture, key(fixture.i, 0, false, 0));
        match (&h, &i) {
            (Some(h), Some(i)) => {
                let above = above_baseline(h);
                if above < ABOVE {
                    fail(
                        BASELINE,
                        format!("{:.1}% of H's ink is above the baseline", above * 100.0),
                    );
                }
                match (centre(h), centre(i)) {
                    (Some(at_h), Some(at_i)) if (at_h - at_i).abs() <= CENTRES => {}
                    (at_h, at_i) => fail(
                        BASELINE,
                        format!("H's ink is centred at {at_h:.3?} px and I's at {at_i:.3?}"),
                    ),
                }
            }
            _ => fail(BASELINE, "H or I has no image".to_owned()),
        }
    }

    // The luminance.
    {
        let mut rasterizer = make();
        let reads = rasterizer.by_luminance();
        let buckets: Vec<Option<GlyphImage>> = (0..=4)
            .map(|bucket| ask(&mut *rasterizer, fixture, key(fixture.h, 0, false, bucket)))
            .collect();
        if reads {
            let inks: Vec<f64> = buckets.iter().flatten().map(ink).collect();
            if inks.len() != buckets.len() {
                fail(LUMINANCE, "H has no image in some bucket".to_owned());
            } else if inks.windows(2).any(|pair| pair[1] < pair[0]) {
                fail(
                    LUMINANCE,
                    format!("the ink falls as the text gets lighter: {inks:.1?}"),
                );
            }
            if buckets[0] == buckets[4] {
                fail(
                    LUMINANCE,
                    "it reads the luminance, and black and white are one image".to_owned(),
                );
            }
        } else if buckets.windows(2).any(|pair| pair[0] != pair[1]) {
            fail(
                LUMINANCE,
                "it does not read the luminance, and the buckets give different images".to_owned(),
            );
        }
    }

    failures
}

#[cfg(test)]
mod tests;
