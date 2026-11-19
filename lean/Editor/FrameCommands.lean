import Editor.Api

/-!
# The frame's commands

The commands that ask the platform's window, the frame (`Editor.Frame`), to
do something, through the display interface (`Display.askFrame`,
`Editor/Display.lean`, "Asking the window"):

- **`toggle-fullscreen`** (`toggleFullscreen`) asks the window to leave the
  system's fullscreen when it last said it is in it
  (`Frame.fullscreen`), and to enter it otherwise. It changes no state: the
  frame's state follows the window's next resize, which says whether the
  window is in fullscreen, whether this command or the user (the green
  button) put it there.
- **`minimise-window`** (`minimise`) asks the window to minimise.

They are a package's: a host registers them for the owner
`frame-commands`, with their default bindings, `C-s-f` and `s-m`
(`Editor/FrameCommands/Compiled.lean`), so config can call them and rebind
their keys. `Editor.lean` imports this module, and not that one, which is
what a host is handed.

Pinned by `ModelTest.frameCommandChecks`, on the models.
-/

namespace Editor.FrameCommands

/-- The name `toggleFullscreen` is registered under. -/
def toggleFullscreenName : String :=
  "toggle-fullscreen"

/-- The name `minimise` is registered under. -/
def minimiseName : String :=
  "minimise-window"

/-- Asks the window to leave the system's fullscreen when it last said it is
in it, and to enter it otherwise. It changes no state. -/
def toggleFullscreen : EditorM Unit := do
  let state ← editorState
  Display.askFrame (if state.frame.fullscreen then .leaveFullscreen else .enterFullscreen)

/-- Asks the window to minimise. -/
def minimise : EditorM Unit :=
  Display.askFrame .minimise

end Editor.FrameCommands
