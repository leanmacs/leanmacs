import Editor.Scene

/-!
# Layouts

How a frame's windows are arranged, as data: a `Layout` value turns the
ordered list of windows and the rectangle they tile into one rectangle per
window shown (`Layout.place`). It is a pure function, and touches nothing
outside, so it is no port.

- **Master-and-stack** (`Layout.masterStack`, the default): the first
  `count` windows of the list are main, and take its share of the area on
  its side; the rest are the stack. Each part is divided the other way into
  equal parts. Its parameters are main's share, in percent, its side and
  main's count (`MasterStack`). With a count of 0, or of as many windows as
  there are or more, every window divides the whole area that way, as
  xmonad's `Tall` does.
- **Monocle** (`Layout.monocle`): the selected window takes the whole area,
  and the others get no rectangle.
- **Manual splits** (`Layout.splits`, `Layout.manual`): a binary tree of
  anonymous tiles (`Splits`), each split cutting its rectangle on an axis
  between two weighted parts. `place` gives the windows of the list to the
  tiles in order, left to right through the tree, the order Vim numbers
  its windows in. So the list stays the one record of which windows exist,
  and the tree is only the shape: list order is screen order, and the list
  operations (promote, demote, rotate, exchange) move windows between
  tiles while the shape stays.

## The manual split tree, read as Vim's frames

The operations follow Vim 9.1's frames. A binary tree is read as Vim's
n-ary frames: a chain of splits on one axis is one row or column of parts,
its *group*.

- **`Splits.insert i axis`** replaces tile `i` with two tiles split along
  `axis`. Vim's `win_split` adds a part to the group when the axes agree,
  and the two readings are the same tiling.
- **`Splits.remove i`** replaces tile `i`'s parent with its sibling, and
  says which tile inherits its place: the first tile of the next part of
  its group when there is one, index `i` after the removal (Vim's
  `win_altframe` under `nosplitbelow` and `nosplitright`), and otherwise
  the last tile of the previous part, index `i - 1`; and the group's axis.
- **`Splits.balance along`** sets every split on an axis `along` keeps to
  the slot counts of its two parts along that axis, as Vim's `win_equal`
  shares out a frame: a tile counts 1, a split on the same axis the sum of
  its parts', and one on the other axis the larger of its parts'.
- **`Splits.resize i axis grow steps`** moves the boundary of the deepest
  split on `axis` that holds tile `i` by `5 * steps` percent of its
  extent, growing tile `i`'s part when `grow` and shrinking it otherwise,
  clamped to 0 and 100; none when no split on `axis` holds the tile.
- **A split's two parts** are its weights: `before` takes
  `extent * first / (first + second)` along its axis, rounded down, or
  half when both are 0, and `after` the rest.
- **A tree is fitted to the list** (`Splits.fit`): one whose tiles are as
  many as the windows is kept, and any other is replaced by as many even
  rows (`Splits.even`), as `vim -o` opens them. So `place` is total, and a
  config that chooses the layout, which knows no windows, writes only a
  shape.
- **`equalalways`**, Vim's default with `eadirection=both`, is the
  caller's: after an insert the tree is balanced along the split's axis,
  and after a removal along the removed tile's group axis (`Layout.inserted`,
  `Layout.removed`). A recorded departure: Vim leaves the other windows
  alone when none is larger than the two new ones, and here they are
  always balanced, which shows only after a resize.

## A layout's operations

The editor state applies each change of its window list to the layout
through these, so a layout's parameters follow its windows:

| Operation | Master-and-stack | Monocle | Manual splits |
|---|---|---|---|
| `inserted index placement` | Unchanged | Unchanged | Tile `index` split along the placement's axis, then balanced along it |
| `removed index` | Unchanged, and no inheritor | Unchanged, and no inheritor | `Splits.remove`, balanced along the group's axis, with its inheritor |
| `balanced` | Main's share back to 50 | Unchanged | Balanced along both axes |
| `resized index n axis grow steps` | Main's share by `5 * steps` along its side's axis only, with `n ≥ 2` and `0 < count < n`; none otherwise | None | `Splits.resize` |
| `rotated windows forward` | The stack, the windows after main's, rotated; main stays | The whole list rotated | The whole list rotated |
| `fits n` | Unchanged | Unchanged | Its tree fitted to `n` |

A split's placement (`Placement`) is read only under manual splits: under
the other two a new window goes right after its source, so the stack grows
and main is left alone.

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
  /-- How many of the first windows are main's: with 0, or with as many as
  there are windows or more, every window divides the whole area. -/
  count : Nat := 1
  deriving DecidableEq, Repr

/-- The shape of the manual split layout: a binary tree of anonymous
tiles. -/
inductive Splits where
  /-- One window: the next of the list, in order. -/
  | tile
  /-- The rectangle cut along `axis` into `before` and `after`, whose
  extents along it are as `first` is to `second`. -/
  | split (axis : Axis) (first second : Nat) (before after : Splits)
  deriving DecidableEq, Repr

/-- Where a split puts the new window, under manual splits. -/
structure Placement where
  /-- Rows: one above the other (Vim's `C-w s`); columns: side by side
  (`C-w v`). -/
  axis : Axis := .rows
  /-- Whether the new window goes before its source, above or left of it:
  Vim's `nosplitbelow` and `nosplitright`. -/
  before : Bool := false
  deriving DecidableEq, Repr

/-- How a frame's windows are arranged. -/
inductive Layout where
  /-- The first windows are main, on one side; the rest are the stack. -/
  | masterStack (parameters : MasterStack)
  /-- The selected window takes the whole area, and the others are not
  shown. -/
  | monocle
  /-- The windows of the list take the tiles of `tree` in order. -/
  | splits (tree : Splits)
  deriving DecidableEq, Repr

/-- The extent of `rect` along `axis`: its height for rows, and its width for
columns. -/
def Layout.extent (axis : Axis) (rect : Rect) : Nat :=
  match axis with
  | .rows => rect.height
  | .columns => rect.width

/-- `rect` cut in two along `axis`: the first part takes `first` of its
extent along the axis, or all of it when that is less, and the second the
rest. -/
def Layout.cut (axis : Axis) (rect : Rect) (first : Nat) : Rect × Rect :=
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

namespace Splits

/-- How many tiles the tree has. -/
def size : Splits → Nat
  | tile => 1
  | split _ _ _ before after => before.size + after.size

/-- `count` tiles in a row along `axis`, of equal extent: one tile for a
count of 0 or 1. -/
def even (axis : Axis) : Nat → Splits
  | 0 | 1 => tile
  | count + 1 => split axis 1 count tile (even axis count)

/-- The tree when its tiles are `count`, and otherwise `count` even rows. -/
def fit (tree : Splits) (count : Nat) : Splits :=
  if tree.size == count then tree else even .rows count

/-- The rectangle of each tile, in order, laid out in `rect`: a split gives
`before` its share of the extent along its axis by its weights, rounded
down, or half when both weights are 0, and `after` the rest. -/
def rects : Splits → Rect → Array Rect
  | tile, rect => #[rect]
  | split axis first second before after, rect =>
    let whole := Layout.extent axis rect
    let size := if first + second == 0 then whole / 2 else whole * first / (first + second)
    let (inBefore, inAfter) := Layout.cut axis rect size
    before.rects inBefore ++ after.rects inAfter

/-- The tree with tile `index` split along `axis` into two tiles of equal
weight; the tree as it was for an index past its tiles. -/
def insert : Splits → (index : Nat) → Axis → Splits
  | tile, 0, axis => split axis 1 1 tile tile
  | tile, _ + 1, _ => tile
  | split along first second before after, index, axis =>
    if index < before.size then split along first second (before.insert index axis) after
    else split along first second before (after.insert (index - before.size) axis)

/-- The tree with tile `index` gone, its parent replaced by its sibling;
none for a single tile and for an index past the tiles. -/
def removeTile : Splits → Nat → Option Splits
  | tile, _ => none
  | split axis first second before after, index =>
    if index < before.size then
      match before with
      | tile => some after
      | _ => (before.removeTile index).map (split axis first second · after)
    else
      match after with
      | tile => if index == before.size then some before else none
      | _ => (after.removeTile (index - before.size)).map (split axis first second before ·)

/-- The axis of tile `index`'s parent split; none for a single tile and for
an index past the tiles. -/
def parentAxis? : Splits → Nat → Option Axis
  | tile, _ => none
  | split axis _ _ before after, index =>
    if index < before.size then
      match before with
      | tile => some axis
      | _ => before.parentAxis? index
    else
      match after with
      | tile => if index == before.size then some axis else none
      | _ => after.parentAxis? (index - before.size)

/-- Whether tile `index` is the last part of its group: the chain of splits
on its parent's axis that holds it, read as one of Vim's frames. `chain` is
the axis of the group the tree is a part of, if any, and `last` whether the
tree is that group's last part. -/
def lastOfGroup : Splits → (index : Nat) → (chain : Option Axis) → (last : Bool) → Bool
  | tile, _, _, last => last
  | split axis _ _ before after, index, chain, last =>
    if index < before.size then before.lastOfGroup index (some axis) false
    else
      after.lastOfGroup (index - before.size) (some axis)
        (if chain == some axis then last else true)

/-- Tile `index` removed (`removeTile`), with the index, after the removal,
of the tile that inherits its place, and the axis of its group: the first
tile of the next part of its group, which is index `index`, or, when it was
the group's last part, the last tile of the previous part, index
`index - 1`. None for a single tile and for an index past the tiles. -/
def remove (tree : Splits) (index : Nat) : Option (Splits × Nat × Axis) := do
  let removed ← tree.removeTile index
  let axis ← tree.parentAxis? index
  let inheritor := if tree.lastOfGroup index none false then index - 1 else index
  return (removed, inheritor, axis)

/-- How many slots `tree` takes along `axis`, as Vim's `win_equal` counts
them: a tile one, a split on `axis` the sum of its parts', and one on the
other axis the larger of its parts'. -/
def slots (axis : Axis) : Splits → Nat
  | tile => 1
  | split along _ _ before after =>
    if along == axis then before.slots axis + after.slots axis
    else max (before.slots axis) (after.slots axis)

/-- The tree with every split on an axis `along` keeps weighted by the
slots of its two parts along that axis (`slots`). -/
def balance (along : Axis → Bool) : Splits → Splits
  | tile => tile
  | split axis first second before after =>
    let (first, second) :=
      if along axis then (before.slots axis, after.slots axis) else (first, second)
    split axis first second (before.balance along) (after.balance along)

/-- The weights of a split whose `before` part's share, in percent, moves
by `5 * steps`: up when the tile is in `before` and grows, or is in `after`
and shrinks, and down otherwise, clamped to 0 and 100. -/
def moved (first second : Nat) (inBefore grow : Bool) (steps : Nat) : Nat × Nat :=
  let share := if first + second == 0 then 50 else first * 100 / (first + second)
  let share := if inBefore == grow then min 100 (share + 5 * steps) else share - 5 * steps
  (share, 100 - share)

/-- The tree with the boundary of the deepest split on `axis` that holds
tile `index` moved by `5 * steps` percent of its extent, growing the tile's
part when `grow` and shrinking it otherwise (`moved`); none when no split
on `axis` holds the tile. -/
def resize : Splits → (index : Nat) → Axis → (grow : Bool) → (steps : Nat) → Option Splits
  | tile, _, _, _, _ => none
  | split along first second before after, index, axis, grow, steps =>
    let inBefore := index < before.size
    let deeper :=
      if inBefore then (before.resize index axis grow steps).map (split along first second · after)
      else
        (after.resize (index - before.size) axis grow steps).map (split along first second before ·)
    match deeper with
    | some tree => some tree
    | none =>
      if along == axis && index < before.size + after.size then
        let (first, second) := moved first second inBefore grow steps
        some (split along first second before after)
      else none

end Splits

/-- `windows` with the windows after its first `skip` rotated: forward,
the last of them becomes the first and the rest move one on, as Vim's
`C-w r`; back, the reverse. -/
private def rotateTail (windows : Array ViewId) (skip : Nat) (forward : Bool) : Array ViewId :=
  let kept := windows.extract 0 skip
  let rest := windows.extract skip windows.size
  match forward, rest.back?, rest[0]? with
  | true, some last, _ => kept ++ #[last] ++ rest.pop
  | false, _, some first => kept ++ rest.extract 1 rest.size |>.push first
  | _, _, _ => windows

namespace Layout

/-- The default layout: master-and-stack, main taking half on the left. -/
protected def default : Layout :=
  .masterStack {}

/-- The manual split layout of one tile, which a split's operations grow;
fitted to the windows it is given (`Splits.fit`). -/
def manual : Layout :=
  .splits .tile

/-- What a master-and-stack layout whose share of main is `share`, above
100, is refused with when config chooses it (`layout`, `Editor/Setup.lean`):
a share is a percentage. -/
def shareTooLarge (share : Nat) : String :=
  s!"main's share of a master-and-stack layout must be at most 100 percent, not {share}"

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

- **Master-and-stack.** With `0 < count < n` for `n` windows, main takes
  `extent * min share 100 / 100` of the extent along its side's axis
  (rounded down) on its `side`, and the stack what is left. The first
  `count` windows divide main's part the other way into equal parts, the
  first ones a pixel larger (`divide`), and the rest of the windows, in
  order, divide the stack's. With a count of 0, or of `n` or more, all the
  windows divide the whole rectangle that way. Every window gets exactly
  one rectangle, in list order, and they tile `rect`.
- **Monocle.** `selected` takes the whole rectangle when it is in the list,
  and the first window otherwise. The other windows get none.
- **Manual splits.** The tree, fitted to the windows (`Splits.fit`), gives
  its tiles' rectangles (`Splits.rects`) to the windows in list order.

An empty list gives none. -/
def place : Layout → (windows : Array ViewId) → (selected : ViewId) → Rect → Array (ViewId × Rect)
  | .masterStack parameters, windows, _, rect =>
    let axis := parameters.side.axis
    let count := parameters.count
    if count == 0 || count ≥ windows.size then windows.zip (divide axis.across rect windows.size)
    else
      let size := extent axis rect * min parameters.share 100 / 100
      let (inMain, inStack) :=
        match parameters.side with
        | .left | .top => cut axis rect size
        | .right | .bottom =>
          let (before, after) := cut axis rect (extent axis rect - size)
          (after, before)
      (windows.extract 0 count).zip (divide axis.across inMain count) ++
        (windows.extract count windows.size).zip (divide axis.across inStack (windows.size - count))
  | .monocle, windows, selected, rect =>
    if windows.contains selected then #[(selected, rect)] else (windows[0]?.map (·, rect)).toArray
  | .splits tree, windows, _, rect => windows.zip ((tree.fit windows.size).rects rect)

/-- The layout once tile `index`, the source window's index in a list of
windows the layout fits, was split by `placement`: under manual splits the
tile is split along the placement's axis and the tree balanced along it,
as Vim's `equalalways` does; the other layouts read no placement and are
unchanged. -/
def inserted (layout : Layout) (index : Nat) (placement : Placement) : Layout :=
  match layout with
  | .splits tree => .splits ((tree.insert index placement.axis).balance (· == placement.axis))
  | other => other

/-- The layout once the window at `index` of a list of windows the layout
fits was removed, and the index, after the removal, of the window that
inherits its place, if the layout says one: under manual splits the tile is
removed (`Splits.remove`) and the tree balanced along its group's axis, as
Vim's `equalalways` does. The other layouts are unchanged and say none. -/
def removed (layout : Layout) (index : Nat) : Layout × Option Nat :=
  match layout with
  | .splits tree =>
    match tree.remove index with
    | some (removed, inheritor, axis) => (.splits (removed.balance (· == axis)), some inheritor)
    | none => (layout, none)
  | other => (other, none)

/-- The layout with its windows made equal, as Vim's `C-w =`: under manual
splits every split balanced along both axes, and under master-and-stack
main's share back to 50, so main's part and the stack's are equal. Monocle
is unchanged. -/
def balanced : Layout → Layout
  | .splits tree => .splits (tree.balance fun _ => true)
  | .masterStack parameters => .masterStack { parameters with share := 50 }
  | .monocle => .monocle

/-- The layout with the window at `index` of `size` windows grown or shrunk
along `axis` by `steps` steps of 5 percent; none when it cannot be.

- **Manual splits**: `Splits.resize`.
- **Master-and-stack**: only along its side's axis, with at least two
  windows and `0 < count < size`. Main's share, above 100 read as 100,
  grows by `5 * steps` when the window is in main and grows, or is in the
  stack and shrinks, and shrinks otherwise, clamped to 0 and 100.
- **Monocle**: none. -/
def resized (layout : Layout) (index size : Nat) (axis : Axis) (grow : Bool) (steps : Nat) :
    Option Layout :=
  match layout with
  | .splits tree => (tree.resize index axis grow steps).map .splits
  | .masterStack parameters =>
    if
        axis == parameters.side.axis && 2 ≤ size && 0 < parameters.count &&
          parameters.count < size then
      let share := min parameters.share 100
      let inMain := index < parameters.count
      let share := if inMain == grow then min 100 (share + 5 * steps) else share - 5 * steps
      some (.masterStack { parameters with share })
    else none
  | .monocle => none

/-- `windows` rotated as the layout defines: under master-and-stack the
stack, the windows after main's `count`, rotates and main stays; under
manual splits and monocle the whole list rotates. Forward, the last window
rotated becomes the first and the rest move one on, as Vim's `C-w r`; back
the reverse, as `C-w R`. -/
def rotated (layout : Layout) (windows : Array ViewId) (forward : Bool) : Array ViewId :=
  match layout with
  | .masterStack parameters => rotateTail windows (min parameters.count windows.size) forward
  | _ => rotateTail windows 0 forward

/-- The layout fitted to `count` windows: under manual splits its tree is
fitted (`Splits.fit`); the others are unchanged. -/
def fits (layout : Layout) (count : Nat) : Layout :=
  match layout with
  | .splits tree => .splits (tree.fit count)
  | other => other

end Layout

end Editor
