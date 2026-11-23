import ContractTest.Support.Displays
import ContractTest.Support.Files
import Editor.Clipboard
import Editor.Command
import Editor.Command.Real
import Editor.Display
import Editor.Display.Recorder
import Editor.Ffi.Document
import Editor.Ffi.Files
import Editor.Ffi.Snapshot
import Editor.File.Cases
import Editor.Invocation
import Editor.Job
import Editor.Job.Contract
import Editor.Job.Real
import Editor.Job.Runner
import Editor.SyntaxTree
import Editor.Test.Linked.Jobs
import Editor.Test.Linked.Services
import Editor.Text
import Editor.Text.Real
import Editor.Watch

/-!
# Contract tests: `Editor/File/Cases.lean`

The tests of `Editor/File/Cases.lean`: `caseFailures`, the file cases on the
real text binding and the library's file service. The root module `ContractTest`
runs them; its module doc says what each shows.
-/

namespace ContractTest

open Editor
open Editor.Test.Linked

/-- Plays `case` on the real text binding and the library's file service, on
real files, and says what went wrong; `none` when the case held.

It is played as the runtime plays it. The first command runs against a store
whose table of snapshots is published. The job is run by the runner, over
the file service that reads that table, and finishes with its command, as a
job does (`Work.of`). That command is run by `Job.finishWith`, which hands
the run what the job held and then settles the job, as the loop does. The
last command runs like any other, handed nothing. The files are in a
temporary directory made here for this one case, which is removed whatever
happened, once the file service has worked what was handed to it
(`Linked.withFiles`). -/
def playOnLibrary (completions : Job.Completions) (case : FileCases.Case) : IO (Option String) := do
  let rig ← FileRig.new completions
  Editor.Test.Linked.withFiles rig.services fun directory => do
      for (name, bytes) in case.files do
        IO.FS.writeBinFile (directory / name) bytes
      let display := (← recorderOf rig.published).handle
      let (.ok start, texts) ←
        case.first.runReal (.over rig.published)
            display | return some "its first command was refused"
      let handle ←
        Job.spawn rig.services (Work.of (fun _ => case.job directory start) (case.handler start))
            (pure ())
      -- hang guard: the job's end, on its outcome.
      if (← Job.awaitWithin patience handle.outcome.result?).isNone then
        handle.cancel
        return some s!"a hang: its job had not ended within {patience.ms} ms"
      match ← handle.outcome? with
      | some (.finished command) =>
        let (ran, texts) ← Job.finishWith rig.held handle command texts display
        if let .error refusal := ran then
          return some s!"the job's command failed with {repr refusal}"
        let (verdict, _) ← (case.last start).runReal texts display
        let after := JobContract.byName (← filesOf directory)
        match verdict with
        | .error refusal =>
          return some s!"its last command failed with {repr refusal}"
        | .ok false =>
          return some "its last command says it did not hold"
        | .ok true =>
          if after == JobContract.byName case.after then
            return none
          return some
              s!"the files afterwards are {after.map (·.1)}, of {after.map (·.2.size)} bytes"
      | some (.failed message) =>
        return some s!"its job failed with `{message}`"
      | _ =>
        return some "its job was cancelled"

/-- What must hold of the library's objects once the cases have run. -/
def caseLeakName : String :=
  "the cases across the two ports leave nothing behind: each store is dropped with its case, what its job held was released, and the library holds the documents and the snapshots it held before, with no request left in the file service"

/-- The names of the cases across the text port and the job port that do not
hold of the real binding and the library's file service, each with what
went wrong. `caseLeakName` is among them if the library's counts are not
then what they were. -/
def caseFailures (completions : Job.Completions) : IO (List String) := do
  let before := (← Ffi.Document.live, ← Ffi.Snapshot.live, ← Ffi.filesPending)
  let failed ←
    FileCases.cases.filterMapM fun case => do
        return (← playOnLibrary completions case).map fun reason =>
            s!"the real text binding and the file service: {case.name} ({reason})"
  -- The file service has worked what it was handed once a flush of it is
  -- completed, and its count is read once then. The live documents and
  -- snapshots are freed by finalisers on other threads: each is waited for
  -- on the frees themselves (`awaitLive`), `patience` a hang guard, and the
  -- counts are read once then.
  let flushed ← Editor.Test.Linked.filesFlushed completions
  let requests ← Ffi.filesPending
  let documentsFreed ← Ffi.Document.awaitLive before.1 patience
  let snapshotsFreed ← Ffi.Snapshot.awaitLive before.2.1 patience
  let freed :=
    documentsFreed && snapshotsFreed &&
      (← Ffi.Document.live, ← Ffi.Snapshot.live) == (before.1, before.2.1)
  let freed := flushed && freed && requests == before.2.2
  return failed ++ if freed then [] else [caseLeakName]

end ContractTest
