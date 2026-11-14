//! The `Shaper` port: a run of styled text in, positioned glyphs and the
//! visual lines they break into out.
//!
//! Measuring and breaking are one operation behind this port, never split:
//! layout never sums advances to decide where a line wraps. A shaper shapes
//! a line once ([`Shaper::shape`]) and the value it gives back is kept; a
//! change of width breaks the kept value again ([`ShapedLine::break_lines`])
//! without shaping it again.
//!
//! What a shaper is handed is one segment of one buffer row, after the
//! display layers below it: no tab (the tab layer has expanded it into
//! spaces, `docs/design/text-and-display.md`) and no line break. Byte
//! offsets in and out are offsets of [`ShapeInput::text`].
//!
//! # Where an addition goes
//!
//! - **A font attribute** (a family, a size, a weight, a slant, a line
//!   height; later a stretch or a variation axis): a field of [`FontSpec`],
//!   the port's term for a font. Layout resolves the faces over a run to
//!   a spec ([`face`](crate::face)), asks the shaper for the spec's
//!   [`FontId`] ([`Shaper::font`]) and names the run's font by it; the
//!   table from an id to its spec is the adapter's. Only what changes a
//!   glyph or a line's height is a font attribute: colours, underlines and
//!   strike-through are paint, and never reach a shaper.
//! - **A shaping feature** (an OpenType feature, a language): data on
//!   [`ShapeInput`] or on [`FontRun`], read by the adapter.
//! - **A metric layout needs** of a font: a field of [`Metrics`].
//! - **What a renderer needs of the font a glyph is drawn in** (its bytes,
//!   its face, a variation, a synthesis): a field of [`ResolvedFont`].
//!   The font a glyph is drawn in is not the font its run asked for: a
//!   glyph names a [`ResolvedFontId`], an entry of [`Shaper::resolved`].
//! - **Where a glyph's outline is drawn**, when that is not its pen
//!   position: [`Glyph::dx`] and [`Glyph::dy`].
//!
//! # The published fake and the contract
//!
//! [`fake::CellShaper`] gives every glyph of a font the same advance, so
//! layout's tests are exact. [`contract`] is the list of rules the fake and
//! every real adapter (Parley, the display pipeline's phase 3) are held to.

use std::fmt;
use std::ops::Range;
use std::sync::Arc;

pub mod contract;
pub mod fake;
#[cfg(test)]
pub(crate) mod scripted;

/// Which font a run asks for: a number the shaper's adapter gives a
/// [`FontSpec`] ([`Shaper::font`]). Font 0 is the default font,
/// [`FontSpec::default`]. It is what a run is shaped in and what
/// [`Shaper::metrics`] is asked about; the font a glyph is drawn in is a
/// [`ResolvedFontId`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
pub struct FontId(pub u32);

/// Which font a glyph is drawn in: an index into the table the shaper
/// describes its fonts in ([`Shaper::resolved`]). It is not the font the
/// glyph's run asked for ([`FontId`]): a character the font asked for has
/// no glyph for is drawn in a fallback font, and two specs that differ
/// only in line height are drawn in one font.
///
/// An id means one font for one generation of its shaper
/// ([`Shaper::generation`]), and may mean another under the next.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
pub struct ResolvedFontId(pub u32);

/// A font a glyph is drawn in, with what a rasteriser needs to draw it:
/// one face of one font file, at a size.
///
/// Two resolved fonts are equal when they name the same face of the same
/// file ([`ResolvedFont::file`]) with the same size, coordinates and
/// synthesis. The bytes are never compared, and `Debug` prints their
/// length in place of them.
#[derive(Clone)]
pub struct ResolvedFont {
    /// The bytes of the font file; none for a shaper that draws from no
    /// file, as the fake.
    pub data: Arc<dyn AsRef<[u8]> + Send + Sync>,
    /// The shaper's number for the file: within one shaper, two resolved
    /// fonts of one number have the same bytes, so they are compared
    /// without reading them.
    pub file: u64,
    /// Which face of the file, for a file that holds several.
    pub index: u32,
    /// The size glyphs are drawn at, in pixels.
    pub size: f32,
    /// The face's normalised variation coordinates, one for each axis, as
    /// the font format's 2.14 fixed-point numbers; none for a face that
    /// does not vary.
    pub coords: Vec<i16>,
    /// Whether the outlines are to be made bolder, for a weight the family
    /// has no face of.
    pub embolden: bool,
    /// How far the outlines are to be slanted, in degrees, for a slant the
    /// family has no face of.
    pub skew: Option<f32>,
}

/// Equal by what is named and never by the bytes, which
/// [`ResolvedFont::file`] stands for.
impl PartialEq for ResolvedFont {
    fn eq(&self, other: &Self) -> bool {
        self.file == other.file
            && self.index == other.index
            && self.size == other.size
            && self.coords == other.coords
            && self.embolden == other.embolden
            && self.skew == other.skew
    }
}

/// Every field as it is, but for the bytes: `data` is printed as their
/// length, `5 bytes`.
impl fmt::Debug for ResolvedFont {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let bytes = (*self.data).as_ref().len();
        formatter
            .debug_struct("ResolvedFont")
            .field("data", &format_args!("{bytes} bytes"))
            .field("file", &self.file)
            .field("index", &self.index)
            .field("size", &self.size)
            .field("coords", &self.coords)
            .field("embolden", &self.embolden)
            .field("skew", &self.skew)
            .finish()
    }
}

/// A length in 64ths of a physical pixel: a whole number, so it is exact as
/// an `f32` and can be hashed and compared.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Length(pub u32);

impl Length {
    /// `pixels` whole pixels.
    pub const fn pixels(pixels: u32) -> Self {
        Self(pixels.saturating_mul(64))
    }

    /// The length in pixels.
    pub fn as_pixels(self) -> f32 {
        self.0 as f32 / 64.0
    }
}

/// The size of a font whose face sets none: 16 pixels.
pub const BASE_SIZE: Length = Length::pixels(16);

/// A font's weight, from 1 to 1000: 400 is normal and 700 bold.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Weight(pub u16);

impl Weight {
    /// The normal weight.
    pub const NORMAL: Self = Self(400);
    /// The bold weight.
    pub const BOLD: Self = Self(700);
}

/// A font's slant.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum Slant {
    /// Upright.
    #[default]
    Upright,
    /// The family's italic design.
    Italic,
    /// The upright design, slanted.
    Oblique,
}

/// How tall the lines of a font are.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LineHeight {
    /// A multiple of the font's own line height at its size, in 64ths: 64
    /// is the font's own.
    Multiple(u32),
    /// A height in pixels, whatever the font's own.
    Pixels(Length),
}

impl LineHeight {
    /// The font's own line height.
    pub const OWN: Self = Self::Multiple(64);
}

/// A font, in the port's terms: what a run of text is shaped in. Two runs
/// are in one font exactly when their specs are equal. The line height is
/// part of it, since it changes how tall a line of the font is.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct FontSpec {
    /// The family's name; `None` is the adapter's default family.
    pub family: Option<String>,
    /// The size.
    pub size: Length,
    /// The weight.
    pub weight: Weight,
    /// The slant.
    pub slant: Slant,
    /// The line height.
    pub line_height: LineHeight,
}

/// The default font, font 0: the default family at [`BASE_SIZE`], of
/// normal weight, upright, with lines of its own height.
impl Default for FontSpec {
    fn default() -> Self {
        Self {
            family: None,
            size: BASE_SIZE,
            weight: Weight::NORMAL,
            slant: Slant::Upright,
            line_height: LineHeight::OWN,
        }
    }
}

/// A run of the input's bytes shaped in one font.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct FontRun {
    /// The bytes of [`ShapeInput::text`] the run covers.
    pub bytes: Range<usize>,
    /// The font they are shaped in.
    pub font: FontId,
}

/// What a shaper is asked to shape: one segment of a buffer row.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub struct ShapeInput {
    /// The text: no tab and no line break.
    pub text: String,
    /// Its font runs, in order. A byte no run covers is in the default
    /// font, and so is an empty text with no run; an empty text with a run
    /// takes that run's font for its height.
    pub runs: Vec<FontRun>,
}

/// One positioned glyph.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Glyph {
    /// The glyph's id in its font.
    pub id: u32,
    /// The font it is drawn in: an entry of [`Shaper::resolved`].
    pub font: ResolvedFontId,
    /// The byte offset in [`ShapeInput::text`] of the cluster it draws.
    pub cluster: usize,
    /// Where its pen position is, in pixels from its visual line's left
    /// edge: where it starts for a cursor, a selection and a click.
    pub x: f32,
    /// How far right of its pen position its outline is drawn, in pixels.
    /// Only a renderer reads it: no position is found by it.
    pub dx: f32,
    /// How far below the baseline its outline is drawn, in pixels. Only a
    /// renderer reads it.
    pub dy: f32,
    /// How far across it is: how far it moves the pen.
    pub advance: f32,
}

/// One visual line: the glyphs of a run of the input placed on one row.
#[derive(Debug, Clone, PartialEq)]
pub struct VisualLine {
    /// The bytes of [`ShapeInput::text`] it holds.
    pub bytes: Range<usize>,
    /// Its glyphs, left to right.
    pub glyphs: Vec<Glyph>,
    /// How far across its glyphs reach.
    pub width: f32,
    /// How far down it is.
    pub height: f32,
    /// The baseline, from its top.
    pub baseline: f32,
}

/// What layout needs of a font before any text is shaped in it: to
/// estimate a row it has not laid out, and to size a cursor where there is
/// no glyph.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Metrics {
    /// The advance of a space.
    pub advance: f32,
    /// The height of a line.
    pub line_height: f32,
}

/// A shaped line, kept so that a change of width breaks it again without
/// shaping it again.
pub trait ShapedLine {
    /// The visual lines it breaks into at `width` pixels, or into one when
    /// `width` is `None`. Every visual line holds at least one cluster, so
    /// a cluster wider than `width` is a line of its own.
    fn break_lines(&self, width: Option<f32>) -> Vec<VisualLine>;
}

/// The port: shapes a segment of text.
pub trait Shaper {
    /// What it keeps of a shaped line.
    type Shaped: ShapedLine + Send + Sync;

    /// Shapes `input`.
    fn shape(&self, input: &ShapeInput) -> Self::Shaped;

    /// A number that changes whenever what [`Shaper::shape`] would give
    /// changes for the same input: fonts loaded, a size changed. Layout
    /// shapes again every line it shaped under another generation. A
    /// [`ResolvedFontId`] is valid for one generation: under another the
    /// same number may be another font.
    fn generation(&self) -> u64;

    /// The fonts glyphs are drawn in, by [`ResolvedFontId`]: every glyph
    /// of a shaped line names an entry of the table as it is when
    /// [`Shaper::shape`] returns, whenever the line is broken. Within one
    /// generation the table only grows and an entry never changes, so a
    /// table read later describes every glyph shaped before it.
    fn resolved(&self) -> Arc<[ResolvedFont]>;

    /// The id of the font `spec`: equal specs have one id and different
    /// specs different ids, for the shaper's life, and
    /// [`FontSpec::default`] is font 0.
    fn font(&self, spec: &FontSpec) -> FontId;

    /// The metrics of `font`, an id [`Shaper::font`] gave or font 0.
    fn metrics(&self, font: FontId) -> Metrics;
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::ResolvedFont;

    /// A resolved font of the file numbered `file`, whose bytes are
    /// `bytes`, at 16 pixels.
    fn font(file: u64, bytes: &[u8]) -> ResolvedFont {
        ResolvedFont {
            data: Arc::new(bytes.to_vec()),
            file,
            index: 0,
            size: 16.0,
            coords: vec![],
            embolden: false,
            skew: None,
        }
    }

    #[test]
    fn resolved_fonts_are_equal_by_what_they_name_and_never_by_their_bytes() {
        let plain = font(1, b"abc");
        assert_eq!(plain, font(1, b"abc"));
        // The bytes are not read: the file's number stands for them.
        assert_eq!(plain, font(1, b"other bytes"));
        assert_ne!(plain, font(2, b"abc"));
        // Each other field alone tells two apart.
        let others = [
            ResolvedFont {
                index: 1,
                ..plain.clone()
            },
            ResolvedFont {
                size: 24.0,
                ..plain.clone()
            },
            ResolvedFont {
                coords: vec![0],
                ..plain.clone()
            },
            ResolvedFont {
                embolden: true,
                ..plain.clone()
            },
            ResolvedFont {
                skew: Some(14.0),
                ..plain.clone()
            },
        ];
        for other in others {
            assert_ne!(plain, other);
            assert_eq!(other, other.clone());
        }
    }

    #[test]
    fn a_resolved_font_is_printed_with_the_length_of_its_bytes() {
        let printed = format!(
            "{:?}",
            ResolvedFont {
                coords: vec![3],
                skew: Some(14.0),
                ..font(7, b"abcde")
            }
        );
        assert_eq!(
            printed,
            "ResolvedFont { data: 5 bytes, file: 7, index: 0, size: 16.0, coords: [3], \
             embolden: false, skew: Some(14.0) }"
        );
    }
}
