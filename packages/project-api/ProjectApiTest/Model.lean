import ProjectApiTest.Check
import ProjectApiTest.ProjectApi

/-!
# The test driver of the package `project-api`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive. It only
imports the test modules and runs their checks, which were the core's
(`ModelTest.<name>`) while the interface was staged in the core, with their
sentences as they were:

- `projectApiChecks`: the interface library `project-api` (`ProjectApi.lean`):
  its names; its fake (`ProjectApiTest.fake`, a `Workspaces` value that
  hands every continuation a given workspace) keeps its contract; the
  contract fails a package lacking `find-file-in-project` and one whose
  reach hands nothing on; and a job over the point with no value fails
  naming its continuation's job.
-/

/-- Every check of the test driver, in the order they run. -/
def ProjectApiTest.checks : List ProjectApiTest.Check :=
  ProjectApiTest.projectApiChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← ProjectApiTest.failures ProjectApiTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"project-api-test: {ProjectApiTest.checks.length} checks passed"
    return 0
  else
    return 1
