import Editor.Event
import Editor.Ffi
import Editor.Keymap

/-!
# The events of the editor queue

`Editor.Event` read from the queue's events (`Event.ofFfi`), and posted to the
queue as a window would report them (`Event.post`). This is the one place on
the Lean side that knows the queue's layouts of a key, a pointer and a resize
as words: the table in the module docs of `crates/editor-ffi/src/window.rs`,
repeated in "The window" of `Editor/Ffi.lean`. It imports `Editor.Ffi`, so
only an executable linked with the library imports it.

Decoding trusts nothing: a code the table does not have, words that are too
few or left over, an unknown tag, a scalar that is not a character, a
modifier bit past the system key's, and a dead bit with no dead key are each
an error, never a guess. A message's words are the source's and are not read;
every other kind with no words in the table must have none.

## The interrupt key

The library raises its interrupt flag as the interrupt key arrives ("The
interrupt flag", in `Editor/Ffi.lean`). What crosses for it is here too:

- `Event.setInterruptKey` tells the library which key it is, as the words
  `EventWords.interruptWords` makes. Which keys are the same key is the
  chord's rule (`Key.chord`, `Editor/Keymap.lean`), and it crosses as data:
  the modifiers of the key's chord, and a mask of the modifiers a chord of
  that key keeps. The library compares words and knows no rule.
- `Event.ofFfi` reads the library's mark, bit 3 of a key event's code, into
  `Received.interrupt`. The loop lowers the flag for those events
  (`Loop.take`, `Editor/Loop.lean`).
- `Event.post` never sends the mark: the library sets it, for a press it
  counted.

Tests: `FfiTest.eventDecodeChecks`, on events built by hand, one row of the
table at a time; `FfiTest.eventChecks`, against the library: the scripted
window's sample, and `Event.post` round trips; `FfiTest.interruptChecks`,
against the library: the interrupt key and its mark.
-/

namespace Editor

namespace EventWords

/-- Words being read: those left, in order. -/
abbrev Reader :=
  StateT (List UInt64) (Except String)

/-- The next word. -/
def word : Reader UInt64 := do
  match ← get with
  | [] =>
    throw "the event has too few words"
  | word :: rest =>
    set rest
    return word

/-- The end of the words: an error when any are left over. -/
def finish : Reader Unit := do
  unless (← get).isEmpty do
    throw "the event has words left over"

/-- The character a word numbers. -/
def char (word : UInt64) : Except String Char :=
  if word.toNat.isValidChar then .ok (Char.ofNat word.toNat)
  else .error s!"{word} is not a Unicode scalar value"

/-- A count of scalar values, then the scalar values, as a string. -/
def scalars : Reader String := do
  let count := (← word).toNat
  unless count <= (← get).length do
    throw "the event has too few words for its characters"
  let mut text := ""
  for _ in [0:count] do
    text := text.push (← char (← word))
  return text

/-- The modifiers a word's bits hold. -/
def modifiers (bits : UInt64) : Except String Modifiers :=
  if bits &&& ~~~15 != 0 then .error s!"the modifier bits {bits} have a bit past super"
  else
    .ok
      { shift := bits &&& 1 != 0, control := bits &&& 2 != 0, alt := bits &&& 4 != 0,
        superKey := bits &&& 8 != 0 }

/-- The bits of `modifiers`. -/
def modifierBits (modifiers : Modifiers) : UInt64 :=
  (if modifiers.shift then 1 else 0) ||| (if modifiers.control then 2 else 0) |||
    (if modifiers.alt then 4 else 0) |||
    (if modifiers.superKey then 8 else 0)

/-- The words of a string's scalar values: their count, then each. -/
def scalarWords (text : String) : Array UInt64 :=
  text.toList.foldl (fun words char => words.push char.toNat.toUInt64) #[text.length.toUInt64]

/-- A key's words: its logical key, its physical key and its modifiers. The
code says whether it was pressed, repeated and dead. -/
def key (code : UInt64) : Reader (Key × Bool) := do
  unless code &&& ~~~7 == 0 do
    throw s!"the key code {code} has a bit past the dead bit"
  let logical ←
    match ← word with
    | 0 =>
      unless (← word) == 0 do
        throw "an unidentified logical key has characters"
      pure LogicalKey.unidentified
    | 1 =>
      LogicalKey.character <$> scalars
    | 2 =>
      (fun name => LogicalKey.named ⟨name⟩) <$> scalars
    | 3 =>
      match ← word with
      | 0 =>
        pure (LogicalKey.dead none)
      | 1 =>
        (fun char => LogicalKey.dead (some char)) <$> (char (← word) : Except String Char)
      | count =>
        throw s!"a dead key has {count} characters"
    | tag =>
      throw s!"{tag} is not a logical key's tag"
  let physical ←
    match ← word with
    | 0 =>
      unless (← word) == 0 do
        throw "an unidentified physical key has characters"
      pure PhysicalKey.unidentified
    | 1 =>
      PhysicalKey.code <$> scalars
    | tag =>
      throw s!"{tag} is not a physical key's tag"
  let modifiers ← (modifiers (← word) : Except String Modifiers)
  let dead := logical matches .dead _
  unless dead == (code &&& 4 != 0) do
    throw "the key's dead bit and its logical key disagree"
  return ({ logical, physical, modifiers, repeated := code &&& 2 != 0 }, code &&& 1 != 0)

/-- The words of a logical key: its tag, then its characters or its name. -/
def logicalWords : LogicalKey → Array UInt64
  | .unidentified => #[0, 0]
  | .character text => #[1] ++ scalarWords text
  | .named name => #[2] ++ scalarWords name.name
  | .dead none => #[3, 0]
  | .dead (some char) => #[3, 1, char.toNat.toUInt64]

/-- The words of a key. -/
def keyWords (key : Key) : Array UInt64 :=
  let physical :=
    match key.physical with
    | .unidentified => #[0, 0]
    | .code name => #[1] ++ scalarWords name
  logicalWords key.logical ++ physical |>.push (modifierBits key.modifiers)

/-- A key's code: bit 0 pressed, bit 1 repeat, bit 2 dead. The interrupt
mark, bit 3, is the library's to set and is never posted. -/
def keyCode (key : Key) (pressed : Bool) : UInt64 :=
  (if pressed then (1 : UInt64) else 0) ||| (if key.repeated then (2 : UInt64) else 0) |||
    (if key.logical matches .dead _ then (4 : UInt64) else 0)

/-- The bit of a key event's code that the library sets for a press it
counted as the interrupt key when it arrived. -/
def interruptMark : UInt64 :=
  8

/-- The words that tell the library `key` is the interrupt key: its logical
key, the modifiers held, and the mask of the modifiers the library is to
compare.

Which keys are the same key is the chord's rule (`Key.chord`), and it stays
here: the modifiers are the chord's, and the mask is the modifiers a chord of
this key keeps, found by taking the chord of the key with every modifier
held. So shift is left out of the mask for a character, which already says
whether it is shifted, and is in it for a named key. -/
def interruptWords (key : Key) : Array UInt64 :=
  let every : Modifiers := { shift := true, control := true, alt := true, superKey := true }
  let mask := modifierBits ({ key with modifiers := every } : Key).chord.modifiers
  logicalWords key.logical ++ #[modifierBits key.chord.modifiers, mask]

/-- A pointer's words, with its code as the action. -/
def pointer (code : UInt64) : Reader Pointer := do
  let x := Float.ofBits (← word)
  let y := Float.ofBits (← word)
  let tag ← word
  let other ← word
  let button ←
    match tag with
    | 0 =>
      pure none
    | 1 =>
      pure (some Button.primary)
    | 2 =>
      pure (some Button.secondary)
    | 3 =>
      pure (some Button.middle)
    | 4 =>
      pure (some Button.back)
    | 5 =>
      pure (some Button.forward)
    | 6 =>
      pure (some (Button.other other.toNat))
    | tag =>
      throw s!"{tag} is not a button's tag"
  unless tag == 6 || other == 0 do
    throw "a named button has a number"
  let modifiers ← (modifiers (← word) : Except String Modifiers)
  let delta ← word
  let dx ← word
  let dy ← word
  let action ←
    match code, delta with
    | 0, 0 | 1, 0 | 2, 0 =>
      unless dx == 0 && dy == 0 do
        throw "a pointer that is not a wheel has a delta"
      pure (if code == 0 then PointerAction.press else if code == 1 then .drag else .release)
    | 3, 1 =>
      pure (PointerAction.wheel (.lines (Float.ofBits dx) (Float.ofBits dy)))
    | 3, 2 =>
      pure (PointerAction.wheel (.pixels (Float.ofBits dx) (Float.ofBits dy)))
    | code, delta =>
      throw s!"a pointer of code {code} cannot have the delta tag {delta}"
  return { action, x, y, button, modifiers }

/-- A pointer's code and words. -/
def pointerWords (pointer : Pointer) : UInt64 × Array UInt64 :=
  let (code, delta) : UInt64 × Array UInt64 :=
    match pointer.action with
    | .press => (0, #[0, 0, 0])
    | .drag => (1, #[0, 0, 0])
    | .release => (2, #[0, 0, 0])
    | .wheel (.lines x y) => (3, #[1, x.toBits, y.toBits])
    | .wheel (.pixels x y) => (3, #[2, x.toBits, y.toBits])
  let (tag, other) : UInt64 × UInt64 :=
    match pointer.button with
    | none => (0, 0)
    | some .primary => (1, 0)
    | some .secondary => (2, 0)
    | some .middle => (3, 0)
    | some .back => (4, 0)
    | some .forward => (5, 0)
    | some (.other number) => (6, number.toUInt64)
  (code, #[pointer.x.toBits, pointer.y.toBits, tag, other, modifierBits pointer.modifiers] ++ delta)

/-- Runs `read` over all of `words`, which it must use up. -/
def readAll {α : Type} (read : Reader α) (words : Array UInt64) : Except String α :=
  (do
        let value ← read
        finish
        return value).run'
    words.toList

end EventWords

/-- The source of a queue's event, in Lean's terms. -/
def EventSource.ofFfi (source : Ffi.Source) : EventSource :=
  { kind :=
      match source.kind with
      | .library => .library
      | .lean => .lean
      | .script => .script
      | .window => .window
    id := source.id }

/-- The `Event` an event of the editor queue is, with its stamp and whether
the library marked it as a press of the interrupt key, or why it cannot be
read: one variant for each kind and code of the table in
`crates/editor-ffi/src/window.rs`.

The interrupt mark is bit 3 of a key event's code, and of no other kind's.
It is taken off before the key is read, so a key's code is still refused
for any higher bit, and a mark on a key that was not pressed is refused: the
library marks presses only. -/
def Event.ofFfi (event : Ffi.Event) : Except String Received := do
  let none (value : Event) : Except String Event :=
    if event.words.isEmpty then .ok value else .error "the event has words its kind does not have"
  let interrupt := event.kind == .key && event.code &&& EventWords.interruptMark != 0
  if interrupt && event.code &&& 1 == 0 then
    throw "the interrupt mark is on a key that was not pressed"
  let decoded ←
    match event.kind, if interrupt then event.code ^^^ EventWords.interruptMark else event.code with
    | .quit, _ =>
      none .quit
    | .message, code =>
      pure (.message (EventSource.ofFfi event.source) code event.text)
    | .completion, id =>
      none (.completion (EventSource.ofFfi event.source) id)
    | .windowOpened, 0 =>
      none (.windowOpened event.text)
    | .windowFocus, 0 =>
      none (.focus false)
    | .windowFocus, 1 =>
      none (.focus true)
    | .key, code =>
      (fun ((which, pressed) : Key × Bool) => Event.key which pressed event.text) <$>
          EventWords.readAll (EventWords.key code) event.words
    | .composition, 0 =>
      none .compositionEnabled
    | .composition, 1 =>
      none (.preedit event.text)
    | .composition, 2 =>
      none (.commit event.text)
    | .composition, 3 =>
      none .compositionDisabled
    | .pointer, code =>
      Event.pointer <$> EventWords.readAll (EventWords.pointer code) event.words
    | .resize, 0 =>
      match event.words with
      | #[width, height, scale] =>
        pure (.resize { width := width.toNat, height := height.toNat, scale := Float.ofBits scale })
      | _ =>
        throw "a resize has three words"
    | .closeRequested, 0 =>
      none .closeRequested
    | kind, code =>
      throw s!"{repr kind} has no code {code}"
  return { event := decoded, stamp := event.stamp, interrupt }

/-- Posts `event` to the editor queue as the process's window would report it,
through the library's window input (`Ffi.postInput`), so that it takes the
same encoding path a real window's input does. `false` when it was not
queued: a message, a completion and a quit are not a window's, and are never
posted; nor is anything once the queues are quit. -/
def Event.post : Event → IO Bool
  | .windowOpened platform => Ffi.postInput .windowOpened 0 platform #[]
  | .focus gained => Ffi.postInput .windowFocus (if gained then 1 else 0) "" #[]
  | .key which pressed text =>
    Ffi.postInput .key (EventWords.keyCode which pressed) text (EventWords.keyWords which)
  | .compositionEnabled => Ffi.postInput .composition 0 "" #[]
  | .preedit text => Ffi.postInput .composition 1 text #[]
  | .commit text => Ffi.postInput .composition 2 text #[]
  | .compositionDisabled => Ffi.postInput .composition 3 "" #[]
  | .pointer what =>
    let (code, words) := EventWords.pointerWords what
    Ffi.postInput .pointer code "" words
  | .resize size =>
    Ffi.postInput .resize 0 "" #[size.width.toUInt64, size.height.toUInt64, size.scale.toBits]
  | .closeRequested => Ffi.postInput .closeRequested 0 "" #[]
  | .message .. | .completion .. | .quit => pure false

/-- Tells the library which key is the interrupt key, or that there is none:
from then on a press of that key, as a chord names it, raises the library's
interrupt flag as it arrives, and its event comes back marked
(`Received.interrupt`). `false` when the library did not take the key. The
flag itself is left as it is. -/
def Event.setInterruptKey : Option Key → IO Bool
  | some which => Ffi.interruptKeySet (EventWords.interruptWords which)
  | none => do
    Ffi.interruptKeyClear
    return true

end Editor
