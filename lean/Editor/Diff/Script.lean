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

end Diff

end Editor
