# editor

An Emacs-style editor written in Lean 4. Lean owns the process and is the
editor: its state, the command loop, commands, modes, keymaps and config. A
Rust library, linked into the Lean executable, provides text storage, layout,
rendering, the window, and process and terminal management.

- [`docs/design/`](docs/design/README.md) says what is being built and why.
- [`AGENTS.md`](AGENTS.md) holds the working rules: test-first, ports and
  adapters, hand-written fakes, hermetic tests.

The editor does nothing useful yet. The executable shows that the build
works: Lean calls the Rust library and prints what comes back, and it runs
one editor command against the library. It also has a headless mode, for
integration tests, that loads a config directory, reloads it live, runs the
commands the config registers and starts its background jobs. And it can open
a window, to check that the keyboard reaches a Lean loop; the window shows
nothing yet.

## Building

The build runs on macOS and on Linux, and the gate passes on both. Windows
has not been attempted ([`docs/design/lean-runtime.md`](docs/design/lean-runtime.md),
"Build").

### Prerequisites

- [mise](https://mise.jdx.dev), which installs the tools `mise.toml` pins
  (Rust, cargo-deny, hk, pkl, clang-format) and runs every task below. Run
  `mise install` once in the checkout.
- `uv` or `pipx`. mise uses one of them to install clang-format, and
  `mise.toml` does not pin either.
- Lean, at exactly the version in `lean/lean-toolchain`, with `lean` and
  `lake` on the `PATH`. `mise install` does not provide it.
  [elan](https://github.com/leanprover/elan) reads that file and does.
- A system C compiler at `/usr/bin/cc`. On macOS, the Xcode command line
  tools. On Linux, gcc with GNU ld and the C library's headers: Debian's
  `build-essential`.
- On Linux, also `git`, `curl`, `zstd` and `pkg-config`, and, to open a
  window, the libraries the window library loads at run time under X11
  (`libx11-6 libx11-xcb1 libxcursor1 libxi6 libxrandr2 libxkbcommon0
  libxkbcommon-x11-0 libxcb1` on Debian). `tools/linux/Dockerfile` is the
  whole list as it was run, on Debian 13.
- Network access for the first build, when Lake fetches lean-fmt and Cargo
  the libraries the crates pin: the window library, the rope and, for the
  tests, the property-test library.

### Build and run

```sh
mise run lean
```

This one command builds everything. Lake compiles the Lean package, runs
`cargo build` for the Rust static library (`crates/editor-ffi`), compiles the
C glue (`lean/ffi/glue.c`) and links the executables. Every Lean linter is
on, and a warning fails the build.

The editor is `lean/.lake/build/bin/editor`:

```console
$ lean/.lake/build/bin/editor
Rust says 2 + 3 = 5
Lean's main is on the process's main thread: false
The main-thread service is on the process's main thread: true
A command appended to a text held by Rust: héllo wörld
```

The last line is a command, `Editor.append`, run against the Rust library.
The model tests run the same source against a pure Lean model.

The executable is about 180 MB on macOS and 265 MB on Linux: it can
elaborate config, so Lean's elaborator is linked into it.

### The headless mode

```sh
editor headless <sysroot> <olean dir> <config dir> <script file>
```

This is the editor with no window. It loads the config in a directory, runs
a script against it and prints what happened. Every path is an argument:
`<sysroot>` is the Lean toolchain's directory (`lean --print-prefix`) and
`<olean dir>` the directory of the editor package's `.olean` files
(`lean/.lake/build/lib/lean`). Nothing is read from the environment or the
working directory.

A config is the `.lean` files directly in the config directory, elaborated in
the byte order of their names, each on top of the one before. They have no
`import` line: `Editor` is imported and opened for them. Config defines
commands and jobs, and a `setup` that registers them:

```lean
def greet : EditorM Unit := do
  let text ← createText "hello"
  append text ", world"

def count : Unit → JobM Nat := fun _ => do
  sleep 1
  return 42

def setup : SetupM Unit := do
  command "greet" greet
  job "count" count fun n => discard <| createText s!"counted {n}"
```

A command (`EditorM`) may change editor state and cannot wait. A job
(`JobM`) may wait, here for a millisecond, and cannot change editor state:
it runs in the background, and its result goes to the handler it was
registered with, which makes a command the editor runs. A job is not a
command, and a reload's report does not count it as one.

A `setup` registers each command name and each job name once. One that
registers a name twice is rejected, like a chunk that does not elaborate.

A script is one directive a line. Blank lines and lines that start with `#`
are skipped.

| Directive | Does |
|---|---|
| `reload` | Asks for the config to be reloaded. Elaboration runs in the background, and the editor goes on answering. |
| `settle` | Waits, for up to 30 seconds, until everything asked so far has been handled and no reload is running. |
| `run <name>` | Runs the command registered under that name. |
| `spawn <name>` | Starts the job registered under that name. It runs in the background, and the editor goes on answering. |
| `join` | Waits, for up to 30 seconds, until everything asked so far has been handled and no job is running. |
| `show` | Prints the commands, the texts and the stores. |

With the fixture the gate uses (`tests/headless`):

```console
$ cd lean
$ .lake/build/bin/editor headless "$(lean --print-prefix)" .lake/build/lib/lean ../tests/headless/config ../tests/headless/script
reload 1: installed, 2 chunks, 1 commands
run greet: ok
run missing: no such command
commands: greet
text 0: "hello, world"
spawn count: job 1
job 1 count: ok
commands: greet
text 0: "hello, world"
text 1: "counted 42"
```

The lines it can print:

```
reload <n>: installed, <c> chunks, <k> commands
reload <n>: rejected
diagnostic: <source>:<line>:<column>: <severity>: <first line of the message>
run <name>: ok            (or "refused: <error>", or "no such command")
spawn <name>: job <id>    (or "no such job")
job <id> <name>: ok       (or "refused: <error>", "failed: <message>", "cancelled")
event <source id> <code>
commands: <names>
text <index>: <quoted text>
store <name> v<version>: <value>
```

A job's line is printed when the editor has dealt with its result: `ok` when
the handler's command ran, `refused` when the library refused that command,
`failed` when the job threw, and `cancelled` when a reload that installed
replaced the config that registered it. A job the script leaves running is
cancelled when the script ends.

A reload that is rejected (a chunk does not elaborate, or `setup` throws)
prints its diagnostics and leaves the config that was loaded in place, with
its jobs still running. The exit status is 0 when the script ran to its end,
1 when it could not, and 2 for a command line it does not understand. With
status 1 a line on stderr says why: the script cannot be read; a `settle`,
named by its line, ran out with a reload still running (a chunk or `setup`
is slow or does not end); a `join`, named by its line, ran out with a job
still running; or the editor thread did not answer.

Lake relinks the executables only when the Rust archive's contents change,
so a second `mise run lean` rebuilds nothing.

`mise run lean` runs the model tests first (`mise run lean-test`, below).
That is only so that two Lake builds never run in `lean/` at once: the tasks
that run Lake form one chain.

Use `mise run lean`, not a bare `lake build`. On both platforms the
executables have to be compiled and linked by the system compiler, and the
task sets `LEAN_CC=/usr/bin/cc` to say so: the clang bundled with Lean has no
`pthread.h` for the glue, on macOS or on Linux, and on macOS its linker
cannot link the system frameworks the window needs. Do not export `LEAN_CC`
in your shell. lean-fmt has to build with Lean's bundled compiler, and on
macOS under `/usr/bin/cc` its link fails with `library 'gmp' not found`.

The executables also do not start at Lean's `main`. Lean runs `main` on a
thread it creates, never on the process's main thread, and macOS only lets a
window event loop run there. So `editor_entry` in the glue runs in its place.
It keeps the real main thread for the Rust library and runs Lean's `main` on
a second thread with a large stack. On macOS the link names it as the entry
point (`-Wl,-e,_editor_entry`). On Linux that would skip the C library's
start-up, so the link renames instead (`-Wl,--wrap=main`): the start-up code
calls the glue's `__wrap_main`, and Lean's `main` is reached as
`__real_main`.

### The gate

```sh
mise run ci
```

This is everything that must pass before review and before landing: Rust
formatting, clippy, cargo-deny, rustdoc and the Rust tests; the Lean model
tests (`mise run lean-test`); the Lean build, lean-fmt's format and lint
checks; the checks of the Lean/Rust boundary, the contract checks against
the real bindings and the checks of the config session against the real
elaborator (`mise run ffi-test`); and the C format check. `hk check` runs the
same task.

The gate opens no window and needs neither a display nor Docker. Every
window it runs is the window port's fake, the scripted platform
(`crates/editor-platform`), which reports a fixed script and opens nothing.
What needs a display, a person or a container is a task of its own, below.

The Rust half needs no Lean toolchain: `mise run test` (`cargo test
--workspace`) builds and tests every crate with Cargo alone. Text storage
(`crates/editor-text`) is tested there in full: its unit tests, and property
tests that drive a text and a `String` with the same random edits and
compare them, convert every offset to a point and back, and load and save
arbitrary bytes; that hold the laws of change sets (composing, inverting,
mapping a position); that compare what the edit log records, the one
patch a subscriber gets and the trace of a range with references computed
from the strings; that keep the anchors a text holds in bounds and in
order through random transactions, merge selections that overlap, and
compare what a selection covers with a reference read off the string; and
that apply the inverses of random runs of revisions and drop them, against
the strings the text held at every revision. The property tests run from a
fixed seed and write no file.

Loading and saving a file are tested there too, and make no real file: the
logic (`crates/editor-text/src/file.rs`) reaches a file system only through
a port the crate defines, and its tests run on the port's published fake,
which `mise run lint` holds them to (`crates/editor-text/clippy.toml`). The
port's real adapter, over `std::fs`, is a crate of its own
(`crates/editor-fs-std`) whose tests hold it to the port's contract in a
temporary directory they make and remove. One test runs the logic over the
real adapter, the file service's wiring test
(`crates/editor-ffi/tests/files.rs`), also in a temporary directory of its
own.

The Lean half's logic needs no Rust library. The editor reaches the library
through interfaces it defines, each with a pure Lean model, and
`mise run lean-test` runs `lake test`: the model tests
(`lean/ModelTest.lean`), which run editor commands, the text interface's
contract and the cases of the undo tree, which is Lean over that interface,
against the model, and the config session's decisions (what a
reload elaborates, what it installs, how reloads are serialised) on
hand-written fakes, with no elaborator. They test the job system the same
way: the job interface's contract against its model and against the job
runner over a fake clock; that jobs in a wait hold no thread, that
cancelling a sleeping job ends it at once, that a job whose owner is removed
is cancelled, and that none of a job runs on the thread that spawned it,
each with the clock or a promise the test holds and no sleeping; and that
warming Lean's task pool makes all its threads. The task shows by behaviour
that they build without the library. It puts a `cargo` that always fails
(`lean/no-cargo/cargo`) first on the `PATH`, and Lake runs `cargo` on every
build that reaches the Rust archive, so the task passes only if the test
driver does not need it. The tests of the pool pin no size, so they pass
whatever `LEAN_NUM_THREADS` says: a bare `lake test` is enough.

`mise run ffi-test` runs `lean/.lake/build/bin/ffi-test`, the test executable
linked against the real library, then `contract-test`, `config-test`, and
then the editor: once with no arguments, and once in its headless mode on
the fixture under `tests/headless`, whose output must be exactly
`tests/headless/expected`. Two more runs pin its failure statuses: a command
line it does not understand must give status 2, and a script that cannot be
read status 1 with a line on stderr that says why. `contract-test` runs the
text interface's contract, the same list of properties the model tests run,
against the real binding, so the model cannot drift from the library: edits
and their refusals, revisions, snapshots that later edits leave alone, rows
and points in bytes and in UTF-16 against a table written out by hand,
releasing a text or a snapshot, applying a transaction and each way one is
refused, what changed since a revision and who wrote a range against tables
written out by hand, forgetting the start of a text's edit log, and applying
the inverse of a run of revisions and dropping kept inverses. It runs the
cases of the undo tree through the same binding. It also
checks what only the real binding
shows: the binding's table is the only holder of its documents and
snapshots, and releasing one frees it at once. It
runs the job interface's contract the same way, against the job runner over
the library's timer service, and checks what only the real service shows:
jobs in real waits hold no thread, cancelling a job takes its timer out of
the library's schedule, and quitting the queues ends the completion pump.

`config-test` also runs jobs through the headless host, on a fake clock it
moves: a job's handler runs on the editor thread, a reload that installs
cancels the old config's jobs and a rejected one does not, and a `join` that
cannot finish says so.

`config-test` (`lean/ConfigTest.lean`) is linked like the editor, with
Lean's elaborator, and is given the toolchain's directory and the package's
`.olean` directory as arguments. It checks the real elaborator and the
directory source against what the model tests' fakes assume, and runs the
headless host in-process on the real event queue and the real text binding:
a reload replaces a command; a type error, a throwing `setup` and a chunk
that declares `initialize` each keep the old config; a reload does not
register a command twice; a store's value survives a reload and is migrated
when its type changes; a command the library refuses is reported as refused
and leaves its store as it was; the editor answers events while a chunk
elaborates; reloads are serialised; and a script that cannot run to its end
says why. Its config directories are temporary directories of its own.

With no arguments `ffi-test` runs its checks of handles, plain data, the
event queues, the timer service, the document, the snapshot of a document,
a document's transactions and edit log, and the window: a snapshot reads
what its document held after the document is edited, and outlives it; a
transaction, a patch and a trace, which are lists, cross as words and come
back as the values that were sent; the scripted
platform's inputs arrive on the editor queue, each stamped with the instant
it was reported, and the keyboard check's loop (below) reports them; a
scripted platform that cannot open a window gives its reason, which the
keyboard check reports with status 1; and each event of a window is decoded
to the input the keyboard check counts. Three scenarios need a process each:

| Command | Shows |
|---|---|
| `ffi-test exit 7` | The entry point passes arguments to Lean's `main` and its result is the exit status. |
| `ffi-test shutdown` | Quitting the queues wakes every task blocked in a pull, and the process then exits. |
| `ffi-test exit-while-blocked` | An explicit exit ends the process although a task is still blocked in the library. |

The conventions every binding follows, and the test that pins each, are in
the crate docs of `crates/editor-ffi/src/lib.rs` and the module docs of
`lean/Editor/Ffi.lean`.

### The overflow check, on demand

```sh
mise run ffi-overflow
```

A stack overflow in interpreted Lean code is not caught: the process aborts.
This task shows it. It runs `ffi-test overflow <sysroot> <olean dir>`, which
has Lean's interpreter run a recursion deeper than its stack, and requires
the process to die of SIGABRT after it has printed the line that says it is
entering the recursion. No core file is written.

It is not part of the gate, and must not be added to it. On macOS every abort
makes the system write a crash report for `ffi-test` under
`~/Library/Logs/DiagnosticReports`, and the gate leaves the machine as it
found it. Run it by hand when the Lean toolchain changes, or the way the
executables are linked and started. The gate still builds the scenario and
its fixture.

The entry point gives every thread Lean creates a 64 MiB stack in place of
Lean's gigabyte, so the overflow takes milliseconds; `ffi-test` checks that
size in the gate, without aborting anything. `LEAN_STACK_SIZE_KB` in the
environment overrides it, and both tasks remove the variable.

### The config benchmark, on demand

```sh
mise run config-bench
```

This measures the config session in the executable as built, and asserts
nothing, so it is not part of the gate either. It runs `config-test`'s three
benchmark subcommands, each in a fresh process under `/usr/bin/time -l`,
which adds the process's real time and its maximum resident set size:

| Subcommand | Measures |
|---|---|
| `bench-start <sysroot> <olean dir> <module>…` | How long importing the base with those modules takes, and the first load of a 20-line config. Run for `Editor`, for `Editor Std` and for `Editor Lean`. |
| `bench-reload <sysroot> <olean dir>` | The median and the maximum of 20 reloads each of a one-line chunk, a 20-line config, and 50 definitions with a `simp` proof. |
| `bench-soak <sysroot> <olean dir> <count>` | The mean time of a reload over that many reloads of the 50-definition config. Run with 100 and with 500: about equal resident set sizes mean replaced configs are freed. |

A time is from the request for a reload to its report. The config is held in
memory, so the benchmark touches no files. Run it on a quiet machine.

### The job benchmark, on demand

```sh
mise run job-bench
```

This measures the latency of the editor loop while background jobs run, in
the executable as built, and asserts nothing, so it is not part of the gate
either. It runs `config-test bench-jobs <sysroot> <olean dir> 10000`. A
sample is the time from posting a request to run a command that does nothing
to the editor thread having run it. It takes 10,000 samples in each of five
rows and prints the median, the 99th percentile and the maximum of each, in
microseconds:

| Row | What runs meanwhile |
|---|---|
| idle | Nothing. |
| 64 jobs each sleeping 1 ms | 64 jobs from config, each sleeping a millisecond in a loop: every wait goes through the timer service and the completion pump. |
| one job a pool thread computing | Interpreted jobs that compute for ever, one for each thread of Lean's task pool. |
| two jobs a pool thread computing | Twice as many: half run and half wait in the pool's queue. |
| idle again | Nothing. |

It then times a million `now` requests in one compiled job, and says which
of the three loaded rows are within bound: a row whose median is at most
twice the larger of the two idle medians and whose 99th percentile is under
100 µs. That is an observation about one run, and the maximum is printed and
not judged. Run it on a quiet machine.

### The keyboard check, at the keyboard

```sh
mise run window-check
```

This opens a window and reports what of the keyboard reached a Lean loop. It
needs a display and a person, so it is not part of the gate. It runs
`editor window-check`: the real window, opened through the entry point on
the process's main thread, and a loop on a dedicated Lean task that pulls the
editor queue, as the command loop will. Start it from a terminal that is in
front; the system may otherwise keep the keyboard from the window until it
is clicked. Type in the window, then close it. The report is eight lines on
stdout:

```
window-check: composition <on|off>, limit <n> s; the main-thread service is on the process's main thread: <yes|no>
window: opened by <platform> <ms> ms after it was asked for        (or "could not open: <reason>")
focus: gained <ms> ms after the window opened; first pointer press in the window: <ms> ms after it opened
                                                                    (or "never gained", and "none")
keys: <n> key events reached the Lean loop (<p> presses, <t> of them repeats, <r> releases); text: "<the first 60 characters typed>"
latency from a key's arrival in Rust to its handling in Lean, in µs: median <m> / 99th percentile <p> / maximum <x> (<n> samples)
                                                                    (or "no samples")
dead keys: <n> key events marked dead
composition: <enabled|not enabled>; <a> preedit and <b> commit events; committed: "<the first 60 characters>"
ended: the window was closed                                        (or "the time limit", or "the window never opened")
```

A key's latency is the time from the instant the window's loop was handed
the key, read in Rust on the main thread, to the instant the Lean loop had
pulled the event and read the same clock. Every key event is a sample. The
check decides nothing about what a key means: it shows that keys, dead keys
and an input method's composition arrive.

| Option | Does |
|---|---|
| `mise run window-check -- --no-ime` | Runs the window with composition not allowed, so a dead key arrives as a key marked dead. Seen on Linux under Xvfb; not yet run on macOS. |
| `mise run window-check -- --seconds <n>` | Closes the window after that many seconds if nobody has (120 by default). |

The exit status is 0 when the window ran, 1 when it could not be opened and
2 when the options are not understood. A window that ran and never reported
that it opened counts as one that could not be opened, in the report and in
the status. The gate runs the same loop on the
scripted platform (`ffi-test`) and on a fake (`lean-test`), with no window,
and checks there what each option asks for.

### The window's contract, on a desktop

```sh
mise run window-contract
```

This holds the real window to the window port's contract
(`crates/editor-platform`, `contract`): it opens, it reports that it opened
before anything else, and it returns when it is asked to close from another
thread and not before, even if it was asked to close before it opened. A
window opens on this desktop for about a second, so it is not part
of the gate, which only builds it. It is the example of
`crates/editor-platform-winit`, and it prints one line; its exit status is
the result.

### The gate on Linux, on demand

```sh
mise run linux-ci
```

This runs `mise run ci` on Linux, in a container. It needs Docker and, the
first time, the network, so it is not part of the gate. `tools/linux/run.sh`
builds the image `tools/linux/Dockerfile` describes (Debian 13 with the
system compiler, mise and elan, each pinned), copies the checkout into a work
directory, and runs the gate there. The copy is the tracked files and the
untracked files git does not ignore, so uncommitted work is tested and this
machine's own build output is not touched. The exit status is the gate's.

| Where | What |
|---|---|
| `.linux-ci/home/` | The toolchains: rustup's, elan's, mise's installs. About 4.6 GB. |
| `.linux-ci/work/` | The copy of the source, with Lake's build output. About 1.2 GB. |
| The Docker volume `editor-linux-ci-cargo` | Cargo's home and `target/`. They must not be on a directory mounted from macOS: clean runs failed there. About 1.4 GB. |
| The Docker image `editor-linux-ci` | The system packages, mise and elan. About 0.9 GB. |

`.linux-ci/` is at the root of the checkout and ignored by git; set
`EDITOR_LINUX_CACHE` to put it elsewhere. `mise run linux-ci -- --clean`
empties the copy's build output first and keeps the toolchains and Cargo's
registry: everything is compiled again and nothing is downloaded again.

It runs on the machine's own architecture. It has been run on aarch64, not
on x86_64.

### The window on Linux, on demand

```sh
mise run linux-window
```

This is where the winit adapter is held to the window port's contract
without a desktop. Run it after a change to `crates/editor-platform-winit`
or to the contract in `crates/editor-platform`. It uses the image, the cache
and the volume of `linux-ci`, and runs three things under Xvfb, a display
that needs no screen and no person, failing if any fails:

1. the adapter's example, as `window-contract` runs it;
2. `editor window-check --seconds 5`, with xdotool giving the window the
   focus and typing a sentence and a dead key into it;
3. the same with `--no-ime`.

Its keys are synthetic. They go through the X server and the real window
library, so they show the path a key takes on Linux, but nobody typed them:
it is not the keyboard check above, and its output says so.

### Formatting

```sh
mise run lean-format   # Lean, with lean-fmt
mise run c-format      # C, with clang-format (.clang-format)
cargo fmt --all        # Rust
```

`mise run c-format` and its check, `mise run c-fmt`, look at tracked files
only, so `git add` a new C file before running them.

## Licence

GPL-3.0-or-later. See [`LICENSE`](LICENSE).
