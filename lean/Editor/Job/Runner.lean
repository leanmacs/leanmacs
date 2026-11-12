import Editor.Job
import Std.Data.HashMap

/-!
# The job runner

Runs a job (`Editor/Job.lean`) on Lean's task pool, built on plain tasks and
promises.

## A wait is a promise

A request that waits does not park a thread. The runner registers the wait in
the table of waits (`Completions`), which gives it an id and a promise, and
hands the id to the service that will complete it. Whatever completes the
wait calls `Completions.finish` with the id, which resolves the promise.

That is the whole matching rule: a request carries its id to the service,
the completion carries it back, and a completion for an id that is no longer
waiting is dropped. An id is a counter from 1 and is never used again in a
process. A promise that is dropped unresolved reads as `cancelled`.

## Where a job runs

`spawn` starts a pool task and returns. What it is given is a `Work`, a
function, and the task applies it: a job's leading pure work, the code before
its first request, runs on the pool and never on the thread that spawned it
(`start` says how that is forced). From there `drive` takes the job a
request at a time. A request that is answered at once is a direct call on
the job's thread. A request that waits ends the loop, and the rest of the
job is chained on the wait's promise, so a job in a wait holds no thread and
any number of waiting jobs leave the pool free.

A known limit: in compiled code Lean lifts a closed term out to a constant
that is computed when the module is initialised. Leading work that depends on
nothing is such a term, so it is computed once at start-up, not at each
spawn. Interpreted config is not affected.

## The clock port

`Timers` is the port the runner's waits are made of: read the clock, start a
wait with an id and a deadline, withdraw a wait. It has a fake a test moves
by hand (`Editor/Job/Fake.lean`) and a real implementation over the Rust
library's timer service (`Editor/Job/Real.lean`). `Services` is what a
runner is given: the table and the clock.
-/

namespace Editor.Job

/-- How a wait ended. -/
inductive Completion where
  /-- The service completed it. -/
  | completed
  /-- It was withdrawn: the job that made it was cancelled. -/
  | cancelled
  deriving DecidableEq, Repr, Inhabited

/-- What the table of waits holds. -/
structure Pending where
  /-- The id of the next wait. -/
  next : UInt64 := 1
  /-- The promise of each wait that has not ended. -/
  waits : Std.HashMap UInt64 (IO.Promise Completion) := {}

/-- The table of waits in flight, shared by the runner and whatever completes
its waits. -/
structure Completions where
  /-- The table. Every change to it is one atomic step. -/
  pending : IO.Ref Pending

namespace Completions

/-- A table with no waits. -/
def new : BaseIO Completions :=
  return { pending := ← IO.mkRef {} }

/-- Registers a wait: its id, and the promise that ends it. -/
def register (completions : Completions) : BaseIO (UInt64 × IO.Promise Completion) := do
  let wait ← IO.Promise.new
  let id ←
    completions.pending.modifyGet fun pending =>
        (pending.next,
          { next := pending.next + 1, waits := pending.waits.insert pending.next wait })
  return (id, wait)

/-- Ends the wait `id` as `completion`, and forgets it. Does nothing if `id`
is not waiting: it never was, or it has ended already. -/
def finish (completions : Completions) (id : UInt64) (completion : Completion) : BaseIO Unit := do
  let wait? ←
    completions.pending.modifyGet fun pending =>
        (pending.waits[id]?, { pending with waits := pending.waits.erase id })
  if let some wait := wait? then
    wait.resolve completion

/-- How many waits are in flight. -/
def waiting (completions : Completions) : BaseIO Nat :=
  return (← completions.pending.get).waits.size

end Completions

/-- The clock port: what the runner's waits are made of. -/
structure Timers where
  /-- The clock's reading, in milliseconds. -/
  now : BaseIO Nat
  /-- Asks for the wait `id` to be completed once the clock reads `deadline`
  or later. It returns at once and never blocks. -/
  start : (id : UInt64) → (deadline : Nat) → BaseIO Unit
  /-- Withdraws the wait `id`: the clock will not complete it. Safe for an id
  that is not waiting. -/
  cancel : (id : UInt64) → BaseIO Unit

/-- What a runner is given. -/
structure Services where
  /-- The waits in flight. -/
  completions : Completions
  /-- The clock. -/
  timers : Timers

instance {α : Type} : Nonempty (Outcome α) :=
  ⟨.cancelled⟩

/-- A job that was spawned, as whoever spawned it holds it. -/
structure Handle where
  /-- How the job ended, once it has. -/
  outcome : IO.Promise (Outcome (EditorM Unit))

namespace Handle

/-- Whether the job has ended. -/
def ended (handle : Handle) : BaseIO Bool :=
  handle.outcome.isResolved

/-- How the job ended; `none` while it runs. It never blocks. -/
def outcome? (handle : Handle) : BaseIO (Option (Outcome (EditorM Unit))) := do
  if ← handle.outcome.isResolved then
    return some (handle.outcome.result?.get.getD .cancelled)
  else
    return none

/-- Leaves `outcome` in the handle, then calls `finished`: the job has ended. -/
def conclude (handle : Handle) (finished : BaseIO Unit) (outcome : Outcome (EditorM Unit)) :
    BaseIO Unit := do
  handle.outcome.resolve outcome
  finished

end Handle

/-- The runner's answer to a request: its reply at once, or once a wait has
ended. -/
inductive Answer (α : Type) where
  /-- The reply. -/
  | now (reply : α)
  /-- The reply, once `wait` has ended. -/
  | later (wait : IO.Promise Completion) (reply : α)

/-- Answers a request. A request that waits is registered in the table of
waits and handed to its service, and nothing here waits for it. -/
def answer (services : Services) : (request : JobRequest) → BaseIO (Answer request.Reply)
  | .now => return .now (← services.timers.now)
  | .waitUntil deadline => do
    let (id, wait) ← services.completions.register
    services.timers.start id deadline
    return .later wait ()

/-- Runs `program` to its end, a request at a time. A request that is
answered at once is a direct call, and the loop goes on on the same thread.
At a request that waits the loop ends, and the rest of the job is chained on
the wait's promise: it runs on a pool task when the wait has ended, and until
then the job holds no thread. -/
partial def drive (services : Services) (handle : Handle) (finished : BaseIO Unit) :
    Program jobPort (Except String (EditorM Unit)) → BaseIO Unit
  | .done (.ok command) => handle.conclude finished (.finished command)
  | .done (.error message) => handle.conclude finished (.failed message)
  | .step request next => do
    match ← answer services request with
    | .now reply =>
      drive services handle finished (next reply)
    | .later wait reply =>
      BaseIO.chainTask wait.result? fun _ => drive services handle finished (next reply)

/-- The body of a job's task: applies `work`, then runs the program it gives.

It is a function of its own, never inlined, so that `work ()` is evaluated
when the task runs it and not where the task is made. Written in place, as
`BaseIO.asTask do drive … (work ()).run`, the application is an argument of
the action handed to `asTask`, and Lean evaluates it on the thread that
calls `spawn`, before the task exists. -/
@[noinline]
def start (services : Services) (handle : Handle) (finished : BaseIO Unit) (work : Work) :
    BaseIO Unit :=
  drive services handle finished (work ()).run

/-- Starts `work` on the pool and returns at once: none of the job runs on
the calling thread, its leading pure work included. `finished` is called once
the job has ended and its outcome is in the handle. -/
def spawn (services : Services) (work : Work) (finished : BaseIO Unit) : BaseIO Handle := do
  let handle : Handle := { outcome := ← IO.Promise.new }
  discard <| BaseIO.asTask (start services handle finished work)
  return handle

end Editor.Job
