import BuffersApiTest.BuffersApi
import BuffersApiTest.Check

/-!
# The test driver of the package `buffers-api`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive. It only
imports the test modules and runs their checks, which were the core's
(`ModelTest.<name>`) while the interface was staged in the core, with their
sentences as they were:

- `buffersApiChecks`: the interface library `buffers-api` (`BuffersApi.lean`):
  its names; its fake (`BuffersApiTest.fake`, a close over the core's API)
  keeps its contract; the contract fails a package lacking `close-buffer`
  and one whose close runs no hook.
-/

/-- Every check of the test driver, in the order they run. -/
def BuffersApiTest.checks : List BuffersApiTest.Check :=
  BuffersApiTest.buffersApiChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← BuffersApiTest.failures BuffersApiTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"buffers-api-test: {BuffersApiTest.checks.length} checks passed"
    return 0
  else
    return 1
