import Editor.Ffi.Snapshot
import Editor.Ffi.Words

/-!
# Bindings: the display

The bindings of `crates/editor-ffi/src/display.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("Handles", "Plain data").

A scene's words are `display/wire.rs`'s. A display's picture, for tests,
binds `display.rs` too, so it is here rather than in a module of its own.
-/

namespace Editor.Ffi

open Words

/-- The type behind `Display`. It is opaque, so the only way to get a
display is `Display.newCells`. -/
opaque DisplayPointed : NonemptyType

/-- Layout held by the Rust library (`crates/editor-ffi/src/display.rs`,
over `crates/editor-layout`): a handle that lays out the text of snapshots
and answers the display interface's two layout queries about them. The
display interface's real binding runs against it
(`Editor/Display/Real.lean`). -/
def Display : Type :=
  DisplayPointed.type

instance : Nonempty Display :=
  DisplayPointed.property

/-- A new display over the library's fake shaper, whose every glyph is
`advance` pixels across and every line `lineHeight` down. -/
@[extern "editor_glue_display_new_cells"]
opaque Display.newCells (advance lineHeight : UInt64) : IO Display

/-- A new display over the library's real shaper and the fonts of this
machine: the window mode's. What it lays out depends on the machine, so no
check makes one. -/
@[extern "editor_glue_display_new_system"]
opaque Display.newSystem : IO Display

/-- Binds `display` to the library's presenter: every scene it publishes
from then on is laid out at the scale the process's window said, and its
frame reaches the render session that runs, the window's or the headless
mode's, stamped with the window input it answers. -/
@[extern "editor_glue_display_present"]
opaque Display.present (display : @& Display) : IO Unit

/-- How many displays the Rust library holds that have not been freed.

This exists for `FfiTest`, which uses it to see a display's finaliser
run. -/
@[extern "editor_glue_display_live"]
opaque Display.live : IO UInt64

/-- The heights of the rows a frame is built of, in whole pixels at the
display's scale, as the library answers them: a text row, a window's status
row, and the frame's bottom row, where the echo or the prompt is drawn. -/
structure DisplayHeights where
  /-- One text row in the default face. -/
  text : UInt64
  /-- A window's status row. -/
  status : UInt64
  /-- The bottom row. -/
  message : UInt64
  deriving DecidableEq, Repr

/-- `Display.heights` as it crosses. -/
@[extern "editor_glue_display_heights"]
private opaque Display.heightsRaw (display : @& Display) : IO RawWords

/-- The heights of a text row, a status row and the bottom row. Words that
are not three are an error. -/
def Display.heights (display : Display) : IO DisplayHeights := do
  let raw ← display.heightsRaw
  match wordsOf? raw.words with
  | some #[text, status, message] =>
    return { text, status, message }
  | _ =>
    throw (IO.userError "the library's heights are not three words")

/-- One visual row, as the library answers it: the bytes from `start` up to
`stop`, without its line break. -/
structure DisplayRow where
  /-- The byte offset of its first character. -/
  start : UInt64
  /-- Where its characters stop. -/
  stop : UInt64
  deriving DecidableEq, Repr

/-- Where a move went, as the library answers it. -/
structure DisplayMoved where
  /-- The byte offset it reached. -/
  position : UInt64
  /-- The x it aimed for, in whole pixels, to pass to the next move. -/
  goal : UInt64
  deriving DecidableEq, Repr

/-- The rows a record of words holds: their count, then a start and a stop
for each. `none` when its status is not 0. Words that do not spell rows are
an error. -/
private def rowsOf? (raw : RawWords) : IO (Option (Array DisplayRow)) := do
  if raw.status != 0 then
    return none
  let some words := wordsOf? raw.words
    | throw (IO.userError "the library's rows are not whole words")
  let count := (words[0]?.getD 0).toNat
  unless words.size == 1 + 2 * count do
    throw (IO.userError "the library's rows do not spell their count")
  return some <|
      (Array.range count).map fun row =>
        { start := words[1 + 2 * row]!, stop := words[2 + 2 * row]! }

/-- `Display.rows` as it crosses: the view's blocks as words and a string,
and the answer as words, and its status. -/
@[extern "editor_glue_display_rows"]
private opaque Display.rowsRaw (display : @& Display) (snapshot : @& Snapshot)
    (width height across down top gutter : UInt64) (anchor : USize) (blockWords : @& ByteArray)
    (blockText : @& String) (foldWords : @& ByteArray) (foldText : @& String) : IO RawWords

/-- The rows a view `width` pixels wide and `height` tall, its content inset
`across` and `down` points from its edges and its rows a further `top`
points from its top, shows of `snapshot`, from the visual row that holds
`anchor`: as many as fit whole, fewer at the end of the text. The library
takes the padding off at the scale it lays out at, as its frames take it
off; a padding no `u32` holds is the largest. `none` when `anchor` is not a
position of the text. `blockWords` and `blockText` are the view's blocks,
in the layout a view's blocks take in a scene after its padding
(`crates/editor-ffi/src/display/wire.rs`): the rows are those that fit
with the blocks drawn between them. Words that spell no blocks are
answered as a bad anchor is, `none`. None by default. `gutter` is the width of
the view's gutter column, in points, a further inset of its text from its
left; none by default. `foldWords` and `foldText` are the view's folds, in
the layout a view's folds take in a scene after its stops: each is one row.
Words that spell no folds are answered as a bad anchor is. None by
default. -/
def Display.rows (display : Display) (snapshot : Snapshot) (width height : UInt64) (anchor : USize)
    (across down top : UInt64 := 0) (blockWords : Array UInt64 := #[0]) (blockText : String := "")
    (gutter : UInt64 := 0) (foldWords : Array UInt64 := #[0]) (foldText : String := "") :
    IO (Option (Array DisplayRow)) := do
  rowsOf?
      (←
        display.rowsRaw snapshot width height across down top gutter anchor
            (blockWords.foldl pushWord ByteArray.empty) blockText
            (foldWords.foldl pushWord ByteArray.empty) foldText)

/-- `Display.move` as it crosses: the lines as a 64-bit two's complement
number, the goal as a presence flag and a value, and the answer as words. -/
@[extern "editor_glue_display_move"]
private opaque Display.moveRaw (display : @& Display) (snapshot : @& Snapshot)
    (width across gutter : UInt64) (position : USize) (lines : UInt64) (goalPresent : Bool)
    (goal : UInt64) (foldWords : @& ByteArray) (foldText : @& String) : IO RawWords

/-- The position of `snapshot` `lines` visual rows below `position` (above
when negative) in a view `width` pixels wide whose text is inset `across`
points each side, aiming for `goal`, or for the position's own x when there
is none; and the goal to pass on. A count of lines past what 64 bits hold
is cut to the largest, which is past every text's first and last row
anyway. `none` when `position` is not a position of the text. `gutter` is the
width of the view's gutter column, in points, taken off the width once. The
folds are as for `Display.rows`: each is one row to the move. -/
def Display.move (display : Display) (snapshot : Snapshot) (width : UInt64) (position : USize)
    (lines : Int) (goal : Option UInt64) (across : UInt64 := 0) (gutter : UInt64 := 0)
    (foldWords : Array UInt64 := #[0]) (foldText : String := "") : IO (Option DisplayMoved) := do
  let bound : Int := 2 ^ 63
  let clamped := max (-bound) (min lines (bound - 1))
  let word := if clamped < 0 then (2 ^ 64 + clamped).toNat.toUInt64 else clamped.toNat.toUInt64
  let raw ←
    display.moveRaw snapshot width across gutter position word goal.isSome (goal.getD 0)
        (foldWords.foldl pushWord ByteArray.empty) foldText
  if raw.status != 0 then
    return none
  match wordsOf? raw.words with
  | some #[position, goal] =>
    return some { position, goal }
  | _ =>
    throw (IO.userError "the library's words do not spell a move")

/-- Where a position is drawn in a view, as the library answers it: in whole
pixels from the view's top left, its padding included. -/
structure DisplaySpot where
  /-- From the view's left edge to the position's left, rounded down. -/
  x : UInt64
  /-- From the view's top edge to the top of the row that holds it,
  rounded down. -/
  y : UInt64
  /-- How tall that row is, rounded up. -/
  height : UInt64
  deriving DecidableEq, Repr

/-- `Display.spot` as it crosses: the view's blocks as words and a string,
and the answer as words, and its status. -/
@[extern "editor_glue_display_spot"]
private opaque Display.spotRaw (display : @& Display) (snapshot : @& Snapshot)
    (width height across down top gutter : UInt64) (anchor position : USize)
    (blockWords : @& ByteArray) (blockText : @& String) (foldWords : @& ByteArray)
    (foldText : @& String) : IO RawWords

/-- Where `position` of `snapshot` is drawn in a view `width` pixels wide
and `height` tall, padded as for `Display.rows`, that shows from the visual
row that holds `anchor`: `some none` when the view does not show it, and
`none` when `anchor` or `position` is not a position of the text. Words
that do not spell a spot are an error. The blocks and the folds are as for
`Display.rows`: a position below a block is lower by the block's rows, and
one a fold covers is at its placeholder's start. -/
def Display.spot (display : Display) (snapshot : Snapshot) (width height : UInt64)
    (anchor position : USize) (across down top : UInt64 := 0) (blockWords : Array UInt64 := #[0])
    (blockText : String := "") (gutter : UInt64 := 0) (foldWords : Array UInt64 := #[0])
    (foldText : String := "") : IO (Option (Option DisplaySpot)) := do
  let raw ←
    display.spotRaw snapshot width height across down top gutter anchor position
        (blockWords.foldl pushWord ByteArray.empty) blockText
        (foldWords.foldl pushWord ByteArray.empty) foldText
  if raw.status != 0 then
    return none
  match wordsOf? raw.words with
  | some #[0, _, _, _] =>
    return some none
  | some #[_, x, y, height] =>
    return some (some { x, y, height })
  | _ =>
    throw (IO.userError "the library's words do not spell a spot")

/-- `Display.measure` as it crosses: the run as one block's words and
string, and the answer as words, and its status. -/
@[extern "editor_glue_display_measure"]
private opaque Display.measureRaw (display : @& Display) (runWords : @& ByteArray)
    (runText : @& String) : IO RawWords

/-- How wide a run is laid out in its faces over the default face, unbroken,
in whole points rounded up: the width a generator computes align-to stops
from. The run is the one block `runWords` and `runText` spell, in the
layout a view's blocks take in a scene after its padding
(`crates/editor-ffi/src/display/wire.rs`), drawn before offset 0: its text
is the run and its decorations the run's faces. `none` when the words
spell no block, more than one, or one drawn before another offset. Words
that do not spell a width are an error. -/
def Display.measure (display : Display) (runWords : Array UInt64) (runText : String) :
    IO (Option UInt64) := do
  let raw ← display.measureRaw (runWords.foldl pushWord ByteArray.empty) runText
  if raw.status != 0 then
    return none
  match wordsOf? raw.words with
  | some #[width] =>
    return some width
  | _ =>
    throw (IO.userError "the library's words do not spell a width")

/-- `Display.publish` as it crosses: the words as bytes, the string, and the
snapshot handles, which the glue passes as a C array. -/
@[extern "editor_glue_display_publish"]
private opaque Display.publishRaw (display : @& Display) (words : @& ByteArray)
    (strings : @& String) (snapshots : @& Array Snapshot) : IO Bool

/-- Publishes the scene `words` and `strings` spell, whose views show the
`snapshots`, named in the words by their index (the layout is
`crates/editor-ffi/src/display/wire.rs`'s): the library resolves the
markers it names in the snapshots' documents, lays it out, and keeps its
frame. `false`, keeping what was published before, when the words do not
spell a scene. -/
def Display.publish (display : Display) (words : Array UInt64) (strings : String)
    (snapshots : Array Snapshot) : IO Bool :=
  display.publishRaw (words.foldl pushWord ByteArray.empty) strings snapshots

/-- `Display.define` as it crosses: the words as bytes, and the string. -/
@[extern "editor_glue_display_define"]
private opaque Display.defineRaw (display : @& Display) (words : @& ByteArray)
    (strings : @& String) : IO Bool

/-- Defines the faces `words` and `strings` spell, the count of definitions
and each definition as they follow the faces' presence in a scene's words,
as what the faces look like from now on, with no frame laid out: every
later heights answer, query and frame is in them, until a scene carries
others. `false`, changing nothing, when the words do not spell them. -/
def Display.define (display : Display) (words : Array UInt64) (strings : String) : IO Bool :=
  display.defineRaw (words.foldl pushWord ByteArray.empty) strings

/-- The latest frame the display laid out, as the library's text of it
(`Frame::describe` in `crates/editor-layout`): empty before any scene is
published. -/
@[extern "editor_glue_display_frame_text"]
opaque Display.frameText (display : @& Display) : IO String

/-- `Display.frameRows` as it crosses. -/
@[extern "editor_glue_display_frame_rows"]
private opaque Display.frameRowsRaw (display : @& Display) (view : UInt64) : IO RawWords

/-- The rows the view numbered `view` shows in the latest frame; `none` when
the frame has no such view. -/
def Display.frameRows (display : Display) (view : UInt64) : IO (Option (Array DisplayRow)) := do
  rowsOf? (← display.frameRowsRaw view)

/-- The last scene published, as the glue builds it: its words, its string,
and 0, or nothing and 1 before any. Object fields first, so the order here is
the layout the glue writes. -/
private structure RawScene where
  /-- The words. -/
  words : ByteArray
  /-- The string. -/
  strings : String
  /-- 0 when a scene was published. -/
  status : UInt64

/-- `Display.scene` as it crosses. -/
@[extern "editor_glue_display_scene"]
private opaque Display.sceneRaw (display : @& Display) : IO RawScene

/-- The last scene published, as the library writes it back: the words and
the string it was sent. `none` before any. -/
def Display.scene (display : Display) : IO (Option (Array UInt64 × String)) := do
  let raw ← display.sceneRaw
  if raw.status != 0 then
    return none
  let some words := wordsOf? raw.words
    | throw (IO.userError "the library's scene is not whole words")
  return some (words, raw.strings)

/-! ## A display's picture, for tests -/

/-- A new display over the library's real shaper and one font file, `bytes`,
whose family `family` is the default family of a font set with no font of
the machine: a face naming any other family is drawn in it. An `IO` error
with the library's reason when the bytes are not a font or hold no such
family. For tests, as `Display.frameText` is: what it lays out is the same
on every machine (`Themes.Picture.themePicturesScenario`, `Editor/Theme/Picture.lean`). -/
@[extern "editor_glue_display_new_font"]
opaque Display.newFont (bytes : @& ByteArray) (family : @& String) : IO Display

/-- A picture, as the library's CPU renderer draws one: `width` pixels
across, `height` down, and its pixels, row by row from the top, red, green,
blue and alpha for each, as sRGB values. For tests. -/
structure Picture where
  /-- How far across it is. -/
  width : Nat
  /-- How far down. -/
  height : Nat
  /-- Its pixels: four bytes each. -/
  rgba : ByteArray
  deriving DecidableEq

/-- A picture as the glue builds it. Object fields first, so the order here
is the layout the glue writes. -/
private structure RawPicture where
  /-- The pixels. -/
  rgba : ByteArray
  /-- How far across. -/
  width : UInt64
  /-- How far down. -/
  height : UInt64

/-- The picture `raw` stands for. -/
private def RawPicture.picture (raw : RawPicture) : Picture :=
  { width := raw.width.toNat, height := raw.height.toNat, rgba := raw.rgba }

/-- `Display.picture` as it crosses. -/
@[extern "editor_glue_display_picture"]
private opaque Display.pictureRaw (display : @& Display) : IO RawPicture

/-- The latest frame the display laid out, drawn by the library's CPU
renderer synchronously, with no render session, thread or clock, at the
last published scene's size and at the display's scale, with one coverage a
pixel and hinting: 0 by 0 before any scene. For tests: it is how a theme
written here reaches the renderer in `ffi-test`. -/
def Display.picture (display : Display) : IO Picture :=
  return (← display.pictureRaw).picture

/-- `Picture.ofPng` as it crosses. -/
@[extern "editor_glue_picture_from_png"]
private opaque Picture.ofPngRaw (bytes : @& ByteArray) : IO RawPicture

/-- The picture the PNG file `bytes` holds, 8 bits a channel, RGB or RGBA,
an RGB one read as opaque; an `IO` error with the library's reason when the
bytes are no such file. For tests. -/
def Picture.ofPng (bytes : ByteArray) : IO Picture :=
  return (← Picture.ofPngRaw bytes).picture

/-- `Picture.toPng` as it crosses. -/
@[extern "editor_glue_picture_to_png"]
private opaque Picture.toPngRaw (width height : UInt64) (rgba : @& ByteArray) : IO ByteArray

/-- The bytes of a PNG file of `picture`: RGB, 8 bits a channel, its alpha
not written. An `IO` error with the library's reason when its pixels are
not its size or it is one no PNG file can hold, such as one 0 by 0. For
tests. -/
def Picture.toPng (picture : Picture) : IO ByteArray :=
  Picture.toPngRaw picture.width.toUInt64 picture.height.toUInt64 picture.rgba

end Editor.Ffi
