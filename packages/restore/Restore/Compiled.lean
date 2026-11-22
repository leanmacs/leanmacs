import Editor.Package
import Editor.Restore.Restart
import Editor.Restore.Run

/-!
# The `restore` package: session restore's jobs, command and mode

What a host registers, as the package `restore` (`Restore.package`,
`lean/Editor/Package.lean`), so that a session is restored at start-up
after a run that did not end cleanly, and its unsaved text journalled as
it changes (`lean/Editor/Restore.lean`, `lean/Editor/Restore/Run.lean`). A
host registers it for the owner `restore` when its loop starts, before any
config (`lean/Editor/Config/Packages.lean`); the loop journals only where
its jobs are registered. It is a module of the Lake package `restore`
(`packages/restore/`) since the features-as-packages roadmap's phase 8;
the work it registers stays the core's, and its declaration keeps its name
(`Editor.Restore.package`). The hosts start the restore by the job's name
and run `restart-abandon` by its name, both the core's, so an editor
without this package restores and journals nothing.

- **The jobs**: `restore` and `restore-files`, the two halves of a restore;
  `restore-write` and `restore-save`, which write this run's index;
  `restart-probe` and `restart-save`, a restart's probe and its save of the
  session and the record (`lean/Editor/Restore/Restart.lean`). Each is
  restarted (`workJob … (restarted := true)`): the next start runs its own
  restore and writes its own index, and a restart's own jobs end with the
  run that hands over, so one running at a restart is not counted as
  stopped by it.
- **The commands**: `restore-modes`, which sets a major mode a restore
  deferred until config registered it; `restart`, bound to the ex name
  `restart`, which takes an optional executable; and `restart-abandon`,
  which a host runs to give a hand-over up.
- **The mode**: `restore-report`, the report's buffer's (`*restore*`).

Pinned by `RestoreTest.restorePackageChecks` (the jobs restarted, the ex
name, and the package held to the kit's stand-in,
`Editor.Test.Restore.package`); the work by the core's
`ModelTest.restoreChecks`, on the models, over that stand-in.
-/

namespace Editor.Restore

/-- The package `restore`: a session's restore and its journal's index. -/
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

end Editor.Restore
