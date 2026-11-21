import Buffers.Compiled

/-!
# The entry module of the Lake package `buffers`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base: it imports `Buffers.Compiled`, and through it `Buffers`, so config
calls the buffer commands (`Buffers.switchCommand`, `Buffers.listCommand`,
`Buffers.closeCommand`) through the set's base.
-/

namespace Buffers.EditorPackage

/-- The packages of the Lake package `buffers`, in the order a host
registers them: the one, `buffers`. -/
def packages : Array Editor.Package :=
  #[Editor.Buffers.package]

end Buffers.EditorPackage
