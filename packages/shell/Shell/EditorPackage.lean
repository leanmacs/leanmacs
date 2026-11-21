import Shell.Compiled

/-!
# The entry module of the Lake package `shell`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base: it imports `Shell.Compiled`, and through it the package's other
modules, so config reaches the shell through the set's base.
-/

namespace Shell.EditorPackage

/-- The packages of the Lake package `shell`, in the order a host
registers them: the one, `shell`. -/
def packages : Array Editor.Package :=
  #[Editor.Shell.package]

end Shell.EditorPackage
