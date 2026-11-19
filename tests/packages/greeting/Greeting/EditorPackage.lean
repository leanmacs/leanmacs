import Greeting

/-!
# The entry module of the Lake package `greeting`

The module the package-set build reads (`docs/design/packages.md`, "The
package set and its build"): a Lake package named `p` lists its packages as
`packages` in `<P>.EditorPackage`, and the generated root registers them
after those of every Lake package this one requires.
-/

namespace Greeting.EditorPackage

/-- The packages of the Lake package `greeting`, in the order a host
registers them. -/
def packages : Array Editor.Package :=
  #[Greeting.package]

end Greeting.EditorPackage
