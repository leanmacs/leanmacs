import Editor.File.Model
import Editor.Job.Runner
import Editor.Process.Model

/-!
# The fakes of the job runner's services

Three fakes, published for `model-test` and `config-test`: the fake clock,
below, the fake file service (`FakeFiles`, after it) and the fake process
service (`FakeProcesses`, at the end of this module), each of whose doc
comment has its rules.

## The fake clock

The fake of the clock port (`Job.Timers`, `Editor/Job/Runner.lean`): a clock a
test moves by hand. With it a check of anything that waits controls time,
and nothing sleeps to let something happen.

- The clock reads 0 until `advance` moves it. `advance` completes every wait
  that is then due, earliest deadline first, through the table of waits it
  was made over.
- A wait started at or after its deadline completes at once, on the thread
  that started it.
- It records every wait started, with the thread that started it, and every
  wait withdrawn, and says how many are waiting. It records the threads that
  read it, too.

A wait that is withdrawn is forgotten: `advance` never completes it.

A test can also hold the port itself: `holdReads` and `holdStarts` park every
read, or every start, on a promise the test resolves, so the test can act
while a request is in flight, which no amount of sleeping would arrange.
-/

namespace Editor.Job

/-- What a fake clock holds. -/
structure FakeClock.State where
  /-- The clock's reading, in milliseconds. -/
  now : Nat := 0
  /-- The waits not yet due, each an id and a deadline, in the order they
  were started. -/
  waiting : Array (UInt64 × Nat) := #[]
  /-- Every wait ever started, each an id and a deadline, oldest first. -/
  started : Array (UInt64 × Nat) := #[]
  /-- The thread that started each wait of `started`. -/
  startThreads : Array UInt64 := #[]
  /-- The waits that were withdrawn while they were waiting, oldest first. -/
  withdrawn : Array UInt64 := #[]
  /-- How many times the clock was read. -/
  reads : Nat := 0
  /-- The threads that read the clock, each once. -/
  readThreads : Array UInt64 := #[]
  /-- What a read parks on before it reads, if reads are held. -/
  readHold : Option (IO.Promise Unit) := none
  /-- What a start parks on before it starts its wait, if starts are held. -/
  startHold : Option (IO.Promise Unit) := none
  /-- How many calls have arrived at a hold. -/
  held : Nat := 0

/-- A clock a test moves by hand. -/
structure FakeClock where
  /-- The table the clock completes its waits through. -/
  completions : Completions
  /-- What the clock holds. Every change to it is one atomic step. -/
  state : IO.Ref FakeClock.State

namespace FakeClock

/-- A clock that reads 0 and has no waits, over the table `completions`. -/
def new (completions : Completions) : BaseIO FakeClock :=
  return { completions, state := ← IO.mkRef {} }

/-- Parks the calling thread on the hold `hold` picks, if there is one, until
the test that made it resolves it, and counts the arrival. -/
def park (clock : FakeClock) (hold : State → Option (IO.Promise Unit)) : BaseIO Unit := do
  let hold? ←
    clock.state.modifyGet fun state =>
        (hold state, if (hold state).isSome then { state with held := state.held + 1 } else state)
  if let some hold := hold? then
    discard <| IO.wait hold.result?

/-- Holds every read of the clock from now on: a read parks, before it reads,
until the promise this returns is resolved. So a test can act while a
reading is in flight. -/
def holdReads (clock : FakeClock) : BaseIO (IO.Promise Unit) := do
  let hold ← IO.Promise.new
  clock.state.modify fun state => { state with readHold := some hold }
  return hold

/-- Holds every start of a wait from now on: a start parks, before the clock
knows the wait, until the promise this returns is resolved. So a test can act
while a job is entering a wait. -/
def holdStarts (clock : FakeClock) : BaseIO (IO.Promise Unit) := do
  let hold ← IO.Promise.new
  clock.state.modify fun state => { state with startHold := some hold }
  return hold

/-- How many calls have arrived at a hold, parked or since let go. -/
def held (clock : FakeClock) : BaseIO Nat :=
  return (← clock.state.get).held

/-- Reads the clock, and records the thread that did. -/
def read (clock : FakeClock) : BaseIO Nat := do
  clock.park (·.readHold)
  let thread ← IO.getTID
  clock.state.modifyGet fun state =>
      (state.now,
        { state with
          reads := state.reads + 1,
          readThreads :=
            if state.readThreads.contains thread then state.readThreads
            else state.readThreads.push thread })

/-- Starts the wait `id`, due at `deadline`: it waits until the clock is
advanced that far, or is completed at once if the clock is already there. -/
def start (clock : FakeClock) (id : UInt64) (deadline : Nat) : BaseIO Unit := do
  clock.park (·.startHold)
  let thread ← IO.getTID
  let due ←
    clock.state.modifyGet fun state =>
        let state :=
          { state with
            started := state.started.push (id, deadline),
            startThreads := state.startThreads.push thread }
        if deadline ≤ state.now then (true, state)
        else (false, { state with waiting := state.waiting.push (id, deadline) })
  if due then
    clock.completions.finish id .completed

/-- Withdraws the wait `id`, if it is waiting. -/
def cancel (clock : FakeClock) (id : UInt64) : BaseIO Unit :=
  clock.state.modify fun state =>
    if state.waiting.any (·.1 == id) then
      { state with
        waiting := state.waiting.filter (·.1 != id), withdrawn := state.withdrawn.push id }
    else state

/-- The clock as the port the runner is given. -/
def timers (clock : FakeClock) : Timers :=
  { now := clock.read, start := clock.start, cancel := clock.cancel }

/-- The waits of `waiting` that are due at `now`, earliest deadline first and,
of two with one deadline, the one started first; and the rest, in the order
they were started. -/
def split (waiting : Array (UInt64 × Nat)) (now : Nat) :
    Array (UInt64 × Nat) × Array (UInt64 × Nat) :=
  let (due, rest) := waiting.partition (·.2 ≤ now)
  -- An insertion sort, which keeps the order of equal deadlines.
  (due.foldl
      (fun sorted wait =>
        let before := sorted.takeWhile (·.2 ≤ wait.2)
        before ++ #[wait] ++ sorted.extract before.size sorted.size)
      #[],
    rest)

/-- Moves the clock on by `duration` milliseconds, and completes every wait
that is now due, earliest deadline first. -/
def advance (clock : FakeClock) (duration : Nat) : BaseIO Unit := do
  let due ←
    clock.state.modifyGet fun state =>
        let now := state.now + duration
        let (due, waiting) := split state.waiting now
        (due,
          { state with
            now, waiting })
  for (id, _) in due do
    clock.completions.finish id .completed

/-- The clock's reading, which this does not record as a read. -/
def now (clock : FakeClock) : BaseIO Nat :=
  return (← clock.state.get).now

/-- How many waits are waiting. -/
def waiting (clock : FakeClock) : BaseIO Nat :=
  return (← clock.state.get).waiting.size

/-- The earliest deadline a wait is waiting for, if any is. -/
def nextDeadline (clock : FakeClock) : BaseIO (Option Nat) :=
  return (← clock.state.get).waiting.foldl
      (fun earliest wait => some (earliest.elim wait.2 (min · wait.2))) none

/-- Every wait ever started, each an id and a deadline, oldest first. -/
def started (clock : FakeClock) : BaseIO (Array (UInt64 × Nat)) :=
  return (← clock.state.get).started

/-- The thread that started each wait of `started`. -/
def startThreads (clock : FakeClock) : BaseIO (Array UInt64) :=
  return (← clock.state.get).startThreads

/-- The waits that were withdrawn while they were waiting, oldest first. -/
def withdrawn (clock : FakeClock) : BaseIO (Array UInt64) :=
  return (← clock.state.get).withdrawn

/-- How many times the clock was read through the port. -/
def reads (clock : FakeClock) : BaseIO Nat :=
  return (← clock.state.get).reads

/-- The threads that read the clock through the port, each once. -/
def readThreads (clock : FakeClock) : BaseIO (Array UInt64) :=
  return (← clock.state.get).readThreads

end FakeClock

/-- What a fake file service holds. -/
structure FakeFiles.State where
  /-- The files, and the snapshots a request may name. -/
  model : FileModel := {}
  /-- The requests that were started and have been neither taken nor
  withdrawn, each with its wait's id, oldest first. -/
  pending : Array (UInt64 × FileRequest) := #[]
  /-- Every request ever started, each with its wait's id, oldest first. -/
  started : Array (UInt64 × FileRequest) := #[]
  /-- The waits that were withdrawn while their requests were pending,
  oldest first. -/
  withdrawn : Array UInt64 := #[]
  /-- Every snapshot the service was asked to release, oldest first. -/
  released : Array JobSnapshotId := #[]
  /-- Whether completions are held: a request started while they are is not
  completed until the test lets go. -/
  holding : Bool := false
  /-- The waits whose completion is held, oldest first. -/
  parked : Array UInt64 := #[]
  /-- The thread that started each request of `started`. -/
  startThreads : Array UInt64 := #[]
  /-- What a take parks on before it answers, if takes are held. -/
  takeHold : Option (IO.Promise Unit) := none
  /-- How many takes have arrived at the hold. -/
  takesHeld : Nat := 0

/-- The fake of the file port (`Job.Files`, `Editor/Job/Runner.lean`): the
pure model of files (`Editor/File/Model.lean`) behind a reference. It is
published for `model-test`, so the job port's file requests run on the
runner with no library and no disk.

- `start` records the request and completes its wait: at once, or, while the
  test holds completions (`holdCompletions`), when the test lets go
  (`letGo`).
- `take` answers from the model, and that is when a request happens: a load
  adds its snapshot to what the model holds for jobs then, and a save writes
  its file then. So a request that was withdrawn before it was taken never
  happened, and `take` of it is refused as failed.
- `cancel` withdraws a request that was started and not taken, and is safe
  for any id.
- `release` empties the model's slot for a job's snapshot.

It records what was started, withdrawn and released, and a test sets what
the editor has published (`publish`). -/
structure FakeFiles where
  /-- The table the service completes its waits through. -/
  completions : Completions
  /-- What the service holds. Every change to it is one atomic step. -/
  state : IO.Ref FakeFiles.State

namespace FakeFiles

/-- A file service over `model`, through the table `completions`, with no
request started. -/
def new (completions : Completions) (model : FileModel := {}) : BaseIO FakeFiles :=
  return { completions, state := ← IO.mkRef { model } }

/-- Holds every completion from now on: a request started from now is not
completed until `letGo`. So a test can act while a job is in a file wait. -/
def holdCompletions (files : FakeFiles) : BaseIO Unit :=
  files.state.modify fun state => { state with holding := true }

/-- Completes every wait whose completion is held, oldest first, and holds
none from now on. -/
def letGo (files : FakeFiles) : BaseIO Unit := do
  let parked ←
    files.state.modifyGet fun state =>
        (state.parked,
          { state with
            holding := false, parked := #[] })
  for id in parked do
    files.completions.finish id .completed

/-- Sets what the editor has published: the snapshots a save may name by a
`SnapshotId`. -/
def publish (files : FakeFiles) (snapshots : Array (Option TextContent)) : BaseIO Unit :=
  files.state.modify fun state => { state with model := { state.model with snapshots } }

/-- Holds every take from now on: a take parks, before it answers, until the
promise this returns is resolved. So a test can act while a job is fetching
the reply of a wait that has completed. -/
def holdTakes (files : FakeFiles) : BaseIO (IO.Promise Unit) := do
  let hold ← IO.Promise.new
  files.state.modify fun state => { state with takeHold := some hold }
  return hold

/-- How many takes have arrived at the hold, parked or since let go. -/
def takesHeld (files : FakeFiles) : BaseIO Nat :=
  return (← files.state.get).takesHeld

/-- Starts `request` as the wait `id`, records the thread that did, and
completes the wait unless completions are held. -/
def start (files : FakeFiles) (id : UInt64) (request : FileRequest) : BaseIO Unit := do
  let thread ← IO.getTID
  let held ←
    files.state.modifyGet fun state =>
        let state :=
          { state with
            pending := state.pending.push (id, request)
            started := state.started.push (id, request)
            startThreads := state.startThreads.push thread }
        if state.holding then (true, { state with parked := state.parked.push id })
        else (false, state)
  unless held do
    files.completions.finish id .completed

/-- Parks the calling thread on the take hold, if there is one, until the
test that made it resolves it, and counts the arrival. -/
def parkTake (files : FakeFiles) : BaseIO Unit := do
  let hold? ←
    files.state.modifyGet fun state =>
        (state.takeHold,
          if state.takeHold.isSome then { state with takesHeld := state.takesHeld + 1 } else state)
  if let some hold := hold? then
    discard <| IO.wait hold.result?

/-- The model's answer to `request`, which was started as the wait `id`, and
the request is pending no longer. A request that is not pending, because it
was withdrawn or never started, is refused as failed and changes nothing. -/
def take (files : FakeFiles) (id : UInt64) : (request : FileRequest) → BaseIO request.Reply
  | .load path limit => do
    files.parkTake
    files.state.modifyGet fun state =>
        if state.pending.any (·.1 == id) then
          let (reply, model) := state.model.load path limit
          (reply,
            { state with
              model, pending := state.pending.filter (·.1 != id) })
        else (.error (.failed "the request is not pending"), state)
  | .save source path expect => do
    files.parkTake
    files.state.modifyGet fun state =>
        if state.pending.any (·.1 == id) then
          let (reply, model) := state.model.save source path expect
          (reply,
            { state with
              model, pending := state.pending.filter (·.1 != id) })
        else (.error (.failed "the request is not pending"), state)

/-- Withdraws the wait `id`, if its request is pending: it is never
completed here and never happens. -/
def cancel (files : FakeFiles) (id : UInt64) : BaseIO Unit :=
  files.state.modify fun state =>
    if state.pending.any (·.1 == id) then
      { state with
        pending := state.pending.filter (·.1 != id)
        parked := state.parked.filter (· != id)
        withdrawn := state.withdrawn.push id }
    else state

/-- Gives up the job's snapshot `snapshot`: the model holds it no longer. -/
def release (files : FakeFiles) (snapshot : JobSnapshotId) : BaseIO Unit :=
  files.state.modify fun state =>
    { state with
      model := state.model.released snapshot
      released := state.released.push snapshot }

/-- The service as the port the runner is given. -/
def files (files : FakeFiles) : Files :=
  { start := files.start, take := files.take, cancel := files.cancel, release := files.release }

/-- The model as it is now. -/
def model (files : FakeFiles) : BaseIO FileModel :=
  return (← files.state.get).model

/-- How many requests are pending: started, and neither taken nor
withdrawn. -/
def waiting (files : FakeFiles) : BaseIO Nat :=
  return (← files.state.get).pending.size

/-- Every request ever started, each with its wait's id, oldest first. -/
def started (files : FakeFiles) : BaseIO (Array (UInt64 × FileRequest)) :=
  return (← files.state.get).started

/-- The thread that started each request of `started`. -/
def startThreads (files : FakeFiles) : BaseIO (Array UInt64) :=
  return (← files.state.get).startThreads

/-- The waits that were withdrawn while their requests were pending, oldest
first. -/
def withdrawn (files : FakeFiles) : BaseIO (Array UInt64) :=
  return (← files.state.get).withdrawn

/-- Every snapshot the service was asked to release, oldest first. -/
def released (files : FakeFiles) : BaseIO (Array JobSnapshotId) :=
  return (← files.state.get).released

end FakeFiles

/-- What a fake process service holds. -/
structure FakeProcesses.State where
  /-- What each command does, and what was started and killed. -/
  model : ProcessModel := {}
  /-- The requests that were started and have been neither taken nor
  withdrawn, each with its wait's id, oldest first. -/
  pending : Array (UInt64 × ProcessRequest) := #[]
  /-- Every request ever started, each with its wait's id, oldest first. -/
  started : Array (UInt64 × ProcessRequest) := #[]
  /-- The waits that were withdrawn while their requests were pending,
  oldest first. -/
  withdrawn : Array UInt64 := #[]
  /-- The waits whose replies were taken, oldest first. -/
  taken : Array UInt64 := #[]
  /-- Whether completions are held: a request started while they are is not
  completed until the test lets go. -/
  holding : Bool := false
  /-- The waits whose completion is held, oldest first. -/
  parked : Array UInt64 := #[]

/-- The fake of the process port (`Job.Processes`, `Editor/Job/Runner.lean`):
the pure model of processes (`Editor/Process/Model.lean`) behind a
reference. It is published for `model-test`, so the job port's process
requests run on the runner with no library and no process.

- `start` records the request and completes its wait: at once, or, while
  the test holds completions (`holdCompletions`), when the test lets go
  (`letGo`).
- `take` answers from the model, and that is when a run happens: the model
  records it as started then. So a request withdrawn before it was taken
  never ran, and `take` of it is refused as failed.
- `cancel` withdraws a request that was started and not taken, as the
  library's service kills a run's child, and is safe for any id. Of the id
  of a streaming child, it ends the child in the model, as the library's
  service kills one, and records the id as withdrawn.
- A streaming child is named by the id of its start's wait, as the
  library's is: `take` of a start has the model give it that id.

It records what was started, withdrawn and taken. -/
structure FakeProcesses where
  /-- The table the service completes its waits through. -/
  completions : Completions
  /-- What the service holds. Every change to it is one atomic step. -/
  state : IO.Ref FakeProcesses.State

namespace FakeProcesses

/-- A process service over `model`, through the table `completions`, with no
request started. -/
def new (completions : Completions) (model : ProcessModel := {}) : BaseIO FakeProcesses :=
  return { completions, state := ← IO.mkRef { model } }

/-- Holds every completion from now on: a request started from now is not
completed until `letGo`. So a test can act while a job is in a process
wait. -/
def holdCompletions (processes : FakeProcesses) : BaseIO Unit :=
  processes.state.modify fun state => { state with holding := true }

/-- Completes every wait whose completion is held, oldest first, and holds
none from now on. -/
def letGo (processes : FakeProcesses) : BaseIO Unit := do
  let parked ←
    processes.state.modifyGet fun state =>
        (state.parked,
          { state with
            holding := false, parked := #[] })
  for id in parked do
    processes.completions.finish id .completed

/-- Starts `request` as the wait `id`, and completes the wait unless
completions are held. -/
def start (processes : FakeProcesses) (id : UInt64) (request : ProcessRequest) : BaseIO Unit := do
  let held ←
    processes.state.modifyGet fun state =>
        let state :=
          { state with
            pending := state.pending.push (id, request)
            started := state.started.push (id, request) }
        if state.holding then (true, { state with parked := state.parked.push id })
        else (false, state)
  unless held do
    processes.completions.finish id .completed

/-- The model's answer to `request`, which was started as the wait `id`, and
the request is pending no longer. A request that is not pending, because it
was withdrawn or never started, is refused as failed and changes nothing. -/
def take (processes : FakeProcesses) (id : UInt64) (request : ProcessRequest) :
    BaseIO request.Reply :=
  processes.state.modifyGet fun state =>
    if state.pending.any (·.1 == id) then
      -- A child is named by the wait of its start, as the library's is.
      let model :=
        if let .start .. := request then { state.model with next := id.toNat } else state.model
      let (reply, model, _) := model.handle 0 none request
      (reply,
        { state with
          model, pending := state.pending.filter (·.1 != id), taken := state.taken.push id })
    else (request.refused (.failed "the request is not pending"), state)

/-- Withdraws the wait `id`, if its request is pending: it is never
completed here and never runs. Or, if `id` names a streaming child of the
model's, ends it as the library kills one: the model records it as killed
and forgets it. -/
def cancel (processes : FakeProcesses) (id : UInt64) : BaseIO Unit :=
  processes.state.modify fun state =>
    if state.pending.any (·.1 == id) then
      { state with
        pending := state.pending.filter (·.1 != id)
        parked := state.parked.filter (· != id)
        withdrawn := state.withdrawn.push id }
    else
      if state.model.children.any (·.id == id.toNat) then
        { state with
          model := state.model.kill id.toNat, withdrawn := state.withdrawn.push id }
      else state

/-- The service as the port the runner is given. -/
def processes (processes : FakeProcesses) : Processes :=
  { start := processes.start, take := processes.take, cancel := processes.cancel }

/-- The model as it is now. -/
def model (processes : FakeProcesses) : BaseIO ProcessModel :=
  return (← processes.state.get).model

/-- How many requests are pending: started, and neither taken nor
withdrawn. -/
def waiting (processes : FakeProcesses) : BaseIO Nat :=
  return (← processes.state.get).pending.size

/-- Every request ever started, each with its wait's id, oldest first. -/
def started (processes : FakeProcesses) : BaseIO (Array (UInt64 × ProcessRequest)) :=
  return (← processes.state.get).started

/-- The waits that were withdrawn while their requests were pending, oldest
first. -/
def withdrawn (processes : FakeProcesses) : BaseIO (Array UInt64) :=
  return (← processes.state.get).withdrawn

/-- The waits whose replies were taken, oldest first. -/
def taken (processes : FakeProcesses) : BaseIO (Array UInt64) :=
  return (← processes.state.get).taken

end FakeProcesses

end Editor.Job
