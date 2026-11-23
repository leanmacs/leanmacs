import Editor.File.Model
import Editor.Headless.Journal.Contract
import Editor.Headless.Journal.Fake
import ModelTest.Check

/-!
# Model tests: `Editor/Headless/Journal/Contract.lean`

The contract of the session journal's port run over its recording fake
(`RecordingJournal`), on the model of files: `journalContractChecks`, one
check per property, each on a fake of its own. The fake is held simply by
not stepping it.

Beside them, what only the fake shows, the promises a host check stepping
it relies on: nothing is worked and no drain ends before a step; every
order is recorded with the thread that handed it, and every answer is on
the stepping thread, here the check's own; and once `stepAll` has run the
fake is quiescent, so nothing is left to drain. The root module `ModelTest`
runs them.
-/

namespace ModelTest

open Editor
open Editor.Headless

/-- The directory the fake's model holds, which the properties write in. -/
def journalDirectory : System.FilePath :=
  "/journal"

/-- A rig over a recording journal of its own, whose model holds
`journalDirectory`, and the fake itself. -/
def journalFakeRig : BaseIO (JournalContract.JournalRig × RecordingJournal) := do
  let fake ← RecordingJournal.new (({} : FileModel).withDirectory journalDirectory)
  let rig : JournalContract.JournalRig :=
    { name := "the recording journal", journal := fake.journal, directory := journalDirectory
      read := fun path => return ((← fake.model).file? path).map (·.bytes)
      put := fun path bytes =>
        fake.state.modify fun state => { state with model := state.model.withFile path bytes }
      snapshotOf := fun text =>
        fake.state.modifyGet fun state =>
            (⟨state.model.snapshots.size⟩,
              { state with
                model :=
                  { state.model with
                    snapshots := state.model.snapshots.push (some { contents := text }) } })
      step := fake.stepAll
      held := return pure () }
  return (rig, fake)

/-- The contract of the journal's port on its recording fake, and the
fake's own promises. -/
def journalContractChecks : List Check :=
  (JournalContract.properties.map fun property =>
      { name := s!"the recording journal keeps the journal's contract: {property.name}"
        run := do
          let (rig, fake) ← journalFakeRig
          let held ← property.holds rig
          return held && (← fake.quiescent) }) ++
    [{  name :=
          "the recording journal works nothing and ends no drain before it is stepped: two orders handed and a drain asked, nothing is worked and the drain has not ended; one step works the first and the drain still has not ended; the second ends it true"
        run := do
          let (rig, fake) ← journalFakeRig
          let path := journalDirectory / "l"
          rig.journal.perform { request := .append path "a".toUTF8 }
          rig.journal.perform { request := .append path "b".toUTF8 }
          let task ← rig.journal.drained
          let before := (← IO.hasFinished task, (← rig.read path).isSome, ← fake.unworked)
          discard <| fake.step
          let between := (← IO.hasFinished task, ← rig.read path, ← fake.unworked)
          discard <| fake.step
          let ended ← JournalContract.awaitDrain task
          unless before == (false, false, 2) && between == (false, some "a".toUTF8, 1) && ended do
            throw <|
                IO.userError
                  s!"before a step the drain had ended {before.1}, the file was there {before.2.1} with {before.2.2} unworked; after one, ended {between.1} with {between.2.2} unworked; after two, {ended}"
          return true },
      { name :=
          "the recording journal records each order with the thread that handed it and answers on the thread that steps it: here every order, every work and every drain is on the check's own thread, and the fake starts none"
        run := do
          let (rig, fake) ← journalFakeRig
          let thread ← IO.getTID
          rig.journal.perform { request := .append (journalDirectory / "l") "a".toUTF8 }
          rig.journal.perform { request := .remove (journalDirectory / "l") }
          let early ← rig.journal.drained
          fake.stepAll
          discard <| JournalContract.awaitDrain early
          let late ← rig.journal.drained
          discard <| JournalContract.awaitDrain late
          let orders ← fake.orderThreads
          let answers ← fake.answerThreads
          unless orders == #[thread, thread] && answers == #[thread, thread, thread, thread] do
            throw <|
                IO.userError
                  s!"the check's thread is {thread}; the orders were handed on {orders}, and answered on {answers}"
          return true },
      { name :=
          "the recording journal is quiescent once stepped to its end: nothing is unworked and no drain waits, so a check that ends there leaves nothing to drain"
        run := do
          let (rig, fake) ← journalFakeRig
          rig.journal.perform { request := .append (journalDirectory / "l") "a".toUTF8 }
          let task ← rig.journal.drained
          let before ← fake.quiescent
          fake.stepAll
          discard <| JournalContract.awaitDrain task
          return !before && (← fake.quiescent) && (← fake.unworked) == 0 }]

end ModelTest
