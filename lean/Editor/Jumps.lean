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
file commands (`packages/files/Files.lean`) can record a jump; what needs the file
commands, going to a place in a closed file, is the upper module's
(`Editor/Jumps/Go.lean`).

- **A place is marked where the cursor is** (`here`): a place's marker
  (`Marks.placeMarker`, an anchor with the bias `after`) at the head of
  the primary range of the window's selection.
- **Record** (`record`, Vim's `setpcmark`): the place is the window's
  previous-context mark and the list's last entry (`JumpList.record`).
- **Check a jump** (`checkPrevious`, Vim's `checkpcmark`): a jump motion
  reads the window's previous-context mark before it records
  (`previousOf`), and once it has moved, a cursor still on the place it
  recorded gives the window that mark back, so `G` on the last line, `gg`
  on the first and `` `a `` with `a` under the cursor leave `''` where it
  was. The list keeps the entry the record appended, as Vim's does. `m'`
  records without a check.
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
- **Placing the cursor** (`placeCursor`, `offsetOn`): one bar at an
  offset, with the selection's shape kept, or at the first non-blank of
  the offset's line. Going to a held place places it so, and so does a
  visit of a file (`Files.placeAt`, `packages/files/Files.lean`), at its point.
- **Detach** (`detach`): before a buffer is closed, every place held in it,
  in every window's jumps and in the global marks, becomes a place in its
  file, with its row and its column in characters; a buffer with no file
  has its places dropped. Its own marks go with it.
- **Delete rows** (`deleteRows`, Vim's `del_lines`, which runs
  `mark_adjust` with `MAXLNUM` over the lines it deletes): a command that
  deletes whole lines decides about the buffer's lowercase marks on them,
  the rows read before the edit, and the edit's shape then decides nothing
  for them (`Editor/Marks.lean`, "A mark's line is erased when its line is
  deleted"). The marks of the rows it deletes are erased. A command that
  keeps the first row, emptied, as the linewise change does (Vim's
  `op_change` truncates it), keeps that row's marks and records their
  markers as decided (`Marks.History.decided`), so the loop does not erase
  them though the edit is `dd`'s in shape when the last line is empty
  (`Editor/Marks/Follow.lean`). Global marks stay on the line, as Vim's
  do: their markers go to where the deletion left them, the line's start,
  where Vim keeps their column (a recorded departure, task
  `global-mark-keeps-column-on-line-delete`). The linewise delete and
  change call it (`Editor/Evil/Operators.lean`).
- **Attach** (`attach`): once a buffer holds a file, the places of that
  file become places held by markers of its text again, at their row and
  column, clamped as a visit clamps (`Marks.offsetAt`).
- **Visiting the source of an excerpt buffer's place** (`visitLocated`, the
  activate key of project search's results and of a working set's
  buffer): the place of an excerpt text is located in its source
  (`TextId.locate`), the jump is recorded, the source's buffer is shown
  and the cursor put at the place; what was not located is said. It needs
  only the editor API, so it is here, below the file commands.

Pinned by `ModelTest.jumpChecks`; the moves that go to another buffer or a
file by `ModelTest.jumpGoChecks`.
-/

namespace Editor.Jumps

/-- Decides the lowercase marks of the buffer `id` that are on its rows
`first` through `last`, which a command deletes whole but for the first
when `keepFirst` ("Delete rows", in the module docs): those of the rows it
deletes are erased, and those of a first row it keeps are recorded as
decided. Nothing for a buffer that is not there. -/
def deleteRows (id : BufferId) (first last : Nat) (keepFirst : Bool := false) : EditorM Unit := do
  let some buffer := (← editorState).buffer? id | return
  let mut decided := buffer.markHistory.decided
  for (char, marker) in buffer.marks do
    let row := (← buffer.text.pointOf (← Marks.offsetOf marker)).row
    if first ≤ row && row ≤ last then
      if keepFirst && row == first then
        decided := decided.push marker
      else
        discard <| id.setMark char none
  unless decided == buffer.markHistory.decided do
    discard <| EditorState.ask (.setMarkHistory id { buffer.markHistory with decided })

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

/-- The previous-context mark of the window of `view`, which a jump motion
reads before it records (`checkPrevious`). `none` for a view with no
window. -/
def previousOf (view : ViewId) : EditorM (Option Place) := do
  return ((← editorState).window? view).bind (·.jumps.previous)

/-- Vim's `checkpcmark` ("Check a jump", in the module docs): once a jump
in `view` has moved the cursor, gives the window back `before`, the
previous-context mark it had before the jump recorded, when the cursor is
on the place the jump recorded, in the same buffer. Nothing when `before`
is `none`, as Vim keeps the place recorded when there was no mark before,
and nothing for a view with no window. -/
def checkPrevious (view : ViewId) (before : Option Place) : EditorM Unit := do
  let some before := before | return
  let some target := (← editorState).target? view | return
  let some (.held buffer marker) := target.window.jumps.previous | return
  let selection ← target.selection
  let some range := selection.ranges[selection.primary]? | return
  if buffer == target.window.buffer && (← Marks.offsetOf marker) == range.head then
    discard <| view.setJumps { target.window.jumps with previous := some before }

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

/-- Puts the cursor of `view` at `offset`, one bar with its shape kept
("Placing the cursor", in the module docs). -/
def placeCursor (view : ViewId) (offset : Nat) : EditorM Unit := do
  if let .ok selection← view.selection then
    discard <|
        view.select
          { selection with
            ranges := #[⟨offset, offset⟩], primary := 0 }

/-- The offset `offset` of `text`, or, with `line`, the first non-blank of
its line ("Placing the cursor", in the module docs). -/
def offsetOn (text : TextId) (offset : Nat) (line : Bool) : TextM Nat :=
  if line then text.motion .lineFirstNonBlank offset else pure offset

/-- Puts the cursor of `view` on the place held by `marker` in `buffer`,
showing `buffer` in the window first when it shows another; with `line`, on
the first non-blank of the place's line. Nothing when the window cannot
show the buffer. -/
def goHeld (view : ViewId) (buffer : BufferId) (marker : MarkerId) (line : Bool) : EditorM Unit :=
  do
  let some window := (← editorState).window? view | return
  if window.buffer != buffer then
    let .ok () ← view.show buffer | return
  placeCursor view (← offsetOn marker.text (← Marks.offsetOf marker) line)

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

/-- Visits the place in its source of the offset `head` of the excerpt text
`text` in `view` ("Visiting the source of an excerpt buffer's place", in
the module docs): says `nothing` when it is in no excerpt, or no buffer
holds its source. -/
def visitLocated (view : ViewId) (text : TextId) (head : Nat) (nothing : String) : EditorM Unit :=
  do
  let some located ← (text.locate head : TextM (Option Located)) | message nothing
  let some source := (← editorState).bufferOver? located.source | message nothing
  record view
  let .ok () ← view.show source | message nothing
  placeCursor view located.offset

end Editor.Jumps
