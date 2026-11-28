import Editor.Package
import FoldCommands

/-!
# The `fold-commands` package

What a host registers so that a buffer's foldable ranges are folded and
unfolded from the keyboard (`FoldCommands.lean`): the package
`fold-commands` (`FoldCommands.package`, `lean/Editor/Package.lean`), whose
`setup` is the core's `Folds.setup`. A host registers it for the owner
`fold-commands` when its loop starts, before any config
(`lean/Editor/Config/Packages.lean`). Both of the executable's hosts are
handed it, through the entry module of the Lake package `fold-commands`
(`FoldCommands/EditorPackage.lean`).

This module is apart from `FoldCommands.lean` because it is what a host is
handed, not what config calls.

Pinned by `FoldCommandsTest.foldCommandsChecks`.
-/

namespace Editor.FoldCommands

/-- The package `fold-commands`: `fold-toggle` and the folds mode. -/
def package : Package :=
  { name := "fold-commands", setup }

end Editor.FoldCommands
