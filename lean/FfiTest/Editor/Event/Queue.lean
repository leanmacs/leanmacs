import Editor.Event
import Editor.Event.Queue
import Editor.Ffi.Events
import Editor.Ffi.Window
import FfiTest.Check
import FfiTest.Support.Queues
import FfiTest.Support.Windows

/-!
# FFI tests: `Editor/Event/Queue.lean`

The tests of `Editor/Event/Queue.lean`: `eventDecodeChecks`,
`eventEncodeChecks` and `eventChecks`, of `Event.ofFfi`, `Event.toFfi` and
`Event.post`. The root module `FfiTest` runs them, and each
list's own doc says what it checks.
-/

namespace FfiTest

/-- An event of `kind` from the window number 1, with this code, text and
words, built by hand. -/
def windowEvent (kind : Editor.Ffi.EventKind) (code : UInt64) (words : Array UInt64 := #[])
    (text : String := "") : Editor.Ffi.Event :=
  { source := { kind := .window, id := 1 }, kind, code, text, stamp := 7, words }

/-- What `Editor.Event.ofFfi` makes of an event built by hand: the event, or
`none` when it is refused. -/
def decodedEvent (event : Editor.Ffi.Event) : Option Editor.Received :=
  (Editor.Event.ofFfi event).toOption

/-- What `Editor.Event.ofFfi` makes of a window event built by hand, without
its stamp. -/
def decodedWindow (kind : Editor.Ffi.EventKind) (code : UInt64) (words : Array UInt64 := #[])
    (text : String := "") : Option Editor.Event :=
  (decodedEvent (windowEvent kind code words text)).map (·.event)

/-- The words of a pointer at (12.5, 40) with alt held, the button tag and its
number, and the wheel's delta tag and two floats. -/
def pointerWords (button other delta : UInt64) (dx dy : Float := 0) : Array UInt64 :=
  #[(12.5 : Float).toBits, (40.0 : Float).toBits, button, other, 4, delta,
    if delta == 0 then 0 else dx.toBits, if delta == 0 then 0 else dy.toBits]

/-- A pointer at (12.5, 40) with alt held. -/
def pointerAt (action : Editor.PointerAction) (button : Option Editor.Button) : Editor.Pointer :=
  { action, x := 12.5, y := 40.0, button, modifiers := { alt := true } }

/-- The checks of which event of the editor queue is which `Editor.Event`
(`Editor.Event.ofFfi`, `Editor/Event/Queue.lean`): each kind the queue
delivers decodes to its own variant, with its fields, and what cannot be read
is refused. They are on events built by hand: they call no binding and need
no window. -/
def eventDecodeChecks (_ : Unit) : List Check :=
  [{  name :=
        "the modifier bits are shift 1, control 2, alt 4 and super 8: each of the 16 sets round trips, and a bit past super reads as none"
      run :=
        pure
          (Editor.Ffi.modifierBits { shift := true } == 1 &&
            Editor.Ffi.modifierBits { control := true } == 2 &&
            Editor.Ffi.modifierBits { alt := true } == 4 &&
            Editor.Ffi.modifierBits { superKey := true } == 8 &&
            (List.range 16).all
              (fun bits =>
                (Editor.Ffi.modifiersOfBits? bits.toUInt64).map Editor.Ffi.modifierBits ==
                  some bits.toUInt64) &&
            [16, 17, 32, UInt64.ofNat (2 ^ 63)].all (Editor.Ffi.modifiersOfBits? · == none)) },
    { name := "a message decodes with its source, its code and its text, whatever its words"
      run :=
        pure
          ((decodedEvent { message 5 6 "hi" with words := #[1, 2] }).map (·.event) ==
            some (.message { kind := .lean, id := 5 } 6 "hi")) },
    { name := "a completion decodes with its source and its id, and a quit to quit"
      run :=
        pure
          ((decodedEvent
                    { source := { kind := .library, id := 4 }, kind := .completion, code := 17,
                      text := "", stamp := 0 }).map
                (·.event) ==
              some (.completion { kind := .library, id := 4 } 17) &&
            (decodedEvent
                    { source := { kind := .library, id := 0 }, kind := .quit, code := 0, text := ""
                      stamp := 0 }).map
                (·.event) ==
              some .quit) },
    { name :=
        "a parse delivered decodes from the library's syntax service, with no code, text or word"
      run :=
        let parsed (code : UInt64) (text : String) (words : Array UInt64) : Editor.Ffi.Event :=
          { source := { kind := .library, id := 5 }, kind := .parsed, code, text, stamp := 0
            words }
        pure
          ((decodedEvent (parsed 0 "" #[])).map (·.event) == some .parsed &&
            (decodedEvent (parsed 1 "" #[])).isNone &&
            (decodedEvent (parsed 0 "x" #[])).isNone &&
            (decodedEvent (parsed 0 "" #[1])).isNone) },
    { name := "a window opened decodes with its platform, and a focus gained and lost"
      run :=
        pure
          (decodedWindow .windowOpened 0 (text := "winit") == some (.windowOpened "winit") &&
            decodedWindow .windowFocus 1 == some (.focus true) &&
            decodedWindow .windowFocus 0 == some (.focus false)) },
    { name :=
        "a key decodes with its logical key, its physical key, its modifiers, whether it is a repeat, whether it was pressed, and its text"
      run :=
        pure
          (decodedWindow .key 1 #[1, 1, 97, 1, 4, 75, 101, 121, 65, 3] "a" ==
              some
                (.key
                  { logical := .character "a", physical := .code "KeyA"
                    modifiers := { shift := true, control := true } } true "a") &&
            decodedWindow .key 2 #[2, 6, 69, 115, 99, 97, 112, 101, 0, 0, 15] ==
              some
                (.key
                  { logical := .named .escape
                    modifiers := { shift := true, control := true, alt := true, superKey := true }
                    repeated := true } false "") &&
            decodedWindow .key 5 #[3, 1, 180, 0, 0, 0] ==
              some (.key { logical := .dead (some '´') } true "") &&
            decodedWindow .key 4 #[3, 0, 0, 0, 0] ==
              some (.key { logical := .dead none } false "") &&
            decodedWindow .key 0 #[0, 0, 0, 0, 0] ==
              some (.key { logical := .unidentified } false "")) },
    { name :=
        "a composition decodes by its code: 0 to enabled, 1 to a preedit of its text, 2 to a commit of its text and 3 to disabled"
      run :=
        pure
          (decodedWindow .composition 0 == some .compositionEnabled &&
            decodedWindow .composition 1 (text := "´") == some (.preedit "´") &&
            decodedWindow .composition 2 (text := "é") == some (.commit "é") &&
            decodedWindow .composition 3 == some .compositionDisabled) },
    { name :=
        "a pointer decodes with its action, its position, its button and its modifiers: each action, each button, and each wheel delta"
      run :=
        pure
          (decodedWindow .pointer 0 (pointerWords 1 0 0) ==
              some (.pointer (pointerAt .press (some .primary))) &&
            decodedWindow .pointer 1 (pointerWords 2 0 0) ==
              some (.pointer (pointerAt .drag (some .secondary))) &&
            decodedWindow .pointer 2 (pointerWords 3 0 0) ==
              some (.pointer (pointerAt .release (some .middle))) &&
            decodedWindow .pointer 0 (pointerWords 4 0 0) ==
              some (.pointer (pointerAt .press (some .back))) &&
            decodedWindow .pointer 0 (pointerWords 5 0 0) ==
              some (.pointer (pointerAt .press (some .forward))) &&
            decodedWindow .pointer 0 (pointerWords 6 9 0) ==
              some (.pointer (pointerAt .press (some (.other 9)))) &&
            decodedWindow .pointer 3 (pointerWords 0 0 1 0 (-1.5)) ==
              some (.pointer (pointerAt (.wheel (.lines 0 (-1.5))) none)) &&
            decodedWindow .pointer 3 (pointerWords 0 0 2 7 0.5) ==
              some (.pointer (pointerAt (.wheel (.pixels 7 0.5)) none))) },
    { name :=
        "a resize decodes with its size, its scale, whether it is in fullscreen, its corner clearance and its top inset, and a request to close to itself"
      run :=
        pure
          (decodedWindow .resize 0 #[800, 600, (2.0 : Float).toBits, 0, 0] ==
              some (.resize { width := 800, height := 600, scale := 2.0 }) &&
            decodedWindow .resize 0 #[800, 600, (2.0 : Float).toBits, 16, 32] ==
              some
                (.resize { width := 800, height := 600, scale := 2.0, corner := 16, top := 32 }) &&
            decodedWindow .resize 1 #[1440, 900, (2.0 : Float).toBits, 0, 0] ==
              some (.resize { width := 1440, height := 900, scale := 2.0, fullscreen := true }) &&
            decodedWindow .resize 0 #[800, 600, (2.0 : Float).toBits, 16] == none &&
            decodedWindow .closeRequested 0 == some .closeRequested) },
    { name :=
        "a quit the system asked decodes to itself, and is refused with a code, with a word and with text"
      run :=
        pure
          (decodedWindow .quitRequested 0 == some .quitRequested &&
            (decodedWindow .quitRequested 1).isNone &&
            (decodedWindow .quitRequested 0 #[0]).isNone &&
            (decodedWindow .quitRequested 0 #[] "x").isNone) },
    { name :=
        "a menu item chosen decodes to its command's name, an empty name as it is, and is refused with a code and with a word"
      run :=
        pure
          (decodedWindow .menu 0 #[] "undo" == some (.menu "undo") &&
            decodedWindow .menu 0 == some (.menu "") &&
            (decodedWindow .menu 1 #[] "undo").isNone &&
            (decodedWindow .menu 0 #[0] "undo").isNone) },
    { name :=
        "files to open decode with their paths in order, each its count of characters and its characters, and no path to none"
      run :=
        pure
          (decodedWindow .openFiles 0 #[2, 1, 97, 2, 98, 99] == some (.openFiles ["a", "bc"]) &&
            decodedWindow .openFiles 0 #[0] == some (.openFiles [])) },
    { name :=
        "files to open are refused with a code, with text, with too few words, with words left over, and with a scalar that is not a character"
      run :=
        pure
          ((decodedWindow .openFiles 1 #[1, 1, 97]).isNone &&
            (decodedWindow .openFiles 0 #[1, 1, 97] "x").isNone &&
            (decodedWindow .openFiles 0 #[2, 1, 97]).isNone &&
            (decodedWindow .openFiles 0 #[]).isNone &&
            (decodedWindow .openFiles 0 #[1, 1, 97, 5]).isNone &&
            (decodedWindow .openFiles 0 #[1, 1, 0xD800]).isNone) },
    { name := "the stamp of an event is kept beside it"
      run := pure ((decodedEvent (windowEvent .closeRequested 0)).map (·.stamp) == some 7) },
    { name :=
        "a key whose code carries the interrupt mark decodes as the key it is, marked as an interrupt key, and one without the mark is not marked"
      run :=
        pure
          (decodedEvent (windowEvent .key 9 #[1, 1, 103, 0, 0, 2]) ==
              some
                { event :=
                    .key { logical := .character "g", modifiers := { control := true } } true ""
                  stamp := 7, interrupt := true } &&
            decodedEvent (windowEvent .key 11 #[0, 0, 0, 0, 0]) ==
              some
                { event := .key { logical := .unidentified, repeated := true } true "", stamp := 7
                  interrupt := true } &&
            (decodedEvent (windowEvent .key 1 #[1, 1, 103, 0, 0, 2])).map (·.interrupt) ==
              some false &&
            (decodedEvent (windowEvent .closeRequested 0)).map (·.interrupt) == some false) },
    { name :=
        "whether an event carries the interrupt mark is read from its kind and its code alone: a key with bit 3 of its code carries it whether or not the key can be read, a key without the bit does not, and no other kind does with the bit"
      run :=
        pure
          (Editor.Event.interruptMarked (windowEvent .key 9 #[1, 1, 103, 0, 0, 2]) &&
            Editor.Event.interruptMarked (windowEvent .key 9 #[1, 1, 103, 0, 0, 2, 0]) &&
            Editor.Event.interruptMarked (windowEvent .key 8 #[0, 0, 0, 0, 0]) &&
            !Editor.Event.interruptMarked (windowEvent .key 1 #[1, 1, 103, 0, 0, 2]) &&
            !Editor.Event.interruptMarked (windowEvent .composition 8) &&
            !Editor.Event.interruptMarked (message 5 8 "")) },
    { name :=
        "a code the table does not have is refused: a focus of 2, a composition of 4, a key with a bit past the interrupt mark, a key with the mark that was not pressed, a pointer of 4, a resize of 2"
      run :=
        pure
          ((decodedWindow .windowFocus 2).isNone && (decodedWindow .composition 4).isNone &&
            (decodedWindow .key 16 #[0, 0, 0, 0, 0]).isNone &&
            (decodedWindow .key 17 #[0, 0, 0, 0, 0]).isNone &&
            (decodedWindow .key 8 #[0, 0, 0, 0, 0]).isNone &&
            (decodedWindow .pointer 4 (pointerWords 1 0 0)).isNone &&
            (decodedWindow .resize 2 #[1, 1, 0, 0]).isNone) },
    { name :=
        "malformed words are refused: too few, left over, an unknown tag, a scalar that is not a character, modifier bits past super, a dead bit with no dead key, a named button with a number, a pointer that is not a wheel with a delta"
      run :=
        pure
          ((decodedWindow .key 1 #[1, 1]).isNone &&
            (decodedWindow .key 1 #[0, 0, 0, 0, 0, 0]).isNone &&
            (decodedWindow .key 1 #[4, 0, 0, 0, 0]).isNone &&
            (decodedWindow .key 1 #[0, 0, 2, 0, 0]).isNone &&
            (decodedWindow .key 1 #[1, 1, 0xD800, 0, 0, 0]).isNone &&
            (decodedWindow .key 1 #[1, 1, 0x110000, 0, 0, 0]).isNone &&
            (decodedWindow .key 1 #[0, 0, 0, 0, 16]).isNone &&
            (decodedWindow .key 5 #[0, 0, 0, 0, 0]).isNone &&
            (decodedWindow .pointer 0 (pointerWords 7 0 0)).isNone &&
            (decodedWindow .pointer 3 (pointerWords 0 0 0)).isNone &&
            (decodedWindow .pointer 0 (pointerWords 1 9 0)).isNone &&
            (decodedWindow .pointer 0
                #[(12.5 : Float).toBits, (40.0 : Float).toBits, 1, 0, 4, 0, 0,
                  (1.0 : Float).toBits]).isNone &&
            (decodedWindow .pointer 0
                #[(12.5 : Float).toBits, (40.0 : Float).toBits, 1, 0, 16, 0, 0, 0]).isNone &&
            (decodedWindow .resize 0 #[800, 600]).isNone &&
            (decodedWindow .resize 0 #[800, 600, (2.0 : Float).toBits]).isNone &&
            (decodedWindow .closeRequested 0 #[1]).isNone) }]

/-- The events of a run of the scripted platform's window, decoded. -/
def scriptedEvents : IO (List Editor.Event) := do
  let ran ← runScripted true
  ran.events.mapM fun event => (·.event) <$> IO.ofExcept (Editor.Event.ofFfi event)

/-- Posts `event` as a window would report it, pulls it back from the editor
queue and decodes it. -/
def roundTrip (event : Editor.Event) : IO (Option Editor.Event) := do
  unless ← Editor.Event.post event do
    return none
  let some pulled ← pull .editor | return none
  return (Editor.Event.ofFfi pulled).toOption.map (·.event)

/-- One event of each kind a window reports, with fields that each layout
carries: what the checks of `Editor.Event.toFfi` encode. -/
def windowKinds : List Editor.Event :=
  [.windowOpened "x", .focus true, .focus false,
    .key
      { logical := .named .escape, physical := .code "Escape", modifiers := { superKey := true } }
      true "",
    .key { logical := .character "é", repeated := true } true "é", .compositionEnabled,
    .preedit "´", .commit "é", .compositionDisabled, .pointer (pointerAt .press (some .primary)),
    .pointer (pointerAt (.wheel (.pixels 0.25 8)) none),
    .resize { width := 1920, height := 1080, scale := 1.25, fullscreen := true },
    .openFiles ["/tmp/é x.lean"], .closeRequested, .quitRequested, .menu "undo"]

/-- The checks of `Editor.Event.toFfi`, the event the library delivers for a
window's report of an event: decoded back it is the event, unmarked, and it
is what a post of the event through the library's window input is pulled
back as, but for the stamp. -/
def eventEncodeChecks (_ : Unit) : List Check :=
  [{  name :=
        "an event of each kind a window reports, encoded as the library delivers it, decodes back to itself, unmarked"
      run :=
        return windowKinds.all fun event =>
            match Editor.Event.toFfi event with
            | some delivered =>
              match Editor.Event.ofFfi delivered with
              | .ok received => received.event == event && !received.interrupt
              | .error _ => false
            | none => false },
    { name :=
        "an event of each kind a window reports, posted through the library's window input, is pulled back as its encoding but for the stamp"
      run :=
        windowKinds.allM fun event => do
          unless ← Editor.Event.post event do
            return false
          let some pulled ← pull .editor | return false
          return Editor.Event.toFfi event == some { pulled with stamp := 0 } },
    { name := "an event no window reports has no encoding: a message, a completion, a parse and a quit"
      run :=
        return [Editor.Event.message { kind := .lean, id := 1 } 0 "",
              .completion { kind := .library, id := 1 } 0, .parsed, .quit].all
            fun event => (Editor.Event.toFfi event).isNone }]

/-- The checks of `Editor.Event` against the real library: what Rust posts
arrives in Lean with the same values. -/
def eventChecks (_ : Unit) : List Check :=
  [{  name :=
        "the scripted window's key arrives as a key with its logical key a, its physical key KeyA, and shift and control"
      run := do
        let events ← scriptedEvents
        return events.contains
            (.key
              { logical := .character "a", physical := .code "KeyA"
                modifiers := { shift := true, control := true } } true "a") },
    { name :=
        "the scripted window's pointer arrives as a press of the secondary button at (12.5, 40) with alt, and its resize as 800 by 600 at scale 2"
      run := do
        let events ← scriptedEvents
        return events.contains (.pointer (pointerAt .press (some .secondary))) &&
            events.contains (.resize { width := 800, height := 600, scale := 2.0 }) },
    { name := "every event of the scripted window decodes, each to its own variant, in order"
      run := do
        let events ← scriptedEvents
        return events.length == (windowSample true).length &&
            events.head? == some (.windowOpened "scripted") &&
            events.getLast? == some .closeRequested },
    { name :=
        "a window opened, a focus gained and lost, a key, each composition, each pointer action, a resize out of fullscreen and one in it, files to open, none to open, a request to close, a quit the system asked and two menu items chosen posted as a window would come back from the library equal"
      run := do
        let events : List Editor.Event :=
          [.windowOpened "x", .focus true, .focus false,
            .key
              { logical := .named .escape, physical := .code "Escape"
                modifiers := { superKey := true } } true "",
            .key { logical := .character "é", repeated := true } true "é", .compositionEnabled,
            .preedit "´", .commit "é", .compositionDisabled,
            .pointer (pointerAt .press (some .primary)), .pointer (pointerAt .drag (some .middle)),
            .pointer (pointerAt .release (some (.other 12))),
            .pointer (pointerAt (.wheel (.lines 1 (-2))) none),
            .pointer (pointerAt (.wheel (.pixels 0.25 8)) none),
            .resize { width := 1920, height := 1080, scale := 1.25 },
            .resize { width := 1920, height := 1080, scale := 1.25, fullscreen := true },
            .openFiles ["/Users/me/notes.txt", "/tmp/é x.lean"], .openFiles [], .closeRequested,
            .quitRequested, .menu "undo", .menu "é"]
        events.allM fun event => return (← roundTrip event) == some event },
    { name := "an event no window reports is not posted: a message, a completion and a quit"
      run := do
        let posted ←
          [Editor.Event.message { kind := .lean, id := 1 } 0 "",
                  .completion { kind := .library, id := 1 } 0, .quit].mapM
              Editor.Event.post
        return posted.all (!·) }]

end FfiTest
