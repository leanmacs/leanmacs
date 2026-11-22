import Editor.Api
import Editor.Command.Call
import Editor.Completion.Later
import Editor.Mode
import Editor.Role
import MinibufferApi

/-!
# The minibuffer's commands and its mode

A prompt is answered and cancelled by commands, and the minibuffer takes
keys through a mode, like any buffer (`docs/design/keymaps-and-modes.md`,
"The minibuffer"). They are a package's: a host registers them for the owner
`minibuffer` (`Minibuffer/Compiled.lean`), so they hold when config
fails to load, and a reload does not replace them. Their names, and the
mode's, are the interface package `minibuffer-api`'s
(`MinibufferApi.acceptName`, …, `MinibufferApi.modeName`), which declares
every name another package reaches.

- **`minibuffer-accept`** (`acceptName`, `acceptCommand`) accepts the open
  prompt with the minibuffer's text as its answer (`acceptPrompt`,
  the core's `lean/Editor/Api.lean`): the prompt is closed, and the continuation's command
  runs next, with the answer.
- **`minibuffer-cancel`** (`cancelName`, `cancelCommand`) cancels the open
  prompt (`cancelPrompt`): it is closed, and the continuation does not run.
- **`minibuffer-next`** and **`minibuffer-previous`** (`nextName`,
  `nextCommand`; `previousName`, `previousCommand`) move a choice through
  the candidates the prompt has listed (`chooseCandidate`,
  the core's `lean/Editor/Api.lean`), which the scene shows in the minibuffer's status
  line (the core's `lean/Editor/Loop.lean`).
  - From nothing chosen, next chooses the first and previous the last;
    next from the last and previous from the first choose nothing. So the
    text as typed is one stop of the round, as in Vim's wild menu.
  - The minibuffer's text is not changed by a choice. Accepting takes the
    chosen candidate, and the typed text when nothing is chosen.
  - A change of the text forgets the choice: the loop lists again for the
    new text.
  - With nothing listed, and in a prompt with no candidates, each changes
    nothing.
- **`minibuffer-insert`** (`insertName`, `insertCommand`) puts a candidate
  in the minibuffer (`insertCandidate`, the core's `lean/Editor/Api.lean`), as vertico's
  `TAB` does: the chosen one, or the first listed when nothing is chosen,
  replaces the whole input, the bar at its end, and the prompt stays open.
  It works in every prompt, so any candidate can be edited before it is
  accepted, and in a file prompt it goes into a directory. With nothing
  listed for the text it changes nothing.
- **`minibuffer-delete-backward`** (`deleteBackwardName`,
  `deleteBackwardCommand`) edits the open prompt's minibuffer ("Deleting
  backward", below).
- **`minibuffer-delete-to-start`** (`deleteToStartName`,
  `deleteToStartCommand`) edits it too ("Deleting to the start", below).
- **With no prompt open** each of the seven says `notOpen` in the echo area
  and does nothing else. Any can be bound in the global keymap or run by
  its name, so it can run in any view.
- **The mode** (`mode`) is the major mode the minibuffer's buffer is made
  with (`Prompt.mode`, the core's `lean/Editor/State.lean`). It fills four roles:
  `activate` with the accept command, `quit` with the cancel command, and
  `next-item` and `previous-item` with the two that move through the
  candidates. So under any scheme whose role keys hold in the minibuffer
  it has those four keys, the scheme's keys for the roles, with no binding
  written for the scheme. It has no suffix and no on-enter action: the
  buffer is made with the mode, which is not set through a view.
- **Under the Vim scheme** the minibuffer's view is in a Vim state where
  typing is text, in which a mode's keys do not hold; that state binds the
  commands by their names (the core's `packages/evil/Evil/Vim/Default.lean`). The
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

## Deleting to the start

`minibuffer-delete-to-start` acts on the minibuffer of the open prompt,
whichever view it was run from:

- **It deletes from the input's start to the bar**: what is before the
  head of the primary range of the minibuffer's selection, as one
  transaction made by the user, with the bar left at the start. What is
  after the bar is kept. This is Vim 9.1's `c_CTRL-U`.
- **With the bar at the start** it deletes nothing.
- **It never cancels the prompt**, even on an empty minibuffer, unlike
  `minibuffer-delete-backward`.

Nothing here inserts typed text: the command a key that prints runs is the
scheme's self-insert. Under the Vim scheme that is evil's
(`Evil.selfInsert`, the core's `packages/evil/Evil.lean`), the same command as in insert
state: the minibuffer's view is in a state where typing is text, and the
loop runs the command with the focused window, which is the minibuffer's.

## Where an addition goes

| Addition | Where |
|---|---|
| A command that acts on the open prompt | Here, with its name, over an operation of the core's `lean/Editor/Api.lean`; its name in the interface package `minibuffer-api` when another package reaches it; its registration in `Minibuffer/Compiled.lean` |
| A key every scheme should have in the minibuffer | A role the mode fills |
| A key one scheme has in the minibuffer | That scheme's own table |
| A key one prompt category has in the minibuffer | A binding given that category (`KeyBinding.category`, the core's `lean/Editor/Config/Registry.lean`) |

## Taking a batch

`minibuffer-candidates` (`candidatesName`, `candidatesCommandOf`) is what a
completion source's job posts each batch of its candidates as
(the core's `lean/Editor/Completion/Later.lean`). It takes the batch into the open prompt,
for the source and the generation the batch names
(`StateRequest.addCandidates`): a stale job's batch, or one for a prompt
that closed, is dropped. Arguments that are no batch say
`minibuffer-candidates: malformed batch` in the echo area. It is a
minibuffer command because it adds to the open prompt; a later phase's
at-point session adds its own.

## Asking for the input scheme

`minibuffer-ask` (`askCommand`) is what an input scheme yields when a key
needs a text typed in the minibuffer before its edit is complete, as Vim's
`/` needs its pattern (the core's `packages/evil/Evil/Vim.lean`, "Motions that ask").
It opens a prompt with the label it is handed and the reserved continuation
`InputScheme.answerName`, so the accepted answer is handed to the scheme
(the core's `lean/Editor/Loop.lean`, "Prompts") and no command runs under that name.

Pinned by `MinibufferTest.promptModeChecks`, on the models and the test
scheme, and through the editor by the package's headless fixtures `prompt`
and `candidates` (`tests/headless/`). The core's own tests of prompts and
their candidates (`ModelTest.candidateChecks`) run on the core's test
kit's minibuffer (`lean/Editor/Test/Minibuffer.lean`), whose
commands act through the same operations.
-/

namespace Editor.Minibuffer

/-- The name the accept command is registered under. -/
def acceptName : String :=
  MinibufferApi.acceptName

/-- The name the cancel command is registered under. -/
def cancelName : String :=
  MinibufferApi.cancelName

/-- The name the command that moves to the next candidate is registered
under. -/
def nextName : String :=
  MinibufferApi.nextName

/-- The name the command that moves to the previous candidate is registered
under. -/
def previousName : String :=
  MinibufferApi.previousName

/-- The name the command that puts a candidate in the minibuffer is
registered under. -/
def insertName : String :=
  MinibufferApi.insertName

/-- The name the command that deletes backward is registered under. -/
def deleteBackwardName : String :=
  MinibufferApi.deleteBackwardName

/-- The name the command that deletes to the input's start is registered
under. -/
def deleteToStartName : String :=
  MinibufferApi.deleteToStartName

/-- The name the command that asks for the input scheme is registered
under. -/
def askName : String :=
  MinibufferApi.askName

/-- What the command that asks for the input scheme says in the echo area
when the prompt is refused: its name, then why. -/
def notAsking (refusal : PromptRefusal) : String :=
  s!"{askName}: {refusal.describe}"

/-- The command that asks for the input scheme, as it is called ("Asking for
the input scheme", in the module docs): opens a prompt labelled with its
first argument, a string, or none, whose continuation is the reserved name
`InputScheme.answerName`, so the answer goes to the scheme. Where the
prompt is refused, because one is open, it says so in the echo area
(`notAsking`). -/
def askCommand (call : Call) : EditorM Unit := do
  let label :=
    match call.arguments with
    | .str label :: _ => label
    | _ => ""
  if let .error refusal← prompt label { command := InputScheme.answerName } then
    message (notAsking refusal)

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

/-- The command that puts a candidate in the minibuffer, as it is called:
the chosen candidate, or the first listed, replaces the input
(`insertCandidate`). With no prompt open it says so in the echo area. -/
def insertCommand (_ : Call) : EditorM Unit := do
  if let .error _← insertCandidate then
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

/-- The command that deletes to the input's start, as it is called
("Deleting to the start", in the module docs): what is before the head of
the minibuffer's selection's primary range is deleted, and what is after it
kept, as Vim's `c_CTRL-U` does. It never cancels the prompt, even on an
empty minibuffer. With no prompt open it says so in the echo area. -/
def deleteToStartCommand (_ : Call) : EditorM Unit := do
  let state ← editorState
  let some asked := state.prompt | message notOpen
  let some minibuffer := state.target? asked.view | message notOpen
  let selection ← minibuffer.selection
  let some range := selection.ranges[selection.primary]? | return
  minibuffer.replaceExtents selection #[⟨0, range.head⟩] ""

/-- The name the command that takes a batch of a source's job is registered
under: the one such a job posts (`Completion.candidatesCommand`). -/
def candidatesName : String :=
  MinibufferApi.candidatesName

/-- What the command that takes a batch says in the echo area for arguments
that are no batch. -/
def malformedBatch : String :=
  s!"{candidatesName}: malformed batch"

/-- The command that takes a batch of a source's job, as it is called
("Taking a batch", in the module docs): its arguments are the batch, with
the view, the source's index and the generation it is for
(`Completion.batchOfArguments?`), and the open prompt takes it when they are
its own (`StateRequest.addCandidates`). Arguments that are no batch say
`malformedBatch` in the echo area. -/
def candidatesCommandOf (call : Call) : EditorM Unit := do
  match Completion.batchOfArguments? call.arguments with
  | some (view, index, generation, batch) =>
    discard <| EditorState.ask (.addCandidates view index generation batch)
  | none =>
    message malformedBatch

/-- The minibuffer's mode: the major mode the minibuffer's buffer is made
with. It fills the role `activate` with the accept command, the role `quit`
with the cancel command, and the roles `next-item` and `previous-item` with
the commands that move through the candidates. -/
def mode : Mode :=
  { name := MinibufferApi.modeName
    roles :=
      [(Role.activate, acceptName), (Role.quit, cancelName), (Role.nextItem, nextName),
        (Role.previousItem, previousName)] }

end Editor.Minibuffer
