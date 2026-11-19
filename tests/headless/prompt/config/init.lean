import Editor
open Editor

-- The command that receives the prompt's answer. It is registered as a
-- command that is given its call (`commandWith`): the answer is its first
-- argument, a string.
def greetNamed (call : Call) : EditorM Unit :=
  match call.arguments with
  | .str name :: _ => message s!"hello {name}"
  | _ => message "hello"

-- Asks for a name, with `Ada` already in the minibuffer, and returns at
-- once: it names the command that receives the answer, as an invocation.
def askName : EditorM Unit :=
  discard <| prompt "Name: " { command := "greet-named" } "Ada"

def setup : SetupM Unit := do
  commandWith "greet-named" greetNamed
  command "ask-name" askName
