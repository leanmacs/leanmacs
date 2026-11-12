import Editor.Command.Append
import Editor.Config.Reload
import Editor.Job.Contract
import Editor.Job.Fake
import Editor.Job.Model
import Editor.Text.Contract

/-!
# The model tests

`lake test` builds and runs this executable (`mise run lean-test`). It links
no C glue and no Rust archive: everything here runs in Lean alone, against
hand-written fakes and the pure models of the editor's ports. With no
arguments it runs every check in `checks`, names the ones that failed, and
exits non-zero if any did.

The checks of the program type run programs over a small port of their own
(`Ask`) against a fake that records the requests it receives.

The text port's contract (`Editor/Text/Contract.lean`) is run against its pure
model here. `contract-test` runs the same list against the real binding.

A command is tested the same way: as a property, a command that returns
whether it held, run against the model (`commandProperties`). The `editor`
executable runs the same command source against the real binding.

The job system is tested here with no Rust library:

- `jobModelChecks`: the job port's pure model (`Editor/Job/Model.lean`), its
  clock and its cancellation, and what only the model's exact clock can
  show: that a timer does not drift;
- `waitChecks`: the table of waits and the fake clock, with no job;
- `runnerChecks`: the runner (`Editor/Job/Runner.lean`) over the fake clock
  (`Editor/Job/Fake.lean`). A check controls time by moving its own fake
  clock and holds a job on a promise it resolves; it sleeps for nothing, and
  polls only as the bound after which it fails.

The job port's contract (`Editor/Job/Contract.lean`) is run here against the
model and against the runner over the fake clock. `contract-test` runs the
same list against the runner over the Rust library's timer service.

The config session's decisions are tested here too, with no elaborator:

- `setupChecks`: what a `setup` registers, and when it is refused;
- `registryChecks`: the registry, replaced by owner;
- `storeChecks`: the rule that meets a new config's stores with the cells
  there are, one check for each case;
- `sessionChecks`: one reload (`Config.build`), on a fake elaborator that
  records every call and a fake source;
- `reloadChecks`: the reducer that serialises reloads, with outcomes built
  by hand. The phase's acceptance tests are here on fakes (reload replaces a
  command, a rejected reload keeps the old config, a reload does not
  double-register, a store value survives a reload), and `config-test` runs
  them again with the real elaborator, queue and text binding.
-/

namespace ModelTest

open Editor

/-- One behaviour, and how to observe it. -/
structure Check where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Observes the behaviour; `true` when it holds. -/
  run : IO Bool

/-- The requests of a small port, for the checks of the program type alone. -/
inductive Ask where
  /-- Asks the handler for a number. -/
  | number
  /-- Tells the handler `value`. -/
  | tell (value : Nat)
  deriving DecidableEq, Repr

/-- The reply to each request: a number for `number`, nothing for `tell`. -/
def Ask.Reply : Ask → Type
  | .number => Nat
  | .tell _ => Unit

/-- The port the checks of the program type run programs over. -/
abbrev askPort : Port :=
  { Request := Ask, Reply := Ask.Reply }

/-- A hand-written fake of the collaborator behind `askPort`. It records every
request it receives and answers `number` with canned numbers that count up. -/
structure Fake where
  /-- The requests received, oldest first. -/
  seen : Array Ask := #[]
  /-- The answer to the next `number` request. -/
  number : Nat

/-- The fake's answer to a request, and the fake after it. -/
def Fake.handle : (request : Ask) → Fake → request.Reply × Fake
  | .number, fake => (fake.number, { seen := fake.seen.push .number, number := fake.number + 1 })
  | .tell value, fake => ((), { fake with seen := fake.seen.push (.tell value) })

/-- `Fake.handle` as a handler in `IO`, over a fake held in a reference. -/
def Fake.handleIO (fake : IO.Ref Fake) (request : Ask) : IO request.Reply :=
  fake.modifyGet (Fake.handle request)

/-- The program that asks for one number. -/
def number : Program askPort Nat :=
  Program.request (port := askPort) .number

/-- The program that tells the handler `value`. -/
def tell (value : Nat) : Program askPort Unit :=
  Program.request (port := askPort) (.tell value)

/-- A program written with the constructors alone, so it needs no `bind`: it
asks for a number, tells the handler its successor, asks for a second number
and returns both in one value. What it tells depends on a reply. -/
def twoNumbers : Program askPort Nat :=
  .step .number fun (first : Nat) =>
    .step (.tell (first + 1)) fun _ =>
      .step .number fun (second : Nat) => .done (first * 100 + second)

/-- What a fake whose first number is 7 must have seen after `twoNumbers`. -/
def twoNumbersSeen : Array Ask :=
  #[.number, .tell 8, .number]

/-- Asks for `count` numbers in a `for` loop and returns their sum. -/
def sumOfNumbers (count : Nat) : Program askPort Nat := do
  let mut sum := 0
  for _ in [0:count] do
    sum := sum + (← number)
  return sum

/-- How many requests the loop checks make. -/
def million : Nat :=
  1000000

/-- The sum of the numbers a fake that starts at 0 gives to a million
requests: 0 + 1 + … + 999999. -/
def millionSum : Nat :=
  499999500000

/-- The checks of the program type and its two runners (`Editor/Program.lean`). -/
def programChecks : List Check :=
  [{
      name :=
        "run hands each request to the handler in order, each reply to its continuation, and returns the program's value",
      run :=
        let (value, fake) := twoNumbers.run Fake.handle { number := 7 }
        pure (value == 708 && fake.seen == twoNumbersSeen) },
    { name := "runM does the same against a handler in IO"
      run := do
        let fake ← IO.mkRef { number := 7 }
        let value ← twoNumbers.runM (Fake.handleIO fake)
        return value == 708 && (← fake.get).seen == twoNumbersSeen },
    { name := "x >>= f makes x's requests, then those of f applied to x's value"
      run :=
        let first : Program askPort Nat := do
          tell 1
          number
        let after (value : Nat) : Program askPort Nat := do
          tell (value * 2)
          return value + 1
        let (value, fake) := (first >>= after).run Fake.handle { number := 5 }
        pure (value == 6 && fake.seen == #[.tell 1, .number, .tell 10]) },
    { name := "a for loop of a million requests completes under run"
      run :=
        let (sum, fake) := (sumOfNumbers million).run Fake.handle { number := 0 }
        pure (sum == millionSum && fake.seen.size == million) },
    { name := "a for loop of a million requests completes under runM"
      run := do
        let fake ← IO.mkRef { number := 0 }
        let sum ← (sumOfNumbers million).runM (Fake.handleIO fake)
        return sum == millionSum && (← fake.get).seen.size == million }]

/-- How `job` ends when it runs against the job port's model from `model`, and
what the model's clock then reads. The clock is how a check sees which waits
a job made: only a wait moves it. -/
def modelled {α : Type} (job : JobM α) (model : JobModel := {}) : Job.Outcome α × Nat :=
  let (outcome, after) := job.runModel model
  (outcome, after.now)

/-- Five sleeps of 10 ms, each inside a handler that catches every error: a
job that would swallow a cancellation, were one ever delivered as an error. -/
def stubborn : JobM Unit := do
  for _ in [0:5] do
    try
      sleep 10
    catch _ =>
      pure ()

/-- The checks of the job port's pure model (`Editor/Job/Model.lean`). -/
def jobModelChecks : List Check :=
  [{
      name :=
        "in the job model, now reads the clock, sleep moves it by its duration, waitUntil a later instant sets it, and waitUntil a past instant leaves it",
      run :=
        let job : JobM (Nat × Nat × Nat × Nat) := do
          let start ← now
          sleep 5
          let slept ← now
          waitUntil 20
          let waited ← now
          waitUntil 3
          return (start, slept, waited, ← now)
        pure (modelled job { now := 2 } == (.finished (2, 7, 20, 20), 20)) },
    { name :=
        "in the job model, a job that throws ends failed with its message, at the instant it threw"
      run :=
        let job : JobM Nat := do
          sleep 4
          throw "no thanks"
        pure (modelled job == (.failed "no thanks", 4)) },
    { name :=
        "in the job model, with cancelAt inside a wait the job ends cancelled at that instant and makes no later request"
      run :=
        let job : JobM Nat := do
          sleep 10
          sleep 10
          sleep 10
          return 1
        -- A third sleep would leave the clock at 25 or later.
        pure (modelled job { cancelAt := some 15 } == (.cancelled, 15)) },
    { name :=
        "in the job model, a job that catches every error around each wait is still cancelled, in its first wait"
      run := pure (modelled stubborn { cancelAt := some 5 } == (.cancelled, 5)) },
    { name :=
        "in the job model, a job whose cancelAt has passed makes no request, and is cancelled whatever it would have returned"
      run :=
        let waits : JobM Nat := do
          sleep 10
          return 1
        pure
          (modelled waits { now := 5, cancelAt := some 3 } == (.cancelled, 5) &&
            modelled (pure 1 : JobM Nat) { now := 5, cancelAt := some 3 } == (.cancelled, 5)) },
    -- Not a property of the contract: it is an equality, which a real clock
    -- would fail, and the contract's inequality cannot see drift, because a
    -- timer that drifts ticks late, which is still "not before". Only a wait
    -- moves the model's clock, so the work between two ticks is a sleep
    -- shorter than the period.
    { name :=
        "in the job model, a timer does not drift: three ticks of a period of 10, with 3 ms of work after the first and the second, leave the clock at exactly 30"
      run :=
        let job : JobM Unit := do
          let timer ← Timer.every 10
          let timer ← timer.tick
          sleep 3
          let timer ← timer.tick
          sleep 3
          discard timer.tick
        pure (modelled job == (.finished (), 30)) },
    { name :=
        "a contract property whose job returns false, throws or is cancelled has not held, and each is named with how it ended"
      run := do
        let properties : List JobContract.Property :=
          [{ name := "holds", holds := pure true }, { name := "false", holds := pure false },
            { name := "throws", holds := throw "no thanks" },
            { name := "cancelled",
              holds := do
                sleep 10
                return true }]
        let failed ←
          JobContract.failures (fun job => pure (job.runModel { cancelAt := some 5 }).1) properties
        return failed ==
            ["false", "throws (the job failed with `no thanks`)",
              "cancelled (the job was cancelled)"] }]

/-- A command that makes one text holding `text`. What a registered command
does is observed by running it: commands are programs, and cannot be compared. -/
def makes (text : String) : EditorM Unit :=
  discard <| createText text

/-- The texts `command` leaves when it runs against a text model with none. -/
def textsOf (command : EditorM Unit) : Array String :=
  (command.runModel {}).2.texts

/-- How long a check waits, in milliseconds, for something that should happen
at once. Only broken code takes this long, and the check then fails instead
of hanging. -/
def patience : Nat :=
  5000

/-- Polls `condition` until it holds; `false` if it still does not after
`patience` milliseconds. The bound is only how long a check takes to fail:
what a check waits for is something it controls. -/
def eventually (condition : IO Bool) : IO Bool := do
  let deadline := (← IO.monoMsNow) + patience
  repeat
    if ← condition then
      return true
    if (← IO.monoMsNow) >= deadline then
      break
    IO.sleep 1
  return false

/-- How `wait` ended; `none` while it is in flight. -/
def ended (wait : IO.Promise Job.Completion) : BaseIO (Option Job.Completion) := do
  if ← wait.isResolved then
    return wait.result?.get
  else
    return none

/-- A table of waits and a fake clock over it: what a check of the job runner
works with. Each check has its own, so no check moves another's clock. -/
structure Rig where
  /-- The fake clock. -/
  clock : Job.FakeClock
  /-- The table of waits and the clock, as the runner is given them. -/
  services : Job.Services

/-- A rig whose clock reads 0 and has no waits. -/
def Rig.new : BaseIO Rig := do
  let completions ← Job.Completions.new
  let clock ← Job.FakeClock.new completions
  return { clock, services := { completions, timers := clock.timers } }

/-- Registers a wait in `rig`'s table and starts it at the clock for
`deadline`, as the runner does. `log` gets the wait's id when it ends,
on the thread that ended it, so the order of a log is the order the waits
ended in. -/
def Rig.wait (rig : Rig) (deadline : Nat) (log : IO.Ref (Array UInt64)) :
    BaseIO (UInt64 × IO.Promise Job.Completion) := do
  let (id, wait) ← rig.services.completions.register
  BaseIO.chainTask wait.result? (fun _ => log.modify (·.push id)) (sync := true)
  rig.services.timers.start id deadline
  return (id, wait)

/-- The checks of the table of waits and of the fake clock
(`Editor/Job/Runner.lean`, `Editor/Job/Fake.lean`), with no job. -/
def waitChecks : List Check :=
  [{
      name :=
        "the table of waits gives each wait an id of its own, from 1, and finish ends exactly that wait and forgets it",
      run := do
        let table ← Job.Completions.new
        let (first, firstWait) ← table.register
        let (second, secondWait) ← table.register
        table.finish first .completed
        return first == 1 && second == 2 && (← ended firstWait) == some .completed &&
            (← ended secondWait) == none &&
            (← table.waiting) == 1 },
    { name :=
        "a wait ends once: a second finish, and a finish for an id that is not waiting, change nothing, and no id is used again"
      run := do
        let table ← Job.Completions.new
        let (id, wait) ← table.register
        table.finish id .cancelled
        table.finish id .completed
        table.finish 99 .completed
        let (next, _) ← table.register
        return (← ended wait) == some .cancelled && next == id + 1 && (← table.waiting) == 1 },
    { name :=
        "the fake clock completes the waits that are due when it is advanced, earliest deadline first, and leaves the others waiting"
      run := do
        let rig ← Rig.new
        let log ← IO.mkRef #[]
        let (late, _) ← rig.wait 30 log
        let (early, _) ← rig.wait 10 log
        let (middle, _) ← rig.wait 20 log
        let (last, lastWait) ← rig.wait 40 log
        let before ← log.get
        rig.clock.advance 30
        let due ← log.get
        let waiting ← rig.clock.waiting
        let lastEnded ← ended lastWait
        rig.clock.advance 10
        return before.isEmpty && due == #[early, middle, late] && waiting == 1 &&
            lastEnded == none &&
            (← log.get) == #[early, middle, late, last] &&
            (← rig.clock.now) == 40 },
    { name := "the fake clock completes a wait started at or after its deadline at once"
      run := do
        let rig ← Rig.new
        let log ← IO.mkRef #[]
        rig.clock.advance 30
        let (now, nowWait) ← rig.wait 30 log
        let (past, pastWait) ← rig.wait 7 log
        return (← log.get) == #[now, past] && (← ended nowWait) == some .completed &&
            (← ended pastWait) == some .completed &&
            (← rig.clock.waiting) == 0 &&
            (← rig.clock.started) == #[(now, 30), (past, 7)] },
    { name :=
        "the fake clock records each wait started with the thread that started it, and each wait withdrawn, and never completes a withdrawn wait"
      run := do
        let rig ← Rig.new
        let log ← IO.mkRef #[]
        let (kept, _) ← rig.wait 10 log
        let (dropped, droppedWait) ← rig.wait 10 log
        rig.services.timers.cancel dropped
        -- Withdrawing a wait that is not waiting is not recorded.
        rig.services.timers.cancel 99
        rig.clock.advance 10
        return (← log.get) == #[kept] && (← ended droppedWait) == none &&
            (← rig.clock.started) == #[(kept, 10), (dropped, 10)] &&
            (← rig.clock.withdrawn) == #[dropped] &&
            (← rig.clock.startThreads) == #[← IO.getTID, ← IO.getTID] }]

/-- A job's outcome as a check compares it: the command it finished with is
replaced by the texts that command leaves, since commands cannot be compared. -/
def texts : Job.Outcome (EditorM Unit) → Job.Outcome (Array String)
  | .finished command => .finished (textsOf command)
  | .failed message => .failed message
  | .cancelled => .cancelled

/-- `job` as it is spawned by a check: it finishes with a command that makes
one text, the job's value as a string. -/
def reporting {α : Type} [ToString α] (job : Unit → JobM α) : Work :=
  Work.of job fun value => makes (toString value)

/-- A job a check spawned. -/
structure Spawned where
  /-- The job. -/
  handle : Job.Handle
  /-- How many times the runner has called the job's `finished`. -/
  finishes : IO.Ref Nat

namespace Spawned

/-- How the job ended, as a check compares it; `none` while it runs. -/
def outcome (spawned : Spawned) : BaseIO (Option (Job.Outcome (Array String))) :=
  return (← spawned.handle.outcome?).map texts

/-- Whether the job ended as `expected`, and the runner then said so once.
Waits for both, with a bound. -/
def endedAs (spawned : Spawned) (expected : Job.Outcome (Array String)) : IO Bool := do
  let ended ← eventually spawned.handle.ended
  -- The runner says a job has ended after it has left the outcome.
  let said ← eventually (return (← spawned.finishes.get) == 1)
  return ended && said && (← spawned.outcome) == some expected

end Spawned

/-- Spawns `work` on `rig`, counting the calls of its `finished`. -/
def Rig.spawn (rig : Rig) (work : Work) : BaseIO Spawned := do
  let finishes ← IO.mkRef 0
  return { handle := ← Job.spawn rig.services work (finishes.modify (· + 1)), finishes }

/-- Runs `job` on the runner over a fake clock of its own, and returns how it
ended. The driver stands in for time: while a wait is waiting it advances the
clock to the earliest deadline. A job that does not end in time has failed. -/
def runOnFake (job : JobM Bool) : IO (Job.Outcome Bool) := do
  let rig ← Rig.new
  let spawned ← rig.spawn (reporting fun _ => job)
  let ended ←
    eventually do
        if ← spawned.handle.ended then
          return true
        if let some deadline← rig.clock.nextDeadline then
          rig.clock.advance (deadline - (← rig.clock.now))
        return false
  unless ended do
    return .failed "the job did not end"
  match ← spawned.outcome with
  | some (.finished texts) =>
    return .finished (texts == #["true"])
  | some (.failed message) =>
    return .failed message
  | _ =>
    return .cancelled

/-- The names of the job port's contract properties that do not hold of the
runner over the fake clock. -/
def jobRunnerFailures : IO (List String) := do
  let failed ← JobContract.failures runOnFake JobContract.properties
  return failed.map (s!"the job runner over the fake clock: {·}")

/-- How many different thread ids `threads` holds. -/
def distinct (threads : Array UInt64) : Nat :=
  (threads.foldl (fun seen thread => if seen.contains thread then seen else seen.push thread)
      #[]).size

/-- The checks of the job runner (`Editor/Job/Runner.lean`), each on a fake
clock of its own. A check holds what it controls (the clock, a promise) and
polls only as the bound after which it fails. -/
def runnerChecks : List Check :=
  [{
      name :=
        "a job that runs to its end is finished with its command, a job that throws is failed with its message, and the runner says so once for each",
      run := do
        let rig ← Rig.new
        let ends ←
          rig.spawn
              (reporting fun _ => do
                sleep 2
                return 42)
        let throws ←
          rig.spawn fun _ => do
              sleep 2
              throw "no thanks"
        unless ← eventually (return (← rig.clock.waiting) == 2) do
          return false
        rig.clock.advance 2
        return (← ends.endedAs (.finished #["42"])) && (← throws.endedAs (.failed "no thanks")) },
    { name :=
        "100,000 now requests in one job are answered on one thread, and none of them registers a wait"
      run := do
        let rig ← Rig.new
        let reads ←
          rig.spawn
              (reporting fun _ => do
                let mut last := 0
                for _ in [0:100000] do
                  last ← now
                return last)
        let ended ← reads.endedAs (.finished #["0"])
        -- A request that needs no wait is a direct call on the job's thread:
        -- a runner that hopped to a task for each would read the clock from
        -- many threads.
        return ended && (← rig.clock.reads) == 100000 && (← rig.clock.readThreads).size == 1 &&
            (← rig.clock.started).isEmpty &&
            (← rig.services.completions.register).1 == 1 },
    { name :=
        "jobs blocked in waits do not delay a new pool task, and their waits hold no thread: more jobs than the pool has threads all reach their wait from fewer threads than there are jobs"
      run := do
        let rig ← Rig.new
        let count := max 64 ((System.Platform.Internal.getHardwareConcurrency ()).toNat + 1)
        let mut jobs := #[]
        for _ in [0:count] do
          jobs :=
            jobs.push
              (←
                rig.spawn
                    (reporting fun _ => do
                      sleep 1000
                      return true))
        try
          -- A runner that parked a thread in a system call for each wait
          -- would let only a pool's worth of jobs get this far.
          unless ← eventually (return (← rig.clock.waiting) == count) do
            return false
          let ran ← IO.Promise.new
          discard <| BaseIO.asTask (ran.resolve ())
          let notDelayed ← eventually ran.isResolved
          -- The clock has not moved, so every job is still in its wait.
          let allWaiting := (← rig.clock.waiting) == count && (← rig.clock.now) == 0
          let noneEnded ← jobs.allM fun job => return !(← job.handle.ended)
          -- A runner that parked each job in `IO.wait` would have had Lean add
          -- a thread for every one of them: as many threads as jobs.
          let threads := distinct (← rig.clock.startThreads)
          rig.clock.advance 1000
          let allFinished ← jobs.allM (·.endedAs (.finished #["true"]))
          return notDelayed && allWaiting && noneEnded && threads < count && allFinished
        finally
          rig.clock.advance 1000 }]

/-- The texts a registered command leaves when it is a plain command, run
against a text model with none; `none` for a command over a store. -/
def plainTexts : Config.Action → Option (Array String)
  | .plain run => some (textsOf run)
  | .store .. => none

/-- A store of one number, at version 1. -/
def counter : Store Nat :=
  { name := "counter", version := 1, initial := 0, encode := .nat,
    decode := fun
      | .nat n => some n
      | _ => none }

/-- The message a `setup` was refused with, if it was. -/
def refusal (setup : SetupM Unit) : Option String :=
  match Config.Registrations.ofSetup setup with
  | .error message => some message
  | .ok _ => none

/-- The checks of `setup`: a program over the setup port (`Editor/Setup.lean`),
run against the handler that collects what it registers
(`Editor/Config/Registry.lean`). -/
def setupChecks : List Check :=
  [{
      name :=
        "running a setup against the collecting handler returns its commands and store declarations, in order",
      run :=
        let setup : SetupM Unit := do
          command "first" (makes "1")
          counter.declare
          counter.command "bump" fun n => pure (n + 1)
          command "second" (makes "2")
        match Config.Registrations.ofSetup setup with
        | .error _ => pure false
        | .ok collected =>
          pure
            (collected.commands.map (·.name) == #["first", "bump", "second"] &&
              collected.commands.map (plainTexts ·.action) == #[some #["1"], none, some #["2"]] &&
              collected.stores.map (fun store => (store.name, store.version, store.initial)) ==
                #[("counter", 1, .nat 0)]) },
    { name := "a setup that throws after registering returns its message and nothing else"
      run :=
        let setup : SetupM Unit := do
          command "first" (makes "1")
          throw "no thanks"
        pure (refusal setup == some "no thanks") },
    { name := "a setup that declares a store name twice is refused"
      run :=
        let setup : SetupM Unit := do
          counter.declare
          counter.declare
        pure (refusal setup).isSome },
    { name := "a setup that registers a command over a store it does not declare is refused"
      run :=
        let setup : SetupM Unit := counter.command "bump" fun n => pure (n + 1)
        pure (refusal setup).isSome },
    { name :=
        "a setup that registers a command name twice is refused with a message that names the command, whether the two are plain commands or one is over a store"
      run :=
        let plain : SetupM Unit := do
          command "first" (makes "1")
          command "greet" (makes "2")
          command "greet" (makes "3")
        let mixed : SetupM Unit := do
          counter.declare
          command "bump" (makes "1")
          counter.command "bump" fun n => pure (n + 1)
        pure
          (refusal plain == some "the command `greet` is registered twice" &&
            refusal mixed == some "the command `bump` is registered twice") },
    { name := "a store step decodes the tree, runs the command and encodes the result"
      run :=
        let step :=
          counter.step fun n => do
            discard <| createText s!"was {n}"
            return n + 5
        match (step (.nat 2)).runModel {} with
        | (.ok tree, model) => pure (tree == .nat 7 && model.texts == #["was 2"])
        | (.error _, _) => pure false }]

/-- A registration of the plain command `name`, which makes the text `text`. -/
def registration (name text : String) : Config.Registration :=
  { name, action := .plain (makes text) }

/-- An owner that is not the config. -/
def other : Config.Owner :=
  { name := "other" }

/-- The texts the command `registry` holds under `name` leaves, run against a
text model with none; `none` if there is no such plain command. -/
def registeredTexts (registry : Config.Registry) (name : String) : Option (Array String) :=
  (registry.find? name).bind (plainTexts ·.registration.action)

/-- The checks of the registry (`Editor/Config/Registry.lean`). -/
def registryChecks : List Check :=
  [{
      name :=
        "replace for an owner leaves exactly the new commands of that owner, and a second replace does not add to the first",
      run :=
        let once : Config.Registry :=
          ({} : Config.Registry).replace .config
            #[registration "greet" "1", registration "part" "1"]
        let twice := once.replace .config #[registration "greet" "2"]
        pure
          (once.names == #["greet", "part"] && twice.names == #["greet"] &&
            twice.entries.size == 1 &&
            registeredTexts twice "greet" == some #["2"]) },
    { name := "replace leaves another owner's entries alone"
      run :=
        let registry : Config.Registry :=
          (({} : Config.Registry).replace other #[registration "theirs" "t"]).replace .config
            #[registration "greet" "1"]
        let replaced := registry.replace .config #[]
        pure
          (registry.names == #["theirs", "greet"] && replaced.names == #["theirs"] &&
            registeredTexts replaced "theirs" == some #["t"]) },
    { name := "a lookup returns the latest entry of a name, and none for a name nobody registered"
      run :=
        let registry : Config.Registry :=
          (({} : Config.Registry).replace other #[registration "greet" "theirs"]).replace .config
            #[registration "greet" "ours"]
        pure
          (registeredTexts registry "greet" == some #["ours"] && registry.names == #["greet"] &&
            (registry.find? "missing").isNone) }]

/-- A declaration of the store `name` at `version`, which starts at the
number 0 and accepts any number. It migrates a number written at version 1 by
adding 100 to it, and, wrongly, anything written at version 5 to a string,
which it does not accept. -/
def numbers (name : String) (version : Nat) : StoreDeclaration :=
  { name, version, initial := .nat 0,
    accepts := fun
      | .nat _ => true
      | _ => false,
    migrate := fun
      | 1, .nat n => some (.nat (n + 100))
      | 5, _ => some (.str "not a number")
      | _, _ => none }

/-- A cell of the config's. -/
def cell (name : String) (version : Nat) (value : Value) : Config.Cell :=
  { owner := .config, name, version, value }

/-- Installs `declarations` for the config over `cells`, and returns the
cells after it and the source and severity of each diagnostic. -/
def installed (cells : Array Config.Cell) (declarations : Array StoreDeclaration) :
    Array Config.Cell × Array (String × Config.Severity) :=
  let (after, diagnostics) := ({ cells } : Config.Cells).install .config declarations
  (after.cells, diagnostics.map fun diagnostic => (diagnostic.source, diagnostic.severity))

/-- The checks of the rule that meets a new config's stores with the cells
there are (`Editor/Config/Stores.lean`), one for each case. -/
def storeChecks : List Check :=
  [{ name := "installing a store with no cell makes one from its initial value",
     run := pure (installed #[] #[numbers "counter" 1] == (#[cell "counter" 1 (.nat 0)], #[])) },
    { name := "a cell at the declared version that the store accepts is kept"
      run :=
        pure
          (installed #[cell "counter" 1 (.nat 7)] #[numbers "counter" 1] ==
            (#[cell "counter" 1 (.nat 7)], #[])) },
    { name :=
        "a cell the store does not accept is reset to the initial value, and a diagnostic says so"
      run :=
        pure
          (installed #[cell "counter" 1 (.str "seven")] #[numbers "counter" 1] ==
            (#[cell "counter" 1 (.nat 0)], #[("store counter", .warning)])) },
    { name :=
        "a cell at another version becomes the store's migration of it, at the declared version"
      run :=
        pure
          (installed #[cell "counter" 1 (.nat 7)] #[numbers "counter" 2] ==
            (#[cell "counter" 2 (.nat 107)], #[])) },
    { name :=
        "a cell the store's migration drops is reset to the initial value, and a diagnostic says so"
      run :=
        pure
          (installed #[cell "counter" 3 (.nat 7)] #[numbers "counter" 2] ==
            (#[cell "counter" 2 (.nat 0)], #[("store counter", .warning)])) },
    { name :=
        "a cell migrated to a tree the store does not accept is reset to the initial value, and a diagnostic says so"
      run :=
        pure
          (installed #[cell "counter" 5 (.nat 7)] #[numbers "counter" 2] ==
            (#[cell "counter" 2 (.nat 0)], #[("store counter", .warning)])) },
    { name := "a cell of the owner that is no longer declared is removed, and a diagnostic says so"
      run :=
        pure
          (installed #[cell "old" 1 (.nat 7), cell "counter" 1 (.nat 1)] #[numbers "counter" 1] ==
            (#[cell "counter" 1 (.nat 1)], #[("store old", .warning)])) },
    { name := "another owner's cell is left alone, whatever its name"
      run :=
        let theirs : Config.Cell :=
          { owner := other, name := "counter", version := 9, value := .str "theirs" }
        pure
          (installed #[theirs] #[numbers "counter" 1] ==
              (#[theirs, cell "counter" 1 (.nat 0)], #[]) &&
            installed #[theirs] #[] == (#[theirs], #[])) }]

/-- The state of the fake elaborator: the names of the chunks elaborated so
far, oldest first. Its base is the state with none. -/
abbrev Elaborated :=
  Array String

/-- A call the fake elaborator received. -/
inductive ElaboratorCall where
  /-- The base was imported. -/
  | base
  /-- The chunk called `name` was elaborated on the state `before`. -/
  | chunk (before : Elaborated) (name : String)
  /-- The `setup` program was asked for, of a config that left `state`. -/
  | setup (state : Elaborated)
  deriving DecidableEq, Repr

/-- The diagnostic the fake elaborator gives for the chunk called `name` when
the chunk's text tells it to. -/
def told (name : String) (severity : Config.Severity) : Config.Diagnostic :=
  { source := name, line := 1, severity, message := "the fake was told to" }

/-- A hand-written fake of the elaborator port. It records every call in
`calls`. A chunk whose text is "fails" fails with an error; one whose text is
"warns" elaborates with a warning; one whose text is "throws" makes the port
itself throw. `setup` is the program it says the config defines, or the
diagnostics it has instead. With `baseThrows` the port throws when it is
asked to import the base, and with `setupThrows` when it is asked for the
`setup` program. -/
def fakeElaborator (calls : IO.Ref (Array ElaboratorCall))
    (setup : Except (Array Config.Diagnostic) (SetupM Unit) := .ok (pure ()))
    (baseThrows setupThrows : Bool := false) : Config.Elaborator Elaborated :=
  {
    base := do
      calls.modify (·.push .base)
      if baseThrows then
        throw (IO.userError "the fake elaborator's base broke")
      return #[],
    chunk := fun before chunk => do
      calls.modify (·.push (.chunk before chunk.name))
      match chunk.text with
      | "fails" =>
        return { diagnostics := #[told chunk.name .error], state := none }
      | "warns" =>
        return { diagnostics := #[told chunk.name .warning],
                 state := some (before.push chunk.name) }
      | "throws" =>
        throw (IO.userError "the fake elaborator broke")
      | _ =>
        return { diagnostics := #[], state := some (before.push chunk.name) },
    setup := fun state => do
      calls.modify (·.push (.setup state))
      if setupThrows then
        throw (IO.userError "the fake elaborator's setup broke")
      return setup }

/-- A hand-written fake of the source port: the chunks called `names`, each
with its own name as its text unless `texts` gives it another. -/
def fakeSource (names : List String) (texts : List (String × String) := []) : Config.Source :=
  {
    chunks :=
      pure
        (names.toArray.map fun name =>
          { name, text := ((texts.find? (·.1 == name)).map (·.2)).getD name }) }

/-- The chunks a config of the fake elaborator has once the chunks called
`names` are loaded, each with its name as its text. -/
def loaded (names : List String) : Array (Config.Chunk Elaborated) :=
  (List.range names.length).toArray.map fun index =>
    { name := names.getD index "", text := names.getD index "",
      after := (names.take (index + 1)).toArray }

/-- The names and the states of an outcome's chunks, if it built any. -/
def builtChunks (outcome : Config.Outcome Elaborated) : Option (Array (String × Elaborated)) :=
  outcome.built.map (·.chunks.map fun chunk => (chunk.name, chunk.after))

/-- Builds `source` over `chunks` with a fake elaborator whose base is already
imported, and returns the calls the elaborator received. -/
def rebuildCalls (chunks : List String) (source : Config.Source) : IO (Array ElaboratorCall) := do
  let calls ← IO.mkRef #[]
  discard <| Config.build (fakeElaborator calls) source (some #[]) (loaded chunks)
  calls.get

/-- The checks of the session core (`Editor/Config/Session.lean`): which
chunks a reload elaborates, from which state, and what it gives back. -/
def sessionChecks : List Check :=
  [{
      name :=
        "a first load imports the base, then elaborates every chunk in the source's order, each on the state after the one before it, then asks for setup on the last state",
      run := do
        let calls ← IO.mkRef #[]
        let outcome ← Config.build (fakeElaborator calls) (fakeSource ["a", "b", "c"]) none #[]
        return (← calls.get) ==
              #[.base, .chunk #[] "a", .chunk #["a"] "b", .chunk #["a", "b"] "c",
                .setup #["a", "b", "c"]] &&
            outcome.base == some #[] &&
            builtChunks outcome ==
              some #[("a", #["a"]), ("b", #["a", "b"]), ("c", #["a", "b", "c"])] &&
            outcome.diagnostics.isEmpty },
    { name := "with the base given, it is not imported again, and the outcome hands it back"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ← Config.build (fakeElaborator calls) (fakeSource ["a"]) (some #["given"]) #[]
        return (← calls.get) == #[.chunk #["given"] "a", .setup #["given", "a"]] &&
            outcome.base == some #["given"] },
    { name :=
        "changing a chunk elaborates it and the chunks after it, from the cached state before it"
      run := do
        let calls ← rebuildCalls ["a", "b", "c"] (fakeSource ["a", "b", "c"] [("b", "changed")])
        return calls == #[.chunk #["a"] "b", .chunk #["a", "b"] "c", .setup #["a", "b", "c"]] },
    { name := "removing a chunk elaborates the chunks after it, from the state before it"
      run := do
        let calls ← rebuildCalls ["a", "b", "c"] (fakeSource ["a", "c"])
        return calls == #[.chunk #["a"] "c", .setup #["a", "c"]] },
    { name := "adding a chunk at the end elaborates it alone"
      run := do
        let calls ← rebuildCalls ["a", "b"] (fakeSource ["a", "b", "c"])
        return calls == #[.chunk #["a", "b"] "c", .setup #["a", "b", "c"]] },
    { name := "renaming a chunk elaborates it and the chunks after it"
      run := do
        let calls ← rebuildCalls ["a", "b", "c"] (fakeSource ["a", "b2", "c"] [("b2", "b")])
        return calls == #[.chunk #["a"] "b2", .chunk #["a", "b2"] "c", .setup #["a", "b2", "c"]] },
    { name := "a reload with nothing changed elaborates no chunk, and still asks for setup"
      run := do
        let calls ← rebuildCalls ["a", "b"] (fakeSource ["a", "b"])
        return calls == #[.setup #["a", "b"]] },
    { name :=
        "a chunk that fails gives a rejected outcome with its diagnostics, and no later chunk and no setup is elaborated"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build (fakeElaborator calls) (fakeSource ["a", "b", "c"] [("b", "fails")])
              (some #[]) #[]
        return (← calls.get) == #[.chunk #[] "a", .chunk #["a"] "b"] && outcome.built.isNone &&
            outcome.diagnostics == #[told "b" .error] },
    { name := "a chunk with only a warning is built, and the outcome carries the warning"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build (fakeElaborator calls) (fakeSource ["a", "b"] [("a", "warns")]) (some #[])
              #[]
        return builtChunks outcome == some #[("a", #["a"]), ("b", #["a", "b"])] &&
            outcome.diagnostics == #[told "a" .warning] },
    { name := "what setup registers is in the outcome"
      run := do
        let calls ← IO.mkRef #[]
        let setup : SetupM Unit := command "greet" (makes "hello")
        let outcome ←
          Config.build (fakeElaborator calls (.ok setup)) (fakeSource ["a"]) (some #[]) #[]
        return (outcome.built.map (·.registrations.commands.map (·.name))) == some #["greet"] },
    { name :=
        "a setup that throws gives a rejected outcome whose diagnostic's source is setup and whose message is the one thrown"
      run := do
        let calls ← IO.mkRef #[]
        let setup : SetupM Unit := do
          command "greet" (makes "hello")
          throw "no thanks"
        let outcome ←
          Config.build (fakeElaborator calls (.ok setup)) (fakeSource ["a"]) (some #[]) #[]
        return outcome.built.isNone &&
            outcome.diagnostics ==
              #[{ source := "setup", severity := .error, message := "no thanks" }] },
    { name :=
        "a setup that registers a command name twice gives a rejected outcome whose diagnostic's source is setup and names the command"
      run := do
        let calls ← IO.mkRef #[]
        let setup : SetupM Unit := do
          command "greet" (makes "hello")
          command "greet" (makes "again")
        let outcome ←
          Config.build (fakeElaborator calls (.ok setup)) (fakeSource ["a"]) (some #[]) #[]
        return outcome.built.isNone &&
            outcome.diagnostics ==
              #[{ source := "setup", severity := .error,
                  message := "the command `greet` is registered twice" }] },
    { name :=
        "a config whose setup cannot be produced gives a rejected outcome with the diagnostics"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build (fakeElaborator calls (.error #[told "setup" .error])) (fakeSource ["a"])
              (some #[]) #[]
        return outcome.built.isNone && outcome.diagnostics == #[told "setup" .error] },
    { name := "a config with no chunks is built with nothing registered, and no setup is asked for"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ← Config.build (fakeElaborator calls) (fakeSource []) (some #[]) (loaded ["a"])
        return (← calls.get).isEmpty && builtChunks outcome == some #[] &&
            (outcome.built.map (·.registrations.commands.size)) == some 0 },
    { name :=
        "a source that cannot be read gives a rejected outcome, which still hands back the base"
      run := do
        let calls ← IO.mkRef #[]
        let source : Config.Source := { chunks := throw (IO.userError "no such directory") }
        let outcome ← Config.build (fakeElaborator calls) source none #[]
        return (← calls.get) == #[.base] && outcome.built.isNone && outcome.base == some #[] &&
            outcome.diagnostics.map (fun diagnostic => (diagnostic.source, diagnostic.severity)) ==
              #[("config", .error)] },
    { name := "an elaborator that throws gives a rejected outcome that names the chunk"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build (fakeElaborator calls) (fakeSource ["a", "b"] [("a", "throws")]) (some #[])
              #[]
        return (← calls.get) == #[.chunk #[] "a"] && outcome.built.isNone &&
            outcome.diagnostics.map (fun diagnostic => (diagnostic.source, diagnostic.severity)) ==
              #[("a", .error)] },
    { name :=
        "a base that cannot be imported gives a rejected outcome with no base and one diagnostic from the base, and no chunk is elaborated"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build (fakeElaborator calls (baseThrows := true)) (fakeSource ["a"]) none #[]
        return (← calls.get) == #[.base] && outcome.built.isNone && outcome.base == none &&
            outcome.diagnostics.map (fun diagnostic => (diagnostic.source, diagnostic.severity)) ==
              #[("base", .error)] },
    { name :=
        "an elaborator that throws when asked for setup gives a rejected outcome with a diagnostic from setup, and hands back the base"
      run := do
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build (fakeElaborator calls (setupThrows := true)) (fakeSource ["a"]) (some #[])
              #[]
        return (← calls.get) == #[.chunk #[] "a", .setup #["a"]] && outcome.built.isNone &&
            outcome.base == some #[] &&
            outcome.diagnostics.map (fun diagnostic => (diagnostic.source, diagnostic.severity)) ==
              #[("setup", .error)] }]

/-- An effect of the reload reducer, as a check compares it: a start with the
base and the names of the chunks it carries, or a report with its number,
whether it installed, the sources of its diagnostics, and its counts of
chunks and commands. -/
inductive Seen where
  /-- A job was started. -/
  | start (base : Option Elaborated) (chunks : Array String)
  /-- A reload was reported. -/
  | report (number : Nat) (installed : Bool) (sources : Array String) (chunks commands : Nat)
  deriving DecidableEq, Repr

/-- `effect` as a check compares it. -/
def seen : Config.Effect Elaborated → Seen
  | .start base chunks => .start base (chunks.map (·.name))
  | .report report =>
    .report report.number report.installed (report.diagnostics.map (·.source)) report.chunks
      report.commands

/-- The state the reducer reaches from `state` through `events`, and every
effect on the way. -/
def reduceFrom (state : Config.State Elaborated) (events : List (Config.Event Elaborated)) :
    Config.State Elaborated × Array Seen :=
  events.foldl
    (fun (state, effects) event =>
      let (state, more) := Config.step state event
      (state, effects ++ more.map seen))
    (state, #[])

/-- The state the reducer reaches through `events` from nothing loaded, and
every effect on the way. -/
def reduce (events : List (Config.Event Elaborated)) : Config.State Elaborated × Array Seen :=
  reduceFrom {} events

/-- The outcome of a reload that built the chunks called `names`, whose
`setup` is `setup`. Built by hand: no elaborator ran. -/
def accepted (names : List String) (setup : SetupM Unit) : Config.Outcome Elaborated :=
  { base := some #[], diagnostics := #[],
    built :=
      (Config.Registrations.ofSetup setup).toOption.map fun registrations =>
        { chunks := loaded names, registrations } }

/-- The outcome of a reload that was rejected with one error from `source`. -/
def rejected (source : String) : Config.Outcome Elaborated :=
  { base := some #[], diagnostics := #[told source .error], built := none }

/-- A `setup` that registers `greet`, which makes the text `text`. -/
def greets (text : String) : SetupM Unit :=
  command "greet" (makes text)

/-- A `setup` that declares `counter` and registers `bump` over it, which
adds `step`. -/
def bumps (step : Nat) : SetupM Unit := do
  counter.declare
  counter.command "bump" fun n => pure (n + step)

/-- Runs the command called `name` the way the editor does, against the text
model `model`: the state once what the command wrote is written back, and
the model after it. `none` if there is no such command or it was refused. -/
def runs (state : Config.State Elaborated) (name : String) (model : TextModel := {}) :
    Option (Config.State Elaborated × TextModel) :=
  (state.program? name).bind fun program =>
    match program.runModel model with
    | (.ok write, model) => some (state.written write, model)
    | (.error _, _) => none

/-- The texts the command called `name` leaves when the editor runs it. -/
def runTexts (state : Config.State Elaborated) (name : String) : Option (Array String) :=
  (runs state name).map (·.2.texts)

/-- The value of the config's store called `name`. -/
def stored (state : Config.State Elaborated) (name : String) : Option Value :=
  (state.cells.find? .config name).map (·.value)

/-- The checks of the reload reducer (`Editor/Config/Reload.lean`), with
outcomes built by hand. -/
def reloadChecks : List Check :=
  [{ name := "a request with no job running starts one, carrying the base and the loaded chunks",
     run :=
       let first := reduce [.requested]
       let later := reduce [.requested, .finished (accepted ["a", "b"] (greets "1")), .requested]
       pure
         (first.2 == #[.start none #[]] &&
           later.2 == #[.start none #[], .report 1 true #[] 2 1, .start (some #[]) #["a", "b"]]) },
    { name :=
        "requests while a job runs start nothing, and the finish then starts exactly one more job"
      run :=
        let (running, effects) := reduce [.requested, .requested, .requested, .requested]
        let (after, more) := reduceFrom running [.finished (accepted ["a"] (greets "1"))]
        let (_, last) := reduceFrom after [.finished (accepted ["a"] (greets "1"))]
        pure
          (effects == #[.start none #[]] &&
            more == #[.report 1 true #[] 1 1, .start (some #[]) #["a"]] &&
            last == #[.report 2 true #[] 1 1]) },
    { name :=
        "an accepted outcome installs its chunks and exactly its commands, and the report says installed"
      run :=
        let (state, effects) := reduce [.requested, .finished (accepted ["a", "b"] (greets "1"))]
        pure
          (state.chunks.map (·.name) == #["a", "b"] && state.registry.names == #["greet"] &&
            state.registry.entries.all (·.owner == .config) &&
            effects == #[.start none #[], .report 1 true #[] 2 1]) },
    { name :=
        "a rejected outcome leaves the registry, the chunks and the cells as they were, and the report carries its diagnostics"
      run :=
        let setup : SetupM Unit := do
          greets "1"
          bumps 1
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] setup)]
        let bumped := ((runs loaded "bump").map (·.1)).getD loaded
        let (state, effects) :=
          reduceFrom bumped
            [.requested, .finished (rejected "a"), .requested, .finished (rejected "setup")]
        pure
          (state.chunks.map (·.name) == #["a"] && state.registry.names == #["greet", "bump"] &&
            runTexts state "greet" == some #["1"] &&
            stored state "counter" == some (.nat 1) &&
            effects ==
              #[.start (some #[]) #["a"], .report 2 false #["a"] 1 2, .start (some #[]) #["a"],
                .report 3 false #["setup"] 1 2]) },
    { name := "a rejected first load keeps the base it imported for the next job"
      run :=
        pure
          ((reduce [.requested, .finished (rejected "a"), .requested]).2 ==
            #[.start none #[], .report 1 false #["a"] 0 0, .start (some #[]) #[]]) },
    { name :=
        "an outcome with no base leaves the base as it was: with none known the next job imports again, and a known one is not forgotten"
      run :=
        let baseless : Config.Outcome Elaborated :=
          { base := none, diagnostics := #[told "base" .error], built := none }
        pure
          ((reduce [.requested, .finished baseless, .requested]).2 ==
              #[.start none #[], .report 1 false #["base"] 0 0, .start none #[]] &&
            (reduce
                  [.requested, .finished (rejected "a"), .requested, .finished baseless,
                    .requested]).2 ==
              #[.start none #[], .report 1 false #["a"] 0 0, .start (some #[]) #[],
                .report 2 false #["base"] 0 0, .start (some #[]) #[]]) },
    { name := "reload replaces a command"
      run :=
        let first : SetupM Unit := do
          greets "v1"
          command "old" (makes "old")
        let (state, _) :=
          reduce
            [.requested, .finished (accepted ["a"] first), .requested,
              .finished (accepted ["a"] (greets "v2"))]
        pure
          (runTexts state "greet" == some #["v2"] && state.registry.names == #["greet"] &&
            (state.program? "old").isNone) },
    { name := "a reload does not double-register"
      run :=
        let (state, _) :=
          reduce
            [.requested, .finished (accepted ["a"] (greets "v1")), .requested,
              .finished (accepted ["a"] (greets "v1")), .requested,
              .finished (accepted ["a"] (greets "v1"))]
        pure (state.registry.entries.size == 1 && runTexts state "greet" == some #["v1"]) },
    { name :=
        "a config that registers a command name twice is not installed, so the commands a report counts are the names that can be run"
      run := do
        let setup : SetupM Unit := do
          greets "v1"
          bumps 1
        let twice : SetupM Unit := do
          greets "v2"
          greets "v3"
        let (loaded, first) := reduce [.requested, .finished (accepted ["a"] setup)]
        let calls ← IO.mkRef #[]
        let outcome ←
          Config.build (fakeElaborator calls (.ok twice)) (fakeSource ["a"]) loaded.base
              loaded.chunks
        let (state, effects) := reduceFrom loaded [.requested, .finished outcome]
        return first == #[.start none #[], .report 1 true #[] 1 2] &&
            effects == #[.start (some #[]) #["a"], .report 2 false #["setup"] 1 2] &&
            state.registry.names == #["greet", "bump"] &&
            state.registry.entries.size == 2 &&
            runTexts state "greet" == some #["v1"] },
    { name := "a store value survives a reload"
      run :=
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] (bumps 1))]
        let once := ((runs loaded "bump").map (·.1)).getD loaded
        let twice := ((runs once "bump").map (·.1)).getD once
        let (reloaded, _) := reduceFrom twice [.requested, .finished (accepted ["a"] (bumps 10))]
        let again := ((runs reloaded "bump").map (·.1)).getD reloaded
        pure
          (stored loaded "counter" == some (.nat 0) && stored twice "counter" == some (.nat 2) &&
            stored reloaded "counter" == some (.nat 2) &&
            stored again "counter" == some (.nat 12)) },
    { name :=
        "an installed reload's report carries the config's warnings, then a diagnostic for each store value that was lost"
      run :=
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] (bumps 1))]
        let bumped := ((runs loaded "bump").map (·.1)).getD loaded
        -- An accepted outcome whose one chunk elaborated with a warning.
        let warned (setup : SetupM Unit) : Config.Outcome Elaborated :=
          { accepted ["a"] setup with diagnostics := #[told "a" .warning] }
        -- The counter at a version its store does not migrate to: the value
        -- is reset. And a config that no longer declares it: the cell goes.
        let unmigrated : SetupM Unit := ({ counter with version := 2 } : Store Nat).declare
        let (reset, resetEffects) := reduceFrom bumped [.requested, .finished (warned unmigrated)]
        let (removed, removedEffects) :=
          reduceFrom bumped [.requested, .finished (warned (greets "v1"))]
        pure
          (stored bumped "counter" == some (.nat 1) &&
            resetEffects ==
              #[.start (some #[]) #["a"], .report 2 true #["a", "store counter"] 1 0] &&
            ((reset.cells.find? .config "counter").map fun cell => (cell.version, cell.value)) ==
              some (2, .nat 0) &&
            removedEffects ==
              #[.start (some #[]) #["a"], .report 2 true #["a", "store counter"] 1 1] &&
            stored removed "counter" == none) },
    { name :=
        "a command over a store that is refused writes nothing, and a name nobody registered runs nothing"
      run :=
        let setup : SetupM Unit := do
          counter.declare
          counter.command "broken" fun n => do
              (⟨7⟩ : TextId).insert 0 "x"
              return n + 1
        let (state, _) := reduce [.requested, .finished (accepted ["a"] setup)]
        pure
          ((state.program? "broken").isSome && (runs state "broken").isNone &&
            (state.program? "missing").isNone) }]

/-- Every check, in the order they run. -/
def checks : List Check :=
  programChecks ++ jobModelChecks ++ waitChecks ++ runnerChecks ++ setupChecks ++ registryChecks ++
    storeChecks ++
    sessionChecks ++
    reloadChecks

/-- Runs `checks` and returns the names of those that failed. A check that
throws has failed, and its error is reported with its name. -/
def failures (checks : List Check) : IO (List String) :=
  checks.filterMapM fun check => do
    try
      return if ← check.run then none else some check.name
    catch error =>
      return some s!"{check.name} ({error})"

/-- What the editor's commands do, observed against the text model. -/
def commandProperties : List TextContract.Property :=
  [{ name := "append adds to the end of a text, after its last character",
     holds := do
       let text ← createText "héllo"
       append text " wörld"
       return (← text.read) == "héllo wörld" }]

/-- The properties run against the text model: the text port's contract, then
those of the commands. -/
def textProperties : List TextContract.Property :=
  TextContract.properties ++ commandProperties

/-- The names of the `textProperties` that do not hold of the text model, each
run from a model with no texts. -/
def textFailures : IO (List String) := do
  let failed ← TextContract.failures (fun command => pure (command.runModel {}).1) textProperties
  return failed.map (s!"the text model: {·}")

/-- The names of the job port's contract properties that do not hold of the
job model, each run from a clock at 0 that nothing cancels. -/
def jobModelFailures : IO (List String) := do
  let failed ← JobContract.failures (fun job => pure (job.runModel {}).1) JobContract.properties
  return failed.map (s!"the job model: {·}")

end ModelTest

/-- Runs the checks, then the text port's contract and the job port's
contract, each against its model: exits 0 when all hold, and 1 after naming
on stderr the ones that do not. -/
def main : IO UInt32 := do
  let failed :=
    (← ModelTest.failures ModelTest.checks) ++ (← ModelTest.textFailures) ++
      (← ModelTest.jobModelFailures) ++
      (← ModelTest.jobRunnerFailures)
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  unless failed.isEmpty do
    return 1
  IO.println
      s!"model-test: {ModelTest.checks.length} checks passed, {ModelTest.textProperties.length} properties hold of the text model, and {Editor.JobContract.properties.length} of the job model and of the job runner over the fake clock"
  return 0
