import Editor.State

/-!
# The mode line

What a window's status row says: segments, each a function from what the
window shows to status fields, listed for the row's left and right sides.
A segment is registered by name, by owner, as commands, modes and themes
are (`Editor/Config/Registry.lean`, "Segments"), and `setup` lists the
segment names for each side (`modeLine`, `Editor/Setup.lean`). The command
loop asks for a window's fields (`Loop.statusOf`, `Editor/Loop.lean`) with
the context of the window (`ModeLine.Context`).

The style is the segmented one of lualine.nvim and doom-modeline: no
separator glyph, so nothing depends on a patched font. Segments are told
apart by their padding and the background of their faces. Where the fields
go across the row, and what is cut when both sides do not fit, is layout's
(`crates/editor-layout/src/frame.rs`, "The mode line").

## The shipped segments

In the default order (`ModeLine.Order.standard`):

| Side | Segment | Field | Face |
|---|---|---|---|
| Left | `state` | The scheme's reported fields, the badge (`NORMAL`), when the window is selected | the scheme's (`mode-line.state.<state>` under the Vim scheme) |
| Left | `buffer` | The buffer's name | `mode-line.buffer` |
| Left | `modified` | `●` while the buffer is modified | `mode-line.modified` |
| Left | `changed` | `[changed on disk]` while a check has found the buffer's file changed on disk, or gone (`Editor/Loop.lean`, "Files that changed on disk") | `mode-line.changed` |
| Left | `directory` | The opened path's parent, as written | `mode-line.secondary` |
| Right | `major-mode` | The buffer's major mode | `mode-line.secondary` |
| Right | `line-column` | `row:column` of the cursor, each from 1, the column in the text's cells (`ColumnUnit.cells`) | `mode-line.secondary` |
| Right | `position` | `All`, `Top`, `Bot` or a whole percentage | `mode-line.secondary` |

A segment that has nothing to say gives no field: `directory` for a buffer
with no file, or whose path's parent is absent, empty or `.`;
`major-mode` for a buffer with none, which at present is every buffer
opened from a file, since opening a file sets no major mode; `line-column`
and `position` for a window whose cursor could not be read; `modified` for
a buffer that is not modified; `changed` for a buffer whose file no check
has found changed. Buffers may be read-only (`Buffer.readOnly`), but the
mode line has no read-only mark yet: task `mode-line-read-only-mark` adds a
segment for it.

**The column is the text's cells**, as the cursor's other readers count
it: a wide character is two and a tab one. So it is Vim's `%l:%v` on a line
with no tab, and after a tab it is less than Vim's screen column, which
counts the tab's spaces: the text port knows no tab stops, which are
layout's (`crates/editor-layout/src/tabs.rs`). The `tests/headless/column`
fixture shows `1:3` after `a<Tab>`, where Vim shows `1:9`.

**The position is counted from the cursor's row** (lualine's `progress`),
not from the rows the window shows as Vim's ruler and Emacs's `%p` are: a
segment sees what the window shows, not layout's rows. It is `All` in a
buffer of one row or none, `Top` on the first row, `Bot` on the last row or
past it, and otherwise `⌊(row + 1) · 100 / lines⌋%`.

**Padding.** The badge has `ModeLine.badgePadding` (8 points) each side of
its text and every other shipped field `ModeLine.padding` (4). So two
neighbours' texts are 8 apart and the badge's text has 8 each side, the
owner's picked look of about 8 pixels a segment.

## Sides, selection and the unknown

`ModeLine.fields` gives each left segment's fields on the left and each
right segment's on the right: the side is the listing's, never the
segment's, so a segment can be listed on either side. For a window that is
not selected (`EditorState.selectedView`: the open prompt's asker while a
prompt is open, and otherwise the focused window, whether or not the frame
has the keyboard focus) the `state` segment gives no badge and every field
is in `ModeLine.inactiveFace` (`mode-line.inactive`), as the loop also
puts the row in it (`View.statusFace`).

A listing that names a segment nobody registered keeps the rest, in order,
and `ModeLine.resolve` names the unknown ones; a reload says so in the echo
area (`ModeLine.unknown`, `Editor/Config/Reload.lean`).

Pinned by `ModelTest.modeLineChecks`.
-/

namespace Editor

/-- What a window shows, as its mode line's segments read it. -/
structure ModeLine.Context where
  /-- The buffer it shows. -/
  buffer : Buffer
  /-- The fields the input scheme reports of it (`InputScheme.Report.status`),
  which the `state` segment draws as its badge. -/
  reported : Array StatusField := #[]
  /-- Its cursor's row and column, in cells: the head of the primary range of
  its selection. None when its selection marker did not answer. -/
  cursor : Option Point := none
  /-- How many rows its text has, less an empty last row after a final line
  break, which Vim and Evil never put a cursor on. -/
  lines : Nat := 0
  /-- Whether it is the selected window (`EditorState.selectedView`). -/
  selected : Bool := true

/-- A segment of the mode line: a name it is registered and listed by, and
the fields it gives for a window. -/
structure Segment where
  /-- Its name, such as `buffer`. -/
  name : String
  /-- Its fields for the window `context` describes; none when it has
  nothing to say. Their sides are the listing's (`ModeLine.fields`). -/
  fields : ModeLine.Context → Array StatusField

/-- A mode line: the segments of each side, in order. -/
structure ModeLine where
  /-- The left side's, from the row's start. -/
  left : Array Segment := #[]
  /-- The right side's, ending at the row's end. -/
  right : Array Segment := #[]

/-- A listing of a mode line by segment names, as config gives it
(`modeLine`, `Editor/Setup.lean`). -/
structure ModeLine.Order where
  /-- The left side's names, in order. -/
  left : Array String
  /-- The right side's names, in order. -/
  right : Array String
  deriving DecidableEq, Repr

namespace ModeLine

/-- The face every field of a window that is not selected is drawn in, and
the face of its row. -/
def inactiveFace : FaceName :=
  ⟨"mode-line.inactive"⟩

/-- The face of the buffer's name. -/
def bufferFace : FaceName :=
  ⟨"mode-line.buffer"⟩

/-- The face of the modified mark. -/
def modifiedFace : FaceName :=
  ⟨"mode-line.modified"⟩

/-- The face of what recedes: the directory, the major mode, line:col and
the position. -/
def secondaryFace : FaceName :=
  ⟨"mode-line.secondary"⟩

/-- What the modified mark says. -/
def modifiedMark : String :=
  "●"

/-- The face of the mark that says the buffer's file changed on disk. -/
def changedFace : FaceName :=
  ⟨"mode-line.changed"⟩

/-- What the mark that says the buffer's file changed on disk says. -/
def changedMark : String :=
  "[changed on disk]"

/-- The padding of the badge, in points each side of its text. -/
def badgePadding : Nat :=
  8

/-- The padding of every shipped field but the badge, in points each side
of its text. -/
def padding : Nat :=
  4

/-- A field of `text` in `face` with the shipped padding. -/
def field (text : String) (face : FaceName) : StatusField :=
  { text, face, padding }

/-- The directory a path was opened in, as written: its parent, unless that
is absent, empty or `.`. -/
def directoryOf (path : System.FilePath) : Option String :=
  match path.parent with
  | some parent =>
    let written := parent.toString
    if written.isEmpty || written == "." then none else some written
  | none => none

/-- Where the cursor's row is in the buffer: `All` with one row or none,
`Top` on the first, `Bot` on the last or past it, and otherwise the row,
counted from 1, as a whole percentage of the rows. -/
def positionOf (row lines : Nat) : String :=
  if lines ≤ 1 then "All"
  else if row == 0 then "Top" else if row + 1 ≥ lines then "Bot" else s!"{(row + 1) * 100 / lines}%"

/-- The `state` segment: the scheme's reported fields, the badge, each with
`badgePadding`, while the window is selected; none for one that is not. -/
def state : Segment where
  name := "state"
  fields context :=
    if context.selected then context.reported.map ({ · with padding := badgePadding }) else #[]

/-- The `buffer` segment: the buffer's name. -/
def buffer : Segment where
  name := "buffer"
  fields context := #[field context.buffer.name bufferFace]

/-- The `modified` segment: the mark while the buffer is modified. -/
def modified : Segment where
  name := "modified"
  fields context := if context.buffer.isModified then #[field modifiedMark modifiedFace] else #[]

/-- The `changed` segment: the mark while a check has found the buffer's
file changed on disk, or gone (`FileInfo.changed`). -/
def changed : Segment where
  name := "changed"
  fields context :=
    if (context.buffer.file.bind (·.changed)).isSome then #[field changedMark changedFace] else #[]

/-- The `directory` segment: the directory the buffer's file was opened in,
as written (`directoryOf`). -/
def directory : Segment where
  name := "directory"
  fields context :=
    match context.buffer.file.bind (directoryOf ·.path) with
    | some written => #[field written secondaryFace]
    | none => #[]

/-- The `major-mode` segment: the buffer's major mode. -/
def majorMode : Segment where
  name := "major-mode"
  fields context :=
    match context.buffer.major with
    | some major => #[field major secondaryFace]
    | none => #[]

/-- The `line-column` segment: the cursor's row and column, each from 1. -/
def lineColumn : Segment where
  name := "line-column"
  fields context :=
    match context.cursor with
    | some point => #[field s!"{point.row + 1}:{point.column + 1}" secondaryFace]
    | none => #[]

/-- The `position` segment: where the cursor's row is in the buffer
(`positionOf`). -/
def position : Segment where
  name := "position"
  fields context :=
    match context.cursor with
    | some point => #[field (positionOf point.row context.lines) secondaryFace]
    | none => #[]

/-- The shipped segments, in the default order (`Order.standard`). -/
def shipped : Array Segment :=
  #[state, buffer, modified, changed, directory, majorMode, lineColumn, position]

/-- The default listing: the badge, the buffer's name, the modified mark,
the changed mark and the directory on the left; the major mode, line:col
and the position on the right. -/
def Order.standard : Order where
  left := #["state", "buffer", "modified", "changed", "directory"]
  right := #["major-mode", "line-column", "position"]

/-- The mode line `order` names, each name the segment `segment?` finds for
it, and the names it finds none for, in order, each once. Which segment a
name finds is the caller's rule: the registry's is its latest entry of the
name (`Config.Registry.segment?`). -/
def resolve (order : Order) (segment? : String → Option Segment) : ModeLine × Array String :=
  let side (names : Array String) := names.filterMap segment?
  let unknown :=
    (order.left ++ order.right).foldl
      (fun unknown name =>
        if (segment? name).isNone && !unknown.contains name then unknown.push name else unknown)
      #[]
  ({ left := side order.left, right := side order.right }, unknown)

/-- The shipped segment called `name`: each shipped segment has a name of
its own, so no entry of a name is later than another. -/
def shipped? (name : String) : Option Segment :=
  shipped.find? (·.name == name)

/-- The shipped mode line, in the default order. -/
def standard : ModeLine :=
  (resolve Order.standard shipped?).1

/-- What is said of a segment name a listing gives and nobody registered. -/
def unknown (name : String) : String :=
  s!"no segment is registered as `{name}`"

/-- The fields of `line` for the window `context` describes: each left
segment's fields on the left, then each right segment's on the right. For a
window that is not selected every field is in `inactiveFace`. -/
def fields (line : ModeLine) (context : Context) : Array StatusField :=
  let sided (side : StatusSide) (segments : Array Segment) : Array StatusField :=
    segments.flatMap fun segment => (segment.fields context).map ({ · with side })
  let all := sided .left line.left ++ sided .right line.right
  if context.selected then all else all.map ({ · with face := inactiveFace })

end ModeLine

end Editor
