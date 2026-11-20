import Editor.Config.Packages
import Editor.Restore.Compiled
import ModelTest.Check

/-!
# Model tests: `Editor/Restore/Compiled.lean`

The model tests of `Editor/Restore/Compiled.lean`: `restorePackageChecks`.
The root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of the `restore` package (`Editor/Restore/Compiled.lean`):
its jobs are restarted by the next start, never counted as stopped, and
`restart` is its ex name. -/
def restorePackageChecks : List Check :=
  [{  name :=
        "the package restore registers its six jobs as restarted by its owner, since the next start runs its own restore and writes its own index and a restart's own jobs end with the run that hands over, and reports none"
      run :=
        let jobs := Restore.package.registered.jobs
        pure
          ((jobs.filter (·.restarted)).map (·.name) ==
              #[Restore.restoreJob, Restore.filesJob, Restore.writeJob, Restore.saveJob,
                Restore.probeJob, Restore.restartSaveJob] &&
            (jobs.filter (·.reported)).isEmpty) },
    { name := "the package restore binds the ex name restart to its command restart, taking text"
      run :=
        pure
          (Restore.package.registered.ex.map
              (fun binding => (binding.name, binding.command, binding.takes)) ==
            #[("restart", "restart", .text)]) }]

end ModelTest
