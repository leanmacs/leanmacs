import Editor.FrameCommands
import Editor.Package
import Editor.Quit

/-!
# The `frame-commands` package: the frame's commands and their bindings

What a host registers so that the window can be put in fullscreen,
minimised and quit from the keyboard (`Editor/FrameCommands.lean`): the
package `frame-commands` (`FrameCommands.package`, `Editor/Package.lean`),
whose `setup` registers the two frame commands and the default key
bindings. A host registers it for the owner `frame-commands` when its loop
starts, before any config (`Editor/Config/Packages.lean`), so they hold
when config fails to load, and config's binding of the same keys is the one
that runs while config binds them.

- **The commands**: `toggle-fullscreen` and `minimise-window`,
  in that order, each a plain command.
- **The bindings** (`bindKeys`, of the chords below): `C-s-f` (Control and the system key,
  Command on macOS, with `f`: the macOS shortcut for fullscreen) runs
  `toggle-fullscreen`, and `s-m` (Command-M) runs `minimise-window`. Both
  chords are the key equivalents of the Window menu's Enter Full Screen and
  Minimise (`packages/menu/Menu/Compiled.lean`), which the menu bar takes from
  these bindings: on macOS AppKit runs the item before the key reaches the
  window, and the item runs the same command.
- **`s-q`** (Command-Q) runs `quit` (`Quit.name`), so Command-Q follows
  the rule `:q` and the close button follow (`Editor/Quit.lean`; `Editor/Ex.lean`, "A window's
  close request"). On macOS it is the application menu's Quit, a system
  item AppKit runs before the key reaches the window: it reaches the loop
  as the system's quit, which runs the same command (`Editor/Loop.lean`,
  "Quit"). Where no menu takes the chord, as headless, the key runs it. The
  command is the ex line's, so a host must be handed the `ex` package too
  (`Editor/Ex/Compiled.lean`) for the key to run anything.

This module is apart from `Editor/FrameCommands.lean` because it is what a
host is handed, not what config calls.

Pinned by `ModelTest.frameCommandChecks`, on the models.
-/

namespace Editor.FrameCommands

/-- The chord `f` with Control and the system key held: `C-s-f`. -/
def fullscreenChord : Key :=
  Key.chord { logical := .character "f", modifiers := { control := true, superKey := true } }

/-- The chord `m` with the system key held: `s-m`. -/
def minimiseChord : Key :=
  Key.chord { logical := .character "m", modifiers := { superKey := true } }

/-- The chord `q` with the system key held: `s-q`. -/
def quitChord : Key :=
  Key.chord { logical := .character "q", modifiers := { superKey := true } }

/-- The package `frame-commands`: the frame's commands and their default
key bindings, `C-s-f`, `s-m` and `s-q`. -/
def package : Package :=
  { name := "frame-commands"
    setup := do
      command toggleFullscreenName toggleFullscreen
      command minimiseName minimise
      bindKeys [fullscreenChord] toggleFullscreenName
      bindKeys [minimiseChord] minimiseName
      bindKeys [quitChord] Quit.name }

end Editor.FrameCommands
