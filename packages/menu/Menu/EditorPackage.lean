import Menu.Compiled

/-!
# The entry module of the Lake package `menu`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base: it imports `Menu.Compiled`, the standard menu and the `Package`
value, so config names the menu that ships (`Menu.standard`) through the
set's base. The menu's types and `defineMenu` are the core's, which config
reaches through the core's base.
-/

namespace Menu.EditorPackage

/-- The packages of the Lake package `menu`, in the order a host registers
them: the one, `menu`. -/
def packages : Array Editor.Package :=
  #[Editor.Menu.package]

end Menu.EditorPackage
