import Editor.Ffi.Words

/-!
# Bindings: the event queues

The bindings of `crates/editor-ffi/src/events.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("The event queues", "Shutdown").
-/

namespace Editor.Ffi

open Words

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

end Editor.Ffi
