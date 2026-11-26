import Acp.Codec
import Editor.PackageService

/-!
# The service `agents`, as the runner reaches it, over the crate's binding

`agents-api`'s service (`AgentsApi/Request.lean`) as the job runner's
package service (`Editor.PackageService`), over a binding of the crate
(`Acp.Binding`): `Acp.jobService`, one function over the binding, as
`Echo.jobService` is. A request is read with `agents-api`'s vocabulary
(`AgentsApi.Request.ofPackage?`), handed to the binding, and its reply,
the crate's text, read back into `agents-api`'s own reply type
(`Acp.Codec.reply`). The package registers it over the Rust-backed binding
(`Acp.Real.service`, `Acp/Packages.lean`); its tests hand it a binding of
their own.
-/

namespace Acp

/-- The crate's C functions, as Lean sees them: the port the service is
made over. Each request is named by the wait id the runner chose. -/
structure Binding where
  /-- Opens a session on the streaming child, in a directory, with the MCP
  servers as `Codec.serversText` writes them: whether it started. -/
  «open» : (request child : UInt64) → (cwd servers : String) → IO Bool
  /-- Waits for a session's next events. -/
  next : (request session : UInt64) → IO Bool
  /-- Sends a session a prompt. -/
  prompt : (request session : UInt64) → String → IO Bool
  /-- Cancels a session's current turn. -/
  cancelTurn : (request session : UInt64) → IO Bool
  /-- Sets a session's mode. -/
  setMode : (request session : UInt64) → String → IO Bool
  /-- Answers a session's parked permission request with an option. -/
  answer : (request session ticket : UInt64) → String → IO Bool
  /-- The reply's text, once the request has completed. -/
  take : (request : UInt64) → IO (Option String)
  /-- Withdraws a request: whether it was in use. -/
  withdraw : (request : UInt64) → IO Bool
  /-- Completes a request once every open and order before it has been. -/
  flush : (request : UInt64) → IO Unit
  /-- Loads a session from the agent's own store on the streaming child, in
  a directory, with the MCP servers as `Codec.serversText` writes them, the
  agent's id of the session last: whether it started. -/
  load : (request child : UInt64) → (cwd servers sessionId : String) → IO Bool

/-- `action`'s value, or `otherwise` when it throws: the runner's port is
`BaseIO`, and the binding's is `IO`. -/
private def orElse {α : Type} (action : IO α) (otherwise : α) : BaseIO α := do
  match ← action.toBaseIO with
  | .ok value =>
    return value
  | .error _ =>
    return otherwise

/-- Hands `request` to `binding` as the wait `id`: whether it started. -/
def started (binding : Binding) (id : UInt64) : AgentsApi.Request → IO Bool
  | .open child cwd servers => binding.open id child.toUInt64 cwd (Codec.serversText servers)
  | .next session => binding.next id session.toUInt64
  | .send session (.prompt text) => binding.prompt id session.toUInt64 text
  | .send session .cancel => binding.cancelTurn id session.toUInt64
  | .send session (.setMode mode) => binding.setMode id session.toUInt64 mode
  | .send session (.answer ticket option) =>
    binding.answer id session.toUInt64 ticket.toUInt64 option
  | .load child cwd servers sessionId =>
    binding.load id child.toUInt64 cwd (Codec.serversText servers) sessionId

/-- The service `agents` over `binding`: a request of `agents-api`'s
vocabulary is handed to the binding, and its reply read back as
`agents-api`'s reply type; any other request is not taken. -/
def jobService (binding : Binding) : Editor.PackageService where
  name := AgentsApi.serviceName
  start id request :=
    match AgentsApi.Request.ofPackage? request with
    | some request => orElse (started binding id request) false
    | none => pure false
  take id request := do
    match AgentsApi.Request.ofPackage? request with
    | none =>
      return .error (.refused "not a request of the service agents")
    | some typed =>
      match ← orElse (binding.take id) none with
      | some text =>
        return Codec.reply typed text
      | none =>
        return .error (.refused "acp had no reply for the request")
  cancel id := discard <| orElse (binding.withdraw id) false
  flush id := orElse (binding.flush id) ()

end Acp
