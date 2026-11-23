import Editor.Ffi.Transaction
import Editor.Ffi.Words
import Editor.InferredWait

/-!
# Bindings: the diff service

The bindings of `crates/editor-ffi/src/diffs.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("Services and completions").
-/

namespace Editor.Ffi

open Words

/-- Asks the library's diff service for the line diff of what `old` and
`new` hold, with its engine asked about at most `limit` lines a side, as the
request `id`, and returns whether it was accepted. It returns at once, and
the library keeps its own hold on both texts. The completion is a
`completion` event on the completion queue, from the library source 5, whose
code is `id`; there is none if the request is cancelled first. The script is
then taken with `diffsTake`. `false`, with nothing started, if `id` is in use
or the service could not start its thread. -/
@[extern "editor_glue_diffs_start"]
opaque diffsStart (id : UInt64) (old new : @& Snapshot) (limit : UInt64) : IO Bool

/-- `diffsTake` before its words are decoded. -/
@[extern "editor_glue_diffs_take"]
private opaque diffsTakeRaw (id : UInt64) : IO (Option ByteArray)

/-- The edit script `bytes` spell: the count of steps, then a kind and two
numbers for each (`crates/editor-ffi/src/diffs.rs`, "How a script
crosses"). An error, with what was wrong, for words that spell none. It is
public for `FfiTest`. -/
def ScriptStep.decode (bytes : ByteArray) : Except String (Array ScriptStep) := do
  let some words := wordsOf? bytes | throw "its words are not whole words"
  let some count := words[0]? | throw "it has no count"
  unless words.size == 1 + 3 * count.toNat do
    throw s!"{count} steps are not {words.size - 1} words"
  (Array.range count.toNat).mapM fun index =>
      match words[1 + 3 * index]!, words[2 + 3 * index]!, words[3 + 3 * index]! with
      | 0, count, 0 => pure (.retain count)
      | 1, count, 0 => pure (.delete count)
      | 2, start, count => pure (.insert start count)
      | kind, _, _ => throw s!"the step kind {kind} is no step"

/-- Hands over the script of the diff request `id`, once. `none` when the
service keeps no script for `id`. It throws if the library sends words these
bindings cannot read. -/
def diffsTake (id : UInt64) : IO (Option (Array ScriptStep)) := do
  let some bytes ← diffsTakeRaw id | return none
  match ScriptStep.decode bytes with
  | .ok script =>
    return some script
  | .error reason =>
    throw (IO.userError s!"the library's edit script could not be read: {reason}")

/-- As `diffsStart`, for the hunks of whole lines of the two texts in place of
a script, which are taken with `diffsTakeHunks`. -/
@[extern "editor_glue_diffs_start_hunks"]
opaque diffsStartHunks (id : UInt64) (old new : @& Snapshot) (limit : UInt64) : IO Bool

/-- `diffsTakeHunks` before its words are decoded. -/
@[extern "editor_glue_diffs_take_hunks"]
private opaque diffsTakeHunksRaw (id : UInt64) : IO (Option ByteArray)

/-- The hunks `bytes` spell: the count of hunks, then four numbers for each
(`crates/editor-ffi/src/diffs.rs`, "How hunks cross"). An error, with what was
wrong, for words that spell none. -/
def HunkWords.decode (bytes : ByteArray) : Except String (Array HunkWords) := do
  let some words := wordsOf? bytes | throw "its words are not whole words"
  let some count := words[0]? | throw "it has no count"
  unless words.size == 1 + 4 * count.toNat do
    throw s!"{count} hunks are not {words.size - 1} words"
  return (Array.range count.toNat).map fun index =>
      { oldStart := words[1 + 4 * index]!, oldStop := words[2 + 4 * index]!
        newStart := words[3 + 4 * index]!, newStop := words[4 + 4 * index]! }

/-- Hands over the hunks of the diff request `id`, once. `none` when the
service keeps no hunks for `id`, a script among them. It throws if the library
sends words these bindings cannot read. -/
def diffsTakeHunks (id : UInt64) : IO (Option (Array HunkWords)) := do
  let some bytes ← diffsTakeHunksRaw id | return none
  match HunkWords.decode bytes with
  | .ok hunks =>
    return some hunks
  | .error reason =>
    throw (IO.userError s!"the library's hunks could not be read: {reason}")

/-- Cancels the diff request `id`, and returns whether there was anything to
cancel. Safe for an id that is unknown. -/
@[extern "editor_glue_diffs_cancel"]
opaque diffsCancel (id : UInt64) : IO Bool

/-- Asks the diff service for the request `id` to be completed once every
diff started before this call has been worked, and returns whether it was
accepted. It returns at once and keeps no answer. -/
@[extern "editor_glue_diffs_flush"]
opaque diffsFlush (id : UInt64) : IO Bool

/-- `diffsPending` is an inferred wait (`Editor/InferredWait.lean`). -/
def diffsPending.inferredWait : InferredWait :=
  .count
    [`Editor.Job.Real, `Editor.Job.Contract, `Editor.Job.FlushContract, `Editor.Job.HandleContract,
      `Editor.Test.Linked.Services]

/-- How many diff requests are waiting or being worked, and how many answers
(scripts or hunks) have not yet been taken, together. A readout for tests. -/
@[extern "editor_glue_diffs_pending"]
opaque diffsPending : IO UInt64

end Editor.Ffi
