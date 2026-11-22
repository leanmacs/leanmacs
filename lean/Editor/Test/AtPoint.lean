import Editor.Api
import Editor.Completion.AtPoint
import Editor.Package

/-!
# The test kit: AtPoint

A hand-written implementation of completion at point's commands, over the
core's API: `package`, a package named `at-point`. The core's tests complete
at point through it, so none of them depends on the package that ships
(`docs/design/keymaps-and-modes.md`, "Completion at point"). It registers
nine commands under the names the core's reachers name as text: the seven
the Vim scheme's insert table binds (`packages/evil/Evil/Vim/Default.lean`,
`insertCommands`) and the two the core runs by itself, whose names are the
core's (`Completion.AtPoint.triggeredCommand`, `.pausedCommand`,
`Editor/Completion/AtPoint.lean`). `names` lists them in the order they are
registered.

Each command acts on the session open in the target's window, if there is
one, through the operations of `Editor/Api.lean`, "Completion at point":

| Command | With a session open in the target's view | With none |
|---|---|---|
| `at-point-complete` | Nothing | `completeAtPoint .key` |
| `at-point-next` | `previewAtPoint .next` | `completeAtPoint .key` |
| `at-point-previous` | `previewAtPoint .previous` | `completeAtPoint .key` |
| `at-point-tab` | `previewAtPoint .next` | Runs `insert-tab` by name, then `retype`s a tab |
| `at-point-backtab` | `previewAtPoint .previous` | Nothing |
| `at-point-return` | `acceptAtPoint` when a candidate is chosen; otherwise `endAtPoint`, then as with none | Runs `insert-newline` by name, then `retype`s a line feed |
| `at-point-quit` | `quitAtPoint` | Runs `keyboard-quit` by name |
| `at-point-triggered` (a character) | Nothing | `completeAtPoint (.trigger c)`, silently |
| `at-point-paused` (a view and milliseconds) | Nothing | When the view is focused and no prompt is open, `completeAtPoint (.pause ms)`, silently |

It says nothing when nothing answers or the ask is refused: what the
package that ships says then is that package's own choice, pinned by its
own tests. It registers no source and no at-point source; a test registers
the ones it asks.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import").
-/

namespace Editor.Test.AtPoint

open Editor

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

/-- The name of the command the loop runs on a typed trigger: the core's. -/
def triggeredName : String :=
  Completion.AtPoint.triggeredCommand

/-- The name of the command a pause that fired runs: the core's. -/
def pausedName : String :=
  Completion.AtPoint.pausedCommand

/-- The names `package` registers its commands under, in the order it
registers them. -/
def names : Array String :=
  #[completeName, nextName, previousName, tabName, backtabName, returnName, quitName, triggeredName,
    pausedName]

/-- Whether a session is open in the target's window of `call`. -/
def opened (call : Call) : EditorM Bool :=
  return (← editorState).atPoint.any (·.view == call.target.window.id)

/-- `at-point-complete`: asks, by a key, unless a session is open. -/
def complete (call : Call) : EditorM Unit := do
  unless ← opened call do
    discard <| completeAtPoint .key

/-- `at-point-next` and `at-point-previous`: moves the open session's choice
by `step`, or with none asks, by a key. -/
def stepOrAsk (step : Candidates.Step) (call : Call) : EditorM Unit := do
  if ← opened call then
    discard <| previewAtPoint step
  else
    discard <| completeAtPoint .key

/-- `at-point-tab`: moves the choice down, or with no session runs
`insert-tab` and, when it ran, says it typed a tab. -/
def tab (call : Call) : EditorM Unit := do
  if ← opened call then
    discard <| previewAtPoint .next
  else if ← runCommand "insert-tab" call then
    retype call.target.window.id "\t"

/-- `at-point-backtab`: moves the choice up; nothing with no session. -/
def backtab (call : Call) : EditorM Unit := do
  if ← opened call then
    discard <| previewAtPoint .previous

/-- `at-point-return`: accepts the chosen candidate; with nothing chosen
ends the session and, as with no session, runs `insert-newline` and, when it
ran, says it typed a line feed. -/
def «return» (call : Call) : EditorM Unit := do
  if ← opened call then
    if (← editorState).atPoint.any (·.candidates.chosen.isSome) then
      discard acceptAtPoint
      return
    discard endAtPoint
  if ← runCommand "insert-newline" call then
    retype call.target.window.id "\n"

/-- `at-point-quit`: quits the open session, or with none runs
`keyboard-quit`. -/
def quit (call : Call) : EditorM Unit := do
  if ← opened call then
    discard quitAtPoint
  else
    discard <| runCommand "keyboard-quit" call

/-- `at-point-triggered`, with the trigger character as its argument: asks
on the trigger, silently, unless a session is open. -/
def triggered (call : Call) : EditorM Unit := do
  let [.str text] := call.arguments | return
  let some char := text.toList.head? | return
  unless ← opened call do
    discard <| completeAtPoint (.trigger char) (silent := true)

/-- `at-point-paused`, with the view and the pause's milliseconds as its
arguments: asks on the pause, silently, when the view is focused and no
prompt and no session is open. -/
def paused (call : Call) : EditorM Unit := do
  let [.nat view, .nat ms] := call.arguments | return
  let state ← editorState
  if state.frame.focused == ⟨view⟩ && state.prompt.isNone && state.atPoint.isNone then
    discard <| completeAtPoint (.pause ms) (silent := true)

/-- The package `at-point` of the core's tests: the nine commands, under
`names`, in that order. -/
def package : Package :=
  { name := "at-point"
    setup := do
      commandWith completeName complete
      commandWith nextName (stepOrAsk .next)
      commandWith previousName (stepOrAsk .previous)
      commandWith tabName tab
      commandWith backtabName backtab
      commandWith returnName «return»
      commandWith quitName quit
      commandWith triggeredName triggered
      commandWith pausedName paused }

end Editor.Test.AtPoint
