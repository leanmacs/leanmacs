import HelloInit

/-! The entry module of the Lake package `hello-init`. -/

namespace HelloInit.EditorPackage

/-- The packages of the Lake package `hello-init`. -/
def packages : Array Editor.Package :=
  #[HelloInit.package]

end HelloInit.EditorPackage
