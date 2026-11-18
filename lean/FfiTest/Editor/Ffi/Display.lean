import Editor.Face
import Editor.Ffi.Display
import Editor.Ffi.Document
import Editor.Ffi.Snapshot
import FfiTest.Check
import FfiTest.Support.Pictures

/-!
# FFI tests: `Editor/Ffi/Display.lean`

The tests of `Editor/Ffi/Display.lean`: `displayChecks`, and `pictureChecks`, of
its pictures. The root module `FfiTest` runs them, and each list's own doc says
what it checks.
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

/-- A picture 2 pixels by 2 of `colors`, row by row. -/
def pictureOf (colors : List Editor.Color) : Editor.Ffi.Picture :=
  { width := 2, height := 2
    rgba := ⟨(colors.flatMap fun color => (channels color).map (·.toUInt8)).toArray⟩ }

/-- The checks of the helpers the theme-pictures scenario reads its
pictures with, on pictures 2 by 2 written here, and of a picture's round
trip through a PNG file by the real binding. -/
def pictureChecks (_ : Unit) : List Check :=
  let black := Editor.Color.rgb 0 0 0
  let white := Editor.Color.rgb 255 255 255
  let grey := Editor.Color.rgb 128 128 128
  let red := Editor.Color.rgb 200 0 0
  [{  name := "two pictures differ where their pixels do, by their worst channel"
      run :=
        let one := pictureOf [black, white, grey, grey]
        let two := pictureOf [black, Editor.Color.rgb 250 255 254, grey, red]
        pure
          (differing one two == #[1, 3] && difference one two == some (128, 2) &&
            difference one one == some (0, 0) &&
            difference one
                { one with
                  width := 4, height := 1 } ==
              none) },
    { name := "the commonest colour of some pixels is the one most of them have"
      run :=
        let picture := pictureOf [grey, white, grey, red]
        pure
          (commonest picture #[0, 1, 2, 3] == some grey && commonest picture #[1] == some white &&
            commonest picture #[] == none) },
    { name := "a blend of paper and ink is between them, and a third colour is not"
      run :=
        pure
          (between black white grey 0 && between white black grey 0 && !between black grey red 0 &&
            between black grey (Editor.Color.rgb 129 130 0) 2 &&
            !between black grey (Editor.Color.rgb 129 131 0) 2) },
    { name := "a picture comes back from its PNG file through the library"
      run := do
        let picture := pictureOf [black, white, grey, red]
        return (← Editor.Ffi.Picture.ofPng (← picture.toPng)) == picture },
    { name := "a picture of no pixels is refused a PNG file with a reason"
      run := do
        try
          discard <| Editor.Ffi.Picture.toPng { width := 0, height := 0, rgba := .empty }
          pure false
        catch error =>
          pure !(toString error).isEmpty },
    { name := "bytes that are no PNG file and a font that is none are refused with a reason"
      run := do
        let notPng ←
          try
            discard <| Editor.Ffi.Picture.ofPng "no".toUTF8
            pure false
          catch error =>
            pure !(toString error).isEmpty
        let notFont ←
          try
            discard <| Editor.Ffi.Display.newFont "no".toUTF8 "Noto Sans Mono"
            pure false
          catch error =>
            pure !(toString error).isEmpty
        return notPng && notFont }]

end FfiTest
