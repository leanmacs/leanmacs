import Editor.Config.Registry
import Editor.FrameCommands

/-!
# The frame's commands and their bindings, as compiled code registers them

What a host is handed so that the window can be put in fullscreen and
minimised from the keyboard (`Editor/FrameCommands.lean`): the registrations
of the two commands, and their default key bindings. A host registers both
for the owner `compiled` when its loop starts, before any config
(`Editor/Config/Registry.lean`, "Compiled commands"), so they hold when
config fails to load, and config's binding of the same keys is the one that
runs while config binds them.

- **`FrameCommands.commands`**: `toggle-fullscreen` and `minimise-window`,
  in that order, each a plain command.
- **`FrameCommands.bindings`**: `C-s-f` (Control and the system key,
  Command on macOS, with `f`: the macOS shortcut for fullscreen) runs
  `toggle-fullscreen`, and `s-m` (Command-M) runs `minimise-window`. The
  window's event loop is built without winit's default menu, so neither
  chord is a menu item's and both reach the window.

This module is apart from `Editor/FrameCommands.lean` because it names the
registry, which is the config session's.

Pinned by `ModelTest.frameCommandChecks`, on the models.
-/

namespace Editor.FrameCommands

/-- The frame's commands, as a host registers them for the owner
`compiled`. -/
def commands : Array Config.Registration :=
  #[{ name := toggleFullscreenName, action := .plain toggleFullscreen },
    { name := minimiseName, action := .plain minimise }]

/-- The chord `f` with Control and the system key held: `C-s-f`. -/
def fullscreenChord : Key :=
  Key.chord { logical := .character "f", modifiers := { control := true, superKey := true } }

/-- The chord `m` with the system key held: `s-m`. -/
def minimiseChord : Key :=
  Key.chord { logical := .character "m", modifiers := { superKey := true } }

/-- The frame's default key bindings, as a host registers them for the
owner `compiled`. -/
def bindings : Array Config.KeyBinding :=
  #[{ keys := [fullscreenChord], command := toggleFullscreenName },
    { keys := [minimiseChord], command := minimiseName }]

end Editor.FrameCommands
