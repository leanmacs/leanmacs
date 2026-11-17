-- The config `mise run install` installs in ~/.config/leanmacs when none is there,
-- to show the installed app loaded config. It uses only Editor.
def hello : EditorM Unit :=
  message "finder-session: config loaded"

def setup : SetupM Unit := do
  command "finder-session-hello" hello
  exCommand "finder-hello" "finder-session-hello"
  bindKey "C-c h" "finder-session-hello"
