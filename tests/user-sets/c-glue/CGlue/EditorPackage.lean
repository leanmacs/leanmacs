import CGlue

/-! The entry module of the Lake package `c-glue`. -/

namespace CGlue.EditorPackage

/-- The packages of the Lake package `c-glue`. -/
def packages : Array Editor.Package :=
  #[CGlue.package]

end CGlue.EditorPackage
