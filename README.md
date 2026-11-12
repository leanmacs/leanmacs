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
commands the config registers and starts its background jobs.

## Building

The build runs on macOS only for now.

### Prerequisites

- [mise](https://mise.jdx.dev), which installs the tools `mise.toml` pins
  (Rust, cargo-deny, hk, pkl, clang-format) and runs every task below. Run
  `mise install` once in the checkout.
- `uv` or `pipx`. mise uses one of them to install clang-format, and
  `mise.toml` does not pin either.
- Lean, at exactly the version in `lean/lean-toolchain`, with `lean` and
  `lake` on the `PATH`. `mise install` does not provide it.
  [elan](https://github.com/leanprover/elan) reads that file and does.
- The Xcode command line tools, for `/usr/bin/cc`.
- Network access for the first build, when Lake fetches lean-fmt.

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

The executable is about 180 MB: it can elaborate config, so Lean's
elaborator is linked into it.

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

Use `mise run lean`, not a bare `lake build`. On macOS the executables have
to be compiled and linked by the system compiler, and the task sets
`LEAN_CC=/usr/bin/cc` to say so: the clang bundled with Lean has no
`pthread.h` for the glue, and its linker cannot link the system frameworks a
window needs. Do not export `LEAN_CC` in your shell. lean-fmt has to build
with Lean's bundled compiler, and under `/usr/bin/cc` its link fails with
`library 'gmp' not found`.

The executables also do not start at Lean's `main`. Lean runs `main` on a
thread it creates, never on the process's main thread, and macOS only lets a
window event loop run there. So the link names `editor_entry` in the glue as
the entry point. It keeps the real main thread for the Rust library and runs
Lean's `main` on a second thread with a large stack.

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

The Rust half needs no Lean toolchain: `mise run test` (`cargo test
--workspace`) builds and tests every crate with Cargo alone.

The Lean half's logic needs no Rust library. The editor reaches the library
through interfaces it defines, each with a pure Lean model, and
`mise run lean-test` runs `lake test`: the model tests
(`lean/ModelTest.lean`), which run editor commands and the text interface's
contract against the model, and the config session's decisions (what a
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
against the real binding, so the model cannot drift from the library. It
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
event queues, the timer service and the document. Three scenarios need a
process each:

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
