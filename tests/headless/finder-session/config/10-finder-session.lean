-- The config the owner's Finder session loads from ~/.config/leanmacs
-- (docs/dev-practices/finder-session.md). It uses only Editor.
def hello : EditorM Unit :=
  message "finder-session: config loaded"

def setup : SetupM Unit := do
  command "finder-session-hello" hello
  exCommand "finder-hello" "finder-session-hello"
  bindKey "C-c h" "finder-session-hello"
