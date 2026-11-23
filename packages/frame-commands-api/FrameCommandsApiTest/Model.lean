import FrameCommandsApiTest.FrameCommandsApi

/-!
# The test driver of the package `frame-commands-api`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive. It only
imports the test modules and runs their checks.
-/

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed := FrameCommandsApiTest.frameCommandsApiChecks.filter fun check => !check.2
  for check in failed do
    IO.eprintln s!"FAILED: {check.1}"
  if failed.isEmpty then
    IO.println
        s!"frame-commands-api-test: {FrameCommandsApiTest.frameCommandsApiChecks.length} checks passed"
    return 0
  else
    return 1
