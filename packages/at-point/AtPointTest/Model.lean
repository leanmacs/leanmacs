import AtPointTest.AtPoint
import AtPointTest.AtPoint.Compiled
import AtPointTest.AtPoint.Words
import AtPointTest.Check

/-!
# The test driver of the package `at-point`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Each test module mirrors the module it tests: the checks of `AtPoint.lean`
are in `AtPointTest/AtPoint.lean`, those of `AtPoint/Words.lean` in
`AtPointTest/AtPoint/Words.lean`, and those of `AtPoint/Compiled.lean` in
`AtPointTest/AtPoint/Compiled.lean`. They run on the core's test kit and
test doubles (`Editor.Test.…`, the models, the at-point sources' contract;
`docs/design/packages.md`, "What a package may import"), and on the
support in `AtPointTest/Support/Words.lean`. The first two lists were the
core's (`ModelTest.<name>`) while completion at point was modules of the
core, and moved here with their sentences as they were.

- `atPointChecks`: the commands (`AtPoint.lean`) on a driver of the Vim
  scheme over the models: the chain of at-point sources, what the commands
  say when nothing answers or the ask is refused, a session refused while
  a prompt is open, the snapshots a source that reads texts is given, and
  that the package registers its commands under the names of the core's
  test kit;
- `wordsChecks`: the source `words` (`AtPoint/Words.lean`): its rule, its
  at-point source and its job on the job model, and the at-point sources'
  contract on every at-point source that ships and on `words` tuned;
- `atPointPackageChecks`: the `Package` value (`AtPoint/Compiled.lean`)
  against the contract check of the interface package `at-point-api`,
  each of the contract's checks one check here, so the count below holds
  them; then what a host handed it alone starts with of `words`.
-/

/-- Every check of the test driver, in the order they run. -/
def AtPointTest.checks : List AtPointTest.Check :=
  AtPointTest.atPointChecks ++ AtPointTest.wordsChecks ++ AtPointTest.atPointPackageChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← AtPointTest.failures AtPointTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"at-point-test: {AtPointTest.checks.length} checks passed"
    return 0
  else
    return 1
