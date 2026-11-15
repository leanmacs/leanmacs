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
- **`minibuffer-next`** and **`minibuffer-previous`** (`nextName`,
  `nextCommand`; `previousName`, `previousCommand`) move a choice through
  the candidates the prompt has listed (`chooseCandidate`,
  `Editor/Api.lean`), which the scene shows in the minibuffer's status
  line (`Editor/Loop.lean`).
  - From nothing chosen, next chooses the first and previous the last;
    next from the last and previous from the first choose nothing. So the
    text as typed is one stop of the round, as in Vim's wild menu.
  - The minibuffer's text is not changed by a choice. Accepting takes the
    chosen candidate, and the typed text when nothing is chosen.
  - A change of the text forgets the choice: the loop lists again for the
    new text.
  - With nothing listed, and in a prompt with no candidates, each changes
    nothing.
- **`minibuffer-delete-backward`** (`deleteBackwardName`,
  `deleteBackwardCommand`) edits the open prompt's minibuffer ("Deleting
  backward", below).
- **With no prompt open** each of the five says `notOpen` in the echo area
  and does nothing else. Any can be bound in the global keymap or run by
  its name, so it can run in any view.
- **The mode** (`mode`) is the major mode the minibuffer's buffer is made
  with (`Prompt.mode`, `Editor/State.lean`). It fills four roles:
  `activate` with the accept command, `quit` with the cancel command, and
  `next-item` and `previous-item` with the two that move through the
  candidates. So under any scheme whose role keys hold in the minibuffer
  it has those four keys, the scheme's keys for the roles, with no binding
  written for the scheme. It has no suffix and no on-enter action: the
  buffer is made with the mode, which is not set through a view.
- **Under the Vim scheme** the minibuffer's view is in a Vim state where
  typing is text, in which a mode's keys do not hold; that state binds the
  commands by their names (`Editor/InputScheme/Vim/Default.lean`). The
  names here and in that table are changed together.

## Deleting backward

`minibuffer-delete-backward` acts on the minibuffer of the open prompt,
whichever view it was run from:

- **It deletes the character before the bar**: the cell before the head of
  the primary range of the minibuffer's selection (the text port's
  `previousCell`, so a character of several bytes, or a cluster, goes
  whole), as one transaction made by the user, with the bar left where the
  cell started. The loop then lists the candidates again for the new text.
- **With the bar at the text's start** it deletes nothing.
- **With the minibuffer empty it cancels the prompt**, as
  `minibuffer-cancel` does: the continuation does not run. This is Vim's
  `<BS>` on an empty command line, which leaves it, and the scheme that
  binds the key is Vim's. Emacs's `DEL` on an empty minibuffer does
  nothing; a scheme that wants that binds another command.

Nothing here inserts typed text: the command a key that prints runs is the
scheme's self-insert. Under the Vim scheme that is evil's
(`Evil.selfInsert`, `Editor/Evil.lean`), the same command as in insert
state: the minibuffer's view is in a state where typing is text, and the
loop runs the command with the focused window, which is the minibuffer's.

## Where an addition goes

| Addition | Where |
|---|---|
| A command that acts on the open prompt | Here, with its name, over an operation of `Editor/Api.lean`; its registration in `Editor/Minibuffer/Compiled.lean` |
| A key every scheme should have in the minibuffer | A role the mode fills |
| A key one scheme has in the minibuffer | That scheme's own table |

Pinned by `ModelTest.promptChecks`, on the models and the test scheme, and
the two commands that move through the candidates by
`ModelTest.candidateChecks`.
-/

namespace Editor.Minibuffer

/-- The name the accept command is registered under. -/
def acceptName : String :=
  "minibuffer-accept"

/-- The name the cancel command is registered under. -/
def cancelName : String :=
  "minibuffer-cancel"

/-- The name the command that moves to the next candidate is registered
under. -/
def nextName : String :=
  "minibuffer-next"

/-- The name the command that moves to the previous candidate is registered
under. -/
def previousName : String :=
  "minibuffer-previous"

/-- The name the command that deletes backward is registered under. -/
def deleteBackwardName : String :=
  "minibuffer-delete-backward"

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

/-- The command that moves to the next candidate, as it is called: moves the
open prompt's choice one step forward through its listing
(`chooseCandidate`). With no prompt open it says so in the echo area. -/
def nextCommand (_ : Call) : EditorM Unit := do
  if let .error _← chooseCandidate .next then
    message notOpen

/-- The command that moves to the previous candidate, as it is called: moves
the open prompt's choice one step back through its listing. With no prompt
open it says so in the echo area. -/
def previousCommand (_ : Call) : EditorM Unit := do
  if let .error _← chooseCandidate .previous then
    message notOpen

/-- The command that deletes backward, as it is called ("Deleting
backward", in the module docs): with the minibuffer empty it cancels the
open prompt, as `<BS>` on Vim's empty command line does; otherwise it
deletes the character before the head of the minibuffer's selection's
primary range: with the head at the text's start the extent is empty, and
nothing is deleted. With no prompt open it says so in the echo area. -/
def deleteBackwardCommand (_ : Call) : EditorM Unit := do
  let state ← editorState
  let some asked := state.prompt | message notOpen
  let some minibuffer := state.target? asked.view | message notOpen
  let text := minibuffer.buffer.text
  if (← text.read).isEmpty then
    discard cancelPrompt
    return
  let selection ← minibuffer.selection
  let some range := selection.ranges[selection.primary]? | return
  -- At the text's start the cell before is none: the extent is empty.
  let start ← text.motion .previousCell range.head
  minibuffer.replaceExtents selection #[⟨start, range.head⟩] ""

/-- The minibuffer's mode: the major mode the minibuffer's buffer is made
with. It fills the role `activate` with the accept command, the role `quit`
with the cancel command, and the roles `next-item` and `previous-item` with
the commands that move through the candidates. -/
def mode : Mode :=
  { name := Prompt.mode
    roles :=
      [(Role.activate, acceptName), (Role.quit, cancelName), (Role.nextItem, nextName),
        (Role.previousItem, previousName)] }

end Editor.Minibuffer
