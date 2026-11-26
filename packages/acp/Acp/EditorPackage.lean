import Acp.Packages

/-!
# The entry module of the Lake package `acp`

The module the package-set build reads (`docs/design/packages.md`, "The
package set and its build"). The packages are `Acp.packages`
(`Acp/Packages.lean`), which imports the Rust-backed binding.
-/

namespace Acp.EditorPackage

/-- The packages of the Lake package `acp`: `Acp.packages`. -/
def packages : Array Editor.Package :=
  Acp.packages

end Acp.EditorPackage
