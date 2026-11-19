import Editor.Api
import Editor.Command.Model
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Display
import Editor.Display.Model
import Editor.Event
import Editor.Ex
import Editor.FrameCommands
import Editor.FrameCommands.Compiled
import Editor.InputScheme.Test
import Editor.Loop
import Editor.Loop.Driver
import Editor.State
import Editor.Test.Driver
import Editor.Test.Keys
import ModelTest.Check
import ModelTest.Support.Frame

/-!
# Model tests: `Editor/FrameCommands.lean`

The model tests of `Editor/FrameCommands.lean`: `frameCommandChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The checks of the frame's commands (`Editor/FrameCommands.lean`,
`Editor/FrameCommands/Compiled.lean`) and of the frame's last reported
fullscreen state, on the loop's driver over the editor's models and the
test scheme, with the registry's active keymaps. -/
def frameCommandChecks : List Check :=
  [{  name :=
        "a resize in fullscreen sets the frame's last reported state, and a resize out of it clears it"
      run :=
        pure <|
          match frameDriver with
          | none => false
          | some driver =>
            let entered := (fedTo driver [resizedTo true]).1
            let left := (fedTo entered [resizedTo false]).1
            !driver.loop.state.frame.fullscreen && entered.loop.state.frame.fullscreen &&
              !left.loop.state.frame.fullscreen &&
              left.model.display.asked.isEmpty },
    { name :=
        "toggle-fullscreen, run with the window last reported windowed, asks the display to enter fullscreen and nothing else, and leaves the frame's state as it was"
      run := pure (framed frameDriver (presses "C-s-f") == some (#[.enterFullscreen], false)) },
    { name := "toggle-fullscreen, run with the window last reported in fullscreen, asks to leave it"
      run :=
        pure
          (framed frameDriver (resizedTo true :: presses "C-s-f") ==
            some (#[.leaveFullscreen], true)) },
    { name :=
        "C-s-f runs toggle-fullscreen: pressed twice with a resize in fullscreen between, it asks to enter and then to leave"
      run :=
        pure
          (framed frameDriver (presses "C-s-f" ++ [resizedTo true] ++ presses "C-s-f") ==
            some (#[.enterFullscreen, .leaveFullscreen], true)) },
    { name := "s-m runs minimise-window, which asks the display to minimise the window"
      run := pure (framed frameDriver (presses "s-m") == some (#[.minimise], false)) },
    { name :=
        "s-q runs quit: with a buffer that holds a file edited, it is refused with the quit command's message and the driver goes on; with nothing unsaved it stops the driver"
      run :=
        pure <|
          match frameDriver (held := true) with
          | none => false
          | some driver =>
            let (refused, _) := fedTo driver ([.commit "x"] ++ presses "s-q")
            let (left, steps) := fedTo driver (presses "s-q")
            !refused.stopped && !refused.loop.state.quitting &&
              echoOf refused == some (Ex.notQuitting (.unsaved "scratch")) &&
              left.stopped &&
              steps.back?.join.map (·.next) == some .stop },
    { name :=
        "the compiled bindings are C-s-f to toggle-fullscreen, s-m to minimise-window and s-q to quit, and config's binding of C-s-f is the one that runs while config binds it"
      run :=
        let rebound := frameRegistry #[.ofKeys (keys "C-s-f") FrameCommands.minimiseName]
        pure
          (FrameCommands.package.registered.bindings ==
              #[.ofKeys (keys "C-s-f") FrameCommands.toggleFullscreenName,
                .ofKeys (keys "s-m") FrameCommands.minimiseName,
                .ofKeys (keys "s-q") Ex.quitName] &&
            FrameCommands.toggleFullscreenName == "toggle-fullscreen" &&
            FrameCommands.minimiseName == "minimise-window" &&
            FrameCommands.package.registered.commands.map (·.name) ==
              #["toggle-fullscreen", "minimise-window"] &&
            framed (frameDriver rebound) (presses "C-s-f") == some (#[.minimise], false)) }]

end ModelTest
