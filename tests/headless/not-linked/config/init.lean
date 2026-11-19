-- A root that imports a module that is not linked into the editor: `Lake`
-- is in the Lean toolchain, and no editor links it. The reload is rejected
-- before anything is elaborated, with a diagnostic at the import.

import Editor
import Lake

open Editor

def setup : SetupM Unit :=
  command "greet" (message "never said")
