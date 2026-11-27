import Editor.Display

/-!
# The contract of the display interface

What every implementation of the display interface's three queries
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
`across` and once `gutter` off the width, and twice `down` and once `top` off
the height. At another
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

## What the spot query is held to

The spot query is tied to the other two (`spotAgrees`), so it cannot drift
from them: for a position among the rows `rowsShown` answers, the spot's y
is the padding's `down` and `top` plus `k` text rows, where `k` is its
row's index in that answer; its x is the padding's `across` and `gutter` plus the goal
a move of no lines with no goal passes back; and its height is a text
row's. A position before the anchor, or past the rows shown, has none.
Which row holds a position is asked of `rowsShown` too, from an anchor at
the position itself. That a row's height is a text row's is so in cells;
at a scale, and where a face sets another height, it is
`editor-layout`'s tests that pin the spot.

## What blocks are held to

Six properties hold every binding to the rule of blocks
(`Editor/Display.lean`, "Blocks") in cells, each with texts that wrap with
no space: a block takes the rows its text wraps to at the view's width,
above the first row of the line that holds its offset; a line's blocks are
shown with its row or not at all, but for the anchor's, which are left out
when they do not fit with it; and a spot below a block is lower by its
rows. A block's faces are not looked at: a face that sets another height
is `editor-layout`'s to pin.

## What the measuring call is held to

Three properties hold every binding's `Display.measure` in cells: an empty
run measures nothing, a run of `n` one-cell characters measures `n`
cells, and a view exactly as wide as a run's measure holds the run (a
text with no space) on one row while one a cell narrower wraps it. So a
width measured is one the rows query agrees with. What a face does to a
width, and that the answer is in points at any scale, are
`editor-layout`'s tests to pin (`tests/measure.rs`).

A view's align-to stops (`View.stops`), like its faces, are not looked at
by the queries' properties: where a cell goes and where a row breaks
before a stop are `editor-layout`'s rules, pinned on its fake shaper
(`crates/editor-layout/src/align.rs`, `tests/align.rs`).

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

/-- Whether the spot of `position` in a view of `snapshot` whose text area
is `columns` cells by `rows` rows, padded `padding` around it, that shows
from `anchor`, is where `rowsShown` and a move of no lines say it is (the
module docs, "What the spot query is held to"). -/
def spotAgrees (cells : Display.Cells) (snapshot : SnapshotId) (columns rows anchor : Nat)
    (padding : Padding) (position : Nat) : DisplayM Bool := do
  let width := columns * cells.advance + 2 * padding.across + padding.gutter
  let height := rows * cells.lineHeight + 2 * padding.down + padding.top
  let shown ← Display.rowsShown { snapshot, width, height, anchor, padding }
  let own ← Display.rowsShown { snapshot, width, height, anchor := position, padding }
  let spot ← Display.spotOf { snapshot, width, height, anchor, padding, position }
  let heights ← Display.heights
  match own[0]?.bind fun held => shown.findIdx? (· == held) with
  | none =>
    return spot.isNone
  | some k =>
    let moved ←
      Display.linesFrom
          { snapshot, width, across := padding.across, gutter := padding.gutter, position
            lines := 0, goal := none }
    return spot ==
        some
          { x := padding.across + padding.gutter + moved.goal
            y := padding.down + padding.top + k * heights.text
            height := heights.text }

/-- The properties of the queries at the cell size `cells`. -/
def properties (cells : Display.Cells) : List Property :=
  let rows (snapshot : SnapshotId) (columns rows anchor : Nat) : DisplayM (Array Display.Row) :=
    Display.rowsShown
      { snapshot, width := columns * cells.advance, height := rows * cells.lineHeight, anchor }
  let blocked (snapshot : SnapshotId) (columns rows anchor : Nat) (blocks : Array Block) :
    DisplayM (Array Display.Row) :=
    Display.rowsShown
      { snapshot, width := columns * cells.advance, height := rows * cells.lineHeight, anchor
        blocks }
  let spotBlocked (snapshot : SnapshotId) (columns rows anchor position : Nat)
    (blocks : Array Block) : DisplayM (Option Display.Spot) :=
    Display.spotOf
      { snapshot, width := columns * cells.advance, height := rows * cells.lineHeight, anchor
        position, blocks }
  let block (before : Nat) (text : String) : Block := { before, text }
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
    { name :=
        "the rows, a spot and a move of a view with a gutter are those of a view the gutter's width narrower, its spot's x the gutter's width further right"
      texts :=
        #["abcdefghijkl
mn
op
qr"]
      holds := fun snapshots => do
        let snapshot := nth snapshots 0
        let padding : Padding := { gutter := 2 * cells.advance }
        let height := 5 * cells.lineHeight
        let guttered ←
          Display.rowsShown { snapshot, width := 6 * cells.advance, height, anchor := 0, padding }
        let narrower ← rows snapshot 4 5 0
        let spot ←
          Display.spotOf
              { snapshot, width := 6 * cells.advance, height, anchor := 0, padding, position := 5 }
        let bare ←
          Display.spotOf
              { snapshot, width := 4 * cells.advance, height, anchor := 0, position := 5 }
        let move (columns gutter : Nat) : DisplayM Display.Moved :=
          Display.linesFrom
            { snapshot, width := columns * cells.advance, gutter, position := 1, lines := 1
              goal := none }
        return guttered == narrower && guttered == #[⟨0, 4⟩, ⟨4, 8⟩, ⟨8, 12⟩, ⟨13, 15⟩, ⟨16, 18⟩] &&
            spot == bare.map (fun spot => { spot with x := spot.x + 2 * cells.advance }) &&
            spot.isSome &&
            (← move 6 (2 * cells.advance)) == (← move 4 0) &&
            (← move 6 (2 * cells.advance)) != (← move 6 0) },
    { name :=
        "a spot is where the rows and a move say: its y the padding and k rows for the k-th row shown, its x the padding and a move's goal, its height a row's, and none for a position before the anchor or past the rows shown, at every position of a text with wrapped and short lines"
      texts := #["abcdefgh\nij\n\nklmnopqrst\nu"]
      holds := fun snapshots => do
        let snapshot := nth snapshots 0
        let paddings : List Padding :=
          [{}, { across := cells.advance, down := cells.lineHeight, top := cells.lineHeight },
            { across := cells.advance, gutter := 2 * cells.advance }]
        let mut holds := true
        for padding in paddings do
          for anchor in [0, 4, 13] do
            for position in List.range 26 do
              holds := holds && (← spotAgrees cells snapshot 4 3 anchor padding position)
        return holds },
    { name :=
        "a spot is shown exactly where the rows are: the third row shown is two rows down, a position before the anchor has none, and one past the rows shown has none"
      texts := #["ab\ncd\nefgh\nij"]
      holds := fun snapshots => do
        let spot (anchor position : Nat) (padding : Padding := {}) :
          DisplayM (Option Display.Spot) :=
          Display.spotOf
            { snapshot := nth snapshots 0, width := 10 * cells.advance + 2 * padding.across
              height := 3 * cells.lineHeight + 2 * padding.down + padding.top, anchor, padding
              position }
        let padding : Padding := { across := cells.advance, down := cells.lineHeight, top := 1 }
        return (← spot 0 9) ==
              some
                { x := 3 * cells.advance, y := 2 * cells.lineHeight, height := cells.lineHeight } &&
            (← spot 3 0) == none &&
            (← spot 0 12) == none &&
            (← spot 0 9 padding) ==
              some
                { x := 4 * cells.advance, y := 3 * cells.lineHeight + 1
                  height := cells.lineHeight } },
    { name := "a block of one row before a row takes a row of the view's height"
      texts := #["a\nb\nc\nd"]
      holds := fun snapshots => do
        return (← blocked (nth snapshots 0) 4 3 0 #[block 2 "H"]) == #[⟨0, 1⟩, ⟨2, 3⟩] &&
            (← rows (nth snapshots 0) 4 3 0) == #[⟨0, 1⟩, ⟨2, 3⟩, ⟨4, 5⟩] },
    { name :=
        "a block wider than the view takes the rows its text wraps to, and is shown with its row or not at all"
      texts := #["a\nb\nc\nd"]
      holds := fun snapshots => do
        let wide := #[block 2 "HHHH"]
        return (← blocked (nth snapshots 0) 2 4 0 wide) == #[⟨0, 1⟩, ⟨2, 3⟩] &&
            (← blocked (nth snapshots 0) 2 3 0 wide) == #[⟨0, 1⟩] },
    { name :=
        "the blocks before the anchor's row are shown above it when they fit with it, and left out when they do not"
      texts := #["a\nb\nc\nd"]
      holds := fun snapshots => do
        let snapshot := nth snapshots 0
        return (← blocked snapshot 4 2 2 #[block 2 "H"]) == #[⟨2, 3⟩] &&
            (← blocked snapshot 4 1 2 #[block 2 "H"]) == #[⟨2, 3⟩] &&
            (← blocked snapshot 4 1 2 #[block 2 "HHHHHHHH"]) == #[⟨2, 3⟩] &&
            (← spotBlocked snapshot 4 2 2 2 #[block 2 "H"]) ==
              some { x := 0, y := cells.lineHeight, height := cells.lineHeight } &&
            (← spotBlocked snapshot 4 1 2 2 #[block 2 "H"]) ==
              some { x := 0, y := 0, height := cells.lineHeight } },
    { name :=
        "a spot below a block is lower by the block's rows, its x and its height as without it"
      texts := #["a\nb\nc\nd"]
      holds := fun snapshots => do
        let snapshot := nth snapshots 0
        let bare ← spotBlocked snapshot 4 5 0 4 #[]
        return bare == some { x := 0, y := 2 * cells.lineHeight, height := cells.lineHeight } &&
            (← spotBlocked snapshot 4 5 0 4 #[block 2 "H"]) ==
              some { x := 0, y := 3 * cells.lineHeight, height := cells.lineHeight } &&
            (← spotBlocked snapshot 4 5 0 5 #[block 2 "H"]) ==
              some { x := cells.advance, y := 3 * cells.lineHeight, height := cells.lineHeight } },
    { name :=
        "a block before an offset in the middle of a line is drawn above that line's first row, and a wrapped row after it has none"
      texts := #["abcdefgh\nij"]
      holds := fun snapshots => do
        let snapshot := nth snapshots 0
        return (← blocked snapshot 4 2 0 #[block 6 "H"]) == #[⟨0, 4⟩] &&
            (← blocked snapshot 4 2 4 #[block 6 "H"]) == #[⟨4, 8⟩, ⟨9, 11⟩] &&
            (← spotBlocked snapshot 4 4 0 9 #[block 6 "H"]) ==
              some { x := 0, y := 3 * cells.lineHeight, height := cells.lineHeight } },
    { name := "two blocks before one row both take rows"
      texts := #["a\nb\nc\nd"]
      holds := fun snapshots => do
        let snapshot := nth snapshots 0
        let two := #[block 2 "H", block 3 "K"]
        return (← blocked snapshot 4 4 0 two) == #[⟨0, 1⟩, ⟨2, 3⟩] &&
            (← blocked snapshot 4 3 0 two) == #[⟨0, 1⟩] &&
            (← spotBlocked snapshot 4 4 0 2 two) ==
              some { x := 0, y := 3 * cells.lineHeight, height := cells.lineHeight } },
    { name := "an empty run measures nothing"
      texts := #[]
      holds := fun _ => do
        return (← Display.measure { text := "" }) == 0 },
    { name := "a run of n one-cell characters measures n cells"
      texts := #[]
      holds := fun _ => do
        return (← Display.measure { text := "abcd" }) == 4 * cells.advance &&
            (← Display.measure { text := "é😀ab" }) == 4 * cells.advance },
    { name :=
        "a view exactly as wide as a run's measure holds it on one row, and one a cell narrower wraps it"
      texts := #["abcdef"]
      holds := fun snapshots => do
        let snapshot := nth snapshots 0
        let width ← Display.measure { text := "abcdef" }
        let height := 2 * cells.lineHeight
        let exact ← Display.rowsShown { snapshot, width, height, anchor := 0 }
        let narrower ←
          Display.rowsShown { snapshot, width := width - cells.advance, height, anchor := 0 }
        return exact == #[⟨0, 6⟩] && narrower == #[⟨0, 5⟩, ⟨5, 6⟩] },
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
                      lines := 1, goal := none })) &&
            (←
              refusedWith .noSuchSnapshot
                  (Display.spotOf
                    { snapshot := unknown snapshots, width := 4 * cells.advance
                      height := cells.lineHeight, anchor := 0, position := 0 })) },
    { name := "a position inside a character, or past the end of the text, is refused"
      texts := #["é\nab"]
      holds := fun snapshots => do
        return (← refusedWith .badPosition (rows (nth snapshots 0) 4 1 1)) &&
            (← refusedWith .badPosition (rows (nth snapshots 0) 4 1 6)) &&
            (←
              refusedWith .badPosition
                  (Display.linesFrom
                    { snapshot := nth snapshots 0, width := 4 * cells.advance, position := 1
                      lines := 1, goal := none })) &&
            (←
              refusedWith .badPosition
                  (Display.spotOf
                    { snapshot := nth snapshots 0, width := 4 * cells.advance
                      height := cells.lineHeight, anchor := 0, position := 1 })) &&
            (←
              refusedWith .badPosition
                  (Display.spotOf
                    { snapshot := nth snapshots 0, width := 4 * cells.advance
                      height := cells.lineHeight, anchor := 1, position := 0 })) }]

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
