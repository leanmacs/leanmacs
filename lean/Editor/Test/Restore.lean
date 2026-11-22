import Editor.Package
import Editor.Restore.Restart
import Editor.Restore.Run

/-!
# The test kit: Restore

A stand-in for the `restore` package that the core's tests, and a
package's, may register: `Test.Restore.package`, named `restore`, which
registers what that package does, over the core's work
(`Editor/Restore/Run.lean`, `Editor/Restore/Restart.lean`), under the
names the core declares (`Editor/Restore.lean`, `Editor.restartName`):

- **the jobs** `restore`, `restore-files`, `restore-write`, `restore-save`,
  `restart-probe` and `restart-save`, each restarted;
- **the commands** `restore-modes`, `restart` and `restart-abandon`, and
  the ex name `restart`, which takes text;
- **the mode** `restore-report`.

The hosts start the restore by the job's name, the loop journals only
where the job `restore` is registered, and a package-set build restarts
through `restart`; so a check of any of those, whose subject is the core,
registers this and names no module of the package.

It holds no checks. It is pinned by the checks that run on it
(`ModelTest.journalReconcileChecks`, `.restoreChecks`, `.restartChecks`,
`.packageSetBuildChecks`, `ContractTest.restoreRunChecks`, and the restore
hosts of `ConfigTest/Editor/Headless.lean`), and the package's own check
holds the real package to it.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import").
-/

namespace Editor.Test.Restore

open Editor
open Editor.Restore

/-- The kit's stand-in for the package `restore` (the module docs). -/
def package : Package :=
  { name := "restore"
    setup := do
      commandWith modesName modesCommand
      commandWith Editor.restartName restartCommand
      commandWith abandonName abandonCommand
      Editor.exCommand Editor.restartName Editor.restartName (takes := .text)
      defineMode { name := reportMode }
      workJob restoreJob restoreWork (restarted := true)
      workJob filesJob filesWork (restarted := true)
      workJob writeJob writeWork (restarted := true)
      workJob saveJob saveWork (restarted := true)
      workJob probeJob probeWork (restarted := true)
      workJob restartSaveJob restartSaveWork (restarted := true) }

end Editor.Test.Restore
