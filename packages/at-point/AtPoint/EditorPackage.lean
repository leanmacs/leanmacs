import AtPoint.Compiled

/-!
# The entry module of the Lake package `at-point`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base, so config can name what this package declares
(`Completion.AtPoint.words`, to tune the shipped at-point source): it
imports `AtPoint.Compiled`, which imports the rest of the library.
-/

namespace AtPoint.EditorPackage

/-- The packages of the Lake package `at-point`, in the order a host
registers them: the one, `at-point`. -/
def packages : Array Editor.Package :=
  #[Editor.AtPoint.package]

end AtPoint.EditorPackage
