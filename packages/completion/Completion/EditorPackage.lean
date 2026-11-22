import Completion.Compiled

/-!
# The entry module of the Lake package `completion`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base, so config can name what this package declares
(`Completion.Styles.orderless`, `Completion.Displays.minibuffer`): it
imports `Completion.Compiled`, which imports the rest of the library.
-/

namespace Completion.EditorPackage

/-- The packages of the Lake package `completion`, in the order a host
registers them: the one, `completion`. -/
def packages : Array Editor.Package :=
  #[Editor.Completion.package]

end Completion.EditorPackage
