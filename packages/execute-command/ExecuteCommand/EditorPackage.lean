import ExecuteCommand.Compiled

/-!
# The entry module of the Lake package `execute-command`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. It is also a module of that set's config
base, so config can name what this package declares
(`ExecuteCommand.executeCommand`, `ExecuteCommand.label`): it imports
`ExecuteCommand.Compiled`, which imports the rest of the library.
-/

namespace ExecuteCommand.EditorPackage

/-- The packages of the Lake package `execute-command`, in the order a
host registers them: the one, `execute-command`. -/
def packages : Array Editor.Package :=
  #[Editor.ExecuteCommand.package]

end ExecuteCommand.EditorPackage
