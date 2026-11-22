import Restore.Compiled

/-!
# The entry module of the Lake package `restore`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base: it imports `Restore.Compiled`, the `Package` value. The work that
value registers is the core's (`lean/Editor/Restore/Run.lean`,
`lean/Editor/Restore/Restart.lean`), which config reaches through the
core's base.
-/

namespace Restore.EditorPackage

/-- The packages of the Lake package `restore`, in the order a host
registers them: the one, `restore`. -/
def packages : Array Editor.Package :=
  #[Editor.Restore.package]

end Restore.EditorPackage
