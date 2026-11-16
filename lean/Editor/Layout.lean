import Editor.Scene

/-!
# Layouts

How a frame's windows are arranged, as data: a `Layout` value turns the
ordered list of windows and the rectangle they tile into one rectangle per
window shown (`Layout.place`). It is a pure function, and touches nothing
outside, so it is no port.

- **Master-and-stack** (`Layout.masterStack`, the default): the first
  window of the list is main, and takes its share of the area on its side;
  the rest are the stack, which divides what is left the other way into
  equal parts. Its parameters are main's share, in percent, and its side
  (`MasterStack`).
- **Monocle** (`Layout.monocle`): the selected window takes the whole area,
  and the others get no rectangle.

The layouts cut in whole pixels and do not snap to text rows. `place` is
total and knows nothing of the editor state, so that layouts can later be
composed. Pinned by `ModelTest.layoutChecks`.
-/

namespace Editor

/-- The axis a rectangle is cut along. -/
inductive Axis where
  /-- One part above the other. -/
  | rows
  /-- One part beside the other. -/
  | columns
  deriving DecidableEq, Repr

/-- The edge of the tiled area main takes. -/
inductive Side where
  /-- Main is on the left, the stack on its right. -/
  | left
  /-- Main is on the right, the stack on its left. -/
  | right
  /-- Main is at the top, the stack below it. -/
  | top
  /-- Main is at the bottom, the stack above it. -/
  | bottom
  deriving DecidableEq, Repr

/-- The axis main is cut off the area along for a side: columns for `left`
and `right`, rows for `top` and `bottom`. -/
def Side.axis : Side → Axis
  | .left | .right => .columns
  | .top | .bottom => .rows

/-- The other axis than `axis`. -/
def Axis.across : Axis → Axis
  | .rows => .columns
  | .columns => .rows

/-- The parameters of master-and-stack. -/
structure MasterStack where
  /-- Main's share of the extent across the stack, in percent; above 100 is
  taken as 100. -/
  share : Nat := 50
  /-- The edge main takes. -/
  side : Side := .left
  deriving DecidableEq, Repr

/-- How a frame's windows are arranged. -/
inductive Layout where
  /-- The first window is main, on one side; the rest are the stack. -/
  | masterStack (parameters : MasterStack)
  /-- The selected window takes the whole area, and the others are not
  shown. -/
  | monocle
  deriving DecidableEq, Repr

namespace Layout

/-- The default layout: master-and-stack, main taking half on the left. -/
protected def default : Layout :=
  .masterStack {}

/-- What a master-and-stack layout whose share of main is `share`, above
100, is refused with when config chooses it (`layout`, `Editor/Setup.lean`):
a share is a percentage. -/
def shareTooLarge (share : Nat) : String :=
  s!"main's share of a master-and-stack layout must be at most 100 percent, not {share}"

/-- The extent of `rect` along `axis`: its height for rows, and its width for
columns. -/
def extent (axis : Axis) (rect : Rect) : Nat :=
  match axis with
  | .rows => rect.height
  | .columns => rect.width

/-- `rect` cut in two along `axis`: the first part takes `first` of its
extent along the axis, or all of it when that is less, and the second the
rest. -/
def cut (axis : Axis) (rect : Rect) (first : Nat) : Rect × Rect :=
  let first := min first (extent axis rect)
  match axis with
  | .rows =>
    ({ rect with height := first },
      { rect with
        y := rect.y + first, height := rect.height - first })
  | .columns =>
    ({ rect with width := first },
      { rect with
        x := rect.x + first, width := rect.width - first })

/-- `rect` divided along `axis` into `count` parts, in order: each takes
the extent divided by `count`, rounded down, and the first `extent % count`
take a pixel more, so the parts sum to the extent. No part for a count of
0. -/
def divide (axis : Axis) (rect : Rect) (count : Nat) : Array Rect :=
  Id.run do
    let whole := extent axis rect
    let mut rest := rect
    let mut parts := #[]
    for index in [0:count] do
      let (part, after) := cut axis rest (whole / count + if index < whole % count then 1 else 0)
      parts := parts.push part
      rest := after
    return parts

/-- The rectangle of each window shown of `windows`, laid out in `rect`, in
drawing order. `selected` is the window the user is working in, which
monocle shows.

- **Master-and-stack.** One window takes the whole rectangle. With two or
  more, the first, main, takes `extent * min share 100 / 100` of the extent
  along its side's axis (rounded down) on its `side`, and the stack, the
  rest of the windows in order, divides what is left the other way into
  equal parts, the first ones a pixel larger (`divide`). Every window gets
  exactly one rectangle, main first, and they tile `rect`.
- **Monocle.** `selected` takes the whole rectangle when it is in the list,
  and the first window otherwise. The other windows get none.

An empty list gives none. -/
def place : Layout → (windows : Array ViewId) → (selected : ViewId) → Rect → Array (ViewId × Rect)
  | .masterStack parameters, windows, _, rect =>
    match windows.toList with
    | [] => #[]
    | [only] => #[(only, rect)]
    | main :: stack =>
      let axis := parameters.side.axis
      let size := extent axis rect * min parameters.share 100 / 100
      let (inMain, inStack) :=
        match parameters.side with
        | .left | .top => cut axis rect size
        | .right | .bottom =>
          let (before, after) := cut axis rect (extent axis rect - size)
          (after, before)
      #[(main, inMain)] ++ stack.toArray.zip (divide axis.across inStack stack.length)
  | .monocle, windows, selected, rect =>
    if windows.contains selected then #[(selected, rect)] else (windows[0]?.map (·, rect)).toArray

end Layout

end Editor
