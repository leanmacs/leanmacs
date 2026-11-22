import WindowCommands.Compiled

/-!
# The entry module of the Lake package `window-commands`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base: it imports `WindowCommands.Compiled`, the `Package` value, and
through it `WindowCommands`, the commands, which the config base `Editor`
imported while the window commands were the core's, so config calls a
window command (`WindowCommands.split`) and names one
(`WindowCommands.splitName`) through the set's base.
-/

namespace WindowCommands.EditorPackage

/-- The packages of the Lake package `window-commands`, in the order a host
registers them: the one, `window-commands`. -/
def packages : Array Editor.Package :=
  #[Editor.WindowCommands.package]

end WindowCommands.EditorPackage
