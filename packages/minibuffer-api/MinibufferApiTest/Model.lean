import Editor.Lint.Wait
import MinibufferApiTest.MinibufferApi

/-!
# The test driver of the package `minibuffer-api`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive. It only
imports the test modules and runs their checks.
-/

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed := MinibufferApiTest.minibufferApiChecks.filter fun check => !check.2
  for check in failed do
    IO.eprintln s!"FAILED: {check.1}"
  if failed.isEmpty then
    IO.println s!"minibuffer-api-test: {MinibufferApiTest.minibufferApiChecks.length} checks passed"
    return 0
  else
    return 1
