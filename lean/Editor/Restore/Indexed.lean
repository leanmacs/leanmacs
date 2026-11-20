import Editor.Restore.Records
import Editor.State

/-!
# What of the state the session index keeps

Which buffers the session index keeps (`indexed`) and which of them are
journalled (`journalled`), and how a position of a text is recorded and put
back (`spotOf`, `offsetOf`) and a window's jump list recorded (`jumpsOf`).
They read the state and the text store, so they cannot be in the leaf
module of the records (`Editor/Restore/Records.lean`), and both the frame's
record (`Editor/Restore/Frame.lean`) and the reconciler
(`Editor/Restore.lean`) need them, so they are here, a module the two
import: the frame's record and the index are rendered by one rule of which
buffers are kept.

Pinned by `ModelTest.journalReconcileChecks`, `ModelTest.restoreOffsetChecks`
and `ModelTest.restoreChecks`.
-/

namespace Editor.Restore

/-- Whether the buffer `id` of `state` is journalled ("The journal
reconciler", `Editor/Restore.lean`): a buffer with unsaved text, its history
modified, that holds a file; or that holds none and is neither read-only nor
an excerpt buffer. Never the minibuffer's buffer. -/
def journalled (state : EditorState) (id : BufferId) (buffer : Buffer) : Bool :=
  state.minibufferBuffer? != some id && buffer.excerpts.isNone && buffer.isModified &&
    (buffer.file.isSome || !buffer.readOnly)

/-- Whether the buffer `id` of `state` is kept in the index: it holds a file
and is no excerpt buffer, or it is journalled. -/
def indexed (state : EditorState) (id : BufferId) (buffer : Buffer) : Bool :=
  (buffer.file.isSome && buffer.excerpts.isNone && state.minibufferBuffer? != some id) ||
    journalled state id buffer

/-- Whether the buffer `id` of `state` is there and kept in the index. -/
def indexedId (state : EditorState) (id : BufferId) : Bool :=
  (state.buffer? id).any (indexed state id)

/-- A byte offset of `text` as a spot: its row and its column in bytes. -/
def spotOf (text : TextId) (offset : Nat) : TextM Spot := do
  let point ← text.pointOf offset
  return { row := point.row, column := point.column }

/-- The byte offset of `text` that `spot` records: the start of its row,
clamped to the last row, and its column in bytes, clamped to the row's
content and moved back to the start of the character it falls inside. The
inverse of `spotOf`, which records a column in bytes. -/
def offsetOf (text : TextId) (spot : Spot) : TextM Nat := do
  let row := min spot.row ((← text.lineCount) - 1)
  let content ← text.rowContent row
  let start ← text.offsetOf ⟨row, 0⟩
  let (column, _) :=
    content.toList.foldl
      (fun (bytes, stopped) char =>
        if !stopped && bytes + char.utf8Size ≤ spot.column then (bytes + char.utf8Size, false)
        else (bytes, true))
      (0, false)
  return start + column

/-- A place of a jump list as the index records it: held in a kept buffer,
by the buffer's key and the marker's row and column in characters
(`Marks.pointAt`); held in a buffer that is not kept but holds a file, by
the file's path, as `Jumps.detach` writes it; detached into a file, as it
is. A place held in a buffer neither kept nor holding a file is dropped,
as `Jumps.detach` drops it; so is one whose marker is gone. -/
def jumpOf (state : EditorState) : Editor.Place → TextM (Option Jump)
  | .file path row column => pure (some (.file path.toString row column))
  | .held buffer marker => do
    let some held := state.buffer? buffer | return none
    let .ok offset ← observing (Marks.offsetOf marker) | return none
    let (row, column) ← Marks.pointAt held.text offset
    if indexed state buffer held then
      return some (.kept buffer.index row column)
    return held.file.map fun file => .file file.path.toString row column

/-- A window's jump list and previous-context mark as the index records them
(`jumpOf`), its index moved back past each entry dropped before it; `none`
for a window with neither. -/
def jumpsOf (state : EditorState) (window : Window) : TextM (Option Jumps.Record) := do
  let list := window.jumps.list
  if list.entries.isEmpty && window.jumps.previous.isNone then
    return none
  let mut entries := #[]
  let mut index := 0
  for position in [0:list.entries.size] do
    let some entry := list.entries[position]? | continue
    if let some jump← jumpOf state entry then
      entries := entries.push jump
      if position < list.index then
        index := index + 1
  if list.index ≥ list.entries.size then
    index := entries.size
  let previous ←
    match window.jumps.previous with
    | some place =>
      jumpOf state place
    | none =>
      pure none
  return some { entries, index, previous }

end Editor.Restore
