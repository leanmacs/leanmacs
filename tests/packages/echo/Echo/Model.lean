import Echo
import Std.Data.HashMap

/-!
# The pure model of the echo port

A request completes the moment it starts: its reply is held at once. It
refuses what the service refuses: an id in use, from its start until it is
taken or cancelled.
-/

namespace Echo

/-- The model: the replies held, by id. -/
structure Model where
  /-- The requests in use: each started and not taken or cancelled, with its
  reply. -/
  held : IO.Ref (Std.HashMap UInt64 Reply)

namespace Model

/-- A model that holds no request. -/
def new : IO Model :=
  return { held := ← IO.mkRef {} }

/-- Whether the request `id` has completed and its reply is held. -/
def completed (model : Model) (id : UInt64) : IO Bool :=
  return (← model.held.get).contains id

/-- The port over the model. -/
def echo (model : Model) : Service where
  start id text :=
    model.held.modifyGet fun held =>
      if held.contains id then (false, held) else (true, held.insert id (Reply.to text))
  cancel id := model.held.modifyGet fun held => (held.contains id, held.erase id)
  take id := model.held.modifyGet fun held => (held[id]?, held.erase id)

end Model

end Echo
