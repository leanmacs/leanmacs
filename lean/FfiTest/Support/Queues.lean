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

/-- One event pulled from `queue`, or `none` if the pull does not return in
time. The pull runs on a dedicated task, so one that never returns fails its
check instead of hanging the executable. -/
def pull (queue : Editor.Ffi.Queue) : IO (Option Editor.Ffi.Event) := do
  let task ← IO.asTask (prio := .dedicated) (Editor.Ffi.nextEvent queue)
  unless ← eventually (IO.hasFinished task) do
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
