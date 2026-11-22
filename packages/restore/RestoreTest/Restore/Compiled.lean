import Editor.Config.Packages
import Editor.Test.Restore
import Restore.Compiled
import RestoreTest.Check

/-!
# The tests of `Restore/Compiled.lean`

The tests of `Restore/Compiled.lean`: `restorePackageChecks`. The test
driver `RestoreTest/Model.lean` runs them; its module doc says what each
shows.
-/

namespace RestoreTest

open Editor

/-- What `package` registers, as the names and flags a host sees: its
commands, its ex names with their commands and what each takes, its modes,
and its jobs with whether each is restarted and reported. -/
def registeredBy (package : Package) :
    Array String ×
      Array (String × String × Ex.Takes) × Array String × Array (String × Bool × Bool) :=
  let registered := package.registered
  (registered.commands.map (·.name),
    registered.ex.map (fun binding => (binding.name, binding.command, binding.takes)),
    registered.modes.map (·.name),
    registered.jobs.map fun job => (job.name, job.restarted, job.reported))

/-- The checks of the `restore` package (`Restore/Compiled.lean`): its jobs
are restarted by the next start, never counted as stopped, `restart` is
its ex name, and it registers exactly what the kit's stand-in does. -/
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
            #[("restart", "restart", .text)]) },
    { name :=
        "the package registers exactly what the kit's stand-in does, under the package name restore: the six jobs, each restarted, the three commands restore-modes, restart and restart-abandon, the mode restore-report and the ex name restart"
      run :=
        pure
          (Restore.package.name == "restore" && Test.Restore.package.name == "restore" &&
            registeredBy Restore.package == registeredBy Test.Restore.package &&
            registeredBy Restore.package ==
              (#["restore-modes", "restart", "restart-abandon"], #[("restart", "restart", .text)],
                #["restore-report"],
                #[("restore", true, false), ("restore-files", true, false),
                  ("restore-write", true, false), ("restore-save", true, false),
                  ("restart-probe", true, false), ("restart-save", true, false)])) }]

end RestoreTest
