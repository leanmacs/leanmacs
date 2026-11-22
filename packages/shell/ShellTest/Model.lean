import ShellTest.Check
import ShellTest.Shell

/-!
# The test driver of the package `shell`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive, so
nothing it needs reaches the core's `rustlib` target, which the task shows
by running it with a `cargo` that fails first on the `PATH`. It only
imports the test modules and runs their checks.

The test module mirrors the module it tests: the checks of `Shell.lean`
and `Shell/Compiled.lean` are in `ShellTest/Shell.lean`, on the shell's
test kit (`ShellTest/Kit.lean`) and the core's. They were the core's
(`ModelTest.shellChecks`) while the shell was modules of the core, and
moved here with their sentences as they were.

- `shellChecks`: the `Package` value (`Shell/Compiled.lean`) held to the
  contract of the interface package `shell-api`
  (`ShellApiTest.contractChecks`); what it keeps across a restart, its
  history whole and neither its output buffers nor its run in flight, and
  its run reported; and `shell-command`, `shell-filter` and `keyboard-quit`
  (`Shell.lean`) run by name on the loop's driver over the editor's models
  and the job model: a child's output in the echo area or an output
  buffer, a filter replacing a range, the history per scope, the
  interrupt, and what each says when it starts nothing.
-/

/-- Every check of the test driver, in the order they run. -/
def ShellTest.checks : List ShellTest.Check :=
  ShellTest.shellChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← ShellTest.failures ShellTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"shell-test: {ShellTest.checks.length} checks passed"
    return 0
  else
    return 1
