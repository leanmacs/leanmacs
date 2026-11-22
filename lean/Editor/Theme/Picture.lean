import Editor.Display
import Editor.Display.Real
import Editor.Face
import Editor.Ffi.Display
import Editor.Ffi.Document
import Editor.Ffi.Marker
import Editor.Ffi.Snapshot
import Editor.Ffi.Window
import Editor.File
import Editor.Loop
import Editor.Menu
import Editor.ModeLine
import Editor.Scene
import Editor.State
import Editor.Text
import Editor.Text.Real
import Editor.UndoTree
import Editor.Value
import Std.Data.HashMap

/-!
# The theme picture check

A test double of the core: the check that a theme, drawn, carries its
palette's colours and matches a reference image. Whoever owns a theme runs
it on that theme, as each runs the completeness check
(`Themes.problems`, `Editor/Theme/Check.lean`): the core on the theme
`default` (`ffi-test theme-pictures`, `FfiTest/Editor/Theme/Picture.lean`),
and a package that ships themes on its own, from its linked test
(`docs/design/packages.md`, "A package's tests and the gate's steps over
them"). A package's tests may import this module; its library may not
(`docs/design/packages.md`, "What a package may import").

It is here, in the core, because drawing a scene goes through the raw
bindings of the display and the document (`Editor.Ffi.…`), which no
package may import. So the scenario takes what differs between owners as
arguments, a list of themes with the colours their sources give
(`ThemeRoles`), the directory of the fixture and the reference images, and
the font file, and keeps the bindings to itself.

- **`themePicturesScenario`** draws each theme's picture of the fixture
  file through the display's real binding and the CPU renderer, and
  compares it with `<dir>/<name>.png`, or writes that file.
- **The helpers it reads pictures with** (`differing`, `difference`,
  `commonest`, `between` and the rest), the picture's size, the tolerance
  and the largest reference are here too, each defined once: the core's
  other picture tests use them (`FfiTest/Editor/ExcerptView.lean`).

It uses a library that must be linked, so nothing imports it but tests
linked as the editor is, and the core's root (`Editor/Core.lean`), which
imports every core module.

Pinned by `FfiTest.pictureChecks` and `FfiTest.themePicturesChecks`, and
by the scenario's own runs in the gate.
-/

namespace Editor.Themes.Picture

/-! ## Pictures

Pictures the library's CPU renderer draws of a display's frame
(`Ffi.Display.picture`), and the pure helpers the scenario reads them with.
A pixel is a `Color`, its four bytes red first, so it compares with a
theme's colours as they are. -/

/-- The pixel numbered `index` of `picture`, counted row by row from the
top left; `none` past its last. -/
def pixelAt (picture : Editor.Ffi.Picture) (index : Nat) : Option Editor.Color :=
  if index * 4 + 4 ≤ picture.rgba.size then
    let byte (offset : Nat) : UInt8 := picture.rgba.get! (index * 4 + offset)
    some (.rgba (byte 0) (byte 1) (byte 2) (byte 3))
  else none

/-- How many pixels `picture` has. -/
def pixelCount (picture : Editor.Ffi.Picture) : Nat :=
  picture.rgba.size / 4

/-- The four bytes of `color`, red first. -/
def channels (color : Editor.Color) : List Nat :=
  [24, 16, 8, 0].map fun shift => ((color.word >>> shift.toUInt32) &&& 0xff).toNat

/-- The largest difference of any channel of two colours. -/
def channelDistance (one two : Editor.Color) : Nat :=
  ((channels one).zip (channels two)).foldl (fun worst (a, b) => max worst (max a b - min a b)) 0

/-- The numbers of the pixels where `one` and `two` differ; none when they
are not the same size. -/
def differing (one two : Editor.Ffi.Picture) : Array Nat :=
  if (one.width, one.height) != (two.width, two.height) then #[]
  else (Array.range (pixelCount one)).filter fun index => pixelAt one index != pixelAt two index

/-- How `one` differs from `two`: `none` when they are not the same size,
and otherwise the largest difference of any channel of any pixel, with how
many pixels differ at all. -/
def difference (one two : Editor.Ffi.Picture) : Option (Nat × Nat) :=
  if (one.width, one.height) != (two.width, two.height) then none
  else
    some <|
      (differing one two).foldl
        (fun (worst, count) index =>
          match pixelAt one index, pixelAt two index with
          | some a, some b => (max worst (channelDistance a b), count + 1)
          | _, _ => (worst, count + 1))
        (0, 0)

/-- The colour most of the pixels numbered `indices` of `picture` have;
`none` when there are none. -/
def commonest (picture : Editor.Ffi.Picture) (indices : Array Nat) : Option Editor.Color :=
  let counts : Std.HashMap UInt32 Nat :=
    indices.foldl
      (fun counts index =>
        match pixelAt picture index with
        | some color => counts.insert color.word (counts.getD color.word 0 + 1)
        | none => counts)
      {}
  let best :=
    counts.fold
      (fun (best : Option (UInt32 × Nat)) word count =>
        match best with
        | some (_, most) => if count > most then some (word, count) else best
        | none => some (word, count))
      none
  best.map fun (word, _) => { word }

/-- Whether `color` lies, channel by channel, between `paper` and `ink`,
within `slack` of either end: a blend of the two. -/
def between (paper ink color : Editor.Color) (slack : Nat) : Bool :=
  ((channels paper).zip ((channels ink).zip (channels color))).all fun (p, i, c) =>
    min p i ≤ c + slack && c ≤ max p i + slack

/-- The size of the theme pictures: one view covers it, taller than the
fixture's text, so rows of bare paper remain. -/
def themePictureSize : Editor.Size :=
  { width := 320, height := 160 }

/-- The face name no theme defines, which the scenario draws the cursor in
to find the cursor's cell: by the face rule (`Editor/Face.lean`) a cursor
in it is drawn in the default face's paint, the ink on the paper, so its
background is the paper. -/
def unthemedFace : Editor.FaceName :=
  ⟨"theme-pictures.unthemed"⟩

/-- How far any channel of any pixel may be from the reference's: 2 of 255,
the bound and the reason of the renderer's own reference image
(`crates/editor-render-wgpu/tests/reference.rs`). -/
def pictureTolerance : Nat :=
  2

/-- The largest a theme's reference image may be as a file. -/
def largestReference : Nat :=
  20000

/-! ## The scene -/

/-- Marks `document` with `marker`, and returns its number. -/
def markIn (document : Editor.Ffi.Document) (marker : Editor.Ffi.Marker) : IO Nat := do
  match ← document.mark marker with
  | .ok number =>
    return number.toNat
  | .error refusal =>
    throw (IO.userError s!"the fixture's marker was refused: {repr refusal}")

/-- A selection marker of the one range from `anchor` to `head`. -/
def rangeMarker (anchor head : UInt64) : Editor.Ffi.Marker :=
  .selection { ranges := #[{ anchor, head }] }

/-- Where `needle` first starts in `haystack`, as a byte offset. -/
def offsetOf (haystack needle : String) : Option Nat :=
  let hay := haystack.toUTF8
  let pin := needle.toUTF8
  (List.range (hay.size + 1 - pin.size)).find? fun start =>
    (List.range pin.size).all fun index => hay.get! (start + index) == pin.get! index

/-- The status line of the theme pictures: the shipped mode line
(`ModeLine.standard`) of the selected window on `source.lean`, opened as
`source.lean` and not modified, of which a scheme reports `VISUAL` in the
badge face `mode-line.state.visual`, as the Vim scheme does in its visual
state, with its cursor at the byte `head` of `text`, the
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
    { buffer, reported := #[{ text := "VISUAL", face := ⟨"mode-line.state.visual"⟩ }]
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

/-- A theme to draw, with the colours its source gives its paper, its body
text and its cursor, written by the caller from the palette's published
record and not read from the theme: what `roleChecks` holds the picture
to. -/
structure ThemeRoles where
  /-- The theme's name, and its reference image's. -/
  name : String
  /-- The theme, as a host is handed it. -/
  theme : Editor.Theme
  /-- The background. -/
  paper : Editor.Color
  /-- The body text. -/
  ink : Editor.Color
  /-- The cursor's background. -/
  cursor : Editor.Color

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
      scene := ← themePicture font theme source source (some ⟨"cursor.visual"⟩)
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

/-- The four pictures of `roles`' theme over `source`, or why they could
not be drawn. -/
def drawn (font : ByteArray) (roles : ThemeRoles) (source : String) :
    IO (Except String ThemePictures) := do
  try
    return .ok (← themePictures font roles.theme source)
  catch error =>
    return .error (toString error)

/-- The theme-pictures scenario over the reference images in `dir`, its
fixture `dir/source.lean`, and the font file `font`. For each theme of
`variants` it draws the four pictures (`themePictures`) and, with `write`,
writes the scene's picture to `dir/<name>.png`; without, it compares the
scene's picture with that file within `pictureTolerance`, runs
`roleChecks`, and guards that each reference is the scene's size and at
most `largestReference` bytes. With `apart`, a pair of names of
`variants`, it also guards that the comparison discriminates: the picture
of the first must not match the reference of the second. Exits 0 after a
line naming what held, or 1 after `FAILED:` lines, in either mode; a theme
that could not be drawn is one of them. `label` starts each line it
prints: the caller's name for the run. -/
def themePicturesScenario (label dir font : String) (write : Bool) (variants : List ThemeRoles)
    (apart : Option (String × String) := none) : IO UInt8 := do
  let source ← IO.FS.readFile (System.FilePath.mk dir / "source.lean")
  let fontBytes ← IO.FS.readBinFile font
  let mut failed : List String := []
  let mut scenes : List (String × Editor.Ffi.Picture) := []
  let mut references : List (String × Editor.Ffi.Picture) := []
  for roles in variants do
    let pictures ←
      match ← drawn fontBytes roles source with
      | .ok pictures =>
        pure pictures
      | .error reason =>
        failed := failed ++ [s!"{roles.name}: {reason}"]
        continue
    let path := System.FilePath.mk dir / s!"{roles.name}.png"
    scenes := scenes ++ [(roles.name, pictures.scene)]
    if write then
      let bytes ← pictures.scene.toPng
      IO.FS.writeBinFile path bytes
      IO.println
          s!"{label}: wrote {path}: {pictures.scene.width} by {pictures.scene.height} pixels, {bytes.size} bytes"
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
  if let (false, some (picture, reference)) := (write, apart) then
    match scenes.lookup picture, references.lookup reference with
    | some one, some other =>
      unless (difference one other).any (·.1 > pictureTolerance) do
        failed := failed ++ [s!"the picture of {picture} matches the reference of {reference}"]
    | _, _ =>
      failed :=
        failed ++ [s!"there is no picture of {picture} and reference of {reference} to tell apart"]
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  unless failed.isEmpty do
    return 1
  if write then
    return 0
  let told :=
    match apart with
    | some (picture, reference) =>
      s!"; the picture of {picture} is not the reference of {reference}"
    | none => ""
  let matching :=
    if variants.length == 1 then "matches its reference image" else "match their reference images"
  IO.println
      s!"{label}: {proseList (variants.map (·.name))} {matching}; in each the paper, the cursor and the text carry the palette's colours{told}"
  return 0

end Editor.Themes.Picture
