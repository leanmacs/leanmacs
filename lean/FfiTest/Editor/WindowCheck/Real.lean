import Editor.Ffi.Events
import Editor.WindowCheck
import Editor.WindowCheck.Real
import FfiTest.Check
import FfiTest.Support.Queues

/-!
# FFI tests: `Editor/WindowCheck/Real.lean`

The tests of `Editor/WindowCheck/Real.lean`: `decodeChecks`, of
`WindowCheck.decode`. The root module `FfiTest` runs them, and each list's own
doc says what it checks.
-/

namespace FfiTest

/-- An event from the window number 1, of this kind, code and text. -/
def fromWindow (kind : Editor.Ffi.EventKind) (code : UInt64) (text : String := "") :
    Editor.Ffi.Event :=
  { source := { kind := .window, id := 1 }, kind, code, text, stamp := 7 }

/-- The input the keyboard check takes an event from the window for. -/
def decoded (kind : Editor.Ffi.EventKind) (code : UInt64) (text : String := "") :
    Editor.WindowCheck.Input :=
  Editor.WindowCheck.decode (fromWindow kind code text)

/-- The checks of which event of the editor queue is which input to the
keyboard check (`Editor.WindowCheck.decode`): the Lean side of the table in
`crates/editor-ffi/src/window.rs`, row by row, on events built by hand. They
call no binding and need no window. -/
def decodeChecks (_ : Unit) : List Check :=
  [{ name := "an event that a window opened decodes to the platform's name, which is its text",
     run := pure (decoded .windowOpened 0 "winit" == .opened "winit") },
    { name := "a focus event decodes to the focus gained for code 1 and lost for code 0"
      run :=
        pure (decoded .windowFocus 1 == .focus true && decoded .windowFocus 0 == .focus false) },
    { name :=
        "a key event decodes to a key with its text: bit 0 of the code says it was pressed, bit 1 that it is a repeat and bit 2 that the key is dead, each by itself and together"
      run :=
        pure
          (decoded .key 0 == .key false false false "" &&
            decoded .key 1 "a" == .key true false false "a" &&
            decoded .key 2 == .key false true false "" &&
            decoded .key 3 "a" == .key true true false "a" &&
            decoded .key 4 == .key false false true "" &&
            decoded .key 5 == .key true false true "" &&
            decoded .key 7 "x" == .key true true true "x") },
    { name :=
        "a composition event decodes by its code: 0 to enabled, 1 to a preedit of its text, 2 to a commit of its text and 3 to disabled"
      run :=
        pure
          (decoded .composition 0 == .compositionEnabled &&
            decoded .composition 1 "´" == .preedit "´" &&
            decoded .composition 2 "é" == .commit "é" &&
            decoded .composition 3 == .compositionDisabled) },
    { name := "a pointer press and a request to close decode to themselves"
      run :=
        pure
          (decoded .pointer 0 == .pointerPressed && decoded .closeRequested 0 == .closeRequested) },
    { name :=
        "a pointer's drag, release and wheel, and a resize, decode to nothing: the keyboard check counts presses only"
      run :=
        pure
          (decoded .pointer 1 == .other && decoded .pointer 2 == .other &&
            decoded .pointer 3 == .other &&
            decoded .resize 0 == .other) },
    { name := "a quit of the queue decodes to the stop, whatever its source"
      run :=
        pure
          (Editor.WindowCheck.decode
                { source := { kind := .library, id := 0 }, kind := .quit, code := 0, text := ""
                  stamp := 0 } ==
              .stop &&
            decoded .quit 0 == .stop) },
    { name :=
        "a message from the check's stop source decodes to the stop, and one from another Lean source to nothing"
      run :=
        pure
          (Editor.WindowCheck.decode (message Editor.WindowCheck.stopSource 0 "") == .stop &&
            Editor.WindowCheck.decode (message (Editor.WindowCheck.stopSource + 1) 0 "") ==
              .other) },
    { name :=
        "an event of a window's kind from a source that is not a window decodes to nothing: a key from the script source, and a request to close from the library"
      run :=
        pure
          (Editor.WindowCheck.decode
                { fromWindow .key 1 "a" with source := { kind := .script, id := 1 } } ==
              .other &&
            Editor.WindowCheck.decode
                { fromWindow .closeRequested 0 with source := { kind := .library, id := 1 } } ==
              .other) },
    { name :=
        "an event from a window that the table has no row for decodes to nothing: a message, a completion, and a composition with a code past 3"
      run :=
        pure
          (decoded .message 1 "a" == .other && decoded .completion 1 == .other &&
            decoded .composition 4 "é" == .other) }]

end FfiTest
