import Editor.Clipboard.InProcess
import Editor.Config.Directory
import Editor.Config.Elaborate
import Editor.Config.Reload
import Editor.Display.Recorder
import Editor.Event.Queue
import Editor.Evil.Compiled
import Editor.Ex.Compiled
import Editor.Files.Compiled
import Editor.InputScheme.Vim.Default
import Editor.Job.Jobs
import Editor.Job.Pool
import Editor.Job.Real
import Editor.Loop
import Editor.Minibuffer.Compiled
import Editor.Text.Real
import Editor.Watch.Real

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
effects, and runs the command loop's programs with `EditorM.runReal`, with
a display recorder (`Editor/Display/Recorder.lean`) as the display and a
clipboard of its own (`Editor/Clipboard/InProcess.lean`). Every
command it runs, it runs through the command loop ("The editor loop").

A reload does not run on the editor thread. The reducer's `start` effect
becomes a dedicated task, the reload job, which reads the source, elaborates
and runs `setup` (`Config.build`), resolves a promise with the outcome and
posts a wake-up to the editor queue. The editor thread meets the wake-up like
any event, takes the outcome and feeds it to the reducer: a config is
installed between two events, and the editor answers events while a chunk
elaborates. It is a dedicated task, not one of the pool's: it reads files.

It knows a request from its driver, the wake-up of a reload job, the wake-up
of a job that has ended, an event of the library's scripted source, an event
from the window input and quit, and nothing else.

## The editor loop

The host runs the command loop (`Editor/Loop.lean`) beside the config
session, and calls the same operations of the reducer and of the job table
as before, so reload and job completion work as they did.

- **The host is given its input scheme**, as a parameter of its
  collaborators' type (`Collaborators σ scheme`), and its loop runs that one
  (`Loop scheme`). The executable's is the Vim scheme over its default
  states (`Vim.Default.scheme`); a test hands a host the test scheme.
- **The frame is made when the loop is first needed** (`Running.framed`):
  at the first event from the window input, the first command run by name
  or the first job's command to deliver, whichever comes first. The host
  holds no frame (`Running.frame`) until then, and then makes it
  (`Loop.start`) in a frame of 0 by 0, which a resize changes. A command
  may ask for buffers and windows, which only the loop's state has, so no
  command runs without one. So the scratch buffer's text is the first text
  made, and `show` prints it as text 0. A host whose frame cannot be made (`Collaborators.start` is refused)
  prints the refusal and says `no frame` for the command it could not run.
- **Every command goes through the loop** (`Editor/Loop.lean`, "Every
  command goes through the loop"): a key's, the driver's `run <name>`
  (`Running.run`, `Loop.runNamed`) and a finished job's
  (`Running.ended`, `Loop.deliver`). Each is guarded against the interrupt
  flag, has its state requests answered, is rolled back if it does not run
  to its end, and is followed by a scene. What the step handed back is
  taken in the same way for all three (`Running.took`).
- **A prompt's answer is run before the next event.** A step whose command
  accepted a prompt hands back the continuation with the answer
  (`Loop.Stepped.answered`). When the step is taken in, the host runs each
  as a step of its own (`Loop.invoke`), with keys made anew
  (`Running.keys`), and takes that step in the same way, before it pulls
  another event from the queue: so a key sent after the accept key is
  handled after the answer's command, and the answer's command is looked
  up in the registry as it is then, over the stores as the accepting
  command's write left them. That is why the host runs it and not the
  accepting command's step: the host holds the cells of the stores
  (`Editor/Loop.lean`, "Prompts").
- **The jobs a command asked for are started** when its step is taken in:
  each for the owner that registered it, printed
  `job <id> <name>: started`.
- **A reload a command asked for is asked of the config session** when its
  step is taken in (`Loop.Stepped.reload`, `reloadConfig`,
  `Editor/Api.lean`): the host feeds the reload reducer a request, which is
  what its driver's `reload` does, so the reducer's rules hold unchanged:
  one job at a time, and a request made while one runs makes one
  follow-up. The reload's report is printed as the driver's is. Nothing
  puts it in the echo area.
- **A window event goes to the loop** (`Running.input`): `Loop.take`, run
  against the library with the recorder as the display, handles it and
  publishes a scene. A key press is still printed with its identity, as the
  host's own output. A close request ends the loop, as the driver's `stop`
  does, and so does any step that says stop: a command asked the editor
  to quit and it can leave (`Editor/Loop.lean`, "Quit"). A window event
  that cannot be read is ignored.
- **A key press is dispatched.** The loop steps it through the host's
  scheme and runs the command it yields (`Editor/Loop.lean`, "Running an
  invocation"). What the keys are looked up in is made for each window
  event from the registry as it then is (`Running.keys`): the registry's
  active keymaps of each view (`Config.Registry.activeMaps`: the modes of
  the view's buffer, then every owner's key bindings), which the loop
  applies to its own state, and the registry's lookup of a command by its
  name. So a reload's modes, bindings and commands hold from the next key.
  What a command over a store asked to be written is written back to the
  stores.
- **Compiled commands, jobs, bindings, modes and ex bindings are registered
  when the loop starts** (`compiled`), for the owner `compiled`, before any
  config: they are what the host's collaborators hand it. A reload replaces
  config's commands, jobs, bindings, modes and ex bindings and never these,
  so they run
  when config fails to load, and config's command of a compiled command's
  name runs in its place until a reload drops it. A compiled job is
  started by a command, by its name, as config's is, for the owner
  `compiled`: a reload that installs cancels config's jobs only, so a
  compiled job runs across a reload. The executable is handed the file
  commands and their jobs (`Files.commands`, `Files.jobs`,
  `Editor/Files/Compiled.lean`): `open-file` and `save-buffer`, the first
  commands it ships, which `show` lists before config's, and the jobs
  `load-file` and `save-file`. It is handed the minibuffer's commands and
  its mode too (`Minibuffer.commands`, `Minibuffer.modes`,
  `Editor/Minibuffer/Compiled.lean`): `minibuffer-accept` and
  `minibuffer-cancel`, which the Vim scheme's minibuffer state binds to
  `<Enter>` and `<Escape>`, and the mode `minibuffer`, the first mode it
  ships. And it is handed evil's commands (`Evil.commands`,
  `Editor/Evil/Compiled.lean`), which the Vim scheme's keys name: `move`,
  the three that enter normal state and the visual states, the four that
  begin an insert, and `self-insert`, which a key that prints runs in
  insert state and in the minibuffer; and the operate command, `x`, the
  two puts, the two commands that open a line, undo, redo and the repeat
  command. So with no config the editor moves, edits, undoes and repeats.
  And it is handed the ex line's commands and the ex names
  that ship (`Ex.commands`, `Ex.bindings`, `Editor/Ex/Compiled.lean`):
  `ex`, which opens the ex line and runs its answer, `quit`,
  `save-and-quit` and `reload-config`, and the ex names `w`, `e`, `q`,
  `wq` and `reload`. The Vim scheme's default table binds `:` to the name
  `ex`, so that key opens the ex line. It is handed no key binding: the
  Vim scheme's keys are its states' own keymaps. Every default key names
  a command the host is handed.
- **The interrupt key.** When the loop starts the host tells the library
  which key raises the interrupt flag (`Collaborators.interruptKey`, `C-g`),
  and leaves it with none when the loop ends. The loop's programs are run
  with the library's flag and the jobs' clock as what they watch
  (`Running.watch`), so a command a key runs stops at its next request once
  the key has arrived, and the loop lowers the flag when it takes the key
  off the queue. Where no loop can take a marked key, with no frame made or
  for an event that cannot be read, the host drops the event
  (`Running.drop`), which lowers the flag by the loop's rule
  (`Loop.lowerFor`), and the mark of an event that cannot be read is the
  decoder's to read (`Event.interruptMarked`).
- **A slow command is logged**, through the collaborators' `log`, and not on
  the output: the entries a step hands back (`Loop.Stepped.log`). The
  executable's log is stderr, so a fixture's output does not depend on how
  long the machine took.
- **After every other event**, a scene is published once there is a frame
  (`Running.publish`), unless the loop took a step for the event and
  published its own: a reload's install, a `show` and a marker are each
  followed by one, so the count of scenes says how many events there were.
  The driver's `stop` publishes nothing.
- **A refusal is never dropped.** The loop puts a refusal in the echo area
  of the scene, a handler's and one met while publishing alike
  (`Editor/Loop.lean`, "When publishing is refused"), so `scene` prints it.
  The loop's programs are not themselves refused; the host runs each
  through `Running.attempt` all the same, which prints one that is,
  `loop: refused: <error>`, and keeps the frame it had. With no frame made,
  the event is dropped and the next window event tries again.
- **The display is a recorder** (`Editor/Display/Recorder.lean`), in cells
  8 pixels across and 16 down (`cells`), over the table of snapshots the
  text binding publishes: it keeps the last scene and counts them, and the
  `scene` request prints it.
- **The clipboard is the host's own** (`Editor/Clipboard/InProcess.lean`):
  with no window system there is no system clipboard, so the host keeps a
  text in the process and answers every command's clipboard requests from
  it, a key's, a command's run by name and a finished job's alike. What one
  command writes the next reads; no other program sees it, and it starts
  holding no text.

The collaborators are handed in (`Collaborators`): the elaborator and the
source of the config session, `emit`, the port every line of output goes
through, the services the loop's jobs wait on, which a test makes of a fake
clock, and the two tables the host makes before those services: the table of
snapshots the loop's text binding publishes, of which the loop is the one
writer, and what the jobs hold. Beside them, each with a default: the
compiled commands, jobs, bindings and modes, the log, the threshold for a
slow command, the interrupt key and how the frame is made
(`Collaborators.start`).

## Jobs

The host owns the job table (`Job.Jobs`, `Editor/Job/Jobs.lean`), so it is
the one thing that starts a job, for the owner that registered it
(`Running.startJob`): for the driver's `spawn <name>`, with no arguments,
and for each job a command asked for (`startJob`, `Editor/Api.lean`), with
the arguments the command gave. `setup` starts none.

- **A job runs on the pool**, and holds no thread while it waits
  (`Editor/Job/Runner.lean`). The editor thread goes on to its next event.
- **Its result comes back as a command.** When a job has ended, however it
  ended, the runner posts a wake-up to the editor queue from the job's
  thread, with the job's id. The outcome stays in the job's handle. The
  editor thread meets the wake-up in its turn, takes the result, and, for a
  job that finished, has the loop run the command it finished with as it
  runs any command (`Loop.deliver`). So a handler runs on the editor
  thread, between two events, after every event that was queued before the
  wake-up.
- **A finished job's command is handed what the job held.** A job that
  loaded a file holds the snapshot the load made. The host runs the
  delivery with `Job.finishWith` (`Editor/Job/Real.lean`): the run is handed
  those snapshots, so the command can take one into the text store
  (`JobSnapshotId.adopt`, `JobSnapshotId.toText`), and the job is settled
  once the delivery has run, which releases what it held. It hands
  `finishWith` what its loop watches (`Running.watch`), so the command's
  guard asks the library's interrupt flag, and its clipboard. A job that failed or was
  cancelled settled itself.
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
run <name>: ok            (or "refused: <error>", "interrupted",
                           "gave up: <reason>", "no such command",
                           "no window", or "no frame" for a host whose
                           frame could not be made)
spawn <name>: job <id>    (or "no such job")
job <id> <name>: started  (a command asked for the job)
job <id> <name>: ok       (the handler's command ran; or "refused: <error>",
                           "interrupted", "gave up: <reason>", "failed:
                           <first line of the message>", "cancelled",
                           "no frame")
event <source id> <code>  (an event from the library's scripted source)
key arrived: <logical> <physical> <modifiers>
                          (a key press from the window, `Key.describe`)
commands: <names>
text <index>: <quoted text>
store <name> v<version>: <value>
scene <w>x<h>, focused <id or ->, echo <quoted>, preedit <quoted or ->, published <n>
view <id> <x>,<y> <w>x<h>: <quoted text>, scroll <offset>, selections <anchor>..<head> …
status <view id>: <face> <quoted text>, …   (or "-" for no field)
scene: none               (no scene has been published)
loop: refused: <error>    (a program of the editor loop was refused)
```

The `scene`, `view` and `status` lines answer `scene`: the last scene
published, with how many scenes have been, then each view in drawing order,
its snapshot's text read from the library, and the offsets of its scroll
anchor and of each range of its selection, as the markers are when it is
asked. After each view's line comes its status line (`statusLine`), one
entry a field: the fields the input scheme reports of the view, which
under the Vim scheme is one, the name of the view's Vim state in the face
`status.state`, then the buffer's name, and the modified field while the
buffer is modified (`Loop.statusOf`). It is a line of its own, so the
view's line keeps its form. It is how a script sees a view's state, its
buffer's name and whether the buffer is modified.

A command a key runs prints nothing: what became of it is in the echo area
of the scene, `<name>: no such command`, `<name>: refused: <error>`,
`<name>: interrupted` or, for one that gave up, `<name>: <reason>`, and a
slow one is on the log. A command run by name
and a job's command are printed and are in the echo area too, a job's under
its label, `job <id> <name>`. The command that receives a prompt's answer
prints nothing either, whatever accepted the prompt: what became of it is
in the echo area, under the continuation's name. While a prompt is open
`scene` prints the minibuffer's view after the windows', with the input
typed so far as its text and the prompt text as its status line, in the
face `minibuffer.prompt`.

`commands`, `text` and `store` answer `show`, which lists commands, the
compiled ones among them, not jobs. The loop keeps
one table of texts for its life, and `show` lists every text in it that no
command has released, under the index it was made with. A diagnostic that is about no place in particular has the
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
`run <name>`, `spawn <name>`, `show` and `scene` are requests, and `settle`,
`join`, `key <logical> <physical> <modifiers>` and `commit <text>` are the
driver's own. A `key` is sent with `Host.press`: a press with no text,
posted through the library's window input as a window would report it
(`Event.post`), in order with the requests. A `commit` is sent the same way
with `Host.commit`, as an input method's composition ending with the rest of
the line, trimmed; an empty one is refused. The loop decodes a window's
events (`Event.ofFfi`) and hands each to the editor loop. Blank lines and
lines that start with `#` are skipped.

A script that cannot run to its end is data too. `Host.await` and `Host.join`
say what a wait came to (`Wait`): settled, or run out with a reload or a job
still running, or run out before the editor thread had handled everything
sent to it, or ended, because the loop has. `run` returns a `Failure` for a
wait that ran out, with the line of the `settle` or the `join`, or with no
line for the wait at the end of the script and for a loop that did not stop.

**A command that quits the editor ends the script.** When a step says stop
(`Editor/Loop.lean`, "Quit") the host ends its loop, as it does for a close
request: it runs no further invocation of that step (`Running.took`),
cancels the jobs that are left, and prints nothing more.

- **The driver sees it.** A wait answers `ended` as soon as the editor
  thread's task has finished (`Host.waitWhile`), in place of running out
  its patience. `run` stops reading the script at a wait that answered
  `ended`, and before each line when the task has finished, and that is no
  failure. A loop that ended with an error is still thrown, by
  `Host.halt`.
- **So the lines of a script after the quit are not run.** A line that was
  already posted when the loop ended, a request or a key, stays on the
  queue unread.
- **A quit that is refused leaves the script running**, and so does one
  that is still waiting for a save: the loop has not ended.
- **A script waits where its commands start a job.** A script's lines are
  posted without waiting, and a job's result is queued when the job ends.
  So a script that opens a file has a `join` after that line, or the lines
  after it are handled in the buffer the window still shows; and a script
  that runs `wq` has a `join` after it. The quit `wq` asks for waits for
  the save, so the loop is still running: without the wait, the lines
  after `wq` would be handled while the save runs, and the end of the
  script would stop the loop, which cancels the save, leaving the file's
  contents to timing. The `join` answers `ended` once the delivery of the
  save's result has stopped the loop, and the end of the script then stops
  nothing.

`main` is the executable's headless mode,
`editor headless <sysroot> <olean dir> <config dir> <script file>`: `run`
with the real elaborator, a directory as the source, stdout as the output,
the library's timer service and file service for the jobs, and the file
commands with their jobs, the minibuffer's commands with its mode, evil's
commands and the ex line's commands with the ex names that ship as
its compiled ones, then the quit and the explicit exit. Before the loop starts it warms the pool (`Editor/Job/Pool.lean`) and
starts the completion pump on a dedicated task (`Editor/Job/Real.lean`),
which the quit ends. Its exit status is 0 when the script ran to its end, or
a command quit the editor before it, and
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
(`ConfigTest.scriptChecks`). Two of those are the loop's refusals: a scene
whose echo is the refusal once a command has released the focused buffer's
text, and `Running.attempt` on a program that is refused, which no script
can make the loop run. `ConfigTest.dispatchChecks` send keys to hosts over
the test scheme, with compiled commands and bindings written there: a key
runs its command, a failed command is rolled back, the interrupt key stops
a command that loops, a reload replaces config's commands and bindings and
leaves the compiled ones, and a slow command is logged, on the fake clock.
`ConfigTest.hostLoopChecks` are the commands no key ran: a `run` goes
through the loop, makes the frame, is rolled back when it fails and is
stopped by the interrupt key; a key's command starts a job, whose result
comes back as a command after the keys sent meanwhile; and a job's command
that loops is stopped by the interrupt key; and a host is handed a compiled
job, which a compiled command starts before any config is loaded and a
reload does not cancel. `ConfigTest.promptChecks` are hosts handed the
minibuffer's commands and its mode: a command asks for a prompt, a commit
is typed into the minibuffer, the accept key runs the answer's command
before the next key and after the accepting command's write to a store,
the cancel key runs nothing, a job's result is delivered while the prompt
is open, and the continuation is looked up across a reload.
`ConfigTest.exChecks` are hosts handed the ex line's commands and the ex
names that ship: the ex line `reload` reloads the config, an ex name config
binds runs config's command until a reload drops the binding, and a name
nobody bound is said in the echo area. `ConfigTest.exScriptChecks` run
scripts a command ends, over the library's file service on files in
temporary directories: `e`, an edit, `w` and `q`, and the same with `wq`,
leave the file with the buffer's text and end the script with no failure,
with the lines after the quit not run; a `q` that is refused leaves the
script running; and a wait on a loop a command ended answers `ended`.
`ConfigTest.fileChecks` are hosts over the
library's file service, handed the file commands and their jobs as compiled
code registers them, on real files in temporary directories.
The `ffi-test` task runs the real executable
once, on the fixture under `tests/headless`, which covers the command line,
the pump and the timer service: the fixture's job sleeps on the real clock.
It runs it a second time on `tests/headless/keys-script`, which sends keys
with their identity through the library's window input, a third on
`tests/headless/scene-script`, which commits text, asks for the scene, and
then reloads and runs a job once the frame exists, each followed by a
scene, a fourth on `tests/headless/dispatch`, whose keys run commands
config binds, one of which starts a job with an argument, and a fifth on
`tests/headless/files`, which runs the file commands the executable ships
and touches no file: `save-buffer` on the scratch buffer, and a command of
config's that opens a path the library refuses before it asks the file
system, and a sixth on `tests/headless/prompt`, under the Vim scheme the
executable runs: a command of config's asks for a prompt, a committed text
goes into the minibuffer, `<Enter>` accepts and config's command receives
the answer, and `<Escape>` cancels. An eighth run is on
`tests/headless/ex/script`, with no config: a name nobody bound, `w` in the
scratch buffer, and `q`, which ends the loop before the script's last line;
the first and the last line are opened with the `:` key, as a user opens
them.
Two more entries of the task run the executable on a real file, each in a
shell of its own that makes a temporary directory, removes it by a trap,
and writes the script there from a template with the file's path put in:
`e`, an edit, `w`, `q` (`tests/headless/ex/save-quit-script`) and the same
with `wq` (`tests/headless/ex/wq-script`), each checked by the exit status,
the file's bytes and the absence of a `commands:` line. They are shell and
not Lean because Lean spawns no child process
(`docs/design/overview.md`).
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
  /-- Print the last scene the editor loop published. -/
  | scene
  deriving DecidableEq, Repr

/-- What a host that runs the input scheme `scheme` needs from outside. The
scheme is a parameter, as it is of the loop (`Loop`): it is in `Type 1`, and
cannot be a field of what a task is handed. -/
structure Collaborators (σ : Type) (scheme : InputScheme) where
  /-- How config is elaborated. -/
  elaborator : Config.Elaborator σ
  /-- Where the config's chunks come from. -/
  source : Config.Source
  /-- Where a line of output goes. The editor thread calls it. -/
  emit : String → IO Unit
  /-- What the host's jobs wait on: the table of waits, the clock and the
  files. A test hands in a fake clock; the executable the library's timer
  service and its file service. -/
  services : Job.Services
  /-- The table of snapshots the loop's text binding is over, which the host
  makes before the services: the loop is its one writer, and a real file
  service is given its read half. -/
  published : Snapshots
  /-- What the host's jobs hold: the snapshots their loads made, which the
  host makes before the services and hands to a real file service too. The
  loop hands a finished job's command what the job holds from it. -/
  held : Job.HeldSnapshots
  /-- The Lean source id the driver's events are posted under. -/
  requests : UInt64
  /-- The Lean source id a finished reload job's wake-up is posted under. -/
  wakeups : UInt64
  /-- The Lean source id the wake-up of a job that has ended is posted under,
  with the job's id as its code. -/
  jobs : UInt64
  /-- The compiled commands: registered for the owner `compiled` when the
  loop starts, before any config. -/
  commands : Array Config.Registration := #[]
  /-- The compiled jobs: registered for the owner `compiled` when the loop
  starts, before any config. A command starts one by its name. `jobs` is
  the name of a source id, above. -/
  compiledJobs : Array Config.JobRegistration := #[]
  /-- The compiled key bindings: registered for the owner `compiled` when
  the loop starts, before any config. -/
  bindings : Array Config.KeyBinding := #[]
  /-- The compiled modes: registered for the owner `compiled` when the loop
  starts, before any config. -/
  modes : Array Mode := #[]
  /-- The compiled ex bindings (`Editor/Ex/Line.lean`): registered for the
  owner `compiled` when the loop starts, before any config. -/
  ex : Array Ex.Binding := #[]
  /-- Where a log entry goes: a command that took longer than `slowAfter`.
  The editor thread calls it. It is not `emit`: the output is what a test
  compares, and a log entry depends on how long the machine took. -/
  log : String → IO Unit := fun _ => pure ()
  /-- How long a command a key runs may take before it is logged as slow, in
  milliseconds. -/
  slowAfter : Nat := Loop.slowAfter
  /-- The interrupt key, which the host tells the library when its loop
  starts. -/
  interruptKey : Key := Watch.interruptKey
  /-- How the host makes the editor loop's frame when it is first needed:
  `Loop.start` in a frame of 0 by 0, which a resize changes. A test hands
  one that is refused, to see what the host does with no frame. -/
  start : TextM (Loop scheme) := Loop.start scheme ⟨0, 0⟩

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
  | .request .scene => (6, "")

/-- The signal an event's code and text stand for, if they stand for one. -/
def Signal.decode? (code : UInt64) (text : String) : Option Signal :=
  match code with
  | 0 => some (.request .reload)
  | 1 => some (.request (.run text))
  | 2 => some (.request .show)
  | 3 => some .marker
  | 4 => some .stop
  | 5 => some (.request (.spawn text))
  | 6 => some (.request .scene)
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

/-- The status line of the view `view` as `scene` prints it, a line of its
own after the view's: the view's id, then each field's face and its quoted
text, in order, or `-` for a status line with no field. -/
def statusLine (view : ViewId) (status : Array StatusField) : String :=
  let fields := status.map fun field => s!"{field.face.name} {field.text.quote}"
  s!"status {view.index}: {if fields.isEmpty then "-" else ", ".intercalate fields.toList}"

/-- The loop's state: everything the editor thread owns, for a host that
runs the input scheme `scheme`. -/
structure Running (σ : Type) (scheme : InputScheme) where
  /-- The config half of the editor's state. -/
  config : Config.State σ := {}
  /-- The texts and the snapshots made so far. -/
  texts : RealTexts
  /-- The display: with no window, a recorder of what is published, over the
  snapshots `texts` publishes. -/
  display : DisplayRecorder
  /-- The clipboard: with no window system, one the host keeps in the
  process, which every command it runs reaches. -/
  clipboard : Clipboard.InProcess
  /-- The editor loop's frame: none until the first event the loop takes or
  the first command it runs. -/
  frame : Option (Loop scheme) := none
  /-- Whether the loop took a step for the event being handled, and so
  published a scene after it: the host then publishes no second one. -/
  stepped : Bool := false
  /-- The jobs that are running, with their owners. -/
  jobs : Job.Jobs
  /-- Where the reload job that is running will leave its outcome. -/
  job : Option (IO.Promise (Config.Outcome σ)) := none
  /-- How many markers the loop has reached. -/
  markers : Nat := 0
  /-- Whether the driver has ended the loop. -/
  stopped : Bool := false

namespace Running

variable {σ : Type} {scheme : InputScheme}

/-- The reload job, on a thread of its own: builds the config, hands the
outcome over through `promise`, and wakes the editor thread with an event.
The wake-up is posted whatever happens, so the editor thread never waits for
a job that is gone. -/
def reloadJob (collaborators : Collaborators σ scheme) (base : Option σ)
    (chunks : Array (Config.Chunk σ)) (promise : IO.Promise (Config.Outcome σ)) : IO Unit := do
  try
    promise.resolve (← Config.build collaborators.elaborator collaborators.source base chunks)
  finally
    discard <| Ffi.postEvent .editor collaborators.wakeups 0 ""

/-- Feeds `event` to the reload reducer and performs its effects. A reload
job is started on a dedicated task, never run here: it reads files and
elaborates, and the editor thread goes on to its next event. -/
def reduce (collaborators : Collaborators σ scheme) (running : Running σ scheme)
    (event : Config.Event σ) : IO (Running σ scheme) := do
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
def finish (collaborators : Collaborators σ scheme) (running : Running σ scheme) :
    IO (Running σ scheme) := do
  let some promise := running.job | return running
  let outcome :=
    promise.result?.get.getD
      { base := none,
        diagnostics := #[Config.failure "reload" "the reload job ended without an outcome"],
        built := none }
  { running with job := none }.reduce collaborators (.finished outcome)

/-- Starts the job registered under `name` with `arguments`, for the owner
that registered it: its id, and the jobs with it, or `none` for a name no
job is registered under. The job runs on the pool; when it has ended the
runner posts a wake-up to the editor queue, with the job's id, from
whichever thread the job ended on. -/
def startJob (collaborators : Collaborators σ scheme) (running : Running σ scheme) (name : String)
    (arguments : List Argument := []) : IO (Option Nat × Running σ scheme) := do
  let some (owner, work) := running.config.work? name arguments | return (none, running)
  let wake (id : Nat) : BaseIO Unit :=
    (discard <| Ffi.postEvent .editor collaborators.jobs id.toUInt64 "" : IO Unit).catchExceptions
      fun _ => pure ()
  let (id, jobs) ← running.jobs.start owner name work wake
  return (some id, { running with jobs })

/-- Starts the job registered under `name`, with no arguments, as the driver
asks, and prints its id. -/
def spawn (collaborators : Collaborators σ scheme) (running : Running σ scheme) (name : String) :
    IO (Running σ scheme) := do
  let (id?, running) ← running.startJob collaborators name
  match id? with
  | some id =>
    collaborators.emit s!"spawn {name}: job {id}"
  | none =>
    collaborators.emit s!"spawn {name}: no such job"
  return running

/-- What the loop's programs watch: the library's interrupt flag, and the
clock the host's jobs wait on, so a test moves one clock for both. -/
def watch (collaborators : Collaborators σ scheme) : WatchHandler :=
  Watch.real collaborators.services.timers

/-- Drops an event of the window input that no loop takes: one that cannot
be read, or one that arrives when no frame could be made. It has been taken
off the queue all the same, so the flag is lowered for it if the library
marked it (`interrupt`, `Loop.lowerFor`). -/
def drop (collaborators : Collaborators σ scheme) (interrupt : Bool) : IO Unit :=
  (Loop.lowerFor interrupt).runM (watch collaborators)

/-- Runs `program`, a program of the editor loop, against the library, with
the recorder as the display, the library's interrupt flag and the jobs'
clock as what it watches and the host's own clipboard, and hands back its
result. The loop's own
programs put a refusal in the echo area and are not refused
(`Editor/Loop.lean`, "When publishing is refused"). One that is refused all
the same is never dropped in silence: it is printed,
`loop: refused: <error>`, and hands back nothing. What it made before the
refusal stays in the table of texts. -/
def attempt {α : Type} (collaborators : Collaborators σ scheme) (running : Running σ scheme)
    (program : EditorM α) : IO (Option α × Running σ scheme) := do
  let (result, texts) ←
    program.runReal running.texts running.display.handle (watch := watch collaborators)
        (clipboard := running.clipboard.handle)
  match result with
  | .ok value =>
    return (some value, { running with texts })
  | .error refusal =>
    collaborators.emit s!"loop: refused: {refusal.describe}"
    return (none, { running with texts })

/-- Publishes a scene of the frame's state, if there is a frame: what the
loop does after every event that is not the window's. A publish that is
refused is printed (`attempt`), and the frame stays as it was. -/
def publish (collaborators : Collaborators σ scheme) (running : Running σ scheme) :
    IO (Running σ scheme) := do
  let some frame := running.frame | return running
  let (published, running) ← running.attempt collaborators frame.publish
  return { running with frame := some (published.getD frame) }

/-- What a step of the loop is handed, from the registry as it is now: the
active keymaps of each view (`Config.Registry.activeMaps`: the modes of the
view's buffer, then every owner's key bindings), which the loop applies to
its own state; the lookup an invocation uses (`Config.State.command?`);
the host's threshold for a slow command; and what a command's state
requests are told of the registry (`Config.Registry.registered`: the modes
whose on-enter actions a major mode runs, the jobs' names and the ex
bindings). It is made for each window
event, so a reload changes it between two events. -/
def keys (collaborators : Collaborators σ scheme) (running : Running σ scheme) : Loop.Keys scheme :=
  { maps := running.config.registry.activeMaps scheme, command? := running.config.command?
    slowAfter := collaborators.slowAfter, registered := running.config.registry.registered }

/-- The loop's frame, made if there is none (`Collaborators.start`): the
frame is made when the loop is first needed, for a window event, a command
run by name or a job's command. Making it is printed when refused
(`attempt`), and there is then no frame. -/
def framed (collaborators : Collaborators σ scheme) (running : Running σ scheme) :
    IO (Option (Loop scheme) × Running σ scheme) := do
  if let some frame := running.frame then
    return (some frame, running)
  let (made, running) ← running.attempt collaborators collaborators.start
  return (made, { running with frame := made })

/-- How a command the loop ran ended, as the host prints it after
`run <name>: ` or `job <id> <name>: `. The host prints a line for every
ending, so this matches on each: a new ending gets its words here. -/
def describeEnding : Loop.Ending → String
  | .finished => "ok"
  | .refused refusal => s!"refused: {refusal.describe}"
  | .interrupted => "interrupted"
  | .gaveUp reason => s!"gave up: {reason}"
  | .noSuchCommand => "no such command"
  | .noWindow => "no window"

/-- Takes in what a step of the loop handed back: the loop after it is the
frame, what the step has to log is logged, what its command asked to be
written is written back to the stores, and each job its command asked for
is started, for the owner that registered it, and printed,
`job <id> <name>: started`. A step whose command asked for the config to be
reloaded (`Loop.Stepped.reload`) feeds the reload reducer a request, as the
driver's `reload` does. A step that said stop ends the loop.

Then each invocation the step answered, the continuation of a prompt its
command accepted, is run as a step of its own (`Loop.invoke`), with keys
made anew, so after the write above was written back, and that step is
taken in the same way, before the host pulls another event
(`Editor/Loop.lean`, "Prompts"). An answer's command prints nothing, as a
key's command prints nothing: what became of it is in the echo area. One
whose step is refused is printed (`attempt`), and the frame stays as it
was.

It has no termination proof: an answer's command can ask and accept again,
for ever, which is runaway code, and the interrupt key stops it at its next
request of the library. -/
partial def took (collaborators : Collaborators σ scheme) (running : Running σ scheme)
    (stepped : Loop.Stepped scheme) : IO (Running σ scheme) := do
  for entry in stepped.log do
    collaborators.log entry
  let mut running :=
    { running with
      frame := some stepped.loop, stepped := true, config := running.config.written stepped.write
      stopped := running.stopped || stepped.next == .stop }
  for start in stepped.starts do
    let (id?, started) ← running.startJob collaborators start.name start.arguments
    running := started
    -- The loop refused a name no job is registered under when the command
    -- asked, from the registry as it is in this event: one is found.
    if let some id := id? then
      collaborators.emit s!"job {id} {start.name}: started"
  if stepped.reload then
    -- What the driver's `reload` request does: one job at a time.
    running ← running.reduce collaborators .requested
  for invocation in stepped.answered do
    -- A step that said stop has ended the loop: nothing more is run.
    if running.stopped then
      break
    let some frame := running.frame | break
    let (answered, attempted) ←
      running.attempt collaborators (frame.invoke (running.keys collaborators) invocation)
    running := attempted
    if let some answered := answered then
      running ← running.took collaborators answered
  return running

/-- Handles an event from the window input: prints a key press with its
identity, makes the frame if there is none, and has the editor loop take the
event (`Loop.take`), which lowers the interrupt flag for an interrupt key,
steps the event, runs the command a key yields and publishes a scene. What
the step handed back is taken in (`took`). A close request ends the loop.

Making the frame and the step are each printed when refused (`attempt`):
after a refused step the frame stays as it was. With no frame made the event
is dropped (`drop`), which lowers the flag for an interrupt key, since no
loop took it off the queue. -/
def input (collaborators : Collaborators σ scheme) (running : Running σ scheme)
    (received : Received) : IO (Running σ scheme) := do
  if let .key which true _ := received.event then
    collaborators.emit s!"key arrived: {which.describe}"
  let (made, running) ← running.framed collaborators
  let some frame := made |
    drop collaborators received.interrupt
    return running
  let (stepped, running) ←
    running.attempt collaborators (frame.take (running.keys collaborators) received)
  match stepped with
  | some stepped =>
    running.took collaborators stepped
  | none =>
    return running

/-- Runs the command called `name` through the loop (`Loop.runNamed`), as
the driver asks, and prints how it went: the command is guarded, its state
requests are answered, it is rolled back if it does not run to its end, and
a scene is published after it. The frame is made if there is none. What the
step handed back is taken in (`took`). With no frame made, which the refusal
printed before it explains, it says `no frame` and runs nothing. -/
def run (collaborators : Collaborators σ scheme) (running : Running σ scheme) (name : String) :
    IO (Running σ scheme) := do
  let (made, running) ← running.framed collaborators
  let some frame := made |
    collaborators.emit s!"run {name}: no frame"
    return running
  let (stepped, running) ←
    running.attempt collaborators (frame.runNamed (running.keys collaborators) name)
  let some stepped := stepped | return running
  collaborators.emit s!"run {name}: {describeEnding ((stepped.ended).getD .finished)}"
  running.took collaborators stepped

/-- Deals with the job `id`, which has ended, on the editor thread: takes its
result, and for a job that finished has the loop run the command it
finished with (`Loop.deliver`), as every command is run, and prints how it
went. The frame is made if there is none. A job that is no longer in the
table, because its owner was removed, is not dealt with: its handler does
not run.

The delivery is run by `Job.finishWith`, which hands the run what the job
held and settles the job once it has run, with what the loop's programs
watch (`watch`): the command's guard asks the library's interrupt flag. It
is handed the host's clipboard too, so a job's command reaches the one a
key's does. -/
def ended (collaborators : Collaborators σ scheme) (running : Running σ scheme) (id : Nat) :
    IO (Running σ scheme) := do
  let (result, jobs) ← running.jobs.finish id
  let running := { running with jobs }
  let some (entry, outcome) := result | return running
  let label := s!"job {entry.id} {entry.name}"
  match outcome with
  | .finished command =>
    let (made, running) ← running.framed collaborators
    let some frame := made |
      -- No loop will run the command: what the job held is released.
      entry.handle.settle
      collaborators.emit s!"{label}: no frame"
      return running
    let (result, texts) ←
      Job.finishWith collaborators.held entry.handle
          (frame.deliver (running.keys collaborators) label command) running.texts
          running.display.handle (watch collaborators) running.clipboard.handle
    let running := { running with texts }
    match result with
    | .ok stepped =>
      collaborators.emit s!"{label}: {describeEnding ((stepped.ended).getD .finished)}"
      running.took collaborators stepped
    | .error refusal =>
      collaborators.emit s!"loop: refused: {refusal.describe}"
      return running
  | .failed message =>
    collaborators.emit s!"{label}: failed: {firstLine message}"
    return running
  | .cancelled =>
    collaborators.emit s!"{label}: cancelled"
    return running

/-- A scene as `scene` prints it, read from the text store as it is now: its
frame, then each view, its snapshot's text and its markers' offsets, and
after each view's line its status line (`statusLine`). `published` is how
many scenes have been published. -/
def sceneLines (scene : Scene) (published : Nat) : TextM (Array String) := do
  let focused :=
    match scene.focused with
    | some id => toString id.index
    | none => "-"
  let preedit :=
    match scene.preedit with
    | some text => text.quote
    | none => "-"
  let mut lines :=
    #[s!"scene {scene.size.width}x{scene.size.height}, focused {focused}, echo {scene.echo.quote}, preedit {preedit}, published {published}"]
  for view in scene.views do
    let .anchor scroll ← view.scroll.text.marker view.scroll | throw .noSuchMarker
    let selections ←
      view.selections.mapM fun id => do
          let .selection selection ← id.text.marker id | throw .noSuchMarker
          return " ".intercalate
              (selection.ranges.map fun range => s!"{range.anchor}..{range.head}").toList
    let rect := view.rect
    lines :=
      (lines.push
            s!"view {view.id.index} {rect.x},{rect.y} {rect.width}x{rect.height}: {(← view.snapshot.read).quote}, scroll {scroll.offset}, selections {" ".intercalate selections.toList}").push
        (statusLine view.id view.status)
  return lines

/-- Prints the last scene published, or that there is none. -/
def scene (collaborators : Collaborators σ scheme) (running : Running σ scheme) :
    IO (Running σ scheme) := do
  let some scene ← running.display.last? |
    collaborators.emit "scene: none"
    return running
  let (result, texts) ← (sceneLines scene (← running.display.published)).runReal running.texts
  match result with
  | .ok lines =>
    for line in lines do
      collaborators.emit line
  | .error refusal =>
    collaborators.emit s!"scene: refused: {refusal.describe}"
  return { running with texts }

/-- Prints the commands, the texts and the stores. -/
def «show» (collaborators : Collaborators σ scheme) (running : Running σ scheme) : IO Unit := do
  collaborators.emit (" ".intercalate ("commands:" :: running.config.registry.names.toList))
  for index in [0:running.texts.documents.size] do
    -- A text a command released has no document, and no line.
    if let some (some document) := running.texts.documents[index]? then
      collaborators.emit s!"text {index}: {(← document.read).quote}"
  for cell in running.config.cells.cells do
    collaborators.emit s!"store {cell.name} v{cell.version}: {render cell.value}"

/-- Handles one event of the editor queue that is not the window's. -/
def other (collaborators : Collaborators σ scheme) (running : Running σ scheme)
    (event : Ffi.Event) : IO (Running σ scheme) := do
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
    | some (.request .scene) =>
      running.scene collaborators
    | some .marker =>
      return { running with markers := running.markers + 1 }
    | some .stop =>
      return { running with stopped := true }
    | none =>
      return running

/-- Handles one event of the editor queue to its end. An event from the
window input goes to the editor loop (`input`), which publishes a scene after
it. So does a command the loop runs for another event: the driver's `run`,
and a finished job's command. After any other event, a scene is published
once there is a frame, unless the driver has ended the loop. A window event
that cannot be read is dropped (`drop`), which lowers the interrupt flag for
a key that carries the library's mark (`Event.interruptMarked`), since the
event has been taken off the queue. -/
def handle (collaborators : Collaborators σ scheme) (running : Running σ scheme)
    (event : Ffi.Event) : IO (Running σ scheme) := do
  if event.source.kind == .window then
    match Event.ofFfi event with
    | .ok received =>
      running.input collaborators received
    | .error _ =>
      drop collaborators (Event.interruptMarked event)
      return running
  else
    let running ← ({ running with stepped := false }).other collaborators event
    -- A step of the loop published its own scene.
    if running.stopped || running.stepped then
      return running
    else
      running.publish collaborators

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

/-- The cells the headless host's display lays text out in: 8 pixels across
and 16 down, as the display contract's larger size. -/
def cells : Display.Cells :=
  { advance := 8, lineHeight := 16 }

/-- The registry a host starts with: what compiled code hands it, its
commands, jobs, key bindings, modes and ex bindings, for the owner
`compiled`, before any config. -/
def compiled {σ : Type} {scheme : InputScheme} (collaborators : Collaborators σ scheme) :
    Config.Registry :=
  ((((({} : Config.Registry).replace .compiled collaborators.commands).replaceJobs .compiled
                collaborators.compiledJobs).replaceBindings
            .compiled collaborators.bindings).replaceModes
        .compiled collaborators.modes).replaceEx
    .compiled collaborators.ex

/-- What the editor thread holds as its loop starts: the compiled registry
(`compiled`), no texts, a recorder in `cells` over the table of snapshots
the text binding publishes, a clipboard that holds no text, no jobs and no
frame. -/
def Running.new {σ : Type} {scheme : InputScheme} (collaborators : Collaborators σ scheme) :
    IO (Running σ scheme) :=
  return {
      config := { registry := compiled collaborators }
      texts := RealTexts.over collaborators.published
      display := ← DisplayRecorder.new cells collaborators.published.reader
      clipboard := ← Clipboard.InProcess.new
      jobs := { services := collaborators.services } }

/-- The editor thread: pulls the editor queue and handles each event to its
end, until the driver ends the loop or the queues are quit. After each event
it publishes in `progress` how many markers it has reached, whether a reload
is running, and how many jobs are.

Before the first event it registers what compiled code hands it (`compiled`),
and tells the library its interrupt key; when it ends it leaves the library with
none, so that no key raises the flag while no loop takes keys off the
queue. -/
def loop {σ : Type} {scheme : InputScheme} (collaborators : Collaborators σ scheme)
    (progress : IO.Ref Progress) : IO Unit := do
  discard <| Event.setInterruptKey (some collaborators.interruptKey)
  let mut running ← Running.new collaborators
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
  -- Nor will anything take a key off the queue, so none is to raise the flag.
  discard <| Event.setInterruptKey none

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
def start {σ : Type} {scheme : InputScheme} (collaborators : Collaborators σ scheme) : IO Host := do
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
  to it: it is still inside an event. -/
  | unanswered
  /-- The editor thread's loop has ended: a command quit the editor, or the
  window was asked to close. Nothing more will be handled. -/
  | ended
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

/-- Sends a press of `key`, with no text, as the window would report it: it
goes through the library's window input (`Event.post`), onto the editor
queue after everything sent before. Throws if the queue refuses it, which it
does once the queues are quit. -/
def press (_ : Host) (key : Key) : IO Unit := do
  unless ← Event.post (.key key true "") do
    throw (IO.userError "the editor queue refused a key: it has been quit")

/-- Sends `text` as an input method's composition would end with it, as the
window would report it: through the library's window input (`Event.post`),
onto the editor queue after everything sent before. Throws if the queue
refuses it, which it does once the queues are quit. -/
def commit (_ : Host) (text : String) : IO Unit := do
  unless ← Event.post (.commit text) do
    throw (IO.userError "the editor queue refused a commit: it has been quit")

/-- Waits until the editor thread has handled everything sent so far and
`busy` no longer holds of its progress, for at most `patience` milliseconds.
Says what the wait came to: `still` if it ran out with the editor thread up
to date and `busy` still holding.

A loop that has ended, or ends while the wait runs, is answered `ended` as
soon as it is seen: its task has finished, so nothing it was waited for
will happen, and the wait does not run out its patience. The loop's last
progress is not read then: the loop does not publish it once it has ended,
so it may still say a job is running. -/
def waitWhile (host : Host) (patience : Nat) (busy : Progress → Bool) (still : Wait) : IO Wait := do
  if ← IO.hasFinished host.thread then
    return .ended
  let marker ← host.posted.modifyGet fun posted => (posted + 1, posted + 1)
  host.post .marker
  let settled ←
    within patience do
        if ← IO.hasFinished host.thread then
          return true
        let progress ← host.progress.get
        return progress.markers >= marker && !busy progress
  if ← IO.hasFinished host.thread then
    return .ended
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
did not end, each within `patience` milliseconds. A loop that had ended by
itself, because a command quit the editor, has nothing to settle. -/
def stop (host : Host) (patience : Nat) : IO Bool := do
  let wait ← host.await patience
  let ended ← host.halt patience
  return (wait == .settled || wait == .ended) && ended

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
  /-- Send a press of this key, with no text, as the window would. -/
  | key (key : Key)
  /-- Send this text, as an input method's composition would end with it. -/
  | commit (text : String)
  deriving DecidableEq, Repr

/-- The name a directive gives after its keyword, which is the first
`keyword` characters of `line`; `none` if there is none. -/
def named (line : String) (keyword : Nat) : Option String :=
  let name := (line.drop keyword).trimAscii.toString
  if name.isEmpty then none else some name

/-- The logical key a `key` directive names: one character, or a named key
in angle brackets (`<Escape>`). -/
def logicalKey? (part : String) : Except String LogicalKey :=
  if part.length == 1 then .ok (.character part)
  else
    if part.length > 2 && part.startsWith "<" && part.endsWith ">" then
      .ok (.named ⟨((part.drop 1).dropEnd 1).toString⟩)
    else .error s!"`{part}` is not a key: expected one character or a <Name>"

/-- The physical key a `key` directive names: a W3C UI Events code, or `-`
for none. -/
def physicalKey (part : String) : PhysicalKey :=
  if part == "-" then .unidentified else .code part

/-- The modifiers a `key` directive names: `shift`, `control`, `alt` and
`super` joined with `+`, or `-` for none. -/
def modifiers? (part : String) : Except String Modifiers :=
  if part == "-" then .ok {}
  else
    (part.splitOn "+").foldlM
      (fun held name =>
        match name with
        | "shift" => .ok { held with shift := true }
        | "control" => .ok { held with control := true }
        | "alt" => .ok { held with alt := true }
        | "super" => .ok { held with superKey := true }
        | _ =>
          .error
            s!"`{name}` is not a modifier: expected shift, control, alt or super, joined with +, or -")
      {}

/-- The key a `key` directive's line names after its keyword. -/
def keyDirective? (line : String) : Except String Directive :=
  match ((line.drop 4).trimAscii.toString.splitOn " ").filter (!·.isEmpty) with
  | [logical, physical, held] => do
    let logical ← logicalKey? logical
    let modifiers ← modifiers? held
    return .key { logical, physical := physicalKey physical, modifiers }
  | _ => .error s!"`{line}` is not a key: expected key <logical> <physical> <modifiers>"

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
                if line.startsWith "key " then some <$> keyDirective? line
                else
                  if line == "scene" then .ok (some (.request .scene))
                  else
                    if line == "commit" || line.startsWith "commit " then
                      match named line 6 with
                      | none => .error s!"`{line}` commits no text"
                      | some text => .ok (some (.commit text))
                    else
                      .error
                        s!"`{line}` is not a directive: expected reload, run <name>, spawn <name>, show, scene, settle, join, key <logical> <physical> <modifiers> or commit <text>"

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
  | .ended => none

/-- Runs `script` against a host of its own, as its driver, and stops the
host: sends each request in order and waits at each `settle` and each
`join`. `none` when the script ran to its end, or a command quit the editor
before it, and otherwise why it could not: the editor thread did not
settle, a job did not end, or the loop did not stop, within `patience`
milliseconds.

Once the loop has ended by itself, because a command quit the editor, the
lines that are left are not run: the script is read no further at a wait
that answered `ended`, and before each line when the loop's task has
finished.

A `settle` or a `join` that runs out ends the loop at once, whether a reload
or a job is running or not. A rejected reload is something to print, not a
failure, and so is a job that fails. A job the script leaves running is
cancelled when the loop ends. -/
def run {σ : Type} {scheme : InputScheme} (collaborators : Collaborators σ scheme)
    (script : Array Line) (patience : Nat) : IO (Option Failure) := do
  let host ← start collaborators
  for line in script do
    -- A command quit the editor: the lines after it are not run.
    if ← IO.hasFinished host.thread then
      break
    let wait ←
      match line.directive with
      | .request request =>
        host.send request
        continue
      | .key key =>
        host.press key
        continue
      | .commit text =>
        host.commit text
        continue
      | .settle =>
        host.await patience
      | .join =>
        host.join patience
    if wait == .ended then
      break
    if let some failure := wait.failure (some line.number) then
      discard <| host.halt patience
      return some failure
  -- The end of the script: wait for a reload that is still running, then
  -- stop the loop. A loop that has ended by itself is neither waited for
  -- nor stopped, and `halt` throws the error it ended with, if it did.
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
with status 0 when the script ran to its end or a command quit the editor
before it, and with 1 when it could not,
after saying why on stderr (the script cannot be read, a wait ran out with a
reload or a job still running, or the editor thread did not answer).

Before the loop starts it warms the pool, so the first burst of jobs finds
every thread made, and starts the completion pump on a dedicated task. The
host's jobs wait on the library's timer service and its file service, which
reads the snapshots the loop publishes.

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
  -- The published table and what jobs hold are made before the services:
  -- the file service reads the one and keeps its loads in the other.
  let published ← Snapshots.new
  let held ← Job.HeldSnapshots.new
  let failure ←
    run (scheme := Vim.Default.scheme)
        { elaborator := Config.Elaborate.elaborator { sysroot, oleanDir },
          source := Config.Directory.source configDir, emit := IO.println,
          services :=
            { completions, timers := Job.realTimers completions,
              files := Job.realFiles completions published.reader held },
          published, held, requests := 1, wakeups := 2, jobs := 3
          commands := Files.commands ++ Minibuffer.commands ++ Evil.commands ++ Ex.commands
          compiledJobs := Files.jobs
          modes := Minibuffer.modes, ex := Ex.bindings, log := IO.eprintln } directives
        settlePatience
  (← IO.getStdout).flush
  if let some failure := failure then
    IO.eprintln s!"editor: {failure.describe settlePatience}"
  -- Shutdown: quit lets every task parked in a pull return, the pump among
  -- them, and the exit is explicit, because a task may still be blocked in
  -- the library.
  Ffi.quit
  IO.Process.exit (if failure.isNone then 0 else 1)

end Editor.Headless
