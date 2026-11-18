import Editor.Display

/-!
# The display model

The pure model of the display interface (`Editor/Display.lean`): it records
every scene published to it, in order, and answers the queries by laying the
text of a snapshot out in fixed-size cells (`Display.Cells`). It is a model
for tests, not a copy of layout kept at run time: an editor with a window
asks the real display every time. The one exception is a host with no
window, which has no layout to ask: there the recorder
(`Editor/Display/Recorder.lean`) answers each query with this module's rule
(`DisplayModel.rows`, `DisplayModel.move`, `DisplayModel.spot`), over a
model that holds the one snapshot the query names.

It sees a snapshot's text through `texts`, which a test fills, and which the
command loop fills from the text model when it runs both ports together.

## The layout rule

- The text is split into lines at each line feed; a carriage return before
  a line feed is part of the break. A cell is `advance` pixels across.
- A tab takes the cells up to the next multiple of 8 (`tabStop`), counted
  from its line's start. A wide character takes two cells; which are wide is
  the model's own list of blocks (`isWide`), not Unicode's table, and an
  emoji is not in it. Every other character, a carriage return alone
  included, is one cell.
- A row of a view `width` pixels wide holds `columns := max 1 (width /
  advance)` cells. A character's first cell is counted from its line's
  start, and the character is of the row that cell is in (`cell / columns`),
  whole: a line of k one-cell characters takes `max 1 ⌈k / columns⌉` rows,
  wrapped at character boundaries. An empty line takes one empty row. What a
  tab or a wide character does at a wrap is this model's own: the contract
  says nothing of it.
- A view `height` pixels tall shows `height / lineHeight` rows.
- A block (`Editor/Display.lean`, "Blocks") takes the rows its text is
  laid out in by this rule at the view's width, above the first row of the
  line that holds its `before` (`lineOf`), and its rows count among the
  rows a view shows: a line's blocks are shown with its first row or not at
  all, and the first row shown has its blocks only when they fit with it.
  A spot's `k` counts the block rows shown above its row.
- A query's padding is in points, and the model lays out at scale 1, where
  a point is a pixel: a view `width` wide with the padding `across` and a
  gutter `gutter` wide lays out as one `width - 2 * across - gutter` wide,
  and one `height` tall with the padding `down` and `top` as one
  `height - 2 * down - top` tall, each at 0 at least. A spot's x has
  `across + gutter` added back.
- A position at a wrap is the start of the later row. Only a line's last row
  holds the position at the line's end, before its break.
- The x of a position is its character's first cell in its row times
  `advance`. Its spot is that x and the top of its row, `k * lineHeight`
  for the `k`-th row shown, each with the padding added back, and a row's
  height. A move aims for the cell `goal / advance` of its row and goes
  to the character that cell is in.

This is arithmetic of tab stops and widths, and it is here because this is
the fake of layout. The editor above the port has none of it: it passes an
x back as the display gave it.

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
  /-- What it was asked of the window, oldest first. -/
  asked : Array Display.FrameRequest := #[]

namespace DisplayModel

/-- The scenes published so far, oldest first. -/
def scenes (model : DisplayModel) : Array Scene :=
  model.published

/-- The text of `snapshot`, if the model knows it. -/
def text? (model : DisplayModel) (snapshot : SnapshotId) : Option String :=
  (model.texts.find? (·.1 == snapshot)).map (·.2)

/-- The cells a tab stop is from the one before it. -/
def tabStop : Nat :=
  8

/-- Whether `char` is two cells across: the model's own list of blocks of
East Asian characters, not Unicode's table of widths. -/
def isWide (char : Char) : Bool :=
  let code := char.toNat
  (0x1100 ≤ code && code ≤ 0x115F) || (0x2E80 ≤ code && code ≤ 0xA4CF) ||
    (0xAC00 ≤ code && code ≤ 0xD7A3) ||
    (0xF900 ≤ code && code ≤ 0xFAFF) ||
    (0xFE30 ≤ code && code ≤ 0xFE4F) ||
    (0xFF00 ≤ code && code ≤ 0xFF60) ||
    (0xFFE0 ≤ code && code ≤ 0xFFE6)

/-- How many cells `char` takes when its first is `cell` cells from its
line's start: a tab up to the next tab stop, a wide character two, any other
one. -/
def span (char : Char) (cell : Nat) : Nat :=
  if char == '\t' then tabStop - cell % tabStop else if isWide char then 2 else 1

/-- A character of a line as the model places it. -/
structure Placed where
  /-- Its byte offset in the text. -/
  offset : Nat
  /-- Its first cell, counted from its line's start. -/
  cell : Nat
  /-- How many cells it takes. -/
  span : Nat
  deriving Inhabited

/-- One visual row as the model lays it out. -/
structure Laid where
  /-- The row's byte range, without its line break. -/
  row : Display.Row
  /-- The byte offset of each of its characters, in order. -/
  chars : Array Nat
  /-- The first cell of each of its characters, counted from the row's first
  cell. -/
  firsts : Array Nat
  /-- The cells its characters reach to, counted from the row's first cell:
  where the position at its end is. -/
  reach : Nat
  /-- The offset the positions this row holds stop before: the next row's
  start, or, for the last row of the text, one past its end. -/
  upTo : Nat
  /-- Whether it is the last row of its line, the one row of a line that
  holds the position at the line's end. -/
  lastOfLine : Bool
  /-- The index of its line in the text: the line feeds before it. -/
  line : Nat := 0
  /-- Whether it is the first row of its line, the one row of a line that
  the line's blocks are drawn above. -/
  firstOfLine : Bool := true
  deriving Inhabited

/-- The lines of a text whose characters, from the byte offset `offset`, are
`chars`, added to `lines`, the next character's first cell being `cell`: for
each line, its characters as placed, the offset where they stop, and the
offset after its line break (its stop, for the last line). A carriage return
before a line feed is part of the break; any other character is one of the
line's. -/
def splitLines :
    List Char →
      Nat → Nat → Array Placed → Array (Array Placed × Nat × Nat) → Array (Array Placed × Nat × Nat)
  | [], offset, _, line, lines => lines.push (line, offset, offset)
  | '\r' :: '\n' :: rest, offset, _, line, lines =>
    splitLines rest (offset + 2) 0 #[] (lines.push (line, offset, offset + 2))
  | '\n' :: rest, offset, _, line, lines =>
    splitLines rest (offset + 1) 0 #[] (lines.push (line, offset, offset + 1))
  | char :: rest, offset, cell, line, lines =>
    let width := span char cell
    splitLines rest (offset + char.utf8Size) (cell + width)
      (line.push { offset, cell, span := width }) lines

/-- How many cells a row of a view `width` pixels wide holds: as many whole
cells as fit, and at least one. -/
def columns (cells : Display.Cells) (width : Nat) : Nat :=
  max 1 (width / cells.advance)

/-- The rows of one line whose characters, from the index `first`, are those
of `chars`, added to `laid`: a character is of the row its first cell is in
(`cell / columns`). `stop` is the offset where the line's characters stop
and `lineUpTo` the offset the positions of its last row stop before. -/
def layoutLine (chars : Array Placed) (columns stop lineUpTo first : Nat) (laid : Array Laid) :
    Array Laid :=
  if inLine : first < chars.size then
    let row := chars[first].cell / columns
    let held := (chars.extract first chars.size).takeWhile (·.cell / columns == row)
    let next := first + max 1 held.size
    let last := chars.size ≤ next
    let rowStop := if last then stop else chars[next]!.offset
    let reach := (held.back?.map fun back => back.cell + back.span - row * columns).getD 0
    layoutLine chars columns stop lineUpTo next
      (laid.push
        { row := ⟨chars[first].offset, rowStop⟩, chars := held.map (·.offset)
          firsts := held.map (·.cell - row * columns), reach
          upTo := if last then lineUpTo else rowStop, lastOfLine := last })
  else laid
termination_by chars.size - first
decreasing_by omega

/-- The layout rule: `text` in rows of `columns` cells. A character is of the
row its first cell is in; an empty line takes one empty row. -/
def layout (text : String) (columns : Nat) : Array Laid :=
  Id.run do
    let lines := splitLines text.toList 0 0 #[] #[]
    let mut laid := #[]
    for index in [0:lines.size] do
      let (chars, stop, after) := lines[index]!
      let lineUpTo := if index + 1 == lines.size then text.utf8ByteSize + 1 else after
      let first := laid.size
      if chars.isEmpty then
        laid :=
          laid.push
            { row := ⟨stop, stop⟩, chars := #[], firsts := #[], reach := 0, upTo := lineUpTo
              lastOfLine := true }
      else
        laid := layoutLine chars columns stop lineUpTo 0 laid
      for place in [first:laid.size] do
        laid :=
          laid.modify place
            ({ · with
              line := index, firstOfLine := place == first })
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

/-- The line of `text` that holds the byte offset `offset`: the line feeds
before it, an offset past the end being the end. An offset inside a
character is on that character's line, as the boundary before it is. -/
def lineOf (text : String) (offset : Nat) : Nat :=
  (text.toUTF8.extract 0 (min offset text.utf8ByteSize)).foldl
    (fun lines byte => if byte == 10 then lines + 1 else lines) 0

/-- How many rows of a view `columns` cells wide the blocks of `blocks`
before the row `row` of a text laid out as `text` take: none unless it is
its line's first row, and otherwise, for each block whose `before` is on
its line, the rows its text wraps to. -/
def blockRows (text : String) (columns : Nat) (blocks : Array Block) (row : Laid) : Nat :=
  if !row.firstOfLine then 0
  else
    blocks.foldl
      (fun rows block =>
        if lineOf text block.before == row.line then rows + (layout block.text columns).size
        else rows)
      0

/-- The rows of `laid` a view `capacity` rows tall shows from the row
`first`, each with the block rows shown above it (`above` gives a row's
blocks' rows): a row's blocks with it or not at all, the walk stopping at
the first that does not fit, but the first row's left out when they do not
fit with it (`Editor/Display.lean`, "Blocks"). -/
def shownFrom (laid : Array Laid) (first capacity : Nat) (above : Laid → Nat) : Array (Nat × Nat) :=
  Id.run do
    let mut shown := #[]
    let mut used := 0
    for index in [first:laid.size] do
      let blocks := above laid[index]!
      if used + 1 + blocks ≤ capacity then
        shown := shown.push (index, blocks)
        used := used + 1 + blocks
      else if index == first && 1 ≤ capacity then
        shown := shown.push (index, 0)
        used := 1
      else
        break
    return shown

/-- The rows a view shows, each with the block rows above it: from the row
that holds the anchor, as many as fit its height with its blocks, fewer at
the end of the text; the view less its padding, as points at scale 1. -/
def shownRows (model : DisplayModel) (snapshot : SnapshotId) (width height anchor : Nat)
    (blocks : Array Block) : Except DisplayError (Array Laid × Array (Nat × Nat)) := do
  let laid ← model.laidOut snapshot width anchor
  let text := (model.text? snapshot).getD ""
  let columns := columns model.cells width
  let shown :=
    shownFrom laid (rowOf laid anchor) (height / model.cells.lineHeight)
      (blockRows text columns blocks)
  return (laid, shown)

/-- The rows a view shows: from the row that holds the anchor, as many as
whole rows fit its height, its blocks' rows counted among them, fewer at the
end of the text; the view less its padding, as points at scale 1. -/
def rows (model : DisplayModel) (query : Display.RowsQuery) :
    Except DisplayError (Array Display.Row) := do
  let width := query.width - 2 * query.padding.across - query.padding.gutter
  let height := query.height - 2 * query.padding.down - query.padding.top
  let (laid, shown) ← model.shownRows query.snapshot width height query.anchor query.blocks
  return shown.map fun (index, _) => laid[index]!.row

/-- Where a position goes: to the row `query.lines` from the one that holds
it, kept within the first and the last row, at the cell the goal aims for
(`goal / advance`, or the position's own first cell when there is no goal):
the character that cell is in. Past the row's last character it is the
row's end on a line's last row and the row's last character on any other.
The goal passed back is the one aimed for. -/
def move (model : DisplayModel) (query : Display.MoveQuery) : Except DisplayError Display.Moved :=
  do
  let laid ←
    model.laidOut query.snapshot (query.width - 2 * query.across - query.gutter) query.position
  let here := rowOf laid query.position
  let held := laid[here]!
  let own := held.firsts[(held.chars.filter (· < query.position)).size]?.getD held.reach
  let goal := query.goal.getD (own * model.cells.advance)
  let target := (max 0 (min (here + query.lines) (laid.size - 1 : Int))).toNat
  let row := laid[target]!
  let aimed := goal / model.cells.advance
  let position :=
    if aimed < row.reach then row.chars[(row.firsts.filter (· ≤ aimed)).size - 1]?.getD row.row.stop
    else if row.lastOfLine then row.row.stop else row.chars.back?.getD row.row.stop
  return { position, goal }

/-- Where a position is drawn in a view: on its row, when that is among the
rows `rows` shows, at `y = down + top + k * lineHeight`, where `k` is the
rows shown above it, block rows included, `lineHeight` tall, and at `x =
across + gutter + cell * advance`, where `cell` is the position's first cell in its
row as a move counts it; none when the rows shown do not hold it. -/
def spot (model : DisplayModel) (query : Display.SpotQuery) :
    Except DisplayError (Option Display.Spot) := do
  let width := query.width - 2 * query.padding.across - query.padding.gutter
  let height := query.height - 2 * query.padding.down - query.padding.top
  let (laid, shown) ← model.shownRows query.snapshot width height query.anchor query.blocks
  discard <| model.laidOut query.snapshot width query.position
  let here := rowOf laid query.position
  let some place := shown.findIdx? (·.1 == here) | return none
  let above := (shown.extract 0 place).foldl (fun rows (_, blocks) => rows + 1 + blocks) 0
  let rowsDown := above + shown[place]!.2
  let held := laid[here]!
  let cell := held.firsts[(held.chars.filter (· < query.position)).size]?.getD held.reach
  return some
      { x := query.padding.across + query.padding.gutter + cell * model.cells.advance
        y := query.padding.down + query.padding.top + rowsDown * model.cells.lineHeight
        height := model.cells.lineHeight }

/-- Answers `request`: a scene is recorded, a request of the window is
recorded and answers nothing, and a query is answered from the model as it
is. -/
def handle : (request : DisplayRequest) → DisplayModel → request.Reply × DisplayModel
  | .publish scene, model => ((), { model with published := model.published.push scene })
  | .rows query, model => (model.rows query, model)
  | .move query, model => (model.move query, model)
  | .spot query, model => (model.spot query, model)
  | .heights, model => (model.cells.heights, model)
  | .frame request, model => ((), { model with asked := model.asked.push request })

end DisplayModel

/-- Runs a display program against the model `model`: its result, or the
refusal it failed with, and the model after its last request. -/
def DisplayM.runModel {α : Type} (program : DisplayM α) (model : DisplayModel) :
    Except DisplayError α × DisplayModel :=
  Program.run (port := displayPort) DisplayModel.handle program.run model

end Editor
