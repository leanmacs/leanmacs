# restore

A default package: session restore's registrations. With it, a session
that did not end cleanly is restored at the next start, unsaved text is
journalled as it changes, and `:restart` restarts the editor into the same
session. An editor without it journals nothing and restores no session,
has no `restart` command, and a package-set build ends without a restart:
you quit and start the editor yourself
([installing-packages.md](../../docs/packages/installing-packages.md)).

Its design record is in [packages.md](../../docs/design/packages.md), and
session restore's own in
[lean-runtime.md](../../docs/design/lean-runtime.md), "Persistence across
a restart".

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `restore`. It
   requires the core, `editor-core`, by path (`../../lean`), declares the
   library `Restore`, the test library `RestoreTest` and the test driver
   `restore-test`, and turns every Lean linter on with warnings as errors.
2. [`Restore/EditorPackage.lean`](Restore/EditorPackage.lean): the entry
   module. It imports `Restore.Compiled`.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.Restore.package]
   ```
3. [`Restore/Compiled.lean`](Restore/Compiled.lean): the `Package` value,
   `Editor.Restore.package`, named `restore`: the jobs `restore`,
   `restore-files`, `restore-write`, `restore-save`, `restart-probe` and
   `restart-save`, each restarted; the commands `restore-modes`, `restart`
   and `restart-abandon`; the ex name `restart`; and the mode
   `restore-report`.

The work it registers is the core's: the restore's run
(`lean/Editor/Restore/Run.lean`) and the restart
(`lean/Editor/Restore/Restart.lean`), over the journal's reconciler and the
session's data (`lean/Editor/Restore.lean` and the modules under
`lean/Editor/Restore/`). The hosts start the restore by the job's name and
the loop journals only where that job is registered; both names are the
core's, so the hosts and the loop name nothing of this package. Its
declaration keeps its name, `Editor.Restore.package`, from when it was a
module of the core.

## Its tests

- **The test driver**, [`RestoreTest/Model.lean`](RestoreTest/Model.lean),
  run by `lake test`: `restorePackageChecks`, in
  [`RestoreTest/Restore/Compiled.lean`](RestoreTest/Restore/Compiled.lean),
  which mirrors the library module: the jobs restarted, the ex name, and
  the package held to the kit's stand-in the core's own checks of session
  restore run on.
- **End to end**: the core's headless fixtures `tests/headless/restore`
  and `tests/headless/restart`, the bundle test and the user sets test
  ([the-gate.md](../../docs/dev-practices/the-gate.md)) restore and
  restart through it, on an editor built from the default set.

The gate runs the driver over the fixture set and the default set
([the-gate.md](../../docs/dev-practices/the-gate.md), "The package steps").

## Dropping it

`:package-remove restore` rebuilds your editor without it and restarts
into the build, once: the editor it restarts into journals nothing,
restores no session after a crash, and has no `:restart`
([installing-packages.md](../../docs/packages/installing-packages.md)).
