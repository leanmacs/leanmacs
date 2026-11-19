import Editor
open Editor

-- A fixture config the gate runs headless, to show a config is loaded and its
-- command runs by key and by ex name. It uses only Editor.
def hello : EditorM Unit :=
  message "finder-session: config loaded"

def setup : SetupM Unit := do
  command "finder-session-hello" hello
  exCommand "finder-hello" "finder-session-hello"
  bindKey "C-c h" "finder-session-hello"
