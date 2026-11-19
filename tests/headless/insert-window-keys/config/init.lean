import Editor
open Editor

-- The window commands in every state: each key of the Vim scheme's `C-w`
-- table bound with `bindKey`, which holds in every Vim state. In insert
-- state the `C-w` prefix then shadows the state's own `C-w`, the word
-- delete. The layout is the default, master-and-stack.

def setup : SetupM Unit := do
  for (keys, name) in Vim.Default.windowKeys do
    bindKey keys name
