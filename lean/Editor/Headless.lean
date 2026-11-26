import Editor.Clipboard.InProcess
import Editor.Config.Directory
import Editor.Config.Display
import Editor.Config.Elaborate
import Editor.Config.Lakefile.Toml
import Editor.Config.Packages
import Editor.Config.Reload
import Editor.Display.Real
import Editor.Display.Recorder
import Editor.Event.Queue
import Editor.Headless.CommandLine
import Editor.Headless.Journal
import Editor.Headless.Journal.Real
import Editor.Headless.Queue.Real
import Editor.Headless.Wait
import Editor.InferredWait
import Editor.Job.Fake
import Editor.Job.Jobs
import Editor.Job.Pool
import Editor.Job.Real
import Editor.Loop
import Editor.PackageSet.Build
import Editor.RealHost
import Editor.Restart.Real
import Editor.SyntaxTree.Real
import Editor.Text.Real
import Editor.Watch.Real
import Editor.Window
import EnvironmentApi

/-!
# The headless host

The editor with no window: a loop on the editor queue that loads a config,
runs its commands against the Rust library and prints what happened, one line
at a time. It exists for integration tests, and it is the first runtime of
the config session.

## The loop

A host is had only inside its bracket, `withHost`, which starts the loop on a
dedicated task, the editor thread, runs its body against the host, and
returns only once the loop has ended, whether the body returned or threw: a
loop still running is asked to stop, and its task is waited for with no
deadline. A loop not ended `guard` milliseconds after it was asked is said
as a hang, once (`editor: a hang: …`), and still waited for: the guard
reports a hang, it never ends the wait. `Host`'s constructor and `start` are
private, so nothing outside this module makes a host, and none outlives
its loop. `withHostEnding` hands the loop's end back instead of throwing
its error, for the window mode, whose exit status says it. The loop pulls the
editor queue and handles one event to its end before the next: one turn
(`Running.turn`), after which it publishes its progress (`Running.progress`),
and at its end it winds down (`Running.wind`). Two drivers take those turns:
the real loop (`loop`), on its dedicated task over the library's editor
queue, and, for tests, a host stepped on its caller's thread over an
in-memory queue (`Editor/Headless/Stepped.lean`). The core posts through the
queue its collaborators carry (`Collaborators.queue`,
`Editor/Headless/Queue.lean`), and a real host refuses one a stepper
drains. It owns the
config half of the editor's state (`Config.State`) and the table of texts
(`RealTexts`), feeds the reload reducer (`Config.step`) and performs its
effects, and runs the command loop's programs with `EditorM.runReal`, with
the display and the clipboard its collaborators make: in the headless mode,
a display recorder (`Editor/Display/Recorder.lean`) and a clipboard of its
own (`Editor/Clipboard/InProcess.lean`). Every
command it runs, it runs through the command loop ("The editor loop").

A reload does not run on the editor thread. The reducer's `start` effect
becomes a dedicated task, the reload job, which reads the source, elaborates
the files that changed and runs `setup` (`Config.build`), resolves a promise
with the outcome and posts a wake-up to the editor queue. The editor thread
meets the wake-up like any event, takes the outcome and feeds it to the
reducer: a config is installed between two events, and the editor answers
events while a file elaborates. It is a dedicated task, not one of the
pool's: it reads files, and writes the module data of the config files
under `Config/` to a temporary directory (`Collaborators.dispose`). When the
collaborators hold a generator (`Collaborators.generator`), it also creates
the config directory's lakefile and toolchain file when they are absent;
a host handed none writes nothing into the config directory.

It knows a request from its driver, the wake-up of a reload job, the wake-up
of a job that has ended, an event of the library's scripted source, an event
from the window input, the library's report that a parse of a highlighted
text was delivered (`Event.parsed`, from the library's source), and quit,
and nothing else.

## The editor loop

The host runs the command loop (`Editor/Loop.lean`) beside the config
session, and calls the same operations of the reducer and of the job table
as before, so reload and job completion work as they did.

- **The host is given its input scheme**, as a parameter of its
  collaborators' type (`Collaborators β σ scheme`), and its loop runs that one
  (`Loop scheme`). The executable's is the one its package set supplies
  (`Editor/Main.lean`, "The input scheme"); a test hands a host the test
  scheme.
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
  follow-up. The reload's report is printed as the driver's is.
- **A theme a command loaded is switched to** when its step is taken in
  (`Loop.Stepped.theme`, `loadTheme`, `Editor/Api.lean`): the host feeds
  the reload reducer a choice (`Config.Event.choose`), which hands the
  display the theme (`Config.retheme`), and publishes a scene, so the
  switch is drawn at once: the step's own scene was published in the theme
  before. No reload runs.
- **A reload's error is said in the echo area** (`Config.Report.echo`,
  `Running.said`), whoever asked for the reload: a rejected one's first
  error, with its place and the first line of its message, and how many
  more there are. The old config keeps running: a rejected reload installs
  nothing. A reload that installs says nothing there, so what a command
  said stays, unless its config named a theme nobody registered, which it
  says (`reload: no theme is registered as …`); and it hands the display
  the new theme (`Config.retheme`),
  which the next scene is drawn in and sized by. With no frame made yet, the error is
  kept and said when the frame is made (`Running.unsaid`); a command that
  makes the frame clears the echo before it runs, as any command does, so
  it shows when the frame is made for a window event that runs none.
- **The window's appearance follows the paper.** When the window says it
  opened, the reload reducer is told (`Config.Event.windowOpened`), and
  from then on its `appearance` effects are asked of the window through
  the display (`Display.FrameRequest.appearance`): at the open, and after
  a reload or a choice of theme that changes whether the paper is light or
  dark. No headless script posts `windowOpened`, so the headless mode asks
  for none.
- **A window event goes to the loop** (`Running.input`): `Loop.take`, run
  against the library with the recorder as the display, handles it and
  publishes a scene. A key press is still printed with its identity, as the
  host's own output. Any step that says stop ends the loop, as the
  driver's `stop` does: a command asked the editor to quit and it can
  leave (`Editor/Loop.lean`, "Quit"). A close request is a quit by `q`'s
  rule: it ends the loop once the editor can leave, and while a buffer that
  holds a file has unsaved changes the loop goes on, with the refusal in
  the echo area. A window event that cannot be read is ignored.
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
- **Packages are registered when the loop starts** (`Running.new`), before
  any config: the host is handed an array of them
  (`Collaborators.packages`, `Editor/Package.lean`) and registers each, in
  the array's order, for the owner named after it
  (`Config.State.ofPackages`, `Editor/Config/Packages.lean`). Every
  command, job, key binding, mode, ex binding, theme, mode-line segment,
  language, compile contribution, completion source, style and display,
  at-point source and menu the host has before config is a package's: the
  host registers nothing else, and imports no module that defines a
  package (`.agents/rules/structure.md`, "Host imports"). A host handed none starts with
  an empty registry and publishes no menu bar.
  - **A reload replaces config's registrations and never a package's**, so
    a package's commands run when config fails to load, and config's
    command of a package's command's name runs in its place until a reload
    drops it. A package's job is started by a command, by its name, as
    config's is, for the package's owner: a reload that installs cancels
    config's jobs only, so a package's job runs across a reload.
  - **A package that is refused is logged and skipped** (`Collaborators.log`,
    the line prefixed with `package: `): one with an empty, reserved or
    repeated name, one whose `setup` is refused, or one that sets what only
    config may choose. The others register and the loop starts.
  - **The executable's hosts are handed the packages of its package set**:
    those of each package of the set (the core's Lake package lists
    none), which the executable's generated root passes through
    `Editor.Main.run` to `main` here and to the window mode's
    (`docs/design/packages.md`, "The package set and its build"). The
    core's are 23, each in
    its feature's `Compiled.lean`, which says what it registers. Among
    them: the file commands and their jobs, the first commands `show`
    lists (`files`); the minibuffer's commands and its mode, which the Vim
    scheme's minibuffer state binds to `<Enter>` and `<Escape>`
    (`minibuffer`); evil's commands, which the Vim scheme's keys name, so
    with no config the editor moves, edits, undoes, repeats and scrolls
    (`evil`); the ex line's commands and the ex names that ship (`ex`),
    with the buffer commands three of them run (`buffers`); the frame's
    commands and their bindings, `s-q` to `quit` among them
    (`frame-commands`), and the menu bar (`menu`); the command that loads
    a theme and the themes that ship (`themes`); the command prompt and
    the binding search (`execute-command`, `binding-search`); the
    workspace commands and the job a file's open starts to find its
    workspace (`workspace`); project search's commands, its results
    buffer's mode and its jobs (`project-search`); the working sets'
    commands, a set's buffer's mode and the jobs that read and write a
    workspace's sets under the state directory (`working-set`); the
    session restore's jobs, which restore a session at start-up and write
    its index, and its command and mode (`restore`); the status
    buffer's commands, jobs and modes,
    and the gutter's (`version-control`, `version-control-gutter`); and
    the `code` mode with the languages that ship (`languages`). The ex
    line is handed no key binding: the Vim scheme's keys are its states'
    own keymaps. Every default key names a command a package registers.
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
  A theme switch a command asked for is followed by one more, after the
  step's own. The driver's `stop` publishes nothing. The count is printed
  only by `published`, never in a scene line: a library parse, a Rust
  poster, a real-time watch or the render loop each post from outside idle,
  in one delivery or two depending on the run, so a script asks for it only
  where no scene before it came from such a source.
- **A refusal is never dropped.** The loop puts a refusal in the echo area
  of the scene, a handler's and one met while publishing alike
  (`Editor/Loop.lean`, "When publishing is refused"), so `scene` prints it.
  The loop's programs are not themselves refused; the host runs each
  through `Running.attempt` all the same, which prints one that is,
  `loop: refused: <error>`, and keeps the frame it had. With no frame made,
  the event is dropped and the next window event tries again.
- **A child's environment** (`Editor/Process/Environment.lean`): the host's
  jobs share one state of environments (`Job.Services.environments`), which
  the executable makes for its mode in `shipped`
  (`reportedEnvironments`): `.headless` for the headless mode, `.window`
  with the home directory for the window mode. What it reports, a failed
  lookup once for a directory and source (once per run for the base), is
  posted under the Lean source id `Collaborators.environment`, and said in
  the echo area for the next scene (`Running.said`). A reload that installs
  reads the registry it installed through `environment-api`
  (`EnvironmentApi.ofRegistry`: every directory source registered, and the
  base `Config.Registry.baseName` names) and hands the layers to
  `Job.Environments.install`, which drops every cached environment, the
  base's and each directory's. A base name nothing answers to installs no
  base, so the environments keep the one they had, and the reload's report
  names it (`Config.Report.unknownBase`), which is printed as `base: …` and
  said in the echo area. A config rejected at start-up installs nothing, so
  children start with the editor's own environment until a reload
  installs. Pinned by `ConfigTest.environmentHostChecks`.
- **The host is handed its display** (`Collaborators.display`), a maker
  over the table of snapshots the text binding publishes, and holds what it
  makes as a `Host.Display`: what answers the loop's requests, wrapped so
  that the host keeps the last scene and counts them, which the `scene`
  request prints, and the rows queries answered since the publish before
  the last one, with what each was answered. It holds how to set the
  display's theme, the name of the theme it was last handed and the name
  of the one the last scene was drawn in, and, where the display lays frames out, how to read the
  rows of its frame. The headless mode's display is a recorder
  (`Editor/Display/Recorder.lean`, `Host.Display.recorder`), in cells 8
  pixels across and 16 down (`cells`), which sets no theme and lays out no
  frame. The real binding has a maker too (`Host.Display.real`).
- **The host is handed its clipboard** (`Collaborators.clipboard`), a maker
  of a clipboard handler, and every command's clipboard requests are
  answered from what it makes, a key's, a command's run by name and a
  finished job's alike. The headless mode's is the host's own
  (`Editor/Clipboard/InProcess.lean`): with no window system there is no
  system clipboard, so the host keeps a text in the process. What one
  command writes the next reads; no other program sees it, and it starts
  holding no text.
- **The host is handed its syntax tree** (`Collaborators.syntaxTree`), a
  maker of a syntax tree handler over the read half of the table of
  snapshots its text binding publishes. It is made once, when the loop
  starts (`Running.new`), and kept (`Running.syntaxTree`), so the queries it
  compiles live as long as the loop; every command's syntax tree requests
  are answered from it, a key's, a command's run by name and a finished
  job's alike. By default it is the real binding over the library's syntax
  service (`Editor/SyntaxTree/Real.lean`), in both modes. What setting a
  major mode with a syntax asks of it is `Editor/Highlight.lean`'s.

The collaborators are handed in (`Collaborators`): the elaborator and the
source of the config session, `emit`, the port every line of output goes
through, the services the loop's jobs wait on, which a test makes of a fake
clock, and the two tables the host makes before those services: the table of
snapshots the loop's text binding publishes, of which the loop is the one
writer, and what the jobs hold. Beside them, each with a default: the
packages the host registers, the log, the threshold for a
slow command, the interrupt key, how the frame is made
(`Collaborators.start`), and how the display, the clipboard and the
syntax tree are made (`Collaborators.display`, `Collaborators.clipboard`,
`Collaborators.syntaxTree`).

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
- **A job's posts run as commands while it runs** (`post`,
  `Editor/Job.lean`). The runner hands each, on the job's thread, to what
  `startJob` gave it, which keeps it in the host's mailbox (`Job.Mailbox`)
  with the job's id and posts an event under the Lean source id
  `Collaborators.posts`, its code the job's id. The editor thread meets the
  event in its turn, takes that job's oldest post, and, while the job is
  still in the table, has the loop run it as a finished job's command is
  run (`Running.posted`, `runPosted`), labelled `job <id> <name>`, and
  prints how it went. So a job's posts run in the order it made them, each
  between two events, and all before its own command, whose wake-up is
  posted after its last post's event. The post of a job a cancel or a
  reload removed is dropped, unprinted.
- **A finished job's command is handed what the job held.** A job that
  loaded a file holds the snapshot the load made. The host runs the
  delivery with `Job.finishWith` (`Editor/Job/Real.lean`): the run is handed
  those snapshots, so the command can take one into the text store
  (`JobSnapshotId.adopt`, `JobSnapshotId.toText`), and the job is settled
  once the delivery has run, which releases what it held. It hands
  `finishWith` what its loop watches (`Running.watch`), so the command's
  guard asks the library's interrupt flag, its clipboard and its syntax
  tree (`Running.syntaxTree`), so a job's command that sets a major mode
  with a syntax attaches and highlights through the host's binding. A job
  that failed or was cancelled settled itself.
- **A reload that installs cancels the old config's jobs**: the reducer's
  `cancelJobs` effect, performed before the reload's report, takes the
  owner's jobs out of the table and cancels them. A wake-up one of them had
  already posted then finds nothing, and its handler never runs. A rejected
  reload cancels nothing.
- **The loop's own work is started the same way** (`Loop.Stepped.spawns`):
  a prompt's match job, as a job of the owner of the style it runs, under
  its key and its label (`Running.startWork`, `Running.launch`), after the
  step's cancels and starts. So an install that cancels config's jobs
  cancels a match of config's style too.
- **The publish after an event the loop does not take reconciles a
  prompt's jobs** (`Running.publish`, `Loop.completionJobs`): after an
  install, a theme switch, or any other such event. It is how a match an
  install ended is spawned again, with the new config's style, with no key
  typed. A publish that changes nothing reconciles to nothing. The window
  mode is this host, so there is no other publish path.
- **The loop cancels every job when it ends**: nothing would deal with their
  results.

## Restoring a session

With a state directory (`Collaborators.stateDirectory`: the window mode's,
or the headless mode's `--state`), the host's first request is `restore`
(`Request.restore`; `run` sends it before the script, the window mode as its
first start). It starts the job `restore` with the state directory, printed
`job <id> restore: started`, and holds every request of the driver that
follows (`Running.heldRequests`) until the restore has finished: its second
half's command has run (`Restore.Kept.restored`, `Editor/Restore/Run.lean`),
or neither of its jobs is in the table any more (`settleRestore`). Then it
handles them in order. Window events, markers and the jobs' wake-ups are
handled meanwhile, and `Host.await` waits while a restore is in flight
(`Progress.restoring`), so a wait for the start-up reload waits for it too.
With no `restore` job registered, the request does nothing.

**The journal.** Each step's journal orders (`Loop.Stepped.journal`,
`Editor/Restore.lean`) are handed to the file service through
`Collaborators.journal`, unobserved (`Journal.real`, the library's), and
the snapshots they name released after (`journaled`); what failed is said
once for each path, in the echo area and to the log (`journalFailed`). The
journal's drain (`Journal.drained`) is a flush of the file service
(`Job.Services.flushed .files`), completed once every order handed before it
has been worked; nothing polls the service's pending count. A host's end
waits for it, at most `drainPatience`, on purpose in real time, so quitting
never hangs on a stuck file system. The script's `journalled` waits for it;
`indexed` waits until the session index is written, moving the fake clock
past each write's delay (`Progress.indexing`), and until no job runs but
those the script spawned (`Progress.background`), and then for the drain; `abort` ends the process at once
with the status 134 and no shutdown (`IO.Process.exit`): not the signal,
which on a macOS desktop raises the crash reporter.

**What the session index is handed.** The reported jobs running
(`Running.reported`, each with its owner and key), how many others run
(`Running.otherJobs`, a count only of the jobs neither reported nor
restarted by their owner) and the config state's cells kept across a
restart (`Config.State.keptCells`, made only when the reconciler forces
them, at its revision `cellsRevision`) are in the keys of every step
(`Loop.Keys.running`, `Loop.Keys.otherJobs`, `Loop.Keys.stores`), and the
cells a restore read (`Loop.Stepped.restoredCells`) are taken in with the
write a step asked for (`Config.State.restoreCells`). The script's `workspaces`
prints the workspace table.

## Restarting

A restart (`Editor/Restore/Restart.lean`) ends with a step that hands the
host a plan (`Loop.Stepped.handOver`): the session and the hand-over record
are written. When a journal order has failed since the hand-over began
(`Running.handingFrom`, against the failures `journalFailed` counted), the
host runs `restart-abandon` with `restart: a journal write failed
(<path>); the session was not handed over`, as an invocation no key
yielded, and the loop goes on. Otherwise it ends its loop and keeps the
plan (`Progress.handOver`). The headless mode then prints `restart: the
session is handed over`, with ` (no launcher, so no fallback)` after it for
a run no launcher started, shuts down as at an end and execs the plan
through its collaborators' exec (`Collaborators.replace`, `Restart.real`
for the executable's hosts), and nothing else; the window mode closes its
window first (`Editor/Window/Real.lean`). Both exec with `Restart.Plan.exec`
("The exec", in `Editor/Restart/Handover.lean`): an exec that fails is
said, `editor: the restart could not start <program>: <reason>; the
session is kept and the next start restores it`, with status 1.

With `--restore` (`Restart.Launch.restore`), the restore request names the
index handed over (`Request.restore`), which the restore takes in place of
the one the version rule chooses. The script's `restarted` waits, within its
patience, until the loop has ended with a hand-over, and the script then
stops in this process; the next run, started with `--resume <k>`, skips the
script through the k-th `restarted` (`resumed`) and goes on from there.

## One loop at a time

The editor queue is process-wide, so two live loops would take each other's
events: hosts in one process follow one another and never overlap. A host
posts under source ids it is given, and its loop ignores an event from a
Lean source it was not given, so a late event from an earlier host is
dropped. `stop` ends this loop only; quitting the queues is for the process
(`Ffi.quit`). No host exists outside its bracket (`withHost`), and `run` and
`runAndDispose` run on it, so they return only once their host's loop has
ended: the next host does not start beside a loop that is still taking
events. Only the headless mode bounds that wait (`main`, "The driver, and
the command line").

## What it prints

```
reload <n>: installed, <c> files, <k> commands
reload <n>: rejected
diagnostic: <source>:<line>:<column>: <severity>: <first line of the message>
theme: no theme is registered as `<name>`
                          (the reload's config named a theme nobody registered)
run <name>: ok            (or "refused: <error>", "interrupted",
                           "gave up: <reason>", "broke off: <reason>",
                           "no such command", "no window", or "no frame"
                           for a host whose frame could not be made)
spawn <name>: job <id>    (or "no such job")
job <id> <name>: started  (a command asked for the job)
job <id> <name>: ok       (the handler's command ran; or "refused: <error>",
                           "interrupted", "gave up: <reason>", "broke off:
                           <reason>", "failed: <first line of the
                           message>", "cancelled", "no frame")
event <source id> <code>  (an event from the library's scripted source)
key arrived: <logical> <physical> <modifiers>
                          (a key press from the window, `Key.describe`)
commands: <names>
text <index>: <quoted text>
store <name> v<version>: <value>
scene <w>x<h>, focused <id or ->, echo <quoted>, echo padding <n>, preedit <quoted or ->, theme <quoted name>
view <id> <x>,<y> <w>x<h>: <quoted text>, scroll <offset>, selections <anchor>..<head> …, padding <across> <down>
status <view id>: <face> <quoted text>, …   (or "-" for no field)
hint <key>: binding <quoted description or ->
hint <key>: prefix <quoted name or -> <count>
                          (a key that can follow the pending keymap prefix)
scene: none               (no scene has been published)
published <n>             (how many scenes have been published)
loop: refused: <error>    (a program of the editor loop was refused)
agree view <id>: <n> rows asked from <anchor>, <m> in the frame: agrees
                          (or "…: disagrees: asked <rows>, frame <rows>",
                           "agree view <id>: no rows query from <anchor>",
                           or "agree: no frame" with no display that lays
                           out frames)
idle: <d> frames drawn, <s> frames submitted
                          (or "idle: no render loop")
journal: <n> frames presented, present - input median <a> us, p99 <b> us, max <c> us, <r> rows rebuilt
                          (or "journal: no render loop")
```

`agree` answers `agree`: the last rows query the display answered since the
publish before the last one that names the last scene's focused view's
snapshot, at its width, its padding and the anchor it was published with,
and whether its rows are those of the frame the display laid out of that
scene
(`Host.Display.frameRows`). The queries are the loop's own, made as it
follows the cursor before each publish, and a scroll command's. `idle` and
`journal` are the driver's: `idle` once the editor thread has handled
everything sent, `journal` once it has settled, each waits until the render
loop is at rest (`Render.awaitRest`, on the step that records the rest).
Then `idle` has the editor thread answer once more with nothing sent and
counts the journal's new entries and the counters' frames submitted from
that rest to the next,
and `journal` the entries since the last `journal` line, with their
`present − input` (nearest rank). `journal`'s numbers vary between runs, so
it is for measuring, never for a fixture.

The `scene`, `view` and `status` lines answer `scene`: the last scene
published, with the name of the theme it was
drawn in (`Host.Display.drawnIn`), then each view in drawing order,
its snapshot's text read from the library, the offsets of its scroll
anchor and of each range of its selection, as the markers are when it is
asked, and its padding across and down in points (`EditorState.paddingOf`),
with ` top <n>` after them when the view is padded at the top by the
window's top inset (`EditorState.topInset`), which the headless driver's
`resize` leaves at 0;
the scene's line says the echo's padding (`EditorState.bottomInset`). After
each view's line comes its status line (`statusLine`), one
entry a field, the left fields and then, after ` | `, the right ones, each
with its padding: the mode line's (`Loop.statusOf`, `Editor/ModeLine.lean`),
which under the Vim scheme and the default order is the badge of the
view's Vim state (`NORMAL` in `mode-line.state.normal`), the buffer's name,
the modified mark while the buffer is modified and the directory its file
was opened in, then its major mode, line:col and position; the selected
window prints `in mode-line.active` after its id, and a window that is not
selected `in mode-line.inactive`, and has no badge. It is a line of its
own, so the view's line keeps its form. It is how a script sees a view's
state, its buffer's name, whether the buffer is modified and where the
cursor is. After the views comes one `divider` line for each divider
between the tiled windows (`Scene.dividers`), in the scene's order: its
top left, its size and its face, `divider 318,0 2x464 in window-divider`.
A scene with no divider, one window's, prints none. Last comes one `hint`
line for each key hint shown (`Scene.keyHints`): the keys that can follow
the pending keymap prefix once the key hint delay has passed, in the
scheme's order: the key, and the binding it
completes, with its description, or the prefix it leads to, with its name
and how many bindings lie under it, `-` for one it has none of
(`hint f: prefix "file" 1`). A scene with no keymap prefix pending, or
before the delay has passed, prints none.

A command a key runs prints nothing: what became of it is in the echo area
of the scene, `<name>: no such command`, `<name>: refused: <error>`,
`<name>: interrupted` or, for one that gave up or broke off,
`<name>: <reason>`, and a slow one is on the log. A command run by name
and a job's command are printed and are in the echo area too, a job's under
its label, `job <id> <name>`. The command that receives a prompt's answer
prints nothing either, whatever accepted the prompt: what became of it is
in the echo area, under the continuation's name. While a prompt is open
`scene` prints the minibuffer's view after the windows', with the input
typed so far as its text and the prompt text as its status line, in the
face `minibuffer.prompt`.

`commands`, `text` and `store` answer `show`, which lists commands, the
packages' among them, before config's, not jobs. The loop keeps
one table of texts for its life, and `show` lists every text in it that no
command has released, under the index it was made with. A diagnostic that is about no place in particular has the
position 0:0. A job's id is its number in this loop's table, from 1. A job
is `cancelled` when a reload that installs replaces the config that
registered it; a job that throws is `failed`.

## Headless time

The headless mode's job clock is fake (`Collaborators.clock`, a
`Job.FakeClock`): every job's wait, every time limit, the pause of
completion at point and the key hint delay wait on it, and real time never
moves it. A script
moves it with `advance <milliseconds>`, which waits until the clock holds a
wait due within them and then moves it, completing every wait then due. It
sends nothing to the editor thread and prints nothing. So a job that sleeps
ends only when a script advances, a pause and the key hints fire only when
a script advances, and saved outputs stay deterministic. The pause's and
the hint delay's waits post their events from the clock's completion,
before the move returns, so a `join` after an `advance` finds them queued.
The hint delay is a wait like the pause's, not a job: it prints nothing
and takes no job id (`Running.delayHints`). `idle` waits for the render loop's
rest, on the rest itself, never for a time. The window mode passes no clock and keeps the
library's timers.

## The idle signal

A host whose collaborators track it (`Collaborators.tracksIdle`: the
headless mode's and a test stage's) starts with an activity count of its own
(`Job.Activity`, `start`), handed to its runner (`Job.Services.activity`), so
it is never a stage's: a late step of an earlier host's job cannot reach a
later host's. A unit of it is held by each job while it can run (the
runner's, `Editor/Job/Runner.lean`, "Activity"); by the reload job from its
start (`reduce`) until it has posted its wake-up (`reloadJob`); by a pause's
or a hint delay's wait in flight on a clock that ends it by itself; and by
each event the reload, a job, a pause or a hint delay posted
(`Collaborators.postCounted`), until the loop has handled it
(`Collaborators.counts`, `loop`). A post made while its poster holds another
unit needs none of its own: an environment's report is posted from a job's
thread, or from the editor thread inside a counted event. The definition of
idle, and why the epoch, is in `docs/design/concurrency.md`, "The idle
signal". The window mode tracks nothing, and its steps of the count do
nothing. `ConfigTest.idleChecks` pin what holds a unit.

## The driver, and the command line

A host is driven from another thread: `Host.send` posts a request,
`Host.settle` waits, with a bound, until the editor thread has handled
everything sent so far and no reload is running, `Host.join` waits the same
way until no job is running, and the bracket the host lives in (`withHost`)
ends the loop. Requests are
handled in the order they were sent, and a request sent while a reload runs
is handled before that reload is installed: settle first to see its effect.

Two requests are the window mode's (`Editor/Window/Real.lean`), which
drives a host with no script: `open <path>` runs the open command with the
path, printed as `run open-file: …`, and `say <text>` says the text in the
echo area (`Running.said`). No script directive sends them.

`run` drives a host through a script, one directive a line: `reload`,
`run <name>`, `spawn <name>`, `show`, `scene` and `agree` are requests, and
`settle`, `settle <milliseconds>`, `join [<seconds>]`, `idle`,
`journal`, `journalled`, `indexed [<seconds>]`, `installed`,
`restarted [<seconds>]`, `key <logical> <physical> <modifiers>`,
`commit <text>` and `resize <width> <height>` are the driver's own. An
`installed` settles, then fails the run (`Failure.notInstalled`) unless
the last reload that finished installed its config
(`Progress.installed`): for a script that must not go on, or exit 0, on a
rejected config, as a benchmark's. A `settle <milliseconds>`
waits as `settle` does, for that many milliseconds in place of the run's
patience, for a reload known to be slow; a `join`, `indexed` or
`restarted` with seconds waits that many seconds in place of it, for a
package-set build or the restart it starts. Each such failure names the
patience that ran out (`Failure.waited`), and anything but one number is
refused. A `key` is sent with
`Host.press`: a press with no text,
posted through the library's window input as a window would report it
(`Event.post`), in order with the requests. A `commit` is sent the same way
with `Host.commit`, as an input method's composition ending with the rest of
the line, trimmed; an empty one is refused. A `resize` is sent the same way
with `Host.resize`: a resize of the frame to that many physical pixels
across and down, at a scale of 1; anything but two numbers is refused. It
is how a script gives its views a height: the frame is made 0 by 0, and a
view of no height shows no row, so no view of a script that does not
resize follows its cursor (`Editor/Loop.lean`, "Following the cursor").
The loop decodes a window's
events (`Event.ofFfi`) and hands each to the editor loop. Blank lines and
lines that start with `#` are skipped.

A script that cannot run to its end is data too. `Host.await` and `Host.join`
say what a wait came to (`Wait`): settled, or run out with a reload or a job
still running, or run out before the editor thread had handled everything
sent to it, or ended, because the loop has. `run` returns a `Failure` for a
wait that ran out, with the line of the `settle` or the `join`, or with no
line for the wait at the end of the script.

A run has two patiences (`runFrom`). Its `patience` bounds what a wait is
for: a reload or a job ending, an `advance`'s wait coming due. Its `answer`
bounds what should happen at once: the editor thread's answer to a wait.
The headless mode gives both the same value (`settlePatience`), and then
every wait is one window of it, as a `settle <milliseconds>` always is of
its milliseconds. A check gives a short `patience` to the one wait it means
to run out and a long `answer`, so that a loaded machine does not turn that
wait's failure into another one. The loop's end is not a patience: the run
returns once the loop has ended, and its `guard` (`answer` unless it is
given) only says a hang. A failure is `waited` the
patience that ran out when that is not the run's `patience`
(`Wait.failureIn`), since the run's failures are described with it.

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
`editor headless [--render] [--generate] [<sysroot> <olean dir>] <config dir>
<script file>`, handed the command line after `headless`, which `Headless.read` reads
(`Editor/Headless/CommandLine.lean`): the toolchain's directory and the
editor's `.olean` directory are given, or, from an executable in an app
bundle, are the bundle's (`Editor/ModuleLookup.lean`). It is `run`
with the packages `main` is handed, the real elaborator, a directory as the
source, stdout as the output, and the library's timer service and file
service for the jobs, then the quit and the explicit exit. Before the loop starts it warms the pool (`Editor/Job/Pool.lean`) and
starts the completion pump on a dedicated task (`Editor/Job/Real.lean`),
which the quit ends. Once the script has ended or failed, it waits for its
loop to end. Only the headless mode bounds that wait, so that CI and
fixtures never hang: a loop not ended 30 seconds (`settlePatience`) after
the script stopped it is said on stderr once, `editor: a hang: …`, and the
run waits up to `hangGrace` (5 seconds) more. A loop that ends within the
grace leaves the run as it was; one that does not fails it as `Failure.hung`,
said as `editor: the editor loop had not ended …; giving up`. Its exit
status is 0 when the script ran to its end, or a command quit the editor
before it, and
1 when it could not, and then it says why on stderr: the script cannot be
read, a wait ran out (after 30 seconds) with a reload or a job still
running, the editor thread did not answer, an `installed` found the config
not installed, or the run gave up on a loop that did not end. A rejected
reload is otherwise something to print, not a failure, and so is a job
that fails. A command line it does
not take is status 2, with its usage on stderr: two paths outside a bundle
among them, which say first that there is no toolchain.

With `--render` the host draws: `main` starts the library's headless render
session, a render loop over the CPU renderer that follows each published
scene's size at a scale of 1, and hands the host the real display binding
over a display of the library's in `cells`, bound to the library's
presenter (`drawnDisplay`), and the session as its `render`. It stops the
session before it quits. Without it, the display is the recorder and
nothing draws.

## Tests

`config-test` drives a host in-process on the real queue, the real text
binding and the real elaborator, and compares the lines it emits
(`ConfigTest.hostChecks`, `ConfigTest.threadChecks`), checks the bracket a
host lives in (`ConfigTest.bracketChecks`: it returns only once the loop has
ended, a loop held inside an event being waited for past the guard, which
says a hang once and is what lets the hold go), checks jobs on a fake
clock it moves, with the thread each line was emitted from
(`ConfigTest.jobChecks`), and checks the script reader and the driver
(`ConfigTest.scriptChecks`), among them that a run disposes only once its
loop has ended, when the loop is held inside an event or in the end of a
wait, and that the headless mode's run gives up, as `hung`, on a loop held
past its guard and its grace, and succeeds on one that ends within the
grace. Two of those are the loop's refusals: a scene
whose echo is the refusal once a command has released the focused buffer's
text, and `Running.attempt` on a program that is refused, which no script
can make the loop run. `ConfigTest.hostChecks` also start a host handed no
packages, which has an empty registry and no menu bar, and one handed a
package it refuses, which it logs and skips. `ConfigTest.dispatchChecks` send keys to hosts over
the test scheme, handed commands and bindings written there, as a package: a key
runs its command, a failed command is rolled back, the interrupt key stops
a command that loops, a reload replaces config's commands and bindings and
leaves the package's, and a slow command is logged, on the fake clock.
`ConfigTest.hostLoopChecks` are the commands no key ran: a `run` goes
through the loop, makes the frame, is rolled back when it fails and is
stopped by the interrupt key; a key's command starts a job, whose result
comes back as a command after the keys sent meanwhile; and a job's command
that loops is stopped by the interrupt key; a host handed two packages has
their commands in list order as its loop starts, before any reload, and
config's after them; and a host is handed a package's
job, which a package's command starts before any config is loaded and a
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
library's file service, handed the file commands and their jobs as the
`files` package registers them, on real files in temporary directories.
The `ffi-test` task runs the fixtures under `tests/headless` on the
default set's fixture harness, stepped on the fakes
(`Editor/Test/Fixture/Stepped.lean`;
`docs/dev-practices/headless-mode.md`, "How the gate runs a fixture").
`ConfigTest.scriptChecks` check that `agree`, `idle` and `journal`
are read, and what is refused.
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
  /-- Print whether the last rows query about the focused view, at what it
  was published with, matches the frame the display laid out. -/
  | agree
  /-- Run the open command (`FileJobs.openFileCommand`) with the path `path`: the
  window mode's first request when it was given a file. -/
  | «open» (path : String)
  /-- Say `text` in the echo area (`Running.said`): what the window mode has
  to say before the first event. -/
  | say (text : String)
  /-- Restore the session of the state directory (`Collaborators.stateDirectory`):
  start the job `restore`, and hold the requests that follow until it has
  finished ("Restoring a session", in the module docs). `named` is the index
  a restart handed over, restored in place of the one the version rule
  chooses ("Restarting"). -/
  | restore (named : Option System.FilePath)
  /-- Print the workspace table: each workspace, each project and the
  unscoped store, with their values. -/
  | workspaces
  /-- Print how many scenes have been published (`published <n>`). A scene
  line carries no count: how many scenes a source outside idle (a library
  parse, a Rust poster, a real-time watch, the render loop) makes changes
  from run to run, while what was published last does not. A script asks
  for the count only where the publish rule fixes it. -/
  | published
  deriving DecidableEq, Repr

/-- The render loop a host's frames are drawn by, as its driver reads it:
the latest render session's (`Ffi.renderResting`, `Ffi.renderJournal`,
`Ffi.renderCounters`). Each answers `none` when no session has started. -/
structure Render where
  /-- Whether the loop is at rest. -/
  resting : IO (Option Bool)
  /-- Waits until the loop is at rest, on the step that records the rest,
  never by a poll of `resting`: `some true` once it is, `some false` when
  the hang guard ran out first. -/
  awaitRest : HangGuard → IO (Option Bool)
  /-- The journal's entries after a serial, oldest first. -/
  journal : UInt64 → IO (Option (Array Ffi.JournalEntry))
  /-- The loop's counters. -/
  counters : IO (Option Ffi.RenderCounters)

/-- The library's render session: the one `editor headless --render`
starts. -/
def Render.library : Render :=
  { resting := Ffi.renderResting, awaitRest := Ffi.renderAwaitRest
    journal := Ffi.renderJournal, counters := Ffi.renderCounters }

/-- The cells the headless host's display lays text out in: 8 pixels across
and 16 down, as the display contract's larger size. -/
def cells : Display.Cells :=
  { advance := 8, lineHeight := 16 }

/-- A rows query the host's display answered, and the rows it answered. -/
structure Asked where
  /-- What was asked. -/
  query : Display.RowsQuery
  /-- The rows answered. -/
  rows : Array Display.Row
  deriving DecidableEq, Repr

/-- The display a host publishes to and asks, as the host holds it: what
answers the loop's requests (`handle`), wrapped so that the host keeps what
it prints of them. A maker hands it whatever answers: the recorder
(`Host.Display.recorder`) or the real binding (`Host.Display.real`). -/
structure Host.Display where
  /-- Answers the loop's display requests, and keeps what the fields below
  hold of them. -/
  handle : DisplayHandler
  /-- The last scene published, if one has been. -/
  last : IO.Ref (Option Scene)
  /-- How many scenes have been published. -/
  count : IO.Ref Nat
  /-- The rows queries answered since the publish before the last one,
  oldest first: those made before the last publish, then those made since.
  A refused query is not kept. -/
  asked : IO.Ref (Array Asked × Array Asked)
  /-- The name of the theme the display was last handed (`setTheme`),
  `default` until one is. -/
  named : IO.Ref String
  /-- The name `named` held when the last scene was published: the theme
  that scene was drawn in, since a theme set goes with the next publish. -/
  drawnIn : IO.Ref String
  /-- Makes a theme, called by its name, what the faces look like from the
  next publish on: keeps the name (`named`), and hands the theme to the
  display. The recorder draws no face, and ignores the theme. -/
  setTheme : String → Theme → BaseIO Unit
  /-- The rows the frame the display laid out last shows of a view, where
  the display lays frames out: the real binding's. `none` for the
  recorder, which lays out no frame. -/
  frameRows : Option (ViewId → IO (Option (Array Display.Row)))

namespace Host.Display

/-- The host's display over `answer`, with no scene published and no query
asked: every request goes to `answer`, and a publish and a rows query that
it answers are kept, with the name of the theme a publish was drawn in.
`setTheme` is how `answer`'s display is handed a theme. -/
def over (answer : DisplayHandler) (setTheme : Theme → BaseIO Unit := fun _ => pure ())
    (frameRows : Option (ViewId → IO (Option (Array Display.Row))) := none) : BaseIO Host.Display :=
  do
  let last ← IO.mkRef none
  let count ← IO.mkRef 0
  let asked ← IO.mkRef (#[], #[])
  let named ← IO.mkRef Theme.defaultName
  let drawnIn ← IO.mkRef Theme.defaultName
  let handle : DisplayHandler := fun
    | .publish scene => do
      answer (.publish scene)
      last.set (some scene)
      count.modify (· + 1)
      drawnIn.set (← named.get)
      asked.modify fun (_, since) => (since, #[])
    | .rows query => do
      let reply ← answer (.rows query)
      if let .ok rows := reply then
        asked.modify fun (before, since) => (before, since.push { query, rows })
      return reply
    | .move query => answer (.move query)
    | .spot query => answer (.spot query)
    | .heights => answer .heights
    | .frame request => answer (.frame request)
  let setNamed (name : String) (theme : Theme) : BaseIO Unit := do
    named.set name
    setTheme theme
  return { handle, last, count, asked, named, drawnIn, setTheme := setNamed, frameRows }

/-- The host's display over a recorder in `cells` that reads snapshots
through `snapshots` (`Editor/Display/Recorder.lean`): the headless mode's. -/
def recorder (cells : Display.Cells) (snapshots : SnapshotReader) : BaseIO Host.Display := do
  over (← DisplayRecorder.new cells snapshots).handle

/-- The host's display over the real binding `real`
(`Editor/Display/Real.lean`): a theme set is sent with the next scene, and
the frame's rows are the library's. -/
def real (real : RealDisplay) : BaseIO Host.Display :=
  over real.handle real.setTheme <|
    some fun view => do
      let rows ← real.display.frameRows (RealTexts.word view.index)
      return rows.map (·.map fun row => { start := row.start.toNat, stop := row.stop.toNat })

/-- The last scene published, if one has been. -/
def last? (display : Host.Display) : BaseIO (Option Scene) :=
  display.last.get

/-- How many scenes have been published. -/
def published (display : Host.Display) : BaseIO Nat :=
  display.count.get

/-- The name of the theme the last scene published was drawn in. -/
def drawn (display : Host.Display) : BaseIO String :=
  display.drawnIn.get

end Host.Display

/-- What a host that runs the input scheme `scheme` needs from outside. The
scheme is a parameter, as it is of the loop (`Loop`): it is in `Type 1`, and
cannot be a field of what a task is handed. -/
structure Collaborators (β σ : Type) (scheme : InputScheme) where
  /-- How config is elaborated. -/
  elaborator : Config.Elaborator β σ
  /-- Where the config's files come from. -/
  source : Config.Source
  /-- The config directory read as a Lake package: its lakefile, which a
  reload reads to say what a module that is not linked belongs to
  (`Editor/Config/Session.lean`, "The package ports"). The default holds no
  file, for a host with no directory. -/
  package : Config.PackageFiles := Config.PackageFiles.none
  /-- What writes the config directory's lakefile and toolchain file when
  they are absent; none for a host that may not write there, which is the
  default: such a host writes nothing. -/
  generator : Option Config.Generator := none
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
  /-- The Lean source id what the jobs' environments report is posted under,
  with the text to say in the echo area (`reportedEnvironments`). -/
  environment : UInt64
  /-- The Lean source id a job's post is announced under, with the job's id
  as its code: the post itself waits in the host's mailbox
  (`Running.mailbox`). -/
  posts : UInt64
  /-- The Lean source id a pause of completion at point that fired is posted
  under, with its wait's id as its code (`Running.pause`), and the key hint
  delay too (`Running.delayHints`). -/
  pauseEvents : UInt64
  /-- The packages the host registers when its loop starts, in order, before
  any config (`Config.State.ofPackages`, `Editor/Config/Packages.lean`):
  every command, job, key binding, mode, ex name, theme, segment, language,
  compile contribution, completion source, style and display, at-point
  source and menu the host has before config is one of theirs. The default
  is none, and a host handed none starts with an empty registry and
  publishes no menu bar; the executable's hosts are handed the packages
  of its package set. -/
  packages : Array Package := #[]
  /-- Where a log entry goes: a command that took longer than `slowAfter`,
  and a package the host refused as its loop started (`Running.new`).
  The editor thread calls it. It is not `emit`: the output is what a test
  compares, and a log entry depends on how long the machine took. -/
  log : String → IO Unit := fun _ => pure ()
  /-- How long a command a key runs may take before it is logged as slow, in
  milliseconds. -/
  slowAfter : Nat := Loop.slowAfter
  /-- How many candidates a prompt may have to match for its listing to be
  made on the editor thread (`Loop.Keys.inlineMatches`): the editor's
  `Loop.inlineMatches`, unless a benchmark lifts it. -/
  inlineMatches : Nat := Loop.inlineMatches
  /-- The interrupt key, which the host tells the library when its loop
  starts. -/
  interruptKey : Key := Watch.interruptKey
  /-- How the host makes the editor loop's frame when it is first needed:
  `Loop.start` in a frame of 0 by 0, which a resize changes. A test hands
  one that is refused, to see what the host does with no frame. -/
  start : TextM (Loop scheme) := Loop.start scheme ⟨0, 0⟩
  /-- The host's working directory, which `start` writes into the editor
  state of the loop it makes (`EditorState.workingDirectory`): where a
  command run for a buffer with neither a workspace nor a file runs. The
  window mode's is the process's working directory, read at the edge, and
  so is the headless mode's. -/
  workingDirectory : System.FilePath := "/"
  /-- The home directory, which `start` writes into the editor state
  (`EditorState.home`): what `~` names in a typed path. The window mode's
  is `HOME`, read at the edge (`Process.Host.home`, which `Window.host`
  hands here); the headless mode reads nothing from the
  environment, so its is none, and a `~` there says the home is not known. -/
  home : Option System.FilePath := none
  /-- The state directory, which `start` writes into the editor state
  (`EditorState.stateDirectory`): where what is kept across a restart
  lives. The window mode's is `--state`, or its default under
  `XDG_STATE_HOME` or `HOME` (`Window.Options.stateDirectory`); the
  headless mode reads nothing from the environment and its command line
  names none unless it is given `--state`, so by default its is none and
  it keeps nothing across a restart. With one, the host's first request is
  `restore` ("Restoring a session", in the module docs). -/
  stateDirectory : Option System.FilePath := none
  /-- How the session journal's orders reach the file service: the
  library's (`Journal.real`) for the executable's hosts, nothing by
  default. -/
  journal : Journal := {}
  /-- How the host makes its display, over the read half of the table of
  snapshots the text binding publishes (`published`). The headless mode's
  is a recorder in `cells`; a host that draws is handed the real binding. -/
  display : SnapshotReader → IO Host.Display := fun snapshots =>
    Host.Display.recorder cells snapshots
  /-- How the host makes its clipboard. The headless mode's is one of its
  own (`Editor/Clipboard/InProcess.lean`), which holds no text at first; a
  host with a window system is handed the system's. -/
  clipboard : IO ClipboardHandler := do
    return (← Clipboard.InProcess.new).handle
  /-- How the host makes its syntax tree handler, over the read half of the
  table of snapshots the text binding publishes (`published`): the real
  binding over the library's syntax service. A test hands one that records
  what it is asked. -/
  syntaxTree : SnapshotReader → IO SyntaxTreeHandler := fun snapshots => do
    return (← RealSyntaxTree.new snapshots).handle
  /-- The render loop the host's display draws through, for the driver's
  `idle` and `journal`; none when nothing draws, as in the headless mode
  without `--render`. -/
  render : Option Render := none
  /-- The fake clock the host's jobs wait on, for the driver's `advance`,
  when they wait on one ("Headless time", in the module docs): the headless
  mode's, and a test stage's. None for a host on the real clock, the window
  mode's. -/
  clock : Option Job.FakeClock := none
  /-- Whether the host keeps a count of its activity, its idle signal
  (`Job.Activity`, `docs/design/concurrency.md`, "The idle signal"): each
  host then starts with a count of its own (`start`), its jobs, its reload
  and the events they post hold units of it, and a driver's wait answers at
  idle (`Host.waitWhile`). The headless mode's hosts and a test stage's keep
  one; the window mode's does not, and its steps of the count do nothing. -/
  tracksIdle : Bool := false
  /-- What the loop's end calls, naming what it is about to wait for, when it
  finds work of the loop's still running: `"reload"` for a reload job not
  ended (`loop`). A test's hook, to let a held reload go on the loop's own
  report that it waits for it, never on time; the default does nothing. -/
  endWaits : String → IO Unit := fun _ => pure ()
  /-- What the loop's end calls last, with a task for each job cancelled and
  not yet done (`Job.Services.unsettled`), those it has just cancelled and
  those an owner's removal or a keyed cancel cancelled before, that ends
  once the runner is done with that job (`Job.Handle.finishedRan`): the job
  has ended and its wake-up has been posted, or refused (`Running.wind`).
  The loop's end in the runner's protocol comes after it, and is recorded
  only once every one has ended (`Job.Services.endLoop`). The loop does
  not wait for them: the default does nothing, and a wake-up posted to a
  queue that has been quit is refused. A test's hook: a test host whose
  queue the next host shares waits on them here, so that nothing of its
  jobs arrives after its bracket has returned. -/
  endCancelled : Array (Task Unit) → IO Unit := fun _ => pure ()
  /-- What the real loop calls on its own thread before it takes its first
  event (`loop`). A test's hook, to count the checks that run a loop thread;
  a host stepped on its caller's thread never calls it. The default does
  nothing. -/
  loopStarted : IO Unit := pure ()
  /-- The editor queue the host's posters post to (`Editor/Headless/Queue.lean`):
  the library's (`Queue.library`), which the real loop pulls. Only a stepped
  host's bracket changes it (`Editor/Headless/Stepped.lean`), to the memory
  queue it drains; a real host refuses a queue a stepper pulls (`start`). -/
  queue : Queue := Queue.library
  /-- How this run was launched and what a restart hands on
  (`Restart.Launch`), which `start` writes into the editor state
  (`EditorState.launch`). The executable's hosts read it from the command
  line (`Editor/Executable.lean`); empty by default, a run with no
  launcher. -/
  launch : Restart.Launch := {}
  /-- What the running editor knows of its own package set
  (`EditorState.packageSet`), which `start` writes into the editor state.
  The executable's hosts read it at the edge (`PackageSet.at`); empty by
  default, a host that never builds a user's package set. -/
  packageSet : PackageSet.Running := {}
  /-- Execs a restart's plan in place of this process, once the host has shut
  down ("Restarting", in the module docs): it answers only when the exec
  failed, with the reason. The hosts exec only through it
  (`Restart.Plan.exec`). The executable's hosts are handed `Restart.real`;
  the default refuses (`Restart.noExec`). -/
  replace : Restart.Invocation → IO String := Restart.noExec
  /-- Removes what the collaborators left outside the process: the real
  ones' directory of the config files' module data, if a config with
  files under `Config/` had it made (`Editor/Config/Elaborate.lean`,
  "Module files"). The executable's edges call it once, when the host has
  ended; the default removes nothing. -/
  dispose : IO Unit := pure ()

/-- Posts an event under `source`, with `code` and `text`, to the editor
queue (`Collaborators.queue`), under a unit of the host's activity (`Job.Activity`; "The idle
signal", in the module docs): the unit is taken before the post and given
back by the loop once it has handled the event (`Collaborators.counts`,
`loop`), or here at once when the queue refuses it, which it does once the
queues are quit. Whether the queue took it. It never throws. -/
def Collaborators.postCounted {β σ : Type} {scheme : InputScheme}
    (collaborators : Collaborators β σ scheme) (source code : UInt64) (text : String := "") :
    BaseIO Bool := do
  let activity := collaborators.services.activity
  activity.begin
  let posted ← collaborators.queue.post { source, code, text }
  unless posted do
    activity.done
  return posted

/-- Whether `event` came under a unit of the host's activity
(`postCounted`): a reload's wake-up, a job's wake-up or post, or a pause's
or a hint delay's. The loop gives its unit back once it has handled it. -/
def Collaborators.counts {β σ : Type} {scheme : InputScheme}
    (collaborators : Collaborators β σ scheme) (event : Ffi.Event) : Bool :=
  event.source.kind == .lean &&
    (event.source.id == collaborators.wakeups || event.source.id == collaborators.jobs ||
      event.source.id == collaborators.posts ||
      event.source.id == collaborators.pauseEvents)

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
  /-- A marker the loop counts and does nothing else for: it publishes no
  scene and releases no held request after it. A wait's later rounds post
  it (`Host.waitWhile`), so how many rounds a wait took changes nothing a
  scene count shows. -/
  | probe

/-- A signal as an event's code and text. -/
def Signal.encode : Signal → UInt64 × String
  | .request .reload => (0, "")
  | .request (.run name) => (1, name)
  | .request .show => (2, "")
  | .marker => (3, "")
  | .stop => (4, "")
  | .request (.spawn name) => (5, name)
  | .request .scene => (6, "")
  | .request .agree => (7, "")
  | .request (.open path) => (8, path)
  | .request (.say text) => (9, text)
  | .request (.restore named) => (10, ((named.map (·.toString)).getD ""))
  | .request .workspaces => (11, "")
  | .probe => (12, "")
  | .request .published => (13, "")

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
  | 7 => some (.request .agree)
  | 8 => some (.request (.open text))
  | 9 => some (.request (.say text))
  | 10 => some (.request (.restore (if text.isEmpty then none else some text)))
  | 11 => some (.request .workspaces)
  | 12 => some .probe
  | 13 => some (.request .published)
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
diagnostics, then, when its config named a theme nobody registered, a line
that says so, a `segment:` line for each segment its mode line listed
that nobody registered, a `style:` line for each completion style it chose
that nobody registered (`Config.Report.unknownStyles`), a `display:` line
for each completion display it chose that nobody registered
(`Config.Report.unknownDisplays`), an `at-point:` line for each at-point
source a use or a mode names that nobody registered
(`Config.Report.unknownAtPoints`), and a `rule:` line
for each display rule left out because its target does not exist
(`Config.Report.unusableRules`). -/
def reportLines (report : Config.Report) : Array String :=
  let outcome :=
    if report.installed then
      s!"reload {report.number}: installed, {report.files} files, {report.commands} commands"
    else s!"reload {report.number}: rejected"
  let diagnostics :=
    report.diagnostics.map fun diagnostic =>
      s!"diagnostic: {diagnostic.source}:{diagnostic.line}:{diagnostic.column}: {severityName diagnostic.severity}: {(diagnostic.message.splitOn "\n").headD ""}"
  #[outcome] ++ diagnostics ++
    report.unknownTheme.toArray.map (fun name => s!"theme: {Theme.unknown name}") ++
    report.unknownSegments.map (fun name => s!"segment: {ModeLine.unknown name}") ++
    report.unknownStyles.map (fun name => s!"style: {Completion.Style.unknown name}") ++
    report.unknownDisplays.map (fun name => s!"display: {Completion.Display.unknown name}") ++
    report.unknownAtPoints.map (fun name => s!"at-point: {Completion.AtPoint.unknown name}") ++
    report.unknownBase.toArray.map (fun sentence => s!"base: {sentence}") ++
    report.unusableRules.map fun sentence => s!"rule: {sentence}"

/-- How a job that has ended is reported, after `job <id> <name>: `. -/
def firstLine (message : String) : String :=
  (message.splitOn "\n").headD ""

/-- The status line of the view `view` as `scene` prints it, a line of its
own after the view's: `status`, the view's id, ` in ` and its status face
when it has one (`View.statusFace`), then its left fields, and, when it
has right ones, ` | ` and the right fields; or `-` for a status line with
no field. Each field is its face, its quoted text, and ` +` and its padding
when that is not 0, in the scene's order within its side. -/
def statusLine (view : ViewId) (status : Array StatusField) (statusFace : Option FaceName := none) :
    String :=
  let printed (side : StatusSide) : List String :=
    (status.filter (·.side == side)).toList.map fun field =>
      let padding := if field.padding == 0 then "" else s!" +{field.padding}"
      s!"{field.face.name} {field.text.quote}{padding}"
  let (left, right) := (", ".intercalate (printed .left), ", ".intercalate (printed .right))
  let fields :=
    if status.isEmpty then "-"
    else
      if right.isEmpty then left else if left.isEmpty then s!"| {right}" else s!"{left} | {right}"
  let face := (statusFace.map (s!" in {·.name}")).getD ""
  s!"status {view.index}{face}: {fields}"

/-- The loop's state: everything the editor thread owns, for a host that
runs the input scheme `scheme`. -/
structure Running (β σ : Type) (scheme : InputScheme) where
  /-- The config half of the editor's state. -/
  config : Config.State β σ := {}
  /-- The texts and the snapshots made so far. -/
  texts : RealTexts
  /-- The display, over the snapshots `texts` publishes: what the host's
  collaborators made (`Collaborators.display`). -/
  display : Host.Display
  /-- The clipboard every command the host runs reaches: what the host's
  collaborators made (`Collaborators.clipboard`). -/
  clipboard : ClipboardHandler
  /-- The syntax tree every command the host runs reaches: what the host's
  collaborators made once, as the loop started
  (`Collaborators.syntaxTree`), so its queries live as long as the loop. -/
  syntaxTree : SyntaxTreeHandler
  /-- The editor loop's frame: none until the first event the loop takes or
  the first command it runs. -/
  frame : Option (Loop scheme) := none
  /-- Whether the loop took a step for the event being handled, and so
  published a scene after it: the host then publishes no second one. -/
  stepped : Bool := false
  /-- The jobs that are running, with their owners. -/
  jobs : Job.Jobs
  /-- Where the reload job that is running will leave its outcome. -/
  job : Option (IO.Promise (Config.Outcome β σ)) := none
  /-- The task of the last reload job started: the loop's end waits for it,
  so no reload outlives the loop that started it. -/
  reloadTask : Option (Task (Except IO.Error Unit)) := none
  /-- How many markers the loop has reached. -/
  markers : Nat := 0
  /-- Whether the last reload that finished installed its config, none
  before one has (`Progress.installed`). -/
  installed : Option Bool := none
  /-- Whether the driver has ended the loop. -/
  stopped : Bool := false
  /-- What the host has to say in the echo area once the frame is made: a
  reload's error said before there was a frame (`said`). -/
  unsaid : Option String := none
  /-- The jobs started with a key, by their key: the id each runs as
  (`JobStart.key`). Changed only through `rekeyed`, which tells the reload
  reducer whether a package-set build is in flight. -/
  keyed : Array (String × Nat) := #[]
  /-- The posts the jobs made that the editor thread has not run, each with
  its job's id. -/
  mailbox : Job.Mailbox
  /-- The pauses of completion at point armed on the job clock, each its
  wait's id, its view and its milliseconds (`pause`). -/
  pauses : Array (UInt64 × ViewId × Nat) := #[]
  /-- The key hint delay armed on the job clock, if one is: its wait's id
  and the generation of the hints it makes due (`delayHints`). -/
  hintWait : Option (UInt64 × Nat) := none
  /-- The id of the job `restore` while a restore is in flight ("Restoring a
  session", in the module docs). -/
  restoring : Option Nat := none
  /-- The driver's requests held while a restore is in flight, oldest
  first. -/
  heldRequests : Array Request := #[]
  /-- The ids of the jobs the driver's `spawn` requests started: a script's
  own jobs, which its `indexed` does not wait for. -/
  spawned : Array Nat := #[]
  /-- The paths whose journal failures were said: each is said once. -/
  journalSaid : Array String := #[]
  /-- How many of the journal's orders have failed, all told, and the path
  of the last. -/
  journalFailures : Nat × Option String := (0, none)
  /-- How many journal orders had failed when the restart in flight began
  (`Restore.Kept.handing`), while one is ("Restarting", in the module
  docs). -/
  handingFrom : Option Nat := none
  /-- The plan of the restart the loop ended for, once it has. -/
  handOver : Option Restart.Plan := none

namespace Running

variable {β σ : Type} {scheme : InputScheme}

/-- Says `text` in the echo area of the frame's state, which the next scene
shows; with no frame made yet, keeps it to say once the frame is made
(`framed`). -/
def said (running : Running β σ scheme) (text : String) : Running β σ scheme :=
  match running.frame with
  | some frame =>
    { running with frame := some { frame with state := { frame.state with echo := text } } }
  | none => { running with unsaid := some text }

/-- `running` with the keyed jobs `keyed`, and the reload reducer told
whether a package-set build is in flight when that changed
(`Config.Event.packageBuild`, which has no effect): the job keyed
`package-build` is, whoever started it. -/
def rekeyed (running : Running β σ scheme) (keyed : Array (String × Nat)) : Running β σ scheme :=
  let inFlight := keyed.any (·.1 == PackageSet.buildJob)
  let running := { running with keyed }
  if inFlight == running.config.packageBuilding then running
  else { running with config := (Config.step running.config (.packageBuild inFlight)).1 }

/-- The reload job, on a thread of its own: builds the config, hands the
outcome over through `promise`, and wakes the editor thread with an event.
The wake-up is posted whatever happens, so the editor thread never waits for
a job that is gone. It holds a unit of the host's activity, taken by
`reduce` as it starts it, and gives it back last, once its wake-up has been
posted under a unit of its own (`postCounted`). -/
def reloadJob (collaborators : Collaborators β σ scheme) (base : Option β)
    (files : Array (Config.LoadedFile σ)) (promise : IO.Promise (Config.Outcome β σ)) : IO Unit :=
  do
  try
    promise.resolve
        (←
          Config.reload scheme collaborators.elaborator collaborators.source collaborators.package
              collaborators.generator base files)
  finally
    discard <| collaborators.postCounted collaborators.wakeups 0
    collaborators.services.activity.done

/-- Starts `work` as a job of `owner` called `name`: its id, and the jobs with
it. It runs on the pool; its posts wait in the mailbox, and when it has
ended the runner posts a wake-up to the editor queue, with the job's id.
How a registered job is started (`startJob`) and how the loop's own work is
(`Loop.Spawn`, `launch`). -/
def startWork (collaborators : Collaborators β σ scheme) (running : Running β σ scheme)
    (owner : Config.Owner) (name : String) (work : Work) : IO (Nat × Running β σ scheme) := do
  -- Each is posted under a unit of the host's activity (`postCounted`).
  let wake (id : Nat) : BaseIO Unit :=
    discard <| collaborators.postCounted collaborators.jobs id.toUInt64
  -- A post waits in the mailbox, and the event says whose it is: the job's
  -- wake-up is posted after its last post's event.
  let posted (id : Nat) (invocation : Invocation) : BaseIO Unit := do
    running.mailbox.push id invocation
    discard <| collaborators.postCounted collaborators.posts id.toUInt64
  let (id, jobs) ← running.jobs.start owner name work wake posted
  return (id, { running with jobs })

/-- Starts the job registered under `name` with `arguments`, for the owner
that registered it: its id, and the jobs with it, or `none` for a name no
job is registered under. The job runs on the pool; when it has ended the
runner posts a wake-up to the editor queue, with the job's id, from
whichever thread the job ended on. -/
def startJob (collaborators : Collaborators β σ scheme) (running : Running β σ scheme)
    (name : String) (arguments : List Argument := []) : IO (Option Nat × Running β σ scheme) := do
  let some (owner, work) := running.config.work? name arguments | return (none, running)
  let (id, running) ← running.startWork collaborators owner name work
  return (some id, running)

/-- Feeds `event` to the reload reducer and performs its effects. A reload
job is started on a dedicated task, never run here: it reads files and
elaborates, and the editor thread goes on to its next event. A reload's
report is printed, and a rejected one's error is said in the echo area
(`Config.Report.echo`, `said`); one that installs says nothing there, and
hands the display the new theme (`Config.retheme`). A package-set build the
reducer asks for (`buildPackages`, `docs/design/packages.md`, "User package
sets") is started as the job `package-build`, keyed so, printed `job <id>
package-build: started`, and said (`PackageSet.startedLine`); what the
reducer has to say of the set instead is said. -/
def reduce (collaborators : Collaborators β σ scheme) (running : Running β σ scheme)
    (event : Config.Event β σ) : IO (Running β σ scheme) := do
  let (config, effects) := Config.step running.config event
  Config.retheme running.display.setTheme config effects
  -- A reload that installs installs the layers the registry gives a child's
  -- environment, and drops every cached one.
  if Config.installed effects then
    collaborators.services.environments.install
        (EnvironmentApi.ofRegistry config.registry.extensionsAt config.registry.baseName).1
  let mut running := { running with config }
  for effect in effects do
    match effect with
    | .report report =>
      running := { running with installed := some report.installed }
      for line in reportLines report do
        collaborators.emit line
      if let some text := report.echo then
        running := running.said text
    | .cancelJobs owner =>
      -- The owner's jobs leave the table here, so a wake-up one of them had
      -- already posted finds nothing, and its handler never runs.
      let (removed, jobs) ← running.jobs.removeOwner owner
      running := { running with jobs }
      for entry in removed do
        collaborators.emit s!"job {entry.id} {entry.name}: cancelled"
    | .start base files =>
      let promise ← IO.Promise.new
      -- The reload can run from here: it holds a unit of the host's
      -- activity until it has posted its wake-up (`reloadJob`).
      collaborators.services.activity.begin
      let task ← IO.asTask (prio := .dedicated) (reloadJob collaborators base files promise)
      running :=
        { running with
          job := some promise, reloadTask := some task }
    | .themed =>
      -- `retheme` above has handed the display the theme.
      pure ()
    | .appearance appearance =>
      discard <| running.display.handle (.frame (.appearance appearance))
    | .buildPackages order =>
      let (id?, started) ← running.startJob collaborators PackageSet.buildJob [.str order.encode]
      match id? with
      | some id =>
        collaborators.emit s!"job {id} {PackageSet.buildJob}: started"
        running :=
          (started.said PackageSet.startedLine).rekeyed
            (started.keyed.push (PackageSet.buildJob, id))
      | none =>
        -- No job is registered under the name: none is in flight.
        running := started.rekeyed started.keyed
    | .say text =>
      running := running.said text
  return running

/-- Sets what the last reload read of the package set
(`Config.State.packageSet`) in the editor state (`PackageSet.Running.facts`),
when there is a frame: the frame takes it as it is made (`framed`). -/
def withFacts (running : Running β σ scheme) : Running β σ scheme :=
  match running.frame with
  | some frame =>
    let facts := running.config.packageSet.facts
    { running with
      frame :=
        some
          { frame with
            state := { frame.state with packageSet := { frame.state.packageSet with facts } } } }
  | none => running

/-- Takes the finished reload job's outcome and feeds it to the reducer. This
is where a reload is installed: on the editor thread, between two events. -/
def finish (collaborators : Collaborators β σ scheme) (running : Running β σ scheme) :
    IO (Running β σ scheme) := do
  let some promise := running.job | return running
  let outcome :=
    promise.result?.get.getD
      { base := none,
        diagnostics := #[Config.failure "reload" "the reload job ended without an outcome"],
        built := none }
  let running ← { running with job := none }.reduce collaborators (.finished outcome)
  return running.withFacts

/-- Cancels the job started with `key`, if one is running or has finished and
not been delivered (`Job.Jobs.cancel`), and forgets the key. -/
def cancelKeyed (running : Running β σ scheme) (key : String) : IO (Running β σ scheme) := do
  let some (_, id) := running.keyed.find? (·.1 == key) | return running
  let jobs ← running.jobs.cancel id
  return { running with jobs }.rekeyed (running.keyed.filter (·.1 != key))

/-- Carries out what the loop handed back to start and to end: each key of
`cancels` is cancelled; then each of `starts` is started, for the owner
that registered it, a start of a key cancelling the running job of that key
first, and printed, `job <id> <name>: started`; then each of `spawns`, the
loop's own work, is started as a job of its owner under its key, which ends
the running job of that key first, and printed, `job <id> <label>:
started`. How a step's jobs are taken in (`took`), and the jobs the
reconciler of a prompt hands back after a publish no step made
(`publish`). -/
def launch (collaborators : Collaborators β σ scheme) (running : Running β σ scheme)
    (starts : Array JobStart) (cancels : Array String) (spawns : Array Loop.Spawn) :
    IO (Running β σ scheme) := do
  let mut running := running
  -- A cancel ends the job of its key, finished and not delivered or not.
  for key in cancels do
    running ← running.cancelKeyed key
  for start in starts do
    -- Starting a job of a key cancels the running job of that key.
    if let some key := start.key then
      running ← running.cancelKeyed key
    let (id?, started) ← running.startJob collaborators start.name start.arguments
    running := started
    -- The loop refused a name no job is registered under when the command
    -- asked, from the registry as it is in this event: one is found.
    if let some id := id? then
      collaborators.emit s!"job {id} {start.name}: started"
      if let some key := start.key then
        running := running.rekeyed (running.keyed.push (key, id))
  for spawn in spawns do
    running ← running.cancelKeyed spawn.key
    let (id, started) ← running.startWork collaborators spawn.owner spawn.label spawn.work
    collaborators.emit s!"job {id} {spawn.label}: started"
    running := started.rekeyed (started.keyed.push (spawn.key, id))
  return running

/-- Withdraws every pause of completion at point armed: its wait is
withdrawn from the clock and ended as cancelled in the table of waits, as a
job's cancel ends its wait, so the task that awaits it ends and posts
nothing. -/
def withdrawPauses (collaborators : Collaborators β σ scheme) (running : Running β σ scheme) :
    BaseIO (Running β σ scheme) := do
  for (id, _, _) in running.pauses do
    collaborators.services.timers.cancel id
    collaborators.services.completions.finish id .cancelled
  return { running with pauses := #[] }

/-- Carries out what a step said of the pause of completion at point
(`Loop.Stepped.pause`, "Completion at point" in `Editor/Loop.lean`): to keep
it, nothing; to disarm it, every pause armed is withdrawn
(`withdrawPauses`); to arm it, those are withdrawn, and a wait is started on
the job clock for each pause, due that many milliseconds from now. When a
wait completes, the clock's own completion posts an event to the editor
queue under `pauseEvents`, with the wait's id as its code, synchronously,
before the clock's move returns, so a driver's `join` after an `advance`
finds it queued; a wait withdrawn posts nothing. -/
def pause (collaborators : Collaborators β σ scheme) (running : Running β σ scheme)
    (change : Loop.PauseChange) : BaseIO (Running β σ scheme) := do
  match change with
  | .keep =>
    return running
  | .disarm =>
    running.withdrawPauses collaborators
  | .arm view pauses =>
    let running ← running.withdrawPauses collaborators
    let services := collaborators.services
    let now ← services.timers.now
    -- A wait on a clock that ends it by itself holds a unit of the host's
    -- activity while it is in flight; one on the fake clock does not.
    let counted := !services.timers.outside
    let mut held := #[]
    for ms in pauses do
      let (id, wait) ← services.completions.register
      if counted then
        services.activity.begin
      let fired (completion : Option Job.Completion) : BaseIO Unit := do
        if completion == some .completed then
          discard <| collaborators.postCounted collaborators.pauseEvents id
        if counted then
          services.activity.done
      discard <| BaseIO.mapTask fired wait.result? (sync := true)
      services.timers.start id (now + ms)
      held := held.push (id, view, ms)
    return { running with pauses := held }

/-- Withdraws the key hint delay armed, if one is, as `withdrawPauses`
withdraws a pause: its wait is withdrawn from the clock and ended as
cancelled, so it posts nothing. -/
def withdrawHints (collaborators : Collaborators β σ scheme) (running : Running β σ scheme) :
    BaseIO (Running β σ scheme) := do
  if let some (id, _) := running.hintWait then
    collaborators.services.timers.cancel id
    collaborators.services.completions.finish id .cancelled
  return { running with hintWait := none }

/-- Carries out what a step said of the key hint delay
(`Loop.Stepped.hintDelay`, "Key hints" in `Editor/Loop.lean`), as `pause`
carries out a pause: to keep it, nothing; to disarm it, the delay armed is
withdrawn (`withdrawHints`); to arm it, that is withdrawn, and a wait is
started on the job clock, due that many milliseconds from now, whose
completion posts an event under `pauseEvents` with the wait's id as its
code (`paused` tells it from a pause by its id). It prints nothing, and
takes no job id. -/
def delayHints (collaborators : Collaborators β σ scheme) (running : Running β σ scheme)
    (change : Loop.HintDelayChange) : BaseIO (Running β σ scheme) := do
  match change with
  | .keep =>
    return running
  | .disarm =>
    running.withdrawHints collaborators
  | .arm generation ms =>
    let running ← running.withdrawHints collaborators
    let services := collaborators.services
    let now ← services.timers.now
    -- As a pause's: in flight on a clock that ends it by itself, it holds a
    -- unit of the host's activity.
    let counted := !services.timers.outside
    let (id, wait) ← services.completions.register
    if counted then
      services.activity.begin
    let fired (completion : Option Job.Completion) : BaseIO Unit := do
      if completion == some .completed then
        discard <| collaborators.postCounted collaborators.pauseEvents id
      if counted then
        services.activity.done
    discard <| BaseIO.mapTask fired wait.result? (sync := true)
    services.timers.start id (now + ms)
    return { running with hintWait := some (id, generation) }

/-- Starts the job registered under `name`, with no arguments, as the driver
asks, and prints its id. -/
def spawn (collaborators : Collaborators β σ scheme) (running : Running β σ scheme)
    (name : String) : IO (Running β σ scheme) := do
  let (id?, running) ← running.startJob collaborators name
  match id? with
  | some id =>
    collaborators.emit s!"spawn {name}: job {id}"
    return { running with spawned := running.spawned.push id }
  | none =>
    collaborators.emit s!"spawn {name}: no such job"
    return running

/-- What the loop's programs watch: the library's interrupt flag, and the
clock the host's jobs wait on, so a test moves one clock for both. -/
def watch (collaborators : Collaborators β σ scheme) : WatchHandler :=
  Watch.real collaborators.services.timers

/-- Drops an event of the window input that no loop takes: one that cannot
be read, or one that arrives when no frame could be made. It has been taken
off the queue all the same, so the flag is lowered for it if the library
marked it (`interrupt`, `Loop.lowerFor`). -/
def drop (collaborators : Collaborators β σ scheme) (interrupt : Bool) : IO Unit :=
  (Loop.lowerFor interrupt).runM (watch collaborators)

/-- Runs `program`, a program of the editor loop, against the library, with
the recorder as the display, the library's interrupt flag and the jobs'
clock as what it watches, and the host's own clipboard and syntax tree, and
hands back its result. The loop's own
programs put a refusal in the echo area and are not refused
(`Editor/Loop.lean`, "When publishing is refused"). One that is refused all
the same is never dropped in silence: it is printed,
`loop: refused: <error>`, and hands back nothing. What it made before the
refusal stays in the table of texts. -/
def attempt {α : Type} (collaborators : Collaborators β σ scheme) (running : Running β σ scheme)
    (program : EditorM α) : IO (Option α × Running β σ scheme) := do
  let (result, texts) ←
    program.runReal running.texts running.display.handle (watch := watch collaborators)
        (clipboard := running.clipboard) (syntaxTree := running.syntaxTree)
  match result with
  | .ok value =>
    return (some value, { running with texts })
  | .error refusal =>
    collaborators.emit s!"loop: refused: {refusal.describe}"
    return (none, { running with texts })

/-- The jobs running that the registry says are reported
(`Config.Registry.reported`), each its owner, name and key, for the session
index (`Loop.Keys.running`). -/
def reported (running : Running β σ scheme) : Array Restore.RunningJob :=
  (running.jobs.table.entries.filter (running.config.registry.reported ·.name)).map fun entry =>
    { owner := entry.owner.name, name := entry.name
      key := (running.keyed.find? (·.2 == entry.id)).map (·.1) }

/-- How many jobs running the session index counts as other jobs
(`Restore.otherJobs`): those the registry neither reports nor says are
restarted by their owner (`Loop.Keys.otherJobs`). -/
def otherJobs (running : Running β σ scheme) : Nat :=
  Restore.otherJobs running.config.registry.reported running.config.registry.restarted
    (running.jobs.table.entries.map (·.name))

/-- What a step of the loop is handed, from the registry as it is now: the
active keymaps of each view (`Config.Registry.activeMaps`: the modes of the
view's buffer, then every owner's key bindings), which the loop applies to
its own state; the lookup an invocation uses (`Config.State.command?`);
the host's threshold for a slow command; and what a command's state
requests are told of the registry (`Config.Registry.registered`: the modes
whose on-enter actions a major mode runs, the jobs' names and the ex
bindings); the mode line, config's listing or the default order resolved
over the registry's segments, a name nobody registered left out
(`Config.Registry.resolve`); the frame padding config set, or the editor's
8 (`Loop.padding`); the layout config chose, or the default
(`Layout.default`); when config chose the tab bar to be shown, or while
there are two tabs or more (`TabBar.Shown.several`); the menu bar the registry's menus make, with its key equivalents filled
from the registry's bindings (`Config.Registry.menuBar?`), or none while no menu is registered; and the
completion styles config chose by category over the registry's styles, or
the fuzzy style (`Config.Registry.matching`); and the completion displays
config chose by category over the registry's displays, or the minibuffer
display (`Config.Registry.displaying`); the registry's prefix names, for
the key hints (`Config.Registry.prefixName?`), and the key hint delay
config set, or the editor's 500 milliseconds (`Loop.keyHintDelay`); and
`now`, the job clock's milliseconds (`Job.Timers.now`), which times what is
viewed of a tracked excerpt (`Loop.Keys.now`). It is made for each window
event, so a reload changes it between two events. -/
def keys (collaborators : Collaborators β σ scheme) (running : Running β σ scheme) (now : Nat) :
    Loop.Keys scheme :=
  { maps := running.config.registry.activeMaps scheme, command? := running.config.command?
    slowAfter := collaborators.slowAfter, registered := running.config.registry.registered
    modeLine := (running.config.registry.resolve (running.config.modeLine.getD .standard)).1
    padding := running.config.framePadding.getD Loop.padding
    layout := some (running.config.layout.getD Layout.default)
    tabBar := some (running.config.tabBar.getD .several)
    menu := running.config.registry.menuBar?
    matching := running.config.registry.matching, inlineMatches := collaborators.inlineMatches
    displaying := running.config.registry.displaying
    prefixNames := running.config.registry.prefixName? scheme
    keyHintDelay := running.config.keyHintDelay.getD (.after Loop.keyHintDelay), now
    stores :=
      { revision := running.config.cellsRevision
        cells := Thunk.mk fun _ => running.config.keptCells }
    running := running.reported, otherJobs := running.otherJobs }

/-- Publishes a scene of the frame's state, if there is a frame, its status
lines drawn by the mode line the registry and config make (`keys`): what
the loop does after every event that is not the window's. A publish that is
refused is printed (`attempt`), and the frame stays as it was.

Then the open prompt's jobs are reconciled with the same keys
(`Loop.completionJobs`) and what that hands back is carried out
(`launch`), as a step's publish does: this publish is the one after an
install, a theme switch and every other event the loop does not take, so a
match that an install ended, stamped with the old config generation, is
spawned again here with the new config's style, with no key typed. A
publish that changes nothing reconciles to nothing.

The publish is the core's, the one a step's is made of
(`Loop.publishHinted`): it opens, closes and lists the key hints for the
keys that can follow now, and what it says of their delay is carried out
(`delayHints`), so an install that sets `.never`, or rebinds the keys under
a pending prefix, closes or opens the hints with no key typed. -/
def publish (collaborators : Collaborators β σ scheme) (running : Running β σ scheme) :
    IO (Running β σ scheme) := do
  let some frame := running.frame | return running
  let keys := running.keys collaborators (← collaborators.services.timers.now)
  let (published, running) ← running.attempt collaborators (frame.publishHinted keys)
  let (published, change) := published.getD (frame, .keep)
  let (frame, starts, cancels, spawns) := published.completionJobs keys
  let running ← { running with frame := some frame }.delayHints collaborators change
  running.launch collaborators starts cancels spawns

/-- The loop's frame, made if there is none (`Collaborators.start`): the
frame is made when the loop is first needed, for a window event, a command
run by name or a job's command. Making it is printed when refused
(`attempt`), and there is then no frame. -/
def framed (collaborators : Collaborators β σ scheme) (running : Running β σ scheme) :
    IO (Option (Loop scheme) × Running β σ scheme) := do
  if let some frame := running.frame then
    return (some frame, running)
  let (made, running) ← running.attempt collaborators collaborators.start
  let running := { running with frame := made }
  -- What was said before there was a frame is said now.
  let running :=
    match made, running.unsaid with
    | some _, some text => { running.said text with unsaid := none }
    | _, _ => running
  -- And what the last reload read of the package set.
  let running := running.withFacts
  return (running.frame, running)

/-- How a command the loop ran ended, as the host prints it after
`run <name>: ` or `job <id> <name>: `. The host prints a line for every
ending, so this matches on each: a new ending gets its words here. -/
def describeEnding : Loop.Ending → String
  | .finished => "ok"
  | .refused refusal => s!"refused: {refusal.describe}"
  | .interrupted => "interrupted"
  | .gaveUp reason => s!"gave up: {reason}"
  | .brokeOff reason => s!"broke off: {reason}"
  | .noSuchCommand => "no such command"
  | .noWindow => "no window"

/-- What a pool task does with a frame the editor thread let go of: reads
one field, so the task holds the frame, which it drops when it ends. It is a
function of its own, never inlined, so that the task's action holds the
frame and does not read it where the task is made (as `Job.start` keeps a
job's work off the calling thread). -/
@[noinline]
def held (previous : Option (Loop scheme)) : BaseIO Nat :=
  return (previous.map (·.shown.size)).getD 0

/-- Lets go of `previous`, the frame a step replaced, on a pool task: what
only it still holds is freed there and not on the editor thread. That is
the listing a match job's delivery replaced, up to 100,000 candidates with
their ranges, whose freeing took the editor thread milliseconds, so a key
that arrived meanwhile waited (`docs/design/concurrency.md`, "Matching off
the editor thread, measured"). It is best effort: should the task end
before the editor thread lets go, the frame is freed here, as before. -/
def release (previous : Option (Loop scheme)) : BaseIO Unit :=
  discard <| BaseIO.asTask (held previous)

/-- Says each failure of the journal's orders the file service kept, once
for each path (`journalSaid`): in the echo area and to the log. -/
def journalFailed (collaborators : Collaborators β σ scheme) (running : Running β σ scheme) :
    IO (Running β σ scheme) := do
  let mut running := running
  for (path, detail) in ← collaborators.journal.failures do
    running := { running with journalFailures := (running.journalFailures.1 + 1, some path) }
    unless running.journalSaid.contains path do
      let text := s!"journal: {path}: {detail}"
      collaborators.log text
      running := { running.said text with journalSaid := running.journalSaid.push path }
  return running

/-- Hands each of `orders`, a step's journal orders (`Loop.Stepped.journal`),
to the file service in order (`Collaborators.journal`), unobserved; then
releases the snapshots they name, which the service holds its own clones
of; then says what failed so far (`journalFailed`). -/
def journaled (collaborators : Collaborators β σ scheme) (running : Running β σ scheme)
    (orders : Array Restore.Order) : IO (Running β σ scheme) := do
  for order in orders do
    collaborators.journal.perform order
  let releases := orders.filterMap (·.release)
  let mut running := running
  unless releases.isEmpty do
    let releasing : EditorM Unit := do
      for id in releases do
        discard <| (observing (TextSource.snapshot id).release : TextM (Except TextError Unit))
    running := (← running.attempt collaborators releasing).2
  running.journalFailed collaborators

/-- Takes in what a step of the loop handed back: the loop after it is the
frame, what the step has to log is logged, what its command asked to be
written is written back to the stores, and the jobs it hands back are
carried out (`launch`): its cancels, then each job its command and the loop
asked for, started for the owner that registered it, then the loop's own
work it spawned, each printed `job <id> <name>: started`. A step whose command asked for the config to be
reloaded (`Loop.Stepped.reload`) feeds the reload reducer a request, as the
driver's `reload` does. A step whose command asked for a theme to be loaded
(`Loop.Stepped.theme`) feeds the reducer a choice of it, which hands the
display the theme (`Config.retheme`), and publishes a scene, drawn in it. A
step that said stop ends the loop. What the step said of the pause of
completion at point and of the key hint delay is carried out on the job
clock (`pause`, `delayHints`).

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
partial def took (collaborators : Collaborators β σ scheme) (running : Running β σ scheme)
    (stepped : Loop.Stepped scheme) : IO (Running β σ scheme) := do
  for entry in stepped.log do
    collaborators.log entry
  -- The frame the step replaced is let go of on the pool (`release`).
  release running.frame
  -- The cancels first, then the journal's orders, then the starts: so a job
  -- started by this step, a restart's save among them, asks the file
  -- service after the orders this step handed it.
  let mut running ←
    ({ running with
            frame := some stepped.loop, stepped := true
            config := (running.config.written stepped.write).restoreCells stepped.restoredCells
            stopped := running.stopped || stepped.next == Loop.Next.stop
            handingFrom :=
              if stepped.loop.state.restore.handing.isSome then
                running.handingFrom <|> some running.journalFailures.1
              else none }).launch
        collaborators #[] stepped.cancels #[]
  running ← running.journaled collaborators stepped.journal
  running ← running.launch collaborators stepped.starts #[] stepped.spawns
  running ← running.pause collaborators stepped.pause
  running ← running.delayHints collaborators stepped.hintDelay
  -- A restart whose session is written: handed over, unless a journal order
  -- failed since it began ("Restarting", in the module docs).
  if let some plan := stepped.handOver then
    let (failures, last) := running.journalFailures
    if failures > running.handingFrom.getD failures then
      let reason :=
        s!"restart: a journal write failed ({last.getD "a journal"}); the session was not handed over"
      if let some frame := running.frame then
        let (answered, attempted) ←
          running.attempt collaborators
              (frame.invoke (running.keys collaborators (← collaborators.services.timers.now))
                { command := Restore.abandonName, arguments := [.str reason] })
        running := attempted
        if let some answered := answered then
          running ← running.took collaborators answered
    else
      return { running with
          stopped := true, handOver := some plan }
  if stepped.reload then
    -- What the driver's `reload` request does: one job at a time.
    running ← running.reduce collaborators .requested
  if let some name := stepped.theme then
    -- The step's scene was published in the theme before: the switch is
    -- drawn in a scene of its own.
    running ← running.reduce collaborators (.choose name)
    running ← running.publish collaborators
  for invocation in stepped.answered do
    -- A step that said stop has ended the loop: nothing more is run.
    if running.stopped then
      break
    let some frame := running.frame | break
    let (answered, attempted) ←
      running.attempt collaborators
          (frame.invoke (running.keys collaborators (← collaborators.services.timers.now))
            invocation)
    running := attempted
    if let some answered := answered then
      running ← running.took collaborators answered
  return running

/-- Handles an event the loop takes (`takenByLoop`), from the window input
or the library's report of a parse delivered: prints a key press with its
identity, tells the reload reducer the window opened when it has (which
asks the window for the paper's appearance), makes the frame if there is
none, and has the editor loop take the
event (`Loop.take`), which lowers the interrupt flag for an interrupt key,
steps the event, runs the command a key yields and publishes a scene. What
the step handed back is taken in (`took`). A close request is a quit by
`q`'s rule: it ends the loop once the editor can leave, and otherwise the
loop goes on with the refusal in the echo area (`Editor/Loop.lean`,
"Quit").

Making the frame and the step are each printed when refused (`attempt`):
after a refused step the frame stays as it was. With no frame made the event
is dropped (`drop`), which lowers the flag for an interrupt key, since no
loop took it off the queue. -/
def input (collaborators : Collaborators β σ scheme) (running : Running β σ scheme)
    (received : Received) : IO (Running β σ scheme) := do
  if let .key which true _ := received.event then
    collaborators.emit s!"key arrived: {which.describe}"
  -- The window's appearance is asked once it has opened (`Config.step`).
  let running ←
    if received.event matches .windowOpened _ then
      running.reduce collaborators .windowOpened
    else
      pure running
  let (made, running) ← running.framed collaborators
  let some frame := made |
    drop collaborators received.interrupt
    return running
  let (stepped, running) ←
    running.attempt collaborators
        (frame.take (running.keys collaborators (← collaborators.services.timers.now)) received)
  match stepped with
  | some stepped =>
    running.took collaborators stepped
  | none =>
    return running

/-- Runs `invocation` through the loop (`Loop.invoke`), as the driver asks,
and prints how it went, under the command's name: the command is guarded,
its state requests are answered, it is rolled back if it does not run to
its end, and a scene is published after it. The frame is made if there is
none. What the step handed back is taken in (`took`). With no frame made,
which the refusal printed before it explains, it says `no frame` and runs
nothing. The driver's `run <name>` is an invocation with no arguments, and
`open <path>` one of the open command with the path. -/
def run (collaborators : Collaborators β σ scheme) (running : Running β σ scheme)
    (invocation : Invocation) : IO (Running β σ scheme) := do
  let name := invocation.command
  let (made, running) ← running.framed collaborators
  let some frame := made |
    collaborators.emit s!"run {name}: no frame"
    return running
  let (stepped, running) ←
    running.attempt collaborators
        (frame.invoke (running.keys collaborators (← collaborators.services.timers.now)) invocation)
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
is handed the host's clipboard and the host's syntax tree too, so a job's
command reaches the ones a key's does: a job's command that sets a major
mode with a syntax attaches and highlights through the host's binding. -/
def ended (collaborators : Collaborators β σ scheme) (running : Running β σ scheme) (id : Nat) :
    IO (Running β σ scheme) := do
  let (result, jobs) ← running.jobs.finish id
  let some (entry, outcome) := result | return { running with jobs }
  -- A keyed job that ended has no key any more.
  let running := { running with jobs }.rekeyed (running.keyed.filter (·.2 != id))
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
          (frame.deliver (running.keys collaborators (← collaborators.services.timers.now)) label
            command)
          running.texts running.display.handle (watch collaborators) running.clipboard
          running.syntaxTree
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

/-- Deals with the pause of completion at point whose wait `id` fired, on the
editor thread: when it is still armed, it is no longer, and the loop runs
`at-point-paused` with its view and milliseconds (`Loop.invoke`), as it
runs a prompt's answered continuation, printing nothing. A pause withdrawn
since its wait completed is passed over.

The key hint delay's wait posts under the same source: when `id` is the
delay armed (`hintWait`), it is no longer, and the loop makes its
generation's hints due and publishes them (`Loop.keyHintsDue`), printing
nothing. -/
def paused (collaborators : Collaborators β σ scheme) (running : Running β σ scheme) (id : UInt64) :
    IO (Running β σ scheme) := do
  if let some (_, generation) := running.hintWait.filter (·.1 == id) then
    let running := { running with hintWait := none }
    let some frame := running.frame | return running
    let (stepped, running) ←
      running.attempt collaborators
          (frame.keyHintsDue (running.keys collaborators (← collaborators.services.timers.now))
            generation)
    let some stepped := stepped | return running
    return ← running.took collaborators stepped
  let some (_, view, ms) := running.pauses.find? (·.1 == id) | return running
  let running := { running with pauses := running.pauses.filter (·.1 != id) }
  let (made, running) ← running.framed collaborators
  let some frame := made | return running
  let (stepped, running) ←
    running.attempt collaborators
        (frame.invoke (running.keys collaborators (← collaborators.services.timers.now))
          { command := Completion.AtPoint.pausedCommand, arguments := [.nat view.index, .nat ms] })
  let some stepped := stepped | return running
  running.took collaborators stepped

/-- Deals with a post of the job `id`, on the editor thread: takes the job's
oldest post out of the mailbox and, while the job is in the table, has the
loop run it (`runPosted`, `Loop.deliver`), labelled `job <id> <name>`, as
a finished job's command is run, and prints how it went. A post of a job
that was cancelled or removed is dropped: nothing runs and nothing is
printed. The frame is made if there is none. -/
def posted (collaborators : Collaborators β σ scheme) (running : Running β σ scheme) (id : Nat) :
    IO (Running β σ scheme) := do
  let some invocation ← running.mailbox.take id | return running
  unless running.jobs.has id do
    return running
  let some entry := running.jobs.table.entries.find? (·.id == id) | return running
  let label := s!"job {entry.id} {entry.name}"
  let (made, running) ← running.framed collaborators
  let some frame := made |
    collaborators.emit s!"{label}: no frame"
    return running
  let (stepped, running) ←
    running.attempt collaborators
        (frame.deliver (running.keys collaborators (← collaborators.services.timers.now)) label
          (runPosted invocation))
  let some stepped := stepped | return running
  collaborators.emit s!"{label}: {describeEnding ((stepped.ended).getD .finished)}"
  running.took collaborators stepped

/-- A key hint as `scene` prints it: its key, then `binding` and its
description, quoted, or `prefix`, its name, quoted, and its count; `-` for
a description or a name it has none of. -/
def hintLine (hint : KeyHint) : String :=
  let label (text : Option String) : String := (text.map (·.quote)).getD "-"
  match hint.leads with
  | .binding desc => s!"hint {hint.key}: binding {label desc}"
  | .prefix name count => s!"hint {hint.key}: prefix {label name} {count}"

/-- A scene as `scene` prints it, read from the text store as it is now: its
frame, then each view, its snapshot's text and its markers' offsets, and
its gutter's width when it has a gutter column, then, for a view that has
any, its decorations, each its face and its range (`decorations <view>:
<face> <start>..<stop> ...`), and its gutter marks, each its text, its face
and its range (`marks <view>: <text> <face> <start>..<stop> ...`), and its
status line (`statusLine`), then each divider, then each key hint
(`hintLine`). `theme` is the name of the theme the scene was drawn in. How
many scenes have been published is no part of it: `published` prints that
on its own (`Request.published`). -/
def sceneLines (scene : Scene) (theme : String) : TextM (Array String) := do
  let focused :=
    match scene.focused with
    | some id => toString id.index
    | none => "-"
  let preedit :=
    match scene.preedit with
    | some text => text.quote
    | none => "-"
  let mut lines :=
    #[s!"scene {scene.size.width}x{scene.size.height}, focused {focused}, echo {scene.echo.quote}, echo padding {scene.echoPadding}, preedit {preedit}, theme {theme.quote}"]
  for view in scene.views do
    let .anchor scroll ← view.scroll.text.marker view.scroll | throw .noSuchMarker
    let selections ←
      view.selections.mapM fun id => do
          let .selection selection ← id.text.marker id | throw .noSuchMarker
          return " ".intercalate
              (selection.ranges.map fun range => s!"{range.anchor}..{range.head}").toList
    let rect := view.rect
    lines :=
      lines.push
        s!"view {view.id.index} {rect.x},{rect.y} {rect.width}x{rect.height}: {(← view.snapshot.read).quote}, scroll {scroll.offset}, selections {" ".intercalate selections.toList}, padding {view.padding.across} {view.padding.down}{if view.padding.top == 0 then "" else s!" top {view.padding.top}"}{if view.padding.gutter == 0 then "" else s!" gutter {view.padding.gutter}"}"
    -- Only a view that has decorations has the line, so a scene with none
    -- prints as it did before there were any.
    unless view.decorations.isEmpty do
      let spans :=
        view.decorations.map fun decoration =>
          s!"{decoration.face.name} {decoration.start}..{decoration.stop}"
      lines := lines.push s!"decorations {view.id.index}: {" ".intercalate spans.toList}"
    -- Likewise for its gutter marks, each its text, its face and its range.
    unless view.marks.isEmpty do
      let marks :=
        view.marks.map fun mark => s!"{mark.text} {mark.face.name} {mark.start}..{mark.stop}"
      lines := lines.push s!"marks {view.id.index}: {" ".intercalate marks.toList}"
    lines := lines.push (statusLine view.id view.status view.statusFace)
  -- Only a scene that has dividers has their lines, so a scene of one
  -- window prints as it did before there were any.
  for divider in scene.dividers do
    let rect := divider.rect
    lines :=
      lines.push s!"divider {rect.x},{rect.y} {rect.width}x{rect.height} in {divider.face.name}"
  -- Only a scene with a keymap prefix pending has key hints, so a scene at
  -- rest prints as it did before there were any.
  return lines ++ scene.keyHints.map hintLine

/-- Prints the last scene published, or that there is none. -/
def scene (collaborators : Collaborators β σ scheme) (running : Running β σ scheme) :
    IO (Running β σ scheme) := do
  let some scene ← running.display.last? |
    collaborators.emit "scene: none"
    return running
  let (result, texts) ← (sceneLines scene (← running.display.drawn)).runReal running.texts
  match result with
  | .ok lines =>
    for line in lines do
      collaborators.emit line
  | .error refusal =>
    collaborators.emit s!"scene: refused: {refusal.describe}"
  return { running with texts }

/-- Rows as `agree` prints them: each `<start>..<stop>`, joined by spaces. -/
def rowsText (rows : Array Display.Row) : String :=
  " ".intercalate (rows.map fun row => s!"{row.start}..{row.stop}").toList

/-- What `agree` says of the focused view of `scene`, the last scene
published, given `asked`, the rows queries answered since the publish before
it, and `shown`, the rows of the frame the display laid out of it: the last
query that names the view's snapshot, at its width and the anchor it was
published with (`anchor`), and its padding, since the loop asks with it,
and whether its rows are the frame's. The query's height is not matched: it
is what the loop asked with, and a height other than the frame's text area
is what `agree` is there to catch. -/
def agreement (scene : Scene) (anchor : Nat) (asked : Array Asked)
    (shown : Option (Array Display.Row)) : String :=
  match scene.focused.bind fun id => scene.views.find? (·.id == id) with
  | none => "agree: no focused view"
  | some view =>
    let matches_ (asked : Asked) : Bool :=
      asked.query.snapshot == view.snapshot && asked.query.width == view.rect.width &&
        asked.query.anchor == anchor &&
        asked.query.padding == view.padding
    match (asked.filter matches_).back?, shown with
    | none, _ => s!"agree view {view.id.index}: no rows query from {anchor}"
    | some _, none => s!"agree view {view.id.index}: the frame has no such view"
    | some query, some shown =>
      let said :=
        s!"agree view {view.id.index}: {query.rows.size} rows asked from {anchor}, {shown.size} in the frame"
      if query.rows == shown then s!"{said}: agrees"
      else s!"{said}: disagrees: asked {rowsText query.rows}, frame {rowsText shown}"

/-- Prints whether the latest rows query about the focused view matches the
frame the display laid out of the last scene (`agreement`): the query that
names the view's snapshot, at the anchor it was published with. A display
that lays out no frame, the recorder, says `agree: no frame`. -/
def agree (collaborators : Collaborators β σ scheme) (running : Running β σ scheme) :
    IO (Running β σ scheme) := do
  let some frameRows := running.display.frameRows |
    collaborators.emit "agree: no frame"
    return running
  let some scene ← running.display.last? |
    collaborators.emit "agree: no frame"
    return running
  let some view := scene.focused.bind fun id => scene.views.find? (·.id == id) |
    collaborators.emit "agree: no focused view"
    return running
  let anchorOf : TextM Nat := do
    let .anchor anchor ← view.scroll.text.marker view.scroll | throw .noSuchMarker
    return anchor.offset
  let (anchor, texts) ← anchorOf.runReal running.texts
  let running := { running with texts }
  match anchor with
  | .error refusal =>
    collaborators.emit s!"agree: refused: {refusal.describe}"
  | .ok anchor =>
    let (before, since) ← running.display.asked.get
    collaborators.emit (agreement scene anchor (before ++ since) (← frameRows view.id))
  return running

/-- Prints the commands, the texts and the stores. -/
def «show» (collaborators : Collaborators β σ scheme) (running : Running β σ scheme) : IO Unit := do
  collaborators.emit (" ".intercalate ("commands:" :: running.config.registry.names.toList))
  for index in [0:running.texts.documents.size] do
    -- A text a command released has no document, and no line.
    if let some (some document) := running.texts.documents[index]? then
      collaborators.emit s!"text {index}: {(← document.read).quote}"
  for cell in running.config.cells.cells do
    collaborators.emit s!"store {cell.name} v{cell.version}: {render cell.value}"

/-- The values of a store as `workspaces` prints them, after a colon: each
` <name>=<value>`, in order; nothing for none. -/
def cellsLine (cells : Array (String × Value)) : String :=
  String.join (cells.toList.map fun (name, value) => s!" {name}={render value}")

/-- Prints the workspace table of the frame's state (`Workspace.Table`): a
line for each workspace, `workspace <label> at <location>: <name>=<value> …`,
then for each project, `project <name>: …`, then `unscoped: …`. With no
frame, nothing. -/
def workspaces (collaborators : Collaborators β σ scheme) (running : Running β σ scheme) :
    IO Unit := do
  let some frame := running.frame | return
  let table := frame.state.workspaces
  for (workspace, cells) in table.workspaces do
    collaborators.emit
        s!"workspace {workspace.label} at {workspace.location.describe}:{cellsLine cells}"
  for (project, cells) in table.projects do
    collaborators.emit s!"project {project.name}:{cellsLine cells}"
  collaborators.emit s!"unscoped:{cellsLine table.unscoped}"

/-- Whether the editor loop takes `event` (`input`): an event from the
window input, and the library's report that a parse of a highlighted text
was delivered (`Event.parsed`), which the loop answers with a scene laid
out with the new tree. Every other event is `other`'s. -/
def takenByLoop (event : Ffi.Event) : Bool :=
  event.source.kind == .window || (event.source.kind == .library && event.kind == .parsed)

/-- Does what the driver asked, `request`: a restore starts the job
`restore` with the state directory, printed `job <id> restore: started`, and
holds the requests that follow until it has finished ("Restoring a session",
in the module docs); with no state directory, or no such job registered, it
does nothing. -/
def request (collaborators : Collaborators β σ scheme) (running : Running β σ scheme) :
    Request → IO (Running β σ scheme)
  | .reload => running.reduce collaborators .requested
  | .run name => running.run collaborators { command := name }
  | .open path =>
    running.run collaborators { command := FileJobs.openFileCommand, arguments := [.str path] }
  | .say text => return running.said text
  | .spawn name => running.spawn collaborators name
  | .show => do
    running.show collaborators
    return running
  | .workspaces => do
    running.workspaces collaborators
    return running
  | .published => do
    collaborators.emit s!"published {← running.display.published}"
    return running
  | .scene => running.scene collaborators
  | .agree => running.agree collaborators
  | .restore named => do
    let some directory := collaborators.stateDirectory | return running
    let arguments := [Argument.str directory.toString] ++ (named.map (.str ·.toString)).toList
    let (id?, running) ← running.startJob collaborators Restore.restoreJob arguments
    let some id := id? | return running
    collaborators.emit s!"job {id} {Restore.restoreJob}: started"
    return { running with restoring := some id }

/-- Ends a restore in flight once it has finished: its second half's command
has run (`Restore.Kept.restored`), or neither of its jobs is in the table
any more, failed or cancelled. Then the requests held are handled in
order, as they would have been. -/
def settleRestore (collaborators : Collaborators β σ scheme) (running : Running β σ scheme) :
    IO (Running β σ scheme) := do
  if running.restoring.isNone then
    return running
  let restored := running.frame.any (·.state.restore.restored)
  let inFlight :=
    running.jobs.table.entries.any fun entry =>
      entry.name == Restore.restoreJob || entry.name == Restore.filesJob
  unless restored || !inFlight do
    return running
  let held := running.heldRequests
  let mut running :=
    { running with
      restoring := none, heldRequests := #[] }
  for request in held do
    running ← running.request collaborators request
  return running

/-- Handles one event of the editor queue that the loop does not take
(`takenByLoop`). -/
def other (collaborators : Collaborators β σ scheme) (running : Running β σ scheme)
    (event : Ffi.Event) : IO (Running β σ scheme) := do
  match event.source.kind with
  | .script =>
    collaborators.emit s!"event {event.source.id} {event.code}"
    return running
  | .library | .window =>
    -- The library's events the loop takes are `takenByLoop`'s: what is
    -- left of the library's is nothing to handle here.
    return running
  | .lean =>
    if event.source.id == collaborators.wakeups then
      return ← running.finish collaborators
    if event.source.id == collaborators.jobs then
      return ← running.ended collaborators event.code.toNat
    if event.source.id == collaborators.posts then
      return ← running.posted collaborators event.code.toNat
    if event.source.id == collaborators.pauseEvents then
      return ← running.paused collaborators event.code
    if event.source.id == collaborators.environment then
      return running.said event.text
    unless event.source.id == collaborators.requests do
      return running
    match Signal.decode? event.code event.text with
    | some (.request request) =>
      -- While a restore is in flight the driver's requests wait for it.
      if running.restoring.isSome then
        return { running with heldRequests := running.heldRequests.push request }
      running.request collaborators request
    | some .marker =>
      return { running with markers := running.markers + 1 }
    | some .stop =>
      return { running with stopped := true }
    -- A probe is counted in `handle`, before this, and never reaches it.
    | some .probe | none =>
      return running

/-- Handles one event of the editor queue to its end. An event the loop takes
(`takenByLoop`: from the window input, or the library's report of a parse
delivered) goes to the editor loop (`input`), which publishes a scene after
it, so a delivered parse is drawn with no key pressed. So does a command the
loop runs for another event: the driver's `run`, and a finished job's
command. After any other event, a scene is published once there is a frame,
unless the driver has ended the loop. An event the loop takes that cannot
be read is dropped (`drop`), which lowers the interrupt flag for a key that
carries the library's mark (`Event.interruptMarked`), since the event has
been taken off the queue. -/
def handle (collaborators : Collaborators β σ scheme) (running : Running β σ scheme)
    (event : Ffi.Event) : IO (Running β σ scheme) := do
  -- A probe is counted and nothing else: no scene, no restore's release.
  if
      event.source.kind == .lean && event.source.id == collaborators.requests &&
        (Signal.decode? event.code event.text).any (· matches .probe) then
    return { running with markers := running.markers + 1 }
  if takenByLoop event then
    match Event.ofFfi event with
    | .ok received =>
      running.input collaborators received
    | .error _ =>
      drop collaborators (Event.interruptMarked event)
      return running
  else
    let running ← ({ running with stepped := false }).other collaborators event
    -- A step of the loop published its own scene.
    let running ←
      if running.stopped || running.stepped then
        pure running
      else
        running.publish collaborators
    running.settleRestore collaborators

end Running

/-- How far the editor thread has got, as it tells its driver after each
event. -/
structure Progress where
  /-- How many markers the loop has reached. -/
  markers : Nat := 0
  /-- Whether a reload job is running. -/
  reloading : Bool := false
  /-- Whether a restore is in flight, the driver's requests held. -/
  restoring : Bool := false
  /-- How many jobs are running: started, and neither dealt with nor
  cancelled with their owner. -/
  jobs : Nat := 0
  /-- Whether the session index is being written: its write or its save is
  running, or a write was started and has not rendered the index
  (`Restore.Kept.writing`). -/
  indexing : Bool := false
  /-- How many jobs are running that are neither the index's write or save
  nor jobs the driver spawned (`Request.spawn`): what the script's `indexed`
  waits for beside the index. -/
  background : Nat := 0
  /-- The title bar the installed config chose (`Config.State.titleBar`),
  or none: what the window mode opens its window with once the start-up
  reload has finished (`Window.titleBarAtOpen`). -/
  titleBar : Option Window.TitleBar := none
  /-- The plan of the restart the loop ended for, set once it has ended
  ("Restarting", in the module docs). -/
  handOver : Option Restart.Plan := none
  /-- Whether the last reload that finished installed its config, none
  before one has: what a script's `installed` reads. -/
  installed : Option Bool := none

/-- What the editor thread holds as its loop starts: the config state its
packages make (`Config.State.ofPackages`: each of `collaborators.packages`
registered in order, for the owner named after it, before any config),
knowing what the running editor knows of its own package set
(`collaborators.packageSet`), no
texts, the display its collaborators make over the table of snapshots the
text binding publishes, the clipboard they make, the syntax tree they make
over the same table, no jobs, an empty mailbox and no frame.

A package that is refused is skipped, and what it was refused with is
handed to the collaborators' log, prefixed with `package: `; the others
register and the loop starts. -/
def Running.new {β σ : Type} {scheme : InputScheme} (collaborators : Collaborators β σ scheme) :
    IO (Running β σ scheme) := do
  let (config, refused) := Config.State.ofPackages collaborators.packages
  for message in refused do
    collaborators.log s!"package: {message}"
  return {
      config := { config with packageSet := collaborators.packageSet }
      texts := RealTexts.over collaborators.published
      display := ← collaborators.display collaborators.published.reader
      clipboard := ← collaborators.clipboard
      syntaxTree := ← collaborators.syntaxTree collaborators.published.reader
      jobs := { services := collaborators.services }
      mailbox := ← Job.Mailbox.new }

/-- One turn of the loop, the editor thread's and a stepped host's
(`Editor/Headless/Stepped.lean`) alike: handles `event` to its end
(`handle`), then gives back the unit of the host's activity it came under,
when it came under one (`Collaborators.postCounted`,
`Collaborators.counts`). -/
def Running.turn {β σ : Type} {scheme : InputScheme} (collaborators : Collaborators β σ scheme)
    (running : Running β σ scheme) (event : Ffi.Event) : IO (Running β σ scheme) := do
  let running ← running.handle collaborators event
  -- An event posted under a unit of the host's activity gives it back
  -- once it has been handled (`Collaborators.postCounted`).
  if collaborators.counts event then
    collaborators.services.activity.done
  return running

/-- How far the loop has got, as it tells its driver after each event: how
many markers it has reached, whether a reload is running, how many jobs
are, the title bar the installed config chose, and whether the last reload
that finished installed its config. -/
def Running.progress {β σ : Type} {scheme : InputScheme} (running : Running β σ scheme) :
    Progress :=
  { markers := running.markers, reloading := running.config.running,
    restoring := running.restoring.isSome, jobs := running.jobs.running
    titleBar := running.config.titleBar
    indexing :=
      running.frame.any (·.state.restore.writing) ||
        running.jobs.table.entries.any fun entry =>
          entry.name == Restore.writeJob || entry.name == Restore.saveJob
    background :=
      (running.jobs.table.entries.filter fun entry =>
          entry.name != Restore.writeJob && entry.name != Restore.saveJob &&
            !running.spawned.contains entry.id).size
    handOver := running.handOver
    installed := running.installed }

/-- The loop's end, the editor thread's and a stepped host's alike: nothing
will deal with a result any more, so every job is cancelled, and every pause
and the hint delay withdrawn; and the reload job is the loop's, so the end
waits for it, after telling `Collaborators.endWaits`, when it has not
ended: through `awaitReload`, a plain wait for its task unless a stepped
host's bracket guards it. A cancelled job ends on a pool thread and then
posts its wake-up, which nothing will take; the end does not wait for that,
and hands `Collaborators.endCancelled` what to wait on: every job cancelled
and not yet done (`Job.Services.unsettled`), those its own cancel has just
cancelled and those an owner's removal or a keyed cancel cancelled before,
which have left its table of jobs. Last it ends the loop in the runner's
protocol (`Job.Services.endLoop`), which the model decides: recorded once
every cancelled job is done, as it is where `endCancelled` waits for them,
and never before. A host's real recorder keeps nothing of it. -/
def Running.wind {β σ : Type} {scheme : InputScheme} (collaborators : Collaborators β σ scheme)
    (running : Running β σ scheme)
    (awaitReload : Task (Except IO.Error Unit) → IO Unit := fun task => discard <| IO.wait task) :
    IO Unit := do
  running.jobs.cancelAll
  let running ← running.withdrawPauses collaborators
  discard <| running.withdrawHints collaborators
  -- The reload job is the loop's: the loop ends once it has, so the host's
  -- bracket, which waits for the loop, waits for it too. Its wake-up to a
  -- queue that has been quit is refused, and gives its unit back.
  if let some task := running.reloadTask then
    unless ← IO.hasFinished task do
      collaborators.endWaits "reload"
      awaitReload task
  -- Every job cancelled and not yet done, its end's own and those cancelled
  -- before: a stage waits for them here.
  collaborators.endCancelled (← collaborators.services.unsettled)
  -- The loop's end, as the runner's protocol has it, which the model
  -- applies only once every cancelled job is done.
  discard <| collaborators.services.endLoop

/-- The editor thread: pulls the editor queue and takes one turn of the loop
for each event (`Running.turn`), until the driver ends the loop or the
queues are quit. After each event it publishes in `progress` how far it has
got (`Running.progress`).

Before the first event it calls `Collaborators.loopStarted`, registers the
packages it is handed (`Running.new`), and tells the library its interrupt
key; when it ends it leaves the library with none, so that no key raises
the flag while no loop takes keys off the queue. Its end (`Running.wind`)
cancels every job and waits for the reload job it started, if that has not
ended, after telling `Collaborators.endWaits`: no reload outlives its
loop. -/
def loop {β σ : Type} {scheme : InputScheme} (collaborators : Collaborators β σ scheme)
    (progress : IO.Ref Progress) (reached : IO.Ref (Option (Nat × IO.Promise Unit))) : IO Unit := do
  collaborators.loopStarted
  discard <| Event.setInterruptKey (some collaborators.interruptKey)
  let mut running ← Running.new collaborators
  repeat
    let event ← Ffi.nextEvent .editor
    if event.kind == .quit then
      break
    let markers := running.markers
    running ← running.turn collaborators event
    if running.stopped then
      break
    progress.set running.progress
    -- A marker or a probe the driver waits on is answered once the progress
    -- it reads has been published: one look at the armed marker, and only
    -- after an event that moved the count of markers.
    if running.markers != markers then
      let armed ←
        reached.modifyGet fun armed =>
            match armed with
            | some (number, promise) =>
              if running.markers >= number then (some promise, none) else (none, armed)
            | none => (none, none)
      if let some promise := armed then
        promise.resolve ()
  -- A loop that ended for a restart tells its driver the plan.
  if let some plan := running.handOver then
    progress.modify fun progress => { progress with handOver := some plan }
  running.wind collaborators
  -- Nor will anything take a key off the queue, so none is to raise the flag.
  discard <| Event.setInterruptKey none

/-- A running host, as its driver holds it. Only its bracket makes one
(`withHost`), so no host outlives its loop: its constructor and `start` are
private to this module. Its fields are read inside the bracket. -/
structure Host where private mk ::
  /-- The Lean source id the driver's events are posted under. -/
  requests : UInt64
  /-- How many markers the driver has posted. -/
  posted : IO.Ref Nat
  /-- How far the loop has got. -/
  progress : IO.Ref Progress
  /-- The marker the driver waits for, if it waits for one: its number, and
  the promise the loop resolves once it has reached it and published the
  progress after it. -/
  reached : IO.Ref (Option (Nat × IO.Promise Unit))
  /-- The host's activity count, its idle signal: a count of its own when
  its collaborators track it (`Collaborators.tracksIdle`), and otherwise
  `Job.Activity.untracked`. -/
  activity : Job.Activity
  /-- The fake clock the host's jobs wait on, if they wait on one. -/
  clock : Option Job.FakeClock
  /-- The loop. -/
  thread : Task (Except IO.Error Unit)

/-- The collaborators whose `start` makes the loop with their working
directory, home directory and state directory in its first state
(`EditorState.hostedBy`). -/
def Collaborators.hosting {β σ : Type} {scheme : InputScheme}
    (collaborators : Collaborators β σ scheme) : Collaborators β σ scheme :=
  let made := collaborators.start
  { collaborators with
    start := do
      let loop ← made
      return { loop with
          state :=
            loop.state.hostedBy collaborators.workingDirectory collaborators.home
              collaborators.stateDirectory collaborators.launch collaborators.packageSet } }

/-- The collaborators as a host's loop runs over them, a real host's and a
stepped one's alike: hosting (`hosting`), and, when they track their idle,
with a count of the host's own (`Job.Activity.counting`), never a stage's,
so a late step of an earlier host's job cannot reach a later host's idle. -/
def Collaborators.prepared {β σ : Type} {scheme : InputScheme}
    (collaborators : Collaborators β σ scheme) : IO (Collaborators β σ scheme) := do
  let collaborators := collaborators.hosting
  if collaborators.tracksIdle then
    return { collaborators with
        services := { collaborators.services with activity := ← Job.Activity.counting } }
  return collaborators

/-- Starts a host: its loop runs on a dedicated task until it is asked to stop
or it ends by itself. The loop it makes, when it is first needed, has the
collaborators' working directory, home directory and state directory in its
state (`Collaborators.hosting`). It refuses, starting nothing, collaborators
whose queue a stepper pulls (`Queue.Puller.stepper`). Private: a host is had
only inside its bracket (`withHost`), which ends the loop. -/
private def start {β σ : Type} {scheme : InputScheme} (collaborators : Collaborators β σ scheme) :
    IO Host := do
  -- A real loop pulls the library's queue: collaborators that post to a
  -- queue a stepper drains would post where nothing takes.
  unless collaborators.queue.pulledBy == .library do
    throw <|
        IO.userError
          "a real host's queue must be the library's: its collaborators' queue is pulled by a stepper"
  let collaborators ← collaborators.prepared
  let progress ← IO.mkRef {}
  let reached ← IO.mkRef none
  let thread ← IO.asTask (prio := .dedicated) (loop collaborators progress reached)
  return {
      requests := collaborators.requests, posted := ← IO.mkRef 0, progress, reached
      activity := collaborators.services.activity, clock := collaborators.clock, thread }

/-- What a driver's wait says, through its `waitHung`, when it reaches its
guard: a hang, once, never a result. It is the hang `guard`, the guard that
ran out, says (`HangGuard.hang`: its event and its bound), then the wait:
`what` is the wait (`settle`, `join`, `advance`, `restarted`, or `answer
to the …` for the editor thread's answer within one), and `line` the
script's line, if it has one. -/
def waitHangLine (what : String) (line : Option Nat) (guard : HangGuard) : String :=
  let place :=
    match line with
    | some line => s!" on line {line}"
    | none => ""
  s!"editor: {guard.hang}: the {what}{place}"

/-- Whether one of `tasks` has ended within `guard`, waited for on the tasks
themselves: a guard against a hang, never a result (`Job.awaitWithin`). -/
def awaitAnyWithin (guard : HangGuard) (tasks : List (Task Unit)) : IO Bool := do
  for task in tasks do
    if ← IO.hasFinished task then
      return true
  let first ← IO.Promise.new
  -- Each map runs on the thread that ends its task, and the list holds them
  -- for as long as the wait does.
  let maps ← tasks.mapM fun task => BaseIO.mapTask (fun _ => first.resolve ()) task (sync := true)
  let ended ← Job.awaitWithin guard first.result?
  for task in maps do
    IO.cancel task
  return ended.isSome

/-- What a driver's wait waits for: one value per kind of wait, the same for
the real host's wait (`Host.waitWhile`), a stepped host's
(`Stepped.waitWhile`), the script runner's (`runScript`) and a test's, so a
`settle`, a `join` and an `advance` mean one thing wherever they are
waited. -/
structure Wait.Kind where
  /-- The wait's name in its hang line (`waitHangLine`). -/
  what : String
  /-- Whether what the wait is for still holds of the loop's progress. -/
  busy : Progress → IO Bool
  /-- What the wait answers once the host is idle with it still busy
  (`Round.still`): none waits on to the guard. -/
  still : Option Wait := none
  /-- What the wait answers at its guard, a hang (`Round.hung`). -/
  hung : Wait
  /-- Whether its first round's marker publishes a scene (`Signal.marker`),
  or every round's is a probe, which publishes nothing (`Signal.probe`). -/
  marker : Bool := true

/- What a wait of a kind infers "done" from is its `busy` and its `still`:
a kind whose `still` is set answers at the host's idle, and one whose
`busy` reads the job counts infers from them. So a kind is made, or its
`busy` or `still` set, only here and in the drivers' modules
(`linter.inferredWait`, `docs/dev-practices/inferred-waits.md`); a check
elsewhere waits with one of the kinds below, and those that infer from the
host's idle, its job counts or the first wait on its fake clock are marked
too. -/
/-- `Wait.Kind.mk` is an inferred wait (`Editor/InferredWait.lean`). -/
def Wait.Kind.mk.inferredWait : InferredWait :=
  .idle [`Editor.Headless.Stepped, `Editor.Headless.Wait]

/-- `Wait.Kind.busy` is an inferred wait (`Editor/InferredWait.lean`). -/
def Wait.Kind.busy.inferredWait : InferredWait :=
  .idle [`Editor.Headless.Stepped, `Editor.Headless.Wait]

/-- `Wait.Kind.still` is an inferred wait (`Editor/InferredWait.lean`). -/
def Wait.Kind.still.inferredWait : InferredWait :=
  .idle [`Editor.Headless.Stepped, `Editor.Headless.Wait]

namespace Wait.Kind

/-- A `settle`'s wait: until no reload is running and no restore is in
flight; at idle it waits on, and at its guard it is `reloading`. A running
reload holds a unit of the host's activity, so the wait ends at the
reload's end. A restore holds the driver's requests after it, the start-up
reload among them, so a wait for that reload waits for the restore first. -/
def settle : Wait.Kind where
  what := "settle"
  busy progress := pure (progress.reloading || progress.restoring)
  hung := .reloading

/-- `join` is an inferred wait (`Editor/InferredWait.lean`). -/
def join.inferredWait : InferredWait :=
  .idle [`Editor.Headless.Stepped, `Editor.Headless.Wait, `Editor.Test.Linked.Host]

/-- A `join`'s wait: until no job is running; `working` once the host is
idle with a job still running, which nothing left to run can end, as a job
asleep on a fake clock nobody moves; `busy` at its guard. A job is running
from its `spawn` until the editor thread has dealt with its result, or has
cancelled it with its owner. -/
def join : Wait.Kind where
  what := "join"
  busy progress := pure (progress.jobs > 0)
  still := some .working
  hung := .busy

/-- `advance` is an inferred wait (`Editor/InferredWait.lean`). -/
def advance.inferredWait : InferredWait :=
  .firstAfter [`Editor.Headless.Stepped, `Editor.Headless.Wait, `Editor.Test.Linked.Host]

/-- An `advance`'s wait: until `clock` holds a wait due within
`milliseconds`, publishing nothing; `working` at idle with none due, a
stall, and `busy` at its guard. -/
def advance (clock : Job.FakeClock) (milliseconds : Nat) : Wait.Kind where
  what := "advance"
  busy _ := return !(← clock.dueWithin milliseconds)
  still := some .working
  hung := .busy
  marker := false

/-- A wait only until the host has handled everything sent so far, whatever
is still running, publishing nothing: `settled` once it has. A stepped host
handles what was sent only in a wait, so a test that sends a request whose
start it then watches for asks this first. -/
def handled : Wait.Kind where
  what := "answer"
  busy _ := pure false
  hung := .unanswered
  marker := false

/-- `indexed` is an inferred wait (`Editor/InferredWait.lean`). -/
def indexed.inferredWait : InferredWait :=
  .idle [`Editor.Headless.Stepped, `Editor.Headless.Wait, `Editor.Test.Linked.Host]

/-- An `indexed`'s wait: until the session index is written, no write or
save of it running and no job running but those the script started with
`spawn` (`Progress.indexing`, `Progress.background`), publishing nothing;
`working` once the host is idle with that still so, and `unanswered` at its
guard. A write sleeps on the job clock (`Restore.writeDelay`): at idle the
driver moves the clock past it and waits again (`awaitIndexed`). A
background job asleep on the fake clock fails the run at idle, never at the
guard. -/
def indexed : Wait.Kind where
  what := "indexed"
  busy progress := pure (progress.indexing || progress.background > 0)
  still := some .working
  hung := .unanswered
  marker := false

/-- `idle` is an inferred wait (`Editor/InferredWait.lean`). -/
def idle.inferredWait : InferredWait :=
  .idle [`Editor.Headless.Stepped, `Editor.Headless.Wait, `Editor.Test.Linked.Host]

/-- A `join`'s wait that publishes nothing (its marker is a probe): what
replaces a poll for a state the host reaches by itself, such as a job in
its sleep, so the scene count stays the poll's. -/
def idle : Wait.Kind :=
  { join with marker := false }

/-- `quiet` is an inferred wait (`Editor/InferredWait.lean`). -/
def quiet.inferredWait : InferredWait :=
  .idle [`Editor.Headless.Stepped, `Editor.Headless.Wait, `Editor.Test.Linked.Host]

/-- A wait until the host is idle (`docs/design/concurrency.md`, "The idle
signal": everything sent handled, nothing that can end by itself running,
no fake-clock wait due), publishing nothing: what it waits for always
holds, so it answers only at idle, `settled`, and `busy` at its guard. -/
def quiet : Wait.Kind where
  what := "idle"
  busy _ := pure true
  still := some .settled
  hung := .busy
  marker := false

/-- The verdict of a round of a wait of this kind (`Round.judge`), read once
the driver has the loop up to date: whether it is still busy of `progress`,
the host's `activity` now against `before`, the reading the round began
with, whether a wait of `clock` is due, and what is left before `deadline`,
the deadline of the wait's guard `waitGuard`. At the hang it says it once,
through `waitHung` (`waitHangLine`, naming the wait and its script's `line`
and the guard that ran out). Both drivers' waits call it, so their rounds
are judged as one. -/
def judge (kind : Wait.Kind) (progress : Progress) (activity : Job.Activity)
    (clock : Option Job.FakeClock) (before : Job.Activity.Seen) (deadline : HangGuard.Deadline)
    (waitGuard : HangGuard) (line : Option Nat) (waitHung : String → IO Unit) : IO Round.Verdict :=
  do
  let busy ← kind.busy progress
  let now ← activity.seen
  let due ←
    match clock with
    | some clock =>
      clock.dueWithin 0
    | none =>
      pure false
  let verdict :=
    Round.judge
      { busy, tracked := activity.tracked, before, now, due, remaining := (← deadline.rest).ms
        still := kind.still, hung := kind.hung }
  if let .hang _ := verdict then
    waitHung (waitHangLine kind.what line waitGuard)
  return verdict

end Wait.Kind

/-- `awaitIndexed` is an inferred wait (`Editor/InferredWait.lean`). -/
def awaitIndexed.inferredWait : InferredWait :=
  .idle [`Editor.Headless.Stepped, `Editor.Headless.Wait, `Editor.Test.Linked.Host]

/-- The loop of an `indexed`'s wait, over a driver's wait of a kind (`wait`,
a host's `waitWhile` or a stepped one's), its progress and its fake clock:
each round waits on `Wait.Kind.indexed`; at idle with a write of the index
in its sleep and no other job running, `clock` is moved past the write's
delay (`Restore.writeDelay`) and the wait goes round again, so what the jobs
changed is in one write; at idle otherwise it answers `working`, which
fails the run. Each round ends on an event, idle among them, and its guard
is the wait's, a hang guard. The script's `indexed` and the config tests'
stepped twin both run it. -/
def awaitIndexed (wait : Wait.Kind → IO Wait) (progress : IO Progress)
    (clock : Option Job.FakeClock) : IO Wait := do
  repeat
    match ← wait Wait.Kind.indexed with
    | .working =>
      let now ← progress
      if let some clock := clock then
        if now.indexing && now.background == 0 && (← clock.dueWithin Restore.writeDelay) then
          clock.advance Restore.writeDelay
          continue
      return .working
    | other =>
      return other
  return .unanswered

namespace Host

/-- `activitySeen` is an inferred wait (`Editor/InferredWait.lean`). -/
def activitySeen.inferredWait : InferredWait :=
  .count []

/-- The host's activity count and its epoch, read in one step: for a test,
which looks at what the host's idle is made of (`Job.Activity`). -/
def activitySeen (host : Host) : BaseIO Job.Activity.Seen :=
  host.activity.seen

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

/-- Sends a resize of the frame to `width` by `height` physical pixels, at a
scale of 1 and out of fullscreen, with square corners (a corner clearance of
0), as the window would report it: through the library's window
input (`Event.post`), onto the editor queue after everything sent before.
Throws if the queue refuses it, which it does once the queues are quit. -/
def resize (_ : Host) (width height : Nat) : IO Unit := do
  unless ← Event.post (.resize { width, height, scale := 1.0 }) do
    throw (IO.userError "the editor queue refused a resize: it has been quit")

/-- The poll of a wait on a host that keeps no count (the window mode's):
what the wait is for is looked at again each millisecond as the progress
changes, until the guard (follow-up window-mode-waits-poll-progress). -/
def untrackedPoll : RealTime :=
  .under "the poll of a wait on a host that keeps no count" 1

/-- Waits until the editor thread has handled everything sent so far and
what `kind` waits for no longer holds of its progress (`Wait.Kind`), and
says what the wait came to. Every wait in it is on an event, and each is
bounded only by a guard against a hang.

It goes in rounds. A round reads the host's activity count (`Job.Activity`),
posts a marker (the first round's is `Signal.marker`, which publishes a scene
as a `settle`'s and a `join`'s always have, unless the kind's `marker` is
`false`, as an `advance`'s, which shows nothing; every later one's a
`Signal.probe`, which publishes nothing), and waits for the loop to answer
it: the loop resolves the marker's promise once it has handled everything
posted before it and published its progress (`loop`). Then the round is
judged as every driver's is (`Wait.Kind.judge`, `Round.judge`,
`Editor/Headless/Wait.lean`): over, with `settled` or the kind's idle
outcome; another round; the hang at the guard; or a block on work still
running, here on the count's next change or the loop's end, and then
another round.

`waitBlocked` is called each time the wait is about to block: with
`"answer"` before the editor thread's answer, when it has not come yet,
and with `"running work"` before a block on work still running. It is the
event a test lets a held step go on, in place of a guard; its default does
nothing.

The editor thread's answer is guarded by `answer`, each round, and the
whole wait by `waitGuard`. At either guard the wait says the hang
once, through `waitHung` (`waitHangLine`, naming the kind's `what` and its
script's `line`), and ends: `unanswered` at the answer's, and the kind's
`hung` at the wait's (`reloading` for a `settle`, `busy` for a `join` or an
`advance`). A guard is never a result: it fails the run as a hang.

A host that keeps no count (`Job.Activity.tracked` false, the window
mode's) is never idle: once the editor thread has answered, its wait looks
at what it waits for again as the progress changes, until it no longer
holds or the guard.

A loop that has ended, or ends while the wait runs, is answered `ended` as
soon as it is seen: its task has finished, so nothing it was waited for
will happen. The loop's last progress is not read then: the loop does not
publish it once it has ended, so it may still say a job is running. -/
def waitWhile (host : Host) (waitGuard : HangGuard) (kind : Wait.Kind)
    (answer : HangGuard := waitGuard) (line : Option Nat := none)
    (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Wait := do
  if ← IO.hasFinished host.thread then
    return .ended
  let deadline ← waitGuard.deadline
  let thread := host.thread.map (sync := true) fun _ => ()
  let mut first := kind.marker
  repeat
    if ← IO.hasFinished host.thread then
      return .ended
    let before ← host.activity.seen
    let marker ← host.posted.modifyGet fun posted => (posted + 1, posted + 1)
    let answered ← IO.Promise.new
    host.reached.set (some (marker, answered))
    -- The marker was posted after everything sent so far: a loop that has
    -- answered it is up to date, and what it is waiting for is what is busy.
    host.post (if first then .marker else .probe)
    first := false
    unless ← answered.isResolved do
      waitBlocked "answer"
    discard <| awaitAnyWithin answer [answered.result?.map (sync := true) fun _ => (), thread]
    if ← IO.hasFinished host.thread then
      return .ended
    unless ← answered.isResolved do
      waitHung (waitHangLine s!"answer to the {kind.what}" line answer)
      return .unanswered
    match
      ←
        kind.judge (← host.progress.get) host.activity host.clock before deadline waitGuard line
            waitHung with
    | .answer wait | .hang wait =>
      return wait
    | .again =>
      continue
    | .block since =>
      waitBlocked "running work"
      if host.activity.tracked then
        discard <| awaitAnyWithin (← deadline.rest) [← host.activity.changedSince since, thread]
      else
        -- No count to wait on: what the wait is for is looked at again,
        -- every millisecond, as the progress changes, until the guard. A
        -- poll, because the window mode keeps no count (follow-up
        -- window-mode-waits-poll-progress).
        repeat
          if (← IO.hasFinished host.thread) || !(← kind.busy (← host.progress.get)) then
            break
          if ← deadline.expired then
            break
          RealTime.sleep untrackedPoll
  return .ended

/-- A `settle`'s wait (`waitWhile` of `Wait.Kind.settle`): until the editor
thread has handled everything sent so far, no reload is running and no
restore is in flight; `settled` at the reload's end, or `reloading`, a
hang, at its guard `waitGuard`. The editor thread's answer is guarded by
`answer`. -/
def await (host : Host) (waitGuard : HangGuard) (answer : HangGuard := waitGuard)
    (line : Option Nat := none) (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Wait :=
  host.waitWhile waitGuard .settle answer line waitHung waitBlocked

/-- `join` is an inferred wait (`Editor/InferredWait.lean`). -/
def join.inferredWait : InferredWait :=
  .idle [`Editor.Headless.Wait, `Editor.Test.Linked.Host]

/-- A `join`'s wait (`waitWhile` of `Wait.Kind.join`): until the editor
thread has handled everything sent so far and no job is running; `settled`,
`working` once the host is idle with a job still running, or `busy`, a
hang, at its guard `waitGuard`. -/
def join (host : Host) (waitGuard : HangGuard) (answer : HangGuard := waitGuard)
    (line : Option Nat := none) (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Wait :=
  host.waitWhile waitGuard .join answer line waitHung waitBlocked

/-- Waits until the editor thread has handled everything sent so far and no
reload is running (`await`); `false` if it did not, a hang said at its
guard `waitGuard`, or the editor thread's answer's, `answer`. -/
def settle (host : Host) (waitGuard : HangGuard) (answer : HangGuard := waitGuard)
    (line : Option Nat := none) (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Bool :=
  return (← host.await waitGuard answer line waitHung waitBlocked) == .settled

/-- Ends the loop at once, whether a reload is running or not; `false` if it
has not ended within `guard`, waited on for the loop's task itself
(`Job.awaitWithin`): a hang guard, never a result. Throws the error
the loop ended with, if it ended with one. Inside a host's bracket
(`withHost`), which ends the loop whatever this answered. -/
def halt (host : Host) (guard : HangGuard) : IO Bool := do
  unless ← IO.hasFinished host.thread do
    host.post .stop
  let some ended ← Job.awaitWithin guard host.thread | return false
  IO.ofExcept ended
  return true

/-- Ends the loop once no reload is running; `false` if it did not settle or
did not end, each within `guard`. A loop that had ended by
itself, because a command quit the editor, has nothing to settle. Inside a
host's bracket (`withHost`), which ends the loop whatever this answered. -/
def stop (host : Host) (guard : HangGuard) : IO Bool := do
  let wait ← host.await guard
  let ended ← host.halt guard
  return (wait == .settled || wait == .ended) && ended

end Host

/-- A host as the script runner drives it, whichever kind it is: a real one,
whose loop runs on a thread of its own (`Driven.ofHost`), or one stepped on
its driver's thread (`Driven.ofStepped`, `Editor/Headless/Stepped.lean`).
The runner's port (`runOn`): each field is a closure over the host, so the
runner, and a check written on it, runs on either.

It grows by data: a new thing the runner asks of its host is a field, made
by `over` and by each host's maker. Only `over` makes one, so the private
wait is never handed a kind of wait from outside this module: a driver
waits through the named waits below (`await`, `join`, `handled`), and those
that infer "done" from the host's idle are marked (`linter.inferredWait`).
A check fakes it by hand with `over`. -/
structure Driven where private mk ::
  /-- Asks the host to do a request, after everything asked before. -/
  send : Request → IO Unit
  /-- Sends an event as the window would report it. -/
  input : Event → IO Unit
  /-- The host's `waitWhile` (`Host.waitWhile`, `Stepped.waitWhile`): its
  guard, the kind of wait (`Wait.Kind`), the answer's guard, the script's
  line, where a hang is said, and what is called before a block. What each
  kind waits for is the core's, never this record's. -/
  private waitWhile :
    HangGuard →
      Wait.Kind → HangGuard → Option Nat → (String → IO Unit) → (String → IO Unit) → IO Wait
  /-- How far the host's loop has got, as it published after its last
  event, and the plan of the restart it ended for, once it has ended for one
  (`Progress.handOver`). -/
  progress : IO Progress
  /-- How the host's loop ended, once it has: `ok` for a loop that stopped
  by itself or was stopped, or the error it threw. -/
  ended? : IO (Option (Except IO.Error Unit))
  /-- The fake clock the host's jobs wait on, if they wait on one. -/
  clock : Option Job.FakeClock
  /-- What a `restarted` waits on: the loop's end, within the guard, and
  how it ended; `none` when it has not ended, after saying the hang through
  the action handed in, when a guard ran out (a real host's), or at once
  when nothing left can end it (a stepped host's over its fakes). -/
  awaitEnd : HangGuard → IO Unit → IO (Option (Except IO.Error Unit))

namespace Driven

/-- A driven host made of its closures: what a host's maker, and a check's
hand-written fake, build one with. -/
def over (send : Request → IO Unit) (input : Event → IO Unit)
    (waitWhile :
      HangGuard →
        Wait.Kind → HangGuard → Option Nat → (String → IO Unit) → (String → IO Unit) → IO Wait)
    (progress : IO Progress) (ended? : IO (Option (Except IO.Error Unit)))
    (clock : Option Job.FakeClock)
    (awaitEnd : HangGuard → IO Unit → IO (Option (Except IO.Error Unit))) : Driven :=
  ⟨send, input, waitWhile, progress, ended?, clock, awaitEnd⟩

/-- A real host, driven: its requests and the library's window input
(`Event.post`) onto the editor queue, its waits (`Host.waitWhile`), and its
loop's task for its end. -/
def ofHost (host : Host) : Driven :=
  over host.send
    (fun event => do
      unless ← Event.post event do
        throw (IO.userError "the editor queue refused an event: it has been quit"))
    (fun guard kind answer line waitHung waitBlocked =>
      host.waitWhile guard kind answer line waitHung waitBlocked)
    host.progress.get
    (do
      if ← IO.hasFinished host.thread then
        return some host.thread.get
      return none)
    host.clock fun guard hang => do
    let ended ← Job.awaitWithin guard host.thread
    if ended.isNone then
      hang
    return ended

/-- Sends a press of `key`, with no text, as the window would report it. -/
def press (driven : Driven) (key : Key) : IO Unit :=
  driven.input (.key key true "")

/-- Sends `text` as an input method's composition would end with it. -/
def commit (driven : Driven) (text : String) : IO Unit :=
  driven.input (.commit text)

/-- Sends a resize of the frame to `width` by `height` physical pixels, at a
scale of 1 and out of fullscreen. -/
def resize (driven : Driven) (width height : Nat) : IO Unit :=
  driven.input (.resize { width, height, scale := 1.0 })

/-- A `settle`'s wait on the driven host (`Wait.Kind.settle`). -/
def await (driven : Driven) (waitGuard : HangGuard) (answer : HangGuard := waitGuard)
    (line : Option Nat := none) (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Wait :=
  driven.waitWhile waitGuard .settle answer line waitHung waitBlocked

/-- `join` is an inferred wait (`Editor/InferredWait.lean`). -/
def join.inferredWait : InferredWait :=
  .idle [`Editor.Headless.Stepped, `Editor.Test.Linked.Host]

/-- A `join`'s wait on the driven host (`Wait.Kind.join`). -/
def join (driven : Driven) (waitGuard : HangGuard) (answer : HangGuard := waitGuard)
    (line : Option Nat := none) (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Wait :=
  driven.waitWhile waitGuard .join answer line waitHung waitBlocked

/-- Whether a `settle`'s wait on the driven host settled (`await`). -/
def settle (driven : Driven) (waitGuard : HangGuard) (answer : HangGuard := waitGuard)
    (line : Option Nat := none) (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Bool :=
  return (← driven.await waitGuard answer line waitHung waitBlocked) == .settled

/-- A wait only until the host has handled everything sent so far
(`Wait.Kind.handled`), publishing nothing. -/
def handled (driven : Driven) (waitGuard : HangGuard) (answer : HangGuard := waitGuard)
    (line : Option Nat := none) (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Wait :=
  driven.waitWhile waitGuard .handled answer line waitHung waitBlocked

end Driven

/-- The guard of the journal's drain, a flush of the file service; only a
stuck file system reaches it, and the end then quits the queues without it.
How long a host's end waits for the drain before it quits the queues: a
guard, never a result. -/
def drainPatience : HangGuard :=
  .on "the journal's drain" 2000

/-- The guard of the event each `settle`, `join`, `advance`, `indexed`,
`journalled` and `restarted` ends on, and the loop's stop; only a hang
reaches it, and the run then fails as a hang (`Host.waitWhile`). The
headless mode's guard of each. -/
def settlePatience : HangGuard :=
  .on "the event the script's wait ends on" 30000

/-- What a host's bracket says when its loop has not ended `guard`
milliseconds after it was asked to stop: a hang, once, never a result. -/
def hangLine (guard : Nat) : String :=
  s!"editor: a hang: the editor loop had not ended {guard} ms after it was asked to stop; waiting for it"

/-- The guard of the loop's end, after its hang was said; only a loop that
never ends reaches it, and the run then gives up as a hang. How long the
headless mode waits, after it has said a hang, for its loop to end before
it gives up and exits 1: a guard so that CI and fixtures never hang, never
a result. -/
def hangGrace : HangGuard :=
  .on "the loop's end, after its hang was said" 5000

/-- Asks `host`'s loop to stop, unless it has ended, and waits for its task;
says what the loop ended with. A loop not ended within `guard` after it was
asked is said through `hung` as a hang (`hangLine`), once, and still waited
for: with no deadline when `grace` is `none`, and otherwise within `grace`
more, after which the loop's task is handed to
`abandoned` and this answers `none`, the loop still running. The stop is
posted only when the queue takes it: a queue already quit (`Ffi.quit`) ends
the loop with its quit event. -/
private def endLoop (host : Host) (guard : HangGuard) (grace : Option HangGuard)
    (hung : String → IO Unit) (abandoned : Task (Except IO.Error Unit) → IO Unit) :
    IO (Option (Except IO.Error Unit)) := do
  unless ← IO.hasFinished host.thread do
    try
      host.post .stop
    catch _ =>
      pure ()
  if (← Job.awaitWithin guard host.thread).isNone then
    hung (hangLine guard.ms)
    if let some grace := grace then
      if (← Job.awaitWithin grace host.thread).isNone then
        abandoned host.thread
        return none
  return some (← IO.wait host.thread)

/-- `withHostEnding`'s end, with a bound for the headless mode: as
`withHostEnding`, but when `grace` is given and the loop has still not
ended within `grace` after the hang was said, hands the loop's task to
`abandoned` and answers `none` with the loop still running. With `grace :=
none` it never answers `none`. -/
private def hostedWithin {α β σ : Type} {scheme : InputScheme}
    (collaborators : Collaborators β σ scheme) (body : Host → IO α) (guard : HangGuard)
    (grace : Option HangGuard) (hung : String → IO Unit)
    (abandoned : Task (Except IO.Error Unit) → IO Unit) : IO (Option (α × Except IO.Error Unit)) :=
  do
  let host ← start collaborators
  let result ←
    try
      body host
    catch error =>
      discard <| endLoop host guard grace hung abandoned
      throw error
  return (← endLoop host guard grace hung abandoned).map (result, ·)

/-- The mark of `withHostEnding`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def withHostEnding.realHost : RealHost :=
  .loop

/-- Runs `body` against a host started on `collaborators`, and returns only
once the host's loop has ended, whether `body` returned or threw: a loop
still running is asked to stop (`Signal.stop`), and its task is waited for
with no deadline. A loop that has not ended within `guard` after it was
asked is said through `hung` as a hang, once, and still waited for: the
guard reports a hang, it never ends the wait, unless `grace` is given: a
loop still running at the end of `grace` after the hang was said is handed
to `abandoned`, and this throws a hang (`a hang: the editor loop had not
ended …; giving up`), as a check's bracket does (ConfigTest's `onStage`),
so a suite always finishes. When `body` threw, its error is the one thrown,
once the loop has ended. With what `body` returned, the
result the loop ended with, for a caller that says a loop's error itself:
the window mode, whose exit status says it (`Window.host`). `withHost`
throws it. -/
def withHostEnding {α β σ : Type} {scheme : InputScheme} (collaborators : Collaborators β σ scheme)
    (body : Host → IO α) (guard : HangGuard := settlePatience)
    (hung : String → IO Unit := IO.eprintln) (grace : Option HangGuard := none)
    (abandoned : Task (Except IO.Error Unit) → IO Unit := fun _ => pure ()) :
    IO (α × Except IO.Error Unit) := do
  match ← hostedWithin collaborators body guard grace hung abandoned with
  | some ended =>
    return ended
  | none =>
    -- Only with a grace: without one the loop is waited for until it ends.
    throw <|
        IO.userError
          s!"a hang: the editor loop had not ended {(grace.map (·.ms)).getD 0} ms after the hang was said ({guard.ms} ms after it was asked to stop); giving up"

/-- The mark of `withHost`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def withHost.realHost : RealHost :=
  .loop

/-- Runs `body` against a host started on `collaborators`, and returns only
once the host's loop has ended, whether `body` returned or threw, as
`withHostEnding` does. When `body` returned and the loop ended with an error,
that error is thrown, as `Host.halt` throws it; when `body` threw, its error
is the one thrown. The way to have a host: a host's loop never outlives its
bracket, and `Host.halt`, `Host.stop` and the waits inside `body` answer
what they answer, the bracket ends the loop whatever they did. -/
def withHost {α β σ : Type} {scheme : InputScheme} (collaborators : Collaborators β σ scheme)
    (body : Host → IO α) (guard : HangGuard := settlePatience)
    (hung : String → IO Unit := IO.eprintln) (grace : Option HangGuard := none)
    (abandoned : Task (Except IO.Error Unit) → IO Unit := fun _ => pure ()) : IO α := do
  let (result, ended) ← withHostEnding collaborators body guard hung grace abandoned
  IO.ofExcept ended
  return result

/-- One line of a script. -/
inductive Directive where
  /-- Ask the editor thread for this. -/
  | request (request : Request)
  /-- Wait until the editor thread has handled everything asked so far and no
  reload is running. This one is the driver's own. -/
  | settle
  /-- Settle as `settle` does, for at most this many milliseconds in place of
  the run's patience: for a reload known to be slow, such as a cold one. The
  driver's own. -/
  | settleWithin (milliseconds : Nat)
  /-- Wait until the editor thread has handled everything asked so far and no
  job is running, or until the host is idle with a job still running, which
  fails the run as `working` (`Host.join`): a hang only past this many
  seconds, or the driver's guard (`settlePatience`) with none (`join
  <seconds>`, for a script that waits on a package-set build). The driver's
  own, too. -/
  | join (seconds : Option Nat := none)
  /-- Send a press of this key, with no text, as the window would. -/
  | key (key : Key)
  /-- Send this text, as an input method's composition would end with it. -/
  | commit (text : String)
  /-- Send a resize of the frame to this many physical pixels across and
  down, as the window would. -/
  | resize (width height : Nat)
  /-- Wait until the editor thread has handled everything sent so far and
  the render loop is at rest, then until the editor thread has answered once
  more with nothing sent and the loop has rested again, and print how many
  frames it drew and how many were submitted between the two rests: what a
  loop left alone was asked, fixed by events, never by a window of time. The
  driver's own. -/
  | idle
  /-- Settle, wait until the render loop is at rest, and print how many
  frames it presented since the last `journal`, with their latencies. The
  driver's own. -/
  | journal
  /-- Wait until the host's fake clock holds a wait due within this many
  milliseconds, then move the clock on by them, completing every wait then
  due. A host found idle with none due stalls the run (`Failure.stalled`);
  only past the driver's guard is it a hang. The driver's own; it sends
  nothing to the editor thread that shows: its rounds post probes. -/
  | advance (milliseconds : Nat)
  /-- Settle, then wait until the file service has worked every request
  handed to it, the session journal's orders among them. The driver's
  own. -/
  | journalled
  /-- Settle, then wait until the session index is written: no write or
  save of it running, none pending, no job running but those the script
  spawned, and the file service holding no request. On a fake clock it
  moves the clock past a write's delay once no other job is running, so
  what they change is in the one write, and a write a finished job started
  is written too. It needs no `join`, so a script
  with a long job of its own running can wait for the index. The driver's
  own. It waits at most this many seconds for the index, or the driver's
  patience with none (`indexed <seconds>`, for a package-set build, a job
  that is not the script's own). -/
  | indexed (seconds : Option Nat := none)
  /-- End the process at once, with the status 134 and no shutdown, as an
  abort would: what the journal handed the system survives it. The
  driver's own. -/
  | abort
  /-- Wait until the loop has ended for a restart (`Progress.handOver`): the
  script stops in this process, and the next run, started with
  `--resume`, goes on after this line ("Restarting", in the module docs).
  The driver's own. It waits at most this many seconds, or the driver's
  patience with none (`restarted <seconds>`, for a restart a package-set
  build starts). -/
  | restarted (seconds : Option Nat := none)
  /-- Settle as `settle` does, then fail the run (`Failure.notInstalled`)
  unless the last reload that finished installed its config: a rejected
  reload, or none finished, ends the script here with status 1, where it
  would otherwise be something to print. The driver's own. -/
  | installed
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

/-- The resize a `resize` directive's line names after its keyword: a width
and a height, two numbers of physical pixels. -/
def resizeDirective? (line : String) : Except String Directive :=
  let problem := s!"`{line}` is not a resize: expected resize <width> <height>, two numbers"
  match ((line.drop 6).trimAscii.toString.splitOn " ").filter (!·.isEmpty) with
  | [width, height] =>
    match width.toNat?, height.toNat? with
    | some width, some height => .ok (.resize width height)
    | _, _ => .error problem
  | _ => .error problem

/-- The settle a `settle` directive's line is: `settle`, which waits the
run's patience, or `settle <milliseconds>`, which waits that many
milliseconds in its place. -/
def settleDirective? (line : String) : Except String Directive :=
  match named line 6 with
  | none => .ok .settle
  | some given =>
    match given.toNat? with
    | some milliseconds => .ok (.settleWithin milliseconds)
    | none =>
      .error s!"`{line}` is not a settle: expected settle, or settle <milliseconds>, one number"

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
        if line == "settle" || line.startsWith "settle " then some <$> settleDirective? line
        else
          if line == "join" || line.startsWith "join " then
            match named line 4 with
            | none => .ok (some (.join none))
            | some text =>
              match text.toNat? with
              | some seconds => .ok (some (.join (some seconds)))
              | none => .error s!"`{line}` is not a join: expected join [<seconds>], one number"
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
                    if line == "published" then .ok (some (.request .published))
                    else
                      if line == "commit" || line.startsWith "commit " then
                        match named line 6 with
                        | none => .error s!"`{line}` commits no text"
                        | some text => .ok (some (.commit text))
                      else
                        if line == "resize" || line.startsWith "resize " then
                          some <$> resizeDirective? line
                        else
                          if line == "agree" then .ok (some (.request .agree))
                          else
                            if line == "journal" then .ok (some .journal)
                            else
                              if line == "journalled" then .ok (some .journalled)
                              else
                                if line == "indexed" || line.startsWith "indexed " then
                                  match named line 7 with
                                  | none => .ok (some (.indexed none))
                                  | some text =>
                                    match text.toNat? with
                                    | some seconds => .ok (some (.indexed (some seconds)))
                                    | none =>
                                      .error
                                        s!"`{line}` is not an indexed: expected indexed [<seconds>], one number"
                                else
                                  if line == "workspaces" then .ok (some (.request .workspaces))
                                  else
                                    if line == "abort" then .ok (some .abort)
                                    else
                                      if line == "installed" then .ok (some .installed)
                                      else
                                        if line == "restarted" || line.startsWith "restarted " then
                                          match named line 9 with
                                          | none => .ok (some (.restarted none))
                                          | some text =>
                                            match text.toNat? with
                                            | some seconds => .ok (some (.restarted (some seconds)))
                                            | none =>
                                              .error
                                                s!"`{line}` is not a restarted: expected restarted [<seconds>], one number"
                                        else
                                          if line == "idle" then .ok (some .idle)
                                          else
                                            if line.startsWith "idle " then
                                              .error
                                                s!"`{line}` is not an idle: expected idle, with nothing after it: it waits until the host and the render loop are at rest, never for a time"
                                            else
                                              if
                                                  line == "advance" ||
                                                    line.startsWith "advance " then
                                                match (named line 7).bind String.toNat? with
                                                | some milliseconds =>
                                                  .ok (some (.advance milliseconds))
                                                | none =>
                                                  .error
                                                    s!"`{line}` is not an advance: expected advance <milliseconds>, one number"
                                              else
                                                .error
                                                  s!"`{line}` is not a directive: expected reload, run <name>, spawn <name>, show, workspaces, scene, published, agree, settle, settle <milliseconds>, join [<seconds>], idle, advance <milliseconds>, journal, journalled, indexed [<seconds>], installed, abort, restarted [<seconds>], key <logical> <physical> <modifiers>, commit <text> or resize <width> <height>"

/-- A directive of a script, and the line it is on. -/
structure Line where
  /-- The line's number in the script, from 1. -/
  number : Nat
  /-- What the line says. -/
  directive : Directive
  deriving DecidableEq, Repr

/-- `script` as a run started with `--resume <resume>` runs it: from the line
after its `resume`-th `restarted`, or whole for 0 ("Restarting", in the
module docs). -/
def resumed (script : Array Line) (resume : Nat) : Array Line :=
  if resume == 0 then script
  else
    let (_, kept) :=
      script.foldl
        (fun (passed, kept) line =>
          if passed ≥ resume then (passed, kept.push line)
          else if line.directive matches .restarted _ then (passed + 1, kept) else (passed, kept))
        (0, #[])
    kept

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
`settle` or the `join` that failed, or `none` for the wait at the end of the
script, before the loop is stopped. `reloading`, `unanswered` and `busy` are
hangs: a wait reached its guard (`Host.waitWhile`). `working` and `stalled`
are not: a wait found the host idle, so nothing would have changed however
long it waited. -/
inductive Failure where
  /-- A hang: a wait reached its guard with a reload still running. -/
  | reloading (line : Option Nat)
  /-- A `join`, or an `indexed`, found the host idle with a job still
  running. -/
  | working (line : Option Nat)
  /-- A hang: the editor thread did not answer: a wait reached its guard
  before it had handled everything sent to it, with no line the wait at the
  script's end. -/
  | unanswered (line : Option Nat)
  /-- The `advance` on `line` of `milliseconds` found the host idle with no
  wait due within them on the clock. -/
  | stalled (line : Nat) (milliseconds : Nat)
  /-- The `advance` on `line` ran on a host whose clock is real. -/
  | noClock (line : Nat)
  /-- The `restarted` on `line` found the loop not ended for a restart within
  the patience. -/
  | notRestarted (line : Nat)
  /-- The `installed` on `line` settled and found that the last reload that
  finished did not install its config: it was rejected, or none had
  finished. -/
  | notInstalled (line : Nat)
  /-- The loop had not ended `grace` milliseconds after the hang was said,
  itself `guard` milliseconds after the run stopped it: the headless mode
  gave up on it (`runFrom`'s `grace`). -/
  | hung (guard grace : Nat)
  /-- A wait that had its own patience of `milliseconds`, a
  `settle <milliseconds>`, or a `join`, `indexed` or `restarted` with its
  seconds, failed so. -/
  | waited (milliseconds : Nat) (failure : Failure)
  /-- A hang: the `join` or `advance` on `line`, or the wait at the script's
  end, reached its guard with the host not idle: work was still running
  that could end what it waited for. -/
  | busy (line : Option Nat)
  deriving DecidableEq, Repr

/-- What an `advance` on a host whose clock is real says. -/
def advanceNeedsClock : String :=
  "advance needs the headless mode's fake clock"

/-- What went wrong, for the user: `patience` is how long each wait was, in
milliseconds, but for a wait that had its own (`waited`). -/
def Failure.describe (patience : Nat) : Failure → String
  | .reloading (some line) =>
    s!"a hang: the settle on line {line} of the script did not finish within {patience} ms: a reload was still running. A file or `setup` of the config is slow, or does not end"
  | .reloading none =>
    s!"a hang: the script ended, and the reload it had asked for did not finish within {patience} ms. A file or `setup` of the config is slow, or does not end"
  | .working (some line) =>
    s!"the join or indexed on line {line} of the script found the editor idle with a job still running: nothing left to run could end it. A job of the config waits on something the script does not do (a sleep on the clock no advance moves)"
  | .working none =>
    "the script ended, and found the editor idle with a job it had started still running: nothing left to run could end it. A job of the config waits on something the script does not do (a sleep on the clock no advance moves)"
  | .unanswered (some line) =>
    s!"a hang: the settle or join on line {line} of the script did not finish within {patience} ms: the editor thread had not handled everything sent to it. It is still inside a command or another event, or it has ended"
  | .unanswered none =>
    s!"a hang: the script ended, and the editor thread had not handled everything sent to it within {patience} ms"
  | .stalled line milliseconds =>
    s!"the advance on line {line} found the editor idle with no wait due within {milliseconds} ms on the clock"
  | .noClock line => s!"the advance on line {line}: {advanceNeedsClock}"
  | .notRestarted line =>
    s!"the restarted on line {line} of the script found no restart within {patience} ms: the loop did not end with the session handed over"
  | .notInstalled line =>
    s!"the installed on line {line} of the script found the config not installed: the last reload was rejected, or none had finished"
  | .hung guard grace =>
    s!"the editor loop had not ended {grace} ms after the hang was said ({guard} ms after the script stopped it); giving up"
  | .waited milliseconds failure => failure.describe milliseconds
  | .busy (some line) =>
    s!"a hang: the join or advance on line {line} of the script did not finish within {patience} ms: work was still running that could end it. A job of the config is slow, or does not end"
  | .busy none =>
    s!"a hang: the script ended, and work it had started was still running after {patience} ms. A job of the config is slow, or does not end"

/-- The failure a wait that did not settle is, at `line` of the script. -/
def Wait.failure (line : Option Nat) : Wait → Option Failure
  | .settled => none
  | .reloading => some (.reloading line)
  | .working => some (.working line)
  | .unanswered => some (.unanswered line)
  | .ended => none
  | .busy => some (.busy line)

/-- `failure`, of a wait whose patience of `milliseconds` ran out, as the
run describes it with its own `patience` (`Failure.describe`): as it is
when the two agree, and otherwise with the patience that ran out
(`waited`). -/
def Failure.ranOut (milliseconds patience : Nat) (failure : Failure) : Failure :=
  if milliseconds == patience then failure else .waited milliseconds failure

/-- `failure`, of a wait bounded by milliseconds of its `own` (an
`indexed <seconds>` or a `restarted <seconds>`), `waited` them; of a wait
bounded by the run's patience (`none`), as it is. -/
def Failure.ownedBy (own : Option Nat) (failure : Failure) : Failure :=
  match own with
  | some milliseconds => .waited milliseconds failure
  | none => failure

/-- The failure a wait of a run whose patience is `patience` and whose
answer patience is `answer` (`runFrom`) came to, at `line` of the script.
A wait with milliseconds of its `own`, a `settle <milliseconds>` or a
`join <seconds>`, is bounded by them alone, its answer too, so any failure
of it is `waited` them (`Failure.ownedBy`). Of any
other wait, the editor thread's not answering ran out `answer`, and a reload
or a job still running ran out `patience`. -/
def Wait.failureIn (wait : Wait) (line : Option Nat) (patience answer : Nat)
    (own : Option Nat := none) : Option Failure :=
  match own, wait with
  | some milliseconds, _ => (wait.failure line).map (Failure.ownedBy (some milliseconds))
  | none, .unanswered => some (Failure.ranOut answer patience (.unanswered line))
  | none, _ => wait.failure line

/-- Waits until `render`'s loop is at rest, on the step that records the rest
(`Render.awaitRest`); `false` if it is not within `guard`, a hang guard: only
a loop that never rests reaches it. -/
def rested (render : Render) (guard : HangGuard) : IO Bool :=
  return (← render.awaitRest guard) == some true

/-- The serial of the newest entry of `render`'s journal, 0 for none. -/
def newestSerial (render : Render) : IO UInt64 := do
  return (((← render.journal 0).getD #[]).back?.map (·.serial)).getD 0

/-- Where an `idle` starts counting: once `render`'s loop is at rest
(`rested`; a loop that does not rest is `idled`'s to say), the serial of the
newest entry of its journal and its counters; none with no render loop, or
no session yet. At rest nothing is scheduled to draw, so what is counted
from here is what was asked after it. -/
def idleStart (render : Option Render) (guard : HangGuard) :
    IO (Option (UInt64 × Ffi.RenderCounters)) := do
  let some render := render | return none
  discard <| rested render guard
  let some counters ← render.counters | return none
  return some (← newestSerial render, counters)

/-- What `idle` prints, once the editor thread has answered again with
nothing sent: it waits until the render loop is at rest (`rested`, on the
step that records the rest), then counts what the loop drew (journal
entries) and what was submitted to it (its counters) since `start`
(`idleStart`), the loop's rest before that answer. Both ends are rests, so
the count is what the editor asked of a loop left alone, fixed by events:
no window of time decides it. With no render loop it says so. -/
def idled (render : Option Render) (guard : HangGuard)
    (start : Option (UInt64 × Ffi.RenderCounters)) : IO String := do
  let some render := render | return "idle: no render loop"
  unless ← rested render guard do
    return s!"idle: the render loop did not come to rest within {guard.ms} ms"
  let some now ← render.counters | return "idle: no render loop"
  -- A session that started after the directive began: all of it is since.
  let (last, before) := start.getD (0, { now with framesSubmitted := 0 })
  let drawn := ((← render.journal last).getD #[]).size
  let submitted := now.framesSubmitted - before.framesSubmitted
  return s!"idle: {drawn} frames drawn, {submitted} frames submitted"

/-- What `journal` prints of `entries`, the frames presented since the last
`journal` line: how many, and the median, the 99th percentile (nearest
rank) and the largest of their `present − input`, in microseconds, by the
window report's rule (`Window.Report.summary`), and how many rows they
built. -/
def journalLine (journal : Array Ffi.JournalEntry) : String :=
  let rebuilt := journal.foldl (fun sum entry => sum + entry.rowsRebuilt.toNat) 0
  let entries :=
    journal.map fun entry =>
      ({ inputNs := entry.inputNs.toNat, presentNs := entry.presentNs.toNat } : Window.Report.Entry)
  let first := (entries[0]?.map (·.presentNs)).getD 0
  let summary := Window.Report.summary first ((entries.back?.map (·.presentNs)).getD first) entries
  s!"journal: {summary.frames} frames presented, present - input median {summary.median} us, p99 {summary.p99} us, max {summary.max} us, {rebuilt} rows rebuilt"

/-- What `journal` prints, once the editor thread has settled: it waits
until the render loop is at rest, then reads the journal's entries after
`after`, the serial the last `journal` line counted to (`journalLine`). With
it the serial it counted to now. With no render loop it says so. -/
def journalSince (render : Option Render) (guard : HangGuard) (after : UInt64) :
    IO (String × UInt64) := do
  let some render := render | return ("journal: no render loop", after)
  unless ← rested render guard do
    return (s!"journal: the render loop did not come to rest within {guard.ms} ms", after)
  let entries := (← render.journal after).getD #[]
  return (journalLine entries, (entries.back?.map (·.serial)).getD after)

/-- The status `abort` ends the process with: 128 and SIGABRT's 6, as a
shell reports an abort, without raising the signal, which on a macOS desktop
brings up the crash reporter. -/
def abortStatus : UInt8 :=
  134

/-- What a script's run comes to (`runOn`): why it could not run to its end,
if it could not, and the plan of the restart a `restarted` found, if one
did. -/
abbrev Ran : Type :=
  Option Failure × Option Restart.Plan

/-- Where a run's host comes from: a bracket over the collaborators that
makes a host, hands its driver (`Driven`) to the body, and returns once the
host's loop has ended, with what the body returned and how the loop ended;
or the failure the run is when the bracket gave up on a loop that did not
end. A real host's (`Hosting.real`) or a stepped one's
(`Stepped.hosting`, `Editor/Headless/Stepped.lean`): the runner is written
on neither. -/
structure Hosting (β σ : Type) (scheme : InputScheme) where
  /-- The bracket. -/
  hosted :
    Collaborators β σ scheme → (Driven → IO Ran) → IO (Except Failure (Ran × Except IO.Error Unit))

/-- The mark of `Hosting.real`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def Hosting.real.realHost : RealHost :=
  .loop

/-- A real host's bracket (`hostedWithin`, driven by `Driven.ofHost`): a
loop not ended within `guard` after the run stopped it is said through
`hung` as a hang, once, and waited for, with no deadline when `grace` is
`none`, and otherwise within `grace` more, after which its task is handed
to `abandoned` and the run fails as `Failure.hung`. -/
def Hosting.real {β σ : Type} {scheme : InputScheme} (guard : HangGuard) (grace : Option HangGuard)
    (hung : String → IO Unit) (abandoned : Task (Except IO.Error Unit) → IO Unit) :
    Hosting β σ scheme
    where
  hosted collaborators body := do
    match
      ←
        hostedWithin collaborators (fun host => body (Driven.ofHost host)) guard grace hung
            abandoned with
    | some ran =>
      return .ok ran
    | none =>
      return .error (.hung guard.ms ((grace.map (·.ms)).getD 0))

/-- What `abort` does in the headless mode: ends the process at once, with
the status `abortStatus` and no shutdown, its output flushed. -/
def abortProcess : IO Unit := do
  (← IO.getStdout).flush
  IO.Process.exit abortStatus

/-- The driver's part of a run (`runOn`): runs `script` against the host
`driven` drives, from after its `resume`-th `restarted`, and says why it
could not run to its end, or the plan of the restart a `restarted` found.
It reaches the host only through `driven`, so it runs on either host. Its
`abort` calls `onAbort`; a script whose `onAbort` returns stops there. It
never stops the loop: the bracket it runs in does. -/
private def runScript {β σ : Type} {scheme : InputScheme} (collaborators : Collaborators β σ scheme)
    (driven : Driven) (script : Array Line) (waitGuard : HangGuard) (resume : Nat)
    (answer : HangGuard) (waitHung : String → IO Unit) (waitBlocked : String → IO Unit)
    (onAbort : IO Unit) : IO Ran := do
  -- The waits of the script, each said with its line when it hangs.
  let await (line : Nat) (guard : HangGuard := waitGuard) (answer : HangGuard := answer) :
    IO Wait := driven.await guard answer (some line) waitHung waitBlocked
  let join (line : Nat) (guard : HangGuard := waitGuard) (answer : HangGuard := answer) : IO Wait :=
    driven.join guard answer (some line) waitHung waitBlocked
  -- With a state directory, the session is restored first: the index a
  -- restart handed over, when there is one.
  if collaborators.stateDirectory.isSome then
    driven.send (.restore collaborators.launch.restore)
  let script := resumed script resume
  -- The serial of the last journal entry a `journal` line counted.
  let mut journaled : UInt64 := 0
  for line in script do
    -- A command quit the editor: the lines after it are not run.
    if (← driven.ended?).isSome then
      break
    let wait ←
      match line.directive with
      | .request request =>
        driven.send request
        continue
      | .key key =>
        driven.press key
        continue
      | .commit text =>
        driven.commit text
        continue
      | .resize width height =>
        driven.resize width height
        continue
      | .settle =>
        await line.number
      | .settleWithin milliseconds =>
        -- Its own milliseconds guard it, the editor thread's answer too; its
        -- failure says how long it waited, not the run's guard.
        let own := HangGuard.on "the settle" milliseconds
        let wait ← await line.number own own
        if let some failure :=
            wait.failureIn (some line.number) waitGuard.ms answer.ms (own := some milliseconds) then
          return (some failure, none)
        pure wait
      | .join none =>
        join line.number
      | .join (some seconds) =>
        -- As a `settle <milliseconds>`: its own seconds guard it, the
        -- editor thread's answer too, and its failure says how long.
        let milliseconds := seconds * 1000
        let own := HangGuard.on "the join" milliseconds
        let wait ← join line.number own own
        if let some failure :=
            wait.failureIn (some line.number) waitGuard.ms answer.ms (own := some milliseconds) then
          return (some failure, none)
        pure wait
      | .idle =>
        -- Everything sent so far handled, publishing nothing, and the
        -- render loop at rest (`idleStart`); then the editor thread answers
        -- once more with nothing sent, and what the loop drew and was handed
        -- from that rest to the next is counted (`idled`).
        let wait ←
          driven.waitWhile waitGuard .handled answer (some line.number) waitHung waitBlocked
        if wait == .settled then
          let start ← idleStart collaborators.render waitGuard
          let again ←
            driven.waitWhile waitGuard .handled answer (some line.number) waitHung waitBlocked
          if again == .settled then
            collaborators.emit (← idled collaborators.render waitGuard start)
          pure again
        else
          pure wait
      | .journal =>
        let wait ← await line.number
        if wait == .settled then
          let (said, last) ← journalSince collaborators.render waitGuard journaled
          journaled := last
          collaborators.emit said
        pure wait
      | .journalled =>
        let wait ← await line.number
        if wait == .settled then
          -- The drain is a flush of the file service: bounded by `waitGuard`
          -- only as a guard against a stuck file system.
          let drained ← Job.awaitWithin waitGuard (← collaborators.journal.drained)
          unless drained == some true do
            return (some (.unanswered (some line.number)), none)
        pure wait
      | .indexed seconds =>
        let wait ← await line.number
        if wait == .settled then
          -- The index's write is bounded by the line's own seconds, if it
          -- gives them, and its failure then says how long it waited.
          let own := seconds.map (· * 1000)
          let guard := (own.map (HangGuard.on "the index's write" ·)).getD waitGuard
          let answerGuard := (own.map (HangGuard.on "the index's write" ·)).getD answer
          -- Each round ends on an event or at idle (`awaitIndexed`): a write
          -- in its sleep has the clock moved past its delay, and a host idle
          -- with the index still not written fails the run.
          let index ←
            awaitIndexed
                (fun kind =>
                  driven.waitWhile guard kind answerGuard (some line.number) waitHung waitBlocked)
                driven.progress driven.clock
          if index == .working then
            return (some (Failure.ownedBy own (.working (some line.number))), none)
          let written := index == .settled
          -- Then what the journal handed the file service is worked: a flush,
          -- bounded by the line's own seconds only as a hang guard.
          let drained ←
            if written then
              Job.awaitWithin guard (← collaborators.journal.drained)
            else
              pure none
          unless drained == some true do
            return (some (Failure.ownedBy own (.unanswered (some line.number))), none)
        pure wait
      | .installed =>
        let wait ← await line.number
        if wait == .settled && (← driven.progress).installed != some true then
          return (some (.notInstalled line.number), none)
        pure wait
      | .abort =>
        -- The headless mode's ends the process (`abortProcess`); one that
        -- returns stops the script here.
        onAbort
        return (none, none)
      | .restarted seconds =>
        -- The loop ends by itself once it has handed the session over: its
        -- task is waited for, guarded by the line's own seconds if it gives
        -- them, and a failure then says how long it waited.
        let own := seconds.map (· * 1000)
        let guard := (own.map (HangGuard.on "the restart" ·)).getD waitGuard
        let ended ←
          driven.awaitEnd guard (waitHung (waitHangLine "restarted" (some line.number) guard))
        let plan := (← driven.progress).handOver
        match ended, plan with
        | some ended, some plan =>
          IO.ofExcept ended
          return (none, some plan)
        | _, _ =>
          return (some (Failure.ownedBy own (.notRestarted line.number)), none)
      | .advance milliseconds =>
        let some clock := driven.clock | return (some (.noClock line.number), none)
        -- Only once a wait is due within the move: so a job that is about
        -- to sleep is in its sleep before the clock moves past it. A wait
        -- already due moves it at once, with no marker; otherwise the wait
        -- is the driver's, and the host found idle with none due is a
        -- stall.
        if ← clock.dueWithin milliseconds then
          clock.advance milliseconds
          continue
        let wait ←
          driven.waitWhile waitGuard (.advance clock milliseconds) answer (some line.number)
              waitHung waitBlocked
        match wait with
        | .settled =>
          clock.advance milliseconds
          continue
        | .working =>
          return (some (.stalled line.number milliseconds), none)
        | other =>
          pure other
    if wait == .ended then
      break
    if let some failure := wait.failureIn (some line.number) waitGuard.ms answer.ms then
      return (some failure, none)
  -- The end of the script: wait for a reload that is still running. The
  -- bracket the script runs in then stops the loop and waits for it to end.
  let last ← driven.await waitGuard answer none waitHung waitBlocked
  return (last.failureIn none waitGuard.ms answer.ms, none)

/-- Runs `script` against a host of `hosting`'s (`Hosting`), as its driver,
through the host's port alone (`Driven`), and returns once the host's loop
has ended: what `runFrom` says of a run, over either host. A loop that
ended with an error has it thrown. `abort` calls `onAbort`, which in the
headless mode ends the process (`abortProcess`); a harness hands one that
throws, since it cannot end its process. -/
def runOn {β σ : Type} {scheme : InputScheme} (hosting : Hosting β σ scheme)
    (collaborators : Collaborators β σ scheme) (script : Array Line) (waitGuard : HangGuard)
    (resume : Nat := 0) (answer : HangGuard := waitGuard)
    (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) (onAbort : IO Unit := abortProcess) :
    IO Ran := do
  let hosted ←
    hosting.hosted collaborators fun driven =>
        runScript collaborators driven script waitGuard resume answer waitHung waitBlocked onAbort
  match hosted with
  | .ok (result, ended) =>
    -- The loop's error is thrown, as `Host.halt` throws it.
    IO.ofExcept ended
    return result
  | .error failure =>
    return (some failure, none)

/-- The mark of `runFrom`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def runFrom.realHost : RealHost :=
  .loop

/-- Runs `script` against a host of its own, in its bracket (`withHost`), as
its driver: sends each request in order and waits at each `settle` and each
`join`, and returns once the loop has ended. `none` when the script ran to
its end, or a command quit the editor before it, and otherwise why it could
not: a reload or a job did not end within `patience` milliseconds, or the
editor thread did not answer within `answer` (`Wait.failureIn`), or the run
gave up on a loop that did not end (`hung`, below). With it, the plan of
the restart the loop ended for, when a `restarted` found one: the script
stops there ("Restarting", in the module docs). A run started with
`--resume <resume>` runs the script from after its `resume`-th `restarted`
(`resumed`).

Once the loop has ended by itself, because a command quit the editor, the
lines that are left are not run: the script is read no further at a wait
that answered `ended`, and before each line when the loop's task has
finished.

A `settle` or a `join` that runs out ends the script, and the bracket ends
the loop at once, whether a reload or a job is running or not. A loop that
ended with an error has it thrown, as `Host.halt` throws it. A rejected reload is something to print, not a
failure, and so is a job that fails. A job the script leaves running is
cancelled when the loop ends.

Every wait of the run is on an event (`Host.waitWhile`), and two guards
bound them, each only against a hang. `waitGuard` bounds what a wait is for:
a reload or a job ending, an `advance`'s wait coming due, a `restarted`'s
hand-over. `answer`, `waitGuard` unless it is given, bounds what should
happen at once: the editor thread's answer to a wait. A `join` that finds
the host idle with a job still running answers `working`, and an `advance`
that finds it idle with nothing due a stall, at once: neither is a guard's
outcome. At either guard the wait says the hang once through `waitHung`
(`waitHangLine`, in its guard's words), and the run fails, as
`reloading`, `unanswered` or `busy`, each a hang; a `restarted` whose guard
runs out before the loop ends says its hang the same way, and fails as
`notRestarted`. `waitBlocked` is the waits' hook for a test, called
as a wait is about to block (`Host.waitWhile`).

The wait guards are named apart from the loop's end, which `guard`,
`hung`, `grace` and `abandoned` bound: a loop not ended within `guard`
(`answer` unless it is given) after the run stopped it is said through
`hung` as a hang, once, and waited for. With `grace := none`, the default,
the wait has no deadline; with `some grace`, which the headless mode gives
(`main`), a loop still running at the end of `grace` after the hang was
said is handed to `abandoned`, so a check can wait for it, and the
run fails as `Failure.hung`, beside the live loop.

A `settle <milliseconds>` or a `join <seconds>` guards its whole wait, the
answer too, by its own milliseconds alone; an `indexed <seconds>` guards
the index's write and a `restarted <seconds>` the hand-over by theirs, in
place of `waitGuard`. A failure of a wait with its own guard is `waited`
it. The headless mode passes one guard for both (`settlePatience`); a check
passes its hang guard (`Editor.Test.Linked.hangGuard`), or, to pin a bound of the
headless mode, a short one with a reload or the editor thread held for
good; a check that holds the loop's end gives a guard of 0 ms held for good, so
that the hang, said at once, is what lets it go. -/
def runFrom {β σ : Type} {scheme : InputScheme} (collaborators : Collaborators β σ scheme)
    (script : Array Line) (waitGuard : HangGuard) (resume : Nat := 0)
    (answer : HangGuard := waitGuard) (guard : HangGuard := answer)
    (grace : Option HangGuard := none) (hung : String → IO Unit := IO.eprintln)
    (abandoned : Task (Except IO.Error Unit) → IO Unit := fun _ => pure ())
    (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO Ran :=
  runOn (Hosting.real guard grace hung abandoned) collaborators script waitGuard resume answer
    waitHung waitBlocked

/-- The mark of `run`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def run.realHost : RealHost :=
  .loop

/-- Runs `script` against a host of its own, as `runFrom` does from its
start, with the same patiences, guard and grace, and says only why it could
not run to its end. -/
def run {β σ : Type} {scheme : InputScheme} (collaborators : Collaborators β σ scheme)
    (script : Array Line) (waitGuard : HangGuard) (answer : HangGuard := waitGuard)
    (guard : HangGuard := answer) (grace : Option HangGuard := none)
    (hung : String → IO Unit := IO.eprintln)
    (abandoned : Task (Except IO.Error Unit) → IO Unit := fun _ => pure ())
    (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) : IO (Option Failure) :=
  (·.1) <$>
    runFrom collaborators script waitGuard 0 answer guard grace hung abandoned waitHung waitBlocked

/-- Runs `script` against a host of `hosting`'s, as `runOn` does, and then,
the host's loop having ended, removes what the collaborators left outside
the process (`Collaborators.dispose`): once, whether the run returned or
threw. A dispose that throws is ignored, so it neither hides the run's
failure nor replaces it. `runAndDispose` is this over a real host; a check
runs it over a stepped one (`Stepped.hosting`). -/
def runOnAndDispose {β σ : Type} {scheme : InputScheme} (hosting : Hosting β σ scheme)
    (collaborators : Collaborators β σ scheme) (script : Array Line) (waitGuard : HangGuard)
    (resume : Nat := 0) (answer : HangGuard := waitGuard)
    (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) (onAbort : IO Unit := abortProcess) :
    IO Ran := do
  try
    runOn hosting collaborators script waitGuard resume answer waitHung waitBlocked onAbort
  finally
    try
      collaborators.dispose
    catch _ =>
      pure ()

/-- The mark of `runAndDispose`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def runAndDispose.realHost : RealHost :=
  .loop

/-- Runs `script` against a host of its own, as `runFrom` does, and then, the
host's loop having ended, removes what the collaborators left outside the
process (`Collaborators.dispose`, `runOnAndDispose`): once, whether the run returned or threw.
With `grace := none`, the default, the loop has always ended by then
(`runFrom`), so nothing is disposed of under a live loop. Only when the
headless mode gives up on a hung loop (`grace := some hangGrace`,
`Failure.hung`) is it disposed beside the live loop, just before the process
exits. A dispose that throws is ignored, so it neither hides the run's
failure nor replaces it. What the headless mode runs (`main`). -/
def runAndDispose {β σ : Type} {scheme : InputScheme} (collaborators : Collaborators β σ scheme)
    (script : Array Line) (waitGuard : HangGuard) (resume : Nat := 0)
    (answer : HangGuard := waitGuard) (guard : HangGuard := answer)
    (grace : Option HangGuard := none) (hung : String → IO Unit := IO.eprintln)
    (abandoned : Task (Except IO.Error Unit) → IO Unit := fun _ => pure ())
    (waitHung : String → IO Unit := IO.eprintln)
    (waitBlocked : String → IO Unit := fun _ => pure ()) :
    IO (Option Failure × Option Restart.Plan) :=
  runOnAndDispose (Hosting.real guard grace hung abandoned) collaborators script waitGuard resume
    answer waitHung waitBlocked

/-- The guard of each warming task's start, run out on purpose: it passes
only when the pool is smaller than the machine, and warming then stops
there, changing no result. How long warming the pool waits for each of its
tasks to start. A task starts in microseconds; this long passes only when the pool
is smaller than the machine, because `LEAN_NUM_THREADS` says so. -/
def warmPatience : HangGuard :=
  .held "a warming task a full pool does not start" 200

/-- The display the headless mode draws with under `--render`: the real
binding over a display of the library's in `cells`, bound to the library's
presenter (`Ffi.Display.present`), so every scene it publishes reaches the
render session, over the snapshots `snapshots` reads. -/
def drawnDisplay (snapshots : SnapshotReader) : IO Host.Display := do
  let display ← Ffi.Display.newCells cells.advance.toUInt64 cells.lineHeight.toUInt64
  display.present
  Host.Display.real (← RealDisplay.over display snapshots Theme.builtin)

/-- The package port over the config directory `configDir`
(`Config.PackageFiles`): its files read by name, a lakefile's requires and
its `[[require]]` tables read with Lake's TOML loader, and another
directory's `lakefile.toml` read the same way. Its directory is
`configDir` as given and it knows no shipped set; a host that knows them
sets the absolute directory and the set's name (`packageFilesAt`). -/
def packageFilesOver (configDir : String) : Config.PackageFiles :=
  { read := Config.Directory.read configDir, requires := Config.Lakefile.Toml.requires
    requireEntries := Config.Lakefile.Toml.requireEntries, directory := configDir
    setRequires := fun directory => do
      try
        Config.Lakefile.Toml.requireEntries (← IO.FS.readFile (directory ++ "/lakefile.toml"))
      catch error =>
        return .error ((toString error).splitOn "\n" |>.headD "") }

/-- The package port over `configDir` as an executable host makes it, at
the edge: `packageFilesOver`, with the directory made absolute (the real
path, or as given when it cannot be resolved) and `setName`, the shipped
set's Lake name. -/
def packageFilesAt (configDir : String) (setName : Option String) : IO Config.PackageFiles := do
  let directory ←
    try
      pure (← IO.FS.realPath configDir).toString
    catch _ =>
      pure configDir
  return { packageFilesOver configDir with
      directory, setName }

/-- The collaborators the executable's hosts are made of, over the jobs'
`services`, the table of snapshots `published` and what jobs hold `held`:
`packages` as the packages the host registers, the real elaborator over the
toolchain in `sysroot` and the editor's `.olean` files in the directories
`oleans`, searched in order, the config directory `configDir` as the
source, `emit` as the output and stderr as the log. Config is elaborated on
`base`, the modules it names: the base of the caller's package set
(`Editor/Main.lean`, "The base"), or `Editor` alone, the core's, for a
caller with no set. Each module of it must be linked into the executable
and found in `oleans`. It is an argument every caller writes, with no
default: a host that fell back to `Editor` without a word would reject
config that names a package's declarations. Its input scheme is `scheme`,
which is the host's type: the executable passes the one its package set
supplies (`Editor/Main.lean`, "The input scheme"). Its
display is the recorder and its clipboard its own, as a host's are by
default.

It names no package: the executable passes the packages of its package
set, and what those register is said in each package's module.

It is apart from `shipped`, which makes what it is over, so that the
collaborators can be made with no pump started. -/
def shippedOver (scheme : InputScheme) (packages : Array Package) (base : Array Lean.Name)
    (sysroot : String) (oleans : List String) (configDir : String) (emit : String → IO Unit)
    (services : Job.Services) (published : Snapshots) (held : Job.HeldSnapshots)
    (files : Config.Elaborate.ModuleFiles) (stateDirectory : Option System.FilePath := none) :
    Collaborators Config.Elaborate.Base Config.Elaborate.Handle scheme :=
  { elaborator :=
      Config.Elaborate.elaborator
        { sysroot, oleanDirs := oleans.map System.FilePath.mk, imports := base } files,
    source := Config.Directory.source configDir, package := packageFilesOver configDir, emit,
    services, published, held, requests := 1, wakeups := 2, jobs := 3, environment := 4, posts := 5,
    pauseEvents := 6, packages, stateDirectory, log := IO.eprintln, tracksIdle := true
    journal := Journal.real published.reader services
    dispose := files.remove }

/-- The environments every job of a host shares, over `state`
(`Job.sharedEnvironments`), which report what they have to say by posting it
to the editor queue `queue`, the library's unless a stepped host's is
handed, under the Lean source id `source`: the host's editor
thread then says it in the echo area (`Collaborators.environment`). -/
def reportedEnvironments (state : IO.Ref Process.Environments) (source : UInt64)
    (queue : Queue := Queue.library) : Job.Environments :=
  Job.sharedEnvironments state fun text => discard <| queue.post { source, code := 0, text }

/-- The package services the packages `packages` bring (`Package.services`),
by name: the edge where a package's real adapters meet the runner.
`shipped` gives its runner these, and a package's linked test gives the
runner of its checks over its crate the same (echo's,
`EchoTest/Linked/Echo/Real/Job.lean`), so a package that stops bringing its
service, or an edge that stops handing the packages' services on, fails
there. -/
def packageServices (packages : Array Package) : Job.PackageServices :=
  Job.PackageServices.of (packages.flatMap (·.services))

/-- The mark of `shipped`: it runs a real background service (`Editor/RealHost.lean`). -/
def shipped.realHost : RealHost :=
  .service

/-- The collaborators the executable's hosts are made of, the headless
mode's and the window mode's, which run the input scheme `scheme`, with
`packages` as the packages the host
registers: `shippedOver` the library's timer service,
file service, process service, watch service and diff service for the
jobs, the library's matcher (`Fuzzy.real`), which the loop's match jobs ask,
the environments they share for the mode `host` (`reportedEnvironments`),
and the services the packages bring (`packageServices`). Config is elaborated on `base`, which every caller names (`shippedOver`).

Making them warms the pool, so the first burst of jobs finds every thread
made, and starts the completion pump on a dedicated task, which quitting the
queues ends. -/
def shipped (scheme : InputScheme) (packages : Array Package) (base : Array Lean.Name)
    (sysroot : String) (oleans : List String) (configDir : String) (emit : String → IO Unit)
    (host : Process.Host) (fakeClock : Bool := false)
    (stateDirectory : Option System.FilePath := none) :
    IO (Collaborators Config.Elaborate.Base Config.Elaborate.Handle scheme) := do
  discard <| Job.Pool.warm Job.Pool.size warmPatience
  let completions ← Job.Completions.new
  discard <| IO.asTask (prio := .dedicated) (Job.pump completions)
  -- The published table and what jobs hold are made before the services:
  -- the file service reads the one and keeps its loads in the other.
  let published ← Snapshots.new
  let held ← Job.HeldSnapshots.new
  let refused ← Job.RefusedRuns.new
  let timed ← Job.TimedRuns.new
  let watches ← Job.RealWatches.new
  let refusedDiffs ← Job.RefusedDiffs.new
  let greps ← Job.RealGreps.new
  -- The headless mode's clock is fake: a script moves it (`advance`).
  let clock ←
    if fakeClock then
      some <$> Job.FakeClock.new completions
    else
      pure none
  let timers := (clock.map (·.timers)).getD (Job.realTimers completions)
  let environments ← IO.mkRef ({ host } : Process.Environments)
  -- The module data of the config files under `Config/` goes in a
  -- temporary directory, made when the first is written.
  let files ← Config.Elaborate.ModuleFiles.temporary
  let collaborators :=
    shippedOver scheme packages base sysroot oleans configDir emit
      { completions, timers
        files := Job.realFiles completions published.reader held
        processes := Job.realProcesses completions refused timers timed
        fileWatches := Job.realFileWatches completions watches
        diffs := Job.realDiffs completions published.reader held refusedDiffs
        greps := Job.realGreps completions published.reader held greps
        environments := reportedEnvironments environments 4 Queue.library, fuzzy := Fuzzy.real
        snapshots := Job.realSnapshots published.reader
        packages := packageServices packages } published held files stateDirectory
  return { collaborators with clock }

/-- What generates the lakefile and the toolchain file of the config
directory `configDir`, for the editor at `appPath` that the build says
`origin` of: files are created in that directory, never overwritten
(`Config.Directory.create`); the pin is the build's; and the package set is
the build's name for it at the directory the editor finds for itself, with
the directory of its core (`ModuleLookup.setDirectory?`,
`ModuleLookup.coreDirectory?`, with the real file read and directory
test), or none when it finds either not, and then no lakefile is written. Both
executable hosts make theirs with it, at the edge. -/
def generatorAt (origin : Config.LakePackage.Origin) (appPath : String) (configDir : String) :
    IO Config.Generator := do
  let readFile (path : System.FilePath) : IO (Option String) := do
    try
      return some (← IO.FS.readFile path)
    catch _ =>
      return none
  let isDirectory (path : System.FilePath) : IO Bool := do
    try
      path.isDir
    catch _ =>
      return false
  let directory ← ModuleLookup.setDirectory? appPath readFile isDirectory
  let core ← ModuleLookup.coreDirectory? appPath readFile isDirectory
  return {
      create := Config.Directory.create configDir, pin := origin.pin
      set := origin.set directory core }

/-- What the executable at `appPath`, built as `origin` says, knows of its
own package set (`PackageSet.at`), read at the edge with the real file
read and test of existence: its records, the set directory and the core
directory it finds for itself (`ModuleLookup.setDirectory?`,
`ModuleLookup.coreDirectory?`), the config directory `configDir`
made absolute, the toolchain directory `sysroot` and the data directory
`data`. Both executable hosts read theirs with it. -/
def runningAt (origin : Config.LakePackage.Origin) (appPath : String) (configDir : String)
    (sysroot data : Option String) : IO PackageSet.Running := do
  let readFile (path : String) : IO (Option String) := do
    try
      return some (← IO.FS.readFile path)
    catch _ =>
      return none
  let isDirectory (path : System.FilePath) : IO Bool := do
    try
      path.isDir
    catch _ =>
      return false
  let directory ←
    ModuleLookup.setDirectory? appPath (fun path => readFile path.toString) isDirectory
  let coreDirectory ←
    ModuleLookup.coreDirectory? appPath (fun path => readFile path.toString) isDirectory
  let config ←
    try
      pure (← IO.FS.realPath configDir).toString
    catch _ =>
      pure configDir
  PackageSet.at appPath config (directory.map (origin.setName, ·)) coreDirectory sysroot data
      readFile fun path => System.FilePath.pathExists path

/-- The mark of `main`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def main.realHost : RealHost :=
  .loop

/-- The headless mode of the executable, handed the input scheme its host
runs, the packages its host
registers, the base config is elaborated on (`Editor/Main.lean`, "The
base") and the command line after
`headless`: `editor headless [--render] [--generate] [<sysroot> <olean dir>]
<config dir> <script file>`, read by `Headless.read` (`Editor/Headless/CommandLine.lean`).
Registers `packages`, in order, loads the config in `configDir` with the real elaborator,
runs the script as `run` does, with the output on stdout, then shuts the
library's process service down, which kills and reaps every child it
started, quits the queues and exits explicitly: with status 0 when the script ran to its end or
a command quit the editor before it, and with 1 when it could not, after
saying why on stderr (the script cannot be read, a wait ran out with a
reload or a job still running, or the editor thread did not answer). Any
other command line is status 2, with the usage on stderr after the reason,
if there is one beyond the number of paths: two paths outside a bundle say
there is no toolchain.

A run the launcher handed a record (`--handed-over`) and that ends without
handing the session on removes that record before it exits, if its
hand-shake has not (`Restart.Launch.removedAtEnd`): its script ended
before its restore's hand-shake, and a run that ends by itself is no
failed start, so the launcher's watcher must start no fallback.

Before the loop starts it warms the pool, so the first burst of jobs finds
every thread made, and starts the completion pump on a dedicated task. The
host's jobs wait on the library's timer service and its file service, which
reads the snapshots the loop publishes.

**`--generate`** lets the headless mode write into the config directory:
before anything is elaborated, a reload creates the `lakefile.toml` and the
`lean-toolchain` the directory lacks (`generatorAt`,
`Editor/Config/LakePackage.lean`). Without it nothing is written there,
and the lakefile is only read.

**`--render`** draws what the host publishes: the library's headless
render session is started (`Ffi.renderHeadless`), a render loop over the
CPU renderer at each scene's size and a scale of 1, and the host's display
is the real binding over a display of the library's in `cells`, bound to
it (`drawnDisplay`), in place of the recorder. The script's `agree`, `idle`
and `journal` read that display's frame and that loop. The session is
stopped before the queues are quit.

The Lean toolchain's directory and the directories holding the `.olean`
files of the base's modules are the first two of four paths, the second a
search path whose directories are followed by the ones the build recorded
for the executable, or, with two, the bundle's, resolved from the
executable's path; `main` reads that path and the record at the edge
(`IO.appPath`, `ModuleLookup.recorded` with the real file read;
`Editor/ModuleLookup.lean`). Nothing is read from the environment. The working directory is read once, at the edge, as the
editor's (`Collaborators.workingDirectory`): where `:!` runs for a buffer
with neither a workspace nor a file; no path of the command line is read
against it. -/
def main (scheme : InputScheme) (packages : Array Package) (base : Array Lean.Name)
    (origin : Config.LakePackage.Origin) (launch : Restart.Launch) (arguments : List String) :
    IO UInt32 := do
  let appPath := (← IO.appPath).toString
  -- The record the build wrote beside the executable, read at the edge: a
  -- record that is not there, or cannot be read, names no directory.
  let readFile (path : System.FilePath) : IO (Option String) := do
    try
      return some (← IO.FS.readFile path)
    catch _ =>
      return none
  let recorded ← ModuleLookup.recorded appPath readFile
  let
    { render := drawn, generate, sysroot, oleans, config := configDir, script := scriptPath, state,
      resume, data }
    ←
    match read appPath arguments recorded (launch.shipped.map (·.toString)) with
    | .ok read =>
      pure read
    | .error reason =>
      unless reason.isEmpty do
        IO.eprintln s!"editor: {reason}"
      IO.eprintln s!"usage: editor {usage}"
      return 2
  -- A cold start under the launcher's watch with no state directory: its
  -- start is its hand-shake.
  if let some record := launch.removedAtStart (stateDirectory := state.isSome) then
    try
      IO.FS.removeFile record
    catch _ =>
      pure ()
  let directives ←
    try
      let text ← IO.FS.readFile scriptPath
      IO.ofExcept ((script text).mapError IO.userError)
    catch error =>
      IO.eprintln s!"editor: cannot run the script {scriptPath}: {error}"
      return 1
  if drawn then
    if let .error reason← Ffi.renderHeadless then
      IO.eprintln s!"editor: the headless render session could not be started: {reason}"
      return 1
  let shipped ←
    shipped scheme packages base sysroot oleans configDir IO.println .headless (fakeClock := true)
        (stateDirectory := state.map System.FilePath.mk)
  let workingDirectory ← IO.currentDir
  -- Only with `--generate` may the headless mode write into the config
  -- directory: then it creates the lakefile and the toolchain file the
  -- directory lacks, as the window mode does.
  let generator ←
    if generate then
      some <$> generatorAt origin appPath configDir
    else
      pure none
  -- The loop has ended when `runAndDispose` returns, so no reload is
  -- elaborating: the directory of the config files' module data goes with
  -- it, if one was made.
  -- A restart hands the next run this command line, its `--resume` one
  -- more than this run's.
  let launch := { launch with arguments := "headless" :: handedOn arguments resume }
  let packageSet ←
    runningAt origin appPath configDir (if sysroot.isEmpty then none else some sysroot) data
  let package ← packageFilesAt configDir packageSet.setName
  let collaborators :=
    { shipped with
      generator, workingDirectory, launch, replace := Restart.real, packageSet, package
      display :=
        if drawn then drawnDisplay else fun snapshots => Host.Display.recorder cells snapshots
      render := if drawn then some Render.library else none }
  -- The run returns once its loop has ended, but for a loop still running
  -- `hangGrace` after its hang was said: the run then gives up, as `hung`,
  -- so the process exits 1 and never hangs.
  let (failure, handOver) ←
    runAndDispose collaborators directives settlePatience resume (grace := some hangGrace)
  if let some plan := handOver then
    IO.println
        s!"restart: the session is handed over{if plan.launcher.isSome then "" else " (no launcher, so no fallback)"}"
  (← IO.getStdout).flush
  if let some failure := failure then
    IO.eprintln s!"editor: {failure.describe settlePatience.ms}"
  if drawn then
    discard Ffi.renderStop
  -- Every child the library started is killed and reaped before the queues
  -- are quit: `run` has returned, so the loop has cancelled every job,
  -- unless the run gave up on it, and the process then exits 1.
  Ffi.processesShutdown
  -- And every watch is ended, and every search.
  Ffi.watchesShutdown
  Ffi.grepShutdown
  -- And what the journal handed the file service is written: a flush of the
  -- service, waited for at most `drainPatience`, on purpose real time, so
  -- that quitting does not hang on a stuck file system.
  discard <| Job.awaitWithin drainPatience (← collaborators.journal.drained)
  -- Shutdown: quit lets every task parked in a pull return, the pump among
  -- them, and the exit is explicit, because a task may still be blocked in
  -- the library.
  Ffi.quit
  -- A run that ended by itself removes the record it was handed, if its
  -- hand-shake has not, so its watcher starts no fallback.
  if let some record := launch.removedAtEnd (handedOn := handOver.isSome) then
    try
      IO.FS.removeFile record
    catch _ =>
      pure ()
  -- A restart's exec, once everything is shut down, through the
  -- collaborators' exec: it returns only when it failed, said.
  if let some plan := handOver then
    IO.Process.exit (← plan.exec collaborators.replace IO.eprintln).toUInt8
  IO.Process.exit (if failure.isNone then 0 else 1)

end Editor.Headless
