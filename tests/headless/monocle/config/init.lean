import Editor
open Editor

-- The monocle layout: only the selected window is shown, in the whole area
-- above the minibuffer's strip. `C-c s` splits the window a key is pressed
-- in, and `C-c o` focuses the next window of the frame's list.

/-- Focuses the window after the one it is called in, in the frame's list,
and the first after the last. -/
def otherWindow (call : Call) : EditorM Unit := do
  let windows := (← editorState).frame.windows
  let some index := windows.findIdx? (· == call.target.window.id) | return
  let some next := windows[(index + 1) % windows.size]? | return
  discard <| next.focus

def setup : SetupM Unit := do
  layout .monocle
  commandWith "split-window" fun call => discard <| call.target.window.id.split
  bindKey "C-c s" "split-window"
  commandWith "other-window" otherWindow
  bindKey "C-c o" "other-window"
