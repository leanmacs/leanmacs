import Editor.Command.Append
import Editor.Config.Reload
import Editor.Display.Model
import Editor.File.Cases
import Editor.File.Model
import Editor.Job.Contract
import Editor.Job.Fake
import Editor.Job.Jobs
import Editor.Job.Model
import Editor.Job.Pool
import Editor.Scene
import Editor.Text.Contract
import Editor.UndoTree.Cases
import Editor.WindowCheck

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

The undo tree (`Editor/UndoTree.lean`) is plain Lean over the text port, so
its cases (`Editor/UndoTree/Cases.lean`) are properties of the same kind and
run against the model in the same list; `contract-test` runs them against
the real binding. `undoTreeChecks` are the checks of its pure operations,
which ask nothing of a text.

The job system is tested here with no Rust library:

- `poolChecks`: warming Lean's task pool (`Editor/Job/Pool.lean`). They pin
  no size: how many threads the pool has is Lean's to say, and
  `LEAN_NUM_THREADS` in the environment changes it. Each check learns the
  pool's threads by warming it, and says what must hold relative to them;
- `jobModelChecks`: the job port's pure model (`Editor/Job/Model.lean`), its
  clock and its cancellation, and what only the model's exact clock can
  show: that a timer does not drift;
- `waitChecks`: the table of waits and the fake clock, with no job;
- `runnerChecks`: the runner (`Editor/Job/Runner.lean`) over the fake clock
  (`Editor/Job/Fake.lean`). A check controls time by moving its own fake
  clock and holds a job on a promise it resolves; it sleeps for nothing, and
  polls only as the bound after which it fails;
- `tableChecks`: the job table (`Editor/Job/Table.lean`), which is pure;
- `ownerChecks`: the shell over the table and the runner
  (`Editor/Job/Jobs.lean`): removing an owner cancels its jobs;
- `fileModelChecks`: the pure model of the files a job reaches
  (`Editor/File/Model.lean`): its decoding of bytes into the text model's
  escapes against texts written out by hand, what a load and a save answer
  and in what order they are refused, and the file data's own functions.
  They touch no file;
- `fileRunnerChecks`, and one check among `runnerChecks`: the runner's file
  waits, on the fake of the file service (`Job.FakeFiles`,
  `Editor/Job/Fake.lean`): a file wait holds no thread, cancelling
  withdraws it, what a job loaded is released however the job ends, a job
  cannot save what another job holds, and a save finds what the editor has
  published when it is made.

The job port's contract (`Editor/Job/Contract.lean`) is run here against the
model and against the runner over the fake clock, and its file properties
against the model of files and against the runner over the fake of the file
service, in a made-up directory: no file is touched. `contract-test` runs
the same lists against the runner over the Rust library's services.

The cases that cross the text port and the job port
(`Editor/File/Cases.lean`) are played here on the two models
(`playOnModels`), with the snapshots handed across as values: a command, a
job that reads what the command published, the job's command, which is
handed what the job held, and a last command, which is handed nothing.
`contract-test` plays them on the real binding and the library's file
service.

The config session's decisions are tested here too, with no elaborator:

- `setupChecks`: what a `setup` registers, commands, stores and jobs, and
  when it is refused;
- `registryChecks`: the registry, its commands and its jobs, replaced by
  owner;
- `storeChecks`: the rule that meets a new config's stores with the cells
  there are, one check for each case;
- `sessionChecks`: one reload (`Config.build`), on a fake elaborator that
  records every call and a fake source;
- `reloadChecks`: the reducer that serialises reloads, with outcomes built
  by hand. The phase's acceptance tests are here on fakes (reload replaces a
  command, a rejected reload keeps the old config, a reload does not
  double-register, a store value survives a reload), and `config-test` runs
  them again with the real elaborator, queue and text binding. The reducer
  also says when the old config's jobs are cancelled: when a reload
  installs, and only then.
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
  (command.runModel {}).2.contents

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
def runOnFake (job : JobM Bool) (rig? : Option Rig := none) : IO (Job.Outcome Bool) := do
  let rig ←
    match rig? with
    | some rig =>
      pure rig
    | none =>
      Rig.new
  let spawned ← rig.spawn (reporting fun _ => job)
  let ended ←
    eventually do
        if ← spawned.handle.ended then
          return true
        if let some deadline← rig.clock.nextDeadline then
          rig.clock.advance (deadline - (← rig.clock.now))
        return false
  unless ended do
    spawned.handle.cancel
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
  let failed ← JobContract.failures (runOnFake ·) JobContract.properties
  return failed.map (s!"the job runner over the fake clock: {·}")

/-- The made-up directory the files of a file property are in, for the model
and for the fake of the file service: an absolute path that is never opened. -/
def fileRoot : System.FilePath :=
  "/files"

/-- The model of the files a file property or a case starts with: the
directory `fileRoot`, and in it `files`, each a name and its bytes. -/
def fileModelOf (files : Array (String × ByteArray)) : FileModel :=
  files.foldl (fun model (name, bytes) => model.withFile (fileRoot / name) bytes)
    (({} : FileModel).withDirectory fileRoot)

/-- The files of `model`, as a file property names them: one in `fileRoot`
by its name, and one anywhere else by its whole path, so that a file written
where none should be is seen. -/
def filesIn (model : FileModel) : Array (String × ByteArray) :=
  model.files.map fun file =>
    let name :=
      if file.path.parent == some fileRoot then file.path.fileName.getD file.path.toString
      else file.path.toString
    (name, file.bytes)

/-- A rig whose services have a fake file service over `model`, and that
service. -/
def Rig.withFiles (model : FileModel) : BaseIO (Rig × Job.FakeFiles) := do
  let rig ← Rig.new
  let files ← Job.FakeFiles.new rig.services.completions model
  return ({ rig with services := { rig.services with files := files.files } }, files)

/-- Runs a file property's job against the job port's model, over the model
of its files: how the job ended, and the files afterwards. -/
def runFilesOnModel (property : JobContract.FileProperty) :
    IO (Job.Outcome Bool × Array (String × ByteArray)) :=
  let (outcome, model) := (property.holds fileRoot).runModel { files := fileModelOf property.files }
  pure (outcome, filesIn model.files)

/-- Runs a file property's job on the runner over a fake clock and the fake
of the file service, over the model of its files: how the job ended, and the
files afterwards. -/
def runFilesOnFake (property : JobContract.FileProperty) :
    IO (Job.Outcome Bool × Array (String × ByteArray)) := do
  let (rig, files) ← Rig.withFiles (fileModelOf property.files)
  let outcome ← runOnFake (property.holds fileRoot) (some rig)
  return (outcome, filesIn (← files.model))

/-- The names of the job port's file properties that do not hold of the job
model, and of those that do not hold of the runner over the fake of the file
service. -/
def fileFailures : IO (List String) := do
  let onModel ← JobContract.fileFailures runFilesOnModel JobContract.fileProperties
  let onFake ← JobContract.fileFailures runFilesOnFake JobContract.fileProperties
  return onModel.map (s!"the job model: {·}") ++
      onFake.map (s!"the job runner over the fake file service: {·}")

/-- What a job's model holds, as what a run of the job's command is handed:
each snapshot the job's loads made that was not released, under the job's
name for it. -/
def heldBy (model : FileModel) : Array (JobSnapshotId × TextContent) :=
  (Array.range model.held.size).filterMap fun index =>
    (model.held[index]?).join.map fun content => (⟨index⟩, content)

/-- Plays `case` on the text model and the job model, handing the snapshots
across as the runtime does, and says what went wrong; `none` when the case
held.

The values that cross are handed as values. The job's model starts with the
text model's snapshots as the published ones. The job's command runs against
the text model with what the job's model held as what arrived. The job is
then settled, so the last command runs against a text model that was handed
nothing. Neither side writes what the other owns. -/
def playOnModels (case : FileCases.Case) : Option String :=
  match case.first.runModel {} with
  | (.error refusal, _) => some s!"its first command failed with {repr refusal}"
  | (.ok start, texts) =>
    let files := { fileModelOf case.files with snapshots := texts.snapshots }
    match (case.job fileRoot start).runModel { files } with
    | (.failed message, _) => some s!"its job failed with `{message}`"
    | (.cancelled, _) => some "its job was cancelled"
    | (.finished value, job) =>
      match (case.handler start value).runModel { texts with arrived := heldBy job.files } with
      | (.error refusal, _) => some s!"the job's command failed with {repr refusal}"
      | (.ok (), texts) =>
        match (case.last start).runModel { texts with arrived := #[] } with
        | (.error refusal, _) => some s!"its last command failed with {repr refusal}"
        | (.ok false, _) => some "its last command says it did not hold"
        | (.ok true, _) =>
          let after := JobContract.byName (filesIn job.files)
          if after == JobContract.byName case.after then none
          else some s!"the files afterwards are {after.map (·.1)}, of {after.map (·.2.size)} bytes"

/-- The names of the cases across the text port and the job port that do not
hold of the two models, each with what went wrong. -/
def caseFailures : IO (List String) :=
  return FileCases.cases.filterMap fun case =>
      (playOnModels case).map fun reason => s!"the text model and the job model: {case.name} ({reason})"

/-- `value`, once `gate` has been resolved: pure work a check can hold a
thread in. It is never inlined, so the read of the gate stays where the call
is. -/
@[noinline]
def onceOpen (gate : IO.Promise Unit) (value : Nat) : Nat :=
  if gate.result?.get.isSome then value else value + 1

/-- How many different thread ids `threads` holds. -/
def distinct (threads : Array UInt64) : Nat :=
  (threads.foldl (fun seen thread => if seen.contains thread then seen else seen.push thread)
      #[]).size

/-- How long a warming waits, in milliseconds, for a task to start before it
takes the pool to be full. A task starts on a free thread in microseconds. -/
def warmPatience : Nat :=
  200

/-- Whether `threads` are all different, and are exactly the threads of
`others`. -/
def sameThreads (threads others : Array UInt64) : Bool :=
  distinct threads == threads.size && threads.size == others.size && threads.all others.contains

/-- The checks of warming the pool (`Editor/Job/Pool.lean`). They are about
the process's one pool, so they run first, while nothing else has used it.

None of them knows how many threads the pool has: that number is Lean's, and
`LEAN_NUM_THREADS` changes it. Each learns the pool's threads from a warming
that stopped short of its limit (`Pool.whole`), and states what must hold
relative to that. -/
def poolChecks : List Check :=
  [{
      name :=
        "warming the pool holds one task on every thread it has, at once: the threads are all different, and a task more than the pool has threads does not start",
      run := do
        let threads ← Job.Pool.whole warmPatience
        return !threads.isEmpty && distinct threads == threads.size },
    { name :=
        "warming stops at the pool's size, and a second warming adds no thread: asked for two threads more than the pool was seen to have, it holds the same threads"
      run := do
        let first ← Job.Pool.whole warmPatience
        let second ← Job.Pool.warm (first.size + 2) warmPatience
        return !first.isEmpty && sameThreads second first },
    { name :=
        "a burst after warming starts no thread: a task for each thread of the pool, all running at once, are on the threads the warming held"
      run := do
        let warmed ← Job.Pool.whole warmPatience
        let release : IO.Promise Unit ← IO.Promise.new
        let running ← IO.mkRef #[]
        try
          for _ in [0:warmed.size] do
            discard <|
                IO.asTask do
                  running.modify (·.push (← IO.getTID))
                  -- Holds its thread in a system call, which Lean does not
                  -- count as blocked, so no thread is added for it.
                  while !(← release.isResolved) do
                    IO.sleep 1
          let together ← eventually (return (← running.get).size == warmed.size)
          return !warmed.isEmpty && together && sameThreads (← running.get) warmed
        finally
          release.resolve () }]

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
        -- More jobs than the pool has threads, whatever its size is here.
        let count := max 64 ((← Job.Pool.whole warmPatience).size + 1)
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
          rig.clock.advance 1000 },
    { name :=
        "jobs in file waits do not delay a new pool task, and their waits hold no thread: more jobs than the pool has threads are all in a load at once, started from fewer threads than there are jobs"
      run := do
        let (rig, files) ←
          Rig.withFiles
              ((({} : FileModel).withDirectory fileRoot).withFile (fileRoot / "a.txt")
                JobContract.rawFile)
        files.holdCompletions
        let count := max 64 ((← Job.Pool.whole warmPatience).size + 1)
        let mut jobs := #[]
        for _ in [0:count] do
          jobs :=
            jobs.push
              (←
                rig.spawn
                    (reporting fun _ => do
                      return (← JobContract.loaded (fileRoot / "a.txt")).stamp.size))
        try
          unless ← eventually (return (← files.waiting) == count) do
            return false
          let ran ← IO.Promise.new
          discard <| BaseIO.asTask (ran.resolve ())
          let notDelayed ← eventually ran.isResolved
          let allWaiting := (← files.waiting) == count
          let noneEnded ← jobs.allM fun job => return !(← job.handle.ended)
          let threads := distinct (← files.startThreads)
          files.letGo
          let allFinished ← jobs.allM (·.endedAs (.finished #["17"]))
          return notDelayed && allWaiting && noneEnded && threads < count && allFinished
        finally
          files.letGo },
    { name :=
        "a job's leading pure work does not run on the spawning thread: spawn returns while that work is still held"
      run := do
        let rig ← Rig.new
        let gate : IO.Promise Unit ← IO.Promise.new
        try
          -- The job's leading pure work reads the gate, so whichever thread
          -- applies the job stays in it until the check resolves the gate.
          let work : Work := fun _ =>
            if gate.result?.get.isSome then pure (makes "ran") else pure (makes "dropped")
          -- On a thread of its own: a spawn that applied the job on its
          -- caller's thread would not return while the gate is held, and
          -- the wait for it would run out.
          let spawning ← BaseIO.asTask (prio := .dedicated) (rig.spawn work)
          let returned ← eventually (IO.hasFinished spawning)
          let held := !(← gate.isResolved)
          gate.resolve ()
          unless returned do
            return false
          return held && (← spawning.get.endedAs (.finished #["ran"]))
        finally
          gate.resolve () },
    { name :=
        "cancelling a sleeping job ends it promptly: it is cancelled, its wait is withdrawn at the clock and gone from the table, and the runner says so once, with the clock never moved"
      run := do
        let rig ← Rig.new
        let sleeper ←
          rig.spawn
              (reporting fun _ => do
                sleep 1000
                return true)
        try
          unless ← eventually (return (← rig.clock.waiting) == 1) do
            return false
          let started ← rig.clock.started
          sleeper.handle.cancel
          -- The clock stays at 0, so only the cancel can have ended the job.
          let cancelled ← sleeper.endedAs .cancelled
          return cancelled && started.size == 1 && (← rig.clock.withdrawn) == started.map (·.1) &&
              (← rig.clock.waiting) == 0 &&
              (← rig.services.completions.waiting) == 0 &&
              (← rig.clock.now) == 0
        finally
          sleeper.handle.cancel },
    { name :=
        "a cancelled job cannot be resumed by a try/catch: a job that catches every error around each of five sleeps, cancelled in the first, makes no further request"
      run := do
        let rig ← Rig.new
        let job ←
          rig.spawn fun _ => do
              stubborn
              return makes "resumed"
        try
          unless ← eventually (return (← rig.clock.waiting) == 1) do
            return false
          job.handle.cancel
          -- A job that went on would start its second sleep.
          discard <|
              eventually do
                return (← job.handle.ended) || (← rig.clock.started).size > 1
          -- Past all five sleeps: a job that had gone on runs to its end.
          rig.clock.advance 100
          return (← job.endedAs .cancelled) && (← rig.clock.started).size == 1 &&
              (← rig.clock.reads) == 1
        finally
          job.handle.cancel },
    { name :=
        "a job cancelled before it starts makes no request: cancelled while its leading work is held, it reads no clock and starts no wait"
      run := do
        let rig ← Rig.new
        let gate : IO.Promise Unit ← IO.Promise.new
        let job ←
          rig.spawn fun _ =>
              if gate.result?.get.isSome then do
                sleep 1000
                return makes "ran"
              else pure (makes "dropped")
        -- A job with no request at all: cancelled, it does not finish.
        let short ←
          rig.spawn fun _ =>
              if gate.result?.get.isSome then pure (makes "ran") else pure (makes "dropped")
        try
          job.handle.cancel
          short.handle.cancel
          gate.resolve ()
          -- A job that went on would read the clock for its sleep.
          discard <|
              eventually do
                return (← job.handle.ended) || (← rig.clock.reads) > 0
          return (← job.endedAs .cancelled) && (← short.endedAs .cancelled) &&
              (← rig.clock.reads) == 0 &&
              (← rig.clock.started).isEmpty
        finally
          gate.resolve ()
          job.handle.cancel },
    { name :=
        "cancellation is looked for again when a reply arrives: a job cancelled while a reading of the clock is in flight is not continued with the reading"
      run := do
        let rig ← Rig.new
        let gate : IO.Promise Unit ← IO.Promise.new
        let reading ← rig.clock.holdReads
        let job ←
          rig.spawn
              (reporting fun _ => do
                let instant ← now
                -- What follows the reply starts with pure work the check
                -- holds: a runner that applied it would be held in it.
                waitUntil (onceOpen gate instant + 10)
                return true)
        try
          unless ← eventually (return (← rig.clock.held) == 1) do
            return false
          job.handle.cancel
          reading.resolve ()
          -- The gate is still shut, so the job can only have ended if what
          -- follows the reply was never applied.
          let cancelled ← job.endedAs .cancelled
          return cancelled && !(← gate.isResolved) && (← rig.clock.started).isEmpty
        finally
          reading.resolve ()
          gate.resolve ()
          job.handle.cancel },
    { name :=
        "a wait entered just as the job is cancelled is withdrawn at once: cancelled while the clock is being asked for the wait, the job ends with the clock never moved"
      run := do
        let rig ← Rig.new
        let starting ← rig.clock.holdStarts
        let job ←
          rig.spawn
              (reporting fun _ => do
                sleep 1000
                return true)
        try
          -- The job has registered its wait and is asking the clock for it:
          -- the cancel finds no wait to withdraw yet.
          unless ← eventually (return (← rig.clock.held) == 1) do
            return false
          job.handle.cancel
          starting.resolve ()
          let cancelled ← job.endedAs .cancelled
          let started ← rig.clock.started
          return cancelled && started.size == 1 && (← rig.clock.withdrawn) == started.map (·.1) &&
              (← rig.services.completions.waiting) == 0 &&
              (← rig.clock.now) == 0
        finally
          starting.resolve ()
          job.handle.cancel },
    { name :=
        "cancellation is looked for again when a wait has ended: a job cancelled as its wait completes is not continued"
      run := do
        let rig ← Rig.new
        let gate : IO.Promise Unit ← IO.Promise.new
        let starting ← rig.clock.holdStarts
        let job ←
          rig.spawn
              (reporting fun _ => do
                let instant ← now
                -- Due already: the clock completes it as soon as it is asked.
                waitUntil instant
                waitUntil (onceOpen gate instant + 10)
                return true)
        try
          unless ← eventually (return (← rig.clock.held) == 1) do
            return false
          -- Cancelled before the clock knows the wait, which then completes
          -- at once: the completion wins, and the job's token is set.
          job.handle.cancel
          starting.resolve ()
          let cancelled ← job.endedAs .cancelled
          return cancelled && !(← gate.isResolved) && (← rig.clock.started).size == 1 &&
              (← rig.clock.withdrawn).isEmpty
        finally
          starting.resolve ()
          gate.resolve ()
          job.handle.cancel },
    { name :=
        "cancelling a job that has ended, and cancelling a job twice, change nothing: the outcome stays, the runner said so once, and the wait was withdrawn once"
      run := do
        let rig ← Rig.new
        let short ←
          rig.spawn
              (reporting fun _ => do
                sleep 5
                return 7)
        let sleeper ←
          rig.spawn
              (reporting fun _ => do
                sleep 1000
                return true)
        try
          unless ← eventually (return (← rig.clock.waiting) == 2) do
            return false
          rig.clock.advance 5
          unless ← short.endedAs (.finished #["7"]) do
            return false
          short.handle.cancel
          sleeper.handle.cancel
          sleeper.handle.cancel
          return (← sleeper.endedAs .cancelled) && (← short.endedAs (.finished #["7"])) &&
              (← rig.clock.withdrawn).size == 1 &&
              (← rig.services.completions.waiting) == 0
        finally
          short.handle.cancel
          sleeper.handle.cancel }]

/-- An owner of jobs. -/
def anna : Config.Owner :=
  { name := "anna" }

/-- Another owner of jobs. -/
def ben : Config.Owner :=
  { name := "ben" }

/-- An entry of a job table as a check compares it: its id, its owner's name,
its name and its handle. -/
def row (entry : Job.Entry String) : Nat × String × String × String :=
  (entry.id, entry.owner.name, entry.name, entry.handle)

/-- The checks of the job table (`Editor/Job/Table.lean`), which is pure:
here a job's handle is a string. -/
def tableChecks : List Check :=
  [{ name := "a job table gives each job an id of its own, and never uses an id again",
     run :=
       let (first, table) := ({} : Job.Table String).add anna "one" "h1"
       let (second, table) := table.add ben "two" "h2"
       let (_, table) := table.take second
       let (third, table) := table.add anna "three" "h3"
       pure
         ([first, second, third].eraseDups.length == 3 &&
           table.entries.map row ==
             #[(first, "anna", "one", "h1"), (third, "anna", "three", "h3")]) },
    { name := "take returns a job once, and nothing for an id that is not in the table"
      run :=
        let (id, table) := ({} : Job.Table String).add anna "one" "h1"
        let (kept, table) := table.add ben "two" "h2"
        let (taken, table) := table.take id
        let (again, table) := table.take id
        let (never, table) := table.take 99
        pure
          (taken.map row == some (id, "anna", "one", "h1") && again.isNone && never.isNone &&
            table.entries.map row == #[(kept, "ben", "two", "h2")]) },
    { name := "removeOwner returns exactly that owner's jobs and leaves the others"
      run :=
        let (first, table) := ({} : Job.Table String).add anna "one" "h1"
        let (second, table) := table.add ben "two" "h2"
        let (third, table) := table.add anna "three" "h3"
        let (removed, table) := table.removeOwner anna
        let (nothing, same) := table.removeOwner anna
        pure
          (removed.map row == #[(first, "anna", "one", "h1"), (third, "anna", "three", "h3")] &&
            table.entries.map row == #[(second, "ben", "two", "h2")] &&
            nothing.isEmpty &&
            same.entries.size == 1) },
    { name := "take after removeOwner finds nothing: a job whose owner is gone has no entry left"
      run :=
        let (id, table) := ({} : Job.Table String).add anna "one" "h1"
        let (_, table) := table.removeOwner anna
        pure (table.take id).1.isNone }]

/-- What `finish` gave, as a check compares it: the job's id and name, and
how it ended. -/
def taken (result : Option (Job.Entry Job.Handle × Job.Outcome (EditorM Unit))) :
    Option (Nat × String × Job.Outcome (Array String)) :=
  result.map fun (entry, outcome) => (entry.id, entry.name, texts outcome)

/-- The checks of the shell over the job table and the runner
(`Editor/Job/Jobs.lean`), on a fake clock. -/
def ownerChecks : List Check :=
  [{
      name :=
        "a job whose owner is removed is cancelled, and its result can no longer be taken; another owner's job runs on, and its result is taken once",
      run := do
        let rig ← Rig.new
        let woken ← IO.mkRef #[]
        let finished (id : Nat) : BaseIO Unit := woken.modify (·.push id)
        let sleeps : Work :=
          reporting fun _ => do
            sleep 1000
            return true
        let jobs : Job.Jobs := { services := rig.services }
        let (annas, jobs) ← jobs.start anna "sleeps" sleeps finished
        let (bens, jobs) ← jobs.start ben "sleeps" sleeps finished
        try
          unless ← eventually (return (← rig.clock.waiting) == 2) do
            return false
          -- A job that is still running has no result to take, and stays.
          let (early, jobs) ← jobs.finish bens
          let (removed, jobs) ← jobs.removeOwner anna
          -- The clock stays at 0, so only removing the owner can have ended
          -- Anna's job.
          let ended ← eventually (return (← woken.get) == #[annas])
          let outcomes ← removed.mapM fun entry => return (← entry.handle.outcome?).map texts
          let withdrawn := (← rig.clock.withdrawn).size == 1 && (← rig.clock.waiting) == 1
          let unmoved := (← rig.clock.now) == 0
          -- The handler cannot run: there is no result to take.
          let (gone, jobs) ← jobs.finish annas
          rig.clock.advance 1000
          let bensEnded ← eventually (return (← woken.get) == #[annas, bens])
          let (result, jobs) ← jobs.finish bens
          let (again, jobs) ← jobs.finish bens
          return early.isNone && ended && removed.map (·.id) == #[annas] &&
              outcomes == #[some .cancelled] &&
              withdrawn &&
              unmoved &&
              gone.isNone &&
              bensEnded &&
              taken result == some (bens, "sleeps", .finished #["true"]) &&
              again.isNone &&
              jobs.running == 0
        finally
          for entry in jobs.table.entries do
            entry.handle.cancel }]

/-- A model with the directory `fileRoot` and, in it, `a.txt` holding
`JobContract.rawFile`, seventeen bytes, and `b.txt` holding
`JobContract.otherFile`, twelve. -/
def twoFiles : FileModel :=
  ((({} : FileModel).withDirectory fileRoot).withFile (fileRoot / "a.txt")
        JobContract.rawFile).withFile
    (fileRoot / "b.txt") JobContract.otherFile

/-- What the editor has published, in the checks below: one snapshot, of a
text with a two-byte character and an escape. Saved, it is the seven bytes
`pubBytes`. -/
def pubContent : TextContent :=
  { contents := "pub é".push (Char.ofNat 0x10DCFF), revision := 2 }

/-- The bytes `pubContent` is saved as, written out by hand. -/
def pubBytes : ByteArray :=
  ⟨#[0x70, 0x75, 0x62, 0x20, 0xC3, 0xA9, 0xFF]⟩

/-- Whether `reply` is a refusal as failed, whatever its detail. -/
def isFailed {α : Type} (reply : Except FileError α) : Bool :=
  match reply with
  | .error (.failed _) => true
  | _ => false

/-- The bytes of the file `name` of `fileRoot` in the fake's model, if it is
there. -/
def fileOf (files : Job.FakeFiles) (name : String) : BaseIO (Option ByteArray) :=
  return ((← files.model).file? (fileRoot / name)).map (·.bytes)

/-- The checks of the job runner's file waits (`Editor/Job/Runner.lean`),
each on a fake of the file service of its own (`Job.FakeFiles`,
`Editor/Job/Fake.lean`), over a model of two files. A check holds what it
controls (the service's completions, its takes, a clock) and polls only as
the bound after which it fails. -/
def fileRunnerChecks : List Check :=
  [{
      name :=
        "cancelling a job in a file wait withdraws the wait and ends the job cancelled, and its save never happens: no file is written, then or when the service lets go",
      run := do
        let (rig, files) ← Rig.withFiles twoFiles
        files.publish #[some pubContent]
        files.holdCompletions
        let saver ←
          rig.spawn
              (reporting fun _ => do
                return (← JobContract.saved (.snapshot ⟨0⟩) (fileRoot / "new.txt") .absent).size)
        try
          unless ← eventually (return (← files.waiting) == 1) do
            return false
          let started := (← files.started).map (·.1)
          saver.handle.cancel
          let cancelled ← saver.endedAs .cancelled
          let withdrawn := (← files.withdrawn) == started && (← files.waiting) == 0
          let forgotten := (← rig.services.completions.waiting) == 0
          files.letGo
          return cancelled && started.size == 1 && withdrawn && forgotten &&
              (← fileOf files "new.txt").isNone
        finally
          saver.handle.cancel
          files.letGo },
    { name :=
        "a job cancelled as its load completes is not continued, and what it loaded is released: cancelled while the reply is being fetched, it ends cancelled, and the snapshot the load made is given up"
      run := do
        let (rig, files) ← Rig.withFiles twoFiles
        let hold ← files.holdTakes
        let loader ←
          rig.spawn
              (reporting fun _ => do
                let file ← JobContract.loaded (fileRoot / "a.txt")
                -- Never reached: the job is cancelled before the reply is
                -- handed to it.
                return (←
                      JobContract.saved (.held file.snapshot) (fileRoot / "new.txt") .absent).size)
        try
          unless ← eventually (return (← files.takesHeld) == 1) do
            return false
          loader.handle.cancel
          hold.resolve ()
          let cancelled ← loader.endedAs .cancelled
          return cancelled && (← files.released) == #[⟨0⟩] && (← files.model).held == #[none] &&
              (← loader.handle.holding).isEmpty &&
              (← files.started).size == 1 &&
              (← fileOf files "new.txt").isNone
        finally
          hold.resolve ()
          loader.handle.cancel },
    { name :=
        "what a job loaded is the runner's to release: a job that fails after a load has its snapshot released with no call from here, and one that finishes keeps it until it is settled, once"
      run := do
        let (rig, files) ← Rig.withFiles twoFiles
        let fails ←
          rig.spawn fun _ => do
              discard <| JobContract.loaded (fileRoot / "a.txt")
              throw "no thanks"
        let failed ← fails.endedAs (.failed "no thanks")
        let afterFailure ← files.released
        let finishes ←
          rig.spawn
              (reporting fun _ => do
                discard <| JobContract.loaded (fileRoot / "a.txt")
                return (← JobContract.loaded (fileRoot / "b.txt")).stamp.size)
        let finished ← finishes.endedAs (.finished #["12"])
        let kept ← files.released
        let holding ← finishes.handle.holding
        finishes.handle.settle
        let settled ← files.released
        finishes.handle.settle
        return failed && afterFailure == #[⟨0⟩] && finished && kept == #[⟨0⟩] &&
            holding == #[⟨1⟩, ⟨2⟩] &&
            settled == #[⟨0⟩, ⟨1⟩, ⟨2⟩] &&
            (← files.released) == settled &&
            (← finishes.handle.holding).isEmpty &&
            (← files.model).held == #[none, none, none] },
    { name :=
        "removing an owner releases what its finished job loaded though the job's command never ran, and so does cancelling every job"
      run := do
        let (rig, files) ← Rig.withFiles twoFiles
        let woken ← IO.mkRef #[]
        let finished (id : Nat) : BaseIO Unit := woken.modify (·.push id)
        let loads : Work :=
          reporting fun _ => do
            return (← JobContract.loaded (fileRoot / "a.txt")).stamp.size
        let jobs : Job.Jobs := { services := rig.services }
        let (annas, jobs) ← jobs.start anna "loads" loads finished
        unless ← eventually (return (← woken.get) == #[annas]) do
          return false
        let before ← files.released
        let (removed, jobs) ← jobs.removeOwner anna
        let afterRemoval ← files.released
        let (bens, jobs) ← jobs.start ben "loads" loads finished
        unless ← eventually (return (← woken.get) == #[annas, bens]) do
          return false
        jobs.cancelAll
        return before.isEmpty && removed.map (·.id) == #[annas] && afterRemoval == #[⟨0⟩] &&
            (← files.released) == #[⟨0⟩, ⟨1⟩] &&
            (← files.model).held == #[none, none] },
    { name :=
        "a job cannot save what another job holds: with one job parked after its load, a second that saves that job's snapshot is refused as naming none, and the service is asked to start nothing for it"
      run := do
        let (rig, files) ← Rig.withFiles twoFiles
        let holder ←
          rig.spawn
              (reporting fun _ => do
                discard <| JobContract.loaded (fileRoot / "a.txt")
                sleep 1000
                return true)
        try
          unless ← eventually (return (← rig.clock.waiting) == 1) do
            return false
          let #[theirs] ← holder.handle.holding | return false
          let thief ←
            rig.spawn
                (reporting fun _ =>
                  JobContract.saveRefusedAs .noSuchSnapshot (.held theirs) (fileRoot / "new.txt")
                    .absent)
          let refused ← thief.endedAs (.finished #["true"])
          return refused && (← files.started).size == 1 && (← fileOf files "new.txt").isNone &&
              (← holder.handle.holding) == #[theirs]
        finally
          holder.handle.cancel },
    { name :=
        "a save of a snapshot the editor published finds it by its id when the save is made: one published before the job began, one published after, and none for one taken away since"
      run := do
        let (rig, files) ← Rig.withFiles twoFiles
        files.publish #[some pubContent]
        let saver ←
          rig.spawn
              (reporting fun _ => do
                let early ← JobContract.saved (.snapshot ⟨0⟩) (fileRoot / "early.txt") .absent
                sleep 10
                let late ← JobContract.saved (.snapshot ⟨1⟩) (fileRoot / "late.txt") .absent
                sleep 10
                let gone ←
                  JobContract.saveRefusedAs .noSuchSnapshot (.snapshot ⟨0⟩) (fileRoot / "gone.txt")
                      .absent
                return early.size == 7 && late.size == 4 && gone)
        try
          unless ← eventually (return (← rig.clock.waiting) == 1) do
            return false
          files.publish #[some pubContent, some { contents := "lé\n" }]
          rig.clock.advance 10
          unless ← eventually (return (← rig.clock.waiting) == 1) do
            return false
          files.publish #[none, some { contents := "lé\n" }]
          rig.clock.advance 10
          let held ← saver.endedAs (.finished #["true"])
          return held && (← fileOf files "early.txt") == some pubBytes &&
              (← fileOf files "late.txt") == some ⟨#[0x6C, 0xC3, 0xA9, 0x0A]⟩ &&
              (← fileOf files "gone.txt").isNone
        finally
          saver.handle.cancel },
    { name :=
        "on a runner that was given no file service a load and a save are refused as failed, and the job goes on to finish"
      run := do
        let rig ← Rig.new
        let asks ←
          rig.spawn
              (reporting fun _ => do
                let load ← File.load (fileRoot / "a.txt") 1000
                let save ← File.save (.snapshot ⟨0⟩) (fileRoot / "b.txt") .whatever
                return isFailed load && isFailed save && (← now) == 0)
        return (← asks.endedAs (.finished #["true"])) &&
            (← rig.services.completions.waiting) == 0 }]

/-- The texts a registered command leaves when it is a plain command, run
against a text model with none; `none` for a command over a store. -/
def plainTexts : Config.Action → Option (Array String)
  | .plain run => some (textsOf run)
  | .store .. => none

/-- How `work` ends when it runs against the job model from a clock at 0 that
nothing cancels, as a check compares it. -/
def worked (work : Work) : Job.Outcome (Array String) :=
  texts ((work ()).runModel {}).1

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
        | (.ok tree, model) => pure (tree == .nat 7 && model.contents == #["was 2"])
        | (.error _, _) => pure false },
    { name :=
        "a setup that registers jobs collects each with its name, in order, beside its commands, and a job is not a command"
      run :=
        let setup : SetupM Unit := do
          command "first" (makes "1")
          job "count"
              (fun _ => do
                sleep 5
                return 42)
              fun n => makes s!"counted {n}"
          job "name" (fun _ => pure "x") makes
          command "second" (makes "2")
        match Config.Registrations.ofSetup setup with
        | .error _ => pure false
        | .ok collected =>
          pure
            (collected.commands.map (·.name) == #["first", "second"] &&
              collected.jobs.map (·.name) == #["count", "name"] &&
              collected.jobs.map (worked ·.work) ==
                #[.finished #["counted 42"], .finished #["x"]]) },
    { name :=
        "a setup that registers a job name twice is refused with a message that names the job, and a job may have the name of a command"
      run :=
        let twice : SetupM Unit := do
          job "count" (fun _ => pure 1) fun n => makes (toString n)
          job "other" (fun _ => pure 2) fun n => makes (toString n)
          job "count" (fun _ => pure 3) fun n => makes (toString n)
        let shared : SetupM Unit := do
          command "count" (makes "1")
          job "count" (fun _ => pure 1) fun n => makes (toString n)
        pure
          (refusal twice == some "the job `count` is registered twice" && refusal shared == none) }]

/-- A registration of the plain command `name`, which makes the text `text`. -/
def registration (name text : String) : Config.Registration :=
  { name, action := .plain (makes text) }

/-- A registration of the job `name`, which finishes with a command that
makes the text `text`. -/
def jobRegistration (name text : String) : Config.JobRegistration :=
  { name, work := fun _ => pure (makes text) }

/-- How the job `registry` holds under `name` ends, run against the job
model; `none` if there is no such job. -/
def registeredWork (registry : Config.Registry) (name : String) :
    Option (Job.Outcome (Array String)) :=
  (registry.findJob? name).map (worked ·.registration.work)

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
            (registry.find? "missing").isNone) },
    { name :=
        "an owner's jobs are replaced as a set, and another owner's are left: a lookup finds the latest job of a name, and the commands are untouched"
      run :=
        let registry : Config.Registry :=
          ((({} : Config.Registry).replace .config #[registration "greet" "1"]).replaceJobs other
                #[jobRegistration "theirs" "t"]).replaceJobs
            .config #[jobRegistration "count" "1", jobRegistration "old" "1"]
        let replaced := registry.replaceJobs .config #[jobRegistration "count" "2"]
        pure
          (registry.jobs.map (·.registration.name) == #["theirs", "count", "old"] &&
            replaced.jobs.map (·.registration.name) == #["theirs", "count"] &&
            registeredWork replaced "count" == some (.finished #["2"]) &&
            registeredWork replaced "theirs" == some (.finished #["t"]) &&
            registeredWork replaced "old" == none &&
            replaced.names == #["greet"] &&
            (replaced.find? "count").isNone) }]

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
base and the names of the chunks it carries, the cancelling of an owner's
jobs with the owner's name, or a report with its number, whether it
installed, the sources of its diagnostics, and its counts of chunks and
commands. -/
inductive Seen where
  /-- A job was started. -/
  | start (base : Option Elaborated) (chunks : Array String)
  /-- The jobs of the owner called `owner` were cancelled. -/
  | cancelJobs (owner : String)
  /-- A reload was reported. -/
  | report (number : Nat) (installed : Bool) (sources : Array String) (chunks commands : Nat)
  deriving DecidableEq, Repr

/-- `effect` as a check compares it. -/
def seen : Config.Effect Elaborated → Seen
  | .start base chunks => .start base (chunks.map (·.name))
  | .cancelJobs owner => .cancelJobs owner.name
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

/-- A `setup` that registers the command `greet` and the job `count`, each of
which makes the text `text`. -/
def counts (text : String) : SetupM Unit := do
  command "greet" (makes text)
  job "count" (fun _ => pure text) makes

/-- The job the editor would start for `name`: its owner's name, and how the
job ends when it runs against the job model; `none` if there is no such job. -/
def startable (state : Config.State Elaborated) (name : String) :
    Option (String × Job.Outcome (Array String)) :=
  (state.work? name).map fun (owner, work) => (owner.name, worked work)

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
  (runs state name).map (·.2.contents)

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
           later.2 ==
             #[.start none #[], .cancelJobs "config", .report 1 true #[] 2 1,
               .start (some #[]) #["a", "b"]]) },
    { name :=
        "requests while a job runs start nothing, and the finish then starts exactly one more job"
      run :=
        let (running, effects) := reduce [.requested, .requested, .requested, .requested]
        let (after, more) := reduceFrom running [.finished (accepted ["a"] (greets "1"))]
        let (_, last) := reduceFrom after [.finished (accepted ["a"] (greets "1"))]
        pure
          (effects == #[.start none #[]] &&
            more == #[.cancelJobs "config", .report 1 true #[] 1 1, .start (some #[]) #["a"]] &&
            last == #[.cancelJobs "config", .report 2 true #[] 1 1]) },
    { name :=
        "an accepted outcome installs its chunks and exactly its commands, and the report says installed"
      run :=
        let (state, effects) := reduce [.requested, .finished (accepted ["a", "b"] (greets "1"))]
        pure
          (state.chunks.map (·.name) == #["a", "b"] && state.registry.names == #["greet"] &&
            state.registry.entries.all (·.owner == .config) &&
            effects == #[.start none #[], .cancelJobs "config", .report 1 true #[] 2 1]) },
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
        return first == #[.start none #[], .cancelJobs "config", .report 1 true #[] 1 2] &&
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
              #[.start (some #[]) #["a"], .cancelJobs "config",
                .report 2 true #["a", "store counter"] 1 0] &&
            ((reset.cells.find? .config "counter").map fun cell => (cell.version, cell.value)) ==
              some (2, .nat 0) &&
            removedEffects ==
              #[.start (some #[]) #["a"], .cancelJobs "config",
                .report 2 true #["a", "store counter"] 1 1] &&
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
            (state.program? "missing").isNone) },
    { name :=
        "a job is not counted as a command: the report of a config that registers one command and one job says one command"
      run :=
        let (state, effects) := reduce [.requested, .finished (accepted ["a"] (counts "v1"))]
        pure
          (effects == #[.start none #[], .cancelJobs "config", .report 1 true #[] 1 1] &&
            state.commands == 1 &&
            state.registry.names == #["greet"]) },
    { name :=
        "an accepted outcome cancels the config's jobs before it is reported, and before the follow-up job starts; a rejected outcome cancels nothing"
      run :=
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] (counts "v1"))]
        -- A reload asked for while one runs: the follow-up starts last.
        let (_, acceptedEffects) :=
          reduceFrom loaded [.requested, .requested, .finished (accepted ["a"] (counts "v2"))]
        -- The same source again: every accepted reload cancels.
        let (_, unchanged) :=
          reduceFrom loaded [.requested, .finished (accepted ["a"] (counts "v1"))]
        let (_, rejectedEffects) :=
          reduceFrom loaded [.requested, .requested, .finished (rejected "a")]
        pure
          (acceptedEffects ==
              #[.start (some #[]) #["a"], .cancelJobs "config", .report 2 true #[] 1 1,
                .start (some #[]) #["a"]] &&
            unchanged ==
              #[.start (some #[]) #["a"], .cancelJobs "config", .report 2 true #[] 1 1] &&
            rejectedEffects ==
              #[.start (some #[]) #["a"], .report 2 false #["a"] 1 1, .start (some #[]) #["a"]]) },
    { name :=
        "a reload replaces the config's jobs: the registry finds the new config's job and not the old one's, and a rejected reload keeps the old one's"
      run :=
        let first : SetupM Unit := do
          counts "v1"
          job "old" (fun _ => pure "old") makes
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] first)]
        let (reloaded, _) :=
          reduceFrom loaded [.requested, .finished (accepted ["a"] (counts "v2"))]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        pure
          (startable loaded "count" == some ("config", .finished #["v1"]) &&
            startable loaded "old" == some ("config", .finished #["old"]) &&
            startable reloaded "count" == some ("config", .finished #["v2"]) &&
            startable reloaded "old" == none &&
            reloaded.registry.jobs.size == 1 &&
            startable kept "count" == some ("config", .finished #["v1"]) &&
            startable kept "old" == some ("config", .finished #["old"]) &&
            startable loaded "missing" == none) }]

/-- A key press that produced `text`. -/
def pressed (text : String) : WindowCheck.Input :=
  .key true false false text

/-- A key release, which produces no text. -/
def released : WindowCheck.Input :=
  .key false false false ""

/-- The tally of `arrivals`, counted in order from nothing. -/
def counted (arrivals : List WindowCheck.Arrival) : WindowCheck.Tally :=
  arrivals.foldl WindowCheck.Tally.step {}

/-- The tally of `inputs`, each arriving and handled at the instant 0. -/
def tallied (inputs : List WindowCheck.Input) : WindowCheck.Tally :=
  counted (inputs.map fun input => { input, arrived := 0, handled := 0 })

/-- `text` as often as `count` says. -/
def repeated (text : String) (count : Nat) : String :=
  String.join (List.replicate count text)

/-- A run whose window opened on the platform `fake` 2.5 ms after it was
asked for, and reported `inputs` after that, each arriving and handled at the
instant the window opened. -/
def opened (inputs : List WindowCheck.Input) (options : WindowCheck.Options := {})
    (ending : WindowCheck.Ending := .closed) : WindowCheck.Run :=
  { options, serviceOnMain := true, askedAt := 1000000, failure := none, ending
    tally :=
      counted
        ((.opened "fake" :: inputs).map fun input =>
          { input, arrived := 3500000, handled := 3500000 }) }

/-- A run whose window could not be opened, for the reason `reason`. Its
ending is what the check gives a run nothing ended. -/
def unopened (reason : String) : WindowCheck.Run :=
  { options := {}, serviceOnMain := true, askedAt := 1000000, failure := some reason, tally := {}
    ending := .closed }

/-- The report of a run with no window, after its second line: the forms
every line takes when nothing arrived. -/
def nothingArrived : List String :=
  ["focus: never gained; first pointer press in the window: none",
    "keys: 0 key events reached the Lean loop (0 presses, 0 of them repeats, 0 releases); text: \"\"",
    "latency from a key's arrival in Rust to its handling in Lean, in µs: no samples",
    "dead keys: 0 key events marked dead",
    "composition: not enabled; 0 preedit and 0 commit events; committed: \"\"",
    "ended: the window never opened"]

/-- What a fake window does in one check: the inputs it reports once it is
run, each with the instant it arrived and the instant the fake's clock reads
when the loop has pulled it. -/
structure FakeWindow where
  /-- What the window reports once it runs, in order. -/
  arrivals : List WindowCheck.Arrival := []
  /-- Why the window cannot be opened, if it cannot. -/
  cannotOpen : Option String := none
  /-- What the fake answers when asked where the main-thread service is. -/
  serviceOnMain : Bool := true
  /-- The clock's reading until the first input is pulled. -/
  askedAt : Nat := 0
  /-- What the clock reads once the window runs and every input has been
  pulled: a time limit passes when this is far enough on. -/
  idleAt : Option Nat := none
  /-- Whether the window, once it is run, takes until a close has been asked
  of it to begin: a close that came too early, which it forgets as every
  window does. -/
  slowToBegin : Bool := false

/-- What a fake window has been asked and has said. -/
structure FakeWindowState where
  /-- The clock's reading. -/
  now : Nat
  /-- The inputs the window has reported that the loop has not pulled. -/
  pending : List WindowCheck.Arrival := []
  /-- Whether the window is running. -/
  running : Bool := false
  /-- Whether the loop has been told to stop once `pending` is empty. -/
  stopped : Bool := false
  /-- The calls made of the window, in order: `probe`, `run true` or
  `run false`, `close`, `stop`. -/
  calls : Array String := #[]
  /-- The lines printed. -/
  lines : Array String := #[]
  /-- The lines said to the person at the terminal, apart from the report. -/
  said : Array String := #[]
  /-- How many closes were asked for while the window was not running, and
  so forgotten. -/
  forgotten : Nat := 0

/-- The fake as the record the check runs on. `closed` is resolved by a
close asked for while the window is running, and ends the run. A close asked
for at any other time is forgotten, as the window port's contract has it. -/
def FakeWindow.window (fake : FakeWindow) (state : IO.Ref FakeWindowState)
    (closed : IO.Promise Unit) : WindowCheck.Window :=
  let called (call : String) : IO Unit :=
    state.modify fun state => { state with calls := state.calls.push call }
  { next := do
      repeat
        let pulled ←
          state.modifyGet fun state =>
              match state.pending with
              | arrival :: rest =>
                (some (arrival.input, arrival.arrived),
                  { state with
                    pending := rest, now := arrival.handled })
              | [] =>
                if state.stopped then (some (.stop, 0), state)
                else
                  if state.running then (none, { state with now := fake.idleAt.getD state.now })
                  else (none, state)
        if let some input := pulled then
          return input
        IO.sleep 1
      return (.stop, 0)
    clock := return (← state.get).now
    serviceOnMain := do
      called "probe"
      return fake.serviceOnMain
    run := fun composition => do
      called s!"run {composition}"
      if let some reason := fake.cannotOpen then
        return .error reason
      if fake.slowToBegin then
        while (← state.get).forgotten == 0 && !(← closed.isResolved) do
          IO.sleep 1
      state.modify fun state =>
          { state with
            pending := fake.arrivals, running := true }
      while !(← closed.isResolved) do
        IO.sleep 1
      state.modify fun state => { state with running := false }
      return .ok ()
    close := do
      called "close"
      let running ←
        state.modifyGet fun state =>
            (state.running,
              if state.running then state else { state with forgotten := state.forgotten + 1 })
      if running then
        closed.resolve ()
    stop := do
      called "stop"
      state.modify fun state => { state with stopped := true }
    emit := fun line => state.modify fun state => { state with lines := state.lines.push line } }

/-- What one check on a fake window showed. -/
structure Checked where
  /-- The lines the check printed. -/
  lines : List String
  /-- The calls it made of the window, in order. -/
  calls : List String
  /-- Its exit status; `none` if it did not end in time. -/
  status : Option UInt32
  /-- What it said to the person at the terminal, apart from the report. -/
  said : List String
  /-- How many closes it asked for while the window was not running. -/
  forgotten : Nat

/-- Runs `act` on `fake`'s window and on somewhere to say a line, and returns
what it did. It runs on a dedicated task that this polls, so one that never
ends fails here instead of hanging the executable, and the fake's window is
closed whatever happened, so its run is not left behind. -/
def FakeWindow.drive (fake : FakeWindow)
    (act : WindowCheck.Window → (String → IO Unit) → IO UInt32) : IO Checked := do
  let state ← IO.mkRef { now := fake.askedAt }
  let closed ← IO.Promise.new
  let say (line : String) : IO Unit :=
    state.modify fun state => { state with said := state.said.push line }
  let task ← IO.asTask (prio := .dedicated) (act (fake.window state closed) say)
  let status ←
    if ← eventually (IO.hasFinished task) then
      some <$> IO.ofExcept task.get
    else
      pure none
  closed.resolve ()
  let state ← state.get
  return {
      lines := state.lines.toList, calls := state.calls.toList, status
      said := state.said.toList, forgotten := state.forgotten }

/-- Runs the keyboard check on `fake`, with `options`. -/
def FakeWindow.check (fake : FakeWindow) (options : WindowCheck.Options := {}) : IO Checked :=
  fake.drive fun window _ => WindowCheck.check window options

/-- Runs the keyboard check on `fake` as `editor window-check` runs it, with
the command line's `arguments`. -/
def FakeWindow.withArguments (fake : FakeWindow) (arguments : List String) : IO Checked :=
  fake.drive fun window say => WindowCheck.withArguments window arguments say

/-- A window that opens 2.5 ms after it is asked for, at the instant
1 000 000 on the clock, and then reports each thing the check tells apart:
the focus, a pointer press, five key events with latencies of 10, 30, 20,
100 and 40.5 µs, a composition, a request to close, and one more key 50 µs
after that. -/
def typed : FakeWindow :=
  { askedAt := 1000000
    arrivals :=
      [{ input := .opened "fake", arrived := 3500000, handled := 3520000 },
        { input := .focus true, arrived := 5500000, handled := 5510000 },
        { input := .pointerPressed, arrived := 9500000, handled := 9510000 },
        { input := pressed "h", arrived := 10000000, handled := 10010000 },
        { input := released, arrived := 10100000, handled := 10130000 },
        { input := .key true true false "h", arrived := 10200000, handled := 10220000 },
        { input := .key true false true "", arrived := 10300000, handled := 10400000 },
        { input := pressed "é", arrived := 10500000, handled := 10540500 },
        { input := .compositionEnabled, arrived := 10600000, handled := 10600000 },
        { input := .preedit "´", arrived := 10700000, handled := 10700000 },
        { input := .commit "é", arrived := 10800000, handled := 10800000 },
        { input := .closeRequested, arrived := 10900000, handled := 10900000 },
        { input := pressed "z", arrived := 11000000, handled := 11050000 }] }

/-- The report of the check on `typed`. -/
def typedReport : List String :=
  ["window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: yes",
    "window: opened by fake 2.5 ms after it was asked for",
    "focus: gained 2.0 ms after the window opened; first pointer press in the window: 6.0 ms after it opened",
    "keys: 6 key events reached the Lean loop (5 presses, 1 of them repeats, 1 releases); text: \"hhéz\"",
    "latency from a key's arrival in Rust to its handling in Lean, in µs: median 30.0 / 99th percentile 100.0 / maximum 100.0 (6 samples)",
    "dead keys: 1 key events marked dead",
    "composition: enabled; 1 preedit and 1 commit events; committed: \"é\"",
    "ended: the window was closed"]

/-- The checks of the keyboard check's pure core (`Editor/WindowCheck.lean`):
what it counts, the percentiles, and each line of the report. -/
def windowTallyChecks : List Check :=
  [{
      name :=
        "the tally counts key presses, the repeats among them, releases, dead keys, preedits and commits",
      run := do
        let tally :=
          tallied
            [pressed "a", released, .key true true false "a", .key true false true "",
              .key false false true "", .preedit "´", .preedit "", .commit "é", .compositionEnabled,
              .focus true, .other]
        return tally.keys == 5 && tally.presses == 3 && tally.repeats == 1 && tally.releases == 2 &&
            tally.dead == 2 &&
            tally.preedits == 2 &&
            tally.commits == 1 &&
            tally.composing &&
            !(tallied [pressed "a"]).composing },
    { name := "the tally's text is what the presses produced, in order, and a release adds nothing"
      run :=
        pure
          ((tallied
                [pressed "a", .key false false false "x", pressed "é", pressed "",
                  pressed "b"]).text ==
            "aéb") },
    { name := "the typed text and the committed text are cut at 60 characters"
      run := do
        let typed := tallied ((List.replicate 70 (pressed "é")) ++ [pressed "z"])
        let committed := tallied [.commit (repeated "ab" 31), .commit "z"]
        return typed.text == repeated "é" 60 && typed.presses == 71 &&
            committed.committed == repeated "ab" 30 &&
            committed.commits == 2 },
    { name :=
        "every key event is a latency sample, the time from its arrival to its handling, and nothing else is"
      run := do
        let tally :=
          counted
            [{ input := pressed "a", arrived := 100, handled := 350 },
              { input := .focus true, arrived := 400, handled := 900 },
              { input := released, arrived := 1000, handled := 1001 },
              { input := .key true true false "a", arrived := 2000, handled := 2000 },
              { input := .commit "é", arrived := 3000, handled := 4000 }]
        return tally.latencies == #[250, 1, 0] },
    { name :=
        "the tally keeps when the window opened, when it first gained the focus and when a pointer was first pressed in it"
      run := do
        let tally :=
          counted
            [{ input := .opened "fake", arrived := 10, handled := 11 },
              { input := .focus false, arrived := 20, handled := 21 },
              { input := .focus true, arrived := 30, handled := 31 },
              { input := .pointerPressed, arrived := 40, handled := 41 },
              { input := .focus true, arrived := 50, handled := 51 },
              { input := .pointerPressed, arrived := 60, handled := 61 }]
        let none : WindowCheck.Tally := {}
        return tally.platform == some "fake" && tally.openedAt == some 10 &&
            tally.focusedAt == some 30 &&
            tally.pointerAt == some 40 &&
            none.platform.isNone &&
            none.focusedAt.isNone &&
            none.pointerAt.isNone },
    { name :=
        "the median, the 99th percentile and the maximum are nearest-rank over the sorted samples: of 1, 2, 100 and 101 samples, and none of none"
      run := do
        let upTo (count : Nat) : Array Nat := ((List.range count).map (· + 1)).reverse.toArray
        return WindowCheck.spread #[] == none && WindowCheck.spread #[5] == some (5, 5, 5) &&
            WindowCheck.spread #[2, 1] == some (1, 2, 2) &&
            WindowCheck.spread (upTo 100) == some (50, 99, 100) &&
            WindowCheck.spread (upTo 101) == some (51, 100, 101) },
    { name := "an instant is printed to one decimal place, rounded down"
      run :=
        pure
          (WindowCheck.millis 2500000 == "2.5" && WindowCheck.millis 0 == "0.0" &&
            WindowCheck.micros 40500 == "40.5" &&
            WindowCheck.micros 999 == "0.9" &&
            WindowCheck.micros 123456789 == "123456.7") },
    { name := "the report of a window that opened is its eight lines, exactly"
      run := do
        let run : WindowCheck.Run :=
          { options := {}, serviceOnMain := true, askedAt := 1000000, failure := none
            tally := counted typed.arrivals, ending := .closed }
        return WindowCheck.report run == typedReport },
    { name :=
        "the report of a window that could not open is eight lines too: the reason in the second, once, and the others as when nothing arrived"
      run :=
        pure
          (WindowCheck.report (unopened "no display") ==
            ["window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: yes",
                "window: could not open: no display"] ++
              nothingArrived) },
    { name :=
        "a window that ran and never said that it opened is reported as one that could not open, however its run was ended: that reason in the second line, the last line that the window never opened, and status 1"
      run := do
        let silent (ending : WindowCheck.Ending) (inputs : List WindowCheck.Input := []) :
          WindowCheck.Run :=
          { options := {}, serviceOnMain := true, askedAt := 1000000, failure := none
            tally := tallied inputs, ending }
        let expected :=
          ["window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: yes",
              "window: could not open: the window ran and did not say that it opened"] ++
            nothingArrived
        -- What did arrive is still counted.
        let typedInto := WindowCheck.report (silent .closed [pressed "a"])
        return WindowCheck.report (silent .closed) == expected &&
            WindowCheck.report (silent .limit) == expected &&
            WindowCheck.status (silent .closed) == 1 &&
            WindowCheck.status (silent .limit) == 1 &&
            typedInto[1]? == expected[1]? &&
            typedInto[3]? ==
              some
                "keys: 1 key events reached the Lean loop (1 presses, 0 of them repeats, 0 releases); text: \"a\"" &&
            typedInto.getLast? == some "ended: the window never opened" &&
            WindowCheck.status (silent .closed [pressed "a"]) == 1 },
    { name :=
        "the focus line gives the gain and the first pointer press, each or neither, and judges nothing"
      run := do
        let line (inputs : List WindowCheck.Arrival) : Option String :=
          (WindowCheck.report
              { opened [] with
                tally :=
                  counted
                    ({ input := .opened "fake", arrived := 1000000, handled := 0 } :: inputs) })[2]?
        let gain : WindowCheck.Arrival := { input := .focus true, arrived := 3000000, handled := 0 }
        let press : WindowCheck.Arrival :=
          { input := .pointerPressed, arrived := 2500000, handled := 0 }
        return line [] == some "focus: never gained; first pointer press in the window: none" &&
            line [gain] ==
              some
                "focus: gained 2.0 ms after the window opened; first pointer press in the window: none" &&
            line [press] ==
              some
                "focus: never gained; first pointer press in the window: 1.5 ms after it opened" &&
            line [press, gain] ==
              some
                "focus: gained 2.0 ms after the window opened; first pointer press in the window: 1.5 ms after it opened" },
    { name := "the last line says how the check ended, in one of three ways"
      run := do
        let last (run : WindowCheck.Run) : Option String := (WindowCheck.report run).getLast?
        return last (opened []) == some "ended: the window was closed" &&
            last (opened [] {} .limit) == some "ended: the time limit" &&
            last (unopened "no display") == some "ended: the window never opened" },
    { name :=
        "the first line says what was asked for and where the main-thread service is, for each value of both"
      run := do
        let first (composition serviceOnMain : Bool) (seconds : Nat) : Option String :=
          (WindowCheck.report { opened [] { composition, seconds } with serviceOnMain }).head?
        return first true true 120 ==
              some
                "window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: yes" &&
            first false true 3 ==
              some
                "window-check: composition off, limit 3 s; the main-thread service is on the process's main thread: yes" &&
            first true false 120 ==
              some
                "window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: no" },
    { name :=
        "with no key the latency line says there are no samples, and the report is still eight lines"
      run := do
        let lines := WindowCheck.report (opened [.focus true])
        return lines.length == 8 &&
            lines[4]? ==
              some
                "latency from a key's arrival in Rust to its handling in Lean, in µs: no samples" },
    { name :=
        "typed text is printed quoted, so a key that produced a control character keeps the line whole"
      run :=
        pure
          ((WindowCheck.report
                (opened [pressed "a", pressed "\r", pressed "\"", pressed "b"]))[3]? ==
            some
              "keys: 4 key events reached the Lean loop (4 presses, 0 of them repeats, 0 releases); text: \"a\\x0d\\\"b\"") },
    { name := "the exit status is 0 for a window that ran and 1 for one that could not open"
      run :=
        pure
          (WindowCheck.status (opened []) == 0 &&
            WindowCheck.status (unopened "no display") == 1) }]

/-- The checks of the keyboard check itself (`WindowCheck.check`), on a fake
window written by hand: what it asks of the window and in what order, and
the report it prints. -/
def windowLoopChecks : List Check :=
  [{
      name :=
        "the check on a window that reports each thing prints the report of what arrived, and ends with status 0",
      run := do
        let checked ← typed.check
        return checked.lines == typedReport && checked.status == some 0 },
    { name :=
        "the check asks where the main-thread service is before it runs the window and never again, closes the window once when it is asked to close, and stops the loop when the window has closed"
      run := return (← typed.check).calls == ["probe", "run true", "close", "stop"] },
    { name := "a second request to close does not close the window again"
      run := do
        let twice : FakeWindow :=
          {
            arrivals :=
              [{ input := .opened "fake", arrived := 1, handled := 1 },
                { input := .closeRequested, arrived := 2, handled := 2 },
                { input := .closeRequested, arrived := 3, handled := 3 }] }
        return (← twice.check).calls == ["probe", "run true", "close", "stop"] },
    { name :=
        "an input that arrives after the close was asked for and before the stop is still counted"
      run := do
        let late : FakeWindow :=
          {
            arrivals :=
              [{ input := .opened "fake", arrived := 1, handled := 1 },
                { input := .closeRequested, arrived := 2, handled := 2 },
                { input := pressed "a", arrived := 3, handled := 4 },
                { input := pressed "b", arrived := 5, handled := 6 }] }
        return (← late.check).lines[3]? ==
            some
              "keys: 2 key events reached the Lean loop (2 presses, 0 of them repeats, 0 releases); text: \"ab\"" },
    { name :=
        "the window is run with composition allowed, and with it not allowed when the options say so, which the first line then says"
      run := do
        let allowed ← typed.check
        let refused ← typed.check { composition := false }
        return allowed.calls[1]? == some "run true" && refused.calls[1]? == some "run false" &&
            refused.lines.head? ==
              some
                "window-check: composition off, limit 120 s; the main-thread service is on the process's main thread: yes" },
    { name :=
        "the window line's time is from the clock's reading before the window was run to the instant the window opened"
      run := do
        let slow : FakeWindow :=
          { askedAt := 7000000
            arrivals :=
              [{ input := .opened "fake", arrived := 19300000, handled := 99000000 },
                { input := .closeRequested, arrived := 99000001, handled := 99000002 }] }
        return (← slow.check).lines[1]? ==
            some "window: opened by fake 12.3 ms after it was asked for" },
    { name :=
        "a window that cannot open gives the eight lines of that case, with the reason in the second, and status 1; nothing is closed, and the loop is still stopped"
      run := do
        let checked ← ({ cannotOpen := some "no display" } : FakeWindow).check
        return checked.lines ==
              ["window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: yes",
                  "window: could not open: no display"] ++
                nothingArrived &&
            checked.status == some 1 &&
            checked.calls == ["probe", "run true", "stop"] },
    { name :=
        "a window that runs and never says that it opened is closed by the time limit, and gives the eight lines of a window that could not open, with that reason in the second, and status 1"
      run := do
        let silent : FakeWindow := { arrivals := [], idleAt := some 3000000000 }
        let checked ← silent.check { seconds := 2 }
        return checked.lines ==
              ["window-check: composition on, limit 2 s; the main-thread service is on the process's main thread: yes",
                  "window: could not open: the window ran and did not say that it opened"] ++
                nothingArrived &&
            checked.status == some 1 &&
            checked.calls.eraseReps == ["probe", "run true", "close", "stop"] },
    { name := "what the fake says of the main-thread service is what the first line says"
      run := do
        let checked ← ({ typed with serviceOnMain := false } : FakeWindow).check
        return checked.lines.head? ==
            some
              "window-check: composition on, limit 120 s; the main-thread service is on the process's main thread: no" },
    { name :=
        "a window nobody closes is closed by the check once the time limit has passed on the clock, and the report says so"
      run := do
        let idle : FakeWindow :=
          { askedAt := 1000000000
            arrivals := [{ input := .opened "fake", arrived := 1000000001, handled := 1000000002 }]
            idleAt := some 3000000000 }
        let checked ← idle.check { seconds := 2 }
        -- The limit asks again at every look until the run has ended, so
        -- there is one close or several in a row.
        return checked.calls.eraseReps == ["probe", "run true", "close", "stop"] &&
            checked.lines.getLast? == some "ended: the time limit" &&
            checked.status == some 0 },
    { name :=
        "a time limit that has passed before the window's run has begun still ends the run: the close that came too early is forgotten, and the check asks again"
      run := do
        let slow : FakeWindow :=
          { arrivals := [{ input := .opened "fake", arrived := 1, handled := 2 }]
            slowToBegin := true }
        let checked ← slow.check { seconds := 0 }
        return checked.forgotten >= 1 && checked.status == some 0 &&
            checked.lines[1]?.any (·.startsWith "window: opened by fake ") &&
            checked.lines.getLast? == some "ended: the time limit" },
    { name := "a window that is closed before the time limit is not said to have reached it"
      run := do
        let checked ← ({ typed with idleAt := some 1000000 } : FakeWindow).check { seconds := 2 }
        return checked.lines.getLast? == some "ended: the window was closed" }]

/-- The checks of the keyboard check's command line: what its arguments ask
for (`WindowCheck.parse`), and what the check does with them
(`WindowCheck.withArguments`), on the fake window. -/
def windowArgumentChecks : List Check :=
  [{ name := "no arguments ask for composition allowed and a limit of 120 seconds",
     run := pure (WindowCheck.parse [] == some { composition := true, seconds := 120 }) },
    { name := "`--no-ime` asks for composition not allowed, and leaves the limit"
      run :=
        pure (WindowCheck.parse ["--no-ime"] == some { composition := false, seconds := 120 }) },
    { name := "`--seconds <n>` sets the limit, and leaves composition allowed"
      run :=
        pure (WindowCheck.parse ["--seconds", "3"] == some { composition := true, seconds := 3 }) },
    { name := "both options are understood together, in either order"
      run := do
        let both : Option WindowCheck.Options := some { composition := false, seconds := 3 }
        return WindowCheck.parse ["--no-ime", "--seconds", "3"] == both &&
            WindowCheck.parse ["--seconds", "3", "--no-ime"] == both },
    { name :=
        "`--seconds` with nothing after it, or with something that is not a number, is not understood"
      run :=
        pure
          (WindowCheck.parse ["--seconds"] == none &&
            WindowCheck.parse ["--seconds", "x"] == none &&
            WindowCheck.parse ["--no-ime", "--seconds"] == none &&
            WindowCheck.parse ["--seconds", "--no-ime"] == none) },
    { name := "an argument that is not an option is not understood, wherever it is"
      run :=
        pure
          (WindowCheck.parse ["--bogus"] == none && WindowCheck.parse ["3"] == none &&
            WindowCheck.parse ["--no-ime", "--bogus"] == none &&
            WindowCheck.parse ["--seconds", "3", "--bogus"] == none) },
    { name :=
        "with arguments that are not understood, the check says the usage, ends with status 2, and asks nothing of the window"
      run := do
        let checked ← typed.withArguments ["--bogus"]
        return checked.said == [WindowCheck.usage] && checked.status == some 2 &&
            checked.calls.isEmpty &&
            checked.lines.isEmpty },
    { name :=
        "with arguments that are understood, the check says what to do with the window and runs it as they ask: `--no-ime` runs the window with composition not allowed, and `--seconds` is the limit the report gives"
      run := do
        let checked ← typed.withArguments ["--no-ime", "--seconds", "3"]
        return checked.said == [WindowCheck.instructions] &&
            checked.calls == ["probe", "run false", "close", "stop"] &&
            checked.lines.head? ==
              some
                "window-check: composition off, limit 3 s; the main-thread service is on the process's main thread: yes" &&
            checked.status == some 0 },
    { name := "with no arguments, the check runs the window with composition allowed"
      run := do
        let checked ← typed.withArguments []
        return checked.lines == typedReport && checked.calls[1]? == some "run true" &&
            checked.status == some 0 }]

/-- A scene of two views, with every field of a scene and of a view set: the
first view focused, with two selections, a decoration and two status fields;
the second with none of those. Its content is named by handles only. -/
def twoViews : Scene where
  size := { width := 1600, height := 1200 }
  views :=
    #[{ id := ⟨0⟩, rect := { x := 0, y := 0, width := 800, height := 1160 }, snapshot := ⟨3⟩
        scroll := { text := ⟨1⟩, index := 0 }
        selections := #[{ text := ⟨1⟩, index := 1 }, { text := ⟨1⟩, index := 2 }]
        cursor := { shape := .block, face := ⟨"cursor.normal"⟩ }
        decorations := #[{ start := 4, stop := 9, face := ⟨"search.match"⟩ }]
        status :=
          #[{ text := "notes.txt", face := ⟨"status.name"⟩ },
            { text := "[+]", face := ⟨"status.modified"⟩ }] },
      { id := ⟨1⟩, rect := { x := 800, y := 0, width := 800, height := 1160 }, snapshot := ⟨4⟩
        scroll := { text := ⟨2⟩, index := 0 }, selections := #[]
        cursor := { shape := .bar, face := ⟨"cursor.insert"⟩ }, decorations := #[], status := #[] }]
  focused := some ⟨0⟩
  echo := "2 lines yanked"
  pending := "d2"
  preedit := some "´"

/-- The checks of the scene, which is plain data (`Editor/Scene.lean`). -/
def sceneChecks : List Check :=
  [{ name := "a scene of two views reads back every field it was built with",
     run :=
       pure
         (twoViews.size == { width := 1600, height := 1200 } && twoViews.views.size == 2 &&
           (twoViews.views[0]?.map (·.selections.size)) == some 2 &&
           (twoViews.views[0]?.map (·.decorations)) ==
             some #[{ start := 4, stop := 9, face := ⟨"search.match"⟩ }] &&
           (twoViews.views[0]?.map (·.status.map (·.text))) == some #["notes.txt", "[+]"] &&
           (twoViews.views[1]?.map (·.cursor)) ==
             some { shape := .bar, face := ⟨"cursor.insert"⟩ } &&
           (twoViews.views[1]?.map (·.rect.x)) == some 800 &&
           (twoViews.views[1]?.map (·.snapshot)) == some ⟨4⟩ &&
           (twoViews.views[1]?.map (·.scroll)) == some { text := ⟨2⟩, index := 0 } &&
           twoViews.focused == some ⟨0⟩ &&
           twoViews.echo == "2 lines yanked" &&
           twoViews.pending == "d2" &&
           twoViews.preedit == some "´") },
    { name := "two scenes are equal exactly when their fields are"
      run :=
        pure
          (twoViews == twoViews && twoViews != { twoViews with pending := "" } &&
            twoViews != { twoViews with views := twoViews.views.pop }) }]

/-- A display model whose cells are one pixel each way, holding `texts` as
the snapshots 0, 1, 2 and so on, with nothing published. -/
def displayOver (texts : List String) (cells : Display.Cells := { advance := 1, lineHeight := 1 }) :
    DisplayModel :=
  { cells, texts := (texts.toArray.mapIdx fun index text => (⟨index⟩, text)) }

/-- A display program's answer, or the refusal it failed with on the left, as
a value with equality. -/
def answered {α : Type} : Except DisplayError α → DisplayError ⊕ α
  | .ok answer => .inr answer
  | .error refusal => .inl refusal

/-- The rows the display model over `texts` answers to `query`. -/
def shownBy (texts : List String) (query : Display.RowsQuery)
    (cells : Display.Cells := { advance := 1, lineHeight := 1 }) :
    DisplayError ⊕ Array Display.Row :=
  answered ((Display.rowsShown query).runModel (displayOver texts cells)).1

/-- The checks of the display model that only it shows: what it recorded of
the scenes published to it. What it answers to the queries is the display
interface's contract (`displayFailures`). -/
def displayChecks : List Check :=
  [{
      name :=
        "the scenes published to the display model read back equal, in the order they were published",
      run := do
        let first := twoViews
        let second :=
          { twoViews with
            pending := "", echo := "" }
        let third :=
          { twoViews with
            views := #[], focused := none }
        let program : DisplayM Unit := do
          Display.publish first
          Display.publish second
          Display.publish third
        let (result, model) := program.runModel (displayOver [])
        return result matches .ok () && model.scenes == #[first, second, third] },
    { name := "a display model that nothing was published to has no scene"
      run := pure ((displayOver ["a"]).scenes == #[]) },
    { name := "a view r rows tall over lines no longer than its width shows r lines from its anchor"
      run :=
        pure
          (shownBy ["ab\ncd\nef\ngh"] { snapshot := ⟨0⟩, width := 4, height := 3, anchor := 3 } ==
            .inr #[⟨3, 5⟩, ⟨6, 8⟩, ⟨9, 11⟩]) },
    { name := "a line twice the view's width takes two rows, split at the width"
      run :=
        pure
          (shownBy ["abcdefgh\nij"] { snapshot := ⟨0⟩, width := 4, height := 3, anchor := 0 } ==
            .inr #[⟨0, 4⟩, ⟨4, 8⟩, ⟨9, 11⟩]) },
    { name := "the rows stop at the end of the text"
      run :=
        pure
          (shownBy ["ab\ncd"] { snapshot := ⟨0⟩, width := 4, height := 10, anchor := 0 } ==
            .inr #[⟨0, 2⟩, ⟨3, 5⟩]) },
    { name := "an anchor in the middle of a row starts at that row"
      run :=
        pure
          (shownBy ["abcdefgh\nij"] { snapshot := ⟨0⟩, width := 4, height := 2, anchor := 6 } ==
            .inr #[⟨4, 8⟩, ⟨9, 11⟩]) },
    { name :=
        "the layout rule in cells of 8 by 16: a width is cut down to whole cells, a height to whole rows, and a carriage return before a line feed is part of the break"
      run :=
        pure
          (shownBy ["abcdef\r\nxy"] { snapshot := ⟨0⟩, width := 39, height := 47, anchor := 0 }
                (cells := { advance := 8, lineHeight := 16 }) ==
              .inr #[⟨0, 4⟩, ⟨4, 6⟩] &&
            shownBy ["abcdef\r\nxy"] { snapshot := ⟨0⟩, width := 39, height := 48, anchor := 0 }
                (cells := { advance := 8, lineHeight := 16 }) ==
              .inr #[⟨0, 4⟩, ⟨4, 6⟩, ⟨8, 10⟩]) },
    { name := "a view narrower than a cell still shows one character a row"
      run :=
        pure
          (shownBy ["abc"] { snapshot := ⟨0⟩, width := 3, height := 32, anchor := 0 } (cells :=
              { advance := 8, lineHeight := 16 }) ==
            .inr #[⟨0, 1⟩, ⟨1, 2⟩]) },
    { name := "a carriage return that is not before a line feed is a character of its own"
      run :=
        pure
          (shownBy ["a\rb"] { snapshot := ⟨0⟩, width := 2, height := 2, anchor := 0 } ==
            .inr #[⟨0, 2⟩, ⟨2, 3⟩]) },
    { name :=
        "the rows of a snapshot the model does not have, or from an anchor inside a character or past the end, are refused"
      run :=
        pure
          (shownBy ["é"] { snapshot := ⟨1⟩, width := 4, height := 1, anchor := 0 } ==
              .inl .noSuchSnapshot &&
            shownBy ["é"] { snapshot := ⟨0⟩, width := 4, height := 1, anchor := 1 } ==
              .inl .badPosition &&
            shownBy ["é"] { snapshot := ⟨0⟩, width := 4, height := 1, anchor := 3 } ==
              .inl .badPosition) }]

/-- The checks of the undo tree's pure operations alone, which ask nothing of
a text: being told a revision, and the boundary. What the tree does to a
text is in `UndoTreeCases.cases`, run against the text model below. -/
def undoTreeChecks : List Check :=
  [{
      name :=
        "an undo tree told a revision has it in its open group, and told one that is not after the last it knew it is unchanged",
      run := do
        let tree := UndoTree.new ⟨0⟩ 3
        let told := tree.record 5
        return !tree.pending && told.pending && told.head == 5 && told.base == 3 &&
            told.record 5 == told &&
            told.record 4 == told &&
            tree.record 3 == tree &&
            tree.record 0 == tree },
    { name :=
        "a boundary with nothing pending makes no node, and with something pending makes one whose parent is where the text was"
      run := do
        let tree := UndoTree.new ⟨0⟩ 3
        let closed := (tree.record 5).close
        let made : UndoTree.NodeId := ⟨1⟩
        return tree.close == tree && closed.nodes.size == 2 && closed.current == made &&
            !closed.pending &&
            closed.node? made ==
              some { parent := some UndoTree.root, cross := some ⟨4, 5⟩, state := ⟨5⟩ } &&
            closed.node? UndoTree.root ==
              some { parent := none, children := #[made], next := some made, state := ⟨3⟩ } &&
            closed.close == closed },
    { name :=
        "an undo tree nobody edited is saved where it is; told an edit it is modified; marked saved it is not, there or at a state named to it; and the state it is in is named by the revision that put it there: the one the tree was made at, or the one it was told"
      run := do
        let tree := UndoTree.new ⟨0⟩ 3
        let told := tree.record 5
        let elsewhere : UndoTree.State := ⟨4⟩
        return !tree.isModified && tree.state == ⟨3⟩ && told.isModified && told.state == ⟨5⟩ &&
            !told.markSaved.isModified &&
            !(told.markSaved told.state).isModified &&
            (tree.markSaved told.state).isModified &&
            (told.markSaved elsewhere).isModified &&
            (told.markSaved.record 6).isModified &&
            !(tree.markSaved.markSaved).isModified },
    { name :=
        "a boundary does not change whether an undo tree is modified: saved where the text is, the saved state is the state of the new node; saved anywhere else, it stays, and is no node's"
      run := do
        let told := (UndoTree.new ⟨0⟩ 3).record 5
        let closed := told.markSaved.close
        let behind := told.markSaved.record 6
        return told.isModified && told.close.isModified && !told.markSaved.isModified &&
            !closed.isModified &&
            closed.saved == some told.state &&
            (closed.node? closed.current).map (·.state) == some told.state &&
            behind.isModified &&
            behind.close.isModified &&
            behind.close.saved == some told.state &&
            behind.close.nodes.all (·.state != told.state) },
    { name :=
        "a state has one name, whether or not a boundary has been set since it was taken: the state taken at the end of an open group is the state of the node a boundary makes of it, so a tree marked saved at it after the boundary is unmodified, and one that was told a further edit before the boundary is not"
      run := do
        let told := (UndoTree.new ⟨0⟩ 3).record 5
        let taken := told.state
        let closed := told.close
        let further := (told.record 6).close
        return closed.state == taken && !(closed.markSaved taken).isModified &&
            further.state != taken &&
            (further.markSaved taken).isModified }]

/-- The escape of `byte`: the character the text model keeps a byte that is
not valid UTF-8 as. It is four bytes of text. -/
def escapeOf (byte : Nat) : Char :=
  Char.ofNat (0x10DC00 + byte)

/-- The escapes of `bytes`, in order. -/
def escapesOf (bytes : List Nat) : String :=
  bytes.foldl (fun text byte => text.push (escapeOf byte)) ""

/-- Byte strings and the text the library keeps each as, written out by
hand: what `FileModel.decode` must make of the bytes, and what
`FileModel.encode` must make the bytes of again. -/
def decodings : List (String × ByteArray × String) :=
  [("Latin-1", ⟨#[0x63, 0x61, 0x66, 0xE9]⟩, "caf".push (escapeOf 0xE9)),
    ("bytes that are never valid", ⟨#[0x61, 0xFF, 0x62, 0xFE]⟩,
      (("a".push (escapeOf 0xFF)).push 'b').push (escapeOf 0xFE)),
    ("a sequence cut short at the end", ⟨#[0x61, 0xE2, 0x82]⟩, "a" ++ escapesOf [0xE2, 0x82]),
    ("a sequence cut short in the middle", ⟨#[0xF0, 0x9F, 0x98, 0x78]⟩,
      (escapesOf [0xF0, 0x9F, 0x98]).push 'x'),
    ("two overlong forms", ⟨#[0xC0, 0xAF, 0xE0, 0x80, 0xAF]⟩,
      escapesOf [0xC0, 0xAF, 0xE0, 0x80, 0xAF]),
    ("an encoded surrogate", ⟨#[0xED, 0xA0, 0x80]⟩, escapesOf [0xED, 0xA0, 0x80]),
    ("a continuation byte alone", ⟨#[0x61, 0x80, 0x62]⟩, ("a".push (escapeOf 0x80)).push 'b'),
    ("the lowest reserved code point, validly encoded", ⟨#[0xF4, 0x8D, 0xB2, 0x80]⟩,
      escapesOf [0xF4, 0x8D, 0xB2, 0x80]),
    ("the highest reserved code point, validly encoded", ⟨#[0xF4, 0x8D, 0xB3, 0xBF]⟩,
      escapesOf [0xF4, 0x8D, 0xB3, 0xBF]),
    ("the code points on either side of the reserved range",
      ⟨#[0xF4, 0x8D, 0xB1, 0xBF, 0xF4, 0x8D, 0xB4, 0x80]⟩,
      ("".push (Char.ofNat 0x10DC7F)).push (Char.ofNat 0x10DD00)),
    ("a code point above the maximum", ⟨#[0xF4, 0x90, 0x80, 0x80]⟩,
      escapesOf [0xF4, 0x90, 0x80, 0x80]),
    ("a lead byte F5", ⟨#[0xF5, 0x80, 0x80, 0x80]⟩, escapesOf [0xF5, 0x80, 0x80, 0x80]),
    ("two- and four-byte characters with a carriage return and a line feed",
      ⟨#[0xC3, 0xA9, 0xF0, 0x9F, 0x98, 0x80, 0x0D, 0x0A]⟩, "é😀\r\n")]

/-- Whether `reply` is the refusal `error`. -/
def refusedAs {α : Type} (reply : Except FileError α) (error : FileError) : Bool :=
  match reply with
  | .error refusal => refusal == error
  | .ok _ => false

/-- The directory the model's files are in, in the checks below. -/
def modelRoot : System.FilePath :=
  "/model"

/-- A file's bytes: "h", a carriage return and a line feed, "😀", two bytes
that are not UTF-8 and a line feed alone. Ten bytes. -/
def mixedBytes : ByteArray :=
  ⟨#[0x68, 0x0D, 0x0A, 0xF0, 0x9F, 0x98, 0x80, 0xE9, 0xFF, 0x0A]⟩

/-- The text `mixedBytes` loads as, written out by hand. Sixteen bytes. -/
def mixedText : String :=
  ("h\r\n😀" ++ escapesOf [0xE9, 0xFF]).push '\n'

/-- A file of `size` bytes, each "a" but for a NUL byte at `nul`. -/
def withNul (size nul : Nat) : ByteArray :=
  ⟨(Array.replicate size (0x61 : UInt8)).setIfInBounds nul 0⟩

/-- A model with the directory `modelRoot` and, in it, `mixed.txt` holding
`mixedBytes`. The editor has published two snapshots, the second released;
the first holds a text that the job's first load will not. -/
def modelWithFile : FileModel :=
  let model :=
    (({} : FileModel).withDirectory modelRoot).withFile (modelRoot / "mixed.txt") mixedBytes
  { model with
    snapshots := #[some { contents := "pub é".push (escapeOf 0xFF), revision := 4 }, none] }

/-- The checks of the pure model of the files a job reaches
(`Editor/File/Model.lean`) and of the file data (`Editor/File.lean`). They
touch no file. -/
def fileModelChecks : List Check :=
  [{
      name :=
        "the file model decodes bytes to the text the library keeps them as, and encodes that text to the bytes again: thirteen byte strings, each against a text written out by hand",
      run :=
        pure
          (decodings.all fun (_, bytes, text) =>
            FileModel.decode bytes == text && FileModel.encode text == bytes) },
    { name :=
        "the file model's load answers a snapshot under the next id, holding the file's text, with the file's length in bytes as the stamp's size and its line endings"
      run := do
        let (first, model) := modelWithFile.load (modelRoot / "mixed.txt") 10
        let (second, after) := model.load (modelRoot / "mixed.txt") 1000
        let .ok first := first | return false
        let .ok second := second | return false
        return first.snapshot == ⟨0⟩ && second.snapshot == ⟨1⟩ && first.stamp.size == 10 &&
            first.endings == ⟨1, 1⟩ &&
            second.stamp == first.stamp &&
            after.held ==
              #[some { contents := mixedText, revision := 0 },
                some { contents := mixedText, revision := 0 }] &&
            after.files == modelWithFile.files &&
            after.snapshots == modelWithFile.snapshots },
    { name :=
        "the file model counts line endings on the bytes: a line feed alone, one after a carriage return, both, and a carriage return alone as neither"
      run :=
        pure
          (FileModel.lineEndings "a\nb\n".toUTF8 == ⟨2, 0⟩ &&
            FileModel.lineEndings "a\r\nb\r\n".toUTF8 == ⟨0, 2⟩ &&
            FileModel.lineEndings "\na\r\nb\nc\rd\r".toUTF8 == ⟨2, 1⟩ &&
            FileModel.lineEndings "abc".toUTF8 == ⟨0, 0⟩ &&
            FileModel.lineEndings ByteArray.empty == ⟨0, 0⟩) },
    { name :=
        "the file model refuses a load in the library's order, and a refused load changes nothing: a path that is not absolute, nothing there, a directory, a file over the limit, and a NUL byte among the first 8,000 bytes"
      run := do
        let model :=
          ((modelWithFile.withFile (modelRoot / "early") (withNul 8001 7999)).withFile
                (modelRoot / "late") (withNul 8001 8000)).withFile
            (modelRoot / "both") (withNul 20 3)
        let refusals :=
          [(model.load "missing.txt" 1000, FileError.relativePath),
            (model.load (modelRoot / "missing.txt") 1000, .notFound),
            (model.load (modelRoot / "none" / "mixed.txt") 1000, .notFound),
            (model.load modelRoot 1000, .notAFile),
            (model.load (modelRoot / "mixed.txt") 9, .tooLarge 10 9),
            (model.load (modelRoot / "early") 9000, .binary 7999),
            -- Over the limit and binary: the limit is looked at first.
            (model.load (modelRoot / "both") 19, .tooLarge 20 19),
            (model.load (modelRoot / "both") 20, .binary 3)]
        let (late, _) := model.load (modelRoot / "late") 9000
        return refusals.all
              (fun ((reply, after), refusal) => refusedAs reply refusal && after == model) &&
            late.toOption.isSome },
    { name :=
        "the file model refuses a save in the library's order, and a refused save changes nothing: a source that names nothing, a path that is not absolute, a directory, a file that is not what is expected, and a directory that is not there"
      run := do
        let (loaded, model) := modelWithFile.load (modelRoot / "mixed.txt") 1000
        let .ok loaded := loaded | return false
        let held := File.Source.held loaded.snapshot
        let stale : File.Stamp := { loaded.stamp with seconds := loaded.stamp.seconds + 1 }
        let refusals :=
          [(model.save (.held ⟨1⟩) "relative.txt" .whatever, FileError.noSuchSnapshot),
            (model.save (.snapshot ⟨1⟩) "relative.txt" .whatever, .noSuchSnapshot),
            (model.save (.snapshot ⟨2⟩) (modelRoot / "new.txt") .whatever, .noSuchSnapshot),
            (model.save held "relative.txt" .whatever, .relativePath),
            (model.save held modelRoot .whatever, .notAFile),
            (model.save held (modelRoot / "mixed.txt") .absent, .changed (some loaded.stamp)),
            (model.save held (modelRoot / "mixed.txt") (.unchanged stale),
              .changed (some loaded.stamp)),
            (model.save held (modelRoot / "new.txt") (.unchanged loaded.stamp), .changed none),
            -- The expectation is looked at before the directory.
            (model.save held (modelRoot / "none" / "new.txt") (.unchanged loaded.stamp),
              .changed none),
            (model.save held (modelRoot / "none" / "new.txt") .absent, .notFound),
            (model.save held (modelRoot / "none" / "new.txt") .whatever, .notFound)]
        return refusals.all fun ((reply, after), refusal) =>
            refusedAs reply refusal && after == model },
    { name :=
        "the file model's save writes the file and answers its stamp, which the next save accepts and which every write changes: over the file that is expected, where no file is expected, and over whatever is there"
      run := do
        let (loaded, model) := modelWithFile.load (modelRoot / "mixed.txt") 1000
        let .ok loaded := loaded | return false
        let held := File.Source.held loaded.snapshot
        let (over, model) := model.save held (modelRoot / "mixed.txt") (.unchanged loaded.stamp)
        let .ok over := over | return false
        let (again, model) := model.save held (modelRoot / "mixed.txt") (.unchanged over)
        let .ok again := again | return false
        let (stale, model) := model.save held (modelRoot / "mixed.txt") (.unchanged over)
        let (fresh, model) := model.save held (modelRoot / "new.txt") .absent
        let .ok fresh := fresh | return false
        let (whatever, model) := model.save held (modelRoot / "new.txt") .whatever
        let .ok whatever := whatever | return false
        return over != loaded.stamp && again != over && refusedAs stale (.changed (some again)) &&
            whatever != fresh &&
            [over, again, fresh, whatever].all (·.size == 10) &&
            model.contents ==
              #[(modelRoot / "mixed.txt", mixedBytes), (modelRoot / "new.txt", mixedBytes)] },
    { name :=
        "a save from what a load made and a save from what the editor published each write the bytes of that snapshot, though the two ids have one number, and neither changes what was published; a released snapshot of the job's is no source"
      run := do
        let (loaded, model) := modelWithFile.load (modelRoot / "mixed.txt") 1000
        let .ok loaded := loaded | return false
        let (held, model) := model.save (.held loaded.snapshot) (modelRoot / "held.txt") .absent
        let (published, model) := model.save (.snapshot ⟨0⟩) (modelRoot / "published.txt") .absent
        let (gone, after) :=
          (model.released loaded.snapshot).save (.held loaded.snapshot) (modelRoot / "gone.txt")
            .absent
        return loaded.snapshot.number == 0 && held.toOption.isSome && published.toOption.isSome &&
            (model.file? (modelRoot / "held.txt")).map (·.bytes) == some mixedBytes &&
            (model.file? (modelRoot / "published.txt")).map (·.bytes) ==
              some ⟨#[0x70, 0x75, 0x62, 0x20, 0xC3, 0xA9, 0xFF]⟩ &&
            model.snapshots == modelWithFile.snapshots &&
            refusedAs gone .noSuchSnapshot &&
            (after.file? (modelRoot / "gone.txt")).isNone &&
            ((after.load (modelRoot / "mixed.txt") 1000).1.toOption.map (·.snapshot)) == some ⟨1⟩ },
    { name :=
        "the dominant line ending is CRLF when there are more of those, LF otherwise when there is any line break, and none for a file with no line break"
      run :=
        pure
          ((File.LineEndings.mk 3 0).dominant == some .lf &&
            (File.LineEndings.mk 0 2).dominant == some .crlf &&
            (File.LineEndings.mk 2 3).dominant == some .crlf &&
            (File.LineEndings.mk 3 2).dominant == some .lf &&
            (File.LineEndings.mk 2 2).dominant == some .lf &&
            (File.LineEndings.mk 0 0).dominant == none) },
    { name :=
        "each file error describes its own thing: no two say the same, a binary file's says its offset, a file too large its size and its limit, a changed file whether one is there, and a failure its detail"
      run := do
        let errors : List FileError :=
          [.relativePath, .notFound, .notAFile, .denied, .binary 7999, .tooLarge 4321 1234,
            .changed none, .changed (some { seconds := 5, nanoseconds := 6, size := 8765 }),
            .noSuchSnapshot, .noTemporaryName, .failed "the disk is on fire"]
        let said := errors.map FileError.describe
        let says (error : FileError) (part : String) : Bool :=
          (error.describe.splitOn part).length > 1
        return said.eraseDups.length == errors.length && said.all (· != "") &&
            says (.binary 7999) "7999" &&
            says (.tooLarge 4321 1234) "4321" &&
            says (.tooLarge 4321 1234) "1234" &&
            says (.changed (some { seconds := 5, nanoseconds := 6, size := 8765 })) "8765" &&
            says (.failed "the disk is on fire") "the disk is on fire" &&
            says .relativePath "absolute" &&
            says .notFound "nothing" &&
            says .notAFile "not a file" &&
            says .noSuchSnapshot "snapshot" }]

/-- Every check, in the order they run.

The order matters where the process's one pool is measured. `poolChecks` run
first, on a pool nothing has used. Within `runnerChecks`, the check that
counts the threads jobs wait from comes before any check that holds a job in
pure code on a promise: pure code blocked in `Task.get` on a pool thread
makes Lean add a thread to the pool, which a later burst can land on. -/
def checks : List Check :=
  poolChecks ++ programChecks ++ jobModelChecks ++ waitChecks ++ runnerChecks ++ tableChecks ++
    ownerChecks ++
    fileRunnerChecks ++
    setupChecks ++
    registryChecks ++
    storeChecks ++
    sessionChecks ++
    reloadChecks ++
    windowTallyChecks ++
    windowLoopChecks ++
    windowArgumentChecks ++
    undoTreeChecks ++
    fileModelChecks ++
    sceneChecks ++
    displayChecks

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

/-- The properties run against the text model: the text port's contract,
those of the commands, and the cases of the undo tree, which is plain Lean
over the port. -/
def textProperties : List TextContract.Property :=
  TextContract.properties ++ commandProperties ++ UndoTreeCases.cases

/-- The names of the `textProperties` that do not hold of the text model, each
run from a model with no texts. -/
def textFailures : IO (List String) := do
  let failed ← TextContract.failures (fun command => pure (command.runModel {}).1) textProperties
  return failed.map (s!"the text model: {·}")

/-- The names of the properties of taking a job's snapshot into the store
that do not hold of the text model. Each is run from a model with no texts
that was handed, as what a job held, the strings the property names. -/
def adoptFailures : IO (List String) := do
  let failed ←
    TextContract.adoptFailures
        (fun arrived command =>
          pure
            (command.runModel
                { arrived := arrived.map fun (id, text) => (id, { contents := text }) }).1)
        TextContract.adoptProperties
  return failed.map (s!"the text model: {·}")

/-- The names of the job port's contract properties that do not hold of the
job model, each run from a clock at 0 that nothing cancels. -/
def jobModelFailures : IO (List String) := do
  let failed ← JobContract.failures (fun job => pure (job.runModel {}).1) JobContract.properties
  return failed.map (s!"the job model: {·}")

end ModelTest

/-- Runs the checks, then the text port's contract against its model and the
job port's contract against its model and against the runner over the fake
clock: exits 0 when all hold, and 1 after naming on stderr the ones that do
not.

It exits explicitly. A check of the job runner that failed may have left a
task that never ends, and returning from `main` would wait for it for ever:
seen once by hand, with a dedicated task in an endless loop. -/
def main : IO UInt32 := do
  let failed :=
    (← ModelTest.failures ModelTest.checks) ++ (← ModelTest.textFailures) ++
      (← ModelTest.adoptFailures) ++
      (← ModelTest.jobModelFailures) ++
      (← ModelTest.jobRunnerFailures) ++
      (← ModelTest.fileFailures) ++
      (← ModelTest.caseFailures)
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  unless failed.isEmpty do
    -- A check that failed may have left a task that never ends, and
    -- returning from `main` would wait for it for ever.
    IO.Process.exit 1
  IO.println
      s!"model-test: {ModelTest.checks.length} checks passed, {Editor.TextContract.properties.length + Editor.TextContract.adoptProperties.length + ModelTest.commandProperties.length} properties hold of the text model, {Editor.UndoTreeCases.cases.length} cases of the undo tree hold over it, and {Editor.JobContract.properties.length} properties of the job model and of the job runner over the fake clock, and {Editor.JobContract.fileProperties.length} file properties of the job model and of the job runner over the fake file service; {Editor.FileCases.cases.length} cases across the text port and the job port hold of the two models"
  (← IO.getStdout).flush
  IO.Process.exit 0
