import Editor.Api
import Editor.Command.Call

/-!
# The binding search: every binding reachable in the view, run as its key

`search-bindings` asks `Binding: ` for one of the key bindings the input
scheme reaches in the asking view, and runs the one accepted as its key
would. It is what Embark's `embark-bindings` and Doom's `SPC h b b` do. It is
written over the editor API (`keyBindings`, `matchByCategory`, `invoke`,
`Editor/Api.lean`). `Editor.lean` imports this module, so config calls it.
The command as compiled code registers it is in
`Editor/BindingSearch/Compiled.lean`.

- **The candidates are every key sequence the walk reaches from rest in the
  asking view's state whose binding runs a command by name** (`source`),
  as the scheme lists them (`InputScheme.keyBindings`): over the same tiers
  the walk uses, so a binding a specific prefix or binding shadows, or one
  under a shorter bound sequence, is not listed; the specific tier's come
  first. A binding that runs no command alone, such as a Vim motion or
  operator, is not listed. The loop answers them in the scheme's state of
  the step that asks, so after `SPC ?` they are normal state's.
- **What a candidate shows** (`candidate`): its text is the keys, written
  as a key string, two spaces and the command's name (`text`, `SPC f f
  open-file`), which is what the style matches and what accepting gives;
  its annotation is the binding's description, which the display aligns
  in its column; its kind is `binding`. Every listed sequence is apart, so
  every text is.
- **It asks when it is given no text** (`searchBindings`), with a prompt
  labelled `label` whose continuation is `search-bindings` itself. Where the
  prompt is refused, because one is open, the echo area says so
  (`notAsking`) and the open prompt stays.
- **The answer is resolved as it was listed** (`resolve`), the rule
  `execute-command` follows: a text that is a binding's exactly is taken;
  otherwise the first binding the style lists for it (`matchByCategory`).
  A text nothing matches is said (`noMatch`) and nothing runs. An empty or
  blank answer runs nothing and says nothing.
- **The binding accepted runs as its key would**: the command `invoke`s the
  reserved keys invocation of its keys (`InputScheme.keysInvocation`), and
  the loop feeds those keys to the scheme from rest and runs what they
  complete (`Loop.pressed`). So the invocation is the scheme's own, with
  no count and no register, the keys it is told of are the binding's, and
  the scheme's state changes as the key changes it: `i` accepted enters
  insert state. Keys that no longer complete anything, after a reload, are
  said (`Loop.notBound`).
- **It hard-codes no matching.** The prompt asks for the sources of the
  category `binding`, with `source` (`bindings`) as its default, so config
  adds candidates by registering a source in `binding`, replaces them by
  registering one under `bindings`, chooses how they are searched and
  ordered with `useStyleFor "binding" …`, and how they are shown with
  `useDisplayFor`.

## Where an addition goes

A new list of candidates is a source registered in the category `binding`.
A new order or search is config's style for `binding`. Searching the
descriptions too would mean putting them in the text; the style sees texts
only.

Pinned by `ModelTest.bindingSearchChecks`, on the loop's driver over the
editor's models and the test scheme; by `ModelTest.pressedChecks`, for the
reserved keys invocation under the test scheme and the Vim scheme; by
the headless fixture `tests/headless/binding-search`, on the default
editor with a config of its own; and by the headless fixture
`tests/headless/default-config`, which runs `SPC ?` under the shipped
default config.
-/

namespace Editor.BindingSearch

/-- The name the binding search is registered under. -/
def name : String :=
  "search-bindings"

/-- The label of the prompt the command asks for a binding with. -/
def label : String :=
  "Binding: "

/-- The category the prompt asks for its sources by. -/
def category : String :=
  "binding"

/-- What the echo area says when the command was called with no text and
could not ask for one: the refusal's own sentence, after the command's
name. -/
def notAsking (refusal : PromptRefusal) : String :=
  s!"{name}: {refusal.describe}"

/-- What the echo area says when no binding matches `text`. -/
def noMatch (text : String) : String :=
  s!"{name}: no binding matches `{text}`"

/-- A binding's text: its keys as a key string, two spaces, and its
command's name. -/
def text (binding : KeyBinding) : String :=
  s!"{Key.notations binding.keys}  {binding.command}"

/-- A binding as a candidate: its text (`text`), annotated with its
description, of the kind `binding`. -/
def candidate (binding : KeyBinding) : Completion.Candidate :=
  { text := text binding, annotation := binding.desc, kind := some category }

/-- The completion source of the key bindings the scheme reaches in the
asking view (`keyBindings`), as the loop answers them when it is asked:
`bindings`, of the category `binding`. -/
def source : Completion.Source :=
  { name := "bindings", category
    candidates := fun query => return (← keyBindings query.view).map candidate }

/-- The binding `text` names in `view`, resolved as the prompt listed it:
the binding whose text is `text` exactly, else the first the style chosen
for the category `binding` lists for `text`; `none` when nothing
matches. -/
def resolve (view : ViewId) (text : String) : EditorM (Option KeyBinding) := do
  let bound ← keyBindings view
  if let some exact := bound.find? (BindingSearch.text · == text) then
    return some exact
  let hits ← matchByCategory category text (bound.map BindingSearch.text)
  return hits[0]?.bind (bound[·.index]?)

/-- The binding search as it is called: runs the binding its first
argument, a string, names (`resolve`), by pressing its keys
(`InputScheme.keysInvocation`), and says so when nothing matches
(`noMatch`); an empty or blank string runs nothing. With anything else
first, or nothing, it asks (`prompt`, labelled `label`), with itself as the
continuation and the bindings as the candidates (`source`); where the
prompt is refused it says so (`notAsking`). -/
def searchBindings (call : Call) : EditorM Unit := do
  match call.arguments with
  | .str text :: _ =>
    let text := text.trimAscii.toString
    if text.isEmpty then
      return
    match ← resolve call.target.window.id text with
    | some binding =>
      invoke (InputScheme.keysInvocation binding.keys)
    | none =>
      message (noMatch text)
  | _ =>
    if let .error refusal←
        prompt label { command := name } (sources := [.category category [source]]) then
      message (notAsking refusal)

end Editor.BindingSearch
