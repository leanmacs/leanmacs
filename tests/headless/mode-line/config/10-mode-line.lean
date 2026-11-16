-- A segment of this config's own, `greeting`, and a mode line that lists
-- segments for each side: three shipped ones on the left and one nobody
-- registered, `nope`, which is left out and said; the config's own and two
-- shipped ones on the right.
def setup : SetupM Unit := do
  defineSegment "greeting" fun _ =>
    #[{ text := "hi", face := ⟨"mode-line.secondary"⟩, padding := 4 }]
  modeLine ["state", "buffer", "modified", "nope"] ["greeting", "line-column", "position"]
