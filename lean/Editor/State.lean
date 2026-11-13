import Editor.Scene
import Editor.Store
import Editor.UndoTree

/-!
# The editor state

What the editor is showing and editing, as one immutable value the editor
thread holds (`EditorState`): the buffers, the windows, the one frame they
are arranged in, the echo area and the input method's preedit. The command
loop (`Editor/Loop.lean`) takes it from one event to the next and publishes
a scene of it after each.

- **A buffer** (`Buffer`) is a text of the text store, a name, the text's
  undo tree, the buffer's local values (`Value` trees, as a store's cell
  holds) and the names of its modes. What a mode means is the command
  loop's phase 7; here it is only a name.
- **A window** (`Window`) is a view of a buffer: its `ViewId`, which names it
  in every scene, the buffer it shows, its scroll position as an anchor
  marker of the buffer's text, and its selections as one selection marker
  of that text, whose ranges are its cursors.
- **The frame** (`Frame`) is the one window of the platform: its size, the
  split tree of the editor's windows (`Split`), the window that is focused,
  and whether the frame has the keyboard focus.

## The split tree and its invariants

The split tree is a binary tree. A leaf is a window, by its `ViewId`, or the
minibuffer's place; a split divides its rectangle along an axis, rows
(stacked) or columns (side by side), between its two children
(`Split.rects`): the first takes half the extent, rounded down, and the
second the rest. A subtree with no window takes no space and its sibling
takes all of it. So the minibuffer's place takes none while no prompt is
open (the command loop's phase 10 gives it some), and the views tile the
frame.

The invariants are part of the model (`EditorState.wellFormed`):

- the focused window is in the tree;
- the tree has exactly one minibuffer leaf;
- the tree's window ids are distinct, and they are exactly the windows'
  ids;
- each window's buffer exists.

Each clause is seen to refuse: `ModelTest.spoilings` builds, for every
clause, a state that breaks it and keeps the others, and none is well
formed. A clause added here gets a state there.

An operation that would break one is refused with a `LayoutRefusal` and
changes nothing: it returns the state it was given. Two operations exist,
with no command bound to either (the command loop's phase 8 offers them as
requests), and they have the shape that request's handler will have:

- `removeWindow` refuses `noSuchWindow` for a window not in the tree, and
  `onlyWindow` for the last window, which would leave nothing to focus. The
  removed window's sibling takes the place of the split that held both, and
  the window is handed back: its markers are the caller's to give up. When
  the window was focused, the focus moves to the first window, in drawing
  order, of the subtree that took its place, or, when that subtree has
  none, to the first window of the tree.
- `focusWindow` refuses `noSuchWindow` for a window not in the tree.

The minibuffer's place has no `ViewId`, so no operation here can remove it.
`LayoutRefusal` has only the constructors these two can reach: a phase that
adds an operation able to remove the minibuffer's place adds its
constructor.

## Smaller rules

- A new state's frame is focused, on view 0, with one window over a buffer
  called `scratch` of an empty text, whose scroll anchor is at 0 and whose
  selection is one exclusive cursor at 0 (`EditorState.initial`).
- The frame's `hasFocus` is the platform window's keyboard focus. While the
  frame does not have it, the scene names no focused view.
- The preedit is the text an input method is composing in the focused
  window; `none` when it is composing nothing.
- No ambient context: a handler is given the window it acts on and its
  buffer, as a `Target`, never "the current buffer".

## Where a new field goes

| What it belongs to | Where |
|---|---|
| One buffer (a file's path, a modified flag) | A field of `Buffer` |
| One view (a goal column, a scroll offset) | A field of `Window` |
| The whole editor (registers, the pending key prefix) | A field of `EditorState` |
| What the user sees of it | A field of the scene (`Editor/Scene.lean`), filled in `Loop.scene` (`Editor/Loop.lean`) |

Each is pinned by `ModelTest.stateChecks`, and what the scene shows of it by
`ModelTest.loopChecks`.
-/

namespace Editor

/-- The name of a buffer: its index in the state's buffers. -/
structure BufferId where
  /-- Which buffer. -/
  index : Nat
  deriving DecidableEq, Repr

/-- A buffer: a text and what the editor keeps about it. -/
structure Buffer where
  /-- Its name, as the user sees it. -/
  name : String
  /-- Its text, in the text store. -/
  text : TextId
  /-- The history of its text. -/
  history : UndoTree
  /-- Its local values, by name. -/
  locals : Array (String × Value) := #[]
  /-- The names of its modes. -/
  modes : Array String := #[]
  deriving BEq, Repr

/-- A window: a view of a buffer. -/
structure Window where
  /-- The view's name in every scene. -/
  id : ViewId
  /-- The buffer it shows. -/
  buffer : BufferId
  /-- Its scroll position: an anchor marker of the buffer's text. -/
  scroll : MarkerId
  /-- Its selections: one selection marker of the buffer's text, whose
  ranges are its cursors. -/
  selection : MarkerId
  deriving DecidableEq, Repr

/-- The axis a split divides its rectangle along. -/
inductive Axis where
  /-- One child above the other. -/
  | rows
  /-- One child beside the other. -/
  | columns
  deriving DecidableEq, Repr

/-- The arrangement of a frame's windows. -/
inductive Split where
  /-- A window, by the name of its view. -/
  | window (id : ViewId)
  /-- The minibuffer's place. -/
  | minibuffer
  /-- `first` and `second` dividing a rectangle along `axis`: `first` above
  or to the left. -/
  | split (axis : Axis) (first second : Split)
  deriving DecidableEq, Repr

/-- The one window of the platform, and how the editor's windows are
arranged in it. -/
structure Frame where
  /-- Its size, in physical pixels. -/
  size : Size
  /-- Its split tree. -/
  tree : Split
  /-- The window that is focused within it. -/
  focused : ViewId
  /-- Whether it has the keyboard focus. -/
  hasFocus : Bool := true
  deriving DecidableEq, Repr

/-- Everything the editor is showing and editing. -/
structure EditorState where
  /-- The buffers; a `BufferId` is an index here. -/
  buffers : Array Buffer
  /-- The windows, each named by its view's id. -/
  windows : Array Window
  /-- The frame. -/
  frame : Frame
  /-- The echo area's text. -/
  echo : String := ""
  /-- The text an input method is composing in the focused window, if any. -/
  preedit : Option String := none
  deriving BEq, Repr

/-- What a handler acts on: a window and the buffer it shows. -/
structure Target where
  /-- The window. -/
  window : Window
  /-- Its buffer. -/
  buffer : Buffer
  deriving BEq, Repr

/-- Why an operation on the layout was refused. -/
inductive LayoutRefusal where
  /-- It would remove the last window, leaving nothing to focus. -/
  | onlyWindow
  /-- The window is not in the frame's tree. -/
  | noSuchWindow (id : ViewId)
  deriving DecidableEq, Repr

namespace Split

/-- The windows of the tree, in drawing order. -/
def windows : Split → Array ViewId
  | .window id => #[id]
  | .minibuffer => #[]
  | .split _ first second => first.windows ++ second.windows

/-- How many minibuffer leaves the tree has. -/
def minibuffers : Split → Nat
  | .window _ => 0
  | .minibuffer => 1
  | .split _ first second => first.minibuffers + second.minibuffers

/-- `rect` cut in two along `axis`: the first part takes half its extent
along the axis, rounded down, and the second the rest. -/
def halve (axis : Axis) (rect : Rect) : Rect × Rect :=
  match axis with
  | .rows =>
    let top := rect.height / 2
    ({ rect with height := top },
      { rect with
        y := rect.y + top, height := rect.height - top })
  | .columns =>
    let left := rect.width / 2
    ({ rect with width := left },
      { rect with
        x := rect.x + left, width := rect.width - left })

/-- The rectangle of each window of the tree laid out in `rect`, in drawing
order. A split halves its rectangle along its axis; a subtree with no window
takes nothing, and its sibling takes all of it. -/
def rects : Split → Rect → Array (ViewId × Rect)
  | .window id, rect => #[(id, rect)]
  | .minibuffer, _ => #[]
  | .split axis first second, rect =>
    if first.windows.isEmpty then second.rects rect
    else
      if second.windows.isEmpty then first.rects rect
      else
        let (one, other) := halve axis rect
        first.rects one ++ second.rects other

/-- The tree without the window `id`, whose sibling takes the place of the
split that held both, and that sibling; `none` when `id` is not a leaf of the
tree or is the whole tree. -/
def remove (id : ViewId) : Split → Option (Split × Split)
  | .window _ | .minibuffer => none
  | .split axis first second =>
    if first == .window id then some (second, second)
    else
      if second == .window id then some (first, first)
      else
        match first.remove id with
        | some (rest, took) => some (.split axis rest second, took)
        | none => (second.remove id).map fun (rest, took) => (.split axis first rest, took)

end Split

namespace EditorState

/-- The window whose view is `id`, if there is one. -/
def window? (state : EditorState) (id : ViewId) : Option Window :=
  state.windows.find? (·.id == id)

/-- The buffer `id` names, if there is one. -/
def buffer? (state : EditorState) (id : BufferId) : Option Buffer :=
  state.buffers[id.index]?

/-- The window whose view is `id` and its buffer: what a handler acting on
that view is given. -/
def target? (state : EditorState) (id : ViewId) : Option Target := do
  let window ← state.window? id
  let buffer ← state.buffer? window.buffer
  return { window, buffer }

/-- The focused window and its buffer. -/
def focusedTarget? (state : EditorState) : Option Target :=
  state.target? state.frame.focused

/-- Whether the state keeps the layout invariants: the focused window is in
the tree, the tree has one minibuffer leaf, its window ids are distinct and
are exactly the windows' ids, and each window's buffer exists. -/
def wellFormed (state : EditorState) : Bool :=
  let ids := state.frame.tree.windows
  ids.contains state.frame.focused && state.frame.tree.minibuffers == 1 &&
    ids.toList.eraseDups.length == ids.size &&
    ids.size == state.windows.size &&
    ids.all (fun id => (state.window? id).isSome) &&
    state.windows.all fun window => (state.buffer? window.buffer).isSome

/-- A buffer called `scratch` over a new empty text, and one window on it,
focused, in a frame of `size` with the minibuffer's place below it. The
window's scroll anchor is at 0, and its selection one exclusive cursor at
0. -/
def initial (size : Size) : TextM EditorState := do
  let text ← createText ""
  let scroll ← text.mark (.anchor { offset := 0, bias := .before })
  let selection ← text.mark (.selection { ranges := #[⟨0, 0⟩], shape := .exclusive })
  let history ← UndoTree.over text
  return {
      buffers := #[{ name := "scratch", text, history }]
      windows := #[{ id := ⟨0⟩, buffer := ⟨0⟩, scroll, selection }]
      frame := { size, tree := .split .rows (.window ⟨0⟩) .minibuffer, focused := ⟨0⟩ } }

/-- Removes the window `id` from the frame: its sibling takes the place of
the split that held both, and the window is handed back, its markers the
caller's to give up. A focused window's focus moves to the first window of
what took its place, or of the tree when that has none. Refused, with the
state unchanged, with `noSuchWindow` for a window not in the tree and with
`onlyWindow` for the last one. -/
def removeWindow (id : ViewId) (state : EditorState) : Except LayoutRefusal Window × EditorState :=
  let tree := state.frame.tree
  match state.window? id, tree.windows.contains id with
  | some window, true =>
    match tree.remove id with
    | some (rest, took) =>
      if rest.windows.isEmpty then (.error .onlyWindow, state)
      else
        let focused :=
          if state.frame.focused == id then
            (took.windows[0]?).getD ((rest.windows[0]?).getD state.frame.focused)
          else state.frame.focused
        (.ok window,
          { state with
            windows := state.windows.filter (·.id != id)
            frame :=
              { state.frame with
                tree := rest, focused } })
    | none => (.error .onlyWindow, state)
  | _, _ => (.error (.noSuchWindow id), state)

/-- Focuses the window `id`. Refused, with the state unchanged, with
`noSuchWindow` for a window not in the tree. -/
def focusWindow (id : ViewId) (state : EditorState) : Except LayoutRefusal Unit × EditorState :=
  if state.frame.tree.windows.contains id then
    (.ok (), { state with frame := { state.frame with focused := id } })
  else (.error (.noSuchWindow id), state)

end EditorState

end Editor
