import VcApiTest.Check
import VcApiTest.VcApi
import VcApiTest.VcApiTest.Contract
import VcApiTest.VcApiTest.Fake

/-!
# The test driver of the package `vc-api`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive. It only
imports the test modules and runs their checks and the contract's failure
list, which were the core's (`ModelTest.<name>`) while the interface was
staged in the core, with their sentences as they were. The tests of
`VcApi.lean` are in `VcApiTest/VcApi.lean`, and those of the published test
support, `VcApiTest/Fake.lean` and `VcApiTest/Contract.lean`, in
`VcApiTest/VcApiTest/`:

- `versionControlModelChecks`: the model of a repository, the fake of the
  interface library `vc-api` (`VcApiTest/Fake.lean`): its status of each
  state, how it pairs renames, and what its writes do;
- `vcApiChecks`: the interface library `vc-api` (`VcApi.lean`): the backend
  point is a choice by the name `git`, so a consumer connects through the
  latest backend of that name, config's after a package's, never through
  one of another name, and with no `git` backend has no connection; its names are the core's
  gutter jobs and the default order's `review`; the fake's backend answers
  from the model; and its registration check holds of a package that
  registers the backend `git`, the gutter jobs and the segment, and fails
  one that leaves any of them out;
- `versionControlContractFailures`: the version-control contract
  (`VcApiTest/Contract.lean`) against the model.
-/

/-- Every check of the test driver, in the order they run. -/
def VcApiTest.checks : List VcApiTest.Check :=
  VcApiTest.versionControlModelChecks ++ VcApiTest.vcApiChecks

/-- Runs the checks and the contract's failure list, and prints each that
failed; the exit status is 1 when one did. -/
def main : IO UInt32 := do
  let failed :=
    (← VcApiTest.failures VcApiTest.checks) ++ (← VcApiTest.versionControlContractFailures)
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println
        s!"vc-api-test: {VcApiTest.checks.length} checks passed, and {Editor.VersionControlContract.properties.length} properties of the version-control interface hold of its model"
    return 0
  else
    return 1
