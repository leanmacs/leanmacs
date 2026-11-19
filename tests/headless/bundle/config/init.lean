import Editor
open Editor

-- The config `mise run bundle-test` loads from a staged bundle. Its command
-- calls compiled code of `Init` (`List.range`, `List.map`, `Nat.repr`,
-- `String.intercalate`) and of `Editor` (`createText`, `append`), so a
-- module file that only running it needs, and not elaborating it, would be
-- missed here. `Editor` imports nothing of `Std` (`config-test
-- bench-modules`), so there is no `Std` code to call.
def squares : EditorM Unit := do
  let text ← createText (", ".intercalate ((List.range 4).map fun n => toString (n * n)))
  append text " from the bundle"

def setup : SetupM Unit := do
  command "squares" squares
