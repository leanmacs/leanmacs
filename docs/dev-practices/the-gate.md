# The gate

```sh
mise run ci
```

This is everything that must pass before review and before landing: Rust
formatting, clippy, cargo-deny, rustdoc and the Rust tests; the Lean model
tests (`mise run lean-test`); the Lean build, lean-fmt's format and lint
checks; the checks of the Lean/Rust boundary, the contract checks against
the real bindings and the checks of the config session against the real
elaborator (`mise run ffi-test`); the headless mode run from a staged app
bundle (`mise run bundle-test`); and the C format check. `hk check` runs the
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
  asked for its refresh rate. winit's event for a change of scale cannot
  be built outside winit, so it is translated from its scale, and a key
  is translated from its parts, though winit 0.31's key event can be
  built.
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
event and a change of scale apart, which `mise run linux-window` runs on
winit's own events, keys typed by xdotool and a change of the display's
settings while the window is open; the readings of the window's size, its
handles and its display's refresh rate; sending the window's request to
its input method; ending the loop when it is woken with a close asked;
and telling the drawer the window is closing); wgpu's own calls that configure a surface, take its texture,
copy it out and present it, since the no-op back end hands out no surface
texture, and the few lines that forward to them
(`crates/editor-render-wgpu`, `gpu`, `OnSurface`); and anything a real
clipboard does. Of the scale and of fullscreen it cannot see anything a
window or a display does. That a window's scale reaches layout is seen
outside it, by `mise run linux-window`: the example's line `14 points
are <p> pixels` shows it only at a scale other than 1, so that task runs
the window a second time with winit told a scale of 2 and requires `at
scale 2: 14 points are 28 pixels`, which a layout never told the scale
does not give ([`on-demand-checks.md`](on-demand-checks.md), "The window
on Linux, on demand", part 4). That task also changes the scale under
an open window, once, from 1 to 2. The rest is a person's to see: an
apparent size beside another app; a display that is itself at scale 2;
a second display and a window moved to it; the system's fullscreen;
another Space; or what a window shows between two sizes
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

Fuzzy matching is tested there too. The rule that orders the candidates a
pattern matches (`crates/editor-fuzzy`) reaches a matching library only
through the `Scorer` port it defines, and is tested on a scorer written
in its tests that answers canned scores: a candidate that is the pattern
first, then by score, then in the order the candidates came. The port's
published fake and its contract are tested there, the contract on
scorers written to break each of its rules. The port's real adapter,
over `nucleo-matcher` (`crates/editor-fuzzy-nucleo`), is held to that
contract, which sweeps generated texts from a fixed seed, and to its own
two cases: a pattern whose characters are in a candidate in order but
apart matches it, and one with a character the candidate lacks does not.
No test pins a score. One test runs the rule over the real adapter
through the C function, for the wiring alone
(`crates/editor-ffi/tests/fuzzy.rs`). `mise run deny` holds that only the
adapter depends on the library. It checks no licence: the library's is
MPL-2.0, and whether that is acceptable in this workspace is the owner's
to confirm.

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
and at selections, undo and redo, windows, and scrolling: a window's
scroll anchor read and placed, a command's question about its view with
the snapshot it takes and releases, and the loop's follow of the next
scene's views. A command that starts a job
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
fills those roles. A prompt's candidates are checked on that driver as
well (`ModelTest.candidateChecks`), with commands written in the test:
after the asking step and after each key the prompt's listing is the one
for the minibuffer's text; the scene's minibuffer status line is the
label and then a field for each candidate the fuzzy model answers for the
text, a candidate that is the text first; the keys of the roles
`next-item` and `previous-item` move a choice, which the scene shows in a
face of its own; the accept key gives the continuation the chosen
candidate, and the typed text when nothing is chosen or nothing matches;
and a command that fails is rolled back to the listing and the choice
from before it. The state's side (opening and closing a prompt, the
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
  of the save's result; a quit is withdrawn when that save is refused,
  whether or not the buffer is modified, and when the buffer is edited
  meanwhile; and a reload a command asked for is
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
  by hand, outside the repository.
- **Evil's editing commands**, the same way (`evilOperatorChecks`,
  `evilSelectionChecks`, `evilRegisterChecks`, `evilOpenChecks`,
  `evilUndoChecks`, `evilRepeatChecks`). An operator's row also says the
  unnamed register after and whether it is line-wise, or that it is as it
  was, which a sentinel set before the keys shows, whether the view is
  left in insert state, and whether the command gave up or broke off
  (`docs/design/keymaps-and-modes.md`, "Operators as built"). The table of
  `d c y` over each of the fifteen motions has five situations: no count,
  a count of 2, the cursor on an empty line, and the cursor on the
  buffer's last character with and without a final line feed. A check
  that reads the default key tables holds it complete, so a motion or an
  operator added with no rows fails it. A sweep presses every operator
  key with every motion key from every resting position of the sample
  texts. Beside them: the operators over a `v` and a `V` selection, `x`,
  `p` and `P`, `o` and `O`, `u` and `C-r` after a change of each kind,
  `.` after one, and the clipboard register, on the clipboard model, which
  a check sets and takes away. The clipboard interface's contract
  (`lean/Editor/Clipboard/Contract.lean`) runs on its model here, and
  `contract-test` runs it on the clipboard a host with no window keeps.
  The fuzzy matching interface's contract
  (`lean/Editor/Fuzzy/Contract.lean`) runs on its model here
  (`fuzzyFailures`), and `contract-test` runs it on its real binding:
  which candidates a pattern matches, and that a candidate that is the
  pattern is first. `fuzzyChecks` are what only the model shows, its
  order after the exact matches, and the contract seen to report a
  matcher that ignores case and one that does not put an exact match
  first. **The model and the binding are not held to agree on the order
  past the exact matches**, so every check above the port computes what
  it expects with the model.
  `textModelStepChecks` hold a premise of the theorem about undo where it
  is not proved: every live text of the model is in step after each
  request of a sample sequence.
- **Scrolling**, by two lists
  (`docs/design/keymaps-and-modes.md`, "Scrolling as built").
  `scrollChecks` run the scroll policy (`lean/Editor/Scroll.lean`) on the
  display model alone, with a view's scroll anchor and its cursor as
  offsets: a cursor among the rows shown keeps the anchor; one a row off
  an edge moves it a row, and one far off leaves the cursor's row at that
  edge; the last row of a wrapped line; the empty row after a final line
  feed; a view that shows no row; the scroll margin, swept from every row
  as the first row shown and every position as the cursor, with a margin
  of two, with none and with one larger than the view; what the policy
  costs in requests, on the counting model; and the anchors a scroll by
  rows and a scroll to the cursor's row place, swept the same way.
  `viewChecks` press keys on the loop's driver over the editor's models,
  under the Vim scheme that ships with evil's commands, in frames a few
  rows tall: a view follows its cursor after `j`, `k`, `g g` and `$` on a
  wrapped line, after a resize, and after an edit through another window
  on the same buffer; a motion that leaves the cursor shown leaves the
  anchor; the margin holds after every motion of the vocabulary; a failed
  command and a view whose selection marker was given up leave the
  anchor; `C-d`, `C-u`, `C-f` and `C-b` move the anchor and the cursor by
  half the rows and by the rows the view fits, with a count, at the
  text's two ends, in a text that ends in a line feed, in a visual state,
  and stopped by the interrupt before each of their requests; and `z t`,
  `z z` and `z b` put the cursor's row first, in the middle and last and
  change nothing else. **A check asks the display model which rows a view
  shows and which row holds the cursor**, for the scene's own snapshot
  and rectangle, so none says where a text wraps. **Nothing here runs
  over real layout**: the model's cells are one size.

The build checks the theorem that inserting at a
position and deleting what was inserted leaves the text
(`lean/Editor/Api/Theorems.lean`), and the theorem that `x` then `u`
restores the text, with its lemmas (`lean/Editor/Evil/Theorems.lean`,
`lean/Editor/UndoTree/Theorems.lean`, `lean/Editor/Text/Model.lean`). The task
shows by behaviour
that they build without the library. It puts a `cargo` that always fails
(`lean/no-cargo/cargo`) first on the `PATH`, and Lake runs `cargo` on every
build that reaches the Rust archive, so the task passes only if the test
driver does not need it. The tests of the pool pin no size, so they pass
whatever `LEAN_NUM_THREADS` says: a bare `lake test` is enough.

`mise run ffi-test` runs `lean/.lake/build/bin/ffi-test`, the test executable
linked against the real library, then `contract-test`, `config-test`, and
then the editor: once as `editor demo`, the demonstration, nine times in its headless
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
editor ships. A whole evil session on a real file is a process check of
its own, below (`session/script`). The eighth is `ex/script`, which also
has no `reload`: it
runs the ex line four times, with a name nobody bound, with `w` in the
scratch buffer, with `e`, where the scene lists the ex names the text
matches, `e` and then `reload`, and `<Tab>` and `<Enter>` run `e`, which
asks for a path with a prompt that lists none, and with `q`, which ends
the loop, so that the `scene` line
after it prints nothing; its output must be exactly `ex/expected`. The
ninth is `candidates/script` on the config in `candidates/config`, under
the Vim scheme and with the library's fuzzy matcher: a command of
config's asks with the candidates `wq`, `edit` and `w`; `w` is typed and
the scene lists `w` and then `wq` after the prompt's label, which only
the rule that a candidate that is the text is first orders, since the
library scores the two the same; `<Tab>` twice chooses `wq`, which the
scene shows in the chosen face; `<Enter>` gives config's command `wq`;
and with `z` typed the scene lists none and the command receives `z`. Its
output must be exactly `candidates/expected`.

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
that cannot name the table is rejected, and the check fails. A second
config names the operators, the repeat command and evil's undo: a
command of config's that runs the operate command with the arguments of
`d w` deletes a word, one that hands the repeat command that change
deletes the next, and one that runs evil's undo gives it back. A third
registers the operate command again, over the operators that ship and one
of its own, and the repeat command replays a change made with that
operator: it runs the command the registry holds for the name. Another
check runs a command of config's that writes the clipboard and one that
reads it through the host, which keeps a clipboard of its own, and a
finished job's command reads it too.

`ffi-test` also runs **an evil session on a real file**, as a process
(`tests/headless/session/`). The entry is one shell: it makes a temporary
directory with `mktemp -d` and removes it by a trap, copies `verse.txt`
there, and writes the script there from the template `script`, with the
copy's absolute path in place of `@FILE@`. The script has no `reload`. It
opens the file with `:e`, and then, by keys, runs a count and an operator
(`2dw`), a dot repeat, an undo, a change with typed text and its dot
repeat, a visual yank, a put, an undo and a redo, and `:w`, with a `scene`
after each step. The editor must exit with status 0; its output, with the
temporary directory's path written `@DIR@`, must be exactly `expected`,
which shows the text, the cursor, the selection, the state and the echo
of every scene; and the copy must hold the bytes of `verse-expected`.

`ffi-test` runs **a view that follows its cursor**, as a process, the same
way (`tests/headless/view/`). The entry copies `lines.txt`, 120 lines
`000` to `119`, each ended by a line feed, so that line n starts at byte
4n, into a temporary directory, and writes the script there from the
template `script`. The script has no `reload`. It sizes the frame with
`resize 640 480`, which in the recorder's cells of 8 by 16 is 80 columns
and 30 rows, opens the file with `:e`, and prints a `scene` after each
step:

| Step | The view's scroll anchor | Its cursor |
|---|---|---|
| The file is open | Byte 0 | Byte 0 |
| `100j` | Byte 284: line 71, so that line 100 is the last of 30 rows | Byte 400: line 100 |
| `C-u` | Byte 224: 15 rows up | Byte 340 |
| `C-f` | Byte 344: 30 rows down | Byte 460 |
| `C-f`, at the text's end | Byte 364: the empty row after line 119 is the last row shown | Byte 476: line 119, the last line |
| `z t` | Byte 476 | Byte 476 |
| `z b` | Byte 360: line 119 is the last of 30 rows | Byte 476 |
| `resize 640 160`, which leaves 10 rows | Byte 440: line 119 is the last of 10 rows | Byte 476 |

The editor must exit with status 0, its output, with the temporary
directory's path written `@DIR@`, must be exactly `expected`, and the copy
must still hold the bytes of `lines.txt`. The display is the recorder: the
display model's rule over the library's snapshots. The numbers in
`expected` were worked out by hand before the editor was run, and the run
agreed with each.

`ffi-test` runs **`j` and `k` aiming for a display column**, as a process,
the same way (`tests/headless/column/`). The entry copies `lines.txt` into
a temporary directory and writes the script there from the template
`script`. The file is three lines, each ended by a line feed: `a`, a tab
and `b`; the ten digits, which start at byte 4; and `世`, three bytes and
two columns wide, and `b`. The script has no `reload` and no `resize`, so
the frame is 0 by 0 and no view is laid out: the column is asked of the
line unwrapped and needs no rectangle. It opens the file with `:e` and
prints a `scene` after each step:

| Step | Its cursor |
|---|---|
| `l l j`, from `b` after the tab | Byte 12: the digit `8`, the tab stop's column |
| `k` | Byte 2: `b` again |
| `G l k`, from `b` after the wide character | Byte 6: the digit `2` |

The editor must exit with status 0, its output, with the temporary
directory's path written `@DIR@`, must be exactly `expected`, and the copy
must still hold the bytes of `lines.txt`. The display is the recorder.

`ffi-test` runs **milestone 1 over the whole program**, as a process, the
same way (`tests/headless/milestone/`), with `editor headless --render`:
the display is the real binding over the library's layout in cells of 8 by
16, bound to the headless render session, which draws every frame on the
CPU renderer. The script opens a copy of `source.txt`, 60 lines of Lean,
with `:e`, runs `2dw`, `.`, `u`, `j`, `cw` with a committed `edited`,
`<Escape>`, `$ p`, `u` and `C-r`, scrolls with `C-f`, saves with `:w`, and
ends with `idle 1000`. The editor must exit 0, its output must be exactly
`expected` (each `agree` line reads `agrees`: the rows the loop asked for
are the frame's, and `idle 1000: 0 frames drawn, 0 frames submitted`), and
the copy must hold the bytes of `source-expected`. That `agree` can say
anything but `agrees` is pinned in `config-test`
(`ConfigTest.agreementChecks`): on a scene and answers made there it says
`agrees`, `disagrees` with both sets of rows, that there is no rows query,
and that the frame has no such view. The idle second is the
one real-time wait of the gate's checks of drawing: it starts once the
render loop is at rest, so a slow machine cannot fail it, and it fails only
if something asks for a frame while nobody types. The render loop's own
rules (an equal frame is no demand; a loop at rest draws nothing) are
`editor-render`'s, pinned on a fake clock.

`ffi-test window-host <file>` runs **the window mode's wiring**
(`lean/Editor/Window/Real.lean`), as a process of its own, on the
library's scripted platform: a cells display bound to the presenter, a
clipboard of its own, the host opening a copy of `ex/note.txt`, and the
scripted sample window opening, sending its input and asking to close.
It must exit 0, which it does only when the window ran and closed and the
render session's counters show a frame drawn, and the copy must be
unchanged. `ffi-test window-host` with no file runs the same wiring as
Finder starts the app: the host posts no open, the window runs on the
editor's one empty buffer, and it must exit 0 the same way.
`ffi-test window-host-undrawn <file>` runs the same wiring on
the scripted platform whose renderer cannot be made, as a machine with no
usable GPU gives: it must exit 0, which it does only when the window mode
ended with status 1 and no render session was started, stderr must hold
`editor: nothing could draw in the window: ` and the platform's reason,
and the copy must be unchanged. `editor --bogus`, `editor a b` and `editor demo x` must each be status
2: any command line that is not `demo` alone, `headless` or `window-check`
is the window mode's, so a word is a file. `editor headless <config dir> <script file>`
from the build tree, outside a bundle, must be status 2 with a line on
stderr that starts `editor: no Lean toolchain`.

`mise run bundle-test` runs **the headless mode from an app bundle**, as the
installed editor will find its modules. In a temporary directory removed by
a trap, `tools/stage-bundle.sh` lays out `Leanmacs.app`: a copy of `editor`
in `Contents/MacOS`, and the `.olean`, `.olean.server` and `.olean.private`
files of the modules `Editor` imports (`config-test bench-modules`) under
`Contents/Resources/lean/toolchain/lib/lean` and
`Contents/Resources/lean/editor`. The copy then runs
`editor headless <config dir> <script file>` on `tests/headless/bundle`
with no directory argument, an empty environment (`env -i`: no `HOME`,
`PATH` or `LEAN_PATH`) and a working directory outside the bundle; it must
exit 0 and print exactly `expected`, whose command calls compiled code of
`Init` and of `Editor`. So the executable found the toolchain and its own
`.olean` files from its own path, and those three file kinds are enough to
import and run config: outside a bundle the same command line is refused,
and the build tree's `.olean` directory is not beside the copy. It has a
time limit of its own, 120 seconds, for copying the executable and the
module files.

What the gate checks of drawing, then: frames a bound display publishes
reach a render loop with the input they answer (`editor-ffi`'s tests,
`FfiTest.renderChecks`), the scripted window's session draws them, and the
whole program drawn by the CPU renderer agrees with its queries and rests.
What it does not: a real window, the system's fonts, a GPU, the desktop's
clipboard, and anything a person sees. Those are on demand
([on-demand-checks.md](on-demand-checks.md): `linux-window`, "The editor
on a file, by hand", "Milestone 1, measured"). The
three offsets were worked out by hand before the editor was run with the
change: before it the run printed bytes 6, 2 and 5.

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
arrive at a known request of a command. It runs the clipboard interface's
contract against the clipboard a host with no window keeps
(`lean/Editor/Clipboard/InProcess.lean`), and checks that a command run
against the library with no clipboard handed in is answered
`unavailable`, and that one handed a clipboard reaches it. It runs the
fuzzy matching interface's contract against its real binding
(`lean/Editor/Fuzzy/Real.lean`), so against the library's matcher, and
checks that a command run against the library that asks for a ranking is
answered by it. `ffi-test`'s own `fuzzyChecks` pin that a pattern, a list
of strings and the ranking cross the boundary.

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
keyboard check reports with status 1; a scripted platform whose renderer
cannot be made runs its window and then says why nothing drew in it; and
each event of a window is decoded
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
