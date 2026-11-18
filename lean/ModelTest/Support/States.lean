import Editor.Completion.Candidate
import Editor.Completion.Display
import Editor.Display
import Editor.File
import Editor.Floating
import Editor.Invocation
import Editor.Layout
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Text
import Editor.UndoTree
import Editor.Value
import ModelTest.Support.Completion
import ModelTest.Support.Geometry

/-!
# Model tests: support: States

Editor states the checks start from: windows, buffers, tabs, docked and floating
windows, open prompts with their candidates and listings, and a session at
point. Shared by several test modules under
`ModelTest/Editor/`; it holds no checks of its own.
-/

namespace ModelTest

open Editor

/-- The initial state at 640 by 480 with two more windows over its one
buffer, each with markers of its own, laid out by the default layout: view
0 is main, and views 1 and 2 the stack.

```
+---------+---------+
|         | view 1  |
| view 0  +---------+
|         | view 2  |
+---------+---------+
|  the minibuffer's |
|       strip       |
+-------------------+
```

View 0 is focused. -/
def threeWindows : TextM EditorState := do
  let state ← EditorState.initial ⟨640, 480⟩
  let some buffer := state.buffer? ⟨0⟩ | throw .noSuchText
  let more ←
    #[1, 2].mapM fun index => do
        let scroll ← buffer.text.mark (.anchor { offset := 0, bias := .before })
        let selection ← buffer.text.mark (.selection { ranges := #[⟨0, 0⟩] })
        return ({ id := ⟨index⟩, buffer := ⟨0⟩, scroll, selection } : Window)
  return { state with
      windows := state.windows ++ more
      frame := { state.frame with windows := #[⟨0⟩, ⟨1⟩, ⟨2⟩] } }

/-- The initial state at 640 by 480 with a second buffer, `other`, over a
text of its own holding "other", and a second window, view 1, on it, beside
view 0. View 0 is focused. -/
def twoBuffers : TextM EditorState := do
  let state ← EditorState.initial ⟨640, 480⟩
  let text ← createText "other"
  let scroll ← text.mark (.anchor { offset := 0, bias := .before })
  let selection ← text.mark (.selection { ranges := #[⟨0, 0⟩] })
  let history ← UndoTree.over text
  return { state with
      buffers := state.buffers.push (some { name := "other", text, history })
      windows := state.windows.push { id := ⟨1⟩, buffer := ⟨1⟩, scroll, selection }
      frame := { state.frame with windows := #[⟨0⟩, ⟨1⟩] } }

/-- The continuation the prompts of these checks are asked with: a command's
name and an argument of the asker's own. No command is registered under it
here: a continuation is plain data. -/
def asked : Invocation :=
  { command := "greet", arguments := [.nat 7] }

/-- `threeWindows` as three tabs: view 0 alone in the first, view 1 in the
second, which is in view, and view 2 in the third, each focused on its one
window under the default layout. -/
def threeTabs : TextM EditorState := do
  let state ← threeWindows
  return { state with
      frame :=
        { state.frame with
          windows := #[⟨1⟩], focused := ⟨1⟩
          tabsBefore := #[{ windows := #[⟨0⟩], focused := ⟨0⟩ }]
          tabsAfter := #[{ windows := #[⟨2⟩], focused := ⟨2⟩ }] } }

/-- `state` with a prompt asked for from its focused view, and the reply: the
label `Name: `, the continuation `asked`, and a minibuffer over the text
`text`, with a new history over it, an anchor that is its marker 0 and a
selection that is its marker 1. The operation asks the text store nothing,
so the ids are written out by hand. -/
def prompted (state : EditorState) (text : Nat := 7) : Except PromptRefusal ViewId × EditorState :=
  state.openPrompt "Name: " asked ⟨text⟩ (UndoTree.new ⟨text⟩ 0) ⟨⟨text⟩, 0⟩ ⟨⟨text⟩, 1⟩

/-- `state` with its open prompt's candidates replaced by `candidates`,
whatever they are, by hand: for comparing two states but for their
candidates, and for building a state no operation makes. A state with no
prompt open is as it was. -/
def withCandidates (state : EditorState) (candidates : Candidates) : EditorState :=
  { state with prompt := state.prompt.map ({ · with candidates }) }

/-- `state`, which has a prompt open, with the candidates `wq`, `edit` and
`w` and a listing of all three for the empty text, in that order, made with
the state's own operations. -/
def picking (state : EditorState) : EditorState :=
  let (_, set) := state.setCandidates { all := offered #["wq", "edit", "w"] }
  (set.listCandidates "" (#[0, 1, 2].map Completion.Hit.ofIndex)).2

/-- `state`, which has a prompt open, with the candidates of `texts` and a
listing for `pattern` of those at `indices`, in that order, made with the
state's own operations. -/
def listingIn (state : EditorState) (texts : Array String) (indices : Array Nat)
    (pattern : String := "") : EditorState :=
  let (_, set) := state.setCandidates { all := offered texts }
  (set.listCandidates pattern (indices.map Completion.Hit.ofIndex)).2

/-- The initial state at 640 by 480 with `count` windows over its one
buffer, views 0 up to `count - 1` in that order, each with markers of its
own, under `layout` fitted to them. View 0 is focused. -/
def windowsUnder (count : Nat) (layout : Layout) : TextM EditorState := do
  let state ← EditorState.initial ⟨640, 480⟩
  let some buffer := state.buffer? ⟨0⟩ | throw .noSuchText
  let more ←
    (Array.range (count - 1)).mapM fun index => do
        let scroll ← buffer.text.mark (.anchor { offset := 0, bias := .before })
        let selection ← buffer.text.mark (.selection { ranges := #[⟨0, 0⟩] })
        return ({ id := ⟨index + 1⟩, buffer := ⟨0⟩, scroll, selection } : Window)
  return { state with
      windows := state.windows ++ more
      frame :=
        { state.frame with
          windows := windowsUpTo count, layout := layout.fits count } }

/-- The initial state at 640 by 480 with `tiles` windows in the frame's
list, views 0 up to `tiles - 1`, and a window docked at each side of
`docked`, in order, views `tiles` on, all over its one buffer and each with
markers of its own, under `layout` fitted to the tiles. View 0 is
focused. -/
def dockedUnder (tiles : Nat) (docked : List Side) (layout : Layout) : TextM EditorState := do
  let state ← windowsUnder (tiles + docked.length) layout
  return { state with
      frame :=
        { state.frame with
          windows := windowsUpTo tiles, layout := layout.fits tiles
          docked := docked.toArray.mapIdx fun index side => (⟨tiles + index⟩, side) } }

/-- `dockedUnder 2 [.left]` under `.edge .left 25 Layout.default`: views 0
and 1 tiled, main and the stack, and view 2 docked at the left edge.

```
+----+------+------+
|    |      |      |
| 2  |  0   |  1   |
|    |      |      |
+----+------+------+
```

View 0 is focused. -/
def sidebar : TextM EditorState :=
  dockedUnder 2 [.left] (.edge .left 25 Layout.default)

/-- `state` with a float on its buffer 0 for each of `floats`, an anchor and
whether it is pinned, in order, each on top of the ones before, with views
from the state's next one on (`EditorState.freshView`), markers of its own
and the default share. The focus is as it was. -/
def withFloats (state : EditorState) (floats : List (Floating.Anchor × Bool)) : TextM EditorState :=
  do
  let some buffer := state.buffer? ⟨0⟩ | throw .noSuchText
  floats.foldlM
      (fun state (anchor, pinned) => do
        let scroll ← buffer.text.mark (.anchor { offset := 0, bias := .before })
        let selection ← buffer.text.mark (.selection { ranges := #[⟨0, 0⟩] })
        let made := state.freshView
        return {
            state with
            windows := state.windows.push { id := made, buffer := ⟨0⟩, scroll, selection }
            frame :=
              { state.frame with
                floats := state.frame.floats.push { view := made, anchor, pinned } }
            nextView := made.index + 1 })
      state

/-- `twoBuffers` with a third buffer, `hidden`, over a text of its own that
no window shows, and that text. -/
def hiddenBuffer : TextM (EditorState × TextId) := do
  let state ← twoBuffers
  let text ← createText "hidden"
  let history ← UndoTree.over text
  return ({ state with buffers := state.buffers.push (some { name := "hidden", text, history }) },
      text)

/-- The path of a file of the state checks. Nothing opens it. -/
def notePath : System.FilePath :=
  "/files/note.txt"

/-- A stamp of the state checks: any one, for a file the checks say a
buffer holds. -/
def noteStamp : File.Stamp :=
  { seconds := 3, nanoseconds := 0, size := 9 }

/-- A session at point of the state checks, in the window 0 over the buffer
0, with made-up markers of the text 0: nothing typed. -/
def stateSession (typed : String := "a") : AtPointSession :=
  { view := ⟨0⟩, buffer := ⟨0⟩, source := "line", start := ⟨⟨0⟩, 90⟩, stop := ⟨⟨0⟩, 91⟩
    typed, shown := typed }

end ModelTest
