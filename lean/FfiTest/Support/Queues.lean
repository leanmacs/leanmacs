import Editor.Ffi.Events
import Editor.Job.Runner

/-!
# FFI tests: support: Queues

The hang guard of every wait a check makes (`patience`), a pull from a queue
on a task of its own (`pull`), and a posted message and its round trip
through a queue. Shared by several test modules; it holds no checks of its
own.
-/

namespace FfiTest

/-- hang guard: the event each wait of a check ends on (a pull's return, a
task's end, a park, a rest, a free); only a hang reaches the bound, and the
check then fails as a hang. In milliseconds: 120 000, the measured guard the
config tests' `hangGuard` is, ten times the slowest such event seen under
the stress load. A check waits on the event itself (`Job.awaitWithin`, or a
readout that returns on it, such as `Ffi.awaitWaiting`), never on time, so
the bound decides no result. -/
def patience : Nat :=
  120000

/-- The pull of each queue that ran out its guard (`pull`), still parked in
the library, if there is one. -/
initialize strayPulls : IO.Ref (List (Editor.Ffi.Queue × Task (Except IO.Error Editor.Ffi.Event))) ←
  IO.mkRef []

/-- A pull of `queue` on a dedicated task: the pull a `pull` left parked when
it ran out its guard, if there is one, or a new one. So at most one pull
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

/-- One event pulled from `queue`, or `none` if the pull is still parked
`patience` milliseconds after it began: a hang. The pull runs on a dedicated
task, waited on for its end (`Job.awaitWithin`), so one that never returns
fails its check instead of hanging the executable; a pull that ran out is
kept parked for the next pull of the queue (`pullTask`). -/
def pull (queue : Editor.Ffi.Queue) : IO (Option Editor.Ffi.Event) := do
  let task ← pullTask queue
  let some pulled ← Editor.Job.awaitWithin patience task |
    strayPulls.modify ((queue, task) :: ·)
    return none
  return some (← IO.ofExcept pulled)

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
