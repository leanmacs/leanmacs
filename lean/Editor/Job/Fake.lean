import Editor.Job.Runner

/-!
# The fake clock

The fake of the clock port (`Job.Timers`, `Editor/Job/Runner.lean`): a clock a
test moves by hand. It is published for `model-test` and `config-test`, so a
check of anything that waits controls time, and nothing sleeps to let
something happen.

- The clock reads 0 until `advance` moves it. `advance` completes every wait
  that is then due, earliest deadline first, through the table of waits it
  was made over.
- A wait started at or after its deadline completes at once, on the thread
  that started it.
- It records every wait started, with the thread that started it, and every
  wait withdrawn, and says how many are waiting. It records the threads that
  read it, too.

A wait that is withdrawn is forgotten: `advance` never completes it.
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

/-- Reads the clock, and records the thread that did. -/
def read (clock : FakeClock) : BaseIO Nat := do
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

end Editor.Job
