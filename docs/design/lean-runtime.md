# The Lean program

How the executable is built and started, how config is loaded and reloaded,
what the editor API looks like, and where state lives.

Two throwaway prototypes stand behind this document. The first (commit
`4e57f01`) embedded Lean in a Rust process and proved runtime elaboration
and live reload. The second (the spike, uncommitted, notes in
`research_notes/lean-host-spike.md`) turned it round: a Lean executable
linking a Rust static library. The design below is the second arrangement.

## Build

Lake builds the executable. The Rust library is a Lake target that runs
`cargo build`, and Lake relinks only when the archive's contents change.

- **`supportInterpreter := true`** on the executable. It exports the
  program's symbols so that interpreted config can call compiled code.
  Without it the interpreter aborts on the first missing symbol.
- **A small glue file** in C holds what neither language can express:
  one-line wrappers where a Lean `@[extern]` signature needs `lean.h`
  (which is mostly inline functions Rust cannot call), and the entry point.
  The spike's was 133 lines.
- **The system compiler compiles the glue and links the executables**, on
  macOS and on Linux (`LEAN_CC=/usr/bin/cc`, set by the `lean` task). The
  clang bundled with Lean has no `pthread.h` on either, and on macOS its
  linker cannot link Apple frameworks. With `LEAN_CC` set Lake no longer adds
  the toolchain's library directory to the link, so the lakefile does.
  lean-fmt and the model tests are still built by the bundled compiler.

The build runs on macOS and on Linux, and the gate passes on both
(`mise run linux-ci` runs it in a container;
`docs/dev-practices/on-demand-checks.md`). Four things differ
by platform, and each has a case for those two and fails the build with a
reason anywhere else:

| | macOS | Linux |
|---|---|---|
| The entry point in place of `main` | `-Wl,-e,_editor_entry`: the loader calls `editor_entry` | `-Wl,--wrap=main`: `-e` would replace `_start` and skip the C library's start-up, so the linker renames instead. The start-up code's `main` is the glue's `__wrap_main`, which calls `editor_entry`, and Lean's `main` is `__real_main`. GNU ld and lld both have `--wrap` |
| Is this the main thread? | `pthread_main_np` | The thread whose id is the process's: `getpid() == gettid()` (glibc 2.30 and later) |
| A thread's stack size, for the check that Lean's threads have the editor's stack | `pthread_get_stacksize_np` | `pthread_getattr_np` and `pthread_attr_getstacksize`, which need `_GNU_SOURCE` |
| What the link names beyond the objects | The frameworks winit needs: ApplicationServices, CoreGraphics, CoreVideo, Carbon, CoreFoundation, AppKit, Foundation, with `-liconv -lobjc` | Nothing: winit loads the display's libraries when it runs |

On Linux the system compiler is gcc (run with gcc 14.2.0, GNU ld 2.44 and
glibc 2.41, on Debian 13, aarch64). Lake's own link line there takes
`libc++` and `libc++abi` statically from the toolchain, so the executable
needs only `libc`, `libm` and `libgcc_s` at run time, and `libstdc++` is not
involved. Not run: x86_64, and a desktop session.

**Windows has not been attempted**, and nothing here was run there. The
entry point, the main-thread check and the stack readout each need a third
case. Lean's Windows toolchain is MinGW-based, so the Rust archive would have
to be built for a `-windows-gnu` target.

**The C++ library on macOS is the system's, whichever compiler links.** It
was an open question whether linking with the system compiler, and so
against the system `libc++` in place of one bundled with Lean, could go
wrong. There is no bundled one to differ from. What Lean's toolchain ships
is a link-time stand-in whose install name is `/usr/lib/libc++.dylib`, and
`libleanshared.dylib`, which `lean` itself runs on, names that path too. An
executable linked by Lean's own clang and lld (`model-test`) and one linked
by `/usr/bin/cc` (`contract-test`) load the same `/usr/lib/libc++.1.dylib`,
one file with one UUID. So `LEAN_CC=/usr/bin/cc` changes the linker, not the
library. Checked on the tree as built: `model-test` linked both ways passes
with the same count; the gate passes; the soak benchmark's resident memory
is flat from 100 reloads to 500; and `leaks --atExit` on `contract-test` and
on the headless mode finds only what Lean's runtime allocated as its modules
initialise (big-number constants, three mutexes, regions read from `.olean`
files), nothing allocated by the glue or the Rust library, and the same
count for a script a hundred times as long.

**The app bundle is a Lake target too** (`editorApp`, not a default
target; `mise run app`). It copies the executable and the `.olean` files of
the closure of `Editor` into `Leanmacs.app`, laid out as module lookup
expects (`lean/Editor/ModuleLookup.lean`), writes `Info.plist`, with
the version from `lean/app/version` as `CFBundleShortVersionString`, the
build ID as `CFBundleVersion` and the commit as `LeanmacsCommit`, a key of
the app's own, and the icon, made from the checked-in
artwork `lean/app/Leanmacs.png`, and signs the whole bundle ad-hoc, last.
The build ID and the commit come from the environment,
`LEANMACS_BUILD_ID` and `LEANMACS_COMMIT`, which `mise run app` sets from
HEAD and CI from its run (`crates/editor-release`); a build without either,
or with one malformed, is refused, naming the variable. `editor --version`
reads the three keys back (`lean/Editor/Version.lean`). Lake's trace of
its inputs, the plist's text among them, makes it rebuild only when one
changed, so a new commit rebuilds it. It builds on macOS on
arm64 only. How to build it, what it holds and why it is signed again are
in [building.md](../dev-practices/building.md), "The app bundle".

There is no hand-written Lean start-up sequence and no scraping of
generated symbol names, which the first prototype needed. What can break on
a Lean upgrade is the `@[extern]` calling convention, the Lake build API,
and the compiler and entry-point workarounds above.

## Start-up and shutdown

1. The C entry point sets the stack size of the threads Lean creates (see
   "An exception from the interpreter ends the process") and starts a thread
   with a large stack that runs Lean's generated `main`. The real main
   thread stays in Rust and runs the window loop when Lean asks for a
   window.
2. Lean `main` creates the editor state, starts the editor loop on a
   dedicated task, and starts loading config on a background task.
3. The editor is usable before config has loaded: the compiled standard
   library provides the default keymap. Without config the spike reached
   its first event in 0.06 ms; importing the API and elaborating a small
   config took 150 to 200 ms in the background. The window mode is the
   exception since theming phase 7: when it loads config at start it opens
   its window only once that reload has finished, installed or refused, or
   after `Window.configPatience` (3 s), whichever is first. Config chooses
   the window's title bar (`titleBar .standard`, `Editor/Setup.lean`), and
   the platform cannot change a title bar under an open window (winit has
   no setter for it, and restores its own style on fullscreen
   transitions), so the choice must be known before the window exists.
   The cost is the start-up config's load before the window shows (0.17 s
   for the bundle, "What config may import, measured"); its gain is that
   the first frame is drawn in config's theme. The editor loop still runs
   from the start: the reload, an open and anything the echo area has to
   say are handled while the window mode waits. With no config, or when
   the wait runs out, the window opens with the themed title bar.

Shutdown posts a quit event, unblocks every dedicated task, and calls exit.
Returning from `main` while a task is blocked in Rust hangs.

**`editor [<file>]`, as built** (the display pipeline's last phase;
`lean/Editor/Window.lean`, `lean/Editor/Window/Real.lean`). The window mode
is the headless host's editor loop handed real collaborators: the real
display binding over a display on the system's fonts, bound to the
process's presenter, and the system clipboard, or `Clipboard.unavailable`
when it cannot be opened, which the echo area says once. Before the first
event `main` posts the open command with the file, when one was given
(with none the editor shows its one empty buffer), what the echo area has
to say, and a reload when config is loaded at start; the editor loop runs
from then on. When config is loaded at start, `main` waits for that reload
to finish, or for 3 s, and opens the window with the title bar the
installed config chose (`Window.titleBarAtOpen`), as above. Then it runs
the window on its own thread (`Ffi.windowRun`) with the editor loop on a
dedicated task; when the
loop ends, once a close request or `:q` can leave, a task waits briefly for the last
frame to be drawn and asks the window to close. Then `main` quits the
queues and exits.

- **The toolchain.** In an app bundle, an executable at
  `<bundle>/Contents/MacOS/<name>`, it is `Contents/Resources/lean/toolchain`,
  a sysroot whose modules are under its `lib/lean`. Outside a bundle Lean
  cannot run `lean --print-prefix`, which would spawn a process, so the
  toolchain's directory is an argument (`--sysroot`). With none, no config
  is loaded, and the echo area says
  `config: not loaded: no Lean toolchain given (--sysroot)`. `mise run
  edit` always gives the pinned one.
- **The editor's `.olean` files** are, in a bundle,
  `Contents/Resources/lean/editor`, and outside one
  `<directory of the executable>/../lib/lean`, where Lake puts them in the
  build tree, unless `--oleans` says otherwise.
- **Where both are found** is a pure function of the executable's path,
  read from `IO.appPath` at the edge, and of the directories the command
  line gave, each of which overrides its own default wherever the
  executable is (`lean/Editor/ModuleLookup.lean`). The bundle is known by
  its layout alone, not by a `.app` suffix. Nothing is read from the
  environment: `LEAN_PATH` is ignored, as the elaborator ignores it. It is
  pinned in `model-test` (`ModelTest.moduleLookupChecks`,
  `windowOptionChecks`, `headlessCommandLineChecks`) and run from a staged
  bundle by the gate's `bundle-test`.
- **The config directory** is `--config`, or `leanmacs` under
  `$XDG_CONFIG_HOME`, or under `$HOME/.config` when that is unset. A
  default directory that does not exist loads nothing and says nothing; a
  given one that does not exist is a rejected reload, said in the echo
  area. Reloading again is `:reload` (`reload-config`); nothing is watched.
- `main` reads the working directory, those two variables and the
  executable's path at the edge; what they mean is a pure function,
  pinned in `model-test` (`ModelTest.windowOptionChecks`).
- **Failures are said, and are status 1.** A window that cannot be opened
  is `editor: the window could not be opened: <reason>` on stderr. A
  window whose renderer cannot be made (no adapter, no device, no
  surface), or whose render thread panics, still runs, with every input
  reaching the loop and nothing drawing in it. The library knows why
  (`Session::failure`) but Lean learns it only from the run's reply, once
  the window has closed (`Ffi.WindowRan.nothingDrew`): the window mode
  then prints `editor: nothing could draw in the window: <reason>` to
  stderr, says it in the echo area if the loop is still running, and
  exits 1. While the window is open the person sees a window that never
  draws; saying so sooner would need the library to tell Lean while the
  window runs, which nothing does yet.

**Quit from a command, as built.** A command cannot end the process. It
asks (`quit`, `lean/Editor/Api.lean`), which sets a flag of the editor
state; the loop's step says stop once the editor can leave, when no buffer
that holds a file has unsaved changes and no save is in flight
([concurrency.md](concurrency.md), "Quit"); the host ends its loop, as it
does once a window's close request, a quit by the same rule, can leave;
and the executable's `main` then quits
the queues and exits, as it does at the end of a script. The headless
mode's driver sees a loop that ended by itself, stops reading its script
there, and exits with status 0
([headless-mode.md](../dev-practices/headless-mode.md)).

**The window, as built.** The main thread is parked in a small service
(`crates/editor-ffi/src/main_thread.rs`), and "run the window" is one
request of it, with which platform and how the window is opened. The main
thread then runs the window's loop to its end, so the Lean thread that asked
is blocked until the window has closed: Lean asks from its main thread or a
dedicated task, never from the pool. What the window reports arrives on the
editor queue, each event stamped with the instant the window's loop was
handed it, and a Lean loop on a dedicated task pulls it.

- **Lean closes the window.** When the user asks for it to be closed, the
  window reports that and stays open; Lean calls the close binding, the
  loop ends, and the request returns. Rust never ends the window by itself.
- **While the window runs, the main-thread service answers nothing else.**
  Requests to the window go through the window's own loop
  (`editor_ffi_window_request`: enter or leave fullscreen, minimise), never
  through the service: the request is put on the adapter's channel and the
  loop is woken, so it never blocks the Lean thread that asks.
- **The window's title is the scene's** (`Scene.title`, the selected
  buffer's name). It is published with every scene, and the library sends
  it to the window only when it changes.
- **Files Finder and the Dock open the app with arrive from the window**,
  as an `openFiles` event with their absolute paths, after `windowOpened`
  and the resize after it, never on the command line: a Finder start posts
  no open. The loop runs `open-file` with the paths, as an invocation no key
  yielded, in the focused window, and the open command opens them one after
  another, so the last path's buffer is shown last (`lean/Editor/Loop.lean`,
  "What each event does"; [rust-library.md](rust-library.md), "Files the
  system asks the app to open").
- **The window runs once in a process**, which is all winit allows.

The one thing that runs a window today is the keyboard check
(`lean/Editor/WindowCheck.lean`; `editor window-check`), which a person runs
to see that keys reach a Lean loop, and how fast.

What is built of this is the headless mode (`lean/Editor/Headless.lean`;
`editor headless [<sysroot> <olean dir>] <config dir> <script file>`): an
editor loop on a dedicated task with no window and no keymaps, which loads a
config directory in the background, runs its commands against the library,
starts its jobs and prints what happened. It exists for integration tests.
It runs the command loop (`lean/Editor/Loop.lean`): events from the window
input go to `Loop.step`, which handles each against the editor state
(`lean/Editor/State.lean`) and publishes a scene; after every other event,
a driver's request, a reload's install or a job's command among them, a
scene is published too. With no window, the display is a recorder of the
scenes (`lean/Editor/Display/Recorder.lean`), and the frame is made, 0 by 0,
at the first event from the window input, so that the texts commands make
before it keep their indices. The first load is an ordinary reload: the
loop answers events before and while it runs. The toolchain's directory
and the editor's `.olean` directory are its first two paths; from an
executable in an app bundle they may be left out, and are then the
bundle's, resolved as the window mode's are (above). Outside a bundle two
paths are refused, status 2, because there is no toolchain to use: the
headless mode never falls back to the environment or the working
directory (`lean/Editor/Headless/CommandLine.lean`).

Before its loop starts, the headless mode does what the command loop's
start-up will:

- **It warms the pool** (`Pool.warm`, `lean/Editor/Job/Pool.lean`), so the
  first burst of jobs finds every pool thread made. The pool keeps Lean's
  size ([concurrency.md](concurrency.md), "The pool").
- **It starts the completion pump** on a dedicated task
  (`lean/Editor/Job/Real.lean`), which pulls the completion queue for the
  life of the process. Quit ends it, like every pull.

Its script has a directive for each thing a driver can ask: `reload`,
`run <name>`, `spawn <name>`, `show` and `scene` (the last scene published),
two waits of the driver's own, `settle` (no reload is running) and `join`
(no job is running), and two events sent as a window would send them,
`key` and `commit`.

Rules found the hard way:

- **Module initialisers must not call the Rust library.** The `lean`
  compiler runs a module's `initialize` declarations when it compiles a
  module that imports it, where the Rust symbols do not exist, so one that
  calls a binding fails the build. A plain constant whose value calls a
  binding is not run by the compiler: it builds, and runs in the module's
  initialiser when the executable starts, so only review keeps those out
  (`lean/Editor/Ffi.lean`, "Nothing runs at initialisation"). Create library
  objects from `main`.
- **Rust objects are Lean external objects with finalisers**, never bare
  integers, so a handle cannot be used after it is freed.

## Config and reload

Lean environments are immutable and a declaration cannot be redefined. So
config is an ordered list of named chunks (in practice, files), and a reload
builds a new environment and swaps it in.

- The environment after importing the editor API is kept as a value and
  never re-imported.
- Each chunk caches the elaborator state after it. Changing chunk *k*
  re-elaborates *k* and the chunks after it.
- A reload is all-or-nothing: if any chunk fails to elaborate (including a
  theorem that no longer holds), or config's `setup` throws, the old
  environment stays.
- Scratch evaluation (a REPL) sits on top and is discarded by a reload. It
  is not built: the prototype's was not carried into the executable.

Config defines commands and a `setup` action that registers them: key
bindings, subscriptions, options. The editor runs `setup` after a successful
elaboration. Closures that config registers are stored in compiled state
(the keymap holds them) and keep working; calling a stored closure was no
slower than a compiled command in the spike.

Measured in the spike: reloading a one-line chunk takes about 2 ms, a
20-line config about 11 ms, and 50 definitions with a `simp` proof about
52 ms. Memory stayed flat over 500 reloads. `mise run config-bench` measures
the same things in the executable as built (start-up by import set, reload
time, and a soak of 500 reloads); it is run by hand and asserts nothing.

Known limits: every later chunk is re-elaborated whether or not it depends
on the change (real modules and Lean's import graph would fix this), and
compiled code cannot be swapped. A chunk has no `import` line, so Lean's own
tooling cannot check a config file by itself.

### The config session as built

The session is a pure core with two ports, and one adapter that knows Lean's
elaborator.

| Piece | Where |
|---|---|
| What config registers with: `setup`, a program over the setup port | `lean/Editor/Setup.lean` |
| Stores: a value of config's type as a plain tree with a version | `lean/Editor/Store.lean` |
| Diagnostics: failure as data | `lean/Editor/Config/Diagnostic.lean` |
| Owners: who registered or started something | `lean/Editor/Config/Owner.lean` |
| Faces: what a face looks like, as data, the built-in theme and a theme with its name | `lean/Editor/Face.lean` |
| The registry of commands, of jobs, of key bindings, of modes, of ex bindings, of faces, of themes and of mode-line segments, replaced by owner, the keymap of the bindings, a mode line resolved from a listing, and the handler that collects a `setup` | `lean/Editor/Config/Registry.lean` |
| The mode line: segments, from what a window shows to status fields; the shipped ones and their default order; a listing resolved into a mode line; and the fields of a window, selected or not | `lean/Editor/ModeLine.lean` |
| An ex line and an ex binding, as data | `lean/Editor/Ex/Line.lean` |
| What a command is run with when a key runs it: the focused window and its buffer, the arguments and the keys | `lean/Editor/Command/Call.lean` |
| The cells of the stores, and the rule that installs a config's stores | `lean/Editor/Config/Stores.lean` |
| One reload: the chunks, the plan, the build, over the two ports | `lean/Editor/Config/Session.lean` |
| The reducer that serialises reloads and installs their outcomes | `lean/Editor/Config/Reload.lean` |
| Handing a display the theme a reload installed | `lean/Editor/Config/Display.lean` |
| The elaborator port answered by Lean's elaborator | `lean/Editor/Config/Elaborate.lean` |
| The source port answered by a directory of `.lean` files | `lean/Editor/Config/Directory.lean` |
| The headless loop: the editor thread, the reload job, the output, and the command loop run against the library with a display recorder | `lean/Editor/Headless.lean` |

- **The core has no elaborator in it.** Which chunks are elaborated and from
  which cached state, all-or-nothing, when `setup` runs, replacement by
  owner, the store rule and the serialising of reloads are plain Lean with
  no `import Lean`, tested by `lake test` on hand-written fakes of the two
  ports. `Elaborate.lean` is the only module that imports Lean's elaborator,
  and `config-test` checks it, the directory source and the whole host
  against the real collaborators (`mise run ffi-test`).
- **`setup` is a program over a setup port**: `SetupM Unit`, whose requests
  carry what is registered (a command, a store, a command over a store, a
  job, a face). A request can carry an `EditorM` because the setup port is not the
  port `EditorM` runs over. After the last chunk the editor runs `setup` against
  a handler that collects its requests into a value, on the job thread.
  Nothing is registered until the editor thread installs that value, so a
  reload is all-or-nothing by construction, and a `setup` that throws is a
  program that ends in an error: the reload is rejected with its message.
  A new kind of registration is a new request.
- **One unchecked evaluation per reload.** After the last chunk the adapter
  elaborates a trailer, `def «editor.setup» : Editor.SetupM Unit := setup`,
  so the elaborator checks that config defines `setup` at the right type,
  and evaluates that one constant. A missing `setup` and one of another type
  are ordinary diagnostics; one that depends on `sorry` is an error value
  from the evaluation, and nothing runs. A config with no chunks has no
  trailer and registers nothing.
- **A command is the value `setup` registered**, not a name looked up in an
  environment. The registry holds the `EditorM` program, tagged with its
  owner, and running a command is running that program against the editor's
  port. Installing a reloaded config replaces the entries of the owner
  `config`; it never adds to them. Within one config a command name is
  registered once: a `setup` that registers a name twice is refused, with a
  diagnostic from `setup` that names the command, and the old config stays.
  The first of the two could never run, so it is a mistake in the config,
  and it is treated like a store declared twice. The number of commands a
  reload reports is therefore the number of names the config can be run by.
- **Compiled commands are entries of the same registry**, for the owner
  `compiled`, which a host registers when it starts, before any config. A
  command is looked up by its name, and the latest entry of the name is
  the one found (`Config.State.command?`): config's command of a compiled
  command's name runs in its place while it is registered, and the
  compiled one is found again once a reload drops it. The reload's report
  counts config's commands only.
- **A command may be given what it was called with**
  (`Config.Action.call`, handed a `Call`: the window it acts on, the
  invocation's arguments and its keys). Compiled code registers one as
  such, and `setup` does with `commandWith "greet" fun call => …`, a
  request of the setup port beside `command`, named as `jobWith` is
  beside `job` (built by the command loop's phase 10). A command
  registered with `command` is told nothing of its call. So a command of
  config's reads a count, and can be the command a prompt names, which
  receives the answer as its first argument; without it only a compiled
  command could read an answer. The two kinds are commands under one set
  of names: a name registered with both is refused as registered twice,
  and a reload replaces them together.
- **A key binding is data too**: `bindKey "C-c t" "two"` in `setup` binds a
  key sequence to a command's name, tagged with its owner, and a reload
  replaces config's bindings as a set and never the compiled ones. A
  sequence bound twice in one `setup` rejects the reload. Bindings are not
  counted in the report. A rejected reload changes no binding, so the
  compiled bindings, and config's of the last config that loaded, still
  run ([keymaps-and-modes.md](keymaps-and-modes.md), "Extending from
  config").
- **A mode is data too**: `defineMode { name := "listing", roles :=
  [(Role.nextItem, "bump")] }` in `setup` defines a mode (`Mode`,
  `lean/Editor/Mode.lean`), which the registry holds by owner, and a
  reload replaces config's modes as a set and never the compiled ones. A
  mode name defined twice in one `setup`, and a mode with a role that is
  not registered, a suffix used twice or a suffix that is not keys, reject
  the reload with a diagnostic that names the mode and the problem. Modes
  are not counted in the report. The active keymaps are made from the
  registry for each key, so a reload's modes hold from the next key, and a
  buffer that had a mode a reload drops keeps its name, which then
  contributes nothing ([keymaps-and-modes.md](keymaps-and-modes.md),
  "Modes").
- **An ex name is data too**: `exCommand "greet" "greet-named" (takes :=
  .text)` in `setup` binds an ex name to a command's name, with what the
  name takes after it (`Ex.Binding`, `lean/Editor/Ex/Line.lean`). The
  registry holds ex bindings by owner, and a reload replaces config's as
  a set and never the compiled ones, so config's binding of a shipped
  name runs in its place until a reload drops it. A name that is empty or
  holds white space, and a name bound twice in one `setup`, reject the
  reload. The command's name is not looked up until a line of that name
  is run. Ex bindings are not counted in the report
  ([keymaps-and-modes.md](keymaps-and-modes.md), "The ex command line").
- **A command asks for a reload.** `reloadConfig` sets a flag of the
  editor state, which the loop takes out after a command that ran to its
  end and hands back with the step; the host then feeds the reload
  reducer a request, as its driver's `reload` does. So the ex line
  `reload` is a command like any other, and the reducer's rules hold
  unchanged ([concurrency.md](concurrency.md), "Reload").
- **A job is the value `setup` registered, too**:
  `job "count" count fun n => …` registers a `Work`, the job with the
  handler that makes the command its result is taken to the editor with.
  The registry holds job entries by owner, apart from its command entries,
  and replaces them as a set. A job name is registered once in a config,
  like a command name; a job may have the name of a command. A job is not a
  command and is not counted as one: a config with one command and one job
  reports one command. `setup` starts nothing, and installing a config
  cancels the jobs of the one it replaces
  ([concurrency.md](concurrency.md), "Reload").
- **`setup` sets faces, as definitions**: `face "keyword" { foreground :=
  some (Color.rgb 200 0 0) }` sets the attributes it names of a face and
  leaves the rest. It is a registration, not a store: a store's value is
  config's own state, and a face is something the editor is told. The
  registry holds the definitions by owner, apart from the commands and the
  jobs, and an install replaces config's as a set. A name is set once in a
  `setup`; a face may have the name of a command. The theme is the theme
  in force followed by the installed config's definitions
  (`State.theme`), and a later definition of a name is over an earlier one
  by layout's rule, so a face config sets takes config's attributes over
  the theme's and one it stops setting is the theme's again. Lean merges
  nothing ([text-and-display.md](text-and-display.md), "Decorations", as
  built). A face is not a command and the reload report does not count it.
  The runtime that owns a display hands it the theme after a reload that
  installs and after a switch (`Config.retheme`): the host does, with its
  display's `setTheme`, which the recorder ignores.
- **Themes are named, and one is in force**: compiled code registers the
  themes that ship, `default` (the built-in theme) among them, and `setup`
  registers more with `defineTheme "name" theme` and names the one in
  force with `useTheme "name"`; the registry holds them by owner and an
  install replaces config's as a set. The theme in force is the reducer's
  state (`State.themeName`): an install whose config names a registered
  theme puts it in force; one that names none keeps it, so a theme chosen
  with `load-theme` survives a reload that does not name one; one that names
  a theme nobody registered keeps it and says so in the echo area, ``reload:
  no theme is registered as `<name>` ``, and on the report's lines
  (`theme: …`). `load-theme` switches it with no reload, through the
  reducer's `choose` event. Defining a theme name twice, or naming a theme
  twice, rejects the reload.
- **Segments of the mode line are named, and config lists them**:
  compiled code registers the shipped segments (`ModeLine.shipped`, the
  host's `Collaborators.segments`), and `setup` registers more with
  `defineSegment "name" fun context => …` and lists each side's with
  `modeLine ["state", "buffer"] ["position"]`; the registry holds them by
  owner and an install replaces config's as a set. The listing in force is
  the reducer's state (`State.modeLine`), set at every install, so a
  config that lists none has the default order. A listed name nobody
  registered is left out and said, in the echo area after the unknown
  theme's sentence, joined by `; `, and on the report's lines
  (`segment: no segment is registered as `<name>``). The host resolves the
  listing over the registry for each step (`Headless.keys`,
  `Loop.Keys.modeLine`). Defining a segment name twice, or listing the
  mode line twice, rejects the reload.
- **Completion styles are named, and config chooses them by category**:
  every host registers the shipped styles, `fuzzy` and `orderless`
  (`Completion.Styles.shipped`, the host's `Collaborators.styles`), and
  `setup` registers more with `defineStyle`, chooses the default with
  `useStyle "name"` and a category's with `useStyleFor "buffer" "name"`;
  the registry holds the styles by owner and an install replaces config's
  as a set, and sets config's choices (`Registry.styleChoices`), so a
  config that chooses none has the fuzzy style for every prompt. A chosen
  name nobody registered leaves its category to the default and is said,
  in the echo area after the segments' sentences, and on the report's
  lines (`style: no completion style is registered under `<name>``). The
  host resolves the choices over the registry for each step
  (`Headless.keys`, `Loop.Keys.matching`;
  [keymaps-and-modes.md](keymaps-and-modes.md), "A prompt's matching
  styles"). Defining a style name twice, or choosing a category's style or
  the default twice, rejects the reload.
- **The frame padding is config's**: `framePadding 12` sets, in whole
  points, how far every window's text and its mode line's first and last
  fields are inset from its edges, and the bottom row at least (theming
  phase 6). It is the reducer's state (`State.framePadding`), set at every
  install, so a config that sets none has the editor's 8
  (`Loop.padding`), and the host hands it to the loop for each step
  (`Headless.keys`, `Loop.Keys.padding`): a reload changes it with no
  restart. Setting it twice rejects the reload.
- **The layout is config's**: `layout (.masterStack { share := 60, side
  := .right })` or `layout .monocle` chooses how the frame's windows are
  arranged, as a value with its parameters (window-management phase 1,
  `lean/Editor/Layout.lean`). It is the reducer's state (`State.layout`),
  set at every install, so a config that chooses none has the default,
  master-and-stack with main taking half on the left, and the host hands
  it to the loop for each step (`Headless.keys`, `Loop.Keys.layout`),
  whose publish has the frame choose it before the views are laid out
  when it differs from the layout the frame last chose (`Frame.chosen`,
  `Frame.choose`): a reload that changes it applies with no restart, and
  rearranges the same windows. A publish handed the layout it last
  applied leaves the frame's, so the window commands' changes (a zoom, a
  resized share, main's count, a split tree) last until config chooses
  another layout (window management's phase 2). A loop handed none keeps
  the frame's own. `layout Layout.manual` chooses manual splits; config
  writes only a shape, which is fitted to the windows. Any layout may be
  wrapped in edges, `layout (.edge .left 25 Layout.default)`, each giving
  the windows docked at its side a strip of its size in percent (window
  management's phase 3); a choice that drops an edge moves the windows
  docked there to the end of the tiled list (`Frame.choose`), so none is
  lost. Only config adds or drops an edge. Choosing it twice, a
  master-and-stack share above 100, an edge above 100 or a side given
  twice, at any depth (`Layout.problem?`), rejects the reload. It is
  chosen as a value, not by a registered name as a theme is, until a
  command switches layouts by name. With tabs (window management's phase
  5) the frame's own fields are the tab in view's, so a reload that
  changes config's layout rearranges the tab in view, losing none of its
  windows, and a new tab takes config's layout; the other tabs keep the
  layouts they had, and selecting one never applies config's layout to
  it, since `Frame.chosen` is frame-wide. Naming a tab's layout in config
  is deferred.
- **The tab bar is config's**: `tabBar .never` or `tabBar .always` chooses
  when the tab bar is shown (window management's phase 5,
  `lean/Editor/TabBar.lean`). It is the reducer's state (`State.tabBar`),
  set at every install, so a config that chooses none has the editor's
  own, shown while there are two tabs or more, and the host hands it to
  the loop for each step (`Headless.keys`, `Loop.Keys.tabBar`), whose
  publish sets it on the state (`EditorState.tabBarShown`). Choosing it
  twice rejects the reload.
- **Display rules are config's**: `displayRule { mode := some "notes",
  target := .edge .left }` adds a rule, in order, that says where a buffer
  a command makes is shown (window management's phase 3,
  `lean/Editor/DisplayRules.lean`). At install each rule is checked against
  the layout config chose (`DisplayTarget.missing?`): a rule whose target
  does not exist, an edge the layout lacks, is left out, its sentence is in the report
  (`Report.unusableRules`, a headless `rule:` line) and the echo area says
  it after an unknown theme's and the segments', as an unknown theme is
  reported; the config is installed without it. The rest are kept in the
  registry (`Registry.displayRules`), set at every install, so a config
  that makes none clears them, and handed to the loop for each step as
  `Loop.Registered.displayRules`, which answers a command's
  `.displayRules` request (`BufferId.display`). Checking at install is
  enough because commands never add or drop an edge; a state handed a rule
  for an edge it lacks still places the buffer, in the stack.
- **The title bar is config's, at the next start**: `titleBar .standard`
  keeps the system's standard title bar in place of the themed one, whose
  paper is the theme's (theming phase 7). It is the reducer's state
  (`State.titleBar`), set at every install and published in the host's
  progress, which the window mode reads once, when it opens the window
  after the start-up reload: a reload that changes it takes effect at the
  next start. Choosing it twice rejects the reload.
- **The window's appearance follows the paper.** Once the window has
  opened, the reducer asks it for the light or the dark appearance that
  contrasts with the effective paper (`Config.Effect.appearance`,
  `Editor/Appearance.lean`), and afterwards only when a choice of theme or
  a reload changes whether that paper is light or dark. A rejected reload's first error
  is said in the echo area (`Config.Report.echo`), and its whole report is
  printed: on stdout in the headless mode, on stderr in the window mode.
- **The session runs no `IO` action from config.** A chunk is elaborated,
  `setup` is a program, a command is a program: every call from compiled
  Lean into config is a plain call of pure code.
- **A rejected reload reports diagnostics as data**: a source (the chunk's
  name, or `setup`), a line and a column, a severity and a message. A chunk
  fails when it has an error; warnings are reported and do not reject. The
  config that was loaded stays, with its commands and its stores.

### One shared state

Interpreted config and compiled code see the same values. In the spike,
compiled code wrote to a global reference and config read it, config's key
binding appeared in the compiled keymap, and a module's initialiser ran
once. This needs `supportInterpreter`, `enableInitializersExecution` before
the import, and `importModules (loadExts := true)`. Every other combination
failed loudly instead of producing a second copy.

As built (`lean/Editor/Config/Elaborate.lean`):

- **The base is imported once per process**, by the first reload job, from
  two directories it is given: the package's `.olean` directory and
  `lib/lean` under the toolchain's. Not Lean's `initSearchPath`, which also
  reads `LEAN_PATH` from the environment. A second import in one process
  about doubled its resident memory in a prototype.
- **The import runs no initialiser of a linked module.** Lean looks for a
  module's native initialiser first, and interprets a module's `initialize`
  declarations only when there is none. The adapter imports `Editor` at
  compile time, so every module of the base is linked into any executable
  that can elaborate config, and its initialiser ran once, when the process
  started. This matters twice: Lean documents initialiser execution as
  unsafe beside other threads, and the editor thread is running during the
  import. A third-party package loaded as interpreted modules would run its
  `initialize` code at import, on a job thread; that is part of the open
  question on packages.
- **Config's own code is pure**, so the state it shares with compiled code
  is what it registers and what its commands are handed: the registry, the
  store cells and the texts all live in compiled Lean. The mechanism itself
  is checked on its own: `config-test` links a fixture module with an
  initialised reference, has compiled code write to it, imports the base,
  has config write to it, and reads it back from compiled code. Each side
  sees the other's write, and the import did not reset the reference.
- **Config cannot name a binding.** `Editor` never imports `Editor.Ffi`, so
  a chunk that mentions a binding is rejected as an unknown identifier
  (checked by `config-test`).
- **Config may not declare `initialize`.** Such a chunk elaborates, but the
  interpreter throws a C++ exception the first time a declaration that
  reads the constant is evaluated, and the process aborts. This one can be
  refused before any code runs, so the adapter rejects a chunk that adds an
  `initialize` declaration, with a diagnostic that points at the store,
  which is where config keeps state.

### An exception from the interpreter ends the process

Deep recursion or a missing native symbol in interpreted code raises a C++
exception that Lean's `try`/`catch` does not see, and the process aborts.
That is left as it is. A call from compiled code into config (running a
command, a handler, a job, `setup`) is an ordinary call with no guard around
it, and the glue has no C++, no terminate handler and no signal handler.

Only a C++ `try`/`catch` could stop the exception, and it could not restore
the state from before it. The compiled Lean frames the exception passes
through are C, so they release nothing: references leak, and `finally`
blocks and lock releases do not run. A crash is safer than carrying on in
that state.

The interpreter's check fires only once its thread's stack is full, so the
stack's size is how long a runaway recursion in config runs before it ends
the process. Lean's default for each thread it creates is 1 GiB. **Every
thread Lean creates in the editor has a 64 MiB stack** instead: Lean's main
thread, dedicated tasks and the pool, so every thread that runs config or
elaborates it.

- **How it is set.** The entry point (`editor_entry` in `lean/ffi/glue.c`)
  calls the runtime's `lean_internal_set_thread_stack_size` before it starts
  Lean. The size is one process-wide value that Lean reads each time it
  creates a thread, and Lean adds 128 KiB to it. `lean.h` does not declare
  the function; Lean's own `lean` binary calls it. A toolchain that renames
  it fails the link.
- **Not through the environment.** `LEAN_STACK_SIZE_KB` set in the editor's
  own environment would be inherited by every child process, and a Lean
  language server started from the editor would get 64 MiB threads.
- **A user can change it** with `LEAN_STACK_SIZE_KB`: Lean reads the variable
  when its `main` starts, after the entry point has set the default. The
  editor adds no setting of its own.
- **Why 64 MiB.** Measured in a prototype, with recursions that returned:

  | | 16 MiB | 64 MiB | 1 GiB (Lean's default) |
  |---|---|---|---|
  | Interpreted frames before the stack check fires, at the 832 bytes a frame measured | about 20,000 | about 80,000 | about 1.29 million |
  | Time to recurse that deep | 3.7 ms for 19,000 frames | 14 ms for 70,000 frames | 191 ms for 1,000,000 frames, with resident memory up by about 950 MB |
  | Nesting depth of source the parser survives, at the 3.9 KB a level measured | about 4,000 | about 16,000 | |

  The deepest stack the elaborator used was 6.2 MB, on input it then
  rejected with "maximum recursion depth has been reached"; a chunk of 50
  definitions and a `simp` proof used 78 KB. So 64 MiB is ten times the
  elaborator's worst case, and a runaway recursion in config ends in about
  15 ms having touched 64 MiB instead of a gigabyte. 16 MiB would abort
  sooner, but leaves 2.6 times the elaborator's worst case and aborts honest
  recursion a quarter as deep; an abort ends the session, so the larger of
  the quick sizes is chosen.
- **What it costs.** Honest deep recursion is fatal sooner than under Lean's
  default: a config function that recurses 80,000 frames without a tail
  call aborts the editor where a gigabyte would have let it finish.

`ffi-test` checks the size on each kind of thread (`FfiTest.entryChecks`,
in the gate); a thread reports its own stack size, so the check aborts
nothing. `mise run ffi-overflow` shows the abort itself, under that size
(the `overflow` scenario of `lean/FfiTest.lean`). It is run on demand and is
not part of the gate, because every abort makes macOS write a crash report
on the machine.

## The editor API is an interface

Commands and jobs are written against interfaces, not against the library
bindings. Each interface has two implementations:

- **The real one**: calls the Rust library.
- **The model**: a pure Lean structure that behaves the same way (text,
  selections, a queue of pending effects). No Rust involved.

This is ports and adapters in Lean, and it gives:

- Lean tests that run under `lake test` without the Rust library.
- Theorems about commands, stated against the model: `x` then `u` restores
  the buffer; a permission policy only ever answers with an option the
  agent offered.
- The effect split from [concurrency.md](concurrency.md) enforced by
  types: `EditorM` has no blocking operations, `JobM` has no mutating ones.
- A contract check per interface: one suite of properties run against both
  the model and the real bindings, so the model cannot drift from Rust.

### An interface is a port, and a command is a program over it

Decided 2026-11-11, from prototypes of both candidates: a free-monad program
type with two interpreters, not type classes with commands polymorphic over
the monad.

- A **port** is a type of requests and, for each request, the type of its
  reply. A **program** over a port is plain data: it is finished, or it
  makes a request and continues with the reply. `EditorM` is the type of
  programs over the editor's port, a composite of the text, display and
  watch ports and the requests about the editor state ("The editor's port
  is a composite", below), and `JobM` the type of
  programs over the job port. Both are ordinary monads, and a command reads as a `do` block.
- A port has two **handlers**. The model is a pure function from a request
  and the model's state to a reply and a new state. The real binding answers
  each request with a call into the Rust library. One runner for each kind
  of handler runs any program, so the same command source runs against both.
- The contract check is a list of commands that both run.
- A theorem about a command is stated about its run against the model and
  proved from the port's lemmas.

The program type is indexed by a request type with a reply type per request.
It is not the textbook free monad over a functor, which lives in `Type 1`.

What decided it:

- **Config is evaluated at one concrete type**, and `EditorM α` is that
  type: it is the type the model runs too. With classes the concrete type is
  the real monad, over `IO`, and a command written at it cannot run on the
  model or appear in a theorem. One that can has a type in `Type 1`, which
  `evalConst` refuses, as it does the textbook free monad. A value in
  `Type 1` also cannot be the result of an `IO` action or sit in a
  reference.
- **The split is checked without any discipline.** A program holds no `IO`,
  so there is nothing to smuggle in: a text request in a job, a job in a
  command, and `IO` in either are type errors. With classes the concrete
  command monad would also need a private constructor, or a bare function
  over `IO` is accepted as a command.
- Both read the same in `do` notation, both state theorems against the
  model with the same proofs, and both are clean under every linter.

What it gives up:

- **Direct calls on the real path.** Each request allocates a program node
  and its continuation and goes through the runner: several times the cost
  of a direct call, tens of nanoseconds more, against the 6 to 12 µs a key
  takes. Binds nested to the left cost in proportion to their depth. That
  the cost stays small is assumed, not measured in the editor.
- **Library handles as values in the interface.** A request is plain data,
  so a text or a snapshot is named by an id and the real binding keeps the
  tables from ids to handles. A text or a snapshot lives until a command
  releases it or the table is dropped, not until the last Lean reference
  goes: a snapshot a command takes and does not release stays in the table.
  A released id is refused for good, and an id is never used again.
- **A subscription as a thing the store holds.** A consumer that follows a
  text's edits is not registered anywhere: a subscriber is a revision the
  caller keeps and asks from again. So no request makes or releases one,
  and a caller that loses its revision has lost its place: it reads the
  text whole and starts from the revision it has then.
- **A request that carries a program over its own port** (a key binding
  made from inside a command): the port would refer to itself. Registration
  from a later port type-checks, and that is what the config session does:
  `setup` is a program over a port of its own. A job's result handler needs
  neither that nor a program type written for the editor: a job finishes
  with a command, the handler already applied to its result, so the type of
  the result stays inside the job and no request carries a handler.
- **A command's type no longer lists the capabilities it uses.** Every
  command has the whole port.

Set aside: a concrete `EditorM` that reads a record of operations over `IO`
(the model's state is then behind a reference, so no theorem about a command
can be proved). Left open as a later step, if the runner's cost becomes a
measured problem: classes for compiled commands, with the program type as
the instance config uses. Commands written at `EditorM` would not change.

The pattern is built for one deliberately small interface, text:

| Piece | Where |
|---|---|
| Programs, and the two runners | `lean/Editor/Program.lean` |
| The text port: create, insert, delete, read; `snapshot`, which takes a text as it is now; `ask`, which puts a question to a text or a snapshot (its revision, length, row count or contents; the point of an offset and the offset of a point, in bytes, in UTF-16 or in cells; the content of one row and the text of a range; and where a motion leads from a position, with the motion a value of an inductive, so that a new motion is a constructor and not a question); `release`, which gives either up; `apply`, which applies a transaction, built by a command as plain data, with an origin, and replies with the revision it produced; `log`, which puts a question to a text's edit log (what changed since a revision, as one patch; who wrote a range); `forget`, which moves where that log starts; and `mark`, `marker`, `place` and `unmark`, which have a text hold an anchor or a selection that every edit moves, read it back, put another in its place, and give it up; and `applyInverse`, which applies the inverse of a run of a text's revisions as one edit, where the text is in the state the run ended in, and replies with the revision it produced and the selection to place, and `dropInverses`, which drops the inverses a text keeps for a run; `copy`, which makes a new text of what a text or a snapshot holds, at revision 0 with an empty log, no markers and no kept inverses; and `adopt`, which takes into the store a snapshot a job held, named by a second kind of id (`JobSnapshotId`) and answered from what the command's run was handed, so that an id the run was not handed is refused. `ask` also carries what a selection covers. A new question is data, a constructor of the query, not a request | `lean/Editor/Text.lean` |
| Its pure model: a string and a revision for each text, a snapshot as a copy of that pair, and points found by walking characters. A transaction's changes are applied as the ranges they change. The log is modelled beside the texts, not inside them, as who wrote every byte and the text at every revision, so the model finds a patch and a trace by a different route from the library's. Markers are a table beside the texts too, moved through the ranges an edit changed, and what a selection covers is read off the string's rows and characters. A motion is picked from a list of every cell start or every word of the string, where the library walks from the position; and two theorems are stated about the conversions, that one that answers is undone by the other and that the line start of a line start is itself. The model keeps no inverse: beside the texts it keeps, for each, the name of the state it was in at every revision, the selections each edit carried and which inverses were dropped (its history). The text an inverse leaves is read off the log's model, and what it changed is the gaps between the bytes the two states share, by the identities the bytes had when the run ended; the library composes the inverses it kept. What a job held reaches its command as a value the run is handed, which `adopt` reads | `lean/Editor/Text/Model.lean` |
| Its real binding, over the text-storage crate (`editor-text`): a table of documents and one of snapshots. The snapshots are a table behind a reference that the binding publishes and alone writes, in a command, on the editor thread; a reader off that thread is given its read half and nothing else. The documents are a value the editor thread owns. A run of a finished job's command is handed the library's snapshots the job held. A question about a text is answered from a snapshot taken for it; a transaction, a question about the log and a marker go to the document, which holds the markers: the binding keeps no table of them, and a marker's id is its text's id with the document's number for it, so that a text refuses another's. The kept inverses are the document's too, with no table here: a run is two of the text's own revisions. A transaction, a patch, a trace, a marker, extents and what an inverse did are lists, which cross the boundary as words, a buffer of 64-bit numbers that a codec on each side writes and checks | `lean/Editor/Text/Real.lean`, `lean/Editor/Ffi.lean` |
| Its contract, run against the model by `lake test` (`mise run lean-test`) and against the real binding by `contract-test` (`mise run ffi-test`) | `lean/Editor/Text/Contract.lean` |
| A command, `append`, with a theorem about it | `lean/Editor/Command/Append.lean` |
| The undo tree: logic above the port, in plain Lean that imports the port alone. It is told the text's revision, sets the boundaries of groups, undoes, redoes and moves between branches by `applyInverse`, drops what it has crossed by `dropInverses`, reverts the open group, and tracks the state last saved, with a theorem that a boundary does not change whether a text is modified | `lean/Editor/UndoTree.lean` |
| Its cases, one list of the text contract's kind of property, run against the text model by `lake test` and against the real binding by `contract-test`: the first logic above a port that runs on both | `lean/Editor/UndoTree/Cases.lean` |
| `JobM`, and the compile-time checks of the split | `lean/Editor/Job.lean` |

The job port is the second interface built this way, and the first whose
real implementation is not one call a request:

| Piece | Where |
|---|---|
| The job port: a clock and a wait; `sleep`; `Timer`; the file requests, `File.load`, `File.save`, `File.stamp` and `File.list` (a directory's entries, sorted by name, each with its kind), whose replies are a result or a refusal, a value; the file-watch requests, `FileWatch.start`, which watches a file, a directory's entries or a directory's tree and replies with the watch, named for the job, or a refusal, and `FileWatch.next`, which waits for the watch's next delivery; `Work` | `lean/Editor/Job.lean` |
| The file requests as data: a stamp, line endings and the dominant one, what a save expects, a save's source (a snapshot a command took or one the job loaded), what a load answers, a directory's entry and its kind, and the refusals with what each says | `lean/Editor/File.lean` |
| The pure model of the files a job reaches: directories, files with their bytes and stamps, a count of writes for a clock, the snapshots the editor published and those the job's loads made. It answers by the library's rules and its own route: a file's text is decoded a character at a time, each byte that starts no valid character becoming its escape | `lean/Editor/File/Model.lean` |
| The file-watch requests as data: a target (a file, or a directory, recursive or not), the coalescing (a window and a bound, the job's policy, with no default), the watch's id, a change (an absolute path and its kinds: created, written, renamed, removed, missed) and the refusals with what each says. The module docs carry the rules and where an addition goes; a `stop` request is listed there as not built. It imports nothing. It is not the interrupt flag's port, `lean/Editor/Watch.lean`, which is `Watch`: this one is `FileWatch` | `lean/Editor/FileWatch.lean` |
| The pure model of what a job's watches see: the directories there are, the watches with their changes recorded, what each command a test expects changes on disk, and the watches ended. It routes a change as the library's service does, records it by the library's coalescing rule, bound and collapse included, and answers a `next` at the window from the first change, moving the clock there | `lean/Editor/FileWatch/Model.lean` |
| Its pure model: a clock, the instant the job is cancelled at, the model of files, the model of processes, and the model of watches, which a command a job runs touches when the run ends | `lean/Editor/Job/Model.lean` |
| Its contract: the clock's properties, run against the model and against the runner over the fake clock by `lake test`, and against the runner over the timer service by `contract-test`; and the file properties, each the files to start with, a job, and every file that must be there afterwards, run against the model and the runner over the fake file service by `lake test`, and against the runner over the library's file service, on real files in a temporary directory, by `contract-test` | `lean/Editor/Job/Contract.lean` |
| The runner, on plain tasks and promises: the table of waits, the clock port and the file port (`Files`), `spawn`, cancellation, and what a job holds: the snapshots its loads made, which a job's handle lists, which no other job can save, and which `settle` releases | `lean/Editor/Job/Runner.lean` |
| The clock port's fake, which a test moves by hand, and the file port's (`FakeFiles`): the model of files behind a reference, whose completions and takes a test can hold | `lean/Editor/Job/Fake.lean` |
| The clock port over the Rust timer service; the file port over its file service (`realFiles`), which keeps what a load made for its job (`HeldSnapshots`) and reads a snapshot a command took through the read half of the published table; running a finished job's command with what the job held handed to it, then settling the job (`finishWith`); and the completion pump | `lean/Editor/Job/Real.lean` |
| The cases that cross the text port and the job port: a command, a job, the job's command and a last command, played on the two models by `lake test` and on the real binding and the file service by `contract-test`. A file a job loads becomes a text, and a save that reports late marks the undo tree's state it wrote | `lean/Editor/File/Cases.lean` |
| The job table, pure, and the shell the editor thread calls | `lean/Editor/Job/Table.lean`, `lean/Editor/Job/Jobs.lean` |
| Warming the pool | `lean/Editor/Job/Pool.lean` |

The display interface is the third. Its real binding is not built here: it is
the display pipeline's, which holds it to the same contract:

| Piece | Where |
|---|---|
| The scene, plain data published after a command: views by handles (a snapshot, markers), faces by name, the echo text, the pending prefix and the preedit | `lean/Editor/Scene.lean` |
| The display port: `publish` a scene, and two layout queries answered in the same call, the rows a view shows from its anchor (`rowsShown`) and the position some visual lines away with the goal x passed back (`linesFrom`); `DisplayM`; the cell size the contract runs at (`Display.Cells`) | `lean/Editor/Display.lean` |
| Its pure model: the scenes published, in order, and a layout in fixed-size cells, in which a tab reaches to the next multiple of 8 cells and a wide character is two, for tests, and for the recorder below | `lean/Editor/Display/Model.lean` |
| Its contract, imported from the port alone: properties of the two queries at a cell size, run against the model by `lake test` at two sizes, against the recorder over the library's snapshots by `contract-test` at the same two, and to be run against the real binding over a fake shaper whose glyphs have that size | `lean/Editor/Display/Contract.lean` |
| The display where there is no window (the headless host): a recorder that keeps the last scene published and how many have been, and answers the two queries with the model's layout rule over the text of the library's snapshot, read through the published table's read half. It is the one place the model's rule runs outside a test, because a host with no window has no layout to ask; an editor with a window asks the real binding every time | `lean/Editor/Display/Recorder.lean` |
| The events of the editor queue as plain data (a key with its logical and physical identity and modifiers, a pointer, a resize, files to open), and the one module that reads and writes their layouts on the queue | `lean/Editor/Event.lean`, `lean/Editor/Event/Queue.lean` |

The runner is the job port's real handler. It is not a function from a
request to an `IO` reply, as the text port's is, because a job must hold no
thread while it waits: the runner answers a wait by registering a promise
and chaining the rest of the program on it
([concurrency.md](concurrency.md)). The model runs the same program to its
end in one call, with the clock moved by each wait.

That a wait is not a command is checked when `lean/Editor/Job.lean` is
compiled: a wait offered at `EditorM Unit`, or at `TextM Unit`, is a type
error, alone and after a text request in a `do` block. So "a command may not block" is pinned
beyond `IO`. Each of the two checks was seen to bite once by hand: offered
at `JobM Unit`, where a wait is legal, the module stops building. The same
module checks that a file request is a job and not a command, and that
`adopt` is a command and not a job: the one request that writes the text
store from what a job made cannot be written in a job. Each of those was
seen to bite once the same way.

A file request is the first request whose wait has a reply. A completion
says only that a wait is over, so the runner fetches the reply from the
service afterwards, on the job's thread, and never for a job that was
cancelled.

### The editor's port is a composite

Decided 2026-11-13, by the command loop's phase 2; the state requests were
added by its phase 8. A command reaches the text, the display, and the
editor state's buffers and windows through one port, whose shape is:

- **Its requests are a sum of sub-ports**, one constructor a sub-port:
  `EditorRequest.text` carries a request of the text port,
  `EditorRequest.display` one of the display port, `EditorRequest.watch`
  one of the watch port, `EditorRequest.clipboard` one of the clipboard
  port, `EditorRequest.fuzzy` one of the fuzzy port,
  `EditorRequest.syntaxTree` one of the syntax tree port
  and `EditorRequest.state` a request about the editor state: seven
  sub-ports. The reply to each is its sub-port's reply. `editorPort` is
  an `abbrev`, as every port is.
- **The fuzzy port** (`lean/Editor/Fuzzy.lean`, added by the command
  loop's phase 14) is what the editor asks of a fuzzy matcher:
  `rank pattern candidates` answers the indices of the candidates the
  pattern matches, best first, each once. It refuses nothing.
  - **What matches** is one rule: the pattern's Unicode scalar values all
    occur in the candidate, in order, with case kept. A Lean `String` is
    a list of scalar values, so the model (`FuzzyModel.matches`) is a
    subsequence test and needs no table. That is what lets the model and
    the library agree on every input
    ([rust-library.md](rust-library.md), "Fuzzy matching, as built").
  - **The order** an asker may rest on is one thing: a candidate that is
    the pattern is first. After those the model's order is the
    candidates' own and the binding's is the library's scores.
  - **The contract** (`lean/Editor/Fuzzy/Contract.lean`) asks those two
    things and no more: which candidates match, on a table of cases
    compared with the reply sorted, and that an exact match is first,
    which reads the first index only. `lake test` runs it on the model
    and `contract-test` on the real binding. **The known gap**: the two
    are not held to agree on the order past the exact matches. So logic
    above the port is tested on the model, and a check of it computes
    what it expects with `FuzzyModel.rank` and never writes an order out.
  - **How the two sides are held together.** The Lean model and the Lean
    binding by this contract. The Rust fake and the library's adapter by
    the Rust port's contract, which also sweeps generated texts. The
    binding is the Rust ranking rule over that adapter. So the model
    cannot drift from the library without one of the two contracts
    failing.
  - **As a sub-port**: `Fuzzy.rank` is used in a command as it is, and
    config can call it. On the models it is answered by the fuzzy model,
    which has no state, and moves the watch model's clock, as every
    request that reaches the library does. Against the library it is
    answered by `Fuzzy.real`, one call, as a text request is by the text
    binding: the matcher needs nothing a host could hand in, so no runner
    takes a handler for it and no host changed. It is guarded like any
    request that is not the state's.
  - Set aside: a function handed to the loop. The loop's publish and a
    command would then reach the matcher two ways, and config not at
    all.
- **The syntax tree port** (`lean/Editor/SyntaxTree.lean`, made a sub-port
  by the syntax roadmap's phase 2) is what a command and a major mode ask
  of the library's syntax service: grammars, attaching and detaching a
  text, queries, a grammar's shipped query, drawing a text with a query's
  captures in faces, its injections and the languages they may name, and
  keeping a query of a structural kind (text objects, indents) whose
  captures are asked by kind (made by the syntax roadmap's phase 3). **Its refusal is a value**: `SyntaxTree.lift`
  runs a syntax tree program in a command and hands back its `Except
  SyntaxTreeError`, which the command matches on, as the clipboard's is, so
  the editor's error type is not widened. Its result type is not the
  program's, so it is no `MonadLift` instance and a command calls it by
  name. On the models it is answered by the syntax tree model, whose texts
  are filled from the text model's snapshots and which tells two snapshots
  of one text from two texts by the text each was taken of, and each
  request moves the clock by a pace. For real it is answered by the
  handler a runner is handed (`SyntaxTree.none`, with no grammars, by
  default): a host makes one over the table of snapshots its text binding
  publishes, once as its loop starts (`Collaborators.syntaxTree`,
  `Running.syntaxTree`), and hands it to every command it runs, a finished
  job's through `Job.finishWith` too. A syntax tree request is guarded like
  any request that is not the state's, and what it did is not undone on
  rollback: the library parses and draws outside the editor state. What
  setting a major mode with a syntax tree asks of it is
  `lean/Editor/Highlight.lean`'s ([keymaps-and-modes.md](keymaps-and-modes.md),
  "A buffer's modes").
- **The clipboard port** (`lean/Editor/Clipboard.lean`, added by the
  command loop's phase 13) is what a command asks of the system
  clipboard: the text it holds, and to hold another. The clipboard is
  outside the editor, written by other programs and not rolled back with
  a command, so it is a port and not editor state. **Its refusals are
  values**: a clipboard may not be there, and each request is then
  answered `unavailable`, an `Except` in the reply, as a state request's
  refusal is. Nothing is thrown, so a clipboard program has no error of
  its own (`ClipboardM`) and the editor's error type is not widened. It
  has a pure model (`ClipboardModel`, which a test can take away), a
  contract every implementation runs, and a stand-in for a host with no
  window, a cell of the process that answers with the model's rule
  (`Clipboard.InProcess`), which is the display recorder's twin. The
  adapter to a window system's clipboard is the display pipeline's, and
  runs the same contract when it is bound. A clipboard request is guarded
  as a text request is, and moves the watch model's clock.
- **The watch port** (`lean/Editor/Watch.lean`, added by the command loop's
  phase 6) is what the loop watches a command with: whether the interrupt
  flag is up, lowering it once, and the job clock in milliseconds. It is a
  sub-port, and not checked by the host, so that the loop stays one pure
  program that runs the same on the models and against the library: the
  loop asks the flag before each request of a command it runs
  ([concurrency.md](concurrency.md), "Foreground: commands"). A flag check
  inside each handler could not say "stop" for a request whose reply has
  no refusal, and a host that ran a step in pieces would be a second
  driver for the models that could drift. The clock is here and not in a
  sub-port of its own because each sub-port costs a constructor, an
  embedding and a case in each runner. Nothing on it is refused. It has
  nothing to do with watching files, which is the job port's `FileWatch`
  (`lean/Editor/FileWatch.lean`), named so that this port keeps its name.
- **A command is `EditorM := ExceptT TextError (Program editorPort)`.** A
  program over the text port alone is `TextM`, and every text operation and
  all logic over text alone (the undo tree, the text contract, `append`)
  stays at it; the display's is `DisplayM`, the watch port's `WatchM` and
  the clipboard's `ClipboardM` and the fuzzy port's `FuzzyM`.
  `TextM.lift`, `DisplayM.lift`, `Watch.lift`, `Clipboard.lift` and
  `Fuzzy.lift` embed each in a command,
  and they are `MonadLift` instances, so an operation of any sub-port is
  used in a command as it is. That is why every config source and fixture written before the port
  became a composite elaborates unchanged. There is no lift from `JobM`, so
  a job is still not a command, which `lean/Editor/Job.lean` checks at
  `TextM` and at `EditorM`.
- **A refusal is a `TextError`.** The display's two refusals mean what the
  text port's of the same names mean (a snapshot that names nothing, an
  offset that is not a position), so the display's lift maps each to its
  namesake. Widening the error to a sum now would break every config that
  throws a text refusal, and nothing needs it yet. The first sub-port whose
  refusal has no `TextError` counterpart widens it, in its own phase. The
  state requests did not: what the editor state refuses (a window that
  would be the last, a buffer a window shows, a mode or a job no one
  registered) is a **value**, an `Except` in the request's reply, which a
  command matches on. Nothing is thrown for it, so a command's error is
  still a `TextError`, and a layout operation's refusal keeps its type.
- **A runner's state is the product of its sub-ports' states**, but for
  the editor state, which is the loop's (below). On the
  models it is the text model, the display model, the watch model and the
  clipboard model side by side (`EditorModel`); before each display request the display model's
  texts are filled from the text model's snapshots, so a command that takes
  a snapshot and asks the display about it is answered from that
  snapshot's text. On the models time passes only with requests: the watch
  model's clock moves on by its pace at each text and display request, and
  a test has an interrupt key arrive at a command's n-th request. For real
  it is the text binding's table, with a display handler (`DisplayHandler`)
  passed in: the recorder in a host with no window, the display pipeline's
  binding in one with a window; and a watch handler (`WatchHandler`),
  `Watch.real` over the library's flag and the job clock in a host, and
  `Watch.idle`, never interrupted, by default; and a clipboard handler
  (`ClipboardHandler`), the in-process clipboard in a host with no window,
  and `Clipboard.unavailable`, which answers every request so, by default.
- **The state requests are the loop's to answer.** Built by the command
  loop's phase 8 (`lean/Editor/State/Request.lean`,
  `lean/Editor/Command/Dispatch.lean`). A state request's handler is one
  pure function over the editor state (`EditorState.handle`), as a store
  is: no Rust, no model and no contract check. This section first had both
  runners' state gain the editor state. What was built instead: the
  command loop keeps holding the editor state, and answers the state
  requests of each command it runs in place, by a pure transformation of
  the command's program (`EditorM.dispatched`), before the program reaches
  a runner. The reasons:
  - the loop is the one writer of editor state
    ([concurrency.md](concurrency.md)), and stays so;
  - rolling a failed command back stays "keep the state from before it";
  - the handler is the same function on the models and against the library
    by construction, since it runs above both runners;
  - the loop, and every test that builds one, is as it was.

  A runner still answers every request of the port. Each answers a state
  request that reaches it as an editor with no buffer and no window would
  (`EditorState.none`), and keeps nothing: a command run where no loop
  dispatched it finds nothing. Every command a host runs goes through the
  loop; only a test runs one bare. A split of the port into one for
  commands and a smaller one for runners, which the types would then check,
  was set aside: it would rename the loop's monad and every call that runs
  a command on the models.
- **A request holds plain data.** A state request names a mode and a job;
  it cannot hold the mode's on-enter action or the job, which are programs
  over this port ("A request that carries a program over its own port",
  above). The loop is told what the names stand for (`Loop.Registered`,
  made by the host from the registry for each step), and answers those two
  requests with it: it refuses a name no one registered, runs a mode's
  on-enter actions inside the command, and hands the jobs a command asked
  for back to the host to start.
- **Where it grows.** A new request about the editor state is a constructor
  of `StateRequest` and an operation of `lean/Editor/State.lean`
  (`lean/Editor/State/Request.lean`, "Where an addition goes"). A new
  sub-port is a constructor and a lift. A new question about text or
  layout stays inside its own sub-port and changes nothing here.

| Piece | Where |
|---|---|
| The composite port, `EditorM`, the six embeddings and lifts (the syntax tree's handing its refusal back as a value), and the mapping of the display's refusals | `lean/Editor/Command.lean` |
| The fuzzy port: its one request, which refuses nothing; `FuzzyHandler` | `lean/Editor/Fuzzy.lean` |
| Its pure model, with no state: a subsequence test, and the candidates that are the pattern first | `lean/Editor/Fuzzy/Model.lean` |
| Its contract, imported from the port alone, run against the model by `lake test` and against the real binding by `contract-test` | `lean/Editor/Fuzzy/Contract.lean` |
| Its real binding: one call into the library | `lean/Editor/Fuzzy/Real.lean` |
| The syntax tree port, a sub-port of the editor's: the grammars, attaching a text to a grammar, a query compiled, its capture names and its captures in a range, a grammar's shipped query, and a text highlighted with a query in faces, each refusal a value; `SyntaxTreeHandler`; `SyntaxTree.none`. Named `SyntaxTree`, since `Syntax` is `Lean.Syntax` wherever `Lean` is open and `Grammar` an input scheme's | `lean/Editor/SyntaxTree.lean` |
| The capture-to-face rule and what setting a major mode with a syntax tree asks of the port | `lean/Editor/Highlight.lean` |
| The language table, the rule that chooses a path's language, and the `code` mode, whose tree is its buffer's language's | `lean/Editor/Language.lean` |
| Its pure model: one grammar, a parser of a subset of JSON that builds the tree `tree-sitter-json` builds, a subset of the query language, and the Rust core's rule for a range; it parses at once, so it answers `notParsed` only when a test says its trees are not delivered (`delivered`) | `lean/Editor/SyntaxTree/Model.lean`, `Model/Json.lean`, `Model/Query.lean` |
| Its contract, imported from the port alone, run against the model by `lake test` and against the real binding by `contract-test`, whose runner waits for a snapshot's tree to be delivered before each question of captures | `lean/Editor/SyntaxTree/Contract.lean` |
| Its real binding: one call into the library a request, over the read half of the text binding's table of snapshots and a table of its own of the queries it compiled; a face crosses as its name, none as the empty string | `lean/Editor/SyntaxTree/Real.lean` |
| The clipboard port: its two requests, each refused as a value; `ClipboardHandler`; `Clipboard.unavailable` | `lean/Editor/Clipboard.lean` |
| Its pure model: the text held, and a clipboard a test takes away | `lean/Editor/Clipboard/Model.lean` |
| Its contract, imported from the port alone, run against the model by `lake test` and against the in-process clipboard by `contract-test` | `lean/Editor/Clipboard/Contract.lean` |
| The clipboard where there is no window (the headless host): a cell of the process that answers with the model's rule | `lean/Editor/Clipboard/InProcess.lean` |
| The state requests and their pure handler: one read of the whole state, and a request a write (a buffer, its history, values and modes; a window; the echo; a job to start), each refused with a value | `lean/Editor/State/Request.lean`, over the operations of `lean/Editor/State.lean` |
| A dispatched command: its state requests answered from the loop's state, every other request guarded, so that it stops at its next one once the flag is up, a major mode's on-enter actions run inside it; `Guarded`, how it ended; and `Loop.Registered`, what the loop is told of the registry. The guard has this one definition | `lean/Editor/Command/Dispatch.lean` |
| The composite's model runner, over the five models side by side, and the fuzzy model, which has no state | `lean/Editor/Command/Model.lean` |
| The composite's real runner, over the text binding, a display handler, a watch handler, a clipboard handler, a syntax tree handler and the fuzzy port's real binding | `lean/Editor/Command/Real.lean` |
| `DisplayHandler`, and running a display program against one | `lean/Editor/Display.lean` |
| The watch port: the interrupt flag, lowering it, and the clock; `WatchHandler`; `Watch.idle`; the interrupt key, `C-g` | `lean/Editor/Watch.lean` |
| Its pure model: the interrupt keys that arrived, one that arrives at a command's n-th request, and a clock with a pace | `lean/Editor/Watch/Model.lean` |
| Its contract, imported from the port alone, run against the model by `lake test` and against the real binding by `contract-test` | `lean/Editor/Watch/Contract.lean` |
| Its real binding, over the library's interrupt flag and the job port's clock | `lean/Editor/Watch/Real.lean` |
| What the model runner does with each sub-port, pinned | `ModelTest.commandPortChecks` |

### The editor API

Built by the command loop's phase 8 (`lean/Editor/Api.lean`, whose module
docs have each operation's rules). It is what a command is written with
beyond the text port's own operations: programs over the composite port,
made of state requests and text requests. Config sees it through
`Editor.lean`.

| A command can | With | Reaches the library |
|---|---|---|
| Read the editor state: its buffers, windows, focus, a buffer's values and modes | `editorState`, then pure functions over it (`buffer?`, `target?`, `findBuffer`, `value?`) | No |
| Make, find and remove a buffer | `createBuffer`, `addBuffer`, `findBuffer`, `BufferId.remove` | To make the text and read its revision |
| Read a buffer | `BufferId.text`, then the text port's reads (`read`, `rowContent`, `slice`, …) | Yes: the text port's own requests |
| Insert and delete at positions | `BufferId.insertAt`, `BufferId.deleteRange`, over `TextId.replaceRange` | Yes: `apply`, with the user's origin |
| Insert at a view's selections, delete what they cover, read and place them | `ViewId.insertAtSelections`, `deleteSelections`, `selection`, `select`, and the same on a `Target` | Yes: `apply` carrying the selection before and the cursors after, and the marker requests |
| Close the undo group, undo and redo, each move handing back the selection to place | `BufferId.closeGroup`, `undo`, `redo`, over the buffer's undo tree | Yes: `applyInverse` and `dropInverses`, the undo tree's own; no new library call |
| Split, close and focus a window, and show another buffer in one | `ViewId.split`, `close`, `focus`, `show` | To mark the new window's markers |
| Set and read a buffer-local value; set the major mode, add and remove a minor mode | `BufferId.setValue`, `value?`, `ViewId.setMajorMode`, `BufferId.addMinorMode`, `removeMinorMode` | No |
| Keep a view's wanted column, the column its vertical motions aim for, with the offset the cursor was left at; read it from the view's window in the state, as it is when the command asks | `ViewId.setWanted`; `Window.wanted`, of `EditorState.window?` on `editorState` | No |
| Say something in the echo area | `message` | No |
| Start a job, with arguments | `startJob`, for a job registered with `jobWith` or `job` | No: the host starts it once the command has ended |
| Break a line with the buffer's line ending, and ask whether a buffer is modified | `ViewId.insertLineBreak`, `Target.insertLineBreak`; `BufferId.isModified` | Yes: `apply`, and the text's revision |
| Open a file into a buffer and save a buffer to its file | `Files.open`, `Files.save` (`lean/Editor/Files.lean`), each of which starts a compiled job | For the snapshot a save writes; the file is the job's to load or save |
| Ask for a string, without waiting for it, and accept or cancel the open prompt | `prompt label continuation initial`, which names the command that receives the answer as an invocation; `acceptPrompt`, `cancelPrompt` | To make the minibuffer's text and its markers, and to read the answer; a cancel reaches nothing |
| Ask with candidates the answer may be chosen from, replace an open prompt's, and move a choice through the ones it has listed | `prompt … (sources := …)`, where each source (`lean/Editor/Completion.lean`) is given as a value or named, and is a program over the editor's port that `prompt` asks once, a named one run by the loop; `setCandidates`; `chooseCandidate step`; config registers a source with `defineSource`. Accepting gives the continuation the chosen candidate, and the typed text when nothing is chosen ([concurrency.md](concurrency.md), "Prompts") | Whatever the sources ask; `setCandidates` and `chooseCandidate` reach nothing. The listing is the loop's, made before each scene |
| Which candidates a pattern matches, best first | `Fuzzy.rank pattern candidates`, the fuzzy port's own, lifted | Yes: one call, which keeps nothing in the library |
| Which ex names are bound | `exNames`, answered by the loop from the registry | No |
| Ask which command an ex name is bound to, and what the name takes | `exBinding name`, answered by the loop from the registry as it is at that step | No |
| Have another command run after it, as a step of its own | `invoke invocation` | No: the host runs it once the command has ended |
| Have the command registered under a name run inside it, as part of it, and learn whether there was one | `runCommand name call`, answered by the loop from the lookup a key's invocation goes through ([concurrency.md](concurrency.md), "Prompts") | Whatever the command run makes |
| End itself with a reason, rolled back, with the reason in the echo area | `giveUp reason` ([concurrency.md](concurrency.md), "Foreground: commands") | No |
| End itself with a reason and keep what it did, with the reason in the echo area and the input scheme back at rest | `breakOff reason` ([concurrency.md](concurrency.md), "Foreground: commands") | No |
| Keep a register, a text and whether it is line-wise, under a name, and read one | `setRegister name register`; `EditorState.register?` on `editorState` | No |
| Replace one extent in an edit that carries the two selections it is handed, the one from before the command and the one it leaves | `Target.replaceCarrying`, over `TextId.replaceCarrying` | Yes: `apply`, with the user's origin, and the marker |
| Read and write the system clipboard, each refused as a value | `Clipboard.read`, `Clipboard.write`, the clipboard port's own, lifted | No: the clipboard handler the host hands in |
| Ask the editor to quit; refused, as a value, while a buffer that holds a file has unsaved changes | `quit` | For the revision of each buffer that holds a file |
| Ask for the config to be reloaded | `reloadConfig` | No: the host asks its config session once the command has ended |
| Read and place its window's scroll anchor | `Target.anchor`, `Target.scrollTo` | Yes: the marker requests. Placing a marker is no edit |
| Ask the display about its view: which rows it shows, and where a position goes by visual rows | `Target.onArea run`, which hands `run` a snapshot of the buffer's text, taken there and released when `run` has ended, and the view's rectangle; then the display port's two queries, and the scroll policy over them (`lean/Editor/Scroll.lean`) | Yes: a snapshot and its release, and the display's queries |
| Set the scroll margin, the rows every view keeps round its cursor's row, and read it | `setScrollMargin rows`; `EditorState.scrollMargin` on `editorState` | No |

- **Edits go through `apply`**, as one transaction made by the user
  (`Origin.user`): one revision, one entry of the edit log, and one step
  for the buffer's history to be told of.
- **A refusal of the state is a value** (above); what the text store
  refuses is thrown, as everywhere in `EditorM`.
- **Giving up is the loop's.** A request that closes a window or removes a
  buffer changes the state alone. The loop gives up the window's markers
  and releases the buffer's text once the command has run to its end
  (`lean/Editor/Loop.lean`, "What a finished command gave up"), so a
  command that fails afterwards is rolled back whole.
- **The contract check.** Every operation that makes a request of the
  library has a case in `lean/Editor/Api/Cases.lean`: a command, played as
  the loop plays one, on the editor's models by `lake test` and on the real
  text binding by `contract-test`. An operation over Lean state alone has
  its one implementation, the state requests' handler, and is pinned once,
  on the models (`ModelTest.stateRequestChecks`,
  `ModelTest.apiStateChecks`).
- **Proved on the text model** (`lean/Editor/Api/Theorems.lean`):
  inserting a string at a character boundary and deleting the range it
  occupies leaves the text's contents as they were
  (`replaceRange_insert_delete`), from `TextModel.splice_insert_delete` and
  `TextModel.applyChanges_replacing` (`lean/Editor/Text/Model.lean`). The
  theorems are in a module of their own so that the API imports no model.
- **Files are commands over the API, not requests of the port**
  (`lean/Editor/Files.lean`, built by the command loop's phase 9). A
  command cannot wait, so opening and saving are each a command that
  starts a job and the command the job finishes with
  ([concurrency.md](concurrency.md), "Getting results back"). What they
  needed of the state is three requests: one that attaches a file to a
  buffer, and two that begin and end a save in flight. The jobs are
  compiled, registered beside the commands
  (`lean/Editor/Files/Compiled.lean`), which is the one module of the two
  that names the registry: config sees the commands through `Editor.lean`
  and not the registrations.
- **A prompt is a request and a named command, not a wait** (built by the
  command loop's phase 10; [concurrency.md](concurrency.md), "Prompts").
  A command cannot wait for an answer, and a request of the editor's port
  cannot carry the program that would receive it ("A request that carries
  a program over its own port", above). So `prompt` names the command
  that receives the answer, as an invocation, and returns at once; the
  open prompt is editor state; and accepting is one state request that
  closes the prompt and records the invocation with the answer as its
  first argument, which the loop's host runs as a step of its own. The
  commands a key runs for it, `minibuffer-accept` and `minibuffer-cancel`,
  and `minibuffer-next` and `minibuffer-previous`, which move a choice
  through a prompt's candidates (the command loop's phase 14), on `C-n`
  and `C-p` under the Vim scheme, `minibuffer-insert`, which puts the
  chosen candidate, or the first listed, in the input, on `TAB`
  (completion's phase 6),
  `minibuffer-delete-backward`, which deletes the character before the
  minibuffer's bar and cancels the prompt when the minibuffer is empty,
  and the minibuffer's mode are compiled (`lean/Editor/Minibuffer.lean`),
  registered by `lean/Editor/Minibuffer/Compiled.lean`, the one module of
  the two that names the registry.
- **Evil is commands over the API** (`lean/Editor/Evil.lean`, built by the
  command loop's phase 11; [keymaps-and-modes.md](keymaps-and-modes.md),
  "The Vim scheme"): the move command, the commands that enter a Vim state
  and begin an insert, and the one typed text runs. Each is given its
  call, which carries what the input scheme reports of its view
  (`Call.report`), since a command cannot ask the scheme. They add no
  request to a port, so there is no new model and no new contract. A
  motion is a vocabulary entry (`lean/Editor/Vocabulary.lean`), a program
  over the text port alone. Config sees the commands, the motions and
  their table through `Editor.lean`, which imports `lean/Editor/Evil.lean`
  and `lean/Editor/Evil/Motions.lean`: the move command is a function of
  the table it looks a name up in, so a command of config's hands it the
  vocabulary that ships (`Evil.motions`), or that vocabulary with motions
  of its own added. The registrations (`lean/Editor/Evil/Compiled.lean`)
  name the registry and are the one module of evil's that is not imported.
  Pinned by `ConfigTest.evilChecks`, on a config the real elaborator
  loads.
- **Evil's editing commands** (the command loop's phase 13): the operators
  and the operate command, `x`, the registers and the two puts, the two
  commands that open a line, undo and redo, and dot repeat, each in a
  module of its own beside `lean/Editor/Evil.lean`. They needed four state
  requests (`giveUp`, `breakOff`, `setRegister`, `runCommand`), one operation of the API
  (`replaceCarrying`, with a case in `lean/Editor/Api/Cases.lean`), and
  one new sub-port, the clipboard's, with its model and its contract
  ("The editor's port is a composite"). An operator is a vocabulary entry
  whose action is a command's body, so the vocabulary imports the port.
  `Editor.lean` imports them, so config calls the operate command with
  the tables that ship or with tables of its own, and the repeat and undo
  commands.
- **The ex line is commands over the API** (`lean/Editor/Ex.lean`, built
  by the command loop's phase 12;
  [keymaps-and-modes.md](keymaps-and-modes.md), "The ex command line"):
  `ex`, which asks for a line and runs it, and `quit`, `save-and-quit` and
  `reload-config`. They needed four state requests. Two name something
  the host holds: which command an ex name is bound to (`exBinding`),
  which the dispatcher answers from the registry, as it answers a major
  mode's name and a job's; and a reload (`reloadConfig`), a one-shot
  output of the step. One has a command run after another (`invoke`), in
  the field a prompt's answer is recorded in. One asks the editor to quit
  (`quit`), which is a flag of the state the step turns into "stop"
  ([concurrency.md](concurrency.md), "Quit"). None adds a request to
  another port, so there is no new model and no new contract; `quit` asks
  the text port for revisions, and has a case in
  `lean/Editor/Api/Cases.lean`. The registrations and the ex names that
  ship (`lean/Editor/Ex/Compiled.lean`) name the registry and are not
  imported by `Editor.lean`.
- **A command asks layout a question through its view's area** (built by
  the command loop's phase 15;
  [text-and-display.md](text-and-display.md), "Views as built";
  [keymaps-and-modes.md](keymaps-and-modes.md), "Scrolling as built").
  - `Target.onArea` reads the view's rectangle from the state
    (`EditorState.rect?`, the definition the scene's views are laid out
    by), takes a snapshot of the buffer's text, runs the command's
    program with both, and releases the snapshot, also when the program
    was refused. A command that is interrupted, gives up or breaks off
    inside it leaves the snapshot: the loop ends a command's program at
    that request, and a snapshot a command took is not undone.
  - The take, the release and the rethrow are one helper,
    `TextId.withSnapshot` in `lean/Editor/Command.lean`, beside the lifts:
    the lowest module that has a command's type, which the API and the
    evil vocabulary both import. `Target.onArea` is the rectangle's lookup
    and that helper, and a motion that asks the display calls it with the
    text it is handed (`j` and `k`, `lean/Editor/Evil/Motions.lean`). So
    the release rule, and what an interrupted command leaves, is in one
    place.
  - The policy that says where a scroll anchor goes is
    `lean/Editor/Scroll.lean`: programs over the display port alone,
    which the API imports. It holds no state, and nothing of an answer of
    layout is kept between two questions.
  - `Target.anchor`, `Target.scrollTo` and `Target.onArea` each have a
    case in `lean/Editor/Api/Cases.lean`, and so has the loop's follow,
    which asks the display about the scene's own snapshots. No request
    was added to a port: the display's two queries were there, and the
    margin is one state request (`setScrollMargin`).
  - Evil's scroll commands are in `lean/Editor/Evil/Scroll.lean`, which
    `Editor.lean` imports, so a command of config's calls `Evil.scroll`
    and `Evil.scrollLineTo`, or the API's operations.

| Piece | Where |
|---|---|
| The operations | `lean/Editor/Api.lean` |
| Their cases, played on the models and on the real binding | `lean/Editor/Api/Cases.lean` |
| What is proved of them on the text model | `lean/Editor/Api/Theorems.lean` |
| The file commands, their jobs' work, their orders and what they say in the echo area | `lean/Editor/Files.lean` |
| The file commands and their jobs as compiled code registers them | `lean/Editor/Files/Compiled.lean` |
| The commands that accept and cancel a prompt, and the minibuffer's mode | `lean/Editor/Minibuffer.lean` |
| The minibuffer's commands and its mode as compiled code registers them | `lean/Editor/Minibuffer/Compiled.lean` |
| The vocabulary: the motion record and the operator record | `lean/Editor/Vocabulary.lean` |
| Evil: where a cursor rests, and the commands the Vim scheme's invocations run that are not below | `lean/Editor/Evil.lean` |
| Evil's motions, as vocabulary entries, and their table | `lean/Editor/Evil/Motions.lean` |
| Evil's operators, as vocabulary entries, their table, what an operator takes, the operate command and `x` | `lean/Editor/Evil/Operators.lean` |
| Evil's registers, storing and fetching, and the two puts | `lean/Editor/Evil/Registers.lean` |
| Evil's undo and redo, which place the selection a step hands back | `lean/Editor/Evil/Undo.lean` |
| Evil's dot repeat: the repeat command | `lean/Editor/Evil/Repeat.lean` |
| The scroll policy: how a view follows its cursor, the margin, and the anchors a scroll places | `lean/Editor/Scroll.lean` |
| Evil's scroll commands: by half a view, by a view, and to the cursor's row | `lean/Editor/Evil/Scroll.lean` |
| What is proved of evil on the text model, and of the undo tree | `lean/Editor/Evil/Theorems.lean`, `lean/Editor/UndoTree/Theorems.lean` |
| Evil's commands as compiled code registers them | `lean/Editor/Evil/Compiled.lean` |
| An ex line as data: its name and argument, and an ex binding | `lean/Editor/Ex/Line.lean` |
| The ex command, and the commands `quit`, `save-and-quit` and `reload-config`, with what they say in the echo area | `lean/Editor/Ex.lean` |
| The ex line's commands and the ex names that ship, as compiled code registers them | `lean/Editor/Ex/Compiled.lean` |
| The command `load-theme`, which switches the theme in force with no reload, with what it says in the echo area | `lean/Editor/Themes.lean` |
| The command that loads a theme and the themes that ship, `default` among them, as compiled code registers them | `lean/Editor/Themes/Compiled.lean` |
| The loop on the models with jobs, for tests of a command that starts a job: a job reads the snapshots commands took, and its command is handed what the job loaded | `lean/Editor/Loop/Driver.lean` |

## Where state lives

| State | Held by | Across a reload | Across a restart |
|---|---|---|---|
| Buffers, windows, keymaps, registers, the agent table | Compiled Lean, on the editor thread. Buffers, windows, the frame's window list and layout, the echo area and the preedit are the editor state (`lean/Editor/State.lean`), which the command loop (`lean/Editor/Loop.lean`) holds and is the one writer of: a command changes it by requests the loop answers. Buffers are kept in slots, so a buffer's id is never used again, and neither is a view's | Untouched | Lost unless its owner persists it |
| A buffer's local values: plain trees by name (`Value`), as a store's cell holds | Compiled Lean, a field of the buffer in the editor state, set and read by a command (`BufferId.setValue`, `BufferId.value?`) | Untouched: a tree names no type of config's | Lost |
| A buffer's changed-on-disk mark: what the last check of its file found that is not the file it holds, and whether the user was told (`Buffer.File.changed`) | Compiled Lean, a field of the buffer's file in the editor state, set by the command a check finishes with (`BufferId.markChanged`, `BufferId.tellChanged`) and cleared by a load, a reload or a save | Untouched | Lost: a check after a restart finds the file as it is |
| What the loop saw at its last publish (`Loop.seen`): the focus, the buffers shown, modified and open, which decide the files due a check | Compiled Lean, a field of the loop | Untouched | Lost |
| The input scheme's state: the pending keys and what the scheme keeps for each view (the Vim scheme's states, its last change, and the text typed in the insert session that change began) | Compiled Lean, in the command loop, which runs one scheme for its life | Untouched | Lost |
| The registers: a text and whether it is line-wise, by name. Evil keeps the unnamed one, which every yank and deletion sets | Compiled Lean, a field of the editor state (`EditorState.registers`, `lean/Editor/State.lean`), set by a command (`setRegister`), so it is rolled back with a command that does not run to its end | Untouched | Lost |
| The system clipboard | Outside the editor: reached through the clipboard port. A host with no window keeps one of its own in the process (`lean/Editor/Clipboard/InProcess.lean`) | Untouched | The window system's is the system's; the in-process one is lost |
| Compiled commands, jobs, key bindings, modes, ex bindings and themes | Compiled Lean, in the registry, for the owner `compiled`. The executable ships the command `load-theme` and the theme `default` (`lean/Editor/Themes/Compiled.lean`), the ex line's four commands, `ex`, `quit`, `save-and-quit` and `reload-config`, and the ex names `w`, `w!`, `e`, `e!`, `q`, `wq` and `reload` (`lean/Editor/Ex/Compiled.lean`), the file commands, `open-file`, `save-buffer`, `edit-file` and `reload-buffer`, and their jobs, `load-file`, `save-file` and `reload-file`, with the file prompt's source `files`, its job `files` and the style `path` as the category `file`'s compiled default (`lean/Editor/Files/Compiled.lean`, `lean/Editor/Completion/Paths.lean`), the minibuffer's commands, `minibuffer-accept`, `minibuffer-cancel`, `minibuffer-next`, `minibuffer-previous`, `minibuffer-insert`, `minibuffer-delete-backward` and `minibuffer-delete-to-start`, and its mode, `minibuffer` (`lean/Editor/Minibuffer/Compiled.lean`), and evil's thirty-seven commands, `move`, `normal`, `visual`, `visual-line`, `insert`, `append`, `insert-line-start`, `append-line-end`, `self-insert`, `operate`, `select-object`, `delete-char`, `put-after`, `put-before`, `open-below`, `open-above`, `undo`, `redo` and `repeat`, over its compiled tables of motions, operators, text objects and changes, and the seven that scroll a view, `scroll-down`, `scroll-up`, `scroll-page-down`, `scroll-page-up`, `scroll-line-to-top`, `scroll-line-to-center` and `scroll-line-to-bottom`, the seven editing keys of insert state, `insert-delete-backward`, `insert-newline`, `insert-tab`, `insert-left`, `insert-right`, `insert-up` and `insert-down`, and the four of the Edit menu, `clipboard-cut`, `clipboard-copy`, `clipboard-paste` and `select-all` (`lean/Editor/Evil/Clipboard.lean`) (`lean/Editor/Evil/Compiled.lean`), and `workspace-current` with the job `find-workspace` (`lean/Editor/Workspace/Compiled.lean`) | Untouched: a reload replaces config's, and cancels config's jobs only, so a compiled job that is running goes on | Registered again when the host starts |
| An open prompt: its label, the minibuffer's view, the asking view and the continuation, its candidates with what it has listed of them and the choice, all plain data, with the minibuffer's buffer and window | Compiled Lean, a field of the editor state (`EditorState.prompt`, `lean/Editor/State.lean`) and a buffer and a window of it, from the command that asks until the one that accepts or cancels | Untouched: the prompt stays open, and its continuation is a name, looked up in the registry as it is when the answer arrives | Lost |
| A save in flight: the snapshot a save writes and the state its text was in | Compiled Lean, with the buffer's file in the editor state, from the save command until the save's result is delivered | Untouched | Lost with the buffer |
| Asked to quit: whether a command asked the editor to quit | Compiled Lean, a field of the editor state (`EditorState.quitting`), from the command that asks until the step that says stop, or until the scene that withdraws it because a buffer has unsaved changes | Untouched: a quit that is waiting for a save still waits | Not kept: the process has ended |
| A view's wanted column: the column its vertical motions aim for, with the offset the cursor was left at | Compiled Lean, a field of the view's window in the editor state (`Window.wanted`), set by a command (`ViewId.setWanted`) | Untouched | Lost |
| A view's scroll position | An anchor marker of the buffer's text, in the text store, named by the view's window (`Window.scroll`). The loop places it before each scene so that the view shows its cursor, and a scroll command places it (`Target.scrollTo`). The loop keeps and restores it round a command, so a command that does not run to its end leaves it | Untouched | Lost |
| The scroll margin: how many rows every view keeps between its cursor's row and the first and the last row it shows | Compiled Lean, a field of the editor state (`EditorState.scrollMargin`, 0 in a new state), set by a command (`setScrollMargin`), so it is rolled back with a command that does not run to its end. Config cannot set it when it loads: `setup` runs no command, and the one setting there is, auto-reload, is not it | Untouched | Lost |
| Auto-reload: config's setting (`autoReload` in `setup`, `Config.Registry.autoReload`, false when config says nothing, a second call refused), a command's choice (`EditorState.autoReload`, `none` until `auto-reload-mode` sets it), and what the loop follows (`EditorState.following`) | Config's setting in the registry, installed with the config; the choice and the following in the editor state | Config's setting is replaced with config's; the command's choice is untouched and decides over it | Lost |
| The workspace table: each workspace found or registered this session, with its location (its one root), its branch and its project, and its store of values by name, keyed by location ([projects.md](projects.md)) | Compiled Lean, a field of the editor state (`EditorState.workspaces`, `lean/Editor/Workspace.lean`), written by state requests (`recordWorkspace`, `registerWorkspace`, `setWorkspaceValue`). A buffer names its workspace by a buffer-local value, its location | Untouched: cells are `Value` trees | Lost |
| The project table: each project of those workspaces, with its store of values by name, keyed by identity | Compiled Lean, in the same table (`setProjectValue`) | Untouched | Lost |
| The directory cache: each directory a file was opened in, the location of its workspace or none, and the config generation it was found under | Compiled Lean, in the same table, recorded by the find job's command. The config generation is the registry's (`Registry.generation`), bumped by every install | Kept, but an answer only under its own generation: the next open after an install asks git again | Lost |
| Layout: where a text wraps, how tall a row is, which rows a view shows | The display, in the Rust library. Lean keeps no copy: it asks the display's two queries each time, and keeps nothing of an answer | Untouched | Not kept |
| A buffer's modes: its major mode and its minor modes, by name | Compiled Lean, a field of the buffer in the editor state | Untouched: a name whose mode a reload drops contributes nothing | Lost |
| A mode's own state | A compiled mode's, a typed field where the editor state's table puts it (the one mode that ships, the minibuffer's, keeps none); a config mode's, a store its `setup` declares, whose commands fill its roles and suffixes, with per-buffer state in the buffer's local values, or inside the store's value | As for compiled state, and as for a store | As for compiled state, and as for a store |
| Text, kept inverses, anchors | Rust, behind handles | Untouched | Files on disk; the kept inverses are lost |
| The undo tree of each text: its nodes, where the text is in it, and the state last saved | Compiled Lean, with the buffer it is the history of, on the editor thread | Untouched | Lost |
| A file's stamp (when it was last modified and how long it is, as the last load or save answered it), its path and its line ending | Compiled Lean, fields of the buffer that shows the file, in the editor state (`Buffer.file`, `Buffer.lineEnding`, `lean/Editor/State.lean`): the path a buffer is found by, the stamp the next save expects, and the line break a command inserts. A command sets them by one request (`BufferId.attachFile`) | Untouched | Lost; the file is loaded again |
| The snapshots a job's loads made | The job runner, off the editor thread, until the job's command adopts one or the job is settled | A reload that installs cancels the old config's jobs, which releases them | Lost |
| Processes, terminals | Rust, behind handles | Untouched | Lost |
| Closures registered by config | Compiled Lean, tagged with their owner | Replaced by the new config's | Re-registered by `setup` |
| Values of types that config defines | See below | Converted or dropped | As for a reload |

Compiled state needs no special mechanism. That is the main simplification
over the first design, where Rust had to store all Lean state as plain data.

**State of config-defined types** is the one case that needs care. After a
reload the type may have changed, so a value built by the old config cannot
be handed to the new one. Config keeps such state in a **store**: a named,
owned cell whose type has an encoding to a plain value tree and a version.
On reload the value is decoded by the new config; a version change runs a
`migrate` function or drops the value, as the owner chose.

As built (`lean/Editor/Store.lean`, `lean/Editor/Config/Stores.lean`), a
store is a whole-value cell, and it is editor state, not a request of the
editor's port:

- **What config writes** is a `Store α`: a name, a version, an initial value,
  `encode : α → Value`, `decode : Value → Option α` and `migrate`, from an
  older version's tree to this version's. `Value` is a plain tree: null,
  bool, nat, int, string, list, record. `setup` declares the store and
  registers commands over it, each a function `α → EditorM α`.
- **Where the value lives.** A cell is an owner, a name, a version and a
  `Value`, in a table in the editor's state on the editor thread. It holds
  no type of config's, so a reload leaves it where it is. To run a store
  command the editor hands the cell's tree to the registered step (decode,
  run, encode: all config's code) and writes the result back only if the
  command succeeded.
- **On install**, for each store the new config declares: no cell makes one
  from the initial value; a cell at the declared version is kept if the new
  config can decode it; a cell at another version becomes `migrate` of it. A
  cell the new config cannot decode, or does not migrate, is reset to the
  initial value, and the reload's report says so. A cell the new config no
  longer declares is removed. Declaring a store name twice, registering a
  command name or a job name twice, setting a face twice, defining or naming
  a theme twice, or registering a command over an undeclared store rejects
  the reload.
- **Why not a request of the editor's port.** The editor's port is now a
  composite of sub-ports ("The editor's port is a composite", above), and a
  `get` and a `set` would be a store sub-port of it. Stores still do not use
  it: state-passing commands need no change to `EditorM`. They limit a
  command to one store; a store sub-port can be added later without
  changing the cell, the encoding, the version or the install rule.
- **No model and no contract check.** The store never reaches the Rust
  library. Its one implementation is the pure core, which the model tests
  and the real editor both run.

**Persistence** is a library feature in Lean: a store or a compiled table
can be marked persistent, and is then written to disk and read back at
start-up through the same encoding. Agent records are the first user.

## Events and reducers

Events arrive on the editor queue as plain data. The intended way to
consume a stream of them is a **reducer**: a pure function from state and
event to new state.

```lean
def AgentTable.step (s : AgentTable) : AgentEvent → AgentTable
  | .statusChanged id st => s.setStatus id st
  | .exited id code      => s.markExited id code
  | …
```

Because it is pure it can be tested and reasoned about with no library.
Side effects (notify the user, start a job) are returned as data alongside
the new state and performed by the runtime. This is the shape that survived
in `edmacs`: one table, one writer, one change event.

The editor loop keeps running during a reload, so events are not held back
and there is no gap to bridge.

## Subscriptions

Hooks in Emacs are lists of functions that accumulate. Here a subscription
is a record: the event kind, an optional subject filter (this buffer, this
agent), the handler, and the owner. On reload every subscription an owner
had is replaced. Handlers always receive their subject explicitly.

## Compiled and interpreted code

| | Interpreted | Compiled into the executable |
|---|---|---|
| Speed | A loop iteration costs about 0.1 µs; calls into compiled code and Rust run at native speed | Native |
| Live reload | Yes | No |
| Used for | User config; features under development | The editor core; the standard library |

A feature can be developed interpreted and compiled in once it settles. A
user who wants to change a compiled feature overrides its registration from
config (a key binding, a command name, a handler); replacing a function that
other compiled code calls directly is not possible without rebuilding.

## Memory and size

Memory is set by how much is imported at runtime, not by the architecture.
Importing only Lean's `Init` gave about 375 MB; an API that also imports
the standard hash map gave about 485 MB; importing all of the `Lean`
package gave about 1.2 GB. So the editor API's imports are kept deliberate,
and config that imports the `Lean` package pays for it.

The executable is large because Lean's elaborator is linked in: `editor` was
13 MB before it could elaborate config. `ffi-test` and `config-test` are the
same size for the same reason. As built, in MB (10⁶ bytes):

| Executable | macOS (arm64) | Linux (aarch64) |
|---|---|---|
| `editor` | 181.6 | 266.1 |
| `ffi-test` | 181.3 | 265.7 |
| `config-test` | 181.9 | 266.5 |
| `contract-test` | 4.3 | 14.7 |
| `model-test` | 3.7 | 6.8 |

The window library added 2.3 MB to `editor` on macOS.

`mise run config-bench` measures start-up time and resident memory for the
import sets `Editor`, `Editor` with `Std`, and `Editor` with `Lean`, in the
executable as built.

### What config may import, measured

Config is elaborated on `Editor`, and an app bundle carries the module files
that import reads, since it can rely on no toolchain on the machine. Which
files those are, and what the set with `Lean` would cost instead, was
measured from staged bundles (`tools/stage-bundle.sh`), on 2026-11-15, on an
Apple M5 Max, macOS 27.2, Lean 4.35.0, with

```sh
mise run module-bench
```

(`tools/module-bench.sh`; [on-demand-checks.md](../dev-practices/on-demand-checks.md)).
MB are 10⁶ bytes of apparent size. "Whole directories" are the toolchain's
top-level `Init` and `Std` (and `Lean` for the second set) with their root
files, and the package's `Editor`; "closure" is the modules the import
reads, which `config-test bench-modules` lists.

| | `Editor` | `Editor` with `Lean` |
|---|---|---|
| Modules the import reads | 700: `Init` 653, `Editor` 47 | 2,421: `Init` 653, `Std` 494, `Lean` 1,227, `Editor` 47 |
| File kinds the import reads | `.olean`, `.olean.server`, `.olean.private` | the same |
| Bytes shipped, those kinds, whole directories | 734.6 MB | 1,728.1 MB |
| Bytes shipped, those kinds, closure | 396.4 MB | 1,684.5 MB |
| Of the closure: `.olean` / `.olean.server` / `.olean.private` | 126.5 / 11.6 / 258.4 MB | 360.0 / 30.6 / 1,293.9 MB |
| Not shipped: `.ir` / `.ir.sig` of the closure | 18.4 / 0.1 MB | 354.4 / 0.4 MB |
| `bench-start`: import, then first load of a 20-line config (median of 5) | 137.8 ms, 13.3 ms | 467.5 ms, 14.1 ms |
| `bench-start`: real time (median of 5) | 0.17 s | 0.52 s |
| `bench-start`: largest maximum resident set (of 5) | 406.3 MB | 1,205.5 MB |
| The bundle's headless mode on `tests/headless/bundle`, `env -i`: real time (median of 5) | 0.18 s | not run |
| The same: largest maximum resident set (of 5) | 406.1 MB | not run |

What the figures show:

- **The import reads three kinds of file.** With `.olean` alone it fails
  on `Init.olean.server`, and with `.olean.server` added on
  `Init.olean.private`; with both it imports and the config loads and runs.
  `.ir` and `.ir.sig` are never needed: compiled code is linked into the
  executable, and the fixture's command, which calls compiled code of
  `Init` and of `Editor`, runs without them (`bundle-test`). The editor
  package's own modules have only `.olean` files; the toolchain's use the
  module system, which reads all three. `.olean.private` is two thirds of
  the bytes.
- **`Editor` imports nothing of `Std`.** Its closure is all of `Init` and
  47 of the package's modules, so the closure is 46% smaller than the whole
  directories (`Std`'s 494 modules and the package's modules that `Editor`
  does not import, the bindings, the config session and the headless mode,
  are left out). The bundle ships the closure, and `bundle-test` stages
  exactly it.
- **With `Lean`, config would cost four times the bytes, about three times
  the start-up, and three times the memory.** The closure saves little
  there: `Lean` reaches nearly all of `Std` and all of `Init`.

Config imports what `Editor` imports, and the bundle ships that set's
closure, in those three kinds, about 396 MB beside the executable. Whether
config should be allowed `Lean` (for metaprogramming, say) is a later task,
to be decided from these numbers.

**A dynamically linked build saves disk and nothing else**, so there is none.
Lake has no option for one outside Windows; it would be link arguments of
our own. Measured once on macOS, by linking `editor` by hand both ways from
the same objects, against Lean's static libraries as the build does and
against its shared ones (`libInit_shared`, `libleanshared` and the two
beside it, found through an `-rpath` to the toolchain):

| | Static | Shared |
|---|---|---|
| Size | 181.6 MB | 4.5 MB |
| Link time | 0.25 s | 0.11 s |
| The demonstration, each of 20 runs | 19 ms | 32 ms |
| The headless fixture, each of 5 runs | 168 ms | 182 ms |
| Resident memory, the demonstration | 55.4 MB | 56.0 MB |
| Resident memory, the headless fixture | 419 MB | 416 MB |

Both print the same. The link is a quarter of a second either way, so a
shared build would not make the edit-and-run loop faster; it starts 13 ms
slower, and it would tie the executable to a toolchain directory.

## Open questions

- **Store design.** Whole-value cells are built. Keyed rows with per-row
  change events stay open, and so does how a command reaches more than one
  store. Decide from the first real users (evil's registers if config
  extends them, and third-party packages).
- **Third-party packages.** Loaded as interpreted modules at runtime, or
  compiled into a rebuilt executable (as xmonad does)? How they are fetched
  (Lake), and whether they are trusted like user config. Lean code runs
  with the user's full authority, as Emacs Lisp does. A constraint found
  with the config session: the base is safe to import beside a running
  editor thread only because every module in it is linked, so its
  initialisers are not run at import. An interpreted package's would be.
- **A header for config chunks.** A chunk has no `import` line, so Lean's
  tooling cannot check or format a config file by itself. Whether a chunk
  should carry a header the session checks and skips is not decided.
- **Overriding compiled features** beyond re-registration.
- **Memory growth** with many packages loaded and with background jobs
  holding old environments.
