import Editor.Display
import Editor.Floating
import Editor.Layout
import Editor.Scene
import ModelTest.Check
import ModelTest.Support.Geometry

/-!
# Model tests: `Editor/Floating.lean`

The model tests of `Editor/Floating.lean`: `floatChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- Whether `rect` is inside `area`. -/
def inside (area rect : Rect) : Bool :=
  area.x ≤ rect.x && area.y ≤ rect.y && rect.x + rect.width ≤ area.x + area.width &&
    rect.y + rect.height ≤ area.y + area.height

/-- Whether the float `Floating.beside` places for `share` against `spot`
in `area` keeps the placement rule (`Editor/Floating.lean`, "Placement"):
inside the area; against the row, its top the row's bottom or its bottom
the row's top, sharing no pixel with the row's band; at the spot's x, or
with its right edge the area's when the spot's would overflow, and never
right of the spot; the share of the area wide; and the share tall whenever
that fits on either side, below whenever it fits below. The spot is
clamped into the area first, as the placement clamps it. -/
def besideHolds (share : Floating.Share) (spot : Display.Spot) (area : Rect) : Bool :=
  let placed := Floating.beside share spot area
  let right := area.x + area.width
  let bottom := area.y + area.height
  let x := max area.x (min spot.x right)
  let top := max area.y (min spot.y bottom)
  let rowBottom := min bottom (top + spot.height)
  let width := Floating.Share.of share.width area.width
  let height := Floating.Share.of share.height area.height
  let below := bottom - rowBottom
  let above := top - area.y
  inside area placed && (placed.y == rowBottom || placed.y + placed.height == top) &&
    (placed.y + placed.height ≤ top || rowBottom ≤ placed.y) &&
    (if x + width ≤ right then placed.x == x else placed.x + placed.width == right) &&
    placed.x ≤ x &&
    placed.width == width &&
    if height ≤ below then placed.height == height && placed.y == rowBottom
    else if height ≤ above then placed.height == height else true

/-- The checks of the placement of a float (`Editor/Floating.lean`): beside a
position, as a property over areas, windows in them, spots anywhere in
those windows, row heights and shares, and by examples; centred; and a
share resized. -/
def floatChecks : List Check :=
  let rect (x y width height : Nat) : Rect := { x, y, width, height }
  let percents := [0, 1, 25, 50, 60, 100]
  let shares : List Floating.Share :=
    percents.flatMap fun width => percents.map fun height => { width, height }
  let area := rect 0 0 640 464
  [{  name :=
        "criterion 1: a float beside a position is inside the area, against the row and clear of it, at the position or shifted left just enough, the share wide, and the share tall below when it fits there and above when it fits there, for spots at the left, middle and last pixel and at the top, middle and last row of the area and of each window master-and-stack gives one to three windows in it, rows 1, 16 and the window tall, every share from 0 to 100 on each axis, at even, odd, small and zero sizes"
      run :=
        pure <|
          sampleRects.all fun area =>
            let windows :=
              area ::
                (List.range 3).flatMap fun count =>
                  (Layout.default.place (windowsUpTo (count + 1)) ⟨0⟩ area).toList.map (·.2)
            windows.all fun window =>
              let xs := [window.x, window.x + window.width / 2, window.x + window.width - 1]
              [1, 16, window.height].all fun height =>
                let ys :=
                  [window.y, window.y + window.height / 2, window.y + window.height - height]
                xs.all fun x =>
                  ys.all fun y => shares.all fun share => besideHolds share { x, y, height } area },
    { name :=
        "a float beside a position: below the row at the position, flipped above a row near the area's bottom, shifted left near its right, and on the larger side clamped when neither side holds it"
      run :=
        pure <|
          let quarter : Floating.Share := { width := 50, height := 25 }
          let tall : Floating.Share := { width := 50, height := 100 }
          Floating.beside quarter { x := 40, y := 40, height := 16 } area == rect 40 56 320 116 &&
            Floating.beside quarter { x := 40, y := 424, height := 16 } area ==
              rect 40 308 320 116 &&
            Floating.beside quarter { x := 568, y := 40, height := 16 } area ==
              rect 320 56 320 116 &&
            Floating.beside tall { x := 40, y := 100, height := 16 } area == rect 40 116 320 348 &&
            Floating.beside tall { x := 40, y := 400, height := 16 } area == rect 40 0 320 400 },
    { name := "a float centred: 60 by 50 percent of 640 by 464 is 384 by 232 at 128, 116"
      run := pure <| Floating.centred {} area == rect 128 116 384 232 },
    { name := "a float's share resized steps by 5 percent on its axis and clamps to 5 and 100"
      run :=
        pure <|
          let share : Floating.Share := {}
          share.resized .columns true 1 == { width := 65, height := 50 } &&
            share.resized .rows false 2 == { width := 60, height := 40 } &&
            share.resized .columns true 30 == { width := 100, height := 50 } &&
            share.resized .rows false 30 == { width := 60, height := 5 } }]

end ModelTest
