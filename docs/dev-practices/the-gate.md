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

The gate opens no window, makes no surface on one, reads and writes no
clipboard, and needs neither a display nor Docker. Every window it runs is
the window port's fake, the scripted platform (`crates/editor-platform`),
which reports a fixed script and opens nothing; every clipboard is the
clipboard port's fake, which keeps text in memory. What needs a display, a
person or a container is a task of its own
([`on-demand-checks.md`](on-demand-checks.md)).

**So a green gate does not say a window draws or a clipboard works.** Two
things the editor must do are confirmed only outside it, by
`mise run linux-window`, in a container under Xvfb: that the window draws
a scene and input given to it arrives on the queue, and that text written
through the clipboard adapter is the text read back. A change that
touches the window, the surface or the clipboard is done when both this
gate and that task exit 0.

What the gate does check of the window, with none open:

- **The translation**, in `crates/editor-platform-winit`, on winit's own
  values built in the tests: a key's logical key, physical key, modifiers
  and text; the pointer's press, drag, release and wheel; a resize and a
  change of scale; the native handles; and what the drawer is told for
  each, damage and hiding among it, and after which events the display is
  asked for its refresh rate. Two of winit's events cannot be built
  outside winit, a key and a change of scale, so those are translated
  from their parts.
- **The port's contract**, in `crates/editor-platform`, on the fake and on
  platforms written to break each rule, those about the drawer among
  them; and the clipboard port's, on its fake and on clipboards written to
  break each property.
- **What the window tells reaching the render loop**, in
  `crates/editor-ffi`: which call on the loop each thing told becomes, on
  a loop stepped by hand over the render crate's fakes; and the session
  that starts the render thread, on a real thread over the scripted
  platform and the recording renderer, where a frame is drawn once for
  itself and once for a resize, nothing more is drawn, and the renderer is
  dropped on the thread that ran the window. Nothing sleeps: a renderer
  says on a channel that it drew, and each word is read with a bound.
- **What is decided about a surface**, in `crates/editor-render-wgpu`
  (`surface`), all of it, on a surface that is a script: what it is
  configured with from what it offers (the format, the view it is drawn
  on through, the present mode, the frame latency) and the format the
  pipeline is made for; that it is configured before the first draw,
  before a draw of another size, after a texture that no longer fitted
  and when its picture begins to be kept, and at no other time; what is
  done with each answer it can give when asked for a texture; and whether
  its picture is read back, and in what order of bytes. On wgpu's no-op
  back end: that a window no adapter can present to gives no renderer,
  and that a surface that offers its adapter nothing is refused.
- **What the window that draws makes of what it saw**, in
  `crates/editor-ffi` (`examples/window.rs`, whose unit tests `cargo
  test` runs, and which open no window): how its command line is read,
  and which of its options contradict each other; which findings of a
  frame's picture fail the run (a picture past the tolerance, of the
  wrong size, or that could not be read back fails; a surface that does
  not let its texture be copied from fails only a run given
  `--require-picture`; a run given `--no-picture` reads none and says
  so); which sizes a frame's glyphs are drawn at, and that any size but
  14 points times the window's scale fails; what the timeline says of
  the masks a draw used; and which ledgers show a window left alone for
  a second with a frame that was not laid out for the size and scale it
  last said.
- **Layout at a scale**, in `crates/editor-layout`, on the fake shaper:
  that a length a face states is a point, multiplied by the scale layout
  was last told before the shaper is asked for the font; that the same
  theme at scale 2 gives rows twice as tall and lines twice as wide, in
  rectangles that are still physical pixels; that the queries answer at
  the scale; and, by the counters, that a change of scale alone shapes
  every row a view shows again and that the scale a layout already has
  shapes none (`tests/scale.rs`, `tests/counters.rs`). In
  `crates/editor-render`: that several sizes told within one refresh, as
  a window going into fullscreen tells them, are one draw on the last.
  In `crates/editor-render-wgpu`: that a renderer says which masks its
  last draw used.
- **How the clipboard library's answers become the port's**, in
  `crates/editor-platform-arboard`, on values built in the tests.

What it cannot check, and so does not claim: winit's own loop, and the few
lines of the adapter that only a real window runs (the two that take a key
event and a change of scale apart, the readings of the window's size, its
handles and its display's refresh rate, and telling the drawer the window
is closing); wgpu's own calls that configure a surface, take its texture,
copy it out and present it, since the no-op back end hands out no surface
texture, and the few lines that forward to them
(`crates/editor-render-wgpu`, `gpu`, `OnSurface`); and anything a real
clipboard does. Of the scale and of fullscreen it cannot see anything a
window or a display does: that a window's scale reaches layout (the
example's line `14 points are <p> pixels`, checked by `mise run
linux-window` at scale 1 and by a person at scale 2); an apparent size
beside another app; a second display and a window moved to it; the
system's fullscreen; another Space; or what a window shows between two
sizes. Those are a person's to see
([`on-demand-checks.md`](on-demand-checks.md), "Scale and fullscreen, by
hand"), and no person has yet. `mise run lint` forbids to
tests the calls that open a clipboard, that make a renderer on a window
and, in `editor-ffi` as in the shaper's adapter, that read the machine's
fonts (`crates/editor-platform-arboard/clippy.toml`,
`crates/editor-render-wgpu/clippy.toml`, `crates/editor-ffi/clippy.toml`).

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

Rendering is tested there too, on a machine with no GPU, and the gate
needs none. What it checks:

- **The render loop**, in `crates/editor-render`, on the fakes the crate
  publishes: a recording renderer, a clock a test sets and a wait that
  never blocks. Newest wins in the mailbox; the scheduler's decisions,
  idle among them; what is and is not a demand, so that a frame submitted
  again draws nothing; a journal entry for each frame presented, with its
  three times, and none while idle; which rows are built again; and the
  port's contract, each property seen to fail on a renderer written to
  break it. One test runs the loop on a thread of its own, parked on a
  real condition variable; it and the tests of that wait read channels
  with a bound, and nothing sleeps.
- **The painter and the glyph cache**, in `crates/editor-render-wgpu`, on
  a hand-written rasteriser that reads no font: where each quad goes,
  the drawing order, what is rasterised once, what is never evicted and
  what the bound does.
- **The rasteriser**, on the fixture fonts under `tests/fonts`, compiled
  in, with glyph ids read from each font's own character map. Its tests
  state relations only (more ink, wider, differs, the same twice).
- **One picture.** The headless adapter draws one frame of real text on
  the CPU, and no channel of any pixel may be further than 2 of 255 from
  the reference image checked in at `tests/render/frame.png`
  (`crates/editor-render-wgpu/tests/reference.rs`). The image is compiled
  into the test, so nothing is read or written when it runs; its README
  says what it shows and when to make it again. That test and one other
  (`tests/reuse.rs`) are the only two that run the real shaper outside
  its own crate, for the wiring alone.
- **The wgpu adapter's calls.** It runs on wgpu's no-op back end, which
  validates every call as a real one would and draws nothing: the shader
  compiles in both its forms, the pipeline's vertex layout is the
  shader's, and a frame with every kind of quad and every kind of atlas
  page is drawn inside an error scope with no error
  (`crates/editor-render-wgpu/src/gpu/tests.rs`).

What it cannot check, and so does not claim: what a GPU draws. wgpu has
no software renderer of its own, so a machine with no GPU and no driver
has no adapter, and no test asks for one: `mise run lint` forbids the
call that does (`crates/editor-render-wgpu/clippy.toml`). The validation
is not everything either: a vertex attribute of the wrong type is
refused, and one with too few components is not. The picture a real GPU
draws is compared with the reference image by tasks of their own, outside
the gate ([`on-demand-checks.md`](on-demand-checks.md)), and so is what
is drawn in a window: a frame presented to a window's surface is read
back and compared with the CPU's picture by `mise run linux-window`, in
the container, which fails unless every frame's was, and by
`mise run window-contract` on a desktop, which lets one thing pass
uncompared and says so: a surface that does not let its texture be
copied from.

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
