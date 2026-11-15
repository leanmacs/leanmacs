import Editor.Display

/-!
# Scrolling: how a view follows its cursor, and where a scroll puts it

A view shows its text from a scroll anchor: a position of the text, and the
rows shown start at the visual row that holds it. This module is the policy
that says where the anchor goes. It is programs over the display port
(`Editor/Display.lean`) and arithmetic on what they answer. It holds no
state, reads no text and places nothing: it is handed offsets and answers
the offset to place the anchor at, or none to keep it, and its callers read
and place the anchor's marker (the command loop before each scene,
`Editor/Loop.lean`, and the commands that scroll).

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
- **A view that shows its whole text keeps the margin as set**, not half
  the rows it fits ("A view that shows its whole text", below). Such a
  view scrolled away from the text's start, as `z t` leaves it, is brought
  back until the margin's rows are above the cursor's row, or to the
  text's first row where it has fewer.
- **At the text's start and end the margin gives way.** The first row shown
  cannot be above the text's first row, and a cursor fewer than the margin
  from the text's last row keeps as many rows below it as the text has.

## The anchors a scroll places

A command that scrolls asks here where its anchor goes, in the same way:

- **By rows** (`Scroll.down`, `Scroll.up`): the anchor moves the rows
  asked. Going down it stops where the text's last row is the last row
  shown, and never moves up; going up it stops at the text's first row.
  How many rows a scroll is, for half a view and for a view and with a
  count, is `Scroll.Amount.rows`.
- **To the cursor's row** (`Scroll.lineTo`): the anchor that puts the
  cursor's row first, in the middle of the rows the view fits (the upper of
  two when it fits an even number), or last. Near the text's start the
  anchor stops at the first row, so the cursor's row cannot be put in the
  middle or at the bottom there; near its end the view shows past the
  text's end. To the middle, in a view that shows its whole text, the
  anchor is the text's first row ("A view that shows its whole text").

Each answers none in a view that shows no row. None of them reads the
margin: the follow that comes before the next scene holds it.

## A view that shows its whole text

How many rows a view has room for is not asked of the display: it answers
the rows shown from an anchor, and `Area.fits`, the rows shown from the
text's start, is the text's rows where the text has fewer than the view
has room for. Half of that number is not half the view. In a view of ten
rows over a text of four, the middle of four would put the anchor on the
text's third row for a cursor on its fourth, and hide two rows that fit.

So a view that shows its whole text from its start (`Area.whole`: the text
has no row after the last row shown from there) is treated on its own:

- **A scroll to the middle places the text's first row.** No row of a text
  that fits its view is scrolled out of sight by `z z`.
- **The follow keeps the margin as set**, as above.
- **A scroll by rows and a scroll to the bottom need nothing**: with the
  text's rows as the rows the view fits, a scroll down places none, and a
  scroll to the bottom places the text's first row.
- **A scroll to the top** still places the cursor's row, and shows past
  the text's end.

**A departure: a text that fills its view exactly is treated as one
shorter than it.** The two cannot be told apart from what the queries
answer. Both show the same rows from the text's start, and the text has no
row after them whose place could say whether the view has room for one
more. Asking the rows again with other heights would count the pixels of
the rows there are and assume the same of rows there are not, which the
contract does not say and real rows do not hold to. So of the two readings
the one taken is the one that never hides a row that would fit. In a view
its text fills exactly, the view's middle is known and is not used: `z z`
on the last of ten rows in a view of ten keeps the anchor at the first
row, where Vim shows from the sixth, and a margin of 99 brings a view of
five rows scrolled to the third of five, with the cursor on the fifth, back
to the first, where half the view would keep it. A text one row longer than its view is not affected.

## What is asked

Layout is the display's, and nothing of it is kept here between two
questions. The two queries of the display port are all that is asked:

- `Display.rowsShown`, three ways: from the view's anchor (the rows shown,
  which the caller asks and hands in), from the cursor (the cursor's row,
  and how many rows of the text are below it, as far as the view is tall),
  and from the text's start (the rows the view fits, `Area.fits`);
- `Display.linesFrom`, aiming for the row's start (`goal := some 0`): the
  row some rows above or below a position, as an anchor (`Area.above`,
  `Area.below`). A command that moves its cursor by rows asks the same
  query itself, with no goal, so that the move aims for the cursor's own
  x.

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
| The same, in a view scrolled from the text's start that shows fewer rows than it fits | 2 more: whether it shows its whole text |

A scroll by rows is one move going up and two going down, after the rows
the view fits, which its caller asks. A scroll to the cursor's row is one
request to the top, and two to the middle and to the bottom; to the
middle it is two more where the anchor would leave the text's first row,
which ask whether the view shows its whole text.

Not done: answering "is the cursor shown" from the rows shown alone, which
would write the display's wrap rule here for one request a view; and
remembering that a view was fine until something changed, which is a
verdict of layout kept in Lean, stale when layout changes for a reason Lean
does not see.

## What is the display's

- **The height of a view's text area.** The rows query takes a height, and
  the display's frame gives a view's bottom row to its status line, or to
  the prompt for the minibuffer's view. The display answers those rows'
  heights (`Display.heights`), which the state keeps, so a view is asked
  about with its height less its bottom row (`Area.ofRect`, the one
  definition that says which height, handed `EditorState.bottomRow`). Over
  real layout the rows query then answers exactly the rows the frame shows
  (`crates/editor-layout/tests/heights.rs`).

## What is missing

- **How many rows fit a view.** The display answers the rows shown from an
  anchor, which are fewer at the text's end. `Area.fits` is the rows shown
  from the text's start: the rows that fit, or all of the text's rows when
  it has fewer. It is right where rows are one height, which is the
  model's.
- **How many rows a view has room for**, where its text has fewer, or
  exactly as many. With it the middle of a view taller than its text would
  be known, and a text that fills its view would be told from a shorter
  one. Without it a view that shows its whole text is treated as taller
  than the text ("A view that shows its whole text", the departure).

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

/-- The area of a view that shows `snapshot` in `rect`, whose bottom row is
`bottom` tall: its width, and its height less that row. This is the one
definition that says which height a view's rows are asked with (the module
docs, "What is the display's"); the bottom row's height is the state's
(`EditorState.bottomRow`). -/
def ofRect (snapshot : SnapshotId) (rect : Rect) (bottom : Nat) : Area :=
  { snapshot, width := rect.width, height := rect.height - bottom }

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

/-- Whether the view shows the whole text from its start, where `fitted` is
the rows it shows from there (`area.rows 0`): whether the text has no row
after the last of them. It is asked as a move one row down from that row,
which stops on it where it is the text's last, and the row the move's answer
is in. False of a view that shows no row.

True both of a text shorter than its view and of one that fills it exactly:
the two are not told apart (the module docs, "What is the display's, and
missing"). -/
def whole (area : Area) (fitted : Array Display.Row) : DisplayM Bool := do
  let some last := fitted.back? | return false
  return (← area.rowStart (← area.below last.start 1)) == last.start

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
  let fitted ←
    if margin == 0 then
      pure shown
    else
      area.rows 0
  let size := fitted.size
  -- A view that shows its whole text keeps the margin as set: the rows it
  -- fits are then the text's rows, which may be fewer than the view's, and
  -- half of them would hide rows the margin asks for. Only a view scrolled
  -- away from the text's start that shows fewer rows than fit from there
  -- can be one, so only that is asked.
  let whole ←
    if margin != 0 && first.start != 0 && shown.size < size then
      area.whole fitted
    else
      pure false
  let margin := if whole then margin else min margin ((size - 1) / 2)
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

/-- How far a scroll by rows goes. -/
inductive Amount where
  /-- Half the rows the view fits. -/
  | half
  /-- The rows the view fits. -/
  | page
  deriving DecidableEq, Repr

/-- How many rows a scroll of `amount` is in a view that fits `fits` rows,
with the count `count` typed before it, 0 for none. Half a view is half the
rows it fits and at least one row, and a count typed before it is the rows
themselves. A view is the rows it fits, a count times over. -/
def Amount.rows : Amount → (count fits : Nat) → Nat
  | .half, count, fits => if count == 0 then max 1 (fits / 2) else count
  | .page, count, fits => max 1 count * fits

/-- Where in a view a scroll to the cursor's row puts that row. -/
inductive Place where
  /-- The first row shown. -/
  | top
  /-- The middle row of those the view fits, the upper of two. -/
  | middle
  /-- The last row shown. -/
  | bottom
  deriving DecidableEq, Repr

/-- Where a scroll down by `rows` rows places the anchor of a view whose
anchor is at `anchor` and which fits `fits` rows (`Area.fits`, which the
caller asks once); none to keep it. The anchor moves that many rows, and no
further than where the text's last row is the last row shown; it never
moves up. None in a view that fits no row.

It is asked as the row `fits - 1 + rows` below the anchor, which stops at
the text's last row, and then the row `fits - 1` above that. -/
def down (area : Area) (anchor rows fits : Nat) : DisplayM (Option Nat) := do
  if fits == 0 then
    return none
  let last ← area.below anchor (fits - 1 + rows)
  let target ← area.above last (fits - 1)
  return if target ≤ anchor then none else some target

/-- Where a scroll up by `rows` rows places the anchor of a view whose
anchor is at `anchor` and which fits `fits` rows; none to keep it. The
anchor moves that many rows and stops at the text's first row. None in a
view that fits no row. -/
def up (area : Area) (anchor rows fits : Nat) : DisplayM (Option Nat) := do
  if fits == 0 then
    return none
  let target ← area.above anchor rows
  return if target == anchor then none else some target

/-- Where a scroll that puts the row of the cursor at `head` at `place`
places the anchor; none in a view that shows no row. To the top it is where
the cursor's row starts; to the middle `(fits - 1) / 2` rows above that, and
to the bottom `fits - 1` rows above it, for the rows the view fits
(`Area.fits`), and the text's first row where it has fewer rows above the
cursor.

The rows the view fits, and not the rows it shows: after a scroll to the
top on the text's last line the view shows one row, and with that as its
rows a scroll to the bottom would do nothing.

To the middle, in a view that shows its whole text from its start
(`Area.whole`), it is the text's first row: the rows the view fits are then
the text's rows, which may be fewer than the view's, and their middle would
scroll rows out of sight that fit. It is asked only where the anchor would
leave the text's first row. -/
def lineTo (place : Place) (area : Area) (head : Nat) : DisplayM (Option Nat) := do
  if place == .top then
    return (← area.rows head)[0]?.map (·.start)
  let fitted ← area.rows 0
  let some first := fitted[0]? | return none
  let fits := fitted.size
  let target ← area.above head (if place == .middle then (fits - 1) / 2 else fits - 1)
  if place == .middle && target != first.start && (← area.whole fitted) then
    return some first.start
  return some target

end Scroll

end Editor
