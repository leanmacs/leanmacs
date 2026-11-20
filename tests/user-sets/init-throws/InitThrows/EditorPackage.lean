import InitThrows

/-! The entry module of the Lake package `init-throws`. -/

namespace InitThrows.EditorPackage

/-- The packages of the Lake package `init-throws`. -/
def packages : Array Editor.Package :=
  #[InitThrows.package]

end InitThrows.EditorPackage
