-- Two windows on one buffer, under the default layout: `C-c s` splits the
-- window a key is pressed in, and `C-c o` focuses the next window of the
-- frame's list. The same bindings as `tests/headless/monocle`'s config:
-- each fixture's config directory is self-contained.

/-- Focuses the window after the one it is called in, in the frame's list,
and the first after the last. -/
def otherWindow (call : Call) : EditorM Unit := do
  let windows := (← editorState).frame.windows
  let some index := windows.findIdx? (· == call.target.window.id) | return
  let some next := windows[(index + 1) % windows.size]? | return
  discard <| next.focus

def setup : SetupM Unit := do
  commandWith "split-window" fun call => discard <| call.target.window.id.split
  bindKey "C-c s" "split-window"
  commandWith "other-window" otherWindow
  bindKey "C-c o" "other-window"
