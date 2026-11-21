import Editor.Display
import Editor.Display.Real
import Editor.Face
import Editor.Ffi.Display
import Editor.Ffi.Document
import Editor.Ffi.Events
import Editor.Ffi.Render
import Editor.Ffi.Window
import Editor.Scene
import Editor.Text
import FfiTest.Check
import FfiTest.Support.Queues
import FfiTest.Support.Scenes
import FfiTest.Support.Windows

/-!
# FFI tests: `Editor/Ffi/Render.lean`

The tests of `Editor/Ffi/Render.lean`: `renderChecks`. The root module `FfiTest`
runs them, and each list's own doc says what it checks.
-/

namespace FfiTest

/-- How many frames the library's latest render session was submitted; 0
when none has started. -/
def framesSubmitted : IO UInt64 := do
  return (← Editor.Ffi.renderCounters).map (·.framesSubmitted) |>.getD 0

/-- The checks of the bindings that reach the library's render wiring: the
headless render session, a display bound to the process's presenter, the
journal and the counters of the latest session, and the display's heights.
They check that the bindings reach the wiring, and nothing of the render
loop's scheduler, which is `editor-render`'s: no check waits for time to
pass to see that nothing happens, and none publishes a scene twice to see
what an equal frame does. The process has one presenter, so each check
stops what it starts and asserts only differences it caused. -/
def renderChecks (_ : Unit) : List Check :=
  [{  name :=
        "a bound display's scene reaches the headless render session, which comes to rest, and the frame's entry answers the window input taken before it"
      run := do
        let fixture ← sceneFixture
        Editor.Ffi.Display.present fixture.real.display
        -- An earlier check's window input may still wait for a frame: a
        -- publish with no session running spends it.
        fixture.real.publish (fixture.scene (SceneFixture.own fixture.anchor) #[])
        unless (← Editor.Ffi.renderHeadless) matches .ok () do
          return false
        let before ← framesSubmitted
        let posted ← Editor.Ffi.postInput .resize 0 "" #[64, 48, (1.0 : Float).toBits, 0, 0]
        let some taken ← pull .editor | return false
        fixture.real.publish (fixture.scene (SceneFixture.own fixture.top) #[])
        let submitted := (← framesSubmitted) == before + 1
        -- The step that records rest ends this wait, not a poll of it.
        let rested := (← Editor.Ffi.renderAwaitRest patience.toUInt64) == some true
        let entries := (← Editor.Ffi.renderJournal 0).getD #[]
        let answered := entries.back?.map (·.inputNs) == some taken.stamp
        let stopped ← Editor.Ffi.renderStop
        let _ ← fixture.document.read
        return posted && taken.source.kind == .window && submitted && rested && answered &&
            stopped },
    { name := "a scene published by a display that is not bound reaches no render session"
      run := do
        unless (← Editor.Ffi.renderHeadless) matches .ok () do
          return false
        let fixture ← sceneFixture
        let before ← framesSubmitted
        fixture.real.publish (fixture.scene (SceneFixture.own fixture.top) #[])
        let after ← framesSubmitted
        let stopped ← Editor.Ffi.renderStop
        let _ ← fixture.document.read
        return after == before && stopped },
    { name :=
        "a headless render session asked for while one runs is refused with the library's reason, starting nothing, and the one that runs is stopped once"
      run := do
        unless (← Editor.Ffi.renderHeadless) matches .ok () do
          return false
        let again ← Editor.Ffi.renderHeadless
        let stopped ← Editor.Ffi.renderStop
        let stoppedAgain ← Editor.Ffi.renderStop
        return (match again with
            | .error reason => !reason.isEmpty
            | .ok () => false) &&
            stopped &&
            !stoppedAgain },
    { name :=
        "a display in cells answers its cell's height for a text row, a status row and the bottom row"
      run := do
        let display ← Editor.Ffi.Display.newCells 8 16
        let heights ← display.heights
        let taller ← (← Editor.Ffi.Display.newCells 8 20).heights
        return heights == { text := 16, status := 16, message := 16 } &&
            taller == { text := 20, status := 20, message := 20 } },
    { name :=
        "a theme whose mode line and echo area have a vertical padding reaches layout through the binding: its status row and bottom row are taller by twice it"
      run := do
        let padded : Editor.Theme :=
          #[{ name := ⟨"mode-line"⟩, face := { verticalPadding := some 3 } },
            { name := ⟨"echo-area"⟩, face := { verticalPadding := some 5 } }]
        let fixture ← sceneFixture padded
        let heights ← fixture.real.heights
        let _ ← fixture.document.read
        return heights == { text := 16, status := 22, message := 26 } },
    { name :=
        "a bound display is drawn in the scripted window while it is open, the window's session's counters are read once it has closed, and a scene published then reaches nothing"
      run := do
        let fixture ← sceneFixture
        Editor.Ffi.Display.present fixture.real.display
        let run ← IO.asTask (prio := .dedicated) (Editor.Ffi.windowRun .scripted true)
        -- The window has opened once its first event arrives.
        let some opened ← pull .editor | return false
        fixture.real.publish (fixture.scene (SceneFixture.own fixture.top) #[])
        for _ in [1:(windowSample true).length] do
          let some _ ← pull .editor | break
        Editor.Ffi.windowClose .scripted
        let some ran ← Editor.Job.awaitWithin patience run | return false
        let ran := (← IO.ofExcept ran) matches .ok { nothingDrew := none }
        let drawn ← framesSubmitted
        fixture.real.publish (fixture.scene (SceneFixture.own fixture.anchor) #[])
        let after ← framesSubmitted
        let _ ← fixture.document.read
        return ran && opened.kind == .windowOpened && drawn >= 1 && after == drawn }]

end FfiTest
