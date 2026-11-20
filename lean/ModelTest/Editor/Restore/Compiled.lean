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
its jobs are restarted by the next start, never counted as stopped. -/
def restorePackageChecks : List Check :=
  [{  name :=
        "the package restore registers its four jobs as restarted by its owner, since the next start runs its own restore and writes its own index, and reports none"
      run :=
        let jobs := Restore.package.registered.jobs
        pure
          ((jobs.filter (·.restarted)).map (·.name) ==
              #[Restore.restoreJob, Restore.filesJob, Restore.writeJob, Restore.saveJob] &&
            (jobs.filter (·.reported)).isEmpty) }]

end ModelTest
