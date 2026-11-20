import Languages.Compiled

/-!
# The entry module of the Lake package `languages`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base: it imports `Languages.Compiled`, the `Package` value. Config names
the languages it registers by their names, and their data, which is the
core's (`Language.shipped`), through the core's base.
-/

namespace Languages.EditorPackage

/-- The packages of the Lake package `languages`, in the order a host
registers them: the one, `languages`. -/
def packages : Array Editor.Package :=
  #[Editor.Language.package]

end Languages.EditorPackage
