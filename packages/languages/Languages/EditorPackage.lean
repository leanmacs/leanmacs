import Languages.Compiled
import Languages.Grammars

/-!
# The entry module of the Lake package `languages`

The package-set build reads `packages` from this module, named by the
convention `<P>.EditorPackage` (`docs/design/packages.md`, "A package's
entry module"), and writes it into the root of every set that holds this
Lake package, after the core's. The Lake package carries the keyword
`editor-grammars`, so the generated root lists these packages tagged with
it (`Editor.Package.shipping`), and the grammars of `languages-grammars`
resolve against the directory the set's build staged them in. It is also a
module of that set's config base: it imports `Languages.Compiled` and
`Languages.Grammars`, the `Package` values. Config names the languages they
register by their names, and the data of `languages`', which is the core's
(`Language.shipped`), through the core's base.
-/

namespace Languages.EditorPackage

/-- The packages of the Lake package `languages`, in the order a host
registers them: `languages`, then `languages-grammars`. -/
def packages : Array Editor.Package :=
  #[Editor.Language.package, Languages.Grammars.package]

end Languages.EditorPackage
