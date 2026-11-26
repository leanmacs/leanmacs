import Acp.Permissions.Policy
import AcpTest.Acp.Conversation.State

/-!
# Model tests: `Acp/Permissions/Policy.lean`

`policyChecks`: the decisions of a policy on a batch, as acp takes them
when the batch is applied. A batch's permission request gets the policy's
decision; one withdrawn in the same batch gets none; a chosen answer is the
indexed option's own; the default asks and so sends nothing; and an ended
conversation decides nothing. The test driver's root, `AcpTest/Model.lean`,
runs them.
-/

namespace AcpTest

open AgentsApi
open AgentsApiTest
open Acp.Permissions

/-- `example1` with its session open. -/
def openedExample : Acp.Conversation :=
  example1.opened
    { session := 1, sessionId := Contract.sessionId, mode := some "mode-auto"
      modes := Contract.modes }

/-- The batch of `Fake.permissionRequest`'s prompt: the pending call, then
its permission request, ticket 1 of turn 1. -/
def askedBatch : Batch :=
  {
    events :=
      #[.toolCall Fake.editPending, .permission 1 (some 1) Fake.editAsked Fake.adapterOptions] }

/-- A policy named `name` that decides by the protocol kind `kind`. -/
def byKind (kind : String) (name : String := PermissionPolicy.defaultName) : PermissionPolicy :=
  { name, decide := fun request => .ofKind request kind }

/-- What `policy` decided of `batch`, applied to `conversation`, as pairs
of the ticket and the answer's id. -/
def decided (policy : PermissionPolicy) (conversation : Acp.Conversation) (batch : Batch) :
    Array (Nat × Option String) :=
  (decisions policy (conversation.applyBatch batch) batch).map fun (request, answer) =>
    (request.ticket, answer.map (·.id))

/-- The checks of `Acp/Permissions/Policy.lean`. -/
def permissionPolicyChecks : List Check :=
  [{  name :=
        "a batch's permission request is handed to the policy whole, the conversation's agent, root and session id with the event's ticket, turn, call and options, and gets its decision"
      run := do
        let after := openedExample.applyBatch askedBatch
        let made := decisions (byKind "allow_once") after askedBatch
        let request : PermissionRequest :=
          { agent := Acp.defaultAgent, root := "/work/example", sessionId := Contract.sessionId
            ticket := 1, turn := some 1, call := Fake.editAsked, options := Fake.adapterOptions }
        saw
            (made.map (·.1) == #[request] &&
              (made.map fun (_, answer) => answer.map (·.id)) == #[some "allow-once"])
            s!"{repr made}" },
    { name := "a request withdrawn in the same batch gets no decision"
      run := do
        let batch := { askedBatch with events := askedBatch.events.push (.withdrawn 1) }
        let made := decided (byKind "allow_once") openedExample batch
        saw made.isEmpty s!"{made}" },
    { name := "a chosen answer is the option at the index the policy chose, by that option's own id"
      run := do
        let second : PermissionPolicy :=
          { name := "second",
            decide := fun request => if h : 1 < request.options.size then .choose ⟨1, h⟩ else .ask }
        let made := decided second openedExample askedBatch
        saw (made == #[(1, some "allow-session")]) s!"{made}" },
    { name := "the default policy asks: its decision answers no option, so nothing is sent"
      run := do
        let made := decided PermissionPolicy.ask openedExample askedBatch
        saw (made == #[(1, none)]) s!"{made}" },
    { name :=
        "a batch with no permission request decides nothing, nor does a conversation that has ended"
      run := do
        let silent := decided (byKind "allow_once") openedExample { events := conversationEvents }
        let ended :=
          decided (byKind "allow_once") { openedExample with ended := some "stopped" } askedBatch
        saw (silent.isEmpty && ended.isEmpty) s!"silent {silent}, ended {ended}" }]

end AcpTest
