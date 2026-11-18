import Editor.Api.Cases
import Editor.Buffers.Compiled
import Editor.Clipboard.Contract
import Editor.Command.Append
import Editor.Command.Model
import Editor.Compile.Compiled
import Editor.Compile.Shipped
import Editor.Config.Display
import Editor.Display.Contract
import Editor.Evil.Compiled
import Editor.Ex.Compiled
import Editor.Executable
import Editor.File.Cases
import Editor.File.Model
import Editor.FileWatch.Model
import Editor.Files.Compiled
import Editor.FrameCommands.Compiled
import Editor.Fuzzy.Contract
import Editor.Headless.CommandLine
import Editor.InputScheme.Contract
import Editor.Job.Contract
import Editor.Job.Fake
import Editor.Job.Jobs
import Editor.Job.Model
import Editor.Job.Pool
import Editor.Loop.Driver
import Editor.Menu.Compiled
import Editor.Minibuffer.Compiled
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Shell.Compiled
import Editor.SyntaxTree.Contract
import Editor.TabCommands.Compiled
import Editor.Themes.Compiled
import Editor.Version
import Editor.Watch.Contract
import Editor.WindowCheck
import Editor.WindowCommands.Compiled
import Editor.Workspace.Compiled
import Editor.Workspace.Contract
import ModelTest.Check

/-!
# Model tests: jobs

The checks of the program type, the job model and the job runner, and of
what runs on them: waits, processes, the pool, the runner's table, owners
and the file runner.

Its lists of checks: `programChecks`, `jobModelChecks`, `waitChecks`,
`processChecks`, `poolChecks`, `runnerChecks`, `tableChecks`, `ownerChecks`,
`fileRunnerChecks`.

The root module `ModelTest` describes each group and runs them all from
`checks`.
-/

namespace ModelTest

open Editor

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
        "in the job model, a run whose script takes longer than its time limit is refused as timedOut with the clock at exactly its start plus the limit, and is killed; one within its limit moves the clock by what it takes and is not killed"
      run :=
        let slow := JobContract.sh "/p" "/bin/sleep 600"
        let quick := JobContract.sh "/p" "exit 0"
        let model : JobModel :=
          { now := 10
            processes :=
              {
                scripts :=
                  #[{ command := slow,
                      reply := .ok { exit := .code 0, stdout := .empty, stderr := .empty }
                      takes := 600000 },
                    { command := quick,
                      reply := .ok { exit := .code 0, stdout := .empty, stderr := .empty }
                      takes := 30 }] } }
        let (late, afterLate) := (Process.runWithin slow 100 50).runModel model
        let (within, afterWithin) := (Process.runWithin quick 100 50).runModel model
        pure
          ((match late with
            | .finished (.error (.timedOut 50)) => true
            | _ => false) &&
            afterLate.now == 60 &&
            afterLate.processes.killed == #[slow] &&
            (match within with
            | .finished (.ok ran) => ran.exit == .code 0
            | _ => false) &&
            afterWithin.now == 40 &&
            afterWithin.processes.killed == #[]) },
    { name :=
        "in the job model, a cancel that falls before a run's time limit ends the job cancelled at that instant, and the run is killed once"
      run :=
        let slow := JobContract.sh "/p" "/bin/sleep 600"
        let model : JobModel :=
          { cancelAt := some 20
            processes :=
              {
                scripts :=
                  #[{ command := slow,
                      reply := .ok { exit := .code 0, stdout := .empty, stderr := .empty }
                      takes := 600000 }] } }
        let (outcome, after) := (Process.runWithin slow 100 50).runModel model
        pure
          ((match outcome with
            | .cancelled => true
            | _ => false) &&
            after.now == 20 &&
            after.processes.killed == #[slow]) },
    { name :=
        "in the job model, environment requests are answered from its environments without moving the clock, and a message they say is reported"
      run :=
        let failure := Process.Failure.signalled 9
        let entry : Process.Entry := { stamps := #[], found := .failed failure }
        let job : JobM (Option Process.Entry × Process.Policy) := do
          Process.askEnvironment (.record "/p/d" entry)
          let found ← Process.askEnvironment (.cached "/p/d")
          let policy ← Process.askEnvironment .policy
          return (found, policy)
        let (outcome, after) :=
          job.runModel { now := 7, environments := { setting := .inherited, limit := 3 } }
        pure
          (outcome ==
              .finished
                (some entry,
                  { setting := .inherited, host := .headless, resolved := none, limit := 3 }) &&
            after.now == 7 &&
            after.reported == #[Process.failureMessage "/p/d" failure]) },
    { name := "in the job model, a post is recorded and answered at once, without moving the clock"
      run :=
        let job : JobM Nat := do
          post (JobContract.posting "first")
          sleep 5
          post (JobContract.posting "second" [.nat 2])
          return 9
        let (outcome, after) := job.runModel { now := 3 }
        pure
          (outcome == .finished 9 && after.now == 8 &&
            after.posted ==
              #[JobContract.posting "first", JobContract.posting "second" [.nat 2]]) },
    { name :=
        "in the job model, a run that parks parks at each post, with it recorded and the clock where it was, and resumes from there to its end"
      run :=
        let job : JobM Nat := do
          post (JobContract.posting "first")
          sleep 5
          post (JobContract.posting "second" [.nat 2])
          return 9
        let parkedAt {α : Type} : JobModel.Ran α → Option (Invocation × Array Invocation × Nat)
          | .posted invocation model _ => some (invocation, model.posted, model.now)
          | _ => none
        let first := JobModel.runParking job.run { now := 3 }
        let second :=
          match first with
          | .posted _ model resume => some (JobModel.runParking (resume ()) model)
          | _ => none
        let third :=
          match second with
          | some (.posted _ model resume) => some (JobModel.runParking (resume ()) model)
          | _ => none
        pure
          (parkedAt first ==
              some (JobContract.posting "first", #[JobContract.posting "first"], 3) &&
            (second.bind parkedAt).map (·.1) == some (JobContract.posting "second" [.nat 2]) &&
            (second.bind parkedAt).map (·.2.2) == some 8 &&
            (match third with
            | some (.ended (some (.ok 9)) model) => model.posted.size == 2
            | _ => false)) },
    { name :=
        "in the job model, a run that parks does not park at a post once a cancel is due: the job is cancelled at its wait"
      run :=
        let job : JobM Unit := do
          post (JobContract.posting "first")
          sleep 10
          post (JobContract.posting "second")
        pure
          (match JobModel.runParking job.run { cancelAt := some 5 } with
          | .ended none model => model.posted == #[JobContract.posting "first"] && model.now == 5
          | _ => false) },
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

/-- The editor's models with no text, the display's in cells one pixel each
way, with nothing published. -/
def editorModel : EditorModel :=
  .over { advance := 1, lineHeight := 1 }

/-- A command that makes one text holding `text`. What a registered command
does is observed by running it: commands are programs, and cannot be compared. -/
def makes (text : String) : EditorM Unit :=
  discard <| createText text

/-- The texts `command` leaves when it runs against the editor's models with
no text. -/
def textsOf (command : EditorM Unit) : Array String :=
  (command.runModel editorModel).2.texts.contents

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

/-- Runs `job` on the runner over a fake clock of its own, spawned with a host
that records each post it is handed, and answers the posts once the job has
ended. The clock is advanced to each deadline, as `runOnFake` does. -/
def postedOnFake (job : JobM Unit) : IO (Array Invocation) := do
  let rig ← Rig.new
  let posts ← IO.mkRef #[]
  let handle ←
    Job.spawn rig.services (Work.of (fun _ => job) fun _ => pure ()) (pure ()) fun invocation =>
        posts.modify (·.push invocation)
  let ended ←
    eventually do
        if ← handle.ended then
          return true
        if let some deadline← rig.clock.nextDeadline then
          rig.clock.advance (deadline - (← rig.clock.now))
        return false
  unless ended do
    handle.cancel
  posts.get

/-- The names of the job port's post properties that do not hold of the job
model, and of those that do not hold of the runner over the fake clock. -/
def postFailures : IO (List String) := do
  let onModel ←
    JobContract.postFailures (fun job => pure (job.runModel {}).2.posted) JobContract.postProperties
  let onFake ← JobContract.postFailures postedOnFake JobContract.postProperties
  return onModel.map (s!"the job model: {·}") ++
      onFake.map (s!"the job runner over the fake clock: {·}")

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
  return ({ rig with
        services :=
          { rig.services with
            files := files.files, diffs := files.diffs } },
      files)

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

/-- The names of the job port's file and diff properties that do not hold of
the job model, and of those that do not hold of the runner over the fake of
the file service, whose model answers a diff. -/
def fileFailures : IO (List String) := do
  let properties := JobContract.fileProperties ++ JobContract.diffProperties
  let onModel ← JobContract.fileFailures runFilesOnModel properties
  let onFake ← JobContract.fileFailures runFilesOnFake properties
  return onModel.map (s!"the job model: {·}") ++
      onFake.map (s!"the job runner over the fake file service: {·}")

/-- The made-up directory the commands of a process property run in, for the
model and for the fake of the process service: an absolute path that is
never opened. -/
def processRoot : System.FilePath :=
  "/processes"

/-- The model of the processes a process property's commands are scripted
as. -/
def processModelOf (property : JobContract.ProcessProperty) : ProcessModel :=
  { scripts := property.scripts processRoot, streams := property.streams processRoot }

/-- Runs a process property's job against the job port's model, over the
model of its processes: how the job ended. -/
def runProcessesOnModel (property : JobContract.ProcessProperty) : IO (Job.Outcome Bool) :=
  pure ((property.holds processRoot).runModel { processes := processModelOf property }).1

/-- A rig whose services have a fake process service over `model`, and that
service. -/
def Rig.withProcesses (model : ProcessModel) : BaseIO (Rig × Job.FakeProcesses) := do
  let rig ← Rig.new
  let processes ← Job.FakeProcesses.new rig.services.completions model
  return ({ rig with services := { rig.services with processes := processes.processes } },
      processes)

/-- Runs a process property's job on the runner over a fake clock and the
fake of the process service, over the model of its processes: how the job
ended. -/
def runProcessesOnFake (property : JobContract.ProcessProperty) : IO (Job.Outcome Bool) := do
  let (rig, _) ← Rig.withProcesses (processModelOf property)
  runOnFake (property.holds processRoot) (some rig)

/-- The names of the job port's process properties that do not hold of the
job model, and of those that do not hold of the runner over the fake of the
process service. -/
def processFailures : IO (List String) := do
  let onModel ← JobContract.processFailures runProcessesOnModel JobContract.processProperties
  let onFake ← JobContract.processFailures runProcessesOnFake JobContract.processProperties
  return onModel.map (s!"the job model: {·}") ++
      onFake.map (s!"the job runner over the fake process service: {·}")

/-- The made-up directory the watch checks and the watch properties watch,
for the model and the fake: an absolute path that is never opened. -/
def watchRoot : System.FilePath :=
  "/watched"

/-- The models a watch property's directories, files and scripts are, for
the job model and the fake, in `watchRoot`: the directory and its
subdirectories, and each script as a run that ends with the status 0 and
changes what it touches. -/
def watchModelsOf (property : JobContract.FileWatchProperty) : ProcessModel × FileWatchModel :=
  let commandOf (script : JobContract.FileWatchScript) := JobContract.sh watchRoot script.script
  let processes : ProcessModel :=
    {
      scripts :=
        property.scripts.map fun script =>
          { command := commandOf script
            reply := .ok { exit := .code 0, stdout := .empty, stderr := .empty } } }
  let watches : FileWatchModel :=
    { directories :=
        #[watchRoot] ++ property.directories.map fun (name : String) => watchRoot / name
      effects :=
        property.scripts.map fun script =>
          (commandOf script, script.touches.map fun (name, kind) => (watchRoot / name, kind)) }
  (processes, watches)

/-- Runs a watch property's job against the job port's model: how the job
ended. -/
def runWatchesOnModel (property : JobContract.FileWatchProperty) : IO (Job.Outcome Bool) :=
  let (processes, fileWatches) := watchModelsOf property
  pure ((property.holds watchRoot).runModel { processes, fileWatches }).1

/-- A rig whose services have a fake watch service over `watches` and a fake
process service over `processes`, whose runs touch the watches with what
their commands change; and the two services. -/
def Rig.withWatches (processes : ProcessModel) (watches : FileWatchModel) :
    BaseIO (Rig × Job.FakeProcesses × Job.FakeFileWatches) := do
  let rig ← Rig.new
  let fileWatches ← Job.FakeFileWatches.new rig.services.completions watches
  let fakeProcesses ← Job.FakeProcesses.new rig.services.completions processes fileWatches.ran
  return ({ rig with
        services :=
          { rig.services with
            processes := fakeProcesses.processes, fileWatches := fileWatches.fileWatches } },
      fakeProcesses, fileWatches)

/-- Runs a watch property's job on the runner over a fake clock, the fake of
the process service and the fake of the watch service: how the job ended. -/
def runWatchesOnFake (property : JobContract.FileWatchProperty) : IO (Job.Outcome Bool) := do
  let (processes, fileWatches) := watchModelsOf property
  let (rig, _, _) ← Rig.withWatches processes fileWatches
  runOnFake (property.holds watchRoot) (some rig)

/-- The names of the job port's watch properties that do not hold of the job
model, and of those that do not hold of the runner over the fakes. -/
def fileWatchFailures : IO (List String) := do
  let onModel ← JobContract.fileWatchFailures runWatchesOnModel JobContract.fileWatchProperties
  let onFake ← JobContract.fileWatchFailures runWatchesOnFake JobContract.fileWatchProperties
  return onModel.map (s!"the job model: {·}") ++
      onFake.map (s!"the job runner over the fake watch service: {·}")

/-- A command that sleeps for ten minutes in `processRoot`, as the process
checks script it. -/
def sleeper : Process.Command :=
  JobContract.sh processRoot "/bin/sleep 600"

/-- The script of `sleeper`, which takes `takes` milliseconds. -/
def sleeperScript (takes : Nat) : Process.Script :=
  { command := sleeper, reply := .ok { exit := .code 0, stdout := .empty, stderr := .empty },
    takes }

/-- What the process model answers a run of `command` under `limit` made at
`now` by a job cancelled at `cancelAt`, with the reply's type spelled out. -/
def modelRun (model : ProcessModel) (now : Nat) (cancelAt : Option Nat) (command : Process.Command)
    (limit : Nat) : Except ProcessError Process.Ran × ProcessModel × Nat :=
  model.handle now cancelAt (.run command limit)

/-- The checks of processes a job runs: the model's order of refusals and its
record of what was killed, and the runner's process waits on the fake of the
process service, where cancelling a job withdraws its wait, which is how the
library comes to kill the job's child. -/
def processChecks : List Check :=
  [{  name :=
        "the process model refuses a relative directory, then a relative program, then an unscripted command as not found, and starts none of them"
      run := do
        let model : ProcessModel := { scripts := #[sleeperScript 0] }
        let ask (command : Process.Command) := modelRun model 0 none command 10
        let (directory, afterDirectory, _) := ask { program := "bin/sh", directory := "relative" }
        let (program, afterProgram, _) := ask { program := "bin/sh", directory := processRoot }
        let (unscripted, afterUnscripted, _) :=
          ask { program := "/bin/sh", directory := processRoot }
        let isNotFound :=
          match unscripted with
          | .error (.notFound _) => true
          | _ => false
        return directory == .error .relativeDirectory && program == .error .relativeProgram &&
            isNotFound &&
            [afterDirectory, afterProgram, afterUnscripted].all (·.started.isEmpty) },
    { name :=
        "the process model records a scripted run as started, moves the clock by its time, and answers too large past the limit, standard output first"
      run := do
        let ran : Process.Ran :=
          { exit := .code 0, stdout := "123456".toUTF8, stderr := "123456".toUTF8 }
        let model : ProcessModel :=
          { scripts := #[{ command := sleeper, reply := .ok ran, takes := 7 }] }
        let (within, after, now) := modelRun model 3 none sleeper 6
        let (over, _, _) := modelRun model 3 none sleeper 5
        let quiet : ProcessModel :=
          {
            scripts :=
              #[{ command := sleeper, reply := .ok { ran with stdout := .empty }, takes := 7 }] }
        let (err, _, _) := modelRun quiet 3 none sleeper 5
        return within == .ok ran && after.started == #[sleeper] && now == 10 &&
            over == .error (.outputTooLarge .out 5) &&
            err == .error (.outputTooLarge .err 5) &&
            after.killed.isEmpty },
    { name :=
        "a job model cancelled inside a scripted run is cancelled at that instant, and the process model records the command as killed"
      run := do
        let job : JobM Bool := do
          discard <| Process.run sleeper 10
          return true
        let (outcome, model) :=
          job.runModel { cancelAt := some 50, processes := { scripts := #[sleeperScript 100] } }
        let (finished, untouched) :=
          job.runModel { cancelAt := some 500, processes := { scripts := #[sleeperScript 100] } }
        return outcome == .cancelled && model.now == 50 && model.processes.killed == #[sleeper] &&
            finished == .finished true &&
            untouched.processes.killed.isEmpty },
    { name :=
        "cancelling a job in a process wait withdraws the wait from the process service with the wait's id, the job ends cancelled, and it makes no further request"
      run := do
        let (rig, processes) ← Rig.withProcesses { scripts := #[sleeperScript 0] }
        processes.holdCompletions
        let spawned ←
          rig.spawn
              (reporting fun _ => do
                discard <| Process.run sleeper 10
                discard <| Process.run sleeper 10
                return true)
        try
          unless ← eventually (return (← processes.waiting) == 1) do
            return false
          let id := ((← processes.started)[0]?.map (·.1)).getD 0
          spawned.handle.cancel
          let cancelled ← spawned.endedAs .cancelled
          processes.letGo
          return cancelled && (← processes.withdrawn) == #[id] && (← processes.started).size == 1 &&
              (← processes.taken).isEmpty &&
              (← processes.waiting) == 0
        finally
          processes.letGo },
    { name :=
        "a runner given no process service refuses a run as failed, as a value, and the job goes on"
      run := do
        let rig ← Rig.new
        let spawned ←
          rig.spawn
              (reporting fun _ => do
                let .error (.failed _) ← Process.run sleeper 10 | return false
                return true)
        spawned.endedAs (.finished #["true"]) },
    { name :=
        "one read delivers every line a child wrote before it waits on its input, on the model and on the fake, where the read is one start and one take: one completion"
      run := do
        let script : Process.StreamScript :=
          { command := sleeper, steps := #[.write .out (JobContract.counted 1000), .awaitClosed] }
        let expected := (List.range 1000).toArray.map fun n => s!"{n}".toUTF8
        let job : JobM Bool := do
          let child ← JobContract.started sleeper (JobContract.lines 1000000 true)
          let delivery ← JobContract.delivered child
          return JobContract.linesOf #[delivery] .out == expected && delivery.ended.isNone
        let (onModel, _) := job.runModel { processes := { streams := #[script] } }
        let (rig, processes) ← Rig.withProcesses { streams := #[script] }
        let onFake ← runOnFake job (some rig)
        let reads :=
          (← processes.started).filterMap fun (id, request) =>
            match request with
            | .read _ => some id
            | _ => none
        return onModel == .finished true && onFake == .finished true && reads.size == 1 &&
            ((← processes.taken).filter reads.contains).size == 1 },
    { name :=
        "the process model holds a child at the bound in the middle of its write, with exactly the bound undelivered, and a read lets it go on"
      run := do
        let script : Process.StreamScript :=
          { command := sleeper, steps := #[.write .out (ByteArray.mk (Array.replicate 25 120))] }
        let model : ProcessModel := { streams := #[script] }
        let streaming : Process.Streaming := { stdout := .bytes, stderr := .bytes, bound := 10 }
        let heldAt (model : ProcessModel) :=
          model.children[0]?.map fun child => (child.stdout.size, child.writing.map (·.2.2))
        let (_, started, _) := model.handle 0 none (.start sleeper streaming)
        let (_, afterRead, _) := started.handle 0 none (.read ⟨1⟩)
        let (_, afterSecond, _) := afterRead.handle 0 none (.read ⟨1⟩)
        return heldAt started == some (10, some 10) && heldAt afterRead == some (10, some 20) &&
            heldAt afterSecond == some (5, none) },
    -- Seen to bite once by hand, on 2026-11-15: over the model as it was,
    -- which judged a partial line that fills the bound too long whatever
    -- the child did next, the first read ends the child and the check fails.
    { name :=
        "the process model ends a child as lineTooLong only when it has more of the line to write: a partial line exactly the bound long, the child waiting on its input, is not too long, and is delivered whole once the input ends"
      run := do
        let script : Process.StreamScript :=
          { command := sleeper, steps := #[.write .out "abcd".toUTF8, .awaitClosed] }
        let model : ProcessModel := { streams := #[script] }
        let (_, started, _) := model.handle 0 none (.start sleeper (JobContract.lines 4 true))
        let (waiting, afterWaiting, _) := started.handle 0 none (.read ⟨1⟩)
        let (_, closed, _) := afterWaiting.handle 0 none (.closeInput ⟨1⟩)
        let (last, afterLast, _) := closed.handle 0 none (.read ⟨1⟩)
        let notTooLong :=
          match waiting with
          | .ok delivery => delivery.ended.isNone
          | .error _ => true
        let whole :=
          match last with
          | .ok delivery =>
            delivery.stdout == .lines #["abcd".toUTF8] && delivery.ended == some (.exited (.code 0))
          | .error _ => false
        return notTooLong && afterWaiting.killed.isEmpty && whole && afterLast.killed.isEmpty &&
            afterLast.children.isEmpty },
    { name :=
        "on the job model a child that pauses holds its second line: the first read gives the first line at once, with no end, and the next moves the clock to the pause's end and gives the second with the end"
      run := do
        let script := JobContract.pausingStream processRoot
        let job : JobM (Process.Delivery × Nat × Array Process.Delivery × Nat) := do
          let child ← JobContract.started script.command (JobContract.lines 64)
          let first ← JobContract.delivered child
          let between ← now
          let rest ← JobContract.toTheEnd child
          return (first, between, rest, ← now)
        match job.runModel { processes := { streams := #[script] } } with
        | (.finished (first, between, rest, after), _) =>
          return first.stdout == .lines #["one".toUTF8] && first.ended.isNone && between == 0 &&
              JobContract.linesOf rest .out == #["two".toUTF8] &&
              JobContract.endOf rest == some (.exited (.code 0)) &&
              after == 500
        | _ =>
          return false },
    { name :=
        "on the job model a job cancelled while its child pauses is cancelled at that instant, and its child is recorded as killed"
      run := do
        let script := JobContract.pausingStream processRoot
        let job : JobM Unit := do
          let child ← JobContract.started script.command (JobContract.lines 64)
          discard <| JobContract.delivered child
          discard <| JobContract.delivered child
        let (outcome, after) :=
          job.runModel { processes := { streams := #[script] }, cancelAt := some 200 }
        return outcome == .cancelled && after.now == 200 &&
            after.processes.killed == #[script.command] },
    -- Seen to bite once by hand, on 2026-11-15: with the filter of
    -- `Handle.children` after a last delivery taken out of `answer`, the
    -- later read, write and close reach the fake, and the check fails.
    { name :=
        "after a child's last delivery the runner forgets it: a later read, write or close is noSuchProcess, answered without a request to the process service"
      run := do
        let script : Process.StreamScript :=
          { command := sleeper, steps := #[.write .out "a\n".toUTF8] }
        let (rig, processes) ← Rig.withProcesses { streams := #[script] }
        let noSuchProcess {α : Type} : Except ProcessError α → Bool
          | .error .noSuchProcess => true
          | _ => false
        let spawned ←
          rig.spawn
              (reporting fun _ => do
                let child ← JobContract.started sleeper (JobContract.lines 64)
                let all ← JobContract.toTheEnd child
                let read ← Process.read child
                let write ← Process.write child "late".toUTF8
                let close ← Process.closeInput child
                return JobContract.linesOf all .out == JobContract.linesFrom ["a"] &&
                    JobContract.endOf all == some (.exited (.code 0)) &&
                    noSuchProcess read &&
                    noSuchProcess write &&
                    noSuchProcess close)
        let finished ← spawned.endedAs (.finished #["true"])
        let kinds :=
          (← processes.started).map fun (_, request) =>
            match request with
            | .start _ _ => "start"
            | .read _ => "read"
            | .write _ _ => "write"
            | .closeInput _ => "closeInput"
            | .run _ _ => "run"
            | .runWithin .. => "runWithin"
            | .runInput .. => "runInput"
        return finished && kinds == #["start", "read"] && (← processes.withdrawn).isEmpty },
    -- Seen to bite once by hand, on 2026-11-15: with `Handle.endChildren`
    -- taken out of `Handle.conclude`, this check and the next fail.
    { name :=
        "a job that ends with a streaming child running, finished, failed or cancelled, cancels the child: the fake withdraws its id, and the model, the fake's and the job model's, records it killed"
      run := do
        let script : Process.StreamScript := { command := sleeper, steps := #[.awaitClosed] }
        let starts : JobM Unit := discard <| JobContract.started sleeper (JobContract.lines 64 true)
        let jobs : List (JobM Bool × Bool) :=
          [((do
                starts;
                return true),
              false),
            ((do
                starts;
                throw "it fails"),
              false),
            ((do
                starts;
                sleep 1000;
                return true),
              true)]
        let results ←
          jobs.mapM fun (job, cancel) => do
              let (rig, processes) ← Rig.withProcesses { streams := #[script] }
              let spawned ← rig.spawn (reporting fun _ => job)
              if cancel then
                unless ← eventually (return (← rig.clock.waiting) == 1) do
                  return false
                spawned.handle.cancel
              unless ← eventually spawned.handle.ended do
                return false
              let child := ((← processes.started)[0]?.map (·.1)).getD 0
              let model ← processes.model
              return (← processes.withdrawn) == #[child] && model.killed == #[sleeper] &&
                  model.children.isEmpty
        let (_, model) :=
          (do
                starts;
                return true : JobM Bool).runModel
            { processes := { streams := #[script] } }
        return results.all id && model.processes.killed == #[sleeper] &&
            model.processes.children.isEmpty },
    { name := "cancelling a job in a pending read withdraws the read's wait and then its child"
      run := do
        let script : Process.StreamScript := { command := sleeper, steps := #[.awaitClosed] }
        let (rig, processes) ← Rig.withProcesses { streams := #[script] }
        let spawned ←
          rig.spawn
              (reporting fun _ => do
                let child ← JobContract.started sleeper (JobContract.lines 64 true)
                sleep 10
                discard <| Process.read child
                return true)
        unless ← eventually (return (← rig.clock.waiting) == 1) do
          return false
        processes.holdCompletions
        rig.clock.advance 10
        try
          unless ← eventually (return (← processes.waiting) == 1) do
            return false
          let started ← processes.started
          let child := (started[0]?.map (·.1)).getD 0
          let read := (started[1]?.map (·.1)).getD 0
          spawned.handle.cancel
          let cancelled ← spawned.endedAs .cancelled
          return cancelled && (← processes.withdrawn) == #[read, child] &&
              (← processes.model).killed == #[sleeper]
        finally
          processes.letGo }]

/-- What a job's model holds, as what a run of the job's command is handed:
each snapshot the job's loads made that was not released, under the job's
name for it. -/
def heldBy (model : FileModel) : Array (JobSnapshotId × TextContent) :=
  (Array.range model.held.size).filterMap fun index =>
    (model.held[index]?).join.map fun content => (⟨index⟩, content)

/-- Plays `case` on the text model and the job model, handing the snapshots
across as the runtime does, and says what went wrong; `none` when the case
held.

The values that cross are handed as values. The commands run against the
editor's models. The job's model starts with the text model's snapshots as
the published ones. The job's command runs with what the job's model held as
what arrived in its text model. The job is then settled, so the last command
runs against a text model that was handed nothing. Neither side writes what
the other owns. -/
def playOnModels (case : FileCases.Case) : Option String :=
  match case.first.runModel editorModel with
  | (.error refusal, _) => some s!"its first command failed with {repr refusal}"
  | (.ok start, model) =>
    let files := { fileModelOf case.files with snapshots := model.texts.snapshots }
    match (case.job fileRoot start).runModel { files } with
    | (.failed message, _) => some s!"its job failed with `{message}`"
    | (.cancelled, _) => some "its job was cancelled"
    | (.finished value, job) =>
      let handed := { model with texts := { model.texts with arrived := heldBy job.files } }
      match (case.handler start value).runModel handed with
      | (.error refusal, _) => some s!"the job's command failed with {repr refusal}"
      | (.ok (), model) =>
        match
          (case.last start).runModel
            { model with texts := { model.texts with arrived := #[] } } with
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
          sleeper.handle.cancel },
    { name :=
        "over shared environments, a job's record of a failure reaches the report once, a second job finds the first one's entry, and no environment request registers a wait"
      run := do
        let rig ← Rig.new
        let state ← IO.mkRef ({} : Process.Environments)
        let said ← IO.mkRef #[]
        let rig :=
          { rig with
            services :=
              { rig.services with
                environments :=
                  Job.sharedEnvironments state fun text => said.modify (·.push text) } }
        let failure := Process.Failure.exited 1 "untrusted"
        let entry : Process.Entry := { stamps := #[none], found := .failed failure }
        let first ←
          rig.spawn
              (reporting fun _ => do
                Process.askEnvironment (.record "/p/d" entry)
                Process.askEnvironment (.record "/p/d" entry)
                return true)
        let firstEnded ← first.endedAs (.finished #["true"])
        let second ←
          rig.spawn
              (reporting fun _ => do
                let found : Option Process.Entry ← Process.askEnvironment (.cached "/p/d")
                return found == some entry)
        let secondEnded ← second.endedAs (.finished #["true"])
        return firstEnded && secondEnded &&
            (← said.get) == #[Process.failureMessage "/p/d" failure] &&
            (← rig.services.completions.waiting) == 0 &&
            (← rig.clock.started).isEmpty },
    { name :=
        "a runner given no environments answers the policy as inherited: auto in the headless mode"
      run := do
        let rig ← Rig.new
        let job ←
          rig.spawn
              (reporting fun _ => do
                let policy : Process.Policy ← Process.askEnvironment .policy
                return policy ==
                    { setting := .auto, host := .headless, resolved := none, limit := 5000 })
        job.endedAs (.finished #["true"]) },
    { name :=
        "a job cancelled in a wait after one post makes no second post: its host is handed the first alone, and it ends cancelled"
      run := do
        let rig ← Rig.new
        let posts ← IO.mkRef #[]
        let work :=
          Work.of
            (fun _ => do
              post (JobContract.posting "first")
              sleep 1000
              post (JobContract.posting "second"))
            fun _ => pure ()
        let handle ←
          Job.spawn rig.services work (pure ()) fun invocation => posts.modify (·.push invocation)
        unless ← eventually (return (← rig.clock.waiting) == 1) do
          return false
        let before ← posts.get
        handle.cancel
        let ended ← eventually handle.ended
        rig.clock.advance 1000
        return before == #[JobContract.posting "first"] && ended &&
            (← posts.get) == #[JobContract.posting "first"] &&
            (← handle.outcome?).map texts == some .cancelled }]

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

end ModelTest
