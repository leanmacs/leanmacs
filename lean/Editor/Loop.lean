import Editor.Command
import Editor.Event
import Editor.State

/-!
# The command loop

Events go in, the state changes, a scene comes out. `Loop.step` takes the
loop (the editor state and what the last scene showed) and one event,
handles it (`Loop.handle`), and publishes a scene of the state after it
(`Loop.publish`). It is pure: a command (`EditorM`) over the editor's
composite port, so the same loop runs on the models in `model-test` and
against the Rust library in the headless host, which pulls the events and
hands each to it.

## What each event does

| Event | What it does to the state |
|---|---|
| `commit text` | Replaces what each range of the focused window's selection covers with `text`, as one transaction with the user's origin, and clears the preedit |
| `preedit text` | Sets the preedit to `text`; an empty one clears it |
| `compositionDisabled` | Clears the preedit |
| `resize` | Sets the frame's size; the views are laid out in it when the scene is made. Its scale is not kept: the scene has no field for it |
| `focus gained` | Sets whether the frame has the keyboard focus |
| `closeRequested`, `quit` | Nothing: the step says stop, and publishes nothing |
| a key, a pointer, `windowOpened`, `compositionEnabled`, a message, a completion | Nothing. A key is decoded and dropped until key lookup (the command loop's phase 6) |

A handler is given what it acts on (a `Target`: the window and its buffer),
never "the current buffer". When one is refused, the state stays as it was
and the echo area reads `refused: ` and the refusal (`TextError.describe`).
Nothing rolls back what the store accepted before the refusal: rollback is
the command loop's phase 6.

## After each event

Every event but `closeRequested` and `quit` publishes a scene, whether it
changed the state or not (`Loop.publish`):

1. **The histories.** Each buffer's undo tree is told the revision its text
   is at, and its group is closed (`EditorState.recordHistories`): what an
   event edited is one step of the history.
2. **The scene** (`Loop.scene`). Each window in the tree, in drawing order,
   is a view in the rectangle `Split.rects` gives it in the frame. A view
   whose buffer's text is at the revision it was last shown at keeps the
   same snapshot; otherwise a new snapshot is taken, and views of one
   buffer share it. A view's scroll anchor and selection are its window's
   markers, its cursor a bar in the face `cursor`, with no decorations and
   an empty status line: later phases choose those. The focused view is
   named only while the frame has the keyboard focus. The pending prefix is
   empty: key lookup is phase 6.
3. **Publish** it through the display port.
4. **Release** each snapshot the previous scene named that this one does
   not. So a scene's handles are alive while it is the last one published,
   and a real binding resolves them when it is published.

Every edit the loop makes for an input event carries `Origin.user`.

## Where a new event handler goes

A new event is handled by a case of `Loop.handle`, which hands a handler of
its own the `Target` it acts on (`EditorState.focusedTarget?`, or the window
the event names) and the state. Its effect on the state and on the scene is
pinned by a check in `ModelTest.loopChecks`, on the models.

The known gap: no view scrolls to follow its cursor in this phase (phase
15).
-/

namespace Editor

/-- What a view showed: a buffer's text, the revision it was at, and the
snapshot taken of it then. -/
structure Loop.Shown where
  /-- The text. -/
  text : TextId
  /-- Its revision when the snapshot was taken. -/
  revision : Nat
  /-- The snapshot. -/
  snapshot : SnapshotId
  deriving DecidableEq, Repr

/-- The loop's own state: the editor state, and the snapshots the last scene
named. -/
structure Loop where
  /-- The editor state. -/
  state : EditorState
  /-- The snapshots the last scene published named, one a text. -/
  shown : Array Loop.Shown := #[]
  deriving BEq, Repr

/-- What the loop does after a step. -/
inductive Loop.Next where
  /-- Pull the next event. -/
  | continue
  /-- End: the window was asked to close, or the queue was quit. -/
  | stop
  deriving DecidableEq, Repr

namespace EditorState

/-- Tells each buffer's undo tree the revision its text is at, and closes its
group: what an event edited becomes one step of its history. -/
def recordHistories (state : EditorState) : TextM EditorState := do
  let buffers ←
    state.buffers.mapM fun buffer => do
        return { buffer with history := (← buffer.history.sync).close }
  return { state with buffers }

end EditorState

namespace Loop

/-- A loop over the initial state, in a frame of `size`, with nothing shown
yet. -/
def start (size : Size) : TextM Loop :=
  return { state := ← EditorState.initial size }

/-- How every view's cursors are drawn, until the phases that choose them. -/
def cursor : Cursor :=
  { shape := .bar, face := ⟨"cursor"⟩ }

/-- The scene of the loop's state, and the snapshots it names. A text at the
revision it was last shown at keeps its snapshot; any other is given a new
one. -/
def scene (loop : Loop) : TextM (Scene × Array Shown) := do
  let state := loop.state
  let frame := state.frame
  let mut shown : Array Shown := #[]
  let mut views : Array View := #[]
  for (id, rect) in
    frame.tree.rects { x := 0, y := 0, width := frame.size.width, height := frame.size.height } do
    let some target := state.target? id | continue
    let text := target.buffer.text
    let revision ← text.revision
    let snapshot ←
      match (shown ++ loop.shown).find? fun was => was.text == text && was.revision == revision with
      | some was =>
        pure was.snapshot
      | none =>
        text.snapshot
    unless shown.any (·.text == text) do
      shown := shown.push { text, revision, snapshot }
    views :=
      views.push
        { id, rect, snapshot, scroll := target.window.scroll,
          selections := #[target.window.selection]
          cursor, decorations := #[], status := #[] }
  let scene : Scene :=
    { size := frame.size, views, focused := if frame.hasFocus then some frame.focused else none
      echo := state.echo, pending := "", preedit := state.preedit }
  return (scene, shown)

/-- Records the histories, publishes a scene of the state, and releases each
snapshot the last scene named that this one does not. -/
def publish (loop : Loop) : EditorM Loop := do
  let state ← loop.state.recordHistories
  let (scene, shown) ← ({ loop with state } : Loop).scene
  Display.publish scene
  for was in loop.shown do
    unless shown.any (·.snapshot == was.snapshot) do
      was.snapshot.release
  return { state, shown }

/-- The changes that replace each of `extents`, sorted and apart, of a text
of `length` bytes, with `text`, and the cursor after each insertion. -/
def replacing (length : Nat) (extents : Array Extent) (text : String) :
    Array Change × Array SelectionRange :=
  Id.run do
    let mut changes := #[]
    let mut cursors := #[]
    let mut walked := 0
    let mut shift : Int := 0
    for extent in extents do
      changes :=
        changes ++
          #[.retain (extent.start - walked), .delete (extent.stop - extent.start), .insert text]
      let after := (extent.start + shift + text.utf8ByteSize).toNat
      cursors := cursors.push ⟨after, after⟩
      shift := shift + text.utf8ByteSize - (extent.stop - extent.start)
      walked := extent.stop
    return (changes.push (.retain (length - walked)), cursors)

/-- Replaces what each range of `target`'s selection covers with `text`, as
one transaction with the user's origin, which carries the selection before
and the cursors after, and places the selection at those cursors. Refused
with `noSuchMarker` when the window's selection marker was given up. -/
def insert (target : Target) (text : String) : TextM Unit := do
  let buffer := target.buffer.text
  let .selection selection ← buffer.marker target.window.selection | throw .noSuchMarker
  let extents ← buffer.extents selection
  let (changes, cursors) := replacing (← buffer.byteLength) extents text
  let after : Selection :=
    { ranges := cursors, primary := min selection.primary (cursors.size - 1),
      shape := selection.shape }
  discard <| buffer.apply { changes, before := some selection, after := some after } Origin.user
  buffer.place target.window.selection (.selection after)

/-- What `event` does to `state` ("What each event does", in the module
docs). -/
def handle (state : EditorState) : Event → EditorM EditorState
  | .preedit text => return { state with preedit := if text.isEmpty then none else some text }
  | .compositionDisabled => return { state with preedit := none }
  | .resize resize =>
    return { state with frame := { state.frame with size := ⟨resize.width, resize.height⟩ } }
  | .focus gained => return { state with frame := { state.frame with hasFocus := gained } }
  | .commit text => do
    let some target := state.focusedTarget? | return { state with preedit := none }
    insert target text
    return { state with preedit := none }
  | _ => return state

/-- Handles `event` and publishes a scene of the state after it, and says
whether to go on. A close request and a quit stop the loop and publish
nothing. A handler that is refused leaves the state as it was, with the
refusal in the echo area. -/
def step (loop : Loop) (event : Event) : EditorM (Loop × Next) := do
  match event with
  | .closeRequested | .quit =>
    return (loop, .stop)
  | _ =>
    let state ←
      try
        handle loop.state event
      catch refusal =>
        pure { loop.state with echo := s!"refused: {refusal.describe}" }
    return (← { loop with state }.publish, .continue)

end Loop

end Editor
