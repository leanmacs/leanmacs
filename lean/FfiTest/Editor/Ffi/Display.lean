import Editor.Face
import Editor.Ffi.Display
import Editor.Ffi.Document
import Editor.Ffi.Snapshot
import FfiTest.Check

/-!
# FFI tests: `Editor/Ffi/Display.lean`

The tests of `Editor/Ffi/Display.lean`: `displayChecks`. The root module
`FfiTest` runs them, and the list's own doc says what it checks. The checks of
the pictures a display draws are `pictureChecks`, in
`FfiTest/Editor/Theme/Picture.lean`.
-/

namespace FfiTest

/-- Makes a display, asks it one question and drops it: what is left of it
must be freed. Its rows of "abc" at one pixel a cell, two wide, from 0. -/
def useDisplay : IO (Option (Array Editor.Ffi.DisplayRow)) := do
  let display ← Editor.Ffi.Display.newCells 1 1
  let snapshot ← (← Editor.Ffi.Document.new "abc").snapshot
  display.rows snapshot 2 10 0

/-- The checks of the display handle (`Editor.Ffi.Display`): it is freed with
its last reference, and its answers cross. What it answers is layout's rule,
pinned by `editor-layout`'s tests, and the queries' rules are held to the
display contract by `contract-test`. -/
def displayChecks (_ : Unit) : List Check :=
  [{  name :=
        "a display is freed when Lean drops the last reference, and its rows cross as start and stop"
      run := do
        let before ← Editor.Ffi.Display.live
        let rows ← useDisplay
        return rows == some #[{ start := 0, stop := 2 }, { start := 2, stop := 3 }] &&
            (← Editor.Ffi.Display.live) == before },
    { name :=
        "a display's move crosses as a position and a goal, and a position inside a character is refused"
      run := do
        let display ← Editor.Ffi.Display.newCells 1 1
        let snapshot ← (← Editor.Ffi.Document.new "abcdé\nx").snapshot
        -- From b (x 1) one row down at width 3: "dé" is the next row, so é.
        let down ← display.move snapshot 3 1 1 none
        -- Two rows up from x, aiming for x 1: "dé", then "abc", so b.
        let up ← display.move snapshot 3 7 (-2) (some 1)
        let inside ← display.move snapshot 3 5 1 none
        return down == some { position := 4, goal := 1 } &&
            up == some { position := 1, goal := 1 } &&
            inside.isNone }]

end FfiTest
