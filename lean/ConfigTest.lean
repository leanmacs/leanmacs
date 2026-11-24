import ConfigTest.Bench
import ConfigTest.Check
import ConfigTest.DefaultConfig
import ConfigTest.Editor.AtPoint
import ConfigTest.Editor.Completion.Keys
import ConfigTest.Editor.Config.Directory
import ConfigTest.Editor.Config.Elaborate
import ConfigTest.Editor.Config.Elaborator.Contract
import ConfigTest.Editor.Config.Lakefile.Toml
import ConfigTest.Editor.Extension
import ConfigTest.Editor.Face
import ConfigTest.Editor.Headless
import ConfigTest.Editor.Headless.Stepped
import ConfigTest.Editor.Indent
import ConfigTest.Editor.Job.ProtocolContract
import ConfigTest.Editor.Keymap
import ConfigTest.Editor.Loop
import ConfigTest.Editor.Minibuffer
import ConfigTest.Editor.PackageSet.Edit
import ConfigTest.Editor.Setup
import ConfigTest.Editor.Test.Linked.Host
import ConfigTest.Editor.Theme.Check
import ConfigTest.Lint.Wait
import ConfigTest.Lsp

/-!
# Checks of the config session against the real elaborator

The `config-test` executable is linked exactly like `editor`, with the glue
object, the Rust archive and Lean's elaborator. `mise run ffi-test` runs it
as `config-test <sysroot> <olean dir> <syntax fixtures> <default config>`:
the Lean toolchain's directory, the directory holding the package's
`.olean` files, the directory of the syntax fixtures (`tests/syntax`), whose
Rust indent fixture the indent checks read, and the directory of the
default config `mise run install` ships (`config/default`), which
`defaultConfigChecks` read. It reads nothing from the
environment or the working directory. It runs every check in `checks`, names
the ones that failed, each with what it saw when it says (`saw`), and exits
non-zero if any did.

The checks themselves live in test modules that mirror the module they
test, where ModelTest keeps the model counterpart where there is one: the
checks of the headless host's own loop, threads and scripts are in
`ConfigTest/Editor/Headless.lean` (`ConfigTest.Editor.Headless`), and those
of prompts through the host in `ConfigTest/Editor/Minibuffer.lean`. The
default config (`config/default`) is no Lean module, so its checks are in
`ConfigTest/DefaultConfig.lean`, which mirrors none. A test module keeps the helpers only its checks use. Helpers that several test
modules use are in small support modules under `ConfigTest/Support/`, each
of one kind of fixture, and `ConfigTest.Check` holds the `Check` type, the
`Context` every check is given, `failures`, `saw`, their own checks
(`checkChecks`), `run` (handed `checks` by `main`) with the check of its
timings (`runChecks`), and `usage`. Everything
is in the namespace `ConfigTest`, so a list is `ConfigTest.<name>Checks`
whichever module holds it. This module keeps
only `checks`, which runs them in order, and `main`.

The model tests (`ModelTest.lean` and `ModelTest/`) pin the decisions of the
config session on fakes. The checks here pin what only real collaborators can
show:

- `elaboratorChecks`: what only Lean's elaborator can show of a config file
  as a module: a file that imports `Lean`, a module of the base and a
  config file sees each; a program a config file exports takes effect when
  the root's `setup` calls it, and a `setup` defined outside the root is
  not run; a diagnostic is at the file's own line; `module` and
  `initialize` are refused; which modules are linked; each version of a
  config file has module data of its own; compiled code and config share
  state; and the base's modules are looked for in every directory it is
  given, in order;
- `moduleFilesChecks`: where the real elaborator writes the module data of
  config files (`ModuleFiles`): the directory is made once, when it is
  first asked for, removed once, and only when it was made, and the
  temporary one is really removed with what is in it, in a temporary
  directory the check owns;
- `elaboratorContractChecks`: the elaborator port's contract
  (`Editor/Config/Elaborator/Contract.lean`) held of that real elaborator,
  as `model-test` holds it of the port's model;
- `lakefileChecks`: a lakefile's requires read with Lake's TOML loader, the
  generated lakefile read back, and the core's copy of Lake's casing rule
  against Lake's own;
- `lakefileEntryChecks`: a lakefile's `[[require]]` tables read whole with
  Lake's TOML loader, each a path, git or Reservoir dependency with its
  fields, and the generated lakefile read back as one path require;
- `packageSetEditChecks`: each text the lakefile's edits make
  (`Editor/PackageSet/Edit.lean`) read back with Lake's TOML loader as
  requiring exactly what the edit meant;
- `directoryChecks`: the directory as a source of config files (the root, a
  config file by exactly its module name, also on a file system that
  ignores case, the stray files, and a root spelt `Init.lean` rejected as
  misspelt, not as the old form) and as a Lake package (a
  file read by name, and a file created only when it is not there), each
  check in a temporary directory of its own;
- `moduleHostChecks`: config as modules through the headless host, with the
  real elaborator over files in a temporary directory: after a change to
  one file a reload elaborates that file and the files that import it and
  no other; a root that imports a module that is not linked is rejected,
  the diagnostic names the module, and the old config stays; and a reload
  whose root first imports `Lean` installs, the base growing to hold it,
  and a settle after one waits for its end, its root held at a gate until
  the settle blocks on it (`waitBlocked`);
- `hostChecks`: the phase's acceptance tests through the headless host, with
  the real elaborator, the real queue and the real text binding, asserted on
  the lines the host prints; and what a host starts from: handed no
  packages, an empty registry and no menu bar, and handed a package it
  refuses, that package logged and skipped and the others registered;
- `bracketChecks`: the bracket a host lives in (`Headless.withHost`): it
  returns only once the host's loop has ended, whether its body returned
  or threw, waits past its guard for a loop held inside an event, saying a
  hang once, throws the body's error, or the loop's when the body returned,
  and hands back the loop's end without throwing it (`withHostEnding`);
  the hold is let go by the bracket's own report of the hang, never by
  time; a reload held at a gate when the body returns is waited for by the
  loop's end, which says so (`endWaits`) and is what lets it go; and a
  bracket given a grace fails as a hang on a loop held past it;
- `steppedChecks`: a host stepped on the check's own thread
  (`Headless.withStepped`, `Editor/Headless/Stepped.lean`): its lines are
  emitted on the check's thread and no loop thread starts; a settle after a
  reload held at a gate settles only after the install, the gate let go
  from the wait's block; a join with a job asleep on the fake clock answers
  working at idle, as an advance's wait with nothing due does; an event
  pushed after a round's drain found the queue empty, in a round that
  posts no marker, the count unchanged, wakes the wait's block and is
  handled (the forced lost wake-up); it publishes the scenes a real host
  does; a wait at its guard says the hang once; the bracket, on return and
  on throw, cancels the jobs, waits for a held reload after `endWaits` and
  closes the queue; its end with a reload held past its guard says the
  hang once and, with a grace, gives up as a hang, handing the reload to
  `abandoned`, or with none waits on; and a loop a step stopped, or a turn that threw, makes
  later waits answer ended, the turn's error thrown by the bracket;
- `protocolContractChecks`: the runner's protocol contract
  (`Editor/Job/ProtocolContract.lean`) on a stepped host whose services
  record to the fake recorder: a nap the clock wakes and one the loop's end
  cancels record a trace that replays on the model and ends in the loop's
  end, recorded once the jobs it cancelled are done; a nap cancelled by its
  key and a config job cancelled by the reload that installs, each held at
  its resume until the loop's end hands it over to be waited for, are done
  before the loop's end is recorded; and a nap held just
  after it gave its unit back for its sleep, where the body returns, is in
  a wait the loop's end withdraws (`parkHolds`), and the same check with
  the park put in the order before the runner-park fix (`preFixOrder`)
  finds it in none, held at its `ask` with its unit back; and a job whose
  load or streaming start its service completed inside the start, held at
  its wake before it recorded the wait and cancelled by its key there,
  drops the request at its service by its serve, its trace a run of the
  protocol (`cancelAfterWakeChecks`). They wait only on the recorder's
  events, and hold the nap on a promise;
- `threadChecks`: the editor answers events while a file elaborates, reloads
  are serialised, and a replaced config is not retained;
- `jobChecks`: jobs from config through the host: a handler receives a job's
  result on the editor thread, a reload that installs cancels the old
  config's jobs and a rejected one does not, how each ending of a job is
  reported, and a join that cannot finish answering working at idle, with
  nothing said as a hang, also when the editor thread is held inside an
  event as the join asks for its answer (let go when the join blocks on
  it, `meetingAnswer`); and an `indexed`'s rounds (`Headless.awaitIndexed`):
  over a scripted wait and a fake clock, idle with a write of the index in
  its sleep and no other job moves the clock once and waits again, while
  idle with a background job running, or with no fake clock, answers
  working; and through the host, an `indexed` with a background job asleep
  on the clock fails at idle, naming its line, and is not a hang;
- `idleChecks`: a host's idle signal (`Editor/Headless.lean`, "The idle
  signal"): what holds a unit of a host's activity count, read through the
  host and waited for on the count's own changes, with the editor thread
  held at a line to look while an event is queued: a job asleep on the
  fake clock holds none, a job's result holds one until it is handled, and
  a pause's event holds one from the clock's move until it is handled; a
  wait's later rounds publish nothing (a join forced to two rounds gives
  the scene count of one); and a late event just before idle does not make
  idle early: a join with a job's start of its sleep held, or a job's
  result on its way, blocks on it (let go from its `waitBlocked`) rather
  than answer working;
- `shippedChecks`: what the executable's host starts its loop with, the
  state directory it is handed. What its registry holds is not this
  list's: the core's Lake package registers no package and has no entry
  module, so a host starts from what its set's packages register, which
  is nothing when it is handed none (`hostChecks`, above, and
  `ModelTest.packageChecks`), and what each default package registers is
  that package's own tests'. The ex line through the host
  (`exChecks`, `exScriptChecks`) is the package `ex`'s linked test's
  (`ExTest.Linked`, `packages/ex/`);
- `scriptChecks`: the headless mode's script (its `indexed` and
  `workspaces` directives among them) and its driver, and the editor
  loop through the host: a commit and the scene it prints, read from the
  library, a scene published after a reload's install and a job's command
  once the frame exists, the scene whose echo is the refusal once a command
  has released the focused buffer's text, the line the host prints for a
  program of the loop that is refused, and a window's close request with
  nothing unsaved ending the loop; and the headless mode's run disposing of
  its collaborators once its loop has ended, whether it failed or not, even
  with the editor thread inside an event when a join or an advance waits
  on it, or with the loop slow to end at the script's end, which guard a
  failure names (`Wait.failureIn`); a `join` and an `advance` answer at
  idle, and the checks that pin a bound of the headless mode (a reload or
  the editor thread held for good) say their hang once (`waitHung`); and
  the executable's hosts' dispose removing the directory of the config
  files' module data once it was made;
- `dispatchChecks`: keys through the host, with the test scheme and
  compiled commands and bindings written here: a compiled binding runs its
  command, a command that fails is rolled back and says so, the interrupt
  key stops a command that loops and stops nothing when none runs, config's
  command of a compiled command's name runs until a reload drops it, a
  reload rebinds a key, compiled bindings run when config fails to load,
  a command slower than the threshold is logged, on the fake clock, and a
  marked interrupt key no loop takes, one that cannot be read or one that
  arrives when the frame cannot be made, still has the flag lowered for it.
  Those last two run no loop: each pulls the key off the queue and hands it
  to the host's handler on its own thread (`withRunning`);
- `modeChecks`: modes through the host, with the test scheme: a role's key
  runs the command of a mode config defines, a store command among them,
  in a view of a buffer that has the mode, and once a reload drops the mode
  it runs the global binding; and a role's key runs the command of a mode
  compiled code hands the host (`Compiled.modes`), before any reload and
  after a reload of a config that defines none. The host's frame is made
  with the scratch buffer's major mode set (`Compiled.major`), since no
  command can set one yet, and the key pressed is the test scheme's for the
  role (`Session.pressKeys`), so no check names a scheme's key;
- `promptChecks`: prompts through the host, with the test scheme, the
  kit's minibuffer's commands and its mode as compiled code hands them
  (`Test.Minibuffer.package.registered.commands`,
  `Test.Minibuffer.package.registered.modes`, `Editor/Test/Minibuffer.lean`)
  and commands written here: a
  command asks, a commit is typed into the minibuffer and the scene shows
  it; the accept key runs the continuation's command with the answer and
  the cancel key does not; a job's result is delivered while a prompt is
  open, on the fake clock; the continuation is looked up when the answer
  arrives, across a reload; the answer's command runs before the next key;
  and it is looked up after the accepting command's write to a store was
  written back; a prompt lists the candidates of a source config registers
  and asks for by name, and of one the executable's hosts ship
  (the `themes` package's), which config's source of its name replaces
  until a reload drops it; and completion phase 4's criteria: the list
  drawn in a view of its own up to the rows config's display sets, the
  height it takes given back when the prompt closes, an annotation's
  column and the matched ranges' face, and a display config chooses for
  one category, redrawn with the default by the install's own scene once a
  reload drops the choice. The accept key and the cancel key are the test scheme's
  for the roles the minibuffer's mode fills;
- `leaderChecks`: the leader through a host of the test scheme: a
  config's `<leader> f f` binding runs on the scheme's leader and then
  `f f` while config sets no leader, and on `\ f f` once a reload sets the
  leader to `\`, when the scheme's leader no longer runs it;
- `hintChecks`: the key hints through a host of the test scheme: after a
  reload, a config's prefix name and a binding's description are in the
  scene's `hint` lines after the scheme's leader and after the leader and
  `f`, none are after the binding runs, and a reload that drops the prefix
  name lists the prefix unnamed (with a delay of 0, so they are shown at
  once);
- `keyHintChecks`: when and where the key hints are shown, through a host
  of the test scheme, on the fake clock and the recorder: after the
  scheme's leader and the default delay the scene lists the keys that can
  follow with their descriptions and prefix names, drawn by the minibuffer
  display above the bottom row, and none before; a sequence completed or
  reset before the delay withdraws it and shows none; a delay of 0 shows
  them in the first scene; the pending keys are drawn in the selected
  window's status line while pending and cleared once the sequence
  completes; a display config chooses for `key` draws them; `.never` arms
  nothing; a reload while the leader is pending that sets `.never` closes
  hints shown and withdraws a wait, one that keeps the delay keeps its
  wait, and one that sets it again arms a new wait; and a reload refuses a
  delay over a minute, one that is not a delay and one set twice;
- `defaultConfigChecks`: the default config `mise run install` ships, read
  from the directory the fourth argument names: a reload of it through a
  host of the test scheme installs with no diagnostic; each of
  its bindings names a registered command or one of the default packages'
  commands, by name; and each prefix it binds under the leader, read
  through the scheme's leader, has a prefix name (`Registry.prefixName?`);
- `extensionChecks`: extension points (`Editor/Extension.lean`) with the
  real elaborator, over the fixture `ExtensionFixture`, which declares an
  extension point and a compiled package that reads it: a config
  elaborated at runtime registers at that point, the compiled package
  reads config's value typed and runs its interpreted program, and a
  reload without the registration replaces config's value and keeps the
  package's; and the package's job over the point is made, when it is
  started, from config's value after the package's;
- `indentChecks`: the core's indent levels through a host of the test
  scheme, over the library's Rust grammar, each asked by a command of
  config's run by name: the edits `TextId.reindentEdits` answers of every
  row of the mangled Rust indent fixture (`tests/syntax/rust/indent.rs`,
  read from the directory the third argument names), applied, give the
  fixture back, rows inside a string and a comment keeping their indent;
  `TextId.openingLevel` after an opening brace is the tree's level; and a
  buffer with no language or no indents query is refused, as a value;
- `restoreOrderChecks`: the restore at start-up in the host, on the real
  elaborator: over the library's file service and a journal on disk, the
  restore's second half runs, and its buffer is there, before reload 1 is
  installed; over a fake file service whose takes are held, a reload sent
  while the restore is in flight is held, and `await` does not answer
  settled, until it has finished; and a restore whose job fails releases
  what it held (the file given opened, the text said, reload 1 installed)
  and `await` answers settled. A package's declared store kept across a
  restart comes back before any reload, and migrated by the package at a
  new version; a config's store comes back by the start-up reload, stays
  parked and written while a config's `setup` throws, and is claimed by a
  later good reload. The first and the last share the table of waits of
  the hosts over a real service;
- `journalFailureChecks`: the journal's failures in the host, over a
  journal whose failures the check puts there: they are taken after each
  step, and said once for each path, in the echo area and to the log;
- `journalDrainChecks`: the host's journal over the library's file service
  (`Headless.Journal.real`): with the service's worker held its drain has
  not ended, and let go it ends true with the order handed before it
  worked. It shares `fileChecks`' table of waits;
- `journalOrderChecks`: the host's hand-off of the session journal's
  orders, on a stepped host over the journal's recording fake
  (`Stage.recordingJournal`): the base's save, the header's and a record's
  appends and the removes, in order, each handed on the check's thread,
  and the drain ended only by the check's step;
- `stageMakerChecks`: a stepped stage (`Stage.stepped`): its job runs only
  on the session's step, every piece, completion and request on the
  check's thread; a step leaves a job asleep on the fake clock held; the
  loop's end steps a cancelled job never stepped to its end; the bracket
  fails a check that left a completion unstepped; a stepped stage refuses
  the library's services and a real host refuses it, and refuses a stage
  stepped already; `stepUntil` says a stall at once; the loop's end
  throws, naming the job, when a job it cancelled has not ended and nothing
  of the fakes can run; and a session's ask throws a stall when a restore
  is in flight and nothing of the fakes can run. And a stage's fake syntax service
  (`Stage.fakeSyntaxService`, `Editor/Test/Linked/Host.lean`) on a stepped
  host: it is the host's syntax handler, learns a text the host published
  from the stage's table, refuses its captures as not parsed until the
  check steps it, and its step posts one `parsed` event to the stage's
  memory queue, which the loop takes and answers with one scene, every
  request and post on the check's thread;
- `reloadEchoChecks`: a rejected reload's first error is said in the echo
  area, while the old config runs; a reload that installs says nothing;
  and one rejected before the frame is made is said once it is;
- `faceChecks`: a face set in a config file reaches the next frame,
  through a host handed the display's real binding over the library's
  layout: the host's reload re-themes its display (`Config.retheme`), and
  the frame the library made of the next scene is compared with a second
  display's frame of the same scene in a theme written here; and a reload
  that makes `mode-line` taller sizes the next scene by the new heights,
  which `agree`, asked with no event between, shows;
- `cursorResolutionChecks`: the completeness check's model of a cursor's
  colours (`Themes.effective`) is the real layout's: for the built-in
  theme, the fixture themes and two whose cursor sets one colour alone, each cursor face's
  frame is the frame of a mirror theme that sets the modelled colours;
- the files' host checks (`languageChecks`, `fileChecks`, `reloadChecks`,
  `filePromptChecks`, `autoReloadChecks`) are the files package's linked
  test's since features-as-packages phase 6 (`FilesTest.Linked`,
  `packages/files/FilesTest/Linked/Files.lean`).

The compile mode as a real config sees it is not checked here: the compile
mode is a package outside the core (`packages/compile/`), and the base this
executable elaborates on is the core's. That a real config written on the
package's declarations elaborates is its headless fixture `config`, run on
the editor built from a set that holds it, and what the hook makes of such
a config's registrations is `CompileTest.compileHookChecks`, on the same
`setup` written as compiled code.

A check controls time through a port, never by sleeping and hoping: a
decorator of the elaborator port (`Gate`) holds one file's elaboration open
until the check lets it go, and a host's jobs wait on a fake clock
(`Editor/Job/Fake.lean`) that only the check moves. Most host checks run on
a host stepped on the check's own thread (`Headless.withStepped`, through
the plain helpers `withHost`, `withTestHost`, `onStage` and the rest of
`Editor/Test/Linked/Host.lean`): its loop's turns are taken by the check's
waits, which end on events and at idle, with a guard against a hang only.
The checks listed in `docs/dev-practices/real-thread-checks.md` run a real
loop thread (the `Real` helpers), and `config-test --real-threads <file>`
names the checks that did, which `mise run ffi-test` holds to that list.
On those, a wait that is a poll still has a bound, so broken code fails a
check instead of hanging the executable. Each line a host emits is recorded
with the thread that emitted it, which is how a check sees that a handler
ran on the editor thread: the check's own, on a stepped host.

All the checks share one base, made once in `run` and grown when a check's
config first imports a module it does not hold (`Editor.Test.Linked.sharing`): a
second import of a module in one process about doubles its memory. The
checks whose config imports `Lean` run last, since every environment made
from a base that holds `Lean` costs a few times more. The module data of
the config files the checks elaborate is written in a temporary directory
of the run, removed when it ends. The real-thread hosts follow one another on
the process's one editor queue and never overlap: every check stops its host
before it returns. A stepped host has a queue of its own, and a stepped
check fails if it left anything on the library's queue.

No check makes the process abort. In particular none evaluates a declaration
that reads an `initialize`d constant of config's, and none runs config that
recurses without bound.

The executable also holds the benchmark (`ConfigTest.Bench`,
`ConfigTest/Bench.lean`), which the gate builds and never runs. The
workspace finder's, which was here too, is the workspace package's
(`WorkspaceTest.Linked.WorkspaceBench`, an opt-in argument of its linked
test; `mise run find-file-bench`).

Evil's checks through a host, `treeObjectChecks`, `treeObjectFixtureChecks`,
`evilIndentChecks`, `evilChecks` and `evilLeaderChecks`, which were here,
are the default package `evil`'s linked test's since the
features-as-packages roadmap's phase 7
(`packages/evil/EvilTest/Linked.lean`, whose module doc says what each
shows): no check here runs a host of the Vim scheme.

The themes' checks through a host, `themeChecks`, are the default package
`themes`' linked test's since that phase too
(`packages/themes/ThemesTest/Linked.lean`).
-/

namespace ConfigTest

open Editor

/-- Every check, in the order they run. -/
def checks (context : Context) : List Check :=
  checkChecks () ++ runChecks context ++ lakefileChecks () ++ lakefileEntryChecks () ++
    packageSetEditChecks () ++
    directoryChecks () ++
    moduleFilesChecks () ++
    hostChecks context ++
    bracketChecks context ++
    steppedChecks context ++
    protocolContractChecks context ++
    threadChecks context ++
    jobChecks context ++
    idleChecks context ++
    indentChecks context ++
    watchReloadChecks context ++
    agreementChecks () ++
    shippedChecks () ++
    scriptChecks context ++
    dispatchChecks context ++
    hostLoopChecks context ++
    modeChecks context ++
    promptChecks context ++
    atPointChecks context ++
    reloadEchoChecks context ++
    faceChecks context ++
    cursorResolutionChecks () ++
    environmentHostChecks context ++
    restoreOrderChecks context ++
    journalFailureChecks context ++
    journalDrainChecks context ++
    journalOrderChecks context ++
    stageMakerChecks context ++
    leaderChecks context ++
    hintChecks context ++
    keyHintChecks context ++
    defaultConfigChecks context ++
    extensionChecks context ++
    -- Last, the checks whose config imports `Lean`: the base the checks
    -- share then holds it, and every environment made from that base
    -- after them costs a few times more.
    moduleHostChecks context ++
    elaboratorChecks context ++
    elaboratorContractChecks context

end ConfigTest

/-- `config-test <sysroot> <olean dir> <syntax fixtures> <default config>`
runs the checks: exits 0 when all hold, and 1 after naming the ones that do
not. With `--real-threads <file>` after them, it also writes to `<file>`
the names of the checks that ran a real editor loop thread, one per line
(`ConfigTest.inventory`). With `--timings <file>`, it writes to `<file>`, as
each ends, the wall time in milliseconds of the base's import and of each
check, a tab and its name (`ConfigTest.run`): what the stress loop keeps of
each round, to size the hang guards from. The third argument is the directory of the syntax fixtures
(`tests/syntax`), which the indent checks read, and the fourth the directory
of the default config (`config/default`), which `defaultConfigChecks` read.

`lsp` is the language server check (`ConfigTest.Lsp`,
`ConfigTest/Lsp.lean`): it starts Lean's language server in a config
directory and requires the root's one error where the command line says,
and `mise run ffi-test` runs it through `tools/config-package-check.sh`.

`bench-start`, `bench-reload`, `bench-reload-directory`, `bench-soak` and
`bench-soak-modules` are the benchmark (`ConfigTest.Bench`; `mise run config-bench`), which the gate
never runs.
`bench-modules` lists the modules an import set reads, for
`mise run module-bench` and the gate's `bundle-test`.
`bench-jobs` is the job benchmark (`ConfigTest.Bench.jobs`;
`mise run job-bench`), which the gate never runs either, and so is
`bench-prompt`, the prompt benchmark (`ConfigTest.Bench.prompt`;
`mise run prompt-bench`), and `bench-journal`, the session
journal's cost on the editor thread (`ConfigTest.Bench.journal`;
`mise run journal-bench`).

Any other command line is reported, with the exit status 2.

It exits explicitly: a failed check may have left a task parked in the
library, and a benchmark leaves its host's loop running; returning from
`main` would wait for either for ever. -/
def main (args : List String) : IO UInt32 := do
  match args with
  | "bench-start" :: sysroot :: oleanDir :: module :: modules =>
    IO.Process.exit (← ConfigTest.Bench.start sysroot oleanDir (module :: modules))
  | "bench-modules" :: sysroot :: oleanDir :: module :: modules =>
    IO.Process.exit (← ConfigTest.Bench.modules sysroot oleanDir (module :: modules))
  | ["bench-journal"] =>
    IO.Process.exit (← ConfigTest.Bench.journal)
  | ["bench-reload", sysroot, oleanDir] =>
    IO.Process.exit (← ConfigTest.Bench.reload sysroot oleanDir)
  | ["bench-reload-directory", sysroot, oleanDir] =>
    IO.Process.exit (← ConfigTest.Bench.reloadDirectory sysroot oleanDir)
  | ["bench-soak", sysroot, oleanDir, count] =>
    match count.toNat? with
    | some count =>
      IO.Process.exit (← ConfigTest.Bench.soak sysroot oleanDir count)
    | none =>
      ConfigTest.usage
  | ["bench-soak-modules", sysroot, oleanDir, count] =>
    match count.toNat? with
    | some count =>
      IO.Process.exit (← ConfigTest.Bench.soakModules sysroot oleanDir count)
    | none =>
      ConfigTest.usage
  | ["lsp", sysroot, configDir, line, column] =>
    match line.toNat?, column.toNat? with
    | some line, some column =>
      IO.Process.exit (← ConfigTest.Lsp.run sysroot configDir line column)
    | _, _ =>
      ConfigTest.usage
  | ["bench-jobs", sysroot, oleanDir, samples] =>
    match samples.toNat? with
    | some samples =>
      -- A benchmark that fails leaves tasks running, so it says why and
      -- exits here: an error that left `main` would wait for them for ever.
      let status ←
        try
          ConfigTest.Bench.jobs sysroot oleanDir samples
        catch error =>
          IO.eprintln s!"config-test: bench-jobs: {error}"
          pure 1
      IO.Process.exit status
    | none =>
      ConfigTest.usage
  | ["bench-prompt", sysroot, oleanDir, samples] =>
    match samples.toNat? with
    | some samples =>
      let status ←
        try
          ConfigTest.Bench.prompt sysroot oleanDir samples
        catch error =>
          IO.eprintln s!"config-test: bench-prompt: {error}"
          pure 1
      IO.Process.exit status
    | none =>
      ConfigTest.usage
  | sysroot :: oleanDir :: syntaxFixtures :: defaultConfig :: rest =>
    match ConfigTest.options rest with
    | some (realThreads, timings) =>
      IO.Process.exit
          (←
            ConfigTest.run ConfigTest.checks sysroot oleanDir syntaxFixtures defaultConfig
                ConfigTest.shippedPackages realThreads timings)
    | none =>
      ConfigTest.usage
  | _ =>
    ConfigTest.usage
