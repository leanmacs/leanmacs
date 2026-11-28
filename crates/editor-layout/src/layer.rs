//! The contract every display layer keeps.
//!
//! Between a buffer's text and what is laid out sit transformations, each a
//! layer (`docs/design/text-and-display.md`, "Display layers"): given the
//! snapshot and the edits of the layer below, a layer gives its own
//! snapshot and its own edits, in its own coordinate type, and converts a
//! point between its coordinates and those below, with a bias for a point
//! the layer below has no counterpart of.
//!
//! The layers built are three. Two are stacked, from the buffer up:
//!
//! 1. [`tabs::TabLayer`](crate::tabs::TabLayer): each tab expanded into
//!    spaces up to the next tab stop, each row cut into segments of at most
//!    [`tabs::SEGMENT_BYTES`](crate::tabs::SEGMENT_BYTES); points are
//!    [`tabs::TabPoint`](crate::tabs::TabPoint).
//! 2. [`wrap::WrapLayer`](crate::wrap::WrapLayer): each segment shaped and
//!    broken into visual lines at the view's width; its snapshot is the
//!    per-text line store; points are
//!    [`wrap::WrapPoint`](crate::wrap::WrapPoint).
//!
//! The third, [`folds::FoldLayer`](crate::folds::FoldLayer), sits beside
//! them: it maps a buffer offset to a
//! [`folds::FoldPoint`](crate::folds::FoldPoint), a row of the rows a
//! view's folds leave with each fold's rows as one placeholder row, and
//! back. A fold never changes the text of a row it leaves shown, so the
//! tab layer's `Below` stays the buffer's snapshot and the tab and wrap
//! entries stay keyed by buffer row: folding shapes only the placeholder,
//! and the rows it hides are not laid out. Layout keeps no fold layer
//! between calls; the frame and the queries read each walk's folds
//! through a [`folds::FoldSnapshot`](crate::folds::FoldSnapshot)
//! ([`folds`](crate::folds), "Where it sits").
//!
//! # Adding a layer
//!
//! A new layer is a new type that implements [`Layer`], placed in the
//! stack where its points make sense, and none of the layers below it
//! changes:
//!
//! - **Inline text** (type hints, a pending-operator hint) goes between
//!   the buffer and the tab layer: it changes what text a row holds, so
//!   tab stops are counted after it. The tab layer then takes its
//!   snapshot and edits in place of the buffer's. Folds were first meant
//!   for this place too; as built they change no shown row's text, and sit
//!   beside the stack instead (above).
//! - **Blocks between lines** (a review thread, a prompt) go after the wrap
//!   layer: they add rows of their own between visual lines and change no
//!   line's breaks.
//!
//! Each keeps the contract: its edits say what of its own snapshot changed,
//! so the layer above moves its state and is never cleared, and its
//! conversions go to the layer below and back to the point they started
//! from wherever the layer below has that point.

use std::ops::Range;

pub use editor_text::Bias;

/// What changed in a layer: the range `old` of its previous snapshot became
/// the range `new` of its current one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LayerEdit<P> {
    /// The range replaced, in the previous snapshot.
    pub old: Range<P>,
    /// The range that replaced it, in the current snapshot.
    pub new: Range<P>,
}

/// One display layer.
pub trait Layer {
    /// The snapshot of the layer below.
    type Below;
    /// A point of the layer below.
    type BelowPoint;
    /// This layer's snapshot.
    type Snapshot;
    /// A point of this layer.
    type Point;

    /// Takes the layer below's new snapshot and the edits that made it
    /// from the one this layer last took, in order, and gives this layer's
    /// new snapshot and its own edits.
    fn sync(
        &mut self,
        below: &Self::Below,
        edits: &[LayerEdit<Self::BelowPoint>],
    ) -> (Self::Snapshot, Vec<LayerEdit<Self::Point>>);

    /// The point of this layer at `point` of the layer below, in the
    /// snapshot last taken. `None` for a point the layer below does not
    /// have.
    fn to_layer(&self, point: Self::BelowPoint, bias: Bias) -> Option<Self::Point>;

    /// The point of the layer below at `point`. Where `point` has no
    /// counterpart below (inside a tab's expansion), `bias` says whether
    /// the point before it or the one after it is meant. `None` for a point
    /// this layer does not have.
    fn to_below(&self, point: Self::Point, bias: Bias) -> Option<Self::BelowPoint>;
}
