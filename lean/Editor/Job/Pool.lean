/-!
# Warming the pool

Lean's task pool has as many threads as the machine runs at once (its
hardware concurrency), unless `LEAN_NUM_THREADS` says otherwise, and that is
the size the editor wants: a job in a wait holds no thread
(`Editor/Job/Runner.lean`), so the pool only computes, and one thread a core
is the size for that. The editor does not set `LEAN_NUM_THREADS` itself,
because every child process would inherit it. A user can.

The pool makes its threads lazily: one for each task that is enqueued while
no thread is idle. A burst of tasks on a cold pool therefore runs on a few
threads until more have been made. `warm` makes them all at start-up.
-/

namespace Editor.Job.Pool

/-- How many threads the machine runs at once: the size Lean gives its pool
unless `LEAN_NUM_THREADS` says otherwise. It is the function Lean's own
runtime sizes the pool with. -/
def size : Nat :=
  (System.Platform.Internal.getHardwareConcurrency ()).toNat

/-- Polls `condition` until it holds; `false` if it still does not after
`patience` milliseconds. It spins first: what it waits for takes
microseconds. -/
def within (patience : Nat) (condition : BaseIO Bool) : BaseIO Bool := do
  let deadline := (← IO.monoMsNow) + patience
  let mut polls := 0
  repeat
    if ← condition then
      return true
    if (← IO.monoMsNow) >= deadline then
      break
    polls := polls + 1
    if polls > 1000 then
      IO.sleep 1
  return false

/-- Makes the pool's threads: holds one task on each of up to `limit` threads
at once, and returns the ids of the threads it held.

It enqueues the tasks one at a time, each only once the one before has
started, and holds every one until the end. So each enqueue finds no idle
thread, and Lean must make one, until the pool has all the threads it may.
It stops at `limit`, or when a task has not started after `patience`
milliseconds: the pool is then full, and that task runs when the others are
let go.

A task holds its thread in a system call, a short sleep in a loop. Lean
does not count that as blocked: waiting on a promise would make it add a
thread to the pool for every task held. -/
def warm (limit patience : Nat) : BaseIO (Array UInt64) := do
  let release : IO.Promise Unit ← IO.Promise.new
  let started ← IO.mkRef #[]
  for index in [0:limit] do
    discard <|
        BaseIO.asTask do
          started.modify (·.push (← IO.getTID))
          while !(← release.isResolved) do
            IO.sleep 1
    unless ← within patience (return (← started.get).size > index) do
      break
  -- Read before the tasks are let go: one that had not started must not be
  -- counted when it then does.
  let held ← started.get
  release.resolve ()
  return held

end Editor.Job.Pool
