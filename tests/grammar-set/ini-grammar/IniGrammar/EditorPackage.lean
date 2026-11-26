import IniGrammar

/-!
# The entry module of the Lake package `ini-grammar`

The module the package-set build reads (`docs/design/packages.md`, "The
package set and its build"). The Lake package carries the keyword
`editor-grammars`, so the generated root lists these packages tagged with
it (`Editor.Package.shipping`).
-/

namespace IniGrammar.EditorPackage

/-- The packages of the Lake package `ini-grammar`, in the order a host
registers them. -/
def packages : Array Editor.Package :=
  #[IniGrammar.package]

end IniGrammar.EditorPackage
