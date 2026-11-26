import Acp.Conversation.State
import AgentsApi.Policy

/-!
# The permission policy, as acp applies it

When a batch of a session's events is applied (`agent-events`), each
permission request of the batch still pending after it is handed to the
policy chosen at `AgentsApi.PermissionPolicy` (`docs/design/agent-hosting.md`,
"Permissions, as built"), and its decision taken (`decisions`):

- a request withdrawn in the same batch, or of a conversation that has
  ended, gets no decision;
- the decision is taken once, on arrival: a request still pending after a
  reload or a change of policy is not decided again, and stays the user's;
- an answer is the request's own option at the index the policy chose, so
  only an offered option's id is ever sent.

This module is pure; the command that starts each answer's job is
`Acp/Conversation.lean`'s.
-/

namespace Acp.Permissions

open AgentsApi

/-- The request a policy is handed for the permission request `ticket` of
`conversation`: the conversation's agent, root and session id with the
request's own fields. -/
def requestOf (conversation : Conversation) (ticket : Nat) (turn : Option Nat) (call : ToolCall)
    (options : Array PermissionOption) : PermissionRequest :=
  { agent := conversation.agent, root := conversation.root
    sessionId := conversation.sessionId.getD "", ticket, turn, call, options }

/-- The permission requests of `batch` still pending in `conversation`, the
conversation after the batch, in event order; none once it has ended. -/
def arrived (conversation : Conversation) (batch : Batch) : Array PermissionRequest :=
  if conversation.ended.isSome then #[]
  else
    batch.events.filterMap fun event =>
      match event with
      | .permission ticket turn call options =>
        if conversation.pending.contains ticket then
          some (requestOf conversation ticket turn call options)
        else none
      | _ => none

/-- What `policy` decided of each request of `batch` still pending in
`conversation`, the conversation after the batch (the module docs): the
request and the option it answers with, none to ask. -/
def decisions (policy : PermissionPolicy) (conversation : Conversation) (batch : Batch) :
    Array (PermissionRequest × Option PermissionOption) :=
  (arrived conversation batch).map fun request => (request, policy.answer request)

end Acp.Permissions
