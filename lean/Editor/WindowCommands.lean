import Editor.Api
import Editor.Ex

/-!
# The window commands

The commands that split, close, focus and arrange the frame's windows, each
over the window operations of the editor API (`ViewId.split`,
`ViewId.close`, `ViewId.focus`, `ViewId.arrange`, `Editor/Api.lean`) and
the state's readers (`EditorState.toward?`, `EditorState.cycled`,
`Editor/State.lean`). Vim 9.1's behaviour is pinned on the commands, so
which key reaches a command is the bindings' business alone: the Vim
scheme binds them under `C-w` (`Vim.Default.windowKeys`,
`Editor/InputScheme/Vim/Default.lean`).

- **Each acts on its call's window** (`call.target.window.id`), never on
  the frame's focus, so a command a config runs on another window acts
  there.
- **Each reads a count from its call's first `.nat` argument**, as the Vim
  scheme lays one out, 0 for none.
- **Each gives up with the refusal's sentence** (`LayoutRefusal.describe`),
  so the echo area says, for the last window,
  `window-close: the last window cannot be closed`.

| Command | Name | What it does |
|---|---|---|
| `split` | `window-split` | Splits the window, the new one above it (`{ before := true }`, Vim's `nosplitbelow`), and focuses the new one: Vim's `CTRL-W s` |
| `splitVertically` | `window-split-vertically` | The same side by side, the new one on the left (`nosplitright`): `CTRL-W v` |
| `new` | `window-new` | Splits as `split` does, then shows a new empty buffer with no file in the new window, named `scratch` or the next free name, and focuses it: Vim's `:new` and `CTRL-W n` |
| `close` | `window-close` | Closes the window (`ViewId.close`): `CTRL-W c` |
| `quit` | `window-quit` | Closes the window, or on the last window runs `quit` (`Ex.quitName`), which asks the editor to quit: Vim's `:quit` and `CTRL-W q` |
| `only` | `window-only` | Closes every other window of the frame, the docked ones too, and says `already only one window` when there is none, as Vim does: `CTRL-W o`. From a window docked at an edge it gives up with `atEdge`, as Emacs refuses a side window as the only window |
| `focusToward side` | `window-focus-left`, `-down`, `-up`, `-right` | Focuses the window `count` steps that way (`EditorState.toward?`), and does nothing when none is there, as Vim is silent at an edge: `CTRL-W h j k l` |
| `focusCycled forward` | `window-focus-next`, `window-focus-previous` | Focuses the next or the previous window of the frame, the tiles then the docked windows, wrapping, or the Nth with a count (`EditorState.cycled`): `CTRL-W w` and `W` |
| `focusEnd last` | `window-focus-top`, `window-focus-bottom` | Focuses the first or the last window of the frame (`Frame.all`): `CTRL-W t` and `b` |
| `focusLast` | `window-focus-last` | Focuses the window of the frame focused before this one (`Frame.lastFocused`) while it is another window of the frame, and otherwise gives up with `noPreviousWindow`, where Vim beeps: `CTRL-W p` |
| `arranging change` | `window-exchange`, `window-rotate`, `window-rotate-back`, `window-balance`, `window-taller`, `window-shorter`, `window-wider`, `window-narrower`, `window-zoom`, `window-promote`, `window-demote`, `window-main-more`, `window-main-fewer` | `ViewId.arrange` with its change (`Arrange`). Exchange takes the count as the Nth window, and resize and main's count take it as the steps, 1 when there is none |
| `arranging fun _ => .edge side` | `window-edge-left`, `-bottom`, `-top`, `-right` | Docks the window at that edge, moves a window docked at another edge there, or moves a window docked there back to the end of the tiled list (`Arrange.edge`): Vim's `CTRL-W H J K L`, which move a window to the far side at the full extent. Recorded departures: under a layout with no such edge it gives up with `noSuchEdge`, where Vim restructures its frames under any layout, and on a window already at that edge it moves it back into the tiles, where Vim does nothing |

They are compiled: a host registers them for the owner `compiled`
(`Editor/WindowCommands/Compiled.lean`), so config can call them and bind
keys to them. `Editor.lean` imports this module, and not that one, which
names the registry.

Pinned by `ModelTest.windowCommandChecks`.
-/

namespace Editor.WindowCommands

/-- The name `split` is registered under. -/
def splitName : String :=
  "window-split"

/-- The name `splitVertically` is registered under. -/
def splitVerticallyName : String :=
  "window-split-vertically"

/-- The name `new` is registered under. -/
def newName : String :=
  "window-new"

/-- The name `close` is registered under. -/
def closeName : String :=
  "window-close"

/-- The name `quit` is registered under. -/
def quitName : String :=
  "window-quit"

/-- The name `only` is registered under. -/
def onlyName : String :=
  "window-only"

/-- The name `focusToward .left` is registered under. -/
def leftName : String :=
  "window-focus-left"

/-- The name `focusToward .bottom` is registered under. -/
def downName : String :=
  "window-focus-down"

/-- The name `focusToward .top` is registered under. -/
def upName : String :=
  "window-focus-up"

/-- The name `focusToward .right` is registered under. -/
def rightName : String :=
  "window-focus-right"

/-- The name `focusCycled true` is registered under. -/
def nextName : String :=
  "window-focus-next"

/-- The name `focusCycled false` is registered under. -/
def previousName : String :=
  "window-focus-previous"

/-- The name `focusEnd false` is registered under. -/
def topName : String :=
  "window-focus-top"

/-- The name `focusEnd true` is registered under. -/
def bottomName : String :=
  "window-focus-bottom"

/-- The name `focusLast` is registered under. -/
def lastName : String :=
  "window-focus-last"

/-- The name the exchange is registered under. -/
def exchangeName : String :=
  "window-exchange"

/-- The name the forward rotation is registered under. -/
def rotateName : String :=
  "window-rotate"

/-- The name the backward rotation is registered under. -/
def rotateBackName : String :=
  "window-rotate-back"

/-- The name the balance is registered under. -/
def balanceName : String :=
  "window-balance"

/-- The name growing along rows is registered under. -/
def tallerName : String :=
  "window-taller"

/-- The name shrinking along rows is registered under. -/
def shorterName : String :=
  "window-shorter"

/-- The name growing along columns is registered under. -/
def widerName : String :=
  "window-wider"

/-- The name shrinking along columns is registered under. -/
def narrowerName : String :=
  "window-narrower"

/-- The name the zoom is registered under. -/
def zoomName : String :=
  "window-zoom"

/-- The name the promotion to main is registered under. -/
def promoteName : String :=
  "window-promote"

/-- The name the demotion is registered under. -/
def demoteName : String :=
  "window-demote"

/-- The name one more main window is registered under. -/
def mainMoreName : String :=
  "window-main-more"

/-- The name one fewer main window is registered under. -/
def mainFewerName : String :=
  "window-main-fewer"

/-- The name `arranging fun _ => .edge .left` is registered under. -/
def edgeLeftName : String :=
  "window-edge-left"

/-- The name `arranging fun _ => .edge .bottom` is registered under. -/
def edgeBottomName : String :=
  "window-edge-bottom"

/-- The name `arranging fun _ => .edge .top` is registered under. -/
def edgeTopName : String :=
  "window-edge-top"

/-- The name `arranging fun _ => .edge .right` is registered under. -/
def edgeRightName : String :=
  "window-edge-right"

/-- What `only` says when the window is the only one of the frame. -/
def alreadyOnly : String :=
  "already only one window"

/-- The count the call carries: its first argument when that is a natural
number, as the Vim scheme lays a count out, and 0 for none. -/
def countOf (call : Call) : Nat :=
  match call.arguments with
  | .nat count :: _ => count
  | _ => 0

/-- The value of `result`, or the command given up with what its refusal
says. -/
def orGiveUp {α : Type} (result : Except LayoutRefusal α) : EditorM α :=
  match result with
  | .ok value => pure value
  | .error refusal => giveUp refusal.describe

/-- Splits the call's window by `placement` and focuses the new window,
which is handed back. -/
def splitFocused (placement : Placement) (call : Call) : EditorM ViewId := do
  let made ← orGiveUp (← call.target.window.id.split placement)
  orGiveUp (← made.focus)
  return made

/-- `window-split`: the new window above the call's window, focused. -/
def split (call : Call) : EditorM Unit :=
  discard <| splitFocused { before := true } call

/-- `window-split-vertically`: the new window left of the call's window,
focused. -/
def splitVertically (call : Call) : EditorM Unit :=
  discard <| splitFocused { axis := .columns, before := true } call

/-- `window-new`: a split as `window-split` makes, showing a new empty
buffer with no file, named `scratch` or the next free name, focused. -/
def new (call : Call) : EditorM Unit := do
  let made ← splitFocused { before := true } call
  let name := (← editorState).freeName EditorState.scratchName
  let .ok buffer ← createBuffer name | giveUp "making the empty buffer was refused"
  orGiveUp (← made.show buffer)

/-- `window-close`: the call's window is closed. -/
def close (call : Call) : EditorM Unit := do
  orGiveUp (← call.target.window.id.close)

/-- `window-quit`: the call's window is closed, or, when it is the last of
the list, the command `quit` runs, which asks the editor to quit. -/
def quit (call : Call) : EditorM Unit := do
  match ← call.target.window.id.close with
  | .ok () =>
    pure ()
  | .error .onlyWindow =>
    discard <| runCommand Ex.quitName call
  | .error refusal =>
    giveUp refusal.describe

/-- `window-only`: every other window of the frame, tiled or docked, is
closed, or, when there is none, `alreadyOnly` is said. From a window docked
at an edge it gives up with `atEdge`: the tiles would be gone. -/
def only (call : Call) : EditorM Unit := do
  let view := call.target.window.id
  let state ← editorState
  if state.minibufferView? == some view then
    giveUp (LayoutRefusal.ofMinibuffer view).describe
  if (state.frame.sideOf? view).isSome then
    giveUp (LayoutRefusal.atEdge view).describe
  unless state.frame.windows.contains view do
    giveUp (LayoutRefusal.noSuchWindow view).describe
  let others := state.frame.all.filter (· != view)
  if others.isEmpty then
    message alreadyOnly
  for other in others do
    orGiveUp (← other.close)

/-- Focuses `view`, unless it is none: nothing happens then. -/
def focusing (view : Option ViewId) : EditorM Unit := do
  if let some view := view then
    orGiveUp (← view.focus)

/-- `window-focus-left`, `-down`, `-up` and `-right`: the window the count
of steps towards `side`, once for none, is focused; nothing happens when
none is there. -/
def focusToward (side : Side) (call : Call) : EditorM Unit := do
  focusing ((← editorState).toward? call.target.window.id side (countOf call))

/-- `window-focus-next` and `window-focus-previous`: the next or the
previous window of the list, wrapping, or the Nth with a count, is
focused. -/
def focusCycled (forward : Bool) (call : Call) : EditorM Unit := do
  focusing ((← editorState).cycled call.target.window.id forward (countOf call))

/-- `window-focus-top` and `window-focus-bottom`: the first window of the
frame, or the last when `last`, is focused, in `Frame.all`'s order: the
tiles, then the docked windows. -/
def focusEnd (last : Bool) (_ : Call) : EditorM Unit := do
  let windows := (← editorState).frame.all
  focusing (if last then windows.back? else windows[0]?)

/-- `window-focus-last`: the window of the frame focused before the call's
window is focused, while it is another window of the frame; otherwise the
command gives up with `noPreviousWindow`. -/
def focusLast (call : Call) : EditorM Unit := do
  let frame := (← editorState).frame
  match frame.lastFocused with
  | some view =>
    if view != call.target.window.id && frame.contains view then
      orGiveUp (← view.focus)
    else
      giveUp LayoutRefusal.noPreviousWindow.describe
  | none =>
    giveUp LayoutRefusal.noPreviousWindow.describe

/-- The command that makes the change `change` of the count on the call's
window (`ViewId.arrange`). -/
def arranging (change : Nat → Arrange) (call : Call) : EditorM Unit := do
  orGiveUp (← call.target.window.id.arrange (change (countOf call)))

/-- The count as a number of steps: 1 for none. -/
def steps (count : Nat) : Nat :=
  max 1 count

/-- The change `window-exchange` makes: with the window the count names, or
with the next when there is no count. -/
def exchange (count : Nat) : Arrange :=
  .exchange (if count == 0 then none else some count)

end Editor.WindowCommands
