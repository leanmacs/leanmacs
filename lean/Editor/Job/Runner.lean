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
  tells the clock, the file service and the process service to withdraw
  that wait and ends it in the table as `cancelled`. A promise resolves once, so whichever of the service and the
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

- **What a cancelled job loaded is released**, like everything else it
  holds ("What a job holds", below).
- **A cancelled job's child is killed.** A job in a process wait is
  withdrawn like any other, and withdrawing tells the process service,
  whose real implementation cancels the run in the library: `Handle.cancel`
  → `Handle.withdraw` → `Processes.cancel` → `Ffi.processesCancel` → the
  library's service, which kills the child's process group and reaps the
  child. `Jobs.removeOwner` and `Jobs.cancelAll` cancel through
  `Handle.cancel`, so they reach it the same way.
- **A streaming child does not outlive its job.** The child a start names
  is the job's (`Handle.children`), and `Handle.conclude` ends every one the
  job still holds, through `Processes.cancel`, for every outcome, finished
  included: a job's command has no request that could use one. A job
  cancelled in a read or a write has that wait withdrawn first, then its
  children ended. A child is named by the id of its start's wait, so a job
  cancelled while its start is in flight has the start withdrawn, and the
  library kills the child as it registers it.

## The ports its waits are made of

`Timers` is the clock port: read the clock, start a wait with an id and a
deadline, withdraw a wait. It has a fake a test moves by hand
(`Editor/Job/Fake.lean`) and a real implementation over the Rust library's
timer service (`Editor/Job/Real.lean`).

`Files` is the file port, beside it: start a file request
(`Editor/File.lean`) as a wait, take the request's reply once the wait has
completed, withdraw a wait, and release a snapshot a load's reply named. It
has a fake over the pure model of files (`FakeFiles`,
`Editor/Job/Fake.lean`) and a real implementation over the library's file
service (`Editor/Job/Real.lean`). A file wait is a wait like a timer's: it
holds no thread, and cancelling the job withdraws it from both services,
each of which is safe for an id it does not know.

`Processes` is the process port, beside them: start a process request
(`Editor/Process.lean`) as a wait, take its reply once the wait has
completed, and withdraw a wait, which kills the run's child. It has a fake
over the pure model of processes (`FakeProcesses`, `Editor/Job/Fake.lean`)
and a real implementation over the library's process service
(`Editor/Job/Real.lean`).

`Services` is what a runner is given: the table, the clock, the files and
the processes. A runner that is given no file service has `Files.absent`,
and one that is given no process service has `Processes.absent`, each of
which refuses every request as failed, at once: an error as a value, and
the job goes on.

## What a job holds

A load's reply names a snapshot the file service holds for the job, by a
`JobSnapshotId`. The job's handle lists them (`Handle.holding`): when a
load's reply is fetched and is a snapshot, its id is added, on the job's
thread.

- **A snapshot is named for the job that loaded it.** A save whose source
  is a job's snapshot is looked for in that job's list first, and is
  answered `noSuchSnapshot` at once, with nothing started, if the job does
  not hold it. So a job cannot save what another job holds, though the ids
  are plain numbers.
- **`Handle.settle` releases everything a job holds**, through
  `Files.release`, and leaves it holding nothing. It is safe to call again.
- **A streaming child is named for the job that started it**, the same
  way (`Handle.children`): a read, a write or a close of a child the job
  does not hold is answered `noSuchProcess` at once, with nothing started.
  A read whose delivery is the last forgets the child, as the library's
  service does.
- **Who settles.** The runner, on the job's own thread, when the job ends
  failed or cancelled, after its last request. For a job that finished,
  whoever runs its command, after the command, so that the command can
  take what the job held into the text store first
  (`Editor/Headless.lean`); and `Jobs.removeOwner` and `Jobs.cancelAll`
  (`Editor/Job/Jobs.lean`), for a finished job whose command will never
  run. Every way a job can end is followed by one of them, and the job's
  last addition to its list comes before it.
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

/-- The file port: what the runner's file waits are made of. -/
structure Files where
  /-- Asks for `request` to be worked as the wait `id`, and for the wait to
  be completed when it has been. It returns at once and never blocks. -/
  start : (id : UInt64) → (request : FileRequest) → BaseIO Unit
  /-- The reply to `request`, which was started as the wait `id` and has
  completed. It is asked once, on the job's thread. A load's reply names the
  snapshot the service then holds for the job. -/
  take : (id : UInt64) → (request : FileRequest) → BaseIO request.Reply
  /-- Withdraws the wait `id`: the service will not complete it, and keeps
  nothing of it. Safe for any id, a timer's included. -/
  cancel : (id : UInt64) → BaseIO Unit
  /-- Gives up the snapshot `snapshot`, which a load's reply named: the
  service holds it no longer. Safe for any id. -/
  release : (snapshot : JobSnapshotId) → BaseIO Unit

/-- The reply of a file service that is not there: every request is refused
as failed. -/
def Files.absentReply : (request : FileRequest) → request.Reply
  | .load .. => .error (.failed "this runner has no file service")
  | .save .. => .error (.failed "this runner has no file service")

/-- No file service: every request completes at once, refused as failed,
through the table `completions`. It is what a runner has when it was given
none, so a job that asks for a file there gets an error as a value and goes
on. -/
def Files.absent (completions : Completions) : Files where
  start id _ := completions.finish id .completed
  take _ request := pure (Files.absentReply request)
  cancel _ := pure ()
  release _ := pure ()

/-- The process port: what the runner's process waits are made of. -/
structure Processes where
  /-- Asks for `request` to be worked as the wait `id`, and for the wait to
  be completed when it has been. It returns at once and never blocks. -/
  start : (id : UInt64) → (request : ProcessRequest) → BaseIO Unit
  /-- The reply to `request`, which was started as the wait `id` and has
  completed. It is asked once, on the job's thread. -/
  take : (id : UInt64) → (request : ProcessRequest) → BaseIO request.Reply
  /-- Withdraws the wait `id`: the service will not complete it, keeps
  nothing of it, and kills the run's child with its process group if it is
  running. Safe for any id, a timer's included. -/
  cancel : (id : UInt64) → BaseIO Unit

/-- The reply of a process service that is not there: every request is
refused as failed. -/
def Processes.absentReply (request : ProcessRequest) : request.Reply :=
  request.refused (.failed "this runner has no process service")

/-- No process service: every request completes at once, refused as failed,
through the table `completions`. It is what a runner has when it was given
none, so a job that runs a program there gets an error as a value and goes
on. -/
def Processes.absent (completions : Completions) : Processes where
  start id _ := completions.finish id .completed
  take _ request := pure (Processes.absentReply request)
  cancel _ := pure ()

/-- What a runner is given. -/
structure Services where
  /-- The waits in flight. -/
  completions : Completions
  /-- The clock. -/
  timers : Timers
  /-- The files. A runner that is given none has `Files.absent`. -/
  files : Files := Files.absent completions
  /-- The processes. A runner that is given none has `Processes.absent`. -/
  processes : Processes := Processes.absent completions

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
  /-- The snapshots the job holds: the ones its loads made, oldest first.
  Every change to it is one atomic step. -/
  held : IO.Ref (Array JobSnapshotId)
  /-- The streaming children the job started and still holds, oldest first.
  Every change to it is one atomic step. -/
  children : IO.Ref (Array Process.Id)

namespace Handle

/-- Whether the job has been cancelled. -/
def cancelled (handle : Handle) : BaseIO Bool :=
  return (← handle.flags.get).cancelled

/-- The snapshots the job holds now: the ones its loads made and nothing has
released, oldest first. -/
def holding (handle : Handle) : BaseIO (Array JobSnapshotId) :=
  handle.held.get

/-- Releases everything the job holds, and leaves it holding nothing. It is
safe to call again: a second call finds nothing to release. -/
def settle (handle : Handle) : BaseIO Unit := do
  let held ← handle.held.modifyGet fun held => (held, #[])
  for snapshot in held do
    handle.services.files.release snapshot

/-- Withdraws the wait `id`: tells the clock, the file service and the
process service to drop it, each of which is safe for an id it does not
know, and ends it as `cancelled` in the table. The process service kills
the child of a run it drops. Whichever of this and the service's completion
comes first wins, and the other does nothing. -/
def withdraw (handle : Handle) (id : UInt64) : BaseIO Unit := do
  handle.services.timers.cancel id
  handle.services.files.cancel id
  handle.services.processes.cancel id
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

/-- Ends every streaming child the job still holds, through the process
service's cancel, which kills the child's group, and leaves it holding none.
Safe to call again. -/
def endChildren (handle : Handle) : BaseIO Unit := do
  let children ← handle.children.modifyGet fun children => (children, #[])
  for child in children do
    handle.services.processes.cancel child.number.toUInt64

/-- Leaves `outcome` in the handle, then calls `finished`: the job has ended.

Every streaming child the job still holds is ended first, however the job
ended: a job's command has no request that could use one.

A job that failed or was cancelled has no command to take what it holds, so
what it holds is released here first, on the job's own thread, after its
last request. A job that finished keeps what it holds for its command:
whoever runs that command settles the job after it. -/
def conclude (handle : Handle) (finished : BaseIO Unit) (outcome : Outcome (EditorM Unit)) :
    BaseIO Unit := do
  handle.endChildren
  match outcome with
  | .finished _ =>
    pure ()
  | .failed _ | .cancelled =>
    handle.settle
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

/-- Answers a request of the job behind `handle`. A request that waits is
registered in the table of waits and handed to its service, and nothing here
waits for it. -/
def answer (handle : Handle) : (request : JobRequest) → BaseIO (Answer request.Reply)
  | .now => return .now (← handle.services.timers.now)
  | .waitUntil deadline => do
    let (id, wait) ← handle.services.completions.register
    handle.services.timers.start id deadline
    return .later id wait (pure ())
  | .file (.load path limit) => do
    let (id, wait) ← handle.services.completions.register
    handle.services.files.start id (.load path limit)
    return .later id wait do
        let reply ← handle.services.files.take id (.load path limit)
        -- What the load made is the job's from here: the runner releases it.
        if let .ok file := reply then
          handle.held.modify (·.push file.snapshot)
        return reply
  | .file (.save source path expect) => do
    -- A snapshot a job holds is named for that job and for no other.
    if let .held snapshot := source then
      unless (← handle.held.get).contains snapshot do
        return .now (.error .noSuchSnapshot)
    let (id, wait) ← handle.services.completions.register
    handle.services.files.start id (.save source path expect)
    return .later id wait (handle.services.files.take id (.save source path expect))
  | .process (.start command streaming) => do
    let (id, wait) ← handle.services.completions.register
    handle.services.processes.start id (.start command streaming)
    return .later id wait do
        let reply ← handle.services.processes.take id (.start command streaming)
        -- The child is the job's from here: the runner ends it with the job.
        if let .ok child := reply then
          handle.children.modify (·.push child)
        return reply
  | .process (.read child) => do
    -- A child is named for the job that started it, and for no other.
    unless (← handle.children.get).contains child do
      return .now (.error .noSuchProcess)
    let (id, wait) ← handle.services.completions.register
    handle.services.processes.start id (.read child)
    return .later id wait do
        let reply ← handle.services.processes.take id (.read child)
        -- After its last delivery the service forgets the child.
        if let .ok { ended := some _, .. } := reply then
          handle.children.modify (·.filter (· != child))
        return reply
  | .process (.write child bytes) => do
    unless (← handle.children.get).contains child do
      return .now (.error .noSuchProcess)
    let (id, wait) ← handle.services.completions.register
    handle.services.processes.start id (.write child bytes)
    return .later id wait (handle.services.processes.take id (.write child bytes))
  | .process (.closeInput child) => do
    unless (← handle.children.get).contains child do
      return .now (.error .noSuchProcess)
    let (id, wait) ← handle.services.completions.register
    handle.services.processes.start id (.closeInput child)
    return .later id wait (handle.services.processes.take id (.closeInput child))
  | .process (.run command limit) => do
    let (id, wait) ← handle.services.completions.register
    handle.services.processes.start id (.run command limit)
    return .later id wait (handle.services.processes.take id (.run command limit))
  | .fileWatch request =>
    return .now (request.refused (.failed "this runner has no file-watch service"))

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
    match ← answer handle request with
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
            -- The reply is never fetched. Whoever cancelled the job withdrew
            -- the wait, so its service keeps nothing for it.
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
  let handle : Handle :=
    { services, flags := ← IO.mkRef {}, outcome := ← IO.Promise.new, held := ← IO.mkRef #[]
      children := ← IO.mkRef #[] }
  discard <| BaseIO.asTask (start handle finished work)
  return handle

end Editor.Job
