import Editor.Menu

/-!
# Bindings to the Rust library

The functions `editor-ffi` (`crates/editor-ffi`) exposes, as Lean
declarations. A pure function over plain numbers binds straight to its Rust
symbol. Any other function binds to a wrapper in `ffi/glue.c`, which calls the
Rust function and builds the Lean value for its result with `lean.h`.

## Conventions

Every binding follows the rules below. Each rule that can have one has a small
real example in this module, and each names the tests that pin it or says that
none does. This is Lean's side of each rule; Rust's side is in the crate docs
of `crates/editor-ffi/src/lib.rs`.

`ffi-test` is the test executable (`FfiTest.lean`), linked against the real
library like the editor. `mise run ffi-test` runs its checks and its
scenarios, all but `overflow`, in the gate.

### Handles

A Rust object is a Lean external object with a finaliser, never a number. Its
Lean type is opaque (`opaque …Pointed : NonemptyType`), so the only way to get
one is the binding that makes it, and no binding takes or returns an address
or frees anything. Lean runs the finaliser when the last reference is dropped,
on whichever thread drops it, and that is the only thing that frees the Rust
object. A handle therefore cannot be used after it is freed: while any
reference exists, on any thread, the object is alive.

Pass a handle to a binding as `@&`, so the call does not take a reference.

Examples: `Counter`; `Document`, the text the text port's real binding holds,
made from a string or from a snapshot (`Document.ofSnapshot`); and
`Snapshot`, a text as it was at one moment, which is made by a binding on a
document and outlives it, or handed over by the file service as the text of
a file it loaded (`filesTake`); and `Display`, layout over the library's
fake shaper, asked about snapshots (`Display.rows`, `Display.move`), whose
one caller is the display interface's real binding
(`Editor/Display/Real.lean`); and `SyntaxQuery`, a query of the library's
syntax service, made by `SyntaxQuery.new`, whose check that it is freed is
in `FfiTest.syntaxChecks`. Tests: the four counter checks of `ffi-test`
(`FfiTest.handleChecks`), its check that a document is freed
(`FfiTest.documentChecks`), its checks that a snapshot is freed and outlives
its document (`FfiTest.snapshotChecks`) and its checks that a loaded
snapshot is counted live and that a document made from a snapshot is freed
(`FfiTest.fileChecks`), and its checks that a display is freed and that its
answers cross (`FfiTest.displayChecks`); `tests/c_api.rs`,
`tests/snapshot.rs`, `tests/document_from_snapshot.rs`, `tests/files.rs` and
`tests/display.rs` in `editor-ffi`.

### Plain data

| Kind | Lean to Rust | Rust to Lean |
|---|---|---|
| String | `@& String`; the glue passes its bytes and byte length, and Rust copies what it keeps | The glue copies the library's buffer into a `String` and hands the buffer back |
| Enum | An enumeration inductive, which Lean passes as a `UInt8` tag that Rust checks | A `UInt64` tag in a private raw structure, decoded here (`EventKind.ofTag?`); an unknown tag is an `IO` error |
| Small structure | The wrapper passes the fields as scalar arguments | The glue builds the structure in one call. Declare object fields first, then `UInt64` fields and nothing else, so the declaration order is the layout the glue writes |
| Option | The wrapper passes a presence flag and a value | The glue builds `none` or `some` |
| Optional handle | `@& Option` of a handle, which the glue passes as the handle's pointer, or null for `none` (`syntaxInjectLanguage`) | None yet |
| Byte range | Two scalars | `ByteRange`: two `UInt64`, half-open, in bytes |
| List | *Words*: a `@& ByteArray` of 64-bit numbers, eight bytes each, least significant first, written by a private encoder here; the glue passes its bytes and byte length, and Rust checks every count against the buffer | The glue copies the library's buffer of words into a `ByteArray` and hands the buffer back; a private decoder here builds the typed value, and words it cannot read are an `IO` error |
| List of handles | `@& Array Snapshot`, an array of handles borrowed for the call, beside the words, which name a handle by its index in it; the glue passes it as a C array of the handles' pointers and its count, which it builds for the call (`Display.publish`) | None yet |
| List of strings | Words, the count and then the byte length of each string, written by a private encoder here, and one `@& String` of all of them end to end; Rust refuses lengths that do not add up to the string or that end inside a character (`fuzzyRank`, `syntaxHighlight`) | The same words and string in a private structure of two object fields the glue builds in one call, decoded here; words that do not add up to the string are an `IO` error (`syntaxGrammars`, `SyntaxQuery.captureNames`) |

A picture (`Picture`, for tests) crosses as a small structure: its pixels,
an object field the glue copies from the library's buffer into a
`ByteArray`, then its width and height as `UInt64` (`Display.picture`,
`Picture.ofPng`); and in, as its width and height as scalars and its pixels
as a `@& ByteArray`, with a PNG file's bytes out as a `ByteArray`
(`Picture.toPng`). A refusal with a reason the library gives in a sentence
is an `IO` error the glue raises with it (`Display.newFont`,
`Picture.ofPng`).

Prefer a few scalar arguments or one structure to many calls: one `nextEvent`
returns one whole event. A raw structure whose shape the glue knows stays
private to this module; what a caller sees is the typed value.

Examples: `find` (an option in, an option of a byte range out), `Event` with
`postEvent` and `nextEvent` (a string, enums and a structure, in both
directions), `Document` (a string in, to `Document.new` and
`Document.replace`; a string out, from `Document.read`; byte offsets as
`USize`; a refusal as a `Bool`) and `Snapshot` (a structure of three numbers
out, `SnapshotInfo`; an enumeration in, `ColumnUnit`; an option of a
structure out, from `Snapshot.pointOf`, and an option of a number, from
`Snapshot.offsetOf`; rows and columns as `UInt64`; an inductive whose
constructors carry values in, `Motion`, which a private encoder here writes
as a `UInt8` tag and the two numbers of a motion by rows, for
`Snapshot.motion`; and an option of a string out, from `Snapshot.row` and
`Snapshot.slice`). A document's
transactions and its edit log are the example of lists: a `Transaction` in,
as words and one string of everything it inserts (`Document.apply`); a
`Patch` and a trace out, as words (`Document.changesSince`,
`Document.trace`); and a refusal as a `Bool` (`Document.forget`). A
document's markers are words in both directions for one value: a `Marker`
in, as words (`Document.mark`, `Document.place`), and out, as words
(`Document.marker`); and a `Selection` in and what it covers out, both as
words (`Snapshot.extents`). A refusal with more than one reason is a status
the library reports as a number, read here into an inductive
(`MarkRefusal`). A published scene is the example of a list of handles:
words, one string of every text it holds, and the `Snapshot`s its views
show, which the words name by index (`Display.publish`); it comes back as
the same words and string, and as `none` before any is published
(`Display.scene`). The definitions of the faces the scene names are in the
same words and the same string, after the views, behind a presence: absent
is "as last published", so a scene and its faces cross in one call
(`RealDisplay.encode`). A document's kept inverses are scalars in and words out
with an option inside them: a run of revisions and an origin in, as three
numbers, and an `Inverted` out, the revision the inverse produced with the
selection it hands back if there is one (`Document.applyInverse`, with its
refusals in `InverseRefusal`); and a run in and a refusal as a `Bool`
(`Document.dropInverses`). Fuzzy ranking is the example of a list of strings,
and of a call that keeps nothing in the library: a pattern and candidates
in, and the indices of the candidates the pattern matches out, best first,
as words (`fuzzyRank`), whose one caller is the fuzzy matching interface's
real binding (`Editor/Fuzzy/Real.lean`). A search of a snapshot is the
example of words out that are a sentence when the call refuses: the pattern
as a string and scalars in, and words out with a status, whose bytes are the
sentence in UTF-8 for a pattern the syntax refuses (`Snapshot.search`,
`Snapshot.matches`, whose one caller is the text port's real binding). The
two reads of a pair take a bracket or a quote as a tag, which a private
encoder here writes, and answer an option of an option: none for a
refusal, and inside it none for nothing found (`Snapshot.unmatched`,
`Snapshot.quoted`). A length or an offset in words is a `UInt64`, and the
largest one is a number no text accepts: a caller with a number no word
holds sends that, so the library refuses it and nothing is cut down. Tests:
the `find` and event checks of `ffi-test` (`FfiTest.dataChecks`), its
document checks (`FfiTest.documentChecks`), its snapshot checks
(`FfiTest.snapshotChecks`), its transaction checks
(`FfiTest.transactionChecks`), its marker checks
(`FfiTest.markerChecks`), its inverse checks (`FfiTest.inverseChecks`),
for a list of strings its ranking checks (`FfiTest.fuzzyChecks`) and,
for a list of handles, its scene checks (`FfiTest.sceneChecks`); the unit
tests of `text.rs`, `document.rs`, `snapshot.rs`, `words.rs`,
`transaction.rs`, `log.rs`, `marker.rs`, `inverse.rs`, `fuzzy.rs` and, for a
scene's words, `display/wire.rs`, the tag tests of `events.rs`, and
`tests/log.rs`, `tests/markers.rs`, `tests/inverse.rs`, `tests/fuzzy.rs` and,
for a scene published with its handles and written back, `tests/display.rs`
in `editor-ffi`.

The editor does not call these bindings. It reaches the library through a
port it defines (`Editor/Text.lean`), whose real binding
(`Editor/Text/Real.lean`) is the one caller of `Document` and of `Snapshot`
(beside the display's real binding, which reads snapshots),
and whose contract (`Editor/Text/Contract.lean`) runs against that binding in
`contract-test`.

### The event queues

Rust never calls a Lean function. Rust threads push events onto a queue, and
Lean pulls them with `nextEvent`, which blocks in Rust: call it from a
dedicated task, never from the thread pool. An event is plain data tagged with
its source: a kind, a code, a text, a stamp, and its detail as words (`words`),
which the glue copies like the text, and whose meaning the kind sets. There are two queues (`Queue`): the editor queue, for input and
events for the editor thread, and the completion queue, for the results of
service requests, pulled by a dedicated task (the completion pump,
`Editor/Job/Real.lean`). `feedScript` drives the library's fake event source,
for tests.

Tests: the three queue checks of `ffi-test` (`FfiTest.queueChecks`); the unit
tests of `events.rs` in `editor-ffi`, which need no Lean.

### Services and completions

A service does work for a job that takes time, and a job that waits must not
hold a thread. So a request to a service is never a blocking binding. The
request goes in with an id the caller chose and returns at once; when the
work is done the library queues a `completion` event on the completion
queue, whose code is that id; and a cancel binding takes the id and stops
the work. Ids and deadlines are plain numbers: no handle crosses, and the
library never calls Lean. A completion may still arrive for a request that
was cancelled, and whoever pulls the queue ignores an id it no longer waits
for.

The timer service is the first: `timersNow`, `timersStart`, `timersCancel`,
and `timersPending`, a readout for tests.

The file service is the second: `filesLoad`, `filesSave` and `filesStamp`
start a request,
`filesTake` hands its result over once its completion has arrived,
`filesCancel` cancels, and `filesPending` is a readout for tests. A request
has a result, which a timer's has not, so there is one more step: the
completion says only that the request `id` is done, and the result is taken
by that id, once, as one record (`FileResult`): a loaded file's text as a
`Snapshot` handle with its stamp and its line endings, a saved file's stamp,
a file's stamp or none, or a refusal (`FileRefusal`). A file's content never crosses as a Lean
string or a byte array: a load hands back a handle, and a save borrows one.
A path crosses as the bytes of a Lean string, which the library does not
decode. What a save expects on disk (`FileExpect`) crosses as a tag and a
stamp's three numbers. A stamp's seconds are an `Int`, and cross as a 64-bit
two's complement word in both directions.

The process service is the third: `processesRun` starts a run of a command
to its end, `processesRunInput` one fed its standard input, `processesTake` hands its result over once its completion has
arrived, `processesCancel` cancels it, which kills the child's process
group, `processesShutdown` kills every group and blocks until every child is
reaped, and `processesPending` is a readout for tests. A command crosses as
a list of strings does: words, and one string of every text end to end. A
result is a status, words, a detail and the two streams' bytes
(`ProcessResult`). A streaming child is opened (`processesOpen`, three words
before a run's), read (`processesRead`), written to (`processesWrite`) and
closed (`processesCloseInput`), each with a wait's id; its replies come back
in a run's record (`processesTakeStream`), a delivery's lines as lengths in
its words, decoded by `StreamReply.decode`. `processesHeld` says, for tests,
whether a child is held at its bound.

The watch service is the fourth: `watchesStart` starts a watch of a file, a
directory's entries or its tree, as three words and the path's bytes;
`watchesNext` asks for a watch's next delivery, under a wait id of its own;
`watchesTake` hands a reply over once its completion has arrived, as a
status, words, a detail and the paths end to end (`WatchReply`, decoded by
`WatchReply.decode`); `watchesCancel` cancels a watch or a wait,
`watchesShutdown` ends every watch, and `watchesPending` is a readout for
tests. A path in a delivery is its bytes as the platform gave them, which
on Linux need not be UTF-8: the job runner's real service decides what such
a change is (`realFileWatches`, `Editor/Job/Real.lean`).

The editor does not call these bindings. The job runner reaches the services
through the ports it defines (`Job.Timers`, `Editor/Job/Runner.lean`), whose
real implementations (`Editor/Job/Real.lean`) are the callers, with the
completion pump that pulls the queue on a dedicated task.

Tests: the three timer checks of `ffi-test` (`FfiTest.timerChecks`), its
file checks (`FfiTest.fileChecks`), in directories they make and remove, its
process checks (`FfiTest.processChecks`), whose children run in directories
they make and remove, and
its watch checks (`FfiTest.watchChecks`), in directories they make and
remove, its check that the completion tag is known (`FfiTest.dataChecks`);
`contract-test`, which runs the job port's contract and the checks of the
real service through the runner (`ContractTest.jobChecks`); the unit tests
of `timers.rs`, `files.rs` and `processes.rs`, and `tests/timers.rs`,
`tests/files.rs`, `tests/processes.rs`, `tests/processes_stream.rs` and
`tests/processes_shutdown.rs`, in `editor-ffi`, which need no Lean.

### The syntax service

Parsing is not a service behind the completion queue: nothing waits for it.
`syntaxAttach` has the library parse the document a snapshot is of with a
grammar (`syntaxGrammars` lists them), on a worker thread of its own, and
reparse it after each of its edits; `syntaxDetach` stops it, and so does
freeing the document. A query is a handle, `SyntaxQuery`, made by
`SyntaxQuery.new` from a grammar and a source, its refusal a status, the
library's tag of why and an offset; its names are a list of strings out
(`SyntaxQuery.captureNames`). `syntaxCaptures` answers a query's captures
in a range of a snapshot, as words, at once from the tree the library last
delivered, and refuses with `notParsed` when that tree is not of the
snapshot's revision: it never waits for a parse. `syntaxSettle` waits, with
a bound, for a delivery, for tests.

`syntaxShippedQuery` answers the source of the query of a kind a grammar is
published with (the kind as a tag: 0 highlights, 1 injections, 2 text
objects, 3 indents), or a status.
`syntaxHighlight` has the library draw a document with a query's captures
in faces from now on: the faces cross as a list of strings in, the empty
string for none, and the refusal is a status. Highlights never come back to
Lean: the library draws them in the display, and reports each delivery of a
highlighted document's parse as a `parsed` event on the editor queue
("The event queues").

`syntaxInject` has the library find a document's injections with a query
from its next round on, and `syntaxInjectLanguage` gives it a language an
injection may name: its highlights query, a face for each capture as a list
of strings in, and its own injections query, an optional handle. The
library parses each injection as a layer and draws it over the document's
own spans, and reports the delivery like any other. `syntaxKeep` has a
document keep a query of a kind, and `syntaxKeptNames` and
`syntaxKeptCaptures` answer its capture names, a list of strings out with a
status, and its captures in a range, as words, from the tree delivered,
refused as `syntaxCaptures` is. Each refusal is a status.

Its one caller is the syntax tree interface's real binding
(`Editor/SyntaxTree/Real.lean`). Tests: the syntax checks of `ffi-test`
(`FfiTest.syntaxChecks`), `contract-test`'s syntax tree properties, and the
unit tests of `syntax.rs` and `tests/syntax.rs` in `editor-ffi`.

### The window

A window is run by the library's main-thread service, and what it reports
arrives on the editor queue.

- `windowRun` is one blocking binding: it returns when the window has
  closed. Call it from Lean's main thread or a dedicated task, never from the
  thread pool. While it runs, the main-thread service answers nothing else,
  so ask `mainThreadProbe` before, not during.
- How the window is opened goes in as scalars, one for each option:
  whether an input method may compose, and the present mode and frame
  latency a run asks for, each none for the renderer's decision. A failure
  to open comes back as a reason, in an `Except`; a window that ran with
  nothing drawing in it, because its renderer could not be made or its
  render thread did not end well, comes back as `.ok` with that reason
  (`WindowRan.nothingDrew`).
- What draws in the window is the library's: a display bound to the
  library's presenter (`Display.present`) is drawn there while the window
  is open, at the scale the window says, stamped with the window input its
  frame answers. With no window, `renderHeadless` runs a render session of
  its own over the CPU renderer, for the headless mode. The latest
  session's journal, counters and rest are read with `renderJournal`,
  `renderCounters` and `renderResting`, after it has ended too. The process
  has one presenter, so a check binds, starts and stops what it reads.
- What the window reports is events from the window source, of the kinds
  from `windowOpened` on, pulled with `nextEvent` like any other. Each is
  stamped with the reading of the library's input clock when the window
  reported it, and `inputClock` reads the same clock.
- A key, a pointer, a resize and files to open carry their detail as the
  event's words.
  The table of codes, texts and word layouts is in the module docs of
  `crates/editor-ffi/src/window.rs`:

  | Kind | Code | Words |
  |---|---|---|
  | `key` | Bit 0 pressed, bit 1 repeat, bit 2 dead, bit 3 the interrupt mark ("The interrupt flag") | `[logical tag, n, n scalars, physical tag, m, m scalars, modifiers]`; logical 0 unidentified, 1 character, 2 named (a W3C UI Events `key` name), 3 dead (n is 0 or 1); physical 0 unidentified, 1 a W3C UI Events `code` |
  | `pointer` | 0 press, 1 drag, 2 release, 3 wheel | `[x, y, button tag, other, modifiers, delta tag, dx, dy]`; button 0 none, 1 primary, 2 secondary, 3 middle, 4 back, 5 forward, 6 another (its number in `other`); delta 0 none, 1 lines, 2 pixels |
  | `resize` | Bit 0 in fullscreen | `[width, height, scale, corner clearance, top inset]`; the corner clearance and the top inset in whole logical points |
  | `openFiles` | 0 | `[n, then for each of the n paths: m, m scalars]`; the text is empty |
  | `quitRequested` | 0 | None, and no text: the system asked the program to quit |
  | `menu` | 0 | None; the text is the chosen item's command name |

  The modifiers are bits: shift 1, control 2, alt 4, super 8
  (`modifierBits`, `modifiersOfBits?`). A float
  crosses as its IEEE 754 bits (`Float.ofBits`). These bindings carry the
  words as they are; the one place on the Lean side that reads them is
  `Editor/Event/Queue.lean`.
- Lean closes the window. A window the user asks to close reports
  `closeRequested` and stays open until `windowClose`, which any thread may
  call.
- Lean asks things of the window with `windowRequest`: enter or leave
  fullscreen, minimise, keep running, the answer to a quit the system
  asked when the editor does not quit, or the light or the dark
  appearance of its title and buttons (`WindowRequest`, tags 0, 1, 2, 4,
  6 and 7). It never blocks, and it goes through the window's own loop,
  not the main-thread service, which still answers nothing else while the
  window runs. Whether
  the window is in fullscreen comes back on every resize, bit 0 of its
  code, how far in its rounded corners reach as its fourth word, and how
  far down its title bar covers it as its fifth. The title is no request: it is the scene's (`Scene.title`), and the
  library sends it to the window when it changes. `windowAsked` reads what
  a scripted window was asked, for tests.
- The platform is an enumeration (`Platform`). The scripted ones are the
  library's fake: they open nothing and need no display, and they are what
  every check runs. One reports a fixed sample; the other cannot open a
  window, so that a failure to open is seen to cross. The real one opens a
  window.

The editor does not run a window yet. The callers are the keyboard check
(`Editor/WindowCheck/Real.lean`, `editor window-check`), and
`Editor/Event/Queue.lean`, whose `Event.post` the headless driver sends keys
with through `postInput`. The editor's events as one Lean type are
`Editor/Event.lean`.

Tests: the window checks of `ffi-test` (`FfiTest.windowChecks`), on the
scripted platforms: the bindings, a run that fails to open and the requests
among them, and
the keyboard check's loop over them; the unit tests of `window.rs` and
`tests/window.rs`
in `editor-ffi`, which need no Lean. Nothing in the gate runs the real
platform: `mise run window-check` and `mise run window-contract` do, on
demand.

### The interrupt flag

The library raises a flag as the interrupt key arrives on the editor queue,
before the key is queued, so that a command that holds the editor thread can
be asked to stop. The primitive is the library's
(`crates/editor-ffi/src/interrupt.rs`); the policy is Lean's
(`Editor/Watch.lean`, `Editor/Loop.lean`).

- `interruptKeySet` tells the library which key raises the flag, as words:
  `[logical tag, n, n scalars, modifiers, mask]`, the logical key as in a
  key event's words, and the modifiers and the mask each a word of modifier
  bits. A press is the interrupt key when it has that logical key and, of
  the modifiers the mask names, exactly those held. The mask is how Lean's
  rule for a chord crosses: the library compares words and knows no rule.
  `interruptKeyClear` leaves it with no key. The one place on the Lean side
  that makes the words is `Editor/Event/Queue.lean` (`Event.setInterruptKey`).
- The flag is a count of the presses that have arrived and not been lowered
  for. `interruptRaised` asks whether it is up, and `interruptLower` takes
  one off. Pulling an event lowers nothing.
- The event of a press the library counted carries the interrupt mark, bit 3
  of a key event's code. `Event.ofFfi` reads it into `Received.interrupt`,
  and the loop lowers the flag for exactly those events. The mark cannot be
  posted: `postInput` refuses a code that carries it.
- None of these blocks, and each may be called from any thread.

Tests: `FfiTest.interruptChecks`, against the library;
`FfiTest.eventDecodeChecks` for the mark, on events built by hand; the
watch port's contract against its real binding in `contract-test`; the unit
tests of `interrupt.rs` and `window.rs` and `tests/interrupt.rs` in
`editor-ffi`, which need no Lean.

### Calls go one way

Lean calls the library, and the library never calls Lean: no binding hands
Rust a closure or a Lean function to call back, and the glue's wrappers call
no Lean code. What Rust has to say arrives as an event.

No test pins this rule, and nothing in the build enforces it; it is kept by
review. The crate docs of `editor-ffi` say how far the Rust build goes.

### An exception from the interpreter ends the process

Deep recursion or a missing native symbol in interpreted code makes Lean's
interpreter throw a C++ exception. A `try`/`catch` in Lean does not see it,
and nothing else catches it: a call from compiled Lean into interpreted code
is an ordinary call, with no guard around it, and the exception terminates the
process. That is deliberate. The exception skips the compiled frames between
the interpreter and whatever would catch it, and they release nothing they
hold: references leak, `finally` blocks do not run, locks stay locked. State
cannot be cleanly restored after that, so the editor does not carry on. Do not
add a guard, and do not add a C++ source to hold one.

The interpreter's stack check fires only once its thread's stack is full, so
the stack's size is how soon a runaway recursion ends. The entry point
(`editor_entry` in `ffi/glue.c`) gives every thread Lean creates a 64 MiB
stack in place of Lean's gigabyte. `threadStackSize` reads a thread's size
back.

Tests: the check of `ffi-test` that Lean's main thread, a dedicated task and
a pool task each have that stack (`FfiTest.entryChecks`), which aborts
nothing. `mise run ffi-overflow`, which runs `ffi-test overflow` and requires
it to die of SIGABRT once it has entered the recursion. It is run on demand,
not by the gate: every abort makes macOS write a crash report on the
developer's machine.

### Shutdown

`quit` makes every `nextEvent`, parked or later, return a `quit` event, so
every dedicated task blocked in a pull returns. Then end the process with
`IO.Process.exit`. Never return from `main` while a dedicated task may still
be blocked in the library: Lean waits for it, for ever.

Tests: `ffi-test shutdown` and `ffi-test exit-while-blocked`; the quit tests
of `events.rs` in `editor-ffi`.

### Nothing runs at initialisation

A module initialiser must not call the library: make library objects from
`main` or later.

No test pins this rule, and the build enforces only part of it.

- An `initialize` declaration that calls a binding fails `mise run lean`. The
  `lean` compiler runs such a declaration when it compiles a module that
  imports this one, in a process where the Rust symbols do not exist, and
  reports "Could not find native implementation of external declaration" for
  the importing module. Seen once by hand, with an `initialize` that called
  `Counter.live` here: `Main` and `FfiTest` failed to build.
- A plain constant whose value calls a binding builds. Lean evaluates it in
  the module's initialiser when the executable starts, where the symbols do
  exist, so nothing stops it. Seen once by hand, with a constant defined as
  `add 2 3`. Keeping such constants out is left to review; a list of checks
  is a function of `Unit` in `FfiTest.lean` for this reason.
-/

namespace Editor.Ffi

/-- The sum of `a` and `b`, wrapping on overflow, computed by the Rust library.
The trivial function that shows a call crossing the boundary. -/
@[extern "editor_ffi_add"]
opaque add (a b : UInt32) : UInt32

/-- Whether the calling thread is the process's main thread. Lean's `main` runs
on a thread Lean creates, so in Lean code this is `false`. -/
@[extern "editor_glue_is_main_thread"]
opaque isMainThread : IO Bool

/-- Whether work handed to the main-thread service runs on the process's main
thread. Blocks until the service has answered. `true` in an executable whose
entry point parks the main thread in the service (`editor_entry` in
`ffi/glue.c`); this is the path a window will take. -/
@[extern "editor_glue_main_thread_probe"]
opaque mainThreadProbe : IO Bool

/-- The stack size, in bytes, of the thread the entry point runs Lean's
generated `main` on, as the operating system reports it; 0 if the executable
did not start at the entry point. Module initialisers run on that thread.

This exists for `FfiTest`, which checks the entry point asked for a large
stack. The editor has no use for it. -/
@[extern "editor_glue_entry_stack_size"]
opaque entryStackSize : IO USize

/-- The stack size, in bytes, of the calling thread, as the operating system
reports it.

This exists for `FfiTest`, which checks that every thread Lean creates has the
stack the entry point sets. The editor has no use for it. -/
@[extern "editor_glue_thread_stack_size"]
opaque threadStackSize : IO USize

/-- The type behind `Counter`. It is opaque, so the only way to get a counter
is `Counter.new`. -/
opaque CounterPointed : NonemptyType

/-- A counter held by the Rust library: the example of a handle. The value is
a Lean external object, and its finaliser, run when the last reference is
dropped, is the only thing that frees the Rust object. -/
def Counter : Type :=
  CounterPointed.type

instance : Nonempty Counter :=
  CounterPointed.property

/-- A new counter starting at `start`. -/
@[extern "editor_glue_counter_new"]
opaque Counter.new (start : UInt64) : IO Counter

/-- Adds one to the counter and returns the new value, wrapping on overflow. -/
@[extern "editor_glue_counter_increment"]
opaque Counter.increment (counter : @& Counter) : IO UInt64

/-- How many counters the Rust library holds that have not been freed.

This exists for `FfiTest`, which uses it to see a counter's finaliser run. -/
@[extern "editor_glue_counter_live"]
opaque Counter.live : IO UInt64

/-- The type behind `Document`. It is opaque, so the only ways to get a
document are `Document.new` and `Document.ofSnapshot`. -/
opaque DocumentPointed : NonemptyType

/-- Text held by the Rust library, edited in place: a second handle, and the
example of a string going in and one coming back. It is the text of the
library's text storage (`crates/editor-text`) behind a lock. The text port's
real binding runs against it (`Editor/Text/Real.lean`), and the editor
reaches it only through that port. -/
def Document : Type :=
  DocumentPointed.type

instance : Nonempty Document :=
  DocumentPointed.property

/-- A new document holding `text`. -/
@[extern "editor_glue_document_new"]
opaque Document.new (text : @& String) : IO Document

/-- Replaces the bytes of the document from `start` up to, not including,
`stop` with `text`, and returns whether the library did. An empty range
inserts, and an empty `text` deletes.

`false`, with nothing changed, unless both offsets are character boundaries
of the document's text, within it, and `start ≤ stop`. -/
@[extern "editor_glue_document_replace"]
opaque Document.replace (document : @& Document) (start stop : USize) (text : @& String) : IO Bool

/-- A copy of the whole text of the document. -/
@[extern "editor_glue_document_read"]
opaque Document.read (document : @& Document) : IO String

/-- How many documents the Rust library holds that have not been freed.

This exists for tests: `FfiTest` uses it to see a document's finaliser run,
and `ContractTest` to see that the text port's table is the only holder of
its documents. -/
@[extern "editor_glue_document_live"]
opaque Document.live : IO UInt64

/-- The type behind `Snapshot`. It is opaque, so the only ways to get a
snapshot are `Document.snapshot` and a load's result (`filesTake`). -/
opaque SnapshotPointed : NonemptyType

/-- A text as it was at one moment, held by the Rust library: a third
handle. It is a document's text when the snapshot was taken, or the text of
a file the file service loaded. It never changes, whatever is done to the
document afterwards, and it stays alive after the document is freed. -/
def Snapshot : Type :=
  SnapshotPointed.type

instance : Nonempty Snapshot :=
  SnapshotPointed.property

/-- A snapshot of the document's text as it is now. It copies none of the
text. -/
@[extern "editor_glue_document_snapshot"]
opaque Document.snapshot (document : @& Document) : IO Snapshot

/-- What a snapshot is, as the glue builds it in one call: `UInt64` fields
only, so the order here is the layout the glue writes. -/
structure SnapshotInfo where
  /-- The revision of its document the snapshot holds: how many edits the
  document had accepted when the snapshot was taken. -/
  revision : UInt64
  /-- The length of the text in bytes. -/
  byteLength : UInt64
  /-- How many rows the text has: one more than its line feeds. -/
  rowCount : UInt64
  deriving DecidableEq, Repr, Inhabited

/-- The revision, the length in bytes and the row count of the snapshot. -/
@[extern "editor_glue_snapshot_info"]
opaque Snapshot.info (snapshot : @& Snapshot) : IO SnapshotInfo

/-- A copy of the whole text of the snapshot. -/
@[extern "editor_glue_snapshot_read"]
opaque Snapshot.read (snapshot : @& Snapshot) : IO String

/-- The unit a point's column is counted in. -/
inductive ColumnUnit where
  /-- Bytes of UTF-8. -/
  | bytes
  /-- UTF-16 code units. -/
  | utf16
  /-- Cells: how many cells of the row start before the position. A cell is
  one character, or a carriage return and the line feed after it together. -/
  | cells
  deriving DecidableEq, Repr

/-- A row and a column of a text, as the glue builds it: `UInt64` fields
only, so the order here is the layout the glue writes. The unit of the column
is the one the binding that returned the point was asked for. -/
structure Point where
  /-- Which row, from 0. A row begins after each line feed. -/
  row : UInt64
  /-- How far into the row. -/
  column : UInt64
  deriving DecidableEq, Repr

/-- The row and the column of the byte offset `offset` of the snapshot, with
the column counted in `unit`. `none` unless the offset is a position of the
text: within it, and not inside a character. -/
@[extern "editor_glue_snapshot_point_of"]
opaque Snapshot.pointOf (snapshot : @& Snapshot) (unit : ColumnUnit) (offset : USize) :
    IO (Option Point)

/-- The byte offset of the point `row`, `column` of the snapshot, with the
column counted in `unit`. `none` unless the point names a position of the
text: a row the text has, and a column within the row that is not inside a
character. -/
@[extern "editor_glue_snapshot_offset_of"]
opaque Snapshot.offsetOf (snapshot : @& Snapshot) (unit : ColumnUnit) (row column : UInt64) :
    IO (Option UInt64)

/-- Which words a motion goes by. -/
inductive WordKind where
  /-- Words: a longest run of word characters, or of punctuation. -/
  | word
  /-- WORDs: a longest run of characters that are not blank. -/
  | bigWord
  deriving DecidableEq, Repr

/-- A motion of the library: a way from one position of a text to another.
What each answers is the library's rule (`crates/editor-text`, `Motion`). A
count and a column are words: the library reads the largest as past any
text's rows or cells. -/
inductive Motion where
  /-- The first cell start after the position, or the end of the text. -/
  | nextCell
  /-- The last cell start before the position, or 0. -/
  | previousCell
  /-- The first start of a word of `kind` after the position, or the end of
  the text. -/
  | nextWordStart (kind : WordKind)
  /-- The first end of a word of `kind` after the position, empty lines not
  counted, or the end of the text. -/
  | nextWordEnd (kind : WordKind)
  /-- The last start of a word of `kind` before the position, or 0. -/
  | previousWordStart (kind : WordKind)
  /-- The last end of a word of `kind` before the position, or 0. -/
  | previousWordEnd (kind : WordKind)
  /-- Where the position's row starts. -/
  | lineStart
  /-- Where the content of the position's row ends. -/
  | lineEnd
  /-- The first position of the row's content whose character is not a
  blank, or where the content ends. -/
  | lineFirstNonBlank
  /-- The start of the text. -/
  | textStart
  /-- The end of the text. -/
  | textEnd
  /-- The position `column` cells into the row `count` rows up, or the
  first row. -/
  | rowsUp (count column : UInt64)
  /-- The position `column` cells into the row `count` rows down, or the
  last row. -/
  | rowsDown (count column : UInt64)
  deriving DecidableEq, Repr

/-- A motion as it crosses: its tag, and the count and the column of a
motion by rows, which are 0 for every other. The table of tags is in the
module docs of `crates/editor-ffi/src/motion.rs`, which checks the tag. -/
private def Motion.encode : Motion → UInt8 × UInt64 × UInt64
  | .nextCell => (0, 0, 0)
  | .previousCell => (1, 0, 0)
  | .nextWordStart .word => (2, 0, 0)
  | .nextWordEnd .word => (3, 0, 0)
  | .previousWordStart .word => (4, 0, 0)
  | .previousWordEnd .word => (5, 0, 0)
  | .nextWordStart .bigWord => (6, 0, 0)
  | .nextWordEnd .bigWord => (7, 0, 0)
  | .previousWordStart .bigWord => (8, 0, 0)
  | .previousWordEnd .bigWord => (9, 0, 0)
  | .lineStart => (10, 0, 0)
  | .lineEnd => (11, 0, 0)
  | .lineFirstNonBlank => (12, 0, 0)
  | .textStart => (13, 0, 0)
  | .textEnd => (14, 0, 0)
  | .rowsUp count column => (15, count, column)
  | .rowsDown count column => (16, count, column)

/-- `Snapshot.motion` as it crosses: the motion as a tag, a count and a
column. -/
@[extern "editor_glue_snapshot_motion"]
private opaque Snapshot.motionRaw (snapshot : @& Snapshot) (tag : UInt8) (count column : UInt64)
    (offset : USize) : IO (Option UInt64)

/-- Where `motion` leads from the byte offset `offset` of the snapshot.
`none` unless the offset is a position of the text: within it, and not inside
a character. -/
def Snapshot.motion (snapshot : Snapshot) (motion : Motion) (offset : USize) : IO (Option UInt64) :=
  let (tag, count, column) := motion.encode
  snapshot.motionRaw tag count column offset

/-- A copy of the content of the row `row` of the snapshot: the row without
its line break. `none` when the text has no such row. It reads that row and
no more of the text. -/
@[extern "editor_glue_snapshot_row"]
opaque Snapshot.row (snapshot : @& Snapshot) (row : UInt64) : IO (Option String)

/-- A copy of the snapshot's text from the byte offset `start` up to, not
including, `stop`. `none` unless both are positions of the text and
`start ≤ stop`. It reads that range and no more of the text. -/
@[extern "editor_glue_snapshot_slice"]
opaque Snapshot.slice (snapshot : @& Snapshot) (start stop : USize) : IO (Option String)

/-- How many snapshots the Rust library holds that have not been freed.

This exists for tests: `FfiTest` uses it to see a snapshot's finaliser run,
and `ContractTest` to see that the text port's table is the only holder of
its snapshots. -/
@[extern "editor_glue_snapshot_live"]
opaque Snapshot.live : IO UInt64

/-- One step of a change set's walk over a document's text, with its length
in bytes. -/
inductive Change where
  /-- Keep the next `count` bytes. -/
  | retain (count : UInt64)
  /-- Remove the next `count` bytes. -/
  | delete (count : UInt64)
  /-- Put `text` in at this point. -/
  | insert (text : String)
  deriving DecidableEq, Repr

/-- One range of a selection: two byte offsets. -/
structure SelectionRange where
  /-- The end that stays when the selection is extended. -/
  anchor : UInt64
  /-- The end that moves. -/
  head : UInt64
  deriving DecidableEq, Repr

/-- What the ranges of a selection cover, given their two ends. -/
inductive Shape where
  /-- From the lower end up to, not including, the higher. -/
  | exclusive
  /-- From the lower end through the character at the higher. -/
  | inclusive
  /-- The whole rows of both ends and those between them. -/
  | line
  /-- A rectangle of characters whose corners are the two ends. -/
  | block
  deriving DecidableEq, Repr

/-- The ranges of a selection, which of them is the primary one, and the
shape they all have. The library sorts the ranges and makes those that
overlap one. -/
structure Selection where
  /-- The ranges, in any order. -/
  ranges : Array SelectionRange
  /-- The index in `ranges` of the primary range. -/
  primary : UInt64 := 0
  /-- What the ranges cover. -/
  shape : Shape := .exclusive
  deriving DecidableEq, Repr

/-- A transaction, as plain data: the changes to make to a document's text,
and optionally the selection before them and the selection after them. -/
structure Transaction where
  /-- The changes, which walk the text from its start to its end. -/
  changes : Array Change
  /-- The selection in the text before the changes. -/
  before : Option Selection := none
  /-- The selection in the text after the changes. -/
  after : Option Selection := none
  deriving DecidableEq, Repr

/-- Why the library refused a transaction. -/
inductive ApplyRefusal where
  /-- The changes do not fit the text: they are for another length, or a
  boundary between two of them is inside a character. -/
  | badChange
  /-- A selection has no range, its primary names none, or an end of one of
  its ranges is not a position of its text. -/
  | badSelection
  deriving DecidableEq, Repr

/-- `words` with `word` added: its eight bytes, least significant first. -/
private def pushWord (words : ByteArray) (word : UInt64) : ByteArray :=
  (List.range 8).foldl (fun words byte => words.push (word >>> (8 * byte).toUInt64).toUInt8) words

/-- The shape as a word: 0 exclusive, 1 inclusive, 2 line-wise, 3
block-wise. -/
private def Shape.word : Shape → UInt64
  | .exclusive => 0
  | .inclusive => 1
  | .line => 2
  | .block => 3

/-- The words of a selection: its shape, its primary, its count of ranges,
and an anchor and a head for each. -/
private def pushShaped (words : ByteArray) (selection : Selection) : ByteArray :=
  let words := pushWord (pushWord words selection.shape.word) selection.primary
  selection.ranges.foldl (fun words range => pushWord (pushWord words range.anchor) range.head)
    (pushWord words selection.ranges.size.toUInt64)

/-- The words of a selection block: a presence word, and for a selection its
words (`pushShaped`). -/
private def pushSelection (words : ByteArray) : Option Selection → ByteArray
  | none => pushWord words 0
  | some selection => pushShaped (pushWord words 1) selection

/-- The length of `change`, as the word that follows its kind. -/
private def Change.length : Change → UInt64
  | .retain count | .delete count => count
  | .insert text => text.utf8ByteSize.toUInt64

/-- The kind of `change`, as a word: 0 a retain, 1 a delete, 2 an insert. -/
private def Change.kind : Change → UInt64
  | .retain _ => 0
  | .delete _ => 1
  | .insert _ => 2

/-- A transaction as it crosses: its words. They are the count of changes, a
kind and a length for each, and a block for each selection. -/
private def Transaction.words (transaction : Transaction) : ByteArray :=
  let words := pushWord ByteArray.empty transaction.changes.size.toUInt64
  let words :=
    transaction.changes.foldl
      (fun words change => pushWord (pushWord words change.kind) change.length) words
  pushSelection (pushSelection words transaction.before) transaction.after

/-- Everything a transaction inserts, joined in order. An insert's length
cuts its text from it. -/
private def Transaction.inserted (transaction : Transaction) : String :=
  transaction.changes.foldl
    (fun inserted change =>
      match change with
      | .insert text => inserted ++ text
      | _ => inserted)
    ""

/-- The result of applying a transaction, as the glue builds it in one call:
`UInt64` fields only, so the order here is the layout the glue writes. -/
private structure RawApplied where
  /-- 0 applied, 1 the changes do not fit, 2 a selection does not fit, 3 the
  words could not be read. -/
  status : UInt64
  /-- The revision the transaction produced, when it was applied. -/
  revision : UInt64

/-- `Document.apply` as it crosses: the transaction as words, and what it
inserts as one string. -/
@[extern "editor_glue_document_apply"]
private opaque Document.applyRaw (document : @& Document) (words : @& ByteArray)
    (inserted : @& String) (origin : UInt64) : IO RawApplied

/-- Applies `transaction` to the document, recording `origin` as who made the
edit, and returns the revision it produced: one more than before, however
many changes it has. `origin` is a number the library stores and gives back
(`Document.trace`) and never reads.

A refused transaction changes nothing. A selection that is none (no range,
or a primary that names none) is refused first, then changes that do not
fit, then a selection with an end that is not a position of its text. A
length or an offset given as the largest `UInt64` is one no text accepts. -/
def Document.apply (document : Document) (transaction : Transaction) (origin : UInt64) :
    IO (Except ApplyRefusal UInt64) := do
  let raw ← document.applyRaw transaction.words transaction.inserted origin
  match raw.status with
  | 0 =>
    return .ok raw.revision
  | 1 =>
    return .error .badChange
  | 2 =>
    return .error .badSelection
  | status =>
    throw (IO.userError s!"the library could not read a transaction's words (status {status})")

/-- One step of an edit script, as the library takes it and a diff gives it
back (`crates/editor-ffi/src/diffs.rs`). -/
inductive ScriptStep where
  /-- Keep the next `count` bytes. -/
  | retain (count : UInt64)
  /-- Remove the next `count` bytes. -/
  | delete (count : UInt64)
  /-- Put in the `count` bytes of the new text from `start`. -/
  | insert (start count : UInt64)
  deriving DecidableEq, Repr

/-- Why the library refused an edit script. -/
inductive ScriptRefusal where
  /-- The text has moved past the revision the script was made for. -/
  | moved
  /-- The steps do not walk the whole of the text and of the source, or one
  starts or stops inside a character of either. -/
  | badChange
  deriving DecidableEq, Repr

/-- An edit script as it crosses: the count of steps, then a kind (0 a
retain, 1 a delete, 2 an insert) and two numbers for each. -/
private def scriptWords (script : Array ScriptStep) : ByteArray :=
  script.foldl
    (fun words step =>
      match step with
      | .retain count => pushWord (pushWord (pushWord words 0) count) 0
      | .delete count => pushWord (pushWord (pushWord words 1) count) 0
      | .insert start count => pushWord (pushWord (pushWord words 2) start) count)
    (pushWord ByteArray.empty script.size.toUInt64)

/-- `Document.applyScript` as it crosses: the script as words. -/
@[extern "editor_glue_document_apply_script"]
private opaque Document.applyScriptRaw (document : @& Document) (base : UInt64)
    (source : @& Snapshot) (words : @& ByteArray) (origin : UInt64) : IO RawApplied

/-- Applies the edit script `script` to the document as one transaction,
taking what it puts in from `source` and recording `origin` as who made the
edit, unless the document's revision is not `base`; and returns the revision
it produced. A refused script changes nothing: the revision is looked at
first, under the document's lock, then whether the steps fit. -/
def Document.applyScript (document : Document) (base : UInt64) (source : Snapshot)
    (script : Array ScriptStep) (origin : UInt64) : IO (Except ScriptRefusal UInt64) := do
  let raw ← document.applyScriptRaw base source (scriptWords script) origin
  match raw.status with
  | 0 =>
    return .ok raw.revision
  | 1 =>
    return .error .badChange
  | 4 =>
    return .error .moved
  | status =>
    throw (IO.userError s!"the library could not apply an edit script (status {status})")

/-- A range of one text, as byte offsets and as points with their columns in
bytes. -/
structure Span where
  /-- The offset the range starts at. -/
  start : UInt64
  /-- The offset the range stops at, not included. -/
  stop : UInt64
  /-- The point of `start`. -/
  startPoint : Point
  /-- The point of `stop`. -/
  stopPoint : Point
  deriving DecidableEq, Repr

/-- One changed range: the bytes of `old`, a range of the text before, were
replaced by the bytes of `new`, a range of the text after. -/
structure Edit where
  /-- The range that was replaced, in the text before. -/
  old : Span
  /-- The range that replaced it, in the text after. -/
  new : Span
  deriving DecidableEq, Repr

/-- What changed in a document between two of its revisions, as one set of
edits in order, no two of which overlap or touch. -/
structure Patch where
  /-- The revision the patch starts from: the old spans are ranges of the
  text then. -/
  since : UInt64
  /-- The revision the patch reaches: the new spans are ranges of the text
  then, which is the text when the patch was asked for. -/
  revision : UInt64
  /-- What changed. -/
  edits : Array Edit
  deriving DecidableEq, Repr

/-- Why the library could not say what changed since a revision. -/
inductive LogRefusal where
  /-- The document has not reached the revision. -/
  | unknownRevision
  /-- The revision is before the log's horizon: `Document.forget` dropped the
  entries that led from it. -/
  | forgotten
  deriving DecidableEq, Repr

/-- Where a piece of a document's text came from. -/
inductive Author where
  /-- The transaction that produced `revision`, applied with `origin`,
  inserted the bytes. -/
  | entry (revision origin : UInt64)
  /-- The bytes were already in the text at `revision`, which is as far back
  as the log reaches. -/
  | earlier (revision : UInt64)
  deriving DecidableEq, Repr

/-- One piece of a traced range: the bytes from `start` up to, not including,
`stop`, of the text as it is now, and where they came from. -/
structure Attribution where
  /-- The offset the piece starts at. -/
  start : UInt64
  /-- The offset the piece stops at, not included. -/
  stop : UInt64
  /-- Where its bytes came from. -/
  author : Author
  deriving DecidableEq, Repr

/-- The words `bytes` holds, eight bytes each, least significant first.
`none` unless its size is whole words. -/
private def wordsOf? (bytes : ByteArray) : Option (Array UInt64) :=
  if bytes.size % 8 != 0 then none
  else
    some <|
      (Array.range (bytes.size / 8)).map fun index =>
        (List.range 8).foldr
          (fun byte word => (word <<< 8) ||| (bytes.get! (8 * index + byte)).toUInt64) 0

/-- The span six words spell, from the index `first`: its offsets, then its
points. -/
private def spanAt (words : Array UInt64) (first : Nat) : Span where
  start := words[first]!
  stop := words[first + 1]!
  startPoint := { row := words[first + 2]!, column := words[first + 3]! }
  stopPoint := { row := words[first + 4]!, column := words[first + 5]! }

/-- The patch `words` spell: the two revisions, the count of edits, and
twelve words an edit. `none` unless the count is the count of edits there. -/
private def patchOf? (words : Array UInt64) : Option Patch := do
  let count := (← words[2]?).toNat
  guard (words.size == 3 + 12 * count)
  return {
      since := ← words[0]?
      revision := ← words[1]?
      edits :=
        (Array.range count).map fun edit =>
          { old := spanAt words (3 + 12 * edit), new := spanAt words (3 + 12 * edit + 6) } }

/-- The piece five words spell, from the index `first`. `none` when the word
that says who wrote it is neither 0 nor 1. -/
private def attributionAt? (words : Array UInt64) (first : Nat) : Option Attribution := do
  let author ←
    match words[first + 2]! with
    | 0 =>
      some (Author.earlier words[first + 3]!)
    | 1 =>
      some (Author.entry words[first + 3]! words[first + 4]!)
    | _ =>
      none
  return { start := words[first]!, stop := words[first + 1]!, author }

/-- The trace `words` spell: the count of pieces, and five words a piece.
`none` unless the count is the count of pieces there. -/
private def traceOf? (words : Array UInt64) : Option (Array Attribution) := do
  let count := (← words[0]?).toNat
  guard (words.size == 1 + 5 * count)
  (Array.range count).mapM fun piece => attributionAt? words (1 + 5 * piece)

/-- An answer in words, as the glue builds it in one call: the object field
first and the `UInt64` field after it, so the order here is the layout the
glue writes. -/
private structure RawWords where
  /-- The words, copied from the library's buffer. -/
  words : ByteArray
  /-- 0 answered, and otherwise the refusal of the call that filled it: for
  the log's, 1 the revision is unknown and 2 it is forgotten; for a marker's
  and for extents, the status `markRefusal` reads; for an inverse's, 1 the
  revision is unknown, 2 no inverse is kept and 3 the text is not in the
  state. -/
  status : UInt64

/-- `Document.changesSince` as it crosses. -/
@[extern "editor_glue_document_changes_since"]
private opaque Document.changesSinceRaw (document : @& Document) (revision : UInt64) : IO RawWords

/-- What changed in the document since `revision`, as one patch: however many
transactions were applied since, their changes come back as one set of edits.
Text inserted and deleted again in between is in none of them. Empty when
`revision` is the document's revision now.

A consumer that wants to follow a document keeps the revision of the last
patch it got and asks again from there: nothing is registered with the
library. -/
def Document.changesSince (document : Document) (revision : UInt64) :
    IO (Except LogRefusal Patch) := do
  let raw ← document.changesSinceRaw revision
  match raw.status with
  | 0 =>
    match (wordsOf? raw.words).bind patchOf? with
    | some patch =>
      return .ok patch
    | none =>
      throw (IO.userError "the library's words do not spell a patch")
  | 1 =>
    return .error .unknownRevision
  | 2 =>
    return .error .forgotten
  | status =>
    throw (IO.userError s!"the library reported an unknown log status ({status})")

/-- `Document.trace` as it crosses: the words, when the library gave any. -/
@[extern "editor_glue_document_trace"]
private opaque Document.traceRaw (document : @& Document) (start stop : USize) :
    IO (Option ByteArray)

/-- Where the bytes of the document from `start` up to, not including, `stop`
came from: the range cut into pieces, in order, each with the revision and
the origin of the transaction that inserted it, or as earlier than the log
reaches. `none` unless both offsets are positions of the text and
`start ≤ stop`. -/
def Document.trace (document : Document) (start stop : USize) : IO (Option (Array Attribution)) :=
  do
  let some words ← document.traceRaw start stop | return none
  match (wordsOf? words).bind traceOf? with
  | some trace =>
    return some trace
  | none =>
    throw (IO.userError "the library's words do not spell a trace")

/-- Drops the entries of the document's log up to `revision`, and returns
whether the library did. Afterwards `changesSince` an earlier revision is
refused as forgotten, and `trace` names older bytes as earlier than
`revision`. The text is untouched.

`false`, with nothing changed, for a revision the document has not
reached. -/
@[extern "editor_glue_document_forget"]
opaque Document.forget (document : @& Document) (revision : UInt64) : IO Bool

/-- A range of byte offsets into text: from `start` up to, not including,
`stop`. -/
structure ByteRange where
  /-- The offset of the first byte. -/
  start : UInt64
  /-- The offset one past the last byte. -/
  stop : UInt64
  deriving DecidableEq, Repr

/-- `find` as it crosses: the option on the way in is a flag and a value, and
the glue builds the option on the way out. -/
@[extern "editor_glue_text_find"]
private opaque findRaw (haystack needle : @& String) (hasStart : Bool) (start : USize) :
    Option ByteRange

/-- The byte range of the first occurrence of `needle` in `haystack` at or
after the byte offset `start` (the beginning, if `none`). `none` when there is
no such occurrence, and when `start` is past the end of `haystack` or inside a
character. -/
def find (haystack needle : String) (start : Option USize := none) : Option ByteRange :=
  match start with
  | none => findRaw haystack needle false 0
  | some start => findRaw haystack needle true start

/-- Which side of text inserted at an anchor the anchor stays on. -/
inductive Bias where
  /-- The anchor stays before the inserted text. -/
  | before
  /-- The anchor goes after the inserted text. -/
  | after
  deriving DecidableEq, Repr

/-- A position in a document's text that the library moves with every
transaction: a byte offset and a bias. -/
structure Anchor where
  /-- Where the anchor is. -/
  offset : UInt64
  /-- Which side of text inserted at the anchor it stays on. -/
  bias : Bias
  deriving DecidableEq, Repr

/-- Something a document holds and moves with every transaction it accepts. -/
inductive Marker where
  /-- One position. -/
  | anchor (anchor : Anchor)
  /-- A selection. Read back, its ranges are sorted and those that overlapped
  are one. -/
  | selection (selection : Selection)
  deriving DecidableEq, Repr

/-- Why the library refused a marker. -/
inductive MarkRefusal where
  /-- The anchor's offset is not a position of the text. -/
  | badPosition
  /-- The selection has no range, its primary names none, or an end of one of
  its ranges is not a position of the text. -/
  | badSelection
  /-- The document holds no marker with that id. -/
  | noSuchMarker
  deriving DecidableEq, Repr

/-- A marker as it crosses: its words. An anchor is 0, its offset and its
bias (0 before, 1 after); a selection is 1 and its words (`pushShaped`). -/
private def Marker.words : Marker → ByteArray
  | .anchor position =>
    let bias : UInt64 :=
      match position.bias with
      | .before => 0
      | .after => 1
    pushWord (pushWord (pushWord ByteArray.empty 0) position.offset) bias
  | .selection ranges => pushShaped (pushWord ByteArray.empty 1) ranges

/-- The shape a word stands for. `none` for a word that is none of the
four. -/
private def Shape.ofWord? : UInt64 → Option Shape
  | 0 => some .exclusive
  | 1 => some .inclusive
  | 2 => some .line
  | 3 => some .block
  | _ => none

/-- The selection the words from the index `first` to the last spell, in the
layout of `pushShaped`: its shape, its primary, its count of ranges, and an
anchor and a head for each. `none` when they spell none, or the count is not
the count of ranges there. -/
private def selectionAt? (words : Array UInt64) (first : Nat) : Option Selection := do
  let shape ← Shape.ofWord? (← words[first]?)
  let count := (← words[first + 2]?).toNat
  guard (words.size == first + 3 + 2 * count)
  return {
      ranges :=
        (Array.range count).map fun range =>
          { anchor := words[first + 3 + 2 * range]!, head := words[first + 3 + 2 * range + 1]! }
      primary := ← words[first + 1]?
      shape }

/-- The marker `words` spell, in the layout of `Marker.words`. `none` when
they spell none. -/
private def markerOf? (words : Array UInt64) : Option Marker := do
  let kind : UInt64 ← words[0]?
  match kind with
  | 0 =>
    guard (words.size == 3)
    let side : UInt64 ← words[2]?
    let bias ←
      match side with
      | 0 =>
        some Bias.before
      | 1 =>
        some Bias.after
      | _ =>
        none
    return .anchor { offset := ← words[1]?, bias }
  | 1 =>
    return .selection (← selectionAt? words 1)
  | _ =>
    none

/-- The extents `words` spell: their count, and a start and a stop for each.
`none` unless the count is the count of extents there. -/
private def extentsOf? (words : Array UInt64) : Option (Array ByteRange) := do
  let count := (← words[0]?).toNat
  guard (words.size == 1 + 2 * count)
  return (Array.range count).map fun extent =>
      { start := words[1 + 2 * extent]!, stop := words[1 + 2 * extent + 1]! }

/-- The refusal a status of the library's stands for: 1 a bad position, 2 a
bad selection, 4 no such marker. An error for any other status, 3 among them:
words the library could not read are a fault of this file's, not a
refusal. -/
private def markRefusal (status : UInt64) : IO MarkRefusal :=
  match status with
  | 1 => return .badPosition
  | 2 => return .badSelection
  | 4 => return .noSuchMarker
  | status => throw (IO.userError s!"the library could not read a marker's words (status {status})")

/-- The result of marking a document, as the glue builds it in one call:
`UInt64` fields only, so the order here is the layout the glue writes. -/
private structure RawMarked where
  /-- 0 marked, and otherwise the status of the refusal (`markRefusal`). -/
  status : UInt64
  /-- The id of the new marker, when it was marked. -/
  id : UInt64

/-- `Document.mark` as it crosses: the marker as words. -/
@[extern "editor_glue_document_mark"]
private opaque Document.markRaw (document : @& Document) (words : @& ByteArray) : IO RawMarked

/-- Has the document hold `marker`, and returns the id it is read back by.
From now on every transaction the document accepts moves the marker, until
it is given up (`Document.unmark`). The library never gives an id out twice.

Refused, holding nothing, unless the marker is in the text as it is now: an
anchor's offset is a position, and every end of every range of a selection
is one. An offset given as the largest `UInt64` is one no text accepts. -/
def Document.mark (document : Document) (marker : Marker) : IO (Except MarkRefusal UInt64) := do
  let raw ← document.markRaw marker.words
  if raw.status == 0 then
    return .ok raw.id
  else
    return .error (← markRefusal raw.status)

/-- `Document.marker` as it crosses: the marker's words, with the status 0,
or no words and the status 4. -/
@[extern "editor_glue_document_marker"]
private opaque Document.markerRaw (document : @& Document) (id : UInt64) : IO RawWords

/-- The marker with the id `id`, where it is in the document's text as it is
now. `none` when the document holds no such marker. -/
def Document.marker (document : Document) (id : UInt64) : IO (Option Marker) := do
  let raw ← document.markerRaw id
  if raw.status != 0 then
    return none
  match (wordsOf? raw.words).bind markerOf? with
  | some marker =>
    return some marker
  | none =>
    throw (IO.userError "the library's words do not spell a marker")

/-- `Document.place` as it crosses: the marker as words, and the status that
comes back. -/
@[extern "editor_glue_document_place"]
private opaque Document.placeRaw (document : @& Document) (id : UInt64) (words : @& ByteArray) :
    IO UInt64

/-- Puts `marker` in place of the marker with the id `id`, which keeps its
id. A refused place changes nothing. A selection that is none (no range, or
a primary that names none) is refused first, then an id the document holds
no marker for, then a marker that is not in the text. -/
def Document.place (document : Document) (id : UInt64) (marker : Marker) :
    IO (Except MarkRefusal Unit) := do
  let status ← document.placeRaw id marker.words
  if status == 0 then
    return .ok ()
  else
    return .error (← markRefusal status)

/-- Gives up the marker with the id `id`, and returns whether the document
held one. The id names nothing from then on. -/
@[extern "editor_glue_document_unmark"]
opaque Document.unmark (document : @& Document) (id : UInt64) : IO Bool

/-- `Snapshot.extents` as it crosses: the selection as words, and the extents
as words with the status 0, or no words and the status of the refusal. -/
@[extern "editor_glue_snapshot_extents"]
private opaque Snapshot.extentsRaw (snapshot : @& Snapshot) (words : @& ByteArray) : IO RawWords

/-- The ranges of bytes `selection` covers in the snapshot's text, by its
shape, sorted, with those that overlap made one. `none` when the selection
is none (no range, or a primary that names none) or an end of one of its
ranges is not a position of the text. -/
def Snapshot.extents (snapshot : Snapshot) (selection : Selection) :
    IO (Option (Array ByteRange)) := do
  let raw ← snapshot.extentsRaw (pushShaped ByteArray.empty selection)
  match raw.status with
  | 0 =>
    match (wordsOf? raw.words).bind extentsOf? with
    | some extents =>
      return some extents
    | none =>
      throw (IO.userError "the library's words do not spell extents")
  | 2 =>
    return none
  | status =>
    throw (IO.userError s!"the library could not read a selection's words (status {status})")

/-- What applying the inverse of a run of revisions did. -/
structure Inverted where
  /-- The revision the inverse produced. -/
  revision : UInt64
  /-- The selection in force before the run: the selection before that the
  run's first transaction carried, in the text as the inverse left it. `none`
  when that transaction carried none. -/
  selection : Option Selection
  deriving DecidableEq, Repr

/-- Why the library refused the inverse of a run. -/
inductive InverseRefusal where
  /-- The document has not reached a revision of the run. -/
  | unknownRevision
  /-- The document keeps no inverse for a revision of the run: the run starts
  at revision 0, its first revision is after its last, or one of its inverses
  was dropped. -/
  | noInverse
  /-- The document's text is not in the state the run ended in. -/
  | notInState
  deriving DecidableEq, Repr

/-- The inverted result `words` spell: the revision, a presence word, and for
a selection its words (`selectionAt?`). `none` when they spell none. -/
private def invertedOf? (words : Array UInt64) : Option Inverted := do
  let revision ← words[0]?
  let present : UInt64 ← words[1]?
  match present with
  | 0 =>
    guard (words.size == 2)
    return { revision, selection := none }
  | 1 =>
    return { revision, selection := some (← selectionAt? words 2) }
  | _ =>
    none

/-- `Document.applyInverse` as it crosses: the run and the origin as numbers,
and the inverted result as words with the status 0, or no words and the
status of the refusal. -/
@[extern "editor_glue_document_apply_inverse"]
private opaque Document.applyInverseRaw (document : @& Document) (first last origin : UInt64) :
    IO RawWords

/-- Applies to the document the inverse of the run of revisions from `first`
to `last`, both included, as one transaction, recording `origin` as who made
the edit: the document holds again what it held before the transaction that
produced `first`. It is one more revision and one entry of the log, like any
transaction, and its own inverse is kept, so the inverse of the revision this
returns takes it back.

A refused inverse changes nothing. A run that names a revision the document
has not reached is refused first, then a run the document keeps no inverse
for, then a run the text is not in the state at the end of: the text is there
just after the run, and again whenever inverses have brought it back, and
not when it merely reads the same. A revision given as the largest `UInt64`
is one no document has reached. -/
def Document.applyInverse (document : Document) (first last origin : UInt64) :
    IO (Except InverseRefusal Inverted) := do
  let raw ← document.applyInverseRaw first last origin
  match raw.status with
  | 0 =>
    match (wordsOf? raw.words).bind invertedOf? with
    | some inverted =>
      return .ok inverted
    | none =>
      throw (IO.userError "the library's words do not spell an inverted result")
  | 1 =>
    return .error .unknownRevision
  | 2 =>
    return .error .noInverse
  | 3 =>
    return .error .notInState
  | status =>
    throw (IO.userError s!"the library reported an unknown inverse status ({status})")

/-- Drops the document's kept inverses for the revisions from `first` to
`last`, and returns whether the library did. Afterwards the inverse of a run
that names one of them is refused. The text and its log are untouched; a
revision with no inverse kept is passed over.

`false`, with nothing dropped, for a `last` the document has not reached. -/
@[extern "editor_glue_document_drop_inverses"]
opaque Document.dropInverses (document : @& Document) (first last : UInt64) : IO Bool

/-- Which of the process's two event queues. -/
inductive Queue where
  /-- The editor queue: input and events for the editor thread. -/
  | editor
  /-- The completion queue: results of service requests, pulled by a dedicated
  task. -/
  | completion
  deriving DecidableEq, Repr

/-- What an event says happened. -/
inductive EventKind where
  /-- The queue has been quit: the task pulling from it must return. -/
  | quit
  /-- A message with no meaning to the library: its code and text are whatever
  the source chose. -/
  | message
  /-- A service request has finished: the event's code is the id the request
  was made with. -/
  | completion
  /-- A window is open: the event's text is the name the platform gives
  itself. This and the kinds after it come from a window. -/
  | windowOpened
  /-- The window gained the keyboard focus (code 1) or lost it (code 0). -/
  | windowFocus
  /-- A key was pressed or released. Bit 0 of the code is set for a press,
  bit 1 for a press repeated because the key is held, and bit 2 for a dead
  key; the text is what the key produced, or empty; the words are which key
  it was and the modifiers held ("The window" in the module docs). -/
  | key
  /-- A step of an input method's composition. The code is 0 when the input
  method became available, 1 for a change of the text being composed, 2 when
  the composition ended with a text, and 3 when the input method is no longer
  available; the text is the text composed or committed. -/
  | composition
  /-- The pointer did something in the window. The code is 0 for a press, 1
  for a drag, 2 for a release and 3 for a wheel; the words are where, with
  which button, with which modifiers, and the wheel's delta. -/
  | pointer
  /-- The user asked for the window to be closed. It stays open until Lean
  closes it. -/
  | closeRequested
  /-- The window's drawable area changed size, or its scale factor did. The
  code is 0; the words are the new width, height and scale. -/
  | resize
  /-- The system asked for files to be opened. The code is 0 and the text
  empty; the words are the paths: their count, then each path's count of
  characters and its characters ("The window" in the module docs). -/
  | openFiles
  /-- The system asked the program to quit: Command-Q, Quit from the Dock,
  a logout, restart or shutdown. The code is 0, and there is no text and no
  word. -/
  | quitRequested
  /-- A command item of the menu bar was chosen. The code is 0, the text
  the command's name, and there is no word. -/
  | menu
  /-- A parse of a highlighted document was delivered, from the library's
  syntax service: the next scene draws with it. The code is 0, and there is
  no text and no word. -/
  | parsed
  deriving DecidableEq, Repr

/-- The kind the library's number `tag` stands for, if it is one. -/
def EventKind.ofTag? : UInt64 → Option EventKind
  | 0 => some .quit
  | 1 => some .message
  | 2 => some .completion
  | 3 => some .windowOpened
  | 4 => some .windowFocus
  | 5 => some .key
  | 6 => some .composition
  | 7 => some .pointer
  | 8 => some .closeRequested
  | 9 => some .resize
  | 10 => some .openFiles
  | 11 => some .quitRequested
  | 12 => some .menu
  | 13 => some .parsed
  | _ => none

/-- What kind of thing an event came from. -/
inductive SourceKind where
  /-- The Rust library itself. -/
  | library
  /-- Lean code, through `postEvent`. -/
  | lean
  /-- The library's scripted source, a fake for tests. -/
  | script
  /-- A window; the source's id is the window's number. -/
  | window
  deriving DecidableEq, Repr

/-- The kind the library's number `tag` stands for, if it is one. -/
def SourceKind.ofTag? : UInt64 → Option SourceKind
  | 0 => some .library
  | 1 => some .lean
  | 2 => some .script
  | 3 => some .window
  | _ => none

/-- Where an event came from. -/
structure Source where
  /-- The kind of source. -/
  kind : SourceKind
  /-- Which source of that kind, in numbers the source chose. -/
  id : UInt64
  deriving DecidableEq, Repr

/-- One thing the library tells Lean: plain data, tagged with its source. -/
structure Event where
  /-- Where the event came from. -/
  source : Source
  /-- What happened. -/
  kind : EventKind
  /-- A number whose meaning the kind sets. -/
  code : UInt64
  /-- Text whose meaning the kind sets. -/
  text : String
  /-- The instant the source says the event happened, in nanoseconds on the
  library's input clock, or 0 when the source does not say. Only a window
  says. -/
  stamp : UInt64
  /-- The event's detail, as words whose meaning the kind sets; empty for a
  kind that has none. -/
  words : Array UInt64 := #[]
  deriving DecidableEq, Repr

/-- An event as the glue builds it, in one call: the object fields first, then
`UInt64` fields only, so the order here is the layout the glue writes. The
kinds are still the library's numbers. -/
private structure RawEvent where
  /-- The event's text. -/
  text : String
  /-- The event's words, copied from the library's buffer. -/
  words : ByteArray
  /-- The source kind's number. -/
  sourceKind : UInt64
  /-- The source's id. -/
  sourceId : UInt64
  /-- The event kind's number. -/
  kind : UInt64
  /-- The event's code. -/
  code : UInt64
  /-- The event's stamp. -/
  stamp : UInt64
  deriving Nonempty

/-- Posts a message from the Lean source `sourceId` to `queue`. `false` when
the queue did not accept it, which is the case once the queues are quit. -/
@[extern "editor_glue_events_post"]
opaque postEvent (queue : Queue) (sourceId code : UInt64) (text : @& String) : IO Bool

/-- `nextEvent` before its kinds are decoded. -/
@[extern "editor_glue_events_next"]
private opaque nextRaw (queue : Queue) : IO RawEvent

/-- Takes the oldest event of `queue`, blocking the calling thread until there
is one. One call returns one whole event.

It blocks in Rust, so call it from a dedicated task, never from the thread
pool. It throws if the library sends a kind these bindings do not know, or
words that are not whole words. -/
def nextEvent (queue : Queue) : IO Event := do
  let raw ← nextRaw queue
  let some sourceKind := SourceKind.ofTag? raw.sourceKind
    | throw <| IO.userError s!"the library sent an event from the unknown source kind {raw.sourceKind}"
  let some kind := EventKind.ofTag? raw.kind
    | throw <| IO.userError s!"the library sent an event of the unknown kind {raw.kind}"
  let some words := wordsOf? raw.words
    | throw <| IO.userError s!"the library sent an event whose {raw.words.size} bytes of words are not whole words"
  return { source := { kind := sourceKind, id := raw.sourceId }, kind, code := raw.code,
           text := raw.text, stamp := raw.stamp, words }

/-- Quits both queues, for good. Events already queued are still delivered;
after them every `nextEvent`, parked or later, returns a `quit` event at once,
and `postEvent` is refused.

This is the first step of shutdown: it lets every dedicated task parked in
`nextEvent` return. The second is `IO.Process.exit`. -/
@[extern "editor_glue_events_quit"]
opaque quit : IO Unit

/-- How many pulls are parked on `queue`. A readout for tests, which use it to
know a pull is parked before they post. -/
@[extern "editor_glue_events_waiting"]
opaque waiting (queue : Queue) : IO UInt64

/-- How many events `queue` holds that have not been pulled. A readout for
tests, which drain the `parsed` events a highlighted document's parses
leave on the editor queue without parking a pull on an empty queue. -/
@[extern "editor_glue_events_queued"]
opaque queued (queue : Queue) : IO UInt64

/-- Has the library's scripted source, a fake for tests, feed `queue` from a
new Rust thread: `count` messages from the script source `sourceId`, with the
codes 0, 1, 2 and so on. `false` when the thread could not be started. -/
@[extern "editor_glue_events_script_feed"]
opaque feedScript (queue : Queue) (sourceId count : UInt64) : IO Bool

/-- The time on the library's timer clock, in milliseconds since the clock
began. It never goes back. -/
@[extern "editor_glue_timers_now"]
opaque timersNow : IO UInt64

/-- Asks the library's timer service to complete the request `id` once its
clock reads `deadline` or later, and returns whether it was accepted. It
returns at once. The completion is a `completion` event on the completion
queue whose code is `id`; there is none if the request is cancelled first.

`false`, with nothing started, if `id` is already waiting or the service
could not start its thread. -/
@[extern "editor_glue_timers_start"]
opaque timersStart (id deadline : UInt64) : IO Bool

/-- Withdraws the timer request `id`, and returns whether it was waiting. It
is safe for an id that is unknown or already completed. A completion that
was already queued still arrives. -/
@[extern "editor_glue_timers_cancel"]
opaque timersCancel (id : UInt64) : IO Bool

/-- How many timer requests are waiting. A readout for tests, which use it to
see that a request reached the service and that a cancel removed it. -/
@[extern "editor_glue_timers_pending"]
opaque timersPending : IO UInt64

/-- A new document holding what `snapshot` holds: a text of its own, at
revision 0, with an empty log, no markers and no kept inverses, whatever the
snapshot's revision. It copies none of the text. An edit to it changes
neither the snapshot nor the document the snapshot was taken from, and it
outlives both. -/
@[extern "editor_glue_document_from_snapshot"]
opaque Document.ofSnapshot (snapshot : @& Snapshot) : IO Document

/-- What the file service compares to tell whether a file changed: when it
was last modified and how long it is. Two stamps are compared for equality
and never ordered. -/
structure FileStamp where
  /-- Whole seconds since the Unix epoch; negative before 1970. -/
  seconds : Int
  /-- The nanoseconds beyond `seconds`. -/
  nanoseconds : UInt64
  /-- The file's length in bytes. -/
  size : UInt64
  deriving DecidableEq, Repr

/-- What a save expects to find at its path. -/
inductive FileExpect where
  /-- Anything, or nothing: the save checks nothing. -/
  | whatever
  /-- No file. -/
  | absent
  /-- The file with this stamp: the one a load or the last save returned. -/
  | unchanged (stamp : FileStamp)
  deriving DecidableEq, Repr

/-- Why the file service refused a load or a save. -/
inductive FileRefusal where
  /-- The path is not absolute. -/
  | relativePath
  /-- Nothing is at the path, or at a directory on the way to it. -/
  | notFound
  /-- What is at the path is not a file. -/
  | notAFile
  /-- The file system does not allow it; `detail` is the platform's words. -/
  | denied (detail : String)
  /-- The file is binary: its first NUL byte is at `offset`. -/
  | binary (offset : UInt64)
  /-- The file is `size` bytes long, over the `limit` the load was given. -/
  | tooLarge (size limit : UInt64)
  /-- The file on disk is not the one the save expected: `found` is its
  stamp now, or `none` when there is no file. -/
  | changed (found : Option FileStamp)
  /-- No name was free for the save's temporary file. -/
  | noTemporaryName
  /-- Anything else; `detail` says what. -/
  | failed (detail : String)
  deriving DecidableEq, Repr

/-- What a file request came to. -/
inductive FileResult where
  /-- A file was loaded: its text as a snapshot, the stamp a save is to
  expect if the file has not changed, and how many line feeds stand alone
  and how many follow a carriage return. -/
  | loaded (snapshot : Snapshot) (stamp : FileStamp) (lineFeeds crlfs : UInt64)
  /-- A file was saved, and has this stamp. -/
  | saved (stamp : FileStamp)
  /-- A stamp was read: the file's, or `none` when nothing is there. -/
  | stamped (stamp : Option FileStamp)
  /-- The request was refused. -/
  | refused (refusal : FileRefusal)

/-- The stamp three words spell, from the index `first`: its seconds, a two's
complement word, then its nanoseconds and its size. -/
private def stampAt (words : Array UInt64) (first : Nat) : FileStamp where
  seconds := words[first]!.toInt64.toInt
  nanoseconds := words[first + 1]!
  size := words[first + 2]!

/-- The result a status, a snapshot, words and a detail spell, by the table
in the module docs of `crates/editor-ffi/src/files.rs`. An error, with what
was wrong, for a status the table does not have and for words that are not
the status's.

It is public for `FfiTest`, which decodes literal words with it; the
bindings call it from `filesTake` and nowhere else. -/
def FileResult.decode (status : UInt64) (snapshot : Option Snapshot) (words : ByteArray)
    (detail : String) : Except String FileResult := do
  let some words := wordsOf? words | throw "its words are not whole words"
  match status, words.size, snapshot with
  | 0, 5, some snapshot =>
    return .loaded snapshot (stampAt words 0) words[3]! words[4]!
  | 0, 3, none =>
    return .saved (stampAt words 0)
  | 0, 4, none =>
    match words[0]! with
    | 0 =>
      return .stamped none
    | 1 =>
      return .stamped (some (stampAt words 1))
    | present =>
      throw s!"a stamped file is present or not, and the word says {present}"
  | 1, 0, none =>
    return .refused .relativePath
  | 2, 0, none =>
    return .refused .notFound
  | 3, 0, none =>
    return .refused .notAFile
  | 4, 0, none =>
    return .refused (.denied detail)
  | 5, 1, none =>
    return .refused (.binary words[0]!)
  | 6, 2, none =>
    return .refused (.tooLarge words[0]! words[1]!)
  | 7, 4, none =>
    match words[0]! with
    | 0 =>
      return .refused (.changed none)
    | 1 =>
      return .refused (.changed (some (stampAt words 1)))
    | present =>
      throw s!"a changed file is present or not, and the word says {present}"
  | 8, 0, none =>
    return .refused .noTemporaryName
  | 9, 0, none =>
    return .refused (.failed detail)
  | status, count, snapshot =>
    let handle := if snapshot.isSome then "a snapshot" else "no snapshot"
    throw s!"the status {status} with {count} words and {handle} is no file result"

/-- Asks the library's file service to load the file at `path`, unless it is
longer than `limit` bytes, as the request `id`, and returns whether it was
accepted. It returns at once. The completion is a `completion` event on the
completion queue, from the library source 2, whose code is `id`; there is
none if the request is cancelled first. The result is then taken with
`filesTake`.

The path crosses as its bytes, with no decoding. `false`, with nothing
started, if `id` is in use or the service could not start its thread. -/
@[extern "editor_glue_files_load"]
opaque filesLoad (id : UInt64) (path : @& String) (limit : UInt64) : IO Bool

/-- Asks the library's file service for the stamp of the file at `path`, as
the request `id`, and returns whether it was accepted. It returns at once,
and nothing of the file is read. The completion and the result are as
`filesLoad`'s: the result is `stamped`, or a refusal.

`false`, with nothing started, if `id` is in use or the service could not
start its thread. -/
@[extern "editor_glue_files_stamp"]
opaque filesStamp (id : UInt64) (path : @& String) : IO Bool

/-- `filesSave` as it crosses: what the save expects as a tag (0 whatever, 1
absent, 2 unchanged) and a stamp's three numbers, its seconds as a two's
complement word. -/
@[extern "editor_glue_files_save"]
private opaque filesSaveRaw (id : UInt64) (snapshot : @& Snapshot) (path : @& String)
    (tag seconds nanoseconds size : UInt64) : IO Bool

/-- Asks the library's file service to save what `snapshot` holds as the file
at `path`, if what is on disk is what `expect` says, as the request `id`, and
returns whether it was accepted. It returns at once, and the library keeps
its own hold on the snapshot's text. The completion and the result are as
`filesLoad`'s.

`false`, with nothing started, if `id` is in use, if `expect` holds a stamp
with nanoseconds no stamp has, or if the service could not start its thread.
Seconds no 64-bit word holds are sent as the nearest it does. -/
def filesSave (id : UInt64) (snapshot : Snapshot) (path : String) (expect : FileExpect) : IO Bool :=
  match expect with
  | .whatever => filesSaveRaw id snapshot path 0 0 0 0
  | .absent => filesSaveRaw id snapshot path 1 0 0 0
  | .unchanged stamp =>
    let seconds := max (-(2 ^ 63 : Int)) (min stamp.seconds (2 ^ 63 - 1))
    filesSaveRaw id snapshot path 2 seconds.toInt64.toUInt64 stamp.nanoseconds stamp.size

/-- A file result as the glue builds it, in one call: the object fields
first and the `UInt64` field after them, so the order here is the layout the
glue writes. -/
private structure RawFileResult where
  /-- The loaded text, for a load that succeeded. -/
  snapshot : Option Snapshot
  /-- The words, copied from the library's buffer. -/
  words : ByteArray
  /-- The detail, copied from the library's buffer. -/
  detail : String
  /-- How the request ended: the library's status. -/
  status : UInt64

/-- `filesTake` before its result is decoded. -/
@[extern "editor_glue_files_take"]
private opaque filesTakeRaw (id : UInt64) : IO (Option RawFileResult)

/-- Hands over the result of the file request `id`, once. `none` when the
service keeps no result for `id`: it is not finished, it was cancelled, its
result was taken already, or it was another service's id. It throws if the
library sends a result these bindings cannot read. -/
def filesTake (id : UInt64) : IO (Option FileResult) := do
  let some raw ← filesTakeRaw id | return none
  match FileResult.decode raw.status raw.snapshot raw.words raw.detail with
  | .ok result =>
    return some result
  | .error reason =>
    throw (IO.userError s!"the library's file result could not be read: {reason}")

/-- Cancels the file request `id`, and returns whether there was anything to
cancel: a request waiting or being worked, or a result not taken. It is safe
for an id that is unknown. A request that was waiting is never worked; a save
being worked does not replace its file; a completion that was already queued
still arrives, and its result is gone. -/
@[extern "editor_glue_files_cancel"]
opaque filesCancel (id : UInt64) : IO Bool

/-- How many file requests are waiting or being worked, and how many results
have not been taken, together. A readout for tests, which use it to see that
a cancel left nothing behind. -/
@[extern "editor_glue_files_pending"]
opaque filesPending : IO UInt64

/-- Asks the library's diff service for the line diff of what `old` and
`new` hold, with its engine asked about at most `limit` lines a side, as the
request `id`, and returns whether it was accepted. It returns at once, and
the library keeps its own hold on both texts. The completion is a
`completion` event on the completion queue, from the library source 5, whose
code is `id`; there is none if the request is cancelled first. The script is
then taken with `diffsTake`. `false`, with nothing started, if `id` is in use
or the service could not start its thread. -/
@[extern "editor_glue_diffs_start"]
opaque diffsStart (id : UInt64) (old new : @& Snapshot) (limit : UInt64) : IO Bool

/-- `diffsTake` before its words are decoded. -/
@[extern "editor_glue_diffs_take"]
private opaque diffsTakeRaw (id : UInt64) : IO (Option ByteArray)

/-- The edit script `bytes` spell: the count of steps, then a kind and two
numbers for each (`crates/editor-ffi/src/diffs.rs`, "How a script
crosses"). An error, with what was wrong, for words that spell none. It is
public for `FfiTest`. -/
def ScriptStep.decode (bytes : ByteArray) : Except String (Array ScriptStep) := do
  let some words := wordsOf? bytes | throw "its words are not whole words"
  let some count := words[0]? | throw "it has no count"
  unless words.size == 1 + 3 * count.toNat do
    throw s!"{count} steps are not {words.size - 1} words"
  (Array.range count.toNat).mapM fun index =>
      match words[1 + 3 * index]!, words[2 + 3 * index]!, words[3 + 3 * index]! with
      | 0, count, 0 => pure (.retain count)
      | 1, count, 0 => pure (.delete count)
      | 2, start, count => pure (.insert start count)
      | kind, _, _ => throw s!"the step kind {kind} is no step"

/-- Hands over the script of the diff request `id`, once. `none` when the
service keeps no script for `id`. It throws if the library sends words these
bindings cannot read. -/
def diffsTake (id : UInt64) : IO (Option (Array ScriptStep)) := do
  let some bytes ← diffsTakeRaw id | return none
  match ScriptStep.decode bytes with
  | .ok script =>
    return some script
  | .error reason =>
    throw (IO.userError s!"the library's edit script could not be read: {reason}")

/-- Cancels the diff request `id`, and returns whether there was anything to
cancel. Safe for an id that is unknown. -/
@[extern "editor_glue_diffs_cancel"]
opaque diffsCancel (id : UInt64) : IO Bool

/-- How many diff requests are waiting or being worked, and how many scripts
have not been taken, together. A readout for tests. -/
@[extern "editor_glue_diffs_pending"]
opaque diffsPending : IO UInt64

/-- Which of the library's platforms runs the window. -/
inductive Platform where
  /-- The library's scripted platform, a fake for tests: it opens nothing,
  needs no display, and reports one fixed script. -/
  | scripted
  /-- The real window, over winit. It needs a display. -/
  | winit
  /-- The library's scripted platform that cannot open a window, a fake for
  tests: every run fails at once, with one fixed reason. -/
  | scriptedFailing
  /-- The library's scripted platform whose window nothing can draw in, a
  fake for tests: it opens and reports as `scripted` does, but its renderer
  cannot be made, with one fixed reason, as a machine with no usable GPU
  gives. -/
  | scriptedUndrawn
  deriving DecidableEq, Repr

/-- A way a frame reaches the display, by wgpu's names
(`crates/editor-render-wgpu/src/present.rs`): what a run may ask for in
place of the renderer's decision, to measure it. -/
inductive PresentMode where
  /-- Frames wait for the display's refresh: no tearing. -/
  | fifo
  /-- As `fifo`, but a late frame is shown at once, tearing. -/
  | fifoRelaxed
  /-- A frame is shown the moment it is presented, tearing. -/
  | immediate
  /-- The newest frame replaces one waiting, at the refresh. -/
  | mailbox
  deriving DecidableEq, Repr

/-- The tag a present mode crosses as; 0 is none asked. -/
def PresentMode.tag : Option PresentMode → UInt8
  | none => 0
  | some .fifo => 1
  | some .fifoRelaxed => 2
  | some .immediate => 3
  | some .mailbox => 4

/-- What a run of the window answers, as the glue builds it: a reason, then
how the run ended (0 it ran and something drew in it, with no reason; 1 no
window ran; 2 it ran and nothing drew in it). Object fields first, so the
order here is the layout the glue writes. -/
private structure RawWindowRun where
  /-- Why no window ran, or why nothing drew in it; empty when it ran and
  something drew. -/
  reason : String
  /-- How the run ended. -/
  status : UInt64

/-- The title bar a window opens with (`editor_ffi_window_run`'s tags 0 and
1, in this order). -/
inductive TitleBar where
  /-- The drawable area extends under a title bar that draws no background
  of its own, so what is drawn there shows through: the window says how far
  down it covers the drawable area on every resize. A platform with no such
  title bar opens a standard one. -/
  | themed
  /-- The system's own title bar, above the drawable area. -/
  | standard
  deriving DecidableEq, Repr, Inhabited

/-- `windowRun` as it crosses. The title bar is its tag, the present mode
its tag and the frame latency a number, each 0 for none asked. -/
@[extern "editor_glue_window_run"]
private opaque windowRunRaw (platform : Platform) (composition : Bool) (titleBar : TitleBar)
    (presentMode : UInt8) (frameLatency : UInt32) : IO RawWindowRun

/-- How a window that opened ran, once it has closed. -/
structure WindowRan where
  /-- Why nothing drew in the window, when nothing did: its renderer could
  not be made (no adapter, no device, no surface), or the render thread did
  not end well. The window ran all the same, and what it reported
  arrived. -/
  nothingDrew : Option String := none
  deriving DecidableEq, Repr

/-- Runs the window on `platform`, with an input method allowed to compose
or not and the title bar `titleBar`, and returns once the window has
closed: `.ok` when it ran, saying
why nothing drew in it when nothing did, and `.error` with the reason when
no window could be opened.

The library's main-thread service runs the window's loop, and this blocks
until the loop has ended, so call it from Lean's main thread or a dedicated
task, never from the thread pool. While it runs, the main-thread service
answers nothing else: `mainThreadProbe` would wait for the window to close.

What the window reports arrives on the editor queue, from the window source,
each event stamped with the reading of `inputClock` when the window reported
it. The window does not close by itself: when the user asks, a
`closeRequested` event arrives, and the window stays open until
`windowClose`.

While the window is open, what a display bound to the presenter publishes
(`Display.present`) is drawn in it, at the scale the window says. A run may
ask for a present mode and a frame latency in place of the renderer's
decision, to measure them; `none` is the decision. -/
def windowRun (platform : Platform) (composition : Bool) (presentMode : Option PresentMode := none)
    (frameLatency : Option Nat := none) (titleBar : TitleBar := .themed) :
    IO (Except String WindowRan) := do
  let latency := (frameLatency.getD 0).toUInt32
  let raw ← windowRunRaw platform composition titleBar (PresentMode.tag presentMode) latency
  return match raw.status with
    | 0 => .ok {}
    | 2 => .ok { nothingDrew := some raw.reason }
    | _ => .error raw.reason

/-- Asks the window `platform` is running to close, so that `windowRun`
ends. Any thread may call it, and it does nothing when that platform runs
no window.

With the system's quit pending (`EventKind.quitRequested`) the close lets
the quit go ahead, and the platform may end the process inside `windowRun`,
which then never returns (the window port's rule, `Platform::close` in
`editor-platform`; AppKit's terminate on macOS). So whatever must happen
before the program ends happens before this is called. A
`WindowRequest.keepRunning` asked just before it refuses the quit instead,
and `windowRun` returns. -/
@[extern "editor_glue_window_close"]
opaque windowClose (platform : Platform) : IO Unit

/-- What Lean asks of the window (`editor_ffi_window_request`, its tags 0, 1,
2, 4, 6 and 7: `WindowRequest.tag`). The title is not one: it is a field of
the scene, and the tag 3 is the title's in what a scripted window was
asked, as 5 is a menu bar's. -/
inductive WindowRequest where
  /-- Put the window in the system's fullscreen; one in it stays there. -/
  | enterFullscreen
  /-- Take the window out of the system's fullscreen; one out of it stays
  out. -/
  | leaveFullscreen
  /-- Minimise the window. -/
  | minimise
  /-- The editor refused, or withdrew, the quit the system asked
  (`EventKind.quitRequested`). It changes nothing the window shows, and a
  platform with no quit pending does nothing with it. Asked just before
  `windowClose`, it refuses a quit pending as the window closes, so that
  `windowRun` returns. -/
  | keepRunning
  /-- Draw the window's title and buttons in the system's light
  appearance, for a light paper. -/
  | lightAppearance
  /-- Draw the window's title and buttons in the system's dark appearance,
  for a dark paper. -/
  | darkAppearance
  deriving DecidableEq, Repr

/-- The library's number for `request`: 0, 1, 2, 4, 6 and 7. It is not the
constructor's index, which for `keepRunning` would be the title's 3, and
for the appearances 4 and 5, keep running's and a menu bar's. -/
def WindowRequest.tag : WindowRequest → UInt8
  | .enterFullscreen => 0
  | .leaveFullscreen => 1
  | .minimise => 2
  | .keepRunning => 4
  | .lightAppearance => 6
  | .darkAppearance => 7

/-- `windowRequest` as it crosses: the request's tag. -/
@[extern "editor_glue_window_request"]
private opaque windowRequestRaw (platform : Platform) (tag : UInt8) : IO Unit

/-- Asks the window `platform` is running to do what `request` says. Any
thread may call it, it never blocks, and it does nothing when that platform
runs no window. It goes through the window's own loop, not the main-thread
service. Whether the window is then in fullscreen comes back on the editor
queue, as a resize. -/
def windowRequest (platform : Platform) (request : WindowRequest) : IO Unit :=
  windowRequestRaw platform request.tag

/-- One thing a scripted window was asked: a request, or a title or a menu
bar the presenter sent it from a scene. -/
inductive WindowAsked where
  /-- A request Lean made. -/
  | request (request : WindowRequest)
  /-- A title. -/
  | title (text : String)
  /-- A menu bar. -/
  | menu (menu : Menu)
  deriving DecidableEq, Repr

/-- The word of `modifiers` as the library reads it ("The window", in the
module docs): shift 1, control 2, alt 4, the system key 8. The one encoding
on the Lean side, for an event posted (`EventWords`), a menu's key
equivalent in a scene (`RealDisplay.encodeMenu`) and what a window was
asked (`askedOf`). -/
def modifierBits (modifiers : Modifiers) : UInt64 :=
  (if modifiers.shift then 1 else 0) ||| (if modifiers.control then 2 else 0) |||
    (if modifiers.alt then 4 else 0) |||
    (if modifiers.superKey then 8 else 0)

/-- The modifiers the word `bits` holds (`modifierBits`); `none` when it has
a bit past the system key's. -/
def modifiersOfBits? (bits : UInt64) : Option Modifiers :=
  if bits &&& ~~~15 != 0 then none
  else
    some
      { shift := bits &&& 1 != 0, control := bits &&& 2 != 0, alt := bits &&& 4 != 0,
        superKey := bits &&& 8 != 0 }

/-- Reads the words of what a window was asked, from an index on: each
reader gives what it read and the index after it, or `none` when the
words spell nothing. -/
private abbrev AskedReader :=
  StateT Nat Option

/-- The next word. -/
private def AskedReader.word (words : Array UInt64) : AskedReader UInt64 := fun at_ =>
  words[at_]?.map (·, at_ + 1)

/-- A count of things, each at least one word, that the words left can
hold. -/
private def AskedReader.count (words : Array UInt64) : AskedReader Nat := do
  let count := (← AskedReader.word words).toNat
  if count ≤ words.size - (← get) then
    pure count
  else
    failure

/-- The character the scalar value `scalar` numbers, if it is one. -/
private def AskedReader.char? (scalar : UInt64) : Option Char :=
  if scalar < 0x110000 && Nat.isValidChar scalar.toNat then some (Char.ofNat scalar.toNat) else none

/-- A text: the count of its scalar values, and each of them. -/
private def AskedReader.text (words : Array UInt64) : AskedReader String := do
  let count ← AskedReader.count words
  let chars ←
    (List.range count).mapM fun _ => do
        let some char := AskedReader.char? (← AskedReader.word words) | failure
        pure char
  return String.ofList chars

/-- A menu bar in the layout of `editor-ffi`'s `menu.rs`: its menus, each
with its title, its role and its items. -/
private def AskedReader.menu (words : Array UInt64) : AskedReader Menu := do
  let word := AskedReader.word words
  let menus ←
    (List.range (← AskedReader.count words)).mapM fun _ => do
        let title ← AskedReader.text words
        let role ←
          match ← word with
          | 0 =>
            pure none
          | 1 =>
            pure (some MenuRole.app)
          | 2 =>
            pure (some MenuRole.window)
          | _ =>
            failure
        let items ←
          (List.range (← AskedReader.count words)).mapM fun _ => do
              match ← word with
              | 0 =>
                pure MenuItem.separator
              | kind@(1 : UInt64) | kind@2 =>
                do
                  let title ← AskedReader.text words
                  let (present, scalar, bits) := (← word, ← word, ← word)
                  let key ←
                    match present with
                    | 0 =>
                      pure none
                    | 1 =>
                      do
                        let some character := AskedReader.char? scalar | failure
                        let some modifiers := modifiersOfBits? bits | failure
                        pure (some { character, modifiers })
                    | _ =>
                      failure
                  let action ←
                    if kind == 1 then
                      MenuAction.command <$> AskedReader.text words
                    else
                      match ← word with
                      | 0 =>
                        pure (.system .about)
                      | 1 =>
                        pure (.system .services)
                      | 2 =>
                        pure (.system .hide)
                      | 3 =>
                        pure (.system .hideOthers)
                      | 4 =>
                        pure (.system .showAll)
                      | 5 =>
                        pure (.system .quit)
                      | _ =>
                        failure
                  pure (MenuItem.item title key action)
              | _ =>
                failure
        pure { title, role, items := items.toArray }
  return { menus := menus.toArray }

/-- `windowAsked` as it crosses. -/
@[extern "editor_glue_window_asked"]
private opaque windowAskedRaw (platform : Platform) : IO RawWords

/-- What the words of `windowAsked` spell from the index `at_` on, each
thing asked in order: a request's tag, the tag 3, a count and the scalar
values of a title's characters, or the tag 5 and a menu bar's layout
(`AskedReader.menu`). `none` when they spell nothing. -/
private partial def askedOf (words : Array UInt64) (at_ : Nat := 0)
    (asked : Array WindowAsked := #[]) : Option (Array WindowAsked) :=
  if at_ >= words.size then some asked
  else
    match words[at_]! with
    | 0 => askedOf words (at_ + 1) (asked.push (.request .enterFullscreen))
    | 1 => askedOf words (at_ + 1) (asked.push (.request .leaveFullscreen))
    | 2 => askedOf words (at_ + 1) (asked.push (.request .minimise))
    | 4 => askedOf words (at_ + 1) (asked.push (.request .keepRunning))
    | 6 => askedOf words (at_ + 1) (asked.push (.request .lightAppearance))
    | 7 => askedOf words (at_ + 1) (asked.push (.request .darkAppearance))
    | 3 => do
      let count := (← words[at_ + 1]?).toNat
      let scalars ← (List.range count).mapM fun index => words[at_ + 2 + index]?
      let chars ←
        scalars.mapM fun scalar =>
            if scalar < 0x110000 && (Nat.isValidChar scalar.toNat) then
              some (Char.ofNat scalar.toNat)
            else none
      askedOf words (at_ + 2 + count) (asked.push (.title (String.ofList chars)))
    | 5 => do
      let (menu, next) ← (AskedReader.menu words).run (at_ + 1)
      askedOf words next (asked.push (.menu menu))
    | _ => none

/-- What the scripted window of `platform` was asked in its latest run, in
order: the requests while it ran, and the titles the presenter sent it.
`none` for the real platform, which records nothing. A readout for tests. -/
def windowAsked (platform : Platform) : IO (Option (Array WindowAsked)) := do
  let raw ← windowAskedRaw platform
  if raw.status != 0 then
    return none
  let problem := IO.userError "the library's record of requests is not its words"
  let some words := wordsOf? raw.words | throw problem
  let some asked := askedOf words | throw problem
  return some asked

/-- `windowOpenedWith` as it crosses. -/
@[extern "editor_glue_window_opened_with"]
private opaque windowOpenedWithRaw (platform : Platform) : IO RawWords

/-- What the scripted window of `platform` was opened with in its latest
run: whether an input method could compose, and its title bar. `none` for
the real platform, which records nothing, and before any run. A readout for
tests. -/
def windowOpenedWith (platform : Platform) : IO (Option (Bool × TitleBar)) := do
  let raw ← windowOpenedWithRaw platform
  if raw.status != 0 then
    return none
  let problem := IO.userError "the library's record of a run is not its words"
  let some words := wordsOf? raw.words | throw problem
  match words with
  | #[] =>
    return none
  | #[composition, titleBar] =>
    let titleBar ←
      match titleBar with
      | 0 =>
        pure TitleBar.themed
      | 1 =>
        pure .standard
      | _ =>
        throw problem
    return some (composition == 1, titleBar)
  | _ =>
    throw problem

/-- `postInput` as it crosses: the words as bytes. -/
@[extern "editor_glue_window_post_input"]
private opaque postInputRaw (kind : EventKind) (code : UInt64) (text : @& String)
    (words : @& ByteArray) : IO Bool

/-- Posts to the editor queue the event the process's window would push if it
reported the input that an event of `kind` with `code`, `text` and `words`
stands for (the layouts in "The window", in the module docs): the library
reads the words into its window input and pushes the event it makes of it,
from the window source, stamped on the input clock. It is the path a real
window's input takes, for tests and for the headless driver.

`false`, queueing nothing, when `kind` is not a window's, the code is out of
range, the words do not read as an input of that kind, or the queues have
been quit. -/
def postInput (kind : EventKind) (code : UInt64) (text : @& String) (words : Array UInt64) :
    IO Bool :=
  postInputRaw kind code text (words.foldl pushWord ByteArray.empty)

/-- The time on the library's input clock, in nanoseconds since the clock
began: the clock a window's events are stamped on. It never goes back, and
it is never 0. The time from an event's stamp to this reading is how long the
event took to reach whoever reads it. -/
@[extern "editor_glue_input_clock"]
opaque inputClock : IO UInt64

/-- `interruptKeySet` as it crosses: the words as bytes. -/
@[extern "editor_glue_interrupt_key_set"]
private opaque interruptKeySetRaw (words : @& ByteArray) : IO Bool

/-- Makes the key `words` stand for the library's interrupt key ("The
interrupt flag", in the module docs): `[logical tag, n, n scalars,
modifiers, mask]`. From then on a press of that key, with exactly those of
the masked modifiers held, raises the flag as it arrives.

`false`, changing nothing, for words that do not read as a key. The flag is
left as it is either way. -/
def interruptKeySet (words : Array UInt64) : IO Bool :=
  interruptKeySetRaw (words.foldl pushWord ByteArray.empty)

/-- Leaves the library with no interrupt key: nothing raises the flag until
one is set again. The flag is left as it is. -/
@[extern "editor_glue_interrupt_key_clear"]
opaque interruptKeyClear : IO Unit

/-- Whether the library's interrupt flag is up: a press of the interrupt key
has arrived on the editor queue and has not been lowered for. Asking does
not lower it. -/
@[extern "editor_glue_interrupt_raised"]
opaque interruptRaised : IO Bool

/-- Tells the library that one press of the interrupt key was taken off the
queue: one fewer holds the flag up. With none counted, nothing. -/
@[extern "editor_glue_interrupt_lower"]
opaque interruptLower : IO Unit

/-! ## The display -/

/-- The type behind `Display`. It is opaque, so the only way to get a
display is `Display.newCells`. -/
opaque DisplayPointed : NonemptyType

/-- Layout held by the Rust library (`crates/editor-ffi/src/display.rs`,
over `crates/editor-layout`): a handle that lays out the text of snapshots
and answers the display interface's two layout queries about them. The
display interface's real binding runs against it
(`Editor/Display/Real.lean`). -/
def Display : Type :=
  DisplayPointed.type

instance : Nonempty Display :=
  DisplayPointed.property

/-- A new display over the library's fake shaper, whose every glyph is
`advance` pixels across and every line `lineHeight` down. -/
@[extern "editor_glue_display_new_cells"]
opaque Display.newCells (advance lineHeight : UInt64) : IO Display

/-- A new display over the library's real shaper and the fonts of this
machine: the window mode's. What it lays out depends on the machine, so no
check makes one. -/
@[extern "editor_glue_display_new_system"]
opaque Display.newSystem : IO Display

/-- Binds `display` to the library's presenter: every scene it publishes
from then on is laid out at the scale the process's window said, and its
frame reaches the render session that runs, the window's or the headless
mode's, stamped with the window input it answers. -/
@[extern "editor_glue_display_present"]
opaque Display.present (display : @& Display) : IO Unit

/-- How many displays the Rust library holds that have not been freed.

This exists for `FfiTest`, which uses it to see a display's finaliser
run. -/
@[extern "editor_glue_display_live"]
opaque Display.live : IO UInt64

/-- The heights of the rows a frame is built of, in whole pixels at the
display's scale, as the library answers them: a text row, a window's status
row, and the frame's bottom row, where the echo or the prompt is drawn. -/
structure DisplayHeights where
  /-- One text row in the default face. -/
  text : UInt64
  /-- A window's status row. -/
  status : UInt64
  /-- The bottom row. -/
  message : UInt64
  deriving DecidableEq, Repr

/-- `Display.heights` as it crosses. -/
@[extern "editor_glue_display_heights"]
private opaque Display.heightsRaw (display : @& Display) : IO RawWords

/-- The heights of a text row, a status row and the bottom row. Words that
are not three are an error. -/
def Display.heights (display : Display) : IO DisplayHeights := do
  let raw ← display.heightsRaw
  match wordsOf? raw.words with
  | some #[text, status, message] =>
    return { text, status, message }
  | _ =>
    throw (IO.userError "the library's heights are not three words")

/-- One visual row, as the library answers it: the bytes from `start` up to
`stop`, without its line break. -/
structure DisplayRow where
  /-- The byte offset of its first character. -/
  start : UInt64
  /-- Where its characters stop. -/
  stop : UInt64
  deriving DecidableEq, Repr

/-- Where a move went, as the library answers it. -/
structure DisplayMoved where
  /-- The byte offset it reached. -/
  position : UInt64
  /-- The x it aimed for, in whole pixels, to pass to the next move. -/
  goal : UInt64
  deriving DecidableEq, Repr

/-- The rows a record of words holds: their count, then a start and a stop
for each. `none` when its status is not 0. Words that do not spell rows are
an error. -/
private def rowsOf? (raw : RawWords) : IO (Option (Array DisplayRow)) := do
  if raw.status != 0 then
    return none
  let some words := wordsOf? raw.words
    | throw (IO.userError "the library's rows are not whole words")
  let count := (words[0]?.getD 0).toNat
  unless words.size == 1 + 2 * count do
    throw (IO.userError "the library's rows do not spell their count")
  return some <|
      (Array.range count).map fun row =>
        { start := words[1 + 2 * row]!, stop := words[2 + 2 * row]! }

/-- `Display.rows` as it crosses: the answer as words, and its status. -/
@[extern "editor_glue_display_rows"]
private opaque Display.rowsRaw (display : @& Display) (snapshot : @& Snapshot)
    (width height across down top : UInt64) (anchor : USize) : IO RawWords

/-- The rows a view `width` pixels wide and `height` tall, its content inset
`across` and `down` points from its edges and its rows a further `top`
points from its top, shows of `snapshot`, from the visual row that holds
`anchor`: as many as fit whole, fewer at the end of the text. The library
takes the padding off at the scale it lays out at, as its frames take it
off; a padding no `u32` holds is the largest. `none` when `anchor` is not a
position of the text. -/
def Display.rows (display : Display) (snapshot : Snapshot) (width height : UInt64) (anchor : USize)
    (across down top : UInt64 := 0) : IO (Option (Array DisplayRow)) := do
  rowsOf? (← display.rowsRaw snapshot width height across down top anchor)

/-- `Display.move` as it crosses: the lines as a 64-bit two's complement
number, the goal as a presence flag and a value, and the answer as words. -/
@[extern "editor_glue_display_move"]
private opaque Display.moveRaw (display : @& Display) (snapshot : @& Snapshot)
    (width across : UInt64) (position : USize) (lines : UInt64) (goalPresent : Bool)
    (goal : UInt64) : IO RawWords

/-- The position of `snapshot` `lines` visual rows below `position` (above
when negative) in a view `width` pixels wide whose text is inset `across`
points each side, aiming for `goal`, or for the position's own x when there
is none; and the goal to pass on. A count of lines past what 64 bits hold
is cut to the largest, which is past every text's first and last row
anyway. `none` when `position` is not a position of the text. -/
def Display.move (display : Display) (snapshot : Snapshot) (width : UInt64) (position : USize)
    (lines : Int) (goal : Option UInt64) (across : UInt64 := 0) : IO (Option DisplayMoved) := do
  let bound : Int := 2 ^ 63
  let clamped := max (-bound) (min lines (bound - 1))
  let word := if clamped < 0 then (2 ^ 64 + clamped).toNat.toUInt64 else clamped.toNat.toUInt64
  let raw ← display.moveRaw snapshot width across position word goal.isSome (goal.getD 0)
  if raw.status != 0 then
    return none
  match wordsOf? raw.words with
  | some #[position, goal] =>
    return some { position, goal }
  | _ =>
    throw (IO.userError "the library's words do not spell a move")

/-- Where a position is drawn in a view, as the library answers it: in whole
pixels from the view's top left, its padding included. -/
structure DisplaySpot where
  /-- From the view's left edge to the position's left, rounded down. -/
  x : UInt64
  /-- From the view's top edge to the top of the row that holds it,
  rounded down. -/
  y : UInt64
  /-- How tall that row is, rounded up. -/
  height : UInt64
  deriving DecidableEq, Repr

/-- `Display.spot` as it crosses: the answer as words, and its status. -/
@[extern "editor_glue_display_spot"]
private opaque Display.spotRaw (display : @& Display) (snapshot : @& Snapshot)
    (width height across down top : UInt64) (anchor position : USize) : IO RawWords

/-- Where `position` of `snapshot` is drawn in a view `width` pixels wide
and `height` tall, padded as for `Display.rows`, that shows from the visual
row that holds `anchor`: `some none` when the view does not show it, and
`none` when `anchor` or `position` is not a position of the text. Words
that do not spell a spot are an error. -/
def Display.spot (display : Display) (snapshot : Snapshot) (width height : UInt64)
    (anchor position : USize) (across down top : UInt64 := 0) : IO (Option (Option DisplaySpot)) :=
  do
  let raw ← display.spotRaw snapshot width height across down top anchor position
  if raw.status != 0 then
    return none
  match wordsOf? raw.words with
  | some #[0, _, _, _] =>
    return some none
  | some #[_, x, y, height] =>
    return some (some { x, y, height })
  | _ =>
    throw (IO.userError "the library's words do not spell a spot")

/-- `Display.publish` as it crosses: the words as bytes, the string, and the
snapshot handles, which the glue passes as a C array. -/
@[extern "editor_glue_display_publish"]
private opaque Display.publishRaw (display : @& Display) (words : @& ByteArray)
    (strings : @& String) (snapshots : @& Array Snapshot) : IO Bool

/-- Publishes the scene `words` and `strings` spell, whose views show the
`snapshots`, named in the words by their index (the layout is
`crates/editor-ffi/src/display/wire.rs`'s): the library resolves the
markers it names in the snapshots' documents, lays it out, and keeps its
frame. `false`, keeping what was published before, when the words do not
spell a scene. -/
def Display.publish (display : Display) (words : Array UInt64) (strings : String)
    (snapshots : Array Snapshot) : IO Bool :=
  display.publishRaw (words.foldl pushWord ByteArray.empty) strings snapshots

/-- `Display.define` as it crosses: the words as bytes, and the string. -/
@[extern "editor_glue_display_define"]
private opaque Display.defineRaw (display : @& Display) (words : @& ByteArray)
    (strings : @& String) : IO Bool

/-- Defines the faces `words` and `strings` spell, the count of definitions
and each definition as they follow the faces' presence in a scene's words,
as what the faces look like from now on, with no frame laid out: every
later heights answer, query and frame is in them, until a scene carries
others. `false`, changing nothing, when the words do not spell them. -/
def Display.define (display : Display) (words : Array UInt64) (strings : String) : IO Bool :=
  display.defineRaw (words.foldl pushWord ByteArray.empty) strings

/-- The latest frame the display laid out, as the library's text of it
(`Frame::describe` in `crates/editor-layout`): empty before any scene is
published. -/
@[extern "editor_glue_display_frame_text"]
opaque Display.frameText (display : @& Display) : IO String

/-- `Display.frameRows` as it crosses. -/
@[extern "editor_glue_display_frame_rows"]
private opaque Display.frameRowsRaw (display : @& Display) (view : UInt64) : IO RawWords

/-- The rows the view numbered `view` shows in the latest frame; `none` when
the frame has no such view. -/
def Display.frameRows (display : Display) (view : UInt64) : IO (Option (Array DisplayRow)) := do
  rowsOf? (← display.frameRowsRaw view)

/-- The last scene published, as the glue builds it: its words, its string,
and 0, or nothing and 1 before any. Object fields first, so the order here is
the layout the glue writes. -/
private structure RawScene where
  /-- The words. -/
  words : ByteArray
  /-- The string. -/
  strings : String
  /-- 0 when a scene was published. -/
  status : UInt64

/-- `Display.scene` as it crosses. -/
@[extern "editor_glue_display_scene"]
private opaque Display.sceneRaw (display : @& Display) : IO RawScene

/-- The last scene published, as the library writes it back: the words and
the string it was sent. `none` before any. -/
def Display.scene (display : Display) : IO (Option (Array UInt64 × String)) := do
  let raw ← display.sceneRaw
  if raw.status != 0 then
    return none
  let some words := wordsOf? raw.words
    | throw (IO.userError "the library's scene is not whole words")
  return some (words, raw.strings)

/-! ## A display's picture, for tests -/

/-- A new display over the library's real shaper and one font file, `bytes`,
whose family `family` is the default family of a font set with no font of
the machine: a face naming any other family is drawn in it. An `IO` error
with the library's reason when the bytes are not a font or hold no such
family. For tests, as `Display.frameText` is: what it lays out is the same
on every machine (`FfiTest.themePicturesScenario`). -/
@[extern "editor_glue_display_new_font"]
opaque Display.newFont (bytes : @& ByteArray) (family : @& String) : IO Display

/-- A picture, as the library's CPU renderer draws one: `width` pixels
across, `height` down, and its pixels, row by row from the top, red, green,
blue and alpha for each, as sRGB values. For tests. -/
structure Picture where
  /-- How far across it is. -/
  width : Nat
  /-- How far down. -/
  height : Nat
  /-- Its pixels: four bytes each. -/
  rgba : ByteArray
  deriving DecidableEq

/-- A picture as the glue builds it. Object fields first, so the order here
is the layout the glue writes. -/
private structure RawPicture where
  /-- The pixels. -/
  rgba : ByteArray
  /-- How far across. -/
  width : UInt64
  /-- How far down. -/
  height : UInt64

/-- The picture `raw` stands for. -/
private def RawPicture.picture (raw : RawPicture) : Picture :=
  { width := raw.width.toNat, height := raw.height.toNat, rgba := raw.rgba }

/-- `Display.picture` as it crosses. -/
@[extern "editor_glue_display_picture"]
private opaque Display.pictureRaw (display : @& Display) : IO RawPicture

/-- The latest frame the display laid out, drawn by the library's CPU
renderer synchronously, with no render session, thread or clock, at the
last published scene's size and at the display's scale, with one coverage a
pixel and hinting: 0 by 0 before any scene. For tests: it is how a theme
written here reaches the renderer in `ffi-test`. -/
def Display.picture (display : Display) : IO Picture :=
  return (← display.pictureRaw).picture

/-- `Picture.ofPng` as it crosses. -/
@[extern "editor_glue_picture_from_png"]
private opaque Picture.ofPngRaw (bytes : @& ByteArray) : IO RawPicture

/-- The picture the PNG file `bytes` holds, 8 bits a channel, RGB or RGBA,
an RGB one read as opaque; an `IO` error with the library's reason when the
bytes are no such file. For tests. -/
def Picture.ofPng (bytes : ByteArray) : IO Picture :=
  return (← Picture.ofPngRaw bytes).picture

/-- `Picture.toPng` as it crosses. -/
@[extern "editor_glue_picture_to_png"]
private opaque Picture.toPngRaw (width height : UInt64) (rgba : @& ByteArray) : IO ByteArray

/-- The bytes of a PNG file of `picture`: RGB, 8 bits a channel, its alpha
not written. An `IO` error with the library's reason when its pixels are
not its size or it is one no PNG file can hold, such as one 0 by 0. For
tests. -/
def Picture.toPng (picture : Picture) : IO ByteArray :=
  Picture.toPngRaw picture.width.toUInt64 picture.height.toUInt64 picture.rgba

/-! ## The render session -/

/-- What starting the headless render session answers, as the glue builds
it: what the library says, then how it went (0 started, 1 one runs
already, 2 its render thread could not be started). Object fields first,
so the order here is the layout the glue writes. -/
private structure RawRenderStart where
  /-- Why nothing started, in the library's words; empty when it started. -/
  reason : String
  /-- How it went. -/
  status : UInt64

/-- `renderHeadless` as it crosses. -/
@[extern "editor_glue_render_headless"]
private opaque renderHeadlessRaw : IO RawRenderStart

/-- Starts the headless mode's render session: a render loop with no window,
on a thread of the library's, over the CPU renderer, which draws what a
bound display publishes at each scene's size. Refused, starting nothing,
with the library's reason: when one runs already, and when its render
thread could not be started, in the system's words. -/
def renderHeadless : IO (Except String Unit) := do
  let raw ← renderHeadlessRaw
  return if raw.status == 0 then .ok () else .error raw.reason

/-- Stops the headless render session and waits for its thread. Its journal
and counters stay readable. `false` when none runs. -/
@[extern "editor_glue_render_stop"]
opaque renderStop : IO Bool

/-- One frame drawn and presented, as the render loop's journal records it,
on the clock that stamps window input. -/
structure JournalEntry where
  /-- Its place in the journal, from 1. -/
  serial : UInt64
  /-- When the input it answers was stamped. -/
  inputNs : UInt64
  /-- When its draw began. -/
  drawNs : UInt64
  /-- When the renderer returned, having presented it. -/
  presentNs : UInt64
  /-- The rows it built. -/
  rowsRebuilt : UInt64
  /-- The rows it drew from what was kept. -/
  rowsReused : UInt64
  deriving DecidableEq, Repr

/-- `renderJournal` as it crosses. -/
@[extern "editor_glue_render_journal"]
private opaque renderJournalRaw (after : UInt64) : IO RawWords

/-- The journal entries of the latest render session, ended or not, whose
serial is above `after`, oldest first; `none` when no session has started. -/
def renderJournal (after : UInt64) : IO (Option (Array JournalEntry)) := do
  let raw ← renderJournalRaw after
  if raw.status != 0 then
    return none
  let some words := wordsOf? raw.words
    | throw (IO.userError "the library's journal is not whole words")
  let count := (words[0]?.getD 0).toNat
  unless words.size == 1 + 6 * count do
    throw (IO.userError "the library's journal does not spell its count")
  return some <|
      (Array.range count).map fun index =>
        let at_ (field : Nat) := words[1 + 6 * index + field]!
        { serial := at_ 0, inputNs := at_ 1, drawNs := at_ 2, presentNs := at_ 3
          rowsRebuilt := at_ 4, rowsReused := at_ 5 }

/-- What the latest render session has done, as its counters say. -/
structure RenderCounters where
  /-- The draws that presented a frame. -/
  draws : UInt64
  /-- The draws that did not. -/
  drawsFailed : UInt64
  /-- The frames submitted. -/
  framesSubmitted : UInt64
  /-- The frames a newer one replaced before they were drawn. -/
  framesReplaced : UInt64
  /-- The rows built, over every presented draw. -/
  rowsRebuilt : UInt64
  /-- The rows drawn from what was kept. -/
  rowsReused : UInt64
  /-- The glyph images rasterised. -/
  glyphsRasterised : UInt64
  /-- The glyph images asked for and already held. -/
  glyphsReused : UInt64
  /-- The glyph images dropped to make room. -/
  glyphsEvicted : UInt64
  /-- The glyphs that could not be drawn. -/
  glyphsSkipped : UInt64
  /-- The bytes the glyph images took up at the last draw. -/
  atlasBytes : UInt64
  /-- The journal entries let go to make room. -/
  journalDropped : UInt64
  deriving DecidableEq, Repr

/-- `renderCounters` as it crosses. -/
@[extern "editor_glue_render_counters"]
private opaque renderCountersRaw : IO RawWords

/-- The counters of the latest render session, ended or not; `none` when no
session has started. -/
def renderCounters : IO (Option RenderCounters) := do
  let raw ← renderCountersRaw
  if raw.status != 0 then
    return none
  match wordsOf? raw.words with
  |
  some
      #[draws, drawsFailed, framesSubmitted, framesReplaced, rowsRebuilt, rowsReused,
        glyphsRasterised, glyphsReused, glyphsEvicted, glyphsSkipped, atlasBytes, journalDropped] =>
    return some
        { draws, drawsFailed, framesSubmitted, framesReplaced, rowsRebuilt, rowsReused
          glyphsRasterised, glyphsReused, glyphsEvicted, glyphsSkipped, atlasBytes
          journalDropped }
  | _ =>
    throw (IO.userError "the library's counters are not twelve words")

/-- `renderResting` as it crosses: 0 for no session, 1 busy, 2 at rest. -/
@[extern "editor_glue_render_resting"]
private opaque renderRestingRaw : IO UInt8

/-- Whether the latest render session's loop is at rest: its last step found
nothing asked and nothing to wait for, and nothing has been asked since;
`none` when no session has started. -/
def renderResting : IO (Option Bool) := do
  return match ← renderRestingRaw with
    | 0 => none
    | 2 => some true
    | _ => some false

/-- What a window's surface offered, what its run asked for and what it was
configured with, as the wgpu renderer says it. -/
structure WindowPresentation where
  /-- The present modes the surface offered, in its order. -/
  modes : Array PresentMode
  /-- The present mode and the frame latency the run asked for, each `none`
  when it did not ask for it: only what was asked. -/
  asked : Option PresentMode × Option Nat
  /-- The present mode and frame latency the surface was configured with. -/
  configured : PresentMode × Nat
  deriving DecidableEq, Repr

/-- `windowPresentation` as it crosses. -/
@[extern "editor_glue_window_presentation"]
private opaque windowPresentationRaw : IO RawWords

/-- The present mode a tag of the library's names: the inverse of
`PresentMode.tag`. -/
private def PresentMode.ofTag? : UInt64 → Option PresentMode
  | 1 => some .fifo
  | 2 => some .fifoRelaxed
  | 3 => some .immediate
  | 4 => some .mailbox
  | _ => none

/-- What the surface of the latest window drawn with the wgpu renderer
offered, what its run asked for and what it was configured with, read after
it has closed too; `none` when no window has drawn with it, as on the
scripted platforms. -/
def windowPresentation : IO (Option WindowPresentation) := do
  let raw ← windowPresentationRaw
  if raw.status != 0 then
    return none
  let problem := IO.userError "the library's presentation is not its words"
  let some words := wordsOf? raw.words | throw problem
  let count := (words[0]?.getD 0).toNat
  let mode (index : Nat) : IO PresentMode := do
    let some mode := PresentMode.ofTag? (words[index]?.getD 0) | throw problem
    return mode
  unless words.size == 1 + count + 4 do
    throw problem
  let modes ← (Array.range count).mapM fun index => mode (1 + index)
  let at_ := 1 + count
  -- What was asked: a mode's tag and a latency, each 0 for none asked.
  let askedMode ←
    if words[at_]! == 0 then
      pure none
    else
      some <$> mode at_
  let askedLatency := (some words[at_ + 1]!.toNat).filter (· != 0)
  return some
      { modes, asked := (askedMode, askedLatency)
        configured := (← mode (at_ + 2), words[at_ + 3]!.toNat) }

/-! ## The clipboard -/

/-- The type behind `Clipboard`. It is opaque, so the only ways to get a
clipboard are `Clipboard.memory`, `Clipboard.failing` and
`Clipboard.system`. -/
opaque ClipboardPointed : NonemptyType

/-- A clipboard held by the Rust library (`crates/editor-ffi/src/clipboard.rs`,
over the clipboard port of `crates/editor-platform`): the library's memory
clipboard, its failing one, or the desktop's. The clipboard interface's real
binding runs against it (`Editor/Clipboard/Real.lean`). -/
def Clipboard : Type :=
  ClipboardPointed.type

instance : Nonempty Clipboard :=
  ClipboardPointed.property

/-- A new clipboard in the library's memory that holds nothing: the port's
fake, which no other program sees. Every test is on it. -/
@[extern "editor_glue_clipboard_memory"]
opaque Clipboard.memory : IO Clipboard

/-- A new clipboard of the library's that cannot be reached: every read and
write fails with `reason`, and changes nothing. It is the port's failing
fake, for tests of the failure path (`ContractTest.clipboardChecks`); the
editor never makes one. -/
@[extern "editor_glue_clipboard_failing"]
opaque Clipboard.failing (reason : @& String) : IO Clipboard

/-- The desktop's clipboard, or the reason it cannot be reached. Only the
window mode opens it: what it holds is the person's. -/
@[extern "editor_glue_clipboard_system"]
opaque Clipboard.system : IO (Except String Clipboard)

/-- What a read of the clipboard answers, as the glue builds it: the text or
the reason, then how the read ended (0 text, 1 no text, 2 failed). Object
fields first, so the order here is the layout the glue writes. -/
private structure RawClipboardRead where
  /-- The text held, or the reason the read failed; empty when there is
  no text. -/
  text : String
  /-- How the read ended. -/
  status : UInt64

/-- `Clipboard.read` as it crosses. -/
@[extern "editor_glue_clipboard_read"]
private opaque Clipboard.readRaw (clipboard : @& Clipboard) : IO RawClipboardRead

/-- The text the clipboard holds, `none` when it holds no text, or the
reason it could not be read. -/
def Clipboard.read (clipboard : Clipboard) : IO (Except String (Option String)) := do
  let raw ← clipboard.readRaw
  return match raw.status with
    | 0 => .ok (some raw.text)
    | 1 => .ok none
    | _ => .error raw.text

/-- Has the clipboard hold `text`, in place of what it held: `none` when it
was written, and the reason otherwise. -/
@[extern "editor_glue_clipboard_write"]
opaque Clipboard.write (clipboard : @& Clipboard) (text : @& String) : IO (Option String)

/-- How many clipboards the Rust library holds that have not been freed. -/
@[extern "editor_glue_clipboard_live"]
opaque Clipboard.live : IO UInt64

/-- A list of strings as words: their count, then the byte length of each.
The strings themselves cross beside the words, as one string of all of them
end to end. -/
private def lengthWords (strings : Array String) : ByteArray :=
  strings.foldl (fun words string => pushWord words string.utf8ByteSize.toUInt64)
    (pushWord ByteArray.empty strings.size.toUInt64)

/-- The ranking `words` spell for `candidates` candidates: the count of
indices, then each. `none` unless the count is the count of indices there
and each is below `candidates`. -/
private def rankingOf? (candidates : Nat) (words : Array UInt64) : Option (Array Nat) := do
  let count := (← words[0]?).toNat
  guard (words.size == 1 + count)
  let indices := (words.extract 1 words.size).map (·.toNat)
  guard (indices.all (· < candidates))
  return indices

/-- `fuzzyRank` as it crosses: the pattern, the candidates as words and one
string, and the ranking as words with the status 0, or no words and the
status 1 when the library cannot read the candidates. -/
@[extern "editor_glue_fuzzy_rank"]
private opaque fuzzyRankRaw (pattern : @& String) (words : @& ByteArray) (strings : @& String) :
    IO RawWords

/-- The indices of the `candidates` that `pattern` matches, best first, each
once: the library's fuzzy matcher (`crates/editor-fuzzy`, over
`nucleo-matcher`). A candidate matches when the pattern's Unicode scalar
values all occur in it, in the pattern's order, adjacent or apart; a
candidate that is the pattern comes first, and the rest are in the order of
the matcher's scores.

The call keeps nothing in the library: the candidates are borrowed for it,
and each call copies their bytes once, into the one string that crosses.

It refuses nothing. A status other than 0, and an answer that is not a count
and that many indices of the candidates, mean the encoder here is wrong, so
each is an `IO` error. -/
def fuzzyRank (pattern : String) (candidates : Array String) : IO (Array Nat) := do
  let strings := candidates.foldl (· ++ ·) ""
  let raw ← fuzzyRankRaw pattern (lengthWords candidates) strings
  if raw.status != 0 then
    throw (IO.userError "the library could not read the candidates of a fuzzy ranking")
  match (wordsOf? raw.words).bind (rankingOf? candidates.size) with
  | some ranking =>
    return ranking
  | none =>
    throw (IO.userError "the library's words do not spell a fuzzy ranking")

/-- A kind of bracket of the library (`crates/editor-text`, `Bracket`). -/
inductive Bracket where
  /-- `(` and `)`. -/
  | round
  /-- `[` and `]`. -/
  | square
  /-- `{` and `}`. -/
  | curly
  deriving DecidableEq, Repr

/-- A kind of quote of the library (`crates/editor-text`, `Quote`). -/
inductive Quote where
  /-- `"`. -/
  | double
  /-- `'`. -/
  | single
  /-- `` ` ``. -/
  | back
  deriving DecidableEq, Repr

/-- A bracket as it crosses: its tag. The table of tags is in the module docs
of `crates/editor-ffi/src/pair.rs`, which checks the tag. -/
private def Bracket.tag : Bracket → UInt8
  | .round => 0
  | .square => 1
  | .curly => 2

/-- A quote as it crosses: its tag, from the same table. -/
private def Quote.tag : Quote → UInt8
  | .double => 0
  | .single => 1
  | .back => 2

/-- `Snapshot.unmatched` as it crosses: the bracket as a tag, four flags and
the offset in, and `none` for a refusal, `some none` for no such bracket and
`some (some at)` for the bracket found. -/
@[extern "editor_glue_snapshot_unmatched"]
private opaque Snapshot.unmatchedRaw (snapshot : @& Snapshot) (tag : UInt8)
    (opening forward escaped skipQuoted : Bool) (offset : USize) : IO (Option (Option UInt64))

/-- `Snapshot.quoted` as it crosses: the quote as a tag and the offset in, and
`none` for a refusal, `some none` for no string and `some (some range)` for
the string found. -/
@[extern "editor_glue_snapshot_quoted"]
private opaque Snapshot.quotedRaw (snapshot : @& Snapshot) (tag : UInt8) (offset : USize) :
    IO (Option (Option ByteRange))

/-- The bracket of the kind `bracket` that the walk from the byte offset
`offset` of the snapshot leaves unbalanced: an opening one when `opening`,
strictly after the offset when `forward` and before it otherwise, counting
only the brackets whose escapedness is `escaped`, and passing over those Vim
guesses are quoted when `skipQuoted`. The rule is the library's
(`crates/editor-text`; `Editor/Text.lean`, "Pairs"). `none` unless the offset
is a position of the text; `some none` when there is no such bracket. -/
def Snapshot.unmatched (snapshot : Snapshot) (bracket : Bracket)
    (opening forward escaped skipQuoted : Bool) (offset : USize) : IO (Option (Option UInt64)) :=
  snapshot.unmatchedRaw bracket.tag opening forward escaped skipQuoted offset

/-- The quoted string of `quote` round the byte offset `offset` of the
snapshot, in its row, from its opening quote's start to its closing quote's
end, by the library's rule. `none` unless the offset is a position of the
text; `some none` when a quote is missing. -/
def Snapshot.quoted (snapshot : Snapshot) (quote : Quote) (offset : USize) :
    IO (Option (Option ByteRange)) :=
  snapshot.quotedRaw quote.tag offset

/-- What a search of a snapshot answers (`Snapshot.search`). -/
inductive SearchAnswer where
  /-- The match, and whether the search wrapped round the text to find it. -/
  | found (range : ByteRange) (wrapped : Bool)
  /-- The text has no match. -/
  | notFound
  /-- The pattern is none the syntax takes, for `reason`. -/
  | invalid (reason : String)
  /-- The offset is not a position of the text. -/
  | badPosition
  deriving DecidableEq, Repr

/-- What the matches in a range of a snapshot answer (`Snapshot.matches`). -/
inductive MatchesAnswer where
  /-- The matches, in order. -/
  | ranges (all : Array ByteRange)
  /-- The pattern is none the syntax takes, for `reason`. -/
  | invalid (reason : String)
  /-- The range is not two positions of the text in order. -/
  | badRange
  deriving DecidableEq, Repr

/-- `Snapshot.search` as it crosses: the pattern, the direction and the
offset in, and words out. The status is 0 answered, with the words a
presence (1 found, 0 not), the match's two offsets and whether it wrapped;
1 for an offset that is not a position, with no words; and 2 for a pattern
the syntax refuses, with the words the bytes of the sentence that says
why, in UTF-8, and not words. -/
@[extern "editor_glue_snapshot_search"]
private opaque Snapshot.searchRaw (snapshot : @& Snapshot) (pattern : @& String) (forward : Bool)
    (offset : USize) : IO RawWords

/-- `Snapshot.matches` as it crosses: the pattern and the range in, and
words out. The status is 0 answered, with the words the count of matches
and then the two offsets of each; 1 for a range that is not two positions in
order; and 2 for a pattern the syntax refuses, as for `searchRaw`. -/
@[extern "editor_glue_snapshot_matches"]
private opaque Snapshot.matchesRaw (snapshot : @& Snapshot) (pattern : @& String)
    (start stop : USize) : IO RawWords

/-- The sentence a status of 2 carries in its bytes. Bytes that are not
UTF-8 mean the library is wrong, which is an `IO` error. -/
private def reasonOf (bytes : ByteArray) : IO String :=
  match String.fromUTF8? bytes with
  | some reason => return reason
  | none => throw (IO.userError "the library's reason for refusing a pattern is not UTF-8")

/-- The match of `pattern` a search of the snapshot's text from `offset`
answers, forward when `forward` and back otherwise: the rule is the
library's (`crates/editor-search`; `Editor/Text.lean`, "Search"). The call
keeps nothing in the library: the pattern is compiled for it. A status or
words the library cannot have answered are an `IO` error. -/
def Snapshot.search (snapshot : Snapshot) (pattern : String) (forward : Bool) (offset : USize) :
    IO SearchAnswer := do
  let raw ← snapshot.searchRaw pattern forward offset
  match raw.status with
  | 0 =>
    match wordsOf? raw.words with
    | some #[0, 0, 0, 0] =>
      return .notFound
    | some #[1, start, stop, wrapped] =>
      return .found ⟨start, stop⟩ (wrapped != 0)
    | _ =>
      throw (IO.userError "the library's words do not spell a search's answer")
  | 1 =>
    return .badPosition
  | 2 =>
    return .invalid (← reasonOf raw.words)
  | _ =>
    throw (IO.userError "the library answered a search with a status it has none of")

/-- The matches of `pattern` in the snapshot's text that start from `start`
up to `stop`, in order, as `search` answers one. -/
def Snapshot.matches (snapshot : Snapshot) (pattern : String) (start stop : USize) :
    IO MatchesAnswer := do
  let raw ← snapshot.matchesRaw pattern start stop
  match raw.status with
  | 0 =>
    let ranges? : Option (Array ByteRange) := do
      let words ← wordsOf? raw.words
      let count ← words[0]?
      guard (words.size == 1 + 2 * count.toNat)
      return (Array.range count.toNat).map fun index =>
          ⟨words[1 + 2 * index]!, words[2 + 2 * index]!⟩
    match ranges? with
    | some all =>
      return .ranges all
    | none =>
      throw (IO.userError "the library's words do not spell the matches in a range")
  | 1 =>
    return .badRange
  | 2 =>
    return .invalid (← reasonOf raw.words)
  | _ =>
    throw (IO.userError "the library answered the matches in a range with a status it has none of")

/-- The type behind `SyntaxQuery`. It is opaque, so the only way to get a
query is `SyntaxQuery.new`. -/
opaque SyntaxQueryPointed : NonemptyType

/-- A query of the library's syntax service (`crates/editor-ffi`,
`src/syntax.rs`), compiled for one grammar: a handle. -/
def SyntaxQuery : Type :=
  SyntaxQueryPointed.type

instance : Nonempty SyntaxQuery :=
  SyntaxQueryPointed.property

/-- A list of strings as the glue builds it in one call: words, the count
and then the byte length of each, and one string of all of them end to end.
Object fields only, so the order here is the layout the glue writes. -/
private structure RawStrings where
  /-- The words, copied from the library's buffer. -/
  words : ByteArray
  /-- Every string end to end, copied from the library's buffer. -/
  text : String

/-- The strings `raw` holds, or `none` when its words do not spell a list of
them: a count and that many lengths, which add up to the text and end
between characters. -/
private def RawStrings.strings? (raw : RawStrings) : Option (Array String) := do
  let words ← wordsOf? raw.words
  let count := (← words[0]?).toNat
  guard (words.size == 1 + count)
  let bytes := raw.text.toUTF8
  let (strings, stop) ←
    (words.extract 1 words.size).foldlM
        (fun (strings, start) length => do
          let stop := start + length.toNat
          guard (stop ≤ bytes.size)
          let string ← String.fromUTF8? (bytes.extract start stop)
          return (strings.push string, stop))
        (#[], 0)
  guard (stop == bytes.size)
  return strings

/-- `syntaxGrammars` as it crosses. -/
@[extern "editor_glue_syntax_grammars"]
private opaque syntaxGrammarsRaw : IO RawStrings

/-- The grammars the library's syntax service has, by name. Words that do
not spell a list of strings mean the decoder here is wrong: an `IO`
error. -/
def syntaxGrammars : IO (Array String) := do
  let some names := (← syntaxGrammarsRaw).strings?
    | throw (IO.userError "the library's words do not spell a list of grammars")
  return names

/-- Why the syntax service did not attach a document. -/
inductive SyntaxAttachRefusal where
  /-- No grammar of that name. -/
  | unknownGrammar
  /-- The snapshot is of no document, or its document is gone. -/
  | noDocument
  /-- The library could not start its worker thread. -/
  | noWorker
  deriving DecidableEq, Repr

/-- `syntaxAttach` as it crosses: 0 attached, 1 unknown grammar, 2 no
document, 3 no worker. -/
@[extern "editor_glue_syntax_attach"]
private opaque syntaxAttachRaw (snapshot : @& Snapshot) (grammar : @& String) : IO UInt64

/-- Has the library's syntax service parse the document `snapshot` is of
with `grammar` from now on, off the editor thread, in place of any grammar
before. A status the library has no word for is an `IO` error. -/
def syntaxAttach (snapshot : Snapshot) (grammar : String) : IO (Except SyntaxAttachRefusal Unit) :=
  do
  match ← syntaxAttachRaw snapshot grammar with
  | 0 =>
    return .ok ()
  | 1 =>
    return .error .unknownGrammar
  | 2 =>
    return .error .noDocument
  | 3 =>
    return .error .noWorker
  | status =>
    throw (IO.userError s!"the library answered an attach with the status {status}")

/-- Stops the syntax service parsing the document `snapshot` is of, and
returns whether it was parsing it. -/
@[extern "editor_glue_syntax_detach"]
opaque syntaxDetach (snapshot : @& Snapshot) : IO Bool

/-- Why a query was not made. -/
inductive SyntaxQueryRefusal where
  /-- No grammar of that name. -/
  | unknownGrammar
  /-- The source is not a query: the library's tag of why (0 syntax, 1 node
  type, 2 field, 3 capture, 4 predicate, 5 structure, 6 language), and the
  byte offset into the source where it found it. -/
  | refused (kind offset : UInt64)
  deriving DecidableEq, Repr

/-- A query made, as the glue builds it in one call: the handle, if made,
first, then the status, the kind and the offset. -/
private structure RawSyntaxQuery where
  /-- The handle, when made. -/
  query : Option SyntaxQuery
  /-- 0 made, 1 unknown grammar, 2 refused. -/
  status : UInt64
  /-- For a refusal, the tag of why. -/
  kind : UInt64
  /-- For a refusal, the byte offset where it was found. -/
  offset : UInt64

/-- `SyntaxQuery.new` as it crosses. -/
@[extern "editor_glue_syntax_query_new"]
private opaque SyntaxQuery.newRaw (grammar : @& String) (source : @& String) : IO RawSyntaxQuery

/-- `source` compiled as a query of `grammar`, or why not. A record the
library could not have filled is an `IO` error. -/
def SyntaxQuery.new (grammar source : String) : IO (Except SyntaxQueryRefusal SyntaxQuery) := do
  let raw ← SyntaxQuery.newRaw grammar source
  match raw.status, raw.query with
  | 0, some query =>
    return .ok query
  | 1, none =>
    return .error .unknownGrammar
  | 2, none =>
    return .error (.refused raw.kind raw.offset)
  | status, _ =>
    throw (IO.userError s!"the library answered a query with the status {status}")

/-- `SyntaxQuery.captureNames` as it crosses. -/
@[extern "editor_glue_syntax_capture_names"]
private opaque SyntaxQuery.captureNamesRaw (query : @& SyntaxQuery) : IO RawStrings

/-- The names of the query's captures, in the order they first appear in its
source. -/
def SyntaxQuery.captureNames (query : SyntaxQuery) : IO (Array String) := do
  let some names := (← query.captureNamesRaw).strings?
    | throw (IO.userError "the library's words do not spell a list of capture names")
  return names

/-- How many queries the library holds that have not been freed. -/
@[extern "editor_glue_syntax_query_live"]
opaque SyntaxQuery.live : IO UInt64

/-- One capture, as the library answers it: its pattern, its capture's index
among the query's names, and the range of its node. -/
structure SyntaxCapture where
  /-- The index of the pattern that matched. -/
  pattern : UInt64
  /-- The index of the capture's name. -/
  capture : UInt64
  /-- The offset its node starts at. -/
  start : UInt64
  /-- The offset its node stops at. -/
  stop : UInt64
  deriving DecidableEq, Repr

/-- Why the syntax service did not answer a question of captures. -/
inductive SyntaxCapturesRefusal where
  /-- The snapshot's document is not attached. -/
  | notAttached
  /-- No tree of the snapshot's revision has been delivered yet. -/
  | notParsed
  /-- The query is of another grammar than the document is parsed with. -/
  | wrongGrammar
  /-- The range is not two positions of the snapshot's text in order. -/
  | badRange
  deriving DecidableEq, Repr

/-- The captures `words` spell: the count, then four words each. `none`
unless the count is the count of captures there. -/
private def capturesOf? (words : Array UInt64) : Option (Array SyntaxCapture) := do
  let count := (← words[0]?).toNat
  guard (words.size == 1 + 4 * count)
  return (Array.range count).map fun index =>
      { pattern := words[1 + 4 * index]!, capture := words[2 + 4 * index]!,
        start := words[3 + 4 * index]!, stop := words[4 + 4 * index]! }

/-- `syntaxCaptures` as it crosses: the captures as words with the status
0, or no words and the status of the refusal (1 not attached, 2 not
parsed, 3 wrong grammar, 4 bad range). -/
@[extern "editor_glue_syntax_captures"]
private opaque syntaxCapturesRaw (snapshot : @& Snapshot) (query : @& SyntaxQuery)
    (start stop : USize) : IO RawWords

/-- The captures of `query` whose node is in the range from `start` to
`stop` of `snapshot`'s text, each once, by start, the longer first, then by
pattern and by capture: answered at once from the tree the library last
delivered of the snapshot's document, and refused as `notParsed` when that
tree is not of the snapshot's revision. It never waits for a parse. A status
or words the decoder here cannot read are an `IO` error. -/
def syntaxCaptures (snapshot : Snapshot) (query : SyntaxQuery) (start stop : USize) :
    IO (Except SyntaxCapturesRefusal (Array SyntaxCapture)) := do
  let raw ← syntaxCapturesRaw snapshot query start stop
  match raw.status with
  | 0 =>
    match (wordsOf? raw.words).bind capturesOf? with
    | some captures =>
      return .ok captures
    | none =>
      throw (IO.userError "the library's words do not spell captures")
  | 1 =>
    return .error .notAttached
  | 2 =>
    return .error .notParsed
  | 3 =>
    return .error .wrongGrammar
  | 4 =>
    return .error .badRange
  | status =>
    throw (IO.userError s!"the library answered captures with the status {status}")

/-- Why the library shipped no query. -/
inductive SyntaxShippedRefusal where
  /-- No grammar of that name. -/
  | unknownGrammar
  /-- The grammar is published with no query of that kind. -/
  | noShippedQuery
  deriving DecidableEq, Repr

/-- A shipped query as the glue builds it in one call: the source, empty
for a refusal, then the status. -/
private structure RawShipped where
  /-- The source, copied from the library's buffer. -/
  source : String
  /-- 0 shipped, 1 unknown grammar, 2 no such query. -/
  status : UInt64

/-- `syntaxShippedQuery` as it crosses. -/
@[extern "editor_glue_syntax_shipped_query"]
private opaque syntaxShippedQueryRaw (grammar : @& String) (kind : UInt8) : IO RawShipped

/-- The source of the query of the kind `kind` tags (0, highlights) that
`grammar` is published with, or why not. A status the library has no word
for is an `IO` error. -/
def syntaxShippedQuery (grammar : String) (kind : UInt8) :
    IO (Except SyntaxShippedRefusal String) := do
  let raw ← syntaxShippedQueryRaw grammar kind
  match raw.status with
  | 0 =>
    return .ok raw.source
  | 1 =>
    return .error .unknownGrammar
  | 2 =>
    return .error .noShippedQuery
  | status =>
    throw (IO.userError s!"the library answered a shipped query with the status {status}")

/-- Why the library did not highlight a document. -/
inductive SyntaxHighlightRefusal where
  /-- The snapshot's document is not attached. -/
  | notAttached
  /-- The query is of another grammar than the document is parsed with. -/
  | wrongGrammar
  /-- The faces are not one for each of the query's capture names. -/
  | badFaces
  deriving DecidableEq, Repr

/-- `syntaxHighlight` as it crosses: the faces as words and one string, and
the status (0 highlighted, 1 not attached, 2 wrong grammar, 3 bad faces). -/
@[extern "editor_glue_syntax_highlight"]
private opaque syntaxHighlightRaw (snapshot : @& Snapshot) (query : @& SyntaxQuery)
    (words : @& ByteArray) (strings : @& String) : IO UInt64

/-- Has the library draw the document `snapshot` is of with `query`'s
captures in `faces`, one for each capture name, from now on, the empty
string for a capture that draws nothing. A status the library has no word
for is an `IO` error. -/
def syntaxHighlight (snapshot : Snapshot) (query : SyntaxQuery) (faces : Array String) :
    IO (Except SyntaxHighlightRefusal Unit) := do
  match ← syntaxHighlightRaw snapshot query (lengthWords faces) (faces.foldl (· ++ ·) "") with
  | 0 =>
    return .ok ()
  | 1 =>
    return .error .notAttached
  | 2 =>
    return .error .wrongGrammar
  | 3 =>
    return .error .badFaces
  | status =>
    throw (IO.userError s!"the library answered a highlight with the status {status}")

/-- Why the library did not take an injections query. -/
inductive SyntaxInjectRefusal where
  /-- The snapshot's document is not attached. -/
  | notAttached
  /-- The query is of another grammar than the document is parsed with. -/
  | wrongGrammar
  deriving DecidableEq, Repr

/-- `syntaxInject` as it crosses: the status (0 injected, 1 not attached, 2
wrong grammar). -/
@[extern "editor_glue_syntax_inject"]
private opaque syntaxInjectRaw (snapshot : @& Snapshot) (query : @& SyntaxQuery) : IO UInt64

/-- Has the library find the injections of the document `snapshot` is of
with `query` from its next round on. A status the library has no word for
is an `IO` error. -/
def syntaxInject (snapshot : Snapshot) (query : SyntaxQuery) :
    IO (Except SyntaxInjectRefusal Unit) := do
  match ← syntaxInjectRaw snapshot query with
  | 0 =>
    return .ok ()
  | 1 =>
    return .error .notAttached
  | 2 =>
    return .error .wrongGrammar
  | status =>
    throw (IO.userError s!"the library answered an injection with the status {status}")

/-- Why the library did not take a language for injections. -/
inductive SyntaxInjectLanguageRefusal where
  /-- The snapshot's document is not attached. -/
  | notAttached
  /-- The injections query is of another grammar than the highlights
  query. -/
  | wrongGrammar
  /-- The faces are not one for each of the highlights query's capture
  names. -/
  | badFaces
  deriving DecidableEq, Repr

/-- `syntaxInjectLanguage` as it crosses: the name, the highlights query,
its faces as words and one string, and the injections query or none; the
status (0 injected, 1 not attached, 2 wrong grammar, 3 bad faces). -/
@[extern "editor_glue_syntax_inject_language"]
private opaque syntaxInjectLanguageRaw (snapshot : @& Snapshot) (name : @& String)
    (highlights : @& SyntaxQuery) (words : @& ByteArray) (strings : @& String)
    (injections : @& Option SyntaxQuery) : IO UInt64

/-- Has the library parse an injection of the language `name` in the
document `snapshot` is of with `highlights`' grammar, draw it with its
captures in `faces` (one for each capture name, the empty string for none),
and find injections of its own with `injections`, from its next round on. A
status the library has no word for is an `IO` error. -/
def syntaxInjectLanguage (snapshot : Snapshot) (name : String) (highlights : SyntaxQuery)
    (faces : Array String) (injections : Option SyntaxQuery) :
    IO (Except SyntaxInjectLanguageRefusal Unit) := do
  let faceWords := lengthWords faces
  let strings := faces.foldl (· ++ ·) ""
  match ← syntaxInjectLanguageRaw snapshot name highlights faceWords strings injections with
  | 0 =>
    return .ok ()
  | 1 =>
    return .error .notAttached
  | 2 =>
    return .error .wrongGrammar
  | 3 =>
    return .error .badFaces
  | status =>
    throw (IO.userError s!"the library answered a language with the status {status}")

/-- Why the library did not keep a query. -/
inductive SyntaxKeepRefusal where
  /-- The snapshot's document is not attached. -/
  | notAttached
  /-- The query is of another grammar than the document is parsed with. -/
  | wrongGrammar
  deriving DecidableEq, Repr

/-- `syntaxKeep` as it crosses: the kind as its tag, and the status (0
kept, 1 not attached, 2 wrong grammar, 3 no such kind). -/
@[extern "editor_glue_syntax_keep"]
private opaque syntaxKeepRaw (snapshot : @& Snapshot) (kind : UInt8) (query : @& SyntaxQuery) :
    IO UInt64

/-- Has the document `snapshot` is of keep `query` as its query of the kind
`kind` tags (0 highlights, 1 injections, 2 text objects, 3 indents). A kind
the library has no tag for, or a status it has no word for, is an `IO`
error. -/
def syntaxKeep (snapshot : Snapshot) (kind : UInt8) (query : SyntaxQuery) :
    IO (Except SyntaxKeepRefusal Unit) := do
  match ← syntaxKeepRaw snapshot kind query with
  | 0 =>
    return .ok ()
  | 1 =>
    return .error .notAttached
  | 2 =>
    return .error .wrongGrammar
  | status =>
    throw (IO.userError s!"the library answered a keep with the status {status}")

/-- Why the library did not answer a question of a kept query. -/
inductive SyntaxKeptRefusal where
  /-- The snapshot's document is not attached. -/
  | notAttached
  /-- The document keeps no query of that kind. -/
  | noQuery
  /-- The range is not two positions of the snapshot's text in order. -/
  | badRange
  /-- No tree of the snapshot's revision has been delivered yet. -/
  | notParsed
  deriving DecidableEq, Repr

/-- The refusal a kept query's status says, or `none` for a status the
library has no word for (1 not attached, 2 no query, 3 bad range, 4 not
parsed). -/
private def keptRefusal? : UInt64 → Option SyntaxKeptRefusal
  | 1 => some .notAttached
  | 2 => some .noQuery
  | 3 => some .badRange
  | 4 => some .notParsed
  | _ => none

/-- A kept query's names as the glue builds them in one call: the names,
none for a refusal, then the status. -/
private structure RawKeptNames where
  /-- The names. -/
  names : RawStrings
  /-- 0 answered, or the refusal's status. -/
  status : UInt64

/-- `syntaxKeptNames` as it crosses. -/
@[extern "editor_glue_syntax_kept_names"]
private opaque syntaxKeptNamesRaw (snapshot : @& Snapshot) (kind : UInt8) : IO RawKeptNames

/-- The capture names of the query the document `snapshot` is of keeps of
the kind `kind` tags, or why not. A status or words the decoder here cannot
read are an `IO` error. -/
def syntaxKeptNames (snapshot : Snapshot) (kind : UInt8) :
    IO (Except SyntaxKeptRefusal (Array String)) := do
  let raw ← syntaxKeptNamesRaw snapshot kind
  if raw.status == 0 then
    let some names := raw.names.strings?
      | throw (IO.userError "the library's words do not spell a list of capture names")
    return .ok names
  match keptRefusal? raw.status with
  | some refusal =>
    return .error refusal
  | none =>
    throw (IO.userError s!"the library answered kept names with the status {raw.status}")

/-- `syntaxKeptCaptures` as it crosses: the captures as words with the
status 0, or no words and the refusal's status. -/
@[extern "editor_glue_syntax_kept_captures"]
private opaque syntaxKeptCapturesRaw (snapshot : @& Snapshot) (kind : UInt8) (start stop : USize) :
    IO RawWords

/-- The captures of the query the document `snapshot` is of keeps of the
kind `kind` tags, in the range from `start` to `stop` of its text, in the
order `syntaxCaptures` answers: answered at once from the tree the library
last delivered, and refused as `notParsed` when that tree is not of the
snapshot's revision. It never waits for a parse. A status or words the
decoder here cannot read are an `IO` error. -/
def syntaxKeptCaptures (snapshot : Snapshot) (kind : UInt8) (start stop : USize) :
    IO (Except SyntaxKeptRefusal (Array SyntaxCapture)) := do
  let raw ← syntaxKeptCapturesRaw snapshot kind start stop
  if raw.status == 0 then
    match (wordsOf? raw.words).bind capturesOf? with
    | some captures =>
      return .ok captures
    | none =>
      throw (IO.userError "the library's words do not spell captures")
  match keptRefusal? raw.status with
  | some refusal =>
    return .error refusal
  | none =>
    throw (IO.userError s!"the library answered kept captures with the status {raw.status}")

/-- For tests: waits up to `boundMs` milliseconds for the library to deliver
a tree of `snapshot`'s revision, or a newer one, with layers found with the
injections as they are now, and returns whether it did.
It blocks in the library and does not sleep; `false` at once for a document
that is not attached. -/
@[extern "editor_glue_syntax_settle"]
opaque syntaxSettle (snapshot : @& Snapshot) (boundMs : UInt64) : IO Bool

/-- How a child the process service ran ended. -/
inductive ProcessExit where
  /-- It exited with this status. -/
  | code (n : UInt64)
  /-- It was ended by this signal. -/
  | signal (n : UInt64)
  deriving DecidableEq, Repr

/-- One of a child's output streams. -/
inductive ProcessStream where
  /-- Its standard output. -/
  | out
  /-- Its standard error. -/
  | err
  deriving DecidableEq, Repr

/-- What a run of the process service came to. Every refusal carries the
platform's words, naming the program and the directory. -/
inductive ProcessResult where
  /-- The child ran to its end, with both its streams. -/
  | ran (exit : ProcessExit) (stdout stderr : ByteArray)
  /-- The directory is not absolute. -/
  | relativeDirectory (detail : String)
  /-- The program names a directory and is not absolute. -/
  | relativeProgram (detail : String)
  /-- The program, or the directory, is not there. -/
  | notFound (detail : String)
  /-- The platform does not allow it. -/
  | denied (detail : String)
  /-- `stream` had more than `limit` bytes, and the child's group was
  killed. -/
  | outputTooLarge (stream : ProcessStream) (limit : UInt64)
  /-- The service has shut down. -/
  | shutDown (detail : String)
  /-- Anything else. -/
  | failed (detail : String)
  deriving DecidableEq

/-- The result a status, words, a detail and the two streams spell, by the
table in the module docs of `crates/editor-ffi/src/processes.rs`. An error,
with what was wrong, for a status the table does not have and for words that
are not the status's.

It is public for `FfiTest`, which decodes literal words with it; the bindings
call it from `processesTake` and nowhere else. -/
def ProcessResult.decode (status : UInt64) (words : ByteArray) (detail : String)
    (stdout stderr : ByteArray) : Except String ProcessResult := do
  let some words := wordsOf? words | throw "its words are not whole words"
  match status, words.toList with
  | 0, [0, code] =>
    return .ran (.code code) stdout stderr
  | 0, [1, signal] =>
    return .ran (.signal signal) stdout stderr
  | 1, [] =>
    return .relativeDirectory detail
  | 2, [] =>
    return .relativeProgram detail
  | 3, [] =>
    return .notFound detail
  | 4, [] =>
    return .denied detail
  | 5, [0, limit] =>
    return .outputTooLarge .out limit
  | 5, [1, limit] =>
    return .outputTooLarge .err limit
  | 6, [] =>
    return .shutDown detail
  | 7, [] =>
    return .failed detail
  | status, words =>
    throw s!"the status {status} with the words {words} is no process result"

/-- `processesRun` as it crosses: the command as words and one string. -/
@[extern "editor_glue_processes_run"]
private opaque processesRunRaw (id : UInt64) (words : @& ByteArray) (strings : @& String) : IO Bool

/-- A run's command and limit as they cross: the words, the limit, whether to
clear, and the count and byte lengths of each list of texts, and one string
of every text end to end. -/
private def runLayout (program : String) (arguments : Array String) (clear : Bool)
    (set : Array (String × String)) (unset : Array String) (directory : String) (limit : UInt64) :
    ByteArray × String :=
  let size (text : String) := text.utf8ByteSize.toUInt64
  let words := pushWord (pushWord ByteArray.empty limit) (if clear then 1 else 0)
  let words :=
    arguments.foldl (fun words argument => pushWord words (size argument))
      (pushWord words arguments.size.toUInt64)
  let words :=
    set.foldl (fun words (name, value) => pushWord (pushWord words (size name)) (size value))
      (pushWord words set.size.toUInt64)
  let words :=
    unset.foldl (fun words name => pushWord words (size name)) (pushWord words unset.size.toUInt64)
  let words := pushWord (pushWord words (size program)) (size directory)
  let strings :=
    arguments.foldl (· ++ ·) "" ++ set.foldl (fun all (name, value) => all ++ name ++ value) "" ++
      unset.foldl (· ++ ·) "" ++
      program ++
      directory
  (words, strings)

/-- Asks the library's process service to run `program` with `arguments` in
`directory`, with the editor's environment emptied first if `clear` is set,
then with `unset` removed and `set` applied, collecting each output stream
unless it is longer than `limit` bytes, as the run `id`, and returns whether
it was accepted. It returns at once. The completion is a `completion` event
on the completion queue, from the library source 3, whose code is `id`;
there is none if the run is cancelled first. The result is then taken with
`processesTake`.

The command crosses as words, the limit, whether to clear, and the count and
byte lengths of each list of texts, and as one string of every text end to
end, in the layout of the module docs of `crates/editor-ffi/src/processes.rs`.
`false`, with nothing started, if `id` is in use or the service could not
start the run's thread; the words this builds are always readable. -/
def processesRun (id : UInt64) (program : String) (arguments : Array String) (clear : Bool)
    (set : Array (String × String)) (unset : Array String) (directory : String) (limit : UInt64) :
    IO Bool :=
  let (words, strings) := runLayout program arguments clear set unset directory limit
  processesRunRaw id words strings

/-- `processesRunInput` as it crosses: a run's words and string, and the
input's bytes. -/
@[extern "editor_glue_processes_run_input"]
private opaque processesRunInputRaw (id : UInt64) (words : @& ByteArray) (strings : @& String)
    (input : @& ByteArray) : IO Bool

/-- Asks the library's process service to run a command as `processesRun`
does, with `input` as the child's standard input, followed by end of file.
The bytes are copied. A child that does not read them is no refusal: the
run answers what it did. -/
def processesRunInput (id : UInt64) (program : String) (arguments : Array String) (clear : Bool)
    (set : Array (String × String)) (unset : Array String) (directory : String) (limit : UInt64)
    (input : ByteArray) : IO Bool :=
  let (words, strings) := runLayout program arguments clear set unset directory limit
  processesRunInputRaw id words strings input

/-- `processesOpen` as it crosses: the open's three words and a run's words,
and one string. -/
@[extern "editor_glue_processes_open"]
private opaque processesOpenRaw (id : UInt64) (words : @& ByteArray) (strings : @& String) : IO Bool

/-- Asks the library's process service to start `program` as a streaming
child named `id`, its standard input piped if `input`, and each output
stream framed as bytes if `stdoutBytes` or `stderrBytes` says so and as
lines otherwise, holding up to `bound` bytes of each stream read and not
taken; the rest is as `processesRun`'s. It returns at once, and whether the
open was accepted. Its reply is taken with `processesTakeStream id` once `id`
is completed.

The words are the input and the two framings, then a run's words with the
bound for the limit, in the layout of the module docs of
`crates/editor-ffi/src/processes.rs`. -/
def processesOpen (id : UInt64) (input stdoutBytes stderrBytes : Bool) (program : String)
    (arguments : Array String) (clear : Bool) (set : Array (String × String)) (unset : Array String)
    (directory : String) (bound : UInt64) : IO Bool :=
  let flag (value : Bool) : UInt64 := if value then 1 else 0
  let lead :=
    pushWord (pushWord (pushWord .empty (flag input)) (flag stdoutBytes)) (flag stderrBytes)
  let (words, strings) := runLayout program arguments clear set unset directory bound
  processesOpenRaw id (lead ++ words) strings

/-- Asks for the next delivery of the streaming child `child`, as the wait
`wait`. It returns at once: false for a child the service does not hold, a
wait id in use, or a read already pending. The delivery is taken with
`processesTakeStream wait` once `wait` is completed, which is once however
much the child writes. -/
@[extern "editor_glue_processes_read"]
opaque processesRead (child wait : UInt64) : IO Bool

/-- Asks for `bytes` to be written to the standard input of the child
`child`, as the wait `wait`, and returns at once; false as for
`processesRead`. The bytes are copied. -/
@[extern "editor_glue_processes_write"]
opaque processesWrite (child wait : UInt64) (bytes : @& ByteArray) : IO Bool

/-- Closes the standard input of the child `child`, as the wait `wait`,
completed at once. -/
@[extern "editor_glue_processes_close_input"]
opaque processesCloseInput (child wait : UInt64) : IO Bool

/-- Whether the readers of the child `child` are held at its bound: 0 no, 1
yes, 2 no such child. A readout for tests. -/
@[extern "editor_glue_processes_held"]
opaque processesHeld (child : UInt64) : IO UInt64

/-- A process result as the glue builds it, in one call: the object fields
first and the `UInt64` field after them, so the order here is the layout the
glue writes. -/
private structure RawProcessResult where
  /-- The words, copied from the library's buffer. -/
  words : ByteArray
  /-- The detail, copied from the library's buffer. -/
  detail : String
  /-- The standard output, copied from the library's buffer. -/
  stdout : ByteArray
  /-- The standard error, copied from the library's buffer. -/
  stderr : ByteArray
  /-- How the run ended: the library's status. -/
  status : UInt64

/-- `processesTake` before its result is decoded. -/
@[extern "editor_glue_processes_take"]
private opaque processesTakeRaw (id : UInt64) : IO (Option RawProcessResult)

/-- Hands over the result of the run `id`, once. `none` when the service
keeps no result for `id`: it has not ended, it was cancelled, its result was
taken already, or it was another service's id. It throws if the library
sends a result these bindings cannot read. -/
def processesTake (id : UInt64) : IO (Option ProcessResult) := do
  let some raw ← processesTakeRaw id | return none
  match ProcessResult.decode raw.status raw.words raw.detail raw.stdout raw.stderr with
  | .ok result =>
    return some result
  | .error reason =>
    throw (IO.userError s!"the library's process result could not be read: {reason}")

/-- How a streaming child's stream crosses in a delivery. -/
inductive StreamFrames where
  /-- Whole lines. -/
  | lines (lines : Array ByteArray)
  /-- Bytes. -/
  | bytes (bytes : ByteArray)
  deriving DecidableEq

/-- How a streaming child ended, as its last delivery crosses. -/
inductive StreamEnd where
  /-- It exited so, every frame delivered. -/
  | exited (exit : ProcessExit)
  /-- A line of `stream` was longer than `bound`. -/
  | lineTooLong (stream : ProcessStream) (bound : UInt64)
  /-- A read failed; `detail` says how. -/
  | failed (detail : String)
  deriving DecidableEq

/-- What a request about a streaming child came to. -/
inductive StreamReply where
  /-- The child was started. -/
  | opened
  /-- A read's delivery: each stream's frames, and in the last one how the
  child ended. -/
  | delivered (stdout stderr : StreamFrames) (ended : Option StreamEnd)
  /-- The bytes are in the child's input, or it was closed. -/
  | written
  /-- The child's input is closed. -/
  | inputClosed (detail : String)
  /-- Refused as a run is refused: a run's result that is a refusal. -/
  | refused (refusal : ProcessResult)
  deriving DecidableEq

/-- A stream's frames read off the front of `values`, with `bytes` its
buffer: for lines, their count and each one's length, which must add up to
the buffer; and the words after them. -/
private def streamFramesOf? : List UInt64 → ByteArray → Option (StreamFrames × List UInt64)
  | 1 :: rest, bytes => some (.bytes bytes, rest)
  | 0 :: count :: rest, bytes =>
    let lengths := rest.take count.toNat
    if lengths.length != count.toNat || lengths.foldl (· + ·.toNat) 0 != bytes.size then none
    else
      let (lines, _) :=
        lengths.foldl (init := ((#[] : Array ByteArray), 0)) fun (lines, start) length =>
          (lines.push (bytes.extract start (start + length.toNat)), start + length.toNat)
      some (.lines lines, rest.drop count.toNat)
  | _, _ => none

/-- The reply a status, words, a detail and the two buffers spell, by the
table in the module docs of `crates/editor-ffi/src/processes.rs`. An error,
with what was wrong, for a status the table does not have and for words that
are not the status's.

It is public for `FfiTest`, which decodes literal words with it; the bindings
call it from `processesTakeStream` and nowhere else. -/
def StreamReply.decode (status : UInt64) (words : ByteArray) (detail : String)
    (stdout stderr : ByteArray) : Except String StreamReply := do
  let some values := wordsOf? words | throw "its words are not whole words"
  match status, values.toList with
  | 10, [] =>
    return .opened
  | 12, [] =>
    return .written
  | 8, [] =>
    return .inputClosed detail
  | 11, values =>
    let some (out, values) := streamFramesOf? values stdout
      | throw s!"its standard output's words do not spell frames of its {stdout.size} bytes"
    let some (err, values) := streamFramesOf? values stderr
      | throw s!"its standard error's words do not spell frames of its {stderr.size} bytes"
    match values with
    | [0] =>
      return .delivered out err none
    | [1, 0, code] =>
      return .delivered out err (some (.exited (.code code)))
    | [1, 1, signal] =>
      return .delivered out err (some (.exited (.signal signal)))
    | [2, 0, bound] =>
      return .delivered out err (some (.lineTooLong .out bound))
    | [2, 1, bound] =>
      return .delivered out err (some (.lineTooLong .err bound))
    | [3] =>
      return .delivered out err (some (.failed detail))
    | values =>
      throw s!"the words {values} spell no end of a delivery"
  | status, [] =>
    if [1, 2, 3, 4, 6, 7].contains status then
      return .refused (← ProcessResult.decode status .empty detail .empty .empty)
    else
      throw s!"the status {status} is no stream reply"
  | status, values =>
    throw s!"the status {status} with the words {values} is no stream reply"

/-- `processesTakeStream` before its reply is decoded: the record of a run's
result. -/
@[extern "editor_glue_processes_take_stream"]
private opaque processesTakeStreamRaw (wait : UInt64) : IO (Option RawProcessResult)

/-- Hands over the reply of the wait `wait` on a streaming child, once.
`none` when the service keeps no reply for it. It throws if the library sends
a reply these bindings cannot read: an unknown status, or line lengths that
do not add up. -/
def processesTakeStream (wait : UInt64) : IO (Option StreamReply) := do
  let some raw ← processesTakeStreamRaw wait | return none
  match StreamReply.decode raw.status raw.words raw.detail raw.stdout raw.stderr with
  | .ok reply =>
    return some reply
  | .error reason =>
    throw (IO.userError s!"the library's stream reply could not be read: {reason}")

/-- Cancels the run `id`, killing its child's process group if the child is
running, and returns whether there was anything to cancel: a run not over or
a result not taken. It is safe for an id that is unknown. A cancelled run is
never completed; a completion that was already queued still arrives, and
its result is gone. -/
@[extern "editor_glue_processes_cancel"]
opaque processesCancel (id : UInt64) : IO Bool

/-- How many runs have a child not yet reaped, and how many results have not
been taken, together. A readout for tests, which use it to see that a
cancelled run's child was reaped. -/
@[extern "editor_glue_processes_pending"]
opaque processesPending : IO UInt64

/-- Shuts the library's process service down: kills every child's process
group and returns once every child it started has been reaped. A run asked
for later is refused as shut down. The editor's mains call it before they
quit the queues; it is safe to call again. -/
@[extern "editor_glue_processes_shutdown"]
opaque processesShutdown : IO Unit

/-- Why the watch service refused a start. -/
inductive WatchRefusal where
  /-- The path is not absolute, or has a `..` component. -/
  | notAbsolute
  /-- The directory is not there. -/
  | notFound
  /-- The path is not a directory. -/
  | notADirectory
  /-- The platform does not allow it. -/
  | denied
  /-- The system's limit on watches is reached. -/
  | limit
  /-- The service has shut down. -/
  | shutDown
  /-- Anything else. -/
  | failed
  deriving DecidableEq, Repr

/-- What a wait of the watch service came to. -/
inductive WatchReply where
  /-- A start's: the watch is live, and its id names it. -/
  | started
  /-- A start's: it was refused, with the platform's words. -/
  | refused (refusal : WatchRefusal) (detail : String)
  /-- A read's: each change's path, as its bytes, and its kinds' bits
  (created 1, written 2, renamed 4, removed 8, missed 16). -/
  | changes (changes : Array (ByteArray × UInt64))
  deriving DecidableEq

/-- The reply a status, words, a detail and the paths spell, by the table in
the module docs of `crates/editor-ffi/src/watches.rs`. An error, with what
was wrong, for a status the table does not have and for words that are not
the status's.

It is public for `FfiTest`, which decodes literal words with it; the bindings
call it from `watchesTake` and nowhere else. -/
def WatchReply.decode (status : UInt64) (words : ByteArray) (detail : String) (paths : ByteArray) :
    Except String WatchReply := do
  let some values := wordsOf? words | throw "its words are not whole words"
  match status, values.toList with
  | 0, [] =>
    return .started
  | 8, count :: rest =>
    unless rest.length == 2 * count.toNat do
      throw s!"its words do not spell {count} changes"
    let pairs := (List.range count.toNat).map fun index => (rest[2 * index]!, rest[2 * index + 1]!)
    let (found, used) :=
      pairs.foldl (init := ((#[] : Array (ByteArray × UInt64)), 0))
        fun (found, start) (length, bits) =>
        (found.push (paths.extract start (start + length.toNat), bits), start + length.toNat)
    unless used == paths.size do
      throw s!"its lengths do not add up to its {paths.size} bytes of paths"
    return .changes found
  | status, [] =>
    let refusal? : Option WatchRefusal :=
      match status with
      | 1 => some .notAbsolute
      | 2 => some .notFound
      | 3 => some .notADirectory
      | 4 => some .denied
      | 5 => some .limit
      | 6 => some .shutDown
      | 7 => some .failed
      | _ => none
    let some refusal := refusal? | throw s!"the status {status} is no watch reply"
    return .refused refusal detail
  | status, values =>
    throw s!"the status {status} with the words {values} is no watch reply"

/-- `watchesStart` as it crosses: three words and the path. -/
@[extern "editor_glue_watches_start"]
private opaque watchesStartRaw (id : UInt64) (words : @& ByteArray) (path : @& String) : IO Bool

/-- Asks the library's watch service to start the watch `id` of `path`: a
file (`target` 0), a directory's entries (1) or its tree (2), its changes
coalesced over `window` milliseconds and at most `bound` paths a delivery;
and returns whether it was accepted. It returns at once. The completion is a
`completion` event on the completion queue, from the library source 4, whose
code is `id`; its reply is then taken with `watchesTake`. `false`, with
nothing started, for a target that is none of these, an id in use, or when
the service could not start the start's thread. -/
def watchesStart (id target window bound : UInt64) (path : String) : IO Bool :=
  watchesStartRaw id (pushWord (pushWord (pushWord ByteArray.empty target) window) bound) path

/-- Asks for the next delivery of the watch `watch`, under the wait id `wait`,
and returns whether it was accepted: not for a watch that is not live, one
with a read pending, or a wait id in use. The completion is `wait`'s, and its
delivery is taken with `watchesTake wait`: every change up to the take. -/
@[extern "editor_glue_watches_next"]
opaque watchesNext (watch wait : UInt64) : IO Bool

/-- A watch reply as the glue builds it, in one call: the object fields
first and the `UInt64` field after them, so the order here is the layout the
glue writes. -/
private structure RawWatchReply where
  /-- The words, copied from the library's buffer. -/
  words : ByteArray
  /-- The detail, copied from the library's buffer. -/
  detail : String
  /-- The paths, copied from the library's buffer. -/
  paths : ByteArray
  /-- What the reply is: the library's status. -/
  status : UInt64

/-- `watchesTake` before its reply is decoded. -/
@[extern "editor_glue_watches_take"]
private opaque watchesTakeRaw (wait : UInt64) : IO (Option RawWatchReply)

/-- Hands over the reply of the wait `wait`, once. `none` when the service
keeps nothing for it. It throws if the library sends a reply these bindings
cannot read. -/
def watchesTake (wait : UInt64) : IO (Option WatchReply) := do
  let some raw ← watchesTakeRaw wait | return none
  match WatchReply.decode raw.status raw.words raw.detail raw.paths with
  | .ok reply =>
    return some reply
  | .error reason =>
    throw (IO.userError s!"the library's watch reply could not be read: {reason}")

/-- Cancels the watch or the wait `id`, and returns whether there was
anything to cancel. Cancelling a watch drops its registration once no other
watch shares it; nothing cancelled is completed. Safe for an id that is
unknown. -/
@[extern "editor_glue_watches_cancel"]
opaque watchesCancel (id : UInt64) : IO Bool

/-- How many watches are starting or live, and how many waits are not
answered or not taken, together. A readout for tests. -/
@[extern "editor_glue_watches_pending"]
opaque watchesPending : IO UInt64

/-- Shuts the library's watch service down: ends every watch. A start asked
for later is refused as shut down. The editor's mains call it before they
quit the queues; it is safe to call again. -/
@[extern "editor_glue_watches_shutdown"]
opaque watchesShutdown : IO Unit

end Editor.Ffi
