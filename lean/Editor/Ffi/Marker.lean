import Editor.Ffi.Text
import Editor.Ffi.Transaction
import Editor.Ffi.Words

/-!
# Bindings: markers

The bindings of `crates/editor-ffi/src/marker.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("Plain data").

`Snapshot.extents` is here too: it binds `snapshot.rs`'s `snapshot_extents`,
whose logic is the marker's.
-/

namespace Editor.Ffi

open Words

/-- Which side of text inserted at an anchor the anchor stays on. -/
inductive Bias where
  /-- The anchor stays before the inserted text. -/
  | before
  /-- The anchor goes after the inserted text. -/
  | after
  deriving DecidableEq, Repr

/-- A position in a document's text that the library moves with every
transaction: a byte offset and a bias. -/
structure Anchor where
  /-- Where the anchor is. -/
  offset : UInt64
  /-- Which side of text inserted at the anchor it stays on. -/
  bias : Bias
  deriving DecidableEq, Repr

/-- Something a document holds and moves with every transaction it accepts. -/
inductive Marker where
  /-- One position. -/
  | anchor (anchor : Anchor)
  /-- A selection. Read back, its ranges are sorted and those that overlapped
  are one. -/
  | selection (selection : Selection)
  deriving DecidableEq, Repr

/-- Why the library refused a marker. -/
inductive MarkRefusal where
  /-- The anchor's offset is not a position of the text. -/
  | badPosition
  /-- The selection has no range, its primary names none, or an end of one of
  its ranges is not a position of the text. -/
  | badSelection
  /-- The document holds no marker with that id. -/
  | noSuchMarker
  deriving DecidableEq, Repr

/-- A marker as it crosses: its words. An anchor is 0, its offset and its
bias (0 before, 1 after); a selection is 1 and its words (`pushShaped`). -/
private def Marker.words : Marker → ByteArray
  | .anchor position =>
    let bias : UInt64 :=
      match position.bias with
      | .before => 0
      | .after => 1
    pushWord (pushWord (pushWord ByteArray.empty 0) position.offset) bias
  | .selection ranges => pushShaped (pushWord ByteArray.empty 1) ranges

/-- The marker `words` spell, in the layout of `Marker.words`. `none` when
they spell none. -/
private def markerOf? (words : Array UInt64) : Option Marker := do
  let kind : UInt64 ← words[0]?
  match kind with
  | 0 =>
    guard (words.size == 3)
    let side : UInt64 ← words[2]?
    let bias ←
      match side with
      | 0 =>
        some Bias.before
      | 1 =>
        some Bias.after
      | _ =>
        none
    return .anchor { offset := ← words[1]?, bias }
  | 1 =>
    return .selection (← selectionAt? words 1)
  | _ =>
    none

/-- The extents `words` spell: their count, and a start and a stop for each.
`none` unless the count is the count of extents there. -/
private def extentsOf? (words : Array UInt64) : Option (Array ByteRange) := do
  let count := (← words[0]?).toNat
  guard (words.size == 1 + 2 * count)
  return (Array.range count).map fun extent =>
      { start := words[1 + 2 * extent]!, stop := words[1 + 2 * extent + 1]! }

/-- The refusal a status of the library's stands for: 1 a bad position, 2 a
bad selection, 4 no such marker. An error for any other status, 3 among them:
words the library could not read are a fault of this file's, not a
refusal. -/
private def markRefusal (status : UInt64) : IO MarkRefusal :=
  match status with
  | 1 => return .badPosition
  | 2 => return .badSelection
  | 4 => return .noSuchMarker
  | status => throw (IO.userError s!"the library could not read a marker's words (status {status})")

/-- The result of marking a document, as the glue builds it in one call:
`UInt64` fields only, so the order here is the layout the glue writes. -/
private structure RawMarked where
  /-- 0 marked, and otherwise the status of the refusal (`markRefusal`). -/
  status : UInt64
  /-- The id of the new marker, when it was marked. -/
  id : UInt64

/-- `Document.mark` as it crosses: the marker as words. -/
@[extern "editor_glue_document_mark"]
private opaque Document.markRaw (document : @& Document) (words : @& ByteArray) : IO RawMarked

/-- Has the document hold `marker`, and returns the id it is read back by.
From now on every transaction the document accepts moves the marker, until
it is given up (`Document.unmark`). The library never gives an id out twice.

Refused, holding nothing, unless the marker is in the text as it is now: an
anchor's offset is a position, and every end of every range of a selection
is one. An offset given as the largest `UInt64` is one no text accepts. -/
def Document.mark (document : Document) (marker : Marker) : IO (Except MarkRefusal UInt64) := do
  let raw ← document.markRaw marker.words
  if raw.status == 0 then
    return .ok raw.id
  else
    return .error (← markRefusal raw.status)

/-- `Document.marker` as it crosses: the marker's words, with the status 0,
or no words and the status 4. -/
@[extern "editor_glue_document_marker"]
private opaque Document.markerRaw (document : @& Document) (id : UInt64) : IO RawWords

/-- The marker with the id `id`, where it is in the document's text as it is
now. `none` when the document holds no such marker. -/
def Document.marker (document : Document) (id : UInt64) : IO (Option Marker) := do
  let raw ← document.markerRaw id
  if raw.status != 0 then
    return none
  match (wordsOf? raw.words).bind markerOf? with
  | some marker =>
    return some marker
  | none =>
    throw (IO.userError "the library's words do not spell a marker")

/-- `Document.place` as it crosses: the marker as words, and the status that
comes back. -/
@[extern "editor_glue_document_place"]
private opaque Document.placeRaw (document : @& Document) (id : UInt64) (words : @& ByteArray) :
    IO UInt64

/-- Puts `marker` in place of the marker with the id `id`, which keeps its
id. A refused place changes nothing. A selection that is none (no range, or
a primary that names none) is refused first, then an id the document holds
no marker for, then a marker that is not in the text. -/
def Document.place (document : Document) (id : UInt64) (marker : Marker) :
    IO (Except MarkRefusal Unit) := do
  let status ← document.placeRaw id marker.words
  if status == 0 then
    return .ok ()
  else
    return .error (← markRefusal status)

/-- Gives up the marker with the id `id`, and returns whether the document
held one. The id names nothing from then on. -/
@[extern "editor_glue_document_unmark"]
opaque Document.unmark (document : @& Document) (id : UInt64) : IO Bool

/-- `Snapshot.extents` as it crosses: the selection as words, and the extents
as words with the status 0, or no words and the status of the refusal. -/
@[extern "editor_glue_snapshot_extents"]
private opaque Snapshot.extentsRaw (snapshot : @& Snapshot) (words : @& ByteArray) : IO RawWords

/-- The ranges of bytes `selection` covers in the snapshot's text, by its
shape, sorted, with those that overlap made one. `none` when the selection
is none (no range, or a primary that names none) or an end of one of its
ranges is not a position of the text. -/
def Snapshot.extents (snapshot : Snapshot) (selection : Selection) :
    IO (Option (Array ByteRange)) := do
  let raw ← snapshot.extentsRaw (pushShaped ByteArray.empty selection)
  match raw.status with
  | 0 =>
    match (wordsOf? raw.words).bind extentsOf? with
    | some extents =>
      return some extents
    | none =>
      throw (IO.userError "the library's words do not spell extents")
  | 2 =>
    return none
  | status =>
    throw (IO.userError s!"the library could not read a selection's words (status {status})")

end Editor.Ffi
