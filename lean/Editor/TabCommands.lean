import Editor.Api
import Editor.WindowCommands

/-!
# The tab commands

The commands that open, close, select, rename and move the frame's tabs,
each over the tab operations of the editor API (`ViewId.newTab`,
`changeTab`, `Editor/Api.lean`) and the state's readers (`Frame.tabs`,
`Frame.tabOf?`, `EditorState.tabLabel`, `Editor/State.lean`, "Tabs").
Which key reaches a command is the bindings' business alone: the Vim
scheme binds them under `C-w` with tmux's keys (`Vim.Default.tabKeys`,
`Editor/InputScheme/Vim/Default.lean`).

- **Each acts on its call's window's tab** (`tabOf`: the tab of
  `call.target.window.id`), never on the tab in view, as the window
  commands act on their call's window (`Editor/WindowCommands.lean`). So a
  config that runs `tab-close` on a hidden tab's window closes that tab.
  The one window of no tab is the minibuffer's, which a prompt's
  continuation may be called with: there it is the tab in view, whose
  window the prompt was asked from.
- **Each reads a count from its call's first `.nat` argument**, as the
  window commands do (`WindowCommands.countOf`), 0 for none.
- **Each gives up with the refusal's sentence** (`LayoutRefusal.describe`),
  so the echo area says, for the last tab,
  `tab-close: the last tab cannot be closed`, and for a missing one
  `tab-select-5: there is no tab 5`.

Tabs are numbered from 1 here, as the tab bar and the keys number them;
the state's indices are from 0.

| Command | Name | What it does |
|---|---|---|
| `new` | `tab-new` | A new tab right after the call's window's tab, showing that window's buffer (`ViewId.newTab`: Emacs's `tab-bar-new-tab-choice` default, and what a split shows), and focuses its window, which brings it into view |
| `close` | `tab-close` | Closes the call's window's tab, every window of it (`TabChange.close`); the last tab is refused with `onlyTab` |
| `next` | `tab-next` | Selects the tab after the call's window's tab, wrapping; with a count N, tab N (Vim's `{count}gt`), refused with `noSuchTab` when there is none |
| `previous` | `tab-previous` | Selects the tab before it, wrapping; with a count N, the tab N before it, wrapping (Vim's `{count}gT`) |
| `selectNumbered n` | `tab-select-1` … `tab-select-9` | Selects tab n, refused with `noSuchTab` when there is none (tmux's `select-window -t :=n`, which is refused for a missing window too) |
| `switch` | `tab-switch` | With a string first argument, selects the tab it names (`resolve`). Otherwise it asks, through the minibuffer, labelled `switchPrompt`, with itself as the continuation, as `switch-buffer` asks; the candidates are `"{n} {label}"` for every tab, in order. An answer is a candidate exactly, then the first tab whose label it is, then a number of a tab, then the fuzzy matcher's best candidate (`Fuzzy.rank`); otherwise `noMatch` is said. Where the prompt is refused, it says so (`notAsking`) |
| `rename` | `tab-rename` | With a string first argument, names the call's window's tab, an empty one going back to the generated label. Otherwise it asks, labelled `renamePrompt`, with the name the tab was given as the initial text, and with itself as the continuation |
| `moveBy forward` | `tab-move-right`, `tab-move-left` | Moves the call's window's tab one place, or by the count, clamped at the ends; the tab in view stays in view |

A prompt's continuation is called with the window the prompt was asked
from, a window of the tab in view, so an answer acts on the tab in view.

They are compiled: a host registers them for the owner `compiled`
(`Editor/TabCommands/Compiled.lean`), so config can call them and bind
keys to them. `Editor.lean` imports this module, and not that one, which
names the registry.

Pinned by `ModelTest.tabCommandChecks`.
-/

namespace Editor.TabCommands

/-- The name `new` is registered under. -/
def newName : String :=
  "tab-new"

/-- The name `close` is registered under. -/
def closeName : String :=
  "tab-close"

/-- The name `next` is registered under. -/
def nextName : String :=
  "tab-next"

/-- The name `previous` is registered under. -/
def previousName : String :=
  "tab-previous"

/-- The name `selectNumbered n` is registered under, `tab-select-n`. -/
def selectName (n : Nat) : String :=
  s!"tab-select-{n}"

/-- The name `switch` is registered under. -/
def switchName : String :=
  "tab-switch"

/-- The name `rename` is registered under. -/
def renameName : String :=
  "tab-rename"

/-- The name `moveBy true` is registered under. -/
def moveRightName : String :=
  "tab-move-right"

/-- The name `moveBy false` is registered under. -/
def moveLeftName : String :=
  "tab-move-left"

/-- The label of the prompt `tab-switch` asks with. -/
def switchPrompt : String :=
  "Tab: "

/-- The label of the prompt `tab-rename` asks with. -/
def renamePrompt : String :=
  "Rename tab: "

/-- What the echo area says when no tab matches `text`. -/
def noMatch (text : String) : String :=
  s!"{switchName}: no tab matches `{text}`"

/-- What the echo area says when the command `name` could not ask, because
the prompt was refused. -/
def notAsking (name : String) (refusal : PromptRefusal) : String :=
  s!"{name}: {refusal.describe}"

/-- The index of the tab of the call's window, from 0: the tab it is a window
of, or, for the minibuffer's view, which is the window of no tab, the tab
in view. -/
def tabOf (state : EditorState) (call : Call) : Nat :=
  (state.frame.tabOf? call.target.window.id).getD state.frame.tabIndex

/-- `tab-switch`'s candidates, as `state` is: `"{n} {label}"` for every tab,
in order, numbered from 1 (`EditorState.tabLabel`). -/
def candidates (state : EditorState) : Array String :=
  (Array.range state.frame.tabs.size).map fun index => s!"{index + 1} {state.tabLabel index}"

/-- The index of the tab `text` names, as `state` is: the tab of the
candidate it is exactly, else the first tab whose label it is, else the
tab of the number it is, else the tab of the fuzzy matcher's best
candidate; `none` when none does. -/
def resolve (state : EditorState) (text : String) : EditorM (Option Nat) := do
  let all := candidates state
  let count := all.size
  if let some index := all.findIdx? (· == text) then
    return some index
  if let some index := (Array.range count).find? (state.tabLabel · == text) then
    return some index
  if let some number := text.toNat? then
    if 0 < number && number ≤ count then
      return some (number - 1)
  return (← Fuzzy.rank text all)[0]?

/-- Selects the tab at `index`, or gives up with the refusal's sentence. -/
def selecting (index : Nat) : EditorM Unit := do
  WindowCommands.orGiveUp (← changeTab (.select index))

/-- `tab-new`: a new tab right after the call's window's tab, its one window
on that window's buffer, focused, which brings it into view. -/
def new (call : Call) : EditorM Unit := do
  let state ← editorState
  let from_ := tabOf state call
  let made ← WindowCommands.orGiveUp (← call.target.window.id.newTab)
  -- The new tab is opened after the tab in view; it goes after the call's.
  if from_ != state.frame.tabIndex then
    WindowCommands.orGiveUp (← changeTab (.move (state.frame.tabIndex + 1) (from_ + 1)))
  WindowCommands.orGiveUp (← made.focus)

/-- `tab-close`: the call's window's tab is closed, with every window of
it. -/
def close (call : Call) : EditorM Unit := do
  WindowCommands.orGiveUp (← changeTab (.close (tabOf (← editorState) call)))

/-- `tab-next`: the tab after the call's window's tab, wrapping, or with a
count N, tab N. -/
def next (call : Call) : EditorM Unit := do
  let state ← editorState
  let count := WindowCommands.countOf call
  if 0 < count then
    selecting (count - 1)
  else
    selecting ((tabOf state call + 1) % state.frame.tabs.size)

/-- `tab-previous`: the tab before the call's window's tab, or the count of
tabs before it, wrapping. -/
def previous (call : Call) : EditorM Unit := do
  let state ← editorState
  let size := state.frame.tabs.size
  let back := WindowCommands.steps (WindowCommands.countOf call) % size
  selecting ((tabOf state call + size - back) % size)

/-- `tab-select-n`: tab `n`, numbered from 1. -/
def selectNumbered (n : Nat) (_ : Call) : EditorM Unit :=
  selecting (n - 1)

/-- Selects the tab `text` names (`resolve`), or says that none matches
(`noMatch`). -/
def switchTo (text : String) : EditorM Unit := do
  let some index ← resolve (← editorState) text | message (noMatch text)
  selecting index

/-- `tab-switch`: the tab its first argument, a string, names, or, with
anything else first, a prompt that asks for one. -/
def switch (call : Call) : EditorM Unit := do
  match call.arguments with
  | .str text :: _ =>
    switchTo text
  | _ =>
    if let .error refusal←
        prompt switchPrompt { command := switchName } (candidates :=
          return candidates (← editorState)) then
      message (notAsking switchName refusal)

/-- `tab-rename`: the call's window's tab named by its first argument, a
string, an empty one going back to the generated label, or, with anything
else first, a prompt that asks for the name. -/
def rename (call : Call) : EditorM Unit := do
  let state ← editorState
  let index := tabOf state call
  match call.arguments with
  | .str text :: _ =>
    WindowCommands.orGiveUp (← changeTab (.rename index (if text.isEmpty then none else some text)))
  | _ =>
    let given := ((state.frame.tabs[index]?).bind (·.name)).getD ""
    if let .error refusal← prompt renamePrompt { command := renameName } given then
      message (notAsking renameName refusal)

/-- `tab-move-right` and `tab-move-left`: the call's window's tab moved one
place, or by the count, clamped at the ends. -/
def moveBy (forward : Bool) (call : Call) : EditorM Unit := do
  let index := tabOf (← editorState) call
  let steps := WindowCommands.steps (WindowCommands.countOf call)
  let to := if forward then index + steps else index - steps
  WindowCommands.orGiveUp (← changeTab (.move index to))

end Editor.TabCommands
