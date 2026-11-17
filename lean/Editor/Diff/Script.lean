/-!
# An edit script

What a line diff of two texts answers (`Editor/Diff.lean`), and what the text
port's `applyScript` applies (`Editor/Text.lean`): steps that walk an old text
from its start to its end, and a new text likewise, and name byte counts and
ranges of them, never text. It is plain data and imports nothing, so the text
port can use it.

- `retain count` keeps the next `count` bytes of the old text, which are the
  next `count` bytes of the new.
- `delete count` removes the next `count` bytes of the old text.
- `insert start count` puts in the `count` bytes of the new text from `start`,
  which is where the walk of the new text is.

A script names byte counts of the texts as the store holds them, so a byte a
load kept as its escape is the escape's four bytes, and no file byte ever
becomes a Lean string on the way (`Editor/File.lean`).

`Diff.Script.run` says what applying a script gives: the model of the diff
(`Editor/Diff/Model.lean`), the text port's model and both contracts use it.

A diff may answer **hunks** instead (`Diff.Hunk`): runs of whole lines of the
old text replaced by runs of whole lines of the new, as byte ranges of both,
each from a line's start to the next line's start or its text's end. An empty
old range is lines added, an empty new range lines removed, and the rest lines
changed (`Diff.Hunk.kind`). `Diff.Hunks.apply` says what applying them gives.
-/

namespace Editor

namespace Diff

/-- One step of an edit script's walk. -/
inductive Step where
  /-- Keep the next `count` bytes of the old text, which are the next `count`
  bytes of the new. -/
  | retain (count : Nat)
  /-- Remove the next `count` bytes of the old text. -/
  | delete (count : Nat)
  /-- Put in the `count` bytes of the new text from `start`. -/
  | insert (start count : Nat)
  deriving DecidableEq, Repr, Inhabited

/-- An edit script: steps that walk the old text from its start to its end,
and the new text likewise. -/
abbrev Script :=
  Array Step

/-- Whether `offset` is a character boundary of `bytes`, which are valid
UTF-8, within them: their end is one, and so is every offset whose byte does
not continue a character. -/
def boundary (bytes : ByteArray) (offset : Nat) : Bool :=
  offset == bytes.size || (offset < bytes.size && bytes.get! offset &&& 0xC0 != 0x80)

/-- What applying `script` to `old` gives, taking what it puts in from `new`:
`none` when the script does not walk the whole of both texts, a step runs past
one, an insert does not start where the walk of the new text is, or a step
starts or stops inside a character of either. -/
def Script.run (old new : String) (script : Script) : Option String := do
  let (oldBytes, newBytes) := (old.toUTF8, new.toUTF8)
  let mut (atOld, atNew) := (0, 0)
  let mut out := ByteArray.empty
  for step in script do
    match step with
    | .retain count =>
      unless atOld + count ≤ oldBytes.size ∧ atNew + count ≤ newBytes.size do
        none
      out := out ++ oldBytes.extract atOld (atOld + count)
      atOld := atOld + count
      atNew := atNew + count
    | .delete count =>
      unless atOld + count ≤ oldBytes.size do
        none
      atOld := atOld + count
    | .insert start count =>
      unless start == atNew ∧ atNew + count ≤ newBytes.size do
        none
      out := out ++ newBytes.extract atNew (atNew + count)
      atNew := atNew + count
    unless boundary oldBytes atOld && boundary newBytes atNew do
      none
  unless atOld == oldBytes.size ∧ atNew == newBytes.size do
    none
  String.fromUTF8? out

/-- The ranges of the old text that `script` retains, in order, each a start
and a stop. -/
def Script.retained (script : Script) : Array (Nat × Nat) :=
  (script.foldl
      (fun (offset, ranges) step =>
        match step with
        | .retain count => (offset + count, ranges.push (offset, offset + count))
        | .delete count => (offset + count, ranges)
        | .insert .. => (offset, ranges))
      (0, #[])).2

/-- How many runs of changes `script` has: runs of deletes and inserts between
two retains. -/
def Script.changedRuns (script : Script) : Nat :=
  (script.foldl
      (fun (runs, inRun) step =>
        match step with
        | .retain _ => (runs, false)
        | _ => (if inRun then runs else runs + 1, true))
      (0, false)).1

/-- A run of whole lines of the old text replaced by a run of whole lines of
the new, as byte ranges, each from a start up to, not including, a stop.
Either may be empty, never both. -/
structure Hunk where
  /-- Where the old lines start. -/
  oldStart : Nat
  /-- Where they stop. -/
  oldStop : Nat
  /-- Where the new lines start. -/
  newStart : Nat
  /-- Where they stop. -/
  newStop : Nat
  deriving DecidableEq, Repr, Inhabited

/-- What a hunk does to the old text's lines. -/
inductive Hunk.Kind where
  /-- Lines put in: the old range is empty. -/
  | added
  /-- Lines taken out: the new range is empty. -/
  | removed
  /-- Lines replaced. -/
  | changed
  deriving DecidableEq, Repr, Inhabited

/-- What `hunk` does: an empty old range is `added`, an empty new range
`removed`, and the rest `changed`. -/
def Hunk.kind (hunk : Hunk) : Hunk.Kind :=
  if hunk.oldStart == hunk.oldStop then .added
  else if hunk.newStart == hunk.newStop then .removed else .changed

/-- Hunks, in the order of both texts. -/
abbrev Hunks :=
  Array Hunk

/-- Whether `offset` of `bytes` is a line's start or their end: 0, their size,
or just after a line feed. -/
def onLine (bytes : ByteArray) (offset : Nat) : Bool :=
  offset == 0 || offset == bytes.size || (offset < bytes.size && bytes.get! (offset - 1) == 10)

/-- What applying `hunks` to `old` gives, taking what each puts in from `new`:
`none` when a hunk is out of order or out of range, a range does not start and
stop at a line's start or its text's end, or the walks of the two texts
between hunks, or after the last, are not as long. -/
def Hunks.apply (old new : String) (hunks : Hunks) : Option String := do
  let (oldBytes, newBytes) := (old.toUTF8, new.toUTF8)
  let mut (atOld, atNew) := (0, 0)
  let mut out := ByteArray.empty
  for hunk in hunks do
    unless
      atOld ≤ hunk.oldStart ∧
        hunk.oldStart ≤ hunk.oldStop ∧
        hunk.oldStop ≤ oldBytes.size ∧
        atNew ≤ hunk.newStart ∧
        hunk.newStart ≤ hunk.newStop ∧
        hunk.newStop ≤ newBytes.size ∧ hunk.oldStart - atOld == hunk.newStart - atNew do
      none
    unless
      onLine oldBytes hunk.oldStart && onLine oldBytes hunk.oldStop &&
        onLine newBytes hunk.newStart &&
        onLine newBytes hunk.newStop do
      none
    out :=
      out ++ oldBytes.extract atOld hunk.oldStart ++ newBytes.extract hunk.newStart hunk.newStop
    atOld := hunk.oldStop
    atNew := hunk.newStop
  unless oldBytes.size - atOld == newBytes.size - atNew ∧ atOld ≤ oldBytes.size do
    none
  String.fromUTF8? (out ++ oldBytes.extract atOld oldBytes.size)

end Diff

end Editor
