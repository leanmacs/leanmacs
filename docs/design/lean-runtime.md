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
- **macOS** needs the system linker (`LEAN_CC=/usr/bin/cc`), because Lean's
  bundled linker cannot link Apple frameworks, plus the toolchain's library
  directory and the framework list winit needs.

There is no hand-written Lean start-up sequence and no scraping of
generated symbol names, which the first prototype needed. What can break on
a Lean upgrade is the `@[extern]` calling convention, the Lake build API,
and the macOS linker workaround.

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

What is built of this is the headless mode (`lean/Editor/Headless.lean`;
`editor headless <sysroot> <olean dir> <config dir> <script file>`): an
editor loop on a dedicated task with no window, keys or keymaps, which loads
a config directory in the background, runs its commands against the library
and prints what happened. It exists for integration tests, and the command
loop will replace its loop. The first load is an ordinary reload: the loop
answers events before and while it runs. Where an installed editor finds the
toolchain's `.olean` files and its own is not decided: the headless mode
takes both directories as arguments.

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
| The registry, replaced by owner, and the handler that collects a `setup` | `lean/Editor/Config/Registry.lean` |
| The cells of the stores, and the rule that installs a config's stores | `lean/Editor/Config/Stores.lean` |
| One reload: the chunks, the plan, the build, over the two ports | `lean/Editor/Config/Session.lean` |
| The reducer that serialises reloads and installs their outcomes | `lean/Editor/Config/Reload.lean` |
| The elaborator port answered by Lean's elaborator | `lean/Editor/Config/Elaborate.lean` |
| The source port answered by a directory of `.lean` files | `lean/Editor/Config/Directory.lean` |
| The headless loop: the editor thread, the reload job, the output | `lean/Editor/Headless.lean` |

- **The core has no elaborator in it.** Which chunks are elaborated and from
  which cached state, all-or-nothing, when `setup` runs, replacement by
  owner, the store rule and the serialising of reloads are plain Lean with
  no `import Lean`, tested by `lake test` on hand-written fakes of the two
  ports. `Elaborate.lean` is the only module that imports Lean's elaborator,
  and `config-test` checks it, the directory source and the whole host
  against the real collaborators (`mise run ffi-test`).
- **`setup` is a program over a setup port**: `SetupM Unit`, whose requests
  carry what is registered (a command, a store, a command over a store). A
  request can carry an `EditorM` because the setup port is not the port
  `EditorM` runs over. After the last chunk the editor runs `setup` against
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
  `config`; it never adds to them.
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
  programs over the editor's port and `JobM` the type of programs over the
  job port. Both are ordinary monads, and a command reads as a `do` block.
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
  so a text is named by an id and the real binding keeps the table from ids
  to handles. A text lives until the table drops it, not until the last
  Lean reference goes.
- **A request that carries a program over its own port** (a job's result
  handler, a key binding made from inside a command): the port would refer
  to itself. Registration from a later port type-checks, and so does a
  program type written for the editor in place of the generic one. The
  config session and the job system choose.
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
| The text port: create, insert, delete, read | `lean/Editor/Text.lean` |
| Its pure model | `lean/Editor/Text/Model.lean` |
| Its real binding, over a placeholder string in Rust until the text-storage crate lands | `lean/Editor/Text/Real.lean` |
| Its contract, run against the model by `lake test` (`mise run lean-test`) and against the real binding by `contract-test` (`mise run ffi-test`) | `lean/Editor/Text/Contract.lean` |
| A command, `append`, with a theorem about it | `lean/Editor/Command/Append.lean` |
| `JobM`, and the compile-time checks of the split | `lean/Editor/Job.lean` |

The job port has no request yet, so "a wait is not a command" is not
checked: that check arrives with the job system and the port's first
request. Until then "a command may not block" is checked only as far as
`IO` goes.

## Where state lives

| State | Held by | Across a reload | Across a restart |
|---|---|---|---|
| Buffers, windows, keymaps, registers, the agent table | Compiled Lean, on the editor thread | Untouched | Lost unless its owner persists it |
| Text, undo history, anchors | Rust, behind handles | Untouched | Files on disk |
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
  longer declares is removed. Declaring a name twice, or registering a
  command over an undeclared store, rejects the reload.
- **Why not a request of the editor's port.** A `get` and a `set` would make
  the editor's port a sum of the text port and a store port, which is the
  shape the phase that grows the editor API exists to choose.
  State-passing commands need no change to `EditorM`. They limit a command
  to one store; `get` and `set` can be added with the composite port
  without changing the cell, the encoding, the version or the install rule.
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

The executable is about 180 MB because Lean's elaborator is linked in:
`editor` is 179 MB as built, where it was 13 MB before it could elaborate
config. `ffi-test` and `config-test` are the same size for the same reason.

`mise run config-bench` measures start-up time and resident memory for the
import sets `Editor`, `Editor` with `Std`, and `Editor` with `Lean`, in the
executable as built.

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
- **The system C++ library.** With the system linker, Lean's runtime links
  against the system `libc++` and not its bundled one. Everything ran; it
  has not been tested further.
