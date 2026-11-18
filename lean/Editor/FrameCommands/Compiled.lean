import Editor.Config.Registry
import Editor.Ex
import Editor.FrameCommands

/-!
# The frame's commands and their bindings, as compiled code registers them

What a host is handed so that the window can be put in fullscreen,
minimised and quit from the keyboard (`Editor/FrameCommands.lean`): the
registrations of the two frame commands, and the default key bindings. A host registers both
for the owner `compiled` when its loop starts, before any config
(`Editor/Config/Registry.lean`, "Compiled commands"), so they hold when
config fails to load, and config's binding of the same keys is the one that
runs while config binds them.

- **`FrameCommands.commands`**: `toggle-fullscreen` and `minimise-window`,
  in that order, each a plain command.
- **`FrameCommands.bindings`**: `C-s-f` (Control and the system key,
  Command on macOS, with `f`: the macOS shortcut for fullscreen) runs
  `toggle-fullscreen`, and `s-m` (Command-M) runs `minimise-window`. Both
  chords are the key equivalents of the Window menu's Enter Full Screen and
  Minimise (`Editor/Menu/Compiled.lean`), which the menu bar takes from
  these bindings: on macOS AppKit runs the item before the key reaches the
  window, and the item runs the same command.
- **`s-q`** (Command-Q) runs `quit` (`Ex.quitName`), so Command-Q follows
  the rule `:q` and the close button follow (`Editor/Ex.lean`, "A window's
  close request"). On macOS it is the application menu's Quit, a system
  item AppKit runs before the key reaches the window: it reaches the loop
  as the system's quit, which runs the same command (`Editor/Loop.lean`,
  "Quit"). Where no menu takes the chord, as headless, the key runs it. The
  command is the ex line's, so a host must be handed `Ex.commands` too for
  the key to run anything.

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

/-- The chord `q` with the system key held: `s-q`. -/
def quitChord : Key :=
  Key.chord { logical := .character "q", modifiers := { superKey := true } }

/-- The frame's default key bindings, as a host registers them for the
owner `compiled`. -/
def bindings : Array Config.KeyBinding :=
  #[.ofKeys [fullscreenChord] toggleFullscreenName, .ofKeys [minimiseChord] minimiseName,
    .ofKeys [quitChord] Ex.quitName]

end Editor.FrameCommands
