-- The command that receives the prompt's answer. It is registered as a
-- command that is given its call (`commandWith`): the answer is its first
-- argument, a string.
def pickedOne (call : Call) : EditorM Unit :=
  match call.arguments with
  | .str answer :: _ => message s!"picked {answer}"
  | _ => message "picked nothing"

-- Asks `Pick: ` with the completion source registered under `picks`, by
-- name, and returns at once.
def pick : EditorM Unit :=
  discard <| prompt "Pick: " { command := "picked" } (sources := [.named "picks"])

-- Registers the source `picks`, of three candidates. The candidate `w` is
-- last, after `wq`, which holds a `w` too.
def setup : SetupM Unit := do
  defineSource (.ofTexts "picks" "pick" #["wq", "edit", "w"])
  commandWith "picked" pickedOne
  command "pick" pick
