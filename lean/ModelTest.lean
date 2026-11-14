import Editor.Command.Append
import Editor.Command.Model
import Editor.Config.Reload
import Editor.Display.Contract
import Editor.Display.Model
import Editor.File.Cases
import Editor.File.Model
import Editor.InputScheme.Contract
import Editor.InputScheme.Test
import Editor.InputScheme.Vim.Default
import Editor.Job.Contract
import Editor.Job.Fake
import Editor.Job.Jobs
import Editor.Job.Model
import Editor.Job.Pool
import Editor.Key.Notation
import Editor.Loop
import Editor.Scene
import Editor.State
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

The display interface's contract (`Editor/Display/Contract.lean`) is run
against its model here, in cells of two sizes (`displayFailures`). The real
binding's run of it is the display pipeline's. `sceneChecks` and
`displayChecks` are what only the model shows: the scenes published to it,
and its exact layout rule.

A command is tested the same way: as a property, a command that returns
whether it held, run against the model (`commandProperties`). The `editor`
executable runs the same command source against the real binding.

A command is a program over the editor's composite port
(`Editor/Command.lean`), run here against the text model and the display
model side by side (`EditorModel`). `commandPortChecks` pin what that runner
does with each sub-port's requests: a text program lifted into a command
does what it does alone, the display answers from the text model's
snapshots, and a display refusal is the text port's of the same name.

The editor state (`Editor/State.lean`) is checked on the text model
(`stateChecks`): the initial state, that a split tree's views tile the
frame, and the two layout operations, each refused with the state as it
was when it would break an invariant. The invariants themselves are checked
to refuse: states built in code that each break one (`spoilings`) are not
well formed, so `EditorState.wellFormed` is seen to answer false for every
one of its clauses.

The command loop (`Editor/Loop.lean`) is checked on the editor's models
(`loopChecks`): events fed to `Loop.step` one by one, the state each leaves
and the scenes the display model records. Among them is what the loop does
when publishing is refused, with a text or a snapshot released behind it:
the scene is published all the same, with the refusal in its echo.

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

How a key becomes an invocation is pure Lean with no port, so its checks
need no model and no fake of a collaborator:

- `keymapChecks`: a keymap (`Editor/Keymap.lean`), on keys built in code:
  what a sequence is bound to, which sequences a binding begins with, the
  chord a binding names a key by, and the walk through a list of keymaps
  in precedence order;
- `keyNotationChecks`: key strings (`Editor/Key/Notation.lean`): the keys
  a string names, the strings that are refused, and that the notation of a
  chord names it back;
- `invocationChecks`: an invocation (`Editor/Invocation.lean`): two are
  compared by their command names and their arguments;
- `schemeChecks`: the scheme interface (`Editor/InputScheme.lean`) on the
  test scheme (`Editor/InputScheme/Test.lean`), with keymaps written as key
  strings: what the keys of a bound sequence yield, that an unbound key
  resets the scheme, which of two keymaps wins, the pending keys it
  reports, and its self-insert;
- `schemeContractChecks`: the scheme contract
  (`Editor/InputScheme/Contract.lean`) holds of the test scheme, and
  reports schemes written here that each break one property of it, `eager`
  among them, which emits on a strict prefix.

The Vim scheme (`Editor/InputScheme/Vim.lean`) is checked the same way,
with no model:

- `vimEditChecks`: what an edit compiles to, the layout of each kind of
  invocation, and what an edit says of itself;
- `vimRegistryChecks`: the registry of Vim states: looking a state up by
  its name, and registering one. A record holds keymaps and so has no
  equality: the checks compare records by their fields (`vimSeen`);
- `vimGrammarChecks`: the grammar: which keymaps a key is looked up in,
  and what a key sequence parses to and yields;
- `vimStateChecks`: Vim states: which state a view is in, how one is
  entered, what the grammar reads of a state's record (typed text, an
  operator over the selection), and the last change;
- `vimDefaultChecks`: the default states and bindings
  (`Editor/InputScheme/Vim/Default.lean`), observed through the grammar:
  what each default key parses to. They restate no table and name no
  vocabulary or command name;
- `vimContractChecks`: the scheme contract holds of the Vim scheme, over
  the registry written here and over the default states.

The grammar's checks run on a registry and keymaps written here
(`vimStates`), so that none of them names a default binding.
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

/-- The keys the key string `text` names, for a fixture; none when it is
refused, which `schemeChecks` checks of no fixture string. -/
def keys (text : String) : List Key :=
  match Key.parse text with
  | .ok named => named
  | .error _ => []

/-- The invocation of the command `name` with no arguments. -/
def invoke (name : String) : Invocation :=
  { command := name }

/-- The texts a registered command leaves when it is a plain command, run
against a text model with none; `none` for a command over a store and for
one that is given its call. -/
def plainTexts : Config.Action → Option (Array String)
  | .plain run => some (textsOf run)
  | .store .. => none
  | .call _ => none

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
        match (step (.nat 2)).runModel editorModel with
        | (.ok tree, model) => pure (tree == .nat 7 && model.texts.contents == #["was 2"])
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
          (refusal twice == some "the job `count` is registered twice" && refusal shared == none) },
    { name :=
        "a setup that binds key strings to command names collects each as its chords and the name, in order, and registers no command"
      run :=
        let setup : SetupM Unit := do
          bindKey "C-x C-s" "save"
          bindKey "<Escape>" "quit"
          bindKey "A" "save"
        match Config.Registrations.ofSetup setup with
        | .error _ => pure false
        | .ok collected =>
          pure
            (collected.bindings.map (fun binding => (binding.keys, binding.command)) ==
                #[(keys "C-x C-s", "save"), (keys "<Escape>", "quit"), (keys "A", "save")] &&
              collected.commands.isEmpty) },
    { name :=
        "a setup that binds a key string that is not keys is refused with the key parser's message, which names the stroke, and one that names no keys with a message that names the command"
      run :=
        let unreadable : SetupM Unit := do
          command "save" (makes "1")
          bindKey "C-x nope" "save"
        let parsed : Option String :=
          match Key.parse "C-x nope" with
          | .error message => some message
          | .ok _ => none
        pure
          (parsed.isSome && refusal unreadable == parsed &&
            refusal (bindKey "" "save") == some "the command `save` is bound to no keys" &&
            refusal (bindKey "  " "save") == some "the command `save` is bound to no keys") },
    { name :=
        "a setup that binds one key sequence twice is refused with a message that names the keys, whether to one command or to two; two sequences to one command are not"
      run :=
        let twice : SetupM Unit := do
          bindKey "C-x C-s" "save"
          bindKey "C-q" "quit"
          bindKey "C-x C-s" "save-as"
        let same : SetupM Unit := do
          bindKey "C-q" "quit"
          bindKey "C-q" "quit"
        let apart : SetupM Unit := do
          bindKey "C-x C-s" "save"
          bindKey "C-x s" "save"
        pure
          (refusal twice == some "the keys `C-x C-s` are bound twice" &&
            refusal same == some "the keys `C-q` are bound twice" &&
            refusal apart == none) }]

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

/-- The binding of the keys the key string `text` names to the command
`command`. -/
def binding (text command : String) : Config.KeyBinding :=
  { keys := keys text, command }

/-- What the keys the key string `text` names are bound to in the keymap
`registry` makes for the test scheme, whose binding is an invocation. -/
def boundTo (registry : Config.Registry) (text : String) : Option Invocation :=
  (registry.keymap TestScheme.scheme).find? (keys text)

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
            (replaced.find? "count").isNone) },
    { name :=
        "compiled code is an owner of its own: config's entry of a name a compiled entry has is the one a lookup finds, and once config no longer registers it the compiled one is found again"
      run :=
        let compiled : Config.Registry :=
          ({} : Config.Registry).replace .compiled
            #[registration "stamp" "compiled", registration "only" "compiled"]
        let overridden := compiled.replace .config #[registration "stamp" "config"]
        let dropped := overridden.replace .config #[]
        pure
          (Config.Owner.compiled != Config.Owner.config &&
            registeredTexts compiled "stamp" == some #["compiled"] &&
            registeredTexts overridden "stamp" == some #["config"] &&
            registeredTexts overridden "only" == some #["compiled"] &&
            overridden.names == #["stamp", "only"] &&
            registeredTexts dropped "stamp" == some #["compiled"] &&
            dropped.entries.all (·.owner == .compiled)) },
    { name :=
        "replacing an owner's bindings removes its old ones and leaves another owner's, and touches no command"
      run :=
        let registry : Config.Registry :=
          ((({} : Config.Registry).replace .config #[registration "greet" "1"]).replaceBindings
                .compiled #[binding "C-c a" "theirs"]).replaceBindings
            .config #[binding "C-c b" "one", binding "C-c c" "old"]
        let replaced := registry.replaceBindings .config #[binding "C-c b" "two"]
        pure
          (boundTo registry "C-c a" == some (invoke "theirs") &&
            boundTo registry "C-c b" == some (invoke "one") &&
            boundTo registry "C-c c" == some (invoke "old") &&
            boundTo replaced "C-c a" == some (invoke "theirs") &&
            boundTo replaced "C-c b" == some (invoke "two") &&
            boundTo replaced "C-c c" == none &&
            replaced.bindings.size == 2 &&
            replaced.names == #["greet"]) },
    { name :=
        "of two owners' bindings of one key sequence, the registry's keymap gives the later owner's, and the earlier's again once the later owner binds nothing"
      run :=
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceBindings .compiled
                #[binding "C-c t" "compiled", binding "C-c u" "kept"]).replaceBindings
            .config #[binding "C-c t" "config"]
        pure
          (boundTo registry "C-c t" == some (invoke "config") &&
            boundTo registry "C-c u" == some (invoke "kept") &&
            boundTo (registry.replaceBindings .config #[]) "C-c t" == some (invoke "compiled") &&
            (registry.keymap TestScheme.scheme).continues (keys "C-c")) }]

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

/-- Runs the command called `name` the way the editor does, against the
editor's models `model`: the state once what the command wrote is written
back, and the models after it. `none` if there is no such command or it was
refused. -/
def runs (state : Config.State Elaborated) (name : String) (model : EditorModel := editorModel) :
    Option (Config.State Elaborated × EditorModel) :=
  (state.program? name).bind fun program =>
    match program.runModel model with
    | (.ok write, model) => some (state.written write, model)
    | (.error _, _) => none

/-- The texts the command called `name` leaves when the editor runs it. -/
def runTexts (state : Config.State Elaborated) (name : String) : Option (Array String) :=
  (runs state name).map (·.2.texts.contents)

/-- The value of the config's store called `name`. -/
def stored (state : Config.State Elaborated) (name : String) : Option Value :=
  (state.cells.find? .config name).map (·.value)

/-- An argument as a check's command writes it. -/
def argumentText : Argument → String
  | .nat value => toString value
  | .int value => toString value
  | .str value => value
  | .bool value => toString value

/-- What a command that is given its call was called with, as one line: its
label, its arguments, and its keys as a key string. -/
def callText (label : String) (call : Call) : String :=
  " ".intercalate (label :: call.arguments.map argumentText ++ [Key.notations call.keys])

/-- A registration of the command `name` that is given its call, and makes a
text of `label` and what it was called with (`callText`). -/
def callRegistration (name label : String) : Config.Registration :=
  { name, action := .call fun call => makes (callText label call) }

/-- Runs the command called `name` the way an invocation does
(`Config.State.command?`), against the editor's models, with a call for the
focused window of a new editor state, `arguments` and the keys `typed`: what
the command asks to write, and the texts after it, the scratch buffer's
first. `none` if there is no such command or it was refused. -/
def calls (state : Config.State Elaborated) (name : String) (arguments : List Argument := [])
    (typed : List Key := []) : Option (Option Config.Write × Array String) :=
  (state.command? name).bind fun run =>
    let program : EditorM (Option Config.Write) := do
      let editor ← EditorState.initial ⟨640, 480⟩
      let some target := editor.focusedTarget? | throw .noSuchText
      run { target, arguments, keys := typed }
    match program.runModel editorModel with
    | (.ok write, model) => some (write, model.texts.contents)
    | (.error _, _) => none

/-- A config state in which compiled code has registered `registrations`,
before any config. -/
def compiledWith (registrations : Array Config.Registration) : Config.State Elaborated :=
  { registry := ({} : Config.Registry).replace .compiled registrations }

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
            startable loaded "missing" == none) },
    { name :=
        "config registers a command under a compiled command's name: an invocation of the name runs config's, the report counts config's commands alone, and after a reload without the registration the invocation runs the compiled one"
      run :=
        let compiled := compiledWith #[registration "stamp" "compiled"]
        let (overridden, effects) :=
          reduceFrom compiled
            [.requested, .finished (accepted ["a"] (command "stamp" (makes "config")))]
        let (dropped, later) :=
          reduceFrom overridden [.requested, .finished (accepted ["a"] (greets "hello"))]
        pure
          ((calls compiled "stamp").map (·.2) == some #["", "compiled"] &&
            (calls overridden "stamp").map (·.2) == some #["", "config"] &&
            effects == #[.start none #[], .cancelJobs "config", .report 1 true #[] 1 1] &&
            (calls dropped "stamp").map (·.2) == some #["", "compiled"] &&
            later == #[.start (some #[]) #["a"], .cancelJobs "config", .report 2 true #[] 1 1] &&
            (calls dropped "missing").isNone) },
    { name :=
        "a command that is given its call is handed the call an invocation runs it with: its arguments and its keys"
      run :=
        let state := compiledWith #[callRegistration "stamp" "stamp"]
        pure
          ((calls state "stamp" [.nat 3, .str "w"] (keys "C-x i")).map (·.2) ==
              some #["", "stamp 3 w C-x i"] &&
            ((calls state "stamp").bind (·.1)).isNone) },
    { name :=
        "a command over a store, run as an invocation runs it, hands back what to write: the owner, the store and the new tree, which the state then holds"
      run :=
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] (bumps 4))]
        pure <|
          match calls loaded "bump" with
          | some (some write, _) =>
            write.owner == .config && write.store == "counter" && write.value == .nat 4 &&
              stored (loaded.written (some write)) "counter" == some (.nat 4)
          | _ => false },
    { name :=
        "the driver's run of a command that is given its call runs it with the target it is handed and nothing else, and runs nothing when it is handed none"
      run :=
        let state := compiledWith #[callRegistration "stamp" "stamp", registration "plain" "p"]
        let program : EditorM (Option Bool) := do
          let editor ← EditorState.initial ⟨640, 480⟩
          let some target := editor.focusedTarget? | throw .noSuchText
          let some run := state.program? "stamp" (some target) | return none
          return some (← run).isNone
        pure
          ((state.program? "stamp").isNone &&
            (match program.runModel editorModel with
            | (.ok (some true), model) => model.texts.contents == #["", "stamp "]
            | _ => false) &&
            runTexts state "plain" == some #["p"]) },
    { name :=
        "an accepted outcome replaces the config's key bindings and leaves compiled ones: a key the new config binds to another command is bound to that one alone, and one it no longer binds is unbound; a rejected outcome keeps them"
      run :=
        let compiled : Config.State Elaborated :=
          { registry := ({} : Config.Registry).replaceBindings .compiled #[binding "C-c k" "kept"] }
        let first : SetupM Unit := do
          bindKey "C-c t" "one"
          bindKey "C-c o" "old"
        let (loaded, _) := reduceFrom compiled [.requested, .finished (accepted ["a"] first)]
        let (reloaded, effects) :=
          reduceFrom loaded [.requested, .finished (accepted ["a"] (bindKey "C-c t" "two"))]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        pure
          (boundTo loaded.registry "C-c t" == some (invoke "one") &&
            boundTo loaded.registry "C-c o" == some (invoke "old") &&
            boundTo reloaded.registry "C-c t" == some (invoke "two") &&
            boundTo reloaded.registry "C-c o" == none &&
            boundTo reloaded.registry "C-c k" == some (invoke "kept") &&
            reloaded.registry.bindings.size == 2 &&
            effects == #[.start (some #[]) #["a"], .cancelJobs "config", .report 2 true #[] 1 0] &&
            boundTo kept.registry "C-c t" == some (invoke "one") &&
            boundTo kept.registry "C-c o" == some (invoke "old")) }]

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

/-- Lines of 6, 2, 10 and 3 characters. Four characters wide, the first takes
two rows and the third three: rows 0 to 6 start at 0, 4, 7, 10, 14, 18 and
21. -/
def wrapping : String :=
  "abcdef\nab\nabcdefghij\nxyz"

/-- Where the display model over `texts` moves `position` of the first of
them, in a view `width` pixels wide, by `lines` rows aiming for `goal`. -/
def movedBy (texts : List String) (width position : Nat) (lines : Int) (goal : Option Nat)
    (cells : Display.Cells := { advance := 1, lineHeight := 1 }) : DisplayError ⊕ Display.Moved :=
  answered
    ((Display.linesFrom { snapshot := ⟨0⟩, width, position, lines, goal }).runModel
        (displayOver texts cells)).1

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
        "across a shorter line the position stops at its end, and the goal passed back brings it to the start's column again"
      run :=
        pure
          (movedBy [wrapping] 4 3 2 none == .inr ⟨9, 3⟩ &&
            movedBy [wrapping] 4 9 (-2) (some 3) == .inr ⟨3, 3⟩ &&
            movedBy [wrapping] 4 9 (-2) none == .inr ⟨2, 2⟩) },
    { name :=
        "a row a line wraps after holds no end-of-line position: aiming past it lands on its last character"
      run := pure (movedBy [wrapping] 4 9 1 (some 6) == .inr ⟨13, 6⟩) },
    { name := "the goal is in pixels: a column times the cells' advance"
      run :=
        pure
          (movedBy [wrapping] 32 3 2 none (cells := { advance := 8, lineHeight := 16 }) ==
            .inr ⟨9, 24⟩) }]

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

/-- A command's result, or the refusal it failed with on the left, as a
value with equality. -/
def resulted {α : Type} : Except TextError α → TextError ⊕ α
  | .ok value => .inr value
  | .error refusal => .inl refusal

/-- The checks of the editor's composite port (`Editor/Command.lean`): what
its model runner does with each sub-port's requests. -/
def commandPortChecks : List Check :=
  [{  name :=
        "a program over the text port, lifted to a command, gives the same result and the same texts on the editor's models as on the text model"
      run := do
        let program : TextM String := do
          let text ← createText "héllo"
          text.insert 6 " wörld"
          discard <| createText "other"
          text.read
        let (onText, texts) := program.runModel {}
        let (onEditor, model) := (TextM.lift program).runModel editorModel
        return resulted onText == resulted onEditor && texts.contents == model.texts.contents &&
            model.display.scenes == #[] },
    { name :=
        "inside a command, the rows a view shows of a snapshot just taken are answered from the text model's text"
      run := do
        let command : EditorM (Array Display.Row) := do
          let text ← createText "ab\ncdef"
          let snapshot ← text.snapshot
          text.insert 0 "xyz"
          Display.rowsShown { snapshot, width := 3, height := 10, anchor := 0 }
        return resulted (command.runModel editorModel).1 == .inr #[⟨0, 2⟩, ⟨3, 6⟩, ⟨6, 7⟩] },
    { name :=
        "a display refusal inside a command is the text port's refusal of the same name, and a text refusal is itself"
      run := do
        let unknown : EditorM (Array Display.Row) :=
          Display.rowsShown { snapshot := ⟨9⟩, width := 3, height := 10, anchor := 0 }
        let inside : EditorM (Array Display.Row) := do
          let snapshot ← (← createText "é").snapshot
          Display.rowsShown { snapshot, width := 3, height := 10, anchor := 1 }
        let moved : EditorM Display.Moved := do
          let snapshot ← (← createText "é").snapshot
          Display.linesFrom { snapshot, width := 3, position := 1, lines := 1, goal := none }
        let text : EditorM Unit := (⟨4⟩ : TextId).insert 0 "x"
        return resulted (unknown.runModel editorModel).1 == .inl .noSuchSnapshot &&
            resulted (inside.runModel editorModel).1 == .inl .badPosition &&
            resulted (moved.runModel editorModel).1 == .inl .badPosition &&
            resulted (text.runModel editorModel).1 == .inl .noSuchText },
    { name := "a scene published inside a command is recorded by the display model, in order"
      run := do
        let command : EditorM Unit := do
          Display.publish twoViews
          discard <| createText "between"
          Display.publish { twoViews with echo := "second" }
        let (result, model) := command.runModel editorModel
        return result matches .ok () &&
            model.display.scenes == #[twoViews, { twoViews with echo := "second" }] }]

/-- The checks of the user's origin (`Origin.user`) and of how a refusal is
described to the user (`TextError.describe`). -/
def originChecks : List Check :=
  [{  name :=
        "the user's origin is not the unattributed one, and a transaction applied with it is traced to an entry by the user"
      run := do
        let command : TextM (Array Attribution) := do
          let text ← createText "ab"
          discard <| text.apply (Transaction.replacing 2 1 1 "xyz") Origin.user
          text.trace 0 5
        return Origin.user != Origin.unattributed &&
            resulted (command.runModel {}).1 ==
              .inr
                #[{ start := 0, stop := 1, author := .earlier 0 },
                  { start := 1, stop := 4, author := .entry 1 Origin.user },
                  { start := 4, stop := 5, author := .earlier 0 }] },
    { name := "every refusal of the text port is described in a few words of its own"
      run :=
        pure
          ([TextError.noSuchText, .badRange, .noSuchSnapshot, .badPosition, .badChange,
                  .badSelection, .unknownRevision, .forgotten, .noSuchMarker, .noInverse,
                  .notInState].map
              TextError.describe ==
            ["no such text", "bad range", "no such snapshot", "bad position", "bad change",
              "bad selection", "unknown revision", "forgotten revision", "no such marker",
              "no inverse", "not in state"]) }]

/-- The rectangle of a frame of `size`, from its top left. -/
def frameRect (size : Size) : Rect :=
  { x := 0, y := 0, width := size.width, height := size.height }

/-- The area of `rect`. -/
def area (rect : Rect) : Nat :=
  rect.width * rect.height

/-- The area two rectangles share: none when they do not overlap. -/
def shared (first second : Rect) : Nat :=
  (min (first.x + first.width) (second.x + second.width) - max first.x second.x) *
    (min (first.y + first.height) (second.y + second.height) - max first.y second.y)

/-- Whether no two of `rects` share any area. -/
def disjoint : List Rect → Bool
  | [] => true
  | rect :: rest => rest.all (shared rect · == 0) && disjoint rest

/-- Whether `parts` tile `whole`: each is inside it, no two share any area,
and their areas sum to its area. -/
def tiles (whole : Rect) (parts : Array Rect) : Bool :=
  parts.all
      (fun part =>
        whole.x ≤ part.x && whole.y ≤ part.y && part.x + part.width ≤ whole.x + whole.width &&
          part.y + part.height ≤ whole.y + whole.height) &&
    disjoint parts.toList &&
    (parts.map area).foldl (· + ·) 0 == area whole

/-- Split trees of one to four windows, with the minibuffer's place and
without it. -/
def sampleTrees : List Split :=
  let window (index : Nat) : Split := .window ⟨index⟩
  [window 0, .split .rows (window 0) .minibuffer, .split .columns (window 0) (window 1),
    .split .rows (.split .columns (window 0) (window 1)) .minibuffer,
    .split .rows (window 0) (.split .columns (window 1) (window 2)),
    .split .columns (.split .rows (window 0) .minibuffer) (.split .rows (window 1) (window 2)),
    .split .rows (.split .columns (window 0) (window 1)) (.split .columns (window 2) (window 3)),
    .split .rows (.split .columns (window 0) (.split .rows (window 1) (window 2)))
      (.split .rows (window 3) .minibuffer)]

/-- Frame sizes for the tiling checks: even, odd, small and zero. -/
def sampleSizes : List Size :=
  [⟨640, 480⟩, ⟨641, 479⟩, ⟨7, 3⟩, ⟨1, 1⟩, ⟨0, 0⟩, ⟨0, 480⟩, ⟨640, 0⟩]

/-- The initial state at 640 by 480 with two more windows over its one
buffer, each with markers of its own:

```
+---------+---------+
| view 0  | view 1  |
+---------+---------+
|      view 2       |
+-------------------+
   (the minibuffer's place, with no space)
```

View 0 is focused. -/
def threeWindows : TextM EditorState := do
  let state ← EditorState.initial ⟨640, 480⟩
  let some buffer := state.buffers[0]? | throw .noSuchText
  let more ←
    #[1, 2].mapM fun index => do
        let scroll ← buffer.text.mark (.anchor { offset := 0, bias := .before })
        let selection ← buffer.text.mark (.selection { ranges := #[⟨0, 0⟩] })
        return ({ id := ⟨index⟩, buffer := ⟨0⟩, scroll, selection } : Window)
  return { state with
      windows := state.windows ++ more
      frame :=
        { state.frame with
          tree :=
            .split .rows (.split .columns (.window ⟨0⟩) (.window ⟨1⟩))
              (.split .rows (.window ⟨2⟩) .minibuffer) } }

/-- The initial state at 640 by 480 with a second buffer, `other`, over a
text of its own holding "other", and a second window, view 1, on it, beside
view 0. View 0 is focused. -/
def twoBuffers : TextM EditorState := do
  let state ← EditorState.initial ⟨640, 480⟩
  let text ← createText "other"
  let scroll ← text.mark (.anchor { offset := 0, bias := .before })
  let selection ← text.mark (.selection { ranges := #[⟨0, 0⟩] })
  let history ← UndoTree.over text
  return { state with
      buffers := state.buffers.push { name := "other", text, history }
      windows := state.windows.push { id := ⟨1⟩, buffer := ⟨1⟩, scroll, selection }
      frame :=
        { state.frame with
          tree := .split .rows (.split .columns (.window ⟨0⟩) (.window ⟨1⟩)) .minibuffer } }

/-- The value of a program over the text port run on a text model with no
text; `none` if it was refused. -/
def onTextModel {α : Type} (program : TextM α) : Option α :=
  match (program.runModel {}).1 with
  | .ok value => some value
  | .error _ => none

/-- The views of `state`'s frame and their rectangles, in drawing order. -/
def laidOut (state : EditorState) : Array (ViewId × Rect) :=
  state.frame.tree.rects (frameRect state.frame.size)

/-- Ways to spoil `threeWindows`, each breaking one layout invariant and
keeping every other clause of `EditorState.wellFormed`, with what the state
is then. So each is refused by one clause alone, and a `wellFormed` without
that clause would accept it. -/
def spoilings : List (String × (EditorState → EditorState)) :=
  let window (index : Nat) : Split := .window ⟨index⟩
  let top : Split := .split .columns (window 0) (window 1)
  let withTree (tree : Split) (state : EditorState) : EditorState :=
    { state with frame := { state.frame with tree } }
  let withWindow (id : ViewId) (change : Window → Window) (state : EditorState) : EditorState :=
    { state with windows := state.windows.map fun was => if was.id == id then change was else was }
  [("whose focused window is not in the tree", fun state =>
      { state with frame := { state.frame with focused := ⟨7⟩ } }),
    ("whose tree has no minibuffer leaf", withTree (.split .rows top (window 2))),
    ("whose tree has two minibuffer leaves",
      withTree (.split .rows (.split .rows top .minibuffer) (.split .rows (window 2) .minibuffer))),
    ("whose tree names one window twice, with as many leaves as there are windows",
      withTree (.split .rows top (.split .rows (window 1) .minibuffer))),
    ("whose tree names a window there is none of, with as many leaves as there are windows",
      withWindow ⟨2⟩ ({ · with id := ⟨7⟩ })),
    ("with a window that is not in the tree", withTree (.split .rows top .minibuffer)),
    ("with a window whose buffer does not exist", withWindow ⟨1⟩ ({ · with buffer := ⟨5⟩ }))]

/-- The checks of the editor state and its layout invariants
(`Editor/State.lean`), on the text model. -/
def stateChecks : List Check :=
  [{  name :=
        "the initial state is well formed: one scratch buffer, one window on it, the minibuffer's place, and the focus on view 0"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            state.wellFormed && state.buffers.map (·.name) == #["scratch"] &&
              state.windows.map (·.id) == #[⟨0⟩] &&
              state.frame.tree == .split .rows (.window ⟨0⟩) .minibuffer &&
              state.frame.focused == ⟨0⟩ &&
              state.frame.hasFocus &&
              state.echo == "" &&
              state.preedit == none },
    { name :=
        "a state that breaks one layout invariant is not well formed: a focus outside the tree, no minibuffer leaf or two, a window named twice, a tree window with no window, a window outside the tree, a window with no buffer"
      run := do
        let some state := onTextModel threeWindows | return false
        -- A failure names the spoiled states that were taken for well formed.
        let accepted := spoilings.filter fun (_, spoil) => (spoil state).wellFormed
        unless accepted.isEmpty do
          throw
              (IO.userError
                s!"well formed: a state {"; a state ".intercalate (accepted.map (·.1))}")
        return state.wellFormed },
    { name :=
        "the views of a split tree tile the frame: each inside it, no two overlapping, their areas summing to its, for one to four windows, with and without the minibuffer's place, at even, odd and zero sizes"
      run :=
        pure <|
          sampleTrees.all fun tree =>
            sampleSizes.all fun size =>
              let laid := tree.rects (frameRect size)
              tiles (frameRect size) (laid.map (·.2)) && laid.map (·.1) == tree.windows },
    { name := "removing the only window is refused with onlyWindow, and the state is as it was"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            match state.removeWindow ⟨0⟩ with
            | (.error .onlyWindow, after) => after == state
            | _ => false },
    { name :=
        "focusing a window that is not in the tree is refused with noSuchWindow, and the state is as it was; so is removing one"
      run :=
        pure <|
          match onTextModel threeWindows with
          | none => false
          | some state =>
            (match state.focusWindow ⟨7⟩ with
              | (.error (.noSuchWindow id), after) => id == ⟨7⟩ && after == state
              | _ => false) &&
              match state.removeWindow ⟨7⟩ with
              | (.error (.noSuchWindow id), after) => id == ⟨7⟩ && after == state
              | _ => false },
    { name :=
        "removing a window of three keeps the state well formed, gives its space to its sibling and hands back the window; the focus moves to the first window of what took its place, or of the tree"
      run :=
        pure <|
          match onTextModel threeWindows with
          | none => false
          | some state =>
            let top := { x := 0, y := 0, width := 640, height := 240 }
            let bottom := { x := 0, y := 240, width := 640, height := 240 }
            let (_, onTwo) := state.focusWindow ⟨2⟩
            state.wellFormed &&
              (match state.removeWindow ⟨0⟩ with
              | (.ok removed, after) =>
                removed.id == ⟨0⟩ && after.wellFormed && after.frame.focused == ⟨1⟩ &&
                  after.windows.map (·.id) == #[⟨1⟩, ⟨2⟩] &&
                  laidOut after == #[(⟨1⟩, top), (⟨2⟩, bottom)]
              | _ => false) &&
              (match state.removeWindow ⟨1⟩ with
              | (.ok _, after) =>
                after.wellFormed && after.frame.focused == ⟨0⟩ &&
                  laidOut after == #[(⟨0⟩, top), (⟨2⟩, bottom)]
              | _ => false) &&
              onTwo.frame.focused == ⟨2⟩ &&
              match onTwo.removeWindow ⟨2⟩ with
              | (.ok _, after) =>
                after.wellFormed && after.frame.focused == ⟨0⟩ &&
                  laidOut after ==
                    #[(⟨0⟩, { x := 0, y := 0, width := 320, height := 480 }),
                      (⟨1⟩, { x := 320, y := 0, width := 320, height := 480 })]
              | _ => false },
    { name := "focusing a window in the tree sets the frame's focus and changes nothing else"
      run :=
        pure <|
          match onTextModel threeWindows with
          | none => false
          | some state =>
            match state.focusWindow ⟨1⟩ with
            | (.ok (), after) =>
              after.frame.focused == ⟨1⟩ &&
                after == { state with frame := { state.frame with focused := ⟨1⟩ } }
            | _ => false }]

/-- Starts a loop from the state `start` makes, feeds it `events` in order,
and returns the loop and what each step said to do next. -/
def stepsFrom (start : TextM EditorState) (events : List Event) :
    EditorM (Loop × Array Loop.Next) := do
  let mut loop : Loop := { state := ← start }
  let mut nexts := #[]
  for event in events do
    let (next, said) ← loop.step event
    loop := next
    nexts := nexts.push said
  return (loop, nexts)

/-- What a run of the loop on the editor's models came to: the loop and what
each step said, the scenes the display recorded, and the models. `none` when
it was refused. -/
def looped (start : TextM EditorState) (events : List Event) :
    Option ((Loop × Array Loop.Next) × Array Scene × EditorModel) :=
  match (stepsFrom start events).runModel editorModel with
  | (.ok result, model) => some (result, model.display.scenes, model)
  | (.error _, _) => none

/-- A key press with no text: what the loop drops in this phase. -/
def pressA : Event :=
  .key { logical := .character "a", physical := .code "KeyA" } true "a"

/-- The text of the snapshot a view shows, as the text model holds it. -/
def shownText (model : EditorModel) (view : View) : Option String :=
  (model.texts.snapshots[view.snapshot.index]?).join.map (·.contents)

/-- The checks of the loop (`Editor/Loop.lean`) on the editor's models: what
each event does to the state, and the scene it publishes. -/
def loopChecks : List Check :=
  [{  name :=
        "a resize to 641 by 479 of a frame of three windows publishes a scene whose views' rectangles tile 641 by 479"
      run :=
        pure <|
          match looped threeWindows [.resize { width := 641, height := 479, scale := 2.0 }] with
          | some ((loop, nexts), scenes, _) =>
            nexts == #[.continue] && loop.state.frame.size == ⟨641, 479⟩ &&
              match scenes with
              | #[scene] =>
                scene.size == ⟨641, 479⟩ && scene.views.map (·.id) == #[⟨0⟩, ⟨1⟩, ⟨2⟩] &&
                  tiles (frameRect ⟨641, 479⟩) (scene.views.map (·.rect))
              | _ => false
          | none => false },
    { name :=
        "a preedit publishes a scene that carries it for the focused view, and leaves the buffer's text and revision as they were"
      run :=
        pure <|
          let start : TextM EditorState := do
            let state ← threeWindows
            let some buffer := state.buffers[0]? | throw .noSuchText
            buffer.text.insert 0 "hello"
            return (state.focusWindow ⟨1⟩).2
          match looped start [.preedit "ka"] with
          | some ((loop, _), scenes, model) =>
            loop.state.preedit == some "ka" &&
              (match scenes with
              | #[scene] =>
                scene.preedit == some "ka" && scene.focused == some ⟨1⟩ &&
                  scene.views.all fun view => shownText model view == some "hello"
              | _ => false) &&
              match loop.state.buffers[0]? with
              | some buffer =>
                model.texts.contents == #["hello"] &&
                  (model.texts.texts[buffer.text.index]?).join.map (·.revision) == some 1
              | none => false
          | none => false },
    { name :=
        "an empty preedit and the input method going away each clear the preedit; enabling it changes nothing"
      run :=
        pure <|
          match
            looped (EditorState.initial ⟨640, 480⟩)
              [.preedit "k", .preedit "", .preedit "ka", .compositionDisabled, .preedit "s",
                .compositionEnabled] with
          | some (_, scenes, _) =>
            scenes.map (·.preedit) == #[some "k", none, some "ka", none, some "s", some "s"]
          | none => false },
    { name :=
        "while the frame does not have the keyboard focus its scene names no focused view, and once it has it again the focused one"
      run :=
        pure <|
          match looped threeWindows [.focus false, .focus true] with
          | some (_, scenes, _) => scenes.map (·.focused) == #[none, some ⟨0⟩]
          | none => false },
    { name :=
        "a key, a pointer and the window opening leave the state as it was, and each publishes one scene"
      run :=
        pure <|
          let events : List Event :=
            [pressA, .pointer { action := .press, x := 3.0, y := 4.0, button := some .primary },
              .windowOpened "headless"]
          let start : EditorM (EditorState × Loop × Array Loop.Next) := do
            let state ← EditorState.initial ⟨640, 480⟩
            let (loop, nexts) ← stepsFrom (pure state) events
            return (state, loop, nexts)
          match (start.runModel editorModel) with
          | (.ok (state, loop, nexts), model) =>
            loop.state == state && nexts == #[.continue, .continue, .continue] &&
              model.display.scenes.size == 3
          | (.error _, _) => false },
    { name := "a close request and a quit say stop and publish nothing"
      run :=
        pure <|
          (match looped threeWindows [.closeRequested] with
            | some ((_, nexts), scenes, _) => nexts == #[.stop] && scenes.isEmpty
            | none => false) &&
            match looped threeWindows [.quit] with
            | some ((_, nexts), scenes, _) => nexts == #[.stop] && scenes.isEmpty
            | none => false },
    { name :=
        "a view whose text has not changed keeps its snapshot from one scene to the next, and two views of one buffer share it"
      run :=
        pure <|
          match looped threeWindows [pressA, pressA] with
          | some (_, #[first, second], model) =>
            first.views.map (·.snapshot) == second.views.map (·.snapshot) &&
              (first.views.map (·.snapshot)).toList.eraseDups.length == 1 &&
              second.views.all fun view => shownText model view == some ""
          | _ => false },
    { name :=
        "a view shows its window's scroll anchor and selection marker, a bar cursor in the face cursor, and no decorations or status"
      run :=
        pure <|
          match looped threeWindows [pressA] with
          | some ((loop, _), #[scene], _) =>
            scene.views.map (·.scroll) == loop.state.windows.map (·.scroll) &&
              scene.views.map (·.selections) == loop.state.windows.map (#[·.selection]) &&
              scene.views.all fun view =>
                view.cursor == { shape := .bar, face := ⟨"cursor"⟩ } && view.decorations.isEmpty &&
                  view.status.isEmpty
          | _ => false },
    { name :=
        "a commit once the focused buffer's text was released is not refused: it publishes a scene with the refusal in its echo and no view of that buffer, and the loop keeps the state as it was, well formed, with that echo"
      run :=
        pure <|
          let program : EditorM (EditorState × Loop × Loop.Next) := do
            let state ← EditorState.initial ⟨640, 480⟩
            let some target := state.focusedTarget? | throw .noSuchMarker
            target.buffer.text.release
            let (loop, next) ← ({ state } : Loop).step (.commit "x")
            return (state, loop, next)
          match program.runModel editorModel with
          | (.ok (state, loop, next), model) =>
            next == .continue && loop.state == { state with echo := "refused: no such text" } &&
              loop.state.wellFormed &&
              loop.shown.isEmpty &&
              match model.display.scenes with
              | #[scene] =>
                scene.echo == "refused: no such text" && scene.views.isEmpty &&
                  scene.size == ⟨640, 480⟩ &&
                  scene.focused == some ⟨0⟩
              | _ => false
          | (.error _, _) => false },
    { name :=
        "an event that changes nothing, once one buffer's text was released, publishes a scene with the refusal in its echo and the other buffer's view, and the other buffer's history is still recorded"
      run :=
        pure <|
          let program : EditorM (EditorState × Loop × String) := do
            let state ← twoBuffers
            let some gone := state.buffers[0]? | throw .noSuchMarker
            let some other := state.buffers[1]? | throw .noSuchMarker
            gone.text.release
            other.text.insert 5 "!"
            let (loop, _) ← ({ state } : Loop).step pressA
            -- The loop recorded the insertion in the other buffer's history:
            -- one undo of it takes the insertion back.
            let some kept := loop.state.buffers[1]? | throw .noSuchMarker
            let some _ ← kept.history.undo | throw .noInverse
            return (state, loop, ← other.text.read)
          match program.runModel editorModel with
          | (.ok (state, loop, undone), model) =>
            undone == "other" && loop.state.wellFormed &&
              loop.state.echo == "refused: no such text" &&
              loop.state.buffers[0]? == state.buffers[0]? &&
              loop.state.windows == state.windows &&
              loop.state.frame == state.frame &&
              match model.display.scenes with
              | #[scene] =>
                scene.echo == "refused: no such text" && scene.views.map (·.id) == #[⟨1⟩] &&
                  scene.views.all fun view => shownText model view == some "other!"
              | _ => false
          | (.error _, _) => false },
    { name :=
        "a released text no window shows still puts its refusal in the scene's echo, with every view shown; so does a view's text that refuses when no history did, and that view is left out"
      run :=
        pure <|
          let hidden : EditorM Loop := do
            let state ← EditorState.initial ⟨640, 480⟩
            let text ← createText "hidden"
            let history ← UndoTree.over text
            text.release
            let state :=
              { state with buffers := state.buffers.push { name := "hidden", text, history } }
            return (← ({ state } : Loop).step pressA).1
          -- A buffer whose history is over another text than its own: the
          -- history is recorded, and only the view is refused.
          let astray : EditorM Loop := do
            let state ← EditorState.initial ⟨640, 480⟩
            let some buffer := state.buffers[0]? | throw .noSuchMarker
            let history ← UndoTree.over (← createText "elsewhere")
            buffer.text.release
            let state := { state with buffers := #[{ buffer with history }] }
            return (← ({ state } : Loop).step pressA).1
          (match hidden.runModel editorModel with
            | (.ok loop, model) =>
              loop.state.echo == "refused: no such text" &&
                match model.display.scenes with
                | #[scene] =>
                  scene.echo == "refused: no such text" && scene.views.map (·.id) == #[⟨0⟩]
                | _ => false
            | (.error _, _) => false) &&
            match astray.runModel editorModel with
            | (.ok loop, model) =>
              loop.state.echo == "refused: no such text" && loop.shown.isEmpty &&
                match model.display.scenes with
                | #[scene] => scene.echo == "refused: no such text" && scene.views.isEmpty
                | _ => false
            | (.error _, _) => false },
    { name :=
        "when a snapshot the last scene named was released behind the loop, the next scene is still published and the loop keeps the new snapshot; the refusal of its release is in the state's echo, and in the scene after"
      run :=
        pure <|
          let program : EditorM (Loop × String × Bool) := do
            let mut loop ← Loop.start ⟨640, 480⟩
            loop := (← loop.step (.commit "a")).1
            let some first := loop.shown[0]? | throw .noSuchMarker
            first.snapshot.release
            loop := (← loop.step (.commit "b")).1
            let some second := loop.shown[0]? | throw .noSuchMarker
            let shown ← second.snapshot.read
            let echoed := loop.state.echo == "refused: no such snapshot"
            loop := (← loop.step pressA).1
            return (loop, shown, echoed && first.snapshot != second.snapshot)
          match program.runModel editorModel with
          | (.ok (loop, shown, echoed), model) =>
            echoed && shown == "ab" && loop.state.wellFormed && loop.shown.size == 1 &&
              model.display.scenes.map (·.echo) == #["", "", "refused: no such snapshot"]
          | (.error _, _) => false }]

/-- The focused window's buffer and window in `loop`'s state, or a refusal
for a state with none. -/
def focusedOf (loop : Loop) : EditorM Target := do
  let some target := loop.state.focusedTarget? | throw .noSuchText
  return target

/-- The ranges of the focused window's selection marker in `loop`'s state. -/
def cursorsOf (loop : Loop) : EditorM (Array SelectionRange) := do
  let target ← focusedOf loop
  let .selection selection ← target.buffer.text.marker target.window.selection | throw .noSuchMarker
  return selection.ranges

/-- The initial state at 640 by 480, its buffer holding `text`, and the
focused window's selection placed at `ranges`, exclusive. -/
def holding (text : String) (ranges : Array SelectionRange) : TextM EditorState := do
  let state ← EditorState.initial ⟨640, 480⟩
  let some target := state.focusedTarget? | throw .noSuchText
  target.buffer.text.insert 0 text
  target.buffer.text.place target.window.selection (.selection { ranges })
  return state

/-- The checks of a text commit in the loop, on the editor's models. -/
def commitChecks : List Check :=
  [{  name :=
        "commits of a, b and c publish one scene each, whose focused view shows the text so far, with the window's cursor just after what was committed"
      run :=
        pure <|
          let program : EditorM (Array (SnapshotId × String × Array SelectionRange)) := do
            let mut loop ← Loop.start ⟨640, 480⟩
            let mut seen := #[]
            for text in ["a", "b", "c"] do
              loop := (← loop.step (.commit text)).1
              let some shown := loop.shown[0]? | throw .noSuchSnapshot
              seen := seen.push (shown.snapshot, ← shown.snapshot.read, ← cursorsOf loop)
            return seen
          match program.runModel editorModel with
          | (.ok seen, model) =>
            let scenes := model.display.scenes
            seen.map (·.2) == #[("a", #[⟨1, 1⟩]), ("ab", #[⟨2, 2⟩]), ("abc", #[⟨3, 3⟩])] &&
              scenes.size == 3 &&
              (scenes.zip seen).all fun (scene, (snapshot, _)) =>
                scene.focused == some ⟨0⟩ &&
                  (scene.views.find? (·.id == ⟨0⟩)).map (·.snapshot) == some snapshot
          | (.error _, _) => false },
    { name :=
        "after a commit, one undo of the buffer's history, as the loop left it, restores the text from before the commit, and the commit was the user's"
      run :=
        pure <|
          let program : EditorM (String × String × String × Array Attribution) := do
            let mut loop ← Loop.start ⟨640, 480⟩
            loop := (← loop.step (.commit "hello")).1
            loop := (← loop.step (.commit " world")).1
            let target ← focusedOf loop
            let before ← target.buffer.text.read
            let some moved ← target.buffer.history.undo | throw .noInverse
            let once ← target.buffer.text.read
            let trace ← target.buffer.text.trace 0 5
            let some _ ← moved.tree.undo | throw .noInverse
            return (before, once, ← target.buffer.text.read, trace)
          match (program.runModel editorModel).1 with
          | .ok (before, once, twice, trace) =>
            before == "hello world" && once == "hello" && twice == "" &&
              trace == #[{ start := 0, stop := 5, author := .entry 1 Origin.user }]
          | .error _ => false },
    { name :=
        "a commit replaces what each range of the selection covers, and leaves a cursor after each insertion"
      run :=
        pure <|
          let program : EditorM (String × Array SelectionRange) := do
            let loop : Loop := { state := ← holding "abcd" #[⟨0, 1⟩, ⟨3, 3⟩] }
            let (loop, _) ← loop.step (.commit "xy")
            return (← (← focusedOf loop).buffer.text.read, ← cursorsOf loop)
          match (program.runModel editorModel).1 with
          | .ok (text, cursors) => text == "xybcxyd" && cursors == #[⟨2, 2⟩, ⟨6, 6⟩]
          | .error _ => false },
    { name :=
        "a commit whose selection marker was given up leaves the state as it was, with the refusal in the echo area"
      run :=
        pure <|
          let program : EditorM (EditorState × Loop × Option String) := do
            let state ← EditorState.initial ⟨640, 480⟩
            let some target := state.focusedTarget? | throw .noSuchText
            target.buffer.text.unmark target.window.selection
            let (loop, _) ← ({ state } : Loop).step (.commit "x")
            return (state, loop, ← target.buffer.text.read)
          match program.runModel editorModel with
          | (.ok (state, loop, text), model) =>
            loop.state == { state with echo := "refused: no such marker" } && text == "" &&
              (model.display.scenes.map (·.echo)) == #["refused: no such marker"]
          | (.error _, _) => false },
    { name :=
        "after a commit the snapshot the previous scene named is released, and asking it is refused with noSuchSnapshot"
      run :=
        pure <|
          let program : EditorM (SnapshotId × SnapshotId × Bool) := do
            let mut loop ← Loop.start ⟨640, 480⟩
            loop := (← loop.step (.commit "a")).1
            let some first := loop.shown[0]? | throw .noSuchSnapshot
            loop := (← loop.step (.commit "b")).1
            let some second := loop.shown[0]? | throw .noSuchSnapshot
            let refused ←
              try
                discard first.snapshot.read
                pure false
              catch refusal =>
                pure (refusal == .noSuchSnapshot)
            return (first.snapshot, second.snapshot, refused)
          match (program.runModel editorModel).1 with
          | .ok (first, second, refused) => first != second && refused
          | .error _ => false },
    { name := "a commit clears the preedit"
      run :=
        pure <|
          match looped (EditorState.initial ⟨640, 480⟩) [.preedit "k", .commit "か"] with
          | some ((loop, _), scenes, _) =>
            scenes.map (·.preedit) == #[some "k", none] && loop.state.preedit == none
          | none => false }]

/-- The key of the character `text`, with `modifiers` held, as a binding
names it. -/
def charKey (text : String) (modifiers : Modifiers := {}) : Key :=
  { logical := .character text, modifiers }

/-- The named key `key`, with `modifiers` held, as a binding names it. -/
def namedKey (key : NamedKey) (modifiers : Modifiers := {}) : Key :=
  { logical := .named key, modifiers }

/-- The character `text` with control held: `C-x` for `"x"`. -/
def controlKey (text : String) : Key :=
  charKey text { control := true }

/-- The checks of a keymap (`Editor/Keymap.lean`): what a sequence is bound
to, which sequences a binding begins with, and the form of a key a binding
names. -/
def keymapChecks : List Check :=
  let save : Keymap Nat := Keymap.empty.bind [controlKey "x", controlKey "s"] 1
  let other : Keymap Nat := Keymap.empty.bind [controlKey "x", controlKey "s"] 2
  let find : Keymap Nat := Keymap.empty.bind [charKey "f"] 3
  let long : Keymap Nat := Keymap.empty.bind [controlKey "x", controlKey "r", charKey "t"] 4
  let prefixBound : Keymap Nat := Keymap.empty.bind [controlKey "x", controlKey "r"] 5
  [{  name := "a key sequence bound in a keymap is found, bound to what it was given"
      run := pure (save.find? [controlKey "x", controlKey "s"] == some 1) },
    { name :=
        "a strict prefix of a bound sequence is not found, and a binding begins with it; a binding begins with the bound sequence too"
      run :=
        pure
          (save.find? [controlKey "x"] == none && save.continues [controlKey "x"] &&
            save.continues [controlKey "x", controlKey "s"]) },
    { name :=
        "a sequence no binding begins with is not found and nothing begins with it: another key, a bound sequence's second key, and a bound sequence with a key after it"
      run :=
        pure <|
          [[charKey "x"], [controlKey "s"], [controlKey "x", controlKey "x"],
                [controlKey "x", controlKey "s", controlKey "s"]].all
            fun keys => save.find? keys == none && !save.continues keys },
    { name := "binding a sequence a second time replaces what it was bound to"
      run :=
        let again := save.bind [controlKey "x", controlKey "s"] 2
        pure
          (again.find? [controlKey "x", controlKey "s"] == some 2 && again.bindings.length == 1) },
    { name := "a keymap made from a list binds each sequence, a later entry replacing an earlier"
      run :=
        let keymap : Keymap Nat :=
          Keymap.ofList [([charKey "a"], 1), ([charKey "b"], 2), ([charKey "a"], 3)]
        pure
          (keymap.find? [charKey "a"] == some 3 && keymap.find? [charKey "b"] == some 2 &&
            keymap.bindings.length == 2) },
    { name := "the empty sequence binds nothing"
      run :=
        let keymap : Keymap Nat := Keymap.empty.bind [] 1
        pure (keymap.bindings.isEmpty && keymap.find? [] == none && !keymap.continues []) },
    { name :=
        "a key from a window finds a binding by its chord: its physical code, whether it was repeated, and shift on a character are not part of it"
      run :=
        let typed : Key :=
          { logical := .character "A"
            physical := .code "KeyA"
            modifiers := { shift := true }
            repeated := true }
        let written : Keymap Nat := Keymap.empty.bind [charKey "A"] 1
        let fromWindow : Keymap Nat := Keymap.empty.bind [typed] 1
        pure
          (typed.chord == charKey "A" && written.find? [typed.chord] == some 1 &&
            fromWindow.find? [charKey "A"] == some 1 &&
            (controlKey "x").chord == controlKey "x") },
    { name :=
        "shift on a named key is part of its chord: the shifted key does not find the unshifted key's binding"
      run :=
        let shifted : Key :=
          { logical := .named .tab, physical := .code "Tab", modifiers := { shift := true } }
        let keymap : Keymap Nat := Keymap.empty.bind [namedKey .tab] 1
        pure
          (shifted.chord == namedKey .tab { shift := true } &&
            keymap.find? [shifted.chord] == none &&
            keymap.find? [namedKey .tab] == some 1 &&
            (keymap.bind [shifted] 2).find? [shifted.chord] == some 2) },
    { name := "of two keymaps that bind one sequence, the earlier in the list gives its binding"
      run :=
        pure
          (Keymap.resolve [other, save] [controlKey "x", controlKey "s"] == .bound 2 &&
            Keymap.resolve [save, other] [controlKey "x", controlKey "s"] == .bound 1) },
    { name :=
        "a sequence that begins a binding is pending, whichever keymap of the list the binding is in, and one that begins none is unbound"
      run :=
        pure
          (Keymap.resolve [save, find] [controlKey "x"] == .pending &&
            Keymap.resolve [save, long] [controlKey "x", controlKey "r"] == .pending &&
            Keymap.resolve [save, long] [controlKey "x", controlKey "q"] == .unbound &&
            Keymap.resolve ([] : List (Keymap Nat)) [controlKey "x"] == .unbound) },
    { name :=
        "a sequence a later keymap binds is bound although an earlier keymap has a longer binding that begins with it"
      run :=
        pure (Keymap.resolve [long, prefixBound] [controlKey "x", controlKey "r"] == .bound 5) },
    { name := "the walk given a key that begins a binding keeps it pending and yields nothing"
      run :=
        let (first, firstBound) := Keymap.walk [long] [] (controlKey "x")
        let (second, secondBound) := Keymap.walk [long] first (controlKey "r")
        pure
          (first == [controlKey "x"] && firstBound == none &&
            second == [controlKey "x", controlKey "r"] &&
            secondBound == none) },
    { name :=
        "the walk given the last key of a bound sequence yields its binding and leaves nothing pending"
      run :=
        pure
          (Keymap.walk [save] [controlKey "x"] (controlKey "s") == ([], some 1) &&
            Keymap.walk [find] [] (charKey "f") == ([], some 3)) },
    { name :=
        "the walk given an unbound key after a pending prefix yields nothing and leaves nothing pending"
      run :=
        pure
          (Keymap.walk [save] [controlKey "x"] (charKey "z") == ([], none) &&
            Keymap.walk [save] [] (charKey "z") == ([], none)) },
    { name := "the walk takes a key by its chord"
      run :=
        let typed : Key :=
          { logical := .character "s"
            physical := .code "KeyS"
            modifiers := { control := true }
            repeated := true }
        pure
          (Keymap.walk [save] [controlKey "x"] typed == ([], some 1) &&
            Keymap.walk [save] [] { controlKey "x" with physical := .code "KeyX" } ==
              ([controlKey "x"], none)) }]

/-- Whether `text` is a key string that names exactly `keys`. -/
def parses (text : String) (keys : List Key) : Bool :=
  match Key.parse text with
  | .ok named => named == keys
  | .error _ => false

/-- Whether `text` is refused as a key string, with a reason that names
`token`. -/
def refusesKey (text token : String) : Bool :=
  match Key.parse text with
  | .ok _ => false
  | .error reason => (reason.splitOn token).length > 1

/-- The checks of key strings (`Editor/Key/Notation.lean`): the keys a
string names, the strings that are refused, and that a chord's notation
names it. -/
def keyNotationChecks : List Check :=
  [{  name := "a key string names its strokes in order, each with the modifiers written before it"
      run := pure (parses "C-x C-s" [controlKey "x", controlKey "s"]) },
    { name :=
        "a stroke of one character is that character, whatever it is: a capital, the minus sign, an angle bracket"
      run :=
        pure
          (parses "A" [charKey "A"] && parses "-" [charKey "-"] && parses "C--" [controlKey "-"] &&
            parses "<" [charKey "<"] &&
            parses "x - >" [charKey "x", charKey "-", charKey ">"]) },
    { name := "a name in angle brackets is the named key of that name"
      run :=
        pure
          (parses "<Escape>" [namedKey .escape] && parses "<ArrowLeft>" [namedKey .arrowLeft] &&
            parses "<F5>" [namedKey ⟨"F5"⟩]) },
    { name := "RET, ESC and TAB are Enter, Escape and Tab, and SPC is the space character"
      run :=
        pure
          (parses "RET ESC TAB SPC"
            [namedKey .enter, namedKey .escape, namedKey .tab, charKey " "]) },
    { name :=
        "each modifier prefix holds its modifier: C- control, M- alt, s- super, and S- shift on a named key"
      run :=
        pure
          (parses "M-s-<ArrowLeft>" [namedKey .arrowLeft { alt := true, superKey := true }] &&
            parses "S-<Tab>" [namedKey .tab { shift := true }] &&
            parses "S-TAB" [namedKey .tab { shift := true }] &&
            parses "C-M-x" [charKey "x" { control := true, alt := true }] &&
            parses "s-s" [charKey "s" { superKey := true }]) },
    { name := "the empty string names no keys, and spaces around strokes name none"
      run :=
        pure
          (parses "" [] && parses "   " [] &&
            parses " C-x  C-s " [controlKey "x", controlKey "s"]) },
    { name :=
        "a string with a stroke that is not a key is refused, naming the stroke: shift on a character, a modifier with no key, two characters, a name that is not closed, an empty name"
      run :=
        pure
          (refusesKey "S-a" "S-a" && refusesKey "x C-" "C-" && refusesKey "C-x xy" "xy" &&
            refusesKey "<Escape" "<Escape" &&
            refusesKey "<>" "<>" &&
            refusesKey "S-SPC" "S-SPC") },
    { name :=
        "a name in angle brackets that is not letters and digits is refused, naming the stroke: a modifier prefix inside the brackets, an underscore"
      run := pure (refusesKey "<C-x>" "<C-x>" && refusesKey "x <a_b>" "<a_b>") },
    { name :=
        "a letter that is no modifier's is not a prefix: the stroke it begins is refused, naming it, and it is the minus key's stroke that stays a key"
      run :=
        pure
          (refusesKey "X-a" "X-a" && refusesKey "C-X-a" "C-X-a" && refusesKey "c-x" "c-x" &&
            parses "C-- X" [controlKey "-", charKey "X"]) },
    { name := "the keys a key string names are chords"
      run :=
        pure <|
          ["C-x C-s", "A", "S-<Tab>", "M-s-<ArrowLeft>", "RET SPC"].all fun text =>
            match Key.parse text with
            | .ok keys => keys.map Key.chord == keys
            | .error _ => false },
    { name := "a key's notation is its modifiers, then the character or the name in angle brackets"
      run :=
        pure
          (Key.notation (controlKey "x") == "C-x" && Key.notation (charKey "A") == "A" &&
            Key.notation (charKey " ") == "SPC" &&
            Key.notation (namedKey .enter) == "<Enter>" &&
            Key.notation
                (namedKey .arrowLeft
                  { shift := true, control := true, alt := true, superKey := true }) ==
              "C-M-s-S-<ArrowLeft>" &&
            Key.notation { logical := .dead none } == "<Dead>" &&
            Key.notation { logical := .unidentified } == "<Unidentified>" &&
            Key.notations [controlKey "x", controlKey "s"] == "C-x C-s" &&
            Key.notations [] == "") },
    { name := "the notation of chords of characters and named keys names those chords"
      run :=
        pure <|
          [[controlKey "x", controlKey "s"], [charKey "A"], [charKey "-"], [controlKey "-"],
                [charKey "<"], [charKey " ", charKey "s" { superKey := true }],
                [namedKey .escape, namedKey .enter, namedKey .tab { shift := true }],
                [namedKey .arrowLeft { control := true, alt := true, superKey := true }],
                [charKey "é" { alt := true }], []].all
            fun keys => parses (Key.notations keys) keys }]

/-- The checks of invocations (`Editor/Invocation.lean`): two can be
compared, by their command names and their arguments. -/
def invocationChecks : List Check :=
  let save : Invocation := { command := "save" }
  let insert (text : String) : Invocation := { command := "self-insert", arguments := [.str text] }
  [{  name := "two invocations of one command with the same arguments are equal"
      run :=
        pure
          (decide (save = { command := "save" }) && decide (insert "a" = insert "a") &&
            decide
              (({ command := "move", arguments := [.nat 2, .int (-1), .bool true] } : Invocation) =
                { command := "move", arguments := [.nat 2, .int (-1), .bool true] })) },
    { name := "invocations of commands with different names are unequal"
      run := pure (decide (save ≠ { command := "quit" })) },
    { name :=
        "invocations of one command are unequal when an argument differs: in its value, in its kind, in how many there are, or in their order"
      run :=
        pure
          (decide (insert "a" ≠ insert "b") &&
            decide
              (({ command := "move", arguments := [.nat 1] } : Invocation) ≠
                { command := "move", arguments := [.int 1] }) &&
            decide (save ≠ { command := "save", arguments := [.bool false] }) &&
            decide
              (({ command := "move", arguments := [.nat 1, .nat 2] } : Invocation) ≠
                { command := "move", arguments := [.nat 2, .nat 1] })) }]

/-- The key strings the scheme fixtures are written with. -/
def schemeKeyStrings : List String :=
  ["C-x C-s", "C-x C-f", "C-x r t", "C-q", "C-x", "C-x r", "z", "a", "<Escape>", "C-z M-z s-z",
    "SPC"]

/-- A keymap for the scheme checks: sequences of two keys and of three, and
one of one key. -/
def globalMap : Keymap Invocation :=
  Keymap.ofList
    [(keys "C-x C-s", invoke "save"), (keys "C-x C-f", invoke "find-file"),
      (keys "C-x r t", invoke "string-rectangle"), (keys "C-q", invoke "quit")]

/-- A keymap that binds one of `globalMap`'s sequences to another command. -/
def localMap : Keymap Invocation :=
  Keymap.ofList [(keys "C-x C-s", invoke "save-as")]

/-- The keymaps of the scheme checks' views: `localMap` before `globalMap`
for view 1, `globalMap` alone for every other. -/
def schemeMaps (view : ViewId) : List (Keymap Invocation) :=
  if view.index == 1 then [localMap, globalMap] else [globalMap]

/-- The test scheme's initial state, at its own type: the scheme's `State`
is a field, and instance search does not see through it to the type's
decidable equality. -/
def schemeInit : TestScheme.State :=
  TestScheme.scheme.init

/-- The test scheme stepped from `state` through `typed`, keys for `view`:
the state it is left in, at its own type, and what each key yielded. -/
def typedFrom (view : ViewId) (state : TestScheme.State) (typed : List Key) :
    TestScheme.State × List (Option Invocation) :=
  TestScheme.scheme.feed schemeMaps view state typed

/-- `typedFrom` the test scheme's initial state. -/
def typedInto (view : ViewId) (typed : List Key) : TestScheme.State × List (Option Invocation) :=
  typedFrom view schemeInit typed

/-- `typedInto`, of the keys a key string names. -/
def fed (view : ViewId) (text : String) : TestScheme.State × List (Option Invocation) :=
  typedInto view (keys text)

/-- The checks of input schemes (`Editor/InputScheme.lean`) on the test
scheme (`Editor/InputScheme/Test.lean`): what the keys of a bound sequence
yield, what an unbound key does, which keymap wins, the pending keys, and
the test scheme's self-insert. -/
def schemeChecks : List Check :=
  [{  name := "every key string the scheme fixtures are written with names keys"
      run := pure (schemeKeyStrings.all fun text => !(keys text).isEmpty) },
    { name :=
        "the keys of a bound sequence stepped through the test scheme: the last yields the bound invocation and each earlier key yields none"
      run :=
        pure
          ((fed ⟨0⟩ "C-x C-s").2 == [none, some (invoke "save")] &&
            (fed ⟨0⟩ "C-x r t").2 == [none, none, some (invoke "string-rectangle")] &&
            (fed ⟨0⟩ "C-q").2 == [some (invoke "quit")]) },
    { name :=
        "an unbound key after a pending prefix yields no invocation and leaves the test scheme in its initial state"
      run :=
        let (state, yields) := fed ⟨0⟩ "C-x z"
        let (deeper, deeperYields) := fed ⟨0⟩ "C-x r z"
        pure
          (yields == [none, none] && decide (state = schemeInit) &&
            deeperYields == [none, none, none] &&
            decide (deeper = schemeInit)) },
    { name := "a bound sequence typed after an unbound key reset the prefix yields its invocation"
      run := pure ((fed ⟨0⟩ "C-x z C-x C-s").2 == [none, none, none, some (invoke "save")]) },
    { name :=
        "of two keymaps in a view's list that bind one sequence, the earlier's invocation is yielded"
      run :=
        pure
          ((fed ⟨1⟩ "C-x C-s").2 == [none, some (invoke "save-as")] &&
            (fed ⟨1⟩ "C-x C-f").2 == [none, some (invoke "find-file")]) },
    { name :=
        "a scheme is stepped with the keymaps of the view the key is for: another view's are not asked"
      run :=
        pure
          ((fed ⟨0⟩ "C-x C-s").2 == [none, some (invoke "save")] &&
            (fed ⟨2⟩ "C-x C-s").2 == [none, some (invoke "save")] &&
            (fed ⟨1⟩ "C-x C-s").2 != (fed ⟨0⟩ "C-x C-s").2) },
    { name :=
        "the test scheme reports a pending prefix as its pending keys, and none before a key and after the sequence completes"
      run :=
        let pendingAfter (text : String) : List Key := TestScheme.scheme.pending (fed ⟨0⟩ text).1
        pure
          (TestScheme.scheme.pending schemeInit == [] && pendingAfter "C-x" == keys "C-x" &&
            pendingAfter "C-x r" == keys "C-x r" &&
            pendingAfter "C-x C-s" == [] &&
            pendingAfter "C-x r t" == [] &&
            pendingAfter "C-x z" == []) },
    { name :=
        "the invocations the test scheme yields for one key sequence are equal, and those for sequences bound to different commands are unequal"
      run :=
        pure
          (decide ((fed ⟨0⟩ "C-x C-s").2 = (fed ⟨0⟩ "C-x C-s").2) &&
            decide ((fed ⟨0⟩ "C-x C-s").2 ≠ (fed ⟨0⟩ "C-x C-f").2) &&
            decide ((fed ⟨0⟩ "C-x C-s").2 ≠ (fed ⟨1⟩ "C-x C-s").2) &&
            decide ((fed ⟨0⟩ "a").2 = (fed ⟨0⟩ "a").2) &&
            decide ((fed ⟨0⟩ "a").2 ≠ (fed ⟨0⟩ "z").2)) },
    { name :=
        "an unbound printable key with nothing pending yields the test scheme's self-insert of its character and leaves nothing pending"
      run :=
        let typed : Key :=
          { logical := .character "A", physical := .code "KeyA", modifiers := { shift := true } }
        pure
          (fed ⟨0⟩ "a" == ({}, [some (TestScheme.selfInsert "a")]) &&
            (fed ⟨0⟩ "SPC").2 == [some (TestScheme.selfInsert " ")] &&
            (typedInto ⟨0⟩ [typed]).2 == [some (TestScheme.selfInsert "A")] &&
            (fed ⟨0⟩ "C-x z a").2 == [none, none, some (TestScheme.selfInsert "a")]) },
    { name :=
        "an unbound key that is not printable yields nothing: a named key, and a character with control, alt or super held"
      run :=
        pure
          (fed ⟨0⟩ "<Escape>" == ({}, [none]) &&
            fed ⟨0⟩ "C-z M-z s-z" == ({}, [none, none, none]) &&
            (typedInto ⟨0⟩ [{ logical := .dead (some '´') }, { logical := .unidentified }]).2 ==
              [none, none]) },
    { name :=
        "the test scheme takes a key by its chord: a key from a window, with its physical code and repeated, continues and completes a sequence"
      run :=
        let fromWindow (key : Key) (code : String) : Key :=
          { key with
            physical := .code code, repeated := true }
        let typed := [fromWindow (controlKey "x") "KeyX", fromWindow (controlKey "s") "KeyS"]
        pure
          ((typedInto ⟨0⟩ typed).2 == [none, some (invoke "save")] &&
            TestScheme.scheme.pending (typedInto ⟨0⟩ (typed.take 1)).1 == keys "C-x") },
    { name :=
        "feeding a scheme keys yields one entry a key, in order, and starts from the state it is given"
      run :=
        let (afterPrefix, first) := fed ⟨0⟩ "C-x"
        let (state, second) := typedFrom ⟨0⟩ afterPrefix (keys "C-s a")
        pure
          (first ++ second == (fed ⟨0⟩ "C-x C-s a").2 && decide (state = (fed ⟨0⟩ "C-x C-s a").1) &&
            fed ⟨0⟩ "" == ({}, [])) }]

/-- A scheme written for the test that breaks the contract: it yields the
first binding that the keys so far begin, so it emits on a strict prefix. -/
def eager : InputScheme :=
  { State := List Key
    Binding := Invocation
    init := []
    step := fun maps view state key =>
      let typed := state ++ [key.chord]
      match
        (maps view).findSome? fun keymap =>
          keymap.bindings.find? fun binding => typed.isPrefixOf binding.1 with
      | some binding => ([], some binding.2)
      | none => ([], none)
    pending := id
    command := fun name => { command := name } }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that an unbound key leaves the pending keys as they were. -/
def sticky : InputScheme :=
  { State := TestScheme.State
    Binding := Invocation
    init := {}
    step := fun maps view state key =>
      match TestScheme.step maps view state key with
      | (next, some invocation) => (next, some invocation)
      | (next, none) => (if next.pending.isEmpty then state else next, none)
    pending := (·.pending)
    command := fun name => { command := name } }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that it reports no pending keys. -/
def silent : InputScheme :=
  { State := TestScheme.State
    Binding := Invocation
    init := {}
    step := TestScheme.step
    pending := fun _ => []
    command := fun name => { command := name } }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that an unbound key after a prefix hides the prefix and does not drop
it. It then reports no pending keys, and the key typed next is still walked
from the prefix, so the input typed next does not yield what it yields from
the initial state. Its state is the test scheme's, and whether its pending
keys are hidden. -/
def masking : InputScheme :=
  { State := TestScheme.State × Bool
    Binding := Invocation
    init := ({}, false)
    step := fun maps view state key =>
      match TestScheme.step maps view state.1 key with
      | (next, some invocation) => ((next, false), some invocation)
      | (next, none) =>
        if !state.1.pending.isEmpty && next.pending.isEmpty && !state.2 then ((state.1, true), none)
        else ((next, false), none)
    pending := fun state => if state.2 then [] else state.1.pending
    command := fun name => { command := name } }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that an unbound key after a prefix yields an invocation. -/
def noisy : InputScheme :=
  { State := TestScheme.State
    Binding := Invocation
    init := {}
    step := fun maps view state key =>
      match TestScheme.step maps view state key with
      | (next, some invocation) => (next, some invocation)
      | (next, none) =>
        if !state.pending.isEmpty && next.pending.isEmpty then (next, some (invoke "noise"))
        else (next, none)
    pending := (·.pending)
    command := fun name => { command := name } }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that after a key that yields an invocation it reports the keys of the
input just completed as pending. Its state is the test scheme's, and the
keys it reports. -/
def lingering : InputScheme :=
  { State := TestScheme.State × List Key
    Binding := Invocation
    init := ({}, [])
    step := fun maps view state key =>
      match TestScheme.step maps view state.1 key with
      | (next, some invocation) => ((next, state.1.pending ++ [key.chord]), some invocation)
      | (next, none) => ((next, next.pending), none)
    pending := (·.2)
    command := fun name => { command := name } }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that what it says runs a named command runs a command of another
name. -/
def misnaming : InputScheme :=
  { TestScheme.scheme with command := fun name => { command := name ++ "-not" } }

/-- The subject the scheme contract is run on: `scheme` over the scheme
checks' keymaps for view 0, the sequences those bind, and a key none of
them goes on with. -/
def subjectOf (scheme : InputScheme) (maps : ViewId → List (Keymap scheme.Binding)) :
    SchemeContract.Subject :=
  { scheme
    maps
    view := ⟨0⟩
    sequences := [keys "C-x C-s", keys "C-x C-f", keys "C-x r t", keys "C-q"]
    unbound := charKey "z" }

/-- Whether exactly the properties `expected` of the scheme contract do not
hold of `subject`. -/
def failsOnly (subject : SchemeContract.Subject) (expected : List SchemeContract.Property) : Bool :=
  SchemeContract.failures subject == expected.map (·.name) &&
    SchemeContract.properties.all fun property =>
      property.holds subject != expected.any (·.name == property.name)

/-- The checks of the scheme contract (`Editor/InputScheme/Contract.lean`):
it holds of the test scheme, and it reports schemes written here that each
break it. -/
def schemeContractChecks : List Check :=
  [{  name := "the scheme contract has properties, each with a name of its own"
      run :=
        let names := SchemeContract.properties.map (·.name)
        pure (!names.isEmpty && names.eraseDups.length == names.length) },
    { name := "the scheme contract holds of the test scheme"
      run := pure (SchemeContract.failures (subjectOf TestScheme.scheme schemeMaps) == []) },
    { name :=
        "the scheme contract reports a scheme that emits on a strict prefix of a binding, by the name of the property it breaks"
      run :=
        let subject := subjectOf eager schemeMaps
        pure
          (!SchemeContract.strictPrefixEmitsNothing.holds subject &&
            (SchemeContract.failures subject).contains
              SchemeContract.strictPrefixEmitsNothing.name) },
    { name :=
        "the scheme contract reports a subject with no sequence of two keys, of which its other properties would hold with nothing to show"
      run :=
        let subject := { subjectOf TestScheme.scheme schemeMaps with sequences := [keys "C-q"] }
        pure (failsOnly subject [SchemeContract.hasPrefixes]) },
    { name :=
        "the scheme contract reports a scheme that keeps its pending keys after an unbound key"
      run := pure (failsOnly (subjectOf sticky schemeMaps) [SchemeContract.unboundResets]) },
    { name := "the scheme contract reports a scheme that does not report a pending prefix"
      run :=
        pure (failsOnly (subjectOf silent schemeMaps) [SchemeContract.strictPrefixIsPending]) },
    { name :=
        "the scheme contract reports a sequence said to be complete that yields nothing: one the keymaps do not bind"
      run :=
        let subject :=
          { subjectOf TestScheme.scheme schemeMaps with
            sequences := [keys "C-x C-s", keys "C-x <Escape>"] }
        pure (failsOnly subject [SchemeContract.completeEmits]) },
    { name :=
        "the scheme contract reports a scheme that reports no pending keys after an unbound key and keeps the prefix, so that the input typed next yields something else"
      run :=
        let subject := subjectOf masking schemeMaps
        let (state, yields) := subject.feed (keys "C-x z")
        pure
          (failsOnly subject [SchemeContract.unboundResets] && yields == [none, none] &&
            (subject.scheme.pending state).isEmpty) },
    { name :=
        "the scheme contract reports a scheme that yields an invocation on an unbound key after a prefix"
      run :=
        let subject := subjectOf noisy schemeMaps
        let (state, _) := subject.feed (keys "C-x z")
        pure
          (failsOnly subject [SchemeContract.unboundResets] &&
            (subject.scheme.pending state).isEmpty &&
            (subject.feedFrom state (keys "C-x C-s")).2 == (subject.feed (keys "C-x C-s")).2) },
    { name :=
        "the scheme contract reports a scheme that still reports pending keys after the key that completes an input, for a bound sequence and for a key bound to a named command"
      run :=
        let subject := subjectOf lingering schemeMaps
        pure
          (failsOnly subject [SchemeContract.completeEmits, SchemeContract.namedCommandRuns] &&
            (subject.feed (keys "C-x C-s")).2.getLast? == some (some (invoke "save"))) },
    { name :=
        "the scheme contract reports a scheme whose binding for a command name runs a command of another name, for that property alone"
      run := pure (failsOnly (subjectOf misnaming schemeMaps) [SchemeContract.namedCommandRuns]) }]

/-- The delete operator of the Vim checks: it changes text and names no
state. -/
def vimDelete : Vim.Operator :=
  { name := "delete" }

/-- The change operator of the Vim checks: it changes text and enters the
state `insert`. -/
def vimChange : Vim.Operator :=
  { name := "change", enters := some "insert" }

/-- The yank operator of the Vim checks: it changes no text. -/
def vimYank : Vim.Operator :=
  { name := "yank", changes := false }

/-- A command of the Vim checks that changes text and enters the state
`insert`. -/
def vimInsert : Vim.Command :=
  { name := "insert", changes := true, enters := some "insert" }

/-- The checks of the Vim scheme's edits (`Editor/InputScheme/Vim.lean`):
the invocation each compiles to, and what an edit says of itself. -/
def vimEditChecks : List Check :=
  let undo : Vim.Command := { name := "undo" }
  [{  name := "a move compiles to the move command, with the motion's name and then the count"
      run :=
        pure
          ((Vim.Edit.move "word" (some 2)).compile ==
              { command := "move", arguments := [.str "word", .nat 2] } &&
            Vim.moveCommand == "move") },
    { name :=
        "an edit with an operator compiles to the operate command, with the operator's name, the kind of its target and the target's name, the count and the register: over a motion, a text object, lines and the selection"
      run :=
        let compiled (over : Vim.Over) : Invocation :=
          (Vim.Edit.operate vimDelete over (some 3) (some "a")).compile
        let expected (kind name : String) : Invocation :=
          { command := "operate"
            arguments := [.str "delete", .str kind, .str name, .nat 3, .str "a"] }
        pure
          (compiled (.motion "word") == expected "motion" "word" &&
            compiled (.textObject "inner-word") == expected "text-object" "inner-word" &&
            compiled .lines == expected "lines" "" &&
            compiled .selection == expected "selection" "" &&
            Vim.operateCommand == "operate") },
    { name :=
        "an edit that runs a command compiles to that command, with the count and then the register"
      run :=
        pure
          ((Vim.Edit.run { name := "put-after" } (some 2) (some "+")).compile ==
            { command := "put-after", arguments := [.nat 2, .str "+"] }) },
    { name :=
        "an edit with no count compiles to a count of 0, and one with no register to the empty register name"
      run :=
        pure
          ((Vim.Edit.move "word" none).compile ==
              { command := "move", arguments := [.str "word", .nat 0] } &&
            (Vim.Edit.operate vimDelete .lines none none).compile ==
              { command := "operate"
                arguments := [.str "delete", .str "lines", .str "", .nat 0, .str ""] } &&
            (Vim.Edit.run undo none none).compile ==
              { command := "undo", arguments := [.nat 0, .str ""] }) },
    { name :=
        "edits that differ in one part compile to invocations that differ, each from every other"
      run :=
        let edits : List Vim.Edit :=
          [.move "word" none, .move "word" (some 1), .move "word" (some 2), .move "line" none,
            .operate vimDelete (.motion "word") none none,
            .operate vimYank (.motion "word") none none,
            .operate vimDelete (.motion "line") none none,
            .operate vimDelete (.textObject "word") none none, .operate vimDelete .lines none none,
            .operate vimDelete .selection none none,
            .operate vimDelete (.motion "word") (some 2) none,
            .operate vimDelete (.motion "word") none (some "a"),
            .operate vimDelete (.motion "word") none (some "b"), .run undo none none,
            .run { name := "redo" } none none, .run undo (some 2) none, .run undo none (some "a")]
        let compiled := edits.map (·.compile)
        pure (compiled.eraseDups.length == edits.length) },
    { name :=
        "whether an edit changes text is its operator's or its command's word for it, and a move changes none"
      run :=
        pure
          ((Vim.Edit.operate vimDelete .lines none none).changes &&
            !(Vim.Edit.operate vimYank .lines none none).changes &&
            (Vim.Edit.run vimInsert none none).changes &&
            !(Vim.Edit.run undo none none).changes &&
            !(Vim.Edit.move "word" (some 2)).changes) },
    { name :=
        "the state an edit enters is the one its operator or its command names, and a move names none"
      run :=
        pure
          ((Vim.Edit.operate vimChange .lines none none).enters == some "insert" &&
            (Vim.Edit.operate vimDelete .lines none none).enters == none &&
            (Vim.Edit.run vimInsert none none).enters == some "insert" &&
            (Vim.Edit.run undo none none).enters == none &&
            (Vim.Edit.move "word" none).enters == none) }]

/-- The keymap that binds each key string of `table` to what is beside it.
A string that names no keys binds nothing. -/
def vimKeymap (table : List (String × Vim.Bound)) : Keymap Vim.Bound :=
  Keymap.ofList (table.map fun (text, bound) => (keys text, bound))

/-- What the Vim checks' normal state binds: three operators, the motion
`word` on `w`, a motion on two keys and one on `0`, a text object, and
commands: one that enters `insert` and changes text, one that enters
`visual`, one that does neither, and one that changes text and enters no
state; and the register prefix on `"`. The names are the checks' own, and
are no default's. -/
def vimNormalTable : List (String × Vim.Bound) :=
  [("d", .operator vimDelete), ("c", .operator vimChange), ("y", .operator vimYank),
    ("w", .motion "word"), ("g g", .motion "first-line"), ("0", .motion "line-start"),
    ("t", .textObject "thing"), ("i", .command vimInsert),
    ("v", .command { name := "visual", enters := some "visual" }),
    ("u", .command { name := "undo" }), ("x", .command { name := "delete-char", changes := true }),
    ("\"", .register)]

/-- What the Vim checks' insert and visual states bind first: a command
that enters `normal`. -/
def vimEscapeTable : List (String × Vim.Bound) :=
  [("<Escape>", .command { name := "normal", enters := some "normal" })]

/-- The registry of Vim states the grammar's checks run on, written here so
that no check of the grammar names a default binding: `normal`, the initial
state; `insert`, where typing is text; and `visual`, where an operator acts
on the selection and normal's keys are bound too. -/
def vimStates : Vim.States :=
  { initial := { name := "normal", keymaps := [vimKeymap vimNormalTable] }
    others :=
      [{  name := "insert"
          keymaps := [vimKeymap vimEscapeTable]
          cursor := .bar
          insertsText := true },
        { name := "visual"
          keymaps := [vimKeymap vimEscapeTable, vimKeymap vimNormalTable]
          operatesOnSelection := true }] }

/-- A state record as the checks compare it: its name, its cursor, its two
flags and how many keymaps it has. A record has no equality of its own,
since a keymap has none. -/
def vimSeen (record : Vim.StateRecord) : String × CursorShape × Bool × Bool × Nat :=
  (record.name, record.cursor, record.insertsText, record.operatesOnSelection,
    record.keymaps.length)

/-- The checks of the registry of Vim states (`Editor/InputScheme/Vim.lean`):
looking a state up by name, and registering one. -/
def vimRegistryChecks : List Check :=
  [{  name :=
        "the record of a registered Vim state is found by its name, with the cursor, the flags and the keymaps it was registered with"
      run :=
        pure
          (vimSeen (vimStates.get "insert") == ("insert", .bar, true, false, 1) &&
            vimSeen (vimStates.get "visual") == ("visual", .block, false, true, 2) &&
            vimSeen (vimStates.get "normal") == ("normal", .block, false, false, 1)) },
    { name := "a name the registry of Vim states does not have is read as the initial state"
      run :=
        pure
          (vimSeen (vimStates.get "replace") == vimSeen vimStates.initial &&
            (vimStates.get "").name == "normal") },
    { name := "registering a Vim state adds its record, found by its name, and leaves the others"
      run :=
        let added :=
          vimStates.register { name := "replace", cursor := .underline, insertsText := true }
        pure
          (vimSeen (added.get "replace") == ("replace", .underline, true, false, 0) &&
            vimSeen (added.get "insert") == vimSeen (vimStates.get "insert") &&
            added.others.map (·.name) == ["insert", "visual", "replace"] &&
            added.initial.name == "normal") },
    { name := "registering a Vim state of a name already registered replaces that record"
      run :=
        let replaced := vimStates.register { name := "insert", cursor := .hollow }
        pure
          (vimSeen (replaced.get "insert") == ("insert", .hollow, false, false, 0) &&
            (replaced.others.filter (·.name == "insert")).length == 1 &&
            replaced.others.length == 2 &&
            vimSeen replaced.initial == vimSeen vimStates.initial) },
    { name :=
        "registering a Vim state of the initial state's name replaces the initial record, and adds none"
      run :=
        let replaced := vimStates.register { name := "normal", cursor := .underline }
        pure
          (vimSeen replaced.initial == ("normal", .underline, false, false, 0) &&
            vimSeen (replaced.get "normal") == ("normal", .underline, false, false, 0) &&
            replaced.others.map (·.name) == ["insert", "visual"]) }]

/-- No active keymaps, for every view: a key is looked up in the keymaps of
the view's Vim state alone. -/
def vimNoMaps (_ : ViewId) : List (Keymap Vim.Bound) :=
  []

/-- The initial state of the Vim scheme over `vimStates`, at its own type:
instance search does not see through the scheme's `State` field. -/
def vimInit : Vim.State :=
  (Vim.scheme vimStates).init

/-- The Vim scheme over `states` stepped from `state` through the keys the
key string `text` names, keys for `view`, with `maps` the active keymaps:
the state it is left in, at its own type, and what each key yielded. -/
def vimFedFrom (state : Vim.State) (text : String)
    (maps : ViewId → List (Keymap Vim.Bound) := vimNoMaps) (view : ViewId := ⟨0⟩)
    (states : Vim.States := vimStates) : Vim.State × List (Option Invocation) :=
  (Vim.scheme states).feed maps view state (keys text)

/-- `vimFedFrom` the scheme's initial state. -/
def vimFed (text : String) (maps : ViewId → List (Keymap Vim.Bound) := vimNoMaps)
    (view : ViewId := ⟨0⟩) (states : Vim.States := vimStates) :
    Vim.State × List (Option Invocation) :=
  vimFedFrom (Vim.scheme states).init text maps view states

/-- `Vim.parse` over `states` folded from `state` through the keys the key
string `text` names: the state it is left in, and what each key parsed
to. -/
def vimParsedFrom (state : Vim.State) (text : String)
    (maps : ViewId → List (Keymap Vim.Bound) := vimNoMaps) (view : ViewId := ⟨0⟩)
    (states : Vim.States := vimStates) : Vim.State × List Vim.Parsed :=
  (keys text).foldl
    (fun (state, parsed) key =>
      let (next, result) := Vim.parse states maps view state key
      (next, parsed ++ [result]))
    (state, [])

/-- `vimParsedFrom` the scheme's initial state. -/
def vimParsed (text : String) (maps : ViewId → List (Keymap Vim.Bound) := vimNoMaps)
    (view : ViewId := ⟨0⟩) (states : Vim.States := vimStates) : Vim.State × List Vim.Parsed :=
  vimParsedFrom (Vim.scheme states).init text maps view states

/-- The keys the Vim scheme over `vimStates` reports as pending after the
keys `text` names, with `maps` the active keymaps. -/
def vimPending (text : String) (maps : ViewId → List (Keymap Vim.Bound) := vimNoMaps) : List Key :=
  (Vim.scheme vimStates).pending (vimFed text maps).1

/-- Active keymaps, for every view, that bind an operator and the register
prefix to two keys each, `g u` and `g r`: both under `g`, the prefix the
checks' normal state binds a motion under. -/
def vimTwoKeyMaps (_ : ViewId) : List (Keymap Vim.Bound) :=
  [vimKeymap [("g u", .operator { name := "lowercase" }), ("g r", .register)]]

/-- The invocation a move by `motion` compiles to, with `count`, 0 for
none. -/
def vimMove (motion : String) (count : Nat := 0) : Invocation :=
  { command := "move", arguments := [.str motion, .nat count] }

/-- The invocation an edit with the operator `operator` compiles to, over a
target of `kind` named `name`, with `count`, 0 for none, and `register`,
empty for none. -/
def vimOperate (operator kind name : String) (count : Nat := 0) (register : String := "") :
    Invocation :=
  { command := "operate"
    arguments := [.str operator, .str kind, .str name, .nat count, .str register] }

/-- The inputs the Vim checks give the scheme contract as complete, as key
strings. -/
def vimSequences : List String :=
  ["g g", "w", "d w", "d d", "d 2 w", "2 d 3 w", "\" + y w"]

/-- The key the Vim checks give the scheme contract as unbound: a named
key. A key that prints goes on with one strict prefix whatever is bound,
the register prefix, by naming the register. -/
def vimUnbound : Key :=
  namedKey ⟨"F12"⟩

/-- The subject the scheme contract is run on for the Vim scheme: the
scheme over `vimStates`, with no active keymaps, for view 0. -/
def vimSubject : SchemeContract.Subject :=
  { scheme := Vim.scheme vimStates
    maps := vimNoMaps
    view := ⟨0⟩
    sequences := vimSequences.map keys
    unbound := vimUnbound }

/-- The checks of the Vim scheme's grammar (`Editor/InputScheme/Vim.lean`),
on the registry written here: the keymaps a key is looked up in, and what a
key sequence parses to. -/
def vimGrammarChecks : List Check :=
  [{  name := "every row of the Vim checks' tables binds its keys"
      run :=
        pure
          ((vimKeymap vimNormalTable).bindings.length == vimNormalTable.length &&
            (vimKeymap vimEscapeTable).bindings.length == vimEscapeTable.length &&
            vimSequences.all fun text => !(keys text).isEmpty) },
    { name := "a key bound to a motion, typed alone, yields a move by that motion with no count"
      run :=
        pure
          ((vimFed "w").2 == [some (vimMove "word")] &&
            (vimParsed "w").2 == [.edit (.move "word" none)]) },
    { name :=
        "a motion bound to two keys yields its move on the second key, and nothing on the first"
      run := pure ((vimFed "g g").2 == [none, some (vimMove "first-line")]) },
    { name := "a key bound to a command yields the edit that runs it, with no count and no register"
      run :=
        pure
          ((vimFed "u").2 == [some { command := "undo", arguments := [.nat 0, .str ""] }] &&
            (vimParsed "u").2 == [.edit (.run { name := "undo" } none none)]) },
    { name :=
        "the Vim scheme reports the keys typed of an edit begun as pending, and none before a key and after the edit completes"
      run :=
        pure
          (vimPending "" == [] && vimPending "g" == keys "g" && vimPending "g g" == [] &&
            vimPending "w" == []) },
    { name :=
        "an unbound key after a prefix yields nothing and leaves the Vim scheme in its initial state, and the motion typed next yields its move"
      run :=
        let (state, yields) := vimFed "g z"
        let (alone, aloneYields) := vimFed "z"
        pure
          (yields == [none, none] && decide (state = vimInit) && aloneYields == [none] &&
            decide (alone = vimInit) &&
            (vimFed "g z g g").2 == [none, none, none, some (vimMove "first-line")]) },
    { name :=
        "a key bound in an active keymap and in the Vim state's keymap yields the active keymap's binding"
      run :=
        let active (_ : ViewId) : List (Keymap Vim.Bound) := [vimKeymap [("w", .motion "big-word")]]
        pure
          ((vimFed "w" active).2 == [some (vimMove "big-word")] &&
            (vimFed "w").2 == [some (vimMove "word")]) },
    { name :=
        "a prefix of a binding in an active keymap and of one in the Vim state's keymap goes on to either: the two lists are one walk"
      run :=
        let active (_ : ViewId) : List (Keymap Vim.Bound) := [vimKeymap [("g x", .motion "other")]]
        pure
          ((vimFed "g x" active).2 == [none, some (vimMove "other")] &&
            (vimFed "g g" active).2 == [none, some (vimMove "first-line")] &&
            (vimFed "g x").2 == [none, none]) },
    { name :=
        "the Vim scheme asks for the active keymaps of the view the key is for: another view's are not walked"
      run :=
        let active (view : ViewId) : List (Keymap Vim.Bound) :=
          if view.index == 1 then [vimKeymap [("m", .motion "late")]] else []
        pure
          ((vimFed "m" active ⟨1⟩).2 == [some (vimMove "late")] &&
            (vimFed "m" active ⟨0⟩).2 == [none]) },
    { name :=
        "the Vim scheme takes a key by its chord: a key from a window, with its physical code and repeated, continues and completes a sequence, and is reported pending as its chord"
      run :=
        let typed : Key :=
          { charKey "g" with
            physical := .code "KeyG", repeated := true }
        let fromWindow (typed : List Key) : Vim.State × List (Option Invocation) :=
          (Vim.scheme vimStates).feed vimNoMaps ⟨0⟩ vimInit typed
        let (state, yields) := fromWindow [typed, typed]
        let (begun, _) := fromWindow [typed]
        pure
          (yields == [none, some (vimMove "first-line")] && decide (state = vimInit) &&
            (Vim.scheme vimStates).pending begun == keys "g") },
    { name :=
        "an operator and then a motion yield one invocation on the motion's key: the operator over that motion, with no count"
      run :=
        pure
          ((vimFed "d w").2 == [none, some (vimOperate "delete" "motion" "word")] &&
            (vimFed "d g g").2 == [none, none, some (vimOperate "delete" "motion" "first-line")] &&
            (vimParsed "d w").2 ==
              [.nothing, .edit (.operate vimDelete (.motion "word") none none)]) },
    { name :=
        "an operator typed twice yields that operator over lines, with a count of 1: the doubled operator counts lines"
      run :=
        pure
          ((vimFed "d d").2 == [none, some (vimOperate "delete" "lines" "" 1)] &&
            (vimFed "y y").2 == [none, some (vimOperate "yank" "lines" "" 1)]) },
    { name :=
        "an unbound key after an operator yields no invocation and leaves no operator waiting, no prefix and no pending keys: the state is the initial state"
      run :=
        let (state, yields) := vimFed "d z"
        let (deeper, deeperYields) := vimFed "d g z"
        pure
          (yields == [none, none] && state.operator == none && state.walked == [] &&
            state.typed == [] &&
            decide (state = vimInit) &&
            deeperYields == [none, none, none] &&
            decide (deeper = vimInit) &&
            (vimFed "d z w").2 == [none, none, some (vimMove "word")]) },
    { name :=
        "a different operator after an operator, and a command after an operator, yield nothing and reset the edit"
      run :=
        let (other, otherYields) := vimFed "d c"
        let (command, commandYields) := vimFed "d u"
        pure
          (otherYields == [none, none] && decide (other = vimInit) &&
            commandYields == [none, none] &&
            decide (command = vimInit) &&
            (vimFed "d c w").2 == [none, none, some (vimMove "word")]) },
    { name :=
        "a text object after an operator is the operator's target, and a text object with no operator yields nothing and resets"
      run :=
        let (alone, aloneYields) := vimFed "t"
        pure
          ((vimFed "d t").2 == [none, some (vimOperate "delete" "text-object" "thing")] &&
            aloneYields == [none] &&
            decide (alone = vimInit)) },
    { name :=
        "a motion bound in an active keymap after the scheme was built is the target after each operator, and a move alone, with no further binding"
      run :=
        let scheme := Vim.scheme vimStates
        let late (_ : ViewId) : List (Keymap scheme.Binding) := [vimKeymap [("m", .motion "late")]]
        let typed (text : String) : List (Option Invocation) :=
          (scheme.feed late ⟨0⟩ scheme.init (keys text)).2
        pure
          (typed "d m" == [none, some (vimOperate "delete" "motion" "late")] &&
            typed "c m" == [none, some (vimOperate "change" "motion" "late")] &&
            typed "y m" == [none, some (vimOperate "yank" "motion" "late")] &&
            typed "m" == [some (vimMove "late")] &&
            (scheme.feed vimNoMaps ⟨0⟩ scheme.init (keys "d m")).2 == [none, none]) },
    { name :=
        "the Vim scheme reports an operator waiting, and the prefix walked after it, as pending keys, and none after the edit"
      run :=
        pure
          (vimPending "d" == keys "d" && vimPending "d g" == keys "d g" &&
            vimPending "d g g" == [] &&
            vimPending "d d" == []) },
    { name :=
        "d 2 w yields one invocation, on its last key: operate, delete, over the motion word, with a count of 2"
      run :=
        pure
          ((vimFed "d 2 w").2 ==
              [none, none,
                some
                  { command := "operate"
                    arguments := [.str "delete", .str "motion", .str "word", .nat 2, .str ""] }] &&
            (vimParsed "d 2 w").2.getLast? ==
              some (.edit (.operate vimDelete (.motion "word") (some 2) none))) },
    { name :=
        "2 d 3 w yields the invocation of d 2 w with a count of 6: a count before the operator and one before the motion multiply"
      run :=
        pure
          ((vimFed "2 d 3 w").2 ==
              [none, none, none,
                some
                  { command := "operate"
                    arguments := [.str "delete", .str "motion", .str "word", .nat 6, .str ""] }] &&
            (vimFed "3 d w").2.getLast? == some (some (vimOperate "delete" "motion" "word" 3))) },
    { name :=
        "a count before a doubled operator, and one inside it, count lines: 3 d d is three lines and 2 d 3 d is six"
      run :=
        pure
          ((vimFed "3 d d").2 == [none, none, some (vimOperate "delete" "lines" "" 3)] &&
            (vimFed "2 d 3 d").2 == [none, none, none, some (vimOperate "delete" "lines" "" 6)]) },
    { name :=
        "the digits of a count are read in base ten, and 0 after a digit is a digit: 1 0 w moves by 10"
      run :=
        pure
          ((vimFed "1 0 w").2 == [none, none, some (vimMove "word" 10)] &&
            (vimFed "1 2 3 w").2.getLast? == some (some (vimMove "word" 123))) },
    { name :=
        "0 with no count being typed is looked up like any key, so it yields the motion it is bound to, after an operator too"
      run :=
        pure
          ((vimFed "0").2 == [some (vimMove "line-start")] &&
            (vimFed "d 0").2 == [none, some (vimOperate "delete" "motion" "line-start")]) },
    { name :=
        "a count before a motion of two keys is carried by its move, and a command carries a count"
      run :=
        pure
          ((vimFed "2 g g").2 == [none, none, some (vimMove "first-line" 2)] &&
            (vimFed "3 u").2 ==
              [none, some { command := "undo", arguments := [.nat 3, .str ""] }] &&
            (vimParsed "2 g g").2.getLast? == some (.edit (.move "first-line" (some 2)))) },
    { name :=
        "a digit after a keymap prefix is looked up as a key of the sequence, not read as a count"
      run :=
        let active (_ : ViewId) : List (Keymap Vim.Bound) := [vimKeymap [("g 2", .motion "second")]]
        pure
          ((vimFed "g 2" active).2 == [none, some (vimMove "second")] &&
            (vimFed "3 g 2" active).2 == [none, none, some (vimMove "second" 3)]) },
    { name :=
        "a digit with control held is not a count: unbound, it resets the count typed before it"
      run := pure ((vimFed "2 C-3 w").2 == [none, none, some (vimMove "word")]) },
    { name :=
        "the count of the edit begun is the product of the counts typed so far, and none when no digit was typed"
      run :=
        pure
          ((vimFed "d").1.count == none && (vimFed "2").1.count == some 2 &&
            (vimFed "2 d").1.count == some 2 &&
            (vimFed "2 d 3").1.count == some 6 &&
            (vimFed "d 1 2").1.count == some 12) },
    { name :=
        "an unbound key after an operator and a count yields no invocation and leaves no count, no operator and no prefix: the state is the initial state"
      run :=
        let (state, yields) := vimFed "d 2 z"
        let (before, beforeYields) := vimFed "2 d z"
        pure
          (yields == [none, none, none] && state.count == none && state.operator == none &&
            state.walked == [] &&
            state.typed == [] &&
            decide (state = vimInit) &&
            beforeYields == [none, none, none] &&
            decide (before = vimInit) &&
            (vimFed "2 z w").2 == [none, none, some (vimMove "word")]) },
    { name :=
        "the Vim scheme reports the digits of a count among the pending keys, in the order typed"
      run :=
        pure
          (vimPending "d 2" == keys "d 2" && vimPending "2 d 3" == keys "2 d 3" &&
            vimPending "1 0" == keys "1 0" &&
            vimPending "2 d 3 w" == []) },
    { name :=
        "a register named before an operator is carried by its edit: the key after the register prefix names it by the text it prints"
      run :=
        pure
          ((vimFed "\" + y w").2 ==
              [none, none, none, some (vimOperate "yank" "motion" "word" 0 "+")] &&
            (vimParsed "\" + y w").2.getLast? ==
              some (.edit (.operate vimYank (.motion "word") none (some "+"))) &&
            (vimFed "\" A d d").2.getLast? == some (some (vimOperate "delete" "lines" "" 1 "A"))) },
    { name :=
        "a register named before a command is carried by its edit, and a digit after the register prefix names a register"
      run :=
        pure
          ((vimFed "\" a x").2 ==
              [none, none, some { command := "delete-char", arguments := [.nat 0, .str "a"] }] &&
            (vimFed "\" 2 x").2 ==
              [none, none, some { command := "delete-char", arguments := [.nat 0, .str "2"] }]) },
    { name :=
        "a move carries no register: one named before a motion is dropped when the motion completes"
      run :=
        let (state, yields) := vimFed "\" a w"
        pure
          (yields == [none, none, some (vimMove "word")] && decide (state = vimInit) &&
            (vimFed "\" a w x").2.getLast? ==
              some (some { command := "delete-char", arguments := [.nat 0, .str ""] })) },
    { name :=
        "counts before the register prefix and after the register multiply: 2 \" a 3 d d is six lines into a"
      run :=
        pure
          ((vimFed "2 \" a 3 d d").2 ==
            [none, none, none, none, none, some (vimOperate "delete" "lines" "" 6 "a")]) },
    { name :=
        "a key that prints nothing after the register prefix yields nothing and resets the edit"
      run :=
        let (state, yields) := vimFed "2 \" <Escape>"
        pure
          (yields == [none, none, none] && decide (state = vimInit) &&
            (vimFed "\" C-a w").2 == [none, none, some (vimMove "word")]) },
    { name :=
        "the register prefix after an operator, and after a register is already named, yields nothing and resets the edit"
      run :=
        let (afterOperator, operatorYields) := vimFed "d \""
        let (twice, twiceYields) := vimFed "\" a \""
        pure
          (operatorYields == [none, none] && decide (afterOperator = vimInit) &&
            twiceYields == [none, none, none] &&
            decide (twice = vimInit) &&
            (vimFed "d \" w").2 == [none, none, some (vimMove "word")]) },
    { name :=
        "the Vim scheme reports the register prefix and the key that names the register among the pending keys"
      run :=
        pure
          (vimPending "\"" == keys "\"" && vimPending "\" a" == keys "\" a" &&
            vimPending "\" a d" == keys "\" a d" &&
            vimPending "\" a d d" == []) },
    { name :=
        "an operator bound to two keys waits with no prefix left: the motion typed next, of one key or of two, is its target"
      run :=
        pure
          ((vimFed "g u w" vimTwoKeyMaps).2 ==
              [none, none, some (vimOperate "lowercase" "motion" "word")] &&
            (vimFed "g u g g" vimTwoKeyMaps).2 ==
              [none, none, none, some (vimOperate "lowercase" "motion" "first-line")] &&
            (vimParsed "g u w" vimTwoKeyMaps).2.getLast? ==
              some (.edit (.operate { name := "lowercase" } (.motion "word") none none))) },
    { name :=
        "a digit after an operator bound to two keys is read as a count, and multiplies with one typed before the operator"
      run :=
        pure
          ((vimFed "g u 2 w" vimTwoKeyMaps).2 ==
              [none, none, none, some (vimOperate "lowercase" "motion" "word" 2)] &&
            (vimFed "3 g u 2 w" vimTwoKeyMaps).2.getLast? ==
              some (some (vimOperate "lowercase" "motion" "word" 6))) },
    { name :=
        "an operator bound to two keys, typed twice, yields that operator over lines, and a different operator after it resets"
      run :=
        let (other, otherYields) := vimFed "g u d" vimTwoKeyMaps
        pure
          ((vimFed "g u g u" vimTwoKeyMaps).2 ==
              [none, none, none, some (vimOperate "lowercase" "lines" "" 1)] &&
            (vimFed "g u 3 g u" vimTwoKeyMaps).2.getLast? ==
              some (some (vimOperate "lowercase" "lines" "" 3)) &&
            otherYields == [none, none, none] &&
            decide (other = vimInit)) },
    { name :=
        "the Vim scheme reports both keys of an operator bound to two keys as pending, with the keys typed after it, and none after the edit"
      run :=
        pure
          (vimPending "g u" vimTwoKeyMaps == keys "g u" &&
            vimPending "g u g" vimTwoKeyMaps == keys "g u g" &&
            vimPending "g u 2" vimTwoKeyMaps == keys "g u 2" &&
            vimPending "g u w" vimTwoKeyMaps == [] &&
            vimPending "g u g u" vimTwoKeyMaps == []) },
    { name :=
        "a register prefix bound to two keys leaves no prefix: the key after it names the register, and the keys after that are looked up from the start"
      run :=
        let (twice, twiceYields) := vimFed "g r a g r" vimTwoKeyMaps
        pure
          ((vimFed "g r a y w" vimTwoKeyMaps).2 ==
              [none, none, none, none, some (vimOperate "yank" "motion" "word" 0 "a")] &&
            (vimFed "g r a g u g u" vimTwoKeyMaps).2.getLast? ==
              some (some (vimOperate "lowercase" "lines" "" 1 "a")) &&
            (vimFed "g r 2 x" vimTwoKeyMaps).2 ==
              [none, none, none,
                some { command := "delete-char", arguments := [.nat 0, .str "2"] }] &&
            (vimFed "2 g r a 3 d d" vimTwoKeyMaps).2.getLast? ==
              some (some (vimOperate "delete" "lines" "" 6 "a")) &&
            twiceYields == [none, none, none, none, none] &&
            decide (twice = vimInit)) },
    { name :=
        "the Vim scheme reports both keys of a register prefix bound to two keys as pending, with the key that names the register"
      run :=
        pure
          (vimPending "g r" vimTwoKeyMaps == keys "g r" &&
            vimPending "g r a" vimTwoKeyMaps == keys "g r a" &&
            vimPending "g r a d" vimTwoKeyMaps == keys "g r a d" &&
            vimPending "g r a d d" vimTwoKeyMaps == []) }]

/-- `vimStates` with a state the checks register, `test`, whose keymap
binds `m` to a motion and whose cursor is an underline, and with `q` bound
in the normal state's keymaps to a command that enters it. -/
def vimWithTest : Vim.States :=
  let registered :=
    vimStates.register
      { name := "test", keymaps := [vimKeymap [("m", .motion "test-motion")]],
        cursor := .underline }
  registered.register
    { registered.initial with
      keymaps :=
        vimKeymap [("q", .command { name := "enter-test", enters := some "test" })] ::
          registered.initial.keymaps }

/-- The invocation the command `name` compiles to when a key bound to it is
typed with no count and no register. -/
def vimRun (name : String) : Invocation :=
  { command := name, arguments := [.nat 0, .str ""] }

/-- The checks of the Vim scheme's states (`Editor/InputScheme/Vim.lean`):
which Vim state a view is in, how one is entered, and what the grammar
reads of a state's record. -/
def vimStateChecks : List Check :=
  [{  name :=
        "a state a check registers, entered by a key bound in the normal state's keymap, is the view's state, and the next key is looked up in its keymap"
      run :=
        let (state, yields) := vimFed "q m" (states := vimWithTest)
        pure
          ((vimFed "m" (states := vimWithTest)).2 == [none] &&
            vimInit.stateOf vimWithTest ⟨0⟩ == "normal" &&
            yields == [some (vimRun "enter-test"), some (vimMove "test-motion")] &&
            state.stateOf vimWithTest ⟨0⟩ == "test" &&
            (state.record vimWithTest ⟨0⟩).cursor == .underline &&
            (vimFed "q w" (states := vimWithTest)).2 == [some (vimRun "enter-test"), none]) },
    { name :=
        "an operator and a command that name a state leave the view in it, and ones that name none leave it where it was"
      run :=
        pure
          ((vimFed "c w").1.stateOf vimStates ⟨0⟩ == "insert" &&
            (vimFed "i").1.stateOf vimStates ⟨0⟩ == "insert" &&
            (vimFed "d w").1.stateOf vimStates ⟨0⟩ == "normal" &&
            (vimFed "u").1.stateOf vimStates ⟨0⟩ == "normal" &&
            (vimFed "v w").1.stateOf vimStates ⟨0⟩ == "visual") },
    { name :=
        "a Vim state is one view's: after a key for one view entered a state, another view is in the initial state and its keys are looked up there"
      run :=
        let (state, _) := vimFed "q" (states := vimWithTest)
        let typed (text : String) (view : ViewId) : List (Option Invocation) :=
          (vimFedFrom state text (view := view) (states := vimWithTest)).2
        pure
          (state.stateOf vimWithTest ⟨0⟩ == "test" && state.stateOf vimWithTest ⟨1⟩ == "normal" &&
            typed "m" ⟨0⟩ == [some (vimMove "test-motion")] &&
            typed "m" ⟨1⟩ == [none] &&
            typed "w" ⟨1⟩ == [some (vimMove "word")] &&
            typed "w" ⟨0⟩ == [none]) },
    { name :=
        "a view not in the initial state has one entry in the scheme's state, and entering the initial state removes it: the state is then the initial state"
      run :=
        let (both, _) := vimFedFrom (vimFed "i").1 "v" (view := ⟨1⟩)
        pure
          ((vimFed "i").1.current == [(⟨0⟩, "insert")] && (vimFed "i <Escape>").1.current == [] &&
            decide ((vimFed "v <Escape>").1 = vimInit) &&
            (vimFed "v i").1.current == [(⟨0⟩, "insert")] &&
            both.current == [(⟨0⟩, "insert"), (⟨1⟩, "visual")] &&
            (vimFedFrom both "<Escape>").1.current == [(⟨1⟩, "visual")]) },
    { name :=
        "a state's name that the registry does not have is read as the initial state, and a command that enters such a name enters the initial state"
      run :=
        let stale : Vim.State := { current := [(⟨0⟩, "gone")] }
        let nowhere (_ : ViewId) : List (Keymap Vim.Bound) :=
          [vimKeymap [("n", .command { name := "leave", enters := some "nowhere" })]]
        pure
          (stale.stateOf vimStates ⟨0⟩ == "normal" &&
            (vimFedFrom stale "w").2 == [some (vimMove "word")] &&
            (vimFed "i n" nowhere).1.current == [] &&
            decide ((vimFed "n" nowhere).1 = vimInit)) },
    { name :=
        "an edit begun by a key for one view is completed by a key for another, looked up in the keymaps of that view's state, and the state it enters is that view's"
      run :=
        let (entered, _) := vimFed "q" (view := ⟨1⟩) (states := vimWithTest)
        let (begun, _) := vimFedFrom entered "2 c" (view := ⟨0⟩) (states := vimWithTest)
        let (state, yields) := vimFedFrom begun "m" (view := ⟨1⟩) (states := vimWithTest)
        pure
          (yields == [some (vimOperate "change" "motion" "test-motion" 2)] &&
            state.current == [(⟨1⟩, "insert")] &&
            (vimFedFrom begun "m" (view := ⟨0⟩) (states := vimWithTest)).2 == [none]) },
    { name :=
        "an unbound key resets the edit begun and keeps which state each view is in: the state is the one the view was left in when it entered"
      run :=
        let (entered, _) := vimFed "v"
        let (state, yields) := vimFedFrom entered "2 g z"
        pure
          (yields == [none, none, none] && state.current == [(⟨0⟩, "visual")] &&
            decide (state = entered)) },
    { name :=
        "in a state that inserts text an unbound printable key yields a self-insert of the text it prints: a letter, the space, and a shifted letter from a window"
      run :=
        let (inserting, _) := vimFed "i"
        let shifted : Key :=
          { logical := .character "A", physical := .code "KeyA", modifiers := { shift := true } }
        let fromWindow : Vim.State × List (Option Invocation) :=
          (Vim.scheme vimStates).feed vimNoMaps ⟨0⟩ inserting [shifted]
        pure
          (Vim.selfInsert "a" == { command := "self-insert", arguments := [.str "a"] } &&
            (vimFedFrom inserting "a").2 == [some (Vim.selfInsert "a")] &&
            (vimFedFrom inserting "SPC w").2 ==
              [some (Vim.selfInsert " "), some (Vim.selfInsert "w")] &&
            fromWindow.2 == [some (Vim.selfInsert "A")]) },
    { name := "in a state that does not insert text an unbound printable key yields nothing"
      run :=
        pure
          ((vimFed "a").2 == [none] && (vimFed "v a").2.getLast? == some none &&
            (vimFed "i <Escape> a").2.getLast? == some none) },
    { name :=
        "in a state that inserts text a digit is text and not a count, 0 among them, and the key typed next carries no count"
      run :=
        let (inserting, _) := vimFed "i"
        let (state, yields) := vimFedFrom inserting "2 0"
        pure
          (yields == [some (Vim.selfInsert "2"), some (Vim.selfInsert "0")] &&
            state.count == none &&
            (vimFedFrom inserting "2 <Escape> w").2.getLast? == some (some (vimMove "word"))) },
    { name :=
        "in a state that inserts text an unbound key that prints nothing yields nothing and leaves the view in the state: a named key, and a character with control held"
      run :=
        let (inserting, _) := vimFed "i"
        let (state, yields) := vimFedFrom inserting "<Enter> C-z"
        pure (yields == [none, none] && decide (state = inserting)) },
    { name :=
        "in a state that inserts text an unbound key after a pending prefix is dropped with the prefix: neither is text"
      run :=
        let (inserting, _) := vimFed "i"
        let active (_ : ViewId) : List (Keymap Vim.Bound) :=
          [vimKeymap [("j k", .command { name := "normal", enters := some "normal" })]]
        let (state, yields) := vimFedFrom inserting "j z" active
        pure
          (yields == [none, none] && decide (state = inserting) &&
            (vimFedFrom inserting "j" active).1.typed == keys "j" &&
            (vimFedFrom inserting "j k" active).1.current == []) },
    { name := "a self-insert leaves the scheme's state as it was, with nothing pending"
      run :=
        let (inserting, _) := vimFed "i"
        let (state, _) := vimFedFrom inserting "a b"
        pure (decide (state = inserting) && state.typed == []) },
    { name :=
        "in a state where operators act on the selection an operator yields its edit over the selection at once, waiting for no motion, and the view is then in the initial state"
      run :=
        let (state, yields) := vimFed "v d"
        pure
          (yields == [some (vimRun "visual"), some (vimOperate "delete" "selection" "")] &&
            (vimParsed "v d").2.getLast? ==
              some (.edit (.operate vimDelete .selection none none)) &&
            decide ({ state with lastChange := none } = vimInit) &&
            (vimFed "v d w").2.getLast? == some (some (vimMove "word"))) },
    { name :=
        "an operator over the selection that names a state leaves the view in that state, and one that names none in the initial state"
      run :=
        pure
          ((vimFed "v c").1.current == [(⟨0⟩, "insert")] &&
            (vimFed "v c").2.getLast? == some (some (vimOperate "change" "selection" "")) &&
            (vimFed "v y").1.current == [] &&
            (vimFed "v y").2.getLast? == some (some (vimOperate "yank" "selection" ""))) },
    { name :=
        "a count and a register typed before an operator over the selection are carried by its edit"
      run :=
        pure
          ((vimFed "v 2 \" a d").2 ==
            [some (vimRun "visual"), none, none, none,
              some (vimOperate "delete" "selection" "" 2 "a")]) },
    { name :=
        "in a state where operators act on the selection a motion is still a move, and the view stays in the state"
      run :=
        let (state, yields) := vimFed "v 2 w"
        pure
          (yields == [some (vimRun "visual"), none, some (vimMove "word" 2)] &&
            state.current == [(⟨0⟩, "visual")]) },
    { name :=
        "after d 2 w the scheme's last change is the edit d 2 w parsed to, and a move typed after it leaves the last change as it was"
      run :=
        let (state, parsed) := vimParsed "d 2 w"
        let (moved, _) := vimParsedFrom state "w 3 g g"
        pure
          (parsed.getLast? == some (.edit (.operate vimDelete (.motion "word") (some 2) none)) &&
            state.lastChange.map Vim.Parsed.edit == parsed.getLast? &&
            moved.lastChange == state.lastChange &&
            vimInit.lastChange == none &&
            (vimParsed "w").1.lastChange == none) },
    { name :=
        "an edit with an operator that changes no text does not replace the last change, and one with an operator that changes text does"
      run :=
        let (state, _) := vimParsed "d 2 w"
        pure
          ((vimParsedFrom state "y w").1.lastChange == state.lastChange &&
            (vimParsed "y w").1.lastChange == none &&
            (vimParsedFrom state "\" a c c").1.lastChange ==
              some (.operate vimChange .lines (some 1) (some "a"))) },
    { name :=
        "a command that changes text replaces the last change, with its count and register, and one that does not leaves it"
      run :=
        let (state, _) := vimParsed "d 2 w"
        pure
          ((vimParsedFrom state "3 \" a x").1.lastChange ==
              some (.run { name := "delete-char", changes := true } (some 3) (some "a")) &&
            (vimParsedFrom state "u").1.lastChange == state.lastChange &&
            (vimParsed "i").1.lastChange == some (.run vimInsert none none)) },
    { name := "an unbound key, a reset edit and entering a state keep the last change"
      run :=
        let (state, _) := vimParsed "d 2 w"
        pure
          (state.lastChange.isSome && (vimParsedFrom state "z").1.lastChange == state.lastChange &&
            (vimParsedFrom state "2 d z").1.lastChange == state.lastChange &&
            (vimParsedFrom state "d u").1.lastChange == state.lastChange &&
            (vimParsedFrom state "v").1.lastChange == state.lastChange &&
            (vimParsedFrom state "v <Escape>").1.lastChange == state.lastChange) },
    { name :=
        "an operator over the selection is the last change when it changes text, and is not when it changes none"
      run :=
        let (state, _) := vimParsed "d 2 w"
        pure
          ((vimParsedFrom state "v d").1.lastChange ==
              some (.operate vimDelete .selection none none) &&
            (vimParsedFrom state "v y").1.lastChange == state.lastChange) },
    { name := "typed text does not replace the last change"
      run :=
        let (inserting, _) := vimParsed "i"
        pure ((vimParsedFrom inserting "a b").1.lastChange == inserting.lastChange) }]

/-- The default Vim scheme's grammar folded from its initial state through
the keys the key string `text` names, keys for view 0 with no active
keymaps: the state it is left in, and what each key parsed to. -/
def vimDefault (text : String) : Vim.State × List Vim.Parsed :=
  vimParsed text (states := Vim.Default.states)

/-- The edit the last key of `text` completed under the default Vim
scheme, if it completed one. -/
def vimDefaultEdit (text : String) : Option Vim.Edit :=
  match (vimDefault text).2.getLast? with
  | some (.edit edit) => some edit
  | _ => none

/-- The command the last key of `text` runs under the default Vim scheme,
with no count and no register, if it runs one. -/
def vimDefaultCommand (text : String) : Option Vim.Command :=
  match vimDefaultEdit text with
  | some (.run command none none) => some command
  | _ => none

/-- The record of the default Vim state view 0 is in after the keys `text`
names. -/
def vimDefaultRecord (text : String) : Vim.StateRecord :=
  (vimDefault text).1.record Vim.Default.states ⟨0⟩

/-- Whether each of `texts` runs a command under the default Vim scheme,
each a command of another name. -/
def vimDefaultCommands (texts : List String) : Bool :=
  let names := (texts.filterMap vimDefaultCommand).map (·.name)
  names.length == texts.length && names.eraseDups.length == texts.length

/-- The subject the scheme contract is run on for the Vim scheme that
ships: the default scheme, with no active keymaps, for view 0. -/
def vimDefaultSubject : SchemeContract.Subject :=
  { scheme := Vim.Default.scheme
    maps := vimNoMaps
    view := ⟨0⟩
    sequences := ["d 2 w", "2 d 3 w", "d d", "g g", "\" + y w", "i"].map keys
    unbound := vimUnbound }

/-- The checks of the Vim scheme's default states and bindings
(`Editor/InputScheme/Vim/Default.lean`). They observe the defaults through
the grammar, by what the default keys parse to, and restate no table: a
check names a key, and no vocabulary or command name. -/
def vimDefaultChecks : List Check :=
  [{  name := "every row of each default table binds its keys, and no table is empty"
      run :=
        pure <|
          [Vim.Default.motions, Vim.Default.operators, Vim.Default.normalCommands,
                Vim.Default.insertCommands, Vim.Default.visualCommands,
                Vim.Default.visualLineCommands].all
            fun table =>
            !table.isEmpty && (Vim.Default.keymap table).bindings.length == table.length },
    { name :=
        "each default motion key yields a move with no count, each by a motion of another name: h j k l w b e W B E 0 ^ $ gg G"
      run :=
        let motionKeys :=
          ["h", "j", "k", "l", "w", "b", "e", "W", "B", "E", "0", "^", "$", "g g", "G"]
        let names :=
          motionKeys.filterMap fun text =>
            match vimDefaultEdit text with
            | some (.move name none) => some name
            | _ => none
        pure (names.length == motionKeys.length && names.eraseDups.length == motionKeys.length) },
    { name :=
        "each default operator key followed by a motion operates over that motion, and typed twice over one line, each an operator of another name: d c y"
      run :=
        let operatorKeys := ["d", "c", "y"]
        let operators :=
          operatorKeys.filterMap fun text =>
            match vimDefaultEdit s!"{text} w", vimDefaultEdit s!"{text} {text}",
              vimDefaultEdit "w" with
            | some (.operate operator (.motion target) none none),
              some (.operate doubled .lines (some 1) none), some (.move motion none) =>
              if operator == doubled && target == motion then some operator.name else none
            | _, _, _ => none
        pure
          (operators.length == operatorKeys.length &&
            operators.eraseDups.length == operatorKeys.length) },
    { name :=
        "of the default operators c leaves the view in a state where typing is text and d and y leave it where it was, and d and c change text and y does not"
      run :=
        pure
          ((vimDefaultRecord "c w").insertsText && (vimDefault "d w").1.current == [] &&
            (vimDefault "y w").1.current == [] &&
            (vimDefault "d w").1.lastChange == vimDefaultEdit "d w" &&
            (vimDefault "c w").1.lastChange == vimDefaultEdit "c w" &&
            (vimDefault "d w").1.lastChange.isSome &&
            (vimDefault "y w").1.lastChange == none) },
    { name :=
        "each of the default keys i a I A o O runs a command of its own that changes text and leaves the view in a state where typing is text"
      run :=
        let insertKeys := ["i", "a", "I", "A", "o", "O"]
        pure
          (vimDefaultCommands insertKeys &&
            insertKeys.all fun text =>
              (vimDefaultRecord text).insertsText && (vimDefault text).1.lastChange.isSome &&
                (vimDefault text).1.lastChange == vimDefaultEdit text) },
    { name :=
        "each of the default keys x p P runs a command of its own that changes text and enters no state"
      run :=
        let changeKeys := ["x", "p", "P"]
        pure
          (vimDefaultCommands changeKeys &&
            changeKeys.all fun text =>
              (vimDefault text).1.current == [] && (vimDefault text).1.lastChange.isSome) },
    { name :=
        "each of the default keys u C-r . : runs a command of its own that changes no text and enters no state"
      run :=
        let plainKeys := ["u", "C-r", ".", ":"]
        pure
          (vimDefaultCommands plainKeys &&
            plainKeys.all fun text =>
              (vimDefault text).1.current == [] && (vimDefault text).1.lastChange == none) },
    { name :=
        "the default keys v and V enter two different states where operators act on the selection, change no text, and each key typed again, and the other, goes where it should: back to the initial state, or to the other visual state"
      run :=
        pure
          ((vimDefaultRecord "v").operatesOnSelection &&
            (vimDefaultRecord "V").operatesOnSelection &&
            (vimDefaultRecord "v").name != (vimDefaultRecord "V").name &&
            (vimDefault "v").1.lastChange == none &&
            (vimDefault "V").1.lastChange == none &&
            (vimDefault "v v").1.current == [] &&
            (vimDefault "V V").1.current == [] &&
            (vimDefault "v V").1.current == (vimDefault "V").1.current &&
            (vimDefault "V v").1.current == (vimDefault "v").1.current) },
    { name :=
        "the default <Escape> returns to the initial state from each state another default key enters: from the state i enters, and from the two v and V enter"
      run :=
        pure
          (["i", "v", "V"].all fun text =>
            !(vimDefault text).1.current.isEmpty &&
              (vimDefault s!"{text} <Escape>").1.current == []) },
    { name :=
        "in the default visual states an operator key operates over the selection at once and a motion key is a move"
      run :=
        pure
          (["v", "V"].all fun text =>
            (match vimDefaultEdit s!"{text} d" with
              | some (.operate _ .selection none none) => true
              | _ => false) &&
              (vimDefault s!"{text} d").1.current == [] &&
              vimDefaultEdit s!"{text} w" == vimDefaultEdit "w" &&
              (vimDefaultEdit "w").isSome) },
    { name :=
        "the default register prefix names a register for an operator in normal state and in each visual state"
      run :=
        let register (text : String) : Option String :=
          match vimDefaultEdit text with
          | some (.operate _ _ _ register) => register
          | _ => none
        pure
          (register "\" + y w" == some "+" && register "v \" a d" == some "a" &&
            register "V \" a d" == some "a" &&
            register "y w" == none) },
    { name :=
        "in the default state that i enters a key bound to a motion in the initial state is typed text, and after <Escape> it is that motion again"
      run :=
        pure
          ((vimDefault "i h").2.getLast? == some (.text "h") &&
            (vimDefault "i 0").2.getLast? == some (.text "0") &&
            vimDefaultEdit "i <Escape> h" == vimDefaultEdit "h" &&
            (vimDefaultEdit "h").isSome) },
    { name :=
        "the cursor of the default initial state is a block, and that of the state i enters a bar"
      run :=
        pure
          ((vimDefaultRecord "").cursor == .block && Vim.Default.states.initial.cursor == .block &&
            (vimDefaultRecord "i").cursor == .bar &&
            (vimDefaultRecord "i").name != (vimDefaultRecord "").name) }]

/-- The checks that the Vim scheme keeps the scheme contract
(`Editor/InputScheme/Contract.lean`). -/
def vimContractChecks : List Check :=
  [{  name := "the scheme contract holds of the Vim scheme over the registry written for the checks"
      run := pure (SchemeContract.failures vimSubject == []) },
    { name := "the scheme contract holds of the Vim scheme that ships, over its default states"
      run := pure (SchemeContract.failures vimDefaultSubject == []) },
    { name :=
        "a key that prints is not unbound after the register prefix, where it names the register: given one as its unbound key, the scheme contract reports that it does not reset"
      run :=
        pure
          (failsOnly { vimSubject with unbound := charKey "z" } [SchemeContract.unboundResets]) }]

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
    displayChecks ++
    commandPortChecks ++
    originChecks ++
    stateChecks ++
    loopChecks ++
    commitChecks ++
    keymapChecks ++
    keyNotationChecks ++
    invocationChecks ++
    schemeChecks ++
    schemeContractChecks ++
    vimEditChecks ++
    vimRegistryChecks ++
    vimGrammarChecks ++
    vimStateChecks ++
    vimDefaultChecks ++
    vimContractChecks

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

/-- The cell sizes the display interface's contract is run at against the
model: one pixel each way, and 8 by 16. -/
def displayCells : List Display.Cells :=
  [{ advance := 1, lineHeight := 1 }, { advance := 8, lineHeight := 16 }]

/-- Runs a property of the display interface's contract against a display
model in `cells` that holds the property's texts, as the snapshots 0, 1, 2
and so on. -/
def runOnDisplayModel (cells : Display.Cells) (property : DisplayContract.Property) :
    IO (Except DisplayError Bool) :=
  let model := displayOver property.texts.toList cells
  pure ((property.holds (model.texts.map (·.1))).runModel model).1

/-- The names of the display interface's contract properties that do not
hold of the display model, at each of `displayCells`. -/
def displayFailures : IO (List String) := do
  let failed ←
    displayCells.flatMapM fun cells => do
        let failed ←
          DisplayContract.failures (runOnDisplayModel cells) (DisplayContract.properties cells)
        return failed.map
            (s!"the display model in cells of {cells.advance} by {cells.lineHeight}: {·}")
  return failed

end ModelTest

/-- Runs the checks, then the text port's contract against its model, the
job port's contract against its model and against the runner over the fake
clock, and the display interface's contract against its model: exits 0 when
all hold, and 1 after naming on stderr the ones that do not.

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
      (← ModelTest.caseFailures) ++
      (← ModelTest.displayFailures)
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  unless failed.isEmpty do
    -- A check that failed may have left a task that never ends, and
    -- returning from `main` would wait for it for ever.
    IO.Process.exit 1
  IO.println
      s!"model-test: {ModelTest.checks.length} checks passed, {Editor.TextContract.properties.length + Editor.TextContract.adoptProperties.length + ModelTest.commandProperties.length} properties hold of the text model, {Editor.UndoTreeCases.cases.length} cases of the undo tree hold over it, and {Editor.JobContract.properties.length} properties of the job model and of the job runner over the fake clock, and {Editor.JobContract.fileProperties.length} file properties of the job model and of the job runner over the fake file service; {Editor.FileCases.cases.length} cases across the text port and the job port hold of the two models; {(Editor.DisplayContract.properties { advance := 1, lineHeight := 1 }).length} properties of the display interface hold of its model in cells of {ModelTest.displayCells.length} sizes"
  (← IO.getStdout).flush
  IO.Process.exit 0
