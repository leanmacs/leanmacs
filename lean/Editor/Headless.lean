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
import Editor.InputScheme.Vim.Default
import Editor.Job.Fake
import Editor.Job.Jobs
import Editor.Job.Pool
import Editor.Job.Real
import Editor.Loop
import Editor.SyntaxTree.Real
import Editor.Text.Real
import Editor.Watch.Real
import Editor.Window

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
  package (`tools/host-imports-check.sh`). A host handed none starts with
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
    those of the core's Lake package (`EditorCore.EditorPackage.packages`,
    `EditorCore/EditorPackage.lean`), then those of each package of the
    set, which the executable's generated root passes through
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
  step's own. The driver's `stop` publishes nothing.
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
  lookup once for a directory, is posted under the Lean source id
  `Collaborators.environment`, and said in the echo area for the next scene
  (`Running.said`). A reload that installs asks it to `install` config's
  setting, `auto` when config sets none, which drops every directory's
  cached environment. Pinned by `ConfigTest.environmentHostChecks`.
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
once for each path, in the echo area and to the log (`journalFailed`). A
host's end waits, at most `drainPatience`, until the service holds no
request. The script's `journalled` waits until it holds none; `abort` ends
the process at once with the status 134 and no shutdown
(`IO.Process.exit`): not the signal, which on a macOS desktop raises the
crash reporter.

## One loop at a time

The editor queue is process-wide, so two live loops would take each other's
events: hosts in one process follow one another and never overlap. A host
posts under source ids it is given, and its loop ignores an event from a
Lean source it was not given, so a late event from an earlier host is
dropped. `stop` ends this loop only; quitting the queues is for the process
(`Ffi.quit`).

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
scene <w>x<h>, focused <id or ->, echo <quoted>, echo padding <n>, preedit <quoted or ->, published <n>, theme <quoted name>
view <id> <x>,<y> <w>x<h>: <quoted text>, scroll <offset>, selections <anchor>..<head> …, padding <across> <down>
status <view id>: <face> <quoted text>, …   (or "-" for no field)
hint <key>: binding <quoted description or ->
hint <key>: prefix <quoted name or -> <count>
                          (a key that can follow the pending keymap prefix)
scene: none               (no scene has been published)
loop: refused: <error>    (a program of the editor loop was refused)
agree view <id>: <n> rows asked from <anchor>, <m> in the frame: agrees
                          (or "…: disagrees: asked <rows>, frame <rows>",
                           "agree view <id>: no rows query from <anchor>",
                           or "agree: no frame" with no display that lays
                           out frames)
idle <ms>: <d> frames drawn, <s> frames submitted
                          (or "idle <ms>: no render loop")
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
`journal` are the driver's: once the editor thread has settled, each waits
until the render loop is at rest (`Render.resting`). Then `idle` counts the
journal's new entries and the counters' frames submitted over the period,
and `journal` the entries since the last `journal` line, with their
`present − input` (nearest rank). `journal`'s numbers vary between runs, so
it is for measuring, never for a fixture.

The `scene`, `view` and `status` lines answer `scene`: the last scene
published, with how many scenes have been and the name of the theme it was
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
and takes no job id (`Running.delayHints`). `idle <milliseconds>` still waits real
time, for the render loop. The window mode passes no clock and keeps the
library's timers.

## The driver, and the command line

A host is driven from another thread: `Host.send` posts a request,
`Host.settle` waits, with a bound, until the editor thread has handled
everything sent so far and no reload is running, `Host.join` waits the same
way until no job is running, and `Host.stop` ends the loop. Requests are
handled in the order they were sent, and a request sent while a reload runs
is handled before that reload is installed: settle first to see its effect.

Two requests are the window mode's (`Editor/Window/Real.lean`), which
drives a host with no script: `open <path>` runs the open command with the
path, printed as `run open-file: …`, and `say <text>` says the text in the
echo area (`Running.said`). No script directive sends them.

`run` drives a host through a script, one directive a line: `reload`,
`run <name>`, `spawn <name>`, `show`, `scene` and `agree` are requests, and
`settle`, `join`, `idle <milliseconds>`, `journal`,
`key <logical> <physical> <modifiers>`, `commit <text>` and
`resize <width> <height>` are the driver's own. A `key` is sent with
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
`editor headless [--render] [--generate] [<sysroot> <olean dir>] <config dir>
<script file>`, handed the command line after `headless`, which `Headless.read` reads
(`Editor/Headless/CommandLine.lean`): the toolchain's directory and the
editor's `.olean` directory are given, or, from an executable in an app
bundle, are the bundle's (`Editor/ModuleLookup.lean`). It is `run`
with the packages `main` is handed, the real elaborator, a directory as the
source, stdout as the output, and the library's timer service and file
service for the jobs, then the quit and the explicit exit. Before the loop starts it warms the pool (`Editor/Job/Pool.lean`) and
starts the completion pump on a dedicated task (`Editor/Job/Real.lean`),
which the quit ends. Its exit status is 0 when the script ran to its end, or
a command quit the editor before it, and
1 when it could not, and then it says why on stderr: the script cannot be
read, a wait ran out (after 30 seconds) with a reload or a job still
running, or the editor thread did not answer. A rejected reload is something
to print, not a failure, and so is a job that fails. A command line it does
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
(`ConfigTest.hostChecks`, `ConfigTest.threadChecks`), checks jobs on a fake
clock it moves, with the thread each line was emitted from
(`ConfigTest.jobChecks`), and checks the script reader and the driver
(`ConfigTest.scriptChecks`). Two of those are the loop's refusals: a scene
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
One more runs the executable with `--render` on milestone 1's fixture
(`tests/headless/milestone`), in a temporary directory in the same way: an
evil session on a source file ending in `:w`, checked by the file's bytes,
`agree` after `C-f` and after the save, and `idle 1000`, which must find
nothing drawn and nothing submitted over the second after the session
settled. `ConfigTest.scriptChecks` check that `agree`, `idle` and `journal`
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
  /-- Run the open command (`Files.openName`) with the path `path`: the
  window mode's first request when it was given a file. -/
  | «open» (path : String)
  /-- Say `text` in the echo area (`Running.said`): what the window mode has
  to say before the first event. -/
  | say (text : String)
  /-- Restore the session of the state directory (`Collaborators.stateDirectory`):
  start the job `restore`, and hold the requests that follow until it has
  finished ("Restoring a session", in the module docs). -/
  | restore
  deriving DecidableEq, Repr

/-- The render loop a host's frames are drawn by, as its driver reads it:
the latest render session's (`Ffi.renderResting`, `Ffi.renderJournal`,
`Ffi.renderCounters`). Each answers `none` when no session has started. -/
structure Render where
  /-- Whether the loop is at rest. -/
  resting : IO (Option Bool)
  /-- The journal's entries after a serial, oldest first. -/
  journal : UInt64 → IO (Option (Array Ffi.JournalEntry))
  /-- The loop's counters. -/
  counters : IO (Option Ffi.RenderCounters)

/-- The library's render session: the one `editor headless --render`
starts. -/
def Render.library : Render :=
  { resting := Ffi.renderResting, journal := Ffi.renderJournal, counters := Ffi.renderCounters }

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

/-- How a host hands the session journal's orders to its file service
(`Loop.Stepped.journal`, `Editor/Restore.lean`), and reads back what failed.
The default does nothing, for a host with no file service. -/
structure Journal where
  /-- Hands one order to the file service, unobserved: nothing waits on it. -/
  perform : Restore.Order → IO Unit := fun _ => pure ()
  /-- Takes what failed of the orders handed so far, each a path and why,
  oldest first, once. -/
  failures : IO (Array (String × String)) := pure #[]
  /-- How many requests the file service has waiting or being worked: 0 once
  every order handed is written. -/
  pending : IO Nat := pure 0

/-- The journal over the library's file service: each order an unobserved
request (`Ffi.filesAppendUnobserved`, `Ffi.filesRemoveUnobserved`,
`Ffi.filesSaveUnobserved` of the snapshot `published` holds), its failures
taken with `Ffi.filesFailure`. -/
def Journal.real (published : SnapshotReader) : Journal where
  perform order := do
    match order.request with
    | .append path bytes =>
      discard <| Ffi.filesAppendUnobserved path.toString bytes
    | .remove path =>
      discard <| Ffi.filesRemoveUnobserved path.toString
    | .save (.snapshot id) path _ =>
      if let some snapshot← published.find? id then
        discard <| Ffi.filesSaveUnobserved snapshot path.toString
    | _ =>
      pure ()
  failures := do
    let mut taken := #[]
    repeat
      let some failure ← Ffi.filesFailure | break
      taken := taken.push failure
    return taken
  pending := return (← Ffi.filesPending).toNat

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
  of its package set, the core's first
  (`EditorCore/EditorPackage.lean`). -/
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
  /-- Removes what the collaborators left outside the process: the real
  ones' directory of the config files' module data, if a config with
  files under `Config/` had it made (`Editor/Config/Elaborate.lean`,
  "Module files"). The executable's edges call it once, when the host has
  ended; the default removes nothing. -/
  dispose : IO Unit := pure ()

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
  | .request .agree => (7, "")
  | .request (.open path) => (8, path)
  | .request (.say text) => (9, text)
  | .request .restore => (10, "")

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
  | 10 => some (.request .restore)
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
    report.unknownStyles.map (fun name => s!"style: {Completion.Styles.unknown name}") ++
    report.unknownDisplays.map (fun name => s!"display: {Completion.Displays.unknown name}") ++
    report.unknownAtPoints.map (fun name => s!"at-point: {Completion.AtPoint.unknown name}") ++
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
  /-- How many markers the loop has reached. -/
  markers : Nat := 0
  /-- Whether the driver has ended the loop. -/
  stopped : Bool := false
  /-- What the host has to say in the echo area once the frame is made: a
  reload's error said before there was a frame (`said`). -/
  unsaid : Option String := none
  /-- The jobs started with a key, by their key: the id each runs as
  (`JobStart.key`). -/
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
  /-- The paths whose journal failures were said: each is said once. -/
  journalSaid : Array String := #[]

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

/-- The reload job, on a thread of its own: builds the config, hands the
outcome over through `promise`, and wakes the editor thread with an event.
The wake-up is posted whatever happens, so the editor thread never waits for
a job that is gone. -/
def reloadJob (collaborators : Collaborators β σ scheme) (base : Option β)
    (files : Array (Config.LoadedFile σ)) (promise : IO.Promise (Config.Outcome β σ)) : IO Unit :=
  do
  try
    promise.resolve
        (←
          Config.build scheme collaborators.elaborator collaborators.source collaborators.package
              collaborators.generator base files)
  finally
    discard <| Ffi.postEvent .editor collaborators.wakeups 0 ""

/-- Feeds `event` to the reload reducer and performs its effects. A reload
job is started on a dedicated task, never run here: it reads files and
elaborates, and the editor thread goes on to its next event. A reload's
report is printed, and a rejected one's error is said in the echo area
(`Config.Report.echo`, `said`); one that installs says nothing there, and
hands the display the new theme (`Config.retheme`). -/
def reduce (collaborators : Collaborators β σ scheme) (running : Running β σ scheme)
    (event : Config.Event β σ) : IO (Running β σ scheme) := do
  let (config, effects) := Config.step running.config event
  Config.retheme running.display.setTheme config effects
  -- A reload that installs is config's setting of a child's environment,
  -- and drops every directory's cached one.
  if Config.installed effects then
    collaborators.services.environments.ask (.install (config.registry.environment.getD .auto))
  let mut running := { running with config }
  for effect in effects do
    match effect with
    | .report report =>
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
      discard <| IO.asTask (prio := .dedicated) (reloadJob collaborators base files promise)
      running := { running with job := some promise }
    | .themed =>
      -- `retheme` above has handed the display the theme.
      pure ()
    | .appearance appearance =>
      discard <| running.display.handle (.frame (.appearance appearance))
  return running

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
  { running with job := none }.reduce collaborators (.finished outcome)

/-- Starts `work` as a job of `owner` called `name`: its id, and the jobs with
it. It runs on the pool; its posts wait in the mailbox, and when it has
ended the runner posts a wake-up to the editor queue, with the job's id.
How a registered job is started (`startJob`) and how the loop's own work is
(`Loop.Spawn`, `launch`). -/
def startWork (collaborators : Collaborators β σ scheme) (running : Running β σ scheme)
    (owner : Config.Owner) (name : String) (work : Work) : IO (Nat × Running β σ scheme) := do
  let wake (id : Nat) : BaseIO Unit :=
    (discard <| Ffi.postEvent .editor collaborators.jobs id.toUInt64 "" : IO Unit).catchExceptions
      fun _ => pure ()
  -- A post waits in the mailbox, and the event says whose it is: the job's
  -- wake-up is posted after its last post's event.
  let posted (id : Nat) (invocation : Invocation) : BaseIO Unit := do
    running.mailbox.push id invocation
    (discard <| Ffi.postEvent .editor collaborators.posts id.toUInt64 "" : IO Unit).catchExceptions
        fun _ => pure ()
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

/-- Cancels the job started with `key`, if one is running or has finished and
not been delivered (`Job.Jobs.cancel`), and forgets the key. -/
def cancelKeyed (running : Running β σ scheme) (key : String) : IO (Running β σ scheme) := do
  let some (_, id) := running.keyed.find? (·.1 == key) | return running
  let jobs ← running.jobs.cancel id
  return { running with
      jobs, keyed := running.keyed.filter (·.1 != key) }

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
        running := { running with keyed := running.keyed.push (key, id) }
  for spawn in spawns do
    running ← running.cancelKeyed spawn.key
    let (id, started) ← running.startWork collaborators spawn.owner spawn.label spawn.work
    collaborators.emit s!"job {id} {spawn.label}: started"
    running := { started with keyed := started.keyed.push (spawn.key, id) }
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
    let mut held := #[]
    for ms in pauses do
      let (id, wait) ← services.completions.register
      let fired (completion : Option Job.Completion) : BaseIO Unit :=
        if completion == some .completed then
          (discard <| Ffi.postEvent .editor collaborators.pauseEvents id "" :
                IO Unit).catchExceptions
            fun _ => pure ()
        else pure ()
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
    let (id, wait) ← services.completions.register
    let fired (completion : Option Job.Completion) : BaseIO Unit :=
      if completion == some .completed then
        (discard <| Ffi.postEvent .editor collaborators.pauseEvents id "" : IO Unit).catchExceptions
          fun _ => pure ()
      else pure ()
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
    keyHintDelay := running.config.keyHintDelay.getD (.after Loop.keyHintDelay), now }

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
  let mut running ←
    ({ running with
            frame := some stepped.loop, stepped := true
            config := running.config.written stepped.write
            stopped := running.stopped || stepped.next == Loop.Next.stop }).launch
        collaborators stepped.starts stepped.cancels stepped.spawns
  running ← running.pause collaborators stepped.pause
  running ← running.delayHints collaborators stepped.hintDelay
  running ← running.journaled collaborators stepped.journal
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
  let running :=
    { running with
      jobs, keyed := running.keyed.filter (·.2 != id) }
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
          { command := AtPoint.pausedName, arguments := [.nat view.index, .nat ms] })
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
(`hintLine`). `published` is how many scenes have been published, and
`theme` the name of the theme the scene was drawn in. -/
def sceneLines (scene : Scene) (published : Nat) (theme : String) : TextM (Array String) := do
  let focused :=
    match scene.focused with
    | some id => toString id.index
    | none => "-"
  let preedit :=
    match scene.preedit with
    | some text => text.quote
    | none => "-"
  let mut lines :=
    #[s!"scene {scene.size.width}x{scene.size.height}, focused {focused}, echo {scene.echo.quote}, echo padding {scene.echoPadding}, preedit {preedit}, published {published}, theme {theme.quote}"]
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
  let (result, texts) ←
    (sceneLines scene (← running.display.published) (← running.display.drawn)).runReal running.texts
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
  | .open path => running.run collaborators { command := Files.openName, arguments := [.str path] }
  | .say text => return running.said text
  | .spawn name => running.spawn collaborators name
  | .show => do
    running.show collaborators
    return running
  | .scene => running.scene collaborators
  | .agree => running.agree collaborators
  | .restore => do
    let some directory := collaborators.stateDirectory | return running
    let (id?, running) ← running.startJob collaborators Restore.restoreJob [.str directory.toString]
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
    | none =>
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
  /-- The title bar the installed config chose (`Config.State.titleBar`),
  or none: what the window mode opens its window with once the start-up
  reload has finished (`Window.titleBarAtOpen`). -/
  titleBar : Option Window.TitleBar := none

/-- What the editor thread holds as its loop starts: the config state its
packages make (`Config.State.ofPackages`: each of `collaborators.packages`
registered in order, for the owner named after it, before any config), no
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
      config
      texts := RealTexts.over collaborators.published
      display := ← collaborators.display collaborators.published.reader
      clipboard := ← collaborators.clipboard
      syntaxTree := ← collaborators.syntaxTree collaborators.published.reader
      jobs := { services := collaborators.services }
      mailbox := ← Job.Mailbox.new }

/-- The editor thread: pulls the editor queue and handles each event to its
end, until the driver ends the loop or the queues are quit. After each event
it publishes in `progress` how many markers it has reached, whether a reload
is running, how many jobs are, and the title bar the installed config
chose.

Before the first event it registers the packages it is handed
(`Running.new`), and tells the library its interrupt key; when it ends it leaves the library with
none, so that no key raises the flag while no loop takes keys off the
queue. -/
def loop {β σ : Type} {scheme : InputScheme} (collaborators : Collaborators β σ scheme)
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
          restoring := running.restoring.isSome, jobs := running.jobs.running
          titleBar := running.config.titleBar }
  -- Nothing will deal with a result any more: no job runs on unowned, and
  -- no pause waits.
  running.jobs.cancelAll
  running ← running.withdrawPauses collaborators
  discard <| running.withdrawHints collaborators
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
              collaborators.stateDirectory } }

/-- Starts a host: its loop runs on a dedicated task until `stop` or `halt`.
The loop it makes, when it is first needed, has the collaborators' working
directory, home directory and state directory in its state
(`Collaborators.hosting`). -/
def start {β σ : Type} {scheme : InputScheme} (collaborators : Collaborators β σ scheme) :
    IO Host := do
  let collaborators := collaborators.hosting
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

/-- Sends a resize of the frame to `width` by `height` physical pixels, at a
scale of 1 and out of fullscreen, with square corners (a corner clearance of
0), as the window would report it: through the library's window
input (`Event.post`), onto the editor queue after everything sent before.
Throws if the queue refuses it, which it does once the queues are quit. -/
def resize (_ : Host) (width height : Nat) : IO Unit := do
  unless ← Event.post (.resize { width, height, scale := 1.0 }) do
    throw (IO.userError "the editor queue refused a resize: it has been quit")

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

/-- Waits until the editor thread has handled everything sent so far, no
reload is running and no restore is in flight, for at most `patience`
milliseconds, and says what the wait came to. A restore holds the driver's
requests after it, the start-up reload among them, so a wait for that
reload waits for the restore first. -/
def await (host : Host) (patience : Nat) : IO Wait :=
  host.waitWhile patience (fun progress => progress.reloading || progress.restoring) .reloading

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
  /-- Send a resize of the frame to this many physical pixels across and
  down, as the window would. -/
  | resize (width height : Nat)
  /-- Settle, wait until the render loop is at rest, and print how many
  frames it drew and how many were submitted over this many milliseconds
  after. The driver's own. -/
  | idle (milliseconds : Nat)
  /-- Settle, wait until the render loop is at rest, and print how many
  frames it presented since the last `journal`, with their latencies. The
  driver's own. -/
  | journal
  /-- Wait until the host's fake clock holds a wait due within this many
  milliseconds, then move the clock on by them, completing every wait then
  due. The driver's own; it sends nothing to the editor thread. -/
  | advance (milliseconds : Nat)
  /-- Settle, then wait until the file service has worked every request
  handed to it, the session journal's orders among them. The driver's
  own. -/
  | journalled
  /-- End the process at once, with the status 134 and no shutdown, as an
  abort would: what the journal handed the system survives it. The
  driver's own. -/
  | abort
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
                      if line == "resize" || line.startsWith "resize " then
                        some <$> resizeDirective? line
                      else
                        if line == "agree" then .ok (some (.request .agree))
                        else
                          if line == "journal" then .ok (some .journal)
                          else
                            if line == "journalled" then .ok (some .journalled)
                            else
                              if line == "abort" then .ok (some .abort)
                              else
                                if line == "idle" || line.startsWith "idle " then
                                  match (named line 4).bind String.toNat? with
                                  | some milliseconds => .ok (some (.idle milliseconds))
                                  | none =>
                                    .error
                                      s!"`{line}` is not an idle: expected idle <milliseconds>, one number"
                                else
                                  if line == "advance" || line.startsWith "advance " then
                                    match (named line 7).bind String.toNat? with
                                    | some milliseconds => .ok (some (.advance milliseconds))
                                    | none =>
                                      .error
                                        s!"`{line}` is not an advance: expected advance <milliseconds>, one number"
                                  else
                                    .error
                                      s!"`{line}` is not a directive: expected reload, run <name>, spawn <name>, show, scene, agree, settle, join, idle <milliseconds>, advance <milliseconds>, journal, journalled, abort, key <logical> <physical> <modifiers>, commit <text> or resize <width> <height>"

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
  /-- The `advance` on `line` of `milliseconds` found no wait due within
  them on the clock. -/
  | stalled (line : Nat) (milliseconds : Nat)
  /-- The `advance` on `line` ran on a host whose clock is real. -/
  | noClock (line : Nat)
  deriving DecidableEq, Repr

/-- What an `advance` on a host whose clock is real says. -/
def advanceNeedsClock : String :=
  "advance needs the headless mode's fake clock"

/-- What went wrong, for the user: `patience` is how long each wait was, in
milliseconds. -/
def Failure.describe (patience : Nat) : Failure → String
  | .reloading (some line) =>
    s!"the settle on line {line} of the script did not finish within {patience} ms: a reload was still running. A file or `setup` of the config is slow, or does not end"
  | .reloading none =>
    s!"the script ended, and the reload it had asked for did not finish within {patience} ms. A file or `setup` of the config is slow, or does not end"
  | .working (some line) =>
    s!"the join on line {line} of the script did not finish within {patience} ms: a job was still running. A job of the config is slow, or does not end"
  | .working none =>
    s!"the script ended, and a job it had started did not finish within {patience} ms. A job of the config is slow, or does not end"
  | .unanswered (some line) =>
    s!"the settle or join on line {line} of the script did not finish within {patience} ms: the editor thread had not handled everything sent to it. It is still inside a command or another event, or it has ended"
  | .unanswered none =>
    s!"the script ended, and the editor thread did not stop within {patience} ms"
  | .stalled line milliseconds =>
    s!"the advance on line {line} found no wait due within {milliseconds} ms on the clock within {patience} ms"
  | .noClock line => s!"the advance on line {line}: {advanceNeedsClock}"

/-- The failure a wait that did not settle is, at `line` of the script. -/
def Wait.failure (line : Option Nat) : Wait → Option Failure
  | .settled => none
  | .reloading => some (.reloading line)
  | .working => some (.working line)
  | .unanswered => some (.unanswered line)
  | .ended => none

/-- Waits until `render`'s loop is at rest, for at most `patience`
milliseconds; `false` if it is not by then. -/
def rested (render : Render) (patience : Nat) : IO Bool :=
  within patience do
    return (← render.resting) == some true

/-- The serial of the newest entry of `render`'s journal, 0 for none. -/
def newestSerial (render : Render) : IO UInt64 := do
  return (((← render.journal 0).getD #[]).back?.map (·.serial)).getD 0

/-- What `idle <milliseconds>` prints, once the editor thread has settled:
it waits until the render loop is at rest, then counts what the loop drew
(journal entries) and what was submitted to it (its counters) over
`milliseconds` milliseconds. With no render loop it says so. -/
def idled (render : Option Render) (patience milliseconds : Nat) : IO String := do
  let some render := render | return s!"idle {milliseconds}: no render loop"
  unless ← rested render patience do
    return s!"idle {milliseconds}: the render loop did not come to rest within {patience} ms"
  let some before ← render.counters | return s!"idle {milliseconds}: no render loop"
  let last ← newestSerial render
  IO.sleep milliseconds.toUInt32
  let drawn := ((← render.journal last).getD #[]).size
  let submitted :=
    match ← render.counters with
    | some after => after.framesSubmitted - before.framesSubmitted
    | none => 0
  return s!"idle {milliseconds}: {drawn} frames drawn, {submitted} frames submitted"

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
def journalSince (render : Option Render) (patience : Nat) (after : UInt64) :
    IO (String × UInt64) := do
  let some render := render | return ("journal: no render loop", after)
  unless ← rested render patience do
    return (s!"journal: the render loop did not come to rest within {patience} ms", after)
  let entries := (← render.journal after).getD #[]
  return (journalLine entries, (entries.back?.map (·.serial)).getD after)

/-- The status `abort` ends the process with: 128 and SIGABRT's 6, as a
shell reports an abort, without raising the signal, which on a macOS desktop
brings up the crash reporter. -/
def abortStatus : UInt8 :=
  134

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
def run {β σ : Type} {scheme : InputScheme} (collaborators : Collaborators β σ scheme)
    (script : Array Line) (patience : Nat) : IO (Option Failure) := do
  let host ← start collaborators
  -- With a state directory, the session is restored first.
  if collaborators.stateDirectory.isSome then
    host.send .restore
  -- The serial of the last journal entry a `journal` line counted.
  let mut journaled : UInt64 := 0
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
      | .resize width height =>
        host.resize width height
        continue
      | .settle =>
        host.await patience
      | .join =>
        host.join patience
      | .idle milliseconds =>
        let wait ← host.await patience
        if wait == .settled then
          collaborators.emit (← idled collaborators.render patience milliseconds)
        pure wait
      | .journal =>
        let wait ← host.await patience
        if wait == .settled then
          let (said, last) ← journalSince collaborators.render patience journaled
          journaled := last
          collaborators.emit said
        pure wait
      | .journalled =>
        let wait ← host.await patience
        if wait == .settled then
          unless ← within patience (return (← collaborators.journal.pending) == 0) do
            discard <| host.halt patience
            return some (.unanswered (some line.number))
        pure wait
      | .abort =>
        (← IO.getStdout).flush
        IO.Process.exit abortStatus
      | .advance milliseconds =>
        let some clock := collaborators.clock |
          discard <| host.halt patience
          return some (.noClock line.number)
        -- Only once a wait is due within the move: so a job that is about
        -- to sleep is in its sleep before the clock moves past it.
        unless ← within patience (clock.dueWithin milliseconds) do
          discard <| host.halt patience
          return some (.stalled line.number milliseconds)
        clock.advance milliseconds
        continue
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

/-- Runs `script` against a host of its own, as `run` does, and then, the
host's loop having ended, removes what the collaborators left outside the
process (`Collaborators.dispose`): once, whether the run returned or threw.
A dispose that throws is ignored, so it neither hides the run's failure nor
replaces it. What the headless mode runs (`main`). -/
def runAndDispose {β σ : Type} {scheme : InputScheme} (collaborators : Collaborators β σ scheme)
    (script : Array Line) (patience : Nat) : IO (Option Failure) := do
  try
    run collaborators script patience
  finally
    try
      collaborators.dispose
    catch _ =>
      pure ()

/-- How long a host's end waits for the file service to work what it holds,
the journal's last orders among them, before it quits the queues, in
milliseconds. -/
def drainPatience : Nat :=
  2000

/-- How long the headless mode waits at each `settle` and each `join`, and
for the loop to stop, in milliseconds. -/
def settlePatience : Nat :=
  30000

/-- How long warming the pool waits, in milliseconds, for each of its tasks
to start. A task starts in microseconds; this long passes only when the pool
is smaller than the machine, because `LEAN_NUM_THREADS` says so. -/
def warmPatience : Nat :=
  200

/-- The display the headless mode draws with under `--render`: the real
binding over a display of the library's in `cells`, bound to the library's
presenter (`Ffi.Display.present`), so every scene it publishes reaches the
render session, over the snapshots `snapshots` reads. -/
def drawnDisplay (snapshots : SnapshotReader) : IO Host.Display := do
  let display ← Ffi.Display.newCells cells.advance.toUInt64 cells.lineHeight.toUInt64
  display.present
  Host.Display.real (← RealDisplay.over display snapshots Theme.builtin)

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
config that names a package's declarations. Its input scheme is the Vim scheme's default
(`Vim.Default.scheme`), which is the host's type and no package's. Its
display is the recorder and its clipboard its own, as a host's are by
default.

It names no package: the executable passes the packages of its package
set, the core's first (`EditorCore/EditorPackage.lean`), and what those
register is said there and in each package's module.

It is apart from `shipped`, which makes what it is over, so that the
collaborators can be made with no pump started. -/
def shippedOver (packages : Array Package) (base : Array Lean.Name) (sysroot : String)
    (oleans : List String) (configDir : String) (emit : String → IO Unit) (services : Job.Services)
    (published : Snapshots) (held : Job.HeldSnapshots) (files : Config.Elaborate.ModuleFiles)
    (stateDirectory : Option System.FilePath := none) :
    Collaborators Config.Elaborate.Base Config.Elaborate.Handle Vim.Default.scheme :=
  { elaborator :=
      Config.Elaborate.elaborator
        { sysroot, oleanDirs := oleans.map System.FilePath.mk, imports := base } files,
    source := Config.Directory.source configDir,
    package :=
      { read := Config.Directory.read configDir, requires := Config.Lakefile.Toml.requires },
    emit, services, published, held, requests := 1, wakeups := 2, jobs := 3, environment := 4,
    posts := 5, pauseEvents := 6, packages, stateDirectory, log := IO.eprintln
    journal := Journal.real published.reader
    dispose := files.remove }

/-- The environments every job of a host shares, over `state`
(`Job.sharedEnvironments`), which report what they have to say by posting it
to the editor queue under the Lean source id `source`: the host's editor
thread then says it in the echo area (`Collaborators.environment`). -/
def reportedEnvironments (state : IO.Ref Process.Environments) (source : UInt64) :
    Job.Environments :=
  Job.sharedEnvironments state fun text =>
    (discard <| Ffi.postEvent .editor source 0 text : IO Unit).catchExceptions fun _ => pure ()

/-- The collaborators the executable's hosts are made of, the headless
mode's and the window mode's, with `packages` as the packages the host
registers: `shippedOver` the library's timer service,
file service, process service, watch service and diff service for the
jobs, the library's matcher (`Fuzzy.real`), which the loop's match jobs ask,
and the environments they share for the mode `host` (`reportedEnvironments`).
Config is elaborated on `base`, which every caller names (`shippedOver`).

Making them warms the pool, so the first burst of jobs finds every thread
made, and starts the completion pump on a dedicated task, which quitting the
queues ends. -/
def shipped (packages : Array Package) (base : Array Lean.Name) (sysroot : String)
    (oleans : List String) (configDir : String) (emit : String → IO Unit) (host : Process.Host)
    (fakeClock : Bool := false) (stateDirectory : Option System.FilePath := none) :
    IO (Collaborators Config.Elaborate.Base Config.Elaborate.Handle Vim.Default.scheme) := do
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
    shippedOver packages base sysroot oleans configDir emit
      { completions, timers
        files := Job.realFiles completions published.reader held
        processes := Job.realProcesses completions refused timers timed
        fileWatches := Job.realFileWatches completions watches
        diffs := Job.realDiffs completions published.reader held refusedDiffs
        greps := Job.realGreps completions published.reader held greps
        environments := reportedEnvironments environments 4, fuzzy := Fuzzy.real
        snapshots := Job.realSnapshots published.reader } published held files stateDirectory
  return { collaborators with clock }

/-- What generates the lakefile and the toolchain file of the config
directory `configDir`, for the editor at `appPath` that the build says
`origin` of: files are created in that directory, never overwritten
(`Config.Directory.create`); the pin is the build's; and the package set is
the build's name for it at the directory the editor finds for itself
(`ModuleLookup.setDirectory?`, with the real file read and directory
test), or none when it finds none, and then no lakefile is written. Both
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
  return {
      create := Config.Directory.create configDir, pin := origin.pin
      set := origin.set directory }

/-- The headless mode of the executable, handed the packages its host
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
def main (packages : Array Package) (base : Array Lean.Name) (origin : Config.LakePackage.Origin)
    (arguments : List String) : IO UInt32 := do
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
    { render := drawn, generate, sysroot, oleans, config := configDir, script := scriptPath, state }
    ←
    match read appPath arguments recorded with
    | .ok read =>
      pure read
    | .error reason =>
      unless reason.isEmpty do
        IO.eprintln s!"editor: {reason}"
      IO.eprintln s!"usage: editor {usage}"
      return 2
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
    shipped packages base sysroot oleans configDir IO.println .headless (fakeClock := true)
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
  let failure ←
    runAndDispose
        { shipped with
          generator, workingDirectory
          display :=
            if drawn then drawnDisplay else fun snapshots => Host.Display.recorder cells snapshots
          render := if drawn then some Render.library else none }
        directives settlePatience
  (← IO.getStdout).flush
  if let some failure := failure then
    IO.eprintln s!"editor: {failure.describe settlePatience}"
  if drawn then
    discard Ffi.renderStop
  -- Every child the library started is killed and reaped before the queues
  -- are quit: `run` has returned, so the loop has cancelled every job.
  Ffi.processesShutdown
  -- And every watch is ended, and every search.
  Ffi.watchesShutdown
  Ffi.grepShutdown
  -- And what the journal handed the file service is written, for at most
  -- `drainPatience`.
  discard <| within drainPatience (return (← Ffi.filesPending) == 0)
  -- Shutdown: quit lets every task parked in a pull return, the pump among
  -- them, and the exit is explicit, because a task may still be blocked in
  -- the library.
  Ffi.quit
  IO.Process.exit (if failure.isNone then 0 else 1)

end Editor.Headless
