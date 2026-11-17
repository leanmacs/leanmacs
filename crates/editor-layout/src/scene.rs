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
//! scroll anchor, with its selections, cursors and decorations over the
//! text's own spans ([`TextSpans`], a syntax's highlights, which the text
//! carries and layout asks of only the rows it lays out), each run
//! in the font its faces resolve to; and a view's `status` as one row at
//! the bottom of its `rect`, above which its text has what is left, with
//! each field on its side and padded, the row in the view's
//! `status_face` over the mode line's; each inset from the view's edges
//! by its `padding`, and the echo by the scene's `echo_padding`; and each
//! of the scene's `dividers` as a fill of its rect in its face's
//! foreground. What
//! it carries and lays out nothing of: the scene's `echo`, `pending`,
//! `preedit` and `focused`, which no phase of the display pipeline draws
//! yet.
//!
//! # Blocks
//!
//! A view's [`Block`]s are rows of text of their own drawn between the
//! rows of its text: an excerpt's header, and later a hunk's controls and
//! a comment thread. A block is the view's, not its text's, as a
//! decoration is, and Lean chooses each one. It is text only, laid out as
//! a small text of its own in its own faces, and it holds no position: a
//! position of the view's text is drawn and moved to as it is without
//! blocks, and only the height a view's rows take counts a block's lines
//! ([`query`](crate::query), "Blocks"). Several blocks before one row are
//! drawn in the order the view lists them.
//!
//! # Gutter marks
//!
//! A view's [`GutterMark`]s are short texts drawn in a column of their own
//! before its text: a version-control gutter's added, removed and changed
//! lines. The column is [`Padding::gutter`] points wide, after `across` at
//! the view's left, and the text rows are that much further right and
//! narrower; every query takes it off as the frame does. A mark is drawn
//! beside every visual line of each row of the view's text that its range
//! has a byte in, or of the row that holds its start when the range is
//! empty, in its face over `gutter` over the default face. Like a block it
//! is the view's, Lean chooses it, and it holds no position of the text:
//! a mark moves only when Lean publishes it moved. Its offsets are moved
//! back to a character boundary, and past the text's end to the end, as a
//! block's are. Marks beside rows the view does not show draw nothing.
//!
//! # Where an addition goes
//!
//! A new field of Lean's scene is a field here, decoded by the binding.
//! Drawing it is the frame's ([`frame`](crate::frame)). A new attribute
//! of a face is [`face`](crate::face)'s.
//!
//! # Builders for tests
//!
//! [`FixedSpans`] is the fake of [`TextSpans`], spans given as data, and
//! [`spans_contract::check`] its contract, which every implementation runs
//! in its own crate's tests.
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

/// A block: rows of text of its own, drawn between two rows of a view
/// (module docs, "Blocks").
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Block {
    /// A byte offset of the view's snapshot: the block is drawn above the
    /// first visual line of the row that holds it.
    pub before: usize,
    /// What it says.
    pub text: String,
    /// Spans of `text` drawn in a face: the block's own faces, over the
    /// default face. `start` and `stop` are bytes of `text`.
    pub decorations: Vec<Decoration>,
}

/// A gutter mark: a short text drawn in a view's gutter column beside the
/// rows its range covers (module docs, "Gutter marks").
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct GutterMark {
    /// A byte offset of the view's snapshot where its range starts.
    pub start: usize,
    /// Where it stops, not included. A range of no byte marks the row that
    /// holds `start`.
    pub stop: usize,
    /// What it says.
    pub text: String,
    /// The name of the face it takes, over `gutter` over the default face.
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
    /// The width of the gutter column (module docs, "Gutter marks"): a
    /// further inset of the text rows from the view's left, beyond
    /// `across`, which the view's marks are drawn in. 0 by default: no
    /// column.
    pub gutter: u32,
}

impl Padding {
    /// A padding of `across`, `down` and `top` points, and nothing else.
    ///
    /// It is published for the tests and the decoders of other crates: a
    /// padding built through it, or from one it returns with `..`, takes a
    /// field added to it at its default, so the field breaks nothing
    /// outside this crate.
    pub const fn new(across: u32, down: u32, top: u32) -> Self {
        Self {
            across,
            down,
            top,
            gutter: 0,
        }
    }
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

/// The port through which layout asks a text for its own spans: what it
/// is drawn with whatever the scene says, a syntax's highlights. They are
/// the lowest layer of a run's faces, under the scene's decorations and
/// the selections ([`face`](crate::face), "The precedence").
pub trait TextSpans: Send + Sync {
    /// What it draws over `snapshot`, fixed for one frame or one query;
    /// `None` when it draws nothing.
    fn at(&self, snapshot: &Snapshot) -> Option<Box<dyn SpansAt>>;
}

/// A text's own spans over one snapshot ([`TextSpans::at`]).
pub trait SpansAt {
    /// The names of the faces its spans name, by index.
    fn faces(&self) -> &[String];

    /// Adds to `out` its spans that cover any of `bytes`, each cut to it,
    /// with the index of its face, lowest layer first. `bytes` is two
    /// positions of the snapshot, in order.
    fn spans(&self, bytes: Range<usize>, out: &mut Vec<(Range<usize>, usize)>);
}

/// A view's text: which text, the snapshot shown, where its changes are
/// pulled from, and its own spans.
#[derive(Clone)]
pub struct TextRef {
    /// Which text.
    pub key: TextKey,
    /// The snapshot shown.
    pub snapshot: Snapshot,
    /// Its changes.
    pub changes: Arc<dyn Changes>,
    /// Its own spans, drawn under the scene's decorations; `None` when it
    /// has none.
    pub spans: Option<Arc<dyn TextSpans>>,
}

impl TextRef {
    /// The text `key` shown at `snapshot`, with nothing to pull and no
    /// spans of its own.
    pub fn fixed(key: TextKey, snapshot: Snapshot) -> Self {
        Self {
            key,
            snapshot,
            changes: Arc::new(NoChanges),
            spans: None,
        }
    }

    /// This text, with its changes pulled through `changes`.
    #[must_use]
    pub fn with_changes(self, changes: Arc<dyn Changes>) -> Self {
        Self { changes, ..self }
    }

    /// This text, with `spans` as its own spans.
    #[must_use]
    pub fn with_spans(self, spans: Arc<dyn TextSpans>) -> Self {
        Self {
            spans: Some(spans),
            ..self
        }
    }
}

/// Spans given as data, for tests, this crate's and other crates': the
/// same spans over any snapshot, cut to the bytes asked. It records the
/// ranges it is asked for.
#[derive(Debug, Clone, Default)]
pub struct FixedSpans {
    /// The face names.
    faces: Vec<String>,
    /// The spans, each with its face's index, lowest layer first.
    spans: Vec<(Range<usize>, usize)>,
    /// The ranges asked, in order.
    asked: Arc<std::sync::Mutex<Vec<Range<usize>>>>,
}

impl FixedSpans {
    /// The spans `spans`, naming `faces` by index.
    pub fn new(faces: &[&str], spans: Vec<(Range<usize>, usize)>) -> Self {
        Self {
            faces: faces.iter().map(|face| (*face).to_owned()).collect(),
            spans,
            asked: Arc::default(),
        }
    }

    /// The ranges it has been asked for so far, in order.
    pub fn asked(&self) -> Vec<Range<usize>> {
        self.asked
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }
}

impl TextSpans for FixedSpans {
    fn at(&self, _snapshot: &Snapshot) -> Option<Box<dyn SpansAt>> {
        Some(Box::new(self.clone()))
    }
}

impl SpansAt for FixedSpans {
    fn faces(&self) -> &[String] {
        &self.faces
    }

    fn spans(&self, bytes: Range<usize>, out: &mut Vec<(Range<usize>, usize)>) {
        self.asked
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(bytes.clone());
        for (span, face) in &self.spans {
            let cut = span.start.max(bytes.start)..span.end.min(bytes.end);
            if !cut.is_empty() {
                out.push((cut, *face));
            }
        }
    }
}

/// The contract of [`TextSpans`]: what every implementation keeps, as a
/// check that runs one over a snapshot. [`FixedSpans`] passes it here, and
/// each implementation in its own crate's tests (`editor-ffi`'s adapter,
/// in its `tests/highlight.rs`).
pub mod spans_contract {
    use std::ops::Range;

    use editor_text::Snapshot;

    use super::TextSpans;

    /// Every span lies within the bytes asked, and is not empty.
    pub const WITHIN: &str = "every span lies within the bytes asked and is not empty";
    /// Every span names a face below the count of its face names.
    pub const FACES: &str = "every span names one of its faces";
    /// Every span's ends are positions of the snapshot.
    pub const POSITIONS: &str = "every span's ends are positions of the snapshot";

    /// Every property, by name.
    pub const PROPERTIES: [&str; 3] = [WITHIN, FACES, POSITIONS];

    /// How many random ranges are asked of each snapshot.
    const RANDOM: usize = 32;

    /// Holds `spans` to the contract over `snapshot`, asking it the bytes
    /// of each row and random ranges from a fixed seed, and returns the
    /// properties that fail: none when it keeps them all, and none when it
    /// draws nothing over the snapshot.
    pub fn check(spans: &dyn TextSpans, snapshot: &Snapshot) -> Vec<&'static str> {
        let Some(at) = spans.at(snapshot) else {
            return Vec::new();
        };
        let mut ranges: Vec<Range<usize>> = (0..snapshot.row_count())
            .filter_map(|row| snapshot.row_range(row))
            .collect();
        let mut seed: u64 = 0x005e_ed0f_5ea5;
        let mut below = |bound: usize| {
            seed = seed
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407);
            usize::try_from(seed >> 33).unwrap_or(0) % bound.max(1)
        };
        for _ in 0..RANDOM {
            let a = position(snapshot, below(snapshot.len() + 1));
            let b = position(snapshot, below(snapshot.len() + 1));
            ranges.push(a.min(b)..a.max(b));
        }
        let (mut within, mut faces, mut positions) = (true, true, true);
        for bytes in ranges {
            let mut out = Vec::new();
            at.spans(bytes.clone(), &mut out);
            for (span, face) in out {
                within &=
                    bytes.start <= span.start && span.end <= bytes.end && span.start < span.end;
                faces &= face < at.faces().len();
                positions &= snapshot.is_char_boundary(span.start)
                    && snapshot.is_char_boundary(span.end)
                    && span.end <= snapshot.len();
            }
        }
        [(WITHIN, within), (FACES, faces), (POSITIONS, positions)]
            .into_iter()
            .filter_map(|(name, holds)| (!holds).then_some(name))
            .collect()
    }

    /// The last position of `snapshot` at or before `offset`.
    fn position(snapshot: &Snapshot, offset: usize) -> usize {
        let mut offset = offset.min(snapshot.len());
        while !snapshot.is_char_boundary(offset) {
            offset -= 1;
        }
        offset
    }

    #[cfg(test)]
    mod tests {
        use std::ops::Range;

        use editor_text::{Snapshot, Text};

        use super::*;
        use crate::scene::{FixedSpans, SpansAt};

        /// Spans that answer what they hold, uncut, whatever is asked.
        struct Uncut(Vec<(Range<usize>, usize)>, Vec<String>);

        impl TextSpans for Uncut {
            fn at(&self, _snapshot: &Snapshot) -> Option<Box<dyn SpansAt>> {
                Some(Box::new(Uncut(self.0.clone(), self.1.clone())))
            }
        }

        impl SpansAt for Uncut {
            fn faces(&self) -> &[String] {
                &self.1
            }
            fn spans(&self, _bytes: Range<usize>, out: &mut Vec<(Range<usize>, usize)>) {
                out.extend(self.0.iter().cloned());
            }
        }

        /// A text with a row of multibyte characters.
        fn snapshot() -> Snapshot {
            Text::from(
                "ab cd
é漢 x

last",
            )
            .snapshot()
        }

        #[test]
        fn fixed_spans_keep_the_contract() {
            let spans = FixedSpans::new(&["a", "b"], vec![(0..2, 0), (3..8, 1), (6..17, 0)]);
            assert_eq!(check(&spans, &snapshot()), [""; 0]);
        }

        #[test]
        fn spans_not_cut_to_the_bytes_asked_are_reported() {
            let uncut = Uncut(vec![(0..19, 0)], vec!["a".to_owned()]);
            assert_eq!(check(&uncut, &snapshot()), [WITHIN]);
        }

        #[test]
        fn a_span_naming_a_face_it_has_not_is_reported() {
            let spans = FixedSpans::new(&["a"], vec![(0..2, 1)]);
            assert_eq!(check(&spans, &snapshot()), [FACES]);
        }

        #[test]
        fn a_span_ending_inside_a_character_is_reported() {
            // 7 is inside `é`, which is 6..8.
            let spans = FixedSpans::new(&["a"], vec![(3..7, 0)]);
            assert_eq!(check(&spans, &snapshot()), [POSITIONS]);
        }

        #[test]
        fn spans_that_draw_nothing_keep_the_contract() {
            struct Nothing;
            impl TextSpans for Nothing {
                fn at(&self, _snapshot: &Snapshot) -> Option<Box<dyn SpansAt>> {
                    None
                }
            }
            assert_eq!(check(&Nothing, &snapshot()), [""; 0]);
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
    /// field's, which gives the row its background: Lean's choice, which
    /// marks the selected window apart from the others; `None` draws the
    /// row in the mode line's alone.
    pub status_face: Option<String>,
    /// How far its text and its status fields are inset from its edges, in
    /// points; none by default.
    pub padding: Padding,
    /// Its blocks, drawn between the rows of its text (module docs,
    /// "Blocks"); none by default.
    pub blocks: Vec<Block>,
    /// Its gutter marks, drawn in its gutter column (module docs, "Gutter
    /// marks"); none by default.
    pub marks: Vec<GutterMark>,
}

/// A divider: a strip of the frame between two tiled views, filled in the
/// foreground of its face. Which strips are dividers, and their face, are
/// Lean's.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Divider {
    /// Where it is in the frame.
    pub rect: Rect,
    /// The name of the face whose foreground it is filled in.
    pub face: String,
}

/// Everything the display shows, as published after a command.
#[derive(Clone, Default)]
pub struct Scene {
    /// The frame's size.
    pub size: Size,
    /// The views, in drawing order.
    pub views: Vec<View>,
    /// The dividers between the tiled views, drawn before every view;
    /// none by default.
    pub dividers: Vec<Divider>,
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
