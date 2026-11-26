import AgentsApi.Arguments
import AgentsApi.Policy
import AgentsApi.Request
import Editor.Job
import Editor.PackageService

/-!
# A session, as a running job reaches it

The typed wrappers through which a job opens a session, waits for its
events and sends it orders, over the service `agents`
(`AgentsApi/Request.lean`) and the job port (`PackageService.askAs`).

A session is one long-lived job (`docs/design/concurrency.md`, "A long-lived
job owns a handed-over child"): it opens the session and loops on `next`,
and the session's child, opened by that job, ends with it. Any other job
may `send` the session an order, by the number `open` answered.
-/

namespace AgentsApi.Job

/-- Opens `agent`'s command in `cwd` as a streaming child, its input piped
and each stream bounded at `lineBound`, and hands it to the service as a
session given the agent's MCP servers: the session, or why there is none. -/
def «open» (agent : Agent) (cwd : String) : Editor.JobM (Except Refusal Opened) := do
  match ← Editor.Process.start (agent.command cwd) { input := true, bound := lineBound } with
  | .error refusal =>
    return .error (.child refusal)
  | .ok child =>
    return (←
            Editor.PackageService.askAs Opened
                (Request.open child.number cwd agent.mcpServers).toPackage).mapError
        .service

/-- Waits for the next events of `session`: a batch of at least one, or why
there is none, the session having ended among the reasons. -/
def next (session : Nat) : Editor.JobM (Except Refusal Batch) := do
  return (← Editor.PackageService.askAs Batch (Request.next session).toPackage).mapError .service

/-- Sends `session` the order `order`, and waits until it is on its way:
for a prompt, the turn it began. -/
def send (session : Nat) (order : Order) : Editor.JobM (Except Refusal Sent) := do
  return (← Editor.PackageService.askAs Sent (Request.send session order).toPackage).mapError
      .service

end AgentsApi.Job
