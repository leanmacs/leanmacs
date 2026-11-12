import Editor.Ffi
import Editor.WindowCheck

/-!
# The keyboard check over the bindings

What the keyboard check needs of the world (`WindowCheck.Window`,
`Editor/WindowCheck.lean`), answered by the Rust library: the window of one
of its platforms, the editor queue and the input clock. This is the only
module of the check that imports `Editor.Ffi`, so only an executable linked
with the library imports it: the editor, for `editor window-check`, and
`ffi-test`, which runs the check on the library's scripted platform.

It is a thin adapter: each member is one call of a binding. The one thing it
decides is which event of the editor queue is which input (`decode`), and
`main` is where the check is wired to the real window. What the command
line's arguments ask for is decided in the core (`WindowCheck.parse`,
`WindowCheck.withArguments`).

Tests: `decode` is checked on events built by hand, and the record on the
library's scripted platforms, by `ffi-test` (`FfiTest.decodeChecks`,
`FfiTest.windowChecks`). Neither opens a window.

The loop pulls the editor queue with `Ffi.nextEvent`, on the dedicated task
`WindowCheck.check` starts for it: the shape of the headless loop, and of the
command loop to come.
-/

namespace Editor.WindowCheck

/-- The Lean source the check posts its stop from: a message from it on the
editor queue ends the loop. -/
def stopSource : UInt64 :=
  0x77696E646F77

/-- The input an event of the editor queue is to the check. An event from a
window is what the window reported; the check's own stop, and a quit of the
queues, end the loop; anything else is nothing to it. -/
def decode (event : Ffi.Event) : Input :=
  if event.kind == .quit || event.source == { kind := .lean, id := stopSource } then .stop
  else
    if event.source.kind != .window then .other
    else
      match event.kind, event.code with
      | .windowOpened, _ => .opened event.text
      | .windowFocus, code => .focus (code == 1)
      -- Bit 0 is set for a press, bit 1 for a repeat and bit 2 for a dead key.
      | .key, code => .key (code &&& 1 != 0) (code &&& 2 != 0) (code &&& 4 != 0) event.text
      | .composition, 0 => .compositionEnabled
      | .composition, 1 => .preedit event.text
      | .composition, 2 => .commit event.text
      | .composition, 3 => .compositionDisabled
      | .pointerPressed, _ => .pointerPressed
      | .closeRequested, _ => .closeRequested
      | _, _ => .other

/-- The check's window on `platform`: the real one, or the library's
scripted one. `emit` prints a line of the report. -/
def real (platform : Ffi.Platform) (emit : String → IO Unit) : Window :=
  { next := do
      let event ← Ffi.nextEvent .editor
      return (decode event, event.stamp.toNat)
    clock := return (← Ffi.inputClock).toNat
    serviceOnMain := Ffi.mainThreadProbe
    run := Ffi.windowRun platform
    close := Ffi.windowClose platform
    stop := discard <| Ffi.postEvent .editor stopSource 0 ""
    emit }

/-- `editor window-check`: the check on the real window, with the command
line's `arguments` (`withArguments`). It says on stderr what to do with the
window, and prints the report on stdout once the window has closed. The exit
status is 0 when the window ran, 1 when it could not be opened and 2 when the
arguments are not understood.

It quits the queues and exits explicitly: the task that enforces the time
limit may still be running. -/
def main (arguments : List String) : IO UInt32 := do
  let status ← withArguments (real .winit IO.println) arguments IO.eprintln
  (← IO.getStdout).flush
  Ffi.quit
  IO.Process.exit status.toUInt8

end Editor.WindowCheck
