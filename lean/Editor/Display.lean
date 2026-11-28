import Editor.Appearance
import Editor.Program
import Editor.Scene

/-!
# The display interface

The port through which Lean publishes a scene (`Editor/Scene.lean`) and asks
layout the three questions commands need of it, answered in the same call:

- **the rows a view shows** from its scroll anchor (`Display.rowsShown`): the
  byte range of each visual row, from the one that holds the anchor, as many
  as fit the view's height;

Each question carries the view's padding in points (`RowsQuery.padding`,
`MoveQuery.across`), because it differs by view, and the display takes it
off the width and the height at the scale it lays out at, as its frame
does, so the answer is the rows the frame shows. Lean never handles a
scale (`docs/design/README.md`, "The window's scale"). The model and the
recorder, which lay out in cells at scale 1, take the points off as
pixels; the contract holds every binding to "a padded question is the
unpadded question of the smaller area" (`Display/Contract.lean`).
- **the position some visual lines away** from a position
  (`Display.linesFrom`), with the x it aimed for passed back so that the next
  move aims for it too (Vim's "curswant");
- **where a position is drawn** in a view (`Display.spotOf`): the x of its
  left edge and the y of the top of the row that holds it, in pixels from
  the view's top left with its padding included, and that row's height;
  none when the view does not show it. A float anchored at a position is
  placed against it (`Editor/Floating.lean`);
- **how wide a run is** in its faces (`Display.measure`, `Display.widthIn`):
  its width laid out unbroken, in whole points rounded up, which a
  generator computes a view's align-to stops from (`AlignStop`,
  `Editor/Columns.lean`). It names no snapshot and no view: the run is a
  string, and its faces are decorations of it over the default face.

The third is a question of its own, not worked out from the first two,
for two reasons. The padding is in points, which the display takes off
at a scale Lean never sees, so Lean cannot add it back in pixels; and
rows are not one height, since a face may set a size or a line height,
so the k-th row shown is not `k` text rows down. The contract ties it to
the first two (`Display/Contract.lean`): in cells, a spot's y is the
padding plus `k` rows for the `k`-th row `rowsShown` answers, and its x
is the padding plus the goal a move of no lines passes back.

## Blocks

A view's blocks (`Block`, `View.blocks`) are rows of text of their own
between the rows of its text. They ride on the two questions that count
heights, the rows a view shows and a spot (`RowsQuery.blocks`,
`SpotQuery.blocks`), and on the scene; the move query takes none. Every
binding answers by one rule:

- A block is drawn above the first visual row of the line that holds its
  `before`, which is moved back to a character boundary, and to the end of
  the text from past it. Several before one line are drawn in the order
  listed.
- A block takes as many rows as its text wraps to at the view's width, and
  each counts among the rows that fit, as a text row does.
- A line's blocks are shown with its first row or not at all: the rows
  stop before blocks whose row does not fit with them. The first row shown
  is the anchor's: its blocks are shown above it only when they fit with
  it, and are left out otherwise, so a view a row tall always shows its
  anchor's row. An anchor on a wrapped row after a line's first has no
  blocks above it.
- The rows answered are text rows only, and a spot below a block is lower
  by its rows.
- **A block holds no position.** A move goes over it as if it were not
  there, and a position converts to a row and back as without blocks.

## Folds

A view's folds (`Fold`, `View.folds`) are ranges of its text each drawn as
one placeholder row. Unlike a block, a fold changes which rows exist, so the
folds ride on all three questions (`RowsQuery.folds`, `MoveQuery.folds`,
`SpotQuery.folds`) as well as on the scene. Every binding answers by one
rule:

- A fold covers the lines that hold a byte of its range `[start, stop)`, a
  line break being the line's it ends, or the line of `start` when the range
  is empty; an offset past the end is the end, and a byte inside a
  character is on that character's line. The folds are taken in order of
  start, the longer first of two with one start, and one whose first line an
  earlier one covers is dropped, so a binding handed nested folds shows the
  outer one.
- The covered lines are one row, whatever they wrap to: the placeholder,
  one row tall. The rows answer gives it as the first covered line's start
  through the end of the last covered line's characters.
- The placeholder holds every position of the lines it covers, each at x 0:
  an anchor in them shows from the placeholder, a spot of any of them is the
  placeholder's row at the padding's x, and a move counts the placeholder as
  one row and, landing on it, goes to the fold's start, passing its goal
  back unchanged.
- A block before the first covered line is drawn above the placeholder, and
  one before a later covered line is not drawn.

Lean keeps no layout of its own: what wraps where, and how tall a row is, is
asked here every time. Xi's experience is the reason
(`docs/design/text-and-display.md`, "The scene").

Like every port (`Editor/Program.lean`) it has a pure model and a real
binding:

- the model, `Editor/Display/Model.lean`, records the scenes published and
  answers the queries by laying text out in fixed-size cells. It is for
  tests, not a layout kept at run time;
- the real binding, `Editor/Display/Real.lean`, is the display pipeline's
  (its phase 1): the Rust library's layout (`crates/editor-layout`), reached
  through `Ffi.Display`, which reads the text binding's table of
  snapshots;
- where there is no window, as in the headless host, the recorder
  (`Editor/Display/Recorder.lean`) keeps the last scene published and
  answers the queries with the model's rule over the library's snapshots.
  It is the one place the model's rule runs outside a test, because a
  host with no window has no layout to ask; an editor with a window asks
  the real binding;
- the contract, `Editor/Display/Contract.lean`, is the one list of properties
  of the queries that all three are held to. It is run against the model
  by `model-test` and against the recorder over the library's snapshots by
  `contract-test`, and the display pipeline runs it against the real
  binding over its fake
  shaper, whose every glyph has the advance and the line height of the
  `Display.Cells` the contract is run at.

## Where an addition goes

| Addition | Where | Owner |
|---|---|---|
| Another question of layout (the position at a point) | A constructor of `DisplayRequest`, its reply in `DisplayRequest.Reply`, its operation here, its answer in the model, the recorder and the real binding, and a property in the contract | The display pipeline adds it when something needs it; `heights` came so, for sizing a view's text area and the minibuffer's place, `spot` for placing a float beside a position (window management, phase 4), and `measure` for computing align-to stops (rich text display, phase 2) |
| A field of what is published | A field of `Scene` (`Editor/Scene.lean`) | The command loop |
| A request a command makes of the display | Nothing new: a command reaches this port through the editor's composite port (`Editor/Command.lean`), which lifts every operation here | The command loop |
| A new thing to ask of the window | A constructor of `FrameRequest`, its case in the model, the recorder, the real binding, `Ffi.WindowRequest` and `editor-ffi`'s request tags, and a variant of `editor-platform`'s `Request` | The macOS app roadmap added the first three |

## Asking the window

The display is also how a command asks the platform's window to do
something (`Display.askFrame`, a `FrameRequest`): enter or leave the system's
fullscreen, or minimise; draw the window's title and buttons in the light
or the dark appearance (`Editor/Appearance.lean`), which the reload reducer
asks for from the paper; or keep running, which tells the system the editor
refused or withdrew the quit it asked (`Loop.publish`), and changes nothing
the window shows. A frame request answers nothing and changes no
answer of layout. Whether the window is then in fullscreen comes back as a
resize (`Event.Resize.fullscreen`), which the loop keeps in the frame
(`Frame.fullscreen`), whether a request or the user made the change. It is
guarded like any request the loop does not answer in place, and like the
clipboard it is outside the editor: a command rolled back does not take it back. The
model records each in order (`DisplayModel.asked`); the recorder, which has
no window, answers it and does nothing; the real binding sends it to the
window it was made with (`RealDisplay.platform`).
-/

namespace Editor

/-- Why the display refused a query. -/
inductive DisplayError where
  /-- The snapshot is not one the display knows. -/
  | noSuchSnapshot
  /-- An offset is not a character boundary within the text. -/
  | badPosition
  deriving DecidableEq, Repr

namespace Display

/-- The size of the cells the contract lays text out in: every character is
`advance` pixels across and every row `lineHeight` pixels down. Each is at
least 1. The model lays out in them, and the real binding's fake shaper is
set to them. -/
structure Cells where
  /-- How far across a character is, in pixels. -/
  advance : Nat
  /-- How far down a row is, in pixels. -/
  lineHeight : Nat
  deriving DecidableEq, Repr

/-- The heights of the rows a frame is built of, in whole pixels, each at
least 1 (`Display.heights`). -/
structure Heights where
  /-- One text row in the default face. -/
  text : Nat
  /-- A window's status row: the face `mode-line`. -/
  status : Nat
  /-- The frame's bottom row: the taller of the faces `echo-area` and
  `mode-line`. -/
  message : Nat
  deriving DecidableEq, Repr, Inhabited

/-- The heights in cells of `cells`: each a cell's height, and at least 1. -/
def Cells.heights (cells : Cells) : Heights :=
  let tall := max 1 cells.lineHeight
  { text := tall, status := tall, message := tall }

/-- One visual row of a text: the bytes from `start` up to `stop`, without
its line break. -/
structure Row where
  /-- The byte offset of the row's first character. -/
  start : Nat
  /-- The byte offset where the row's characters stop, before any line
  break. -/
  stop : Nat
  deriving DecidableEq, Inhabited, Repr

/-- Which rows a view shows. -/
structure RowsQuery where
  /-- The text the view shows. -/
  snapshot : SnapshotId
  /-- The view's width, in pixels: where rows wrap, less its padding. -/
  width : Nat
  /-- The view's height, in pixels: how many rows fit, less its padding. -/
  height : Nat
  /-- The scroll anchor's byte offset: the rows start at the one that holds
  it. -/
  anchor : Nat
  /-- The view's padding, in points: the display takes twice `across` and
  once `gutter` off the width, and twice `down` and once `top` off the
  height, at the scale it lays out at, as its frame does. Lean subtracts
  nothing. -/
  padding : Padding := {}
  /-- The view's blocks: their rows count among the rows that fit, by the
  rule its frame draws them by (the module docs, "Blocks"). None by
  default. -/
  blocks : Array Block := #[]
  /-- The view's folds: each shows its covered lines as one row (the module
  docs, "Folds"). None by default. -/
  folds : Array Fold := #[]
  deriving DecidableEq, Repr

/-- Where a position goes when it moves some visual lines. -/
structure MoveQuery where
  /-- The text. -/
  snapshot : SnapshotId
  /-- The view's width, in pixels: where rows wrap, less its padding. -/
  width : Nat
  /-- The view's padding across, in points: the display takes it off both
  sides of the width, at its scale. A move only wraps, so it takes no
  padding down. -/
  across : Nat := 0
  /-- The width of the view's gutter column, in points: the display takes it
  off the width once, at its scale, as its frame does. -/
  gutter : Nat := 0
  /-- The byte offset to move from. -/
  position : Nat
  /-- How many visual rows to move: down when positive, up when negative. -/
  lines : Int
  /-- The x, in pixels from the row's start, that the move aims for: what
  the last move passed back, or `none` to aim for the position's own. -/
  goal : Option Nat
  /-- The view's folds, as `RowsQuery.folds`: a fold is one row to a move,
  and a move that lands on it goes to its start. -/
  folds : Array Fold := #[]
  deriving DecidableEq, Repr

/-- Where a move went. -/
structure Moved where
  /-- The byte offset it reached. -/
  position : Nat
  /-- The x it aimed for, to pass to the next move. -/
  goal : Nat
  deriving DecidableEq, Repr

/-- Where a position is drawn in a view. -/
structure SpotQuery where
  /-- The text the view shows. -/
  snapshot : SnapshotId
  /-- The view's width, in pixels, as `RowsQuery.width`. -/
  width : Nat
  /-- The view's height less its bottom row, in pixels, as
  `RowsQuery.height`. -/
  height : Nat
  /-- The scroll anchor's byte offset, as `RowsQuery.anchor`. -/
  anchor : Nat
  /-- The view's padding, in points, as `RowsQuery.padding`. -/
  padding : Padding := {}
  /-- The byte offset of the position. -/
  position : Nat
  /-- The view's blocks, as `RowsQuery.blocks`: a position below a block
  is lower by the block's rows. -/
  blocks : Array Block := #[]
  /-- The view's folds, as `RowsQuery.folds`: a position a fold covers is
  drawn at its placeholder's x 0, and one below a fold is higher by the rows
  it hides. -/
  folds : Array Fold := #[]
  deriving DecidableEq, Repr

/-- Where a position is drawn in a view, in whole pixels from the view's
top left, its padding included. -/
structure Spot where
  /-- From the view's left edge to the position's left. -/
  x : Nat
  /-- From the view's top edge to the top of the row that holds it. -/
  y : Nat
  /-- How tall that row is. -/
  height : Nat
  deriving DecidableEq, Repr, Inhabited

/-- How wide a run is (`Display.measure`). -/
structure MeasureQuery where
  /-- The run: up to its first line feed, its tabs reaching to the next
  multiple of eight cells from its start. -/
  text : String
  /-- Spans of `text` drawn in a face, its offsets bytes of `text`: the
  run's faces, over the default face. None by default. -/
  decorations : Array Decoration := #[]
  deriving DecidableEq, Repr

end Display

namespace Display

/-- What Lean asks of the platform's window, the frame (`Editor.Frame`). -/
inductive FrameRequest where
  /-- Put the window in the system's fullscreen; one in it stays there. -/
  | enterFullscreen
  /-- Take the window out of the system's fullscreen; one out of it stays
  out. -/
  | leaveFullscreen
  /-- Minimise the window. -/
  | minimise
  /-- The editor refused, or withdrew, the quit the system asked
  (`Event.quitRequested`), so the system stops waiting for it to quit. It
  changes nothing the window shows. -/
  | keepRunning
  /-- Draw the window's title and buttons in this appearance, so that they
  contrast with the paper under them. -/
  | appearance (appearance : Appearance)
  deriving DecidableEq, Repr

end Display

/-- What Lean may ask of the display. A new question is a constructor here. -/
inductive DisplayRequest where
  /-- Show `scene` from now on. -/
  | publish (scene : Scene)
  /-- Which rows a view shows. -/
  | rows (query : Display.RowsQuery)
  /-- Where a position goes when it moves some visual lines. -/
  | move (query : Display.MoveQuery)
  /-- Where a position is drawn in a view. -/
  | spot (query : Display.SpotQuery)
  /-- How tall a text row, a window's status row and the frame's bottom row
  are. -/
  | heights
  /-- How wide a run is in its faces, in whole points. -/
  | measure (query : Display.MeasureQuery)
  /-- Ask the platform's window to do something: it answers nothing. -/
  | frame (request : Display.FrameRequest)

/-- The type of the reply to each request. -/
def DisplayRequest.Reply : DisplayRequest → Type
  | .publish _ => Unit
  | .rows _ => Except DisplayError (Array Display.Row)
  | .move _ => Except DisplayError Display.Moved
  | .spot _ => Except DisplayError (Option Display.Spot)
  | .heights => Display.Heights
  | .measure _ => Nat
  | .frame _ => Unit

/-- The display port: `DisplayRequest` and the reply to each request. -/
abbrev displayPort : Port :=
  { Request := DisplayRequest, Reply := DisplayRequest.Reply }

/-- A program over the display port that may be refused with a
`DisplayError`. -/
abbrev DisplayM :=
  ExceptT DisplayError (Program displayPort)

/-- An answerer of the display port's requests in `IO`: the real binding,
or, with no window, the headless host's recorder
(`Editor/Display/Recorder.lean`). A runner of commands is handed one. -/
abbrev DisplayHandler :=
  (request : DisplayRequest) → IO request.Reply

/-- Runs a display program against `handler`: its result, or the refusal it
failed with. -/
def DisplayM.runWith {α : Type} (program : DisplayM α) (handler : DisplayHandler) :
    IO (Except DisplayError α) :=
  Program.runM (port := displayPort) handler program.run

namespace Display

/-- Publishes `scene`: the display shows it from now on. -/
def publish (scene : Scene) : DisplayM Unit :=
  ExceptT.lift (Program.request (port := displayPort) (.publish scene))

/-- The rows a view shows: from the visual row that holds the anchor, as many
as fit its height, fewer at the end of the text. Refused with
`noSuchSnapshot` for a snapshot the display does not know, and with
`badPosition` for an anchor that is not a character boundary within the
text. -/
def rowsShown (query : RowsQuery) : DisplayM (Array Row) :=
  ExceptT.mk (Program.request (port := displayPort) (.rows query))

/-- The position `query.lines` visual rows below (or above, when negative)
`query.position`, aiming for the x `query.goal`, and the goal to pass to the
next move. A move past the first or the last row stops there. Refused as
`rowsShown` is. -/
def linesFrom (query : MoveQuery) : DisplayM Moved :=
  ExceptT.mk (Program.request (port := displayPort) (.move query))

/-- Where `query.position` is drawn in a view that shows from
`query.anchor`: the x of its left edge and the y of the top of the row that
holds it, from the view's top left with its padding included, and that
row's height, in whole pixels at the display's scale. None when the
position is not among the rows `rowsShown` answers for the same view,
which includes a position before the anchor. Refused as `rowsShown` is,
for the anchor or the position. -/
def spotOf (query : SpotQuery) : DisplayM (Option Spot) :=
  ExceptT.mk (Program.request (port := displayPort) (.spot query))

/-- The heights of the rows a frame is built of, in whole pixels at the
display's scale: a text row in the default face, a window's status row, and
the frame's bottom row, where the echo or the prompt is drawn. A caller
that sizes a view's text area as its height less its bottom row asks
`rowsShown` for exactly the rows the frame shows. -/
def heights : DisplayM Heights :=
  ExceptT.lift (Program.request (port := displayPort) .heights)

/-- How wide `query.text` is laid out unbroken in `query.decorations`' faces
over the default face, in whole points rounded up: what a generator
computes a view's align-to stops from (`Editor/Columns.lean`). The run
stops at its first line feed. It is in the faces the next frame is laid
out in, and names no snapshot, so it is refused nothing. -/
def measure (query : MeasureQuery) : DisplayM Nat :=
  ExceptT.lift (Program.request (port := displayPort) (.measure query))

/-- How wide `text` is in the face `face` over the default face, in whole
points (`measure` of one decoration over the whole run). -/
def widthIn (face : FaceName) (text : String) : DisplayM Nat :=
  measure { text, decorations := #[{ start := 0, stop := text.utf8ByteSize, face }] }

/-- Asks the platform's window to do what `request` says. It answers
nothing and changes no answer of layout: whether the window went into
fullscreen comes back as a resize, an event like any other. -/
def askFrame (request : FrameRequest) : DisplayM Unit :=
  ExceptT.lift (Program.request (port := displayPort) (.frame request))

end Display

end Editor
