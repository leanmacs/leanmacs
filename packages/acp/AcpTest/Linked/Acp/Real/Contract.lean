import Acp.Real
import AcpTest.Check
import AcpTest.ScriptedAgent
import AgentsApiTest.Contract
import Editor.RealHost
import Editor.Test.Linked.Jobs
import Editor.Test.Linked.Services

/-!
# Linked tests: `agents-api`'s contract on the acp crate

The contract of the service `agents` (`AgentsApiTest/Contract.lean`)
against the crate's binding as the runner's package service
(`Acp.Real.service`), over the linked test kit's table of waits and its
completion pump (`Editor.Test.Linked.Services.start`), the same queue and
pump the editor runs. Each property's canonical agent is the scripted
agent executable (`AcpTest.ScriptedAgent`), opened as a streaming child
through the real process port with `AgentsApi.lineBound` and its input
piped, and handed to the crate by its number, which takes it over; each
property's child is ended at its end, whatever state its session is in.
So the fake the package's driver holds to the contract and the crate
cannot drift apart.

It runs the contract against the real crate, outside the rule of the
wiring set (`docs/dev-practices/real-thread-checks.md`).
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.AcpTest.Linked.Acp.Real.Contract : Editor.WiringSet :=
  .contract "agents-api's service agents, on the acp crate"

namespace AcpTest.Linked

open Editor

/-- Opens the scripted agent in `directory` as a streaming child through
`services`' real process port, its input piped and each stream bounded at
`AgentsApi.lineBound`, and gives its number once it is open. -/
def openedAgent (services : Editor.Test.Linked.Services) (directory : System.FilePath) : IO Nat :=
  do
  let request :=
    ProcessRequest.start (ScriptedAgent.command directory.toString)
      { input := true, bound := AgentsApi.lineBound }
  let (child, wait) ← services.completions.register
  services.jobs.processes.start child request
  -- Waited for on the wait itself; the kit's patience is a hang guard.
  unless (← Job.awaitWithin Editor.Test.Linked.patience wait.result?) == some (some .completed) do
    throw (IO.userError "the scripted agent's start did not complete")
  match ← services.jobs.processes.take child request with
  | .ok _ =>
    return child.toNat
  | .error refusal =>
    throw (IO.userError s!"the scripted agent was refused: {repr refusal}")

/-- The crate as the contract's rig, over `services`, each canonical agent
opened in `directory`. -/
def realRig (services : Editor.Test.Linked.Services) (directory : System.FilePath) :
    AgentsApiTest.Contract.Rig :=
  { name := "the acp crate", service := Acp.Real.service, completions := services.completions
    patience := Editor.Test.Linked.patience
    opened := openedAgent services directory
    release := fun child => services.jobs.processes.cancel child.toUInt64 }

/-- The check of the crate: every property of the contract, each on a
scripted agent of its own, in a temporary directory removed once the
process service has reaped them. -/
def contractChecks (services : Editor.Test.Linked.Services) : List Check :=
  [{  name :=
        s!"the acp crate holds the {AgentsApiTest.Contract.properties.length} properties of agents-api's service agents, each on a scripted agent of its own"
      run :=
        Editor.Test.Linked.withFiles services.jobs (targets := [.processes]) fun directory => do
          let failing ← AgentsApiTest.Contract.failures (realRig services directory)
          saw failing.isEmpty s!"{failing}" }]

end AcpTest.Linked
