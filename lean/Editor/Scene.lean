import Editor.Menu
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
  status line holds, on which side and with what padding, is the mode
  line's choice (`ModeLine.fields`, `Editor/ModeLine.lean`), called by the
  command loop (`Loop.statusOf`, `Editor/Loop.lean`): the segments config
  or the default order lists for each side, the input scheme's reported
  fields drawn by the `state` segment as a badge; and, for a window that
  is not selected, every field and the row (`View.statusFace`) in
  `mode-line.inactive`, and for the selected one the row in
  `mode-line.active`. Which strips of the frame are dividers between
  tiled views is the editor state's (`EditorState.dividers`,
  `Layout.carve`), and their face the loop's (`Loop.dividerFace`);
  layout fills each in its face's foreground. For the minibuffer's view while a prompt is open
  it is the prompt's label alone. The candidates the prompt has listed are
  a view of their own, over generated text, as the tab bar is: the
  candidate list (`Loop.candidateListView`), whose rows the completion
  display drew (`Editor/Completion/Display.lean`), its spans in faces as
  decorations.
  Where the fields go across the row, and what is cut when they do not
  fit, is layout's (`crates/editor-layout/src/frame.rs`, "The mode
  line").
  The scene has no field of its own for a
  prompt or for its candidates: the minibuffer's view is a view like any
  other, whose text is the input typed so far, and its status line is
  fields like any other's; the candidate list is a view like any other,
  with no selection and no status field. Which cursor shape and face a view has is the
  input scheme's to say (`InputScheme.report`, `Editor/InputScheme.lean`):
  the Vim scheme's is the cursor of the view's Vim state. The pending key
  prefix is rendered by Lean into a string, and drawn as a field of the
  selected window's status line (the `pending-keys` segment,
  `Editor/ModeLine.lean`), so it needs no field of its own on the wire.
- **The key hints are a Lean-only readout.** The key hints shown
  (`Scene.keyHints`: the keys that can follow the pending prefix, from
  `InputScheme.continuations`, once the key hint delay has passed) are
  data the command loop fills, but they do not cross to the Rust scene:
  they are drawn by the completion display chosen for the category `key`,
  as the candidate list's view, a view Lean makes, so no Rust code reads
  them.
- **A block is text only.** A view's blocks (`View.blocks`) are rows of
  text of their own between its rows, each in its own faces: which ones,
  and where, is the command loop's choice (an excerpt buffer's headers,
  `Editor/ExcerptView.lean`). Layout lays them out and counts them among
  the rows that fit; they hold no position.
- **A gutter mark is text only too.** A view's marks (`View.marks`) are drawn
  in a column of their own before its text, `Padding.gutter` points wide,
  beside the lines their ranges cover; which ones is the command loop's
  (`Gutter.marksOf`). Layout draws them and every query takes the column off
  the text's width (`crates/editor-layout/src/frame.rs`, "The gutter").
- **A stop is a place, not a face.** A view's align-to stops
  (`View.stops`) each name the first character of a cell of a row and how
  far right of the start of the text row it starts, in whole points:
  layout places the cell there, whatever the widths of the cells before
  it, which no count of spaces can do on a proportional font, and breaks
  the row before a stop past the view's width
  (`crates/editor-layout/src/align.rs`). Which ones is the buffer's owner's
  (`Buffer.stops`, set by `BufferId.setStops`), computed from widths the
  display measures (`Display.measure`, `Editor/Columns.lean`); the command
  loop copies them to every view of the buffer (`Loop.stopsOf`).
- Sizes and rectangles are in the frame's physical pixels. Paddings (a
  view's `padding`, the scene's `echoPadding`, a status field's `padding`)
  are in whole points, as a face's lengths are: layout multiplies them by
  the scale it lays out at, and Lean multiplies nothing
  (`crates/editor-layout/src/frame.rs`, "The padding").

## Where an addition goes

| Addition | Lean (command loop) | Rust (display pipeline) |
|---|---|---|
| A new field of the scene or of a view | A field here, which the command loop fills | The same field in the Rust scene and its binding (its phase 1); drawing a new face (its phase 2) |
| A new cursor shape | A constructor of `CursorShape` | Its drawing |
| A new kind of thing a view shows (a terminal) | A field or a constructor here | The view's renderer |
| A new decoration of a view drawn beside its text (a gutter mark) | A field of `View`, as `marks` | A field of the Rust `View`, drawn as rows of the frame, and its crossing |
| A readout only Lean draws, as a view of its own (the key hints) | A field here | Nothing: it does not cross |
| Something more the menu bar shows | A field or a constructor of `Editor/Menu.lean`'s types | `editor_platform::menu`, and the scene's crossing (`editor-ffi`'s `display/wire.rs` and `menu.rs`) |

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

/-- A block: rows of text of its own, drawn between two rows of a view, such
as an excerpt's header. It is the view's, as a decoration is, and text only:
it holds no position, so a position of the view's text is drawn and moved
to as it is without it, and only the height of the rows a view shows counts
its rows (`Editor/Display.lean`, "Blocks"). -/
structure Block where
  /-- A byte offset of the view's snapshot: the block is drawn above the
  first visual row of the line that holds it. -/
  before : Nat
  /-- What it says. -/
  text : String
  /-- Spans of `text` drawn in a face, its offsets bytes of `text`: the
  block's own faces, over the default face. -/
  decorations : Array Decoration := #[]
  deriving DecidableEq, Repr

/-- A gutter mark: a short text drawn in a view's gutter column
(`Padding.gutter`) beside every visual row of each line its range has a byte
in, or of the line that holds `start` when the range is empty, in its face
over `gutter` over the default face. Like a block it is the view's and holds
no position: the command loop moves it (`Gutter.marksOf`,
`Editor/Gutter.lean`). -/
structure GutterMark where
  /-- A byte offset of the view's snapshot where its range starts. -/
  start : Nat
  /-- Where it stops, not included. -/
  stop : Nat
  /-- What it says: `+`, `~` or `-` for a version-control gutter. -/
  text : String
  /-- The face it takes. -/
  face : FaceName
  deriving DecidableEq, Repr

/-- An align-to stop: where a cell of a row of a view's text starts. Like a
decoration it is the view's, and it holds no position: layout places the
cell at it and breaks the row before it when it is past the view's width
(`crates/editor-layout/src/align.rs`). -/
structure AlignStop where
  /-- A byte offset of the view's snapshot: the first character of the
  cell. -/
  offset : Nat
  /-- How far right of the start of the text row (after the view's padding
  and gutter) the cell starts, in whole points: layout multiplies it by the
  window's scale, as it does a padding. -/
  x : Nat
  deriving DecidableEq, Repr

/-- Which end of a view's status row a field is drawn from: the left fields
run from the row's start, and the right fields end at its end. -/
inductive StatusSide where
  /-- From the row's start, after the left fields before it. -/
  | left
  /-- Ending at the row's end, with the right fields after it. -/
  | right
  deriving DecidableEq, Repr

/-- One field of a view's status line. -/
structure StatusField where
  /-- What it says. -/
  text : String
  /-- The face it takes. -/
  face : FaceName
  /-- The side of the row it is drawn on. -/
  side : StatusSide := .left
  /-- The space before and after its text, in whole points (logical pixels),
  which its face's background fills. Layout multiplies it by the window's
  scale, as it does a face's lengths. -/
  padding : Nat := 0
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

/-- How far a view's content is inset from its edges, in whole points
(logical pixels), which layout multiplies by the window's scale. All 0 by
default, which lays out as a view with no padding. -/
structure Padding where
  /-- The inset of the text, and of the status row's first and last fields,
  from the view's left and right edges. -/
  across : Nat := 0
  /-- The inset of the text rows from the view's top and from the top of its
  status row (its bottom when it has none). -/
  down : Nat := 0
  /-- The further inset of the text rows from the view's top, beyond `down`:
  what a window's title bar covers of a view along the frame's top edge. -/
  top : Nat := 0
  /-- The width of the view's gutter column, a further inset of its text rows
  from its left, beyond `across`, which its marks (`View.marks`) are drawn
  in. 0, no column, by default. -/
  gutter : Nat := 0
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
  /-- The face of its status row, over `mode-line` and under every field's,
  which gives the row its background: `mode-line.inactive` for a window
  that is not selected, `mode-line.active` for the selected one, and none
  for the minibuffer's view. It neither makes the row taller nor moves its line. -/
  statusFace : Option FaceName := none
  /-- How far its text and its status fields are inset from its edges, in
  points (`EditorState.paddingOf`). The status row's background still spans
  the whole view, and the text's padding is the default face's paper. -/
  padding : Padding := {}
  /-- Its blocks, drawn between the rows of its text in the order listed
  where several are before one row: the header of each excerpt of an
  excerpt buffer (`Editor/ExcerptView.lean`). None by default. -/
  blocks : Array Block := #[]
  /-- Its gutter marks, drawn in its gutter column (`Padding.gutter`): the
  added, removed and changed lines of a tracked file
  (`packages/version-control/VersionControl/Gutter.lean`). None by default. -/
  marks : Array GutterMark := #[]
  /-- Its align-to stops, its buffer's (`Buffer.stops`) in the range its
  decorations are read over (`Loop.stopsOf`). None by default. -/
  stops : Array AlignStop := #[]
  deriving DecidableEq, Repr

/-- A divider: a strip of the frame between two tiled views, filled in the
foreground of its face. Which strips are dividers is the editor state's
(`EditorState.dividers`), and their face the command loop's
(`Loop.dividerFace`). -/
structure Divider where
  /-- Where it is in the frame. -/
  rect : Rect
  /-- The face whose foreground it is filled in. -/
  face : FaceName
  deriving DecidableEq, Repr

/-- What a key that can follow the pending prefix leads to, as a key hint
shows it. -/
inductive KeyHint.Leads where
  /-- A binding, with its description if it has one. -/
  | binding (desc : Option String)
  /-- A further prefix, with its name if it is named, and how many bindings
  under it the walk can reach. -/
  | prefix (name : Option String) (count : Nat)
  deriving DecidableEq, Repr

/-- A key that can follow the pending prefix, for the key hints: the key as
a key string names it, and what it leads to. It is scheme-neutral: what the
key is bound to is the scheme's and is not here. -/
structure KeyHint where
  /-- The key, as a key string names it (`Key.notation`). -/
  key : String
  /-- What it leads to. -/
  leads : KeyHint.Leads
  deriving DecidableEq, Repr

/-- Everything the display shows, as published after a command. -/
structure Scene where
  /-- The frame's size. -/
  size : Size
  /-- The views, in the order they are drawn. -/
  views : Array View
  /-- The dividers between the tiled views, drawn before every view, so a
  float over one covers it. None in a scene no command loop made. -/
  dividers : Array Divider := #[]
  /-- The view that has the keyboard focus, if one has. -/
  focused : Option ViewId
  /-- The echo area's text. -/
  echo : String
  /-- How far the echo is inset from the frame's left and right edges, in
  points, when layout draws it in the bottom row (`EditorState.bottomInset`):
  at least the window's corner clearance. -/
  echoPadding : Nat := 0
  /-- The pending key prefix, as Lean renders it; empty when there is
  none. The selected window's status line draws it
  (`ModeLine.pendingKeys`). -/
  pending : String
  /-- The key hints shown: the keys that can follow the pending prefix, in
  the input scheme's order (`InputScheme.continuations`), once the key hint
  delay has passed; none before it, and none when no keymap prefix is
  pending. They are drawn by the completion display chosen for the
  category `key`, as the candidate list's view (`Loop.keyHinted`). A
  Lean-only readout: it does not cross to the Rust scene. -/
  keyHints : Array KeyHint := #[]
  /-- The text an input method is composing in the focused view, if it is
  composing. -/
  preedit : Option String
  /-- The window's title: the selected buffer's name (`EditorState.title`).
  It is empty only in a scene no command loop made. -/
  title : String := ""
  /-- The application's menu bar, with its key equivalents filled from the
  registry's bindings as they were at the step that published it
  (`Loop.menu`, `Editor/Menu.lean`); `none` in a scene no command loop of
  a host with a menu made, which leaves the menu bar as it was. -/
  menu : Option Menu := none
  deriving DecidableEq, Repr

end Editor
