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
//! - **A font attribute** (family, weight, size from a face): the faces of
//!   phase 2 resolve to a [`FontId`] per [`FontRun`]; what a font id stands
//!   for is the adapter's table. Nothing here grows.
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

/// Which font: a number the shaper's adapter gives meaning to. Font 0 is
/// the default font.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
pub struct FontId(pub u32);

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

/// What layout needs of the default font before any text is shaped: to
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

    /// The default font's metrics.
    fn metrics(&self) -> Metrics;
}
