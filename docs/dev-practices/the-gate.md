# The gate

```sh
mise run ci
```

This is everything that must pass before review and before landing: Rust
formatting, clippy, cargo-deny, rustdoc and the Rust tests; the check that
every copy of the Lean pin equals the pin and the Lean model
tests (`mise run lean-test`); the Lean build, which links the editor from
the default package set, lean-fmt's format and lint
checks; the same tests, lint, format check and headless fixtures over
every package of the fixture set, the default packages among them ("The
package steps", below); the checks of the Lean/Rust boundary, the contract checks against
the real bindings and the checks of the config session against the real
elaborator (`mise run ffi-test`); the headless mode run from a staged app
bundle (`mise run bundle-test`); a user's package set built, installed and
restarted into end to end through the launcher (`mise run
user-sets-test`); the C format check; and the workflow lint
(`mise run workflow-lint`: actionlint, zizmor and the structural check of
the CI workflow). `hk check` runs the same task, and CI runs it, unchanged,
on `macos-26` and on `ubuntu-24.04` for every push and pull request
([`ci.md`](ci.md)). The pre-commit hook runs it too, when a staged path
is one the gate reads ("The pre-commit hook", below).

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

Two checks of the repository rather than the editor are outside the gate
too: `mise run secrets-scan`, gitleaks over `main`'s history (the copy
`linux-ci` runs the gate in has no history), and `mise run infra-check`,
the offline checks of the repository's GitHub settings in `infra/github`.
Neither runs in `ci` or the hk hooks; both are in
[`publishing.md`](publishing.md).

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
  its picture is read back, and in what order of bytes. The format is
  chosen for each blending: in linear light an sRGB one, and encoded a
  format that is not sRGB, as it is or through a view, or, where the
  surface offers no 8-bit format with an sRGB pair, linear light's
  choice with the surface saying it blends in linear light; the colour
  space is `Auto` under both. On wgpu's no-op back end: that a window no
  adapter can present to gives no renderer, and that a surface that
  offers its adapter nothing is refused.
- **What the window that draws makes of what it saw**, in
  `crates/editor-ffi` (`examples/window/`, whose unit tests `cargo
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
- **A resize's final state, the paper around a frame, and the Metal
  layer's rules** (text-rendering phase 3), each asserted once the system
  is idle and never as a count that depends on timing:
  - `crates/editor-render` (`render_loop`): once at rest after six
    scripts of a resize (sizes within a refresh, frames one size behind,
    a failed and a hidden draw among them, a change of scale alone, a
    size and back), the last request is on the last size asked with the
    frame laid out for it, nothing more is drawn over a further 100
    refreshes, and every draw is on the size last asked before it;
  - Lean (`ModelTest/Editor/Loop.lean`): a burst of resizes, a key among
    them, publishes a scene for each event and ends in one of the last
    size that tiles it;
  - `crates/editor-ffi` (`display.rs`): a bound display, told resizes as
    the window session tells them, draws its last frame at the size and
    scale the window last said, the window's own sequence for a change of
    scale among them;
  - `crates/editor-render-wgpu` (`surface`): a window's surface is
    configured `Opaque` where it offers that and `Auto` otherwise, at the
    size of the last draw whatever it answered between, not again for a
    draw at the size of one whose texture was not presented, and at the
    new size, not the scale, for a change of scale;
  - `crates/editor-layout` (`frame`): a frame's ground is the default
    face's background, `BASE_BACKGROUND` while nothing defines one, frames
    that differ only in it differ, and one made by hand has `Color(0)`;
  - `crates/editor-render-wgpu`: the CPU's clear is the ground at full
    opacity (`cpu`), the GPU's in the space the device blends in
    (`gpu/tests.rs`, `clear_color`), every kind of quad is drawn on the
    no-op back end on a ground that is not black, and, through the public
    API, a half-covered frame is its view's background and its ground and
    nowhere black (`tests/ground.rs`);
  - the window port's `Request::Background`: the scripted platform
    records and shows it, the request contract holds a carrier to it (a
    fresh window has none, the last wins, it and every other thing shown
    leave each other alone), the winit adapter sets one only when it is
    not the one asked last and turns it into AppKit's components
    (`asked.rs`, `background.rs`), the presenter sends a frame's ground
    only when it changes and after the title and the menu bar
    (`render.rs`), its words cross to Lean (`asked_words`, tag 8) and Lean
    reads them (`askedOf`, `FfiTest/Editor/Ffi/Window.lean`), and the
    window-host check finds the built-in theme's paper the last background
    asked;
  - `crates/editor-render-wgpu` (`layer`): `misses` on readings built in
    code, each rule alone, a layer read across a change of scale, and
    `Followed::holds`; a renderer with no window has no layer to read;
  - `crates/editor-platform-winit` (`examples/settings/reading.rs`, run by
    `cargo test` since the example is declared `test = true`): the window
    settings' rules, a background 2/255 off missing.
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
an open window, once, from 1 to 2. No check sees the rest: an apparent
size beside another app; a display that is itself at scale 2; a second
display and a window moved to it; the system's fullscreen; another
Space; or what a window shows between two sizes
([`on-demand-checks.md`](on-demand-checks.md), "The window's scale, as
seen"). `mise run lint` forbids to
tests the calls that open a clipboard, that make a renderer on a window
and, in `editor-ffi` as in the shaper's adapter, that read the machine's
fonts (the root `clippy.toml`, which every crate reads).

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

Loading and saving a file, listing a directory and making one are tested
there too, and make no real file: the
logic (`crates/editor-text/src/file.rs`) reaches a file system only through
a port the crate defines, and its tests run on the port's published fake,
which `mise run lint` holds them to (the root `clippy.toml`). The
port's real adapter, over `std::fs`, is a crate of its own
(`crates/editor-fs-std`) whose tests hold it to the port's contract in a
temporary directory they make and remove: a directory made with its
parents, made again, and refused where a file is, among its rules. One test runs the logic over the
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
to that (the root `clippy.toml`: no file, no
environment variable, and no call that asks for the system's fonts). One
file runs layout over the real adapter, for the wiring alone
(`crates/editor-shape-parley/tests/layout.rs`). A text's own spans (a
syntax's highlights) reach layout through a port of its own, `TextSpans`;
layout's tests run on its published fake, `FixedSpans`, and its contract
(`scene::spans_contract`) is seen to bite on spans not cut, of a face it has
not, and ending inside a character. The fixture fonts are
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
(`crates/editor-ffi/tests/fuzzy.rs`). Locating a pattern with errors
allowed, the crate's second rule (`src/locate.rs`), reaches a library only
through the `Searcher` port: which span is answered (fewest errors, then
nearest, earliest, longest, and never one that cuts a character) is tested
on the published fake, `Scan`, and on searchers that answer canned spans;
the port's contract, `contract::check_searcher`, against an exhaustive
oracle, is tested on `Scan` and on searchers written to break each of its
properties. The root `clippy.toml` refuses the clocks, every file of
the disk and both adapters' constructors in all of it. The searcher's real
adapter, over `triple_accel` (`crates/editor-fuzzy-triple-accel`), is held
to that contract, which sweeps generated texts from a fixed seed, and to
its own three cases: one substitution is found with one error, a
pattern with no span near enough reports none, and an empty text reports
the empty span exactly when the whole pattern is within the errors
allowed. `mise run deny` holds that
only that adapter depends on the library, and only `editor-ffi` on the
adapter, whose C function that locates a pattern has one wiring test
beside the ranking's. `mise run deny` holds that only the
adapter depends on the library. It checks no licence: the library's is
MPL-2.0, and whether that is acceptable in this workspace is the owner's
to confirm.

Syntax trees are tested there too. The core (`crates/editor-syntax`)
reaches a parser only through the `Syntax` port it defines, and is tested
on the port's published fake, a toy grammar of parens: the rule for what a
query answers of a range, on syntaxes that answer out of order, twice and
as tree-sitter does at a range's ends; a session's round, the delivery
rule and its stale results, and the fallback to a whole parse when an
incremental one has an error, on a recording mock, single-threaded; and the
worker stepped by hand and, in `tests/worker.rs`, on a real thread while
another edits and touches, with every wait bounded. The port's contract is
tested on the fake and on implementations written to break each of its
fourteen properties. The real adapter, over tree-sitter with the Rust,
JSON and Markdown grammars compiled in (`crates/editor-syntax-treesitter`),
is held to that contract for each grammar, over fixtures under
`tests/syntax/`: among it, that a tree told the edit log's patches and
reparsed as the core reparses equals a fresh parse, texts with errors among
them, on named cases and on a sweep of random edits from a fixed seed;
that the grammar's shipped queries of the kinds its corpus lists compile,
and none of another kind (`SHIPPED`); that its spans on the reparsed tree
equal a fresh parse's over the same edits (`HIGHLIGHTS_AFTER_EDITS`); that
a parse in ranges reads only them (`IN_RANGES`); that a range's matches,
flattened, are its captures, with each node's named children (`MATCHES`);
and each pattern's `#set!` settings (`SETTINGS`). The injection rule
(`inject.rs`) is tested on a mock that answers canned matches and on the
fake, and on the real grammars in the adapter's `tests/injections.rs`: a
Markdown fence's layer is its content parsed alone, a quoted fence leaves
out each `> `, and a Rust macro's token tree is a Rust layer. A session's
layers, its delivery again at the same revision when new injections find
new layers, the spans of a layer drawn over the host's and carried through
a patch, and its kept queries with their refusals are tested in
`session.rs`, single-threaded. Highlighting is tested on the fake: the rule
that turns captures into spans and the carrying of spans through a patch
(`highlight.rs`), which tree draws a snapshot (`session.rs`), and, in
`tests/highlight.rs`, a parse held on a real worker thread while an edit,
its touch, a language set for injections and a read of the highlights on
other threads each complete within a bound. `crates/editor-ffi/tests/syntax.rs` runs the syntax service on real
documents through their edit paths and the C functions, and
`crates/editor-ffi/tests/highlight.rs` highlights a Rust fixture, a TOML
fixture and a Lean fixture through the C functions, edits each, and holds its spans once
reparsed to a fresh highlight of its text; it runs layout's spans contract on the service, and
checks that a published scene paints a keyword in its face. It does the
same for a Markdown document given its injections and languages through the
C functions: a Rust fence drawn in Rust's captures, a JSON fence in JSON's,
no layer over a quoted fence's `> `, the spans after edits equal to a fresh
injected highlight, the spans contract with layers, and a fenced `fn`
painted in the keyword face. `mise run deny`
holds that only the adapter depends on tree-sitter and its grammars, and
bans `wasmtime` and `tree-sitter-loader`.

Child processes are tested there too. The service that runs a command
to its end, cancels it and shuts down (`crates/editor-process`) reaches
processes only through the `Processes` port it defines, and its tests run
on the port's published fake, which `mise run lint` holds them to
(the root `clippy.toml`). The port's contract is tested
there on the fake and on fakes written to break each rule. The port's
real adapter (`crates/editor-process-std`) is held to the same contract
on real processes, every one `/bin/sh` or another absolute path, in a
temporary directory its test makes and removes: among them a child that
starts a grandchild, which a kill, a cancel and shutdown must each end,
and whose child must be reaped; and streaming children, read as they
write, written to, held at their bound and cancelled, every wait on a
marker file a child makes or on the service's readout of a held child,
never a fixed sleep. `crates/editor-process-std/tests/sigpipe.rs`, a test
binary of its own, sets `SIGPIPE` to its default, as a Lean executable has
it, and writes to an input its child closed; `tests/large_write.rs` writes
256 KiB, four times a pipe, to `/bin/cat` through the service and reads it
all back. `crates/editor-ffi/tests/processes.rs`
runs a command through the C functions, `tests/processes_stream.rs`
streams a child through them and pulls one completion for a read from the
real completion queue, and `crates/editor-ffi/tests/processes_shutdown.rs`,
a test binary of its own, shuts the process-wide service down. No test
changes the test process's environment or working directory; the
environment a property sets goes to the child alone.

Watching is tested there too. The coalescing rule and the service that
owns each watch (`crates/editor-watch`) reach a file system only through
the `Watch` port the crate defines, and time only through its `Clock`, and
their tests run on the port's published fake, a file system in memory, and
on the manual clock, which `mise run lint` holds them to
(the root `clippy.toml`: no `std::fs`, no `Path` method that
asks the disk, no clock of the machine's, and not the adapter's
constructor). The port's contract, the service's properties among them, is
tested there on the fake and on fakes written to break each rule of the
port. The port's real adapter, over `notify`
(`crates/editor-watch-notify`), is held to the same contract on real files
in a temporary directory its test makes and removes, with a monotonic clock
of the test's own. Every wait is on a notice or a delivery that matches, up
to a deadline of 10 s, never a fixed sleep, and a negative claim is shown
by a sentinel noticed after it; on the fake the window passes on the manual
clock, so the coalescing property is deterministic there. On real files a
property checks that a kind is present, never an exact set: the platform
decides how its flags come. `mise run linux-ci` runs the same contract on
inotify, in the container's own `/tmp`. `crates/editor-ffi/tests/watches.rs`
watches a real file through the C functions and pulls the completion from
the real completion queue, and `crates/editor-ffi/tests/watches_shutdown.rs`,
a test binary of its own, shuts the process-wide service down.
`mise run deny` holds that only the adapter depends on `notify`, and that
only `editor-ffi` depends on the adapter.

Project search is tested there too. The port of the files under a root
(`crates/editor-grep`) is tested on its published fake, a tree in memory,
which `mise run lint` holds the crate's tests to
(the root `clippy.toml`: no `std::fs`, no `Path` method that
asks the disk, no clock of the machine's, and not the adapter's
constructor). The port's contract is tested there on the fake and on
implementations written to break each rule. The rule of which matches a
search answers is tested on the fake and the search engine's fake: walk
order, offsets, open buffers' texts in place of their files, the word
class, the limits, stopping, and that the pattern is compiled once a
branch a search, on an engine that counts what it compiles. The service
that owns each search is tested on the fake behind a gate the test holds
in front of every read: a delivery's bound and a file cut across
deliveries, the end delivered last, a search held back while its reader
takes nothing, cancelling mid-file and before the start is answered, an
id in use, and shutdown. Nothing sleeps; every wait is bounded. The
port's real adapter, over ripgrep's `ignore` and `grep-searcher`
(`crates/editor-grep-ripgrep`), is held to the same contract on real files
in a temporary directory its test makes and removes, and to its own cases
there: every match under a root with a `.gitignore` at the root and below
it, a `.ignore`, `.git/info/exclude`, hidden files, a binary file, CRLF
rows and a row that is not UTF-8, against a naive scan of the files no
ignore rule leaves out; the walk's order by name; `holds` asked once a row
across the reader's blocks; and a NUL past the first block. `mise run
deny` holds that only the adapter depends on the libraries, and that only
`editor-ffi` depends on the adapter. `editor-ffi`'s grep service
(`src/grep.rs`) is tested on the fake: how a start's words and strings
cross, which are refused, how a delivery and each refusal cross, and a
start read from words run on a service over the fake; and `mise run lint`
refuses the adapter's constructor anywhere in that crate but the process's
one service (the root `clippy.toml`). `ffi-test`'s grep checks
(`FfiTest.grepChecks`) start a search through the C functions in a
temporary directory, with an open buffer's snapshot in place of a file and
an ignored file left out, read its deliveries from the real completion
queue, and check a refused pattern's sentence, cancelling, and the
decoding of a reply. On the Lean side the job port's search properties
(`JobContract.grepProperties`) run against the pure model of project
search and the runner over its fake in `model-test`, and against the
library's grep service on real files in `contract-test`, beside its
`grepChecks`; `project-search` itself is pinned, in its package
(`packages/project-search/`), on the loop's driver over the models
(`ProjectSearchTest.projectSearchRunChecks`) and over the real bindings in
a temporary directory (`ProjectSearchTest.Linked.projectSearchChecks`).

Working sets are pinned the same way, in their package
(`packages/working-set/`). Their decisions are Lean's and run in its test
driver, `working-set-test`: the stored form and its JSON
(`WorkingSetTest.workingSetChecks`), the re-find ladder against the fuzzy
model (`WorkingSetTest.workingSetRefindChecks`), and, on the loop's driver over the
models, where ranges are held (`workingSetPlaceChecks`), the commands
(`workingSetRunChecks`, the phase's first acceptance criterion) and the
store under a state directory of the file model's, through a restart
(`workingSetDiskChecks`, the second). Its linked test runs both criteria
once over the real bindings (`WorkingSetTest.Linked.workingSetChecks`): the library's
file service, text store and fuzzy matcher and real git, in a repository and
a state directory of its own, both temporary, with the file rewritten by
`IO.FS.writeFile` between two hosts. No check reads `$HOME` or
`$XDG_STATE_HOME`: every state directory is handed in.

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
  the rasteriser port's published fake, which reads no font: where each
  quad goes, the drawing order, what is rasterised once, what is never
  evicted and what the bound does.
- **The rasteriser.** The rasteriser port's contract
  (`crates/editor-raster`, `contract`) runs on its published fake, plain
  and reading luminance, and on a rasteriser written to break each
  property, which must fail by that property's name; and on swash's
  adapter (`crates/editor-render-wgpu/src/raster.rs`), on the fixture
  fonts under `tests/fonts`, compiled in, with glyph ids read from each
  font's own character map. The luminance bucket rule and `Fallback` are
  tested on the fake. Every pure module of the Core Text adapter
  (`crates/editor-raster-coretext`: the bitmap and the pen, the smoothing
  decision on its published fake, what is declined, the fill grey, the
  mask comparison) runs on both legs; no test calls Core Text, and on
  macOS the gate builds the adapter and its example `check` and runs
  neither (`mise run coretext-check` runs it on demand). The swash
  rasteriser's own tests state relations only (more ink, wider, differs,
  the same twice).
- **Placement, against Core Text's.** The shaper's pen places of the
  sentence of the Core Text captures, in the fixture font at 28 and 14
  px, are within an eighth of a pixel of Core Text's
  (`crates/editor-shape-parley/tests/core_text.rs`), and the painter
  puts each of Core Text's places on Core Text's grid
  (`crates/editor-render-wgpu/src/placement_tests.rs`), both over
  `tests/coretext/positions.txt`, compiled in.
- **The blending**, in `crates/editor-render-wgpu` (`blend`, `cpu`,
  `tests/rasterizer.rs`): both arithmetics, linear light and
  sRGB-encoded values, for every kind of quad, with the contrast's
  luminance in linear light in either; the encoded arithmetic within 1
  of 255 of Core Graphics' own result on every case of
  `tests/coretext/blend.txt`, compiled in, and linear light missing its
  cases at half alpha; the compositor and the headless renderer blending
  as their settings say, and an encoded picture nowhere lighter than a
  linear one; `Settings::core_text()` blending encoded with a contrast
  of 0, and the swash fallback's weight fitted encoded
  (`weight_tests.rs`).
- **The renderer's picture.** The headless adapter draws one frame of
  real text on the CPU, and no channel of any pixel may be further than 2
  of 255 from the reference image checked in at `tests/render/frame.png`
  (`crates/editor-render-wgpu/tests/reference.rs`). The image is compiled
  into the test, so nothing is read or written when it runs; its README
  says what it shows and when to make it again. That test and one other
  (`tests/reuse.rs`) are the only two of that crate that run the real
  shaper, for the wiring alone.
- **The themes' pictures.** The theme picture check
  (`lean/Editor/Theme/Picture.lean`), in `mise run ffi-test`, publishes a
  fixture file from Lean through the display's real binding, in each
  theme it is handed, over a display of one fixture font, and the CPU
  renderer draws it. No channel of any pixel may be further than 2 of 255
  from the theme's reference image. In each picture the paper, the cursor
  and the text must carry the palette's colours, found by differencing
  pictures the scenario draws itself, so it names no size layout or the
  renderer owns. It reads only checked-in files. Each owner of a theme
  runs it: `ffi-test theme-pictures` on the built-in theme, `default`,
  against `tests/render/themes/default.png`; and the linked test of the
  package `shipped-themes`, which the package steps run, on
  `solarized-dark`, `solarized-light` and `fairy-floss`, against the
  images under `packages/shipped-themes/tests/render`, where the light
  picture must also not match the dark reference. The README beside each
  set of images says what they show and when to make them again.
- **The wgpu adapter's calls.** It runs on wgpu's no-op back end, which
  validates every call as a real one would and draws nothing: the shader
  compiles in both its forms, the pipeline's vertex layout is the
  shader's, and a frame with every kind of quad and every kind of atlas
  page is drawn inside an error scope with no error, under both
  blendings, with dual-source blending and without; a device that
  blends encoded draws on its own target in `Rgba8Unorm` and tells the
  shader so in its globals (`crates/editor-render-wgpu/src/gpu/tests.rs`).
- **What the composited sentence is measured by**, in `crates/editor-ffi`
  (`examples/coretext/measure.rs`, whose unit tests `cargo test` runs, on
  pictures made in code): the ink, the dark pixels, the worst channel and
  the direction of a miss. The example itself draws on Core Text and the
  GPU, and is run on demand (`mise run coretext-check`).

What it cannot check, and so does not claim: what a GPU draws. wgpu has
no software renderer of its own, so a machine with no GPU and no driver
has no adapter, and no test asks for one: `mise run lint` forbids the
call that does (the root `clippy.toml`). The validation
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
(`lean/ModelTest.lean` and its modules under `lean/ModelTest/`), which run
editor commands, the text interface's
contract and the cases of the undo tree, which is Lean over that interface,
against the model, and the config session's decisions (what a
reload elaborates, what it installs, how reloads are serialised) on
hand-written fakes, with no elaborator. They test the job system the same
way: the job interface's contract against its model and against the job
runner over a fake clock; that jobs in a wait hold no thread, that
cancelling a sleeping job ends it at once, that a job whose owner is removed
is cancelled, and that none of a job runs on the thread that spawned it,
each with the clock or a promise the test holds and no sleeping; and that
warming Lean's task pool makes all its threads. The workspace finder's
contract and the mode marker search's run there against their pure models
and against the real finder and search on the job model. Loading and saving a file
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
(`packages/files/Files.lean`) are checked on that driver, over the model of
files, with no file touched (`FilesTest.fileCommandChecks`): opening a file
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
the API. Completion at point is checked on the models in the same layers
(completion's phase 5): its interface and the shipped `words` against their
contract (`atPointContractChecks`, `wordsChecks`), a session in the state
(`atPointStateChecks`), asking through the dispatcher and the chain
(`atPointChecks`, `registryChecks`), and, on the loop's driver over the
models, under a scheme written in the test that reports a session, the
keys, the preview, the accept, the closing rules, one undo step, a trigger
and a pause moved by `Loop.Driver.pass` (`atPointLoopChecks`,
`atPointAskChecks`, `atPointByItselfChecks`), and, under the Vim scheme
in the package `evil`'s tests (`packages/evil/EvilTest/Evil/Repeat.lean`),
the repeat (`atPointRepeatChecks`). The editor state's
side of a save in flight, the snapshot the loop releases once a save has ended and
the saved mark a rollback takes back are checked with the state requests
and the loop's dispatch.

The model tests are split into test modules that mirror the module they
test, under `lean/ModelTest/Editor/` (the checks of `lean/Editor/State.lean`
are in `lean/ModelTest/Editor/State.lean`), with the helpers several of them
share in small support modules under `lean/ModelTest/Support/`, and, for
the ones a package's tests are also written on, under `lean/Editor/Test/`,
the core's test kit, which the core publishes as a test double
([packages.md](../design/packages.md), "What moving the compile mode added
to the core's API"). Each imports
only what it uses, and the root `lean/ModelTest.lean` keeps its imports, the
`checks` aggregator and `main`. Splitting keeps lean-fmt's exact-frontend
child, one per file with a 600 s bound by default
(`LEAN_FMT_CHILD_TIMEOUT_MS`), from meeting one huge file. As a single file
of 38,031 lines it took 221 to 318 s under `lake exe lean-fmt format
--check --no-cache` (the formatter was then a dependency of the core) on
the owner's machine (2026-11-17) and once ran past
the bound on the `macos-26` runner; mirrored, the largest module
(`lean/ModelTest/Editor/Loop.lean`, about 5,500 lines) took 9.4 s on the
same machine, and the whole tree 23 s. Put a new check in the test module
of the module it tests, creating that module if it is the first, and a
helper that a second test module comes to need in a support module; don't
raise the bound. Every list stays in the namespace `ModelTest`, so
`ModelTest.<name>Checks` names it wherever it lives.

`ffi-test`, `config-test` and `contract-test` are laid out the same way,
under `lean/FfiTest/`, `lean/ConfigTest/` and `lean/ContractTest/`: the
checks of `lean/Editor/Ffi/Document.lean` are in
`lean/FfiTest/Editor/Ffi/Document.lean`, and a run of a port's contract
against its real binding is in the mirror of that contract
(`lean/ContractTest/Editor/Display/Contract.lean`). The helpers several
test modules share are in `<Root>/Support/`, and contract-test's rig over
the real services in the linked test kit, `lean/Editor/Test/Linked/`; `Check` (and `failures`,
`run` and `usage`, and config-test's `Context`, where the root has them)
are in `<Root>/Check.lean`; the benchmark is in
`lean/ConfigTest/Bench.lean`, but for the workspace finder's, which is the
workspace's, in the workspace package's linked test
(`packages/workspace/WorkspaceTest/Linked/Workspace/Bench.lean`); and the checks of the default config
(`config/default`), which is no Lean module to mirror, are in
`lean/ConfigTest/DefaultConfig.lean`. Each root keeps its imports, its `checks`
aggregator (contract-test's is `main`) and `main`, and every list stays in
its root's namespace, so `FfiTest.<name>Checks`, `ConfigTest.<name>Checks`
and `ContractTest.<name>Checks` name it wherever it lives. Put a new check
in the test module of the module it tests.

The ex command line (`packages/ex/Ex.lean`) is checked there in layers,
so that a change to one breaks no other's checks:

- **A line and a binding, as data** (`exLineChecks`): what a typed line
  parses to, and the invocation a binding makes of an argument. Pure.
- **Ex bindings in the registry** (`registryChecks`, `setupChecks`,
  `reloadChecks`): by owner, bound from `setup` with its refusals, and
  replaced by an install, which keeps another owner's.
- **The requests a command makes for it**: which command an ex name is
  bound to, answered by the dispatcher from what it is told of the
  registry (`registryRequestChecks`, `dispatchStateChecks`); an invocation
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
  refused. The five names run on the `ex` package's ex bindings
  (`Ex.package.registered.ex`): `e` and a path, `w`, `q`
  with nothing modified, with a file's buffer modified and with the
  scratch buffer alone modified, `w` then `q` and `wq` while the save is
  in flight, `wq` with no file, with the file changed behind the editor
  and with another buffer unsaved, and `reload`. Each message is read
  from the function that makes it.

Evil, Vim's states and motions on the editor API (`packages/evil/Evil.lean`),
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
  which candidates a pattern matches, that a candidate that is the
  pattern is first, and where a pattern is located with errors allowed
  (within the errors, on character boundaries, the fewest errors in ASCII
  text against the contract's own oracle, and the pattern where it is
  expected answered there). `fuzzyChecks` are what only the model shows,
  its order after the exact matches and its order among located spans of
  the fewest errors, and the contract seen to report a matcher that
  ignores case, one that does not put an exact match first, and locators
  that answer nothing or a span with more errors than the fewest. **The model and the binding are not held to agree on the order
  past the exact matches**, so every check above the port computes what
  it expects with the model. The completion sources' contract
  (`lean/Editor/Completion/Contract.lean`), that a source reads and does
  not write, runs here on the sources' model, their fake and every
  shipped source (`sourceContractChecks`), and is seen to report a source
  that makes a text and one that is refused.
  The syntax tree interface's contract
  (`lean/Editor/SyntaxTree/Contract.lean`) runs on its model here
  (`syntaxTreeFailures`), and `contract-test` runs it on its real binding:
  the grammars, refusals, capture names, a table of exact cases that are
  the library's answers, the range rule, a grammar's shipped query, and a
  highlight answered or refused, and injections, languages and kept queries
  with their refusals. `highlightFaceChecks` and
  `highlightEnterChecks` pin the capture-to-face rule and what setting a
  major mode with a syntax tree asks of the port, through the loop's
  dispatch on the models, its injections and kept queries among it.
  `indentRuleChecks` and `indentLevelChecks` pin the indent rule and the
  indent primitive, and `treeObjectRuleChecks` and `evilObjectChecks` the
  syntax tree's text objects, by key, on a test mode of the model's JSON
  grammar. `syntaxTreeChecks` are what
  only the model shows: its JSON tree node by node, its `ERROR` answer
  outside the subset, what its query subset refuses as unsupported, and
  the contract seen to report a model that answers a range with the whole
  text.
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
  under the test scheme with the test kit's editing keys, in frames a few
  rows tall: a view follows its cursor after a move down, up, to the
  text's start and to the end of a wrapped line, after a resize, and after
  an edit through another window on the same buffer; a move that leaves
  the cursor shown leaves the anchor; the margin holds after every move of
  the kit's editing keys; and a failed command and a view whose selection
  marker was given up leave the anchor. `evilScrollChecks` press keys on
  the same driver under the Vim scheme that ships with evil's commands:
  the margin holds after every motion of the vocabulary; `C-d`, `C-u`,
  `C-f` and `C-b` move the anchor and the cursor by
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
restores the text, with its lemmas (`packages/evil/Evil/Theorems.lean`,
`lean/Editor/UndoTree/Theorems.lean`, `lean/Editor/Text/Model.lean`). The task
shows by behaviour
that they build without the library. It puts a `cargo` that always fails
(`lean/no-cargo/cargo`) first on the `PATH`, and Lake runs `cargo` on every
build that reaches the Rust archive, so the task passes only if the test
driver does not need it. The tests of the pool pin no size, so they pass
whatever `LEAN_NUM_THREADS` says: a bare `lake test` is enough.

`mise run ffi-test` runs `lean/.lake/build/bin/ffi-test`, the test executable
linked against the real library, then `contract-test`, handed three
directories: `tests/process-environment` (the fixtures that stand in for
mise in the checks of a child's environment), `tests/syntax` (the syntax
fixtures, whose Rust fixtures the indent and text-object checks read) and
`tests/completion` (the fixture that stands in for fzf in the checks of a
source a command filters, so they pass where fzf is not installed); each
fixture must stay executable. The same `filter` stands in for fzf in the
default-config headless fixture (`tests/headless/default-config`), whose
script opens the workspace finder on the default source: the run copies it
into its temporary directory as `fzf` and puts that first on the editor's
`PATH`, so the fixture reads the same where fzf is installed and where it
is not (it failed on both CI runners, which install none, until it did).
The workspace finder's and the mode marker
search's contracts over the real services, git's lister and the fallback,
`:!` over the real process service, project search, the working sets and
version control over real git were `contract-test`'s until the seven
features of the files cluster moved out of the core (features-as-packages
phase 6), and are their packages' linked tests' now, on their own
fixtures: `packages/workspace/tests/workspaces` (git's stand-in) and
`packages/workspace/tests/completion` (a byte-for-byte copy of fzf's);
the shell's run on a rig over fakes, with no fixture. The
checks of a compile over the real process service, which `contract-test`
ran on `tests/compile` until the compile mode moved out of the core, are
its package's linked test's now, on `packages/compile/tests/compile` (the
fixture `three-lines`, which waits for files the check makes, so its
pauses are the check's to end; and the programs that stand for cargo,
lake, mise and git, put first on each child's `PATH`, with the trees the
shipped modes are checked in, which the checks copy into a temporary
directory, so no real tool runs): "The package steps", below. Then `config-test`, handed
`tests/syntax` too, whose Rust indent fixture its indent checks mangle and
re-indent through a headless host, and
then the editor, once as `editor demo`, the demonstration; then **the
headless fixtures under `tests/headless`, stepped**: the default set's
fixture harness (`packages/.lake/build/bin/fixture-test … run
../tests/headless`; [headless-mode.md](headless-mode.md), "How the gate
runs a fixture") discovers each fixture and runs it on the stepped host
with the fakes against its expected file, or its setup's after-checks,
but those the real-thread set (`Editor.Test.Fixture.RealThread`) leaves
to the CLI, whose lines follow here. Its output must hold a `stepped, as
expected` line for each of the 29 it runs and the line `fixture-test: ran
29 fixtures stepped under tests/headless, 19 left to the CLI`; it fails on
a fixture that differs, naming the first line with both texts, on a stale
entry and on a root that holds none. The fixtures whose subject is the
script runner over a real loop thread, the set's four runner entries
(`script`, `keys-script`, `scene-script`, `ex/script`), are then run both
ways and compared by `case_compare` in `tools/wiring-runs.sh`: it reads
the entries from `fixture-test … compared`, runs each through the CLI,
which must exit 0, and hands its output to `fixture-test … compare
<script> <file>`, which runs it stepped and exits 1, saying the lines
each side alone has, when the two outputs differ or are not the expected
file. Each step is decided by its exit status; nothing reads their lines.
The CLI runs are shell because Lean spawns no child process
(`docs/design/overview.md`, "Rules of the boundary"). What the fixtures show, by fixture: with `script`, whose job `count` sleeps
on the headless mode's fake clock, which the script advances (`advance 1`)
before its `join`, and whose output must be exactly `expected`; with `keys-script`, which sends keys with their
identity through the library's window input and whose output must be exactly
`keys-expected`; with `scene-script`, which enters insert state, commits
text through the window input, prints the scene the editor loop published,
and reloads and runs a job once the frame exists, advancing the clock past
its sleep, and whose output must be exactly `scene-expected`; and with `dispatch/script` on the config in
`dispatch/config`, which sends the keys of a command that loops and the
interrupt key, then the keys of a command that ends, then the keys of a
command that starts a job with an argument, whose sleep the script
advances past and whose result the job's command says in the echo area,
and whose output must be exactly `dispatch/expected`; and with `finder-session/script` on the
config in `finder-session/config`, which runs that config's command by its
key `C-c h` and by its ex name `finder-hello`, so the fixture is known to
load and to say `finder-session: config loaded`, and whose output must be exactly
`finder-session/expected`; and with `files/script` on the config in
`files/config`, which runs the file commands the editor ships and touches
no file: `save-buffer` on the scratch buffer says it has no file, and a
command of config's opens a path that is not absolute, which starts the
compiled load job and is refused by the library before it asks the file
system, and whose output must be exactly `files/expected`; and with `evil-script`, which has no `reload` and so
loads no config: it sends `i`, the keys of `hello`, `<Escape>` and `0`,
and its scenes must show the text, the cursor after each, and the state's
name in the status line, exactly as `evil-expected` has them. That run is
evil's wiring on the real library: every command its keys run is one the
editor ships. A whole evil session on a real file is a process check of
its own, below (`session/script`). The eighth is `ex/script`, which also
has no `reload`: it
runs the ex line four times, with a name nobody bound, with `w` in the
scratch buffer, with `e`, where the scene lists the ex names the text
matches, `e` and then `reload`, and `<Tab>`, which puts `e` in the input,
and `<Enter>` run `e`, which asks for a path with the file prompt, whose
listing of the working directory is waited for with `join` and not
printed before `<Escape>` cancels it, and with `q`, which ends
the loop, so that the `scene` line
after it prints nothing; its output must be exactly `ex/expected`. The
fixtures `at-point`, `prompt` and `candidates` were the core's and run here
until the features-as-packages roadmap's phase 4 moved them, byte for
byte, into the default packages `at-point` and `minibuffer`, whose
fixtures the package steps run ("The package steps", below):
`at-point`, on the shared config copied into it, types `a` and `l` in
insert state, advances the headless mode's clock 240 ms so the shipped
`words` source's pause fires, and prints the session's candidate list,
then previews and accepts its first candidate; `prompt` asks for a
prompt, types into the minibuffer, accepts with `<Enter>` and cancels
with `<Escape>`; and `candidates` asks with the candidates `wq`, `edit`
and `w`, lists `w` before `wq` for `w` typed, which only the rule that a
candidate that is the text is first orders, chooses with `C-n` and
inserts with `<Tab>`.

`open-file/script` is a process check on real files, of the restore
checks' form (below), left to the CLI by its entry in the real-thread set:
its last file, `notes/todo.md`, opens in a mode attached to a grammar of
the library's syntax service, which the syntax tree's model does not hold
(it knows `json` alone). Its entry copies `open-file/tree` into a temporary
directory, writes the script there with `@DIR@` replaced, and the output,
with that directory written `@DIR@`, must be exactly
`open-file/expected`. The file prompt lists the tree's directory,
directories first and `.hidden` left out, lists `.hidden` once a `.` is
typed with no new job, goes into `notes/` with `<Tab>`, opens `todo.md`
with `C-n` and `<Enter>`, and says why a missing directory lists nothing.
Every job is joined, so its lines are fixed. Its temporary directory is
made from the template `/tmp/open-file.XXXXXXXX`, not under `$TMPDIR`,
so its path has the same length on every machine: the prompt's cursor
offset is counted over that path, and the scrub cannot rewrite it.

Two more fixtures run on a file, and read what an output cannot show: the
file's bytes. They were the executable's first two acceptance criteria,
and they run stepped now, with their setup (`Editor.Test.Fixture.Setup`).

- **Each is a template.** `@FILE@` stands for the file's absolute path,
  since the file port refuses a path that is not absolute: the setup
  copies `tests/headless/ex/note.txt` into the file fake's model at
  `/fixture/note.txt`, which `@FILE@` stands for in `ex/save-quit-script`
  and `ex/wq-script`.
- **What must hold**: the model's copy holds the bytes of
  `ex/note-expected`; and no line of the output starts with `commands:`,
  which the `show` line after the quit would print. They have no expected
  file: their setup's after-checks are what holds them.
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
- **They were shell in this task and not Lean** because Lean spawns no
  child process: child processes belong to the Rust process service, since
  Lean never kills or reaps one (`docs/design/overview.md`, "Rules of the
  boundary"). Stepped, they spawn nothing: the file is the file fake's.
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
snapshots, and releasing one frees it at once. It compares the binding's
bracket walk with the text model's at every position of texts with quotes,
for every kind, side, direction and escapedness, with quoted brackets
passed over and not (`pairChecks`), since the quote rule is ported to both. It
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
(`ConfigTest.promptChecks`), stepped on the check's own thread over an
in-memory editor queue, with the real text binding
and the real elaborator, with the test scheme and the minibuffer's
commands and mode as compiled code registers them: the scene of an open
prompt, with a committed text in the minibuffer; the accept key and the
cancel key; a job's result delivered while a prompt is open, on the fake
clock; a continuation that config registers, looked up when the answer
arrives, across a reload that replaces it and one that drops it; the
answer's command run before a key sent right after the accept key; and a
continuation over a store reading the cell after the accepting command's
write.

`config-test` runs completion at point through headless hosts of the test
scheme, on keys of the checks' own for the kit's at-point commands
(`ConfigTest.atPointChecks`, `withAtPointHost`), over the real
elaborator, queue, text binding and recorder and the stage's fake clock:
the key of `at-point-next` lists what a config's source answers, a config's trigger
source opens a session on its character and no other, a pause of 240 ms
after two characters opens one of `words`, a typed key arms one pause wait
and starts no job, and the pause's event is queued before the clock's
move returns, so a `join` after an `advance` finds the session.

`config-test` runs the ex command line through headless hosts too, with
the test scheme and the ex line's commands and the ex names that ship as
compiled code registers them. `ExTest.Linked.exChecks`, over the real
elaborator: a config binds a key to a command, its file is rewritten to
bind the key to another, the ex line `reload` is run, and the key runs the
other command, with no restart; an ex name config binds runs config's
command with the rest of the line, and is not an ex command after a
reload of a config without the binding; config's binding of a shipped
name runs in its place until a reload drops it; and a name nobody bound
is said in the scene's echo, with the editor going on.
`ExTest.Linked.exScriptChecks`, with `Headless.run` on scripts built in the
check, over the library's file service on a file each check writes in a
temporary directory of its own: `e`, a commit, `w`, a join and `q` leave
the file with the buffer's text and end the script with no failure, with
the `show` line after the quit not run; so does `wq` with a join after
it; a `q` that is refused leaves the script running; and a wait on a host
whose loop a command ended answers `ended`. No test of `config-test`
spawns a process.

The package `evil`'s linked test also loads a config that names evil's vocabulary
(`EvilTest.Linked.evilChecks`, which was `config-test`'s until evil became
a package): a command of config's hands the move command
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

`ffi-test` also runs **an evil session on a file**, stepped
(`tests/headless/session/`): its setup copies `verse.txt` into the file
fake's model at `/fixture/verse.txt`, which the template `script`'s
`@FILE@` stands for. The script has no `reload`. It
opens the file with `:e`, and then, by keys, runs a count and an operator
(`2dw`), a dot repeat, an undo, a change with typed text and its dot
repeat, a visual yank, a put, an undo and a redo, and `:w`, with a `scene`
after each step. Its output, with `/fixture` written `@DIR@`, must be
exactly `expected`, which shows the text, the cursor, the selection, the
state and the echo of every scene; and the model's copy must hold the
bytes of `verse-expected`.

`ffi-test` runs **session restore** as processes (`tests/headless/restore/`),
six entries of the session check's form, each with `--state` naming a
directory of its temporary directory. Each run's output is compared with
the temporary directory's path written `@DIR@`, a stamp's time written
`@TIME@`, and its `job` lines and its `commands:` line dropped: what a job
came to is printed when its wake-up arrives, which the driver's other
requests do not wait for, and the command list grows with every package.

- **An abort**: `abort-script` opens `note.txt` with `:e`, types `xy` in
  insert state, waits until the journal is written (`journalled`) and
  aborts (`abort`): the editor must exit with the status 134, with no
  shutdown. A second run with the same state directory, `restore-script`,
  must print exactly `restore-expected`: the file's buffer with the text
  typed, modified.
- **Changed on disk**: the same abort, then `note.txt` rewritten; the
  second run, `changed-script`, must print exactly `changed-expected`: the
  buffer marked `[changed on disk]`, and `:w` refused as changed; and the
  file must still hold what was written over it.
- **A clean quit**: `quit-script` edits, saves with `:w` and quits with
  `:q`; its output must be exactly `quit-expected`, the journals' directory
  must then be empty and `session-1.json` must say `"ended":true`; a run of
  `restore-script` after it must print exactly `quit-restore-expected`,
  which restores nothing.
- **Another version**: the state directory is a copy of `newer/`: an index
  of format 99 with keys this editor does not know, and a journal whose log
  has a record of a kind it does not know. `newer-script` must print
  exactly `newer-expected`, with what is known restored and the report's
  lines in `*restore*`'s text; afterwards `cmp` must find the index and the
  journal's two files byte for byte as they were.
- **Windows, layouts, tabs and the jump list**: against `layout-config`,
  which chooses manual splits inside a left edge and binds `tab-rename`,
  `layout-script` makes two tabs: in the first, tiles under manual splits,
  one resized, a docked window and a float; the second named `notes`,
  split and zoomed. It records jumps with `G` and `gg`, types, waits until
  the index and the journal are written (`indexed`, `journalled`) and
  aborts with the status 134, printing exactly `layout-expected`. The
  second run, `layout-restore-script`, must print exactly
  `layout-restore-expected`: every window back where it was before config
  installs (the layout held) and after (config chose the same one), `C-w n`
  showing the hidden tab named and zoomed, `C-o` the recorded jump, and `u`
  saying `nothing to undo: no history before the restore`; and the index
  it writes must be of format 2.
- **Stores, workspaces and jobs**: the file is copied beside a `.project`
  marker, so its directory is a workspace without git. Against
  `stores-config`, which declares `kept`, kept across a restart, and
  `unkept`, which is not, and a reported job `hold` that sleeps a minute,
  `stores-script` bumps both stores, runs `:!true`, starts `hold`, types
  and aborts with the status 134 while `hold` runs, printing exactly
  `stores-expected`. `stores-restore-script` must print exactly
  `stores-restore-expected`: before config installs no config cell, the
  workspace table (`workspaces`) with the project's `shell-history`; after
  it `kept` back at 2 and `unkept` at 0; and the summary and `*restore*`
  saying the restart stopped `hold`.
- **acp's agent table** (`packages/acp/tests/headless/table/` and
  `table-restore/`, `case_acp_table_restore`), on the fixture set's
  editor, which holds `acp`, with a scripted `claude-code` from the
  fixture's config: `table/script` starts a session its agent ends and
  aborts once indexed, status 134; `table-restore/script` reads the
  project's `agents-table` back (`workspaces`), lists the record and
  visits it, which resumes the session with `session/load` through the
  real crate, its history shown. Each output is held to its expected file
  by `fixture-test … expect`, by its exit status.

`ffi-test` runs **the restart** as processes (`tests/headless/restart/`;
`lean/Editor/Restore/Restart.lean`), after the `launcher` task has built the
launcher and its test helper, release (`target/release/leanmacs`). Each
entry copies `note.txt` into a temporary directory, gives `--state` there,
writes the script there from its template, and prints the output with the
temporary directory written `@DIR@`, the editor's path `@EDITOR@`, and its
job lines and command list dropped:

- **Through the launcher**: `leanmacs --default <editor> -- headless …` on
  `script`, which opens the file, types, splits the window and makes a
  second tab, then `:restart`s and waits at `restarted`. The second
  process, started by the launcher with the session handed over and
  `--resume 1`, runs the script from there. Both print exactly
  `restart-expected`: the summary that the window was closed and reopened,
  the buffer with its unsaved text, the split and the hidden tab. Then no
  hand-over record is left, `session-1.json` is gone, `session-2.json` is
  there, and the journals are only run 2's.
- **With no launcher**: the same script, the editor run directly
  (`restart-direct-expected`, which says there is no fallback); the same
  files are left.
- **The probe refuses**: `probe-script` restarts into a program that exits
  3 whatever it is given; the echo says it did not start, the script goes
  on in the same process with the session as it was (`probe-expected`),
  and no record is written.
- **The fallback**: `fallback-script` restarts, through the launcher, into
  a program that prints `probe: ok` for `--probe` and otherwise exits 3.
  The launcher's watcher marks it failed and starts the previous
  executable, the editor, which restores the session and names it
  (`fallback-expected`); its standard error says `leanmacs: @DIR@/bad ended
  before it restored the session; starting @EDITOR@`, and no record is
  left. The first process's status is the failed program's.
- **The fallback after a kill**: the same, with the program sending itself
  `SIGKILL` (`killed-expected`).

The launcher's own tests run under `mise run test`: the core's on its fakes
(`crates/editor-launch`), and on real processes the ports' contract, the
fallback with a candidate that exits and one that kills itself, and, on
macOS, CoreFoundation's main bundle in a fake bundle the launcher starts an
editor from, inside it and outside it (`crates/editor-launch-std/tests/`).

`ffi-test` runs **a view that follows its cursor**, stepped, the same way
(`tests/headless/view/`). Its setup copies `lines.txt`, 120 lines `000` to
`119`, each ended by a line feed, so that line n starts at byte 4n, into
the file fake's model at `/fixture/lines.txt`, which the template
`script`'s `@FILE@` stands for. The script has no `reload`. It sizes the frame with
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

Its output, with `/fixture` written `@DIR@`, must be exactly `expected`,
and the model's copy must still hold the bytes of `lines.txt`. The display
is the recorder: the display model's rule over the library's snapshots. The numbers in
`expected` were worked out by hand before the editor was run, and the run
agreed with each.

`ffi-test` runs **`j` and `k` aiming for a display column**, stepped, the
same way (`tests/headless/column/`): its setup copies `lines.txt` into the
file fake's model at `/fixture/lines.txt`, which the template `script`'s
`@FILE@` stands for. The file is three lines, each ended by a line feed: `a`, a tab
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

Its output, with `/fixture` written `@DIR@`, must be exactly `expected`,
and the model's copy must still hold the bytes of `lines.txt`. The display
is the recorder.

`ffi-test` runs **milestone 1 over the whole program**, as a process, the
same way (`tests/headless/milestone/`), with `editor headless --render`:
the display is the real binding over the library's layout in cells of 8 by
16, bound to the headless render session, which draws every frame on the
CPU renderer. The script opens a copy of `source.txt`, 60 lines of Lean,
with `:e`, runs `2dw`, `.`, `u`, `j`, `cw` with a committed `edited`,
`<Escape>`, `$ p`, `u` and `C-r`, scrolls with `C-f`, saves with `:w`, and
ends with `idle`. The editor must exit 0, its output must be exactly
`expected` (each `agree` line reads `agrees`: the rows the loop asked for
are the frame's, and `idle: 0 frames drawn, 0 frames submitted`), and
the copy must hold the bytes of `source-expected`. That `agree` can say
anything but `agrees` is pinned in `config-test`
(`ConfigTest.agreementChecks`): on a scene and answers made there it says
`agrees`, `disagrees` with both sets of rows, that there is no rows query,
and that the frame has no such view. The `idle` waits on
events alone: everything sent handled, then the render loop's rest, on the
step that records it, so a slow machine cannot fail it, and its count of
frames is fixed by events: a loop that kept asking for frames while nobody
types would never rest. The render loop's own
rules (an equal frame is no demand; a loop at rest draws nothing) are
`editor-render`'s, pinned on a fake clock.

`ffi-test window-host <file>` runs **the window mode's wiring**
(`lean/Editor/Window/Real.lean`), as a process of its own, on the
library's scripted platform: a cells display bound to the presenter, a
clipboard of its own, the host opening a copy of `ex/note.txt`, and the
scripted sample window opening, sending its input and asking to close.
It must exit 0, which it does only when the window ran and closed, the
render session's counters show a frame drawn, the window was opened with
the themed title bar and asked for the dark appearance of the built-in
paper and nothing else, and the copy must be unchanged. `ffi-test
window-host` with no file runs the same wiring as Finder starts the app:
the host posts no open, the window runs on the editor's one empty buffer,
and it must exit 0 the same way. `ffi-test window-host-config <sysroot>
<olean dir> <config dir>` runs the same wiring with no file and config
loaded at start from the fixture `tests/window/title-bar/config`, whose
`setup` keeps the standard title bar: the host waits for the start-up
reload with no bound, so the result does not race the clock, and the
scenario must exit 0, which it does only when the scripted window was
opened with the standard title bar.
`ffi-test window-host-base <sysroot> <olean dir> <config dir>` runs it
again with a config base that is not `Editor` alone, as the editor's
`main` hands the window mode its package set's: `Editor` and
`ConfigFixture`, a module linked into `ffi-test` that `Editor` does not
import, on the fixture `tests/window/base/config`, which names a
declaration of that module and keeps the standard title bar. It exits 0
only when the window was opened with that title bar, so only when the
window mode elaborated config on the base it was handed: on `Editor`
alone the reload is rejected with `Unknown identifier`. The base is an
argument of `Window.host` and `Headless.shipped` with no default, so a
caller that leaves it out does not build.
`ffi-test window-host-generate <sysroot> <olean dir> <config dir>` runs it
handed a generator, as the editor's `main` hands the window mode one, on a
temporary copy of `tests/window/title-bar/config`, which holds a root and
neither generated file. It exits 0 only when the start-up reload created
the directory's `lean-toolchain` and `lakefile.toml` and loaded the
config, so only when the window mode handed the session the generator it
was handed ("The config directory", below).
`ffi-test window-host-direct <editor> <sysroot> <config dir>` runs that
again as the editor at `<editor>` starts when run directly with
`--sysroot` and `--config` and no `--oleans`: the command line is read for
that executable, so the `.olean` directory is its default, the one the
package-set build recorded beside it (`<editor>.oleans`;
`lean/Editor/ModuleLookup.lean`, "The record"), read at the same edge the
editor reads it at. It must exit 0, which it does only when that config
loaded, so the default directory holds the modules config is elaborated
on. The gate runs it for the default set's editor and for the fixture
set's, and then requires the fixture set's record to name eight
directories in order, the core's, `greeting-api`'s, `greeting`'s,
`greeting-loud`'s, `echo`'s, `shipped-themes`', `compile`'s and
`word-count`'s, each holding its package's modules.
The editor searches every recorded directory, after any its command line
gives, which is a search path, directories joined with `:`
(`lean/Editor/ModuleLookup.lean`).
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
installed editor will find its modules, from a bundle staged as the app
is, with the whole toolchain ("The bundle test", below).

What the gate checks of drawing, then: frames a bound display publishes
reach a render loop with the input they answer (`editor-ffi`'s tests,
`FfiTest.renderChecks`), the scripted window's session draws them, and the
whole program drawn by the CPU renderer agrees with its queries and rests.
What it does not: a real window, the system's fonts, a GPU, the desktop's
clipboard, and anything a person sees. Those are on demand
([on-demand-checks.md](on-demand-checks.md): `linux-window`, "The editor
on a file, on demand", "Milestone 1, measured"). The
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
(`lean/Editor/Fuzzy/Real.lean`), so against the library's matcher and
searcher, and checks that a command run against the library that asks for
a ranking, or where a pattern is located, is answered by it. `ffi-test`'s own `fuzzyChecks` pin that a pattern, a list
of strings and the ranking cross the boundary, and that a pattern, a text
and the span it is located at cross. It runs the syntax tree
interface's contract against its real binding
(`lean/Editor/SyntaxTree/Real.lean`), over the library's syntax service,
waiting with a bound for each snapshot's tree before a question of its
captures and after an attach, and checks what only the library shows: its
Rust grammar, a Rust function's name captured, a query of one grammar asked
of a text parsed with another or highlighted with it, a text edited through
its document reparsed, a Rust text highlighted and edited drawn by the real
display with its keywords in the keyword face's colour once the edit's
delivery is reported on the editor queue, a Markdown text with a fenced
Rust block drawn with the fence's `fn` in the keyword face's colour, and a
job's command run by `Job.finishWith` reaching the syntax tree it is
handed. Over the fixtures of `tests/syntax`, its third argument, it checks
that the indent levels of `rust/indent.rs` are its own indentation and the
tree's text objects of `rust/objects.rs` cover the ranges written by hand,
each before and after an edit, that the shipped Rust indents and text
objects queries name only what their rules read, and that the opening
level of Rust texts at unclosed brackets counts every bracket the tree did
not close. `config-test` mangles `rust/indent.rs` (77 rustfmt-formatted
rows; its two rows inside a multi-line string and a block comment are
found by their content, not their number) and re-indents it with `gg=G`
through a headless host.
`ffi-test`'s own `syntaxChecks` pin that a list of strings out, a query
handle with its refusals, captures with each of their refusals, a shipped
query, a highlight, an injection, a language and a kept query with each
refusal cross the boundary, and that a
file's loaded text is of no document; its event checks decode a parse
delivered.

`config-test` (`lean/ConfigTest.lean`) is linked like the editor, with
Lean's elaborator, and is given the toolchain's directory and the package's
`.olean` directory as arguments. It holds the real elaborator to the
elaborator port's contract, the same properties `model-test` holds of the
port's pure model (`lean/Editor/Config/Elaborator/Contract.lean`), checks
what only Lean's elaborator can show of a config file as a module, the
directory source, and the adapter that reads a lakefile's requires, and
runs the headless host in-process, on the real text binding: most checks on a
host stepped on the check's own thread over an in-memory editor queue, and
the checks of the wiring set's modules, each with the adapter it covers, on
a real loop thread or a real service ([real-thread-checks.md](real-thread-checks.md)):
`lake build`'s `linter.realHost` confines them to those modules. A reload replaces a command; a type error, a throwing `setup` and
a file that declares `initialize` each keep the old config; after a change
to one config file a reload elaborates that file and the files that import
it, and no other; a root that imports a module that is not linked is
rejected, naming the module, and the old config stays; a reload whose root
first imports `Lean` installs; a reload does not
register a command twice; a store's value survives a reload and is migrated
when its type changes; a command the library refuses is reported as refused
and leaves its store as it was; the editor answers events while a file
elaborates; reloads are serialised; a script that cannot run to its end
says why; a job's command that sets a mode with a syntax tree reaches the
host's syntax tree; a parse of a highlighted text the library delivers
makes the host publish a scene, with no key pressed. That `v a f` selects
the enclosing function and `d a f` deletes it in a Rust buffer of a host of
the Vim scheme is the package `evil`'s linked test's since the
features-as-packages roadmap's phase 7 (`EvilTest.Linked.treeObjectChecks`,
`packages/evil/EvilTest/Linked.lean`): no check of `config-test` runs a
host of the Vim scheme. Its config directories are temporary directories of its own, and so is the directory the module data of the config files it elaborates is written to.
Its fourth argument is the default config `mise run install` ships
(`config/default`), which it reads and never writes: `defaultConfigChecks`
pin that a reload of it installs with no diagnostic and `SPC f f` then
asks for a path to open, that every binding names a registered command,
and that every prefix it binds under the leader has a prefix name.

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
to the input the keyboard check counts; and a picture crosses through a PNG
file and back, and its helpers read it (`pictureChecks`). These scenarios
need a process each:

| Command | Shows |
|---|---|
| `ffi-test exit 7` | The entry point passes arguments to Lean's `main` and its result is the exit status. |
| `ffi-test shutdown` | Quitting the queues wakes every task blocked in a pull, and the process then exits. |
| `ffi-test exit-while-blocked` | An explicit exit ends the process although a task is still blocked in the library. |
| `ffi-test theme-pictures <dir> <font>` | The built-in theme's picture of the fixture file matches its reference image in `<dir>`, and carries the palette's colours where the paper, the cursor and the text are ("The themes' pictures", above). The shipped themes' pictures are their package's linked test's ("The package steps", below). |

The conventions every binding follows, and the test that pins each, are in
the crate docs of `crates/editor-ffi/src/lib.rs` and the module docs of
`lean/Editor/Ffi.lean`.

## The config directory

Four things about a config directory are checked on built editors, in
`ffi-test`, each on fixtures under `tests/`. The headless mode is run on a
checked-in config directory with no `--generate`, so it writes nothing
there; everything that is generated or converted is in a temporary
directory the script makes and removes.

- **Config as modules** (`tests/headless/modules`, `not-linked`,
  `needs-rebuild`): three fixtures the default set's editor runs, each
  diffed against its `expected`.
  - `modules`: a root that imports `Lean`, the compile package's `Compile`
    and two config files. The command a program of `Config/Keys.lean`
    registers runs, since the root's `setup` calls it; the command the
    `setup` of `Config/Unused.lean` registers is no command.
  - `not-linked`: a root that imports `Lake` is rejected with one
    diagnostic, at the import, that names the module.
  - `needs-rebuild`: a root that imports `Greeting`, in a directory whose
    `lakefile.toml` requires the fixture package `greeting`. The default
    set's editor rejects it and says the package set needs a rebuild
    (`expected`); the fixture set's editor, which links the package, loads
    it (`installed-expected`). A third line fails if the fixture's config
    directory holds anything but its two tracked files.
- **The old form** (`tools/config-migrate-check.sh`, on
  `tests/config-migrate`). `chunks/` is a config directory kept in the old
  form on purpose: two files with no header, and no `init.lean`.
  1. On it the editor must print `refused-expected`: `reload 1: rejected`
     and one diagnostic that names the two files and
     `mise run config-migrate`.
  2. A temporary copy, converted by `tools/config-migrate.sh`, must hold
     `init.lean` and `Config/Leader.lean` and no other file, and on it the
     editor must print `migrated-expected`: the config loads and its command
     runs.
  3. More shapes of the old form, each written in the temporary directory,
     converted, and loaded by the editor, which must install it and run a
     command of it: three files, the second named `20-evil-keys.lean` and
     the last using a declaration of the first; one file; a `setup` defined
     in the second of three files, whose root must hold that file and the
     one after it, each seeing what the old form let it see and no more; a
     `setup` defined in the first of two; a `private` declaration that
     a later file uses; and a `setup` that no line is seen to declare,
     where every file must become `init.lean`.
  4. The script must refuse, with status 1 and the directory left as it
     was: a directory that already holds an `init.lean`; two files that
     give one module name; a file whose name has no letter after its
     digits; a `Config/<Name>.lean` that is already there; a file that
     would go in `init.lean` before another and leaves a namespace open, or
     closes one it did not open, which the refusal must name; a file that
     already starts with an import header, which the refusal must name; and
     a root spelt `Init.lean`, the refusal naming it and `init.lean`. It
     must convert nothing in a directory with no `.lean` file.
- **The generated files** (`tools/config-package-check.sh`, on
  `tests/headless/generate`, whose config directory holds `init.lean`
  alone).
  1. The default set's `editor headless --generate`, on a temporary copy,
     must print the fixture's `expected`, and leave a `lean-toolchain` that
     is `lean/lean-toolchain` byte for byte and a `lakefile.toml` that
     requires the set by its Lake name and its directory, then, last,
     `editor-core` by the checkout's `lean/`, the core the editor links.
  2. A second run must leave both files as they were.
  3. A run without `--generate` on another copy must leave neither.

  It must print `config-package: generated lakefile.toml and
  lean-toolchain, the config loaded, and a second run wrote nothing`.
  `bundle-test` has the staged bundle do the same, where the lakefile
  names the bundle's own set ("The bundle test", below), and `ffi-test
  window-host-generate` hands the window host a generator on a temporary
  copy of `tests/window/title-bar/config`, which must then hold both files.
- **The language server** (the same script, then `config-test lsp`,
  `lean/ConfigTest/Lsp.lean`). The root and the config file of
  `tests/config-package/lsp` are put in the directory the first step
  generated: a root that imports `Lean`, `Compile` and `Config.Keys` and
  holds one type error, on line 8 at column 19. `config-test lsp` starts
  `<sysroot>/bin/lake serve` there, opens the root over the language server
  protocol and waits until it is elaborated. The server must report that
  one error and no other, so no import failed, and the check must print
  `config-test lsp: init.lean: no import error, and the type error is at
  8:19`. It takes about three seconds and needs no network: the generated
  lakefile requires the set by path, and Lake writes `lake-manifest.json`
  and `.lake/` in the temporary directory and nothing under `lean/` or
  `packages/`. It gives up after three minutes.

`mise run config-migrate` itself is run by hand, on a real config directory
([`on-demand-checks.md`](on-demand-checks.md)); the gate runs its script on
the copy alone.

## Structure rules are reviewer rules

What a module may import, where the core's modules sit, which layer may
import which, that every implementation package can be left out of a set,
that the module map of `docs/design/packages.md` agrees with the tree, and
that every library and executable loads the build's linters are rules of
the code's structure. They are written in `.agents/rules/structure.md`,
and review holds a change to them: no gate step checks them. Shell scripts
that read Lake's module graph and the tree checked them until
gates-by-exit-status phase 1, which removed them, since no structural tool
stood behind them (`.agents/rules/gates.md`). The Lean linters (the wait
and real-host linters, "The wait lints", below) and Lake's own resolution
of `require`s stay automated. rdm task `lean-structure-rules-tool` is
where automated checking of the structure rules comes back.

## The package steps

```sh
cd lean && sh ../tools/package-set.sh <step> ../tests/packages
```

A package outside the core gets the same gate as the core: its tests, its
lint, its format check and its headless fixtures, each in the task that
runs the core's. `tools/package-set.sh` asks Lake for the packages of a
package set (`lake -d <set dir> query :editorPackages`, a facet the core's
lakefile defines) and runs one step over each, each package after the ones
it requires. What a set is, how the editor is built from one and what a
package's tests are by convention are in
[packages.md](../design/packages.md), "The package set and its build".

| Step | What it runs for each package | In task |
|---|---|---|
| `test` | `lake -d <package> test --wfail`: the package's Lake test driver, the tests that need no Rust library | `lean-test`, with the `cargo` that fails first on the `PATH`, so a package's driver reaches no `rustlib` either |
| `build` | Once, `lake -d <set dir> build --wfail :editor :editorFixtures`, the set's editor and its fixture harness. Then `lake -d <package> build --wfail`, its default targets under its own linter options, and `+<P>Test.Linked:editorLinked` when the package has that module | `lean` |
| `fmt` | `lean-fmt format --check --root <package>`, then `lean-fmt check --root <package>`, from the formatter's host | `lean-fmt` |
| `format` | `lean-fmt format` and `lean-fmt check --fix`, which rewrite | `lean-format` |
| `run <sysroot> <core olean dir>` | The package's linked test, in its directory, with those two arguments. Then its fixtures, each `<package>/tests/headless/<name>/`, on the set's fixture harness, once for the package: `fixture-test <sysroot> <core olean dir> --repo <repository> run <package>/tests/headless` runs each stepped, on the fakes, and each must print exactly `<name>/expected`, but those the real-thread set leaves to the CLI ([headless-mode.md](headless-mode.md), "How the gate runs a fixture"); its count line must cover every fixture the step found. With `--no-linked`, the fixtures alone; with `--wiring`, each linked test's wiring groups alone and no fixture (the stress loop's `linked-wiring`) | `ffi-test` |

- **The gate gives every step the fixture set**, `tests/packages/`, which
  requires the fixture package `greeting-loud`, through it `greeting`, the
  fixture interface package `greeting-api`, the fixture package `echo`,
  which holds Rust, the default set, and the example package of the guide
  to writing a package, `word-count` (`docs/packages/word-count/`). So the
  default packages, all twenty-five, with the eighteen interface
  packages ([packages.md](../design/packages.md), "The module map"), and
  the code the guide quotes are tested, built, format-checked and run through it. `run`
  is also given the default set itself, `packages/`, with `--no-linked`,
  so those packages' fixtures hold of the default set's editor, the one
  that is shipped.
- **The packages a step runs over** are those of the set that are path
  dependencies and hold a Lean library, other than the core. The script
  reads no lakefile.
- **A step cannot pass over nothing.** With no package to run over it
  exits 2, as it does for a query Lake fails and for a command line it
  does not take. `lean-test` shows it: `package-set.sh test
  ../tests/empty-set` must exit 2 and say why. `tests/empty-set` is a set
  kept for tests: it requires the core alone and never gains a package, as
  the default set has.
- **The default packages' tests are required to have run.** `lean-test`
  keeps the `test` step's output and requires the line the step prints as
  it reaches each of them, `package-set: test <name> (<its directory>)`
  for each default package and each interface package of the default set
  (the names are listed in the task), and the same line for
  `word-count`, matched on what
  comes before the directory. The step stops at the first driver
  that fails, so those lines and exit 0 say each package's driver ran and
  passed: the themes hold under the core's completeness check, and the
  compile mode's 98 model checks hold on the core's test kit.
- **A package with no test driver fails `test`**, since Lake refuses to
  test it.
- **Each linked test runs once, by how the sets are invoked.** The
  fixture set requires the default set, so Lake names every default
  package for it too, and `ffi-test`'s `package-set.sh run
  ../tests/packages` runs every linked test, fourteen today: the default
  packages' twelve, `greeting`'s and `echo`'s. Its run over the default
  set is `package-set.sh --no-linked run ../packages`, which runs that
  set's fifteen fixtures on the shipped set's own harness and no linked
  test, so none runs twice. Each passes or fails by its exit status. `run`
  prints a line for each linked test and each headless fixture
  (`package-set: linked test <module> of <package>`, `package-set:
  headless fixture <name> of <package>`) and a last line with the counts,
  for people reading the log; nothing requires them. A package Lake does
  not name, or a linked test `editorPackages` misses, would go unrun: a
  gap reviewers hold (gates-by-exit-status phase 4 removed the lists of
  required lines, `.agents/rules/gates.md`).
- **`--no-linked` is shown on stand-ins.** `lean-test` runs
  `package-set.sh` in a temporary directory with a stand-in `lake` first
  on the PATH, which names a package whose linked test exits 3 and which
  has one fixture, on a stand-in harness that passes: `run` must exit 3
  and `--no-linked run` 0, so a broken skip, which would run each default
  linked test a second time, fails the gate. A set with a linked test and
  no fixture must exit 2 under `--no-linked run`, and `--no-linked` with
  another step, or with `--wiring`, is a usage error, 2. Each is decided
  by the script's exit status alone, and the check needs no build.
- **The default packages' own checks.** `shipped-themes`: sixteen checks
  in its driver (`ShippedThemesTest/Model.lean`), the completeness check
  on each theme among them; a linked test that holds each theme's picture
  to its reference image; and four fixtures, the fourth, `package-names`,
  a config that names the package's declaration `ShippedThemes.themes`,
  which elaborates because the editor's config base is its set's. `themes` switches from a
  theme of config's to `solarized-dark` and `fairy-floss`;
  `shipped-themes` starts in the `solarized-light` its config names; and
  `load-theme`, on a config that defines no theme, prints the theme
  prompt's candidates: `default`, `solarized-dark`, `solarized-light`,
  `fairy-floss`, in that order
  ([headless-mode.md](headless-mode.md)). `compile`: 98 checks in its
  driver (`CompileTest/Model.lean`), the ten model lists it had in the
  core, on the core's test kit; a linked test of 8 checks
  (`CompileTest/Linked.lean`): a compile over the real process service,
  on the fixture `packages/compile/tests/compile/three-lines`, the shipped
  modes on a stepped rig over the fixture trees and canned output beside
  it, and a compile through a host on a stepped stage
  (`compileHostChecks`); and three fixtures:
  `ex-names`, each of the six ex names reaching its command; `config`, a
  config written on the package's declarations; and `shipped-formats`, the
  shipped modes' formats reading canned output of cargo, lake and mise
  into locations, and mise's task list into commands, with no process.
  The first two and the host's script were written against the editor
  with the compile mode still in the core, and moved into the package
  with no byte changed; the third was written after the move, and an
  editor built at the commit before the move prints its `expected` for it,
  byte for byte ([packages.md](../design/packages.md), "The default
  package `compile`"). The four of the features-as-packages roadmap's
  phase 3: `mode-line` (1 check; the fixture `mode-line`),
  `execute-command` (16 checks, the interface's contract check and the
  registration of its completion source among them; the fixture
  `command-prompt`), `binding-search` (13 checks, the same;
  the fixture `binding-search`) and `languages` (1 check; no fixture),
  and the interface packages `execute-command-api` and
  `binding-search-api` (4 checks each: the fake keeps the contract, and
  the contract refuses a package that lacks or misspells the name)
  ([packages.md](../design/packages.md), "The default packages of the
  features-as-packages roadmap's phase 3"). The three of its phase 4:
  `completion` (19 checks: the shipped styles and display and its
  `Package` value, the interface's contract check among them; a linked
  test of 6 checks, the shipped styles' contract over the real fuzzy
  binding; the fixture `completion-choices`), `at-point` (29 checks, the
  interface's contract check among them; the fixtures `at-point` and
  `at-point-tuned`) and `minibuffer` (23 checks, the same; the fixtures
  `prompt` and `candidates`), and the interface packages
  `completion-api` (6 checks), `at-point-api` (7) and `minibuffer-api`
  (8): the names pinned whole, the fake, which for the last two is the
  core test kit's own implementation, keeps the contract, and the
  contract refuses a package that registers nothing, lacks a name or
  misspells one ([packages.md](../design/packages.md), "The default
  packages of the features-as-packages roadmap's phase 4").
- **An editor without the default packages refuses to start.** `mise run
  lean` also links an editor from `tests/empty-set`, the default set with
  its packages dropped. No package of that set supplies an input scheme,
  since the Vim scheme is the default package `evil`'s, so `ffi-test` runs
  that editor twice, in the headless mode on
  `tests/headless/no-input-scheme` and with `--probe`, and requires exit 1
  and exactly the line `editor: no input scheme is installed: no package
  of this editor's package set supplies one` each time
  ([packages.md](../design/packages.md), "Input schemes"). Until the
  features-as-packages roadmap's phase 7 the core supplied the scheme and
  two fixtures ran on this editor, `core-themes` and `core-ex-names`; they
  are retired, and where what they showed of an editor without the
  default packages is held is in
  [packages.md](../design/packages.md), "Dropping evil or themes
  leaves…". The gate also requires that set's config base to be
  `Editor` alone (`lake -d ../tests/empty-set query :editorBase`), and the
  default set's `Editor` and the entry modules of its twenty-five default
  packages, in the order they register (`Ex.EditorPackage` …
  `PackageSet.EditorPackage`, `Evil.EditorPackage`,
  `Themes.EditorPackage`, `Files.EditorPackage` …
  `VersionControl.EditorPackage`, then `Completion.EditorPackage` …
  `Languages.EditorPackage`), and that set's root to import `Editor` and
  `Editor.Main` alone (`:editorRootImports`): the core's Lake package has
  no entry module, so an editor of the core alone hands its hosts no
  package.
- **`run` refuses a directory that is not a whole fixture.** A directory
  under a package's `tests/headless/` with no `config/`, no `script` or no
  `expected` is exit 2, naming what is missing, and so is a set whose
  packages hold nothing the run could run: no linked test and no fixture
  at all, or, with `--no-linked`, no fixture.
- **The fixture's own checks.** `greeting`: three checks in its driver
  (`GreetingTest/Greeting.lean`), and the contract check of
  `greeting-api`, which it implements; a linked test
  (`GreetingTest/Linked.lean`) with a check of each kind the core has an
  executable for, one that reads its text back from the Rust library, as
  `ffi-test` does, and one that starts the headless host on the real
  elaborator over the set's packages, loads a config that binds a key to
  the package's command and sees the key run it, as `config-test` does;
  and the fixture
  `hello`, where its command runs on the fixture set's editor.
  `greeting-loud`: two checks in its driver, on greeting-api's fake, and
  the fixture `reply`, which shows it registered after `greeting`.
  `greeting-api`: four checks in its driver, that it declares
  `greeting-reply`, that its fake keeps its contract, and that the
  contract refuses a package that lacks the name or misspells it. `echo`: in its driver
  (`EchoTest/Model.lean`), the three vectors of its pure CRC-32 and the
  seven properties of its port's contract against the pure model, and one
  check of the model's own; in its linked test (`EchoTest/Linked.lean`),
  the same seven properties against the binding over its crate, each
  request's completion waited for on the linked test kit's table of
  waits, which only the completion pump ends, from the completion queue.
  Its crate's own tests (`cargo test`): a test of the service for each
  property on `editor-service`'s fake completer, the zlib adapter's
  vectors, and the C functions over the real completion queue
  (`rust/tests/wiring.rs`). `word-count`: five checks in its driver
  (`WordCountTest/WordCount.lean`), of its word count and of what it
  registers, and its three fixtures, the stages of the guide that quotes
  it (`docs/packages/writing-a-package.md`). `ffi-test` also runs the
  `hello` script on the default set's editor, which must answer `run
  greeting-hello: no such command`.
- **Seen to bite, once each by hand** (2026-11-19): a failing check in
  `GreetingTest/Greeting.lean` fails `mise run lean-test`; a definition
  with no doc string in `Greeting.lean` fails `mise run lean` (in its
  `lean-test` step, where `lake test` first builds the library under the
  package's linter options); a misformatted line fails `mise run lean-fmt`
  (`would-format`); a changed `expected` fails `mise run ffi-test`
  with the diff; and a fixture with its `script` moved away is refused by
  `run` with exit 2.
- **`run` builds nothing**, so `ffi-test` still only runs what `lean`
  built, and may run beside `lean-fmt`.
- **A set's Rust crates.** `ffi-test` requires the fixture set's package
  crates to be `echo`'s `echo-service` (`lake -d ../tests/packages query
  :editorRustCrates`, its first two fields) and the default set's to be
  none, so the fixture set's editor and `echo`'s linked test link the
  archive generated from `editor-ffi` and `echo-service`, and the default
  set's editor the core's ([packages.md](../design/packages.md), "Rust in a
  package").
- **A set's system libraries come back.** rustc writes the file of system
  libraries beside a generated crate (`target/editor-rust/<key>/native-static-libs`)
  only when it runs, so when the file is gone and the archive is fresh the
  build cleans the generated crate and builds it again (`buildRust` in
  `lean/lakefile.lean`). `ffi-test` deletes the fixture set's file
  (`target/editor-rust/echo-acp/native-static-libs`), builds `lake -d
  ../tests/packages build --wfail :editorRust`, and requires the file back
  holding the same line, which names `-lz`. It is the one step of
  `ffi-test` that builds: it runs Cargo alone, on an archive `lean` built,
  and writes only under `target/`, which `lean-fmt` does not read.
  **Seen to bite, once each by hand** (2026-11-19): with the clean given a
  package name that is not the generated crate's, the build fails on
  `cargo clean`; with no clean at all, it fails with `cargo built
  editor-rust-echo but rustc wrote no …`; either way the step fails.
- **A set's records and its install.** `ffi-test` requires the core's
  identity beside the default set's editor (`editor.core`) to equal the
  fixture set's, and on macOS the build environment beside it
  (`editor.build`) to hold `LEAN_CC=/usr/bin/cc`. It then installs the
  fixture set's editor into a temporary directory (`EDITOR_INSTALL_DIR=…
  lake -d ../tests/packages build :editorInstall`), runs `greeting`'s
  `hello` fixture from the copy with no `.olean` directory given, verifies
  the copy's ad-hoc signature on macOS, and requires a second install into
  the same directory to fail saying it exists
  ([packages.md](../design/packages.md), "User package sets"). The editor
  is up to date after `lean`, so the install builds nothing; it writes the
  temporary directory, and runs Cargo's own up-to-date check under
  `target/` as `:editorRust` does.
- **A user's set with no Rust runs no Cargo, and its C builds.**
  `ffi-test` writes a set in a temporary directory that requires the
  default set and the fixture package `c-glue` (a C source and its
  `@[extern]` binding), resolves it and links its editor with a `cargo`
  that always fails first on the PATH (`lean/no-cargo/cargo`):
  `:editorRustSource` says `prebuilt` for it and `cargo` for the default
  set, the two editors' `editor.core` are equal, `c-glue`'s command
  answers from its C function (`tests/user-sets/c-glue-expected`), and
  the default set's editor still reads as up to date
  ([packages.md](../design/packages.md), "Who can build it").
- **A Rust crate outside the repository is refused**
  (`tools/rust-outside-check.sh`): a copy of `echo` in a temporary
  directory makes `lake query :editorRustCrates` fail with the reason.
- **The package-set build in the headless mode** (`tests/user-sets/`):
  `git-missing`, run with `--data` in a temporary directory and a PATH
  with no git, says git is required and how to get it, writes nothing in
  the data directory, and still answers the next command; `match`, run
  with `--generate`, starts no build.

## The bundle test

`mise run bundle-test` (`tools/bundle-test.sh`, whose header says each
step) stages the app bundle's layout in a temporary directory removed by a
trap and runs its editor as the installed app runs it
([headless-mode.md](headless-mode.md), "From an app bundle";
[lean-runtime.md](../design/lean-runtime.md), "Build"):

1. **The stage.** `lake -d ../packages query :editorShipped` lists what the
   bundle ships of the default set, built: the core's and each default
   package's sources and build output, the set's and the packages'
   lakefiles, the core's glue and the Rust archive. `tools/stage-bundle.sh`
   copies them, the whole Lean toolchain, the editor, the launcher (built
   by Cargo, release, first) and, on macOS, the link stubs into
   `Leanmacs.app`, and writes the records `editor.core`, `editor.oleans`
   and `editor.build` (without `LEAN_CC`) in `Contents/Resources`. Every
   copy is a clone on APFS; on Linux the toolchain, about 3.1 GB, is
   copied.
2. **The pieces.** `lean`, `lake`, `clang` and `ld64.lld` are there and
   executable, with `Init`, `Std`, `Lean` and `Lake`, `lean.h`, the static
   libraries, the Rust archive and its system libraries, the core's and
   each default package's built modules, the core's glue, the set's
   lakefile and, on macOS, the stubs; it prints `bundle-test: the bundle
   holds lean, lake, clang, ld64.lld, Init, Std, Lean, the static
   libraries, the Rust archive, the built core and default packages`.
3. **The headless runs.** Through the launcher, `Contents/MacOS/leanmacs`,
   with no directory argument, an empty environment (`env -i`: no `HOME`,
   `PATH` or `LEAN_PATH`) and a working directory outside the bundle, the
   bundle's editor runs `tests/headless/bundle`, whose root imports `Lean`
   and names a declaration of Lean's elaborator, and three fixtures of the
   default packages: `shipped-themes` and `package-names` of the package
   `shipped-themes`, and `config` of the package `compile`. Each must
   print exactly its `expected`, which it can only from the modules the
   bundle's record names. The bundle fixture's first settle waits up to
   90 seconds (`settle 90000`), not the default 30: it is the chain's cold
   first reload, of a config that imports `Lean` from module files just
   copied into the bundle, and on the macOS runner it overlaps
   `ffi-test`'s cargo steps (the script's comment has the runs).
4. **The generated lakefile.** `headless --generate` on a copy of
   `tests/headless/generate`, whose config directory holds `init.lean`
   alone, must print exactly its `expected`, write a `lakefile.toml` equal
   to `tests/headless/generate/expected-lakefile-bundle` with `@CORE@` the
   bundle's `Contents/Resources/lean/lean` and `@SET@` its
   `Contents/Resources/lean/set`, and a `lean-toolchain` that is
   `lean/lean-toolchain` byte for byte. That lakefile requires the set the
   editor was built from, then, last, the core the editor links, at its
   root, so the reload starts no build.
5. **The version and the identity.** With `tests/headless/bundle/
   Info.plist` (the version, build ID, commit and core tag keys with a
   fake stamp)
   in `Contents/`, `--version` must print exactly `version-expected`, and
   the build tree's `editor --version` the line of a development build
   (the plist reader is `ModelTest.versionChecks`'). `leanmacs --probe`
   must print `probe: ok`, `launched-by <bundle>/Contents/MacOS/leanmacs`,
   on macOS `bundle <bundle> identifier org.leanmacs.bundle-test` (`bundle
   none` elsewhere) and `executable <bundle>/Contents/MacOS/editor`; so
   must `leanmacs --default <dir>/outside/editor -- --probe` for a copy
   outside the bundle; and with a per-user editor under the bundle's core
   in a data directory, `leanmacs --data <dir> --probe` must start that
   one and leave no cold record.

6. **The first launch.** With a fresh data directory, a state directory
   and a config of `init.lean` alone, the bundle's editor prints exactly
   `tests/headless/generate/expected` (but its state jobs' lines), says
   nothing of its packages and builds nothing (no `<data>/editors`), and
   the launcher's probe then names `Contents/MacOS/editor`.
7. **The unchanged default set from the bundle alone** (macOS; the Linux
   leg says it skips: the app is macOS on arm64 only). The bundle's
   `Contents/Resources/lean` is made read-only and listed (path, size,
   modification time); a config directory holds the generated lakefile;
   the environment is `env -i` with `PATH` a directory of decoys first
   (`lean`, `lake`, `clang`, `cc`, `ld`, `xcrun`, `cargo` and `git`, each
   logging its name and exiting 1), `CC` and `LEAN_SYSROOT` decoys,
   `HOME` inside the temporary directory and the bundle's `editor.build`.
   The bundle's own `lake -d <config> build :editorInstall` must exit 0,
   leave the listing identical (a compile would have failed writing into
   the read-only tree), run no decoy, and install an editor whose
   `editor.core` is the bundle's and whose `--probe` prints `probe: ok`.
8. **A package installed and a default one dropped**
   (`tools/bundle-sets.sh`, macOS): a first launch generates the lakefile
   naming the bundle's set; then, with `init.lean` importing `HelloInit`,
   three processes of `tests/user-sets/bundle-script` run through the
   launcher under the same decoys, decoy `LEAN_CC` too, and the read-only
   tree: `:package-install hello-init <copy>`, a copy that names the core
   from git, from a `file://` stand-in for the core's repository made
   before the decoys (`tools/core-repo.sh`), builds version 1 against the
   bundle's core, which the lakefile requires at its root, whose `run
   hello-init` says `hello-init: initialize ran`; `:package-remove
   compile` builds version 2, where `run compile` has no such command. The
   output must equal `tests/user-sets/expected-bundle`, versions 1 and 2
   of the bundle's core must be published, no decoy may have run (the
   decoy `git` among them, so Lake never fetched the core), the listing
   must be unchanged, no core may be cloned under the config's
   `.lake/packages`, and the launcher's probe must name version 2.

It has a time limit of its own, 600 seconds, for the toolchain's copy, the
builds and that settle, which can run out and say so well within it. On macOS (2026-11-20, Apple
M5 Max) the stage takes about 5 to 14 s, the default set's build from the
bundle about 7 s, the two builds of step 8 about 9 s, and the whole test
about 30 s.

## The user sets test

`mise run user-sets-test` (`tools/user-sets-test.sh`, part of `ci`, after
`lean` and `launcher`, with a time limit of 600 s) runs a user's package
set end to end through the app's launcher
([packages.md](../design/packages.md), "User package sets"). Everything it
writes is in a fresh temporary directory, with `HOME` and `XDG_*` pointed
inside it, but the fixture packages' own `.lake/` under `tests/user-sets/`.
`hello-init` is installed from a copy in that directory that names the
core from git, as a published package does: a `file://` stand-in for the
core's repository, tagged `nightly-20000101000000`, holding none of the
core's sources (`tools/core-repo.sh`), with the copy's manifest written by
`lake update` against it.

The `lean` and `lake` it runs are those of the toolchain `lean
--print-prefix` named before it moved `HOME` (wrappers around
`$sysroot/bin/lean` and `lake`, first on the `PATH`), and
`user-sets-check` does the same. A toolchain manager that resolves its
toolchains under `HOME`, as elan does on CI, would otherwise install and
run another copy of the toolchain, and the default set's editor's link
trace names the toolchain's directory (`-L <toolchain>/lib`), so that copy
reads the editor as out of date though nothing rebuilt it (found
2026-11-20, CI run 44825190133 on macOS). Both tasks run under
`tools/home-bound-toolchain.sh`, whose `lean` and `lake`, like elan's
proxies, exit 1 when run under any `HOME` but the one they were made
under, so a bare `lake` after `HOME` moves fails on a developer's machine
too, where mise's `lean` does not depend on `HOME`. `lean-test` probes the
stand-in: its `lake` under `HOME=/nonexistent` must exit 1 with its
message, and under its own `HOME` exit 0.

- **A, install, a failing link, a dropped default package**
  (`tests/user-sets/install-script`), three processes started by
  `leanmacs --data … --default packages/.lake/build/bin/editor -- headless
  --state … --data …`. The shipped default loads a lakefile that requires
  the default set and starts no build, and refuses the config, which
  imports `HelloInit`; it opens a file, types, splits and opens a tab, and
  `:package-install hello-init <dir>` (the copy naming the core from git)
  writes the running core's require at the lakefile's root, builds the set
  against that core, cloning none, and restarts into version 1, which
  restores the session (the unsaved text, the split, the
  tab, the summary) and answers `hello-init: initialize ran`.
  `:package-install broken-link <dir>` fails at the link: the echo says
  the editor keeps running, and it does. `:package-remove broken-link`
  matches version 1 and builds nothing. `:package-remove compile` expands
  the default set and restarts into version 2, where `run compile` has no
  such command. Its output, with the paths and the core's identity
  written `@DIR@`, `@REPO@` and `@CORE@`, and job
  lines and the build buffer's views left out, must equal
  `expected-install`; the build buffer's views must hold `Package build
  failed: lake build exited with status 1` and the linker's
  `leanmacs_no_such_symbol`; the lakefile must equal `expected-lakefile`
  (the core, the shipped themes and `hello-init`, by absolute path); no
  core may be cloned under the config's `.lake` (no
  `.lake/packages/editor-core`, no file of the stand-in); the
  data directory must hold exactly versions 1 and 2 of the core and no
  staging directory; the launcher's probe must choose version 2; no
  hand-over or cold record may be left; and the default set's editor must
  read as up to date.
- **B, a set that fails to elaborate** (`elab-script`): on the shipped
  default, the build buffer ends failed with Lean's `Type mismatch`, the
  editor keeps running, and nothing is published.
- **C, git missing**, through the launcher, with no git on the PATH: it
  says git is required and how to get it, and writes nothing in the data
  directory.
- **D, a set that resolves another core**: a lakefile written by hand that
  reaches the core only through the default set and holds a copy of
  `hello-init` naming the core from git, a `file://` stand-in for the
  core's repository with the tag `nightly-20000101000000`
  (`tools/core-repo.sh`), so Lake resolves the core to that clone. The
  shipped default's build must stop before it links, the echo saying
  `packages: the package set resolves editor-core to git file://…` and the
  build buffer ending `Package build failed: the package set resolves
  editor-core …`; `run tab-new` must still answer, and nothing is built
  into the data directory. It builds nothing, so it takes about a second.

**Nothing it starts outlives it** (`tools/leftovers.sh`), here and in
`bundle-test`, `app-check` and `user-sets-check` alike. Every process a
step starts names the check's temporary directory on its command line:
the launcher, the editor, the launcher's watcher and its record. Before
the check says `ok`, none may still be running, the watchers given 10 s to
see their records go; on its way out, whatever the outcome, an interrupt
included, the check kills any that is before it removes the directory. A
watcher left behind falls back when its editor ends, and with its record
removed under it the launcher starts the shipped default cold with no
arguments: a window on the desktop that no one waits for (found
2026-11-20, six such windows from staged bundles). A headless run the
launcher handed a record removes it as it ends by itself, if its
hand-shake has not (`Restart.Launch.removedAtEnd`), so its watcher starts
no fallback.

Measured on macOS arm64 (2026-11-20): about 17 s, cold fixture packages
included; A's three processes about 13 s.

## The pre-commit hook

```sh
hk run pre-commit
```

The pre-commit hook (`hk.pkl`, `pre-commit`) and `hk check` have one
step, `mise_ci`, which runs `mise run ci` when any staged path matches
its glob, and nothing else. The glob is every file the gate reads: the
Rust, C and Cargo files wherever they are, the crates and the vendored
grammar they build from (`crates/**`, `vendor/**`, since `include_str!`
pulls in query files and the renderer its shader), the Lean core
(`lean/**`), the package sets and the fixtures (`packages/**`,
`tests/**`), the default config (`config/**`), the writing guide's
example package (`docs/packages/*/**`, which the fixture set requires),
every script the gate runs (`tools/**`), what the bundle steps stage
(`packaging/**`), the CI workflows and the files the workflow lint
compares them with, `mise.toml`, the tools' configs (`deny.toml`,
`clippy.toml`, `.clang-format`) and `hk.pkl` itself. A commit that stages
only other files (the rest of `docs/`, `README.md`, `.agents/`, `infra/`
beside the workflow lint's `actions.tf`) runs no step.

The step passes or fails by `mise run ci`'s exit status. Which paths
select it is `hk`'s glob alone; no script decides what to run. So the
hook takes as long as the whole gate, by the owner's choice: a slower
hook that runs everything over a faster one that a script narrows.
Faster selection from the build graphs, by a tool rather than a shell
script, is rdm task `build-graph-test-selection-tool`.

## The Rust bans check

```sh
cd lean && dir=$(lake -d ../tests/packages query :editorRustCrate) &&
  cargo deny --offline --manifest-path "$dir/Cargo.toml" check \
    --config "$dir/deny.toml" -D unused-wrapper bans
```

Part of `mise run ffi-test`. A package's crate depends on `editor-service`
and on nothing else of the editor's, so neither on `editor-ffi` nor on
another package's crate. The root `deny.toml` cannot hold that, since
nothing in the root graph depends on either (its header says why), so
cargo-deny's bans run over the crate the package-set build generates from
the set (`lake -d <set dir> query :editorRustCrate`, which writes it and
prints its directory), with the `deny.toml` the build writes beside it
(`rustDenyConfig` in `lean/lakefile.lean`): the generated crate is the one
wrapper of `editor-ffi` and of each package crate, and
`editor-release-std` is banned. Offline, bans alone, stale wrappers errors.

- **It holds of the fixture set and of the default set**: `ffi-test` runs
  it on each, and passes by cargo-deny's exit status.
- **It bites**: `ffi-test` runs it, without `-D unused-wrapper`, over the
  two bite sets of `tests/rust-bans/`, each with one edge the rule
  refuses, and requires exit status 2 from each, cargo-deny's status when
  the bans check alone fails (a bit for each failed check, the bans' being
  2; seen with cargo-deny 0.19.9). `ffi`, whose package `bans-ffi`'s crate
  depends on `editor-ffi`, holds the config's `editor-ffi` entry; `peer`,
  whose package `bans-peer`'s crate depends on `bans-base`'s, which
  depends on nothing, holds the package crates' entries. Drop either kind
  of entry, make it a no-op, or name each package crate a wrapper of the
  others, and that set's run exits 0, so the step fails. A stale wrapper
  stays a warning there: as an error it would fail the bans, and give 2,
  for a config that refuses nothing. A config cargo-deny cannot parse or a
  manifest it cannot load exits 1, and a missing config file exits 0, so
  neither passes. Neither set's crates are members of the root workspace,
  so the bad edges never enter the root graph, and nothing compiles them:
  cargo-deny reads metadata.
- It writes the generated crates under `target/editor-rust/` and Lake's
  configuration in the sets' `.lake`, which no other task reads.

## The wait lints

Every time bound in a test is a value that says which kind it is, and a
wait takes only that type (`docs/design/concurrency.md`, "What a test may
still wait on time for"; `docs/dev-practices/inferred-waits.md`). What a
type cannot say is held by lints, each part of the build or of `mise run
lint`, never a script over source text:

- **`linter.rawClock`** (`lean/Lint/Wait.lean`, part of every `lake
  build`): a call of `IO.sleep` or a read of `IO.monoMsNow` or
  `IO.monoNanosNow` in any module but `Editor.Bound` is a lint, and
  `warningAsError` makes it an error. It reads the constants the command's
  terms resolved to (its info trees), never text. It is on through
  `linter.all`, in the core and in every package's lakefile, and active in
  every module of the core's libraries and of every package under
  `packages/` and `tests/packages/`, which the build elaborates with the
  library `Lint` loaded as a Lean plugin (`lintPlugin` in
  `lean/lakefile.lean`, `plugins` in each package's lakefile). The plugin
  is named by the core's target `lintShared` (`@editor-core/lintShared`),
  never by the facet `Lint:shared`: Lake does not memoise a plugin named by
  a facet key, so each module's setup would build its own, and the `Lint`
  modules would be built several times at once into the same files. No
  module imports it: it imports `Lean`, which the config base and the model tests
  may not reach (`.agents/rules/structure.md`, "Core imports"). A bench, or
  `config-test --timings`'s wall clock, says it measures real time with
  `set_option linter.rawClock false` and its reason.
- **`linter.inferredWait`** (the same module): a reference to a constant
  with a mark, a declaration `<constant>.inferredWait` of the type
  `Editor.InferredWait` (`lean/Editor/InferredWait.lean`, plain data that
  the editor's modules may hold), outside its own module, its subject
  modules and the test modules that mirror them is an error, and so is a
  public declaration of an allowed test module that hands one on with no
  mark of its own, or a reference to a constant whose mark the linter
  cannot read. Each site left is under `set_option linter.inferredWait
  false in` with its row of `inferred-waits.md`.
- **`linter.realHost`** (`lean/Lint/RealHost.lean`, loaded with the
  others): a reference to a constant marked a real host or a real service
  (`<constant>.realHost`, `lean/Editor/RealHost.lean`) in a test module
  that declares no wiring set (`wiringSet.<module>`) is a lint, unless it is
  inside a declaration that has a mark itself; a `.contract` module and
  contract-test may reach a service and never a loop, an `.edge` root only
  in its `main`, and a public helper of a wiring module that hands one on
  must be marked, `main` or a check
  ([real-thread-checks.md](real-thread-checks.md)). Its fixtures are
  `ModelTest/Lint/RealHost.lean` and the modules under
  `ModelTest/Lint/RealHost/`, `ConfigTest/Lint/RealHost.lean` and greeting's
  `GreetingTest/Linked/Lint/RealHost.lean`, and its rules' checks
  `LintTest.lintRealHostChecks`.
- **It bites**: `ModelTest/Lint/Wait.lean` holds `#guard_msgs` fixtures,
  built by `mise run lean-test` and `mise run lean` and never run, that
  expect the error for a raw sleep, a raw clock read, a count read outside
  its modules, a laundering wrapper, one through a private wrapper, a count
  read in a module named beside a mirror that declares no wiring set (the
  modules under `ModelTest/Lint/Wait/`, beside a `.wiring` one that may), a new
  count read in a check list
  beside a check under an allow and a mark of the wrong type or worked
  out, and a `fail_if_success` that `Job.awaitWithin` takes no number;
  `ContractTest/Lint/Wait.lean` expects it for a first-after wait, which
  needs the linked kit, and `ConfigTest/Lint/Wait.lean` for an idle wait
  put together from a host's `waitWhile` and a kind, which needs the host.
  `FfiTest/Lint/Wait.lean` and the fixture package `greeting`'s
  `GreetingTest/Lint/Wait.lean` expect it for a raw sleep, so the plugin is
  seen loaded by `lintPlugin` into the `ffi-test` executable's library and
  by a package lakefile's `plugins` line into a package's. The rules they apply, which module is a test module, which mirrors
  which, and how a mark is read, are `LintTest.lintWaitChecks`, which
  `mise run lean-test` runs (`lake exe lint-test`): those checks call the
  linters' functions, so they import `Lint` and are an executable of their
  own, whose library loads no plugin. `ModelTest/Editor/Bound.lean`'s
  `fail_if_success` examples show that a number, an anonymous constructor
  and a structure instance are not a bound.
- **It is loaded**: a library that loads no plugin is never linted, and
  no fixture would say so. Every `lean_lib` and `lean_exe` of the core and
  of each package in this repository loads the core's `Lint` as a plugin,
  or has it by import (`Lint`, `LintTests` and `lint-test`, where loading
  it too would register the linters twice); the libraries of a set's
  generated roots get the plugin from the build (`generatedLib`). That is
  a reviewer rule (`.agents/rules/structure.md`, "Lint plugins"), not a
  gate step. A package written as a user's, as `docs/packages/word-count`
  and `tests/user-link/package` are, names no plugin.
- **Rust, by clippy** (`mise run lint`): the root `clippy.toml`, the
  workspace's one, which every crate reads (no crate has one of its own),
  bans through `disallowed-methods` the raw timed primitives
  (`thread::sleep`, `sleep_ms`, `park_timeout`, `park_timeout_ms`,
  `yield_now`, `Receiver::recv_timeout`, `Condvar::wait_timeout`,
  `wait_timeout_ms`, `wait_timeout_while`, `JoinHandle::is_finished`,
  `Child::try_wait`, `Instant::now`), the readout waits and the C
  functions Lean calls to wait, whose bound is a number of milliseconds;
  `editor-wait`'s `HangGuard`, `recv`, `wait_while`, `Deadline`,
  `Stopwatch` and `RealTime::sleep` take their place, and a Rust check of a
  C function makes its number from a guard (`HangGuard::as_millis`). The
  same file bans the outside world a core reaches only through its ports
  (real files, the machine's directories and environment, processes, the
  wall clock, each adapter's real constructor), in every crate.
- **An opt-out is an `#[expect]` with a reason, at its site**: the root
  `Cargo.toml`'s `[workspace.lints.clippy]`, which every member takes
  (`[lints] workspace = true`), denies `disallowed_methods`,
  `disallowed_types`, `allow_attributes` and
  `allow_attributes_without_reason`, so an `#[allow]` or a mark without a
  reason fails the lint, and an `#[expect(clippy::disallowed_methods,
  reason = …)]` that no longer covers a banned call is unfulfilled, which
  `-D warnings` fails. At a check that waits through a C function its
  reason names the row of `inferred-waits.md`. A `disallowed_methods`
  opt-out sits at its site: on the statement or `let` that makes the call,
  or on the `fn` or `impl` whose call it is, never on a module or a crate,
  a test module or file included, since the wait bans are the same lint. A
  test module that waits on its readout again and again calls it through
  one helper `fn`, whose statement carries the mark. **An item's
  mark never covers a wait**: a banned wait inside an `fn` or `impl` that
  carries a mark for the outside world has a statement-level `#[expect]`
  of its own, whose reason is the wait's. These scope rules are a
  reviewer's (`.agents/rules/structure.md`, "Clippy's bans"); the root
  `clippy.toml`'s header says where the marks are.
- **It bites**: `mise run lint` runs clippy over `tests/wait-lints/`, a
  crate outside the workspace (its own lock, read `--locked --offline`,
  into `target/wait-lints/`) that calls each banned wait a crate other
  than its owner can call, once, each call under an
  `#[expect(clippy::disallowed_methods)]` of its own that names the path
  it shows. Clippy over it passes, by its exit status, only while every
  one of those bans bites: one that stopped biting leaves its expectation
  unfulfilled. A wait ban added to the root `clippy.toml` gets its call
  there (a reviewer rule). So does each `allow-invalid` entry point that
  no crate of the workspace calls (`parley::FontContext::new`,
  `fontique::Collection::load_system_fonts` and `load_fonts_from_paths`,
  in `unreached`): clippy does not refuse an `allow-invalid` path that
  resolves to nothing, so such a ban bites only while an `#[expect]`
  covers a call of it, and every other `allow-invalid` ban has one at its
  site in the workspace.

## Formatting

```sh
mise run lean-format   # Lean, with lean-fmt
mise run c-format      # C, with clang-format (.clang-format)
cargo fmt --all        # Rust
```

`mise run c-format` and its check, `mise run c-fmt`, look at tracked files
only, so `git add` a new C file before running them. They leave `vendor/`
out: vendored C is upstream's generated code (`vendor/README.md`), neither
checked nor rewritten here.

`mise run lean-format` and its check, `mise run lean-fmt`, run lean-fmt
over the core and then over each package of the fixture set
(`tools/package-set.sh format`, `fmt`).

- **lean-fmt is required by a package of its own, its host**
  (`tools/lean-fmt/lakefile.toml`), not by the core: a package set that
  requires the core would fetch every git dependency of the core
  ([packages.md](../design/packages.md), "Manifests: a set's build fetches
  nothing"). The tasks run it as `lake -d ../tools/lean-fmt exe lean-fmt …
  --root <package>` in `lean/`: Lake builds the formatter from the host,
  and `--root` names the package it is run over, `.` for the core.
- **The clone stays under `lean/.lake/packages`** (the host's
  `packagesDir`), where it was when the core required it and where CI's
  cache of `lean/.lake` holds it. Its pin is the host's
  `lake-manifest.json`; to bump it, change `rev` in the host's lakefile
  with `lean/lean-toolchain` and run
  `lake -d ../tools/lean-fmt update --keep-toolchain` in `lean/`.
- **It writes a cache in the root it is given**, `.lean-fmt-cache`, which
  git ignores in any directory, and it refuses a root with no
  `lean-toolchain`, which is one reason every package holds a link to the
  pin.
- **A package's headless fixtures are excluded** by a `lean-fmt.toml` in
  the package (`exclude = ["tests/**"]`): a config file is a module of a
  config directory, another Lake package, and is not built with this one. The core has no such file, since its fixtures are outside
  `lean/`.
