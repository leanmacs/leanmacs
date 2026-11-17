import Editor.Display
import Editor.Layout

/-!
# Floating windows

A float is a window of the frame kept apart from the tiled list and the
edges (`Frame.floats`, `Editor/State.lean`), drawn above them in stacking
order. This module is what a float is and where it goes: its anchor, its
size and the placement rule. It is pure, and every placement is total
over any rectangles.

- **An anchor** (`Floating.Anchor`) is what a float is placed against: the
  frame, centred in the area floats are kept in; a window, centred in that
  window's rectangle; or a position of a window's buffer, an anchor marker
  of its text, beside which the float goes. An anchor window is a tiled or
  docked window, never a float, so placement never recurses.
- **A size** (`Floating.Share`) is a share in percent of what the float is
  placed in: the area for the frame and a position, the window's rectangle
  for a window. It is the same unit as an edge's size and main's share,
  since Lean knows no column width and handles no scale. A resize steps it
  by 5 on one axis, clamped to 5..100 (`Share.resized`), so a float never
  shrinks to nothing.
- **Pinned or transient** (`Floating.pinned`). A pinned float stays until it
  is closed. A transient one closes when the focus leaves it or the window
  it was opened from, or when its anchor goes off screen
  (`Editor/State.lean`, "A floating window").
- **Where its position anchor was drawn** at the last publish is kept on the
  float (`Floating.spot`, in frame pixels), so the rectangles of a state
  (`EditorState.rects`) stay pure: the spot is the one answer of the
  display they read, and the publish keeps it (`Editor/Loop.lean`).

## Placement

- `centred share rect` is the share of `rect`, centred in it, rounded down.
- `beside share spot area` places a float against a position whose spot is
  `spot`, in frame pixels, its `height` its row's. A spot outside the area
  is clamped into it first.
  1. Its width and height are the shares of `area`.
  2. Across, it starts at the position, or shifted left just enough to stay
     inside the area.
  3. Down, it goes below the row when it fits there, and else above it,
     flipped, its bottom at the row's top, when it fits there.
  4. Else it goes on the side with more room, below on a tie, its height
     clamped to that room: corfu's and Vim's popup rule.

The area a float is kept in is the tiled area (`EditorState.tiled`), not
the whole frame, so a float never covers the echo row, the minibuffer's
view or a tab bar cut off the frame. `ModelTest.floatChecks` pins the
placement, by a property over areas, windows, spots anywhere in them, row
heights and shares, and by examples.
-/

namespace Editor

namespace Floating

/-- What a float is placed against. -/
inductive Anchor where
  /-- Centred in the area floats are kept in. -/
  | frame
  /-- Centred in the rectangle of the window `view`. -/
  | window (view : ViewId)
  /-- Beside a position of the buffer of the window `view`: `marker` is an
  anchor marker of that buffer's text. -/
  | position (view : ViewId) (marker : MarkerId)
  deriving DecidableEq, Repr

/-- The window an anchor is placed against, if it is one. -/
def Anchor.view? : Anchor → Option ViewId
  | .frame => none
  | .window view => some view
  | .position view _ => some view

/-- The marker a position anchor holds, if it is one. -/
def Anchor.marker? : Anchor → Option MarkerId
  | .position _ marker => some marker
  | _ => none

/-- A float's size, in percent of what it is placed in: the area for the
frame and a position, the window's rectangle for a window. -/
structure Share where
  /-- Across, in percent. -/
  width : Nat := 60
  /-- Down, in percent. -/
  height : Nat := 50
  deriving DecidableEq, Repr

/-- The least a share is on either axis, in percent. -/
def Share.least : Nat :=
  5

/-- The share with its width (`columns`) or its height (`rows`) grown or
shrunk by `steps` steps of 5 percent, clamped to 5..100 (`Share.least`), so
a float never shrinks to nothing. -/
def Share.resized (share : Share) (axis : Axis) (grow : Bool) (steps : Nat) : Share :=
  let moved (value : Nat) : Nat :=
    let value := if grow then value + 5 * steps else value - 5 * steps
    max Share.least (min 100 value)
  match axis with
  | .columns => { share with width := moved share.width }
  | .rows => { share with height := moved share.height }

/-- `share` percent of `extent`, at most the whole. -/
def Share.of (share extent : Nat) : Nat :=
  extent * min share 100 / 100

/-- The share `share` of `rect`, centred in it, rounded down. -/
def centred (share : Share) (rect : Rect) : Rect :=
  let width := Share.of share.width rect.width
  let height := Share.of share.height rect.height
  { x := rect.x + (rect.width - width) / 2, y := rect.y + (rect.height - height) / 2, width
    height }

/-- A float of `share` of `area`, placed against a position drawn at `spot`
(in frame pixels, its `height` its row's), inside `area` (the module docs,
"Placement"). -/
def beside (share : Share) (spot : Display.Spot) (area : Rect) : Rect :=
  let right := area.x + area.width
  let bottom := area.y + area.height
  let width := Share.of share.width area.width
  let height := Share.of share.height area.height
  -- The spot clamped into the area, so the placement stays total.
  let top := max area.y (min spot.y bottom)
  let rowBottom := min bottom (top + spot.height)
  let x := max area.x (min (max area.x (min spot.x right)) (right - width))
  let below := bottom - rowBottom
  let above := top - area.y
  if height ≤ below then { x, y := rowBottom, width, height }
  else
    if height ≤ above then { x, y := top - height, width, height }
    else
      if above ≤ below then { x, y := rowBottom, width, height := below }
      else { x, y := area.y, width, height := above }

end Floating

/-- A floating window: a window of the frame kept apart from the tiled list
and the edges, above them. -/
structure Floating where
  /-- The window. -/
  view : ViewId
  /-- What it is placed against. -/
  anchor : Floating.Anchor
  /-- Its size. -/
  share : Floating.Share := {}
  /-- Pinned floats stay until closed; transient ones close when the focus
  leaves them or their anchor goes off screen. -/
  pinned : Bool := false
  /-- Where its position anchor was drawn at the last publish, in frame
  pixels; none until it has been, and for other anchors. -/
  spot : Option Display.Spot := none
  deriving DecidableEq, Repr

/-- Where `float` goes, in `area` (the tiled area), given the rectangles
`laid` the layout gave the tiles and the docked windows: centred in the
area for the frame; centred in its window's rectangle for a window, or in
the area when the window has none (monocle hides it); beside its spot for a
position, or as for its window before it has a spot. -/
def Floating.placed (float : Floating) (area : Rect) (laid : Array (ViewId × Rect)) : Rect :=
  let inWindow (view : ViewId) : Rect :=
    match laid.find? (·.1 == view) with
    | some (_, rect) => Floating.centred float.share rect
    | none => Floating.centred float.share area
  match float.anchor with
  | .frame => Floating.centred float.share area
  | .window view => inWindow view
  | .position view _ =>
    match float.spot with
    | some spot => Floating.beside float.share spot area
    | none => inWindow view

end Editor
