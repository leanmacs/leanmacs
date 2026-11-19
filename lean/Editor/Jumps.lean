import Editor.Api
import Editor.Marks

/-!
# Jumps: recording and moving through a window's jump list

The decisions about a window's jump list and the places it holds
(`docs/design/keymaps-and-modes.md`, "The jump list and marks"), written
over the editor API: the list's rules are `Editor/JumpList.lean`'s, run on
places of the editor state (`Editor/State.lean`, "The jump list and
marks") whose lines are read from their markers. It names no scheme and no
key: evil's commands (`Editor/Evil/Jumps.lean`, `Editor/Evil/Marks.lean`)
call it, and so do the file commands, since opening a file is a jump.

This is the lower of two modules. It imports the editor API only, so the
file commands (`Editor/Files.lean`) can record a jump; what needs the file
commands, going to a place in a closed file, is the upper module's
(`Editor/Jumps/Go.lean`).

- **A place is marked where the cursor is** (`here`): a place's marker
  (`Marks.placeMarker`, an anchor with the bias `after`) at the head of
  the primary range of the window's selection.
- **Record** (`record`, Vim's `setpcmark`): the place is the window's
  previous-context mark and the list's last entry (`JumpList.record`).
- **Move by `n`** (`plan`): the list is cleaned up first (`cleanup`), by
  each entry's buffer, or file, and the line its marker is on now
  (`lineKey`), so entries edits brought onto one line are one; then the
  step's plan (`JumpList.plan`) records the cursor's place first when the
  index is one past the end, and the window keeps the list with its new
  index. It hands back the place to go to, or `none` when the step fails,
  with the clean-up kept, as Vim keeps it.
- **Going to a held place** (`goHeld`): in the window's own buffer the
  cursor is put on the place; in another, the window shows that buffer
  first. With `line`, the cursor goes to the first non-blank of the place's
  line.
- **Detach** (`detach`): before a buffer is closed, every place held in it,
  in every window's jumps and in the global marks, becomes a place in its
  file, with its row and its column in characters; a buffer with no file
  has its places dropped. Its own marks go with it.
- **Erase rows** (`eraseRows`, Vim's `del_lines`, which runs
  `mark_adjust` with `MAXLNUM` over the lines it deletes): a command that
  deletes whole lines erases the buffer's lowercase marks on them, the
  rows read before the edit. Global marks stay, as Vim's do: their markers
  go to where the deletion left them. The linewise delete and change call
  it (`Editor/Evil/Operators.lean`), since the edit alone does not say
  which lines they delete (`Editor/Marks.lean`, "A mark's line is erased
  when its line is deleted").
- **Renew a row** (`renewRow`): a command that empties a line it keeps,
  as the linewise change keeps its first line (Vim's `op_change`
  truncates it), holds the buffer's lowercase marks on it by new place
  markers where their markers are, after its edit. The loop erases a mark
  by the line its marker was read on (`Editor/Marks/Follow.lean`), and a
  marker set since was read on none, so the edit cannot erase the marks,
  though it is `dd`'s in shape when the lines after the first end with an
  empty one. The linewise change calls it (`Editor/Evil/Operators.lean`).
- **Attach** (`attach`): once a buffer holds a file, the places of that
  file become places held by markers of its text again, at their row and
  column, clamped as a visit clamps (`Marks.offsetAt`).

Pinned by `ModelTest.jumpChecks`; the moves that go to another buffer or a
file by `ModelTest.jumpGoChecks`.
-/

namespace Editor.Jumps

/-- Erases the lowercase marks of the buffer `id` that are on its rows
`first` through `last` ("Erase rows", in the module docs). Nothing for a
buffer that is not there. -/
def eraseRows (id : BufferId) (first last : Nat) : EditorM Unit := do
  let some buffer := (← editorState).buffer? id | return
  for (char, marker) in buffer.marks do
    let row := (← buffer.text.pointOf (← Marks.offsetOf marker)).row
    if first ≤ row && row ≤ last then
      discard <| id.setMark char none

/-- Holds each lowercase mark of the buffer `id` on its row `row` by a new
place marker where its marker is ("Renew a row", in the module docs).
Nothing for a buffer that is not there. -/
def renewRow (id : BufferId) (row : Nat) : EditorM Unit := do
  let some buffer := (← editorState).buffer? id | return
  for (char, marker) in buffer.marks do
    let offset ← Marks.offsetOf marker
    if (← buffer.text.pointOf offset).row == row then
      discard <| id.setMark char (some (← Marks.placeMarker buffer.text offset))

/-- The place of the cursor of `view`: a marker at the head of the primary
range of its window's selection. `none` for a view with no window. -/
def here (view : ViewId) : EditorM (Option Place) := do
  let some target := (← editorState).target? view | return none
  let selection ← target.selection
  let some range := selection.ranges[selection.primary]? | return none
  return some (.held target.window.buffer (← Marks.placeMarker target.buffer.text range.head))

/-- Records a jump in `view` (Vim's `setpcmark`): the cursor's place is its
previous-context mark and the last entry of its list, the oldest dropped
past the limit, and the index one past the end. Nothing for a view with no
window. -/
def record (view : ViewId) : EditorM Unit := do
  let some window := (← editorState).window? view | return
  let some place ← here view | return
  discard <| view.setJumps { list := window.jumps.list.record place, previous := some place }

/-- What a clean-up compares two entries by: their buffer, or file. -/
inductive Owner where
  /-- A place held in this buffer. -/
  | buffer (id : BufferId)
  /-- A place in this file. -/
  | file (path : System.FilePath)
  deriving DecidableEq, Repr

/-- What the clean-up keys `place` by: its buffer or file, and the row it is
on now, read from its marker. -/
def lineKey (place : Place) : TextM (Owner × Nat) := do
  match place with
  | .held buffer marker =>
    return (.buffer buffer, (← marker.text.pointOf (← Marks.offsetOf marker)).row)
  | .file path row _ =>
    return (.file path, row)

/-- `list` cleaned up (`JumpList.cleanup`) by the line each entry is on now
(`lineKey`). -/
def cleanup (list : JumpList Place) : TextM (JumpList Place) := do
  let keyed ← list.entries.mapM fun place => return (place, ← lineKey place)
  let cleaned :=
    ({ entries := keyed, index := list.index } : JumpList (Place × Owner × Nat)).cleanup (·.2)
  return { entries := cleaned.entries.map (·.1), index := cleaned.index }

/-- A step by `n` of the jump list of `view` ("Move by `n`", in the module
docs): the list cleaned up, the cursor's place recorded first when the
index is one past the end, the window keeping the list with its new index,
and the place to go to. `none` when the step fails, with the clean-up
kept, and for a view with no window. -/
def plan (view : ViewId) (n : Int) : EditorM (Option Place) := do
  let some window := (← editorState).window? view | return none
  let cleaned ← cleanup window.jumps.list
  let some step := cleaned.plan n |
    do
      discard <| view.setJumps { window.jumps with list := cleaned }
      return none
  let (list, previous) ←
    if step.recordFirst then
      match ← here view with
      | some place =>
        pure (cleaned.apply step place, some place)
      | none =>
        return none
    else
      pure ({ cleaned with index := step.index }, window.jumps.previous)
  discard <| view.setJumps { list, previous }
  return list.entries[step.index]?

/-- Puts the cursor of `view` on the place held by `marker` in `buffer`,
showing `buffer` in the window first when it shows another; with `line`, on
the first non-blank of the place's line. Nothing when the window cannot
show the buffer. -/
def goHeld (view : ViewId) (buffer : BufferId) (marker : MarkerId) (line : Bool) : EditorM Unit :=
  do
  let some window := (← editorState).window? view | return
  if window.buffer != buffer then
    let .ok () ← view.show buffer | return
  let offset ← Marks.offsetOf marker
  let offset ←
    if line then
      marker.text.motion .lineFirstNonBlank offset
    else
      pure offset
  if let .ok selection← view.selection then
    discard <|
        view.select
          { selection with
            ranges := #[⟨offset, offset⟩], primary := 0 }

/-- Detaches the places held in the buffer `id` ("Detach", in the module
docs): in every window's jumps and in the global marks, each becomes a
place in the buffer's file at its row and column, or is dropped when the
buffer has no file. Called before the buffer is closed. -/
def detach (id : BufferId) : EditorM Unit := do
  let state ← editorState
  let some closing := state.buffer? id | return
  let heldIn (place : Place) : Option MarkerId :=
    match place with
    | .held buffer marker => if buffer == id then some marker else none
    | .file .. => none
  let places := state.windows.flatMap (·.jumps.places) ++ state.remembered.globalMarks.map (·.2)
  let markers :=
    (places.filterMap heldIn).foldl (fun once m => if once.contains m then once else once.push m)
      #[]
  let detached : Array (MarkerId × Option Place) ←
    markers.mapM fun marker => do
        match closing.file with
        | none =>
          return (marker, none)
        | some file =>
          let (row, column) ← Marks.pointAt marker.text (← Marks.offsetOf marker)
          return (marker, some (.file file.path row column))
  let change (place : Place) : Option Place :=
    match heldIn place with
    | some marker => (detached.find? (·.1 == marker)).bind (·.2)
    | none => some place
  for window in state.windows do
    if window.jumps.places.any (heldIn · |>.isSome) then
      discard <| window.id.setJumps (window.jumps.filterMap change)
  for (char, place) in state.remembered.globalMarks do
    if (heldIn place).isSome then
      discard <| setGlobalMark char (change place)

/-- Attaches the places of the file at `path` to the buffer `id`, which
holds it ("Attach", in the module docs): in every window's jumps and in
the global marks, each becomes a place held by a marker of the buffer's
text, one marker for each row and column. -/
def attach (id : BufferId) (path : System.FilePath) : EditorM Unit := do
  let state ← editorState
  let some opened := state.buffer? id | return
  let inFile (place : Place) : Option (Nat × Nat) :=
    match place with
    | .file at_ row column => if at_ == path then some (row, column) else none
    | .held .. => none
  let places := state.windows.flatMap (·.jumps.places) ++ state.remembered.globalMarks.map (·.2)
  let points :=
    (places.filterMap inFile).foldl (fun once p => if once.contains p then once else once.push p)
      #[]
  if points.isEmpty then
    return
  let attached : Array ((Nat × Nat) × MarkerId) ←
    points.mapM fun (row, column) => do
        return ((row, column),
            ← Marks.placeMarker opened.text (← Marks.offsetAt opened.text row column))
  let change (place : Place) : Option Place :=
    match inFile place with
    | some point => (attached.find? (·.1 == point)).map fun (_, marker) => .held id marker
    | none => some place
  for window in state.windows do
    if window.jumps.places.any (inFile · |>.isSome) then
      discard <| window.id.setJumps (window.jumps.filterMap change)
  for (char, place) in state.remembered.globalMarks do
    if (inFile place).isSome then
      discard <| setGlobalMark char (change place)

end Editor.Jumps
