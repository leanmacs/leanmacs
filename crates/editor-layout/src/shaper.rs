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
//!   table from an id to its spec is the adapter's. Only what changes a glyph or a line's height is a font
//!   attribute: colours, underlines and strike-through are paint, and never
//!   reach a shaper.
//! - **A shaping feature** (an OpenType feature, a language): data on
//!   [`ShapeInput`] or on [`FontRun`], read by the adapter.
//! - **A metric layout needs** of a font: a field of [`Metrics`].
//!
//! # The published fake and the contract
//!
//! [`fake::CellShaper`] gives every glyph of a font the same advance, so
//! layout's tests are exact. [`contract`] is the list of rules the fake and
//! every real adapter (Parley, the display pipeline's phase 3) are held to.

use std::ops::Range;

pub mod contract;
pub mod fake;

/// Which font: a number the shaper's adapter gives a [`FontSpec`]
/// ([`Shaper::font`]). Font 0 is the default font, [`FontSpec::default`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
pub struct FontId(pub u32);

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
    /// Its font.
    pub font: FontId,
    /// The byte offset in [`ShapeInput::text`] of the cluster it draws.
    pub cluster: usize,
    /// Where it starts, in pixels from its visual line's left edge.
    pub x: f32,
    /// How far across it is.
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
    /// shapes again every line it shaped under another generation.
    fn generation(&self) -> u64;

    /// The id of the font `spec`: equal specs have one id and different
    /// specs different ids, for the shaper's life, and
    /// [`FontSpec::default`] is font 0.
    fn font(&self, spec: &FontSpec) -> FontId;

    /// The metrics of `font`, an id [`Shaper::font`] gave or font 0.
    fn metrics(&self, font: FontId) -> Metrics;
}
