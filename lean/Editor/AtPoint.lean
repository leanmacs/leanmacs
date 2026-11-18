import Editor.Api

/-!
# Completion at point's commands

The commands that ask for completion at point, move its choice, accept it
and quit it (`docs/design/keymaps-and-modes.md`, "Completion at point"),
after Doom Emacs's corfu module. The Vim scheme binds them in insert state
(`Editor/InputScheme/Vim/Default.lean`); they work under any scheme. Each is
given what it was called with (`Action.call`), and acts on the session open
in the target's window, if there is one (`EditorState.atPoint`), through
the operations of `Editor/Api.lean`, "Completion at point".

| Command | With a session open in the target's view | With none |
|---|---|---|
| `at-point-complete` | Nothing | `completeAtPoint .key`; says `nothing to complete at point` when nothing answers |
| `at-point-next` | `previewAtPoint .next` | As `at-point-complete` |
| `at-point-previous` | `previewAtPoint .previous` | As `at-point-complete` |
| `at-point-tab` | `previewAtPoint .next` | Runs `insert-tab` by name, then says it typed a tab |
| `at-point-backtab` | `previewAtPoint .previous` | Nothing |
| `at-point-return` | `acceptAtPoint` when a candidate is chosen; otherwise `endAtPoint`, then as with none | Runs `insert-newline` by name, then says it typed a line feed |
| `at-point-quit` | `quitAtPoint` | Runs `keyboard-quit` by name, as `C-g` does in normal state |
| `at-point-triggered` (a character) | Nothing | `completeAtPoint (.trigger c)`, silent when nothing answers and when the session closes having shown no row |
| `at-point-paused` (a view and milliseconds) | Nothing | When the view is focused and no prompt is open, `completeAtPoint (.pause ms)`, silent when nothing answers and when the session closes having shown no row |

`insert-tab` and `insert-newline` run by name, so config's commands of those
names stay reachable from `TAB` and `RET`. What they type reaches the last
change's recording through `retype`, and only when they ran.

## Where an addition goes

| Addition | Where |
|---|---|
| A new key's command | A command here, its registration in `AtPoint.commands` (`Editor/AtPoint/Compiled.lean`), and its row in `Vim.Default.insertCommands` |
| A new way to ask | An `Occasion` (`Editor/Completion/Candidate.lean`), and a command here that asks with it |

Pinned by `ModelTest.atPointChecks` (asking, on the models),
`atPointLoopChecks` (the keys, the preview, the accept and the closing, on
the evil driver) and `atPointRepeatChecks` (what the repeat replays).
-/

namespace Editor.AtPoint

/-- The name of the command that asks: `C-SPC` in insert state. -/
def completeName : String :=
  "at-point-complete"

/-- The name of the command that moves the choice down, or asks: `C-n`. -/
def nextName : String :=
  "at-point-next"

/-- The name of the command that moves the choice up, or asks: `C-p`. -/
def previousName : String :=
  "at-point-previous"

/-- The name of `TAB`'s command in insert state. -/
def tabName : String :=
  "at-point-tab"

/-- The name of `S-TAB`'s command in insert state. -/
def backtabName : String :=
  "at-point-backtab"

/-- The name of `RET`'s command in insert state. -/
def returnName : String :=
  "at-point-return"

/-- The name of `C-g`'s command in insert state. -/
def quitName : String :=
  "at-point-quit"

/-- The name of the command a typed trigger character runs. -/
def triggeredName : String :=
  "at-point-triggered"

/-- The name of the command a pause that fired runs. -/
def pausedName : String :=
  "at-point-paused"

/-- What the echo area says when a key asks and no at-point source
answers. -/
def nothing : String :=
  "nothing to complete at point"

/-- What the echo area says when a session closes having never listed a
candidate. -/
def noCompletions : String :=
  "no completions"

/-- The session open in the target's window of `call`, if there is one. -/
def sessionOf (call : Call) : EditorM (Option AtPointSession) :=
  return (← editorState).atPoint.filter (·.view == call.target.window.id)

/-- Asks for completion at point on `occasion` (`completeAtPoint`): when
nothing answers, the ask is refused, or the session it opens closes having
never shown a row, the echo area says so, unless `silent`. -/
def ask (occasion : Completion.Occasion) (silent : Bool := false) : EditorM Unit := do
  match ← completeAtPoint occasion silent with
  | .ok true =>
    pure ()
  | .ok false =>
    unless silent do
      message nothing
  | .error refusal =>
    unless silent do
      message refusal.describe

/-- `at-point-complete`: asks, by a key, unless a session is open in the
target's window. -/
def complete (call : Call) : EditorM Unit := do
  if (← sessionOf call).isNone then
    ask .key

/-- Moves the open session's choice by `step`, or with none asks, by a
key. -/
def stepOrAsk (step : Candidates.Step) (call : Call) : EditorM Unit := do
  if (← sessionOf call).isSome then
    discard <| previewAtPoint step
  else
    ask .key

/-- `at-point-tab`: moves the choice down, or with no session runs
`insert-tab` and says it typed a tab. -/
def tab (call : Call) : EditorM Unit := do
  if (← sessionOf call).isSome then
    discard <| previewAtPoint .next
  else if ← runCommand "insert-tab" call then
    retype call.target.window.id "\t"

/-- `at-point-backtab`: moves the choice up; nothing with no session. -/
def backtab (call : Call) : EditorM Unit := do
  if (← sessionOf call).isSome then
    discard <| previewAtPoint .previous

/-- `at-point-return`: accepts the chosen candidate; with nothing chosen
closes the session and, as with no session, runs `insert-newline` and says
it typed a line feed. -/
def «return» (call : Call) : EditorM Unit := do
  match ← sessionOf call with
  | some session =>
    if session.candidates.chosen.isSome then
      discard acceptAtPoint
      return
    discard endAtPoint
  | none =>
    pure ()
  if ← runCommand "insert-newline" call then
    retype call.target.window.id "\n"

/-- `at-point-quit`: quits the open session, or with none runs
`keyboard-quit`. -/
def quit (call : Call) : EditorM Unit := do
  if (← sessionOf call).isSome then
    discard quitAtPoint
  else
    discard <| runCommand "keyboard-quit" call

/-- `at-point-triggered`, with the trigger character as its argument: asks
on the trigger, silently, unless a session is open. -/
def triggered (call : Call) : EditorM Unit := do
  let [.str text] := call.arguments | return
  let some char := text.toList.head? | return
  if (← editorState).atPoint.isNone then
    ask (.trigger char) (silent := true)

/-- `at-point-paused`, with the view and the pause's milliseconds as its
arguments: asks on the pause, silently, when the view is focused and no
prompt and no session is open. A key since would have disarmed the pause. -/
def paused (call : Call) : EditorM Unit := do
  let [.nat view, .nat ms] := call.arguments | return
  let state ← editorState
  if state.frame.focused == ⟨view⟩ && state.prompt.isNone && state.atPoint.isNone then
    ask (.pause ms) (silent := true)

end Editor.AtPoint
