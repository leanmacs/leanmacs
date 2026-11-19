import Editor
open Editor

-- A frame padding of 12 points: every window's view is padded 12 across
-- and down, and the bottom row, the echo and the minibuffer's view, 12
-- across, the headless window's corners being square.
def setup : SetupM Unit := do
  framePadding 12
