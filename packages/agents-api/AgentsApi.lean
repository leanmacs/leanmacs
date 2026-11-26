import AgentsApi.Job

/-!
# The interface package `agents-api`

What a session with a coding agent is to the editor, in its own terms and
with no protocol in sight (`docs/design/agent-hosting.md`, "ACP"):

- the plain events a session produces (`AgentsApi/Event.lean`);
- the orders a client gives it (`AgentsApi/Order.lean`);
- the agent registration point, `AgentsApi.Agent`, with everything a
  session is started with passed explicitly and no session mode or agent
  configuration of the editor's own (`AgentsApi/Agent.lean`);
- the service `agents`, its requests and its replies
  (`AgentsApi/Request.lean`), and the typed wrappers a job reaches it
  through (`AgentsApi/Job.lean`).

It imports `AgentsApi.Job`, which imports every other module of the
library. It holds no behaviour. The package `acp` implements the service over the
Agent Client Protocol's Rust SDK and registers it (`Package.services`);
consumers import this package alone, never `acp` (owner decision). The test
library publishes the protocol's model with its theorems, the fake of the
service and its contract.

## Where an addition goes

| Addition | Where |
|---|---|
| A new event | A case of `Event`, the implementation's encoder (`acp`'s `rust/src/event.rs`) and decoder (`Acp/Codec.lean`), and the fake's script (`AgentsApiTest/Fake.lean`) |
| A new order | A case of `Order`, its arguments in `Request.orderArguments` and `Request.order?`, the implementation's binding, and the fake |
| A new request of the service | A case of `Request`, its encoding in `toPackage` and `ofPackage?`, a wrapper in `AgentsApi/Job.lean`, and a property of the contract (`AgentsApiTest/Contract.lean`) |
| A new rule of the protocol | An action or a check of `AgentsApiTest/Protocol.lean`, and a theorem beside it |
-/
