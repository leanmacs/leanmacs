import Editor.Display
import Editor.Display.Real
import Editor.ExcerptView
import Editor.Face
import Editor.Ffi.Display
import Editor.Ffi.Document
import Editor.Ffi.Excerpts
import Editor.Ffi.Marker
import Editor.Ffi.Snapshot
import Editor.Ffi.Window
import Editor.InputScheme.Vim
import Editor.Loop
import Editor.Menu
import Editor.Scene
import Editor.State
import Editor.Text
import Editor.Text.Real
import Editor.Theme.Picture
import FfiTest.Support.Scenes

/-!
# FFI tests: `Editor/ExcerptView.lean`

The tests of `Editor/ExcerptView.lean`: the `excerpt-picture` scenario
(`excerptPictureScenario`), which draws the excerpt headers
(`ExcerptView.headers`). The root module `FfiTest` runs it, and its own doc
says what it shows.
-/

namespace FfiTest

open Editor.Themes.Picture

/-- The size of the excerpt picture, a theme picture's. -/
def excerptPictureSize : Editor.Size :=
  themePictureSize

/-- The headers of the excerpt picture's two excerpts. -/
def excerptHeaders : Array Editor.Buffer.ExcerptEntry :=
  #[{ source := ⟨0⟩, header := "a.txt" }, { source := ⟨1⟩, header := "b.txt" }]

/-- One picture of the excerpt-picture scene, drawn through the real
binding over a display of the one font `font`, in `theme`: an excerpt
document of `beta` of `a.txt` (`alpha\nbeta\ngamma\n`, 6 to 11) and of
`b.txt` (`one\ntwo\n`, 0 to 8), in one view the size of
`excerptPictureSize`, padded as the editor pads a window, with a block
cursor on `two` in `cursor`. With `headed`, the view has the excerpts'
headers as blocks, placed by the list its snapshot carries
(`Ffi.Snapshot.excerpts`, `ExcerptView.headers`); without, it has none. -/
def excerptPicture (font : ByteArray) (theme : Editor.Theme) (headed : Bool)
    (cursor : Editor.FaceName) : IO Editor.Ffi.Picture := do
  let a ← Editor.Ffi.Document.new "alpha\nbeta\ngamma\n"
  let b ← Editor.Ffi.Document.new "one\ntwo\n"
  let excerpts ← Editor.Ffi.Document.excerptsNew
  if let .error refusal← excerpts.excerptsSet #[a, b] #[(0, 6, 11), (1, 0, 8)] then
    throw (IO.userError s!"the excerpt list was refused: {repr refusal}")
  let library ← excerpts.snapshot
  let some list ← library.excerpts | throw (IO.userError "the snapshot carries no list")
  let placed : Array Editor.Excerpt.Placed :=
    list.map fun (start, stop, sourceStart, sourceStop) => { start, stop, sourceStart, sourceStop }
  let blocks := if headed then Editor.ExcerptView.headers placed excerptHeaders else #[]
  -- `beta\n\none\ntwo\n`: `two` is at 10.
  let scroll ← markIn excerpts (.anchor { offset := 0, bias := .before })
  let selection ← markIn excerpts (rangeMarker 10 10)
  let table ← Editor.Snapshots.new
  let snapshot ← table.add library
  let display ← Editor.Ffi.Display.newFont font "Noto Sans Mono"
  let real ← Editor.RealDisplay.over display table.reader theme
  let marker (index : Nat) : Editor.MarkerId := { text := ⟨0⟩, index }
  let size := excerptPictureSize
  let scene : Editor.Scene :=
    { size
      views :=
        #[{ id := ⟨1⟩, rect := { x := 0, y := 0, width := size.width, height := size.height }
            snapshot, scroll := marker scroll, selections := #[marker selection]
            cursor := { shape := .block, face := cursor }, decorations := #[], status := #[]
            padding := { across := Editor.Loop.padding, down := Editor.Loop.padding }, blocks }]
      focused := some ⟨1⟩, echo := "", pending := "", preedit := none }
  if let .error refusal← (Editor.Display.publish scene).runReal real then
    throw (IO.userError s!"publishing was refused: {repr refusal}")
  let picture ← display.picture
  -- The documents are held until here, past the publish: the library reads
  -- their markers and their texts.
  discard <| excerpts.read
  discard <| a.read
  discard <| b.read
  return picture

/-- The topmost row of pixels among `indices` of `picture`; `none` when
there are none. -/
def topOf (picture : Editor.Ffi.Picture) (indices : Array Nat) : Option Nat :=
  let row (index : Nat) := index / max 1 picture.width
  indices.foldl (fun top index => some (min (top.getD (row index)) (row index))) none

/-- The excerpt-picture scenario over the reference image
`dir/excerpts.png` and the font file `font`, in the built-in theme
(`Theme.builtin`, the theme `default`): it draws
the scene (`excerptPicture`) and, with `write`, writes it to that file
(`mise run excerpt-reference`); without, it compares it with the file
within `pictureTolerance`, guards that the file is the scene's size and at
most `largestReference` bytes, and checks, by pictures it draws itself and
naming no layout constant, that the scene with no blocks differs from it,
that the pixels the header's background changes are mostly the theme's
`block-header` background, and that the cursor's cell is lower than in the
scene with no blocks. Exits 0 after a line naming what held, or 1 after
`FAILED:` lines. -/
def excerptPictureScenario (dir font : String) (write : Bool) : IO UInt8 := do
  let fontBytes ← IO.FS.readBinFile font
  let theme := Editor.Theme.builtin
  let cursor := Editor.Vim.cursorFace "normal"
  let scene ← excerptPicture fontBytes theme true cursor
  let path := System.FilePath.mk dir / "excerpts.png"
  if write then
    let bytes ← scene.toPng
    IO.FS.writeBinFile path bytes
    IO.println
        s!"ffi-test excerpt-picture: wrote {path}: {scene.width} by {scene.height} pixels, {bytes.size} bytes"
    return 0
  let mut failed : List String := []
  let file ← IO.FS.readBinFile path
  let reference ← Editor.Ffi.Picture.ofPng file
  let size := excerptPictureSize
  unless
    (reference.width, reference.height) == (size.width, size.height) &&
      file.size ≤ largestReference do
    failed :=
      failed ++
        [s!"{path} is {reference.width} by {reference.height} and {file.size} bytes, not {size.width} by {size.height} and at most {largestReference}"]
  match difference scene reference with
  | some (worst, count) =>
    unless worst ≤ pictureTolerance do
      failed :=
        failed ++
          [s!"{count} pixels of the excerpt picture differ from {path}, one by {worst} of 255; the tolerance is {pictureTolerance}"]
  | none =>
    failed := failed ++ [s!"the excerpt picture is not the size of {path}"]
  let bare ← excerptPicture fontBytes theme false cursor
  if (differing scene bare).isEmpty then
    failed := failed ++ ["the scene with no blocks is the scene with them"]
  -- The header's face with the paper behind it: what differs is where its
  -- background is.
  let paper := Editor.Palette.placeholder.paper
  let papered :=
    theme.push { name := Editor.ExcerptView.headerFace, face := { background := some paper } }
  let plainHeaders ← excerptPicture fontBytes papered true cursor
  let behind := differing scene plainHeaders
  unless commonest scene behind == some Editor.Palette.placeholder.raised do
    failed :=
      failed ++
        ["the pixels the header's background changes are not mostly block-header's background"]
  -- The cursor's cell: where the scene differs from it with the cursor in a
  -- face nothing defines.
  let cell (headed : Bool) : IO (Option Nat) := do
    let shown ← excerptPicture fontBytes theme headed cursor
    let unthemed ← excerptPicture fontBytes theme headed unthemedFace
    return topOf shown (differing shown unthemed)
  match ← cell true, ← cell false with
  | some headed, some bare =>
    unless headed > bare do
      failed := failed ++ [s!"the cursor's cell is at {headed} with the headers and {bare} without"]
  | _, _ =>
    failed := failed ++ ["the cursor's face changes no pixel"]
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  unless failed.isEmpty do
    return 1
  IO.println
      "ffi-test excerpt-picture: the excerpt picture matches its reference image; its headers are drawn in block-header's background, the scene differs without them, and the cursor's cell is lower with them"
  return 0

end FfiTest
