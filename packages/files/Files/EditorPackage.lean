import Files.Compiled

/-!
# The entry module of the Lake package `files`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base: it imports `Files.Compiled`, and through it `Files` and `Files.Paths`,
so config calls the file commands (`Files.open`, `Files.save`) through the
set's base.
-/

namespace Files.EditorPackage

/-- The packages of the Lake package `files`, in the order a host registers
them: the one, `files`. -/
def packages : Array Editor.Package :=
  #[Editor.Files.package]

end Files.EditorPackage
