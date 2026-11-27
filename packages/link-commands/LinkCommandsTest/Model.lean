import LinkCommandsTest.Check
import LinkCommandsTest.LinkCommands

/-!
# The test driver of the package `link-commands`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Its one test module mirrors the modules it tests: the checks of
`LinkCommands.lean` and `LinkCommands/Compiled.lean` are in
`LinkCommandsTest/LinkCommands.lean`. They run on the core's test kit.

- `linkCommandsChecks`: what the `Package` value registers, the core's
  names for the three commands, the job `url-open` and the links mode, and
  nothing else; and, on a hosted driver over the package, that
  `activate`'s key on a command link runs that command, which shows the
  wiring. What following and moving do is the core's
  (`ModelTest.linkFollowChecks`, `ModelTest.linkMoveChecks`).
-/

/-- Every check of the test driver, in the order they run. -/
def LinkCommandsTest.checks : List LinkCommandsTest.Check :=
  LinkCommandsTest.linkCommandsChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← LinkCommandsTest.failures LinkCommandsTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"link-commands-test: {LinkCommandsTest.checks.length} checks passed"
    return 0
  else
    return 1
