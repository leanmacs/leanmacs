import Editor
open Editor

-- Opens a path that is not absolute, in the focused view. The library
-- refuses such a path before it asks the file system, so nothing is read:
-- the refusal comes back as the load job's result, and the job's command
-- says it in the echo area.
def openRelative : EditorM Unit := do
  Files.open (← editorState).frame.focused "notes/relative.txt"

def setup : SetupM Unit := do
  command "open-relative" openRelative
