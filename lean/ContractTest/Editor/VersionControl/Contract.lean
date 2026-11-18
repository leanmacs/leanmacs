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

/-- The names of the version-control contract's properties
(`Editor/VersionControl/Contract.lean`) that do not hold of the git
implementation over the library's process service, each property's
repository written out with real git in a temporary directory of its own
(`writeGitRepository`), every child's git kept from the system's config and
given `pinnedAwayConfig` as the user's (`onIsolatedGit`); and that every
child it ran is reaped. Property 1 is the phase's adapter test of git
against the model. -/
def versionControlFailures (services : Job.Services) : IO (List String) := do
  let before ← Ffi.processesPending
  let failed ←
    VersionControlContract.properties.filterMapM fun property =>
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
  let reaped ← eventually (return (← Ffi.processesPending) == before)
  return failed.map (s!"the version-control interface over git: {·}") ++
      if reaped then [] else ["every child the git implementation ran is reaped"]

end ContractTest
