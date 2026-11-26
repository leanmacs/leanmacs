import AgentsApiTest.AgentsApi
import AgentsApiTest.AgentsApiTest.Protocol
import AgentsApiTest.Check

/-!
# The test driver of the package `agents-api`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It links no glue and no Rust archive. It only
imports the test modules and runs their checks:

- `protocolChecks`: the protocol's model (`AgentsApiTest/Protocol.lean`),
  each rule of `step` and what `replay` says of a broken trace. The
  theorems over every reachable state are built, not run
  (`AgentsApiTest/Protocol/Theorems.lean`);
- `agentsApiChecks`: the interface library (`AgentsApi.lean`): the service's
  request vocabulary read back as it was written and a malformed request
  refused, the agent registration point a choice by name, and an agent's
  command.
-/

/-- Every check of the test driver, in the order they run. -/
def AgentsApiTest.checks : List AgentsApiTest.Check :=
  AgentsApiTest.protocolChecks ++ AgentsApiTest.agentsApiChecks

/-- Runs the checks, and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← AgentsApiTest.failures AgentsApiTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"agents-api-test: {AgentsApiTest.checks.length} checks passed"
    return 0
  else
    return 1
