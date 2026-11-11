/-!
# Bindings to the Rust library

The functions `editor-ffi` (`crates/editor-ffi`) exposes, as Lean
declarations. A pure function over plain numbers binds straight to its Rust
symbol. Any other function binds to a wrapper in `ffi/glue.c`, which calls the
Rust function and builds the Lean value for its result with `lean.h`.

## Conventions

Every binding follows the rules below. Each has one small real example in this
module and names the tests that pin it. This is Lean's side of each rule;
Rust's side is in the crate docs of `crates/editor-ffi/src/lib.rs`.

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

Example: `Counter`. Tests: the four counter checks of `ffi-test`
(`FfiTest.handleChecks`); `tests/c_api.rs` in `editor-ffi`.

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

Examples: `find` (an option in, an option of a byte range out) and `Event`
with `postEvent` and `nextEvent` (a string, enums and a structure, in both
directions). Tests: the `find` and event checks of `ffi-test`
(`FfiTest.dataChecks`); the unit tests of `text.rs` and the tag tests of
`events.rs` in `editor-ffi`.

### The event queues

Rust never calls a Lean function. Rust threads push events onto a queue, and
Lean pulls them with `nextEvent`, which blocks in Rust: call it from a
dedicated task, never from the thread pool. An event is plain data tagged with
its source. There are two queues (`Queue`): the editor queue, for input and
events for the editor thread, and the completion queue, for the results of
service requests, pulled by a dedicated task. `feedScript` drives the library's
fake event source, for tests.

Tests: the three queue checks of `ffi-test` (`FfiTest.queueChecks`); the unit
tests of `events.rs` in `editor-ffi`, which need no Lean.

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

Test: `mise run ffi-overflow`, which runs `ffi-test overflow` and requires it
to die of SIGABRT once it has entered the recursion. It is run on demand, not
by the gate: every abort makes macOS write a crash report on the developer's
machine.

### Shutdown

`quit` makes every `nextEvent`, parked or later, return a `quit` event, so
every dedicated task blocked in a pull returns. Then end the process with
`IO.Process.exit`. Never return from `main` while a dedicated task may still
be blocked in the library: Lean waits for it, for ever.

Tests: `ffi-test shutdown` and `ffi-test exit-while-blocked`; the quit tests
of `events.rs` in `editor-ffi`.

### Nothing runs at initialisation

A module initialiser must not call the library: make library objects from
`main` or later. The `lean` compiler runs a module's initialisers when it
compiles a module that imports it, in a process where the Rust symbols do not
exist, so `mise run lean` fails on an initialiser that calls a binding.
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
  deriving DecidableEq, Repr

/-- The kind the library's number `tag` stands for, if it is one. -/
def EventKind.ofTag? : UInt64 → Option EventKind
  | 0 => some .quit
  | 1 => some .message
  | _ => none

/-- What kind of thing an event came from. -/
inductive SourceKind where
  /-- The Rust library itself. -/
  | library
  /-- Lean code, through `postEvent`. -/
  | lean
  /-- The library's scripted source, a fake for tests. -/
  | script
  deriving DecidableEq, Repr

/-- The kind the library's number `tag` stands for, if it is one. -/
def SourceKind.ofTag? : UInt64 → Option SourceKind
  | 0 => some .library
  | 1 => some .lean
  | 2 => some .script
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
           text := raw.text }

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

end Editor.Ffi
