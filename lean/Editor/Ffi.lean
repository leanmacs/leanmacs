import Editor.Ffi.Clipboard
import Editor.Ffi.Counter
import Editor.Ffi.Diffs
import Editor.Ffi.Display
import Editor.Ffi.Excerpts
import Editor.Ffi.Files
import Editor.Ffi.Fuzzy
import Editor.Ffi.Grep
import Editor.Ffi.Interrupt
import Editor.Ffi.Inverse
import Editor.Ffi.Launch
import Editor.Ffi.Log
import Editor.Ffi.MainThread
import Editor.Ffi.Marker
import Editor.Ffi.Pair
import Editor.Ffi.Render
import Editor.Ffi.Search
import Editor.Ffi.Syntax
import Editor.Ffi.Timers
import Editor.Ffi.Watches
import Editor.Ffi.Window

/-!
# Bindings to the Rust library

The functions `editor-ffi` (`crates/editor-ffi`) exposes, as Lean
declarations. A pure function over plain numbers binds straight to its Rust
symbol. Any other function binds to a wrapper in `ffi/glue.c`, which calls the
Rust function and builds the Lean value for its result with `lean.h`.

## Modules

This module holds the conventions and imports the bindings, one module for
each module of `crates/editor-ffi/src/` that defines them, all in
`namespace Editor.Ffi`, so `import Editor.Ffi` brings every binding. It
imports each family no other family imports; the rest (`Document`,
`Snapshot`, `Transaction`, `Text`, `Events`, `Words`, and `Processes`, whose
command layout `Launch` takes) come with the families that build on them.

| Module | Binds | Conventions |
|---|---|---|
| `Editor/Ffi/Counter.lean` | `counter.rs`, and `lib.rs`'s `add` | "Handles" |
| `Editor/Ffi/MainThread.lean` | `main_thread.rs`, and the glue's stack readouts | "The window", "An exception from the interpreter ends the process" |
| `Editor/Ffi/Document.lean` | `document.rs` | "Handles", "Plain data" |
| `Editor/Ffi/Snapshot.lean` | `snapshot.rs`, and `document.rs`'s `from_snapshot` (`Document.ofSnapshot`) | "Handles", "Plain data" |
| `Editor/Ffi/Transaction.lean` | `transaction.rs` | "Plain data" |
| `Editor/Ffi/Log.lean` | `log.rs` | "Plain data" |
| `Editor/Ffi/Text.lean` | `text.rs` | "Plain data" |
| `Editor/Ffi/Marker.lean` | `marker.rs`, and `snapshot.rs`'s extents | "Plain data" |
| `Editor/Ffi/Inverse.lean` | `inverse.rs` | "Plain data" |
| `Editor/Ffi/Events.lean` | `events.rs` | "The event queues", "Shutdown" |
| `Editor/Ffi/Timers.lean` | `timers.rs` | "Services and completions" |
| `Editor/Ffi/Excerpts.lean` | `excerpts.rs` | "Plain data" |
| `Editor/Ffi/Files.lean` | `files.rs` | "Services and completions" |
| `Editor/Ffi/Diffs.lean` | `diffs.rs` | "Services and completions" |
| `Editor/Ffi/Window.lean` | `window.rs` | "The window" |
| `Editor/Ffi/Interrupt.lean` | `interrupt.rs` | "The interrupt flag" |
| `Editor/Ffi/Display.lean` | `display.rs` and `display/wire.rs` | "Handles", "Plain data" |
| `Editor/Ffi/Render.lean` | `render.rs` | "The window" |
| `Editor/Ffi/Clipboard.lean` | `clipboard.rs` | "Handles" |
| `Editor/Ffi/Fuzzy.lean` | `fuzzy.rs` | "Plain data" |
| `Editor/Ffi/Pair.lean` | `pair.rs`, through `snapshot.rs`'s externs | "Plain data" |
| `Editor/Ffi/Search.lean` | `search.rs` | "Plain data" |
| `Editor/Ffi/Syntax.lean` | `syntax.rs` | "The syntax service" |
| `Editor/Ffi/Processes.lean` | `processes.rs` | "Services and completions" |
| `Editor/Ffi/Watches.lean` | `watches.rs` | "Services and completions" |
| `Editor/Ffi/Grep.lean` | `grep.rs` | "Services and completions" |
| `Editor/Ffi/Launch.lean` | `launch.rs`: the exec and the main bundle, forwarded to the launcher's adapters (`crates/editor-launch-std`) | "Plain data" |

`Editor/Ffi/Words.lean` is the word codec the families share (`words.rs`'s
counterpart), under `Editor.Ffi.Words`; see "Plain data".

## Conventions

Every binding follows the rules below. Each rule that can have one has a small
real example in the binding modules this one imports
(`Editor/Ffi/<Family>.lean`), and each names the tests that pin it or says
that none does. This is Lean's side of each rule; Rust's side is in the crate
docs of `crates/editor-ffi/src/lib.rs`.

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
| Enum | An enumeration inductive, which Lean passes as a `UInt8` tag that Rust checks | A `UInt64` tag in a private raw structure, decoded in the family's module (`EventKind.ofTag?`); an unknown tag is an `IO` error |
| Small structure | The wrapper passes the fields as scalar arguments | The glue builds the structure in one call. Declare object fields first, then `UInt64` fields and nothing else, so the declaration order is the layout the glue writes |
| Option | The wrapper passes a presence flag and a value | The glue builds `none` or `some` |
| Optional handle | `@& Option` of a handle, which the glue passes as the handle's pointer, or null for `none` (`syntaxInjectLanguage`) | None yet |
| Byte range | Two scalars | `ByteRange`: two `UInt64`, half-open, in bytes |
| List | *Words*: a `@& ByteArray` of 64-bit numbers, eight bytes each, least significant first, written by an encoder in the family's module; the glue passes its bytes and byte length, and Rust checks every count against the buffer | The glue copies the library's buffer of words into a `ByteArray` and hands the buffer back; a decoder in the family's module builds the typed value, and words it cannot read are an `IO` error |
| List of handles | `@& Array Snapshot`, an array of handles borrowed for the call, beside the words, which name a handle by its index in it; the glue passes it as a C array of the handles' pointers and its count, which it builds for the call (`Display.publish`) | None yet |
| List of strings | Words, the count and then the byte length of each string, written by an encoder in the family's module, and one `@& String` of all of them end to end; Rust refuses lengths that do not add up to the string or that end inside a character (`fuzzyRank`, `syntaxHighlight`) | The same words and string in a private structure of two object fields the glue builds in one call, decoded in the family's module; words that do not add up to the string are an `IO` error (`syntaxGrammars`, `SyntaxQuery.captureNames`) |

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
private to its family's module; the ones families share, `RawWords` and the
word codec (`pushWord`, `wordsOf?`, `lengthWords`, `pushShaped`,
`selectionAt?`), live under `Editor.Ffi.Words` (`Editor/Ffi/Words.lean`, the
selection codec in `Editor/Ffi/Transaction.lean`), which only the bindings
open. What a caller sees is the typed value.

Examples: `find` (an option in, an option of a byte range out), `Event` with
`postEvent` and `nextEvent` (a string, enums and a structure, in both
directions), `Document` (a string in, to `Document.new` and
`Document.replace`; a string out, from `Document.read`; byte offsets as
`USize`; a refusal as a `Bool`) and `Snapshot` (a structure of three numbers
out, `SnapshotInfo`; an enumeration in, `ColumnUnit`; an option of a
structure out, from `Snapshot.pointOf`, and an option of a number, from
`Snapshot.offsetOf`; rows and columns as `UInt64`; an inductive whose
constructors carry values in, `Motion`, which a private encoder writes
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
the library reports as a number, read into an inductive
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
encoder writes, and answer an option of an option: none for a
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

The file service is the second: `filesLoad`, `filesSave`, `filesStamp`,
`filesList` and `filesMakeDirectory` start a request,
`filesTake` hands its result over once its completion has arrived,
`filesCancel` cancels, and `filesPending` is a readout for tests. A request
has a result, which a timer's has not, so there is one more step: the
completion says only that the request `id` is done, and the result is taken
by that id, once, as one record (`FileResult`): a loaded file's text as a
`Snapshot` handle with its stamp and its line endings, a saved file's stamp,
a file's stamp or none, a directory's entries (`listed`, each a name and a
kind code: 0 a file, 1 a directory, 2 anything else), a directory made
(`made`: done with no words), or a refusal
(`FileRefusal`). A listing's names cross as a list of strings does: the
count and each entry's kind and byte length as words, and the names end to
end as the detail; a name that is not UTF-8 is left out by the library,
since a Lean string cannot hold it. A file's content never crosses as a Lean
string or a byte array: a load hands back a handle, and a save borrows one.
A path crosses as the bytes of a Lean string, which the library does not
decode. What a save expects on disk (`FileExpect`) crosses as a tag and a
stamp's three numbers. A stamp's seconds are an `Int`, and cross as a 64-bit
two's complement word in both directions.

The process service is the third: `processesRun` starts a run of a command
to its end, `processesRunInput` one fed its standard input, `processesRunHead` one fed its
standard input that keeps the head of its standard output and ends the child there
(`ProcessResult.cut`), `processesTake` hands its result over once its completion has
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

The grep service is the seventh: `grepStart` starts a search of the files
under a root, as words, the root, the pattern and the overlays' paths end to
end, and a snapshot handle for each overlay, whose text is searched in place
of its file; `grepNext` asks for a search's next delivery, under a wait id of
its own; `grepTake` hands a reply over once its completion has arrived, as a
status, words, a detail and the paths end to end (`GrepReply`, decoded by
`GrepReply.decode`); `grepCancel` cancels a search or a wait, `grepShutdown`
ends every search, and `grepPending` is a readout for tests.

The editor does not call these bindings. The job runner reaches the services
through the ports it defines (`Job.Timers`, `Editor/Job/Runner.lean`), whose
real implementations (`Editor/Job/Real.lean`) are the callers, with the
completion pump that pulls the queue on a dedicated task.

Tests: the three timer checks of `ffi-test` (`FfiTest.timerChecks`), its
file checks (`FfiTest.fileChecks`), in directories they make and remove, its
process checks (`FfiTest.processChecks`), whose children run in directories
they make and remove, and
its watch checks (`FfiTest.watchChecks`) and its grep checks
(`FfiTest.grepChecks`), in directories they make and remove, its check that the completion tag is known (`FfiTest.dataChecks`);
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
a bound, for a delivery, for tests. `syntaxRefreshAfter` sets how long a
text goes unchanged after an edit before the library parses it whole.

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
  `Counter.live` in the bindings: `Main` and `FfiTest` failed to build.
- A plain constant whose value calls a binding builds. Lean evaluates it in
  the module's initialiser when the executable starts, where the symbols do
  exist, so nothing stops it. Seen once by hand, with a constant defined as
  `add 2 3`. Keeping such constants out is left to review; a list of checks
  is a function of `Unit` in `ffi-test`'s test modules (`FfiTest/`) for
  this reason.
-/
