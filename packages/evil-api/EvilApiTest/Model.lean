import EvilApiTest.EvilApi

/-!
# The test driver of the package `evil-api`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive. It only
imports the test modules and runs their checks.
-/

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed := EvilApiTest.evilApiChecks.filter fun check => !check.2
  for check in failed do
    IO.eprintln s!"FAILED: {check.1}"
  if failed.isEmpty then
    IO.println s!"evil-api-test: {EvilApiTest.evilApiChecks.length} checks passed"
    return 0
  else
    return 1
