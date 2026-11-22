import Evil.Compiled
import Evil.Theorems

/-!
# The entry module of the Lake package `evil`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's.

It also declares `scheme`: this Lake package's lakefile declares the
keyword `editor-input-scheme`, so the build hands
`Evil.EditorPackage.scheme` to `Editor.Main.run` beside the packages
(`docs/design/packages.md`, "Input schemes"), and the editor's hosts run
it: the Vim scheme. The value is `Editor.Evil.scheme`, of
`Evil/Compiled.lean` ("The scheme"), so this module holds no declaration
of the scheme's own.

It is also a module of that set's config base. It imports `Evil.Compiled`,
the `Package` value, which brings every module the config base `Editor`
imported while evil was the core's but one: the commands' modules
(`Evil.Clipboard`, `Evil.Jumps`, `Evil.Operators`, `Evil.Repeat`,
`Evil.Scroll`, `Evil.TreeObjects`, `Evil.Undo`, with `Evil`, the motions,
the text objects and the registers) and the scheme's default states and
bindings (`Evil.Vim.Default`, with the scheme). The one it does not bring,
what is proved of evil on the text model (`Evil.Theorems`), is imported
here by name, so that the build checks the proofs. An import of a module
`Evil.Compiled` already brings is redundant, and the formatter's check
refuses it. So config calls evil's commands and names its vocabularies
(`Evil.move Evil.motions`, `Vim.Bound`) through the set's base, as it did
through `Editor`.
-/

namespace Evil.EditorPackage

/-- The packages of the Lake package `evil`, in the order a host registers
them: the one, `evil`. -/
def packages : Array Editor.Package :=
  #[Editor.Evil.package]

/-- The input scheme the Lake package `evil` supplies: the Vim scheme. -/
def scheme : Editor.SchemePackage :=
  Editor.Evil.scheme

end Evil.EditorPackage
