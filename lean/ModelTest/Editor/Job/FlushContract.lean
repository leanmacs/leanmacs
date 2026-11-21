import Editor.Job.Fake
import Editor.Job.FlushContract
import Editor.Job.Runner
import ModelTest.Check

/-!
# Model tests: `Editor/Job/FlushContract.lean`

The services' flush contract run against the fakes: `flushContractChecks`.
The fake file service's files and diffs, and the fake process service, are
held by their held completions (`holdCompletions`, `letGo`); the fake clock
and the fake watch service, which complete what they are asked at once, are
idle only. The root module `ModelTest` runs them.
-/

namespace ModelTest

open Editor
open Editor.Job

/-- Services over a table of their own, the fakes' ports in place: a fake
clock, files, diffs, processes and watches. -/
structure FlushFakes where
  /-- The table of waits. -/
  completions : Completions
  /-- The fake files, whose diffs are the diff port. -/
  files : FakeFiles
  /-- The fake processes. -/
  processes : FakeProcesses
  /-- The services, over the fakes. -/
  services : Services

/-- Fresh fakes over a table of their own. -/
def FlushFakes.new : BaseIO FlushFakes := do
  let completions ← Completions.new
  let clock ← FakeClock.new completions
  let files ← FakeFiles.new completions
  let processes ← FakeProcesses.new completions
  let watches ← FakeFileWatches.new completions
  return {
      completions, files, processes
      services :=
        { completions, timers := clock.timers, files := files.files, diffs := files.diffs
          greps := files.greps, processes := processes.processes
          fileWatches := watches.fileWatches } }

/-- Starts `start` as a wait of `completions` with the completions held by
`hold`, and gives back `letGo` and whether that wait has ended. -/
def heldWork (completions : Completions) (hold letGo : BaseIO Unit) (start : UInt64 → BaseIO Unit) :
    IO (IO Unit × IO Bool) := do
  hold
  let (id, wait) ← completions.register
  start id
  return (letGo, IO.hasFinished wait.result?)

/-- The rigs of the fakes. -/
def flushFakeRigs (fakes : FlushFakes) : List FlushContract.FlushRig :=
  let services := fakes.services
  [{ name := "the fake clock", flush := services.flushed .timers },
    { name := "the fake file service"
      flush := services.flushed .files
      held :=
        some <|
          heldWork fakes.completions fakes.files.holdCompletions fakes.files.letGo fun id =>
            services.files.start id (.stamp "/flushed") },
    { name := "the fake file service's diffs"
      flush := services.flushed .diffs
      held :=
        some <|
          heldWork fakes.completions fakes.files.holdCompletions fakes.files.letGo fun id =>
            services.diffs.start id (.lines (.held ⟨1⟩) (.held ⟨2⟩) 10) },
    { name := "the fake process service"
      flush := services.flushed .processes
      held :=
        some <|
          heldWork fakes.completions fakes.processes.holdCompletions fakes.processes.letGo fun id =>
            services.processes.start id (.run { program := "/bin/true", directory := "/" } 10) },
    { name := "the fake watch service", flush := services.flushed .fileWatches },
    { name := "the fake grep service", flush := services.flushed .greps }]

/-- The services' flush contract on the fakes, one check for each rig and
property (`Editor/Job/FlushContract.lean`); and that it bites, on a file
service whose flush completes at its call and on one whose flush never
completes. -/
def flushContractChecks : List Check :=
  [{  name := "the services' flush contract holds of the fakes"
      run := do
        let fakes ← FlushFakes.new
        let failed ← FlushContract.failures (flushFakeRigs fakes)
        unless failed.isEmpty do
          throw <| IO.userError s!"{failed}"
        return true },
    { name :=
        "the flush contract bites on a file service whose flush completes at its call: the held property fails"
      run := do
        let fakes ← FlushFakes.new
        let eager : Services :=
          { fakes.services with
            files :=
              { fakes.services.files with
                flush := fun id => fakes.completions.finish id .completed } }
        let some held := (flushFakeRigs { fakes with services := eager })[1]? | return false
        let failed ← FlushContract.failures [held]
        unless
          failed.length == 1 &&
            failed.all (·.startsWith s!"the fake file service: {FlushContract.heldBehind.name}") do
          throw <| IO.userError s!"{failed}"
        return true },
    { name :=
        "the flush contract bites on a file service whose flush never completes: the idle property reports a hang"
      run := do
        let fakes ← FlushFakes.new
        let stuck : Services :=
          { fakes.services with files := { fakes.services.files with flush := fun _ => pure () } }
        -- The flush never ends, so the guard always runs out: a short one.
        let rig : FlushContract.FlushRig :=
          { name := "the fake file service", flush := stuck.flushed .files, patience := 50 }
        let failed ← FlushContract.failures [rig]
        let idle := s!"the fake file service: {FlushContract.idle.name}"
        unless
          failed.length == 1 &&
            failed.all fun failure =>
              failure.startsWith idle && (failure.splitOn "a hang").length > 1 do
          throw <| IO.userError s!"{failed}"
        return true }]

end ModelTest
