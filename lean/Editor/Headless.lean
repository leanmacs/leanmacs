import Editor.Config.Directory
import Editor.Config.Elaborate
import Editor.Config.Reload
import Editor.Job.Jobs
import Editor.Job.Pool
import Editor.Job.Real
import Editor.Text.Real

/-!
# The headless host

The editor with no window: a loop on the editor queue that loads a config,
runs its commands against the Rust library and prints what happened, one line
at a time. It exists for integration tests, and it is the first runtime of
the config session.

## The loop

`start` runs the loop on a dedicated task: the editor thread. It pulls the
editor queue and handles one event to its end before the next. It owns the
config half of the editor's state (`Config.State`) and the table of texts
(`RealTexts`), feeds the reload reducer (`Config.step`) and performs its
effects, and runs commands with `EditorM.runReal`.

A reload does not run on the editor thread. The reducer's `start` effect
becomes a dedicated task, the reload job, which reads the source, elaborates
and runs `setup` (`Config.build`), resolves a promise with the outcome and
posts a wake-up to the editor queue. The editor thread meets the wake-up like
any event, takes the outcome and feeds it to the reducer: a config is
installed between two events, and the editor answers events while a chunk
elaborates. It is a dedicated task, not one of the pool's: it reads files.

It knows a request from its driver, the wake-up of a reload job, the wake-up
of a job that has ended, an event of the library's scripted source and quit,
and nothing else. It has no keys, keymaps, dispatch, scene or rollback: those
are the command loop's, which will replace this loop and call the same
operations of the reducer and of the job table.

The collaborators are handed in (`Collaborators`): the elaborator and the
source of the config session, `emit`, the port every line of output goes
through, and the services the loop's jobs wait on, which a test makes of a
fake clock.

## Jobs

The loop owns the job table (`Job.Jobs`, `Editor/Job/Jobs.lean`), so it is
the one thing that starts a job: a `spawn` request starts the job `setup`
registered under that name, for the owner that registered it. A command
cannot start one, and neither can `setup`.

- **A job runs on the pool**, and holds no thread while it waits
  (`Editor/Job/Runner.lean`). The editor thread goes on to its next event.
- **Its result comes back as a command.** When a job has ended, however it
  ended, the runner posts a wake-up to the editor queue from the job's
  thread, with the job's id. The outcome stays in the job's handle. The
  editor thread meets the wake-up in its turn, takes the result, and, for a
  job that finished, runs the command it finished with exactly as it runs
  any command. So a handler runs on the editor thread, between two events.
- **A reload that installs cancels the old config's jobs**: the reducer's
  `cancelJobs` effect, performed before the reload's report, takes the
  owner's jobs out of the table and cancels them. A wake-up one of them had
  already posted then finds nothing, and its handler never runs. A rejected
  reload cancels nothing.
- **The loop cancels every job when it ends**: nothing would deal with their
  results.

## One loop at a time

The editor queue is process-wide, so two live loops would take each other's
events: hosts in one process follow one another and never overlap. A host
posts under source ids it is given, and its loop ignores an event from a
Lean source it was not given, so a late event from an earlier host is
dropped. `stop` ends this loop only; quitting the queues is for the process
(`Ffi.quit`).

## What it prints

```
reload <n>: installed, <c> chunks, <k> commands
reload <n>: rejected
diagnostic: <source>:<line>:<column>: <severity>: <first line of the message>
run <name>: ok            (or "refused: <error>", or "no such command")
spawn <name>: job <id>    (or "no such job")
job <id> <name>: ok       (the handler's command ran; or "refused: <error>",
                           "failed: <first line of the message>", "cancelled")
event <source id> <code>  (an event from the library's scripted source)
commands: <names>
text <index>: <quoted text>
store <name> v<version>: <value>
```

The last three answer `show`, which lists commands, not jobs. A text is
never closed: the loop keeps one table of texts for its life, and `show`
lists them all. A diagnostic that is about no place in particular has the
position 0:0. A job's id is its number in this loop's table, from 1. A job
is `cancelled` when a reload that installs replaces the config that
registered it; a job that throws is `failed`.

## The driver, and the command line

A host is driven from another thread: `Host.send` posts a request,
`Host.settle` waits, with a bound, until the editor thread has handled
everything sent so far and no reload is running, `Host.join` waits the same
way until no job is running, and `Host.stop` ends the loop. Requests are
handled in the order they were sent, and a request sent while a reload runs
is handled before that reload is installed: settle first to see its effect.

`run` drives a host through a script, one directive a line: `reload`,
`run <name>`, `spawn <name>` and `show` are requests, and `settle` and `join`
are the driver's own. Blank lines and lines that start with `#` are skipped.

A script that cannot run to its end is data too. `Host.await` and `Host.join`
say what a wait came to (`Wait`): settled, or run out with a reload or a job
still running, or run out before the editor thread had handled everything
sent to it. `run` returns a `Failure` for a wait that did not settle, with
the line of the `settle` or the `join`, or with no line for the wait at the
end of the script and for a loop that did not stop.

`main` is the executable's headless mode,
`editor headless <sysroot> <olean dir> <config dir> <script file>`: `run`
with the real elaborator, a directory as the source, stdout as the output
and the library's timer service for the jobs, then the quit and the explicit
exit. Before the loop starts it warms the pool (`Editor/Job/Pool.lean`) and
starts the completion pump on a dedicated task (`Editor/Job/Real.lean`),
which the quit ends. Its exit status is 0 when the script ran to its end and
1 when it could not, and then it says why on stderr: the script cannot be
read, a wait ran out (after 30 seconds) with a reload or a job still
running, or the editor thread did not answer. A rejected reload is something
to print, not a failure, and so is a job that fails.

## Tests

`config-test` drives a host in-process on the real queue, the real text
binding and the real elaborator, and compares the lines it emits
(`ConfigTest.hostChecks`, `ConfigTest.threadChecks`), checks jobs on a fake
clock it moves, with the thread each line was emitted from
(`ConfigTest.jobChecks`), and checks the script reader and the driver
(`ConfigTest.scriptChecks`). The `ffi-test` task runs the real executable
once, on the fixture under `tests/headless`, which covers the command line,
the pump and the timer service: the fixture's job sleeps on the real clock.
-/

namespace Editor.Headless

/-- What a driver asks the editor thread to do. -/
inductive Request where
  /-- Reload the config from its source. -/
  | reload
  /-- Run the command called `name`. -/
  | run (name : String)
  /-- Print the commands, the texts and the stores. -/
  | «show»
  /-- Start the job registered under `name`. -/
  | spawn (name : String)
  deriving DecidableEq, Repr

/-- What a host needs from outside. -/
structure Collaborators (σ : Type) where
  /-- How config is elaborated. -/
  elaborator : Config.Elaborator σ
  /-- Where the config's chunks come from. -/
  source : Config.Source
  /-- Where a line of output goes. The editor thread calls it. -/
  emit : String → IO Unit
  /-- What the host's jobs wait on: the table of waits and the clock. A test
  hands in a fake clock; the executable the library's timer service. -/
  services : Job.Services
  /-- The Lean source id the driver's events are posted under. -/
  requests : UInt64
  /-- The Lean source id a finished reload job's wake-up is posted under. -/
  wakeups : UInt64
  /-- The Lean source id the wake-up of a job that has ended is posted under,
  with the job's id as its code. -/
  jobs : UInt64

/-- What the driver posts to the editor queue: a request, a marker to wait
for, or the end of the loop. -/
inductive Signal where
  /-- Do this. -/
  | request (request : Request)
  /-- A marker: `settle` waits until the loop has reached it and no reload is
  running. -/
  | marker
  /-- End the loop. -/
  | stop

/-- A signal as an event's code and text. -/
def Signal.encode : Signal → UInt64 × String
  | .request .reload => (0, "")
  | .request (.run name) => (1, name)
  | .request .show => (2, "")
  | .marker => (3, "")
  | .stop => (4, "")
  | .request (.spawn name) => (5, name)

/-- The signal an event's code and text stand for, if they stand for one. -/
def Signal.decode? (code : UInt64) (text : String) : Option Signal :=
  match code with
  | 0 => some (.request .reload)
  | 1 => some (.request (.run text))
  | 2 => some (.request .show)
  | 3 => some .marker
  | 4 => some .stop
  | 5 => some (.request (.spawn text))
  | _ => none

mutual
/-- A store's value as `show` prints it. -/
def render : Value → String
  | .null => "null"
  | .bool value => toString value
  | .nat value => toString value
  | .int value => toString value
  | .str value => value.quote
  | .list items => "[" ++ ", ".intercalate (renderItems items) ++ "]"
  | .record fields => "{" ++ ", ".intercalate (renderFields fields) ++ "}"
/-- Each item of a list as `show` prints it. -/
def renderItems : List Value → List String
  | [] => []
  | item :: rest => render item :: renderItems rest
/-- Each field of a record as `show` prints it. -/
def renderFields : List (String × Value) → List String
  | [] => []
  | (name, value) :: rest => (name ++ ": " ++ render value) :: renderFields rest
end

/-- A severity as a diagnostic line names it. -/
def severityName : Config.Severity → String
  | .information => "information"
  | .warning => "warning"
  | .error => "error"

/-- A refusal as a `run` line names it. -/
def refusalName : TextError → String
  | .noSuchText => "no such text"
  | .badRange => "bad range"

/-- The lines a reload's report is printed as: what it came to, then its
diagnostics. -/
def reportLines (report : Config.Report) : Array String :=
  let outcome :=
    if report.installed then
      s!"reload {report.number}: installed, {report.chunks} chunks, {report.commands} commands"
    else s!"reload {report.number}: rejected"
  #[outcome] ++
    report.diagnostics.map fun diagnostic =>
      s!"diagnostic: {diagnostic.source}:{diagnostic.line}:{diagnostic.column}: {severityName diagnostic.severity}: {(diagnostic.message.splitOn "\n").headD ""}"

/-- How a job that has ended is reported, after `job <id> <name>: `. -/
def firstLine (message : String) : String :=
  (message.splitOn "\n").headD ""

/-- The loop's state: everything the editor thread owns. -/
structure Running (σ : Type) where
  /-- The config half of the editor's state. -/
  config : Config.State σ := {}
  /-- The texts made so far. -/
  texts : RealTexts := #[]
  /-- The jobs that are running, with their owners. -/
  jobs : Job.Jobs
  /-- Where the reload job that is running will leave its outcome. -/
  job : Option (IO.Promise (Config.Outcome σ)) := none
  /-- How many markers the loop has reached. -/
  markers : Nat := 0
  /-- Whether the driver has ended the loop. -/
  stopped : Bool := false

namespace Running

variable {σ : Type}

/-- The reload job, on a thread of its own: builds the config, hands the
outcome over through `promise`, and wakes the editor thread with an event.
The wake-up is posted whatever happens, so the editor thread never waits for
a job that is gone. -/
def reloadJob (collaborators : Collaborators σ) (base : Option σ) (chunks : Array (Config.Chunk σ))
    (promise : IO.Promise (Config.Outcome σ)) : IO Unit := do
  try
    promise.resolve (← Config.build collaborators.elaborator collaborators.source base chunks)
  finally
    discard <| Ffi.postEvent .editor collaborators.wakeups 0 ""

/-- Feeds `event` to the reload reducer and performs its effects. A reload
job is started on a dedicated task, never run here: it reads files and
elaborates, and the editor thread goes on to its next event. -/
def reduce (collaborators : Collaborators σ) (running : Running σ) (event : Config.Event σ) :
    IO (Running σ) := do
  let (config, effects) := Config.step running.config event
  let mut running := { running with config }
  for effect in effects do
    match effect with
    | .report report =>
      for line in reportLines report do
        collaborators.emit line
    | .cancelJobs owner =>
      -- The owner's jobs leave the table here, so a wake-up one of them had
      -- already posted finds nothing, and its handler never runs.
      let (removed, jobs) ← running.jobs.removeOwner owner
      running := { running with jobs }
      for entry in removed do
        collaborators.emit s!"job {entry.id} {entry.name}: cancelled"
    | .start base chunks =>
      let promise ← IO.Promise.new
      discard <| IO.asTask (prio := .dedicated) (reloadJob collaborators base chunks promise)
      running := { running with job := some promise }
  return running

/-- Takes the finished reload job's outcome and feeds it to the reducer. This
is where a reload is installed: on the editor thread, between two events. -/
def finish (collaborators : Collaborators σ) (running : Running σ) : IO (Running σ) := do
  let some promise := running.job | return running
  let outcome :=
    promise.result?.get.getD
      { base := none,
        diagnostics := #[Config.failure "reload" "the reload job ended without an outcome"],
        built := none }
  { running with job := none }.reduce collaborators (.finished outcome)

/-- Runs the command called `name` against the Rust library, writes back what
it wrote, and prints how it went. -/
def run (collaborators : Collaborators σ) (running : Running σ) (name : String) : IO (Running σ) :=
  do
  let some program := running.config.program? name
    |
    collaborators.emit s!"run {name}: no such command"
    return running
  let (result, texts) ← program.runReal running.texts
  match result with
  | .ok write =>
    collaborators.emit s!"run {name}: ok"
    return { running with
        config := running.config.written write, texts }
  | .error refusal =>
    collaborators.emit s!"run {name}: refused: {refusalName refusal}"
    return { running with texts }

/-- Starts the job registered under `name`, for the owner that registered it,
and prints its id. The job runs on the pool; when it has ended the runner
posts a wake-up to the editor queue, with the job's id, from whichever thread
the job ended on. -/
def spawn (collaborators : Collaborators σ) (running : Running σ) (name : String) :
    IO (Running σ) := do
  let some (owner, work) := running.config.work? name
    |
    collaborators.emit s!"spawn {name}: no such job"
    return running
  let wake (id : Nat) : BaseIO Unit :=
    (discard <| Ffi.postEvent .editor collaborators.jobs id.toUInt64 "" : IO Unit).catchExceptions
      fun _ => pure ()
  let (id, jobs) ← running.jobs.start owner name work wake
  collaborators.emit s!"spawn {name}: job {id}"
  return { running with jobs }

/-- Deals with the job `id`, which has ended, on the editor thread: takes its
result, and for a job that finished runs the command it finished with, as any
command is run, and prints how it went. A job that is no longer in the table,
because its owner was removed, is not dealt with: its handler does not run. -/
def ended (collaborators : Collaborators σ) (running : Running σ) (id : Nat) : IO (Running σ) := do
  let (result, jobs) ← running.jobs.finish id
  let running := { running with jobs }
  let some (entry, outcome) := result | return running
  let label := s!"job {entry.id} {entry.name}"
  match outcome with
  | .finished command =>
    let (result, texts) ← command.runReal running.texts
    match result with
    | .ok () =>
      collaborators.emit s!"{label}: ok"
    | .error refusal =>
      collaborators.emit s!"{label}: refused: {refusalName refusal}"
    return { running with texts }
  | .failed message =>
    collaborators.emit s!"{label}: failed: {firstLine message}"
    return running
  | .cancelled =>
    collaborators.emit s!"{label}: cancelled"
    return running

/-- Prints the commands, the texts and the stores. -/
def «show» (collaborators : Collaborators σ) (running : Running σ) : IO Unit := do
  collaborators.emit (" ".intercalate ("commands:" :: running.config.registry.names.toList))
  for index in [0:running.texts.size] do
    if let some document := running.texts[index]? then
      collaborators.emit s!"text {index}: {(← document.read).quote}"
  for cell in running.config.cells.cells do
    collaborators.emit s!"store {cell.name} v{cell.version}: {render cell.value}"

/-- Handles one event of the editor queue to its end. -/
def handle (collaborators : Collaborators σ) (running : Running σ) (event : Ffi.Event) :
    IO (Running σ) := do
  match event.source.kind with
  | .script =>
    collaborators.emit s!"event {event.source.id} {event.code}"
    return running
  | .library | .window =>
    return running
  | .lean =>
    if event.source.id == collaborators.wakeups then
      return ← running.finish collaborators
    if event.source.id == collaborators.jobs then
      return ← running.ended collaborators event.code.toNat
    unless event.source.id == collaborators.requests do
      return running
    match Signal.decode? event.code event.text with
    | some (.request .reload) =>
      running.reduce collaborators .requested
    | some (.request (.run name)) =>
      running.run collaborators name
    | some (.request (.spawn name)) =>
      running.spawn collaborators name
    | some (.request .show) =>
      running.show collaborators
      return running
    | some .marker =>
      return { running with markers := running.markers + 1 }
    | some .stop =>
      return { running with stopped := true }
    | none =>
      return running

end Running

/-- How far the editor thread has got, as it tells its driver after each
event. -/
structure Progress where
  /-- How many markers the loop has reached. -/
  markers : Nat := 0
  /-- Whether a reload job is running. -/
  reloading : Bool := false
  /-- How many jobs are running: started, and neither dealt with nor
  cancelled with their owner. -/
  jobs : Nat := 0

/-- The editor thread: pulls the editor queue and handles each event to its
end, until the driver ends the loop or the queues are quit. After each event
it publishes in `progress` how many markers it has reached, whether a reload
is running, and how many jobs are. -/
def loop {σ : Type} (collaborators : Collaborators σ) (progress : IO.Ref Progress) : IO Unit := do
  let mut running : Running σ := { jobs := { services := collaborators.services } }
  repeat
    let event ← Ffi.nextEvent .editor
    if event.kind == .quit then
      break
    running ← running.handle collaborators event
    if running.stopped then
      break
    progress.set
        { markers := running.markers, reloading := running.config.running,
          jobs := running.jobs.running }
  -- Nothing will deal with a result any more: no job runs on unowned.
  running.jobs.cancelAll

/-- A running host, as its driver holds it. -/
structure Host where
  /-- The Lean source id the driver's events are posted under. -/
  requests : UInt64
  /-- How many markers the driver has posted. -/
  posted : IO.Ref Nat
  /-- How far the loop has got. -/
  progress : IO.Ref Progress
  /-- The loop. -/
  thread : Task (Except IO.Error Unit)

/-- Starts a host: its loop runs on a dedicated task until `stop` or `halt`. -/
def start {σ : Type} (collaborators : Collaborators σ) : IO Host := do
  let progress ← IO.mkRef {}
  let thread ← IO.asTask (prio := .dedicated) (loop collaborators progress)
  return { requests := collaborators.requests, posted := ← IO.mkRef 0, progress, thread }

/-- What a driver's wait for the editor thread came to. -/
inductive Wait where
  /-- The editor thread has handled everything sent so far, and what the wait
  was for is over: no reload is running, for a `settle`, and no job, for a
  `join`. -/
  | settled
  /-- The wait ran out with the editor thread up to date and a reload still
  running. -/
  | reloading
  /-- The wait ran out with the editor thread up to date and a job still
  running. -/
  | working
  /-- The wait ran out before the editor thread had handled everything sent
  to it: it is still inside an event, or it has ended. -/
  | unanswered
  deriving DecidableEq, Repr

/-- Polls `condition` until it holds; `false` if it still does not after
`patience` milliseconds. -/
def within (patience : Nat) (condition : IO Bool) : IO Bool := do
  let deadline := (← IO.monoMsNow) + patience
  repeat
    if ← condition then
      return true
    if (← IO.monoMsNow) >= deadline then
      break
    IO.sleep 1
  return false

namespace Host

/-- Posts `signal` to the editor queue. Throws if the queue refuses it, which
it does once the queues are quit. -/
def post (host : Host) (signal : Signal) : IO Unit := do
  let (code, text) := signal.encode
  unless ← Ffi.postEvent .editor host.requests code text do
    throw (IO.userError "the editor queue refused an event: it has been quit")

/-- Asks the editor thread to do `request`, after everything asked before. -/
def send (host : Host) (request : Request) : IO Unit :=
  host.post (.request request)

/-- Waits until the editor thread has handled everything sent so far and
`busy` no longer holds of its progress, for at most `patience` milliseconds.
Says what the wait came to: `still` if it ran out with the editor thread up
to date and `busy` still holding. -/
def waitWhile (host : Host) (patience : Nat) (busy : Progress → Bool) (still : Wait) : IO Wait := do
  let marker ← host.posted.modifyGet fun posted => (posted + 1, posted + 1)
  host.post .marker
  let settled ←
    within patience do
        let progress ← host.progress.get
        return progress.markers >= marker && !busy progress
  if settled then
    return .settled
  -- The marker was posted after everything sent so far: a loop that has
  -- reached it is up to date, and what it is waiting for is what is busy.
  let progress ← host.progress.get
  return if progress.markers < marker then .unanswered
    else if busy progress then still else .settled

/-- Waits until the editor thread has handled everything sent so far and no
reload is running, for at most `patience` milliseconds, and says what the
wait came to. -/
def await (host : Host) (patience : Nat) : IO Wait :=
  host.waitWhile patience (·.reloading) .reloading

/-- Waits until the editor thread has handled everything sent so far and no
job is running, for at most `patience` milliseconds, and says what the wait
came to. A job is running from its `spawn` until the editor thread has dealt
with its result, or has cancelled it with its owner. -/
def join (host : Host) (patience : Nat) : IO Wait :=
  host.waitWhile patience (·.jobs > 0) .working

/-- Waits until the editor thread has handled everything sent so far and no
reload is running; `false` if that takes longer than `patience`
milliseconds. -/
def settle (host : Host) (patience : Nat) : IO Bool :=
  return (← host.await patience) == .settled

/-- Ends the loop at once, whether a reload is running or not; `false` if it
has not ended after `patience` milliseconds. Throws the error the loop ended
with, if it ended with one. -/
def halt (host : Host) (patience : Nat) : IO Bool := do
  unless ← IO.hasFinished host.thread do
    host.post .stop
  unless ← within patience (IO.hasFinished host.thread) do
    return false
  IO.ofExcept host.thread.get
  return true

/-- Ends the loop once no reload is running; `false` if it did not settle or
did not end, each within `patience` milliseconds. -/
def stop (host : Host) (patience : Nat) : IO Bool := do
  let settled ← host.settle patience
  let ended ← host.halt patience
  return settled && ended

end Host

/-- One line of a script. -/
inductive Directive where
  /-- Ask the editor thread for this. -/
  | request (request : Request)
  /-- Wait until the editor thread has handled everything asked so far and no
  reload is running. This one is the driver's own. -/
  | settle
  /-- Wait until the editor thread has handled everything asked so far and no
  job is running. The driver's own, too. -/
  | join
  deriving DecidableEq, Repr

/-- The name a directive gives after its keyword, which is the first
`keyword` characters of `line`; `none` if there is none. -/
def named (line : String) (keyword : Nat) : Option String :=
  let name := (line.drop keyword).trimAscii.toString
  if name.isEmpty then none else some name

/-- The directive `line` is, `none` for a blank line or a comment, or what is
wrong with it. -/
def directive? (line : String) : Except String (Option Directive) :=
  let line := line.trimAscii.toString
  if line.isEmpty || line.startsWith "#" then .ok none
  else
    if line == "reload" then .ok (some (.request .reload))
    else
      if line == "show" then .ok (some (.request .show))
      else
        if line == "settle" then .ok (some .settle)
        else
          if line == "join" then .ok (some .join)
          else
            if line.startsWith "run " then
              match named line 4 with
              | none => .error s!"`{line}` names no command"
              | some name => .ok (some (.request (.run name)))
            else
              if line.startsWith "spawn " then
                match named line 6 with
                | none => .error s!"`{line}` names no job"
                | some name => .ok (some (.request (.spawn name)))
              else
                .error
                  s!"`{line}` is not a directive: expected reload, run <name>, spawn <name>, show, settle or join"

/-- A directive of a script, and the line it is on. -/
structure Line where
  /-- The line's number in the script, from 1. -/
  number : Nat
  /-- What the line says. -/
  directive : Directive
  deriving DecidableEq, Repr

/-- The directives of a script: one a line, with blank lines and lines that
start with `#` skipped. Or what is wrong with the first line that is not a
directive, after the number of that line: `line 3: …`. -/
def script (text : String) : Except String (Array Line) := do
  let mut lines := #[]
  let mut number := 0
  for line in text.splitOn "\n" do
    number := number + 1
    match directive? line with
    | .error problem =>
      throw s!"line {number}: {problem}"
    | .ok none =>
      pure ()
    | .ok (some directive) =>
      lines := lines.push { number, directive }
  return lines

/-- Why a script did not run to its end. Each carries the line of the
`settle` or the `join` that ran out, or `none` for the wait at the end of
the script, before the loop is stopped. -/
inductive Failure where
  /-- A wait ran out with a reload still running. -/
  | reloading (line : Option Nat)
  /-- A `join` ran out with a job still running. -/
  | working (line : Option Nat)
  /-- The editor thread did not answer: a wait ran out before it had handled
  everything sent to it, or, with no line, it did not stop. -/
  | unanswered (line : Option Nat)
  deriving DecidableEq, Repr

/-- What went wrong, for the user: `patience` is how long each wait was, in
milliseconds. -/
def Failure.describe (patience : Nat) : Failure → String
  | .reloading (some line) =>
    s!"the settle on line {line} of the script did not finish within {patience} ms: a reload was still running. A chunk or `setup` of the config is slow, or does not end"
  | .reloading none =>
    s!"the script ended, and the reload it had asked for did not finish within {patience} ms. A chunk or `setup` of the config is slow, or does not end"
  | .working (some line) =>
    s!"the join on line {line} of the script did not finish within {patience} ms: a job was still running. A job of the config is slow, or does not end"
  | .working none =>
    s!"the script ended, and a job it had started did not finish within {patience} ms. A job of the config is slow, or does not end"
  | .unanswered (some line) =>
    s!"the settle or join on line {line} of the script did not finish within {patience} ms: the editor thread had not handled everything sent to it. It is still inside a command or another event, or it has ended"
  | .unanswered none =>
    s!"the script ended, and the editor thread did not stop within {patience} ms"

/-- The failure a wait that did not settle is, at `line` of the script. -/
def Wait.failure (line : Option Nat) : Wait → Option Failure
  | .settled => none
  | .reloading => some (.reloading line)
  | .working => some (.working line)
  | .unanswered => some (.unanswered line)

/-- Runs `script` against a host of its own, as its driver, and stops the
host: sends each request in order and waits at each `settle` and each
`join`. `none` when the script ran to its end, and otherwise why it could
not: the editor thread did not settle, a job did not end, or the loop did not
stop, within `patience` milliseconds.

A `settle` or a `join` that runs out ends the loop at once, whether a reload
or a job is running or not. A rejected reload is something to print, not a
failure, and so is a job that fails. A job the script leaves running is
cancelled when the loop ends. -/
def run {σ : Type} (collaborators : Collaborators σ) (script : Array Line) (patience : Nat) :
    IO (Option Failure) := do
  let host ← start collaborators
  for line in script do
    let wait ←
      match line.directive with
      | .request request =>
        host.send request
        continue
      | .settle =>
        host.await patience
      | .join =>
        host.join patience
    if let some failure := wait.failure (some line.number) then
      discard <| host.halt patience
      return some failure
  -- The end of the script: wait for a reload that is still running, then
  -- stop the loop.
  let unsettled := (← host.await patience).failure none
  let stopped ← host.halt patience
  return unsettled <|> (if stopped then none else some (.unanswered none))

/-- How long the headless mode waits at each `settle` and each `join`, and
for the loop to stop, in milliseconds. -/
def settlePatience : Nat :=
  30000

/-- How long warming the pool waits, in milliseconds, for each of its tasks
to start. A task starts in microseconds; this long passes only when the pool
is smaller than the machine, because `LEAN_NUM_THREADS` says so. -/
def warmPatience : Nat :=
  200

/-- The headless mode of the executable:
`editor headless <sysroot> <olean dir> <config dir> <script file>`. Loads the
config in `configDir` with the real elaborator, runs the script as `run`
does, with the output on stdout, then quits the queues and exits explicitly:
with status 0 when the script ran to its end, and with 1 when it could not,
after saying why on stderr (the script cannot be read, a wait ran out with a
reload or a job still running, or the editor thread did not answer).

Before the loop starts it warms the pool, so the first burst of jobs finds
every thread made, and starts the completion pump on a dedicated task. The
host's jobs wait on the library's timer service.

`sysroot` is the Lean toolchain's directory and `oleanDir` the directory
holding the editor package's `.olean` files. Every path is an argument:
nothing is read from the environment or the working directory. -/
def main (sysroot oleanDir configDir scriptPath : String) : IO UInt32 := do
  let directives ←
    try
      let text ← IO.FS.readFile scriptPath
      IO.ofExcept ((script text).mapError IO.userError)
    catch error =>
      IO.eprintln s!"editor: cannot run the script {scriptPath}: {error}"
      return 1
  discard <| Job.Pool.warm Job.Pool.size warmPatience
  let completions ← Job.Completions.new
  discard <| IO.asTask (prio := .dedicated) (Job.pump completions)
  let failure ←
    run
        { elaborator := Config.Elaborate.elaborator { sysroot, oleanDir },
          source := Config.Directory.source configDir, emit := IO.println,
          services := { completions, timers := Job.realTimers completions }, requests := 1,
          wakeups := 2, jobs := 3 }
        directives settlePatience
  (← IO.getStdout).flush
  if let some failure := failure then
    IO.eprintln s!"editor: {failure.describe settlePatience}"
  -- Shutdown: quit lets every task parked in a pull return, the pump among
  -- them, and the exit is explicit, because a task may still be blocked in
  -- the library.
  Ffi.quit
  IO.Process.exit (if failure.isNone then 0 else 1)

end Editor.Headless
