import Editor.Api
import Editor.Command.Call
import Editor.Mode
import Editor.Role

/-!
# The minibuffer's commands and its mode

A prompt is answered and cancelled by commands, and the minibuffer takes
keys through a mode, like any buffer (`docs/design/keymaps-and-modes.md`,
"The minibuffer"). They are compiled: a host registers them for the owner
`compiled` (`Editor/Minibuffer/Compiled.lean`), so they hold when config
fails to load, and a reload does not replace them.

- **`minibuffer-accept`** (`acceptName`, `acceptCommand`) accepts the open
  prompt with the minibuffer's text as its answer (`acceptPrompt`,
  `Editor/Api.lean`): the prompt is closed, and the continuation's command
  runs next, with the answer.
- **`minibuffer-cancel`** (`cancelName`, `cancelCommand`) cancels the open
  prompt (`cancelPrompt`): it is closed, and the continuation does not run.
- **With no prompt open** each says `notOpen` in the echo area and does
  nothing else. Either can be bound in the global keymap or run by its
  name, so it can run in any view.
- **The mode** (`mode`) is the major mode the minibuffer's buffer is made
  with (`Prompt.mode`, `Editor/State.lean`). It fills two roles:
  `activate` with the accept command and `quit` with the cancel command.
  So under any scheme the minibuffer has an accept key and a cancel key,
  the scheme's keys for those roles, with no binding written for the
  scheme. It has no suffix and no on-enter action: the buffer is made with
  the mode, which is not set through a view.
- **Under the Vim scheme** the minibuffer's view is in a Vim state where
  typing is text, in which a mode's keys do not hold; that state binds the
  two commands by their names (`Editor/InputScheme/Vim/Default.lean`). The
  names here and in that table are changed together.

Nothing here inserts typed text: the command a key that prints runs is the
scheme's self-insert, which goes with insert state.

## Where an addition goes

| Addition | Where |
|---|---|
| A command that acts on the open prompt | Here, with its name, over an operation of `Editor/Api.lean`; its registration in `Editor/Minibuffer/Compiled.lean` |
| A key every scheme should have in the minibuffer | A role the mode fills |
| A key one scheme has in the minibuffer | That scheme's own table |

Pinned by `ModelTest.promptChecks`, on the models and the test scheme.
-/

namespace Editor.Minibuffer

/-- The name the accept command is registered under. -/
def acceptName : String :=
  "minibuffer-accept"

/-- The name the cancel command is registered under. -/
def cancelName : String :=
  "minibuffer-cancel"

/-- What the accept command and the cancel command say in the echo area when
no prompt is open. -/
def notOpen : String :=
  PromptRefusal.notOpen.describe

/-- The accept command as it is called: accepts the open prompt with the
minibuffer's text as its answer. With no prompt open it says so in the echo
area. -/
def acceptCommand (_ : Call) : EditorM Unit := do
  if let .error _← acceptPrompt then
    message notOpen

/-- The cancel command as it is called: cancels the open prompt. With no
prompt open it says so in the echo area. -/
def cancelCommand (_ : Call) : EditorM Unit := do
  if let .error _← cancelPrompt then
    message notOpen

/-- The minibuffer's mode: the major mode the minibuffer's buffer is made
with. It fills the role `activate` with the accept command and the role
`quit` with the cancel command. -/
def mode : Mode :=
  { name := Prompt.mode, roles := [(Role.activate, acceptName), (Role.quit, cancelName)] }

end Editor.Minibuffer
