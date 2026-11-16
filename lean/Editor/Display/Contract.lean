import Editor.Display

/-!
# The contract of the display interface

What every implementation of the display interface's two queries
(`Editor/Display.lean`) answers, as one list of properties. The model
(`Editor/Display/Model.lean`) is held to it by `model-test`, under
`lake test`. The display pipeline's real binding (its phase 1) is to be held
to the same list. This module imports only the port, so the contract never
depends on the model.

## How a runner runs a property

A property names the texts it needs (`Property.texts`) and is handed the
snapshots of them, in that order. Its `holds` is a program over the display
port, run from a display that knows those snapshots:

- the model is made with those texts as its `texts`, with the snapshots
  `0`, `1`, `2` and so on;
- the real binding makes a document and a snapshot of each text in the
  library's table, and runs `holds` with `Program.runM` against its handler
  over its fake shaper, whose every glyph has the advance `cells.advance`
  and whose every line the height `cells.lineHeight`.

`properties cells` is the list at one cell size; a runner runs it at each
size it is given. Widths and heights are in pixels, as whole cells and whole
rows of `cells`. A query's padding is in points, which every runner lays out
at scale 1, where a point is a pixel: the property of the padding holds the
model, the recorder and the real binding to one rule, that a padded
question is the unpadded question of the area less the padding: twice
`across` off the width, and twice `down` and once `top` off the height. At another
scale the real binding takes the points off as that many times the scale,
which `editor-layout`'s and `editor-ffi`'s tests pin.

## What the properties leave open

A text in a property that wraps has no space in it, so it wraps at the same
place whether lines break at characters or at words: the wrapping policy
stays the display pipeline's. A carriage return before a line feed is part
of the break.

A character of a property is one cell wide, but for a tab, which reaches to
the next multiple of eight cells from its line's start: the default tab
width, named here until a view has a setting for it. No property has a
character that a font draws wide. How wide a character is drawn is the
shaper's, and the fake shaper a runner uses makes every glyph one cell, so
what is wide, and how wide, is left open. No property has a tab or a wide
character in a line that wraps either.

## What a caller that wants a column of a line relies on

Two properties are for a caller that asks about a line and not about a view
(evil's `j` and `k`), with the property of the tab, whose x such a caller
aims across:

- a move of no lines that is given a goal goes to that x of its row, so the
  move query also answers "which position is at this x of this row", and
  the goal a move with no goal passes back is the x of its position;
- a width no machine word holds wraps no line, so at that width a row is a
  line of the text and an x is counted from the line's start.
-/

namespace Editor.DisplayContract

/-- One property of the display interface's queries. -/
structure Property where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- The texts the property needs, made into snapshots before it runs. -/
  texts : Array String
  /-- Observes the property, given the snapshots of `texts` in order;
  `true` when it holds. A program that is refused has not held. -/
  holds : Array SnapshotId → DisplayM Bool

/-- Runs `program` and returns whether it was refused with `error`. -/
def refusedWith {α : Type} (error : DisplayError) (program : DisplayM α) : DisplayM Bool :=
  try
    discard program
    return false
  catch refusal =>
    return refusal == error

/-- The snapshot at `index` of those a property was handed, or one past them
when it was not handed that many. -/
def nth (snapshots : Array SnapshotId) (index : Nat) : SnapshotId :=
  snapshots[index]?.getD ⟨snapshots.size⟩

/-- A snapshot no runner was asked to make: past every one handed in. -/
def unknown (snapshots : Array SnapshotId) : SnapshotId :=
  ⟨(snapshots.map (·.index)).foldl max 0 + 1⟩

/-- Moves `position` of `snapshot` `lines` rows down in a view `columns`
cells wide, then the same number of rows back up with the goal the first
move passed back, and returns whether it is back where it started. -/
def downAndUp (cells : Display.Cells) (snapshot : SnapshotId) (columns position : Nat)
    (lines : Int) : DisplayM Bool := do
  let width := columns * cells.advance
  let down ← Display.linesFrom { snapshot, width, position, lines, goal := none }
  let up ←
    Display.linesFrom
        { snapshot, width, position := down.position, lines := -lines, goal := some down.goal }
  return up.position == position && down.position != position

/-- The properties of the queries at the cell size `cells`. -/
def properties (cells : Display.Cells) : List Property :=
  let rows (snapshot : SnapshotId) (columns rows anchor : Nat) : DisplayM (Array Display.Row) :=
    Display.rowsShown
      { snapshot, width := columns * cells.advance, height := rows * cells.lineHeight, anchor }
  [{  name :=
        "a view r rows tall over lines no longer than its width shows r lines from its anchor",
      texts := #["ab\ncd\nef\ngh"]
      holds := fun snapshots => do
        return (← rows (nth snapshots 0) 4 3 3) == #[⟨3, 5⟩, ⟨6, 8⟩, ⟨9, 11⟩] },
    { name := "a line twice the view's width takes exactly two rows, split at the width"
      texts := #["abcdefgh\nij"]
      holds := fun snapshots => do
        return (← rows (nth snapshots 0) 4 3 0) == #[⟨0, 4⟩, ⟨4, 8⟩, ⟨9, 11⟩] },
    { name := "the rows stop at the end of the text"
      texts := #["ab\ncd"]
      holds := fun snapshots => do
        return (← rows (nth snapshots 0) 4 10 0) == #[⟨0, 2⟩, ⟨3, 5⟩] },
    { name := "an anchor in the middle of a row starts at that row"
      texts := #["abcdefgh\nij"]
      holds := fun snapshots => do
        return (← rows (nth snapshots 0) 4 2 6) == #[⟨4, 8⟩, ⟨9, 11⟩] },
    { name := "an empty text shows one empty row, and a trailing line feed one empty row after it"
      texts := #["", "ab\n"]
      holds := fun snapshots => do
        return (← rows (nth snapshots 0) 4 3 0) == #[⟨0, 0⟩] &&
            (← rows (nth snapshots 1) 4 3 0) == #[⟨0, 2⟩, ⟨3, 3⟩] },
    { name :=
        "a character of several bytes takes one cell, and the rows are its byte ranges: é is two bytes and 😀 four"
      texts := #["é😀ab"]
      holds := fun snapshots => do
        return (← rows (nth snapshots 0) 2 3 0) == #[⟨0, 6⟩, ⟨6, 8⟩] &&
            (← rows (nth snapshots 0) 2 3 2) == #[⟨0, 6⟩, ⟨6, 8⟩] },
    { name :=
        "n visual lines down and then n up, with the goal passed back, is the start: over lines that do not wrap"
      texts := #["abc\ndef\nghi"]
      holds := fun snapshots => downAndUp cells (nth snapshots 0) 10 1 2 },
    { name := "n visual lines down and then n up is the start across a wrapped line"
      texts := #["abcdef\nab\nabcdefghij\nxyz"]
      holds := fun snapshots => do
        return (← downAndUp cells (nth snapshots 0) 4 8 3) &&
            (← downAndUp cells (nth snapshots 0) 4 15 (-2)) },
    { name :=
        "n visual lines down and then n up is the start across a shorter line, when the goal is passed back"
      texts := #["abcdef\nab\nabcdefghij\nxyz"]
      holds := fun snapshots => do
        return (← downAndUp cells (nth snapshots 0) 4 3 2) &&
            (← downAndUp cells (nth snapshots 0) 4 13 (-2)) },
    { name := "a move of no lines leaves the position where it is"
      texts := #["abcdef\nab\nabcdefghij\nxyz"]
      holds := fun snapshots => do
        let moved ←
          Display.linesFrom
              { snapshot := nth snapshots 0, width := 4 * cells.advance, position := 15, lines := 0
                goal := none }
        return moved.position == 15 },
    { name :=
        "a move past the first row or past the last stops on that row, at the column aimed for"
      texts := #["abcdef\nab\nabcdefghij\nxyz"]
      holds := fun snapshots => do
        let move (position : Nat) (lines : Int) : DisplayM Nat := do
          let moved ←
            Display.linesFrom
                { snapshot := nth snapshots 0, width := 4 * cells.advance, position, lines
                  goal := none }
          return moved.position
        return (← move 9 (-5)) == 2 && (← move 1 (-1)) == 1 && (← move 12 9) == 23 &&
            (← move 22 1) == 22 },
    { name :=
        "a move of no lines that is given a goal goes to that x of its row, and to the row's end past its last character; the goal a move with no goal passes back is its position's own x"
      texts := #["abcdef\nab"]
      holds := fun snapshots => do
        let move (position : Nat) (goal : Option Nat) : DisplayM Display.Moved :=
          Display.linesFrom
            { snapshot := nth snapshots 0, width := 10 * cells.advance, position, lines := 0, goal }
        let own ← move 4 none
        return (← move 0 (some (3 * cells.advance))).position == 3 &&
            (← move 7 (some (5 * cells.advance))).position == 9 &&
            own.position == 4 &&
            (← move 0 (some own.goal)).position == 4 },
    { name :=
        "at a width wider than any machine word holds no line wraps: a row is a line of the text, and a move goes from line to line"
      texts := #["abcdefgh\nij"]
      holds := fun snapshots => do
        let shown ←
          Display.rowsShown
              { snapshot := nth snapshots 0, width := 2 ^ 64, height := 2 * cells.lineHeight
                anchor := 0 }
        let moved ←
          Display.linesFrom
              { snapshot := nth snapshots 0, width := 2 ^ 64, position := 6, lines := 1
                goal := none }
        return shown == #[⟨0, 8⟩, ⟨9, 11⟩] && moved.position == 11 },
    { name :=
        "a tab reaches to the next multiple of eight cells: the character after it is eight cells in, and a move that aims inside the tab lands on the tab"
      texts := #["a\tb\n0123456789"]
      holds := fun snapshots => do
        let move (position : Nat) (lines : Int) : DisplayM Nat := do
          let moved ←
            Display.linesFrom
                { snapshot := nth snapshots 0, width := 20 * cells.advance, position, lines
                  goal := none }
          return moved.position
        return (← move 2 1) == 12 && (← move 8 (-1)) == 1 && (← move 11 (-1)) == 1 &&
            (← move 12 (-1)) == 2 },
    { name :=
        "a padded question is the unpadded question of the smaller area: at the scale 1 a runner lays out at, a view padded a cell across and a row down shows the rows of a view two cells narrower and two rows shorter, one also padded a row at the top the rows of one three rows shorter, and a move padded a cell across goes as in a view two cells narrower"
      texts := #["abcdefghijkl\nmn\nop\nqr"]
      holds := fun snapshots => do
        let snapshot := nth snapshots 0
        let padding : Padding := { across := cells.advance, down := cells.lineHeight }
        let padded ←
          Display.rowsShown
              { snapshot, width := 6 * cells.advance, height := 5 * cells.lineHeight, anchor := 0
                padding }
        let smaller ← rows snapshot 4 3 0
        let whole ← rows snapshot 6 5 0
        let move (columns across : Nat) : DisplayM Display.Moved :=
          Display.linesFrom
            { snapshot, width := columns * cells.advance, across, position := 1, lines := 1
              goal := none }
        let paddedMove ← move 6 cells.advance
        -- A top inset of a row takes it off the height once more: a view six
        -- rows tall padded a row down and a row at the top shows three.
        let under ←
          Display.rowsShown
              { snapshot, width := 6 * cells.advance, height := 6 * cells.lineHeight, anchor := 0
                padding := { padding with top := cells.lineHeight } }
        return padded == smaller && padded != whole && padded == #[⟨0, 4⟩, ⟨4, 8⟩, ⟨8, 12⟩] &&
            under == smaller &&
            paddedMove == (← move 4 0) &&
            paddedMove != (← move 6 0) },
    { name := "each height of a row the display answers is at least one pixel"
      texts := #[]
      holds := fun _ => do
        let heights ← Display.heights
        return heights.text ≥ 1 && heights.status ≥ 1 && heights.message ≥ 1 },
    { name :=
        "in cells of a line height, a text row, a status row and the bottom row are each that tall"
      texts := #[]
      holds := fun _ => do
        let heights ← Display.heights
        return heights.text == cells.lineHeight && heights.status == cells.lineHeight &&
            heights.message == cells.lineHeight },
    { name := "a query of a snapshot the display does not know is refused"
      texts := #["ab"]
      holds := fun snapshots => do
        return (← refusedWith .noSuchSnapshot (rows (unknown snapshots) 4 1 0)) &&
            (←
              refusedWith .noSuchSnapshot
                  (Display.linesFrom
                    { snapshot := unknown snapshots, width := 4 * cells.advance, position := 0
                      lines := 1, goal := none })) },
    { name := "a position inside a character, or past the end of the text, is refused"
      texts := #["é\nab"]
      holds := fun snapshots => do
        return (← refusedWith .badPosition (rows (nth snapshots 0) 4 1 1)) &&
            (← refusedWith .badPosition (rows (nth snapshots 0) 4 1 6)) &&
            (←
              refusedWith .badPosition
                  (Display.linesFrom
                    { snapshot := nth snapshots 0, width := 4 * cells.advance, position := 1
                      lines := 1, goal := none })) }]

/-- The names of `properties` that do not hold, with the refusal of each
that was refused. `run` runs one property against an implementation, made
ready with the property's texts as the module docs say. -/
def failures (run : Property → IO (Except DisplayError Bool)) (properties : List Property) :
    IO (List String) :=
  properties.filterMapM fun property => do
    match ← run property with
    | .ok true =>
      return none
    | .ok false =>
      return some property.name
    | .error error =>
      return some s!"{property.name} (it was refused with {repr error})"

end Editor.DisplayContract
