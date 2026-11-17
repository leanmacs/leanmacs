-- Display rules, under the default layout: `C-c n` runs `make-notes`, which
-- makes a buffer called `notes` holding `a note` and displays it where the
-- display rules say, as a command shows a buffer it made. The one rule sends
-- what the command `nowhere` opens to a new tab, which does not exist yet,
-- so the install leaves it out and says so, and every buffer a command shows
-- goes to the stack.

/-- Makes a buffer called `notes`, or a free name made from it, holding
`a note`, and displays it for the command `make-notes`, from the window the
command was called in. -/
def makeNotes (call : Call) : EditorM Unit := do
  let .ok notes ← createBuffer ((← editorState).freeName "notes") "a note" | return
  discard <| notes.display call.target.window.id "make-notes"

def setup : SetupM Unit := do
  commandWith "make-notes" makeNotes
  bindKey "C-c n" "make-notes"
  displayRule { opener := some "nowhere", target := .newTab }
