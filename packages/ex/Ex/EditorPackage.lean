import Ex.Compiled

/-!
# The entry module of the Lake package `ex`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base: it imports `Ex.Compiled`, the `Package` value, and through it `Ex`,
the commands, which the config base `Editor` imported while the ex line
was the core's, so config calls an ex command (`Ex.run`, `Ex.quitCommand`)
and names one (`Ex.name`) through the set's base.
-/

namespace Ex.EditorPackage

/-- The packages of the Lake package `ex`, in the order a host registers
them: the one, `ex`. -/
def packages : Array Editor.Package :=
  #[Editor.Ex.package]

end Ex.EditorPackage
