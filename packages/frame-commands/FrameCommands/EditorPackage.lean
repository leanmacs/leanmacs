import FrameCommands.Compiled

/-!
# The entry module of the Lake package `frame-commands`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base: it imports `FrameCommands.Compiled`, the `Package` value, and
through it `FrameCommands`, the commands, which the config base `Editor`
imported while the frame commands were the core's, so config calls a
frame command (`FrameCommands.toggleFullscreen`) and names one
(`FrameCommands.minimiseName`) through the set's base.
-/

namespace FrameCommands.EditorPackage

/-- The packages of the Lake package `frame-commands`, in the order a host
registers them: the one, `frame-commands`. -/
def packages : Array Editor.Package :=
  #[Editor.FrameCommands.package]

end FrameCommands.EditorPackage
