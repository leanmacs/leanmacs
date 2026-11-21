import WorkingSet.Compiled

/-!
# The entry module of the Lake package `working-set`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base: it imports `WorkingSet.Compiled`, and through it the package's other
modules, so config reaches the working sets through the set's base.
-/

namespace WorkingSet.EditorPackage

/-- The packages of the Lake package `working-set`, in the order a host
registers them: the one, `working-set`. -/
def packages : Array Editor.Package :=
  #[Editor.WorkingSet.package]

end WorkingSet.EditorPackage
