//! The contract every display layer keeps.
//!
//! Between a buffer's text and what is laid out sit transformations, each a
//! layer (`docs/design/text-and-display.md`, "Display layers"): given the
//! snapshot and the edits of the layer below, a layer gives its own
//! snapshot and its own edits, in its own coordinate type, and converts a
//! point between its coordinates and those below, with a bias for a point
//! the layer below has no counterpart of.
//!
//! The layers built are, from the buffer up:
//!
//! 1. [`tabs::TabLayer`](crate::tabs::TabLayer): each tab expanded into
//!    spaces up to the next tab stop, each row cut into segments of at most
//!    [`tabs::SEGMENT_BYTES`](crate::tabs::SEGMENT_BYTES); points are
//!    [`tabs::TabPoint`](crate::tabs::TabPoint).
//! 2. The wrap layer (next): each segment shaped and broken into visual
//!    lines at the view's width; its snapshot is the per-text line cache.
//!
//! # Adding a layer
//!
//! A new layer is a new type that implements [`Layer`], placed in the
//! stack where its points make sense, and none of the layers below it
//! changes:
//!
//! - **Folds and inline text** (type hints, a pending-operator hint) go
//!   between the buffer and the tab layer: they change what text a row
//!   holds, so tab stops are counted after them. The tab layer then takes
//!   their snapshot and edits in place of the buffer's.
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
