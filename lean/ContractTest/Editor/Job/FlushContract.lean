import ContractTest.Check
import ContractTest.Support.FileHold
import Editor.Job.FlushContract
import Editor.Job.Runner
import Editor.Test.Linked.Services

/-!
# Contract tests: `Editor/Job/FlushContract.lean`

The services' flush contract run against the real ports over the Rust
library: `flushContractChecks`, one check a port. The file service is held
by its in-process hold (`FileHold`), the work behind it a stamp; the process
service by a run of `/bin/sleep 600`, which only its cancel ends, the work
having ended once the service has no more children than before it started;
the clock, the watch service and the diff service are idle. The root module
`ContractTest` runs them over the services it starts.
-/

namespace ContractTest

open Editor
open Editor.Job

/-- The rigs of the real ports among `services`. -/
def flushRealRigs (services : Job.Services) : List FlushContract.FlushRig :=
  let completions := services.completions
  [{ name := "the library's timer service", flush := services.flushed .timers },
    { name := "the library's file service, held by its hold"
      flush := services.flushed .files
      held :=
        some do
          let hold ← FileHold.hold completions
          let (id, wait) ← completions.register
          let request : FileRequest := .stamp "/"
          services.files.start id request
          -- The stamp's result is taken, or the stamp withdrawn when it has
          -- not ended, so a failing check leaves nothing in the service.
          let ended := do
            let finished ← IO.hasFinished wait.result?
            if finished then
              discard <| services.files.take id request
            else
              services.files.cancel id
              completions.finish id .cancelled
            return finished
          return (hold.release, ended) },
    { name := "the library's process service, held by a child only a cancel ends"
      flush := services.flushed .processes
      held :=
        some do
          let before ← Test.Linked.pendingChildren
          let (id, _) ← completions.register
          services.processes.start id
              (.run { program := "/bin/sleep", arguments := #["600"], directory := "/" } 1024)
          let release := do
            services.processes.cancel id
            completions.finish id .cancelled
          return (release, return (← Test.Linked.pendingChildren) == before) },
    { name := "the library's watch service", flush := services.flushed .fileWatches },
    { name := "the library's diff service", flush := services.flushed .diffs }]

/-- The services' flush contract over the real ports among `services`, one
check a port (`Editor/Job/FlushContract.lean`). -/
def flushContractChecks (services : Job.Services) : List Check :=
  (flushRealRigs services).map fun rig =>
    { name := s!"the services' flush contract holds of {rig.name}"
      run := do
        let failed ← FlushContract.failures [rig]
        unless failed.isEmpty do
          throw <| IO.userError s!"{failed}"
        return true }

end ContractTest
