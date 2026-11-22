import Sample

/-! A test library's root is not read: this read is not counted. -/

def rootReads : EditorM Unit := do
  discard <| Extension.values Skipped.TestRoot
