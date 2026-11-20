import Editor.Api
import Editor.Command.Call

/-!
# The command prompt: running any registered command by name

`execute-command` asks `Command: ` for the name of a registered command and
runs the one accepted, as Emacs's `M-x` does. It is written over the editor
API (`commandNames`, `matchByCategory`, `invoke`, `Editor/Api.lean`).
`Editor.lean` imports this module, so config calls it. The command as
compiled code registers it is in `Editor/ExecuteCommand/Compiled.lean`.

- **The candidates are every registered command's name** (`source`), from
  compiled code and from config, the command prompt itself and the
  minibuffer's own commands among them, each once, compiled code's first,
  in the order they were first registered. The loop answers them from the
  registry as it is for the step that asks (`commandNames`), so a reload
  that drops config's command drops it from the next prompt: nothing is
  kept across a reload. Filtering and ordering are the style's.
- **Each candidate shows the keys that reach its command** (`annotation`):
  the key bindings the input scheme reaches in the asking view, in its
  state then (`keyBindings`), whose command is the candidate's, each
  written as a key string and joined by `, `, then two spaces and the
  first description among them, as in `SPC ., SPC f f  Find file`. A
  command no key reaches has none. They are asked of the scheme's own
  list, not of a keymap's raw bindings (`Keymap.keysFor`), so a key a
  specific tier shadows is never shown. The text stays the name, so
  resolution is unchanged.
- **It asks when it is given no name** (`executeCommand`), as the ex
  command asks for its line (`Editor/Ex.lean`). With a string as its first
  argument it runs the command that string names. With anything else
  first, or nothing, it asks with a prompt labelled `label`, whose
  continuation is `execute-command` itself; so a Vim key, which hands a
  count first, asks. Where the prompt is refused, because one is open, the
  echo area says so (`notAsking`) and the open prompt stays.
- **The command accepted runs as a key bound to it would** (`invoke`): as a
  step of its own after the prompt's, with the window then focused, its
  store write written back and its failure said under its own name. It is
  given no argument, so a command that asks for its own (`load-theme`,
  `ex`, `switch-buffer`) asks in turn. An accepted name is three steps: the
  accept, `execute-command` with the name, and the named command.
- **The answer is resolved as it was listed** (`resolve`), the rule
  `switch-buffer` follows (`Editor/Buffers.lean`): a name a command is
  registered under exactly is run; otherwise the first command the style
  lists for the text (`matchByCategory`), so accepting a typed fragment
  with nothing chosen runs the top of the list shown. A text nothing
  matches is said (`noMatch`) and nothing runs. An empty or blank answer
  runs nothing and says nothing, as the ex line's empty line does.
- **It hard-codes no matching.** The prompt asks for the sources of the
  category `command`, with `source` (`commands`) as its default, so config
  adds candidates by registering a source in `command`, replaces them by
  registering one under `commands`, chooses how they are searched and
  ordered with `useStyleFor "command" …`, and how they are shown with
  `useDisplayFor`.

## Where an addition goes

A new list of candidates is a source registered in the category `command`.
A new order or search is config's style for `command`. What a candidate
shows beside its name is `annotation`.

Pinned by `ModelTest.executeCommandChecks`, on the loop's driver over the
editor's models and the test scheme; by the headless fixture
`tests/headless/command-prompt`, on the default editor with a config of
its own; and by the headless fixture `tests/headless/default-config`,
which runs `SPC :` under the shipped default config.
-/

namespace Editor.ExecuteCommand

/-- The name the command prompt is registered under. -/
def name : String :=
  "execute-command"

/-- The label of the prompt the command asks for a command's name with. -/
def label : String :=
  "Command: "

/-- The category the prompt asks for its sources by. -/
def category : String :=
  "command"

/-- What the echo area says when the command was called with no name and
could not ask for one: the refusal's own sentence, after the command's
name. -/
def notAsking (refusal : PromptRefusal) : String :=
  s!"{name}: {refusal.describe}"

/-- What the echo area says when no registered command matches `text`. -/
def noMatch (text : String) : String :=
  s!"{name}: no command matches `{text}`"

/-- The annotation of the command `name` among the key bindings `bound`:
the keys of every binding whose command is `name`, each written as a key
string, joined by `, `, in their order, then two spaces and the first
description among them when one has one; `none` when no key reaches the
command. -/
def annotation (bound : Array KeyBinding) (name : String) : Option String :=
  let reaching := bound.filter (·.command == name)
  if reaching.isEmpty then none
  else
    let written := ", ".intercalate (reaching.toList.map (Key.notations ·.keys))
    match reaching.findSome? (·.desc) with
    | some desc => some s!"{written}  {desc}"
    | none => some written

/-- The completion source of the names commands are registered under
(`commandNames`), as the loop answers them when it is asked: `commands`, of
the category `command`, each annotated with the keys that reach it in the
asking view (`annotation`). -/
def source : Completion.Source :=
  { name := "commands", category
    candidates := fun query => do
      let bound ← keyBindings query.view
      return (← commandNames).map fun name =>
          { text := name, annotation := annotation bound name } }

/-- The command `text` names, resolved as the prompt listed it: the name a
command is registered under that is `text` exactly, else the first the
style chosen for the category `command` lists for `text`; `none` when
nothing matches. -/
def resolve (text : String) : EditorM (Option String) := do
  let names ← commandNames
  if names.contains text then
    return some text
  let hits ← matchByCategory category text names
  return hits[0]?.bind (names[·.index]?)

/-- The command prompt as it is called: runs the command its first argument,
a string, names (`resolve`), as a step of its own with no argument
(`invoke`), and says so when nothing matches (`noMatch`); an empty or blank
string runs nothing. With anything else first, or nothing, it asks for the
name (`prompt`, labelled `label`), with itself as the continuation and the
registered commands' names as the candidates (`source`); where the prompt
is refused it says so (`notAsking`). -/
def executeCommand (call : Call) : EditorM Unit := do
  match call.arguments with
  | .str text :: _ =>
    let text := text.trimAscii.toString
    if text.isEmpty then
      return
    match ← resolve text with
    | some command =>
      invoke { command }
    | none =>
      message (noMatch text)
  | _ =>
    if let .error refusal←
        prompt label { command := name } (sources := [.category category [source]]) then
      message (notAsking refusal)

end Editor.ExecuteCommand
