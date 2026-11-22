import RestoreTest.Check
import RestoreTest.Restore.Compiled

/-!
# The test driver of the package `restore`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Each test module mirrors the module it tests: the checks of
`Restore/Compiled.lean` are in `RestoreTest/Restore/Compiled.lean`. They
were the core's (`ModelTest.restorePackageChecks`) while the package was a
module of the core, and moved here with their sentences as they were.

- `restorePackageChecks`: the `Package` value (`Restore/Compiled.lean`):
  its six jobs are restarted by the next start, never counted as stopped,
  and none is reported; `restart` is its ex name, taking text; and it
  registers exactly what the kit's stand-in does
  (`Editor.Test.Restore.package`, which the core's checks of session
  restore run on): the six jobs, each restarted, the three commands, the
  mode and the ex name.
-/

/-- Every check of the test driver, in the order they run. -/
def RestoreTest.checks : List RestoreTest.Check :=
  RestoreTest.restorePackageChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← RestoreTest.failures RestoreTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"restore-test: {RestoreTest.checks.length} checks passed"
    return 0
  else
    return 1
