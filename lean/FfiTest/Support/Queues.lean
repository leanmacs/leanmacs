import Editor.Ffi.Events

/-!
# FFI tests: support: Queues

Polling with a bound: `patience`, `eventually`, a pull from a queue on a task of
its own (`pull`), and a posted message and its round trip through a queue.
Shared by several test modules; it holds no checks of its own.
-/

namespace FfiTest

/-- How many times a check polls, a millisecond apart, for something that
should happen at once: about five seconds. Only broken code takes this long,
and the check then fails instead of hanging. -/
def patience : Nat :=
  5000

/-- Polls `condition` until it holds; `false` if it still does not after
`patience` polls. -/
def eventually (condition : IO Bool) : IO Bool := do
  for _ in [0:patience] do
    if ← condition then
      return true
    IO.sleep 1
  return false

/-- The pull of each queue that ran out its patience (`pull`), still parked in
the library, if there is one. -/
initialize strayPulls : IO.Ref (List (Editor.Ffi.Queue × Task (Except IO.Error Editor.Ffi.Event))) ←
  IO.mkRef []

/-- A pull of `queue` on a dedicated task: the pull a `pull` left parked when
it ran out its patience, if there is one, or a new one. So at most one pull
of a queue is ever parked for the checks, and an event that pull takes is
handed to the next caller, never lost to a pull nothing waits for. -/
def pullTask (queue : Editor.Ffi.Queue) : IO (Task (Except IO.Error Editor.Ffi.Event)) := do
  let stray ←
    strayPulls.modifyGet fun strays =>
        ((strays.find? (·.1 == queue)).map (·.2), strays.filter (·.1 != queue))
  match stray with
  | some task =>
    return task
  | none =>
    IO.asTask (prio := .dedicated) (Editor.Ffi.nextEvent queue)

/-- One event pulled from `queue`, or `none` if the pull does not return in
time. The pull runs on a dedicated task, so one that never returns fails its
check instead of hanging the executable; a pull that ran out is kept parked
for the next pull of the queue (`pullTask`). -/
def pull (queue : Editor.Ffi.Queue) : IO (Option Editor.Ffi.Event) := do
  let task ← pullTask queue
  unless ← eventually (IO.hasFinished task) do
    strayPulls.modify ((queue, task) :: ·)
    return none
  return some (← IO.ofExcept task.get)

/-- The message `postEvent` queues for the Lean source `sourceId`. It has no
stamp: only a window says when its events happened. -/
def message (sourceId code : UInt64) (text : String) : Editor.Ffi.Event :=
  { source := { kind := .lean, id := sourceId }, kind := .message, code, text, stamp := 0 }

/-- Posts a message to the editor queue and pulls it back; `true` when what
comes back is that message, from the Lean source `sourceId`. -/
def roundTrips (sourceId code : UInt64) (text : String) : IO Bool := do
  unless ← Editor.Ffi.postEvent .editor sourceId code text do
    return false
  return (← pull .editor) == some (message sourceId code text)

end FfiTest
