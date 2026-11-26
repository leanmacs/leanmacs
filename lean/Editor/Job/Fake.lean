import Editor.File.Model
import Editor.FileWatch.Model
import Editor.Grep.Model
import Editor.Job.Pump
import Editor.Job.Runner
import Editor.PackageService
import Editor.Process.Model
import Editor.SyntaxTree.Registration.Model

/-!
# The fakes of the job runner's services

Five fakes, published for `model-test`, `config-test` and the packages'
linked tests: the fake clock, below, the fake file service (`FakeFiles`,
after it), the fake process service (`FakeProcesses`), with its hand-off
of a child to a package's crate (`FakeProcesses.handOff`), the fake of a
package's service (`FakePackageService`), the frame of a package's own
fake of its service (`PackageFake`), the fake watch service
(`FakeFileWatches`), and the fake grammar service (`FakeGrammars`), each of
whose doc comment has its rules; the fake scheduler
(`FakeScheduler`), which runs a job's code only when a check steps it; the
fake completion pump (`FakePump`), the one step point they answer through
in their step mode; and the fake of the recording port (`FakeRecorder`, at the end of this
module), which keeps the trace of the runner's protocol transitions and
holds a thread at one a check names.

## Answering on the check's step

Each job service's fake takes `answer : FakeAnswer`. `.atOnce`, the
default, is how every fake answered before: a completion is finished at
once, on the thread that made it. `.onStep pump` hands every completion
(a start's, a flush's, a `letGo`'s, a watch's wake) to the fake pump
(`FakePump`) in place of finishing it, as a real service hands its
completion to the library's one queue; the check steps the pump on its own
thread, so every answer is on that thread, in one due order. A runner
given the fake scheduler (`Services.scheduler`) runs the job's code on the
check's thread too, when the check steps it, so the job's requests are
made there. `FakePump.runToEnd` is the stepped runner: it runs the job's
next piece of code, steps the pump or moves the clock, waits on events
alone (the next completion handed, the next wait started on the fake
clock, or the job's end) only when none of those can, and asserts at the
end that nothing is left due. Each fake also logs what it was handed, with
the thread that handed it (`FakeFiles.log`), and the file service resolves
an arrival once that many requests are started
(`FakeFiles.startsArrivedAt`). The fakes start no thread: their state is
one reference each and the promises they hand out.

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

As a port it says its waits end only when a test acts (`Timers.outside`),
and so does the fake watch service's (`FileWatches.outside`): a job asleep
on the fake clock, or in a `next` of a fake watch, holds no unit of the
host's activity (`Editor/Job/Runner.lean`, "Activity"). The fake files,
processes, diffs and greps do not say so: their waits end by themselves, or
a test holds them on purpose, and a held wait is not idle.

A test can also hold the port itself: `holdReads` and `holdStarts` park every
read, or every start, on a promise the test resolves, so the test can act
while a request is in flight, which no amount of sleeping would arrange.

And a test waits for a fake to reach a state on a promise the fake resolves,
never by polling it: `FakeClock.arrivedAt` (calls arrived at a hold, waits
started, waits waiting) and `FakeFiles.takesArrivedAt` (takes arrived at the
take hold). The promise is resolved in the same atomic step that makes the
state reach it, or at once if the state already has, so an arrival before
the promise was asked for resolves it as surely as one after.
-/

namespace Editor.Job

/-- What a test waits for a fake clock to reach (`FakeClock.arrivedAt`). -/
inductive FakeClockArrival where
  /-- At least `count` calls have arrived at a hold (`FakeClock.held`). -/
  | held (count : Nat)
  /-- At least `count` waits have been started (`FakeClock.started`). -/
  | started (count : Nat)
  /-- Exactly `count` waits are waiting (`FakeClock.waiting`). -/
  | waiting (count : Nat)

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
  /-- What tests wait for the clock to reach (`arrivedAt`), each with the
  promise resolved when it does. -/
  arrivals : Array (FakeClockArrival × IO.Promise Unit) := #[]
  /-- The actions armed to run inside a read (`atRead`), each with the
  count of reads it runs in. -/
  atReads : Array (Nat × BaseIO Unit) := #[]

/-- A clock a test moves by hand. -/
structure FakeClock where
  /-- The table the clock completes its waits through. -/
  completions : Completions
  /-- What the clock holds. Every change to it is one atomic step. -/
  state : IO.Ref FakeClock.State

/-- Whether the clock's state `state` has reached `arrival`. -/
def FakeClockArrival.reached (arrival : FakeClockArrival) (state : FakeClock.State) : Bool :=
  match arrival with
  | .held count => state.held ≥ count
  | .started count => state.started.size ≥ count
  | .waiting count => state.waiting.size == count

namespace FakeClock

/-- A clock that reads 0 and has no waits, over the table `completions`. -/
def new (completions : Completions) : BaseIO FakeClock :=
  return { completions, state := ← IO.mkRef {} }

/-- Changes the clock's state by `change`, in one atomic step, and resolves
the promise of every arrival the new state has reached. -/
def change {α : Type} (clock : FakeClock) (change : State → α × State) : BaseIO α := do
  let (result, reached) ←
    clock.state.modifyGet fun state =>
        let (result, state) := change state
        let (reached, rest) := state.arrivals.partition (·.1.reached state)
        ((result, reached), { state with arrivals := rest })
  for (_, promise) in reached do
    promise.resolve ()
  return result

/-- A promise resolved once the clock has reached `arrival`: at once if it
already has, else in the step that makes it. What a test waits on, with
`Job.awaitWithin` and a hang guard, for a state the clock reaches on another
thread, in place of polling the readout. -/
def arrivedAt (clock : FakeClock) (arrival : FakeClockArrival) : BaseIO (IO.Promise Unit) := do
  let promise ← IO.Promise.new
  let reached ←
    clock.state.modifyGet fun state =>
        if arrival.reached state then (true, state)
        else (false, { state with arrivals := state.arrivals.push (arrival, promise) })
  if reached then
    promise.resolve ()
  return promise

/-- Parks the calling thread on the hold `hold` picks, if there is one, until
the test that made it resolves it, and counts the arrival. -/
def park (clock : FakeClock) (hold : State → Option (IO.Promise Unit)) : BaseIO Unit := do
  let hold? ←
    clock.change fun state =>
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

/-- Reads the clock, and records the thread that did. An action armed for
this read (`atRead`) runs first, on this thread, so the read sees what it
did. -/
def read (clock : FakeClock) : BaseIO Nat := do
  clock.park (·.readHold)
  let thread ← IO.getTID
  let due ←
    clock.state.modifyGet fun state =>
        let reads := state.reads + 1
        let (due, rest) := state.atReads.partition (·.1 == reads)
        (due,
          { state with
            reads, atReads := rest
            readThreads :=
              if state.readThreads.contains thread then state.readThreads
              else state.readThreads.push thread })
  for (_, action) in due do
    action
  return (← clock.state.get).now

/-- Arms `action` to run inside the `count`-th read from now (1 for the
next), on the reading thread, before that read returns: so a check moves
the clock between two reads the code under test makes on its own thread,
with no thread of its own and no held read. -/
def atRead (clock : FakeClock) (count : Nat) (action : BaseIO Unit) : BaseIO Unit :=
  clock.state.modify fun state =>
    { state with atReads := state.atReads.push (state.reads + count, action) }

/-- Starts the wait `id`, due at `deadline`: it waits until the clock is
advanced that far, or is completed at once if the clock is already there. -/
def start (clock : FakeClock) (id : UInt64) (deadline : Nat) : BaseIO Unit := do
  clock.park (·.startHold)
  let thread ← IO.getTID
  let due ←
    clock.change fun state =>
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
  clock.change fun state =>
    ((),
      if state.waiting.any (·.1 == id) then
        { state with
          waiting := state.waiting.filter (·.1 != id), withdrawn := state.withdrawn.push id }
      else state)

/-- Flushes the clock as the wait `id`: it is due now, so it is completed at
once, after every wait that `start` or `advance` has already completed. -/
def flush (clock : FakeClock) (id : UInt64) : BaseIO Unit :=
  clock.completions.finish id .completed

/-- The clock as the port the runner is given. -/
def timers (clock : FakeClock) : Timers :=
  { now := clock.read, start := clock.start, cancel := clock.cancel, flush := clock.flush
    outside := true }

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
    clock.change fun state =>
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

/-- Whether a wait is waiting that a move of the clock by `duration`
milliseconds would complete. -/
def dueWithin (clock : FakeClock) (duration : Nat) : BaseIO Bool := do
  let state ← clock.state.get
  return state.waiting.any (·.2 ≤ state.now + duration)

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

/-- One piece of a job's code a fake scheduler holds. -/
inductive FakeScheduler.Entry where
  /-- A job's first run. -/
  | start (job : BaseIO Unit)
  /-- A job's continuation, run with what `wait` ended with once it has. -/
  | resume (wait : Task (Option Completion)) (next : Option Completion → BaseIO Unit)

/-- What a fake scheduler holds. -/
structure FakeScheduler.State where
  /-- The pieces handed and not yet run, in the order they were handed. -/
  held : Array FakeScheduler.Entry := #[]
  /-- The thread that ran each piece, oldest first. -/
  ranThreads : Array UInt64 := #[]

/-- The fake of the scheduler port (`Scheduler`, `Editor/Job/Runner.lean`):
it holds a job's start and each of its continuations, and runs none of them
until a check steps it (`step`), which runs the oldest that can run, a start
or a continuation whose wait has ended, on the caller's thread. So a job of
a runner given it makes its requests on the check's thread, and takes each
reply there on a step, and nothing of it runs anywhere else. It starts no
task: its state is one reference. It is stepped from one thread. -/
structure FakeScheduler where
  /-- What it holds. Every change to it is one atomic step. -/
  state : IO.Ref FakeScheduler.State

namespace FakeScheduler

/-- A scheduler that holds nothing. -/
def new : BaseIO FakeScheduler :=
  return { state := ← IO.mkRef {} }

/-- The fake as the port the runner is given: each piece is held. -/
def scheduler (jobs : FakeScheduler) : Scheduler where
  start job := jobs.state.modify fun state => { state with held := state.held.push (.start job) }
  resume wait next :=
    jobs.state.modify fun state => { state with held := state.held.push (.resume wait next) }

/-- Whether the piece can run now: a start can, and a continuation once its
wait has ended. -/
def Entry.ready : Entry → BaseIO Bool
  | .start _ => pure true
  | .resume wait _ => IO.hasFinished wait

/-- Runs the oldest held piece that can run, on the caller's thread, and
records the thread; `false` when none can. -/
def step (jobs : FakeScheduler) : BaseIO Bool := do
  let some index ← (← jobs.state.get).held.findIdxM? (·.ready) | return false
  let thread ← IO.getTID
  let entry? ←
    jobs.state.modifyGet fun state =>
        (state.held[index]?,
          { state with
            held := state.held.eraseIdxIfInBounds index
            ranThreads := state.ranThreads.push thread })
  match entry? with
  | some (.start job) =>
    job
  | some (.resume wait next) =>
    -- The wait has ended, so this returns at once.
    next (← IO.wait wait)
  | none =>
    pure ()
  return true

/-- Runs every piece that can run, oldest first, with `step`, those a piece
hands on the way included. -/
partial def stepAll (jobs : FakeScheduler) : BaseIO Unit := do
  if ← jobs.step then
    jobs.stepAll

/-- How many pieces it holds, run or not yet able to. -/
def size (jobs : FakeScheduler) : BaseIO Nat :=
  return (← jobs.state.get).held.size

/-- The thread that ran each piece, oldest first. -/
def ranThreads (jobs : FakeScheduler) : BaseIO (Array UInt64) :=
  return (← jobs.state.get).ranThreads

/-- Whether it holds nothing: no job's code is left to run. -/
def quiescent (jobs : FakeScheduler) : BaseIO Bool :=
  return (← jobs.state.get).held.isEmpty

end FakeScheduler

/-- What a fake completion pump holds. -/
structure FakePump.State where
  /-- The completions handed and not yet finished, oldest first. -/
  due : Array UInt64 := #[]
  /-- How many completions were ever handed. -/
  handed : Nat := 0
  /-- The thread that finished each completion, oldest first. -/
  finishedThreads : Array UInt64 := #[]
  /-- The counts of completions handed that checks wait for (`arrivedAt`),
  each with the promise resolved when `handed` reaches it. -/
  arrivals : Array (Nat × IO.Promise Unit) := #[]
  /-- Whether the source is closed: once nothing is due, a pull of it says
  quit. -/
  closed : Bool := false
  /-- What a step that finds nothing due parks on before it returns, if
  empty steps are held (`holdEmptySteps`). -/
  emptyHold : Option (IO.Promise Unit) := none
  /-- How many steps that found nothing due have arrived at the hold. -/
  emptyHeld : Nat := 0
  /-- The counts of empty steps held that checks wait for
  (`emptyStepsArrivedAt`), each with the promise resolved when `emptyHeld`
  reaches it. -/
  emptyArrivals : Array (Nat × IO.Promise Unit) := #[]

/-- The fake of the completion pump (`Editor/Job/Pump.lean`): the one step
point of the job services' fakes. A stepped fake hands it each completion
(`hand`) in place of finishing the wait itself, as a real service hands
its completion to the library's queue; nothing is finished until the check
steps (`step`), which finishes the oldest due completion on the caller's
thread, so the fakes' answers come in one due order, as the real wiring's
do. It starts no task: its state is one reference and the promises it
hands out. Its `source` is the fake as the pump's port, so `pumpFrom` runs
over it on the check's thread. -/
structure FakePump where
  /-- The table the pump finishes its completions through. -/
  completions : Completions
  /-- What the pump holds. Every change to it is one atomic step. -/
  state : IO.Ref FakePump.State

namespace FakePump

/-- A pump over the table `completions` with nothing due. -/
def new (completions : Completions) : BaseIO FakePump :=
  return { completions, state := ← IO.mkRef {} }

/-- Hands the completion of the wait `id`: due, and finished only by a
step. -/
def hand (pump : FakePump) (id : UInt64) : BaseIO Unit := do
  let reached ←
    pump.state.modifyGet fun state =>
        let handed := state.handed + 1
        let (reached, rest) := state.arrivals.partition (·.1 ≤ handed)
        (reached,
          { state with
            due := state.due.push id, handed, arrivals := rest })
  for (_, promise) in reached do
    promise.resolve ()

/-- Takes the oldest due completion, recording the caller's thread as the
one that finishes it. -/
private def takeDue (pump : FakePump) : BaseIO (Option UInt64) := do
  let thread ← IO.getTID
  pump.state.modifyGet fun state =>
      match state.due[0]? with
      | some id =>
        (some id,
          { state with
            due := state.due.extract 1 state.due.size
            finishedThreads := state.finishedThreads.push thread })
      | none => (none, state)

/-- Parks the caller of a step that found nothing due on the hold, if
empty steps are held, once it has counted the arrival. -/
private def parkEmpty (pump : FakePump) : BaseIO Unit := do
  let (hold?, reached) ←
    pump.state.modifyGet fun state =>
        match state.emptyHold with
        | some hold =>
          let emptyHeld := state.emptyHeld + 1
          let (reached, rest) := state.emptyArrivals.partition (·.1 ≤ emptyHeld)
          ((some hold, reached),
            { state with
              emptyHeld, emptyArrivals := rest })
        | none => ((none, #[]), state)
  for (_, promise) in reached do
    promise.resolve ()
  if let some hold := hold? then
    discard <| IO.wait hold.result?

/-- Finishes the oldest due completion, as completed, on the caller's
thread; `false` when none was due, once the empty step has passed the
hold, if empty steps are held. -/
def step (pump : FakePump) : BaseIO Bool := do
  let some id ← pump.takeDue |
    pump.parkEmpty
    return false
  pump.completions.finish id .completed
  return true

/-- Holds every step that finds nothing due from now on: it parks, before
it returns `false`, until the promise this returns is resolved. So a check
can hand a completion while a stepper is between finding nothing and what
it does next, which no amount of sleeping would arrange. -/
def holdEmptySteps (pump : FakePump) : BaseIO (IO.Promise Unit) := do
  let hold ← IO.Promise.new
  pump.state.modify fun state => { state with emptyHold := some hold }
  return hold

/-- A promise resolved once at least `count` empty steps have arrived at
the hold: at once if they already have, else in the step that counts the
last. -/
def emptyStepsArrivedAt (pump : FakePump) (count : Nat) : BaseIO (IO.Promise Unit) := do
  let promise ← IO.Promise.new
  let reached ←
    pump.state.modifyGet fun state =>
        if state.emptyHeld ≥ count then (true, state)
        else (false, { state with emptyArrivals := state.emptyArrivals.push (count, promise) })
  if reached then
    promise.resolve ()
  return promise

/-- Finishes every due completion, oldest first, with `step`, those a
finish hands on the way included. -/
partial def stepAll (pump : FakePump) : BaseIO Unit := do
  if ← pump.step then
    pump.stepAll

/-- A promise resolved once at least `count` completions have been handed:
at once if they already have, else in the step that hands the last. What a
check waits on, with a hang guard, for a completion handed on another
thread, in place of polling `size`. -/
def arrivedAt (pump : FakePump) (count : Nat) : BaseIO (IO.Promise Unit) := do
  let promise ← IO.Promise.new
  let reached ←
    pump.state.modifyGet fun state =>
        if state.handed ≥ count then (true, state)
        else (false, { state with arrivals := state.arrivals.push (count, promise) })
  if reached then
    promise.resolve ()
  return promise

/-- How many completions are due. -/
def size (pump : FakePump) : BaseIO Nat :=
  return (← pump.state.get).due.size

/-- How many completions were ever handed. -/
def handed (pump : FakePump) : BaseIO Nat :=
  return (← pump.state.get).handed

/-- The thread that finished each completion, oldest first. -/
def finishedThreads (pump : FakePump) : BaseIO (Array UInt64) :=
  return (← pump.state.get).finishedThreads

/-- Closes the source: once nothing is due, a pull of it says quit. -/
def close (pump : FakePump) : BaseIO Unit :=
  pump.state.modify fun state => { state with closed := true }

/-- The pump as the pump's port: a pull gives the oldest due completion,
taken on the caller's thread, and quit once nothing is due and the source
is closed. A pull of an open source with nothing due says quit too: the
fake never blocks, since nothing but the check's own thread could hand it
more. -/
def source (pump : FakePump) : CompletionSource where
  next := do
    match ← pump.takeDue with
    | some id =>
      return .completion id
    | none =>
      return .quit

/-- Whether nothing is due: nothing is left for a step. -/
def quiescent (pump : FakePump) : BaseIO Bool :=
  return (← pump.state.get).due.isEmpty

/-- Runs every job piece and every completion that can run, on the caller's
thread, until neither can. -/
private partial def drain (pump : FakePump) (jobs : Option FakeScheduler) : BaseIO Unit := do
  if let some jobs := jobs then
    if ← jobs.step then
      return ← pump.drain (some jobs)
  if ← pump.step then
    pump.drain jobs

/-- Runs the pump on the caller's thread until `ended` has ended: runs the
next piece of a job's code `jobs` holds that can run, when it is given, or
steps the pump, or moves the clock to the earliest deadline waiting when a
wait has started on `clock` since it last did, which completes that wait on
this thread; and goes on. When none of these can, it waits, on events
alone, for whichever comes first: the next completion handed, the next
wait started on `clock`, or `ended`. Once `ended` has ended it runs what is
still due. So a job runs to its end with every answer the check's, and the
clock stands in for time as the job's own waits start, never at an idle.

Given `jobs`, the scheduler of the job's runner (`FakeScheduler`), the job's
code runs here too, so its requests are made on this thread and the wait is
only reached by a hang. Without it, a job's requests are handed on its pool
thread; the next hand it waits for is the one after the count it read
before its step, so a hand made on another thread just after a step that
found nothing due is not lost (`ModelTest.jobFakeChecks`). Throws a hang
when nothing comes within `guard`, which only a hang reaches; and throws
when the pump, or `jobs`, still holds something at the end. -/
partial def runToEnd {α : Type} (pump : FakePump) (ended : Task α) (guard : HangGuard)
    (clock : Option FakeClock := none) (jobs : Option FakeScheduler := none) (seen : Nat := 0) :
    IO Unit := do
  if ← IO.hasFinished ended then
    pump.drain jobs
    unless ← pump.quiescent do
      throw <| IO.userError "the fake pump still holds a completion once the run ended"
    if let some jobs := jobs then
      unless ← jobs.quiescent do
        throw <| IO.userError "the fake scheduler still holds a job's code once the run ended"
    return
  -- The count of hands is read before the step, and the wait is for the
  -- hand after it: a hand that lands after the step found nothing due
  -- resolves that wait at once, where a count read after the step would
  -- have counted it and waited for the next.
  let handed ← pump.handed
  if let some jobs := jobs then
    if ← jobs.step then
      return ← pump.runToEnd ended guard clock (some jobs) seen
  if ← pump.step then
    return ← pump.runToEnd ended guard clock jobs seen
  if let some clock := clock then
    let started := (← clock.started).size
    if started > seen then
      if let some deadline← clock.nextDeadline then
        clock.advance (deadline - (← clock.now))
      return ← pump.runToEnd ended guard (some clock) jobs started
  let next ← pump.arrivedAt (handed + 1)
  let clockStart ←
    match clock with
    | some clock =>
      pure [(← clock.arrivedAt (.started (seen + 1))).result?.map (sync := true) fun _ => some ()]
    | none =>
      pure []
  let expiry ← guard.expiry
  let first ←
    IO.waitAny
        ([next.result?.map (sync := true) fun _ => some (),
            ended.map (sync := true) fun _ => some (), expiry.map (sync := true) fun _ => none] ++
          clockStart)
  IO.cancel expiry
  let some () := first | throw <| IO.userError guard.hang
  pump.runToEnd ended guard clock jobs seen

end FakePump

/-- How a fake job service answers: at once, as each fake did before the
pump, or on the check's step, through a fake pump it hands each completion
to. -/
inductive FakeAnswer where
  /-- Each completion finished at once, on the thread that made it. -/
  | atOnce
  /-- Each completion handed to `pump`, finished on its step. -/
  | onStep (pump : FakePump)

/-- Finishes the wait `id` as completed as `answer` says: at once, or by
handing it to the pump. -/
def FakeAnswer.complete (answer : FakeAnswer) (completions : Completions) (id : UInt64) :
    BaseIO Unit :=
  match answer with
  | .atOnce => completions.finish id .completed
  | .onStep pump => pump.hand id

/-- One thing a fake file service was handed, in its log (`FakeFiles.log`). -/
inductive FakeFiles.Order where
  /-- A file request started as the wait `id`. -/
  | start (id : UInt64) (request : FileRequest)
  /-- A flush of the files, the diffs or the searches as the wait `id`. -/
  | flush (id : UInt64)
  /-- The wait `id` withdrawn while its request was pending. -/
  | withdraw (id : UInt64)
  /-- A job's snapshot released. -/
  | release (snapshot : JobSnapshotId)
  /-- A diff started as the wait `id`. -/
  | diff (id : UInt64)
  /-- A search request started as the wait `id`. -/
  | grep (id : UInt64)
  /-- The search `id` cancelled while held. -/
  | grepCancel (id : UInt64)

/-- What a fake file service holds. -/
structure FakeFiles.State where
  /-- Every order that changed what the service holds, in arrival order,
  each with the thread that handed it: starts, flushes, withdrawals of a
  pending wait, releases and cancels of a held search. A cancel of a wait it
  does not hold, which the runner hands every service, is not logged. -/
  log : Array (FakeFiles.Order × UInt64) := #[]
  /-- The counts of requests started that tests wait for
  (`startsArrivedAt`), each with the promise resolved when `started`
  reaches it. -/
  startArrivals : Array (Nat × IO.Promise Unit) := #[]
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
  /-- The counts of takes held tests wait for (`takesArrivedAt`), each with
  the promise resolved when `takesHeld` reaches it. -/
  takeArrivals : Array (Nat × IO.Promise Unit) := #[]
  /-- The diff waits that were started and have been neither taken nor
  withdrawn. -/
  diffsPending : Array UInt64 := #[]
  /-- Every diff ever started, each with its wait's id, oldest first. -/
  diffsStarted : Array (UInt64 × DiffRequest) := #[]
  /-- The searches started and held (`Editor/Grep/Model.lean`), each named
  by its start's wait id. -/
  greps : GrepModel := {}
  /-- The search waits that were started and have been neither taken nor
  withdrawn. -/
  grepsPending : Array UInt64 := #[]
  /-- Every search request ever started, each with its wait's id, oldest
  first. -/
  grepsStarted : Array (UInt64 × GrepRequest) := #[]
  /-- The searches cancelled while held, oldest first. -/
  grepsCancelled : Array UInt64 := #[]

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
  /-- How it answers: at once, or on the check's step through a fake pump
  (`FakeAnswer.onStep`). -/
  answer : FakeAnswer := .atOnce
  /-- The text the editor has published for a snapshot id now, read when a
  request that names it is taken (`learnSources`), as the library's
  service reads the published table then: what a host's published table
  hands a fake its stage made (`Stage.stepped`). None by default, so a
  check's own `publish` is all the model holds. -/
  learn : SnapshotId → BaseIO (Option String) := fun _ => pure none
  /-- Told each snapshot a load made, with its text, as it is taken, and
  each snapshot released, with none: what a host's table of what its jobs
  hold is handed, so a finished job's command can adopt a load the fake
  made, as it adopts the library's (`Stage.stepped`). Nothing by default. -/
  holding : JobSnapshotId → Option String → BaseIO Unit := fun _ _ => pure ()

namespace FakeFiles

/-- A file service over `model`, through the table `completions`, with no
request started, that learns a published snapshot through `learn`. -/
def new (completions : Completions) (model : FileModel := {}) (answer : FakeAnswer := .atOnce)
    (learn : SnapshotId → BaseIO (Option String) := fun _ => pure none)
    (holding : JobSnapshotId → Option String → BaseIO Unit := fun _ _ => pure ()) :
    BaseIO FakeFiles :=
  return { completions, state := ← IO.mkRef { model }, answer, learn, holding }

/-- Reads, through `learn`, the text the editor has published now for each
snapshot of `sources` that names one, and puts it in the model's published
snapshots, in place of what it held there; a snapshot `learn` does not know
is left as the model holds it. A request that is taken calls it first, so
it answers from the text as published when it is taken. -/
def learnSources (files : FakeFiles) (sources : Array File.Source) : BaseIO Unit := do
  for source in sources do
    if let .snapshot id := source then
      if let some text← files.learn id then
        files.state.modify fun state =>
            let held := state.model.snapshots
            let grown :=
              if held.size > id.index then held
              else held ++ Array.replicate (id.index + 1 - held.size) none
            { state with
              model :=
                { state.model with snapshots := grown.set! id.index (some { contents := text }) } }

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
    files.answer.complete files.completions id

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

/-- A promise resolved once at least `count` takes have arrived at the hold:
at once if they already have, else in the step that counts the last. What a
test waits on, with a hang guard, in place of polling `takesHeld`. -/
def takesArrivedAt (files : FakeFiles) (count : Nat) : BaseIO (IO.Promise Unit) := do
  let promise ← IO.Promise.new
  let reached ←
    files.state.modifyGet fun state =>
        if state.takesHeld ≥ count then (true, state)
        else (false, { state with takeArrivals := state.takeArrivals.push (count, promise) })
  if reached then
    promise.resolve ()
  return promise

/-- Starts `request` as the wait `id`, records the thread that did, and
completes the wait unless completions are held. -/
def start (files : FakeFiles) (id : UInt64) (request : FileRequest) : BaseIO Unit := do
  let thread ← IO.getTID
  let (held, reached) ←
    files.state.modifyGet fun state =>
        let state :=
          { state with
            pending := state.pending.push (id, request)
            started := state.started.push (id, request)
            startThreads := state.startThreads.push thread
            log := state.log.push (.start id request, thread) }
        let (reached, rest) := state.startArrivals.partition (·.1 ≤ state.started.size)
        let state := { state with startArrivals := rest }
        if state.holding then ((true, reached), { state with parked := state.parked.push id })
        else ((false, reached), state)
  for (_, promise) in reached do
    promise.resolve ()
  unless held do
    files.answer.complete files.completions id

/-- Parks the calling thread on the take hold, if there is one, until the
test that made it resolves it, and counts the arrival. -/
def parkTake (files : FakeFiles) : BaseIO Unit := do
  let (hold?, reached) ←
    files.state.modifyGet fun state =>
        if state.takeHold.isSome then
          let takesHeld := state.takesHeld + 1
          let (reached, rest) := state.takeArrivals.partition (·.1 ≤ takesHeld)
          ((state.takeHold, reached),
            { state with
              takesHeld, takeArrivals := rest })
        else ((none, #[]), state)
  for (_, promise) in reached do
    promise.resolve ()
  if let some hold := hold? then
    discard <| IO.wait hold.result?

/-- The model's answer to `request`, which was started as the wait `id`, and
the request is pending no longer. A request that is not pending, because it
was withdrawn or never started, is refused as failed and changes nothing. -/
def take (files : FakeFiles) (id : UInt64) : (request : FileRequest) → BaseIO request.Reply
  | .load path limit => do
    files.parkTake
    let (reply, text) ←
      files.state.modifyGet fun state =>
          if state.pending.any (·.1 == id) then
            let (reply, model) := state.model.load path limit
            let text :=
              match reply with
              | .ok loaded => (model.held[loaded.snapshot.number]?).join.map (·.contents)
              | .error _ => none
            ((reply, text),
              { state with
                model, pending := state.pending.filter (·.1 != id) })
          else ((.error (.failed "the request is not pending"), none), state)
    if let (.ok loaded, some text) := (reply, text) then
      files.holding loaded.snapshot (some text)
    return reply
  | .save source path expect => do
    files.parkTake
    files.learnSources #[source]
    files.state.modifyGet fun state =>
        if state.pending.any (·.1 == id) then
          let (reply, model) := state.model.save source path expect
          (reply,
            { state with
              model, pending := state.pending.filter (·.1 != id) })
        else (.error (.failed "the request is not pending"), state)
  | .stamp path => do
    files.parkTake
    files.state.modifyGet fun state =>
        if state.pending.any (·.1 == id) then
          (state.model.stamp path, { state with pending := state.pending.filter (·.1 != id) })
        else (.error (.failed "the request is not pending"), state)
  | .list path => do
    files.parkTake
    files.state.modifyGet fun state =>
        if state.pending.any (·.1 == id) then
          let (reply, model) := state.model.list path
          (reply,
            { state with
              model, pending := state.pending.filter (·.1 != id) })
        else (.error (.failed "the request is not pending"), state)
  | .makeDirectory path => do
    files.parkTake
    files.state.modifyGet fun state =>
        if state.pending.any (·.1 == id) then
          let (reply, model) := state.model.makeDirectory path
          (reply,
            { state with
              model, pending := state.pending.filter (·.1 != id) })
        else (.error (.failed "the request is not pending"), state)
  | .append path bytes => do
    files.parkTake
    files.state.modifyGet fun state =>
        if state.pending.any (·.1 == id) then
          let (reply, model) := state.model.append path bytes
          (reply,
            { state with
              model, pending := state.pending.filter (·.1 != id) })
        else (.error (.failed "the request is not pending"), state)
  | .remove path => do
    files.parkTake
    files.state.modifyGet fun state =>
        if state.pending.any (·.1 == id) then
          let (reply, model) := state.model.remove path
          (reply,
            { state with
              model, pending := state.pending.filter (·.1 != id) })
        else (.error (.failed "the request is not pending"), state)

/-- Withdraws the wait `id`, if its request is pending: it is never
completed here and never happens. -/
def cancel (files : FakeFiles) (id : UInt64) : BaseIO Unit := do
  let thread ← IO.getTID
  files.state.modify fun state =>
      if state.pending.any (·.1 == id) then
        { state with
          pending := state.pending.filter (·.1 != id)
          parked := state.parked.filter (· != id)
          withdrawn := state.withdrawn.push id
          log := state.log.push (.withdraw id, thread) }
      else state

/-- Gives up the job's snapshot `snapshot`: the model holds it no longer. -/
def release (files : FakeFiles) (snapshot : JobSnapshotId) : BaseIO Unit := do
  let thread ← IO.getTID
  files.state.modify fun state =>
      { state with
        model := state.model.released snapshot
        released := state.released.push snapshot
        log := state.log.push (.release snapshot, thread) }
  files.holding snapshot none

/-- Flushes the files as the wait `id`: completed at once, unless completions
are held, when it is parked behind them and `letGo` completes it after every
wait held before it. -/
def flush (files : FakeFiles) (id : UInt64) : BaseIO Unit := do
  let thread ← IO.getTID
  let held ←
    files.state.modifyGet fun state =>
        let state := { state with log := state.log.push (.flush id, thread) }
        if state.holding then (true, { state with parked := state.parked.push id })
        else (false, state)
  unless held do
    files.answer.complete files.completions id

/-- The service as the port the runner is given. -/
def files (files : FakeFiles) : Files :=
  { start := files.start, take := files.take, cancel := files.cancel, release := files.release,
    flush := files.flush }

/-- Starts the diff `request` as the wait `id`, and completes the wait unless
completions are held, as a file request's is. -/
def startDiff (files : FakeFiles) (id : UInt64) (request : DiffRequest) : BaseIO Unit := do
  let thread ← IO.getTID
  let held ←
    files.state.modifyGet fun state =>
        let state :=
          { state with
            log := state.log.push (.diff id, thread)
            diffsPending := state.diffsPending.push id
            diffsStarted := state.diffsStarted.push (id, request) }
        if state.holding then (true, { state with parked := state.parked.push id })
        else (false, state)
  unless held do
    files.answer.complete files.completions id

/-- The model's answer to the diff `request`, started as the wait `id`, over
the snapshots the model holds when it is taken. A request that is not
pending is refused as failed. -/
def takeDiff (files : FakeFiles) (id : UInt64) (request : DiffRequest) : BaseIO request.Reply := do
  match request with
  | .lines old new _ | .hunks old new _ =>
    files.learnSources #[old, new]
  files.state.modifyGet fun state =>
      if state.diffsPending.contains id then
        (state.model.diff request, { state with diffsPending := state.diffsPending.erase id })
      else (request.refused (.failed "the request is not pending"), state)

/-- Withdraws the diff wait `id`, if its request is pending. -/
def cancelDiff (files : FakeFiles) (id : UInt64) : BaseIO Unit := do
  let thread ← IO.getTID
  files.state.modify fun state =>
      if state.diffsPending.contains id then
        { state with
          diffsPending := state.diffsPending.erase id
          parked := state.parked.filter (· != id)
          withdrawn := state.withdrawn.push id
          log := state.log.push (.withdraw id, thread) }
      else state

/-- Flushes the diffs as the wait `id`, as `flush` flushes the files: the
diffs share the files' held completions. -/
def flushDiffs (files : FakeFiles) (id : UInt64) : BaseIO Unit :=
  files.flush id

/-- The fake of the diff port (`Job.Diffs`): the model of a line diff over
the snapshots this file service's model holds, so a job's load and its diff
see one table, as the library's two services do. -/
def diffs (files : FakeFiles) : Diffs :=
  { start := files.startDiff, take := files.takeDiff, cancel := files.cancelDiff,
    flush := files.flushDiffs }

/-- Starts the search `request` as the wait `id`, and completes the wait
unless completions are held, as a file request's is. -/
def startGrep (files : FakeFiles) (id : UInt64) (request : GrepRequest) : BaseIO Unit := do
  let thread ← IO.getTID
  let held ←
    files.state.modifyGet fun state =>
        let state :=
          { state with
            log := state.log.push (.grep id, thread)
            grepsPending := state.grepsPending.push id
            grepsStarted := state.grepsStarted.push (id, request) }
        if state.holding then (true, { state with parked := state.parked.push id })
        else (false, state)
  unless held do
    files.answer.complete files.completions id

/-- The model's answer to the search `request`, started as the wait `id`,
over the files and snapshots the model holds when it is taken: a start names
its search by its wait's id, as the library's service does. A request that
is not pending is refused as failed. -/
def takeGrep (files : FakeFiles) (id : UInt64) : (request : GrepRequest) → BaseIO request.Reply
  | .start root pattern overlays limits bound => do
    files.learnSources (overlays.map (·.2))
    files.state.modifyGet fun state =>
        if state.grepsPending.contains id then
          let state := { state with grepsPending := state.grepsPending.erase id }
          match state.greps.start state.model id.toNat root pattern overlays limits bound with
          | .ok greps => (.ok ⟨id.toNat⟩, { state with greps })
          | .error error => (.error error, state)
        else (.error (.failed "the request is not pending"), state)
  | .next search =>
    files.state.modifyGet fun state =>
      if state.grepsPending.contains id then
        let (reply, greps) := state.greps.read search.number
        (reply,
          { state with
            grepsPending := state.grepsPending.erase id, greps })
      else (.error (.failed "the request is not pending"), state)

/-- Withdraws the search wait `id`, if its request is pending, or cancels the
search `id`, if it is held. -/
def cancelGrep (files : FakeFiles) (id : UInt64) : BaseIO Unit := do
  let thread ← IO.getTID
  files.state.modify fun state =>
      let state :=
        if state.grepsPending.contains id then
          { state with
            grepsPending := state.grepsPending.erase id
            parked := state.parked.filter (· != id)
            withdrawn := state.withdrawn.push id
            log := state.log.push (.withdraw id, thread) }
        else state
      if state.greps.searches.any (·.id == id.toNat) then
        { state with
          greps := { state.greps with searches := state.greps.searches.filter (·.id != id.toNat) }
          grepsCancelled := state.grepsCancelled.push id
          log := state.log.push (.grepCancel id, thread) }
      else state

/-- Flushes the searches as the wait `id`, as `flush` flushes the files: the
model's searches are worked in the call that takes them, so nothing runs
past a cancel, and the flush is completed at once, unless completions are
held, when it is parked behind them. -/
def flushGreps (files : FakeFiles) (id : UInt64) : BaseIO Unit :=
  files.flush id

/-- The fake of the grep port (`Job.Greps`): the model of project search over
the files and the snapshots this file service's model holds, so a job's load
and its search see one table, as the library's two services do. -/
def greps (files : FakeFiles) : Greps :=
  { start := files.startGrep, take := files.takeGrep, cancel := files.cancelGrep
    flush := files.flushGreps }

/-- Every search request ever started, each with its wait's id, oldest
first. -/
def grepsStarted (files : FakeFiles) : BaseIO (Array (UInt64 × GrepRequest)) :=
  return (← files.state.get).grepsStarted

/-- How many searches the fake holds: started and neither ended nor
cancelled. -/
def searching (files : FakeFiles) : BaseIO Nat :=
  return (← files.state.get).greps.searches.size

/-- The searches cancelled while held, oldest first. -/
def grepsCancelled (files : FakeFiles) : BaseIO (Array UInt64) :=
  return (← files.state.get).grepsCancelled

/-- Every diff ever started, each with its wait's id, oldest first. -/
def diffsStarted (files : FakeFiles) : BaseIO (Array (UInt64 × DiffRequest)) :=
  return (← files.state.get).diffsStarted

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

/-- Every order that changed what the service holds, in arrival order, each
with the thread that handed it (`State.log`). -/
def log (files : FakeFiles) : BaseIO (Array (Order × UInt64)) :=
  return (← files.state.get).log

/-- A promise resolved once at least `count` requests have been started: at
once if they already have, else in the start that makes the count. What a
check waits on for a start made on a job's thread, in place of polling
`started`. -/
def startsArrivedAt (files : FakeFiles) (count : Nat) : BaseIO (IO.Promise Unit) := do
  let promise ← IO.Promise.new
  let reached ←
    files.state.modifyGet fun state =>
        if state.started.size ≥ count then (true, state)
        else (false, { state with startArrivals := state.startArrivals.push (count, promise) })
  if reached then
    promise.resolve ()
  return promise

/-- Whether nothing of the service is in flight: no request pending, no
completion parked. -/
def quiescent (files : FakeFiles) : BaseIO Bool := do
  let state ← files.state.get
  return state.pending.isEmpty && state.parked.isEmpty && state.diffsPending.isEmpty &&
      state.grepsPending.isEmpty

end FakeFiles

/-- One thing a fake process service was handed, in its log. -/
inductive FakeProcesses.Order where
  /-- A request started as the wait `id`. -/
  | start (id : UInt64) (request : ProcessRequest)
  /-- A flush of the processes as the wait `id`. -/
  | flush (id : UInt64)
  /-- The wait `id` withdrawn while its request was pending. -/
  | withdraw (id : UInt64)
  /-- The streaming child `id` killed. -/
  | kill (id : UInt64)
  /-- The streaming child `id` handed over to a package's crate
  (`FakeProcesses.handOff`). -/
  | handOff (id : UInt64)

/-- How a child handed over to a package's crate ended, as its consumer's
last pull says (`FakeProcesses.handOff`): it exited, or it was cancelled,
killed with its job. -/
inductive FakeProcesses.Ending where
  /-- The child exited so, and every line was delivered. -/
  | exited (exit : Process.Exit)
  /-- The child was cancelled: its job ended, or the job's cancel reached it. -/
  | cancelled
  deriving DecidableEq, Repr

/-- What the consumer of a child handed over to it read at the child's end
(`FakeProcesses.handOff`): the lines of its standard output not yet taken,
and how it ended. -/
structure FakeProcesses.Handed where
  /-- The lines, each without its line feed. -/
  lines : Array String
  /-- How the child ended. -/
  ended : FakeProcesses.Ending
  deriving DecidableEq, Repr

/-- Why a hand-off was refused (`FakeProcesses.handOff`), as
`editor_service::stream::take_over` refuses one. -/
inductive FakeProcesses.Refusal where
  /-- No live child has this number: none started, or its end was taken. -/
  | noSuchChild
  /-- A read of the job's is pending on the child. -/
  | readPending
  /-- The child was handed over already. -/
  | taken
  deriving DecidableEq, Repr

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
  /-- The thread that started each request of `started`. -/
  startThreads : Array UInt64 := #[]
  /-- Every order that changed what the service holds, in arrival order,
  each with the thread that handed it: starts, flushes, withdrawals of a
  pending wait and kills of a streaming child. A cancel of an id it does not
  hold is not logged. -/
  log : Array (FakeProcesses.Order × UInt64) := #[]
  /-- The children handed over and not yet ended, oldest first, each with
  what is told its end (`handOff`). -/
  handedOff : Array (UInt64 × (FakeProcesses.Handed → BaseIO Unit)) := #[]

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
- `handOff` hands a streaming child over to a package's crate, as
  `editor_service::stream::take_over` does, by its rules: it refuses a
  child that is not live (`noSuchChild`), one with a read of the job's
  pending (`readPending`) and one handed over already (`taken`). From then
  on the job's read, write and close of the child are `noSuchProcess`, and
  the child's end is told to the consumer's `onEnd`, on the thread that
  ends it: a kill (`cancel`) tells it the lines not yet taken and
  `cancelled`; a child that had exited before its hand-off tells it at the
  hand-off its lines and its exit, and is forgotten, as the consumer's last
  pull forgets one. Nothing else moves a handed child, so one that pauses
  is held until it is killed.
- `ran` is told the command of every run it takes, after the run: a test
  connects it to what the run changes, so that the fake watch service sees
  a job's command change the disk (`FakeFileWatches.ran`). By default it
  does nothing.

It records what was started, withdrawn and taken. -/
structure FakeProcesses where
  /-- The table the service completes its waits through. -/
  completions : Completions
  /-- What is told the command of each run, once it has run. -/
  ran : Process.Command → BaseIO Unit
  /-- What the service holds. Every change to it is one atomic step. -/
  state : IO.Ref FakeProcesses.State
  /-- How it answers: at once, or on the check's step through a fake pump
  (`FakeAnswer.onStep`). -/
  answer : FakeAnswer := .atOnce

namespace FakeProcesses

/-- The lines of `child`'s standard output not yet taken, each without its
line feed, a last partial line among them, read as UTF-8. -/
def linesOf (child : ProcessModel.Child) : Array String :=
  let (lines, rest) := ProcessModel.Child.splitLines child.stdout
  let lines := if rest.size > 0 then lines.push rest else lines
  lines.map fun line => (String.fromUTF8? line).getD ""

/-- A process service over `model`, through the table `completions`, with no
request started, which tells `ran` the command of each run once it has
run. -/
def new (completions : Completions) (model : ProcessModel := {})
    (ran : Process.Command → BaseIO Unit := fun _ => pure ()) (answer : FakeAnswer := .atOnce) :
    BaseIO FakeProcesses :=
  return { completions, ran, state := ← IO.mkRef { model }, answer }

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
    processes.answer.complete processes.completions id

/-- Starts `request` as the wait `id`, and completes the wait unless
completions are held. -/
def start (processes : FakeProcesses) (id : UInt64) (request : ProcessRequest) : BaseIO Unit := do
  let thread ← IO.getTID
  let held ←
    processes.state.modifyGet fun state =>
        let state :=
          { state with
            pending := state.pending.push (id, request)
            started := state.started.push (id, request)
            startThreads := state.startThreads.push thread
            log := state.log.push (.start id request, thread) }
        if state.holding then (true, { state with parked := state.parked.push id })
        else (false, state)
  unless held do
    processes.answer.complete processes.completions id

/-- The model's answer to `request`, which was started as the wait `id`, and
the request is pending no longer. A request that is not pending, because it
was withdrawn or never started, is refused as failed and changes nothing. -/
def take (processes : FakeProcesses) (id : UInt64) (request : ProcessRequest) :
    BaseIO request.Reply := do
  let (reply, ran) ←
    processes.state.modifyGet fun state =>
        -- A child handed over is the consumer's: the job reaches it no
        -- more, as the library's service refuses it.
        let handed :=
          match request with
          | .read child | .write child _ | .closeInput child =>
            state.handedOff.any (·.1 == child.number.toUInt64)
          | _ => false
        if handed && state.pending.any (·.1 == id) then
          ((request.refused .noSuchProcess, false),
            { state with
              pending := state.pending.filter (·.1 != id), taken := state.taken.push id })
        else
          if state.pending.any (·.1 == id) then
            -- A child is named by the wait of its start, as the library's is.
            let model :=
              if let .start .. := request then { state.model with next := id.toNat }
              else state.model
            let (reply, model, _) := model.handle 0 none request
            ((reply, true),
              { state with
                model, pending := state.pending.filter (·.1 != id), taken := state.taken.push id })
          else ((request.refused (.failed "the request is not pending"), false), state)
  if ran then
    match request with
    | .run command _ | .runWithin command _ _ | .runInput command _ _ _ | .runHead command _ _ _ =>
      processes.ran command
    | _ =>
      pure ()
  return reply

/-- Withdraws the wait `id`, if its request is pending: it is never
completed here and never runs. Or, if `id` names a streaming child of the
model's, ends it as the library kills one: the model records it as killed
and forgets it. -/
def cancel (processes : FakeProcesses) (id : UInt64) : BaseIO Unit := do
  let thread ← IO.getTID
  let told ←
    processes.state.modifyGet fun state =>
        if state.pending.any (·.1 == id) then
          (none,
            { state with
              pending := state.pending.filter (·.1 != id)
              parked := state.parked.filter (· != id)
              withdrawn := state.withdrawn.push id
              log := state.log.push (.withdraw id, thread) })
        else
          match state.model.children.find? (·.id == id.toNat) with
          | some child =>
            -- A child handed over tells its consumer it was cancelled, with
            -- the lines it had not taken.
            let told :=
              (state.handedOff.find? (·.1 == id)).map fun (_, onEnd) =>
                (onEnd, { lines := FakeProcesses.linesOf child, ended := .cancelled : Handed })
            (told,
              { state with
                model := state.model.kill id.toNat, withdrawn := state.withdrawn.push id
                log := state.log.push (.kill id, thread)
                handedOff := state.handedOff.filter (·.1 != id) })
          | none => (none, state)
  if let some (onEnd, handed) := told then
    onEnd handed

/-- Hands the streaming child `child` over to a package's crate, as
`editor_service::stream::take_over` does, and tells `onEnd` its end, on the
thread that ends it (the rules are in `FakeProcesses`' doc): refused as
`noSuchChild` for a child that is not live, `readPending` while a read of
the job's is pending on it, and `taken` once handed over. A child that had
exited is told at once, here, with its lines and its exit, and forgotten. -/
def handOff (processes : FakeProcesses) (child : UInt64) (onEnd : Handed → BaseIO Unit) :
    BaseIO (Except Refusal Unit) := do
  let thread ← IO.getTID
  let decided : Except Refusal (Option Handed) ←
    processes.state.modifyGet fun state =>
        let pending :=
          state.pending.any fun (_, request) =>
            match request with
            | .read read => read.number.toUInt64 == child
            | _ => false
        if state.handedOff.any (·.1 == child) then (.error .taken, state)
        else
          if pending then (.error .readPending, state)
          else
            match state.model.children.find? (·.id == child.toNat) with
            | none => (.error .noSuchChild, state)
            | some found =>
              let log := state.log.push (.handOff child, thread)
              if found.done then
                -- Exited before it was handed over: the consumer's first pull
                -- is its last, and the service forgets it.
                (.ok
                    (some
                      ({ lines := linesOf found, ended := .exited found.script.exit } : Handed)),
                  { state with
                    log,
                    model :=
                      { state.model with
                        children := state.model.children.filter (·.id != child.toNat) } })
              else
                (.ok none,
                  { state with
                    log, handedOff := state.handedOff.push (child, onEnd) })
  match decided with
  | .error refusal =>
    return .error refusal
  | .ok (some handed) =>
    onEnd handed
    return .ok ()
  | .ok none =>
    return .ok ()

/-- The children handed over and not yet ended, oldest first. -/
def handed (processes : FakeProcesses) : BaseIO (Array UInt64) :=
  return (← processes.state.get).handedOff.map (·.1)

/-- Flushes the processes as the wait `id`: completed at once, unless
completions are held, when it is parked behind them and `letGo` completes it
after every wait held before it. -/
def flush (processes : FakeProcesses) (id : UInt64) : BaseIO Unit := do
  let thread ← IO.getTID
  let held ←
    processes.state.modifyGet fun state =>
        let state := { state with log := state.log.push (.flush id, thread) }
        if state.holding then (true, { state with parked := state.parked.push id })
        else (false, state)
  unless held do
    processes.answer.complete processes.completions id

/-- The service as the port the runner is given. -/
def processes (processes : FakeProcesses) : Processes :=
  { start := processes.start, take := processes.take, cancel := processes.cancel,
    flush := processes.flush }

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

/-- The thread that started each request of `started`. -/
def startThreads (processes : FakeProcesses) : BaseIO (Array UInt64) :=
  return (← processes.state.get).startThreads

/-- Every order that changed what the service holds, in arrival order, each
with the thread that handed it (`State.log`). -/
def log (processes : FakeProcesses) : BaseIO (Array (Order × UInt64)) :=
  return (← processes.state.get).log

/-- Whether nothing of the service is in flight: no request pending, no
completion parked. -/
def quiescent (processes : FakeProcesses) : BaseIO Bool := do
  let state ← processes.state.get
  return state.pending.isEmpty && state.parked.isEmpty

end FakeProcesses

/-- One thing a fake package service was handed or told, in its log
(`FakePackageService.log`). -/
inductive FakePackageService.Order where
  /-- A request started as the wait `id`. -/
  | start (id : UInt64) (request : PackageRequest)
  /-- The reply of the wait `id` taken. -/
  | take (id : UInt64)
  /-- The wait `id` withdrawn while its request was pending. -/
  | withdraw (id : UInt64)
  /-- A flush of the service as the wait `id`. -/
  | flush (id : UInt64)
  /-- The consumer of the child the request `id` handed over read its last
  event (`FakeProcesses.handOff`): what it read. Told whether or not the
  request is still pending. -/
  | ended (id : UInt64) (read : FakeProcesses.Handed)

/-- How a fake package service answers a request that hands a child over to
its crate, as echo's `attach` does: which child a request hands over, and
the reply it answers once the consumer has read the child's end. -/
structure FakePackageService.HandOff where
  /-- The child `request` hands over, if it is such a request. -/
  child : (request : PackageRequest) → Option UInt64
  /-- The reply, from what the consumer read. -/
  reply : FakeProcesses.Handed → Dynamic

/-- What a fake package service is made of: what it answers, which a check
of a package's hands the stepped stage (`Stage.stepped`). -/
structure FakePackageService.Spec where
  /-- The service's name. -/
  name : String
  /-- What each request answers, the package's pure model. A request the
  model does not know is answered as `noSuchService` would be. -/
  model : PackageModel
  /-- How a request that hands a child over is answered; none for a service
  that takes no child. -/
  handOff : Option FakePackageService.HandOff := none

/-- What a fake package service holds. -/
structure FakePackageService.State where
  /-- The requests that were started and have been neither taken nor
  withdrawn, each with its wait's id, oldest first. -/
  pending : Array (UInt64 × PackageRequest) := #[]
  /-- The replies of pending hand-offs whose consumer has read the child's
  end, by wait. -/
  replies : Array (UInt64 × PackageReply) := #[]
  /-- Whether completions are held: one made while they are is not handed
  on until the test lets go. -/
  holding : Bool := false
  /-- The waits whose completion is held, oldest first. -/
  parked : Array UInt64 := #[]
  /-- Every order that changed what the service holds, and every end a
  consumer read, in arrival order, each with the thread that handed or told
  it. A cancel of an id it does not hold is not logged. -/
  log : Array (FakePackageService.Order × UInt64) := #[]

/-- The fake of a package's service (`PackageService`,
`Editor/PackageService.lean`), published for `model-test` and for the
packages' linked tests: a package's pure model behind a reference, so a
job's package requests run on the runner with no crate.

- `start` records the request and completes its wait: at once, or on the
  check's step through a fake pump (`FakeAnswer.onStep`), or, while the
  test holds completions (`holdCompletions`), when the test lets go
  (`letGo`).
- `take` answers from the model, once.
- A request that hands a child over (`Spec.handOff`) hands it to the fake
  process service (`FakeProcesses.handOff`), as a crate takes a child over:
  its start is refused when the hand-off is, and it completes once the
  consumer has read the child's end, with the reply made of what it read.
  The end is logged whether or not the request is still pending; a request
  withdrawn first posts no completion and keeps nothing, as a crate's
  cancelled request does.
- `cancel` withdraws a request that was started and not taken, and is safe
  for any id.
- `flush` completes once every completion held before it has been let go,
  behind them, as a crate's flush is queued behind the replies it covers. A
  hand-off whose child lives is not waited for.

It logs every order with the thread that handed it, and says when it holds
nothing in flight (`quiescent`). -/
structure FakePackageService where
  /-- What it answers. -/
  spec : FakePackageService.Spec
  /-- The table the service completes its waits through. -/
  completions : Completions
  /-- The fake process service a hand-off takes its child from; none for a
  service that takes no child. -/
  processes : Option FakeProcesses := none
  /-- How it answers: at once, or on the check's step through a fake pump
  (`FakeAnswer.onStep`). -/
  answer : FakeAnswer := .atOnce
  /-- What the service holds. Every change to it is one atomic step. -/
  state : IO.Ref FakePackageService.State

namespace FakePackageService

/-- A fake service of `spec`, through the table `completions`, answering as
`answer` says, its hand-offs taken from `processes`. -/
def new (completions : Completions) (spec : Spec) (processes : Option FakeProcesses := none)
    (answer : FakeAnswer := .atOnce) : BaseIO FakePackageService :=
  return { spec, completions, processes, answer, state := ← IO.mkRef {} }

/-- Holds every completion from now on: one made from now is not handed on
until `letGo`. So a check can act while a job is in a package wait whose
reply is ready. -/
def holdCompletions (service : FakePackageService) : BaseIO Unit :=
  service.state.modify fun state => { state with holding := true }

/-- Completes every wait whose completion is held, oldest first, and holds
none from now on. -/
def letGo (service : FakePackageService) : BaseIO Unit := do
  let parked ←
    service.state.modifyGet fun state =>
        (state.parked,
          { state with
            holding := false, parked := #[] })
  for id in parked do
    service.answer.complete service.completions id

/-- Completes the wait `id` unless completions are held, when it is parked. -/
private def complete (service : FakePackageService) (id : UInt64) : BaseIO Unit := do
  let held ←
    service.state.modifyGet fun state =>
        if state.holding then (true, { state with parked := state.parked.push id })
        else (false, state)
  unless held do
    service.answer.complete service.completions id

/-- What the consumer of the child the request `id` handed over read at its
end: logged, and, while the request is pending, its reply held and its wait
completed. -/
private def ended (service : FakePackageService) (handOff : HandOff) (id : UInt64)
    (read : FakeProcesses.Handed) : BaseIO Unit := do
  let thread ← IO.getTID
  let pending ←
    service.state.modifyGet fun state =>
        let state := { state with log := state.log.push (.ended id read, thread) }
        if state.pending.any (·.1 == id) then
          (true, { state with replies := state.replies.push (id, .ok (handOff.reply read)) })
        else (false, state)
  if pending then
    service.complete id

/-- Starts `request` as the wait `id`: a hand-off hands its child over and
completes once the consumer has read its end, refused when the hand-off is;
any other request completes now, unless completions are held. -/
def start (service : FakePackageService) (id : UInt64) (request : PackageRequest) : BaseIO Bool :=
  do
  let thread ← IO.getTID
  service.state.modify fun state =>
      { state with
        pending := state.pending.push (id, request)
        log := state.log.push (.start id request, thread) }
  let handed? := service.spec.handOff.bind fun handOff => (handOff.child request).map (handOff, ·)
  match handed?, service.processes with
  | some (handOff, child), some processes =>
    match ← processes.handOff child (service.ended handOff id) with
    | .ok () =>
      return true
    | .error _ =>
      service.state.modify fun state => { state with pending := state.pending.filter (·.1 != id) }
      return false
  | some _, none =>
    -- A hand-off with no process service to take a child from.
    service.state.modify fun state => { state with pending := state.pending.filter (·.1 != id) }
    return false
  | none, _ =>
    service.complete id
    return true

/-- The reply to `request`, which was started as the wait `id`: a
hand-off's, made of what its consumer read, or the model's. A request that
is not pending is refused. -/
def take (service : FakePackageService) (id : UInt64) (request : PackageRequest) :
    BaseIO PackageReply := do
  let thread ← IO.getTID
  service.state.modifyGet fun state =>
      if state.pending.any (·.1 == id) then
        let reply :=
          ((state.replies.find? (·.1 == id)).map (·.2)).getD (service.spec.model.answer request)
        (reply,
          { state with
            pending := state.pending.filter (·.1 != id)
            replies := state.replies.filter (·.1 != id)
            log := state.log.push (.take id, thread) })
      else (.error (.refused "the request is not pending"), state)

/-- Withdraws the wait `id`, if its request is pending: it is never
completed here, and its reply is dropped. A hand-off's consumer still reads
its child to the end, and that end completes nothing. -/
def cancel (service : FakePackageService) (id : UInt64) : BaseIO Unit := do
  let thread ← IO.getTID
  service.state.modify fun state =>
      if state.pending.any (·.1 == id) then
        { state with
          pending := state.pending.filter (·.1 != id)
          replies := state.replies.filter (·.1 != id)
          parked := state.parked.filter (· != id)
          log := state.log.push (.withdraw id, thread) }
      else state

/-- Flushes the service as the wait `id`: completed behind every completion
held before it, when they are let go, and at once otherwise. -/
def flush (service : FakePackageService) (id : UInt64) : BaseIO Unit := do
  let thread ← IO.getTID
  service.state.modify fun state => { state with log := state.log.push (.flush id, thread) }
  service.complete id

/-- The service as the port the runner is given. -/
def service (fake : FakePackageService) : PackageService :=
  { name := fake.spec.name, start := fake.start, take := fake.take, cancel := fake.cancel
    flush := fake.flush }

/-- How many requests are pending: started, and neither taken nor
withdrawn. -/
def waiting (service : FakePackageService) : BaseIO Nat :=
  return (← service.state.get).pending.size

/-- Every order the service was handed and every end a consumer read, in
arrival order, each with the thread that handed or told it
(`State.log`). -/
def log (service : FakePackageService) : BaseIO (Array (Order × UInt64)) :=
  return (← service.state.get).log

/-- Whether nothing of the service is in flight: no request pending, no
reply held, no completion parked. -/
def quiescent (service : FakePackageService) : BaseIO Bool := do
  let state ← service.state.get
  return state.pending.isEmpty && state.replies.isEmpty && state.parked.isEmpty

end FakePackageService

/-- What a package's own fake of its service makes (`PackageFake.make`): the
service the runner is given, and whether it holds nothing in flight. -/
structure PackageFake.Made where
  /-- The service, as the runner reaches it. -/
  service : PackageService
  /-- Whether it holds nothing in flight: a stage holding a request of it is
  not quiescent. -/
  quiescent : BaseIO Bool

/-- A package's own fake of its service, which a check hands the stepped
stage (`Stage.stepped`, `SteppedServices.new`) beside the fakes of specs
(`FakePackageService.Spec`): made over the stepped services' table of waits
and their pump, so each of its completions is a step of the check's. Where a
spec's model is a pure function of the request, a package's own fake keeps
state, so it may hold a request until an order of the check's, or of
another job, makes its reply, as a session's long poll waits for its
agent's next events (`agents-api`'s fake). -/
structure PackageFake where
  /-- The service's name. -/
  name : String
  /-- Makes the fake over the stepped services' table, completing each wait
  as `FakeAnswer` says: through the pump, on the check's step. -/
  make : Completions → FakeAnswer → BaseIO PackageFake.Made

/-- One thing a fake watch service was handed, in its log. -/
inductive FakeFileWatches.Order where
  /-- A request started as the wait `id`. -/
  | start (id : UInt64) (request : FileWatchRequest)
  /-- A flush of the watches as the wait `id`. -/
  | flush (id : UInt64)
  /-- The wait or the watch `id` withdrawn. -/
  | withdraw (id : UInt64)

/-- What a fake watch service holds. -/
structure FakeFileWatches.State where
  /-- Every order that changed what the service holds, in arrival order,
  each with the thread that handed it: starts, flushes, withdrawals of a
  pending wait and ends of a watch. A cancel of an id it does not hold is
  not logged. -/
  log : Array (FakeFileWatches.Order × UInt64) := #[]
  /-- What the watches see. -/
  model : FileWatchModel := {}
  /-- The requests that were started and have been neither taken nor
  withdrawn, each with its wait's id, oldest first. -/
  pending : Array (UInt64 × FileWatchRequest) := #[]
  /-- The `next` waits that are pending and not yet completed: their watch
  had nothing recorded. -/
  parked : Array (UInt64 × Nat) := #[]
  /-- Every request ever started, each with its wait's id, oldest first. -/
  started : Array (UInt64 × FileWatchRequest) := #[]
  /-- The waits withdrawn while pending, and the watches ended, oldest
  first. -/
  withdrawn : Array UInt64 := #[]
  /-- The waits whose replies were taken, oldest first. -/
  taken : Array UInt64 := #[]

/-- The fake of the file-watch port (`Job.FileWatches`,
`Editor/Job/Runner.lean`): the pure model of watches
(`Editor/FileWatch/Model.lean`) behind a reference. It is published for
`model-test` and `config-test`, so the job port's watch requests run on the
runner with no library and no file.

- `start` of a start records it and completes its wait at once; `take`
  answers from the model, which names the watch by the wait's id, as the
  library does.
- `start` of a `next` completes its wait as soon as the watch has a change
  recorded: at once if it has one, or when `change`, `touch` or `ran`
  records one. It does not apply the window: the window is pinned by the
  model's checks (`ModelTest.fileWatchModelChecks`) and by the library's
  tests in Rust, and a test of the fake waits on no clock for it. A `next`
  of a watch the model does not have completes at once, and its take is
  `noSuchWatch`.
- `cancel` withdraws a request that was started and not taken, and is safe
  for any id. Of the id of a watch, it ends the watch in the model, as the
  library's service drops a registration, and records the id as
  withdrawn.
- `ran` records what a command changes on disk (`FileWatchModel.effects`),
  for `FakeProcesses.ran`.

It records what was started, withdrawn, taken and ended, and how many
watches are up. -/
structure FakeFileWatches where
  /-- The table the service completes its waits through. -/
  completions : Completions
  /-- What the service holds. Every change to it is one atomic step. -/
  state : IO.Ref FakeFileWatches.State
  /-- How it answers: at once, or on the check's step through a fake pump
  (`FakeAnswer.onStep`). A job in a parked `next` holds no unit either way
  (`FileWatches.outside`). -/
  answer : FakeAnswer := .atOnce

namespace FakeFileWatches

/-- A watch service over `model`, through the table `completions`, with no
request started. -/
def new (completions : Completions) (model : FileWatchModel := {})
    (answer : FakeAnswer := .atOnce) : BaseIO FakeFileWatches :=
  return { completions, state := ← IO.mkRef { model }, answer }

/-- Whether the model's watch `watch` has a change recorded, or is not
there: a `next` of it can be answered. -/
def answerable (model : FileWatchModel) (watch : Nat) : Bool :=
  match model.watches.find? (·.id == watch) with
  | some found => !found.changes.isEmpty
  | none => true

/-- Starts `request` as the wait `id`, and completes the wait when it can be
taken. -/
def start (watches : FakeFileWatches) (id : UInt64) (request : FileWatchRequest) : BaseIO Unit := do
  let thread ← IO.getTID
  let now ←
    watches.state.modifyGet fun state =>
        let state :=
          { state with
            log := state.log.push (.start id request, thread)
            pending := state.pending.push (id, request)
            started := state.started.push (id, request) }
        match request with
        | .start .. => (true, state)
        | .next watch =>
          if answerable state.model watch.number then (true, state)
          else (false, { state with parked := state.parked.push (id, watch.number) })
  if now then
    watches.answer.complete watches.completions id

/-- Completes every parked `next` whose watch can now be answered. -/
def wake (watches : FakeFileWatches) : BaseIO Unit := do
  let due ←
    watches.state.modifyGet fun state =>
        let (due, parked) := state.parked.partition fun (_, watch) => answerable state.model watch
        (due, { state with parked })
  for (id, _) in due do
    watches.answer.complete watches.completions id

/-- Records `changes` in the model, and completes each `next` that can now be
answered. -/
def touch (watches : FakeFileWatches) (changes : Array (System.FilePath × FileWatch.Kind)) :
    BaseIO Unit := do
  watches.state.modify fun state => { state with model := state.model.touch changes 0 }
  watches.wake

/-- Records the change of `path` with each of `kinds`: for a test. -/
def change (watches : FakeFileWatches) (path : System.FilePath) (kinds : Array FileWatch.Kind) :
    BaseIO Unit :=
  watches.touch (kinds.map (path, ·))

/-- Records what a run of `command` changes on disk, as the model's effects
say. -/
def ran (watches : FakeFileWatches) (command : Process.Command) : BaseIO Unit := do
  let changes := (← watches.state.get).model.effectsOf command
  watches.touch changes

/-- The model's answer to `request`, which was started as the wait `id`, and
the request is pending no longer. A request that is not pending is refused
as failed and changes nothing. -/
def take (watches : FakeFileWatches) (id : UInt64) (request : FileWatchRequest) :
    BaseIO request.Reply :=
  watches.state.modifyGet fun state =>
    if state.pending.any (·.1 == id) then
      -- A watch is named by the wait of its start, as the library's is.
      let model :=
        if let .start .. := request then { state.model with next := id.toNat } else state.model
      let (reply, model, _) := model.handle 0 none request
      (reply,
        { state with
          model, pending := state.pending.filter (·.1 != id), taken := state.taken.push id })
    else (request.refused (.failed "the request is not pending"), state)

/-- Withdraws the wait `id`, if its request is pending; or, if `id` names a
watch of the model's, ends it as the library drops one. -/
def cancel (watches : FakeFileWatches) (id : UInt64) : BaseIO Unit := do
  let thread ← IO.getTID
  watches.state.modify fun state =>
      if state.pending.any (·.1 == id) then
        { state with
          pending := state.pending.filter (·.1 != id)
          parked := state.parked.filter (·.1 != id)
          withdrawn := state.withdrawn.push id
          log := state.log.push (.withdraw id, thread) }
      else
        if state.model.watches.any (·.id == id.toNat) then
          { state with
            model := state.model.endWatch id.toNat, withdrawn := state.withdrawn.push id
            log := state.log.push (.withdraw id, thread) }
        else state

/-- Flushes the watches as the wait `id`: completed at once, since the fake
completes every start at once. -/
def flush (watches : FakeFileWatches) (id : UInt64) : BaseIO Unit := do
  let thread ← IO.getTID
  watches.state.modify fun state => { state with log := state.log.push (.flush id, thread) }
  watches.answer.complete watches.completions id

/-- The service as the port the runner is given. -/
def fileWatches (watches : FakeFileWatches) : FileWatches :=
  { start := watches.start, take := watches.take, cancel := watches.cancel, flush := watches.flush
    outside := true }

/-- The model as it is now. -/
def model (watches : FakeFileWatches) : BaseIO FileWatchModel :=
  return (← watches.state.get).model

/-- How many watches are up: started and not ended. -/
def watching (watches : FakeFileWatches) : BaseIO Nat :=
  return (← watches.state.get).model.watches.size

/-- Every watch ended, by its id, oldest first. -/
def ended (watches : FakeFileWatches) : BaseIO (Array Nat) :=
  return (← watches.state.get).model.ended

/-- How many requests are pending: started, and neither taken nor
withdrawn. -/
def waiting (watches : FakeFileWatches) : BaseIO Nat :=
  return (← watches.state.get).pending.size

/-- Every request ever started, each with its wait's id, oldest first. -/
def started (watches : FakeFileWatches) : BaseIO (Array (UInt64 × FileWatchRequest)) :=
  return (← watches.state.get).started

/-- The waits withdrawn while pending, and the watches ended, oldest first. -/
def withdrawn (watches : FakeFileWatches) : BaseIO (Array UInt64) :=
  return (← watches.state.get).withdrawn

/-- The waits whose replies were taken, oldest first. -/
def taken (watches : FakeFileWatches) : BaseIO (Array UInt64) :=
  return (← watches.state.get).taken

/-- Every order that changed what the service holds, in arrival order, each
with the thread that handed it (`State.log`). -/
def log (watches : FakeFileWatches) : BaseIO (Array (Order × UInt64)) :=
  return (← watches.state.get).log

/-- Whether nothing of the service is in flight: no request pending. -/
def quiescent (watches : FakeFileWatches) : BaseIO Bool :=
  return (← watches.state.get).pending.isEmpty

end FakeFileWatches

/-- The fake of the grammar port (`Job.Grammars`): the pure model of the
registry (`Editor/SyntaxTree/Registration/Model.lean`) behind a reference.

- A start answers the registration from the registry at once, records what
  it registers, keeps the answer under the wait's id, and completes the
  wait through the table of waits at once, on the thread that started it,
  as `Grammars.absent` does.
- A take hands the kept answer over once; an id with none kept is answered
  `failed`.
- A cancel drops the kept answer: the registration stays done, as the
  library's still works one it has queued.
- A flush completes at once: every registration is answered at its start.

Made with no table, the default, it refuses every registration
`unsupported`, as the library's real adapter does until it loads native
libraries. -/
structure FakeGrammars where private mk ::
  /-- The table of waits it completes through. -/
  completions : Completions
  /-- The registry, and the answers kept, by the wait's id. -/
  state : IO.Ref (GrammarRegistry × Std.HashMap UInt64 (Except GrammarError String))

namespace FakeGrammars

/-- A fake over `registry`, completing through `completions`. -/
def new (completions : Completions) (registry : GrammarRegistry := {}) : BaseIO FakeGrammars :=
  return ⟨completions, ← IO.mkRef (registry, {})⟩

/-- Answers `request` from the registry, keeps the answer as the wait
`id`'s, and completes the wait. -/
def start (fake : FakeGrammars) (id : UInt64) : GrammarRequest → BaseIO Unit
  | .register source => do
    fake.state.modify fun (registry, kept) =>
        let (answer, registry) := registry.register source
        (registry, kept.insert id (answer.mapError .refused))
    fake.completions.finish id .completed

/-- The answer kept for the wait `id`, taken out; `failed` when none is. -/
def take (fake : FakeGrammars) (id : UInt64) : (request : GrammarRequest) → BaseIO request.Reply
  | .register _ =>
    fake.state.modifyGet fun (registry, kept) =>
      (kept[id]?.getD (.error (.failed "the fake grammar service kept no answer")),
        (registry, kept.erase id))

/-- The grammar port over this fake. -/
def grammars (fake : FakeGrammars) : Grammars :=
  { start := fake.start, take := fake.take
    cancel := fun id => fake.state.modify fun (registry, kept) => (registry, kept.erase id)
    flush := fun id => fake.completions.finish id .completed }

/-- The registry as it is now. -/
def registry (fake : FakeGrammars) : BaseIO GrammarRegistry :=
  return (← fake.state.get).1

end FakeGrammars

/-- A hold of a fake recorder: the transitions it holds at, the promise
resolved with the first one to arrive, and the promise that lets it go. -/
structure FakeRecorder.Hold where
  /-- Which transitions it holds at. -/
  picks : Protocol.Transition → Bool
  /-- Resolved with the transition held, once a thread has arrived. -/
  arrived : IO.Promise Protocol.Transition
  /-- Resolved to let the held thread go. -/
  release : IO.Promise Unit

/-- What a fake recorder holds. -/
structure FakeRecorder.State where
  /-- Every transition recorded, in the order of the sections that applied
  them. -/
  trace : Array Protocol.Transition := #[]
  /-- Every transition told as applied, in the order the tells came. -/
  applied : Array Protocol.Transition := #[]
  /-- What checks wait for (`reached`): each with the promise resolved with
  the first transition told as applied that it picks. -/
  reaching : Array ((Protocol.Transition → Bool) × IO.Promise Protocol.Transition) := #[]
  /-- The holds at a tell of applied, not yet arrived at (`holdAt`). -/
  appliedHolds : Array FakeRecorder.Hold := #[]
  /-- The holds inside a section, at a record, not yet arrived at
  (`holdRecordAt`). -/
  recordHolds : Array FakeRecorder.Hold := #[]

/-- The fake of the recording port (`Job.Recorder`, `Editor/Job/Runner.lean`):
it keeps the trace of the transitions the runner records, in the order of
their sections, and lets a check wait for a transition to have been applied
(`reached`), or hold the thread that applies one, after its section
(`holdAt`) or inside it (`holdRecordAt`), until the check lets it go. A held
thread is held on a promise, never on time. A check that holds inside a
section holds the table's lock: it makes no call into the runner on that
table until it has let the hold go. -/
structure FakeRecorder where
  /-- What it holds. Every change to it is one atomic step. -/
  state : IO.Ref FakeRecorder.State

namespace FakeRecorder

/-- A recorder that has recorded nothing. -/
def new : BaseIO FakeRecorder :=
  return { state := ← IO.mkRef {} }

/-- Takes the first hold of `holds` that `transition` picks, if one does. -/
def takeHold (holds : Array Hold) (transition : Protocol.Transition) : Option Hold × Array Hold :=
  match holds.findIdx? (·.picks transition) with
  | some index => (holds[index]?, holds.eraseIdxIfInBounds index)
  | none => (none, holds)

/-- Parks the calling thread on `hold`, if there is one, once it has told
the check it arrived. -/
def park (hold : Option Hold) (transition : Protocol.Transition) : BaseIO Unit := do
  if let some hold := hold then
    hold.arrived.resolve transition
    discard <| IO.wait hold.release.result?

/-- Records `transition`, inside the section that applies it: appended to
the trace, then held if a hold inside a section picks it. -/
def record (recorder : FakeRecorder) (transition : Protocol.Transition) : BaseIO Unit := do
  let hold ←
    recorder.state.modifyGet fun state =>
        let (hold, recordHolds) := takeHold state.recordHolds transition
        (hold,
          { state with
            trace := state.trace.push transition, recordHolds })
  park hold transition

/-- Tells that `transition` has been applied, its section over: noted, each
wait it picks resolved, then held if a hold after a section picks it. -/
def applied (recorder : FakeRecorder) (transition : Protocol.Transition) : BaseIO Unit := do
  let (reached, hold) ←
    recorder.state.modifyGet fun state =>
        let (reached, reaching) := state.reaching.partition (·.1 transition)
        let (hold, appliedHolds) := takeHold state.appliedHolds transition
        ((reached, hold),
          { state with
            applied := state.applied.push transition, reaching, appliedHolds })
  for (_, promise) in reached do
    promise.resolve transition
  park hold transition

/-- The recorder as the port the runner is given. -/
def recorder (recorder : FakeRecorder) : Recorder :=
  { record := recorder.record, applied := recorder.applied }

/-- The transitions recorded so far, in the order of their sections. -/
def trace (recorder : FakeRecorder) : BaseIO (Array Protocol.Transition) :=
  return (← recorder.state.get).trace

/-- A task that ends with the first transition matching `picks` told as
applied, its section over: at once if one already has been. What a check
waits on, with a hang guard, for a step the runner takes on another
thread. -/
def reached (recorder : FakeRecorder) (picks : Protocol.Transition → Bool) :
    BaseIO (Task Protocol.Transition) := do
  let promise ← IO.Promise.new
  let already ←
    recorder.state.modifyGet fun state =>
        match state.applied.find? picks with
        | some transition => (some transition, state)
        | none => (none, { state with reaching := state.reaching.push (picks, promise) })
  if let some transition := already then
    promise.resolve transition
  return promise.result?.map (sync := true) (·.getD .loopEnd)

/-- Sets a hold at the transitions `picks` names, where `place` puts it,
and gives back the task of its arrival and the action that lets it go. -/
def hold (recorder : FakeRecorder) (picks : Protocol.Transition → Bool)
    (place : Hold → State → State) : BaseIO (Task Protocol.Transition × BaseIO Unit) := do
  let hold : Hold := { picks, arrived := ← IO.Promise.new, release := ← IO.Promise.new }
  recorder.state.modify (place hold)
  return (hold.arrived.result?.map (sync := true) (·.getD .loopEnd), hold.release.resolve ())

/-- Holds the thread that tells the first transition from now matching
`picks` as applied, after its section, until the action handed back is
run; the task ends once the thread has arrived. -/
def holdAt (recorder : FakeRecorder) (picks : Protocol.Transition → Bool) :
    BaseIO (Task Protocol.Transition × BaseIO Unit) :=
  recorder.hold picks fun hold state => { state with appliedHolds := state.appliedHolds.push hold }

/-- Holds the thread that records the first transition from now matching
`picks`, inside its section, with the table's lock held, until the action
handed back is run; the task ends once the thread has arrived. -/
def holdRecordAt (recorder : FakeRecorder) (picks : Protocol.Transition → Bool) :
    BaseIO (Task Protocol.Transition × BaseIO Unit) :=
  recorder.hold picks fun hold state => { state with recordHolds := state.recordHolds.push hold }

end FakeRecorder

end Editor.Job
