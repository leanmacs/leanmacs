import Editor
open Editor

-- A float anchored at the cursor, under the default layout: `C-c f` runs
-- `fill`, which puts eighty lines, `line00` to `line79`, at the cursor, and
-- `C-c h` runs `float-here`, which opens a buffer called `hint` in a
-- transient float anchored at the cursor, half the tiled area wide and a
-- quarter tall, without the focus.

/-- Puts `line00` to `line79`, each but the last ended by a line feed, at
the cursors of the window the command was called in. -/
def fill (call : Call) : EditorM Unit := do
  let lines := (List.range 80).map fun line => s!"line{line / 10}{line % 10}"
  discard <| call.target.window.id.insertAtSelections ("\n".intercalate lines)

/-- Opens the buffer `hint`, made holding `a hint` the first time, in a
transient float anchored at the cursor of the window the command was called
in, 50 percent of the tiled area wide and 25 percent tall, and leaves the
focus where it is. -/
def floatHere (call : Call) : EditorM Unit := do
  let view := call.target.window.id
  let hint ←
    match (← editorState).findBuffer "hint" with
    | some hint => pure hint
    | none =>
      let .ok hint ← createBuffer "hint" "a hint" | return
      pure hint
  let .ok selection ← view.selection | return
  let some range := selection.ranges[selection.primary]? | return
  discard <|
    hint.float (.position view range.head) { width := 50, height := 25 } (focus := false)

def setup : SetupM Unit := do
  commandWith "fill" fill
  bindKey "C-c f" "fill"
  commandWith "float-here" floatHere
  bindKey "C-c h" "float-here"
