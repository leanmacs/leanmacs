import Editor.Completion.Later
import Editor.State

/-!
# The interface package `minibuffer-api`

The interface package of the minibuffer's commands and its mode
(`docs/design/extension-points.md`, "Three layers"): the contract between
the default package `minibuffer`, which implements it, and whatever
reaches one of its commands or its mode by name. A name another package
reaches is part of the contract a replacement must keep, so it is
declared here, in the interface package, and a reacher outside the core
names the constant, never the text ("Reaches by name"). The reached names
are nine commands and one mode:

- the seven commands the Vim scheme's minibuffer table binds (the core's
  `packages/evil/Evil/Vim/Default.lean`, `minibufferCommands`):
  `minibuffer-accept`, `-cancel`, `-next`, `-previous`, `-insert`,
  `-delete-backward` and `-delete-to-start`. The core cannot import a
  package, so it names them as text;
- `minibuffer-ask`, which the Vim scheme yields when a key needs a text
  typed in the minibuffer (`InputScheme.Vim.askCommand`, the core's
  `packages/evil/Evil/Vim.lean`), also as text;
- `minibuffer-candidates`, which a completion source's job posts each
  batch as, whose name is the core's (`Completion.candidatesCommand`, the
  core's `lean/Editor/Completion/Later.lean`), declared from that constant;
- the mode `minibuffer`, which the core makes the minibuffer's buffer
  with, whose name is the core's (`Prompt.mode`, the core's
  `lean/Editor/State.lean`), declared from that constant.

It registers no behaviour.

Its test library publishes a fake (`MinibufferApiTest.fake`, the core's
test kit's implementation) and the contract check every implementation
runs (`MinibufferApiTest.contractChecks`).
-/

namespace MinibufferApi

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
typed in the minibuffer: the Vim scheme's `InputScheme.Vim.askCommand`,
which the core writes as text. -/
def askName : String :=
  "minibuffer-ask"

/-- The name of the command a source's job posts each batch as: the core's
(`Completion.candidatesCommand`). -/
def candidatesName : String :=
  Editor.Completion.candidatesCommand

/-- The name of the mode the minibuffer's buffer is made with: the core's
(`Prompt.mode`). -/
def modeName : String :=
  Editor.Prompt.mode

/-- Every command name this interface declares, in the order the
implementation registers them: the names an implementation must register a
command under, which the contract check holds it to. -/
def names : Array String :=
  #[acceptName, cancelName, nextName, previousName, insertName, deleteBackwardName,
    deleteToStartName, askName, candidatesName]

end MinibufferApi
