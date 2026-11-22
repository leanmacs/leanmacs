import Editor.Api
import FrameCommandsApi

/-!
# The frame's commands

The commands that ask the platform's window, the frame (`Editor.Frame`), to
do something, through the display interface (`Display.askFrame`,
`lean/Editor/Display.lean`, "Asking the window"). A module of the Lake
package `frame-commands` (`packages/frame-commands/`) since the
features-as-packages roadmap's phase 8; its declarations keep their names
(`Editor.FrameCommands.…`). The commands' names are the interface
package's (`FrameCommandsApi`, `packages/frame-commands-api/`), which
whoever reaches a frame command by name, as the Window menu's items do,
imports in this module's place:

- **`toggle-fullscreen`** (`toggleFullscreen`) asks the window to leave the
  system's fullscreen when it last said it is in it
  (`Frame.fullscreen`), and to enter it otherwise. It changes no state: the
  frame's state follows the window's next resize, which says whether the
  window is in fullscreen, whether this command or the user (the green
  button) put it there.
- **`minimise-window`** (`minimise`) asks the window to minimise.

They are a package's: a host registers them for the owner
`frame-commands`, with their default bindings, `C-s-f` and `s-m`
(`FrameCommands/Compiled.lean`), so config can call them and rebind
their keys. The package's entry module brings this module into the set's
config base (`FrameCommands/EditorPackage.lean`).

Pinned by `FrameCommandsTest.frameCommandChecks`, on the models.
-/

namespace Editor.FrameCommands

/-- The name `toggleFullscreen` is registered under: the interface
package's. -/
def toggleFullscreenName : String :=
  FrameCommandsApi.toggleFullscreenName

/-- The name `minimise` is registered under: the interface package's. -/
def minimiseName : String :=
  FrameCommandsApi.minimiseName

/-- Asks the window to leave the system's fullscreen when it last said it is
in it, and to enter it otherwise. It changes no state. -/
def toggleFullscreen : EditorM Unit := do
  let state ← editorState
  Display.askFrame (if state.frame.fullscreen then .leaveFullscreen else .enterFullscreen)

/-- Asks the window to minimise. -/
def minimise : EditorM Unit :=
  Display.askFrame .minimise

end Editor.FrameCommands
