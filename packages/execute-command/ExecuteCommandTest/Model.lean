import ExecuteCommandTest.Check
import ExecuteCommandTest.ExecuteCommand
import ExecuteCommandTest.ExecuteCommand.Compiled

/-!
# The test driver of the package `execute-command`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

Each test module mirrors the module it tests: the checks of
`ExecuteCommand.lean` are in `ExecuteCommandTest/ExecuteCommand.lean`, and
those of `ExecuteCommand/Compiled.lean` in
`ExecuteCommandTest/ExecuteCommand/Compiled.lean`. They run on the core's
test kit (`Editor.Test.…`, a test double the core publishes;
`docs/design/packages.md`, "What a package may import").

- `executeCommandChecks`: the command prompt (`ExecuteCommand.lean`), on
  the loop's driver over the editor's models and the test scheme, and its
  source held to the completion sources' contract on the kit's runner. It
  was the core's (`ModelTest.executeCommandChecks`) while the command
  prompt was a module of the core, and moved here with its sentences as
  they were;
- `executeCommandPackageChecks`: the `Package` value
  (`ExecuteCommand/Compiled.lean`) against the contract check of the
  interface package `execute-command-api`, each of the contract's checks
  one check here, so the count below holds them.
-/

/-- Every check of the test driver, in the order they run. -/
def ExecuteCommandTest.checks : List ExecuteCommandTest.Check :=
  ExecuteCommandTest.executeCommandChecks ++ ExecuteCommandTest.executeCommandPackageChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← ExecuteCommandTest.failures ExecuteCommandTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"execute-command-test: {ExecuteCommandTest.checks.length} checks passed"
    return 0
  else
    return 1
