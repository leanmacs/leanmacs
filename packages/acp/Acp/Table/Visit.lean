import Acp.Conversation.State
import AgentsApi.Table

/-!
# What a visit of an agent does

A visit of a session of the agent table (`agent-visit`), decided pure from
its record and the conversation of its id, if this process holds one
(`Visit.decide`):

- **show** the conversation's buffer, when a conversation of that id holds
  one and has not ended without ever opening;
- **resume** the session from the agent's own store, when the record has
  the provider's session id and no conversation of that id holds a buffer,
  as after a restart, or the one that does ended before its session opened,
  as a refused load does: so a later visit tries again, in that buffer;
- **refuse**, saying why, when the record never had a session to resume.

So a session is loaded once, on its first visit: a second visit finds its
conversation and only shows it.
-/

namespace Acp.Table

open AgentsApi

/-- What a visit does (the module docs). -/
inductive Visit where
  /-- Show the buffer of this number. -/
  | show (buffer : Nat)
  /-- Resume the session of this provider's id, in the buffer of this number
  when there is one to reuse. -/
  | resume (sessionId : String) (buffer : Option Nat)
  /-- Do nothing, saying this. -/
  | refuse (words : String)
  deriving DecidableEq, Repr

/-- What a visit of `record` does, `conversation?` the conversation of its
id, if one is held (the module docs). -/
def Visit.decide (record : AgentRecord) (conversation? : Option Conversation) : Visit :=
  let shown : Option Nat := conversation?.bind (·.buffer)
  let failedOpen := conversation?.any fun held => held.ended.isSome && held.session.isNone
  match shown, record.sessionId with
  | some buffer, some sessionId =>
    if failedOpen then .resume sessionId (some buffer) else .show buffer
  | some buffer, none => .show buffer
  | none, some sessionId => .resume sessionId none
  | none, none => .refuse s!"{record.name} never opened a session, so there is nothing to resume"

end Acp.Table
