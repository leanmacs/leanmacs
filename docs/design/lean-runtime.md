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
   config took 150 to 200 ms in the background.

Shutdown posts a quit event, unblocks every dedicated task, and calls exit.
Returning from `main` while a task is blocked in Rust hangs.

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
  The real editor will need requests that reach the main thread through the
  window's loop; that is the display pipeline's.
- **The window runs once in a process**, which is all winit allows.

The one thing that runs a window today is the keyboard check
(`lean/Editor/WindowCheck.lean`; `editor window-check`), which a person runs
to see that keys reach a Lean loop, and how fast.

What is built of this is the headless mode (`lean/Editor/Headless.lean`;
`editor headless <sysroot> <olean dir> <config dir> <script file>`): an
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
loop answers events before and while it runs. Where an installed
editor finds the toolchain's `.olean` files and its own is not decided: the
headless mode takes both directories as arguments.

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
| The registry of commands, of jobs and of key bindings, replaced by owner, the keymap of the bindings, and the handler that collects a `setup` | `lean/Editor/Config/Registry.lean` |
| What a command is run with when a key runs it: the focused window and its buffer, the arguments and the keys | `lean/Editor/Command/Call.lean` |
| The cells of the stores, and the rule that installs a config's stores | `lean/Editor/Config/Stores.lean` |
| One reload: the chunks, the plan, the build, over the two ports | `lean/Editor/Config/Session.lean` |
| The reducer that serialises reloads and installs their outcomes | `lean/Editor/Config/Reload.lean` |
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
  job). A request can carry an `EditorM` because the setup port is not the
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
  compiled one is found again once a reload drops it. A compiled command
  may be given what it was called with (`Config.Action.call`, handed a
  `Call`); config's commands are not, until a setup request for it exists.
  The reload's report counts config's commands only.
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
| The job port: a clock and a wait; `sleep`; `Timer`; the file requests, `File.load` and `File.save`, whose replies are a result or a refusal, a value; `Work` | `lean/Editor/Job.lean` |
| The file requests as data: a stamp, line endings and the dominant one, what a save expects, a save's source (a snapshot a command took or one the job loaded), what a load answers, and the refusals with what each says | `lean/Editor/File.lean` |
| The pure model of the files a job reaches: directories, files with their bytes and stamps, a count of writes for a clock, the snapshots the editor published and those the job's loads made. It answers by the library's rules and its own route: a file's text is decoded a character at a time, each byte that starts no valid character becoming its escape | `lean/Editor/File/Model.lean` |
| Its pure model: a clock, the instant the job is cancelled at, and the model of files | `lean/Editor/Job/Model.lean` |
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
| Its pure model: the scenes published, in order, and a layout in fixed-size cells, for tests, and for the recorder below | `lean/Editor/Display/Model.lean` |
| Its contract, imported from the port alone: properties of the two queries at a cell size, run against the model by `lake test` at two sizes, against the recorder over the library's snapshots by `contract-test` at the same two, and to be run against the real binding over a fake shaper whose glyphs have that size | `lean/Editor/Display/Contract.lean` |
| The display where there is no window (the headless host): a recorder that keeps the last scene published and how many have been, and answers the two queries with the model's layout rule over the text of the library's snapshot, read through the published table's read half. It is the one place the model's rule runs outside a test, because a host with no window has no layout to ask; an editor with a window asks the real binding every time | `lean/Editor/Display/Recorder.lean` |
| The events of the editor queue as plain data (a key with its logical and physical identity and modifiers, a pointer, a resize), and the one module that reads and writes their layouts on the queue | `lean/Editor/Event.lean`, `lean/Editor/Event/Queue.lean` |

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
  one of the watch port and `EditorRequest.state` a request about the
  editor state. The reply to each is its sub-port's reply. `editorPort` is
  an `abbrev`, as every port is.
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
  embedding and a case in each runner. Nothing on it is refused.
- **A command is `EditorM := ExceptT TextError (Program editorPort)`.** A
  program over the text port alone is `TextM`, and every text operation and
  all logic over text alone (the undo tree, the text contract, `append`)
  stays at it; the display's is `DisplayM` and the watch port's `WatchM`.
  `TextM.lift`, `DisplayM.lift` and `Watch.lift` embed each in a command,
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
  models it is the text model, the display model and the watch model side
  by side (`EditorModel`); before each display request the display model's
  texts are filled from the text model's snapshots, so a command that takes
  a snapshot and asks the display about it is answered from that
  snapshot's text. On the models time passes only with requests: the watch
  model's clock moves on by its pace at each text and display request, and
  a test has an interrupt key arrive at a command's n-th request. For real
  it is the text binding's table, with a display handler (`DisplayHandler`)
  passed in: the recorder in a host with no window, the display pipeline's
  binding in one with a window; and a watch handler (`WatchHandler`),
  `Watch.real` over the library's flag and the job clock in a host, and
  `Watch.idle`, never interrupted, by default.
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
| The composite port, `EditorM`, the three embeddings and lifts, and the mapping of the display's refusals | `lean/Editor/Command.lean` |
| The state requests and their pure handler: one read of the whole state, and a request a write (a buffer, its history, values and modes; a window; the echo; a job to start), each refused with a value | `lean/Editor/State/Request.lean`, over the operations of `lean/Editor/State.lean` |
| A dispatched command: its state requests answered from the loop's state, every other request guarded, so that it stops at its next one once the flag is up, a major mode's on-enter actions run inside it; `Guarded`, how it ended; and `Loop.Registered`, what the loop is told of the registry. The guard has this one definition | `lean/Editor/Command/Dispatch.lean` |
| The composite's model runner, over the three models side by side | `lean/Editor/Command/Model.lean` |
| The composite's real runner, over the text binding, a display handler and a watch handler | `lean/Editor/Command/Real.lean` |
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
| Say something in the echo area | `message` | No |
| Start a job, with arguments | `startJob`, for a job registered with `jobWith` or `job` | No: the host starts it once the command has ended |

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
- **Out of the API still**: files (phase 9), prompts (phase 10), and
  commands that ask layout a question (phase 15).

| Piece | Where |
|---|---|
| The operations | `lean/Editor/Api.lean` |
| Their cases, played on the models and on the real binding | `lean/Editor/Api/Cases.lean` |
| What is proved of them on the text model | `lean/Editor/Api/Theorems.lean` |
| The loop on the models with jobs, for tests of a command that starts a job: a job reads the snapshots commands took, and its command is handed what the job loaded | `lean/Editor/Loop/Driver.lean` |

## Where state lives

| State | Held by | Across a reload | Across a restart |
|---|---|---|---|
| Buffers, windows, keymaps, registers, the agent table | Compiled Lean, on the editor thread. Buffers, windows, the frame's split tree, the echo area and the preedit are the editor state (`lean/Editor/State.lean`), which the command loop (`lean/Editor/Loop.lean`) holds and is the one writer of: a command changes it by requests the loop answers. Buffers are kept in slots, so a buffer's id is never used again, and neither is a view's | Untouched | Lost unless its owner persists it |
| A buffer's local values: plain trees by name (`Value`), as a store's cell holds | Compiled Lean, a field of the buffer in the editor state, set and read by a command (`BufferId.setValue`, `BufferId.value?`) | Untouched: a tree names no type of config's | Lost |
| The input scheme's state: the pending keys and what the scheme keeps for each view (the Vim scheme's states, its last change) | Compiled Lean, in the command loop, which runs one scheme for its life | Untouched | Lost |
| Compiled commands, key bindings and modes | Compiled Lean, in the registry, for the owner `compiled` | Untouched: a reload replaces config's | Registered again when the host starts |
| A buffer's modes: its major mode and its minor modes, by name | Compiled Lean, a field of the buffer in the editor state | Untouched: a name whose mode a reload drops contributes nothing | Lost |
| A mode's own state | A compiled mode's, a typed field where the editor state's table puts it (none ships); a config mode's, a store its `setup` declares, whose commands fill its roles and suffixes, with per-buffer state in the buffer's local values, or inside the store's value | As for compiled state, and as for a store | As for compiled state, and as for a store |
| Text, kept inverses, anchors | Rust, behind handles | Untouched | Files on disk; the kept inverses are lost |
| The undo tree of each text: its nodes, where the text is in it, and the state last saved | Compiled Lean, with the buffer it is the history of, on the editor thread | Untouched | Lost |
| A file's stamp (when it was last modified and how long it is, as the last load or save answered it), its path and its line ending | Compiled Lean, with the buffer that shows the file: the buffer's to keep, for the next save to expect. Nothing keeps one yet: buffers are the command loop's | Untouched | Lost; the file is loaded again |
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
  command name or a job name twice, or registering a command over an
  undeclared store rejects the reload.
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
- **Where an installed editor finds `.olean` files**: the toolchain's and
  its own. The headless mode takes both directories as arguments, and
  nothing else loads config yet.
- **Overriding compiled features** beyond re-registration.
- **Memory growth** with many packages loaded and with background jobs
  holding old environments.
