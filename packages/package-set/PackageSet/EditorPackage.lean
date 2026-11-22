import PackageSet.Compiled

/-!
# The entry module of the Lake package `package-set`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base: it imports `PackageSet.Compiled`, the `Package` value and the
commands. What the commands edit and build through is the core's
(`lean/Editor/PackageSet/`), which config reaches through the core's
base.
-/

namespace PackageSet.EditorPackage

/-- The packages of the Lake package `package-set`, in the order a host
registers them: the one, `package-set`. -/
def packages : Array Editor.Package :=
  #[Editor.PackageSet.package]

end PackageSet.EditorPackage
