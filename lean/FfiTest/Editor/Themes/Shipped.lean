import Editor.Display
import Editor.Display.Real
import Editor.Face
import Editor.Ffi.Display
import Editor.Ffi.Document
import Editor.Ffi.Marker
import Editor.Ffi.Snapshot
import Editor.Ffi.Window
import Editor.File
import Editor.InputScheme.Vim
import Editor.Loop
import Editor.Menu
import Editor.ModeLine
import Editor.Scene
import Editor.State
import Editor.Text
import Editor.Text.Real
import Editor.Themes.FairyFloss
import Editor.Themes.Shipped
import Editor.Themes.Solarized
import Editor.UndoTree
import Editor.Value
import FfiTest.Check
import FfiTest.Support.Files
import FfiTest.Support.Pictures
import FfiTest.Support.Scenes

/-!
# FFI tests: `Editor/Themes/Shipped.lean`

The tests of `Editor/Themes/Shipped.lean`: the `theme-pictures` scenario
(`themePicturesScenario`), which draws the shipped palettes
(`Themes.Shipped.themes`),
and `themePicturesChecks`, of its own reporting. The root module `FfiTest` runs
them, and each list's own doc says what it checks.
-/

namespace FfiTest

/-- Where `needle` first starts in `haystack`, as a byte offset. -/
def offsetOf (haystack needle : String) : Option Nat :=
  let hay := haystack.toUTF8
  let pin := needle.toUTF8
  (List.range (hay.size + 1 - pin.size)).find? fun start =>
    (List.range pin.size).all fun index => hay.get! (start + index) == pin.get! index

/-- The status line of the theme pictures: the shipped mode line
(`ModeLine.standard`) of the selected window on `source.lean`, opened as
`source.lean` and not modified, of which the Vim scheme reports `VISUAL` in
`Vim.stateFace "visual"`, with its cursor at the byte `head` of `text`, the
fixture's own text, and `text`'s rows: what the editor sends of such a
window. -/
def themeStatus (text : String) (head : Nat) : Array Editor.StatusField :=
  let before := (String.fromUTF8? (text.toUTF8.extract 0 head)).getD ""
  let rows := before.splitOn "\n"
  let all := text.splitOn "\n"
  let lines := if all.length > 1 && all.getLast? == some "" then all.length - 1 else all.length
  let buffer : Editor.Buffer :=
    { name := "source.lean", text := ⟨0⟩, history := Editor.UndoTree.new ⟨0⟩ 0
      file :=
        some { path := "source.lean", stamp := { seconds := 0, nanoseconds := 0, size := 0 } } }
  Editor.ModeLine.standard.fields
    { buffer, reported := #[{ text := "VISUAL", face := Editor.Vim.stateFace "visual" }]
      cursor := some ⟨rows.length - 1, ((rows.getLast?).getD "").length⟩, lines }

/-- One picture of the theme-pictures scene, drawn through the real
binding over a display of the one font `font`: `text` in one view the size
of `themePictureSize`, in `theme`, with the shipped mode line of a selected
window in visual state on `source.lean` (`themeStatus`): the `VISUAL` badge,
the buffer's name, and on the right line:col and the position, the same in
every draw, read from `selectedIn`; padded as the editor pads a window,
`Loop.padding` points across and down. With `selected`, the text holds
one selection, from the `a` of `area` to its head on the `h` of `(w h`,
with a block cursor there in `cursor`; without, it holds none, and so no
cursor. The offsets are found in `selectedIn`, the fixture's own text, so
that a text of spaces is selected where the fixture is. -/
def themePicture (font : ByteArray) (theme : Editor.Theme) (text selectedIn : String)
    (selected : Option Editor.FaceName) : IO Editor.Ffi.Picture := do
  let some anchor := offsetOf selectedIn "def area"
    | throw (IO.userError "the fixture has no `def area`")
  let some head := offsetOf selectedIn "(w h"
    | throw (IO.userError "the fixture has no `(w h`")
  let document ← Editor.Ffi.Document.new text
  let scroll ← markIn document (.anchor { offset := 0, bias := .before })
  let selection ← markIn document (rangeMarker (anchor + 4).toUInt64 (head + 3).toUInt64)
  let table ← Editor.Snapshots.new
  let snapshot ← table.add (← document.snapshot)
  let display ← Editor.Ffi.Display.newFont font "Noto Sans Mono"
  let real ← Editor.RealDisplay.over display table.reader theme
  let marker (index : Nat) : Editor.MarkerId := { text := ⟨0⟩, index }
  let size := themePictureSize
  let scene : Editor.Scene :=
    { size
      views :=
        #[{ id := ⟨1⟩, rect := { x := 0, y := 0, width := size.width, height := size.height }
            snapshot, scroll := marker scroll
            selections := if selected.isSome then #[marker selection] else #[]
            cursor := { shape := .block, face := selected.getD unthemedFace }
            decorations := #[]
            status := themeStatus selectedIn (head + 3)
            -- A selected window's row, as the loop gives it (`Loop.statusOf`).
            statusFace := some Editor.ModeLine.activeFace
            -- The editor's frame padding at scale 1 (`Loop.padding`).
            padding := { across := Editor.Loop.padding, down := Editor.Loop.padding } }]
      focused := some ⟨1⟩, echo := "", pending := "", preedit := none }
  if let .error refusal← (Editor.Display.publish scene).runReal real then
    throw (IO.userError s!"publishing was refused: {repr refusal}")
  let picture ← display.picture
  -- The document is held until here, past the publish: the library reads
  -- its markers.
  discard <| document.read
  return picture

/-- The colours a shipped theme's source gives its paper, its body text and
its cursor, written from its published record (`Themes.Solarized.published`,
`Themes.FairyFloss.published`, pinned by `ModelTest.solarizedChecks` and
`ModelTest.fairyFlossChecks`), not read from the theme. -/
structure ThemeRoles where
  /-- The shipped theme's name, and its reference image's. -/
  name : String
  /-- The background. -/
  paper : Editor.Color
  /-- The body text. -/
  ink : Editor.Color
  /-- The cursor's background. -/
  cursor : Editor.Color

/-- Solarized dark's and light's roles: base0 on base03, its cursor
base0; base00 on base3, its cursor base00. -/
def solarizedRoles : List ThemeRoles :=
  let c := Editor.Themes.Solarized.published
  [{ name := "solarized-dark", paper := c.base03, ink := c.base0, cursor := c.base0 },
    { name := "solarized-light", paper := c.base3, ink := c.base00, cursor := c.base00 }]

/-- Fairy Floss's roles: the tmTheme's foreground on its background, its
cursor the caret. -/
def fairyFlossRoles : ThemeRoles :=
  let c := Editor.Themes.FairyFloss.published
  { name := "fairy-floss", paper := c.background, ink := c.foreground, cursor := c.caret }

/-- The roles of every shipped theme that has a reference image. -/
def shippedRoles : List ThemeRoles :=
  solarizedRoles ++ [fairyFlossRoles]

/-- `names` as a list in prose: `a`, `a and b`, `a, b and c`. -/
def proseList : List String → String
  | [] => ""
  | [one] => one
  | names => ", ".intercalate names.dropLast ++ " and " ++ names.getLast!

/-- The four pictures of one variant: the scene, the scene with its cursor
in a face nothing defines, and the scene with no selection over the
fixture's text and over the same text with every character but a newline a
space. -/
structure ThemePictures where
  /-- The scene. -/
  scene : Editor.Ffi.Picture
  /-- Its cursor unthemed. -/
  unthemed : Editor.Ffi.Picture
  /-- No selection, over the text. -/
  text : Editor.Ffi.Picture
  /-- No selection, over spaces. -/
  blank : Editor.Ffi.Picture

/-- The four pictures of `theme`, over the fixture `source`. -/
def themePictures (font : ByteArray) (theme : Editor.Theme) (source : String) : IO ThemePictures :=
  do
  let spaces := String.ofList (source.toList.map fun c => if c == '\n' then c else ' ')
  return {
      scene := ← themePicture font theme source source (some (Editor.Vim.cursorFace "visual"))
      unthemed := ← themePicture font theme source source (some unthemedFace)
      text := ← themePicture font theme source source none
      blank := ← themePicture font theme spaces source none }

/-- The role checks of one variant's pictures, as the names of what did
not hold: the commonest colour is the paper; the pixels where the cursor's
cell changes when its face is unthemed are mostly the cursor colour; and
the pixels the text changes from spaces are blends of the paper and the
ink, one of them within the tolerance of the ink. -/
def roleChecks (roles : ThemeRoles) (pictures : ThemePictures) : List String :=
  let all := Array.range (pixelCount pictures.scene)
  let paper :=
    if commonest pictures.scene all == some roles.paper then []
    else [s!"{roles.name}: the commonest colour is not the paper"]
  let cell := differing pictures.scene pictures.unthemed
  let cursor :=
    if cell.isEmpty then [s!"{roles.name}: the cursor's face changes no pixel"]
    else
      if commonest pictures.scene cell == some roles.cursor then []
      else [s!"{roles.name}: the cursor's cell is not mostly the cursor colour"]
  let glyphs := differing pictures.text pictures.blank
  let inked := glyphs.filterMap (pixelAt pictures.text)
  let blended :=
    if inked.isEmpty then [s!"{roles.name}: the text changes no pixel from spaces"]
    else
      if !inked.all (between roles.paper roles.ink · pictureTolerance) then
        [s!"{roles.name}: a pixel of the text is not between the paper and the ink"]
      else
        let farthest :=
          inked.foldl
            (fun (far : Editor.Color) pixel =>
              if channelDistance pixel roles.paper > channelDistance far roles.paper then pixel
              else far)
            roles.paper
        if channelDistance farthest roles.ink ≤ pictureTolerance then []
        else [s!"{roles.name}: no pixel of the text is the ink"]
  paper ++ cursor ++ blended

/-- The theme-pictures scenario over the reference images in `dir`, its
fixture `dir/source.lean`, and the font file `font`. For each theme of
`variants`, looked up by name in `Themes.Shipped.themes`, it draws the four pictures (`themePictures`) and, with
`write`, writes the scene's picture to `dir/<name>.png` (`mise run
theme-references`); without, it compares the scene's picture with that
file within `pictureTolerance`, runs `roleChecks`, and guards that each
reference is the scene's size and at most `largestReference` bytes, and
that the light picture does not match the dark reference. Exits 0 after a
line naming what held, or 1 after `FAILED:` lines, in either mode.
`variants`, the themes it draws, are `shippedRoles` except in its own
check (`themePicturesChecks`). -/
def themePicturesScenario (dir font : String) (write : Bool)
    (variants : List ThemeRoles := shippedRoles) : IO UInt8 := do
  let source ← IO.FS.readFile (System.FilePath.mk dir / "source.lean")
  let fontBytes ← IO.FS.readBinFile font
  let mut failed : List String := []
  let mut scenes : List (String × Editor.Ffi.Picture) := []
  let mut references : List (String × Editor.Ffi.Picture) := []
  for roles in variants do
    let some named := Editor.Themes.Shipped.themes.find? (·.name == roles.name)
      | failed := failed ++ [s!"no shipped theme is named {roles.name}"]
    let pictures ← themePictures fontBytes named.theme source
    let path := System.FilePath.mk dir / s!"{roles.name}.png"
    scenes := scenes ++ [(roles.name, pictures.scene)]
    if write then
      let bytes ← pictures.scene.toPng
      IO.FS.writeBinFile path bytes
      IO.println
          s!"ffi-test theme-pictures: wrote {path}: {pictures.scene.width} by {pictures.scene.height} pixels, {bytes.size} bytes"
      continue
    let file ← IO.FS.readBinFile path
    let reference ← Editor.Ffi.Picture.ofPng file
    references := references ++ [(roles.name, reference)]
    let size := themePictureSize
    unless
      (reference.width, reference.height) == (size.width, size.height) &&
        file.size ≤ largestReference do
      failed :=
        failed ++
          [s!"{path} is {reference.width} by {reference.height} and {file.size} bytes, not {size.width} by {size.height} and at most {largestReference}"]
    match difference pictures.scene reference with
    | some (worst, count) =>
      unless worst ≤ pictureTolerance do
        failed :=
          failed ++
            [s!"{count} pixels of {roles.name} differ from {path}, one by {worst} of 255; the tolerance is {pictureTolerance}"]
    | none =>
      failed := failed ++ [s!"the picture of {roles.name} is not the size of {path}"]
    failed := failed ++ roleChecks roles pictures
  unless write do
    match scenes.lookup "solarized-light", references.lookup "solarized-dark" with
    | some light, some dark =>
      unless (difference light dark).any (·.1 > pictureTolerance) do
        failed := failed ++ ["the light picture matches the dark reference"]
    | _, _ =>
      failed := failed ++ ["there is no light picture and dark reference to tell apart"]
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  unless failed.isEmpty do
    return 1
  if write then
    return 0
  IO.println
      s!"ffi-test theme-pictures: {proseList (variants.map (·.name))} match their reference images; in each the paper, the cursor and the text carry the palette's colours; the light picture is not the dark reference"
  return 0

/-- The checks of the theme-pictures scenario's own reporting, over a
directory of its own and a theme no shipped theme is named, so that
nothing is drawn or written. -/
def themePicturesChecks (_ : Unit) : List Check :=
  [{  name := "theme-pictures --write says why it fails on stderr, not only by its status"
      run :=
        inOwnDirectory fun directory => do
          IO.FS.writeFile (directory / "source.lean") ""
          let font := directory / "font.ttf"
          IO.FS.writeBinFile font .empty
          let missing : ThemeRoles :=
            { name := "no-such-theme", paper := .rgb 0 0 0, ink := .rgb 0 0 0,
              cursor := .rgb 0 0 0 }
          let errors ← IO.mkRef ({} : IO.FS.Stream.Buffer)
          let status ←
            IO.withStderr (IO.FS.Stream.ofBuffer errors) <|
                themePicturesScenario directory.toString font.toString true [missing]
          let said := String.fromUTF8? (← errors.get).data
          return status == 1 && said == some "FAILED: no shipped theme is named no-such-theme\n" }]

end FfiTest
