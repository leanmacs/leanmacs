import Editor.Ffi.Transaction
import Editor.Ffi.Words

/-!
# Bindings: kept inverses

The bindings of `crates/editor-ffi/src/inverse.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("Plain data").
-/

namespace Editor.Ffi

open Words

/-- What applying the inverse of a run of revisions did. -/
structure Inverted where
  /-- The revision the inverse produced. -/
  revision : UInt64
  /-- The selection in force before the run: the selection before that the
  run's first transaction carried, in the text as the inverse left it. `none`
  when that transaction carried none. -/
  selection : Option Selection
  deriving DecidableEq, Repr

/-- Why the library refused the inverse of a run. -/
inductive InverseRefusal where
  /-- The document has not reached a revision of the run. -/
  | unknownRevision
  /-- The document keeps no inverse for a revision of the run: the run starts
  at revision 0, its first revision is after its last, or one of its inverses
  was dropped. -/
  | noInverse
  /-- The document's text is not in the state the run ended in. -/
  | notInState
  /-- The document is an excerpt document, whose inverses are refused: the
  undo of an edit through it is its sources'. -/
  | excerpted
  deriving DecidableEq, Repr

/-- The inverted result `words` spell: the revision, a presence word, and for
a selection its words (`selectionAt?`). `none` when they spell none. -/
private def invertedOf? (words : Array UInt64) : Option Inverted := do
  let revision ← words[0]?
  let present : UInt64 ← words[1]?
  match present with
  | 0 =>
    guard (words.size == 2)
    return { revision, selection := none }
  | 1 =>
    return { revision, selection := some (← selectionAt? words 2) }
  | _ =>
    none

/-- `Document.applyInverse` as it crosses: the run and the origin as numbers,
and the inverted result as words with the status 0, or no words and the
status of the refusal. -/
@[extern "editor_glue_document_apply_inverse"]
private opaque Document.applyInverseRaw (document : @& Document) (first last origin : UInt64) :
    IO RawWords

/-- Applies to the document the inverse of the run of revisions from `first`
to `last`, both included, as one transaction, recording `origin` as who made
the edit: the document holds again what it held before the transaction that
produced `first`. It is one more revision and one entry of the log, like any
transaction, and its own inverse is kept, so the inverse of the revision this
returns takes it back.

A refused inverse changes nothing. An excerpt document is refused first,
then a run that names a revision the document has not reached, then a run the document keeps no inverse
for, then a run the text is not in the state at the end of: the text is there
just after the run, and again whenever inverses have brought it back, and
not when it merely reads the same. A revision given as the largest `UInt64`
is one no document has reached. -/
def Document.applyInverse (document : Document) (first last origin : UInt64) :
    IO (Except InverseRefusal Inverted) := do
  let raw ← document.applyInverseRaw first last origin
  match raw.status with
  | 0 =>
    match (wordsOf? raw.words).bind invertedOf? with
    | some inverted =>
      return .ok inverted
    | none =>
      throw (IO.userError "the library's words do not spell an inverted result")
  | 1 =>
    return .error .unknownRevision
  | 2 =>
    return .error .noInverse
  | 3 =>
    return .error .notInState
  | 4 =>
    return .error .excerpted
  | status =>
    throw (IO.userError s!"the library reported an unknown inverse status ({status})")

/-- Drops the document's kept inverses for the revisions from `first` to
`last`, and returns whether the library did. Afterwards the inverse of a run
that names one of them is refused. The text and its log are untouched; a
revision with no inverse kept is passed over.

`false`, with nothing dropped, for a `last` the document has not reached. -/
@[extern "editor_glue_document_drop_inverses"]
opaque Document.dropInverses (document : @& Document) (first last : UInt64) : IO Bool

end Editor.Ffi
