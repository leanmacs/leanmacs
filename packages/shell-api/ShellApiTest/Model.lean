import ShellApiTest.Check
import ShellApiTest.ShellApi

/-!
# The test driver of the package `shell-api`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive. It only
imports the test modules and runs their checks, which were the core's
(`ModelTest.<name>`) while the interface was staged in the core, with their
sentences as they were:

- `shellApiChecks`: the interface library `shell-api` (`ShellApi.lean`): its
  names and the history's store; its fake (`ShellApiTest.fake`, the three
  commands over the core's API, `shell-command` recording its line) keeps
  its contract; the contract fails a package lacking `keyboard-quit`, one
  that registers no codec for the history, and one whose `shell-command`
  records nothing; `remember`'s rule; and the history's store, which is
  kept across a restart, round-tripping through the session index's JSON,
  initial and populated.
-/

/-- Every check of the test driver, in the order they run. -/
def ShellApiTest.checks : List ShellApiTest.Check :=
  ShellApiTest.shellApiChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← ShellApiTest.failures ShellApiTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"shell-api-test: {ShellApiTest.checks.length} checks passed"
    return 0
  else
    return 1
