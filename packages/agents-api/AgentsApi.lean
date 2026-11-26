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
  through (`AgentsApi/Job.lean`);
- a session's values as command arguments, which a job that runs a session
  posts its events with (`AgentsApi/Arguments.lean`);
- how a conversation is shown, the extension point
  `AgentsApi.ConversationView`, a choice by name (`AgentsApi/View.lean`);
- the permission policy, the extension point `AgentsApi.PermissionPolicy`,
  a choice by name whose type admits no answer the request did not offer,
  and its default, which asks (`AgentsApi/Policy.lean`).

It imports `AgentsApi.Job`, which imports every other module of the
library. It holds no behaviour. The package `acp` implements the service over the
Agent Client Protocol's Rust SDK and registers it (`Package.services`);
consumers import this package alone, never `acp` (owner decision). The test
library publishes the protocol's model with its theorems, the policy's
theorem, the fake of the service and its contract.

## Where an addition goes

| Addition | Where |
|---|---|
| A new event | A case of `Event`, the implementation's encoder (`acp`'s `rust/src/event.rs`) and decoder (`Acp/Codec.lean`), its argument encoding (`Event.toArguments` and `Event.take?`, `AgentsApi/Arguments.lean`, with a case of `AgentsApiTest.everyEvent`), and the fake's script (`AgentsApiTest/Fake.lean`) |
| A new kind of conversation item | A field of `ConversationView` (`AgentsApi/View.lean`), and the implementation's default view |
| A new order | A case of `Order`, its arguments in `Request.orderArguments` and `Request.order?`, the implementation's binding, and the fake |
| A new request of the service | A case of `Request`, its encoding in `toPackage` and `ofPackage?`, a wrapper in `AgentsApi/Job.lean`, and a property of the contract (`AgentsApiTest/Contract.lean`) |
| A new field a policy may read | A field of `PermissionRequest` (`AgentsApi/Policy.lean`), filled by the implementation |
| A new rule of the protocol | An action or a check of `AgentsApiTest/Protocol.lean`, and a theorem beside it |
-/
