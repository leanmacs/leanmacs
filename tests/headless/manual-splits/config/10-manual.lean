-- The manual split layout: each split cuts the window it is run in, and the
-- window commands are reached by the keys the Vim scheme ships under `C-w`.
-- No key is bound here.

def setup : SetupM Unit := do
  layout Layout.manual
