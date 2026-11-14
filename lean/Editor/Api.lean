import Editor.Command

/-!
# The editor API

The operations a command is written with, beyond the text port's own
(`Editor/Text.lean`): each is a program over the editor's port (`EditorM`,
`Editor/Command.lean`) made of state requests (`Editor/State/Request.lean`)
and text requests. `Editor.lean` imports this module, so config sees them.

## Asking the state

- `EditorState.ask request` makes one state request and returns its reply.
- `editorState` reads the whole state. A question is a pure function over
  it (`EditorState.buffer?`, `target?`, `findBuffer`, `value?`,
  `frame.focused`), so a command reads once and asks as much as it likes.

A reply that can be refused is a value, an `Except` of the operation's
refusal, which the command matches on: nothing here throws a refusal of the
state. What the text store refuses is thrown, as everywhere in `EditorM`.

The loop that runs a command answers its state requests
(`Editor/Command/Dispatch.lean`). Run bare, a command finds an editor with
nothing in it.

## Buffers

- `createBuffer name contents` makes a text holding `contents`, empty by
  default, and a buffer of that name over it, with a new undo tree. The
  name is checked against a read of the state first, so a name a buffer
  already has is refused (`nameTaken`) with no text made.
- `addBuffer name text` makes a buffer over a text the command already
  has: one it copied, or took in from a job's snapshot.
- `findBuffer name` is the buffer of that name, if there is one. Names are
  unique, so there is at most one.
- `BufferId.remove` removes a buffer no window shows. Its text is released
  by the loop once the command has run to its end (`Editor/Loop.lean`,
  "What a finished command gave up"), so a command that fails afterwards
  is rolled back whole.
- `BufferId.text` is the buffer's text. Reading a buffer is the text
  port's reads on it (`TextId.read`, `rowContent`, `slice`, `byteLength`
  and the rest of `Editor/Text.lean`): there is no read request of the
  state beside them.

## Edits at positions

Every edit here goes through the text port's `apply`, as one transaction
made by the user (`Origin.user`), so it is one revision, one entry of the
edit log, and one step for the buffer's history to be told of.

- `TextId.replaceRange text start stop s` replaces the bytes of `text`
  from `start` up to, not including, `stop` with `s`
  (`Transaction.replacing`). It is refused as the store refuses a
  transaction that does not fit its text, with `badChange`: an offset
  inside a character or past the end, and a range that ends before it
  starts.
- `BufferId.insertAt` and `BufferId.deleteRange` are that on the buffer's
  text: an insertion replaces an empty range, and a deletion replaces a
  range with nothing.
- Proved on the text model (`replaceRange_insert_delete`,
  `Editor/Api/Theorems.lean`): inserting a string at a character boundary
  and deleting the range it occupies leaves the text's contents as they
  were.

## Selections

A window's selection is a selection marker of its buffer's text
(`Window.selection`), whose ranges are the view's cursors. A command that
was handed its `Target` uses the operations on it, which are programs over
the text port; one that has a view's id uses the operations on `ViewId`,
which read the window from the state first and are refused, as a value,
with `noSuchWindow` for a view with no window.

- `selection` reads the selection, in the form the store keeps one in, and
  `select` places it. A selection the store refuses is thrown
  (`badSelection`).
- `insertAtSelections s` inserts `s` at the head of each range. Each range
  becomes a cursor just after its insertion; the primary and the shape
  are kept.
- `deleteSelections` deletes what each range covers, by the selection's
  shape (`TextId.extents`), and leaves a cursor where each started.
- `Target.replaceSelections s` replaces what each range covers with `s`
  and leaves a cursor after each: what a committed text does
  (`Editor/Loop.lean`).

Each is one transaction made by the user that carries the selection before
and the cursors after, so undoing it hands the selection back
(`replaceExtents`), and the selection marker is then placed at the
cursors. The heads of a kept selection are in order, since its ranges are
sorted and apart, so they are the extents an insertion replaces.

## Undo

The undo operations work over the buffer's own undo tree
(`Buffer.history`, `Editor/UndoTree.lean`), with no new request of the
text store: each reads the buffer, tells the tree the revision its text is
at, does its part, and records the tree that comes back as the buffer's
(`StateRequest.setHistory`).

- `BufferId.closeGroup` sets the boundary: the edits since the last one
  become one step. With nothing pending it makes no node.
- `BufferId.undo` and `BufferId.redo` move one step, with the user's
  origin, and hand back the selection to place (`Undone`): the selection
  before the step's first edit for an undo, and the one after its last for
  a redo. `none` is the tree's "there is nothing to do": an undo at the
  root, a redo with no step to go to or with an edit pending.
- **The selection is handed back, not placed.** Placing it is the
  caller's: which view it belongs to, and what its cursor's shape becomes,
  are the input scheme's to say. The store hands back a selection only for
  an edit that carried one, which the selection edits above do.
- **The loop's boundary still follows.** The loop closes each buffer's
  group after every event (`Editor/Loop.lean`, "After each event"). After a
  command that moved, that tells the moved tree nothing new and makes no
  node, so a move is not itself a step.
- **A command that moves and then fails** is rolled back from the tree it
  recorded: the edits it made after the move are taken back, and the move
  is not (`Editor/Loop.lean`, "Rollback").

## Windows

Each operation is a request over the layout operations of
`Editor/State.lean`, which keep the layout invariants, and is refused, as
a value, with their `LayoutRefusal`.

- `ViewId.split view axis` makes a new window on the same buffer, below
  the view for `Axis.rows` and to its right for `Axis.columns`, and returns
  its view. The new window has markers of its own: copies, marked on the
  buffer's text, of the source window's scroll anchor and selection as
  they are. The focus stays.
- `ViewId.close` removes a window. The last one is refused (`onlyWindow`).
  Closing the view a split made gives back the tree from before the split.
  The window's markers are given up by the loop once the command has run
  to its end (`Editor/Loop.lean`, "What a finished command gave up").
- `ViewId.focus` focuses a window.
- `ViewId.show view buffer` has the window show another buffer, with a
  scroll anchor at that buffer's start and one cursor at its start, of the
  shape the window's selection had. Showing the buffer the window already
  shows changes nothing and marks nothing. The markers the window had are
  given up by the loop, as a closed window's are.

A view's id is never used again (`Editor/State.lean`).

## Buffer-local values and modes

These are Lean state alone: none makes a request of the library, so none
has a case on the real binding. They are pinned once, on the models
(`ModelTest.apiStateChecks`, `ModelTest.modeEnterChecks`).

- `BufferId.setValue id name value` has a buffer keep a plain tree
  (`Value`, `Editor/Value.lean`) under a name, in place of the one the name
  had, and `BufferId.value?` reads it.
- `BufferId.addMinorMode` and `BufferId.removeMinorMode` add and remove a
  minor mode. No action runs.
- `ViewId.setMajorMode view name` makes a mode the major mode of the buffer
  the view shows, and says whether it became it: `false`, with nothing
  run, when the buffer already had it. The loop that runs the command
  refuses a name no mode is registered under (`noSuchMode`) and runs the
  on-enter actions of the mode's lineage, root first, inside the command
  (`Editor/Command/Dispatch.lean`).

Each operation that makes a text request has a case in
`Editor/Api/Cases.lean`, played on the editor's models and on the real
binding.
-/

namespace Editor

/-- Makes one request of the editor state and returns its reply. It is never
refused: a reply that can be is an `Except`, a value. -/
def EditorState.ask (request : StateRequest) : EditorM request.Reply :=
  ExceptT.lift (Program.request (port := editorPort) (.state request))

/-- The whole editor state, as it is now. -/
def editorState : EditorM EditorState :=
  EditorState.ask .read

/-- Replaces the bytes of `text` from `start` up to, not including, `stop`
with `s`, as one transaction made by the user. Refused, changing nothing,
with `badChange` unless both offsets are character boundaries within the
text and `start ≤ stop`. -/
def TextId.replaceRange (text : TextId) (start stop : Nat) (s : String) : TextM Unit := do
  let length ← text.byteLength
  let _ ← text.apply (Transaction.replacing length start stop s) Origin.user
  return ()

/-- The buffer called `name`, if there is one. -/
def findBuffer (name : String) : EditorM (Option BufferId) :=
  return (← editorState).findBuffer name

/-- Makes a buffer called `name` over `text`, a text the command already
has, with a new undo tree over it, and returns its id. Refused with
`nameTaken` for a name a buffer already has. -/
def addBuffer (name : String) (text : TextId) : EditorM (Except BufferRefusal BufferId) := do
  EditorState.ask (.addBuffer name text (← UndoTree.over text))

/-- Makes a buffer called `name` over a new text holding `contents`, and
returns its id. Refused with `nameTaken` for a name a buffer already has,
with no text made. -/
def createBuffer (name : String) (contents : String := "") :
    EditorM (Except BufferRefusal BufferId) := do
  if (← findBuffer name).isSome then
    return .error (.nameTaken name)
  addBuffer name (← createText contents)

namespace BufferId

/-- The text of the buffer `id`. Refused with `noSuchBuffer` for a buffer
there is none of. -/
def text (id : BufferId) : EditorM (Except BufferRefusal TextId) := do
  match (← editorState).buffer? id with
  | some buffer =>
    return .ok buffer.text
  | none =>
    return .error (.noSuchBuffer id)

/-- Removes the buffer `id`. Refused with `noSuchBuffer` for a buffer there
is none of, and with `shown` while a window shows it. -/
def remove (id : BufferId) : EditorM (Except BufferRefusal Unit) :=
  EditorState.ask (.removeBuffer id)

/-- Replaces the bytes of the buffer `id`'s text from `start` up to, not
including, `stop` with `s` (`TextId.replaceRange`). Refused with
`noSuchBuffer` for a buffer there is none of; what the store refuses is
thrown. -/
def replaceRange (id : BufferId) (start stop : Nat) (s : String) :
    EditorM (Except BufferRefusal Unit) := do
  match ← id.text with
  | .ok text =>
    text.replaceRange start stop s
    return .ok ()
  | .error refusal =>
    return .error refusal

/-- Inserts `s` into the buffer `id`'s text at the byte offset `offset`.
Refused with `noSuchBuffer` for a buffer there is none of; the store
refuses, with `badChange`, an offset that is not a character boundary
within the text. -/
def insertAt (id : BufferId) (offset : Nat) (s : String) : EditorM (Except BufferRefusal Unit) :=
  id.replaceRange offset offset s

/-- Deletes the bytes of the buffer `id`'s text from `start` up to, not
including, `stop`. Refused with `noSuchBuffer` for a buffer there is none
of; the store refuses, with `badChange`, offsets that are not character
boundaries within the text and a range that ends before it starts. -/
def deleteRange (id : BufferId) (start stop : Nat) : EditorM (Except BufferRefusal Unit) :=
  id.replaceRange start stop ""

end BufferId

/-- What an undo or a redo hands back. -/
structure Undone where
  /-- The selection to place: the one before the step's first edit for an
  undo, and the one after its last for a redo. `none` when the step's edits
  carried none. -/
  selection : Option Selection
  deriving DecidableEq, Repr

namespace BufferId

/-- The buffer `id` with its undo tree told the revision its text is at.
Refused with `noSuchBuffer` for a buffer there is none of. -/
def synced (id : BufferId) : EditorM (Except BufferRefusal Buffer) := do
  match (← editorState).buffer? id with
  | some buffer =>
    return .ok { buffer with history := ← buffer.history.sync }
  | none =>
    return .error (.noSuchBuffer id)

/-- Sets the boundary in the buffer `id`'s history: the edits since the last
one become one step. With nothing pending it makes no node. Refused with
`noSuchBuffer` for a buffer there is none of. -/
def closeGroup (id : BufferId) : EditorM (Except BufferRefusal Unit) := do
  match ← id.synced with
  | .ok buffer =>
    EditorState.ask (.setHistory id buffer.history.close)
  | .error refusal =>
    return .error refusal

/-- Makes `move` in the buffer `id`'s history, on its tree once told the
revision its text is at, and records the tree the move returns as the
buffer's: what the move handed back, or `none` when the tree had nothing
to do. Refused with `noSuchBuffer` for a buffer there is none of. -/
def moved (id : BufferId) (move : UndoTree → TextM (Option UndoTree.Moved)) :
    EditorM (Except BufferRefusal (Option Undone)) := do
  match ← id.synced with
  | .error refusal =>
    return .error refusal
  | .ok buffer =>
    let some moved ← move buffer.history | return .ok none
    match ← EditorState.ask (.setHistory id moved.tree) with
    | .ok () =>
      return .ok (some ⟨moved.selection⟩)
    | .error refusal =>
      return .error refusal

/-- Undoes one step of the buffer `id`'s history, with the user's origin,
and hands back the selection from before the step's first edit. The open
group is a step: it is closed first. `none`, with nothing done, when there
is no step to undo. Refused with `noSuchBuffer` for a buffer there is none
of. -/
def undo (id : BufferId) : EditorM (Except BufferRefusal (Option Undone)) :=
  id.moved (·.undo Origin.user)

/-- Redoes one step of the buffer `id`'s history, with the user's origin,
and hands back the selection from after the step's last edit. `none`, with
nothing done, when there is no step to redo, and whenever an edit is
pending. Refused with `noSuchBuffer` for a buffer there is none of. -/
def redo (id : BufferId) : EditorM (Except BufferRefusal (Option Undone)) :=
  id.moved (·.redo Origin.user)

/-- Has the buffer `id` keep `value` under `name`, in place of the value the
name had. Refused with `noSuchBuffer` for a buffer there is none of. -/
def setValue (id : BufferId) (name : String) (value : Value) :
    EditorM (Except BufferRefusal Unit) :=
  EditorState.ask (.setValue id name value)

/-- The value the buffer `id` keeps under `name`, if it keeps one. -/
def value? (id : BufferId) (name : String) : EditorM (Option Value) :=
  return (← editorState).value? id name

/-- Adds the minor mode called `name` to the buffer `id`, first; one it has
already changes nothing. Refused with `noSuchBuffer` for a buffer there is
none of. -/
def addMinorMode (id : BufferId) (name : String) : EditorM (Except BufferRefusal Unit) :=
  EditorState.ask (.addMinorMode id name)

/-- Removes the minor mode called `name` from the buffer `id`; one it does
not have changes nothing. Refused with `noSuchBuffer` for a buffer there is
none of. -/
def removeMinorMode (id : BufferId) (name : String) : EditorM (Except BufferRefusal Unit) :=
  EditorState.ask (.removeMinorMode id name)

end BufferId

/-- The changes that replace each of `extents`, sorted and apart, of a text
of `length` bytes, with `text`, and the cursor after each insertion. -/
def replacingEach (length : Nat) (extents : Array Extent) (text : String) :
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

namespace Target

/-- The selection of `target`'s window, in the form the store keeps one in.
Refused with `noSuchMarker` when the window's selection marker was given
up. -/
def selection (target : Target) : TextM Selection := do
  let .selection selection ← target.buffer.text.marker target.window.selection | throw .noSuchMarker
  return selection

/-- Places `selection` as the selection of `target`'s window. Refused as the
store refuses a selection: with `badSelection` for one that is none or has
an end that is not a position of the text. -/
def select (target : Target) (selection : Selection) : TextM Unit :=
  target.buffer.text.place target.window.selection (.selection selection)

/-- Replaces each of `extents`, sorted and apart, of `target`'s text with
`s`, as one transaction made by the user, which carries `before` and the
cursors after, one after each insertion, with `before`'s shape, and places
the window's selection at those cursors. -/
def replaceExtents (target : Target) (before : Selection) (extents : Array Extent) (s : String) :
    TextM Unit := do
  let text := target.buffer.text
  let (changes, cursors) := replacingEach (← text.byteLength) extents s
  let after : Selection :=
    { ranges := cursors, primary := min before.primary (cursors.size - 1), shape := before.shape }
  let _ ← text.apply { changes, before := some before, after := some after } Origin.user
  target.select after

/-- Replaces what each range of `target`'s selection covers with `s`, as one
transaction made by the user, and leaves a cursor after each insertion. -/
def replaceSelections (target : Target) (s : String) : TextM Unit := do
  let selection ← target.selection
  target.replaceExtents selection (← target.buffer.text.extents selection) s

/-- Inserts `s` at the head of each range of `target`'s selection, as one
transaction made by the user, and leaves a cursor just after each
insertion. -/
def insertAtSelections (target : Target) (s : String) : TextM Unit := do
  let selection ← target.selection
  target.replaceExtents selection (selection.ranges.map fun range => ⟨range.head, range.head⟩) s

/-- Deletes what each range of `target`'s selection covers, as one
transaction made by the user, and leaves a cursor where each started. -/
def deleteSelections (target : Target) : TextM Unit :=
  target.replaceSelections ""

end Target

namespace ViewId

/-- The window of `view` and its buffer. Refused with `noSuchWindow` for a
view with no window. -/
def target (view : ViewId) : EditorM (Except LayoutRefusal Target) := do
  match (← editorState).target? view with
  | some target =>
    return .ok target
  | none =>
    return .error (.noSuchWindow view)

/-- Runs `run` on the window of `view` and its buffer. Refused with
`noSuchWindow` for a view with no window; what the store refuses is
thrown. -/
def onTarget {α : Type} (view : ViewId) (run : Target → TextM α) :
    EditorM (Except LayoutRefusal α) := do
  match ← view.target with
  | .ok target =>
    return .ok (← run target)
  | .error refusal =>
    return .error refusal

/-- The selection of the window of `view` (`Target.selection`). -/
def selection (view : ViewId) : EditorM (Except LayoutRefusal Selection) :=
  view.onTarget (·.selection)

/-- Places `selection` as the selection of the window of `view`
(`Target.select`). -/
def select (view : ViewId) (selection : Selection) : EditorM (Except LayoutRefusal Unit) :=
  view.onTarget (·.select selection)

/-- Inserts `s` at the head of each range of the selection of the window of
`view` (`Target.insertAtSelections`). -/
def insertAtSelections (view : ViewId) (s : String) : EditorM (Except LayoutRefusal Unit) :=
  view.onTarget (·.insertAtSelections s)

/-- Deletes what each range of the selection of the window of `view` covers
(`Target.deleteSelections`). -/
def deleteSelections (view : ViewId) : EditorM (Except LayoutRefusal Unit) :=
  view.onTarget (·.deleteSelections)

/-- Splits the window of `view` along `axis`: a new window on the same
buffer, below it for rows and to its right for columns, whose markers are
copies of the window's scroll anchor and selection as they are, and returns
the new view. The focus stays. Refused with `noSuchWindow` for a view with
no window. -/
def split (view : ViewId) (axis : Axis) : EditorM (Except LayoutRefusal ViewId) := do
  match ← view.target with
  | .error refusal =>
    return .error refusal
  | .ok target =>
    let text := target.buffer.text
    let scroll ← text.mark (← text.marker target.window.scroll)
    let selection ← text.mark (← text.marker target.window.selection)
    EditorState.ask (.split view axis scroll selection)

/-- Closes the window of `view`: its sibling takes the place of the split
that held both. Refused with `noSuchWindow` for a view with no window, and
with `onlyWindow` for the last window. -/
def close (view : ViewId) : EditorM (Except LayoutRefusal Unit) :=
  return (← EditorState.ask (.removeWindow view)).map fun _ => ()

/-- Focuses the window of `view`. Refused with `noSuchWindow` for a view
with no window. -/
def focus (view : ViewId) : EditorM (Except LayoutRefusal Unit) :=
  EditorState.ask (.focus view)

/-- Has the window of `view` show the buffer `buffer`, with a scroll anchor
at its start and one cursor at its start, of the shape the window's
selection had. Showing the buffer the window shows already changes nothing
and marks nothing. Refused with `noSuchWindow` for a view with no window,
and with `noSuchBuffer` for a buffer there is none of. -/
def «show» (view : ViewId) (buffer : BufferId) : EditorM (Except LayoutRefusal Unit) := do
  let state ← editorState
  let some target := state.target? view | return .error (.noSuchWindow view)
  if target.window.buffer == buffer then
    return .ok ()
  let some shown := state.buffer? buffer | return .error (.noSuchBuffer buffer)
  let shape := (← target.selection).shape
  let scroll ← shown.text.mark (.anchor { offset := 0, bias := .before })
  let selection ← shown.text.mark (.selection { ranges := #[⟨0, 0⟩], shape })
  EditorState.ask (.show view buffer scroll selection)

/-- Makes the mode called `name` the major mode of the buffer the window of
`view` shows, and says whether it became the major mode: `false`, with
nothing run, when the buffer already had it. When it became it, the
on-enter actions of the mode's lineage have run, root first, before this
returns. Refused with `noSuchWindow` for a view with no window, and with
`noSuchMode` for a name no mode is registered under. -/
def setMajorMode (view : ViewId) (name : String) : EditorM (Except ModeRefusal Bool) :=
  EditorState.ask (.setMajorMode view name)

end ViewId

end Editor
