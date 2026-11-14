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
compare what a selection covers with a reference read off the string; that
ask every motion from every position of a text and compare the answer with
a reference that lists the string's cells, rows and words first and picks
one, and read every row; and
that apply the inverses of random runs of revisions and drop them, against
the strings the text held at every revision. The property tests run from a
fixed seed and write no file. What a motion and a read of one row or a
range allocate on a megabyte of text is counted there too, in bytes
(`crates/editor-text/tests/snapshot_cost.rs`).

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
warming Lean's task pool makes all its threads. Loading and saving a file
from a job are tested there too, with no file: the job interface's file
properties run against a pure model of files and against the job runner
over a fake of the file service, in a made-up directory, and cases play a
command, a job and the job's command together on the models, a file a job
loads becoming a text among them. How a key becomes an invocation is
checked there as well, and it has no model and no fake, since it reaches
nothing: keymaps and the walk through a list of them, key strings, the
test scheme, and the scheme contract, run on the test scheme and on schemes
written to break it. The Vim scheme is checked there the same way: what an
edit compiles to, the registry of Vim states, the grammar (operators and
their targets, counts, registers, resets) on a registry and keymaps written
in the test, Vim states and the last change, the default states and
bindings through what each default key parses to, and the scheme contract
on the Vim scheme. So is the command loop's dispatch, on the models: keys
stepped through the test scheme, the commands they run, rollback, the
interrupt and the slow-command log, with the watch port's contract run on
its model. So are modes, on the test scheme's role table and leader: the
registered roles, the keymaps a mode makes for a scheme and what
`Mode.check` reports, a buffer's major and minor modes, a mode's lineage
and the active keymaps of a view, keys in the loop running a mode's
command, the on-enter action, and `defineMode` and its refusals. So is the
editor API a command is written with (`lean/Editor/Api.lean`): the state
requests' pure handler, request by request, with every layout invariant
kept; what the loop does with a command's state requests, rollback to the
state from before it and the markers and texts given up after it; and the
cases of the API (`lean/Editor/Api/Cases.lean`), each a command played as
the loop plays one, on the editor's models: buffers, edits at positions
and at selections, undo and redo, and windows. A command that starts a job
is checked there too, on the loop's driver over the models and the job
model (`lean/Editor/Loop/Driver.lean`): the job is handed its argument,
its result comes back as a command, and events fed meanwhile are handled
first; a job saves a snapshot its command took, and a job's command is
handed what its job loaded and no other job's. The file commands
(`lean/Editor/Files.lean`) are checked on that driver, over the model of
files, with no file touched (`ModelTest.fileCommandChecks`): opening a file
makes a buffer of its text, named by its base name, with its file's stamp
and dominant line ending; what is typed while a load is in flight is
handled first; a path that is open is shown and not loaded again; a save
writes the buffer's text and leaves the buffer not modified, with the
status line's modified field gone; a save of a file that changed on disk
leaves the file and says so; open then save with no edit writes the file
and leaves its bytes as they were, for LF, CRLF, both and bytes that are
not UTF-8; a second save while one is in flight, a buffer with no file and
a job that is not registered are each said in the echo area; and a save
that reports late marks the state it wrote. Prompts are checked on that
driver too (`ModelTest.promptChecks`), with the test scheme: a command asks
for a prompt and runs to its end, keys that print are typed into the
minibuffer, the accept key runs the command the prompt named with the
typed string, in the view the prompt was asked from, before the next
event, and the minibuffer's window is closed and its text released; a
prompt with an initial value answers with it; the cancel key runs nothing
and gives the focus back; a job's result is delivered while a prompt is
open; the scene shows the prompt text and the input after each key; and a
command that fails around a prompt, or is interrupted as it accepts, is
rolled back with the prompt as it was. The accept key and the cancel key
are read from the test scheme's role table, since the minibuffer's mode
fills two roles. The state's side (opening and closing a prompt, the
layout invariants with the minibuffer's window, the strip its place
takes) is checked with the state's operations, the scene's side with the
loop's, the notice a scheme is told with the loop's dispatch, and the
operations `prompt`, `acceptPrompt` and `cancelPrompt` with the cases of
the API. The editor state's side of a
save in flight, the snapshot the loop releases once a save has ended and
the saved mark a rollback takes back are checked with the state requests
and the loop's dispatch.

The ex command line (`lean/Editor/Ex.lean`) is checked there in layers,
so that a change to one breaks no other's checks:

- **A line and a binding, as data** (`exLineChecks`): what a typed line
  parses to, and the invocation a binding makes of an argument. Pure.
- **Ex bindings in the registry** (`registryChecks`, `setupChecks`,
  `reloadChecks`): by owner, bound from `setup` with its refusals, and
  replaced by an install, which keeps the compiled ones.
- **The requests a command makes for it**: which command an ex name is
  bound to, answered by the dispatcher from what it is told of the
  registry (`stateRequestChecks`, `dispatchStateChecks`); an invocation
  to be run after the command (`stateRequestChecks`, `promptChecks`, on
  the driver); and quit (`stateChecks`, `stateRequestChecks`,
  `apiStateChecks`, and one case of the API on the models and on the real
  binding).
- **Quit and reload in the loop** (`dispatchQuitChecks`), on the loop's
  driver over the model of files, with commands written in the test that
  name no ex name: the step says stop once the editor can leave, after
  its scene; a quit asked while a save is in flight stops at the delivery
  of the save's result; a quit is withdrawn when that save is refused and
  when the buffer is edited meanwhile; and a reload a command asked for is
  handed back with its step.
- **The ex line and the names that ship** (`exChecks`), on that driver,
  with the test scheme: the ex command and the accept and cancel commands
  are on keys of the test scheme and a line is a committed text, so no
  check names a Vim key. The ex line's own rules run on ex bindings
  written in the test: a name nobody bound, an argument a name does not
  take, an empty line, a bound command that is not registered or is
  refused. The five names run on `Ex.bindings`: `e` and a path, `w`, `q`
  with nothing modified, with a file's buffer modified and with the
  scratch buffer alone modified, `w` then `q` and `wq` while the save is
  in flight, `wq` with no file, with the file changed behind the editor
  and with another buffer unsaved, and `reload`. Each message is read
  from the function that makes it.

Evil, Vim's states and motions on the editor API (`lean/Editor/Evil.lean`),
is checked there in three layers, so that a change to one breaks no other's
checks:

- **What a scheme reports of a view, and what the loop does with it**, with
  no Vim key. The scheme interface's report on the test scheme, and the
  contract's property that a key which yields nothing leaves it as it was,
  on schemes written to break it. Then, with a scheme written in the test
  whose report a key's invocation switches, and commands written there:
  the scene's cursor and status field (`loopChecks`), the report a command
  is called with (`dispatchReportChecks`), that what is edited while a
  view is in an insert session is one step of the history
  (`dispatchUndoChecks`), and that a committed text is inserted only where
  the view takes text (`commitChecks`). The window's wanted column and the
  first window's shape are checked with the state's operations.
- **The Vim scheme's side**: a state's selection shape and the scheme's
  report of each view's state, on a registry written in the test and on
  the defaults by key (`vimRegistryChecks`, `vimStateChecks`,
  `vimDefaultChecks`).
- **Evil itself**, where Vim keys are pressed against a text, on the loop's
  driver over the editor's models, under the Vim scheme that ships with
  the commands compiled code registers (`evilRestChecks`,
  `evilMotionChecks`, `evilStateChecks`, `evilInsertChecks`). A check is a
  row: keys, a text with the cursor written into it as a bar, and the text
  after, written by hand from Vim's documented behaviour
  (`docs/design/keymaps-and-modes.md`, "Motions as built", has the table).
  Each of `h j k l w b e W B E ^ $ gg G` has rows with no count, a count
  of 1, a count inside the text and a count past it, and `0` its own; a
  sweep runs every motion from every position a cursor may rest at in the
  sample texts and holds the cursor to a cell that is not the line break
  of a line with content; `j` then `k` across a shorter line returns to
  its column; `i`, typed text and `<Escape>` are one step of the history,
  by an undo request; `a`, `I` and `A`; and the selection the scene shows
  after `v` and `V` and a motion. **No test runs Vim**, and nothing about
  Vim is in the build or the gate: the rows were compared with a local Vim
  by hand, outside the repository. The build checks the theorem that inserting at a
position and deleting what was inserted leaves the text
(`lean/Editor/Api/Theorems.lean`). The task
shows by behaviour
that they build without the library. It puts a `cargo` that always fails
(`lean/no-cargo/cargo`) first on the `PATH`, and Lake runs `cargo` on every
build that reaches the Rust archive, so the task passes only if the test
driver does not need it. The tests of the pool pin no size, so they pass
whatever `LEAN_NUM_THREADS` says: a bare `lake test` is enough.

`mise run ffi-test` runs `lean/.lake/build/bin/ffi-test`, the test executable
linked against the real library, then `contract-test`, `config-test`, and
then the editor: once with no arguments, eight times in its headless
mode on the fixtures under `tests/headless`, and twice more on a real file
in a temporary directory (below): with `script`, whose output must
be exactly `expected`; with `keys-script`, which sends keys with their
identity through the library's window input and whose output must be exactly
`keys-expected`; with `scene-script`, which enters insert state, commits
text through the window input, prints the scene the editor loop published,
and reloads and runs a job once the frame exists, and whose output must be
exactly `scene-expected`; and with `dispatch/script` on the config in
`dispatch/config`, which sends the keys of a command that loops and the
interrupt key, then the keys of a command that ends, then the keys of a
command that starts a job with an argument, whose result the job's command
says in the echo area, and whose output must
be exactly `dispatch/expected`; and with `files/script` on the config in
`files/config`, which runs the file commands the editor ships and touches
no file: `save-buffer` on the scratch buffer says it has no file, and a
command of config's opens a path that is not absolute, which starts the
compiled load job and is refused by the library before it asks the file
system, and whose output must be exactly `files/expected`; and with
`prompt/script` on the config in `prompt/config`, under the Vim scheme the
executable runs: a command of config's asks for a prompt, a key that
prints is typed into the minibuffer, whose view the scene prints with the
prompt text as its status line, `<Enter>` accepts and config's command
receives the answer, `<Escape>` cancels, and the compiled `open-file`, run
with no path, asks for one and opens the answer, a committed path the
library refuses, so the run touches no file; its output must be exactly
`prompt/expected`; and with `evil-script`, which has no `reload` and so
loads no config: it sends `i`, the keys of `hello`, `<Escape>` and `0`,
and its scenes must show the text, the cursor after each, and the state's
name in the status line, exactly as `evil-expected` has them. That run is
evil's wiring on the real library: every command its keys run is one the
editor ships. The eighth is `ex/script`, which also has no `reload`: it
runs the ex line three times, with a name nobody bound, with `w` in the
scratch buffer and with `q`, which ends the loop, so that the `scene` line
after it prints nothing; its output must be exactly `ex/expected`.

Two more entries of the task run the executable on a real file, and read
what a fixture's output cannot show: the process's exit status and the
file's bytes. They are the phase's first two acceptance criteria on the
executable.

- **Each entry is one shell.** It makes a temporary directory with
  `mktemp -d` and at once sets a trap that removes it when the shell ends,
  whether the check passed or failed. It copies the fixture
  `tests/headless/ex/note.txt` there, and writes the script there with
  `sed` from a checked-in template, `ex/save-quit-script` or
  `ex/wq-script`, in which `@FILE@` stands for the copy's absolute path:
  the file port refuses a path that is not absolute, and a checked-in
  script cannot name one. The headless mode runs a script written at run
  time as it runs a checked-in one.
- **What must hold**: the editor exits with status 0; the copy holds the
  bytes of `ex/note-expected`; and no line of the output starts with
  `commands:`, which the `show` line after the quit would print.
- **The first** runs `e` on the file, waits for the load, enters insert
  state, commits text, returns to normal state, runs `w`, waits for the
  save, and runs `q`. **The second** runs `wq` in place of `w`, the wait
  and `q`, and waits after it.
- **Why the `wq` script waits after `wq`.** The quit `wq` asks for waits
  for the save, so the loop is still running after the line. With no wait
  the `show` line would be handled while the save runs, and the end of the
  script would stop the loop, which cancels the save: the check would
  print a `commands:` line and pass or fail on the file by timing. With
  the `join` the script is read no further once the save's delivery has
  ended the loop. Seen by hand: the template without its last `join`
  printed the `commands:` line and left the file unwritten, six runs of
  six, and each check as it is passed forty runs of forty
  ([headless-mode.md](headless-mode.md), "A script waits where a command
  starts a job").
- **They are shell in this task and not Lean** because Lean spawns no
  child process: child processes belong to the Rust process service, since
  Lean never kills or reaps one (`docs/design/overview.md`, "Rules of the
  boundary"). So `config-test` spawns nothing, and the editor is a child
  of the task's shell, which the task's time limit ends if it hangs.
- **They are hermetic.** The scripts have no `reload`, so nothing of the
  config directory is loaded. The only file the editor opens or writes is
  the copy: a save writes a temporary file beside its target and renames
  it, so nothing is written outside the temporary directory. The
  checked-in fixtures are read and never written.
- **What is left behind if the task is killed** by a signal its shell
  cannot catch: the temporary directory, in the system's temporary
  directory, and nothing else.

Two more runs
pin its failure statuses: a command
line it does not understand must give status 2, and a script that cannot be
read status 1 with a line on stderr that says why. `contract-test` runs the
text interface's contract, the same list of properties the model tests run,
against the real binding, so the model cannot drift from the library: edits
and their refusals, revisions, snapshots that later edits leave alone, rows
and points in bytes, in UTF-16 and in cells against a table written out by
hand, releasing a text or a snapshot, applying a transaction and each way
one is refused, what changed since a revision and who wrote a range against
tables written out by hand, forgetting the start of a text's edit log,
applying the inverse of a run of revisions and dropping kept inverses,
reading one row and a range, and every motion from every position of one
text against a table written out by hand, with each way a motion and a read
are refused. It runs the
cases of the undo tree through the same binding, and plays the cases of the
editor API on it, with a recorder as the display, so every request an
operation of the API makes of the library is answered the same by the model
and by the binding. It also
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
their own. `config-test` also runs the file commands and their jobs as
compiled code registers them (`ConfigTest.fileChecks`), through headless
hosts over the real elaborator, queue, text binding and file service, on
real files: each check makes its temporary directories, writes its files'
bytes itself and hands its host the paths. They are the phase's acceptance
tests on the real library: a file is opened into a buffer the focused view
shows, named by its base name; a modified buffer is saved, the file's bytes
are its text and the status line loses its modified field; a path already
open starts no second load; a file with LF endings and one with CRLF
endings, each opened and saved with no edit, have the bytes they had, with
the save job seen to end `ok` and the echo area to say the file was
written; a file changed on disk is left as it is, with the changed-on-disk
refusal and the file's stamp in the echo area; and a path with no file
says so and leaves the window; and the open command run with no path asks
for one, and opens the path committed into the minibuffer once the accept
key is pressed. These hosts share one table of waits and one completion
pump.

`config-test` runs prompts through headless hosts as well
(`ConfigTest.promptChecks`), over the real queue, the real text binding
and the real elaborator, with the test scheme and the minibuffer's
commands and mode as compiled code registers them: the scene of an open
prompt, with a committed text in the minibuffer; the accept key and the
cancel key; a job's result delivered while a prompt is open, on the fake
clock; a continuation that config registers, looked up when the answer
arrives, across a reload that replaces it and one that drops it; the
answer's command run before a key sent right after the accept key; and a
continuation over a store reading the cell after the accepting command's
write.

`config-test` runs the ex command line through headless hosts too, with
the test scheme and the ex line's commands and the ex names that ship as
compiled code registers them. `ConfigTest.exChecks`, over the real
elaborator: a config binds a key to a command, its file is rewritten to
bind the key to another, the ex line `reload` is run, and the key runs the
other command, with no restart; an ex name config binds runs config's
command with the rest of the line, and is not an ex command after a
reload of a config without the binding; config's binding of a shipped
name runs in its place until a reload drops it; and a name nobody bound
is said in the scene's echo, with the editor going on.
`ConfigTest.exScriptChecks`, with `Headless.run` on scripts built in the
check, over the library's file service on a file each check writes in a
temporary directory of its own: `e`, a commit, `w`, a join and `q` leave
the file with the buffer's text and end the script with no failure, with
the `show` line after the quit not run; so does `wq` with a join after
it; a `q` that is refused leaves the script running; and a wait on a host
whose loop a command ended answers `ended`. No test of `config-test`
spawns a process.

`config-test` also loads a config that names evil's vocabulary
(`ConfigTest.evilChecks`): a command of config's hands the move command
the table of motions the editor ships, as it is and with a motion of
config's own added, and the cursor goes where config's motion says. That
is the check of what the root module lets config name of evil: a config
that cannot name the table is rejected, and the check fails.

`config-test` also runs jobs through the headless host, on a fake clock it
moves: a job's handler runs on the editor thread, a reload that installs
cancels the old config's jobs and a rejected one does not, and a `join` that
cannot finish says so. It sends keys to hosts over the test scheme, with
compiled commands and bindings written in the test: a key runs its command,
a failed command is rolled back, the interrupt key stops a command that
loops and stops nothing when none runs, a reload replaces config's commands
and bindings and leaves the compiled ones, and a slow command is logged, on
the fake clock; and a role's key runs the store command of a mode config
defines, in a view of a buffer that has the mode, until a reload drops the
mode and the key runs the global binding. It runs commands no key ran
through the host's loop as well: the driver's `run` makes the frame, is
rolled back when it fails and is stopped by the interrupt key; a key's
command starts a job with an argument, keys sent while the job sleeps on
the fake clock are handled before its result, and its command then runs
with the value the job computed; a job's command that loops is stopped
by the interrupt key; and a compiled job a host is handed is started by a
compiled command before any config is loaded, and is not cancelled by a
reload. `contract-test` runs the watch port's contract against its
real binding, over the library's interrupt flag, and has the interrupt key
arrive at a known request of a command.

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
what its document held after the document is edited, and outlives it; each
motion of a snapshot crosses under its own tag, and one row and a range
come back as text; a
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
