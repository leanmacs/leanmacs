import Editor.Api
import Editor.Command.Call
import Editor.Completion.Later
import Editor.Mode
import Editor.Package
import Editor.Role

/-!
# The test kit: Minibuffer

A hand-written implementation of the minibuffer's commands and its mode,
over the core's prompt API: `package`, a package named `minibuffer`. The
core's tests answer prompts through it, so none of them depends on the
package that ships (`docs/design/keymaps-and-modes.md`, "The minibuffer").
It registers nine commands under the names the core's reachers name as
text: the seven the Vim scheme's minibuffer table binds
(`packages/evil/Evil/Vim/Default.lean`, `minibufferCommands`), the one an
input scheme yields when a key needs a text typed (`InputScheme.Vim.askCommand`,
`packages/evil/Evil/Vim.lean`) and the one a completion source's job posts
each batch as, whose name is the core's (`Completion.candidatesCommand`,
`Editor/Completion/Later.lean`). `names` lists them in the order they are
registered.

Each command acts on the open prompt through the operations of
`Editor/Api.lean`, "Prompts":

| Command | Does |
|---|---|
| `minibuffer-accept` | `acceptPrompt` |
| `minibuffer-cancel` | `cancelPrompt` |
| `minibuffer-next`, `minibuffer-previous` | `chooseCandidate .next`, `.previous` |
| `minibuffer-insert` | `insertCandidate` |
| `minibuffer-delete-backward` | Deletes the cell before the head of the primary range of the minibuffer's selection (the text port's `previousCell`); it never cancels the prompt |
| `minibuffer-delete-to-start` | Deletes from the input's start to that head |
| `minibuffer-ask` (a label) | `prompt label { command := InputScheme.answerName }` |
| `minibuffer-candidates` (a batch) | `Completion.batchOfArguments?`, then `StateRequest.addCandidates`; arguments that are no batch do nothing |

On a refusal each command but the last says the refusal's own `describe`
in the echo area, which for no prompt open is `PromptRefusal.notOpen.describe`.

It also registers the mode `Prompt.mode` (`mode`), the major mode the
minibuffer's buffer is made with (`Editor/State.lean`), with the four roles
the mode that ships fills: `activate` with the accept command, `quit` with
the cancel command, and `next-item` and `previous-item` with the two that
move through the candidates.

What the package that ships does beyond this is that package's own choice,
pinned by its own tests: cancelling on an empty minibuffer, the echo for
arguments that are no batch, and the text of `minibuffer-ask`'s refusal.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import").
-/

namespace Editor.Test.Minibuffer

open Editor

/-- The name of the command that accepts the open prompt: `RET`. -/
def acceptName : String :=
  "minibuffer-accept"

/-- The name of the command that cancels the open prompt: `<Escape>`. -/
def cancelName : String :=
  "minibuffer-cancel"

/-- The name of the command that chooses the next candidate: `C-n`. -/
def nextName : String :=
  "minibuffer-next"

/-- The name of the command that chooses the previous candidate: `C-p`. -/
def previousName : String :=
  "minibuffer-previous"

/-- The name of the command that puts a candidate in the minibuffer: `TAB`. -/
def insertName : String :=
  "minibuffer-insert"

/-- The name of the command that deletes backward: `<Backspace>`. -/
def deleteBackwardName : String :=
  "minibuffer-delete-backward"

/-- The name of the command that deletes to the input's start: `C-u`. -/
def deleteToStartName : String :=
  "minibuffer-delete-to-start"

/-- The name of the command an input scheme yields when a key needs a text
typed in the minibuffer. -/
def askName : String :=
  "minibuffer-ask"

/-- The name of the command a source's job posts each batch as: the core's. -/
def candidatesName : String :=
  Completion.candidatesCommand

/-- The names `package` registers its commands under, in the order it
registers them. -/
def names : Array String :=
  #[acceptName, cancelName, nextName, previousName, insertName, deleteBackwardName,
    deleteToStartName, askName, candidatesName]

/-- Runs `operation` and, when it is refused, says the refusal in the echo
area. -/
def saying (operation : EditorM (Except PromptRefusal α)) (_ : Call) : EditorM Unit := do
  if let .error refusal← operation then
    message refusal.describe

/-- `minibuffer-accept`: accepts the open prompt (`acceptPrompt`). -/
def accept : Call → EditorM Unit :=
  saying acceptPrompt

/-- `minibuffer-cancel`: cancels the open prompt (`cancelPrompt`). -/
def cancel : Call → EditorM Unit :=
  saying cancelPrompt

/-- `minibuffer-next`: chooses the next candidate (`chooseCandidate .next`). -/
def next : Call → EditorM Unit :=
  saying (chooseCandidate .next)

/-- `minibuffer-previous`: chooses the previous candidate
(`chooseCandidate .previous`). -/
def previous : Call → EditorM Unit :=
  saying (chooseCandidate .previous)

/-- `minibuffer-insert`: puts a candidate in the minibuffer
(`insertCandidate`). -/
def insert : Call → EditorM Unit :=
  saying insertCandidate

/-- `minibuffer-delete-backward`: deletes the cell before the head of the
primary range of the minibuffer's selection; at the input's start the
extent is empty, and nothing is deleted. It never cancels the prompt. -/
def deleteBackward (_ : Call) : EditorM Unit := do
  let state ← editorState
  let some asked := state.prompt | message PromptRefusal.notOpen.describe
  let some minibuffer := state.target? asked.view | message PromptRefusal.notOpen.describe
  let selection ← minibuffer.selection
  let some range := selection.ranges[selection.primary]? | return
  let start ← minibuffer.buffer.text.motion .previousCell range.head
  minibuffer.replaceExtents selection #[⟨start, range.head⟩] ""

/-- `minibuffer-delete-to-start`: deletes what is before the head of the
primary range of the minibuffer's selection. -/
def deleteToStart (_ : Call) : EditorM Unit := do
  let state ← editorState
  let some asked := state.prompt | message PromptRefusal.notOpen.describe
  let some minibuffer := state.target? asked.view | message PromptRefusal.notOpen.describe
  let selection ← minibuffer.selection
  let some range := selection.ranges[selection.primary]? | return
  minibuffer.replaceExtents selection #[⟨0, range.head⟩] ""

/-- `minibuffer-ask`, with the label as its first argument, a string, or
none: opens a prompt whose continuation is the reserved name
`InputScheme.answerName`, so the answer goes to the scheme. -/
def ask (call : Call) : EditorM Unit := do
  let label :=
    match call.arguments with
    | .str label :: _ => label
    | _ => ""
  saying (prompt label { command := InputScheme.answerName }) call

/-- `minibuffer-candidates`, with a batch as its arguments: the open prompt
takes it when the view, the source's index and the generation are its own.
Arguments that are no batch do nothing. -/
def candidates (call : Call) : EditorM Unit := do
  let some (view, index, generation, batch) := Completion.batchOfArguments? call.arguments
    | return
  discard <| EditorState.ask (.addCandidates view index generation batch)

/-- The mode of the minibuffer's buffer, `Prompt.mode`, with the four roles
the mode that ships fills. -/
def mode : Mode :=
  { name := Prompt.mode
    roles :=
      [(Role.activate, acceptName), (Role.quit, cancelName), (Role.nextItem, nextName),
        (Role.previousItem, previousName)] }

/-- The package `minibuffer` of the core's tests: the nine commands, under
`names`, in that order, and the mode. -/
def package : Package :=
  { name := "minibuffer"
    setup := do
      commandWith acceptName accept
      commandWith cancelName cancel
      commandWith nextName next
      commandWith previousName previous
      commandWith insertName insert
      commandWith deleteBackwardName deleteBackward
      commandWith deleteToStartName deleteToStart
      commandWith askName ask
      commandWith candidatesName candidates
      defineMode mode }

end Editor.Test.Minibuffer
