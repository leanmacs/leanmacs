import Workspace.Compiled

/-!
# The entry module of the Lake package `workspace`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base: it imports `Workspace.Compiled`, and through it the package's other
modules, so config calls the workspaces' commands and reads their names
through the set's base.
-/

namespace Workspace.EditorPackage

/-- The packages of the Lake package `workspace`, in the order a host
registers them: the one, `workspace`. -/
def packages : Array Editor.Package :=
  #[Editor.Workspace.package]

end Workspace.EditorPackage
