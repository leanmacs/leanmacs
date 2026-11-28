import FoldCommands.Compiled

/-!
# The entry module of the Lake package `fold-commands`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base: it imports `FoldCommands.Compiled`, and through it `FoldCommands`
and the core's `Editor.Folds`, so config names the fold command
(`Folds.toggleName`) through the set's base.
-/

namespace FoldCommands.EditorPackage

/-- The packages of the Lake package `fold-commands`, in the order a host
registers them: the one, `fold-commands`. -/
def packages : Array Editor.Package :=
  #[Editor.FoldCommands.package]

end FoldCommands.EditorPackage
