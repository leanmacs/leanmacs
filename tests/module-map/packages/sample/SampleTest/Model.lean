import Sample

/-! A test library's module is not read: this read is not counted. -/

def moduleReads : EditorM Unit := do
  discard <| Extension.values Skipped.TestModule
