import ModeLineTest.Check
import ModeLineTest.ModeLine.Compiled

/-!
# The test driver of the package `mode-line`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Each test module mirrors the module it tests: the checks of
`ModeLine/Compiled.lean` are in `ModeLineTest/ModeLine/Compiled.lean`.

- `modeLinePackageChecks`: the `Package` value (`ModeLine/Compiled.lean`):
  it registers the shipped segments, in order, each with the shipped
  segment's fields, so the default listing resolves over them to the
  shipped mode line. It was the core's (`ModelTest.modeLinePackageChecks`)
  while the package was a module of the core.
-/

/-- Every check of the test driver, in the order they run. -/
def ModeLineTest.checks : List ModeLineTest.Check :=
  ModeLineTest.modeLinePackageChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← ModeLineTest.failures ModeLineTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"mode-line-test: {ModeLineTest.checks.length} checks passed"
    return 0
  else
    return 1
