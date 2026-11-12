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

Examples: `Counter`, and `Document`, the placeholder text the text port's real
binding holds. Tests: the four counter checks of `ffi-test`
(`FfiTest.handleChecks`) and its check that a document is freed
(`FfiTest.documentChecks`); `tests/c_api.rs` in `editor-ffi`.

### Plain data

| Kind | Lean to Rust | Rust to Lean |
|---|---|---|
| String | `@& String`; the glue passes its bytes and byte length, and Rust copies what it keeps | The glue copies the library's buffer into a `String` and hands the buffer back |
| Enum | An enumeration inductive, which Lean passes as a `UInt8` tag that Rust checks | A `UInt64` tag in a private raw structure, decoded here (`EventKind.ofTag?`); an unknown tag is an `IO` error |
| Small structure | The wrapper passes the fields as scalar arguments | The glue builds the structure in one call. Declare object fields first, then `UInt64` fields and nothing else, so the declaration order is the layout the glue writes |
| Option | The wrapper passes a presence flag and a value | The glue builds `none` or `some` |
| Byte range | Two scalars | `ByteRange`: two `UInt64`, half-open, in bytes |

Prefer a few scalar arguments or one structure to many calls: one `nextEvent`
returns one whole event. A raw structure whose shape the glue knows stays
private to this module; what a caller sees is the typed value.

Examples: `find` (an option in, an option of a byte range out), `Event` with
`postEvent` and `nextEvent` (a string, enums and a structure, in both
directions) and `Document` (a string in, to `Document.new` and
`Document.replace`; a string out, from `Document.read`; byte offsets as
`USize`; a refusal as a `Bool`). Tests: the `find` and event checks of
`ffi-test` (`FfiTest.dataChecks`) and its document checks
(`FfiTest.documentChecks`); the unit tests of `text.rs` and `document.rs` and
the tag tests of `events.rs` in `editor-ffi`.

The editor does not call these bindings. It reaches the library through a
port it defines (`Editor/Text.lean`), whose real binding
(`Editor/Text/Real.lean`) is the one caller of `Document`, and whose contract
(`Editor/Text/Contract.lean`) runs against that binding in `contract-test`.

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

The editor does not call these bindings. The job runner reaches the service
through the clock port it defines (`Job.Timers`, `Editor/Job/Runner.lean`),
whose real implementation (`Editor/Job/Real.lean`) is the one caller, with
the completion pump that pulls the queue on a dedicated task.

Tests: the three timer checks of `ffi-test` (`FfiTest.timerChecks`), and its
check that the completion tag is known (`FfiTest.dataChecks`);
`contract-test`, which runs the job port's contract and the checks of the
real service through the runner (`ContractTest.jobChecks`); the unit tests
of `timers.rs` and `tests/timers.rs` in `editor-ffi`, which need no Lean.

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
- The platform is an enumeration (`Platform`). The scripted one is the
  library's fake: it opens nothing and needs no display, and it is what
  every check runs. The real one opens a window.

The editor does not call these bindings yet. The one caller is the keyboard
check (`Editor/WindowCheck/Real.lean`, `editor window-check`). The editor's
own port for the window, with its model and its contract, arrives with the
command loop.

Tests: the window checks of `ffi-test` (`FfiTest.windowChecks`), on the
scripted platform: five of the bindings, and two that run the keyboard
check's loop over them; the unit tests of `window.rs` and `tests/window.rs`
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

/-- The type behind `Document`. It is opaque, so the only way to get a
document is `Document.new`. -/
opaque DocumentPointed : NonemptyType

/-- Text held by the Rust library, edited in place: a second handle, and the
example of a string going in and one coming back. It is the placeholder the
text port's real binding runs against (`Editor/Text/Real.lean`), and the
editor reaches it only through that port. -/
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

/-- Which of the library's platforms runs the window. -/
inductive Platform where
  /-- The library's scripted platform, a fake for tests: it opens nothing,
  needs no display, and reports one fixed script. -/
  | scripted
  /-- The real window, over winit. It needs a display. -/
  | winit
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
