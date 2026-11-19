import ShippedThemes

/-!
# The entry module of the Lake package `shipped-themes`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It imports the package's library alone.
-/

namespace ShippedThemes.EditorPackage

/-- The packages of the Lake package `shipped-themes`, in the order a host
registers them: the one, `shipped-themes`. -/
def packages : Array Editor.Package :=
  #[ShippedThemes.package]

end ShippedThemes.EditorPackage
