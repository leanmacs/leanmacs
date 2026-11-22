import Editor.Api
import Editor.Command.Model
import Editor.Config.Packages
import Editor.Display
import Editor.Display.Model
import Editor.Event
import Editor.InputScheme.Test
import Editor.Loop.Driver
import Editor.Quit
import Editor.State
import Editor.Test.Driver
import Editor.Test.Ex
import Editor.Test.Frame
import Editor.Test.Hosted
import Editor.Test.Keys
import FrameCommands.Compiled
import FrameCommandsApiTest.Contract
import FrameCommandsTest.Check

/-!
# The tests of `FrameCommands.lean` and `FrameCommands/Compiled.lean`

The tests of the frame commands and of the package that registers them:
`frameCommandChecks`. The test driver `FrameCommandsTest/Model.lean` runs
them; its module doc says what each shows.
-/

namespace FrameCommandsTest

open Editor
open Editor.Test

namespace FrameCommandTest

/-- The registry of the frame command checks: the frame's commands, and the
kit's quit command (`quitPackage`, `lean/Editor/Test/Ex.lean`), under the name
the frame's `s-q` runs, and the frame's bindings, registered for the owner
`compiled`, an owner that is not config, as a host registers a package's,
and `config` as config's bindings. -/
def frameRegistry (config : Array Config.KeyBinding := #[]) : Config.Registry :=
  ((({} : Config.Registry).replace .compiled
            (FrameCommands.package.registered.commands ++
              quitPackage.registered.commands)).replaceBindings
        .compiled FrameCommands.package.registered.bindings).replaceBindings
    .config config

/-- A driver of the frame command checks (the kit's `frameDriverOver`), over
`frameRegistry` unless told otherwise. -/
def frameDriver (registry : Config.Registry := frameRegistry) (held : Bool := false) :
    Option TestDriver :=
  frameDriverOver registry none held

end FrameCommandTest

open FrameCommandTest in
/-- The checks of the frame's commands (`FrameCommands.lean`,
`FrameCommands/Compiled.lean`) and of the frame's last reported
fullscreen state, on the loop's driver over the editor's models and the
test scheme, with the registry's active keymaps. -/
def frameCommandChecks : List Check :=
  [{    name :=
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
      { name :=
          "toggle-fullscreen, run with the window last reported in fullscreen, asks to leave it"
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
                echoOf refused == some (Quit.notQuitting (.unsaved "scratch")) &&
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
                  .ofKeys (keys "s-q") Quit.name] &&
              FrameCommands.toggleFullscreenName == "toggle-fullscreen" &&
              FrameCommands.minimiseName == "minimise-window" &&
              FrameCommands.package.registered.commands.map (·.name) ==
                #["toggle-fullscreen", "minimise-window"] &&
              framed (frameDriver rebound) (presses "C-s-f") == some (#[.minimise], false)) },
      { name :=
          "the frame-commands package registers its two commands, toggle-fullscreen and minimise-window, and its three bindings, and nothing else: no ex name, source, job or menu"
        run :=
          let registry := hostedRegistry #[FrameCommands.package]
          pure
            (FrameCommands.package.name == "frame-commands" &&
              registry.entries.map (·.registration.name) == FrameCommandsApi.names &&
              registry.entries.all (·.owner == FrameCommands.package.owner) &&
              registry.bindings.size == 3 &&
              registry.bindings.all (·.owner == FrameCommands.package.owner) &&
              registry.exNames.isEmpty &&
              registry.sources.isEmpty &&
              registry.jobs.isEmpty &&
              registry.menus.isEmpty) },
      { name :=
          "the contract of frame-commands-api this list runs bites: a package that registers every frame command but minimise-window fails it, on minimise-window's check alone"
        run :=
          let lacking : Package :=
            { name := "lacking"
              setup :=
                for name in FrameCommandsApi.names do
                  unless name == FrameCommandsApi.minimiseName do
                    command name (pure ()) }
          let failing := ((FrameCommandsApiTest.contractChecks lacking).filter (!·.2)).map (·.1)
          pure
            (failing.length == 1 &&
              failing.all fun sentence =>
                (sentence.splitOn s!"`{FrameCommandsApi.minimiseName}`").length > 1) }] ++
    (FrameCommandsApiTest.contractChecks FrameCommands.package).map fun (name, held) =>
      { name, run := pure held }

end FrameCommandsTest
