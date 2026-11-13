import Editor.Display

/-!
# The display model

The pure model of the display interface (`Editor/Display.lean`): it records
every scene published to it, in order, and answers the queries by laying the
text of a snapshot out in fixed-size cells (`Display.Cells`). It is a model
for tests, not a copy of layout kept at run time: the editor asks the real
display every time.

It sees a snapshot's text through `texts`, which a test fills, and which the
command loop fills from the text model when it runs both ports together.

## The layout rule

- The text is split into lines at each line feed; a carriage return before
  a line feed is part of the break. Every other character, a carriage return
  alone included, is one cell `advance` pixels across.
- A row of a view `width` pixels wide holds `columns := max 1 (width /
  advance)` characters. A line of k characters takes `max 1 ⌈k / columns⌉`
  rows, wrapped at character boundaries; an empty line takes one empty row.
- A view `height` pixels tall shows `height / lineHeight` rows.
- A position at a wrap is the start of the later row. Only a line's last row
  holds the position at the line's end, before its break.

A refusal is `noSuchSnapshot` for a snapshot it has no text for, and
`badPosition` for an anchor or a position that is not a character boundary
within the text.
-/

namespace Editor

/-- The state of the display model. -/
structure DisplayModel where
  /-- The cells it lays text out in. -/
  cells : Display.Cells
  /-- The text of each snapshot it knows. -/
  texts : Array (SnapshotId × String) := #[]
  /-- The scenes published to it, oldest first. -/
  published : Array Scene := #[]

namespace DisplayModel

/-- The scenes published so far, oldest first. -/
def scenes (model : DisplayModel) : Array Scene :=
  model.published

/-- The text of `snapshot`, if the model knows it. -/
def text? (model : DisplayModel) (snapshot : SnapshotId) : Option String :=
  (model.texts.find? (·.1 == snapshot)).map (·.2)

/-- One visual row as the model lays it out. -/
structure Laid where
  /-- The row's byte range, without its line break. -/
  row : Display.Row
  /-- The byte offset of each of its characters, in order. -/
  chars : Array Nat
  /-- The offset the positions this row holds stop before: the next row's
  start, or, for the last row of the text, one past its end. -/
  upTo : Nat
  /-- Whether it is the last row of its line, the one row of a line that
  holds the position at the line's end. -/
  lastOfLine : Bool
  deriving Inhabited

/-- The lines of a text whose characters, from the byte offset `offset`, are
`chars`, added to `lines`: for each line, the offset of each of its
characters, the offset where they stop, and the offset after its line break
(its stop, for the last line). A carriage return before a line feed is part
of the break; any other character is one of the line's. -/
def splitLines :
    List Char → Nat → Array Nat → Array (Array Nat × Nat × Nat) → Array (Array Nat × Nat × Nat)
  | [], offset, line, lines => lines.push (line, offset, offset)
  | '\r' :: '\n' :: rest, offset, line, lines =>
    splitLines rest (offset + 2) #[] (lines.push (line, offset, offset + 2))
  | '\n' :: rest, offset, line, lines =>
    splitLines rest (offset + 1) #[] (lines.push (line, offset, offset + 1))
  | char :: rest, offset, line, lines =>
    splitLines rest (offset + char.utf8Size) (line.push offset) lines

/-- How many characters a row of a view `width` pixels wide holds: as many
whole cells as fit, and at least one. -/
def columns (cells : Display.Cells) (width : Nat) : Nat :=
  max 1 (width / cells.advance)

/-- The layout rule: `text` in rows of `columns` characters. A line of k
characters takes `max 1 ⌈k / columns⌉` rows, wrapped at character
boundaries; an empty line takes one empty row. -/
def layout (text : String) (columns : Nat) : Array Laid :=
  Id.run do
    let lines := splitLines text.toList 0 #[] #[]
    let mut laid := #[]
    for index in [0:lines.size] do
      let (chars, stop, after) := lines[index]!
      let lineUpTo := if index + 1 == lines.size then text.utf8ByteSize + 1 else after
      if chars.isEmpty then
        laid := laid.push { row := ⟨stop, stop⟩, chars, upTo := lineUpTo, lastOfLine := true }
      else
        let count := (chars.size + columns - 1) / columns
        for row in [0:count] do
          let first := row * columns
          let next := first + columns
          let last := row + 1 == count
          let rowStop := if last then stop else chars[next]!
          laid :=
            laid.push
              { row := ⟨chars[first]!, rowStop⟩, chars := chars.extract first next
                upTo := if last then lineUpTo else rowStop, lastOfLine := last }
    return laid

/-- Whether `offset` is a position of `text`: a character boundary within
it, its end included. -/
def isPosition (text : String) (offset : Nat) : Bool :=
  offset == text.utf8ByteSize ||
    (text.toList.foldl (fun (here, found) char => (here + char.utf8Size, found || here == offset))
        (0, false)).2

/-- The index of the row of `laid` that holds the position `offset`. -/
def rowOf (laid : Array Laid) (offset : Nat) : Nat :=
  (laid.findIdx? fun row => row.row.start <= offset && offset < row.upTo).getD 0

/-- The text of `snapshot`, laid out for a view `width` pixels wide, with the
position `offset` checked: refused with `noSuchSnapshot` or `badPosition`. -/
def laidOut (model : DisplayModel) (snapshot : SnapshotId) (width offset : Nat) :
    Except DisplayError (Array Laid) := do
  let some text := model.text? snapshot | throw .noSuchSnapshot
  unless isPosition text offset do
    throw .badPosition
  return layout text (columns model.cells width)

/-- The rows a view shows: from the row that holds the anchor, as many as
whole rows fit its height, fewer at the end of the text. -/
def rows (model : DisplayModel) (query : Display.RowsQuery) :
    Except DisplayError (Array Display.Row) := do
  let laid ← model.laidOut query.snapshot query.width query.anchor
  let first := rowOf laid query.anchor
  return (laid.extract first (first + query.height / model.cells.lineHeight)).map (·.row)

/-- Where a position goes: to the row `query.lines` from the one that holds
it, kept within the first and the last row, at the column the goal aims for
(`goal / advance`, or the position's own column when there is no goal), kept
within that row. Only a line's last row admits the column at its end. The
goal passed back is the one aimed for. -/
def move (model : DisplayModel) (query : Display.MoveQuery) : Except DisplayError Display.Moved :=
  do
  let laid ← model.laidOut query.snapshot query.width query.position
  let here := rowOf laid query.position
  let column := (laid[here]!.chars.filter (· < query.position)).size
  let goal := query.goal.getD (column * model.cells.advance)
  let target := (max 0 (min (here + query.lines) (laid.size - 1 : Int))).toNat
  let row := laid[target]!
  let last := if row.lastOfLine then row.chars.size else row.chars.size - 1
  let wanted := min (goal / model.cells.advance) last
  return { position := row.chars[wanted]?.getD row.row.stop, goal }

/-- Answers `request`: a scene is recorded, and a query is answered from the
model as it is. -/
def handle : (request : DisplayRequest) → DisplayModel → request.Reply × DisplayModel
  | .publish scene, model => ((), { model with published := model.published.push scene })
  | .rows query, model => (model.rows query, model)
  | .move query, model => (model.move query, model)

end DisplayModel

/-- Runs a display program against the model `model`: its result, or the
refusal it failed with, and the model after its last request. -/
def DisplayM.runModel {α : Type} (program : DisplayM α) (model : DisplayModel) :
    Except DisplayError α × DisplayModel :=
  Program.run (port := displayPort) DisplayModel.handle program.run model

end Editor
