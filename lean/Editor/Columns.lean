import Editor.Display

/-!
# Columns at align-to stops

The arithmetic of a table of text cells laid out in columns at align-to
stops (`AlignStop`, `Editor/Scene.lean`): from each cell's measured width
to each column's x, and from rows of cells to the text, the stops and the
decorations a generated buffer is written with (`BufferId.setStops`,
`BufferId.setSpans`). A generator (a table, a list, a picker) computes its
columns here, so every one of them lines up by one rule.

- **A column starts past the widest cell of every column before it.**
  Column 0 is at 0, and column `j` at the sum, over the columns before it,
  of each one's widest cell and `gap` (`starts`). Widths are in whole
  points, as `Display.measure` answers them and as a stop's x is.
- **A row is its cells joined by a separator** (a space by default), and
  the rows are joined by line feeds. Each cell after a row's first has a
  stop at its first byte, at its column's x (`lay`); the first needs none,
  since a row starts at 0.
- **The separator is drawn in the gap.** Layout gives the gap before a
  stop to the character before it (`crates/editor-layout/src/align.rs`), so
  the separator is as wide as the gap, and the gap should be at least the
  separator's width: `measured` takes the wider of `gap` and the
  separator's measured width, so a cell is never pushed past its column.
- **What fits is layout's.** A stop past the view's width breaks the row
  before its cell, and a cell longer than the room after its stop wraps
  under it: a generator that wants every row on one visual line keeps its
  columns narrower than the view.

The model of this arithmetic is the display model's (`Display/Model.lean`),
whose measure is cells times their advance; it is checked there by
`ModelTest.columnsChecks`.
-/

namespace Editor.Columns

/-- The x of each column of a table whose cells, row by row, are `widths`
wide, in whole points, with `gap` points between a column's widest cell and
the next column: 0 for column 0, and each later column past the widest cell
of the column before it and the gap. A row shorter than another has no cell
in its last columns, which count as none wide. -/
def starts (widths : Array (Array Nat)) (gap : Nat) : Array Nat :=
  let columns := widths.foldl (fun count row => max count row.size) 0
  let widest (column : Nat) : Nat := widths.foldl (fun most row => max most (row[column]?.getD 0)) 0
  ((List.range columns).foldl (fun (xs, x) column => (xs.push x, x + widest column + gap))
      (#[], 0)).1

/-- The text of `rows` of cells, each row its cells joined by `separator`
and the rows joined by line feeds, and the byte offset of each cell's first
byte in it, row by row. -/
def placed (rows : Array (Array String)) (separator : String := " ") : String × Array (Array Nat) :=
  let (text, offsets, _) :=
    rows.foldl
      (fun (text, offsets, first) row =>
        let text := if first then text else text ++ "\n"
        let (text, cells) :=
          row.foldl
            (fun (text, cells) cell =>
              let text := if cells.isEmpty then text else text ++ separator
              (text ++ cell, cells.push text.utf8ByteSize))
            (text, #[])
        (text, offsets.push cells, false))
      ("", #[], true)
  (text, offsets)

/-- The text of `rows` of cells laid out in columns at `starts` (`placed`),
and a stop at the first byte of each cell after a row's first, at its
column's x. A cell of a column `starts` has no x for has no stop. -/
def lay (rows : Array (Array String)) (starts : Array Nat) (separator : String := " ") :
    String × Array AlignStop :=
  let (text, offsets) := placed rows separator
  let stops :=
    offsets.foldl
      (fun stops cells =>
        (cells.zipIdx.filterMap fun (offset, column) =>
              if column == 0 then none else (starts[column]?.map fun x => { offset, x })).foldl
          Array.push stops)
      #[]
  (text, stops)

/-- The text, the stops and the decorations of `rows` of cells, each in its
face over the default face when it names one, laid out in columns: each
cell measured in its face (`Display.measure`), each column past the widest
cell of the one before it and the wider of `gap` and `separator`'s width
(`starts`, `lay`), and a decoration over each cell that names a face. -/
def measured (rows : Array (Array (String × Option FaceName))) (gap : Nat)
    (separator : String := " ") : DisplayM (String × Array AlignStop × Array Decoration) := do
  let width (cell : String × Option FaceName) : DisplayM Nat :=
    match cell.2 with
    | some face => Display.widthIn face cell.1
    | none => Display.measure { text := cell.1 }
  let widths ← rows.mapM (·.mapM width)
  let gap := max gap (← Display.measure { text := separator })
  let texts := rows.map (·.map (·.1))
  let (text, stops) := lay texts (starts widths gap) separator
  let (_, offsets) := placed texts separator
  let decorations :=
    (rows.zip offsets).foldl
      (fun decorations (row, cells) =>
        (row.zip cells).foldl
          (fun decorations ((cell, face), offset) =>
            match face with
            | some face =>
              decorations.push { start := offset, stop := offset + cell.utf8ByteSize, face }
            | none => decorations)
          decorations)
      #[]
  return (text, stops, decorations)

end Editor.Columns
