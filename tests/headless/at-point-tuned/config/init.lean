import Editor
import Editor.Completion.Words
open Editor

-- A config that tunes the shipped at-point source `words`: it defines it
-- again with a pause of 100 milliseconds, so it elaborates only on a base
-- that holds the module that declares it.
def setup : SetupM Unit := do
  defineAtPoint (Completion.AtPoint.words (pause := 100))
