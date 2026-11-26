import Mise.Compiled

/-!
# The entry module of the Lake package `mise`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base: it imports `Mise.Compiled`, and through it `Mise`, so config reaches
the package's setting, `Mise.executable`, through the set's base.
-/

namespace Mise.EditorPackage

/-- The packages of the Lake package `mise`, in the order a host registers
them: the one, `mise`. -/
def packages : Array Editor.Package :=
  #[Mise.package]

end Mise.EditorPackage
