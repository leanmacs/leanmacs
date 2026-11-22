import VersionControl.Compiled

/-!
# The entry module of the Lake package `version-control`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base: it imports `VersionControl.Compiled`, and through it the package's
other modules, so config reaches version control, its commit and its stage
among them, through the set's base.
-/

namespace VersionControl.EditorPackage

/-- The packages of the Lake package `version-control`, in the order a host
registers them: `version-control`, then its gutter's,
`version-control-gutter`, whose segment and jobs follow the commands' as
they did in the core's list. -/
def packages : Array Editor.Package :=
  #[Editor.VersionControl.package, Editor.VersionControl.gutterPackage]

end VersionControl.EditorPackage
