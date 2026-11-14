import Editor.Text

/-!
# The scene

What Lean publishes to the display after each command: plain data that says
what every view shows, and nothing about how it looks. Rendering works from
the last scene published, on its own thread, so painting never waits on Lean
(`docs/design/text-and-display.md`, "The scene").

- **Content is named by handles, never copied.** A view names the text it
  shows by a snapshot (`SnapshotId`), its scroll anchor and its selections by
  markers of that text (`MarkerId`); a selection marker carries its ranges
  and its `Shape`. So the real binding can send a view whose text has not
  changed as the same handles, and publishing costs what changed.
- **Faces are named only** (`FaceName`). What a face looks like, themes and
  how faces merge are the display pipeline's (its phase 2).
- **The scene only carries choices made elsewhere.** Which fields a view's
  status line holds is the command loop's choice (`Loop.status`,
  `Editor/Loop.lean`): the buffer's name, and a modified field while the
  buffer is modified. Which cursor shape and face a view has is chosen by a
  later phase of the command loop (the evil state in phase 11). The pending
  key prefix is rendered by Lean into a string.
- Sizes and rectangles are in the frame's physical pixels.

## Where an addition goes

| Addition | Lean (command loop) | Rust (display pipeline) |
|---|---|---|
| A new field of the scene or of a view | A field here, which the command loop fills | The same field in the Rust scene and its binding (its phase 1); drawing a new face (its phase 2) |
| A new cursor shape | A constructor of `CursorShape` | Its drawing |
| A new kind of thing a view shows (a terminal) | A field or a constructor here | The view's renderer |

The scene is pinned by `ModelTest.sceneChecks`. It is published through the
display interface (`Editor/Display.lean`).
-/

namespace Editor

/-- The name of a face: how a span, a cursor or a status field is to look,
named and not described. -/
structure FaceName where
  /-- The name, such as `cursor.normal` or `search.match`. -/
  name : String
  deriving DecidableEq, Repr

/-- The shape a cursor is drawn as. -/
inductive CursorShape where
  /-- A filled cell. -/
  | block
  /-- A thin bar before the cell. -/
  | bar
  /-- A line under the cell. -/
  | underline
  /-- The outline of a cell, as for a view that does not have the focus. -/
  | hollow
  deriving DecidableEq, Repr

/-- How a view's cursors are drawn. -/
structure Cursor where
  /-- Their shape. -/
  shape : CursorShape
  /-- The face they take. -/
  face : FaceName
  deriving DecidableEq, Repr

/-- A span of a view's text drawn in a face. -/
structure Decoration where
  /-- The byte offset where the span starts, in the view's snapshot. -/
  start : Nat
  /-- The byte offset where it stops, not included. -/
  stop : Nat
  /-- The face it takes. -/
  face : FaceName
  deriving DecidableEq, Repr

/-- One field of a view's status line. -/
structure StatusField where
  /-- What it says. -/
  text : String
  /-- The face it takes. -/
  face : FaceName
  deriving DecidableEq, Repr

/-- A size, in physical pixels. -/
structure Size where
  /-- Across. -/
  width : Nat
  /-- Down. -/
  height : Nat
  deriving DecidableEq, Repr

/-- A rectangle of the frame, in physical pixels from its top left. -/
structure Rect where
  /-- From the left. -/
  x : Nat
  /-- From the top. -/
  y : Nat
  /-- Across. -/
  width : Nat
  /-- Down. -/
  height : Nat
  deriving DecidableEq, Repr

/-- The name of a view in a scene. -/
structure ViewId where
  /-- Which view: the command loop's number for it. -/
  index : Nat
  deriving DecidableEq, Repr

/-- One view: what it shows, where, and how its cursors, spans and status
line look. -/
structure View where
  /-- Which view. -/
  id : ViewId
  /-- Where it is in the frame. -/
  rect : Rect
  /-- The text it shows, by handle. -/
  snapshot : SnapshotId
  /-- Its scroll anchor: an anchor marker of that text, at the start of the
  first row it shows. -/
  scroll : MarkerId
  /-- Its selections: selection markers of that text, each carrying its
  ranges and its shape. -/
  selections : Array MarkerId
  /-- How its cursors are drawn. -/
  cursor : Cursor
  /-- Spans of its text drawn in a face. -/
  decorations : Array Decoration
  /-- Its status line, field by field. -/
  status : Array StatusField
  deriving DecidableEq, Repr

/-- Everything the display shows, as published after a command. -/
structure Scene where
  /-- The frame's size. -/
  size : Size
  /-- The views, in the order they are drawn. -/
  views : Array View
  /-- The view that has the keyboard focus, if one has. -/
  focused : Option ViewId
  /-- The echo area's text. -/
  echo : String
  /-- The pending key prefix, as Lean renders it; empty when there is
  none. -/
  pending : String
  /-- The text an input method is composing in the focused view, if it is
  composing. -/
  preedit : Option String
  deriving DecidableEq, Repr

end Editor
