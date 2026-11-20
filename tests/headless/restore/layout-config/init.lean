import Editor
open Editor

-- Session restore of windows, layouts, tabs and the jump list
-- (`layout-script`, `layout-restore-script`): manual splits inside a left
-- edge, which the session that wrote the index chose too, so a restored
-- layout is kept when this config installs; and `C-c r` renames the tab of
-- the window it is pressed in, as `tests/headless/tabs/config` binds it.

def setup : SetupM Unit := do
  layout (.edge .left 25 Layout.manual)
  bindKey "C-c r" "tab-rename"
