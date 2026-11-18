import Editor.Ffi.Snapshot
import Editor.Ffi.Words

/-!
# Bindings: transactions

The bindings of `crates/editor-ffi/src/transaction.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("Plain data").

The selection codec (`Words.pushShaped`, `Words.selectionAt?`) is here, beside
`Selection`, under `Editor.Ffi.Words` with the rest of the word codec.
-/

namespace Editor.Ffi

open Words

/-- One step of a change set's walk over a document's text, with its length
in bytes. -/
inductive Change where
  /-- Keep the next `count` bytes. -/
  | retain (count : UInt64)
  /-- Remove the next `count` bytes. -/
  | delete (count : UInt64)
  /-- Put `text` in at this point. -/
  | insert (text : String)
  deriving DecidableEq, Repr

/-- One range of a selection: two byte offsets. -/
structure SelectionRange where
  /-- The end that stays when the selection is extended. -/
  anchor : UInt64
  /-- The end that moves. -/
  head : UInt64
  deriving DecidableEq, Repr

/-- What the ranges of a selection cover, given their two ends. -/
inductive Shape where
  /-- From the lower end up to, not including, the higher. -/
  | exclusive
  /-- From the lower end through the character at the higher. -/
  | inclusive
  /-- The whole rows of both ends and those between them. -/
  | line
  /-- A rectangle of characters whose corners are the two ends. -/
  | block
  deriving DecidableEq, Repr

/-- The ranges of a selection, which of them is the primary one, and the
shape they all have. The library sorts the ranges and makes those that
overlap one. -/
structure Selection where
  /-- The ranges, in any order. -/
  ranges : Array SelectionRange
  /-- The index in `ranges` of the primary range. -/
  primary : UInt64 := 0
  /-- What the ranges cover. -/
  shape : Shape := .exclusive
  deriving DecidableEq, Repr

/-- A transaction, as plain data: the changes to make to a document's text,
and optionally the selection before them and the selection after them. -/
structure Transaction where
  /-- The changes, which walk the text from its start to its end. -/
  changes : Array Change
  /-- The selection in the text before the changes. -/
  before : Option Selection := none
  /-- The selection in the text after the changes. -/
  after : Option Selection := none
  deriving DecidableEq, Repr

/-- Why the library refused a transaction. -/
inductive ApplyRefusal where
  /-- The changes do not fit the text: they are for another length, or a
  boundary between two of them is inside a character. -/
  | badChange
  /-- A selection has no range, its primary names none, or an end of one of
  its ranges is not a position of its text. -/
  | badSelection
  /-- The document is an excerpt document, whose edit scripts are refused. -/
  | excerpted
  /-- The document is an excerpt document, and a range the transaction changes
  is not inside one excerpt, or meets two excerpts of one source. -/
  | outsideExcerpt
  /-- The document is an excerpt document, and the transaction reaches an
  excerpt of a source that was freed. -/
  | noSuchSource
  deriving DecidableEq, Repr

/-- The shape as a word: 0 exclusive, 1 inclusive, 2 line-wise, 3
block-wise. -/
private def Shape.word : Shape → UInt64
  | .exclusive => 0
  | .inclusive => 1
  | .line => 2
  | .block => 3

/-- The words of a selection: its shape, its primary, its count of ranges,
and an anchor and a head for each. -/
def Words.pushShaped (words : ByteArray) (selection : Selection) : ByteArray :=
  let words := pushWord (pushWord words selection.shape.word) selection.primary
  selection.ranges.foldl (fun words range => pushWord (pushWord words range.anchor) range.head)
    (pushWord words selection.ranges.size.toUInt64)

/-- The shape a word stands for. `none` for a word that is none of the
four. -/
private def Shape.ofWord? : UInt64 → Option Shape
  | 0 => some .exclusive
  | 1 => some .inclusive
  | 2 => some .line
  | 3 => some .block
  | _ => none

/-- The selection the words from the index `first` to the last spell, in the
layout of `pushShaped`: its shape, its primary, its count of ranges, and an
anchor and a head for each. `none` when they spell none, or the count is not
the count of ranges there. -/
def Words.selectionAt? (words : Array UInt64) (first : Nat) : Option Selection := do
  let shape ← Shape.ofWord? (← words[first]?)
  let count := (← words[first + 2]?).toNat
  guard (words.size == first + 3 + 2 * count)
  return {
      ranges :=
        (Array.range count).map fun range =>
          { anchor := words[first + 3 + 2 * range]!, head := words[first + 3 + 2 * range + 1]! }
      primary := ← words[first + 1]?
      shape }

/-- The words of a selection block: a presence word, and for a selection its
words (`pushShaped`). -/
private def pushSelection (words : ByteArray) : Option Selection → ByteArray
  | none => pushWord words 0
  | some selection => pushShaped (pushWord words 1) selection

/-- The length of `change`, as the word that follows its kind. -/
private def Change.length : Change → UInt64
  | .retain count | .delete count => count
  | .insert text => text.utf8ByteSize.toUInt64

/-- The kind of `change`, as a word: 0 a retain, 1 a delete, 2 an insert. -/
private def Change.kind : Change → UInt64
  | .retain _ => 0
  | .delete _ => 1
  | .insert _ => 2

/-- A transaction as it crosses: its words. They are the count of changes, a
kind and a length for each, and a block for each selection. -/
private def Transaction.words (transaction : Transaction) : ByteArray :=
  let words := pushWord ByteArray.empty transaction.changes.size.toUInt64
  let words :=
    transaction.changes.foldl
      (fun words change => pushWord (pushWord words change.kind) change.length) words
  pushSelection (pushSelection words transaction.before) transaction.after

/-- Everything a transaction inserts, joined in order. An insert's length
cuts its text from it. -/
private def Transaction.inserted (transaction : Transaction) : String :=
  transaction.changes.foldl
    (fun inserted change =>
      match change with
      | .insert text => inserted ++ text
      | _ => inserted)
    ""

/-- The result of applying a transaction, as the glue builds it in one call:
`UInt64` fields only, so the order here is the layout the glue writes. -/
private structure RawApplied where
  /-- 0 applied, 1 the changes do not fit, 2 a selection does not fit, 3 the
  words could not be read, 4 the text moved past an edit script's revision,
  5 an excerpt document's edit script, 6 an edit outside one excerpt, 7 an
  edit of a freed source. -/
  status : UInt64
  /-- The revision the transaction produced, when it was applied. -/
  revision : UInt64

/-- `Document.apply` as it crosses: the transaction as words, and what it
inserts as one string. -/
@[extern "editor_glue_document_apply"]
private opaque Document.applyRaw (document : @& Document) (words : @& ByteArray)
    (inserted : @& String) (origin : UInt64) : IO RawApplied

/-- Applies `transaction` to the document, recording `origin` as who made the
edit, and returns the revision it produced: one more than before, however
many changes it has. `origin` is a number the library stores and gives back
(`Document.trace`) and never reads.

A refused transaction changes nothing. A selection that is none (no range, or
a primary that names none) is refused first, then changes that do not fit,
then a selection with an end that is not a position of its text. A length or
an offset given as the largest `UInt64` is one no text accepts.

An excerpt document's transaction is its sources' edit, and the revision is
the excerpt document's (`crates/editor-ffi/src/excerpts.rs`): after those
refusals, an edit outside one excerpt is `outsideExcerpt`, and one that
reaches a freed source `noSuchSource`. -/
def Document.apply (document : Document) (transaction : Transaction) (origin : UInt64) :
    IO (Except ApplyRefusal UInt64) := do
  let raw ← document.applyRaw transaction.words transaction.inserted origin
  match raw.status with
  | 0 =>
    return .ok raw.revision
  | 1 =>
    return .error .badChange
  | 2 =>
    return .error .badSelection
  | 5 =>
    return .error .excerpted
  | 6 =>
    return .error .outsideExcerpt
  | 7 =>
    return .error .noSuchSource
  | status =>
    throw (IO.userError s!"the library could not read a transaction's words (status {status})")

/-- One step of an edit script, as the library takes it and a diff gives it
back (`crates/editor-ffi/src/diffs.rs`). -/
inductive ScriptStep where
  /-- Keep the next `count` bytes. -/
  | retain (count : UInt64)
  /-- Remove the next `count` bytes. -/
  | delete (count : UInt64)
  /-- Put in the `count` bytes of the new text from `start`. -/
  | insert (start count : UInt64)
  deriving DecidableEq, Repr

/-- A hunk of a diff's answer, as the library gives it back
(`crates/editor-ffi/src/diffs.rs`, "How hunks cross"): byte ranges of whole
lines of the old text and the new. -/
structure HunkWords where
  /-- Where the old lines start. -/
  oldStart : UInt64
  /-- Where they stop. -/
  oldStop : UInt64
  /-- Where the new lines start. -/
  newStart : UInt64
  /-- Where they stop. -/
  newStop : UInt64
  deriving DecidableEq, Repr

/-- Why the library refused an edit script. -/
inductive ScriptRefusal where
  /-- The text has moved past the revision the script was made for. -/
  | moved
  /-- The steps do not walk the whole of the text and of the source, or one
  starts or stops inside a character of either. -/
  | badChange
  /-- The document is an excerpt document, whose edit scripts are refused. -/
  | excerpted
  deriving DecidableEq, Repr

/-- An edit script as it crosses: the count of steps, then a kind (0 a
retain, 1 a delete, 2 an insert) and two numbers for each. -/
private def scriptWords (script : Array ScriptStep) : ByteArray :=
  script.foldl
    (fun words step =>
      match step with
      | .retain count => pushWord (pushWord (pushWord words 0) count) 0
      | .delete count => pushWord (pushWord (pushWord words 1) count) 0
      | .insert start count => pushWord (pushWord (pushWord words 2) start) count)
    (pushWord ByteArray.empty script.size.toUInt64)

/-- `Document.applyScript` as it crosses: the script as words. -/
@[extern "editor_glue_document_apply_script"]
private opaque Document.applyScriptRaw (document : @& Document) (base : UInt64)
    (source : @& Snapshot) (words : @& ByteArray) (origin : UInt64) : IO RawApplied

/-- Applies the edit script `script` to the document as one transaction,
taking what it puts in from `source` and recording `origin` as who made the
edit, unless the document's revision is not `base`; and returns the revision
it produced. A refused script changes nothing: an excerpt document is
refused first, then the revision is looked at, under the document's lock,
then whether the steps fit. -/
def Document.applyScript (document : Document) (base : UInt64) (source : Snapshot)
    (script : Array ScriptStep) (origin : UInt64) : IO (Except ScriptRefusal UInt64) := do
  let raw ← document.applyScriptRaw base source (scriptWords script) origin
  match raw.status with
  | 0 =>
    return .ok raw.revision
  | 1 =>
    return .error .badChange
  | 4 =>
    return .error .moved
  | 5 =>
    return .error .excerpted
  | status =>
    throw (IO.userError s!"the library could not apply an edit script (status {status})")

end Editor.Ffi
