import ModeLine.Compiled

/-!
# The entry module of the Lake package `mode-line`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base: it imports `ModeLine.Compiled`, the `Package` value. Config names
the segments it registers by their names, and their data, which is the
core's (`ModeLine.shipped`), through the core's base.
-/

namespace ModeLine.EditorPackage

/-- The packages of the Lake package `mode-line`, in the order a host
registers them: the one, `mode-line`. -/
def packages : Array Editor.Package :=
  #[Editor.ModeLine.package]

end ModeLine.EditorPackage
