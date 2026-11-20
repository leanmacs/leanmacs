import BrokenLink

/-! The entry module of the Lake package `broken-link`. -/

namespace BrokenLink.EditorPackage

/-- The packages of the Lake package `broken-link`. -/
def packages : Array Editor.Package :=
  #[BrokenLink.package]

end BrokenLink.EditorPackage
