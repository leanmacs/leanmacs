import ContractTest.Check
import Editor.Ffi.Document
import Editor.Ffi.Snapshot
import Editor.Program
import Editor.Text
import Editor.Text.Contract
import Editor.Text.Model
import Editor.Text.Real

/-!
# Contract tests: `Editor/Text/Contract.lean`

The tests of `Editor/Text/Contract.lean`: `failures`, the text contract's
properties and the undo tree's cases against the real text binding, with
`releaseFrees`, `readerFinds` and `runHanded`, and `pairChecks`, of its bracket
walk against the text model. The root module `ContractTest` runs them; its
module doc says what each shows.
-/

namespace ContractTest

open Editor

/-- What must hold of the binding's tables once the contract has run. It is
not a property of the port, which has no way to say it: it is about the
library's objects, which only the real binding has. -/
def tableName : String :=
  "the real binding's table is the only holder of its documents and of its snapshots: they are all freed when it is dropped"

/-- What must hold of a release in the real binding. Like `tableName`, it is
about the library's objects, so the port cannot say it. -/
def releaseName : String :=
  "releasing a text or a snapshot frees the library's object at once, while the table is still held"

/-- Whether a release frees the library's object at once. A command makes two
texts and two snapshots and releases one of each; then, with the table it
left still held, the library must hold one document and one snapshot more
than before. -/
def releaseFrees : IO Bool := do
  let documents ← Ffi.Document.live
  let snapshots ← Ffi.Snapshot.live
  let command : TextM Unit := do
    let kept ← createText "kept"
    let dropped ← createText "dropped"
    discard kept.snapshot
    let released ← kept.snapshot
    released.release
    dropped.release
  let (result, table) ← command.runReal (← RealTexts.new)
  let documentsHeld ← Ffi.Document.live
  let snapshotsHeld ← Ffi.Snapshot.live
  -- The table is read here, so it is alive until now. A released slot stays
  -- in it, empty.
  return result.isOk && documentsHeld == documents + 1 && snapshotsHeld == snapshots + 1 &&
      table.documents.size == 2 &&
      (← table.snapshots.size) == 2

/-- What must hold of the read half of the real binding's table of
snapshots, which is all a reader off the editor thread is given. It is about
the binding's own table, so the port cannot say it. -/
def readerName : String :=
  "a snapshot a command took is found through the read half of the binding's table by its id, and reads what the command read; one taken by a later command is found too; one a command released is not found, and neither is an id never given"

/-- Whether the read half of the table finds what the commands' own
questions read. One command takes two snapshots of a text with two- and
four-byte characters and an escape, at two revisions, and releases a third;
a second command, run on the table the first left, takes another. The reader
was made before either ran. -/
def readerFinds : IO Bool := do
  let snapshots ← Snapshots.new
  let reader := snapshots.reader
  let first : TextM (TextId × SnapshotId × SnapshotId × SnapshotId × String) := do
    let text ← createText (TextContract.loaded)
    let early ← text.snapshot
    text.insert 0 "x"
    let released ← text.snapshot
    let late ← text.snapshot
    released.release
    return (text, early, late, released, ← late.read)
  let (.ok (text, early, late, released, read), table) ←
    first.runReal (.over snapshots) | return false
  let some foundEarly ← reader.find? early | return false
  let some foundLate ← reader.find? late | return false
  let gone ← reader.find? released
  let never ← reader.find? ⟨7⟩
  let (.ok later, _) ← text.snapshot.runReal table | return false
  let some foundLater ← reader.find? later | return false
  return (← foundEarly.read) == "héllo\r\n😀".push (Char.ofNat 0x10DCFF) &&
      (← foundLate.read) == read &&
      read == "xhéllo\r\n😀".push (Char.ofNat 0x10DCFF) &&
      (← foundLate.info).revision == 1 &&
      gone.isNone &&
      never.isNone &&
      (← foundLater.read) == read

/-- Runs `command` against the real binding, from a table with no texts, in
a run that is handed `arrived` as what a job held: for each, a snapshot the
library made of a document holding the string. The documents, the snapshots
and the table are dropped with the run. -/
def runHanded (arrived : Array (JobSnapshotId × String)) (command : TextM Bool) :
    IO (Except TextError Bool) := do
  let handed ← arrived.mapM fun (id, text) => return (id, ← (← Ffi.Document.new text).snapshot)
  return (← command.runReal (← RealTexts.new) handed).1

/-- Runs `properties` against the real binding, each from a table with no
texts, and then `adoptProperties`, each in a run handed its snapshots
(`runHanded`), and returns the names of those that did not hold. Each table
is dropped with its run, and so is what a run was handed, so the counts of
live documents and of live snapshots must then be what they were before: if
either is not, `tableName` is among the names. `releaseName` is among them
if a release did not free its object at once. -/
def failures (properties : List TextContract.Property)
    (adoptProperties : List TextContract.AdoptProperty) : IO (List String) := do
  let before := (← Ffi.Document.live, ← Ffi.Snapshot.live)
  let held ←
    TextContract.failures (fun command => return (← command.runReal (← RealTexts.new)).1) properties
  let failed := held ++ (← TextContract.adoptFailures runHanded adoptProperties)
  let released ← releaseFrees
  let found ← readerFinds
  let after := (← Ffi.Document.live, ← Ffi.Snapshot.live)
  return failed ++ (if released then [] else [releaseName]) ++
      (if found then [] else [readerName]) ++
      if after == before then []
      else
        [s!"{tableName} ({before.1} documents and {before.2} snapshots before, {after.1} and {after.2} after)"]

/-- The answers of the bracket walk over `contents` at every position, for
each kind, side, direction, escapedness and whether quoted brackets are
passed over, in that order: the question asked and the answer. -/
def unmatchedEverywhere (contents : String)
    (answer : Bracket → Bool → Bool → Bool → Bool → Nat → IO (Option Nat)) :
    IO (Array (String × Option Nat)) := do
  let mut answers := #[]
  for offset in
    (List.range (contents.utf8ByteSize + 1)).filter fun offset =>
      (String.Pos.Raw.mk offset).IsValid contents do
    for bracket in [Bracket.round, .square, .curly] do
      for opening in [false, true] do
        for forward in [false, true] do
          for escaped in [false, true] do
            for skipQuoted in [false, true] do
              let question :=
                s!"{repr contents} {bracket.opening} opening {opening} forward {forward} escaped {escaped} skipQuoted {skipQuoted} from {offset}"
              answers :=
                answers.push (question, ← answer bracket opening forward escaped skipQuoted offset)
  return answers

/-- What only a run against both shows: that the real binding's bracket walk
and the model's agree at every position of texts with quotes. The contract's
tables pin the quote rule at the cases they name, and its every-position
property only what any answer must be, so two ports of the rule could
disagree at an offset no table names; this check compares them there. A
disagreement fails the check with the first question the two answer
differently. -/
def pairChecks : List Check :=
  [{  name :=
        "at every position of texts with quotes, for each kind, side, direction, escapedness and whether quoted brackets are passed over, the real bracket walk answers what the text model does"
      run := do
        for contents in TextContract.bracketText :: TextContract.quotedBracketTexts do
          let model ←
            unmatchedEverywhere contents fun bracket opening forward escaped skipQuoted offset =>
                match
                  TextModel.unmatched? contents bracket opening forward escaped skipQuoted
                    offset with
                | .ok found => pure found
                | .error error => throw (IO.userError s!"the model refused: {repr error}")
          let (real, _) ←
            (do
                    let text ← createText contents
                    let mut found := #[]
                    for offset in [0:contents.utf8ByteSize + 1] do
                      if (String.Pos.Raw.mk offset).IsValid contents then
                        for bracket in [Bracket.round, .square, .curly] do
                          for opening in [false, true] do
                            for forward in [false, true] do
                              for escaped in [false, true] do
                                for skipQuoted in [false, true] do
                                  found :=
                                    found.push
                                      (←
                                        text.unmatched bracket opening forward escaped skipQuoted
                                            offset)
                    return found : TextM (Array (Option Nat))).runReal
                (← RealTexts.new)
          let real ←
            match real with
            | .ok found =>
              pure found
            | .error error =>
              throw (IO.userError s!"the binding refused: {repr error}")
          if real.size != model.size then
            return false
          for ((question, expected), got) in model.toList.zip real.toList do
            if expected != got then
              throw
                  (IO.userError
                    s!"{question}: the model answers {repr expected}, the binding {repr got}")
        return true }]

end ContractTest
