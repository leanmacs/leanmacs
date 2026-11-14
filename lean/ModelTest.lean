import Editor.Api.Cases
import Editor.Clipboard.Contract
import Editor.Clipboard.Model
import Editor.Command.Append
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Config.Reload
import Editor.Display.Contract
import Editor.Display.Model
import Editor.Evil.Compiled
import Editor.Ex.Compiled
import Editor.Ex.Line
import Editor.File.Cases
import Editor.File.Model
import Editor.Files.Compiled
import Editor.InputScheme.Contract
import Editor.InputScheme.Test
import Editor.InputScheme.Vim.Default
import Editor.Job.Contract
import Editor.Job.Fake
import Editor.Job.Jobs
import Editor.Job.Model
import Editor.Job.Pool
import Editor.Key.Notation
import Editor.Loop.Driver
import Editor.Minibuffer.Compiled
import Editor.Mode
import Editor.Role
import Editor.Scene
import Editor.State
import Editor.State.Request
import Editor.Text.Contract
import Editor.UndoTree.Cases
import Editor.Watch.Contract
import Editor.Watch.Model
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
(`Editor/Command.lean`), run here against the text model, the display model
and the watch model side by side (`EditorModel`). `commandPortChecks` pin
what that runner does with each sub-port's requests: a text program lifted
into a command does what it does alone, the display answers from the text
model's snapshots, a display refusal is the text port's of the same name,
and a watch request goes to the watch model.

The watch port's contract (`Editor/Watch/Contract.lean`: the interrupt flag
and a clock) is run against its model here (`watchFailures`), and
`contract-test` runs the same list against the real binding. `watchChecks`
are what only the model shows: an interrupt key that arrives at a request a
test names, and a clock that moves with a command's requests. `guardChecks`
run commands on those models as the loop runs one
(`Editor/Command/Dispatch.lean`, "The guard"): a command stops at its next
request once the flag is up, and cannot catch it.

The clipboard interface's contract (`Editor/Clipboard/Contract.lean`) is
run against its model here (`clipboardFailures`). `clipboardChecks` are
what only the model shows: a clipboard that is not available refuses and
keeps what it held, and one that holds nothing answers no text. They also
show the contract biting: a clipboard written here that drops every write
is reported.

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

What a key does in the loop is checked the same way (`dispatchChecks`), on
the editor's models and the test scheme, with keymaps and commands written
in the test, so that none of them names a shipped scheme's keys or a
registered command:

- `dispatchKeyChecks`: which keys are stepped through the scheme, the
  pending keys the scene shows, and the command a completed sequence runs,
  with its arguments and its keys;
- `dispatchRollbackChecks`: a command that fails leaves the texts, the
  windows' markers, the history and the scheme's state as they were, what
  cannot be rolled back is said, a move in the history is not taken back,
  and a mark of the saved state is;
- `dispatchInterruptChecks`: on the watch model, an interrupt key that
  arrives while a command runs, before one and between two;
- `dispatchSlowChecks`: on the watch model's clock, which a command's
  requests move, a command slower than the threshold is logged once;
- `dispatchGiveUpChecks`: what the loop gives up once a command has run to
  its end, and not before: a closed window's markers, a removed buffer's
  text, the snapshot of a save that is no longer in flight, and the
  minibuffer of a prompt that was accepted or cancelled;
- `dispatchMinibufferNoticeChecks`: the loop tells its scheme when a
  command that ran to its end opened the minibuffer's view, in both states
  of the scheme it keeps, after the views the command closed, and tells it
  nothing after a later command, a key's or a job's, that ran with the
  prompt open;
- `dispatchUndoChecks`: undo from a command, and that what is edited while
  a view is in an insert session is one step of the history;
- `dispatchReportChecks`: a command is called with what the scheme reports
  of its view, in the scheme's state after its key;
- `dispatchCommandGivesUpChecks`: a command that gives up (`giveUp`,
  `Editor/Api.lean`) is rolled back, its reason is in the echo area with
  no `refused:`, and the scheme is back at rest. It is another thing than
  `dispatchGiveUpChecks`, which is what the loop gives up after a command;
- `dispatchCommandBreaksOffChecks`: a command that breaks off (`breakOff`,
  `Editor/Api.lean`) keeps what it did, its reason is in the echo area with
  no `refused:`, and the scheme is back at rest;
- `dispatchRunCommandChecks`: a command that has another run inside it
  (`runCommand`, `Editor/Api.lean`) runs the one a key's invocation of the
  name runs, as part of itself.

What the loop does with a scheme's report of a view is checked with a
scheme written here, `switching`: the test scheme, with a report of each
view that an invocation it yields switches. So the checks of the scene's
cursor and status field (`loopChecks`), of the report a command is told,
of insert sessions and of where a committed text is inserted
(`commitChecks`) name no Vim state and no Vim key.

Jobs started from commands are checked on the loop's driver over the
editor's models and the job model (`Editor/Loop/Driver.lean`):

- `driverChecks`: a command starts a job by its name, the job's result
  comes back as a command, events fed meanwhile are handled first, a job
  reads a snapshot its command took, and a job's command is handed what its
  own job loaded;
- `promptChecks`: prompts on that driver. `promptLoopChecks`, with commands
  written here under keys of the global keymap: an accepted prompt's
  answer is handed back with the step, and the answer's command runs
  before the next event, with the asking view as its target; a
  continuation with no command, one that is refused and one that asks
  again; and rollback and the interrupt around an open prompt.
  `promptModeChecks`, with the minibuffer's commands and its mode
  (`Editor/Minibuffer/Compiled.lean`) in a registry whose active keymaps
  the loop is handed: the phase's acceptance criteria, with the accept key
  and the cancel key read from the test scheme's role table;
- `fileCommandChecks`: the file commands (`Editor/Files.lean`) on that
  driver, over the model of files (`Editor/File/Model.lean`), with keys
  bound to the commands and jobs registered as the test says: opening a
  file into a buffer, a path that is open, a file that is not there, what
  is typed while a load is in flight, and a file that would be shown in
  the minibuffer's view; saving a buffer, a file that
  changed on disk, a save that reports late, a forced save, and what each
  command says when it starts nothing; and the commands and jobs as
  compiled code registers them (`Editor/Files/Compiled.lean`). They touch
  no file;
- `dispatchQuitChecks`: quitting in the loop (`Editor/Loop.lean`, "Quit")
  on that driver and the model of files, with commands written here that
  ask the editor to quit: the step says stop once the editor can leave,
  after its scene; a quit waits for a save in flight and stops at the
  delivery of its result; and a quit that cannot go ahead is withdrawn,
  when the save is refused and when the buffer is edited meanwhile. They
  name no ex name. They are apart from `dispatchChecks`, which are
  defined before the driver;
- `exChecks`: the ex command line (`Editor/Ex.lean`) on that driver, with
  the commands compiled code registers for it, for the minibuffer and for
  files, keys of the test scheme bound to the ex command and to the accept
  and cancel commands, and ex bindings written here: the ex command opens
  a prompt, and the accepted line runs the command its name is bound to,
  as a step of its own, with the rest of the line as its argument; a name
  nobody bound, an argument a name does not take, an empty line, a bound
  command that is not registered or is refused, and a cancelled line.
  Each message is read from the function that makes it.

The undo tree (`Editor/UndoTree.lean`) is plain Lean over the text port, so
its cases (`Editor/UndoTree/Cases.lean`) are properties of the same kind and
run against the model in the same list; `contract-test` runs them against
the real binding. `undoTreeChecks` are the checks of its pure operations,
which ask nothing of a text. `textModelStepChecks` hold a premise of the
theorems about undo (`TextModel.InStep`, `Editor/Text/Model.lean`) where
it is not proved: after each request of a sample sequence, every live text
of the model is in step.

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

- `setupChecks`: what a `setup` registers, commands, stores, jobs, key
  bindings, modes and ex bindings, and when it is refused;
- `registryChecks`: the registry, its commands, its jobs, its key
  bindings, its modes and its ex bindings, replaced by owner;
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
  installs, and only then. An install replaces config's key bindings,
  modes and ex bindings and keeps the compiled ones.

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
- `exLineChecks`: an ex line (`Editor/Ex/Line.lean`): the name and the
  argument a typed line parses to, and the invocation an ex binding makes
  of an argument, by what the binding takes;
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
  entered, what the scheme reports of a view in a state, what the grammar
  reads of a state's record (typed text, an operator over the selection),
  the last change, and a mode's keys under the Vim scheme: a hand-tuned
  key is typed text in insert state, and `Mode.check` reads every state's
  keymaps;
- `vimDefaultChecks`: the default states and bindings
  (`Editor/InputScheme/Vim/Default.lean`), observed through the grammar:
  what each default key parses to, and what the scheme reports of the view
  after it. They restate no table and name no vocabulary or command name;
- `vimContractChecks`: the scheme contract holds of the Vim scheme, over
  the registry written here and over the default states.

The grammar's checks run on a registry and keymaps written here
(`vimStates`), so that none of them names a default binding.

Evil (`Editor/Evil.lean`), what the Vim scheme's invocations run, is
checked on the editor's models. This is where Vim keys are pressed against
a text, under the Vim scheme that ships with the commands compiled code
registers for evil (`Editor/Evil/Compiled.lean`), on the loop's driver:

- `evilRestChecks`: where a cursor rests under each rule, from every
  position of a few small texts, on the text model alone;
- `evilMotionChecks`: each motion's key in a text with the cursor written
  into it as a bar (`evilKeys`, `evilRows`), with no count, a count of 1, a
  count inside the text and a count past it; the wanted column, by keys
  and by a command that calls the move command twice with one call; a
  sweep of every motion of the vocabulary from every position a cursor may
  rest at; and that every default motion key has a motion of its name;
- `evilStateChecks`: `v`, `V` and `<Escape>`: the selection the scene
  shows, its shape and what it covers, and the scene's cursor and status
  field in each state; and, by the entering command called with a report
  written by hand (`evilEntered`), a state that keeps both ends entered
  from an exclusive selection, which no default key does: where the anchor
  rests, and that the head steps back;
- `evilInsertChecks`: `i a I A`, typed text and `<Escape>`; that an insert
  session is one step of the history, by an undo request; a key typed into
  a prompt; and a committed text in normal state and inside a session;
- `evilOperatorChecks`: the operators (`Editor/Evil/Operators.lean`). An
  operator's keys are pressed with a sentinel in the unnamed register
  (`evilEdited`), so a register left as it was is seen, and a row
  (`OperatorRow`, `operatorRows`) says the text, the cursor, the register
  and whether it is line-wise, whether the view is left in insert state,
  and whether the command gave up. `operatorTable` is every operator over
  every motion in five situations; beside it are the special cases, the
  calls of the operate command that give up, and that an operator is one
  step of the history. `operatorSweep` presses every default operator key
  with every default motion key from every resting position of a few
  texts;
- `evilSelectionChecks`: the operators over a `v` and a `V` selection, by
  the same rows, and that the operator's key leaves one cursor;
- `evilRegisterChecks`: `x`, the registers a yank and a deletion set, the
  clipboard register on the clipboard model (`evilClipped`), and `p` and
  `P`, by the same rows;
- `evilOpenChecks`: `o` and `O`, by the same rows, and their insert
  session;
- `evilUndoChecks`: `u` and `C-r` after one change of each kind
  (`undoRows`): the text and the cursor from before the change, and those
  the change left. They are the phase's rule and are not compared with
  Vim, which leaves the cursor at the start of the changed text;
- `evilRepeatChecks`: `.` after a change of each kind (`repeatRows`), a
  count before it, a change with an insert session and its typed and
  committed text, and what is not repeated.

Each expected text of a row is written by hand from Vim's documented
behaviour (`docs/design/keymaps-and-modes.md`, "Motions as built"). No
check runs Vim. The word rule outside ASCII is the text port's and is not
restated here: the word motions' rows are ASCII, and one text with letters
Vim and the editor agree on.

Modes are checked on the test scheme, by the roles and the leader it reports
(`InputScheme.roleKey`, `InputScheme.leader`), so that no check of a mode
names a scheme's key:

- `modeRecordChecks`: the registered roles (`Editor/Role.lean`), and the
  keymaps a mode makes for a scheme (`Editor/Mode.lean`): its roles at the
  scheme's keys for them, its suffixes under the leader, and the scheme's
  hand-tuned keys for it ahead of both; and what `Mode.check` reports;
- `modeRegistryChecks`: modes in the registry
  (`Editor/Config/Registry.lean`): a mode's lineage, and the active keymaps
  of a view, in precedence order;
- `modeDispatchChecks`: keys in the loop over the registry's active
  keymaps, on the editor's models: a role's key runs the major mode's
  command in a view of its buffer and the global binding elsewhere, a minor
  mode's wins over the major mode's, a derived mode falls to its parent,
  and the leader then a suffix runs the mode's local command;
- `modeEnterChecks`: a mode's on-enter action, on the editor's models: it
  runs once, with the view, when the mode becomes a buffer's major mode, a
  derived mode's lineage root first, and a refusal runs nothing.
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
    { name :=
        "a setup registers a command that is given its call under its name, beside its other commands, in order; a name registered as a plain command and as one given its call is refused as registered twice"
      run :=
        let setup : SetupM Unit := do
          command "first" (makes "1")
          commandWith "greet" fun _ => makes "2"
          command "second" (makes "3")
        let twice : SetupM Unit := do
          command "greet" (makes "1")
          commandWith "greet" fun _ => makes "2"
        match Config.Registrations.ofSetup setup with
        | .error _ => pure false
        | .ok collected =>
          pure
            (collected.commands.map (·.name) == #["first", "greet", "second"] &&
              collected.commands.map (·.action matches .call _) == #[false, true, false] &&
              collected.commands.map (plainTexts ·.action) == #[some #["1"], none, some #["3"]] &&
              refusal twice == some "the command `greet` is registered twice") },
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
              collected.jobs.map (fun job => worked (job.work [])) ==
                #[.finished #["counted 42"], .finished #["x"]]) },
    { name :=
        "a setup that registers a job that takes arguments collects it under its name beside the others, and the job computes from the arguments it is started with; a job registered without them is the same whatever it is started with"
      run :=
        let setup : SetupM Unit := do
          jobWith "double"
              (fun arguments => do
                let [.nat n] := arguments | throw "double takes one number"
                sleep 5
                return 2 * n)
              fun n => makes s!"doubled to {n}"
          job "fixed" (fun _ => pure "x") makes
        match Config.Registrations.ofSetup setup with
        | .error _ => pure false
        | .ok collected =>
          let started (name : String) (arguments : List Argument) :=
            (collected.jobs.find? (·.name == name)).map fun job => worked (job.work arguments)
          pure
            (collected.jobs.map (·.name) == #["double", "fixed"] && collected.commands.isEmpty &&
              started "double" [.nat 21] == some (.finished #["doubled to 42"]) &&
              started "double" [.nat 4] == some (.finished #["doubled to 8"]) &&
              started "double" [] == some (.failed "double takes one number") &&
              started "fixed" [.nat 1] == some (.finished #["x"]) &&
              started "fixed" [] == some (.finished #["x"])) },
    { name :=
        "a job that takes arguments registered under the name of another job is refused with a message that names the job, whichever of the two was first"
      run :=
        let doubling (name : String) : SetupM Unit :=
          jobWith name (fun _ => pure 1) fun n => makes (toString n)
        let twice : SetupM Unit := do
          doubling "count"
          job "count" (fun _ => pure 3) fun n => makes (toString n)
        let again : SetupM Unit := do
          job "count" (fun _ => pure 3) fun n => makes (toString n)
          doubling "other"
          doubling "count"
        pure
          (refusal twice == some "the job `count` is registered twice" &&
            refusal again == some "the job `count` is registered twice") },
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
            refusal apart == none) },
    { name :=
        "a setup that binds ex names collects each binding, in order, with what it takes, nothing unless it says, and registers no command"
      run :=
        let setup : SetupM Unit := do
          exCommand "greet" "greet-named" (takes := .text)
          exCommand "w" "write"
        match Config.Registrations.ofSetup setup with
        | .error _ => pure false
        | .ok collected =>
          pure
            (collected.ex ==
                #[{ name := "greet", command := "greet-named", takes := .text },
                  { name := "w", command := "write" }] &&
              collected.commands.isEmpty) },
    { name :=
        "a setup that binds one ex name twice is refused with a message that names it, whether to one command or to two; two names for one command are not"
      run :=
        let twice : SetupM Unit := do
          exCommand "greet" "one"
          exCommand "w" "write"
          exCommand "greet" "two"
        let same : SetupM Unit := do
          exCommand "w" "write"
          exCommand "w" "write"
        let apart : SetupM Unit := do
          exCommand "w" "write"
          exCommand "write" "write"
        pure
          (refusal twice == some "the ex name `greet` is bound twice" &&
            refusal same == some "the ex name `w` is bound twice" &&
            refusal apart == none) },
    { name :=
        "a setup that binds an ex name that is empty or holds white space is refused, with a message that names it and the command: it could not be typed on the ex line"
      run :=
        let after (name : String) : SetupM Unit := do
          command "write" (makes "1")
          exCommand name "write"
        pure
          (["", "w q", " w", "w\t"].all
              (fun name => refusal (after name) == some (unusableExName name "write")) &&
            refusal (after "w-q!") == none) },
    { name := "defineMode registers the mode, in order, beside the commands"
      run :=
        let setup : SetupM Unit := do
          defineMode { name := "listing", roles := [(Role.nextItem, "listing-next")] }
          command "listing-next" (makes "1")
          defineMode { name := "derived", parent := some "listing" }
        match Config.Registrations.ofSetup setup with
        | .error _ => pure false
        | .ok collected =>
          pure
            (collected.modes.map (·.name) == #["listing", "derived"] &&
              collected.modes.map (·.parent) == #[none, some "listing"] &&
              collected.modes.map (·.roles) == #[[(Role.nextItem, "listing-next")], []] &&
              collected.commands.map (·.name) == #["listing-next"]) },
    { name := "a setup that defines a mode name twice is refused with a message that names the mode"
      run :=
        let setup : SetupM Unit := do
          defineMode { name := "listing" }
          defineMode { name := "other" }
          defineMode { name := "listing", parent := some "other" }
        pure (refusal setup == some "the mode `listing` is defined twice") },
    { name :=
        "a setup that defines a mode with an unregistered role, a suffix used twice or a suffix that is not keys is refused, naming the mode and the problem"
      run :=
        let refused (mode : Mode) (problem : Mode.Problem) : Bool :=
          refusal (defineMode mode) ==
            some s!"the mode `{mode.name}` cannot be meant: {problem.describe}"
        pure
          (refused { name := "roles", roles := [(Role.mk "frobnicate", "f")] }
              (.unregisteredRole (Role.mk "frobnicate")) &&
            refused { name := "twice", locals := [("x", "a"), ("x", "b")] }
              (.duplicateSuffix (keys "x")) &&
            refused { name := "unreadable", locals := [("S-a", "a")] } (.unreadableSuffix "S-a") &&
            refusal (defineMode { name := "fine", locals := [("x", "a")] }) == none) }]

/-- A registration of the plain command `name`, which makes the text `text`. -/
def registration (name text : String) : Config.Registration :=
  { name, action := .plain (makes text) }

/-- A registration of the job `name`, which finishes with a command that
makes the text `text`. -/
def jobRegistration (name text : String) : Config.JobRegistration :=
  { name, work := fun _ _ => pure (makes text) }

/-- How the job `registry` holds under `name` ends, started with `arguments`
and run against the job model; `none` if there is no such job. -/
def registeredWork (registry : Config.Registry) (name : String) (arguments : List Argument := []) :
    Option (Job.Outcome (Array String)) :=
  (registry.findJob? name).map fun entry => worked (entry.registration.work arguments)

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
        "a job is held with what it takes: the work a lookup hands back for the arguments the job is started with computes from them, and so does the work the editor would start for an installed config"
      run :=
        let doubling : Config.JobRegistration :=
          { name := "double"
            work := fun arguments =>
              Work.of
                (fun _ =>
                  match arguments with
                  | [.nat n] => pure (2 * n)
                  | _ => throw "no number")
                fun n => makes (toString n) }
        let registry := ({} : Config.Registry).replaceJobs .config #[doubling]
        let state : Config.State Unit := { registry }
        let starting (arguments : List Argument) :=
          (state.work? "double" arguments).map fun (owner, work) => (owner.name, worked work)
        pure
          (registeredWork registry "double" [.nat 21] == some (.finished #["42"]) &&
            registeredWork registry "double" == some (.failed "no number") &&
            starting [.nat 4] == some ("config", .finished #["8"]) &&
            starting [] == some ("config", .failed "no number") &&
            (state.work? "missing" [.nat 4]).isNone) },
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
            (registry.keymap TestScheme.scheme).continues (keys "C-c")) },
    { name :=
        "replacing an owner's modes leaves the others', and the latest mode of a name is the one found"
      run :=
        let named (name parent : String) : Mode := { name, parent := some parent }
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceModes .compiled
                #[named "listing" "compiled", named "kept" "compiled"]).replaceModes
            .config #[named "listing" "config", named "gone" "config"]
        let replaced := registry.replaceModes .config #[named "new" "config"]
        let parentOf (registry : Config.Registry) (name : String) : Option String :=
          (registry.mode? name).bind (·.parent)
        pure
          (parentOf registry "listing" == some "config" &&
            parentOf registry "kept" == some "compiled" &&
            parentOf registry "gone" == some "config" &&
            parentOf replaced "listing" == some "compiled" &&
            (replaced.mode? "gone").isNone &&
            parentOf replaced "new" == some "config" &&
            replaced.modes.map (·.mode.name) == #["listing", "kept", "new"] &&
            (registry.mode? "none").isNone) },
    { name :=
        "replacing an owner's ex bindings removes its old ones and adds the new, and leaves another owner's; a name nobody bound is not found"
      run :=
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceEx .compiled
                #[{ name := "w", command := "theirs" }]).replaceEx
            .config
            #[{ name := "greet", command := "one", takes := .text },
              { name := "old", command := "gone" }]
        let replaced := registry.replaceEx .config #[{ name := "greet", command := "two" }]
        pure
          (registry.ex? "w" == some { name := "w", command := "theirs" } &&
            registry.ex? "greet" == some { name := "greet", command := "one", takes := .text } &&
            registry.ex? "old" == some { name := "old", command := "gone" } &&
            replaced.ex? "w" == some { name := "w", command := "theirs" } &&
            replaced.ex? "greet" == some { name := "greet", command := "two" } &&
            replaced.ex? "old" == none &&
            replaced.ex.size == 2 &&
            registry.ex? "missing" == none) },
    { name :=
        "of two owners' ex bindings of one name the latest entry is the one found: config's while it is there, and the compiled one again once config binds nothing"
      run :=
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceEx .compiled
                #[{ name := "w", command := "compiled" },
                  { name := "q", command := "kept" }]).replaceEx
            .config #[{ name := "w", command := "config" }]
        pure
          ((registry.ex? "w").map (·.command) == some "config" &&
            (registry.ex? "q").map (·.command) == some "kept" &&
            ((registry.replaceEx .config #[]).ex? "w").map (·.command) == some "compiled") },
    { name :=
        "replacing an owner's ex bindings leaves the commands, the jobs, the key bindings and the modes as they were"
      run :=
        let registry : Config.Registry :=
          (((({} : Config.Registry).replace .config #[registration "greet" "1"]).replaceJobs .config
                    #[jobRegistration "count" "1"]).replaceBindings
                .config #[binding "C-c b" "one"]).replaceModes
            .config #[{ name := "listing" }]
        let replaced := registry.replaceEx .config #[{ name := "w", command := "write" }]
        pure
          (replaced.names == #["greet"] && registeredTexts replaced "greet" == some #["1"] &&
            replaced.jobs.map (·.registration.name) == #["count"] &&
            boundTo replaced "C-c b" == some (invoke "one") &&
            replaced.modes.map (·.mode.name) == #["listing"] &&
            (replaced.ex? "w").isSome) }]

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
        "a command config registers as one given its call is handed the call an invocation runs it with: it acts on the call's target and reads its arguments and its keys; an install replaces it with config's other commands, and a config that no longer registers it drops it"
      run :=
        let greets (label : String) : SetupM Unit :=
          commandWith "greet" fun call => Loop.insert call.target (callText label call)
        let called (state : Config.State Elaborated) : Option (Array String) :=
          (calls state "greet" [.nat 3, .str "w"] (keys "C-x i")).map (·.2)
        let (loaded, _) := reduce [.requested, .finished (accepted ["a"] (greets "one"))]
        let (reloaded, _) :=
          reduceFrom loaded [.requested, .finished (accepted ["a"] (greets "two"))]
        let (dropped, _) :=
          reduceFrom loaded [.requested, .finished (accepted ["a"] (command "other" (makes "o")))]
        pure
          (called loaded == some #["one 3 w C-x i"] && called reloaded == some #["two 3 w C-x i"] &&
            (called dropped).isNone &&
            loaded.registry.names == #["greet"]) },
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
            boundTo kept.registry "C-c o" == some (invoke "old")) },
    { name :=
        "an accepted outcome replaces the config's modes and leaves compiled ones; a rejected outcome keeps config's"
      run :=
        let compiled : Config.State Elaborated :=
          { registry := ({} : Config.Registry).replaceModes .compiled #[{ name := "kept" }] }
        let first : SetupM Unit := do
          defineMode { name := "listing", parent := some "first" }
          defineMode { name := "gone" }
        let (loaded, _) := reduceFrom compiled [.requested, .finished (accepted ["a"] first)]
        let (reloaded, _) :=
          reduceFrom loaded
            [.requested,
              .finished
                (accepted ["a"] (defineMode { name := "listing", parent := some "second" }))]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        let names (state : Config.State Elaborated) : Array String :=
          state.registry.modes.map (·.mode.name)
        let parentOf (state : Config.State Elaborated) : Option String :=
          (state.registry.mode? "listing").bind (·.parent)
        pure
          (names loaded == #["kept", "listing", "gone"] && parentOf loaded == some "first" &&
            names reloaded == #["kept", "listing"] &&
            parentOf reloaded == some "second" &&
            names kept == names loaded &&
            parentOf kept == some "first") },
    { name :=
        "an accepted outcome replaces the config's ex bindings and leaves compiled ones: a name the new config binds to another command runs that one, one it no longer binds is found no more, and a compiled name it bound is the compiled one again; a rejected outcome keeps them; an ex binding is not counted as a command"
      run :=
        let compiled : Config.State Elaborated :=
          {
            registry :=
              ({} : Config.Registry).replaceEx .compiled
                #[{ name := "w", command := "compiled" }, { name := "q", command := "kept" }] }
        let first : SetupM Unit := do
          exCommand "greet" "one" (takes := .text)
          exCommand "old" "gone"
          exCommand "w" "config"
        let (loaded, _) := reduceFrom compiled [.requested, .finished (accepted ["a"] first)]
        let (reloaded, effects) :=
          reduceFrom loaded [.requested, .finished (accepted ["a"] (exCommand "greet" "two"))]
        let (kept, _) := reduceFrom loaded [.requested, .finished (rejected "a")]
        let runs (state : Config.State Elaborated) (name : String) : Option String :=
          (state.registry.ex? name).map (·.command)
        pure
          (runs loaded "greet" == some "one" && runs loaded "old" == some "gone" &&
            runs loaded "w" == some "config" &&
            runs loaded "q" == some "kept" &&
            reloaded.registry.ex? "greet" == some { name := "greet", command := "two" } &&
            runs reloaded "old" == none &&
            runs reloaded "w" == some "compiled" &&
            runs reloaded "q" == some "kept" &&
            reloaded.registry.ex.size == 3 &&
            effects == #[.start (some #[]) #["a"], .cancelJobs "config", .report 2 true #[] 1 0] &&
            kept.registry.ex == loaded.registry.ex) }]

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

/-- Whether every live text of `model` is in step (`TextModel.InStep`) at
the revision it is at. -/
def allInStep (model : TextModel) : Bool :=
  (List.range model.texts.size).all fun index =>
    match model.texts[index]? with
    | some (some content) => decide (model.InStep ⟨index⟩ content.revision)
    | _ => true

/-- The check of the premise the theorems about undo take of the text model
(`TextModel.InStep`), for the requests no lemma covers. -/
def textModelStepChecks : List Check :=
  [{  name :=
        "every live text of the text model is in step after each request of a sequence, each of which is accepted: a text made, an insertion, a deletion, a transaction with selections, an applied inverse, a drop of inverses, a forgotten revision, a marker, a copy, and the release of another text; and a model whose log is short a revision is not in step"
      run :=
        pure <|
          let text : TextId := ⟨0⟩
          let steps : List (TextM Unit) :=
            [discard <| createText "héllo", text.insert 6 " wörld", text.delete 0 1,
              discard <|
                text.apply
                  { Transaction.replacing 12 0 0 "X" with
                    before := some { ranges := #[⟨0, 0⟩] }, after := some { ranges := #[⟨1, 1⟩] } }
                  Origin.user,
              discard <| text.applyInverse 3 3 Origin.user, text.dropInverses 1 2, text.forget 1,
              discard <| text.mark (.anchor { offset := 0, bias := .before }), discard <| text.copy,
              discard <| createText "other", (⟨2⟩ : TextId).release]
          let (held, model) :=
            steps.foldl
              (fun (held, model) step =>
                let (result, model) := step.runModel model
                (held && result.isOk && allInStep model, model))
              (true, ({} : TextModel))
          held && model.texts.size == 3 &&
            !allInStep { model with logs := model.logs.map fun log => { log with past := #[] } } }]

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
        "the text of a line ending is a line feed for LF, and a carriage return and a line feed for CRLF"
      run := pure (File.LineEnding.lf.text == "\n" && File.LineEnding.crlf.text == "\r\n") },
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

/-- A reply that may be refused, as a sum, which has an equality: the
refusal on the left. -/
def replied {ε α : Type} : Except ε α → ε ⊕ α
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
            model.display.scenes == #[twoViews, { twoViews with echo := "second" }] },
    { name :=
        "a watch request inside a command is answered by the watch model, and leaves the text model and the display model as they were"
      run := do
        let command : EditorM (Bool × Bool × Nat) := do
          let before ← Watch.interrupted
          Watch.lower
          return (before, ← Watch.interrupted, ← Watch.now)
        let watch : WatchModel := { arrived := 1, clock := 7 }
        let (result, model) := command.runModel { editorModel with watch }
        return resulted result == .inr (true, false, 7) &&
            model.watch == { watch with arrived := 0 } &&
            model.texts.contents == #[] &&
            model.display.scenes == #[] },
    { name :=
        "a program over the clipboard port, lifted to a command, gives the same replies on the editor's models as on the clipboard model and leaves the same clipboard, with the texts and the display as they were; a clipboard that is not available answers unavailable as a value, and the command is not refused"
      run := do
        let program :
          ClipboardM
            (Except ClipboardError (Option String) × Except ClipboardError (Option String)) :=
          do
          let before ← Clipboard.read
          discard <| Clipboard.write "copied"
          return (before, ← Clipboard.read)
        let (alone, clipboard) :=
          Program.run (port := clipboardPort) ClipboardModel.handle program {}
        let (onEditor, model) := (Clipboard.lift program).runModel editorModel
        let away : ClipboardModel := { held := some "kept", available := false }
        let (refused, after) :=
          (Clipboard.lift program).runModel { editorModel with clipboard := away }
        return (match onEditor with
            | .ok (before, written) =>
              replied before == replied alone.1 && replied written == replied alone.2 &&
                replied before == .inr none &&
                replied written == .inr (some "copied")
            | .error _ => false) &&
            model.clipboard == clipboard &&
            model.texts.contents == #[] &&
            model.display.scenes == #[] &&
            (match refused with
            | .ok (before, written) =>
              replied before == .inl .unavailable && replied written == .inl .unavailable
            | .error _ => false) &&
            after.clipboard == away },
    { name :=
        "a clipboard request inside a command moves the watch model's clock on by its pace, as a text request does: a read and then a write take two paces"
      run := do
        let command : EditorM (List Nat) := do
          let start ← Watch.now
          discard <| Clipboard.read
          let afterRead ← Watch.now
          discard <| Clipboard.write "copied"
          return [start, afterRead, ← Watch.now]
        let paced := (command.runModel { editorModel with watch := { clock := 100, pace := 10 } }).1
        return resulted paced == .inr [100, 110, 120] },
    { name :=
        "a state request of a command no loop runs is answered as an editor with no buffer and no window answers it, and nothing is kept: a read sees none, a buffer added is not there at the next read, and neither the watch model's clock nor the other models move"
      run := do
        let command :
          EditorM
            (EditorState ×
              Except BufferRefusal BufferId × EditorState × Except LayoutRefusal Unit) :=
          do
          let before ← editorState
          let added ← EditorState.ask (.addBuffer "new" ⟨0⟩ (UndoTree.new ⟨0⟩ 0))
          let after ← editorState
          return (before, added, after, ← EditorState.ask (.focus ⟨0⟩))
        let watch : WatchModel := { clock := 7, pace := 3 }
        let (result, model) := command.runModel { editorModel with watch }
        match result with
        | .ok (before, added, after, focused) =>
          return before == EditorState.none && before.buffers.isEmpty && before.windows.isEmpty &&
              replied added == .inr ⟨0⟩ &&
              after == EditorState.none &&
              replied focused == .inl (.noSuchWindow ⟨0⟩) &&
              model.watch == watch &&
              model.texts.contents == #[] &&
              model.display.scenes == #[]
        | .error _ =>
          return false }]

/-- The watch model after `program`, run from `model`, and what the program
returned. -/
def watched {α : Type} (program : WatchM α) (model : WatchModel := {}) : α × WatchModel :=
  Program.run (port := watchPort) WatchModel.handle program model

/-- The checks of the watch port's model (`Editor/Watch/Model.lean`): what
only the model has, an arrival a test places and a clock a command's
requests move. -/
def watchChecks : List Check :=
  [{  name :=
        "the watch model's interrupt key arrives when the flag is asked for the time after the count it was given, and once: asked four times with a count of two, the flag is down, down, up and up, with one arrived"
      run :=
        let asks : WatchM (List Bool) := do
          return [← Watch.interrupted, ← Watch.interrupted, ← Watch.interrupted,
              ← Watch.interrupted]
        let (answers, model) := watched asks { arrivesAfter := some 2 }
        let (never, _) := watched asks
        pure
          (answers == [false, false, true, true] && model.arrived == 1 &&
            model.arrivesAfter == none &&
            never == [false, false, false, false]) },
    { name := "the watch model's clock reads where it was set, and a watch request does not move it"
      run :=
        let reads : WatchM (List Nat) := do
          let first ← Watch.now
          discard Watch.interrupted
          Watch.lower
          return [first, ← Watch.now]
        pure ((watched reads { clock := 5, pace := 10 }).1 == [5, 5]) },
    { name :=
        "on the editor's models the clock moves on by the watch model's pace at each text request and each display request of a command, and at no watch request"
      run := do
        let command : EditorM (List Nat) := do
          let start ← Watch.now
          let text ← createText "ab"
          let afterText ← Watch.now
          Display.publish twoViews
          let afterDisplay ← Watch.now
          discard Watch.interrupted
          discard <| text.read
          return [start, afterText, afterDisplay, ← Watch.now]
        let paced := (command.runModel { editorModel with watch := { clock := 100, pace := 10 } }).1
        let still := (command.runModel editorModel).1
        return resulted paced == .inr [100, 110, 120, 130] && resulted still == .inr [0, 0, 0, 0] }]

/-- Runs a program over the clipboard port against the clipboard model
`model`: its value and the model after its last request. -/
def clipped {α : Type} (program : ClipboardM α) (model : ClipboardModel := {}) :
    α × ClipboardModel :=
  Program.run (port := clipboardPort) ClipboardModel.handle program model

/-- A clipboard written for the test that breaks the contract: it accepts
every write and keeps none, so a read answers what it held before. -/
def droppingWrites : (request : ClipboardRequest) → ClipboardModel → request.Reply × ClipboardModel
  | .read, model => (.ok model.held, model)
  | .write _, model => (.ok (), model)

/-- The checks of the clipboard interface's model
(`Editor/Clipboard/Model.lean`): what only the model shows, a clipboard
that is not available and one that holds nothing, and the contract
(`Editor/Clipboard/Contract.lean`) seen to report a clipboard that breaks
it. -/
def clipboardChecks : List Check :=
  [{  name :=
        "a clipboard model that is not available refuses a read and a write, each with unavailable, and holds what it held: the refused write replaces nothing, and once it is available again a read answers the text from before"
      run :=
        pure <|
          let away : ClipboardModel := { held := some "kept", available := false }
          let (read, afterRead) := clipped Clipboard.read away
          let (written, afterWrite) := clipped (Clipboard.write "lost") away
          let (back, _) := clipped Clipboard.read { afterWrite with available := true }
          replied read == .inl .unavailable && afterRead == away &&
            replied written == .inl .unavailable &&
            afterWrite == away &&
            replied back == .inr (some "kept") },
    { name :=
        "a clipboard model that holds nothing answers a read with no text, which is another answer than the empty text, and a read changes nothing"
      run :=
        pure <|
          let (read, after) := clipped Clipboard.read
          let (empty, _) :=
            clipped do
              discard <| Clipboard.write ""
              Clipboard.read
          replied read == .inr none && after == {} && replied empty == .inr (some "") &&
            replied read != replied empty },
    { name :=
        "the clipboard contract reports a clipboard that drops every write: its first property, that a text written is the text read, does not hold of it, and every property holds of the model"
      run := do
        let dropped ←
          ClipboardContract.failures
              (fun property =>
                pure (Program.run (port := clipboardPort) droppingWrites property.holds {}).1)
              ClipboardContract.properties
        let held ←
          ClipboardContract.failures (fun property => pure (clipped property.holds).1)
              ClipboardContract.properties
        return (ClipboardContract.properties.head?.map (·.name)).any dropped.contains &&
            held.isEmpty &&
            !ClipboardContract.properties.isEmpty }]

/-- The editor's models with a watch model that counts: its clock, at 0,
moves on by 1 at each text request and each display request, so its reading
is how many of them a command made. -/
def countingModel (watch : WatchModel := {}) : EditorModel :=
  { editorModel with
    watch :=
      { watch with
        clock := 0, pace := 1 } }

/-- A command that makes a text of each of `labels`, in order, and returns
how many it made. -/
def makesEach (labels : List String) : EditorM Nat := do
  for label in labels do
    makes label
  return labels.length

/-- `command` as the loop runs one (`EditorM.dispatched`), told nothing of
the registry, from an editor state with nothing in it: how it ended. The
commands of the guard checks make no state request, so the state it left is
not looked at. -/
def guarded {α : Type} (command : EditorM α) : EditorM (Guarded α) :=
  return (← command.dispatched {} EditorState.none).1

/-- The checks of the guard of a dispatched command
(`Editor/Command/Dispatch.lean`, "The guard") on the editor's models: it
stops at its next request once the interrupt flag is up. They run the
transformation the loop runs, on commands that make no state request. -/
def guardChecks : List Check :=
  [{  name :=
        "with the interrupt flag down a guarded command finishes with its value, and leaves the models as the command alone does"
      run := do
        let command := makesEach ["1", "2", "3"]
        let (bare, alone) := command.runModel countingModel
        let (ended, model) := (guarded command).runModel countingModel
        return resulted bare == .inr 3 && resulted ended == .inr (.finished 3) &&
            model.texts.contents == alone.texts.contents &&
            model.display.scenes == alone.display.scenes &&
            model.watch == alone.watch },
    { name :=
        "a guarded command that is refused is not itself refused: the refusal comes back as its outcome, with what the command did before it"
      run := do
        let command : EditorM Nat := do
          makes "1"
          (⟨7⟩ : TextId).insert 0 "x"
          makesEach ["2"]
        let (ended, model) := (guarded command).runModel countingModel
        return resulted ended == .inr (.refused .noSuchText) && model.texts.contents == #["1"] },
    { name :=
        "with the interrupt flag up before it starts, a guarded command makes no request and is interrupted, and the flag stays up"
      run := do
        let (ended, model) :=
          (guarded (makesEach ["1", "2"])).runModel (countingModel { arrived := 1 })
        return resulted ended == .inr .interrupted && model.texts.contents == #[] &&
            model.watch.clock == 0 &&
            model.watch.arrived == 1 },
    { name :=
        "when the interrupt key arrives as a guarded command is about to make its fourth request, the command has made exactly three and makes no more"
      run := do
        let (ended, model) :=
          (guarded (makesEach ["1", "2", "3", "4", "5"])).runModel
            (countingModel { arrivesAfter := some 3 })
        return resulted ended == .inr .interrupted && model.texts.contents == #["1", "2", "3"] &&
            model.watch.clock == 3 },
    { name :=
        "a command that catches every refusal of every request cannot go on past an interrupt: nothing is thrown for it to catch"
      run := do
        let stubborn : EditorM Nat := do
          let mut made := 0
          for label in ["1", "2", "3", "4"] do
            try
              makes label
              made := made + 1
            catch _ =>
              made := made + 100
          return made
        let (ended, model) := (guarded stubborn).runModel (countingModel { arrivesAfter := some 2 })
        return resulted ended == .inr .interrupted && model.texts.contents == #["1", "2"] &&
            model.watch.clock == 2 },
    { name :=
        "a guarded command that makes no request finishes with its value though the interrupt flag is up: there is no request to stop it at"
      run := do
        let (ended, model) :=
          (guarded (pure 7 : EditorM Nat)).runModel (countingModel { arrived := 1 })
        return resulted ended == .inr (.finished 7) && model.watch.arrived == 1 },
    { name :=
        "a clipboard request is guarded like a text request: with the interrupt flag up before a clipboard write the write is not made and the clipboard holds what it held, and with the flag down the same command writes"
      run := do
        let command : EditorM Unit := discard <| Clipboard.write "copied"
        let (ended, model) := (guarded command).runModel (countingModel { arrived := 1 })
        let (finished, wrote) := (guarded command).runModel countingModel
        return resulted ended == .inr .interrupted && model.clipboard.held == none &&
            model.watch.clock == 0 &&
            resulted finished == .inr (.finished ()) &&
            wrote.clipboard.held == some "copied" &&
            wrote.watch.clock == 1 }]

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
  let some buffer := state.buffer? ⟨0⟩ | throw .noSuchText
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
      buffers := state.buffers.push (some { name := "other", text, history })
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

/-- The continuation the prompts of these checks are asked with: a command's
name and an argument of the asker's own. No command is registered under it
here: a continuation is plain data. -/
def asked : Invocation :=
  { command := "greet", arguments := [.nat 7] }

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
    ("with a window whose buffer does not exist", withWindow ⟨1⟩ ({ · with buffer := ⟨5⟩ })),
    ("with a prompt whose view has no window", fun state =>
      { state with
        prompt := some { label := "", view := ⟨7⟩, asker := ⟨0⟩, continuation := asked } }),
    ("with a prompt whose view is also a window of the tree", fun state =>
      { state with
        prompt := some { label := "", view := ⟨2⟩, asker := ⟨0⟩, continuation := asked } })]

/-- `state` with a prompt asked for from its focused view, and the reply: the
label `Name: `, the continuation `asked`, and a minibuffer over the text
`text`, with a new history over it, an anchor that is its marker 0 and a
selection that is its marker 1. The operation asks the text store nothing,
so the ids are written out by hand. -/
def prompted (state : EditorState) (text : Nat := 7) : Except PromptRefusal ViewId × EditorState :=
  state.openPrompt "Name: " asked ⟨text⟩ (UndoTree.new ⟨text⟩ 0) ⟨⟨text⟩, 0⟩ ⟨⟨text⟩, 1⟩

/-- States of the quit checks, each `twoBuffers` with its histories set by
hand. -/
structure QuitStates where
  /-- The scratch buffer, which holds no file, is modified. -/
  bare : EditorState
  /-- And the buffer `other` holds a file and is modified. -/
  held : EditorState
  /-- And a save of `other` is in flight, writing the state its text is
  in. -/
  saving : EditorState
  /-- And `other` was edited since that save began. -/
  moved : EditorState
  /-- The save of `saving` ended with a stamp: `other` is saved. -/
  saved : EditorState

/-- The states of the quit checks. The operations ask the text store
nothing, so a revision and a snapshot's id are written out by hand. -/
def quitStates : TextM QuitStates := do
  let state ← twoBuffers
  let stamp : File.Stamp := { seconds := 3, nanoseconds := 0, size := 9 }
  let edited := (UndoTree.new ⟨1⟩ 0).record 3
  let (_, bare) := state.setHistory ⟨0⟩ ((UndoTree.new ⟨0⟩ 0).record 2)
  let (_, held) := bare.attachFile ⟨1⟩ "/files/note.txt" stamp .lf
  let (_, held) := held.setHistory ⟨1⟩ edited
  let (_, saving) := held.beginSave ⟨1⟩ ⟨5⟩ edited.state
  let (_, moved) := saving.setHistory ⟨1⟩ (edited.record 4)
  let (_, saved) := saving.endSave ⟨1⟩ ⟨5⟩ (some stamp)
  return { bare, held, saving, moved, saved }

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
            state.wellFormed && state.buffers.map (·.map (·.name)) == #[some "scratch"] &&
              state.windows.map (·.id) == #[⟨0⟩] &&
              state.frame.tree == .split .rows (.window ⟨0⟩) .minibuffer &&
              state.frame.focused == ⟨0⟩ &&
              state.frame.hasFocus &&
              state.echo == "" &&
              state.preedit == none },
    { name :=
        "the initial state's buffer has no file, and its line ending is a line feed; no path finds a buffer"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            ((state.buffer? ⟨0⟩).map fun buffer => (buffer.file, buffer.lineEnding)) ==
                some (none, .lf) &&
              state.findFile "/files/note.txt" == none },
    { name := "why a job was not started names the job, as a sentence for the echo area"
      run :=
        pure
          (((JobRefusal.noSuchJob "load-it").describe.splitOn "load-it").length == 2 &&
            (JobRefusal.noSuchJob "a").describe != (JobRefusal.noSuchJob "b").describe) },
    { name :=
        "a free name is the name itself when no buffer has it, and otherwise the name followed by <2>, <3> and so on, the first no buffer has"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let named (names : List String) : EditorState :=
              names.foldl (fun state name => (state.addBuffer name ⟨1⟩ (UndoTree.new ⟨1⟩ 0)).2)
                state
            state.freeName "new" == "new" && state.freeName "other" == "other<2>" &&
              (named ["other<2>"]).freeName "other" == "other<3>" &&
              (named ["other<3>"]).freeName "other" == "other<2>" &&
              (named ["other<2>", "other<3>"]).freeName "other" == "other<4>" &&
              (named ["other<2>"]).freeName "other<2>" == "other<2><2>" },
    { name :=
        "a state that breaks one layout invariant is not well formed: a focus outside the tree, no minibuffer leaf or two, a window named twice, a tree window with no window, a window outside the tree, a window with no buffer, a prompt whose view has no window, a prompt whose view is a window of the tree"
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
    { name :=
        "with the minibuffer's view given, the views of a split tree that has the minibuffer's place still tile the frame, the minibuffer's view among them once and the windows in drawing order, at even, odd and zero sizes; a tree with no such place is laid out as with no view"
      run :=
        pure <|
          sampleTrees.all fun tree =>
            sampleSizes.all fun size =>
              let view : ViewId := ⟨9⟩
              let laid := tree.rects (frameRect size) (some view)
              if tree.minibuffers == 0 then laid == tree.rects (frameRect size)
              else
                tiles (frameRect size) (laid.map (·.2)) &&
                  (laid.map (·.1)).filter (· != view) == tree.windows &&
                  laid.size == tree.windows.size + 1 },
    { name :=
        "the minibuffer's place takes a strip of its split, the minibuffer's height along the split's axis, or the whole extent where that is less, and its sibling the rest: below a window, in the left of two columns, and first along columns; a tree that is the place alone gives the view the whole rectangle"
      run :=
        pure <|
          let view : ViewId := ⟨9⟩
          let window (index : Nat) : Split := .window ⟨index⟩
          let below : Split := .split .rows (window 0) .minibuffer
          let strip := Split.minibufferHeight
          let laid (tree : Split) (width height : Nat) :=
            tree.rects (frameRect ⟨width, height⟩) (some view)
          strip > 0 && strip < 240 &&
            laid below 640 480 ==
              #[(⟨0⟩, { x := 0, y := 0, width := 640, height := 480 - strip }),
                (view, { x := 0, y := 480 - strip, width := 640, height := strip })] &&
            laid below 7 3 ==
              #[(⟨0⟩, { x := 0, y := 0, width := 7, height := 0 }),
                (view, { x := 0, y := 0, width := 7, height := 3 })] &&
            laid below 0 0 ==
              #[(⟨0⟩, { x := 0, y := 0, width := 0, height := 0 }),
                (view, { x := 0, y := 0, width := 0, height := 0 })] &&
            laid (.split .columns below (.split .rows (window 1) (window 2))) 640 480 ==
              #[(⟨0⟩, { x := 0, y := 0, width := 320, height := 480 - strip }),
                (view, { x := 0, y := 480 - strip, width := 320, height := strip }),
                (⟨1⟩, { x := 320, y := 0, width := 320, height := 240 }),
                (⟨2⟩, { x := 320, y := 240, width := 320, height := 240 })] &&
            laid (.split .columns .minibuffer (window 0)) 640 480 ==
              #[(view, { x := 0, y := 0, width := strip, height := 480 }),
                (⟨0⟩, { x := strip, y := 0, width := 640 - strip, height := 480 })] &&
            laid .minibuffer 640 480 == #[(view, frameRect ⟨640, 480⟩)] },
    { name :=
        "with no minibuffer's view given the minibuffer's place takes nothing: a window above it has the whole frame, and the place alone has no view"
      run :=
        pure <|
          let whole := frameRect ⟨640, 480⟩
          (Split.split .rows (.window ⟨0⟩) .minibuffer).rects whole == #[(⟨0⟩, whole)] &&
            (Split.split .rows (.window ⟨0⟩) .minibuffer).rects whole none == #[(⟨0⟩, whole)] &&
            Split.minibuffer.rects whole == #[] },
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
            | _ => false },
    { name := "the initial state's window keeps no wanted column"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state => (state.window? ⟨0⟩).map (·.wanted) == some none },
    { name :=
        "the initial state has no register: none is read under the empty name, under a letter or under the clipboard's name"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            state.registers.isEmpty && ["", "\"", "a", "+"].all (state.register? · == none) },
    { name :=
        "a register set under a name is read back under that name with its text and whether it is line-wise, and under no other; a second one set under the name replaces it, and a register under another name stays; nothing else of the state changes"
      run :=
        pure <|
          match onTextModel threeWindows with
          | none => false
          | some state =>
            let word : Register := { text := "word" }
            let line : Register := { text := "a line\n", linewise := true }
            let once := state.setRegister "a" word
            let both := once.setRegister "b" line
            let again := both.setRegister "a" line
            once.register? "a" == some word && once.register? "b" == none &&
              once.register? "" == none &&
              !word.linewise &&
              both.register? "a" == some word &&
              both.register? "b" == some line &&
              again.register? "a" == some line &&
              again.register? "b" == some line &&
              again.registers.size == 2 &&
              { again with registers := #[] } == state &&
              (state.setRegister "" word).register? "" == some word },
    { name :=
        "the initial state's selection is one cursor at 0, of the shape the state is made with, and exclusive when it is made with none"
      run :=
        pure <|
          let cursor (start : TextM EditorState) : Option Marker :=
            onTextModel do
              let some target := (← start).focusedTarget? | throw .noSuchText
              target.buffer.text.marker target.window.selection
          let one (shape : Shape) : Option Marker :=
            some (.selection { ranges := #[⟨0, 0⟩], shape })
          cursor (EditorState.initial ⟨640, 480⟩) == one .exclusive &&
            cursor (EditorState.initial ⟨640, 480⟩ .inclusive) == one .inclusive &&
            cursor (EditorState.initial ⟨640, 480⟩ .line) == one .line },
    { name :=
        "setting a window's wanted column keeps the column with the head it was kept at, and leaves the other windows and the rest of the state; setting none keeps none again"
      run :=
        pure <|
          match onTextModel threeWindows with
          | none => false
          | some state =>
            let kept : Window.Wanted := { column := .cells 3, head := 7 }
            let wanted (state : EditorState) (index : Nat) : Option (Option Window.Wanted) :=
              (state.window? ⟨index⟩).map (·.wanted)
            match state.setWanted ⟨1⟩ (some kept) with
            | (.ok (), after) =>
              wanted after 1 == some (some kept) && wanted after 0 == some none &&
                wanted after 2 == some none &&
                after ==
                  { state with
                    windows :=
                      state.windows.map fun window =>
                        if window.id == ⟨1⟩ then { window with wanted := some kept }
                        else window } &&
                (match after.setWanted ⟨1⟩ (some { column := .lineEnd, head := 2 }) with
                | (.ok (), ends) => wanted ends 1 == some (some { column := .lineEnd, head := 2 })
                | _ => false) &&
                match after.setWanted ⟨1⟩ none with
                | (.ok (), cleared) => cleared == state
                | _ => false
            | _ => false },
    { name :=
        "setting the wanted column of a view with no window is refused with noSuchWindow, and the state is as it was"
      run :=
        pure <|
          match onTextModel threeWindows with
          | none => false
          | some state =>
            match state.setWanted ⟨7⟩ (some { column := .cells 3, head := 7 }) with
            | (.error (.noSuchWindow id), after) => id == ⟨7⟩ && after == state
            | _ => false },
    { name :=
        "a window shown another buffer keeps no wanted column, and a window a split makes has none while its source keeps its own"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let kept : Window.Wanted := { column := .cells 3, head := 4 }
            let marker (text index : Nat) : MarkerId := ⟨⟨text⟩, index⟩
            let (_, keeping) := state.setWanted ⟨0⟩ (some kept)
            let wanted (state : EditorState) (index : Nat) : Option (Option Window.Wanted) :=
              (state.window? ⟨index⟩).map (·.wanted)
            (match keeping.showBuffer ⟨0⟩ ⟨1⟩ (marker 1 8) (marker 1 9) with
              | (.ok (), shown) =>
                wanted keeping 0 == some (some kept) && wanted shown 0 == some none
              | _ => false) &&
              match keeping.splitWindow ⟨0⟩ .rows (marker 0 8) (marker 0 9) with
              | (.ok made, split) =>
                wanted split made.index == some none && wanted split 0 == some (some kept)
              | _ => false },
    { name :=
        "setting a buffer's major mode names it and says it became the major mode, leaving the other buffers; setting it again changes nothing and says not; another mode replaces it"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let major (state : EditorState) (index : Nat) : Option String :=
              (state.buffer? ⟨index⟩).bind (·.major)
            match state.setMajorMode ⟨1⟩ "listing" with
            | (.ok true, listed) =>
              major state 1 == none && major listed 1 == some "listing" && major listed 0 == none &&
                listed ==
                  { state with
                    buffers :=
                      state.buffers.modify 1 (·.map ({ · with major := some "listing" })) } &&
                (match listed.setMajorMode ⟨1⟩ "listing" with
                | (.ok false, again) => again == listed
                | _ => false) &&
                match listed.setMajorMode ⟨1⟩ "other" with
                | (.ok true, other) => major other 1 == some "other"
                | _ => false
            | _ => false },
    { name :=
        "a minor mode added is first and added once, and removing one takes it away; removing one not there changes nothing"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let minors (state : EditorState) : Array String :=
              ((state.buffer? ⟨0⟩).map (·.minors)).getD #[]
            let (_, one) := state.addMinorMode ⟨0⟩ "one"
            let (_, two) := one.addMinorMode ⟨0⟩ "two"
            let (added, again) := two.addMinorMode ⟨0⟩ "one"
            let (removed, without) := two.removeMinorMode ⟨0⟩ "one"
            let (absent, unchanged) := two.removeMinorMode ⟨0⟩ "three"
            minors state == #[] && minors one == #["one"] && minors two == #["two", "one"] &&
              added matches .ok () &&
              again == two &&
              removed matches .ok () &&
              minors without == #["two"] &&
              absent matches .ok () &&
              unchanged == two &&
              ((two.buffer? ⟨1⟩).map (·.minors)) == some #[] },
    { name :=
        "setting a major mode, adding a minor mode and removing one each refuse a buffer there is none of with noSuchBuffer, and the state is as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let refused {α : Type} : Except BufferRefusal α × EditorState → Bool
              | (.error (.noSuchBuffer id), after) => id == ⟨5⟩ && after == state
              | _ => false
            refused (state.setMajorMode ⟨5⟩ "listing") && refused (state.addMinorMode ⟨5⟩ "one") &&
              refused (state.removeMinorMode ⟨5⟩ "one") },
    { name := "the initial state has no prompt open"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state => state.prompt == none },
    { name :=
        "opening a prompt replies the minibuffer's view, a new one: the state has the prompt with its label, its continuation and the focused view as its asker, a buffer in the next slot over the text given, with the minibuffer's mode and a name no other buffer has, a window on it with the markers given, the focus on it, and the tree as it was; it is well formed"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            match prompted state with
            | (.ok view, after) =>
              view == ⟨1⟩ &&
                after.prompt ==
                  some { label := "Name: ", view := ⟨1⟩, asker := ⟨0⟩, continuation := asked } &&
                after.buffers.size == 2 &&
                after.buffer? ⟨0⟩ == state.buffer? ⟨0⟩ &&
                after.buffer? ⟨1⟩ ==
                  some
                    { name := Prompt.bufferName, text := ⟨7⟩, history := UndoTree.new ⟨7⟩ 0
                      major := some Prompt.mode } &&
                state.findBuffer Prompt.bufferName == none &&
                after.windows ==
                  state.windows.push
                    { id := ⟨1⟩, buffer := ⟨1⟩, scroll := ⟨⟨7⟩, 0⟩, selection := ⟨⟨7⟩, 1⟩ } &&
                after.frame == { state.frame with focused := ⟨1⟩ } &&
                after.nextView == 2 &&
                after.wellFormed
            | _ => false },
    { name :=
        "the minibuffer's buffer gets the next free name when a buffer is already called by the minibuffer's name"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            let (_, named) := state.addBuffer Prompt.bufferName ⟨3⟩ (UndoTree.new ⟨3⟩ 0)
            match prompted named with
            | (.ok _, after) =>
              (after.buffer? ⟨2⟩).map (·.name) == some s!"{Prompt.bufferName}<2>" &&
                after.findBuffer Prompt.bufferName == some ⟨1⟩ &&
                after.wellFormed
            | _ => false },
    { name :=
        "a second prompt is refused with alreadyOpen and the open prompt's view, a history or a marker of another text than the minibuffer's with notItsText, and a prompt asked for with no window focused with noWindow, each with the state as it was"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            let (_, asking) := prompted state
            let refused (refusal : PromptRefusal) (was : EditorState) :
              Except PromptRefusal ViewId × EditorState → Bool
              | (.error why, after) => why == refusal && after == was
              | _ => false
            let astray (history scroll selection : Nat) :=
              state.openPrompt "Name: " asked ⟨7⟩ (UndoTree.new ⟨history⟩ 0) ⟨⟨scroll⟩, 0⟩
                ⟨⟨selection⟩, 1⟩
            asking.prompt.isSome && refused (.alreadyOpen ⟨1⟩) asking (prompted asking 8) &&
              refused .notItsText state (astray 0 7 7) &&
              refused .notItsText state (astray 7 0 7) &&
              refused .notItsText state (astray 7 7 0) &&
              refused .noWindow EditorState.none (prompted EditorState.none) },
    { name :=
        "the focus leaves the minibuffer's view for a window of the tree and comes back to it, and nothing else changes"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            let (_, asking) := prompted state
            match asking.focusWindow ⟨0⟩ with
            | (.ok (), away) =>
              away == { asking with frame := { asking.frame with focused := ⟨0⟩ } } &&
                away.wellFormed &&
                match away.focusWindow ⟨1⟩ with
                | (.ok (), back) => back == asking
                | _ => false
            | _ => false },
    { name :=
        "removing, splitting and showing another buffer in the minibuffer's view, and showing the minibuffer's buffer in another window, are each refused with ofMinibuffer and the minibuffer's view, with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, asking) := prompted state
            let refused {α : Type} : Except LayoutRefusal α × EditorState → Bool
              | (.error (.ofMinibuffer view), after) => view == ⟨2⟩ && after == asking
              | _ => false
            asking.prompt.map (·.view) == some ⟨2⟩ && refused (asking.removeWindow ⟨2⟩) &&
              refused (asking.splitWindow ⟨2⟩ .rows ⟨⟨7⟩, 2⟩ ⟨⟨7⟩, 3⟩) &&
              refused (asking.showBuffer ⟨2⟩ ⟨1⟩ ⟨⟨1⟩, 8⟩ ⟨⟨1⟩, 9⟩) &&
              refused (asking.showBuffer ⟨0⟩ ⟨2⟩ ⟨⟨7⟩, 2⟩ ⟨⟨7⟩, 3⟩) },
    { name :=
        "with a prompt open over two windows, removing one window is done and leaves the prompt open, and removing the other is refused with onlyWindow: the minibuffer's window does not count"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, asking) := prompted state
            match asking.removeWindow ⟨1⟩ with
            | (.ok removed, one) =>
              removed.id == ⟨1⟩ && one.wellFormed && one.prompt == asking.prompt &&
                one.frame.focused == ⟨2⟩ &&
                one.windows.map (·.id) == #[⟨0⟩, ⟨2⟩] &&
                match one.removeWindow ⟨0⟩ with
                | (.error .onlyWindow, same) => same == one
                | _ => false
            | _ => false },
    { name :=
        "removing the minibuffer's buffer while its prompt is open is refused with shown and the minibuffer's view"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            let (_, asking) := prompted state
            match asking.removeBuffer ⟨1⟩ with
            | (.error (.shown view), after) => view == ⟨1⟩ && after == asking
            | _ => false },
    { name := "why a prompt was refused is a sentence for the echo area, one for each refusal"
      run :=
        pure
          (([PromptRefusal.alreadyOpen ⟨1⟩, .notOpen, .notItsText, .noWindow].map
                  PromptRefusal.describe).eraseDups.length ==
              4 &&
            [PromptRefusal.alreadyOpen ⟨1⟩, .notOpen, .notItsText, .noWindow].all fun refusal =>
              !refusal.describe.isEmpty) },
    { name :=
        "closing a prompt with no answer leaves no prompt: the minibuffer's window is gone, its buffer's slot is empty, the focus is on the asking view, the tree and the next view's id are as they were after the open, and nothing is answered; the state is well formed"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            let (_, asking) := prompted state
            match asking.closePrompt none with
            | (.ok (), closed) =>
              closed ==
                  { state with
                    buffers := state.buffers.push none, nextView := 2 } &&
                closed.prompt == none &&
                closed.window? ⟨1⟩ == none &&
                closed.buffers[1]? == some none &&
                closed.frame.focused == ⟨0⟩ &&
                closed.frame.tree == asking.frame.tree &&
                closed.nextView == asking.nextView &&
                closed.answered == #[] &&
                closed.wellFormed
            | _ => false },
    { name :=
        "closing a prompt with an answer does the same, and records the continuation with the answer as its first argument, before its own"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            let (_, asking) := prompted state
            match asking.closePrompt none, asking.closePrompt (some "héllo") with
            | (.ok (), cancelled), (.ok (), accepted) =>
              accepted.answered == #[{ command := "greet", arguments := [.str "héllo", .nat 7] }] &&
                { accepted with answered := #[] } == cancelled &&
                accepted.wellFormed
            | _, _ => false },
    { name :=
        "two prompts opened and accepted one after the other leave two answered invocations, in order, and the second prompt's view and buffer have ids the first's never had"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            let (first, one) := prompted state
            let (_, one) := one.closePrompt (some "a")
            let (second, two) := prompted one 8
            let minibuffer := two.minibufferBuffer?
            let (_, two) := two.closePrompt (some "b")
            replied first == .inr ⟨1⟩ && replied second == .inr ⟨2⟩ && minibuffer == some ⟨2⟩ &&
              two.answered ==
                #[{ command := "greet", arguments := [.str "a", .nat 7] },
                  { command := "greet", arguments := [.str "b", .nat 7] }] &&
              two.buffers.size == 3 &&
              two.nextView == 3 &&
              two.wellFormed },
    { name :=
        "closing a prompt gives the focus back to the asking view, though the focus was moved to another window meanwhile"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, asking) := prompted state
            let (_, away) := asking.focusWindow ⟨1⟩
            let (_, closed) := away.closePrompt (some "a")
            asking.prompt.map (·.asker) == some ⟨0⟩ && away.frame.focused == ⟨1⟩ &&
              closed.frame.focused == ⟨0⟩ &&
              closed.wellFormed },
    { name :=
        "when the asking view was removed while the prompt was open, the prompt stays open, and closing it focuses the first window of the tree"
      run :=
        pure <|
          match onTextModel threeWindows with
          | none => false
          | some state =>
            let (_, asking) := prompted state
            let (removed, without) := asking.removeWindow ⟨0⟩
            let (_, closed) := without.closePrompt (some "a")
            (replied removed).isRight && without.prompt == asking.prompt && without.wellFormed &&
              without.frame.focused == ⟨3⟩ &&
              closed.frame.focused == ⟨1⟩ &&
              closed.frame.tree.windows == #[⟨1⟩, ⟨2⟩] &&
              closed.answered.size == 1 &&
              closed.wellFormed },
    { name :=
        "closing a prompt when none is open is refused with notOpen, with or without an answer, and the state is as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            [none, some "a"].all fun answer =>
              match state.closePrompt answer with
              | (.error .notOpen, after) => after == state
              | _ => false },
    { name :=
        "the initial state is not asked to quit, does not leave, has no buffer with unsaved changes and no save in flight"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            !state.quitting && !state.leaves && state.unsaved.isNone && !state.isSaving },
    { name :=
        "a modified buffer with no file has no unsaved changes; one that holds a file has; one whose save in flight is writing the state its text is in has not; one edited since that save began has; and one whose save was ended with a stamp has not"
      run :=
        pure <|
          match onTextModel quitStates with
          | none => false
          | some states =>
            let unsaved (state : EditorState) := state.unsaved.map (·.name)
            ((states.bare.buffer? ⟨0⟩).map (·.isModified)) == some true &&
              unsaved states.bare == none &&
              unsaved states.held == some "other" &&
              unsaved states.saving == none &&
              unsaved states.moved == some "other" &&
              unsaved states.saved == none &&
              [states.bare, states.held, states.saved].all (!·.isSaving) &&
              states.saving.isSaving &&
              states.moved.isSaving },
    { name :=
        "a state asked to quit leaves when no buffer has unsaved changes and no save is in flight, and not while a save is in flight or a buffer has unsaved changes; a state that was not asked never leaves"
      run :=
        pure <|
          match onTextModel quitStates with
          | none => false
          | some states =>
            let asked (state : EditorState) : EditorState := { state with quitting := true }
            (asked states.bare).leaves && (asked states.saved).leaves &&
              !(asked states.saving).leaves &&
              !(asked states.held).leaves &&
              !(asked states.moved).leaves &&
              !states.bare.leaves &&
              !states.saved.leaves },
    { name :=
        "a quit that cannot go ahead is withdrawn: a state asked to quit while a buffer has unsaved changes is no longer asked, and is otherwise as it was; one asked with nothing unsaved, a save in flight among them, stays asked; one that was not asked is as it was"
      run :=
        pure <|
          match onTextModel quitStates with
          | none => false
          | some states =>
            let asked (state : EditorState) : EditorState := { state with quitting := true }
            (asked states.held).settleQuit == states.held &&
              (asked states.moved).settleQuit == states.moved &&
              (asked states.saving).settleQuit == asked states.saving &&
              (asked states.bare).settleQuit == asked states.bare &&
              (asked states.saved).settleQuit == asked states.saved &&
              states.held.settleQuit == states.held }]

/-- `twoBuffers` with a third buffer, `hidden`, over a text of its own that
no window shows, and that text. -/
def hiddenBuffer : TextM (EditorState × TextId) := do
  let state ← twoBuffers
  let text ← createText "hidden"
  let history ← UndoTree.over text
  return ({ state with buffers := state.buffers.push (some { name := "hidden", text, history }) },
      text)

/-- The path of a file of the state checks. Nothing opens it. -/
def notePath : System.FilePath :=
  "/files/note.txt"

/-- A stamp of the state checks: any one, for a file the checks say a
buffer holds. -/
def noteStamp : File.Stamp :=
  { seconds := 3, nanoseconds := 0, size := 9 }

/-- The requests a well-formed state is seen to stay well formed under, on
`hiddenBuffer`, whose buffers' texts are 0, 1 and 2: each kind of request,
accepted and refused. -/
def stateRequests : List StateRequest :=
  let marker (text index : Nat) : MarkerId := ⟨⟨text⟩, index⟩
  [.read, .addBuffer "new" ⟨3⟩ (UndoTree.new ⟨3⟩ 0), .addBuffer "other" ⟨3⟩ (UndoTree.new ⟨3⟩ 0),
    .removeBuffer ⟨2⟩, .removeBuffer ⟨1⟩, .removeBuffer ⟨9⟩, .setHistory ⟨0⟩ (UndoTree.new ⟨0⟩ 4),
    .setHistory ⟨0⟩ (UndoTree.new ⟨1⟩ 0), .setValue ⟨0⟩ "count" (.nat 1),
    .setValue ⟨9⟩ "count" .null, .setMajorMode ⟨0⟩ "listing", .setMajorMode ⟨9⟩ "listing",
    .addMinorMode ⟨1⟩ "one", .removeMinorMode ⟨1⟩ "one", .split ⟨0⟩ .rows (marker 0 8) (marker 0 9),
    .split ⟨1⟩ .columns (marker 1 8) (marker 1 9), .split ⟨0⟩ .rows (marker 1 8) (marker 0 9),
    .split ⟨9⟩ .rows (marker 0 8) (marker 0 9), .removeWindow ⟨1⟩, .removeWindow ⟨9⟩, .focus ⟨1⟩,
    .focus ⟨9⟩, .show ⟨0⟩ ⟨2⟩ (marker 2 0) (marker 2 1), .show ⟨0⟩ ⟨9⟩ (marker 2 0) (marker 2 1),
    .show ⟨0⟩ ⟨2⟩ (marker 0 0) (marker 2 1), .show ⟨9⟩ ⟨2⟩ (marker 2 0) (marker 2 1), .message "hi",
    .startJob "count" [.nat 1], .attachFile ⟨2⟩ notePath noteStamp .crlf,
    .attachFile ⟨9⟩ notePath noteStamp .lf, .beginSave ⟨0⟩ ⟨4⟩ ⟨0⟩, .beginSave ⟨9⟩ ⟨4⟩ ⟨0⟩,
    .endSave ⟨0⟩ ⟨4⟩ (some noteStamp), .endSave ⟨9⟩ ⟨4⟩ none,
    .openPrompt "Name: " asked ⟨8⟩ (UndoTree.new ⟨8⟩ 0) (marker 8 0) (marker 8 1),
    .openPrompt "Name: " asked ⟨8⟩ (UndoTree.new ⟨8⟩ 0) (marker 0 0) (marker 8 1),
    .closePrompt none, .closePrompt (some "typed"),
    .setWanted ⟨0⟩ (some { column := .cells 3, head := 7 }), .setWanted ⟨1⟩ none,
    .setWanted ⟨9⟩ (some { column := .lineEnd, head := 0 }), .ex "w", .invoke asked, .quit, .reload,
    .giveUp "no", .breakOff "far enough", .setRegister "a" { text := "a line\n", linewise := true }]

/-- The checks of the state requests' pure handler (`EditorState.handle`,
`Editor/State/Request.lean`), on states made on the text model. The handler
asks the text store nothing, so a marker's id is written out by hand. -/
def stateRequestChecks : List Check :=
  let marker (text index : Nat) : MarkerId := ⟨⟨text⟩, index⟩
  [{  name := "a read hands back the whole state and changes nothing"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (read, after) := state.handle .read
            read == state && after == state },
    { name :=
        "adding a buffer gives it the next slot's id and finds it by its name; a name a buffer has is refused with nameTaken, and a history over another text with notItsHistory, each with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let tree := UndoTree.new ⟨2⟩ 0
            let (added, after) := state.handle (.addBuffer "third" ⟨2⟩ tree)
            let (taken, same) := state.handle (.addBuffer "other" ⟨2⟩ tree)
            let (astray, still) := state.handle (.addBuffer "third" ⟨3⟩ tree)
            replied added == .inr ⟨2⟩ && after.findBuffer "third" == some ⟨2⟩ &&
              after.buffer? ⟨2⟩ == some { name := "third", text := ⟨2⟩, history := tree } &&
              state.findBuffer "third" == none &&
              state.findBuffer "other" == some ⟨1⟩ &&
              replied taken == .inl (.nameTaken "other") &&
              same == state &&
              replied astray == .inl .notItsHistory &&
              still == state },
    { name :=
        "removing a buffer empties its slot, and its id is not given to the next buffer; a buffer a window shows is refused with shown and that view, and one there is none of with noSuchBuffer, each with the state as it was"
      run :=
        pure <|
          match onTextModel hiddenBuffer with
          | none => false
          | some (state, _) =>
            let (removed, after) := state.handle (.removeBuffer ⟨2⟩)
            let (again, gone) := after.handle (.removeBuffer ⟨2⟩)
            let (next, _) := after.handle (.addBuffer "next" ⟨3⟩ (UndoTree.new ⟨3⟩ 0))
            let (shown, same) := state.handle (.removeBuffer ⟨1⟩)
            let (absent, still) := state.handle (.removeBuffer ⟨9⟩)
            replied removed == .inr () && after.buffers[2]? == some none &&
              after.buffer? ⟨2⟩ == none &&
              after.findBuffer "hidden" == none &&
              after.buffers.size == 3 &&
              replied again == .inl (.noSuchBuffer ⟨2⟩) &&
              gone == after &&
              replied next == .inr ⟨3⟩ &&
              replied shown == .inl (.shown ⟨1⟩) &&
              same == state &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              still == state },
    { name :=
        "setting a buffer's history replaces its tree; a tree over another text is refused with notItsHistory, and a buffer there is none of with noSuchBuffer, each with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let tree := UndoTree.new ⟨1⟩ 7
            let (set, after) := state.handle (.setHistory ⟨1⟩ tree)
            let (astray, same) := state.handle (.setHistory ⟨0⟩ tree)
            let (absent, still) := state.handle (.setHistory ⟨9⟩ tree)
            replied set == .inr () && (after.buffer? ⟨1⟩).map (·.history) == some tree &&
              after.buffer? ⟨0⟩ == state.buffer? ⟨0⟩ &&
              replied astray == .inl .notItsHistory &&
              same == state &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              still == state },
    { name :=
        "a buffer-local value is set under its name and read back, a second value of the name replaces the first, and other names and other buffers are left; a buffer there is none of is refused with noSuchBuffer"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (set, one) := state.handle (.setValue ⟨1⟩ "count" (.nat 1))
            let (_, two) := one.handle (.setValue ⟨1⟩ "label" (.str "a"))
            let (_, three) := two.handle (.setValue ⟨1⟩ "count" (.nat 2))
            let (absent, same) := state.handle (.setValue ⟨9⟩ "count" (.nat 1))
            replied set == .inr () && state.value? ⟨1⟩ "count" == none &&
              one.value? ⟨1⟩ "count" == some (.nat 1) &&
              three.value? ⟨1⟩ "count" == some (.nat 2) &&
              three.value? ⟨1⟩ "label" == some (.str "a") &&
              ((three.buffer? ⟨1⟩).map (·.locals.size)) == some 2 &&
              three.value? ⟨0⟩ "count" == none &&
              three.value? ⟨9⟩ "count" == none &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              same == state },
    { name :=
        "the minor-mode requests are the state's operations: one added is first, one removed is gone, and a buffer there is none of is refused with noSuchBuffer"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (added, one) := state.handle (.addMinorMode ⟨0⟩ "one")
            let (removed, bare) := one.handle (.removeMinorMode ⟨0⟩ "one")
            let (absent, same) := state.handle (.addMinorMode ⟨9⟩ "one")
            replied added == .inr () && one == (state.addMinorMode ⟨0⟩ "one").2 &&
              ((one.buffer? ⟨0⟩).map (·.minors)) == some #["one"] &&
              replied removed == .inr () &&
              bare == state &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              same == state },
    { name :=
        "the major-mode request sets the mode of the buffer its view shows and says whether it became the major mode; a view with no window is refused with noSuchWindow, with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (set, listed) := state.handle (.setMajorMode ⟨1⟩ "listing")
            let (again, same) := listed.handle (.setMajorMode ⟨1⟩ "listing")
            let (absent, still) := state.handle (.setMajorMode ⟨9⟩ "listing")
            replied set == .inr true && listed == (state.setMajorMode ⟨1⟩ "listing").2 &&
              ((listed.buffer? ⟨1⟩).bind (·.major)) == some "listing" &&
              replied again == .inr false &&
              same == listed &&
              replied absent == .inl (.noSuchWindow ⟨9⟩) &&
              still == state },
    { name :=
        "a split gives the new window an id no window has or had, shows the source window's buffer in it with the markers handed in, puts it second in a split where the source was, and leaves the focus"
      run :=
        pure <|
          match onTextModel threeWindows with
          | none => false
          | some state =>
            let (made, after) := state.handle (.split ⟨1⟩ .rows (marker 0 8) (marker 0 9))
            let (closed, without) := after.handle (.removeWindow ⟨3⟩)
            let (next, later) := without.handle (.split ⟨0⟩ .columns (marker 0 10) (marker 0 11))
            replied made == .inr ⟨3⟩ && after.wellFormed &&
              after.window? ⟨3⟩ ==
                some { id := ⟨3⟩, buffer := ⟨0⟩, scroll := marker 0 8, selection := marker 0 9 } &&
              after.frame.tree ==
                .split .rows
                  (.split .columns (.window ⟨0⟩) (.split .rows (.window ⟨1⟩) (.window ⟨3⟩)))
                  (.split .rows (.window ⟨2⟩) .minibuffer) &&
              after.frame.focused == state.frame.focused &&
              after.windows.extract 0 3 == state.windows &&
              (replied closed).isRight &&
              replied next == .inr ⟨4⟩ &&
              later.frame.tree ==
                .split .rows
                  (.split .columns (.split .columns (.window ⟨0⟩) (.window ⟨4⟩)) (.window ⟨1⟩))
                  (.split .rows (.window ⟨2⟩) .minibuffer) },
    { name :=
        "a split is refused with noSuchWindow for a view with no window, and with markersOfAnotherText when a marker handed in is not of the source buffer's text, each with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (absent, same) := state.handle (.split ⟨9⟩ .rows (marker 0 8) (marker 0 9))
            let (scroll, still) := state.handle (.split ⟨0⟩ .rows (marker 1 8) (marker 0 9))
            let (selection, yet) := state.handle (.split ⟨0⟩ .rows (marker 0 8) (marker 1 9))
            replied absent == .inl (.noSuchWindow ⟨9⟩) && same == state &&
              replied scroll == .inl .markersOfAnotherText &&
              still == state &&
              replied selection == .inl .markersOfAnotherText &&
              yet == state },
    { name :=
        "splitting a window and removing the new window gives back the tree, the windows and the focus from before the split, along either axis and from one window or three"
      run :=
        pure <|
          [onTextModel threeWindows, onTextModel (EditorState.initial ⟨640, 480⟩)].all fun
            | none => false
            | some state =>
              [Axis.rows, Axis.columns].all fun axis =>
                state.windows.all fun window =>
                  let (made, split) :=
                    state.handle (.split window.id axis (marker 0 8) (marker 0 9))
                  match made with
                  | .error _ => false
                  | .ok view =>
                    let (closed, after) := split.handle (.removeWindow view)
                    split.frame.tree != state.frame.tree && (replied closed).isRight &&
                      after.frame == state.frame &&
                      after.windows == state.windows &&
                      after.buffers == state.buffers },
    { name :=
        "the request to remove the only window is refused with onlyWindow, and the tree and the state are as they were"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            let (closed, after) := state.handle (.removeWindow ⟨0⟩)
            replied closed == .inl .onlyWindow && after.frame.tree == state.frame.tree &&
              after == state },
    { name :=
        "the focus request focuses a window in the tree, and refuses one that is not with noSuchWindow"
      run :=
        pure <|
          match onTextModel threeWindows with
          | none => false
          | some state =>
            let (focused, after) := state.handle (.focus ⟨2⟩)
            let (absent, same) := state.handle (.focus ⟨9⟩)
            replied focused == .inr () && after.frame.focused == ⟨2⟩ &&
              after == (state.focusWindow ⟨2⟩).2 &&
              replied absent == .inl (.noSuchWindow ⟨9⟩) &&
              same == state },
    { name :=
        "showing another buffer in a window sets its buffer and its markers and leaves the other windows; a buffer there is none of is refused with noSuchBuffer, a view with no window with noSuchWindow, and a marker of another text with markersOfAnotherText, each with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (shown, after) := state.handle (.show ⟨0⟩ ⟨1⟩ (marker 1 8) (marker 1 9))
            let (absent, same) := state.handle (.show ⟨0⟩ ⟨9⟩ (marker 1 8) (marker 1 9))
            let (unseen, still) := state.handle (.show ⟨9⟩ ⟨1⟩ (marker 1 8) (marker 1 9))
            let (astray, yet) := state.handle (.show ⟨0⟩ ⟨1⟩ (marker 0 8) (marker 1 9))
            replied shown == .inr () && after.wellFormed &&
              after.window? ⟨0⟩ ==
                some { id := ⟨0⟩, buffer := ⟨1⟩, scroll := marker 1 8, selection := marker 1 9 } &&
              after.window? ⟨1⟩ == state.window? ⟨1⟩ &&
              after.frame == state.frame &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              same == state &&
              replied unseen == .inl (.noSuchWindow ⟨9⟩) &&
              still == state &&
              replied astray == .inl .markersOfAnotherText &&
              yet == state },
    { name :=
        "the wanted-column request is the state's operation: the window keeps the column and the head, none clears it, and a view with no window is refused with noSuchWindow, with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let kept : Window.Wanted := { column := .cells 3, head := 7 }
            let (set, after) := state.handle (.setWanted ⟨1⟩ (some kept))
            let (cleared, bare) := after.handle (.setWanted ⟨1⟩ none)
            let (absent, same) := state.handle (.setWanted ⟨9⟩ (some kept))
            replied set == .inr () && after == (state.setWanted ⟨1⟩ (some kept)).2 &&
              (after.window? ⟨1⟩).map (·.wanted) == some (some kept) &&
              after.window? ⟨0⟩ == state.window? ⟨0⟩ &&
              replied cleared == .inr () &&
              bare == state &&
              replied absent == .inl (.noSuchWindow ⟨9⟩) &&
              same == state },
    { name := "a message sets the echo area's text, and the last of two is the one kept"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let ((), one) := state.handle (.message "first")
            let ((), two) := one.handle (.message "second")
            one == { state with echo := "first" } && two == { state with echo := "second" } },
    { name :=
        "a request to start a job is appended to the state's starts, with its name and its arguments, in order"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (first, one) := state.handle (.startJob "count" [.nat 3])
            let (_, two) := one.handle (.startJob "load" [.str "a", .bool true])
            replied first == .inr () && state.starts == #[] &&
              two.starts ==
                #[{ name := "count", arguments := [.nat 3] },
                  { name := "load", arguments := [.str "a", .bool true] }] &&
              { two with starts := #[] } == state },
    { name :=
        "attaching a file to a buffer sets its path, its stamp and its line ending, with no save in flight, and leaves the rest of the buffer and the other buffers; the buffer is then found by that path and by no other"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (attached, after) := state.handle (.attachFile ⟨1⟩ notePath noteStamp .crlf)
            replied attached == .inr () &&
              (after.buffer? ⟨1⟩) ==
                (state.buffer? ⟨1⟩).map
                  ({ · with
                    file := some { path := notePath, stamp := noteStamp }, lineEnding := .crlf }) &&
              ((after.buffer? ⟨1⟩).bind (·.file)).map (·.saving) == some none &&
              after.buffer? ⟨0⟩ == state.buffer? ⟨0⟩ &&
              after.findFile notePath == some ⟨1⟩ &&
              after.findFile "/files/other.txt" == none &&
              after.findFile "/files/../files/note.txt" == none &&
              state.findFile notePath == none &&
              { after with buffers := state.buffers } == state },
    { name :=
        "attaching a file is refused with noSuchBuffer for a buffer there is none of, and with fileOpen and the buffer that holds the path when another buffer does, each with the state as it was; attaching the path a buffer holds to that buffer again replaces its stamp and its line ending"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let later : File.Stamp :=
              { noteStamp with
                seconds := 9, size := 12 }
            let (_, held) := state.handle (.attachFile ⟨1⟩ notePath noteStamp .crlf)
            let (absent, same) := state.handle (.attachFile ⟨9⟩ notePath noteStamp .lf)
            let (taken, still) := held.handle (.attachFile ⟨0⟩ notePath later .lf)
            let (unseen, yet) := held.handle (.attachFile ⟨9⟩ notePath later .lf)
            let (again, replaced) := held.handle (.attachFile ⟨1⟩ notePath later .lf)
            replied absent == .inl (.noSuchBuffer ⟨9⟩) && same == state &&
              replied taken == .inl (.fileOpen ⟨1⟩) &&
              still == held &&
              replied unseen == .inl (.noSuchBuffer ⟨9⟩) &&
              yet == held &&
              replied again == .inr () &&
              ((replaced.buffer? ⟨1⟩).map fun buffer => (buffer.file, buffer.lineEnding)) ==
                some (some { path := notePath, stamp := later }, .lf) &&
              replaced.findFile notePath == some ⟨1⟩ },
    { name :=
        "beginning a save of a buffer with a file records the snapshot and the state as the save in flight and leaves the rest; it is refused with noFile for a buffer with no file, with beingSaved while a save is in flight and with noSuchBuffer, each with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, held) := state.handle (.attachFile ⟨1⟩ notePath noteStamp .crlf)
            let (begun, saving) := held.handle (.beginSave ⟨1⟩ ⟨5⟩ ⟨3⟩)
            let (bare, same) := held.handle (.beginSave ⟨0⟩ ⟨5⟩ ⟨3⟩)
            let (twice, still) := saving.handle (.beginSave ⟨1⟩ ⟨6⟩ ⟨4⟩)
            let (absent, yet) := held.handle (.beginSave ⟨9⟩ ⟨5⟩ ⟨3⟩)
            replied begun == .inr () &&
              (saving.buffer? ⟨1⟩) ==
                (held.buffer? ⟨1⟩).map
                  ({ · with
                    file :=
                      some
                        { path := notePath, stamp := noteStamp
                          saving := some { snapshot := ⟨5⟩, state := ⟨3⟩ } } }) &&
              { saving with buffers := held.buffers } == held &&
              replied bare == .inl .noFile &&
              same == held &&
              replied twice == .inl .beingSaved &&
              still == saving &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              yet == held },
    { name :=
        "ending a save with a stamp clears the save in flight, records the stamp, and marks the state the save kept as saved: a buffer still in that state is no longer modified, and one whose text has moved on since still is; ending it with no stamp clears the save in flight and changes neither the stamp nor the saved state"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let later : File.Stamp :=
              { noteStamp with
                seconds := 9, size := 12 }
            let edited := (UndoTree.new ⟨1⟩ 0).record 3
            let (_, held) := state.handle (.attachFile ⟨1⟩ notePath noteStamp .crlf)
            let (_, held) := held.handle (.setHistory ⟨1⟩ edited)
            let (_, saving) := held.handle (.beginSave ⟨1⟩ ⟨5⟩ edited.state)
            let (ended, saved) := saving.handle (.endSave ⟨1⟩ ⟨5⟩ (some later))
            let (_, moved) := saving.handle (.setHistory ⟨1⟩ (edited.record 4))
            let (_, late) := moved.handle (.endSave ⟨1⟩ ⟨5⟩ (some later))
            let (refused, unsaved) := saving.handle (.endSave ⟨1⟩ ⟨5⟩ none)
            let seen (state : EditorState) :=
              (state.buffer? ⟨1⟩).map fun buffer =>
                (buffer.file, buffer.isModified, buffer.history.saved)
            seen held == some (some { path := notePath, stamp := noteStamp }, true, some ⟨0⟩) &&
              replied ended == .inr () &&
              seen saved == some (some { path := notePath, stamp := later }, false, some ⟨3⟩) &&
              (saved.buffer? ⟨1⟩).map (·.history) == some (edited.markSaved edited.state) &&
              { saved with buffers := held.buffers } == held &&
              seen late == some (some { path := notePath, stamp := later }, true, some ⟨3⟩) &&
              replied refused == .inr () &&
              unsaved == held },
    { name :=
        "ending a save with no stamp withdraws a quit that was asked: the state is no longer asked to quit, whether or not the buffer is modified, and is otherwise as it was before the save began; ending it with a stamp leaves the state asked"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let asked (state : EditorState) : EditorState := { state with quitting := true }
            let edited := (UndoTree.new ⟨1⟩ 0).record 3
            let (_, clean) := state.handle (.attachFile ⟨1⟩ notePath noteStamp .crlf)
            let (_, held) := clean.handle (.setHistory ⟨1⟩ edited)
            let ends (held : EditorState) (stamp : Option File.Stamp) : EditorState :=
              let history := ((held.buffer? ⟨1⟩).map (·.history.state)).getD ⟨0⟩
              let (_, saving) := held.handle (.beginSave ⟨1⟩ ⟨5⟩ history)
              ((asked saving).handle (.endSave ⟨1⟩ ⟨5⟩ stamp)).2
            (clean.buffer? ⟨1⟩).map (·.isModified) == some false &&
              (held.buffer? ⟨1⟩).map (·.isModified) == some true &&
              ends clean none == clean &&
              ends held none == held &&
              (ends clean (some noteStamp)).quitting &&
              (ends held (some noteStamp)).quitting },
    { name :=
        "ending a save is refused with notBeingSaved for a snapshot that is not the one of the save in flight, for a buffer with no save in flight and for one with no file, and with noSuchBuffer, each with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, held) := state.handle (.attachFile ⟨1⟩ notePath noteStamp .crlf)
            let (_, saving) := held.handle (.beginSave ⟨1⟩ ⟨5⟩ ⟨3⟩)
            let (other, same) := saving.handle (.endSave ⟨1⟩ ⟨6⟩ (some noteStamp))
            let (idle, still) := held.handle (.endSave ⟨1⟩ ⟨5⟩ (some noteStamp))
            let (bare, yet) := saving.handle (.endSave ⟨0⟩ ⟨5⟩ none)
            let (absent, last) := saving.handle (.endSave ⟨9⟩ ⟨5⟩ none)
            replied other == .inl .notBeingSaved && same == saving &&
              replied idle == .inl .notBeingSaved &&
              still == held &&
              replied bare == .inl .notBeingSaved &&
              yet == saving &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              last == saving },
    { name :=
        "the request to open a prompt is the state's operation: it replies the minibuffer's view and leaves the prompt open, and a second is refused with alreadyOpen, a value, with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let request : StateRequest :=
              .openPrompt "Name: " asked ⟨7⟩ (UndoTree.new ⟨7⟩ 0) (marker 7 0) (marker 7 1)
            let (made, asking) := state.handle request
            let (again, same) := asking.handle request
            replied made == .inr ⟨2⟩ && asking == (prompted state).2 && asking.prompt.isSome &&
              replied again == .inl (.alreadyOpen ⟨2⟩) &&
              same == asking },
    { name :=
        "the request to close a prompt is the state's operation, with an answer and with none, and with no prompt open it is refused with notOpen, a value"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, asking) := prompted state
            let (cancelled, without) := asking.handle (.closePrompt none)
            let (accepted, answered) := asking.handle (.closePrompt (some "a"))
            let (refused, same) := state.handle (.closePrompt (some "a"))
            replied cancelled == .inr () && without == (asking.closePrompt none).2 &&
              without.prompt == none &&
              replied accepted == .inr () &&
              answered == (asking.closePrompt (some "a")).2 &&
              answered.answered.size == 1 &&
              replied refused == .inl .notOpen &&
              same == state },
    { name :=
        "the handler knows no registry: asked which command an ex name is bound to, it answers none for any name, and leaves the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            ["w", "greet", ""].all fun name =>
              let (bound, after) := state.handle (.ex name)
              bound == none && after == state },
    { name :=
        "the request to have an invocation run next records it after what is recorded, the answer of a prompt that was closed among it, and changes nothing else"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let first : Invocation := { command := "one", arguments := [.str "a"] }
            let second : Invocation := { command := "two" }
            let (_, once) := state.handle (.invoke first)
            let (_, twice) := once.handle (.invoke second)
            let (_, asking) := prompted state
            let (_, answered) := asking.handle (.closePrompt (some "typed"))
            let (_, after) := answered.handle (.invoke second)
            once.answered == #[first] && twice.answered == #[first, second] &&
              { twice with answered := #[] } == state &&
              after.answered == answered.answered.push second &&
              answered.answered.size == 1 },
    { name :=
        "the request to quit sets the state's flag that the editor was asked to quit and changes nothing else; asked again, the state is as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, asked) := state.handle .quit
            let (_, again) := asked.handle .quit
            !state.quitting && asked.quitting && { asked with quitting := false } == state &&
              again == asked },
    { name :=
        "the request to reload the config sets the state's flag that a reload was asked for and changes nothing else"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, asked) := state.handle .reload
            !state.reload && asked.reload && { asked with reload := false } == state },
    { name :=
        "the request by which a command gives up changes nothing of the state: the handler knows no command to end, and the state after it is the state before"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, after) := state.handle (.giveUp "no such thing")
            after == state },
    { name :=
        "the request by which a command breaks off changes nothing of the state either: the handler knows no command to end"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, after) := state.handle (.breakOff "far enough")
            after == state },
    { name :=
        "the request to set a register sets the register of that name, in place of the one the name had, and changes nothing else of the state"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let word : Register := { text := "word" }
            let line : Register := { text := "a line\n", linewise := true }
            let (_, set) := state.handle (.setRegister "a" word)
            let (_, replaced) := set.handle (.setRegister "a" line)
            state.register? "a" == none && set.register? "a" == some word &&
              set == state.setRegister "a" word &&
              replaced.register? "a" == some line &&
              { replaced with registers := #[] } == state },
    { name :=
        "every kind of request, accepted and refused, leaves a well-formed state well formed, with no prompt open and with one open, and the state with nothing in it answers each without a buffer or a window"
      run := do
        let some (state, _) := onTextModel hiddenBuffer | return false
        let (_, asking) := prompted state
        let spoiled :=
          [state, asking].flatMap fun start =>
            stateRequests.filter fun request => !(start.handle request).2.wellFormed
        unless spoiled.isEmpty do
          throw
              (IO.userError
                s!"{spoiled.length} of the requests left a state that is not well formed")
        let (read, _) := EditorState.none.handle .read
        return state.wellFormed && asking.wellFormed && asking.prompt.isSome &&
            read.buffers.isEmpty &&
            read.windows.isEmpty &&
            stateRequests.all fun request =>
              let (_, after) := EditorState.none.handle request
              after.windows.isEmpty && after.frame == EditorState.none.frame }]

/-- The loop the model tests run: one over the test scheme. -/
abbrev TestLoop :=
  Loop TestScheme.scheme

/-- One step of `loop` with no keymap: the loop after `event` and what the
step said to do next, for the checks that look at nothing else of a step. -/
def stepped (loop : TestLoop) (event : Event) : EditorM (TestLoop × Loop.Next) := do
  let after ← loop.step {} event
  return (after.loop, after.next)

/-- Starts a loop from the state `start` makes, feeds it `events` in order,
and returns the loop and what each step said to do next. -/
def stepsFrom (start : TextM EditorState) (events : List Event) :
    EditorM (TestLoop × Array Loop.Next) := do
  let mut loop : TestLoop := { state := ← start }
  let mut nexts := #[]
  for event in events do
    let (next, said) ← stepped loop event
    loop := next
    nexts := nexts.push said
  return (loop, nexts)

/-- What a run of the loop on the editor's models came to: the loop and what
each step said, the scenes the display recorded, and the models. `none` when
it was refused. -/
def looped (start : TextM EditorState) (events : List Event) :
    Option ((TestLoop × Array Loop.Next) × Array Scene × EditorModel) :=
  match (stepsFrom start events).runModel editorModel with
  | (.ok result, model) => some (result, model.display.scenes, model)
  | (.error _, _) => none

/-- The initial state at 640 by 480 with a prompt open, asked from view 0 with
the label `Name: ` and the continuation `asked`: the minibuffer is view 1,
over a text of its own holding `text`, with a scroll anchor at its start
and one cursor after `text`. -/
def promptedOver (text : String) : TextM EditorState := do
  let state ← EditorState.initial ⟨640, 480⟩
  let made ← createText text
  let scroll ← made.mark (.anchor { offset := 0, bias := .before })
  let selection ← made.mark (.selection { ranges := #[⟨text.utf8ByteSize, text.utf8ByteSize⟩] })
  return (state.openPrompt "Name: " asked made (← UndoTree.over made) scroll selection).2

/-- A press of a key that no keymap binds and that prints nothing, with its
physical code as a window reports it: the loop steps it through its scheme,
which yields nothing for it. -/
def pressF5 : Event :=
  .key { logical := .named ⟨"F5"⟩, physical := .code "F5" } true ""

/-- The text of the snapshot a view shows, as the text model holds it. -/
def shownText (model : EditorModel) (view : View) : Option String :=
  (model.texts.snapshots[view.snapshot.index]?).join.map (·.contents)

/-- A report of the scheme `switching`, unlike the default in every field
the scene shows: a block in a face of its own, one status field, an
inclusive selection, and selecting. -/
def markedReport : InputScheme.Report :=
  { cursor := { shape := .block, face := ⟨"cursor.marked"⟩ }
    status := #[{ text := "marked", face := ⟨"status.marked"⟩ }]
    shape := .inclusive
    selecting := true }

/-- What the scheme `switching` reports of a view it was told is the
minibuffer's: an underline in a face of its own, and one status field. -/
def askedReport : InputScheme.Report :=
  { cursor := { shape := .underline, face := ⟨"cursor.asked"⟩ }
    status := #[{ text := "asked", face := ⟨"status.asked"⟩ }] }

/-- The reports the scheme `switching` switches a view between: a command's
name, the key string a loop over it binds to that command, and what the
scheme reports of a view once a key for the view has yielded an invocation
of the command. The keys print nothing. -/
def switchingTable : List (String × String × InputScheme.Report) :=
  [("mark", "C-m", markedReport), ("plain", "C-p", {}), ("begin", "C-b", { session := true }),
    ("end", "C-e", {}), ("deafen", "C-d", { takesText := false })]

/-- A scheme written for the loop's checks, so that none of them names a
shipped scheme's states or keys: the test scheme, with a report of each
view that an invocation it yields switches (`switchingTable`). A view
starts with the default report, a view told to be the minibuffer's has
`askedReport`, and a closed view's is forgotten. Its state is the test
scheme's, and the report of each view that has one. -/
def switching : InputScheme :=
  { State := TestScheme.State × List (ViewId × InputScheme.Report)
    Binding := Invocation
    init := ({}, [])
    step := fun maps view state key =>
      let (next, yielded) := TestScheme.step maps view state.1 key
      match yielded.bind fun invocation => switchingTable.find? (·.1 == invocation.command) with
      | some (_, _, report) => ((next, (view, report) :: state.2.filter (·.1 != view)), yielded)
      | none => ((next, state.2), yielded)
    pending := (·.1.pending)
    command := fun name => { command := name }
    roles := TestScheme.roles
    leader := TestScheme.leader
    closeView := fun view state => (state.1, state.2.filter (·.1 != view))
    openMinibuffer := fun view state => (state.1, (view, askedReport) :: state.2)
    report := fun state view => ((state.2.find? (·.1 == view)).map (·.2)).getD {} }

/-- What a step of a loop over `switching` is handed: one keymap, the same
for every view, that binds each key of `switchingTable` to its command and
each key string of `bindings` to the invocation beside it; and commands,
one that does nothing under each name of `switchingTable`, and
`commands`. -/
def switchingKeys (bindings : List (String × Invocation) := [])
    (commands : List (String × (Call → EditorM (Option Config.Write))) := []) :
    Loop.Keys switching :=
  { maps := fun _ _ =>
      [Keymap.ofList
          ((switchingTable.map fun (name, text, _) => (keys text, invoke name)) ++
            bindings.map fun (text, invocation) => (keys text, invocation))]
    command? := fun name =>
      match commands.find? (·.1 == name) with
      | some (_, command) => some command
      | none => if switchingTable.any (·.1 == name) then some fun _ => pure none else none }

/-- A loop over `switching` started from the state `start` makes and fed the
presses of the keys `text` names and then `events`, each step handed
`handed`, on the editor's models: the loop after them, the scenes the
display recorded, and the models. `none` when it was refused. -/
def switched (start : TextM EditorState) (text : String) (events : List Event := [])
    (handed : Loop.Keys switching := switchingKeys) :
    Option (Loop switching × Array Scene × EditorModel) :=
  let program : EditorM (Loop switching) := do
    let mut loop : Loop switching := { state := ← start }
    for event in (keys text).map (Event.key · true "") ++ events do
      loop := (← loop.step handed event).loop
    return loop
  match program.runModel editorModel with
  | (.ok loop, model) => some (loop, model.display.scenes, model)
  | (.error _, _) => none

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
            let some buffer := state.buffer? ⟨0⟩ | throw .noSuchText
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
              match loop.state.buffer? ⟨0⟩ with
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
        "a press of a key that is bound to nothing and prints nothing, a pointer and the window opening leave the state as it was, and each publishes one scene"
      run :=
        pure <|
          let events : List Event :=
            [pressF5, .pointer { action := .press, x := 3.0, y := 4.0, button := some .primary },
              .windowOpened "headless"]
          let start : EditorM (EditorState × TestLoop × Array Loop.Next) := do
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
          match looped threeWindows [pressF5, pressF5] with
          | some (_, #[first, second], model) =>
            first.views.map (·.snapshot) == second.views.map (·.snapshot) &&
              (first.views.map (·.snapshot)).toList.eraseDups.length == 1 &&
              second.views.all fun view => shownText model view == some ""
          | _ => false },
    { name :=
        "a view shows its window's scroll anchor and selection marker, a bar cursor in the face cursor, no decorations, and a status line of one field, its buffer's name in the name's face"
      run :=
        pure <|
          match looped threeWindows [pressF5] with
          | some ((loop, _), #[scene], _) =>
            let named :=
              (loop.state.buffer? ⟨0⟩).map fun buffer =>
                #[({ text := buffer.name, face := Loop.nameFace } : StatusField)]
            scene.views.map (·.scroll) == loop.state.windows.map (·.scroll) &&
              scene.views.map (·.selections) == loop.state.windows.map (#[·.selection]) &&
              scene.views.all fun view =>
                view.cursor == { shape := .bar, face := ⟨"cursor"⟩ } && view.decorations.isEmpty &&
                  some view.status == named
          | _ => false },
    { name :=
        "a view's status line carries the modified field while its buffer is modified, and not otherwise: the first scene's views have the name alone, after a commit each view of the buffer has the name and then the modified mark in the modified face, and after a key whose command undoes the commit each has the name alone again"
      run :=
        pure <|
          let undoKeys : Loop.Keys TestScheme.scheme :=
            { maps := fun _ _ => [Keymap.ofList [(keys "C-z", invoke "undo")]]
              command? := fun name =>
                if name == "undo" then
                  some fun call => do
                    discard <| call.target.window.buffer.undo
                    return none
                else none }
          let program : EditorM TestLoop := do
            let mut loop : TestLoop := { state := ← threeWindows }
            for event in [pressF5, .commit "x"] ++ (keys "C-z").map (Event.key · true "") do
              loop := (← loop.step undoKeys event).loop
            return loop
          match program.runModel editorModel with
          | (.ok loop, model) =>
            match loop.state.buffer? ⟨0⟩ with
            | none => false
            | some buffer =>
              let name : StatusField := { text := buffer.name, face := Loop.nameFace }
              let modified : StatusField := { text := Loop.modifiedMark, face := Loop.modifiedFace }
              model.texts.contents == #[""] &&
                model.display.scenes.map (fun scene => scene.views.map (·.status)) ==
                  #[.replicate 3 #[name], .replicate 3 #[name, modified], .replicate 3 #[name]]
          | (.error _, _) => false },
    { name :=
        "a commit once the focused buffer's text was released is not refused: it publishes a scene with the refusal in its echo and no view of that buffer, and the loop keeps the state as it was, well formed, with that echo"
      run :=
        pure <|
          let program : EditorM (EditorState × TestLoop × Loop.Next) := do
            let state ← EditorState.initial ⟨640, 480⟩
            let some target := state.focusedTarget? | throw .noSuchMarker
            target.buffer.text.release
            let (loop, next) ← stepped { state } (.commit "x")
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
          let program : EditorM (EditorState × TestLoop × String) := do
            let state ← twoBuffers
            let some gone := state.buffer? ⟨0⟩ | throw .noSuchMarker
            let some other := state.buffer? ⟨1⟩ | throw .noSuchMarker
            gone.text.release
            other.text.insert 5 "!"
            let (loop, _) ← stepped { state } pressF5
            -- The loop recorded the insertion in the other buffer's history:
            -- one undo of it takes the insertion back.
            let some kept := loop.state.buffer? ⟨1⟩ | throw .noSuchMarker
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
          let hidden : EditorM TestLoop := do
            let state ← EditorState.initial ⟨640, 480⟩
            let text ← createText "hidden"
            let history ← UndoTree.over text
            text.release
            let state :=
              { state with
                buffers := state.buffers.push (some { name := "hidden", text, history }) }
            return (← stepped { state } pressF5).1
          -- A buffer whose history is over another text than its own: the
          -- history is recorded, and only the view is refused.
          let astray : EditorM TestLoop := do
            let state ← EditorState.initial ⟨640, 480⟩
            let some buffer := state.buffer? ⟨0⟩ | throw .noSuchMarker
            let history ← UndoTree.over (← createText "elsewhere")
            buffer.text.release
            let state := { state with buffers := #[some { buffer with history }] }
            return (← stepped { state } pressF5).1
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
          let program : EditorM (TestLoop × String × Bool) := do
            let mut loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
            loop := (← stepped loop (.commit "a")).1
            let some first := loop.shown[0]? | throw .noSuchMarker
            first.snapshot.release
            loop := (← stepped loop (.commit "b")).1
            let some second := loop.shown[0]? | throw .noSuchMarker
            let shown ← second.snapshot.read
            let echoed := loop.state.echo == "refused: no such snapshot"
            loop := (← stepped loop pressF5).1
            return (loop, shown, echoed && first.snapshot != second.snapshot)
          match program.runModel editorModel with
          | (.ok (loop, shown, echoed), model) =>
            echoed && shown == "ab" && loop.state.wellFormed && loop.shown.size == 1 &&
              model.display.scenes.map (·.echo) == #["", "", "refused: no such snapshot"]
          | (.error _, _) => false },
    { name :=
        "a message from a key's command is in the echo area of the scene published after it, the last of two when the command sent two; a key that yields nothing leaves it, and the next invocation clears it"
      run :=
        pure <|
          let say (texts : List String) (_ : Call) : EditorM (Option Config.Write) := do
            for text in texts do
              message text
            return none
          let handed : Loop.Keys TestScheme.scheme :=
            { maps := fun _ _ =>
                [Keymap.ofList
                    [(keys "C-c m", invoke "say"), (keys "C-c t", invoke "twice"),
                      (keys "C-c q", invoke "quiet")]]
              command? := fun name =>
                ([("say", say ["hi"]), ("twice", say ["first", "second"]), ("quiet", say [])].find?
                      (·.1 == name)).map
                  (·.2) }
          let program : EditorM TestLoop := do
            let mut loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
            let pressed (text : String) : List Event := (keys text).map (.key · true "")
            for event in pressed "C-c m" ++ [pressF5] ++ pressed "C-c t C-c q" do
              loop := (← loop.step handed event).loop
            return loop
          match program.runModel editorModel with
          | (.ok loop, model) =>
            loop.state.echo == "" &&
              model.display.scenes.map (·.echo) == #["", "hi", "hi", "hi", "second", "second", ""]
          | (.error _, _) => false },
    { name :=
        "with a prompt open the scene has the minibuffer's view after the window's, in the rectangles the tree gives with that view: its snapshot is the minibuffer's text, its scroll anchor and selection are its window's markers, its status line is one field, the label in the prompt's face, and it is the focused view; the window's status line is still its buffer's name"
      run :=
        pure <|
          match looped (promptedOver "ab") [pressF5] with
          | some ((loop, _), #[scene], model) =>
            let state := loop.state
            match scene.views, state.window? ⟨1⟩ with
            | #[window, minibuffer], some held =>
              window.id == ⟨0⟩ && minibuffer.id == ⟨1⟩ && shownText model minibuffer == some "ab" &&
                shownText model window == some "" &&
                minibuffer.scroll == held.scroll &&
                minibuffer.selections == #[held.selection] &&
                minibuffer.status == #[{ text := "Name: ", face := Loop.promptFace }] &&
                window.status == #[{ text := "scratch", face := Loop.nameFace }] &&
                Loop.promptFace != Loop.nameFace &&
                scene.focused == some ⟨1⟩ &&
                scene.views.map (fun view => (view.id, view.rect)) ==
                  state.frame.tree.rects (frameRect state.frame.size) (some ⟨1⟩) &&
                tiles (frameRect state.frame.size) (scene.views.map (·.rect))
            | _, _ => false
          | _ => false },
    { name :=
        "a text committed while a prompt is open is inserted in the minibuffer: its view shows the text so far, and the window's text is as it was"
      run :=
        pure <|
          match looped (promptedOver "ab") [.commit "c"] with
          | some (_, #[scene], model) => scene.views.map (shownText model) == #[some "", some "abc"]
          | _ => false },
    { name :=
        "once the prompt is closed the next scene has one view, the window's, which has the whole frame"
      run :=
        pure <|
          let program : EditorM TestLoop := do
            let (loop, _) ← stepsFrom (promptedOver "ab") [pressF5]
            let (_, closed) := loop.state.closePrompt none
            return (← stepped { loop with state := closed } pressF5).1
          match program.runModel editorModel with
          | (.ok _, model) =>
            model.display.scenes.map (·.views.map fun view => (view.id, view.rect)) ==
              #[(Split.split .rows (.window ⟨0⟩) .minibuffer).rects (frameRect ⟨640, 480⟩)
                  (some ⟨1⟩),
                #[(⟨0⟩, frameRect ⟨640, 480⟩)]]
          | (.error _, _) => false },
    { name :=
        "each view's cursor in the scene is what the scheme reports of that view: the default before a key, and, in the scene published after the key whose invocation switches the focused view's report, the switched one for that view and the default still for the others; a key that switches it back is followed by the default again"
      run :=
        pure <|
          match switched threeWindows "<F5> C-m C-p" with
          | some (_, #[first, marked, plain], _) =>
            let plainCursor : Cursor := ({} : InputScheme.Report).cursor
            first.views.map (·.cursor) == #[plainCursor, plainCursor, plainCursor] &&
              marked.views.map (·.cursor) == #[markedReport.cursor, plainCursor, plainCursor] &&
              plain.views.map (·.cursor) == #[plainCursor, plainCursor, plainCursor] &&
              markedReport.cursor != plainCursor
          | _ => false },
    { name :=
        "a view's status line is the fields the scheme reports of it and then its buffer's: the name, and the modified field while the buffer is modified; a view the scheme reports no field of has its buffer's alone"
      run :=
        pure <|
          match switched threeWindows "C-m" [.commit "x"] with
          | some (_, #[marked, modified], _) =>
            let name : StatusField := { text := "scratch", face := Loop.nameFace }
            let mark : StatusField := { text := Loop.modifiedMark, face := Loop.modifiedFace }
            marked.views.map (·.status) == #[markedReport.status ++ #[name], #[name], #[name]] &&
              modified.views.map (·.status) ==
                #[markedReport.status ++ #[name, mark], #[name, mark], #[name, mark]] &&
              markedReport.status.size == 1
          | _ => false },
    { name :=
        "while a prompt is open the minibuffer's view has the cursor the scheme reports of it, and its status line is the prompt's label alone, with none of the scheme's fields; the asking view keeps its own report"
      run :=
        pure <|
          let ask : Call → EditorM (Option Config.Write) := fun _ => do
            discard <| prompt "Name: " asked
            return none
          match
            switched (EditorState.initial ⟨640, 480⟩) "C-m C-a" (handed :=
              switchingKeys [("C-a", invoke "ask")] [("ask", ask)]) with
          | some (_, #[_, scene], _) =>
            scene.views.map (·.cursor) == #[markedReport.cursor, askedReport.cursor] &&
              scene.views.map (·.status) ==
                #[markedReport.status ++ #[{ text := "scratch", face := Loop.nameFace }],
                  #[{ text := "Name: ", face := Loop.promptFace }]] &&
              !askedReport.status.isEmpty
          | _ => false },
    { name :=
        "a loop is started with its first window's selection of the shape its scheme reports of the first view before any key: an inclusive cursor under a scheme that reports one, and an exclusive one under a scheme that says nothing"
      run :=
        pure <|
          let inclusive : InputScheme :=
            { TestScheme.scheme with
              report := fun _ view => if view == ⟨0⟩ then { shape := .inclusive } else {} }
          let cursor (scheme : InputScheme) : Option Marker :=
            onTextModel do
              let loop ← Loop.start scheme ⟨640, 480⟩
              let some target := loop.state.focusedTarget? | throw .noSuchText
              target.buffer.text.marker target.window.selection
          cursor inclusive == some (.selection { ranges := #[⟨0, 0⟩], shape := .inclusive }) &&
            cursor TestScheme.scheme ==
              some (.selection { ranges := #[⟨0, 0⟩], shape := .exclusive }) }]

/-- The focused window's buffer and window in `loop`'s state, or a refusal
for a state with none. -/
def focusedOf (loop : TestLoop) : EditorM Target := do
  let some target := loop.state.focusedTarget? | throw .noSuchText
  return target

/-- The ranges of the focused window's selection marker in `loop`'s state. -/
def cursorsOf (loop : TestLoop) : EditorM (Array SelectionRange) := do
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

/-- A scheme written for the commit checks: the test scheme, which keeps
what it is told was committed, the newest first, and says of every view
that it takes text or that it takes none, as `takesText` says. -/
def telling (takesText : Bool) : InputScheme :=
  { State := TestScheme.State × List (ViewId × String)
    Binding := Invocation
    init := ({}, [])
    step := fun maps view state key =>
      let (next, yielded) := TestScheme.step maps view state.1 key
      ((next, state.2), yielded)
    pending := (·.1.pending)
    command := fun name => { command := name }
    committed := fun view text state => (state.1, (view, text) :: state.2)
    report := fun _ _ => { takesText } }

/-- The checks of a text commit in the loop, on the editor's models. -/
def commitChecks : List Check :=
  [{  name :=
        "commits of a, b and c publish one scene each, whose focused view shows the text so far, with the window's cursor just after what was committed"
      run :=
        pure <|
          let program : EditorM (Array (SnapshotId × String × Array SelectionRange)) := do
            let mut loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
            let mut seen := #[]
            for text in ["a", "b", "c"] do
              loop := (← stepped loop (.commit text)).1
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
            let mut loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
            loop := (← stepped loop (.commit "hello")).1
            loop := (← stepped loop (.commit " world")).1
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
            let loop : TestLoop := { state := ← holding "abcd" #[⟨0, 1⟩, ⟨3, 3⟩] }
            let (loop, _) ← stepped loop (.commit "xy")
            return (← (← focusedOf loop).buffer.text.read, ← cursorsOf loop)
          match (program.runModel editorModel).1 with
          | .ok (text, cursors) => text == "xybcxyd" && cursors == #[⟨2, 2⟩, ⟨6, 6⟩]
          | .error _ => false },
    { name :=
        "a commit whose selection marker was given up leaves the state as it was, with the refusal in the echo area"
      run :=
        pure <|
          let program : EditorM (EditorState × TestLoop × Option String) := do
            let state ← EditorState.initial ⟨640, 480⟩
            let some target := state.focusedTarget? | throw .noSuchText
            target.buffer.text.unmark target.window.selection
            let (loop, _) ← stepped { state } (.commit "x")
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
            let mut loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
            loop := (← stepped loop (.commit "a")).1
            let some first := loop.shown[0]? | throw .noSuchSnapshot
            loop := (← stepped loop (.commit "b")).1
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
          | none => false },
    { name :=
        "a text committed where the scheme reports that the focused view takes no text is not inserted: the text and the selection are as they were, and the preedit is cleared all the same"
      run :=
        pure <|
          match switched (holding "abcd" #[⟨1, 3⟩]) "C-d" [.preedit "ka", .commit "x"] with
          | some (loop, scenes, model) =>
            let selection :=
              loop.state.focusedTarget?.bind fun target =>
                (target.selection.runModel model.texts).1.toOption
            model.texts.contents == #["abcd"] && selection.map (·.ranges) == some #[⟨1, 3⟩] &&
              loop.state.preedit == none &&
              scenes.map (·.preedit) == #[none, some "ka", none]
          | none => false },
    { name :=
        "once the scheme reports that the focused view takes text again, a committed text replaces what the selection covers, as under a scheme that says nothing"
      run :=
        pure <|
          let events : List Event :=
            [.commit "x"] ++ (keys "C-p").map (Event.key · true "") ++ [.commit "y"]
          match switched (holding "abcd" #[⟨1, 3⟩]) "C-d" events with
          | some (_, _, model) => model.texts.contents == #["ayd"]
          | none => false },
    { name :=
        "the loop tells the scheme of a committed text it inserted, for the focused view, in both states of the scheme it keeps; a commit that is dropped, where the scheme says the view takes no text, is not told; and the test scheme's notice changes nothing"
      run :=
        pure <|
          let told (takesText : Bool) :
            Option (List (ViewId × String) × List (ViewId × String) × Array String) :=
            let program : EditorM (Loop (telling takesText)) := do
              let mut loop ← Loop.start (telling takesText) ⟨640, 480⟩
              for event in [Event.commit "ab", .preedit "k", .commit "c"] do
                loop := (← loop.step {} event).loop
              return loop
            match program.runModel editorModel with
            | (.ok loop, model) =>
              let input : TestScheme.State × List (ViewId × String) := loop.input
              let atRest : TestScheme.State × List (ViewId × String) := loop.atRest
              some (input.2, atRest.2, model.texts.contents)
            | (.error _, _) => none
          told true == some ([(⟨0⟩, "c"), (⟨0⟩, "ab")], [(⟨0⟩, "c"), (⟨0⟩, "ab")], #["abc"]) &&
            told false == some ([], [], #[""]) &&
            (TestScheme.scheme.pending
                (TestScheme.scheme.committed ⟨0⟩ "x" TestScheme.scheme.init)).isEmpty }]

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
              ([controlKey "x"], none)) },
    { name :=
        "filtering a keymap keeps exactly the bindings whose binding is kept, in order, and what it binds is found by find? and continues"
      run :=
        let keymap : Keymap Nat :=
          Keymap.ofList
            [([charKey "a"], 1), ([controlKey "x", charKey "b"], 2), ([charKey "c"], 3),
              ([controlKey "x", charKey "d"], 4)]
        let odd := keymap.filter (· % 2 == 1)
        pure
          (odd.bindings == [([charKey "a"], 1), ([charKey "c"], 3)] &&
            odd.find? [charKey "c"] == some 3 &&
            odd.find? [controlKey "x", charKey "b"] == none &&
            !odd.continues [controlKey "x"] &&
            (keymap.filter (· > 3)).continues [controlKey "x"] &&
            (keymap.filter fun _ => true).bindings == keymap.bindings) }]

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

/-- The checks of an ex line (`Editor/Ex/Line.lean`): what a line typed on
the ex command line parses to, and the invocation an ex binding makes of a
line's argument. -/
def exLineChecks : List Check :=
  let parsed (line : String) : Option (String × Option String) :=
    (Ex.parse line).map fun parsed => (parsed.name, parsed.argument)
  [{  name := "an ex line of one word is that name, with no argument"
      run := pure (parsed "w" == some ("w", none)) },
    { name := "an ex line of a word and more is the word as its name and the rest as its argument"
      run := pure (parsed "e notes.txt" == some ("e", some "notes.txt")) },
    { name :=
        "white space round an ex line and after its name is dropped, and the argument is kept whole, the spaces inside it included"
      run := pure (parsed "  e   /tmp/my notes.txt  " == some ("e", some "/tmp/my notes.txt")) },
    { name := "a tab separates an ex name from its argument as a space does"
      run := pure (parsed "e\tnotes.txt" == some ("e", some "notes.txt")) },
    { name := "an ex name may hold a hyphen, and its argument a digit"
      run := pure (parsed "greet-all 2" == some ("greet-all", some "2")) },
    { name :=
        "an ex name is everything up to the first white space: a mark after letters is part of the name, and so is a leading colon"
      run := pure (parsed "w!" == some ("w!", none) && parsed ":w" == some (":w", none)) },
    { name := "the empty line and a line of white space are no ex line"
      run := pure (parsed "" == none && parsed "  \t " == none) },
    { name :=
        "an ex binding that takes nothing gives its command with no arguments for a line with no argument, and nothing for a line with one"
      run :=
        let binding : Ex.Binding := { name := "w", command := "write" }
        pure
          (binding.invocation? none == some { command := "write" } &&
            binding.invocation? (some "notes.txt") == none) },
    { name :=
        "an ex binding that takes text gives its command with the line's argument as its first argument, a string, and its command with no arguments for a line with none"
      run :=
        let binding : Ex.Binding := { name := "e", command := "edit", takes := .text }
        pure
          (binding.invocation? (some "my notes.txt") ==
              some { command := "edit", arguments := [.str "my notes.txt"] } &&
            binding.invocation? none == some { command := "edit" }) }]

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
            fed ⟨0⟩ "" == ({}, [])) },
    { name :=
        "a scheme that says nothing of a closed view keeps its state as it was: the notice defaults to changing nothing"
      run :=
        let (pending, _) := fed ⟨0⟩ "C-x"
        let closed : TestScheme.State := TestScheme.scheme.closeView ⟨0⟩ pending
        pure (decide (closed = pending) && TestScheme.scheme.pending closed == keys "C-x") },
    { name :=
        "a scheme that says nothing of the minibuffer's view keeps its state as it was: the notice defaults to changing nothing"
      run :=
        let (pending, _) := fed ⟨0⟩ "C-x"
        let told : TestScheme.State := TestScheme.scheme.openMinibuffer ⟨1⟩ pending
        pure (decide (told = pending) && TestScheme.scheme.pending told == keys "C-x") },
    { name :=
        "a scheme that says nothing of a view reports the default: a bar in the face cursor, no status field, an exclusive selection, no selecting, no insert session, and a view that takes text; the test scheme reports it of every view, before a key, while keys are pending and after a sequence completes"
      run :=
        let plain : InputScheme.Report := {}
        let reported (text : String) (view : ViewId) : InputScheme.Report :=
          TestScheme.scheme.report (fed ⟨0⟩ text).1 view
        pure
          (plain ==
              { cursor := { shape := .bar, face := ⟨"cursor"⟩ }, status := #[], shape := .exclusive
                selecting := false, session := false, takesText := true } &&
            TestScheme.scheme.report schemeInit ⟨0⟩ == plain &&
            reported "C-x" ⟨0⟩ == plain &&
            reported "C-x" ⟨1⟩ == plain &&
            reported "C-x C-s" ⟨0⟩ == plain &&
            reported "a" ⟨0⟩ == plain) }]

/-- A press of `key` with no text, as a window reports one. -/
def press (key : Key) : Event :=
  .key key true ""

/-- A press of each key the key string `text` names, in order. -/
def presses (text : String) : List Event :=
  (keys text).map press

/-- What a command of the dispatch checks is: given its call, a program
whose value is what to write back. -/
abbrev Dispatched :=
  Call → EditorM (Option Config.Write)

/-- What a step of the dispatch checks is handed: one keymap, the same for
every view, that binds each key string of `bindings` to the invocation
beside it, and the commands `commands`, by name. -/
def dispatchKeys (bindings : List (String × Invocation))
    (commands : List (String × Dispatched) := []) : Loop.Keys TestScheme.scheme :=
  { maps := fun _ _ =>
      [Keymap.ofList (bindings.map fun (text, invocation) => (keys text, invocation))]
    command? := fun name => (commands.find? (·.1 == name)).map (·.2) }

/-- What a command was called with, as one line: its arguments, then its
keys as a key string. -/
def calledWith (call : Call) : String :=
  " ".intercalate (call.arguments.map argumentText ++ [Key.notations call.keys])

/-- The command `stamp` of the dispatch checks: it inserts what it was
called with (`calledWith`) at the cursors of the window it is handed. -/
def stamp : Dispatched := fun call => do
  Loop.insert call.target (calledWith call)
  return none

/-- Feeds `loop` the `events` in order, each step handed `keys`: the loop
after them and what each step handed back. -/
def stepsWith {scheme : InputScheme} (keys : Loop.Keys scheme) (loop : Loop scheme)
    (events : List Event) : EditorM (Loop scheme × Array (Loop.Stepped scheme)) := do
  let mut loop := loop
  let mut steps := #[]
  for event in events do
    let after ← loop.step keys event
    loop := after.loop
    steps := steps.push after
  return (loop, steps)

/-- What a run of the loop over the state `start` makes came to on the
models `model`, each step handed `keys`: the loop and what each step handed
back, the scenes the display recorded, and the models. `none` when it was
refused. -/
def dispatched (keys : Loop.Keys TestScheme.scheme) (events : List Event)
    (start : TextM EditorState := EditorState.initial ⟨640, 480⟩)
    (model : EditorModel := editorModel) :
    Option ((TestLoop × Array (Loop.Stepped TestScheme.scheme)) × Array Scene × EditorModel) :=
  let program : EditorM (TestLoop × Array (Loop.Stepped TestScheme.scheme)) := do
    stepsWith keys { state := ← start } events
  match program.runModel model with
  | (.ok result, model) => some (result, model.display.scenes, model)
  | (.error _, _) => none

/-- The pending keys each scene of a run showed; none of them when the run
was refused. -/
def pendingShown (keys : Loop.Keys TestScheme.scheme) (events : List Event)
    (start : TextM EditorState := EditorState.initial ⟨640, 480⟩) : Array String :=
  match dispatched keys events start with
  | some (_, scenes, _) => scenes.map (·.pending)
  | none => #[]

/-- What the last scene of a run showed: its echo, its pending keys, and the
text of each of its views. `none` when the run was refused or published
nothing. -/
def lastScene (keys : Loop.Keys TestScheme.scheme) (events : List Event)
    (start : TextM EditorState := EditorState.initial ⟨640, 480⟩)
    (model : EditorModel := editorModel) : Option (String × String × Array (Option String)) :=
  match dispatched keys events start model with
  | some (_, scenes, model) =>
    scenes.back?.map fun scene => (scene.echo, scene.pending, scene.views.map (shownText model))
  | none => none

/-- The checks of keys in the loop (`Editor/Loop.lean`), on the editor's
models and the test scheme, with keymaps written here: which keys are
stepped through the scheme, the pending keys the scene shows, and the
command a completed sequence runs. -/
def dispatchKeyChecks : List Check :=
  let saves := dispatchKeys [("C-x C-s", invoke "save"), ("C-x r t", invoke "rectangle")]
  [{  name :=
        "after the first key of a bound sequence the scene shows it as pending, after each further key of a longer one the keys so far, and after the key that completes the sequence none"
      run :=
        pure
          (pendingShown saves (presses "C-x C-s") == #["C-x", ""] &&
            pendingShown saves (presses "C-x r t") == #["C-x", "C-x r", ""]) },
    { name :=
        "after a prefix and then a key that goes on with no binding, the scene shows no pending keys, and the sequence typed next is pending from its first key again"
      run :=
        pure
          (pendingShown saves (presses "C-x" ++ [pressF5] ++ presses "C-x") ==
            #["C-x", "", "C-x"]) },
    { name :=
        "a key release, and a press and a release of a modifier key by itself, between two keys of a sequence are not stepped: the prefix is still pending after each"
      run :=
        let shift : Key :=
          { logical := .named ⟨"Shift"⟩, physical := .code "ShiftLeft",
            modifiers := { shift := true } }
        let between : List Event :=
          [.key (controlKey "x") false "", press shift,
            .key { shift with modifiers := {} } false ""]
        pure
          (pendingShown saves (presses "C-x" ++ between ++ presses "r") ==
            #["C-x", "C-x", "C-x", "C-x", "C-x r"]) },
    { name :=
        "a press the platform repeated is stepped like any press, and a key from a window is taken by its chord"
      run :=
        let held : Key :=
          { controlKey "x" with
            physical := .code "KeyX", repeated := true }
        pure (pendingShown saves [press held] == #["C-x"]) },
    { name :=
        "a key is for the focused view: it is looked up in that view's keymaps, and in no other's"
      run :=
        let onlyFirst : Loop.Keys TestScheme.scheme :=
          { maps := fun state view => if view == ⟨1⟩ then saves.maps state view else [] }
        let focusedOn (view : ViewId) : TextM EditorState := do
          return ((← threeWindows).focusWindow view).2
        pure
          (pendingShown onlyFirst (presses "C-x") (focusedOn ⟨1⟩) == #["C-x"] &&
            pendingShown onlyFirst (presses "C-x") (focusedOn ⟨0⟩) == #[""]) },
    { name :=
        "a modifier key by itself is each named key of the W3C modifier names, with or without modifiers held, and no other key: not a character with shift held, and not another named key"
      run :=
        pure
          (["Shift", "Control", "Alt", "AltGraph", "Meta", "Super", "Hyper", "CapsLock", "NumLock",
                  "ScrollLock", "Fn", "FnLock", "Symbol", "SymbolLock"].all
              (fun name =>
                (namedKey ⟨name⟩).isModifier &&
                  (namedKey ⟨name⟩ { shift := true, control := true }).isModifier) &&
            !(charKey "A" { shift := true }).isModifier &&
            !(namedKey .escape).isModifier &&
            !(namedKey ⟨"F5"⟩).isModifier &&
            !({ logical := .dead none } : Key).isModifier &&
            !({ logical := .unidentified } : Key).isModifier) },
    { name :=
        "a bound key sequence runs its command once, with the count the binding gives and the keys typed: the scene after the prefix shows the text unchanged, the scene after the last key shows the command's effect, and a further key that is bound to nothing adds nothing"
      run :=
        let keys :=
          dispatchKeys [("C-x i", { command := "stamp", arguments := [.nat 3] })] [("stamp", stamp)]
        pure
          (lastScene keys (presses "C-x") == some ("", "C-x", #[some ""]) &&
            lastScene keys (presses "C-x i") == some ("", "", #[some "3 C-x i"]) &&
            lastScene keys (presses "C-x i" ++ [pressF5]) == some ("", "", #[some "3 C-x i"])) },
    { name :=
        "a command is handed the focused window and its buffer, the arguments of the invocation in order, and every key of the sequence as a chord, though the keys came from a window with their physical codes"
      run :=
        let seen : Dispatched := fun call => do
          let editor := (← call.target.buffer.text.read)
          makes
              s!"{call.target.window.id.index} {call.target.buffer.name} {editor.length} {calledWith call}"
          return none
        let keys :=
          dispatchKeys
            [("C-x r t", { command := "seen", arguments := [.str "w", .int (-2), .bool true] })]
            [("seen", seen)]
        let fromWindow : List Event :=
          (Editor.Key.parse "C-x r t" |>.toOption.getD []).map fun key =>
            press
              { key with
                physical := .code "KeyQ", repeated := true }
        let focusedOn : TextM EditorState := do
          return ((← threeWindows).focusWindow ⟨2⟩).2
        pure <|
          match dispatched keys fromWindow focusedOn with
          | some (_, _, model) => model.texts.contents.back? == some "2 scratch 0 w -2 true C-x r t"
          | none => false },
    { name :=
        "an invocation of a name no command is registered under says so in the echo area, and the next key is handled: a key that yields nothing leaves the echo, and the next command that runs clears it"
      run :=
        let keys :=
          dispatchKeys [("C-c n", invoke "nope"), ("C-c s", invoke "stamp")] [("stamp", stamp)]
        pure
          (lastScene keys (presses "C-c n") == some ("nope: no such command", "", #[some ""]) &&
            lastScene keys (presses "C-c n" ++ [pressF5] ++ presses "C-c") ==
              some ("nope: no such command", "C-c", #[some ""]) &&
            lastScene keys (presses "C-c n C-c s") == some ("", "", #[some "C-c s"])) },
    { name :=
        "a key bound to a registered command, in a state whose focused window is not in the state, says in the echo area that no window is focused: the command makes no request, and nothing is left pending"
      run :=
        let made : Dispatched := fun _ => do
          discard <| createText "made"
          return none
        let keys := dispatchKeys [("C-c m", invoke "made")] [("made", made)]
        let unfocused : TextM EditorState := do
          let state ← EditorState.initial ⟨640, 480⟩
          return { state with frame := { state.frame with focused := ⟨9⟩ } }
        pure <|
          match dispatched keys (presses "C-c m") unfocused with
          | some ((loop, _), scenes, model) =>
            loop.state.echo == "made: no window is focused" &&
              scenes.back?.map (·.echo) == some "made: no window is focused" &&
              model.texts.contents == #[""] &&
              loop.pending == "" &&
              scenes.back?.map (·.pending) == some ""
          | none => false },
    { name :=
        "a command that is refused says so in the echo area, with its name and the refusal, and the step is not refused: the next key runs its command"
      run :=
        let gone : Dispatched := fun _ => do
          (⟨7⟩ : TextId).insert 0 "x"
          return none
        let keys :=
          dispatchKeys [("C-c g", invoke "gone"), ("C-c s", invoke "stamp")]
            [("gone", gone), ("stamp", stamp)]
        pure
          (lastScene keys (presses "C-c g") ==
              some ("gone: refused: no such text", "", #[some ""]) &&
            lastScene keys (presses "C-c g C-c s") == some ("", "", #[some "C-c s"])) },
    { name :=
        "under the test scheme a key that prints and is bound to nothing yields its self-insert, which no command is registered under: the echo area says so"
      run :=
        pure
          (lastScene (dispatchKeys []) (presses "a") ==
            some ("self-insert: no such command", "", #[some ""])) },
    { name :=
        "a step hands back what the command it ran asked to be written, and nothing for a step that ran no command or whose command was refused"
      run :=
        let writes : Dispatched := fun _ =>
          return some { owner := .config, store := "counter", value := .nat 5 }
        let refuses : Dispatched := fun _ => do
          (⟨7⟩ : TextId).insert 0 "x"
          return some { owner := .config, store := "counter", value := .nat 9 }
        let keys :=
          dispatchKeys [("C-c w", invoke "writes"), ("C-c r", invoke "refuses")]
            [("writes", writes), ("refuses", refuses)]
        pure <|
          match dispatched keys (presses "C-c w C-c r" ++ [pressF5, .focus true]) with
          | some ((_, steps), _, _) =>
            steps.map
                (fun step =>
                  step.write.map fun write => (write.owner.name, write.store, write.value)) ==
              #[none, some ("config", "counter", Value.nat 5), none, none, none, none]
          | none => false }]

/-- A command of the rollback checks that is refused with `badRange`, after
`before` has run on what it was called with. -/
def failingAfter (before : Call → EditorM Unit) : Dispatched := fun call => do
  before call
  call.target.buffer.text.delete 9 99
  return none

/-- The command `boom` of the rollback checks: it replaces what the
selection covers with `boom`, which edits the text and moves the selection,
and is then refused. -/
def boom : Dispatched :=
  failingAfter fun call => Loop.insert call.target "boom"

/-- `hiddenBuffer`'s state with the buffer `hidden`, which no window shows,
holding a file: a buffer a save can be begun for. -/
def savable : TextM EditorState := do
  let (state, _) ← hiddenBuffer
  return (state.attachFile ⟨2⟩ notePath noteStamp .lf).2

/-- The save in flight of the buffer `hidden` of `savable`, in `state`. -/
def savingOf (state : EditorState) : Option Buffer.Saving :=
  ((state.buffer? ⟨2⟩).bind (·.file)).bind (·.saving)

/-- The commands of the checks of a save in flight, on `savable`, bound
under `C-c`. `begin` (`g`) takes a snapshot of the buffer's text and begins
a save of it, with the state the buffer's history is in. `end` (`e`) ends
the save in flight with a stamp, as a save that wrote the file does, and
`unsaved` (`n`) with none, as one that was refused does. `remove` (`r`)
removes the buffer. `fail` (`f`) ends the save with a stamp and is then
refused. `twice` (`t`) releases the save's snapshot itself and then ends
the save. -/
def saveKeys : Loop.Keys TestScheme.scheme :=
  let ends (stamp : Option File.Stamp) (first : SnapshotId → EditorM Unit := fun _ => pure ()) :
    EditorM Unit := do
    let some saving := savingOf (← editorState) | throw .noSuchSnapshot
    first saving.snapshot
    discard <| EditorState.ask (.endSave ⟨2⟩ saving.snapshot stamp)
  let later : File.Stamp :=
    { noteStamp with
      seconds := 9, size := 12 }
  let run (command : EditorM Unit) : Dispatched := fun _ => do
    command
    return none
  dispatchKeys
    [("C-c g", invoke "begin"), ("C-c e", invoke "end"), ("C-c n", invoke "unsaved"),
      ("C-c r", invoke "remove"), ("C-c f", invoke "fail"), ("C-c t", invoke "twice")]
    [("begin",
        run do
          let some buffer := (← editorState).buffer? ⟨2⟩ | throw .noSuchText
          let taken ← buffer.text.snapshot
          discard <| EditorState.ask (.beginSave ⟨2⟩ taken buffer.history.state)),
      ("end", run (ends (some later))), ("unsaved", run (ends none)),
      ("remove", run (discard <| EditorState.ask (.removeBuffer ⟨2⟩))),
      ("fail", failingAfter fun _ => ends (some later)),
      ("twice", run (ends (some later) fun taken => taken.release))]

/-- A scheme written for the rollback checks: the test scheme, with two
counts beside its state that no reset clears, as a scheme's state may hold
what a reset must keep. The first counts the keys that yielded an
invocation, and the second the keys that yielded nothing and left nothing
pending. -/
def tallying : InputScheme :=
  { State := TestScheme.State × Nat × Nat
    Binding := Invocation
    init := ({}, 0, 0)
    step := fun maps view state key =>
      match TestScheme.step maps view state.1 key with
      | (next, some invocation) => ((next, state.2.1 + 1, state.2.2), some invocation)
      | (next, none) =>
        ((next, state.2.1, if next.pending.isEmpty then state.2.2 + 1 else state.2.2), none)
    pending := (·.1.pending)
    command := fun name => { command := name } }

/-- The two counts of `tallying` in a loop's state: the keys that yielded an
invocation, and the keys that yielded nothing and left nothing pending. -/
def tallies (loop : Loop tallying) : Nat × Nat :=
  let state : TestScheme.State × Nat × Nat := loop.input
  state.2

/-- The focused window's scroll anchor in `loop`'s state, as the text holds
it. -/
def scrollOf {scheme : InputScheme} (loop : Loop scheme) : EditorM (Option Anchor) := do
  let some target := loop.state.focusedTarget? | throw .noSuchText
  match ← target.buffer.text.marker target.window.scroll with
  | .anchor anchor =>
    return some anchor
  | .selection _ =>
    return none

/-- The checks of rollback in the loop (`Editor/Loop.lean`), on the editor's
models: what a command that failed leaves, in the text, in the windows'
markers, in the history and in the scheme's state. -/
def dispatchRollbackChecks : List Check :=
  let keys :=
    dispatchKeys [("C-c b", invoke "boom"), ("C-c s", invoke "stamp")]
      [("boom", boom), ("stamp", stamp)]
  [{  name :=
        "a command that fails after editing: the echo area shows its error, the buffer's text and the window's selection are those before the command, the history has no step for it, and the next key runs its command"
      run :=
        pure <|
          let program :
            EditorM ((String × Array SelectionRange × String × Nat) × Nat × String × String) := do
            let loop : TestLoop := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let (loop, _) ← stepsWith keys loop (presses "C-c")
            let nodes := (← focusedOf loop).buffer.history.nodes.size
            let (loop, _) ← stepsWith keys loop (presses "b")
            let target ← focusedOf loop
            let failed :=
              (← target.buffer.text.read, ← cursorsOf loop, loop.state.echo,
                target.buffer.history.nodes.size)
            let (loop, _) ← stepsWith keys loop (presses "C-c s")
            let target ← focusedOf loop
            let after ← target.buffer.text.read
            let some _ ← target.buffer.history.undo | throw .noInverse
            return (failed, nodes, after, ← target.buffer.text.read)
          match program.runModel editorModel with
          | (.ok (failed, nodes, after, undone), model) =>
            failed == ("abcd", #[⟨1, 3⟩], "boom: refused: bad range", nodes) &&
              after == "aC-c sd" &&
              undone == "abcd" &&
              model.display.scenes.map (·.echo) ==
                #["", "boom: refused: bad range", "boom: refused: bad range", ""]
          | (.error _, _) => false },
    { name :=
        "a command that placed the window's selection and its scroll anchor without editing, and then failed, has both put back where they were"
      run :=
        pure <|
          let wander : Dispatched :=
            failingAfter fun call => do
              let text := call.target.buffer.text
              text.place call.target.window.selection (.selection { ranges := #[⟨0, 0⟩, ⟨4, 4⟩] })
              text.place call.target.window.scroll (.anchor { offset := 2, bias := .after })
          let keys := dispatchKeys [("C-c w", invoke "wander")] [("wander", wander)]
          let program : EditorM (Array SelectionRange × Option Anchor × String) := do
            let loop : TestLoop := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let (loop, _) ← stepsWith keys loop (presses "C-c w")
            return (← cursorsOf loop, ← scrollOf loop, loop.state.echo)
          match (program.runModel editorModel).1 with
          | .ok (cursors, scroll, echo) =>
            cursors == #[⟨1, 3⟩] && scroll == some { offset := 0, bias := .before } &&
              echo == "wander: refused: bad range"
          | .error _ => false },
    { name :=
        "a command that fails after editing two buffers has both texts as they were before it, and one that edited nothing leaves the texts and their revisions as they were"
      run :=
        pure <|
          let both : Dispatched :=
            failingAfter fun call => do
              call.target.buffer.text.insert 0 "x"
              (⟨1⟩ : TextId).insert 5 "!"
              call.target.buffer.text.insert 0 "y"
          let idle : Dispatched := failingAfter fun _ => pure ()
          let keys :=
            dispatchKeys [("C-c 2", invoke "both"), ("C-c 0", invoke "idle")]
              [("both", both), ("idle", idle)]
          let revisions (loop : TestLoop) : EditorM (Array Nat) :=
            loop.state.buffers.filterMap id |>.mapM fun buffer => buffer.text.revision
          let program : EditorM (Array String × Array Nat × Array Nat) := do
            let (loop, _) ← stepsWith keys { state := ← twoBuffers } (presses "C-c 2")
            let texts ← (loop.state.buffers.filterMap id).mapM fun buffer => buffer.text.read
            let before ← revisions loop
            let (loop, _) ← stepsWith keys loop (presses "C-c 0")
            return (texts, before, ← revisions loop)
          match (program.runModel editorModel).1 with
          | .ok (texts, before, after) => texts == #["", "other"] && before == after
          | .error _ => false },
    { name :=
        "a key's command that sets a register and is then refused leaves the register the name had: a register is editor state, and the state is the one from before the command; a command that sets one and runs to its end leaves it set"
      run :=
        pure <|
          let kept : Register := { text := "kept" }
          let lost : Register := { text := "lost\n", linewise := true }
          let keeps : Dispatched := fun _ => do
            setRegister "a" kept
            return none
          let loses : Dispatched :=
            failingAfter fun _ => do
              setRegister "a" lost
              setRegister "b" lost
          let keys :=
            dispatchKeys [("C-c k", invoke "keeps"), ("C-c l", invoke "loses")]
              [("keeps", keeps), ("loses", loses)]
          let program :
            EditorM
              (Option Register × Option Register × Option Register × Option Register × String) :=
            do
            let loop : TestLoop := { state := ← EditorState.initial ⟨640, 480⟩ }
            let (set, _) ← stepsWith keys loop (presses "C-c k")
            let (failed, _) ← stepsWith keys set (presses "C-c l")
            return (loop.state.register? "a", set.state.register? "a", failed.state.register? "a",
                failed.state.register? "b", failed.state.echo)
          (program.runModel editorModel).1.toOption ==
            some (none, some kept, some kept, none, "loses: refused: bad range") },
    { name :=
        "after a command that failed the scheme is as it was before the first key of the sequence, with what it keeps across a reset: the key that yielded the failed invocation is not counted, a key that yielded nothing before it still is, and nothing is pending"
      run :=
        pure <|
          let keys : Loop.Keys tallying :=
            { maps := fun _ _ =>
                [Keymap.ofList
                    [(ModelTest.keys "C-c b", invoke "boom"),
                      (ModelTest.keys "C-c s", invoke "stamp")]]
              command? := fun name =>
                ([("boom", boom), ("stamp", stamp)].find? (·.1 == name)).map (·.2) }
          let program : EditorM (List (Nat × Nat) × String) := do
            let loop : Loop tallying := { state := ← EditorState.initial ⟨640, 480⟩ }
            let (ran, _) ← stepsWith keys loop (presses "C-c s")
            let (reset, _) ← stepsWith keys ran [pressF5]
            let (failed, _) ← stepsWith keys reset (presses "C-c b")
            let (again, _) ← stepsWith keys failed (presses "C-c s")
            return ([tallies ran, tallies reset, tallies failed, tallies again], failed.pending)
          match (program.runModel editorModel).1 with
          | .ok (counts, pending) => counts == [(1, 0), (1, 1), (1, 1), (2, 1)] && pending == ""
          | .error _ => false },
    { name :=
        "a command that gave up the window's selection marker and then failed cannot be rolled back whole: the echo area says what was not, after the command's error, the text is still put back, and the step is not refused"
      run :=
        pure <|
          let forget : Dispatched :=
            failingAfter fun call => do
              call.target.buffer.text.insert 0 "x"
              call.target.buffer.text.unmark call.target.window.selection
          let keys := dispatchKeys [("C-c f", invoke "forget")] [("forget", forget)]
          lastScene keys (presses "C-c f") (holding "abcd" #[⟨1, 3⟩]) ==
            some
              ("forget: refused: bad range; not rolled back: no such marker", "", #[some "abcd"]) },
    { name :=
        "a command that released a buffer's text and then failed: running it says what was not rolled back and still rolls back the other buffer, and the step that runs it is not refused"
      run :=
        pure <|
          let release : Dispatched :=
            failingAfter fun call => do
              (⟨1⟩ : TextId).insert 5 "!"
              call.target.buffer.text.release
          let keys := dispatchKeys [("C-c r", invoke "release")] [("release", release)]
          let ran : EditorM (String × String) := do
            let state ← twoBuffers
            let ran ← Loop.run keys state (invoke "release") (ModelTest.keys "C-c r")
            return (ran.state.echo, ← (⟨1⟩ : TextId).read)
          (match (ran.runModel editorModel).1 with
            | .ok (echo, other) =>
              echo == "release: refused: no such text; not rolled back: no such text" &&
                other == "other"
            | .error _ => false) &&
            (dispatched keys (presses "C-c r") twoBuffers).isSome },
    { name :=
        "a rollback after the history moved does not take the move back: it reverts the edits made since the move, leaves the text at the node the move reached, says the command moved in the history, and what was undone can be redone"
      run :=
        pure <|
          let program : EditorM (String × String × String × String) := do
            let state ← holding "one" #[⟨3, 3⟩]
            let (state, _) ← state.recordHistories
            let kept ← Loop.keep state
            -- What a command that moved in the history would have done: an
            -- undo, to the root, and then an edit.
            let some buffer := state.buffer? ⟨0⟩ | throw .noSuchText
            let some moved ← buffer.history.undo Origin.user | throw .noInverse
            buffer.text.insert 0 "x"
            let during := { state with buffers := #[some { buffer with history := moved.tree }] }
            let before ← buffer.text.read
            let (restored, said) ← kept.restore state during
            let after ← buffer.text.read
            let some again := restored.buffer? ⟨0⟩ | throw .noSuchText
            let some _ ← again.history.redo Origin.user | throw .noInverse
            return (before, after, said, ← buffer.text.read)
          (program.runModel editorModel).1.toOption ==
            some ("x", "", "; the command moved in the history", "one") },
    { name :=
        "a command that ended a save with a stamp, which marks the buffer's state as saved, and was then refused is rolled back whole: the buffer is modified as it was before the command, its stamp is the one from before, and its save is still in flight"
      run :=
        pure <|
          let program : EditorM (Bool × Bool × Option Buffer × Option Buffer × String) := do
            let state ← savable
            (⟨2⟩ : TextId).insert 0 "x"
            let (edited, _) ← stepsWith saveKeys ({ state } : TestLoop) [pressF5]
            let (begun, _) ← stepsWith saveKeys edited (presses "C-c g")
            let (failed, _) ← stepsWith saveKeys begun (presses "C-c f")
            return (((begun.state.buffer? ⟨2⟩).map (·.isModified)) == some true,
                (savingOf begun.state).isSome, failed.state.buffer? ⟨2⟩, begun.state.buffer? ⟨2⟩,
                failed.state.echo)
          match (program.runModel editorModel).1 with
          | .ok (modified, saving, after, before, echo) =>
            modified && saving && after == before && echo == "fail: refused: bad range"
          | .error _ => false },
    { name :=
        "a command that recorded its buffer's history marked as saved and was then refused leaves the buffer modified as it was: a rollback takes back a mark of the saved state"
      run :=
        pure <|
          let marking : Dispatched :=
            failingAfter fun call => do
              let .ok buffer ← call.target.window.buffer.synced | throw .noSuchText
              discard <|
                  EditorState.ask (.setHistory call.target.window.buffer buffer.history.markSaved)
          let keys := dispatchKeys [("C-c m", invoke "mark")] [("mark", marking)]
          let program : EditorM (Option Buffer × Option Buffer × String) := do
            let (edited, _) ←
              stepsWith keys ({ state := ← EditorState.initial ⟨640, 480⟩ } : TestLoop)
                  [.commit "a"]
            let (failed, _) ← stepsWith keys edited (presses "C-c m")
            return (edited.state.buffer? ⟨0⟩, failed.state.buffer? ⟨0⟩, failed.state.echo)
          match (program.runModel editorModel).1 with
          | .ok (before, after, echo) =>
            (before.map (·.isModified)) == some true && after == before &&
              echo == "mark: refused: bad range"
          | .error _ => false }]

/-- The events of `events` as they arrive, none of them marked as an
interrupt key. -/
def arriving (events : List Event) : List Received :=
  events.map fun event => { event, stamp := 0 }

/-- A press of the interrupt key as it arrives, marked as one: the event
the loop lowers the flag for. -/
def interruptArrives : Received :=
  { event := press Watch.interruptKey, stamp := 0, interrupt := true }

/-- Feeds `loop` what arrived, in order, as a host does (`Loop.take`), each
step handed `keys`: the loop after them. -/
def takes {scheme : InputScheme} (keys : Loop.Keys scheme) (loop : Loop scheme)
    (received : List Received) : EditorM (Loop scheme) := do
  let mut loop := loop
  for one in received do
    loop := (← loop.take keys one).loop
  return loop

/-- What a run of the loop over the buffer holding `abcd`, its selection
over `bc`, came to when it was fed what arrived, on the editor's models
with the watch model `watch`: the buffer's text, the selection's ranges, the
echo of each scene, and the watch model after. `none` when it was
refused. -/
def tookFrom (keys : Loop.Keys TestScheme.scheme) (received : List Received) (watch : WatchModel) :
    Option (String × Array SelectionRange × Array String × WatchModel) :=
  let program : EditorM (String × Array SelectionRange) := do
    let loop ← takes keys { state := ← holding "abcd" #[⟨1, 3⟩] } received
    return (← (← focusedOf loop).buffer.text.read, ← cursorsOf loop)
  match program.runModel { editorModel with watch } with
  | (.ok (text, cursors), model) =>
    some (text, cursors, model.display.scenes.map (·.echo), model.watch)
  | (.error _, _) => none

/-- The command `spin` of the interrupt checks: it replaces what the
selection covers with `spin`, and then asks the text its revision a thousand
times. -/
def spin : Dispatched := fun call => do
  Loop.insert call.target "spin"
  for _ in [0:1000] do
    discard <| call.target.buffer.text.revision
  return none

/-- The checks of the interrupt in the loop (`Editor/Loop.lean`), on the
editor's models: a command the loop runs stops once the flag is up, and the
flag comes down when the loop takes the interrupt key off the queue. -/
def dispatchInterruptChecks : List Check :=
  let keys :=
    dispatchKeys [("C-c l", invoke "spin"), ("C-c s", invoke "stamp"), ("C-g", invoke "stamp")]
      [("spin", spin), ("stamp", stamp)]
  let unbound := dispatchKeys [("C-c s", invoke "stamp")] [("stamp", stamp)]
  [{  name :=
        "when the interrupt key arrives while a command is looping over requests, the command stops: the buffer's text and the selection are those before it, the echo area says it was interrupted, and the flag is still up"
      run :=
        pure <|
          match tookFrom keys (arriving (presses "C-c l")) { arrivesAfter := some 20 } with
          | some (text, cursors, echoes, watch) =>
            text == "abcd" && cursors == #[⟨1, 3⟩] && echoes == #["", "spin: interrupted"] &&
              watch.arrived == 1
          | none => false },
    { name := "with no interrupt key arriving the same command runs to its end, and its edit stays"
      run :=
        pure <|
          match tookFrom keys (arriving (presses "C-c l")) {} with
          | some (text, _, echoes, _) => text == "aspind" && echoes == #["", ""]
          | none => false },
    { name :=
        "the event the library marked as the interrupt key lowers the flag and is then stepped like any key: the command bound to it runs to its end; the same key unmarked lowers nothing, and its command is interrupted"
      run :=
        pure <|
          (match tookFrom keys [interruptArrives] { arrived := 1 } with
            | some (text, _, echoes, watch) =>
              text == "aC-gd" && echoes == #[""] && watch.arrived == 0
            | none => false) &&
            match tookFrom keys (arriving [press Watch.interruptKey]) { arrived := 1 } with
            | some (text, _, echoes, watch) =>
              text == "abcd" && echoes == #["stamp: interrupted"] && watch.arrived == 1
            | none => false },
    { name :=
        "an interrupt key that arrived while no command was running interrupts nothing: once the loop has taken it off the queue, the next key's command runs to its end"
      run :=
        pure <|
          match
            tookFrom unbound (interruptArrives :: arriving (presses "C-c s")) { arrived := 1 } with
          | some (text, _, echoes, watch) =>
            text == "aC-c sd" && echoes == #["", "", ""] && watch.arrived == 0
          | none => false },
    { name :=
        "a command for a key queued ahead of the interrupt key is interrupted before its first request, and its echo is still there after the interrupt key is stepped and found bound to nothing; the key after it runs its command"
      run :=
        pure <|
          let queued := arriving (presses "C-c s") ++ [interruptArrives]
          (match tookFrom unbound queued { arrived := 1 } with
            | some (text, cursors, echoes, watch) =>
              text == "abcd" && cursors == #[⟨1, 3⟩] &&
                echoes == #["", "stamp: interrupted", "stamp: interrupted"] &&
                watch.arrived == 0
            | none => false) &&
            match tookFrom unbound (queued ++ arriving (presses "C-c s")) { arrived := 1 } with
            | some (text, _, echoes, _) => text == "aC-c sd" && echoes.back? == some ""
            | none => false },
    { name :=
        "with two interrupt keys arrived, the command of a key between them is interrupted, and the one after the second runs to its end"
      run :=
        pure <|
          let between := interruptArrives :: arriving (presses "C-c s") ++ [interruptArrives]
          (match tookFrom unbound between { arrived := 2 } with
            | some (text, _, echoes, watch) =>
              text == "abcd" && echoes.back? == some "stamp: interrupted" && watch.arrived == 0
            | none => false) &&
            match tookFrom unbound (between ++ arriving (presses "C-c s")) { arrived := 2 } with
            | some (text, _, echoes, _) => text == "aC-c sd" && echoes.back? == some ""
            | none => false },
    { name :=
        "for an event taken off the queue with no loop to step it, the flag is lowered once if the library marked the event, and not at all if it did not"
      run :=
        pure
          ((watched (Loop.lowerFor true) { arrived := 2 }).2.arrived == 1 &&
            (watched (Loop.lowerFor false) { arrived := 2 }).2.arrived == 2) }]

/-- A command of the slow-command checks that makes `requests` requests of
the text port, each a question that changes nothing, and is then refused if
`refused`. -/
def asking (requests : Nat) (refused : Bool := false) : Dispatched := fun call => do
  for _ in [0:requests] do
    discard <| call.target.buffer.text.revision
  if refused then
    throw .badRange
  return none

/-- What each step of a run handed back as its log, on the editor's models
with a clock that moves on by 10 milliseconds at each text request and each
display request; nothing when the run was refused. -/
def logged (keys : Loop.Keys TestScheme.scheme) (events : List Event) : Array (Array String) :=
  match
    dispatched keys events (model :=
      { editorModel with watch := { clock := 1000, pace := 10 } }) with
  | some ((_, steps), _, _) => steps.map (·.log)
  | none => #[]

/-- The checks of the slow-command log in the loop (`Editor/Loop.lean`), on
the model's clock: a command that took longer than the threshold is logged
once, with its name and how long it took. -/
def dispatchSlowChecks : List Check :=
  let keys : Loop.Keys TestScheme.scheme :=
    {
      dispatchKeys
        [("C-c 6", invoke "stamp"), ("C-c 5", invoke "five"), ("C-c 2", invoke "two"),
          ("C-c r", invoke "refused"), ("C-c n", invoke "nope")]
        [("stamp", asking 6), ("five", asking 5), ("two", asking 2),
          ("refused", asking 7 true)] with
      slowAfter := 50 }
  [{  name :=
        "a command that takes longer than the threshold produces one log entry with its name and how long it took, in the step that ran it and in no other"
      run :=
        pure
          (logged keys (presses "C-c 6" ++ [pressF5]) ==
            #[#[], #["slow command: stamp took 60 ms"], #[]]) },
    { name :=
        "a command that takes less than the threshold, or exactly as long, produces no log entry"
      run := pure (logged keys (presses "C-c 2 C-c 5") == #[#[], #[], #[], #[]]) },
    { name :=
        "a slow command that was refused is logged like one that finished, with the time the command took and not the time its rollback took"
      run :=
        pure (logged keys (presses "C-c r") == #[#[], #["slow command: refused took 70 ms"]]) },
    { name := "an invocation of a name no command is registered under produces no log entry"
      run := pure (logged keys (presses "C-c n") == #[#[], #[]]) },
    { name :=
        "the threshold a step is handed by default is the loop's, 100 milliseconds: a command of ten requests is not logged and one of eleven is"
      run :=
        let keys :=
          dispatchKeys [("C-c a", invoke "ten"), ("C-c b", invoke "eleven")]
            [("ten", asking 10), ("eleven", asking 11)]
        pure
          (keys.slowAfter == Loop.slowAfter && Loop.slowAfter == 100 &&
            logged keys (presses "C-c a C-c b") ==
              #[#[], #[], #[], #["slow command: eleven took 110 ms"]]) }]

/-- Splits the window a command was called on, along rows, by the state
request, with markers the command makes on the buffer's text first: the new
view. Refused with `noSuchMarker` if the split is. -/
def splitting (call : Call) : EditorM ViewId := do
  let text := call.target.buffer.text
  let scroll ← text.mark (.anchor { offset := 0, bias := .before })
  let selection ← text.mark (.selection { ranges := #[⟨0, 0⟩] })
  match ← EditorState.ask (.split call.target.window.id .rows scroll selection) with
  | .ok view =>
    return view
  | .error _ =>
    throw .noSuchMarker

/-- The checks of a command's state requests in the loop
(`Editor/Command/Dispatch.lean`, `Editor/Loop.lean`), on the editor's
models: the loop answers them from the state it holds, keeps the state a
command that ran to its end left, and goes back to the state from before
one that did not. -/
def dispatchStateChecks : List Check :=
  let split : Dispatched := fun call => do
    discard <| splitting call
    return none
  let moving : Dispatched :=
    failingAfter fun call => do
      -- A move in the history, recorded as a command records one: an undo
      -- to the root, the moved tree set as the buffer's, and then an edit.
      let state ← editorState
      let some buffer := state.buffer? call.target.window.buffer | throw .noSuchText
      let some moved ← (← buffer.history.sync).undo Origin.user | throw .noInverse
      discard <| EditorState.ask (.setHistory call.target.window.buffer moved.tree)
      buffer.text.insert 0 "x"
  let keys :=
    dispatchKeys [("C-c s", invoke "split"), ("C-c f", invoke "fail"), ("C-c m", invoke "moving")]
      [("split", split), ("fail", failingAfter fun call => discard <| splitting call),
        ("moving", moving)]
  let oneWindow : Split := .split .rows (.window ⟨0⟩) .minibuffer
  [{  name :=
        "a key's command that splits its window by a state request: the loop keeps the new window after the step, well formed, and the scene shows both views"
      run :=
        pure <|
          match dispatched keys (presses "C-c s") with
          | some ((loop, _), scenes, _) =>
            loop.state.wellFormed && loop.state.windows.map (·.id) == #[⟨0⟩, ⟨1⟩] &&
              loop.state.frame.tree ==
                .split .rows (.split .rows (.window ⟨0⟩) (.window ⟨1⟩)) .minibuffer &&
              loop.state.echo == "" &&
              scenes.back?.map (·.views.map (·.id)) == some #[⟨0⟩, ⟨1⟩]
          | none => false },
    { name :=
        "a command that splits its window and is then refused leaves the state from before it: one window, the tree as it was, and the refusal in the echo"
      run :=
        pure <|
          match dispatched keys (presses "C-c f") with
          | some ((loop, _), scenes, _) =>
            loop.state.wellFormed && loop.state.windows.map (·.id) == #[⟨0⟩] &&
              loop.state.frame.tree == oneWindow &&
              loop.state.echo == "fail: refused: bad range" &&
              scenes.back?.map (·.views.map (·.id)) == some #[⟨0⟩]
          | none => false },
    { name :=
        "the interrupt flag is asked before each request that reaches the models and not before a state request: with the interrupt key arriving at a command's second ask, the state request before it is answered, the text request after it is not made, and the state the command had reached is handed back"
      run :=
        pure <|
          let command : EditorM Unit := do
            discard <| createText "one"
            EditorState.ask (.message "said")
            discard <| createText "two"
            EditorState.ask (.message "late")
          let program : EditorM (Guarded Unit × EditorState) := do
            command.dispatched {} (← EditorState.initial ⟨640, 480⟩)
          let ran (arrivesAfter : Nat) :=
            program.runModel { editorModel with watch := { arrivesAfter := some arrivesAfter } }
          (match ran 1 with
            | (.ok (outcome, state), model) =>
              outcome == .interrupted && state.echo == "said" &&
                model.texts.contents == #["", "one"]
            | (.error _, _) => false) &&
            -- Two asks for the four requests: the key placed two asks away
            -- has not arrived when the command ends, and is one ask off.
            match ran 2 with
            | (.ok (outcome, state), model) =>
              outcome == .finished () && state.echo == "late" &&
                model.texts.contents == #["", "one", "two"] &&
                model.watch.arrivesAfter == some 0 &&
                model.watch.arrived == 0
            | (.error _, _) => false },
    { name :=
        "a command that edits, says something, gives up and would edit again ends as having given up, with its reason and the state it had reached: the first edit was made, the second was not, and a try round the call does not go on"
      run :=
        pure <|
          let command : EditorM Unit := do
            discard <| createText "one"
            EditorState.ask (.message "said")
            try
              giveUp "cannot go on"
            catch _ =>
              pure ()
            discard <| createText "two"
            EditorState.ask (.message "late")
          let program : EditorM (Guarded Unit × EditorState) := do
            command.dispatched {} (← EditorState.initial ⟨640, 480⟩)
          match program.runModel editorModel with
          | (.ok (outcome, state), model) =>
            outcome == .gaveUp "cannot go on" && state.echo == "said" &&
              model.texts.contents == #["", "one"]
          | (.error _, _) => false },
    { name :=
        "a command that gives up where no loop dispatches it is refused with badSelection, and nothing of its reason is kept: the handler of the runners changes nothing"
      run :=
        pure <|
          let command : EditorM Unit := do
            discard <| createText "one"
            giveUp "cannot go on"
          match command.runModel editorModel with
          | (.error refusal, model) => refusal == .badSelection && model.texts.contents == #["one"]
          | (.ok _, _) => false },
    { name :=
        "a command that edits, says something, breaks off and would edit again ends as having broken off, with its reason and the state it had reached: the first edit was made, the second was not, and a try round the call does not go on"
      run :=
        pure <|
          let command : EditorM Unit := do
            discard <| createText "one"
            EditorState.ask (.message "said")
            try
              breakOff "far enough"
            catch _ =>
              pure ()
            discard <| createText "two"
            EditorState.ask (.message "late")
          let program : EditorM (Guarded Unit × EditorState) := do
            command.dispatched {} (← EditorState.initial ⟨640, 480⟩)
          match program.runModel editorModel with
          | (.ok (outcome, state), model) =>
            outcome == .brokeOff "far enough" && state.echo == "said" &&
              model.texts.contents == #["", "one"]
          | (.error _, _) => false },
    { name :=
        "a command that breaks off where no loop dispatches it is refused with badSelection, and nothing of its reason is kept: the handler of the runners changes nothing"
      run :=
        pure <|
          let command : EditorM Unit := do
            discard <| createText "one"
            breakOff "far enough"
          match command.runModel editorModel with
          | (.error refusal, model) => refusal == .badSelection && model.texts.contents == #["one"]
          | (.ok _, _) => false },
    { name :=
        "a command that edits, moves in the history and records the move, edits again and is then refused: the rollback reverts the edit made since the move from the tree the command left, leaves the text at the node the move reached, says the command moved in the history, and what was undone can be redone"
      run :=
        pure <|
          let program : EditorM (String × String × Array String × String) := do
            let loop : TestLoop := { state := ← holding "one" #[⟨3, 3⟩] }
            -- The first step records the insertion as a step of the history.
            let (loop, _) ← stepsWith keys loop ([pressF5] ++ presses "C-c m")
            let target ← focusedOf loop
            let text ← target.buffer.text.read
            let some _ ← target.buffer.history.redo Origin.user | throw .noInverse
            return (text, loop.state.echo, loop.state.windows.map fun _ => "window",
                ← target.buffer.text.read)
          (program.runModel editorModel).1.toOption ==
            some
              ("", "moving: refused: bad range; the command moved in the history", #["window"],
                "one") },
    { name :=
        "a command that asks which command an ex name is bound to is answered what the loop was told of the registry: the binding of a name it knows, with what it takes, and none for another name; the state is as it was"
      run :=
        pure <|
          let greet : Ex.Binding := { name := "greet", command := "greet-named", takes := .text }
          let registered : Loop.Registered :=
            { ex := fun name => if name == "greet" then some greet else none }
          let command : EditorM (Option Ex.Binding × Option Ex.Binding) := do
            return (← exBinding "greet", ← exBinding "other")
          let program : EditorM (Guarded (Option Ex.Binding × Option Ex.Binding) × Bool) := do
            let start ← EditorState.initial ⟨640, 480⟩
            let (outcome, state) ← command.dispatched registered start
            return (outcome, state == start)
          (program.runModel editorModel).1.toOption == some (.finished (some greet, none), true) },
    { name :=
        "what the loop is told of a registry's ex bindings is the latest entry of each name: config's binding of a name a compiled binding has, the compiled one of a name config does not bind, and none for a name nobody bound"
      run :=
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceEx .compiled
                #[{ name := "w", command := "compiled" },
                  { name := "q", command := "kept" }]).replaceEx
            .config #[{ name := "w", command := "config", takes := .text }]
        let told := registry.registered
        pure
          (told.ex "w" == some { name := "w", command := "config", takes := .text } &&
            told.ex "q" == some { name := "q", command := "kept" } &&
            told.ex "missing" == none) },
    { name :=
        "a command that asks for the command of a name to be run inside it: the command the loop was told of under that name runs there, with the call it is handed, before the asking command goes on, and what it said is in the state the asking command then reads; a name the loop was told no command of is answered false, and nothing runs"
      run :=
        pure <|
          let inner (call : Call) : EditorM Unit := do
            discard <| createText "inner"
            message s!"handed {call.arguments.length} arguments"
          let registered : Loop.Registered :=
            { command := fun name => if name == "inner" then some inner else none }
          let command : EditorM (Bool × String × Bool) := do
            let some target := (← editorState).focusedTarget? | throw .noSuchText
            let ran ← runCommand "inner" { target, arguments := [.nat 1, .nat 2] }
            let said := (← editorState).echo
            let missing ← runCommand "other" { target }
            discard <| createText "outer"
            return (ran, said, missing)
          let program : EditorM (Guarded (Bool × String × Bool) × EditorState) := do
            command.dispatched registered (← EditorState.initial ⟨640, 480⟩)
          match program.runModel editorModel with
          | (.ok (outcome, _), model) =>
            outcome == .finished (true, "handed 2 arguments", false) &&
              model.texts.contents == #["", "inner", "outer"]
          | (.error _, _) => false },
    { name :=
        "a command run inside another is part of it: one that gives up ends the asking command as having given up, one that is refused refuses it, and one that the interrupt stops at a request ends it as interrupted, each with nothing of the asking command run after it"
      run :=
        pure <|
          let registered : Loop.Registered :=
            {
              command := fun name =>
                match name with
                | "quits" => some fun _ => giveUp "no"
                | "fails" => some fun _ => throw .badRange
                | "works" =>
                  some fun _ => do
                    discard <| createText "one"
                    discard <| createText "two"
                | _ => none }
          let asking (name : String) : EditorM Unit := do
            let some target := (← editorState).focusedTarget? | throw .noSuchText
            discard <| runCommand name { target }
            discard <| createText "late"
          let ended (name : String) (watch : WatchModel := {}) :
            Option (Guarded Unit × Array String) :=
            let program : EditorM (Guarded Unit × EditorState) := do
              (asking name).dispatched registered (← EditorState.initial ⟨640, 480⟩)
            match program.runModel { editorModel with watch } with
            | (.ok (outcome, _), model) => some (outcome, model.texts.contents)
            | (.error _, _) => none
          ended "quits" == some (.gaveUp "no", #[""]) &&
            ended "fails" == some (.refused .badRange, #[""]) &&
            ended "works" == some (.finished (), #["", "one", "two", "late"]) &&
            ended "works" { arrivesAfter := some 1 } == some (.interrupted, #["", "one"]) },
    { name :=
        "a command that asks for another to be run inside it where no loop dispatches it is answered false: the handler of the runners knows no registry"
      run :=
        pure <|
          let command : EditorM Bool := do
            let state ← EditorState.initial ⟨640, 480⟩
            let some target := state.focusedTarget? | throw .noSuchText
            runCommand "inner" { target }
          (command.runModel editorModel).1.toOption == some false }]

/-- The refusal `program` ends with, if it is refused. -/
def refusalOf {α : Type} (program : TextM α) : TextM (Option TextError) := do
  match ← observing program with
  | .ok _ =>
    return none
  | .error refusal =>
    return some refusal

/-- The refusals reading each of a window's two markers ends with, the
scroll anchor's first. -/
def markerRefusals (window : Window) : TextM (List (Option TextError)) :=
  return [← refusalOf (window.scroll.text.marker window.scroll),
      ← refusalOf (window.selection.text.marker window.selection)]

/-- The checks of what the loop gives up after a command (`Editor/Loop.lean`,
"What a finished command gave up"), on the editor's models: the markers of
a window a command closed, the text of a buffer it removed and the snapshot
of a save it ended, once the command has run to its end and not before. -/
def dispatchGiveUpChecks : List Check :=
  let asks (requests : List StateRequest) : EditorM Unit := do
    for request in requests do
      discard <| EditorState.ask request
  let bound (run : Dispatched) := dispatchKeys [("C-c g", invoke "go")] [("go", run)]
  let ran (run : EditorM Unit) : Loop.Keys TestScheme.scheme :=
    bound fun _ => do
      run
      return none
  [{  name :=
        "after a command that closed a window has run to its end, the window's two markers are given up: each refuses noSuchMarker, the other windows' markers still answer, and nothing is in the echo"
      run :=
        pure <|
          let program :
            EditorM (List (Option TextError) × List (Option TextError) × String × Bool) := do
            let state ← threeWindows
            let some closed := state.window? ⟨1⟩ | throw .noSuchMarker
            let some stays := state.window? ⟨2⟩ | throw .noSuchMarker
            let (loop, _) ←
              stepsWith (ran (asks [.removeWindow ⟨1⟩])) ({ state } : TestLoop) (presses "C-c g")
            return (← markerRefusals closed, ← markerRefusals stays, loop.state.echo,
                loop.state.wellFormed && loop.state.windows.map (·.id) == #[⟨0⟩, ⟨2⟩])
          (program.runModel editorModel).1.toOption ==
            some ([some .noSuchMarker, some .noSuchMarker], [none, none], "", true) },
    { name :=
        "after a command that removed a buffer has run to its end, the buffer's text is released: it refuses noSuchText, the other buffers' texts still answer, and nothing is in the echo"
      run :=
        pure <|
          let program : EditorM (List (Option TextError) × String × Bool) := do
            let (state, text) ← hiddenBuffer
            let (loop, _) ←
              stepsWith (ran (asks [.removeBuffer ⟨2⟩])) ({ state } : TestLoop) (presses "C-c g")
            return ([← refusalOf text.read, ← refusalOf (⟨0⟩ : TextId).read,
                  ← refusalOf (⟨1⟩ : TextId).read],
                loop.state.echo, loop.state.wellFormed && loop.state.buffer? ⟨2⟩ == none)
          (program.runModel editorModel).1.toOption ==
            some ([some .noSuchText, none, none], "", true) },
    { name :=
        "a buffer a command removed keeps its empty slot through the loop's pass over the histories, in the step that removed it and in the next event's: the buffers after it keep their ids, the window on one still shows it, and a buffer added afterwards gets an id no buffer had"
      run :=
        pure <|
          -- `hidden`, which no window shows, is in the slot before `other`,
          -- which view 1 shows.
          let middle : TextM EditorState := do
            let state ← EditorState.initial ⟨640, 480⟩
            let hidden ← createText "hidden"
            let text ← createText "other"
            let scroll ← text.mark (.anchor { offset := 0, bias := .before })
            let selection ← text.mark (.selection { ranges := #[⟨0, 0⟩] })
            return {
                state with
                buffers :=
                  state.buffers ++
                    #[some { name := "hidden", text := hidden, history := ← UndoTree.over hidden },
                      some { name := "other", text, history := ← UndoTree.over text }]
                windows := state.windows.push { id := ⟨1⟩, buffer := ⟨2⟩, scroll, selection }
                frame :=
                  { state.frame with
                    tree :=
                      .split .rows (.split .columns (.window ⟨0⟩) (.window ⟨1⟩)) .minibuffer } }
          let removing : Dispatched := fun _ => do
            asks [.removeBuffer ⟨1⟩]
            return none
          let adding : Dispatched := fun _ => do
            let text ← createText "new"
            let .ok id ←
              EditorState.ask (.addBuffer "new" text (← UndoTree.over text)) | throw .noSuchText
            EditorState.ask (.message s!"added {id.index}")
            return none
          let keys :=
            dispatchKeys [("C-c g", invoke "go"), ("C-c a", invoke "add")]
              [("go", removing), ("add", adding)]
          let slots (loop : TestLoop) : Array (Option String) × Option String × Bool :=
            (loop.state.buffers.map (·.map (·.name)), (loop.state.target? ⟨1⟩).map (·.buffer.name),
              loop.state.wellFormed)
          let program : EditorM (List (Array (Option String) × Option String × Bool) × String) := do
            let (removed, _) ← stepsWith keys ({ state := ← middle } : TestLoop) (presses "C-c g")
            let (next, _) ← stepsWith keys removed [pressF5]
            let (added, _) ← stepsWith keys next (presses "C-c a")
            return ([slots removed, slots next, slots added], added.state.echo)
          match program.runModel editorModel with
          | (.ok (seen, echo), model) =>
            let kept := (#[some "scratch", none, some "other"], some "other", true)
            seen ==
                [kept, kept,
                  (#[some "scratch", none, some "other", some "new"], some "other", true)] &&
              echo == "added 3" &&
              (model.display.scenes.back?.map fun scene => scene.views.map (shownText model)) ==
                some #[some "", some "other"]
          | (.error _, _) => false },
    { name :=
        "a command that closes a window and removes the buffer it showed gives up both with nothing refused: the markers before the text, and the scene shows the window that is left"
      run :=
        pure <|
          match
            dispatched (ran (asks [.removeWindow ⟨1⟩, .removeBuffer ⟨1⟩])) (presses "C-c g")
              twoBuffers with
          | some ((loop, _), scenes, model) =>
            loop.state.wellFormed && loop.state.echo == "" && model.texts.contents == #[""] &&
              (scenes.back?.map fun scene => (scene.echo, scene.views.map (·.id))) ==
                some ("", #[⟨0⟩])
          | none => false },
    { name :=
        "a window shown another buffer has the markers it had given up, and keeps the ones it was shown with"
      run :=
        pure <|
          let showing : EditorM Unit := do
            let text : TextId := ⟨1⟩
            let scroll ← text.mark (.anchor { offset := 0, bias := .before })
            let selection ← text.mark (.selection { ranges := #[⟨0, 0⟩] })
            asks [.show ⟨0⟩ ⟨1⟩ scroll selection]
          let program : EditorM (List (Option TextError) × List (Option TextError) × String) := do
            let state ← twoBuffers
            let some was := state.window? ⟨0⟩ | throw .noSuchMarker
            let (loop, _) ← stepsWith (ran showing) ({ state } : TestLoop) (presses "C-c g")
            let some now := loop.state.window? ⟨0⟩ | throw .noSuchMarker
            return (← markerRefusals was, ← markerRefusals now, loop.state.echo)
          (program.runModel editorModel).1.toOption ==
            some ([some .noSuchMarker, some .noSuchMarker], [none, none], "") },
    { name :=
        "a command that closed a window and removed its buffer and was then refused gave up nothing: the window and the buffer are back, the window's markers and the buffer's text answer, and the scene shows both views"
      run :=
        pure <|
          let failing : Dispatched :=
            failingAfter fun _ => asks [.removeWindow ⟨1⟩, .removeBuffer ⟨1⟩]
          let program : EditorM (List (Option TextError) × String × Bool × String) := do
            let state ← twoBuffers
            let some closed := state.window? ⟨1⟩ | throw .noSuchMarker
            let (loop, _) ← stepsWith (bound failing) ({ state } : TestLoop) (presses "C-c g")
            return (← markerRefusals closed, ← (⟨1⟩ : TextId).read,
                loop.state.wellFormed && loop.state.windows == state.windows &&
                  loop.state.buffer? ⟨1⟩ == state.buffer? ⟨1⟩ &&
                  loop.state.frame == state.frame,
                loop.state.echo)
          match program.runModel editorModel with
          | (.ok result, model) =>
            result == ([none, none], "other", true, "go: refused: bad range") &&
              (model.display.scenes.back?.map fun scene => scene.views.map (shownText model)) ==
                some #[some "", some "other"]
          | (.error _, _) => false },
    { name :=
        "a release the store refuses, of a text the command released itself before it removed the buffer, is in the echo area of the scene, and the buffer is still removed"
      run :=
        pure <|
          let twice : EditorM Unit := do
            (⟨2⟩ : TextId).release
            asks [.removeBuffer ⟨2⟩]
          match dispatched (ran twice) (presses "C-c g") ((·.1) <$> hiddenBuffer) with
          | some ((loop, _), scenes, _) =>
            loop.state.echo == "refused: no such text" && loop.state.buffer? ⟨2⟩ == none &&
              loop.state.wellFormed &&
              scenes.back?.map (·.echo) == some "refused: no such text"
          | none => false },
    { name :=
        "the text of a buffer a command removed is not released while a buffer that is left is over the same text: the text still reads, the view of the buffer that is left shows it, and nothing is in the echo"
      run :=
        pure <|
          -- `alias`, which no window shows, is over the text of `other`,
          -- which view 1 shows.
          let shared : TextM EditorState := do
            let state ← twoBuffers
            let text : TextId := ⟨1⟩
            return { state with
                buffers :=
                  state.buffers.push
                    (some { name := "alias", text, history := ← UndoTree.over text }) }
          let program : EditorM (Option TextError × Array (Option String) × String × Bool) := do
            let (loop, _) ←
              stepsWith (ran (asks [.removeBuffer ⟨2⟩])) ({ state := ← shared } : TestLoop)
                  (presses "C-c g")
            return (← refusalOf (⟨1⟩ : TextId).read, loop.state.buffers.map (·.map (·.name)),
                loop.state.echo, loop.state.wellFormed)
          match program.runModel editorModel with
          | (.ok result, model) =>
            result == (none, #[some "scratch", some "other", none], "", true) &&
              (model.display.scenes.back?.map fun scene =>
                  (scene.echo, scene.views.map (shownText model))) ==
                some ("", #[some "", some "other"])
          | (.error _, _) => false },
    { name :=
        "a marker the store refuses to give up, the selection marker of a window the command gave up itself before it closed the window, is in the echo area of the scene: the window is still closed, and its other marker is still given up"
      run :=
        pure <|
          let program : EditorM (List (Option TextError) × String × Array ViewId × Bool) := do
            let state ← threeWindows
            let some closed := state.window? ⟨1⟩ | throw .noSuchMarker
            let twice : EditorM Unit := do
              closed.selection.text.unmark closed.selection
              asks [.removeWindow ⟨1⟩]
            let (loop, _) ← stepsWith (ran twice) ({ state } : TestLoop) (presses "C-c g")
            return (← markerRefusals closed, loop.state.echo, loop.state.windows.map (·.id),
                loop.state.wellFormed)
          match program.runModel editorModel with
          | (.ok result, model) =>
            result ==
                ([some .noSuchMarker, some .noSuchMarker], "refused: no such marker", #[⟨0⟩, ⟨2⟩],
                  true) &&
              model.display.scenes.back?.map (·.echo) == some "refused: no such marker"
          | (.error _, _) => false },
    { name :=
        "the snapshot of a save is released once a command that ended the save has run to its end, and not before: it still reads after the command that took it and began the save, and refuses noSuchSnapshot after the command that ended it, whether the save wrote the file or was refused, with nothing in the echo"
      run :=
        pure <|
          let program (key : String) :
            EditorM (Option TextError × Option TextError × Option Buffer.Saving × String) := do
            let (begun, _) ←
              stepsWith saveKeys ({ state := ← savable } : TestLoop) (presses "C-c g")
            let some taken := (savingOf begun.state).map (·.snapshot) | throw .noSuchSnapshot
            let held ← refusalOf taken.read
            let (ended, _) ← stepsWith saveKeys begun (presses key)
            return (held, ← refusalOf taken.read, savingOf ended.state, ended.state.echo)
          ["C-c e", "C-c n"].all fun key =>
            ((program key).runModel editorModel).1.toOption ==
              some (none, some .noSuchSnapshot, none, "") },
    { name :=
        "a buffer removed while its save is in flight has the save's snapshot released with its text: each refuses, and nothing is in the echo"
      run :=
        pure <|
          let program : EditorM (Option TextError × Option TextError × String) := do
            let (begun, _) ←
              stepsWith saveKeys ({ state := ← savable } : TestLoop) (presses "C-c g")
            let some taken := (savingOf begun.state).map (·.snapshot) | throw .noSuchSnapshot
            let (removed, _) ← stepsWith saveKeys begun (presses "C-c r")
            return (← refusalOf taken.read, ← refusalOf (⟨2⟩ : TextId).read, removed.state.echo)
          (program.runModel editorModel).1.toOption ==
            some (some .noSuchSnapshot, some .noSuchText, "") },
    { name :=
        "a command that ended a save and was then refused released nothing: the snapshot still reads, and the buffer's file is as it was before the command, with the save in flight and its old stamp"
      run :=
        pure <|
          let program : EditorM (Option TextError × Bool × String) := do
            let (begun, _) ←
              stepsWith saveKeys ({ state := ← savable } : TestLoop) (presses "C-c g")
            let some taken := (savingOf begun.state).map (·.snapshot) | throw .noSuchSnapshot
            let (failed, _) ← stepsWith saveKeys begun (presses "C-c f")
            return (← refusalOf taken.read,
                (savingOf failed.state).isSome &&
                  (failed.state.buffer? ⟨2⟩).map (·.file) == (begun.state.buffer? ⟨2⟩).map (·.file),
                failed.state.echo)
          (program.runModel editorModel).1.toOption ==
            some (none, true, "fail: refused: bad range") },
    { name :=
        "a release of a save's snapshot that the store refuses, because the command released the snapshot itself before it ended the save, is in the echo area of the scene, and the save is still ended"
      run :=
        pure <|
          let program : EditorM (Option Buffer.Saving × String) := do
            let (begun, _) ←
              stepsWith saveKeys ({ state := ← savable } : TestLoop) (presses "C-c g")
            let (ended, _) ← stepsWith saveKeys begun (presses "C-c t")
            return (savingOf ended.state, ended.state.echo)
          match program.runModel editorModel with
          | (.ok result, model) =>
            result == (none, "refused: no such snapshot") &&
              model.display.scenes.back?.map (·.echo) == some "refused: no such snapshot"
          | (.error _, _) => false },
    { name :=
        "after a command that cancelled a prompt has run to its end the minibuffer is given up, though the last scene named a snapshot of its text: its text refuses noSuchText and each of its window's markers refuses, the window's text and markers still answer, and nothing is in the echo; the same after a command that accepted it"
      run :=
        pure <|
          [cancelPrompt, acceptPrompt].all fun close =>
            let keys := ran (discard close)
            let program :
              EditorM
                (Option TextError ×
                  Bool × Option TextError × List (Option TextError) × String × Bool) :=
              do
              let state ← promptedOver "ab"
              let some minibuffer := state.window? ⟨1⟩ | throw .noSuchMarker
              let some window := state.window? ⟨0⟩ | throw .noSuchMarker
              -- A scene of the open prompt first, so that the loop holds a
              -- snapshot of the minibuffer's text when the text is released.
              let (shown, _) ← stepsWith keys ({ state } : TestLoop) [pressF5]
              let (loop, _) ← stepsWith keys shown (presses "C-c g")
              return (← refusalOf minibuffer.scroll.text.read,
                  (← markerRefusals minibuffer).all (·.isSome), ← refusalOf window.scroll.text.read,
                  ← markerRefusals window, loop.state.echo,
                  loop.state.wellFormed && loop.state.prompt == none &&
                    loop.state.windows.map (·.id) == #[⟨0⟩])
            (program.runModel editorModel).1.toOption ==
              some (some .noSuchText, true, none, [none, none], "", true) },
    { name :=
        "a command that accepts a prompt and is then refused gives nothing up: the prompt is open again, its text reads what was typed, its window's markers answer, and nothing is answered"
      run :=
        pure <|
          let keys := bound (failingAfter fun _ => discard acceptPrompt)
          let program : EditorM (Option String × List (Option TextError) × String × Bool × Bool) :=
            do
            let state ← promptedOver "ab"
            let some minibuffer := state.window? ⟨1⟩ | throw .noSuchMarker
            let (loop, steps) ←
              stepsWith keys ({ state } : TestLoop) (.commit "c" :: presses "C-c g")
            return ((← observing minibuffer.scroll.text.read).toOption, ← markerRefusals minibuffer,
                loop.state.echo,
                loop.state.prompt == state.prompt && loop.state.frame.focused == ⟨1⟩ &&
                  loop.state.wellFormed,
                loop.state.answered.isEmpty &&
                  steps.back?.map (·.ended) == some (some (.refused .badRange)))
          (program.runModel editorModel).1.toOption ==
            some (some "abc", [none, none], "go: refused: bad range", true, true) }]

/-- A scheme written for the closed-view checks: the test scheme, with the
views it was stepped for kept beside its state, in the order they first
had a key, and a view it is told is closed dropped from them. -/
def remembering : InputScheme :=
  { State := TestScheme.State × List ViewId
    Binding := Invocation
    init := ({}, [])
    step := fun maps view state key =>
      let (next, yielded) := TestScheme.step maps view state.1 key
      ((next, if state.2.contains view then state.2 else state.2 ++ [view]), yielded)
    pending := (·.1.pending)
    command := fun name => { command := name }
    closeView := fun view state => (state.1, state.2.filter (· != view)) }

/-- The views `remembering` keeps in a loop's two states of the scheme: the
one after the last key, and the one at rest. -/
def remembered (loop : Loop remembering) : List ViewId × List ViewId :=
  let input : TestScheme.State × List ViewId := loop.input
  let atRest : TestScheme.State × List ViewId := loop.atRest
  (input.2, atRest.2)

/-- The checks of the scheme's notice of a closed view in the loop
(`Editor/Loop.lean`), on the editor's models. -/
def dispatchCloseViewChecks : List Check :=
  let focus : Dispatched := fun _ => do
    discard <| EditorState.ask (.focus ⟨1⟩)
    return none
  let close (call : Call) : EditorM Unit :=
    discard <| EditorState.ask (.removeWindow call.target.window.id)
  let keys : Loop.Keys remembering :=
    { maps := fun _ _ =>
        [Keymap.ofList
            [(ModelTest.keys "C-c 1", invoke "focus"), (ModelTest.keys "C-c x", invoke "close"),
              (ModelTest.keys "C-c f", invoke "fail")]]
      command? := fun name =>
        ([("focus", focus),
                  ("close", fun call => do
                    close call
                    return none),
                  ("fail", failingAfter close)].find?
              (·.1 == name)).map
          (·.2) }
  let program (last : String) : EditorM ((List ViewId × List ViewId) × Array ViewId) := do
    let loop : Loop remembering := { state := ← threeWindows }
    -- The key after the focus moved is view 1's, yields nothing and leaves
    -- nothing pending: the scheme then keeps view 1 in both its states.
    let (loop, _) ← stepsWith keys loop (presses "C-c 1" ++ [pressF5] ++ presses last)
    return (remembered loop, loop.state.windows.map (·.id))
  [{  name :=
        "after a command closed a view, the loop has told its scheme: neither state of the scheme it keeps holds anything for the view, and what they hold for the other views is kept"
      run :=
        pure <|
          ((program "C-c").runModel editorModel).1.toOption ==
              some (([⟨0⟩, ⟨1⟩], [⟨0⟩, ⟨1⟩]), #[⟨0⟩, ⟨1⟩, ⟨2⟩]) &&
            ((program "C-c x").runModel editorModel).1.toOption ==
              some (([⟨0⟩], [⟨0⟩]), #[⟨0⟩, ⟨2⟩]) },
    { name :=
        "a command that closed a view and was then refused closed nothing: the scheme is told of no closed view"
      run :=
        pure <|
          ((program "C-c f").runModel editorModel).1.toOption ==
            some (([⟨0⟩, ⟨1⟩], [⟨0⟩, ⟨1⟩]), #[⟨0⟩, ⟨1⟩, ⟨2⟩]) }]

/-- What `noticing` was told of a view. -/
inductive Notice where
  /-- The view is the minibuffer's. -/
  | minibuffer (view : ViewId)
  /-- The view is closed. -/
  | closed (view : ViewId)
  deriving DecidableEq, Repr

/-- A scheme written for the minibuffer-notice checks: the test scheme, with
what it was told kept beside its state, in the order it was told. -/
def noticing : InputScheme :=
  { State := TestScheme.State × List Notice
    Binding := Invocation
    init := ({}, [])
    step := fun maps view state key =>
      let (next, yielded) := TestScheme.step maps view state.1 key
      ((next, state.2), yielded)
    pending := (·.1.pending)
    command := fun name => { command := name }
    closeView := fun view state => (state.1, state.2 ++ [.closed view])
    openMinibuffer := fun view state => (state.1, state.2 ++ [.minibuffer view]) }

/-- What `noticing` was told, in a loop's two states of the scheme: the one
after the last key, and the one at rest. -/
def noticed (loop : Loop noticing) : List Notice × List Notice :=
  let input : TestScheme.State × List Notice := loop.input
  let atRest : TestScheme.State × List Notice := loop.atRest
  (input.2, atRest.2)

/-- The checks of the scheme's notice of the minibuffer's view in the loop
(`Editor/Loop.lean`), on the editor's models. -/
def dispatchMinibufferNoticeChecks : List Check :=
  let asks : EditorM Unit := discard <| prompt "Name: " asked
  let ran (run : EditorM Unit) : Dispatched := fun _ => do
    run
    return none
  let keys : Loop.Keys noticing :=
    { maps := fun _ _ =>
        [Keymap.ofList
            [(ModelTest.keys "C-c a", invoke "ask"), (ModelTest.keys "C-c f", invoke "fail"),
              (ModelTest.keys "C-c y", invoke "accept"), (ModelTest.keys "C-c s", invoke "swap"),
              (ModelTest.keys "C-c n", invoke "idle")]]
      command? := fun name =>
        ([("ask", ran asks), ("fail", failingAfter fun _ => asks), ("idle", ran (pure ())),
                  ("accept", ran (discard acceptPrompt)),
                  ("swap",
                    ran do
                      discard cancelPrompt
                      asks)].find?
              (·.1 == name)).map
          (·.2) }
  let told (typed : String) : Option ((List Notice × List Notice) × Option ViewId) :=
    let program : EditorM ((List Notice × List Notice) × Option ViewId) := do
      let loop : Loop noticing := { state := ← EditorState.initial ⟨640, 480⟩ }
      let (loop, _) ← stepsWith keys loop (presses typed)
      return (noticed loop, loop.state.minibufferView?)
    (program.runModel editorModel).1.toOption
  -- What the scheme was told once a prompt was asked for and `next` then ran
  -- one more command from the loop with the prompt open, with the
  -- minibuffer's view after that command and how it ended.
  let toldAfter (next : Loop noticing → EditorM (Option (Loop.Stepped noticing))) :
    Option ((List Notice × List Notice) × Option ViewId × Option Loop.Ending) :=
    let program :
      EditorM (Option ((List Notice × List Notice) × Option ViewId × Option Loop.Ending)) := do
      let loop : Loop noticing := { state := ← EditorState.initial ⟨640, 480⟩ }
      let (loop, _) ← stepsWith keys loop (presses "C-c a")
      return (← next loop).map fun stepped =>
          (noticed stepped.loop, stepped.loop.state.minibufferView?, stepped.ended)
    (program.runModel editorModel).1.toOption.join
  let typing (typed : String) (loop : Loop noticing) : EditorM (Option (Loop.Stepped noticing)) :=
    (·.2.back?) <$> stepsWith keys loop (presses typed)
  let both (notices : List Notice) := (notices, notices)
  [{  name :=
        "after a command that asked for a prompt, the loop has told its scheme that the new view is the minibuffer's, once, in both states of the scheme it keeps"
      run := pure (told "C-c a" == some (both [.minibuffer ⟨1⟩], some ⟨1⟩)) },
    { name :=
        "a key's command that runs to its end while the prompt stays open opened nothing: the scheme is told of the minibuffer's view by the command that opened it alone, so both its states still hold the one notice after a command that does nothing, and after one that asks again and is refused as a value"
      run :=
        pure <|
          ["C-c n", "C-c a"].all fun typed =>
            toldAfter (typing typed) == some (both [.minibuffer ⟨1⟩], some ⟨1⟩, some .finished) },
    { name :=
        "a job's command that runs to its end while the prompt stays open opened nothing: after its delivery both states of the scheme still hold the one notice"
      run :=
        pure
          (toldAfter (fun loop => return some (← loop.deliver keys "job" (pure ()))) ==
            some (both [.minibuffer ⟨1⟩], some ⟨1⟩, some .finished)) },
    { name :=
        "a command that asked for a prompt and was then refused opened nothing: the scheme is told nothing"
      run := pure (told "C-c f" == some (both [], none)) },
    { name :=
        "after the command that accepted the prompt, the loop has told both states of its scheme that the minibuffer's view is closed"
      run := pure (told "C-c a C-c y" == some (both [.minibuffer ⟨1⟩, .closed ⟨1⟩], none)) },
    { name :=
        "a command that closes one prompt and asks for another tells the scheme the first view is closed and then that the second is the minibuffer's"
      run :=
        pure
          (told "C-c a C-c s" ==
            some (both [.minibuffer ⟨1⟩, .closed ⟨1⟩, .minibuffer ⟨2⟩], some ⟨2⟩)) }]

/-- The history of the buffer `buffer` in `loop`'s state, as the loop keeps
it. -/
def treeOf {scheme : InputScheme} (loop : Loop scheme) (buffer : Nat := 0) : EditorM UndoTree := do
  let some held := loop.state.buffer? ⟨buffer⟩ | throw .noSuchText
  return held.history

/-- The checks of undo from a command in the loop (`Editor/Api.lean`,
`Editor/Loop.lean`), on the editor's models: a move in the history a key's
command made is the loop's after the step, and a boundary set by a command
that does not run to its end is rolled back with its edits; and, with the
scheme `switching`, two of whose keys begin and end an insert session of
the focused view, that what is edited in a session is one step of the
history. -/
def dispatchUndoChecks : List Check :=
  let undo : Dispatched := fun call => do
    discard <| call.target.window.buffer.undo
    return none
  let redo : Dispatched := fun call => do
    discard <| call.target.window.buffer.redo
    return none
  let keys :=
    dispatchKeys [("C-c s", invoke "stamp"), ("C-c u", invoke "undo"), ("C-c r", invoke "redo")]
      [("stamp", stamp), ("undo", undo), ("redo", redo)]
  -- What a step of a loop over `switching` is handed: beside the keys that
  -- begin and end a session, a key that stamps, one whose command edits and
  -- is refused, one that edits the second buffer, and one that focuses the
  -- second window.
  let sessions : Loop.Keys switching :=
    switchingKeys
      [("C-c s", invoke "stamp"), ("C-c f", invoke "fail"), ("C-c o", invoke "elsewhere"),
        ("C-c w", invoke "window")]
      [("stamp", stamp), ("fail", boom),
        ("elsewhere", fun _ => do
          discard <| (⟨1⟩ : BufferId).insertAt 0 "x"
          return none),
        ("window", fun _ => do
          discard <| (⟨1⟩ : ViewId).focus
          return none)]
  [{  name :=
        "a key's command that undoes keeps the move after the step: the text is the one before the last key's edit, the buffer's tree has nothing pending and no node made for the move, and the next key's redo gives the edit back"
      run :=
        pure <|
          let program : EditorM (List String × List Nat × Bool) := do
            let loop : TestLoop := { state := ← holding "abcd" #[⟨1, 3⟩] }
            -- The first step records what the buffer was made holding as a
            -- step of the history, and the second the stamp.
            let (loop, _) ← stepsWith keys loop ([pressF5] ++ presses "C-c s")
            let stamped ← focusedOf loop
            let (loop, _) ← stepsWith keys loop (presses "C-c u")
            let undone ← focusedOf loop
            let afterUndo ← undone.buffer.text.read
            let (again, _) ← stepsWith keys loop (presses "C-c r")
            let redone ← focusedOf again
            return ([afterUndo, ← redone.buffer.text.read],
                [stamped.buffer.history.nodes.size, undone.buffer.history.nodes.size,
                  redone.buffer.history.nodes.size],
                !undone.buffer.history.pending && loop.state.echo == "" &&
                  undone.buffer.history.current != stamped.buffer.history.current &&
                  redone.buffer.history.current == stamped.buffer.history.current)
          (program.runModel editorModel).1.toOption ==
            some (["abcd", "aC-c sd"], [3, 3, 3], true) },
    { name :=
        "a command that edits, sets a boundary in the history, edits again and then does not run to its end, refused or interrupted, is rolled back whole: the text and the window's selection are those before it, the echo area says how it ended and nothing of a move, the history has no step for it and nothing to redo, and the next key's edit is undone as one step"
      run :=
        pure <|
          -- An edit that moves the selection, the boundary, and an edit in
          -- the group the boundary opened.
          let bounded (call : Call) : EditorM Unit := do
            Loop.insert call.target "boom"
            discard <| call.target.window.buffer.closeGroup
            call.target.buffer.text.insert 0 "x"
          let spun : Dispatched := fun call => do
            bounded call
            for _ in [0:1000] do
              discard <| call.target.buffer.text.revision
            return none
          let keys :=
            dispatchKeys
              [("C-c b", invoke "bounded"), ("C-c l", invoke "spun"), ("C-c s", invoke "stamp")]
              [("bounded", failingAfter bounded), ("spun", spun), ("stamp", stamp)]
          -- `lowering` is what arrives after the command: the interrupt key
          -- that stopped it, taken off the queue, which lowers the flag.
          let program (failing : String) (lowering : List Received) :
            EditorM ((String × Array SelectionRange × String) × Bool × Bool × String × String) := do
            let loop : TestLoop := { state := ← holding "abcd" #[⟨1, 3⟩] }
            -- The first step records what the buffer was made holding as a
            -- step of the history.
            let (loop, _) ← stepsWith keys loop [pressF5]
            let nodes := (← focusedOf loop).buffer.history.nodes.size
            let (loop, _) ← stepsWith keys loop (presses failing)
            let target ← focusedOf loop
            let failed := (← target.buffer.text.read, ← cursorsOf loop, loop.state.echo)
            let stepless :=
              target.buffer.history.nodes.size == nodes && !target.buffer.history.pending
            let redone ← target.buffer.history.redo Origin.user
            let loop ← takes keys loop lowering
            let (loop, _) ← stepsWith keys loop (presses "C-c s")
            let target ← focusedOf loop
            let after ← target.buffer.text.read
            let some _ ← target.buffer.history.undo | throw .noInverse
            return (failed, stepless, redone.isNone, after, ← target.buffer.text.read)
          let rolledBack (failing echo : String) (lowering : List Received) (watch : WatchModel) :
            Bool :=
            ((program failing lowering).runModel { editorModel with watch }).1.toOption ==
              some (("abcd", #[⟨1, 3⟩], echo), true, true, "aC-c sd", "abcd")
          rolledBack "C-c b" "bounded: refused: bad range" [] {} &&
            rolledBack "C-c l" "spun: interrupted" [interruptArrives] { arrivesAfter := some 20 } },
    { name :=
        "a command run while an edit is pending in the open group, which sets a boundary and is then refused, is rolled back to the point of the group it began at: the text is the one before it, no node was made, the edit from before it is still pending, and it is one step at the next boundary, which an undo takes back and a redo gives again"
      run :=
        pure <|
          let bounded : Dispatched :=
            failingAfter fun call => do
              Loop.insert call.target "boom"
              discard <| call.target.window.buffer.closeGroup
              call.target.buffer.text.insert 0 "x"
          let keys := dispatchKeys [] [("bounded", bounded)]
          let program : EditorM ((String × String × Nat × Bool) × Nat × String × String) := do
            -- No scene was published since the buffer was made holding
            -- `abcd`, so that edit is in the open group when the command
            -- starts.
            let ran ← Loop.run keys (← holding "abcd" #[⟨1, 3⟩]) (invoke "bounded") []
            let some left := ran.state.buffer? ⟨0⟩ | throw .noSuchText
            let failed :=
              (← left.text.read, ran.state.echo, left.history.nodes.size, left.history.pending)
            let (state, _) ← ran.state.recordHistories
            let some buffer := state.buffer? ⟨0⟩ | throw .noSuchText
            let some undone ← buffer.history.undo Origin.user | throw .noInverse
            let before ← buffer.text.read
            let some _ ← undone.tree.redo Origin.user | throw .noInverse
            return (failed, buffer.history.nodes.size, before, ← buffer.text.read)
          (program.runModel editorModel).1.toOption ==
            some (("abcd", "bounded: refused: bad range", 1, true), 2, "", "abcd") },
    { name :=
        "a command that sets a boundary, moves over the step it closed, there and back, and is then refused moved in the history: the move is not taken back, the echo area says so, and the tree the loop keeps is the one the command left, so the next key's undo takes the step back"
      run :=
        pure <|
          let crossing : Dispatched :=
            failingAfter fun call => do
              let buffer := call.target.window.buffer
              call.target.buffer.text.insert 0 "x"
              discard <| buffer.closeGroup
              discard <| buffer.undo
              discard <| buffer.redo
          let keys :=
            dispatchKeys [("C-c x", invoke "crossing"), ("C-c u", invoke "undo")]
              [("crossing", crossing), ("undo", undo)]
          let program : EditorM (String × String × String × String) := do
            let loop : TestLoop := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let (loop, _) ← stepsWith keys loop ([pressF5] ++ presses "C-c x")
            let failed ← (← focusedOf loop).buffer.text.read
            let echo := loop.state.echo
            let (loop, _) ← stepsWith keys loop (presses "C-c u")
            return (failed, echo, ← (← focusedOf loop).buffer.text.read, loop.state.echo)
          (program.runModel editorModel).1.toOption ==
            some
              ("xabcd", "crossing: refused: bad range; the command moved in the history", "abcd",
                "") },
    { name :=
        "two keys' edits made while the scheme reports the focused view as in an insert session, and then the key that ends the session, are one step of the history: no node is made inside the session, one is made when it ends, one undo gives the text from before the session and one redo the text after it"
      run :=
        pure <|
          let program : EditorM (List Nat × List Bool × List String) := do
            let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
            -- The first step records what the buffer was made holding as a
            -- step of the history.
            let (loop, _) ← stepsWith sessions loop [pressF5]
            let before ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-b C-c s C-c s")
            let inside ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-e")
            let ended ← treeOf loop
            let typed ← ended.text.read
            let some undone ← ended.undo Origin.user | throw .noInverse
            let back ← ended.text.read
            let some _ ← undone.tree.redo Origin.user | throw .noInverse
            return ([before.nodes.size, inside.nodes.size, ended.nodes.size],
                [before.pending, inside.pending, ended.pending], [typed, back, ← ended.text.read])
          (program.runModel editorModel).1.toOption ==
            some ([2, 2, 3], [false, true, false], ["aC-c sC-c sd", "abcd", "aC-c sC-c sd"]) },
    { name :=
        "the same two keys' edits with no view in an insert session are two steps of the history, each closed after its event"
      run :=
        pure <|
          let program : EditorM (List Nat × Bool) := do
            let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let (loop, _) ← stepsWith sessions loop [pressF5]
            let before ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-c s")
            let between ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-c s")
            let after ← treeOf loop
            return ([before.nodes.size, between.nodes.size, after.nodes.size],
                between.pending || after.pending)
          (program.runModel editorModel).1.toOption == some ([2, 3, 4], false) },
    { name :=
        "a buffer is modified in the scene published after the first edit of an insert session, while its history has gained no node"
      run :=
        pure <|
          let program : EditorM (Nat × Nat) := do
            let loop : Loop switching := { state := ← EditorState.initial ⟨640, 480⟩ }
            let (loop, _) ← stepsWith sessions loop (presses "C-b")
            let before ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-c s")
            return (before.nodes.size, (← treeOf loop).nodes.size)
          match program.runModel editorModel with
          | (.ok (before, inside), model) =>
            before == inside &&
              -- One scene a key: the key that begins the session, the
              -- prefix of the stamping sequence, and the key that stamps.
              model.display.scenes.map (·.views.map (·.status.any (·.face == Loop.modifiedFace))) ==
                #[#[false], #[false], #[true]]
          | (.error _, _) => false },
    { name :=
        "a command that is refused inside an insert session is rolled back to the text from before it, with the session's earlier edit still pending and no node made; a later edit and the end of the session then make one step of both, which one undo takes back"
      run :=
        pure <|
          let program : EditorM ((String × String × Nat × Bool) × Nat × String × String) := do
            let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let (loop, _) ← stepsWith sessions loop ([pressF5] ++ presses "C-b C-c s C-c f")
            let failed ← treeOf loop
            let rolled := (← failed.text.read, loop.state.echo, failed.nodes.size, failed.pending)
            let (loop, _) ← stepsWith sessions loop (presses "C-c s C-e")
            let ended ← treeOf loop
            let typed ← ended.text.read
            let some _ ← ended.undo Origin.user | throw .noInverse
            return (rolled, ended.nodes.size, typed, ← ended.text.read)
          (program.runModel editorModel).1.toOption ==
            some (("aC-c sd", "fail: refused: bad range", 2, true), 3, "aC-c sC-c sd", "abcd") },
    { name :=
        "an insert session in which nothing was edited makes no step of the history: the tree has no node more and nothing pending"
      run :=
        pure <|
          let program : EditorM (List Nat × Bool) := do
            let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let (loop, _) ← stepsWith sessions loop [pressF5]
            let before ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-b")
            let inside ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-e")
            let ended ← treeOf loop
            return ([before.nodes.size, inside.nodes.size, ended.nodes.size],
                inside.pending || ended.pending)
          (program.runModel editorModel).1.toOption == some ([2, 2, 2], false) },
    { name :=
        "of two buffers, the one shown by a view in an insert session has its group left open, and the one no such view shows has its group closed after each event"
      run :=
        pure <|
          let program : EditorM (List Nat × List Bool) := do
            let loop : Loop switching := { state := ← twoBuffers }
            let (loop, _) ← stepsWith sessions loop [pressF5]
            let (held, other) := (← treeOf loop, ← treeOf loop 1)
            let (loop, _) ← stepsWith sessions loop (presses "C-b C-c s C-c o")
            let (heldAfter, otherAfter) := (← treeOf loop, ← treeOf loop 1)
            return ([held.nodes.size, other.nodes.size, heldAfter.nodes.size,
                  otherAfter.nodes.size],
                [heldAfter.pending, otherAfter.pending])
          (program.runModel editorModel).1.toOption == some ([1, 1, 1, 2], [true, false]) },
    { name :=
        "of two windows on one buffer, one in an insert session, the buffer's group is left open after an edit made through the other window"
      run :=
        pure <|
          let program : EditorM (List Nat × List Bool × Option ViewId) := do
            let loop : Loop switching := { state := ← threeWindows }
            let (loop, _) ← stepsWith sessions loop (presses "C-b C-c w")
            let before ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-c s")
            let after ← treeOf loop
            return ([before.nodes.size, after.nodes.size], [before.pending, after.pending],
                some loop.state.frame.focused)
          (program.runModel editorModel).1.toOption == some ([1, 1], [false, true], some ⟨1⟩) }]

/-- A report as a command of the checks says it in the echo area. -/
def reportText (report : InputScheme.Report) : String :=
  reprStr report

/-- The command `say` of the report checks: it says the report its call
carries in the echo area (`reportText`). -/
def say : Dispatched := fun call => do
  message (reportText call.report)
  return none

/-- The checks of what a command is told of its view
(`Editor/Command/Call.lean`, `Editor/Loop.lean`), on the editor's models,
with the scheme `switching`, whose report a key's invocation switches, and
a command that says the report it was called with. -/
def dispatchReportChecks : List Check :=
  let handed (commands : List (String × Dispatched) := []) : Loop.Keys switching :=
    switchingKeys [("C-s", invoke "say")] (("say", say) :: commands)
  let echoes (text : String) (commands : List (String × Dispatched) := []) :
    Option (Array String) :=
    (switched (EditorState.initial ⟨640, 480⟩) text (handed := handed commands)).map
      (·.2.1.map (·.echo))
  [{  name :=
        "a command is called with what the scheme reports of its view: the default before any key switched it, and, for the key whose invocation switches the report, the switched report, since the command sees the scheme's state after its key; the next key's command is called with it too"
      run :=
        pure
          (echoes "C-s C-m C-s" [("mark", say)] ==
              some #[reportText {}, reportText markedReport, reportText markedReport] &&
            reportText markedReport != reportText {}) },
    { name :=
        "a command that is refused leaves the scheme at rest: the next key's command is called with the report from before the failed key, and not with the one that key would have switched to"
      run :=
        pure <|
          let failing : Dispatched := fun _ => throw .badRange
          match echoes "C-m C-b C-s" [("begin", failing)], echoes "C-m C-b C-s" with
          | some #[_, failed, after], some #[_, _, begun] =>
            failed == "begin: refused: bad range" && after == reportText markedReport &&
              begun == reportText { session := true }
          | _, _ => false },
    { name :=
        "a command run by its name, which no key yielded, is called with what the scheme reports of the focused view in the state the scheme is in"
      run :=
        pure <|
          let program : EditorM (String × String) := do
            let loop : Loop switching := { state := ← EditorState.initial ⟨640, 480⟩ }
            let fresh := (← loop.runNamed (handed []) "say").loop.state.echo
            let (loop, _) ← stepsWith (handed []) loop (presses "C-m")
            return (fresh, (← loop.runNamed (handed []) "say").loop.state.echo)
          (program.runModel editorModel).1.toOption ==
            some (reportText {}, reportText markedReport) },
    { name :=
        "under a scheme that says nothing of a view a command is called with the default report, by a key and by its name"
      run :=
        pure <|
          let keys := dispatchKeys [("C-s", invoke "say")] [("say", say)]
          let program : EditorM (String × String) := do
            let loop : TestLoop := { state := ← EditorState.initial ⟨640, 480⟩ }
            let (loop, _) ← stepsWith keys loop (presses "C-s")
            return (loop.state.echo, (← loop.runNamed keys "say").loop.state.echo)
          (program.runModel editorModel).1.toOption == some (reportText {}, reportText {}) }]

/-- The checks of a command that gives up (`giveUp`, `Editor/Api.lean`;
`Editor/Loop.lean`, "Running an invocation"), on the editor's models, with
the scheme `switching`, whose report a key's invocation switches, and
commands written here: the loop rolls the command back, says its reason in
the echo area with no `refused:`, and puts the scheme back in its state at
rest. -/
def dispatchCommandGivesUpChecks : List Check :=
  let reason := "nothing to do here"
  -- Edits the text, moves the selection, and then gives up.
  let quitter : Dispatched := fun call => do
    Loop.insert call.target "typed"
    giveUp reason
  let handed (commands : List (String × Dispatched) := []) : Loop.Keys switching :=
    switchingKeys [("C-s", invoke "say"), ("C-g", invoke "quitter")]
      ([("say", say), ("quitter", quitter)] ++ commands)
  [{  name :=
        "a key whose command edits and then gives up: the text and the selection are those before the command, the history has no step for it, the echo area reads the command's name and its reason with no refused, and the step says the command gave up"
      run :=
        pure <|
          let program :
            EditorM (String × Array SelectionRange × String × Bool × Bool × Option Loop.Ending) :=
            do
            let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
            -- A key that runs nothing: its publish records the fixture's own
            -- insertion as a step, so the count read here is the one to keep.
            let (loop, _) ← stepsWith (handed []) loop [pressF5]
            let some before := loop.state.focusedTarget? | throw .noSuchText
            let (loop, steps) ← stepsWith (handed []) loop (presses "C-g")
            let some target := loop.state.focusedTarget? | throw .noSuchText
            return (← target.buffer.text.read, (← target.selection).ranges, loop.state.echo,
                target.buffer.history.nodes.size == before.buffer.history.nodes.size,
                target.buffer.history.pending, (steps.back?).bind (·.ended))
          (program.runModel editorModel).1.toOption ==
            some
              ("abcd", #[⟨1, 3⟩], s!"quitter: {reason}", true, false,
                some (Loop.Ending.gaveUp reason)) },
    { name :=
        "a command that gives up leaves the scheme at rest: the next key's command is told the report from before the key that gave up, and not the one that key would have switched to; the same key with a command that runs to its end switches it"
      run :=
        pure <|
          let giving : Dispatched := fun _ => giveUp reason
          let echoes (commands : List (String × Dispatched)) : Option (Array String) :=
            (switched (EditorState.initial ⟨640, 480⟩) "C-m C-b C-s" (handed :=
                  handed commands)).map
              (·.2.1.map (·.echo))
          match echoes [("begin", giving)], echoes [] with
          | some #[_, gave, after], some #[_, _, begun] =>
            gave == s!"begin: {reason}" && after == reportText markedReport &&
              begun == reportText { session := true }
          | _, _ => false },
    { name :=
        "a command that has its buffer keep a value and then gives up leaves the editor state as it was: the buffer keeps no value under the name"
      run :=
        pure <|
          let keeping : Dispatched := fun call => do
            discard <| call.target.window.buffer.setValue "count" (.nat 7)
            giveUp reason
          let kept : Dispatched := fun call => do
            discard <| call.target.window.buffer.setValue "count" (.nat 7)
            return none
          let bound (name : String) : Loop.Keys switching :=
            switchingKeys [("C-k", invoke name)] [("keeping", keeping), ("kept", kept)]
          let after (name : String) : Option (Option Value × String) :=
            (switched (EditorState.initial ⟨640, 480⟩) "C-k" (handed := bound name)).map
              fun (loop, _, _) => (loop.state.value? ⟨0⟩ "count", loop.state.echo)
          after "keeping" == some (none, s!"keeping: {reason}") &&
            after "kept" == some (some (.nat 7), "") },
    { name :=
        "a command that gives up inside an insert session leaves the session's earlier edit pending in the open group, with the text as the session left it: only what the command itself made is taken back"
      run :=
        pure <|
          let typing : Dispatched := fun call => do
            Loop.insert call.target "one"
            return none
          let program : EditorM (String × Bool × Nat × String) := do
            let loop : Loop switching := { state := ← EditorState.initial ⟨640, 480⟩ }
            let handed := handed [("begin", typing)]
            let (loop, _) ← stepsWith handed loop (presses "C-b C-g")
            let some target := loop.state.focusedTarget? | throw .noSuchText
            return (← target.buffer.text.read, target.buffer.history.pending,
                target.buffer.history.nodes.size, loop.state.echo)
          (program.runModel editorModel).1.toOption ==
            some ("one", true, 1, s!"quitter: {reason}") },
    { name :=
        "a command that gives up, run by its name, ends the same way: rolled back, with its name and its reason in the echo area, and the step says it gave up"
      run :=
        pure <|
          let program : EditorM (String × String × Option Loop.Ending) := do
            let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let stepped ← loop.runNamed (handed []) "quitter"
            let some target := stepped.loop.state.focusedTarget? | throw .noSuchText
            return (← target.buffer.text.read, stepped.loop.state.echo, stepped.ended)
          (program.runModel editorModel).1.toOption ==
            some ("abcd", s!"quitter: {reason}", some (Loop.Ending.gaveUp reason)) }]

/-- The checks of a command that breaks off (`breakOff`, `Editor/Api.lean`;
`Editor/Loop.lean`, "Running an invocation"), on the editor's models, with
the scheme `switching`, whose report a key's invocation switches, and
commands written here: the loop keeps what the command did, says its reason
in the echo area with no `refused:`, and puts the scheme back in its state
at rest. -/
def dispatchCommandBreaksOffChecks : List Check :=
  let reason := "far enough"
  -- Edits the text, which moves the selection, and then breaks off or, with
  -- no reason, runs to its end.
  let editing (reason : Option String) : Dispatched := fun call => do
    Loop.insert call.target "typed"
    match reason with
    | some reason =>
      breakOff reason
    | none =>
      return none
  let handed (commands : List (String × Dispatched) := []) : Loop.Keys switching :=
    switchingKeys [("C-s", invoke "say"), ("C-g", invoke "stopper"), ("C-f", invoke "finisher")]
      ([("say", say), ("stopper", editing (some reason)), ("finisher", editing none)] ++ commands)
  -- What the key `key` leaves from a text with a selection: the text, the
  -- selection, the echo area, the history's nodes and whether an edit is
  -- pending in it, and how the step says the command ended.
  let left (key : String) :
    Option (String × Array SelectionRange × String × Nat × Bool × Option Loop.Ending) :=
    let program :
      EditorM (String × Array SelectionRange × String × Nat × Bool × Option Loop.Ending) := do
      let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
      let (loop, steps) ← stepsWith (handed []) loop (presses key)
      let some target := loop.state.focusedTarget? | throw .noSuchText
      return (← target.buffer.text.read, (← target.selection).ranges, loop.state.echo,
          target.buffer.history.nodes.size, target.buffer.history.pending,
          (steps.back?).bind (·.ended))
    (program.runModel editorModel).1.toOption
  [{  name :=
        "a key whose command edits and then breaks off: the text, the selection and the history are those the same command leaves when it runs to its end, which are not those from before it; the echo area reads the command's name and its reason with no refused, and the step says the command broke off"
      run :=
        pure <|
          match left "C-g", left "C-f" with
          | some (text, ranges, echo, nodes, pending, ended),
            some (finished, placed, said, steps, unclosed, how) =>
            text == finished && text != "abcd" && ranges == placed && ranges != #[⟨1, 3⟩] &&
              nodes == steps &&
              pending == unclosed &&
              echo == s!"stopper: {reason}" &&
              said.isEmpty &&
              ended == some (Loop.Ending.brokeOff reason) &&
              how == some .finished
          | _, _ => false },
    { name :=
        "a command that breaks off leaves the scheme at rest: the next key's command is told the report from before the key that broke off, and not the one that key would have switched to; the same key with a command that runs to its end switches it"
      run :=
        pure <|
          let breaking : Dispatched := fun _ => breakOff reason
          let echoes (commands : List (String × Dispatched)) : Option (Array String) :=
            (switched (EditorState.initial ⟨640, 480⟩) "C-m C-b C-s" (handed :=
                  handed commands)).map
              (·.2.1.map (·.echo))
          match echoes [("begin", breaking)], echoes [] with
          | some #[_, broke, after], some #[_, _, begun] =>
            broke == s!"begin: {reason}" && after == reportText markedReport &&
              begun == reportText { session := true }
          | _, _ => false },
    { name :=
        "a command that has its buffer keep a value, asks for an invocation to be run after it and then breaks off leaves the editor state it reached: the buffer keeps the value, and the step hands the invocation back"
      run :=
        pure <|
          let keeping : Dispatched := fun call => do
            discard <| call.target.window.buffer.setValue "count" (.nat 7)
            Editor.invoke { command := "say" }
            breakOff reason
          let bound : Loop.Keys switching :=
            switchingKeys [("C-k", invoke "keeping")] [("keeping", keeping)]
          let program : EditorM (Option Value × String × Array (Array String)) := do
            let loop : Loop switching := { state := ← EditorState.initial ⟨640, 480⟩ }
            let (loop, steps) ← stepsWith bound loop (presses "C-k")
            return (loop.state.value? ⟨0⟩ "count", loop.state.echo,
                steps.map fun step => step.answered.map (·.command))
          (program.runModel editorModel).1.toOption ==
            some (some (.nat 7), s!"keeping: {reason}", #[#["say"]]) },
    { name :=
        "a command that breaks off, run by its name, ends the same way: what it did stays, its name and its reason are in the echo area, and the step says it broke off"
      run :=
        pure <|
          let program : EditorM (String × String × Option Loop.Ending) := do
            let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let stepped ← loop.runNamed (handed []) "stopper"
            let some target := stepped.loop.state.focusedTarget? | throw .noSuchText
            return (← target.buffer.text.read, stepped.loop.state.echo, stepped.ended)
          match (program.runModel editorModel).1.toOption, left "C-f" with
          | some (text, echo, ended), some (finished, _) =>
            text == finished && echo == s!"stopper: {reason}" &&
              ended == some (Loop.Ending.brokeOff reason)
          | _, _ => false }]

/-- The checks of a command that has another run inside it (`runCommand`,
`Editor/Api.lean`; `Editor/Loop.lean`, "A command run inside another"), on
the editor's models, with commands written here: the command it names is
the one a key's invocation of that name runs, looked up in what the step
was handed. -/
def dispatchRunCommandChecks : List Check :=
  -- Runs the command its first argument names inside itself, with its own
  -- call but for the arguments, and says whether there was one.
  let outer : Dispatched := fun call => do
    let .str name :: arguments := call.arguments | giveUp "no command named"
    let ran ← runCommand name { call with arguments }
    message s!"{name} ran: {ran}"
    return none
  let write : Config.Write := { owner := .config, store := "cell", value := .nat 1 }
  let commands : List (String × Dispatched) :=
    [("outer", outer), ("stamp", stamp), ("writer", fun _ => return some write),
      ("quitter", fun call => do
        Loop.insert call.target "typed"
        giveUp "nothing to do here")]
  let handed : Loop.Keys TestScheme.scheme :=
    dispatchKeys
      [("C-s", { command := "outer", arguments := [.str "stamp", .nat 7] }),
        ("C-m", { command := "outer", arguments := [.str "missing"] }),
        ("C-w", { command := "outer", arguments := [.str "writer"] }),
        ("C-q", { command := "outer", arguments := [.str "quitter"] }), ("C-t", invoke "stamp")]
      commands
  -- What the key `key` leaves from a text with a cursor: the text, the echo
  -- area, the history's nodes, and how the step says the command ended.
  let left (key : String) : Option (String × String × Nat × Option Loop.Ending) :=
    let program : EditorM (String × String × Nat × Option Loop.Ending) := do
      let loop : TestLoop := { state := ← holding "ab" #[⟨2, 2⟩] }
      let (loop, _) ← stepsWith handed loop [pressF5]
      let (loop, steps) ← stepsWith handed loop (presses key)
      let some target := loop.state.focusedTarget? | throw .noSuchText
      return (← target.buffer.text.read, loop.state.echo, target.buffer.history.nodes.size,
          (steps.back?).bind (·.ended))
    (program.runModel editorModel).1.toOption
  [{  name :=
        "a command that has the command of a name run inside it runs the one a key's invocation of that name runs, with the call it hands it, as part of itself: what the two did is one step of the history, and the asking command goes on after it"
      run :=
        pure <|
          match left "C-s", left "C-t" with
          | some (text, echo, nodes, ended), some (alone, _, steps, _) =>
            text == "ab7 C-s" && alone == "abC-t" && echo == "stamp ran: true" && nodes == steps &&
              ended == some .finished
          | _, _ => false },
    { name :=
        "a name no command is registered under is answered false, and nothing runs: the asking command goes on"
      run :=
        pure <|
          (left "C-m").map (fun (text, echo, _, ended) => (text, echo, ended)) ==
            some ("ab", "missing ran: false", some .finished) },
    { name :=
        "a command run inside another that gives up gives the asking command up: both are rolled back, and the reason is said under the asking command's name"
      run :=
        pure <|
          (left "C-q").map (fun (text, echo, _, ended) => (text, echo, ended)) ==
            some ("ab", "outer: nothing to do here", some (.gaveUp "nothing to do here")) },
    { name :=
        "a command run inside another that asks for a store to be written gives the asking command up, with the sentence the loop makes of its name: only a command the loop runs has its write written back"
      run :=
        pure <|
          !(Loop.writesInside "writer").isEmpty &&
            (left "C-w").map (fun (text, echo, _, ended) => (text, echo, ended)) ==
              some
                ("ab", s!"outer: {Loop.writesInside "writer"}",
                  some (.gaveUp (Loop.writesInside "writer"))) }]

/-- The checks of key dispatch in the loop (`Editor/Loop.lean`), on the
editor's models: keys through the scheme and the commands they run,
rollback, the interrupt, the slow-command log, a command's state requests,
what the loop gives up after a command, a command that gives up, a command
that breaks off, a command that has another run inside it, the scheme's
notice of a closed view, undo from a command, and what a command is told of
its view. -/
def dispatchChecks : List Check :=
  dispatchKeyChecks ++ dispatchRollbackChecks ++ dispatchInterruptChecks ++ dispatchSlowChecks ++
    dispatchStateChecks ++
    dispatchGiveUpChecks ++
    dispatchCloseViewChecks ++
    dispatchMinibufferNoticeChecks ++
    dispatchUndoChecks ++
    dispatchReportChecks ++
    dispatchCommandGivesUpChecks ++
    dispatchCommandBreaksOffChecks ++
    dispatchRunCommandChecks

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
    command := fun name => { command := name }
    roles := TestScheme.roles
    leader := TestScheme.leader }

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
    command := fun name => { command := name }
    roles := TestScheme.roles
    leader := TestScheme.leader }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that it reports no pending keys. -/
def silent : InputScheme :=
  { State := TestScheme.State
    Binding := Invocation
    init := {}
    step := TestScheme.step
    pending := fun _ => []
    command := fun name => { command := name }
    roles := TestScheme.roles
    leader := TestScheme.leader }

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
    command := fun name => { command := name }
    roles := TestScheme.roles
    leader := TestScheme.leader }

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
    command := fun name => { command := name }
    roles := TestScheme.roles
    leader := TestScheme.leader }

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
    command := fun name => { command := name }
    roles := TestScheme.roles
    leader := TestScheme.leader }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that what it says runs a named command runs a command of another
name. -/
def misnaming : InputScheme :=
  { TestScheme.scheme with command := fun name => { command := name ++ "-not" } }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that what it says a mode's key is bound to runs a command of another
name. -/
def modeMisnaming : InputScheme :=
  { TestScheme.scheme with modeCommand := fun name => { command := name ++ "-not" } }

/-- A scheme written for the test that breaks the contract: the test scheme,
with a role table that lacks the role `mark`. -/
def roleless : InputScheme :=
  { TestScheme.scheme with roles := TestScheme.roles.filter (·.1 != Role.mark) }

/-- A scheme written for the test that breaks the contract: the test scheme,
with the role `previous-item` put on the keys of `next-item` as well. -/
def crowded : InputScheme :=
  { TestScheme.scheme with
    roles :=
      TestScheme.roles.map fun (role, keys) =>
        if role == Role.previousItem then (role, (TestScheme.scheme.roleKey Role.nextItem).getD [])
        else (role, keys) }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that a key that prints and that nothing binds yields nothing, so no
view of it takes typed text, the minibuffer's included. -/
def mute : InputScheme :=
  { State := TestScheme.State
    Binding := Invocation
    init := {}
    step := fun maps view state key =>
      let (pending, yielded) := Keymap.walk (maps view) state.pending key
      ({ pending }, yielded)
    pending := (·.pending)
    command := fun name => { command := name }
    roles := TestScheme.roles
    leader := TestScheme.leader }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that it reports a view as in an insert session while keys are
pending, so a key that yields nothing changes its report. -/
def fidgeting : InputScheme :=
  { TestScheme.scheme with
    report := fun (state : TestScheme.State) _ => { session := !state.pending.isEmpty } }

/-- A scheme written for the test that breaks the contract: the test scheme,
except that once an unbound key has dropped a prefix it reports every view
as in an insert session. Its state is the test scheme's, and whether a
prefix was dropped. -/
def startled : InputScheme :=
  { State := TestScheme.State × Bool
    Binding := Invocation
    init := ({}, false)
    step := fun maps view state key =>
      let (next, yielded) := TestScheme.step maps view state.1 key
      ((next, state.2 || !state.1.pending.isEmpty && next.pending.isEmpty && yielded.isNone),
        yielded)
    pending := (·.1.pending)
    command := fun name => { command := name }
    roles := TestScheme.roles
    leader := TestScheme.leader
    report := fun state _ => { session := state.2 } }

/-- The subject the scheme contract is run on: `scheme` over the scheme
checks' keymaps for view 0, the sequences those bind, a key none of them
goes on with, and that same key as the one that prints and that nothing
binds. -/
def subjectOf (scheme : InputScheme) (maps : ViewId → List (Keymap scheme.Binding)) :
    SchemeContract.Subject :=
  { scheme
    maps
    view := ⟨0⟩
    sequences := [keys "C-x C-s", keys "C-x C-f", keys "C-x r t", keys "C-q"]
    unbound := charKey "z"
    printable := charKey "z" }

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
        "the scheme contract reports a scheme that still reports pending keys after the key that completes an input, for a bound sequence, for a key bound to a named command, for a mode's key and for a key typed in the minibuffer's view"
      run :=
        let subject := subjectOf lingering schemeMaps
        pure
          (failsOnly subject
              [SchemeContract.completeEmits, SchemeContract.namedCommandRuns,
                SchemeContract.modeCommandRuns, SchemeContract.minibufferTakesText] &&
            (subject.feed (keys "C-x C-s")).2.getLast? == some (some (invoke "save"))) },
    { name :=
        "the scheme contract reports a scheme whose binding for a command name runs a command of another name, for that property alone"
      run := pure (failsOnly (subjectOf misnaming schemeMaps) [SchemeContract.namedCommandRuns]) },
    { name :=
        "the scheme contract reports a scheme whose binding for a mode's key runs a command of another name, for that property alone"
      run :=
        pure (failsOnly (subjectOf modeMisnaming schemeMaps) [SchemeContract.modeCommandRuns]) },
    { name :=
        "the scheme contract reports a scheme that yields nothing for a key that prints in the minibuffer's view, for that property alone"
      run :=
        let subject := subjectOf mute schemeMaps
        pure
          (failsOnly subject [SchemeContract.minibufferTakesText] &&
            (subject.feed [charKey "z"]).2 == [none] &&
            ((subjectOf TestScheme.scheme schemeMaps).feed [charKey "z"]).2.all (·.isSome)) },
    { name :=
        "the scheme contract reports a scheme whose role table lacks a registered role, for that property alone"
      run := pure (failsOnly (subjectOf roleless schemeMaps) [SchemeContract.everyRoleHasKey]) },
    { name :=
        "the scheme contract reports a scheme that puts two roles on one key, for that property alone"
      run := pure (failsOnly (subjectOf crowded schemeMaps) [SchemeContract.leaderAndRolesApart]) },
    { name :=
        "the scheme contract reports a scheme with no leader, and one with a role on keys that begin with the leader or begin it, for that property alone"
      run :=
        let leader := TestScheme.leader
        let quit := (TestScheme.scheme.roleKey Role.quit).getD []
        let underLeader :=
          TestScheme.roles.map fun (role, keys) =>
            if role == Role.quit then (role, leader ++ keys) else (role, keys)
        let tables : List (List (Role × List Key) × List Key) :=
          [(TestScheme.roles, []), (underLeader, leader), (TestScheme.roles, quit ++ leader)]
        pure
          (tables.all fun (roles, leader) =>
            failsOnly
              (subjectOf
                { TestScheme.scheme with
                  roles, leader }
                schemeMaps)
              [SchemeContract.leaderAndRolesApart]) },
    { name :=
        "the scheme contract reports a scheme whose report of a view changes while keys are pending, for that property alone"
      run :=
        let subject := subjectOf fidgeting schemeMaps
        pure
          (failsOnly subject [SchemeContract.quietKeyKeepsReport] &&
            (subject.scheme.report (subject.feed (keys "C-x")).1 ⟨0⟩).session &&
            !(subject.scheme.report (subject.feed (keys "C-x z")).1 ⟨0⟩).session) },
    { name :=
        "the scheme contract reports a scheme whose report of a view changes at the unbound key that resets a prefix, for that property alone"
      run :=
        let subject := subjectOf startled schemeMaps
        pure
          (failsOnly subject [SchemeContract.quietKeyKeepsReport] &&
            !(subject.scheme.report (subject.feed (keys "C-x")).1 ⟨0⟩).session &&
            (subject.scheme.report (subject.feed (keys "C-x z")).1 ⟨0⟩).session) }]

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
state; `insert`, where typing is text and the selection is exclusive, which
is also the state the registry names for the minibuffer's view; and
`visual`, where an operator acts on the selection and normal's keys are
bound too. -/
def vimStates : Vim.States :=
  { initial := { name := "normal", keymaps := [vimKeymap vimNormalTable] }
    others :=
      [{  name := "insert"
          keymaps := [vimKeymap vimEscapeTable]
          cursor := .bar
          insertsText := true
          shape := .exclusive },
        { name := "visual"
          keymaps := [vimKeymap vimEscapeTable, vimKeymap vimNormalTable]
          operatesOnSelection := true }]
    minibuffer := some "insert" }

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
            replaced.others.map (·.name) == ["insert", "visual"]) },
    { name :=
        "a Vim state's record says the shape of its selection: inclusive unless it says otherwise, and the shape it was registered with"
      run :=
        let added := vimStates.register { name := "lines", shape := .line }
        pure
          (({ name := "bare" } : Vim.StateRecord).shape == .inclusive &&
            (vimStates.get "normal").shape == .inclusive &&
            (vimStates.get "visual").shape == .inclusive &&
            (vimStates.get "insert").shape == .exclusive &&
            (added.get "lines").shape == .line) }]

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

/-- The role table and leader the Vim checks give the scheme, written here
so that no check names a default: each registered role on a key of its own,
and the leader on `SPC`. -/
def vimModeKeys : Vim.ModeKeys :=
  { roles :=
      Role.registered.zip
        ([["n"], ["N"], ["RET"], ["Q"], ["z", "r"], ["TAB"], ["M"]].map fun strokes =>
          keys (" ".intercalate strokes))
    leader := keys "SPC" }

/-- The subject the scheme contract is run on for the Vim scheme over
`states`: the scheme with the checks' role table and leader and no active
keymaps, for view 0, and `z`, which no keymap of the checks' states binds,
as the key that prints. -/
def vimSubjectOver (states : Vim.States) : SchemeContract.Subject :=
  { scheme := Vim.scheme states vimModeKeys
    maps := vimNoMaps
    view := ⟨0⟩
    sequences := vimSequences.map keys
    unbound := vimUnbound
    printable := charKey "z" }

/-- The subject the scheme contract is run on for the Vim scheme: the
scheme over `vimStates`. -/
def vimSubject : SchemeContract.Subject :=
  vimSubjectOver vimStates

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
        "the Vim scheme reports a view with no entry by the initial record: its cursor shape in the face cursor. and its name, one status field with its name in the state's face, its shape, no selecting, no insert session, and a view that takes no text"
      run :=
        let scheme := Vim.scheme vimStates
        pure
          (scheme.report vimInit ⟨0⟩ ==
              { cursor := { shape := .block, face := ⟨"cursor.normal"⟩ }
                status := #[{ text := "normal", face := Vim.stateFace }], shape := .inclusive
                selecting := false, session := false, takesText := false } &&
            scheme.report vimInit ⟨5⟩ == scheme.report vimInit ⟨0⟩ &&
            Vim.stateFace == ⟨"status.state"⟩) },
    { name :=
        "after a key that enters a state where typing is text, the Vim scheme reports that record's cursor, name and shape, an insert session, and a view that takes text"
      run :=
        let scheme := Vim.scheme vimStates
        pure
          (scheme.report (vimFed "i").1 ⟨0⟩ ==
            { cursor := { shape := .bar, face := ⟨"cursor.insert"⟩ }
              status := #[{ text := "insert", face := Vim.stateFace }], shape := .exclusive
              selecting := false, session := true, takesText := true }) },
    { name :=
        "the Vim scheme reports selecting for a view in a state whose operators act on the selection, and the record a check registers by its own cursor, name and shape"
      run :=
        let states := vimWithTest.register { vimWithTest.get "test" with shape := .line }
        let visual := (Vim.scheme vimStates).report (vimFed "v").1 ⟨0⟩
        pure
          (visual.selecting && !visual.session && !visual.takesText && visual.shape == .inclusive &&
            visual.status == #[{ text := "visual", face := Vim.stateFace }] &&
            (Vim.scheme states).report (vimFed "q" (states := states)).1 ⟨0⟩ ==
              { cursor := { shape := .underline, face := ⟨"cursor.test"⟩ }
                status := #[{ text := "test", face := Vim.stateFace }], shape := .line
                selecting := false, session := false, takesText := false }) },
    { name :=
        "the Vim scheme's report is one view's: a key for one view leaves another view's report as it was, a view told closed is reported by the initial record again, and a view told to be the minibuffer's by the record the registry names for it"
      run :=
        let scheme := Vim.scheme vimStates
        let (entered, _) := vimFed "i"
        let closed : Vim.State := scheme.closeView ⟨0⟩ entered
        let told : Vim.State := scheme.openMinibuffer ⟨3⟩ vimInit
        pure
          (scheme.report entered ⟨1⟩ == scheme.report vimInit ⟨1⟩ &&
            scheme.report entered ⟨0⟩ != scheme.report vimInit ⟨0⟩ &&
            scheme.report closed ⟨0⟩ == scheme.report vimInit ⟨0⟩ &&
            scheme.report told ⟨3⟩ == scheme.report entered ⟨0⟩ &&
            scheme.report told ⟨0⟩ == scheme.report vimInit ⟨0⟩) },
    { name :=
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
    { name :=
        "a self-insert leaves the scheme's state as it was but for the text kept for the last change, with nothing pending; where no text is being kept it leaves the whole state as it was"
      run :=
        let (inserting, _) := vimFed "i"
        let (state, _) := vimFedFrom inserting "a b"
        let minibuffer := Vim.State.openMinibuffer vimStates ⟨1⟩ vimInit
        let (typed, yields) := vimFedFrom minibuffer "a b" (view := ⟨1⟩)
        pure
          (decide ({ state with inserted := inserting.inserted } = inserting) &&
            state.typed == [] &&
            yields.length == 2 &&
            decide (typed = minibuffer)) },
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
        pure ((vimParsedFrom inserting "a b").1.lastChange == inserting.lastChange) },
    { name :=
        "the text typed in the insert session the last change began is kept: a change that enters a state where typing is text keeps the empty text for its view, the keys typed there are added in order, and the last change is as it was"
      run :=
        let (changing, _) := vimParsed "c w"
        let (typed, _) := vimParsedFrom changing "a b 1"
        pure
          (vimInit.inserted == none && vimInit.recording == none && changing.inserted == some "" &&
            changing.recording == some ⟨0⟩ &&
            typed.inserted == some "ab1" &&
            typed.recording == some ⟨0⟩ &&
            typed.lastChange == changing.lastChange &&
            (vimParsed "i x y").1.inserted == some "xy") },
    { name :=
        "the key that leaves the state ends the keeping and keeps the text: text typed in a later session that no change began is not added, and a reset keeps what was kept"
      run :=
        let peeking (_ : ViewId) : List (Keymap Vim.Bound) :=
          [vimKeymap [("z", .command { name := "peek", enters := some "insert" })]]
        let (left, _) := vimParsed "c w a b <Escape>"
        pure
          (left.inserted == some "ab" && left.recording == none &&
            (vimParsedFrom left "z q" peeking).1.inserted == some "ab" &&
            (vimParsedFrom left "d z").1.inserted == some "ab" &&
            (vimParsedFrom left "u").1.inserted == some "ab" &&
            (vimParsedFrom left "v <Escape>").1.inserted == some "ab") },
    { name :=
        "a change that enters no state where typing is text keeps no typed text, and a second change that begins a session empties what the first kept"
      run :=
        let (left, _) := vimParsed "c w a b <Escape>"
        pure
          ((vimParsed "d w").1.inserted == none && (vimParsedFrom left "x").1.inserted == none &&
            (vimParsedFrom left "x").1.recording == none &&
            (vimParsedFrom left "v d").1.inserted == none &&
            (vimParsedFrom left "c w").1.inserted == some "" &&
            (vimParsedFrom left "c w q").1.inserted == some "q") },
    { name :=
        "text typed in another view is not added, the minibuffer's included, and the view being closed ends the keeping and keeps the text"
      run :=
        let (typed, _) := vimParsed "c w a"
        let other := Vim.State.openMinibuffer vimStates ⟨1⟩ typed
        let (elsewhere, parsed) := vimParsedFrom other "q" (view := ⟨1⟩)
        let closed := Vim.State.closeView ⟨0⟩ typed
        pure
          (parsed == [.text "q"] && elsewhere.inserted == some "a" &&
            elsewhere.recording == some ⟨0⟩ &&
            (vimParsedFrom elsewhere "b").1.inserted == some "ab" &&
            closed.inserted == some "a" &&
            closed.recording == none &&
            (Vim.State.closeView ⟨1⟩ elsewhere).recording == some ⟨0⟩) },
    { name :=
        "a committed text the scheme is told of is typed text: it is added to what is kept for the last change when it was committed in the view being kept for, and not when in another"
      run :=
        let scheme := Vim.scheme vimStates
        let (typed, _) := vimParsed "c w a"
        let here : Vim.State := scheme.committed ⟨0⟩ "かな" typed
        let there : Vim.State := scheme.committed ⟨1⟩ "かな" typed
        let idle : Vim.State := scheme.committed ⟨0⟩ "かな" vimInit
        pure
          (here.inserted == some "aかな" &&
            decide ({ here with inserted := typed.inserted } = typed) &&
            decide (there = typed) &&
            decide (idle = vimInit)) },
    { name :=
        "a replay compiles to the repeat command, with whether the change began an insert session, the text typed in it, the command the change compiles to and then the change's own arguments; it changes no text and enters no state"
      run :=
        let change : Vim.Edit := .operate vimChange (.motion "word") (some 2) (some "a")
        pure
          ((Vim.Edit.replay change (some "xy")).compile ==
              { command := Vim.repeatCommand
                arguments :=
                  [.bool true, .str "xy", .str Vim.operateCommand, .str "change", .str "motion",
                    .str "word", .nat 2, .str "a"] } &&
            (Vim.Edit.replay (.run vimInsert none none) none).compile ==
              { command := Vim.repeatCommand
                arguments := [.bool false, .str "", .str "insert", .nat 0, .str ""] } &&
            !(Vim.Edit.replay change (some "xy")).changes &&
            (Vim.Edit.replay change (some "xy")).enters == none &&
            !Vim.repeatCommand.isEmpty) },
    { name :=
        "the repeat key yields the last change to replay, with the text typed in its session: nothing when there is no last change, and after a change the repeat command with the change's invocation; the replay is not the last change, and the view stays in the state it is in"
      run :=
        let dot (_ : ViewId) : List (Keymap Vim.Bound) := [vimKeymap [(".", .repeat)]]
        let (deleted, _) := vimFed "d 2 w"
        let (changed, _) := vimFed "c w a b <Escape>"
        let replayed (arguments : List Argument) : List (Option Invocation) :=
          [some { command := Vim.repeatCommand, arguments }]
        let (idle, nothing) := vimFed "." dot
        let (again, yielded) := vimFedFrom changed "." dot
        pure
          (nothing == [none] && decide (idle = vimInit) &&
            (vimFedFrom deleted "." dot).2 ==
              replayed
                [.bool false, .str "", .str Vim.operateCommand, .str "delete", .str "motion",
                  .str "word", .nat 2, .str ""] &&
            decide ((vimFedFrom deleted "." dot).1 = deleted) &&
            yielded ==
              replayed
                [.bool true, .str "ab", .str Vim.operateCommand, .str "change", .str "motion",
                  .str "word", .nat 0, .str ""] &&
            decide (again = changed)) },
    { name :=
        "a count typed before the repeat key replaces the last change's count, in what is yielded and in the last change, so a later bare repeat carries it; and while an operator waits the repeat key resets and yields nothing"
      run :=
        let dot (_ : ViewId) : List (Keymap Vim.Bound) := [vimKeymap [(".", .repeat)]]
        let (deleted, _) := vimFed "d 2 w"
        let thrice : Option Invocation :=
          some
            { command := Vim.repeatCommand
              arguments :=
                [.bool false, .str "", .str Vim.operateCommand, .str "delete", .str "motion",
                  .str "word", .nat 3, .str ""] }
        let (counted, yielded) := vimFedFrom deleted "3 ." dot
        let (waiting, reset) := vimFedFrom deleted "d ." dot
        pure
          (yielded == [none, thrice] &&
            counted.lastChange == some (.operate vimDelete (.motion "word") (some 3) none) &&
            counted.typed == [] &&
            (vimFedFrom counted "." dot).2 == [thrice] &&
            reset == [none, none] &&
            decide (waiting = deleted)) },
    { name :=
        "a key a mode binds runs its command in normal state, and in insert state it is typed text, while a key an active keymap binds for no mode still runs there"
      run :=
        let scheme := Vim.scheme vimStates
        let maps (_ : ViewId) : List (Keymap Vim.Bound) :=
          [Keymap.ofList
              [(keys "z", scheme.modeCommand "mode-thing"),
                (keys "Z", scheme.command "global-thing")]]
        let (inserting, _) := vimFed "i"
        pure
          ((vimFed "z" maps).2 == [some (vimRun "mode-thing")] &&
            (vimFedFrom inserting "z Z" maps).2 ==
              [some (Vim.selfInsert "z"), some (vimRun "global-thing")]) },
    { name := "a mode's binding that wraps a motion moves, and is an operator's target"
      run :=
        let maps (_ : ViewId) : List (Keymap Vim.Bound) :=
          [vimKeymap [("z", .mode (.motion "zed"))]]
        pure
          ((vimFed "z" maps).2 == [some (vimMove "zed")] &&
            (vimFed "d z" maps).2 == [none, some (vimOperate "delete" "motion" "zed")]) },
    { name :=
        "a hand-tuned key the Vim scheme has for a mode runs its command in normal state, and in insert state it is typed text"
      run :=
        let scheme :=
          Vim.scheme vimStates
            { vimModeKeys with tuned := [("tuning", keys "z", .command { name := "tuned-z" })] }
        let tuning : Mode := { name := "tuning" }
        let maps (_ : ViewId) : List (Keymap Vim.Bound) := tuning.keymaps scheme
        let (inserting, _) := vimFed "i"
        pure
          ((vimFed "z" maps).2 == [some (vimRun "tuned-z")] &&
            (vimFedFrom inserting "z" maps).2 == [some (Vim.selfInsert "z")]) },
    { name :=
        "Mode.check under the Vim scheme reports a hand-tuned key a state other than the initial one binds, and not one no state binds"
      run :=
        let scheme :=
          Vim.scheme vimStates
            { vimModeKeys with
              tuned :=
                [("tuning", keys "<Escape>", .command { name := "tuned-escape" }),
                  ("tuning", keys "z", .command { name := "tuned-z" })] }
        let tuning : Mode := { name := "tuning" }
        pure (tuning.check scheme == [.shadowsScheme (keys "<Escape>")]) },
    { name :=
        "told that a view is closed, the Vim scheme drops the Vim state it kept for it and keeps everything else: the other views' states, the edit begun and the last change; a view it kept nothing for changes nothing"
      run :=
        let scheme := Vim.scheme vimWithTest
        let (one, _) := vimFed "d w q" (states := vimWithTest)
        let (both, _) := vimFedFrom one "q 2" (view := ⟨1⟩) (states := vimWithTest)
        let closed : Vim.State := scheme.closeView ⟨0⟩ both
        let other : Vim.State := scheme.closeView ⟨7⟩ both
        pure
          (both.current == [(⟨0⟩, "test"), (⟨1⟩, "test")] && both.lastChange.isSome &&
            !both.typed.isEmpty &&
            closed == { both with current := [(⟨1⟩, "test")] } &&
            closed.stateOf vimWithTest ⟨0⟩ == "normal" &&
            closed.stateOf vimWithTest ⟨1⟩ == "test" &&
            other == both) },
    { name :=
        "told that a view is the minibuffer's, the Vim scheme puts it in the state its registry names and leaves the other views in theirs: a key that prints and a digit typed for it are text, and the same keys for another view are not; told that the view is closed, its state is the scheme's initial state again"
      run :=
        let states := vimStates
        let scheme := Vim.scheme states
        let told : Vim.State := scheme.openMinibuffer ⟨5⟩ vimInit
        let closed : Vim.State := scheme.closeView ⟨5⟩ told
        let typed (view : ViewId) (text : String) : List (Option Invocation) :=
          (vimFedFrom told text (view := view) (states := states)).2
        pure
          (told.current == [(⟨5⟩, "insert")] && told.stateOf states ⟨5⟩ == "insert" &&
            told.stateOf states ⟨0⟩ == "normal" &&
            typed ⟨5⟩ "w 2" == [some (Vim.selfInsert "w"), some (Vim.selfInsert "2")] &&
            (typed ⟨0⟩ "w").all
              (fun yielded => yielded.isSome && yielded != some (Vim.selfInsert "w")) &&
            typed ⟨0⟩ "2" == [none] &&
            closed == vimInit) },
    { name :=
        "with no state named for the minibuffer, and with a name the registry does not have, a view the Vim scheme is told is the minibuffer's is in the initial state, and the scheme's state is as it was"
      run :=
        let nowhere : Vim.States := { vimStates with minibuffer := some "nowhere" }
        let nameless : Vim.States := { vimStates with minibuffer := none }
        let unnamed : Vim.State := (Vim.scheme nameless).openMinibuffer ⟨5⟩ vimInit
        let unknown : Vim.State := (Vim.scheme nowhere).openMinibuffer ⟨5⟩ vimInit
        pure
          (vimStates.minibuffer == some "insert" && unnamed == vimInit && unknown == vimInit &&
            unknown.stateOf nowhere ⟨5⟩ == "normal") },
    { name :=
        "the notice of the minibuffer's view keeps the edit begun and the last change, and the other views' states"
      run :=
        let states := vimStates
        let (begun, _) := vimFedFrom (vimFed "x i" (states := states)).1 "d" (view := ⟨1⟩)
        let told : Vim.State := (Vim.scheme states).openMinibuffer ⟨5⟩ begun
        pure
          (begun.current == [(⟨0⟩, "insert")] && begun.lastChange.isSome && !begun.typed.isEmpty &&
            told == { begun with current := [(⟨0⟩, "insert"), (⟨5⟩, "insert")] }) }]

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

/-- What the default Vim scheme reports of view 0 after the keys `text`
names. -/
def vimDefaultReport (text : String) : InputScheme.Report :=
  Vim.Default.scheme.report (vimDefault text).1 ⟨0⟩

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
    unbound := vimUnbound
    printable := charKey "z" }

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
                Vim.Default.visualLineCommands, Vim.Default.minibufferCommands].all
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
        "each of the default keys u C-r : runs a command of its own that changes no text and enters no state"
      run :=
        let plainKeys := ["u", "C-r", ":"]
        pure
          (vimDefaultCommands plainKeys &&
            plainKeys.all fun text =>
              (vimDefault text).1.current == [] && (vimDefault text).1.lastChange == none) },
    { name :=
        "the default key . is the repeat key, and no command's: with no last change it yields nothing, and after x it yields the replay of that change and leaves it the last change"
      run :=
        let deleteChar : Vim.Edit := .run { name := "delete-char", changes := true } none none
        pure
          ((vimDefault ".").2 == [.nothing] && (vimDefault ".").1.lastChange == none &&
            (vimDefault "x .").2.getLast? == some (.edit (.replay deleteChar none)) &&
            (vimDefault "x .").1.lastChange == some deleteChar &&
            (vimDefault "x .").1.current == []) },
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
            (vimDefaultRecord "i").name != (vimDefaultRecord "").name) },
    { name :=
        "under the default Vim scheme a view opened as the minibuffer's is in a state of its own, where typing is text and the cursor is a bar: a letter, a digit and a key the initial state binds to a motion are text there; RET and <Escape> each run a command, of two different names, that enters no state and leaves nothing pending; a view that was not opened as the minibuffer's is in the initial state"
      run :=
        let states := Vim.Default.states
        let told : Vim.State := Vim.Default.scheme.openMinibuffer ⟨5⟩ (Vim.scheme states).init
        let record := told.record states ⟨5⟩
        let parsed (text : String) : Vim.State × List Vim.Parsed :=
          vimParsedFrom told text (view := ⟨5⟩) (states := states)
        let command (text : String) : Option String :=
          match (parsed text).2 with
          | [.edit (.run command none none)] => some command.name
          | _ => none
        pure
          (record.insertsText && record.cursor == .bar && record.name != states.initial.name &&
            record.name != (vimDefaultRecord "i").name &&
            (parsed "a 7 w").2 == [.text "a", .text "7", .text "w"] &&
            (vimDefaultEdit "w").isSome &&
            (command "RET").isSome &&
            (command "<Escape>").isSome &&
            command "RET" != command "<Escape>" &&
            (["RET", "<Escape>"].all fun text => (parsed text).1 == told) &&
            told.stateOf states ⟨0⟩ == states.initial.name) },
    { name :=
        "the default Vim scheme reports a fresh view as a block with an inclusive selection, no selecting and no insert session; after i a bar, an exclusive selection, an insert session and a view that takes text; and after i and <Escape> what it reported first"
      run :=
        let fresh := vimDefaultReport ""
        let inserting := vimDefaultReport "i"
        pure
          (fresh.cursor.shape == .block && fresh.shape == .inclusive && !fresh.selecting &&
            !fresh.session &&
            !fresh.takesText &&
            inserting.cursor.shape == .bar &&
            inserting.shape == .exclusive &&
            !inserting.selecting &&
            inserting.session &&
            inserting.takesText &&
            inserting.cursor.face != fresh.cursor.face &&
            vimDefaultReport "i <Escape>" == fresh) },
    { name :=
        "the default Vim scheme reports selecting in the states v and V enter, with an inclusive selection after v and a line-shaped one after V, neither an insert session; v then V is reported as V is, and V then v as v is"
      run :=
        let visual := vimDefaultReport "v"
        let line := vimDefaultReport "V"
        pure
          (visual.selecting && visual.shape == .inclusive && !visual.session && !visual.takesText &&
            line.selecting &&
            line.shape == .line &&
            !line.session &&
            !line.takesText &&
            vimDefaultReport "v V" == line &&
            vimDefaultReport "V v" == visual &&
            vimDefaultReport "v v" == vimDefaultReport "" &&
            vimDefaultReport "V V" == vimDefaultReport "") },
    { name :=
        "the default Vim scheme reports the minibuffer's view as a bar with an exclusive selection, in an insert session, taking text; and the status fields and the cursor faces of its five states all differ"
      run :=
        let told : Vim.State := Vim.Default.scheme.openMinibuffer ⟨5⟩ Vim.Default.scheme.init
        let minibuffer := Vim.Default.scheme.report told ⟨5⟩
        let reports := minibuffer :: ["", "i", "v", "V"].map vimDefaultReport
        pure
          (minibuffer.cursor.shape == .bar && minibuffer.shape == .exclusive &&
            !minibuffer.selecting &&
            minibuffer.session &&
            minibuffer.takesText &&
            Vim.Default.scheme.report told ⟨0⟩ == vimDefaultReport "" &&
            reports.all (·.status.size == 1) &&
            (reports.map (·.status)).eraseDups.length == 5 &&
            (reports.map (·.cursor.face)).eraseDups.length == 5) }]

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
          (failsOnly { vimSubject with unbound := charKey "z" } [SchemeContract.unboundResets]) },
    { name :=
        "the Vim scheme over a registry that names no state for the minibuffer leaves the minibuffer's view where a key that prints is no text: the scheme contract reports it, for that property alone"
      run :=
        pure
          (failsOnly (vimSubjectOver { vimStates with minibuffer := none })
            [SchemeContract.minibufferTakesText]) }]

/-- A mode the mode checks run on: `listing`, which fills two roles and has
one suffix, each with a command of its own. -/
def listing : Mode :=
  { name := "listing"
    roles := [(Role.nextItem, "listing-next"), (Role.previousItem, "listing-previous")]
    locals := [("x", "listing-execute")] }

/-- The test scheme with keymaps of its own, which bind `C-x C-s` and
`C-x C-f`, and a hand-tuned key for `listing` that they do not bind: what
`Mode.check` is run against. -/
def checkedScheme : InputScheme :=
  { TestScheme.scheme with
    defaults :=
      [Keymap.ofList [(keys "C-x C-s", invoke "save")],
        Keymap.ofList [(keys "C-x C-f", invoke "find")]]
    tuned := [("listing", keys "C-t", invoke "tuned-t")] }

/-- The keys `role` is on under the test scheme; none when it has no row. -/
def roleKeys (role : Role) : List Key :=
  (TestScheme.scheme.roleKey role).getD []

/-- What the keymaps `mode` makes for the test scheme `scheme` make of
`keys`. -/
def modeLookup (mode : Mode) (keys : List Key) (scheme : InputScheme := TestScheme.scheme)
    (same : scheme.Binding = Invocation := by rfl) : Lookup Invocation :=
  Keymap.resolve (same ▸ mode.keymaps scheme) keys

/-- The checks of roles and of the mode record (`Editor/Role.lean`,
`Editor/Mode.lean`): the roles the core registers, and the keymaps a mode
makes for a scheme, read through the test scheme's role table and leader. -/
def modeRecordChecks : List Check :=
  [{  name := "a mode's role is bound at the scheme's key for the role to the mode's command"
      run :=
        pure
          (modeLookup listing (roleKeys Role.nextItem) == .bound (invoke "listing-next") &&
            modeLookup listing (roleKeys Role.previousItem) == .bound (invoke "listing-previous") &&
            modeLookup listing (roleKeys Role.quit) == .unbound) },
    { name := "a mode's suffix is bound under the scheme's leader to the mode's command"
      run :=
        pure
          (modeLookup listing (TestScheme.scheme.leader ++ keys "x") ==
              .bound (invoke "listing-execute") &&
            modeLookup listing TestScheme.scheme.leader == .pending &&
            modeLookup listing (keys "x") == .unbound) },
    { name := "a role the scheme has no key for binds nothing"
      run :=
        let marking : Mode := { name := "marking", roles := [(Role.mark, "marking-mark")] }
        pure
          ((marking.keymaps roleless).all (·.bindings.isEmpty) &&
            modeLookup marking (roleKeys Role.mark) == .bound (invoke "marking-mark")) },
    { name :=
        "a scheme's hand-tuned key for the mode is in the keymap ahead of the roles and suffixes, and wins over a role on the same key; another mode's is not"
      run :=
        let tuned : InputScheme :=
          { TestScheme.scheme with
            tuned :=
              [("listing", roleKeys Role.nextItem, invoke "tuned-next"),
                ("listing", keys "C-t", invoke "tuned-t"),
                ("other", keys "C-o", invoke "other-o")] }
        pure
          (modeLookup listing (roleKeys Role.nextItem) tuned == .bound (invoke "tuned-next") &&
            modeLookup listing (keys "C-t") tuned == .bound (invoke "tuned-t") &&
            modeLookup listing (roleKeys Role.previousItem) tuned ==
              .bound (invoke "listing-previous") &&
            modeLookup listing (keys "C-o") tuned == .unbound &&
            ((listing.keymaps tuned).head?.map (·.bindings.length)) == some 2) },
    { name := "Mode.check reports nothing for a mode with no problem, under a scheme that tunes it"
      run := pure (listing.check TestScheme.scheme == [] && listing.check checkedScheme == []) },
    { name := "Mode.check reports a role that is not registered, by its name"
      run :=
        let mode := { listing with roles := listing.roles ++ [(Role.mk "frobnicate", "f")] }
        pure
          (mode.check checkedScheme == [.unregisteredRole { name := "frobnicate" }] &&
            mode.problems == [.unregisteredRole { name := "frobnicate" }]) },
    { name :=
        "Mode.check reports a suffix used twice once, comparing suffixes as keys, so that two spellings of one key are one suffix"
      run :=
        let twice := { listing with locals := [("x", "a"), ("x", "b"), ("x", "c"), ("y", "d")] }
        let spelled := { listing with locals := [("TAB", "a"), ("<Tab>", "b")] }
        pure
          (twice.check checkedScheme == [.duplicateSuffix (keys "x")] &&
            spelled.check checkedScheme == [.duplicateSuffix (keys "TAB")]) },
    { name := "Mode.check reports a suffix that is not keys, and one that names no keys"
      run :=
        let mode := { listing with locals := listing.locals ++ [("S-a", "a"), ("", "b")] }
        pure (mode.check checkedScheme == [.unreadableSuffix "S-a", .unreadableSuffix ""]) },
    { name :=
        "Mode.check reports a hand-tuned key of the mode that the scheme's own keymaps bind exactly, and not one they bind longer, nor another mode's"
      run :=
        let shadowing : InputScheme :=
          { checkedScheme with
            tuned :=
              [("listing", keys "C-t", invoke "tuned-t"),
                ("listing", keys "C-x C-s", invoke "tuned-save"),
                ("listing", keys "C-x", invoke "tuned-prefix"),
                ("other", keys "C-x C-f", invoke "other-find")] }
        pure
          (listing.check shadowing == [.shadowsScheme (keys "C-x C-s")] &&
            listing.problems == []) },
    { name := "each problem Mode.check reports is described by a sentence naming it"
      run :=
        let described :=
          [Mode.Problem.unregisteredRole { name := "frobnicate" }, .duplicateSuffix (keys "C-x"),
                .unreadableSuffix "S-a", .shadowsScheme (keys "C-x C-s")].map
            Mode.Problem.describe
        pure
          ([("frobnicate", 0), ("C-x", 1), ("S-a", 2), ("C-x C-s", 3)].all fun (name, index) =>
            ((described[index]?).getD "").contains name) },
    { name :=
        "the registered roles are next-item, previous-item, activate, quit, refresh, toggle and mark, each a name of its own"
      run :=
        pure
          (Role.registered.map (·.name) ==
              ["next-item", "previous-item", "activate", "quit", "refresh", "toggle", "mark"] &&
            [Role.nextItem, Role.previousItem, Role.activate, Role.quit, Role.refresh, Role.toggle,
                Role.mark] ==
              Role.registered) }]

/-- A mode called `name` that fills each of `roles` with a command named
after the mode and the role, and derives from `parent`, if given. -/
def filling (name : String) (roles : List Role) (parent : Option String := none) : Mode :=
  { name, parent, roles := roles.map fun role => (role, s!"{name}-{role.name}") }

/-- The invocation of the command `filling name` fills `role` with. -/
def filled (name : String) (role : Role) : Invocation :=
  invoke s!"{name}-{role.name}"

/-- What the active keymaps `registry` makes for the test scheme, in
`state`, for `view`, make of the keys `role` is on. -/
def activeLookup (registry : Config.Registry) (state : EditorState) (view : ViewId) (role : Role) :
    Lookup Invocation :=
  Keymap.resolve (registry.activeMaps TestScheme.scheme state view) (roleKeys role)

/-- `twoBuffers` with the major mode `major` set on buffer 0 and the minor
modes `minors` added to it, in order. -/
def withModes (major : String) (minors : List String) : TextM EditorState := do
  let state := (← twoBuffers).setMajorMode ⟨0⟩ major |>.2
  return minors.foldl (fun state minor => (state.addMinorMode ⟨0⟩ minor).2) state

/-- The registry of the mode registry checks: a global binding of the keys
of `quit` and of `next-item`, two minor modes and a major mode that fill
roles over one another, and a derived mode whose parent derives from a
root. -/
def modeRegistry : Config.Registry :=
  (({} : Config.Registry).replaceBindings .compiled
        #[{ keys := roleKeys Role.quit, command := "global-quit" },
          { keys := roleKeys Role.nextItem, command := "global-next" }]).replaceModes
    .compiled
    #[filling "m1" [Role.nextItem, Role.previousItem], filling "m2" [Role.nextItem],
      filling "major" [Role.nextItem, Role.previousItem, Role.activate],
      filling "root" [Role.toggle, Role.mark],
      filling "base" [Role.refresh, Role.mark] (some "root"),
      filling "child" [Role.mark] (some "base")]

/-- The checks of modes in the registry (`Editor/Config/Registry.lean`): a
mode's lineage, and the active keymaps of a view. -/
def modeRegistryChecks : List Check :=
  [{  name :=
        "a lineage is the mode then its parents, and ends at a name with no mode and at a cycle"
      run :=
        let looped :=
          modeRegistry.replaceModes .config
            #[filling "a" [] (some "b"), filling "b" [] (some "a"),
              filling "orphan" [] (some "missing")]
        pure
          ((modeRegistry.lineage "child").map (·.name) == ["child", "base", "root"] &&
            (modeRegistry.lineage "root").map (·.name) == ["root"] &&
            (looped.lineage "a").map (·.name) == ["a", "b"] &&
            (looped.lineage "orphan").map (·.name) == ["orphan"] &&
            (looped.lineage "missing").isEmpty) },
    { name :=
        "the active keymaps of a view are its buffer's minor modes', the last added first, then its major mode's lineage's, then the global keymap"
      run :=
        pure <|
          match onTextModel (withModes "major" ["m1", "m2"]) with
          | none => false
          | some state =>
            let lookup := activeLookup modeRegistry state ⟨0⟩
            (modeRegistry.activeMaps TestScheme.scheme state ⟨0⟩).length == 7 &&
              lookup Role.nextItem == .bound (filled "m2" Role.nextItem) &&
              lookup Role.previousItem == .bound (filled "m1" Role.previousItem) &&
              lookup Role.activate == .bound (filled "major" Role.activate) &&
              lookup Role.quit == .bound (invoke "global-quit") &&
              lookup Role.mark == .unbound &&
              activeLookup modeRegistry state ⟨1⟩ Role.nextItem == .bound (invoke "global-next") },
    { name :=
        "a derived mode's own role wins over its parents', and a role it does not fill falls to the nearest that fills it"
      run :=
        pure <|
          match onTextModel (withModes "child" []) with
          | none => false
          | some state =>
            let lookup := activeLookup modeRegistry state ⟨0⟩
            lookup Role.mark == .bound (filled "child" Role.mark) &&
              lookup Role.refresh == .bound (filled "base" Role.refresh) &&
              lookup Role.toggle == .bound (filled "root" Role.toggle) &&
              lookup Role.quit == .bound (invoke "global-quit") },
    { name := "a mode name no mode is registered under contributes nothing"
      run :=
        pure <|
          match onTextModel (withModes "ghost" ["phantom"]) with
          | none => false
          | some state =>
            (modeRegistry.activeMaps TestScheme.scheme state ⟨0⟩).length == 1 &&
              activeLookup modeRegistry state ⟨0⟩ Role.nextItem == .bound (invoke "global-next") },
    { name := "a view with no window has the global keymap alone"
      run :=
        pure <|
          match onTextModel (withModes "major" ["m1"]) with
          | none => false
          | some state =>
            (modeRegistry.activeMaps TestScheme.scheme state ⟨9⟩).length == 1 &&
              activeLookup modeRegistry state ⟨9⟩ Role.nextItem == .bound (invoke "global-next") }]

/-- What a step of the mode dispatch checks is handed: the active keymaps
`registry` makes for the test scheme from the loop's state, and, for every
name, a command that inserts its name at the cursors of the window it acts
on. -/
def modeKeys (registry : Config.Registry) : Loop.Keys TestScheme.scheme :=
  { maps := registry.activeMaps TestScheme.scheme
    command? := fun name =>
      some fun call => do
        Loop.insert call.target name
        return none }

/-- The text each view shows after the keys `role` is on are pressed in a
loop over `registry`'s active keymaps, from the state `start` makes with
the focus on `view`; none when the run was refused. -/
def roleTyped (registry : Config.Registry) (start : TextM EditorState) (keys : List Key)
    (view : ViewId := ⟨0⟩) : Option (Array (Option String)) :=
  let focused : TextM EditorState := do
    return ((← start).focusWindow view).2
  (lastScene (modeKeys registry) (keys.map press) focused).map (·.2.2)

/-- The checks of modes in the loop (`Editor/Loop.lean`), on the editor's
models and the test scheme: a key a mode binds runs its command in a view
of a buffer that has the mode, and the global binding elsewhere. Each key
is the test scheme's for a role, or its leader, so no check names a key of
a scheme. -/
def modeDispatchChecks : List Check :=
  [{  name :=
        "a key of a role the buffer's major mode fills runs the mode's command in a view of that buffer, and the global binding of the key in a view of a buffer without the mode"
      run :=
        let start := withModes "major" []
        pure
          (roleTyped modeRegistry start (roleKeys Role.nextItem) ==
              some #[some "major-next-item", some "other"] &&
            roleTyped modeRegistry start (roleKeys Role.nextItem) ⟨1⟩ ==
              some #[some "", some "global-nextother"]) },
    { name :=
        "when a minor mode and the major mode fill the same role, the minor mode's command runs"
      run :=
        pure
          (roleTyped modeRegistry (withModes "major" ["m2"]) (roleKeys Role.nextItem) ==
            some #[some "m2-next-item", some "other"]) },
    { name :=
        "a derived mode runs its parent's command for a role it does not fill, and its own for one it does"
      run :=
        let start := withModes "child" []
        pure
          (roleTyped modeRegistry start (roleKeys Role.refresh) ==
              some #[some "base-refresh", some "other"] &&
            roleTyped modeRegistry start (roleKeys Role.mark) ==
              some #[some "child-mark", some "other"]) },
    { name := "the scheme's leader followed by a mode's suffix runs that mode's local command"
      run :=
        let registry :=
          modeRegistry.replaceModes .config
            #[{ filling "major" [Role.nextItem] with locals := [("C-x", "major-local")] }]
        let typed := TestScheme.scheme.leader ++ keys "C-x"
        pure
          (roleTyped registry (withModes "major" []) typed ==
              some #[some "major-local", some "other"] &&
            roleTyped registry (withModes "major" []) typed ⟨1⟩ == some #[some "", some "other"]) }]

/-- A mode called `name` whose on-enter action makes a text naming the mode
and the view it was given, and which derives from `parent`, if given. -/
def entering (name : String) (parent : Option String := none) : Mode :=
  { name, parent, onEnter := fun view => makes s!"{name} in {view.index}" }

/-- The registry of the on-enter checks: `listing` and `other`, and `child`,
which derives from `base`, which derives from `root`. -/
def enterRegistry : Config.Registry :=
  ({} : Config.Registry).replaceModes .compiled
    #[entering "listing", entering "other", entering "root", entering "base" (some "root"),
      entering "child" (some "base")]

/-- What the command `enter` of the on-enter checks says of a refusal, in the
echo area. -/
def modeRefusalText : ModeRefusal → String
  | .noSuchWindow id => s!"no window {id.index}"
  | .noSuchMode name => s!"no mode {name}"

/-- The command `enter` of the on-enter checks: it asks for the mode named
by its second argument to be the major mode of the buffer the view of its
first argument shows, by the request (`ViewId.setMajorMode`), and says a
refusal in the echo area. With `fail` it is then refused with
`badRange`. -/
def enter (fail : Bool := false) : Dispatched := fun call => do
  let [.nat view, .str name] := call.arguments | throw .badPosition
  if let .error refusal← (⟨view⟩ : ViewId).setMajorMode name then
    EditorState.ask (.message (modeRefusalText refusal))
  if fail then
    call.target.buffer.text.delete 9 99
  return none

/-- What a step of the on-enter checks is handed: the commands `enter` and
`enter-fail`, and what `registry` says of its modes. -/
def enterKeys (registry : Config.Registry) : Loop.Keys TestScheme.scheme :=
  { command? := fun name =>
      ([("enter", enter), ("enter-fail", enter true)].find? (·.1 == name)).map (·.2)
    registered := registry.registered }

/-- The invocation of `command` that sets the mode `name` through `view`. -/
def entersMode (view : ViewId) (name : String) (command : String := "enter") : Invocation :=
  { command, arguments := [.nat view.index, .str name] }

/-- Sets the major mode of the buffer of each view in `steps` in turn, each
by an invocation of `enter` the loop runs (`Loop.run`) over `registry`,
from `twoBuffers`, on the editor's models with the watch model `watch`: the
texts made, in order, after the two the state was made with, what each
invocation left in the echo area, and each buffer's major mode at the end.
`none` when the run was refused. -/
def entered (steps : List (ViewId × String)) (registry : Config.Registry := enterRegistry)
    (watch : WatchModel := {}) : Option (Array String × List String × Array (Option String)) :=
  let program : EditorM (List String × EditorState) := do
    let mut state ← twoBuffers
    let mut echoes := []
    for (view, name) in steps do
      state := (← Loop.run (enterKeys registry) state (entersMode view name) []).state
      echoes := echoes ++ [state.echo]
    return (echoes, state)
  match program.runModel { editorModel with watch } with
  | (.ok (echoes, state), model) =>
    let texts := model.texts.contents
    some (texts.extract 2 texts.size, echoes, state.buffers.map (·.bind (·.major)))
  | (.error _, _) => none

/-- The checks of a mode's on-enter action, on the editor's models: a
command asks for a major mode by the request, and the loop that runs the
command runs the mode's on-enter actions inside it
(`Editor/Command/Dispatch.lean`). -/
def modeEnterChecks : List Check :=
  [{  name :=
        "the on-enter action runs once, with the view, when the mode becomes a buffer's major mode"
      run :=
        pure
          (entered [(⟨0⟩, "listing")] == some (#["listing in 0"], [""], #[some "listing", none]) &&
            entered [(⟨1⟩, "listing")] ==
              some (#["listing in 1"], [""], #[none, some "listing"])) },
    { name :=
        "setting the major mode a buffer already has runs nothing; setting another and then it again runs each"
      run :=
        pure
          (entered [(⟨0⟩, "listing"), (⟨0⟩, "listing")] ==
              some (#["listing in 0"], ["", ""], #[some "listing", none]) &&
            entered [(⟨0⟩, "listing"), (⟨0⟩, "other"), (⟨0⟩, "listing")] ==
              some
                (#["listing in 0", "other in 0", "listing in 0"], ["", "", ""],
                  #[some "listing", none])) },
    { name := "a derived mode's lineage runs its on-enter actions root first, each once"
      run :=
        pure
          (entered [(⟨1⟩, "child")] ==
            some (#["root in 1", "base in 1", "child in 1"], [""], #[none, some "child"])) },
    { name :=
        "setting a mode no mode is registered under is refused with noSuchMode, and one for a view with no window with noSuchWindow; each changes nothing and runs nothing"
      run :=
        pure
          (entered [(⟨0⟩, "ghost")] == some (#[], ["no mode ghost"], #[none, none]) &&
            entered [(⟨9⟩, "listing")] == some (#[], ["no window 9"], #[none, none]) &&
            entered [(⟨9⟩, "ghost")] == some (#[], ["no window 9"], #[none, none])) },
    { name :=
        "an on-enter action's own state requests are answered from the state the command had reached and kept with it: its message is in the echo area, and the minor mode it adds is the buffer's"
      run :=
        pure <|
          let loud : Mode :=
            { name := "loud"
              onEnter := fun view => do
                let state ← editorState
                let some target := state.target? view | throw .noSuchText
                -- The mode is the buffer's major mode by the time its
                -- action runs.
                EditorState.ask
                    (.message s!"{target.buffer.major.getD "none"} entered in {view.index}")
                discard <| EditorState.ask (.addMinorMode target.window.buffer "ringing") }
          let registry := enterRegistry.replaceModes .config #[loud]
          let program : EditorM EditorState := do
            return (← Loop.run (enterKeys registry) (← twoBuffers) (entersMode ⟨1⟩ "loud") []).state
          match (program.runModel editorModel).1 with
          | .ok state =>
            state.echo == "loud entered in 1" &&
              ((state.buffer? ⟨1⟩).map fun buffer => (buffer.major, buffer.minors)) ==
                some (some "loud", #["ringing"]) &&
              ((state.buffer? ⟨0⟩).map (·.minors)) == some #[]
          | .error _ => false },
    { name :=
        "a command that is refused after it set a major mode is rolled back, the mode and what its on-enter action did alike: the buffer has no major mode, the action's edit and its minor mode are gone, and the echo area says the refusal"
      run :=
        pure <|
          let stamping : Mode :=
            { name := "stamping"
              onEnter := fun view => do
                discard <| view.insertAtSelections "!"
                let some target := (← editorState).target? view | throw .noSuchText
                discard <| EditorState.ask (.addMinorMode target.window.buffer "stamped") }
          let keys := enterKeys (enterRegistry.replaceModes .config #[stamping])
          let program (command : String) : EditorM (EditorState × String) := do
            let ran ← Loop.run keys (← twoBuffers) (entersMode ⟨1⟩ "stamping" command) []
            return (ran.state, ← (⟨1⟩ : TextId).read)
          let modes (state : EditorState) :=
            (state.buffer? ⟨1⟩).map fun buffer => (buffer.major, buffer.minors)
          (match ((program "enter").runModel editorModel).1 with
            | .ok (state, text) =>
              text == "!other" && modes state == some (some "stamping", #["stamped"]) &&
                state.echo == ""
            | .error _ => false) &&
            match ((program "enter-fail").runModel editorModel).1 with
            | .ok (state, text) =>
              text == "other" && modes state == some (none, #[]) &&
                state.echo == "enter-fail: refused: bad range"
            | .error _ => false },
    { name :=
        "an on-enter action that is refused refuses the command at the request that set the mode, and the command cannot catch it: neither its handler nor what follows the request runs, the echo area says the refusal under the command's name, and the mode and the action's edit are rolled back"
      run :=
        pure <|
          let broken : Mode :=
            { name := "broken"
              onEnter := fun view => do
                discard <| view.insertAtSelections "!"
                let some target := (← editorState).target? view | throw .noSuchText
                target.buffer.text.delete 9 99 }
          -- What the command went on to do is seen in the texts it made,
          -- which no rollback takes back.
          let catching : Dispatched := fun call => do
            let [.nat view, .str name] := call.arguments | throw .badPosition
            try
              discard <| (⟨view⟩ : ViewId).setMajorMode name
            catch _ =>
              makes "caught"
            makes "went on"
            return none
          let keys : Loop.Keys TestScheme.scheme :=
            { command? := fun _ => some catching
              registered := (enterRegistry.replaceModes .config #[broken]).registered }
          let program : EditorM (EditorState × String) := do
            let ran ← Loop.run keys (← twoBuffers) (entersMode ⟨1⟩ "broken") []
            return (ran.state, ← (⟨1⟩ : TextId).read)
          match program.runModel editorModel with
          | (.ok (state, text), model) =>
            state.echo == "enter: refused: bad range" &&
              ((state.buffer? ⟨1⟩).map (·.major)) == some none &&
              text == "other" &&
              model.texts.contents == #["", "other"]
          | (.error _, _) => false },
    { name :=
        "an on-enter action is guarded with the command that set the mode: with the interrupt flag up its request of the store is not made, and the command is rolled back, so the mode is not the buffer's"
      run :=
        pure
          (entered [(⟨0⟩, "listing")] (watch := { arrived := 1 }) ==
            some (#[], ["enter: interrupted"], #[none, none])) }]

/-- What `command`, run dispatched from the state `start` makes with nothing
told of the registry, returned on the editor's models, and the state it
left; `none` unless it ran to its end. -/
def dispatchedFrom {α : Type} (command : EditorM α) (start : TextM EditorState := twoBuffers) :
    Option (α × EditorState) :=
  let program : EditorM (Guarded α × EditorState) := do
    command.dispatched {} (← start)
  match (program.runModel editorModel).1 with
  | .ok (.finished value, state) => some (value, state)
  | _ => none

/-- `twoBuffers` whose buffer `other` holds a file, for the checks of
`quit`. With `edited` its text was edited since, and its history told so:
the buffer is modified. -/
def quitStart (edited : Bool) : TextM EditorState := do
  let state ← twoBuffers
  let (_, state) :=
    state.attachFile ⟨1⟩ "/files/note.txt" { seconds := 3, nanoseconds := 0, size := 9 } .lf
  let some buffer := state.buffer? ⟨1⟩ | throw .noSuchText
  if edited then
    buffer.text.insert 0 "edited"
    return (state.setHistory ⟨1⟩ (← buffer.history.sync)).2
  else
    return state

/-- The checks of the operations of the editor API that are Lean state
alone (`Editor/Api.lean`): they make no request of the library, so they are
pinned here, once, on the editor's models; and of `quit`, on the same
models, whose one case on the real binding is in `Editor/Api/Cases.lean`. -/
def apiStateChecks : List Check :=
  let one : BufferId := ⟨1⟩
  let absent : BufferId := ⟨9⟩
  [{  name :=
        "a buffer-local value set from a command is read back by its name, a second value of the name replaces the first, another buffer has none, and setting one on a buffer there is none of is refused with noSuchBuffer"
      run :=
        pure <|
          match
            dispatchedFrom do
              let set ← one.setValue "count" (.nat 1)
              let first ← one.value? "count"
              discard <| one.setValue "count" (.nat 2)
              return (set, first, ← one.value? "count", ← (⟨0⟩ : BufferId).value? "count",
                  ← absent.setValue "count" .null, ← absent.value? "count") with
          | some ((set, first, second, other, refused, nothing), state) =>
            replied set == .inr () && first == some (.nat 1) && second == some (.nat 2) &&
              other == none &&
              replied refused == .inl (.noSuchBuffer absent) &&
              nothing == none &&
              state.value? one "count" == some (.nat 2)
          | none => false },
    { name :=
        "a minor mode added from a command is the buffer's, first, and one removed is gone; each is refused with noSuchBuffer for a buffer there is none of"
      run :=
        pure <|
          match
            dispatchedFrom do
              let added ← one.addMinorMode "first"
              discard <| one.addMinorMode "second"
              let both := ((← editorState).buffer? one).map (·.minors)
              let removed ← one.removeMinorMode "first"
              return (added, both, removed, ← absent.addMinorMode "first",
                  ← absent.removeMinorMode "first") with
          | some ((added, both, removed, unadded, unremoved), state) =>
            replied added == .inr () && both == some #["second", "first"] &&
              replied removed == .inr () &&
              replied unadded == .inl (.noSuchBuffer absent) &&
              replied unremoved == .inl (.noSuchBuffer absent) &&
              ((state.buffer? one).map (·.minors)) == some #["second"] &&
              ((state.buffer? ⟨0⟩).map (·.minors)) == some #[]
          | none => false },
    { name :=
        "a major mode asked for where nothing was told of the registry is refused with noSuchMode, and a view with no window with noSuchWindow first; the state is as it was"
      run :=
        pure <|
          match
            dispatchedFrom do
              return (← (⟨0⟩ : ViewId).setMajorMode "listing",
                  ← (⟨9⟩ : ViewId).setMajorMode "listing") with
          | some ((unknown, unseen), state) =>
            replied unknown == .inl (.noSuchMode "listing") &&
              replied unseen == .inl (.noSuchWindow ⟨9⟩) &&
              some state == onTextModel twoBuffers
          | none => false },
    { name :=
        "a wanted column set from a command is the window's, with its head, and setting none clears it; a view with no window is refused with noSuchWindow; none of it makes a request of the library"
      run :=
        pure <|
          let kept : Window.Wanted := { column := .cells 3, head := 7 }
          let view : ViewId := ⟨1⟩
          let program : EditorM _ := do
            let start ← twoBuffers
            let before ← Watch.now
            let ran ←
              EditorM.dispatched
                  (do
                    let set ← view.setWanted (some kept)
                    let held := ((← editorState).window? view).map (·.wanted)
                    let cleared ← (⟨0⟩ : ViewId).setWanted none
                    return (set, held, cleared, ← (⟨9⟩ : ViewId).setWanted (some kept)))
                  {} start
            return (ran, start, before, ← Watch.now)
          match (program.runModel countingModel).1 with
          | .ok ((.finished (set, held, cleared, refused), state), start, before, after) =>
            replied set == .inr () && held == some (some kept) && replied cleared == .inr () &&
              replied refused == .inl (.noSuchWindow ⟨9⟩) &&
              state == (start.setWanted view (some kept)).2 &&
              before > 0 &&
              after == before
          | _ => false },
    { name :=
        "a register set from a command is the editor state's, which the command then reads it from, and a second set under the name replaces it; none of it makes a request of the library"
      run :=
        pure <|
          let word : Register := { text := "word" }
          let line : Register := { text := "a line\n", linewise := true }
          let program : EditorM _ := do
            let start ← twoBuffers
            let before ← Watch.now
            let ran ←
              EditorM.dispatched
                  (do
                    setRegister "a" word
                    let first := (← editorState).register? "a"
                    setRegister "a" line
                    return (first, (← editorState).register? "a", (← editorState).register? "b"))
                  {} start
            return (ran, start, before, ← Watch.now)
          match (program.runModel countingModel).1 with
          | .ok ((.finished (first, second, other), state), start, before, after) =>
            first == some word && second == some line && other == none &&
              state == start.setRegister "a" line &&
              before > 0 &&
              after == before
          | _ => false },
    { name :=
        "quit from a command asks the editor to quit when no buffer has unsaved changes, and when the only modified buffer holds no file, though the command itself edited it"
      run :=
        pure <|
          let clean := dispatchedFrom quit
          let scratch :=
            dispatchedFrom do
              discard <| (⟨0⟩ : BufferId).insertAt 0 "typed"
              quit
          (clean.map fun (reply, state) => (replied reply, state.quitting)) ==
              some (.inr (), true) &&
            (scratch.map fun (reply, state) => (replied reply, state.quitting)) ==
              some (.inr (), true) },
    { name :=
        "quit from a command is refused with the name of a buffer that holds a file and has unsaved changes, with the state as it was and the editor not asked: for a buffer that was modified before the command, and for an edit the command itself made before it asked"
      run :=
        pure <|
          let before :=
            dispatchedFrom (start := quitStart true) do
              let state ← editorState
              return (← quit, (← editorState) == state)
          let during :=
            dispatchedFrom (start := quitStart false) do
              discard <| one.insertAt 0 "typed"
              let state ← editorState
              return (← quit, (← editorState) == state)
          let refused (ran : Option ((Except QuitRefusal Unit × Bool) × EditorState)) : Bool :=
            (ran.map fun ((reply, same), state) => (replied reply, same, state.quitting)) ==
              some (.inl (.unsaved "other"), true, false)
          refused before && refused during },
    { name :=
        "quit from a command asks when the modified buffer's save in flight is writing the state its text is in, and is refused once the command has edited the buffer since"
      run :=
        pure <|
          let saving : TextM EditorState := do
            let state ← quitStart true
            let some buffer := state.buffer? one | throw .noSuchText
            let snapshot ← buffer.text.snapshot
            return (state.beginSave one snapshot buffer.history.state).2
          let covered := dispatchedFrom quit saving
          let since :=
            dispatchedFrom (start := saving) do
              discard <| one.insertAt 0 "more"
              quit
          (covered.map fun (reply, state) => (replied reply, state.quitting)) ==
              some (.inr (), true) &&
            (since.map fun (reply, state) => (replied reply, state.quitting)) ==
              some (.inl (.unsaved "other"), false) }]

/-- The driver the job checks run: one over the test scheme. -/
abbrev TestDriver :=
  Loop.Driver TestScheme.scheme

/-- The jobs of the driver checks, by name. `double` doubles the number it
is started with, and its command inserts the result, in brackets, at the
cursor of view 0. `bad` finishes with a command that inserts and is then
refused. `chain` finishes with a command that starts `double` with 5.

Four reach files, in `fileRoot`. `load` loads the file it is named and
finishes with a command that makes a text of it. `adopt` loads nothing, and
finishes with a command that adopts the job snapshot of the number it is
started with. `save` saves the snapshot of the store whose index it is
started with as `out.txt`, which must not be there. `lose` loads `note.txt`
and then throws. -/
def driverJobs (name : String) : Option (List Argument → Work) :=
  let inserts (text : String) : EditorM Unit := discard <| (⟨0⟩ : ViewId).insertAtSelections text
  match name with
  | "double" =>
    some fun arguments =>
      Work.of
        (fun _ => do
          let [.nat n] := arguments | throw "double takes one number"
          sleep 10
          return 2 * n)
        fun n => inserts s!"[{n}]"
  | "bad" =>
    some fun _ =>
      Work.of (fun _ => pure ()) fun _ => do
        inserts "lost"
        (⟨0⟩ : TextId).delete 9 99
  | "chain" =>
    some fun _ => Work.of (fun _ => pure ()) fun _ => discard <| startJob "double" [.nat 5]
  | "load" =>
    some fun arguments =>
      Work.of
        (fun _ => do
          let [.str name] := arguments | throw "load takes one name"
          return (← JobContract.loaded (fileRoot / name)).snapshot)
        fun file => discard file.toText
  | "adopt" =>
    some fun arguments =>
      Work.of
        (fun _ => do
          let [.nat number] := arguments | throw "adopt takes one number"
          return number)
        fun number => discard (JobSnapshotId.mk number).adopt
  | "save" =>
    some fun arguments =>
      Work.of
        (fun _ => do
          let [.nat index] := arguments | throw "save takes one number"
          discard <| JobContract.saved (.snapshot ⟨index⟩) (fileRoot / "out.txt") .absent)
        fun _ => pure ()
  | "lose" =>
    some fun _ =>
      Work.of
        (fun _ => do
          discard <| JobContract.loaded (fileRoot / "note.txt")
          throw "lost")
        fun (_ : Unit) => pure ()
  | _ => none

/-- The commands of the driver checks, bound under `C-c`: `ask` (`a`)
messages `asked` and starts `double` with 21; `missing` (`m`) starts a job
no one registered and messages the refusal; `fail` (`f`) starts `double`
and is then refused; `none` (`n`) starts `double` with no argument; `bad`
(`b`) and `chain` (`c`) start the jobs of those names; `load` (`l`) starts
`load` with `note.txt`, `adopt` (`s`) starts `adopt` with 0, `save` (`w`)
takes a snapshot of its buffer's text and starts `save` with its index, and
`lose` (`t`) starts `lose`. -/
def driverKeys : Loop.Keys TestScheme.scheme :=
  let starts (name : String) (arguments : List Argument := []) : Dispatched := fun _ => do
    discard <| startJob name arguments
    return none
  dispatchKeys
    [("C-c a", invoke "ask"), ("C-c m", invoke "missing"), ("C-c f", invoke "fail"),
      ("C-c n", invoke "none"), ("C-c b", invoke "bad"), ("C-c c", invoke "chain"),
      ("C-c l", invoke "load"), ("C-c s", invoke "adopt"), ("C-c w", invoke "save"),
      ("C-c t", invoke "lose")]
    [("ask", fun _ => do
        message "asked"
        discard <| startJob "double" [.nat 21]
        return none),
      ("missing", fun _ => do
        if let .error (.noSuchJob name)← startJob "nope" [.nat 1] then
          message s!"no job {name}"
        return none),
      ("fail", failingAfter fun _ => discard <| startJob "double" [.nat 1]),
      ("none", starts "double"), ("bad", starts "bad"), ("chain", starts "chain"),
      ("load", starts "load" [.str "note.txt"]), ("adopt", starts "adopt" [.nat 0]),
      ("save", fun call => do
        let taken ← call.target.buffer.text.snapshot
        discard <| startJob "save" [.nat taken.index]
        return none),
      ("lose", starts "lose")]

/-- A driver over the initial state, with the commands and the jobs of the
driver checks; `none` if making the state was refused. -/
def newDriver : Option TestDriver :=
  (Loop.Driver.over driverKeys driverJobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption

/-- `newDriver` whose jobs reach the directory `fileRoot`, holding the file
`note.txt` with `FileCases.noteBytes`. -/
def fileDriver : Option TestDriver :=
  newDriver.map fun driver =>
    { driver with jobs := { files := fileModelOf #[("note.txt", FileCases.noteBytes)] } }

/-- Feeds `driver` the `events` in order: the driver after them, and what
each step handed back, `none` for a step that was refused. -/
def fedTo (driver : TestDriver) (events : List Event) :
    TestDriver × Array (Option (Loop.Stepped TestScheme.scheme)) :=
  events.foldl
    (fun (driver, steps) event =>
      let (driver, stepped) := driver.feed { event, stamp := 0 }
      (driver, steps.push stepped.toOption))
    (driver, #[])

/-- What the buffer of view 0 holds in `driver`'s text model. -/
def driverText (driver : TestDriver) : Option String :=
  driver.model.texts.contents[0]?

/-- The checks of jobs started from commands (`Editor/Loop.lean`,
`Editor/Loop/Driver.lean`), on the loop's driver over the editor's models
and the job model: a command starts a job by its name with arguments, and
the job's result comes back as a command the loop delivers. -/
def driverChecks : List Check :=
  let started (steps : Array (Option (Loop.Stepped TestScheme.scheme))) : Array JobStart :=
    steps.flatMap fun step => (step.map (·.starts)).getD #[]
  let echoOf (driver : TestDriver) : Option String := driver.model.display.scenes.back?.map (·.echo)
  [{  name :=
        "a command that starts a job with an argument: the step hands the start back, the job is run with that argument, and once it is finished a command has run that received the value the job computed from it; the delivery publishes a scene and leaves the echo the command left"
      run :=
        pure <|
          match newDriver with
          | none => false
          | some driver =>
            let (asked, steps) := fedTo driver (presses "C-c a")
            let (finished, delivered) := asked.finish 1
            started steps == #[{ name := "double", arguments := [.nat 21] }] &&
              asked.pending.map (fun job => (job.id, job.name)) == #[(1, "double")] &&
              asked.loop.state.starts.isEmpty &&
              driverText asked == some "" &&
              echoOf asked == some "asked" &&
              (delivered.map (·.ended)) == some (some .finished) &&
              finished.pending.isEmpty &&
              driverText finished == some "[42]" &&
              echoOf finished == some "asked" &&
              finished.model.display.scenes.size == asked.model.display.scenes.size + 1 &&
              finished.jobs.now == 10 },
    { name :=
        "events fed after a job started and before its result is delivered are each handled before the result's command: two commits are both in the text, in order, after their own steps, the result's command has run after neither, and it runs when the job is finished"
      run :=
        pure <|
          match newDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-c a")
            let (first, _) := fedTo asked [.commit "a"]
            let (second, _) := fedTo first [.commit "b"]
            let (finished, _) := second.finish 1
            driverText asked == some "" && driverText first == some "a" &&
              driverText second == some "ab" &&
              second.pending.size == 1 &&
              driverText finished == some "ab[42]" },
    { name :=
        "starting a job no one registered is refused with noSuchJob, a value the command sees, and starts nothing; a job started with arguments it does not take fails, and no command is delivered for it"
      run :=
        pure <|
          match newDriver with
          | none => false
          | some driver =>
            let (missing, steps) := fedTo driver (presses "C-c m")
            let (wrong, wrongSteps) := fedTo driver (presses "C-c n")
            let (failed, delivered) := wrong.finish 1
            started steps == #[] && missing.pending.isEmpty &&
              echoOf missing == some "no job nope" &&
              started wrongSteps == #[{ name := "double" }] &&
              (wrong.pending.map fun job =>
                  job.outcome matches .failed "double takes one number") ==
                #[true] &&
              delivered.isNone &&
              failed.pending.isEmpty &&
              driverText failed == some "" },
    { name :=
        "a command that asked for a job and was then refused starts nothing: the step hands back no start, the state keeps none, and the echo says the refusal"
      run :=
        pure <|
          match newDriver with
          | none => false
          | some driver =>
            let (failed, steps) := fedTo driver (presses "C-c f")
            started steps == #[] && failed.pending.isEmpty && failed.loop.state.starts.isEmpty &&
              (steps.back?.join.map (·.ended)) == some (some (.refused .badRange)) &&
              echoOf failed == some "fail: refused: bad range" },
    { name :=
        "a delivered command that is refused is rolled back: the text is as it was before the delivery, the echo names the job and the refusal, a scene is still published, and the loop goes on"
      run :=
        pure <|
          match newDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver ([.commit "ab"] ++ presses "C-c b")
            let (finished, delivered) := typed.finish 1
            let (after, _) := fedTo finished [.commit "c"]
            driverText typed == some "ab" && driverText finished == some "ab" &&
              (delivered.map (·.ended)) == some (some (.refused .badRange)) &&
              echoOf finished == some "job 1 bad: refused: bad range" &&
              finished.model.display.scenes.size == typed.model.display.scenes.size + 1 &&
              driverText after == some "abc" },
    { name :=
        "a delivered command may itself start a job: the delivery hands the start back, the job gets the next id, and its result is delivered in its turn; finishing an id that names no job started changes nothing"
      run :=
        pure <|
          match newDriver with
          | none => false
          | some driver =>
            let (chained, _) := fedTo driver (presses "C-c c")
            let (first, delivered) := chained.finish 1
            let (unknown, nothing) := first.finish 7
            let (second, _) := unknown.finish 2
            (delivered.map (·.starts)) == some #[{ name := "double", arguments := [.nat 5] }] &&
              first.pending.map (fun job => (job.id, job.name)) == #[(2, "double")] &&
              nothing.isNone &&
              unknown.pending.size == 1 &&
              driverText unknown == some "" &&
              driverText second == some "[10]" },
    { name :=
        "a command run by its name is run as a key's is, with the focused window, no keys and the echo cleared, and a scene is published after it; a name no command has is said in the echo, and the step says which it was"
      run :=
        pure <|
          let program : EditorM (Array (Option Loop.Ending) × Array String × String) := do
            let loop : TestLoop := { state := { (← holding "abcd" #[⟨1, 3⟩]) with echo := "old" } }
            let keys := dispatchKeys [] [("stamp", stamp), ("boom", boom)]
            let stamped ← loop.runNamed keys "stamp"
            let failed ← stamped.loop.runNamed keys "boom"
            let unknown ← failed.loop.runNamed keys "nope"
            return (#[stamped.ended, failed.ended, unknown.ended],
                #[stamped.loop.state.echo, failed.loop.state.echo, unknown.loop.state.echo],
                ← (← focusedOf unknown.loop).buffer.text.read)
          match program.runModel editorModel with
          | (.ok (endings, echoes, text), model) =>
            endings == #[some .finished, some (.refused .badRange), some .noSuchCommand] &&
              echoes == #["", "boom: refused: bad range", "nope: no such command"] &&
              text == "ad" &&
              model.display.scenes.map (·.echo) == echoes
          | (.error _, _) => false },
    { name :=
        "a finished job's command is handed what the job loaded: a job that loads a file finishes with a command that makes a text of it, and once the job is finished the store holds the file's text in a new text, no snapshot more than before, and nothing is left as handed or held"
      run :=
        pure <|
          match fileDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-c l")
            let (finished, delivered) := asked.finish 1
            asked.model.texts.contents == #[""] &&
              (delivered.map (·.ended)) == some (some .finished) &&
              finished.model.texts.contents == #["", FileCases.noteText] &&
              finished.model.texts.snapshots.filterMap id ==
                asked.model.texts.snapshots.filterMap id &&
              finished.model.texts.arrived.isEmpty &&
              finished.jobs.files.held == #[none] },
    { name :=
        "what a job loaded is handed to its own command and to no other: a second job's command that adopts the first job's snapshot is refused with noSuchSnapshot when it is delivered before the first job's command and when it is delivered after it, and the first job's command still makes its text"
      run :=
        pure <|
          match fileDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-c l C-c s")
            let (early, stolen) := asked.finish 2
            let (made, delivered) := early.finish 1
            let (again, _) := fedTo made (presses "C-c s")
            let (late, gone) := again.finish 3
            (stolen.map (·.ended)) == some (some (.refused .noSuchSnapshot)) &&
              (delivered.map (·.ended)) == some (some .finished) &&
              (gone.map (·.ended)) == some (some (.refused .noSuchSnapshot)) &&
              late.model.texts.contents == #["", FileCases.noteText] },
    { name :=
        "a job reads a snapshot its command took: a command takes a snapshot of its buffer's text and starts a job with its index, the job saves that snapshot, and the files then hold its bytes"
      run :=
        pure <|
          match fileDriver with
          | none => false
          | some driver =>
            let (saved, _) := fedTo driver ([.commit "héllo"] ++ presses "C-c w")
            (saved.pending.map fun job => job.outcome matches .finished _) == #[true] &&
              (saved.jobs.files.file? (fileRoot / "out.txt")).map (·.bytes) ==
                some "héllo".toUTF8 },
    { name :=
        "a job that loads and then throws holds nothing afterwards: its snapshot is released when it ends, and no command is delivered for it"
      run :=
        pure <|
          match fileDriver with
          | none => false
          | some driver =>
            let (lost, _) := fedTo driver (presses "C-c t")
            let (finished, delivered) := lost.finish 1
            (lost.pending.map fun job => job.outcome matches .failed "lost") == #[true] &&
              lost.jobs.files.held == #[none] &&
              delivered.isNone &&
              finished.model.texts.contents == #[""] }]

/-- What the command `greet` of the prompt checks says in the echo area: the
arguments it was called with, the view of its target, and how many keys it
was told of. -/
def greeted (arguments : List Argument) (view : Nat := 0) (keys : Nat := 0) : String :=
  s!"greet {arguments.map argumentText} in view {view} with {keys} keys"

/-- The invocation the command `hand` of the prompt checks asks to be run
after it: `greet`, with two arguments of its own. -/
def handed : Invocation :=
  { command := "greet", arguments := [.str "handed", .nat 3] }

/-- The commands of the prompt checks, by name.

- `ask` asks `Name: ` with the continuation `asked`, the command `greet`
  and the argument 7, and says the refusal when it is refused. `ask-missing`,
  `ask-boom`, `ask-again` and `ask-job` ask the same with the continuations
  `nobody`, which no command is registered under, `boom`, `ask` and `start`.
  `ask-then-fail` asks and is then refused.
- `accept` and `cancel` are the API's operations.
- `greet` says what it was called with (`greeted`).
- The test scheme's self-insert inserts its argument at its target's
  cursors.
- `boom` inserts and is then refused, `other` says `other`, and `start`
  starts the job `double`.
- `hand` says `handing` and asks for `handed` to be run after it
  (`invoke`, `Editor/Api.lean`), with no prompt; `hand-then-fail` asks the
  same and is then refused; `hand-missing` asks for a command nobody
  registered. -/
def promptCommands : List (String × Dispatched) :=
  let asks (continuation : Invocation) : Dispatched := fun _ => do
    if let .error refusal← prompt "Name: " continuation then
      message s!"not asked: {refusal.describe}"
    return none
  let says (text : String) : Dispatched := fun _ => do
    message text
    return none
  [("ask", asks asked), ("ask-missing", asks { command := "nobody" }),
    ("ask-boom", asks { command := "boom" }), ("ask-again", asks { command := "ask" }),
    ("ask-job", asks { command := "start" }),
    ("ask-then-fail", failingAfter fun _ => discard <| prompt "Name: " asked),
    ("accept", fun _ => do
      discard acceptPrompt
      return none),
    ("cancel", fun _ => do
      discard cancelPrompt
      return none),
    ("greet", fun call =>
      says (greeted call.arguments call.target.window.id.index call.keys.length) call),
    ((TestScheme.selfInsert "").command, fun call => do
      let [.str text] := call.arguments | throw .badRange
      call.target.insertAtSelections text
      return none),
    ("boom", boom), ("other", says "other"),
    ("start", fun _ => do
      discard <| startJob "double" [.nat 21]
      return none),
    ("hand", fun _ => do
      message "handing"
      Editor.invoke handed
      return none),
    ("hand-then-fail", failingAfter fun _ => Editor.invoke handed),
    ("hand-missing", fun _ => do
      Editor.invoke { command := "nobody" }
      return none)]

/-- What a step of the prompt checks is handed: one keymap, the same for
every view, the minibuffer's among them, that binds a key sequence under
`C-c` to each command of `promptCommands` but the self-insert, `greet` and
`start`, which no key runs. No key of it prints, so a key that prints is a
self-insert. -/
def promptKeys : Loop.Keys TestScheme.scheme :=
  dispatchKeys
    [("C-c a", invoke "ask"), ("C-c m", invoke "ask-missing"), ("C-c x", invoke "ask-boom"),
      ("C-c r", invoke "ask-again"), ("C-c j", invoke "ask-job"), ("C-c f", invoke "ask-then-fail"),
      ("C-c y", invoke "accept"), ("C-c n", invoke "cancel"), ("C-c b", invoke "boom"),
      ("C-c o", invoke "other"), ("C-c h", invoke "hand"), ("C-c g", invoke "hand-then-fail"),
      ("C-c k", invoke "hand-missing")]
    promptCommands

/-- A driver over the initial state, with the commands of the prompt checks
and the jobs of the driver checks; `none` if making the state was
refused. -/
def promptDriver : Option TestDriver :=
  (Loop.Driver.over promptKeys driverJobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption

/-- What the minibuffer holds in `driver`'s text model, while a prompt is
open. -/
def minibufferText (driver : TestDriver) : Option String := do
  let state := driver.loop.state
  let buffer ← state.buffer? (← state.minibufferBuffer?)
  (← driver.model.texts.texts[buffer.text.index]?).map (·.contents)

/-- The echo area of `driver`'s loop. -/
def promptEcho (driver : TestDriver) : String :=
  driver.loop.state.echo

/-- The checks of prompts through the loop and its host (`Editor/Loop.lean`,
`Editor/Loop/Driver.lean`), on the loop's driver over the editor's models
and the test scheme, with commands written here under keys of the global
keymap: the answer a step hands back, the answer's command run before the
next event, and rollback and the interrupt around an open prompt. -/
def promptLoopChecks : List Check :=
  let answer (text : String) : List Argument := [.str text, .nat 7]
  let closed (driver : TestDriver) : Bool :=
    let state := driver.loop.state
    state.prompt == none && state.windows.map (·.id) == #[⟨0⟩] && state.frame.focused == ⟨0⟩ &&
      state.answered.isEmpty &&
      state.wellFormed
  [{  name :=
        "ask, then accept: the accepting step hands back one answered invocation, the continuation with the answer first, and the answer's command has then run with those arguments, the asking view as its target and no keys; the loop's state keeps no answer, and the scene after it has one view"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-c a")
            let (accepted, steps) := fedTo asking (presses "C-c y")
            asking.loop.state.prompt.map (·.continuation) == some asked &&
              asking.loop.state.frame.focused == ⟨1⟩ &&
              steps.map (·.map (·.answered)) ==
                #[some #[], some #[{ command := "greet", arguments := answer "" }]] &&
              promptEcho accepted == greeted (answer "") &&
              closed accepted &&
              accepted.model.display.scenes.size == asking.model.display.scenes.size + 3 &&
              (accepted.model.display.scenes.back?.map fun scene =>
                  (scene.views.map (·.id), scene.echo)) ==
                some (#[⟨0⟩], greeted (answer "")) },
    { name :=
        "ask, two keys that print, then accept: the keys are typed into the minibuffer and not into the asking window, and the answer's command receives the two characters, in order"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a h i")
            let (accepted, _) := fedTo typed (presses "C-c y")
            minibufferText typed == some "hi" && driverText typed == some "" &&
              promptEcho accepted == greeted (answer "hi") &&
              closed accepted &&
              driverText accepted == some "" },
    { name :=
        "ask, accept, then a key bound to another command: the answer's command ran before that key was handled, and the echo area is then the other command's"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-c a")
            let (after, _) := fedTo asking (presses "C-c y C-c o")
            (after.model.display.scenes.map (·.echo)).extract asking.model.display.scenes.size ==
                #["", "", greeted (answer ""), greeted (answer ""), "other"] &&
              promptEcho after == "other" },
    { name :=
        "a continuation no command is registered under: the echo area says there is no such command, by the continuation's name, and the prompt is closed with the focus on the asking view"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (accepted, _) := fedTo driver (presses "C-c m C-c y")
            promptEcho accepted == "nobody: no such command" && closed accepted },
    { name :=
        "a continuation that is refused after an edit: the echo area says the refusal under the continuation's name, the edit is rolled back, the prompt stays closed, and nothing is answered again"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (accepted, steps) := fedTo driver (presses "C-c x C-c y")
            promptEcho accepted == "boom: refused: bad range" && driverText accepted == some "" &&
              closed accepted &&
              (steps.back?.join.map (·.answered.map (·.command))) == some #["boom"] },
    { name :=
        "a command that asks for an invocation to be run after it, with no prompt: its step hands the invocation back, the invocation's command then runs as a step of its own, with the invocation's arguments, the focused view as its target and no keys, before a key fed next is handled, and the loop's state keeps nothing to run"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (ran, steps) := fedTo driver (presses "C-c h")
            let (after, _) := fedTo ran (presses "C-c o")
            steps.map (·.map (·.answered)) == #[some #[], some #[handed]] &&
              promptEcho ran == greeted handed.arguments &&
              closed ran &&
              (after.model.display.scenes.map (·.echo)).extract driver.model.display.scenes.size ==
                #["", "handing", greeted handed.arguments, greeted handed.arguments, "other"] },
    { name :=
        "a command that asks for an invocation to be run after it and is then refused has nothing run: its step hands back no invocation, and the echo area says the refusal under the command's name"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (failed, steps) := fedTo driver (presses "C-c g")
            steps.map (·.map (·.answered)) == #[some #[], some #[]] &&
              promptEcho failed == "hand-then-fail: refused: bad range" &&
              closed failed },
    { name :=
        "a command that asks for a command nobody registered to be run after it: the echo area says there is no such command, by that name, and the next key's command runs"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (ran, _) := fedTo driver (presses "C-c k")
            let (after, _) := fedTo ran (presses "C-c o")
            promptEcho ran == "nobody: no such command" && closed ran &&
              promptEcho after == "other" },
    { name :=
        "a command that asks and is then refused opens no prompt: there is one window, with the focus, and the echo area says the refusal under the command's name"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (failed, _) := fedTo driver (presses "C-c f")
            promptEcho failed == "ask-then-fail: refused: bad range" && closed failed },
    { name :=
        "a command that fails in the minibuffer while a prompt is open is rolled back with the prompt open: its edit is taken back, and the minibuffer holds what was typed"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a h i")
            let (failed, _) := fedTo typed (presses "C-c b")
            promptEcho failed == "boom: refused: bad range" &&
              failed.loop.state.prompt == typed.loop.state.prompt &&
              failed.loop.state.prompt.isSome &&
              failed.loop.state.frame.focused == ⟨1⟩ &&
              minibufferText failed == some "hi" &&
              failed.loop.state.wellFormed },
    { name :=
        "the interrupt key arriving as the accept command reads the minibuffer: the echo area says the command was interrupted, the prompt is open with its text, and nothing was answered; once the key is taken off the queue a second accept answers"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a h i")
            -- The accept command's first request of the library is its read
            -- of the minibuffer's text: the key arrives as the flag is asked
            -- before it.
            let arriving : TestDriver :=
              { typed with model := { typed.model with watch := { arrivesAfter := some 0 } } }
            let (stopped, steps) := fedTo arriving (presses "C-c y")
            let (lowered, _) := stopped.feed interruptArrives
            let (accepted, _) := fedTo lowered (presses "C-c y")
            (steps.back?.join.map fun step => (step.ended, step.answered)) ==
                some (some .interrupted, #[]) &&
              promptEcho stopped == "accept: interrupted" &&
              stopped.loop.state.prompt == typed.loop.state.prompt &&
              stopped.loop.state.answered.isEmpty &&
              minibufferText stopped == some "hi" &&
              stopped.model.watch.arrived == 1 &&
              lowered.model.watch.arrived == 0 &&
              lowered.loop.state.prompt.isSome &&
              promptEcho accepted == greeted (answer "hi") &&
              closed accepted },
    { name :=
        "cancel makes no request of the library: with the interrupt flag up it still closes the prompt, and the continuation does not run"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-c a")
            let raised : TestDriver :=
              { asking with model := { asking.model with watch := { arrived := 1 } } }
            let (cancelled, steps) := fedTo raised (presses "C-c n")
            (steps.back?.join.map fun step => (step.ended, step.answered)) ==
                some (some .finished, #[]) &&
              promptEcho cancelled == "" &&
              closed cancelled },
    { name :=
        "a continuation that asks again leaves a second prompt open, in a view no view had, whose asker is the first asking view"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (again, _) := fedTo driver (presses "C-c r C-c y")
            again.loop.state.prompt ==
                some { label := "Name: ", view := ⟨2⟩, asker := ⟨0⟩, continuation := asked } &&
              again.loop.state.frame.focused == ⟨2⟩ &&
              again.loop.state.windows.map (·.id) == #[⟨0⟩, ⟨2⟩] &&
              promptEcho again == "" &&
              again.loop.state.wellFormed },
    { name :=
        "an answer's command that starts a job has the job started: the driver holds it as started and not delivered, and its result's command runs when it is finished"
      run :=
        pure <|
          match promptDriver with
          | none => false
          | some driver =>
            let (accepted, _) := fedTo driver (presses "C-c j C-c y")
            let (finished, _) := accepted.finish 1
            accepted.pending.map (fun job => (job.id, job.name)) == #[(1, "double")] &&
              closed accepted &&
              driverText finished == some "[42]" }]

/-- The commands of the minibuffer checks that `promptCommands` does not
have, by name: `ask-ada` asks as `ask` does, with the initial value `Ada`;
`to-window` focuses view 0, and `to-minibuffer` the minibuffer's view;
`close-asker` closes the view the open prompt was asked from. -/
def minibufferCommands : List (String × Dispatched) :=
  let ran (run : EditorM Unit) : Dispatched := fun _ => do
    run
    return none
  [("ask-ada", ran (discard <| prompt "Name: " asked "Ada")),
    ("to-window", ran (discard <| (⟨0⟩ : ViewId).focus)),
    ("to-minibuffer",
      ran do
        if let some view := (← editorState).minibufferView? then
          discard view.focus),
    ("close-asker",
      ran do
        if let some asking := (← editorState).prompt then
          discard asking.asker.close)]

/-- The global bindings of the minibuffer checks: a key sequence under `C-c`
and the name of the command it runs. The last two run the minibuffer's own
commands by their names, from any view. -/
def minibufferBindings : List (String × String) :=
  [("C-c a", "ask"), ("C-c i", "ask-ada"), ("C-c s", "start"), ("C-c w", "to-window"),
    ("C-c v", "to-minibuffer"), ("C-c k", "close-asker"), ("C-c 1", Minibuffer.acceptName),
    ("C-c 2", Minibuffer.cancelName)]

/-- The registry of the minibuffer checks: the minibuffer's commands and its
mode registered for the owner `compiled`, as a host registers them, and the
checks' bindings as config's. -/
def minibufferRegistry : Config.Registry :=
  ((({} : Config.Registry).replace .compiled Minibuffer.commands).replaceModes .compiled
        Minibuffer.modes).replaceBindings
    .config (minibufferBindings.toArray.map fun (text, command) => { keys := keys text, command })

/-- What a step of the minibuffer checks is handed: the active keymaps the
registry makes for the test scheme from the loop's state, so the
minibuffer's mode holds in the minibuffer's view and nowhere else; the
registry's commands, each given its call; and, for any other name, the
commands of the prompt checks and of these. -/
def minibufferKeys : Loop.Keys TestScheme.scheme :=
  { maps := minibufferRegistry.activeMaps TestScheme.scheme
    command? := fun name =>
      match minibufferRegistry.find? name with
      | some { registration := { action := .call run, .. }, .. } =>
        some fun call => do
          run call
          return none
      | _ => ((promptCommands ++ minibufferCommands).find? (·.1 == name)).map (·.2) }

/-- A driver of the minibuffer checks over the state `start` makes, with the
jobs of the driver checks; `none` if making the state was refused. -/
def minibufferDriver (start : TextM EditorState := EditorState.initial ⟨640, 480⟩) :
    Option TestDriver :=
  (Loop.Driver.over minibufferKeys driverJobs start editorModel).toOption

/-- A press of each key the test scheme has `role` on. -/
def rolePresses (role : Role) : List Event :=
  (roleKeys role).map press

/-- What reading the text `text` comes to on `driver`'s models. -/
def readOn (driver : TestDriver) (text : TextId) : TextError ⊕ String :=
  let read : EditorM String := text.read
  resulted (read.runModel driver.model).1

/-- The text of the minibuffer's buffer in `driver`'s state, while a prompt
is open. -/
def minibufferTextId (driver : TestDriver) : Option TextId := do
  let state := driver.loop.state
  return (← state.buffer? (← state.minibufferBuffer?)).text

/-- What the last scene `driver`'s display recorded shows of the open
prompt: the text and the status line of the minibuffer's view, whether it
is the focused view, and the status line of view 0. `none` when no prompt
is open or the scene lacks either view. -/
def promptScene (driver : TestDriver) :
    Option (Option String × Array StatusField × Bool × Array StatusField) := do
  let scene ← driver.model.display.scenes.back?
  let view ← driver.loop.state.minibufferView?
  let minibuffer ← scene.views.find? (·.id == view)
  let window ← scene.views.find? (·.id == ⟨0⟩)
  return (shownText driver.model minibuffer, minibuffer.status, scene.focused == some view,
      window.status)

/-- The checks of the minibuffer's commands and its mode
(`Editor/Minibuffer.lean`, `Editor/Minibuffer/Compiled.lean`), on the
loop's driver over the editor's models and the test scheme, with the
registry's active keymaps: the phase's acceptance criteria on the models.
The accept key and the cancel key are the test scheme's keys for the roles
the mode fills (`InputScheme.roleKey`), so no check names a key of
either. -/
def promptModeChecks : List Check :=
  let accept := rolePresses Role.activate
  let cancel := rolePresses Role.quit
  let answer (text : String) : List Argument := [.str text, .nat 7]
  let closed (driver : TestDriver) (view : ViewId := ⟨0⟩) : Bool :=
    let state := driver.loop.state
    state.prompt == none && state.frame.focused == view && state.answered.isEmpty &&
      state.wellFormed
  [{  name :=
        "criterion 1: a command prompts, keys are typed and the accept key is pressed: the continuation's command receives the typed string, with the asking view as its target, and the minibuffer's window is closed; the state has no prompt, one window, the tree it had and the focus on the asking view, the minibuffer's buffer slot is empty and its text refuses noSuchText, and the scene has one view"
      run :=
        pure <|
          match minibufferDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a h i")
            let (accepted, _) := fedTo typed accept
            !accept.isEmpty && minibufferText typed == some "hi" &&
              typed.loop.state.minibufferBuffer? == some ⟨1⟩ &&
              (minibufferTextId typed).map (readOn typed) == some (.inr "hi") &&
              promptEcho accepted == greeted (answer "hi") &&
              closed accepted &&
              accepted.loop.state.windows.map (·.id) == #[⟨0⟩] &&
              accepted.loop.state.frame.tree == driver.loop.state.frame.tree &&
              accepted.loop.state.buffers[1]? == some none &&
              (minibufferTextId typed).map (readOn accepted) == some (.inl .noSuchText) &&
              (accepted.model.display.scenes.back?.map (·.views.map (·.id))) == some #[⟨0⟩] },
    { name :=
        "criterion 2: a prompt given an initial value and accepted with no key typed: the continuation's command receives the initial value"
      run :=
        pure <|
          match minibufferDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-c i")
            let (accepted, _) := fedTo asking accept
            minibufferText asking == some "Ada" && promptEcho accepted == greeted (answer "Ada") &&
              closed accepted },
    { name :=
        "criterion 3: the prompt is cancelled: the continuation's command does not run, nothing is answered, the focus returns to the view that had it, and the minibuffer's text is released; the same keys with the accept key in place of the cancel key do run it"
      run :=
        pure <|
          match minibufferDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a h i")
            let (cancelled, steps) := fedTo typed cancel
            let (accepted, _) := fedTo typed accept
            !cancel.isEmpty && cancel != accept && typed.loop.state.frame.focused == ⟨1⟩ &&
              promptEcho cancelled == "" &&
              steps.all (·.all (·.answered.isEmpty)) &&
              closed cancelled &&
              cancelled.loop.state.windows.map (·.id) == #[⟨0⟩] &&
              (minibufferTextId typed).map (readOn cancelled) == some (.inl .noSuchText) &&
              cancelled.model.display.scenes.all (·.echo != greeted (answer "hi")) &&
              promptEcho accepted == greeted (answer "hi") },
    { name :=
        "criterion 4: a job completes while a prompt is open: its result's command runs, to its end, before the prompt is answered, and inserts in the window's buffer; the prompt is still open, with its text and the focus, and the keys typed afterwards and the accept key answer it with everything typed"
      run :=
        pure <|
          match minibufferDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c s C-c a h")
            let (delivered, step) := typed.finish 1
            let (accepted, _) := fedTo delivered (presses "i" ++ accept)
            typed.pending.map (·.id) == #[1] && driverText typed == some "" &&
              (step.map (·.ended)) == some (some .finished) &&
              driverText delivered == some "[42]" &&
              delivered.loop.state.prompt == typed.loop.state.prompt &&
              delivered.loop.state.prompt.isSome &&
              delivered.loop.state.frame.focused == ⟨1⟩ &&
              minibufferText delivered == some "h" &&
              promptEcho accepted == greeted (answer "hi") &&
              closed accepted &&
              driverText accepted == some "[42]" },
    { name :=
        "criterion 5: while a prompt is open the scene shows the prompt text and the input typed so far in the minibuffer's view: after the prompt is asked for and after each key that prints, the last scene has that view with the text so far, the label alone as its status line, in the prompt's face, and the focus, and view 0 with its own status line"
      run :=
        pure <|
          match minibufferDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-c a")
            let (one, _) := fedTo asking (presses "h")
            let (two, _) := fedTo one (presses "i")
            let showing (text : String) :=
              some
                (some text, #[({ text := "Name: ", face := Loop.promptFace } : StatusField)], true,
                  #[({ text := "scratch", face := Loop.nameFace } : StatusField)])
            promptScene driver == none && promptScene asking == showing "" &&
              promptScene one == showing "h" &&
              promptScene two == showing "hi" },
    { name :=
        "with no prompt open the minibuffer's accept command and its cancel command, each run by a key of the global keymap, say that no prompt is open and change nothing else; and the keys of the two roles, typed in a view whose buffer does not have the minibuffer's mode, run no command"
      run :=
        pure <|
          match minibufferDriver with
          | none => false
          | some driver =>
            let said (typed : String) : Bool :=
              let (after, _) := fedTo driver (presses typed)
              after.loop.state == { driver.loop.state with echo := Minibuffer.notOpen }
            let (unbound, steps) := fedTo driver (accept ++ cancel)
            !Minibuffer.notOpen.isEmpty && said "C-c 1" && said "C-c 2" &&
              steps.all (·.all (·.ended.isNone)) &&
              unbound.loop.state == driver.loop.state },
    { name :=
        "a second prompt asked for while one is open, by a key of the global keymap typed in the minibuffer: the command says the refusal, the first prompt is still open with its text, and no text was made"
      run :=
        pure <|
          match minibufferDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a h")
            let (again, _) := fedTo typed (presses "C-c a")
            promptEcho again == s!"not asked: {(PromptRefusal.alreadyOpen ⟨1⟩).describe}" &&
              again.loop.state.prompt == typed.loop.state.prompt &&
              again.loop.state.prompt.isSome &&
              minibufferText again == some "h" &&
              again.model.texts.texts.size == typed.model.texts.texts.size },
    { name :=
        "a prompt does not capture the keyboard: with the focus moved to the window while the prompt is open, a key that prints goes to the window's buffer and the prompt waits; with the focus moved back, the accept key answers with what the minibuffer held"
      run :=
        pure <|
          match minibufferDriver with
          | none => false
          | some driver =>
            let (away, _) := fedTo driver (presses "C-c a h C-c w x")
            let (back, _) := fedTo away (presses "C-c v")
            let (accepted, _) := fedTo back accept
            away.loop.state.frame.focused == ⟨0⟩ && away.loop.state.prompt.isSome &&
              driverText away == some "x" &&
              minibufferText away == some "h" &&
              back.loop.state.frame.focused == ⟨1⟩ &&
              promptEcho accepted == greeted (answer "h") &&
              closed accepted &&
              driverText accepted == some "x" },
    { name :=
        "with the asking view closed while the prompt is open: the prompt stays open, and after the accept key the focus is on the first window of the tree, which is the target of the continuation's command"
      run :=
        pure <|
          match minibufferDriver twoBuffers with
          | none => false
          | some driver =>
            let (closing, _) := fedTo driver (presses "C-c a h C-c k")
            let (accepted, _) := fedTo closing accept
            closing.loop.state.prompt.map (·.asker) == some ⟨0⟩ &&
              closing.loop.state.windows.map (·.id) == #[⟨1⟩, ⟨2⟩] &&
              closing.loop.state.frame.focused == ⟨2⟩ &&
              promptEcho accepted == greeted (answer "h") 1 &&
              closed accepted ⟨1⟩ &&
              accepted.loop.state.windows.map (·.id) == #[⟨1⟩] },
    { name :=
        "the minibuffer's commands are registered under their two names, and its one mode is called by the name the minibuffer's buffer is made with and has no problem under the test scheme"
      run :=
        pure
          (Minibuffer.commands.map (·.name) == #[Minibuffer.acceptName, Minibuffer.cancelName] &&
            Minibuffer.acceptName != Minibuffer.cancelName &&
            Minibuffer.modes.map (·.name) == #[Prompt.mode] &&
            Minibuffer.modes.all fun mode => mode.check TestScheme.scheme == []) }]

/-- The checks of prompts on the loop's driver: the loop's part and its
host's (`promptLoopChecks`), then the minibuffer's commands and its mode
(`promptModeChecks`). -/
def promptChecks : List Check :=
  promptLoopChecks ++ promptModeChecks

/-- A file of three lines of which two end in CRLF and one in a line
feed. -/
def mostlyCrlf : ByteArray :=
  "a\r\nb\r\nc\n".toUTF8

/-- A file of three lines of which two end in a line feed and one in
CRLF. -/
def mostlyLf : ByteArray :=
  "a\nb\nc\r\n".toUTF8

/-- A file with no line break. -/
def unbroken : ByteArray :=
  "no break".toUTF8

/-- The files of the file command checks, in `fileRoot`: `note.txt`, with a
two-byte character, a four-byte one and a byte that is not UTF-8
(`FileCases.noteBytes`), three files that differ in their line endings,
and two files called `x.txt`, in the directories `a` and `b`. -/
def commandFiles : FileModel :=
  [("a", "first x\n"), ("b", "second x\n")].foldl
    (fun (model : FileModel) (directory, text) =>
      (model.withDirectory (fileRoot / directory)).withFile (fileRoot / directory / "x.txt")
        text.toUTF8)
    (fileModelOf
      #[("note.txt", FileCases.noteBytes), ("crlf.txt", mostlyCrlf), ("lf.txt", mostlyLf),
        ("plain.txt", unbroken)])

/-- The path of a file of the file command checks, by its name. -/
def inFiles (name : String) : System.FilePath :=
  fileRoot / name

/-- The keys of the file command checks that open a file, and the path each
opens: `missing.txt` is not there, and `relative.txt` is not an absolute
path. -/
def openKeys : List (String × System.FilePath) :=
  [("C-o n", inFiles "note.txt"), ("C-o c", inFiles "crlf.txt"), ("C-o l", inFiles "lf.txt"),
    ("C-o p", inFiles "plain.txt"), ("C-o m", inFiles "missing.txt"), ("C-o r", "relative.txt"),
    ("C-o a", fileRoot / "a" / "x.txt"), ("C-o b", fileRoot / "b" / "x.txt")]

/-- The invocation that opens `path`: the open command, with the path as
its argument. -/
def opens (path : System.FilePath) : Invocation :=
  { command := Files.openName, arguments := [.str path.toString] }

/-- What a step of the file command checks is handed: the keys of
`openKeys`, each bound to the open command with its path, `C-o o` bound to
the open command with no argument, `C-o V` to the open command with the
arguments the Vim scheme gives a command a key is bound to, a count and a
register, and the open command under its name.

`C-o w` is bound to the save command, under its name, `C-o f` to the save
command with `true` as its argument, and `C-o v` to the save command with
the arguments the Vim scheme gives a command a key is bound to, a count
and a register.

Six more commands, written here: `scratch` (`C-o 0`) shows the scratch
buffer in the window it is called with, `split` (`C-o s`) splits that
window and focuses the new one, `close` (`C-o k`) closes it, `shut`
(`C-o K`) closes the view 1, the first a split makes, whichever window it
is called with, `undo` (`C-o u`) undoes one step of its buffer's history,
`drop` (`C-o d`) removes the buffer 1, the first a file is opened into, and
`save-absent` (`C-o x`) saves a buffer there is none of. -/
def fileKeys : Loop.Keys TestScheme.scheme :=
  dispatchKeys
    (openKeys.map (fun (text, path) => (text, opens path)) ++
      [("C-o o", invoke Files.openName),
        ("C-o V", { command := Files.openName, arguments := [.nat 0, .str ""] }),
        ("C-o 0", invoke "scratch"), ("C-o s", invoke "split"), ("C-o k", invoke "close"),
        ("C-o K", invoke "shut"), ("C-o w", invoke Files.saveName),
        ("C-o f", { command := Files.saveName, arguments := [.bool true] }),
        ("C-o v", { command := Files.saveName, arguments := [.nat 0, .str ""] }),
        ("C-o u", invoke "undo"), ("C-o d", invoke "drop"), ("C-o x", invoke "save-absent")])
    [(Files.openName, fun call => do
        Files.openCommand call
        return none),
      (Files.saveName, fun call => do
        Files.saveCommand call
        return none),
      ("undo", fun call => do
        discard <| call.target.window.buffer.undo
        return none),
      ("drop", fun _ => do
        discard <| (⟨1⟩ : BufferId).remove
        return none),
      ("save-absent", fun _ => do
        Files.save ⟨9⟩
        return none),
      ("scratch", fun call => do
        discard <| call.target.window.id.show ⟨0⟩
        return none),
      ("split", fun call => do
        if let .ok made← call.target.window.id.split .rows then
          discard <| made.focus
        return none),
      ("close", fun call => do
        discard <| call.target.window.id.close
        return none),
      ("shut", fun _ => do
        discard <| (⟨1⟩ : ViewId).close
        return none)]

/-- The jobs of the file command checks, by name: the load job, whose loads
are refused over `limit` bytes, and the save job. -/
def fileJobs (limit : Nat := Files.limit) (name : String) : Option (List Argument → Work) :=
  if name == Files.loadJob then some (Files.loadWork limit)
  else if name == Files.saveJob then some Files.saveWork else none

/-- A driver over the initial state with the keys of the file command
checks, the jobs `registered`, and `files` as the files its jobs reach;
`none` if making the state was refused. -/
def filesDriver (registered : String → Option (List Argument → Work) := fileJobs)
    (files : FileModel := commandFiles) : Option TestDriver :=
  (Loop.Driver.over fileKeys registered (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => { driver with jobs := { files } }

/-- A driver whose commands and jobs are the ones compiled code registers
(`Files.commands`, `Files.jobs`, and `Minibuffer.commands`), each under the
name it is registered under, over the files of the file command checks:
`C-o n` is bound to the open command with the path of `note.txt`, `C-o o`
to the open command with no argument, `C-o w` to the save command, and
`C-o y` to the minibuffer's accept command, in every view. -/
def compiledDriver : Option TestDriver :=
  let keys : Loop.Keys TestScheme.scheme :=
    dispatchKeys
      [("C-o n", opens (inFiles "note.txt")), ("C-o o", invoke Files.openName),
        ("C-o w", invoke Files.saveName), ("C-o y", invoke Minibuffer.acceptName)]
      ((Files.commands ++ Minibuffer.commands).toList.filterMap fun registration =>
        match registration.action with
        | .call run =>
          some
            (registration.name, fun call => do
              run call
              return none)
        | _ => none)
  (Loop.Driver.over keys (fun name => (Files.jobs.find? (·.name == name)).map (·.work))
        (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => { driver with jobs := { files := commandFiles } }

/-- What a view of a driver shows. -/
structure Showing where
  /-- The buffer's id. -/
  id : BufferId
  /-- The buffer. -/
  buffer : Buffer
  /-- What the buffer's text holds in the text model; `none` if it was
  released. -/
  text : Option String
  /-- The ranges of the window's selection, as the text model has them;
  `none` if the marker was given up. -/
  cursors : Option (Array SelectionRange)

/-- What the view `view` of `driver` shows; `none` if it has no window. -/
def showing (driver : TestDriver) (view : ViewId := ⟨0⟩) : Option Showing := do
  let target ← driver.loop.state.target? view
  return {
      id := target.window.buffer
      buffer := target.buffer
      text := (driver.model.texts.texts[target.buffer.text.index]?).join.map (·.contents)
      cursors := (target.selection.runModel driver.model.texts).1.toOption.map (·.ranges) }

/-- The echo area of the last scene `driver`'s display recorded. -/
def echoOf (driver : TestDriver) : Option String :=
  driver.model.display.scenes.back?.map (·.echo)

/-- The status line of the view `view` in the last scene `driver`'s display
recorded. -/
def statusOf (driver : TestDriver) (view : ViewId := ⟨0⟩) : Option (Array StatusField) :=
  driver.model.display.scenes.back?.bind fun scene =>
    (scene.views.find? (·.id == view)).map (·.status)

/-- The status line of a view of a buffer called `name` that is not
modified: the name alone, in the name's face. -/
def named (name : String) : Array StatusField :=
  #[{ text := name, face := Loop.nameFace }]

/-- The status line of a view of a buffer called `name` that is modified:
the name, then the modified field. -/
def namedModified (name : String) : Array StatusField :=
  named name ++ #[{ text := Loop.modifiedMark, face := Loop.modifiedFace }]

/-- The stamp the files `driver`'s jobs reach have for `path`. -/
def stampOf (driver : TestDriver) (path : System.FilePath) : Option File.Stamp :=
  (driver.jobs.files.file? path).map (·.stamp)

/-- The bytes the files `driver`'s jobs reach hold at `path`. -/
def bytesOf (driver : TestDriver) (path : System.FilePath) : Option ByteArray :=
  (driver.jobs.files.file? path).map (·.bytes)

/-- `driver` once another program has written `bytes` as the file at
`path`. -/
def rewritten (driver : TestDriver) (path : System.FilePath) (bytes : ByteArray) : TestDriver :=
  { driver with jobs := { driver.jobs with files := driver.jobs.files.withFile path bytes } }

/-- The file the buffer the view `view` of `driver` shows holds. -/
def heldFile (driver : TestDriver) (view : ViewId := ⟨0⟩) : Option Buffer.File :=
  (showing driver view).bind (·.buffer.file)

/-- What reading `snapshot` is refused with in `driver`'s text model:
`some none` when it reads. -/
def snapshotRefusal (driver : TestDriver) (snapshot : SnapshotId) : Option (Option TextError) :=
  ((refusalOf snapshot.read).runModel driver.model.texts).1.toOption

/-- A driver of the file command checks with the file `note.txt` open in
view 0, and the step that opened it: the open command, and its job
finished. The load is job 1. -/
def noteOpen (files : FileModel := commandFiles) : Option TestDriver :=
  (filesDriver (files := files)).map fun driver => ((fedTo driver (presses "C-o n")).1.finish 1).1

/-- The checks of the file commands (`Editor/Files.lean`), on the loop's
driver over the editor's models and the model of files: opening a file into
a buffer, and saving a buffer to its file. No file is touched. -/
def fileCommandChecks : List Check :=
  let started (steps : Array (Option (Loop.Stepped TestScheme.scheme))) : Array JobStart :=
    steps.flatMap fun step => (step.map (·.starts)).getD #[]
  [{  name :=
        "the open command on a file: once its job is finished, the view the command was called in shows a new buffer whose text is the file's, a byte that is not UTF-8 as its escape, named by the file's base name, with one cursor at its start, not modified, holding the file's path and the stamp the files have for it; the view's status line is that name alone"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let (asked, steps) := fedTo driver (presses "C-o n")
            let (opened, delivered) := asked.finish 1
            match showing opened with
            | none => false
            | some shown =>
              started steps ==
                  #[{ name := Files.loadJob
                      arguments := Files.LoadOrder.arguments { path, view := ⟨0⟩ } }] &&
                (delivered.map (·.ended)) == some (some .finished) &&
                shown.id == ⟨1⟩ &&
                shown.buffer.name == "note.txt" &&
                shown.text == some FileCases.noteText &&
                shown.cursors == some #[⟨0, 0⟩] &&
                !shown.buffer.isModified &&
                (shown.buffer.file.map fun file => (file.path, some file.stamp, file.saving)) ==
                  some (path, (opened.jobs.files.file? path).map (·.stamp), none) &&
                statusOf opened == some (named "note.txt") &&
                opened.loop.state.wellFormed &&
                opened.loop.state.buffers.size == 2 &&
                opened.model.texts.contents == #["", FileCases.noteText] },
    { name :=
        "a buffer's line ending is its file's dominant one: CRLF for a file most of whose lines end in CRLF, a line feed for one most of whose lines end in a line feed, and a line feed for a file with no line break"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let ending (key : String) : Option File.LineEnding :=
              let (asked, _) := fedTo driver (presses key)
              (showing (asked.finish 1).1).bind fun shown =>
                shown.buffer.file.map fun _ => shown.buffer.lineEnding
            ending "C-o c" == some .crlf && ending "C-o l" == some .lf &&
              ending "C-o p" == some .lf },
    { name :=
        "events that arrive while a load is in flight are handled before the load's result: after the open command the view still shows the scratch buffer, two commits fed before the job is finished are each in the scratch buffer's text after their own steps, and the file's buffer is there, and shown, only once the job is finished"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-o n")
            let (first, _) := fedTo asked [.commit "a"]
            let (second, _) := fedTo first [.commit "b"]
            let (opened, _) := second.finish 1
            (showing asked).map (·.id) == some ⟨0⟩ && asked.pending.size == 1 &&
              driverText first == some "a" &&
              driverText second == some "ab" &&
              (showing second).map (·.id) == some ⟨0⟩ &&
              second.loop.state.buffers.size == 1 &&
              second.model.texts.contents == #["ab"] &&
              (showing opened).map (·.id) == some ⟨1⟩ &&
              (showing opened).bind (·.text) == some FileCases.noteText &&
              opened.model.texts.contents == #["ab", FileCases.noteText] },
    { name :=
        "the open command on a path with no file: the echo area says the refusal, the view still shows the buffer it showed, with its cursor, and there is no new buffer and no new text"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver ([.commit "kept"] ++ presses "C-o m")
            let (refused, delivered) := asked.finish 1
            (delivered.map (·.ended)) == some (some .finished) &&
              echoOf refused == some (Files.notOpened (inFiles "missing.txt") .notFound) &&
              (showing refused).map (fun shown => (shown.id, shown.text, shown.cursors)) ==
                some (⟨0⟩, some "kept", some #[⟨4, 4⟩]) &&
              refused.loop.state.buffers.size == 1 &&
              refused.model.texts.texts.size == 1 &&
              refused.model.texts.snapshots.size == asked.model.texts.snapshots.size &&
              refused.jobs.files == asked.jobs.files },
    { name :=
        "a file longer than the limit the load job is registered with is refused as too large, with its size and the limit, and a path that is not absolute as a relative path: each is said in the echo area by the same route, and nothing is opened"
      run :=
        pure <|
          match filesDriver (fileJobs 4), filesDriver with
          | some small, some driver =>
            let (large, _) := fedTo small (presses "C-o n")
            let (large, _) := large.finish 1
            let (relative, _) := fedTo driver (presses "C-o r")
            let (relative, _) := relative.finish 1
            echoOf large ==
                some
                  (Files.notOpened (inFiles "note.txt") (.tooLarge FileCases.noteBytes.size 4)) &&
              large.loop.state.buffers.size == 1 &&
              echoOf relative == some (Files.notOpened "relative.txt" .relativePath) &&
              relative.loop.state.buffers.size == 1
          | _, _ => false },
    { name :=
        "a load order's arguments are read back as the order, and arguments that are no order as none; the load job started with arguments that are no order fails"
      run :=
        pure <|
          let orders : List Files.LoadOrder :=
            [{ path := inFiles "note.txt", view := ⟨0⟩ }, { path := "relative.txt", view := ⟨7⟩ },
              { path := "/a b/é.txt", view := ⟨12⟩ }]
          orders.all (fun order => Files.LoadOrder.ofArguments? order.arguments == some order) &&
            [[], [.str "/a"], [.nat 0, .str "/a"], [.str "/a", .nat 0, .nat 1]].all
              (fun arguments => Files.LoadOrder.ofArguments? arguments == none) &&
            ((Files.loadWork Files.limit [.nat 1] ()).runModel { files := commandFiles }).1 matches
              .failed _ },
    { name :=
        "the markers of the window that showed the scratch buffer are given up once the file's buffer is shown in it, and not before: they answer while the load is in flight and refuse noSuchMarker after the delivery"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-o n")
            let (opened, _) := asked.finish 1
            match driver.loop.state.window? ⟨0⟩ with
            | none => false
            | some old =>
              ((markerRefusals old).runModel asked.model.texts).1.toOption == some [none, none] &&
                ((markerRefusals old).runModel opened.model.texts).1.toOption ==
                  some [some .noSuchMarker, some .noSuchMarker] },
    { name :=
        "a file whose asking view was closed while it loaded is shown in the focused view: the command is called in a second view, that view is closed before the job is finished, and the file's buffer is then shown in the view that has the focus"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let (asked, steps) := fedTo driver (presses "C-o s C-o n")
            let (closed, _) := fedTo asked (presses "C-o k")
            let (opened, _) := closed.finish 1
            started steps ==
                #[{ name := Files.loadJob
                    arguments := Files.LoadOrder.arguments { path, view := ⟨1⟩ } }] &&
              asked.loop.state.frame.focused == ⟨1⟩ &&
              closed.loop.state.frame.focused == ⟨0⟩ &&
              (showing closed ⟨1⟩).isNone &&
              opened.loop.state.findFile path == some ⟨1⟩ &&
              (showing opened).map (·.id) == some ⟨1⟩ &&
              (showing opened).bind (·.text) == some FileCases.noteText &&
              opened.loop.state.wellFormed },
    { name :=
        "a file whose asking view was closed while it loaded, delivered while a prompt has the focus, is shown in the view the prompt was asked from, which is not the first window: the prompt is still open with the focus, the first window shows what it showed, and nothing is said"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            -- Views 0, 1 and 2; the open command is called in view 2, which
            -- is then closed, and the prompt is asked from view 1.
            let (asked, _) := fedTo driver (presses "C-o s C-o s C-o n")
            let (prompted, _) := fedTo asked (presses "C-o k C-o o")
            let (opened, delivered) := prompted.finish 1
            let state := opened.loop.state
            asked.loop.state.frame.focused == ⟨2⟩ && (showing prompted ⟨2⟩).isNone &&
              prompted.loop.state.prompt.map (·.asker) == some ⟨1⟩ &&
              (delivered.map (·.ended)) == some (some .finished) &&
              state.prompt.isSome &&
              state.prompt == prompted.loop.state.prompt &&
              some state.frame.focused == state.minibufferView? &&
              (state.findFile path).isSome &&
              (showing opened ⟨1⟩).map (·.id) == state.findFile path &&
              (showing opened ⟨1⟩).bind (·.text) == some FileCases.noteText &&
              (showing opened).map (·.id) == some ⟨0⟩ &&
              echoOf opened == some "" &&
              state.wellFormed },
    { name :=
        "a file delivered while a prompt has the focus, whose asking view and the view the prompt was asked from were both closed, is shown in the first window of the tree, with the prompt still open"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            -- Views 0 and 1; the open command is called in view 1, the
            -- prompt is asked from it, and it is closed with the prompt open.
            let (asked, _) := fedTo driver (presses "C-o s C-o n C-o o")
            let (closed, _) := fedTo asked (presses "C-o K")
            let (opened, delivered) := closed.finish 1
            let state := opened.loop.state
            asked.loop.state.prompt.map (·.asker) == some ⟨1⟩ && (showing closed ⟨1⟩).isNone &&
              closed.loop.state.prompt == asked.loop.state.prompt &&
              (delivered.map (·.ended)) == some (some .finished) &&
              state.prompt.isSome &&
              state.prompt == asked.loop.state.prompt &&
              some state.frame.focused == state.minibufferView? &&
              (state.findFile path).isSome &&
              (showing opened).map (·.id) == state.findFile path &&
              (showing opened).bind (·.text) == some FileCases.noteText &&
              echoOf opened == some "" &&
              state.wellFormed },
    { name :=
        "the open command called in the minibuffer's view, with a path, shows the file in the view the prompt was asked from and leaves the prompt open: a file that is not open once its job is finished, and one that is open at once, with no job started"
      run :=
        pure <|
          match filesDriver, noteOpen with
          | some driver, some noted =>
            let path := inFiles "note.txt"
            let behind (before after : TestDriver) : Bool :=
              let state := after.loop.state
              state.prompt.isSome && state.prompt == before.loop.state.prompt &&
                some state.frame.focused == state.minibufferView? &&
                (state.findFile path).isSome &&
                (showing after).map (·.id) == state.findFile path &&
                (showing after).bind (·.text) == some FileCases.noteText &&
                echoOf after == some "" &&
                state.wellFormed
            let (prompted, _) := fedTo driver (presses "C-o o")
            let (asked, steps) := fedTo prompted (presses "C-o n")
            let (opened, delivered) := asked.finish 1
            -- The file is open in view 0, which then shows the scratch
            -- buffer again.
            let (shown, _) := fedTo noted (presses "C-o 0 C-o o")
            let (again, repeated) := fedTo shown (presses "C-o n")
            started steps ==
                #[{ name := Files.loadJob
                    arguments := Files.LoadOrder.arguments { path, view := ⟨1⟩ } }] &&
              prompted.loop.state.minibufferView? == some ⟨1⟩ &&
              (delivered.map (·.ended)) == some (some .finished) &&
              behind prompted opened &&
              (showing shown).map (·.id) == some ⟨0⟩ &&
              started repeated == #[] &&
              again.pending.isEmpty &&
              behind shown again
          | _, _ => false },
    { name :=
        "a file loaded where no window can show it is said in the echo area as loaded and not shown: in a state whose focused view has no window, for an order whose view has none either, the buffer is there and holds the file, and the windows show what they showed"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let state := driver.loop.state
            let astray : TestDriver :=
              { driver with
                loop :=
                  { driver.loop with
                    state := { state with frame := { state.frame with focused := ⟨7⟩ } } } }
            let asked :=
              astray.started
                #[{ name := Files.loadJob
                    arguments := Files.LoadOrder.arguments { path, view := ⟨9⟩ } }]
            let (opened, _) := asked.finish 1
            echoOf opened == some (Files.notShown path) &&
              Files.notShown path != Files.notOpened path .notFound &&
              (showing opened).map (·.id) == some ⟨0⟩ &&
              opened.loop.state.findFile path == some ⟨1⟩ },
    { name :=
        "opening a path that is open shows its buffer and makes no second one: with the file open and another buffer shown in the view since, the open command shows the file's buffer again, with one cursor at its start, the step hands back no job to start, and there are as many buffers and texts as before"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-o n")
            let (opened, _) := asked.finish 1
            let (back, _) := fedTo opened (presses "C-o 0")
            let (again, steps) := fedTo back (presses "C-o n")
            (showing back).map (·.id) == some ⟨0⟩ && started steps == #[] &&
              again.pending.isEmpty &&
              (showing again).map (fun shown => (shown.id, shown.text, shown.cursors)) ==
                some (⟨1⟩, some FileCases.noteText, some #[⟨0, 0⟩]) &&
              again.loop.state.buffers.size == opened.loop.state.buffers.size &&
              again.model.texts.texts.size == opened.model.texts.texts.size &&
              echoOf again == some "" },
    { name :=
        "two opens of one path in flight make one buffer: the command is run twice before either job is finished, and once both are, one buffer holds the path, the view shows it, and the second delivery made no text and left no snapshot"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let (asked, _) := fedTo driver (presses "C-o n C-o n")
            let (first, _) := asked.finish 1
            let (second, delivered) := first.finish 2
            asked.pending.size == 2 && (delivered.map (·.ended)) == some (some .finished) &&
              second.loop.state.findFile path == some ⟨1⟩ &&
              second.loop.state.buffers.size == 2 &&
              (showing second).map (·.id) == some ⟨1⟩ &&
              second.model.texts.texts.size == first.model.texts.texts.size &&
              second.model.texts.snapshots.filterMap id ==
                first.model.texts.snapshots.filterMap id &&
              second.jobs.files.held.all (·.isNone) &&
              echoOf second == echoOf first },
    { name :=
        "a second file with the base name a buffer has gets a name of its own: two files called x.txt in two directories open as x.txt and x.txt<2>, each buffer holding its own path and its own text"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-o a")
            let (first, _) := asked.finish 1
            let (asked, _) := fedTo first (presses "C-o b")
            let (second, _) := asked.finish 2
            let seen (driver : TestDriver) :=
              (showing driver).map fun shown =>
                (shown.buffer.name, shown.buffer.file.map (·.path), shown.text)
            seen first == some ("x.txt", some (fileRoot / "a" / "x.txt"), some "first x\n") &&
              seen second ==
                some ("x.txt<2>", some (fileRoot / "b" / "x.txt"), some "second x\n") &&
              statusOf second == some (named "x.txt<2>") &&
              second.loop.state.buffers.size == 3 },
    { name :=
        "the open command where no load job is registered says so in the echo area, by the job's name, starts nothing and leaves the view as it was"
      run :=
        pure <|
          match filesDriver (fun _ => none) with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let (asked, steps) := fedTo driver (presses "C-o n")
            started steps == #[] && asked.pending.isEmpty &&
              echoOf asked == some (Files.notOpening path (.noSuchJob Files.loadJob)) &&
              Files.notOpening path (.noSuchJob Files.loadJob) != Files.notOpened path .notFound &&
              (showing asked).map (·.id) == some ⟨0⟩ &&
              asked.loop.state.buffers.size == 1 },
    { name :=
        "the open command with no path among its arguments, with none and with the count and the register an input scheme hands a command, starts no job and asks for the path: a prompt is open, labelled as the open command's, whose continuation is the open command with no argument of its own, asked from the view the command was called in"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            ["C-o o", "C-o V"].all fun typed =>
              let (asked, steps) := fedTo driver (presses typed)
              started steps == #[] && asked.pending.isEmpty && echoOf asked == some "" &&
                asked.loop.state.prompt ==
                  some
                    { label := Files.openPrompt, view := ⟨1⟩, asker := ⟨0⟩
                      continuation := { command := Files.openName } } &&
                !Files.openPrompt.isEmpty &&
                asked.loop.state.frame.focused == ⟨1⟩ &&
                asked.loop.state.wellFormed },
    { name :=
        "the open command with no path while a prompt is open cannot ask: the echo area says so, with the refusal, and the one prompt is still open"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-o o")
            let (again, steps) := fedTo asked (presses "C-o o")
            started steps == #[] && echoOf again == some (Files.notAsking (.alreadyOpen ⟨1⟩)) &&
              again.loop.state.prompt == asked.loop.state.prompt &&
              again.loop.state.prompt.isSome &&
              again.loop.state.windows.size == 2 },
    { name :=
        "the open command asks for its path and opens the answer: with the commands compiled code registers, the open command with no argument, the path of a file committed into the minibuffer, the accept command and the load job finished leave the view the command was called in showing the file's text, in a buffer called by the file's base name, with the prompt closed, and one job was started"
      run :=
        pure <|
          match compiledDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let (asked, _) := fedTo driver (presses "C-o o")
            let (typed, _) := fedTo asked [.commit path.toString]
            let (accepted, _) := fedTo typed (presses "C-o y")
            let (opened, delivered) := accepted.finish 1
            asked.loop.state.prompt.isSome && asked.pending.isEmpty &&
              minibufferText typed == some path.toString &&
              accepted.loop.state.prompt == none &&
              accepted.loop.state.frame.focused == ⟨0⟩ &&
              accepted.pending.map (fun job => (job.id, job.name)) == #[(1, Files.loadJob)] &&
              (delivered.map (·.ended)) == some (some .finished) &&
              opened.pending.isEmpty &&
              opened.next == 2 &&
              (showing opened).map (fun shown => (shown.buffer.name, shown.text)) ==
                some ("note.txt", some FileCases.noteText) &&
              statusOf opened == some (named "note.txt") &&
              opened.loop.state.wellFormed },
    { name :=
        "the save command on a modified buffer: once its job is finished, the file's bytes are the buffer's text as a save writes it, the buffer is not modified, its stamp is the one the files now have, no save is in flight, the snapshot the command took is released, the echo area says the file was written, and the view's status line has no modified field"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let text := "x" ++ FileCases.noteText
            let (saving, _) := fedTo opened ([.commit "x"] ++ presses "C-o w")
            let (saved, delivered) := saving.finish 2
            match (heldFile saving).bind (·.saving), showing saved with
            | some flight, some shown =>
              (delivered.map (·.ended)) == some (some .finished) && shown.text == some text &&
                bytesOf saved path == some (FileModel.encode text) &&
                !shown.buffer.isModified &&
                shown.buffer.file.map (·.stamp) == stampOf saved path &&
                stampOf saved path != stampOf opened path &&
                (shown.buffer.file.map (·.saving)) == some none &&
                snapshotRefusal saved flight.snapshot == some (some .noSuchSnapshot) &&
                echoOf saved == some (Files.wrote path) &&
                statusOf saved == some (named "note.txt")
            | _, _ => false },
    { name :=
        "while a save is in flight the buffer is still modified: after the save command and before its job is finished, the step has handed back the save job with its order, the buffer's save is in flight with a snapshot that reads as the buffer's text and the stamp the file was opened with, and the view's status line has the modified field"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let (edited, _) := fedTo opened [.commit "x"]
            let (saving, steps) := fedTo edited (presses "C-o w")
            match (heldFile saving).bind (·.saving), (heldFile opened).map (·.stamp) with
            | some flight, some stamp =>
              started steps ==
                  #[{ name := Files.saveJob
                      arguments :=
                        Files.SaveOrder.arguments
                          { buffer := ⟨1⟩, snapshot := flight.snapshot, path
                            expect := .unchanged stamp } }] &&
                saving.pending.size == 1 &&
                (showing saving).map (·.buffer.isModified) == some true &&
                (heldFile saving).map (·.stamp) == some stamp &&
                ((flight.snapshot.read.runModel saving.model.texts).1.toOption) ==
                  some ("x" ++ FileCases.noteText) &&
                some flight.state == (showing edited).map (·.buffer.history.state) &&
                statusOf saving == some (namedModified "note.txt")
            | _, _ => false },
    { name :=
        "a save of a buffer whose file changed on disk after it was loaded leaves the file as it is and says the changed-on-disk refusal in the echo area, with the stamp the file now has: the buffer is still modified, with the stamp it was opened with, no save is in flight, and the snapshot is released"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let changed := rewritten opened path JobContract.otherFile
            let (saving, _) := fedTo changed ([.commit "x"] ++ presses "C-o w")
            let (refused, delivered) := saving.finish 2
            match (heldFile saving).bind (·.saving), stampOf changed path with
            | some flight, some found =>
              (delivered.map (·.ended)) == some (some .finished) &&
                bytesOf refused path == some JobContract.otherFile &&
                stampOf refused path == some found &&
                some found != stampOf opened path &&
                echoOf refused == some (Files.notSaved path (.changed (some found))) &&
                (showing refused).map (·.buffer.isModified) == some true &&
                (heldFile refused).map (fun file => (some file.stamp, file.saving)) ==
                  some (stampOf opened path, none) &&
                snapshotRefusal refused flight.snapshot == some (some .noSuchSnapshot) &&
                statusOf refused == some (namedModified "note.txt")
            | _, _ => false },
    { name :=
        "open then save with no edit writes the file and leaves its bytes as they were, for a file whose lines end in line feeds, one whose lines end in CRLF, one with both and two with bytes that are not UTF-8: the save's job has run, the files have a new stamp for the path, which is the buffer's, the echo area says the file was written, and the bytes are byte for byte what they were"
      run :=
        pure <|
          ["a\nb\n".toUTF8, "a\r\nb\r\n".toUTF8, mostlyCrlf, FileCases.noteBytes,
                JobContract.rawFile].all
            fun bytes =>
            match noteOpen (fileModelOf #[("note.txt", bytes)]) with
            | none => false
            | some opened =>
              let path := inFiles "note.txt"
              let (saving, _) := fedTo opened (presses "C-o w")
              let (saved, delivered) := saving.finish 2
              (saving.pending.map fun job => (job.name, job.outcome matches .finished _)) ==
                  #[(Files.saveJob, true)] &&
                (delivered.map (·.ended)) == some (some .finished) &&
                bytesOf saved path == some bytes &&
                (stampOf saved path).isSome &&
                stampOf saved path != stampOf opened path &&
                (heldFile saved).map (·.stamp) == stampOf saved path &&
                echoOf saved == some (Files.wrote path) &&
                (showing saved).map (·.buffer.isModified) == some false },
    { name :=
        "a save order's arguments are read back as the order, for each thing a save can expect and for a stamp from before 1970, and arguments that are no order as none; the save job started with arguments that are no order fails"
      run :=
        pure <|
          let stamps : List File.Stamp :=
            [{ seconds := 5, nanoseconds := 7, size := 9 },
              { seconds := -3, nanoseconds := 999999999, size := 0 }]
          let expects : List File.Expect := stamps.map .unchanged ++ [.absent, .whatever]
          expects.all
                (fun expect =>
                  let order : Files.SaveOrder :=
                    { buffer := ⟨3⟩, snapshot := ⟨11⟩, path := "/a b/é.txt", expect }
                  Files.SaveOrder.ofArguments? order.arguments == some order) &&
              [[], [.nat 1], [.nat 1, .nat 2, .str "/a"],
                    [.nat 1, .nat 2, .str "/a", .str "sometimes"],
                    [.nat 1, .nat 2, .str "/a", .str "absent", .nat 1],
                    [.str "/a", .nat 1, .nat 2, .str "absent"]].all
                (fun arguments => Files.SaveOrder.ofArguments? arguments == none) &&
            ((Files.saveWork [.nat 1] ()).runModel { files := commandFiles }).1 matches .failed _ },
    { name :=
        "the save command on a buffer with no file says so in the echo area, by the buffer's name, starts no job and takes no snapshot; saving a buffer there is none of says so too"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (shown, _) := fedTo driver [pressF5]
            let (asked, steps) := fedTo shown (presses "C-o w")
            let (absent, absentSteps) := fedTo shown (presses "C-o x")
            match (showing driver).map (·.buffer.name) with
            | none => false
            | some name =>
              started steps == #[] && asked.pending.isEmpty &&
                echoOf asked == some (Files.noFile name) &&
                asked.model.texts.snapshots.size == shown.model.texts.snapshots.size &&
                started absentSteps == #[] &&
                echoOf absent == some Files.noBuffer &&
                absent.model.texts.snapshots.size == shown.model.texts.snapshots.size &&
                Files.noBuffer != Files.noFile name },
    { name :=
        "a second save while one is in flight is refused when it is asked: the echo area says the file is being saved, no second job is started and no snapshot is taken, and once the first is finished the buffer is saved once, not modified, with the stamp the files have"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let (saving, _) := fedTo opened ([.commit "x"] ++ presses "C-o w")
            let (again, steps) := fedTo saving (presses "C-o w")
            let (saved, _) := again.finish 2
            started steps == #[] && again.pending.size == 1 &&
              echoOf again == some (Files.beingSaved path) &&
              again.model.texts.snapshots.size == saving.model.texts.snapshots.size &&
              heldFile again == heldFile saving &&
              (showing saved).map (·.buffer.isModified) == some false &&
              (heldFile saved).map (fun file => (some file.stamp, file.saving)) ==
                some (stampOf saved path, none) &&
              saved.jobs.files.writes == opened.jobs.files.writes + 1 &&
              echoOf saved == some (Files.wrote path) },
    { name :=
        "a save that reports late marks the state it wrote: a commit fed between the save command and its job's end leaves the buffer modified once the job is finished, with the new stamp, and one undo, back to the state that was written, leaves it not modified"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let (saving, _) := fedTo opened ([.commit "x"] ++ presses "C-o w")
            let (typed, _) := fedTo saving [.commit "y"]
            let (saved, _) := typed.finish 2
            let (undone, _) := fedTo saved (presses "C-o u")
            bytesOf saved path == some (FileModel.encode ("x" ++ FileCases.noteText)) &&
              (showing saved).bind (·.text) == some ("xy" ++ FileCases.noteText) &&
              (showing saved).map (·.buffer.isModified) == some true &&
              (heldFile saved).map (fun file => (some file.stamp, file.saving)) ==
                some (stampOf saved path, none) &&
              statusOf saved == some (namedModified "note.txt") &&
              (showing undone).bind (·.text) == some ("x" ++ FileCases.noteText) &&
              (showing undone).map (·.buffer.isModified) == some false &&
              statusOf undone == some (named "note.txt") },
    { name :=
        "a forced save writes over a file that changed on disk: with the file written by another program since it was opened, the save command with true as its argument writes the buffer's text as the file, and the buffer is not modified, with the new stamp; with the arguments the Vim scheme gives a bound command it is a plain save, and is refused as changed on disk"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let text := "x" ++ FileCases.noteText
            let (edited, _) := fedTo (rewritten opened path JobContract.otherFile) [.commit "x"]
            let (forcing, steps) := fedTo edited (presses "C-o f")
            let (forced, _) := forcing.finish 2
            let (plain, _) := fedTo edited (presses "C-o v")
            let (refused, _) := plain.finish 2
            (started steps).map
                  (fun start => (Files.SaveOrder.ofArguments? start.arguments).map (·.expect)) ==
                #[some .whatever] &&
              bytesOf forced path == some (FileModel.encode text) &&
              (showing forced).map (·.buffer.isModified) == some false &&
              (heldFile forced).map (fun file => (some file.stamp, file.saving)) ==
                some (stampOf forced path, none) &&
              echoOf forced == some (Files.wrote path) &&
              bytesOf refused path == some JobContract.otherFile &&
              echoOf refused == some (Files.notSaved path (.changed (stampOf edited path))) &&
              (showing refused).map (·.buffer.isModified) == some true },
    { name :=
        "the save command where no save job is registered says so in the echo area, by the job's name, and leaves no save in flight: nothing is started, the snapshot it took is released, the buffer is as it was, and once the job is registered the buffer is saved"
      run :=
        pure <|
          match
            (filesDriver fun name =>
                  if name == Files.loadJob then fileJobs Files.limit name else none).map
              fun driver => ((fedTo driver (presses "C-o n")).1.finish 1).1 with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let (edited, _) := fedTo opened [.commit "x"]
            let (asked, steps) := fedTo edited (presses "C-o w")
            let registered : TestDriver := { asked with registered := fileJobs }
            let (saving, _) := fedTo registered (presses "C-o w")
            let (saved, _) := saving.finish 2
            let live (driver : TestDriver) := (driver.model.texts.snapshots.filterMap id).size
            started steps == #[] && asked.pending.isEmpty &&
              echoOf asked == some (Files.notSaving path (.noSuchJob Files.saveJob)) &&
              Files.notSaving path (.noSuchJob Files.saveJob) != Files.notSaved path .notFound &&
              heldFile asked == heldFile edited &&
              (heldFile asked).map (·.saving) == some none &&
              asked.model.texts.snapshots.size == edited.model.texts.snapshots.size + 1 &&
              live asked == live edited &&
              bytesOf asked path == some FileCases.noteBytes &&
              echoOf saved == some (Files.wrote path) &&
              (showing saved).map (·.buffer.isModified) == some false &&
              bytesOf saved path == some (FileModel.encode ("x" ++ FileCases.noteText)) },
    { name :=
        "a buffer removed while its save runs: the file is written, the delivery says so in the echo area and is not refused, and the buffer stays removed"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let (saving, _) := fedTo opened ([.commit "x"] ++ presses "C-o w")
            let (removed, _) := fedTo saving (presses "C-o 0 C-o d")
            let (saved, delivered) := removed.finish 2
            removed.loop.state.buffer? ⟨1⟩ == none &&
              (delivered.map (·.ended)) == some (some .finished) &&
              echoOf saved == some (Files.wrote path) &&
              bytesOf saved path == some (FileModel.encode ("x" ++ FileCases.noteText)) &&
              saved.loop.state.buffers == removed.loop.state.buffers &&
              saved.loop.state.wellFormed },
    { name :=
        "the file commands and their jobs as compiled code registers them: the open command and the save command are registered under their names and the load job and the save job under theirs, the open command with a path opens the file and the save command saves the buffer, and the open command with no path starts nothing and asks for one"
      run :=
        pure <|
          match compiledDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let text := "x" ++ FileCases.noteText
            let (bare, steps) := fedTo driver (presses "C-o o")
            let (asked, _) := fedTo driver (presses "C-o n")
            let (opened, _) := asked.finish 1
            let (saving, _) := fedTo opened ([.commit "x"] ++ presses "C-o w")
            let (saved, _) := saving.finish 2
            Files.commands.map (·.name) == #[Files.openName, Files.saveName] &&
              Files.jobs.map (·.name) == #[Files.loadJob, Files.saveJob] &&
              started steps == #[] &&
              bare.pending.isEmpty &&
              bare.loop.state.prompt.map (fun asking => (asking.label, asking.continuation)) ==
                some (Files.openPrompt, { command := Files.openName }) &&
              (showing opened).bind (·.text) == some FileCases.noteText &&
              (showing saved).bind (·.text) == some text &&
              bytesOf saved path == some (FileModel.encode text) &&
              echoOf saved == some (Files.wrote path) }]

/-- What the command `leave` of the quit checks says in the echo area when
it is refused, for a buffer called `name`. -/
def notLeaving (name : String) : String :=
  s!"not leaving: {name}"

/-- What a step of the quit checks is handed: the open command with the
path of `note.txt` (`C-o n`) and the save command (`C-o w`), as the file
command checks have them, and six commands written here, under `C-l`:
`leave` (`l`) asks the editor to quit and says a refusal (`notLeaving`),
`leave-then-fail` (`f`) asks and is then refused, `stamp` (`s`) edits its
buffer, `other` (`o`) says `other`, `hand-leave` (`h`) asks for `leave`
to be run after it, and `hand-leave-other` (`t`) asks for `leave` and then
`other` to be run after it. Two more ask for the config to be reloaded: `again`
(`r`), and `again-then-fail` (`g`), which asks and is then refused. -/
def quitKeys : Loop.Keys TestScheme.scheme :=
  dispatchKeys
    [("C-o n", opens (inFiles "note.txt")), ("C-o w", invoke Files.saveName),
      ("C-l l", invoke "leave"), ("C-l f", invoke "leave-then-fail"), ("C-l s", invoke "stamp"),
      ("C-l o", invoke "other"), ("C-l h", invoke "hand-leave"),
      ("C-l t", invoke "hand-leave-other"), ("C-l r", invoke "again"),
      ("C-l g", invoke "again-then-fail")]
    [(Files.openName, fun call => do
        Files.openCommand call
        return none),
      (Files.saveName, fun call => do
        Files.saveCommand call
        return none),
      ("leave", fun _ => do
        if let .error (.unsaved name)← quit then
          message (notLeaving name)
        return none),
      ("leave-then-fail", failingAfter fun _ => discard quit), ("stamp", stamp),
      ("other", fun _ => do
        message "other"
        return none),
      ("hand-leave", fun _ => do
        Editor.invoke { command := "leave" }
        return none),
      ("hand-leave-other", fun _ => do
        Editor.invoke { command := "leave" }
        Editor.invoke { command := "other" }
        return none),
      ("again", fun _ => do
        reloadConfig
        return none),
      ("again-then-fail", failingAfter fun _ => reloadConfig)]

/-- A driver of the quit checks over the files `files`, with the file
`note.txt` open in view 0: the open command, and its job finished. The load
is job 1. -/
def quitDriver (files : FileModel := commandFiles) : Option TestDriver :=
  (Loop.Driver.over quitKeys fileJobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => ((fedTo { driver with jobs := { files } } (presses "C-o n")).1.finish 1).1

/-- The checks of quitting in the loop (`Editor/Loop.lean`, "Quit"), on the
loop's driver over the editor's models and the model of files, with
commands written here: the step says stop once the editor can leave, a quit
waits for a save in flight, and a quit that cannot go ahead is withdrawn.
They name no ex name. -/
def dispatchQuitChecks : List Check :=
  let next (steps : Array (Option (Loop.Stepped TestScheme.scheme))) : Array (Option Loop.Next) :=
    steps.map (·.map (·.next))
  let path := inFiles "note.txt"
  [{  name :=
        "a key whose command asks the editor to quit: the step publishes a scene, the last, and says stop, and the driver has stopped; a step that ran another command says continue"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let (other, went) := fedTo driver (presses "C-l o")
            let (left, steps) := fedTo other (presses "C-l l")
            next went == #[some .continue, some .continue] && !other.stopped &&
              next steps == #[some .continue, some .stop] &&
              left.stopped &&
              left.loop.state.quitting &&
              left.model.display.scenes.size == other.model.display.scenes.size + 2 },
    { name :=
        "a command that asks the editor to quit and is then refused says continue, and the state is not asked to quit"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let (failed, steps) := fedTo driver (presses "C-l f")
            next steps == #[some .continue, some .continue] && !failed.stopped &&
              !failed.loop.state.quitting &&
              promptEcho failed == "leave-then-fail: refused: bad range" },
    { name :=
        "asked to quit while a save is in flight, the step says continue and the editor waits: a key fed meanwhile is handled, the delivery of the save's result says stop, and the file then holds the buffer's text"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let text := "x" ++ FileCases.noteText
            let (saving, _) := fedTo driver ([.commit "x"] ++ presses "C-o w")
            let (asked, steps) := fedTo saving (presses "C-l l")
            let (meanwhile, went) := fedTo asked (presses "C-l o")
            let (left, delivered) := meanwhile.finish 2
            next steps == #[some .continue, some .continue] && promptEcho asked == "" &&
              asked.loop.state.quitting &&
              !asked.stopped &&
              next went == #[some .continue, some .continue] &&
              promptEcho meanwhile == "other" &&
              meanwhile.loop.state.quitting &&
              !meanwhile.stopped &&
              delivered.map (·.next) == some .stop &&
              left.stopped &&
              bytesOf left path == some (FileModel.encode text) &&
              (showing left).map (·.buffer.isModified) == some false },
    { name :=
        "asked to quit while a save is in flight that is then refused, the file having changed behind the editor: the delivery says continue, the state is no longer asked to quit, the echo area has the save's refusal, and the buffer is still modified"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let changed := rewritten driver path JobContract.otherFile
            let (asked, _) := fedTo changed ([.commit "x"] ++ presses "C-o w C-l l")
            let (refused, delivered) := asked.finish 2
            asked.loop.state.quitting && delivered.map (·.next) == some .continue &&
              !refused.stopped &&
              !refused.loop.state.quitting &&
              echoOf refused == some (Files.notSaved path (.changed (stampOf changed path))) &&
              (showing refused).map (·.buffer.isModified) == some true &&
              bytesOf refused path == some JobContract.otherFile },
    { name :=
        "asked to quit while a save of a buffer that is not modified is in flight, which is then refused, the file having changed behind the editor: the delivery says continue, the driver has not stopped, the state is no longer asked to quit, and the echo area has the save's refusal"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let changed := rewritten driver path JobContract.otherFile
            let (asked, _) := fedTo changed (presses "C-o w C-l l")
            let (refused, delivered) := asked.finish 2
            asked.loop.state.quitting && !asked.stopped &&
              (showing asked).map (·.buffer.isModified) == some false &&
              delivered.map (·.next) == some .continue &&
              !refused.stopped &&
              !refused.loop.state.quitting &&
              echoOf refused == some (Files.notSaved path (.changed (stampOf changed path))) &&
              bytesOf refused path == some JobContract.otherFile },
    { name :=
        "an edit made while a quit waits for a save withdraws it: the state is no longer asked to quit after the edit's step, and the delivery of the save's result says continue, with the file written and the buffer still modified"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver ([.commit "x"] ++ presses "C-o w C-l l")
            let (edited, steps) := fedTo asked [.commit "y"]
            let (saved, delivered) := edited.finish 2
            asked.loop.state.quitting && next steps == #[some .continue] &&
              !edited.loop.state.quitting &&
              delivered.map (·.next) == some .continue &&
              !saved.stopped &&
              !saved.loop.state.quitting &&
              bytesOf saved path == some (FileModel.encode ("x" ++ FileCases.noteText)) &&
              (showing saved).map (·.buffer.isModified) == some true },
    { name :=
        "a command that asks to quit with a file's buffer modified is refused and the editor goes on; once the buffer is saved the same key stops it"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let (refused, steps) := fedTo driver ([.commit "x"] ++ presses "C-l l")
            let (saved, _) := fedTo refused (presses "C-o w")
            let (saved, _) := saved.finish 2
            let (left, last) := fedTo saved (presses "C-l l")
            promptEcho refused == notLeaving "note.txt" && !refused.loop.state.quitting &&
              steps.all (·.all (·.next == .continue)) &&
              !saved.stopped &&
              next last == #[some .continue, some .stop] &&
              left.stopped },
    { name :=
        "the driver records that a step said stop when the step was one it ran for an invocation a command asked for: the fed step says continue and the driver has stopped"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let (left, steps) := fedTo driver (presses "C-l h")
            next steps == #[some .continue, some .continue] && left.stopped &&
              left.loop.state.quitting },
    { name :=
        "once a step said stop the driver runs no further invocation: a command that asks for a quitting command and then another to be run after it stops the driver at the first, whose scene is the last, and the second never runs: no scene says its message; where the first is refused, the second runs"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let echoes (before after : TestDriver) : Array String :=
              (after.model.display.scenes.map (·.echo)).extract before.model.display.scenes.size
            let (left, steps) := fedTo driver (presses "C-l t")
            let (went, _) := fedTo driver ([.commit "x"] ++ presses "C-l t")
            next steps == #[some .continue, some .continue] && left.stopped &&
              left.model.display.scenes.size == driver.model.display.scenes.size + 3 &&
              !(echoes driver left).contains "other" &&
              !went.stopped &&
              promptEcho went == "other" &&
              (echoes driver went).contains (notLeaving "note.txt") },
    { name :=
        "a step whose command asked for the config to be reloaded hands the request back, and the state after it is not asking; a step that ran another command hands back none, and so does one whose command asked and was then refused; the driver counts the reloads asked for"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let asked (steps : Array (Option (Loop.Stepped TestScheme.scheme))) :=
              steps.map (·.map (·.reload))
            let (once, steps) := fedTo driver (presses "C-l r")
            let (other, went) := fedTo once (presses "C-l o")
            let (failed, lost) := fedTo other (presses "C-l g")
            let (twice, _) := fedTo failed (presses "C-l r")
            asked steps == #[some false, some true] && !once.loop.state.reload &&
              once.reloads == 1 &&
              asked went == #[some false, some false] &&
              asked lost == #[some false, some false] &&
              !failed.loop.state.reload &&
              failed.reloads == 1 &&
              twice.reloads == 2 &&
              driver.reloads == 0 }]

/-- The ex bindings of the ex line's own checks, written here: `say` runs
the command `greet` of the prompt checks with the rest of the line, and
`plain` runs it and takes nothing; `ghost` is bound to a command nobody
registered, and `burst` to `boom`, which inserts and is then refused. -/
def exTestBindings : Array Ex.Binding :=
  #[{ name := "say", command := "greet", takes := .text }, { name := "plain", command := "greet" },
    { name := "ghost", command := "nobody" }, { name := "burst", command := "boom" }]

/-- What a step of the ex checks is handed. The commands are the ones
compiled code registers for the ex line, the minibuffer and files
(`Ex.commands`, `Minibuffer.commands`, `Files.commands`), each under the
name it is registered under, and then the commands of the prompt checks:
`greet`, which says what it was called with, `boom`, `other` and the test
scheme's self-insert. The ex bindings a command is told of are `bindings`,
the latest of a name.

One keymap, the same for every view: `C-e e` runs the ex command, `C-e V`
runs it with the arguments the Vim scheme gives a command a key is bound
to, a count and a register, `C-e l` runs it with the line `say hello there`
as its first argument, `C-e y` and `C-e n` run the minibuffer's accept and
cancel commands, and `C-e o` runs `other`. -/
def exKeys (bindings : Array Ex.Binding := exTestBindings) : Loop.Keys TestScheme.scheme :=
  let compiled : List (String × Dispatched) :=
    (Ex.commands ++ Minibuffer.commands ++ Files.commands).toList.filterMap fun registration =>
      match registration.action with
      | .call run =>
        some
          (registration.name, fun call => do
            run call
            return none)
      | _ => none
  {
    dispatchKeys
      [("C-e e", invoke Ex.name), ("C-e V", { command := Ex.name, arguments := [.nat 0, .str ""] }),
        ("C-e l", { command := Ex.name, arguments := [.str "say hello there"] }),
        ("C-e y", invoke Minibuffer.acceptName), ("C-e n", invoke Minibuffer.cancelName),
        ("C-e o", invoke "other")]
      (compiled ++ promptCommands) with
    registered := { ex := fun name => bindings.findRev? (·.name == name) } }

/-- A driver of the ex checks over the initial state, told of the ex
bindings `bindings`, with the file commands' jobs and the files of the file
command checks; `none` if making the state was refused. -/
def exDriver (bindings : Array Ex.Binding := exTestBindings) : Option TestDriver :=
  (Loop.Driver.over (exKeys bindings) fileJobs (EditorState.initial ⟨640, 480⟩)
        editorModel).toOption.map
    fun driver => { driver with jobs := { files := commandFiles } }

/-- The events of one ex line: the key that opens the ex line, `line`
committed into the minibuffer, and the accept key. -/
def exLine (line : String) : List Event :=
  presses "C-e e" ++ [.commit line] ++ presses "C-e y"

/-- The echo area of each scene `after` recorded that `before` had not. -/
def echoesSince (before after : TestDriver) : Array String :=
  (after.model.display.scenes.map (·.echo)).extract before.model.display.scenes.size

/-- A driver of the ex checks told of the ex names that ship
(`Ex.bindings`), with the file `note.txt` open in view 0 by the ex line
`e` and its path, its load finished. The load is job 1. -/
def exNoteOpen : Option TestDriver :=
  (exDriver Ex.bindings).map fun driver =>
    ((fedTo driver (exLine s!"e {inFiles "note.txt"}")).1.finish 1).1

/-- The checks of the ex command line (`Editor/Ex.lean`,
`Editor/Ex/Compiled.lean`), on the loop's driver over the editor's models,
the model of files and the test scheme: the ex command opens a prompt and
runs its answer as the command the line's name is bound to. Each message is
read from the function that makes it. -/
def exChecks : List Check :=
  let closed (driver : TestDriver) : Bool :=
    let state := driver.loop.state
    state.prompt == none && state.frame.focused == ⟨0⟩ && state.answered.isEmpty && state.wellFormed
  let hello : List Argument := [.str "hello there"]
  [{  name :=
        "the ex command opens a prompt labelled with the ex line's label, whose continuation is the ex command itself, with the focus in the minibuffer's view; called with a count and a register first, as a key under the Vim scheme calls it, it asks the same"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let asked (keys : String) :=
              let (asking, _) := fedTo driver (presses keys)
              asking.loop.state.prompt.map (fun asking => (asking.label, asking.continuation)) ==
                  some (Ex.label, { command := Ex.name }) &&
                asking.loop.state.minibufferView? == some asking.loop.state.frame.focused &&
                asking.loop.state.frame.focused != ⟨0⟩ &&
                asking.loop.state.wellFormed
            asked "C-e e" && asked "C-e V" },
    { name :=
        "a line typed on the ex line and accepted runs the command its name is bound to, with the rest of the line as its first argument, a string, in the view the line was asked from and with no keys; the accept key is three steps, the accept command, the ex command and the bound command, each with a scene"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-e e" ++ [.commit "say hello there"])
            let (accepted, _) := fedTo typed (presses "C-e y")
            minibufferText typed == some "say hello there" &&
              promptEcho accepted == greeted hello &&
              closed accepted &&
              echoesSince typed accepted == #["", "", "", greeted hello] },
    { name :=
        "criterion 5: a name nobody bound leaves the ex line's message for it in the echo area, with the prompt closed, and the editor goes on: the next key's command runs"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (unknown, _) := fedTo driver (exLine "nope 1 2")
            let (after, _) := fedTo unknown (presses "C-e o")
            promptEcho unknown == Ex.unknown "nope" && closed unknown &&
              echoOf unknown == some (Ex.unknown "nope") &&
              promptEcho after == "other" },
    { name :=
        "an argument for an ex name that takes nothing leaves the ex line's message for it in the echo area and runs nothing; the name alone runs its command with no arguments"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (refused, _) := fedTo driver (exLine "plain hello")
            let (ran, _) := fedTo driver (exLine "plain")
            promptEcho refused == Ex.noArgument "plain" && closed refused &&
              !(echoesSince driver refused).contains (greeted hello) &&
              promptEcho ran == greeted [] },
    { name :=
        "an empty line and a line of white space run nothing and leave the echo area empty, with the prompt closed"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (empty, _) := fedTo driver (presses "C-e e C-e y")
            let (blank, _) := fedTo driver (exLine "   ")
            promptEcho empty == "" && closed empty && promptEcho blank == "" && closed blank },
    { name :=
        "an ex name bound to a command nobody registered says there is no such command, by the command's name"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (ran, _) := fedTo driver (exLine "ghost")
            promptEcho ran == "nobody: no such command" && closed ran },
    { name :=
        "a command an ex line runs that is refused is rolled back, and the echo area says the refusal under the command's own name, not the ex command's"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (ran, _) := fedTo driver (exLine "burst")
            promptEcho ran == "boom: refused: bad range" && driverText ran == some "" &&
              closed ran },
    { name :=
        "a key fed after the accept key is handled after the command the line runs: the scenes show the bound command's message before the other command's"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-e e" ++ [.commit "say hello there"])
            let (after, _) := fedTo typed (presses "C-e y C-e o")
            echoesSince typed after == #["", "", "", greeted hello, greeted hello, "other"] },
    { name :=
        "the ex command called with a string as its first argument runs that line and opens no prompt"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (ran, steps) := fedTo driver (presses "C-e l")
            promptEcho ran == greeted hello && closed ran &&
              steps.map (·.map (·.answered)) ==
                #[some #[], some #[{ command := "greet", arguments := hello }]] &&
              ran.model.display.scenes.all (·.views.size == 1) },
    { name :=
        "the ex command while a prompt is open says the refusal after its own name and leaves that prompt open, with what was typed"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-e e" ++ [.commit "say"])
            let (again, _) := fedTo typed (presses "C-e e")
            (typed.loop.state.minibufferView?).map
                  (fun view => promptEcho again == Ex.notAsking (.alreadyOpen view)) ==
                some true &&
              again.loop.state.prompt == typed.loop.state.prompt &&
              again.loop.state.prompt.isSome &&
              minibufferText again == some "say" },
    { name := "cancelling the ex line runs nothing: the prompt is closed and no command is run"
      run :=
        pure <|
          match exDriver with
          | none => false
          | some driver =>
            let (cancelled, steps) :=
              fedTo driver (presses "C-e e" ++ [.commit "say hello there"] ++ presses "C-e n")
            promptEcho cancelled == "" && closed cancelled &&
              steps.all (·.all (·.answered.isEmpty)) &&
              !(echoesSince driver cancelled).contains (greeted hello) },
    { name :=
        "the ex name e with a path: once the load is finished the view the line was asked from shows a buffer with the file's text, holding the file's path; before that it shows the scratch buffer"
      run :=
        pure <|
          match exDriver Ex.bindings with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let (asked, _) := fedTo driver (exLine s!"e {path}")
            let (opened, _) := asked.finish 1
            (showing asked).map (·.id) == some ⟨0⟩ && asked.pending.size == 1 && closed asked &&
              (showing opened).bind (·.text) == some FileCases.noteText &&
              (heldFile opened).map (·.path) == some path &&
              closed opened },
    { name :=
        "the ex name e with no argument asks for a path, with the open command's prompt, and starts nothing"
      run :=
        pure <|
          match exDriver Ex.bindings with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (exLine "e")
            asking.loop.state.prompt.map (fun asking => (asking.label, asking.continuation)) ==
                some (Files.openPrompt, { command := Files.openName }) &&
              asking.pending.isEmpty },
    { name :=
        "the ex name w after an edit starts a save, which is in flight until its job is finished: the file then holds the buffer's text, the buffer is not modified, and the echo area says the file was written"
      run :=
        pure <|
          match exNoteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let text := "x" ++ FileCases.noteText
            let (saving, _) := fedTo opened ([.commit "x"] ++ exLine "w")
            let (saved, _) := saving.finish 2
            (heldFile saving).bind (·.saving) != none && saving.pending.size == 1 &&
              (showing saving).map (·.buffer.isModified) == some true &&
              (showing saved).bind (·.text) == some text &&
              bytesOf saved path == some (FileModel.encode text) &&
              (showing saved).map (·.buffer.isModified) == some false &&
              echoOf saved == some (Files.wrote path) },
    { name :=
        "the ex name w with an argument says it takes none, by the ex line's message, and starts no save: the file is as it was and the buffer is still modified"
      run :=
        pure <|
          match exNoteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let (refused, _) := fedTo opened ([.commit "x"] ++ exLine "w other.txt")
            promptEcho refused == Ex.noArgument "w" && refused.pending.isEmpty &&
              (heldFile refused).bind (·.saving) == none &&
              bytesOf refused path == some FileCases.noteBytes &&
              statusOf refused == some (namedModified "note.txt") },
    { name :=
        "the ex name w in the scratch buffer says the buffer has no file, by the save command's message, and starts nothing"
      run :=
        pure <|
          match exDriver Ex.bindings with
          | none => false
          | some driver =>
            let (refused, _) := fedTo driver (exLine "w")
            promptEcho refused == Files.noFile "scratch" && refused.pending.isEmpty &&
              closed refused },
    { name :=
        "the ex name q in an editor with nothing modified stops the driver; and so does q after text was typed in the scratch buffer alone, which holds no file"
      run :=
        pure <|
          match exDriver Ex.bindings with
          | none => false
          | some driver =>
            let (fresh, _) := fedTo driver (exLine "q")
            let (typed, _) := fedTo driver ([.commit "typed"] ++ exLine "q")
            !driver.stopped && fresh.stopped && typed.stopped && driverText typed == some "typed" },
    { name :=
        "the ex name q while a file's buffer is modified says the quit command's refusal, with the buffer's name, and the editor goes on: the driver has not stopped and the next key's command runs"
      run :=
        pure <|
          match exNoteOpen with
          | none => false
          | some opened =>
            let (refused, _) := fedTo opened ([.commit "x"] ++ exLine "q")
            let (after, _) := fedTo refused (presses "C-e o")
            promptEcho refused == Ex.notQuitting (.unsaved "note.txt") && !refused.stopped &&
              !refused.loop.state.quitting &&
              closed refused &&
              promptEcho after == "other" },
    { name :=
        "criterion 1 on the models: w and then q with the save not yet finished does not stop the driver until the save is finished, and then the file holds the buffer's text"
      run :=
        pure <|
          match exNoteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let text := "x" ++ FileCases.noteText
            let (asked, _) := fedTo opened ([.commit "x"] ++ exLine "w" ++ exLine "q")
            let (left, _) := asked.finish 2
            asked.pending.size == 1 && !asked.stopped && asked.loop.state.quitting &&
              promptEcho asked == "" &&
              left.stopped &&
              bytesOf left path == some (FileModel.encode text) &&
              (showing left).map (·.buffer.isModified) == some false },
    { name := "the ex name q with an argument says it takes none and does not stop the driver"
      run :=
        pure <|
          match exDriver Ex.bindings with
          | none => false
          | some driver =>
            let (refused, _) := fedTo driver (exLine "q now")
            promptEcho refused == Ex.noArgument "q" && !refused.stopped &&
              !refused.loop.state.quitting },
    { name :=
        "criterion 2 on the models: the ex name wq on a modified buffer of a file starts the save and asks to quit: the driver has not stopped while the save is not finished, and once it is finished the file holds the buffer's text and the driver has stopped"
      run :=
        pure <|
          match exNoteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let text := "x" ++ FileCases.noteText
            let (asked, _) := fedTo opened ([.commit "x"] ++ exLine "wq")
            let (left, _) := asked.finish 2
            asked.pending.size == 1 && (heldFile asked).bind (·.saving) != none && !asked.stopped &&
              asked.loop.state.quitting &&
              left.stopped &&
              bytesOf left path == some (FileModel.encode text) &&
              (showing left).map (·.buffer.isModified) == some false },
    { name :=
        "the ex name wq on a buffer of a file that is not modified saves it all the same and stops the driver once the save is finished, with the file's bytes as they were"
      run :=
        pure <|
          match exNoteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let (asked, _) := fedTo opened (exLine "wq")
            let (left, _) := asked.finish 2
            asked.pending.size == 1 && !asked.stopped && left.stopped &&
              bytesOf left path == some FileCases.noteBytes &&
              stampOf left path != stampOf opened path },
    { name :=
        "the ex name w and then wq with the save not yet finished: the save command says the file is being saved and starts no second save, the quit is asked and waits for the one save, and the driver stops once it is finished, with the buffer's text in the file"
      run :=
        pure <|
          match exNoteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let text := "x" ++ FileCases.noteText
            let (asked, _) := fedTo opened ([.commit "x"] ++ exLine "w" ++ exLine "wq")
            let (left, _) := asked.finish 2
            asked.pending.size == 1 && !asked.stopped && asked.loop.state.quitting &&
              promptEcho asked == Files.beingSaved path &&
              left.stopped &&
              bytesOf left path == some (FileModel.encode text) &&
              (showing left).map (·.buffer.isModified) == some false },
    { name :=
        "the ex name w, an edit, and then wq with the save not yet finished: no second save is started and the quit is refused with the buffer's name, by the quit command's message, which is what the echo area says; the driver does not stop when the save is finished, the file holds the text from before the edit, and the buffer is still modified"
      run :=
        pure <|
          match exNoteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let (asked, _) :=
              fedTo opened ([.commit "x"] ++ exLine "w" ++ [.commit "y"] ++ exLine "wq")
            let (saved, _) := asked.finish 2
            asked.pending.size == 1 && !asked.stopped && !asked.loop.state.quitting &&
              promptEcho asked == Ex.notQuitting (.unsaved "note.txt") &&
              !saved.stopped &&
              !saved.loop.state.quitting &&
              bytesOf saved path == some (FileModel.encode ("x" ++ FileCases.noteText)) &&
              (showing saved).map (·.buffer.isModified) == some true },
    { name :=
        "the ex name wq in the scratch buffer says the buffer has no file, by the save command's message, starts nothing and does not ask to quit"
      run :=
        pure <|
          match exDriver Ex.bindings with
          | none => false
          | some driver =>
            let (refused, _) := fedTo driver ([.commit "typed"] ++ exLine "wq")
            promptEcho refused == Files.noFile "scratch" && refused.pending.isEmpty &&
              !refused.stopped &&
              !refused.loop.state.quitting },
    { name :=
        "the ex name wq with the file changed behind the editor: the save is refused, the echo area says so by the save command's message, the quit is withdrawn and the driver has not stopped; a later q is refused, the buffer being still modified"
      run :=
        pure <|
          match exNoteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let changed := rewritten opened path JobContract.otherFile
            let (asked, _) := fedTo changed ([.commit "x"] ++ exLine "wq")
            let (refused, _) := asked.finish 2
            let (later, _) := fedTo refused (exLine "q")
            asked.loop.state.quitting && !refused.stopped && !refused.loop.state.quitting &&
              echoOf refused == some (Files.notSaved path (.changed (stampOf changed path))) &&
              bytesOf refused path == some JobContract.otherFile &&
              promptEcho later == Ex.notQuitting (.unsaved "note.txt") &&
              !later.stopped },
    { name :=
        "the ex name wq on a buffer that is not modified, with the file changed behind the editor: the save is refused, the echo area says so by the save command's message, the quit is withdrawn and the driver has not stopped; and so with w and then q in place of wq"
      run :=
        pure <|
          match exNoteOpen with
          | none => false
          | some opened =>
            let path := inFiles "note.txt"
            let changed := rewritten opened path JobContract.otherFile
            [exLine "wq", exLine "w" ++ exLine "q"].all fun lines =>
              let (asked, _) := fedTo changed lines
              let (refused, _) := asked.finish 2
              asked.loop.state.quitting && !asked.stopped &&
                (showing asked).map (·.buffer.isModified) == some false &&
                !refused.stopped &&
                !refused.loop.state.quitting &&
                echoOf refused == some (Files.notSaved path (.changed (stampOf changed path))) &&
                bytesOf refused path == some JobContract.otherFile },
    { name :=
        "the ex name wq while another file's buffer has unsaved changes starts this buffer's save and is refused the quit, with the other buffer's name: the file is written and the driver has not stopped"
      run :=
        pure <|
          match exNoteOpen with
          | none => false
          | some opened =>
            let path := inFiles "crlf.txt"
            let (second, _) := fedTo opened ([.commit "x"] ++ exLine s!"e {path}")
            let (second, _) := second.finish 2
            let (asked, _) := fedTo second ([.commit "y"] ++ exLine "wq")
            let (saved, _) := asked.finish 3
            (showing second).map (·.buffer.name) == some "crlf.txt" &&
              promptEcho asked == Ex.notQuitting (.unsaved "note.txt") &&
              asked.pending.size == 1 &&
              !asked.loop.state.quitting &&
              !saved.stopped &&
              (bytesOf saved path).map (·.size) == some (mostlyCrlf.size + 1) &&
              echoOf saved == some (Files.wrote path) &&
              bytesOf saved (inFiles "note.txt") == some FileCases.noteBytes },
    { name :=
        "the ex name reload asks for the config to be reloaded: the driver counts one reload, and two once the line is typed twice; with an argument it says it takes none and asks for none"
      run :=
        pure <|
          match exDriver Ex.bindings with
          | none => false
          | some driver =>
            let (once, _) := fedTo driver (exLine "reload")
            let (twice, _) := fedTo once (exLine "reload")
            let (refused, _) := fedTo driver (exLine "reload now")
            driver.reloads == 0 && once.reloads == 1 && twice.reloads == 2 && closed twice &&
              !twice.stopped &&
              promptEcho once == "" &&
              promptEcho refused == Ex.noArgument "reload" &&
              refused.reloads == 0 }]

/-- Texts of the resting rule's checks, each with every position it has, in
order, and where each rests under `onCell` and under `offLineBreak`,
written out by hand: the empty text; one line feed; a line with no line
break; a line and its line feed; two lines around an empty one; a carriage
return and line feed, with the position between the two; and a character
of four bytes. -/
def restings : List (String × List Nat × List Nat × List Nat) :=
  [("", [0], [0], [0]), ("\n", [0, 1], [0, 0], [0, 0]), ("ab", [0, 1, 2], [0, 1, 1], [0, 1, 1]),
    ("ab\n", [0, 1, 2, 3], [0, 1, 2, 2], [0, 1, 1, 1]),
    ("ab\n\ncd", [0, 1, 2, 3, 4, 5, 6], [0, 1, 2, 3, 4, 5, 5], [0, 1, 1, 3, 4, 5, 5]),
    ("ab\r\ncd", [0, 1, 2, 3, 4, 5, 6], [0, 1, 2, 2, 4, 5, 5], [0, 1, 1, 1, 4, 5, 5]),
    ("a😀", [0, 1, 5], [0, 1, 1], [0, 1, 1])]

/-- Where each of `offsets` rests in a text holding `contents` under the
rule `rest` (`Evil.rested`), on the text model; none when one was
refused. -/
def restedIn (rest : Evil.Rest) (contents : String) (offsets : List Nat) : Option (List Nat) :=
  onTextModel do
    let text ← createText contents
    offsets.mapM (Evil.rested rest text)

/-- The checks of where a cursor rests in a state (`Editor/Evil.lean`), on
the text model, from every position of a few small texts. -/
def evilRestChecks : List Check :=
  [{  name :=
        "where a cursor may rest anywhere, every position rests where it is, the text's end among them"
      run :=
        pure
          (restings.all fun (contents, positions, _, _) =>
            restedIn .anywhere contents positions == some positions) },
    { name :=
        "where a cursor rests on a cell, every position rests where it is, a line break among them, but for the text's end, which rests at the start of the last cell, and the position inside a carriage return and line feed, which rests at the carriage return"
      run :=
        pure
          (restings.all fun (contents, positions, onCell, _) =>
            restedIn .onCell contents positions == some onCell) },
    { name :=
        "where a cursor rests off the line break, it rests as on a cell, and one cell back from the line break of a row that has content; the line break of an empty line is kept, and the text's end after a final line feed rests on the last character of the row before"
      run :=
        pure
          (restings.all fun (contents, positions, _, offLineBreak) =>
            restedIn .offLineBreak contents positions == some offLineBreak) },
    { name := "in the empty text every rule rests a cursor at 0"
      run :=
        pure
          ([Evil.Rest.anywhere, .onCell, .offLineBreak].all fun rest =>
            restedIn rest "" [0] == some [0]) },
    { name :=
        "the resting rule of a view is read off what the scheme reports of it: anywhere for an exclusive selection, on a cell where a motion extends the selection, and off the line break otherwise"
      run :=
        pure
          (Evil.restOf { shape := .exclusive } == .anywhere &&
            Evil.restOf { shape := .exclusive, selecting := true } == .anywhere &&
            Evil.restOf { shape := .inclusive, selecting := true } == .onCell &&
            Evil.restOf { shape := .line, selecting := true } == .onCell &&
            Evil.restOf { shape := .inclusive } == .offLineBreak &&
            Evil.restOf { shape := .line } == .offLineBreak) }]

/-- A fixture of the evil checks, which writes the cursor into the text as
a bar: the text without the bar, and the bar's byte offset. A fixture with
no bar has its cursor at 0. -/
def barred (fixture : String) : String × Nat :=
  match fixture.splitOn "|" with
  | [before, after] => (before ++ after, before.utf8ByteSize)
  | _ => (fixture, 0)

/-- `contents` with a bar written before the character at the byte offset
`offset`, or at its end. An offset that is no character's start, and none
past the end, writes no bar, so a fixture's expectation does not match. -/
def withBar (contents : String) (offset : Nat) : String :=
  let (shown, walked) :=
    contents.foldl
      (fun (shown, walked) char =>
        ((if walked == offset then shown.push '|' else shown).push char, walked + char.utf8Size))
      ("", 0)
  if walked == offset then shown.push '|' else shown

/-- The loop the evil checks run: one over the Vim scheme that ships. -/
abbrev EvilLoop :=
  Loop Vim.Default.scheme

/-- The driver the evil checks run: one over the Vim scheme that ships. -/
abbrev EvilDriver :=
  Loop.Driver Vim.Default.scheme

/-- What a step of the evil checks is handed: no active keymaps, so that a
key is looked up in the keymaps of its view's Vim state alone, and the
commands compiled code registers for evil (`Evil.commands`) and those of
`more`, each under the name it is registered under, then `commands`. A
command of `more` runs in place of one of evil's of the same name, as the
registry's latest entry of a name does. -/
def evilHanded (more : Array Config.Registration := #[])
    (commands : List (String × Dispatched) := []) : Loop.Keys Vim.Default.scheme :=
  {
    command? := fun name =>
      match (Evil.commands ++ more).findRev? (·.name == name) with
      | some { action := .call run, .. } =>
        some fun call => do
          run call
          return none
      | _ => (commands.find? (·.1 == name)).map (·.2) }

/-- A state of the evil checks: one buffer, `scratch`, over a text made
holding `contents`, so that nothing is pending in its history, and one
window on it, focused, in a frame of 640 by 480, whose selection is one
cursor at the byte offset `head`, of the shape the Vim scheme that ships
reports of a view before any key. -/
def evilState (contents : String) (head : Nat) : TextM EditorState := do
  let text ← createText contents
  let scroll ← text.mark (.anchor { offset := 0, bias := .before })
  let shape := (Vim.Default.scheme.report Vim.Default.scheme.init ⟨0⟩).shape
  let selection ← text.mark (.selection { ranges := #[⟨head, head⟩], shape })
  let history ← UndoTree.over text
  return {
      buffers := #[some { name := "scratch", text, history }]
      windows := #[{ id := ⟨0⟩, buffer := ⟨0⟩, scroll, selection }]
      frame :=
        { size := ⟨640, 480⟩, tree := .split .rows (.window ⟨0⟩) .minibuffer, focused := ⟨0⟩ } }

/-- A driver of the evil checks over the state the fixture `fixture` says
(`evilState`), each step handed `handed`, with no job registered; `none` if
making the state was refused. -/
def evilDriver (fixture : String) (handed : Loop.Keys Vim.Default.scheme := evilHanded) :
    Option EvilDriver :=
  let (contents, head) := barred fixture
  (Loop.Driver.over handed (fun _ => none) (evilState contents head) editorModel).toOption

/-- `driver` fed a press of each key the key string `text` names, in
order. -/
def evilFed (driver : EvilDriver) (text : String) : EvilDriver :=
  (keys text).foldl (fun driver key => (driver.feed { event := press key, stamp := 0 }).1) driver

/-- The selection of the view `view` of `driver`, as the text model has
it. -/
def evilSelection (driver : EvilDriver) (view : ViewId := ⟨0⟩) : Option Selection := do
  let target ← driver.loop.state.target? view
  (target.selection.runModel driver.model.texts).1.toOption

/-- What the view `view` of `driver` shows, as a fixture writes it: its
buffer's text with a bar at the head of its selection's primary range. -/
def evilShown (driver : EvilDriver) (view : ViewId := ⟨0⟩) : String :=
  match driver.loop.state.target? view, evilSelection driver view with
  | some target, some selection =>
    match (driver.model.texts.texts[target.buffer.text.index]?).join,
      selection.ranges[selection.primary]? with
    | some content, some range => withBar content.contents range.head
    | _, _ => "no text"
  | _, _ => "no view"

/-- The keys the key string `typed` names, pressed under the Vim scheme that
ships with evil's commands, from the text and the cursor `fixture` says:
the text after them with a bar at the cursor, or what the echo area says
when a command said something. -/
def evilKeys (fixture typed : String) : String :=
  match evilDriver fixture with
  | none => "no driver"
  | some driver =>
    let driver := evilFed driver typed
    if driver.loop.state.echo.isEmpty then evilShown driver else driver.loop.state.echo

/-- Whether each row of `rows` holds: the keys of a row, pressed from its
first fixture, leave its second (`evilKeys`). A failure names each row that
does not hold, with what its keys left, and each row whose key string
names no keys. -/
def evilRows (rows : List (String × String × String)) : IO Bool := do
  let wrong :=
    rows.filterMap fun (typed, before, after) =>
      let got := evilKeys before typed
      -- A key string that is refused presses nothing, which a row that
      -- expects the text unchanged would not show.
      if (keys typed).isEmpty then some s!"{repr typed} names no keys"
      else if got == after then none else some s!"{typed} from {repr before} left {repr got}"
  unless wrong.isEmpty do
    throw (IO.userError ("; ".intercalate wrong))
  return true

/-- Whether a cursor of normal state may rest at the byte offset `head` of
`contents`, said of the string alone: the text is empty and the offset 0;
or a cell starts there, which is a character's start that is not the line
feed of a carriage return and line feed, and that cell is not the line
break of a row that has content. -/
def restsWell (contents : String) (head : Nat) : Bool :=
  let chars := contents.toList
  let offsets :=
    (chars.foldl (fun (offsets, walked) char => (offsets ++ [walked], walked + char.utf8Size))
        ([], 0)).1
  let before := none :: chars.map some
  let after := (chars.drop 1).map some ++ [none]
  contents.isEmpty && head == 0 ||
    ((offsets.zip chars).zip (before.zip after)).any fun ((offset, char), (before, after)) =>
      offset == head && !(char == '\n' && before == some '\r') &&
        !((char == '\n' || char == '\r' && after == some '\n') && before.isSome &&
            before != some '\n')

/-- The texts every motion is swept over: those of the resting rule's
checks, and one with a run of punctuation beside a word, a run of blanks,
an empty line, a line that begins with a tab, and a last line with no line
feed. -/
def sweepTexts : List String :=
  restings.map (·.1) ++ ["foo.bar  x\n\n\tab\nend"]

/-- The counts every motion is swept with, as a move's invocation carries
one: 0, which is no count, a count of 1, a count inside most of the texts,
and one past every text. -/
def sweepCounts : List Nat :=
  [0, 1, 2, 99]

/-- Every motion of the vocabulary run by the move command, in normal
state, with each count of `sweepCounts`, from every position of a text
holding `contents` where a normal-state cursor may rest: for each, the
motion's name, the count, the position, and the selection the move left.
`none` when a move was refused. -/
def swept (contents : String) : Option (List (String × Nat × Nat × Selection)) :=
  let program : EditorM (List (String × Nat × Nat × Selection)) := do
    let mut moved := []
    for position in (List.range (contents.utf8ByteSize + 1)).filter (restsWell contents) do
      for motion in Evil.motions do
        for count in sweepCounts do
          let loop : EvilLoop := { state := ← evilState contents position }
          let stepped ←
            loop.invoke evilHanded
                { command := Vim.moveCommand, arguments := [.str motion.name, .nat count] }
          let some target := stepped.loop.state.focusedTarget? | throw .noSuchText
          moved := (motion.name, count, position, ← target.selection) :: moved
    return moved
  (program.runModel editorModel).1.toOption

/-- The rows of the oracle table for `h` and `l`
(`docs/design/keymaps-and-modes.md`, "Motions as built"): the keys, the
text before with the cursor as a bar, and the text after. -/
def leftRightRows : List (String × String × String) :=
  [("l", "a|bc", "ab|c"), ("l", "ab|c", "ab|c"), ("l", "ab|c\ndef", "ab|c\ndef"),
    ("1 l", "a|bc", "ab|c"), ("2 l", "|abcd", "ab|cd"), ("3 l", "|abcd", "abc|d"),
    ("5 l", "|abc", "ab|c"), ("l", "|\nabc", "|\nabc"), ("l", "a|b\r\ncd", "a|b\r\ncd"),
    ("h", "ab|c", "a|bc"), ("h", "|abc", "|abc"), ("h", "abc\n|def", "abc\n|def"),
    ("1 h", "ab|c", "a|bc"), ("2 h", "abc|d", "a|bcd"), ("2 h", "abc\nde|fg", "abc\n|defg"),
    ("5 h", "abc\nde|f", "abc\n|def"), ("l", "|", "|"), ("h", "|", "|"), ("l", "|\n", "|\n"),
    ("h", "|\n", "|\n")]

/-- The rows of the oracle table for `w`, `b` and `e`: a word beside a run
of punctuation, runs of blanks, an empty line, which stops `w` and `b` and
not `e`, a line of blanks only, leading blanks on the next line, the last
word with and without a final line feed, trailing blanks at the end, a
carriage return and line feed as the line break, counts inside and past the
text, the empty text and the text of one line feed, and one text with
letters outside ASCII that Vim and the editor both take for word
characters. -/
def wordRows : List (String × String × String) :=
  [("w", "foo |bar baz", "foo bar |baz"), ("1 w", "foo |bar baz", "foo bar |baz"),
    ("2 w", "|foo bar baz", "foo bar |baz"), ("w", "foo |bar", "foo ba|r"),
    ("w", "foo b|ar", "foo ba|r"), ("w", "foo ba|r", "foo ba|r"), ("w", "foo |bar\n", "foo ba|r\n"),
    ("w", "foo ba|r\n", "foo ba|r\n"), ("w", "|foo.bar  x", "foo|.bar  x"),
    ("3 w", "|foo.bar  x", "foo.bar  |x"), ("9 w", "|foo.bar  x", "foo.bar  |x"),
    ("9 w", "|ab cd ef", "ab cd e|f"), ("w", "|foo(bar)", "foo|(bar)"),
    ("w", "foo|(bar)", "foo(|bar)"), ("w", "foo(|bar)", "foo(bar|)"),
    ("3 w", "|foo(bar)", "foo(bar|)"), ("w", "|foo\n\nbar", "foo\n|\nbar"),
    ("w", "foo\n|\nbar", "foo\n\n|bar"), ("w", "|foo\n   \nbar", "foo\n   \n|bar"),
    ("w", "foo\n | \nbar", "foo\n  \n|bar"), ("2 w", "|ab cd\n  ef", "ab cd\n  |ef"),
    ("w", "a\n|\n", "a\n|\n"), ("w", "foo |bar\r\nbaz", "foo bar\r\n|baz"),
    ("w", "|héllo wörld", "héllo |wörld"), ("w", "|", "|"), ("w", "|\n", "|\n"),
    ("b", "foo b|ar", "foo |bar"), ("1 b", "foo b|ar", "foo |bar"), ("b", "foo |bar", "|foo bar"),
    ("b", "|foo bar", "|foo bar"), ("b", "foo\n\n|bar", "foo\n|\nbar"),
    ("b", "foo\n|\nbar", "|foo\n\nbar"), ("b", "foo\n   \n|bar", "|foo\n   \nbar"),
    ("b", "ab\n  |cd", "|ab\n  cd"), ("2 b", "foo.bar  |x", "foo|.bar  x"),
    ("9 b", "foo.bar  |x", "|foo.bar  x"), ("b", "foo(bar|)", "foo(|bar)"),
    ("b", "foo(|bar)", "foo|(bar)"), ("3 b", "foo(bar|)", "|foo(bar)"), ("b", "a\n|\n", "|a\n\n"),
    ("b", "foo\r\n|bar", "|foo\r\nbar"), ("b", "héllo w|örld", "héllo |wörld"), ("b", "|", "|"),
    ("b", "|\n", "|\n"), ("e", "|foo bar", "fo|o bar"), ("1 e", "|a b c d e", "a |b c d e"),
    ("e", "fo|o bar", "foo ba|r"), ("e", "foo ba|r", "foo ba|r"), ("e", "foo |bar\n", "foo ba|r\n"),
    ("e", "foo ba|r\n", "foo ba|r\n"), ("e", "fo|o\n\nbar", "foo\n\nba|r"),
    ("e", "fo|o\n   \nbar", "foo\n   \nba|r"), ("e", "a|b\n  cd", "ab\n  c|d"),
    ("e", "fo|o  ", "foo | "), ("e", "fo|o  \n", "foo | \n"),
    ("2 e", "|foo bar baz", "foo ba|r baz"), ("2 e", "|ab cd ef", "ab c|d ef"),
    ("3 e", "|a b c d e", "a b c |d e"), ("9 e", "|a b c d e", "a b c d |e"),
    ("9 e", "|ab cd ef", "ab cd e|f"), ("e", "|foo(bar)", "fo|o(bar)"),
    ("e", "fo|o(bar)", "foo|(bar)"), ("e", "foo|(bar)", "foo(ba|r)"), ("e", "a\n|\n", "a\n|\n"),
    ("e", "|héllo wörld", "héll|o wörld"), ("e", "|", "|"), ("e", "|\n", "|\n")]

/-- The rows of the oracle table for `W`, `B` and `E`, which go by runs of
characters that are not blank: with no count, with a count of 1, with a
count inside the text and with one past it, and on an empty line, which
stops `W` and `B` and not `E`. -/
def bigWordRows : List (String × String × String) :=
  [("W", "|foo.bar  x", "foo.bar  |x"), ("W", "|foo(bar) x", "foo(bar) |x"),
    ("W", "|a.b c.d e.f gh", "a.b |c.d e.f gh"), ("1 W", "|a.b c.d e.f gh", "a.b |c.d e.f gh"),
    ("2 W", "|a.b c.d e.f gh", "a.b c.d |e.f gh"), ("3 W", "|a.b c.d e.f gh", "a.b c.d e.f |gh"),
    ("9 W", "|a.b c.d e.f gh", "a.b c.d e.f g|h"),
    ("2 W", "|a.b c.d\n  e.f gh", "a.b c.d\n  |e.f gh"), ("W", "|foo\n\nbar", "foo\n|\nbar"),
    ("W", "|", "|"), ("W", "|\n", "|\n"), ("B", "foo.bar  |x", "|foo.bar  x"),
    ("B", "foo(bar) |x", "|foo(bar) x"), ("B", "a.b c.d e.f |gh", "a.b c.d |e.f gh"),
    ("1 B", "a.b c.d e.f |gh", "a.b c.d |e.f gh"), ("2 B", "a.b c.d e.f |gh", "a.b |c.d e.f gh"),
    ("2 B", "a.b c.d e.f g|h", "a.b c.d |e.f gh"), ("9 B", "a.b c.d e.f |gh", "|a.b c.d e.f gh"),
    ("B", "foo\n\n|bar", "foo\n|\nbar"), ("B", "|", "|"), ("B", "|\n", "|\n"),
    ("E", "|foo.bar  x", "foo.ba|r  x"), ("E", "|foo(bar) x", "foo(bar|) x"),
    ("E", "|a.b c.d e.f gh", "a.|b c.d e.f gh"), ("1 E", "|a.b c.d e.f gh", "a.|b c.d e.f gh"),
    ("2 E", "|a.b c.d e.f gh", "a.b c.|d e.f gh"), ("9 E", "|a.b c.d e.f gh", "a.b c.d e.f g|h"),
    ("9 E", "|a.b c.d e.f gh\n", "a.b c.d e.f g|h\n"), ("E", "fo|o\n\nbar", "foo\n\nba|r"),
    ("E", "|", "|"), ("E", "|\n", "|\n")]

/-- The rows of the oracle table for `0`, `^` and `$`: leading blanks, a
line of blanks only, an empty line, a count before `^`, which is ignored,
a `0` after a digit, which is part of a count, and for `$` a count, a count
past the last line, a count above 1 on the last line, which does not move,
an empty line as the start and as the target, a text that ends in a line
feed, and a carriage return and line feed as the line break. -/
def lineRows : List (String × String × String) :=
  [("0", "  a|bc", "|  abc"), ("0", "|abc", "|abc"), ("0", "abc\n  d|ef", "abc\n|  def"),
    ("0", "a\n|\nb", "a\n|\nb"), ("0", "ab\r\nc|d", "ab\r\n|cd"), ("0", "|", "|"),
    ("0", "|\n", "|\n"), ("1 0 l", "|abcdefghijklmno", "abcdefghij|klmno"),
    ("^", "  ab|c", "  |abc"), ("^", "|  abc", "  |abc"), ("3 ^", "  ab|c", "  |abc"),
    ("^", "|abc", "|abc"), ("^", "abc\n  de|f", "abc\n  |def"), ("^", "| \t ", " \t| "),
    ("^", "| \t \nx", " \t| \nx"), ("^", "a\n|\nb", "a\n|\nb"), ("^", "|", "|"),
    ("^", "|\n", "|\n"), ("$", "|abc\ndef", "ab|c\ndef"), ("$", "a|bc", "ab|c"),
    ("$", "ab|c", "ab|c"), ("1 $", "|abc\ndef\nghi", "ab|c\ndef\nghi"),
    ("2 $", "|abc\ndef\nghi", "abc\nde|f\nghi"), ("3 $", "|abc\ndef\nghi", "abc\ndef\ngh|i"),
    ("2 $", "|abc\ndef", "abc\nde|f"), ("5 $", "|abc\ndef\n", "abc\nde|f\n"),
    ("2 $", "abc\n|def", "abc\n|def"), ("2 $", "abc\nde|f\n", "abc\nde|f\n"),
    ("$", "|\nabc", "|\nabc"), ("2 $", "|abc\n\nghi", "abc\n|\nghi"),
    ("$", "a|b\r\ncd", "a|b\r\ncd"), ("2 $", "|ab\r\ncd", "ab\r\nc|d"), ("$", "|", "|"),
    ("$", "|\n", "|\n")]

/-- The rows of the oracle table for `j` and `k` with one key: one line,
a count of 1, a count inside the text, a count past the last line and the
first, the last line and the first line, a shorter line and an empty line
as the target, the last line of a text that ends in a line feed, a
carriage return and line feed as the line break, and characters of two
bytes before the cursor, where the column aimed for is the cursor's in
cells and its column in bytes is another. Those characters are one display
column wide, so Vim's column is the same. -/
def verticalRows : List (String × String × String) :=
  [("j", "abc|d\nx\nabcd", "abcd\n|x\nabcd"), ("k", "abcd\nx\nabc|d", "abcd\n|x\nabcd"),
    ("j", "hé|llo\nworld", "héllo\nwo|rld"), ("k", "abcdef\néö|x", "ab|cdef\néöx"),
    ("2 j", "é|bc\ndef\nghi", "ébc\ndef\ng|hi"),
    ("1 j", "a|b\ncd\nef\ngh\nij", "ab\nc|d\nef\ngh\nij"),
    ("2 j", "a|b\ncd\nef\ngh\nij", "ab\ncd\ne|f\ngh\nij"),
    ("3 j", "a|b\ncd\nef\ngh\nij", "ab\ncd\nef\ng|h\nij"),
    ("2 j", "a|b\ncd\nef\ngh\nij\n", "ab\ncd\ne|f\ngh\nij\n"),
    ("5 j", "abc|d\nx\nabcd", "abcd\nx\nabc|d"),
    ("1 k", "ab\ncd\nef\ng|h\nij", "ab\ncd\ne|f\ngh\nij"),
    ("2 k", "ab\ncd\nef\ng|h\nij", "ab\nc|d\nef\ngh\nij"),
    ("3 k", "ab\ncd\nef\ngh\ni|j", "ab\nc|d\nef\ngh\nij"),
    ("5 k", "abcd\nx\nabc|d", "abc|d\nx\nabcd"), ("j", "abcd\nx\nab|cd", "abcd\nx\nab|cd"),
    ("k", "ab|cd\nx", "ab|cd\nx"), ("j", "ab|cd\nxyz\n", "abcd\nxy|z\n"),
    ("j", "abcd\nxy|z\n", "abcd\nxy|z\n"), ("j", "ab|cd\n\nabcd", "abcd\n|\nabcd"),
    ("j", "abcd\n|\nabcd", "abcd\n\n|abcd"), ("k", "ab\r\n|cd", "|ab\r\ncd"),
    ("j", "a|b\r\ncd", "ab\r\nc|d"), ("j", "|", "|"), ("k", "|", "|"), ("j", "|\n", "|\n"),
    ("k", "|\n", "|\n")]

/-- The rows of the oracle table for the wanted column, each a sequence of
keys: `j` and `k` return to the column they started in across a shorter
line and across an empty one; a count aims for the same column; an `h`, an
`l`, a `j` or a `k` that cannot move keeps the column; a horizontal motion
that moves, and `0`, `^`, `w` and `e` whether they move or not, keep none,
so the next vertical motion aims for the cursor's own column; `$` keeps
the line's end, also when it does not move; and the column kept from a
cursor with a character of two bytes before it is its column in cells. -/
def wantedRows : List (String × String × String) :=
  [("j k", "abc|d\nx\nabcd", "abc|d\nx\nabcd"), ("j j", "abc|d\nx\nabcd", "abcd\nx\nabc|d"),
    ("j k", "hé|llo\nx\nhéllo", "hé|llo\nx\nhéllo"),
    ("j j", "hé|llo\nx\nworld", "héllo\nx\nwo|rld"), ("j j", "abc|d\n\nabcd", "abcd\n\nabc|d"),
    ("j j", "ab|cd\nxyz\n", "abcd\nxy|z\n"),
    ("2 j 2 j", "ab|cd\nx\nabcd\ny\nabcd", "abcd\nx\nabcd\ny\nab|cd"),
    ("j 2 j", "ab|cd\nx\nabcd\ny\nabcd", "abcd\nx\nabcd\n|y\nabcd"),
    ("j 3 j", "ab|cd\nx\nabcd\ny\nabcd", "abcd\nx\nabcd\ny\nab|cd"),
    ("k 2 k", "abcd\nx\nabcd\ny\nab|cd", "abcd\n|x\nabcd\ny\nabcd"),
    ("k 3 k", "abcd\nx\nabcd\ny\nab|cd", "ab|cd\nx\nabcd\ny\nabcd"),
    ("j h j", "abc|d\nx\nabcd", "abcd\nx\nabc|d"), ("j l j", "abc|d\nx\nabcd", "abcd\nx\nabc|d"),
    ("k j", "abc|d\nx\nabcd", "abcd\n|x\nabcd"), ("j h j", "abc|d\nxy\nabcd", "abcd\nxy\n|abcd"),
    ("j 0 j", "abc|d\n\nabcd", "abcd\n\n|abcd"), ("j ^ k", "abc|d\nx\nabcd", "|abcd\nx\nabcd"),
    ("j w j", "abc|d\nx\nabcd\nabcd", "abcd\nx\nabcd\n|abcd"),
    ("j e k", "abc|d\nx\nabcd", "abcd\n|x\nabcd"),
    ("$ j j", "|abc\nde\nabcdef", "abc\nde\nabcde|f"),
    ("$ j j k", "|abc\nde\nabcdef", "abc\nd|e\nabcdef"), ("2 $ k", "abc\n|def", "ab|c\ndef")]

/-- The rows of the oracle table for `g g` and `G`: no count, a count as
the line's number, from 1, a number past the last line, a text that ends
in a line feed, whose last line is the line before its end, leading
blanks, an empty line and a line of blanks only as the target, a text of
one line, and that neither keeps a wanted column. -/
def toLineRows : List (String × String × String) :=
  [("G", "a|bcd\n  xyz\n", "abcd\n  |xyz\n"), ("G", "a\nb\n  c|c\nd\n", "a\nb\n  cc\n|d\n"),
    ("G", "ab|c", "|abc"), ("1 G", "a\nb\n  c|c\nd", "|a\nb\n  cc\nd"),
    ("2 G", "a\nb\n  c|c\nd", "a\n|b\n  cc\nd"), ("9 9 G", "a\nb\n  c|c\nd", "a\nb\n  cc\n|d"),
    ("4 G", "a|b\ncd", "ab\n|cd"), ("2 G", "ab\n\n|cd", "ab\n|\ncd"),
    ("2 G", "ab\n   \n|cd", "ab\n  | \ncd"), ("G", "a|b\r\n  cd", "ab\r\n  |cd"), ("G", "|", "|"),
    ("G", "|\n", "|\n"), ("g g", "abcd\n  x|yz", "|abcd\n  xyz"), ("g g", "  a|b\ncd", "  |ab\ncd"),
    ("g g", "ab|c", "|abc"), ("1 g g", "a\nb\n  c|c\nd", "|a\nb\n  cc\nd"),
    ("3 g g", "a\nb\n  c|c\nd", "a\nb\n  |cc\nd"), ("9 9 g g", "a\nb\n  c|c\nd", "a\nb\n  cc\n|d"),
    ("9 9 g g", "a\nb\n  c|c\nd\n", "a\nb\n  cc\n|d\n"), ("g g", "|", "|"), ("g g", "|\n", "|\n"),
    ("j G k k", "abc|d\nx\nabcd", "|abcd\nx\nabcd")]

/-- Rows for every motion key from an empty line between two lines: where
Vim's motion puts the cursor, which for the motions along the line is
where it is. -/
def emptyLineRows : List (String × String × String) :=
  let here := "ab\n|\ncd"
  [("h", here, here), ("2 h", here, here), ("l", here, here), ("2 l", here, here),
    ("j", here, "ab\n\n|cd"), ("2 j", here, "ab\n\n|cd"), ("k", here, "|ab\n\ncd"),
    ("2 k", here, "|ab\n\ncd"), ("w", here, "ab\n\n|cd"), ("b", here, "|ab\n\ncd"),
    ("e", here, "ab\n\nc|d"), ("W", here, "ab\n\n|cd"), ("B", here, "|ab\n\ncd"),
    ("E", here, "ab\n\nc|d"), ("0", here, here), ("^", here, here), ("$", here, here),
    ("2 $", here, "ab\n\nc|d"), ("g g", here, "|ab\n\ncd"), ("G", here, "ab\n\n|cd")]

/-- Rows for every motion key from the last character of a text that ends
`ending`, which is nothing or a line feed: a motion that would leave the
text does not move, with a count as with none, and the cursor is never past
the last character. -/
def lastCharacterRows (ending : String) : List (String × String × String) :=
  let here := "ab\nc|d" ++ ending
  let lineStart := "ab\n|cd" ++ ending
  [("h", here, lineStart), ("l", here, here), ("3 l", here, here), ("j", here, here),
    ("3 j", here, here), ("k", here, "a|b\ncd" ++ ending), ("w", here, here), ("3 w", here, here),
    ("b", here, lineStart), ("e", here, here), ("3 e", here, here), ("W", here, here),
    ("3 W", here, here), ("B", here, lineStart), ("E", here, here), ("3 E", here, here),
    ("0", here, lineStart), ("^", here, lineStart), ("$", here, here), ("3 $", here, here),
    ("g g", here, "|ab\ncd" ++ ending), ("G", here, lineStart)]

/-- The move command called with `arguments`, as an invocation no key
yielded, under the Vim scheme that ships with evil's commands, from the
text and the cursor `fixture` says: the text after it with a bar at the
cursor, and what the echo area says. `none` if there is no driver. -/
def evilMoved (fixture : String) (arguments : List Argument) : Option (String × String) :=
  (evilDriver fixture).map fun driver =>
    let (moved, _) :=
      driver.stepped (driver.loop.invoke driver.handed { command := Vim.moveCommand, arguments })
    (evilShown moved, moved.loop.state.echo)

/-- The checks of evil's motions (`Editor/Evil.lean`, `Editor/Evil/Motions.lean`)
on the loop's driver over the editor's models, under the Vim scheme that
ships with the commands compiled code registers for evil: a motion's key
is pressed in a text with the cursor written into it, and each expected
text is written by hand from Vim's documented behaviour, case by case. -/
def evilMotionChecks : List Check :=
  [{  name :=
        "h and l move by cells and stay on the line: with no count one cell, with a count that many, as far as the line allows; neither leaves an empty line, the empty text or the line of a text that is one line feed, and l does not go onto the line break"
      run := evilRows leftRightRows },
    { name :=
        "w goes to the start of the next word, b to the start of the word before and e to the end of the next, a word being a run of word characters or a run of punctuation: each with a count repeats, and one past the text goes as far as there is a word; an empty line stops w and b and not e; where there is no word further on, w and e rest on the last character"
      run := evilRows wordRows },
    { name :=
        "W, B and E go as w, b and e do, by runs of characters that are not blank: with no count, with a count of 1, with a count inside the text, and with one past it, which goes as far as there is such a run"
      run := evilRows bigWordRows },
    { name :=
        "0 goes to the line's start and ^ to its first character that is not a blank, each whatever count was typed, and on a line of blanks only ^ rests on the last blank; $ goes to the last character of the line, or with a count of the line that many lines less one below, of the last line when the text has fewer, and does not move from the last line with a count above 1; none leaves an empty line"
      run := evilRows lineRows },
    { name :=
        "j and k go one line down and up by lines of the text, or with a count that many, and stop at the last line and at the first; on a shorter line the cursor is on its last character, and on an empty line on its line break; the last line of a text that ends in a line feed is the line before its end; the column they aim for is the cursor's counted in cells, not in bytes, so a character of two bytes before the cursor is one column"
      run := evilRows verticalRows },
    { name :=
        "j and k keep the column they aim for: j then k across a shorter line returns to the column it started in, and so does j twice across an empty line; an h or an l that cannot move keeps it, a motion along the line that moves keeps none, and after $ they stay at line ends; the column kept is counted in cells, not in bytes, so with a character of two bytes before the cursor j then k still returns to it"
      run := evilRows wantedRows },
    { name :=
        "gg goes to the first line and G to the last, or with a count each to the line of that number, the last line when the text has fewer, and to that line's first character that is not a blank; the last line of a text that ends in a line feed is the line before its end; neither keeps a wanted column"
      run := evilRows toLineRows },
    { name :=
        "from an empty line every motion key leaves the cursor where Vim's does: h, l, 0, ^ and $ where it is, the others on the line they lead to"
      run := evilRows emptyLineRows },
    { name :=
        "from the last character of the text, with a final line feed and with none, every motion key leaves the cursor where Vim's does, with a count as with none: a motion that would leave the text does not move, and the cursor is never past the last character"
      run := evilRows (lastCharacterRows "" ++ lastCharacterRows "\n") },
    { name :=
        "every key the default tables bind to a motion has a motion of its name in the vocabulary: pressed in a text of three lines, none says anything in the echo area"
      run := do
        let said :=
          Vim.Default.motions.filterMap fun (typed, _) =>
            match evilDriver "ab cd\ne|f gh\nij kl" with
            | none => some s!"{typed}: no driver"
            | some driver =>
              let echo := (evilFed driver typed).loop.state.echo
              if echo.isEmpty then none else some s!"{typed} said {repr echo}"
        unless said.isEmpty do
          throw (IO.userError ("; ".intercalate said))
        return !Vim.Default.motions.isEmpty },
    { name :=
        "after j the window keeps the column the cursor started in, with the offset the cursor rests at; after $ it keeps the line's end; after w it keeps none"
      run :=
        pure <|
          match evilDriver "abc|d\nx\nabcd" with
          | none => false
          | some driver =>
            let wanted (driver : EvilDriver) : Option (Option Window.Wanted) :=
              (driver.loop.state.window? ⟨0⟩).map (·.wanted)
            let down := evilFed driver "j"
            let ended := evilFed down "j $"
            wanted driver == some none &&
              wanted down == some (some { column := .cells 3, head := 5 }) &&
              evilShown down == "abcd\n|x\nabcd" &&
              wanted ended == some (some { column := .lineEnd, head := 10 }) &&
              evilShown ended == "abcd\nx\nabc|d" &&
              wanted (evilFed down "w") == some none },
    { name :=
        "a kept column holds only while the cursor is where it was kept: once a command written here has placed the cursor elsewhere, the next j aims for the cursor's own column"
      run :=
        pure <|
          let place : Dispatched := fun call => do
            call.target.select { ranges := #[⟨5, 5⟩], shape := .inclusive }
            return none
          match evilDriver "abc|d\nxyz\nabcd" (evilHanded (commands := [("place", place)])) with
          | none => false
          | some driver =>
            let down := evilFed driver "j"
            let (placed, _) := down.stepped (down.loop.runNamed down.handed "place")
            evilShown down == "abcd\nxy|z\nabcd" &&
              evilShown (evilFed down "j") == "abcd\nxyz\nabc|d" &&
              evilShown placed == "abcd\n|xyz\nabcd" &&
              (placed.loop.state.window? ⟨0⟩).map (·.wanted) ==
                some (some { column := .cells 3, head := 7 }) &&
              evilShown (evilFed placed "j") == "abcd\nxyz\n|abcd" },
    { name :=
        "the move command reads the column the window keeps when it is called, not the one the window kept when its command was called, so a command written here that calls it twice with one call moves as two keys do: down and then down across a shorter line lands in the column it started in, and the window then keeps what it keeps after j and j; down and then up returns to where it started; and neither says anything"
      run := do
        let fixture := "abc|d\nx\nabcd"
        let moving (names : List String) : Dispatched := fun call => do
          for name in names do
            Evil.move Evil.motions { call with arguments := [.str name] }
          return none
        let handed :=
          evilHanded (commands :=
            [("down-down", moving [Evil.down.name, Evil.down.name]),
              ("down-up", moving [Evil.down.name, Evil.up.name])])
        let some driver := evilDriver fixture handed | throw (IO.userError "no driver")
        let ran (name : String) : EvilDriver :=
          (driver.stepped (driver.loop.runNamed driver.handed name)).1
        let wanted (driver : EvilDriver) : Option (Option Window.Wanted) :=
          (driver.loop.state.window? ⟨0⟩).map (·.wanted)
        let twice := ran "down-down"
        let back := ran "down-up"
        let keyed := evilFed driver "j j"
        unless evilShown twice == "abcd\nx\nabc|d" && evilShown back == fixture do
          throw
              (IO.userError
                s!"down and down left {repr (evilShown twice)}, down and up {repr (evilShown back)}")
        return evilShown keyed == evilShown twice && wanted twice == wanted keyed &&
            wanted twice == some (some { column := .cells 3, head := 10 }) &&
            twice.loop.state.echo.isEmpty &&
            back.loop.state.echo.isEmpty },
    { name :=
        "a departure from Vim, recorded in keymaps-and-modes.md under The wanted column: the column j and k aim for counts cells, and Vim's counts display columns, so from the character after a tab j lands two cells in, where Vim's lands at the tab stop's column"
      run := evilRows [("j", "a\t|b\n0123456789", "a\tb\n01|23456789")] },
    { name :=
        "a move by a name the vocabulary has no motion of says so in the echo area, the name and then no such motion, and leaves the cursor where it was"
      run :=
        pure <|
          match evilDriver "a|bc" with
          | none => false
          | some driver =>
            let (driver, _) :=
              driver.stepped
                (driver.loop.invoke driver.handed
                  { command := Vim.moveCommand, arguments := [.str "nowhere", .nat 0] })
            driver.loop.state.echo == "nowhere: no such motion" && evilShown driver == "a|bc" },
    { name :=
        "the move command run by its name, which hands it no argument, says that no motion was named and what it expects, which is not what it says of a name the vocabulary has no motion of, and leaves the cursor where it was"
      run := do
        let some driver := evilDriver "a|bc" | throw (IO.userError "no driver")
        let (ran, _) := driver.stepped (driver.loop.runNamed driver.handed Vim.moveCommand)
        let echo := ran.loop.state.echo
        unless echo == "move: no motion named (expects a motion's name, then an optional count)" do
          throw (IO.userError s!"the echo area says {repr echo}")
        return echo != Evil.noSuchMotion "" && evilShown ran == "a|bc" },
    { name :=
        "the move command called with a motion's name and no count after it moves with no count: every motion of the vocabulary, from the middle of a text of three lines, leaves the cursor where it leaves it when the count is 0, which is how a key with no count calls it, and says nothing; by the name of the motion one cell on it goes where l does"
      run := do
        let here := "ab cd\ne|f gh\nij kl"
        let wrong :=
          Evil.motions.toList.filterMap fun motion =>
            let alone := evilMoved here [.str motion.name]
            let counted := evilMoved here [.str motion.name, .nat 0]
            if alone.isSome && alone == counted && alone.map (·.2) == some "" then none
            else some s!"{motion.name} alone left {repr alone}, and with the count 0 {repr counted}"
        unless wrong.isEmpty do
          throw (IO.userError ("; ".intercalate wrong))
        return !Evil.motions.isEmpty &&
            evilMoved "a|bc" [.str Evil.right.name] == some ("ab|c", "") &&
            evilKeys "a|bc" "l" == "ab|c" },
    { name :=
        "the move command called with a first argument that is not a string says that no motion was named, as it does handed no argument, and leaves the cursor where it was: a number alone, and a number before a motion's name, which is not read as the name"
      run :=
        pure <|
          !Evil.noMotionNamed.isEmpty &&
            evilMoved "a|bc" [.nat 1] == some ("a|bc", Evil.noMotionNamed) &&
            evilMoved "a|bc" [.nat 1, .str Evil.right.name] == some ("a|bc", Evil.noMotionNamed) &&
            evilMoved "a|bc" [] == some ("a|bc", Evil.noMotionNamed) },
    { name :=
        "a motion is no step of the history: after it the buffer's tree has no node more and nothing pending, and the buffer is not modified"
      run :=
        pure <|
          match evilDriver "a|bc" with
          | none => false
          | some driver =>
            let moved := evilFed driver "l"
            let seen (driver : EvilDriver) : Option (Nat × Bool × Bool) :=
              (driver.loop.state.buffer? ⟨0⟩).map fun buffer =>
                (buffer.history.nodes.size, buffer.history.pending, buffer.isModified)
            evilShown moved == "ab|c" && seen moved == some (1, false, false) &&
              seen driver == some (1, false, false) },
    { name :=
        "after every motion of the vocabulary, in normal state, from every position a cursor may rest at in each sample text, with no count and with counts of 1, 2 and 99, the selection is one cursor of normal state's shape, on a cell inside the text, or at 0 in the empty text, and never on the line break of a line that has content"
      run := do
        let mut wrong := #[]
        for contents in sweepTexts do
          let some moved :=
            swept contents | throw (IO.userError s!"a move was refused in {repr contents}")
          if moved.isEmpty then
            throw (IO.userError s!"nothing was swept in {repr contents}")
          for (name, count, position, selection) in moved do
            let rests : Bool :=
              match selection.ranges with
              | #[range] =>
                range.anchor == range.head && selection.shape == .inclusive &&
                  restsWell contents range.head
              | _ => false
            unless rests do
              wrong :=
                wrong.push
                  s!"{name} with {count} from {position} of {repr contents}: {repr selection}"
        unless wrong.isEmpty do
          throw (IO.userError ("; ".intercalate wrong.toList))
        return !Evil.motions.isEmpty }]

/-- What a scene shows of one view, as the evil checks read it. -/
structure EvilSeen where
  /-- The selection the view's one selection marker holds. -/
  selection : Selection
  /-- The text each range of that selection covers, by its shape. -/
  covered : Array String
  /-- How the view's cursors are drawn. -/
  cursor : Cursor
  /-- The view's status line. -/
  status : Array StatusField
  deriving DecidableEq, Repr

/-- What the last scene `driver`'s display recorded shows of the view
`view`: the selection its selection marker holds in the text model, what
that selection covers, the view's cursor and its status line. `none` when
no scene has the view, or it does not name one selection marker. -/
def evilSeen (driver : EvilDriver) (view : ViewId := ⟨0⟩) : Option EvilSeen := do
  let scene ← driver.model.display.scenes.back?
  let shown ← scene.views.find? (·.id == view)
  let #[marker] := shown.selections | none
  let program : TextM (Selection × Array String) := do
    let .selection selection ← marker.text.marker marker | throw .noSuchMarker
    let extents ← marker.text.extents selection
    return (selection, ← extents.mapM fun extent => marker.text.slice extent.start extent.stop)
  let (selection, covered) ← (program.runModel driver.model.texts).1.toOption
  return { selection, covered, cursor := shown.cursor, status := shown.status }

/-- What the scene after the keys `typed`, pressed from the fixture
`fixture`, shows of view 0 (`evilSeen`). -/
def evilScene (fixture typed : String) : Option EvilSeen :=
  (evilDriver fixture).bind fun driver => evilSeen (evilFed driver typed)

/-- The selection the scene shows after the keys `typed`, pressed from the
fixture `fixture`: its ranges, as an anchor and a head each, its shape,
and the text each range covers. -/
def evilSelected (fixture typed : String) : Option (List (Nat × Nat) × Shape × List String) :=
  (evilScene fixture typed).map fun seen =>
    ((seen.selection.ranges.map fun range => (range.anchor, range.head)).toList,
      seen.selection.shape, seen.covered.toList)

/-- The cursor and the status line a scene shows of a view of the buffer
`scratch`, not modified, in the Vim state view 0 is in after the keys
`typed` under the grammar alone: what the default scheme reports of that
state, and then the buffer's name. -/
def evilLooks (typed : String) : Cursor × Array StatusField :=
  let report := vimDefaultReport typed
  (report.cursor, report.status ++ #[{ text := "scratch", face := Loop.nameFace }])

/-- What the scheme reports of a view in a state that keeps both ends of
the selection, of the shape `shape`, written by hand: what a visual state
reports, as far as entering a state reads a report. -/
def evilKeeping (shape : Shape) : InputScheme.Report :=
  { shape, selecting := true }

/-- The selection the scene shows once the command that enters a Vim state
(`Evil.enter`) has been called with the report `report`, written by hand,
on a selection written by hand: one range from `anchor` to `head`, of the
shape `was`, in a text holding `contents`. Its ranges, as an anchor and a
head each, its shape, and the text each range covers. A command the loop
is handed places the selection and calls `Evil.enter`, since no key of the
default tables enters a state that keeps both ends from an insert session,
or with an anchor that is not on a cell; a state config registers may. -/
def evilEntered (contents : String) (was : Shape) (anchor head : Nat)
    (report : InputScheme.Report) : Option (List (Nat × Nat) × Shape × List String) := do
  let enter : Dispatched := fun call => do
    call.target.select { ranges := #[⟨anchor, head⟩], shape := was }
    Evil.enter { call with report }
    return none
  let driver ← evilDriver contents (evilHanded (commands := [("enter", enter)]))
  let (entered, _) := driver.stepped (driver.loop.runNamed driver.handed "enter")
  let seen ← evilSeen entered
  return ((seen.selection.ranges.map fun range => (range.anchor, range.head)).toList,
      seen.selection.shape, seen.covered.toList)

/-- The checks of evil's states (`Editor/Evil.lean`) on the loop's driver
over the editor's models, under the Vim scheme that ships with evil's
commands: what entering a visual state and leaving one does to the view's
selection, read from the selection marker the scene names, and what the
scene then shows of the state; and, by the entering command called with a
report written by hand, a state that keeps both ends entered from an
exclusive selection. -/
def evilStateChecks : List Check :=
  [{  name :=
        "v and then a motion: the scene shows one inclusive selection from the cell the cursor started on to the cell the motion leads to, which covers both cells and what is between them"
      run :=
        pure
          (evilSelected "foo |bar baz" "v w" == some ([(4, 8)], .inclusive, ["bar b"]) &&
            evilSelected "foo |bar baz" "v" == some ([(4, 4)], .inclusive, ["b"]) &&
            evilSelected "foo |bar baz" "v 2 l" == some ([(4, 6)], .inclusive, ["bar"])) },
    { name :=
        "v and then a motion backwards: the anchor stays on the cell the cursor started on and the head is before it, and the selection covers from the head through the anchor's cell"
      run :=
        pure
          (evilSelected "foo |bar baz" "v b" == some ([(4, 0)], .inclusive, ["foo b"]) &&
            evilSelected "foo b|ar baz" "v h h" == some ([(5, 3)], .inclusive, [" ba"])) },
    { name :=
        "V and then a motion: the scene shows one line-shaped selection whose two ends are the cells the cursor started on and came to, which covers every line from the starting line to the target line, each with its line break"
      run :=
        pure
          (evilSelected "ab|cd\nefgh\nijkl" "V j" == some ([(2, 7)], .line, ["abcd\nefgh\n"]) &&
            evilSelected "ab|cd\nefgh\nijkl" "V" == some ([(2, 2)], .line, ["abcd\n"]) &&
            evilSelected "abcd\nefgh\nij|kl" "V k k" ==
              some ([(12, 2)], .line, ["abcd\nefgh\nijkl"]) &&
            evilSelected "ab|cd\nefgh\nijkl" "V 2 j w" ==
              some ([(2, 13)], .line, ["abcd\nefgh\nijkl"])) },
    { name :=
        "in a visual state the head may rest on a line break: v then $ puts it there and the selection covers the line break, and so do l from a line's last character and j onto a shorter line"
      run :=
        pure
          (evilSelected "a|bc\ndef" "v $" == some ([(1, 3)], .inclusive, ["bc\n"]) &&
            evilSelected "ab|c\ndef" "v l" == some ([(2, 3)], .inclusive, ["c\n"]) &&
            evilSelected "abc|d\nx\nabcd" "v j" == some ([(3, 6)], .inclusive, ["d\nx\n"]) &&
            evilSelected "foo |bar\n" "v w" == some ([(4, 7)], .inclusive, ["bar\n"])) },
    { name :=
        "<Escape> from a visual state leaves one inclusive selection with equal ends on the head, which then rests as normal state's cursor does: off the line break after v and $"
      run :=
        pure
          (evilSelected "foo |bar baz" "v w <Escape>" == some ([(8, 8)], .inclusive, ["b"]) &&
            evilSelected "foo |bar baz" "v b <Escape>" == some ([(0, 0)], .inclusive, ["f"]) &&
            evilSelected "ab|cd\nefgh\nijkl" "V j <Escape>" == some ([(7, 7)], .inclusive, ["g"]) &&
            evilSelected "a|bc\ndef" "v $ <Escape>" == some ([(2, 2)], .inclusive, ["c"]) &&
            evilKeys "a|bc\ndef" "v $ <Escape>" == "ab|c\ndef" &&
            evilKeys "abc|d\nx\nabcd" "v j <Escape>" == "abcd\n|x\nabcd") },
    { name :=
        "V in the state v enters and v in the state V enters change the selection's shape and keep both its ends; v typed again in the state it enters, and V in its own, leave the selection as <Escape> does"
      run :=
        pure
          (evilSelected "foo |bar baz" "v w V" == some ([(4, 8)], .line, ["foo bar baz"]) &&
            evilSelected "foo |bar baz" "V w v" == some ([(4, 8)], .inclusive, ["bar b"]) &&
            evilSelected "foo |bar baz" "v w v" == some ([(8, 8)], .inclusive, ["b"]) &&
            evilSelected "foo |bar baz" "V w V" == some ([(8, 8)], .inclusive, ["b"])) },
    { name :=
        "a state that keeps both ends, entered with the anchor where no cursor of it may rest, puts the anchor where the head would rest: from an exclusive selection whose anchor is at the end of a text that ends in a line feed, on the line feed, which is the last cell, for the inclusive shape and for the line shape; with both ends in the empty last row, both on the line feed; at the end of a text with no line feed, on the last character; and an anchor on a cell, a line break among them, stays"
      run :=
        pure
          (evilEntered "ab\n" .exclusive 3 1 (evilKeeping .inclusive) ==
              some ([(2, 0)], .inclusive, ["ab\n"]) &&
            evilEntered "ab\n" .exclusive 3 1 (evilKeeping .line) ==
              some ([(2, 0)], .line, ["ab\n"]) &&
            evilEntered "ab\n" .exclusive 3 3 (evilKeeping .inclusive) ==
              some ([(2, 2)], .inclusive, ["\n"]) &&
            evilEntered "ab" .exclusive 2 0 (evilKeeping .inclusive) ==
              some ([(1, 0)], .inclusive, ["ab"]) &&
            evilEntered "ab\ncd" .exclusive 2 5 (evilKeeping .inclusive) ==
              some ([(2, 4)], .inclusive, ["\ncd"])) },
    { name :=
        "a state that keeps both ends, entered from an exclusive selection, keeps the anchor and steps the head back one cell, as leaving an insert session does, whichever end is first and for the line shape too; a head at its line's start stays; and from a selection that was not exclusive the head does not step back"
      run :=
        pure
          (evilEntered "abcd" .exclusive 1 3 (evilKeeping .inclusive) ==
              some ([(1, 2)], .inclusive, ["bc"]) &&
            evilEntered "abcd" .exclusive 3 1 (evilKeeping .inclusive) ==
              some ([(3, 0)], .inclusive, ["abcd"]) &&
            evilEntered "abcd" .exclusive 1 3 (evilKeeping .line) ==
              some ([(1, 2)], .line, ["abcd"]) &&
            evilEntered "ab\ncd" .exclusive 0 3 (evilKeeping .inclusive) ==
              some ([(0, 3)], .inclusive, ["ab\nc"]) &&
            evilEntered "abcd" .inclusive 1 3 (evilKeeping .inclusive) ==
              some ([(1, 3)], .inclusive, ["bcd"])) },
    { name :=
        "a departure from Vim, recorded in keymaps-and-modes.md under Where a cursor rests: on a last line with no line feed the head of a visual selection stops on the last character, where Vim's goes one past it, since there is no cell there"
      run := pure (evilSelected "foo |bar" "v w" == some ([(4, 6)], .inclusive, ["bar"])) },
    { name :=
        "the scene's cursor and status line are the state's after each key that enters one: a visual state's after v and after V, each with its own status field, and normal state's again after <Escape>"
      run :=
        pure <|
          let looks (typed : String) : Option (Cursor × Array StatusField) :=
            (evilScene "foo |bar baz" typed).map fun seen => (seen.cursor, seen.status)
          ["v", "V", "v V", "V v", "v <Escape>", "V <Escape>", "v w v", "<Escape>"].all
              (fun typed => looks typed == some (evilLooks typed)) &&
            (evilLooks "v").2 != (evilLooks "V").2 &&
            (evilLooks "v").2 != (evilLooks "").2 &&
            evilLooks "v <Escape>" == evilLooks "" },
    { name :=
        "the wanted column is kept through v, so j in the state v enters aims for it, and is not kept through <Escape>: the next j aims for the cursor's own column"
      run :=
        evilRows
          [("j v j", "abc|d\nx\nabcd", "abcd\nx\nabc|d"),
            ("j v <Escape> j", "abc|d\nx\nabcd", "abcd\nx\n|abcd")] }]

/-- The history of the buffer 0 of `driver`, as the checks read it: how many
nodes its tree has, and whether an edit is pending in its open group. -/
def evilHistory (driver : EvilDriver) : Option (Nat × Bool) :=
  (driver.loop.state.buffer? ⟨0⟩).map fun buffer =>
    (buffer.history.nodes.size, buffer.history.pending)

/-- `driver` after one undo request of the buffer 0 (`BufferId.undo`), made
by a command the loop is handed, which says in the echo area whether there
was a step to undo: `undone` or `nothing to undo`. -/
def evilUndone (driver : EvilDriver) : EvilDriver :=
  let undo : EditorM Unit := do
    match ← (⟨0⟩ : BufferId).undo with
    | .ok (some _) =>
      message "undone"
    | _ =>
      message "nothing to undo"
  (driver.stepped (driver.loop.deliver driver.handed "undo" undo)).1

/-- What the buffer 0 of `driver` holds in the text model. -/
def evilText (driver : EvilDriver) : Option String := do
  let buffer ← driver.loop.state.buffer? ⟨0⟩
  (driver.model.texts.texts[buffer.text.index]?).join.map (·.contents)

/-- The rows of the oracle table for `i`, typed text and `<Escape>`: the
text is inserted before the cursor's cell, and `<Escape>` leaves the cursor
on the last character typed, one cell back from the bar, and where it is at
a line's start. A digit, a key a motion is bound to, a shifted letter and a
space are text in the session. -/
def insertRows : List (String × String × String) :=
  [("i X <Escape>", "ab|c", "ab|Xc"), ("i <Escape>", "a|bc", "|abc"),
    ("i <Escape>", "|abc", "|abc"), ("i <Escape>", "ab\n|cd", "ab\n|cd"),
    ("i h e l l o <Escape>", "foo |bar", "foo hell|obar"), ("i h i <Escape>", "|", "h|i"),
    ("i X <Escape>", "ab\n|\ncd", "ab\n|X\ncd"), ("i 2 w <Escape>", "a|b", "a2|wb"),
    ("i x SPC A <Escape>", "a|b", "ax |Ab"), ("i é <Escape>", "a|b", "a|éb"),
    ("i X <Escape> l l", "|abc", "Xa|bc"), ("j i <Escape> j", "abc|d\nx\nabcd", "abcd\nx\n|abcd")]

/-- The rows of the oracle table for `a`, `I` and `A`: `a` begins the insert
after the cursor's cell, also on a line's last character, and where the
cursor is on an empty line; `I` at the line's first character that is not
a blank, which on a line of blanks only is after the blanks; `A` at the
line's end, before the line break. -/
def appendRows : List (String × String × String) :=
  [("a X <Escape>", "a|bc", "ab|Xc"), ("a X <Escape>", "ab|c\ndef", "abc|X\ndef"),
    ("a X <Escape>", "|\nabc", "|X\nabc"), ("a X <Escape>", "|", "|X"),
    ("a <Escape>", "ab|c", "ab|c"), ("a <Escape>", "a|bc", "a|bc"),
    ("a X <Escape>", "a|b\r\ncd", "ab|X\r\ncd"), ("I X <Escape>", "  ab|c", "  |Xabc"),
    ("I X <Escape>", "ab|c", "|Xabc"), ("I X <Escape>", "| \t ", " \t |X"),
    ("I X <Escape>", "ab\n|\ncd", "ab\n|X\ncd"), ("I <Escape>", "  ab|c", " | abc"),
    ("A X <Escape>", "a|bc", "abc|X"), ("A X <Escape>", "a|bc\ndef", "abc|X\ndef"),
    ("A X <Escape>", "ab\n|\ncd", "ab\n|X\ncd"), ("A <Escape>", "a|bc", "ab|c"),
    ("A X <Escape>", "a|b\r\ncd", "ab|X\r\ncd")]

/-- Rows for a count typed before a key that begins an insert, which
changes nothing: the text is inserted once. Vim repeats it, which is not
built. -/
def countedInsertRows : List (String × String × String) :=
  [("3 i X <Escape>", "ab|c", "ab|Xc"), ("3 a X <Escape>", "a|bc", "ab|Xc"),
    ("2 I X <Escape>", "  ab|c", "  |Xabc"), ("2 A X <Escape>", "a|bc", "abc|X")]

/-- The checks of evil's insert state (`Editor/Evil.lean`) on the loop's
driver over the editor's models, under the Vim scheme that ships with
evil's commands: the keys that begin an insert, typed text, and `<Escape>`,
and that one insert session is one step of the history. -/
def evilInsertChecks : List Check :=
  [{  name :=
        "i begins an insert before the cursor's cell, a key that prints is inserted at the bar, and <Escape> leaves the cursor one cell back from the bar, or where it is at a line's start; a digit and a key a motion is bound to are text in the session"
      run := evilRows insertRows },
    { name :=
        "a, I and A each begin the insert at the documented position: a after the cursor's cell, I at the line's first character that is not a blank, A at the line's end"
      run := evilRows appendRows },
    { name :=
        "a count typed before i, a, I or A changes nothing: the text typed is inserted once, where the key with no count inserts it"
      run := evilRows countedInsertRows },
    { name :=
        "i, typed text and <Escape>: the text is inserted at the cursor, the history has gained one node for the whole session and none inside it, one undo request gives the text from before the session, and a second finds nothing to undo"
      run :=
        pure <|
          match evilDriver "foo |bar" with
          | none => false
          | some driver =>
            let typing := evilFed driver "i h e l l o"
            let typed := evilFed typing "<Escape>"
            let undone := evilUndone typed
            let again := evilUndone undone
            evilHistory driver == some (1, false) && evilHistory typing == some (1, true) &&
              evilText typing == some "foo hellobar" &&
              evilHistory typed == some (2, false) &&
              evilText typed == some "foo hellobar" &&
              undone.loop.state.echo == "undone" &&
              evilText undone == some "foo bar" &&
              again.loop.state.echo == "nothing to undo" &&
              evilText again == some "foo bar" },
    { name :=
        "two insert sessions are two steps of the history: an undo request after the second gives the text from after the first"
      run :=
        pure <|
          match evilDriver "a|b" with
          | none => false
          | some driver =>
            let typed := evilFed driver "i x y <Escape> i z <Escape>"
            evilText typed == some "axzyb" && evilHistory typed == some (3, false) &&
              evilText (evilUndone typed) == some "axyb" &&
              evilText (evilUndone (evilUndone typed)) == some "ab" },
    { name :=
        "the scene shows the state: before i and after <Escape> a block, normal state's status field and one inclusive selection; inside the session a bar, insert state's status field and one exclusive selection at the bar, with the modified field once something is typed"
      run :=
        pure <|
          let seen (typed : String) : Option EvilSeen := evilScene "foo |bar" typed
          let modified : StatusField := { text := Loop.modifiedMark, face := Loop.modifiedFace }
          let insert := vimDefaultReport "i"
          let normal := vimDefaultReport ""
          seen "<F5>" ==
              some
                { selection := { ranges := #[⟨4, 4⟩], shape := .inclusive }, covered := #["b"]
                  cursor := (evilLooks "").1, status := (evilLooks "").2 } &&
            seen "i" ==
              some
                { selection := { ranges := #[⟨4, 4⟩], shape := .exclusive }, covered := #[""]
                  cursor := (evilLooks "i").1, status := (evilLooks "i").2 } &&
            seen "i h" ==
              some
                { selection := { ranges := #[⟨5, 5⟩], shape := .exclusive }, covered := #[""]
                  cursor := (evilLooks "i").1, status := (evilLooks "i").2.push modified } &&
            seen "i h <Escape>" ==
              some
                { selection := { ranges := #[⟨4, 4⟩], shape := .inclusive }, covered := #["h"]
                  cursor := (evilLooks "").1, status := (evilLooks "").2.push modified } &&
            insert.cursor.shape == .bar &&
            normal.cursor.shape == .block &&
            insert.cursor != normal.cursor &&
            insert.status != normal.status },
    { name :=
        "a key that prints, typed while a prompt is open, is inserted in the minibuffer and not in the asking view; RET then accepts, and the command the prompt named is run with what was typed"
      run :=
        pure <|
          let ask : Dispatched := fun _ => do
            discard <| prompt "Name: " { command := "greet" }
            return none
          let greet : Dispatched := fun call => do
            message s!"hello {" ".intercalate (call.arguments.map argumentText)}"
            return none
          let handed := evilHanded Minibuffer.commands [("ask", ask), ("greet", greet)]
          match evilDriver "a|bc" handed with
          | none => false
          | some driver =>
            let (asking, _) := driver.stepped (driver.loop.runNamed driver.handed "ask")
            let typing := evilFed asking "A d a 7"
            let answered := evilFed typing "RET"
            asking.loop.state.frame.focused == ⟨1⟩ && evilShown typing ⟨1⟩ == "Ada7|" &&
              evilShown typing == "a|bc" &&
              answered.loop.state.prompt.isNone &&
              answered.loop.state.echo == "hello Ada7" &&
              evilShown answered == "a|bc" },
    { name :=
        "the command typed text runs, called with no string as its first argument, inserts nothing and says so in the echo area"
      run :=
        pure <|
          match evilDriver "a|bc" with
          | none => false
          | some driver =>
            let (ran, _) :=
              driver.stepped (driver.loop.runNamed driver.handed Vim.selfInsertCommand)
            ran.loop.state.echo == Evil.noText && !Evil.noText.isEmpty && evilShown ran == "a|bc" &&
              evilHistory ran == some (1, false) },
    { name :=
        "a text an input method commits in normal state is not inserted: the text, the cursor and the history are as they were; committed inside an insert session it is inserted at the bar, and is one step of the history with what was typed"
      run :=
        pure <|
          match evilDriver "a|bc" with
          | none => false
          | some driver =>
            let commit (driver : EvilDriver) (text : String) : EvilDriver :=
              (driver.feed { event := .commit text, stamp := 0 }).1
            let ignored := commit driver "xy"
            let typed := evilFed (commit (evilFed driver "i x") "yz") "w"
            let ended := evilFed typed "<Escape>"
            evilShown ignored == "a|bc" && evilHistory ignored == some (1, false) &&
              evilShown typed == "axyzw|bc" &&
              evilHistory typed == some (1, true) &&
              evilShown ended == "axyz|wbc" &&
              evilHistory ended == some (2, false) &&
              evilText (evilUndone ended) == some "abc" }]

/-- What the unnamed register holds before the keys of an operator's row:
a text no row yields, so that a register the keys left as it was is seen. -/
def evilSentinel : Register :=
  { text := "the sentinel", linewise := true }

/-- What the keys of an operator's row left, as the checks read it. -/
structure EvilEdited where
  /-- The buffer's text with a bar at the head of the selection's primary
  range. -/
  shown : String
  /-- The unnamed register; `none` when it is as it was before the keys. -/
  register : Option Register
  /-- Whether the scene's status line says the view is in insert state: its
  first field is the one the scheme reports of that state. -/
  insert : Bool
  /-- What the echo area says. -/
  echo : String
  deriving DecidableEq, Repr

/-- A driver of the evil checks over the state the fixture `fixture` says,
with the unnamed register holding `evilSentinel`, on the models `model`. -/
def evilRegistered (fixture : String) (model : EditorModel := editorModel) : Option EvilDriver :=
  let (contents, head) := barred fixture
  (Loop.Driver.over evilHanded (fun _ => none)
      (do
        return (← evilState contents head).setRegister Evil.unnamed evilSentinel)
      model).toOption

/-- What `driver`, made by `evilRegistered`, shows after its keys. -/
def evilLeft (driver : EvilDriver) : EvilEdited :=
  let register := driver.loop.state.register? Evil.unnamed
  { shown := evilShown driver
    register := if register == some evilSentinel then none else register
    insert :=
      ((evilSeen driver).bind (·.status[0]?)) == (vimDefaultReport "i").status[0]? &&
        (vimDefaultReport "i").status[0]? != (vimDefaultReport "").status[0]?
    echo := driver.loop.state.echo }

/-- The keys the key string `typed` names, pressed under the Vim scheme that
ships with evil's commands, from the text and the cursor `fixture` says,
with the unnamed register holding a sentinel: what they left. -/
def evilEdited (fixture typed : String) : Option EvilEdited :=
  (evilRegistered fixture).map fun driver => evilLeft (evilFed driver typed)

/-- The operate command called with `arguments`, as an invocation no key
yielded, from the text and the cursor `fixture` says: what it left. -/
def evilOperated (fixture : String) (arguments : List Argument) : Option EvilEdited :=
  (evilRegistered fixture).map fun driver =>
    evilLeft
      (driver.stepped
          (driver.loop.invoke driver.handed { command := Vim.operateCommand, arguments })).1

/-- A register's text that is not line-wise, as a row expects it. -/
def charwise (text : String) : Option Register :=
  some { text }

/-- A register's text that is line-wise, as a row expects it. -/
def linewise (text : String) : Option Register :=
  some { text, linewise := true }

/-- The register a row expects its keys to leave as it was. -/
def asItWas : Option Register :=
  none

/-- One row of an oracle table of the operators: keys, the text and the
cursor they are pressed from, and what Vim leaves. -/
structure OperatorRow where
  /-- The text before, with the cursor as a bar. -/
  before : String
  /-- The key string. -/
  keys : String
  /-- The text after, with a bar at the cursor: the cell the cursor is on in
  normal state, and where the insert begins in insert state. -/
  after : String
  /-- The unnamed register after; `none` when it is as it was. -/
  register : Option Register
  /-- Whether the view is left in insert state. -/
  insert : Bool := false
  /-- Whether the command gave up or broke off: something is said in the
  echo area, which is no refusal. -/
  gaveUp : Bool := false

namespace OperatorRow

/-- A row whose keys leave the view in normal state. -/
def rests (before keys after : String) (register : Option Register) : OperatorRow :=
  { before, keys, after, register }

/-- A row whose keys leave the view in insert state, the bar at `after`'s. -/
def inserts (before keys after : String) (register : Option Register) : OperatorRow :=
  { before, keys, after, register, insert := true }

/-- A row whose keys' command gives up: the text, the cursor and the
register are as they were, and the view is in normal state. -/
def givesUp (before keys : String) : OperatorRow :=
  { before, keys, after := before, register := none, gaveUp := true }

/-- A row whose keys' command breaks off: the cursor is at `after`'s bar,
the text and the register are as they were, the view is in normal state,
and the echo area says something that is no refusal. -/
def breaksOff (before keys after : String) : OperatorRow :=
  { before, keys, after, register := none, gaveUp := true }

/-- What is wrong with the row, if anything: what its keys left when that
is not what the row says, and a key string that names no keys. -/
def wrong (row : OperatorRow) : Option String :=
  if (ModelTest.keys row.keys).isEmpty then some s!"{repr row.keys} names no keys"
  else
    match evilEdited row.before row.keys with
    | none => some s!"no driver for {repr row.before}"
    | some left =>
      let saidSo := !left.echo.isEmpty && (left.echo.splitOn "refused").length == 1
      if
          left.shown == row.after && left.register == row.register && left.insert == row.insert &&
            (if row.gaveUp then saidSo else left.echo.isEmpty) then
        none
      else some s!"{row.keys} from {repr row.before} left {repr left}"

end OperatorRow

/-- Whether each row of `rows` holds (`OperatorRow.wrong`). A failure names
each row that does not hold, with what its keys left. -/
def operatorRows (rows : List OperatorRow) : IO Bool := do
  let wrong := rows.filterMap (·.wrong)
  unless wrong.isEmpty do
    throw (IO.userError ("; ".intercalate wrong))
  return true

/-- The text and the cursor of the oracle table's first two situations: a
cursor in the middle of a line that has words, punctuation and an indent,
with lines above and below. -/
def plainText : String :=
  "ab\ncd\n  ef |gh.ij kl\nmn\nop\n"

/-- The text and the cursor of the oracle table's third situation: a cursor
on an empty line. -/
def emptyLineText : String :=
  "ab cd\n|\n  ef gh\n"

/-- The text and the cursor of the oracle table's fourth situation: a cursor
on the last character of a buffer that ends in a line feed. -/
def endText : String :=
  "ab cd\n  ef g|h\n"

/-- The text and the cursor of the oracle table's fifth situation: a cursor
on the last character of a buffer with no final line feed. -/
def bareEndText : String :=
  "ab cd\n  ef g|h"

/-- The oracle table's rows for `d` over `h`, `l`, `0` and `^`, in its five
situations: no count, a count of 2, on an empty line, and on the buffer's
last character with and without a final line feed. `0` takes no count of
its own, so its counted row has the count before the operator. -/
def deleteAlongRows : List OperatorRow :=
  [.rests plainText "d h" "ab\ncd\n  ef|gh.ij kl\nmn\nop\n" (charwise " "),
    .rests plainText "d l" "ab\ncd\n  ef |h.ij kl\nmn\nop\n" (charwise "g"),
    .rests plainText "d 0" "ab\ncd\n|gh.ij kl\nmn\nop\n" (charwise "  ef "),
    .rests plainText "d ^" "ab\ncd\n  |gh.ij kl\nmn\nop\n" (charwise "ef "),
    .rests plainText "d 2 h" "ab\ncd\n  e|gh.ij kl\nmn\nop\n" (charwise "f "),
    .rests plainText "d 2 l" "ab\ncd\n  ef |.ij kl\nmn\nop\n" (charwise "gh"),
    .rests plainText "2 d 0" "ab\ncd\n|gh.ij kl\nmn\nop\n" (charwise "  ef "),
    .rests plainText "d 2 ^" "ab\ncd\n  |gh.ij kl\nmn\nop\n" (charwise "ef "),
    .rests emptyLineText "d h" "ab cd\n|\n  ef gh\n" asItWas,
    .rests emptyLineText "d l" "ab cd\n|\n  ef gh\n" asItWas,
    .rests emptyLineText "d 0" "ab cd\n|\n  ef gh\n" asItWas,
    .rests emptyLineText "d ^" "ab cd\n|\n  ef gh\n" asItWas,
    .rests endText "d h" "ab cd\n  ef |h\n" (charwise "g"),
    .rests endText "d l" "ab cd\n  ef |g\n" (charwise "h"),
    .rests endText "d 0" "ab cd\n|h\n" (charwise "  ef g"),
    .rests endText "d ^" "ab cd\n  |h\n" (charwise "ef g"),
    .rests bareEndText "d h" "ab cd\n  ef |h" (charwise "g"),
    .rests bareEndText "d l" "ab cd\n  ef |g" (charwise "h"),
    .rests bareEndText "d 0" "ab cd\n|h" (charwise "  ef g"),
    .rests bareEndText "d ^" "ab cd\n  |h" (charwise "ef g")]

/-- The oracle table's rows for `c` and `y` over `h`, `l`, `0` and `^`, in
its five situations. A yank leaves the cursor at the start of what it took,
and a change leaves the bar there, in insert state. Over no cell `y`
empties the register and `c` leaves it as it was. -/
def yankChangeAlongRows : List OperatorRow :=
  [.inserts plainText "c h" "ab\ncd\n  ef|gh.ij kl\nmn\nop\n" (charwise " "),
    .rests plainText "y h" "ab\ncd\n  ef| gh.ij kl\nmn\nop\n" (charwise " "),
    .inserts plainText "c l" "ab\ncd\n  ef |h.ij kl\nmn\nop\n" (charwise "g"),
    .rests plainText "y l" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "g"),
    .inserts plainText "c 0" "ab\ncd\n|gh.ij kl\nmn\nop\n" (charwise "  ef "),
    .rests plainText "y 0" "ab\ncd\n|  ef gh.ij kl\nmn\nop\n" (charwise "  ef "),
    .inserts plainText "c ^" "ab\ncd\n  |gh.ij kl\nmn\nop\n" (charwise "ef "),
    .rests plainText "y ^" "ab\ncd\n  |ef gh.ij kl\nmn\nop\n" (charwise "ef "),
    .inserts plainText "c 2 h" "ab\ncd\n  e|gh.ij kl\nmn\nop\n" (charwise "f "),
    .rests plainText "y 2 h" "ab\ncd\n  e|f gh.ij kl\nmn\nop\n" (charwise "f "),
    .inserts plainText "c 2 l" "ab\ncd\n  ef |.ij kl\nmn\nop\n" (charwise "gh"),
    .rests plainText "y 2 l" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "gh"),
    .inserts plainText "2 c 0" "ab\ncd\n|gh.ij kl\nmn\nop\n" (charwise "  ef "),
    .rests plainText "2 y 0" "ab\ncd\n|  ef gh.ij kl\nmn\nop\n" (charwise "  ef "),
    .inserts plainText "c 2 ^" "ab\ncd\n  |gh.ij kl\nmn\nop\n" (charwise "ef "),
    .rests plainText "y 2 ^" "ab\ncd\n  |ef gh.ij kl\nmn\nop\n" (charwise "ef "),
    .inserts emptyLineText "c h" "ab cd\n|\n  ef gh\n" asItWas,
    .rests emptyLineText "y h" "ab cd\n|\n  ef gh\n" (charwise ""),
    .inserts emptyLineText "c l" "ab cd\n|\n  ef gh\n" asItWas,
    .rests emptyLineText "y l" "ab cd\n|\n  ef gh\n" (charwise ""),
    .inserts emptyLineText "c 0" "ab cd\n|\n  ef gh\n" asItWas,
    .rests emptyLineText "y 0" "ab cd\n|\n  ef gh\n" (charwise ""),
    .inserts emptyLineText "c ^" "ab cd\n|\n  ef gh\n" asItWas,
    .rests emptyLineText "y ^" "ab cd\n|\n  ef gh\n" (charwise ""),
    .inserts endText "c h" "ab cd\n  ef |h\n" (charwise "g"),
    .rests endText "y h" "ab cd\n  ef |gh\n" (charwise "g"),
    .inserts endText "c l" "ab cd\n  ef g|\n" (charwise "h"),
    .rests endText "y l" "ab cd\n  ef g|h\n" (charwise "h"),
    .inserts endText "c 0" "ab cd\n|h\n" (charwise "  ef g"),
    .rests endText "y 0" "ab cd\n|  ef gh\n" (charwise "  ef g"),
    .inserts endText "c ^" "ab cd\n  |h\n" (charwise "ef g"),
    .rests endText "y ^" "ab cd\n  |ef gh\n" (charwise "ef g"),
    .inserts bareEndText "c h" "ab cd\n  ef |h" (charwise "g"),
    .rests bareEndText "y h" "ab cd\n  ef |gh" (charwise "g"),
    .inserts bareEndText "c l" "ab cd\n  ef g|" (charwise "h"),
    .rests bareEndText "y l" "ab cd\n  ef g|h" (charwise "h"),
    .inserts bareEndText "c 0" "ab cd\n|h" (charwise "  ef g"),
    .rests bareEndText "y 0" "ab cd\n|  ef gh" (charwise "  ef g"),
    .inserts bareEndText "c ^" "ab cd\n  |h" (charwise "ef g"),
    .rests bareEndText "y ^" "ab cd\n  |ef gh" (charwise "ef g")]

/-- The oracle table's rows for the three operators over `$`, in its five
situations. With a count it reaches the end of a line below, and the line
breaks between are taken. On an empty line `c $` empties the register where
`d $` leaves it. -/
def lineEndRows : List OperatorRow :=
  [.rests plainText "d $" "ab\ncd\n  ef| \nmn\nop\n" (charwise "gh.ij kl"),
    .inserts plainText "c $" "ab\ncd\n  ef |\nmn\nop\n" (charwise "gh.ij kl"),
    .rests plainText "y $" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "gh.ij kl"),
    .rests plainText "d 2 $" "ab\ncd\n  ef| \nop\n" (charwise "gh.ij kl\nmn"),
    .inserts plainText "c 2 $" "ab\ncd\n  ef |\nop\n" (charwise "gh.ij kl\nmn"),
    .rests plainText "y 2 $" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "gh.ij kl\nmn"),
    .rests emptyLineText "d $" "ab cd\n|\n  ef gh\n" asItWas,
    .inserts emptyLineText "c $" "ab cd\n|\n  ef gh\n" (charwise ""),
    .rests emptyLineText "y $" "ab cd\n|\n  ef gh\n" (charwise ""),
    .rests endText "d $" "ab cd\n  ef |g\n" (charwise "h"),
    .inserts endText "c $" "ab cd\n  ef g|\n" (charwise "h"),
    .rests endText "y $" "ab cd\n  ef g|h\n" (charwise "h"),
    .rests bareEndText "d $" "ab cd\n  ef |g" (charwise "h"),
    .inserts bareEndText "c $" "ab cd\n  ef g|" (charwise "h"),
    .rests bareEndText "y $" "ab cd\n  ef g|h" (charwise "h")]

/-- The oracle table's rows for the three operators over `e`, `E`, `b` and
`B`, in its five situations. A motion to a word's end takes that end's
cell. A backward motion that stops at a line's start, from another line,
stops where the line before ends. -/
def wordEndBackRows : List OperatorRow :=
  [.rests plainText "d b" "ab\ncd\n  |gh.ij kl\nmn\nop\n" (charwise "ef "),
    .inserts plainText "c b" "ab\ncd\n  |gh.ij kl\nmn\nop\n" (charwise "ef "),
    .rests plainText "y b" "ab\ncd\n  |ef gh.ij kl\nmn\nop\n" (charwise "ef "),
    .rests plainText "d e" "ab\ncd\n  ef |.ij kl\nmn\nop\n" (charwise "gh"),
    .inserts plainText "c e" "ab\ncd\n  ef |.ij kl\nmn\nop\n" (charwise "gh"),
    .rests plainText "y e" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "gh"),
    .rests plainText "d B" "ab\ncd\n  |gh.ij kl\nmn\nop\n" (charwise "ef "),
    .inserts plainText "c B" "ab\ncd\n  |gh.ij kl\nmn\nop\n" (charwise "ef "),
    .rests plainText "y B" "ab\ncd\n  |ef gh.ij kl\nmn\nop\n" (charwise "ef "),
    .rests plainText "d E" "ab\ncd\n  ef | kl\nmn\nop\n" (charwise "gh.ij"),
    .inserts plainText "c E" "ab\ncd\n  ef | kl\nmn\nop\n" (charwise "gh.ij"),
    .rests plainText "y E" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "gh.ij"),
    .rests plainText "d 2 b" "ab\n|gh.ij kl\nmn\nop\n" (charwise "cd\n  ef "),
    .inserts plainText "c 2 b" "ab\n|gh.ij kl\nmn\nop\n" (charwise "cd\n  ef "),
    .rests plainText "y 2 b" "ab\n|cd\n  ef gh.ij kl\nmn\nop\n" (charwise "cd\n  ef "),
    .rests plainText "d 2 e" "ab\ncd\n  ef |ij kl\nmn\nop\n" (charwise "gh."),
    .inserts plainText "c 2 e" "ab\ncd\n  ef |ij kl\nmn\nop\n" (charwise "gh."),
    .rests plainText "y 2 e" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "gh."),
    .rests plainText "d 2 B" "ab\n|gh.ij kl\nmn\nop\n" (charwise "cd\n  ef "),
    .inserts plainText "c 2 B" "ab\n|gh.ij kl\nmn\nop\n" (charwise "cd\n  ef "),
    .rests plainText "y 2 B" "ab\n|cd\n  ef gh.ij kl\nmn\nop\n" (charwise "cd\n  ef "),
    .rests plainText "d 2 E" "ab\ncd\n  ef| \nmn\nop\n" (charwise "gh.ij kl"),
    .inserts plainText "c 2 E" "ab\ncd\n  ef |\nmn\nop\n" (charwise "gh.ij kl"),
    .rests plainText "y 2 E" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "gh.ij kl"),
    .rests emptyLineText "d b" "ab| \n\n  ef gh\n" (charwise "cd"),
    .inserts emptyLineText "c b" "ab |\n\n  ef gh\n" (charwise "cd"),
    .rests emptyLineText "y b" "ab |cd\n\n  ef gh\n" (charwise "cd"),
    .rests emptyLineText "d e" "ab cd\n| gh\n" (charwise "\n  ef"),
    .inserts emptyLineText "c e" "ab cd\n| gh\n" (charwise "\n  ef"),
    .rests emptyLineText "y e" "ab cd\n|\n  ef gh\n" (charwise "\n  ef"),
    .rests emptyLineText "d B" "ab| \n\n  ef gh\n" (charwise "cd"),
    .inserts emptyLineText "c B" "ab |\n\n  ef gh\n" (charwise "cd"),
    .rests emptyLineText "y B" "ab |cd\n\n  ef gh\n" (charwise "cd"),
    .rests emptyLineText "d E" "ab cd\n| gh\n" (charwise "\n  ef"),
    .inserts emptyLineText "c E" "ab cd\n| gh\n" (charwise "\n  ef"),
    .rests emptyLineText "y E" "ab cd\n|\n  ef gh\n" (charwise "\n  ef"),
    .rests endText "d b" "ab cd\n  ef |h\n" (charwise "g"),
    .inserts endText "c b" "ab cd\n  ef |h\n" (charwise "g"),
    .rests endText "y b" "ab cd\n  ef |gh\n" (charwise "g"),
    .rests endText "d e" "ab cd\n  ef |g\n" (charwise "h"),
    .inserts endText "c e" "ab cd\n  ef g|\n" (charwise "h"),
    .rests endText "y e" "ab cd\n  ef g|h\n" (charwise "h"),
    .rests endText "d B" "ab cd\n  ef |h\n" (charwise "g"),
    .inserts endText "c B" "ab cd\n  ef |h\n" (charwise "g"),
    .rests endText "y B" "ab cd\n  ef |gh\n" (charwise "g"),
    .rests endText "d E" "ab cd\n  ef |g\n" (charwise "h"),
    .inserts endText "c E" "ab cd\n  ef g|\n" (charwise "h"),
    .rests endText "y E" "ab cd\n  ef g|h\n" (charwise "h"),
    .rests bareEndText "d b" "ab cd\n  ef |h" (charwise "g"),
    .inserts bareEndText "c b" "ab cd\n  ef |h" (charwise "g"),
    .rests bareEndText "y b" "ab cd\n  ef |gh" (charwise "g"),
    .rests bareEndText "d e" "ab cd\n  ef |g" (charwise "h"),
    .inserts bareEndText "c e" "ab cd\n  ef g|" (charwise "h"),
    .rests bareEndText "y e" "ab cd\n  ef g|h" (charwise "h"),
    .rests bareEndText "d B" "ab cd\n  ef |h" (charwise "g"),
    .inserts bareEndText "c B" "ab cd\n  ef |h" (charwise "g"),
    .rests bareEndText "y B" "ab cd\n  ef |gh" (charwise "g"),
    .rests bareEndText "d E" "ab cd\n  ef |g" (charwise "h"),
    .inserts bareEndText "c E" "ab cd\n  ef g|" (charwise "h"),
    .rests bareEndText "y E" "ab cd\n  ef g|h" (charwise "h")]

/-- The oracle table's rows for `d` and `y` over `w` and `W`, in its five
situations. Under an operator the last word moved over ends the stretch
where its line's content ends, and from an empty line the stretch is that
line. -/
def wordForwardRows : List OperatorRow :=
  [.rests plainText "d w" "ab\ncd\n  ef |.ij kl\nmn\nop\n" (charwise "gh"),
    .rests plainText "y w" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "gh"),
    .rests plainText "d W" "ab\ncd\n  ef |kl\nmn\nop\n" (charwise "gh.ij "),
    .rests plainText "y W" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "gh.ij "),
    .rests plainText "d 2 w" "ab\ncd\n  ef |ij kl\nmn\nop\n" (charwise "gh."),
    .rests plainText "y 2 w" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "gh."),
    .rests plainText "d 2 W" "ab\ncd\n  ef| \nmn\nop\n" (charwise "gh.ij kl"),
    .rests plainText "y 2 W" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (charwise "gh.ij kl"),
    .rests emptyLineText "d w" "ab cd\n  |ef gh\n" (linewise "\n"),
    .rests emptyLineText "y w" "ab cd\n|\n  ef gh\n" (linewise "\n"),
    .rests emptyLineText "d W" "ab cd\n  |ef gh\n" (linewise "\n"),
    .rests emptyLineText "y W" "ab cd\n|\n  ef gh\n" (linewise "\n"),
    .rests endText "d w" "ab cd\n  ef |g\n" (charwise "h"),
    .rests endText "y w" "ab cd\n  ef g|h\n" (charwise "h"),
    .rests endText "d W" "ab cd\n  ef |g\n" (charwise "h"),
    .rests endText "y W" "ab cd\n  ef g|h\n" (charwise "h"),
    .rests bareEndText "d w" "ab cd\n  ef |g" (charwise "h"),
    .rests bareEndText "y w" "ab cd\n  ef g|h" (charwise "h"),
    .rests bareEndText "d W" "ab cd\n  ef |g" (charwise "h"),
    .rests bareEndText "y W" "ab cd\n  ef g|h" (charwise "h")]

/-- The oracle table's rows for `c` over `w` and `W`, in its five
situations. On a cell that is not a blank a change goes to the end of the
word and not to the next word's start. -/
def changeWordRows : List OperatorRow :=
  [.inserts plainText "c w" "ab\ncd\n  ef |.ij kl\nmn\nop\n" (charwise "gh"),
    .inserts plainText "c W" "ab\ncd\n  ef | kl\nmn\nop\n" (charwise "gh.ij"),
    .inserts plainText "c 2 w" "ab\ncd\n  ef |ij kl\nmn\nop\n" (charwise "gh."),
    .inserts plainText "c 2 W" "ab\ncd\n  ef |\nmn\nop\n" (charwise "gh.ij kl"),
    .inserts emptyLineText "c w" "ab cd\n|\n  ef gh\n" (linewise "\n"),
    .inserts emptyLineText "c W" "ab cd\n|\n  ef gh\n" (linewise "\n"),
    .inserts endText "c w" "ab cd\n  ef g|\n" (charwise "h"),
    .inserts endText "c W" "ab cd\n  ef g|\n" (charwise "h"),
    .inserts bareEndText "c w" "ab cd\n  ef g|" (charwise "h"),
    .inserts bareEndText "c W" "ab cd\n  ef g|" (charwise "h")]

/-- The oracle table's rows for the three operators over `j`, `k`, `g g`
and `G`, in its five situations: each takes whole lines. On the buffer's
last line `j` fails, and the operator gives up. -/
def lineMotionRows : List OperatorRow :=
  [.rests plainText "d j" "ab\ncd\n|op\n" (linewise "  ef gh.ij kl\nmn\n"),
    .inserts plainText "c j" "ab\ncd\n|\nop\n" (linewise "  ef gh.ij kl\nmn\n"),
    .rests plainText "y j" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (linewise "  ef gh.ij kl\nmn\n"),
    .rests plainText "d k" "ab\n|mn\nop\n" (linewise "cd\n  ef gh.ij kl\n"),
    .inserts plainText "c k" "ab\n|\nmn\nop\n" (linewise "cd\n  ef gh.ij kl\n"),
    .rests plainText "y k" "ab\nc|d\n  ef gh.ij kl\nmn\nop\n" (linewise "cd\n  ef gh.ij kl\n"),
    .rests plainText "d g g" "|mn\nop\n" (linewise "ab\ncd\n  ef gh.ij kl\n"),
    .inserts plainText "c g g" "|\nmn\nop\n" (linewise "ab\ncd\n  ef gh.ij kl\n"),
    .rests plainText "y g g" "|ab\ncd\n  ef gh.ij kl\nmn\nop\n"
      (linewise "ab\ncd\n  ef gh.ij kl\n"),
    .rests plainText "d G" "ab\n|cd\n" (linewise "  ef gh.ij kl\nmn\nop\n"),
    .inserts plainText "c G" "ab\ncd\n|\n" (linewise "  ef gh.ij kl\nmn\nop\n"),
    .rests plainText "y G" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n" (linewise "  ef gh.ij kl\nmn\nop\n"),
    .rests plainText "d 2 j" "ab\n|cd\n" (linewise "  ef gh.ij kl\nmn\nop\n"),
    .inserts plainText "c 2 j" "ab\ncd\n|\n" (linewise "  ef gh.ij kl\nmn\nop\n"),
    .rests plainText "y 2 j" "ab\ncd\n  ef |gh.ij kl\nmn\nop\n"
      (linewise "  ef gh.ij kl\nmn\nop\n"),
    .rests plainText "d 2 k" "|mn\nop\n" (linewise "ab\ncd\n  ef gh.ij kl\n"),
    .inserts plainText "c 2 k" "|\nmn\nop\n" (linewise "ab\ncd\n  ef gh.ij kl\n"),
    .rests plainText "y 2 k" "a|b\ncd\n  ef gh.ij kl\nmn\nop\n"
      (linewise "ab\ncd\n  ef gh.ij kl\n"),
    .rests plainText "d 2 g g" "ab\n|mn\nop\n" (linewise "cd\n  ef gh.ij kl\n"),
    .inserts plainText "c 2 g g" "ab\n|\nmn\nop\n" (linewise "cd\n  ef gh.ij kl\n"),
    .rests plainText "y 2 g g" "ab\n|cd\n  ef gh.ij kl\nmn\nop\n" (linewise "cd\n  ef gh.ij kl\n"),
    .rests plainText "d 2 G" "ab\n|mn\nop\n" (linewise "cd\n  ef gh.ij kl\n"),
    .inserts plainText "c 2 G" "ab\n|\nmn\nop\n" (linewise "cd\n  ef gh.ij kl\n"),
    .rests plainText "y 2 G" "ab\n|cd\n  ef gh.ij kl\nmn\nop\n" (linewise "cd\n  ef gh.ij kl\n"),
    .rests emptyLineText "d j" "|ab cd\n" (linewise "\n  ef gh\n"),
    .inserts emptyLineText "c j" "ab cd\n|\n" (linewise "\n  ef gh\n"),
    .rests emptyLineText "y j" "ab cd\n|\n  ef gh\n" (linewise "\n  ef gh\n"),
    .rests emptyLineText "d k" "  |ef gh\n" (linewise "ab cd\n\n"),
    .inserts emptyLineText "c k" "|\n  ef gh\n" (linewise "ab cd\n\n"),
    .rests emptyLineText "y k" "|ab cd\n\n  ef gh\n" (linewise "ab cd\n\n"),
    .rests emptyLineText "d g g" "  |ef gh\n" (linewise "ab cd\n\n"),
    .inserts emptyLineText "c g g" "|\n  ef gh\n" (linewise "ab cd\n\n"),
    .rests emptyLineText "y g g" "|ab cd\n\n  ef gh\n" (linewise "ab cd\n\n"),
    .rests emptyLineText "d G" "|ab cd\n" (linewise "\n  ef gh\n"),
    .inserts emptyLineText "c G" "ab cd\n|\n" (linewise "\n  ef gh\n"),
    .rests emptyLineText "y G" "ab cd\n|\n  ef gh\n" (linewise "\n  ef gh\n"),
    .givesUp endText "d j", .givesUp endText "c j", .givesUp endText "y j",
    .rests endText "d k" "|" (linewise "ab cd\n  ef gh\n"),
    .inserts endText "c k" "|\n" (linewise "ab cd\n  ef gh\n"),
    .rests endText "y k" "ab c|d\n  ef gh\n" (linewise "ab cd\n  ef gh\n"),
    .rests endText "d g g" "|" (linewise "ab cd\n  ef gh\n"),
    .inserts endText "c g g" "|\n" (linewise "ab cd\n  ef gh\n"),
    .rests endText "y g g" "|ab cd\n  ef gh\n" (linewise "ab cd\n  ef gh\n"),
    .rests endText "d G" "|ab cd\n" (linewise "  ef gh\n"),
    .inserts endText "c G" "ab cd\n|\n" (linewise "  ef gh\n"),
    .rests endText "y G" "ab cd\n  |ef gh\n" (linewise "  ef gh\n"), .givesUp bareEndText "d j",
    .givesUp bareEndText "c j", .givesUp bareEndText "y j",
    .rests bareEndText "d k" "|" (linewise "ab cd\n  ef gh\n"),
    .inserts bareEndText "c k" "|" (linewise "ab cd\n  ef gh\n"),
    .rests bareEndText "y k" "ab c|d\n  ef gh" (linewise "ab cd\n  ef gh\n"),
    .rests bareEndText "d g g" "|" (linewise "ab cd\n  ef gh\n"),
    .inserts bareEndText "c g g" "|" (linewise "ab cd\n  ef gh\n"),
    .rests bareEndText "y g g" "|ab cd\n  ef gh" (linewise "ab cd\n  ef gh\n"),
    .rests bareEndText "d G" "|ab cd" (linewise "  ef gh\n"),
    .inserts bareEndText "c G" "ab cd\n|" (linewise "  ef gh\n"),
    .rests bareEndText "y G" "ab cd\n  |ef gh" (linewise "  ef gh\n")]

/-- The rows of the operator × motion table, in the order the motions were
built. -/
def operatorTable : List OperatorRow :=
  deleteAlongRows ++ yankChangeAlongRows ++ lineEndRows ++ wordEndBackRows ++ wordForwardRows ++
    changeWordRows ++
    lineMotionRows

/-- The five situations of the operator × motion table: the text and the
cursor of each, and whether its rows have a count. -/
def operatorSituations : List (String × Bool) :=
  [(plainText, false), (plainText, true), (emptyLineText, false), (endText, false),
    (bareEndText, false)]

/-- The pairs of an operator's key and a motion's key that the rows of
`operatorTable` have for the situation of the text `before`, with a count
when `counted`: a row's keys without its count, the first being the
operator's and the rest the motion's. -/
def operatorPairs (before : String) (counted : Bool) : List (String × String) :=
  operatorTable.filterMap fun row =>
    let tokens := row.keys.splitOn " "
    if row.before == before && tokens.contains "2" == counted then
      match tokens.filter (· != "2") with
      | operator :: motion => some (operator, " ".intercalate motion)
      | [] => none
    else none

/-- Every pair of an operator's key and a motion's key of the default
tables (`Vim.Default.operators`, `Vim.Default.motions`). -/
def defaultPairs : List (String × String) :=
  Vim.Default.operators.flatMap fun (operator, _) =>
    Vim.Default.motions.map fun (motion, _) => (operator, motion)

/-- What is wrong, if anything, with each operator key of the default tables
pressed with each motion key, with no count and with a count of 2, from
every position of a text holding `contents` where a normal-state cursor may
rest. For each: the echo area says no refusal; after an operator that
enters no state the cursor is where normal state lets one rest; an operator
that changes no text leaves the text; and when the text changed, `u`, after
`<Escape>` for an operator that enters a state, gives the text back and
puts the cursor where it was. It reads the tables, so it covers a key added
later. -/
def operatorSweep (contents : String) : List String :=
  ((List.range (contents.utf8ByteSize + 1)).filter (restsWell contents)).flatMap fun position =>
    Vim.Default.operators.flatMap fun (operatorKey, bound) =>
      match bound with
      | .operator operator =>
        Vim.Default.motions.flatMap fun (motionKey, _) =>
          [false, true].filterMap fun counted =>
            let typed := (if counted then "2 " else "") ++ operatorKey ++ " " ++ motionKey
            let what := s!"{typed} at {position} of {repr contents}"
            match
              (Loop.Driver.over evilHanded (fun _ => none) (evilState contents position)
                  editorModel).toOption with
            | none => some s!"{what}: no driver"
            | some driver =>
              let after := evilFed driver typed
              let text := evilText after
              let head :=
                (evilSelection after).bind fun selection =>
                  selection.ranges[selection.primary]?.map (·.head)
              let refused := (after.loop.state.echo.splitOn "refused").length != 1
              let rests :=
                operator.enters.isSome ||
                  match text, head with
                  | some text, some head => restsWell text head
                  | _, _ => false
              let kept := operator.changes || text == some contents
              let ended := if operator.enters.isSome then evilFed after "<Escape>" else after
              let undone :=
                text == some contents || evilShown (evilFed ended "u") == withBar contents position
              if !refused && rests && kept && undone then none
              else
                some
                  s!"{what}: left {repr (evilShown after)}, echo {repr after.loop.state.echo}, undone to {repr (evilShown (evilFed ended "u"))}"
      | _ => []

/-- Whether `left` is what a command that gave up with `reason` leaves: the
text and the cursor `shown`, the register as it was, the view not in insert
state, and an echo area that ends with the reason and says no refusal. -/
def evilGaveUp (left : Option EvilEdited) (shown reason : String) : Bool :=
  !reason.isEmpty &&
    match left with
    | some left =>
      left.shown == shown && left.register == none && !left.insert && left.echo.endsWith reason &&
        (left.echo.splitOn "refused").length == 1
    | none => false

/-- The checks of evil's operators (`Editor/Evil/Operators.lean`) on the
loop's driver over the editor's models, under the Vim scheme that ships
with evil's commands: an operator's keys are pressed in a text with the
cursor written into it, with a sentinel in the unnamed register, and each
expected text, cursor and register is written by hand from Vim's
documented behaviour, case by case. -/
def evilOperatorChecks : List Check :=
  [{  name :=
        "an operator's key and a motion's run the operate command: d l deletes the cell under the cursor into the unnamed register, and nothing is said in the echo area"
      run := pure (evilEdited "a|bc" "d l" == some ⟨"a|c", charwise "b", false, ""⟩) },
    { name :=
        "each operator over each motion, in five situations (no count, a count of 2, on an empty line, on the buffer's last character with and without a final line feed), leaves the text, the cursor and the unnamed register Vim leaves"
      run := operatorRows operatorTable },
    { name :=
        "the table is complete: in each of its five situations, the pairs of an operator's key and a motion's key its rows have are exactly those of the default tables, each once"
      run :=
        pure <|
          !defaultPairs.isEmpty &&
            operatorTable.length == operatorSituations.length * defaultPairs.length &&
            operatorSituations.all fun (before, counted) =>
              let pairs := operatorPairs before counted
              pairs.length == defaultPairs.length && defaultPairs.all pairs.contains },
    { name :=
        "a sweep of every default operator key over every default motion key, with no count and with a count of 2, from every position a cursor may rest at in a few texts: nothing is refused, after an operator that enters no state the cursor is where normal state lets one rest, an operator that changes no text leaves the text, and u gives back a text that changed, with the cursor where it was"
      run := do
        let wrong := sweepTexts.flatMap operatorSweep
        unless wrong.isEmpty do
          throw
              (IO.userError s!"{wrong.length} cases, the first: {"; ".intercalate (wrong.take 5)}")
        return true },
    { name :=
        "the doubled operator acts on whole lines, and with a count on that many, stopped at the last line: d d leaves the cursor on the first non-blank of the line now there, or of the last line; c c leaves one line break and the bar at the line's start; y y leaves the cursor; and the counts of 2 d 3 d multiply"
      run :=
        operatorRows
          [.rests "ab\n  cd\n|ef\n  gh" "d d" "ab\n  cd\n  |gh" (linewise "ef\n"),
            .rests "a\n|b" "d d" "|a" (linewise "b\n"),
            .rests "a\n|b\n" "d d" "|a\n" (linewise "b\n"),
            .rests "|a\n" "d d" "|" (linewise "a\n"),
            .rests "|ab\ncd\nef" "2 d d" "|ef" (linewise "ab\ncd\n"),
            .rests "ab\n|cd\nef" "3 d d" "|ab" (linewise "cd\nef\n"),
            .inserts "ab\n c|d\nef" "c c" "ab\n|\nef" (linewise " cd\n"),
            .inserts "ab\n c|d\nef" "2 c c" "ab\n|" (linewise " cd\nef\n"),
            .inserts "ab\n|cd" "c c" "ab\n|" (linewise "cd\n"),
            .rests "ab\nc|d\nef" "y y" "ab\nc|d\nef" (linewise "cd\n"),
            .rests "ab\nc|d" "y y" "ab\nc|d" (linewise "cd\n"),
            .rests "ab\nc|d\nef" "2 y y" "ab\nc|d\nef" (linewise "cd\nef\n"),
            .rests "ab\nc|d\nef" "5 y y" "ab\nc|d\nef" (linewise "cd\nef\n"),
            .rests "|a\nb\nc\nd\ne\nf" "2 d 3 d" "|" (linewise "a\nb\nc\nd\ne\nf\n")] },
    { name :=
        "a doubled operator with a count above 1 on the last line is cancelled, as Vim cancels it, there being no line below to go to: 2 d d, 2 c c and 2 y y there, with and without a final line feed, in a text of one line and in the empty text, leave the text, the cursor and the register as they were and the view in normal state, and so do a count inside the operator, counts that multiply, a count past the text and a named register; counts of 1 do not fail, and from a line above a count past the text stops at the last line; the echo area says the sentence the function makes, and the register a cancelled operator named holds nothing"
      run := do
        let held ←
          operatorRows
              [.givesUp "ab\ncd\n|ef" "2 d d", .givesUp "ab\ncd\n|ef" "2 c c",
                .givesUp "ab\ncd\n|ef" "2 y y", .givesUp "ab\ncd\ne|f\n" "2 d d",
                .givesUp "ab\ncd\ne|f\n" "2 c c", .givesUp "ab\ncd\ne|f\n" "2 y y",
                .givesUp "a|b" "2 d d", .givesUp "a|b" "2 c c", .givesUp "a|b" "2 y y",
                .givesUp "a|b\n" "2 d d", .givesUp "a|b\n" "2 c c", .givesUp "a|b\n" "2 y y",
                .givesUp "|" "2 d d", .givesUp "|" "2 c c", .givesUp "|" "2 y y",
                .givesUp "ab\ncd\n  e|f" "d 2 d", .givesUp "ab\ncd\n  e|f" "c 2 c",
                .givesUp "ab\ncd\n  e|f" "y 2 y", .givesUp "ab\ncd\n|ef" "2 d 3 d",
                .givesUp "ab\ncd\n|ef" "2 c 3 c", .givesUp "ab\ncd\n|ef" "2 y 3 y",
                .givesUp "ab\ncd\n|ef" "9 d d", .givesUp "ab\ncd\ne|f\n" "9 c c",
                .givesUp "a|b" "9 y y", .givesUp "ab\ncd\n|ef" "\" a 2 d d",
                .rests "ab\ncd\n|ef" "1 d 1 d" "ab\n|cd" (linewise "ef\n"),
                .rests "ab\ncd\ne|f\n" "1 d 1 d" "ab\n|cd\n" (linewise "ef\n"),
                .rests "ab\n|cd\nef\n" "9 d d" "|ab\n" (linewise "cd\nef\n"),
                .inserts "ab\n|cd\nef" "9 c c" "ab\n|" (linewise "cd\nef\n"),
                .rests "ab\n|cd\nef\n" "9 y y" "ab\n|cd\nef\n" (linewise "cd\nef\n")]
        return held &&
            evilGaveUp (evilEdited "ab\ncd\n|ef" "2 d d") "ab\ncd\n|ef" Evil.noLineBelow &&
            (evilEdited "ab\ncd\n|ef" "2 c c").map (·.echo) ==
              some s!"{Vim.operateCommand}: {Evil.noLineBelow}" &&
            ((evilRegistered "ab\ncd\n|ef").map fun driver =>
                (evilFed driver "\" a 2 d d").loop.state.register? "a") ==
              some none },
    { name :=
        "in the empty text d and c change neither the text nor the register, c still begins an insert, and y y yanks one line break, line-wise; and the counts before and after an operator multiply: 2 d 3 w deletes six words"
      run :=
        operatorRows
          [.rests "|" "d d" "|" asItWas, .inserts "|" "c c" "|" asItWas,
            .rests "|" "d G" "|" asItWas, .inserts "|" "c G" "|" asItWas,
            .rests "|" "d w" "|" asItWas, .inserts "|" "c $" "|" asItWas,
            .rests "|" "y y" "|" (linewise "\n"),
            .rests "|a b c d e f g" "2 d 3 w" "|g" (charwise "a b c d e f ")] },
    { name :=
        "d ^ on a line of blanks only deletes from the cursor up to the line's last blank, and nothing from the last blank; d h at a line's start and d l on an empty line delete nothing and leave the register as it was"
      run :=
        operatorRows
          [.rests "|   " "d ^" "| " (charwise "  "), .rests "  | " "d ^" "  | " asItWas,
            .rests "|abc" "d h" "|abc" asItWas, .rests "ab\n|abc" "d h" "ab\n|abc" asItWas,
            .rests "ab\n|\ncd" "d l" "ab\n|\ncd" asItWas] },
    { name :=
        "over no cell a yank empties the register and leaves the cursor, and a change leaves the register as it was and begins an insert where the cursor is: y h and c h at a line's start, y l and c l on an empty line"
      run :=
        operatorRows
          [.rests "|abc" "y h" "|abc" (charwise ""), .inserts "|abc" "c h" "|abc" asItWas,
            .rests "ab\n|abc" "y h" "ab\n|abc" (charwise ""),
            .inserts "ab\n|abc" "c h" "ab\n|abc" asItWas,
            .rests "ab\n|\ncd" "y l" "ab\n|\ncd" (charwise ""),
            .inserts "ab\n|\ncd" "c l" "ab\n|\ncd" asItWas] },
    { name :=
        "$ under an operator: c 2 $ from a line's start takes the cells through the end of the line below; on an empty line c $ empties the register where d $ leaves it, and in the empty text c $ leaves it too; with a count above 1 on the last line the motion fails and the operator gives up, with and without a final line feed"
      run := do
        let held ←
          operatorRows
              [.inserts "|ab\ncd\nef" "c 2 $" "|\nef" (charwise "ab\ncd"),
                .rests "ab\n|\ncd" "d $" "ab\n|\ncd" asItWas,
                .inserts "ab\n|\ncd" "c $" "ab\n|\ncd" (charwise ""), .inserts "" "c $" "|" asItWas,
                .givesUp "ab\n|cd" "d 2 $", .givesUp "ab\n|cd" "c 2 $", .givesUp "ab\n|cd" "y 2 $",
                .givesUp "ab\n|cd\n" "d 2 $", .rests "ab\n|cd\n" "d 1 $" "ab\n|\n" (charwise "cd")]
        -- The sentence is the one the function makes of the motion's name.
        return held &&
            evilGaveUp (evilEdited "ab\n|cd" "d 2 $") "ab\n|cd"
              (Evil.cannotMove Evil.lineEnd.name) },
    { name :=
        "e and b under an operator: d e on a text's last character takes it, and d 2 e takes through the second word's end; a backward motion that stops at a line's start takes the whole line before when it starts at or before its own line's first non-blank, with d, y and c, and otherwise stops where the line before ends; d 3 b with one word before the cursor takes it; at the text's start b fails and the operator gives up"
      run := do
        let held ←
          operatorRows
              [.rests "ab|c\n" "d e" "a|b\n" (charwise "c"),
                .rests "a|b c" "d 2 e" "|a" (charwise "b c"),
                .rests "foo\n|bar" "d b" "|bar" (linewise "foo\n"),
                .rests "foo\n|bar" "y b" "|foo\nbar" (linewise "foo\n"),
                .inserts "foo\n|bar" "c b" "|\nbar" (linewise "foo\n"),
                .rests "abc foo\n|bar" "d b" "abc| \nbar" (charwise "foo"),
                .rests "foo\n  |bar" "d b" "|bar" (charwise "foo\n  "),
                .rests "ab |cd" "d 3 b" "|cd" (charwise "ab "), .givesUp "|abc" "d b",
                .givesUp "|abc" "c b", .givesUp "|abc" "y B", .givesUp "|" "d b"]
        return held &&
            evilGaveUp (evilEdited "|abc" "d b") "|abc" (Evil.cannotMove Evil.wordBackward.name) },
    { name :=
        "w under d and y: the last word of a line is taken with the blanks after it and not the line break, with a count that ends there too; a count that ends on a later line takes up to that word; from an empty line the stretch is that line, whole; at the text's end the last word is taken, with and without a final line feed, and a count past the text takes what there is"
      run :=
        operatorRows
          [.rests "one |two\nthree" "d w" "one| \nthree" (charwise "two"),
            .rests "|two\nthree" "d w" "|\nthree" (charwise "two"),
            .rests "|foo   \nbar" "d w" "|\nbar" (charwise "foo   "),
            .rests "foo|   \nbar" "d w" "fo|o\nbar" (charwise "   "),
            .rests "|foo\n  bar" "d w" "|\n  bar" (charwise "foo"),
            .rests "|one two\nthree" "d 2 w" "|\nthree" (charwise "one two"),
            .rests "|one\ntwo three" "d 2 w" "|three" (charwise "one\ntwo "),
            .rests "foo |bar\nbaz" "y w" "foo |bar\nbaz" (charwise "bar"),
            .rests "a b |c" "d w" "a b| " (charwise "c"),
            .rests "a b |c\n" "d w" "a b| \n" (charwise "c"),
            .rests "a |b c\nd" "d 9 w" "a| " (charwise "b c\nd"),
            .rests "x |foo.bar\nbaz" "d W" "x| \nbaz" (charwise "foo.bar"),
            .rests "ab\n|\nfoo" "d w" "ab\n|foo" (linewise "\n"),
            .rests "|one\n\nthree" "d 2 w" "|three" (linewise "one\n\n"),
            .rests "x |one\n\nthree" "d 2 w" "x| \nthree" (charwise "one\n")] },
    { name :=
        "Vi's rule for a deletion over lines: cells that start at or before their line's first non-blank, stop on a later line and have only blanks after them on it are whole lines for d, and cells for y; from past the indent they are cells for d too"
      run :=
        operatorRows
          [.rests "|one\ntwo\nthree" "d 3 w" "|" (linewise "one\ntwo\nthree\n"),
            .rests "|one\ntwo\nthree" "y 3 w" "|one\ntwo\nthree" (charwise "one\ntwo\nthree"),
            .rests "|ab\ncd\nef" "d 2 $" "|ef" (linewise "ab\ncd\n"),
            .rests "a|b\ncd\nef" "d 2 $" "|a\nef" (charwise "b\ncd"),
            .rests "|ab\n  cd  \nef" "d 2 e" "|ef" (linewise "ab\n  cd  \n"),
            .rests "ab\n|\ncd" "d e" "|ab" (linewise "\ncd\n"),
            .rests "  |ab\n\tcd \t\nef\n" "d 2 $" "|ef\n" (linewise "  ab\n\tcd \t\n")] },
    { name :=
        "c w on a cell that is not a blank changes to the end of the word, where d w takes the blanks after it too: the word under the cursor counts as the first of a count, also from its last character; a run of punctuation and a WORD are changed whole; on a blank c w is d w; the last word of a line is changed up to the line break; on an empty line the line is changed"
      run :=
        operatorRows
          [.inserts "foo |bar baz" "c w" "foo | baz" (charwise "bar"),
            .rests "foo |bar baz" "d w" "foo |baz" (charwise "bar "),
            .inserts "foo ba|r baz" "c w" "foo ba| baz" (charwise "r"),
            .inserts "foo |bar baz qux" "c 2 w" "foo | qux" (charwise "bar baz"),
            .inserts "foo ba|r baz qux" "c 2 w" "foo ba| qux" (charwise "r baz"),
            .inserts "foo |.,bar" "c w" "foo |bar" (charwise ".,"),
            .inserts "foo |b.r baz" "c W" "foo | baz" (charwise "b.r"),
            .inserts "foo|   bar" "c w" "foo|bar" (charwise "   "),
            .inserts "foo|\t bar" "c w" "foo|bar" (charwise "\t "),
            .inserts "foo |bar\nbaz" "c w" "foo |\nbaz" (charwise "bar"),
            .inserts "ab\n|\ncd" "c w" "ab\n|\ncd" (linewise "\n")] },
    { name :=
        "j and k under an operator take whole lines: on the last line j fails and on the first k does, and the operator gives up; a count past the text stops at the last line and does not fail"
      run := do
        let held ←
          operatorRows
              [.givesUp "ab\n|cd" "d j", .givesUp "ab\n|cd" "c j", .givesUp "|ab\ncd" "d k",
                .givesUp "ab\n|cd\n" "y j",
                .rests "ab\n|cd\nef" "d 5 j" "|ab" (linewise "cd\nef\n"),
                .rests "ab\ncd\n|ef" "y 5 k" "|ab\ncd\nef" (linewise "ab\ncd\nef\n")]
        return held &&
            evilGaveUp (evilEdited "ab\n|cd" "d j") "ab\n|cd" (Evil.cannotMove Evil.down.name) &&
            evilGaveUp (evilEdited "|ab\ncd" "d k") "|ab\ncd" (Evil.cannotMove Evil.up.name) },
    { name :=
        "a line-wise deletion leaves the text ending the way it ended: to a last line that ends in a line feed the lines go with their line breaks, to one that does not the line break before the first goes instead, and deleting every line leaves the empty text; a line-wise register of a last line with no line feed ends in a line feed all the same"
      run :=
        operatorRows
          [.rests "ab\n|cd\n" "d G" "|ab\n" (linewise "cd\n"),
            .rests "ab\n|cd" "d G" "|ab" (linewise "cd\n"),
            .rests "|ab\ncd" "d G" "|" (linewise "ab\ncd\n"),
            .rests "|ab\ncd\n" "d G" "|" (linewise "ab\ncd\n"),
            .rests "ab\nc|d" "y G" "ab\n|cd" (linewise "cd\n"),
            .inserts "ab\nc|d" "c G" "ab\n|" (linewise "cd\n")] },
    { name :=
        "in a buffer whose lines end in a carriage return and line feed, a line-wise register of a last line with no line break ends in that, and the deletion takes the whole line break before the line"
      run :=
        pure <|
          let start : TextM EditorState := do
            let state ← evilState "ab\r\ncd" 4
            return { state with
                buffers := state.buffers.map (·.map ({ · with lineEnding := .crlf })) }
          match (Loop.Driver.over evilHanded (fun _ => none) start editorModel).toOption with
          | none => false
          | some driver =>
            let deleted := evilFed driver "d G"
            evilShown deleted == "|ab" &&
              deleted.loop.state.register? Evil.unnamed == linewise "cd\r\n" },
    { name :=
        "a departure from Vim, recorded: a cursor cannot rest in the empty last row. d $ on the only word of the last line of a text with no final line feed leaves the text Vim writes, and the cursor on the line above, where Vim's is on the emptied line"
      run := operatorRows [.rests "ab\n|cd" "d $" "a|b\n" (charwise "cd")] },
    { name :=
        "a motion that fails after it moved cancels the operator and leaves the cursor where it got to, as Vim does: when b or B with a count comes to rest on an empty first line with steps left over, the cursor is on that line, nothing is deleted, changed or yanked, the register is as it was, and the view is in normal state; the echo area says the sentence the function makes of the motion's name"
      run := do
        let held ←
          operatorRows
              [.breaksOff "\nab |cd" "d 3 b" "|\nab cd", .breaksOff "\nab |cd" "c 3 B" "|\nab cd",
                .breaksOff "\nab |cd" "y 3 b" "|\nab cd", .breaksOff "\nab |cd" "d 3 B" "|\nab cd",
                .breaksOff "\nab |cd" "c 3 b" "|\nab cd", .breaksOff "\nab |cd" "y 3 B" "|\nab cd",
                .breaksOff "\n|ab" "d 2 b" "|\nab", .breaksOff "\n\nab |cd" "d 9 b" "|\n\nab cd",
                .breaksOff "\nab |cd\n" "d 3 b" "|\nab cd\n",
                -- With no step left over the motion has not failed.
                .rests "\nab |cd" "d 2 b" "|cd" (charwise "\nab "),
                .rests " a|b" "d 2 b" "|b" (charwise " a"), .givesUp "|\nab" "d b"]
        return held &&
            (evilEdited "\nab |cd" "d 3 b").map (·.echo) ==
              some s!"{Vim.operateCommand}: {Evil.cannotMove Evil.wordBackward.name}" &&
            (evilEdited "\nab |cd" "c 3 B").map (·.echo) ==
              some s!"{Vim.operateCommand}: {Evil.cannotMove Evil.bigwordBackward.name}" &&
            -- The cursor a cancelled c leaves is one range of normal state's
            -- shape, and the window keeps no wanted column: k kept one.
            ((evilDriver "\nab cd\ne|f").map fun driver =>
                let moved := evilFed driver "k"
                let broke := evilFed moved "c 3 b"
                (((moved.loop.state.window? ⟨0⟩).bind (·.wanted)).isSome,
                  (broke.loop.state.window? ⟨0⟩).bind (·.wanted), evilSelection broke)) ==
              some
                (true, none, some { ranges := #[⟨0, 0⟩], shape := (vimDefaultReport "").shape }) },
    { name :=
        "the other motions under an operator with a count they cannot go the whole way of, as Vim has them: w, W, e and E at the text's end take what there is and do not fail, with and without a final line feed; h and l take the cells there are on the line, and none at a line's start or on an empty line; j and k with a count past the text stop at the last line and at the first, and $ at the last line's end; on the last line j and a counted $ fail, and on the first k does, each where it is, so the operator gives up with nothing moved"
      run :=
        operatorRows
          [.rests "ab |cd" "d 3 w" "ab| " (charwise "cd"),
            .rests "ab c|d" "d 3 w" "ab |c" (charwise "d"),
            .rests "ab |cd\n" "d 3 w" "ab| \n" (charwise "cd"),
            .inserts "ab |cd" "c 3 w" "ab |" (charwise "cd"),
            .rests "ab |cd" "y 3 w" "ab |cd" (charwise "cd"),
            .rests "ab |cd" "d 3 W" "ab| " (charwise "cd"),
            .inserts "ab c|d" "c 3 W" "ab c|" (charwise "d"),
            .rests "ab |cd\n" "y 3 W" "ab |cd\n" (charwise "cd"),
            .rests "ab |cd" "d 3 e" "ab| " (charwise "cd"),
            .rests "ab c|d" "d 3 e" "ab |c" (charwise "d"),
            .rests "ab |cd\n" "d 3 e" "ab| \n" (charwise "cd"),
            .inserts "ab |cd" "c 3 e" "ab |" (charwise "cd"),
            .rests "ab c|d" "y 3 e" "ab c|d" (charwise "d"),
            .rests "ab |cd" "d 3 E" "ab| " (charwise "cd"),
            .inserts "ab c|d" "c 3 E" "ab c|" (charwise "d"),
            .rests "ab |cd\n" "y 3 E" "ab |cd\n" (charwise "cd"),
            .rests "ab c|d\n" "d 2 w" "ab |c\n" (charwise "d"),
            .rests "ab c|d\n" "d 2 e" "ab |c\n" (charwise "d"),
            .rests "a|bcd" "d 3 h" "|bcd" (charwise "a"),
            .rests "ab\n|cd" "d 3 h" "ab\n|cd" asItWas,
            .inserts "ab\n|cd" "c 3 h" "ab\n|cd" asItWas,
            .rests "ab\nc|d" "y 3 h" "ab\n|cd" (charwise "c"),
            .rests "ab|cd\nef" "d 5 l" "a|b\nef" (charwise "cd"),
            .rests "abc|d\nef" "d 3 l" "ab|c\nef" (charwise "d"),
            .inserts "ab|cd\nef" "c 5 l" "ab|\nef" (charwise "cd"),
            .rests "ab|cd\nef" "y 5 l" "ab|cd\nef" (charwise "cd"),
            .rests "ab\n|\ncd" "d 3 l" "ab\n|\ncd" asItWas,
            .rests "ab\n|cd\nef" "d 3 j" "|ab" (linewise "cd\nef\n"),
            .givesUp "ab\ncd\n|ef" "d 3 j", .givesUp "ab\ncd\n|ef" "c 3 j",
            .givesUp "ab\ncd\ne|f" "y 3 j",
            .rests "ab\n|cd\nef" "d 3 k" "|ef" (linewise "ab\ncd\n"),
            .givesUp "|ab\ncd\nef" "d 3 k", .givesUp "a|b\ncd" "c 3 k",
            .rests "ab\nc|d" "y 3 k" "a|b\ncd" (linewise "ab\ncd\n"),
            .rests "a|b\ncd\nef" "d 3 $" "|a" (charwise "b\ncd\nef"),
            .rests "ab\nc|d\nef" "d 3 $" "ab\n|c" (charwise "d\nef"),
            .givesUp "ab\ncd\ne|f" "d 3 $", .givesUp "ab\ncd\n|ef" "c 3 $"] },
    { name :=
        "a change and the text typed after it are one step of the history: c l deletes the cell and leaves its group open, the typed text joins it, <Escape> closes it as one node, and one undo request gives the text from before the change"
      run :=
        pure <|
          match evilDriver "a|bc" with
          | none => false
          | some driver =>
            let changed := evilFed driver "c l"
            let typed := evilFed changed "X Y"
            let ended := evilFed typed "<Escape>"
            evilHistory changed == some (1, true) && evilShown changed == "a|c" &&
              evilHistory typed == some (1, true) &&
              evilShown typed == "aXY|c" &&
              evilHistory ended == some (2, false) &&
              evilShown ended == "aX|Yc" &&
              evilText (evilUndone ended) == some "abc" },
    { name :=
        "a change begins an insert only when a key that enters insert state runs it: operate with the operator change, run by its name in normal state, deletes the cell into the register and leaves the cursor resting there, in normal state"
      run :=
        pure <|
          evilOperated "a|bc"
                [.str Evil.change.name, .str "motion", .str Evil.right.name, .nat 0, .str ""] ==
              some ⟨"a|c", charwise "b", false, ""⟩ &&
            evilOperated "ab|c"
                [.str Evil.change.name, .str "motion", .str Evil.right.name, .nat 0, .str ""] ==
              some ⟨"a|b", charwise "c", false, ""⟩ &&
            evilOperated "a|bc"
                [.str Evil.yank.name, .str "motion", .str Evil.right.name, .nat 2, .str ""] ==
              some ⟨"a|bc", charwise "bc", false, ""⟩ },
    { name :=
        "operate gives up, with the sentence its function makes and nothing changed, when it names an operator no entry has, a motion no entry has, a text object, a kind there is none of, and when its arguments are not an operator's"
      run :=
        pure <|
          let operated (arguments : List Argument) := evilOperated "a|bc" arguments
          evilGaveUp (operated [.str "frob", .str "motion", .str Evil.right.name, .nat 0, .str ""])
              "a|bc" (Evil.noSuchOperator "frob") &&
            evilGaveUp
              (operated [.str Evil.delete.name, .str "motion", .str "nowhere", .nat 0, .str ""])
              "a|bc" (Evil.noSuchMotion "nowhere") &&
            evilGaveUp
              (operated [.str Evil.delete.name, .str "text-object", .str "word", .nat 0, .str ""])
              "a|bc" Evil.noTextObject &&
            evilGaveUp (operated [.str Evil.delete.name, .str "sideways", .str "", .nat 0, .str ""])
              "a|bc" Evil.noOperatorNamed &&
            evilGaveUp (operated []) "a|bc" Evil.noOperatorNamed &&
            evilGaveUp (operated [.str Evil.delete.name, .str "motion"]) "a|bc"
              Evil.noOperatorNamed &&
            operated
                [.str Evil.delete.name, .str "motion", .str Evil.right.name, .nat 2, .str ""] ==
              some ⟨"|a", charwise "bc", false, ""⟩ },
    { name :=
        "an operator leaves the window with no wanted column: after j the window keeps one, and after d l it keeps none"
      run :=
        pure <|
          match evilDriver "ab|cd\nxyz\nabcd" with
          | none => false
          | some driver =>
            let wanted (driver : EvilDriver) := (driver.loop.state.window? ⟨0⟩).bind (·.wanted)
            let moved := evilFed driver "j"
            let deleted := evilFed moved "d l"
            (wanted moved).isSome && (wanted deleted).isNone &&
              evilShown deleted == "abcd\nx|y\nabcd" },
    { name :=
        "a deletion is one step of the history: after d l the buffer's tree has one node more and nothing pending, and one undo request gives the text from before it"
      run :=
        pure <|
          match evilDriver "a|bc" with
          | none => false
          | some driver =>
            let deleted := evilFed driver "d l"
            evilHistory driver == some (1, false) && evilHistory deleted == some (2, false) &&
              evilText deleted == some "ac" &&
              evilText (evilUndone deleted) == some "abc" }]

/-- The oracle table's rows for the operators over a visual selection: a
`v` selection is acted on through the cell under its head, and a `V`
selection as whole lines. -/
def selectionRows : List OperatorRow :=
  [.rests "foo |bar baz" "v w d" "foo |az" (charwise "bar b"),
    .rests "foo |bar baz" "v w y" "foo |bar baz" (charwise "bar b"),
    .inserts "foo |bar baz" "v w c" "foo |az" (charwise "bar b"),
    .rests "foo bar |baz" "v b y" "foo |bar baz" (charwise "bar b"),
    .rests "a|bc\ndef" "v $ d" "a|def" (charwise "bc\n"),
    .rests "a|bc\ndef\nghi" "v j d" "a|f\nghi" (charwise "bc\nde"),
    .rests "ab\n|\ncd" "v d" "ab\n|cd" (charwise "\n"),
    .rests "ab\nc|d\n" "v $ d" "ab\n|c\n" (charwise "d"), .rests "ab\n|\n" "v d" "ab\n|\n" asItWas,
    .rests "abc\nd|ef\nghi" "V d" "abc\n|ghi" (linewise "def\n"),
    .rests "abc\nd|ef\nghi" "V y" "abc\n|def\nghi" (linewise "def\n"),
    .rests "abc\nd|ef\nghi" "V j y" "abc\n|def\nghi" (linewise "def\nghi\n"),
    .rests "abc\nd|ef\nghi" "V k y" "a|bc\ndef\nghi" (linewise "abc\ndef\n"),
    .rests "abc\nd|ef\nghi" "V j d" "|abc" (linewise "def\nghi\n"),
    .rests "abc\n  d|ef\nghi\n  jkl" "V j d" "abc\n  |jkl" (linewise "  def\nghi\n"),
    .inserts "abc\nd|ef\nghi" "V c" "abc\n|\nghi" (linewise "def\n"),
    .inserts "abc\nd|ef\nghi" "V j c" "abc\n|" (linewise "def\nghi\n")]

/-- The checks of evil's operators over a visual selection
(`Editor/Evil/Operators.lean`), by key, as `evilOperatorChecks` are. -/
def evilSelectionChecks : List Check :=
  [{  name :=
        "d, c and y on a v selection act on the inclusive range, and on a V selection on whole lines: the text, the cursor and the unnamed register are Vim's, and the view is left in normal state, or in insert state for c"
      run := operatorRows selectionRows },
    { name :=
        "an operator's key leaves the visual state with one cursor: after it the selection is one range with both ends on the cursor, of normal state's shape, and a motion moves the cursor alone"
      run :=
        pure <|
          let normal := (vimDefaultReport "").shape
          let cursor (fixture typed : String) (head : Nat) : Bool :=
            (evilSelected fixture typed).map (fun (ranges, shape, _) => (ranges, shape)) ==
              some ([(head, head)], normal)
          cursor "foo |bar baz qux" "v w d" 4 && cursor "foo |bar baz qux" "v w y" 4 &&
            cursor "abc\nd|ef\nghi" "V j y" 4 &&
            cursor "abc\nd|ef\nghi" "V d" 4 &&
            cursor "foo |bar baz qux" "v w y w" 8 &&
            cursor "foo |bar baz qux" "v w c <Escape>" 3 },
    { name :=
        "a count typed before the operator of a visual selection changes nothing: the selection is what is acted on"
      run :=
        operatorRows
          [.rests "foo |bar baz" "v w 3 d" "foo |az" (charwise "bar b"),
            .rests "abc\nd|ef\nghi" "V 2 y" "abc\n|def\nghi" (linewise "def\n")] }]

/-- The keys the key string `typed` names, pressed from the text and the
cursor `fixture` says with the unnamed register holding a sentinel, on the
editor's models with the clipboard model `clipboard`: what they left, and
the text the clipboard model then holds. -/
def evilClipped (fixture typed : String) (clipboard : ClipboardModel := {}) :
    Option (EvilEdited × Option String) :=
  (evilRegistered fixture { editorModel with clipboard }).map fun driver =>
    let after := evilFed driver typed
    (evilLeft after, after.model.clipboard.held)

/-- A driver of the evil checks over a buffer holding `contents` whose lines
end in a carriage return and line feed (`Buffer.lineEnding`), with the
cursor at `head`, on the models `model`. -/
def evilCrlfDriver (contents : String) (head : Nat) (model : EditorModel := editorModel) :
    Option EvilDriver :=
  (Loop.Driver.over evilHanded (fun _ => none)
      (do
        let state ← evilState contents head
        return { state with buffers := state.buffers.map (·.map ({ · with lineEnding := .crlf })) })
      model).toOption

/-- The checks of evil's registers and of the commands that read and set
them without an operator's key (`Editor/Evil/Registers.lean`,
`Editor/Evil/Operators.lean`), by key, as `evilOperatorChecks` are. -/
def evilRegisterChecks : List Check :=
  [{  name :=
        "x deletes the cell under the cursor into the unnamed register and leaves the cursor on the cell that follows, or on the line's last cell when it deleted the last one; with a count it deletes that many cells and no further than the line's end; on an empty line it does nothing"
      run :=
        operatorRows
          [.rests "a|bc" "x" "a|c" (charwise "b"), .rests "ab|c" "x" "a|b" (charwise "c"),
            .rests "ab|c\ndef" "x" "a|b\ndef" (charwise "c"),
            .rests "a|bcde" "3 x" "a|e" (charwise "bcd"),
            .rests "a|bcde" "9 x" "|a" (charwise "bcde"),
            .rests "ab\n|\ncd" "x" "ab\n|\ncd" asItWas] },
    { name :=
        "x is d l: from the same text and cursor the two leave the same text, cursor and register, with no count and with one, and each is one step of the history"
      run :=
        pure <|
          ["a|bc", "ab|c", "ab|c\ndef", "ab\n|\ncd", "|", "a|é😀b\r\nc"].all
              (fun fixture =>
                (evilEdited fixture "x").isSome &&
                  evilEdited fixture "x" == evilEdited fixture "d l" &&
                  evilEdited fixture "3 x" == evilEdited fixture "d 3 l") &&
            ((evilDriver "a|bc").map fun driver => evilHistory (evilFed driver "x")) ==
              some (some (2, false)) },
    { name :=
        "a yank or a deletion that names the clipboard register writes the clipboard and sets the unnamed register too: \" + y w leaves the clipboard model holding the word, \" + d d the line with its line break, and \" + x the cell"
      run :=
        pure <|
          evilClipped "foo |bar baz" "\" + y w" ==
              some (⟨"foo |bar baz", charwise "bar ", false, ""⟩, some "bar ") &&
            evilClipped "ab\n|cd\nef" "\" + d d" ==
              some (⟨"ab\n|ef", linewise "cd\n", false, ""⟩, some "cd\n") &&
            evilClipped "a|bc" "\" + x" == some (⟨"a|c", charwise "b", false, ""⟩, some "b") },
    { name :=
        "naming the unnamed register is naming none: \" \" y w and y w leave the same, and the clipboard model holds what it held"
      run :=
        pure <|
          evilClipped "foo |bar baz" "\" \" y w" { held := some "before" } ==
              some (⟨"foo |bar baz", charwise "bar ", false, ""⟩, some "before") &&
            evilClipped "foo |bar baz" "y w" { held := some "before" } ==
              some (⟨"foo |bar baz", charwise "bar ", false, ""⟩, some "before") },
    { name :=
        "a register evil has none of gives the command up, with the sentence its function makes: nothing is yanked or deleted, a change begins no insert, and nothing is written to the clipboard"
      run :=
        pure <|
          !(Evil.noRegister "a").isEmpty &&
            evilGaveUp (evilEdited "foo |bar baz" "\" a y w") "foo |bar baz"
              (Evil.noRegister "a") &&
            evilGaveUp (evilEdited "foo |bar baz" "\" a c w") "foo |bar baz"
              (Evil.noRegister "a") &&
            evilGaveUp (evilEdited "foo |bar baz" "\" a d d") "foo |bar baz"
              (Evil.noRegister "a") &&
            evilGaveUp (evilEdited "foo |bar baz" "\" a x") "foo |bar baz" (Evil.noRegister "a") &&
            (evilClipped "foo |bar baz" "\" a y w").map (·.2) == some none },
    { name :=
        "with a clipboard that is not available, a yank that names it says so in the echo area, with the sentence its function makes, and the unnamed register holds the word"
      run :=
        pure <|
          !Evil.clipboardUnavailable.isEmpty &&
            evilClipped "foo |bar baz" "\" + y w" { available := false } ==
              some (⟨"foo |bar baz", charwise "bar ", false, Evil.clipboardUnavailable⟩, none) },
    { name :=
        "a yank that names the clipboard and takes no cell empties the unnamed register and writes nothing: the clipboard model holds what it held"
      run :=
        pure <|
          evilClipped "|abc" "\" + y h" { held := some "before" } ==
            some (⟨"|abc", charwise "", false, ""⟩, some "before") },
    { name :=
        "p and P put a character-wise register after and before the cursor's cell, count times, and leave the cursor on the last cell put, or on the first when the text holds a line break; on an empty line p puts at the cursor"
      run :=
        operatorRows
          [.rests "foo |bar baz" "y w p" "foo bbar| ar baz" (charwise "bar "),
            .rests "foo |bar baz" "y w P" "foo bar| bar baz" (charwise "bar "),
            .rests "|ab cd" "y w 2 p" "aab ab| b cd" (charwise "ab "),
            .rests "|ab cd\n\nef" "y w j p" "ab cd\nab| \nef" (charwise "ab "),
            .rests "|ab" "x p" "b|a" (charwise "a"),
            .rests "a|bc\ndef\nghi" "v j y p" "ab|bc\ndec\ndef\nghi" (charwise "bc\nde"),
            .rests "a|bc\ndef\nghi" "v j y P" "a|bc\ndebc\ndef\nghi" (charwise "bc\nde")] },
    { name :=
        "p and P put a line-wise register below and above the cursor's line, count times, and leave the cursor on the first non-blank of the first line put; below a last line with no line break the line break goes before the lines and their last one is left out"
      run :=
        operatorRows
          [.rests "ab\nc|d\nef" "y y p" "ab\ncd\n|cd\nef" (linewise "cd\n"),
            .rests "ab\nc|d\nef" "y y P" "ab\n|cd\ncd\nef" (linewise "cd\n"),
            .rests "ab\nc|d\nef" "y y 2 p" "ab\ncd\n|cd\ncd\nef" (linewise "cd\n"),
            .rests "ab\n  c|d\nef" "y y j p" "ab\n  cd\nef\n  |cd" (linewise "  cd\n"),
            .rests "ab\nc|d" "y y p" "ab\ncd\n|cd" (linewise "cd\n"),
            .rests "a|b\n" "y y p" "ab\n|ab\n" (linewise "ab\n"),
            .rests "|ab\ncd" "d d p" "cd\n|ab" (linewise "ab\n"),
            .rests "ab\n|cd" "d d P" "|cd\nab" (linewise "cd\n"),
            .rests "a|b" "y y 2 p" "ab\n|ab\nab" (linewise "ab\n")] },
    { name :=
        "a put from the clipboard register inserts what the clipboard model holds, character-wise for a text with no final line feed and line-wise for one that ends in one, and leaves the unnamed register as it was"
      run :=
        pure <|
          evilClipped "a|b" "\" + p" { held := some "XY" } ==
              some (⟨"abX|Y", asItWas, false, ""⟩, some "XY") &&
            evilClipped "a|b" "\" + P" { held := some "XY" } ==
              some (⟨"aX|Yb", asItWas, false, ""⟩, some "XY") &&
            evilClipped "a|b" "\" + p" { held := some "cd\n" } ==
              some (⟨"ab\n|cd", asItWas, false, ""⟩, some "cd\n") &&
            evilClipped "a|b\n" "\" + P" { held := some "  cd\n" } ==
              some (⟨"  |cd\nab\n", asItWas, false, ""⟩, some "  cd\n") },
    { name :=
        "a put with nothing to put gives up, with the sentence its function makes, and changes nothing: an unnamed register nothing was set in, one that holds the empty text, a clipboard that holds no text, and one that is not available; and a register evil has none of"
      run :=
        pure <|
          let unset :=
            (evilDriver "a|b").map fun driver =>
              let put := evilFed driver "p"
              (evilShown put, put.loop.state.echo.endsWith Evil.nothingToPut, evilHistory put)
          let emptied :=
            (evilEdited "|ab" "y h p").map fun left =>
              (left.shown, left.echo.endsWith Evil.nothingToPut)
          !Evil.nothingToPut.isEmpty && unset == some ("a|b", true, some (1, false)) &&
            emptied == some ("|ab", true) &&
            evilGaveUp ((evilClipped "a|b" "\" + p").map (·.1)) "a|b" Evil.nothingToPut &&
            evilGaveUp ((evilClipped "a|b" "\" + P" { available := false }).map (·.1)) "a|b"
              Evil.clipboardUnavailable &&
            evilGaveUp (evilEdited "a|b" "\" a p") "a|b" (Evil.noRegister "a") },
    { name :=
        "a put is one step of the history: after y w p the buffer's tree has one node more and nothing pending, and one undo request gives the text from before the put"
      run :=
        pure <|
          match evilDriver "|ab cd" with
          | none => false
          | some driver =>
            let put := evilFed driver "y w p"
            evilHistory put == some (2, false) && evilText put == some "aab b cd" &&
              evilText (evilUndone put) == some "ab cd" },
    { name :=
        "the name a command names the clipboard by when it will write it itself: a yank under that name sets the unnamed register and keeps the same text under the name, and writes nothing to the clipboard; a put under it puts what the clipboard holds; and it is no name a key types, being longer than one character"
      run :=
        pure <|
          let ran (fixture : String) (invocation : Invocation) (clipboard : ClipboardModel) :
            Option (EvilEdited × Option String × Option Register) :=
            (evilRegistered fixture { editorModel with clipboard }).map fun driver =>
              let after := (driver.stepped (driver.loop.invoke driver.handed invocation)).1
              (evilLeft after, after.model.clipboard.held,
                after.loop.state.register? Evil.clipboardLater)
          Evil.clipboardLater.length > 1 &&
            ran "foo |bar baz"
                { command := Vim.operateCommand
                  arguments :=
                    [.str Evil.yank.name, .str "motion", .str Evil.wordForward.name, .nat 0,
                      .str Evil.clipboardLater] }
                { held := some "before" } ==
              some (⟨"foo |bar baz", charwise "bar ", false, ""⟩, some "before", charwise "bar ") &&
            ran "a|b" { command := "put-after", arguments := [.nat 0, .str Evil.clipboardLater] }
                { held := some "XY" } ==
              some (⟨"abX|Y", asItWas, false, ""⟩, some "XY", none) },
    { name :=
        "in a buffer whose lines end in a carriage return and line feed, a line-wise put keeps that line break: y y p on a middle line puts the line below it, y y P above it, and below a last line with no line break the buffer's line break goes before the lines and their last one is left out whole, with a count too"
      run :=
        pure <|
          let put (contents : String) (head : Nat) (typed : String) :
            Option (String × Option Register) :=
            (evilCrlfDriver contents head).map fun driver =>
              let after := evilFed driver typed
              (evilShown after, after.loop.state.register? Evil.unnamed)
          put "ab\r\ncd" 5 "y y p" == some ("ab\r\ncd\r\n|cd", linewise "cd\r\n") &&
            put "ab\r\ncd\r\nef" 5 "y y p" == some ("ab\r\ncd\r\n|cd\r\nef", linewise "cd\r\n") &&
            put "ab\r\ncd" 5 "y y P" == some ("ab\r\n|cd\r\ncd", linewise "cd\r\n") &&
            put "ab\r\ncd" 5 "y y 2 p" == some ("ab\r\ncd\r\n|cd\r\ncd", linewise "cd\r\n") &&
            put "ab\r\n  cd" 6 "y y p" == some ("ab\r\n  cd\r\n  |cd", linewise "  cd\r\n") },
    { name :=
        "in such a buffer a put from the clipboard register of a text that ends in a carriage return and line feed is line-wise: below a middle line and above a line the text goes in as it is, and below a last line with no line break the buffer's line break goes first and the text's own is left out whole; a text that ends in a line feed alone is put below the last line after the buffer's line break"
      run :=
        pure <|
          let put (contents : String) (head : Nat) (typed held : String) : Option String :=
            (evilCrlfDriver contents head
                  { editorModel with clipboard := { held := some held } }).map
              fun driver => evilShown (evilFed driver typed)
          put "ab\r\ncd" 5 "\" + p" "xy\r\n" == some "ab\r\ncd\r\n|xy" &&
            put "ab\r\ncd" 0 "\" + p" "xy\r\n" == some "ab\r\n|xy\r\ncd" &&
            put "ab\r\ncd" 5 "\" + P" "xy\r\n" == some "ab\r\n|xy\r\ncd" &&
            put "ab\r\ncd" 5 "\" + p" "xy\n" == some "ab\r\ncd\r\n|xy" }]

/-- The checks of the two commands that open a line (`Evil.openBelow`,
`Evil.openAbove`), by key, as `evilOperatorChecks` are. -/
def evilOpenChecks : List Check :=
  [{  name :=
        "o opens an empty line below the cursor's line and O one above it, each with the bar on the new line in insert state and the register as it was; the text typed is on the new line, and <Escape> leaves the cursor on it"
      run :=
        operatorRows
          [.inserts "ab\nc|d\nef" "o" "ab\ncd\n|\nef" asItWas,
            .inserts "ab\nc|d\nef" "O" "ab\n|\ncd\nef" asItWas,
            .inserts "ab\nc|d" "o" "ab\ncd\n|" asItWas, .inserts "|ab" "O" "|\nab" asItWas,
            .rests "ab\nc|d\nef" "o X <Escape>" "ab\ncd\n|X\nef" asItWas,
            .rests "ab\nc|d\nef" "O X <Escape>" "ab\n|X\ncd\nef" asItWas,
            .rests "ab\nc|d\nef" "o <Escape>" "ab\ncd\n|\nef" asItWas] },
    { name :=
        "a departure from Vim, recorded: a cursor cannot rest in the empty last row. o and <Escape> on a last line with no line feed leaves the text Vim writes, and the cursor on the line above, where Vim's is on the new line"
      run := operatorRows [.rests "ab\nc|d" "o <Escape>" "ab\nc|d\n" asItWas] },
    { name :=
        "inside the session o began, the selection is one exclusive range on the new line and the status field is insert state's; a count before o or O changes nothing"
      run := do
        let held ←
          operatorRows
              [.rests "ab\nc|d\nef" "3 o X <Escape>" "ab\ncd\n|X\nef" asItWas,
                .rests "ab\nc|d\nef" "3 O X <Escape>" "ab\n|X\ncd\nef" asItWas]
        return held &&
            (evilScene "ab\nc|d\nef" "o").map (fun seen => (seen.selection, seen.status)) ==
              some
                ({ ranges := #[⟨6, 6⟩], shape := .exclusive },
                  (evilLooks "i").2.push
                    { text := Loop.modifiedMark, face := Loop.modifiedFace }) },
    { name :=
        "o and the text typed after it are one step of the history: o leaves its group open, <Escape> closes it as one node, and one undo request gives the text from before the o"
      run :=
        pure <|
          match evilDriver "ab\nc|d\nef" with
          | none => false
          | some driver =>
            let opened := evilFed driver "o"
            let ended := evilFed opened "X Y <Escape>"
            evilHistory opened == some (1, true) && evilHistory ended == some (2, false) &&
              evilText ended == some "ab\ncd\nXY\nef" &&
              evilText (evilUndone ended) == some "ab\ncd\nef" },
    { name :=
        "in a buffer whose lines end in a carriage return and line feed, the line break o and O insert is that"
      run :=
        pure <|
          ((evilCrlfDriver "ab\r\ncd" 5).map fun driver => evilShown (evilFed driver "o")) ==
              some "ab\r\ncd\r\n|" &&
            ((evilCrlfDriver "ab\r\ncd" 5).map fun driver => evilShown (evilFed driver "O")) ==
              some "ab\r\n|\r\ncd" },
    { name :=
        "o and O begin an insert only when a key that enters insert state runs them: open-below and open-above, run by name in normal state, open the line and leave the cursor resting on it, in normal state"
      run :=
        pure <|
          let ran (name : String) : Option EvilEdited :=
            (evilRegistered "ab\nc|d\nef").map fun driver =>
              evilLeft (driver.stepped (driver.loop.invoke driver.handed { command := name })).1
          ran "open-below" == some ⟨"ab\ncd\n|\nef", asItWas, false, ""⟩ &&
            ran "open-above" == some ⟨"ab\n|\ncd\nef", asItWas, false, ""⟩ }]

/-- One change of each kind, for the checks of `u` and `C-r`: the text and
the cursor it is made from, its keys, and the text and the cursor from
before the change's command, which is the fixture unless keys before the
change's own moved the cursor. -/
def undoRows : List (String × String × String) :=
  [("|a b c", "d w", "|a b c"), ("ab\n|cd\nef", "d d", "ab\n|cd\nef"),
    ("ab\nc|d\nef\ngh", "d j", "ab\nc|d\nef\ngh"),
    ("foo |bar baz", "c w X <Escape>", "foo |bar baz"),
    ("ab\nc|d\nef", "c c X <Escape>", "ab\nc|d\nef"), ("foo |bar baz", "v e d", "foo ba|r baz"),
    ("abc\nd|ef\nghi\njk", "V j d", "abc\ndef\ng|hi\njk"), ("a|bc", "x", "a|bc"),
    ("a|bcde", "3 x", "a|bcde"), ("foo |bar baz", "y w p", "foo |bar baz"),
    ("ab\nc|d\nef", "y y p", "ab\nc|d\nef"), ("ab\nc|d\nef", "y y P", "ab\nc|d\nef"),
    ("foo |bar baz", "y w P", "foo |bar baz"), ("ab\nc|d\nef", "o X <Escape>", "ab\nc|d\nef"),
    ("ab\nc|d\nef", "O X <Escape>", "ab\nc|d\nef")]

/-- The checks of evil's undo and redo (`Editor/Evil/Undo.lean`), by key,
on the loop's driver over the editor's models, under the Vim scheme that
ships with evil's commands. What `u` leaves is the phase's rule and not
Vim's, which leaves the cursor at the start of the changed text. -/
def evilUndoChecks : List Check :=
  [{  name :=
        "u after a change restores the text and the cursor from before the change's command, and C-r reapplies it, leaving the text and the cursor the change left: for d over a motion, lines and a selection, c with typed text, x, p, P, o and O"
      run := do
        let wrong :=
          undoRows.filterMap fun (fixture, typed, before) =>
            match evilDriver fixture with
            | none => some s!"no driver for {repr fixture}"
            | some driver =>
              let changed := evilFed driver typed
              let undone := evilFed changed "u"
              let redone := evilFed undone "C-r"
              if
                  evilText changed != evilText driver && evilShown undone == before &&
                    undone.loop.state.echo.isEmpty &&
                    evilShown redone == evilShown changed &&
                    redone.loop.state.echo.isEmpty then
                none
              else
                some
                  s!"{typed} from {repr fixture} left {repr (evilShown changed)}, u {repr (evilShown undone)} saying {repr undone.loop.state.echo}, C-r {repr (evilShown redone)} saying {repr redone.loop.state.echo}"
        unless wrong.isEmpty do
          throw (IO.userError ("; ".intercalate wrong))
        return true },
    { name :=
        "u after an insert session that typed text restores the text and leaves the cursor on the cell the insert began before, and C-r leaves the cursor where <Escape> left it"
      run :=
        pure <|
          evilKeys "a|bc" "i X Y <Escape> u" == "a|bc" &&
            evilKeys "a|bc" "a X Y <Escape> u" == "ab|c" &&
            evilKeys "a|bc" "i X Y <Escape> u C-r" == evilKeys "a|bc" "i X Y <Escape>" &&
            evilKeys "a|bc" "i X Y <Escape>" == "aX|Ybc" },
    { name :=
        "a count before u or C-r takes that many steps: 2 u takes two back, a count past the history stops at the first step, and 2 C-r takes two forward"
      run :=
        pure <|
          evilKeys "|abcd" "x x x" == "|d" && evilKeys "|abcd" "x x x 2 u" == "|bcd" &&
            evilKeys "|abcd" "x x x 9 u" == "|abcd" &&
            evilKeys "|abcd" "x x x 9 u 2 C-r" == "|cd" &&
            evilKeys "|abcd" "x x x 9 u 9 C-r" == "|d" },
    { name :=
        "u with nothing to undo and C-r with nothing to redo say so in the echo area, each with the sentence its function makes, and change nothing"
      run :=
        pure <|
          match evilDriver "a|bc" with
          | none => false
          | some driver =>
            let undone := evilFed driver "u"
            let redone := evilFed driver "C-r"
            !Evil.nothingToUndo.isEmpty && !Evil.nothingToRedo.isEmpty &&
              undone.loop.state.echo == Evil.nothingToUndo &&
              evilShown undone == "a|bc" &&
              evilHistory undone == evilHistory driver &&
              redone.loop.state.echo == Evil.nothingToRedo &&
              evilShown redone == "a|bc" &&
              (evilFed (evilFed driver "x u") "u").loop.state.echo == Evil.nothingToUndo },
    { name :=
        "u after a visual deletion leaves one range with equal ends at the selection's head, in normal state's shape"
      run :=
        pure <|
          (evilSelected "foo |bar baz" "v e d u").map (fun (ranges, shape, _) => (ranges, shape)) ==
            some ([(6, 6)], (vimDefaultReport "").shape) },
    { name :=
        "a step whose edits carried no selection is undone with the cursor rested where the selection's marker is: a command written here inserts at a position, and u after it leaves the cursor on the cell it was on"
      run :=
        pure <|
          let stamp : Config.Registration :=
            { name := "stamp"
              action := .call fun _ => discard <| (⟨0⟩ : BufferId).insertAt 0 "XY" }
          match evilDriver "ab|c" (evilHanded #[stamp]) with
          | none => false
          | some driver =>
            let stamped :=
              (driver.stepped (driver.loop.invoke driver.handed { command := "stamp" })).1
            evilShown stamped == "XYab|c" && evilShown (evilFed stamped "u") == "ab|c" },
    { name :=
        "after u and after C-r the window keeps no wanted column: j keeps one, and the u and the C-r after it leave none"
      run :=
        pure <|
          match evilDriver "ab|cd\nxyz\nabcd" with
          | none => false
          | some driver =>
            let wanted (driver : EvilDriver) := (driver.loop.state.window? ⟨0⟩).bind (·.wanted)
            let moved := evilFed driver "x j"
            let undone := evilFed moved "u"
            let again := evilFed (evilFed undone "j") "C-r"
            (wanted moved).isSome && (wanted undone).isNone && (wanted again).isNone }]

/-- The oracle table's rows for `.`: the keys, the text before with the
cursor as a bar, and the text after. A count before `.` replaces the
change's; a change with an insert session is replayed with the text typed
in it, and leaves the cursor where `<Escape>` would; a yank is not the last
change. -/
def repeatRows : List (String × String × String) :=
  [("d w .", "|a b c d e f", "|c d e f"), ("d w 3 .", "|a b c d e f g", "|e f g"),
    ("d w 3 . .", "|a b c d e f g h i", "|h i"), ("d 2 w 3 .", "|a b c d e f g", "|f g"),
    ("2 d d .", "|a\nb\nc\nd\ne", "|e"), ("x .", "|abcd", "|cd"), ("x 3 .", "|abcdefgh", "|efgh"),
    ("c w X Y <Escape> w .", "|foo bar baz", "XY X|Y baz"),
    ("c w X Y <Escape> w w .", "|foo bar baz", "XY bar X|Y"),
    ("c w X Y <Escape> w 2 .", "|foo bar baz qux", "XY X|Y qux"),
    ("c w <Escape> w .", "|foo bar baz", "|  baz"),
    ("c c X <Escape> j .", "|ab\ncd\nef", "X\n|X\nef"), ("o X <Escape> .", "|ab", "ab\nX\n|X"),
    ("O X <Escape> .", "|ab", "|X\nX\nab"), ("i X <Escape> .", "a|b", "a|XXb"),
    ("a X <Escape> .", "a|b", "abX|X"), ("A X <Escape> j .", "|ab\ncd", "abX\ncd|X"),
    ("I X <Escape> j .", "  a|b\n  cdef", "  Xab\n  |Xcdef"),
    ("I X <Escape> j $ .", "  a|b\n  cdef", "  Xab\n  |Xcdef"),
    ("y w P .", "|ab cd", "abab|  ab cd"), ("y y p .", "|ab", "ab\nab\n|ab"),
    ("d w y w .", "|a b c d", "|c d")]

/-- The checks of evil's dot repeat (`Editor/Evil/Repeat.lean`), by key, on
the loop's driver over the editor's models, under the Vim scheme that ships
with evil's commands. -/
def evilRepeatChecks : List Check :=
  [{  name :=
        ". replays the last change: after d w it deletes the next word, and after c w, typed text and <Escape> it makes the same change with the same text at the cursor; a count before it replaces the change's and is kept; x, the doubled operator, o, O, i, a, I, A, p and P are replayed, and a yank is not the last change"
      run := evilRows repeatRows },
    { name :=
        "a replayed change that itself gives up gives the replay up and changes nothing: after d j, G and . on the last line, where j fails, the text, the cursor, the register and the history are as they were, the view is in normal state, and the echo area says why under the repeat command's name; after c j, a text, <Escape> and G, . likewise, with no text inserted and the view left in normal state; and the change is still the last change, which . replays from the first line"
      run :=
        pure <|
          let said := s!"{Vim.repeatCommand}: {Evil.cannotMove Evil.down.name}"
          let steps (typed : String) : Option (Option (Nat × Bool)) :=
            (evilDriver "|ab\ncd\nef\ngh").map fun driver => evilHistory (evilFed driver typed)
          let status (typed : String) : Option (Array StatusField) :=
            (evilScene "|ab\ncd\nef\ngh" typed).map (·.status)
          evilEdited "|ab\ncd\nef\ngh" "d j G" ==
              some ⟨"ef\n|gh", linewise "ab\ncd\n", false, ""⟩ &&
            evilEdited "|ab\ncd\nef\ngh" "d j G ." ==
              some ⟨"ef\n|gh", linewise "ab\ncd\n", false, said⟩ &&
            steps "d j G ." == steps "d j G" &&
            status "d j G ." == status "d j G" &&
            evilEdited "|ab\ncd\nef\ngh" "c j X <Escape> G" ==
              some ⟨"X\nef\n|gh", linewise "ab\ncd\n", false, ""⟩ &&
            evilEdited "|ab\ncd\nef\ngh" "c j X <Escape> G ." ==
              some ⟨"X\nef\n|gh", linewise "ab\ncd\n", false, said⟩ &&
            steps "c j X <Escape> G ." == steps "c j X <Escape> G" &&
            steps "c j X <Escape> G" == some (some (2, false)) &&
            status "c j X <Escape> G ." == status "c j X <Escape> G" &&
            evilEdited "|ab\ncd\nef\ngh" "c j X <Escape> G . g g ." ==
              some ⟨"|X\ngh", linewise "X\nef\n", false, ""⟩ },
    { name :=
        "a replayed change with an insert session is one step of the history and leaves the view in normal state: after c w X Y <Escape> w . the tree has one node more and nothing pending, and one u takes the whole replay back, with the cursor where it was"
      run :=
        pure <|
          match evilDriver "|foo bar baz" with
          | none => false
          | some driver =>
            let changed := evilFed driver "c w X Y <Escape> w"
            let replayed := evilFed changed "."
            evilHistory changed == some (2, false) && evilHistory replayed == some (3, false) &&
              evilShown replayed == "XY X|Y baz" &&
              (evilSeen replayed).map (·.status) ==
                some
                  ((evilLooks "").2.push
                    { text := Loop.modifiedMark, face := Loop.modifiedFace }) &&
              evilShown (evilFed replayed "u") == "XY |bar baz" },
    { name :=
        ". with no change to repeat says nothing and changes nothing, and the repeat command run by its name, which is handed no change, gives up with the sentence its function makes"
      run :=
        pure <|
          let named :=
            (evilRegistered "a|bc").map fun driver =>
              evilLeft
                (driver.stepped
                    (driver.loop.invoke driver.handed { command := Vim.repeatCommand })).1
          evilEdited "a|bc" "." == some ⟨"a|bc", asItWas, false, ""⟩ &&
            evilEdited "a|bc" "y l ." == some ⟨"a|bc", charwise "b", false, ""⟩ &&
            evilGaveUp named "a|bc" Evil.nothingToRepeat },
    { name :=
        "what is not repeated gives the command up and changes nothing: a change over a visual selection, and a change whose command the registry has none of"
      run :=
        pure <|
          let unknown :=
            (evilRegistered "a|bc").map fun driver =>
              evilLeft
                (driver.stepped
                    (driver.loop.invoke driver.handed
                      { command := Vim.repeatCommand
                        arguments :=
                          [.bool false, .str "", .str "frobnicate", .nat 0, .str ""] })).1
          let selected :=
            (evilDriver "foo |bar baz qux").map fun driver =>
              let deleted := evilFed driver "v e d w"
              let repeated := evilFed deleted "."
              (evilShown deleted, evilShown repeated,
                repeated.loop.state.echo.endsWith (Evil.notRepeated Evil.overSelection),
                evilHistory deleted == evilHistory repeated)
          !(Evil.notRepeated "frobnicate").isEmpty &&
            evilGaveUp unknown "a|bc" (Evil.notRepeated "frobnicate") &&
            selected == some ("foo  |baz qux", "foo  |baz qux", true, true) },
    { name :=
        "a text committed in the session a change began is replayed with it: after c w, a committed text, <Escape> and w, . changes the next word to that text"
      run :=
        pure <|
          match evilDriver "|foo bar baz" with
          | none => false
          | some driver =>
            let changing := evilFed driver "c w"
            let committed := (changing.feed { event := .commit "かな", stamp := 0 }).1
            evilShown (evilFed committed "X <Escape> w .") == "かなX かな|X baz" },
    { name :=
        "an operator that a motion's failure cancelled is not the last change, whether or not the motion moved first, as in Vim: after x, a d 3 b that leaves the cursor on the empty first line, and w, . replays the x; and after x and a d j that fails on the last line, . replays the x"
      run :=
        pure <|
          evilEdited "\nab |cd ef" "x d 3 b w ." == some ⟨"\n|b d ef", charwise "a", false, ""⟩ &&
            evilEdited "\nab |cd ef" "x c 3 B w ." == some ⟨"\n|b d ef", charwise "a", false, ""⟩ &&
            evilEdited "ab\n|cde" "x d j ." == some ⟨"ab\n|e", charwise "d", false, ""⟩ },
    { name :=
        "a doubled operator that its count cancelled on the last line is not the last change, as in Vim: after x and then 2 d d, 2 c c, 2 y y or d 2 d on the last line, . replays the x"
      run :=
        pure <|
          evilEdited "ab\ncd\n|efg" "x 2 d d ." == some ⟨"ab\ncd\n|g", charwise "f", false, ""⟩ &&
            evilEdited "ab\ncd\n|efg" "x 2 c c ." == some ⟨"ab\ncd\n|g", charwise "f", false, ""⟩ &&
            evilEdited "ab\ncd\n|efg" "x 2 y y ." == some ⟨"ab\ncd\n|g", charwise "f", false, ""⟩ &&
            evilEdited "ab\ncd\n|efg\n" "x 2 d d ." ==
              some ⟨"ab\ncd\n|g\n", charwise "f", false, ""⟩ &&
            evilEdited "|abc" "x d 2 d ." == some ⟨"|c", charwise "b", false, ""⟩ },
    { name :=
        "a replayed doubled operator that comes to the last line with a count above 1 gives the replay up, as Vim cancels it: 2 d d and . on the one line left, 2 d d . . when the second replay is on the last line, d d, G and 2 ., and 2 c c, a text, <Escape>, j and . each leave the text, the cursor, the register and the history as they were and the view in normal state, with no text inserted, and the echo area says why under the repeat command's name; and the change is still the last change, which . replays from the first line, with the count it had and not the count of the replay that gave up"
      run :=
        pure <|
          let steps (fixture typed : String) : Option (Option (Nat × Bool)) :=
            (evilDriver fixture).map fun driver => evilHistory (evilFed driver typed)
          -- Whether the replay `replay`, typed after `typed`, gave up: what
          -- `typed` left is `shown` and `register`, and the replay left that
          -- and the history, and said why under the repeat command's name.
          let gaveUp (fixture typed replay shown : String) (register : Option Register) : Bool :=
            let after := typed ++ " " ++ replay
            match evilEdited fixture after with
            | some left =>
              evilEdited fixture typed == some ⟨shown, register, false, ""⟩ &&
                left.shown == shown &&
                left.register == register &&
                !left.insert &&
                left.echo == s!"{Vim.repeatCommand}: {Evil.noLineBelow}" &&
                steps fixture after == steps fixture typed
            | none => false
          gaveUp "|ab\ncd\nef" "2 d d" "." "|ef" (linewise "ab\ncd\n") &&
            gaveUp "|ab\ncd\nef\ngh\nij" "2 d d ." "." "|ij" (linewise "ef\ngh\n") &&
            gaveUp "ab\ncd\nef\n|gh" "d d G" "2 ." "ab\ncd\n|ef" (linewise "gh\n") &&
            gaveUp "|ab\ncd\nef" "2 c c X <Escape> j" "." "X\n|ef" (linewise "ab\ncd\n") &&
            evilEdited "|ab\ncd\nef\ngh\nij\nkl" "2 d d G . g g ." ==
              some ⟨"|ij\nkl", linewise "ef\ngh\n", false, ""⟩ &&
            evilEdited "|ab\ncd\nef\ngh" "2 c c X <Escape> G . g g ." ==
              some ⟨"|X\ngh", linewise "X\nef\n", false, ""⟩ &&
            -- The count of a replay that gave up is not kept.
            evilEdited "|ab\ncd\nef\ngh\nij" "d d G 2 . g g ." ==
              some ⟨"|ef\ngh\nij", linewise "cd\n", false, ""⟩ },
    { name :=
        "a replayed change whose motion fails after it moved breaks the replay off, as Vim does: the cursor is where the motion got to, in normal state, nothing is deleted or inserted, the register is the one the change left, the history has no step for it, and the change is still the last change"
      run :=
        pure <|
          let said := s!"{Vim.repeatCommand}: {Evil.cannotMove Evil.wordBackward.name}"
          let steps (fixture typed : String) : Option (Option (Nat × Bool)) :=
            (evilDriver fixture).map fun driver => evilHistory (evilFed driver typed)
          evilEdited "\nab cd |ef gh" "d 2 b ." ==
              some ⟨"|\nef gh", charwise "ab cd ", false, said⟩ &&
            evilEdited "\nab cd |ef gh" "c 2 b X <Escape> ." ==
              some ⟨"|\nXef gh", charwise "ab cd ", false, said⟩ &&
            steps "\nab cd |ef gh" "d 2 b ." == steps "\nab cd |ef gh" "d 2 b" &&
            steps "\nab cd |ef gh" "c 2 b X <Escape> ." ==
              steps "\nab cd |ef gh" "c 2 b X <Escape>" &&
            evilEdited "\nab cd ef |gh" "d 2 b $ . ." ==
              some ⟨"|\nh", charwise "ab g", false, said⟩ &&
            evilEdited "\nab cd |ef gh ij" "d 2 b . G $ ." ==
              some ⟨"\nef |j", charwise "gh i", false, ""⟩ },
    { name :=
        ". replays a change with the command the registry holds for its name, which is the one the change's own keys ran: with operate registered again over the operators that ship and one more, and a key bound to that operator, the key and w erase a word and . erases the next; with a command registered in place of delete-char that deletes two cells, x deletes two and . two more; and with one in place of append that inserts before the cursor, a, a text and <Escape> insert before it and . does again"
      run :=
        pure <|
          let erase : Vocabulary.Operator := { Evil.delete with name := "erase" }
          let more : Array Config.Registration :=
            #[{ name := Vim.operateCommand
                action := .call (Evil.operate (Evil.operators.push erase) Evil.motions) },
              { name := "delete-char"
                action :=
                  .call fun call => Evil.deleteChar { call with arguments := [.nat 2, .str ""] } },
              { name := "append", action := .call Evil.insert }]
          let handed : Loop.Keys Vim.Default.scheme :=
            { evilHanded more with
              maps := fun _ _ =>
                [Keymap.ofList [(keys "Z", Vim.Bound.operator { name := erase.name })]] }
          let typed (fixture keys : String) : Option (String × String) :=
            (evilDriver fixture handed).map fun driver =>
              let after := evilFed driver keys
              (evilShown after, after.loop.state.echo)
          typed "|a b c d" "Z w" == some ("|b c d", "") &&
            typed "|a b c d" "Z w ." == some ("|c d", "") &&
            typed "|abcdef" "x" == some ("|cdef", "") &&
            typed "|abcdef" "x ." == some ("|ef", "") &&
            typed "a|b" "a X <Escape>" == some ("a|Xb", "") &&
            typed "a|b" "a X <Escape> ." == some ("a|XXb", "") },
    { name :=
        "the repeat command handed its own name as the change gives up, with the sentence its function makes: a replay is no change"
      run :=
        pure <|
          let named :=
            (evilRegistered "a|bc").map fun driver =>
              evilLeft
                (driver.stepped
                    (driver.loop.invoke driver.handed
                      { command := Vim.repeatCommand
                        arguments :=
                          [.bool false, .str "", .str Vim.repeatCommand, .bool false, .str "",
                            .str "delete-char", .nat 0, .str ""] })).1
          evilGaveUp named "a|bc" (Evil.notRepeated Vim.repeatCommand) },
    { name :=
        "every command a default key of the Vim scheme is bound to as changing text is one evil registers, and so is the command an operator's keys run: . finds each in the registry"
      run :=
        pure <|
          let changing :=
            (Vim.Default.normalCommands ++ Vim.Default.insertCommands ++
                  Vim.Default.visualCommands ++
                  Vim.Default.visualLineCommands).filterMap
              fun (_, bound) =>
              match bound with
              | .command command => if command.changes then some command.name else none
              | _ => none
          !changing.isEmpty &&
            (Vim.operateCommand :: changing).all fun name => Evil.commands.any (·.name == name) },
    { name :=
        "a replayed change that names the clipboard register and began an insert session writes the clipboard as the replay's last request: run to its end it leaves the clipboard model holding the word it changed, and stopped by the interrupt before any one of its requests it is rolled back with the clipboard model holding what it held before"
      run :=
        pure <|
          match evilRegistered "|foo bar baz" with
          | none => false
          | some driver =>
            let changed := evilFed driver "\" + c w X <Escape> w"
            -- The replay with an interrupt key that arrives once it has made
            -- `asks` of its requests, or with none.
            let replayed (asks : Option Nat) : EvilEdited × Option String :=
              let after :=
                evilFed
                  { changed with
                    model :=
                      { changed.model with
                        watch := { changed.model.watch with arrivesAfter := asks } } }
                  "."
              (evilLeft after, after.model.clipboard.held)
            let before : EvilEdited × Option String :=
              (⟨"X |bar baz", charwise "foo", false, ""⟩, some "foo")
            let whole : EvilEdited × Option String :=
              (⟨"X |X baz", charwise "bar", false, ""⟩, some "bar")
            let stopped : EvilEdited × Option String :=
              ({ before.1 with echo := s!"{Vim.repeatCommand}: interrupted" }, some "foo")
            let runs := (List.range 80).map fun asks => replayed (some asks)
            (evilLeft changed, changed.model.clipboard.held) == before && replayed none == whole &&
              runs.all (fun run => run == stopped || run == whole) &&
              (runs.filter (· == stopped)).length > 8 &&
              runs.getLast? == some whole },
    { name :=
        "the clipboard a replayed change writes is the text the replay took, whatever the unnamed register held: where the clipboard model was set to another text since the change, and the word the replay changes is the one the unnamed register already holds, the replay writes that word; a replayed change that takes no cell writes nothing; and with a clipboard that is not available the replay runs to its end and says so in the echo area"
      run :=
        pure <|
          let replayed (fixture typed : String) (clipboard : ClipboardModel) :
            Option (EvilEdited × Option String) :=
            (evilRegistered fixture).map fun driver =>
              let changed := evilFed driver typed
              let after := evilFed { changed with model := { changed.model with clipboard } } "."
              (evilLeft after, after.model.clipboard.held)
          replayed "|foo foo baz" "\" + c w X <Escape> w" { held := some "other" } ==
              some (⟨"X |X baz", charwise "foo", false, ""⟩, some "foo") &&
            replayed "|ab\ncd" "\" + c h X <Escape> j" { held := some "other" } ==
              some (⟨"Xab\n|Xcd", asItWas, false, ""⟩, some "other") &&
            replayed "|foo bar baz" "\" + c w X <Escape> w" { available := false } ==
              some (⟨"X |X baz", charwise "bar", false, Evil.clipboardUnavailable⟩, none) &&
            replayed "|a b c d" "\" + d w" {} ==
              some (⟨"|c d", charwise "b ", false, ""⟩, some "b ") }]

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
    textModelStepChecks ++
    fileModelChecks ++
    sceneChecks ++
    displayChecks ++
    commandPortChecks ++
    watchChecks ++
    clipboardChecks ++
    guardChecks ++
    originChecks ++
    stateChecks ++
    stateRequestChecks ++
    loopChecks ++
    commitChecks ++
    keymapChecks ++
    keyNotationChecks ++
    invocationChecks ++
    exLineChecks ++
    schemeChecks ++
    schemeContractChecks ++
    dispatchChecks ++
    vimEditChecks ++
    vimRegistryChecks ++
    vimGrammarChecks ++
    vimStateChecks ++
    vimDefaultChecks ++
    vimContractChecks ++
    modeRecordChecks ++
    modeRegistryChecks ++
    modeDispatchChecks ++
    modeEnterChecks ++
    apiStateChecks ++
    driverChecks ++
    promptChecks ++
    fileCommandChecks ++
    dispatchQuitChecks ++
    exChecks ++
    evilRestChecks ++
    evilMotionChecks ++
    evilStateChecks ++
    evilInsertChecks ++
    evilOperatorChecks ++
    evilSelectionChecks ++
    evilRegisterChecks ++
    evilOpenChecks ++
    evilUndoChecks ++
    evilRepeatChecks

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

/-- The names of the watch port's contract properties that do not hold of
the watch model, each run from a model in which the property's interrupt
keys have arrived. -/
def watchFailures : IO (List String) := do
  let failed ←
    WatchContract.failures
        (fun property => pure (watched property.holds { arrived := property.arrived }).1)
        WatchContract.properties
  return failed.map (s!"the watch model: {·}")

/-- The names of the clipboard interface's contract properties that do not
hold of the clipboard model, each run from a model that is available and
holds nothing. -/
def clipboardFailures : IO (List String) := do
  let failed ←
    ClipboardContract.failures (fun property => pure (clipped property.holds).1)
        ClipboardContract.properties
  return failed.map (s!"the clipboard model: {·}")

/-- The names of the cases of the editor API (`Editor/Api/Cases.lean`) that
do not hold of the editor's models, each played from models with no
text. -/
def apiCaseFailures : IO (List String) := do
  let failed ← ApiCases.failures (fun play => pure (play.runModel editorModel).1) ApiCases.cases
  return failed.map (s!"the editor's models: {·}")

end ModelTest

/-- Runs the checks, then the text port's contract against its model, the
job port's contract against its model and against the runner over the fake
clock, the display interface's contract against its model, the watch
port's against its model, the clipboard interface's against its model and
the cases of the editor API on the editor's models: exits 0 when all hold,
and 1 after naming on stderr the ones that do not.

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
      (← ModelTest.displayFailures) ++
      (← ModelTest.watchFailures) ++
      (← ModelTest.clipboardFailures) ++
      (← ModelTest.apiCaseFailures)
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  unless failed.isEmpty do
    -- A check that failed may have left a task that never ends, and
    -- returning from `main` would wait for it for ever.
    IO.Process.exit 1
  IO.println
      s!"model-test: {ModelTest.checks.length} checks passed, {Editor.TextContract.properties.length + Editor.TextContract.adoptProperties.length + ModelTest.commandProperties.length} properties hold of the text model, {Editor.UndoTreeCases.cases.length} cases of the undo tree hold over it, and {Editor.JobContract.properties.length} properties of the job model and of the job runner over the fake clock, and {Editor.JobContract.fileProperties.length} file properties of the job model and of the job runner over the fake file service; {Editor.FileCases.cases.length} cases across the text port and the job port hold of the two models; {(Editor.DisplayContract.properties { advance := 1, lineHeight := 1 }).length} properties of the display interface hold of its model in cells of {ModelTest.displayCells.length} sizes; {Editor.WatchContract.properties.length} properties of the watch port hold of its model; {Editor.ClipboardContract.properties.length} properties of the clipboard interface hold of its model; {Editor.ApiCases.cases.length} cases of the editor API hold of the editor's models"
  (← IO.getStdout).flush
  IO.Process.exit 0
