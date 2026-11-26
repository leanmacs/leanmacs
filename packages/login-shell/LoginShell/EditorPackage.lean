import LoginShell.Compiled

/-!
# The entry module of the Lake package `login-shell`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base: it imports `LoginShell.Compiled`, and through it `LoginShell`, so
config reaches the package's setting, `LoginShell.timeLimit`, through the
set's base.
-/

namespace LoginShell.EditorPackage

/-- The packages of the Lake package `login-shell`, in the order a host
registers them: the one, `login-shell`. -/
def packages : Array Editor.Package :=
  #[LoginShell.package]

end LoginShell.EditorPackage
