import MiseTest.Check
import MiseTest.Mise

/-!
# The test driver of the package `mise`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

The test module mirrors the modules it tests: the checks of `Mise.lean` and
`Mise/Compiled.lean` are in `MiseTest/Mise.lean`.

- `miseChecks`: the package registers one directory source named `mise`,
  which looks nothing up in the headless mode and in the window mode runs
  mise at the first of the usual places there is (`Mise.candidates`);
  `Mise.executable` refuses a relative path and replaces the package's
  value in its place, and a second call in one `setup` is refused, beside
  the package's own value; the source's command, parser and stamp paths; and
  `environment-api`'s directory-source contract
  (`EnvironmentApiTest.directoryContract`) on the model rig.
- `miseLookupChecks`: a child's environment looked up by mise on the job
  model, with the layers a host installs from the package's value and
  config's `Mise.executable`: the first candidate that exists, kept until a
  reload; no lookup in the headless mode or with none there; the lookup's
  variables under the command's own, for a run and a streaming start; the
  stamps that keep a directory's result, a directory of its own, and a
  reload's install; and a lookup that fails, prints what is not a JSON
  object or outlives its limit, reported once. They were the core's
  (`ModelTest.environmentLookupChecks`) while mise was the core's, and
  moved here with their assertions as they were.
-/

/-- Every check of the test driver, in the order they run. -/
def MiseTest.checks : List MiseTest.Check :=
  MiseTest.miseChecks ++ MiseTest.miseLookupChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← MiseTest.failures MiseTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"mise-test: {MiseTest.checks.length} checks passed"
    return 0
  else
    return 1
