import Echo
import Editor.Job
import Editor.PackageService

/-!
# The echo service, reached by a running job

Echo's service as the job runner reaches it (`docs/design/packages.md`,
"Behind a port, so it stays replaceable"): the requests a job makes of it
through the job port (`Echo.Job.say`, `Echo.Job.attach`), each read back as
the package's own reply type, and the adapter from echo's port
(`Echo.Service`) to the runner's (`Editor.PackageService`),
`Echo.jobService`, so the logic between them is one function over the
port. The package registers that adapter over the Rust-backed binding
(`Echo.Real.service`, `Echo/Packages.lean`); a check hands the runner a
fake over the pure model (`Echo.Model.packages`) in its place.

- **`say`** of a text answers the text and its CRC-32 (`Echo.Reply`).
- **`attach`** of a streaming child the job opened hands it to the crate,
  which takes it over and reads it to its end, and answers what it read
  (`Echo.Attached`). The child is still the job's (`Job.Handle.children`):
  cancelling the job withdraws the request at the service first, then ends
  the child, and the crate's consumer, blocked in a pull, is answered
  cancelled, its last event; the crate posts no completion for a request
  withdrawn first (`docs/design/concurrency.md`, "A long-lived job owns a
  handed-over child").
-/

namespace Echo

/-- The request of a `say` of `text`. -/
def sayRequest (text : String) : Editor.PackageRequest :=
  { service := serviceName, operation := "say", arguments := [.str text] }

/-- The request of an `attach` of the child `child`. -/
def attachRequest (child : Editor.Process.Id) : Editor.PackageRequest :=
  { service := serviceName, operation := "attach", arguments := [.nat child.number] }

/-- The child an `attach` request hands over, if `request` is one. -/
def attachedChild (request : Editor.PackageRequest) : Option UInt64 :=
  match request.operation, request.arguments with
  | "attach", [.nat child] => some child.toUInt64
  | _, _ => none

namespace Job

/-- Asks echo's service to say `text`, and waits for its reply: the text
and its checksum, or why it did not answer. -/
def say (text : String) : Editor.JobM (Except Editor.PackageError Reply) :=
  Editor.PackageService.askAs Reply (sayRequest text)

/-- Hands the streaming child `child`, which this job opened, to echo's
crate, and waits until the crate has read it to its end: what it read, or
why it did not take it. -/
def attach (child : Editor.Process.Id) : Editor.JobM (Except Editor.PackageError Attached) :=
  Editor.PackageService.askAs Attached (attachRequest child)

end Job

/-- `action`'s value, or `otherwise` when it throws: the runner's port is
`BaseIO`, and echo's is `IO`. -/
private def orElse {α : Type} (action : IO α) (otherwise : α) : BaseIO α := do
  match ← action.toBaseIO with
  | .ok value =>
    return value
  | .error _ =>
    return otherwise

/-- Echo's port as the runner's package service: a `say` starts a request
of its text, an `attach` hands its child over, and each reply is taken as
the package's own type; any other request is not taken. -/
def jobService (echo : Service) : Editor.PackageService where
  name := serviceName
  start id request :=
    match request.operation, request.arguments with
    | "say", [.str text] => orElse (echo.start id text) false
    | "attach", [.nat child] => orElse (echo.attach id child.toUInt64) false
    | _, _ => pure false
  take id request := do
    match request.operation with
    | "attach" =>
      match ← orElse (echo.attachTake id) none with
      | some attached =>
        return .ok (.mk attached)
      | none =>
        return .error (.refused "echo had no read for the attach")
    | _ =>
      match ← orElse (echo.take id) none with
      | some reply =>
        return .ok (.mk reply)
      | none =>
        return .error (.refused "echo had no reply for the say")
  cancel id := discard <| orElse (echo.cancel id) false
  flush id := orElse (echo.flush id) ()

end Echo
