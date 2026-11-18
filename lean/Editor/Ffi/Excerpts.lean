import Editor.Ffi.Snapshot
import Editor.Ffi.Words

/-!
# Bindings: excerpt documents

The bindings of `crates/editor-ffi/src/excerpts.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("Plain data").
-/

namespace Editor.Ffi

open Words

/-- A new excerpt document with no excerpts: a document whose text is made of
ranges of other documents, its sources, joined by one line feed
(`crates/editor-ffi/src/excerpts.rs`). Its text is caught up with its
sources whenever it is read, so a snapshot of it, its edit log and its
markers follow them; its edits are its sources' edits, and its inverse, edit
script and trace are refused. It holds its sources' texts, so a source freed
is read as it was, and no longer edited through it. -/
@[extern "editor_glue_excerpts_new"]
opaque Document.excerptsNew : IO Document

/-- Why the library refused an excerpt document's list. -/
inductive ExcerptRefusal where
  /-- The document is not an excerpt document. -/
  | notExcerpts
  /-- A source is an excerpt document. -/
  | excerpted
  /-- A range is not two positions of its source in order. -/
  | badRange
  deriving DecidableEq, Repr

/-- `Document.excerptsSet` as it crosses: the sources as an array of
handles, and the list as words, the count of excerpts and then the index of
each one's source in the array, its start and its end. -/
@[extern "editor_glue_excerpts_set"]
private opaque Document.excerptsSetRaw (document : @& Document) (sources : @& Array Document)
    (words : @& ByteArray) : IO UInt64

/-- Replaces the list of the excerpt document with `list`: for each excerpt,
the index in `sources` of its source, and its range there, as byte offsets.
A refused list changes nothing: a document that is not an excerpt document
is refused first, then a source that is one, then a range that is not two
positions of its source in order. An index into `sources` that names none
is a fault of the caller's, thrown. -/
def Document.excerptsSet (document : Document) (sources : Array Document)
    (list : Array (Nat × UInt64 × UInt64)) : IO (Except ExcerptRefusal Unit) := do
  let words :=
    list.foldl
      (fun words (index, start, stop) =>
        pushWord (pushWord (pushWord words index.toUInt64) start) stop)
      (pushWord ByteArray.empty list.size.toUInt64)
  match ← document.excerptsSetRaw sources words with
  | 0 =>
    return .ok ()
  | 1 =>
    return .error .notExcerpts
  | 2 =>
    return .error .excerpted
  | 4 =>
    return .error .badRange
  | status =>
    throw (IO.userError s!"the library could not read an excerpt list (status {status})")

/-- Whether the document is an excerpt document. -/
@[extern "editor_glue_document_is_excerpts"]
opaque Document.isExcerpts (document : @& Document) : IO Bool

/-- Where an offset of an excerpt document is, as the glue builds it in one
call: `UInt64` fields only, so the order here is the layout the glue
writes. -/
private structure RawLocated where
  /-- 0 found, 1 not an excerpt document, 2 not a position, 3 an empty
  list. -/
  status : UInt64
  /-- The index of the excerpt, when found. -/
  excerpt : UInt64
  /-- The offset in its source, when found. -/
  offset : UInt64

/-- `Document.excerptsLocate` as it crosses. -/
@[extern "editor_glue_excerpts_locate"]
private opaque Document.excerptsLocateRaw (document : @& Document) (offset : USize) : IO RawLocated

/-- Why the library did not locate an offset of an excerpt document. -/
inductive LocateRefusal where
  /-- The document is not an excerpt document. -/
  | notExcerpts
  /-- The offset is not a position of the document's text. -/
  | badPosition
  deriving DecidableEq, Repr

/-- Which excerpt of the excerpt document holds the position `offset` of its
text, caught up first, and the offset in that excerpt's source as the source
is now: `none` for an empty list. An excerpt holds both its ends. -/
def Document.excerptsLocate (document : Document) (offset : USize) :
    IO (Except LocateRefusal (Option (Nat × Nat))) := do
  let raw ← document.excerptsLocateRaw offset
  match raw.status with
  | 0 =>
    return .ok (some (raw.excerpt.toNat, raw.offset.toNat))
  | 1 =>
    return .error .notExcerpts
  | 2 =>
    return .error .badPosition
  | 3 =>
    return .ok none
  | status =>
    throw (IO.userError s!"the library answered a locate with an unknown status {status}")

/-- `Snapshot.excerpts` as it crosses: the list as words, and its status. -/
@[extern "editor_glue_snapshot_excerpts"]
private opaque Snapshot.excerptsRaw (snapshot : @& Snapshot) : IO RawWords

/-- The list a snapshot of an excerpt document carries, as it was when the
snapshot was taken: for each excerpt, its start and its end in the
snapshot's text and its start and its end in its source. `none` for a
snapshot of any other document. Words that do not spell a list are an
error. -/
def Snapshot.excerpts (snapshot : Snapshot) : IO (Option (Array (Nat × Nat × Nat × Nat))) := do
  let raw ← snapshot.excerptsRaw
  match raw.status with
  | 0 =>
    let some words := wordsOf? raw.words
      | throw (IO.userError "the library's excerpt list is not whole words")
    let count := (words[0]?.getD 0).toNat
    unless words.size == 1 + 4 * count do
      throw (IO.userError "the library's excerpt list does not spell its count")
    return some <|
        (Array.range count).map fun index =>
          let word (field : Nat) := words[1 + 4 * index + field]!.toNat
          (word 0, word 1, word 2, word 3)
  | 1 =>
    return none
  | status =>
    throw (IO.userError s!"the library answered an excerpt list with an unknown status {status}")

end Editor.Ffi
