import ConfigTest.Editor.Headless
import Editor.RealHost

/-!
# Config tests: `Editor/Window/Real.lean`, the window mode's edge

A module of the wiring set (`AGENTS.md`, "Deterministic concurrency in
tests"; `docs/dev-practices/real-thread-checks.md`): the test module that
mirrors the real adapter's module.

**The real adapter.** `Window.awaitConfig` on a real host: the window
mode's wait for its start-up config. **Why a real thread.** It is the
window mode's edge, over a real loop; its model halves are
`ModelTest/Editor/Window.lean`'s.

`windowModeChecks`: the wait past its patience says nothing on stderr,
wiring only.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.ConfigTest.Editor.Window.Real : Editor.WiringSet :=
  .wiring "the window mode's start-up wait on a real host (Window.awaitConfig)" "it is the window mode's edge, which runs over a real loop thread"

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- The checks of the window mode's edge over a real host. -/
def windowModeChecks (context : Context) : List Check :=
  [{  name :=
        "the window mode's wait for its start-up config, past its patience with the reload still running, says nothing on stderr: its patience is a bound of the window's, not a hang"
      run := do
        -- The reload is held at the gate for good, so the window's wait
        -- reaches its patience; what it says is caught on this thread's
        -- stderr, which `waitHung` would write to.
        let gate ← Gate.new
        let caught ← IO.mkRef ({} : IO.FS.Stream.Buffer)
        let settled ←
          withRealHostOver context slowConfig gate.around id fun session => do
              try
                session.host.send .reload
                let before ← IO.setStderr (IO.FS.Stream.ofBuffer caught)
                try
                  Window.awaitConfig session.host (some heldShort)
                finally
                  discard <| IO.setStderr before
              finally
                gate.open
        let said := String.fromUTF8! (← caught.get).data
        saw (!settled && said.isEmpty) s!"settled={settled} said={said.quote}" }]

end ConfigTest
