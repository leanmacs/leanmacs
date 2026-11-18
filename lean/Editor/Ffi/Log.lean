import Editor.Ffi.Snapshot
import Editor.Ffi.Words

/-!
# Bindings: the edit log

The bindings of `crates/editor-ffi/src/log.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("Plain data").
-/

namespace Editor.Ffi

open Words

/-- A range of one text, as byte offsets and as points with their columns in
bytes. -/
structure Span where
  /-- The offset the range starts at. -/
  start : UInt64
  /-- The offset the range stops at, not included. -/
  stop : UInt64
  /-- The point of `start`. -/
  startPoint : Point
  /-- The point of `stop`. -/
  stopPoint : Point
  deriving DecidableEq, Repr

/-- One changed range: the bytes of `old`, a range of the text before, were
replaced by the bytes of `new`, a range of the text after. -/
structure Edit where
  /-- The range that was replaced, in the text before. -/
  old : Span
  /-- The range that replaced it, in the text after. -/
  new : Span
  deriving DecidableEq, Repr

/-- What changed in a document between two of its revisions, as one set of
edits in order, no two of which overlap or touch. -/
structure Patch where
  /-- The revision the patch starts from: the old spans are ranges of the
  text then. -/
  since : UInt64
  /-- The revision the patch reaches: the new spans are ranges of the text
  then, which is the text when the patch was asked for. -/
  revision : UInt64
  /-- What changed. -/
  edits : Array Edit
  deriving DecidableEq, Repr

/-- Why the library could not say what changed since a revision. -/
inductive LogRefusal where
  /-- The document has not reached the revision. -/
  | unknownRevision
  /-- The revision is before the log's horizon: `Document.forget` dropped the
  entries that led from it. -/
  | forgotten
  deriving DecidableEq, Repr

/-- Where a piece of a document's text came from. -/
inductive Author where
  /-- The transaction that produced `revision`, applied with `origin`,
  inserted the bytes. -/
  | entry (revision origin : UInt64)
  /-- The bytes were already in the text at `revision`, which is as far back
  as the log reaches. -/
  | earlier (revision : UInt64)
  deriving DecidableEq, Repr

/-- One piece of a traced range: the bytes from `start` up to, not including,
`stop`, of the text as it is now, and where they came from. -/
structure Attribution where
  /-- The offset the piece starts at. -/
  start : UInt64
  /-- The offset the piece stops at, not included. -/
  stop : UInt64
  /-- Where its bytes came from. -/
  author : Author
  deriving DecidableEq, Repr

/-- The span six words spell, from the index `first`: its offsets, then its
points. -/
private def spanAt (words : Array UInt64) (first : Nat) : Span where
  start := words[first]!
  stop := words[first + 1]!
  startPoint := { row := words[first + 2]!, column := words[first + 3]! }
  stopPoint := { row := words[first + 4]!, column := words[first + 5]! }

/-- The patch `words` spell: the two revisions, the count of edits, and
twelve words an edit. `none` unless the count is the count of edits there. -/
private def patchOf? (words : Array UInt64) : Option Patch := do
  let count := (← words[2]?).toNat
  guard (words.size == 3 + 12 * count)
  return {
      since := ← words[0]?
      revision := ← words[1]?
      edits :=
        (Array.range count).map fun edit =>
          { old := spanAt words (3 + 12 * edit), new := spanAt words (3 + 12 * edit + 6) } }

/-- The piece five words spell, from the index `first`. `none` when the word
that says who wrote it is neither 0 nor 1. -/
private def attributionAt? (words : Array UInt64) (first : Nat) : Option Attribution := do
  let author ←
    match words[first + 2]! with
    | 0 =>
      some (Author.earlier words[first + 3]!)
    | 1 =>
      some (Author.entry words[first + 3]! words[first + 4]!)
    | _ =>
      none
  return { start := words[first]!, stop := words[first + 1]!, author }

/-- The trace `words` spell: the count of pieces, and five words a piece.
`none` unless the count is the count of pieces there. -/
private def traceOf? (words : Array UInt64) : Option (Array Attribution) := do
  let count := (← words[0]?).toNat
  guard (words.size == 1 + 5 * count)
  (Array.range count).mapM fun piece => attributionAt? words (1 + 5 * piece)

/-- `Document.changesSince` as it crosses. -/
@[extern "editor_glue_document_changes_since"]
private opaque Document.changesSinceRaw (document : @& Document) (revision : UInt64) : IO RawWords

/-- What changed in the document since `revision`, as one patch: however many
transactions were applied since, their changes come back as one set of edits.
Text inserted and deleted again in between is in none of them. Empty when
`revision` is the document's revision now.

A consumer that wants to follow a document keeps the revision of the last
patch it got and asks again from there: nothing is registered with the
library. -/
def Document.changesSince (document : Document) (revision : UInt64) :
    IO (Except LogRefusal Patch) := do
  let raw ← document.changesSinceRaw revision
  match raw.status with
  | 0 =>
    match (wordsOf? raw.words).bind patchOf? with
    | some patch =>
      return .ok patch
    | none =>
      throw (IO.userError "the library's words do not spell a patch")
  | 1 =>
    return .error .unknownRevision
  | 2 =>
    return .error .forgotten
  | status =>
    throw (IO.userError s!"the library reported an unknown log status ({status})")

/-- `Document.trace` as it crosses: the words, when the library gave any. -/
@[extern "editor_glue_document_trace"]
private opaque Document.traceRaw (document : @& Document) (start stop : USize) :
    IO (Option ByteArray)

/-- Where the bytes of the document from `start` up to, not including, `stop`
came from: the range cut into pieces, in order, each with the revision and
the origin of the transaction that inserted it, or as earlier than the log
reaches. `none` unless both offsets are positions of the text and
`start ≤ stop`. -/
def Document.trace (document : Document) (start stop : USize) : IO (Option (Array Attribution)) :=
  do
  let some words ← document.traceRaw start stop | return none
  match (wordsOf? words).bind traceOf? with
  | some trace =>
    return some trace
  | none =>
    throw (IO.userError "the library's words do not spell a trace")

/-- Drops the entries of the document's log up to `revision`, and returns
whether the library did. Afterwards `changesSince` an earlier revision is
refused as forgotten, and `trace` names older bytes as earlier than
`revision`. The text is untouched.

`false`, with nothing changed, for a revision the document has not
reached. -/
@[extern "editor_glue_document_forget"]
opaque Document.forget (document : @& Document) (revision : UInt64) : IO Bool

end Editor.Ffi
