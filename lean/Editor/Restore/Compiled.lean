import Editor.Package
import Editor.Restore.Run

/-!
# The `restore` package: session restore's jobs, command and mode

What a host registers, as the package `restore` (`Restore.package`,
`Editor/Package.lean`), so that a session is restored at start-up after a
run that did not end cleanly, and its unsaved text journalled as it changes
(`Editor/Restore.lean`, `Editor/Restore/Run.lean`). A host registers it for
the owner `restore` when its loop starts, before any config
(`Editor/Config/Packages.lean`); the loop journals only where its jobs are
registered.

- **The jobs**: `restore` and `restore-files`, the two halves of a restore;
  `restore-write` and `restore-save`, which write this run's index. Each is
  restarted (`workJob … (restarted := true)`): the next start runs its own
  restore and writes its own index, so one running at a restart is not
  counted as stopped by it.
- **The command**: `restore-modes`, which sets a major mode a restore
  deferred until config registered it.
- **The mode**: `restore-report`, the report's buffer's (`*restore*`).

Pinned by `ModelTest.restoreChecks`, on the models, by
`ModelTest.restorePackageChecks` (the jobs restarted), and by
`ModelTest.packageSetChecks` over the package table.
-/

namespace Editor.Restore

/-- The package `restore`: a session's restore and its journal's index. -/
def package : Package :=
  { name := "restore"
    setup := do
      commandWith modesName modesCommand
      defineMode { name := reportMode }
      workJob restoreJob restoreWork (restarted := true)
      workJob filesJob filesWork (restarted := true)
      workJob writeJob writeWork (restarted := true)
      workJob saveJob saveWork (restarted := true) }

end Editor.Restore
