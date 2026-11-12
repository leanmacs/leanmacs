import Editor.Config.Directory
import Editor.Config.Elaborate
import Editor.Config.Reload
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

It knows a request from its driver, an event of the library's scripted source
and quit, and nothing else. It has no keys, keymaps, dispatch, scene or
rollback: those are the command loop's, which will replace this loop and
call the same two operations of the reducer.

The collaborators are handed in (`Collaborators`): the elaborator and the
source of the config session, and `emit`, the port every line of output goes
through.

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
event <source id> <code>  (an event from the library's scripted source)
commands: <names>
text <index>: <quoted text>
store <name> v<version>: <value>
```

The last three answer `show`. A text is never closed: the loop keeps one
table of texts for its life, and `show` lists them all. A diagnostic that is
about no place in particular has the position 0:0.

## The driver, and the command line

A host is driven from another thread: `Host.send` posts a request,
`Host.settle` waits, with a bound, until the editor thread has handled
everything sent so far and no reload is running, and `Host.stop` ends the
loop. Requests are handled in the order they were sent, and a request sent
while a reload runs is handled before that reload is installed: settle
first to see its effect.

`run` drives a host through a script, one directive a line: `reload`,
`run <name>` and `show` are requests, and `settle` is the driver's own.
Blank lines and lines that start with `#` are skipped.

`main` is the executable's headless mode,
`editor headless <sysroot> <olean dir> <config dir> <script file>`: `run`
with the real elaborator, a directory as the source and stdout as the
output, then the quit and the explicit exit. Its exit status is 0 when the
script ran to its end and 1 when it could not: the script cannot be read, or
a `settle` ran out (after 30 seconds). A rejected reload is something to
print, not a failure.

## Tests

`config-test` drives a host in-process on the real queue, the real text
binding and the real elaborator, and compares the lines it emits
(`ConfigTest.hostChecks`, `ConfigTest.threadChecks`), and checks the script
reader and the driver (`ConfigTest.scriptChecks`). The `ffi-test` task runs
the real executable once, on the fixture under `tests/headless`, which
covers the command line.
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
  deriving DecidableEq, Repr

/-- What a host needs from outside. -/
structure Collaborators (σ : Type) where
  /-- How config is elaborated. -/
  elaborator : Config.Elaborator σ
  /-- Where the config's chunks come from. -/
  source : Config.Source
  /-- Where a line of output goes. The editor thread calls it. -/
  emit : String → IO Unit
  /-- The Lean source id the driver's events are posted under. -/
  requests : UInt64
  /-- The Lean source id a finished reload job's wake-up is posted under. -/
  wakeups : UInt64

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

/-- The signal an event's code and text stand for, if they stand for one. -/
def Signal.decode? (code : UInt64) (text : String) : Option Signal :=
  match code with
  | 0 => some (.request .reload)
  | 1 => some (.request (.run text))
  | 2 => some (.request .show)
  | 3 => some .marker
  | 4 => some .stop
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

/-- The loop's state: everything the editor thread owns. -/
structure Running (σ : Type) where
  /-- The config half of the editor's state. -/
  config : Config.State σ := {}
  /-- The texts made so far. -/
  texts : RealTexts := #[]
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
  | .library =>
    return running
  | .lean =>
    if event.source.id == collaborators.wakeups then
      return ← running.finish collaborators
    unless event.source.id == collaborators.requests do
      return running
    match Signal.decode? event.code event.text with
    | some (.request .reload) =>
      running.reduce collaborators .requested
    | some (.request (.run name)) =>
      running.run collaborators name
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

/-- The editor thread: pulls the editor queue and handles each event to its
end, until the driver ends the loop or the queues are quit. After each event
it publishes in `settled` how many markers it has reached with no reload
running. -/
def loop {σ : Type} (collaborators : Collaborators σ) (settled : IO.Ref Nat) : IO Unit := do
  let mut running : Running σ := {}
  repeat
    let event ← Ffi.nextEvent .editor
    if event.kind == .quit then
      break
    running ← running.handle collaborators event
    if running.stopped then
      break
    unless running.config.running do
      settled.set running.markers

/-- A running host, as its driver holds it. -/
structure Host where
  /-- The Lean source id the driver's events are posted under. -/
  requests : UInt64
  /-- How many markers the driver has posted. -/
  posted : IO.Ref Nat
  /-- How many markers the loop has reached with no reload running. -/
  settled : IO.Ref Nat
  /-- The loop. -/
  thread : Task (Except IO.Error Unit)

/-- Starts a host: its loop runs on a dedicated task until `stop` or `halt`. -/
def start {σ : Type} (collaborators : Collaborators σ) : IO Host := do
  let settled ← IO.mkRef 0
  let thread ← IO.asTask (prio := .dedicated) (loop collaborators settled)
  return { requests := collaborators.requests, posted := ← IO.mkRef 0, settled, thread }

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

/-- Waits until the editor thread has handled everything sent so far and no
reload is running; `false` if that takes longer than `patience`
milliseconds. -/
def settle (host : Host) (patience : Nat) : IO Bool := do
  let marker ← host.posted.modifyGet fun posted => (posted + 1, posted + 1)
  host.post .marker
  within patience (return (← host.settled.get) >= marker)

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
  deriving DecidableEq, Repr

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
          if line.startsWith "run " then
            let name := (line.drop 4).trimAscii.toString
            if name.isEmpty then .error s!"`{line}` names no command"
            else .ok (some (.request (.run name)))
          else .error s!"`{line}` is not a directive: expected reload, run <name>, show or settle"

/-- The directives of a script: one a line, with blank lines and lines that
start with `#` skipped. Or the first line that is not a directive. -/
def script (text : String) : Except String (Array Directive) :=
  (text.splitOn "\n").foldlM
    (fun directives line => do
      match ← directive? line with
      | some directive =>
        return directives.push directive
      | none =>
        return directives)
    #[]

/-- Runs `script` against a host of its own, as its driver, and stops the
host: sends each request in order and waits at each `settle`. The exit
status: 0 when the script ran to its end, 1 when it could not, because the
editor thread did not settle, or did not stop, within `patience`
milliseconds.

A `settle` that runs out ends the loop at once, whether a reload is running
or not. A rejected reload is something to print, not a failure. -/
def run {σ : Type} (collaborators : Collaborators σ) (script : Array Directive)
    (patience : Nat := 30000) : IO UInt32 := do
  let host ← start collaborators
  for directive in script do
    match directive with
    | .request request =>
      host.send request
    | .settle =>
      unless ← host.settle patience do
        discard <| host.halt patience
        return 1
  return if ← host.stop patience then 0 else 1

/-- The headless mode of the executable:
`editor headless <sysroot> <olean dir> <config dir> <script file>`. Loads the
config in `configDir` with the real elaborator, runs the script as `run`
does, with the output on stdout, then quits the queues and exits explicitly
with `run`'s status, or with 1 if the script cannot be read.

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
  let status ←
    run
        { elaborator := Config.Elaborate.elaborator { sysroot, oleanDir },
          source := Config.Directory.source configDir, emit := IO.println, requests := 1,
          wakeups := 2 }
        directives
  (← IO.getStdout).flush
  -- Shutdown: quit lets every task parked in a pull return, and the exit is
  -- explicit, because a task may still be blocked in the library.
  Ffi.quit
  IO.Process.exit status.toUInt8

end Editor.Headless
