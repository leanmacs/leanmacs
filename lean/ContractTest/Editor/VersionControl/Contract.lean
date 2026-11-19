import ContractTest.Support.Git
import ContractTest.Support.Jobs
import Editor.Ffi.Processes
import Editor.Job
import Editor.Job.Runner
import Editor.Program
import Editor.VersionControl
import Editor.VersionControl.Contract
import Editor.VersionControl.Git

/-!
# Contract tests: `Editor/VersionControl/Contract.lean`

The tests of `Editor/VersionControl/Contract.lean`: `versionControlFailures`,
the version-control interface's contract over real git. The root module
`ContractTest` runs them; its module doc says what each shows.
-/

namespace ContractTest

open Editor

/-- How many of the version-control contract's properties run at once. It
is bounded, not one lane per property, because each property's job must end
within `patience` or fails as one that did not end, and on a runner with few
cores and every core busy, every property's git at once could push one past
it. -/
def versionControlLanes : Nat :=
  8

/-- Runs `run` on each of `items` in `width` lanes, each a dedicated task
that takes every `width`-th item in turn: the results in `items`' order.
A lane that throws gives `failed` its error for each of its items. The
lanes are dedicated threads, because each item may block on a process or
on `eventually`, and Lean's task pool must stay as the job checks measure
it. -/
def inLanes {α β : Type} (width : Nat) (items : List α) (run : α → IO β)
    (failed : α → IO.Error → β) : IO (List β) := do
  let numbered := items.zipIdx
  let lanes :=
    (List.range width).map fun lane => numbered.filter fun (_, index) => index % width == lane
  let tasks ←
    lanes.mapM fun lane =>
        IO.asTask (prio := .dedicated) (lane.mapM fun (item, index) => return (index, ← run item))
  let results ←
    (lanes.zip tasks).flatMapM fun (lane, task) => do
        match ← IO.wait task with
        | .ok results =>
          return results
        | .error error =>
          return lane.map fun (item, index) => (index, failed item error)
  return (results.mergeSort fun a b => a.1 ≤ b.1).map (·.2)

/-- The names of the version-control contract's properties
(`Editor/VersionControl/Contract.lean`) that do not hold of the git
implementation over the library's process service, each property's
repository written out with real git in a temporary directory and home of
its own (`writeGitRepository`), every child's git kept from the system's
config and given `pinnedAwayConfig` as the user's (`onIsolatedGit`); and
that every child it ran, in every lane, is reaped once all have ended. The
properties run `versionControlLanes` at a time (`inLanes`), and their
failures are reported in the contract's order. Property 1 is the phase's
adapter test of git against the model. -/
def versionControlFailures (services : Job.Services) : IO (List String) := do
  let before ← Ffi.processesPending
  let outcomes ←
    inLanes versionControlLanes VersionControlContract.properties (failed := fun property error =>
        some s!"{property.name} ({error})") fun property =>
        withRepository fun home directory => do
          try
            writeGitRepository home directory property.repository
            let config := home / "gitconfig"
            IO.FS.writeFile config pinnedAwayConfig
            let outcome ←
              runOnTimers (onIsolatedGit services home config)
                  (property.holds.runM (VersionControl.Git.handler "git" directory))
            return if outcome == .finished true then none
              else some s!"{property.name} ({repr outcome})"
          catch error =>
            return some s!"{property.name} (writing its repository: {error})"
  let failed := outcomes.filterMap id
  let reaped ← eventually (return (← Ffi.processesPending) == before)
  return failed.map (s!"the version-control interface over git: {·}") ++
      if reaped then [] else ["every child the git implementation ran is reaped"]

end ContractTest
