import Editor

/-! A fixture's config is not read: this read is not counted. -/

def setup : SetupM Unit := do
  discard <| Extension.values Skipped.FixtureConfig
