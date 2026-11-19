import Compile.Compiled

/-!
# The entry module of the Lake package `compile`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base, so config can name what this package declares (`Compile.cargoMode`,
`Compile.Format`): it imports `Compile.Compiled`, which imports the rest of
the library.
-/

namespace Compile.EditorPackage

/-- The packages of the Lake package `compile`, in the order a host
registers them: the one, `compile`. -/
def packages : Array Editor.Package :=
  #[Editor.Compile.package]

end Compile.EditorPackage
