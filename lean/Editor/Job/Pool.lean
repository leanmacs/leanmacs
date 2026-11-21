import Editor.Job.Runner

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

How many threads the pool has is Lean's to say: `expected` reads it as the
runtime does, and `holdAll` holds that many tasks at once, each start an
event it waits for, which is how a test of the pool learns its threads with
no window deciding anything.
-/

namespace Editor.Job.Pool

/-- How many threads the machine runs at once: the size Lean gives its pool
unless `LEAN_NUM_THREADS` says otherwise. It is the function Lean's own
runtime sizes the pool with. -/
def size : Nat :=
  (System.Platform.Internal.getHardwareConcurrency ()).toNat

/-- How many threads Lean's runtime gives its pool in this process:
`LEAN_NUM_THREADS` when it is set to a positive number, else `size`, as the
runtime itself decides at start-up. A test of the pool takes its size from
here rather than learning it from a task that does not start. -/
def expected : IO Nat := do
  match (← IO.getEnv "LEAN_NUM_THREADS").bind String.toNat? with
  | some count =>
    if count > 0 then
      return count
    else
      return size
  | none =>
    return size

/-- Holds `count` tasks of the pool at once, each on its own thread, and
returns the ids of their threads once the last has started; `none` if it has
not within `guard` milliseconds. The tasks are let go before it returns.

Each task counts itself as it starts and the `count`-th resolves a promise,
which is what this waits on: no window decides anything. `guard` is a hang
guard: only a pool with fewer than `count` threads to give reaches it, and
the caller then reports a hang.

A task holds its thread in a system call, a short sleep in a loop on the
release promise. Lean does not count that as blocked: waiting on a promise
would make it add a thread to the pool for every task held. -/
def holdAll (count guard : Nat) : IO (Option (Array UInt64)) := do
  let release : IO.Promise Unit ← IO.Promise.new
  let all : IO.Promise Unit ← IO.Promise.new
  let started ← IO.mkRef (#[] : Array UInt64)
  for _ in [0:count] do
    discard <|
        BaseIO.asTask do
          let thread ← IO.getTID
          let now ← started.modifyGet fun threads => (threads.size + 1, threads.push thread)
          if now == count then
            all.resolve ()
          -- real time under test: a thread held in a system call is not
          -- counted as blocked, so the pool adds none for it; the task ends
          -- on the release promise, read each millisecond, and no result is
          -- decided by the time.
          while !(← release.isResolved) do
            IO.sleep 1
  if count == 0 then
    all.resolve ()
  let reached ← Job.awaitWithin guard all.result?
  -- Read before the tasks are let go: they are all running.
  let held ← started.get
  release.resolve ()
  return reached.map fun _ => held

/-- Makes the pool's threads at start-up: holds one task on each of up to
`limit` threads at once, and returns the ids of the threads it held.

It enqueues the tasks one at a time, each only once the one before has
started, and holds every one until the end. So each enqueue finds no idle
thread, and Lean must make one, until the pool has all the threads it may.
It stops at `limit`, or when a task has not started after `patience`
milliseconds: the pool is then full, and that task runs when the others are
let go.

The editor calls it with `limit` = `size`, the pool's size unless
`LEAN_NUM_THREADS` makes it smaller; only then does a task not start, and
the cost is `patience` once. That rests on a rule of Lean's runtime (a
task beyond the pool's threads waits for one), which no check pins: it is
Lean's, not this module's (`holdAll` is what the checks pin).

A task holds its thread in a system call, a short sleep in a loop. Lean
does not count that as blocked: waiting on a promise would make it add a
thread to the pool for every task held. -/
def warm (limit patience : Nat) : IO (Array UInt64) := do
  let release : IO.Promise Unit ← IO.Promise.new
  let started ← IO.mkRef #[]
  for _ in [0:limit] do
    let began : IO.Promise Unit ← IO.Promise.new
    discard <|
        BaseIO.asTask do
          started.modify (·.push (← IO.getTID))
          began.resolve ()
          -- real time under test: a thread held in a system call is not
          -- counted as blocked; the task ends on the release promise.
          while !(← release.isResolved) do
            IO.sleep 1
    -- hang guard, run out on purpose: a pool already full holds the task
    -- for good; the warming stops there, at the pool's size.
    if (← Job.awaitWithin patience began.result?).isNone then
      break
  -- Read before the tasks are let go: one that had not started must not be
  -- counted when it then does.
  let held ← started.get
  release.resolve ()
  return held

end Editor.Job.Pool
