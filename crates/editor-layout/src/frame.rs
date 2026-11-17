//! The frame: an immutable plain-data value of what to draw, built from a
//! scene.
//!
//! For each view, the visual rows it shows from its scroll anchor, as many
//! as fit its rectangle less its padding, each with its `x` and `y`, its
//! glyphs (shared with the
//! line store, never copied), its runs and a content hash; and the
//! geometry of its cursors and of its selections. Geometry is in pixels
//! from the view's top left.
//!
//! **The dividers.** Each of the scene's dividers ([`Scene::dividers`]) is a
//! [`Fill`] of its rectangle in its face's foreground over the default
//! face, as Emacs colours `window-divider` and `vertical-border` with
//! `:foreground`: a face nothing defines is the default face's ink, which
//! is seen on the paper. Layout reads no face name of its own for them:
//! which strips are dividers, and their face, are Lean's. The frame keeps
//! them apart from the views ([`Frame::dividers`]), and the renderer fills
//! them first.
//!
//! The rows that fit are the rows query's ([`query`](crate::query), "The
//! rows that fit"): each counts as at least one pixel, so a frame holds at
//! most a row for each pixel of its view's height, whatever height a font
//! gives its lines. A row is as tall as the shaper made it, so a row of no
//! height has a height of 0 and the row after it has its `y`.
//!
//! **Block rows.** A view's blocks ([`View::blocks`]) are rows of
//! [`ViewFrame::rows`] too, in top-to-bottom order among its text rows,
//! each with [`FrameRow::block`] naming its block, its bytes those of the
//! block's text and its runs its block's decorations' paint over the
//! default face. Where each goes and which fit are the rows query's rule
//! ([`query`](crate::query), "Blocks"), and the frame walks the same
//! walk. A renderer draws a block row as any row. Cursors and selection
//! areas are on text rows only, at their `y`, which counts the block rows
//! above them; a row's hash is computed as a text row's, so an unchanged
//! header keeps its hash.
//!
//! **The mode line.** A view with at least one status field has a status
//! row ([`StatusRow`]) at the bottom of its rectangle. Each field is
//! shaped through the `Shaper` port as a line of its own, in its face over
//! the view's status face ([`View::status_face`], Lean's
//! `mode-line.active` for the selected window and `mode-line.inactive` for
//! the others) over the face `mode-line` over the default face.
//! A tab, a carriage return or a line feed in a field is shaped as a
//! space. There is no separator glyph: fields are told apart by their
//! padding and their background.
//!
//! - **Sides and padding.** A field has a side and a horizontal padding
//!   in points ([`StatusField::side`], [`StatusField::padding`]), which
//!   layout multiplies by its scale. A field's box is its line's width
//!   plus its padding on each side, and its glyphs start its padding in.
//!   The left fields, in the scene's order, run from the row's start, each
//!   box from the end of the one before. The right fields, in the scene's
//!   order, are laid out the same way and end at the row's end. The row's
//!   start and end are the view's padding across in from its left and
//!   right edges ("The padding", below): 0 and the view's width when it
//!   has none.
//! - **When both do not fit**, the right side keeps its place: every left
//!   glyph that would end past the right side's start is dropped, and the
//!   left boxes are cut there (a box with nothing left is dropped). A right
//!   side wider than the row starts at the row's start, and what of it runs
//!   past the row's end is drawn on into the padding, and what runs past
//!   the view's edge is outside the view, which draws nothing outside its
//!   rectangle. With no right field nothing is cut.
//! - **Boxes.** The row carries each field's box ([`StatusBox`]) in the
//!   background of the field's face over the row's faces, so a padding,
//!   which has no glyph in it, is painted as data. The row's own
//!   background, across the view, is the status face's over the mode
//!   line's.
//! - **The row's line.** Its glyphs are the fields' lines placed, their
//!   clusters bytes of the fields' texts one after another; it is as tall
//!   as its tallest field's line, on the lowest field baseline, and an
//!   empty row's is the mode line's font's.
//! - **Height.** The row is exactly [`Heights::status`] tall
//!   ([`Layout::heights`]: the mode line's line height and its vertical
//!   padding above and below, rounded up to a whole pixel), whatever height
//!   its line was shaped at, and its line sits below the mode line's
//!   vertical padding, rounded down to a whole pixel. The status face
//!   neither makes the row taller nor moves its line. A glyph of a field
//!   whose face is taller runs past the row's foot, which is the view's,
//!   and the renderer draws nothing of a view outside its rectangle.
//!
//! The view's text rows are those that fit whole in the whole pixels that
//! remain less the view's padding down twice, and none when the status row
//! is taller than the view. A view with no status field gives its whole
//! height to its text, less that padding.
//!
//! **The padding.** A view's [`View::padding`] insets its content from its
//! edges, in whole points that layout turns into pixels at its scale with
//! one function, [`Layout::padding_pixels`]: the points times the scale,
//! unrounded, as a status field's padding is. So 8 points are 8 pixels at
//! scale 1, 16 at scale 2 and 12 at scale 1.5, and 3 points are 4½ at 1.5.
//! Below, `across`, `down` and `top` are those pixels.
//!
//! - **The text** is laid out in the rectangle less `across` at the left
//!   and right, `top` and `down` at the top, and `down` above the status
//!   row (or the bottom, with none): it wraps at the view's width less
//!   twice `across`, and its rows are those that fit whole in its height
//!   less its status row less twice `down` and once `top`, which may be a
//!   fractional number of pixels. Each extent is at 0 at least, and a
//!   width of 0 is a view narrower than a cell. `top` is what a window's
//!   title bar covers of a view along the frame's top edge
//!   ([`Padding::top`](crate::scene::Padding::top)), so the first row
//!   starts below it and the padding; it is 0 for any other view.
//! - **A row** starts `top` and `down` from the view's top, and its [`FrameRow::x`]
//!   is `across`: its glyphs keep their `x` from the row's start, shared
//!   with the line store and never copied. A row's hash leaves out its `x`
//!   and its `y`, so a change of padding rebuilds no row.
//! - **A cursor and a selection area** are `across` further right than
//!   their cells on the row, and at the row's `y`.
//! - **The status row** keeps its background across the whole view, so the
//!   padding beside its fields is the mode line's colour, and its fields
//!   run between `across` in from each edge ("The mode line", above). It
//!   takes no `down`: it is at the view's foot.
//! - **The view's background** (the default face's) fills its rectangle,
//!   so the padding round the text is paper, not a border.
//!
//! The echo's view, [`ECHO_VIEW`], has no padding of its own: its fields
//! are inset [`Scene::echo_padding`] points from the frame's left and
//! right edges, by the same function. A padding of 0, a scene's default,
//! lays out as before there was one.
//!
//! The rows query takes a padding off by the same rule
//! ([`Layout::rows_shown`], [`Layout::lines_from`]), so a caller that asks
//! with a view's padding at its height less its bottom row is answered
//! with the rows its frame shows (`tests/padding.rs`, `tests/heights.rs`).
//!
//! **The bottom row.** A view whose rectangle reaches the frame's bottom
//! edge (its foot at or below the scene's height) and that has a status
//! field has a status row [`Heights::message`] tall in place of
//! [`Heights::status`]: that row is the frame's bottom row, the
//! minibuffer's, where Lean puts the prompt while one is open. A view
//! with no status field is not touched by this: it has no status row, at
//! the bottom edge or not.
//!
//! So a caller that asks the rows query for a view's rows at its height
//! less [`Heights::status`], or less [`Heights::message`] for a view at
//! the bottom edge, is answered with exactly the rows its frame shows.
//!
//! The scene's echo is drawn in the bottom row when nothing else is: when
//! the echo is not empty and no view's rectangle has a pixel in common
//! with the frame's bottom [`Heights::message`] pixels (the frame's height
//! when it is less), the frame ends with one more view frame, of the id
//! [`ECHO_VIEW`]. Its rectangle is that row across the scene's width, it
//! has no text rows, no cursor and no selection, and its one status row is
//! the echo, shaped as a status row is, in the face `echo-area` over the
//! default face, not `mode-line`, its line below the echo area's vertical
//! padding, and its text inset [`Scene::echo_padding`] from the frame's
//! left and right edges ("The padding", below). An empty echo, a frame of no width or no
//! height, and a bottom row any view covers any of, give no such view: the
//! row then shows what the views there draw, or the target's clear
//! colour.
//!
//! **Every value is resolved.** A frame names no face: a run carries the
//! [`Paint`] its faces come to ([`face`](crate::face), "The precedence":
//! lowest first, the text's own spans, resolved once for the frame through
//! its [`TextSpans`](crate::scene::TextSpans), then the view's decorations
//! in the scene's order and then the selection, over the default face), a
//! glyph the id of the font it is
//! drawn in, a
//! cursor the paint of the face the scene names for it over the default
//! face, and a view the default face's background and the selection
//! face's, which its selection areas are filled with. Neighbouring runs of
//! one paint are one run, so two faces that come to the same paint cannot
//! be told apart in a frame.
//!
//! **The fonts travel with the frame.** A glyph's font id is an index into
//! [`Frame::fonts`], the shaper's table of the fonts glyphs are drawn in
//! ([`Shaper::resolved`]), read once the views are laid out: the bytes of
//! each font's file, its face, its size and its synthesis, which is what a
//! rasteriser needs. [`Frame::generation`] is the shaper's generation the
//! frame was laid out under. Within one generation an id never changes
//! meaning, so whatever takes frames may key what it keeps by font id and
//! glyph id, and drops it all when a frame of another generation arrives.
//! The frame holds no atlas id and no rasterised glyph.
//!
//! A row's runs cover its glyphs from the first to the last and nothing
//! past them, and a selection's area on a row is as wide as the glyphs it
//! covers there. Cursor boxes and selection areas are read from a row's
//! cells ([`line`](mod@crate::line), "Cells"), not from its glyphs as they
//! are listed: a cursor on one character of a glyph that draws two is half
//! the glyph wide, and a selection that crosses a change of direction is
//! an area for each stretch of the row it covers. A tab whose spaces cross
//! a soft wrap is drawn on both
//! rows, so each row takes the tab's faces and its selection over the
//! spaces it holds, though the tab's position is on the earlier row alone
//! ([`line`](mod@crate::line), which also says which of a tab's spaces are
//! no row at all in a view narrower than the tab).
//!
//! A row's hash covers its glyphs (each with its font's id and the offset
//! its outline is drawn at), its runs (their bytes and their paint) and
//! its height and baseline, all relative to the row's start: never its `x`,
//! its `y` or an absolute offset. So scrolling,
//! and an edit on another row, leave it as it was, and a renderer reuses
//! what it built for a row whose hash it has seen. A change of a face's
//! colour changes the hash of the rows drawn in it and of no other. A
//! cursor is not part of any row, so moving one, or changing its face,
//! changes no hash.
//!
//! Offsets in the scene that are not positions of the view's snapshot (a
//! marker read at a newer revision than the snapshot) are moved back to the
//! nearest position at or before them, and past the end to the end.
//!
//! [`Frame::describe`] is the frame as text, for tests: geometry, glyph
//! ids, font ids and paints; no hash, no generation and no table of
//! fonts.

use std::fmt::Write as _;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::ops::Range;
use std::sync::Arc;

use editor_text::{Selection, SelectionRange, Snapshot};

use crate::Layout;
use std::collections::{HashMap, HashSet};

use crate::blocks::{BlockKey, BlockLayout, ViewBlocks};

use crate::cache::{FieldKept, StatusKept, state};
use crate::decoration::{
    DecorationSource, FaceSpanSource, SelectionSource, Span, Styles, TextSpansSource, fonts_of,
    merge,
};
use crate::face::{
    Color, ECHO_AREA_FACE, FaceId, MODE_LINE_FACE, Paint, SELECTION_FACE, UnderlineStyle,
};
use crate::line::LineEntry;
use crate::query::{Shown, Visual, Walker};
use crate::scene::{CursorShape, Rect, Scene, Side, Size, StatusField, TextKey, View, ViewId};
use crate::shaper::{
    FontId, FontRun, Glyph, ResolvedFont, ResolvedFontId, ShapeInput, ShapedLine, Shaper,
    VisualLine,
};
use crate::tabs::boundary_at_or_before;
use crate::wrap::Outcome;

/// A rectangle in pixels from a view's top left.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Area {
    /// From the left.
    pub x: f32,
    /// From the top.
    pub y: f32,
    /// Across.
    pub width: f32,
    /// Down.
    pub height: f32,
}

/// A rectangle of the frame filled in one colour: a divider between two
/// views (module docs, "The dividers").
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Fill {
    /// Where it is, in the frame's physical pixels from its top left.
    pub rect: Rect,
    /// Its colour.
    pub color: Color,
}

/// One visual row of a view's frame.
#[derive(Debug, Clone, PartialEq)]
pub struct FrameRow {
    /// Its left, from the view's left: the view's padding across, in
    /// pixels (module docs, "The padding"). Its glyphs' `x` are from here.
    pub x: f32,
    /// Its top, from the view's top.
    pub y: f32,
    /// How far down it is.
    pub height: f32,
    /// Its baseline, from its top.
    pub baseline: f32,
    /// Its bytes, without its line break: in the view's snapshot for a row
    /// of the view's text, and in the block's text for a block row. A tab
    /// whose spaces it starts inside is not among them: the tab is the
    /// earlier row's.
    pub bytes: Range<usize>,
    /// Its glyphs, as the line store holds them. Their clusters are bytes of
    /// the segment's expanded text; `line.bytes` is the row's part of it.
    pub line: Arc<VisualLine>,
    /// Its runs, as bytes of the expanded text from the row's start
    /// (`line.bytes.start`), each with what it is painted with. They cover
    /// `line.bytes` from start to end, and no two neighbours have the same
    /// paint; an empty row has none. The font of a glyph is the glyph's.
    pub runs: Vec<(Range<usize>, Paint)>,
    /// The content hash.
    pub hash: u64,
    /// Which text it is a row of: `None` for the view's text, and
    /// `Some(i)` for a line of the view's `blocks[i]` ([`View::blocks`];
    /// [`query`](crate::query), "Blocks"). A block row is drawn like any
    /// row: the renderer needs to tell it from no other.
    pub block: Option<usize>,
}

impl FrameRow {
    /// A row of the view's text at `x` and `y`, of `bytes` of its
    /// snapshot, drawing `line` with `runs`, as tall as `line` and on its
    /// baseline, with the content hash `hash`.
    ///
    /// It is how the frame builds a text row, and it is published for the
    /// tests of other crates: a renderer's test builds the rows it draws
    /// through it, or from one it returns with `..`, so a field added to a
    /// row breaks no test outside this crate.
    pub fn text_row(
        x: f32,
        y: f32,
        bytes: Range<usize>,
        line: Arc<VisualLine>,
        runs: Vec<(Range<usize>, Paint)>,
        hash: u64,
    ) -> Self {
        Self {
            x,
            y,
            height: line.height,
            baseline: line.baseline,
            bytes,
            line,
            runs,
            hash,
            block: None,
        }
    }
}

/// One cursor of a view.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CursorBox {
    /// The cell it is on ([`line`](mod@crate::line), "Cells"): its
    /// character's share of the glyphs that draw it, which is the glyph
    /// where a glyph draws one character; or at a line's end, where there
    /// is no character, one advance of the default face's font.
    pub area: Area,
    /// Its shape.
    pub shape: CursorShape,
    /// What its face comes to over the default face: its background is
    /// the cursor's colour, and its foreground the colour of the glyph
    /// under a block cursor.
    pub paint: Paint,
}

/// The status row of a view: its status fields, each on its side, as one
/// line at the view's bottom (module docs, "The mode line").
#[derive(Debug, Clone, PartialEq)]
pub struct StatusRow {
    /// Its top, from the view's top: the view's height less its own, and
    /// the view's top when it is taller than the view.
    pub y: f32,
    /// How far down it is: [`Heights::status`], or [`Heights::message`]
    /// at the frame's bottom edge (module docs, "The bottom row").
    pub height: f32,
    /// Its baseline, from its top: the mode line's vertical padding, in
    /// whole pixels, and its line's baseline.
    pub baseline: f32,
    /// Its glyphs: each field's text shaped as a line of its own and
    /// placed on its side, left fields first. Their clusters are bytes of
    /// the fields' texts one after another.
    pub line: Arc<VisualLine>,
    /// Its runs, as bytes of that text, each with the paint of its
    /// field's face over the view's status face, over the mode line's,
    /// over the default face's; neighbours of one paint are one run.
    pub runs: Vec<(Range<usize>, Paint)>,
    /// The colour behind it, across the view: the status face's background
    /// over the mode line face's.
    pub background: Color,
    /// The box of each field that kept any width, left fields first:
    /// where the field's padding and text are, in its face's background.
    pub boxes: Vec<StatusBox>,
    /// The content hash: its glyphs, its runs, its height and baseline,
    /// its background and its boxes.
    pub hash: u64,
}

/// A status field on its way to its row: its side, its padding in pixels,
/// its first byte in the row's text, its line (none for an empty text)
/// and the background of its face.
struct Placed {
    side: Side,
    padding: f32,
    start: usize,
    line: Option<Arc<VisualLine>>,
    background: Color,
}

/// The box of one status field across its row: its padding each side of
/// its text, cut where the right side starts when both sides do not fit.
/// It is as tall as the row.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StatusBox {
    /// Where it starts, in pixels from the view's left.
    pub x: f32,
    /// How far across it is, in pixels.
    pub width: f32,
    /// The colour it is filled with: the background of the field's face
    /// over the row's faces over the default face.
    pub background: Color,
}

/// The frame of one view.
#[derive(Debug, Clone, PartialEq)]
pub struct ViewFrame {
    /// Which view.
    pub id: ViewId,
    /// Where it is in the frame.
    pub rect: Rect,
    /// The colour behind it: the default face's background.
    pub background: Color,
    /// Its text rows, top to bottom: those that fit whole above its status
    /// row, or in its whole height when it has none.
    pub rows: Vec<FrameRow>,
    /// Its status row, when it has a status field.
    pub status: Option<StatusRow>,
    /// Its cursors on the rows shown: the head of every range of every
    /// selection.
    pub cursors: Vec<CursorBox>,
    /// What its selections cover on the rows shown: for each row and
    /// span, an area for each run of cells next to each other on the row
    /// that the span holds. That is one area where the text runs in one
    /// direction, and several where a span crosses a change of direction,
    /// each as wide as the cells it covers.
    pub selections: Vec<Area>,
    /// The colour of those areas: the selection face's background.
    pub selection: Color,
}

/// What to draw: the dividers, every view, in drawing order, and the fonts
/// their glyphs are drawn in.
///
/// Two frames are equal when their views, their dividers, their
/// generations and their tables of fonts are: a font is compared by what
/// it names and never by its bytes ([`ResolvedFont`]).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Frame {
    /// The views.
    pub views: Vec<ViewFrame>,
    /// The dividers between the views, each a fill of its rectangle,
    /// drawn before every view (module docs, "The dividers").
    pub dividers: Vec<Fill>,
    /// The shaper's generation the frame was laid out under
    /// ([`Shaper::generation`]). A glyph's font id means one font for one
    /// generation, so whatever is kept by font id and glyph id from the
    /// frames of one generation is dropped when a frame of another
    /// arrives.
    pub generation: u64,
    /// The fonts, by the id a glyph names its font with
    /// ([`Shaper::resolved`]): every glyph of every row and status row of
    /// the frame names an entry. Within a generation an entry never
    /// changes and the table only grows, so the table of a later frame
    /// describes the glyphs of an earlier one too.
    pub fonts: Arc<[ResolvedFont]>,
}

impl Frame {
    /// The frame as text: per view its rectangle, its background and its
    /// selection colour, then per row its geometry, its glyphs and its
    /// runs, then its status row if it has one, then its cursors and
    /// selections. No hash, and neither the generation nor the table of
    /// fonts.
    ///
    /// - A row is `row`, then ` x <x>` when its `x` is not 0 (a padded
    ///   view's), then its `y`, its height, its baseline and its bytes. A
    ///   block row has `block <i> ` before it.
    /// - A colour is its eight hexadecimal digits, `rrggbbaa`.
    /// - A glyph is `id@x`, with `^dx,dy` after it when its outline is
    ///   drawn off its pen position, and then `#font` when it is drawn in
    ///   a font other than entry 0 of the table.
    /// - A run is `start..end:paint`, and a paint is
    ///   `foreground/background`, then `+style:colour` when it has an
    ///   underline and `+strike` when it is struck through.
    /// - A status row's boxes follow its runs, after ` boxes`, each
    ///   `x+width:colour`.
    ///
    /// A font's id is its shaper's, given in the order the shaper first
    /// drew a glyph in each font (on the fake, the order it was first
    /// asked for each spec). So the text of a frame depends on which fonts
    /// its layout resolved before: two layouts are compared by their
    /// frames' texts, or by their frames, only when they were handed the
    /// same scenes, with the same faces, in the same order.
    pub fn describe(&self) -> String {
        let mut out = String::new();
        for view in &self.views {
            let rect = view.rect;
            let _ = writeln!(
                out,
                "view {} rect {} {} {} {} background {:08x} selection {:08x}",
                view.id.0,
                rect.x,
                rect.y,
                rect.width,
                rect.height,
                view.background.0,
                view.selection.0
            );
            for row in &view.rows {
                out.push_str("  ");
                if let Some(block) = row.block {
                    let _ = write!(out, "block {block} ");
                }
                out.push_str("row");
                if row.x != 0.0 {
                    let _ = write!(out, " x {}", row.x);
                }
                let _ = write!(
                    out,
                    " y {} height {} baseline {} bytes {}..{}",
                    row.y, row.height, row.baseline, row.bytes.start, row.bytes.end
                );
                describe_line(&mut out, &row.line, &row.runs);
            }
            if let Some(status) = &view.status {
                let _ = write!(
                    out,
                    "  status y {} height {} baseline {} background {:08x}",
                    status.y, status.height, status.baseline, status.background.0
                );
                describe_line(&mut out, &status.line, &status.runs);
                out.pop();
                out.push_str(" boxes");
                for status_box in &status.boxes {
                    let _ = write!(
                        out,
                        " {}+{}:{:08x}",
                        status_box.x, status_box.width, status_box.background.0
                    );
                }
                out.push('\n');
            }
            for cursor in &view.cursors {
                let shape = match cursor.shape {
                    CursorShape::Block => "block",
                    CursorShape::Bar => "bar",
                    CursorShape::Underline => "underline",
                    CursorShape::Hollow => "hollow",
                };
                let area = cursor.area;
                let _ = writeln!(
                    out,
                    "  cursor {shape} paint {} at {} {} {} {}",
                    described(&cursor.paint),
                    area.x,
                    area.y,
                    area.width,
                    area.height
                );
            }
            for area in &view.selections {
                let _ = writeln!(
                    out,
                    "  selection at {} {} {} {}",
                    area.x, area.y, area.width, area.height
                );
            }
        }
        out
    }
}

/// Adds to `out` the glyphs of `line` and `runs`, as [`Frame::describe`]
/// writes them, and ends the line.
fn describe_line(out: &mut String, line: &VisualLine, runs: &[(Range<usize>, Paint)]) {
    out.push_str(" glyphs");
    for glyph in &line.glyphs {
        let _ = write!(out, " {}@{}", glyph.id, glyph.x);
        if glyph.dx != 0.0 || glyph.dy != 0.0 {
            let _ = write!(out, "^{},{}", glyph.dx, glyph.dy);
        }
        if glyph.font != ResolvedFontId::default() {
            let _ = write!(out, "#{}", glyph.font.0);
        }
    }
    out.push_str(" runs");
    for (bytes, paint) in runs {
        let _ = write!(out, " {}..{}:{}", bytes.start, bytes.end, described(paint));
    }
    out.push('\n');
}

/// `paint` as [`Frame::describe`] writes it.
fn described(paint: &Paint) -> String {
    let mut out = format!("{:08x}/{:08x}", paint.foreground.0, paint.background.0);
    if let Some((style, color)) = paint.underline {
        let style = match style {
            UnderlineStyle::None => "none",
            UnderlineStyle::Single => "single",
            UnderlineStyle::Double => "double",
            UnderlineStyle::Curly => "curly",
            UnderlineStyle::Dotted => "dotted",
            UnderlineStyle::Dashed => "dashed",
        };
        let _ = write!(out, "+{style}:{:08x}", color.0);
    }
    if paint.strike_through {
        out.push_str("+strike");
    }
    out
}

/// How far from the rows a view shows its text's entries are kept at a
/// publish, in view heights (counted in buffer rows): farther ones are
/// dropped, and laid out again if they are reached.
pub const KEPT_VIEW_HEIGHTS: usize = 4;

/// The id of the view frame that holds the echo in the frame's bottom row
/// (module docs, "The bottom row"): an id the wire never sends for a view.
pub const ECHO_VIEW: ViewId = ViewId(u64::MAX);

/// The heights of the rows a frame is built of, in whole physical pixels
/// at the layout's scale, each its line height, and for a status row its
/// face's vertical padding above and below, rounded up and at least 1
/// ([`Layout::heights`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Heights {
    /// One text row in the default face. The default face's vertical
    /// padding is no text row's.
    pub text: u32,
    /// A window's status row: the face `mode-line` over the default face,
    /// its line and its vertical padding twice.
    pub status: u32,
    /// The frame's bottom row, where the echo text or a prompt is drawn:
    /// the taller of the face `echo-area` and the face `mode-line`, each
    /// over the default face and each with its vertical padding twice.
    pub message: u32,
}

/// Whether `a` and `b` have a pixel in common.
fn overlap(a: Rect, b: Rect) -> bool {
    let (a_right, a_foot) = (a.x.saturating_add(a.width), a.y.saturating_add(a.height));
    let (b_right, b_foot) = (b.x.saturating_add(b.width), b.y.saturating_add(b.height));
    a.x < b_right && b.x < a_right && a.y < b_foot && b.y < a_foot
}

/// `line_height` rounded up to a whole pixel, and at least 1.
fn whole_pixels(line_height: f32) -> u32 {
    // A height that is no number rounds to 0, and is then 1.
    (line_height.ceil() as u32).max(1)
}

impl<S: Shaper> Layout<S> {
    /// The heights of a text row, a status row and the frame's bottom row,
    /// in the faces as last defined and at the scale last set: what the
    /// frame lays those rows out at (module docs, "The mode line"). A
    /// caller that sizes a view's text area by them asks the rows query
    /// for exactly the rows the frame shows.
    pub fn heights(&mut self) -> Heights {
        let mode_line = self.styles.intern(MODE_LINE_FACE);
        let echo_area = self.styles.intern(ECHO_AREA_FACE);
        let line_of = |stack: &[FaceId], padded: bool| {
            let style = self.styles.style(&self.shaper, stack);
            let padding = if padded {
                2.0 * style.vertical_padding.as_pixels()
            } else {
                0.0
            };
            whole_pixels(self.shaper.metrics(style.font).line_height + padding)
        };
        let status = line_of(&[mode_line], true);
        Heights {
            text: line_of(&[], false),
            status,
            message: status.max(line_of(&[echo_area], true)),
        }
    }
    /// Lays `scene` out into a frame, in the faces it carries, or in those
    /// of the last scene that carried any. What is kept of every text it
    /// does not name is dropped, and of each text it names, every row
    /// farther than [`KEPT_VIEW_HEIGHTS`] view heights from the rows every
    /// view of it shows.
    pub fn frame(&mut self, scene: &Scene) -> Frame {
        if let Some(definitions) = &scene.faces {
            self.define(definitions);
        }
        let mut views: Vec<ViewFrame> = scene
            .views
            .iter()
            .map(|view| {
                let bottom_edge = view.rect.y.saturating_add(view.rect.height) >= scene.size.height;
                self.view_frame(view, bottom_edge, &[])
            })
            .collect();
        let echo = self.echo_frame(scene);
        let echoed = echo.is_some();
        views.extend(echo);
        // Read once the views are laid out, so the table holds every font
        // a glyph of theirs names.
        let dividers = scene
            .dividers
            .iter()
            .map(|divider| {
                let face = self.styles.intern(&divider.face);
                Fill {
                    rect: divider.rect,
                    color: self.styles.style(&self.shaper, &[face]).paint.foreground,
                }
            })
            .collect();
        let frame = Frame {
            views,
            dividers,
            generation: self.shaper.generation(),
            fonts: self.shaper.resolved(),
        };
        // The buffer rows each view shows, by text.
        let mut shown: HashMap<TextKey, Vec<Range<usize>>> = HashMap::new();
        for (view, laid) in scene.views.iter().zip(&frame.views) {
            let Some(text) = &view.text else { continue };
            let rows = shown.entry(text.key).or_default();
            let row_of = |offset| {
                text.snapshot
                    .offset_to_point(offset)
                    .map_or(0, |point| point.row)
            };
            let text_row = |row: &&FrameRow| row.block.is_none();
            let first = laid.rows.iter().find(text_row);
            let last = laid.rows.iter().rev().find(text_row);
            if let (Some(first), Some(last)) = (first, last) {
                let (first, last) = (row_of(first.bytes.start), row_of(last.bytes.end));
                let reach = KEPT_VIEW_HEIGHTS * (last - first + 1);
                rows.push(first.saturating_sub(reach)..last + reach + 1);
            }
        }
        self.texts.retain(|key, _| shown.contains_key(key));
        // The blocks no view names are dropped.
        let named: HashSet<BlockKey> = scene
            .views
            .iter()
            .flat_map(|view| &view.blocks)
            .map(BlockKey::of)
            .collect();
        self.blocks.retain(|key, _| named.contains(key));
        for (key, state) in &mut self.texts {
            let near = &shown[key];
            state
                .wrap
                .retain_rows(|row| near.iter().any(|rows| rows.contains(&row)));
        }
        // The status row of every view the scene does not name is dropped,
        // and the echo's when it was not laid out.
        self.status.retain(|id, _| {
            (*id == ECHO_VIEW && echoed) || scene.views.iter().any(|view| view.id == *id)
        });
        frame
    }

    /// The echo's view frame (module docs, "The bottom row"): when the
    /// scene's echo is not empty and no view of it covers any pixel of the
    /// frame's bottom row, a view frame [`ECHO_VIEW`] that is that row
    /// across the frame, with no text and one status row of the echo in
    /// the face `echo-area` over the default face. The row is
    /// [`Heights::message`] tall, or the frame's height when that is less;
    /// a frame of no width or no height has none.
    fn echo_frame(&mut self, scene: &Scene) -> Option<ViewFrame> {
        if scene.echo.is_empty() {
            return None;
        }
        let Size { width, height } = scene.size;
        let tall = self.heights().message.min(height);
        let row = Rect {
            x: 0,
            y: height - tall,
            width,
            height: tall,
        };
        if row.width == 0
            || row.height == 0
            || scene.views.iter().any(|view| overlap(view.rect, row))
        {
            return None;
        }
        let view = View {
            id: ECHO_VIEW,
            rect: row,
            status: vec![StatusField {
                text: scene.echo.clone(),
                face: ECHO_AREA_FACE.to_owned(),
                ..StatusField::default()
            }],
            ..View::default()
        };
        let inset = self.padding_pixels(scene.echo_padding);
        let status = self.status_row(&view, ECHO_AREA_FACE, tall, inset);
        let selection = self.styles.intern(SELECTION_FACE);
        let paint_of = |stack: &[FaceId]| self.styles.style(&self.shaper, stack).paint;
        Some(ViewFrame {
            id: ECHO_VIEW,
            rect: row,
            background: paint_of(&[]).background,
            rows: Vec::new(),
            status,
            cursors: Vec::new(),
            selections: Vec::new(),
            selection: paint_of(&[selection]).background,
        })
    }

    /// The status row of `view`, when it has a status field (module docs,
    /// "The mode line"): each field's text shaped as a line of its own, in
    /// its face over the view's status face over the face `base` over the
    /// default face's, and placed on its side with its padding each side.
    /// A tab, a carriage return and a line feed in a field are shaped as a
    /// space each, so the row is one line and holds no tab.
    ///
    /// Each field's line is kept per view, and shaped again only when its
    /// text, its font or the shaper's generation change: a change of paint
    /// shapes nothing, and a change of one field shapes that field alone.
    ///
    /// The row is exactly as tall as `height`, whatever height its lines
    /// were shaped at, and sits at the view's bottom, its line below the
    /// vertical padding of the face `base`: the mode line for a view's
    /// status row, and the echo area for the echo's. Its fields are inset
    /// `inset` pixels from the view's left and right edges, and its
    /// background is not.
    fn status_row(
        &mut self,
        view: &View,
        base: &str,
        height: u32,
        inset: f32,
    ) -> Option<StatusRow> {
        if view.status.is_empty() {
            self.status.remove(&view.id);
            return None;
        }
        let base_face = self.styles.intern(base);
        let mut stack = vec![base_face];
        if let Some(face) = &view.status_face {
            stack.push(self.styles.intern(face));
        }
        let row = self.styles.style(&self.shaper, &stack);
        // The line sits below the row face's padding, in whole pixels.
        let padding = self
            .styles
            .style(&self.shaper, &[base_face])
            .vertical_padding
            .as_pixels()
            .floor();
        let scale = self.styles.scale();
        let generation = self.shaper.generation();
        let kept = self
            .status
            .remove(&view.id)
            .filter(|kept| kept.generation == generation)
            .map(|kept| kept.fields)
            .unwrap_or_default();
        let mut fields_kept: Vec<FieldKept> = Vec::new();
        let mut text_len = 0;
        let mut runs: Vec<(Range<usize>, Paint)> = Vec::new();
        let mut placed: Vec<Placed> = Vec::new();
        for field in &view.status {
            let mut field_stack = stack.clone();
            field_stack.push(self.styles.intern(&field.face));
            let style = self.styles.style(&self.shaper, &field_stack);
            let text: String = field
                .text
                .chars()
                .map(|character| match character {
                    '\t' | '\r' | '\n' => ' ',
                    other => other,
                })
                .collect();
            let bytes = text_len..text_len + text.len();
            text_len = bytes.end;
            let line = if bytes.is_empty() {
                None
            } else {
                match runs.last_mut() {
                    Some((last, paint)) if *paint == style.paint => last.end = bytes.end,
                    _ => runs.push((bytes.clone(), style.paint)),
                }
                self.field_line(text, style.font, &kept, &mut fields_kept)
            };
            placed.push(Placed {
                side: field.side,
                padding: field.padding as f32 * scale,
                start: bytes.start,
                line,
                background: style.paint.background,
            });
        }
        // The row's line is as tall as its tallest field's, on the lowest
        // baseline; an empty row is as tall as the row face's font.
        let mut lines: Vec<Arc<VisualLine>> = placed
            .iter()
            .filter_map(|field| field.line.clone())
            .collect();
        if lines.is_empty() {
            lines.extend(self.field_line(String::new(), row.font, &kept, &mut fields_kept));
        }
        let line_height = lines.iter().map(|line| line.height).fold(0.0, f32::max);
        let line_baseline = lines.iter().map(|line| line.baseline).fold(0.0, f32::max);
        self.status.insert(
            view.id,
            StatusKept {
                generation,
                fields: fields_kept,
            },
        );
        let width = view.rect.width as f32;
        let span = |field: &Placed| {
            2.0 * field.padding + field.line.as_ref().map_or(0.0, |line| line.width)
        };
        let right: f32 = placed
            .iter()
            .filter(|field| field.side == Side::Right)
            .map(span)
            .sum();
        let has_right = placed.iter().any(|field| field.side == Side::Right);
        // The fields run between the insets.
        let end = (width - inset).max(inset);
        // Where the right side starts, and so where the left side is cut;
        // with no right side nothing is cut.
        let cut = if has_right {
            (end - right).max(inset)
        } else {
            f32::INFINITY
        };
        let mut glyphs = Vec::new();
        let mut boxes = Vec::new();
        for (side, from) in [(Side::Left, inset), (Side::Right, cut.min(end))] {
            let mut x = from;
            for field in placed.iter().filter(|field| field.side == side) {
                let across = span(field);
                let stop = match side {
                    Side::Left => (x + across).min(cut),
                    Side::Right => x + across,
                };
                if stop > x {
                    boxes.push(StatusBox {
                        x,
                        width: stop - x,
                        background: field.background,
                    });
                }
                if let Some(line) = &field.line {
                    let offset = x + field.padding;
                    glyphs.extend(
                        line.glyphs
                            .iter()
                            .map(|glyph| Glyph {
                                x: glyph.x + offset,
                                cluster: glyph.cluster + field.start,
                                ..*glyph
                            })
                            .filter(|glyph| side == Side::Right || glyph.x + glyph.advance <= cut),
                    );
                }
                x += across;
            }
        }
        let line = Arc::new(VisualLine {
            bytes: 0..text_len,
            width: glyphs
                .iter()
                .map(|glyph| glyph.x + glyph.advance)
                .fold(0.0, f32::max),
            glyphs,
            height: line_height,
            baseline: line_baseline,
        });
        let background = row.paint.background;
        let baseline = padding + line.baseline;
        let height = height as f32;
        Some(StatusRow {
            y: view.rect.height.saturating_sub(height as u32) as f32,
            height,
            baseline,
            hash: {
                let mut hasher = DefaultHasher::new();
                (hash(&line, &runs), background).hash(&mut hasher);
                (height.to_bits(), baseline.to_bits()).hash(&mut hasher);
                for status_box in &boxes {
                    (status_box.x.to_bits(), status_box.width.to_bits()).hash(&mut hasher);
                    status_box.background.hash(&mut hasher);
                }
                hasher.finish()
            },
            line,
            runs,
            background,
            boxes,
        })
    }

    /// The line of a status field of `text` in `font`: the one kept in
    /// `kept` or already in `fields` for that text and font, or else
    /// shaped. It is added to `fields`, the row's kept lines, once.
    fn field_line(
        &self,
        text: String,
        font: FontId,
        kept: &[FieldKept],
        fields: &mut Vec<FieldKept>,
    ) -> Option<Arc<VisualLine>> {
        let runs = vec![FontRun {
            bytes: 0..text.len(),
            font,
        }];
        let same = |field: &&FieldKept| field.text == text && field.runs == runs;
        if let Some(field) = fields.iter().find(same) {
            return Some(Arc::clone(&field.line));
        }
        let line = match kept.iter().find(same) {
            Some(field) => Arc::clone(&field.line),
            None => {
                let shaped = self.shaper.shape(&ShapeInput {
                    text: text.clone(),
                    runs: runs.clone(),
                });
                Arc::new(shaped.break_lines(None).into_iter().next()?)
            }
        };
        fields.push(FieldKept {
            text,
            runs,
            line: Arc::clone(&line),
        });
        Some(line)
    }

    /// The frame of `view`, with `extra` sources of spans under its
    /// decorations: the layers over a run are, lowest first, its text's own
    /// spans ([`TextRef::spans`](crate::scene::TextRef::spans)), `extra` in
    /// order, the view's decorations in the order the scene lists them, and
    /// the selections ([`face`](crate::face), "The precedence"). A view at
    /// the frame's `bottom_edge` has a status row of the message height,
    /// and any other one of the status height ([`Layout::heights`]).
    pub(crate) fn view_frame(
        &mut self,
        view: &View,
        bottom_edge: bool,
        extra: &[&dyn DecorationSource],
    ) -> ViewFrame {
        let heights = self.heights();
        let bottom = if bottom_edge {
            heights.message
        } else {
            heights.status
        };
        let across = self.padding_pixels(view.padding.across);
        let first_row = self.first_row(view.padding);
        let status = self.status_row(view, MODE_LINE_FACE, bottom, across);
        // What is left for the text above the status row, in whole pixels,
        // less the padding above and below it (module docs, "The padding").
        let text_height = match status {
            Some(_) => view.rect.height.saturating_sub(bottom),
            None => view.rect.height,
        } as f32;
        let text_height = self.text_height(text_height, view.padding);
        let text_width = self.inset(view.rect.width as f32, view.padding.across);
        let cursor_face = self.styles.intern(&view.cursor.face);
        let selection_face = self.styles.intern(SELECTION_FACE);
        let paint_of = |stack: &[FaceId]| self.styles.style(&self.shaper, stack).paint;
        let cursor_paint = paint_of(&[cursor_face]);
        let mut frame = ViewFrame {
            id: view.id,
            rect: view.rect,
            background: paint_of(&[]).background,
            rows: Vec::new(),
            status,
            cursors: Vec::new(),
            selections: Vec::new(),
            selection: paint_of(&[selection_face]).background,
        };
        let Some(text) = &view.text else {
            return frame;
        };
        let snapshot = &text.snapshot;
        let decorations: Vec<Span> = view
            .decorations
            .iter()
            .map(|decoration| {
                let start = boundary_at_or_before(snapshot, decoration.start);
                Span {
                    bytes: start..boundary_at_or_before(snapshot, decoration.stop).max(start),
                    face: self.styles.intern(&decoration.face),
                }
            })
            .collect();
        let mut view_blocks = ViewBlocks::new(&view.blocks, snapshot, &mut self.styles);
        let selections: Vec<Selection> = view
            .selections
            .iter()
            .filter_map(|selection| moved_back(snapshot, selection))
            .collect();
        let selection_source = SelectionSource::new(snapshot, &selections, selection_face);
        let face_source = FaceSpanSource::new(decorations);
        let own = TextSpansSource::of(&mut self.styles, text);
        // Every source, lowest layer first: the text's own spans, `extra`,
        // the decorations and the selections.
        let mut sources: Vec<&dyn DecorationSource> = Vec::new();
        if let Some(own) = &own {
            sources.push(own);
        }
        sources.extend_from_slice(extra);
        sources.push(&face_source);
        sources.push(&selection_source);
        let (styles, shaper, base) = (&self.styles, &self.shaper, self.base);
        let fonts = |bytes: Range<usize>| fonts_of(&sources, snapshot, bytes, styles, shaper, base);
        let mut held = state(&mut self.texts, text, self.tab_width, Some(text_width));
        let state = &mut *held;
        let mut seen: HashMap<(usize, usize), Outcome> = HashMap::new();
        let mut walker = Walker {
            shaper: &self.shaper,
            wrap: &mut state.wrap,
            base,
            fonts: &fonts,
            outcome: &mut |row, segment, outcome| {
                seen.entry((row, segment)).or_insert(outcome);
            },
        };
        let anchor = boundary_at_or_before(snapshot, view.scroll);
        let mut block_layout = BlockLayout {
            store: &mut self.blocks,
            shaper,
            styles,
            base,
            tab_width: self.tab_width,
            width: text_width,
            counters: &mut self.counters,
        };
        let walked = walker
            .shown(text_height, anchor, &mut |row| {
                view_blocks.above(row, &mut block_layout)
            })
            .unwrap_or_default();
        // The text lines shown, each with its index among the frame's rows.
        let mut shown: Vec<(Visual, usize)> = Vec::new();
        let mut y = first_row;
        for item in walked {
            let visual = match item {
                Shown::Text(visual) => visual,
                Shown::Block { block, line, .. } => {
                    if let Some(laid) = view_blocks.line(block, line) {
                        frame.rows.push(FrameRow {
                            block: Some(block),
                            ..FrameRow::text_row(
                                across,
                                y,
                                laid.bytes.clone(),
                                Arc::clone(&laid.line),
                                laid.runs.clone(),
                                laid.hash,
                            )
                        });
                        y += laid.line.height;
                    }
                    continue;
                }
            };
            let Some(entry) = walker.entry(visual.row, visual.segment) else {
                continue;
            };
            let Some(line) = entry.lines().get(visual.line).cloned() else {
                continue;
            };
            let range = walker.range(visual);
            let bytes = range.start..range.stop;
            let row_start = snapshot.row_range(visual.row).map_or(0, |row| row.start);
            let painted = paint_line(
                &entry,
                visual.line,
                &line,
                row_start,
                snapshot,
                &sources,
                styles,
                shaper,
            );
            // What each selected span covers of the row: an area for each
            // run of cells next to each other that it holds, so one area
            // in text of one direction, and several where it crosses a
            // change of direction. The selections are the last source.
            let columns = &line.bytes;
            for span in &painted.spans[painted.last..] {
                let held = columns.start + span.bytes.start..columns.start + span.bytes.end;
                let covered = entry.cells(visual.line).map(|cells| cells.covered(held));
                for (left, right) in covered.unwrap_or_default() {
                    frame.selections.push(Area {
                        x: across + left,
                        y,
                        width: right - left,
                        height: line.height,
                    });
                }
            }
            shown.push((visual, frame.rows.len()));
            frame.rows.push(FrameRow::text_row(
                across,
                y,
                bytes,
                Arc::clone(&line),
                painted.runs,
                painted.hash,
            ));
            y += line.height;
        }
        // The cursors on the rows shown.
        let last = shown.last().map_or(
            Visual {
                row: 0,
                segment: 0,
                line: 0,
            },
            |(visual, _)| *visual,
        );
        let from = shown
            .first()
            .map_or(0, |(_, index)| frame.rows[*index].bytes.start);
        let to = snapshot
            .row_range(last.row)
            .map_or(snapshot.len(), |row| row.end);
        let advance = self.shaper.metrics(base).advance;
        for range in selections.iter().flat_map(|selection| selection.ranges()) {
            let head = range.head;
            if shown.is_empty() || head < from || head > to {
                continue;
            }
            let Ok((visual, x)) = walker.locate(head) else {
                continue;
            };
            let Some(&(_, index)) = shown.iter().find(|(shown, _)| *shown == visual) else {
                continue;
            };
            let row = &frame.rows[index];
            let row_start = snapshot.row_range(visual.row).map_or(0, |row| row.start);
            // As wide as the cell it is on, which is a share of its glyph
            // where the glyph draws several characters; at a line's end,
            // where there is no cell, as wide as a space of the base font.
            let width = walker
                .entry(visual.row, visual.segment)
                .and_then(|entry| {
                    let column = entry.column(head - row_start);
                    entry.cell_of_column(visual.line, column)
                })
                .map_or(advance, |cell| cell.width);
            frame.cursors.push(CursorBox {
                area: Area {
                    x: row.x + x,
                    y: row.y,
                    width,
                    height: row.height,
                },
                shape: view.cursor.shape,
                paint: cursor_paint,
            });
        }
        state.sources = Some((selection_source.clone(), face_source.clone()));
        self.counters.add(&seen);
        frame
    }
}

/// `selection` with each end moved back to a position of `snapshot`.
fn moved_back(snapshot: &Snapshot, selection: &Selection) -> Option<Selection> {
    let ranges = selection
        .ranges()
        .iter()
        .map(|range| {
            SelectionRange::new(
                boundary_at_or_before(snapshot, range.anchor),
                boundary_at_or_before(snapshot, range.head),
            )
        })
        .collect();
    Selection::shaped(selection.shape(), ranges, selection.primary())
}

/// A visual line painted ([`paint_line`]).
pub(crate) struct PaintedLine {
    /// Each span of the line's sources as the columns of the line it
    /// covers, from the line's start, lowest layer first; a span that
    /// covers none of them is left out.
    pub spans: Vec<Span>,
    /// Where the last source's spans start in `spans`.
    pub last: usize,
    /// Its runs, each with what its faces come to, neighbours of one paint
    /// made one run.
    pub runs: Vec<(Range<usize>, Paint)>,
    /// Its content hash ([`hash`]).
    pub hash: u64,
}

/// Visual line `index` of `entry`, which is `line`, painted: the entry is
/// of a buffer row of `snapshot` that starts at `row_start`, its spans are
/// what `sources` give, lowest layer first, and their faces come to paints
/// in `styles`. A view's text rows and its blocks' rows are painted so.
///
/// The spans asked for are those of the characters the line draws any of,
/// which is more than its bytes when it starts inside a tab's spaces, and
/// each is cut to the columns of the line it covers: a tab's span to the
/// spaces of it the line holds.
#[allow(clippy::too_many_arguments)]
pub(crate) fn paint_line<L, S: Shaper>(
    entry: &LineEntry<L>,
    index: usize,
    line: &VisualLine,
    row_start: usize,
    snapshot: &Snapshot,
    sources: &[&dyn DecorationSource],
    styles: &Styles,
    shaper: &S,
) -> PaintedLine {
    let drawn = entry.drawn_bytes(index).unwrap_or(0..0);
    let bytes = row_start + drawn.start..row_start + drawn.end;
    let mut found = Vec::new();
    let mut below = 0;
    for source in sources {
        below = found.len();
        source.spans(snapshot, bytes.clone(), &mut found);
    }
    let columns = line.bytes.clone();
    let column = |offset: usize| {
        entry
            .column(offset - row_start)
            .clamp(columns.start, columns.end)
            - columns.start
    };
    let on_line = |span: &Span| {
        let covered = column(span.bytes.start)..column(span.bytes.end);
        (!covered.is_empty()).then_some(Span {
            bytes: covered,
            face: span.face,
        })
    };
    let mut spans: Vec<Span> = found[..below].iter().filter_map(on_line).collect();
    let last = spans.len();
    spans.extend(found[below..].iter().filter_map(on_line));
    let mut runs: Vec<(Range<usize>, Paint)> = Vec::new();
    for run in merge(0..columns.len(), &spans) {
        let paint = styles.style(shaper, &run.faces).paint;
        match runs.last_mut() {
            Some((bytes, last)) if *last == paint => bytes.end = run.bytes.end,
            _ => runs.push((run.bytes, paint)),
        }
    }
    PaintedLine {
        hash: hash(line, &runs),
        spans,
        last,
        runs,
    }
}

/// The content hash of a row of `line` with `runs`: its glyphs and runs
/// relative to its start, and its height.
fn hash(line: &VisualLine, runs: &[(Range<usize>, Paint)]) -> u64 {
    let mut hasher = DefaultHasher::new();
    line.height.to_bits().hash(&mut hasher);
    line.baseline.to_bits().hash(&mut hasher);
    for glyph in &line.glyphs {
        (glyph.id, glyph.font, glyph.cluster - line.bytes.start).hash(&mut hasher);
        (glyph.x.to_bits(), glyph.advance.to_bits()).hash(&mut hasher);
        (glyph.dx.to_bits(), glyph.dy.to_bits()).hash(&mut hasher);
    }
    runs.hash(&mut hasher);
    hasher.finish()
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::hash::{DefaultHasher, Hash, Hasher};
    use std::ops::Range;
    use std::sync::Arc;

    use editor_text::{Selection, SelectionRange, Shape, Snapshot, Text};

    use super::{Area, Fill, Frame, FrameRow, StatusRow, ViewFrame};
    use crate::Layout;
    use crate::decoration::{DecorationSource, Span};
    use crate::face::{
        BASE_BACKGROUND, BASE_FOREGROUND, Color, Face, FaceDef, Paint, Underline, UnderlineStyle,
    };
    use crate::scene::{
        Block, Cursor, CursorShape, Decoration, Divider, FixedSpans, Padding, Rect, Scene, Side,
        SpansAt, StatusField, TextKey, TextRef, TextSpans, View, ViewId,
    };
    use crate::shaper::fake::CellShaper;
    use crate::shaper::scripted::{ScriptedShaper, glyph, line};
    use crate::shaper::{
        FontId, FontSpec, Glyph, Length, LineHeight, ResolvedFontId, Shaper, VisualLine, Weight,
    };

    const RED: Color = Color::rgb(0xcc, 0, 0);
    const GREEN: Color = Color::rgb(0, 0xcc, 0);
    const BLUE: Color = Color::rgb(0, 0, 0xcc);
    const GREY: Color = Color::rgb(0x80, 0x80, 0x80);

    /// The definition of `name` as `face`.
    fn def(name: &str, face: Face) -> FaceDef {
        FaceDef {
            name: name.to_owned(),
            face,
        }
    }

    /// A face in the family `name` and nothing else.
    fn family(name: &str) -> Face {
        Face {
            family: Some(name.to_owned()),
            ..Face::default()
        }
    }

    /// A face of the foreground `color` and nothing else.
    fn fg(color: Color) -> Face {
        Face {
            foreground: Some(color),
            ..Face::default()
        }
    }

    /// A face of the background `color` and nothing else.
    fn bg(color: Color) -> Face {
        Face {
            background: Some(color),
            ..Face::default()
        }
    }

    /// The paint of `foreground` on `background`, with no underline and
    /// no strike-through.
    fn paint(foreground: Color, background: Color) -> Paint {
        Paint {
            foreground,
            background,
            ..Paint::default()
        }
    }

    /// The base paint: what a run under no face is drawn with while no
    /// default face is defined.
    const PLAIN: Paint = Paint {
        foreground: BASE_FOREGROUND,
        background: BASE_BACKGROUND,
        underline: None,
        strike_through: false,
    };

    /// What the selection of [`layout`] is drawn with over the base paint.
    const SELECTED: Paint = Paint {
        foreground: BASE_FOREGROUND,
        background: BLUE,
        underline: None,
        strike_through: false,
    };

    /// A layout on cells 10 by 16, with a family of lines 32 tall that the
    /// face `tall` is in, a selection on blue, and the faces `tab` in red
    /// and `face` in green.
    fn layout() -> Layout<CellShaper> {
        let mut layout = Layout::new(CellShaper::new(10.0, 16.0).with_family("tall", 10.0, 32.0));
        layout.define(&[
            def("tall", family("tall")),
            def("selection", bg(BLUE)),
            def("tab", fg(RED)),
            def("face", fg(GREEN)),
        ]);
        layout
    }

    /// A key for `text`: one per text, as the binding gives one per
    /// document.
    fn key(text: &str) -> TextKey {
        let mut hasher = DefaultHasher::new();
        text.hash(&mut hasher);
        TextKey(hasher.finish())
    }

    /// A view of `text` `columns` cells wide and `height` pixels tall,
    /// scrolled to `scroll`, with the cursors and selections `ranges`.
    fn view(
        text: &str,
        columns: u32,
        height: u32,
        scroll: usize,
        ranges: &[(usize, usize)],
    ) -> View {
        View {
            id: ViewId(1),
            rect: Rect {
                x: 0,
                y: 0,
                width: columns * 10,
                height,
            },
            text: Some(TextRef::fixed(key(text), Text::from(text).snapshot())),
            scroll,
            selections: if ranges.is_empty() {
                vec![]
            } else {
                vec![
                    Selection::new(
                        ranges
                            .iter()
                            .map(|&(anchor, head)| SelectionRange::new(anchor, head))
                            .collect(),
                        0,
                    )
                    .unwrap(),
                ]
            },
            cursor: Cursor {
                shape: CursorShape::Block,
                face: "cursor".to_owned(),
            },
            decorations: vec![],
            status: vec![],
            status_face: None,
            padding: Padding::default(),
            blocks: vec![],
        }
    }

    /// The frame of `view` alone.
    fn frame<S: Shaper>(layout: &mut Layout<S>, view: View) -> ViewFrame {
        let scene = Scene {
            views: vec![view],
            ..Scene::default()
        };
        layout.frame(&scene).views.remove(0)
    }

    /// The tops of `rows`.
    fn tops(rows: &[FrameRow]) -> Vec<f32> {
        rows.iter().map(|row| row.y).collect()
    }

    #[test]
    fn a_text_row_built_by_hand_is_as_tall_as_its_line_and_equals_the_frames() {
        let mut layout = layout();
        let laid = frame(&mut layout, view("ab\ncd", 4, 64, 0, &[])).rows;
        let second = &laid[1];
        let built = FrameRow::text_row(
            second.x,
            second.y,
            second.bytes.clone(),
            Arc::clone(&second.line),
            second.runs.clone(),
            second.hash,
        );
        assert_eq!(&built, second);
        assert_eq!(
            (built.height, built.baseline),
            (second.line.height, second.line.baseline)
        );
    }

    #[test]
    fn rows_of_different_heights_stack() {
        let mut layout = layout();
        let mut tall = view("ab\ncd\nef", 4, 64, 0, &[]);
        tall.decorations = vec![Decoration {
            start: 3,
            stop: 5,
            face: "tall".to_owned(),
        }];
        let rows = frame(&mut layout, tall.clone()).rows;
        assert_eq!(
            rows.iter().map(|row| row.height).collect::<Vec<_>>(),
            vec![16.0, 32.0, 16.0]
        );
        assert_eq!(tops(&rows), vec![0.0, 16.0, 48.0]);
        // The rows that fit are counted by their heights: 63 pixels hold
        // the first two.
        tall.rect.height = 63;
        assert_eq!(frame(&mut layout, tall.clone()).rows.len(), 2);
        // The rows query fits them by their heights too, in the fonts of
        // the last frame that showed the text.
        let text = tall.text.unwrap();
        assert_eq!(
            layout
                .rows_shown(&text, 40.0, 63.0, Padding::default(), 0)
                .unwrap()
                .len(),
            2
        );
        assert_eq!(
            layout
                .rows_shown(&text, 40.0, 64.0, Padding::default(), 0)
                .unwrap()
                .len(),
            3
        );
    }

    #[test]
    fn a_row_of_no_height_takes_a_pixel_of_the_count_and_none_of_the_frame() {
        // The second row is in a face of size 0, whose lines have no
        // height.
        let mut layout = layout_with(&[def("flat", sized(0))]);
        let flat = decorated(view("ab\ncd\nef\ngh", 4, 48, 0, &[]), &[(3..5, "flat")]);
        let rows = frame(&mut layout, flat).rows;
        // In the count of the rows that fit it is a pixel tall: 16, 1 and
        // 16 leave 15 of the 48, which do not hold the fourth row.
        assert_eq!(rows.len(), 3);
        // In the frame it is as tall as the shaper made it, and the row
        // after it starts where it does.
        assert_eq!(
            rows.iter().map(|row| row.height).collect::<Vec<_>>(),
            vec![16.0, 0.0, 16.0]
        );
        assert_eq!(tops(&rows), vec![0.0, 16.0, 16.0]);
    }

    #[test]
    fn scrolling_by_n_lines_starts_the_frame_n_rows_down() {
        let text = "abcdefgh\nij\nklmnopqrst\nuv";
        let mut layout = layout();
        let at_top = frame(&mut layout, view(text, 4, 160, 0, &[]));
        let snapshot = TextRef::fixed(key(text), Text::from(text).snapshot());
        for n in 1..=5 {
            let moved = layout
                .lines_from(&snapshot, 40.0, 0, 0, n, Some(0.0))
                .unwrap();
            let scrolled = frame(&mut layout, view(text, 4, 160, moved.position, &[]));
            let expected = &at_top.rows[usize::try_from(n).unwrap()];
            let first = &scrolled.rows[0];
            assert_eq!(first.bytes, expected.bytes, "{n} lines down");
            assert_eq!(first.line, expected.line);
            assert_eq!(first.hash, expected.hash);
            assert_eq!(first.y, 0.0);
        }
    }

    #[test]
    fn scrolling_by_n_lines_reaches_every_row_of_a_text_with_tabs() {
        // Tabs that end a row, start one, cross a wrap and are wider than
        // the view, at every width from one column to twelve.
        let texts = [
            "abc\tdef\nzz",
            "abcdefghi\tx",
            "\tgh",
            "a\tb\tc",
            "é\t😀\tz",
            "ab\t",
            "\t\t\n\t",
        ];
        for text in texts {
            for columns in 1..=12_u32 {
                let mut layout = layout();
                let at_top = frame(&mut layout, view(text, columns, 1600, 0, &[]));
                let snapshot = TextRef::fixed(key(text), Text::from(text).snapshot());
                let width = columns as f32 * 10.0;
                for (n, expected) in at_top.rows.iter().enumerate() {
                    let lines = i64::try_from(n).unwrap();
                    let moved = layout
                        .lines_from(&snapshot, width, 0, 0, lines, Some(0.0))
                        .unwrap();
                    let scrolled =
                        frame(&mut layout, view(text, columns, 1600, moved.position, &[]));
                    let first = &scrolled.rows[0];
                    let case = format!("{text:?} at {columns} columns, {n} lines down");
                    assert_eq!(first.bytes, expected.bytes, "{case}");
                    assert_eq!(first.line, expected.line, "{case}");
                    assert_eq!(first.hash, expected.hash, "{case}");
                }
            }
        }
    }

    #[test]
    fn the_cursor_at_a_line_end_sits_after_its_last_glyph() {
        let mut layout = layout();
        let mut area = |text: &str, columns: u32, head: usize| {
            frame(&mut layout, view(text, columns, 64, 0, &[(head, head)])).cursors[0].area
        };
        assert_eq!(
            area("abc", 10, 3),
            Area {
                x: 30.0,
                y: 0.0,
                width: 10.0,
                height: 16.0
            }
        );
        // The end of a wrapped line, on its last visual row.
        assert_eq!(
            area("abcdef", 4, 6),
            Area {
                x: 20.0,
                y: 16.0,
                width: 10.0,
                height: 16.0
            }
        );
        // The wrap point is the start of the later row.
        assert_eq!(
            area("abcdef", 4, 4),
            Area {
                x: 0.0,
                y: 16.0,
                width: 10.0,
                height: 16.0
            }
        );
    }

    #[test]
    fn every_range_of_every_selection_has_a_cursor_and_its_extent() {
        let mut layout = layout();
        let mut two = view("abcdef\nghij", 10, 64, 0, &[(1, 3)]);
        two.selections.push(
            Selection::new(
                vec![SelectionRange::new(9, 9), SelectionRange::new(4, 6)],
                0,
            )
            .unwrap(),
        );
        let frame = frame(&mut layout, two);
        let heads: Vec<(f32, f32)> = frame
            .cursors
            .iter()
            .map(|cursor| (cursor.area.x, cursor.area.y))
            .collect();
        assert_eq!(heads, vec![(30.0, 0.0), (60.0, 0.0), (20.0, 16.0)]);
        assert_eq!(
            frame.selections,
            vec![
                Area {
                    x: 10.0,
                    y: 0.0,
                    width: 20.0,
                    height: 16.0
                },
                Area {
                    x: 40.0,
                    y: 0.0,
                    width: 20.0,
                    height: 16.0
                },
            ]
        );
    }

    #[test]
    fn a_cursor_off_the_rows_shown_is_left_out() {
        let mut layout = layout();
        // At four columns the visual rows are ab, cdef, gh, ij, klmn, op
        // and qr. A view two rows tall scrolled to i shows ij and klmn.
        let text = "ab\ncdefgh\nij\nklmnop\nqr";
        let mut cursors = |heads: &[usize]| {
            let ranges: Vec<(usize, usize)> = heads.iter().map(|&head| (head, head)).collect();
            let shown = frame(&mut layout, view(text, 4, 32, 10, &ranges));
            let bytes: Vec<Range<usize>> = shown.rows.iter().map(|row| row.bytes.clone()).collect();
            assert_eq!(bytes, vec![10..12, 13..17]);
            shown
                .cursors
                .iter()
                .map(|cursor| (cursor.area.x, cursor.area.y))
                .collect::<Vec<_>>()
        };
        // Above the anchor: on the text's first row, and on the visual row
        // just before the anchor's.
        assert_eq!(cursors(&[1]), vec![]);
        assert_eq!(cursors(&[8]), vec![]);
        // Below the last row shown.
        assert_eq!(cursors(&[20]), vec![]);
        // On op, a later visual line of the row whose first line, klmn, is
        // the last row shown.
        assert_eq!(cursors(&[18]), vec![]);
        // Among them, the cursors on j and on m are drawn, and no other.
        assert_eq!(
            cursors(&[1, 8, 11, 15, 18, 20]),
            vec![(10.0, 0.0), (20.0, 16.0)]
        );
    }

    /// The area at `x` and `y`, `width` across and `height` down.
    fn area(x: f32, y: f32, width: f32, height: f32) -> Area {
        Area {
            x,
            y,
            width,
            height,
        }
    }

    #[test]
    fn a_selection_across_wrapped_rows_has_an_area_on_each() {
        let mut layout = layout();
        // At four columns the rows are abcd, efgh and ij. From c to j:
        // the rest of the first row, the whole of the second, which is a
        // continuation, and the first glyph of the third.
        let text = "abcdefgh\nij";
        let across = frame(&mut layout, view(text, 4, 64, 0, &[(2, 10)]));
        assert_eq!(
            across.selections,
            vec![
                area(20.0, 0.0, 20.0, 16.0),
                area(0.0, 16.0, 40.0, 16.0),
                area(0.0, 32.0, 10.0, 16.0),
            ]
        );
        // Inside a continuation row, an area starts at its first glyph's x
        // on that row: f is the second glyph of efgh.
        let inside = frame(&mut layout, view(text, 4, 64, 0, &[(5, 7)]));
        assert_eq!(inside.selections, vec![area(10.0, 16.0, 20.0, 16.0)]);
        // An area is as tall as its row and starts at its top: with the
        // second row 32 tall, the third row's area is 48 down.
        let mut tall = view(text, 4, 64, 0, &[(6, 10)]);
        tall.decorations = vec![Decoration {
            start: 4,
            stop: 5,
            face: "tall".to_owned(),
        }];
        assert_eq!(
            frame(&mut layout, tall).selections,
            vec![area(20.0, 16.0, 20.0, 32.0), area(0.0, 48.0, 10.0, 16.0)]
        );
        // Scrolled, areas are from the first row shown, and a row above
        // the view has none.
        let scrolled = frame(&mut layout, view(text, 4, 64, 4, &[(2, 10)]));
        assert_eq!(
            scrolled.selections,
            vec![area(0.0, 0.0, 40.0, 16.0), area(0.0, 16.0, 10.0, 16.0)]
        );
    }

    #[test]
    fn a_selected_tab_is_as_wide_as_the_spaces_of_it_each_row_draws() {
        let mut layout = layout();
        // Tabs are 8 columns wide. Unwrapped, the tab of "a\tb" is columns
        // 1 to 8.
        let whole = frame(&mut layout, view("a\tb", 12, 64, 0, &[(1, 2)]));
        assert_eq!(whole.selections, vec![area(10.0, 0.0, 70.0, 16.0)]);
        // At four columns the tab of "\tgh" is two rows of spaces; the
        // second would hold no position and is no row, so the rows are
        // abcd, ef, four spaces, gh and ij. From c to i, the tab is
        // selected over the four spaces drawn.
        let wrapped = frame(&mut layout, view("abcdef\n\tgh\nij", 4, 160, 0, &[(2, 12)]));
        let bytes: Vec<Range<usize>> = wrapped.rows.iter().map(|row| row.bytes.clone()).collect();
        assert_eq!(bytes, vec![0..4, 4..6, 7..8, 8..10, 11..13]);
        assert_eq!(
            wrapped.selections,
            vec![
                area(20.0, 0.0, 20.0, 16.0),
                area(0.0, 16.0, 20.0, 16.0),
                area(0.0, 32.0, 40.0, 16.0),
                area(0.0, 48.0, 20.0, 16.0),
                area(0.0, 64.0, 10.0, 16.0),
            ]
        );
        assert_eq!(wrapped.rows[2].runs, vec![(0..4, SELECTED)]);
        assert_eq!(wrapped.rows[3].runs, vec![(0..2, SELECTED)]);
    }

    #[test]
    fn a_cursor_move_keeps_every_row_hash() {
        let mut layout = layout();
        let text = "abcdef\nghij\nklm";
        let before = frame(&mut layout, view(text, 4, 160, 0, &[(1, 1)]));
        let after = frame(&mut layout, view(text, 4, 160, 0, &[(9, 9)]));
        let hashes = |frame: &ViewFrame| frame.rows.iter().map(|row| row.hash).collect::<Vec<_>>();
        assert_eq!(hashes(&before), hashes(&after));
        assert_ne!(before.cursors, after.cursors);
        // A selection is part of its rows.
        let selected = frame(&mut layout, view(text, 4, 160, 0, &[(1, 3)]));
        assert_ne!(hashes(&selected)[0], hashes(&before)[0]);
        assert_eq!(hashes(&selected)[1..], hashes(&before)[1..]);
    }

    /// A view of `text` 10 cells wide and 64 pixels tall, with one
    /// selection of `shape` whose one range has both ends at `at`.
    fn with_equal_ends(text: &str, shape: Shape, at: usize) -> View {
        let mut view = view(text, 10, 64, 0, &[]);
        view.selections =
            vec![Selection::shaped(shape, vec![SelectionRange::new(at, at)], 0).unwrap()];
        view
    }

    #[test]
    fn a_line_wise_selection_with_equal_ends_is_as_wide_as_its_row() {
        let mut layout = layout();
        let text = "abc\ndef";
        let line = frame(&mut layout, with_equal_ends(text, Shape::Line, 1));
        assert_eq!(line.selections, vec![area(0.0, 0.0, 30.0, 16.0)]);
        // Its head is a cursor as well.
        let cursors: Vec<Area> = line.cursors.iter().map(|cursor| cursor.area).collect();
        assert_eq!(cursors, vec![area(10.0, 0.0, 10.0, 16.0)]);
        // Moved to the next row, it is that row's.
        let moved = frame(&mut layout, with_equal_ends(text, Shape::Line, 5));
        assert_eq!(moved.selections, vec![area(0.0, 16.0, 30.0, 16.0)]);
    }

    #[test]
    fn a_cursor_move_keeps_every_row_hash_in_each_shape_that_is_not_line_wise() {
        let mut layout = layout();
        let text = "abc\ndef";
        for shape in [Shape::Exclusive, Shape::Inclusive, Shape::Block] {
            let before = frame(&mut layout, with_equal_ends(text, shape, 1));
            let after = frame(&mut layout, with_equal_ends(text, shape, 5));
            assert_eq!(hashes(&before), hashes(&after), "{shape:?}");
            assert_ne!(before.cursors, after.cursors, "{shape:?}");
            assert_eq!(before.selections, vec![], "{shape:?}");
        }
    }

    #[test]
    fn a_tab_that_crosses_a_wrap_is_styled_and_selected_on_both_rows() {
        let mut layout = layout();
        // Tabs are 8 columns wide, so the tab is columns 9 to 16, and the
        // view is 10 columns wide: the tab's first space ends the first
        // row and its other six start the second, before the x.
        let mut crossing = view("abcdefghi\tx", 10, 64, 0, &[(8, 11)]);
        crossing.decorations = vec![Decoration {
            start: 9,
            stop: 10,
            face: "tab".to_owned(),
        }];
        let frame = frame(&mut layout, crossing);
        let tab = paint(RED, BLUE);
        let glyphs: Vec<usize> = frame.rows.iter().map(|row| row.line.glyphs.len()).collect();
        assert_eq!(glyphs, vec![10, 7]);
        // Each row's runs cover its glyphs and no more, and the tab's
        // spaces take the tab's faces on both rows: its decoration's red,
        // and over it the selection's blue behind.
        assert_eq!(
            frame.rows[0].runs,
            vec![(0..8, PLAIN), (8..9, SELECTED), (9..10, tab)]
        );
        assert_eq!(frame.rows[1].runs, vec![(0..6, tab), (6..7, SELECTED)]);
        assert_eq!(
            frame.selections,
            vec![
                Area {
                    x: 80.0,
                    y: 0.0,
                    width: 20.0,
                    height: 16.0
                },
                Area {
                    x: 0.0,
                    y: 16.0,
                    width: 70.0,
                    height: 16.0
                },
            ]
        );
    }

    #[test]
    fn every_rows_runs_cover_its_glyphs_and_a_selection_of_it_all_is_as_wide() {
        // Tabs that end a row, start one, cross a wrap and fill whole
        // rows, at every width from one column to twelve.
        let texts = [
            "abcdefghi\tx",
            "abc\tdef\nzz",
            "\tgh",
            "a\tb\tc",
            "é\t😀\tz",
            "ab\t",
            "\t\t\n\t",
        ];
        for text in texts {
            for columns in 1..=12 {
                let mut layout = layout();
                // The whole text selected, and each tab in a face.
                let mut all = view(text, columns, 1600, 0, &[(0, text.len())]);
                all.decorations = text
                    .match_indices('\t')
                    .map(|(at, _)| Decoration {
                        start: at,
                        stop: at + 1,
                        face: "tab".to_owned(),
                    })
                    .collect();
                let frame = frame(&mut layout, all);
                let mut areas = Vec::new();
                for row in &frame.rows {
                    let mut covered = 0;
                    let mut before = None;
                    for (bytes, paint) in &row.runs {
                        assert_eq!(bytes.start, covered, "{text:?} at {columns}: {row:?}");
                        assert!(bytes.end > bytes.start, "{text:?} at {columns}: {row:?}");
                        // Neighbours of one paint are one run.
                        assert_ne!(before, Some(paint), "{text:?} at {columns}: {row:?}");
                        covered = bytes.end;
                        before = Some(paint);
                    }
                    assert_eq!(
                        covered,
                        row.line.bytes.len(),
                        "{text:?} at {columns}: {row:?}"
                    );
                    if !row.line.glyphs.is_empty() {
                        areas.push(Area {
                            x: 0.0,
                            y: row.y,
                            width: row.line.width,
                            height: row.height,
                        });
                    }
                }
                assert_eq!(frame.selections, areas, "{text:?} at {columns}");
            }
        }
    }

    /// The hash of each row of `frame`.
    fn hashes(frame: &ViewFrame) -> Vec<u64> {
        frame.rows.iter().map(|row| row.hash).collect()
    }

    #[test]
    fn rows_of_different_glyphs_have_different_hashes() {
        let mut layout = layout();
        // Four rows: "abcd" twice (one wrapped row), "abce" and "abcd".
        let rows = hashes(&frame(
            &mut layout,
            view("abcdabcd\nabce\nabcd", 4, 160, 0, &[]),
        ));
        assert_ne!(rows[0], rows[2]);
        // The same glyphs hash the same wherever the row is: further down,
        // further into the text, or the later part of a wrapped row.
        assert_eq!(rows[0], rows[1]);
        assert_eq!(rows[0], rows[3]);
        // An edit changes the hash of the row it is on, and of no other,
        // though the rows after it are further into the text.
        let edited = hashes(&frame(
            &mut layout,
            view("abcdabcd\nabcxe\nabcd", 4, 160, 0, &[]),
        ));
        assert_ne!(edited[2], rows[2]);
        assert_eq!((edited[0], edited[1]), (rows[0], rows[1]));
        assert_eq!(edited[4], rows[3]);
    }

    #[test]
    fn the_same_glyphs_at_another_height_or_advance_have_another_hash() {
        // The first row of "ab" where the default face is in a family
        // whose cells are `advance` by `height`. The family's font is the
        // first each shaper is asked for after the default, so its id is
        // the same in each layout.
        let row = |advance: f32, height: f32| {
            let mut layout =
                Layout::new(CellShaper::new(10.0, 16.0).with_family("cell", advance, height));
            layout.define(&[def("default", family("cell"))]);
            frame(&mut layout, view("ab", 4, 160, 0, &[]))
                .rows
                .remove(0)
        };
        let (short, tall, wide) = (row(10.0, 16.0), row(10.0, 32.0), row(12.0, 16.0));
        // Another line height: the same glyphs and runs, lower down.
        assert_eq!(short.line.glyphs, tall.line.glyphs);
        assert_eq!(short.runs, tall.runs);
        assert_ne!(short.hash, tall.hash);
        // Another advance: the same height, glyphs further across.
        assert_eq!((short.height, short.baseline), (wide.height, wide.baseline));
        assert_ne!(short.hash, wide.hash);
        assert_eq!(short.hash, row(10.0, 16.0).hash);
        // The fake's baseline follows its height, so each alone is checked
        // on a line made by hand.
        let line = |height: f32, baseline: f32| VisualLine {
            bytes: 0..0,
            glyphs: vec![],
            width: 0.0,
            height,
            baseline,
        };
        let plain = super::hash(&line(16.0, 12.0), &[]);
        assert_ne!(plain, super::hash(&line(20.0, 12.0), &[]));
        assert_ne!(plain, super::hash(&line(16.0, 10.0), &[]));
    }

    #[test]
    fn the_same_glyphs_in_another_font_of_the_same_cell_have_another_hash() {
        // Bold changes no geometry on the fake, and is another font.
        let row = |weight: Weight| {
            let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
            layout.define(&[def(
                "default",
                Face {
                    weight: Some(weight),
                    ..Face::default()
                },
            )]);
            frame(&mut layout, view("ab", 4, 160, 0, &[]))
                .rows
                .remove(0)
        };
        let (normal, bold) = (row(Weight::NORMAL), row(Weight::BOLD));
        assert_eq!(
            (normal.height, normal.line.width),
            (bold.height, bold.line.width)
        );
        assert_eq!(normal.runs, bold.runs);
        assert_ne!(normal.hash, bold.hash);
    }

    /// A layout whose shaper shapes `ab` to one line of two glyphs 10
    /// across, the second drawn `dx` right of its pen position and `dy`
    /// below the baseline.
    fn offset_layout(dx: f32, dy: f32) -> Layout<ScriptedShaper> {
        let glyphs = vec![
            glyph('a', 0, 0.0, 10.0),
            Glyph {
                dx,
                dy,
                ..glyph('b', 1, 10.0, 10.0)
            },
        ];
        Layout::new(ScriptedShaper::new(10.0, 16.0).with("ab", vec![line(0..2, glyphs)]))
    }

    #[test]
    fn two_rows_alike_but_for_a_glyphs_offset_have_different_hashes() {
        let row = |dx: f32, dy: f32| {
            frame(&mut offset_layout(dx, dy), view("ab", 4, 16, 0, &[]))
                .rows
                .remove(0)
        };
        let plain = row(0.0, 0.0);
        assert_eq!(plain.hash, row(0.0, 0.0).hash);
        // Each offset alone: the pen positions and the advances are the
        // same, and the outline is drawn elsewhere.
        for moved in [row(0.0, 3.0), row(1.5, 0.0)] {
            assert_eq!(moved.line.width, plain.line.width);
            assert_eq!(moved.runs, plain.runs);
            assert_ne!(moved.hash, plain.hash);
        }
        assert_ne!(row(0.0, 3.0).hash, row(3.0, 0.0).hash);
    }

    #[test]
    fn a_frame_is_described_with_the_offset_of_a_glyph_that_has_one() {
        let described = |dx: f32, dy: f32| {
            let scene = Scene {
                views: vec![view("ab", 4, 16, 0, &[])],
                ..Scene::default()
            };
            offset_layout(dx, dy).frame(&scene).describe()
        };
        let with = |glyphs: &str| {
            format!(
                "view 1 rect 0 0 40 16 background ffffffff selection ffffffff\n  \
                 row y 0 height 16 baseline 12 bytes 0..2 glyphs {glyphs} \
                 runs 0..2:000000ff/ffffffff\n"
            )
        };
        // A glyph with no offset is written as the fake's are.
        assert_eq!(described(0.0, 0.0), with("97@0 98@10"));
        assert_eq!(described(1.5, -3.0), with("97@0 98@10^1.5,-3"));
        assert_eq!(described(0.0, 2.0), with("97@0 98@10^0,2"));
    }

    #[test]
    fn an_offset_that_is_not_a_position_is_moved_back() {
        let mut layout = layout();
        // 2 is inside é: the anchor is moved back to 1, on row 0.
        let rows = frame(&mut layout, view("aé\nb", 4, 16, 2, &[(9, 9)])).rows;
        assert_eq!(rows[0].bytes, 0..3);
        let cursors = frame(&mut layout, view("aé\nb", 4, 64, 0, &[(9, 9)])).cursors;
        assert_eq!((cursors[0].area.x, cursors[0].area.y), (10.0, 16.0));
        // A decoration that starts inside é starts at é, and one that
        // stops inside it stops before it.
        let decorated = |start: usize, stop: usize| {
            let mut layout = self::layout();
            let mut view = view("aéb", 4, 16, 0, &[]);
            view.decorations = vec![Decoration {
                start,
                stop,
                face: "face".to_owned(),
            }];
            frame(&mut layout, view).rows.remove(0).runs
        };
        let green = paint(GREEN, BASE_BACKGROUND);
        assert_eq!(decorated(2, 4), vec![(0..1, PLAIN), (1..4, green)]);
        assert_eq!(decorated(0, 2), vec![(0..1, green), (1..4, PLAIN)]);
    }

    #[test]
    fn a_decoration_that_stops_before_it_starts_gives_no_run() {
        let mut layout = layout();
        let mut reversed = view("abcdef", 10, 16, 0, &[]);
        reversed.decorations = vec![Decoration {
            start: 4,
            stop: 2,
            face: "face".to_owned(),
        }];
        let row = frame(&mut layout, reversed).rows.remove(0);
        assert_eq!(row.runs, vec![(0..6, PLAIN)]);
    }

    /// `view` with the decorations `decorations`: each its bytes and its
    /// face's name, in the scene's order.
    fn decorated(mut view: View, decorations: &[(Range<usize>, &str)]) -> View {
        view.decorations = decorations
            .iter()
            .map(|(bytes, face)| Decoration {
                start: bytes.start,
                stop: bytes.end,
                face: (*face).to_owned(),
            })
            .collect();
        view
    }

    /// A layout on cells 10 by 16 with the faces `definitions`.
    fn layout_with(definitions: &[FaceDef]) -> Layout<CellShaper> {
        let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
        layout.define(definitions);
        layout
    }

    /// The runs of the first row of `view`.
    fn first_runs(layout: &mut Layout<CellShaper>, view: View) -> Vec<(Range<usize>, Paint)> {
        frame(layout, view).rows.remove(0).runs
    }

    #[test]
    fn a_later_decoration_is_over_an_earlier_one() {
        // Both set a foreground, and the earlier one a background too.
        let mut layout = layout_with(&[
            def(
                "first",
                Face {
                    background: Some(GREY),
                    ..fg(RED)
                },
            ),
            def("second", fg(GREEN)),
        ]);
        let text = "abcdefghij";
        let runs = first_runs(
            &mut layout,
            decorated(
                view(text, 20, 16, 0, &[]),
                &[(2..6, "first"), (4..8, "second")],
            ),
        );
        assert_eq!(
            runs,
            vec![
                (0..2, PLAIN),
                (2..4, paint(RED, GREY)),
                // The overlap: the later one's foreground, and the
                // background only the earlier one sets.
                (4..6, paint(GREEN, GREY)),
                (6..8, paint(GREEN, BASE_BACKGROUND)),
                (8..10, PLAIN),
            ]
        );
        // Listed the other way round, the overlap has the other's
        // foreground, and is one run with the bytes before it.
        let runs = first_runs(
            &mut layout,
            decorated(
                view(text, 20, 16, 0, &[]),
                &[(4..8, "second"), (2..6, "first")],
            ),
        );
        assert_eq!(
            runs,
            vec![
                (0..2, PLAIN),
                (2..6, paint(RED, GREY)),
                (6..8, paint(GREEN, BASE_BACKGROUND)),
                (8..10, PLAIN),
            ]
        );
    }

    #[test]
    fn the_selection_is_over_every_decoration() {
        // The selection and both decorations set a background.
        let mut layout = layout_with(&[
            def("selection", bg(BLUE)),
            def("first", bg(RED)),
            def("second", bg(GREEN)),
        ]);
        // 3..7 is selected; the decorations cover 0..5 and 4..10.
        for order in [
            [(0..5, "first"), (4..10, "second")],
            [(4..10, "second"), (0..5, "first")],
        ] {
            let runs = first_runs(
                &mut layout,
                decorated(view("abcdefghij", 20, 16, 0, &[(3, 7)]), &order),
            );
            let backgrounds: Vec<(Range<usize>, Color)> = runs
                .into_iter()
                .map(|(bytes, paint)| (bytes, paint.background))
                .collect();
            // Selected, the selection's, whichever decoration is under it
            // and in whichever order the scene lists them.
            assert_eq!(backgrounds[1], (3..7, BLUE), "{order:?}");
            assert_eq!(backgrounds[0], (0..3, RED), "{order:?}");
            assert_eq!(backgrounds[2], (7..10, GREEN), "{order:?}");
        }
        // What the selection leaves unset is still the decoration's.
        let mut layout = layout_with(&[def("selection", bg(BLUE)), def("first", fg(RED))]);
        let runs = first_runs(
            &mut layout,
            decorated(view("abcdef", 20, 16, 0, &[(2, 4)]), &[(0..6, "first")]),
        );
        assert_eq!(
            runs,
            vec![
                (0..2, paint(RED, BASE_BACKGROUND)),
                (2..4, paint(RED, BLUE)),
                (4..6, paint(RED, BASE_BACKGROUND)),
            ]
        );
    }

    #[test]
    fn a_run_under_no_span_is_drawn_in_the_default_face() {
        let default = Face {
            underline: Some(Underline {
                style: UnderlineStyle::Dotted,
                color: None,
            }),
            strike_through: Some(true),
            ..Face {
                background: Some(GREY),
                ..fg(GREEN)
            }
        };
        let expected = Paint {
            foreground: GREEN,
            background: GREY,
            underline: Some((UnderlineStyle::Dotted, GREEN)),
            strike_through: true,
        };
        let mut layout = layout_with(&[def("default", default)]);
        let shown = frame(&mut layout, view("abc\n\nde", 20, 48, 0, &[]));
        assert_eq!(shown.rows[0].runs, vec![(0..3, expected)]);
        // An empty row has no run, and the view's background is the
        // default face's.
        assert_eq!(shown.rows[1].runs, vec![]);
        assert_eq!(shown.background, GREY);
        // With no default face defined, the base paint.
        let mut layout = layout_with(&[]);
        let shown = frame(&mut layout, view("abc", 20, 16, 0, &[]));
        assert_eq!(shown.rows[0].runs, vec![(0..3, PLAIN)]);
        assert_eq!(shown.background, BASE_BACKGROUND);
    }

    #[test]
    fn a_face_that_sets_only_a_foreground_keeps_the_default_background_and_font() {
        let faces = |background: Color| {
            [
                def(
                    "default",
                    Face {
                        weight: Some(Weight::BOLD),
                        ..bg(background)
                    },
                ),
                def("keyword", fg(RED)),
            ]
        };
        let row = |layout: &mut Layout<CellShaper>| {
            let view = decorated(view("abcdef", 20, 16, 0, &[]), &[(0..2, "keyword")]);
            frame(layout, view).rows.remove(0)
        };
        let mut layout = layout_with(&faces(GREY));
        let shown = row(&mut layout);
        assert_eq!(
            shown.runs,
            vec![
                (0..2, paint(RED, GREY)),
                (2..6, paint(BASE_FOREGROUND, GREY))
            ]
        );
        // Its glyphs are in the font of the run under no span: the
        // default face's, which is bold.
        let bold = layout.shaper().font(&FontSpec {
            weight: Weight::BOLD,
            ..FontSpec::default()
        });
        let drawn = CellShaper::resolved_of(bold);
        assert!(shown.line.glyphs.iter().all(|glyph| glyph.font == drawn));
        assert_ne!(bold, FontId(0));
        // A change of the default face's background changes both runs'.
        layout.define(&faces(BLUE));
        assert_eq!(
            row(&mut layout).runs,
            vec![
                (0..2, paint(RED, BLUE)),
                (2..6, paint(BASE_FOREGROUND, BLUE))
            ]
        );
    }

    #[test]
    fn a_colour_change_changes_the_hash_of_the_rows_drawn_in_the_face_and_of_no_other() {
        let mut layout = layout_with(&[def("keyword", fg(RED))]);
        // Three rows; the second has a keyword.
        let shown = || decorated(view("ab\ncd\nef", 20, 48, 0, &[]), &[(3..4, "keyword")]);
        let before = hashes(&frame(&mut layout, shown()));
        layout.define(&[def("keyword", fg(GREEN))]);
        let after = hashes(&frame(&mut layout, shown()));
        assert_ne!(after[1], before[1]);
        assert_eq!((after[0], after[2]), (before[0], before[2]));
        // Each other attribute of paint likewise.
        let others = [
            bg(GREY),
            Face {
                underline: Some(Underline {
                    style: UnderlineStyle::Single,
                    color: None,
                }),
                ..fg(GREEN)
            },
            Face {
                strike_through: Some(true),
                ..fg(GREEN)
            },
        ];
        for other in others {
            layout.define(&[def("keyword", other.clone())]);
            let now = hashes(&frame(&mut layout, shown()));
            assert_ne!(now[1], after[1], "{other:?}");
            assert_eq!((now[0], now[2]), (before[0], before[2]), "{other:?}");
        }
    }

    #[test]
    fn two_faces_that_resolve_alike_are_one_run_and_one_hash() {
        let mut layout = layout_with(&[
            def("one", fg(RED)),
            def("other", fg(RED)),
            def("unset", Face::default()),
        ]);
        let shown = |decorations: &[(Range<usize>, &str)]| {
            decorated(view("abcdef", 20, 16, 0, &[]), decorations)
        };
        // Two neighbours in faces that come to one paint: one run.
        let two = frame(&mut layout, shown(&[(0..3, "one"), (3..6, "other")]));
        let one = frame(&mut layout, shown(&[(0..6, "one")]));
        assert_eq!(two.rows[0].runs, vec![(0..6, paint(RED, BASE_BACKGROUND))]);
        assert_eq!(hashes(&two), hashes(&one));
        // A face that sets nothing, and a name nothing defines, are the
        // run under no span.
        let unset = frame(&mut layout, shown(&[(1..3, "unset"), (4..5, "undefined")]));
        let bare = frame(&mut layout, shown(&[]));
        assert_eq!(unset.rows[0].runs, vec![(0..6, PLAIN)]);
        assert_eq!(hashes(&unset), hashes(&bare));
    }

    #[test]
    fn a_cursor_takes_the_face_the_scene_names() {
        let mut layout = layout_with(&[def("default", bg(GREY))]);
        let shown = |face: &str| {
            let mut view = view("abc\ndef", 20, 32, 0, &[(1, 1)]);
            view.cursor.face = face.to_owned();
            view
        };
        // A name nothing defines draws as the default face.
        let undefined = frame(&mut layout, shown("cursor.normal"));
        assert_eq!(undefined.cursors[0].paint, paint(BASE_FOREGROUND, GREY));
        // Defined, the cursor has its paint over the default face's, and
        // no row changed.
        layout.define(&[
            def("default", bg(GREY)),
            def("cursor.normal", bg(RED)),
            def(
                "cursor.insert",
                Face {
                    background: Some(GREEN),
                    ..fg(BLUE)
                },
            ),
        ]);
        let normal = frame(&mut layout, shown("cursor.normal"));
        assert_eq!(normal.cursors[0].paint, paint(BASE_FOREGROUND, RED));
        assert_eq!(hashes(&normal), hashes(&undefined));
        assert_eq!(normal.rows, undefined.rows);
        // Another name, another paint, and still no row changed.
        let insert = frame(&mut layout, shown("cursor.insert"));
        assert_eq!(insert.cursors[0].paint, paint(BLUE, GREEN));
        assert_eq!(insert.rows, undefined.rows);
    }

    #[test]
    fn a_change_of_the_cursors_face_changes_no_row_hash() {
        let mut layout = layout_with(&[def("cursor", bg(RED))]);
        let shown = || view("abc\ndef", 20, 32, 0, &[(1, 1)]);
        let before = frame(&mut layout, shown());
        // Its paint, and then its font, which no glyph is shaped in.
        layout.define(&[def("cursor", bg(GREEN))]);
        let repainted = frame(&mut layout, shown());
        assert_eq!(hashes(&repainted), hashes(&before));
        assert_ne!(repainted.cursors, before.cursors);
        layout.define(&[def(
            "cursor",
            Face {
                size: Some(Length::pixels(32)),
                ..bg(GREEN)
            },
        )]);
        let resized = frame(&mut layout, shown());
        assert_eq!(hashes(&resized), hashes(&before));
        assert_eq!(resized.rows, before.rows);
    }

    #[test]
    fn a_view_carries_the_default_faces_background_and_the_selections() {
        let mut layout = layout_with(&[def("default", bg(GREY)), def("selection", bg(BLUE))]);
        let shown = frame(&mut layout, view("abc", 20, 16, 0, &[(0, 2)]));
        assert_eq!((shown.background, shown.selection), (GREY, BLUE));
        // A selection face that sets no background has the default
        // face's, and a view with no text has both too.
        layout.define(&[def("default", bg(GREY)), def("selection", fg(RED))]);
        let shown = frame(&mut layout, view("abc", 20, 16, 0, &[(0, 2)]));
        assert_eq!((shown.background, shown.selection), (GREY, GREY));
        let mut empty = view("abc", 20, 16, 0, &[]);
        empty.text = None;
        let shown = frame(&mut layout, empty);
        assert_eq!((shown.background, shown.selection), (GREY, GREY));
    }

    #[test]
    fn a_frame_is_described_with_its_paints_and_the_fonts_that_are_not_font_0() {
        let mut layout = layout_with(&[
            def("default", bg(GREY)),
            def("selection", bg(BLUE)),
            def(
                "keyword",
                Face {
                    weight: Some(Weight::BOLD),
                    underline: Some(Underline {
                        style: UnderlineStyle::Curly,
                        color: Some(GREEN),
                    }),
                    strike_through: Some(true),
                    ..fg(RED)
                },
            ),
            def("cursor", bg(RED)),
        ]);
        let scene = Scene {
            views: vec![decorated(
                view("ab", 4, 16, 0, &[(1, 1)]),
                &[(0..1, "keyword")],
            )],
            ..Scene::default()
        };
        assert_eq!(
            layout.frame(&scene).describe(),
            "view 1 rect 0 0 40 16 background 808080ff selection 0000ccff\n  \
             row y 0 height 16 baseline 12 bytes 0..2 glyphs 97@0#1 98@10 \
             runs 0..1:cc0000ff/808080ff+curly:00cc00ff+strike 1..2:000000ff/808080ff\n  \
             cursor block paint 000000ff/cc0000ff at 10 0 10 16\n"
        );
    }

    /// `view` with the status fields `fields`: each its text and its
    /// face's name.
    fn with_status(mut view: View, fields: &[(&str, &str)]) -> View {
        view.status = fields
            .iter()
            .map(|(text, face)| StatusField {
                text: (*text).to_owned(),
                face: (*face).to_owned(),
                ..StatusField::default()
            })
            .collect();
        view
    }

    /// The faces of the status tests: a default face on grey, a mode line
    /// in green on blue, the face `name` in red, and the face `big` at
    /// twice the base size.
    fn status_faces() -> Vec<FaceDef> {
        vec![
            def("default", bg(GREY)),
            def(
                "mode-line",
                Face {
                    background: Some(BLUE),
                    ..fg(GREEN)
                },
            ),
            def("name", fg(RED)),
            def("big", sized(32)),
        ]
    }

    /// The id and the x of each glyph of `line`.
    fn glyphs_of(line: &VisualLine) -> Vec<(u32, f32)> {
        line.glyphs
            .iter()
            .map(|glyph| (glyph.id, glyph.x))
            .collect()
    }

    #[test]
    fn a_views_status_fields_are_one_row_at_its_bottom_each_in_its_face() {
        let mut layout = layout_with(&status_faces());
        // The face `position` is not defined: its field is drawn in the
        // mode line's face.
        let fields = [("a.rs", "name"), (" 1:2", "position")];
        let shown = frame(
            &mut layout,
            with_status(view("ab\ncd", 20, 80, 0, &[]), &fields),
        );
        let status = shown.status.expect("a status row");
        // One row of the view's last 16 pixels.
        assert_eq!(
            (status.y, status.height, status.baseline),
            (64.0, 16.0, 12.0)
        );
        // The fields' texts one after another, with no separator.
        let expected: Vec<(u32, f32)> = "a.rs 1:2"
            .chars()
            .enumerate()
            .map(|(index, character)| (u32::from(character), index as f32 * 10.0))
            .collect();
        assert_eq!(glyphs_of(&status.line), expected);
        assert_eq!(status.line.bytes, 0..8);
        // Each field in its face over the mode line's over the default's.
        assert_eq!(
            status.runs,
            vec![(0..4, paint(RED, BLUE)), (4..8, paint(GREEN, BLUE))]
        );
        assert_eq!(status.background, BLUE);
        // The text rows are in the default face, not the mode line's.
        assert_eq!(
            shown.rows[0].runs,
            vec![(0..2, paint(BASE_FOREGROUND, GREY))]
        );
        assert_eq!(shown.background, GREY);
    }

    #[test]
    fn a_status_field_is_shaped_in_the_font_of_its_face() {
        let mut layout = layout_with(&status_faces());
        let fields = [("ab", "name"), ("X", "big"), ("c", "name")];
        let shown = frame(
            &mut layout,
            with_status(view("ab", 20, 80, 0, &[]), &fields),
        );
        let status = shown.status.expect("a status row");
        // X is twice the size: 20 across. The row is still the mode line's
        // height, at the view's bottom: X's glyph, taller than the row, is
        // shaped on the line's baseline and runs past the row's foot, and
        // what runs past is outside the view and is not drawn.
        assert_eq!(
            glyphs_of(&status.line),
            vec![
                (u32::from('a'), 0.0),
                (u32::from('b'), 10.0),
                (u32::from('X'), 20.0),
                (u32::from('c'), 40.0)
            ]
        );
        assert_eq!((status.y, status.height), (64.0, 16.0));
        // The mode line's own font is every field's it sets none for.
        layout.define(&[def("mode-line", sized(32))]);
        let shown = frame(
            &mut layout,
            with_status(view("ab", 20, 80, 0, &[]), &fields),
        );
        let status = shown.status.expect("a status row");
        let xs: Vec<f32> = status.line.glyphs.iter().map(|glyph| glyph.x).collect();
        assert_eq!(xs, vec![0.0, 20.0, 40.0, 60.0]);
        // And not the text's.
        assert_eq!(shown.rows[0].height, 16.0);
    }

    #[test]
    fn the_text_rows_are_those_that_fit_above_the_status_row() {
        let mut layout = layout_with(&status_faces());
        let text = "a\nb\nc\nd\ne\nf\ng";
        let rows = |layout: &mut Layout<CellShaper>, height: u32, fields: &[(&str, &str)]| {
            let shown = frame(layout, with_status(view(text, 20, height, 0, &[]), fields));
            let status = shown.status.map(|status| (status.y, status.height));
            (shown.rows.len(), status)
        };
        // 80 pixels: five rows with no status row, and four above one.
        assert_eq!(rows(&mut layout, 80, &[]), (5, None));
        assert_eq!(
            rows(&mut layout, 80, &[("x", "name")]),
            (4, Some((64.0, 16.0)))
        );
        // Only rows that fit whole: 79 pixels leave 63 above the status
        // row, which hold three.
        assert_eq!(
            rows(&mut layout, 79, &[("x", "name")]),
            (3, Some((63.0, 16.0)))
        );
        // A field in a taller face leaves the row as it was: the row is
        // the mode line's height.
        assert_eq!(
            rows(&mut layout, 80, &[("x", "big")]),
            (4, Some((64.0, 16.0)))
        );
        // A taller mode line leaves less: 48 pixels hold three.
        let mut faces = status_faces();
        faces.push(def("mode-line", sized(32)));
        layout.define(&faces);
        assert_eq!(
            rows(&mut layout, 80, &[("x", "name")]),
            (3, Some((48.0, 32.0)))
        );
        layout.define(&status_faces());
        // A cursor on a row the status row took the place of is not
        // drawn: the fifth row starts at byte 8.
        let hidden = frame(
            &mut layout,
            with_status(view(text, 20, 80, 0, &[(8, 8)]), &[("x", "name")]),
        );
        assert_eq!(hidden.cursors, vec![]);
        let shown = frame(&mut layout, view(text, 20, 80, 0, &[(8, 8)]));
        assert_eq!(shown.cursors.len(), 1);
    }

    #[test]
    fn a_view_with_no_status_field_gives_its_whole_height_to_text() {
        let mut layout = layout_with(&status_faces());
        let shown = frame(&mut layout, view("a\nb\nc\nd\ne\nf", 20, 80, 0, &[]));
        assert_eq!(shown.status, None);
        assert_eq!(shown.rows.len(), 5);
        assert_eq!(tops(&shown.rows), vec![0.0, 16.0, 32.0, 48.0, 64.0]);
    }

    #[test]
    fn a_view_whose_status_fields_are_empty_has_an_empty_status_row() {
        let mut layout = layout_with(&status_faces());
        let shown = frame(
            &mut layout,
            with_status(view("a\nb\nc\nd\ne\nf", 20, 80, 0, &[]), &[("", "name")]),
        );
        let status = shown.status.expect("a status row");
        assert_eq!(glyphs_of(&status.line), vec![]);
        assert_eq!(status.runs, vec![]);
        assert_eq!(
            (status.y, status.height, status.background),
            (64.0, 16.0, BLUE)
        );
        assert_eq!(shown.rows.len(), 4);
        // An empty row is as tall as the mode line's font.
        layout.define(&[def("mode-line", sized(32))]);
        let shown = frame(
            &mut layout,
            with_status(view("a\nb\nc", 20, 80, 0, &[]), &[("", "name"), ("", "x")]),
        );
        assert_eq!(
            shown.status.map(|status| (status.y, status.height)),
            Some((48.0, 32.0))
        );
    }

    #[test]
    fn a_tab_a_return_or_a_line_feed_in_a_status_field_is_shaped_as_a_space() {
        let mut layout = layout_with(&status_faces());
        let shown = frame(
            &mut layout,
            with_status(
                view("ab", 20, 80, 0, &[]),
                &[("a\tb\r\nc", "name"), ("\n", "x")],
            ),
        );
        let status = shown.status.expect("a status row");
        let ids: Vec<u32> = status.line.glyphs.iter().map(|glyph| glyph.id).collect();
        let space = u32::from(' ');
        assert_eq!(
            ids,
            vec![
                u32::from('a'),
                space,
                u32::from('b'),
                space,
                space,
                u32::from('c'),
                space
            ]
        );
        // Still one row of one line.
        assert_eq!(status.line.bytes, 0..7);
        assert_eq!(status.height, 16.0);
    }

    #[test]
    fn a_status_row_taller_than_its_view_is_at_its_top_and_leaves_no_text_row() {
        let mut layout = layout_with(&status_faces());
        let shown = frame(
            &mut layout,
            with_status(view("ab\ncd", 20, 10, 0, &[(0, 0)]), &[("x", "name")]),
        );
        assert_eq!(
            shown.status.map(|status| (status.y, status.height)),
            Some((0.0, 16.0))
        );
        assert_eq!(shown.rows, vec![]);
        assert_eq!(shown.cursors, vec![]);
    }

    #[test]
    fn a_view_with_no_text_still_has_its_status_row() {
        let mut layout = layout_with(&status_faces());
        let mut empty = with_status(view("ab", 20, 80, 0, &[]), &[("x", "name")]);
        empty.text = None;
        let shown = frame(&mut layout, empty);
        assert_eq!(shown.rows, vec![]);
        let status = shown.status.expect("a status row");
        assert_eq!(status.runs, vec![(0..1, paint(RED, BLUE))]);
        assert_eq!(status.y, 64.0);
    }

    #[test]
    fn a_change_of_a_status_field_changes_the_status_rows_hash_and_no_text_rows() {
        let mut layout = layout_with(&status_faces());
        let shown = |layout: &mut Layout<CellShaper>, fields: &[(&str, &str)]| {
            let shown = frame(layout, with_status(view("ab\ncd", 20, 80, 0, &[]), fields));
            let status = shown.status.as_ref().map(|status| status.hash);
            (hashes(&shown), status.expect("a status row"))
        };
        let (rows, status) = shown(&mut layout, &[("a.rs", "name"), (" 1:2", "position")]);
        // The same fields: the same hash.
        assert_eq!(
            shown(&mut layout, &[("a.rs", "name"), (" 1:2", "position")]),
            (rows.clone(), status)
        );
        // Another text, another face of a field, and the same glyphs
        // split into fields another way under faces that differ.
        let others: [&[(&str, &str)]; 3] = [
            &[("a.rs", "name"), (" 1:3", "position")],
            &[("a.rs", "position"), (" 1:2", "position")],
            &[("a.r", "name"), ("s 1:2", "position")],
        ];
        for fields in others {
            let (now, changed) = shown(&mut layout, fields);
            assert_eq!(now, rows, "{fields:?}");
            assert_ne!(changed, status, "{fields:?}");
        }
        // A change of the mode line's background alone.
        let mut faces = status_faces();
        faces[1] = def(
            "mode-line",
            Face {
                background: Some(RED),
                ..fg(GREEN)
            },
        );
        layout.define(&faces);
        let (now, changed) = shown(&mut layout, &[("", "name")]);
        layout.define(&status_faces());
        let (_, before) = shown(&mut layout, &[("", "name")]);
        assert_eq!(now, rows);
        assert_ne!(changed, before);
    }

    #[test]
    fn a_frame_is_described_with_its_status_row() {
        let mut layout = layout_with(&status_faces());
        let scene = Scene {
            views: vec![with_status(
                view("ab", 4, 40, 0, &[(1, 1)]),
                &[("x", "name"), ("y", "big")],
            )],
            ..Scene::default()
        };
        assert_eq!(
            layout.frame(&scene).describe(),
            "view 1 rect 0 0 40 40 background 808080ff selection 808080ff\n  \
             row y 0 height 16 baseline 12 bytes 0..2 glyphs 97@0 98@10 \
             runs 0..2:000000ff/808080ff\n  \
             status y 24 height 16 baseline 24 background 0000ccff glyphs 120@0 121@10#1 \
             runs 0..1:cc0000ff/0000ccff 1..2:00cc00ff/0000ccff \
             boxes 0+10:0000ccff 10+20:0000ccff\n  \
             cursor block paint 000000ff/808080ff at 10 0 10 16\n"
        );
    }

    #[test]
    fn a_frame_is_described_with_its_block_rows() {
        let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
        let mut shown = view("ab\ncd", 4, 48, 0, &[]);
        shown.blocks = vec![Block {
            before: 3,
            text: "h".to_owned(),
            decorations: vec![],
        }];
        let scene = Scene {
            views: vec![shown],
            ..Scene::default()
        };
        assert_eq!(
            layout.frame(&scene).describe(),
            "view 1 rect 0 0 40 48 background ffffffff selection ffffffff\n  \
             row y 0 height 16 baseline 12 bytes 0..2 glyphs 97@0 98@10 \
             runs 0..2:000000ff/ffffffff\n  \
             block 0 row y 16 height 16 baseline 12 bytes 0..1 glyphs 104@0 \
             runs 0..1:000000ff/ffffffff\n  \
             row y 32 height 16 baseline 12 bytes 3..5 glyphs 99@0 100@10 \
             runs 0..2:000000ff/ffffffff\n"
        );
    }

    /// A status field: `text` in the face `face`, on `side`, padded
    /// `padding` points each side.
    fn field(text: &str, face: &str, side: Side, padding: u32) -> StatusField {
        StatusField {
            text: text.to_owned(),
            face: face.to_owned(),
            side,
            padding,
        }
    }

    /// `view` with the status fields `fields`.
    fn with_fields(mut view: View, fields: Vec<StatusField>) -> View {
        view.status = fields;
        view
    }

    /// Each box of `status`: its x, its width and its background.
    fn boxes_of(status: &StatusRow) -> Vec<(f32, f32, Color)> {
        status
            .boxes
            .iter()
            .map(|status_box| (status_box.x, status_box.width, status_box.background))
            .collect()
    }

    /// The x of each glyph of `line`, and where the last one ends.
    fn xs_and_end(line: &VisualLine) -> (Vec<f32>, f32) {
        let xs = line.glyphs.iter().map(|glyph| glyph.x).collect();
        let end = line
            .glyphs
            .last()
            .map_or(0.0, |glyph| glyph.x + glyph.advance);
        (xs, end)
    }

    #[test]
    fn left_fields_start_at_the_status_rows_start() {
        let mut layout = layout_with(&status_faces());
        let fields = vec![
            field("ab", "name", Side::Left, 2),
            field("cd", "x", Side::Left, 2),
        ];
        let shown = frame(&mut layout, with_fields(view("ab", 20, 80, 0, &[]), fields));
        let status = shown.status.expect("a status row");
        // The first box at the row's start, its first glyph the padding
        // in; the second box from the first's end.
        assert_eq!(
            boxes_of(&status),
            vec![(0.0, 24.0, BLUE), (24.0, 24.0, BLUE)]
        );
        assert_eq!(
            glyphs_of(&status.line),
            vec![
                (u32::from('a'), 2.0),
                (u32::from('b'), 12.0),
                (u32::from('c'), 26.0),
                (u32::from('d'), 36.0)
            ]
        );
        // The fields' bytes, one after another, each in its face.
        assert_eq!(status.line.bytes, 0..4);
        assert_eq!(
            status.runs,
            vec![(0..2, paint(RED, BLUE)), (2..4, paint(GREEN, BLUE))]
        );
    }

    #[test]
    fn right_fields_end_at_the_status_rows_end() {
        let mut layout = layout_with(&status_faces());
        let fields = vec![
            field("a.rs", "name", Side::Left, 0),
            field("1:2", "x", Side::Right, 2),
            field("All", "name", Side::Right, 2),
        ];
        let shown = frame(&mut layout, with_fields(view("ab", 20, 80, 0, &[]), fields));
        let status = shown.status.expect("a status row");
        // The view is 200 across: the last box ends there, and the right
        // fields keep their order.
        assert_eq!(
            boxes_of(&status),
            vec![(0.0, 40.0, BLUE), (132.0, 34.0, BLUE), (166.0, 34.0, BLUE)]
        );
        let (xs, end) = xs_and_end(&status.line);
        assert_eq!(
            xs,
            vec![
                0.0, 10.0, 20.0, 30.0, 134.0, 144.0, 154.0, 168.0, 178.0, 188.0
            ]
        );
        // The last glyph ends the padding short of the row's end.
        assert_eq!(end, 198.0);
        let ids: String = status
            .line
            .glyphs
            .iter()
            .filter_map(|glyph| char::from_u32(glyph.id))
            .collect();
        assert_eq!(ids, "a.rs1:2All");
        // Each glyph's cluster is its byte of the row's text.
        let clusters: Vec<usize> = status
            .line
            .glyphs
            .iter()
            .map(|glyph| glyph.cluster)
            .collect();
        assert_eq!(clusters, (0..10).collect::<Vec<_>>());
    }

    #[test]
    fn a_fields_padding_is_drawn_in_its_faces_background() {
        let mut faces = status_faces();
        faces.push(def("lit", bg(RED)));
        let mut layout = layout_with(&faces);
        let fields = vec![
            field("ab", "lit", Side::Left, 3),
            field("c", "name", Side::Left, 1),
            field("d", "x", Side::Right, 0),
        ];
        let shown = frame(
            &mut layout,
            with_fields(view("ab", 20, 80, 0, &[]), fields.clone()),
        );
        let status = shown.status.expect("a status row");
        // Each box is twice its padding and its text across: in its face's
        // background, in the mode line's where its face sets none.
        assert_eq!(
            boxes_of(&status),
            vec![(0.0, 26.0, RED), (26.0, 12.0, BLUE), (190.0, 10.0, BLUE)]
        );
        // With no mode line background either: the default face's.
        let mut layout = layout_with(&[def("default", bg(GREY)), def("lit", bg(RED))]);
        let shown = frame(&mut layout, with_fields(view("ab", 20, 80, 0, &[]), fields));
        let status = shown.status.expect("a status row");
        assert_eq!(
            boxes_of(&status),
            vec![(0.0, 26.0, RED), (26.0, 12.0, GREY), (190.0, 10.0, GREY)]
        );
        assert_eq!(status.background, GREY);
    }

    #[test]
    fn when_both_sides_do_not_fit_the_right_side_is_whole_and_the_left_ends_where_it_begins() {
        let mut layout = layout_with(&status_faces());
        let right = || vec![field("xyz", "x", Side::Right, 2)];
        // The right side alone, in a view 100 across: 34 wide, from 66.
        let alone = frame(
            &mut layout,
            with_fields(view("ab", 10, 80, 0, &[]), right()),
        );
        let alone = alone.status.expect("a status row");
        assert_eq!(boxes_of(&alone), vec![(66.0, 34.0, BLUE)]);
        // Three left fields that would reach 112: the first fits, the
        // second is cut at 66 and the third, wholly past it, is not drawn.
        let mut fields = vec![
            field("abcdef", "name", Side::Left, 2),
            field("gh", "name", Side::Left, 2),
            field("ij", "x", Side::Left, 2),
        ];
        fields.extend(right());
        let shown = frame(&mut layout, with_fields(view("ab", 10, 80, 0, &[]), fields));
        let status = shown.status.expect("a status row");
        assert_eq!(
            boxes_of(&status),
            vec![(0.0, 64.0, BLUE), (64.0, 2.0, BLUE), (66.0, 34.0, BLUE)]
        );
        let (xs, end) = xs_and_end(&status.line);
        assert_eq!(
            xs,
            vec![2.0, 12.0, 22.0, 32.0, 42.0, 52.0, 68.0, 78.0, 88.0]
        );
        assert_eq!(end, 98.0);
        // No left glyph passes the right side's start, and the right side
        // is as it was alone.
        let right_glyphs = |line: &VisualLine| -> Vec<(u32, f32, f32)> {
            line.glyphs
                .iter()
                .filter(|glyph| glyph.x >= 66.0)
                .map(|glyph| (glyph.id, glyph.x, glyph.advance))
                .collect()
        };
        assert_eq!(right_glyphs(&status.line), right_glyphs(&alone.line));
        assert!(
            status
                .line
                .glyphs
                .iter()
                .filter(|glyph| glyph.x < 66.0)
                .all(|glyph| glyph.x + glyph.advance <= 66.0)
        );
        // A right side wider than the row starts at its start, and the
        // left side has nothing left: what runs past the row's end is
        // outside the view, which draws nothing outside its rectangle.
        let mut fields = vec![field("ab", "name", Side::Left, 0)];
        fields.extend(right());
        let shown = frame(&mut layout, with_fields(view("ab", 2, 80, 0, &[]), fields));
        let status = shown.status.expect("a status row");
        assert_eq!(boxes_of(&status), vec![(0.0, 34.0, BLUE)]);
        assert_eq!(xs_and_end(&status.line), (vec![2.0, 12.0, 22.0], 32.0));
    }

    #[test]
    fn an_unselected_views_status_face_is_under_its_fields_and_its_rows_background() {
        const DIM: Color = Color::rgb(0x11, 0x22, 0x33);
        let mut faces = status_faces();
        // A status face that would make the row taller, were it read for
        // the height.
        faces.push(def(
            "dim",
            Face {
                foreground: Some(GREY),
                background: Some(DIM),
                line_height: Some(LineHeight::Pixels(Length::pixels(40))),
                vertical_padding: Some(Length::pixels(9)),
                ..Face::default()
            },
        ));
        let mut layout = layout_with(&faces);
        let fields = vec![
            field("a", "name", Side::Left, 1),
            field("b", "unset", Side::Right, 1),
        ];
        let mut dimmed = with_fields(view("ab", 20, 80, 0, &[]), fields);
        dimmed.status_face = Some("dim".to_owned());
        let shown = frame(&mut layout, dimmed);
        let status = shown.status.expect("a status row");
        assert_eq!(status.background, DIM);
        // A field's face is over it, and what the field sets nothing of is
        // the status face's, over the mode line's.
        assert_eq!(
            status.runs,
            vec![(0..1, paint(RED, DIM)), (1..2, paint(GREY, DIM))]
        );
        assert_eq!(
            boxes_of(&status),
            vec![(0.0, 12.0, DIM), (188.0, 12.0, DIM)]
        );
        // The row keeps the mode line's height, and its line is not moved
        // down by the status face's padding. The status face's line height
        // is under every field's face, so the fields are shaped in it, as
        // in a taller field's face: their line's baseline is 30 of its 40,
        // and what runs past the row's foot is not drawn.
        assert_eq!(
            (status.y, status.height, status.baseline),
            (64.0, 16.0, 30.0)
        );
        assert_eq!(layout.heights().status, 16);
    }

    #[test]
    fn a_change_of_one_field_reshapes_that_field_alone() {
        let mut layout = layout_with(&status_faces());
        let shaped = |layout: &mut Layout<CellShaper>, position: &str| {
            let before = layout.shaper().bytes_shaped();
            let fields = vec![
                field("a.rs", "name", Side::Left, 4),
                field(position, "x", Side::Right, 4),
            ];
            frame(layout, with_fields(view("ab", 20, 80, 0, &[]), fields));
            layout.shaper().bytes_shaped() - before
        };
        // The text's row and both fields.
        assert_eq!(shaped(&mut layout, "1:2"), 2 + 4 + 3);
        assert_eq!(shaped(&mut layout, "1:2"), 0);
        // Another position: that field's bytes alone.
        assert_eq!(shaped(&mut layout, "10:2"), 4);
    }

    #[test]
    fn a_cursor_is_as_wide_as_the_glyph_it_is_on() {
        // The face `wide` is in a font whose glyphs are 20 across.
        let mut layout = Layout::new(CellShaper::new(10.0, 16.0).with_family("wide", 20.0, 16.0));
        layout.define(&[def("wide", family("wide"))]);
        let cursor = |layout: &mut Layout<CellShaper>, head: usize| {
            let mut view = view("abc", 10, 16, 0, &[(head, head)]);
            view.decorations = vec![Decoration {
                start: 1,
                stop: 2,
                face: "wide".to_owned(),
            }];
            frame(layout, view).cursors[0].area
        };
        assert_eq!(cursor(&mut layout, 0), area(0.0, 0.0, 10.0, 16.0));
        assert_eq!(cursor(&mut layout, 1), area(10.0, 0.0, 20.0, 16.0));
        assert_eq!(cursor(&mut layout, 2), area(30.0, 0.0, 10.0, 16.0));
        // Past the last glyph, the default advance.
        assert_eq!(cursor(&mut layout, 3), area(40.0, 0.0, 10.0, 16.0));
        // Which is the default face's font's: with the default face in the
        // wide family, every glyph and the cell past the last are 20.
        layout.define(&[def("default", family("wide"))]);
        assert_eq!(cursor(&mut layout, 3), area(60.0, 0.0, 20.0, 16.0));
    }

    /// A layout whose shaper shapes `afib` with `fi` as one glyph 30
    /// across, and `abcd` as `ab` left to right and then `cd` right to
    /// left: a, b, d, c from the left.
    fn real_layout() -> Layout<ScriptedShaper> {
        let ligature = vec![
            glyph('a', 0, 0.0, 10.0),
            glyph('f', 1, 10.0, 30.0),
            glyph('b', 3, 40.0, 10.0),
        ];
        let two_directions = vec![
            glyph('a', 0, 0.0, 10.0),
            glyph('b', 1, 10.0, 10.0),
            glyph('d', 3, 20.0, 10.0),
            glyph('c', 2, 30.0, 10.0),
        ];
        let shaper = ScriptedShaper::new(10.0, 16.0)
            .with("afib", vec![line(0..4, ligature)])
            .with("abcd", vec![line(0..4, two_directions)]);
        let mut layout = Layout::new(shaper);
        layout.define(&[def("selection", bg(BLUE))]);
        layout
    }

    #[test]
    fn a_cursor_on_a_character_of_a_glyph_of_two_is_half_the_glyph_wide() {
        let mut layout = real_layout();
        let mut cursor = |head: usize| {
            frame(&mut layout, view("afib", 10, 16, 0, &[(head, head)])).cursors[0].area
        };
        assert_eq!(cursor(0), area(0.0, 0.0, 10.0, 16.0));
        // `f` is the left half of the glyph and `i` the right half, from
        // its middle.
        assert_eq!(cursor(1), area(10.0, 0.0, 15.0, 16.0));
        assert_eq!(cursor(2), area(25.0, 0.0, 15.0, 16.0));
        assert_eq!(cursor(3), area(40.0, 0.0, 10.0, 16.0));
        assert_eq!(cursor(4), area(50.0, 0.0, 10.0, 16.0));
    }

    #[test]
    fn a_cursor_in_reordered_text_is_on_its_own_glyph() {
        let mut layout = real_layout();
        let mut cursor = |head: usize| {
            frame(&mut layout, view("abcd", 10, 16, 0, &[(head, head)])).cursors[0].area
        };
        // `c` is the rightmost glyph and `d` the one before it.
        assert_eq!(cursor(2), area(30.0, 0.0, 10.0, 16.0));
        assert_eq!(cursor(3), area(20.0, 0.0, 10.0, 16.0));
        // The line's end is at its right edge.
        assert_eq!(cursor(4), area(40.0, 0.0, 10.0, 16.0));
    }

    #[test]
    fn a_cursor_at_a_lines_end_is_a_base_advance_wide_whatever_the_last_glyph() {
        // On the fake, a row whose last character is in a font whose
        // glyphs are 20 across. The cursor on that character is as wide as
        // it; the cursor past it is on no character, so it is one advance
        // of the default face's font, at the line's width.
        let mut layout = Layout::new(CellShaper::new(10.0, 16.0).with_family("wide", 20.0, 16.0));
        layout.define(&[def("wide", family("wide"))]);
        let mut cursor = |head: usize| {
            let mut view = view("abc", 10, 16, 0, &[(head, head)]);
            view.decorations = vec![Decoration {
                start: 2,
                stop: 3,
                face: "wide".to_owned(),
            }];
            frame(&mut layout, view).cursors[0].area
        };
        assert_eq!(cursor(2), area(20.0, 0.0, 20.0, 16.0));
        assert_eq!(cursor(3), area(40.0, 0.0, 10.0, 16.0));
    }

    #[test]
    fn a_cursor_at_the_end_of_a_real_shapers_line_is_a_base_advance_wide() {
        // Lines as a real shaper gives them. `abfi` ends in one glyph of
        // two characters, 30 across: its last character is half of that,
        // and the end is neither. `abi` ends in a glyph narrower than the
        // base advance. `abc` drawn right to left ends, in the text's
        // order, in its leftmost glyph, and its end is still at its right
        // edge.
        let ends_in_a_ligature = vec![
            glyph('a', 0, 0.0, 10.0),
            glyph('b', 1, 10.0, 10.0),
            glyph('f', 2, 20.0, 30.0),
        ];
        let ends_narrow = vec![
            glyph('a', 0, 0.0, 10.0),
            glyph('b', 1, 10.0, 10.0),
            glyph('i', 2, 20.0, 4.0),
        ];
        let right_to_left = vec![
            glyph('c', 2, 0.0, 14.0),
            glyph('b', 1, 14.0, 10.0),
            glyph('a', 0, 24.0, 10.0),
        ];
        let shaper = ScriptedShaper::new(10.0, 16.0)
            .with("abfi", vec![line(0..4, ends_in_a_ligature)])
            .with("abi", vec![line(0..3, ends_narrow)])
            .with("abc", vec![line(0..3, right_to_left)]);
        let mut layout = Layout::new(shaper);
        let mut cursor = |text: &str, head: usize| {
            frame(&mut layout, view(text, 10, 16, 0, &[(head, head)])).cursors[0].area
        };
        assert_eq!(cursor("abfi", 3), area(35.0, 0.0, 15.0, 16.0));
        assert_eq!(cursor("abfi", 4), area(50.0, 0.0, 10.0, 16.0));
        assert_eq!(cursor("abi", 2), area(20.0, 0.0, 4.0, 16.0));
        assert_eq!(cursor("abi", 3), area(24.0, 0.0, 10.0, 16.0));
        assert_eq!(cursor("abc", 2), area(0.0, 0.0, 14.0, 16.0));
        assert_eq!(cursor("abc", 3), area(34.0, 0.0, 10.0, 16.0));
    }

    #[test]
    fn a_selection_across_a_direction_change_is_an_area_for_each_run_of_glyphs_it_covers() {
        let mut layout = real_layout();
        let mut selected = |anchor: usize, head: usize| {
            frame(&mut layout, view("abcd", 10, 16, 0, &[(anchor, head)])).selections
        };
        // `b` and `c`: `b` is the second glyph and `c` the fourth, with
        // `d`, which is not selected, between them.
        assert_eq!(
            selected(1, 3),
            vec![area(10.0, 0.0, 10.0, 16.0), area(30.0, 0.0, 10.0, 16.0)]
        );
        // Inside one direction, one area: `a` and `b`, and `c` and `d`,
        // whose glyphs are next to each other in the other order.
        assert_eq!(selected(0, 2), vec![area(0.0, 0.0, 20.0, 16.0)]);
        assert_eq!(selected(2, 4), vec![area(20.0, 0.0, 20.0, 16.0)]);
        // `b`, `c` and `d` are next to each other on the line, though not
        // in the text's order: one area.
        assert_eq!(selected(1, 4), vec![area(10.0, 0.0, 30.0, 16.0)]);
        // All of it is one area as wide as the line.
        assert_eq!(selected(0, 4), vec![area(0.0, 0.0, 40.0, 16.0)]);
        // One character of a glyph of two is half the glyph.
        let half = frame(&mut layout, view("afib", 10, 16, 0, &[(2, 3)])).selections;
        assert_eq!(half, vec![area(25.0, 0.0, 15.0, 16.0)]);
    }

    /// A face of the size `pixels` and nothing else.
    fn sized(pixels: u32) -> Face {
        Face {
            size: Some(Length::pixels(pixels)),
            ..Face::default()
        }
    }

    #[test]
    fn overlapping_sizes_shape_the_run_in_the_later_ones() {
        // `small` over 2..6 and `big` over 4..8, on cells 10 by 16 at the
        // base size: glyphs 5 across at 8 pixels and 20 across at 32.
        let frame_of = |first: &str, second: &str| {
            let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
            layout.define(&[def("small", sized(8)), def("big", sized(32))]);
            let mut view = view("abcdefghij", 40, 64, 0, &[]);
            view.decorations = vec![
                Decoration {
                    start: 2,
                    stop: 6,
                    face: first.to_owned(),
                },
                Decoration {
                    start: 4,
                    stop: 8,
                    face: second.to_owned(),
                },
            ];
            let small = layout.shaper().font(&FontSpec {
                size: Length::pixels(8),
                ..FontSpec::default()
            });
            let big = layout.shaper().font(&FontSpec {
                size: Length::pixels(32),
                ..FontSpec::default()
            });
            let row = frame(&mut layout, view).rows.remove(0);
            let glyphs: Vec<(ResolvedFontId, f32)> = row
                .line
                .glyphs
                .iter()
                .map(|glyph| (glyph.font, glyph.advance))
                .collect();
            let drawn = CellShaper::resolved_of;
            (glyphs, drawn(small), drawn(big), row.height)
        };
        // The later decoration of the list is over the earlier one: the
        // overlap, 4..6, is in the later one's font.
        let (glyphs, small, big, height) = frame_of("small", "big");
        let base = (CellShaper::resolved_of(FontId(0)), 10.0);
        let expected: Vec<(ResolvedFontId, f32)> = [
            [base; 2],
            [(small, 5.0); 2],
            [(big, 20.0); 2],
            [(big, 20.0); 2],
            [base; 2],
        ]
        .concat();
        assert_eq!(glyphs, expected);
        assert_eq!(height, 32.0);
        // Listed the other way round, the overlap is in the small one,
        // which is now the later.
        let (glyphs, small, big, _) = frame_of("big", "small");
        let expected: Vec<(ResolvedFontId, f32)> = [
            [base; 2],
            [(big, 20.0); 2],
            [(small, 5.0); 2],
            [(small, 5.0); 2],
            [base; 2],
        ]
        .concat();
        assert_eq!(glyphs, expected);
    }

    #[test]
    fn a_selection_whose_face_sets_a_font_is_over_a_decoration_that_sets_one() {
        let mut layout = Layout::new(CellShaper::new(10.0, 16.0));
        layout.define(&[def("big", sized(32)), def("selection", sized(8))]);
        // `big` over 0..4, and 2..6 selected.
        let mut view = view("abcdef", 40, 64, 0, &[(2, 6)]);
        view.decorations = vec![Decoration {
            start: 0,
            stop: 4,
            face: "big".to_owned(),
        }];
        let row = frame(&mut layout, view).rows.remove(0);
        let advances: Vec<f32> = row.line.glyphs.iter().map(|glyph| glyph.advance).collect();
        assert_eq!(advances, vec![20.0, 20.0, 5.0, 5.0, 5.0, 5.0]);
    }

    /// A source that records the ranges it is asked for.
    struct Counting {
        asked: RefCell<Vec<Range<usize>>>,
    }

    impl DecorationSource for Counting {
        fn spans(&self, _snapshot: &Snapshot, bytes: Range<usize>, _out: &mut Vec<Span>) {
            self.asked.borrow_mut().push(bytes);
        }
    }

    #[test]
    fn decorations_are_asked_only_for_the_rows_shown() {
        let text = "row\n".repeat(1000);
        let mut layout = layout();
        // Row 500 starts at byte 2000; five rows are shown.
        let shown = view(&text, 10, 80, 2000, &[]);
        let counting = Counting {
            asked: RefCell::new(vec![]),
        };
        let frame = layout.view_frame(&shown, false, &[&counting]);
        assert_eq!(frame.rows.len(), 5);
        let asked = counting.asked.into_inner();
        assert!(!asked.is_empty());
        assert!(
            asked
                .iter()
                .all(|bytes| bytes.start >= 2000 && bytes.end <= 2019),
            "{asked:?}"
        );
    }

    /// `view` with `spans` as its text's own spans.
    fn with_spans(mut view: View, spans: &FixedSpans) -> View {
        view.text = view
            .text
            .map(|text| text.with_spans(Arc::new(spans.clone())));
        view
    }

    #[test]
    fn text_spans_are_drawn_in_their_faces() {
        let mut layout = layout();
        let spans = FixedSpans::new(&["tab", "face"], vec![(1..3, 0), (4..6, 1)]);
        let runs = first_runs(
            &mut layout,
            with_spans(view("abcdef", 10, 16, 0, &[]), &spans),
        );
        assert_eq!(
            runs,
            vec![
                (0..1, PLAIN),
                (1..3, paint(RED, BASE_BACKGROUND)),
                (3..4, PLAIN),
                (4..6, paint(GREEN, BASE_BACKGROUND)),
            ]
        );
    }

    #[test]
    fn text_spans_are_under_the_scene_decorations_and_the_selection() {
        let mut layout = layout_with(&[
            def(
                "under",
                Face {
                    background: Some(GREY),
                    ..fg(RED)
                },
            ),
            def("over", fg(GREEN)),
            def("selection", bg(BLUE)),
        ]);
        let spans = FixedSpans::new(&["under"], vec![(0..6, 0)]);
        let view = decorated(view("abcdef", 10, 16, 0, &[(3, 5)]), &[(2..4, "over")]);
        let runs = first_runs(&mut layout, with_spans(view, &spans));
        assert_eq!(
            runs,
            vec![
                (0..2, paint(RED, GREY)),
                // The decoration's foreground over the span's.
                (2..3, paint(GREEN, GREY)),
                // The selection's background over both.
                (3..4, paint(GREEN, BLUE)),
                (4..5, paint(RED, BLUE)),
                (5..6, paint(RED, GREY)),
            ]
        );
    }

    #[test]
    fn text_spans_are_asked_only_for_the_rows_shown() {
        let text = "row\n".repeat(1000);
        let mut layout = layout();
        let spans = FixedSpans::new(&["face"], vec![(0..text.len(), 0)]);
        // Row 500 starts at byte 2000; five rows are shown.
        let frame = frame(
            &mut layout,
            with_spans(view(&text, 10, 80, 2000, &[]), &spans),
        );
        assert_eq!(frame.rows.len(), 5);
        let asked = spans.asked();
        assert!(!asked.is_empty());
        assert!(
            asked
                .iter()
                .all(|bytes| bytes.start >= 2000 && bytes.end <= 2019),
            "{asked:?}"
        );
    }

    #[test]
    fn a_text_with_no_spans_lays_out_as_before() {
        /// Spans that draw nothing over any snapshot.
        struct Nothing;
        impl TextSpans for Nothing {
            fn at(&self, _snapshot: &Snapshot) -> Option<Box<dyn SpansAt>> {
                None
            }
        }
        let text = "ab\ncdé\n";
        let plain = frame(&mut layout(), view(text, 10, 64, 0, &[(1, 4)]));
        let mut nothing = view(text, 10, 64, 0, &[(1, 4)]);
        nothing.text = nothing.text.map(|text| text.with_spans(Arc::new(Nothing)));
        assert_eq!(frame(&mut layout(), nothing), plain);
        let empty = FixedSpans::new(&[], vec![]);
        assert_eq!(
            frame(
                &mut layout(),
                with_spans(view(text, 10, 64, 0, &[(1, 4)]), &empty)
            ),
            plain
        );
    }

    /// A scene of one view of `ab\ncd` with a status field, its second
    /// row in the face `big` and its status field in the face `name`.
    fn two_fonts_scene() -> Scene {
        let view = decorated(view("ab\ncd", 20, 80, 0, &[]), &[(3..5, "big")]);
        Scene {
            views: vec![with_status(view, &[("x", "name")])],
            ..Scene::default()
        }
    }

    /// The faces of [`two_fonts_scene`]: `big` at twice the base size and
    /// `name` in bold.
    fn two_fonts_faces() -> Vec<FaceDef> {
        let bold = Face {
            weight: Some(Weight::BOLD),
            ..Face::default()
        };
        vec![def("big", sized(32)), def("name", bold)]
    }

    #[test]
    fn a_frame_carries_the_generation_and_every_font_its_glyphs_name() {
        let mut layout = layout_with(&two_fonts_faces());
        let frame = layout.frame(&two_fonts_scene());
        assert_eq!(frame.generation, layout.shaper().generation());
        // The table is the shaper's, as it is once the views are laid
        // out: the default font, and the two the faces came to.
        assert_eq!(frame.fonts, layout.shaper().resolved());
        assert_eq!(frame.fonts.len(), 3);
        let view = &frame.views[0];
        let status = view.status.as_ref().expect("a status row");
        let lines = view.rows.iter().map(|row| &row.line).chain([&status.line]);
        let mut named = Vec::new();
        for glyph in lines.flat_map(|line| &line.glyphs) {
            let font = frame.fonts.get(glyph.font.0 as usize);
            assert!(
                font.is_some(),
                "{glyph:?} names no font of {:?}",
                frame.fonts
            );
            named.push(glyph.font);
        }
        // Each of the three is named by a glyph, and the big one is
        // described at its size.
        named.sort_unstable();
        named.dedup();
        assert_eq!(named.len(), 3);
        let big = view.rows[1].line.glyphs[0].font;
        assert_eq!(frame.fonts[big.0 as usize].size, 32.0);
    }

    #[test]
    fn a_frame_after_the_fonts_change_has_another_generation() {
        let mut layout = layout_with(&two_fonts_faces());
        let before = layout.frame(&two_fonts_scene());
        assert_eq!(
            layout.frame(&two_fonts_scene()).generation,
            before.generation
        );
        layout.shaper().change_fonts();
        let after = layout.frame(&two_fonts_scene());
        assert_ne!(after.generation, before.generation);
        assert_eq!(after.generation, layout.shaper().generation());
        // The frame of an empty scene carries both too.
        let empty = layout.frame(&Scene::default());
        assert_eq!(empty.generation, after.generation);
        assert_eq!(empty.fonts, layout.shaper().resolved());
    }

    #[test]
    fn two_frames_are_equal_when_their_views_generations_and_fonts_are() {
        let mut layout = layout_with(&two_fonts_faces());
        let frame = layout.frame(&two_fonts_scene());
        // Another layout handed the same scene and faces asks its shaper
        // for the same fonts in the same order.
        let mut other = layout_with(&two_fonts_faces());
        assert_eq!(other.frame(&two_fonts_scene()), frame);
        // The same views under another generation.
        other.shaper().change_fonts();
        let changed = other.frame(&two_fonts_scene());
        assert_eq!(changed.views, frame.views);
        assert_ne!(changed, frame);
        // The same views, with one more font described after theirs.
        let mut more = layout_with(&two_fonts_faces());
        more.frame(&two_fonts_scene());
        more.shaper().font(&FontSpec {
            size: Length::pixels(48),
            ..FontSpec::default()
        });
        let wider = more.frame(&two_fonts_scene());
        assert_eq!(wider.views, frame.views);
        assert_ne!(wider, frame);
    }

    #[test]
    fn a_frame_is_shared_between_threads_as_it_is() {
        fn shared<T: Send + Sync>() {}
        shared::<Frame>();
    }

    /// A scene of no view whose dividers are `dividers`, each a rectangle
    /// and a face's name.
    fn divided(dividers: &[(Rect, &str)]) -> Scene {
        Scene {
            dividers: dividers
                .iter()
                .map(|(rect, face)| Divider {
                    rect: *rect,
                    face: (*face).to_owned(),
                })
                .collect(),
            ..Scene::default()
        }
    }

    #[test]
    fn a_divider_is_a_fill_of_its_rectangle_in_its_faces_foreground() {
        let rect = Rect {
            x: 318,
            y: 0,
            width: 2,
            height: 464,
        };
        let frame = layout().frame(&divided(&[(rect, "tab")]));
        assert_eq!(frame.dividers, vec![Fill { rect, color: RED }]);
    }

    #[test]
    fn a_divider_in_a_face_nothing_defines_is_filled_in_the_default_faces_foreground() {
        let rect = Rect {
            x: 0,
            y: 230,
            width: 318,
            height: 2,
        };
        let mut layout = layout();
        let base = layout.frame(&divided(&[(rect, "nothing")]));
        assert_eq!(
            base.dividers,
            vec![Fill {
                rect,
                color: BASE_FOREGROUND
            }]
        );
        layout.define(&[def("default", fg(GREY)), def("default", bg(GREEN))]);
        let defaulted = layout.frame(&divided(&[(rect, "nothing")]));
        assert_eq!(defaulted.dividers, vec![Fill { rect, color: GREY }]);
        // A divider's face's background is not its colour.
        layout.define(&[def("default", fg(GREY)), def("ground", bg(RED))]);
        let grounded = layout.frame(&divided(&[(rect, "ground")]));
        assert_eq!(grounded.dividers, vec![Fill { rect, color: GREY }]);
    }

    #[test]
    fn a_scene_with_no_divider_gives_no_fill_and_frames_differ_by_their_fills() {
        let rect = Rect {
            x: 318,
            y: 0,
            width: 2,
            height: 464,
        };
        let mut layout = layout();
        let plain = layout.frame(&Scene::default());
        assert!(plain.dividers.is_empty());
        let filled = layout.frame(&divided(&[(rect, "tab")]));
        assert_eq!(filled.views, plain.views);
        assert_ne!(filled, plain);
    }
}
