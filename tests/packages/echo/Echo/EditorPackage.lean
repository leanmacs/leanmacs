import Echo.Packages

/-!
# The entry module of the Lake package `echo`

The module the package-set build reads (`docs/design/packages.md`, "The
package set and its build"). The packages are `Echo.packages`
(`Echo/Packages.lean`), which imports the Rust-backed binding.
-/

namespace Echo.EditorPackage

/-- The packages of the Lake package `echo`: `Echo.packages`, none. -/
def packages : Array Editor.Package :=
  Echo.packages

end Echo.EditorPackage
