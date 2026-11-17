-- Tabs under the default layout: the tab commands are reached by the keys
-- the Vim scheme ships under `C-w` (tmux's), and the two with no default
-- key are bound here: `C-c r` renames the tab of the window it is pressed
-- in, and `C-c m` moves that tab one place right.

def setup : SetupM Unit := do
  bindKey "C-c r" "tab-rename"
  bindKey "C-c m" "tab-move-right"
