import Editor.Display

/-!
# Scrolling: how a view follows its cursor

A view shows its text from a scroll anchor: a position of the text, and the
rows shown start at the visual row that holds it. This module is the policy
that says where the anchor goes. It is programs over the display port
(`Editor/Display.lean`) and arithmetic on what they answer. It holds no
state, reads no text and places nothing: it is handed offsets and answers
the offset to place the anchor at, or none to keep it, and its callers read
and place the anchor's marker (the command loop before each scene,
`Editor/Loop.lean`).

## The follow policy: the least movement

`Scroll.follow` is asked before each scene, for each view:

- A view whose cursor's row is among the rows it shows keeps its anchor.
- Otherwise the anchor moves just far enough to show it. A cursor above
  the rows shown becomes the first row shown, and a cursor below them the
  last. So a motion of one row off an edge scrolls one row, and a jump (to
  the text's end, to its start, by a count) leaves the cursor at the edge
  it came in by.
- The anchor placed is where a row starts, as the display answers it.
- A view that shows no row, because it is less than a row tall, keeps its
  anchor: there is no row to show the cursor in.

The cursor is a position of the text, and **the cursor's row** is the first
row the display answers from it. Whether the cursor is shown is decided by
comparing rows, never by comparing its offset with the rows' ranges: a
position at a wrap is the start of the later row, and only a line's last
row holds the position at its end, so "the offset is at or before the last
row's stop" is wrong of a wrapped row. The display says which row holds a
position, by its own rule.

Not done: centring the cursor's row after a far jump, as Vim does, and
scrolling by more than one row at an edge (Vim's `scrolljump`). A margin
larger than half the view gives a view that always centres.

## The margin

The margin is how many rows are kept between the cursor's row and the first
and the last row shown. Vim's `scrolloff` is the model. It is a number of
the editor state, 0 by default, which this module is handed.

- With a margin, a cursor's row that is among the rows shown but nearer an
  edge than the margin moves the anchor too, by as little as holds the
  margin.
- **The margin in force is at most half the rows the view fits**: `min
  margin ((fits - 1) / 2)`. In a view of five rows a margin of 99 keeps
  two, which centres the cursor's row. It is capped by the rows the view
  fits (`Area.fits`), not by the rows shown, which are fewer when the view
  shows past the text's end: capped by those, a second follow would move
  the anchor again.
- **At the text's start and end the margin gives way.** The first row shown
  cannot be above the text's first row, and a cursor fewer than the margin
  from the text's last row keeps as many rows below it as the text has.

## What is asked

Layout is the display's, and nothing of it is kept here between two
questions. The two queries of the display port are all that is asked:

- `Display.rowsShown`, three ways: from the view's anchor (the rows shown,
  which the caller asks and hands in), from the cursor (the cursor's row,
  and how many rows of the text are below it, as far as the view is tall),
  and from the text's start (the rows the view fits, `Area.fits`);
- `Display.linesFrom`, aiming for the row's start (`goal := some 0`): the
  row some rows above or below a position, as an anchor (`Area.above`,
  `Area.below`).

What is relied on is in the display interface's contract
(`Editor/Display/Contract.lean`): an anchor in the middle of a row starts
at that row; the rows stop at the end of the text; a move past the first or
the last row stops on that row. One thing is not in it and is not relied
on: that a move aiming for x 0 answers the row's first byte. The model
does, so on the model a placed anchor is a row's start. Where a display
answers another position of that row, the rows shown from it are the same.

## What it costs

In requests of the display, for one view, after the rows shown from its
anchor, which the caller asked:

| The view | Requests |
|---|---|
| Shows no row | 0 |
| Keeps its anchor, the margin as set holding | 1: the rows from the cursor |
| Cursor above, no margin | 1 |
| Cursor below, no margin | 2: and one move; 1 in a view of one row |
| A margin set that does not hold as set | 2: and the rows the view fits; 3 where the anchor moves |

Not done: answering "is the cursor shown" from the rows shown alone, which
would write the display's wrap rule here for one request a view; and
remembering that a view was fine until something changed, which is a
verdict of layout kept in Lean, stale when layout changes for a reason Lean
does not see.

## What is the display's, and missing

- **The height of a view's text area.** The rows query takes a height, and
  the real frame gives a view's bottom row to its status line. Lean cannot
  learn that row's height, so a view is asked about with its whole height
  (`Area.ofRect`, the one definition that says which height). On the model
  and in the headless host that is exact: neither has a status row. Over
  real layout the rows query answers one row more than the frame shows.
  The fix is the display pipeline's (`docs/design/text-and-display.md`,
  "Open questions"), and `Area.ofRect` is what changes when it exists.
- **How many rows fit a view.** The display answers the rows shown from an
  anchor, which are fewer at the text's end. `Area.fits` is the rows shown
  from the text's start: the rows that fit, or all of the text's rows when
  it has fewer. It is right where rows are one height, which is the
  model's.

Pinned by `ModelTest.scrollChecks`, on the display model alone.
-/

namespace Editor

namespace Scroll

/-- What the display is asked about a view with: a snapshot of its text, and
its width and its height in pixels. -/
structure Area where
  /-- The text the view shows. -/
  snapshot : SnapshotId
  /-- The view's width, in pixels: where rows wrap. -/
  width : Nat
  /-- The height the rows are asked with, in pixels. -/
  height : Nat
  deriving DecidableEq, Repr

namespace Area

/-- The area of a view that shows `snapshot` in `rect`: its width, and its
whole height. This is the one definition that says which height a view's
rows are asked with (the module docs, "What is the display's, and
missing"). -/
def ofRect (snapshot : SnapshotId) (rect : Rect) : Area :=
  { snapshot, width := rect.width, height := rect.height }

/-- The rows the view shows from `anchor`. -/
def rows (area : Area) (anchor : Nat) : DisplayM (Array Display.Row) :=
  Display.rowsShown
    { snapshot := area.snapshot, width := area.width, height := area.height, anchor }

/-- Where the row that holds `position` starts; `position` itself in a view
that shows no row. -/
def rowStart (area : Area) (position : Nat) : DisplayM Nat :=
  return ((← area.rows position)[0]?.map (·.start)).getD position

/-- A position of the row `lines` rows from the one that holds `position`,
down when positive and up when negative, as an anchor: the move aims for
the row's start, and stops at the text's first and last row. No rows away,
it is where the position's own row starts. -/
def away (area : Area) (position : Nat) (lines : Int) : DisplayM Nat := do
  if lines == 0 then
    return ← area.rowStart position
  return (←
        Display.linesFrom
            { snapshot := area.snapshot, width := area.width, position, lines,
              goal := some 0 }).position

/-- A position of the row `lines` rows above the one that holds `position`,
as an anchor; the text's first row when there are fewer above. -/
def above (area : Area) (position lines : Nat) : DisplayM Nat :=
  area.away position (-(lines : Int))

/-- A position of the row `lines` rows below the one that holds `position`,
as an anchor; the text's last row when there are fewer below. -/
def below (area : Area) (position lines : Nat) : DisplayM Nat :=
  area.away position lines

/-- How many rows the view fits: the rows it shows from the text's start,
which are all of the text's rows when it has fewer. -/
def fits (area : Area) : DisplayM Nat :=
  return (← area.rows 0).size

end Area

/-- The follow policy (the module docs): where to place the scroll anchor of
a view that shows `shown` from its anchor, so that the row of the cursor at
`head` is among the rows shown with `margin` rows kept each side of it; none
to keep the anchor. `shown` is `area.rows` from the anchor, which the caller
asks. -/
def follow (area : Area) (margin : Nat) (shown : Array Display.Row) (head : Nat) :
    DisplayM (Option Nat) := do
  -- A view that shows no row has none to show the cursor in.
  let some first := shown[0]? | return none
  -- The rows from the cursor: the first is the cursor's row, and the rest
  -- are the rows of the text below it, as far as the view is tall.
  let under ← area.rows head
  let some row := under[0]? | return none
  let below := under.size - 1
  let index := shown.findIdx? (·.start == row.start)
  -- Whether the cursor's row is shown with `margin` rows each side of it.
  -- Below it the margin gives way to the text's end.
  let holds (margin : Nat) : Bool :=
    match index with
    | some index => index ≥ margin && shown.size - 1 - index ≥ min margin below
    | none => false
  -- The common case, which asks nothing more.
  if holds margin then
    return none
  -- The margin in force is at most half the rows the view fits. With no
  -- margin the rows shown stand for them: they are used only for a cursor
  -- below the rows shown, where the view is full.
  let size ←
    if margin == 0 then
      pure shown.size
    else
      area.fits
  let margin := min margin ((size - 1) / 2)
  if holds margin then
    return none
  -- The cursor's row is too near the top, or above it.
  let high :=
    match index with
    | some index => index < margin
    | none => row.start < first.start
  -- At the text's start there is no row above to show.
  if high && first.start == 0 then
    return none
  -- How many rows above the cursor's row the first row shown is to be.
  let up := if high then margin else size - 1 - min margin below
  let target ←
    if up == 0 then
      pure row.start
    else
      area.above row.start up
  return if target == first.start then none else some target

end Scroll

end Editor
