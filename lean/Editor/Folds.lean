import Editor.Extension
import Editor.Fold
import Editor.Jumps
import Editor.Mode

/-!
# Folding and unfolding a buffer's sections

A buffer's foldable ranges are its owner's data (`Buffer.folds`,
`Editor/Fold.lean`); this module folds and unfolds the one under the cursor
from the keyboard (`docs/design/text-and-display.md`, "Folds, as built").
The core holds every decision and declares the names; the package
`fold-commands` registers them (`Folds.setup`), as `link-commands` registers
the link commands. Leaving the package out leaves toggling out: folds are
still drawn, and still honoured by motion.

- **The folds mode** (`mode`, named `Folds.modeName`) fills `toggle` with
  `fold-toggle`. Its keymaps go after the links mode's and before a
  buffer's minor and major modes' in a buffer with any foldable range
  (`Config.Registry.activeMaps`), so on a foldable range toggling a fold
  takes precedence over the mode's own `toggle`. A buffer with no foldable
  range, such as `version-control`'s status buffer or acp's conversation,
  keeps its own `toggle`.
- **Toggling** (`toggle`, `fold-toggle`) acts on the ranges whose covered
  rows hold the cursor's row (`Fold.toggleTarget`): the outermost folded
  one is unfolded, and with none folded the innermost one is folded and
  the cursor put at its start (`Jumps.placeCursor`), so it is on the
  placeholder. Neither touches the text, so its content and revision stay
  as they were.
- **Off every foldable range** it runs the command the buffer's own modes
  fill `toggle` with (`RegistryRequest.roleCommand`, which never asks the
  folds mode), inside itself, with the same call, guarded against calling
  itself; with none it says `fold-toggle: no fold at the cursor`. This is
  `link-follow`'s fall-through (`Editor/Links.lean`).

## Where an addition goes

| Addition | Where |
|---|---|
| A new command over folds (fold all, unfold all) | A role (`Editor/Role.lean`) when a scheme should put it on a key, a command here, its entry in `mode` and `setup`, and a check in `ModelTest.foldToggleChecks` |
| A new lookup over foldable ranges | `Editor/Fold.lean` |

Pinned by `ModelTest.foldToggleChecks` and `ModelTest.foldRegenerateChecks`,
and the package's registrations by `FoldCommandsTest.foldCommandsChecks`.
-/

namespace Editor.Folds

/-- The name `toggle` is registered under. -/
def toggleName : String :=
  "fold-toggle"

/-- The folds mode: it fills `toggle` with `fold-toggle`, and its keymaps go
after the links mode's in a buffer with foldable ranges
(`Config.Registry.activeMaps`). -/
def mode : Mode :=
  { name := modeName
    roles := [(Role.toggle, toggleName)]
    roleDescs := [(Role.toggle, "Fold or unfold the section")] }

/-- `fold-toggle`: folds or unfolds the range under the cursor, or, off
every foldable range, runs the command the buffer's own modes fill `toggle`
with ("Toggling" and "Off every foldable range", in the module docs). -/
def toggle (call : Call) : EditorM Unit := do
  let selection ← call.target.selection
  let some range := selection.ranges[selection.primary]? | return
  let buffer := call.target.buffer
  let id := call.target.window.buffer
  let covered ← id.foldsCovered
  let row ← Fold.rowOf buffer.text (← buffer.text.byteLength) range.head
  match Fold.toggleTarget covered row with
  | some (key, folded) =>
    discard <| id.setFolded key folded
    if folded then
      if let some (_, first, _) := covered.find? (·.1.key == key) then
        Jumps.placeCursor call.target.window.id (← buffer.text.offsetOf ⟨first, 0⟩)
  | none =>
    match ← RegistryRequest.ask (.roleCommand buffer.major buffer.minors Role.toggle) with
    | some name =>
      -- A mode of the buffer's own that names this command would run it
      -- again for ever.
      if name == toggleName then
        message s!"{toggleName}: no fold at the cursor"
      else
        discard <| runCommand name call
    | none =>
      message s!"{toggleName}: no fold at the cursor"

/-- Registers the command `fold-toggle` and the folds mode, under the names
the core declares: the package `fold-commands`'s `setup`, and the core's
tests'. -/
def setup : SetupM Unit := do
  commandWith toggleName toggle
  defineMode mode

end Editor.Folds
