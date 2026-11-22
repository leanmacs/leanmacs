import Minibuffer.Compiled

/-!
# The entry module of the Lake package `minibuffer`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base, so config can name what this package declares (the minibuffer's
commands, `Minibuffer.acceptName` and the rest, to bind them): it imports
`Minibuffer.Compiled`, which imports the rest of the library.
-/

namespace Minibuffer.EditorPackage

/-- The packages of the Lake package `minibuffer`, in the order a host
registers them: the one, `minibuffer`. -/
def packages : Array Editor.Package :=
  #[Editor.Minibuffer.package]

end Minibuffer.EditorPackage
