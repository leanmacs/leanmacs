import TabCommands.Compiled

/-!
# The entry module of the Lake package `tab-commands`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base: it imports `TabCommands.Compiled`, the `Package` value, and through
it `TabCommands`, the commands, which the config base `Editor` imported
while the tab commands were the core's, so config calls a tab command
(`TabCommands.new`) and names one (`TabCommands.newName`) through the set's
base.
-/

namespace TabCommands.EditorPackage

/-- The packages of the Lake package `tab-commands`, in the order a host
registers them: the one, `tab-commands`. -/
def packages : Array Editor.Package :=
  #[Editor.TabCommands.package]

end TabCommands.EditorPackage
