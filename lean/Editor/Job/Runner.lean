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

A completion says only that a wait is over. What the wait came to, if it
came to anything, is fetched afterwards: an answer that waits carries the
action that gives the reply (`Answer.later`), and the runner runs it on the
job's thread once the wait has completed, and never for a job that was
cancelled. A timer's wait comes to nothing, so its action is `pure ()`.

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

## Cancellation

Lean's own `IO.cancel` only sets a flag: it interrupts no wait. So
cancellation is built here.

- **The token** is in the job's handle: whether the job is cancelled, and
  the id of the wait it is in, if it is in one, changed together in one
  atomic step.
- **Every wait races it.** `Handle.cancel` sets the token, takes the id,
  tells the clock to withdraw that wait and ends it in the table as
  `cancelled`. A promise resolves once, so whichever of the service and the
  cancel comes first wins and the other does nothing. A wait the job was
  still making when it was cancelled is withdrawn by the job itself, as
  soon as it sees the token.
- **A cancelled job makes no further request.** The runner looks at the
  token before each request, when each reply arrives, at once or after a
  wait, and when the program ends.
- **A `try`/`catch` cannot resume it.** Cancellation is not a reply and
  nothing is thrown into the program: the runner stops applying the job's
  continuation, and the `catch` handlers are part of that continuation.
  The outcome is `cancelled` whatever the program would have returned.
- **A cancelled job runs no cleanup of its own.** What it holds is the
  runner's to release: the wait it is in is withdrawn, and a handle to a
  library object is freed by its finaliser when the continuation is dropped.

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

/-- A job's token: what the job and whoever cancels it share. -/
structure Flags where
  /-- Whether the job has been cancelled. -/
  cancelled : Bool := false
  /-- The wait the job is in, if it is in one. -/
  waiting : Option UInt64 := none

/-- A job that was spawned, as whoever spawned it holds it. -/
structure Handle where
  /-- What the job's waits are made of. -/
  services : Services
  /-- The job's token. Every change to it is one atomic step. -/
  flags : IO.Ref Flags
  /-- How the job ended, once it has. -/
  outcome : IO.Promise (Outcome (EditorM Unit))

namespace Handle

/-- Whether the job has been cancelled. -/
def cancelled (handle : Handle) : BaseIO Bool :=
  return (← handle.flags.get).cancelled

/-- Withdraws the wait `id`: tells the clock to drop it, and ends it as
`cancelled` in the table. Whichever of this and the service's completion
comes first wins, and the other does nothing. -/
def withdraw (handle : Handle) (id : UInt64) : BaseIO Unit := do
  handle.services.timers.cancel id
  handle.services.completions.finish id .cancelled

/-- Cancels the job: sets its token, and withdraws the wait it is in, if it
is in one, which ends the job there. -/
def cancel (handle : Handle) : BaseIO Unit := do
  let waiting ←
    handle.flags.modifyGet fun flags => (flags.waiting, { cancelled := true, waiting := none })
  if let some id := waiting then
    handle.withdraw id

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
  /-- The reply, once the wait `id`, whose promise is `wait`, has ended:
  `reply` fetches it then. It is run on the job's thread, once, and only for
  a wait the service completed in a job that is not cancelled; a wait with
  nothing to fetch, a timer's, answers `pure ()`. -/
  | later (id : UInt64) (wait : IO.Promise Completion) (reply : BaseIO α)

/-- Answers a request. A request that waits is registered in the table of
waits and handed to its service, and nothing here waits for it. -/
def answer (services : Services) : (request : JobRequest) → BaseIO (Answer request.Reply)
  | .now => return .now (← services.timers.now)
  | .waitUntil deadline => do
    let (id, wait) ← services.completions.register
    services.timers.start id deadline
    return .later id wait (pure ())

/-- Runs `program` to its end, a request at a time. A request that is
answered at once is a direct call, and the loop goes on on the same thread.
At a request that waits the loop ends, and the rest of the job is chained on
the wait's promise: it runs on a pool task when the wait has ended, and until
then the job holds no thread.

The job's token is looked at before each request, when each reply arrives,
and when the program ends. A cancelled job ends there as `cancelled`: `next`
is not applied again, so nothing of the job runs after it, a `catch` handler
included. -/
partial def drive (handle : Handle) (finished : BaseIO Unit) :
    Program jobPort (Except String (EditorM Unit)) → BaseIO Unit
  | .done result => do
    if ← handle.cancelled then
      return ← handle.conclude finished .cancelled
    match result with
    | .ok command =>
      handle.conclude finished (.finished command)
    | .error message =>
      handle.conclude finished (.failed message)
  | .step request next => do
    if ← handle.cancelled then
      return ← handle.conclude finished .cancelled
    match ← answer handle.services request with
    | .now reply =>
      if ← handle.cancelled then
        return ← handle.conclude finished .cancelled
      drive handle finished (next reply)
    | .later id wait reply =>
      -- The job is in the wait from here, unless it was cancelled while the
      -- wait was being made: then nobody else will withdraw it.
      let entered ←
        handle.flags.modifyGet fun flags =>
            if flags.cancelled then (false, flags) else (true, { flags with waiting := some id })
      unless entered do
        handle.withdraw id
      BaseIO.chainTask wait.result? fun completion => do
          let cancelled ←
            handle.flags.modifyGet fun flags => (flags.cancelled, { flags with waiting := none })
          -- A wait the service completed just as the job was cancelled reads
          -- as completed: the token still says the job is over.
          if completion == some .completed && !cancelled then
            drive handle finished (next (← reply))
          else
            handle.conclude finished .cancelled

/-- The body of a job's task: applies `work`, then runs the program it gives.

It is a function of its own, never inlined, so that `work ()` is evaluated
when the task runs it and not where the task is made. Written in place, as
`BaseIO.asTask do drive … (work ()).run`, the application is an argument of
the action handed to `asTask`, and Lean evaluates it on the thread that
calls `spawn`, before the task exists. -/
@[noinline]
def start (handle : Handle) (finished : BaseIO Unit) (work : Work) : BaseIO Unit :=
  drive handle finished (work ()).run

/-- Starts `work` on the pool and returns at once: none of the job runs on
the calling thread, its leading pure work included. `finished` is called once
the job has ended and its outcome is in the handle. -/
def spawn (services : Services) (work : Work) (finished : BaseIO Unit) : BaseIO Handle := do
  let handle : Handle := { services, flags := ← IO.mkRef {}, outcome := ← IO.Promise.new }
  discard <| BaseIO.asTask (start handle finished work)
  return handle

end Editor.Job
