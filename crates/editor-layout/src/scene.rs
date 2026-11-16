//! The scene as Rust data: what Lean publishes after each command, the
//! input to layout.
//!
//! It is Lean's scene and the faces the binding sends with it. Field for
//! field it is `lean/Editor/Scene.lean`'s `Scene`, with the handles Lean
//! names content by already resolved by the binding (`editor-ffi`): a
//! view's snapshot is a [`TextRef`], its scroll anchor and its selections
//! the values its markers held when it was published. The decoded wire
//! form, with the handles and marker numbers unresolved, is the binding's.
//! Beside those fields it has one Lean's scene has not, [`Scene::faces`]:
//! Lean's scene names faces and never says what one looks like, so the
//! binding sends the definitions in the same call, and only when they
//! changed.
//!
//! What is laid out of it: each view's text across its `rect`, from its
//! scroll anchor, with its selections, cursors and decorations, each run
//! in the font its faces resolve to; and a view's `status` as one row at
//! the bottom of its `rect`, above which its text has what is left, with
//! each field on its side and padded, the row in the view's
//! `status_face` over the mode line's; each inset from the view's edges
//! by its `padding`, and the echo by the scene's `echo_padding`. What
//! it carries and lays out nothing of: the scene's `echo`, `pending`,
//! `preedit` and `focused`, which no phase of the display pipeline draws
//! yet.
//!
//! # Where an addition goes
//!
//! A new field of Lean's scene is a field here, decoded by the binding.
//! Drawing it is the frame's ([`frame`](crate::frame)). A new attribute
//! of a face is [`face`](crate::face)'s.
//!
//! # Builders for tests
//!
//! [`Scene::of_text`] and [`Scene::selecting`] make a scene of one view
//! of a text from a string and byte offsets alone. They are published for
//! the tests of other crates: a `Shaper` adapter's wiring test lays a
//! text out through them without depending on text storage
//! ([`shaper`](crate::shaper), "Where layout is run over a real
//! adapter").

use std::hash::{DefaultHasher, Hash, Hasher};
use std::ops::Range;
use std::sync::Arc;

use editor_text::{Patch, Revision, Selection, SelectionRange, Snapshot, Text};

use crate::face::FaceDef;

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

/// Which end of a view's status row a field is drawn from
/// ([`frame`](crate::frame), "The mode line").
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum Side {
    /// From the row's start, after the left fields before it.
    #[default]
    Left,
    /// Ending at the row's end, with the right fields after it.
    Right,
}

/// One field of a view's status line.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct StatusField {
    /// What it says.
    pub text: String,
    /// The name of the face it takes.
    pub face: String,
    /// The side of the row it is drawn on.
    pub side: Side,
    /// The space before and after its text, in whole points, which its
    /// face's background fills. Layout multiplies it by its scale as it
    /// does a face's lengths ([`face`](crate::face), "Units").
    pub padding: u32,
}

/// How far a view's content is inset from its edges, in whole points,
/// which layout multiplies by its scale as it does a face's lengths
/// ([`Layout::padding_pixels`](crate::Layout::padding_pixels);
/// [`frame`](crate::frame), "The padding"). The default is none.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Padding {
    /// The inset of the text, and of the status row's first and last
    /// fields, from the view's left and right edges.
    pub across: u32,
    /// The inset of the text rows from the view's top, and from the top of
    /// its status row (its bottom when it has none).
    pub down: u32,
    /// The further inset of the text rows from the view's top, beyond
    /// `down`: what a window's title bar covers of a view along the
    /// frame's top edge. 0 by default.
    pub top: u32,
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
    /// The face of its status row, over the mode line's and under every
    /// field's, which gives the row its background: an unselected
    /// window's `mode-line.inactive`, and `None` for a selected one.
    pub status_face: Option<String>,
    /// How far its text and its status fields are inset from its edges, in
    /// points; none by default.
    pub padding: Padding,
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
    /// How far the echo is inset from the frame's left and right edges, in
    /// points, in the view [`ECHO_VIEW`](crate::frame::ECHO_VIEW) layout
    /// makes of it; none by default.
    pub echo_padding: u32,
    /// The pending key prefix, rendered by Lean.
    pub pending: String,
    /// The input method's preedit text, if it is composing.
    pub preedit: Option<String>,
    /// What the faces the scene names look like: the definitions, in the
    /// order they were made, a later one of a name over an earlier one
    /// ([`face`](crate::face)). `None` is "as last given": layout keeps
    /// the definitions of the last scene that carried any, or that it was
    /// given since by [`Layout::define`](crate::Layout::define), and none
    /// before the first.
    pub faces: Option<Vec<FaceDef>>,
}

/// Builders for tests, this crate's and other crates': a scene made
/// without naming a type of `editor-text`, so the test of a `Shaper`
/// adapter lays a text out without depending on text storage.
impl Scene {
    /// A scene of one view, view 1, showing `text` in `rect` from its
    /// start, with no selection, no decoration, no status field and no
    /// faces.
    ///
    /// The text never changes and has nothing to pull. Its key is made
    /// from its bytes, so two scenes of one text name one text and layout
    /// keeps what it laid out of it, and a scene of another text names
    /// another.
    pub fn of_text(text: &str, rect: Rect) -> Self {
        let mut hasher = DefaultHasher::new();
        text.hash(&mut hasher);
        let key = TextKey(hasher.finish());
        Self {
            views: vec![View {
                id: ViewId(1),
                rect,
                text: Some(TextRef::fixed(key, Text::from(text).snapshot())),
                ..View::default()
            }],
            ..Self::default()
        }
    }

    /// This scene with its first view given one exclusive selection, from
    /// `bytes.start` to its head at `bytes.end`: a cursor when the two are
    /// equal. A scene with no view is left as it is.
    #[must_use]
    pub fn selecting(mut self, bytes: Range<usize>) -> Self {
        if let Some(view) = self.views.first_mut() {
            let range = SelectionRange::new(bytes.start, bytes.end);
            view.selections = Selection::new(vec![range], 0).into_iter().collect();
        }
        self
    }
}

#[cfg(test)]
mod tests {
    use editor_text::{Revision, Shape};

    use super::{Rect, Scene, ViewId};
    use crate::Layout;
    use crate::shaper::fake::CellShaper;

    /// A rectangle 200 pixels across and 64 down, off the frame's corner.
    const RECT: Rect = Rect {
        x: 3,
        y: 4,
        width: 200,
        height: 64,
    };

    #[test]
    fn a_scene_of_a_text_is_one_view_of_it_in_the_rectangle() {
        let scene = Scene::of_text("ab\ncd", RECT);
        assert_eq!(scene.views.len(), 1);
        let view = &scene.views[0];
        assert_eq!((view.id, view.rect, view.scroll), (ViewId(1), RECT, 0));
        let text = view.text.as_ref().expect("a text");
        assert_eq!(
            text.snapshot.slice_to_string(0..text.snapshot.len()),
            Some("ab\ncd".to_owned())
        );
        // Nothing else is set: no selection, decoration or status field,
        // and no faces.
        assert!(view.selections.is_empty());
        assert!(view.decorations.is_empty() && view.status.is_empty());
        assert!(scene.faces.is_none());
        // The text has nothing to pull.
        assert!(text.changes.since(Revision::default()).is_none());
        // One text is one key, and another text another.
        let key = |text: &str| {
            Scene::of_text(text, RECT).views[0]
                .text
                .as_ref()
                .unwrap()
                .key
        };
        assert_eq!(key("ab\ncd"), text.key);
        assert_ne!(key("ab\ncde"), text.key);
        // It lays out: two rows on the fake, and none shaped again for
        // the same text in another scene.
        let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
        assert_eq!(layout.frame(&scene).views[0].rows.len(), 2);
        let shaped = layout.counters().shaped;
        layout.frame(&Scene::of_text("ab\ncd", RECT));
        assert_eq!(layout.counters().shaped, shaped);
    }

    #[test]
    fn selecting_gives_the_first_view_one_exclusive_selection() {
        let scene = Scene::of_text("abcdef", RECT).selecting(1..4);
        let selections = &scene.views[0].selections;
        assert_eq!(selections.len(), 1);
        assert_eq!(selections[0].shape(), Shape::Exclusive);
        let ranges: Vec<(usize, usize)> = selections[0]
            .ranges()
            .iter()
            .map(|range| (range.anchor, range.head))
            .collect();
        assert_eq!(ranges, vec![(1, 4)]);
        // Selecting again replaces it, and equal ends are a cursor: one
        // cursor box and no selection area.
        let cursor = scene.selecting(2..2);
        assert_eq!(cursor.views[0].selections.len(), 1);
        let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
        let frame = layout.frame(&cursor);
        assert_eq!(frame.views[0].cursors.len(), 1);
        assert!(frame.views[0].selections.is_empty());
        // A scene with no view stays as it is.
        assert!(Scene::default().selecting(0..1).views.is_empty());
    }
}
