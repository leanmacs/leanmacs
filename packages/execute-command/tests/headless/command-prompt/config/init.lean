import Editor
import ExecuteCommand
open Editor

-- A config for the command prompt, `execute-command`. It chooses a style of
-- its own for the prompt's category, so the listing is short and in the
-- order the commands were registered; registers two commands, one bound to
-- a key; defines a theme of its own; and registers a command whose message
-- names a declaration of the command prompt's module, so it elaborates only
-- on a base that holds that module.

-- A theme of this config's own, `zz-dark`: the built-in theme followed by a
-- `default` of its own background.
def zzDark : Theme :=
  Theme.builtin ++
    #[{ name := ⟨"default"⟩, face := { background := some (Color.rgb 20 20 60) } }]

def setup : SetupM Unit := do
  defineStyle (.keeping "starts" fun text candidate => candidate.startsWith text)
  useStyleFor "command" "starts"
  command "zz-other" (message "other")
  bindKey "SPC f f" "zz-other"
  command "zz-mine" (message "mine")
  defineTheme "zz-dark" zzDark
  command "prompt-label" (message s!"the command prompt asks {ExecuteCommand.label.quote}")
