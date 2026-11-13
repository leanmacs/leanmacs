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
2. **The scene** (`Loop.views`, `Loop.scene`). Each window in the tree, in
   drawing order, is a view in the rectangle `Split.rects` gives it in the
   frame. A view
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

## When publishing is refused

Publishing asks the store too: each buffer's text for its revision, a text
that changed for a snapshot, and the store to release the snapshots the
last scene named. Each is refused once the text or the snapshot is gone,
and a command can release either: their ids are plain indices. The cause
that refuses a handler (the focused buffer's text was released) refuses
these as well, so a publish that failed with them would lose the echo the
handler's refusal had just written.

`Loop.publish` is therefore not refused by any of them, and neither is
`Loop.step`: a scene is published after the event all the same.

- **A buffer whose text refuses keeps its history as it was.** The other
  buffers' histories are recorded.
- **A view whose buffer's text refuses is left out of the scene**, and
  nothing is taken for it. The other views keep their rectangles, so the
  views then do not tile the frame, and the scene names a focused view it
  does not hold when that view is the one left out.
- **The refusal is in the echo area**, as a refused handler's is (`refused: `
  and `TextError.describe`), in the state the loop keeps and in the scene
  it publishes. It is the first refusal of the publish, and it replaces the
  echo a refused handler wrote in the same step.
- **A release that is refused** comes after the scene is published, for a
  snapshot that was released behind the loop. The loop keeps the new
  scene's snapshots all the same, and the refusal is in the echo area of
  the state it returns, so the next scene shows it.

Nothing here touches the layout or the windows: the state the loop keeps is
the one the handler left, with the echo set, and a well-formed state stays
well formed. A host still has to deal with a program of the loop that is
refused, because an `EditorM` can be; none is today, and a host prints one
that is instead of dropping it (`Headless.Running.attempt`).

One case is not seen: a snapshot of the last scene released behind the loop
while its text did not change. The loop asks nothing of a snapshot it
keeps, so nothing is refused, and the scenes go on naming a snapshot that
is gone until the text changes.

These are pinned by `ModelTest.loopChecks`, and through the headless host by
`ConfigTest.scriptChecks`.

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

/-- `state` with `refusal` in the echo area: `refused: ` and what it was. -/
def refused (state : EditorState) (refusal : TextError) : EditorState :=
  { state with echo := s!"refused: {refusal.describe}" }

/-- `state`, with `refusal` in the echo area if there is one. -/
def refusedBy (state : EditorState) : Option TextError → EditorState
  | some refusal => state.refused refusal
  | none => state

/-- Tells each buffer's undo tree the revision its text is at, and closes its
group: what an event edited becomes one step of its history. It is not
refused: a buffer whose text refuses, because it was released, keeps its
history as it was, and the first such refusal is handed back. -/
def recordHistories (state : EditorState) : TextM (EditorState × Option TextError) := do
  let mut buffers := #[]
  let mut refusal := none
  for buffer in state.buffers do
    match ← observing buffer.history.sync with
    | .ok history =>
      buffers := buffers.push { buffer with history := history.close }
    | .error error =>
      buffers := buffers.push buffer
      refusal := refusal <|> some error
  return ({ state with buffers }, refusal)

end EditorState

namespace Loop

/-- A loop over the initial state, in a frame of `size`, with nothing shown
yet. -/
def start (size : Size) : TextM Loop :=
  return { state := ← EditorState.initial size }

/-- How every view's cursors are drawn, until the phases that choose them. -/
def cursor : Cursor :=
  { shape := .bar, face := ⟨"cursor"⟩ }

/-- The views of the loop's state, in drawing order, and the snapshots they
name. A text at the revision it was last shown at keeps its snapshot; any
other is given a new one. It is not refused: a view whose buffer's text
refuses, because it was released, is left out, with nothing taken for it,
and the first such refusal is handed back. -/
def views (loop : Loop) : TextM (Array View × Array Shown × Option TextError) := do
  let state := loop.state
  let frame := state.frame
  let mut shown : Array Shown := #[]
  let mut views : Array View := #[]
  let mut refusal := none
  for (id, rect) in
    frame.tree.rects { x := 0, y := 0, width := frame.size.width, height := frame.size.height } do
    let some target := state.target? id | continue
    let text := target.buffer.text
    let taken ←
      observing do
          let revision ← text.revision
          match
            (shown ++ loop.shown).find? fun was => was.text == text && was.revision == revision with
          | some was =>
            pure (revision, was.snapshot)
          | none =>
            return (revision, ← text.snapshot)
    match taken with
    | .error error =>
      refusal := refusal <|> some error
    | .ok (revision, snapshot) =>
      unless shown.any (·.text == text) do
        shown := shown.push { text, revision, snapshot }
      views :=
        views.push
          { id, rect, snapshot, scroll := target.window.scroll,
            selections := #[target.window.selection]
            cursor, decorations := #[], status := #[] }
  return (views, shown, refusal)

/-- The scene of `state` over `views`: what the state says of the frame, the
echo area and the preedit, around the views made of its windows. -/
def scene (state : EditorState) (views : Array View) : Scene :=
  let frame := state.frame
  { size := frame.size, views, focused := if frame.hasFocus then some frame.focused else none
    echo := state.echo, pending := "", preedit := state.preedit }

/-- Records the histories, publishes a scene of the state, and releases each
snapshot the last scene named that this one does not. It is not refused
("When publishing is refused", in the module docs): a refusal of a buffer's
text is in the echo area of the scene it publishes, and one of a release in
the echo area of the state it returns. -/
def publish (loop : Loop) : EditorM Loop := do
  let (state, unrecorded) ← loop.state.recordHistories
  let (views, shown, unshown) ← ({ loop with state } : Loop).views
  let state := state.refusedBy (unrecorded <|> unshown)
  Display.publish (scene state views)
  let mut unreleased := none
  for was in loop.shown do
    unless shown.any (·.snapshot == was.snapshot) do
      if let .error error← (observing was.snapshot.release : TextM (Except TextError Unit)) then
        unreleased := unreleased <|> some error
  return { state := state.refusedBy unreleased, shown }

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
refusal in the echo area. The step itself is not refused: the publish puts
a refusal of its own in the echo area too ("When publishing is refused", in
the module docs). -/
def step (loop : Loop) (event : Event) : EditorM (Loop × Next) := do
  match event with
  | .closeRequested | .quit =>
    return (loop, .stop)
  | _ =>
    let state ←
      try
        handle loop.state event
      catch refusal =>
        pure (loop.state.refused refusal)
    return (← { loop with state }.publish, .continue)

end Loop

end Editor
