import Editor.Layout
import Editor.Scene

/-!
# Model tests: support: Geometry

Rectangles and the sample areas and window counts the layouts are checked over.
Shared by several test modules under `ModelTest/Editor/`; it holds no checks of
its own.
-/

namespace ModelTest

open Editor

/-- The rectangle of a frame of `size`, from its top left. -/
def frameRect (size : Size) : Rect :=
  { x := 0, y := 0, width := size.width, height := size.height }

/-- The area of `rect`. -/
def area (rect : Rect) : Nat :=
  rect.width * rect.height

/-- The area two rectangles share: none when they do not overlap. -/
def shared (first second : Rect) : Nat :=
  (min (first.x + first.width) (second.x + second.width) - max first.x second.x) *
    (min (first.y + first.height) (second.y + second.height) - max first.y second.y)

/-- Whether no two of `rects` share any area. -/
def disjoint : List Rect → Bool
  | [] => true
  | rect :: rest => rest.all (shared rect · == 0) && disjoint rest

/-- Whether `parts` tile `whole`: each is inside it, no two share any area,
and their areas sum to its area. -/
def tiles (whole : Rect) (parts : Array Rect) : Bool :=
  parts.all
      (fun part =>
        whole.x ≤ part.x && whole.y ≤ part.y && part.x + part.width ≤ whole.x + whole.width &&
          part.y + part.height ≤ whole.y + whole.height) &&
    disjoint parts.toList &&
    (parts.map area).foldl (· + ·) 0 == area whole

/-- Frame sizes for the tiling checks: even, odd, small and zero. -/
def sampleSizes : List Size :=
  [⟨640, 480⟩, ⟨641, 479⟩, ⟨7, 3⟩, ⟨1, 1⟩, ⟨0, 0⟩, ⟨0, 480⟩, ⟨640, 0⟩]

/-- The windows `0` to `count - 1`, in order. -/
def windowsUpTo (count : Nat) : Array ViewId :=
  (Array.range count).map (⟨·⟩)

/-- The rectangles the layout checks lay windows out in: each of
`sampleSizes`, at the frame's origin and away from it. -/
def sampleRects : List Rect :=
  sampleSizes.flatMap fun size =>
    [frameRect size, { x := 5, y := 7, width := size.width, height := size.height }]

/-- The trees of the manual split layout reached from one tile by up to
`splits` splits, each of any tile on either axis, and each then balanced
along its axis or not: every tree once per way of reaching it. -/
def splitsReached (splits : Nat) : List Splits :=
  (List.range splits).foldl
      (fun (all, last) _ =>
        let next :=
          last.flatMap fun tree =>
            (List.range tree.size).flatMap fun index =>
              [Axis.rows, .columns].flatMap fun axis =>
                let inserted := tree.insert index axis
                [inserted, inserted.balance (· == axis)]
        (all ++ next, next))
      ([Splits.tile], [Splits.tile]) |>.1

end ModelTest
