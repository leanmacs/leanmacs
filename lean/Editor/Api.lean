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

end ViewId

end Editor
