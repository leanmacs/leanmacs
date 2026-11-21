import Editor
import Completion.Styles
import Completion.Displays
open Editor

-- A config that names the completion styles and displays that ship: it
-- defines the shipped minibuffer display again with two rows, and chooses
-- the shipped style orderless for a category of its own, so it elaborates
-- only on a base that holds the modules that declare them.

-- The command that receives the prompt's answer, its first argument.
def pickedOne (call : Call) : EditorM Unit :=
  match call.arguments with
  | .str answer :: _ => message s!"picked {answer}"
  | _ => message "picked nothing"

-- Asks `Pick: ` with the completion source registered under `picks`.
def pick : EditorM Unit :=
  discard <| prompt "Pick: " { command := "picked" } (sources := [.named "picks"])

def setup : SetupM Unit := do
  defineSource (.ofTexts "picks" "pick" #["alpha beta", "beta gamma", "gamma alpha", "delta gamma"])
  defineDisplay (Completion.Displays.minibuffer (rows := 2))
  useStyleFor "pick" Completion.Styles.orderless.name
  commandWith "picked" pickedOne
  command "pick" pick
