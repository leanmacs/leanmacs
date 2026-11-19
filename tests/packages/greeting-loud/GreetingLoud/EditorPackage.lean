import GreetingLoud

/-!
# The entry module of the Lake package `greeting-loud`

The module the package-set build reads (`docs/design/packages.md`, "The
package set and its build"). The generated root registers these after the
packages of `greeting`, which this Lake package requires.
-/

namespace GreetingLoud.EditorPackage

/-- The packages of the Lake package `greeting-loud`, in the order a host
registers them. -/
def packages : Array Editor.Package :=
  #[GreetingLoud.package]

end GreetingLoud.EditorPackage
