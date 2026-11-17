-- Floats a display rule opens, under the default layout: `C-c n` runs
-- `make-notes`, which makes a buffer called `notes` and displays it, and a
-- rule sends what it opens to a float, transient; `C-c m` runs `make-memo`,
-- which makes a buffer called `memo`, and a rule sends what it opens to a
-- float pinned. The window commands are reached by the Vim scheme's own
-- `C-w` keys.

/-- Makes a buffer called `name`, or a free name made from it, holding
`text`, and displays it for the command `opener`, from the window the
command was called in. -/
def makeShown (name text opener : String) (call : Call) : EditorM Unit := do
  let .ok made ← createBuffer ((← editorState).freeName name) text | return
  discard <| made.display call.target.window.id opener

def setup : SetupM Unit := do
  commandWith "make-notes" (makeShown "notes" "a note" "make-notes")
  bindKey "C-c n" "make-notes"
  commandWith "make-memo" (makeShown "memo" "a memo" "make-memo")
  bindKey "C-c m" "make-memo"
  displayRule { opener := some "make-notes", target := .float }
  displayRule { opener := some "make-memo", target := .float (pinned := true) }
