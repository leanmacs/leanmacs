import BrokenElab

/-! The entry module of the Lake package `broken-elab`. -/

namespace BrokenElab.EditorPackage

/-- The packages of the Lake package `broken-elab`. -/
def packages : Array Editor.Package :=
  #[BrokenElab.package]

end BrokenElab.EditorPackage
