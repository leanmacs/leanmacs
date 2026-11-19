import Editor
open Editor

-- The manual split layout, so that `C-w v` puts two windows side by side
-- and `C-w s` stacks two; the window commands are reached by the keys the
-- Vim scheme ships under `C-w`. No key is bound here.

def setup : SetupM Unit := do
  layout Layout.manual
