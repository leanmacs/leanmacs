import Editor.Config.Directory
import Editor.Display.Real
import Editor.Face
import Editor.Ffi.Display
import Editor.Headless
import Editor.Test.Linked.Host

/-!
# The linked test kit: Frames

A host that draws on the display's real binding, and the frames a check
compares (`withFramedHost`): the frame the host's display laid out of the
last scene it published, and the frame a second display, over the same
snapshots, lays out of that scene in a theme the check writes. So a check
says which theme a frame was drawn in without reading a colour off it. It
holds no checks of its own.

Published for a package's linked tests, in the namespace
`Editor.Test.Linked`, as the rest of the linked kit is: a module under a
linked root may import neither the real bindings nor the raw ones
(`docs/design/packages.md`, "What a package may import"). The core's own
checks of a face set in config (`ConfigTest.faceChecks`) build the same two
displays themselves.
-/

namespace Editor.Test.Linked

open Editor

/-- Runs `check` against a host stepped on the check's own thread
(`onStage`) over a fresh temporary directory holding `files`, with the real
elaborator and what `compiled` hands it, whose display is the real binding
over the library's layout in cells 8 by 16. The check is handed the session
and `frames`:
given a theme, the host's frame of the last scene it published and the
frame a second display over the same table of snapshots lays out of that
scene in that theme, as text. `frames` throws when the host has made no
display or published no scene. `false` if the check did not hold or the
host did not settle. The directory is removed. -/
def withFramedHost (context : HostContext) (files : List (String × String))
    (check : Session → (Theme → IO (String × String)) → IO Bool) (compiled : Compiled := {}) :
    IO Bool :=
  IO.FS.withTempDir fun directory => do
    writeConfig directory files
    let stage ← Stage.new context context.elaborator (Config.Directory.source directory) compiled
    let library ← Ffi.Display.newCells 8 16
    let made ← IO.mkRef (none : Option Headless.Host.Display)
    let collaborators :=
      { stage.collaborators with
        display := fun snapshots => do
          let display ←
            Headless.Host.Display.real (← RealDisplay.over library snapshots Theme.builtin)
          made.set (some display)
          return display }
    -- The second display, over the same table of snapshots.
    let mirror ←
      RealDisplay.over (← Ffi.Display.newCells 8 16) collaborators.published.reader Theme.builtin
    onStage { stage with collaborators } fun drive stage => do
        let frames (theme : Theme) : IO (String × String) := do
          let some display ← made.get | throw (IO.userError "the host made no display")
          let some scene ← display.last? | throw (IO.userError "the host published no scene")
          mirror.setTheme theme
          mirror.publish scene
          return (← library.frameText, ← mirror.display.frameText)
        check (Session.ofStage drive directory stage) frames

end Editor.Test.Linked
