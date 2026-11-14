/-!
# The events

What arrives on the editor queue, as one Lean type: `Event`, a variant for
each kind of thing the queue delivers, with the instant it happened beside it
(`Received`). It is plain data and imports no binding, so keymaps and the
command loop see it under `lake test`; decoding it from the queue, and
posting one as a window would, is `Editor/Event/Queue.lean`, the one module on
the Lean side that knows how the queue lays an event out.

## The key

A key is its identity, the modifiers held, and whether the platform repeated
it (`Key`). Its identity is two things:

- the **logical** key, what the keyboard layout makes of it: a character, a
  named key, a dead key, or nothing the platform could say (`LogicalKey`);
- the **physical** key, where it is on the keyboard, whatever the layout
  (`PhysicalKey`).

A named key and a physical key are W3C UI Events names, as strings: the `key`
values (`Escape`, `ArrowLeft`) and the `code` values (`KeyA`, `Digit1`). So
the vocabulary grows with no table of numbers that Lean and Rust must change
in step. `NamedKey` has constants for the names Lean uses.

The text a key produced is not part of the key: it stays beside it in the
event (`Event.key`), because a key may have an identity and produce no text
(`Escape`), and an input method decides what text a key makes.

## The pointer and the resize

A pointer event is a press, a drag, a release or a wheel, with the position
in the frame, the button and the modifiers (`Pointer`). A resize is the
frame's new size and its scale factor (`Resize`). Positions and sizes are in
the frame's physical pixels.

## Where an addition goes

Two roadmaps build on these events. The display pipeline owns producing them
from winit in Rust; the command loop owns what Lean does with them.

| Addition | Lean (command loop) | Rust (display pipeline) |
|---|---|---|
| A new event kind | A variant of `Event`, a tag in `Ffi.EventKind`, a case in `Event.ofFfi` and `Event.post` | A variant of `editor_platform::Input`, a tag in `EventKind`, a row in `window::event` and `window::input` |
| A new key attribute | A field of `Key` (or of `Modifiers`), its words appended in `Event.ofFfi` and `Event.post` | A field of `editor_platform::Key`, its words appended in `window.rs` |
| A new named key or physical code | A `NamedKey` constant, if Lean names it; no tag | The adapter produces the W3C name; nothing to add |

Each row is pinned on its side: in Lean by `FfiTest.eventDecodeChecks` on
events built by hand and `FfiTest.eventChecks` against the library; in Rust
by the unit tests of `window.rs`.
-/

namespace Editor

/-- A key with a name and no character: its W3C UI Events `key` value. -/
structure NamedKey where
  /-- The name, such as `Escape` or `ArrowLeft`. -/
  name : String
  deriving DecidableEq, Repr

namespace NamedKey

/-- `Escape`. -/
def escape : NamedKey :=
  ⟨"Escape"⟩

/-- `Enter`. -/
def enter : NamedKey :=
  ⟨"Enter"⟩

/-- `Tab`. -/
def tab : NamedKey :=
  ⟨"Tab"⟩

/-- `Backspace`. -/
def backspace : NamedKey :=
  ⟨"Backspace"⟩

/-- `Delete`. -/
def delete : NamedKey :=
  ⟨"Delete"⟩

/-- `Insert`. -/
def insert : NamedKey :=
  ⟨"Insert"⟩

/-- `Home`. -/
def home : NamedKey :=
  ⟨"Home"⟩

/-- `End`. -/
def end_ : NamedKey :=
  ⟨"End"⟩

/-- `PageUp`. -/
def pageUp : NamedKey :=
  ⟨"PageUp"⟩

/-- `PageDown`. -/
def pageDown : NamedKey :=
  ⟨"PageDown"⟩

/-- `ArrowUp`. -/
def arrowUp : NamedKey :=
  ⟨"ArrowUp"⟩

/-- `ArrowDown`. -/
def arrowDown : NamedKey :=
  ⟨"ArrowDown"⟩

/-- `ArrowLeft`. -/
def arrowLeft : NamedKey :=
  ⟨"ArrowLeft"⟩

/-- `ArrowRight`. -/
def arrowRight : NamedKey :=
  ⟨"ArrowRight"⟩

end NamedKey

/-- What the keyboard layout makes of a key. -/
inductive LogicalKey where
  /-- A key that produces a character: the characters the layout gives it,
  usually one. -/
  | character (text : String)
  /-- A key with a name and no character. -/
  | named (key : NamedKey)
  /-- A dead key: it produces nothing by itself and changes the key after it.
  The character it would add, when the platform says. -/
  | dead (char : Option Char)
  /-- The platform could not say. -/
  | unidentified
  deriving DecidableEq, Repr

/-- Where a key is on the keyboard, whatever the layout. -/
inductive PhysicalKey where
  /-- The key's W3C UI Events `code` value, such as `KeyA`. -/
  | code (name : String)
  /-- The platform could not say. -/
  | unidentified
  deriving DecidableEq, Repr

/-- The modifier keys held. -/
structure Modifiers where
  /-- Shift. -/
  shift : Bool := false
  /-- Control. -/
  control : Bool := false
  /-- Alt, which macOS calls Option. -/
  alt : Bool := false
  /-- The system key: Command on macOS, the Windows key elsewhere. -/
  superKey : Bool := false
  deriving DecidableEq, Repr

/-- A key: which it is, the modifiers held, and whether the platform repeated
it because it is held. Whether it went down or up, and the text it produced,
are the event's (`Event.key`). -/
structure Key where
  /-- What the layout makes of it. -/
  logical : LogicalKey
  /-- Where it is. -/
  physical : PhysicalKey := .unidentified
  /-- The modifiers held. -/
  modifiers : Modifiers := {}
  /-- Whether this is a press the platform repeated because the key is
  held. -/
  repeated : Bool := false
  deriving DecidableEq, Repr

/-- The modifiers held, as a key is described: their names joined with `+`
(`shift`, `control`, `alt`, `super`, in that order), or `-` for none. -/
def Modifiers.describe (modifiers : Modifiers) : String :=
  let held :=
    [(modifiers.shift, "shift"), (modifiers.control, "control"), (modifiers.alt, "alt"),
          (modifiers.superKey, "super")].filterMap
      fun (isHeld, name) => if isHeld then some name else none
  if held.isEmpty then "-" else "+".intercalate held

/-- A logical key as a key is described: a character as itself, a named key
as its name in angle brackets (`<Escape>`), a dead key as `<Dead>` or
`<Dead ´>`, and an unidentified one as `<Unidentified>`. -/
def LogicalKey.describe : LogicalKey → String
  | .character text => text
  | .named key => s!"<{key.name}>"
  | .dead none => "<Dead>"
  | .dead (some char) => s!"<Dead {char}>"
  | .unidentified => "<Unidentified>"

/-- A physical key as a key is described: its code, or `-` when the platform
could not say. -/
def PhysicalKey.describe : PhysicalKey → String
  | .code name => name
  | .unidentified => "-"

/-- A key for output: its logical key, its physical key and its modifiers,
separated by spaces, such as `a KeyA shift+control` or `<Escape> - -`. -/
def Key.describe (key : Key) : String :=
  s!"{key.logical.describe} {key.physical.describe} {key.modifiers.describe}"

/-- A pointer button. -/
inductive Button where
  /-- The main button: usually the left. -/
  | primary
  /-- The context button: usually the right. -/
  | secondary
  /-- The middle button, often the wheel. -/
  | middle
  /-- The back button. -/
  | back
  /-- The forward button. -/
  | forward
  /-- Another button, by the platform's number for it. -/
  | other (number : Nat)
  deriving DecidableEq, Repr

/-- How far a wheel turned. -/
inductive WheelDelta where
  /-- In columns and lines, as a mouse wheel's notches count. -/
  | lines (x y : Float)
  /-- In physical pixels, as a trackpad scrolls. -/
  | pixels (x y : Float)
  deriving BEq, Repr

/-- What a pointer did. -/
inductive PointerAction where
  /-- A button went down. -/
  | press
  /-- The pointer moved with a button held. -/
  | drag
  /-- A button came up. -/
  | release
  /-- A wheel turned, or a trackpad scrolled, by `delta`. -/
  | wheel (delta : WheelDelta)
  deriving BEq, Repr

/-- What the pointer did, where in the frame, with which button, and the
modifiers held. -/
structure Pointer where
  /-- What happened. -/
  action : PointerAction
  /-- How far from the left of the frame, in physical pixels. -/
  x : Float
  /-- How far from the top of the frame, in physical pixels. -/
  y : Float
  /-- The button that went down or up, or that is held while dragging;
  `none` when there is none, as for a wheel. -/
  button : Option Button
  /-- The modifiers held. -/
  modifiers : Modifiers := {}
  deriving BEq, Repr

/-- The frame's new size and scale factor. -/
structure Resize where
  /-- The drawable width, in physical pixels. -/
  width : Nat
  /-- The drawable height, in physical pixels. -/
  height : Nat
  /-- How many physical pixels a logical pixel is. -/
  scale : Float
  deriving BEq, Repr

/-- What kind of thing an event came from. -/
inductive EventSourceKind where
  /-- The Rust library itself. -/
  | library
  /-- Lean code, posting to the queue. -/
  | lean
  /-- The library's scripted source, a fake for tests. -/
  | script
  /-- A window; the source's id is the window's number. -/
  | window
  deriving DecidableEq, Repr

/-- Where an event came from. -/
structure EventSource where
  /-- The kind of source. -/
  kind : EventSourceKind
  /-- Which source of that kind, in numbers the source chose. -/
  id : UInt64
  deriving DecidableEq, Repr

/-- One thing the editor queue delivers. A new kind is a variant here
("Where an addition goes", in the module docs). -/
inductive Event where
  /-- A message with no meaning to the library: its code and text are
  whatever `source` chose. -/
  | message (source : EventSource) (code : UInt64) (text : String)
  /-- The service `source` finished the request `id`. -/
  | completion (source : EventSource) (id : UInt64)
  /-- The window is open, on the platform of this name. -/
  | windowOpened (platform : String)
  /-- The window gained the keyboard focus, or lost it. -/
  | focus (gained : Bool)
  /-- `key` went down (`pressed`) or up, and produced `text`, which may be
  empty. -/
  | key (key : Key) (pressed : Bool) (text : String)
  /-- An input method became available to the window. -/
  | compositionEnabled
  /-- The input method is no longer available to the window. -/
  | compositionDisabled
  /-- A composition ended with `text`. -/
  | commit (text : String)
  /-- The text an input method is composing is now `text`; it is not yet
  part of the input. -/
  | preedit (text : String)
  /-- The pointer did something in the window. -/
  | pointer (pointer : Pointer)
  /-- The frame changed size, or its scale factor did. -/
  | resize (resize : Resize)
  /-- The user asked for the window to be closed. It stays open until Lean
  closes it. -/
  | closeRequested
  /-- The queue has been quit: the loop pulling it must return. -/
  | quit
  deriving BEq, Repr

/-- An event, and when its source says it happened: nanoseconds on the
library's input clock, or 0 when the source does not say. Only a window
says. -/
structure Received where
  /-- What happened. -/
  event : Event
  /-- When. -/
  stamp : UInt64
  /-- Whether the library counted this event as a press of the interrupt
  key when it arrived, and raised the interrupt flag for it. The loop that
  takes the event off the queue lowers the flag, for these events and for
  no other (`Loop.take`, `Editor/Loop.lean`). -/
  interrupt : Bool := false
  deriving BEq, Repr

end Editor
