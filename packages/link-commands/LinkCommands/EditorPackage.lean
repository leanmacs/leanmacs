import LinkCommands.Compiled

/-!
# The entry module of the Lake package `link-commands`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base: it imports `LinkCommands.Compiled`, and through it `LinkCommands`
and the core's `Editor.Links`, so config names a link command
(`Links.followName`) and registers a reference resolver (`Links.Resolver`)
through the set's base.
-/

namespace LinkCommands.EditorPackage

/-- The packages of the Lake package `link-commands`, in the order a host
registers them: the one, `link-commands`. -/
def packages : Array Editor.Package :=
  #[Editor.LinkCommands.package]

end LinkCommands.EditorPackage
