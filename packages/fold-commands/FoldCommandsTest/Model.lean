import FoldCommandsTest.Check
import FoldCommandsTest.FoldCommands

/-!
# The test driver of the package `fold-commands`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Its one test module mirrors the modules it tests: the checks of
`FoldCommands.lean` and `FoldCommands/Compiled.lean` are in
`FoldCommandsTest/FoldCommands.lean`. They run on the core's test kit.

- `foldCommandsChecks`: what the `Package` value registers, the core's
  names for `fold-toggle` and the folds mode, and nothing else; and, on a
  hosted driver over the package, that the `toggle` role's key on a
  declared folded range unfolds it, which shows the wiring. What toggling
  does is the core's (`ModelTest.foldToggleChecks`).
-/

/-- Every check of the test driver, in the order they run. -/
def FoldCommandsTest.checks : List FoldCommandsTest.Check :=
  FoldCommandsTest.foldCommandsChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← FoldCommandsTest.failures FoldCommandsTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"fold-commands-test: {FoldCommandsTest.checks.length} checks passed"
    return 0
  else
    return 1
