import Editor.Program
import Editor.Scene

/-!
# The display interface

The port through which Lean publishes a scene (`Editor/Scene.lean`) and asks
layout the two questions commands need of it, answered in the same call:

- **the rows a view shows** from its scroll anchor (`Display.rowsShown`): the
  byte range of each visual row, from the one that holds the anchor, as many
  as fit the view's height;
- **the position some visual lines away** from a position
  (`Display.linesFrom`), with the x it aimed for passed back so that the next
  move aims for it too (Vim's "curswant").

Lean keeps no layout of its own: what wraps where, and how tall a row is, is
asked here every time. Xi's experience is the reason
(`docs/design/text-and-display.md`, "The scene").

Like every port (`Editor/Program.lean`) it has a pure model and a real
binding:

- the model, `Editor/Display/Model.lean`, records the scenes published and
  answers the queries by laying text out in fixed-size cells. It is for
  tests, not a layout kept at run time;
- the real binding is the display pipeline's (its phase 1), over its layout;
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
| Another question of layout (the position at a point) | A constructor of `DisplayRequest`, its reply in `DisplayRequest.Reply`, its operation here, and a property in the contract | The display pipeline adds it when something needs it |
| A field of what is published | A field of `Scene` (`Editor/Scene.lean`) | The command loop |
| The editor's port | This port combined with the text port | The command loop, phase 2 |
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
  /-- The view's width, in pixels: where rows wrap. -/
  width : Nat
  /-- The view's height, in pixels: how many rows fit. -/
  height : Nat
  /-- The scroll anchor's byte offset: the rows start at the one that holds
  it. -/
  anchor : Nat
  deriving DecidableEq, Repr

/-- Where a position goes when it moves some visual lines. -/
structure MoveQuery where
  /-- The text. -/
  snapshot : SnapshotId
  /-- The view's width, in pixels: where rows wrap. -/
  width : Nat
  /-- The byte offset to move from. -/
  position : Nat
  /-- How many visual rows to move: down when positive, up when negative. -/
  lines : Int
  /-- The x, in pixels from the row's start, that the move aims for: what
  the last move passed back, or `none` to aim for the position's own. -/
  goal : Option Nat
  deriving DecidableEq, Repr

/-- Where a move went. -/
structure Moved where
  /-- The byte offset it reached. -/
  position : Nat
  /-- The x it aimed for, to pass to the next move. -/
  goal : Nat
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

/-- The type of the reply to each request. -/
def DisplayRequest.Reply : DisplayRequest → Type
  | .publish _ => Unit
  | .rows _ => Except DisplayError (Array Display.Row)
  | .move _ => Except DisplayError Display.Moved

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

end Display

end Editor
