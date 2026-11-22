import PackageSetTest.Check
import PackageSetTest.PackageSet.Compiled

/-!
# The test driver of the package `package-set`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Each test module mirrors the module it tests: the checks of
`PackageSet/Compiled.lean` are in `PackageSetTest/PackageSet/Compiled.lean`.
They run on the core's test kit. They were the core's
(`ModelTest.packageSetCommandChecks`) while the package was a module of
the core, and moved here with their sentences as they were.

- `packageSetCommandChecks`: the `package-set` package's commands
  (`PackageSet/Compiled.lean`), on the kit's hosted driver over the
  package: the three commands' edits, their refusals and the reload after
  them; `:package-update` with no rev repairing a lakefile without the
  core's require at its root first, through the edit job, and starting the
  build on a repaired one; the install's forms; and what the `Package`
  value registers: the job and the two commands the kit's stand-in for the
  build does (`Editor.Test.PackageSet.buildPackage`), the build reported,
  and its own edit job and three commands with their ex names.
-/

/-- Every check of the test driver, in the order they run. -/
def PackageSetTest.checks : List PackageSetTest.Check :=
  PackageSetTest.packageSetCommandChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← PackageSetTest.failures PackageSetTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"package-set-test: {PackageSetTest.checks.length} checks passed"
    return 0
  else
    return 1
