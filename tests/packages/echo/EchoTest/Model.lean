import EchoTest.Echo.Checksum
import EchoTest.Echo.Job
import EchoTest.Echo.Library
import EchoTest.Echo.Model

/-!
# The test driver of the package `echo`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It imports no module that binds the crate
(`Echo.Real`), so it links no glue and no Rust archive, and nothing it
needs reaches a Cargo build, which the task shows by running it with a
`cargo` that fails first on the `PATH`. It only imports the test modules
and runs their checks.
-/

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let checks :=
    EchoTest.echoChecksumChecks ++ (← EchoTest.echoModelChecks) ++ EchoTest.echoJobChecks ++
      EchoTest.echoLibraryChecks
  let failed := checks.filter fun check => !check.2
  for check in failed do
    IO.eprintln s!"FAILED: {check.1}"
  if failed.isEmpty then
    IO.println s!"echo-test: {checks.length} checks passed"
    return 0
  else
    return 1
