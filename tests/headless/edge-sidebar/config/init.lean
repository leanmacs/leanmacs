import Editor
open Editor

-- A sidebar that is an ordinary window: the layout gives the windows docked
-- at its left edge a strip of 25 percent, and master-and-stack the rest. A
-- display rule sends the buffers of the minor mode `notes` to that edge,
-- and `C-c n` runs `make-notes`, which makes a buffer called `notes` in
-- that mode and displays it. The window commands are reached by the Vim
-- scheme's own `C-w` keys.

/-- Makes a buffer called `notes`, or a free name made from it, holding
`a note`, adds the minor mode `notes` to it, and displays it for the
command `make-notes`, from the window the command was called in. -/
def makeNotes (call : Call) : EditorM Unit := do
  let .ok notes ← createBuffer ((← editorState).freeName "notes") "a note" | return
  discard <| notes.addMinorMode "notes"
  discard <| notes.display call.target.window.id "make-notes"

def setup : SetupM Unit := do
  layout (.edge .left 25 Layout.default)
  displayRule { mode := some "notes", target := .edge .left }
  commandWith "make-notes" makeNotes
  bindKey "C-c n" "make-notes"
