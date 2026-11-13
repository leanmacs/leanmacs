//! The scene as Rust data: what Lean publishes after each command, the
//! input to layout.
//!
//! It is field for field `lean/Editor/Scene.lean`'s `Scene`, with the
//! handles Lean names content by already resolved by the binding
//! (`editor-ffi`): a view's snapshot is a [`TextRef`], its scroll anchor
//! and its selections the values its markers held when it was published.
//! The decoded wire form, with the handles and marker numbers unresolved,
//! is the binding's.
//!
//! What phase 1 lays out of it: each view's text across its whole `rect`,
//! from its scroll anchor, with its selections, cursors and decorations.
//! What it carries and lays out nothing of: a view's `status` (the mode
//! line, phase 2), and the scene's `echo`, `pending`, `preedit` and
//! `focused`, which no phase of the display pipeline draws yet.
//!
//! # Where an addition goes
//!
//! A new field of Lean's scene is a field here, decoded by the binding.
//! Drawing it is the frame's ([`frame`](crate::frame)).

use std::sync::Arc;

use editor_text::{Patch, Revision, Selection, Snapshot};

/// A size, in physical pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Size {
    /// Across.
    pub width: u32,
    /// Down.
    pub height: u32,
}

/// A rectangle of the frame, in physical pixels from its top left.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Rect {
    /// From the left.
    pub x: u32,
    /// From the top.
    pub y: u32,
    /// Across.
    pub width: u32,
    /// Down.
    pub height: u32,
}

/// The name of a view in a scene: the command loop's number for it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
pub struct ViewId(pub u64);

/// The shape a cursor is drawn as.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum CursorShape {
    /// A filled cell.
    #[default]
    Block,
    /// A thin bar before the cell.
    Bar,
    /// A line under the cell.
    Underline,
    /// The outline of a cell.
    Hollow,
}

/// How a view's cursors are drawn.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Cursor {
    /// Their shape.
    pub shape: CursorShape,
    /// The name of the face they take.
    pub face: String,
}

/// A span of a view's text drawn in a face.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Decoration {
    /// The byte offset where it starts, in the view's snapshot.
    pub start: usize,
    /// Where it stops, not included.
    pub stop: usize,
    /// The name of the face it takes.
    pub face: String,
}

/// One field of a view's status line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatusField {
    /// What it says.
    pub text: String,
    /// The name of the face it takes.
    pub face: String,
}

/// Which text: a key the binding gives each text, unique in the process.
/// Layout keeps its state per key, so two snapshots of one key at one
/// revision must hold the same text: the binding gives a key to each
/// document, and one of its own to each snapshot no document holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct TextKey(pub u64);

/// The port through which layout pulls what changed in a text since a
/// revision it laid out, to move its entries rather than clear them.
pub trait Changes: Send + Sync {
    /// What changed since `revision`, up to the text's revision now; `None`
    /// when that cannot be said (the log has forgotten it, or the text is
    /// gone).
    fn since(&self, revision: Revision) -> Option<Patch>;
}

/// [`Changes`] of a text nothing can be pulled from: a snapshot loaded from
/// a file, which no text holds.
#[derive(Debug, Clone, Copy, Default)]
pub struct NoChanges;

impl Changes for NoChanges {
    fn since(&self, _revision: Revision) -> Option<Patch> {
        None
    }
}

/// A view's text: which text, the snapshot shown, and where its changes
/// are pulled from.
#[derive(Clone)]
pub struct TextRef {
    /// Which text.
    pub key: TextKey,
    /// The snapshot shown.
    pub snapshot: Snapshot,
    /// Its changes.
    pub changes: Arc<dyn Changes>,
}

impl TextRef {
    /// The text `key` shown at `snapshot`, with nothing to pull.
    pub fn fixed(key: TextKey, snapshot: Snapshot) -> Self {
        Self {
            key,
            snapshot,
            changes: Arc::new(NoChanges),
        }
    }
}

/// One view.
#[derive(Clone, Default)]
pub struct View {
    /// Which view.
    pub id: ViewId,
    /// Where it is in the frame.
    pub rect: Rect,
    /// The text it shows; `None` when the binding was handed none.
    pub text: Option<TextRef>,
    /// Its scroll anchor's offset: the first row shown is the one that
    /// holds it.
    pub scroll: usize,
    /// Its selections, each with its ranges and its shape.
    pub selections: Vec<Selection>,
    /// How its cursors are drawn.
    pub cursor: Cursor,
    /// Spans of its text drawn in a face.
    pub decorations: Vec<Decoration>,
    /// Its status line, field by field.
    pub status: Vec<StatusField>,
}

/// Everything the display shows, as published after a command.
#[derive(Clone, Default)]
pub struct Scene {
    /// The frame's size.
    pub size: Size,
    /// The views, in drawing order.
    pub views: Vec<View>,
    /// The view with the keyboard focus, if one has.
    pub focused: Option<ViewId>,
    /// The echo area's text.
    pub echo: String,
    /// The pending key prefix, rendered by Lean.
    pub pending: String,
    /// The input method's preedit text, if it is composing.
    pub preedit: Option<String>,
}
