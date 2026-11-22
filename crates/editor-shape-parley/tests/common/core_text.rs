//! Core Text's places of the glyphs of a line: the file
//! `tests/coretext/positions.txt` at the repository's root, written by
//! `tools/coretext/capture.swift`, or one the capture tool writes for
//! another font (`mise run coretext-menlo`).
//!
//! A test compiles the file in ([`FIXTURE`]); the example `core_text`
//! includes this module by its path and reads a file it is given.

/// Core Text's places of "the window draws this" in the fixture font, Noto
/// Sans Mono, at 14 points, at scale 1 and 2.
pub const FIXTURE: &str = include_str!("../../../../tests/coretext/positions.txt");

/// The sentence the places are of.
pub const SENTENCE: &str = "the window draws this";

/// One glyph's place on a line, as Core Text gives it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Place {
    /// The scale it was laid out at: 14 points is 14 pixels at 1 and 28 at
    /// 2.
    pub scale: u32,
    /// The glyph's id.
    pub glyph: u32,
    /// Its pen's place across, in device pixels from the line's origin.
    pub x: f64,
    /// Its advance, from the font's own metrics.
    pub advance: f64,
}

/// The places of a file of them: one line a glyph, `<scale> <glyph id> <x
/// px> <y px> <advance px>`, lines that start with `#` and empty ones left
/// out. Refused, with the line, when one is not of that form.
pub fn places(text: &str) -> Result<Vec<Place>, String> {
    text.lines()
        .filter(|line| !line.trim().is_empty() && !line.starts_with('#'))
        .map(|line| {
            let refused = || format!("not a place: {line:?}");
            let fields: Vec<&str> = line.split_whitespace().collect();
            let [scale, glyph, x, _y, advance] = fields[..] else {
                return Err(refused());
            };
            Ok(Place {
                scale: scale.parse().map_err(|_| refused())?,
                glyph: glyph.parse().map_err(|_| refused())?,
                x: x.parse().map_err(|_| refused())?,
                advance: advance.parse().map_err(|_| refused())?,
            })
        })
        .collect()
}

/// The places of `all` at `scale`, in order.
pub fn at_scale(all: &[Place], scale: u32) -> Vec<Place> {
    all.iter()
        .copied()
        .filter(|place| place.scale == scale)
        .collect()
}

/// How one glyph of ours stands against Core Text's.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Error {
    /// Which glyph of the line, from 0.
    pub index: usize,
    /// Whether its id is Core Text's.
    pub same_glyph: bool,
    /// Our pen's place less Core Text's, in pixels.
    pub across: f64,
}

/// How each glyph of `ours` (id, pen x) stands against `theirs`, and how
/// the line's end does (our last pen place plus its advance, less Core
/// Text's): `None` when the two have not as many glyphs.
pub fn errors(ours: &[(u32, f64, f64)], theirs: &[Place]) -> Option<(Vec<Error>, f64)> {
    if ours.len() != theirs.len() || ours.is_empty() {
        return None;
    }
    let each = ours
        .iter()
        .zip(theirs)
        .enumerate()
        .map(|(index, ((glyph, x, _), place))| Error {
            index,
            same_glyph: *glyph == place.glyph,
            across: x - place.x,
        })
        .collect();
    let (last, place) = (ours[ours.len() - 1], theirs[theirs.len() - 1]);
    let end = (last.1 + last.2) - (place.x + place.advance);
    Some((each, end))
}

/// The largest distance across of `errors` and of the line's `end`.
pub fn worst(errors: &[Error], end: f64) -> f64 {
    errors
        .iter()
        .map(|error| error.across.abs())
        .fold(end.abs(), f64::max)
}
