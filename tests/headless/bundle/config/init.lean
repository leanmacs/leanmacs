import Editor
import Lean
open Editor

-- The config `mise run bundle-test` loads from a staged bundle. Its command
-- calls compiled code of `Init` (`List.range`, `List.map`, `Nat.repr`,
-- `String.intercalate`) and of `Editor` (`createText`, `append`), so a
-- module file that only running it needs, and not elaborating it, would be
-- missed here.
--
-- It imports `Lean`, which the editor's base does not hold, and names a
-- declaration of Lean's elaborator, which no module of the base imports:
-- the base grows to hold `Lean` from the module files the bundle carries,
-- and the config elaborates only if the bundle carries them.
def squares : EditorM Unit := do
  let text ← createText (", ".intercalate ((List.range 4).map fun n => toString (n * n)))
  append text " from the bundle"

/-- A program of Lean's elaborator, never run: it elaborates only on a base
that holds `Lean`. -/
def fromLean : Lean.Elab.Command.CommandElabM Unit :=
  pure ()

def setup : SetupM Unit := do
  command "squares" squares
