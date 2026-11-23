import Editor.Bound
import Editor.Job
import Editor.Job.Activity
import Editor.Job.Protocol
import Std.Data.HashMap
import Std.Sync.Mutex

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

What the table holds for a wait is the action that ends it, not the promise
itself: `register` gives a wait whose action resolves its promise, and
`registerWith` one whose action is the caller's. `finish` removes the wait
in one atomic step and runs its action outside it, once, on the thread that
finishes it, whether or not anything still holds the promise or a task of
it. That matters because a mapped task that is still waiting when its last
reference goes is deactivated and never runs, so work that must happen when
a wait ends, such as taking a request's reply from a service that keeps it
until it is taken, cannot hang off a task a caller may drop; it goes in the
wait's action (`Services.fileWorked`).

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

- **The token** is in the job's handle (`Handle.job`, a `Token`): the job's
  state in the protocol, whether it is cancelled and the wait it has
  recorded among it. It changes only inside a critical section of the table
  of waits, under the table's lock, with the transition recorded ("The
  protocol", below); it is read anywhere.
- **Every wait races it.** `Handle.cancel` sets the token and takes the
  wait it recorded, in one section, then tells the services to withdraw
  that wait and ends it in the table as `cancelled`. A promise resolves
  once, so whichever of the service and the cancel comes first wins and the
  other does nothing. A wait the job was still making when it was cancelled
  is recorded nowhere: the job withdraws it itself, in the section of its
  `park` or `serve`, which takes it out of the table, and then tells the
  services to drop it. It does so even when the service completed the wait
  before the job recorded it: the service keeps a completed request's reply
  until it is taken or dropped, and a cancelled job never takes it.
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
  library kills the child as it registers it; one cancelled after the
  service completed its start, before it recorded it, drops the start at its
  `serve`, and the library kills the child it registered.

## Activity

The runner keeps the host's activity count (`Services.activity`,
`Editor/Job/Activity.lean`), which a host's idle is made of
(`docs/design/concurrency.md`, "The idle signal"): a job holds one unit
while it can run, and none while it is in a wait only a test ends.

- **`spawn`** takes the job's unit before its task exists, in its `start`
  section, and the `finished` it hands the job gives it back last, in the
  `done` section after the job's own `finished` has run: a wake-up that
  posts is posted under the unit.
- **A wait that parks** is one on a port that says its waits end only when a
  test acts (`Timers.outside`, `FileWatches.outside`: the fake clock's sleep,
  the fake watches' `next`). The job gives its unit back in the section
  that records the wait as its own (its `park`, `Handle.enter`), and the
  wait's end takes one back in the section that ends it (its `wake`, in
  `Completions.finish`), on the thread that ends it, the clock's `advance`
  or a withdrawal, before the job's continuation can run. So at idle every
  parked job is in a wait a cancel withdraws (`Handle.cancel`). A wait that
  ended before the job recorded it, a sleep already due, takes nothing,
  and the job keeps its own unit; so does a job cancelled on its way in,
  which withdraws the wait in its `park` and holds its unit until it has
  ended.
- **Any other wait** keeps the job's unit: a timer of the library, a real
  file, process, diff, grep or watch request, a fake one a test holds on
  purpose. The job is not idle while it waits on something that ends by
  itself.
- **A handle** (`Services.fileWorked`) holds a unit from its start until its
  `noted` has run and its task has ended. A flush (`Services.flushed`)
  holds none: it is its observer's, not the program's.

A runner given no count has `Activity.untracked`, whose steps do nothing.
`ModelTest.activityRunnerChecks` pin the accounting on the fake clock and
the fake files; the handle's contract (`Editor/Job/HandleContract.lean`,
`handleCounts` and `jobLoadCounts`) pins a handle's and a job's load on the
fake file service and on the library's.

## The protocol

How the runner moves jobs through their waits is a pure transition system
(`Editor/Job/Protocol.lean`), whose invariants are proved
(`Editor/Job/Protocol/Theorems.lean`). The runner applies it one transition
per critical section:

- **One lock.** The table of waits is behind a mutex (`Completions`, whose
  constructor and state are private), and every access to it goes through
  the one private section helper, `Completions.critical`: registering and
  ending a wait, job or not, counting the waits, and each job transition.
- **One section per transition.** A job's `start` (`spawn`), `ask`
  (`Handle.ask`, which also registers the wait), `park` or `serve`
  (`Handle.enter`, which also takes out a wait the job withdraws), `wake`
  (`Completions.finish`, which also removes the wait), `resume`
  (`Handle.resume`), `cancel` (`Handle.cancel`) and `done`
  (`Handle.retire`) each is one section, and so is the loop's end
  (`Services.endLoop`). In it the runner decides the step with the
  model's own per-job step (`Protocol.JobState.step`), writes the token,
  moves the job's unit and records the transition (`Recorder.record`),
  all before it lets the lock go; `Recorder.applied` is told after. So the
  order of the records is the order the transitions took effect, and a
  split step, a unit given back before the wait is recorded, cannot be
  written: the token is written only by `Section.transition`, which runs
  only inside a section.
- **The loop's end waits for every cancelled job.** The table keeps the
  jobs cancelled and not yet done (`Pending.unsettled`): a job's `cancel`
  section adds it unless it is done, its `done` section takes it out. A
  host's loop's end hands a task for each to its wait (`Services.unsettled`,
  `Running.wind`), owner-removed and keyed-cancel ones included, which have
  left the host's table of jobs, and then ends the loop in a section that
  decides it with the model's own step over them (`Services.endLoop`,
  `Protocol.State.step`): `loopEnd` is applied and recorded only once every
  cancelled job is done, so a loop's end the model refuses is never
  recorded. A test stage waits for each under its hang guard, so a job that
  never ends is reported as a hang there; the editor waits for none, and
  its loop's end may then record nothing, which its recorder would not keep
  anyway.
- **Nothing else in a section.** A section calls no port, no other section
  and no promise but the activity's own waiter, whose consumers are all
  waits; the services' `start` and `cancel` and the end of a wait come
  after it, on the same thread.
- **The recording port** (`Recorder`) is `Recorder.none` in a host, which
  records nothing; a check gives the runner the fake (`FakeRecorder`,
  `Editor/Job/Fake.lean`) and replays its trace on the model
  (`Protocol.replay`; `Editor/Job/ProtocolContract.lean`).

## Posting a command

A job's post (`JobRequest.post`) is answered at once, as an environment
request is, and registers no wait: the runner hands the invocation to the
job's `posted` (`spawn`), on the job's thread, and goes on. A job's posts
are handed over in the order it made them, all before its outcome is in its
handle and `finished` is called. A cancelled job posts nothing: the token is
looked at before the post is handed over, as it is before every request.
Whoever spawned the job runs each post as a command on the editor thread,
and drops a post of a job it has removed (`Editor/Job/Jobs.lean`,
`Editor/Headless.lean`).

## A watch does not outlive its job

A watch a start names is the job's (`Handle.watches`), as a streaming child
is: a `next` of a watch the job does not hold is answered `noSuchWatch` at
once, with nothing started, so a job cannot read another's watch though the
ids are plain numbers. `Handle.conclude` ends every watch the job still
holds, through `FileWatches.cancel`, for every outcome, finished included.
A job cancelled in a `next` has that wait withdrawn first, then its watches
ended; one cancelled while its start is in flight has the start withdrawn,
and the library drops the registration when it returns. So
`Jobs.removeOwner .config` → `Handle.cancel` → `conclude` → `endWatches` →
`FileWatches.cancel` → the library drops the registration: a config reload,
which cancels config's jobs, replaces config's watches and never piles them
up, with no code of its own.

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

`FileWatches` is the file-watch port, beside them: start a watch request
(`Editor/FileWatch.lean`) as a wait, take its reply once the wait has
completed, and withdraw a wait or end a watch. It has a fake over the pure
model of watches (`FakeFileWatches`, `Editor/Job/Fake.lean`) and a real
implementation over the library's watch service (`Editor/Job/Real.lean`).

`Diffs` is the diff port, beside them: start a diff request
(`Editor/Diff.lean`) as a wait, take its reply once the wait has completed,
and withdraw a wait. A diff names its sources as a save does, so one that
names a snapshot the job does not hold is answered `noSuchSnapshot` at once,
with nothing started. It has a fake over the pure model of files
(`FakeFiles.diffs`, `Editor/Job/Fake.lean`) and a real implementation over
the library's diff service (`Editor/Job/Real.lean`). A runner that is given
none has `Diffs.absent`.

`Greps` is the grep port, beside them: start a search request
(`Editor/Grep.lean`) as a wait, take its reply once the wait has completed,
and withdraw a wait or cancel a search. A start whose overlay names a
snapshot the job does not hold is answered `noSuchSnapshot` at once, as a
diff's is, and a `next` of a search the job does not hold `noSuchSearch`. A
search does not outlive its job: `Handle.conclude` cancels every search the
job still holds (`Handle.endGreps`). It has a fake over the pure model of
project search (`FakeFiles.greps`, `Editor/Job/Fake.lean`) and a real
implementation over the library's grep service (`Editor/Job/Real.lean`). A
runner that is given none has `Greps.absent`.

Each of `Timers`, `Files`, `Processes`, `FileWatches` and `Diffs` has a
`flush`, a field with no default, so a port that forgot it does not
silently never complete: it asks for a wait to be completed once the
service has finished the work handed to it before that it can finish on its
own, returns at once, and keeps no reply. Its `absent` completes it at once.
A host or a test flushes a service through `Services.flushed`, which takes
the service as data (`Service`), registers the wait and returns its task;
since a service queues a flush's completion behind those of the work it
covers, and the pump finishes waits in queue order, the covered waits have
ended once that task has. `awaitWithin` is the one hang-guarded wait of a
task: its value, or `none` past a patience, which is a hang and never a
result. The flush contract is `Editor/Job/FlushContract.lean`.

A caller that is not a job hands one file request to the port through
`Services.fileWorked`, which returns the task of its reply: a handle. The
wait is registered with an action (`registerWith`) that takes the reply
through the port when the wait ends and then resolves the task, so a caller
that drops the task leaves the service keeping nothing. A handle is for one
request's reply; a flush is for everything handed before. The handle's
contract is `Editor/Job/HandleContract.lean`.

`Environments` is the port of the environments a host's jobs share, which
answers at once and registers no wait (`Environments.inherited`, the
default, and `sharedEnvironments`, state behind a reference).

The fuzzy matcher is a `FuzzyHandler` (`Editor/Fuzzy.lean`), which answers
at once and registers no wait. It is `IO`, and may throw: the runner
catches what it throws and answers the job `.error`, `fuzzy: ` and the
message, since an answer cannot throw.

`Services` is what a runner is given: the table, the clock, the files, the
processes, the file watches, the diffs, the environments and the matcher. A runner that is given no file service has `Files.absent`,
and one that is given no process service has `Processes.absent`, each of
which refuses every request as failed, at once: an error as a value, and
the job goes on; one that is given no watch service has
`FileWatches.absent`, which does the same. One that is given no matcher
has `Fuzzy.absent`, which throws, so a fuzzy request there is answered an
error, and never a model's order as if it were a library's.

A snapshot read is answered by `snapshots`, a function from a snapshot's id
to its text, at once and with no wait. One that is given none answers
`none` for every id; a host's real one reads the published table
(`realSnapshots`, `Editor/Job/Real.lean`).

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

/-- The recording port: what the runner tells of each protocol transition
it applies (`Editor/Job/Protocol.lean`). `record` is called inside the
critical section that applies the transition, so the order of the records is
the order the transitions took effect; `applied` is called once that section
has let its lock go, on the same thread. Neither may call the runner, which
`record` would deadlock, and `record` may not block on anything but what a
check holds on purpose. The real one is `Recorder.none`; the fake, which
keeps the trace and holds a thread at a transition a check names, is
`FakeRecorder` (`Editor/Job/Fake.lean`). -/
structure Recorder where
  /-- Records a transition, inside the section that applies it. -/
  record : Protocol.Transition → BaseIO Unit
  /-- Tells that a transition has been applied, once its section is over. -/
  applied : Protocol.Transition → BaseIO Unit
  /-- Whether anything is recorded: `false` only for `Recorder.none`, whose
  sections then call neither. -/
  on : Bool := true

/-- No recording: what a runner has when it is given no recorder, a host's
real one among them. A section then pays one branch on this field. -/
def Recorder.none : Recorder where
  record _ := pure ()
  applied _ := pure ()
  on := false

/-- A job's token: its state in the protocol (`Protocol.JobState`): whether
it is cancelled, and the wait it has recorded, with where it is. Its
constructor is private, so only this module makes one, and only inside a
section (`Section.transition`) is one written. -/
structure Token where private mk ::
  /-- The job's state in the protocol. -/
  state : Protocol.JobState

/-- A job as the runner's sections reach it: its number in the table, its
token, and the count and the recorder its steps move and tell. -/
structure JobRef where
  /-- The job's number, given by the table in the order of spawns. -/
  number : Nat
  /-- The job's token. Read anywhere; written only inside a section. -/
  token : IO.Ref Token
  /-- The host's activity count, whose unit the job's steps move. -/
  activity : Activity
  /-- What the job's steps are told to. -/
  recorder : Recorder

/-- What the table holds for a wait. -/
structure Waiting where
  /-- What ends the wait: run once, outside the section that ends it. -/
  ended : Completion → BaseIO Unit
  /-- The job whose wait it is, for a job's wait: its end is that job's
  `wake`. -/
  job? : Option JobRef := none

/-- What the table of waits holds. -/
structure Pending where
  /-- The id of the next wait. -/
  next : UInt64 := 1
  /-- The number of the next job spawned on the table. -/
  nextJob : Nat := 0
  /-- Each wait that has not ended. -/
  waits : Std.HashMap UInt64 Waiting := {}
  /-- Each job cancelled and not yet done, by its number, with the promise
  of the runner's last step for it (`Handle.finishedRan`): what the loop's
  end waits for (`Services.unsettled`) and decides its end over
  (`Services.endLoop`). A job's `cancel` section adds it unless it is done,
  and its `done` section takes it out. -/
  unsettled : Std.HashMap Nat (JobRef × IO.Promise Unit) := {}

/-- The table of waits in flight, shared by the runner and whatever completes
its waits. It is behind a lock, and every access to it is one critical
section (`Completions.critical`), job or not. -/
structure Completions where private mk ::
  /-- The table, behind its lock. -/
  private state : Std.Mutex Pending

/-- What a section has applied, each transition with the recorder to tell
once the section has let its lock go. -/
private abbrev Section :=
  StateT (Array (Recorder × Protocol.Transition)) BaseIO

/-- Records `transition` with `recorder`, inside the section, and has it told
as applied once the section is over. -/
private def Section.note (recorder : Recorder) (transition : Protocol.Transition) : Section Unit :=
  do
  if recorder.on then
    recorder.record transition
    modify (·.push (recorder, transition))

/-- Moves `activity` as the protocol's move says. -/
private def Section.move (activity : Activity) : Protocol.Move → Section Unit
  | .keep => pure ()
  | .take => activity.begin
  | .give => activity.done

/-- Applies `transition` to `job`, inside a section: decides it with the
model's own step (`Protocol.JobState.step`), writes the token, moves the
job's unit and records the transition, in that one section. The job's state
before and after, or `none` where the model refuses the step, which the
runner never takes by construction: then nothing changes, the transition is
recorded all the same, so a replay names it, and the caller takes the
cancelled path. -/
private def Section.transition (job : JobRef) (transition : Protocol.Transition) :
    Section (Option (Protocol.JobState × Protocol.JobState)) := do
  let before := (← job.token.get).state
  match before.step transition with
  | some (after, move) =>
    job.token.set ⟨after⟩
    Section.move job.activity move
    Section.note job.recorder transition
    return some (before, after)
  | none =>
    Section.note job.recorder transition
    return none

namespace Completions

/-- A table with no waits. -/
def new : BaseIO Completions :=
  return ⟨← Std.Mutex.new {}⟩

/-- The one critical section: runs `body` on the table under its lock, and
leaves what it gives back; then, with the lock let go, tells each recorder
of each transition the body applied. Every access to the table is one, and
every token is written inside one (`Section.transition`). A body calls no
port, no other section and no promise but the activity's own waiter, whose
consumers are all waits; port calls and the ends of waits come after it. -/
private def critical {α : Type} (completions : Completions)
    (body : Pending → Section (α × Pending)) : BaseIO α := do
  let (result, applied) ←
    completions.state.atomically do
        let pending ← get
        let ((result, pending), applied) ← liftM ((body pending).run #[])
        set pending
        return (result, applied)
  for (recorder, transition) in applied do
    recorder.applied transition
  return result

/-- Whether a section holds the table's lock now, read without waiting for
it: for a check that a transition is recorded inside the section that
applies it (`Editor/Job/ProtocolContract.lean`). -/
def busy (completions : Completions) : BaseIO Bool :=
  return (← completions.state.tryAtomically (pure ())).isNone

/-- Registers a wait that ends by running `ended id completion`, once, on the
thread that ends it (`finish`), whether or not anything still waits on it:
the table holds the action, so it outlives whatever the action resolves.
Returns the wait's id. -/
def registerWith (completions : Completions) (ended : UInt64 → Completion → BaseIO Unit) :
    BaseIO UInt64 :=
  completions.critical fun pending =>
    pure
      (pending.next,
        { pending with
          next := pending.next + 1
          waits := pending.waits.insert pending.next { ended := ended pending.next } })

/-- Registers a wait: its id, and the promise that ends it, which `finish`
resolves (`registerWith` over the promise). -/
def register (completions : Completions) : BaseIO (UInt64 × IO.Promise Completion) := do
  let wait ← IO.Promise.new
  let id ← completions.registerWith fun _ completion => wait.resolve completion
  return (id, wait)

/-- Ends the wait `id` as `completion`, and forgets it: removes it in one
section, which for a job's wait is also the job's `wake`, then runs its
action outside that section, on this thread. Does nothing if `id` is not
waiting: it never was, or it has ended already. -/
def finish (completions : Completions) (id : UInt64) (completion : Completion) : BaseIO Unit := do
  let ended? ←
    completions.critical fun pending => do
        match pending.waits[id]? with
        | none =>
          return (none, pending)
        | some waiting =>
          if let some job := waiting.job? then
            discard <| Section.transition job (.wake id.toNat completion)
          return (some waiting.ended, { pending with waits := pending.waits.erase id })
  if let some ended := ended? then
    ended completion

/-- How many waits are in flight. -/
def waiting (completions : Completions) : BaseIO Nat :=
  completions.critical fun pending => pure (pending.waits.size, pending)

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
  /-- Asks for the wait `id` to be completed once every wait due when this is
  called has been completed. A wait not yet due is not waited for. It
  returns at once and never blocks. -/
  flush : (id : UInt64) → BaseIO Unit
  /-- Whether a wait on this clock ends only when a test acts: the fake
  clock's, which only `advance` moves. A job in such a wait holds no unit of
  the host's activity ("Activity", in the module docs). A real clock's wait
  ends by itself, so it is `false`, the default. -/
  outside : Bool := false

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
  /-- Asks for the wait `id` to be completed once every file request handed
  to the service before this call, unobserved writes included, has been
  worked. It returns at once and never blocks, and keeps no reply. -/
  flush : (id : UInt64) → BaseIO Unit

/-- The reply of a file service that is not there: every request is refused
as failed. -/
def Files.absentReply : (request : FileRequest) → request.Reply
  | .load .. => .error (.failed "this runner has no file service")
  | .save .. => .error (.failed "this runner has no file service")
  | .stamp .. => .error (.failed "this runner has no file service")
  | .list .. => .error (.failed "this runner has no file service")
  | .makeDirectory .. => .error (.failed "this runner has no file service")
  | .append .. => .error (.failed "this runner has no file service")
  | .remove .. => .error (.failed "this runner has no file service")

/-- The reply of a file request handed through the services
(`Services.fileWorked`) whose wait was withdrawn before the service worked
it: refused as failed. -/
def Files.withdrawnReply : (request : FileRequest) → request.Reply
  | .load .. => .error (.failed "the request was withdrawn")
  | .save .. => .error (.failed "the request was withdrawn")
  | .stamp .. => .error (.failed "the request was withdrawn")
  | .list .. => .error (.failed "the request was withdrawn")
  | .makeDirectory .. => .error (.failed "the request was withdrawn")
  | .append .. => .error (.failed "the request was withdrawn")
  | .remove .. => .error (.failed "the request was withdrawn")

/-- Every reply type has a value, so a promise of one can be made. -/
instance (request : FileRequest) : Nonempty request.Reply :=
  ⟨Files.absentReply request⟩

/-- No file service: every request completes at once, refused as failed,
through the table `completions`. It is what a runner has when it was given
none, so a job that asks for a file there gets an error as a value and goes
on. -/
def Files.absent (completions : Completions) : Files where
  start id _ := completions.finish id .completed
  take _ request := pure (Files.absentReply request)
  cancel _ := pure ()
  release _ := pure ()
  flush id := completions.finish id .completed

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
  /-- Asks for the wait `id` to be completed once every run started before
  this call has ended and every child cancelled before it has been reaped.
  A live streaming child and its pending read are not waited for. It
  returns at once and never blocks. -/
  flush : (id : UInt64) → BaseIO Unit

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
  flush id := completions.finish id .completed

/-- The file-watch port: what the runner's watch waits are made of. -/
structure FileWatches where
  /-- Asks for `request` to be worked as the wait `id`, and for the wait to
  be completed when it can be taken: a start once the watch is registered or
  refused, a `next` once a delivery is due. It returns at once and never
  blocks. -/
  start : (id : UInt64) → (request : FileWatchRequest) → BaseIO Unit
  /-- The reply to `request`, which was started as the wait `id` and has
  completed. It is asked once, on the job's thread. A `next`'s delivery
  holds every change recorded up to the take. -/
  take : (id : UInt64) → (request : FileWatchRequest) → BaseIO request.Reply
  /-- Withdraws the wait `id`, or ends the watch `id`: the service will not
  complete it and keeps nothing of it. Safe for any id, a timer's
  included. -/
  cancel : (id : UInt64) → BaseIO Unit
  /-- Asks for the wait `id` to be completed once every start asked before
  this call has returned: registered or refused. A pending `next` is not
  waited for. It returns at once and never blocks. -/
  flush : (id : UInt64) → BaseIO Unit
  /-- Whether a `next` on this service ends only when a test acts: the fake
  watches', which only a test's change answers. A job in such a wait holds
  no unit of the host's activity ("Activity", in the module docs). The real
  service's `next` ends by itself, so it is `false`, the default. -/
  outside : Bool := false

/-- No file-watch service: every request completes at once, refused as
failed, through the table `completions`. It is what a runner has when it was
given none, so a job that watches a file there gets an error as a value and
goes on. -/
def FileWatches.absent (completions : Completions) : FileWatches where
  start id _ := completions.finish id .completed
  take _ request := pure (request.refused (.failed "this runner has no file-watch service"))
  cancel _ := pure ()
  flush id := completions.finish id .completed

/-- The diff port: what the runner's diff waits are made of. -/
structure Diffs where
  /-- Asks for `request` to be worked as the wait `id`, and for the wait to
  be completed when it has been. It returns at once and never blocks. -/
  start : (id : UInt64) → (request : DiffRequest) → BaseIO Unit
  /-- The reply to `request`, which was started as the wait `id` and has
  completed. It is asked once, on the job's thread. -/
  take : (id : UInt64) → (request : DiffRequest) → BaseIO request.Reply
  /-- Withdraws the wait `id`: the service will not complete it, and keeps
  nothing of it. Safe for any id, a timer's included. -/
  cancel : (id : UInt64) → BaseIO Unit
  /-- Asks for the wait `id` to be completed once every diff started before
  this call has been worked. It returns at once and never blocks. -/
  flush : (id : UInt64) → BaseIO Unit

/-- No diff service: every request completes at once, refused as failed,
through the table `completions`. -/
def Diffs.absent (completions : Completions) : Diffs where
  start id _ := completions.finish id .completed
  take _ request := pure (request.refused (.failed "this runner has no diff service"))
  cancel _ := pure ()
  flush id := completions.finish id .completed

/-- The grep port: what the runner's search waits are made of. -/
structure Greps where
  /-- Asks for `request` to be worked as the wait `id`, and for the wait to
  be completed when it can be taken: a start once the search has its pattern
  compiled or is refused, a `next` once a delivery is there. It returns at
  once and never blocks. -/
  start : (id : UInt64) → (request : GrepRequest) → BaseIO Unit
  /-- The reply to `request`, which was started as the wait `id` and has
  completed. It is asked once, on the job's thread. -/
  take : (id : UInt64) → (request : GrepRequest) → BaseIO request.Reply
  /-- Withdraws the wait `id`, or cancels the search `id`: the service will
  not complete it, reads nothing more for it and keeps nothing of it. Safe
  for any id, a timer's included. -/
  cancel : (id : UInt64) → BaseIO Unit
  /-- Asks for the wait `id` to be completed once every search started before
  has ended, its walk over: a cancelled search's among them, which may still
  be reading when its cancel returns. It returns at once, keeps no reply,
  and a service that refuses it finishes the wait as `cancelled`. -/
  flush : (id : UInt64) → BaseIO Unit

/-- No grep service: every request completes at once, refused as failed,
through the table `completions`, and so does a flush, with no search to
wait for. -/
def Greps.absent (completions : Completions) : Greps where
  start id _ := completions.finish id .completed
  take _ request := pure (request.refused (.failed "this runner has no grep service"))
  cancel _ := pure ()
  flush id := completions.finish id .completed

/-- The environments port: what a job's environment requests are answered
by, at once (`Editor/Process/Environment.lean`). -/
structure Environments where
  /-- The answer to `request`. It never waits. -/
  ask : (request : EnvironmentRequest) → BaseIO request.Reply

/-- The environments of a runner given none: every request answered as the
default state answers it, `auto` in the headless mode, which is `inherited`,
and nothing kept. So a job's process requests start their children exactly
as their commands say. -/
def Environments.inherited : Environments where
  ask request := pure (({} : Process.Environments).handle request).1

/-- The environments over `state`, which every job given them shares: each
request is answered from it in one atomic step, and a message it says for
the echo area is handed to `report`. It is pure state behind a reference, so
it serves the real host and the runner's checks alike. -/
def sharedEnvironments (state : IO.Ref Process.Environments) (report : String → BaseIO Unit) :
    Environments
    where
  ask request := do
    let (reply, said) ←
      state.modifyGet fun held =>
          let (reply, after, said) := held.handle request
          ((reply, said), after)
    if let some text := said then
      report text
    return reply

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
  /-- The file watches. A runner that is given none has
  `FileWatches.absent`. -/
  fileWatches : FileWatches := FileWatches.absent completions
  /-- The diffs. A runner that is given none has `Diffs.absent`. -/
  diffs : Diffs := Diffs.absent completions
  /-- The searches. A runner that is given none has `Greps.absent`. -/
  greps : Greps := Greps.absent completions
  /-- The environments its jobs share. A runner that is given none has
  `Environments.inherited`. -/
  environments : Environments := Environments.inherited
  /-- The fuzzy matcher. A runner that is given none has `Fuzzy.absent`. -/
  fuzzy : FuzzyHandler := Fuzzy.absent
  /-- The text of a snapshot a command took, as the published table holds
  it now (`JobRequest.snapshot`); `none` for an id that names nothing or
  was released. A runner that is given none answers `none` for every id. -/
  snapshots : SnapshotId → BaseIO (Option String) := fun _ => pure none
  /-- The count of work that can still end by itself, for the host's idle
  (`Editor/Job/Activity.lean`; "Activity", in the module docs). A runner
  that is given none has `Activity.untracked`, which is never idle. -/
  activity : Activity := Activity.untracked
  /-- What the runner's protocol transitions are told to (`Recorder`). A
  runner that is given none has `Recorder.none`, which records nothing. -/
  recorder : Recorder := Recorder.none

/-- A task for each job cancelled and not yet done, in one section: each
ends once the runner is done with its job (`Handle.finishedRan`), after
the job's `done`. What a host's loop hands its wait for the jobs it
cancelled once it has cancelled its own (`Running.wind`,
`Editor/Headless.lean`): those of its end's cancel, and those cancelled
before it, by an owner's removal or a keyed cancel, which are no longer in
its table of jobs. A table several hosts share holds theirs too. -/
def Services.unsettled (services : Services) : BaseIO (Array (Task Unit)) := do
  let ran ←
    services.completions.critical fun pending =>
        pure (pending.unsettled.fold (init := #[]) fun ran _ (_, last) => ran.push last, pending)
  -- Each task is made after the section, which touches no promise.
  return ran.map fun last => last.result?.map (sync := true) fun _ => ()

/-- The loop's end (`Protocol.Transition.loopEnd`), in a section of its
own, decided by the model's own step over the jobs cancelled and not yet
done (`Protocol.State.step`): it is applied and recorded only once every
cancelled job is done, so a loop's end the model refuses is never recorded.
Whether it was. The table outlives one loop's end, which leaves it open, so
the step is taken from a state that has not ended. What a host's loop calls
last, once it has handed `Services.unsettled` to its wait (`Running.wind`);
a host whose wait does not wait for them, the editor's, may find one not
yet done, and then records nothing. -/
def Services.endLoop (services : Services) : BaseIO Bool :=
  services.completions.critical fun pending => do
    let mut jobs := []
    for (_, (job, _)) in pending.unsettled do
      jobs := (← job.token.get).state :: jobs
    let ends := (({ jobs } : Protocol.State).step .loopEnd).isSome
    if ends then
      Section.note services.recorder .loopEnd
    return (ends, pending)

/-- A service whose flush a host or a test can wait on
(`Services.flushed`). -/
inductive Service where
  /-- The clock. -/
  | timers
  /-- The files. -/
  | files
  /-- The processes. -/
  | processes
  /-- The file watches. -/
  | fileWatches
  /-- The diffs. -/
  | diffs
  /-- The searches. -/
  | greps
  deriving DecidableEq, Repr, Inhabited

/-- The flush of `target` among `services`. -/
def Services.flushOf (services : Services) : Service → (UInt64 → BaseIO Unit)
  | .timers => services.timers.flush
  | .files => services.files.flush
  | .processes => services.processes.flush
  | .fileWatches => services.fileWatches.flush
  | .diffs => services.diffs.flush
  | .greps => services.greps.flush

/-- Flushes `target`: registers a wait in the table, hands its id to the
service's `flush`, and returns the task that ends with the wait: `completed`
once the service has finished what was handed to it before, and `cancelled`
if the service refused the flush. Since the pump finishes waits in the order
the completion queue gives them, and a service queues a flush's completion
behind those of the work it covers, the covered waits have ended by the time
this task does. -/
def Services.flushed (services : Services) (target : Service) : BaseIO (Task Completion) := do
  let (id, wait) ← services.completions.register
  services.flushOf target id
  -- A map run on the resolving thread, so the task has ended once the wait
  -- has: `IO.hasFinished` of it says whether the flush has been completed.
  return wait.resultD .cancelled

/-- Hands `request` to the file port as a wait of its own, and returns the task
of its reply: a handle of the one request. The reply is taken through the
port when the wait ends, on the thread that ends it (the pump, a fake's
`letGo`, or the port's own `start` when it refuses the request at once), and
handed to `noted` before the task ends, whether or not the task is still
held. So a caller that does not need the reply drops the task (`discard`),
and the service keeps nothing of the request. A wait withdrawn
(`cancelled`) ends with `Files.withdrawnReply request`, and nothing is taken.

The take is the port's, as a job's is (`Files.take`): an append, a remove
and a save are decoded and taken, and a load's reply names a snapshot the
port then holds, as a job's load does, until it is released. A handle is
for one request's reply; to wait for everything handed to the service
before, flush it (`Services.flushed .files`).

The request holds a unit of the host's activity (`Services.activity`) from
its start until its reply has been handed to `noted` and the task has ended:
it is work that ends by itself ("Activity", in the module docs). -/
def Services.fileWorked (services : Services) (request : FileRequest)
    (noted : request.Reply → BaseIO Unit := fun _ => pure ()) : BaseIO (Task request.Reply) := do
  let reply ← IO.Promise.new
  -- The take hangs off the wait's action, which the table holds, and not off
  -- the task handed back: a mapped task still waiting when its last
  -- reference goes is deactivated and never runs.
  let id ←
    services.completions.registerWith fun id completion => do
        let answer ←
          match completion with
          | .completed =>
            services.files.take id request
          | .cancelled =>
            pure (Files.withdrawnReply request)
        noted answer
        reply.resolve answer
        -- The request was work that ends by itself: its unit goes once its
        -- reply has been handed over.
        services.activity.done
  services.activity.begin
  services.files.start id request
  return reply.resultD (Files.withdrawnReply request)

/-- `task`'s value, or `none` if it has not ended within `guard`. It is a
guard against a hang, never a result: a caller that gets `none` reports a
hang (`HangGuard.hang`), and does not pass or fail a property on time. It is
the one place a deadline meets a flush: the guard's own `within`
(`Editor/Bound.lean`), which races the task against the guard's expiry and
reads no clock for a task that has ended. -/
def awaitWithin {α : Type} (guard : HangGuard) (task : Task α) : IO (Option α) :=
  guard.within task

/-- `task`'s value, waited for within `guard` (`awaitWithin`). Past the
guard it throws the hang the guard says (`HangGuard.hang`), naming the event
it waited for and its bound, so a caller that cannot go on without the
value fails as a hang, in the guard's words. -/
def awaitOrHang {α : Type} (guard : HangGuard) (task : Task α) : IO α := do
  let some value ← awaitWithin guard task | throw (IO.userError guard.hang)
  return value

instance {α : Type} : Nonempty (Outcome α) :=
  ⟨.cancelled⟩

/-- A job that was spawned, as whoever spawned it holds it. -/
structure Handle where
  /-- What the job's waits are made of. -/
  services : Services
  /-- The job as the runner's sections reach it: its number and its token,
  which is written only inside a section of the table. -/
  job : JobRef
  /-- How the job ended, once it has. -/
  outcome : IO.Promise (Outcome (EditorM Unit))
  /-- Resolved once the runner is done with the job: its `finished` has
  been called and its unit of the activity given back, the last thing the
  runner does for it, after the outcome is in. Something to wait on for
  whoever must know that nothing of the job is still to come, such as the
  wake-up its `finished` posts; a host's loop drops it, a test does not. -/
  finishedRan : IO.Promise Unit
  /-- The snapshots the job holds: the ones its loads made, oldest first.
  Every change to it is one atomic step. -/
  held : IO.Ref (Array JobSnapshotId)
  /-- The streaming children the job started and still holds, oldest first.
  Every change to it is one atomic step. -/
  children : IO.Ref (Array Process.Id)
  /-- The watches the job started and still holds, oldest first. Every
  change to it is one atomic step. -/
  watches : IO.Ref (Array FileWatch.Id)
  /-- The searches the job started and still holds, oldest first. Every
  change to it is one atomic step. -/
  searches : IO.Ref (Array Grep.Id)
  /-- What the job's posts are handed to, on the job's thread: whoever
  spawned it runs each on the editor thread ("Posting a command", in the
  module docs). -/
  posted : Invocation → BaseIO Unit := fun _ => pure ()

namespace Handle

/-- Whether the job has been cancelled. -/
def cancelled (handle : Handle) : BaseIO Bool :=
  return (← handle.job.token.get).state.cancelled

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

/-- Tells the clock, the file service, the process service, the watch
service, the diff service and the grep service to drop the wait `id`, each
of which is safe for an id it does not know; the table is not told. -/
def drop (handle : Handle) (id : UInt64) : BaseIO Unit := do
  handle.services.timers.cancel id
  handle.services.files.cancel id
  handle.services.processes.cancel id
  handle.services.fileWatches.cancel id
  handle.services.diffs.cancel id
  handle.services.greps.cancel id

/-- Withdraws the wait `id`: tells the clock, the file service, the
process service and the watch service to drop it, each of which is safe for
an id it does not know, and ends it as `cancelled` in the table. The process
service kills the child of a run it drops; the watch service drops a start
in flight, and the registration it makes. Whichever of this and the
service's completion comes first wins, and the other does nothing. -/
def withdraw (handle : Handle) (id : UInt64) : BaseIO Unit := do
  handle.drop id
  handle.services.completions.finish id .cancelled

/-- Cancels the job: sets its token and takes the wait it has recorded, in
one section (the protocol's `cancel`), and then withdraws that wait, if it
had one, which ends the job there. A job that has recorded none is on its
thread, and sees the token there. -/
def cancel (handle : Handle) : BaseIO Unit := do
  let recorded ←
    handle.services.completions.critical fun pending => do
        let stepped ← Section.transition handle.job (.cancel handle.job.number)
        -- A job cancelled and not yet done is one the loop's end waits for.
        let pending :=
          match stepped with
          | some (_, after) =>
            if after.status == .done then pending
            else
              { pending with
                unsettled :=
                  pending.unsettled.insert handle.job.number (handle.job, handle.finishedRan) }
          | none => pending
        return (stepped.bind (·.1.recorded), pending)
  if let some id := recorded then
    handle.withdraw id.toUInt64

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

/-- Ends every watch the job still holds, through the watch service's
cancel, which drops its registration once no other watch shares it, and
leaves it holding none. Safe to call again. -/
def endWatches (handle : Handle) : BaseIO Unit := do
  let watches ← handle.watches.modifyGet fun watches => (watches, #[])
  for watch in watches do
    handle.services.fileWatches.cancel watch.number.toUInt64

/-- Cancels every search the job still holds, through the grep service's
cancel, which stops it reading, and leaves it holding none. Safe to call
again. -/
def endGreps (handle : Handle) : BaseIO Unit := do
  let searches ← handle.searches.modifyGet fun searches => (searches, #[])
  for search in searches do
    handle.services.greps.cancel search.number.toUInt64

/-- Leaves `outcome` in the handle, then calls `finished`: the job has ended.

Every streaming child, every watch and every search the job still holds is
ended first,
however the job ended: a job's command has no request that could use
one.

A job that failed or was cancelled has no command to take what it holds, so
what it holds is released here first, on the job's own thread, after its
last request. A job that finished keeps what it holds for its command:
whoever runs that command settles the job after it. -/
def conclude (handle : Handle) (finished : BaseIO Unit) (outcome : Outcome (EditorM Unit)) :
    BaseIO Unit := do
  handle.endChildren
  handle.endWatches
  handle.endGreps
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
  nothing to fetch, a timer's, answers `pure ()`. Whether the wait parks is
  the job's token's, which its `ask` left asking that kind of wait
  (`Handle.ask`). -/
  | later (id : UInt64) (wait : IO.Promise Completion) (reply : BaseIO α)

/-- The kind of a wait on a port that says whether its waits end only when a
test acts (`Timers.outside`, `FileWatches.outside`). -/
def Protocol.Kind.of (outside : Bool) : Protocol.Kind :=
  if outside then .parks else .service

/-- Registers a wait of the job behind `handle`, of kind `kind`, and applies
the job's `ask`, in one section: its id and its promise. The caller hands
the id to the service after the section. -/
def Handle.ask (handle : Handle) (kind : Protocol.Kind := .service) :
    BaseIO (UInt64 × IO.Promise Completion) := do
  let wait ← IO.Promise.new
  let id ←
    handle.services.completions.critical fun pending => do
        let id := pending.next
        discard <| Section.transition handle.job (.ask handle.job.number id.toNat kind)
        return (id,
            { pending with
              next := id + 1
              waits := pending.waits.insert id { ended := wait.resolve, job? := some handle.job } })
  return (id, wait)

/-- Records the wait `id` the job asked as its own, in one section: its
`park` for a wait that parks, which gives its unit back, its `serve` for any
other. `none` once the job is in the wait, or the wait has ended and the job
recorded it, for its continuation to take the reply.

A job cancelled on its way in withdraws the wait itself, since no cancel
found it recorded: `some ended?`, for the job to tell the services to drop
the wait, whether or not it has ended, and then to run `ended?`. A wait that
had not ended is removed from the table in this step, and `ended?` is the
action that ends it; one the service completed already is out of the table,
and `ended?` is `none`, but the service keeps the request's reply until it is
taken or dropped, and a cancelled job never takes it. -/
def Handle.enter (handle : Handle) (id : UInt64) :
    BaseIO (Option (Option (Completion → BaseIO Unit))) :=
  handle.services.completions.critical fun pending => do
    let transition :=
      match (← handle.job.token.get).state.status with
      | .asking _ .parks _ => Protocol.Transition.park handle.job.number
      | _ => .serve handle.job.number
    let withdraw :=
      return (some (pending.waits[id]?.map (·.ended)),
        { pending with waits := pending.waits.erase id })
    match ← Section.transition handle.job transition with
    | some (before, _) =>
      if before.cancelled then withdraw else return (none, pending)
    | none =>
      withdraw

/-- The first step of the job's continuation, once its wait has ended: its
`resume`, in one section, which leaves it running with no wait recorded.
Whether the job is cancelled. -/
def Handle.resume (handle : Handle) : BaseIO Bool :=
  handle.services.completions.critical fun pending => do
    match ← Section.transition handle.job (.resume handle.job.number) with
    | some (before, _) =>
      return (before.cancelled, pending)
    | none =>
      return (true, pending)

/-- The runner's last step for the job, once its `finished` has run: its
`done`, in one section, which gives its unit back and takes it out of the
jobs cancelled and not yet done. -/
def Handle.retire (handle : Handle) : BaseIO Unit :=
  handle.services.completions.critical fun pending => do
    discard <| Section.transition handle.job (.done handle.job.number)
    return ((), { pending with unsettled := pending.unsettled.erase handle.job.number })

/-- Answers a request of the job behind `handle`. A request that waits is
registered in the table of waits and handed to its service, and nothing here
waits for it. -/
def answer (handle : Handle) : (request : JobRequest) → BaseIO (Answer request.Reply)
  | .now => return .now (← handle.services.timers.now)
  | .waitUntil deadline => do
    let (id, wait) ← handle.ask (.of handle.services.timers.outside)
    handle.services.timers.start id deadline
    return .later id wait (pure ())
  | .file (.load path limit) => do
    let (id, wait) ← handle.ask
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
    let (id, wait) ← handle.ask
    handle.services.files.start id (.save source path expect)
    return .later id wait (handle.services.files.take id (.save source path expect))
  | .file (.stamp path) => do
    let (id, wait) ← handle.ask
    handle.services.files.start id (.stamp path)
    return .later id wait (handle.services.files.take id (.stamp path))
  | .file (.list path) => do
    let (id, wait) ← handle.ask
    handle.services.files.start id (.list path)
    return .later id wait (handle.services.files.take id (.list path))
  | .file (.makeDirectory path) => do
    let (id, wait) ← handle.ask
    handle.services.files.start id (.makeDirectory path)
    return .later id wait (handle.services.files.take id (.makeDirectory path))
  | .file (.append path bytes) => do
    let (id, wait) ← handle.ask
    handle.services.files.start id (.append path bytes)
    return .later id wait (handle.services.files.take id (.append path bytes))
  | .file (.remove path) => do
    let (id, wait) ← handle.ask
    handle.services.files.start id (.remove path)
    return .later id wait (handle.services.files.take id (.remove path))
  | .process (.start command streaming) => do
    let (id, wait) ← handle.ask
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
    let (id, wait) ← handle.ask
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
    let (id, wait) ← handle.ask
    handle.services.processes.start id (.write child bytes)
    return .later id wait (handle.services.processes.take id (.write child bytes))
  | .process (.closeInput child) => do
    unless (← handle.children.get).contains child do
      return .now (.error .noSuchProcess)
    let (id, wait) ← handle.ask
    handle.services.processes.start id (.closeInput child)
    return .later id wait (handle.services.processes.take id (.closeInput child))
  | .process (.run command limit) => do
    let (id, wait) ← handle.ask
    handle.services.processes.start id (.run command limit)
    return .later id wait (handle.services.processes.take id (.run command limit))
  | .process (.runWithin command limit time) => do
    let (id, wait) ← handle.ask
    handle.services.processes.start id (.runWithin command limit time)
    return .later id wait (handle.services.processes.take id (.runWithin command limit time))
  | .process (.runInput command input limit time) => do
    let (id, wait) ← handle.ask
    handle.services.processes.start id (.runInput command input limit time)
    return .later id wait (handle.services.processes.take id (.runInput command input limit time))
  | .process (.runHead command input limit time) => do
    let (id, wait) ← handle.ask
    handle.services.processes.start id (.runHead command input limit time)
    return .later id wait (handle.services.processes.take id (.runHead command input limit time))
  | .fileWatch (.start target coalescing) => do
    let (id, wait) ← handle.ask
    handle.services.fileWatches.start id (.start target coalescing)
    return .later id wait do
        let reply ← handle.services.fileWatches.take id (.start target coalescing)
        -- The watch is the job's from here: the runner ends it with the job.
        if let .ok watch := reply then
          handle.watches.modify (·.push watch)
        return reply
  | .environment request => return .now (← handle.services.environments.ask request)
  | .post invocation => do
    -- A cancelled job posts nothing: the token is looked at here, and the
    -- post is answered at once, as `environment` is.
    unless ← handle.cancelled do
      handle.posted invocation
    return .now ()
  | .fuzzy request => do
    -- The matcher answers in the call, and may throw: what it throws is the
    -- job's error, as a value.
    match ← (handle.services.fuzzy request).toBaseIO with
    | .ok reply =>
      return .now (.ok reply)
    | .error error =>
      return .now (.error s!"fuzzy: {error}")
  | .snapshot id => return .now (← handle.services.snapshots id)
  | .fileWatch (.next watch) => do
    -- A watch is named for the job that started it, and for no other.
    unless (← handle.watches.get).contains watch do
      return .now (.error .noSuchWatch)
    let (id, wait) ← handle.ask (.of handle.services.fileWatches.outside)
    handle.services.fileWatches.start id (.next watch)
    return .later id wait (handle.services.fileWatches.take id (.next watch))
  | .diff request => do
    -- A snapshot a job holds is named for that job and for no other, as a
    -- save's source is.
    let (old, new) := request.sources
    for source in [old, new] do
      if let .held snapshot := source then
        unless (← handle.held.get).contains snapshot do
          return .now (request.refused .noSuchSnapshot)
    let (id, wait) ← handle.ask
    handle.services.diffs.start id request
    return .later id wait (handle.services.diffs.take id request)
  | .grep (.next search) => do
    -- A search is named for the job that started it, and for no other.
    unless (← handle.searches.get).contains search do
      return .now (.error .noSuchSearch)
    let (id, wait) ← handle.ask
    handle.services.greps.start id (.next search)
    return .later id wait do
        let reply ← handle.services.greps.take id (.next search)
        -- After its last delivery, or a refused read, the service forgets
        -- the search.
        match reply with
        | .ok { ended := none, .. } =>
          pure ()
        | _ =>
          handle.searches.modify (·.filter (· != search))
        return reply
  | .grep request => do
    -- An overlay's snapshot is named for the job that holds it, as a diff's
    -- source is.
    for source in request.sources do
      if let .held snapshot := source then
        unless (← handle.held.get).contains snapshot do
          return .now (request.refused .noSuchSnapshot)
    let (id, wait) ← handle.ask
    handle.services.greps.start id request
    return .later id wait do
        let reply ← handle.services.greps.take id request
        -- The search is the job's from here: the runner ends it with the job.
        match request, reply with
        | .start .., .ok search =>
          handle.searches.modify (·.push search)
        | _, _ =>
          pure ()
        return reply

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
      -- wait was being made: then nobody else will withdraw it, and it does
      -- so itself, its `park` or `serve` having taken the wait out of the
      -- table if it was still there. It drops the wait at its services even
      -- when the service completed it first, which keeps the reply until it
      -- is taken or dropped. A job in a wait only a test ends gave its unit
      -- back in that same section, its wait recorded: a host that reads idle
      -- finds every parked job in a wait a cancel withdraws.
      if let some ended?← handle.enter id then
        handle.drop id
        if let some ended := ended? then
          ended .cancelled
      BaseIO.chainTask wait.result? fun completion => do
          let cancelled ← handle.resume
          -- A wait the service completed just as the job was cancelled reads
          -- as completed: the token still says the job is over.
          if completion == some .completed && !cancelled then
            drive handle finished (next (← reply))
          else
            -- The reply is never fetched, and its service keeps nothing for
            -- it: a cancel that found the wait recorded dropped it at the
            -- services, and a job cancelled on its way in dropped it itself
            -- at its `park` or `serve`, whether or not the wait had ended.
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
the job has ended and its outcome is in the handle, and `posted` with each
post the job makes while it is not cancelled, on the job's thread, in the
order they were made. -/
def spawn (services : Services) (work : Work) (finished : BaseIO Unit)
    (posted : Invocation → BaseIO Unit := fun _ => pure ()) : BaseIO Handle := do
  -- The job's `start`, in one section: it is numbered, and it can run from
  -- here, holding a unit of the host's activity until it is in a wait only a
  -- test ends, or has ended, its `finished` called first, so a wake-up it
  -- posts there is posted under its unit.
  let job ←
    services.completions.critical fun pending => do
        let number := pending.nextJob
        let (fresh, move) := Protocol.JobState.started
        let job : JobRef :=
          { number, token := ← IO.mkRef ⟨fresh⟩, activity := services.activity
            recorder := services.recorder }
        Section.move services.activity move
        Section.note services.recorder (.start number)
        return (job, { pending with nextJob := number + 1 })
  let handle : Handle :=
    { services, job, outcome := ← IO.Promise.new
      finishedRan := ← IO.Promise.new, held := ← IO.mkRef #[]
      children := ← IO.mkRef #[], watches := ← IO.mkRef #[], searches := ← IO.mkRef #[]
      posted }
  let ended : BaseIO Unit := do
    finished
    handle.retire
    handle.finishedRan.resolve ()
  discard <| BaseIO.asTask (start handle ended work)
  return handle

end Editor.Job
