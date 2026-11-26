import AgentsApiTest.AgentsApi
import AgentsApiTest.AgentsApi.Arguments
import AgentsApiTest.AgentsApi.Policy
import AgentsApiTest.AgentsApi.View
import AgentsApiTest.AgentsApiTest.Contract
import AgentsApiTest.AgentsApiTest.Fake
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
  refused, the agent registration point a choice by name, an agent's
  command, and a refusal's words;
- `argumentsChecks`: a session's values as command arguments
  (`AgentsApi/Arguments.lean`), each read back as it was written, and a
  malformed list read as none;
- `viewChecks`: the extension point `ConversationView`
  (`AgentsApi/View.lean`), a choice by name;
- `policyChecks`: the extension point `PermissionPolicy`
  (`AgentsApi/Policy.lean`): the default asks, a decision by kind or by id
  chooses an offered option or asks, and the point is a choice by name.
  The theorems that no policy answers with an option the request did not
  offer are built, not run (`AgentsApiTest/AgentsApi/Policy/Theorems.lean`);
- `fakeChecks`: the fake of the service (`AgentsApiTest/Fake.lean`) at the
  runner's port: what each request answers and when a `next` completes;
- `contractBiteChecks`: three flawed fakes, each refused by the contract on
  the property it breaks;
- `contractFailures`: the contract (`AgentsApiTest/Contract.lean`) against
  the fake.
-/

/-- Every check of the test driver, in the order they run. -/
def AgentsApiTest.checks : List AgentsApiTest.Check :=
  AgentsApiTest.protocolChecks ++ AgentsApiTest.agentsApiChecks ++ AgentsApiTest.argumentsChecks ++
    AgentsApiTest.viewChecks ++
    AgentsApiTest.policyChecks ++
    AgentsApiTest.fakeChecks ++
    AgentsApiTest.contractBiteChecks

/-- Runs the checks, and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed :=
    (← AgentsApiTest.failures AgentsApiTest.checks) ++ (← AgentsApiTest.contractFailures)
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println
        s!"agents-api-test: {AgentsApiTest.checks.length} checks passed, and {AgentsApiTest.Contract.properties.length} properties of the service agents hold of its fake"
    return 0
  else
    return 1
