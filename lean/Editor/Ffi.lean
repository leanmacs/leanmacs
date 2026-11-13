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
a file it loaded (`filesTake`). Tests: the four counter checks of `ffi-test`
(`FfiTest.handleChecks`), its check that a document is freed
(`FfiTest.documentChecks`), its checks that a snapshot is freed and outlives
its document (`FfiTest.snapshotChecks`) and its checks that a loaded
snapshot is counted live and that a document made from a snapshot is freed
(`FfiTest.fileChecks`); `tests/c_api.rs`, `tests/snapshot.rs`,
`tests/document_from_snapshot.rs` and `tests/files.rs` in `editor-ffi`.

### Plain data

| Kind | Lean to Rust | Rust to Lean |
|---|---|---|
| String | `@& String`; the glue passes its bytes and byte length, and Rust copies what it keeps | The glue copies the library's buffer into a `String` and hands the buffer back |
| Enum | An enumeration inductive, which Lean passes as a `UInt8` tag that Rust checks | A `UInt64` tag in a private raw structure, decoded here (`EventKind.ofTag?`); an unknown tag is an `IO` error |
| Small structure | The wrapper passes the fields as scalar arguments | The glue builds the structure in one call. Declare object fields first, then `UInt64` fields and nothing else, so the declaration order is the layout the glue writes |
| Option | The wrapper passes a presence flag and a value | The glue builds `none` or `some` |
| Byte range | Two scalars | `ByteRange`: two `UInt64`, half-open, in bytes |
| List | *Words*: a `@& ByteArray` of 64-bit numbers, eight bytes each, least significant first, written by a private encoder here; the glue passes its bytes and byte length, and Rust checks every count against the buffer | The glue copies the library's buffer of words into a `ByteArray` and hands the buffer back; a private decoder here builds the typed value, and words it cannot read are an `IO` error |

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
`Snapshot.offsetOf`; rows and columns as `UInt64`). A document's
transactions and its edit log are the example of lists: a `Transaction` in,
as words and one string of everything it inserts (`Document.apply`); a
`Patch` and a trace out, as words (`Document.changesSince`,
`Document.trace`); and a refusal as a `Bool` (`Document.forget`). A
document's markers are words in both directions for one value: a `Marker`
in, as words (`Document.mark`, `Document.place`), and out, as words
(`Document.marker`); and a `Selection` in and what it covers out, both as
words (`Snapshot.extents`). A refusal with more than one reason is a status
the library reports as a number, read here into an inductive
(`MarkRefusal`). A document's kept inverses are scalars in and words out
with an option inside them: a run of revisions and an origin in, as three
numbers, and an `Inverted` out, the revision the inverse produced with the
selection it hands back if there is one (`Document.applyInverse`, with its
refusals in `InverseRefusal`); and a run in and a refusal as a `Bool`
(`Document.dropInverses`). A length or an offset in words is a `UInt64`, and the
largest one is a number no text accepts: a caller with a number no word
holds sends that, so the library refuses it and nothing is cut down. Tests:
the `find` and event checks of `ffi-test` (`FfiTest.dataChecks`), its
document checks (`FfiTest.documentChecks`), its snapshot checks
(`FfiTest.snapshotChecks`), its transaction checks
(`FfiTest.transactionChecks`), its marker checks
(`FfiTest.markerChecks`) and its inverse checks (`FfiTest.inverseChecks`);
the unit tests of `text.rs`, `document.rs`, `snapshot.rs`, `words.rs`,
`transaction.rs`, `log.rs`, `marker.rs` and `inverse.rs`, the tag tests of
`events.rs`, and `tests/log.rs`, `tests/markers.rs` and `tests/inverse.rs`
in `editor-ffi`.

The editor does not call these bindings. It reaches the library through a
port it defines (`Editor/Text.lean`), whose real binding
(`Editor/Text/Real.lean`) is the one caller of `Document` and of `Snapshot`,
and whose contract (`Editor/Text/Contract.lean`) runs against that binding in
`contract-test`.

### The event queues

Rust never calls a Lean function. Rust threads push events onto a queue, and
Lean pulls them with `nextEvent`, which blocks in Rust: call it from a
dedicated task, never from the thread pool. An event is plain data tagged with
its source. There are two queues (`Queue`): the editor queue, for input and
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

The file service is the second: `filesLoad` and `filesSave` start a request,
`filesTake` hands its result over once its completion has arrived,
`filesCancel` cancels, and `filesPending` is a readout for tests. A request
has a result, which a timer's has not, so there is one more step: the
completion says only that the request `id` is done, and the result is taken
by that id, once, as one record (`FileResult`): a loaded file's text as a
`Snapshot` handle with its stamp and its line endings, a saved file's stamp,
or a refusal (`FileRefusal`). A file's content never crosses as a Lean
string or a byte array: a load hands back a handle, and a save borrows one.
A path crosses as the bytes of a Lean string, which the library does not
decode. What a save expects on disk (`FileExpect`) crosses as a tag and a
stamp's three numbers. A stamp's seconds are an `Int`, and cross as a 64-bit
two's complement word in both directions.

The editor does not call these bindings. The job runner reaches the services
through the ports it defines (`Job.Timers`, `Editor/Job/Runner.lean`), whose
real implementations (`Editor/Job/Real.lean`) are the callers, with the
completion pump that pulls the queue on a dedicated task.

Tests: the three timer checks of `ffi-test` (`FfiTest.timerChecks`), its
file checks (`FfiTest.fileChecks`), in directories they make and remove, and
its check that the completion tag is known (`FfiTest.dataChecks`);
`contract-test`, which runs the job port's contract and the checks of the
real service through the runner (`ContractTest.jobChecks`); the unit tests
of `timers.rs` and `files.rs`, and `tests/timers.rs` and `tests/files.rs`,
in `editor-ffi`, which need no Lean.

### The window

A window is run by the library's main-thread service, and what it reports
arrives on the editor queue.

- `windowRun` is one blocking binding: it returns when the window has
  closed. Call it from Lean's main thread or a dedicated task, never from the
  thread pool. While it runs, the main-thread service answers nothing else,
  so ask `mainThreadProbe` before, not during.
- How the window is opened goes in as scalars, one for each option: today,
  whether an input method may compose. A failure to open comes back as a
  reason, in an `Except`.
- What the window reports is events from the window source, of the kinds
  from `windowOpened` on, pulled with `nextEvent` like any other. Each is
  stamped with the reading of the library's input clock when the window
  reported it, and `inputClock` reads the same clock.
- Lean closes the window. A window the user asks to close reports
  `closeRequested` and stays open until `windowClose`, which any thread may
  call.
- The platform is an enumeration (`Platform`). The scripted ones are the
  library's fake: they open nothing and need no display, and they are what
  every check runs. One reports a fixed sample; the other cannot open a
  window, so that a failure to open is seen to cross. The real one opens a
  window.

The editor does not call these bindings yet. The one caller is the keyboard
check (`Editor/WindowCheck/Real.lean`, `editor window-check`). The editor's
own port for the window, with its model and its contract, arrives with the
command loop.

Tests: the window checks of `ffi-test` (`FfiTest.windowChecks`), on the
scripted platforms: the bindings, a run that fails to open among them, and
the keyboard check's loop over them; the unit tests of `window.rs` and
`tests/window.rs`
in `editor-ffi`, which need no Lean. Nothing in the gate runs the real
platform: `mise run window-check` and `mise run window-contract` do, on
demand.

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
  key; the text is what the key produced, or empty. -/
  | key
  /-- A step of an input method's composition. The code is 0 when the input
  method became available, 1 for a change of the text being composed, 2 when
  the composition ended with a text, and 3 when the input method is no longer
  available; the text is the text composed or committed. -/
  | composition
  /-- A pointer button was pressed in the window. -/
  | pointerPressed
  /-- The user asked for the window to be closed. It stays open until Lean
  closes it. -/
  | closeRequested
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
  | 7 => some .pointerPressed
  | 8 => some .closeRequested
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
  deriving DecidableEq, Repr

/-- An event as the glue builds it, in one call: the object field first, then
`UInt64` fields only, so the order here is the layout the glue writes. The
kinds are still the library's numbers. -/
private structure RawEvent where
  /-- The event's text. -/
  text : String
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
pool. It throws if the library sends a kind these bindings do not know. -/
def nextEvent (queue : Queue) : IO Event := do
  let raw ← nextRaw queue
  let some sourceKind := SourceKind.ofTag? raw.sourceKind
    | throw <| IO.userError s!"the library sent an event from the unknown source kind {raw.sourceKind}"
  let some kind := EventKind.ofTag? raw.kind
    | throw <| IO.userError s!"the library sent an event of the unknown kind {raw.kind}"
  return { source := { kind := sourceKind, id := raw.sourceId }, kind, code := raw.code,
           text := raw.text, stamp := raw.stamp }

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
  deriving DecidableEq, Repr

/-- `windowRun` as it crosses: the glue builds `none` when the window ran and
`some` of the reason when it did not. -/
@[extern "editor_glue_window_run"]
private opaque windowRunRaw (platform : Platform) (composition : Bool) : IO (Option String)

/-- Runs the window on `platform`, with an input method allowed to compose
or not, and returns once the window has closed: `.ok ()` when it ran, and
`.error` with the reason when no window could be opened.

The library's main-thread service runs the window's loop, and this blocks
until the loop has ended, so call it from Lean's main thread or a dedicated
task, never from the thread pool. While it runs, the main-thread service
answers nothing else: `mainThreadProbe` would wait for the window to close.

What the window reports arrives on the editor queue, from the window source,
each event stamped with the reading of `inputClock` when the window reported
it. The window does not close by itself: when the user asks, a
`closeRequested` event arrives, and the window stays open until
`windowClose`. -/
def windowRun (platform : Platform) (composition : Bool) : IO (Except String Unit) := do
  match ← windowRunRaw platform composition with
  | none =>
    return .ok ()
  | some reason =>
    return .error reason

/-- Asks the window `platform` is running to close, so that `windowRun`
returns. Any thread may call it, and it does nothing when that platform runs
no window. -/
@[extern "editor_glue_window_close"]
opaque windowClose (platform : Platform) : IO Unit

/-- The time on the library's input clock, in nanoseconds since the clock
began: the clock a window's events are stamped on. It never goes back, and
it is never 0. The time from an event's stamp to this reading is how long the
event took to reach whoever reads it. -/
@[extern "editor_glue_input_clock"]
opaque inputClock : IO UInt64

end Editor.Ffi
