import Editor.File.Model
import Editor.Job.Fake
import Editor.Job.HandleContract
import Editor.Job.Runner
import ModelTest.Check

/-!
# Model tests: `Editor/Job/HandleContract.lean`

The contract of a file request's handle run against the fake file service:
`handleContractChecks`. The fake is held by its held completions
(`holdCompletions`, `letGo`), and what it keeps is its pending requests and
its parked completions. The root module `ModelTest` runs them.
-/

namespace ModelTest

open Editor
open Editor.Job

/-- The directory the fake's model holds, which the properties write in. -/
def handleDirectory : System.FilePath :=
  "/handles"

/-- A rig over a fake file service of its own, over a table of its own, whose
model holds `handleDirectory`. -/
def handleFakeRig : BaseIO HandleContract.HandleRig := do
  let completions ← Completions.new
  let clock ← FakeClock.new completions
  let files ← FakeFiles.new completions (({} : FileModel).withDirectory handleDirectory)
  return {
      name := "the fake file service"
      services := { completions, timers := clock.timers, files := files.files }
      directory := handleDirectory
      read := fun path => return ((← files.state.get).model.file? path).map (·.bytes)
      held := do
        files.holdCompletions
        return files.letGo
      kept := do
        let state ← files.state.get
        return state.pending.size + state.parked.size }

/-- The contract of a file request's handle on the fake file service
(`Editor/Job/HandleContract.lean`). -/
def handleContractChecks : List Check :=
  [{  name := "the contract of a file request's handle holds of the fake file service"
      run := do
        let failed ← HandleContract.failures [← handleFakeRig]
        unless failed.isEmpty do
          throw <| IO.userError s!"{failed}"
        return true }]

end ModelTest
