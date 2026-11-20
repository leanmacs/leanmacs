import Editor.Config.Packages
import Editor.Files.Compiled
import ModelTest.Check

/-!
# Model tests: `Editor/Files/Compiled.lean`

The model tests of `Editor/Files/Compiled.lean`: `filesPackageChecks`. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of the `files` package (`Editor/Files/Compiled.lean`): which
of its jobs a restart reports and which it leaves to the package to start
again. -/
def filesPackageChecks : List Check :=
  [{  name :=
        "the package files registers check-files and follow-file alone as restarted by their owner, since the files a restore puts back are checked and followed again, and reports none: a save, a load or a reload running at a restart is counted among the other jobs"
      run :=
        let jobs := Files.package.registered.jobs
        pure
          ((jobs.filter (·.restarted)).map (·.name) == #[Files.checkJob, Files.followJob] &&
            (jobs.filter (·.reported)).isEmpty &&
            [Files.saveJob, Files.loadJob, Files.reloadJob].all fun name =>
              jobs.any (·.name == name)) }]

end ModelTest
