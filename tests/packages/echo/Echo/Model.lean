import Echo
import Editor.PackageService
import Std.Data.HashMap

/-!
# The pure model of the echo port

A request completes the moment it starts: its reply is held at once. It
refuses what the service refuses: an id in use, from its start until it is
taken or cancelled. It has no children, so an attach is refused; and a
flush completes the moment it is asked, since nothing is ever in flight.

`Echo.Model.packages` is the model of echo's service as a job reaches it
(`Echo/Job.lean`): a `say` answers its text and checksum at once.
-/

namespace Echo

/-- The model: the replies held, by id, and the flushes completed. -/
structure Model where
  /-- The requests in use: each started and not taken or cancelled, with its
  reply. -/
  held : IO.Ref (Std.HashMap UInt64 Reply)
  /-- The flushes asked, each completed at once. -/
  flushed : IO.Ref (Array UInt64)

namespace Model

/-- A model that holds no request. -/
def new : IO Model :=
  return { held := ← IO.mkRef {}, flushed := ← IO.mkRef #[] }

/-- Whether the request or flush `id` has completed: its reply is held, or
it is a flush. -/
def completed (model : Model) (id : UInt64) : IO Bool :=
  return (← model.held.get).contains id || (← model.flushed.get).contains id

/-- The port over the model. -/
def echo (model : Model) : Service where
  start id text :=
    model.held.modifyGet fun held =>
      if held.contains id then (false, held) else (true, held.insert id (Reply.to text))
  cancel id := model.held.modifyGet fun held => (held.contains id, held.erase id)
  take id := model.held.modifyGet fun held => (held[id]?, held.erase id)
  attach _ _ := pure false
  attachTake _ := pure none
  flush id := model.flushed.modify (·.push id)

/-- Echo's service as a job reaches it (`Echo/Job.lean`), pure: a `say` of
a text answers the text and its checksum; any other request of `echo` is
refused, an `attach` among them, since the model has no children; and it
knows no other service. -/
def packages : Editor.PackageModel := fun request =>
  if request.service == serviceName then
    match request.operation, request.arguments with
    | "say", [.str text] => some (.ok (.mk (Reply.to text)))
    | _, _ => some (.error (.refused s!"the model of echo does not answer {request.operation}"))
  else none

end Model

end Echo
