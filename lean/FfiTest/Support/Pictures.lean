import Editor.Face
import Editor.Ffi.Display
import Editor.Scene
import Std.Data.HashMap

/-!
# FFI tests: support: Pictures

Pictures the library's CPU renderer draws, and how they are read and compared:
pixels, the theme pictures' size and unthemed face, and the tolerance against a
reference. Shared by several test modules; it holds no checks of its own.
-/

namespace FfiTest

/-! ## Theme pictures

Pictures the library's CPU renderer draws of a display's frame
(`Ffi.Display.picture`), and the pure helpers the theme-pictures scenario
reads them with. A pixel is a `Color`, its four bytes red first, so it
compares with a theme's colours as they are. -/

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

end FfiTest
