import Editor.Face
import Editor.Ffi.Display
import Editor.Themes.Picture
import FfiTest.Check
import FfiTest.Support.Files

/-!
# FFI tests: `Editor/Themes/Picture.lean`

The tests of `Editor/Themes/Picture.lean`, the theme picture check:
`pictureChecks`, of the helpers it reads pictures with, and
`themePicturesChecks`, of the scenario's own reporting; and `defaultRoles`,
what the core hands the scenario for its own theme, `default`, which the
`theme-pictures` scenario of the root module `FfiTest` draws. The root
module runs the lists, and each list's own doc says what it checks.
-/

namespace FfiTest

open Editor.Themes.Picture

/-- The roles of the theme `default`, the built-in theme
(`Theme.builtin`), written from the placeholder palette
(`Palette.placeholder`, `Editor/Face.lean`): its ink on its paper, its
cursor the palette's cursor colour. -/
def defaultRoles : ThemeRoles :=
  let palette := Editor.Palette.placeholder
  { name := Editor.Theme.defaultName, theme := Editor.Theme.builtin, paper := palette.paper,
    ink := palette.ink, cursor := palette.cursor }

/-- A picture 2 pixels by 2 of `colors`, row by row. -/
def pictureOf (colors : List Editor.Color) : Editor.Ffi.Picture :=
  { width := 2, height := 2
    rgba := ⟨(colors.flatMap fun color => (channels color).map (·.toUInt8)).toArray⟩ }

/-- The checks of the helpers the theme picture check reads its pictures
with (`Editor/Themes/Picture.lean`), on pictures 2 by 2 written here, and of a picture's round
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

/-- The checks of the theme-pictures scenario's own reporting, over a
directory of its own whose fixture file is empty, so that the one theme it
is handed cannot be drawn and nothing is written. -/
def themePicturesChecks (_ : Unit) : List Check :=
  [{  name :=
        "theme-pictures --write says why a theme could not be drawn on stderr, under the caller's theme's name, not only by its status"
      run :=
        inOwnDirectory fun directory => do
          IO.FS.writeFile (directory / "source.lean") ""
          let font := directory / "font.ttf"
          IO.FS.writeBinFile font .empty
          let undrawn : ThemeRoles :=
            { name := "fixture-theme", theme := #[], paper := .rgb 0 0 0, ink := .rgb 0 0 0,
              cursor := .rgb 0 0 0 }
          let errors ← IO.mkRef ({} : IO.FS.Stream.Buffer)
          let status ←
            IO.withStderr (IO.FS.Stream.ofBuffer errors) <|
                themePicturesScenario "a run" directory.toString font.toString true [undrawn]
          let said := String.fromUTF8? (← errors.get).data
          return status == 1 &&
              said == some "FAILED: fixture-theme: the fixture has no `def area`\n" }]

end FfiTest
