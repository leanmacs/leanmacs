import Themes.Compiled

/-!
# The entry module of the Lake package `themes`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's and evil's. It is also a module of that
set's config base: it imports `Themes.Compiled`, the `Package` value, and
through it `Themes`, the command, which the config base `Editor` imported
while the themes were the core's, so config calls the command that loads a
theme (`Themes.loadThemeCommand`) through the set's base.
-/

namespace Themes.EditorPackage

/-- The packages of the Lake package `themes`, in the order a host registers
them: the one, `themes`. -/
def packages : Array Editor.Package :=
  #[Editor.Themes.package]

end Themes.EditorPackage
