# The gate

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
What needs a display, a person or a container is a task of its own
([`on-demand-checks.md`](on-demand-checks.md)).

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

Shaping with real fonts is tested there too, and uses no font of the
machine. Layout (`crates/editor-layout`) measures text only through the
`Shaper` port it defines, and its tests run on the port's published fake.
The port's real adapter, over Parley (`crates/editor-shape-parley`), is
held to the port's contract and to its own rules on five fixture fonts
checked in under `tests/fonts`, at the root of the repository, whose
README says where each comes from, under which licence, and what the
tests rest on in each. They are compiled into the tests, so no test reads
a file when it runs, and a font set made of them has the system's fonts
off: a letter no fixture font has comes out as the primary fixture's
missing glyph, on any machine. `mise run lint` holds the adapter's tests
to that (`crates/editor-shape-parley/clippy.toml`: no file, no
environment variable, and no call that asks for the system's fonts). One
file runs layout over the real adapter, for the wiring alone
(`crates/editor-shape-parley/tests/layout.rs`). The fixture fonts are
made by `tools/fonts/subset.sh`, by hand and never by the gate. The
system's fonts have a check of their own, outside the gate
([`on-demand-checks.md`](on-demand-checks.md)).

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
warming Lean's task pool makes all its threads. Loading and saving a file
from a job are tested there too, with no file: the job interface's file
properties run against a pure model of files and against the job runner
over a fake of the file service, in a made-up directory, and cases play a
command, a job and the job's command together on the models, a file a job
loads becoming a text among them. The task shows by behaviour
that they build without the library. It puts a `cargo` that always fails
(`lean/no-cargo/cargo`) first on the `PATH`, and Lake runs `cargo` on every
build that reaches the Rust archive, so the task passes only if the test
driver does not need it. The tests of the pool pin no size, so they pass
whatever `LEAN_NUM_THREADS` says: a bare `lake test` is enough.

`mise run ffi-test` runs `lean/.lake/build/bin/ffi-test`, the test executable
linked against the real library, then `contract-test`, `config-test`, and
then the editor: once with no arguments, and twice in its headless mode on
the fixture under `tests/headless`: with `script`, whose output must be
exactly `expected`, and with `keys-script`, which sends keys with their
identity through the library's window input and whose output must be exactly
`keys-expected`. Two more runs pin its failure statuses: a command
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
It runs the job interface's file properties against the runner over the
library's file service, on real files: each property has a temporary
directory of its own, made and removed by the test, and a file loaded and
saved without edits must be byte for byte what it was, for LF, CRLF and
bytes that are not UTF-8. It plays the cases that cross the two interfaces
on the real binding and that service, and checks that a load writes nothing
to the editor's table of snapshots until the job's command takes it in, and
that what a job loaded is freed when the job is settled. `ffi-test` checks
the bindings of the file service, and `config-test` a job from config that
loads a file through the headless host, each in temporary directories of
their own.

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
it was reported, and the keyboard check's loop
([`on-demand-checks.md`](on-demand-checks.md)) reports them; a
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

## Formatting

```sh
mise run lean-format   # Lean, with lean-fmt
mise run c-format      # C, with clang-format (.clang-format)
cargo fmt --all        # Rust
```

`mise run c-format` and its check, `mise run c-fmt`, look at tracked files
only, so `git add` a new C file before running them.
