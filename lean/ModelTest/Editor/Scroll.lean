import Editor.Command
import Editor.Command.Model
import Editor.Display
import Editor.Program
import Editor.Scene
import Editor.Scroll
import Editor.Test.Models
import Editor.Text
import Editor.Watch
import Editor.Watch.Model
import ModelTest.Check
import ModelTest.Support.Display

/-!
# Model tests: `Editor/Scroll.lean`

The model tests of `Editor/Scroll.lean`: `blockedScrollChecks` and
`scrollChecks`. The root module `ModelTest` runs them; its module doc says what
each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- What the follow policy answers for a view of `text` whose scroll anchor
is at `anchor` and whose cursor is at `head`: the offset to place the anchor
at, or none inside to keep it; none outside where the display refused. -/
def followFrom (text : String) (width height margin anchor head : Nat)
    (cells : Display.Cells := { advance := 1, lineHeight := 1 }) : Option (Option Nat) :=
  onDisplay text (cells := cells) do
    let area := areaOf width height
    Scroll.follow area margin (← area.rows anchor) head

/-- A view after the follow policy. -/
structure Followed where
  /-- Whether the policy placed an anchor. -/
  moved : Bool
  /-- The rows the view shows afterwards. -/
  shown : Array Display.Row
  /-- Where the cursor's row is among them, if it is one of them. -/
  index : Option Nat
  deriving DecidableEq, Repr

/-- The view of `followFrom` after the policy: the rows the display model
answers from the anchor placed, or from `anchor` where it was kept, and
where the cursor's row is among them. -/
def followedFrom (text : String) (width height margin anchor head : Nat)
    (cells : Display.Cells := { advance := 1, lineHeight := 1 }) : Option Followed := do
  let moved ← followFrom text width height margin anchor head cells
  let row ← rowAt text width head cells
  let shown := rowsFrom text width height (moved.getD anchor) cells
  return { moved := moved.isSome, shown, index := shown.findIdx? (· == row) }

/-- Whether the follow policy, handed `margin`, holds a margin of `held`
rows, from every row of `text` as the first row shown and every offset of it
as the cursor (the text is ASCII): afterwards the margin holds of the
cursor's row, an anchor is kept when it held already, and a second follow
keeps the anchor. -/
def marginSweep (text : String) (width height margin : Nat) (held : Nat := margin) : Bool :=
  let rows := allRows text width
  !rows.isEmpty &&
    rows.all fun top =>
      (List.range (text.utf8ByteSize + 1)).all fun head =>
        match rowAt text width head, followFrom text width height margin top.start head with
        | some row, some moved =>
          let anchor := moved.getD top.start
          marginHolds rows (rowsFrom text width height anchor) row held &&
            (!marginHolds rows (rowsFrom text width height top.start) row held || moved.isNone) &&
            followFrom text width height margin anchor head == some none
        | _, _ => false

/-- Sixteen lines of one letter each, `a` to `p`, with no line feed after the
last. -/
def sixteen : String :=
  "\n".intercalate ("abcdefghijklmnop".toList.map (·.toString))

/-- What the follow policy costs on the counting model, for a view of
`sixteen` ten characters wide and `height` rows tall whose first row shown is
row `top` and whose cursor is on row `cursor`: whether it placed an anchor,
and how many requests it made after the rows shown, which its caller
asked. -/
def followCost (height margin top cursor : Nat) : Option (Bool × Nat) :=
  let rows := allRows sixteen 10
  let program : EditorM (Bool × Nat) := do
    let text ← createText sixteen
    let area : Scroll.Area := { snapshot := ← text.snapshot, width := 10, height }
    let shown ← area.rows (startOf rows top)
    let before ← Watch.now
    let moved ← Scroll.follow area margin shown (startOf rows cursor)
    return (moved.isSome, (← Watch.now) - before)
  (program.runModel countingModel).1.toOption

/-- Where a scroll down by `rows` rows places the anchor of a view of `text`
whose anchor is at `anchor`, handed the rows the view fits as its caller
asks them: none inside to keep it, none outside where the display
refused. -/
def scrolledDown (text : String) (width height anchor rows : Nat) : Option (Option Nat) :=
  onDisplay text do
    let area := areaOf width height
    Scroll.down area anchor rows (← area.fits)

/-- The same for a scroll up. -/
def scrolledUp (text : String) (width height anchor rows : Nat) : Option (Option Nat) :=
  onDisplay text do
    let area := areaOf width height
    Scroll.up area anchor rows (← area.fits)

/-- Whether, from every row of `text` as the first row shown, a scroll by 1,
2, 3, 5 and 100 rows places the anchor the model's rows say: down, the row
that many below, no further than where the text's last row is the last row
shown, and never a row before the one given; up, the row that many above,
no further than the first; none where that is the row it was at. -/
def scrollSweep (text : String) (width height : Nat) : Bool :=
  let rows := allRows text width
  let fits := (rowsFrom text width height 0).size
  let placed (was want : Nat) : Option (Option Nat) :=
    some (if want == was then none else some (startOf rows want))
  fits > 0 &&
    (List.range rows.size).all fun top =>
      [1, 2, 3, 5, 100].all fun count =>
        scrolledDown text width height (startOf rows top) count ==
            placed top (max top (min (top + count) (rows.size - fits))) &&
          scrolledUp text width height (startOf rows top) count == placed top (top - count)

/-- Whether, from every offset of `text` as the cursor (the text is ASCII),
a scroll to the cursor's row places an anchor from which the model shows
that row first, in the middle of the rows the view fits (the upper of two)
and last; or, where the text has fewer rows above the cursor than that
takes, the text's first row first. Where the view shows the whole text from
its start, a scroll to the middle places the text's first row first,
wherever the cursor is. -/
def lineToSweep (text : String) (width height : Nat) : Bool :=
  let rows := allRows text width
  let fits := (rowsFrom text width height 0).size
  -- Whether the rows shown from the text's start are all of its rows.
  let whole := fits == rows.size
  fits > 0 &&
    (List.range (text.utf8ByteSize + 1)).all fun head =>
      match rowAt text width head with
      | none => false
      | some row =>
        let cursor := (rows.findIdx? (· == row)).getD rows.size
        -- The cursor's row is to be `up` rows below the first row shown.
        let placed (place : Scroll.Place) (up : Nat) (kept : Bool := false) : Bool :=
          match onDisplay text (Scroll.lineTo place (areaOf width height) head) with
          | some (some anchor) =>
            let shown := rowsFrom text width height anchor
            if cursor ≥ up && !kept then shown[up]? == some row else shown[0]? == rows[0]?
          | _ => false
        placed .top 0 && placed .middle ((fits - 1) / 2) (kept := whole) &&
          placed .bottom (fits - 1)

/-- Blocks over `sixteen` ten cells wide: a block of one row before rows 3,
6 and 7, and one of two rows before row 12 (its text is twelve cells). -/
def sixteenBlocks : Array Block :=
  #[{ before := 6, text := "H" }, { before := 12, text := "I" }, { before := 14, text := "J" },
    { before := 24, text := "twelve-cells" }]

/-- A view of `sixteen` ten cells wide and `height` rows tall, with
`sixteenBlocks`. -/
def blockedArea (height : Nat) : Scroll.Area :=
  { snapshot := ⟨0⟩, width := 10, height, blocks := sixteenBlocks }

/-- The rows of a view of `sixteen` with blocks (`blockedArea`) from
`anchor`, as the display model answers them; none where it refuses. -/
def blockedRows (height anchor : Nat) : Array Display.Row :=
  (onDisplay sixteen ((blockedArea height).rows anchor)).getD #[]

/-- Whether the cursor's row, that of `head`, is among `shown`, the rows of
a view with blocks `height` rows tall, with `margin` rows after it as far as
the rows shown from the cursor's row reach, which is where the follow's
margin gives way below (`Editor/Scroll.lean`, "The margin"), or it is the
first row shown (`Editor/Scroll.lean`, "Blocks": the settle holds the
margin below). -/
def blockedHolds (height : Nat) (shown : Array Display.Row) (head margin : Nat) : Bool :=
  let below := (blockedRows height head).size - 1
  match shown.findIdx? (·.start == head) with
  | none => false
  | some index => index == 0 || shown.size - 1 - index ≥ min margin below

/-- Where the follow places the anchor of a view of `sixteen` with blocks
`height` rows tall from `anchor`, with its cursor at `head`; none outside
where the display refused. -/
def blockedFollow (height margin anchor head : Nat) : Option (Option Nat) :=
  onDisplay sixteen do
    let area := blockedArea height
    Scroll.follow area margin (← area.rows anchor) head

/-- The anchors a view of `sixteen` with blocks `height` rows tall is left
at, with the margin `margin`, by a cursor on every row from the first to
the last and back, one row at a time, the follow asked after each from the
anchor the one before left, from the text's start; and whether the cursor's
row was shown with the margin in force below it (`blockedHolds`) each time. -/
def blockedSweep (height margin : Nat) : Bool :=
  Id.run do
    let fits := (blockedRows height 0).size
    let held := min margin ((fits - 1) / 2)
    let mut anchor := 0
    for row in List.range 16 ++ (List.range 16).reverse do
      let head := 2 * row
      let some moved := blockedFollow height margin anchor head | return false
      anchor := moved.getD anchor
      unless blockedHolds height (blockedRows height anchor) head held do
        return false
    return true

/-- What the follow costs on the counting model for a view of `sixteen` ten
characters wide and five rows tall whose first row shown is row `top` and
whose cursor is on row `cursor`, with `blocks`: whether it placed an anchor,
and how many requests it made after the rows shown. -/
def blockedFollowCost (blocks : Array Block) (top cursor : Nat) : Option (Bool × Nat) :=
  let program : EditorM (Bool × Nat) := do
    let text ← createText sixteen
    let area : Scroll.Area := { snapshot := ← text.snapshot, width := 10, height := 5, blocks }
    let shown ← area.rows (2 * top)
    let before ← Watch.now
    let moved ← Scroll.follow area 0 shown (2 * cursor)
    return (moved.isSome, (← Watch.now) - before)
  (program.runModel countingModel).1.toOption

/-- The checks of the follow and of the scrolls in a view with blocks
(`Editor/Scroll.lean`, "Blocks"), on the display model alone, over
`sixteen` with `sixteenBlocks`. -/
def blockedScrollChecks : List Check :=
  [{  name :=
        "in a view with blocks, a cursor on every row of the text, reached down a row at a time and back up, is among the rows shown after the follow, with the margin in force below it as far as the rows from it reach, at margins 0, 1 and 2 and in views of 3, 5 and 7 rows"
      run :=
        pure <|
          [3, 5, 7].all fun height => [0, 1, 2].all fun margin => blockedSweep height margin },
    { name :=
        "in a view with blocks, a jump to the text's end and back to its start shows the cursor's row"
      run :=
        pure <|
          [3, 5, 7].all fun height =>
            match blockedFollow height 0 0 30 with
            | some (some down) =>
              blockedHolds height (blockedRows height down) 30 0 &&
                match blockedFollow height 0 down 0 with
                | some (some up) => up == 0 && blockedHolds height (blockedRows height up) 0 0
                | _ => false
            | _ => false },
    { name :=
        "in a view with blocks, a scroll by a row, by half a view and up, and to the top, the middle and the bottom, followed by the follow, shows the cursor's row, from every row shown first and every row as the cursor"
      run :=
        pure <|
          [3, 5, 7].all fun height =>
            let area := blockedArea height
            (List.range 16).all fun top =>
              (List.range 16).all fun row =>
                let head := 2 * row
                let anchor := 2 * top
                let scrolls : List (DisplayM (Option Nat)) :=
                  [do
                    Scroll.down area anchor 1 (← area.fits), do
                    Scroll.down area anchor (Scroll.Amount.half.rows 0 (← area.fits)) (← area.fits),
                    do
                    Scroll.up area anchor 2 (← area.fits), Scroll.lineTo .top area head,
                    Scroll.lineTo .middle area head, Scroll.lineTo .bottom area head]
                scrolls.all fun scroll =>
                  match onDisplay sixteen scroll with
                  | some placed =>
                    let anchor := placed.getD anchor
                    match blockedFollow height 0 anchor head with
                    | some moved =>
                      blockedHolds height (blockedRows height (moved.getD anchor)) head 0
                    | none => false
                  | none => false },
    { name :=
        "a view with blocks shows the rows of the view without them that fit with the block rows above them: from the text's start, the first three rows and the fourth with its block"
      run :=
        pure <|
          blockedRows 5 0 == (rowsFrom sixteen 10 5 0).extract 0 4 &&
            (onDisplay sixteen ((areaOf 10 5).rows 0)) == some (rowsFrom sixteen 10 5 0) },
    { name :=
        "what the follow costs with blocks: one request more where it places an anchor that holds the cursor's row, one more for each row it settles, and nothing more where it keeps the anchor"
      run :=
        pure <|
          -- Row 11 from row 0: the anchor placed, row 8, holds it.
          blockedFollowCost #[] 0 11 == some (true, 2) &&
            blockedFollowCost sixteenBlocks 0 11 == some (true, 3) &&
            -- Row 15 from row 0: the anchor placed, row 12, shows its two
            -- block rows and does not hold it; one step to row 13 does.
            blockedFollowCost sixteenBlocks 0 15 == some (true, 4) &&
            -- A cursor shown asks the rows from it alone.
            blockedFollowCost sixteenBlocks 0 1 == some (false, 1) &&
            blockedFollowCost #[] 0 1 == some (false, 1) }]

/-- The checks of the policy by which a view follows its cursor and of the
anchors a scroll places (`Editor/Scroll.lean`), on the display model alone,
with the scroll anchor and the cursor as offsets. A row is one the display model answers
(`allRows`, `rowsFrom`, `rowAt`): no check says where a text wraps. -/
def scrollChecks : List Check :=
  [{  name :=
        "the area of a view asks with the snapshot of its text, its rectangle's width and its rectangle's height less its bottom row"
      run :=
        pure
          (Scroll.Area.ofRect ⟨3⟩ { x := 7, y := 9, width := 40, height := 30 } 16 ==
              { snapshot := ⟨3⟩, width := 40, height := 14 } &&
            (Scroll.Area.ofRect ⟨3⟩ { x := 7, y := 9, width := 40, height := 10 } 16).height ==
              0) },
    { name :=
        "a cursor on the first row a view shows, on the last, and on one between them keeps the scroll anchor"
      run :=
        pure <|
          let rows := allRows sixteen 10
          rows.size == 16 &&
            [3, 5, 7].all fun cursor =>
              followFrom sixteen 10 5 0 (startOf rows 3) (startOf rows cursor) == some none },
    { name :=
        "a cursor one row below the rows shown moves the anchor one row, and one ten rows below them moves it so that the cursor's row is the last row shown"
      run :=
        pure <|
          let rows := allRows sixteen 10
          followFrom sixteen 10 5 0 (startOf rows 3) (startOf rows 8) ==
              some (some (startOf rows 4)) &&
            followedFrom sixteen 10 5 0 (startOf rows 0) (startOf rows 14) ==
              some { moved := true, shown := rows.extract 10 15, index := some 4 } },
    { name :=
        "a cursor one row above the rows shown moves the anchor one row, and one ten rows above them moves it so that the cursor's row is the first row shown"
      run :=
        pure <|
          let rows := allRows sixteen 10
          followFrom sixteen 10 5 0 (startOf rows 8) (startOf rows 7) ==
              some (some (startOf rows 7)) &&
            followedFrom sixteen 10 5 0 (startOf rows 12) (startOf rows 2) ==
              some { moved := true, shown := rows.extract 2 7, index := some 0 } },
    { name :=
        "a cursor on the last visual row of a line wrapped over three rows, below the view, has that row as the last row shown, and the anchor is not the line's first row"
      run :=
        pure <|
          let rows := allRows wrapping 4
          -- The third line is rows 3, 4 and 5: a line break is before the
          -- first of them and after the last, and none is between them.
          let last := startOf rows 5
          (rows[2]?.map (·.stop + 1)) == some (startOf rows 3) &&
            (rows[3]?.map (·.stop)) == some (startOf rows 4) &&
            (rows[4]?.map (·.stop)) == some last &&
            (rows[5]?.map (·.stop + 1)) == some (startOf rows 6) &&
            (rowAt wrapping 4 (last + 1)).map (·.start) == some last &&
            followedFrom wrapping 4 2 0 0 (last + 1) ==
              some { moved := true, shown := rows.extract 4 6, index := some 1 } },
    { name :=
        "a cursor at the end of a text that ends in a line feed, in the empty row after it, is shown, as the last row"
      run :=
        pure <|
          let text := "a\nb\nc\nd\n"
          let rows := allRows text 10
          followedFrom text 10 2 0 0 text.utf8ByteSize ==
              some
                { moved := true, shown := rows.extract (rows.size - 2) rows.size,
                  index := some 1 } &&
            (rows.back?.map fun row => row.start == row.stop) == some true },
    { name := "a view that shows no row keeps its anchor, wherever its anchor and its cursor are"
      run :=
        pure <|
          let rows := allRows sixteen 10
          !rows.isEmpty &&
            rows.all fun top =>
              rows.all fun cursor =>
                followFrom sixteen 10 0 0 top.start cursor.start == some none &&
                  followFrom sixteen 10 0 2 top.start cursor.start == some none },
    { name :=
        "with a margin of two, from every row as the first row shown and every position as the cursor, of sixteen short lines and of a text with wrapped lines, in views of five and of seven rows: afterwards the cursor's row is among the rows shown, at least two rows from the first unless the first is the text's first row and at least two from the last unless the last is the text's last; an anchor is kept when that held already; and a second follow keeps the anchor"
      run :=
        pure
          (marginSweep sixteen 10 5 2 && marginSweep sixteen 10 7 2 && marginSweep ragged 4 5 2 &&
            marginSweep ragged 4 7 2) },
    { name :=
        "with no margin, the same sweep: the cursor's row is among the rows shown afterwards, an anchor that showed it is kept, and a second follow keeps the anchor"
      run :=
        pure
          (marginSweep sixteen 10 5 0 && marginSweep ragged 4 3 0 && marginSweep ragged 4 1 0 &&
            marginSweep "" 4 3 0) },
    { name :=
        "a margin larger than a view can keep is half the rows the view fits: with a margin of 99 a view of five rows keeps two rows each side of the cursor's row, and keeps its anchor while it does"
      run :=
        pure <|
          let rows := allRows sixteen 10
          followedFrom sixteen 10 5 99 (startOf rows 0) (startOf rows 10) ==
              some { moved := true, shown := rows.extract 8 13, index := some 2 } &&
            followedFrom sixteen 10 5 99 (startOf rows 8) (startOf rows 11) ==
              some { moved := true, shown := rows.extract 9 14, index := some 2 } &&
            followFrom sixteen 10 5 99 (startOf rows 8) (startOf rows 10) == some none &&
            marginSweep sixteen 10 5 99 (held := 2) },
    { name :=
        "the policy counts no pixels: in cells of 8 by 16, in a view 48 pixels tall, a cursor below the rows shown becomes the last of three rows shown and one above them the first"
      run :=
        pure <|
          let cells : Display.Cells := { advance := 8, lineHeight := 16 }
          let rows := allRows sixteen 80 cells
          rows.size == 16 &&
            followedFrom sixteen 80 48 0 (startOf rows 0) (startOf rows 9) cells ==
              some { moved := true, shown := rows.extract 7 10, index := some 2 } &&
            followedFrom sixteen 80 48 0 (startOf rows 9) (startOf rows 4) cells ==
              some { moved := true, shown := rows.extract 4 7, index := some 0 } },
    { name :=
        "what the policy costs, counted on the watch model's clock, after the rows shown, which its caller asked: one request where the anchor is kept and the margin as set holds, with a margin and with none; one for a cursor above with no margin; two for a cursor below with no margin, and one in a view of one row; with a margin that does not hold as set, two where the anchor is kept and three where it moves"
      run :=
        pure
          (followCost 5 0 3 5 == some (false, 1) && followCost 5 2 3 5 == some (false, 1) &&
            followCost 5 0 8 2 == some (true, 1) &&
            followCost 5 0 0 10 == some (true, 2) &&
            followCost 1 0 0 10 == some (true, 1) &&
            followCost 5 2 0 1 == some (false, 2) &&
            followCost 5 2 3 7 == some (true, 3)) },
    { name :=
        "the rows a view fits are the rows it shows from the text's start: its own rows where the text has more, and the text's rows where the text is shorter than the view"
      run :=
        pure
          (onDisplay sixteen (areaOf 10 5).fits == some 5 &&
            onDisplay "a\nb\nc" (areaOf 10 9).fits == some (allRows "a\nb\nc" 10).size &&
            (allRows "a\nb\nc" 10).size < 9 &&
            onDisplay sixteen (areaOf 10 0).fits == some 0) },
    { name :=
        "how many rows a scroll is: half the rows the view fits and at least one, or the count when one was typed; and the rows the view fits, times the count when one was typed"
      run :=
        pure
          (Scroll.Amount.half.rows 0 6 == 3 && Scroll.Amount.half.rows 0 7 == 3 &&
            Scroll.Amount.half.rows 0 1 == 1 &&
            Scroll.Amount.half.rows 5 6 == 5 &&
            Scroll.Amount.page.rows 0 6 == 6 &&
            Scroll.Amount.page.rows 1 6 == 6 &&
            Scroll.Amount.page.rows 2 6 == 12) },
    { name :=
        "a scroll down moves the anchor the rows asked; near the text's end it stops where the text's last row is the last row shown; and from there, and from an anchor past it, it places none"
      run :=
        pure <|
          let rows := allRows sixteen 10
          scrolledDown sixteen 10 5 (startOf rows 3) 2 == some (some (startOf rows 5)) &&
            scrolledDown sixteen 10 5 (startOf rows 9) 5 == some (some (startOf rows 11)) &&
            rowsFrom sixteen 10 5 (startOf rows 11) == rows.extract 11 16 &&
            scrolledDown sixteen 10 5 (startOf rows 11) 1 == some none &&
            scrolledDown sixteen 10 5 (startOf rows 13) 1 == some none },
    { name :=
        "a scroll up moves the anchor the rows asked, and no further than the text's first row, where it places none"
      run :=
        pure <|
          let rows := allRows sixteen 10
          scrolledUp sixteen 10 5 (startOf rows 9) 2 == some (some (startOf rows 7)) &&
            scrolledUp sixteen 10 5 (startOf rows 3) 5 == some (some (startOf rows 0)) &&
            scrolledUp sixteen 10 5 (startOf rows 0) 1 == some none },
    { name :=
        "from every row as the first row shown, of sixteen short lines, of a text with wrapped lines and of a text shorter than its view, by 1, 2, 3, 5 and 100 rows: a scroll down places the row that many below, no further than where the text's last row is the last row shown, and never a row before the one it was given; a scroll up the row that many above, no further than the first; and each places none where that is the row it was at"
      run :=
        pure
          (scrollSweep sixteen 10 5 && scrollSweep sixteen 10 1 && scrollSweep ragged 4 3 &&
            scrollSweep ragged 4 7 &&
            scrollSweep "a\nb\nc" 10 9 &&
            scrollSweep "" 4 3) },
    { name :=
        "a scroll to the cursor's row, from every position as the cursor: to the top, the cursor's row is the first row then shown; to the middle, the middle row of those the view fits, the upper of two; to the bottom, the last; and where the text has too few rows above the cursor for that, the first row shown is the text's first"
      run :=
        pure
          (lineToSweep sixteen 10 5 && lineToSweep sixteen 10 6 && lineToSweep ragged 4 3 &&
            lineToSweep ragged 4 4 &&
            lineToSweep "" 4 3) },
    { name :=
        "a scroll to the middle never hides a row of a text its view shows whole: in a view taller than its text and in one the text fills exactly, of short lines and of wrapped ones, from every position as the cursor, it places the text's first row, while a scroll to the top still puts the cursor's row first; and in a view one row shorter than its text it puts the cursor's row in the middle"
      run :=
        pure <|
          let rows := allRows sixteen 10
          lineToSweep "a\nb\nc" 10 9 && lineToSweep "a\nb\nc\n" 10 9 &&
            lineToSweep "a\nb\nc" 10 3 &&
            lineToSweep sixteen 10 16 &&
            lineToSweep ragged 4 (allRows ragged 4).size &&
            lineToSweep ragged 4 40 &&
            onDisplay "a\nb\nc\n" (Scroll.lineTo .middle (areaOf 10 10) 4) == some (some 0) &&
            onDisplay sixteen (Scroll.lineTo .middle (areaOf 10 16) (startOf rows 15)) ==
              some (some 0) &&
            onDisplay sixteen (Scroll.lineTo .middle (areaOf 10 15) (startOf rows 15)) ==
              some (some (startOf rows 8)) },
    { name :=
        "with a margin, in a view that shows its whole text, the follow keeps as many rows above the cursor's row as the margin asks and the text has, and is not capped by the text's rows: a sweep with a margin of two and one of 99, in a view taller than four lines and in one they fill exactly; and from the last of four rows as the first row shown, with the cursor on it, a margin of two shows from the second row"
      run :=
        pure <|
          let four := "a\nb\nc\nd"
          let rows := allRows four 10
          marginSweep four 10 9 2 && marginSweep four 10 9 99 && marginSweep four 10 4 2 &&
            marginSweep four 10 4 99 &&
            followedFrom four 10 9 2 (startOf rows 3) (startOf rows 3) ==
              some { moved := true, shown := rows.extract 1 4, index := some 2 } },
    { name :=
        "on the text's last line a scroll to the top leaves the view showing one row, and a scroll to the bottom from there shows as many rows as the view fits, the cursor's row the last"
      run :=
        pure <|
          let rows := allRows sixteen 10
          let last := startOf rows 15
          let top := onDisplay sixteen (Scroll.lineTo .top (areaOf 10 5) last)
          let bottom := onDisplay sixteen (Scroll.lineTo .bottom (areaOf 10 5) last)
          top == some (some last) && rowsFrom sixteen 10 5 last == rows.extract 15 16 &&
            bottom == some (some (startOf rows 11)) },
    { name :=
        "in a view that shows no row a scroll down, a scroll up and a scroll to the cursor's row each place none"
      run :=
        pure <|
          let rows := allRows sixteen 10
          let area := areaOf 10 0
          scrolledDown sixteen 10 0 (startOf rows 3) 2 == some none &&
            scrolledUp sixteen 10 0 (startOf rows 3) 2 == some none &&
            [Scroll.Place.top, .middle, .bottom].all fun place =>
              onDisplay sixteen (Scroll.lineTo place area (startOf rows 8)) == some none }]

end ModelTest
