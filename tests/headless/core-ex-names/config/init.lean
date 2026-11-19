import Editor
open Editor

-- A config that registers nothing, so every ex name the script types is
-- answered by what the packages compiled into the editor bound.
def setup : SetupM Unit :=
  pure ()
