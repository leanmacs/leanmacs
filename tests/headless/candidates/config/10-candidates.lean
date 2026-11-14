-- The command that receives the prompt's answer. It is registered as a
-- command that is given its call (`commandWith`): the answer is its first
-- argument, a string.
def pickedOne (call : Call) : EditorM Unit :=
  match call.arguments with
  | .str answer :: _ => message s!"picked {answer}"
  | _ => message "picked nothing"

-- Asks `Pick: ` with three candidates, from a function, and returns at
-- once. The candidate `w` is last, after `wq`, which holds a `w` too.
def pick : EditorM Unit :=
  discard <| prompt "Pick: " { command := "picked" } (candidates := pure #["wq", "edit", "w"])

def setup : SetupM Unit := do
  commandWith "picked" pickedOne
  command "pick" pick
