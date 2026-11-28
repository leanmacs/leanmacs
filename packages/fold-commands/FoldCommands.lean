import Editor.Folds

/-!
# The fold commands

The package `fold-commands`'s `setup`: the core's `Folds.setup`
(`lean/Editor/Folds.lean`), which registers `fold-toggle` and the folds
mode under the names the core declares. The core holds every decision;
this package is where they are registered, so leaving it out leaves
toggling out: a buffer's folded ranges are still drawn as their
placeholders, still honoured by motion, and a mode keeps its own `toggle`.

Config reaches the names through this package's entry module, which brings
`Editor.Folds` into the set's config base.

Pinned by `FoldCommandsTest.foldCommandsChecks`.
-/

namespace Editor.FoldCommands

/-- The package's `setup`: the core's `Folds.setup`. -/
def setup : SetupM Unit :=
  Folds.setup

end Editor.FoldCommands
