import AcpTest.Acp.ClaudeCode
import AcpTest.Acp.Codec
import AcpTest.Acp.Conversation.Diff
import AcpTest.Acp.Conversation.Render
import AcpTest.Acp.Conversation.State
import AcpTest.Acp.Permissions.Audit
import AcpTest.Acp.Permissions.Outbox
import AcpTest.Acp.Permissions.Policy
import AcpTest.Acp.Permissions.Queue
import AcpTest.Acp.Service

/-!
# The test driver of the package `acp`

`lake test` builds and runs this (`mise run lean-test`, through
`tools/package-set.sh test`). It imports no module that binds the crate
(`Acp.Real`), so it links no glue and no Rust archive. It only imports the
test modules and runs their checks:

- `codecChecks`: the crate's text read into `agents-api`'s values
  (`Acp/Codec.lean`), on the golden lines `rust/src/event.rs`'s tests hold;
- `serviceChecks`: the service `agents` over a binding written in the test
  (`Acp/Service.lean`);
- `diffChecks`: a tool call's diff as the conversation shows it
  (`Acp/Conversation/Diff.lean`);
- `stateChecks`: a conversation after each event and each of the client's
  steps, and its store's tree (`Acp/Conversation/State.lean`);
- `claudeCodeChecks`: Claude Code's adapter, with nothing of the editor's
  in its environment, and what `Acp.setup` registers
  (`Acp/ClaudeCode.lean`, `Acp/Conversation.lean`);
- `renderChecks`: a conversation's text, its fold and its map of rows, as
  the default view shows it, and a queued request's lines
  (`Acp/Conversation/Render.lean`, `Acp/Conversation/View.lean`);
- `permissionPolicyChecks`: a policy's decisions on a batch
  (`Acp/Permissions/Policy.lean`);
- `queueChecks`: the queue of a project's pending permission requests, its
  order, its text and its map of rows (`Acp/Permissions/Queue.lean`);
- `auditChecks`: the audit log's records, each a golden line, escaped and
  read back, in event order (`Acp/Permissions/Audit.lean`);
- `outboxChecks`: the audit log's outbox, one write at a time, each
  dropping exactly the lines it held (`Acp/Permissions/Outbox.lean`).

The service over the real crate, with `agents-api`'s contract, is the
linked test's (`AcpTest/Linked.lean`).
-/

/-- Every check of the test driver, in the order they run. -/
def AcpTest.checks : List AcpTest.Check :=
  AcpTest.codecChecks ++ AcpTest.serviceChecks ++ AcpTest.diffChecks ++ AcpTest.stateChecks ++
    AcpTest.renderChecks ++
    AcpTest.claudeCodeChecks ++
    AcpTest.permissionPolicyChecks ++
    AcpTest.queueChecks ++
    AcpTest.auditChecks ++
    AcpTest.outboxChecks

/-- Runs the checks and prints each that failed; the exit status is 1 when
one did. -/
def main : IO UInt32 := do
  let failed ← AcpTest.failures AcpTest.checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  if failed.isEmpty then
    IO.println s!"acp-test: {AcpTest.checks.length} checks passed"
    return 0
  else
    return 1
